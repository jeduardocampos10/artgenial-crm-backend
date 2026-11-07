# Customer memory foundation (Phase 3, Block 1)

The CRM PostgreSQL database is the canonical store for each installation. Its
`contacts.id` UUID is the subject identifier. One database belongs to one
installation; a future shared deployment must add an explicit installation
scope before reusing the event/idempotency indexes across installations.

## Domain boundaries

- `ContactIdentity` is an external identifier, not a second customer. A live
  identifier is unique by type, provider and optional inbox scope. `NULL`
  inbox is a single provider-wide scope. End an identity by setting
  `valid_until`; no contact backfill or similarity matching is performed.
- `ContactCompany` remains the existing N:N link. Role and validity belong to
  the relationship, not to either contact's individual memory.
- `MemoryRecord` owns a typed, scoped assertion. `fact` means a source made or
  proved a statement; it does not claim universal truth. An `inference` must
  carry confidence and a separate review status. Evidence rows reference sources instead of copying raw
  messages. A replacement record points at its predecessor; the predecessor
  stays queryable.
- `CustomerEvent` is an append-only operational ledger. Its payload must be
  small and must not include raw message bodies or credentials. The unique key
  is `(source_system, idempotency_key)` inside the installation database.
- `EventOutbox` is written in the same database transaction. No external
  publisher or delivery destination is connected in this block.

Use `CustomerMemory::Record`, `CustomerMemory::Supersede`,
`CustomerMemory::AttachEvidence`, `CustomerEvents::Record`, and
`ContactIdentities::Register` for new writes. `Register` returns a conflict and
records an event when another contact owns a candidate identity. It never
merges contacts. Callers must supply normalized phone/WhatsApp values; email
case and surrounding whitespace are normalized in the model.

The legacy contact merger now refuses a merge involving memory, identities,
events, an existing person/company relationship on the mergee, or a lead
`PipelineItem` on the mergee. The caller must reconcile those structures
explicitly in a later block. No bulk history backfill, message listener,
external publisher, retrieval API, or AI decision component is installed.

`value` is limited to 8 KiB and metadata/payload/envelopes to 4 KiB at the
model layer; credential-shaped keys are rejected. These checks do not replace
authorization and data classification at the eventual ingestion boundary.
Database foreign keys restrict accidental deletion while retention and
anonymization flows await a dedicated design.
