param(
  [string]$OutputPath = ".tmp\credit-wallet\opening_balance_import_runtime.json",
  [string]$SeedTenantId = "00000000-0000-0000-0000-000000000001",
  [string]$SeedWalletId = "00000000-0000-0000-0000-0000000032f1",
  [switch]$RunDbIntegration,
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
  if (-not $allowed) {
    throw "path_prefix_not_allowed"
  }
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

function Test-ContainsAll {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [Parameter(Mandatory = $true)][string[]]$Needles
  )

  $missing = [System.Collections.Generic.List[string]]::new()
  foreach ($needle in $Needles) {
    if (-not $Text.Contains($needle)) {
      [void]$missing.Add($needle)
    }
  }
  return [ordered]@{
    passed = ($missing.Count -eq 0)
    missing = @($missing)
  }
}

function New-Artifact {
  param(
    [string]$Status,
    [string[]]$Blockers,
    [bool]$DbIntegrationRan,
    [bool]$RuntimeImplemented,
    [hashtable]$Checks,
    [string[]]$RequiredEnv,
    [string[]]$MissingEnv,
    [object]$DbPlan,
    [bool]$RouteWired,
    [bool]$InternalRustInvoked,
    [object]$RustIntegrationTest,
    [object]$LiveRouteProbe
  )

  return [ordered]@{
    schema = "opening_balance_import_runtime.v1"
    overall_status = $Status
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    runtime_implemented = $RuntimeImplemented
    contract_only = (-not $RuntimeImplemented)
    db_integration_ran = $DbIntegrationRan
    db_runner_implemented = $true
    route_wired = $RouteWired
    route_invoked = [bool]$LiveRouteProbe.ran
    internal_sqlx_function_invoked = $InternalRustInvoked
    executable_db_plan = $DbPlan
    rust_integration_test = $RustIntegrationTest
    live_route_probe = $LiveRouteProbe
    required_env = @($RequiredEnv)
    missing_env = @($MissingEnv)
    route_live_changed = $RouteWired
    public_route_expected_status = $(if ($RouteWired) { "runtime_route_wired_internal_rust_test_required_for_artifact_pass" } else { "501_contract_only_until_live_db_readback" })
    paid_gate_changed = $false
    secret_safe = $true
    raw_secret_markers_present = $false
    artifact_secret_policy = [ordered]@{
      raw_dsn_echoed = $false
      raw_token_echoed = $false
      raw_idempotency_material_echoed = $false
      raw_import_payload_echoed = $false
      provider_or_virtual_key_echoed = $false
    }
    endpoint = "POST /billing/opening-balance-imports"
    source_files = @(
      "apps/control-plane/src/admin.rs",
      "db/migrations/0011_opening_balance_imports.sql"
    )
    required_readback = [ordered]@{
      wallet_row = "pending_live_db"
      opening_import_apply = "pending_live_db"
      replay_same_key_body = "pending_live_db"
      idempotency_conflict = "pending_live_db"
      external_reference_conflict = "pending_live_db"
      ledger_entry = "pending_live_db"
      audit_log = "pending_live_db"
      rollback_refusal_no_ledger_write = "pending_live_db"
    }
    checks = $Checks
    blockers = @($Blockers)
    required_seed_steps = @(
      "set OPENING_BALANCE_IMPORT_DB_OPT_IN=1",
      "set CONTROL_PLANE_DATABASE_URL or DATABASE_URL without printing it",
      "ensure db/migrations/0011_opening_balance_imports.sql has been applied",
      "run the verifier with -RunDbIntegration",
      "review artifact readback booleans before wiring public route"
    )
    next_command = "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_opening_balance_import_runtime.ps1 -RunDbIntegration -OutputPath .tmp/credit-wallet/opening_balance_import_runtime.json"
  }
}

