# frozen_string_literal: true

# PostgreSQL is the correctness boundary for Evolution messages.upsert idempotency.
# Evolution message ids are unique only within an inbox, so a global source_id index
# would incorrectly suppress deliveries belonging to another WhatsApp connection.
class AddUniqueInboxSourceIdToMessages < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  INDEX_NAME = 'index_messages_on_inbox_id_and_source_id_unique'
  INDEX_PREDICATE = "source_id IS NOT NULL AND source_id <> ''"

  def up
    preflight_duplicate_identities!
    drop_invalid_index

    add_index :messages, %i[inbox_id source_id],
              unique: true,
              name: INDEX_NAME,
              where: INDEX_PREDICATE,
              algorithm: :concurrently,
              if_not_exists: true
  end

  def down
    remove_index :messages, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
  end

  private

  # This migration deliberately does not choose a winner or delete customer data.
  # Operators must inspect and reconcile duplicates before retrying the migration.
  # Only aggregate counts enter the exception, never source ids or message content.
  def preflight_duplicate_identities!
    result = select_one(<<~SQL.squish)
      SELECT COUNT(*) AS duplicate_groups,
             COALESCE(SUM(row_count - 1), 0) AS extra_rows
      FROM (
        SELECT COUNT(*) AS row_count
        FROM messages
        WHERE #{INDEX_PREDICATE}
        GROUP BY inbox_id, source_id
        HAVING COUNT(*) > 1
      ) duplicates
    SQL

    duplicate_groups = result.fetch('duplicate_groups').to_i
    return if duplicate_groups.zero?

    raise ActiveRecord::MigrationError,
          "Cannot create #{INDEX_NAME}: found #{duplicate_groups} duplicate identity group(s) " \
          "and #{result.fetch('extra_rows').to_i} extra row(s). No data was changed; " \
          'reconcile duplicates in a controlled maintenance operation, then retry.'
  end

  # CREATE INDEX CONCURRENTLY can leave an INVALID index after interruption.
  # Removing only that invalid artifact makes retries safe without touching rows.
  def drop_invalid_index
    invalid = select_value(<<~SQL.squish)
      SELECT 1
      FROM pg_class index_class
      JOIN pg_index index_state ON index_state.indexrelid = index_class.oid
      WHERE index_class.relname = #{quote(INDEX_NAME)}
        AND NOT index_state.indisvalid
    SQL
    return if invalid.blank?

    execute "DROP INDEX CONCURRENTLY IF EXISTS #{quote_column_name(INDEX_NAME)}"
  end
end
