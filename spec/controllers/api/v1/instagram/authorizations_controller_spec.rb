# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Instagram::AuthorizationsController, type: :controller do
  subject(:controller_instance) { described_class.new }

  describe '#create' do
    before do
      allow(controller_instance).to receive(:instagram_redirect_uri)
        .and_return('https://crm.example.com/instagram/callback')
      allow(controller_instance).to receive(:generate_instagram_token)
        .and_return('signed-state')
    end

    it 'selects Unified Login when a login configuration ID is present' do
      service = instance_double(Instagram::UnifiedLoginService)
      allow(controller_instance).to receive(:unified_login_enabled?).and_return(true)
      allow(controller_instance).to receive(:unified_login_service).and_return(service)
      allow(service).to receive(:authorization_url).with(state: 'signed-state').and_return('https://www.facebook.com/dialog/oauth?...')

      expect(controller_instance).to receive(:render).with(
        json: { success: true, url: 'https://www.facebook.com/dialog/oauth?...' }
      )

      controller_instance.create
    end

    it 'preserves legacy Instagram Login when the configuration ID is absent' do
      allow(controller_instance).to receive(:unified_login_enabled?).and_return(false)
      allow(controller_instance).to receive(:legacy_authorization_url)
        .with('signed-state')
        .and_return('https://www.instagram.com/oauth/authorize?...')

      expect(controller_instance).to receive(:render).with(
        json: { success: true, url: 'https://www.instagram.com/oauth/authorize?...' }
      )

      controller_instance.create
    end
  end

  describe '#callback' do
    it 'uses the mode bound into the verified state and returns every connected channel' do
      controller_instance.params = ActionController::Parameters.new(code: 'one-time-code', state: 'signed-state')
      allow(controller_instance).to receive(:instagram_redirect_uri)
        .and_return('https://crm.example.com/instagram/callback')
      allow(controller_instance).to receive(:verify_instagram_state)
        .with('signed-state', redirect_uri: 'https://crm.example.com/instagram/callback')
        .and_return('mode' => 'unified_login')

      inbox_one = instance_double(Inbox, id: 'inbox-1')
      inbox_two = instance_double(Inbox, id: 'inbox-2')
      channel_one = instance_double(Channel::Instagram, id: 'channel-1', inbox: inbox_one)
      channel_two = instance_double(Channel::Instagram, id: 'channel-2', inbox: inbox_two)
      allow(channel_one).to receive(:reauthorized!)
      allow(channel_two).to receive(:reauthorized!)
      allow(controller_instance).to receive(:complete_unified_login)
        .with('one-time-code')
        .and_return([channel_one, channel_two])

      expect(controller_instance).to receive(:render).with(
        json: {
          success: true,
          inbox_id: 'inbox-1',
          channel_id: 'channel-1',
          inbox_ids: %w[inbox-1 inbox-2],
          channel_ids: %w[channel-1 channel-2]
        }
      )

      controller_instance.callback
    end
  end
end