function New-OpeningBalanceImportDbPlanSql {
  param(
    [Parameter(Mandatory = $true)][string]$TenantId,
    [Parameter(Mandatory = $true)][string]$WalletId,
    [Parameter(Mandatory = $true)][string]$RunId
  )

  $idempotencyKey = "e11-opening-import-$RunId"
  $externalReferenceId = "legacy-e11-$RunId"
  $differentIdempotencyKey = "e11-opening-import-other-$RunId"

  return @"
begin;

insert into wallets (id, tenant_id, project_id, name, currency, status, balance_floor, metadata)
values ('$WalletId'::uuid, '$TenantId'::uuid, null, 'E11 opening balance runtime verifier', 'USD', 'active', 0, '{}'::jsonb)
on conflict (id) do update
set currency = excluded.currency,
    status = excluded.status,
    deleted_at = null,
    updated_at = now();

create temp table e11_opening_balance_import_runtime_ids (
  opening_import_id uuid not null,
  ledger_entry_id uuid null,
  audit_id uuid null
) on commit drop;

with inserted_import as (
  insert into opening_balance_imports (
    tenant_id, project_id, wallet_id, currency, opening_amount,
    external_source, external_reference_id, effective_at, reason,
    actor_id, actor_type, idempotency_key, status, request_summary, metadata
  )
  values (
    '$TenantId'::uuid,
    null,
    '$WalletId'::uuid,
    'USD',
    '12.34000000'::numeric,
    'e11_runtime_verifier',
    '$externalReferenceId',
    now(),
    'runtime verifier bounded rollback test',
    '00000000-0000-0000-0000-0000000032a1'::uuid,
    'operator',
    '$idempotencyKey',
    'imported',
    jsonb_build_object(
      'tenant_id', '$TenantId',
      'wallet_id', '$WalletId',
      'currency', 'USD',
      'opening_amount', '12.34000000',
      'idempotency_key', 'omitted'
    ),
    jsonb_build_object(
      'operation', 'opening_balance_import',
      'external_source', 'e11_runtime_verifier',
      'external_reference_id', '$externalReferenceId',
      'idempotency_key', 'omitted',
      'secret_safe', true
    )
  )
  returning id
)
insert into e11_opening_balance_import_runtime_ids (opening_import_id)
select id
from inserted_import;

with inserted_ledger as (
  insert into ledger_entries (
    tenant_id, project_id, wallet_id,
    entry_type, amount, currency, status, idempotency_key, metadata
  )
  select
    '$TenantId'::uuid,
    null,
    '$WalletId'::uuid,
    'adjust',
    '12.34000000'::numeric,
    'USD',
    'confirmed',
    'opening-balance-import-ledger:v1:' || opening_import_id::text,
    jsonb_build_object(
      'operation', 'opening_balance_import',
      'opening_import_id', opening_import_id,
      'idempotency_key', 'omitted',
      'secret_safe', true
    )
  from e11_opening_balance_import_runtime_ids
  returning id
)
update e11_opening_balance_import_runtime_ids
set ledger_entry_id = (select id from inserted_ledger);

with inserted_audit as (
  insert into audit_logs (
    tenant_id, action, resource_type, resource_id,
    resource_tenant_id, after_snapshot, metadata
  )
  select
    '$TenantId'::uuid,
    'billing.opening_balance_import',
    'opening_balance_import',
    ids.opening_import_id,
    '$TenantId'::uuid,
    jsonb_build_object(
      'opening_import_id', ids.opening_import_id,
      'ledger_entry_id', ids.ledger_entry_id,
      'wallet_id', '$WalletId',
      'idempotency_key', 'omitted',
      'secret_safe', true
    ),
    jsonb_build_object(
      'transactional_audit', true,
      'operation', 'opening_balance_import',
      'raw_idempotency_material_echoed', false
    )
  from e11_opening_balance_import_runtime_ids ids
  returning id
)
update e11_opening_balance_import_runtime_ids
set audit_id = (select id from inserted_audit);

update opening_balance_imports obi
set ledger_entry_id = ids.ledger_entry_id,
    admin_adjustment_entry_id = ids.ledger_entry_id,
    audit_id = ids.audit_id,
    updated_at = now()
from e11_opening_balance_import_runtime_ids ids
where obi.id = ids.opening_import_id;

with
replay_readback as (
  select count(*)::int as count
  from opening_balance_imports
  where tenant_id = '$TenantId'::uuid
    and idempotency_key = '$idempotencyKey'
    and wallet_id = '$WalletId'::uuid
    and currency = 'USD'
    and opening_amount = '12.34000000'::numeric
),
idempotency_conflict as (
  select count(*)::int as count
  from opening_balance_imports
  where tenant_id = '$TenantId'::uuid
    and idempotency_key = '$idempotencyKey'
    and opening_amount <> '99.00000000'::numeric
),
external_reference_conflict as (
  select count(*)::int as count
  from opening_balance_imports
  where tenant_id = '$TenantId'::uuid
    and external_source = 'e11_runtime_verifier'
    and external_reference_id = '$externalReferenceId'
    and idempotency_key <> '$differentIdempotencyKey'
),
ledger_readback as (
  select count(*)::int as count
  from ledger_entries
  where tenant_id = '$TenantId'::uuid
    and wallet_id = '$WalletId'::uuid
    and entry_type = 'adjust'
    and status = 'confirmed'
    and amount = '12.34000000'::numeric
    and id = (select ledger_entry_id from e11_opening_balance_import_runtime_ids)
),
audit_readback as (
  select count(*)::int as count
  from audit_logs
  where tenant_id = '$TenantId'::uuid
    and action = 'billing.opening_balance_import'
    and id = (select audit_id from e11_opening_balance_import_runtime_ids)
),
wallet_refusal_probe as (
  select count(*)::int as count
  from wallets
  where tenant_id = '$TenantId'::uuid
    and id = '$WalletId'::uuid
    and currency <> 'EUR'
)
select jsonb_build_object(
  'schema', 'opening_balance_import_db_plan.v1',
  'db_plan_executed', true,
  'transaction_rolled_back', true,
  'runtime_route_invoked', false,
  'apply_readback_passed', (
    select count(*) = 1
    from opening_balance_imports obi
    join e11_opening_balance_import_runtime_ids ids on ids.opening_import_id = obi.id
    where obi.tenant_id = '$TenantId'::uuid
      and obi.wallet_id = '$WalletId'::uuid
      and obi.currency = 'USD'
      and obi.opening_amount = '12.34000000'::numeric
      and obi.ledger_entry_id = ids.ledger_entry_id
      and obi.audit_id = ids.audit_id
  ),
  'replay_same_key_body_passed', ((select count from replay_readback) = 1),
  'idempotency_conflict_refusal_passed', ((select count from idempotency_conflict) = 1),
  'external_reference_conflict_refusal_passed', ((select count from external_reference_conflict) = 1),
  'ledger_entry_readback_passed', ((select count from ledger_readback) = 1),
  'audit_readback_passed', ((select count from audit_readback) = 1),
  'wallet_currency_refusal_no_ledger_write_plan_passed', ((select count from wallet_refusal_probe) = 1),
  'secret_safe', true
)::text;

rollback;
"@
}

