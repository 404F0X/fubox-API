param(
  [string]$GatewayBaseUrl = "http://127.0.0.1:8080",
  [string]$GatewayAuthToken = "dev_test_key_123456789",
  [string]$GatewayProfileRef = "",
  [string]$ComposeFile = "deploy/docker-compose/docker-compose.yml",
  [int]$TimeoutSeconds = 20,
  [int]$DbPollSeconds = 12,
  [int]$LockHoldSeconds = 4,
  [int]$LockWarmupMilliseconds = 1000,
  [switch]$DryRun,
  [switch]$PreflightOnly,
  [switch]$SkipComposePs
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$fixturePath = Join-Path $repoRoot "tests\fixtures\gateway\rate_limit_reservation_live_smoke.json"
$script:Fixture = $null
$script:Failures = @()
$script:OriginalProviderKeyStates = @()
$script:ProviderKeyStateCaptured = $false
$script:SmokeSuffix = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$script:PerformanceEvidenceReportWritten = $false

if ($env:GATEWAY_BASE_URL) { $GatewayBaseUrl = $env:GATEWAY_BASE_URL }
if ($env:GATEWAY_AUTH_TOKEN) { $GatewayAuthToken = $env:GATEWAY_AUTH_TOKEN }
if ($env:GATEWAY_PROFILE_REF) { $GatewayProfileRef = $env:GATEWAY_PROFILE_REF }
if ($env:GATEWAY_AI_PROFILE) { $GatewayProfileRef = $env:GATEWAY_AI_PROFILE }
if ($env:COMPOSE_FILE) { $ComposeFile = $env:COMPOSE_FILE }
if ($env:GATEWAY_RATE_LIMIT_RESERVATION_SMOKE_DRY_RUN -eq "1") { $DryRun = $true }
if ($env:GATEWAY_RATE_LIMIT_RESERVATION_SMOKE_SKIP_COMPOSE_PS -eq "1") { $SkipComposePs = $true }

Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Security

function Redact-SecretLikeString {
  param([AllowNull()][string]$Text)

  if ($null -eq $Text) {
    return ""
  }

  $redacted = $Text
  if (-not [string]::IsNullOrWhiteSpace($GatewayAuthToken)) {
    $redacted = $redacted.Replace($GatewayAuthToken, "[REDACTED]")
  }
  $redacted = $redacted -replace '(?i)(authorization\s*[:=]\s*bearer\s+)[^\s";,}]+', '${1}[REDACTED]'
  $redacted = $redacted -replace '(?i)(Bearer\s+)[A-Za-z0-9._~+/\-]+=*', '${1}[REDACTED]'
  $redacted = $redacted -replace 'dev_test_key_[A-Za-z0-9._~+\-/=]+', '[REDACTED]'
  $redacted = $redacted -replace 'sk-[A-Za-z0-9._~+\-/=]+', '[REDACTED]'
  return $redacted
}

function Write-SafeHost {
  param([AllowNull()][string]$Text)

  Write-Host (Redact-SecretLikeString $Text)
}

function Add-Failure {
  param([Parameter(Mandatory = $true)][string]$Message)

  $safe = Redact-SecretLikeString $Message
  $script:Failures += $safe
  Write-SafeHost $safe
}

function Check {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][scriptblock]$Action
  )

  try {
    & $Action
    Write-SafeHost "[OK] $Name"
  } catch {
    Add-Failure "[FAIL] $Name - $($_.Exception.Message)"
  }
}

function Exit-WithFailuresIfAny {
  if ($script:Failures.Count -eq 0) {
    return
  }

  if ($script:Fixture -and -not $script:PerformanceEvidenceReportWritten) {
    Write-PerformanceEvidenceReport -Status "blocked" -UnavailableReason "preflight_or_contract_blocked"
  }

  Write-SafeHost ""
  Write-SafeHost "Gateway rate-limit reservation smoke failed:"
  foreach ($failure in $script:Failures) {
    Write-SafeHost $failure
  }
  exit 1
}

function ConvertFrom-JsonArray {
  param([AllowNull()][string]$Json)

  if ([string]::IsNullOrWhiteSpace($Json)) {
    return @()
  }

  $parsed = ConvertFrom-Json -InputObject $Json
  if ($null -eq $parsed) {
    return @()
  }
  if ($parsed -is [System.Array]) {
    return $parsed
  }
  return @($parsed)
}

function Read-Fixture {
  if (-not (Test-Path $fixturePath)) {
    throw "missing tests\fixtures\gateway\rate_limit_reservation_live_smoke.json"
  }

  return Get-Content -Raw $fixturePath | ConvertFrom-Json
}

function Escape-SqlLiteral {
  param([Parameter(Mandatory = $true)][string]$Value)

  return $Value.Replace("'", "''")
}

function Join-Url {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$Path
  )

  return $BaseUrl.TrimEnd("/") + $Path
}

function ConvertTo-RequestJson {
  param([Parameter(Mandatory = $true)]$Body)

  return ($Body | ConvertTo-Json -Depth 16 -Compress)
}

