param(
  [switch]$Live,
  [switch]$LiveExecutionProbe,
  [switch]$RunLiveDbExecutorProbe,
  [switch]$ExecuteRollbackOnlyLiveProbe,
  [switch]$AttemptRealLiveDbProbe,
  [switch]$ShadowCommitHandoff,
  [switch]$AcceptProductionCutover,
  [switch]$LiveCommitProof,
  [switch]$AcknowledgeRollbackPlan,
  [switch]$SingleWriterCutoverProof,
  [AllowNull()][string]$ActiveWriterMarker,
  [AllowNull()][string]$RuntimeContainerCommitMarker,
  [AllowNull()][string]$LiveCommitReadbackMarker,
  [AllowNull()][string]$SourceOfTruthMarker,
  [switch]$SimulateProbeMeasurements,
  [switch]$SimulateProbeRowCountMismatch,
  [switch]$SimulateStaleProbeArtifact,
  [switch]$SimulateMissingRowCountReadback,
  [switch]$SimulateMissingTimingReadback,
  [switch]$SimulateMissingRollbackProofReadback,
  [switch]$SimulateCommitObserved,
  [switch]$SimulateProductionWriterReplaced,
  [switch]$SimulateDualCommitObserved,
  [switch]$SimulateRawSqlOutput,
  [switch]$WriteProbeArtifact,
  [switch]$ReadProbeArtifact,
  [AllowNull()][string]$ArtifactPath,
  [switch]$WriteLiveCommitProofArtifact,
  [switch]$ReadLiveCommitProofArtifact,
  [AllowNull()][string]$LiveCommitProofArtifactPath,
  [switch]$ReadCutoverEvidenceArtifact,
  [AllowNull()][string]$CutoverEvidenceArtifactPath,
  [switch]$SimulateAcceptedCutoverEvidenceShape,
  [switch]$PlanRuntimeWriterCommitRunner,
  [switch]$RunRuntimeWriterCommitRunner,
  [switch]$SelfTestRuntimeWriterCommitRunnerArtifactAcceptance,
  [switch]$SelfTestCanonicalCutoverArtifactGuard,
  [switch]$RuntimeWriterAvailable,
  [switch]$RuntimeSchemaAvailable,
  [switch]$RuntimeToolAvailable,
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
$shadowCommitHandoffContract = $readinessContract.shadow_commit_handoff_contract
$productionCutoverAcceptanceGateContract = $readinessContract.production_cutover_acceptance_gate_contract
$runtimeEvidenceTrustGateContract = $readinessContract.runtime_evidence_trust_gate_contract
$liveCommitProofArtifactContract = $readinessContract.live_commit_proof_artifact_contract
$liveCommitProofReadbackBoundaryContract = $readinessContract.live_commit_proof_readback_boundary_contract
$runtimeWriterCommitRunnerCommandContract = $readinessContract.runtime_writer_commit_runner_command_contract
$runtimeWriterCommitRunnerArtifactHandoffContract = $readinessContract.runtime_writer_commit_runner_artifact_handoff_contract
$cutoverFinalDoDChecklistContract = $readinessContract.cutover_final_dod_checklist_contract
$cutoverOperatorRunbookPreflightContract = $readinessContract.cutover_operator_runbook_preflight_contract
$cutoverEvidenceAcceptanceMatrixContract = $readinessContract.cutover_evidence_acceptance_matrix_contract
$cutoverFinalClosureAuditContract = $readinessContract.cutover_final_closure_audit_contract
$cutoverEvidenceWatcherChecklistContract = $readinessContract.cutover_evidence_watcher_checklist_contract
$singleWriterCutoverProofGateContract = $readinessContract.single_writer_cutover_proof_gate_contract
$providerContract = $contract.runtime_env_provider_preflight_contract
$performanceContract = $contract.handoff_performance_guard_contract

$modeEnvVar = [string]$providerContract.cutover_mode_env_var
$databaseUrlEnvVar = [string]$providerContract.live_database_url_env_var
$featureEnvVar = [string]$readinessContract.opt_in_inputs.runtime_writer_feature_env_var
$liveOptInEnvVar = "AI_CONTROL_PLANE_BILLING_LEDGER_RUNTIME_WRITER_READINESS_LIVE"
$artifactWriteEnvVar = "AI_CONTROL_PLANE_BILLING_LEDGER_PROBE_ARTIFACT_WRITE"
$artifactReadEnvVar = "AI_CONTROL_PLANE_BILLING_LEDGER_PROBE_ARTIFACT_READ"
$artifactPathEnvVar = "AI_CONTROL_PLANE_BILLING_LEDGER_PROBE_ARTIFACT_PATH"
$liveCommitProofArtifactWriteEnvVar = "AI_CONTROL_PLANE_BILLING_LEDGER_LIVE_COMMIT_PROOF_ARTIFACT_WRITE"
$liveCommitProofArtifactReadEnvVar = "AI_CONTROL_PLANE_BILLING_LEDGER_LIVE_COMMIT_PROOF_ARTIFACT_READ"
$liveCommitProofArtifactPathEnvVar = "AI_CONTROL_PLANE_BILLING_LEDGER_LIVE_COMMIT_PROOF_ARTIFACT_PATH"
$cutoverEvidenceArtifactReadEnvVar = "AI_CONTROL_PLANE_BILLING_LEDGER_CUTOVER_EVIDENCE_ARTIFACT_READ"
$cutoverEvidenceArtifactPathEnvVar = "AI_CONTROL_PLANE_BILLING_LEDGER_CUTOVER_EVIDENCE_ARTIFACT_PATH"
$cutoverEvidenceAcceptedShapeSimulationEnvVar = "AI_CONTROL_PLANE_BILLING_LEDGER_CUTOVER_EVIDENCE_ACCEPTED_SHAPE_SIMULATION"
$runtimeWriterCommitRunnerPlanEnvVar = "AI_CONTROL_PLANE_BILLING_LEDGER_RUNTIME_WRITER_COMMIT_RUNNER_PLAN"
$runtimeWriterCommitRunnerRunEnvVar = "AI_CONTROL_PLANE_BILLING_LEDGER_RUNTIME_WRITER_COMMIT_RUNNER_RUN"
$liveDbExecutorProbeEnvVar = "AI_CONTROL_PLANE_BILLING_LEDGER_LIVE_DB_EXECUTOR_PROBE"
$rollbackOnlyExecutorEnvVar = "AI_CONTROL_PLANE_BILLING_LEDGER_ROLLBACK_ONLY_EXECUTOR_PROBE"
$realLiveAttemptEnvVar = "AI_CONTROL_PLANE_BILLING_LEDGER_REAL_LIVE_DB_PROBE_ATTEMPT"
$shadowCommitHandoffEnvVar = "AI_CONTROL_PLANE_BILLING_LEDGER_SHADOW_COMMIT_HANDOFF"
$productionCutoverAcceptanceEnvVar = "AI_CONTROL_PLANE_BILLING_LEDGER_PRODUCTION_CUTOVER_ACCEPTED"
$liveCommitProofEnvVar = "AI_CONTROL_PLANE_BILLING_LEDGER_LIVE_COMMIT_PROOF_AVAILABLE"
$liveCommitReadbackEnvVar = "AI_CONTROL_PLANE_BILLING_LEDGER_LIVE_COMMIT_READBACK"
$rollbackPlanAcknowledgedEnvVar = "AI_CONTROL_PLANE_BILLING_LEDGER_ROLLBACK_PLAN_ACKNOWLEDGED"
$runtimeContainerCommitEnvVar = "AI_CONTROL_PLANE_BILLING_LEDGER_RUNTIME_CONTAINER_COMMIT"
$singleWriterProofEnvVar = "AI_CONTROL_PLANE_BILLING_LEDGER_SINGLE_WRITER_PROOF"
$activeWriterEnvVar = "AI_CONTROL_PLANE_BILLING_LEDGER_ACTIVE_WRITER"
$sourceOfTruthEnvVar = "AI_CONTROL_PLANE_BILLING_LEDGER_SOURCE_OF_TRUTH"
$localWriterDisabledEnvVar = "AI_CONTROL_PLANE_BILLING_LEDGER_LOCAL_WRITER_DISABLED_FOR_CUTOVER"
$runtimeSchemaEnvVar = "AI_CONTROL_PLANE_BILLING_LEDGER_RUNTIME_SCHEMA_AVAILABLE"
$runtimeToolEnvVar = "AI_CONTROL_PLANE_BILLING_LEDGER_RUNTIME_TOOL_AVAILABLE"

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
  if ([string]$shadowCommitHandoffContract.schema_version -ne "control_plane_billing_ledger_shadow_commit_handoff.v1") {
    throw "shadow commit handoff schema mismatch"
  }
  if ([bool]$shadowCommitHandoffContract.default_requested) {
    throw "shadow commit handoff must be disabled by default"
  }
  if ([string]$shadowCommitHandoffContract.explicit_flag -ne "-ShadowCommitHandoff") {
    throw "shadow commit handoff explicit flag mismatch"
  }
  if ([bool]$shadowCommitHandoffContract.production_source_of_truth_switch_allowed) {
    throw "shadow commit handoff must not allow source-of-truth cutover"
  }
  if ([bool]$shadowCommitHandoffContract.no_double_write_contract.dual_commit_allowed) {
    throw "shadow commit handoff must not allow dual commit"
  }
  if ([string]$shadowCommitHandoffContract.rollback_fallback_guard.local_writer_fallback -ne "control_plane_local_sql_writer") {
    throw "shadow commit handoff fallback must remain local writer"
  }
  if ([string]$productionCutoverAcceptanceGateContract.schema_version -ne "control_plane_billing_ledger_production_cutover_acceptance_gate.v1") {
    throw "production cutover acceptance gate schema mismatch"
  }
  if ([bool]$productionCutoverAcceptanceGateContract.default_accepted) {
    throw "production cutover acceptance must default to rejected"
  }
  if ([string]$productionCutoverAcceptanceGateContract.explicit_flag -ne "-AcceptProductionCutover") {
    throw "production cutover acceptance flag mismatch"
  }
  if ([bool]$productionCutoverAcceptanceGateContract.source_of_truth_switch_performed_by_this_script) {
    throw "production cutover acceptance gate must not perform source-of-truth switch"
  }
  if ([bool]$productionCutoverAcceptanceGateContract.no_double_write_contract.dual_commit_allowed) {
    throw "production cutover acceptance gate must not allow dual commit"
  }
  if ([string]$productionCutoverAcceptanceGateContract.rollback_plan.rollback_command.script -ne "scripts/verify_control_plane_billing_ledger_runtime_writer_readiness.ps1") {
    throw "production cutover rollback command script mismatch"
  }
  if ([string]$productionCutoverAcceptanceGateContract.required_inputs.live_commit_readback_env_var -ne "AI_CONTROL_PLANE_BILLING_LEDGER_LIVE_COMMIT_READBACK") {
    throw "production cutover live commit readback env mismatch"
  }
  if ([string]$productionCutoverAcceptanceGateContract.required_inputs.source_of_truth_readback_env_var -ne "AI_CONTROL_PLANE_BILLING_LEDGER_SOURCE_OF_TRUTH") {
    throw "production cutover source-of-truth readback env mismatch"
  }
  if (-not [bool]$productionCutoverAcceptanceGateContract.commit_eligibility_contract.live_commit_readback_required) {
    throw "production cutover acceptance must require live commit readback"
  }
  if (-not [bool]$productionCutoverAcceptanceGateContract.rollback_plan.proof_freshness_required) {
    throw "production cutover rollback proof freshness must be required"
  }
  if ([bool]$productionCutoverAcceptanceGateContract.live_commit_proof_readback_contract.commit_performed_by_this_script) {
    throw "production cutover acceptance must not perform commit"
  }
  if ([string]$productionCutoverAcceptanceGateContract.required_inputs.live_commit_proof_artifact_path_env_var -ne "AI_CONTROL_PLANE_BILLING_LEDGER_LIVE_COMMIT_PROOF_ARTIFACT_PATH") {
    throw "production cutover live commit proof artifact path env mismatch"
  }
  if ([string]$runtimeEvidenceTrustGateContract.schema_version -ne "control_plane_billing_ledger_runtime_evidence_trust_gate.v1") {
    throw "runtime evidence trust gate schema mismatch"
  }
  if ([bool]$runtimeEvidenceTrustGateContract.docker_build_performed) {
    throw "runtime evidence trust gate must not perform Docker build"
  }
  if ([string]$runtimeEvidenceTrustGateContract.container_runtime_commit_env_var -ne "AI_CONTROL_PLANE_BILLING_LEDGER_RUNTIME_CONTAINER_COMMIT") {
    throw "runtime evidence trust container commit env mismatch"
  }
  $trustClassifications = @($runtimeEvidenceTrustGateContract.classification_values | ForEach-Object { [string]$_ })
  foreach ($requiredTrustClassification in @("source_level_pass", "container_runtime_current", "container_runtime_stale", "rollback_only_live_probe_only")) {
    if ($requiredTrustClassification -notin $trustClassifications) {
      throw "runtime evidence trust gate missing classification: $requiredTrustClassification"
    }
  }
  if ([string]$singleWriterCutoverProofGateContract.schema_version -ne "control_plane_billing_ledger_single_writer_cutover_proof_gate.v1") {
    throw "single writer cutover proof gate schema mismatch"
  }
  if ([bool]$singleWriterCutoverProofGateContract.default_proof_accepted) {
    throw "single writer proof must default to rejected"
  }
  if ([string]$singleWriterCutoverProofGateContract.expected_active_writer -ne "billing_ledger_runtime_writer") {
    throw "single writer proof expected active writer mismatch"
  }
  if ([string]$singleWriterCutoverProofGateContract.source_of_truth_env_var -ne "AI_CONTROL_PLANE_BILLING_LEDGER_SOURCE_OF_TRUTH") {
    throw "single writer proof source-of-truth env mismatch"
  }
  if ([string]$singleWriterCutoverProofGateContract.live_commit_readback_env_var -ne "AI_CONTROL_PLANE_BILLING_LEDGER_LIVE_COMMIT_READBACK") {
    throw "single writer proof live commit readback env mismatch"
  }
  if ([string]$singleWriterCutoverProofGateContract.proof_scope -ne "external_commit_readback_gate_no_source_of_truth_switch") {
    throw "single writer proof scope mismatch"
  }
  if (-not [bool]$singleWriterCutoverProofGateContract.requires_source_of_truth_consistency) {
    throw "single writer proof must require source-of-truth consistency"
  }
  if (-not [bool]$singleWriterCutoverProofGateContract.requires_rollback_proof_freshness) {
    throw "single writer proof must require rollback proof freshness"
  }
  if ([string]$singleWriterCutoverProofGateContract.rollback_proof_freshness_contract.simulated_measurement_source_classification -ne "blocker") {
    throw "single writer proof simulated measurement classification mismatch"
  }
  if ([string]$liveCommitProofArtifactContract.schema_version -ne "control_plane_billing_ledger_live_commit_proof_artifact.v1") {
    throw "live commit proof artifact schema mismatch"
  }
  if ([bool]$liveCommitProofArtifactContract.commit_performed_by_this_script) {
    throw "live commit proof artifact contract must not perform commit"
  }
  if ([string]$liveCommitProofArtifactContract.required_measurement_source -ne "external_controlled_runtime_writer_commit") {
    throw "live commit proof artifact measurement source mismatch"
  }
  if ([string]$liveCommitProofReadbackBoundaryContract.schema_version -ne "control_plane_billing_ledger_live_commit_proof_readback_boundary.v1") {
    throw "live commit proof readback boundary schema mismatch"
  }
  if ([string]$liveCommitProofReadbackBoundaryContract.write_mode -ne "template_only_never_passes_cutover_gate") {
    throw "live commit proof write mode mismatch"
  }
  if ([string]$singleWriterCutoverProofGateContract.live_commit_proof_artifact_readback_contract.schema_version -ne "control_plane_billing_ledger_live_commit_proof_readback_boundary.v1") {
    throw "single writer live commit proof artifact readback schema mismatch"
  }
  if ([bool]$singleWriterCutoverProofGateContract.live_commit_proof_artifact_readback_contract.write_template_can_pass) {
    throw "live commit proof template must not pass single writer proof"
  }
  if ([string]$cutoverFinalDoDChecklistContract.schema_version -ne "control_plane_billing_ledger_cutover_final_dod_checklist.v1") {
    throw "cutover final DoD checklist contract schema mismatch"
  }
  if ([bool]$cutoverFinalDoDChecklistContract.script_performs_commit -or [bool]$cutoverFinalDoDChecklistContract.script_performs_cutover) {
    throw "cutover final DoD checklist must not allow this script to commit or cutover"
  }
  if ([bool]$cutoverFinalDoDChecklistContract.states.cutover_ready.can_mark_todo_x) {
    throw "cutover-ready must not mark E9 complete"
  }
  if ([bool]$cutoverFinalDoDChecklistContract.states.cutover_ready.cutover_ready_can_mark_final_x) {
    throw "cutover-ready must not mark final x"
  }
  if (-not [bool]$cutoverFinalDoDChecklistContract.states.final_x_eligible.can_mark_todo_x) {
    throw "final DoD checklist must define final x eligibility"
  }
  if ([string]$cutoverOperatorRunbookPreflightContract.schema_version -ne "control_plane_billing_ledger_cutover_operator_runbook_preflight.v1") {
    throw "cutover operator runbook preflight contract schema mismatch"
  }
  if ([bool]$cutoverOperatorRunbookPreflightContract.default_commit -or [bool]$cutoverOperatorRunbookPreflightContract.default_cutover -or [bool]$cutoverOperatorRunbookPreflightContract.default_db_write) {
    throw "cutover operator runbook must default to no commit, no cutover, and no DB write"
  }
  if (-not [bool]$cutoverOperatorRunbookPreflightContract.actual_execution_requires_explicit_opt_in) {
    throw "actual cutover execution must require explicit opt-in"
  }
  foreach ($requiredRunbookStep in @("preflight", "commit_proof_readback", "cutover_dry_run_ready", "actual_cutover_opt_in", "post_cutover_readback", "rollback_proof")) {
    $runbookSteps = @($cutoverOperatorRunbookPreflightContract.ordered_steps | ForEach-Object { [string]$_.step })
    if ($requiredRunbookStep -notin $runbookSteps) {
      throw "cutover operator runbook missing step: $requiredRunbookStep"
    }
  }
  if ([bool]$singleWriterCutoverProofGateContract.no_double_write_contract.dual_commit_allowed) {
    throw "single writer proof must not allow dual commit"
  }
  if ([string]$cutoverEvidenceAcceptanceMatrixContract.schema_version -ne "control_plane_billing_ledger_cutover_evidence_acceptance_matrix.v1") {
    throw "cutover evidence acceptance matrix contract schema mismatch"
  }
  if ([bool]$cutoverEvidenceAcceptanceMatrixContract.default_read_artifact -or [bool]$cutoverEvidenceAcceptanceMatrixContract.default_commit -or [bool]$cutoverEvidenceAcceptanceMatrixContract.default_cutover -or [bool]$cutoverEvidenceAcceptanceMatrixContract.default_db_write) {
    throw "cutover evidence acceptance matrix must default to no read, no commit, no cutover, and no DB write"
  }
  if ([bool]$cutoverEvidenceAcceptanceMatrixContract.script_performs_commit -or [bool]$cutoverEvidenceAcceptanceMatrixContract.script_performs_cutover -or [bool]$cutoverEvidenceAcceptanceMatrixContract.script_writes_db) {
    throw "cutover evidence acceptance matrix must not execute commit, cutover, or DB writes"
  }
  if ([bool]$cutoverEvidenceAcceptanceMatrixContract.simulation_can_mark_final_x -or [bool]$cutoverEvidenceAcceptanceMatrixContract.template_can_mark_final_x -or [bool]$cutoverEvidenceAcceptanceMatrixContract.accepted_for_review_can_mark_final_x -or [bool]$cutoverEvidenceAcceptanceMatrixContract.cutover_ready_can_mark_final_x) {
    throw "cutover evidence acceptance matrix non-final states must not mark final x"
  }
  foreach ($requiredCutoverEvidenceField in @("artifact_provenance", "runtime_container_commit", "external_runner_provenance", "commit_proof_row_counts", "no_dual_result", "active_writer_before", "active_writer_after", "source_of_truth_before", "source_of_truth_after", "actual_cutover_opt_in_marker", "post_cutover_readback", "rollback_command", "rollback_proof", "duration_timing", "secret_safe_omission")) {
    $cutoverEvidenceFields = @($cutoverEvidenceAcceptanceMatrixContract.artifact_schema.required_fields | ForEach-Object { [string]$_ })
    if ($requiredCutoverEvidenceField -notin $cutoverEvidenceFields) {
      throw "cutover evidence acceptance matrix missing artifact field: $requiredCutoverEvidenceField"
    }
  }
  foreach ($requiredCutoverEvidenceRefusal in @("missing_artifact", "unsafe_path", "stale_artifact", "template_artifact", "simulated_artifact", "runtime_mismatch", "commit_proof_missing", "row_count_mismatch", "no_dual_failure", "active_writer_mismatch", "source_of_truth_not_switched", "post_cutover_readback_missing", "rollback_proof_missing", "raw_secret_present")) {
    if (-not (Test-EvidenceField -Object $cutoverEvidenceAcceptanceMatrixContract.refusal_taxonomy -Field $requiredCutoverEvidenceRefusal)) {
      throw "cutover evidence acceptance matrix missing refusal: $requiredCutoverEvidenceRefusal"
    }
  }
  if ([bool]$cutoverEvidenceAcceptanceMatrixContract.acceptance_states.cutover_evidence_accepted_for_review.can_mark_final_x) {
    throw "accepted-for-review evidence must not mark final x"
  }
  if ([bool]$cutoverEvidenceAcceptanceMatrixContract.acceptance_states.final_x_eligible.simulation_can_mark_final_x) {
    throw "final x eligibility must refuse simulations"
  }
  if ([string]$cutoverFinalClosureAuditContract.schema_version -ne "control_plane_billing_ledger_cutover_final_closure_audit.v1") {
    throw "cutover final closure audit contract schema mismatch"
  }
  if ([bool]$cutoverFinalClosureAuditContract.default_read_artifact -or [bool]$cutoverFinalClosureAuditContract.default_commit -or [bool]$cutoverFinalClosureAuditContract.default_cutover -or [bool]$cutoverFinalClosureAuditContract.default_db_write) {
    throw "cutover final closure audit must default to no artifact read, no commit, no cutover, and no DB write"
  }
  if ([bool]$cutoverFinalClosureAuditContract.script_performs_commit -or [bool]$cutoverFinalClosureAuditContract.script_performs_cutover -or [bool]$cutoverFinalClosureAuditContract.script_writes_db) {
    throw "cutover final closure audit must not execute commit, cutover, or DB writes"
  }
  if ([bool]$cutoverFinalClosureAuditContract.accepted_shape_simulation_can_mark_final_x -or [bool]$cutoverFinalClosureAuditContract.template_artifact_can_mark_final_x -or [bool]$cutoverFinalClosureAuditContract.accepted_for_review_can_mark_final_x -or [bool]$cutoverFinalClosureAuditContract.cutover_ready_can_mark_final_x -or [bool]$cutoverFinalClosureAuditContract.watcher_can_mark_final_x) {
    throw "cutover final closure audit must refuse non-final state final x"
  }
  foreach ($requiredClosureOutputField in @("final_x_eligible", "blocking_reasons", "required_evidence", "cutover_evidence_acceptance_state", "commit_proof_state", "actual_cutover_state", "post_cutover_readback_state", "rollback_proof_state", "active_writer_source_of_truth_no_dual_summary", "generated_at_utc", "current_commit", "secret_safe_omission")) {
    $closureOutputFields = @($cutoverFinalClosureAuditContract.required_output_fields | ForEach-Object { [string]$_ })
    if ($requiredClosureOutputField -notin $closureOutputFields) {
      throw "cutover final closure audit missing output field: $requiredClosureOutputField"
    }
  }
  foreach ($requiredClosureCommand in @("preflight", "read_commit_proof", "read_cutover_artifact", "post_cutover_readback", "rollback_proof_readback")) {
    $closureCommandSteps = @($cutoverFinalClosureAuditContract.next_commands | ForEach-Object { [string]$_.step })
    if ($requiredClosureCommand -notin $closureCommandSteps) {
      throw "cutover final closure audit missing next command: $requiredClosureCommand"
    }
  }
  if ([string]$cutoverEvidenceWatcherChecklistContract.schema_version -ne "control_plane_billing_ledger_cutover_evidence_watcher_checklist.v1") {
    throw "cutover evidence watcher checklist contract schema mismatch"
  }
  if ([bool]$cutoverEvidenceWatcherChecklistContract.default_poll -or [bool]$cutoverEvidenceWatcherChecklistContract.default_read_artifact -or [bool]$cutoverEvidenceWatcherChecklistContract.default_commit -or [bool]$cutoverEvidenceWatcherChecklistContract.default_cutover -or [bool]$cutoverEvidenceWatcherChecklistContract.default_db_write) {
    throw "cutover evidence watcher must default to no poll, no read, no commit, no cutover, and no DB write"
  }
  if ([bool]$cutoverEvidenceWatcherChecklistContract.script_performs_commit -or [bool]$cutoverEvidenceWatcherChecklistContract.script_performs_cutover -or [bool]$cutoverEvidenceWatcherChecklistContract.script_writes_db) {
    throw "cutover evidence watcher must not execute commit, cutover, or DB writes"
  }
  if ([bool]$cutoverEvidenceWatcherChecklistContract.watcher_can_mark_final_x -or [bool]$cutoverEvidenceWatcherChecklistContract.accepted_for_review_can_mark_final_x -or [bool]$cutoverEvidenceWatcherChecklistContract.simulation_can_mark_final_x -or [bool]$cutoverEvidenceWatcherChecklistContract.template_can_mark_final_x -or [bool]$cutoverEvidenceWatcherChecklistContract.cutover_ready_can_mark_final_x) {
    throw "cutover evidence watcher non-final states must not mark final x"
  }
  foreach ($requiredWatcherCommand in @("preflight", "missing_artifact_check", "read_commit_proof", "read_cutover_artifact", "final_audit_review")) {
    $watcherCommandSteps = @($cutoverEvidenceWatcherChecklistContract.exact_commands | ForEach-Object { [string]$_.step })
    if ($requiredWatcherCommand -notin $watcherCommandSteps) {
      throw "cutover evidence watcher missing command: $requiredWatcherCommand"
    }
  }
  $noDualCommitClassifications = @($singleWriterCutoverProofGateContract.no_double_write_contract.classification_values | ForEach-Object { [string]$_ })
  foreach ($requiredNoDualCommitClassification in @("blocker", "pass", "fail")) {
    if ($requiredNoDualCommitClassification -notin $noDualCommitClassifications) {
      throw "single writer proof missing no-dual-commit classification: $requiredNoDualCommitClassification"
    }
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

function Get-LocalToolReadiness {
  $psql = Get-Command psql -ErrorAction SilentlyContinue
  $docker = Get-Command docker -ErrorAction SilentlyContinue
  $dockerDaemonAvailable = $false
  if ($null -ne $docker) {
    try {
      docker version --format '{{.Server.Version}}' 2>$null | Out-Null
      $dockerDaemonAvailable = ($LASTEXITCODE -eq 0)
    } catch {
      $dockerDaemonAvailable = $false
    }
  }

  return [ordered]@{
    psql_available = ($null -ne $psql)
    docker_cli_available = ($null -ne $docker)
    docker_daemon_available = $dockerDaemonAvailable
    docker_postgres_container = "docker-compose-postgres-1"
    psql_path_output = if ($null -ne $psql) { "available_marker_only" } else { "missing" }
    docker_path_output = if ($null -ne $docker) { "available_marker_only" } else { "missing" }
  }
}

function Invoke-DockerPostgresRollbackProbeArtifact {
  param(
    [Parameter(Mandatory = $true)][bool]$Enabled
  )

  if (-not $Enabled) {
    return $null
  }

  $currentCommit = Get-CurrentCommitMarker
  $sql = @"
\set ON_ERROR_STOP on
BEGIN;
CREATE TEMP TABLE live_probe_evidence (
  step_order integer,
  statement_kind text,
  expected_rows text,
  actual_rows integer,
  rows_match boolean,
  rows_affected_source text,
  duration_ms numeric
) ON COMMIT DROP;
DO `$`$
DECLARE
  v_tenant uuid;
  v_project uuid;
  v_request uuid;
  v_wallet uuid;
  v_ledger uuid := gen_random_uuid();
  v_start timestamptz;
  v_rows integer;
  v_idempotency text := 'billing-ledger-live-probe-' || v_ledger::text;
BEGIN
  SELECT rl.tenant_id, rl.project_id, rl.id
    INTO v_tenant, v_project, v_request
    FROM request_logs rl
    JOIN projects p ON p.id = rl.project_id AND p.tenant_id = rl.tenant_id
   WHERE rl.project_id IS NOT NULL
   LIMIT 1;
  IF v_request IS NULL THEN
    RAISE EXCEPTION 'billing ledger live probe prerequisite missing';
  END IF;

  v_start := clock_timestamp();
  PERFORM 1 FROM ledger_entries WHERE tenant_id = v_tenant AND idempotency_key = v_idempotency FOR UPDATE;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  INSERT INTO live_probe_evidence VALUES (1, 'lock_idempotency_scope', 'zero_or_one', v_rows, v_rows IN (0, 1), 'docker_psql_row_count', EXTRACT(milliseconds FROM clock_timestamp() - v_start));

  v_start := clock_timestamp();
  INSERT INTO wallets (id, tenant_id, project_id, name, currency, status, balance_floor, metadata, created_at, updated_at)
  VALUES (gen_random_uuid(), v_tenant, v_project, 'billing ledger live probe rollback wallet', 'USD', 'active', 0, '{"probe":"billing_ledger_live_rollback"}'::jsonb, now(), now())
  RETURNING id INTO v_wallet;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  INSERT INTO live_probe_evidence VALUES (2, 'prepare_probe_wallet', 'one', v_rows, v_rows = 1, 'docker_psql_row_count', EXTRACT(milliseconds FROM clock_timestamp() - v_start));

  v_start := clock_timestamp();
  PERFORM 1 FROM wallets WHERE id = v_wallet AND tenant_id = v_tenant FOR UPDATE;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  INSERT INTO live_probe_evidence VALUES (3, 'lock_wallet_scope', 'one', v_rows, v_rows = 1, 'docker_psql_row_count', EXTRACT(milliseconds FROM clock_timestamp() - v_start));

  v_start := clock_timestamp();
  PERFORM 1 FROM budgets WHERE tenant_id = v_tenant AND (project_id = v_project OR project_id IS NULL) FOR UPDATE;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  INSERT INTO live_probe_evidence VALUES (4, 'lock_budget_scope', 'zero_or_more', v_rows, v_rows >= 0, 'docker_psql_row_count', EXTRACT(milliseconds FROM clock_timestamp() - v_start));

  v_start := clock_timestamp();
  INSERT INTO ledger_entries (
    id, tenant_id, project_id, request_id, entry_type, amount, currency, status,
    idempotency_key, usage_snapshot, policy_snapshot, wallet_id, metadata, occurred_at
  ) VALUES (
    v_ledger, v_tenant, v_project, v_request, 'adjust', 0.000001, 'USD', 'pending',
    v_idempotency, '{}'::jsonb, '{}'::jsonb, v_wallet, '{"probe":"billing_ledger_live_rollback"}'::jsonb, now()
  );
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  INSERT INTO live_probe_evidence VALUES (5, 'insert_probe_ledger_entry', 'one', v_rows, v_rows = 1, 'docker_psql_row_count', EXTRACT(milliseconds FROM clock_timestamp() - v_start));

  v_start := clock_timestamp();
  UPDATE ledger_entries SET status = 'confirmed' WHERE id = v_ledger AND tenant_id = v_tenant;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  INSERT INTO live_probe_evidence VALUES (6, 'mark_probe_idempotency', 'one', v_rows, v_rows = 1, 'docker_psql_row_count', EXTRACT(milliseconds FROM clock_timestamp() - v_start));
END
`$`$;
SELECT jsonb_build_object(
  'schema_version', 'control_plane_billing_ledger_live_probe_evidence_artifact.v1',
  'artifact_mode', 'post_probe_measurement_contract',
  'generated_at_utc', to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
  'current_commit', '$currentCommit',
  'freshness_marker', 'current',
  'stale_artifact', false,
  'probe_requested', true,
  'classification', CASE WHEN bool_and(rows_match) THEN 'pass' ELSE 'fail' END,
  'supported_classifications', jsonb_build_array('blocker', 'pass', 'fail'),
  'provenance', jsonb_build_object(
    'measurement_source', 'docker_compose_postgres_psql_rollback_only',
    'executor_boundary_schema', 'control_plane_billing_ledger_live_probe_executor_boundary.v1',
    'readiness_schema', 'control_plane_billing_ledger_writer_readiness_smoke_wrapper.v1',
    'probe_requested', true
  ),
  'db_write_performed', true,
  'production_writer_replaced', false,
  'production_source_of_truth_switch_allowed', false,
  'dual_commit_allowed', false,
  'safe_command_summary', jsonb_build_object(
    'script', 'scripts/verify_control_plane_billing_ledger_runtime_writer_readiness.ps1',
    'flags', jsonb_build_array('-Live', '-LiveExecutionProbe', '-RunLiveDbExecutorProbe', '-ExecuteRollbackOnlyLiveProbe', '-AttemptRealLiveDbProbe', '-WriteProbeArtifact', '-ReadProbeArtifact'),
    'database_url_output', 'presence_marker_only',
    'env_value_output', 'omitted',
    'raw_env_values_echoed', false
  ),
  'row_count_evidence', (
    SELECT jsonb_agg(jsonb_build_object(
      'statement_kind', statement_kind,
      'expected_rows', expected_rows,
      'actual_rows', actual_rows,
      'rows_match', rows_match,
      'mismatch_classification', CASE WHEN rows_match THEN 'pass' ELSE 'fail' END,
      'rows_affected_source', rows_affected_source
    ) ORDER BY step_order)
    FROM live_probe_evidence
  ),
  'transaction_timing_durations', (
    SELECT jsonb_object_agg(
      CASE statement_kind
        WHEN 'lock_idempotency_scope' THEN 'lock_idempotency_scope_duration_ms'
        WHEN 'prepare_probe_wallet' THEN 'prepare_probe_wallet_duration_ms'
        WHEN 'lock_wallet_scope' THEN 'lock_wallet_scope_duration_ms'
        WHEN 'lock_budget_scope' THEN 'lock_budget_scope_duration_ms'
        WHEN 'insert_probe_ledger_entry' THEN 'insert_probe_ledger_entry_duration_ms'
        WHEN 'mark_probe_idempotency' THEN 'mark_probe_idempotency_duration_ms'
      END,
      duration_ms
    ) || jsonb_build_object(
      'begin_transaction_duration_ms', 0,
      'row_count_capture_duration_ms', 0,
      'rollback_transaction_duration_ms', 0,
      'measurement_source', 'docker_compose_postgres_psql_rollback_only'
    )
    FROM live_probe_evidence
  ),
  'rollback_no_commit_proof', jsonb_build_object(
    'rollback_observed', true,
    'commit_observed', false,
    'probe_commits_billing_ledger', false,
    'production_writer_replaced', false,
    'dual_commit_observed', false,
    'local_writer_fallback', 'control_plane_local_sql_writer',
    'proof_source', 'docker_compose_postgres_psql_rollback_only'
  ),
  'classification_rules', jsonb_build_object(
    'blocker', jsonb_build_array('missing_row_count_measurement', 'missing_timing_measurement', 'missing_rollback_proof', 'stale_artifact'),
    'pass', jsonb_build_array('all_required_row_counts_match', 'all_required_timing_fields_present', 'rollback_no_commit_proof_present', 'production_writer_unchanged'),
    'fail', jsonb_build_array('row_count_mismatch', 'unsafe_output_detected')
  ),
  'blockers', jsonb_build_array(),
  'safe_output', jsonb_build_object(
    'database_url_output', 'omitted',
    'env_value_output', 'omitted',
    'operation_key_output', 'omitted',
    'raw_env_value_echoed', false,
    'raw_database_url_echoed', false,
    'raw_metadata_echoed', false,
    'credential_material_echoed', false,
    'raw_executor_error_detail_echoed', false
  )
)::text AS probe_json
FROM live_probe_evidence
\gset
ROLLBACK;
SELECT :'probe_json';
"@

  $output = $sql | docker exec -i docker-compose-postgres-1 sh -lc 'export PGPASSWORD="$POSTGRES_PASSWORD"; psql -v ON_ERROR_STOP=1 -At -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($output)) {
    return $null
  }
  return ($output | Select-Object -Last 1 | ConvertFrom-Json)
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

function Resolve-SafeProbeArtifactPath {
  param(
    [AllowNull()][string]$RequestedPath,
    [string]$DefaultRelativePath = ".tmp\billing-ledger\live-probe-evidence-artifact.json"
  )

  $pathValue = $RequestedPath
  if ([string]::IsNullOrWhiteSpace($pathValue)) {
    $pathValue = $DefaultRelativePath
  }

  $candidate = if ([System.IO.Path]::IsPathRooted($pathValue)) {
    [System.IO.Path]::GetFullPath($pathValue)
  } else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $pathValue))
  }

  $repoFull = [System.IO.Path]::GetFullPath([string]$repoRoot)
  $tmpRoot = [System.IO.Path]::GetFullPath((Join-Path $repoFull ".tmp"))
  $directory = [System.IO.Path]::GetDirectoryName($candidate)
  $extension = [System.IO.Path]::GetExtension($candidate)
  $relative = if ($candidate.StartsWith($repoFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    $candidate.Substring($repoFull.Length).TrimStart('\', '/')
  } else {
    ""
  }

  $safe = $true
  $reason = "allowed_repo_tmp_artifact_path"
  if (-not $candidate.StartsWith($tmpRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    $safe = $false
    $reason = "artifact_path_must_be_under_repo_tmp"
  } elseif ($relative -match '(^|[\\/])\.git([\\/]|$)') {
    $safe = $false
    $reason = "artifact_path_must_not_target_git"
  } elseif ($relative -match '^(apps|crates|docs|scripts|tests|web)([\\/]|$)') {
    $safe = $false
    $reason = "artifact_path_must_not_target_source_or_docs"
  } elseif ($extension -ne ".json") {
    $safe = $false
    $reason = "artifact_path_must_be_json"
  }

  return [ordered]@{
    safe = $safe
    reason = $reason
    full_path = $candidate
    relative_path = $relative
    directory = $directory
  }
}

function Write-ProbeArtifactIfAllowed {
  param(
    [Parameter(Mandatory = $true)]$Artifact,
    [Parameter(Mandatory = $true)]$PathGate,
    [Parameter(Mandatory = $true)][bool]$WriteRequested
  )

  if (-not $WriteRequested) {
    return [ordered]@{
      requested = $false
      performed = $false
      classification = "blocker"
      reason = "artifact_write_not_requested"
      relative_path = [string]$PathGate.relative_path
    }
  }

  if (-not [bool]$PathGate.safe) {
    return [ordered]@{
      requested = $true
      performed = $false
      classification = "blocker"
      reason = [string]$PathGate.reason
      relative_path = [string]$PathGate.relative_path
    }
  }

  New-Item -ItemType Directory -Path ([string]$PathGate.directory) -Force | Out-Null
  $Artifact | ConvertTo-Json -Depth 16 | Set-Content -Path ([string]$PathGate.full_path) -Encoding UTF8
  return [ordered]@{
    requested = $true
    performed = $true
    classification = "pass"
    reason = "artifact_written"
    relative_path = [string]$PathGate.relative_path
  }
}

function Read-ProbeArtifactIfAllowed {
  param(
    [Parameter(Mandatory = $true)]$FallbackArtifact,
    [Parameter(Mandatory = $true)]$PathGate,
    [Parameter(Mandatory = $true)][bool]$ReadRequested
  )

  if (-not $ReadRequested) {
    return [ordered]@{
      requested = $false
      performed = $false
      classification = "blocker"
      reason = "artifact_read_not_requested"
      relative_path = [string]$PathGate.relative_path
      artifact = $FallbackArtifact
    }
  }

  if (-not [bool]$PathGate.safe) {
    return [ordered]@{
      requested = $true
      performed = $false
      classification = "blocker"
      reason = [string]$PathGate.reason
      relative_path = [string]$PathGate.relative_path
      artifact = $FallbackArtifact
    }
  }

  if (-not (Test-Path -LiteralPath ([string]$PathGate.full_path))) {
    return [ordered]@{
      requested = $true
      performed = $false
      classification = "blocker"
      reason = "artifact_file_missing"
      relative_path = [string]$PathGate.relative_path
      artifact = $FallbackArtifact
    }
  }

  $artifact = Get-Content -Raw -LiteralPath ([string]$PathGate.full_path) | ConvertFrom-Json
  return [ordered]@{
    requested = $true
    performed = $true
    classification = "pass"
    reason = "artifact_read"
    relative_path = [string]$PathGate.relative_path
    artifact = $artifact
  }
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

function New-LiveCommitProofTemplateArtifact {
  param(
    [Parameter(Mandatory = $true)][string]$CurrentCommit,
    [AllowNull()][string]$RuntimeCommitMarker,
    [AllowNull()][string]$ActiveWriter,
    [AllowNull()][string]$SourceOfTruth
  )

  $expectedWriter = [string]$singleWriterCutoverProofGateContract.expected_active_writer
  return [ordered]@{
    schema_version = [string]$liveCommitProofArtifactContract.schema_version
    artifact_mode = [string]$liveCommitProofArtifactContract.artifact_mode
    generated_at_utc = [DateTimeOffset]::UtcNow.ToString("o")
    current_commit = $CurrentCommit
    runtime_container_commit = if ([string]::IsNullOrWhiteSpace($RuntimeCommitMarker)) { "missing" } else { $RuntimeCommitMarker }
    freshness_marker = "template"
    stale_artifact = $true
    measurement_source = "script_template_no_commit"
    generated_by_this_script = $true
    simulated = $false
    classification = "blocker"
    live_commit_readback = if ([string]::IsNullOrWhiteSpace($ActiveWriter)) { $expectedWriter } else { $ActiveWriter }
    active_writer = if ([string]::IsNullOrWhiteSpace($ActiveWriter)) { $expectedWriter } else { $ActiveWriter }
    source_of_truth = if ([string]::IsNullOrWhiteSpace($SourceOfTruth)) { "missing" } else { $SourceOfTruth }
    single_active_writer_count = 0
    row_count_proof = @(
      [ordered]@{
        statement_kind = "insert_runtime_writer_commit_ledger_entry"
        expected_rows = 1
        actual_rows = 0
        rows_match = $false
        rows_affected_source = "template_only_no_commit"
      },
      [ordered]@{
        statement_kind = "mark_runtime_writer_commit_idempotency"
        expected_rows = 1
        actual_rows = 0
        rows_match = $false
        rows_affected_source = "template_only_no_commit"
      }
    )
    commit_proof = [ordered]@{
      runtime_writer_commit_observed = $false
      committed_writer = $expectedWriter
      commit_source = "template_only_no_commit"
      operation_scope = "operator_must_replace_with_external_controlled_commit_proof"
      production_source_of_truth_switch_observed = $false
    }
    runner_provenance = [ordered]@{
      runner_id = "template_only_no_external_runner"
      runner_invocation_id = "template_only_no_external_runner"
      artifact_origin = "script_template_no_commit"
      generated_by_external_runner = $false
      source_of_truth_switch_performed = $false
    }
    no_dual_commit_proof = [ordered]@{
      dual_commit_observed = $false
      local_and_billing_ledger_commit_same_request_observed = $false
      production_writer_replaced = $false
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

function New-LiveCommitProofReadbackBoundary {
  param(
    [Parameter(Mandatory = $true)]$Artifact,
    [Parameter(Mandatory = $true)]$ArtifactWrite,
    [Parameter(Mandatory = $true)]$ArtifactRead,
    [Parameter(Mandatory = $true)]$PathGate,
    [Parameter(Mandatory = $true)][string]$CurrentCommit,
    [AllowNull()][string]$RuntimeCommitMarker,
    [AllowNull()][string]$ActiveWriter,
    [AllowNull()][string]$SourceOfTruth,
    [Parameter(Mandatory = $true)]$RollbackGate
  )

  $blockers = New-Object System.Collections.Generic.List[string]
  $failures = New-Object System.Collections.Generic.List[string]
  $expectedWriter = [string]$singleWriterCutoverProofGateContract.expected_active_writer

  if (-not [bool]$ArtifactRead.requested) {
    [void]$blockers.Add("live_commit_proof_artifact_read_not_requested")
  }
  if (-not [bool]$ArtifactRead.performed) {
    [void]$blockers.Add("live_commit_proof_artifact_missing")
  }
  if (-not [bool]$PathGate.safe) {
    [void]$blockers.Add([string]$PathGate.reason)
  }

  foreach ($field in @($liveCommitProofArtifactContract.required_fields | ForEach-Object { [string]$_ })) {
    if (-not (Test-EvidenceField -Object $Artifact -Field $field)) {
      [void]$blockers.Add("live_commit_proof_artifact_missing_field")
      break
    }
  }

  $artifactSchema = [string](Get-EvidenceField -Object $Artifact -Field "schema_version")
  if ($artifactSchema -ne [string]$liveCommitProofArtifactContract.schema_version) {
    [void]$failures.Add("live_commit_proof_artifact_schema_mismatch")
  }

  $generatedByThisScript = [bool](Get-EvidenceField -Object $Artifact -Field "generated_by_this_script")
  $simulated = [bool](Get-EvidenceField -Object $Artifact -Field "simulated")
  $trustedExternalEvidence = [bool]$ArtifactRead.performed -and -not $generatedByThisScript -and -not $simulated
  $measurementSource = [string](Get-EvidenceField -Object $Artifact -Field "measurement_source")
  if ($trustedExternalEvidence -and $measurementSource -ne [string]$liveCommitProofArtifactContract.required_measurement_source) {
    [void]$failures.Add("live_commit_proof_measurement_source_mismatch")
  }
  if ($generatedByThisScript) {
    [void]$blockers.Add("live_commit_proof_artifact_generated_by_script")
  }
  if ($simulated) {
    [void]$blockers.Add("live_commit_proof_artifact_simulated")
  }

  $artifactCurrentCommit = [string](Get-EvidenceField -Object $Artifact -Field "current_commit")
  $artifactRuntimeCommit = [string](Get-EvidenceField -Object $Artifact -Field "runtime_container_commit")
  $runtimeCommitMatches = (Test-CommitMarkerMatches -CurrentCommit $CurrentCommit -RuntimeCommit $RuntimeCommitMarker) -and (Test-CommitMarkerMatches -CurrentCommit $CurrentCommit -RuntimeCommit $artifactRuntimeCommit)
  if ([string](Get-EvidenceField -Object $Artifact -Field "freshness_marker") -ne "current" -or [bool](Get-EvidenceField -Object $Artifact -Field "stale_artifact") -or -not (Test-CommitMarkerMatches -CurrentCommit $CurrentCommit -RuntimeCommit $artifactCurrentCommit)) {
    [void]$blockers.Add("live_commit_proof_artifact_stale")
  }
  if ($trustedExternalEvidence -and -not $runtimeCommitMatches) {
    [void]$failures.Add("runtime_container_commit_stale")
  }

  $artifactCommitReadback = [string](Get-EvidenceField -Object $Artifact -Field "live_commit_readback")
  $artifactActiveWriter = [string](Get-EvidenceField -Object $Artifact -Field "active_writer")
  $artifactSourceOfTruth = [string](Get-EvidenceField -Object $Artifact -Field "source_of_truth")
  $commitReadbackMatches = Test-WriterMarkerMatches -Value $artifactCommitReadback -Expected $expectedWriter
  $activeWriterMatches = (Test-WriterMarkerMatches -Value $artifactActiveWriter -Expected $expectedWriter) -and (Test-WriterMarkerMatches -Value $ActiveWriter -Expected $expectedWriter)
  $sourceOfTruthMatches = (Test-WriterMarkerMatches -Value $artifactSourceOfTruth -Expected $expectedWriter) -and (Test-WriterMarkerMatches -Value $SourceOfTruth -Expected $expectedWriter)
  $activeMatchesSource = $artifactActiveWriter.Trim().ToLowerInvariant() -eq $artifactSourceOfTruth.Trim().ToLowerInvariant()
  if ($trustedExternalEvidence -and -not $commitReadbackMatches) {
    [void]$failures.Add("live_commit_readback_mismatch")
  }
  if ($trustedExternalEvidence -and (-not $activeWriterMatches -or -not $sourceOfTruthMatches -or -not $activeMatchesSource)) {
    [void]$failures.Add("active_writer_source_of_truth_mismatch")
  }

  $singleActiveWriterCount = [int](Get-EvidenceField -Object $Artifact -Field "single_active_writer_count")
  if ($trustedExternalEvidence -and $singleActiveWriterCount -ne 1) {
    [void]$failures.Add("single_active_writer_count_mismatch")
  }

  $commitProof = Get-EvidenceField -Object $Artifact -Field "commit_proof"
  $runnerProvenance = Get-EvidenceField -Object $Artifact -Field "runner_provenance"
  $noDualCommitProof = Get-EvidenceField -Object $Artifact -Field "no_dual_commit_proof"
  $rowCountProof = @(Get-EvidenceField -Object $Artifact -Field "row_count_proof")
  $rowCountRequiredFields = @($liveCommitProofArtifactContract.row_count_proof_required_fields | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($rowCountRequiredFields.Count -eq 0) {
    $rowCountRequiredFields = @("statement_kind", "expected_rows", "actual_rows", "rows_match", "rows_affected_source")
  }
  $requiredRowCountKinds = @($liveCommitProofArtifactContract.required_row_count_statement_kinds | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($requiredRowCountKinds.Count -eq 0) {
    $requiredRowCountKinds = @("insert_runtime_writer_commit_ledger_entry", "mark_runtime_writer_commit_idempotency")
  }
  $rowCountKinds = New-Object System.Collections.Generic.HashSet[string]
  if ($rowCountProof.Count -eq 0) {
    [void]$blockers.Add("runtime_writer_commit_runner_row_count_missing")
  } else {
    foreach ($row in $rowCountProof) {
      if ($null -eq $row) {
        [void]$blockers.Add("runtime_writer_commit_runner_row_count_missing")
        continue
      }
      foreach ($field in $rowCountRequiredFields) {
        if (-not (Test-EvidenceField -Object $row -Field $field)) {
          [void]$blockers.Add("runtime_writer_commit_runner_row_count_missing")
          break
        }
      }
      $statementKind = [string](Get-EvidenceField -Object $row -Field "statement_kind")
      if (-not [string]::IsNullOrWhiteSpace($statementKind)) {
        [void]$rowCountKinds.Add($statementKind)
      }
      $expectedRows = [int](Get-EvidenceField -Object $row -Field "expected_rows")
      $actualRows = [int](Get-EvidenceField -Object $row -Field "actual_rows")
      $rowsMatch = [bool](Get-EvidenceField -Object $row -Field "rows_match")
      if ($trustedExternalEvidence -and (-not $rowsMatch -or $expectedRows -ne $actualRows)) {
        [void]$failures.Add("runtime_writer_commit_runner_row_count_mismatch")
      }
    }
    foreach ($requiredKind in $requiredRowCountKinds) {
      if (-not $rowCountKinds.Contains($requiredKind)) {
        [void]$blockers.Add("runtime_writer_commit_runner_row_count_missing")
      }
    }
  }
  if ($null -eq $commitProof -or $null -eq $noDualCommitProof) {
    [void]$blockers.Add("live_commit_proof_artifact_missing_field")
  } else {
    foreach ($field in @($liveCommitProofArtifactContract.commit_proof_required_fields | ForEach-Object { [string]$_ })) {
      if (-not (Test-EvidenceField -Object $commitProof -Field $field)) {
        [void]$blockers.Add("live_commit_proof_artifact_missing_field")
        break
      }
    }
    foreach ($field in @($liveCommitProofArtifactContract.no_dual_commit_required_fields | ForEach-Object { [string]$_ })) {
      if (-not (Test-EvidenceField -Object $noDualCommitProof -Field $field)) {
        [void]$blockers.Add("live_commit_proof_artifact_missing_field")
        break
      }
    }
    if ($trustedExternalEvidence -and (Get-EvidenceField -Object $commitProof -Field "runtime_writer_commit_observed") -ne $true) {
      [void]$failures.Add("runtime_writer_commit_not_observed")
    }
    if ($trustedExternalEvidence -and -not (Test-WriterMarkerMatches -Value ([string](Get-EvidenceField -Object $commitProof -Field "committed_writer")) -Expected $expectedWriter)) {
      [void]$failures.Add("live_commit_readback_mismatch")
    }
    if ($trustedExternalEvidence -and (Get-EvidenceField -Object $commitProof -Field "production_source_of_truth_switch_observed") -eq $true) {
      [void]$failures.Add("production_source_of_truth_switch_observed")
    }
    if ($trustedExternalEvidence -and ((Get-EvidenceField -Object $noDualCommitProof -Field "dual_commit_observed") -eq $true -or (Get-EvidenceField -Object $noDualCommitProof -Field "local_and_billing_ledger_commit_same_request_observed") -eq $true)) {
      [void]$failures.Add("dual_commit_observed")
    }
    if ($trustedExternalEvidence -and (Get-EvidenceField -Object $noDualCommitProof -Field "production_writer_replaced") -eq $true) {
      [void]$failures.Add("production_writer_replaced")
    }
  }
  if ($null -eq $runnerProvenance) {
    [void]$blockers.Add("runtime_writer_commit_runner_provenance_missing")
  } else {
    foreach ($field in @($liveCommitProofArtifactContract.provenance_proof_required_fields | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
      if (-not (Test-EvidenceField -Object $runnerProvenance -Field $field)) {
        [void]$blockers.Add("runtime_writer_commit_runner_provenance_missing")
        break
      }
    }
    $artifactOrigin = [string](Get-EvidenceField -Object $runnerProvenance -Field "artifact_origin")
    $externalRunnerGenerated = [bool](Get-EvidenceField -Object $runnerProvenance -Field "generated_by_external_runner")
    $provenanceCutoverObserved = [bool](Get-EvidenceField -Object $runnerProvenance -Field "source_of_truth_switch_performed")
    if ($trustedExternalEvidence -and ($artifactOrigin -ne "external_runtime_writer_commit_runner" -or -not $externalRunnerGenerated)) {
      [void]$failures.Add("runtime_writer_commit_runner_provenance_mismatch")
    }
    if ($trustedExternalEvidence -and $provenanceCutoverObserved) {
      [void]$failures.Add("production_source_of_truth_switch_observed")
    }
  }

  $rollbackFreshness = $RollbackGate.rollback_proof_freshness
  if ($null -eq $rollbackFreshness -or [string]$rollbackFreshness.classification -ne "pass") {
    [void]$blockers.Add("rollback_proof_not_fresh")
  }

  $classification = "blocker"
  if ($failures.Count -gt 0) {
    $classification = "fail"
  } elseif ($blockers.Count -eq 0) {
    $classification = "pass"
  }

  return [ordered]@{
    schema_version = [string]$liveCommitProofReadbackBoundaryContract.schema_version
    classification = $classification
    artifact_schema_version = $artifactSchema
    write_template = [ordered]@{
      requested = [bool]$ArtifactWrite.requested
      performed = [bool]$ArtifactWrite.performed
      can_pass = $false
    }
    readback = [ordered]@{
      requested = [bool]$ArtifactRead.requested
      performed = [bool]$ArtifactRead.performed
      relative_path = [string]$ArtifactRead.relative_path
      path_safe = [bool]$PathGate.safe
    }
    current_commit = $CurrentCommit
    artifact_current_commit = $artifactCurrentCommit
    runtime_container_commit_matches_current = $runtimeCommitMatches
    measurement_source = $measurementSource
    generated_by_this_script = $generatedByThisScript
    simulated = $simulated
    live_commit_readback = [ordered]@{
      artifact_value_present = -not [string]::IsNullOrWhiteSpace($artifactCommitReadback)
      matches_expected_writer = $commitReadbackMatches
      output = "presence_and_match_only"
      raw_marker_echoed = $false
    }
    active_writer_source_of_truth = [ordered]@{
      active_writer_matches_expected = $activeWriterMatches
      source_of_truth_matches_expected = $sourceOfTruthMatches
      active_writer_matches_source_of_truth = $activeMatchesSource
      single_active_writer_count = $singleActiveWriterCount
      source_of_truth_switch_performed_by_this_script = $false
    }
    commit_proof = [ordered]@{
      runtime_writer_commit_observed = if ($null -eq $commitProof) { $false } else { [bool](Get-EvidenceField -Object $commitProof -Field "runtime_writer_commit_observed") }
      committed_writer_matches_expected = if ($null -eq $commitProof) { $false } else { Test-WriterMarkerMatches -Value ([string](Get-EvidenceField -Object $commitProof -Field "committed_writer")) -Expected $expectedWriter }
      production_source_of_truth_switch_observed = if ($null -eq $commitProof) { $false } else { [bool](Get-EvidenceField -Object $commitProof -Field "production_source_of_truth_switch_observed") }
      commit_performed_by_this_script = $false
    }
    runner_provenance = [ordered]@{
      present = ($null -ne $runnerProvenance)
      generated_by_external_runner = if ($null -eq $runnerProvenance) { $false } else { [bool](Get-EvidenceField -Object $runnerProvenance -Field "generated_by_external_runner") }
      artifact_origin = if ($null -eq $runnerProvenance) { "missing" } else { [string](Get-EvidenceField -Object $runnerProvenance -Field "artifact_origin") }
      source_of_truth_switch_performed = if ($null -eq $runnerProvenance) { $false } else { [bool](Get-EvidenceField -Object $runnerProvenance -Field "source_of_truth_switch_performed") }
      output = "presence_and_classification_only"
    }
    row_count_proof = [ordered]@{
      required_statement_kinds = @($requiredRowCountKinds)
      observed_statement_kinds = @($rowCountKinds)
      row_count_markers_present = ($rowCountProof.Count -gt 0)
      row_count_markers_match = -not (@($failures) -contains "runtime_writer_commit_runner_row_count_mismatch")
      source = "external_controlled_runtime_writer_commit_artifact"
    }
    no_dual_commit_proof = [ordered]@{
      dual_commit_allowed = $false
      dual_commit_observed = if ($null -eq $noDualCommitProof) { $false } else { [bool](Get-EvidenceField -Object $noDualCommitProof -Field "dual_commit_observed") }
      local_and_billing_ledger_commit_same_request_observed = if ($null -eq $noDualCommitProof) { $false } else { [bool](Get-EvidenceField -Object $noDualCommitProof -Field "local_and_billing_ledger_commit_same_request_observed") }
      production_writer_replaced = if ($null -eq $noDualCommitProof) { $false } else { [bool](Get-EvidenceField -Object $noDualCommitProof -Field "production_writer_replaced") }
    }
    rollback_proof_freshness = $rollbackFreshness
    blockers = @($blockers | Select-Object -Unique)
    failures = @($failures | Select-Object -Unique)
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

function New-ExternalCommitRunnerAcceptanceSelfTestArtifact {
  param(
    [Parameter(Mandatory = $true)][string]$Case,
    [Parameter(Mandatory = $true)][string]$CurrentCommit
  )

  $expectedWriter = [string]$singleWriterCutoverProofGateContract.expected_active_writer
  $artifact = [ordered]@{
    schema_version = [string]$liveCommitProofArtifactContract.schema_version
    artifact_mode = [string]$liveCommitProofArtifactContract.artifact_mode
    generated_at_utc = [DateTimeOffset]::UtcNow.ToString("o")
    current_commit = $CurrentCommit
    runtime_container_commit = $CurrentCommit
    freshness_marker = "current"
    stale_artifact = $false
    measurement_source = [string]$liveCommitProofArtifactContract.required_measurement_source
    generated_by_this_script = $false
    simulated = $false
    classification = "self_test_candidate"
    live_commit_readback = $expectedWriter
    active_writer = $expectedWriter
    source_of_truth = $expectedWriter
    single_active_writer_count = 1
    row_count_proof = @(
      [ordered]@{
        statement_kind = "insert_runtime_writer_commit_ledger_entry"
        expected_rows = 1
        actual_rows = 1
        rows_match = $true
        rows_affected_source = "external_runner_readback"
      },
      [ordered]@{
        statement_kind = "mark_runtime_writer_commit_idempotency"
        expected_rows = 1
        actual_rows = 1
        rows_match = $true
        rows_affected_source = "external_runner_readback"
      }
    )
    commit_proof = [ordered]@{
      runtime_writer_commit_observed = $true
      committed_writer = $expectedWriter
      commit_source = "external_controlled_runtime_writer_commit_runner"
      operation_scope = "self_test_no_cutover_artifact_acceptance"
      production_source_of_truth_switch_observed = $false
    }
    runner_provenance = [ordered]@{
      runner_id = "self_test_external_runner"
      runner_invocation_id = "self_test_invocation"
      artifact_origin = "external_runtime_writer_commit_runner"
      generated_by_external_runner = $true
      source_of_truth_switch_performed = $false
    }
    no_dual_commit_proof = [ordered]@{
      dual_commit_observed = $false
      local_and_billing_ledger_commit_same_request_observed = $false
      production_writer_replaced = $false
    }
  }

  switch ($Case) {
    "row_count_mismatch" {
      $artifact.row_count_proof[0].actual_rows = 0
      $artifact.row_count_proof[0].rows_match = $false
    }
    "commit_missing" {
      $artifact.commit_proof.runtime_writer_commit_observed = $false
    }
    "no_dual_failed" {
      $artifact.no_dual_commit_proof.dual_commit_observed = $true
      $artifact.no_dual_commit_proof.local_and_billing_ledger_commit_same_request_observed = $true
    }
    "stale_commit" {
      $artifact.runtime_container_commit = "stale-self-test-commit"
    }
    "stale_artifact" {
      $artifact.freshness_marker = "stale"
      $artifact.stale_artifact = $true
    }
    "provenance_mismatch" {
      $artifact.runner_provenance.artifact_origin = "unknown_or_template_runner"
      $artifact.runner_provenance.generated_by_external_runner = $false
    }
  }

  return $artifact
}

function Invoke-RuntimeWriterCommitRunnerArtifactAcceptanceSelfTest {
  param(
    [Parameter(Mandatory = $true)][bool]$Requested,
    [Parameter(Mandatory = $true)][string]$CurrentCommit
  )

  $cases = @(
    @{ Name = "accepted_external_artifact"; Expected = "pass"; ExpectedCode = "" },
    @{ Name = "row_count_mismatch"; Expected = "fail"; ExpectedCode = "runtime_writer_commit_runner_row_count_mismatch" },
    @{ Name = "commit_missing"; Expected = "fail"; ExpectedCode = "runtime_writer_commit_not_observed" },
    @{ Name = "no_dual_failed"; Expected = "fail"; ExpectedCode = "dual_commit_observed" },
    @{ Name = "stale_commit"; Expected = "fail"; ExpectedCode = "runtime_container_commit_stale" },
    @{ Name = "stale_artifact"; Expected = "blocker"; ExpectedCode = "live_commit_proof_artifact_stale" },
    @{ Name = "provenance_mismatch"; Expected = "fail"; ExpectedCode = "runtime_writer_commit_runner_provenance_mismatch" }
  )

  if (-not $Requested) {
    return [ordered]@{
      schema_version = "control_plane_billing_ledger_runtime_writer_commit_runner_artifact_acceptance_self_test.v1"
      requested = $false
      classification = "blocker"
      blocker = "runtime_writer_commit_runner_artifact_acceptance_self_test_not_requested"
      case_results = @()
      production_source_of_truth_switch_allowed = $false
      script_performs_commit = $false
      can_substitute_external_commit_proof = $false
    }
  }

  $fakeRead = [ordered]@{
    requested = $true
    performed = $true
    relative_path = ".tmp\billing-ledger\self-test-live-commit-proof-artifact.json"
  }
  $fakeWrite = [ordered]@{
    requested = $false
    performed = $false
  }
  $fakePathGate = [ordered]@{
    safe = $true
    reason = "safe"
    relative_path = ".tmp\billing-ledger\self-test-live-commit-proof-artifact.json"
  }
  $fakeRollbackGate = [ordered]@{
    rollback_proof_freshness = [ordered]@{
      classification = "pass"
      generated_at_utc = [DateTimeOffset]::UtcNow.ToString("o")
      current_commit = $CurrentCommit
      expected_current_commit = $CurrentCommit
      freshness_marker = "current"
      stale_artifact = $false
    }
  }

  $failures = New-Object System.Collections.Generic.List[string]
  $caseResults = @(
    foreach ($case in $cases) {
      $artifact = New-ExternalCommitRunnerAcceptanceSelfTestArtifact -Case ([string]$case.Name) -CurrentCommit $CurrentCommit
      $readback = New-LiveCommitProofReadbackBoundary -Artifact $artifact -ArtifactWrite $fakeWrite -ArtifactRead $fakeRead -PathGate $fakePathGate -CurrentCommit $CurrentCommit -RuntimeCommitMarker $CurrentCommit -ActiveWriter ([string]$singleWriterCutoverProofGateContract.expected_active_writer) -SourceOfTruth ([string]$singleWriterCutoverProofGateContract.expected_active_writer) -RollbackGate $fakeRollbackGate
      $codes = @($readback.blockers) + @($readback.failures)
      $expectedCode = [string]$case.ExpectedCode
      $expectedCodeObserved = [string]::IsNullOrWhiteSpace($expectedCode) -or $expectedCode -in $codes
      $passed = [string]$readback.classification -eq [string]$case.Expected -and $expectedCodeObserved
      if (-not $passed) {
        [void]$failures.Add("self_test_case_unexpected_$($case.Name)")
      }
      [ordered]@{
        case = [string]$case.Name
        expected_classification = [string]$case.Expected
        actual_classification = [string]$readback.classification
        expected_code = $expectedCode
        expected_code_observed = $expectedCodeObserved
        passed = $passed
        blockers = @($readback.blockers)
        failures = @($readback.failures)
      }
    }
  )

  $classification = if ($failures.Count -eq 0) { "pass" } else { "fail" }
  return [ordered]@{
    schema_version = "control_plane_billing_ledger_runtime_writer_commit_runner_artifact_acceptance_self_test.v1"
    requested = $true
    classification = $classification
    case_results = $caseResults
    failures = @($failures)
    production_source_of_truth_switch_allowed = $false
    production_source_of_truth_switch_performed = $false
    script_performs_commit = $false
    script_performs_cutover = $false
    simulated_or_template_artifact_can_pass = $false
    can_substitute_external_commit_proof = $false
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

function New-RuntimeWriterCommitRunnerCommandBoundary {
  param(
    [Parameter(Mandatory = $true)][bool]$PlanRequested,
    [Parameter(Mandatory = $true)][bool]$RunRequested,
    [Parameter(Mandatory = $true)][bool]$LiveOptIn,
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][bool]$LiveDatabaseUrlPresent,
    [Parameter(Mandatory = $true)][bool]$FeatureAvailable,
    [Parameter(Mandatory = $true)][bool]$SchemaAvailable,
    [Parameter(Mandatory = $true)][bool]$ToolAvailable,
    [Parameter(Mandatory = $true)]$ArtifactRead,
    [Parameter(Mandatory = $true)]$PathGate
  )

  $blockers = New-Object System.Collections.Generic.List[string]
  $failures = New-Object System.Collections.Generic.List[string]
  if (-not $PlanRequested) {
    [void]$blockers.Add("runtime_writer_commit_runner_not_requested")
  }
  if ($RunRequested) {
    [void]$blockers.Add("runtime_writer_commit_runner_external_execution_required")
  }
  if (-not $LiveOptIn -or $Mode -ne "ready") {
    [void]$blockers.Add("cutover_mode_not_ready")
  }
  if (-not $LiveDatabaseUrlPresent) {
    [void]$blockers.Add("live_database_url_missing")
  }
  if (-not $FeatureAvailable) {
    [void]$blockers.Add("runtime_writer_feature_unavailable")
  }
  if (-not $SchemaAvailable) {
    [void]$blockers.Add("runtime_schema_unavailable")
  }
  if (-not $ToolAvailable) {
    [void]$blockers.Add("runtime_tool_unavailable")
  }
  if (-not [bool]$PathGate.safe) {
    [void]$blockers.Add([string]$PathGate.reason)
  }

  $classification = "blocker"
  if ($failures.Count -gt 0) {
    $classification = "fail"
  } elseif ($blockers.Count -eq 0) {
    $classification = "planned"
  }

  return [ordered]@{
    schema_version = [string]$runtimeWriterCommitRunnerCommandContract.schema_version
    classification = $classification
    plan_requested = $PlanRequested
    run_requested = $RunRequested
    default_commit = $false
    external_runner_required = $true
    script_executes_runner = $false
    script_performs_commit = $false
    script_performs_cutover = $false
    production_source_of_truth_switch_allowed = $false
    dual_commit_allowed = $false
    controlled_command = [ordered]@{
      script = "scripts/verify_control_plane_billing_ledger_runtime_writer_readiness.ps1"
      flags = @($runtimeWriterCommitRunnerCommandContract.required_script_flags | ForEach-Object { [string]$_ })
      artifact_path_flag = [string]$runtimeWriterCommitRunnerCommandContract.artifact_path_flag
      artifact_relative_path = [string]$PathGate.relative_path
      database_url_output = "presence_marker_only"
      env_value_output = "omitted"
      raw_env_value_echoed = $false
      raw_database_url_echoed = $false
    }
    required_runtime_env_markers = @($runtimeWriterCommitRunnerCommandContract.required_runtime_env_markers | ForEach-Object { [string]$_ })
    required_availability_flags = @($runtimeWriterCommitRunnerCommandContract.required_availability_flags | ForEach-Object { [string]$_ })
    artifact_readback = [ordered]@{
      read_requested = [bool]$ArtifactRead.requested
      read_performed = [bool]$ArtifactRead.performed
      relative_path = [string]$ArtifactRead.relative_path
      path_safe = [bool]$PathGate.safe
    }
    required_markers = [ordered]@{
      row_count_markers_required = $true
      commit_marker_required = $true
      no_dual_commit_marker_required = $true
    }
    blockers = @($blockers | Select-Object -Unique)
    failures = @($failures | Select-Object -Unique)
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

function New-RuntimeWriterCommitRunnerArtifactHandoff {
  param(
    [Parameter(Mandatory = $true)]$CommandBoundary,
    [Parameter(Mandatory = $true)]$ReadbackBoundary
  )

  $blockers = New-Object System.Collections.Generic.List[string]
  $failures = New-Object System.Collections.Generic.List[string]
  if ([string]$CommandBoundary.classification -ne "planned") {
    [void]$blockers.Add("runtime_writer_commit_runner_not_planned")
    foreach ($blocker in @($CommandBoundary.blockers)) {
      [void]$blockers.Add([string]$blocker)
    }
  }
  if ([string]$ReadbackBoundary.classification -eq "fail") {
    foreach ($failure in @($ReadbackBoundary.failures)) {
      if ([string]$failure -eq "live_commit_proof_artifact_schema_mismatch") {
        [void]$failures.Add("runtime_writer_commit_runner_artifact_schema_mismatch")
      } elseif ([string]$failure -eq "runtime_writer_commit_runner_row_count_mismatch") {
        [void]$failures.Add("runtime_writer_commit_runner_row_count_mismatch")
      } elseif ([string]$failure -eq "dual_commit_observed") {
        [void]$failures.Add("runtime_writer_commit_runner_no_dual_commit_failed")
      } else {
        [void]$failures.Add([string]$failure)
      }
    }
  } elseif ([string]$ReadbackBoundary.classification -ne "pass") {
    [void]$blockers.Add("runtime_writer_commit_runner_artifact_handoff_not_passed")
    foreach ($blocker in @($ReadbackBoundary.blockers)) {
      if ([string]$blocker -eq "runtime_writer_commit_runner_row_count_missing") {
        [void]$blockers.Add("runtime_writer_commit_runner_row_count_missing")
      } else {
        [void]$blockers.Add([string]$blocker)
      }
    }
  }

  $classification = "blocker"
  if ($failures.Count -gt 0) {
    $classification = "fail"
  } elseif ($blockers.Count -eq 0) {
    $classification = "pass"
  }

  return [ordered]@{
    schema_version = [string]$runtimeWriterCommitRunnerArtifactHandoffContract.schema_version
    classification = $classification
    command_boundary_schema_version = [string]$CommandBoundary.schema_version
    command_boundary_planned = ([string]$CommandBoundary.classification -eq "planned")
    external_runner_artifact_required = $true
    template_or_simulated_artifact_can_pass = $false
    script_generated_artifact_can_pass = $false
    live_commit_proof_readback_boundary = [string]$ReadbackBoundary.classification
    row_count_markers_required = $true
    row_count_markers_match = if ($null -eq $ReadbackBoundary.row_count_proof) { $false } else { [bool]$ReadbackBoundary.row_count_proof.row_count_markers_match }
    runtime_writer_commit_observed = if ($null -eq $ReadbackBoundary.commit_proof) { $false } else { [bool]$ReadbackBoundary.commit_proof.runtime_writer_commit_observed }
    no_dual_commit_marker_required = $true
    no_dual_commit_observed = if ($null -eq $ReadbackBoundary.no_dual_commit_proof) { $false } else { [bool]$ReadbackBoundary.no_dual_commit_proof.dual_commit_observed }
    production_source_of_truth_switch_allowed = $false
    production_source_of_truth_switch_observed = if ($null -eq $ReadbackBoundary.commit_proof) { $false } else { [bool]$ReadbackBoundary.commit_proof.production_source_of_truth_switch_observed }
    rollback_proof_freshness = $ReadbackBoundary.rollback_proof_freshness
    blockers = @($blockers | Select-Object -Unique)
    failures = @($failures | Select-Object -Unique)
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

  $generatedAt = [string](Get-EvidenceField -Object $Artifact -Field "generated_at_utc")
  $parsedGeneratedAt = [DateTimeOffset]::MinValue
  if ([string]::IsNullOrWhiteSpace($generatedAt) -or -not [DateTimeOffset]::TryParse($generatedAt, [ref]$parsedGeneratedAt)) {
    [void]$refusals.Add("missing_freshness_field")
  }
  $artifactCommit = [string](Get-EvidenceField -Object $Artifact -Field "current_commit")
  $currentCommit = Get-CurrentCommitMarker
  if ([bool](Get-EvidenceField -Object $Artifact -Field "stale_artifact") -or [string](Get-EvidenceField -Object $Artifact -Field "freshness_marker") -ne "current" -or $artifactCommit -ne $currentCommit) {
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
    current_commit = $artifactCommit
    expected_current_commit = $currentCommit
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

function New-LiveDbExecutorProbeCommandBoundary {
  param(
    [Parameter(Mandatory = $true)][bool]$ProbeRequested,
    [Parameter(Mandatory = $true)][bool]$LiveOptIn,
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][bool]$LiveDatabaseUrlPresent,
    [Parameter(Mandatory = $true)][bool]$FeatureAvailable,
    [Parameter(Mandatory = $true)][bool]$SchemaAvailable,
    [Parameter(Mandatory = $true)][bool]$ToolAvailable,
    [Parameter(Mandatory = $true)]$ArtifactWrite,
    [Parameter(Mandatory = $true)]$ArtifactRead,
    [Parameter(Mandatory = $true)]$ReadbackGate
  )

  $blockers = New-Object System.Collections.Generic.List[string]
  $failures = New-Object System.Collections.Generic.List[string]
  if (-not $ProbeRequested) {
    [void]$blockers.Add("live_db_executor_probe_not_requested")
  }
  if (-not $LiveOptIn) {
    [void]$blockers.Add("live_opt_in_missing")
  }
  if ($Mode -ne "ready") {
    [void]$blockers.Add("cutover_mode_not_ready")
  }
  if (-not $LiveDatabaseUrlPresent) {
    [void]$blockers.Add("live_database_url_missing")
  }
  if (-not $FeatureAvailable) {
    [void]$blockers.Add("runtime_writer_feature_unavailable")
  }
  if (-not $SchemaAvailable) {
    [void]$blockers.Add("runtime_schema_unavailable")
  }
  if (-not $ToolAvailable) {
    [void]$blockers.Add("runtime_tool_unavailable")
  }
  if (-not [bool]$ArtifactWrite.performed) {
    [void]$blockers.Add("artifact_write_missing")
  }
  if (-not [bool]$ArtifactRead.performed) {
    [void]$blockers.Add("artifact_read_missing")
  }
  if ([string]$ReadbackGate.classification -eq "blocker") {
    foreach ($refusal in @($ReadbackGate.refusals)) {
      [void]$blockers.Add([string]$refusal)
    }
  }
  if ([string]$ReadbackGate.classification -eq "fail") {
    foreach ($failure in @($ReadbackGate.failures)) {
      [void]$failures.Add([string]$failure)
    }
  }

  $classification = "blocker"
  if ($failures.Count -gt 0) {
    $classification = "fail"
  } elseif ($blockers.Count -eq 0 -and [string]$ReadbackGate.classification -eq "pass") {
    $classification = "pass"
  }

  return [ordered]@{
    schema_version = "control_plane_billing_ledger_live_db_executor_probe_command_boundary.v1"
    classification = $classification
    requested = $ProbeRequested
    safe_command_summary = [ordered]@{
      script = "scripts/verify_control_plane_billing_ledger_runtime_writer_readiness.ps1"
      flags = @("-Live", "-LiveExecutionProbe", "-RunLiveDbExecutorProbe", "-WriteProbeArtifact", "-ReadProbeArtifact")
      required_env_markers = @($modeEnvVar, $databaseUrlEnvVar, $featureEnvVar, $runtimeSchemaEnvVar, $runtimeToolEnvVar)
      database_url_output = "presence_marker_only"
      env_value_output = "omitted"
      raw_env_values_echoed = $false
    }
    required_markers = [ordered]@{
      live_opt_in = $LiveOptIn
      mode_ready = ($Mode -eq "ready")
      live_database_url_present = $LiveDatabaseUrlPresent
      runtime_writer_feature_available = $FeatureAvailable
      runtime_schema_available = $SchemaAvailable
      runtime_tool_available = $ToolAvailable
    }
    rollback_only = [ordered]@{
      rollback_required = $true
      commit_forbidden = $true
      production_writer_replaced = $false
      production_source_of_truth_switch_allowed = $false
      dual_commit_allowed = $false
    }
    row_count_evidence = $ReadbackGate.row_count_evidence
    timing_evidence = $ReadbackGate.transaction_timing_durations
    rollback_no_commit_proof = $ReadbackGate.rollback_no_commit_proof
    artifact_handoff = [ordered]@{
      write_performed = [bool]$ArtifactWrite.performed
      read_performed = [bool]$ArtifactRead.performed
      relative_path = [string]$ArtifactRead.relative_path
    }
    blockers = @($blockers | Select-Object -Unique)
    failures = @($failures | Select-Object -Unique)
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

function New-LiveDbExecutorSqlBridgeReadinessArtifact {
  param(
    [Parameter(Mandatory = $true)]$CommandBoundary,
    [Parameter(Mandatory = $true)]$ReadbackGate,
    [Parameter(Mandatory = $true)][bool]$LiveDatabaseUrlPresent,
    [Parameter(Mandatory = $true)][bool]$SchemaAvailable,
    [Parameter(Mandatory = $true)][bool]$ToolAvailable
  )

  $blockers = New-Object System.Collections.Generic.List[string]
  $failures = New-Object System.Collections.Generic.List[string]
  if (-not $LiveDatabaseUrlPresent) {
    [void]$blockers.Add("live_database_url_missing")
  }
  if (-not $SchemaAvailable) {
    [void]$blockers.Add("runtime_schema_unavailable")
  }
  if (-not $ToolAvailable) {
    [void]$blockers.Add("runtime_tool_unavailable")
  }
  if ([string]$CommandBoundary.classification -eq "blocker") {
    foreach ($blocker in @($CommandBoundary.blockers)) {
      [void]$blockers.Add([string]$blocker)
    }
  }
  if ([string]$CommandBoundary.classification -eq "fail") {
    foreach ($failure in @($CommandBoundary.failures)) {
      [void]$failures.Add([string]$failure)
    }
  }
  if ([string]$ReadbackGate.classification -eq "fail") {
    foreach ($failure in @($ReadbackGate.failures)) {
      [void]$failures.Add([string]$failure)
    }
  }

  $classification = "blocker"
  if ($failures.Count -gt 0) {
    $classification = "fail"
  } elseif ($blockers.Count -eq 0 -and [string]$CommandBoundary.classification -eq "pass" -and [string]$ReadbackGate.classification -eq "pass") {
    $classification = "pass"
  }

  return [ordered]@{
    schema_version = "control_plane_billing_ledger_live_db_executor_sql_bridge_readiness_artifact.v1"
    classification = $classification
    default_db_write_performed = $false
    raw_sql_output = "omitted"
    schema_tool_readiness = [ordered]@{
      live_database_url_present = $LiveDatabaseUrlPresent
      runtime_schema_available = $SchemaAvailable
      runtime_tool_available = $ToolAvailable
      database_url_output = "presence_marker_only"
    }
    bounded_statement_kinds = @(
      "begin_transaction",
      "lock_idempotency_scope",
      "lock_wallet_scope",
      "lock_budget_scope",
      "insert_probe_ledger_entry",
      "mark_probe_idempotency",
      "rollback_transaction"
    )
    bind_marker_counts = [ordered]@{
      lock_idempotency_scope = 4
      lock_wallet_scope = 3
      lock_budget_scope = 3
      insert_probe_ledger_entry = 8
      mark_probe_idempotency = 4
    }
    row_count_field_names = @("statement_kind", "expected_rows", "actual_rows", "rows_match")
    timing_field_names = @(
      "begin_transaction_duration_ms",
      "lock_idempotency_scope_duration_ms",
      "lock_wallet_scope_duration_ms",
      "lock_budget_scope_duration_ms",
      "insert_probe_ledger_entry_duration_ms",
      "mark_probe_idempotency_duration_ms",
      "rollback_transaction_duration_ms"
    )
    row_count_evidence = $ReadbackGate.row_count_evidence
    timing_evidence = $ReadbackGate.transaction_timing_durations
    rollback_no_commit_proof = $ReadbackGate.rollback_no_commit_proof
    rollback_only = $true
    commit_forbidden = $true
    production_writer_unchanged_required = $true
    dual_commit_allowed = $false
    blockers = @($blockers | Select-Object -Unique)
    failures = @($failures | Select-Object -Unique)
    safe_output = [ordered]@{
      raw_sql_output = "omitted"
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

function New-LiveDbRollbackOnlyExecutorGate {
  param(
    [Parameter(Mandatory = $true)][bool]$ExecutionRequested,
    [Parameter(Mandatory = $true)]$SqlBridge,
    [Parameter(Mandatory = $true)]$ReadbackGate,
    [Parameter(Mandatory = $true)]$ArtifactWrite,
    [Parameter(Mandatory = $true)]$ArtifactRead,
    [Parameter(Mandatory = $true)][bool]$RawSqlOutputObserved
  )

  $blockers = New-Object System.Collections.Generic.List[string]
  $failures = New-Object System.Collections.Generic.List[string]
  if (-not $ExecutionRequested) {
    [void]$blockers.Add("rollback_only_executor_not_requested")
  }
  if (-not [bool]$ArtifactWrite.performed) {
    [void]$blockers.Add("artifact_write_missing")
  }
  if (-not [bool]$ArtifactRead.performed) {
    [void]$blockers.Add("artifact_read_missing")
  }
  if ([string]$SqlBridge.classification -eq "blocker") {
    foreach ($blocker in @($SqlBridge.blockers)) {
      [void]$blockers.Add([string]$blocker)
    }
  }
  if ([string]$ReadbackGate.classification -eq "blocker") {
    foreach ($refusal in @($ReadbackGate.refusals)) {
      [void]$blockers.Add([string]$refusal)
    }
  }
  if ([string]$SqlBridge.classification -eq "fail") {
    foreach ($failure in @($SqlBridge.failures)) {
      [void]$failures.Add([string]$failure)
    }
  }
  if ([string]$ReadbackGate.classification -eq "fail") {
    foreach ($failure in @($ReadbackGate.failures)) {
      [void]$failures.Add([string]$failure)
    }
  }
  if ($RawSqlOutputObserved) {
    [void]$failures.Add("raw_sql_output_observed")
  }

  $rollbackProofFreshnessClassification = "blocker"
  if ([string]$ReadbackGate.classification -eq "fail") {
    $rollbackProofFreshnessClassification = "fail"
  } elseif ([string]$ReadbackGate.classification -eq "pass" -and [string]$ReadbackGate.freshness_marker -eq "current" -and -not [bool]$ReadbackGate.stale_artifact) {
    $rollbackProofFreshnessClassification = "pass"
  }

  $classification = "blocker"
  if ($failures.Count -gt 0) {
    $classification = "fail"
  } elseif ($blockers.Count -eq 0 -and [string]$SqlBridge.classification -eq "pass" -and [string]$ReadbackGate.classification -eq "pass") {
    $classification = "pass"
  }

  return [ordered]@{
    schema_version = "control_plane_billing_ledger_live_db_rollback_executor_gate.v1"
    classification = $classification
    requested = $ExecutionRequested
    default_db_write_performed = $false
    executor_mode = "rollback_only_probe"
    bounded_statement_kinds = $SqlBridge.bounded_statement_kinds
    bind_marker_counts = $SqlBridge.bind_marker_counts
    row_count_evidence = $ReadbackGate.row_count_evidence
    timing_evidence = $ReadbackGate.transaction_timing_durations
    rollback_no_commit_proof = $ReadbackGate.rollback_no_commit_proof
    rollback_proof_freshness = [ordered]@{
      classification = $rollbackProofFreshnessClassification
      generated_at_utc = [string]$ReadbackGate.generated_at_utc
      current_commit = [string]$ReadbackGate.current_commit
      expected_current_commit = [string]$ReadbackGate.expected_current_commit
      freshness_marker = [string]$ReadbackGate.freshness_marker
      stale_artifact = [bool]$ReadbackGate.stale_artifact
      artifact_classification = [string]$ReadbackGate.classification
      output = "freshness_marker_and_commit_match_only"
    }
    rollback_only = $true
    commit_forbidden = $true
    production_writer_replaced = $false
    production_source_of_truth_switch_allowed = $false
    dual_commit_allowed = $false
    artifact_handoff = [ordered]@{
      write_performed = [bool]$ArtifactWrite.performed
      read_performed = [bool]$ArtifactRead.performed
      relative_path = [string]$ArtifactRead.relative_path
    }
    provenance = [ordered]@{
      sql_bridge_schema = [string]$SqlBridge.schema_version
      readback_gate_schema = [string]$ReadbackGate.schema_version
      raw_sql_output_observed = $RawSqlOutputObserved
      database_url_output = "presence_marker_only"
    }
    blockers = @($blockers | Select-Object -Unique)
    failures = @($failures | Select-Object -Unique)
    safe_output = [ordered]@{
      raw_sql_output = "omitted"
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

function New-RealLiveDbRollbackAttempt {
  param(
    [Parameter(Mandatory = $true)][bool]$AttemptRequested,
    [Parameter(Mandatory = $true)]$ToolReadiness,
    [Parameter(Mandatory = $true)]$RollbackGate,
    [Parameter(Mandatory = $true)][bool]$LiveDatabaseUrlPresent,
    [Parameter(Mandatory = $true)][bool]$SchemaAvailable,
    [Parameter(Mandatory = $true)][bool]$RuntimeToolAvailable
  )

  $blockers = New-Object System.Collections.Generic.List[string]
  $failures = New-Object System.Collections.Generic.List[string]
  if (-not $AttemptRequested) {
    [void]$blockers.Add("real_live_db_probe_attempt_not_requested")
  }
  if (-not [bool]$ToolReadiness.psql_available -and -not [bool]$ToolReadiness.docker_daemon_available) {
    [void]$blockers.Add("db_probe_tool_unavailable")
  }
  if (-not [bool]$ToolReadiness.docker_daemon_available -and -not [bool]$ToolReadiness.psql_available) {
    [void]$blockers.Add("docker_daemon_unavailable")
  }
  if (-not $LiveDatabaseUrlPresent) {
    [void]$blockers.Add("live_database_url_missing")
  }
  if (-not $SchemaAvailable) {
    [void]$blockers.Add("runtime_schema_unavailable")
  }
  if (-not $RuntimeToolAvailable) {
    [void]$blockers.Add("runtime_tool_unavailable")
  }
  if ([string]$RollbackGate.classification -eq "blocker") {
    foreach ($blocker in @($RollbackGate.blockers)) {
      [void]$blockers.Add([string]$blocker)
    }
  }
  if ([string]$RollbackGate.classification -eq "fail") {
    foreach ($failure in @($RollbackGate.failures)) {
      [void]$failures.Add([string]$failure)
    }
  }

  $classification = "blocker"
  if ($failures.Count -gt 0) {
    $classification = "fail"
  } elseif ($blockers.Count -eq 0 -and [string]$RollbackGate.classification -eq "pass") {
    $classification = "pass"
  }

  return [ordered]@{
    schema_version = "control_plane_billing_ledger_real_live_db_rollback_attempt.v1"
    requested = $AttemptRequested
    classification = $classification
    execution_performed = ($classification -eq "pass")
    executor_mode = "rollback_only_probe"
    copyable_command = ".\scripts\verify_control_plane_billing_ledger_runtime_writer_readiness.ps1 -Live -LiveExecutionProbe -RunLiveDbExecutorProbe -ExecuteRollbackOnlyLiveProbe -AttemptRealLiveDbProbe -WriteProbeArtifact -ReadProbeArtifact -ArtifactPath .tmp\billing-ledger\live-probe-evidence-artifact.json"
    local_tool_readiness = $ToolReadiness
    blocker_reasons = @($blockers | Select-Object -Unique)
    failure_reasons = @($failures | Select-Object -Unique)
    row_count_evidence = $RollbackGate.row_count_evidence
    timing_evidence = $RollbackGate.timing_evidence
    rollback_no_commit_proof = $RollbackGate.rollback_no_commit_proof
    safe_output = [ordered]@{
      raw_sql_output = "omitted"
      database_url_output = "omitted"
      env_value_output = "omitted"
      operation_key_output = "omitted"
      raw_database_url_echoed = $false
      raw_executor_error_detail_echoed = $false
    }
  }
}

function New-ProductionWriterCutoverPreflight {
  param(
    [Parameter(Mandatory = $true)]$LiveAttempt,
    [Parameter(Mandatory = $true)]$RollbackGate,
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $false)]$AcceptanceGate = $null
  )

  $blockers = New-Object System.Collections.Generic.List[string]
  $failures = New-Object System.Collections.Generic.List[string]
  if ([string]$Mode -ne "ready") {
    [void]$blockers.Add("source_of_truth_switch_not_ready")
  }
  [void]$blockers.Add("production_cutover_not_requested")
  if ($null -eq $AcceptanceGate -or [string]$AcceptanceGate.classification -ne "pass") {
    [void]$blockers.Add("production_cutover_acceptance_gate_not_passed")
  }
  if ([string]$LiveAttempt.classification -ne "pass") {
    [void]$blockers.Add("live_rollback_attempt_not_passed")
  }
  if ([string]$RollbackGate.classification -eq "fail") {
    foreach ($failure in @($RollbackGate.failures)) {
      [void]$failures.Add([string]$failure)
    }
  }
  $proof = $RollbackGate.rollback_no_commit_proof
  if ($null -eq $proof -or $proof.rollback_observed -ne $true) {
    [void]$blockers.Add("rollback_path_not_proven")
  }
  if ($null -ne $proof -and ($proof.commit_observed -eq $true -or $proof.dual_commit_observed -eq $true)) {
    [void]$failures.Add("no_dual_commit_contract_failed")
  }

  $classification = "blocker"
  if ($failures.Count -gt 0) {
    $classification = "fail"
  } elseif ($blockers.Count -eq 0) {
    $classification = "pass"
  }

  return [ordered]@{
    schema_version = "control_plane_billing_ledger_production_writer_cutover_preflight.v1"
    classification = $classification
    source_of_truth_switch = [ordered]@{
      requested = $false
      allowed_in_this_script = $false
      required_mode = "ready"
      current_mode = $Mode
    }
    acceptance_gate = if ($null -eq $AcceptanceGate) {
      [ordered]@{
        classification = "blocker"
        commit_eligible = $false
        blocker = "production_cutover_acceptance_gate_missing"
      }
    } else {
      [ordered]@{
        schema_version = [string]$AcceptanceGate.schema_version
        classification = [string]$AcceptanceGate.classification
        commit_eligible = [bool]$AcceptanceGate.commit_eligibility.eligible
        live_commit_readback_classification = [string]$AcceptanceGate.commit_eligibility.live_commit_readback_classification
        source_of_truth_consistent = [bool]$AcceptanceGate.commit_eligibility.source_of_truth_consistent
        rollback_proof_fresh = [bool]$AcceptanceGate.commit_eligibility.rollback_proof_fresh
        no_dual_commit_proof_classification = [string]$AcceptanceGate.commit_eligibility.no_dual_commit_proof_classification
        blockers = @($AcceptanceGate.blockers)
        failures = @($AcceptanceGate.failures)
      }
    }
    no_dual_commit = [ordered]@{
      required = $true
      dual_commit_allowed = $false
      dual_commit_observed = if ($null -eq $proof) { $false } else { [bool]$proof.dual_commit_observed }
    }
    rollback_path = [ordered]@{
      required = $true
      rollback_observed = if ($null -eq $proof) { $false } else { [bool]$proof.rollback_observed }
      proof_freshness = if ($null -eq $AcceptanceGate) { $null } else { $AcceptanceGate.rollback_plan.proof_freshness }
      local_writer_fallback = "control_plane_local_sql_writer"
    }
    row_count_summary = $RollbackGate.row_count_evidence
    duration_summary = $RollbackGate.timing_evidence
    blockers = @($blockers | Select-Object -Unique)
    failures = @($failures | Select-Object -Unique)
    safe_output = [ordered]@{
      database_url_output = "omitted"
      env_value_output = "omitted"
      operation_key_output = "omitted"
      raw_executor_error_detail_echoed = $false
    }
  }
}

function New-CutoverFinalDoDChecklist {
  param(
    [Parameter(Mandatory = $true)]$RuntimeEvidenceTrustGate,
    [Parameter(Mandatory = $true)]$RuntimeWriterCommitRunnerArtifactHandoff,
    [Parameter(Mandatory = $true)]$LiveCommitProofReadbackBoundary,
    [Parameter(Mandatory = $true)]$SingleWriterProofGate,
    [Parameter(Mandatory = $true)]$ProductionCutoverAcceptanceGate,
    [Parameter(Mandatory = $true)]$ProductionWriterCutoverPreflight,
    [Parameter(Mandatory = $true)]$RollbackGate
  )

  $currentRuntimePass = [string]$RuntimeEvidenceTrustGate.classification -eq "container_runtime_current"
  $externalCommitProofPass = [string]$RuntimeWriterCommitRunnerArtifactHandoff.classification -eq "pass"
  $rowCountProofPass = [string]$LiveCommitProofReadbackBoundary.classification -eq "pass" -and [bool]$LiveCommitProofReadbackBoundary.row_count_proof.row_count_markers_match
  $noDualCommitPass = [string]$SingleWriterProofGate.no_dual_commit_proof.classification -eq "pass"
  $singleWriterPass = [string]$SingleWriterProofGate.classification -eq "pass"
  $rollbackProofPass = $null -ne $RollbackGate.rollback_proof_freshness -and [string]$RollbackGate.rollback_proof_freshness.classification -eq "pass"
  $staleTemplateSimulatedRefused = [string]$LiveCommitProofReadbackBoundary.classification -ne "pass" -or (-not [bool]$LiveCommitProofReadbackBoundary.generated_by_this_script -and -not [bool]$LiveCommitProofReadbackBoundary.simulated)
  $sourceOfTruthSwitchPerformed = [bool]$ProductionCutoverAcceptanceGate.commit_eligibility.source_of_truth_switch_performed
  $postCutoverReadbackPass = $sourceOfTruthSwitchPerformed -and [bool]$SingleWriterProofGate.source_of_truth_consistency.consistent -and $noDualCommitPass
  $actualCutoverExecutionReadbackPass = [string]$ProductionWriterCutoverPreflight.classification -eq "pass" -and $sourceOfTruthSwitchPerformed -and $postCutoverReadbackPass

  $checklist = @(
    [ordered]@{
      key = "current_runtime"
      evidence_state = if ($currentRuntimePass) { "pass" } else { "blocker" }
      cutover_ready_required = $true
      final_x_required = $true
      source = [string]$RuntimeEvidenceTrustGate.schema_version
      observed = [string]$RuntimeEvidenceTrustGate.classification
    },
    [ordered]@{
      key = "external_commit_runner_proof"
      evidence_state = if ($externalCommitProofPass) { "pass" } else { "blocker" }
      cutover_ready_required = $true
      final_x_required = $true
      source = [string]$RuntimeWriterCommitRunnerArtifactHandoff.schema_version
      observed = [string]$RuntimeWriterCommitRunnerArtifactHandoff.classification
      simulated_or_template_can_pass = $false
    },
    [ordered]@{
      key = "row_count_proof"
      evidence_state = if ($rowCountProofPass) { "pass" } else { "blocker" }
      cutover_ready_required = $true
      final_x_required = $true
      observed = if ($null -eq $LiveCommitProofReadbackBoundary.row_count_proof) { "missing" } else { "row_count_markers_match=$([bool]$LiveCommitProofReadbackBoundary.row_count_proof.row_count_markers_match)" }
    },
    [ordered]@{
      key = "no_dual_commit"
      evidence_state = if ($noDualCommitPass) { "pass" } else { "blocker" }
      cutover_ready_required = $true
      final_x_required = $true
      observed = [string]$SingleWriterProofGate.no_dual_commit_proof.classification
    },
    [ordered]@{
      key = "active_writer"
      evidence_state = if ($singleWriterPass) { "pass" } else { "blocker" }
      cutover_ready_required = $true
      final_x_required = $true
      expected = "billing_ledger_runtime_writer"
      observed = [string]$SingleWriterProofGate.classification
    },
    [ordered]@{
      key = "source_of_truth_switch"
      evidence_state = if ($sourceOfTruthSwitchPerformed) { "pass" } else { "blocker" }
      cutover_ready_required = $false
      final_x_required = $true
      observed = if ($sourceOfTruthSwitchPerformed) { "performed" } else { "not_performed_by_this_script" }
      source_of_truth_switch_allowed_in_this_script = $false
    },
    [ordered]@{
      key = "rollback_command_and_proof"
      evidence_state = if ($rollbackProofPass) { "pass" } else { "blocker" }
      cutover_ready_required = $true
      final_x_required = $true
      rollback_command_available = $true
      proof_freshness = if ($null -eq $RollbackGate.rollback_proof_freshness) { "missing" } else { [string]$RollbackGate.rollback_proof_freshness.classification }
    },
    [ordered]@{
      key = "post_cutover_readback"
      evidence_state = if ($postCutoverReadbackPass) { "pass" } else { "blocker" }
      cutover_ready_required = $false
      final_x_required = $true
      observed = if ($postCutoverReadbackPass) { "source_of_truth_and_active_writer_runtime" } else { "missing_actual_cutover_readback" }
    },
    [ordered]@{
      key = "stale_simulated_template_refusal"
      evidence_state = if ($staleTemplateSimulatedRefused) { "pass" } else { "fail" }
      cutover_ready_required = $true
      final_x_required = $true
      template_can_pass = $false
      simulated_can_pass = $false
      stale_can_pass = $false
    }
  )

  $cutoverReadyEligible = $currentRuntimePass -and $externalCommitProofPass -and $rowCountProofPass -and $noDualCommitPass -and $singleWriterPass -and $rollbackProofPass -and $staleTemplateSimulatedRefused
  $finalXEligible = $cutoverReadyEligible -and $actualCutoverExecutionReadbackPass
  $missingForCutoverReady = @($checklist | Where-Object { [bool]$_.cutover_ready_required -and [string]$_.evidence_state -ne "pass" } | ForEach-Object { [string]$_.key })
  $missingForFinalX = @($checklist | Where-Object { [bool]$_.final_x_required -and [string]$_.evidence_state -ne "pass" } | ForEach-Object { [string]$_.key })

  return [ordered]@{
    schema_version = [string]$cutoverFinalDoDChecklistContract.schema_version
    classification = if ($finalXEligible) { "final_x_eligible" } elseif ($cutoverReadyEligible) { "cutover_ready" } else { "blocker" }
    cutover_ready_eligible = $cutoverReadyEligible
    final_x_eligible = $finalXEligible
    cutover_ready_can_mark_final_x = $false
    accepted_for_review_can_mark_final_x = $false
    simulation_can_mark_final_x = $false
    template_can_mark_final_x = $false
    default_commit = $false
    default_cutover = $false
    default_db_write = $false
    script_performs_commit = $false
    script_performs_cutover = $false
    checklist = $checklist
    missing_for_cutover_ready = $missingForCutoverReady
    missing_for_final_x = $missingForFinalX
    evidence_for_cutover_ready_only = @(
      "current_runtime",
      "external_commit_runner_proof",
      "row_count_proof",
      "no_dual_commit",
      "active_writer",
      "rollback_command_and_proof",
      "stale_simulated_template_refusal"
    )
    evidence_required_for_final_x = @(
      "actual_source_of_truth_switch_execution",
      "post_cutover_readback",
      "post_cutover_no_dual_commit_readback",
      "post_cutover_rollback_command_still_available"
    )
    actual_cutover_execution_readback = [ordered]@{
      source_of_truth_switch_performed = $sourceOfTruthSwitchPerformed
      post_cutover_readback_pass = $postCutoverReadbackPass
      production_writer_cutover_preflight_classification = [string]$ProductionWriterCutoverPreflight.classification
      final_x_requires_external_execution = $true
    }
    refusal_classification = $cutoverFinalDoDChecklistContract.refusal_classification
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

function New-CutoverOperatorRunbookPreflight {
  param(
    [Parameter(Mandatory = $true)]$CutoverFinalDoDChecklist,
    [Parameter(Mandatory = $true)]$RuntimeEvidenceTrustGate,
    [Parameter(Mandatory = $true)]$RuntimeWriterCommitRunnerCommandBoundary,
    [Parameter(Mandatory = $true)]$RuntimeWriterCommitRunnerArtifactHandoff,
    [Parameter(Mandatory = $true)]$LiveCommitProofReadbackBoundary,
    [Parameter(Mandatory = $true)]$SingleWriterProofGate,
    [Parameter(Mandatory = $true)]$ProductionCutoverAcceptanceGate,
    [Parameter(Mandatory = $true)]$ProductionWriterCutoverPreflight,
    [Parameter(Mandatory = $true)]$RollbackGate,
    [Parameter(Mandatory = $true)]$LiveCommitProofArtifactPathGate
  )

  $refusals = New-Object System.Collections.Generic.List[string]
  if ([string]$RuntimeEvidenceTrustGate.classification -eq "container_runtime_stale") {
    [void]$refusals.Add("stale_runtime")
  }
  if ([string]$LiveCommitProofReadbackBoundary.classification -ne "pass") {
    foreach ($blocker in @($LiveCommitProofReadbackBoundary.blockers)) {
      $code = [string]$blocker
      if ($code -like "*stale*") { [void]$refusals.Add("stale_artifact") }
      if ($code -like "*simulated*") { [void]$refusals.Add("simulated_artifact") }
      if ($code -like "*generated_by_script*") { [void]$refusals.Add("template_artifact") }
    }
    foreach ($failure in @($LiveCommitProofReadbackBoundary.failures)) {
      $code = [string]$failure
      if ($code -eq "runtime_writer_commit_runner_row_count_mismatch") { [void]$refusals.Add("row_count_mismatch") }
      if ($code -eq "runtime_container_commit_stale") { [void]$refusals.Add("stale_runtime") }
      if ($code -eq "active_writer_source_of_truth_mismatch") { [void]$refusals.Add("active_writer_mismatch") }
      if ($code -eq "dual_commit_observed") { [void]$refusals.Add("no_dual_failure") }
    }
  }
  if ([string]$SingleWriterProofGate.no_dual_commit_proof.classification -eq "fail") {
    [void]$refusals.Add("no_dual_failure")
  }
  if (-not [bool]$SingleWriterProofGate.source_of_truth_consistency.consistent) {
    [void]$refusals.Add("active_writer_mismatch")
  }
  if (-not [bool]$ProductionCutoverAcceptanceGate.commit_eligibility.source_of_truth_switch_performed) {
    [void]$refusals.Add("source_of_truth_not_switched")
  }
  if ($null -eq $RollbackGate.rollback_proof_freshness -or [string]$RollbackGate.rollback_proof_freshness.classification -ne "pass") {
    [void]$refusals.Add("rollback_missing")
  }
  if (-not [bool]$CutoverFinalDoDChecklist.actual_cutover_execution_readback.post_cutover_readback_pass) {
    [void]$refusals.Add("post_cutover_readback_missing")
  }
  if (-not [bool]$LiveCommitProofArtifactPathGate.safe) {
    [void]$refusals.Add("unsafe_artifact_path")
  }

  $actualCutoverExecuted = [bool]$ProductionCutoverAcceptanceGate.commit_eligibility.source_of_truth_switch_performed
  return [ordered]@{
    schema_version = [string]$cutoverOperatorRunbookPreflightContract.schema_version
    classification = if ([bool]$CutoverFinalDoDChecklist.final_x_eligible) { "final_x_eligible" } elseif ([bool]$CutoverFinalDoDChecklist.cutover_ready_eligible) { "cutover_ready" } else { "blocker" }
    cutover_ready = [bool]$CutoverFinalDoDChecklist.cutover_ready_eligible
    actual_cutover_executed = $actualCutoverExecuted
    final_x_eligible = [bool]$CutoverFinalDoDChecklist.final_x_eligible
    default_commit = $false
    default_cutover = $false
    default_db_write = $false
    script_performs_commit = $false
    script_performs_cutover = $false
    contract_only_final_x_allowed = $false
    exact_command_runbook = @($cutoverOperatorRunbookPreflightContract.ordered_steps)
    current_gate_summary = [ordered]@{
      runtime_evidence = [string]$RuntimeEvidenceTrustGate.classification
      runner_command = [string]$RuntimeWriterCommitRunnerCommandBoundary.classification
      external_commit_proof = [string]$RuntimeWriterCommitRunnerArtifactHandoff.classification
      commit_proof_readback = [string]$LiveCommitProofReadbackBoundary.classification
      single_writer = [string]$SingleWriterProofGate.classification
      production_acceptance = [string]$ProductionCutoverAcceptanceGate.classification
      production_cutover_preflight = [string]$ProductionWriterCutoverPreflight.classification
      rollback_proof_freshness = if ($null -eq $RollbackGate.rollback_proof_freshness) { "missing" } else { [string]$RollbackGate.rollback_proof_freshness.classification }
    }
    artifact_schema = $cutoverOperatorRunbookPreflightContract.artifact_schema
    artifact_path = [ordered]@{
      safe = [bool]$LiveCommitProofArtifactPathGate.safe
      relative_path = [string]$LiveCommitProofArtifactPathGate.relative_path
      raw_path_output = "omitted"
    }
    refusal_taxonomy = @($cutoverOperatorRunbookPreflightContract.refusal_taxonomy | ForEach-Object { [string]$_ })
    observed_refusals = @($refusals | Select-Object -Unique)
    state_definitions = $cutoverOperatorRunbookPreflightContract.state_definitions
    state_difference = [ordered]@{
      cutover_ready = "pre-cutover proof bundle current; does not switch source-of-truth and cannot mark final x"
      actual_cutover_executed = "separate explicit operator opt-in switched production source-of-truth"
      final_x_eligible = "actual cutover plus post-cutover source-of-truth/active-writer/no-dual/rollback readback"
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

function New-CutoverEvidenceAcceptedShapeArtifact {
  param(
    [Parameter(Mandatory = $true)][string]$CurrentCommit,
    [AllowNull()][string]$RuntimeCommitMarker
  )

  $runtimeCommit = if ([string]::IsNullOrWhiteSpace($RuntimeCommitMarker)) { $CurrentCommit } else { $RuntimeCommitMarker }
  return [ordered]@{
    schema_version = [string]$cutoverEvidenceAcceptanceMatrixContract.artifact_schema.schema_version
    artifact_provenance = [ordered]@{
      source = "accepted_shape_simulation_fixture"
      simulated = $true
      template = $false
      generated_by_this_script = $true
      simulation_can_mark_final_x = $false
    }
    generated_at_utc = [DateTimeOffset]::UtcNow.ToString("o")
    current_commit = $CurrentCommit
    runtime_container_commit = $runtimeCommit
    freshness_marker = "current"
    stale_artifact = $false
    external_runner_provenance = [ordered]@{
      runner = "external_operator_cutover_tool"
      runner_schema_version = "control_plane_billing_ledger_runtime_writer_commit_runner_command.v1"
      runtime_writer = "billing_ledger_runtime_writer"
      generated_by_this_script = $false
    }
    commit_proof_row_counts = @(
      [ordered]@{
        statement_kind = "runtime_writer_commit"
        expected_rows = "one"
        actual_rows = 1
        rows_match = $true
      },
      [ordered]@{
        statement_kind = "source_of_truth_marker_readback"
        expected_rows = "one"
        actual_rows = 1
        rows_match = $true
      }
    )
    no_dual_result = [ordered]@{
      passed = $true
      dual_commit_observed = $false
      active_writer_count = 1
    }
    active_writer_before = "control_plane_local_sql_writer"
    active_writer_after = "billing_ledger_runtime_writer"
    source_of_truth_before = "control_plane_local_sql_writer"
    source_of_truth_after = "billing_ledger_runtime_writer"
    actual_cutover_opt_in_marker = [ordered]@{
      performed = $true
      flag = "--execute-source-of-truth-switch"
      env_var = "AI_CONTROL_PLANE_BILLING_LEDGER_EXECUTE_PRODUCTION_CUTOVER"
      operator_ack = "present_marker_only"
    }
    post_cutover_readback = [ordered]@{
      performed = $true
      source_of_truth = "billing_ledger_runtime_writer"
      active_writer = "billing_ledger_runtime_writer"
      no_dual_commit = $true
    }
    rollback_command = [ordered]@{
      script = "external_operator_cutover_tool"
      flags = @("--rollback-source-of-truth-switch", "--restore-active-writer=control_plane_local_sql_writer")
      database_url_output = "presence_marker_only"
      env_value_output = "omitted"
    }
    rollback_proof = [ordered]@{
      present = $true
      performed = $true
      fallback_writer = "control_plane_local_sql_writer"
      proof_generated_at_utc = [DateTimeOffset]::UtcNow.ToString("o")
    }
    duration_timing = [ordered]@{
      commit_duration_ms = 1
      cutover_duration_ms = 1
      post_cutover_readback_duration_ms = 1
      rollback_readiness_duration_ms = 1
    }
    secret_safe_omission = [ordered]@{
      database_url_output = "omitted"
      env_value_output = "omitted"
      operation_key_output = "omitted"
      raw_secret_present = $false
      raw_env_value_echoed = $false
      raw_database_url_echoed = $false
      raw_metadata_echoed = $false
      credential_material_echoed = $false
    }
  }
}

function Test-CutoverEvidenceTruthyField {
  param(
    [AllowNull()]$Object,
    [Parameter(Mandatory = $true)][string]$Field
  )

  if ($null -eq $Object -or -not (Test-EvidenceField -Object $Object -Field $Field)) {
    return $false
  }

  return [bool](Get-EvidenceField -Object $Object -Field $Field)
}

function New-CutoverEvidenceAcceptanceMatrix {
  param(
    [Parameter(Mandatory = $true)]$ArtifactRead,
    [Parameter(Mandatory = $true)]$PathGate,
    [Parameter(Mandatory = $true)][bool]$SimulationRequested,
    [Parameter(Mandatory = $true)][string]$CurrentCommit,
    [AllowNull()][string]$RuntimeCommitMarker
  )

  $blockers = New-Object System.Collections.Generic.List[string]
  $failures = New-Object System.Collections.Generic.List[string]
  $artifact = $ArtifactRead.artifact
  $artifactContentAvailable = $SimulationRequested -or [bool]$ArtifactRead.performed
  $artifactSource = if ($SimulationRequested) { "accepted_shape_simulation" } elseif ([bool]$ArtifactRead.performed) { "bounded_artifact_readback" } else { "missing_artifact" }

  if (-not $SimulationRequested) {
    if ([bool]$ArtifactRead.requested -and -not [bool]$PathGate.safe) {
      [void]$blockers.Add("unsafe_path")
    }
    if (-not [bool]$ArtifactRead.performed) {
      [void]$blockers.Add("missing_artifact")
    }
  }

  if ($artifactContentAvailable) {
    foreach ($requiredField in @($cutoverEvidenceAcceptanceMatrixContract.artifact_schema.required_fields | ForEach-Object { [string]$_ })) {
      if ($null -eq $artifact -or -not (Test-EvidenceField -Object $artifact -Field $requiredField)) {
        [void]$blockers.Add("commit_proof_missing")
        break
      }
    }
  }

  $provenance = if ($null -eq $artifact -or -not (Test-EvidenceField -Object $artifact -Field "artifact_provenance")) { $null } else { Get-EvidenceField -Object $artifact -Field "artifact_provenance" }
  $secretSafe = if ($null -eq $artifact -or -not (Test-EvidenceField -Object $artifact -Field "secret_safe_omission")) { $null } else { Get-EvidenceField -Object $artifact -Field "secret_safe_omission" }
  $noDual = if ($null -eq $artifact -or -not (Test-EvidenceField -Object $artifact -Field "no_dual_result")) { $null } else { Get-EvidenceField -Object $artifact -Field "no_dual_result" }
  $actualOptIn = if ($null -eq $artifact -or -not (Test-EvidenceField -Object $artifact -Field "actual_cutover_opt_in_marker")) { $null } else { Get-EvidenceField -Object $artifact -Field "actual_cutover_opt_in_marker" }
  $postCutoverReadback = if ($null -eq $artifact -or -not (Test-EvidenceField -Object $artifact -Field "post_cutover_readback")) { $null } else { Get-EvidenceField -Object $artifact -Field "post_cutover_readback" }
  $rollbackProof = if ($null -eq $artifact -or -not (Test-EvidenceField -Object $artifact -Field "rollback_proof")) { $null } else { Get-EvidenceField -Object $artifact -Field "rollback_proof" }
  $rowCounts = if ($null -eq $artifact -or -not (Test-EvidenceField -Object $artifact -Field "commit_proof_row_counts")) { @() } else { @(Get-EvidenceField -Object $artifact -Field "commit_proof_row_counts") }

  $artifactSimulated = $SimulationRequested -or (Test-CutoverEvidenceTruthyField -Object $provenance -Field "simulated") -or (Test-CutoverEvidenceTruthyField -Object $artifact -Field "simulated")
  $artifactTemplate = (Test-CutoverEvidenceTruthyField -Object $provenance -Field "template") -or (Test-CutoverEvidenceTruthyField -Object $artifact -Field "template") -or (Test-CutoverEvidenceTruthyField -Object $artifact -Field "generated_by_this_script")
  $rawSecretPresent = (Test-CutoverEvidenceTruthyField -Object $secretSafe -Field "raw_secret_present") -or (Test-CutoverEvidenceTruthyField -Object $artifact -Field "raw_secret_present")
  $staleArtifact = (Test-CutoverEvidenceTruthyField -Object $artifact -Field "stale_artifact") -or ($null -ne $artifact -and (Test-EvidenceField -Object $artifact -Field "freshness_marker") -and [string](Get-EvidenceField -Object $artifact -Field "freshness_marker") -ne "current")
  $environmentScope = if ($null -eq $artifact -or -not (Test-EvidenceField -Object $artifact -Field "environment_scope")) { "" } else { [string](Get-EvidenceField -Object $artifact -Field "environment_scope") }

  if ($artifactContentAvailable -and $artifactTemplate -and -not $SimulationRequested) {
    [void]$blockers.Add("template_artifact")
  }
  if ($artifactContentAvailable -and $artifactSimulated -and -not $SimulationRequested) {
    [void]$blockers.Add("simulated_artifact")
  } elseif ($artifactContentAvailable -and $artifactSimulated) {
    [void]$blockers.Add("simulated_artifact")
  }
  if ($artifactContentAvailable -and $staleArtifact) {
    [void]$blockers.Add("stale_artifact")
  }
  if ($artifactContentAvailable -and $rawSecretPresent) {
    [void]$failures.Add("raw_secret_present")
  }
  if ($artifactContentAvailable -and $environmentScope -eq "local_dev") {
    [void]$blockers.Add("local_dev_cutover_artifact_not_production_final")
  } elseif ($artifactContentAvailable -and -not [string]::IsNullOrWhiteSpace($environmentScope) -and $environmentScope -ne "production") {
    [void]$blockers.Add("non_production_cutover_artifact_not_production_final")
  }
  $cutoverArtifactRelativePath = if ($null -eq $PathGate -or -not (Test-EvidenceField -Object $PathGate -Field "relative_path")) { "" } else { ([string]$PathGate.relative_path).Replace("\", "/") }
  if ($artifactContentAvailable -and $environmentScope -eq "production" -and $cutoverArtifactRelativePath -ne ".tmp/billing-ledger/cutover-evidence-artifact.json") {
    [void]$blockers.Add("production_cutover_artifact_path_not_canonical")
  }

  $runtimeCommit = if ($null -eq $artifact -or -not (Test-EvidenceField -Object $artifact -Field "runtime_container_commit")) { "" } else { [string](Get-EvidenceField -Object $artifact -Field "runtime_container_commit") }
  $expectedRuntimeCommit = if ([string]::IsNullOrWhiteSpace($RuntimeCommitMarker)) { $CurrentCommit } else { $RuntimeCommitMarker }
  if ($artifactContentAvailable -and $null -ne $artifact -and -not (Test-CommitMarkerMatches -CurrentCommit $expectedRuntimeCommit -RuntimeCommit $runtimeCommit)) {
    [void]$blockers.Add("runtime_mismatch")
  }
  if ($artifactContentAvailable -and $null -ne $artifact -and (Test-EvidenceField -Object $artifact -Field "current_commit") -and [string](Get-EvidenceField -Object $artifact -Field "current_commit") -ne $CurrentCommit) {
    [void]$blockers.Add("stale_artifact")
  }

  if ($artifactContentAvailable -and $rowCounts.Count -eq 0) {
    [void]$blockers.Add("commit_proof_missing")
  }
  foreach ($row in @($rowCounts)) {
    if ((Test-EvidenceField -Object $row -Field "rows_match") -and -not [bool](Get-EvidenceField -Object $row -Field "rows_match")) {
      [void]$failures.Add("row_count_mismatch")
    }
  }

  $noDualPassed = $null -ne $noDual -and (Test-CutoverEvidenceTruthyField -Object $noDual -Field "passed") -and -not (Test-CutoverEvidenceTruthyField -Object $noDual -Field "dual_commit_observed")
  if ($artifactContentAvailable -and -not $noDualPassed) {
    [void]$failures.Add("no_dual_failure")
  }

  $activeWriterAfter = if ($null -eq $artifact -or -not (Test-EvidenceField -Object $artifact -Field "active_writer_after")) { "" } else { [string](Get-EvidenceField -Object $artifact -Field "active_writer_after") }
  $sourceOfTruthAfter = if ($null -eq $artifact -or -not (Test-EvidenceField -Object $artifact -Field "source_of_truth_after")) { "" } else { [string](Get-EvidenceField -Object $artifact -Field "source_of_truth_after") }
  if ($artifactContentAvailable -and $null -ne $artifact -and $activeWriterAfter -ne "billing_ledger_runtime_writer") {
    [void]$failures.Add("active_writer_mismatch")
  }
  if ($artifactContentAvailable -and $null -ne $artifact -and $sourceOfTruthAfter -ne "billing_ledger_runtime_writer") {
    [void]$blockers.Add("source_of_truth_not_switched")
  }

  $actualOptInPerformed = $null -ne $actualOptIn -and (Test-CutoverEvidenceTruthyField -Object $actualOptIn -Field "performed")
  if ($artifactContentAvailable -and $null -ne $artifact -and -not $actualOptInPerformed) {
    [void]$blockers.Add("source_of_truth_not_switched")
  }

  $postCutoverReadbackPassed = $null -ne $postCutoverReadback -and (Test-CutoverEvidenceTruthyField -Object $postCutoverReadback -Field "performed") -and [string](Get-EvidenceField -Object $postCutoverReadback -Field "source_of_truth") -eq "billing_ledger_runtime_writer" -and [string](Get-EvidenceField -Object $postCutoverReadback -Field "active_writer") -eq "billing_ledger_runtime_writer" -and (Test-CutoverEvidenceTruthyField -Object $postCutoverReadback -Field "no_dual_commit")
  if ($artifactContentAvailable -and $null -ne $artifact -and -not $postCutoverReadbackPassed) {
    [void]$blockers.Add("post_cutover_readback_missing")
  }

  $rollbackProofPresent = $null -ne $rollbackProof -and (Test-CutoverEvidenceTruthyField -Object $rollbackProof -Field "present") -and (Test-CutoverEvidenceTruthyField -Object $rollbackProof -Field "performed")
  if ($artifactContentAvailable -and $null -ne $artifact -and -not $rollbackProofPresent) {
    [void]$blockers.Add("rollback_proof_missing")
  }

  $actualCutoverExecuted = (-not $artifactSimulated) -and (-not $artifactTemplate) -and $actualOptInPerformed -and ($sourceOfTruthAfter -eq "billing_ledger_runtime_writer") -and ($activeWriterAfter -eq "billing_ledger_runtime_writer") -and $postCutoverReadbackPassed
  $reviewBlockingCodes = @($blockers | Where-Object { [string]$_ -notin @("source_of_truth_not_switched", "post_cutover_readback_missing", "rollback_proof_missing", "simulated_artifact") })
  $cutoverEvidenceAcceptedForReview = $false
  if ($SimulationRequested) {
    $cutoverEvidenceAcceptedForReview = ($failures.Count -eq 0 -and ($reviewBlockingCodes.Count -eq 0))
  } else {
    $cutoverEvidenceAcceptedForReview = ($failures.Count -eq 0 -and ($reviewBlockingCodes.Count -eq 0) -and -not $artifactSimulated -and -not $artifactTemplate)
  }
  if ($actualCutoverExecuted -and -not $rollbackProofPresent) {
    $cutoverEvidenceAcceptedForReview = $false
  }

  $finalXEligible = $cutoverEvidenceAcceptedForReview -and $actualCutoverExecuted -and $rollbackProofPresent -and -not $artifactSimulated -and -not $artifactTemplate -and ($failures.Count -eq 0) -and (($blockers | Where-Object { [string]$_ -ne "simulated_artifact" }).Count -eq 0)
  $classification = "blocker"
  if ($failures.Count -gt 0) {
    $classification = "fail"
  } elseif ($finalXEligible) {
    $classification = "accepted_final_x_eligible"
  } elseif ($cutoverEvidenceAcceptedForReview) {
    $classification = "accepted_for_review"
  }

  return [ordered]@{
    schema_version = [string]$cutoverEvidenceAcceptanceMatrixContract.schema_version
    artifact_source = $artifactSource
    read_requested = [bool]$ArtifactRead.requested
    read_performed = [bool]$ArtifactRead.performed
    simulation_requested = $SimulationRequested
    simulation_can_mark_final_x = $false
    template_can_mark_final_x = $false
    accepted_for_review_can_mark_final_x = $false
    cutover_ready_can_mark_final_x = $false
    classification = $classification
    cutover_evidence_accepted_for_review = $cutoverEvidenceAcceptedForReview
    actual_cutover_executed = $actualCutoverExecuted
    final_x_eligible = $finalXEligible
    default_read_artifact = $false
    default_commit = $false
    default_cutover = $false
    default_db_write = $false
    script_performs_commit = $false
    script_performs_cutover = $false
    artifact_path = [ordered]@{
      safe = [bool]$PathGate.safe
      classification = if ([bool]$PathGate.safe) { "pass" } else { "blocker" }
      reason = [string]$PathGate.reason
      relative_path = [string]$PathGate.relative_path
      raw_path_output = "omitted"
    }
    artifact_schema = [ordered]@{
      expected_schema_version = [string]$cutoverEvidenceAcceptanceMatrixContract.artifact_schema.schema_version
      observed_schema_version = if ($null -eq $artifact -or -not (Test-EvidenceField -Object $artifact -Field "schema_version")) { $null } else { [string](Get-EvidenceField -Object $artifact -Field "schema_version") }
      required_fields = @($cutoverEvidenceAcceptanceMatrixContract.artifact_schema.required_fields | ForEach-Object { [string]$_ })
    }
    state_difference = [ordered]@{
      cutover_evidence_accepted_for_review = "artifact is bounded, current, secret-safe, and structurally accepted for operator review; simulation is allowed only here"
      actual_cutover_executed = "real non-simulated artifact proves explicit source-of-truth switch plus post-cutover readback"
      final_x_eligible = "real actual cutover artifact also proves rollback/no-dual/row-count/readback and can close E9"
    }
    evidence = [ordered]@{
      runtime_container_commit = $runtimeCommit
      environment_scope = $environmentScope
      external_runner_provenance_present = ($null -ne $artifact -and (Test-EvidenceField -Object $artifact -Field "external_runner_provenance"))
      commit_proof_row_counts_present = ($rowCounts.Count -gt 0)
      no_dual_passed = $noDualPassed
      active_writer_after = $activeWriterAfter
      source_of_truth_after = $sourceOfTruthAfter
      actual_cutover_opt_in_performed = $actualOptInPerformed
      post_cutover_readback_passed = $postCutoverReadbackPassed
      rollback_proof_present = $rollbackProofPresent
      raw_secret_present = $rawSecretPresent
    }
    refusal_taxonomy = $cutoverEvidenceAcceptanceMatrixContract.refusal_taxonomy
    observed_refusals = @($blockers | Select-Object -Unique)
    observed_failures = @($failures | Select-Object -Unique)
    safe_output = [ordered]@{
      database_url_output = "omitted"
      env_value_output = "omitted"
      operation_key_output = "omitted"
      raw_path_output = "omitted"
      raw_env_value_echoed = $false
      raw_database_url_echoed = $false
      raw_metadata_echoed = $false
      credential_material_echoed = $false
      raw_executor_error_detail_echoed = $false
    }
  }
}

function New-CanonicalCutoverArtifactGuardSelfTestArtifact {
  param(
    [Parameter(Mandatory = $true)][string]$CaseName,
    [Parameter(Mandatory = $true)][string]$CurrentCommit,
    [AllowNull()][string]$RuntimeCommitMarker
  )

  $artifact = New-CutoverEvidenceAcceptedShapeArtifact -CurrentCommit $CurrentCommit -RuntimeCommitMarker $RuntimeCommitMarker
  $artifact["environment_scope"] = "production"
  $artifact["simulated"] = $false
  $artifact["template"] = $false
  $artifact["generated_by_this_script"] = $false
  $artifact["artifact_provenance"]["source"] = "canonical_cutover_artifact_guard_selftest_fixture"
  $artifact["artifact_provenance"]["simulated"] = $false
  $artifact["artifact_provenance"]["template"] = $false
  $artifact["artifact_provenance"]["generated_by_this_script"] = $false
  $artifact["artifact_provenance"]["production_cutover"] = $true
  $artifact["artifact_provenance"]["canonical_production_artifact"] = $true
  $artifact["artifact_provenance"]["simulation_can_mark_final_x"] = $false

  switch ($CaseName) {
    "staging_persistent_cutover_artifact" {
      $artifact["environment_scope"] = "staging"
      $artifact["artifact_provenance"]["production_cutover"] = $false
      $artifact["artifact_provenance"]["canonical_production_artifact"] = $false
    }
    "canonical_production_missing_rollback" {
      $artifact["rollback_proof"]["present"] = $false
      $artifact["rollback_proof"]["performed"] = $false
      $artifact["rollback_proof"]["rollback_observed"] = $false
      $artifact["rollback_proof"]["reason"] = "selftest_missing_rollback_proof"
    }
    "canonical_production_no_dual_failure" {
      $artifact["no_dual_result"]["passed"] = $false
      $artifact["no_dual_result"]["dual_commit_observed"] = $true
      $artifact["no_dual_result"]["reason"] = "selftest_dual_commit_observed"
      $artifact["post_cutover_readback"]["no_dual_commit"] = $false
    }
  }

  return $artifact
}

function Invoke-CanonicalCutoverArtifactGuardSelfTest {
  param(
    [Parameter(Mandatory = $true)][bool]$Requested,
    [Parameter(Mandatory = $true)][string]$CurrentCommit,
    [AllowNull()][string]$RuntimeCommitMarker
  )

  if (-not $Requested) {
    return [ordered]@{
      requested = $false
      performed = $false
      classification = "not_requested"
      db_io_performed = $false
      production_cutover_performed = $false
    }
  }

  $cases = @(
    [ordered]@{
      name = "staging_persistent_cutover_artifact_final_false"
      artifact_case = "staging_persistent_cutover_artifact"
      relative_path = ".tmp/billing-ledger/cutover-evidence-artifact.staging.persistent-s105.json"
      expected_observed_refusal = "non_production_cutover_artifact_not_production_final"
      expected_final_blocking_reason = "non_production_cutover_artifact_not_production_final"
    },
    [ordered]@{
      name = "production_non_canonical_path_final_false"
      artifact_case = "production_non_canonical_path"
      relative_path = ".tmp/billing-ledger/cutover-evidence-artifact.production.noncanonical-s108.json"
      expected_observed_refusal = "production_cutover_artifact_path_not_canonical"
      expected_final_blocking_reason = "production_cutover_artifact_path_not_canonical"
    },
    [ordered]@{
      name = "canonical_production_missing_rollback_final_false"
      artifact_case = "canonical_production_missing_rollback"
      relative_path = ".tmp/billing-ledger/cutover-evidence-artifact.json"
      expected_observed_refusal = "rollback_proof_missing"
      expected_final_blocking_reason = "rollback_proof_missing"
    },
    [ordered]@{
      name = "canonical_production_no_dual_failure_final_false"
      artifact_case = "canonical_production_no_dual_failure"
      relative_path = ".tmp/billing-ledger/cutover-evidence-artifact.json"
      expected_observed_failure = "no_dual_failure"
      expected_final_blocking_reason = "no_dual_proof_failed"
    }
  )

  $caseResults = @()
  $failures = New-Object System.Collections.Generic.List[string]

  foreach ($case in @($cases)) {
    $artifact = New-CanonicalCutoverArtifactGuardSelfTestArtifact -CaseName ([string]$case.artifact_case) -CurrentCommit $CurrentCommit -RuntimeCommitMarker $RuntimeCommitMarker
    $artifactRead = [ordered]@{
      requested = $true
      performed = $true
      classification = "pass"
      reason = "canonical_cutover_artifact_guard_selftest_fixture"
      relative_path = [string]$case.relative_path
      artifact = $artifact
    }
    $pathGate = [ordered]@{
      safe = $true
      reason = "selftest_bounded_tmp_fixture"
      relative_path = [string]$case.relative_path
    }
    $matrix = New-CutoverEvidenceAcceptanceMatrix -ArtifactRead $artifactRead -PathGate $pathGate -SimulationRequested $false -CurrentCommit $CurrentCommit -RuntimeCommitMarker $RuntimeCommitMarker
    $observedRefusals = @($matrix.observed_refusals | ForEach-Object { [string]$_ })
    $observedFailures = @($matrix.observed_failures | ForEach-Object { [string]$_ })
    $expectedRefusal = if (Test-EvidenceField -Object $case -Field "expected_observed_refusal") { [string]$case.expected_observed_refusal } else { "" }
    $expectedFailure = if (Test-EvidenceField -Object $case -Field "expected_observed_failure") { [string]$case.expected_observed_failure } else { "" }
    $expectedCodeObserved = $true
    if (-not [string]::IsNullOrWhiteSpace($expectedRefusal) -and $expectedRefusal -notin $observedRefusals) {
      $expectedCodeObserved = $false
    }
    if (-not [string]::IsNullOrWhiteSpace($expectedFailure) -and $expectedFailure -notin $observedFailures) {
      $expectedCodeObserved = $false
    }
    $finalFalseObserved = -not [bool]$matrix.final_x_eligible
    if (-not $expectedCodeObserved -or -not $finalFalseObserved) {
      [void]$failures.Add([string]$case.name)
    }
    $caseResults += [ordered]@{
      name = [string]$case.name
      artifact_path = [string]$case.relative_path
      expected_observed_refusal = $expectedRefusal
      expected_observed_failure = $expectedFailure
      expected_final_blocking_reason = [string]$case.expected_final_blocking_reason
      observed_refusals = $observedRefusals
      observed_failures = $observedFailures
      final_x_eligible = [bool]$matrix.final_x_eligible
      actual_cutover_executed = [bool]$matrix.actual_cutover_executed
      classification = [string]$matrix.classification
      pass = ($expectedCodeObserved -and $finalFalseObserved)
    }
  }

  if ($failures.Count -gt 0) {
    throw ("canonical cutover artifact guard selftest failed: " + (($failures | Select-Object -Unique) -join ", "))
  }

  return [ordered]@{
    requested = $true
    performed = $true
    classification = "pass"
    db_io_performed = $false
    production_cutover_performed = $false
    canonical_production_artifact_required = ".tmp/billing-ledger/cutover-evidence-artifact.json"
    env_marker_can_mark_final_x = $false
    persistent_state_contract_can_bypass_canonical_artifact = $false
    cases = @($caseResults)
  }
}

function New-CutoverFinalClosureAudit {
  param(
    [Parameter(Mandatory = $true)]$RuntimeEvidenceTrustGate,
    [Parameter(Mandatory = $true)]$RuntimeWriterCommitRunnerArtifactHandoff,
    [Parameter(Mandatory = $true)]$LiveCommitProofReadbackBoundary,
    [Parameter(Mandatory = $true)]$SingleWriterCutoverProofGate,
    [Parameter(Mandatory = $true)]$CutoverEvidenceAcceptanceMatrix,
    [Parameter(Mandatory = $true)][bool]$AcceptedShapeSimulationRequested,
    [Parameter(Mandatory = $true)][string]$CurrentCommit
  )

  $blockingReasons = New-Object System.Collections.Generic.List[string]
  $commitProofPass = [string]$RuntimeWriterCommitRunnerArtifactHandoff.classification -eq "pass"
  $commitReadbackPass = [string]$LiveCommitProofReadbackBoundary.classification -eq "pass"
  $cutoverEvidenceAccepted = [bool]$CutoverEvidenceAcceptanceMatrix.cutover_evidence_accepted_for_review
  $actualCutoverExecuted = [bool]$CutoverEvidenceAcceptanceMatrix.actual_cutover_executed
  $finalCutoverEvidenceEligible = [bool]$CutoverEvidenceAcceptanceMatrix.final_x_eligible
  $postCutoverReadbackPass = [bool]$CutoverEvidenceAcceptanceMatrix.evidence.post_cutover_readback_passed
  $rollbackProofPass = [bool]$CutoverEvidenceAcceptanceMatrix.evidence.rollback_proof_present
  $noDualPass = [bool]$CutoverEvidenceAcceptanceMatrix.evidence.no_dual_passed
  $activeWriterAfter = [string]$CutoverEvidenceAcceptanceMatrix.evidence.active_writer_after
  $sourceOfTruthAfter = [string]$CutoverEvidenceAcceptanceMatrix.evidence.source_of_truth_after
  $secretSafe = -not [bool]$CutoverEvidenceAcceptanceMatrix.evidence.raw_secret_present

  if (-not $commitProofPass) {
    [void]$blockingReasons.Add("external_commit_proof_missing")
  }
  if (-not $commitReadbackPass) {
    [void]$blockingReasons.Add("commit_proof_readback_not_passed")
  }
  if (-not $cutoverEvidenceAccepted) {
    [void]$blockingReasons.Add("cutover_evidence_not_accepted")
  }
  if ([string]$CutoverEvidenceAcceptanceMatrix.artifact_source -eq "missing_artifact") {
    [void]$blockingReasons.Add("cutover_evidence_artifact_missing")
  }
  if ($AcceptedShapeSimulationRequested -or -not [bool]$CutoverEvidenceAcceptanceMatrix.simulation_can_mark_final_x) {
    if ($AcceptedShapeSimulationRequested) {
      [void]$blockingReasons.Add("accepted_shape_simulation_not_final")
    }
  }
  foreach ($refusal in @($CutoverEvidenceAcceptanceMatrix.observed_refusals)) {
    $code = [string]$refusal
    if ($code -eq "simulated_artifact") { [void]$blockingReasons.Add("accepted_shape_simulation_not_final") }
    if ($code -eq "template_artifact") { [void]$blockingReasons.Add("template_artifact_not_final") }
    if ($code -eq "unsafe_path") { [void]$blockingReasons.Add("unsafe_artifact_path") }
    if ($code -eq "stale_artifact") { [void]$blockingReasons.Add("stale_artifact") }
    if ($code -eq "runtime_mismatch") { [void]$blockingReasons.Add("runtime_mismatch") }
    if ($code -eq "source_of_truth_not_switched") { [void]$blockingReasons.Add("source_of_truth_not_switched") }
    if ($code -eq "post_cutover_readback_missing") { [void]$blockingReasons.Add("post_cutover_readback_missing") }
    if ($code -eq "rollback_proof_missing") { [void]$blockingReasons.Add("rollback_proof_missing") }
    if ($code -eq "local_dev_cutover_artifact_not_production_final") { [void]$blockingReasons.Add("local_dev_cutover_artifact_not_production_final") }
    if ($code -eq "non_production_cutover_artifact_not_production_final") { [void]$blockingReasons.Add("non_production_cutover_artifact_not_production_final") }
    if ($code -eq "production_cutover_artifact_path_not_canonical") { [void]$blockingReasons.Add("production_cutover_artifact_path_not_canonical") }
  }
  foreach ($failure in @($CutoverEvidenceAcceptanceMatrix.observed_failures)) {
    $code = [string]$failure
    if ($code -eq "row_count_mismatch") { [void]$blockingReasons.Add("row_count_mismatch") }
    if ($code -eq "no_dual_failure") { [void]$blockingReasons.Add("no_dual_proof_failed") }
    if ($code -eq "active_writer_mismatch") { [void]$blockingReasons.Add("active_writer_mismatch") }
    if ($code -eq "raw_secret_present") { [void]$blockingReasons.Add("raw_secret_present") }
  }
  if (-not $actualCutoverExecuted) {
    [void]$blockingReasons.Add("actual_cutover_not_executed")
  }
  if (-not $postCutoverReadbackPass) {
    [void]$blockingReasons.Add("post_cutover_readback_missing")
  }
  if (-not $rollbackProofPass) {
    [void]$blockingReasons.Add("rollback_proof_missing")
  }
  if (-not $noDualPass) {
    [void]$blockingReasons.Add("no_dual_proof_failed")
  }
  if ($activeWriterAfter -ne "billing_ledger_runtime_writer") {
    [void]$blockingReasons.Add("active_writer_mismatch")
  }
  if ($sourceOfTruthAfter -ne "billing_ledger_runtime_writer") {
    [void]$blockingReasons.Add("source_of_truth_not_switched")
  }
  if (-not $secretSafe) {
    [void]$blockingReasons.Add("raw_secret_present")
  }

  $blockingReasonsUnique = @($blockingReasons | Select-Object -Unique)
  $finalXEligible = $commitProofPass -and $commitReadbackPass -and $finalCutoverEvidenceEligible -and $actualCutoverExecuted -and $postCutoverReadbackPass -and $rollbackProofPass -and $noDualPass -and ($activeWriterAfter -eq "billing_ledger_runtime_writer") -and ($sourceOfTruthAfter -eq "billing_ledger_runtime_writer") -and $secretSafe -and (-not $AcceptedShapeSimulationRequested) -and ($blockingReasonsUnique.Count -eq 0)

  $requiredEvidence = @(
    [ordered]@{
      key = "external_runtime_writer_commit_proof"
      state = if ($commitProofPass -and $commitReadbackPass) { "pass" } else { "blocker" }
      source_gate = [string]$RuntimeWriterCommitRunnerArtifactHandoff.schema_version
      observed = [ordered]@{
        handoff = [string]$RuntimeWriterCommitRunnerArtifactHandoff.classification
        readback = [string]$LiveCommitProofReadbackBoundary.classification
      }
    },
    [ordered]@{
      key = "cutover_evidence_acceptance"
      state = if ($cutoverEvidenceAccepted) { "pass" } else { "blocker" }
      source_gate = [string]$CutoverEvidenceAcceptanceMatrix.schema_version
      observed = [string]$CutoverEvidenceAcceptanceMatrix.classification
    },
    [ordered]@{
      key = "actual_source_of_truth_cutover"
      state = if ($actualCutoverExecuted) { "pass" } else { "blocker" }
      observed = $actualCutoverExecuted
    },
    [ordered]@{
      key = "post_cutover_readback"
      state = if ($postCutoverReadbackPass) { "pass" } else { "blocker" }
      observed = $postCutoverReadbackPass
    },
    [ordered]@{
      key = "rollback_proof"
      state = if ($rollbackProofPass) { "pass" } else { "blocker" }
      observed = $rollbackProofPass
    },
    [ordered]@{
      key = "active_writer_source_of_truth_no_dual"
      state = if ($noDualPass -and $activeWriterAfter -eq "billing_ledger_runtime_writer" -and $sourceOfTruthAfter -eq "billing_ledger_runtime_writer") { "pass" } else { "blocker" }
      observed = [ordered]@{
        active_writer_after = $activeWriterAfter
        source_of_truth_after = $sourceOfTruthAfter
        no_dual_passed = $noDualPass
      }
    },
    [ordered]@{
      key = "secret_safe_omission"
      state = if ($secretSafe) { "pass" } else { "fail" }
      observed = if ($secretSafe) { "omitted" } else { "raw_secret_present" }
    }
  )

  return [ordered]@{
    schema_version = [string]$cutoverFinalClosureAuditContract.schema_version
    generated_at_utc = [DateTimeOffset]::UtcNow.ToString("o")
    current_commit = $CurrentCommit
    final_x_eligible = $finalXEligible
    classification = if ($finalXEligible) { "final_x_eligible" } else { "blocked" }
    accepted_for_review_can_mark_final_x = $false
    simulation_can_mark_final_x = $false
    template_can_mark_final_x = $false
    cutover_ready_can_mark_final_x = $false
    watcher_can_mark_final_x = $false
    blocking_reasons = $blockingReasonsUnique
    required_evidence = $requiredEvidence
    cutover_evidence_acceptance_state = [ordered]@{
      classification = [string]$CutoverEvidenceAcceptanceMatrix.classification
      accepted_for_review = $cutoverEvidenceAccepted
      final_x_eligible = $finalCutoverEvidenceEligible
      simulation_can_mark_final_x = [bool]$CutoverEvidenceAcceptanceMatrix.simulation_can_mark_final_x
    }
    commit_proof_state = [ordered]@{
      runtime_writer_commit_runner_artifact_handoff = [string]$RuntimeWriterCommitRunnerArtifactHandoff.classification
      live_commit_proof_readback = [string]$LiveCommitProofReadbackBoundary.classification
      current_runtime = [string]$RuntimeEvidenceTrustGate.classification
    }
    actual_cutover_state = [ordered]@{
      executed = $actualCutoverExecuted
      source_of_truth_after = $sourceOfTruthAfter
      active_writer_after = $activeWriterAfter
    }
    post_cutover_readback_state = [ordered]@{
      passed = $postCutoverReadbackPass
      source = "cutover_evidence_acceptance_matrix.evidence.post_cutover_readback_passed"
    }
    rollback_proof_state = [ordered]@{
      passed = $rollbackProofPass
      source = "cutover_evidence_acceptance_matrix.evidence.rollback_proof_present"
    }
    active_writer_source_of_truth_no_dual_summary = [ordered]@{
      active_writer_after = $activeWriterAfter
      source_of_truth_after = $sourceOfTruthAfter
      no_dual_passed = $noDualPass
      single_writer_gate_classification = [string]$SingleWriterCutoverProofGate.classification
      no_dual_gate_classification = [string]$SingleWriterCutoverProofGate.no_dual_commit_proof.classification
    }
    next_commands = @($cutoverFinalClosureAuditContract.next_commands)
    default_side_effects = [ordered]@{
      artifact_read = $false
      db_write = $false
      commit = $false
      cutover = $false
    }
    secret_safe_omission = [ordered]@{
      database_url_output = "omitted"
      env_value_output = "omitted"
      operation_key_output = "omitted"
      raw_path_output = "omitted"
      raw_env_value_echoed = $false
      raw_database_url_echoed = $false
      raw_metadata_echoed = $false
      credential_material_echoed = $false
      raw_executor_error_detail_echoed = $false
    }
  }
}

function New-CutoverEvidenceWatcherChecklist {
  param(
    [Parameter(Mandatory = $true)]$CutoverFinalClosureAudit,
    [Parameter(Mandatory = $true)]$LiveCommitProofArtifactRead,
    [Parameter(Mandatory = $true)]$LiveCommitProofArtifactPathGate,
    [Parameter(Mandatory = $true)]$CutoverEvidenceArtifactRead,
    [Parameter(Mandatory = $true)]$CutoverEvidenceArtifactPathGate,
    [Parameter(Mandatory = $true)]$CutoverEvidenceAcceptanceMatrix
  )

  $watcherBlockers = New-Object System.Collections.Generic.List[string]
  if (-not [bool]$LiveCommitProofArtifactRead.performed) {
    [void]$watcherBlockers.Add("live_commit_proof_artifact_missing_or_unread")
  }
  if (-not [bool]$CutoverEvidenceArtifactRead.performed -and [string]$CutoverEvidenceAcceptanceMatrix.artifact_source -ne "accepted_shape_simulation") {
    [void]$watcherBlockers.Add("cutover_evidence_artifact_missing_or_unread")
  }
  if (-not [bool]$LiveCommitProofArtifactPathGate.safe -or -not [bool]$CutoverEvidenceArtifactPathGate.safe) {
    [void]$watcherBlockers.Add("unsafe_artifact_path")
  }
  if (-not [bool]$CutoverFinalClosureAudit.final_x_eligible) {
    foreach ($reason in @($CutoverFinalClosureAudit.blocking_reasons)) {
      [void]$watcherBlockers.Add([string]$reason)
    }
  }

  $currentStatus = if ([bool]$CutoverFinalClosureAudit.final_x_eligible) { "final_review_ready" } else { "blocked_waiting_for_operator_evidence" }
  $nextCommand = if (-not [bool]$LiveCommitProofArtifactRead.performed) {
    ($cutoverEvidenceWatcherChecklistContract.exact_commands | Where-Object { [string]$_.step -eq "read_commit_proof" } | Select-Object -First 1).command
  } elseif (-not [bool]$CutoverEvidenceArtifactRead.performed -and [string]$CutoverEvidenceAcceptanceMatrix.artifact_source -ne "accepted_shape_simulation") {
    ($cutoverEvidenceWatcherChecklistContract.exact_commands | Where-Object { [string]$_.step -eq "read_cutover_artifact" } | Select-Object -First 1).command
  } else {
    ($cutoverEvidenceWatcherChecklistContract.exact_commands | Where-Object { [string]$_.step -eq "final_audit_review" } | Select-Object -First 1).command
  }

  return [ordered]@{
    schema_version = [string]$cutoverEvidenceWatcherChecklistContract.schema_version
    generated_at_utc = [DateTimeOffset]::UtcNow.ToString("o")
    current_status = $currentStatus
    final_x_eligible = [bool]$CutoverFinalClosureAudit.final_x_eligible
    watcher_can_mark_final_x = $false
    accepted_for_review_can_mark_final_x = $false
    simulation_can_mark_final_x = $false
    template_can_mark_final_x = $false
    cutover_ready_can_mark_final_x = $false
    blocking_reasons = @($watcherBlockers | Select-Object -Unique)
    expected_artifact_paths = [ordered]@{
      live_commit_proof = [string]$cutoverEvidenceWatcherChecklistContract.expected_artifact_paths.live_commit_proof
      cutover_evidence = [string]$cutoverEvidenceWatcherChecklistContract.expected_artifact_paths.cutover_evidence
      rollback_probe = [string]$cutoverEvidenceWatcherChecklistContract.expected_artifact_paths.rollback_probe
    }
    observed_artifact_state = [ordered]@{
      live_commit_proof = [ordered]@{
        read_requested = [bool]$LiveCommitProofArtifactRead.requested
        read_performed = [bool]$LiveCommitProofArtifactRead.performed
        path_safe = [bool]$LiveCommitProofArtifactPathGate.safe
        relative_path = [string]$LiveCommitProofArtifactPathGate.relative_path
      }
      cutover_evidence = [ordered]@{
        read_requested = [bool]$CutoverEvidenceArtifactRead.requested
        read_performed = [bool]$CutoverEvidenceArtifactRead.performed
        artifact_source = [string]$CutoverEvidenceAcceptanceMatrix.artifact_source
        path_safe = [bool]$CutoverEvidenceArtifactPathGate.safe
        relative_path = [string]$CutoverEvidenceArtifactPathGate.relative_path
        accepted_shape_simulation = ([string]$CutoverEvidenceAcceptanceMatrix.artifact_source -eq "accepted_shape_simulation")
      }
    }
    required_operator_actions = @($cutoverEvidenceWatcherChecklistContract.required_operator_actions | ForEach-Object { [string]$_ })
    exact_commands = @($cutoverEvidenceWatcherChecklistContract.exact_commands)
    next_command = [string]$nextCommand
    final_review_checklist = @(
      @($cutoverEvidenceWatcherChecklistContract.final_review_checklist) | ForEach-Object {
        $key = [string]$_.key
        [ordered]@{
          key = $key
          required = [bool]$_.required
          state = if ($key -eq "external_commit_proof") {
            if ([string]$CutoverFinalClosureAudit.commit_proof_state.runtime_writer_commit_runner_artifact_handoff -eq "pass" -and [string]$CutoverFinalClosureAudit.commit_proof_state.live_commit_proof_readback -eq "pass") { "pass" } else { "blocker" }
          } elseif ($key -eq "cutover_evidence_artifact") {
            if ([bool]$CutoverFinalClosureAudit.cutover_evidence_acceptance_state.accepted_for_review) { "pass" } else { "blocker" }
          } elseif ($key -eq "actual_cutover_executed") {
            if ([bool]$CutoverFinalClosureAudit.actual_cutover_state.executed) { "pass" } else { "blocker" }
          } elseif ($key -eq "post_cutover_readback") {
            if ([bool]$CutoverFinalClosureAudit.post_cutover_readback_state.passed) { "pass" } else { "blocker" }
          } elseif ($key -eq "rollback_proof") {
            if ([bool]$CutoverFinalClosureAudit.rollback_proof_state.passed) { "pass" } else { "blocker" }
          } elseif ($key -eq "no_template_or_simulation") {
            if ([bool]$CutoverFinalClosureAudit.cutover_evidence_acceptance_state.simulation_can_mark_final_x) { "fail" } else { "pass" }
          } elseif ($key -eq "secret_safe_omission") {
            if ("raw_secret_present" -in @($CutoverFinalClosureAudit.blocking_reasons | ForEach-Object { [string]$_ })) { "fail" } else { "pass" }
          } else {
            "blocker"
          }
        }
      }
    )
    safe_defaults = [ordered]@{
      poll = $false
      artifact_read = $false
      db_write = $false
      commit = $false
      cutover = $false
      explicit_readback_required = $true
    }
    closure_rule = [string]$cutoverEvidenceWatcherChecklistContract.closure_rule
    safe_output = [ordered]@{
      database_url_output = "omitted"
      env_value_output = "omitted"
      operation_key_output = "omitted"
      raw_path_output = "omitted"
      raw_env_value_echoed = $false
      raw_database_url_echoed = $false
      raw_metadata_echoed = $false
      credential_material_echoed = $false
      raw_executor_error_detail_echoed = $false
    }
  }
}

function New-ShadowCommitHandoff {
  param(
    [Parameter(Mandatory = $true)][bool]$Requested,
    [Parameter(Mandatory = $true)]$LiveAttempt,
    [Parameter(Mandatory = $true)]$RollbackGate,
    [Parameter(Mandatory = $true)][string]$Mode
  )

  $blockers = New-Object System.Collections.Generic.List[string]
  $failures = New-Object System.Collections.Generic.List[string]
  if (-not $Requested) {
    [void]$blockers.Add("shadow_commit_handoff_not_requested")
  }
  if ([string]$Mode -ne "ready") {
    [void]$blockers.Add("cutover_mode_not_ready")
  }
  if ([string]$LiveAttempt.classification -ne "pass") {
    [void]$blockers.Add("live_rollback_attempt_not_passed")
  }
  if ([string]$RollbackGate.classification -eq "fail") {
    foreach ($failure in @($RollbackGate.failures)) {
      [void]$failures.Add([string]$failure)
    }
  } elseif ([string]$RollbackGate.classification -ne "pass") {
    [void]$blockers.Add("rollback_only_executor_gate_not_passed")
  }

  $proof = $RollbackGate.rollback_no_commit_proof
  if ($null -eq $proof -or $proof.rollback_observed -ne $true) {
    [void]$blockers.Add("rollback_fallback_not_proven")
  }
  if ($null -ne $proof -and $proof.commit_observed -eq $true) {
    [void]$failures.Add("commit_observed_before_shadow_handoff")
  }
  if ($null -ne $proof -and $proof.dual_commit_observed -eq $true) {
    [void]$failures.Add("dual_commit_observed")
  }

  $classification = "blocker"
  if ($failures.Count -gt 0) {
    $classification = "fail"
  } elseif ($Requested -and $blockers.Count -eq 0) {
    $classification = "pass"
  }

  return [ordered]@{
    schema_version = [string]$shadowCommitHandoffContract.schema_version
    requested = $Requested
    classification = $classification
    handoff_mode = "shadow_commit_handoff_contract_only"
    commit_handoff = [ordered]@{
      attempted = $Requested
      real_commit_performed = $false
      billing_ledger_writer_commit_allowed = $false
      source_of_truth_switch_performed = $false
      source_of_truth_switch_allowed = $false
      output = "handoff_summary_only_without_writer_cutover"
    }
    no_double_write = [ordered]@{
      local_sql_writer_remains_authoritative = $true
      local_sql_writer_commit_allowed = $true
      billing_ledger_shadow_commit_allowed = $false
      dual_commit_allowed = $false
      dual_commit_observed = if ($null -eq $proof) { $false } else { [bool]$proof.dual_commit_observed }
    }
    rollback_fallback = [ordered]@{
      required = $true
      proven = if ($null -eq $proof) { $false } else { [bool]$proof.rollback_observed }
      local_writer_fallback = "control_plane_local_sql_writer"
      rollback_required_on_row_count_mismatch = $true
      rollback_required_on_adapter_refusal = $true
      fallback_after_billing_commit_allowed = $false
    }
    row_count_summary = $RollbackGate.row_count_evidence
    transaction_timing_summary = $RollbackGate.timing_evidence
    production_cutover = [ordered]@{
      remains_blocked = $true
      blocker = "source_of_truth_switch_not_requested"
      source_of_truth = "control_plane_local_sql_writer"
    }
    blockers = @($blockers | Select-Object -Unique)
    failures = @($failures | Select-Object -Unique)
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

function Test-CommitMarkerMatches {
  param(
    [Parameter(Mandatory = $true)][string]$CurrentCommit,
    [AllowNull()][string]$RuntimeCommit
  )

  if ([string]::IsNullOrWhiteSpace($RuntimeCommit)) {
    return $false
  }

  $current = $CurrentCommit.Trim().ToLowerInvariant()
  $runtime = $RuntimeCommit.Trim().ToLowerInvariant()
  return $runtime -eq $current -or $runtime.StartsWith($current) -or $current.StartsWith($runtime)
}

function Test-WriterMarkerMatches {
  param(
    [AllowNull()][string]$Value,
    [Parameter(Mandatory = $true)][string]$Expected
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $false
  }

  return $Value.Trim().ToLowerInvariant() -eq $Expected.Trim().ToLowerInvariant()
}

function New-RuntimeEvidenceTrustGate {
  param(
    [Parameter(Mandatory = $true)]$RollbackGate,
    [Parameter(Mandatory = $true)][string]$CurrentCommit,
    [AllowNull()][string]$RuntimeCommitMarker
  )

  $runtimeMarkerPresent = -not [string]::IsNullOrWhiteSpace($RuntimeCommitMarker)
  $runtimeMarkerMatches = Test-CommitMarkerMatches -CurrentCommit $CurrentCommit -RuntimeCommit $RuntimeCommitMarker
  $rollbackProbePassed = [string]$RollbackGate.classification -eq "pass"
  $classification = "source_level_pass"
  $blockers = New-Object System.Collections.Generic.List[string]
  if ($runtimeMarkerPresent -and -not $runtimeMarkerMatches) {
    $classification = "container_runtime_stale"
    [void]$blockers.Add("container_runtime_commit_stale")
  } elseif ($runtimeMarkerPresent -and $runtimeMarkerMatches -and $rollbackProbePassed) {
    $classification = "container_runtime_current"
  } elseif ($rollbackProbePassed) {
    $classification = "rollback_only_live_probe_only"
    [void]$blockers.Add("container_runtime_commit_marker_missing")
  } else {
    [void]$blockers.Add("rollback_only_live_probe_not_passed")
  }

  return [ordered]@{
    schema_version = [string]$runtimeEvidenceTrustGateContract.schema_version
    classification = $classification
    docker_build_performed = $false
    source_level_evidence = [ordered]@{
      current_commit = $CurrentCommit
      classification = "source_level_pass"
      source_commit_output = "short_commit_marker"
    }
    container_runtime_evidence = [ordered]@{
      env_var = $runtimeContainerCommitEnvVar
      present = $runtimeMarkerPresent
      matches_current_source = $runtimeMarkerMatches
      output = if ($runtimeMarkerPresent) { "presence_and_match_only" } else { "missing" }
      raw_env_value_echoed = $false
    }
    rollback_only_live_probe_evidence = [ordered]@{
      classification = if ($rollbackProbePassed) { "rollback_only_live_probe_only" } else { "blocker" }
      measurement_source = if ($null -eq $RollbackGate.timing_evidence) { "unavailable" } else { [string]$RollbackGate.timing_evidence.measurement_source }
      can_substitute_production_cutover = $false
      row_count_summary_available = ($null -ne $RollbackGate.row_count_evidence)
      timing_summary_available = ($null -ne $RollbackGate.timing_evidence)
    }
    blockers = @($blockers | Select-Object -Unique)
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

function New-SingleWriterCutoverProofGate {
  param(
    [Parameter(Mandatory = $true)][bool]$ProofRequested,
    [Parameter(Mandatory = $true)][bool]$LiveCommitProofAvailable,
    [AllowNull()][string]$LiveCommitReadback,
    [AllowNull()][string]$ActiveWriter,
    [AllowNull()][string]$SourceOfTruth,
    [Parameter(Mandatory = $true)][bool]$LocalWriterDisabled,
    [Parameter(Mandatory = $true)]$RuntimeEvidenceTrustGate,
    [Parameter(Mandatory = $true)]$RollbackGate,
    [Parameter(Mandatory = $true)]$LiveCommitProofReadbackBoundary,
    [Parameter(Mandatory = $true)]$RuntimeWriterCommitRunnerArtifactHandoff
  )

  $blockers = New-Object System.Collections.Generic.List[string]
  $failures = New-Object System.Collections.Generic.List[string]
  if (-not $ProofRequested) {
    [void]$blockers.Add("single_writer_proof_missing")
  }

  $expectedActiveWriter = [string]$singleWriterCutoverProofGateContract.expected_active_writer
  $activeWriterPresent = -not [string]::IsNullOrWhiteSpace($ActiveWriter)
  $activeWriterMatches = Test-WriterMarkerMatches -Value $ActiveWriter -Expected $expectedActiveWriter
  $liveCommitReadbackPresent = -not [string]::IsNullOrWhiteSpace($LiveCommitReadback)
  $liveCommitReadbackMatches = Test-WriterMarkerMatches -Value $LiveCommitReadback -Expected $expectedActiveWriter
  $sourceOfTruthPresent = -not [string]::IsNullOrWhiteSpace($SourceOfTruth)
  $sourceOfTruthMatches = Test-WriterMarkerMatches -Value $SourceOfTruth -Expected $expectedActiveWriter
  $activeWriterMatchesSourceOfTruth = $activeWriterPresent -and $sourceOfTruthPresent -and ([string]$ActiveWriter).Trim().ToLowerInvariant() -eq ([string]$SourceOfTruth).Trim().ToLowerInvariant()
  if (-not $LiveCommitProofAvailable) {
    [void]$blockers.Add("live_commit_proof_missing")
  }
  if ([string]$LiveCommitProofReadbackBoundary.classification -eq "fail") {
    foreach ($failure in @($LiveCommitProofReadbackBoundary.failures)) {
      [void]$failures.Add([string]$failure)
    }
  } elseif ([string]$LiveCommitProofReadbackBoundary.classification -ne "pass") {
    [void]$blockers.Add("live_commit_proof_artifact_not_passed")
    foreach ($blocker in @($LiveCommitProofReadbackBoundary.blockers)) {
      [void]$blockers.Add([string]$blocker)
    }
  }
  if ([string]$RuntimeWriterCommitRunnerArtifactHandoff.classification -eq "fail") {
    foreach ($failure in @($RuntimeWriterCommitRunnerArtifactHandoff.failures)) {
      [void]$failures.Add([string]$failure)
    }
  } elseif ([string]$RuntimeWriterCommitRunnerArtifactHandoff.classification -ne "pass") {
    [void]$blockers.Add("runtime_writer_commit_runner_artifact_handoff_not_passed")
    foreach ($blocker in @($RuntimeWriterCommitRunnerArtifactHandoff.blockers)) {
      [void]$blockers.Add([string]$blocker)
    }
  }
  if (-not $liveCommitReadbackPresent) {
    [void]$blockers.Add("live_commit_readback_missing")
  } elseif (-not $liveCommitReadbackMatches) {
    [void]$failures.Add("live_commit_readback_mismatch")
  }
  if (-not $activeWriterPresent) {
    [void]$blockers.Add("active_writer_marker_missing")
  } elseif (-not $activeWriterMatches) {
    [void]$failures.Add("active_writer_marker_not_billing_ledger_runtime_writer")
  }
  if (-not $sourceOfTruthPresent) {
    [void]$blockers.Add("source_of_truth_readback_missing")
  } elseif (-not $sourceOfTruthMatches) {
    [void]$failures.Add("source_of_truth_not_billing_ledger_runtime_writer")
  }
  if ($activeWriterPresent -and $sourceOfTruthPresent -and -not $activeWriterMatchesSourceOfTruth) {
    [void]$failures.Add("active_writer_source_of_truth_mismatch")
  }
  if (-not $LocalWriterDisabled) {
    [void]$blockers.Add("local_writer_disable_marker_missing")
  }
  if ([string]$RuntimeEvidenceTrustGate.classification -ne "container_runtime_current") {
    [void]$blockers.Add("runtime_evidence_not_container_current")
  }

  $proof = $RollbackGate.rollback_no_commit_proof
  $rollbackProofFreshness = $RollbackGate.rollback_proof_freshness
  $proofSource = if ($null -eq $proof) { "" } else { [string]$proof.proof_source }
  $timingSource = if ($null -eq $RollbackGate.timing_evidence) { "" } else { [string]$RollbackGate.timing_evidence.measurement_source }
  $simulatedProof = $proofSource -eq "contract_simulated_no_db_io" -or $timingSource -eq "contract_simulated_no_db_io"
  if ($null -eq $proof -or $proof.rollback_observed -ne $true) {
    [void]$blockers.Add("rollback_proof_missing")
  }
  if ($null -eq $rollbackProofFreshness -or [string]$rollbackProofFreshness.classification -ne "pass") {
    [void]$blockers.Add("rollback_proof_not_fresh")
  }
  if ($simulatedProof) {
    [void]$blockers.Add("rollback_proof_simulated")
  }
  $commitObserved = if ($null -eq $proof) { $false } else { [bool]$proof.commit_observed }
  $dualCommitObserved = if ($null -eq $proof) { $false } else { [bool]$proof.dual_commit_observed }
  $productionWriterReplaced = if ($null -eq $proof) { $false } else { [bool]$proof.production_writer_replaced }
  $noDualCommitClassification = "blocker"
  if ($null -ne $proof -and ($proof.commit_observed -eq $true -or $proof.dual_commit_observed -eq $true)) {
    [void]$failures.Add("dual_commit_or_commit_observed")
  }
  if ($commitObserved -or $dualCommitObserved -or $productionWriterReplaced) {
    $noDualCommitClassification = "fail"
  } elseif ($null -ne $proof -and $proof.rollback_observed -eq $true) {
    $noDualCommitClassification = "pass"
  }
  if ([string]$RollbackGate.classification -eq "fail") {
    foreach ($failure in @($RollbackGate.failures)) {
      [void]$failures.Add([string]$failure)
    }
  }

  $classification = "blocker"
  if ($failures.Count -gt 0) {
    $classification = "fail"
  } elseif ($blockers.Count -eq 0) {
    $classification = "pass"
  }

  return [ordered]@{
    schema_version = [string]$singleWriterCutoverProofGateContract.schema_version
    requested = $ProofRequested
    classification = $classification
    expected_active_writer = $expectedActiveWriter
    live_commit_proof_readback = [ordered]@{
      requested = $LiveCommitProofAvailable
      classification = if (-not $LiveCommitProofAvailable -or -not $liveCommitReadbackPresent) { "blocker" } elseif ($liveCommitReadbackMatches) { "pass" } else { "fail" }
      marker_env_var = $liveCommitReadbackEnvVar
      present = $liveCommitReadbackPresent
      matches_expected_writer = $liveCommitReadbackMatches
      expected_writer = $expectedActiveWriter
      commit_performed_by_this_script = $false
      cutover_performed_by_this_script = $false
      output = "presence_and_match_only"
      raw_env_value_echoed = $false
    }
    live_commit_proof_artifact_readback = $LiveCommitProofReadbackBoundary
    runtime_writer_commit_runner_artifact_handoff = $RuntimeWriterCommitRunnerArtifactHandoff
    active_writer = [ordered]@{
      marker_env_var = $activeWriterEnvVar
      present = $activeWriterPresent
      matches_expected = $activeWriterMatches
      output = "presence_and_match_only"
      raw_env_value_echoed = $false
    }
    source_of_truth_consistency = [ordered]@{
      source_of_truth_env_var = $sourceOfTruthEnvVar
      present = $sourceOfTruthPresent
      matches_expected_writer = $sourceOfTruthMatches
      active_writer_matches_source_of_truth = $activeWriterMatchesSourceOfTruth
      runtime_evidence_classification = [string]$RuntimeEvidenceTrustGate.classification
      container_runtime_current = ([string]$RuntimeEvidenceTrustGate.classification -eq "container_runtime_current")
      current_execution_source_of_truth = "control_plane_local_sql_writer"
      source_of_truth_switch_performed_by_this_script = $false
      consistent = ($sourceOfTruthMatches -and $activeWriterMatches -and $activeWriterMatchesSourceOfTruth -and [string]$RuntimeEvidenceTrustGate.classification -eq "container_runtime_current")
      output = "presence_and_match_only"
      raw_env_value_echoed = $false
    }
    local_writer = [ordered]@{
      disable_marker_env_var = $localWriterDisabledEnvVar
      disabled_for_cutover = $LocalWriterDisabled
      output = "boolean_only"
      raw_env_value_echoed = $false
    }
    no_double_write = [ordered]@{
      dual_commit_allowed = $false
      local_and_billing_ledger_commit_same_request_allowed = $false
      dual_commit_observed = $dualCommitObserved
      commit_observed_before_cutover = $commitObserved
    }
    no_dual_commit_proof = [ordered]@{
      classification = $noDualCommitClassification
      commit_observed = $commitObserved
      dual_commit_observed = $dualCommitObserved
      production_writer_replaced = $productionWriterReplaced
      dual_commit_allowed = $false
    }
    rollback_proof = [ordered]@{
      rollback_observed = if ($null -eq $proof) { $false } else { [bool]$proof.rollback_observed }
      local_writer_fallback = "control_plane_local_sql_writer"
      fallback_after_billing_commit_allowed = $false
    }
    rollback_proof_freshness = $rollbackProofFreshness
    simulated_evidence = [ordered]@{
      rejected = $simulatedProof
      proof_source = if ([string]::IsNullOrWhiteSpace($proofSource)) { "missing" } else { $proofSource }
      timing_source = if ([string]::IsNullOrWhiteSpace($timingSource)) { "missing" } else { $timingSource }
      classification = if ($simulatedProof) { "blocker" } else { "not_simulated" }
    }
    runtime_evidence_classification = [string]$RuntimeEvidenceTrustGate.classification
    proof_scope = [string]$singleWriterCutoverProofGateContract.proof_scope
    can_substitute_production_cutover = $false
    blockers = @($blockers | Select-Object -Unique)
    failures = @($failures | Select-Object -Unique)
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

function New-ProductionCutoverAcceptanceGate {
  param(
    [Parameter(Mandatory = $true)][bool]$Accepted,
    [Parameter(Mandatory = $true)][bool]$LiveCommitProofAvailable,
    [Parameter(Mandatory = $true)][bool]$RollbackPlanAcknowledged,
    [Parameter(Mandatory = $true)]$ShadowHandoff,
    [Parameter(Mandatory = $true)]$RollbackGate,
    [Parameter(Mandatory = $true)]$RuntimeEvidenceTrustGate,
    [Parameter(Mandatory = $true)]$SingleWriterProofGate,
    [Parameter(Mandatory = $true)][string]$Mode
  )

  $blockers = New-Object System.Collections.Generic.List[string]
  $failures = New-Object System.Collections.Generic.List[string]
  if (-not $Accepted) {
    [void]$blockers.Add("production_cutover_acceptance_missing")
  }
  if ([string]$Mode -ne "ready") {
    [void]$blockers.Add("cutover_mode_not_ready")
  }
  if ([string]$ShadowHandoff.classification -ne "pass") {
    [void]$blockers.Add("shadow_commit_handoff_not_passed")
  }
  if (-not $LiveCommitProofAvailable) {
    [void]$blockers.Add("live_commit_proof_missing")
  }
  if (-not $RollbackPlanAcknowledged) {
    [void]$blockers.Add("rollback_plan_not_acknowledged")
  }
  if ([string]$RuntimeEvidenceTrustGate.classification -eq "container_runtime_stale") {
    [void]$blockers.Add("container_runtime_stale")
  } elseif ([string]$RuntimeEvidenceTrustGate.classification -ne "container_runtime_current") {
    [void]$blockers.Add("runtime_evidence_not_container_current")
  }
  if ([string]$SingleWriterProofGate.classification -eq "fail") {
    foreach ($failure in @($SingleWriterProofGate.failures)) {
      [void]$failures.Add([string]$failure)
    }
  } elseif ([string]$SingleWriterProofGate.classification -ne "pass") {
    [void]$blockers.Add("single_writer_proof_not_passed")
    foreach ($blocker in @($SingleWriterProofGate.blockers)) {
      [void]$blockers.Add([string]$blocker)
    }
  }
  $proof = $RollbackGate.rollback_no_commit_proof
  $rollbackProofFreshness = $SingleWriterProofGate.rollback_proof_freshness
  if ($null -eq $proof -or $proof.rollback_observed -ne $true) {
    [void]$blockers.Add("rollback_plan_not_proven")
  }
  if ($null -eq $rollbackProofFreshness -or [string]$rollbackProofFreshness.classification -ne "pass") {
    [void]$blockers.Add("rollback_proof_not_fresh")
  }
  if ($null -ne $proof -and ($proof.commit_observed -eq $true -or $proof.dual_commit_observed -eq $true)) {
    [void]$failures.Add("no_dual_commit_contract_failed")
  }
  if ([string]$RollbackGate.classification -eq "fail") {
    foreach ($failure in @($RollbackGate.failures)) {
      [void]$failures.Add([string]$failure)
    }
  }

  $classification = "blocker"
  if ($failures.Count -gt 0) {
    $classification = "fail"
  } elseif ($blockers.Count -eq 0) {
    $classification = "pass"
  }

  return [ordered]@{
    schema_version = [string]$productionCutoverAcceptanceGateContract.schema_version
    requested = $Accepted
    classification = $classification
    acceptance_marker = [ordered]@{
      explicit_flag = [string]$productionCutoverAcceptanceGateContract.explicit_flag
      explicit_env_var = [string]$productionCutoverAcceptanceGateContract.explicit_env_var
      accepted = $Accepted
      env_value_output = "omitted"
      raw_env_value_echoed = $false
    }
    commit_eligibility = [ordered]@{
      eligible = ($classification -eq "pass")
      live_commit_proof_available = $LiveCommitProofAvailable
      live_commit_readback_classification = [string]$SingleWriterProofGate.live_commit_proof_readback.classification
      shadow_commit_handoff_passed = ([string]$ShadowHandoff.classification -eq "pass")
      rollback_plan_acknowledged = $RollbackPlanAcknowledged
      runtime_evidence_classification = [string]$RuntimeEvidenceTrustGate.classification
      single_writer_proof_classification = [string]$SingleWriterProofGate.classification
      source_of_truth_consistent = [bool]$SingleWriterProofGate.source_of_truth_consistency.consistent
      rollback_proof_fresh = ($null -ne $rollbackProofFreshness -and [string]$rollbackProofFreshness.classification -eq "pass")
      no_dual_commit_proof_classification = [string]$SingleWriterProofGate.no_dual_commit_proof.classification
      source_of_truth_switch_performed = $false
      source_of_truth_switch_performed_by_this_script = $false
      source_of_truth_switch_execution = "separate_explicit_cutover_step_required"
    }
    live_commit_proof_readback = $SingleWriterProofGate.live_commit_proof_readback
    source_of_truth_consistency = $SingleWriterProofGate.source_of_truth_consistency
    rollback_plan = [ordered]@{
      acknowledged = $RollbackPlanAcknowledged
      local_writer_fallback = "control_plane_local_sql_writer"
      fallback_after_billing_commit_allowed = $false
      proof_freshness = $rollbackProofFreshness
      rollback_command = [ordered]@{
        script = [string]$productionCutoverAcceptanceGateContract.rollback_plan.rollback_command.script
        flags = @($productionCutoverAcceptanceGateContract.rollback_plan.rollback_command.flags | ForEach-Object { [string]$_ })
        env_value_output = "omitted"
        database_url_output = "presence_marker_only"
      }
    }
    no_double_write = [ordered]@{
      required = $true
      dual_commit_allowed = $false
      dual_commit_observed = if ($null -eq $proof) { $false } else { [bool]$proof.dual_commit_observed }
      local_and_billing_ledger_commit_same_request_allowed = $false
      no_dual_commit_proof_classification = [string]$SingleWriterProofGate.no_dual_commit_proof.classification
    }
    row_count_summary = $RollbackGate.row_count_evidence
    transaction_timing_summary = $RollbackGate.timing_evidence
    blockers = @($blockers | Select-Object -Unique)
    failures = @($failures | Select-Object -Unique)
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
$runtimeSchemaAvailable = [bool]$RuntimeSchemaAvailable -or (Test-TruthyEnv ([Environment]::GetEnvironmentVariable($runtimeSchemaEnvVar)))
$runtimeToolAvailable = [bool]$RuntimeToolAvailable -or (Test-TruthyEnv ([Environment]::GetEnvironmentVariable($runtimeToolEnvVar)))
$liveDbExecutorProbeRequested = [bool]$RunLiveDbExecutorProbe -or (Test-TruthyEnv ([Environment]::GetEnvironmentVariable($liveDbExecutorProbeEnvVar)))
$rollbackOnlyExecutorRequested = [bool]$ExecuteRollbackOnlyLiveProbe -or (Test-TruthyEnv ([Environment]::GetEnvironmentVariable($rollbackOnlyExecutorEnvVar)))
$realLiveAttemptRequested = [bool]$AttemptRealLiveDbProbe -or (Test-TruthyEnv ([Environment]::GetEnvironmentVariable($realLiveAttemptEnvVar)))
$shadowCommitHandoffRequested = [bool]$ShadowCommitHandoff -or (Test-TruthyEnv ([Environment]::GetEnvironmentVariable($shadowCommitHandoffEnvVar)))
$productionCutoverAccepted = [bool]$AcceptProductionCutover -or (Test-TruthyEnv ([Environment]::GetEnvironmentVariable($productionCutoverAcceptanceEnvVar)))
$liveCommitProofAvailable = [bool]$LiveCommitProof -or (Test-TruthyEnv ([Environment]::GetEnvironmentVariable($liveCommitProofEnvVar)))
$rollbackPlanAcknowledged = [bool]$AcknowledgeRollbackPlan -or (Test-TruthyEnv ([Environment]::GetEnvironmentVariable($rollbackPlanAcknowledgedEnvVar)))
$runtimeCommitMarkerValue = if ([string]::IsNullOrWhiteSpace($RuntimeContainerCommitMarker)) { [Environment]::GetEnvironmentVariable($runtimeContainerCommitEnvVar) } else { $RuntimeContainerCommitMarker }
$liveCommitReadbackMarkerValue = if ([string]::IsNullOrWhiteSpace($LiveCommitReadbackMarker)) { [Environment]::GetEnvironmentVariable($liveCommitReadbackEnvVar) } else { $LiveCommitReadbackMarker }
$singleWriterProofRequested = [bool]$SingleWriterCutoverProof -or (Test-TruthyEnv ([Environment]::GetEnvironmentVariable($singleWriterProofEnvVar)))
$activeWriterMarkerValue = if ([string]::IsNullOrWhiteSpace($ActiveWriterMarker)) { [Environment]::GetEnvironmentVariable($activeWriterEnvVar) } else { $ActiveWriterMarker }
$sourceOfTruthMarkerValue = if ([string]::IsNullOrWhiteSpace($SourceOfTruthMarker)) { [Environment]::GetEnvironmentVariable($sourceOfTruthEnvVar) } else { $SourceOfTruthMarker }
$localWriterDisabledForCutover = Test-TruthyEnv ([Environment]::GetEnvironmentVariable($localWriterDisabledEnvVar))
$artifactWriteRequested = [bool]$WriteProbeArtifact -or (Test-TruthyEnv ([Environment]::GetEnvironmentVariable($artifactWriteEnvVar)))
$artifactReadRequested = [bool]$ReadProbeArtifact -or (Test-TruthyEnv ([Environment]::GetEnvironmentVariable($artifactReadEnvVar)))
$artifactPathValue = if ([string]::IsNullOrWhiteSpace($ArtifactPath)) { [Environment]::GetEnvironmentVariable($artifactPathEnvVar) } else { $ArtifactPath }
$liveCommitProofArtifactWriteRequested = [bool]$WriteLiveCommitProofArtifact -or (Test-TruthyEnv ([Environment]::GetEnvironmentVariable($liveCommitProofArtifactWriteEnvVar)))
$liveCommitProofArtifactReadRequested = [bool]$ReadLiveCommitProofArtifact -or (Test-TruthyEnv ([Environment]::GetEnvironmentVariable($liveCommitProofArtifactReadEnvVar)))
$liveCommitProofArtifactPathValue = if ([string]::IsNullOrWhiteSpace($LiveCommitProofArtifactPath)) { [Environment]::GetEnvironmentVariable($liveCommitProofArtifactPathEnvVar) } else { $LiveCommitProofArtifactPath }
$cutoverEvidenceArtifactReadRequested = [bool]$ReadCutoverEvidenceArtifact -or (Test-TruthyEnv ([Environment]::GetEnvironmentVariable($cutoverEvidenceArtifactReadEnvVar)))
$cutoverEvidenceArtifactPathValue = if ([string]::IsNullOrWhiteSpace($CutoverEvidenceArtifactPath)) { [Environment]::GetEnvironmentVariable($cutoverEvidenceArtifactPathEnvVar) } else { $CutoverEvidenceArtifactPath }
$cutoverEvidenceAcceptedShapeSimulationRequested = [bool]$SimulateAcceptedCutoverEvidenceShape -or (Test-TruthyEnv ([Environment]::GetEnvironmentVariable($cutoverEvidenceAcceptedShapeSimulationEnvVar)))
$runtimeWriterCommitRunnerPlanRequested = [bool]$PlanRuntimeWriterCommitRunner -or (Test-TruthyEnv ([Environment]::GetEnvironmentVariable($runtimeWriterCommitRunnerPlanEnvVar)))
$runtimeWriterCommitRunnerRunRequested = [bool]$RunRuntimeWriterCommitRunner -or (Test-TruthyEnv ([Environment]::GetEnvironmentVariable($runtimeWriterCommitRunnerRunEnvVar)))
$runtimeWriterCommitRunnerAcceptanceSelfTestRequested = [bool]$SelfTestRuntimeWriterCommitRunnerArtifactAcceptance
$canonicalCutoverArtifactGuardSelfTestRequested = [bool]$SelfTestCanonicalCutoverArtifactGuard
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

$localToolReadiness = Get-LocalToolReadiness
$liveProbeEvidenceArtifact = New-LiveProbeEvidenceArtifact -Readiness $readiness -ProbeRequested ([bool]$LiveExecutionProbe) -MeasurementsAvailable ([bool]$SimulateProbeMeasurements) -RowCountMismatch ([bool]$SimulateProbeRowCountMismatch) -StaleArtifact ([bool]$SimulateStaleProbeArtifact) -CommitObserved ([bool]$SimulateCommitObserved) -ProductionWriterReplaced ([bool]$SimulateProductionWriterReplaced) -DualCommitObserved ([bool]$SimulateDualCommitObserved) -Blockers @($blockers)
$realProbeCanRun = $realLiveAttemptRequested -and $liveOptIn -and ([string]$mode.Mode -eq "ready") -and $liveDatabaseUrlPresent -and $featureAvailable -and $runtimeSchemaAvailable -and $runtimeToolAvailable -and [bool]$localToolReadiness.docker_daemon_available -and -not [bool]$SimulateProbeRowCountMismatch -and -not [bool]$SimulateCommitObserved -and -not [bool]$SimulateProductionWriterReplaced -and -not [bool]$SimulateDualCommitObserved -and -not [bool]$SimulateRawSqlOutput
$realProbeArtifact = Invoke-DockerPostgresRollbackProbeArtifact -Enabled $realProbeCanRun
if ($null -ne $realProbeArtifact) {
  $liveProbeEvidenceArtifact = $realProbeArtifact
}
$artifactPathGate = Resolve-SafeProbeArtifactPath -RequestedPath $artifactPathValue
$artifactWriteResult = Write-ProbeArtifactIfAllowed -Artifact $liveProbeEvidenceArtifact -PathGate $artifactPathGate -WriteRequested $artifactWriteRequested
$artifactReadResult = Read-ProbeArtifactIfAllowed -FallbackArtifact $liveProbeEvidenceArtifact -PathGate $artifactPathGate -ReadRequested $artifactReadRequested
$readbackArtifact = $artifactReadResult.artifact
$liveProbeMeasurementReadbackGate = New-LiveProbeMeasurementReadbackGate -Artifact $readbackArtifact -MissingRowCount ([bool]$SimulateMissingRowCountReadback) -MissingTiming ([bool]$SimulateMissingTimingReadback) -MissingRollbackProof ([bool]$SimulateMissingRollbackProofReadback)
$liveDbExecutorProbeCommandBoundary = New-LiveDbExecutorProbeCommandBoundary -ProbeRequested $liveDbExecutorProbeRequested -LiveOptIn $liveOptIn -Mode ([string]$mode.Mode) -LiveDatabaseUrlPresent $liveDatabaseUrlPresent -FeatureAvailable $featureAvailable -SchemaAvailable $runtimeSchemaAvailable -ToolAvailable $runtimeToolAvailable -ArtifactWrite $artifactWriteResult -ArtifactRead $artifactReadResult -ReadbackGate $liveProbeMeasurementReadbackGate
$liveDbExecutorSqlBridgeReadinessArtifact = New-LiveDbExecutorSqlBridgeReadinessArtifact -CommandBoundary $liveDbExecutorProbeCommandBoundary -ReadbackGate $liveProbeMeasurementReadbackGate -LiveDatabaseUrlPresent $liveDatabaseUrlPresent -SchemaAvailable $runtimeSchemaAvailable -ToolAvailable $runtimeToolAvailable
$liveDbRollbackOnlyExecutorGate = New-LiveDbRollbackOnlyExecutorGate -ExecutionRequested $rollbackOnlyExecutorRequested -SqlBridge $liveDbExecutorSqlBridgeReadinessArtifact -ReadbackGate $liveProbeMeasurementReadbackGate -ArtifactWrite $artifactWriteResult -ArtifactRead $artifactReadResult -RawSqlOutputObserved ([bool]$SimulateRawSqlOutput)
$realLiveDbRollbackAttempt = New-RealLiveDbRollbackAttempt -AttemptRequested $realLiveAttemptRequested -ToolReadiness $localToolReadiness -RollbackGate $liveDbRollbackOnlyExecutorGate -LiveDatabaseUrlPresent $liveDatabaseUrlPresent -SchemaAvailable $runtimeSchemaAvailable -RuntimeToolAvailable $runtimeToolAvailable
$shadowCommitHandoffSummary = New-ShadowCommitHandoff -Requested $shadowCommitHandoffRequested -LiveAttempt $realLiveDbRollbackAttempt -RollbackGate $liveDbRollbackOnlyExecutorGate -Mode ([string]$mode.Mode)
$runtimeEvidenceTrustGate = New-RuntimeEvidenceTrustGate -RollbackGate $liveDbRollbackOnlyExecutorGate -CurrentCommit (Get-CurrentCommitMarker) -RuntimeCommitMarker $runtimeCommitMarkerValue
$liveCommitProofTemplateArtifact = New-LiveCommitProofTemplateArtifact -CurrentCommit (Get-CurrentCommitMarker) -RuntimeCommitMarker $runtimeCommitMarkerValue -ActiveWriter $activeWriterMarkerValue -SourceOfTruth $sourceOfTruthMarkerValue
$liveCommitProofArtifactPathGate = Resolve-SafeProbeArtifactPath -RequestedPath $liveCommitProofArtifactPathValue -DefaultRelativePath ".tmp\billing-ledger\live-commit-proof-artifact.json"
$liveCommitProofArtifactWriteResult = Write-ProbeArtifactIfAllowed -Artifact $liveCommitProofTemplateArtifact -PathGate $liveCommitProofArtifactPathGate -WriteRequested $liveCommitProofArtifactWriteRequested
$liveCommitProofArtifactReadResult = Read-ProbeArtifactIfAllowed -FallbackArtifact $liveCommitProofTemplateArtifact -PathGate $liveCommitProofArtifactPathGate -ReadRequested $liveCommitProofArtifactReadRequested
$liveCommitProofReadbackBoundary = New-LiveCommitProofReadbackBoundary -Artifact $liveCommitProofArtifactReadResult.artifact -ArtifactWrite $liveCommitProofArtifactWriteResult -ArtifactRead $liveCommitProofArtifactReadResult -PathGate $liveCommitProofArtifactPathGate -CurrentCommit (Get-CurrentCommitMarker) -RuntimeCommitMarker $runtimeCommitMarkerValue -ActiveWriter $activeWriterMarkerValue -SourceOfTruth $sourceOfTruthMarkerValue -RollbackGate $liveDbRollbackOnlyExecutorGate
$runtimeWriterCommitRunnerCommandBoundary = New-RuntimeWriterCommitRunnerCommandBoundary -PlanRequested $runtimeWriterCommitRunnerPlanRequested -RunRequested $runtimeWriterCommitRunnerRunRequested -LiveOptIn $liveOptIn -Mode ([string]$mode.Mode) -LiveDatabaseUrlPresent $liveDatabaseUrlPresent -FeatureAvailable $featureAvailable -SchemaAvailable $runtimeSchemaAvailable -ToolAvailable $runtimeToolAvailable -ArtifactRead $liveCommitProofArtifactReadResult -PathGate $liveCommitProofArtifactPathGate
$runtimeWriterCommitRunnerArtifactHandoff = New-RuntimeWriterCommitRunnerArtifactHandoff -CommandBoundary $runtimeWriterCommitRunnerCommandBoundary -ReadbackBoundary $liveCommitProofReadbackBoundary
$runtimeWriterCommitRunnerArtifactAcceptanceSelfTest = Invoke-RuntimeWriterCommitRunnerArtifactAcceptanceSelfTest -Requested $runtimeWriterCommitRunnerAcceptanceSelfTestRequested -CurrentCommit (Get-CurrentCommitMarker)
$canonicalCutoverArtifactGuardSelfTest = Invoke-CanonicalCutoverArtifactGuardSelfTest -Requested $canonicalCutoverArtifactGuardSelfTestRequested -CurrentCommit (Get-CurrentCommitMarker) -RuntimeCommitMarker $runtimeCommitMarkerValue
$singleWriterCutoverProofGate = New-SingleWriterCutoverProofGate -ProofRequested $singleWriterProofRequested -LiveCommitProofAvailable $liveCommitProofAvailable -LiveCommitReadback $liveCommitReadbackMarkerValue -ActiveWriter $activeWriterMarkerValue -SourceOfTruth $sourceOfTruthMarkerValue -LocalWriterDisabled $localWriterDisabledForCutover -RuntimeEvidenceTrustGate $runtimeEvidenceTrustGate -RollbackGate $liveDbRollbackOnlyExecutorGate -LiveCommitProofReadbackBoundary $liveCommitProofReadbackBoundary -RuntimeWriterCommitRunnerArtifactHandoff $runtimeWriterCommitRunnerArtifactHandoff
$productionCutoverAcceptanceGate = New-ProductionCutoverAcceptanceGate -Accepted $productionCutoverAccepted -LiveCommitProofAvailable $liveCommitProofAvailable -RollbackPlanAcknowledged $rollbackPlanAcknowledged -ShadowHandoff $shadowCommitHandoffSummary -RollbackGate $liveDbRollbackOnlyExecutorGate -RuntimeEvidenceTrustGate $runtimeEvidenceTrustGate -SingleWriterProofGate $singleWriterCutoverProofGate -Mode ([string]$mode.Mode)
$productionWriterCutoverPreflight = New-ProductionWriterCutoverPreflight -LiveAttempt $realLiveDbRollbackAttempt -RollbackGate $liveDbRollbackOnlyExecutorGate -Mode ([string]$mode.Mode) -AcceptanceGate $productionCutoverAcceptanceGate
$cutoverFinalDoDChecklist = New-CutoverFinalDoDChecklist -RuntimeEvidenceTrustGate $runtimeEvidenceTrustGate -RuntimeWriterCommitRunnerArtifactHandoff $runtimeWriterCommitRunnerArtifactHandoff -LiveCommitProofReadbackBoundary $liveCommitProofReadbackBoundary -SingleWriterProofGate $singleWriterCutoverProofGate -ProductionCutoverAcceptanceGate $productionCutoverAcceptanceGate -ProductionWriterCutoverPreflight $productionWriterCutoverPreflight -RollbackGate $liveDbRollbackOnlyExecutorGate
$cutoverOperatorRunbookPreflight = New-CutoverOperatorRunbookPreflight -CutoverFinalDoDChecklist $cutoverFinalDoDChecklist -RuntimeEvidenceTrustGate $runtimeEvidenceTrustGate -RuntimeWriterCommitRunnerCommandBoundary $runtimeWriterCommitRunnerCommandBoundary -RuntimeWriterCommitRunnerArtifactHandoff $runtimeWriterCommitRunnerArtifactHandoff -LiveCommitProofReadbackBoundary $liveCommitProofReadbackBoundary -SingleWriterProofGate $singleWriterCutoverProofGate -ProductionCutoverAcceptanceGate $productionCutoverAcceptanceGate -ProductionWriterCutoverPreflight $productionWriterCutoverPreflight -RollbackGate $liveDbRollbackOnlyExecutorGate -LiveCommitProofArtifactPathGate $liveCommitProofArtifactPathGate
$cutoverEvidenceFallbackArtifact = if ($cutoverEvidenceAcceptedShapeSimulationRequested) {
  New-CutoverEvidenceAcceptedShapeArtifact -CurrentCommit (Get-CurrentCommitMarker) -RuntimeCommitMarker $runtimeCommitMarkerValue
} else {
  [ordered]@{
    schema_version = [string]$cutoverEvidenceAcceptanceMatrixContract.artifact_schema.schema_version
    artifact_mode = "missing_external_cutover_evidence_artifact"
  }
}
$cutoverEvidenceArtifactPathGate = Resolve-SafeProbeArtifactPath -RequestedPath $cutoverEvidenceArtifactPathValue -DefaultRelativePath ".tmp\billing-ledger\cutover-evidence-artifact.json"
$cutoverEvidenceArtifactReadResult = Read-ProbeArtifactIfAllowed -FallbackArtifact $cutoverEvidenceFallbackArtifact -PathGate $cutoverEvidenceArtifactPathGate -ReadRequested $cutoverEvidenceArtifactReadRequested
$cutoverEvidenceArtifactForMatrix = if ($cutoverEvidenceAcceptedShapeSimulationRequested) {
  [ordered]@{
    requested = $false
    performed = $false
    classification = "pass"
    reason = "accepted_shape_simulation_fixture"
    relative_path = [string]$cutoverEvidenceArtifactPathGate.relative_path
    artifact = $cutoverEvidenceFallbackArtifact
  }
} else {
  $cutoverEvidenceArtifactReadResult
}
$cutoverEvidenceAcceptanceMatrix = New-CutoverEvidenceAcceptanceMatrix -ArtifactRead $cutoverEvidenceArtifactForMatrix -PathGate $cutoverEvidenceArtifactPathGate -SimulationRequested $cutoverEvidenceAcceptedShapeSimulationRequested -CurrentCommit (Get-CurrentCommitMarker) -RuntimeCommitMarker $runtimeCommitMarkerValue
$cutoverFinalClosureAudit = New-CutoverFinalClosureAudit -RuntimeEvidenceTrustGate $runtimeEvidenceTrustGate -RuntimeWriterCommitRunnerArtifactHandoff $runtimeWriterCommitRunnerArtifactHandoff -LiveCommitProofReadbackBoundary $liveCommitProofReadbackBoundary -SingleWriterCutoverProofGate $singleWriterCutoverProofGate -CutoverEvidenceAcceptanceMatrix $cutoverEvidenceAcceptanceMatrix -AcceptedShapeSimulationRequested $cutoverEvidenceAcceptedShapeSimulationRequested -CurrentCommit (Get-CurrentCommitMarker)
$cutoverEvidenceWatcherChecklist = New-CutoverEvidenceWatcherChecklist -CutoverFinalClosureAudit $cutoverFinalClosureAudit -LiveCommitProofArtifactRead $liveCommitProofArtifactReadResult -LiveCommitProofArtifactPathGate $liveCommitProofArtifactPathGate -CutoverEvidenceArtifactRead $cutoverEvidenceArtifactForMatrix -CutoverEvidenceArtifactPathGate $cutoverEvidenceArtifactPathGate -CutoverEvidenceAcceptanceMatrix $cutoverEvidenceAcceptanceMatrix

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
  live_probe_artifact_path_gate = [ordered]@{
    schema_version = "control_plane_billing_ledger_live_probe_artifact_path_gate.v1"
    write_requested = $artifactWriteRequested
    read_requested = $artifactReadRequested
    safe = [bool]$artifactPathGate.safe
    classification = if ([bool]$artifactPathGate.safe) { "pass" } else { "blocker" }
    reason = [string]$artifactPathGate.reason
    relative_path = [string]$artifactPathGate.relative_path
    allowed_root = ".tmp"
    env_value_output = "omitted"
    raw_path_output = "omitted"
  }
  live_probe_artifact_write = [ordered]@{
    requested = [bool]$artifactWriteResult.requested
    performed = [bool]$artifactWriteResult.performed
    classification = [string]$artifactWriteResult.classification
    reason = [string]$artifactWriteResult.reason
    relative_path = [string]$artifactWriteResult.relative_path
  }
  live_probe_artifact_read = [ordered]@{
    requested = [bool]$artifactReadResult.requested
    performed = [bool]$artifactReadResult.performed
    classification = [string]$artifactReadResult.classification
    reason = [string]$artifactReadResult.reason
    relative_path = [string]$artifactReadResult.relative_path
  }
  live_probe_measurement_readback_gate = $liveProbeMeasurementReadbackGate
  live_db_executor_probe_command_boundary = $liveDbExecutorProbeCommandBoundary
  live_db_executor_sql_bridge_readiness_artifact = $liveDbExecutorSqlBridgeReadinessArtifact
  live_db_rollback_only_executor_gate = $liveDbRollbackOnlyExecutorGate
  real_live_db_rollback_attempt = $realLiveDbRollbackAttempt
  shadow_commit_handoff = $shadowCommitHandoffSummary
  runtime_evidence_trust_gate = $runtimeEvidenceTrustGate
  live_commit_proof_artifact_path_gate = [ordered]@{
    schema_version = "control_plane_billing_ledger_live_commit_proof_artifact_path_gate.v1"
    write_requested = $liveCommitProofArtifactWriteRequested
    read_requested = $liveCommitProofArtifactReadRequested
    safe = [bool]$liveCommitProofArtifactPathGate.safe
    classification = if ([bool]$liveCommitProofArtifactPathGate.safe) { "pass" } else { "blocker" }
    reason = [string]$liveCommitProofArtifactPathGate.reason
    relative_path = [string]$liveCommitProofArtifactPathGate.relative_path
    allowed_root = ".tmp"
    env_value_output = "omitted"
    raw_path_output = "omitted"
  }
  live_commit_proof_artifact_write = [ordered]@{
    requested = [bool]$liveCommitProofArtifactWriteResult.requested
    performed = [bool]$liveCommitProofArtifactWriteResult.performed
    classification = [string]$liveCommitProofArtifactWriteResult.classification
    reason = [string]$liveCommitProofArtifactWriteResult.reason
    relative_path = [string]$liveCommitProofArtifactWriteResult.relative_path
    template_can_pass = $false
  }
  live_commit_proof_artifact_read = [ordered]@{
    requested = [bool]$liveCommitProofArtifactReadResult.requested
    performed = [bool]$liveCommitProofArtifactReadResult.performed
    classification = [string]$liveCommitProofArtifactReadResult.classification
    reason = [string]$liveCommitProofArtifactReadResult.reason
    relative_path = [string]$liveCommitProofArtifactReadResult.relative_path
  }
  live_commit_proof_readback_boundary = $liveCommitProofReadbackBoundary
  runtime_writer_commit_runner_command_boundary = $runtimeWriterCommitRunnerCommandBoundary
  runtime_writer_commit_runner_artifact_handoff = $runtimeWriterCommitRunnerArtifactHandoff
  runtime_writer_commit_runner_artifact_acceptance_self_test = $runtimeWriterCommitRunnerArtifactAcceptanceSelfTest
  canonical_cutover_artifact_guard_self_test = $canonicalCutoverArtifactGuardSelfTest
  single_writer_cutover_proof_gate = $singleWriterCutoverProofGate
  production_cutover_acceptance_gate = $productionCutoverAcceptanceGate
  production_writer_cutover_preflight = $productionWriterCutoverPreflight
  cutover_final_dod_checklist = $cutoverFinalDoDChecklist
  cutover_operator_runbook_preflight = $cutoverOperatorRunbookPreflight
  cutover_evidence_artifact_path_gate = [ordered]@{
    schema_version = "control_plane_billing_ledger_cutover_evidence_artifact_path_gate.v1"
    read_requested = $cutoverEvidenceArtifactReadRequested
    accepted_shape_simulation_requested = $cutoverEvidenceAcceptedShapeSimulationRequested
    safe = [bool]$cutoverEvidenceArtifactPathGate.safe
    classification = if ([bool]$cutoverEvidenceArtifactPathGate.safe) { "pass" } else { "blocker" }
    reason = [string]$cutoverEvidenceArtifactPathGate.reason
    relative_path = [string]$cutoverEvidenceArtifactPathGate.relative_path
    allowed_root = ".tmp"
    env_value_output = "omitted"
    raw_path_output = "omitted"
  }
  cutover_evidence_artifact_read = [ordered]@{
    requested = [bool]$cutoverEvidenceArtifactForMatrix.requested
    performed = [bool]$cutoverEvidenceArtifactForMatrix.performed
    classification = [string]$cutoverEvidenceArtifactForMatrix.classification
    reason = [string]$cutoverEvidenceArtifactForMatrix.reason
    relative_path = [string]$cutoverEvidenceArtifactForMatrix.relative_path
    simulation_can_mark_final_x = $false
  }
  cutover_evidence_acceptance_matrix = $cutoverEvidenceAcceptanceMatrix
  cutover_final_closure_audit = $cutoverFinalClosureAudit
  cutover_evidence_watcher_checklist = $cutoverEvidenceWatcherChecklist
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

$json = $summary | ConvertTo-Json -Depth 20
Assert-SecretSafeJson -Json $json
Write-Output $json

if ($readiness -eq "blocked") {
  exit $BlockedExitCode
}

exit 0
