# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ArtgenialTemplateComponent, type: :model do
  let(:installation) do
    ArtgenialTemplateInstallation.create!(installation_key: SecureRandom.uuid,
                                          template_key: 'artgenial.base', template_version: '1', checksum: 'b' * 64)
  end

  it 'requires a unique logical key and matching record type' do
    described_class.create!(artgenial_template_installation: installation, component_type: 'pipeline',
                            component_key: 'sales', record_type: 'Pipeline')
    duplicate = described_class.new(artgenial_template_installation: installation, component_type: 'pipeline',
                                    component_key: 'sales', record_type: 'Pipeline')
    expect(duplicate).not_to be_valid
    mismatched = described_class.new(artgenial_template_installation: installation, component_type: 'label',
                                     component_key: 'label.vip', record_type: 'Pipeline')
    expect(mismatched).not_to be_valid
    stored = described_class.find_by!(artgenial_template_installation: installation, component_key: 'sales')
    expect(stored.update(component_key: 'sales_renamed')).to be(false)
  end

  it 'does not own or delete the product record' do
    user = User.create!(email: "artgenial-#{SecureRandom.hex(4)}@example.com", name: 'Artgenial Test')
    pipeline = Pipeline.create!(name: "Artgenial Test #{SecureRandom.hex(4)}", pipeline_type: 'sales', created_by: user)
    component = described_class.create!(artgenial_template_installation: installation,
                                        component_type: 'pipeline', component_key: 'sales',
                                        record_type: 'Pipeline', record_id: pipeline.id)
    component.destroy!
    expect(Pipeline.exists?(pipeline.id)).to be(true)
  end
end
