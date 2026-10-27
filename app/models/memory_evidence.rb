class MemoryEvidence < ApplicationRecord
  include CustomerDataGuard

  belongs_to :memory_record
  belongs_to :customer_event, optional: true

  before_validation :normalize_locator

  validates :source_system, :source_type, :source_id, :observed_at, presence: true
  validates :source_system, :source_type, :source_id, :locator, length: { maximum: 255 }, allow_nil: true
  validate :metadata_safe, :event_matches_subject

  private

  def normalize_locator
    self.locator = nil if locator == ''
  end

  def metadata_safe
    validate_structured_data(:metadata)
  end

  def event_matches_subject
    return unless customer_event && memory_record

    errors.add(:customer_event, 'must have the same contact') if customer_event.contact_id != memory_record.contact_id
    if customer_event.source_type.present? &&
       (customer_event.source_system != source_system || customer_event.source_type != source_type || customer_event.source_id != source_id)
      errors.add(:customer_event, 'must have the same source reference')
    end
  end
end
