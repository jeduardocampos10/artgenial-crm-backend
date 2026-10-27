module ContactIdentities
  class Register
    def self.call(contact:, identity_type:, provider:, normalized_value: nil, external_id: nil,
                  inbox: nil, source_system: 'crm', idempotency_key:, **attributes)
      normalized_value = Normalizer.value(identity_type: identity_type, normalized_value: normalized_value)
      result = Resolve.call(identity_type: identity_type, provider: provider,
                            normalized_value: normalized_value, external_id: external_id,
                            inbox: inbox, contact: contact, source_system: source_system,
                            idempotency_key: idempotency_key)
      return result if result.status == :conflict || result.status == :found

      identity = ContactIdentity.transaction(requires_new: true) do
        ContactIdentity.create!(contact: contact, identity_type: identity_type,
                                provider: provider, normalized_value: normalized_value,
                                external_id: external_id, inbox: inbox,
                                valid_from: Time.current, **attributes)
      end
      Resolve::Result.new(status: :created, contact: contact, identity: identity)
    rescue ActiveRecord::RecordNotUnique
      # Another writer won the unique index race. Resolve again; never merge.
      result = Resolve.call(identity_type: identity_type, provider: provider,
                            normalized_value: normalized_value, external_id: external_id,
                            inbox: inbox, contact: contact, source_system: source_system,
                            idempotency_key: idempotency_key)
      # The race may instead be on the unique primary slot. In that case no
      # requested identity exists, so reporting :missing would hide a failed write.
      raise if result.status == :missing

      result
    end
  end
end
