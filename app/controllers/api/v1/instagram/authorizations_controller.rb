class Api::V1::Instagram::AuthorizationsController < Api::V1::BaseController
  require_permissions({
    index: 'instagram_authorizations.read',
    show: 'instagram_authorizations.read',
    create: 'instagram_authorizations.create',
    update: 'instagram_authorizations.update',
    destroy: 'instagram_authorizations.delete',
    callback: 'instagram_authorizations.create'
  })
  include InstagramConcern
  include Instagram::IntegrationHelper


  def create
    mode = unified_login_enabled? ? 'unified_login' : 'instagram_login'
    state = generate_instagram_token('community', mode: mode, redirect_uri: instagram_redirect_uri)

    redirect_url = if mode == 'unified_login'
                     unified_login_service.authorization_url(state: state)
                   else
                     legacy_authorization_url(state)
                   end

    render json: { success: true, url: redirect_url }
  rescue Instagram::UnifiedLoginService::Error => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  rescue StandardError => e
    Rails.logger.error("Instagram authorization URL error: #{e.class}")
    render json: { success: false, error: 'Unable to start the Instagram connection' }, status: :unprocessable_entity
  end

  def callback
    code = params[:code]
    state = params[:state]

    if code.blank? || state.blank?
      render json: { success: false, error: 'Missing code or state' }, status: :bad_request
      return
    end

    state_payload = verify_instagram_state(state, redirect_uri: instagram_redirect_uri)
    unless state_payload.present?
      render json: { success: false, error: 'Invalid or expired state token' }, status: :unauthorized
      return
    end

    channels = if state_payload['mode'] == 'unified_login'
                 complete_unified_login(code)
               else
                 [complete_legacy_login(code)]
               end

    channels.each(&:reauthorized!)
    render json: {
      success: true,
      inbox_id: channels.first.inbox.id,
      channel_id: channels.first.id,
      inbox_ids: channels.map { |channel| channel.inbox.id },
      channel_ids: channels.map(&:id)
    }
  rescue Instagram::UnifiedLoginService::Error => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  rescue StandardError => e
    Rails.logger.error("Instagram callback failed: #{e.class}")
    render json: { success: false, error: 'Unable to complete the Instagram connection' }, status: :unprocessable_entity
  end

  private

  def legacy_authorization_url(state)
    instagram_client.auth_code.authorize_url(
      redirect_uri: instagram_redirect_uri,
      scope: InstagramConcern::LEGACY_REQUIRED_SCOPES.join(','),
      enable_fb_login: '0',
      force_authentication: '1',
      response_type: 'code',
      state: state
    )
  end

  def complete_legacy_login(code)
    response = instagram_client.auth_code.get_token(
      code,
      redirect_uri: instagram_redirect_uri,
      grant_type: 'authorization_code'
    )
    token_response = exchange_for_long_lived_token(response.token)
    user_details = fetch_instagram_user_details(token_response['access_token'])

    find_or_create_channel(user_details, token_response, auth_mode: 'instagram_login')
  end

  def complete_unified_login(code)
    service = unified_login_service
    token_response = service.exchange_code(code)
    access_token = token_response.fetch('access_token')
    client_business_id = service.client_business_id(access_token)
    accounts = service.assigned_instagram_accounts(access_token)

    # Validate every external subscription before replacing any working legacy
    # credential. If one account fails, the database remains untouched.
    accounts.each { |account| service.subscribe_account(access_token, account.fetch('id')) }

    ActiveRecord::Base.transaction do
      accounts.map do |account|
        find_or_create_channel(
          account,
          token_response,
          auth_mode: 'unified_login',
          client_business_id: client_business_id,
          login_config_id: login_config_id
        )
      end
    end
  end

  def find_or_create_channel(user_details, token_response, auth_mode:, client_business_id: nil, login_config_id: nil)
    instagram_id = extract_instagram_user_id(user_details)
    expires_at = token_expires_at(token_response)
    channel_instagram = Channel::Instagram.find_by(instagram_id: instagram_id)
    attributes = {
      access_token: token_response.fetch('access_token'),
      expires_at: expires_at,
      auth_mode: auth_mode,
      client_business_id: client_business_id,
      login_config_id: login_config_id
    }

    if channel_instagram
      Rails.logger.info("Instagram: Updating existing channel for instagram_id=#{instagram_id}")
      channel_instagram.update!(attributes)
      if channel_instagram.inbox
        channel_instagram.inbox.update!(name: user_details['username'])
      else
        Inbox.create!(channel: channel_instagram, name: user_details['username'])
      end
    else
      Rails.logger.info("Instagram: Creating new channel for instagram_id=#{instagram_id}")
      ActiveRecord::Base.transaction do
        channel_instagram = Channel::Instagram.create!(attributes.merge(instagram_id: instagram_id))
        Inbox.create!(channel: channel_instagram, name: user_details['username'])
      end
    end

    channel_instagram
  end

  def token_expires_at(token_response)
    expires_in = token_response['expires_in'].to_i
    return Time.current + expires_in.seconds if expires_in.positive?

    expires_at = token_response['expires_at'].to_i
    Time.zone.at(expires_at) if expires_at.positive?
  end

  def extract_instagram_user_id(user_details)
    (user_details['user_id'] || user_details['id']).to_s
  end

end
