# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AgentBots::ResponseProcessor do
  it 'does not force an AI reply after the conversation eligibility guard rejects it' do
    agent_bot = instance_double(
      AgentBot,
      text_segmentation_enabled: false,
      bot_provider: 'evo_ai_provider',
      message_signature: nil
    )
    payload = { conversation: { id: 123 } }
    conversation = instance_double(Conversation)
    response = instance_double(
      Net::HTTPResponse,
      code: '200',
      message: 'OK',
      body: {
        result: {
          artifacts: [{ parts: [{ type: 'text', text: 'must stay silent' }] }]
        }
      }.to_json
    )
    creator = instance_double(AgentBots::MessageCreator)

    allow(AgentBots::ConversationFinder).to receive(:new)
      .with(agent_bot, payload).and_return(instance_double(AgentBots::ConversationFinder, find_conversation: conversation))
    allow(AgentBots::MessageCreator).to receive(:new).with(agent_bot).and_return(creator)
    expect(creator).to receive(:create_bot_reply)
      .with('must stay silent', conversation, content_type: 'text', content_attributes: nil)
      .once
      .and_return(nil)

    described_class.new(agent_bot, payload).process(response)
  end
end
