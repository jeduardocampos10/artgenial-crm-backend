# frozen_string_literal: true

require 'yaml'

module Artgenial
  module Templates
    class Loader
      class MissingTemplate < StandardError; end
      class InvalidYaml < StandardError; end

      Manifest = Struct.new(:data, :checksum, :path, keyword_init: true)

      def initialize(root: Rails.root.join('config/artgenial/templates'))
        @root = Pathname.new(root)
      end

      def load(template_key:, version:)
        path = path_for(template_key, version)
        raise MissingTemplate, "template not found: #{template_key} v#{version}" unless path.file?

        data = YAML.safe_load(path.read(encoding: 'UTF-8'), permitted_classes: [], permitted_symbols: [], aliases: false)
        data = data.deep_stringify_keys if data.is_a?(Hash)
        Validator.new.validate!(data)
        raise Validator::InvalidManifest, 'template_key does not match requested template' unless data['template_key'] == template_key
        raise Validator::InvalidManifest, 'version does not match requested version' unless data['version'].to_s == version.to_s

        Manifest.new(data: data, checksum: Checksum.call(data), path: path)
      rescue Psych::Exception => e
        raise InvalidYaml, "invalid YAML: #{e.message}"
      end

      private

      def path_for(template_key, version)
        unless template_key.to_s.match?(Validator::TEMPLATE_KEY_PATTERN) && version.to_s.match?(/\A[1-9]\d*\z/)
          raise MissingTemplate, 'invalid template key or version'
        end

        segments = template_key == 'artgenial.base' ? ['base'] : ['segments', template_key.delete_prefix('artgenial.segment.')]
        @root.join(*segments, "v#{version}.yml")
      end
    end
  end
end
