# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Instagram::RefreshOauthTokenService do
  describe '#access_token' do
    it 'returns a non-expiring Unified Login token without calling the legacy refresh endpoint' do
      channel = instance_double(
        Channel::Instagram,
        unified_login?: true,
        expires_at: nil
      )
      allow(channel).to receive(:[]).with(:access_token).and_return('business-token')
      allow(HTTParty).to receive(:get)

      token = described_class.new(channel: channel).access_token

      expect(token).to eq('business-token')
      expect(HTTParty).not_to have_received(:get)
    end

    it 'rejects an expired Unified Login token without invoking ig_refresh_token' do
      channel = instance_double(
        Channel::Instagram,
        unified_login?: true,
        expires_at: 1.minute.ago
      )
      allow(channel).to receive(:[]).with(:access_token).and_return('expired-token')
      allow(channel).to receive(:authorization_error!)
      allow(HTTParty).to receive(:get)

      expect(described_class.new(channel: channel).access_token).to be_nil
      expect(channel).to have_received(:authorization_error!)
      expect(HTTParty).not_to have_received(:get)
    end
  end
end
