class CustomerEvent < ApplicationRecord
  include CustomerDataGuard

  belongs_to :contact
  has_many :event_outboxes, dependent: :restrict_with_exception
  has_many :memory_evidences, dependent: :restrict_with_exception

  SENSITIVITIES = %w[public internal personal sensitive].freeze
  validates :event_type, :source_system, :idempotency_key, :occurred_at, :recorded_at, presence: true
  validates :event_type, :source_system, :idempotency_key, length: { maximum: 255 }
  validates :schema_version, numericality: { only_integer: true, greater_than: 0 }
  validates :sensitivity, inclusion: { in: SENSITIVITIES }
  validate :payload_safe
  before_update :reject_mutation
  before_destroy :reject_mutation

  private

  def payload_safe
    validate_structured_data(:payload, limit: 4096)
  end

  def reject_mutation
    raise ActiveRecord::ReadOnlyError, 'customer events are append-only'
  end
end
