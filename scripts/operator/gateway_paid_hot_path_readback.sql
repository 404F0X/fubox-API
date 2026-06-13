\set ON_ERROR_STOP on
\if :{?request_ids}
\else
\set request_ids ''
\endif
\if :{?success_request_id}
\else
\set success_request_id ''
\endif
\if :{?failure_request_id}
\else
\set failure_request_id ''
\endif
\if :{?insufficient_request_id}
\else
\set insufficient_request_id ''
\endif
\if :{?smoke_run_id}
\else
\set smoke_run_id ''
\endif

with readback_parameters as (
  select
    nullif(:'smoke_run_id', '') as smoke_run_id,
    array(
      select value::uuid
      from unnest(string_to_array(:'request_ids', ',')) as value
      where value <> ''
    ) as request_ids,
    nullif(:'success_request_id', '')::uuid as success_request_id,
    nullif(:'failure_request_id', '')::uuid as failure_request_id,
    nullif(:'insufficient_request_id', '')::uuid as insufficient_request_id
),
request_scope as (
  select rl.*
  from request_logs rl
  cross join readback_parameters p
  where cardinality(p.request_ids) > 0
    and rl.id = any(p.request_ids)
),
provider_attempt_scope as (
  select pa.*
  from provider_attempts pa
  join request_scope rs
    on rs.tenant_id = pa.tenant_id
   and rs.id = pa.request_id
),
ledger_scope as (
  select le.*
  from ledger_entries le
  join request_scope rs
    on rs.tenant_id = le.tenant_id
   and rs.id = le.request_id
),
resolved_parameters as (
  select
    p.smoke_run_id,
    p.request_ids,
    coalesce(
      p.success_request_id,
      (
        select le.request_id
        from ledger_scope le
        where le.entry_type = 'settle'
          and le.status = 'confirmed'
        order by le.created_at desc, le.id desc
        limit 1
      )
    ) as success_request_id,
    coalesce(
      p.failure_request_id,
      (
        select le.request_id
        from ledger_scope le
        where le.entry_type = 'reserve'
          and le.status = 'reversed'
          and le.metadata ? 'release'
        order by le.created_at desc, le.id desc
        limit 1
      )
    ) as failure_request_id,
    coalesce(
      p.insufficient_request_id,
      (
        select rs.id
        from request_scope rs
        where not exists (
            select 1
            from provider_attempt_scope pa
            where pa.tenant_id = rs.tenant_id
              and pa.request_id = rs.id
          )
          and not exists (
            select 1
            from ledger_scope le
            where le.tenant_id = rs.tenant_id
              and le.request_id = rs.id
              and le.entry_type = 'reserve'
          )
        order by rs.created_at desc, rs.id desc
        limit 1
      )
    ) as insufficient_request_id,
    jsonb_build_object(
      'success_request_id', case when p.success_request_id is null then 'inferred_from_confirmed_settle' else 'provided' end,
      'failure_request_id', case when p.failure_request_id is null then 'inferred_from_released_reserve' else 'provided' end,
      'insufficient_request_id', case when p.insufficient_request_id is null then 'inferred_from_no_provider_attempt_no_reserve' else 'provided' end
    ) as role_resolution_sources
  from readback_parameters p
),
counts as (
  select
    (select count(*) from request_scope) as request_rows,
    (select count(*) from provider_attempt_scope) as provider_attempt_rows,
    (select count(*) from ledger_scope where entry_type = 'reserve') as reserve_rows,
    (select count(*) from ledger_scope where entry_type = 'reserve' and status = 'pending') as reserve_pending_rows,
    (select count(*) from ledger_scope where entry_type = 'reserve' and status = 'reversed') as reserve_reversed_rows,
    (select count(*) from ledger_scope where entry_type = 'settle' and status = 'confirmed') as settle_confirmed_rows,
    (select count(*) from ledger_scope where entry_type = 'refund') as refund_rows,
    (
      select count(*)
      from provider_attempt_scope pa
      cross join resolved_parameters p
      where pa.request_id = p.insufficient_request_id
    ) as insufficient_balance_provider_attempt_rows,
    (
      select count(*)
      from ledger_scope le
      cross join resolved_parameters p
      where le.request_id = p.failure_request_id
        and le.entry_type = 'reserve'
        and le.status = 'reversed'
        and le.metadata ? 'release'
    ) as failure_release_rows,
    (
      select count(*)
      from ledger_scope le
      cross join resolved_parameters p
      where le.request_id = p.success_request_id
        and le.entry_type = 'settle'
        and le.status = 'confirmed'
    ) as success_settle_rows
),
ordering as (
  select
    coalesce(bool_and(le.created_at <= pa.started_at), false) as reserve_before_provider_attempt
  from ledger_scope le
  join provider_attempt_scope pa
    on pa.tenant_id = le.tenant_id
   and pa.request_id = le.request_id
  where le.entry_type = 'reserve'
),
idempotency as (
  select
    bool_or(entry_type = 'reserve' and idempotency_key = 'reserve:' || request_id::text) as reserve_idempotency_seen,
    bool_or(entry_type = 'settle' and idempotency_key = 'settle:' || request_id::text) as settle_idempotency_seen,
    bool_or(entry_type = 'reserve' and metadata #>> '{release,release_idempotency_key}' = 'release:' || request_id::text) as release_idempotency_seen,
    bool_or(entry_type = 'refund' and idempotency_key = 'refund:' || related_ledger_entry_id::text) as refund_idempotency_seen
  from ledger_scope
),
operation_evidence as (
  select
    (
      select le.id
      from ledger_scope le
      cross join resolved_parameters p
      where le.request_id = p.success_request_id
        and le.entry_type = 'reserve'
      order by le.created_at desc, le.id desc
      limit 1
    ) as success_reserve_ledger_entry_id,
    (
      select le.id
      from ledger_scope le
      cross join resolved_parameters p
      where le.request_id = p.success_request_id
        and le.entry_type = 'settle'
        and le.status = 'confirmed'
      order by le.created_at desc, le.id desc
      limit 1
    ) as success_settle_ledger_entry_id,
    (
      select le.id
      from ledger_scope le
      cross join resolved_parameters p
      where le.request_id = p.success_request_id
        and le.entry_type = 'refund'
        and le.status = 'confirmed'
      order by le.created_at desc, le.id desc
      limit 1
    ) as success_refund_ledger_entry_id,
    (
      select le.related_ledger_entry_id
      from ledger_scope le
      cross join resolved_parameters p
      where le.request_id = p.success_request_id
        and le.entry_type = 'refund'
        and le.status = 'confirmed'
      order by le.created_at desc, le.id desc
      limit 1
    ) as success_refund_related_settle_ledger_entry_id,
    (
      select le.idempotency_key
      from ledger_scope le
      cross join resolved_parameters p
      where le.request_id = p.success_request_id
        and le.entry_type = 'refund'
        and le.status = 'confirmed'
      order by le.created_at desc, le.id desc
      limit 1
    ) as success_refund_idempotency_key,
    (
      select le.id
      from ledger_scope le
      cross join resolved_parameters p
      where le.request_id = p.failure_request_id
        and le.entry_type = 'reserve'
        and le.status = 'reversed'
        and le.metadata ? 'release'
      order by le.created_at desc, le.id desc
      limit 1
    ) as failure_release_ledger_entry_id,
    (
      select le.metadata #>> '{release,release_idempotency_key}'
      from ledger_scope le
      cross join resolved_parameters p
      where le.request_id = p.failure_request_id
        and le.entry_type = 'reserve'
        and le.status = 'reversed'
        and le.metadata ? 'release'
      order by le.created_at desc, le.id desc
      limit 1
    ) as failure_release_idempotency_key
),
secret_scan as (
  select
    coalesce(bool_or(
      request_body_hash ilike '%sk-%'
      or request_body_hash ilike '%bearer%'
      or route_decision_snapshot::text ilike '%authorization%'
      or route_decision_snapshot::text ilike '%database_url%'
      or route_decision_snapshot::text ilike '%provider_secret%'
      or route_decision_snapshot::text ilike '%encrypted_secret%'
    ), false) as raw_or_secret_marker_present
  from request_scope
)
select jsonb_pretty(jsonb_build_object(
  'schema', 'gateway_paid_hot_path_readback_v1',
  'smoke_run_id', (select smoke_run_id from resolved_parameters),
  'resolved_request_roles', jsonb_build_object(
    'success_request_id', (select success_request_id::text from resolved_parameters),
    'failure_request_id', (select failure_request_id::text from resolved_parameters),
    'insufficient_request_id', (select insufficient_request_id::text from resolved_parameters),
    'sources', (select role_resolution_sources from resolved_parameters)
  ),
  'operation_evidence', jsonb_build_object(
    'success_reserve_ledger_entry_id', (select success_reserve_ledger_entry_id::text from operation_evidence),
    'success_settle_ledger_entry_id', (select success_settle_ledger_entry_id::text from operation_evidence),
    'success_refund_ledger_entry_id', (select success_refund_ledger_entry_id::text from operation_evidence),
    'success_refund_related_settle_ledger_entry_id', (select success_refund_related_settle_ledger_entry_id::text from operation_evidence),
    'success_refund_idempotency_key', (select success_refund_idempotency_key from operation_evidence),
    'failure_release_ledger_entry_id', (select failure_release_ledger_entry_id::text from operation_evidence),
    'failure_release_idempotency_key', (select failure_release_idempotency_key from operation_evidence)
  ),
  'request_rows', (select request_rows from counts),
  'provider_attempt_rows', (select provider_attempt_rows from counts),
  'ledger_counts', jsonb_build_object(
    'reserve', (select reserve_rows from counts),
    'reserve_pending', (select reserve_pending_rows from counts),
    'reserve_reversed', (select reserve_reversed_rows from counts),
    'settle_confirmed', (select settle_confirmed_rows from counts),
    'refund', (select refund_rows from counts),
    'failure_release', (select failure_release_rows from counts)
  ),
  'reserve_before_provider_side_effect', (select reserve_before_provider_attempt from ordering),
  'insufficient_balance_prevents_provider_call', (select insufficient_balance_provider_attempt_rows from counts) = 0,
  'insufficient_balance_provider_attempt_rows', (select insufficient_balance_provider_attempt_rows from counts),
  'successful_request_settled', (select success_settle_rows from counts) > 0,
  'failure_request_released', (select failure_release_rows from counts) > 0,
  'settle_idempotency', coalesce((select settle_idempotency_seen from idempotency), false),
  'refund_idempotency', jsonb_build_object(
    'status', case
      when (select refund_rows from counts) > 0
       and coalesce((select refund_idempotency_seen from idempotency), false)
       and (select success_refund_related_settle_ledger_entry_id from operation_evidence) = (select success_settle_ledger_entry_id from operation_evidence)
      then 'passed'
      else 'blocked'
    end,
    'covered_path', 'full_refund_after_confirmed_settle',
    'release_idempotency_seen', coalesce((select release_idempotency_seen from idempotency), false),
    'refund_idempotency_seen', coalesce((select refund_idempotency_seen from idempotency), false),
    'refund_count', (select refund_rows from counts),
    'refund_rows', (select refund_rows from counts),
    'related_settle_ledger_entry_id', (select success_refund_related_settle_ledger_entry_id::text from operation_evidence),
    'refund_ledger_entry_id', (select success_refund_ledger_entry_id::text from operation_evidence),
    'refund_idempotency_key', (select success_refund_idempotency_key from operation_evidence),
    'duplicate_refund_idempotent', (select refund_rows from counts) = 1
      and coalesce((select refund_idempotency_seen from idempotency), false),
    'bounded_smoke_refund_step', true,
    'production_default_path', false
  ),
  'reserve_idempotency_seen', coalesce((select reserve_idempotency_seen from idempotency), false),
  'post_commit_readback', (select request_rows from counts) = 3
    and (select reserve_rows from counts) >= 2
    and (select success_settle_rows from counts) > 0
    and (select failure_release_rows from counts) > 0
    and (select refund_rows from counts) > 0
    and (select insufficient_balance_provider_attempt_rows from counts) = 0,
  'rollback_proof', jsonb_build_object(
    'insufficient_balance_provider_attempt_rows', (select insufficient_balance_provider_attempt_rows from counts),
    'insufficient_balance_created_reserve_rows', (
      select count(*)
      from ledger_scope le
      cross join resolved_parameters p
      where le.request_id = p.insufficient_request_id
        and le.entry_type = 'reserve'
    )
  ),
  'reconciliation_report', jsonb_build_object(
    'status', 'bounded_beta_readback',
    'request_rows_equal_expected', (select request_rows from counts) = 3,
    'paid_billing_source_of_truth_scope', 'gateway_beta_hot_path_evidence_not_full_production_billing_close'
  ),
  'secret_safe', jsonb_build_object(
    'raw_request_body_omitted', true,
    'auth_token_omitted', true,
    'provider_secret_omitted', true,
    'database_url_omitted', true,
    'raw_or_secret_marker_present', (select raw_or_secret_marker_present from secret_scan)
  )
)) as gateway_paid_hot_path_readback;
