param(
  [string]$OutputPath = ".tmp\credit-wallet\recharge_voucher_runtime_db_plan.json",
  [string]$RuntimeOutputPath = ".tmp\credit-wallet\recharge_voucher_runtime.json",
  [string]$RuntimeBlockedOutputPath = ".tmp\credit-wallet\recharge_voucher_runtime_s6_blocked.json",
  [string]$SeedTenantId = "00000000-0000-0000-0000-000000000001",
  [string]$SeedWalletId = "00000000-0000-0000-0000-0000000032a5",
  [switch]$RunDbIntegration,
  [switch]$RunInternalRuntime,
  [switch]$WriteRuntimeBlockedArtifact,
  [switch]$Overwrite,
  [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Resolve-RepoBoundedPath {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string[]]$AllowedPrefixes
  )

  $candidate = if ([System.IO.Path]::IsPathRooted($Path)) {
    [System.IO.Path]::GetFullPath($Path)
  } else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
  }
  $repoPrefix = $repoRoot.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
  if (-not $candidate.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "path_must_stay_inside_repo"
  }
  $relative = $candidate.Substring($repoPrefix.Length).Replace("\", "/")
  $allowed = $false
  foreach ($prefix in $AllowedPrefixes) {
    if ($relative.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      $allowed = $true
      break
    }
  }
  if (-not $allowed) { throw "path_prefix_not_allowed" }
  return [ordered]@{ full = $candidate; relative = $relative }
}

function Test-SecretSafeText {
  param([AllowNull()][string]$Text)

  if ([string]::IsNullOrEmpty($Text)) { return $true }
  foreach ($pattern in @(
      '(?i)authorization\s*[:=]',
      '(?i)cookie\s*[:=]',
      '(?i)bearer\s+[A-Za-z0-9._~+/\-]+=*',
      '(?i)provider[_-]?key\s*[:=]',
      '(?i)virtual[_-]?key\s*[:=]',
      '(?i)database[_-]?url\s*[:=]',
      '(?i)postgres(?:ql)?://[^"\s]+',
      '(?i)password\s*[:=]',
      'sk-[A-Za-z0-9]{8,}'
    )) {
    if ($Text -match $pattern) { return $false }
  }
  return $true
}

function Write-Artifact {
  param(
    [Parameter(Mandatory = $true)][object]$Artifact,
    [Parameter(Mandatory = $true)][hashtable]$Output
  )

  $json = $Artifact | ConvertTo-Json -Depth 16
  if (-not (Test-SecretSafeText $json)) {
    throw "artifact_secret_safety_failed"
  }
  $parent = Split-Path -Parent $Output.full
  if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  Set-Content -LiteralPath $Output.full -Encoding UTF8 -Value $json
}

