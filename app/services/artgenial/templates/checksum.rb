# frozen_string_literal: true

require 'digest'
require 'json'

module Artgenial
  module Templates
    class Checksum
      def self.call(data)
        Digest::SHA256.hexdigest(JSON.generate(canonical(data)))
      end

      def self.canonical(value)
        case value
        when Hash
          value.stringify_keys.sort.to_h.transform_values { |item| canonical(item) }
        when Array
          value.map { |item| canonical(item) }
        else
          value
        end
      end
      private_class_method :canonical
    end
  end
end
