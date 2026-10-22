# frozen_string_literal: true

namespace :artgenial do
  namespace :templates do
    desc 'Validate a versioned ArtGenial manifest without writing data'
    task validate: :environment do
      key = ENV.fetch('TEMPLATE_KEY', 'artgenial.base')
      version = ENV.fetch('TEMPLATE_VERSION', '1')
      manifest = Artgenial::Templates::Loader.new.load(template_key: key, version: version)
      puts JSON.pretty_generate(template_key: key, version: version, checksum: manifest.checksum,
                                pipelines: manifest.data.fetch('pipelines').size,
                                stages: manifest.data.fetch('pipelines').sum { |pipeline| pipeline.fetch('stages').size },
                                labels: manifest.data.fetch('labels').size)
    end

    desc 'Preview ArtGenial template actions without writing data; requires INSTALLATION_KEY'
    task plan: :environment do
      key = ENV.fetch('TEMPLATE_KEY', 'artgenial.base')
      version = ENV.fetch('TEMPLATE_VERSION', '1')
      installation_key = ENV.fetch('INSTALLATION_KEY')
      manifest = Artgenial::Templates::Loader.new.load(template_key: key, version: version)
      plan = Artgenial::Templates::Planner.new(installation_key: installation_key, manifest: manifest).call
      puts JSON.pretty_generate(plan.to_h.merge(actions: plan.actions.map(&:to_h)))
    end
  end
end
