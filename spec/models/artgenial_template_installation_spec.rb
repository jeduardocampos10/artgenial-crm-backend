# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ArtgenialTemplateInstallation, type: :model do
  def attributes
    { installation_key: SecureRandom.uuid, template_key: 'artgenial.base', template_version: '1',
      checksum: 'a' * 64, status: 'planned' }
  end

  it 'prevents duplicate template version per installation but permits another version' do
    first = described_class.create!(attributes)
    expect(described_class.new(attributes)).not_to be_valid
    expect(described_class.new(attributes.merge(template_version: '2'))).to be_valid
    expect(described_class.new(attributes.merge(installation_key: SecureRandom.uuid))).to be_valid
    expect(first.update(template_version: '2')).to be(false)
  end

  it 'does not cascade deletion into managed components' do
    installation = described_class.create!(attributes)
    installation.artgenial_template_components.create!(component_type: 'pipeline', component_key: 'sales', record_type: 'Pipeline')
    expect(installation.destroy).to be(false)
    expect(described_class.exists?(installation.id)).to be(true)
  end
end
