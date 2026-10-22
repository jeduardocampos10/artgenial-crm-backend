# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Artgenial::Templates::Planner do
  let(:manifest) { Artgenial::Templates::Loader.new.load(template_key: 'artgenial.base', version: '1') }
  let(:installation_key) { SecureRandom.uuid }

  def plan
    described_class.new(installation_key: installation_key, manifest: manifest).call
  end

  it 'reports CREATE for every absent component without writing product or ledger rows' do
    before_counts = [Pipeline.count, PipelineStage.count, Label.count,
                     ArtgenialTemplateInstallation.count, ArtgenialTemplateComponent.count]
    actions = plan.actions
    after_counts = [Pipeline.count, PipelineStage.count, Label.count,
                    ArtgenialTemplateInstallation.count, ArtgenialTemplateComponent.count]

    expect(after_counts).to eq(before_counts)
    expect(actions.count { |item| item.operation == :create && item.component_type == 'pipeline' }).to eq(6)
    expect(actions.count { |item| item.operation == :create && item.component_type == 'stage' }).to eq(62)
    expect(actions.count { |item| item.operation == :create && item.component_type == 'label' }).to eq(29)
    expect(actions.size).to eq(97)
  end

  it 'reports COLLISION without adopting, renaming or creating an existing pipeline and label' do
    user = User.create!(email: "artgenial-#{SecureRandom.hex(4)}@example.com", name: 'Artgenial Test')
    sales = Pipeline.create!(name: 'Vendas — Funil Comercial', pipeline_type: 'sales', created_by: user)
    label = Label.create!(title: 'origem-whatsapp')
    before_counts = [Pipeline.count, PipelineStage.count, Label.count,
                     ArtgenialTemplateInstallation.count, ArtgenialTemplateComponent.count]

    actions = plan.actions
    expect(actions.find { |item| item.component_key == 'sales' }.operation).to eq(:collision)
    expect(actions.find { |item| item.component_key == 'sales.novo_lead' }.operation).to eq(:blocked)
    expect(actions.find { |item| item.component_key == 'label.origem_whatsapp' }.operation).to eq(:collision)
    expect(sales.reload.name).to eq('Vendas — Funil Comercial')
    expect(label.reload.title).to eq('origem-whatsapp')
    expect([Pipeline.count, PipelineStage.count, Label.count,
            ArtgenialTemplateInstallation.count, ArtgenialTemplateComponent.count]).to eq(before_counts)
  end

  it 'recognizes a linked managed record and reports NOOP without writing' do
    user = User.create!(email: "artgenial-#{SecureRandom.hex(4)}@example.com", name: 'Artgenial Test')
    sales = Pipeline.create!(name: 'Vendas — Funil Comercial', pipeline_type: 'sales',
                             visibility: :public, is_default: true, created_by: user)
    installation = ArtgenialTemplateInstallation.create!(installation_key: installation_key,
                                                         template_key: 'artgenial.base', template_version: '1',
                                                         checksum: manifest.checksum)
    installation.artgenial_template_components.create!(component_type: 'pipeline', component_key: 'sales',
                                                       record_type: 'Pipeline', record_id: sales.id)
    expect(plan.actions.find { |item| item.component_key == 'sales' }.operation).to eq(:noop)
    expect(ArtgenialTemplateComponent.count).to eq(1)
  end

  it 'uses the last applied version to recognize a managed record during a future version preview' do
    user = User.create!(email: "artgenial-#{SecureRandom.hex(4)}@example.com", name: 'Artgenial Test')
    sales = Pipeline.create!(name: 'Vendas — Funil Comercial', pipeline_type: 'sales',
                             visibility: :public, is_default: true, created_by: user)
    installed = ArtgenialTemplateInstallation.create!(installation_key: installation_key,
                                                      template_key: 'artgenial.base', template_version: '1',
                                                      checksum: manifest.checksum, status: 'applied',
                                                      installed_at: Time.current)
    installed.artgenial_template_components.create!(component_type: 'pipeline', component_key: 'sales',
                                                    record_type: 'Pipeline', record_id: sales.id)
    next_data = manifest.data.deep_dup.merge('version' => '2')
    next_manifest = Artgenial::Templates::Loader::Manifest.new(data: next_data,
                                                               checksum: Artgenial::Templates::Checksum.call(next_data))
    next_plan = described_class.new(installation_key: installation_key, manifest: next_manifest).call
    expect(next_plan.actions.find { |item| item.component_key == 'sales' }.operation).to eq(:noop)
  end

  it 'reports a checksum collision for a published version that changed' do
    ArtgenialTemplateInstallation.create!(installation_key: installation_key, template_key: 'artgenial.base',
                                          template_version: '1', checksum: 'f' * 64)
    actions = plan.actions
    expect(actions.size).to eq(1)
    expect(actions.first.operation).to eq(:collision)
    expect(actions.first.reason).to match(/different checksum/)
  end

  it 'requires an explicit installation key' do
    expect { described_class.new(installation_key: '', manifest: manifest).call }
      .to raise_error(ArgumentError, /installation_key/)
  end
end
