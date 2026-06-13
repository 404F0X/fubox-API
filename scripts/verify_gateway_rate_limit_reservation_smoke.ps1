param(
  [string]$GatewayBaseUrl = "http://127.0.0.1:8080",
  [string]$GatewayAuthToken = "dev_test_key_123456789",
  [string]$GatewayProfileRef = "",
  [string]$ComposeFile = "deploy/docker-compose/docker-compose.yml",
  [int]$TimeoutSeconds = 20,
  [int]$DbPollSeconds = 12,
  [int]$LockHoldSeconds = 4,
  [int]$LockWarmupMilliseconds = 1000,
  [string]$ArtifactPath = "",
  [switch]$ExplainabilitySelfTest,
  [switch]$DryRun,
  [switch]$PreflightOnly,
  [switch]$SkipComposePs
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$fixturePath = Join-Path $repoRoot "tests\fixtures\gateway\rate_limit_reservation_live_smoke.json"
$explainabilityFixturePath = Join-Path $repoRoot "tests\fixtures\observability\e8_rate_limit_explainability_handoff_contract.json"
$script:Fixture = $null
$script:Failures = @()
$script:OriginalProviderKeyStates = @()
$script:ProviderKeyStateCaptured = $false
$script:SmokeSuffix = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$script:PerformanceEvidenceReportWritten = $false
$script:MissingServices = @()
$script:ObservedAcquireCount = 0
$script:ObservedReleaseCount = 0
$script:ObservedNotAppliedCount = 0
$script:ObservedFallbackCount = 0
$script:ObservedRequestLogRows = 0
$script:ObservedProviderAttemptRows = 0
$script:ObservedGatewayLatencyMilliseconds = @()
$script:ObservedContenderJobs = 0
$script:ObservedContenderDurationMilliseconds = $null
$script:ObservedContenderStartedAt = $null
$script:ObservedRequestHashes = @()
$script:ObservedRequestIds = @()
$script:ForcedLimitProviderAttemptRows = $null
$script:ContenderReadyLockKey = 88004

if ($env:GATEWAY_BASE_URL) { $GatewayBaseUrl = $env:GATEWAY_BASE_URL }
if ($env:GATEWAY_AUTH_TOKEN) { $GatewayAuthToken = $env:GATEWAY_AUTH_TOKEN }
if ($env:GATEWAY_PROFILE_REF) { $GatewayProfileRef = $env:GATEWAY_PROFILE_REF }
if ($env:GATEWAY_AI_PROFILE) { $GatewayProfileRef = $env:GATEWAY_AI_PROFILE }
if ($env:COMPOSE_FILE) { $ComposeFile = $env:COMPOSE_FILE }
if ($env:GATEWAY_RATE_LIMIT_RESERVATION_SMOKE_ARTIFACT_PATH) { $ArtifactPath = $env:GATEWAY_RATE_LIMIT_RESERVATION_SMOKE_ARTIFACT_PATH }
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
  $scriptPath = "scripts/verify_gateway_rate_limit_reservation_smoke.ps1"
  return [ordered]@{
    script = $scriptPath
    mode = Get-SmokeMode
    dry_run = [bool]$DryRun
    preflight_only = [bool]$PreflightOnly
    live_requests_enabled = [bool](-not $DryRun -and -not $PreflightOnly)
    copyable_dry_run_command = "pwsh -File $scriptPath -DryRun"
    copyable_preflight_command = "pwsh -File $scriptPath -PreflightOnly"
    copyable_live_command = "pwsh -File $scriptPath"
    gateway_base_url_configured = [bool](-not [string]::IsNullOrWhiteSpace($GatewayBaseUrl))
    gateway_auth_token_configured = [bool](-not [string]::IsNullOrWhiteSpace($GatewayAuthToken))
    gateway_profile_ref_configured = [bool](-not [string]::IsNullOrWhiteSpace($GatewayProfileRef))
    compose_file_configured = [bool](-not [string]::IsNullOrWhiteSpace($ComposeFile))
    skip_compose_ps = [bool]$SkipComposePs
    artifact_path_configured = [bool](-not [string]::IsNullOrWhiteSpace($ArtifactPath))
    timeout_seconds = [int]$TimeoutSeconds
    db_poll_seconds = [int]$DbPollSeconds
    lock_hold_seconds = [int]$LockHoldSeconds
    lock_warmup_milliseconds = [int]$LockWarmupMilliseconds
    raw_values_in_output = $false
  }
}

