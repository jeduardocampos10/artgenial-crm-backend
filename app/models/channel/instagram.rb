# == Schema Information
#
# Table name: channel_instagram
#
#  id                 :uuid             not null, primary key
#  access_token       :text             not null
#  auth_mode          :string           default("instagram_login"), not null
#  client_business_id :string
#  evolution_hub_meta :jsonb            not null
#  expires_at         :datetime
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  instagram_id       :string           not null
#  login_config_id    :string
#
# Indexes
#
#  index_channel_instagram_on_instagram_id  (instagram_id) UNIQUE
#
class Channel::Instagram < ApplicationRecord
  include Channelable
  include Reauthorizable
  include EvolutionHubReconcilable
  include ChannelMessageTemplates
  include EvolutionHubChannelCleanup
  self.table_name = 'channel_instagram'

  AUTHORIZATION_ERROR_THRESHOLD = 1
  AUTH_MODES = %w[instagram_login unified_login].freeze

  # On a hub-managed channel the credentials only exist while the Hub reports
  # `active` — the `channel_connected` webhook fills them in, and a
  # `channel_disconnected` takes the connection away again. Requiring them at
  # any other status would raise while recording what the Hub just told us.
  validates :access_token, presence: true, unless: :hub_credentials_absent?
  validates :instagram_id, uniqueness: true
  validates :instagram_id, presence: true, unless: :hub_credentials_absent?
  validates :auth_mode, inclusion: { in: AUTH_MODES }
  validates :client_business_id, :login_config_id, presence: true, if: :unified_login?

  after_create_commit :subscribe
  after_update_commit :resubscribe_if_token_changed
  before_destroy :unsubscribe

  def hub_pending?
    evolution_hub_meta.is_a?(Hash) && evolution_hub_meta['status'] == 'pending'
  end

  def hub_active?
    evolution_hub_meta.is_a?(Hash) && evolution_hub_meta['status'] == 'active'
  end

  def name
    'Instagram'
  end

  def unified_login?
    auth_mode == 'unified_login'
  end

  # Unified Login uses graph.facebook.com with an explicit Instagram account ID;
  # legacy Instagram Login remains on graph.instagram.com. Hub-managed channels
  # keep using the existing transparent /meta proxy.
  def graph_api_base_url
    return MetaBaseUrl.for(:instagram) if MetaBaseUrl.enabled?

    version = GlobalConfigService.load('INSTAGRAM_API_VERSION', 'v23.0').to_s
    version = 'v23.0' unless version.match?(/\Av\d+\.\d+\z/)
    host = unified_login? ? 'graph.facebook.com' : 'graph.instagram.com'
    "https://#{host}/#{version}"
  end

  def create_contact_inbox(instagram_id, name)
    @contact_inbox = ::ContactInboxWithContactBuilder.new({
                                                            source_id: instagram_id,
                                                            inbox: inbox,
                                                            contact_attributes: { name: name }
                                                          }).perform
  end

  def subscribe
    # In Hub mode the Hub already subscribed the IG user on its side with the
    # real Meta app token; the CRM doesn't have that token and shouldn't try.
    return if MetaBaseUrl.enabled?
    # Also skip while still pending — instagram_id is a placeholder until the
    # operator finishes OAuth at the Hub.
    return if hub_pending?

    # ref https://developers.facebook.com/docs/instagram-platform/webhooks#enable-subscriptions
    Rails.logger.info("Instagram: Subscribing to webhooks for instagram_id=#{instagram_id}")

    response = HTTParty.post(
      "#{graph_api_base_url}/#{instagram_id}/subscribed_apps",
      body: URI.encode_www_form(
        subscribed_fields: %w[messages message_reactions messaging_seen message_edit comments live_comments].join(',')
      ),
      headers: {
        'Authorization' => "Bearer #{access_token}",
        'Content-Type' => 'application/x-www-form-urlencoded'
      }
    )

    if response.success?
      Rails.logger.info("Instagram: Webhook subscription SUCCESS for instagram_id=#{instagram_id}")
    else
      Rails.logger.error("Instagram: Webhook subscription FAILED for instagram_id=#{instagram_id} - Status: #{response.code}, Body: #{response.body}")
    end

    true
  rescue StandardError => e
    Rails.logger.error("Instagram: Webhook subscription ERROR for instagram_id=#{instagram_id} - #{e.class}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    true
  end

  def unsubscribe
    return true if MetaBaseUrl.enabled?

    HTTParty.delete(
      "#{graph_api_base_url}/#{instagram_id}/subscribed_apps",
      headers: { 'Authorization' => "Bearer #{access_token}" }
    )
    true
  rescue StandardError => e
    Rails.logger.debug { "Rescued: #{e.inspect}" }
    true
  end

  def access_token
    Instagram::RefreshOauthTokenService.new(channel: self).access_token
  end

  # Check subscription status
  def subscription_status
    Rails.logger.info("Instagram: Checking subscription status for instagram_id=#{instagram_id}")

    response = HTTParty.get(
      "#{graph_api_base_url}/#{instagram_id}/subscribed_apps",
      headers: { 'Authorization' => "Bearer #{access_token}" }
    )

    if response.success?
      data = response.parsed_response
      Rails.logger.info("Instagram: Subscription status for instagram_id=#{instagram_id}: #{data.inspect}")
      data
    else
      Rails.logger.error("Instagram: Failed to check subscription status for instagram_id=#{instagram_id} - Status: #{response.code}, Body: #{response.body}")
      nil
    end
  rescue StandardError => e
    Rails.logger.error("Instagram: Error checking subscription status for instagram_id=#{instagram_id} - #{e.class}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    nil
  end

  private

  def hub_managed?
    evolution_hub_meta.is_a?(Hash) && evolution_hub_meta['status'].present?
  end

  def hub_credentials_absent?
    hub_managed? && !hub_active?
  end

  # Re-subscribe if access_token was updated (e.g., after reauthorization)
  def resubscribe_if_token_changed
    return unless saved_change_to_access_token?

    Rails.logger.info("Instagram: Access token changed, re-subscribing to webhooks for instagram_id=#{instagram_id}")
    subscribe
  end
end