function Get-Sha256Hex {
  param([Parameter(Mandatory = $true)][string]$Text)

  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function New-ChatBody {
  param(
    [Parameter(Mandatory = $true)][string]$Model,
    [Parameter(Mandatory = $true)][string]$Content
  )

  return [ordered]@{
    model = $Model
    messages = @(@{ role = "user"; content = $Content })
    stream = $false
  }
}

function Invoke-GatewayRequest {
  param(
    [Parameter(Mandatory = $true)][string]$JsonBody,
    [Parameter(Mandatory = $true)][hashtable]$Headers,
    [int]$TimeoutSec = $TimeoutSeconds
  )

  $client = New-Object System.Net.Http.HttpClient
  $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
  $request = New-Object System.Net.Http.HttpRequestMessage -ArgumentList (New-Object System.Net.Http.HttpMethod -ArgumentList "POST"), (Join-Url $GatewayBaseUrl "/v1/chat/completions")

  foreach ($key in $Headers.Keys) {
    [void]$request.Headers.TryAddWithoutValidation($key, [string]$Headers[$key])
  }

  $content = New-Object System.Net.Http.StringContent -ArgumentList $JsonBody
  $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/json")
  $request.Content = $content

  $response = $null
  try {
    $response = $client.SendAsync($request).GetAwaiter().GetResult()
    return [PSCustomObject]@{
      StatusCode = [int]$response.StatusCode
      Content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    }
  } finally {
    if ($response) { $response.Dispose() }
    $request.Dispose()
    $client.Dispose()
  }
}

function Invoke-ComposePsql {
  param([Parameter(Mandatory = $true)][string]$Sql)

  Push-Location $repoRoot
  try {
    $output = Invoke-Docker compose -f $ComposeFile exec -T postgres psql `
      -U ai_gateway `
      -d ai_gateway `
      -tA `
      -v ON_ERROR_STOP=1 `
      -c $Sql

    if ($LASTEXITCODE -ne 0) {
      throw "[BLOCKED] psql failed with exit code $LASTEXITCODE"
    }

    return (($output | Out-String).Trim())
  } finally {
    Pop-Location
  }
}

function Assert-Status {
  param(
    [Parameter(Mandatory = $true)]$Response,
    [Parameter(Mandatory = $true)][int]$Expected
  )

  if ([int]$Response.StatusCode -ne $Expected) {
    throw "expected HTTP $Expected, got HTTP $($Response.StatusCode): $($Response.Content)"
  }
}

function Assert-Contains {
  param(
    [Parameter(Mandatory = $true)][string]$Content,
    [Parameter(Mandatory = $true)][string]$Needle,
    [Parameter(Mandatory = $true)][string]$Context
  )

  if (-not $Content.Contains($Needle)) {
    throw "$Context does not contain '$Needle'"
  }
}

function Assert-NoSecretLeak {
  param(
    [AllowNull()][string]$Content,
    [Parameter(Mandatory = $true)][string]$Label
  )

  $lower = ([string]$Content).ToLowerInvariant()
  foreach ($marker in @($script:Fixture.log_safety.forbidden_markers)) {
    $needle = [string]$marker
    if ([string]::IsNullOrWhiteSpace($needle)) {
      continue
    }
    if ($lower.Contains($needle.ToLowerInvariant())) {
      throw "$Label leaked forbidden marker '$needle'"
    }
  }
}

function New-GatewayHeaders {
  param([string]$ProfileRef = "")

  $headers = @{ Authorization = "Bearer $GatewayAuthToken" }
  if (-not [string]::IsNullOrWhiteSpace($ProfileRef)) {
    $headers["x-ai-profile"] = $ProfileRef.Trim()
  }
  return $headers
}

function Get-SmokeMode {
  if ($DryRun) {
    return "dry-run"
  }
  if ($PreflightOnly) {
    return "preflight"
  }
  return "live"
}

function New-SecretSafeCommandSummary {
  return [ordered]@{
    script = "scripts/verify_gateway_rate_limit_reservation_smoke.ps1"
    mode = Get-SmokeMode
    dry_run = [bool]$DryRun
    preflight_only = [bool]$PreflightOnly
    live_requests_enabled = [bool](-not $DryRun -and -not $PreflightOnly)
    gateway_base_url_configured = [bool](-not [string]::IsNullOrWhiteSpace($GatewayBaseUrl))
    gateway_auth_token_configured = [bool](-not [string]::IsNullOrWhiteSpace($GatewayAuthToken))
    gateway_profile_ref_configured = [bool](-not [string]::IsNullOrWhiteSpace($GatewayProfileRef))
    compose_file_configured = [bool](-not [string]::IsNullOrWhiteSpace($ComposeFile))
    skip_compose_ps = [bool]$SkipComposePs
    timeout_seconds = [int]$TimeoutSeconds
    db_poll_seconds = [int]$DbPollSeconds
    lock_hold_seconds = [int]$LockHoldSeconds
    lock_warmup_milliseconds = [int]$LockWarmupMilliseconds
    raw_values_in_output = $false
  }
}

function New-PerformanceUnavailableMarker {
  param(
    [Parameter(Mandatory = $true)][string]$Reason
  )

  return [ordered]@{
    available = $false
    reason = $Reason
  }
}

function New-PerformanceEvidenceReport {
  param(
    [Parameter(Mandatory = $true)][string]$Status,
    [Parameter(Mandatory = $true)][string]$UnavailableReason
  )

  $contract = $script:Fixture.performance_evidence_contract
  $schema = "gateway_rate_limit_reservation_performance_evidence_v1"
  if ($contract -and -not [string]::IsNullOrWhiteSpace([string]$contract.schema)) {
    $schema = [string]$contract.schema
  }

  $expectedAcquireCount = 3
  $expectedReleaseCount = 1
  $expectedNotAppliedCount = 1
  $expectedFallbackCount = 1
  if ($contract) {
    if ($contract.expected_minimum_counts.acquire -ne $null) { $expectedAcquireCount = [int]$contract.expected_minimum_counts.acquire }
    if ($contract.expected_minimum_counts.release -ne $null) { $expectedReleaseCount = [int]$contract.expected_minimum_counts.release }
    if ($contract.expected_minimum_counts.not_applied -ne $null) { $expectedNotAppliedCount = [int]$contract.expected_minimum_counts.not_applied }
    if ($contract.expected_minimum_counts.fallback -ne $null) { $expectedFallbackCount = [int]$contract.expected_minimum_counts.fallback }
  }

  $unavailable = New-PerformanceUnavailableMarker -Reason $UnavailableReason
  $liveRequestsSent = [bool](-not $DryRun -and -not $PreflightOnly -and $Status.StartsWith("live_"))
  $closureEligible = [bool]($Status -eq "live_completed" -and $UnavailableReason -eq "live_observed")
  return [ordered]@{
    schema = $schema
    mode = Get-SmokeMode
    status = $Status
    live_requests_sent = $liveRequestsSent
    closure_eligible = $closureEligible
    bounded_scope = [ordered]@{
      provider_key_scope = "fixture_bounded_provider_key_ids"
      request_log_query_limit = 10
      max_affected_rows_per_acquire = [int]$script:Fixture.postgres_scope.max_affected_rows_per_acquire
      max_live_cases = 3
    }
    performance = [ordered]@{
      concurrency = [ordered]@{
        expected_contender_jobs = 1
        lock_hold_seconds = [int]$LockHoldSeconds
        lock_warmup_milliseconds = [int]$LockWarmupMilliseconds
        observed_contender_jobs = $null
        unavailable = $unavailable
      }
      latency_or_ttft = [ordered]@{
        gateway_latency_ms = $null
        ttft_ms = $null
        unavailable = $unavailable
      }
      not_applied_or_fallback_rate = [ordered]@{
        expected_not_applied_count_min = $expectedNotAppliedCount
        expected_fallback_count_min = $expectedFallbackCount
        observed_not_applied_count = $null
        observed_fallback_count = $null
        observed_rate = $null
        unavailable = $unavailable
      }
      reservation_counts = [ordered]@{
        expected_acquire_count_min = $expectedAcquireCount
        expected_release_count_min = $expectedReleaseCount
        observed_acquire_count = $null
        observed_release_count = $null
        unavailable = $unavailable
      }
    }
    secret_safe_command_summary = New-SecretSafeCommandSummary
    blockers = @($script:Failures | ForEach-Object { Redact-SecretLikeString ([string]$_) })
    secret_safety = [ordered]@{
      auth_material_in_output = $false
      provider_secret_in_output = $false
      request_material_in_output = $false
      endpoint_material_in_output = $false
      window_state_material_in_output = $false
    }
  }
}

function Assert-PerformanceEvidenceSecretSafe {
  param([Parameter(Mandatory = $true)]$Report)

  $text = ($Report | ConvertTo-Json -Depth 32 -Compress)
  Assert-NoSecretLeak -Content $text -Label "rate-limit performance evidence"
}

function Write-PerformanceEvidenceReport {
  param(
    [Parameter(Mandatory = $true)][string]$Status,
    [Parameter(Mandatory = $true)][string]$UnavailableReason
  )

  if ($script:PerformanceEvidenceReportWritten) {
    return
  }

  $report = New-PerformanceEvidenceReport -Status $Status -UnavailableReason $UnavailableReason
  Assert-PerformanceEvidenceSecretSafe $report
  $script:PerformanceEvidenceReportWritten = $true
  Write-SafeHost ""
  Write-SafeHost "Gateway rate-limit reservation performance evidence:"
  Write-SafeHost ($report | ConvertTo-Json -Depth 32 -Compress)
}

function ProviderKeyIdListSql {
  param([Parameter(Mandatory = $true)][object[]]$ProviderKeyIds)

  $parts = @()
  foreach ($id in @($ProviderKeyIds)) {
    $parts += "'" + (Escape-SqlLiteral ([string]$id)) + "'::uuid"
  }
  return ($parts -join ", ")
}

function NullableIntSql {
  param([AllowNull()]$Value)

  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
    return "null"
  }
  return [string][int]$Value
}

function RateLimitStateJson {
  param(
    [Parameter(Mandatory = $true)][int]$RpmUsed,
    [Parameter(Mandatory = $true)][int]$TpmUsed,
    [Parameter(Mandatory = $true)][int]$ConcurrencyUsed
  )

  return '{"rpm":{"used":' + $RpmUsed + '},"tpm":{"used":' + $TpmUsed + '},"concurrency":{"used":' + $ConcurrencyUsed + '}}'
}

function Set-ProviderKeyRateLimitWindow {
  param(
    [Parameter(Mandatory = $true)][object[]]$ProviderKeyIds,
    [int]$RpmLimit = 1000,
    [int]$TpmLimit = 100000,
    [int]$ConcurrencyLimit = 10,
    [int]$RpmUsed = 0,
    [int]$TpmUsed = 0,
    [int]$ConcurrencyUsed = 0
  )

  $tenantId = Escape-SqlLiteral ([string]$script:Fixture.postgres_scope.tenant_id)
  $idsSql = ProviderKeyIdListSql $ProviderKeyIds
  $state = Escape-SqlLiteral (RateLimitStateJson -RpmUsed $RpmUsed -TpmUsed $TpmUsed -ConcurrencyUsed $ConcurrencyUsed)
  $sql = @"
update provider_keys
   set rpm_limit = $RpmLimit,
       tpm_limit = $TpmLimit,
       concurrency_limit = $ConcurrencyLimit,
       current_window_state = '$state'::jsonb,
       status = 'enabled',
       cooldown_until = null,
       deleted_at = null,
       updated_at = now()
 where tenant_id = '$tenantId'
   and id in ($idsSql);
"@
  [void](Invoke-ComposePsql $sql)
}

function Get-ProviderKeyStateRows {
  param([Parameter(Mandatory = $true)][object[]]$ProviderKeyIds)

  $tenantId = Escape-SqlLiteral ([string]$script:Fixture.postgres_scope.tenant_id)
  $idsSql = ProviderKeyIdListSql $ProviderKeyIds
  $sql = @"
select coalesce(jsonb_agg(to_jsonb(t) order by provider_key_id), '[]'::jsonb)::text
from (
  select
    id::text as provider_key_id,
    rpm_limit,
    tpm_limit,
    concurrency_limit,
    current_window_state
  from provider_keys
  where tenant_id = '$tenantId'
    and id in ($idsSql)
) t;
"@
  return ConvertFrom-JsonArray (Invoke-ComposePsql $sql)
}

function Capture-OriginalProviderKeyStates {
  $ids = @($script:Fixture.postgres_scope.bounded_provider_key_ids)
  $script:OriginalProviderKeyStates = @(Get-ProviderKeyStateRows $ids)
  if ($script:OriginalProviderKeyStates.Count -ne $ids.Count) {
    throw "expected $($ids.Count) provider key rows for restore, found $($script:OriginalProviderKeyStates.Count)"
  }
  $script:ProviderKeyStateCaptured = $true
}

function Restore-OriginalProviderKeyStates {
  if (-not $script:ProviderKeyStateCaptured) {
    return
  }

  foreach ($row in @($script:OriginalProviderKeyStates)) {
    $tenantId = Escape-SqlLiteral ([string]$script:Fixture.postgres_scope.tenant_id)
    $providerKeyId = Escape-SqlLiteral ([string]$row.provider_key_id)
    $rpm = NullableIntSql $row.rpm_limit
    $tpm = NullableIntSql $row.tpm_limit
    $concurrency = NullableIntSql $row.concurrency_limit
    $stateJson = Escape-SqlLiteral (($row.current_window_state | ConvertTo-Json -Depth 16 -Compress))
    $sql = @"
update provider_keys
   set rpm_limit = $rpm,
       tpm_limit = $tpm,
       concurrency_limit = $concurrency,
       current_window_state = '$stateJson'::jsonb,
       updated_at = now()
 where tenant_id = '$tenantId'
   and id = '$providerKeyId';
"@
    [void](Invoke-ComposePsql $sql)
  }
}

function Get-ProviderKeyCounterRow {
  param([Parameter(Mandatory = $true)][string]$ProviderKeyId)

  $tenantId = Escape-SqlLiteral ([string]$script:Fixture.postgres_scope.tenant_id)
  $providerKeyId = Escape-SqlLiteral $ProviderKeyId
  $sql = @"
select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb)::text
from (
  select
    id::text as provider_key_id,
    rpm_limit,
    tpm_limit,
    concurrency_limit,
    current_window_state #>> '{rpm,used}' as rpm_used,
    current_window_state #>> '{tpm,used}' as tpm_used,
    current_window_state #>> '{concurrency,used}' as concurrency_used
  from provider_keys
  where tenant_id = '$tenantId'
    and id = '$providerKeyId'
  limit 1
) t;
"@
  $rows = @(ConvertFrom-JsonArray (Invoke-ComposePsql $sql))
  if ($rows.Count -ne 1) {
    throw "provider key '$ProviderKeyId' was not found"
  }
  return $rows[0]
}

function Assert-ProviderKeyCounters {
  param(
    [Parameter(Mandatory = $true)][string]$ProviderKeyId,
    [Parameter(Mandatory = $true)][int]$Rpm,
    [Parameter(Mandatory = $true)][int]$Tpm,
    [Parameter(Mandatory = $true)][int]$Concurrency
  )

  $row = Get-ProviderKeyCounterRow $ProviderKeyId
  if ([int]$row.rpm_used -ne $Rpm) {
    throw "provider key $ProviderKeyId rpm used expected $Rpm, got '$($row.rpm_used)'"
  }
  if ([int]$row.tpm_used -ne $Tpm) {
    throw "provider key $ProviderKeyId tpm used expected $Tpm, got '$($row.tpm_used)'"
  }
  if ([int]$row.concurrency_used -ne $Concurrency) {
    throw "provider key $ProviderKeyId concurrency used expected $Concurrency, got '$($row.concurrency_used)'"
  }
}

function Get-RequestLogRowsByHash {
  param([Parameter(Mandatory = $true)][string]$RequestHash)

  $hash = Escape-SqlLiteral $RequestHash
  $sql = @"
select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb)::text
from (
  select
    rl.id::text as request_id,
    rl.status as request_status,
    rl.http_status as request_http_status,
    rl.error_code as request_error_code,
    rl.route_decision_snapshot,
    rl.provider_key_id::text as request_provider_key_id,
    pa.id::text as attempt_id,
    pa.attempt_no,
    pa.status as attempt_status,
    pa.http_status as attempt_http_status,
    pa.error_code as attempt_error_code,
    pa.fallback_reason,
    pa.provider_key_id::text as attempt_provider_key_id,
    pa.metadata
  from request_logs rl
  left join provider_attempts pa
    on pa.tenant_id = rl.tenant_id
   and pa.request_id = rl.id
  where rl.request_body_hash = '$hash'
  order by rl.created_at desc, pa.attempt_no asc
  limit 10
) t;
"@
  return ConvertFrom-JsonArray (Invoke-ComposePsql $sql)
}

function Wait-RequestLogRowsByHash {
  param([Parameter(Mandatory = $true)][string]$RequestHash)

  $deadline = (Get-Date).AddSeconds($DbPollSeconds)
  while ((Get-Date) -lt $deadline) {
    $rows = @(Get-RequestLogRowsByHash $RequestHash)
    if ($rows.Count -gt 0) {
      return $rows
    }
    Start-Sleep -Seconds 1
  }

  throw "request_logs row with request_body_hash=$RequestHash was not observed within $DbPollSeconds seconds"
}

function Get-RateLimitEvidenceText {
  param(
    [AllowNull()][string]$ResponseContent,
    [AllowNull()]$Rows
  )

  $items = New-Object System.Collections.Generic.List[object]
  if (-not [string]::IsNullOrEmpty($ResponseContent)) {
    $items.Add($ResponseContent)
  }
  foreach ($row in @($Rows)) {
    if ($row.metadata -and $row.metadata.rate_limit_reservation) {
      $items.Add($row.metadata.rate_limit_reservation)
    }
    if ($row.route_decision_snapshot -and $row.route_decision_snapshot.rate_limit_reservation_rejection) {
      $items.Add($row.route_decision_snapshot.rate_limit_reservation_rejection)
    }
  }

  return ($items | ConvertTo-Json -Depth 32 -Compress)
}

function Assert-RateLimitEvidenceSecretSafe {
  param(
    [Parameter(Mandatory = $true)][string]$ResponseContent,
    [Parameter(Mandatory = $true)]$Rows,
    [Parameter(Mandatory = $true)][string]$Label
  )

  Assert-NoSecretLeak -Content (Get-RateLimitEvidenceText -ResponseContent $ResponseContent -Rows $Rows) -Label $Label
}

function Get-AttemptRows {
  param([Parameter(Mandatory = $true)]$Rows)

  return @($Rows | Where-Object { $_.attempt_id })
}

function Assert-DbAcquireStatus {
  param(
    [Parameter(Mandatory = $true)]$Attempt,
    [Parameter(Mandatory = $true)][string]$Expected
  )

  $actual = [string]$Attempt.metadata.rate_limit_reservation.db_execution.acquire.status
  if ($actual -ne $Expected) {
    throw "db acquire status expected '$Expected', got '$actual'"
  }
}

function Assert-DbReleaseStatus {
  param(
    [Parameter(Mandatory = $true)]$Attempt,
    [Parameter(Mandatory = $true)][string]$Expected
  )

  $actual = [string]$Attempt.metadata.rate_limit_reservation.db_execution.release.status
  if ($actual -ne $Expected) {
    throw "db release status expected '$Expected', got '$actual'"
  }
}

function Assert-LiveRouteSeedRows {
  $tenantId = Escape-SqlLiteral ([string]$script:Fixture.postgres_scope.tenant_id)
  $profile = Escape-SqlLiteral ([string]$script:Fixture.gateway.strict_profile_ref)
  $idsSql = ProviderKeyIdListSql @($script:Fixture.postgres_scope.bounded_provider_key_ids)
  $modelDefault = Escape-SqlLiteral ([string]$script:Fixture.live_cases.acquire_updates_bounded_counters.model)
  $modelFallback = Escape-SqlLiteral ([string]$script:Fixture.live_cases.fallback_releases_failed_attempt.model)

  $sql = @"
select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb)::text
from (
  select 'provider_key' as kind, id::text as id, status, deleted_at is null as active
  from provider_keys
  where tenant_id = '$tenantId' and id in ($idsSql)
  union all
  select 'model' as kind, id::text as id, status, deleted_at is null as active
  from canonical_models
  where tenant_id = '$tenantId' and model_key in ('$modelDefault', '$modelFallback')
  union all
  select 'profile' as kind, id::text as id, status, deleted_at is null as active
  from api_key_profiles
  where tenant_id = '$tenantId' and name = '$profile'
) t;
"@

  $rows = @(ConvertFrom-JsonArray (Invoke-ComposePsql $sql))
  if (@($rows | Where-Object { $_.kind -eq "provider_key" -and $_.status -eq "enabled" -and $_.active -eq $true }).Count -ne 3) {
    throw "expected all three smoke provider keys to be enabled and active"
  }
  if (@($rows | Where-Object { $_.kind -eq "model" -and $_.status -eq "active" -and $_.active -eq $true }).Count -ne 2) {
    throw "expected default and fallback smoke models to be active"
  }
  if (@($rows | Where-Object { $_.kind -eq "profile" -and $_.status -eq "active" -and $_.active -eq $true }).Count -ne 1) {
    throw "expected strict rate-limit smoke profile to be active"
  }
}

function Assert-FixtureContract {
  param([Parameter(Mandatory = $true)]$Fixture)

  if ($Fixture.scenario -ne "gateway_rate_limit_reservation_live_postgres_smoke") {
    throw "fixture scenario must be gateway_rate_limit_reservation_live_postgres_smoke"
  }
  if ($Fixture.script -ne "scripts/verify_gateway_rate_limit_reservation_smoke.ps1") {
    throw "fixture script path is not stable"
  }
  foreach ($service in @("postgres", "gateway", "mock-provider")) {
    if (@($Fixture.compose.required_services | Where-Object { $_ -eq $service }).Count -ne 1) {
      throw "fixture compose.required_services must include '$service'"
    }
  }
  if ([int]$Fixture.required_capacity.tokens_per_minute -ne 128) {
    throw "fixture required tpm must match Gateway fallback token capacity"
  }
  foreach ($id in @(
      $Fixture.live_cases.acquire_updates_bounded_counters.provider_key_id,
      $Fixture.live_cases.fallback_releases_failed_attempt.failing_provider_key_id,
      $Fixture.live_cases.fallback_releases_failed_attempt.fallback_provider_key_id
    )) {
    if (@($Fixture.postgres_scope.bounded_provider_key_ids | Where-Object { $_ -eq $id }).Count -ne 1) {
      throw "fixture postgres_scope.bounded_provider_key_ids must include $id"
    }
  }
  if ($Fixture.live_cases.concurrent_over_limit_not_applied_final_429.expected_db_acquire_status -ne "not_applied") {
    throw "concurrency case must expect DB not_applied"
  }
  if ($Fixture.live_cases.concurrent_over_limit_not_applied_final_429.expected_error_code -ne "rate_limit_exceeded") {
    throw "concurrency case must expect rate_limit_exceeded"
  }
  if ($Fixture.performance_evidence_contract.schema -ne "gateway_rate_limit_reservation_performance_evidence_v1") {
    throw "performance evidence contract schema must be stable"
  }
  if ([bool]$Fixture.performance_evidence_contract.live_default_enabled -ne $false) {
    throw "performance evidence contract must document default non-live test entry"
  }
  foreach ($field in @(
      "schema",
      "mode",
      "status",
      "bounded_scope",
      "performance",
      "secret_safe_command_summary",
      "blockers",
      "secret_safety"
    )) {
    if (@($Fixture.performance_evidence_contract.required_top_level_fields | Where-Object { $_ -eq $field }).Count -ne 1) {
      throw "performance evidence contract missing top-level field '$field'"
    }
  }
  foreach ($field in @(
      "concurrency",
      "latency_or_ttft",
      "not_applied_or_fallback_rate",
      "reservation_counts"
    )) {
    if (@($Fixture.performance_evidence_contract.required_performance_fields | Where-Object { $_ -eq $field }).Count -ne 1) {
      throw "performance evidence contract missing performance field '$field'"
    }
  }
  if ([int]$Fixture.performance_evidence_contract.bounded_scope.request_log_query_limit -ne 10) {
    throw "performance evidence contract request log query limit must remain bounded"
  }
  if ([int]$Fixture.performance_evidence_contract.bounded_scope.max_affected_rows_per_acquire -ne 1) {
    throw "performance evidence contract must preserve <=1 affected row acquire semantics"
  }
}

function Assert-ComposeServicesRunning {
  Push-Location $repoRoot
  try {
    $running = @(Invoke-Docker compose -f $ComposeFile ps --services --status running)
    if ($LASTEXITCODE -ne 0) {
      throw "[BLOCKED] docker compose ps failed with exit code $LASTEXITCODE"
    }

    foreach ($service in @($script:Fixture.compose.required_services)) {
      if ($running -notcontains $service) {
        throw "[BLOCKED] service '$service' is not running; start the local compose stack or use -DryRun"
      }
    }
  } finally {
    Pop-Location
  }
}

function Assert-ScriptStructure {
  $source = Get-Content -LiteralPath $PSCommandPath -Raw
  foreach ($needle in @(
      "Start-ProviderKeyOverLimitContender",
      "rate_limit_reservation_rejection",
      "not_applied",
      "release.status",
      "Assert-NoSecretLeak",
      "Restore-OriginalProviderKeyStates",
      "Write-PerformanceEvidenceReport",
      "gateway_rate_limit_reservation_performance_evidence_v1",
      "latency_or_ttft",
      "not_applied_or_fallback_rate",
      "secret_safe_command_summary"
    )) {
    if (-not $source.Contains($needle)) {
      throw "script source is missing smoke marker '$needle'"
    }
  }
}

function Start-ProviderKeyOverLimitContender {
  param(
    [Parameter(Mandatory = $true)][object[]]$ProviderKeyIds,
    [Parameter(Mandatory = $true)][int]$HoldSeconds
  )

  $tenantId = Escape-SqlLiteral ([string]$script:Fixture.postgres_scope.tenant_id)
  $idsSql = ProviderKeyIdListSql $ProviderKeyIds
  $state = Escape-SqlLiteral (RateLimitStateJson -RpmUsed 0 -TpmUsed 0 -ConcurrencyUsed 1)
  $sql = @"
begin;
select id
  from provider_keys
 where tenant_id = '$tenantId'
   and id in ($idsSql)
 order by id
 for update;
select pg_sleep($HoldSeconds);
update provider_keys
   set current_window_state = '$state'::jsonb,
       updated_at = now()
 where tenant_id = '$tenantId'
   and id in ($idsSql);
commit;
"@

  $docker = Get-DockerCommand
  return Start-Job -ScriptBlock {
    param($RepoRoot, $DockerCommand, $ComposeFile, $Sql)
    Set-Location $RepoRoot
    & $DockerCommand compose -f $ComposeFile exec -T postgres psql -U ai_gateway -d ai_gateway -v ON_ERROR_STOP=1 -c $Sql
    if ($LASTEXITCODE -ne 0) {
      throw "concurrent psql contender failed with exit code $LASTEXITCODE"
    }
  } -ArgumentList ([string]$repoRoot), $docker, $ComposeFile, $sql
}

function Complete-ContenderJob {
  param([Parameter(Mandatory = $true)]$Job)

  try {
    $null = Wait-Job -Job $Job -Timeout ($LockHoldSeconds + $TimeoutSeconds)
    if ($Job.State -eq "Running") {
      Stop-Job -Job $Job
      throw "concurrent provider-key contender did not finish"
    }
    $output = Receive-Job -Job $Job -ErrorAction Stop
    $text = (($output | Out-String).Trim())
    if (-not [string]::IsNullOrWhiteSpace($text)) {
      Write-SafeHost $text
    }
    if ($Job.State -ne "Completed") {
      throw "concurrent provider-key contender ended in state $($Job.State)"
    }
  } finally {
    Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-TrackedChatRequest {
  param(
    [Parameter(Mandatory = $true)][string]$Model,
    [Parameter(Mandatory = $true)][string]$Content,
    [string]$ProfileRef = "",
    [int]$TimeoutSec = $TimeoutSeconds
  )

  $body = New-ChatBody -Model $Model -Content $Content
  $json = ConvertTo-RequestJson $body
  $hash = Get-Sha256Hex $json
  $response = Invoke-GatewayRequest -JsonBody $json -Headers (New-GatewayHeaders $ProfileRef) -TimeoutSec $TimeoutSec
  return [PSCustomObject]@{
    Body = $body
    Json = $json
    Hash = $hash
    Response = $response
  }
}

function Check-AcquireUpdatesBoundedCounters {
  $case = $script:Fixture.live_cases.acquire_updates_bounded_counters
  $providerKeyId = [string]$case.provider_key_id
  Set-ProviderKeyRateLimitWindow -ProviderKeyIds @($providerKeyId) -RpmUsed 0 -TpmUsed 0 -ConcurrencyUsed 0

  $tracked = Invoke-TrackedChatRequest -Model ([string]$case.model) -Content "rate limit acquire smoke $script:SmokeSuffix"
  Assert-Status $tracked.Response ([int]$case.expected_http_status)
  Assert-Contains $tracked.Response.Content "chat.completion" "acquire update response"
  Assert-ProviderKeyCounters `
    -ProviderKeyId $providerKeyId `
    -Rpm ([int]$case.expected_used_after.rpm) `
    -Tpm ([int]$case.expected_used_after.tpm) `
    -Concurrency ([int]$case.expected_used_after.concurrency)

  $rows = @(Wait-RequestLogRowsByHash $tracked.Hash)
  $attempts = @(Get-AttemptRows $rows)
  if ($attempts.Count -lt 1) {
    throw "provider_attempts row was not recorded for acquire update"
  }
  Assert-DbAcquireStatus $attempts[0] ([string]$case.expected_db_acquire_status)
  if ([bool]$attempts[0].metadata.rate_limit_reservation.db_execution.release_attempted -ne [bool]$case.expected_release_attempted) {
    throw "completed acquire smoke should not release successful reservation"
  }
  Assert-RateLimitEvidenceSecretSafe -ResponseContent $tracked.Response.Content -Rows $rows -Label "acquire update evidence"
}

function Check-FallbackReleasesFailedAttempt {
  $case = $script:Fixture.live_cases.fallback_releases_failed_attempt
  $failedKeyId = [string]$case.failing_provider_key_id
  $fallbackKeyId = [string]$case.fallback_provider_key_id
  Set-ProviderKeyRateLimitWindow -ProviderKeyIds @($failedKeyId, $fallbackKeyId) -RpmUsed 0 -TpmUsed 0 -ConcurrencyUsed 0

  $tracked = Invoke-TrackedChatRequest `
    -Model ([string]$case.model) `
    -ProfileRef ([string]$case.profile_ref) `
    -Content "rate limit fallback release smoke $script:SmokeSuffix"
  Assert-Status $tracked.Response ([int]$case.expected_http_status)
  Assert-Contains $tracked.Response.Content "chat.completion" "fallback release response"

  $rows = @(Wait-RequestLogRowsByHash $tracked.Hash)
  $attempts = @(Get-AttemptRows $rows)
  if ($attempts.Count -lt 2) {
    throw "fallback release expected at least two provider_attempts, got $($attempts.Count)"
  }
  $failedAttempt = @($attempts | Where-Object { $_.attempt_provider_key_id -eq $failedKeyId } | Select-Object -First 1)
  $fallbackAttempt = @($attempts | Where-Object { $_.attempt_provider_key_id -eq $fallbackKeyId -and $_.attempt_status -eq "succeeded" } | Select-Object -First 1)
  if ($failedAttempt.Count -ne 1) {
    throw "failed fallback attempt for provider key $failedKeyId was not recorded"
  }
  if ($fallbackAttempt.Count -ne 1) {
    throw "successful fallback attempt for provider key $fallbackKeyId was not recorded"
  }
  if ($failedAttempt[0].fallback_reason -ne $case.expected_fallback_reason) {
    throw "fallback reason expected '$($case.expected_fallback_reason)', got '$($failedAttempt[0].fallback_reason)'"
  }
  Assert-DbAcquireStatus $failedAttempt[0] ([string]$case.expected_db_acquire_status)
  Assert-DbReleaseStatus $failedAttempt[0] ([string]$case.expected_db_release_status)
  Assert-ProviderKeyCounters `
    -ProviderKeyId $failedKeyId `
    -Rpm ([int]$case.expected_failed_key_used_after_release.rpm) `
    -Tpm ([int]$case.expected_failed_key_used_after_release.tpm) `
    -Concurrency ([int]$case.expected_failed_key_used_after_release.concurrency)
  Assert-ProviderKeyCounters -ProviderKeyId $fallbackKeyId -Rpm 1 -Tpm 128 -Concurrency 1
  Assert-RateLimitEvidenceSecretSafe -ResponseContent $tracked.Response.Content -Rows $rows -Label "fallback release evidence"
}

function Check-ConcurrentOverLimitNotAppliedFinal429 {
  $case = $script:Fixture.live_cases.concurrent_over_limit_not_applied_final_429
  $providerKeyIds = @($case.locked_provider_key_ids)
  Set-ProviderKeyRateLimitWindow -ProviderKeyIds $providerKeyIds -RpmLimit 1000 -TpmLimit 100000 -ConcurrencyLimit 1 -RpmUsed 0 -TpmUsed 0 -ConcurrencyUsed 0

  $job = Start-ProviderKeyOverLimitContender -ProviderKeyIds $providerKeyIds -HoldSeconds $LockHoldSeconds
  Start-Sleep -Milliseconds $LockWarmupMilliseconds
  try {
    $tracked = Invoke-TrackedChatRequest `
      -Model ([string]$case.model) `
      -ProfileRef ([string]$case.profile_ref) `
      -Content "rate limit concurrent not applied smoke $script:SmokeSuffix" `
      -TimeoutSec ($TimeoutSeconds + $LockHoldSeconds)
  } finally {
    Complete-ContenderJob $job
  }

  Assert-Status $tracked.Response ([int]$case.expected_http_status)
  Assert-Contains $tracked.Response.Content ([string]$case.expected_error_code) "concurrent over-limit response"

  $rows = @(Wait-RequestLogRowsByHash $tracked.Hash)
  $attempts = @(Get-AttemptRows $rows)
  if ($attempts.Count -ne 0) {
    throw "concurrent over-limit final 429 should not create provider_attempts; got $($attempts.Count)"
  }
  $requestRow = $rows[0]
  if ([int]$requestRow.request_http_status -ne [int]$case.expected_http_status) {
    throw "request log HTTP status expected $($case.expected_http_status), got '$($requestRow.request_http_status)'"
  }
  $rejection = $requestRow.route_decision_snapshot.rate_limit_reservation_rejection
  if ($rejection.schema -ne $case.expected_rejection_schema) {
    throw "rate-limit rejection snapshot schema expected '$($case.expected_rejection_schema)', got '$($rejection.schema)'"
  }
  if ([int]$rejection.skip_event_count -lt 1) {
    throw "expected at least one rate-limit reservation skip event"
  }
  $skipEvent = @($rejection.skip_events | Select-Object -First 1)[0]
  if ($skipEvent.schema -ne $case.expected_skip_schema) {
    throw "skip event schema expected '$($case.expected_skip_schema)', got '$($skipEvent.schema)'"
  }
  if ($skipEvent.rate_limit_reservation.db_execution.acquire.status -ne $case.expected_db_acquire_status) {
    throw "skip event DB acquire status expected '$($case.expected_db_acquire_status)', got '$($skipEvent.rate_limit_reservation.db_execution.acquire.status)'"
  }
  Assert-RateLimitEvidenceSecretSafe -ResponseContent $tracked.Response.Content -Rows $rows -Label "concurrent not_applied evidence"
}

Push-Location $repoRoot
try {
  Check "rate-limit reservation smoke fixture files exist" {
    foreach ($relativePath in @(
        "scripts\verify_gateway_rate_limit_reservation_smoke.ps1",
        "scripts\common.ps1",
        "tests\fixtures\gateway\rate_limit_reservation_live_smoke.json",
        "tests\fixtures\gateway\rate_limit_reservation_runtime_contract.json",
        "deploy\docker-compose\docker-compose.yml",
        "db\dev-seeds\0003_dev_smoke_seed_reconcile.sql"
      )) {
      if (-not (Test-Path (Join-Path $repoRoot $relativePath))) {
        throw "missing $relativePath"
      }
    }
  }

  Check "rate-limit reservation smoke fixture contract" {
    $script:Fixture = Read-Fixture
    Assert-FixtureContract $script:Fixture
  }

  Check "rate-limit reservation smoke script structure" {
    Assert-ScriptStructure
  }

  if ($DryRun) {
    Exit-WithFailuresIfAny
    Write-PerformanceEvidenceReport -Status "contract_only" -UnavailableReason "dry_run_no_runtime_requests"
    Write-SafeHost ""
    Write-SafeHost "Gateway rate-limit reservation smoke dry-run passed; runtime requests were not sent."
    exit 0
  }

  if ([string]::IsNullOrWhiteSpace($GatewayProfileRef)) {
    $GatewayProfileRef = [string]$script:Fixture.gateway.strict_profile_ref
  }

  if (-not $SkipComposePs) {
    Check "docker compose rate-limit reservation services are running" {
      Assert-ComposeServicesRunning
    }
  }

  Exit-WithFailuresIfAny

  Check "rate-limit reservation live seed rows are available" {
    Assert-LiveRouteSeedRows
  }

  if ($PreflightOnly) {
    Exit-WithFailuresIfAny
    Write-PerformanceEvidenceReport -Status "preflight_passed" -UnavailableReason "preflight_only_no_runtime_requests"
    Write-SafeHost ""
    Write-SafeHost "Gateway rate-limit reservation smoke preflight passed; runtime requests were not sent."
    exit 0
  }

  Check "capture provider key rate-limit windows for restore" {
    Capture-OriginalProviderKeyStates
  }

  Exit-WithFailuresIfAny

  try {
    Check "live acquire updates bounded provider-key counters" {
      Check-AcquireUpdatesBoundedCounters
    }

    Check "live provider fallback releases failed provider-key reservation" {
      Check-FallbackReleasesFailedAttempt
    }

    Check "live concurrent over-limit acquire produces not_applied fallback 429" {
      Check-ConcurrentOverLimitNotAppliedFinal429
    }
  } finally {
    Check "restore provider key rate-limit windows" {
      Restore-OriginalProviderKeyStates
    }
  }
} finally {
  Pop-Location
}

Exit-WithFailuresIfAny

Write-PerformanceEvidenceReport -Status "live_completed" -UnavailableReason "live_performance_measurement_not_collected"

Write-SafeHost ""
Write-SafeHost "Gateway rate-limit reservation live Postgres smoke passed."
