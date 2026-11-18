# frozen_string_literal: true

# Implements Instagram API with Unified Login (Facebook Login for Business).
# Every Graph URL is fixed to Meta-owned hosts and credentials remain server-side.
class Instagram::UnifiedLoginService
  class Error < StandardError; end

  AUTHORIZATION_ENDPOINT = 'https://www.facebook.com/dialog/oauth'
  GRAPH_ENDPOINT = 'https://graph.facebook.com'
  MAX_ACCOUNT_PAGES = 10

  attr_reader :client_id, :client_secret, :config_id, :redirect_uri, :api_version

  def initialize(client_id:, client_secret:, config_id:, redirect_uri:, api_version:)
    @client_id = client_id.to_s.strip
    @client_secret = client_secret.to_s.strip
    @config_id = config_id.to_s.strip
    @redirect_uri = redirect_uri.to_s.strip
    @api_version = normalize_api_version(api_version)
  end

  def authorization_url(state:)
    require_configuration!
    raise Error, 'Unable to create Instagram authorization state' if state.blank?

    query = URI.encode_www_form(
      client_id: client_id,
      config_id: config_id,
      display: 'popup',
      override_default_response_type: 'true',
      redirect_uri: redirect_uri,
      response_type: 'code',
      state: state,
      prompt: 'login'
    )
    "#{AUTHORIZATION_ENDPOINT}?#{query}"
  end

  def exchange_code(code)
    require_configuration!
    raise Error, 'Instagram authorization code is missing' if code.blank?

    # This server-side redirect flow sends redirect_uri in the authorization
    # request, so Meta requires the exact same value during the code exchange.
    graph_get(
      '/oauth/access_token',
      {
        client_id: client_id,
        client_secret: client_secret,
        code: code,
        redirect_uri: redirect_uri
      },
      operation: 'token exchange'
    ).tap do |payload|
      raise Error, 'Meta did not return an Instagram access token' if payload['access_token'].blank?
    end
  end

  def client_business_id(access_token)
    payload = graph_get(
      '/me',
      { fields: 'client_business_id' },
      access_token: access_token,
      operation: 'business identity'
    )
    payload['client_business_id'].presence || raise(Error, 'Meta did not return the client business ID')
  end

  def assigned_instagram_accounts(access_token)
    accounts = []
    after = nil

    MAX_ACCOUNT_PAGES.times do |page_index|
      query = { fields: 'id,username', limit: 100 }
      query[:after] = after if after.present?
      payload = graph_get(
        '/me/assigned_instagram_accounts',
        query,
        access_token: access_token,
        operation: 'account discovery'
      )
      accounts.concat(Array(payload['data']))

      next_after = payload.dig('paging', 'cursors', 'after').presence
      has_next_page = payload.dig('paging', 'next').present?
      break unless has_next_page && next_after.present? && next_after != after

      if page_index == MAX_ACCOUNT_PAGES - 1
        raise Error, 'Meta returned too many Instagram account pages; narrow the shared accounts and try again'
      end

      after = next_after
    end

    normalized = accounts.filter_map do |account|
      id = account['id'].to_s.strip
      next if id.blank?

      { 'id' => id, 'username' => account['username'].presence || "Instagram #{id}" }
    end.uniq { |account| account['id'] }

    raise Error, 'No Instagram professional account was shared with this app' if normalized.empty?

    normalized
  end

  # A connection is not considered successful until Meta accepts the webhook
  # subscription with the newly issued business token. This protects an
  # existing legacy channel from being overwritten by an unusable token.
  def subscribe_account(access_token, account_id)
    fields = %w[messages message_reactions messaging_seen message_edit comments live_comments]
    response = HTTParty.post(
      "#{GRAPH_ENDPOINT}/#{api_version}/#{account_id}/subscribed_apps",
      body: URI.encode_www_form(subscribed_fields: fields.join(',')),
      headers: {
        'Accept' => 'application/json',
        'Authorization' => "Bearer #{access_token}",
        'Content-Type' => 'application/x-www-form-urlencoded'
      },
      timeout: 15
    )
    payload = parse_response(response)
    return true if response.success? && payload['error'].blank? && payload['success'] == true

    raise_meta_error(response, payload, operation: 'webhook subscription')
  end

  private

  def require_configuration!
    missing = {
      'INSTAGRAM_APP_ID' => client_id,
      'INSTAGRAM_APP_SECRET' => client_secret,
      'INSTAGRAM_LOGIN_CONFIG_ID' => config_id,
      'redirect_uri' => redirect_uri
    }.filter_map { |name, value| name if value.blank? }
    return if missing.empty?

    raise Error, "Missing Instagram Unified Login configuration: #{missing.join(', ')}"
  end

  def normalize_api_version(value)
    version = value.to_s.strip
    version.match?(/\Av\d+\.\d+\z/) ? version : 'v23.0'
  end

  def graph_get(path, query, access_token: nil, operation: 'request')
    headers = { 'Accept' => 'application/json' }
    headers['Authorization'] = "Bearer #{access_token}" if access_token.present?
    response = HTTParty.get(
      "#{GRAPH_ENDPOINT}/#{api_version}#{path}",
      query: query,
      headers: headers,
      timeout: 15
    )
    payload = parse_response(response)

    return payload if response.success? && payload['error'].blank?

    raise_meta_error(response, payload, operation: operation)
  end

  def parse_response(response)
    payload = response.parsed_response
    payload.is_a?(Hash) ? payload : JSON.parse(response.body)
  rescue JSON::ParserError
    Rails.logger.warn("Instagram Unified Login Meta response was not JSON: status=#{response.code}")
    raise Error, 'Meta returned an invalid response for the Instagram connection'
  end

  def raise_meta_error(response, payload, operation:)
    error_code = payload.dig('error', 'code')
    Rails.logger.warn("Instagram Unified Login Meta #{operation} failed: status=#{response.code} code=#{error_code}")
    suffix = error_code.present? ? " (code #{error_code})" : ''
    raise Error, "Meta rejected the Instagram connection#{suffix}"
  end
end
