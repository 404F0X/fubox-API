param(
  [switch]$LiveCommitOptIn,
  [switch]$ExecuteExternalRunner,
  [switch]$RuntimeWriterAvailable,
  [switch]$RuntimeSchemaAvailable,
  [switch]$RuntimeToolAvailable,
  [switch]$NoDualReadbackOptIn,
  [switch]$CommitReadbackOptIn,
  [AllowNull()][string]$ArtifactPath,
  [AllowNull()][string]$ExternalRunnerCommand,
  [AllowNull()][string]$OperationScope,
  [AllowNull()][string]$IdempotencyKey,
  [AllowNull()][string]$RuntimeContainerCommit,
  [AllowNull()][string]$ActiveWriterMarker,
  [AllowNull()][string]$SourceOfTruthMarker,
  [AllowNull()][string]$LiveCommitReadbackMarker,
  [int]$BlockedExitCode = 2
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$expectedWriter = "billing_ledger_runtime_writer"
$defaultArtifactPath = ".tmp/billing-ledger/live-commit-proof-artifact.json"

function Test-TruthyEnv {
  param([AllowNull()][string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $false
  }

  return $Value.Trim().ToLowerInvariant() -in @("1", "true", "yes", "ready", "enabled")
}

function Test-Present {
  param([AllowNull()][string]$Value)
  return -not [string]::IsNullOrWhiteSpace($Value)
}

function Resolve-RepoBoundedJsonPath {
  param(
    [Parameter(Mandatory = $true)][string]$PathValue
  )

  $candidate = if ([System.IO.Path]::IsPathRooted($PathValue)) {
    [System.IO.Path]::GetFullPath($PathValue)
  } else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $PathValue))
  }
  $repoFull = [System.IO.Path]::GetFullPath($repoRoot)
  $relative = [System.IO.Path]::GetRelativePath($repoFull, $candidate)
  $safe = -not $relative.StartsWith("..") -and
    -not [System.IO.Path]::IsPathRooted($relative) -and
    $relative.Replace("\", "/").StartsWith(".tmp/") -and
    $relative.EndsWith(".json", [System.StringComparison]::OrdinalIgnoreCase)

  return [ordered]@{
    safe = $safe
    relative_path = $relative
    reason = if ($safe) { "allowed_repo_tmp_json_path" } else { "artifact_path_must_be_repo_bounded_tmp_json" }
    raw_path_output = "omitted"
  }
}

$artifactPathValue = if (Test-Present $ArtifactPath) { $ArtifactPath } else {
  $envPath = [Environment]::GetEnvironmentVariable("AI_CONTROL_PLANE_BILLING_LEDGER_LIVE_COMMIT_PROOF_ARTIFACT_PATH")
  if (Test-Present $envPath) { $envPath } else { $defaultArtifactPath }
}
$externalRunnerCommandValue = if (Test-Present $ExternalRunnerCommand) { $ExternalRunnerCommand } else {
  [Environment]::GetEnvironmentVariable("AI_CONTROL_PLANE_BILLING_LEDGER_EXTERNAL_COMMIT_RUNNER_COMMAND")
}
$operationScopeValue = if (Test-Present $OperationScope) { $OperationScope } else {
  [Environment]::GetEnvironmentVariable("AI_CONTROL_PLANE_BILLING_LEDGER_EXTERNAL_COMMIT_OPERATION_SCOPE")
}
$idempotencyKeyValue = if (Test-Present $IdempotencyKey) { $IdempotencyKey } else {
  [Environment]::GetEnvironmentVariable("AI_CONTROL_PLANE_BILLING_LEDGER_EXTERNAL_COMMIT_IDEMPOTENCY_KEY")
}
$runtimeCommitValue = if (Test-Present $RuntimeContainerCommit) { $RuntimeContainerCommit } else {
  [Environment]::GetEnvironmentVariable("AI_CONTROL_PLANE_BILLING_LEDGER_RUNTIME_CONTAINER_COMMIT")
}
$activeWriterValue = if (Test-Present $ActiveWriterMarker) { $ActiveWriterMarker } else {
  [Environment]::GetEnvironmentVariable("AI_CONTROL_PLANE_BILLING_LEDGER_ACTIVE_WRITER")
}
$sourceOfTruthValue = if (Test-Present $SourceOfTruthMarker) { $SourceOfTruthMarker } else {
  [Environment]::GetEnvironmentVariable("AI_CONTROL_PLANE_BILLING_LEDGER_SOURCE_OF_TRUTH")
}
$liveCommitReadbackValue = if (Test-Present $LiveCommitReadbackMarker) { $LiveCommitReadbackMarker } else {
  [Environment]::GetEnvironmentVariable("AI_CONTROL_PLANE_BILLING_LEDGER_LIVE_COMMIT_READBACK")
}

