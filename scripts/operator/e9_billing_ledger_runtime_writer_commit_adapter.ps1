param(
  [switch]$LiveCommitOptIn,
  [switch]$RuntimeWriterAvailable,
  [switch]$RuntimeSchemaAvailable,
  [switch]$RuntimeToolAvailable,
  [switch]$NoDualReadbackOptIn,
  [switch]$CommitReadbackOptIn,
  [AllowNull()][string]$ArtifactPath,
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
  param([Parameter(Mandatory = $true)][string]$PathValue)

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

$detectedCapabilities = [ordered]@{
  billing_ledger_rust_sqlx_writer_function_present = Test-Path -LiteralPath (Join-Path $repoRoot "crates/billing-ledger/src/postgres_execution.rs")
  billing_ledger_rust_sqlx_writer_function = "execute_consistent_ledger_postgres_sqlx_writer_plan"
  billing_ledger_rust_sqlx_writer_function_reference = "crates/billing-ledger/src/postgres_execution.rs:809"
  billing_ledger_rust_sqlx_writer_function_is_operator_cli = $false
  control_plane_local_execute_path_present = Test-Path -LiteralPath (Join-Path $repoRoot "apps/control-plane/src/admin.rs")
  control_plane_local_execute_path = "/admin/ledger/adjustments/dry-run mode=execute -> execute_ledger_adjustment"
  control_plane_local_execute_path_reference = "apps/control-plane/src/admin.rs:2140,2747"
  control_plane_local_execute_path_is_external_runtime_runner = $false
  repo_bounded_operator_cli_present = $false
  external_runner_artifact_writer_present = $false
  callable_boundary_classification = "missing_operator_callable_writer_boundary"
}

$requiredEnvMarkers = @(
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
  "AI_CONTROL_PLANE_BILLING_LEDGER_LIVE_COMMIT_PROOF_ARTIFACT_PATH",
  "AI_CONTROL_PLANE_BILLING_LEDGER_NO_DUAL_READBACK_OPT_IN",
  "AI_CONTROL_PLANE_BILLING_LEDGER_COMMIT_READBACK_OPT_IN"
)

$expectedArtifactSchema = [ordered]@{
  schema_version = "control_plane_billing_ledger_live_commit_proof_artifact.v1"
  measurement_source = "external_controlled_runtime_writer_commit"
  generated_by_this_script = $false
  simulated = $false
  artifact_origin = "external_runtime_writer_commit_runner"
  required_row_count_statement_kinds = @("insert_runtime_writer_commit_ledger_entry", "mark_runtime_writer_commit_idempotency")
  required_commit_marker = "runtime_writer_commit_observed=true"
  required_no_dual_marker = "dual_commit_observed=false"
  required_secret_policy = "secrets_omitted"
}

$minimalMissingBoundary = [ordered]@{
  missing = @(
    "repo_bounded_operator_cli_or_endpoint_for_external_runtime_writer_commit",
    "callable_wrapper_for_execute_consistent_ledger_postgres_sqlx_writer_plan_or_equivalent_control_plane_runtime_writer",
    "accepted_artifact_writer_for_control_plane_billing_ledger_live_commit_proof_artifact_v1",
    "readback_no_dual_probe_bound_to_same_idempotency_key"
  )
  implementation_target = "E9-004-S68 Callable Runtime Writer Boundary Implementation"
  required_behavior = @(
    "default_dry_run_refusal",
    "explicit_live_db_env_required",
    "runtime_writer_schema_tool_markers_required",
    "operation_scope_and_idempotency_key_required",
    "single_live_commit_through_billing_ledger_runtime_writer",
    "row_count_proof_captured",
    "commit_observed_readback_captured",
    "no_dual_commit_proof_captured",
    "secret_safe_output_only",
    "write_accepted_artifact_to_repo_bounded_tmp_json"
  )
}

$actionPlan = @(
  [ordered]@{
    step = "dry_run_adapter_preflight"
    side_effect = "none"
    checks = @("env_presence", "repo_bounded_artifact_path", "operation_scope", "idempotency_key", "runtime_writer_markers")
  },
  [ordered]@{
    step = "blocked_live_invocation"
    side_effect = "none"
    reason = "callable_runtime_writer_boundary_missing"
    detail = "Existing library/API paths do not yet expose a repo-bounded external runner that writes accepted proof artifact."
  },
  [ordered]@{
    step = "future_callable_boundary"
    side_effect = "one_bounded_live_commit_only_after_explicit_opt_in"
    target = "execute_consistent_ledger_postgres_sqlx_writer_plan_or_equivalent_control_plane_runtime_writer_boundary"
  },
  [ordered]@{
    step = "readback"
    side_effect = "none"
    command = "powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_billing_ledger_runtime_writer_readiness.ps1 -ReadLiveCommitProofArtifact -LiveCommitProofArtifactPath .tmp/billing-ledger/live-commit-proof-artifact.json -SingleWriterCutoverProof -LiveCommitProof"
  }
)

$blockers = New-Object System.Collections.Generic.List[string]
if (-not [bool]$LiveCommitOptIn) { [void]$blockers.Add("live_commit_opt_in_missing") }
if (-not $liveDatabaseUrlPresent) { [void]$blockers.Add("live_database_url_missing") }
if (-not $runtimeWriterAvailableValue) { [void]$blockers.Add("runtime_writer_unavailable") }
if (-not $runtimeSchemaAvailableValue) { [void]$blockers.Add("runtime_schema_unavailable") }
if (-not $runtimeToolAvailableValue) { [void]$blockers.Add("runtime_tool_unavailable") }
if (-not (Test-Present $operationScopeValue)) { [void]$blockers.Add("operation_scope_missing") }
if (-not (Test-Present $idempotencyKeyValue)) { [void]$blockers.Add("idempotency_key_missing") }
if (-not (Test-Present $runtimeCommitValue)) { [void]$blockers.Add("runtime_container_commit_missing") }
if ($activeWriterValue -ne $expectedWriter) { [void]$blockers.Add("active_writer_not_billing_ledger_runtime_writer") }
if ($sourceOfTruthValue -ne $expectedWriter) { [void]$blockers.Add("source_of_truth_not_billing_ledger_runtime_writer") }
if ($liveCommitReadbackValue -ne $expectedWriter) { [void]$blockers.Add("live_commit_readback_not_billing_ledger_runtime_writer") }
if (-not $noDualOptInValue) { [void]$blockers.Add("no_dual_readback_opt_in_missing") }
if (-not $commitReadbackOptInValue) { [void]$blockers.Add("commit_readback_opt_in_missing") }
if (-not [bool]$pathGate.safe) { [void]$blockers.Add([string]$pathGate.reason) }
[void]$blockers.Add("callable_runtime_writer_boundary_missing")

$artifactExists = $false
if ([bool]$pathGate.safe) {
  $artifactFullPath = Join-Path $repoRoot ([string]$pathGate.relative_path)
  $artifactExists = Test-Path -LiteralPath $artifactFullPath
}

$classification = if ([bool]$LiveCommitOptIn) { "blocked" } else { "dry_run_refusal_ready" }
$result = [ordered]@{
  schema_version = "control_plane_billing_ledger_runtime_writer_commit_invocation_adapter.v1"
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  classification = $classification
  default_db_write = $false
  script_performs_cutover = $false
  accepted_artifact_written = $false
  simulated_evidence_generated = $false
  final_x_eligible = $false
  detected_capabilities = $detectedCapabilities
  required_env_markers = $requiredEnvMarkers
  live_inputs = [ordered]@{
    live_database_url_present = $liveDatabaseUrlPresent
    runtime_writer_available = $runtimeWriterAvailableValue
    runtime_schema_available = $runtimeSchemaAvailableValue
    runtime_tool_available = $runtimeToolAvailableValue
    operation_scope_present = Test-Present $operationScopeValue
    idempotency_key_present = Test-Present $idempotencyKeyValue
    runtime_container_commit_present = Test-Present $runtimeCommitValue
    active_writer_marker = if (Test-Present $activeWriterValue) { $activeWriterValue } else { "missing" }
    source_of_truth_marker = if (Test-Present $sourceOfTruthValue) { $sourceOfTruthValue } else { "missing" }
    live_commit_readback_marker = if (Test-Present $liveCommitReadbackValue) { $liveCommitReadbackValue } else { "missing" }
    no_dual_readback_opt_in = $noDualOptInValue
    commit_readback_opt_in = $commitReadbackOptInValue
  }
  artifact_path_gate = $pathGate
  artifact_state = [ordered]@{
    exists = $artifactExists
    accepted_artifact_written_by_this_script = $false
    artifact_content_echoed = $false
  }
  expected_artifact_schema = $expectedArtifactSchema
  minimal_missing_boundary = $minimalMissingBoundary
  blockers = @($blockers)
  first_blocker = ($blockers | Select-Object -First 1)
  action_plan = $actionPlan
  s66_external_runner_command_shape = "powershell -NoProfile -ExecutionPolicy Bypass -File scripts/operator/e9_billing_ledger_external_commit_proof_producer.ps1 -LiveCommitOptIn -ExecuteExternalRunner -RuntimeWriterAvailable -RuntimeSchemaAvailable -RuntimeToolAvailable -NoDualReadbackOptIn -CommitReadbackOptIn -OperationScope <scope> -IdempotencyKey <key> -RuntimeContainerCommit <commit> -ActiveWriterMarker billing_ledger_runtime_writer -SourceOfTruthMarker billing_ledger_runtime_writer -LiveCommitReadbackMarker billing_ledger_runtime_writer"
  next_short_operator_command = "powershell -NoProfile -ExecutionPolicy Bypass -File scripts/operator/e9_billing_ledger_runtime_writer_commit_adapter.ps1"
  readback_command = "powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_billing_ledger_runtime_writer_readiness.ps1 -ReadLiveCommitProofArtifact -LiveCommitProofArtifactPath .tmp/billing-ledger/live-commit-proof-artifact.json -SingleWriterCutoverProof -LiveCommitProof"
  safety = [ordered]@{
    secrets_echoed = $false
    raw_database_url_echoed = $false
    raw_command_output_echoed = $false
    db_write_attempted = $false
    production_cutover_attempted = $false
  }
}

$result | ConvertTo-Json -Depth 8

if ([bool]$LiveCommitOptIn) {
  exit $BlockedExitCode
}
