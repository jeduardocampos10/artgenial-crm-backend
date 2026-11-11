# frozen_string_literal: true

require 'rails_helper'
require_relative '../../db/migrate/20261028120000_add_unique_inbox_source_id_to_messages'

RSpec.describe AddUniqueInboxSourceIdToMessages, type: :migration do
  let(:migration) { described_class.new.tap { |instance| instance.verbose = false } }
  let(:connection) { double('migration connection') }

  describe '#up' do
    before do
      allow(migration).to receive(:connection).and_return(connection)
      allow(migration).to receive(:drop_invalid_index)
      allow(connection).to receive(:add_index)
    end

    it 'builds a concurrent partial unique index scoped by inbox' do
      allow(connection).to receive(:select_one).and_return(
        'duplicate_groups' => '0',
        'extra_rows' => '0'
      )

      migration.up

      expect(connection).to have_received(:add_index) do |table, columns, **options|
        expect(table).to eq('messages')
        expect(columns).to eq(%i[inbox_id source_id])
        expect(options).to eq(
          unique: true,
          name: described_class::INDEX_NAME,
          where: described_class::INDEX_PREDICATE,
          algorithm: :concurrently,
          if_not_exists: true
        )
      end
    end

    it 'aborts on duplicate identities without deleting or rewriting data' do
      allow(connection).to receive(:select_one).and_return(
        'duplicate_groups' => '2',
        'extra_rows' => '3'
      )
      allow(connection).to receive(:execute)

      expect { migration.up }
        .to raise_error(ActiveRecord::MigrationError, /2 duplicate identity group.*3 extra row/m)
      expect(connection).not_to have_received(:add_index)
      expect(connection).not_to have_received(:execute)
    end
  end
end