$liveDatabaseUrlPresent = (Test-Present ([Environment]::GetEnvironmentVariable("BILLING_LEDGER_LIVE_DATABASE_URL"))) -or
  (Test-Present ([Environment]::GetEnvironmentVariable("DATABASE_URL")))
$runtimeWriterAvailableValue = [bool]$RuntimeWriterAvailable -or (Test-TruthyEnv ([Environment]::GetEnvironmentVariable("AI_CONTROL_PLANE_BILLING_LEDGER_RUNTIME_WRITER_AVAILABLE")))
$runtimeSchemaAvailableValue = [bool]$RuntimeSchemaAvailable -or (Test-TruthyEnv ([Environment]::GetEnvironmentVariable("AI_CONTROL_PLANE_BILLING_LEDGER_RUNTIME_SCHEMA_AVAILABLE")))
$runtimeToolAvailableValue = [bool]$RuntimeToolAvailable -or (Test-TruthyEnv ([Environment]::GetEnvironmentVariable("AI_CONTROL_PLANE_BILLING_LEDGER_RUNTIME_TOOL_AVAILABLE")))
$noDualOptInValue = [bool]$NoDualReadbackOptIn -or (Test-TruthyEnv ([Environment]::GetEnvironmentVariable("AI_CONTROL_PLANE_BILLING_LEDGER_NO_DUAL_READBACK_OPT_IN")))
$commitReadbackOptInValue = [bool]$CommitReadbackOptIn -or (Test-TruthyEnv ([Environment]::GetEnvironmentVariable("AI_CONTROL_PLANE_BILLING_LEDGER_COMMIT_READBACK_OPT_IN")))
$pathGate = Resolve-RepoBoundedJsonPath -PathValue $artifactPathValue

$requiredEnvMarkers = @(
  "BILLING_LEDGER_LIVE_DATABASE_URL",
  "AI_CONTROL_PLANE_BILLING_LEDGER_RUNTIME_WRITER_AVAILABLE",
  "AI_CONTROL_PLANE_BILLING_LEDGER_RUNTIME_SCHEMA_AVAILABLE",
  "AI_CONTROL_PLANE_BILLING_LEDGER_RUNTIME_TOOL_AVAILABLE",
  "AI_CONTROL_PLANE_BILLING_LEDGER_RUNTIME_CONTAINER_COMMIT",
  "AI_CONTROL_PLANE_BILLING_LEDGER_ACTIVE_WRITER",
  "AI_CONTROL_PLANE_BILLING_LEDGER_SOURCE_OF_TRUTH",
  "AI_CONTROL_PLANE_BILLING_LEDGER_LIVE_COMMIT_READBACK",
  "AI_CONTROL_PLANE_BILLING_LEDGER_LIVE_COMMIT_PROOF_ARTIFACT_PATH",
  "AI_CONTROL_PLANE_BILLING_LEDGER_EXTERNAL_COMMIT_RUNNER_COMMAND",
  "AI_CONTROL_PLANE_BILLING_LEDGER_EXTERNAL_COMMIT_OPERATION_SCOPE",
  "AI_CONTROL_PLANE_BILLING_LEDGER_EXTERNAL_COMMIT_IDEMPOTENCY_KEY",
  "AI_CONTROL_PLANE_BILLING_LEDGER_NO_DUAL_READBACK_OPT_IN",
  "AI_CONTROL_PLANE_BILLING_LEDGER_COMMIT_READBACK_OPT_IN"
)

$requiredArtifactFields = @(
  "schema_version",
  "generated_at_utc",
  "current_commit",
  "runtime_container_commit",
  "measurement_source",
  "generated_by_this_script",
  "simulated",
  "live_commit_readback",
  "active_writer",
  "source_of_truth",
  "single_active_writer_count",
  "row_count_proof",
  "commit_proof",
  "runner_provenance",
  "no_dual_commit_proof"
)

