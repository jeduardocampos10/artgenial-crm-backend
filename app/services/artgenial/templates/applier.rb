# frozen_string_literal: true

module Artgenial
  module Templates
    # Applies only the published Base v1. Product rows and ownership ledger commit together.
    class Applier
      class UnsafePlan < StandardError; end

      BASE_V1_CHECKSUM = '1c22c7dc607ee0a1519c2a508affc776b570f12d9ddb8051e504d1240c0b20ad'.freeze
      Result = Struct.new(:status, :installation, :plan, keyword_init: true)

      def initialize(installation_key:, manifest:, actor:)
        @installation_key = installation_key.to_s
        @manifest = manifest
        @actor = actor
      end

      def call
        validate_inputs!

        ArtgenialTemplateInstallation.transaction do
          # The existing Pipeline callback clears another default on insert. Serialize pipeline
          # writes so the guard below cannot miss a default created concurrently.
          Pipeline.connection.execute('LOCK TABLE pipelines IN SHARE ROW EXCLUSIVE MODE')

          plan = Planner.new(installation_key: @installation_key, manifest: @manifest).call
          validate_plan!(plan)
          installation = ArtgenialTemplateInstallation.find_by(
            installation_key: @installation_key, template_key: plan.template_key,
            template_version: plan.template_version
          )

          if installation
            verify_applied_installation!(installation, plan)
            Result.new(status: :already_applied, installation: installation, plan: plan)
          else
            raise UnsafePlan, 'a different pipeline is already default' if Pipeline.where(is_default: true).exists?

            apply_new_installation!(plan)
          end
        end
      end

      private

      def validate_inputs!
        unless @installation_key.match?(ArtgenialTemplateInstallation::INSTALLATION_KEY_PATTERN)
          raise ArgumentError, 'installation_key must be an explicit installation UUID'
        end
        raise ArgumentError, 'actor must be a persisted User' unless @actor.is_a?(User) && @actor.persisted? && User.exists?(@actor.id)
        raise ArgumentError, 'manifest must be a loaded template' unless @manifest.respond_to?(:data) && @manifest.respond_to?(:checksum)

        data = @manifest.data
        Validator.new.validate!(data)
        unless data['template_key'] == 'artgenial.base' && data['version'] == '1' &&
               @manifest.checksum == BASE_V1_CHECKSUM && Checksum.call(data) == BASE_V1_CHECKSUM
          raise UnsafePlan, 'only the approved ArtGenial Base v1 manifest can be applied'
        end
      end

      def validate_plan!(plan)
        unsafe = plan.actions.find { |action| %i[collision blocked].include?(action.operation) }
        raise UnsafePlan, "#{unsafe.component_key}: #{unsafe.operation} (#{unsafe.reason})" if unsafe

        expected = expected_components
        actual = plan.actions.map { |action| [action.component_type, action.component_key] }
        raise UnsafePlan, 'plan does not match the manifest components' unless actual.size == expected.size && actual.sort == expected.sort
      end

      def expected_components
        data = @manifest.data
        pipelines = data.fetch('pipelines').flat_map do |pipeline|
          [['pipeline', pipeline.fetch('key')]] + pipeline.fetch('stages').map do |stage|
            ['stage', "#{pipeline.fetch('key')}.#{stage.fetch('key')}"]
          end
        end
        pipelines + data.fetch('labels').map { |label| ['label', "label.#{label.fetch('key')}"] }
      end

      def verify_applied_installation!(installation, plan)
        raise UnsafePlan, 'installation is not fully applied' unless installation.status == 'applied' && installation.installed_at
        raise UnsafePlan, 'installation checksum differs from the manifest' unless installation.checksum == plan.checksum
        raise UnsafePlan, 'managed records require reconciliation' unless plan.actions.all? { |action| %i[noop preserve].include?(action.operation) }

        components = installation.artgenial_template_components.to_a
        identities = components.map { |component| [component.component_type, component.component_key] }
        unless identities.size == expected_components.size && identities.sort == expected_components.sort
          raise UnsafePlan, 'installation ledger is incomplete'
        end

        actions = plan.actions.index_by { |action| [action.component_type, action.component_key] }
        components.each do |component|
          action = actions.fetch([component.component_type, component.component_key])
          valid = component.status == 'applied' && component.record_id.present? &&
                  component.record_type == ArtgenialTemplateComponent::RECORD_TYPES.fetch(component.component_type) &&
                  component.record_id == action.record_id && component.last_applied_state.present?
          raise UnsafePlan, "incomplete ledger component: #{component.component_key}" unless valid
        end
      end

      def apply_new_installation!(plan)
        raise UnsafePlan, 'new installation requires CREATE for every component' unless plan.actions.all? { |action| action.operation == :create }

        installation = ArtgenialTemplateInstallation.create!(
          installation_key: @installation_key, template_key: plan.template_key,
          template_version: plan.template_version, checksum: plan.checksum,
          status: 'applying', metadata: { 'actor_id' => @actor.id }
        )

        create_pipelines!(installation)
        create_labels!(installation)
        installation.update!(status: 'applied', installed_at: Time.current)
        Result.new(status: :applied, installation: installation, plan: plan)
      end

      def create_pipelines!(installation)
        @manifest.data.fetch('pipelines').each do |definition|
          pipeline = Pipeline.create!(name: definition.fetch('name'), pipeline_type: definition.fetch('pipeline_type'),
                                      visibility: definition.fetch('visibility'), is_default: definition.fetch('is_default'),
                                      created_by: @actor)
          record_component!(installation, 'pipeline', definition.fetch('key'), pipeline)
          definition.fetch('stages').each do |stage_definition|
            stage = pipeline.pipeline_stages.create!(name: stage_definition.fetch('name'),
                                                     position: stage_definition.fetch('position'),
                                                     stage_type: stage_definition.fetch('stage_type'))
            record_component!(installation, 'stage', "#{definition.fetch('key')}.#{stage_definition.fetch('key')}", stage)
          end
        end
      end

      def create_labels!(installation)
        @manifest.data.fetch('labels').each do |definition|
          label = Label.create!(title: definition.fetch('title'), color: definition.fetch('color'))
          record_component!(installation, 'label', "label.#{definition.fetch('key')}", label,
                            'category' => definition.fetch('category'))
        end
      end

      def record_component!(installation, type, key, record, metadata = {})
        installation.artgenial_template_components.create!(
          component_type: type, component_key: key, record_type: record.class.name, record_id: record.id,
          last_applied_state: record.reload.attributes.except('id', 'created_at', 'updated_at'),
          status: 'applied', metadata: metadata
        )
      end
    end
  end
end
