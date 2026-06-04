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
$evidenceMatrixContract = $readinessContract.live_cutover_evidence_matrix_contract
$dryRunEvidenceContract = $readinessContract.runtime_writer_dry_run_execution_evidence_contract
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
  if ([string]$evidenceMatrixContract.schema_version -ne "control_plane_billing_ledger_live_cutover_evidence_matrix.v1") {
    throw "live cutover evidence matrix schema mismatch"
  }
  if ([bool]$evidenceMatrixContract.production_source_of_truth_switch_allowed_in_this_contract) {
    throw "evidence matrix must not allow source-of-truth switch"
  }
  if ([bool]$evidenceMatrixContract.dual_commit_allowed) {
    throw "evidence matrix must not allow dual commit"
  }
  if ([string]$dryRunEvidenceContract.schema_version -ne "control_plane_billing_ledger_runtime_writer_dry_run_execution_evidence.v1") {
    throw "dry-run execution evidence schema mismatch"
  }
  if ([bool]$dryRunEvidenceContract.db_write_performed) {
    throw "dry-run execution evidence must not write DB"
  }
  if ([bool]$dryRunEvidenceContract.dual_commit_allowed) {
    throw "dry-run execution evidence must not allow dual commit"
  }
  if ([int]$dryRunEvidenceContract.bounded_command_count.max -le 0) {
    throw "dry-run execution evidence must define a positive bounded command count"
  }
  $rowExpectationStatementKinds = @($dryRunEvidenceContract.row_count_expectations | ForEach-Object { [string]$_.statement_kind })
  foreach ($requiredStatementKind in @("lock_idempotency_scope", "lock_wallet_scope", "insert_ledger_entry", "mark_idempotency_applied")) {
    if ($requiredStatementKind -notin $rowExpectationStatementKinds) {
      throw "dry-run execution evidence missing row-count expectation: $requiredStatementKind"
    }
  }
  $timingNames = @($dryRunEvidenceContract.transaction_step_timing_names | ForEach-Object { [string]$_ })
  foreach ($requiredTimingName in @("begin_transaction", "row_count_enforcement", "rollback_transaction")) {
    if ($requiredTimingName -notin $timingNames) {
      throw "dry-run execution evidence missing transaction timing name: $requiredTimingName"
    }
  }
  if ([string]$dryRunEvidenceContract.rollback_fallback_guard.local_writer_fallback -ne "control_plane_local_sql_writer") {
    throw "dry-run execution evidence must preserve local writer fallback"
  }
  $evidenceKeys = @($evidenceMatrixContract.required_evidence | ForEach-Object { [string]$_.key })
  foreach ($requiredEvidence in @("migrated_db", "runtime_writer_feature", "source_of_truth_switch", "rollback_path", "performance_summaries", "schema_markers")) {
    if ($requiredEvidence -notin $evidenceKeys) {
      throw "evidence matrix missing required evidence key: $requiredEvidence"
    }
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

function New-EvidenceItem {
  param(
    [Parameter(Mandatory = $true)][string]$Key,
    [Parameter(Mandatory = $true)][string]$Status,
    [Parameter(Mandatory = $true)][string]$Marker,
    [Parameter(Mandatory = $true)][string]$EvidenceOutput,
    [Parameter(Mandatory = $true)][bool]$Required
  )

  return [ordered]@{
    key = $Key
    status = $Status
    marker = $Marker
    required = $Required
    evidence_output = $EvidenceOutput
    raw_value_echoed = $false
  }
}

function New-DryRunExecutionEvidence {
  param(
    [Parameter(Mandatory = $true)][string]$Readiness,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Blockers
  )

  $classification = "blocker"
  if ($Readiness -eq "ready") {
    $classification = "ready"
  } elseif ($Readiness -eq "unavailable") {
    $classification = "blocker"
  }

  $rowCountExpectations = @(
    $dryRunEvidenceContract.row_count_expectations | ForEach-Object {
      [ordered]@{
        statement_kind = [string]$_.statement_kind
        expected_rows = [string]$_.expected_rows
        mismatch_classification = [string]$_.mismatch_classification
        actual_rows = $null
        output = "expectation_only_no_db_io"
      }
    }
  )

  $timingNames = @($dryRunEvidenceContract.transaction_step_timing_names | ForEach-Object { [string]$_ })

  return [ordered]@{
    schema_version = [string]$dryRunEvidenceContract.schema_version
    execution_mode = [string]$dryRunEvidenceContract.execution_mode
    classification = $classification
    db_write_performed = $false
    production_writer_replaced = $false
    production_source_of_truth_switch_allowed = $false
    billing_ledger_writer_commit_allowed = $false
    dual_commit_allowed = $false
    bounded_command_count = [ordered]@{
      observed = 0
      min = [int]$dryRunEvidenceContract.bounded_command_count.min
      max = [int]$dryRunEvidenceContract.bounded_command_count.max
      source = [string]$dryRunEvidenceContract.bounded_command_count.source
      unbounded_scan_allowed = $false
      output = "bounded_numeric"
    }
    bounded_command_kinds = @($dryRunEvidenceContract.bounded_command_kinds | ForEach-Object { [string]$_ })
    row_count_expectations = $rowCountExpectations
    transaction_step_timing_names = $timingNames
    transaction_step_timing = [ordered]@{
      measurement_available = $false
      names = $timingNames
      duration_ms = $null
      output = "names_only_no_db_io"
    }
    rollback_fallback_guard = [ordered]@{
      rollback_required_on_row_count_mismatch = $true
      rollback_required_on_adapter_refusal = $true
      local_writer_fallback = "control_plane_local_sql_writer"
      fallback_after_billing_commit_allowed = $false
      rollback_summary_required = $true
    }
    blockers = @($Blockers)
    failure_blocker_classification = [ordered]@{
      runtime_writer_unavailable = [string]$dryRunEvidenceContract.failure_blocker_classification.runtime_writer_unavailable
      live_database_url_missing = [string]$dryRunEvidenceContract.failure_blocker_classification.live_database_url_missing
      row_count_expectation_missing = [string]$dryRunEvidenceContract.failure_blocker_classification.row_count_expectation_missing
      bounded_command_count_exceeded = [string]$dryRunEvidenceContract.failure_blocker_classification.bounded_command_count_exceeded
      transaction_timing_name_missing = [string]$dryRunEvidenceContract.failure_blocker_classification.transaction_timing_name_missing
      unsafe_output_detected = [string]$dryRunEvidenceContract.failure_blocker_classification.unsafe_output_detected
    }
    safe_output = [ordered]@{
      database_url_output = "omitted"
      env_value_output = "omitted"
      operation_key_output = "omitted"
      dedupe_material_echoed = $false
      raw_env_value_echoed = $false
      raw_database_url_echoed = $false
      raw_metadata_echoed = $false
      credential_material_echoed = $false
      raw_executor_error_detail_echoed = $false
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

$evidenceClassification = "blocker"
if ($readiness -eq "ready") {
  $evidenceClassification = "pass"
} elseif ($readiness -eq "blocked") {
  $evidenceClassification = "blocker"
}

$migratedDbStatus = if ($liveOptIn -and $liveDatabaseUrlPresent) { "pass" } else { "blocker" }
$featureStatus = if ($liveOptIn -and $featureAvailable) { "pass" } else { "blocker" }
$sourceOfTruthStatus = if ($readiness -eq "ready") { "pass" } else { "blocker" }
$rollbackStatus = "pass"
$performanceStatus = "pass"
$schemaStatus = "pass"

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
  evidence_matrix = [ordered]@{
    schema_version = [string]$evidenceMatrixContract.schema_version
    classification = $evidenceClassification
    supported_classifications = @("ready", "pass", "blocker", "fail")
    required_env_markers = @($modeEnvVar, $databaseUrlEnvVar, $featureEnvVar)
    required_tool_markers = @([string]$readinessContract.script, [string]$providerContract.runtime_writer_feature_marker)
    required_schema_markers = @(
      [string]$providerContract.schema_version,
      [string]$performanceContract.schema_version,
      [string]$readinessContract.schema_version
    )
    evidence = @(
      (New-EvidenceItem -Key "migrated_db" -Status $migratedDbStatus -Marker $databaseUrlEnvVar -EvidenceOutput "presence_marker_only" -Required $true),
      (New-EvidenceItem -Key "runtime_writer_feature" -Status $featureStatus -Marker ([string]$providerContract.runtime_writer_feature_marker) -EvidenceOutput "boolean_marker_only" -Required $true),
      (New-EvidenceItem -Key "source_of_truth_switch" -Status $sourceOfTruthStatus -Marker "separate_live_cutover_acceptance_required" -EvidenceOutput "guard_marker_only" -Required $true),
      (New-EvidenceItem -Key "rollback_path" -Status $rollbackStatus -Marker "control_plane_local_sql_writer_fallback" -EvidenceOutput "fallback_marker_only" -Required $true),
      (New-EvidenceItem -Key "performance_summaries" -Status $performanceStatus -Marker "handoff_performance_summary" -EvidenceOutput "unavailable_marker_without_db_io" -Required $true),
      (New-EvidenceItem -Key "schema_markers" -Status $schemaStatus -Marker "contract_schema_versions" -EvidenceOutput "schema_version_markers_only" -Required $true)
    )
    rollback_path = [ordered]@{
      local_writer_fallback = "control_plane_local_sql_writer"
      rollback_summary_required = $true
      fallback_after_billing_commit_allowed = $false
      raw_executor_error_detail_echoed = $false
    }
    performance_required_fields = @(
      "duration_ms",
      "handoff_performance_summary",
      "row_count_summary",
      "transaction_summary"
    )
    no_double_write = [ordered]@{
      production_writer_replaced = $false
      production_source_of_truth_switch_allowed = $false
      billing_ledger_writer_commit_allowed = $false
      dual_commit_allowed = $false
    }
    blocker_classification = [ordered]@{
      blockers = @($blockers)
      missing_migrated_db = "blocker"
      runtime_writer_feature_unavailable = "blocker"
      cutover_mode_not_ready = "blocker"
      invalid_cutover_mode_guard = "blocker"
      source_of_truth_switch_not_accepted = "blocker_for_real_cutover_not_readiness"
    }
    fail_classification = [ordered]@{
      contract_schema_mismatch = "fail"
      unsafe_output_detected = "fail"
      required_summary_field_missing = "fail"
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
  dry_run_execution_evidence = (New-DryRunExecutionEvidence -Readiness $readiness -Blockers @($blockers))
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
