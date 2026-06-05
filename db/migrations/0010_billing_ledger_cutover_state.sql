create table if not exists billing_ledger_writer_cutover_state (
  environment_scope text primary key,
  active_writer text not null default 'control_plane_local_sql_writer',
  source_of_truth text not null default 'control_plane_local_sql_writer',
  previous_active_writer text null,
  previous_source_of_truth text null,
  cutover_generation bigint not null default 0,
  rollback_generation bigint not null default 0,
  rollback_token_hash text null,
  no_dual_commit boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by text not null default 'migration_default',
  check (environment_scope in ('local_dev', 'staging', 'production')),
  check (active_writer in ('control_plane_local_sql_writer', 'billing_ledger_runtime_writer')),
  check (source_of_truth in ('control_plane_local_sql_writer', 'billing_ledger_runtime_writer')),
  check (previous_active_writer is null or previous_active_writer in ('control_plane_local_sql_writer', 'billing_ledger_runtime_writer')),
  check (previous_source_of_truth is null or previous_source_of_truth in ('control_plane_local_sql_writer', 'billing_ledger_runtime_writer')),
  check (cutover_generation >= 0),
  check (rollback_generation >= 0),
  check (jsonb_typeof(metadata) = 'object')
);

create table if not exists billing_ledger_writer_cutover_audit (
  id uuid primary key default gen_random_uuid(),
  environment_scope text not null,
  action text not null,
  from_active_writer text null,
  from_source_of_truth text null,
  to_active_writer text not null,
  to_source_of_truth text not null,
  expected_generation bigint null,
  resulting_generation bigint not null,
  rollback_generation bigint not null,
  rollback_token_hash text null,
  no_dual_commit boolean not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  created_by text not null,
  check (environment_scope in ('local_dev', 'staging', 'production')),
  check (action in ('seed_default', 'source_of_truth_switch', 'rollback_to_local_writer', 'readback')),
  check (to_active_writer in ('control_plane_local_sql_writer', 'billing_ledger_runtime_writer')),
  check (to_source_of_truth in ('control_plane_local_sql_writer', 'billing_ledger_runtime_writer')),
  check (from_active_writer is null or from_active_writer in ('control_plane_local_sql_writer', 'billing_ledger_runtime_writer')),
  check (from_source_of_truth is null or from_source_of_truth in ('control_plane_local_sql_writer', 'billing_ledger_runtime_writer')),
  check (resulting_generation >= 0),
  check (rollback_generation >= 0),
  check (jsonb_typeof(metadata) = 'object')
);

create index if not exists idx_billing_ledger_writer_cutover_audit_scope_created
  on billing_ledger_writer_cutover_audit(environment_scope, created_at desc);

alter table billing_ledger_writer_cutover_state
  add column if not exists active_writer text not null default 'control_plane_local_sql_writer',
  add column if not exists source_of_truth text not null default 'control_plane_local_sql_writer',
  add column if not exists previous_active_writer text null,
  add column if not exists previous_source_of_truth text null,
  add column if not exists cutover_generation bigint not null default 0,
  add column if not exists rollback_generation bigint not null default 0,
  add column if not exists rollback_token_hash text null,
  add column if not exists no_dual_commit boolean not null default true,
  add column if not exists metadata jsonb not null default '{}'::jsonb,
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists updated_by text not null default 'migration_default';

update billing_ledger_writer_cutover_state
set no_dual_commit = coalesce(no_dual_commit, true);

do $$
begin
  if exists (
    select 1
    from information_schema.columns
    where table_name = 'billing_ledger_writer_cutover_state'
      and column_name = 'no_dual_commit_marker'
  ) then
    update billing_ledger_writer_cutover_state
    set no_dual_commit = coalesce(no_dual_commit, no_dual_commit_marker, true);
  end if;
end $$;

insert into billing_ledger_writer_cutover_state (
  environment_scope,
  active_writer,
  source_of_truth,
  previous_active_writer,
  previous_source_of_truth,
  cutover_generation,
  rollback_generation,
  no_dual_commit,
  metadata,
  updated_by
)
values
  ('local_dev', 'control_plane_local_sql_writer', 'control_plane_local_sql_writer', null, null, 0, 0, true, '{"seeded_by":"0010_billing_ledger_cutover_state"}'::jsonb, 'migration_default'),
  ('staging', 'control_plane_local_sql_writer', 'control_plane_local_sql_writer', null, null, 0, 0, true, '{"seeded_by":"0010_billing_ledger_cutover_state"}'::jsonb, 'migration_default'),
  ('production', 'control_plane_local_sql_writer', 'control_plane_local_sql_writer', null, null, 0, 0, true, '{"seeded_by":"0010_billing_ledger_cutover_state"}'::jsonb, 'migration_default')
on conflict (environment_scope) do nothing;
