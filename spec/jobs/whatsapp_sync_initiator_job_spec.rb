# frozen_string_literal: true

require 'rails_helper'

RSpec.describe WhatsappSyncInitiatorJob do
  subject(:job) { described_class.new }

  let(:webhook_secret) { 'w' * 32 }
  let(:channel) do
    double(
      'evolution channel',
      provider_config: {
        'instance_name' => 'support'
      },
      phone_number: '+55 11 99999-9999'
    )
  end
  let(:response) do
    double(
      success?: true,
      parsed_response: {
        'hash' => 'instance-api-hash',
        'instance' => {'instanceName' => 'support', 'instanceId' => 'instance-id'}
      }
    )
  end

  around do |example|
    previous_backend_url = ENV.fetch('BACKEND_URL', nil)
    previous_webhook_secret = ENV.fetch('EVOLUTION_WEBHOOK_SECRET', nil)
    ENV['BACKEND_URL'] = 'https://crm.example.test'
    ENV['EVOLUTION_WEBHOOK_SECRET'] = webhook_secret
    allow(GlobalConfigService).to receive(:load_env_first)
      .with('EVOLUTION_API_URL', '').and_return('http://evolution-api:8080')
    allow(GlobalConfigService).to receive(:load_env_first)
      .with('EVOLUTION_ADMIN_SECRET', '').and_return('server-only-admin-token')
    example.run
  ensure
    ENV['BACKEND_URL'] = previous_backend_url
    ENV['EVOLUTION_WEBHOOK_SECRET'] = previous_webhook_secret
  end

  it 'uses global Evolution credentials and registers the webhook JWT signing secret' do
    allow(channel).to receive(:update!)

    expect(HTTParty).to receive(:post) do |url, options|
      expect(url).to eq('http://evolution-api:8080/instance/create')
      expect(options[:headers]).to include('apikey' => 'server-only-admin-token')

      payload = JSON.parse(options[:body])
      expect(payload.dig('webhook', 'url')).to eq('https://crm.example.test/webhooks/whatsapp/evolution')
      expect(payload.dig('webhook', 'headers', 'jwt_key')).to eq(webhook_secret)
      response
    end

    job.send(:create_evolution_instance, channel)
  end

  context 'when the webhook secret is too short' do
    let(:webhook_secret) { 'short' }

    it 'fails closed before sending a request to Evolution' do
      expect(HTTParty).not_to receive(:post)

      expect { job.send(:create_evolution_instance, channel) }
        .to raise_error(RuntimeError, 'EVOLUTION_WEBHOOK_SECRET must contain at least 32 bytes')
    end
  end
end
