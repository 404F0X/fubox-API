\set ON_ERROR_STOP on
\if :{?artifact_path}
\else
\set artifact_path ''
\endif
\if :{?smoke_run_id}
\else
\set smoke_run_id ''
\endif
\if :{?request_ids}
\else
\set request_ids ''
\endif
\if :{?request_hashes}
\else
\set request_hashes ''
\endif

with readback_parameters as (
  select
    nullif(:'artifact_path', '') as artifact_path,
    nullif(:'smoke_run_id', '') as smoke_run_id,
    array(
      select value::uuid
      from unnest(string_to_array(:'request_ids', ',')) as value
      where value <> ''
    ) as request_ids,
    array(
      select value
      from unnest(string_to_array(:'request_hashes', ',')) as value
      where value <> ''
    ) as request_hashes
),
request_scope as (
  select rl.*
  from request_logs rl
  cross join readback_parameters p
  where (
      cardinality(p.request_ids) > 0
      and rl.id = any(p.request_ids)
    )
    or (
      cardinality(p.request_hashes) > 0
      and rl.request_body_hash = any(p.request_hashes)
    )
),
provider_attempt_readback as (
  select
    count(pa.id) as provider_attempt_rows,
    count(pa.id) filter (
      where pa.metadata #>> '{rate_limit_reservation,db_execution,acquire,status}' = 'applied'
    ) as acquire_applied_count,
    count(pa.id) filter (
      where pa.metadata #>> '{rate_limit_reservation,db_execution,acquire,status}' = 'not_applied'
    ) as acquire_not_applied_count,
    count(pa.id) filter (
      where pa.metadata #>> '{rate_limit_reservation,db_execution,acquire,status}' = 'refused'
    ) as acquire_refused_count,
    count(pa.id) filter (
      where pa.metadata #>> '{rate_limit_reservation,db_execution,acquire,status}' = 'noop'
    ) as acquire_noop_count,
    count(pa.id) filter (
      where pa.metadata #>> '{rate_limit_reservation,db_execution,release,status}' = 'applied'
    ) as release_applied_count,
    count(pa.id) filter (
      where pa.metadata #>> '{rate_limit_reservation,db_execution,release,status}' = 'not_applied'
    ) as release_not_applied_count,
    count(pa.id) filter (
      where pa.metadata #>> '{rate_limit_reservation,db_execution,release,status}' = 'refused'
    ) as release_refused_count,
    count(pa.id) filter (
      where pa.metadata #>> '{rate_limit_reservation,db_execution,release,status}' = 'noop'
    ) as release_noop_count,
    count(pa.id) filter (
      where pa.fallback_reason is not null
         or pa.metadata #>> '{rate_limit_reservation,outcome}' = 'fallback'
    ) as fallback_count,
    count(distinct rs.id) filter (
      where rs.route_decision_snapshot ? 'rate_limit_reservation_rejection'
    ) as forced_limit_request_rows,
    count(pa.id) filter (
      where rs.route_decision_snapshot ? 'rate_limit_reservation_rejection'
    ) as forced_limit_provider_attempt_rows,
    bool_or(
      coalesce((pa.metadata #>> '{rate_limit_reservation,tpm_estimate,estimated}')::boolean, false)
    ) as any_estimated_tpm,
    bool_or(
      coalesce((pa.metadata #>> '{rate_limit_reservation,tpm_estimate,trusted_numeric_source_present}')::boolean, false)
    ) as any_trusted_numeric_tpm
  from request_scope rs
  left join provider_attempts pa
    on pa.tenant_id = rs.tenant_id
   and pa.request_id = rs.id
),
reservation_skip_readback as (
  select
    count(*) filter (
      where skip_event #>> '{rate_limit_reservation,db_execution,acquire,status}' = 'not_applied'
    ) as skip_not_applied_count,
    count(*) filter (
      where skip_event #>> '{rate_limit_reservation,db_execution,acquire,status}' = 'refused'
    ) as skip_refused_count,
    count(*) filter (
      where skip_event #>> '{rate_limit_reservation,db_execution,acquire,status}' = 'noop'
    ) as skip_noop_count
  from request_scope rs
  cross join lateral jsonb_array_elements(
    coalesce(
      rs.route_decision_snapshot #> '{rate_limit_reservation_rejection,skip_events}',
      '[]'::jsonb
    )
  ) as skip_event
),
provider_key_readback as (
  select
    count(*) as provider_key_rows_with_rate_limits,
    count(*) filter (where tpm_limit is not null) as rows_with_tpm_limit,
    count(*) filter (
      where jsonb_typeof(current_window_state #> '{tpm,used}') = 'number'
    ) as rows_with_current_tpm_counter,
    count(*) filter (
      where jsonb_typeof(current_window_state #> '{rpm,used}') = 'number'
    ) as rows_with_current_rpm_counter,
    count(*) filter (
      where jsonb_typeof(current_window_state #> '{concurrency,used}') = 'number'
    ) as rows_with_current_concurrency_counter,
    jsonb_build_object(
      'tokens_per_minute_rows', count(*) filter (where tpm_limit is not null),
      'requests_per_minute_rows', count(*) filter (where rpm_limit is not null),
      'concurrency_rows', count(*) filter (where concurrency_limit is not null)
    ) as reservation_capacity_projection
  from provider_keys
  where deleted_at is null
    and (rpm_limit is not null or tpm_limit is not null or concurrency_limit is not null)
)
select jsonb_build_object(
  'schema', 'gateway_tpm_rate_limit_db_acquire_readback_v1',
  'artifact_path', p.artifact_path,
  'smoke_run_id', p.smoke_run_id,
  'source_table', 'provider_keys',
  'request_source_table', 'request_logs',
  'provider_attempt_source_table', 'provider_attempts',
  'bounded_readback', true,
  'same_smoke_run_request_correlation', (
    p.smoke_run_id is not null
    and (cardinality(p.request_ids) > 0 or cardinality(p.request_hashes) > 0)
  ),
  'raw_material_present', false,
  'secret_safe_raw_omission', true,
  'request_scope', jsonb_build_object(
    'request_ids_supplied', cardinality(p.request_ids),
    'request_hashes_supplied', cardinality(p.request_hashes),
    'request_log_rows', (select count(*) from request_scope)
  ),
  'reservation_event_counts', jsonb_build_object(
    'acquire_applied_count', coalesce(pa.acquire_applied_count, 0),
    'acquire_not_applied_count', coalesce(pa.acquire_not_applied_count, 0),
    'acquire_refused_count', coalesce(pa.acquire_refused_count, 0),
    'acquire_noop_count', coalesce(pa.acquire_noop_count, 0),
    'release_applied_count', coalesce(pa.release_applied_count, 0),
    'release_not_applied_count', coalesce(pa.release_not_applied_count, 0),
    'release_refused_count', coalesce(pa.release_refused_count, 0),
    'release_noop_count', coalesce(pa.release_noop_count, 0),
    'skip_not_applied_count', coalesce(skip.skip_not_applied_count, 0),
    'skip_refused_count', coalesce(skip.skip_refused_count, 0),
    'skip_noop_count', coalesce(skip.skip_noop_count, 0),
    'not_applied_count', coalesce(pa.acquire_not_applied_count, 0) + coalesce(skip.skip_not_applied_count, 0),
    'fallback_count', coalesce(pa.fallback_count, 0),
    'provider_attempt_rows', coalesce(pa.provider_attempt_rows, 0),
    'forced_limit_request_rows', coalesce(pa.forced_limit_request_rows, 0),
    'forced_limit_provider_attempt_rows', coalesce(pa.forced_limit_provider_attempt_rows, 0)
  ),
  'tpm_estimate_readback', jsonb_build_object(
    'estimated_seen', coalesce(pa.any_estimated_tpm, false),
    'trusted_numeric_source_seen', coalesce(pa.any_trusted_numeric_tpm, false),
    'missing_tokenizer_fallback_expected_estimated', true
  ),
  'request_trace_usage_handoff', jsonb_build_object(
    'schema', 'gateway_rate_limit_request_trace_usage_handoff_v1',
    'status', case
      when (select count(*) from request_scope) >= 3
       and coalesce(pa.forced_limit_provider_attempt_rows, 0) = 0
       and coalesce(pa.any_estimated_tpm, false) = true
      then 'ready'
      else 'blocked'
    end,
    'smoke_run_id', p.smoke_run_id,
    'request_trace_lookup_keys', jsonb_build_object(
      'request_ids', to_jsonb(p.request_ids),
      'request_hashes', to_jsonb(p.request_hashes),
      'request_id_count', cardinality(p.request_ids),
      'request_hash_count', cardinality(p.request_hashes),
      'lookup_scope', 'request_logs_and_provider_attempts',
      'material_in_output', false
    ),
    'reservation_events', jsonb_build_object(
      'acquire_applied_count', coalesce(pa.acquire_applied_count, 0),
      'release_applied_count', coalesce(pa.release_applied_count, 0),
      'not_applied_count', coalesce(pa.acquire_not_applied_count, 0) + coalesce(skip.skip_not_applied_count, 0),
      'fallback_count', coalesce(pa.fallback_count, 0),
      'provider_attempt_rows', coalesce(pa.provider_attempt_rows, 0),
      'forced_limit_provider_attempt_rows', coalesce(pa.forced_limit_provider_attempt_rows, 0)
    ),
    'estimated_tpm_fallback', jsonb_build_object(
      'estimated', coalesce(pa.any_estimated_tpm, false),
      'trusted_numeric_source_present', coalesce(pa.any_trusted_numeric_tpm, false),
      'evidence_field', 'rate_limit_reservation.tpm_estimate.estimated',
      'trusted_numeric_field', 'rate_limit_reservation.tpm_estimate.trusted_numeric_source_present',
      'source', 'conservative_missing_tokenizer_fallback',
      'paid_billing_settled', false
    ),
    'admin_readback_expectations', jsonb_build_object(
      'required_views', jsonb_build_array('request_detail', 'trace_detail', 'provider_attempt_detail'),
      'expected_fields', jsonb_build_array(
        'request_id',
        'request_hash',
        'route_decision_snapshot.rate_limit_reservation_rejection',
        'provider_attempts.metadata.rate_limit_reservation',
        'provider_attempts.fallback_reason'
      ),
      'forced_limit_expected_provider_attempt_rows', 0,
      'admin_ui_beta_closure_claimed', false
    ),
    'usage_cost_expectations', jsonb_build_object(
      'usage_basis', 'rate_limit_reservation_metadata_and_estimated_tpm',
      'cost_basis', 'not_paid_billing_settlement',
      'paid_billing_settled', false,
      'estimated_tpm_only', true,
      'acceptable_for_todo14_usage_trace', true
    ),
    'secret_safe_omission', jsonb_build_object(
      'auth_material_in_output', false,
      'provider_secret_in_output', false,
      'body_material_in_output', false,
      'header_material_in_output', false,
      'endpoint_material_in_output', false,
      'window_state_material_in_output', false,
      'raw_material_present', false
    )
  ),
  'provider_key_rows_with_rate_limits', pk.provider_key_rows_with_rate_limits,
  'rows_with_tpm_limit', pk.rows_with_tpm_limit,
  'rows_with_current_tpm_counter', pk.rows_with_current_tpm_counter,
  'rows_with_current_rpm_counter', pk.rows_with_current_rpm_counter,
  'rows_with_current_concurrency_counter', pk.rows_with_current_concurrency_counter,
  'reservation_capacity_projection', pk.reservation_capacity_projection
) as e8_rate_limit_db_acquire_readback
from readback_parameters p
cross join provider_key_readback pk
cross join provider_attempt_readback pa
cross join reservation_skip_readback skip;
