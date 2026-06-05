param(
  [switch]$LiveCommitOptIn,
  [switch]$ExecuteLiveCommit,
  [switch]$RuntimeWriterAvailable,
  [switch]$RuntimeSchemaAvailable,
  [switch]$RuntimeToolAvailable,
  [switch]$NoDualReadbackOptIn,
  [switch]$CommitReadbackOptIn,
  [AllowNull()][string]$InputPath,
  [AllowNull()][string]$ArtifactPath,
  [AllowNull()][string]$OperationScope,
  [AllowNull()][string]$IdempotencyKey,
  [AllowNull()][string]$CurrentCommit,
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
$defaultInputPath = ".tmp/billing-ledger/runtime-writer-commit-input.json"
$binSource = Join-Path $repoRoot "crates/billing-ledger/src/bin/runtime_writer_commit.rs"

function Test-Present {
  param([AllowNull()][string]$Value)
  return -not [string]::IsNullOrWhiteSpace($Value)
}

function Test-TruthyEnv {
  param([AllowNull()][string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  return $Value.Trim().ToLowerInvariant() -in @("1", "true", "yes", "ready", "enabled")
}

function Resolve-RepoBoundedPath {
  param(
    [Parameter(Mandatory = $true)][string]$PathValue,
    [Parameter(Mandatory = $true)][string]$RequiredExtension
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
    $relative.EndsWith($RequiredExtension, [System.StringComparison]::OrdinalIgnoreCase)

  return [ordered]@{
    safe = $safe
    relative_path = $relative
    reason = if ($safe) { "allowed_repo_tmp_path" } else { "path_must_be_repo_bounded_tmp" }
    raw_path_output = "omitted"
  }
}

$artifactPathValue = if (Test-Present $ArtifactPath) { $ArtifactPath } else {
  $envPath = [Environment]::GetEnvironmentVariable("AI_CONTROL_PLANE_BILLING_LEDGER_LIVE_COMMIT_PROOF_ARTIFACT_PATH")
  if (Test-Present $envPath) { $envPath } else { $defaultArtifactPath }
}
$inputPathValue = if (Test-Present $InputPath) { $InputPath } else {
  $envPath = [Environment]::GetEnvironmentVariable("AI_CONTROL_PLANE_BILLING_LEDGER_RUNTIME_WRITER_COMMIT_INPUT_PATH")
  if (Test-Present $envPath) { $envPath } else { $defaultInputPath }
}
$operationScopeValue = if (Test-Present $OperationScope) { $OperationScope } else {
  [Environment]::GetEnvironmentVariable("AI_CONTROL_PLANE_BILLING_LEDGER_EXTERNAL_COMMIT_OPERATION_SCOPE")
}
$idempotencyKeyValue = if (Test-Present $IdempotencyKey) { $IdempotencyKey } else {
  [Environment]::GetEnvironmentVariable("AI_CONTROL_PLANE_BILLING_LEDGER_EXTERNAL_COMMIT_IDEMPOTENCY_KEY")
}
$currentCommitValue = if (Test-Present $CurrentCommit) { $CurrentCommit } else {
  [Environment]::GetEnvironmentVariable("AI_CONTROL_PLANE_BILLING_LEDGER_CURRENT_COMMIT")
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
$artifactGate = Resolve-RepoBoundedPath -PathValue $artifactPathValue -RequiredExtension ".json"
$inputGate = Resolve-RepoBoundedPath -PathValue $inputPathValue -RequiredExtension ".json"
$binSourcePresent = Test-Path -LiteralPath $binSource

$blockers = New-Object System.Collections.Generic.List[string]
if (-not [bool]$LiveCommitOptIn) { [void]$blockers.Add("live_commit_opt_in_missing") }
if (-not [bool]$ExecuteLiveCommit) { [void]$blockers.Add("execute_live_commit_opt_in_missing") }
if (-not $liveDatabaseUrlPresent) { [void]$blockers.Add("live_database_url_missing") }
if (-not $runtimeWriterAvailableValue) { [void]$blockers.Add("runtime_writer_unavailable") }
if (-not $runtimeSchemaAvailableValue) { [void]$blockers.Add("runtime_schema_unavailable") }
if (-not $runtimeToolAvailableValue) { [void]$blockers.Add("runtime_tool_unavailable") }
if (-not (Test-Present $operationScopeValue)) { [void]$blockers.Add("operation_scope_missing") }
if (-not (Test-Present $idempotencyKeyValue)) { [void]$blockers.Add("idempotency_key_missing") }
if (-not (Test-Present $currentCommitValue)) { [void]$blockers.Add("current_commit_missing") }
if (-not (Test-Present $runtimeCommitValue)) { [void]$blockers.Add("runtime_container_commit_missing") }
if ($activeWriterValue -ne $expectedWriter) { [void]$blockers.Add("active_writer_not_billing_ledger_runtime_writer") }
if ($sourceOfTruthValue -ne $expectedWriter) { [void]$blockers.Add("source_of_truth_not_billing_ledger_runtime_writer") }
if ($liveCommitReadbackValue -ne $expectedWriter) { [void]$blockers.Add("live_commit_readback_not_billing_ledger_runtime_writer") }
if (-not $noDualOptInValue) { [void]$blockers.Add("no_dual_readback_opt_in_missing") }
if (-not $commitReadbackOptInValue) { [void]$blockers.Add("commit_readback_opt_in_missing") }
if (-not [bool]$artifactGate.safe) { [void]$blockers.Add("artifact_path_not_repo_bounded") }
if (-not [bool]$inputGate.safe) { [void]$blockers.Add("input_path_not_repo_bounded") }
if (-not $binSourcePresent) { [void]$blockers.Add("runtime_writer_commit_bin_source_missing") }

$commandShape = "cargo run -p ai-gateway-billing-ledger --features postgres-sqlx --bin billing-ledger-runtime-writer-commit -- --live-commit-opt-in --no-dual-readback-opt-in --commit-readback-opt-in --input <repo-bounded .tmp json> --artifact-path .tmp/billing-ledger/live-commit-proof-artifact.json --operation-scope <scope> --idempotency-key <key> --current-commit <commit> --runtime-container-commit <commit> --active-writer billing_ledger_runtime_writer --source-of-truth billing_ledger_runtime_writer --live-commit-readback billing_ledger_runtime_writer"
$runner = [ordered]@{
  requested = [bool]$ExecuteLiveCommit
  executed = $false
  classification = if ([bool]$ExecuteLiveCommit) { "blocked_before_execution" } else { "not_requested" }
  reason = if ($blockers.Count -gt 0) { ($blockers | Select-Object -First 1) } else { "ready_not_executed" }
  exit_code = "not_run"
  stdout_output = "omitted"
  stderr_output = "omitted"
  raw_command_echoed = $false
}

if ([bool]$ExecuteLiveCommit -and $blockers.Count -eq 0) {
  $artifactFullPath = Join-Path $repoRoot ([string]$artifactGate.relative_path)
  $inputFullPath = Join-Path $repoRoot ([string]$inputGate.relative_path)
  $runnerLogDir = Join-Path $repoRoot ".tmp\billing-ledger"
  New-Item -ItemType Directory -Force -Path $runnerLogDir | Out-Null
  $runnerStdout = Join-Path $runnerLogDir "callable-runtime-writer.stdout.omitted"
  $runnerStderr = Join-Path $runnerLogDir "callable-runtime-writer.stderr.omitted"
  $arguments = @(
    "run", "-p", "ai-gateway-billing-ledger", "--features", "postgres-sqlx",
    "--bin", "billing-ledger-runtime-writer-commit", "--",
    "--live-commit-opt-in",
    "--no-dual-readback-opt-in",
    "--commit-readback-opt-in",
    "--input", $inputFullPath,
    "--artifact-path", $artifactFullPath,
    "--operation-scope", $operationScopeValue,
    "--idempotency-key", $idempotencyKeyValue,
    "--current-commit", $currentCommitValue,
    "--runtime-container-commit", $runtimeCommitValue,
    "--active-writer", $activeWriterValue,
    "--source-of-truth", $sourceOfTruthValue,
    "--live-commit-readback", $liveCommitReadbackValue
  )
  try {
    $process = Start-Process -FilePath "cargo" `
      -ArgumentList $arguments `
      -WorkingDirectory $repoRoot `
      -Wait `
      -PassThru `
      -WindowStyle Hidden `
      -RedirectStandardOutput $runnerStdout `
      -RedirectStandardError $runnerStderr
    $runner.executed = $true
    $runner.exit_code = [int]$process.ExitCode
    $runner.classification = if ([int]$process.ExitCode -eq 0) { "live_commit_runner_executed" } else { "live_commit_runner_failed" }
    $runner.reason = if ([int]$process.ExitCode -eq 0) { "artifact_readback_required" } else { "runner_exit_nonzero" }
  } finally {
    Remove-Item -LiteralPath $runnerStdout -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $runnerStderr -Force -ErrorAction SilentlyContinue
  }
}

$artifactExists = $false
if ([bool]$artifactGate.safe) {
  $artifactExists = Test-Path -LiteralPath (Join-Path $repoRoot ([string]$artifactGate.relative_path))
}

$result = [ordered]@{
  schema_version = "control_plane_billing_ledger_callable_runtime_writer_boundary.v1"
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  classification = if ([bool]$ExecuteLiveCommit) { if ($blockers.Count -eq 0) { "live_commit_invoked" } else { "blocked" } } else { "dry_run_refusal_ready" }
  default_db_write = $false
  script_performs_cutover = $false
  accepted_artifact_written_by_wrapper = $false
  simulated_evidence_generated = $false
  final_x_eligible = $false
  callable_boundary = [ordered]@{
    bin_name = "billing-ledger-runtime-writer-commit"
    bin_source_present = $binSourcePresent
    calls = "execute_consistent_ledger_postgres_sqlx_writer_plan"
    package = "ai-gateway-billing-ledger"
    required_features = @("postgres-sqlx")
    supports_operation = "reserve_bounded_paid_ledger_commit"
  }
  command_shape = $commandShape
  required_env_markers = @(
    "BILLING_LEDGER_LIVE_DATABASE_URL",
    "AI_CONTROL_PLANE_BILLING_LEDGER_RUNTIME_WRITER_AVAILABLE",
    "AI_CONTROL_PLANE_BILLING_LEDGER_RUNTIME_SCHEMA_AVAILABLE",
    "AI_CONTROL_PLANE_BILLING_LEDGER_RUNTIME_TOOL_AVAILABLE",
    "AI_CONTROL_PLANE_BILLING_LEDGER_RUNTIME_CONTAINER_COMMIT",
    "AI_CONTROL_PLANE_BILLING_LEDGER_ACTIVE_WRITER",
    "AI_CONTROL_PLANE_BILLING_LEDGER_SOURCE_OF_TRUTH",
    "AI_CONTROL_PLANE_BILLING_LEDGER_LIVE_COMMIT_READBACK",
    "AI_CONTROL_PLANE_BILLING_LEDGER_EXTERNAL_COMMIT_OPERATION_SCOPE",
    "AI_CONTROL_PLANE_BILLING_LEDGER_EXTERNAL_COMMIT_IDEMPOTENCY_KEY",
    "AI_CONTROL_PLANE_BILLING_LEDGER_NO_DUAL_READBACK_OPT_IN",
    "AI_CONTROL_PLANE_BILLING_LEDGER_COMMIT_READBACK_OPT_IN",
    "AI_CONTROL_PLANE_BILLING_LEDGER_RUNTIME_WRITER_COMMIT_INPUT_PATH"
  )
  input_path_gate = $inputGate
  artifact_path_gate = $artifactGate
  artifact_state = [ordered]@{
    exists = $artifactExists
    accepted_artifact_written_by_wrapper = $false
    artifact_content_echoed = $false
  }
  expected_input_schema = [ordered]@{
    operation = "reserve"
    required_fields = @("tenant_id", "wallet_id", "request_id", "amount", "currency", "available_balance")
    operator_context_fields = @("operation_scope", "idempotency_key", "source", "artifact_path")
    optional_fields = @("project_id", "virtual_key_id", "user_id", "budgets")
    money_scale = 8
  }
  expected_artifact_schema = [ordered]@{
    schema_version = "control_plane_billing_ledger_live_commit_proof_artifact.v1"
    measurement_source = "external_controlled_runtime_writer_commit"
    generated_by_this_script = $false
    simulated = $false
    runner_origin = "external_runtime_writer_commit_runner"
    required_row_count_statement_kinds = @("insert_runtime_writer_commit_ledger_entry", "mark_runtime_writer_commit_idempotency")
    required_commit_marker = "runtime_writer_commit_observed=true"
    required_no_dual_marker = "dual_commit_observed=false"
    secret_policy = "secrets_omitted"
  }
  action_plan = @(
    [ordered]@{ step = "prepare_input"; side_effect = "none"; detail = "write reserve commit input JSON under .tmp/billing-ledger" },
    [ordered]@{ step = "preflight"; side_effect = "none"; checks = @("live_db_env", "runtime_writer_markers", "repo_bounded_paths", "idempotency_key", "no_dual_readback_opt_in") },
    [ordered]@{ step = "live_commit"; side_effect = "one_bounded_paid_ledger_commit_only_with_explicit_opt_in"; command_shape = $commandShape },
    [ordered]@{ step = "readback"; side_effect = "none"; command = "powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_billing_ledger_runtime_writer_readiness.ps1 -ReadLiveCommitProofArtifact -LiveCommitProofArtifactPath .tmp/billing-ledger/live-commit-proof-artifact.json -SingleWriterCutoverProof -LiveCommitProof" }
  )
  blockers = @($blockers)
  first_blocker = ($blockers | Select-Object -First 1)
  runner = $runner
  next_short_operator_command = "powershell -NoProfile -ExecutionPolicy Bypass -File scripts/operator/e9_billing_ledger_callable_runtime_writer_boundary.ps1"
  safety = [ordered]@{
    raw_database_url_echoed = $false
    raw_env_values_echoed = $false
    raw_command_output_echoed = $false
    db_write_attempted_by_default = $false
    production_cutover_attempted = $false
  }
}

$result | ConvertTo-Json -Depth 8

if ([bool]$ExecuteLiveCommit -and $blockers.Count -gt 0) {
  exit $BlockedExitCode
}
