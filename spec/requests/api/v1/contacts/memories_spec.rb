# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'GET /api/v1/contacts/:contact_id/memories', type: :request do
  let(:user) { User.create!(name: 'Memory reader', email: "memory-reader-#{SecureRandom.hex(4)}@example.com") }
  let(:contact) { Contact.create!(name: 'Customer', email: "customer-#{SecureRandom.hex(4)}@example.com") }

  def create_memory(contact:, kind: 'fact', observed_at: Time.utc(2026, 11, 5, 10), key: SecureRandom.uuid,
                    category: 'profile', value: { 'preference' => 'email' })
    attributes = {
      contact: contact,
      scope: 'person',
      category: category,
      semantic_key: key,
      kind: kind,
      value: value,
      observed_at: observed_at
    }
    attributes[:confidence] = 0.8 if kind == 'inference'
    MemoryRecord.create!(attributes)
  end

  def json_response
    response.parsed_body
  end

  def get_memories(target = contact, params: {})
    get "/api/v1/contacts/#{target.id}/memories", params: params, as: :json
  end

  def authenticate_as(authorized: true)
    spec = self
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = spec.user
      Current.service_authenticated = false
      true
    end
    allow_any_instance_of(Api::BaseController).to receive(:has_user_permission?)
      .with(user.id, 'contacts.read').and_return(authorized)
  end

  after { Current.reset }

  context 'with an authenticated user holding contacts.read' do
    before { authenticate_as }

    it 'omits unclassified content and nested sensitive values through an explicit whitelist' do
      secret_marker = 'synthetic-secret-must-not-leak'
      email_marker = 'sensitive-person@example.test'
      memory = create_memory(
        contact: contact,
        key: "semantic-key-#{email_marker}",
        category: "category-#{secret_marker}",
        value: {
          'profile' => { 'email' => email_marker, 'nested' => { 'note' => secret_marker } },
          'arbitrary' => ['unclassified', { 'detail' => secret_marker }]
        }
      )
      MemoryEvidence.create!(memory_record: memory, source_system: 'crm', source_type: 'Note',
                             source_id: SecureRandom.uuid, observed_at: memory.observed_at,
                             metadata: { 'internal' => 'do-not-expose' })

      get_memories

      expect(response).to have_http_status(:ok)
      item = json_response.fetch('data').fetch(0)
      expect(item).to include('id', 'scope', 'kind', 'status', 'review_status', 'confidence', 'observed_at',
                              'valid_from', 'valid_until', 'evidence_count')
      expect(item).not_to include('value', 'category', 'semantic_key', 'metadata', 'extractor', 'model_version',
                                  'actor_id', 'reviewed_by_id', 'memory_evidences')
      expect(item.fetch('evidence_count')).to eq(1)
      expect(response.body).not_to include(secret_marker, email_marker, 'do-not-expose')
    end

    it 'distinguishes facts and inferences using persisted model fields' do
      fact = create_memory(contact: contact, kind: 'fact', observed_at: Time.utc(2026, 11, 5, 11))
      inference = create_memory(contact: contact, kind: 'inference', observed_at: Time.utc(2026, 11, 5, 12))

      get_memories

      result = json_response.fetch('data').index_by { |item| item.fetch('id') }
      expect(result.fetch(fact.id).slice('kind', 'confidence')).to eq('kind' => 'fact', 'confidence' => nil)
      expect(result.fetch(inference.id).fetch('kind')).to eq('inference')
      expect(result.fetch(inference.id).fetch('confidence').to_f).to eq(0.8)
    end

    it 'returns an empty collection for a contact without memories' do
      get_memories

      expect(response).to have_http_status(:ok)
      expect(json_response.fetch('data')).to eq([])
    end

    it 'orders by observed_at descending with id as a deterministic tie-breaker' do
      older = create_memory(contact: contact, observed_at: Time.utc(2026, 11, 5, 9))
      same_time_first = create_memory(contact: contact, observed_at: Time.utc(2026, 11, 5, 10))
      same_time_second = create_memory(contact: contact, observed_at: Time.utc(2026, 11, 5, 10))

      get_memories

      expect(json_response.fetch('data').map { |item| item.fetch('id') })
        .to eq([same_time_first.id, same_time_second.id].sort.reverse + [older.id])
    end

    it 'paginates and caps the requested page size' do
      3.times { |index| create_memory(contact: contact, observed_at: Time.utc(2026, 11, 5, 10, index)) }

      get_memories(params: { page: 2, pageSize: 2 })

      expect(json_response.fetch('data').size).to eq(1)
      pagination = json_response.dig('meta', 'pagination')
      expect(pagination).to include('page' => 2, 'page_size' => 2, 'total' => 3, 'total_pages' => 2)

      get_memories(params: { pageSize: 10_000 })
      expect(json_response.dig('meta', 'pagination', 'page_size')).to eq(100)
    end

    it 'uses documented defaults for malformed or non-positive pagination values' do
      2.times { |index| create_memory(contact: contact, observed_at: Time.utc(2026, 11, 5, 10, index)) }

      get_memories(params: { page: 'not-a-page', pageSize: 'not-a-size' })

      expect(response).to have_http_status(:ok)
      expect(json_response.dig('meta', 'pagination')).to include('page' => 1, 'page_size' => 20)

      get_memories(params: { page: 0, pageSize: 0 })

      expect(response).to have_http_status(:ok)
      expect(json_response.dig('meta', 'pagination')).to include('page' => 1, 'page_size' => 20)
    end

    it 'does not read or mutate memories belonging to another contact' do
      other_contact = Contact.create!(name: 'Other', email: "other-#{SecureRandom.hex(4)}@example.com")
      own_memory = create_memory(contact: contact)
      other_memory = create_memory(contact: other_contact)

      expect { get_memories }.not_to change { MemoryRecord.count }
      ids = json_response.fetch('data').map { |item| item.fetch('id') }
      expect(ids).to include(own_memory.id)
      expect(ids).not_to include(other_memory.id)
    end
  end

  context 'without authentication' do
    it 'returns 401 before resolving the contact' do
      expect(Contact).not_to receive(:find)

      get_memories

      expect(response).to have_http_status(:unauthorized)
    end
  end

  context 'with authentication but without contacts.read' do
    before { authenticate_as(authorized: false) }

    it 'returns 403 and does not mutate memory records' do
      create_memory(contact: contact)

      expect(Contact).not_to receive(:find)
      expect { get_memories }.not_to change { MemoryRecord.count }
      expect(response).to have_http_status(:forbidden)

      expect(Contact).not_to receive(:find)
      get "/api/v1/contacts/#{SecureRandom.uuid}/memories", as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end

  context 'when the contact does not exist' do
    before { authenticate_as }

    it 'returns 404' do
      get "/api/v1/contacts/#{SecureRandom.uuid}/memories", as: :json

      expect(response).to have_http_status(:not_found)
    end
  end
end
