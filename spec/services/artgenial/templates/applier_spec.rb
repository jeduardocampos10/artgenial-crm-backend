# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Artgenial::Templates::Applier do
  let(:manifest) { Artgenial::Templates::Loader.new.load(template_key: 'artgenial.base', version: '1') }
  let(:installation_key) { SecureRandom.uuid }
  let(:actor) { User.create!(email: "artgenial-applier-#{SecureRandom.hex(4)}@example.com", name: 'Artgenial Applier') }

  def apply(key: installation_key, template: manifest, user: actor)
    described_class.new(installation_key: key, manifest: template, actor: user).call
  end

  def counts
    [Pipeline.count, PipelineStage.count, Label.count,
     ArtgenialTemplateInstallation.count, ArtgenialTemplateComponent.count]
  end

  it 'installs Base v1 with the approved totals and installation ledger' do
    before_counts = counts
    result = apply

    expect(result.status).to eq(:applied)
    expect(counts.zip(before_counts).map { |after_count, before_count| after_count - before_count }).to eq([6, 62, 29, 1, 97])
    installation = result.installation.reload
    expect(installation).to have_attributes(installation_key: installation_key, template_key: 'artgenial.base',
                                            template_version: '1', checksum: manifest.checksum, status: 'applied')
    expect(installation.installed_at).to be_present
    expect(installation.metadata['actor_id']).to eq(actor.id)
  end

  it 'links all 97 components to real records and stores their applied state' do
    installation = apply.installation

    components = installation.artgenial_template_components.to_a
    expect(components.group_by(&:component_type).transform_values(&:size)).to eq('pipeline' => 6, 'stage' => 62, 'label' => 29)
    components.each do |component|
      model = ArtgenialTemplateComponent::RECORD_TYPES.fetch(component.component_type).constantize
      record = model.find(component.record_id)
      expect(component.record_type).to eq(model.name)
      expect(component.status).to eq('applied')
      expect(component.last_applied_state).to eq(record.attributes.except('id', 'created_at', 'updated_at'))
    end
    expect(components.find { |component| component.component_key == 'label.origem_whatsapp' }.metadata['category']).to eq('origem')
  end

  it 'sets Vendas as the only default and retains the special stage types' do
    apply
    sales = Pipeline.find_by!(name: 'Vendas — Funil Comercial')
    expect(sales).to have_attributes(pipeline_type: 'sales', visibility: 'public', is_default: true, created_by_id: actor.id)
    expect(Pipeline.where(is_default: true).pluck(:id)).to eq([sales.id])
    expect(sales.pipeline_stages.pluck(:position)).to eq((1..13).to_a)
    expect(sales.pipeline_stages.find_by!(name: 'Ganho').stage_type).to eq('completed')
    expect(sales.pipeline_stages.find_by!(name: 'Perdido').stage_type).to eq('cancelled')
    expect(sales.pipeline_stages.find_by!(name: 'Abandono 30+').stage_type).to eq('active')
    expect(Label.find_by!(title: 'origem-whatsapp').color).to eq('#2563EB')
  end

  it 'returns already_applied without writing on an identical reapplication' do
    first = apply
    before_counts = counts
    before_timestamps = [first.installation.reload.updated_at,
                         first.installation.artgenial_template_components.order(:id).pluck(:updated_at)]

    second = apply

    expect(second.status).to eq(:already_applied)
    expect(second.installation.id).to eq(first.installation.id)
    expect(counts).to eq(before_counts)
    expect([first.installation.reload.updated_at,
            first.installation.artgenial_template_components.order(:id).pluck(:updated_at)]).to eq(before_timestamps)
  end

  it 'creates every pipeline, stage and label with the manifest attributes' do
    installation = apply.installation
    linked = installation.artgenial_template_components.index_by(&:component_key)

    manifest.data.fetch('pipelines').each do |definition|
      pipeline = Pipeline.find(linked.fetch(definition.fetch('key')).record_id)
      expect(pipeline.attributes.slice('name', 'pipeline_type', 'visibility', 'is_default')).to eq(
        definition.slice('name', 'pipeline_type', 'visibility', 'is_default')
      )
      definition.fetch('stages').each do |stage_definition|
        stage = PipelineStage.find(linked.fetch("#{definition.fetch('key')}.#{stage_definition.fetch('key')}").record_id)
        expect(stage.pipeline_id).to eq(pipeline.id)
        expect(stage.attributes.slice('name', 'position', 'stage_type')).to eq(
          stage_definition.slice('name', 'position', 'stage_type')
        )
      end
    end
    manifest.data.fetch('labels').each do |definition|
      label = Label.find(linked.fetch("label.#{definition.fetch('key')}").record_id)
      expect(label.attributes.slice('title', 'color')).to eq(definition.slice('title', 'color'))
    end
  end

  it 'preserves a renamed managed stage on reapplication' do
    apply
    stage = Pipeline.find_by!(name: 'Vendas — Funil Comercial').pipeline_stages.find_by!(name: 'Novo Lead')
    stage.update!(name: 'Entrada personalizada')
    before_counts = counts

    result = apply

    expect(result.status).to eq(:already_applied)
    expect(result.plan.actions.find { |action| action.component_key == 'sales.novo_lead' }.operation).to eq(:preserve)
    expect(stage.reload.name).to eq('Entrada personalizada')
    expect(counts).to eq(before_counts)
  end

  it 'rejects a manual pipeline collision and blocked children before any write' do
    manual = Pipeline.create!(name: 'Vendas — Funil Comercial', pipeline_type: 'sales', created_by: actor)
    before_counts = counts
    plan = Artgenial::Templates::Planner.new(installation_key: installation_key, manifest: manifest).call
    expect(plan.actions.find { |action| action.component_key == 'sales' }.operation).to eq(:collision)
    expect(plan.actions.find { |action| action.component_key == 'sales.novo_lead' }.operation).to eq(:blocked)

    expect { apply }.to raise_error(described_class::UnsafePlan, /collision/)
    expect(counts).to eq(before_counts)
    expect(manual.reload.name).to eq('Vendas — Funil Comercial')
  end

  it 'does not adopt or modify a manual label with a matching title' do
    manual = Label.create!(title: 'origem-whatsapp', color: '#123456')
    before_counts = counts

    expect { apply }.to raise_error(described_class::UnsafePlan, /collision/)
    expect(counts).to eq(before_counts)
    expect(manual.reload.color).to eq('#123456')
  end

  it 'refuses to clear an unrelated default pipeline through the Pipeline callback' do
    external = Pipeline.create!(name: 'Default externo', pipeline_type: 'custom', is_default: true, created_by: actor)
    before_counts = counts

    expect { apply }.to raise_error(described_class::UnsafePlan, /already default/)
    expect(counts).to eq(before_counts)
    expect(external.reload.is_default).to be(true)
  end

  it 'leaves unrelated records untouched and never deletes them' do
    external = Pipeline.create!(name: 'Pipeline externo', pipeline_type: 'custom', created_by: actor)
    external_label = Label.create!(title: 'etiqueta-externa', color: '#123456')
    apply

    expect(external.reload).to have_attributes(name: 'Pipeline externo', is_default: false)
    expect(external_label.reload).to have_attributes(title: 'etiqueta-externa', color: '#123456')
    expect(Pipeline.exists?(external.id)).to be(true)
    expect(Label.exists?(external_label.id)).to be(true)
  end

  it 'rolls back product and ledger rows when a later component fails' do
    before_counts = counts
    allow(Label).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(Label.new))

    expect { apply }.to raise_error(ActiveRecord::RecordInvalid)
    expect(counts).to eq(before_counts)
  end

  it 'requires an explicit UUID and persisted actor' do
    before_counts = counts
    expect { apply(key: 'not-a-uuid') }.to raise_error(ArgumentError, /installation_key/)
    expect { apply(user: User.new) }.to raise_error(ArgumentError, /actor/)
    expect(counts).to eq(before_counts)
  end

  it 'rejects a changed checksum or version instead of treating it as the installed v1' do
    apply
    before_counts = counts
    changed_data = manifest.data.deep_dup
    changed_data['labels'][0]['color'] = '#000000'
    changed = Artgenial::Templates::Loader::Manifest.new(
      data: changed_data, checksum: Artgenial::Templates::Checksum.call(changed_data)
    )
    next_version_data = manifest.data.deep_dup.merge('version' => '2')
    next_version = Artgenial::Templates::Loader::Manifest.new(
      data: next_version_data, checksum: Artgenial::Templates::Checksum.call(next_version_data)
    )

    expect { apply(template: changed) }.to raise_error(described_class::UnsafePlan, /approved.*Base v1/)
    expect { apply(template: next_version) }.to raise_error(described_class::UnsafePlan, /approved.*Base v1/)
    expect(counts).to eq(before_counts)
  end

  it 'rejects an existing incomplete ledger instead of silently adopting rows' do
    ArtgenialTemplateInstallation.create!(installation_key: installation_key,
                                          template_key: 'artgenial.base', template_version: '1',
                                          checksum: manifest.checksum, status: 'planned')
    before_counts = counts

    expect { apply }.to raise_error(described_class::UnsafePlan, /not fully applied/)
    expect(counts).to eq(before_counts)
  end

  it 'rejects the same installation identity with a different stored checksum' do
    ArtgenialTemplateInstallation.create!(installation_key: installation_key,
                                          template_key: 'artgenial.base', template_version: '1',
                                          checksum: 'f' * 64, status: 'planned')
    before_counts = counts

    expect { apply }.to raise_error(described_class::UnsafePlan)
    expect(counts).to eq(before_counts)
  end

  it 'does not report already_applied when a ledger component loses its record link' do
    installation = apply.installation
    installation.artgenial_template_components.find_by!(component_key: 'sales').update!(record_id: nil)
    before_counts = counts

    expect { apply }.to raise_error(described_class::UnsafePlan)
    expect(counts).to eq(before_counts)
  end
end
