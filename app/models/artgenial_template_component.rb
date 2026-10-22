# frozen_string_literal: true

class ArtgenialTemplateComponent < ApplicationRecord
  RECORD_TYPES = { 'pipeline' => 'Pipeline', 'stage' => 'PipelineStage', 'label' => 'Label' }.freeze
  STATUSES = %w[planned applied missing preserved].freeze

  belongs_to :artgenial_template_installation, inverse_of: :artgenial_template_components

  validates :component_type, inclusion: { in: RECORD_TYPES.keys }
  validates :component_key, :record_type, presence: true
  validates :component_key, format: { with: /\A[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)*\z/ }
  validates :component_key, uniqueness: { scope: %i[artgenial_template_installation_id component_type] }
  validates :status, inclusion: { in: STATUSES }
  validate :record_type_matches_component
  validate :identity_immutable, on: :update

  private

  def record_type_matches_component
    return if RECORD_TYPES[component_type] == record_type

    errors.add(:record_type, 'does not match component_type')
  end

  def identity_immutable
    %w[artgenial_template_installation_id component_type component_key record_type].each do |attribute|
      errors.add(attribute, 'cannot change after creation') if will_save_change_to_attribute?(attribute)
    end
  end
end
