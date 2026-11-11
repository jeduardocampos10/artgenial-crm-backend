# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AgentBots::SegmentedMessageCreator do
  it 'never bypasses conversation eligibility, including with the legacy force option' do
    agent_bot = instance_double(AgentBot)
    conversation = instance_double(Conversation, id: 42, status: 'open')
    creator = described_class.new(agent_bot)

    allow(creator).to receive(:conversation_eligible_for_bot_reply?).with(conversation).and_return(false)
    expect(creator).not_to receive(:create_single_message)
    expect(creator).not_to receive(:process_segment_message)

    expect(creator.create_messages(['must stay silent'], conversation, force: true)).to be_nil
  end
end
