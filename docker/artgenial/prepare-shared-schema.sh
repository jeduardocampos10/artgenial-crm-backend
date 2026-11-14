#!/bin/sh
set -eu

state="$(bundle exec ruby -r pg -e '
connection = PG.connect(
  host: ENV.fetch("POSTGRES_HOST"),
  port: ENV.fetch("POSTGRES_PORT"),
  dbname: ENV.fetch("POSTGRES_DATABASE"),
  user: ENV.fetch("POSTGRES_USERNAME"),
  password: ENV.fetch("POSTGRES_PASSWORD")
)
count = connection.exec_params(
  "SELECT count(*) FROM information_schema.tables WHERE table_schema = $1 AND table_type = $2",
  ["public", "BASE TABLE"]
).getvalue(0, 0).to_i
if count.zero?
  puts "empty"
elsif connection.exec_params(
  "SELECT to_regclass($1) IS NOT NULL",
  ["public.schema_migrations"]
).getvalue(0, 0) == "t"
  puts "ready"
else
  abort "Existing database has no migration ledger; manual review required"
end
' )"

case "$state" in
  empty)
    echo "Preparing empty shared schema from the CRM master schema"
    bundle exec rails db:schema:load
    ;;
  ready)
    echo "Shared schema already exists with a migration ledger"
    ;;
  *)
    echo "Could not inspect the shared database" >&2
    exit 1
    ;;
esac
