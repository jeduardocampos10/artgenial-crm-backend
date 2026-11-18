# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Instagram::IntegrationHelper do
  subject(:helper) do
    Class.new do
      include Instagram::IntegrationHelper
    end.new
  end

  let(:user) { instance_double(User, id: 'user-1') }
  let(:redirect_uri) { 'https://crm.example.com/instagram/callback' }

  before do
    Current.user = user
    allow(GlobalConfigService).to receive(:load).with('INSTAGRAM_APP_SECRET', nil).and_return('state-secret')
  end

  after do
    Current.reset
  end

  it 'creates a short-lived state bound to the user, callback and login mode' do
    token = helper.generate_instagram_token('community', mode: 'unified_login', redirect_uri: redirect_uri)
    payload = helper.verify_instagram_state(token, redirect_uri: redirect_uri)

    expect(payload).to include(
      'sub' => 'community',
      'user_id' => 'user-1',
      'mode' => 'unified_login',
      'redirect_uri' => redirect_uri
    )
    expect(payload['jti']).to be_present
    expect(payload['exp'] - payload['iat']).to eq(10.minutes.to_i)
  end

  it 'rejects state replayed by another authenticated user' do
    token = helper.generate_instagram_token('community', mode: 'unified_login', redirect_uri: redirect_uri)
    Current.user = instance_double(User, id: 'user-2')

    expect(helper.verify_instagram_state(token, redirect_uri: redirect_uri)).to be_nil
  end

  it 'rejects a state for a different callback URI' do
    token = helper.generate_instagram_token('community', mode: 'unified_login', redirect_uri: redirect_uri)

    expect(helper.verify_instagram_state(token, redirect_uri: 'https://attacker.example/callback')).to be_nil
  end
end
