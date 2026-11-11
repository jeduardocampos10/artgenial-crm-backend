# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::EvolutionHandlers::MessagesUpsert do
  let(:inbox) { instance_double(Inbox, id: 'inbox-1') }
  let(:params) { { event: 'messages.upsert', data: { key: { id: 'evo.race' } } } }
  let(:host) { Whatsapp::IncomingMessageEvolutionService.new(inbox: inbox, params: params) }
  let(:fake_alfred) { {} }

  before do
    allow(Redis::Alfred).to receive(:set) do |key, value, nx:, ex:|
      expect(nx).to be(true)
      expect(ex).to eq(described_class::EVOLUTION_MESSAGE_GUARD_TTL)
      next false if fake_alfred.key?(key)

      fake_alfred[key] = value
      'OK'
    end
    allow(Redis::Alfred).to receive(:delete_if_value) do |key, value|
      fake_alfred.delete(key) if fake_alfred[key] == value
    end

    host.send(:processed_params)
    host.instance_variable_set(:@raw_message, params[:data])
    allow(host).to receive(:message_type).and_return('text')
    allow(host).to receive(:message_processable?).and_return(true)
    allow(host).to receive(:raw_message_id).and_return('evo.race')
    allow(host).to receive(:find_evolution_message_by_source_id).and_return(nil)
  end

  describe 'the Redis contention guard' do
    it 'acquires the inbox-scoped lease with one atomic SET NX EX' do
      expect(host.send(:acquire_evolution_message_guard)).to be(true)

      expect(Redis::Alfred).to have_received(:set).with(
        host.send(:evolution_message_guard_key),
        kind_of(String),
        nx: true,
        ex: described_class::EVOLUTION_MESSAGE_GUARD_TTL
      ).once
    end

    it 'does not acquire an identity already owned by another worker' do
      expect(host.send(:acquire_evolution_message_guard)).to be(true)
      contender = Whatsapp::IncomingMessageEvolutionService.new(inbox: inbox, params: params)
      contender.instance_variable_set(:@raw_message, params[:data])
      allow(contender).to receive(:raw_message_id).and_return('evo.race')

      expect(contender.send(:acquire_evolution_message_guard)).to be(false)
    end

    it 'does not collide when two inboxes receive the same provider source id' do
      expect(host.send(:acquire_evolution_message_guard)).to be(true)
      other_inbox = instance_double(Inbox, id: 'inbox-2')
      other = Whatsapp::IncomingMessageEvolutionService.new(inbox: other_inbox, params: params)
      other.instance_variable_set(:@raw_message, params[:data])
      allow(other).to receive(:raw_message_id).and_return('evo.race')

      expect(other.send(:acquire_evolution_message_guard)).to be(true)
      expect(fake_alfred.keys.length).to eq(2)
    end

    it 'fails open when Redis is unavailable because PostgreSQL is authoritative' do
      allow(Redis::Alfred).to receive(:set).and_raise(Redis::CannotConnectError)

      expect(host.send(:acquire_evolution_message_guard)).to be(true)
      expect(host.instance_variable_get(:@evolution_message_guard)).to be_nil
    end

    it 'releases only its own token when processing raises' do
      allow(host).to receive(:set_contact).and_raise(ActiveRecord::RecordInvalid)

      expect { host.send(:handle_message) }.to raise_error(ActiveRecord::RecordInvalid)
      expect(fake_alfred).to be_empty
      expect(Redis::Alfred).to have_received(:delete_if_value).once
    end

    it 'leaves an existing guard untouched when acquisition fails' do
      expect(host.send(:acquire_evolution_message_guard)).to be(true)
      existing = fake_alfred.dup

      expect(host.send(:handle_message)).to be_nil
      expect(fake_alfred).to eq(existing)
    end
  end

  describe 'PostgreSQL idempotency fallback' do
    it 'looks up an existing message by inbox and source id' do
      allow(host).to receive(:find_evolution_message_by_source_id).and_call_original
      allow(Message).to receive(:find_by)

      host.send(:find_evolution_message_by_source_id)

      expect(Message).to have_received(:find_by).with(inbox_id: 'inbox-1', source_id: 'evo.race')
    end

    it 'treats RecordNotUnique as a redelivery only when that scoped message now exists' do
      duplicate = instance_double(Message)
      pending = instance_double(Message)
      host.instance_variable_set(:@message, pending)
      allow(pending).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique)
      allow(host).to receive(:find_evolution_message_by_source_id).and_return(duplicate)

      expect { host.send(:save_message_and_notify) }.not_to raise_error
      expect(host.instance_variable_get(:@message)).to eq(duplicate)
    end

    it 're-raises RecordNotUnique from an unrelated constraint' do
      pending = instance_double(Message)
      host.instance_variable_set(:@message, pending)
      allow(pending).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique)
      allow(host).to receive(:find_evolution_message_by_source_id).and_return(nil)

      expect { host.send(:save_message_and_notify) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
