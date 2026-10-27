require 'rails_helper'

RSpec.describe 'Customer memory foundation', type: :model do
  let(:person) { Contact.create!(name: 'Person', type: 'person') }
  let(:other_person) { Contact.create!(name: 'Other', type: 'person') }
  let(:company) { Contact.create!(name: 'Company', type: 'company') }
  let(:now) { Time.current }
  let(:evidence) { { source_type: 'Note', source_id: SecureRandom.uuid } }

  def fact(contact: person, key: 'preference', value: { 'channel' => 'email' }, key_id: SecureRandom.uuid)
    CustomerMemory::Record.call(contact: contact, scope: contact.company? ? 'company' : 'person',
                                category: 'communication', semantic_key: key, kind: 'fact', value: value,
                                evidence: evidence, idempotency_key: key_id, source_system: 'crm', observed_at: now)
  end

  it 'keeps multiple scoped identities for one contact without resolving a conflict by merge' do
    first = ContactIdentity.create!(contact: person, identity_type: 'phone', provider: 'crm',
                                    normalized_value: '+12025550101', valid_from: now)
    second = ContactIdentity.create!(contact: person, identity_type: 'email', provider: 'crm',
                                     normalized_value: 'p@example.test', valid_from: now)
    expect(person.contact_identities.count).to eq(2)
    expect(ContactIdentities::Resolve.call(identity_type: 'phone', provider: 'crm',
                                          normalized_value: first.normalized_value).contact).to eq(person)
    conflict = ContactIdentities::Resolve.call(identity_type: 'email', provider: 'crm',
                                               normalized_value: second.normalized_value, contact: other_person,
                                               idempotency_key: SecureRandom.uuid)
    expect(conflict.status).to eq(:conflict)
    expect(conflict.candidate_contact_ids).to eq([person.id])
    expect(Contact.exists?(person.id)).to be true
    expect(Contact.exists?(other_person.id)).to be true
    expect(CustomerEvent.where(event_type: 'identity.conflict', contact: other_person).count).to eq(1)
  end

  it 'keeps identities unique only inside provider and inbox scope' do
    ContactIdentity.create!(contact: person, identity_type: 'external_id', provider: 'a',
                            external_id: 'same', valid_from: now)
    expect(ContactIdentity.new(contact: other_person, identity_type: 'external_id', provider: 'b',
                               external_id: 'same', valid_from: now)).to be_valid
    expect do
      ContactIdentity.transaction(requires_new: true) do
        ContactIdentity.create!(contact: other_person, identity_type: 'external_id', provider: 'a',
                                external_id: 'same', valid_from: now)
      end
    end.to raise_error(ActiveRecord::RecordNotUnique)
    channel = Channel::WebWidget.create!(website_url: 'https://identity.example.test')
    first_inbox = Inbox.create!(name: 'One', channel: channel)
    second_channel = Channel::WebWidget.create!(website_url: 'https://other-identity.example.test')
    second_inbox = Inbox.create!(name: 'Two', channel: second_channel)
    ContactIdentity.create!(contact: person, identity_type: 'webchat', provider: 'widget',
                            external_id: 'visitor-1', inbox: first_inbox, valid_from: now)
    ContactIdentity.create!(contact: other_person, identity_type: 'webchat', provider: 'widget',
                            external_id: 'visitor-1', inbox: second_inbox, valid_from: now)
  end

  it 'normalizes email consistently in model, resolve and register without merging contacts' do
    identity = ContactIdentity.create!(contact: person, identity_type: 'email', provider: 'crm',
                                       normalized_value: ' MARIA@EMAIL.COM ', valid_from: now)
    expect(identity.reload.normalized_value).to eq('maria@email.com')
    ['maria@email.com', 'MARIA@EMAIL.COM', ' maria@email.com '].each do |value|
      result = ContactIdentities::Resolve.call(identity_type: 'email', provider: 'crm', normalized_value: value)
      expect(result.status).to eq(:found)
      expect(result.identity).to eq(identity)
    end
    expect(ContactIdentities::Resolve.call(identity_type: 'email', provider: 'other',
                                           normalized_value: 'MARIA@EMAIL.COM').status).to eq(:missing)
    channel = Channel::WebWidget.create!(website_url: 'https://scoped-email.example.test')
    inbox = Inbox.create!(name: 'Scoped', channel: channel)
    expect(ContactIdentities::Resolve.call(identity_type: 'email', provider: 'crm', inbox: inbox,
                                           normalized_value: 'MARIA@EMAIL.COM').status).to eq(:missing)
    conflict = ContactIdentities::Register.call(contact: other_person, identity_type: 'email', provider: 'crm',
                                                normalized_value: ' MARIA@EMAIL.COM ', idempotency_key: SecureRandom.uuid)
    expect(conflict.status).to eq(:conflict)
    expect(Contact.exists?(person.id)).to be(true)
    expect(Contact.exists?(other_person.id)).to be(true)
    expect(ContactIdentity.where(identity_type: 'email', provider: 'crm').count).to eq(1)
    external = ContactIdentities::Register.call(contact: other_person, identity_type: 'external_id',
                                                provider: 'crm', external_id: 'MixedCase-42', idempotency_key: SecureRandom.uuid)
    expect(external.status).to eq(:created)
    expect(ContactIdentities::Resolve.call(identity_type: 'external_id', provider: 'crm',
                                           external_id: 'mixedcase-42').status).to eq(:missing)
  end

  it 'does not report missing when a primary identity slot rejects registration' do
    ContactIdentity.create!(contact: person, identity_type: 'email', provider: 'crm',
                            normalized_value: 'first@example.test', valid_from: now, is_primary: true)
    expect do
      ContactIdentities::Register.call(contact: person, identity_type: 'email', provider: 'crm',
                                       normalized_value: 'second@example.test', is_primary: true,
                                       idempotency_key: SecureRandom.uuid)
    end.to raise_error(ActiveRecord::RecordNotUnique)
    expect(person.contact_identities.count).to eq(1)
  end

  it 'reuses equivalent evidence, rejects divergent retries, and keeps distinct observations' do
    memory = fact
    event_evidence = memory.memory_evidences.first
    expect(CustomerMemory::AttachEvidence.call(memory_record: memory,
                                                source_system: event_evidence.source_system,
                                                source_type: event_evidence.source_type,
                                                source_id: event_evidence.source_id,
                                                observed_at: event_evidence.observed_at,
                                                customer_event: event_evidence.customer_event)).to eq(event_evidence)
    source_id = SecureRandom.uuid
    args = { memory_record: memory, source_system: 'crm', source_type: 'Note', source_id: source_id,
             observed_at: now, locator: 'line-1', metadata: { 'origin' => 'manual' } }
    attached = CustomerMemory::AttachEvidence.call(**args)
    expect(CustomerMemory::AttachEvidence.call(**args)).to eq(attached)
    expect do
      CustomerMemory::AttachEvidence.call(**args.merge(metadata: { 'origin' => 'other' }))
    end.to raise_error(CustomerMemory::AttachEvidence::IdempotencyConflict)
    expect(CustomerMemory::AttachEvidence.call(**args.merge(locator: 'line-2'))).not_to eq(attached)
    expect(CustomerMemory::AttachEvidence.call(**args.merge(observed_at: now + 1.second))).not_to eq(attached)
    expect do
      MemoryEvidence.transaction(requires_new: true) do
        MemoryEvidence.create!(memory_record: memory, source_system: 'crm', source_type: 'Note',
                               source_id: source_id, observed_at: now, locator: 'line-1')
      end
    end.to raise_error(ActiveRecord::RecordNotUnique)
    expect(memory.memory_evidences.where(source_id: source_id).count).to eq(3)
  end

  it 'rolls back an earlier merge when a later identity match is protected' do
    current = person
    email_match = Contact.create!(name: 'Email match', email: 'email-match@example.test')
    phone_match = Contact.create!(name: 'Phone match', phone_number: '+12025550119')
    identity = ContactIdentity.create!(contact: phone_match, identity_type: 'external_id', provider: 'crm',
                                       external_id: 'protected', valid_from: now)
    memory = fact(contact: phone_match)
    user = User.create!(email: 'rollback-test@example.test', name: 'Rollback Test')
    pipeline = Pipeline.create!(name: 'Rollback test pipeline', pipeline_type: Pipeline::VALID_TYPES.first, created_by: user)
    stage = PipelineStage.create!(pipeline: pipeline, name: 'Rollback test stage', position: 1)
    item = PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, contact: phone_match)
    expect do
      ContactIdentifyAction.new(contact: current, params: { email: email_match.email,
                                                            phone_number: phone_match.phone_number }).perform
    end.to raise_error(ContactMergeAction::MergeBlocked)
    expect(Contact.exists?(current.id)).to be(true)
    expect(Contact.exists?(email_match.id)).to be(true)
    expect(Contact.exists?(phone_match.id)).to be(true)
    expect(email_match.reload.email).to eq('email-match@example.test')
    expect(identity.reload.contact_id).to eq(phone_match.id)
    expect(memory.reload.contact_id).to eq(phone_match.id)
    expect(item.reload.contact_id).to eq(phone_match.id)
  end

  it 'restricts company deletion while retaining person/company N:N links' do
    link = ContactCompany.create!(contact: person, company: company)
    expect { company.destroy! }.to raise_error(ActiveRecord::DeleteRestrictionError)
    expect(link.reload.company_id).to eq(company.id)
    expect(person.companies).to include(company)
  end

  it 'supports person/company N:N without changing the old link API' do
    second_company = Contact.create!(name: 'Second company', type: 'company')
    ContactCompany.create!(contact: person, company: company, commercial_role: 'decision_maker')
    ContactCompany.create!(contact: person, company: second_company)
    ContactCompany.create!(contact: other_person, company: company)
    expect(person.companies.count).to eq(2)
    expect(company.comp_contacts.count).to eq(2)
    expect(ContactCompany.find_by!(contact: person, company: company).status).to eq('active')
    relationship = ContactCompany.find_by!(contact: person, company: company)
    memory = MemoryRecord.create!(contact: person, contact_company: relationship, scope: 'relationship',
                                  category: 'role', semantic_key: 'commercial_role', kind: 'fact',
                                  value: { 'role' => 'decision_maker' }, observed_at: now)
    expect(memory.contact_company).to eq(relationship)
  end

  it 'rejects credential-shaped metadata and event payload keys' do
    memory = MemoryRecord.new(contact: person, scope: 'person', category: 'profile', semantic_key: 'note',
                              kind: 'fact', value: {}, observed_at: now,
                              metadata: { 'access_token' => 'placeholder' })
    expect(memory).not_to be_valid
    event = CustomerEvent.new(contact: person, event_type: 'sample', source_system: 'crm',
                              idempotency_key: SecureRandom.uuid, occurred_at: now, recorded_at: now,
                              payload: { 'password' => 'placeholder' })
    expect(event).not_to be_valid
  end

  it 'separates fact and inference and requires confidence only for inference' do
    recorded = fact
    inferred = MemoryRecord.create!(contact: company, scope: 'company', category: 'profile',
                                    semantic_key: 'size', kind: 'inference', value: { 'range' => 'small' },
                                    confidence: 0.7, observed_at: now)
    expect(recorded.confidence).to be_nil
    expect(inferred.confidence.to_f).to eq(0.7)
    expect(inferred.review_status).to eq('pending')
    expect(recorded.memory_evidences.count).to eq(1)
    CustomerMemory::AttachEvidence.call(memory_record: recorded, source_system: 'crm', source_type: 'Conversation',
                                        source_id: SecureRandom.uuid, observed_at: now)
    expect(recorded.memory_evidences.count).to eq(2)
    expect(MemoryRecord.new(contact: person, scope: 'person', category: 'x', semantic_key: 'y',
                            kind: 'fact', value: {}, confidence: 0.5, observed_at: now)).not_to be_valid
  end

  it 'supersedes transactionally, preserves history, and refuses unreviewed inference over fact' do
    previous = fact
    expect do
      CustomerMemory::Supersede.call(previous: previous, kind: 'inference', value: { 'channel' => 'chat' },
                                    evidence: evidence, idempotency_key: SecureRandom.uuid,
                                    source_system: 'crm', observed_at: now, confidence: 0.8)
    end.to raise_error(CustomerMemory::Supersede::UnsafeReplacement)
    expect(previous.reload.status).to eq('active')
    key = SecureRandom.uuid
    replacement = CustomerMemory::Supersede.call(previous: previous, kind: 'fact', value: { 'channel' => 'chat' },
                                                evidence: evidence, idempotency_key: key,
                                                source_system: 'crm', observed_at: now)
    expect(previous.reload.status).to eq('superseded')
    expect(previous.value).to eq('channel' => 'email')
    expect(replacement.supersedes).to eq(previous)
    expect(CustomerMemory::Supersede.call(previous: previous, kind: 'fact', value: replacement.value,
                                          evidence: evidence, idempotency_key: key,
                                          source_system: 'crm', observed_at: now)).to eq(replacement)
  end

  it 'records an append-only event and one outbox envelope per idempotency key' do
    key = SecureRandom.uuid
    correlation = SecureRandom.uuid
    causation = SecureRandom.uuid
    args = { contact: person, event_type: 'memory.checked', source_system: 'crm',
             idempotency_key: key, occurred_at: now, correlation_id: correlation,
             causation_id: causation, payload: { ref: person.id } }
    event = CustomerEvents::Record.call(**args)
    expect(CustomerEvents::Record.call(**args)).to eq(event)
    expect(event.event_outboxes.count).to eq(1)
    expect(event.correlation_id).to eq(correlation)
    expect(event.causation_id).to eq(causation)
    expect { event.update!(event_type: 'changed') }.to raise_error(ActiveRecord::ReadOnlyError)
    expect { event.destroy! }.to raise_error(ActiveRecord::ReadOnlyError)
    expect { CustomerEvents::Record.call(**args.merge(event_type: 'other')) }
      .to raise_error(CustomerEvents::Record::IdempotencyConflict)
  end

  it 'rolls back event and outbox when a memory write fails' do
    key = SecureRandom.uuid
    expect do
      expect do
        CustomerMemory::Record.call(contact: person, scope: 'person', category: 'x', semantic_key: 'y',
                                    kind: 'fact', confidence: 0.8, value: {}, evidence: evidence,
                                    idempotency_key: key, source_system: 'crm', observed_at: now)
      end.to raise_error(ActiveRecord::RecordInvalid)
    end.not_to change(CustomerEvent, :count)
    expect(EventOutbox.where(customer_event_id: CustomerEvent.where(idempotency_key: key).select(:id))).to be_empty
  end

  it 'rejects reuse of a memory idempotency key for a different relationship' do
    first_link = ContactCompany.create!(contact: person, company: company)
    another_company = Contact.create!(name: 'Another company', type: 'company')
    second_link = ContactCompany.create!(contact: person, company: another_company)
    args = { contact: person, scope: 'relationship', category: 'role', semantic_key: 'function',
             kind: 'fact', value: { 'role' => 'user' }, evidence: evidence,
             idempotency_key: SecureRandom.uuid, source_system: 'crm', observed_at: now }
    original = CustomerMemory::Record.call(**args, contact_company: first_link)
    expect do
      CustomerMemory::Record.call(**args, contact_company: second_link)
    end.to raise_error(CustomerEvents::Record::IdempotencyConflict)
    expect(MemoryRecord.where(contact: person, scope: 'relationship').count).to eq(1)
    expect(original.reload.contact_company_id).to eq(first_link.id)
  end

  it 'blocks legacy merges that would lose a lead card, identity, relationship or memory' do
    base = person
    mergee = other_person
    ContactIdentity.create!(contact: mergee, identity_type: 'email', provider: 'crm',
                            normalized_value: 'other@example.test', valid_from: now)
    expect { ContactMergeAction.new(base_contact: base, mergee_contact: mergee).perform }
      .to raise_error(ContactMergeAction::MergeBlocked)
    expect(Contact.exists?(mergee.id)).to be true
    expect(mergee.contact_identities.count).to eq(1)
  end

  it 'does not lose a PipelineItem during merge' do
    mergee = other_person
    user = User.create!(email: 'memory-test@example.test', name: 'Memory Test')
    pipeline = Pipeline.create!(name: 'Transient test pipeline', pipeline_type: Pipeline::VALID_TYPES.first, created_by: user)
    stage = PipelineStage.create!(pipeline: pipeline, name: 'Transient test stage', position: 1)
    item = PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, contact: mergee)
    expect { ContactMergeAction.new(base_contact: person, mergee_contact: mergee).perform }
      .to raise_error(ContactMergeAction::MergeBlocked)
    expect(item.reload.contact_id).to eq(mergee.id)
    expect(Contact.exists?(mergee.id)).to be true
  end

  it 'does not lose evidence, events or relationship memory during merge' do
    mergee = other_person
    relationship = ContactCompany.create!(contact: mergee, company: company)
    memory = MemoryRecord.create!(contact: mergee, contact_company: relationship, scope: 'relationship',
                                  category: 'role', semantic_key: 'role', kind: 'fact',
                                  value: { 'role' => 'user' }, observed_at: now)
    CustomerMemory::AttachEvidence.call(memory_record: memory, source_system: 'crm', source_type: 'Note',
                                        source_id: SecureRandom.uuid, observed_at: now)
    event = CustomerEvents::Record.call(contact: mergee, event_type: 'sample', source_system: 'crm',
                                        idempotency_key: SecureRandom.uuid, occurred_at: now)
    expect { ContactMergeAction.new(base_contact: person, mergee_contact: mergee).perform }
      .to raise_error(ContactMergeAction::MergeBlocked)
    expect(memory.reload.memory_evidences.count).to eq(1)
    expect(CustomerEvent.exists?(event.id)).to be true
    expect(ContactCompany.exists?(relationship.id)).to be true
  end
end
