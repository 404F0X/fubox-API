param(
  [ValidateSet("staging", "production")]
  [string]$Scope = "staging",
  [switch]$ExecuteSourceOfTruthSwitch,
  [switch]$AcknowledgeRollbackPlan,
  [AllowNull()][string]$LiveCommitProofArtifactPath,
  [AllowNull()][string]$LocalDevCutoverEvidenceArtifactPath,
  [AllowNull()][string]$FinalReadbackArtifactPath,
  [AllowNull()][string]$OutputArtifactPath,
  [int]$BlockedExitCode = 2
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$expectedWriter = "billing_ledger_runtime_writer"
$localWriter = "control_plane_local_sql_writer"

function Test-Present {
  param([AllowNull()][string]$Value)
  return -not [string]::IsNullOrWhiteSpace($Value)
}

function Resolve-RepoTmpJsonPath {
  param([Parameter(Mandatory = $true)][string]$PathValue)

  $candidate = if ([System.IO.Path]::IsPathRooted($PathValue)) {
    [System.IO.Path]::GetFullPath($PathValue)
  } else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $PathValue))
  }
  $repoFull = [System.IO.Path]::GetFullPath($repoRoot)
  $relative = [System.IO.Path]::GetRelativePath($repoFull, $candidate)
  $normalized = $relative.Replace("\", "/")
  $safe = -not $relative.StartsWith("..") -and
    -not [System.IO.Path]::IsPathRooted($relative) -and
    $normalized.StartsWith(".tmp/") -and
    $normalized.EndsWith(".json", [System.StringComparison]::OrdinalIgnoreCase)

  return [ordered]@{
    safe = $safe
    relative_path = $relative
    full_path = $candidate
    reason = if ($safe) { "allowed_repo_tmp_json_path" } else { "path_must_be_repo_bounded_tmp_json" }
    raw_path_output = "omitted"
  }
}

function Read-JsonArtifact {
  param([Parameter(Mandatory = $true)]$PathGate)

  if (-not [bool]$PathGate.safe) {
    return [ordered]@{ performed = $false; classification = "blocker"; reason = "unsafe_path"; artifact = $null }
  }
  if (-not (Test-Path -LiteralPath ([string]$PathGate.full_path))) {
    return [ordered]@{ performed = $false; classification = "blocker"; reason = "artifact_missing"; artifact = $null }
  }
  try {
    return [ordered]@{
      performed = $true
      classification = "read"
      reason = "artifact_read"
      artifact = Get-Content -LiteralPath ([string]$PathGate.full_path) -Raw | ConvertFrom-Json -ErrorAction Stop
    }
  } catch {
    return [ordered]@{ performed = $false; classification = "fail"; reason = "artifact_json_parse_failed"; artifact = $null }
  }
}

function Get-Field {
  param(
    [AllowNull()]$Object,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if ($null -eq $Object) { return $null }
  if ($Object.PSObject.Properties.Name -notcontains $Name) { return $null }
  return $Object.$Name
}

function Test-FileContains {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Pattern
  )
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  return [bool](Select-String -LiteralPath $Path -Pattern $Pattern -Quiet)
}

function Get-CurrentCommit {
  try {
    return ((git -C $repoRoot rev-parse --short HEAD) | Select-Object -First 1).Trim()
  } catch {
    return "unknown"
  }
}

$liveCommitPathValue = if (Test-Present $LiveCommitProofArtifactPath) { $LiveCommitProofArtifactPath } else { ".tmp/billing-ledger/live-commit-proof-artifact.json" }
$localDevPathValue = if (Test-Present $LocalDevCutoverEvidenceArtifactPath) { $LocalDevCutoverEvidenceArtifactPath } else { ".tmp/billing-ledger/cutover-evidence-artifact.local-dev.json" }
$finalReadbackPathValue = if (Test-Present $FinalReadbackArtifactPath) { $FinalReadbackArtifactPath } else { ".tmp/billing-ledger/s101-final-readback-write-rollback.json" }
$outputPathValue = if (Test-Present $OutputArtifactPath) { $OutputArtifactPath } else { ".tmp/billing-ledger/cutover-evidence-artifact.$Scope.json" }

$liveCommitGate = Resolve-RepoTmpJsonPath -PathValue $liveCommitPathValue
$localDevGate = Resolve-RepoTmpJsonPath -PathValue $localDevPathValue
$finalReadbackGate = Resolve-RepoTmpJsonPath -PathValue $finalReadbackPathValue
$outputGate = Resolve-RepoTmpJsonPath -PathValue $outputPathValue

$liveCommitRead = Read-JsonArtifact -PathGate $liveCommitGate
$localDevRead = Read-JsonArtifact -PathGate $localDevGate
$finalReadbackRead = Read-JsonArtifact -PathGate $finalReadbackGate

