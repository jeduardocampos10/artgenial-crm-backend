class CreateCustomerMemoryFoundation < ActiveRecord::Migration[7.1]
  def change
    change_table :contact_companies do |t|
      t.string :relationship_type
      t.string :commercial_role
      t.string :status, null: false, default: 'active'
      t.datetime :valid_from
      t.datetime :valid_until
      t.string :source_type
      t.string :source_id
      t.jsonb :metadata, null: false, default: {}
    end
    add_check_constraint :contact_companies, "status IN ('active', 'inactive', 'contested')", name: 'contact_companies_status_valid'
    add_check_constraint :contact_companies, 'valid_until IS NULL OR valid_from IS NULL OR valid_until > valid_from', name: 'contact_companies_valid_period'

    create_table :contact_identities, id: :uuid do |t|
      t.references :contact, type: :uuid, null: false, foreign_key: true
      t.references :inbox, type: :uuid, foreign_key: true
      t.string :identity_type, null: false
      t.string :provider, null: false
      t.string :external_id
      t.string :normalized_value
      t.string :display_value
      t.string :verification_status, null: false, default: 'unverified'
      t.datetime :verified_at
      t.string :verified_by_type
      t.uuid :verified_by_id
      t.datetime :valid_from, null: false
      t.datetime :valid_until
      t.boolean :is_primary, null: false, default: false
      t.string :source_type
      t.string :source_id
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_check_constraint :contact_identities, "identity_type <> '' AND provider <> ''", name: 'contact_identities_names_present'
    add_check_constraint :contact_identities, 'NULLIF(normalized_value, \'\') IS NOT NULL OR NULLIF(external_id, \'\') IS NOT NULL', name: 'contact_identities_has_identifier'
    add_check_constraint :contact_identities, "verification_status IN ('unverified', 'verified', 'contested', 'rejected')", name: 'contact_identities_verification_valid'
    add_check_constraint :contact_identities, 'valid_until IS NULL OR valid_until > valid_from', name: 'contact_identities_valid_period'
    # NULL inbox is a real global/provider scope; PostgreSQL treats NULLs as distinct
    # in ordinary unique indexes. COALESCE makes that scope enforceable.
    scope = "COALESCE(inbox_id, '00000000-0000-0000-0000-000000000000'::uuid)"
    add_index :contact_identities, "identity_type, provider, #{scope}, normalized_value", unique: true,
              where: 'valid_until IS NULL AND normalized_value IS NOT NULL', name: 'uniq_active_identity_value'
    add_index :contact_identities, "identity_type, provider, #{scope}, external_id", unique: true,
              where: 'valid_until IS NULL AND external_id IS NOT NULL', name: 'uniq_active_identity_external'
    add_index :contact_identities, "contact_id, identity_type, provider, #{scope}", unique: true,
              where: 'valid_until IS NULL AND is_primary', name: 'uniq_active_primary_identity'

    create_table :customer_events, id: :uuid do |t|
      t.references :contact, type: :uuid, null: false, foreign_key: true
      t.string :event_type, null: false
      t.integer :schema_version, null: false, default: 1
      t.datetime :occurred_at, null: false
      t.datetime :recorded_at, null: false
      t.string :source_system, null: false
      t.string :source_type
      t.string :source_id
      t.string :actor_type
      t.uuid :actor_id
      t.uuid :correlation_id
      t.uuid :causation_id
      t.string :idempotency_key, null: false
      t.jsonb :payload, null: false, default: {}
      t.string :sensitivity, null: false, default: 'internal'
      t.timestamps
    end
    add_index :customer_events, [:source_system, :idempotency_key], unique: true, name: 'uniq_customer_event_source_key'
    add_index :customer_events, [:contact_id, :occurred_at]
    add_index :customer_events, [:event_type, :occurred_at]
    add_index :customer_events, :correlation_id
    add_check_constraint :customer_events, 'schema_version > 0', name: 'customer_events_schema_version_positive'
    add_check_constraint :customer_events, "sensitivity IN ('public', 'internal', 'personal', 'sensitive')", name: 'customer_events_sensitivity_valid'

    create_table :memory_records, id: :uuid do |t|
      t.references :contact, type: :uuid, null: false, foreign_key: true
      t.references :contact_company, type: :uuid, foreign_key: true
      t.string :context_type
      t.uuid :context_id
      t.string :scope, null: false
      t.string :category, null: false
      t.string :semantic_key, null: false
      t.string :kind, null: false
      t.string :review_status, null: false, default: 'not_required'
      t.jsonb :value, null: false
      t.string :status, null: false, default: 'active'
      t.decimal :confidence, precision: 5, scale: 4
      t.datetime :observed_at, null: false
      t.datetime :valid_from
      t.datetime :valid_until
      t.datetime :superseded_at
      t.datetime :verified_at
      t.datetime :reviewed_at
      t.string :reviewed_by_type
      t.uuid :reviewed_by_id
      t.string :actor_type
      t.uuid :actor_id
      t.string :extractor
      t.string :model_version
      t.references :supersedes, type: :uuid, index: { unique: true }, foreign_key: { to_table: :memory_records }
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :memory_records, [:contact_id, :scope, :category, :semantic_key], name: 'index_memory_records_on_subject_and_key'
    add_index :memory_records, [:context_type, :context_id]
    add_check_constraint :memory_records, "scope IN ('person', 'company', 'relationship', 'context')", name: 'memory_records_scope_valid'
    add_check_constraint :memory_records, "kind IN ('fact', 'inference')", name: 'memory_records_kind_valid'
    add_check_constraint :memory_records, "(kind = 'fact' AND review_status = 'not_required') OR (kind = 'inference' AND review_status IN ('pending', 'approved', 'rejected'))", name: 'memory_records_review_status_valid'
    add_check_constraint :memory_records, "review_status NOT IN ('approved', 'rejected') OR (reviewed_at IS NOT NULL AND reviewed_by_type IS NOT NULL AND reviewed_by_id IS NOT NULL)", name: 'memory_records_review_actor_required'
    add_check_constraint :memory_records, "status IN ('active', 'contested', 'superseded', 'expired', 'anonymized')", name: 'memory_records_status_valid'
    add_check_constraint :memory_records, "(kind = 'fact' AND confidence IS NULL) OR (kind = 'inference' AND confidence BETWEEN 0 AND 1)", name: 'memory_records_confidence_valid'
    add_check_constraint :memory_records, 'valid_until IS NULL OR valid_from IS NULL OR valid_until > valid_from', name: 'memory_records_valid_period'
    add_check_constraint :memory_records, "(scope = 'relationship' AND contact_company_id IS NOT NULL) OR (scope <> 'relationship' AND contact_company_id IS NULL)", name: 'memory_records_relationship_scope'
    add_check_constraint :memory_records, "(scope = 'context' AND context_type IS NOT NULL AND context_id IS NOT NULL) OR (scope <> 'context' AND context_type IS NULL AND context_id IS NULL)", name: 'memory_records_context_scope'

    create_table :memory_evidences, id: :uuid do |t|
      t.references :memory_record, type: :uuid, null: false, foreign_key: true
      t.references :customer_event, type: :uuid, index: false, foreign_key: true
      t.string :source_system, null: false
      t.string :source_type, null: false
      t.string :source_id, null: false
      t.datetime :observed_at, null: false
      t.string :actor_type
      t.uuid :actor_id
      t.string :extractor
      t.string :extractor_version
      t.string :locator
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :memory_evidences, [:source_system, :source_type, :source_id], name: 'index_memory_evidences_on_source'
    add_index :memory_evidences, :customer_event_id, unique: true, where: 'customer_event_id IS NOT NULL', name: 'uniq_memory_evidence_per_event'
    # A source can support several observations. The locator and observation time
    # distinguish them; retries of the same observation cannot create two rows.
    add_index :memory_evidences,
              "memory_record_id, source_system, source_type, source_id, COALESCE(locator, ''), observed_at",
              unique: true, where: 'customer_event_id IS NULL', name: 'uniq_memory_evidence_source_observation'

    create_table :event_outboxes, id: :uuid do |t|
      t.references :customer_event, type: :uuid, null: false, foreign_key: true
      t.string :destination, null: false
      t.string :status, null: false, default: 'pending'
      t.integer :attempts, null: false, default: 0
      t.datetime :available_at, null: false
      t.datetime :published_at
      t.datetime :last_attempt_at
      t.string :last_error_code
      t.jsonb :envelope, null: false, default: {}
      t.timestamps
    end
    add_index :event_outboxes, [:customer_event_id, :destination], unique: true
    add_index :event_outboxes, [:status, :available_at]
    add_check_constraint :event_outboxes, "status IN ('pending', 'publishing', 'published', 'failed')", name: 'event_outboxes_status_valid'
    add_check_constraint :event_outboxes, 'attempts >= 0', name: 'event_outboxes_attempts_valid'
  end
end
