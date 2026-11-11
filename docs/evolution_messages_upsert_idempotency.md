# Evolution `messages.upsert` idempotency rollout

Evolution message identity is `(inbox_id, source_id)`. Redis provides a short, atomic
`SET NX EX` contention guard, but PostgreSQL's partial unique index is the correctness
boundary. Redis failures therefore fail open and are resolved by the database constraint.

## Required CI checks

Ruby is not available on the implementation host, so CI must run at least:

```bash
bundle exec rspec spec/services/whatsapp/evolution_handlers/messages_upsert_guard_spec.rb
bundle exec rspec spec/migrations/add_unique_inbox_source_id_to_messages_spec.rb
```

The complete backend RSpec suite should also remain required before merge.

## Required homologation preflight

Run the migration in homologation before production:

```bash
bundle exec rails db:migrate
```

Migration `20261028120000_add_unique_inbox_source_id_to_messages` performs a read-only
preflight and aborts if duplicate nonblank `(inbox_id, source_id)` identities exist. Its
error reports aggregate counts only. It never deletes or rewrites messages.

If the preflight fails:

1. stop the rollout;
2. inspect the duplicate groups under the normal restricted data-access process;
3. reconcile them in an explicitly reviewed maintenance operation that preserves audit
   requirements and attachments;
4. rerun the migration;
5. verify that `index_messages_on_inbox_id_and_source_id_unique` is valid and unique.

The index is built concurrently. An interrupted concurrent build can leave an invalid
index; the migration removes only that invalid index artifact before retrying and does not
remove message rows.
