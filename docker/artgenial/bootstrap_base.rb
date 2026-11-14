# frozen_string_literal: true
manifest = Artgenial::Templates::Loader.new.load(template_key: 'artgenial.base', version: '1')
actor = User.find_by!(email: ENV.fetch('ADMIN_EMAIL').downcase)
result = Artgenial::Templates::Applier.new(
  installation_key: ENV.fetch('INSTALLATION_KEY'), manifest: manifest, actor: actor
).call
raise 'Base ArtGenial not applied' unless %i[applied already_applied].include?(result.status)
