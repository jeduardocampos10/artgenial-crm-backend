# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Evolution::AuthorizationsController, type: :controller do
  it 'uses global credentials and returns connection metadata without upstream secrets' do
    controller_instance = described_class.new
    controller_instance.params = ActionController::Parameters.new(
      authorization: { instance_name: 'support', phone_number: '+5511999999999' }
    )
    allow(GlobalConfigService).to receive(:load).with('EVOLUTION_API_URL', '').and_return('https://internal.example')
    allow(GlobalConfigService).to receive(:load).with('EVOLUTION_ADMIN_SECRET', '').and_return('server-only-secret')
    allow(controller_instance).to receive(:check_server_status).with('https://internal.example').and_return({})
    allow(controller_instance).to receive(:check_and_delete_existing_instance)
    expect(controller_instance).to receive(:create_instance).with(
      'https://internal.example', 'server-only-secret', 'support', '+5511999999999', anything
    ).and_return(
      'hash' => 'upstream-api-key',
      'instance' => { 'instanceName' => 'support', 'status' => 'created', 'token' => 'nested-secret' }
    )
    expect(controller_instance).to receive(:success_response) do |data:, message:|
      expect(data[:instance]).to eq('instanceName' => 'support', 'status' => 'created')
      expect(data.to_json).not_to include('secret', 'upstream-api-key', 'internal.example')
      expect(message).to eq('Instance created successfully')
    end
    controller_instance.create
  end
end