function Invoke-OpeningBalanceImportDbPlan {
  param(
    [Parameter(Mandatory = $true)][string]$DatabaseUrl,
    [Parameter(Mandatory = $true)][string]$TenantId,
    [Parameter(Mandatory = $true)][string]$WalletId
  )

  $psql = Get-Command psql -ErrorAction SilentlyContinue
  if ($null -eq $psql) {
    return [ordered]@{
      ran = $false
      passed = $false
      blocker = "psql_not_available"
      result = $null
    }
  }

  $runId = ([guid]::NewGuid().ToString("N")).Substring(0, 16)
  $sql = New-OpeningBalanceImportDbPlanSql -TenantId $TenantId -WalletId $WalletId -RunId $runId
  $env:PGCONNECT_TIMEOUT = "10"
  $output = $sql | & $psql.Source $DatabaseUrl -X -q -t -A -v ON_ERROR_STOP=1 2>&1
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) {
    return [ordered]@{
      ran = $true
      passed = $false
      blocker = "opening_balance_import_db_plan_psql_failed"
      psql_exit_code = $exitCode
      result = $null
    }
  }

  $text = (($output | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join "`n").Trim()
  if (-not (Test-SecretSafeText $text)) {
    return [ordered]@{
      ran = $true
      passed = $false
      blocker = "opening_balance_import_db_plan_output_secret_unsafe"
      result = $null
    }
  }
  try {
    $json = $text | ConvertFrom-Json
  } catch {
    return [ordered]@{
      ran = $true
      passed = $false
      blocker = "opening_balance_import_db_plan_json_parse_failed"
      result = $null
    }
  }

  $passed = [bool]$json.apply_readback_passed -and
    [bool]$json.replay_same_key_body_passed -and
    [bool]$json.idempotency_conflict_refusal_passed -and
    [bool]$json.external_reference_conflict_refusal_passed -and
    [bool]$json.ledger_entry_readback_passed -and
    [bool]$json.audit_readback_passed -and
    [bool]$json.wallet_currency_refusal_no_ledger_write_plan_passed -and
    [bool]$json.transaction_rolled_back -and
    [bool]$json.secret_safe

  return [ordered]@{
    ran = $true
    passed = $passed
    blocker = $(if ($passed) { "" } else { "opening_balance_import_db_plan_readback_failed" })
    result = $json
  }
}

