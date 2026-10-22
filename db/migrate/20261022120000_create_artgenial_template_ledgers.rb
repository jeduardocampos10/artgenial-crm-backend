# frozen_string_literal: true

class CreateArtgenialTemplateLedgers < ActiveRecord::Migration[7.1]
  def change
    create_table :artgenial_template_installations, id: :uuid do |t|
      t.string :installation_key, null: false
      t.string :template_key, null: false
      t.string :template_version, null: false
      t.string :checksum, limit: 64, null: false
      t.string :status, null: false, default: 'planned'
      t.datetime :installed_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :artgenial_template_installations,
              %i[installation_key template_key template_version],
              unique: true, name: 'idx_artgenial_installations_identity'
    add_check_constraint :artgenial_template_installations,
                         "status IN ('planned', 'applying', 'applied', 'failed')",
                         name: 'chk_artgenial_installation_status'
    add_check_constraint :artgenial_template_installations,
                         "status <> 'applied' OR installed_at IS NOT NULL",
                         name: 'chk_artgenial_applied_at'

    create_table :artgenial_template_components, id: :uuid do |t|
      t.references :artgenial_template_installation, type: :uuid, null: false,
                   foreign_key: { on_delete: :restrict }, index: false
      t.string :component_type, null: false
      t.string :component_key, null: false
      t.string :record_type, null: false
      t.uuid :record_id
      t.jsonb :last_applied_state, null: false, default: {}
      t.string :status, null: false, default: 'planned'
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :artgenial_template_components,
              %i[artgenial_template_installation_id component_type component_key],
              unique: true, name: 'idx_artgenial_components_identity'
    add_index :artgenial_template_components,
              %i[artgenial_template_installation_id record_type record_id],
              unique: true, where: 'record_id IS NOT NULL', name: 'idx_artgenial_components_record'
    add_check_constraint :artgenial_template_components,
                         "component_type IN ('pipeline', 'stage', 'label')",
                         name: 'chk_artgenial_component_type'
    add_check_constraint :artgenial_template_components,
                         "(component_type = 'pipeline' AND record_type = 'Pipeline') OR " \
                         "(component_type = 'stage' AND record_type = 'PipelineStage') OR " \
                         "(component_type = 'label' AND record_type = 'Label')",
                         name: 'chk_artgenial_record_type'
    add_check_constraint :artgenial_template_components,
                         "status IN ('planned', 'applied', 'missing', 'preserved')",
                         name: 'chk_artgenial_component_status'
  end
end