function Select-DefaultBlockedOutput {
  param(
    [Parameter(Mandatory = $true)][hashtable]$Output,
    [bool]$AllowOverwrite
  )

  if ($AllowOverwrite -or -not (Test-Path -LiteralPath $Output.full)) {
    return [ordered]@{
      output = $Output
      preserved_existing_artifact = $false
      preserved_artifact_path = $null
    }
  }

  $parent = Split-Path -Parent $Output.full
  $stem = [System.IO.Path]::GetFileNameWithoutExtension($Output.full)
  $alternate = Join-Path $parent "$stem.default_blocked.json"
  $repoPrefix = $repoRoot.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
  $relative = ([System.IO.Path]::GetFullPath($alternate)).Substring($repoPrefix.Length).Replace("\", "/")
  return [ordered]@{
    output = [ordered]@{ full = $alternate; relative = $relative }
    preserved_existing_artifact = $true
    preserved_artifact_path = $Output.relative
  }
}

function New-RechargeVoucherArtifact {
  param(
    [string]$Status,
    [string[]]$Blockers,
    [bool]$DbIntegrationRan,
    [object]$DbPlan,
    [string[]]$MissingEnv,
    [bool]$PreservedExistingArtifact = $false,
    [AllowNull()][string]$PreservedArtifactPath = $null
  )

  return [ordered]@{
    schema = "recharge_voucher_runtime_db_plan.v1"
    overall_status = $Status
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    runtime_implemented = $false
    contract_only = $true
    route_invoked = $false
    internal_sqlx_function_invoked = $false
    db_integration_ran = $DbIntegrationRan
    db_plan = $DbPlan
    required_env = @(
      "RECHARGE_VOUCHER_DB_OPT_IN=1",
      "CONTROL_PLANE_DATABASE_URL or DATABASE_URL",
      "psql available on PATH",
      "db/migrations/0012_recharge_voucher_boundary.sql applied"
    )
    missing_env = @($MissingEnv)
    default_blocked_artifact_preserved_existing = $PreservedExistingArtifact
    preserved_db_attempt_artifact_path = $PreservedArtifactPath
    overwrite_required_to_replace_existing_artifact = $PreservedExistingArtifact
    source_files = @(
      "apps/control-plane/src/admin.rs",
      "db/migrations/0012_recharge_voucher_boundary.sql"
    )
    required_readback = [ordered]@{
      voucher_issuance = "pending_runtime"
      voucher_redemption = "pending_runtime"
      voucher_redeem_attempts = "pending_runtime"
      idempotency_replay = "pending_runtime"
      idempotency_conflict_refusal = "pending_runtime"
      credit_grant_or_ledger_effect = "pending_runtime"
      audit_link = "pending_runtime"
    }
    secret_safe = $true
    raw_secret_markers_present = $false
    artifact_secret_policy = [ordered]@{
      raw_dsn_echoed = $false
      raw_token_echoed = $false
      voucher_code_echoed = $false
      idempotency_material_echoed = $false
      provider_payload_echoed = $false
      provider_or_virtual_key_echoed = $false
    }
    paid_gate_changed = $false
    blockers = @($Blockers)
    next_command = "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_recharge_voucher_runtime.ps1 -RunDbIntegration -OutputPath .tmp/credit-wallet/recharge_voucher_runtime_db_plan.json"
    overwrite_note = "Default blocked runs preserve an existing DB-attempt artifact and write a sibling .default_blocked.json artifact unless -Overwrite is supplied."
    runtime_acceptance_note = "This artifact is an opt-in DB plan/readback only. It must not satisfy recharge_voucher_runtime_verified or replace .tmp/credit-wallet/recharge_voucher_runtime.json."
  }
}

function New-RechargeVoucherDbPlanSql {
  param(
    [Parameter(Mandatory = $true)][string]$TenantId,
    [Parameter(Mandatory = $true)][string]$WalletId,
    [Parameter(Mandatory = $true)][string]$RunId
  )

  $codeHash = "e11-code-hash-$RunId"
  $codePrefix = "e11$($RunId.Substring(0, 8))"
  $issueIdempotency = "e11-issue-idem-$RunId"
  $redeemIdempotency = "e11-redeem-idem-$RunId"
  $conflictIdempotency = "e11-redeem-conflict-$RunId"
  $ledgerIdempotency = "e11-voucher-ledger-$RunId"

  return @"
begin;

insert into tenants (id, name, slug, status, metadata)
values ('$TenantId'::uuid, 'E11 recharge voucher verifier tenant', 'e11-recharge-voucher-verifier', 'active', '{}'::jsonb)
on conflict (id) do update set status = 'active', deleted_at = null, updated_at = now();

insert into wallets (id, tenant_id, project_id, name, currency, status, balance_floor, metadata)
values ('$WalletId'::uuid, '$TenantId'::uuid, null, 'E11 recharge voucher verifier wallet', 'USD', 'active', 0, '{}'::jsonb)
on conflict (id) do update
set currency = excluded.currency,
    status = excluded.status,
    deleted_at = null,
    updated_at = now();

create temp table e11_recharge_voucher_ids (
  voucher_id uuid,
  redemption_id uuid,
  attempt_id uuid,
  refusal_attempt_id uuid,
  credit_grant_id uuid,
  ledger_entry_id uuid,
  issue_audit_id uuid,
  redeem_audit_id uuid
) on commit drop;

with issue_audit as (
  insert into audit_logs (tenant_id, actor_user_id, request_id, action, resource_type, resource_id, resource_tenant_id, before_snapshot, after_snapshot, metadata)
  values ('$TenantId'::uuid, null, null, 'voucher.issue', 'voucher_issuance', null, '$TenantId'::uuid, null, null, jsonb_build_object('operation', 'voucher_issue', 'secret_safe', true))
  returning id
),
issue_row as (
  insert into voucher_issuances (
    tenant_id, project_id, wallet_id, campaign_id, currency, amount,
    code_hash, code_lookup_prefix, code_redacted, status, max_redemptions,
    redemption_count, idempotency_key_hash, audit_id, request_summary, metadata
  )
  select
    '$TenantId'::uuid, null, '$WalletId'::uuid, null, 'USD', 25.00000000::numeric,
    '$codeHash', '$codePrefix', 'redacted:last4:plan', 'issued', 1,
    0, '$issueIdempotency', issue_audit.id,
    jsonb_build_object('voucher_code', 'omitted', 'idempotency_key', 'omitted'),
    jsonb_build_object('code_hash_present', true, 'code_lookup_prefix_present', true, 'secret_safe', true)
  from issue_audit
  returning id, audit_id
)
insert into e11_recharge_voucher_ids (voucher_id, issue_audit_id)
select id, audit_id from issue_row;

with redeem_attempt as (
  insert into voucher_redeem_attempts (
    tenant_id, project_id, wallet_id, code_lookup_prefix, outcome, refusal_code,
    actor_fingerprint_hash, attempt_count, request_summary, metadata
  )
  values (
    '$TenantId'::uuid, null, '$WalletId'::uuid, '$codePrefix', 'accepted', null,
    'actor-hash-$RunId', 1,
    jsonb_build_object('voucher_code', 'omitted'),
    jsonb_build_object('secret_safe', true)
  )
  returning id
),
credit_effect as (
  insert into credit_grants (tenant_id, wallet_id, amount, remaining_amount, currency, source, valid_from, status, metadata)
  values ('$TenantId'::uuid, '$WalletId'::uuid, 25.00000000::numeric, 25.00000000::numeric, 'USD', 'voucher_redeem', now(), 'active', jsonb_build_object('operation', 'voucher_redeem', 'secret_safe', true))
  returning id
),
ledger_effect as (
  insert into ledger_entries (tenant_id, project_id, wallet_id, request_id, virtual_key_id, trace_id, related_ledger_entry_id, entry_type, amount, currency, status, idempotency_key, metadata)
  values ('$TenantId'::uuid, null, '$WalletId'::uuid, null, null, null, null, 'credit_grant', 25.00000000::numeric, 'USD', 'confirmed', '$ledgerIdempotency', jsonb_build_object('operation', 'voucher_redeem', 'secret_safe', true))
  returning id
),
redeem_audit as (
  insert into audit_logs (tenant_id, actor_user_id, request_id, action, resource_type, resource_id, resource_tenant_id, before_snapshot, after_snapshot, metadata)
  values ('$TenantId'::uuid, null, null, 'voucher.redeem', 'voucher_redemption', null, '$TenantId'::uuid, null, null, jsonb_build_object('operation', 'voucher_redeem', 'secret_safe', true))
  returning id
),
redemption as (
  insert into voucher_redemptions (
    tenant_id, project_id, wallet_id, voucher_id, redeemer_user_id, currency, amount,
    status, idempotency_key_hash, credit_grant_id, ledger_entry_id, audit_id, refusal_code,
    request_summary, metadata
  )
  select
    '$TenantId'::uuid, null, '$WalletId'::uuid, ids.voucher_id, null, 'USD', 25.00000000::numeric,
    'redeemed', '$redeemIdempotency', credit_effect.id, ledger_effect.id, redeem_audit.id, null,
    jsonb_build_object('voucher_code', 'omitted', 'idempotency_key', 'omitted'),
    jsonb_build_object('secret_safe', true)
  from e11_recharge_voucher_ids ids, credit_effect, ledger_effect, redeem_audit
  returning id, credit_grant_id, ledger_entry_id, audit_id
),
updated_issue as (
  update voucher_issuances
  set redemption_count = redemption_count + 1,
      status = 'redeemed',
      updated_at = now()
  where tenant_id = '$TenantId'::uuid
    and id = (select voucher_id from e11_recharge_voucher_ids limit 1)
  returning id
)
update e11_recharge_voucher_ids
set redemption_id = redemption.id,
    attempt_id = redeem_attempt.id,
    credit_grant_id = redemption.credit_grant_id,
    ledger_entry_id = redemption.ledger_entry_id,
    redeem_audit_id = redemption.audit_id
from redemption, redeem_attempt;

create temp table e11_recharge_voucher_counts_before_refusal as
select
  (select count(*) from voucher_redemptions where tenant_id = '$TenantId'::uuid) as redemptions,
  (select count(*) from credit_grants where tenant_id = '$TenantId'::uuid and metadata->>'operation' = 'voucher_redeem') as credit_grants,
  (select count(*) from ledger_entries where tenant_id = '$TenantId'::uuid and metadata->>'operation' = 'voucher_redeem') as ledger_entries;

with refusal_attempt as (
  insert into voucher_redeem_attempts (
    tenant_id, project_id, wallet_id, code_lookup_prefix, outcome, refusal_code,
    actor_fingerprint_hash, attempt_count, request_summary, metadata
  )
  values (
    '$TenantId'::uuid, null, '$WalletId'::uuid, '$codePrefix', 'refused', 'idempotency_conflict',
    'actor-hash-conflict-$RunId', 1,
    jsonb_build_object('voucher_code', 'omitted'),
    jsonb_build_object('secret_safe', true, 'no_credit_or_ledger_write', true)
  )
  returning id
)
update e11_recharge_voucher_ids
set refusal_attempt_id = refusal_attempt.id
from refusal_attempt;

select jsonb_build_object(
  'schema', 'recharge_voucher_db_plan_readback.v1',
  'passed', true,
  'voucher_issuance_readback_passed', exists (
    select 1 from voucher_issuances v, e11_recharge_voucher_ids ids
    where v.tenant_id = '$TenantId'::uuid
      and v.id = ids.voucher_id
      and v.code_hash = '$codeHash'
      and v.code_lookup_prefix = '$codePrefix'
      and v.code_redacted like 'redacted:%'
      and v.idempotency_key_hash = '$issueIdempotency'
      and v.audit_id = ids.issue_audit_id
      and v.status = 'redeemed'
  ),
  'issue_idempotency_replay_lookup_passed', exists (
    select 1 from voucher_issuances
    where tenant_id = '$TenantId'::uuid
      and idempotency_key_hash = '$issueIdempotency'
  ),
  'redeem_readback_passed', exists (
    select 1 from voucher_redemptions r, e11_recharge_voucher_ids ids
    where r.tenant_id = '$TenantId'::uuid
      and r.id = ids.redemption_id
      and r.voucher_id = ids.voucher_id
      and r.idempotency_key_hash = '$redeemIdempotency'
      and r.credit_grant_id = ids.credit_grant_id
      and r.ledger_entry_id = ids.ledger_entry_id
      and r.audit_id = ids.redeem_audit_id
      and r.status = 'redeemed'
  ),
  'redeem_idempotency_replay_lookup_passed', exists (
    select 1 from voucher_redemptions
    where tenant_id = '$TenantId'::uuid
      and idempotency_key_hash = '$redeemIdempotency'
  ),
  'voucher_redeem_attempts_readback_passed', exists (
    select 1 from voucher_redeem_attempts a, e11_recharge_voucher_ids ids
    where a.tenant_id = '$TenantId'::uuid
      and a.id = ids.attempt_id
      and a.outcome = 'accepted'
      and a.code_lookup_prefix = '$codePrefix'
  ),
  'conflict_refusal_attempt_readback_passed', exists (
    select 1 from voucher_redeem_attempts a, e11_recharge_voucher_ids ids
    where a.tenant_id = '$TenantId'::uuid
      and a.id = ids.refusal_attempt_id
      and a.outcome = 'refused'
      and a.refusal_code = 'idempotency_conflict'
  ),
  'conflict_refusal_no_write_passed', (
    (select redemptions from e11_recharge_voucher_counts_before_refusal) =
      (select count(*) from voucher_redemptions where tenant_id = '$TenantId'::uuid)
    and
    (select credit_grants from e11_recharge_voucher_counts_before_refusal) =
      (select count(*) from credit_grants where tenant_id = '$TenantId'::uuid and metadata->>'operation' = 'voucher_redeem')
    and
    (select ledger_entries from e11_recharge_voucher_counts_before_refusal) =
      (select count(*) from ledger_entries where tenant_id = '$TenantId'::uuid and metadata->>'operation' = 'voucher_redeem')
  ),
  'credit_grant_link_readback_passed', exists (
    select 1 from credit_grants c, e11_recharge_voucher_ids ids
    where c.tenant_id = '$TenantId'::uuid
      and c.id = ids.credit_grant_id
      and c.source = 'voucher_redeem'
  ),
  'ledger_link_readback_passed', exists (
    select 1 from ledger_entries l, e11_recharge_voucher_ids ids
    where l.tenant_id = '$TenantId'::uuid
      and l.id = ids.ledger_entry_id
      and l.entry_type = 'credit_grant'
      and l.status = 'confirmed'
  ),
  'audit_link_readback_passed', exists (
    select 1 from audit_logs a, e11_recharge_voucher_ids ids
    where a.tenant_id = '$TenantId'::uuid
      and a.id in (ids.issue_audit_id, ids.redeem_audit_id)
      and a.action in ('voucher.issue', 'voucher.redeem')
  ),
  'voucher_code_echoed', false,
  'idempotency_material_echoed', false,
  'provider_payload_echoed', false,
  'paid_gate_changed', false
)::text as result;

rollback;
"@
}

function New-RechargeVoucherRuntimeBlockedArtifact {
  param(
    [Parameter(Mandatory = $true)][object]$DbPlan,
    [Parameter(Mandatory = $true)][string[]]$Blockers,
    [string]$DbPlanArtifactPath
  )

  $dbPlanPassed = [bool]$DbPlan.passed
  return [ordered]@{
    schema = "recharge_voucher_runtime_s6_blocked.v1"
    overall_status = "blocked"
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    runtime_implemented = $false
    contract_only = $true
    route_invoked = $false
    internal_runtime_function_invoked = $false
    internal_sqlx_function_invoked = $false
    db_integration_ran = $dbPlanPassed
    db_plan_artifact_path = $DbPlanArtifactPath
    db_plan_passed = $dbPlanPassed
    evidence = [ordered]@{
      voucher_issue_storage_readback = [bool]$DbPlan.voucher_issuance_readback_passed
      voucher_code_hash_readback = [bool]$DbPlan.voucher_issuance_readback_passed
      raw_voucher_code_echoed = [bool]$DbPlan.voucher_code_echoed
      redeem_readback = [bool]$DbPlan.redeem_readback_passed
      redeem_idempotency_replay = [bool]$DbPlan.redeem_idempotency_replay_lookup_passed
      issue_idempotency_replay = [bool]$DbPlan.issue_idempotency_replay_lookup_passed
      conflict_refusal_no_duplicate_write = [bool]$DbPlan.conflict_refusal_no_write_passed
      refusal_attempt_persisted = [bool]$DbPlan.conflict_refusal_attempt_readback_passed
      redeem_attempt_persisted = [bool]$DbPlan.voucher_redeem_attempts_readback_passed
      credit_grant_effect_readback = [bool]$DbPlan.credit_grant_link_readback_passed
      ledger_effect_readback = [bool]$DbPlan.ledger_link_readback_passed
      audit_readback = [bool]$DbPlan.audit_link_readback_passed
      refund_cancel_reversal_readback = $false
    }
    required_runtime_acceptance = [ordered]@{
      pass_artifact_path = ".tmp/credit-wallet/recharge_voucher_runtime.json"
      pass_schema = "recharge_voucher_runtime.v1"
      requires_route_or_internal_runtime_invocation = $true
      requires_refund_cancel_reversal_readback = $true
      requires_qa_verifier_acceptance = $true
    }
    secret_safe = $true
    raw_secret_markers_present = $false
    artifact_secret_policy = [ordered]@{
      raw_dsn_echoed = $false
      raw_token_echoed = $false
      voucher_code_echoed = $false
      idempotency_material_echoed = $false
      provider_payload_echoed = $false
      provider_or_virtual_key_echoed = $false
    }
    paid_gate_changed = $false
    blockers = @($Blockers)
    next_task = "E11-CREDIT-28 should wire a public route or internal Rust/sqlx runtime invocation and add refund/cancel reversal readback before writing .tmp/credit-wallet/recharge_voucher_runtime.json as pass."
  }
}

function Invoke-PsqlJson {
  param(
    [Parameter(Mandatory = $true)][string]$DatabaseUrl,
    [Parameter(Mandatory = $true)][string]$Sql
  )

  $psql = Get-Command psql -ErrorAction SilentlyContinue
  if (-not $psql) {
    throw "psql_unavailable"
  }
  $output = $Sql | & $psql.Source -X -v ON_ERROR_STOP=1 -q -t -A -d $DatabaseUrl 2>&1
  if ($LASTEXITCODE -ne 0) {
    $safe = (($output | Out-String) -replace '(?i)postgres(?:ql)?://[^"\s]+', '<redacted-db-url>')
    throw "psql_execution_failed:$safe"
  }
  $jsonText = ($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
  if ([string]::IsNullOrWhiteSpace($jsonText)) {
    throw "psql_json_output_missing"
  }
  return ($jsonText | ConvertFrom-Json)
}

function Test-RuntimeArtifactPass {
  param([Parameter(Mandatory = $true)][object]$Artifact)

  $evidence = $Artifact.evidence
  return (
    ([string]$Artifact.schema -eq "recharge_voucher_runtime.v1") -and
    ([string]$Artifact.overall_status -eq "pass") -and
    ([bool]$Artifact.runtime_implemented) -and
    (-not [bool]$Artifact.contract_only) -and
    (([bool]$Artifact.route_invoked) -or ([bool]$Artifact.internal_runtime_function_invoked) -or ([bool]$Artifact.internal_sqlx_function_invoked)) -and
    ([bool]$Artifact.db_integration_ran) -and
    ([bool]$Artifact.secret_safe) -and
    (-not [bool]$Artifact.paid_gate_changed) -and
    ([bool]$evidence.voucher_issue_storage_readback) -and
    ([bool]$evidence.voucher_code_hash_readback) -and
    (-not [bool]$evidence.raw_voucher_code_echoed) -and
    ([bool]$evidence.redeem_readback) -and
    ([bool]$evidence.redeem_idempotency_replay) -and
    ([bool]$evidence.conflict_refusal_no_duplicate_write) -and
    ([bool]$evidence.refusal_attempt_persisted) -and
    ([bool]$evidence.redeem_attempt_persisted) -and
    (([bool]$evidence.credit_grant_effect_readback) -or ([bool]$evidence.ledger_effect_readback)) -and
    ([bool]$evidence.audit_readback) -and
    ([bool]$evidence.refund_cancel_reversal_readback)
  )
}

function Invoke-RechargeVoucherRustRuntimeTest {
  param([Parameter(Mandatory = $true)][hashtable]$RuntimeOutput)

  $oldPath = $env:RECHARGE_VOUCHER_RUNTIME_ARTIFACT_PATH
  $env:RECHARGE_VOUCHER_RUNTIME_ARTIFACT_PATH = $RuntimeOutput.full
  try {
    $output = & cargo test -p ai-control-plane recharge_voucher_internal_runtime_db_integration -- --ignored --nocapture 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    if ($null -eq $oldPath) {
      Remove-Item Env:RECHARGE_VOUCHER_RUNTIME_ARTIFACT_PATH -ErrorAction SilentlyContinue
    } else {
      $env:RECHARGE_VOUCHER_RUNTIME_ARTIFACT_PATH = $oldPath
    }
  }

  $text = (($output | ForEach-Object { [string]$_ }) -join "`n")
  if (-not (Test-SecretSafeText $text)) {
    return [ordered]@{
      ran = $true
      passed = $false
      blocker = "recharge_voucher_internal_runtime_output_secret_unsafe"
      cargo_exit_code = $exitCode
      artifact = $null
    }
  }
  if ($exitCode -ne 0) {
    return [ordered]@{
      ran = $true
      passed = $false
      blocker = "recharge_voucher_internal_runtime_cargo_test_failed"
      cargo_exit_code = $exitCode
      artifact = $null
    }
  }
  if (-not (Test-Path -LiteralPath $RuntimeOutput.full)) {
    return [ordered]@{
      ran = $true
      passed = $false
      blocker = "recharge_voucher_runtime_artifact_missing_after_internal_test"
      cargo_exit_code = $exitCode
      artifact = $null
    }
  }
  $artifactText = Get-Content -LiteralPath $RuntimeOutput.full -Raw
  if (-not (Test-SecretSafeText $artifactText)) {
    return [ordered]@{
      ran = $true
      passed = $false
      blocker = "recharge_voucher_runtime_artifact_secret_unsafe"
      cargo_exit_code = $exitCode
      artifact = $null
    }
  }
  $artifact = $artifactText | ConvertFrom-Json
  $passed = Test-RuntimeArtifactPass -Artifact $artifact
  return [ordered]@{
    ran = $true
    passed = $passed
    blocker = $(if ($passed) { "" } else { "recharge_voucher_runtime_artifact_acceptance_failed" })
    cargo_exit_code = $exitCode
    artifact = $artifact
  }
}

function Invoke-SelfTest {
  $blocked = New-RechargeVoucherArtifact `
    -Status "blocked" `
    -Blockers @("db_opt_in_missing") `
    -DbIntegrationRan $false `
    -DbPlan ([ordered]@{ passed = $false }) `
    -MissingEnv @("RECHARGE_VOUCHER_DB_OPT_IN")
  $partial = New-RechargeVoucherArtifact `
    -Status "partial" `
    -Blockers @("route_runtime_not_invoked") `
    -DbIntegrationRan $true `
    -DbPlan ([ordered]@{ passed = $true; voucher_issuance_readback_passed = $true }) `
    -MissingEnv @()

  $blockedJson = $blocked | ConvertTo-Json -Depth 12
  $partialJson = $partial | ConvertTo-Json -Depth 12
  $runtimeBlocked = New-RechargeVoucherRuntimeBlockedArtifact `
    -DbPlan ([ordered]@{
      passed = $true
      voucher_issuance_readback_passed = $true
      voucher_code_echoed = $false
      redeem_readback_passed = $true
      redeem_idempotency_replay_lookup_passed = $true
      issue_idempotency_replay_lookup_passed = $true
      conflict_refusal_no_write_passed = $true
      conflict_refusal_attempt_readback_passed = $true
      voucher_redeem_attempts_readback_passed = $true
      credit_grant_link_readback_passed = $true
      ledger_link_readback_passed = $true
      audit_link_readback_passed = $true
    }) `
    -Blockers @("route_runtime_not_invoked", "refund_cancel_reversal_not_implemented") `
    -DbPlanArtifactPath ".tmp/credit-wallet/recharge_voucher_runtime_db_plan.json"
  $runtimeBlockedJson = $runtimeBlocked | ConvertTo-Json -Depth 12
  $runtimePass = [pscustomobject]@{
    schema = "recharge_voucher_runtime.v1"
    overall_status = "pass"
    runtime_implemented = $true
    contract_only = $false
    route_invoked = $false
    internal_runtime_function_invoked = $true
    internal_sqlx_function_invoked = $true
    db_integration_ran = $true
    secret_safe = $true
    paid_gate_changed = $false
    evidence = [pscustomobject]@{
      voucher_issue_storage_readback = $true
      voucher_code_hash_readback = $true
      raw_voucher_code_echoed = $false
      redeem_readback = $true
      redeem_idempotency_replay = $true
      conflict_refusal_no_duplicate_write = $true
      refusal_attempt_persisted = $true
      redeem_attempt_persisted = $true
      credit_grant_effect_readback = $true
      ledger_effect_readback = $true
      audit_readback = $true
      refund_cancel_reversal_readback = $true
    }
  }
  $runtimePassMissingReversal = ($runtimePass | ConvertTo-Json -Depth 8) | ConvertFrom-Json
  $runtimePassMissingReversal.evidence.refund_cancel_reversal_readback = $false
  $selftestDir = Resolve-RepoBoundedPath -Path ".tmp/credit-wallet/selftest" -AllowedPrefixes @(".tmp/")
  if (-not (Test-Path -LiteralPath $selftestDir.full)) {
    New-Item -ItemType Directory -Path $selftestDir.full -Force | Out-Null
  }
  $existingPath = Join-Path $selftestDir.full "existing_db_attempt.json"
  $existingRelative = " .tmp/credit-wallet/selftest/existing_db_attempt.json".Trim()
  $existingOutput = [ordered]@{ full = $existingPath; relative = $existingRelative }
  Set-Content -LiteralPath $existingPath -Encoding UTF8 -Value (@{
      schema = "recharge_voucher_runtime_db_plan.v1"
      overall_status = "blocked"
      db_integration_ran = $true
      blockers = @("recharge_voucher_schema_0012_not_applied")
    } | ConvertTo-Json -Depth 4)
  $selectedBlockedOutput = Select-DefaultBlockedOutput -Output $existingOutput -AllowOverwrite:$false
  $preservedContent = Get-Content -LiteralPath $existingPath -Raw
  $cases = @(
    [ordered]@{ name = "blocked_is_contract_only"; status = if (($blocked.runtime_implemented -eq $false) -and ($blocked.contract_only -eq $true)) { "pass" } else { "fail" } },
    [ordered]@{ name = "partial_db_plan_not_runtime"; status = if (($partial.runtime_implemented -eq $false) -and ($partial.route_invoked -eq $false)) { "pass" } else { "fail" } },
    [ordered]@{ name = "s6_runtime_blocked_artifact_not_runtime"; status = if (($runtimeBlocked.runtime_implemented -eq $false) -and ($runtimeBlocked.contract_only -eq $true) -and ($runtimeBlocked.schema -ne "recharge_voucher_runtime.v1")) { "pass" } else { "fail" } },
    [ordered]@{ name = "s6_runtime_blocked_requires_reversal_and_invocation"; status = if (($runtimeBlocked.blockers -contains "route_runtime_not_invoked") -and ($runtimeBlocked.blockers -contains "refund_cancel_reversal_not_implemented")) { "pass" } else { "fail" } },
    [ordered]@{ name = "runtime_pass_requires_reversal_and_internal_invocation"; status = if (Test-RuntimeArtifactPass -Artifact $runtimePass) { "pass" } else { "fail" } },
    [ordered]@{ name = "runtime_pass_rejects_missing_reversal"; status = if (-not (Test-RuntimeArtifactPass -Artifact $runtimePassMissingReversal)) { "pass" } else { "fail" } },
    [ordered]@{ name = "secret_safe_blocked"; status = if (Test-SecretSafeText $blockedJson) { "pass" } else { "fail" } },
    [ordered]@{ name = "secret_safe_partial"; status = if (Test-SecretSafeText $partialJson) { "pass" } else { "fail" } },
    [ordered]@{ name = "secret_safe_s6_runtime_blocked"; status = if (Test-SecretSafeText $runtimeBlockedJson) { "pass" } else { "fail" } },
    [ordered]@{ name = "existing_db_attempt_artifact_preserved_by_default_blocked"; status = if (($selectedBlockedOutput.preserved_existing_artifact -eq $true) -and ($selectedBlockedOutput.output.relative.EndsWith(".default_blocked.json")) -and ($preservedContent -match "recharge_voucher_schema_0012_not_applied")) { "pass" } else { "fail" } }
  )
  $failed = @($cases | Where-Object { $_.status -ne "pass" })
  [ordered]@{
    schema = "recharge_voucher_runtime_db_plan_selftest.v1"
    overall_status = if ($failed.Count -eq 0) { "pass" } else { "fail" }
    actual_exit_code = if ($failed.Count -eq 0) { 0 } else { 1 }
    cases = $cases
  }
}

if ($SelfTest) {
  $result = Invoke-SelfTest
  $result | ConvertTo-Json -Depth 8
  exit ([int]$result.actual_exit_code)
}

$output = Resolve-RepoBoundedPath -Path $OutputPath -AllowedPrefixes @(".tmp/", "artifacts/")
$runtimeOutput = Resolve-RepoBoundedPath -Path $RuntimeOutputPath -AllowedPrefixes @(".tmp/", "artifacts/")
$runtimeBlockedOutput = if ($WriteRuntimeBlockedArtifact) {
  Resolve-RepoBoundedPath -Path $RuntimeBlockedOutputPath -AllowedPrefixes @(".tmp/", "artifacts/")
} else {
  $null
}
$missingEnv = [System.Collections.Generic.List[string]]::new()
if ($env:RECHARGE_VOUCHER_DB_OPT_IN -ne "1") { [void]$missingEnv.Add("RECHARGE_VOUCHER_DB_OPT_IN") }
$dbUrl = if ($env:CONTROL_PLANE_DATABASE_URL) { $env:CONTROL_PLANE_DATABASE_URL } else { $env:DATABASE_URL }
if ([string]::IsNullOrWhiteSpace($dbUrl)) { [void]$missingEnv.Add("CONTROL_PLANE_DATABASE_URL_or_DATABASE_URL") }

if ($RunInternalRuntime) {
  $runtimeMissingEnv = [System.Collections.Generic.List[string]]::new()
  if ($env:RECHARGE_VOUCHER_DB_OPT_IN -ne "1") { [void]$runtimeMissingEnv.Add("RECHARGE_VOUCHER_DB_OPT_IN") }
  if ([string]::IsNullOrWhiteSpace($dbUrl)) { [void]$runtimeMissingEnv.Add("CONTROL_PLANE_DATABASE_URL_or_DATABASE_URL") }
  if ($runtimeMissingEnv.Count -gt 0) {
    $runtimeBlockedArtifact = New-RechargeVoucherRuntimeBlockedArtifact `
      -DbPlan ([ordered]@{ passed = $false; reason = "opt_in_or_database_env_missing" }) `
      -Blockers (@("recharge_voucher_internal_runtime_env_missing") + @($runtimeMissingEnv | ForEach-Object { "missing_$_" })) `
      -DbPlanArtifactPath $output.relative
    $runtimeBlockedOutputForMissing = Resolve-RepoBoundedPath -Path $RuntimeBlockedOutputPath -AllowedPrefixes @(".tmp/", "artifacts/")
    Write-Artifact -Artifact $runtimeBlockedArtifact -Output $runtimeBlockedOutputForMissing
    Write-Output "recharge_voucher_runtime_artifact_status=blocked"
    Write-Output "recharge_voucher_runtime_s6_blocked_path=$($runtimeBlockedOutputForMissing.relative)"
    Write-Output "recharge_voucher_runtime_implemented=false"
    exit 1
  }

  $runtimeResult = Invoke-RechargeVoucherRustRuntimeTest -RuntimeOutput $runtimeOutput
  if (-not [bool]$runtimeResult.passed) {
    $runtimeBlockedArtifact = New-RechargeVoucherRuntimeBlockedArtifact `
      -DbPlan ([ordered]@{ passed = $false; reason = $runtimeResult.blocker; cargo_exit_code = $runtimeResult.cargo_exit_code }) `
      -Blockers @([string]$runtimeResult.blocker) `
      -DbPlanArtifactPath $output.relative
    $runtimeBlockedOutputForFailure = Resolve-RepoBoundedPath -Path $RuntimeBlockedOutputPath -AllowedPrefixes @(".tmp/", "artifacts/")
    Write-Artifact -Artifact $runtimeBlockedArtifact -Output $runtimeBlockedOutputForFailure
    Write-Output "recharge_voucher_runtime_artifact_status=blocked"
    Write-Output "recharge_voucher_runtime_s6_blocked_path=$($runtimeBlockedOutputForFailure.relative)"
    Write-Output "recharge_voucher_runtime_implemented=false"
    exit 1
  }
  Write-Output "recharge_voucher_runtime_artifact_status=pass"
  Write-Output "recharge_voucher_runtime_artifact_path=$($runtimeOutput.relative)"
  Write-Output "recharge_voucher_runtime_implemented=true"
  exit 0
}

if (-not $RunDbIntegration -or $missingEnv.Count -gt 0) {
  $selectedOutput = Select-DefaultBlockedOutput -Output $output -AllowOverwrite ([bool]$Overwrite)
  $blockers = @()
  if (-not $RunDbIntegration) { $blockers += "run_db_integration_flag_missing" }
  foreach ($missing in $missingEnv) { $blockers += "missing_$missing" }
  $artifact = New-RechargeVoucherArtifact `
    -Status "blocked" `
    -Blockers $blockers `
    -DbIntegrationRan $false `
    -DbPlan ([ordered]@{ passed = $false; reason = "opt_in_or_database_env_missing" }) `
    -MissingEnv @($missingEnv) `
    -PreservedExistingArtifact ([bool]$selectedOutput.preserved_existing_artifact) `
    -PreservedArtifactPath $selectedOutput.preserved_artifact_path
  Write-Artifact -Artifact $artifact -Output $selectedOutput.output
  Write-Output "recharge_voucher_runtime_db_plan_status=blocked"
  Write-Output "recharge_voucher_runtime_db_plan_path=$($selectedOutput.output.relative)"
  if ($selectedOutput.preserved_existing_artifact) {
    Write-Output "recharge_voucher_runtime_db_plan_preserved_existing=$($selectedOutput.preserved_artifact_path)"
  }
  Write-Output "recharge_voucher_runtime_implemented=false"
  exit 1
}

$runId = ([Guid]::NewGuid().ToString("N")).Substring(0, 24)
$sql = New-RechargeVoucherDbPlanSql -TenantId $SeedTenantId -WalletId $SeedWalletId -RunId $runId
try {
  $dbPlan = Invoke-PsqlJson -DatabaseUrl $dbUrl -Sql $sql
  $required = @(
    "voucher_issuance_readback_passed",
    "issue_idempotency_replay_lookup_passed",
    "redeem_readback_passed",
    "redeem_idempotency_replay_lookup_passed",
    "voucher_redeem_attempts_readback_passed",
    "conflict_refusal_attempt_readback_passed",
    "conflict_refusal_no_write_passed",
    "credit_grant_link_readback_passed",
    "ledger_link_readback_passed",
    "audit_link_readback_passed"
  )
  $missingChecks = @()
  foreach ($field in $required) {
    if (-not [bool]$dbPlan.$field) { $missingChecks += $field }
  }
  $passed = ($missingChecks.Count -eq 0)
  $artifact = New-RechargeVoucherArtifact `
    -Status $(if ($passed) { "partial" } else { "blocked" }) `
    -Blockers $(if ($passed) { @("route_runtime_not_invoked", "qa_runtime_artifact_missing") } else { @("db_plan_readback_failed") + $missingChecks }) `
    -DbIntegrationRan $true `
    -DbPlan $dbPlan `
    -MissingEnv @()
  Write-Artifact -Artifact $artifact -Output $output
  if ($WriteRuntimeBlockedArtifact) {
    $runtimeBlockers = if ($passed) {
      @(
        "route_runtime_not_invoked",
        "internal_runtime_function_not_invoked",
        "refund_cancel_reversal_not_implemented",
        "qa_runtime_artifact_missing"
      )
    } else {
      @("db_plan_readback_failed") + $missingChecks
    }
    $runtimeBlockedArtifact = New-RechargeVoucherRuntimeBlockedArtifact `
      -DbPlan $dbPlan `
      -Blockers $runtimeBlockers `
      -DbPlanArtifactPath $output.relative
    Write-Artifact -Artifact $runtimeBlockedArtifact -Output $runtimeBlockedOutput
    Write-Output "recharge_voucher_runtime_s6_blocked_path=$($runtimeBlockedOutput.relative)"
  }
  Write-Output "recharge_voucher_runtime_db_plan_status=$($artifact.overall_status)"
  Write-Output "recharge_voucher_runtime_db_plan_path=$($output.relative)"
  Write-Output "recharge_voucher_runtime_implemented=false"
  exit $(if ($passed) { 0 } else { 1 })
} catch {
  $errorText = [string]$_.Exception.Message
  $safeError = ($errorText -replace '(?i)postgres(?:ql)?://[^"\s]+', '<redacted-db-url>')
  if (-not (Test-SecretSafeText $safeError)) { $safeError = "redacted_db_plan_error" }
  $blockers = @("recharge_voucher_db_plan_unavailable")
  if ($safeError -match 'relation "(voucher_issuances|voucher_redemptions|voucher_redeem_attempts|voucher_campaigns|recharge_intents)" does not exist') {
    $blockers = @("recharge_voucher_schema_0012_not_applied")
  }
  $artifact = New-RechargeVoucherArtifact `
    -Status "blocked" `
    -Blockers $blockers `
    -DbIntegrationRan $false `
    -DbPlan ([ordered]@{ passed = $false; error = $safeError }) `
    -MissingEnv @()
  Write-Artifact -Artifact $artifact -Output $output
  if ($WriteRuntimeBlockedArtifact) {
    $runtimeBlockedArtifact = New-RechargeVoucherRuntimeBlockedArtifact `
      -DbPlan ([ordered]@{ passed = $false; error = $safeError }) `
      -Blockers $blockers `
      -DbPlanArtifactPath $output.relative
    Write-Artifact -Artifact $runtimeBlockedArtifact -Output $runtimeBlockedOutput
    Write-Output "recharge_voucher_runtime_s6_blocked_path=$($runtimeBlockedOutput.relative)"
  }
  Write-Output "recharge_voucher_runtime_db_plan_status=blocked"
  Write-Output "recharge_voucher_runtime_db_plan_path=$($output.relative)"
  Write-Output "recharge_voucher_runtime_implemented=false"
  exit 1
}
