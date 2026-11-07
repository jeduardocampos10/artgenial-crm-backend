# frozen_string_literal: true

# Explicit fail-closed response contract for Customer 360 memory reads.
#
# `value`, `category` and `semantic_key` are free-form inputs: MemoryRecord has
# no approved public schema or sensitivity classification for them. They are
# therefore omitted entirely instead of trying to infer safety from JSON keys or
# string patterns. Metadata, provenance identifiers, actors, extractor/model
# details and evidence payloads are also excluded. `evidence_count` is the only
# evidence field exposed by this endpoint.
module MemoryRecordSerializer
  extend self

  def serialize(memory_record)
    {
      id: memory_record.id,
      scope: memory_record.scope,
      kind: memory_record.kind,
      status: memory_record.status,
      review_status: memory_record.review_status,
      confidence: memory_record.confidence,
      observed_at: memory_record.observed_at&.iso8601,
      valid_from: memory_record.valid_from&.iso8601,
      valid_until: memory_record.valid_until&.iso8601,
      evidence_count: memory_record.memory_evidences.size
    }
  end

  def serialize_collection(memory_records)
    return [] unless memory_records

    memory_records.map { |memory_record| serialize(memory_record) }
  end
end
