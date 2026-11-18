class Instagram::MessageText < Instagram::BaseMessageText
  attr_reader :messaging

  def ensure_contact(ig_scope_id)
    Rails.logger.info("[Instagram::MessageText] ensure_contact called with ig_scope_id: #{ig_scope_id}")
    result = fetch_instagram_user(ig_scope_id)
    Rails.logger.info("[Instagram::MessageText] fetch_instagram_user result: #{result.inspect}")

    # Use ig_scope_id as fallback if API didn't return user data
    if result.blank? || result['id'].blank?
      Rails.logger.warn('[Instagram::MessageText] fetch_instagram_user returned empty result or nil id, using ig_scope_id as fallback')
      result = { 'id' => ig_scope_id, 'name' => nil }.with_indifferent_access
    end

    Rails.logger.info("[Instagram::MessageText] Calling find_or_create_contact with result: #{result.inspect}")
    find_or_create_contact(result)
    Rails.logger.info("[Instagram::MessageText] After find_or_create_contact, contact_inbox: #{@contact_inbox.inspect}")
  end

  # Busca nome/username/foto do contato. Em Hub mode roteia pelo proxy /meta do EvoHub
  # com `Authorization: Bearer {channel_token}` (o access_token DIRETO no Graph é o
  # channel_token opaco → 190 → authorization_error! prendia o canal e o MessageBuilder
  # engolia a DM). Direto-no-Meta também usa Bearer para não vazar tokens em URLs.
  # ⚠️ O token do Bearer é evolution_hub_meta['channel_token'] (o getter access_token é
  # sobrescrito por RefreshOauthTokenService e retorna 'hub-managed-…', NÃO o token real).
  # 'profile_pic' é o campo do contato (sender-scoped id); 'profile_picture_url' só existe
  # p/ business account — process_successful_response lê os dois (fallback).
  def fetch_instagram_user(ig_scope_id)
    fields = 'id,name,username,profile_pic'

    if MetaBaseUrl.enabled?
      url = "#{MetaBaseUrl.for(:instagram)}/#{ig_scope_id}?fields=#{fields}"
      Rails.logger.info("[Instagram::MessageText] Fetching user via Hub proxy - ig_scope_id: #{ig_scope_id}")
      response = HTTParty.get(url, headers: hub_auth_headers)
    else
      url = "#{base_uri}/#{ig_scope_id}?fields=#{fields}"
      Rails.logger.info("[Instagram::MessageText] Fetching user data from Instagram API - ig_scope_id: #{ig_scope_id}")
      response = HTTParty.get(
        url,
        headers: { 'Authorization' => "Bearer #{@inbox.channel.access_token}" }
      )
    end

    Rails.logger.info("[Instagram::MessageText] Instagram API response - status: #{response.code}, success?: #{response.success?}, body: #{response.body.inspect}")

    if response.success?
      # Check if response body is empty or just {}
      parsed_body = begin
        JSON.parse(response.body)
      rescue StandardError
        {}
      end
      if parsed_body.blank? || parsed_body == {}
        Rails.logger.warn("[Instagram::MessageText] Instagram API returned empty response (status 200) - this usually means user consent is required or token lacks permissions. User ID: #{ig_scope_id}")
        return {}
      end

      # Check if there's an error in the response even with status 200
      if parsed_body['error'].present?
        Rails.logger.warn("[Instagram::MessageText] Instagram API returned error in successful response: #{parsed_body['error'].inspect}")
        handle_error_response(response)
        return {}
      end

      result = process_successful_response(response)
      Rails.logger.info("[Instagram::MessageText] Processed successful response: #{result.inspect}")
      return result
    end

    handle_error_response(response)
    {}
  end

  def process_successful_response(response)
    result = JSON.parse(response.body).with_indifferent_access
    # O contato (sender-scoped id) expõe `profile_pic`; só o business account expõe
    # `profile_picture_url`. O código antigo lia SÓ profile_picture_url → avatar do
    # contato sempre nil (bug latente, Hub e não-Hub). Preferir profile_pic, fallback url.
    pic = result['profile_pic'].presence || result['profile_picture_url'].presence
    {
      'id' => result['id'],
      'name' => result['name'],
      'username' => result['username'],
      'profile_pic' => pic,
      'profile_picture_url' => pic
    }.with_indifferent_access
  end

  def handle_error_response(response)
    parsed_response = response.parsed_response
    error_message = parsed_response.dig('error', 'message')
    error_code = parsed_response.dig('error', 'code')

    Rails.logger.warn("[Instagram::MessageText] Instagram API error - code: #{error_code}, message: #{error_message}, full_response: #{parsed_response.inspect}")

    # https://developers.facebook.com/docs/messenger-platform/error-codes
    # Access token has expired or become invalid.
    if error_code == 190
      Rails.logger.error('[Instagram::MessageText] Access token expired or invalid (error 190), marking channel as requiring reauthorization')
      channel.authorization_error!
    end

    # TODO: Remove this once we have a better way to handle this error.
    # https://developers.facebook.com/docs/messenger-platform/instagram/features/user-profile/#user-consent
    # The error typically occurs when the connected Instagram account attempts to send a message to a user
    # who has never messaged this Instagram account before.
    # We can only get consent to access a user's profile if they have previously sent a message to the connected Instagram account.
    # In such cases, we receive the error "User consent is required to access user profile".
    # We can safely ignore this error.
    if error_code == 230
      Rails.logger.info('[Instagram::MessageText] User consent required (error 230) - this is expected for first-time users. Using ig_scope_id as fallback.')
      return
    end

    Rails.logger.warn("[InstagramUserFetchError]: inbox_id #{@inbox.id}")
    Rails.logger.warn("[InstagramUserFetchError]: #{error_message} #{error_code}")

    exception = StandardError.new("#{error_message} (Code: #{error_code})")
    EvolutionExceptionTracker.new(exception, account: nil).capture_exception
  end

  def base_uri
    @inbox.channel.graph_api_base_url
  end

  # Header de auth do proxy /meta do EvoHub (Hub-ON). O proxy EXIGE Bearer (rejeita
  # ?access_token= com 401). Token = evolution_hub_meta['channel_token'] (NÃO o getter
  # access_token, que é sobrescrito e retorna 'hub-managed-…'). Nunca logar o header.
  def hub_auth_headers
    token = (@inbox.channel.evolution_hub_meta || {})['channel_token']
    { 'Authorization' => "Bearer #{token}" }
  end

  def create_message
    Rails.logger.info("[Instagram::MessageText] create_message called - contact_inbox: #{@contact_inbox.inspect}")

    unless @contact_inbox
      Rails.logger.warn('[Instagram::MessageText] contact_inbox is nil, cannot create message')
      return
    end

    Rails.logger.info('[Instagram::MessageText] Creating message via MessageBuilder')
    result = Messages::Instagram::MessageBuilder.new(@messaging, @inbox, outgoing_echo: agent_message_via_echo?).perform
    Rails.logger.info("[Instagram::MessageText] MessageBuilder result: #{result.inspect}")
    result
  end
end
