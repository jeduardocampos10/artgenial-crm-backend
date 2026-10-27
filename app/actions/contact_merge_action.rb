class ContactMergeAction
  class MergeBlocked < StandardError; end
  include Events::Types
  pattr_initialize [:base_contact!, :mergee_contact!, { account: nil }]

  def perform
    # This case happens when an agent updates a contact email in dashboard,
    # while the contact also update his email via email collect box
    return @base_contact if base_contact.id == mergee_contact.id

    ActiveRecord::Base.transaction do
      Contact.lock.where(id: [base_contact.id, mergee_contact.id]).order(:id).load
      validate_contacts
      merge_conversations
      merge_messages
      merge_contact_inboxes
      merge_contact_notes
      merge_and_remove_mergee_contact
    end
    @base_contact
  end

  private

  def validate_contacts
    if [base_contact, mergee_contact].any? { |contact| protected_memory_associations?(contact) } ||
       PipelineItem.where(contact_id: mergee_contact.id).exists? ||
       ContactCompany.where(contact_id: mergee_contact.id).or(ContactCompany.where(company_id: mergee_contact.id)).exists?
      raise MergeBlocked, 'contact merge requires explicit memory, relationship or pipeline reconciliation'
    end
    return if belongs_to_account?(@base_contact) && belongs_to_account?(@mergee_contact)

    raise StandardError, 'contact does not belong to the account'
  end

  def protected_memory_associations?(contact)
    contact.contact_identities.exists? || contact.memory_records.exists? || contact.customer_events.exists?
  end

  def belongs_to_account?(_contact)
    true
  end

  def merge_conversations
    Conversation.where(contact_id: @mergee_contact.id).update(contact_id: @base_contact.id)
  end

  def merge_contact_notes
    Note.where(contact_id: @mergee_contact.id).update(contact_id: @base_contact.id)
  end

  def merge_messages
    Message.where(sender: @mergee_contact).update(sender: @base_contact)
  end

  def merge_contact_inboxes
    ContactInbox.where(contact_id: @mergee_contact.id).update(contact_id: @base_contact.id)
  end

  def merge_and_remove_mergee_contact
    mergable_attribute_keys = %w[identifier name email phone_number additional_attributes custom_attributes]
    base_contact_attributes = base_contact.attributes.slice(*mergable_attribute_keys).compact_blank
    mergee_contact_attributes = mergee_contact.attributes.slice(*mergable_attribute_keys).compact_blank

    # attributes in base contact are given preference
    merged_attributes = mergee_contact_attributes.deep_merge(base_contact_attributes)

    @mergee_contact.reload.destroy!
    Rails.configuration.dispatcher.dispatch(CONTACT_MERGED, Time.zone.now, contact: @base_contact,
                                                                           tokens: [@base_contact.contact_inboxes.filter_map(&:pubsub_token)])
    @base_contact.update!(merged_attributes)
  end
end
