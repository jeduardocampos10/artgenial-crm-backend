require 'rails_helper'

RSpec.describe 'Public contact identification conflict', type: :request do
  it 'returns a safe 422 and preserves both contacts when merge is blocked' do
    channel = Channel::Api.create!
    inbox = Inbox.create!(name: 'Isolated conflict inbox', channel: channel)
    current = Contact.create!(name: 'Current')
    target = Contact.create!(name: 'Target', email: 'private-person@example.test')
    contact_inbox = ContactInbox.create!(inbox: inbox, contact: current, source_id: SecureRandom.hex(8))
    identity = ContactIdentity.create!(contact: target, identity_type: 'external_id', provider: 'crm',
                                       external_id: 'protected-target', valid_from: Time.current)
    path = "/public/api/v1/inboxes/#{channel.identifier}/contacts/#{contact_inbox.source_id}"

    patch path, params: { email: target.email, name: 'Changed' }, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include('requires review')
    expect(response.body).not_to include(target.email, target.id, current.id, 'protected-target')
    expect(current.reload.name).to eq('Current')
    expect(contact_inbox.reload.contact_id).to eq(current.id)
    expect(identity.reload.contact_id).to eq(target.id)
    expect(Contact.exists?(current.id)).to be(true)
    expect(Contact.exists?(target.id)).to be(true)
  end
end