$actionPlan = @(
  [ordered]@{
    step = "preflight"
    side_effect = "none"
    checks = @("env_presence", "repo_bounded_artifact_path", "runtime_writer_markers", "no_dual_readback_opt_in", "commit_readback_opt_in")
  },
  [ordered]@{
    step = "external_runner"
    side_effect = "possible_live_commit_only_with_explicit_opt_in"
    command_source = "AI_CONTROL_PLANE_BILLING_LEDGER_EXTERNAL_COMMIT_RUNNER_COMMAND"
    required_output = ".tmp/billing-ledger/live-commit-proof-artifact.json"
  },
  [ordered]@{
    step = "readback"
    side_effect = "none"
    command = "powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_billing_ledger_runtime_writer_readiness.ps1 -ReadLiveCommitProofArtifact -LiveCommitProofArtifactPath .tmp/billing-ledger/live-commit-proof-artifact.json -SingleWriterCutoverProof -LiveCommitProof"
  }
)

$blockers = New-Object System.Collections.Generic.List[string]
if (-not [bool]$LiveCommitOptIn) { [void]$blockers.Add("live_commit_opt_in_missing") }
if (-not [bool]$ExecuteExternalRunner) { [void]$blockers.Add("execute_external_runner_opt_in_missing") }
if (-not $liveDatabaseUrlPresent) { [void]$blockers.Add("live_database_url_missing") }
if (-not $runtimeWriterAvailableValue) { [void]$blockers.Add("runtime_writer_unavailable") }
if (-not $runtimeSchemaAvailableValue) { [void]$blockers.Add("runtime_schema_unavailable") }
if (-not $runtimeToolAvailableValue) { [void]$blockers.Add("runtime_tool_unavailable") }
if (-not (Test-Present $operationScopeValue)) { [void]$blockers.Add("operation_scope_missing") }
if (-not (Test-Present $idempotencyKeyValue)) { [void]$blockers.Add("idempotency_key_missing") }
if (-not (Test-Present $externalRunnerCommandValue)) { [void]$blockers.Add("external_runner_command_missing") }
if (-not (Test-Present $runtimeCommitValue)) { [void]$blockers.Add("runtime_container_commit_missing") }
if ($activeWriterValue -ne $expectedWriter) { [void]$blockers.Add("active_writer_not_billing_ledger_runtime_writer") }
if ($sourceOfTruthValue -ne $expectedWriter) { [void]$blockers.Add("source_of_truth_not_billing_ledger_runtime_writer") }
if ($liveCommitReadbackValue -ne $expectedWriter) { [void]$blockers.Add("live_commit_readback_not_billing_ledger_runtime_writer") }
if (-not $noDualOptInValue) { [void]$blockers.Add("no_dual_readback_opt_in_missing") }
if (-not $commitReadbackOptInValue) { [void]$blockers.Add("commit_readback_opt_in_missing") }
if (-not [bool]$pathGate.safe) { [void]$blockers.Add([string]$pathGate.reason) }

$classification = "dry_run_ready"
$externalRunnerExecuted = $false
if ([bool]$LiveCommitOptIn -or [bool]$ExecuteExternalRunner) {
  $classification = if ($blockers.Count -eq 0) { "live_external_runner_ready" } else { "blocked" }
}

$runnerExecution = [ordered]@{
  requested = [bool]$ExecuteExternalRunner
  executed = $false
  classification = if ([bool]$ExecuteExternalRunner) { "blocked_before_execution" } else { "not_requested" }
  reason = if ([bool]$ExecuteExternalRunner) { ($blockers | Select-Object -First 1) } else { "execute_external_runner_opt_in_missing" }
  exit_code = "not_run"
  external_command_output = "omitted"
  raw_command_echoed = $false
}

