# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Channel::Instagram do
  describe '#graph_api_base_url' do
    before do
      allow(MetaBaseUrl).to receive(:enabled?).and_return(false)
      allow(GlobalConfigService).to receive(:load)
        .with('INSTAGRAM_API_VERSION', 'v23.0')
        .and_return('v23.0')
    end

    it 'keeps legacy Instagram Login traffic on graph.instagram.com' do
      channel = described_class.new(auth_mode: 'instagram_login')

      expect(channel.graph_api_base_url).to eq('https://graph.instagram.com/v23.0')
    end

    it 'uses graph.facebook.com for Unified Login business tokens' do
      channel = described_class.new(auth_mode: 'unified_login')

      expect(channel.graph_api_base_url).to eq('https://graph.facebook.com/v23.0')
    end

    it 'keeps the existing Hub proxy when Hub mode is enabled' do
      allow(MetaBaseUrl).to receive(:enabled?).and_return(true)
      allow(MetaBaseUrl).to receive(:for).with(:instagram).and_return('https://hub.example/meta')

      channel = described_class.new(auth_mode: 'unified_login')

      expect(channel.graph_api_base_url).to eq('https://hub.example/meta')
    end
  end
end
