create table if not exists importer_apply_runs (
  transaction_id text primary key,
  plan_idempotency_key text not null unique,
  rollback_snapshot_idempotency_key text not null,
  idempotency_manifest_key text not null,
  tenant_id uuid not null,
  idempotency_manifest_json jsonb not null,
  status text not null check (status in ('prepared', 'applied', 'rolled_back', 'blocked')),
  dry_run_contract boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (length(btrim(transaction_id)) > 0),
  check (length(btrim(plan_idempotency_key)) > 0),
  check (length(btrim(rollback_snapshot_idempotency_key)) > 0),
  check (length(btrim(idempotency_manifest_key)) > 0),
  check (jsonb_typeof(idempotency_manifest_json) = 'object')
);

create table if not exists importer_apply_operation_journal (
  snapshot_entry_id text primary key,
  transaction_id text not null references importer_apply_runs(transaction_id) on delete cascade,
  operation_id text not null,
  operation_idempotency_key text not null,
  target_kind text not null,
  target_natural_key_hash text not null,
  rollback_action text not null check (rollback_action in ('delete_created_object', 'restore_previous_object')),
  before_image_json jsonb not null,
  before_image_hash text,
  after_hash text not null,
  rollback_entry_json jsonb not null,
  status text not null check (status in ('prepared', 'skipped_same_after_hash', 'applied', 'rolled_back', 'blocked')),
  error_summary_json jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (transaction_id, operation_id),
  unique (operation_idempotency_key, target_kind, target_natural_key_hash),
  check (length(btrim(snapshot_entry_id)) > 0),
  check (length(btrim(operation_id)) > 0),
  check (length(btrim(operation_idempotency_key)) > 0),
  check (length(btrim(target_kind)) > 0),
  check (length(btrim(target_natural_key_hash)) > 0),
  check (length(btrim(after_hash)) > 0),
  check (before_image_hash is null or length(btrim(before_image_hash)) > 0),
  check (jsonb_typeof(before_image_json) = 'object'),
  check (jsonb_typeof(rollback_entry_json) = 'object'),
  check (jsonb_typeof(error_summary_json) = 'object')
);

create index if not exists idx_importer_apply_operation_journal_transaction
  on importer_apply_operation_journal(transaction_id, status);

create index if not exists idx_importer_apply_operation_journal_target
  on importer_apply_operation_journal(target_kind, target_natural_key_hash);
