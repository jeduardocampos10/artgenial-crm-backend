module ContactIdentities
  module Normalizer
    def self.value(identity_type:, normalized_value:)
      return normalized_value unless identity_type == 'email'

      normalized_value&.strip&.downcase
    end
  end
end