function Get-RepoRelativePath {
  param([Parameter(Mandatory = $true)][string]$FullPath)

  $full = [System.IO.Path]::GetFullPath($FullPath)
  $root = ([System.IO.Path]::GetFullPath([string]$repoRoot)).TrimEnd("\", "/")
  $prefix = $root + [System.IO.Path]::DirectorySeparatorChar
  if ($full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $full.Substring($prefix.Length).Replace("\", "/")
  }
  return $full.Replace("\", "/")
}

function Resolve-SafeArtifactPath {
  if ([string]::IsNullOrWhiteSpace($ArtifactPath)) {
    return $null
  }

  $candidate = $ArtifactPath.Trim()
  $combined = if ([System.IO.Path]::IsPathRooted($candidate)) {
    $candidate
  } else {
    Join-Path $repoRoot $candidate
  }
  $full = [System.IO.Path]::GetFullPath($combined)
  $tmpRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot ".tmp"))
  $artifactsRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "artifacts"))

  $isAllowed = $full.StartsWith($tmpRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
    $full.StartsWith($artifactsRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
  if (-not $isAllowed) {
    throw "artifact path must be under .tmp or artifacts"
  }

  $relative = Get-RepoRelativePath $full
  if ($DryRun -and $relative.Equals(".tmp/launch/e8_gateway_rate_limit_launch_check.json", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "dry_run_must_not_overwrite_launch_live_rate_limit_artifact; use a sidecar path such as .tmp/launch/e8_gateway_rate_limit_launch_check.dry_run.json"
  }

  return $full
}

function Artifact-RelativePath {
  param([AllowNull()][string]$FullPath)

  if ([string]::IsNullOrWhiteSpace($FullPath)) {
    return $null
  }
  return Get-RepoRelativePath $FullPath
}

function New-RateLimitExplainabilityHandoff {
  param(
    [Parameter(Mandatory = $true)][string]$Status
  )

  $requestHashes = @($script:ObservedRequestHashes | Select-Object -Unique)
  $requestIds = @($script:ObservedRequestIds | Select-Object -Unique)
  return [ordered]@{
    schema = "gateway_rate_limit_request_trace_usage_handoff_v1"
    status = $Status
    smoke_run_id = [string]$script:SmokeSuffix
    request_trace_lookup_keys = [ordered]@{
      request_ids = $requestIds
      request_hashes = $requestHashes
      request_id_count = [int]$requestIds.Count
      request_hash_count = [int]$requestHashes.Count
      lookup_scope = "request_logs_and_provider_attempts"
      material_in_output = $false
    }
    reservation_events = [ordered]@{
      acquire_applied_count = [int]$script:ObservedAcquireCount
      release_applied_count = [int]$script:ObservedReleaseCount
      not_applied_count = [int]$script:ObservedNotAppliedCount
      fallback_count = [int]$script:ObservedFallbackCount
      provider_attempt_rows = [int]$script:ObservedProviderAttemptRows
      forced_limit_provider_attempt_rows = $script:ForcedLimitProviderAttemptRows
    }
    estimated_tpm_fallback = [ordered]@{
      estimated = $true
      trusted_numeric_source_present = $false
      evidence_field = "rate_limit_reservation.tpm_estimate.estimated"
      trusted_numeric_field = "rate_limit_reservation.tpm_estimate.trusted_numeric_source_present"
      source = "conservative_missing_tokenizer_fallback"
      paid_billing_settled = $false
    }
    admin_readback_expectations = [ordered]@{
      required_views = @("request_detail", "trace_detail", "provider_attempt_detail")
      expected_fields = @(
        "request_id",
        "request_hash",
        "route_decision_snapshot.rate_limit_reservation_rejection",
        "provider_attempts.metadata.rate_limit_reservation",
        "provider_attempts.fallback_reason"
      )
      forced_limit_expected_provider_attempt_rows = 0
      admin_ui_beta_closure_claimed = $false
    }
    usage_cost_expectations = [ordered]@{
      usage_basis = "rate_limit_reservation_metadata_and_estimated_tpm"
      cost_basis = "not_paid_billing_settlement"
      paid_billing_settled = $false
      estimated_tpm_only = $true
      acceptable_for_todo14_usage_trace = $true
    }
    secret_safe_omission = [ordered]@{
      auth_material_in_output = $false
      provider_secret_in_output = $false
      body_material_in_output = $false
      header_material_in_output = $false
      endpoint_material_in_output = $false
      window_state_material_in_output = $false
      raw_material_present = $false
    }
  }
}

function Test-RateLimitExplainabilityHandoff {
  param([Parameter(Mandatory = $true)]$Handoff)

  if ($Handoff.schema -ne "gateway_rate_limit_request_trace_usage_handoff_v1") {
    return "invalid_schema"
  }
  if (@($Handoff.request_trace_lookup_keys.request_ids).Count -lt 1) {
    return "missing_request_id"
  }
  if ([int]$Handoff.reservation_events.forced_limit_provider_attempt_rows -ne 0) {
    return "forced_limit_provider_attempt_nonzero"
  }
  if ([bool]$Handoff.estimated_tpm_fallback.estimated -ne $true) {
    return "estimated_tpm_missing"
  }
  if ([bool]$Handoff.estimated_tpm_fallback.trusted_numeric_source_present -ne $false) {
    return "trusted_numeric_misclassified"
  }
  if ([bool]$Handoff.secret_safe_omission.raw_material_present -ne $false) {
    return "raw_or_secret_marker_present"
  }
  if ([bool]$Handoff.secret_safe_omission.auth_material_in_output -ne $false) {
    return "raw_or_secret_marker_present"
  }

  $text = ($Handoff | ConvertTo-Json -Depth 32 -Compress).ToLowerInvariant()
  foreach ($marker in @("authorization", "bearer", "sk-live", "request_body", "raw prompt", "raw input", "encrypted_secret", "provider_secret")) {
    if ($text.Contains($marker)) {
      return "raw_or_secret_marker_present"
    }
  }
  return "pass"
}

function Invoke-ExplainabilitySelfTest {
  if (-not (Test-Path $explainabilityFixturePath)) {
    throw "missing tests\fixtures\observability\e8_rate_limit_explainability_handoff_contract.json"
  }

  $fixture = Get-Content -Raw $explainabilityFixturePath | ConvertFrom-Json
  if ($fixture.schema -ne "gateway_rate_limit_request_trace_usage_handoff_contract_v1") {
    throw "unexpected E8 explainability fixture schema"
  }

  foreach ($case in @($fixture.cases)) {
    $actual = Test-RateLimitExplainabilityHandoff $case.handoff
    if ($actual -ne $case.expected_result) {
      throw "E8 explainability selftest case '$($case.name)' expected '$($case.expected_result)', got '$actual'"
    }
  }

  $accepted = @($fixture.cases | Where-Object { $_.expected_result -eq "pass" } | Select-Object -First 1)[0]
  $serialized = ($accepted.handoff | ConvertTo-Json -Depth 32 -Compress).ToLowerInvariant()
  foreach ($marker in @($fixture.forbidden_output_markers)) {
    if ($serialized.Contains(([string]$marker).ToLowerInvariant())) {
      throw "E8 explainability fixture leaked forbidden marker '$marker'"
    }
  }

  Write-SafeHost "E8 rate-limit explainability handoff selftest passed."
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

  $liveRequestsSent = [bool](-not $DryRun -and -not $PreflightOnly -and $Status.StartsWith("live_"))
  $measurementsAvailable = [bool](
    $Status -eq "live_completed" `
      -and $script:ObservedGatewayLatencyMilliseconds.Count -gt 0 `
      -and $script:ObservedRequestLogRows -gt 0 `
      -and $script:ObservedProviderAttemptRows -gt 0 `
      -and $script:ObservedContenderJobs -ge 1 `
      -and $script:ObservedAcquireCount -ge $expectedAcquireCount `
      -and $script:ObservedReleaseCount -ge $expectedReleaseCount `
      -and $script:ObservedNotAppliedCount -ge $expectedNotAppliedCount `
      -and $script:ObservedFallbackCount -ge $expectedFallbackCount
  )
  $unavailableReasonForReport = $UnavailableReason
  if ($measurementsAvailable) {
    $unavailableReasonForReport = "measurements_available"
  }
  $unavailable = New-PerformanceUnavailableMarker -Reason $unavailableReasonForReport
  $availableMarker = [ordered]@{ available = $true; reason = "measurements_available" }
  $measurementMarker = if ($measurementsAvailable) { $availableMarker } else { $unavailable }
  $gatewayLatencyMs = $null
  if ($script:ObservedGatewayLatencyMilliseconds.Count -gt 0) {
    $gatewayLatencyMs = [int][Math]::Round(($script:ObservedGatewayLatencyMilliseconds | Measure-Object -Average).Average)
  }
  $notAppliedFallbackTotal = $script:ObservedNotAppliedCount + $script:ObservedFallbackCount
  $attemptTotal = [Math]::Max(1, $script:ObservedAcquireCount)
  $notAppliedFallbackRate = [double]($notAppliedFallbackTotal / $attemptTotal)
  $closureEligible = [bool]($Status -eq "live_completed" -and $measurementsAvailable)
  $safeArtifactFullPath = Resolve-SafeArtifactPath
  $safeArtifactRelativePath = Artifact-RelativePath $safeArtifactFullPath
  return [ordered]@{
    schema = $schema
    mode = Get-SmokeMode
    status = $Status
    live_requests_sent = $liveRequestsSent
    measurements_available = $measurementsAvailable
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
        observed_contender_jobs = if ($script:ObservedContenderJobs -gt 0) { [int]$script:ObservedContenderJobs } else { $null }
        observed_contender_duration_ms = $script:ObservedContenderDurationMilliseconds
        unavailable = $measurementMarker
      }
      latency_or_ttft = [ordered]@{
        gateway_latency_ms = $gatewayLatencyMs
        ttft_ms = $null
        unavailable = if ($null -ne $gatewayLatencyMs) { $availableMarker } else { $unavailable }
      }
      row_count = [ordered]@{
        request_log_query_limit = 10
        provider_attempt_query_join = "request_logs_left_join_provider_attempts"
        max_affected_rows_per_acquire = [int]$script:Fixture.postgres_scope.max_affected_rows_per_acquire
        observed_request_log_rows = if ($script:ObservedRequestLogRows -gt 0) { [int]$script:ObservedRequestLogRows } else { $null }
        observed_provider_attempt_rows = if ($script:ObservedProviderAttemptRows -gt 0) { [int]$script:ObservedProviderAttemptRows } else { $null }
        forced_limit_provider_attempt_rows = $script:ForcedLimitProviderAttemptRows
        unavailable = if ($script:ObservedRequestLogRows -gt 0) { $availableMarker } else { $unavailable }
      }
      not_applied_or_fallback_rate = [ordered]@{
        expected_not_applied_count_min = $expectedNotAppliedCount
        expected_fallback_count_min = $expectedFallbackCount
        observed_not_applied_count = if ($script:ObservedNotAppliedCount -gt 0) { [int]$script:ObservedNotAppliedCount } else { $null }
        observed_fallback_count = if ($script:ObservedFallbackCount -gt 0) { [int]$script:ObservedFallbackCount } else { $null }
        observed_rate = if ($notAppliedFallbackTotal -gt 0) { $notAppliedFallbackRate } else { $null }
        unavailable = if ($notAppliedFallbackTotal -gt 0) { $availableMarker } else { $unavailable }
      }
      reservation_counts = [ordered]@{
        expected_acquire_count_min = $expectedAcquireCount
        expected_release_count_min = $expectedReleaseCount
        observed_acquire_count = if ($script:ObservedAcquireCount -gt 0) { [int]$script:ObservedAcquireCount } else { $null }
        observed_release_count = if ($script:ObservedReleaseCount -gt 0) { [int]$script:ObservedReleaseCount } else { $null }
        unavailable = if ($script:ObservedAcquireCount -gt 0) { $availableMarker } else { $unavailable }
      }
    }
    trusted_numeric_source_handoff = [ordered]@{
      schema = "gateway_tpm_trusted_numeric_source_request_path_handoff_v1"
      provider_opt_in_default = $false
      artifact_write_default = $false
      artifact_path_scope = ".tmp"
      request_path_default_provider_invoked = $false
      request_path_tpm_estimated_default = $true
      request_path_estimated_field = "rate_limit_reservation.tpm_estimate.estimated"
      request_path_trusted_numeric_present_field = "rate_limit_reservation.tpm_estimate.trusted_numeric_source_present"
      closure_requires_live_evidence = $true
      marker_names = [ordered]@{
        availability = "gateway_tpm_trusted_numeric_source_available"
        preflight_duration = "gateway_tpm_trusted_numeric_source_preflight_duration_ms"
        estimate_duration = "gateway_tpm_trusted_numeric_source_estimate_duration_ms"
        source = "gateway_tpm_trusted_numeric_source_type"
        token_count = "gateway_tpm_trusted_numeric_source_token_count"
      }
    }
    smoke_run_readback = [ordered]@{
      schema = "gateway_rate_limit_reservation_smoke_run_readback_v1"
      smoke_run_id = [string]$script:SmokeSuffix
      request_hashes = @($script:ObservedRequestHashes | Select-Object -Unique)
      request_ids = @($script:ObservedRequestIds | Select-Object -Unique)
      operator_sql = "scripts/operator/e8_rate_limit_db_acquire_readback.sql"
      operator_sql_parameters = [ordered]@{
        artifact_path = ".tmp/gateway_tpm_production_backend/e8-rate-limit-live-smoke.json"
        smoke_run_id = [string]$script:SmokeSuffix
        request_hashes = (@($script:ObservedRequestHashes | Select-Object -Unique) -join ",")
        request_ids = (@($script:ObservedRequestIds | Select-Object -Unique) -join ",")
      }
      copyable_readback_command = "Get-Content scripts/operator/e8_rate_limit_db_acquire_readback.sql | docker compose -f $ComposeFile exec -T postgres psql -U ai_gateway -d ai_gateway -v ON_ERROR_STOP=1 --set artifact_path=.tmp/gateway_tpm_production_backend/e8-rate-limit-live-smoke.json --set smoke_run_id=$script:SmokeSuffix --set request_hashes='<comma-separated hashes from this report>' --set request_ids='<comma-separated request ids from this report>'"
      same_smoke_run_request_correlation = $true
      raw_material_in_output = $false
    }
    artifact_write = [ordered]@{
      configured = [bool](-not [string]::IsNullOrWhiteSpace($ArtifactPath))
      path = $safeArtifactRelativePath
      allowed_scope = if ($null -ne $safeArtifactRelativePath) { ".tmp_or_artifacts" } else { $null }
      secret_safe = $true
    }
    request_trace_usage_handoff = New-RateLimitExplainabilityHandoff -Status $Status
    secret_safe_command_summary = New-SecretSafeCommandSummary
    blockers = @($script:Failures | ForEach-Object { Redact-SecretLikeString ([string]$_) })
    blocker_evidence = [ordered]@{
      missing_services = @($script:MissingServices)
      docker_or_compose_unavailable = [bool](@($script:Failures | Where-Object { ([string]$_).Contains("docker compose ps failed") }).Count -gt 0)
      gateway_unavailable = [bool](@($script:MissingServices | Where-Object { $_ -eq "gateway" }).Count -gt 0)
      postgres_unavailable = [bool](@($script:MissingServices | Where-Object { $_ -eq "postgres" }).Count -gt 0)
      mock_provider_unavailable = [bool](@($script:MissingServices | Where-Object { $_ -eq "mock-provider" }).Count -gt 0)
    }
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
  $reportJson = ($report | ConvertTo-Json -Depth 32 -Compress)
  $artifactFullPath = Resolve-SafeArtifactPath
  if ($artifactFullPath) {
    $artifactDirectory = Split-Path -Parent $artifactFullPath
    if (-not (Test-Path $artifactDirectory)) {
      New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
    }
    Set-Content -LiteralPath $artifactFullPath -Value $reportJson -Encoding UTF8
  }
  $script:PerformanceEvidenceReportWritten = $true
  Write-SafeHost ""
  Write-SafeHost "Gateway rate-limit reservation performance evidence:"
  Write-SafeHost $reportJson
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

function RateLimitStateSql {
  param(
    [Parameter(Mandatory = $true)][int]$RpmUsed,
    [Parameter(Mandatory = $true)][int]$TpmUsed,
    [Parameter(Mandatory = $true)][int]$ConcurrencyUsed
  )

  return "jsonb_build_object('rpm', jsonb_build_object('used', $RpmUsed), 'tpm', jsonb_build_object('used', $TpmUsed), 'concurrency', jsonb_build_object('used', $ConcurrencyUsed))"
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
  $stateSql = RateLimitStateSql -RpmUsed $RpmUsed -TpmUsed $TpmUsed -ConcurrencyUsed $ConcurrencyUsed
  $sql = @"
update provider_keys
   set rpm_limit = $RpmLimit,
       tpm_limit = $TpmLimit,
       concurrency_limit = $ConcurrencyLimit,
       current_window_state = $stateSql,
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
    status,
    cooldown_until,
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
    $status = Escape-SqlLiteral ([string]$row.status)
    $cooldownUntil = if ($null -eq $row.cooldown_until -or [string]::IsNullOrWhiteSpace([string]$row.cooldown_until)) {
      "null"
    } else {
      "'" + (Escape-SqlLiteral ([string]$row.cooldown_until)) + "'::timestamptz"
    }
    $stateJson = Escape-SqlLiteral (($row.current_window_state | ConvertTo-Json -Depth 16 -Compress))
    $sql = @"
update provider_keys
   set rpm_limit = $rpm,
       tpm_limit = $tpm,
       concurrency_limit = $concurrency,
       status = '$status',
       cooldown_until = $cooldownUntil,
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

function Reconcile-LiveSmokeProviderKeys {
  $tenantId = Escape-SqlLiteral ([string]$script:Fixture.postgres_scope.tenant_id)
  $idsSql = ProviderKeyIdListSql @($script:Fixture.postgres_scope.bounded_provider_key_ids)
  $sql = @"
update provider_keys
   set status = 'enabled',
       cooldown_until = null,
       last_error_code = null,
       deleted_at = null,
       updated_at = now()
 where tenant_id = '$tenantId'
   and id in ($idsSql);
"@
  [void](Invoke-ComposePsql $sql)
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

function Record-LiveRequestLatency {
  param([Parameter(Mandatory = $true)][int]$LatencyMilliseconds)

  $script:ObservedGatewayLatencyMilliseconds += [int]$LatencyMilliseconds
}

function Record-LiveRows {
  param([Parameter(Mandatory = $true)]$Rows)

  $rowsArray = @($Rows)
  $requestIds = @($rowsArray | Select-Object -ExpandProperty request_id -Unique)
  $script:ObservedRequestIds += $requestIds
  $script:ObservedRequestLogRows += $requestIds.Count
  $script:ObservedProviderAttemptRows += @(Get-AttemptRows $rowsArray).Count
}

function Record-RateLimitReservationMetadata {
  param([Parameter(Mandatory = $true)]$Metadata)

  if (-not $Metadata -or -not $Metadata.rate_limit_reservation) {
    return
  }
  $reservation = $Metadata.rate_limit_reservation
  if ($reservation.db_execution -and $reservation.db_execution.acquire -and $reservation.db_execution.acquire.status -eq "applied") {
    $script:ObservedAcquireCount += 1
  }
  if ($reservation.db_execution -and $reservation.db_execution.release -and $reservation.db_execution.release.status -eq "applied") {
    $script:ObservedReleaseCount += 1
  }
}

function Record-RateLimitRejectionSnapshot {
  param([Parameter(Mandatory = $true)]$Snapshot)

  if (-not $Snapshot -or -not $Snapshot.rate_limit_reservation_rejection) {
    return
  }
  $rejection = $Snapshot.rate_limit_reservation_rejection
  foreach ($skipEvent in @($rejection.skip_events)) {
    if ($skipEvent.rate_limit_reservation.db_execution.acquire.status -eq "not_applied") {
      $script:ObservedNotAppliedCount += 1
    }
  }
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
    $providerKeyRows = @($rows | Where-Object { $_.kind -eq "provider_key" } | Select-Object kind, id, status, active)
    $diagnostic = ($providerKeyRows | ConvertTo-Json -Depth 4 -Compress)
    throw "expected all three smoke provider keys to be enabled and active; observed provider key states: $diagnostic"
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
  if ([int]$Fixture.required_capacity.tokens_per_minute -ne 1024) {
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
      "measurements_available",
      "bounded_scope",
      "performance",
      "trusted_numeric_source_handoff",
      "smoke_run_readback",
      "secret_safe_command_summary",
      "blockers",
      "blocker_evidence",
      "secret_safety"
    )) {
    if (@($Fixture.performance_evidence_contract.required_top_level_fields | Where-Object { $_ -eq $field }).Count -ne 1) {
      throw "performance evidence contract missing top-level field '$field'"
    }
  }
  foreach ($field in @(
      "concurrency",
      "latency_or_ttft",
      "row_count",
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

    $missing = @()
    foreach ($service in @($script:Fixture.compose.required_services)) {
      if ($running -notcontains $service) {
        $missing += [string]$service
      }
    }
    if ($missing.Count -gt 0) {
      $script:MissingServices = @($missing)
      throw "[BLOCKED] missing required services: $($missing -join ', '); run 'pwsh -File scripts/verify_gateway_rate_limit_reservation_smoke.ps1 -DryRun' for contract-only validation or start the compose stack and rerun -PreflightOnly"
    }
  } finally {
    Pop-Location
  }
}

function Assert-ScriptStructure {
  $source = Get-Content -LiteralPath $PSCommandPath -Raw
  foreach ($needle in @(
      "Start-ProviderKeyOverLimitContender",
      "Wait-ProviderKeyOverLimitContenderReady",
      "pg_advisory_xact_lock",
      "rate_limit_reservation_rejection",
      "not_applied",
      "release.status",
      "Assert-NoSecretLeak",
      "Restore-OriginalProviderKeyStates",
      "Write-PerformanceEvidenceReport",
      "gateway_rate_limit_reservation_performance_evidence_v1",
      "latency_or_ttft",
      "row_count",
      "observed_request_log_rows",
      "observed_provider_attempt_rows",
      "observed_contender_duration_ms",
      "not_applied_or_fallback_rate",
      "trusted_numeric_source_handoff",
      "measurements_available",
      "live_observed",
      "copyable_preflight_command",
      "secret_safe_command_summary",
      "artifact_write",
      "Reconcile-LiveSmokeProviderKeys",
      "request_trace_usage_handoff",
      "forced_limit_provider_attempt_rows",
      "gateway_rate_limit_request_trace_usage_handoff_v1",
      "request_trace_lookup_keys",
      "admin_readback_expectations",
      "usage_cost_expectations",
      "request_path_tpm_estimated_default",
      "same_smoke_run_request_correlation"
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
  $stateSql = RateLimitStateSql -RpmUsed 0 -TpmUsed 0 -ConcurrencyUsed 1
  $sql = @"
begin;
select id
  from provider_keys
 where tenant_id = '$tenantId'
   and id in ($idsSql)
 order by id
 for update;
select pg_advisory_xact_lock($script:ContenderReadyLockKey);
select pg_sleep($HoldSeconds);
update provider_keys
   set current_window_state = $stateSql,
       updated_at = now()
 where tenant_id = '$tenantId'
   and id in ($idsSql);
commit;
"@

  $docker = Get-DockerCommand
  $script:ObservedContenderStartedAt = Get-Date
  return Start-Job -ScriptBlock {
    param($RepoRoot, $DockerCommand, $ComposeFile, $Sql)
    Set-Location $RepoRoot
    & $DockerCommand compose -f $ComposeFile exec -T postgres psql -U ai_gateway -d ai_gateway -v ON_ERROR_STOP=1 -c $Sql
    if ($LASTEXITCODE -ne 0) {
      throw "concurrent psql contender failed with exit code $LASTEXITCODE"
    }
  } -ArgumentList ([string]$repoRoot), $docker, $ComposeFile, $sql
}

function Wait-ProviderKeyOverLimitContenderReady {
  $deadline = (Get-Date).AddSeconds([Math]::Max(2, $LockHoldSeconds))
  while ((Get-Date) -lt $deadline) {
    $sql = "select case when pg_try_advisory_lock($script:ContenderReadyLockKey) then case when pg_advisory_unlock($script:ContenderReadyLockKey) then 'free' else 'free' end else 'held' end;"
    $state = Invoke-ComposePsql $sql
    if ($state.Trim() -eq "held") {
      return
    }
    Start-Sleep -Milliseconds 100
  }

  throw "concurrent provider-key contender did not signal ready before request"
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
    $script:ObservedContenderJobs += 1
  } finally {
    if ($script:ObservedContenderStartedAt) {
      $script:ObservedContenderDurationMilliseconds = [int]((Get-Date) - $script:ObservedContenderStartedAt).TotalMilliseconds
    }
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
  $script:ObservedRequestHashes += $hash
  $timer = [System.Diagnostics.Stopwatch]::StartNew()
  $response = Invoke-GatewayRequest -JsonBody $json -Headers (New-GatewayHeaders $ProfileRef) -TimeoutSec $TimeoutSec
  $timer.Stop()
  Record-LiveRequestLatency -LatencyMilliseconds ([int]$timer.ElapsedMilliseconds)
  return [PSCustomObject]@{
    Body = $body
    Json = $json
    Hash = $hash
    Response = $response
    LatencyMilliseconds = [int]$timer.ElapsedMilliseconds
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
  Record-LiveRows -Rows $rows
  $attempts = @(Get-AttemptRows $rows)
  if ($attempts.Count -lt 1) {
    throw "provider_attempts row was not recorded for acquire update"
  }
  Record-RateLimitReservationMetadata -Metadata $attempts[0].metadata
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
  Record-LiveRows -Rows $rows
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
  Record-RateLimitReservationMetadata -Metadata $failedAttempt[0].metadata
  Record-RateLimitReservationMetadata -Metadata $fallbackAttempt[0].metadata
  if (-not [string]::IsNullOrWhiteSpace([string]$failedAttempt[0].fallback_reason)) {
    $script:ObservedFallbackCount += 1
  }
  Assert-ProviderKeyCounters `
    -ProviderKeyId $failedKeyId `
    -Rpm ([int]$case.expected_failed_key_used_after_release.rpm) `
    -Tpm ([int]$case.expected_failed_key_used_after_release.tpm) `
    -Concurrency ([int]$case.expected_failed_key_used_after_release.concurrency)
  Assert-ProviderKeyCounters -ProviderKeyId $fallbackKeyId -Rpm 1 -Tpm ([int]$script:Fixture.required_capacity.tokens_per_minute) -Concurrency 1
  Assert-RateLimitEvidenceSecretSafe -ResponseContent $tracked.Response.Content -Rows $rows -Label "fallback release evidence"
}

function Check-ConcurrentOverLimitNotAppliedFinal429 {
  $case = $script:Fixture.live_cases.concurrent_over_limit_not_applied_final_429
  $providerKeyIds = @($case.locked_provider_key_ids)
  Set-ProviderKeyRateLimitWindow -ProviderKeyIds $providerKeyIds -RpmLimit 1000 -TpmLimit 100000 -ConcurrencyLimit 1 -RpmUsed 0 -TpmUsed 0 -ConcurrencyUsed 0

  $job = Start-ProviderKeyOverLimitContender -ProviderKeyIds $providerKeyIds -HoldSeconds $LockHoldSeconds
  Wait-ProviderKeyOverLimitContenderReady
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
  Record-LiveRows -Rows $rows
  $attempts = @(Get-AttemptRows $rows)
  $script:ForcedLimitProviderAttemptRows = [int]$attempts.Count
  if ($attempts.Count -ne 0) {
    throw "concurrent over-limit final 429 should not create provider_attempts; got $($attempts.Count)"
  }
  $requestRow = $rows[0]
  Record-RateLimitRejectionSnapshot -Snapshot $requestRow.route_decision_snapshot
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
  if ($ExplainabilitySelfTest) {
    Invoke-ExplainabilitySelfTest
    exit 0
  }

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

  Check "reconcile bounded rate-limit smoke provider keys" {
    Reconcile-LiveSmokeProviderKeys
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

Write-PerformanceEvidenceReport -Status "live_completed" -UnavailableReason "live_observed"

Write-SafeHost ""
Write-SafeHost "Gateway rate-limit reservation live Postgres smoke passed."
