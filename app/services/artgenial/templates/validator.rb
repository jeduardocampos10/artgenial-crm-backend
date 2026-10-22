# frozen_string_literal: true

module Artgenial
  module Templates
    class Validator
      class InvalidManifest < StandardError; end

      SCHEMA_VERSION = 1
      KEY_PATTERN = /\A[a-z][a-z0-9_]*\z/
      TEMPLATE_KEY_PATTERN = /\Aartgenial\.(?:base|segment\.[a-z][a-z0-9_]*)\z/
      TITLE_PATTERN = /\A[\p{L}\p{N}]+(?:[ _-]*[\p{L}\p{N}]+)*\z/
      COLOR_PATTERN = /\A#[0-9a-fA-F]{6}\z/
      FORBIDDEN_LABELS = %w[followup-1d followup-5d followup-15d followup-30d abandono-30].freeze
      PIPELINE_TYPES = %w[sales support onboarding custom marketing].freeze
      STAGE_TYPES = %w[active completed cancelled].freeze

      def validate!(manifest)
        @errors = []
        unless manifest.is_a?(Hash)
          raise InvalidManifest, 'manifest must be a mapping'
        end

        @manifest_template_key = manifest['template_key']
        validate_header(manifest)
        reject_database_ids(manifest)
        validate_pipelines(manifest['pipelines'])
        validate_labels(manifest['labels'])
        raise InvalidManifest, @errors.join('; ') if @errors.any?

        manifest
      end

      private

      def validate_header(manifest)
        @errors << 'template_key is required or invalid' unless manifest['template_key'].to_s.match?(TEMPLATE_KEY_PATTERN)
        version = manifest['version']
        @errors << 'version must be a positive integer string' unless version.is_a?(String) && version.match?(/\A[1-9]\d*\z/)
        @errors << "schema_version must be #{SCHEMA_VERSION}" unless manifest['schema_version'] == SCHEMA_VERSION
        @errors << 'name is required' if manifest['name'].blank?
      end

      def reject_database_ids(value, path = 'manifest')
        case value
        when Hash
          value.each do |key, child|
            @errors << "#{path}.#{key} must not contain a database ID" if key.to_s == 'id' || key.to_s.end_with?('_id')
            reject_database_ids(child, "#{path}.#{key}")
          end
        when Array
          value.each_with_index { |child, index| reject_database_ids(child, "#{path}[#{index}]") }
        when String
          @errors << "#{path} must not contain a database UUID" if value.match?(/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i)
        end
      end

      def validate_pipelines(pipelines)
        unless pipelines.is_a?(Array)
          @errors << 'pipelines must be an array'
          return
        end

        @errors << 'base template requires pipelines' if base_template? && pipelines.empty?
        keys = []
        names = []
        defaults = 0
        pipelines.each_with_index do |pipeline, index|
          path = "pipelines[#{index}]"
          next @errors << "#{path} must be a mapping" unless pipeline.is_a?(Hash)

          validate_key(pipeline['key'], path)
          keys << pipeline['key']
          names << pipeline['name']
          @errors << "#{path}.name is required" if pipeline['name'].blank?
          @errors << "#{path}.pipeline_type is invalid" unless PIPELINE_TYPES.include?(pipeline['pipeline_type'])
          @errors << "#{path}.visibility must be public" unless pipeline['visibility'] == 'public'
          @errors << "#{path}.is_default must be boolean" unless [true, false].include?(pipeline['is_default'])
          defaults += 1 if pipeline['is_default'] == true
          validate_stages(pipeline['stages'], path)
        end
        @errors << 'pipeline keys must be unique' if keys.uniq.length != keys.length
        @errors << 'pipeline names must be unique' if names.uniq.length != names.length
        @errors << 'exactly one base pipeline must be default' if base_template? && defaults != 1
        @errors << 'at most one pipeline may be default' if defaults > 1
      end

      def validate_stages(stages, pipeline_path)
        unless stages.is_a?(Array) && stages.any?
          @errors << "#{pipeline_path}.stages must be a non-empty array"
          return
        end

        keys = []
        positions = []
        stages.each_with_index do |stage, index|
          path = "#{pipeline_path}.stages[#{index}]"
          next @errors << "#{path} must be a mapping" unless stage.is_a?(Hash)

          validate_key(stage['key'], path)
          keys << stage['key']
          @errors << "#{path}.name is required" if stage['name'].blank?
          @errors << "#{path}.stage_type is invalid" unless STAGE_TYPES.include?(stage['stage_type'])
          @errors << "#{path}.position must be a positive integer" unless stage['position'].is_a?(Integer) && stage['position'].positive?
          positions << stage['position']
        end
        @errors << "#{pipeline_path} stage keys must be unique" if keys.uniq.length != keys.length
        @errors << "#{pipeline_path} stage positions must be consecutive from 1" unless positions.sort == (1..stages.length).to_a
      end

      def validate_labels(labels)
        unless labels.is_a?(Array)
          @errors << 'labels must be an array'
          return
        end

        @errors << 'base template requires labels' if base_template? && labels.empty?
        keys = []
        titles = []
        labels.each_with_index do |label, index|
          path = "labels[#{index}]"
          next @errors << "#{path} must be a mapping" unless label.is_a?(Hash)

          validate_key(label['key'], path)
          keys << label['key']
          title = label['title']
          titles << title
          @errors << "#{path}.title is invalid" unless title.is_a?(String) && title.match?(TITLE_PATTERN)
          @errors << "#{path}.title must be lowercase" if title.is_a?(String) && title != title.downcase
          @errors << "#{path}.title is a prohibited stage mirror" if FORBIDDEN_LABELS.include?(title)
          @errors << "#{path}.category is required" if label['category'].blank?
          @errors << "#{path}.color must be a six-digit hex color" unless label['color'].to_s.match?(COLOR_PATTERN)
        end
        @errors << 'label keys must be unique' if keys.uniq.length != keys.length
        @errors << 'label titles must be unique' if titles.uniq.length != titles.length
      end

      def validate_key(key, path)
        @errors << "#{path}.key is required or invalid" unless key.is_a?(String) && key.match?(KEY_PATTERN)
      end

      def base_template?
        @manifest_template_key == 'artgenial.base'
      end
    end
  end
end
