module ContactIdentities
  class Resolve
    Result = Struct.new(:status, :contact, :identity, :candidate_contact_ids, keyword_init: true)

    def self.call(identity_type:, provider:, normalized_value: nil, external_id: nil, inbox: nil, contact: nil,
                  source_system: 'crm', idempotency_key: nil)
      normalized_value = Normalizer.value(identity_type: identity_type, normalized_value: normalized_value)
      raise ArgumentError, 'identity value is required' if normalized_value.blank? && external_id.blank?

      scope = ContactIdentity.active.where(identity_type: identity_type, provider: provider, inbox_id: inbox&.id)
      matches = [normalized_value.present? ? scope.find_by(normalized_value: normalized_value) : nil,
                 external_id.present? ? scope.find_by(external_id: external_id) : nil].compact.uniq
      if matches.map(&:contact_id).uniq.size > 1 || (contact && matches.any? { |match| match.contact_id != contact.id })
        if contact
          raise ArgumentError, 'idempotency_key is required for audited conflict' if idempotency_key.blank?

          CustomerEvents::Record.call(contact: contact, event_type: 'identity.conflict', source_system: source_system,
                                      idempotency_key: idempotency_key, occurred_at: Time.current,
                                      payload: { candidate_contact_ids: matches.map(&:contact_id).uniq })
        end
        return Result.new(status: :conflict, candidate_contact_ids: matches.map(&:contact_id).uniq)
      end
      match = matches.first
      return Result.new(status: :found, contact: match.contact, identity: match) if match

      Result.new(status: :missing)
    end
  end
end
