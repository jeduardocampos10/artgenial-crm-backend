class EventOutbox < ApplicationRecord
  include CustomerDataGuard

  belongs_to :customer_event

  STATUSES = %w[pending publishing published failed].freeze
  validates :destination, presence: true, length: { maximum: 80 }
  validates :status, inclusion: { in: STATUSES }
  validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :available_at, presence: true
  validate :envelope_safe

  private

  def envelope_safe
    validate_structured_data(:envelope, limit: 4096)
  end
end
