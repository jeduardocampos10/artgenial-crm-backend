class ContactIdentity < ApplicationRecord
  include CustomerDataGuard

  belongs_to :contact
  belongs_to :inbox, optional: true

  STATUSES = %w[unverified verified contested rejected].freeze
  validates :identity_type, :provider, presence: true, length: { maximum: 80 }
  validates :external_id, :normalized_value, :display_value, length: { maximum: 255 }, allow_nil: true
  validates :verification_status, inclusion: { in: STATUSES }
  before_validation :normalize_text_identity
  validate :identifier_present, :valid_period, :verification_consistent, :metadata_safe

  scope :active, -> { where(valid_until: nil) }

  private

  def normalize_text_identity
    self.normalized_value = ContactIdentities::Normalizer.value(identity_type: identity_type,
                                                                normalized_value: normalized_value)
  end

  def identifier_present
    errors.add(:base, 'external_id or normalized_value is required') if external_id.blank? && normalized_value.blank?
  end

  def valid_period
    errors.add(:valid_until, 'must follow valid_from') if valid_until && valid_from && valid_until <= valid_from
  end

  def verification_consistent
    errors.add(:verified_at, 'is required for verified identity') if verification_status == 'verified' && verified_at.nil?
  end

  def metadata_safe
    validate_structured_data(:metadata)
  end
end
