# frozen_string_literal: true

require 'digest'

# Authenticates Evolution webhook deliveries and reserves each signed delivery
# atomically before enqueue. Retries of an already accepted delivery receive 200
# without creating a second job; unavailable auth/dedup infrastructure fails closed.
module EvolutionWebhookAuthConcern
  extend ActiveSupport::Concern

  MAX_TOKEN_AGE = 10.minutes
  REQUIRED_CLAIMS = %w[exp iat jti app action].freeze

  included do
    before_action :authenticate_evolution_webhook!, only: :process_evolution_payload
  end

  private

  def authenticate_evolution_webhook!
    secret = ENV['EVOLUTION_WEBHOOK_SECRET'].to_s
    return render_webhook_unavailable unless secret.bytesize >= 32

    token = request.authorization.to_s[/\ABearer\s+(.+)\z/i, 1]
    return render_webhook_unauthorized if token.blank?

    claims = JWT.decode(
      token,
      secret,
      true,
      algorithm: 'HS256',
      verify_expiration: true,
      verify_iat: true,
      required_claims: REQUIRED_CLAIMS
    ).first

    validate_evolution_claims!(claims)
    reserve_evolution_delivery!(claims.fetch('jti'))
  rescue JWT::DecodeError, KeyError, ArgumentError
    render_webhook_unauthorized
  rescue Redis::BaseError
    render_webhook_unavailable
  end

  def validate_evolution_claims!(claims)
    issued_at = Time.at(Integer(claims.fetch('iat')))
    valid_source = claims['app'] == 'evolution' && claims['action'] == 'webhook'
    valid_age = issued_at >= MAX_TOKEN_AGE.ago && issued_at <= 30.seconds.from_now
    raise JWT::DecodeError, 'invalid Evolution webhook claims' unless valid_source && valid_age
    raise JWT::DecodeError, 'missing delivery id' if claims['jti'].to_s.blank?
  end

  def reserve_evolution_delivery!(delivery_id)
    digest = Digest::SHA256.hexdigest(delivery_id.to_s)
    @evolution_webhook_replay_key = "evolution:webhook:delivery:#{digest}"
    acquired = Redis::Alfred.set(
      @evolution_webhook_replay_key,
      '1',
      nx: true,
      ex: MAX_TOKEN_AGE.to_i
    )
    return true if acquired

    head :ok
    false
  end

  def release_evolution_delivery_reservation!
    return if @evolution_webhook_replay_key.blank?

    Redis::Alfred.delete(@evolution_webhook_replay_key)
  rescue Redis::BaseError => e
    Rails.logger.error("Evolution webhook replay reservation release failed: #{e.class}")
  end

  def render_webhook_unauthorized
    Rails.logger.warn('Rejected unauthenticated Evolution webhook delivery')
    head :unauthorized
    false
  end

  def render_webhook_unavailable
    Rails.logger.error('Evolution webhook authentication infrastructure unavailable')
    head :service_unavailable
    false
  end
end
