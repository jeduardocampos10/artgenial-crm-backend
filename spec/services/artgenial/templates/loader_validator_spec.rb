# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'
require 'fileutils'

RSpec.describe Artgenial::Templates::Loader do
  subject(:loaded) { Artgenial::Templates::Loader.new.load(template_key: 'artgenial.base', version: '1') }

  def copy_manifest
    loaded.data.deep_dup
  end

  it 'loads the versioned Base v1 with the approved totals and identities' do
    data = loaded.data
    expect(data.fetch('pipelines').size).to eq(6)
    expect(data.fetch('pipelines').sum { |pipeline| pipeline.fetch('stages').size }).to eq(62)
    expect(data.fetch('labels').size).to eq(29)
    expect(data.fetch('pipelines').first.fetch('stages').size).to eq(13)
    expect(data.fetch('pipelines').count { |pipeline| pipeline['is_default'] }).to eq(1)
    expect(data.fetch('pipelines').first.slice('key', 'is_default')).to eq('key' => 'sales', 'is_default' => true)
  end

  it 'represents Ganho, Perdido and Abandono 30+ with the approved stage types' do
    stages = loaded.data.fetch('pipelines').first.fetch('stages').index_by { |stage| stage.fetch('key') }
    expect(stages.fetch('ganho').fetch('stage_type')).to eq('completed')
    expect(stages.fetch('perdido').fetch('stage_type')).to eq('cancelled')
    expect(stages.fetch('abandono_30_plus').fetch('stage_type')).to eq('active')
  end

  it 'rejects a missing manifest and path traversal' do
    expect { described_class.new.load(template_key: 'artgenial.segment.veterinary', version: '1') }
      .to raise_error(described_class::MissingTemplate)
    expect { described_class.new.load(template_key: '../base', version: '1') }
      .to raise_error(described_class::MissingTemplate)
  end

  it 'rejects malformed YAML and object deserialization' do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, 'base'))
      path = File.join(root, 'base', 'v1.yml')
      File.write(path, "pipelines: [\n")
      expect { described_class.new(root: root).load(template_key: 'artgenial.base', version: '1') }
        .to raise_error(described_class::InvalidYaml)
      File.write(path, "--- !ruby/object:Object {}\n")
      expect { described_class.new(root: root).load(template_key: 'artgenial.base', version: '1') }
        .to raise_error(described_class::InvalidYaml)
    end
  end

  describe Artgenial::Templates::Validator do
    subject(:validator) { described_class.new }

    it 'accepts Base v1' do
      expect { validator.validate!(copy_manifest) }.not_to raise_error
    end

    it 'rejects duplicate pipeline, stage and label keys in their scopes' do
      data = copy_manifest
      data['pipelines'][1]['key'] = data['pipelines'][0]['key']
      data['pipelines'][0]['stages'][1]['key'] = data['pipelines'][0]['stages'][0]['key']
      data['labels'][1]['key'] = data['labels'][0]['key']
      expect { validator.validate!(data) }.to raise_error(described_class::InvalidManifest) { |error|
        expect(error.message).to include('pipeline keys must be unique', 'stage keys must be unique', 'label keys must be unique')
      }
    end

    it 'rejects nonconsecutive positions, invalid stage type and multiple defaults' do
      data = copy_manifest
      data['pipelines'][1]['is_default'] = true
      data['pipelines'][0]['stages'][1]['position'] = 99
      data['pipelines'][0]['stages'][0]['stage_type'] = 'won'
      expect { validator.validate!(data) }.to raise_error(described_class::InvalidManifest) { |error|
        expect(error.message).to include('stage_type is invalid', 'stage positions must be consecutive', 'at most one pipeline may be default')
      }
    end

    it 'rejects follow-up labels, database IDs and invalid titles' do
      data = copy_manifest
      data['labels'][0]['title'] = 'followup-1d'
      data['labels'][1]['title'] = 'invalid!'
      data['pipelines'][0]['id'] = SecureRandom.uuid
      expect { validator.validate!(data) }.to raise_error(described_class::InvalidManifest, /database ID.*prohibited stage mirror/)
    end

    it 'rejects unsupported schema versions and missing component keys' do
      data = copy_manifest
      data['schema_version'] = 2
      data['pipelines'][0].delete('key')
      expect { validator.validate!(data) }.to raise_error(described_class::InvalidManifest, /schema_version.*key is required/)
    end

    it 'finds no fixed database UUIDs in the published manifest' do
      expect(copy_manifest.to_json).not_to match(/[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}/i)
    end
  end

  describe Artgenial::Templates::Checksum do
    it 'is deterministic across hash key order and changes on logical edits' do
      original = copy_manifest
      reordered = original.deep_dup.to_a.reverse.to_h
      expect(described_class.call(original)).to eq(described_class.call(reordered))
      reordered['labels'][0]['title'] = 'origem-alterada'
      expect(described_class.call(original)).not_to eq(described_class.call(reordered))
    end
  end
end
