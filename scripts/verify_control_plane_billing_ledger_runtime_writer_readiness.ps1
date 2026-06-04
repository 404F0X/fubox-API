param(
  [switch]$Live,
  [switch]$RuntimeWriterAvailable,
  [int]$BlockedExitCode = 2
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$fixturePath = Join-Path $repoRoot "tests\fixtures\control-plane\ledger_adjustment_dry_run_contract.json"
$contract = (Get-Content -Raw $fixturePath | ConvertFrom-Json).billing_ledger_writer_cutover_preflight_contract
$readinessContract = $contract.readiness_smoke_wrapper_contract
$providerContract = $contract.runtime_env_provider_preflight_contract
$performanceContract = $contract.handoff_performance_guard_contract

$modeEnvVar = [string]$providerContract.cutover_mode_env_var
$databaseUrlEnvVar = [string]$providerContract.live_database_url_env_var
$featureEnvVar = [string]$readinessContract.opt_in_inputs.runtime_writer_feature_env_var
$liveOptInEnvVar = "AI_CONTROL_PLANE_BILLING_LEDGER_RUNTIME_WRITER_READINESS_LIVE"

function Test-TruthyEnv {
  param([AllowNull()][string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $false
  }

  $normalized = $Value.Trim().ToLowerInvariant()
  return $normalized -in @("1", "true", "yes", "ready", "enabled")
}

function Normalize-CutoverMode {
  param([AllowNull()][string]$Value)

  if ($null -eq $Value) {
    return @{
      Mode = "disabled"
      InputState = "missing_defaulted"
      Invalid = $false
    }
  }

  $normalized = $Value.Trim().ToLowerInvariant()
  if ($normalized.Length -eq 0) {
    return @{
      Mode = "disabled"
      InputState = "blank_defaulted"
      Invalid = $false
    }
  }

  if ($normalized -in @("disabled", "shadow", "ready")) {
    return @{
      Mode = $normalized
      InputState = "valid_normalized"
      Invalid = $false
    }
  }

  return @{
    Mode = "disabled"
    InputState = "invalid_disabled_guard"
    Invalid = $true
  }
}

function Assert-Contract {
  if ([string]$readinessContract.schema_version -ne "control_plane_billing_ledger_writer_readiness_smoke_wrapper.v1") {
    throw "readiness smoke wrapper schema mismatch"
  }
  if ([bool]$readinessContract.default_live_db_check) {
    throw "readiness smoke wrapper must default to DB-free"
  }
  if (-not [bool]$readinessContract.explicit_opt_in_required) {
    throw "readiness smoke wrapper must require explicit live opt-in"
  }
  if ([bool]$readinessContract.production_writer_replaced) {
    throw "readiness smoke wrapper must not replace the production writer"
  }
  if ([bool]$readinessContract.dual_commit_allowed) {
    throw "readiness smoke wrapper must not allow dual commit"
  }
  if ([string]$providerContract.live_database_url_output -ne "presence_marker_only") {
    throw "live DB URL output must be a presence marker"
  }
  if ([string]$providerContract.runtime_writer_feature_output -ne "boolean_only") {
    throw "runtime writer feature output must be boolean-only"
  }
  if ([string]$performanceContract.summary_field -ne "handoff_performance_summary") {
    throw "handoff performance summary contract missing"
  }
}

function New-UnavailableMarker {
  param([Parameter(Mandatory = $true)][string]$Kind)

  return [ordered]@{
    available = $false
    marker = "${Kind}_unavailable"
    measurement_available = $false
    db_io_performed = $false
    output = "unavailable_marker_without_db_io"
  }
}

function Assert-SecretSafeJson {
  param([Parameter(Mandatory = $true)][string]$Json)

  foreach ($forbidden in @(
      "postgres://",
      "postgresql://",
      "Authorization",
      "Bearer ",
      "sk-live",
      "password=",
      "raw credential",
      "operation_key=",
      "idempotency_key",
      "raw ledger payload",
      "raw executor failure detail"
    )) {
    if ($Json.Contains($forbidden)) {
      throw "readiness output contains forbidden material pattern: $forbidden"
    }
  }
}

Assert-Contract

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$liveOptIn = [bool]$Live -or (Test-TruthyEnv ([Environment]::GetEnvironmentVariable($liveOptInEnvVar)))
$mode = Normalize-CutoverMode ([Environment]::GetEnvironmentVariable($modeEnvVar))
$liveDatabaseUrlPresent = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($databaseUrlEnvVar))
$featureAvailable = [bool]$RuntimeWriterAvailable -or (Test-TruthyEnv ([Environment]::GetEnvironmentVariable($featureEnvVar)))
$blockers = New-Object System.Collections.Generic.List[string]

if ($liveOptIn) {
  if ([bool]$mode.Invalid) {
    [void]$blockers.Add("invalid_cutover_mode_guard")
  } elseif ([string]$mode.Mode -ne "ready") {
    [void]$blockers.Add("cutover_mode_not_ready")
  }
  if (-not $liveDatabaseUrlPresent) {
    [void]$blockers.Add("live_database_url_missing")
  }
  if (-not $featureAvailable) {
    [void]$blockers.Add("runtime_writer_feature_unavailable")
  }
}

$readiness = "unavailable"
if ($liveOptIn) {
  if ($blockers.Count -eq 0) {
    $readiness = "ready"
  } else {
    $readiness = "blocked"
  }
}

$stopwatch.Stop()

$summary = [ordered]@{
  schema_version = [string]$readinessContract.schema_version
  script = "scripts/verify_control_plane_billing_ledger_runtime_writer_readiness.ps1"
  readiness = $readiness
  duration_ms = [math]::Max(0, [int]$stopwatch.ElapsedMilliseconds)
  duration_source = "script_stopwatch"
  live_opt_in = $liveOptIn
  mode = [ordered]@{
    env_var = $modeEnvVar
    effective_mode = [string]$mode.Mode
    input_state = [string]$mode.InputState
    invalid_value_refused = [bool]$mode.Invalid
    env_value_output = "omitted"
    raw_env_value_echoed = $false
  }
  live_database_url = [ordered]@{
    env_var = $databaseUrlEnvVar
    present = $liveDatabaseUrlPresent
    checked = $liveOptIn
    output = "presence_marker_only"
    raw_database_url_echoed = $false
  }
  runtime_writer_feature = [ordered]@{
    feature_marker = [string]$providerContract.runtime_writer_feature_marker
    env_var = $featureEnvVar
    available = $featureAvailable
    checked = $liveOptIn
    output = "boolean_only"
    raw_feature_config_echoed = $false
  }
  blockers = @($blockers)
  handoff_performance_summary = [ordered]@{
    schema_version = [string]$performanceContract.schema_version
    available = $false
    measurement_available = $false
    db_io_performed = $false
    output = "unavailable_marker_without_db_io"
  }
  row_count_summary = (New-UnavailableMarker -Kind "row_count_summary")
  transaction_summary = (New-UnavailableMarker -Kind "transaction_summary")
  no_double_write = [ordered]@{
    production_writer_replaced = $false
    production_source_of_truth_switch_allowed = $false
    billing_ledger_writer_commit_allowed = $false
    dual_commit_allowed = $false
  }
  safe_output = [ordered]@{
    env_value_output = "omitted"
    database_url_output = "omitted"
    operation_key_output = "omitted"
    raw_env_value_echoed = $false
    raw_database_url_echoed = $false
    credential_material_echoed = $false
    raw_executor_error_detail_echoed = $false
  }
}

$json = $summary | ConvertTo-Json -Depth 12
Assert-SecretSafeJson -Json $json
Write-Output $json

if ($readiness -eq "blocked") {
  exit $BlockedExitCode
}

exit 0
