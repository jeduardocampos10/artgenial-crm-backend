module CustomerMemory
  class Record
    def self.call(contact:, scope:, category:, semantic_key:, kind:, value:, evidence:, idempotency_key:,
                  source_system:, observed_at:, confidence: nil, contact_company: nil, context_type: nil,
                  context_id: nil, extractor: nil, model_version: nil)
      MemoryRecord.transaction do
        event = CustomerEvents::Record.call(
          contact: contact, event_type: 'memory.recorded', source_system: source_system,
          idempotency_key: idempotency_key, occurred_at: observed_at,
          source_type: evidence.fetch(:source_type), source_id: evidence.fetch(:source_id),
          payload: { scope: scope, category: category, semantic_key: semantic_key }
        )
        event.with_lock do
          existing = MemoryEvidence.find_by(customer_event: event)&.memory_record
          if existing
            normalized_value = JSON.parse(JSON.generate(value))
            unless existing.kind == kind && existing.value == normalized_value && existing.confidence == confidence &&
                   existing.contact_company_id == contact_company&.id && existing.context_type == context_type &&
                   existing.context_id == context_id && existing.extractor == extractor &&
                   existing.model_version == model_version
              raise CustomerEvents::Record::IdempotencyConflict, 'idempotency key was reused for different memory'
            end
            next existing
          end

          memory = MemoryRecord.create!(contact: contact, scope: scope, category: category,
                                        semantic_key: semantic_key, kind: kind, value: value,
                                        confidence: confidence, observed_at: observed_at,
                                        contact_company: contact_company, context_type: context_type,
                                        context_id: context_id, extractor: extractor, model_version: model_version)
          memory.memory_evidences.create!(evidence.merge(source_system: source_system,
                                                         observed_at: observed_at, customer_event: event))
          memory
        end
      end
    end
  end
end
