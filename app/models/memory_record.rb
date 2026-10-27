class MemoryRecord < ApplicationRecord
  include CustomerDataGuard

  belongs_to :contact
  belongs_to :contact_company, optional: true
  belongs_to :supersedes, class_name: 'MemoryRecord', optional: true
  has_many :memory_evidences, dependent: :restrict_with_exception

  SCOPES = %w[person company relationship context].freeze
  KINDS = %w[fact inference].freeze
  STATUSES = %w[active contested superseded expired anonymized].freeze
  REVIEW_STATUSES = %w[not_required pending approved rejected].freeze

  before_validation :set_review_status

  validates :scope, inclusion: { in: SCOPES }
  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :review_status, inclusion: { in: REVIEW_STATUSES }
  validates :category, :semantic_key, presence: true, length: { maximum: 120 }
  validates :observed_at, presence: true
  validate :owner_matches_scope, :confidence_matches_kind, :review_matches_kind,
           :structured_data_safe, :valid_period, :supersession_consistent

  private

  def set_review_status
    self.review_status = 'pending' if kind == 'inference' && review_status == 'not_required'
  end

  def review_matches_kind
    valid = (kind == 'fact' && review_status == 'not_required') ||
            (kind == 'inference' && %w[pending approved rejected].include?(review_status))
    errors.add(:review_status, 'is inconsistent with memory kind') unless valid
    if %w[approved rejected].include?(review_status) &&
       (reviewed_at.nil? || reviewed_by_type.blank? || reviewed_by_id.nil?)
      errors.add(:review_status, 'requires a reviewer and review time')
    end
  end

  def owner_matches_scope
    errors.add(:contact, 'must be a person') if scope == 'person' && contact && !contact.person?
    errors.add(:contact, 'must be a company') if scope == 'company' && contact && !contact.company?
    if scope == 'relationship'
      errors.add(:contact_company, 'is required') unless contact_company
      errors.add(:contact, 'must match relationship person') if contact_company && contact_id != contact_company.contact_id
    elsif contact_company_id.present?
      errors.add(:contact_company, 'only applies to relationship memory')
    end
    if scope == 'context'
      errors.add(:context_id, 'and context_type are required') if context_id.blank? || context_type.blank?
    elsif context_id.present? || context_type.present?
      errors.add(:context_id, 'only applies to context memory')
    end
  end

  def confidence_matches_kind
    if kind == 'fact' && !confidence.nil?
      errors.add(:confidence, 'is only allowed for inference')
    elsif kind == 'inference' && (confidence.nil? || confidence < 0 || confidence > 1)
      errors.add(:confidence, 'must be between 0 and 1 for inference')
    end
  end

  def structured_data_safe
    validate_structured_data(:value, limit: 8192)
    validate_structured_data(:metadata)
  end

  def valid_period
    errors.add(:valid_until, 'must follow valid_from') if valid_until && valid_from && valid_until <= valid_from
  end

  def supersession_consistent
    return unless supersedes

    same_subject = supersedes.contact_id == contact_id && supersedes.contact_company_id == contact_company_id &&
                   supersedes.context_type == context_type && supersedes.context_id == context_id
    same_key = supersedes.scope == scope && supersedes.category == category && supersedes.semantic_key == semantic_key
    errors.add(:supersedes, 'must have the same subject and semantic key') unless same_subject && same_key
  end
end