$liveCommit = $liveCommitRead.artifact
$localDev = $localDevRead.artifact
$finalReadback = $finalReadbackRead.artifact

$liveCommitPass = [string](Get-Field -Object $liveCommit -Name "classification") -eq "pass" -and
  [bool](Get-Field -Object $liveCommit -Name "simulated") -eq $false -and
  [bool](Get-Field -Object $liveCommit -Name "generated_by_this_script") -eq $false
$localDevProofPass = [string](Get-Field -Object $localDev -Name "environment_scope") -eq "local_dev" -and
  [bool](Get-Field -Object (Get-Field -Object $localDev -Name "post_cutover_readback") -Name "performed") -and
  [bool](Get-Field -Object (Get-Field -Object $localDev -Name "rollback_proof") -Name "performed")
$finalReadbackCommitPass = $null -ne $finalReadback -and
  [string](Get-Field -Object (Get-Field -Object $finalReadback -Name "runtime_writer_commit_runner_artifact_handoff") -Name "classification") -eq "pass" -and
  [string](Get-Field -Object (Get-Field -Object $finalReadback -Name "live_commit_proof_readback_boundary") -Name "classification") -eq "pass"

$adminPath = Join-Path $repoRoot "apps\control-plane\src\admin.rs"
$migrationPaths = @(Get-ChildItem -Path (Join-Path $repoRoot "db\migrations") -Filter "*.sql" -ErrorAction SilentlyContinue)
$migrationText = ""
foreach ($migrationPath in $migrationPaths) {
  $migrationText += "`n" + (Get-Content -LiteralPath $migrationPath.FullName -Raw)
}

$persistentStoreDetected = $migrationText -match "(?i)create\s+table\s+.*(billing_ledger.*(cutover|writer|source_of_truth|active_writer)|control_plane.*(setting|config|state)|system_(setting|config)|feature_flag)"
$adminEnvOnlyDetected = (Test-FileContains -Path $adminPath -Pattern "from_process_env") -and
  (Test-FileContains -Path $adminPath -Pattern "production_source_of_truth_switch_allowed_in_this_contract.: false") -and
  (Test-FileContains -Path $adminPath -Pattern "control_plane_local_sql_writer_remains_authoritative")
$runtimeCommitCliOnlyMarkers = Test-FileContains -Path (Join-Path $repoRoot "crates\billing-ledger\src\bin\runtime_writer_commit.rs") -Pattern "--source-of-truth"

$implementationBlockers = New-Object System.Collections.Generic.List[string]
if (-not $persistentStoreDetected) { [void]$implementationBlockers.Add("persistent_cutover_state_store_missing") }
if ($adminEnvOnlyDetected) { [void]$implementationBlockers.Add("control_plane_cutover_is_env_summary_only") }
if ($runtimeCommitCliOnlyMarkers) { [void]$implementationBlockers.Add("runtime_writer_commit_cli_accepts_markers_but_does_not_persist_cutover_state") }
[void]$implementationBlockers.Add("control_plane_source_of_truth_write_api_missing")
[void]$implementationBlockers.Add("runtime_writer_dispatch_not_backed_by_persistent_cutover_readback")

$blockers = New-Object System.Collections.Generic.List[string]
if (-not [bool]$ExecuteSourceOfTruthSwitch) { [void]$blockers.Add("execute_source_of_truth_switch_opt_in_missing") }
if (-not [bool]$AcknowledgeRollbackPlan) { [void]$blockers.Add("rollback_plan_acknowledgement_missing") }
if (-not $liveCommitPass) { [void]$blockers.Add("s101_live_commit_proof_not_passed") }
if (-not $localDevProofPass) { [void]$blockers.Add("s103_local_dev_cutover_proof_not_passed") }
if (-not $finalReadbackCommitPass) { [void]$blockers.Add("s101_final_readback_not_passed") }
if (-not [bool]$outputGate.safe) { [void]$blockers.Add("output_artifact_path_not_repo_bounded") }
foreach ($implementationBlocker in @($implementationBlockers)) {
  [void]$blockers.Add([string]$implementationBlocker)
}

