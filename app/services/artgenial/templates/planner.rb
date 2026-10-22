# frozen_string_literal: true

module Artgenial
  module Templates
    # A read-only preview. In phase 1 no component is adopted, changed or created.
    class Planner
      Action = Struct.new(:operation, :component_type, :component_key, :name, :record_id, :reason, keyword_init: true)
      Plan = Struct.new(:installation_key, :template_key, :template_version, :checksum, :actions, keyword_init: true)

      def initialize(installation_key:, manifest:)
        @installation_key = installation_key.to_s
        @manifest = manifest
      end

      def call
        unless @installation_key.match?(ArtgenialTemplateInstallation::INSTALLATION_KEY_PATTERN)
          raise ArgumentError, 'installation_key must be an explicit installation UUID'
        end

        data = @manifest.data
        Validator.new.validate!(data)
        checksum = Checksum.call(data)
        installation = ArtgenialTemplateInstallation.find_by(
          installation_key: @installation_key,
          template_key: data.fetch('template_key'),
          template_version: data.fetch('version').to_s
        )
        previous_installation = ArtgenialTemplateInstallation
                                .where(installation_key: @installation_key, template_key: data.fetch('template_key'),
                                       status: 'applied')
                                .order(created_at: :desc).first
        @components = (installation || previous_installation)&.artgenial_template_components
        actions = []
        if installation && installation.checksum != checksum
          actions << action(:collision, 'template', data.fetch('template_key'), data.fetch('name'), nil,
                            'published version has a different checksum')
        else
          data.fetch('pipelines').each { |pipeline| plan_pipeline(pipeline, actions) }
          data.fetch('labels').each { |label| plan_label(label, actions) }
        end

        Plan.new(installation_key: @installation_key, template_key: data.fetch('template_key'),
                 template_version: data.fetch('version').to_s, checksum: checksum, actions: actions)
      end

      private

      def plan_pipeline(desired, actions)
        key = desired.fetch('key')
        linked = linked_record('pipeline', key, Pipeline)
        existing = Pipeline.find_by(name: desired.fetch('name'))
        operation, record, reason = decision(linked, existing, desired,
                                             %w[name pipeline_type visibility is_default])
        actions << action(operation, 'pipeline', key, desired.fetch('name'), record&.id, reason)
        desired.fetch('stages').each { |stage| plan_stage(key, stage, record, operation, actions) }
      end

      def plan_stage(pipeline_key, desired, pipeline_record, pipeline_operation, actions)
        key = "#{pipeline_key}.#{desired.fetch('key')}"
        if pipeline_operation == :collision || !pipeline_record
          operation = pipeline_operation == :create ? :create : :blocked
          actions << action(operation, 'stage', key, desired.fetch('name'), nil,
                            operation == :blocked ? 'parent pipeline has a collision' : nil)
          return
        end

        linked = linked_record('stage', key, PipelineStage)
        existing = pipeline_record.pipeline_stages.find_by(name: desired.fetch('name'))
        if linked && linked.pipeline_id != pipeline_record.id
          actions << action(:collision, 'stage', key, desired.fetch('name'), linked.id,
                            'managed stage belongs to a different pipeline')
          return
        end
        operation, record, reason = decision(linked, existing, desired, %w[name position stage_type])
        actions << action(operation, 'stage', key, desired.fetch('name'), record&.id, reason)
      end

      def plan_label(desired, actions)
        key = "label.#{desired.fetch('key')}"
        linked = linked_record('label', key, Label)
        existing = Label.find_by(title: desired.fetch('title'))
        operation, record, reason = decision(linked, existing, desired, %w[title color])
        actions << action(operation, 'label', key, desired.fetch('title'), record&.id, reason)
      end

      def linked_record(type, key, model)
        component = @components&.find_by(component_type: type, component_key: key)
        return nil unless component&.record_id && component.record_type == model.name

        model.find_by(id: component.record_id)
      end

      def decision(linked, existing, desired, fields)
        if linked
          if existing && existing.id != linked.id
            return [:collision, existing, 'desired visible name belongs to another record']
          end

          current = fields.index_with { |field| linked.public_send(field) }
          expected = desired.slice(*fields)
          return [current == expected ? :noop : :preserve, linked,
                  current == expected ? nil : 'managed record differs; phase 1 does not update']
        end
        return [:collision, existing, 'same visible name exists without a matching ledger link'] if existing

        [:create, nil, nil]
      end

      def action(operation, component_type, component_key, name, record_id, reason)
        Action.new(operation: operation, component_type: component_type,
                   component_key: component_key, name: name, record_id: record_id, reason: reason)
      end
    end
  end
end
