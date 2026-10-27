# Limits structured data to small, JSON-compatible records and rejects credential-like keys.
# This is defense in depth: callers must still send only approved domain fields.
module CustomerDataGuard
  FORBIDDEN_KEY = /password|secret|token|credential|authorization|api[_-]?key|private[_-]?key/i

  private

  def validate_structured_data(attribute, limit: 4096)
    value = public_send(attribute)
    unless value.is_a?(Hash) || value.is_a?(Array)
      errors.add(attribute, 'must be a JSON object or array')
      return
    end
    serialized = JSON.generate(value)
    errors.add(attribute, 'is too large') if serialized.bytesize > limit
    errors.add(attribute, 'contains a forbidden key') if contains_forbidden_key?(value)
  rescue JSON::GeneratorError, EncodingError
    errors.add(attribute, 'must be JSON compatible')
  end

  def contains_forbidden_key?(value)
    case value
    when Hash
      value.any? { |key, nested| key.to_s.match?(FORBIDDEN_KEY) || contains_forbidden_key?(nested) }
    when Array
      value.any? { |nested| contains_forbidden_key?(nested) }
    else
      false
    end
  end
end