$artifactWritten = $false
if ([bool]$outputGate.safe) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent ([string]$outputGate.full_path)) | Out-Null
  $rowCounts = @(Get-Field -Object $liveCommit -Name "row_count_proof")
  $artifact = [ordered]@{
    schema_version = "control_plane_billing_ledger_cutover_evidence_artifact.v1"
    environment_scope = $Scope
    generated_at_utc = [DateTimeOffset]::UtcNow.ToString("o")
    current_commit = Get-CurrentCommit
    runtime_container_commit = [string](Get-Field -Object $liveCommit -Name "runtime_container_commit")
    freshness_marker = "current"
    stale_artifact = $false
    simulated = $false
    template = $false
    artifact_provenance = [ordered]@{
      source = "repo_native_cutover_executor_feasibility"
      environment_scope = $Scope
      repo_native_executor_found = $false
      production_cutover = $false
      staging_cutover = $false
      canonical_production_artifact = $false
      refusal_artifact = $true
    }
    external_runner_provenance = [ordered]@{
      runner_id = "e9_billing_ledger_repo_native_cutover_executor_feasibility"
      runner_path = "scripts/operator/e9_billing_ledger_repo_native_cutover_executor_feasibility.ps1"
      source_of_truth_switch_performed = $false
      output = "sanitized_presence_only"
    }
    commit_proof_row_counts = @($rowCounts)
    no_dual_result = [ordered]@{
      passed = $false
      dual_commit_observed = $false
      active_writer_count = 0
      refusal_reason = "persistent_cutover_state_store_missing"
    }
    active_writer_before = $localWriter
    source_of_truth_before = $localWriter
    active_writer_after = $localWriter
    source_of_truth_after = $localWriter
    actual_cutover_opt_in_marker = [ordered]@{
      performed = $false
      requested = [bool]$ExecuteSourceOfTruthSwitch
      acknowledgement = [bool]$AcknowledgeRollbackPlan
      environment_scope = $Scope
      refusal_reason = "repo_native_persistent_cutover_executor_missing"
    }
    post_cutover_readback = [ordered]@{
      performed = $false
      source_of_truth = $localWriter
      active_writer = $localWriter
      no_dual_commit = $false
      refusal_reason = "no_persistent_source_of_truth_to_read_back"
    }
    rollback_command = [ordered]@{
      available = $false
      refusal_reason = "no_persistent_cutover_state_to_rollback"
    }
    rollback_proof = [ordered]@{
      present = $false
      performed = $false
      refusal_reason = "no_persistent_cutover_state_changed"
    }
    duration_timing = [ordered]@{
      repo_scan_ms = 0
      db_write_ms = 0
      post_cutover_readback_ms = 0
      measurement_source = "repo_native_static_feasibility_scan"
    }
    secret_safe_omission = [ordered]@{
      raw_secret_present = $false
      database_url_output = "omitted"
      env_value_output = "omitted"
      operation_key_output = "omitted"
      raw_env_value_echoed = $false
      raw_database_url_echoed = $false
      credential_material_echoed = $false
    }
  }
  $artifact | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath ([string]$outputGate.full_path) -Encoding utf8
  $artifactWritten = $true
}

$result = [ordered]@{
  schema_version = "control_plane_billing_ledger_repo_native_cutover_executor_feasibility.v1"
  generated_at_utc = [DateTimeOffset]::UtcNow.ToString("o")
  classification = "blocked"
  environment_scope = $Scope
  repo_native_source_of_truth_switch_executed = $false
  production_final_artifact_written = $false
  feasibility_artifact = [ordered]@{
    written = $artifactWritten
    relative_path = [string]$outputGate.relative_path
    path_safe = [bool]$outputGate.safe
    artifact_is_refusal_not_cutover = $true
  }
  prerequisites = [ordered]@{
    s101_live_commit_proof_pass = $liveCommitPass
    s103_local_dev_cutover_proof_pass = $localDevProofPass
    s101_final_readback_commit_pass = $finalReadbackCommitPass
  }
  repo_findings = [ordered]@{
    persistent_cutover_state_store_detected = $persistentStoreDetected
    control_plane_cutover_env_summary_only = $adminEnvOnlyDetected
    runtime_commit_cli_marker_only = $runtimeCommitCliOnlyMarkers
    inspected_files = @(
      "apps/control-plane/src/admin.rs",
      "db/migrations/*.sql",
      "crates/billing-ledger/src/bin/runtime_writer_commit.rs"
    )
  }
  blockers = @($blockers | Select-Object -Unique)
  first_blocker = ($blockers | Select-Object -Unique | Select-Object -First 1)
  missing_repo_native_implementation = [ordered]@{
    persistent_table = "billing_ledger_writer_cutover_state or control_plane_runtime_settings"
    required_columns = @("scope", "active_writer", "source_of_truth", "previous_writer", "cutover_generation", "updated_at", "updated_by", "rollback_token_or_generation")
    required_api_or_cli = "guarded source-of-truth switch writer with compare-and-swap/readback"
    required_runtime_integration = "Control Plane execute path reads persistent source-of-truth before choosing local SQL writer vs billing-ledger runtime writer"
    required_rollback = "bounded rollback command updates same persistent state and proves post-rollback readback"
  }
  safe_output = [ordered]@{
    database_url_output = "omitted"
    env_value_output = "omitted"
    operation_key_output = "omitted"
    raw_env_value_echoed = $false
    raw_database_url_echoed = $false
    credential_material_echoed = $false
    raw_executor_error_detail_echoed = $false
  }
}

$result | ConvertTo-Json -Depth 8
exit $BlockedExitCode
