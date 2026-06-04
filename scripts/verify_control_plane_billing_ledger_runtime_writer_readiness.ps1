param(
  [switch]$Live,
  [switch]$LiveExecutionProbe,
  [switch]$SimulateProbeMeasurements,
  [switch]$SimulateProbeRowCountMismatch,
  [switch]$SimulateStaleProbeArtifact,
  [switch]$SimulateMissingRowCountReadback,
  [switch]$SimulateMissingTimingReadback,
  [switch]$SimulateMissingRollbackProofReadback,
  [switch]$SimulateCommitObserved,
  [switch]$SimulateProductionWriterReplaced,
  [switch]$SimulateDualCommitObserved,
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
$liveExecutionHandoffContract = $readinessContract.live_execution_handoff_contract
$liveProbeArtifactContract = $readinessContract.live_probe_evidence_artifact_contract
$liveProbeExecutorBoundaryContract = $readinessContract.live_probe_executor_boundary_contract
$liveProbeReadbackGateContract = $readinessContract.live_probe_measurement_readback_gate_contract
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
  if ([string]$liveExecutionHandoffContract.schema_version -ne "control_plane_billing_ledger_live_execution_handoff.v1") {
    throw "live execution handoff schema mismatch"
  }
  if ([string]$liveExecutionHandoffContract.execution_mode -ne "live_probe_handoff_only") {
    throw "live execution handoff must remain handoff-only"
  }
  $handoffFlags = @($liveExecutionHandoffContract.safe_live_probe_command.flags | ForEach-Object { [string]$_ })
  foreach ($requiredHandoffFlag in @("-Live", "-LiveExecutionProbe")) {
    if ($requiredHandoffFlag -notin $handoffFlags) {
      throw "live execution handoff missing required flag: $requiredHandoffFlag"
    }
  }
  if ([string]$liveExecutionHandoffContract.expected_classification.live_probe_ready -ne "pass") {
    throw "live execution handoff must classify ready probe as pass"
  }
  if ([string]$liveExecutionHandoffContract.expected_classification.row_count_mismatch -ne "fail") {
    throw "live execution handoff must classify row-count mismatch as fail"
  }
  if ([bool]$liveExecutionHandoffContract.rollback_no_commit_guard.probe_commits_billing_ledger) {
    throw "live execution probe must not commit billing ledger"
  }
  if ([bool]$liveExecutionHandoffContract.rollback_no_commit_guard.dual_commit_allowed) {
    throw "live execution probe must not allow dual commit"
  }
  if ([string]$liveProbeArtifactContract.schema_version -ne "control_plane_billing_ledger_live_probe_evidence_artifact.v1") {
    throw "live probe evidence artifact schema mismatch"
  }
  $artifactClassifications = @($liveProbeArtifactContract.classification_values | ForEach-Object { [string]$_ })
  foreach ($requiredArtifactClassification in @("blocker", "pass", "fail")) {
    if ($requiredArtifactClassification -notin $artifactClassifications) {
      throw "live probe evidence artifact missing classification: $requiredArtifactClassification"
    }
  }
  $artifactFreshnessFields = @($liveProbeArtifactContract.freshness_fields | ForEach-Object { [string]$_ })
  foreach ($requiredFreshnessField in @("generated_at_utc", "current_commit", "freshness_marker", "stale_artifact")) {
    if ($requiredFreshnessField -notin $artifactFreshnessFields) {
      throw "live probe evidence artifact missing freshness field: $requiredFreshnessField"
    }
  }
  $artifactProvenanceFields = @($liveProbeArtifactContract.provenance_fields | ForEach-Object { [string]$_ })
  foreach ($requiredProvenanceField in @("probe_requested", "measurement_source", "executor_boundary_schema", "readiness_schema")) {
    if ($requiredProvenanceField -notin $artifactProvenanceFields) {
      throw "live probe evidence artifact missing provenance field: $requiredProvenanceField"
    }
  }
  $artifactRowFields = @($liveProbeArtifactContract.row_count_evidence_fields | ForEach-Object { [string]$_ })
  foreach ($requiredRowField in @("statement_kind", "expected_rows", "actual_rows", "rows_match", "mismatch_classification")) {
    if ($requiredRowField -notin $artifactRowFields) {
      throw "live probe evidence artifact missing row-count field: $requiredRowField"
    }
  }
  $artifactTimingFields = @($liveProbeArtifactContract.transaction_timing_duration_fields | ForEach-Object { [string]$_ })
  foreach ($requiredDurationField in @("begin_transaction_duration_ms", "insert_probe_ledger_entry_duration_ms", "mark_probe_idempotency_duration_ms", "row_count_capture_duration_ms", "rollback_transaction_duration_ms")) {
    if ($requiredDurationField -notin $artifactTimingFields) {
      throw "live probe evidence artifact missing timing duration field: $requiredDurationField"
    }
  }
  $artifactProofFields = @($liveProbeArtifactContract.rollback_no_commit_proof_fields | ForEach-Object { [string]$_ })
  foreach ($requiredProofField in @("rollback_observed", "commit_observed", "probe_commits_billing_ledger", "production_writer_replaced", "dual_commit_observed")) {
    if ($requiredProofField -notin $artifactProofFields) {
      throw "live probe evidence artifact missing rollback/no-commit proof field: $requiredProofField"
    }
  }
  if ([string]$liveProbeExecutorBoundaryContract.schema_version -ne "control_plane_billing_ledger_live_probe_executor_boundary.v1") {
    throw "live probe executor boundary schema mismatch"
  }
  if ([string]$liveProbeExecutorBoundaryContract.execution_mode -ne "rollback_only_live_probe") {
    throw "live probe executor boundary must remain rollback-only"
  }
  if (-not [bool]$liveProbeExecutorBoundaryContract.rollback_required) {
    throw "live probe executor boundary must require rollback"
  }
  if (-not [bool]$liveProbeExecutorBoundaryContract.commit_forbidden) {
    throw "live probe executor boundary must forbid commit"
  }
  $executorSteps = @($liveProbeExecutorBoundaryContract.step_ordering | ForEach-Object { [string]$_ })
  $expectedSteps = @(
    "begin_transaction",
    "lock_idempotency_scope",
    "lock_wallet_scope",
    "lock_budget_scope",
    "insert_probe_ledger_entry",
    "mark_probe_idempotency",
    "capture_row_count_measurements",
    "capture_timing_measurements",
    "rollback_transaction"
  )
  for ($stepIndex = 0; $stepIndex -lt $expectedSteps.Count; $stepIndex++) {
    if ($executorSteps[$stepIndex] -ne $expectedSteps[$stepIndex]) {
      throw "live probe executor boundary step ordering mismatch at index ${stepIndex}"
    }
  }
  $executorRowFields = @($liveProbeExecutorBoundaryContract.row_count_capture_fields | ForEach-Object { [string]$_ })
  foreach ($requiredExecutorRowField in @("expected_rows", "actual_rows", "rows_match", "rows_affected_source")) {
    if ($requiredExecutorRowField -notin $executorRowFields) {
      throw "live probe executor boundary missing row-count capture field: $requiredExecutorRowField"
    }
  }
  $executorTimingFields = @($liveProbeExecutorBoundaryContract.timing_duration_capture_fields | ForEach-Object { [string]$_ })
  foreach ($requiredExecutorTimingField in @("begin_transaction_duration_ms", "insert_probe_ledger_entry_duration_ms", "row_count_capture_duration_ms", "rollback_transaction_duration_ms")) {
    if ($requiredExecutorTimingField -notin $executorTimingFields) {
      throw "live probe executor boundary missing timing capture field: $requiredExecutorTimingField"
    }
  }
  if ([bool]$liveProbeExecutorBoundaryContract.rollback_no_commit_semantics.commit_statement_allowed) {
    throw "live probe executor boundary must not allow commit statements"
  }
  if ([bool]$liveProbeExecutorBoundaryContract.bounded_scope.unbounded_scan_allowed) {
    throw "live probe executor boundary must not allow unbounded scans"
  }
  if ([string]$liveProbeReadbackGateContract.schema_version -ne "control_plane_billing_ledger_live_probe_measurement_readback_gate.v1") {
    throw "live probe measurement readback gate schema mismatch"
  }
  $readbackFreshnessFields = @($liveProbeReadbackGateContract.required_freshness_fields | ForEach-Object { [string]$_ })
  foreach ($requiredReadbackFreshnessField in @("generated_at_utc", "current_commit", "freshness_marker", "stale_artifact")) {
    if ($requiredReadbackFreshnessField -notin $readbackFreshnessFields) {
      throw "live probe readback gate missing freshness field: $requiredReadbackFreshnessField"
    }
  }
  $readbackRowFields = @($liveProbeReadbackGateContract.required_row_count_fields | ForEach-Object { [string]$_ })
  foreach ($requiredReadbackRowField in @("statement_kind", "expected_rows", "actual_rows", "rows_match", "rows_affected_source")) {
    if ($requiredReadbackRowField -notin $readbackRowFields) {
      throw "live probe readback gate missing row-count field: $requiredReadbackRowField"
    }
  }
  $readbackTimingFields = @($liveProbeReadbackGateContract.required_timing_duration_fields | ForEach-Object { [string]$_ })
  foreach ($requiredReadbackTimingField in @("begin_transaction_duration_ms", "insert_probe_ledger_entry_duration_ms", "row_count_capture_duration_ms", "rollback_transaction_duration_ms")) {
    if ($requiredReadbackTimingField -notin $readbackTimingFields) {
      throw "live probe readback gate missing timing field: $requiredReadbackTimingField"
    }
  }
  if (-not [bool]$liveProbeReadbackGateContract.pass_requirements.rollback_observed) {
    throw "live probe readback gate pass must require rollback observed"
  }
  if ([bool]$liveProbeReadbackGateContract.pass_requirements.commit_observed) {
    throw "live probe readback gate pass must forbid commit observed"
  }
  $handoffRowEvidenceNames = @($liveExecutionHandoffContract.row_count_evidence_names | ForEach-Object { [string]$_ })
  foreach ($requiredRowEvidence in @("lock_idempotency_scope", "lock_wallet_scope", "insert_ledger_entry", "mark_idempotency_applied")) {
    if ($requiredRowEvidence -notin $handoffRowEvidenceNames) {
      throw "live execution handoff missing row-count evidence name: $requiredRowEvidence"
    }
  }
  $handoffTimingNames = @($liveExecutionHandoffContract.timing_evidence_names | ForEach-Object { [string]$_ })
  foreach ($requiredTimingEvidence in @("begin_transaction", "row_count_enforcement", "rollback_transaction")) {
    if ($requiredTimingEvidence -notin $handoffTimingNames) {
      throw "live execution handoff missing timing evidence name: $requiredTimingEvidence"
    }
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

function Get-CurrentCommitMarker {
  try {
    $commit = git -C $repoRoot rev-parse --short HEAD 2>$null
    if ([string]::IsNullOrWhiteSpace($commit)) {
      return "unavailable"
    }
    return [string]$commit.Trim()
  } catch {
    return "unavailable"
  }
}

function Test-EvidenceField {
  param(
    [Parameter(Mandatory = $true)]$Object,
    [Parameter(Mandatory = $true)][string]$Field
  )

  if ($Object -is [System.Collections.IDictionary]) {
    return $Object.Contains($Field)
  }

  return $Object.PSObject.Properties.Name -contains $Field
}

function Get-EvidenceField {
  param(
    [Parameter(Mandatory = $true)]$Object,
    [Parameter(Mandatory = $true)][string]$Field
  )

  if ($Object -is [System.Collections.IDictionary]) {
    return $Object[$Field]
  }

  return $Object.$Field
}

function New-LiveProbeEvidenceArtifact {
  param(
    [Parameter(Mandatory = $true)][string]$Readiness,
    [Parameter(Mandatory = $true)][bool]$ProbeRequested,
    [Parameter(Mandatory = $true)][bool]$MeasurementsAvailable,
    [Parameter(Mandatory = $true)][bool]$RowCountMismatch,
    [Parameter(Mandatory = $true)][bool]$StaleArtifact,
    [Parameter(Mandatory = $true)][bool]$CommitObserved,
    [Parameter(Mandatory = $true)][bool]$ProductionWriterReplaced,
    [Parameter(Mandatory = $true)][bool]$DualCommitObserved,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Blockers
  )

  $artifactBlockers = New-Object System.Collections.Generic.List[string]
  foreach ($blocker in @($Blockers)) {
    [void]$artifactBlockers.Add([string]$blocker)
  }

  if (-not $ProbeRequested) {
    [void]$artifactBlockers.Add("probe_not_requested")
  }
  if ($StaleArtifact) {
    [void]$artifactBlockers.Add("stale_artifact")
  }
  if ($ProbeRequested -and $Readiness -eq "ready" -and -not $MeasurementsAvailable -and -not $RowCountMismatch) {
    [void]$artifactBlockers.Add("missing_row_count_measurement")
    [void]$artifactBlockers.Add("missing_timing_measurement")
    [void]$artifactBlockers.Add("missing_rollback_proof")
  }

  $classification = "blocker"
  if ($RowCountMismatch) {
    $classification = "fail"
  } elseif ($CommitObserved -or $ProductionWriterReplaced -or $DualCommitObserved) {
    $classification = "fail"
  } elseif ($ProbeRequested -and $Readiness -eq "ready" -and $MeasurementsAvailable -and -not $StaleArtifact) {
    $classification = "pass"
  }

  $rowCountEvidence = @(
    $liveProbeExecutorBoundaryContract.row_count_expectations | ForEach-Object {
      $statementKind = [string]$_.statement_kind
      $expectedRows = [string]$_.expected_rows
      $actualRows = $null
      $rowsMatch = $null
      $mismatchClassification = "blocker"
      if ($MeasurementsAvailable) {
        if ($expectedRows -eq "zero_or_one") {
          $actualRows = 0
        } else {
          $actualRows = 1
        }
        $rowsMatch = $true
        $mismatchClassification = "pass"
      }
      if ($RowCountMismatch -and $statementKind -eq "insert_probe_ledger_entry") {
        $actualRows = 0
        $rowsMatch = $false
        $mismatchClassification = "fail"
      }
      [ordered]@{
        statement_kind = $statementKind
        expected_rows = $expectedRows
        actual_rows = $actualRows
        rows_match = $rowsMatch
        mismatch_classification = $mismatchClassification
        rows_affected_source = if ($MeasurementsAvailable -or $RowCountMismatch) { "contract_simulated_no_db_io" } else { "pending_live_probe_executor" }
      }
    }
  )

  $durationSource = if ($MeasurementsAvailable) { "contract_simulated_no_db_io" } else { "pending_live_probe_executor" }
  $durationValue = if ($MeasurementsAvailable) { 1 } else { $null }
  $generatedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
  $freshnessMarker = if ($StaleArtifact) { "stale" } else { "current" }

  return [ordered]@{
    schema_version = [string]$liveProbeArtifactContract.schema_version
    artifact_mode = [string]$liveProbeArtifactContract.artifact_mode
    generated_at_utc = $generatedAtUtc
    current_commit = (Get-CurrentCommitMarker)
    freshness_marker = $freshnessMarker
    stale_artifact = $StaleArtifact
    probe_requested = $ProbeRequested
    classification = $classification
    supported_classifications = @($liveProbeArtifactContract.classification_values | ForEach-Object { [string]$_ })
    provenance = [ordered]@{
      measurement_source = $durationSource
      executor_boundary_schema = [string]$liveProbeExecutorBoundaryContract.schema_version
      readiness_schema = [string]$readinessContract.schema_version
      probe_requested = $ProbeRequested
    }
    db_write_performed = $false
    production_writer_replaced = $ProductionWriterReplaced
    production_source_of_truth_switch_allowed = $false
    dual_commit_allowed = $false
    safe_command_summary = [ordered]@{
      script = [string]$liveExecutionHandoffContract.safe_live_probe_command.script
      flags = @($liveExecutionHandoffContract.safe_live_probe_command.flags | ForEach-Object { [string]$_ })
      required_env_markers = @($modeEnvVar, $databaseUrlEnvVar, $featureEnvVar)
      database_url_output = "presence_marker_only"
      env_value_output = "omitted"
      raw_env_values_echoed = $false
    }
    row_count_evidence = $rowCountEvidence
    transaction_timing_durations = [ordered]@{
      begin_transaction_duration_ms = $durationValue
      lock_idempotency_scope_duration_ms = $durationValue
      lock_wallet_scope_duration_ms = $durationValue
      lock_budget_scope_duration_ms = $durationValue
      insert_probe_ledger_entry_duration_ms = $durationValue
      mark_probe_idempotency_duration_ms = $durationValue
      row_count_capture_duration_ms = $durationValue
      rollback_transaction_duration_ms = $durationValue
      measurement_source = $durationSource
    }
    rollback_no_commit_proof = [ordered]@{
      rollback_observed = $MeasurementsAvailable
      commit_observed = $CommitObserved
      probe_commits_billing_ledger = $false
      production_writer_replaced = $ProductionWriterReplaced
      dual_commit_observed = $DualCommitObserved
      local_writer_fallback = "control_plane_local_sql_writer"
      proof_source = $durationSource
    }
    classification_rules = [ordered]@{
      blocker = @($liveProbeArtifactContract.classification_rules.blocker | ForEach-Object { [string]$_ })
      pass = @($liveProbeArtifactContract.classification_rules.pass | ForEach-Object { [string]$_ })
      fail = @($liveProbeArtifactContract.classification_rules.fail | ForEach-Object { [string]$_ })
    }
    blockers = @($artifactBlockers)
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

function New-LiveProbeExecutorBoundary {
  param(
    [Parameter(Mandatory = $true)][bool]$ProbeRequested,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Blockers
  )

  $rowCountMeasurementInputs = @(
    $liveProbeExecutorBoundaryContract.row_count_expectations | ForEach-Object {
      [ordered]@{
        statement_kind = [string]$_.statement_kind
        expected_rows = [string]$_.expected_rows
        actual_rows = $null
        rows_match = $null
        rows_affected_source = "pending_live_probe_executor"
      }
    }
  )

  return [ordered]@{
    schema_version = [string]$liveProbeExecutorBoundaryContract.schema_version
    execution_mode = [string]$liveProbeExecutorBoundaryContract.execution_mode
    probe_requested = $ProbeRequested
    db_write_performed = $false
    production_writer_replaced = $false
    production_source_of_truth_switch_allowed = $false
    commit_forbidden = $true
    rollback_required = $true
    dual_commit_allowed = $false
    step_ordering = @($liveProbeExecutorBoundaryContract.step_ordering | ForEach-Object { [string]$_ })
    row_count_measurement_inputs = $rowCountMeasurementInputs
    timing_duration_capture = [ordered]@{
      begin_transaction_duration_ms = $null
      lock_idempotency_scope_duration_ms = $null
      lock_wallet_scope_duration_ms = $null
      lock_budget_scope_duration_ms = $null
      insert_probe_ledger_entry_duration_ms = $null
      mark_probe_idempotency_duration_ms = $null
      row_count_capture_duration_ms = $null
      rollback_transaction_duration_ms = $null
      capture_source = "pending_live_probe_executor"
    }
    rollback_no_commit_semantics = [ordered]@{
      rollback_required_on_success = $true
      rollback_required_on_row_count_mismatch = $true
      rollback_required_on_executor_error = $true
      commit_statement_allowed = $false
      production_writer_unchanged = $true
      local_writer_fallback = "control_plane_local_sql_writer"
    }
    bounded_scope = [ordered]@{
      tenant_project_request_operation_required = $true
      operation_key_bind_only = $true
      unbounded_scan_allowed = $false
      max_statement_count = [int]$liveProbeExecutorBoundaryContract.bounded_scope.max_statement_count
    }
    blockers = @($Blockers)
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

function New-LiveProbeMeasurementReadbackGate {
  param(
    [Parameter(Mandatory = $true)]$Artifact,
    [Parameter(Mandatory = $true)][bool]$MissingRowCount,
    [Parameter(Mandatory = $true)][bool]$MissingTiming,
    [Parameter(Mandatory = $true)][bool]$MissingRollbackProof
  )

  $refusals = New-Object System.Collections.Generic.List[string]
  $failures = New-Object System.Collections.Generic.List[string]

  foreach ($field in @($liveProbeReadbackGateContract.required_freshness_fields | ForEach-Object { [string]$_ })) {
    if (-not (Test-EvidenceField -Object $Artifact -Field $field)) {
      [void]$refusals.Add("missing_freshness_field")
      break
    }
  }

  if ([bool](Get-EvidenceField -Object $Artifact -Field "stale_artifact") -or [string](Get-EvidenceField -Object $Artifact -Field "freshness_marker") -ne "current") {
    [void]$refusals.Add("stale_artifact")
  }

  $rowCountEvidence = @(Get-EvidenceField -Object $Artifact -Field "row_count_evidence")
  if ($MissingRowCount -or $rowCountEvidence.Count -eq 0) {
    [void]$refusals.Add("missing_row_count_field")
  } else {
    foreach ($row in $rowCountEvidence) {
      foreach ($field in @($liveProbeReadbackGateContract.required_row_count_fields | ForEach-Object { [string]$_ })) {
        if (-not (Test-EvidenceField -Object $row -Field $field)) {
          [void]$refusals.Add("missing_row_count_field")
          break
        }
      }
      if ((Get-EvidenceField -Object $row -Field "rows_match") -eq $false) {
        [void]$failures.Add("row_count_mismatch")
      }
      if ($null -eq (Get-EvidenceField -Object $row -Field "actual_rows") -or $null -eq (Get-EvidenceField -Object $row -Field "rows_match")) {
        [void]$refusals.Add("missing_row_count_field")
      }
    }
  }

  $timing = Get-EvidenceField -Object $Artifact -Field "transaction_timing_durations"
  if ($MissingTiming -or $null -eq $timing) {
    [void]$refusals.Add("missing_timing_duration")
  } else {
    foreach ($field in @($liveProbeReadbackGateContract.required_timing_duration_fields | ForEach-Object { [string]$_ })) {
      if (-not (Test-EvidenceField -Object $timing -Field $field) -or $null -eq (Get-EvidenceField -Object $timing -Field $field)) {
        [void]$refusals.Add("missing_timing_duration")
        break
      }
    }
  }

  $proof = Get-EvidenceField -Object $Artifact -Field "rollback_no_commit_proof"
  if ($MissingRollbackProof -or $null -eq $proof) {
    [void]$refusals.Add("missing_rollback_proof")
  } else {
    foreach ($field in @($liveProbeReadbackGateContract.required_rollback_no_commit_fields | ForEach-Object { [string]$_ })) {
      if (-not (Test-EvidenceField -Object $proof -Field $field)) {
        [void]$refusals.Add("missing_rollback_proof")
        break
      }
    }
    if ((Get-EvidenceField -Object $proof -Field "rollback_observed") -ne $true) {
      [void]$refusals.Add("missing_rollback_proof")
    }
    if ((Get-EvidenceField -Object $proof -Field "commit_observed") -eq $true) {
      [void]$failures.Add("commit_observed")
    }
    if ((Get-EvidenceField -Object $proof -Field "production_writer_replaced") -eq $true -or (Get-EvidenceField -Object $Artifact -Field "production_writer_replaced") -eq $true) {
      [void]$failures.Add("production_writer_replaced")
    }
    if ((Get-EvidenceField -Object $proof -Field "dual_commit_observed") -eq $true) {
      [void]$failures.Add("dual_commit_observed")
    }
  }

  $classification = "blocker"
  if ($failures.Count -gt 0) {
    $classification = "fail"
  } elseif ($refusals.Count -eq 0 -and [string](Get-EvidenceField -Object $Artifact -Field "classification") -eq "pass") {
    $classification = "pass"
  }

  return [ordered]@{
    schema_version = [string]$liveProbeReadbackGateContract.schema_version
    classification = $classification
    artifact_schema_version = [string](Get-EvidenceField -Object $Artifact -Field "schema_version")
    generated_at_utc = [string](Get-EvidenceField -Object $Artifact -Field "generated_at_utc")
    current_commit = [string](Get-EvidenceField -Object $Artifact -Field "current_commit")
    freshness_marker = [string](Get-EvidenceField -Object $Artifact -Field "freshness_marker")
    stale_artifact = [bool](Get-EvidenceField -Object $Artifact -Field "stale_artifact")
    probe_requested = [bool](Get-EvidenceField -Object $Artifact -Field "probe_requested")
    provenance = (Get-EvidenceField -Object $Artifact -Field "provenance")
    row_count_evidence = $rowCountEvidence
    transaction_timing_durations = $timing
    rollback_no_commit_proof = $proof
    refusals = @($refusals | Select-Object -Unique)
    failures = @($failures | Select-Object -Unique)
    pass_requirements = [ordered]@{
      rollback_observed_required = $true
      commit_observed_required = $false
      production_writer_replaced_required = $false
      dual_commit_observed_required = $false
    }
    safe_output = [ordered]@{
      database_url_output = "omitted"
      env_value_output = "omitted"
      operation_key_output = "omitted"
      raw_env_value_echoed = $false
      raw_database_url_echoed = $false
      raw_metadata_echoed = $false
      credential_material_echoed = $false
      raw_executor_error_detail_echoed = $false
    }
  }
}

function New-LiveExecutionHandoff {
  param(
    [Parameter(Mandatory = $true)][string]$Readiness,
    [Parameter(Mandatory = $true)][bool]$ProbeRequested,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Blockers
  )

  $classification = "blocker"
  if ($ProbeRequested -and $Readiness -eq "ready") {
    $classification = "pass"
  } elseif ($ProbeRequested -and $Readiness -eq "blocked") {
    $classification = "blocker"
  }

  $rowEvidenceNames = @($liveExecutionHandoffContract.row_count_evidence_names | ForEach-Object { [string]$_ })
  $timingEvidenceNames = @($liveExecutionHandoffContract.timing_evidence_names | ForEach-Object { [string]$_ })

  return [ordered]@{
    schema_version = [string]$liveExecutionHandoffContract.schema_version
    execution_mode = [string]$liveExecutionHandoffContract.execution_mode
    probe_requested = $ProbeRequested
    classification = $classification
    safe_live_probe_command = [ordered]@{
      script = [string]$liveExecutionHandoffContract.safe_live_probe_command.script
      flags = @($liveExecutionHandoffContract.safe_live_probe_command.flags | ForEach-Object { [string]$_ })
      required_env_markers = @(
        $modeEnvVar,
        $databaseUrlEnvVar,
        $featureEnvVar
      )
      env_value_output = "omitted"
      database_url_output = "presence_marker_only"
      raw_env_values_echoed = $false
    }
    expected_classification = [ordered]@{
      default_no_live_probe = [string]$liveExecutionHandoffContract.expected_classification.default_no_live_probe
      missing_live_database_url = [string]$liveExecutionHandoffContract.expected_classification.missing_live_database_url
      runtime_writer_unavailable = [string]$liveExecutionHandoffContract.expected_classification.runtime_writer_unavailable
      invalid_cutover_mode_guard = [string]$liveExecutionHandoffContract.expected_classification.invalid_cutover_mode_guard
      row_count_mismatch = [string]$liveExecutionHandoffContract.expected_classification.row_count_mismatch
      unsafe_output_detected = [string]$liveExecutionHandoffContract.expected_classification.unsafe_output_detected
      live_probe_ready = [string]$liveExecutionHandoffContract.expected_classification.live_probe_ready
    }
    row_count_evidence = [ordered]@{
      measurement_available = $false
      names = $rowEvidenceNames
      expected_rows_output = "expectation_names_only_until_probe_executor_runs"
      raw_sql_output = "omitted"
    }
    timing_evidence = [ordered]@{
      measurement_available = $false
      names = $timingEvidenceNames
      duration_ms = $null
      output = "timing_names_only_until_probe_executor_runs"
    }
    rollback_no_commit_guard = [ordered]@{
      probe_commits_billing_ledger = $false
      rollback_required_after_probe = $true
      production_writer_replaced = $false
      production_source_of_truth_switch_allowed = $false
      dual_commit_allowed = $false
      local_writer_fallback = "control_plane_local_sql_writer"
    }
    blockers = @($Blockers)
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

$liveProbeEvidenceArtifact = New-LiveProbeEvidenceArtifact -Readiness $readiness -ProbeRequested ([bool]$LiveExecutionProbe) -MeasurementsAvailable ([bool]$SimulateProbeMeasurements) -RowCountMismatch ([bool]$SimulateProbeRowCountMismatch) -StaleArtifact ([bool]$SimulateStaleProbeArtifact) -CommitObserved ([bool]$SimulateCommitObserved) -ProductionWriterReplaced ([bool]$SimulateProductionWriterReplaced) -DualCommitObserved ([bool]$SimulateDualCommitObserved) -Blockers @($blockers)
$liveProbeMeasurementReadbackGate = New-LiveProbeMeasurementReadbackGate -Artifact $liveProbeEvidenceArtifact -MissingRowCount ([bool]$SimulateMissingRowCountReadback) -MissingTiming ([bool]$SimulateMissingTimingReadback) -MissingRollbackProof ([bool]$SimulateMissingRollbackProofReadback)

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
  live_execution_handoff = (New-LiveExecutionHandoff -Readiness $readiness -ProbeRequested ([bool]$LiveExecutionProbe) -Blockers @($blockers))
  live_probe_executor_boundary = (New-LiveProbeExecutorBoundary -ProbeRequested ([bool]$LiveExecutionProbe) -Blockers @($blockers))
  live_probe_evidence_artifact = $liveProbeEvidenceArtifact
  live_probe_measurement_readback_gate = $liveProbeMeasurementReadbackGate
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
