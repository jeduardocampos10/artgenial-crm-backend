require 'rails_helper'

RSpec.describe 'Widget contact identification conflict', type: :request do
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://conflict.example.test') }
  let(:inbox) { Inbox.create!(name: 'Conflict widget', channel: channel) }
  let(:current) { Contact.create!(name: 'Current') }
  let(:target) { Contact.create!(name: 'Target', email: 'private-widget@example.test') }
  let(:contact_inbox) do
    ContactInbox.create!(inbox: inbox, contact: current, source_id: SecureRandom.hex(8))
  end

  it 'returns a safe 422 on update and set_user without changing the widget session' do
    ContactIdentity.create!(contact: target, identity_type: 'external_id', provider: 'crm',
                            external_id: 'protected-widget', valid_from: Time.current)
    token = Widget::TokenService.new(payload: { inbox_id: inbox.id, source_id: contact_inbox.source_id }).generate_token
    headers = { 'X-Auth-Token' => token }

    ['/api/v1/widget/contact', '/api/v1/widget/contact/set_user'].each do |path|
      patch path, params: { website_token: channel.website_token, email: target.email, name: 'Changed' },
                  headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include('requires review')
      expect(response.body).not_to include(target.email, target.id, current.id, 'protected-widget')
      expect(current.reload.name).to eq('Current')
      expect(contact_inbox.reload.contact_id).to eq(current.id)
    end
  end

  it 'rolls back the submitted email when an input-email message hits a protected contact' do
    ContactIdentity.create!(contact: target, identity_type: 'external_id', provider: 'crm',
                            external_id: 'protected-message', valid_from: Time.current)
    conversation = create(:conversation, inbox: inbox, contact: current, contact_inbox: contact_inbox)
    message = create(:message, conversation: conversation, inbox: inbox,
                               message_type: :template, content_type: 'input_email')
    token = Widget::TokenService.new(payload: { inbox_id: inbox.id, source_id: contact_inbox.source_id }).generate_token

    patch "/api/v1/widget/messages/#{message.id}",
          params: { website_token: channel.website_token, contact: { email: target.email } },
          headers: { 'X-Auth-Token' => token }, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).not_to include(target.email, target.id, current.id, 'protected-message')
    expect(message.reload.submitted_email).to be_blank
    expect(contact_inbox.reload.contact_id).to eq(current.id)
  end
end