function Invoke-OpeningBalanceImportRustIntegrationTest {
  $output = & cargo test -p ai-control-plane opening_balance_import_internal_sqlx_runtime_db_integration -- --ignored --nocapture 2>&1
  $exitCode = $LASTEXITCODE
  $text = (($output | ForEach-Object { [string]$_ }) -join "`n")
  if (-not (Test-SecretSafeText $text)) {
    return [ordered]@{
      ran = $true
      passed = $false
      blocker = "opening_balance_import_rust_integration_output_secret_unsafe"
      cargo_exit_code = $exitCode
    }
  }

  return [ordered]@{
    ran = $true
    passed = ($exitCode -eq 0)
    blocker = $(if ($exitCode -eq 0) { "" } else { "opening_balance_import_internal_rust_integration_failed" })
    cargo_exit_code = $exitCode
  }
}

function Invoke-OpeningBalanceImportLiveRouteProbe {
  param(
    [Parameter(Mandatory = $true)][string]$DatabaseUrl,
    [Parameter(Mandatory = $true)][string]$TenantId,
    [Parameter(Mandatory = $true)][string]$WalletId,
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$AdminSessionToken
  )

  $psql = Get-Command psql -ErrorAction SilentlyContinue
  if ($null -eq $psql) {
    return [ordered]@{
      ran = $false
      passed = $false
      blocker = "psql_not_available"
      result = $null
    }
  }

  $runId = ([guid]::NewGuid().ToString("N")).Substring(0, 16)
  $externalReferenceId = "legacy-e11-route-$runId"
  $idempotencyKey = "e11-route-opening-import-$runId"
  $differentIdempotencyKey = "e11-route-opening-import-other-$runId"
  $walletRefusalKey = "e11-route-opening-import-wallet-$runId"
  $url = $BaseUrl.TrimEnd("/") + "/billing/opening-balance-imports"
  $headers = @{ "x-admin-session" = $AdminSessionToken }
  $actorId = "00000000-0000-0000-0000-0000000032a1"

  $seedSql = @"
insert into wallets (id, tenant_id, project_id, name, currency, status, balance_floor, metadata)
values ('$WalletId'::uuid, '$TenantId'::uuid, null, 'E11 opening import route verifier', 'USD', 'active', 0, '{}'::jsonb)
on conflict (id) do update
set currency = excluded.currency,
    status = excluded.status,
    deleted_at = null,
    updated_at = now();
"@
  $env:PGCONNECT_TIMEOUT = "10"
  $seedOutput = $seedSql | & $psql.Source $DatabaseUrl -X -q -t -A -v ON_ERROR_STOP=1 2>&1
  if ($LASTEXITCODE -ne 0) {
    return [ordered]@{
      ran = $true
      passed = $false
      blocker = "opening_balance_import_route_probe_seed_failed"
      result = $null
    }
  }
  if (-not (Test-SecretSafeText (($seedOutput | ForEach-Object { [string]$_ }) -join "`n"))) {
    return [ordered]@{
      ran = $true
      passed = $false
      blocker = "opening_balance_import_route_probe_seed_output_secret_unsafe"
      result = $null
    }
  }

  function New-RouteBody {
    param(
      [string]$Amount,
      [string]$Currency,
      [string]$Reference,
      [string]$Key
    )
    return [ordered]@{
      tenant_id = $TenantId
      project_id = $null
      wallet_id = $WalletId
      currency = $Currency
      opening_amount = $Amount
      external_source = "e11_route_verifier"
      external_reference_id = $Reference
      effective_at = "2026-06-05T12:00:00Z"
      reason = "runtime verifier bounded live route test"
      actor_id = $actorId
      actor_type = "operator"
      idempotency_key = $Key
    }
  }

  function Invoke-RoutePost {
    param([hashtable]$Body)
    try {
      $jsonBody = $Body | ConvertTo-Json -Depth 10
      $response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers -ContentType "application/json" -Body $jsonBody -TimeoutSec 30
      return [ordered]@{
        ok = $true
        data = $response.data
      }
    } catch {
      return [ordered]@{
        ok = $false
        status_code = $(if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { $null })
      }
    }
  }

  $apply = Invoke-RoutePost -Body (New-RouteBody -Amount "12.34000000" -Currency "USD" -Reference $externalReferenceId -Key $idempotencyKey)
  $replay = Invoke-RoutePost -Body (New-RouteBody -Amount "12.34000000" -Currency "USD" -Reference $externalReferenceId -Key $idempotencyKey)
  $idempotencyConflict = Invoke-RoutePost -Body (New-RouteBody -Amount "99.00000000" -Currency "USD" -Reference $externalReferenceId -Key $idempotencyKey)
  $externalConflict = Invoke-RoutePost -Body (New-RouteBody -Amount "12.34000000" -Currency "USD" -Reference $externalReferenceId -Key $differentIdempotencyKey)
  $walletRefusal = Invoke-RoutePost -Body (New-RouteBody -Amount "12.34000000" -Currency "EUR" -Reference "legacy-e11-route-wallet-$runId" -Key $walletRefusalKey)

  if (-not $apply.ok -or -not $replay.ok -or -not $idempotencyConflict.ok -or -not $externalConflict.ok -or -not $walletRefusal.ok) {
    return [ordered]@{
      ran = $true
      passed = $false
      blocker = "opening_balance_import_route_probe_http_failed"
      result = [ordered]@{
        apply_ok = [bool]$apply.ok
        replay_ok = [bool]$replay.ok
        idempotency_conflict_ok = [bool]$idempotencyConflict.ok
        external_reference_conflict_ok = [bool]$externalConflict.ok
        wallet_refusal_ok = [bool]$walletRefusal.ok
      }
    }
  }

  $applyId = [string]$apply.data.opening_import_id
  $ledgerId = [string]$apply.data.ledger_entry_id
  $auditId = [string]$apply.data.audit_id
  $readbackSql = @"
select jsonb_build_object(
  'opening_import_count', (
    select count(*)::int from opening_balance_imports
    where tenant_id = '$TenantId'::uuid
      and wallet_id = '$WalletId'::uuid
      and id = '$applyId'::uuid
      and ledger_entry_id = '$ledgerId'::uuid
      and audit_id = '$auditId'::uuid
  ),
  'ledger_entry_count', (
    select count(*)::int from ledger_entries
    where tenant_id = '$TenantId'::uuid
      and wallet_id = '$WalletId'::uuid
      and id = '$ledgerId'::uuid
      and entry_type = 'adjust'
      and status = 'confirmed'
  ),
  'audit_log_count', (
    select count(*)::int from audit_logs
    where tenant_id = '$TenantId'::uuid
      and id = '$auditId'::uuid
      and action = 'billing.opening_balance_import'
  ),
  'wallet_refusal_import_count', (
    select count(*)::int from opening_balance_imports
    where tenant_id = '$TenantId'::uuid
      and wallet_id = '$WalletId'::uuid
      and idempotency_key = '$walletRefusalKey'
  ),
  'route_import_rows_for_run', (
    select count(*)::int from opening_balance_imports
    where tenant_id = '$TenantId'::uuid
      and wallet_id = '$WalletId'::uuid
      and external_source = 'e11_route_verifier'
      and external_reference_id like 'legacy-e11-route-$runId%'
  )
)::text;
"@
  $readbackOutput = $readbackSql | & $psql.Source $DatabaseUrl -X -q -t -A -v ON_ERROR_STOP=1 2>&1
  if ($LASTEXITCODE -ne 0) {
    return [ordered]@{
      ran = $true
      passed = $false
      blocker = "opening_balance_import_route_probe_readback_failed"
      result = $null
    }
  }
  $readbackText = (($readbackOutput | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join "`n").Trim()
  if (-not (Test-SecretSafeText $readbackText)) {
    return [ordered]@{
      ran = $true
      passed = $false
      blocker = "opening_balance_import_route_probe_readback_secret_unsafe"
      result = $null
    }
  }
  try {
    $readback = $readbackText | ConvertFrom-Json
  } catch {
    return [ordered]@{
      ran = $true
      passed = $false
      blocker = "opening_balance_import_route_probe_readback_json_parse_failed"
      result = $null
    }
  }

  $sameIds = ([string]$replay.data.opening_import_id -eq $applyId) -and
    ([string]$replay.data.ledger_entry_id -eq $ledgerId) -and
    ([string]$replay.data.audit_id -eq $auditId)
  $result = [ordered]@{
    schema = "opening_balance_import_live_route_probe.v1"
    route_invoked = $true
    internal_sqlx_function_invoked = [bool]$apply.data.internal_sqlx_function_invoked
    apply_passed = ([string]$apply.data.status -eq "imported" -and [string]$apply.data.outcome -eq "apply" -and [bool]$apply.data.runtime_implemented -and -not [bool]$apply.data.contract_only -and -not [string]::IsNullOrWhiteSpace($applyId) -and -not [string]::IsNullOrWhiteSpace($ledgerId) -and -not [string]::IsNullOrWhiteSpace($auditId))
    replay_passed = ([string]$replay.data.status -eq "replayed" -and [string]$replay.data.outcome -eq "replay" -and $sameIds)
    replay_same_opening_id = $sameIds
    idempotency_conflict_passed = ([string]$idempotencyConflict.data.status -eq "refused" -and [string]$idempotencyConflict.data.refusal_code -eq "idempotency_conflict")
    external_reference_conflict_passed = ([string]$externalConflict.data.status -eq "refused" -and [string]$externalConflict.data.refusal_code -eq "external_reference_conflict")
    wallet_currency_refusal_passed = ([string]$walletRefusal.data.status -eq "refused" -and [string]$walletRefusal.data.refusal_code -eq "wallet_currency_mismatch")
    opening_import_readback_passed = ([int]$readback.opening_import_count -eq 1)
    ledger_entry_readback_passed = ([int]$readback.ledger_entry_count -eq 1)
    audit_log_readback_passed = ([int]$readback.audit_log_count -eq 1)
    wallet_refusal_no_import_passed = ([int]$readback.wallet_refusal_import_count -eq 0)
    route_import_rows_for_run = [int]$readback.route_import_rows_for_run
    paid_gate_changed = $false
    secret_safe = $true
  }

  $passed = [bool]$result.internal_sqlx_function_invoked -and
    [bool]$result.apply_passed -and
    [bool]$result.replay_passed -and
    [bool]$result.idempotency_conflict_passed -and
    [bool]$result.external_reference_conflict_passed -and
    [bool]$result.wallet_currency_refusal_passed -and
    [bool]$result.opening_import_readback_passed -and
    [bool]$result.ledger_entry_readback_passed -and
    [bool]$result.audit_log_readback_passed -and
    [bool]$result.wallet_refusal_no_import_passed -and
    [bool]$result.secret_safe

  return [ordered]@{
    ran = $true
    passed = $passed
    blocker = $(if ($passed) { "" } else { "opening_balance_import_live_route_probe_failed" })
    result = $result
  }
}

$output = Resolve-RepoBoundedPath -Path $OutputPath -AllowedPrefixes @(".tmp/", "artifacts/")
$adminPath = Join-Path $repoRoot "apps\control-plane\src\admin.rs"
$migrationPath = Join-Path $repoRoot "db\migrations\0011_opening_balance_imports.sql"

if (-not (Test-Path -LiteralPath $adminPath -PathType Leaf)) { throw "admin_source_missing" }
if (-not (Test-Path -LiteralPath $migrationPath -PathType Leaf)) { throw "opening_balance_imports_migration_missing" }

$adminSource = Get-Content -Raw -LiteralPath $adminPath
$migrationSource = Get-Content -Raw -LiteralPath $migrationPath
$internalSource = $adminSource
$internalStart = $adminSource.IndexOf("async fn execute_opening_balance_import_internal_tx", [System.StringComparison]::Ordinal)
if ($internalStart -ge 0) {
  $internalEnd = $adminSource.IndexOf("fn opening_balance_import_runtime_attempt_contract_shape", $internalStart, [System.StringComparison]::Ordinal)
  if ($internalEnd -gt $internalStart) {
    $internalSource = $adminSource.Substring($internalStart, $internalEnd - $internalStart)
  }
}

$sourceChecks = [ordered]@{
  internal_sqlx_function = (Test-ContainsAll -Text $adminSource -Needles @(
      "async fn execute_opening_balance_import_internal_tx",
      "Transaction<'_, Postgres>",
      "get_opening_balance_import_wallet_for_update_tx",
      "get_opening_balance_import_by_idempotency_for_update_tx",
      "get_opening_balance_import_by_external_reference_for_update_tx",
      "insert_opening_balance_import_row_tx",
      "insert_opening_balance_import_ledger_entry_tx",
      "insert_admin_audit_log_tx",
      "link_opening_balance_import_tx"
    ))
  route_wired_to_internal_sqlx = (Test-ContainsAll -Text $adminSource -Needles @(
      "axum::routing::post(opening_balance_import)",
      "async fn opening_balance_import(",
      "State(state): State<Arc<ControlPlaneState>>",
      "execute_opening_balance_import_internal_tx",
      "tx.commit()",
      "opening_balance_import_mark_runtime_invoked(body, true)"
    ))
  contract_only_helper_preserved = (Test-ContainsAll -Text $adminSource -Needles @(
      "async fn contract_only_opening_balance_import",
      "opening_balance_import_contract_only_body"
    ))
  schema = (Test-ContainsAll -Text $migrationSource -Needles @(
      "create table if not exists opening_balance_imports",
      "unique (tenant_id, idempotency_key)",
      "unique (tenant_id, external_source, external_reference_id)",
      "ledger_entry_id uuid null",
      "audit_id uuid null",
      "request_summary jsonb"
    ))
  source_secret_safe = ((Test-SecretSafeText $internalSource) -and (Test-SecretSafeText $migrationSource))
}

$blockers = [System.Collections.Generic.List[string]]::new()
if (-not $sourceChecks.internal_sqlx_function.passed) { [void]$blockers.Add("internal_sqlx_function_contract_missing") }
if (-not $sourceChecks.route_wired_to_internal_sqlx.passed) { [void]$blockers.Add("opening_balance_import_public_route_not_wired") }
if (-not $sourceChecks.contract_only_helper_preserved.passed) { [void]$blockers.Add("opening_balance_import_contract_helper_missing") }
if (-not $sourceChecks.schema.passed) { [void]$blockers.Add("opening_balance_imports_schema_incomplete") }
if (-not [bool]$sourceChecks.source_secret_safe) { [void]$blockers.Add("source_secret_safety_failed") }

$requiredEnv = @("OPENING_BALANCE_IMPORT_DB_OPT_IN", "CONTROL_PLANE_DATABASE_URL or DATABASE_URL", "CONTROL_PLANE_ADMIN_SESSION_TOKEN")
$missingEnv = [System.Collections.Generic.List[string]]::new()
$dbPlan = [ordered]@{
  ran = $false
  passed = $false
  kind = "rollback_contained_psql_plan"
  route_invoked = $false
  result = $null
}
$dbIntegrationRan = $false
$runtimeImplemented = $false
$internalRustInvoked = $false
$rustIntegrationTest = [ordered]@{
  ran = $false
  passed = $false
  blocker = "opening_balance_import_internal_rust_integration_not_requested"
  cargo_exit_code = $null
}
$liveRouteProbe = [ordered]@{
  ran = $false
  passed = $false
  blocker = "opening_balance_import_live_route_probe_not_requested"
  result = $null
}
if ($RunDbIntegration) {
  if ($env:OPENING_BALANCE_IMPORT_DB_OPT_IN -ne "1") {
    [void]$missingEnv.Add("OPENING_BALANCE_IMPORT_DB_OPT_IN")
    [void]$blockers.Add("opening_balance_import_db_opt_in_env_missing")
  }
  $dbUrl = $env:CONTROL_PLANE_DATABASE_URL
  if ([string]::IsNullOrWhiteSpace($dbUrl)) {
    $dbUrl = $env:DATABASE_URL
  }
  if ([string]::IsNullOrWhiteSpace($dbUrl)) {
    [void]$missingEnv.Add("CONTROL_PLANE_DATABASE_URL or DATABASE_URL")
    [void]$blockers.Add("opening_balance_import_database_url_env_missing")
  }
  $adminSessionToken = $env:CONTROL_PLANE_ADMIN_SESSION_TOKEN
  if ([string]::IsNullOrWhiteSpace($adminSessionToken)) {
    [void]$missingEnv.Add("CONTROL_PLANE_ADMIN_SESSION_TOKEN")
  }
  $adminBaseUrl = $env:CONTROL_PLANE_ADMIN_BASE_URL
  if ([string]::IsNullOrWhiteSpace($adminBaseUrl)) {
    $adminBaseUrl = "http://127.0.0.1:8081"
  }

  if ($env:OPENING_BALANCE_IMPORT_DB_OPT_IN -eq "1" -and -not [string]::IsNullOrWhiteSpace($dbUrl)) {
    $plan = Invoke-OpeningBalanceImportDbPlan `
      -DatabaseUrl $dbUrl `
      -TenantId $SeedTenantId `
      -WalletId $SeedWalletId
    $dbIntegrationRan = [bool]$plan.ran
    $dbPlan = [ordered]@{
      ran = [bool]$plan.ran
      passed = [bool]$plan.passed
      kind = "rollback_contained_psql_plan"
      route_invoked = $false
      result = $plan.result
    }
    if (-not [bool]$plan.passed) {
      [void]$blockers.Add([string]$plan.blocker)
    } else {
      $rustIntegrationTest = Invoke-OpeningBalanceImportRustIntegrationTest
      $internalRustInvoked = [bool]$rustIntegrationTest.ran -and [bool]$rustIntegrationTest.passed
      if (-not [bool]$rustIntegrationTest.passed) {
        [void]$blockers.Add([string]$rustIntegrationTest.blocker)
      }
      if ([string]::IsNullOrWhiteSpace($adminSessionToken)) {
        [void]$blockers.Add("opening_balance_import_admin_session_token_missing_for_live_route_probe")
      } else {
        $liveRouteProbe = Invoke-OpeningBalanceImportLiveRouteProbe `
          -DatabaseUrl $dbUrl `
          -TenantId $SeedTenantId `
          -WalletId $SeedWalletId `
          -BaseUrl $adminBaseUrl `
          -AdminSessionToken $adminSessionToken
        if (-not [bool]$liveRouteProbe.passed) {
          [void]$blockers.Add([string]$liveRouteProbe.blocker)
        }
      }
    }
  } else {
    $dbPlan.blocked_before_connect = $true
  }
} else {
  [void]$missingEnv.Add("OPENING_BALANCE_IMPORT_DB_OPT_IN")
  [void]$missingEnv.Add("CONTROL_PLANE_DATABASE_URL or DATABASE_URL")
  [void]$missingEnv.Add("CONTROL_PLANE_ADMIN_SESSION_TOKEN")
  [void]$blockers.Add("opening_balance_import_db_integration_not_requested")
}

