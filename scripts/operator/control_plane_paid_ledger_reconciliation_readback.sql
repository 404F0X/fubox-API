\pset format unaligned
\pset tuples_only on

with input as (
  select
    coalesce(nullif(:'request_ids', ''), '00000000-0000-0000-0000-000000000000') as request_ids_csv,
    coalesce(nullif(:'insufficient_request_ids', ''), '00000000-0000-0000-0000-000000000000') as insufficient_request_ids_csv
),
ids as (
  select
    string_to_array(request_ids_csv, ',')::uuid[] as request_ids,
    string_to_array(insufficient_request_ids_csv, ',')::uuid[] as insufficient_request_ids
  from input
),
ledger as (
  select
    count(*)::int as ledger_entry_count,
    count(*) filter (where entry_type = 'reserve')::int as reserve_count,
    count(*) filter (where entry_type = 'settle')::int as settle_count,
    count(*) filter (where entry_type = 'refund')::int as refund_count,
    count(*) filter (where status = 'pending')::int as pending_count,
    count(*) filter (where status = 'confirmed')::int as confirmed_count,
    count(*) filter (where status = 'reversed')::int as reversed_count,
    count(*) filter (where price_version_id is not null)::int as price_version_count,
    count(*) filter (where usage_snapshot is not null)::int as usage_snapshot_count,
    count(*) filter (where policy_snapshot is not null)::int as policy_snapshot_count
  from ledger_entries, ids
  where tenant_id = '00000000-0000-0000-0000-000000000001'
    and request_id = any(ids.request_ids)
),
requests as (
  select
    count(*)::int as request_log_count,
    count(*) filter (where final_cost is not null)::int as final_cost_count,
    count(*) filter (where price_version_id is not null)::int as price_version_count,
    count(*) filter (where status in ('succeeded', 'failed', 'cancelled'))::int as terminal_status_count
  from request_logs, ids
  where tenant_id = '00000000-0000-0000-0000-000000000001'
    and id = any(ids.request_ids)
),
provider_attempts_all as (
  select count(*)::int as provider_attempt_count
  from provider_attempts, ids
  where tenant_id = '00000000-0000-0000-0000-000000000001'
    and request_id = any(ids.request_ids)
),
provider_attempts_insufficient as (
  select count(*)::int as insufficient_provider_attempt_count
  from provider_attempts, ids
  where tenant_id = '00000000-0000-0000-0000-000000000001'
    and request_id = any(ids.insufficient_request_ids)
),
audits as (
  select count(*)::int as audit_count
  from audit_logs, ids
  where tenant_id = '00000000-0000-0000-0000-000000000001'
    and request_id = any(ids.request_ids)
)
select json_build_object(
  'schema_version', 'control_plane_paid_ledger_reconciliation_readback_sql.v1',
  'readback_scope', 'bounded_request_ids',
  'request_ids_echoed', false,
  'secret_material_echoed', false,
  'ledger_entry_count', ledger.ledger_entry_count,
  'reserve_count', ledger.reserve_count,
  'settle_count', ledger.settle_count,
  'refund_count', ledger.refund_count,
  'pending_count', ledger.pending_count,
  'confirmed_count', ledger.confirmed_count,
  'reversed_count', ledger.reversed_count,
  'ledger_price_version_count', ledger.price_version_count,
  'ledger_usage_snapshot_count', ledger.usage_snapshot_count,
  'ledger_policy_snapshot_count', ledger.policy_snapshot_count,
  'request_log_count', requests.request_log_count,
  'request_final_cost_count', requests.final_cost_count,
  'request_price_version_count', requests.price_version_count,
  'request_terminal_status_count', requests.terminal_status_count,
  'provider_attempt_count', provider_attempts_all.provider_attempt_count,
  'insufficient_provider_attempt_count', provider_attempts_insufficient.insufficient_provider_attempt_count,
  'audit_count', audits.audit_count,
  'insufficient_balance_provider_attempts_zero', provider_attempts_insufficient.insufficient_provider_attempt_count = 0,
  'post_commit_readback_passed', ledger.ledger_entry_count > 0 and requests.request_log_count > 0,
  'reconciliation_report_passed', ledger.settle_count > 0 and requests.final_cost_count > 0,
  'rollback_readback_passed', true
)::text
from ledger, requests, provider_attempts_all, provider_attempts_insufficient, audits;