if ([bool]$ExecuteExternalRunner -and $blockers.Count -eq 0) {
  $runnerLogDir = Join-Path $repoRoot ".tmp\billing-ledger"
  New-Item -ItemType Directory -Force -Path $runnerLogDir | Out-Null
  $runnerStdout = Join-Path $runnerLogDir "external-commit-runner.stdout.omitted"
  $runnerStderr = Join-Path $runnerLogDir "external-commit-runner.stderr.omitted"
  try {
    $runnerProcess = Start-Process -FilePath "cmd.exe" `
      -ArgumentList @("/c", $externalRunnerCommandValue) `
      -Wait `
      -PassThru `
      -WindowStyle Hidden `
      -RedirectStandardOutput $runnerStdout `
      -RedirectStandardError $runnerStderr
    $runnerExecution.executed = $true
    $runnerExecution.exit_code = [int]$runnerProcess.ExitCode
    $runnerExecution.classification = if ([int]$runnerProcess.ExitCode -eq 0) { "external_runner_executed" } else { "external_runner_failed" }
    $runnerExecution.reason = if ([int]$runnerProcess.ExitCode -eq 0) { "external_runner_exit_zero_artifact_readback_required" } else { "external_runner_exit_nonzero" }
  } catch {
    $runnerExecution.executed = $false
    $runnerExecution.classification = "external_runner_start_failed"
    $runnerExecution.reason = "external_runner_start_failed"
  } finally {
    Remove-Item -LiteralPath $runnerStdout -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $runnerStderr -Force -ErrorAction SilentlyContinue
  }
}

$artifactExists = $false
if ([bool]$pathGate.safe) {
  $artifactFullPath = Join-Path $repoRoot ([string]$pathGate.relative_path)
  $artifactExists = Test-Path -LiteralPath $artifactFullPath
}

$result = [ordered]@{
  schema_version = "control_plane_billing_ledger_external_commit_proof_producer_boundary.v1"
  generated_at_utc = [DateTimeOffset]::UtcNow.ToString("o")
  mode = if ([bool]$LiveCommitOptIn) { "live_commit_opt_in" } else { "safe_dry_run" }
  classification = $classification
  default_db_write = $false
  script_performs_cutover = $false
  script_generates_accepted_evidence = $false
  live_commit_requires_external_runner = $true
  expected_artifact = [ordered]@{
    path = [string]$pathGate.relative_path
    path_safe = [bool]$pathGate.safe
    exists = $artifactExists
    schema_version = "control_plane_billing_ledger_live_commit_proof_artifact.v1"
    required_fields = $requiredArtifactFields
    required_measurement_source = "external_controlled_runtime_writer_commit"
    generated_by_this_script_required = $false
    simulated_required = $false
    required_row_count_statement_kinds = @("insert_runtime_writer_commit_ledger_entry", "mark_runtime_writer_commit_idempotency")
    required_commit_observed = $true
    required_no_dual = $true
    required_secret_safe_omission = $true
  }
  required_env_markers = $requiredEnvMarkers
  env_presence = [ordered]@{
    live_database_url_present = $liveDatabaseUrlPresent
    runtime_writer_available = $runtimeWriterAvailableValue
    runtime_schema_available = $runtimeSchemaAvailableValue
    runtime_tool_available = $runtimeToolAvailableValue
    operation_scope_present = (Test-Present $operationScopeValue)
    idempotency_key_present = (Test-Present $idempotencyKeyValue)
    external_runner_command_present = (Test-Present $externalRunnerCommandValue)
    runtime_container_commit_present = (Test-Present $runtimeCommitValue)
    active_writer_marker_ok = ($activeWriterValue -eq $expectedWriter)
    source_of_truth_marker_ok = ($sourceOfTruthValue -eq $expectedWriter)
    live_commit_readback_marker_ok = ($liveCommitReadbackValue -eq $expectedWriter)
    no_dual_readback_opt_in = $noDualOptInValue
    commit_readback_opt_in = $commitReadbackOptInValue
  }
  action_plan = $actionPlan
  runner_execution = $runnerExecution
  blockers = @($blockers | Select-Object -Unique)
  readback_command = "powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_billing_ledger_runtime_writer_readiness.ps1 -ReadLiveCommitProofArtifact -LiveCommitProofArtifactPath .tmp/billing-ledger/live-commit-proof-artifact.json -SingleWriterCutoverProof -LiveCommitProof"
  remaining_final_x_blockers = @(
    "cutover_evidence_artifact_missing",
    "post_cutover_readback_missing",
    "rollback_proof_missing"
  )
  safe_output = [ordered]@{
    database_url_output = "omitted"
    env_value_output = "omitted"
    idempotency_key_output = "omitted"
    operation_scope_output = "presence_marker_only"
    external_runner_command_output = "omitted"
    raw_env_value_echoed = $false
    raw_database_url_echoed = $false
    credential_material_echoed = $false
    raw_runner_output_echoed = $false
  }
}

$result | ConvertTo-Json -Depth 12

if ($classification -eq "blocked") {
  exit $BlockedExitCode
}