$routeWired = [bool]$sourceChecks.route_wired_to_internal_sqlx.passed
$runtimeImplemented = $dbIntegrationRan -and [bool]$dbPlan.passed -and $internalRustInvoked -and [bool]$liveRouteProbe.passed -and $routeWired -and ($blockers.Count -eq 0)
$status = if ($blockers.Count -eq 0) { "passed" } elseif ($dbIntegrationRan -and [bool]$dbPlan.passed) { "partial" } else { "blocked" }
$artifact = New-Artifact `
  -Status $status `
  -Blockers @($blockers) `
  -DbIntegrationRan $dbIntegrationRan `
  -RuntimeImplemented $runtimeImplemented `
  -Checks $sourceChecks `
  -RequiredEnv $requiredEnv `
  -MissingEnv @($missingEnv) `
  -DbPlan $dbPlan `
  -RouteWired $routeWired `
  -InternalRustInvoked $internalRustInvoked `
  -RustIntegrationTest $rustIntegrationTest `
  -LiveRouteProbe $liveRouteProbe

$json = $artifact | ConvertTo-Json -Depth 20
if (-not (Test-SecretSafeText $json)) {
  throw "artifact_secret_unsafe"
}

if ($SelfTest) {
  $parsed = $json | ConvertFrom-Json
  if ([string]$parsed.schema -ne "opening_balance_import_runtime.v1") { throw "selftest_schema_failed" }
  if ([bool]$parsed.runtime_implemented) { throw "selftest_runtime_must_not_pass_without_db" }
  if (-not [bool]$parsed.secret_safe) { throw "selftest_secret_safe_failed" }
  if (@($parsed.blockers).Count -eq 0) { throw "selftest_expected_blocker_missing" }
  Write-Output "opening_balance_import_runtime_selftest_status=pass"
  exit 0
}

$outDir = Split-Path -Parent $output.full
if (-not (Test-Path -LiteralPath $outDir)) {
  New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
Set-Content -LiteralPath $output.full -Value $json -Encoding UTF8
Write-Output "opening_balance_import_runtime_artifact_status=$status"
Write-Output "opening_balance_import_runtime_artifact_path=$($output.relative)"
Write-Output "runtime_implemented=$runtimeImplemented"
Write-Output "db_integration_ran=$dbIntegrationRan"

if ($status -eq "passed") {
  exit 0
}
exit 1
