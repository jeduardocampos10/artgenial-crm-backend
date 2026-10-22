# frozen_string_literal: true

class ArtgenialTemplateInstallation < ApplicationRecord
  STATUSES = %w[planned applying applied failed].freeze
  INSTALLATION_KEY_PATTERN = /\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i

  has_many :artgenial_template_components, dependent: :restrict_with_error, inverse_of: :artgenial_template_installation

  validates :installation_key, :template_key, :template_version, :checksum, presence: true
  validates :installation_key,
            format: { with: INSTALLATION_KEY_PATTERN,
                      message: 'must be an opaque installation UUID supplied by the provisioner' }
  validates :template_version, format: { with: /\A[1-9]\d*\z/ }
  validates :checksum, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :status, inclusion: { in: STATUSES }
  validates :template_key, uniqueness: { scope: %i[installation_key template_version] }
  validate :installed_at_only_when_applied
  validate :identity_immutable, on: :update

  private

  def installed_at_only_when_applied
    errors.add(:installed_at, 'requires applied status') if installed_at.present? && status != 'applied'
    errors.add(:installed_at, 'is required for applied status') if status == 'applied' && installed_at.blank?
  end

  def identity_immutable
    %w[installation_key template_key template_version checksum].each do |attribute|
      errors.add(attribute, 'cannot change after creation') if will_save_change_to_attribute?(attribute)
    end
  end
end
