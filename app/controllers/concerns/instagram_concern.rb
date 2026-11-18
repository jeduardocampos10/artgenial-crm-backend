module InstagramConcern
  extend ActiveSupport::Concern

  LEGACY_REQUIRED_SCOPES = %w[
    instagram_business_basic
    instagram_business_manage_messages
    instagram_business_manage_comments
  ].freeze

  def instagram_client
    ::OAuth2::Client.new(
      client_id,
      client_secret,
      {
        site: 'https://api.instagram.com',
        authorize_url: 'https://www.instagram.com/oauth/authorize',
        token_url: 'https://api.instagram.com/oauth/access_token',
        auth_scheme: :request_body,
        token_method: :post
      }
    )
  end

  def unified_login_service
    Instagram::UnifiedLoginService.new(
      client_id: client_id,
      client_secret: client_secret,
      config_id: login_config_id,
      redirect_uri: instagram_redirect_uri,
      api_version: instagram_api_version
    )
  end

  def unified_login_enabled?
    login_config_id.present?
  end

  def instagram_redirect_uri
    "#{base_url}/instagram/callback"
  end

  private

  def client_id
    GlobalConfigService.load('INSTAGRAM_APP_ID', nil)
  end

  def client_secret
    GlobalConfigService.load('INSTAGRAM_APP_SECRET', nil)
  end

  def login_config_id
    GlobalConfigService.load('INSTAGRAM_LOGIN_CONFIG_ID', nil)
  end

  def instagram_api_version
    GlobalConfigService.load('INSTAGRAM_API_VERSION', 'v23.0')
  end

  def exchange_for_long_lived_token(short_lived_token)
    endpoint = 'https://graph.instagram.com/access_token'
    params = {
      grant_type: 'ig_exchange_token',
      client_secret: client_secret,
      access_token: short_lived_token,
      client_id: client_id
    }

    make_api_request(endpoint, params, 'Failed to exchange token')
  end

  def fetch_instagram_user_details(access_token)
    endpoint = 'https://graph.instagram.com/v23.0/me'
    params = {
      fields: 'id,username,user_id,name,profile_picture_url,account_type',
      access_token: access_token
    }

    make_api_request(endpoint, params, 'Failed to fetch Instagram user details')
  end

  def make_api_request(endpoint, params, error_prefix)
    response = HTTParty.get(
      endpoint,
      query: params,
      headers: { 'Accept' => 'application/json' }
    )

    unless response.success?
      Rails.logger.error "#{error_prefix}. Status: #{response.code}, Body: #{response.body}"
      raise "#{error_prefix}: #{response.body}"
    end

    begin
      JSON.parse(response.body)
    rescue JSON::ParserError => e
      EvolutionExceptionTracker.new(e).capture_exception
      Rails.logger.error "Invalid JSON response: #{response.body}"
      raise e
    end
  end

  def base_url
    ENV.fetch('FRONTEND_URL', 'http://localhost:5173').chomp('/')
  end
end
