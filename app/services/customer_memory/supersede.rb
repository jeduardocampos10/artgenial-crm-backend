module CustomerMemory
  class Supersede
    class UnsafeReplacement < StandardError; end

    def self.call(previous:, kind:, value:, evidence:, idempotency_key:, source_system:, observed_at:,
                  confidence: nil)
      MemoryRecord.transaction do
        previous.lock!
        prior_event = CustomerEvent.find_by(source_system: source_system, idempotency_key: idempotency_key)
        if prior_event
          replacement = MemoryRecord.find_by(supersedes_id: previous.id)
          if prior_event.event_type == 'memory.superseded' && prior_event.contact_id == previous.contact_id &&
             prior_event.payload['previous_memory_record_id'] == previous.id &&
             prior_event.source_type == evidence.fetch(:source_type) && prior_event.source_id == evidence.fetch(:source_id) &&
             replacement&.memory_evidences&.exists?(customer_event_id: prior_event.id) &&
             replacement.kind == kind && replacement.value == JSON.parse(JSON.generate(value)) &&
             replacement.confidence == confidence
            next replacement
          end
          raise CustomerEvents::Record::IdempotencyConflict, 'idempotency key was reused for different supersession'
        end
        raise UnsafeReplacement, 'only active memory can be superseded' unless previous.status == 'active'
        if previous.kind == 'fact' && kind == 'inference'
          raise UnsafeReplacement, 'inference cannot replace a fact in this block'
        end

        event = CustomerEvents::Record.call(
          contact: previous.contact, event_type: 'memory.superseded', source_system: source_system,
          idempotency_key: idempotency_key, occurred_at: observed_at,
          source_type: evidence.fetch(:source_type), source_id: evidence.fetch(:source_id),
          payload: { previous_memory_record_id: previous.id }
        )
        replacement = MemoryRecord.create!(contact: previous.contact, contact_company: previous.contact_company,
                                           context_type: previous.context_type, context_id: previous.context_id,
                                           scope: previous.scope, category: previous.category,
                                           semantic_key: previous.semantic_key, kind: kind, value: value,
                                           confidence: confidence, observed_at: observed_at,
                                           supersedes: previous)
        replacement.memory_evidences.create!(evidence.merge(source_system: source_system,
                                                             observed_at: observed_at, customer_event: event))
        previous.update!(status: 'superseded', superseded_at: observed_at)
        replacement
      end
    end
  end
end
