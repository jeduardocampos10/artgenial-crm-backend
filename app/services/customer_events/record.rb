module CustomerEvents
  class Record
    class IdempotencyConflict < StandardError; end

    def self.call(contact:, event_type:, source_system:, idempotency_key:, occurred_at:, source_type: nil,
                  source_id: nil, actor_type: nil, actor_id: nil, correlation_id: nil, causation_id: nil,
                  payload: {}, sensitivity: 'internal', destination: 'customer_memory')
      CustomerEvent.transaction do
        attributes = {
          contact: contact, event_type: event_type, schema_version: 1,
          source_system: source_system, idempotency_key: idempotency_key,
          occurred_at: occurred_at, recorded_at: Time.current,
          source_type: source_type, source_id: source_id,
          actor_type: actor_type, actor_id: actor_id,
          correlation_id: correlation_id, causation_id: causation_id,
          payload: payload, sensitivity: sensitivity
        }
        event = CustomerEvent.create_or_find_by!(source_system: source_system, idempotency_key: idempotency_key) do |row|
          row.assign_attributes(attributes)
        end
        # A reused key for a different logical operation must not silently
        # return someone else's event, even within one installation database.
        unless event.contact_id == contact.id && event.event_type == event_type && event.source_type == source_type &&
               event.source_id == source_id && event.payload == JSON.parse(JSON.generate(payload)) &&
               event.correlation_id == correlation_id && event.causation_id == causation_id &&
               event.sensitivity == sensitivity
          raise IdempotencyConflict, 'idempotency key was reused for a different event'
        end
        EventOutbox.create_or_find_by!(customer_event: event, destination: destination) do |row|
          row.available_at = Time.current
          row.envelope = { event_id: event.id }
        end
        event
      end
    end
  end
end
