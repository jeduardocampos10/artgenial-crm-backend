module Instagram::IntegrationHelper
  STATE_TTL = 10.minutes

  # Generates a short-lived, signed OAuth state bound to the initiating user,
  # callback URI and login mode. The authorization code itself is single-use at
  # Meta, while the random jti prevents predictable state values.
  def generate_instagram_token(identifier, mode:, redirect_uri:)
    return if client_secret.blank? || Current.user.blank?

    JWT.encode(token_payload(identifier, mode: mode, redirect_uri: redirect_uri), client_secret, 'HS256')
  rescue StandardError => e
    Rails.logger.error("Failed to generate Instagram OAuth state: #{e.class}")
    nil
  end

  def token_payload(identifier, mode:, redirect_uri:)
    now = Time.current.to_i
    {
      sub: identifier,
      user_id: Current.user.id.to_s,
      mode: mode,
      redirect_uri: redirect_uri,
      jti: SecureRandom.uuid,
      iat: now,
      exp: now + STATE_TTL.to_i
    }
  end

  # Returns the verified payload only when it belongs to the authenticated user
  # and exact callback URI. This blocks login-CSRF and cross-session state reuse.
  def verify_instagram_state(token, redirect_uri:)
    return if token.blank? || client_secret.blank? || Current.user.blank?

    payload = decode_token(token, client_secret)
    return unless payload
    return unless payload['user_id'].to_s == Current.user.id.to_s
    return unless ActiveSupport::SecurityUtils.secure_compare(payload['redirect_uri'].to_s, redirect_uri.to_s)

    payload
  end

  private

  def client_secret
    @client_secret ||= GlobalConfigService.load('INSTAGRAM_APP_SECRET', nil)
  end

  def decode_token(token, secret)
    JWT.decode(token, secret, true, {
                 algorithm: 'HS256',
                 verify_expiration: true,
                 verify_iat: true
               }).first
  rescue StandardError => e
    Rails.logger.warn("Instagram OAuth state verification failed: #{e.class}")
    nil
  end
end
