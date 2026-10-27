module CustomerMemory
  class AttachEvidence
    class IdempotencyConflict < StandardError; end

    def self.call(memory_record:, source_system:, source_type:, source_id:, observed_at:, **attributes)
      attributes[:locator] = nil if attributes[:locator] == ''
      attributes[:metadata] = JSON.parse(JSON.generate(attributes[:metadata])) if attributes.key?(:metadata)
      desired = MemoryEvidence.new(memory_record: memory_record, source_system: source_system,
                                   source_type: source_type, source_id: source_id,
                                   observed_at: observed_at, **attributes)
      key = if desired.customer_event_id
              { customer_event_id: desired.customer_event_id }
            else
              { memory_record_id: desired.memory_record_id, source_system: desired.source_system,
                source_type: desired.source_type, source_id: desired.source_id,
                locator: desired.locator, observed_at: desired.observed_at, customer_event_id: nil }
            end
      evidence = MemoryEvidence.create_or_find_by!(key) do |row|
        row.assign_attributes(desired.attributes.except('id', 'created_at', 'updated_at'))
      end
      comparable = ->(record) { record.attributes.except('id', 'created_at', 'updated_at') }
      raise IdempotencyConflict, 'evidence key was reused with different attributes' unless comparable.call(evidence) == comparable.call(desired)

      evidence
    rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordNotUnique
      raise IdempotencyConflict, 'evidence key conflicts with an existing record'
    end
  end
end
