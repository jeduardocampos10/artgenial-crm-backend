# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Instagram::UnifiedLoginService do
  subject(:service) do
    described_class.new(
      client_id: 'meta-app-1',
      client_secret: 'meta-secret',
      config_id: 'login-config-1',
      redirect_uri: 'https://crm.example.com/instagram/callback',
      api_version: 'v23.0'
    )
  end

  def response(payload, success: true, code: 200)
    instance_double(HTTParty::Response, parsed_response: payload, body: payload.to_json, success?: success, code: code)
  end

  describe '#authorization_url' do
    it 'builds the Facebook Login for Business URL with the exact callback and dynamic state' do
      uri = URI.parse(service.authorization_url(state: 'signed-state'))
      query = Rack::Utils.parse_nested_query(uri.query)

      expect("#{uri.scheme}://#{uri.host}#{uri.path}").to eq('https://www.facebook.com/dialog/oauth')
      expect(query).to include(
        'client_id' => 'meta-app-1',
        'config_id' => 'login-config-1',
        'redirect_uri' => 'https://crm.example.com/instagram/callback',
        'response_type' => 'code',
        'display' => 'popup',
        'override_default_response_type' => 'true',
        'prompt' => 'login',
        'state' => 'signed-state'
      )
      expect(query).not_to have_key('scope')
    end
  end

  describe '#exchange_code' do
    it 'exchanges the code server-side on graph.facebook.com' do
      allow(HTTParty).to receive(:get).and_return(response('access_token' => 'business-token'))

      expect(service.exchange_code('one-time-code')).to include('access_token' => 'business-token')
      expect(HTTParty).to have_received(:get).with(
        'https://graph.facebook.com/v23.0/oauth/access_token',
        hash_including(query: {
          client_id: 'meta-app-1',
          client_secret: 'meta-secret',
          code: 'one-time-code',
          redirect_uri: 'https://crm.example.com/instagram/callback'
        })
      )
    end

    it 'does not expose Meta response bodies when the exchange fails' do
      allow(HTTParty).to receive(:get).and_return(
        response({ 'error' => { 'message' => 'contains-sensitive-data', 'code' => 190 } }, success: false, code: 400)
      )

      expect { service.exchange_code('bad-code') }
        .to raise_error(described_class::Error, 'Meta rejected the Instagram connection (code 190)')
    end
  end

  describe '#client_business_id' do
    it 'loads the business portfolio identifier with a bearer token, not a URL token' do
      allow(HTTParty).to receive(:get).and_return(response('client_business_id' => 'business-1', 'id' => 'system-user'))

      expect(service.client_business_id('business-token')).to eq('business-1')
      expect(HTTParty).to have_received(:get).with(
        'https://graph.facebook.com/v23.0/me',
        hash_including(
          query: { fields: 'client_business_id' },
          headers: hash_including('Authorization' => 'Bearer business-token')
        )
      )
    end
  end

  describe '#subscribe_account' do
    it 'subscribes the selected account before the channel credential is replaced' do
      allow(HTTParty).to receive(:post).and_return(response('success' => true))

      expect(service.subscribe_account('business-token', 'ig-1')).to be true
      expect(HTTParty).to have_received(:post).with(
        'https://graph.facebook.com/v23.0/ig-1/subscribed_apps',
        hash_including(
          body: 'subscribed_fields=messages%2Cmessage_reactions%2Cmessaging_seen%2Cmessage_edit%2Ccomments%2Clive_comments',
          headers: hash_including('Authorization' => 'Bearer business-token')
        )
      )
    end

    it 'rejects a response that did not confirm the subscription' do
      allow(HTTParty).to receive(:post).and_return(response('success' => false))

      expect { service.subscribe_account('business-token', 'ig-1') }
        .to raise_error(described_class::Error, 'Meta rejected the Instagram connection')
    end
  end

  describe '#assigned_instagram_accounts' do
    it 'paginates on the fixed Meta endpoint and deduplicates shared accounts' do
      first = response(
        'data' => [{ 'id' => 'ig-1', 'username' => 'first' }],
        'paging' => { 'cursors' => { 'after' => 'cursor-1' }, 'next' => 'https://untrusted.example/next' }
      )
      second = response('data' => [{ 'id' => 'ig-1', 'username' => 'first' }, { 'id' => 'ig-2', 'username' => 'second' }])
      allow(HTTParty).to receive(:get).and_return(first, second)

      expect(service.assigned_instagram_accounts('business-token')).to eq([
        { 'id' => 'ig-1', 'username' => 'first' },
        { 'id' => 'ig-2', 'username' => 'second' }
      ])
      expect(HTTParty).to have_received(:get)
        .with(
          'https://graph.facebook.com/v23.0/me/assigned_instagram_accounts',
          hash_including(
            query: hash_including(after: 'cursor-1'),
            headers: hash_including('Authorization' => 'Bearer business-token')
          )
        )
    end

    it 'rejects a connection that shared no Instagram professional account' do
      allow(HTTParty).to receive(:get).and_return(response('data' => []))

      expect { service.assigned_instagram_accounts('business-token') }
        .to raise_error(described_class::Error, 'No Instagram professional account was shared with this app')
    end

    it 'fails explicitly rather than silently truncating more than ten pages' do
      pages = 10.times.map do |index|
        response(
          'data' => [{ 'id' => "ig-#{index}" }],
          'paging' => { 'cursors' => { 'after' => "cursor-#{index}" }, 'next' => 'present' }
        )
      end
      allow(HTTParty).to receive(:get).and_return(*pages)

      expect { service.assigned_instagram_accounts('business-token') }
        .to raise_error(described_class::Error, /too many Instagram account pages/)
    end
  end
end
