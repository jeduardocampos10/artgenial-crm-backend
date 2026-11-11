require 'base64'
require 'digest'
require 'securerandom'
require 'tempfile'

module Whatsapp::EvolutionHandlers::MessagesUpsert
  include Whatsapp::EvolutionHandlers::Helpers
  include Whatsapp::EvolutionHandlers::AttachmentProcessor
  include Whatsapp::EvolutionHandlers::FileExtensions
  include Whatsapp::EvolutionHandlers::ContentHandlers
  include Whatsapp::EvolutionHandlers::ProfilePictureHandler
  include EvolutionHelper

  EVOLUTION_MESSAGE_GUARD_TTL = 5.minutes.to_i

  private

  def process_messages_upsert
    # Evolution API v2.3.1 sends single message data directly in 'data' field
    message_data = processed_params[:data]
    return if message_data.blank?

    @message = nil
    @contact_inbox = nil
    @contact = nil
    @raw_message = message_data

    Rails.logger.info "Evolution API: Processing message for inbox #{@inbox.id} (outgoing: #{!incoming?})"

    if incoming?
      handle_message
    else
      # Handle outgoing messages with lock to avoid race conditions
      with_evolution_channel_lock_on_outgoing_message(inbox.channel.id) { handle_message }
    end
  end

  def handle_message
    return handle_revoke_protocol if message_type == 'protocol'
    return unless message_processable?
    return unless acquire_evolution_message_guard

    begin
      # Redis is only a contention optimization and may be unavailable. Recheck
      # PostgreSQL after acquiring the lease; the unique index remains authoritative.
      return if find_evolution_message_by_source_id

      set_contact

      unless @contact
        Rails.logger.warn "Evolution API: Contact not found while processing message for inbox #{@inbox.id}"
        return
      end

      set_conversation
      update_conversation_status_if_needed
      handle_create_message
    ensure
      release_evolution_message_guard
    end
  end

  # A revoke arrives as a protocolMessage; mark the original as revoked-by-contact
  # (the upsert path otherwise just ignores protocol via ignore_message?).
  def handle_revoke_protocol
    protocol = @raw_message.dig(:message, :protocolMessage)
    source_id = revoked_message_source_id(protocol)
    Rails.logger.info "Evolution API: Processing message revocation for inbox #{@inbox.id}"
    mark_message_revoked_by_source_id(source_id)
  end

  def set_contact
    if jid_type == 'group'
      set_group_contact
    else
      set_individual_contact
    end
  end

  def set_group_contact
    subject = group_subject
    Rails.logger.debug { "Evolution API: Setting group contact for inbox #{@inbox.id}" }

    contact_inbox = ::ContactInboxWithContactBuilder.new(
      source_id: group_jid,
      inbox: inbox,
      contact_attributes: {
        name: subject,
        identifier: group_jid,
        type: 'group'
      }
    ).perform

    @contact_inbox = contact_inbox
    @contact = contact_inbox.contact

    @contact.update_columns(type: 'group') unless @contact.group?
    update_group_name_if_safe(subject)
  end

  # Mirror of the Evolution Go safeguard: only refresh @contact.name when the
  # incoming subject is a real one and the current name is empty or still the
  # synthetic fallback. Prevents overwriting an operator-renamed group, and
  # prevents the fallback from clobbering a real subject that arrived later.
  def update_group_name_if_safe(subject)
    return if subject.blank?
    return if @contact.name == subject
    return if fallback_group_name?(subject)
    return unless @contact.name.blank? || fallback_group_name?(@contact.name)

    Rails.logger.debug { "Evolution API: Updating group name for contact #{@contact.id}" }
    @contact.update!(name: subject)
  end

  def fallback_group_name?(name)
    name.to_s.match?(/\AWhatsApp Group(?:\s+\S+)?\z/)
  end

  def set_individual_contact
    push_name = contact_name
    raw_source_id = phone_number_from_jid

    # Always normalize Brazilian numbers to the 9-digit format.
    # processed_waid only helps when a contact_inbox already exists; it misses contacts
    # created manually in the CRM (Contact record exists, but no ContactInbox yet).
    # By normalizing unconditionally, find_contact_by_phone_number can also match them.
    source_id = brazil_phone_number?(raw_source_id) ? normalised_brazil_mobile_number(raw_source_id) : raw_source_id

    contact_inbox = ::ContactInboxWithContactBuilder.new(
      source_id: source_id,
      inbox: inbox,
      contact_attributes: {
        name: push_name,
        phone_number: "+#{source_id}"
      }
    ).perform

    @contact_inbox = contact_inbox
    @contact = contact_inbox.contact

    # Update contact name if it was just the phone number
    @contact.update!(name: push_name) if @contact.name == raw_source_id && push_name.present?

    update_contact_profile_picture(@contact, source_id)
  end

  def phone_number_string?(value)
    value.present? && value.match?(/^\+?\d{7,15}$/)
  end

  def handle_create_message
    create_message(attach_media: media_attachment?)
  end

  def create_message(attach_media: false)
    build_message_attributes
    handle_attach_media if attach_media
    handle_location if message_type == 'location'
    handle_contacts if message_type == 'contacts'
    save_message_and_notify
  end

  def build_message_attributes
    @message = @conversation.messages.build(
      content: message_content || '',
      inbox_id: @inbox.id,
      source_id: raw_message_id,
      sender: incoming? ? @contact : User.where(type: 'SuperAdmin').first || User.first,
      sender_type: incoming? ? 'Contact' : 'User',
      message_type: incoming? ? :incoming : :outgoing,
      content_attributes: message_content_attributes
    )
  end

  def save_message_and_notify
    @message.save!

    Rails.logger.info "Evolution API: Message created successfully for inbox #{@inbox.id}"
    inbox.channel.received_messages([@message], @conversation) if incoming?
  rescue ActiveRecord::RecordNotUnique
    # A concurrent worker can win even when Redis is unavailable or its lease
    # expires. Swallow only the expected message identity conflict; unrelated
    # unique violations must still reach the retry/dead-letter path.
    existing_message = find_evolution_message_by_source_id
    raise unless existing_message

    @message = existing_message
    Rails.logger.info "Evolution API: Duplicate message delivery ignored for inbox #{@inbox.id}"
  end

  def message_processable?
    return false if raw_message_id.blank?
    return false unless jid_type.in?(%w[user group])
    return false if ignore_message?
    return false if find_evolution_message_by_source_id

    true
  end

  def find_evolution_message_by_source_id
    @message = Message.find_by(inbox_id: @inbox.id, source_id: raw_message_id)
  end

  def acquire_evolution_message_guard
    key = evolution_message_guard_key
    token = SecureRandom.uuid
    acquired = ::Redis::Alfred.set(key, token, nx: true, ex: EVOLUTION_MESSAGE_GUARD_TTL)
    @evolution_message_guard = { key: key, token: token } if acquired
    acquired.present?
  rescue StandardError => e
    # PostgreSQL is the correctness boundary, so a Redis outage must not lose a
    # webhook. Log only exception type; adapter messages can contain endpoints.
    Rails.logger.warn "Evolution API: Redis message guard unavailable (#{e.class})"
    true
  end

  def release_evolution_message_guard
    guard = @evolution_message_guard
    return unless guard

    ::Redis::Alfred.delete_if_value(guard[:key], guard[:token])
  rescue StandardError => e
    Rails.logger.warn "Evolution API: Redis message guard release failed (#{e.class})"
  ensure
    @evolution_message_guard = nil
  end

  def evolution_message_guard_key
    source_digest = Digest::SHA256.hexdigest(raw_message_id.to_s)
    format(
      Redis::RedisKeys::EVOLUTION_MESSAGE_SOURCE_KEY,
      inbox_id: @inbox.id,
      source_digest: source_digest
    )
  end

  # Override base conversation_params so groups carry their JID in additional_attributes,
  # which the outbound send path uses to route replies back to the group.
  def conversation_params
    params = {
      inbox_id: @inbox.id,
      contact_id: @contact.id,
      contact_inbox_id: @contact_inbox.id
    }
    params[:additional_attributes] = { evolution_chat_id: group_jid } if jid_type == 'group'
    params
  end

  def update_conversation_status_if_needed
    return unless !incoming? && @conversation&.status == 'pending'

    # CRITICAL: If inbox has active bot, keep conversation pending
    # Bot conversations should only change to open when a human agent manually responds
    # or manually changes the status
    if @conversation.inbox.active_bot?
      Rails.logger.info "Evolution API: Keeping conversation #{@conversation.id} pending (active bot present)"
      return
    end

    @conversation.update!(status: :open)
    Rails.logger.info "Evolution API: Updated conversation #{@conversation.id} status from pending to open for outgoing message"
  end
end
