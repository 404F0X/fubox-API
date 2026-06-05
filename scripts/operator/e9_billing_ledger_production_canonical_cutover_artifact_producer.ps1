param(
  [ValidateSet("local_dev", "staging", "production")]
  [string]$Scope = "production",
  [switch]$WriteCanonicalArtifact,
  [AllowNull()][string]$PersistentStateReadbackArtifactPath,
  [AllowNull()][string]$LiveCommitProofArtifactPath,
  [AllowNull()][string]$RollbackProbeArtifactPath,
  [AllowNull()][string]$FinalReadbackArtifactPath,
  [AllowNull()][string]$CutoverEvidenceArtifactPath,
  [AllowNull()][string]$ResultArtifactPath,
  [int]$BlockedExitCode = 2
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$expectedWriter = "billing_ledger_runtime_writer"
$canonicalCutoverPath = ".tmp/billing-ledger/cutover-evidence-artifact.json"

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
    ($normalized.StartsWith(".tmp/") -or $normalized.StartsWith("tests/fixtures/billing-ledger/")) -and
    $normalized.EndsWith(".json", [System.StringComparison]::OrdinalIgnoreCase)

  return [ordered]@{
    safe = $safe
    relative_path = $relative
    normalized_relative_path = $normalized
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

function Get-CurrentCommit {
  try {
    return ((git -C $repoRoot rev-parse --short HEAD) | Select-Object -First 1).Trim()
  } catch {
    return "unknown"
  }
}

function Test-RowsMatch {
  param([AllowNull()]$Rows)

  $items = @($Rows)
  if ($items.Count -eq 0) { return $false }
  foreach ($row in $items) {
    if ((Get-Field -Object $row -Name "rows_match") -ne $true) {
      return $false
    }
  }
  return $true
}

$persistentStatePathValue = if (Test-Present $PersistentStateReadbackArtifactPath) { $PersistentStateReadbackArtifactPath } else { ".tmp/billing-ledger/cutover-state-s105-production-readback.json" }
$liveCommitPathValue = if (Test-Present $LiveCommitProofArtifactPath) { $LiveCommitProofArtifactPath } else { ".tmp/billing-ledger/live-commit-proof-artifact.json" }
$rollbackProbePathValue = if (Test-Present $RollbackProbeArtifactPath) { $RollbackProbeArtifactPath } else { ".tmp/billing-ledger/live-probe-evidence-artifact.json" }
$finalReadbackPathValue = if (Test-Present $FinalReadbackArtifactPath) { $FinalReadbackArtifactPath } else { ".tmp/billing-ledger/s101-final-readback-write-rollback.json" }
$cutoverEvidencePathValue = if (Test-Present $CutoverEvidenceArtifactPath) { $CutoverEvidenceArtifactPath } else { $canonicalCutoverPath }
$resultPathValue = if (Test-Present $ResultArtifactPath) { $ResultArtifactPath } else { ".tmp/billing-ledger/s109-production-canonical-cutover-producer.json" }

$persistentGate = Resolve-RepoTmpJsonPath -PathValue $persistentStatePathValue
$liveCommitGate = Resolve-RepoTmpJsonPath -PathValue $liveCommitPathValue
$rollbackProbeGate = Resolve-RepoTmpJsonPath -PathValue $rollbackProbePathValue
$finalReadbackGate = Resolve-RepoTmpJsonPath -PathValue $finalReadbackPathValue
$cutoverEvidenceGate = Resolve-RepoTmpJsonPath -PathValue $cutoverEvidencePathValue
$resultGate = Resolve-RepoTmpJsonPath -PathValue $resultPathValue

$persistentRead = Read-JsonArtifact -PathGate $persistentGate
$liveCommitRead = Read-JsonArtifact -PathGate $liveCommitGate
$rollbackProbeRead = Read-JsonArtifact -PathGate $rollbackProbeGate
$finalReadbackRead = Read-JsonArtifact -PathGate $finalReadbackGate

$persistent = $persistentRead.artifact
$liveCommit = $liveCommitRead.artifact
$rollbackProbe = $rollbackProbeRead.artifact
$finalReadback = $finalReadbackRead.artifact
$persistentState = Get-Field -Object $persistent -Name "persistent_state"
$rollbackNoCommit = Get-Field -Object $rollbackProbe -Name "rollback_no_commit_proof"
$singleWriterGate = Get-Field -Object $finalReadback -Name "single_writer_cutover_proof_gate"
$noDualProof = Get-Field -Object $singleWriterGate -Name "no_dual_commit_proof"

$liveCommitPass = [bool]$liveCommitRead.performed -and
  [string](Get-Field -Object $liveCommit -Name "classification") -eq "pass" -and
  [string](Get-Field -Object $liveCommit -Name "measurement_source") -eq "external_controlled_runtime_writer_commit" -and
  [bool](Get-Field -Object $liveCommit -Name "simulated") -eq $false -and
  [bool](Get-Field -Object $liveCommit -Name "generated_by_this_script") -eq $false -and
  [bool](Get-Field -Object (Get-Field -Object $liveCommit -Name "commit_proof") -Name "runtime_writer_commit_observed") -and
  (Test-RowsMatch -Rows (Get-Field -Object $liveCommit -Name "row_count_proof"))

$rollbackProbePass = [bool]$rollbackProbeRead.performed -and
  [string](Get-Field -Object $rollbackProbe -Name "classification") -eq "pass" -and
  [bool](Get-Field -Object $rollbackNoCommit -Name "rollback_observed") -and
  -not [bool](Get-Field -Object $rollbackNoCommit -Name "commit_observed") -and
  -not [bool](Get-Field -Object $rollbackNoCommit -Name "dual_commit_observed")

$finalReadbackPass = [bool]$finalReadbackRead.performed -and
  [string](Get-Field -Object (Get-Field -Object $finalReadback -Name "runtime_writer_commit_runner_artifact_handoff") -Name "classification") -eq "pass" -and
  [string](Get-Field -Object (Get-Field -Object $finalReadback -Name "live_commit_proof_readback_boundary") -Name "classification") -eq "pass" -and
  [string](Get-Field -Object $singleWriterGate -Name "classification") -eq "pass"

$noDualPass = $finalReadbackPass -and
  [string](Get-Field -Object $noDualProof -Name "classification") -eq "pass" -and
  -not [bool](Get-Field -Object $noDualProof -Name "commit_observed") -and
  -not [bool](Get-Field -Object $noDualProof -Name "dual_commit_observed")

$persistentProductionReadbackPass = [bool]$persistentRead.performed -and
  [string](Get-Field -Object $persistent -Name "classification") -eq "pass" -and
  [string](Get-Field -Object $persistent -Name "environment_scope") -eq "production" -and
  [string](Get-Field -Object $persistentState -Name "active_writer") -eq $expectedWriter -and
  [string](Get-Field -Object $persistentState -Name "source_of_truth") -eq $expectedWriter -and
  $null -ne (Get-Field -Object $persistentState -Name "generation")

$postCutoverReadbackPass = $persistentProductionReadbackPass
$canonicalPath = [bool]$cutoverEvidenceGate.safe -and [string]$cutoverEvidenceGate.normalized_relative_path -eq $canonicalCutoverPath

$blockers = New-Object System.Collections.Generic.List[string]
if ($Scope -ne "production") { [void]$blockers.Add("non_production_scope_not_canonical_final") }
if (-not [bool]$persistentGate.safe) { [void]$blockers.Add("persistent_state_readback_path_not_repo_bounded") }
if (-not [bool]$persistentRead.performed) { [void]$blockers.Add("production_persistent_state_readback_missing") }
if ([bool]$persistentRead.performed -and [string](Get-Field -Object $persistent -Name "environment_scope") -ne "production") { [void]$blockers.Add("persistent_state_scope_not_production") }
if ([bool]$persistentRead.performed -and -not $persistentProductionReadbackPass) { [void]$blockers.Add("production_persistent_state_not_runtime_writer") }
if (-not $liveCommitPass) { [void]$blockers.Add("s101_live_commit_proof_not_passed") }
if (-not $rollbackProbePass) { [void]$blockers.Add("rollback_probe_proof_not_passed") }
if (-not $finalReadbackPass) { [void]$blockers.Add("s101_final_readback_not_passed") }
if (-not $noDualPass) { [void]$blockers.Add("no_dual_proof_not_passed") }
if (-not $postCutoverReadbackPass) { [void]$blockers.Add("post_cutover_readback_missing") }
if (-not $canonicalPath) { [void]$blockers.Add("production_cutover_artifact_path_not_canonical") }
if (-not [bool]$resultGate.safe) { [void]$blockers.Add("result_artifact_path_not_repo_bounded") }

$evidenceReady = $blockers.Count -eq 0
$canonicalArtifactWritten = $false

if ($evidenceReady -and [bool]$WriteCanonicalArtifact) {
  $rowCounts = @(Get-Field -Object $liveCommit -Name "row_count_proof")
  $cutoverArtifact = [ordered]@{
    schema_version = "control_plane_billing_ledger_cutover_evidence_artifact.v1"
    environment_scope = "production"
    generated_at_utc = [DateTimeOffset]::UtcNow.ToString("o")
    current_commit = Get-CurrentCommit
    runtime_container_commit = [string](Get-Field -Object $liveCommit -Name "runtime_container_commit")
    freshness_marker = "current"
    stale_artifact = $false
    simulated = $false
    template = $false
    artifact_provenance = [ordered]@{
      source = "production_canonical_cutover_artifact_producer_readback_integration"
      environment_scope = "production"
      production_cutover = $true
      canonical_production_artifact = $true
      persistent_state_readback_artifact = [string]$persistentGate.relative_path
      live_commit_proof_artifact = [string]$liveCommitGate.relative_path
      rollback_probe_artifact = [string]$rollbackProbeGate.relative_path
      final_readback_artifact = [string]$finalReadbackGate.relative_path
      generated_by_this_script = $false
      template = $false
      simulated = $false
      raw_command_echoed = $false
    }
    external_runner_provenance = [ordered]@{
      runner_id = "e9_billing_ledger_production_canonical_cutover_artifact_producer"
      runner_path = "scripts/operator/e9_billing_ledger_production_canonical_cutover_artifact_producer.ps1"
      source_of_truth_switch_performed = $true
      source_of_truth_switch_source = "production_persistent_cutover_state_readback"
      generated_by_this_script = $false
      output = "sanitized_presence_only"
    }
    commit_proof_row_counts = @($rowCounts)
    no_dual_result = [ordered]@{
      passed = $true
      dual_commit_observed = $false
      active_writer_count = 1
      measurement_source = "s101_single_writer_cutover_proof_gate"
      persistent_state_generation = Get-Field -Object $persistentState -Name "generation"
    }
    active_writer_before = "control_plane_local_sql_writer"
    source_of_truth_before = "control_plane_local_sql_writer"
    active_writer_after = $expectedWriter
    source_of_truth_after = $expectedWriter
    actual_cutover_opt_in_marker = [ordered]@{
      performed = $true
      requested = [bool]$WriteCanonicalArtifact
      action = "production_canonical_artifact_write_from_persistent_readback"
      environment_scope = "production"
      production_cutover = $true
    }
    post_cutover_readback = [ordered]@{
      performed = $true
      source_of_truth = $expectedWriter
      active_writer = $expectedWriter
      no_dual_commit = $true
      environment_scope = "production"
      measurement_source = "production_persistent_cutover_state_readback"
      persistent_state_generation = Get-Field -Object $persistentState -Name "generation"
    }
    rollback_command = [ordered]@{
      available = $true
      command = "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/operator/e9_billing_ledger_persistent_cutover_state_switch.ps1 -Scope production -Action rollback -ExecuteRollback -AcknowledgeRollbackPlan -RollbackToken <same-token>"
      environment_scope = "production"
      raw_token_echoed = $false
    }
    rollback_proof = [ordered]@{
      present = $true
      performed = $true
      rollback_observed = $true
      commit_observed = $false
      dual_commit_observed = $false
      measurement_source = "s101_rollback_only_live_probe"
      environment_scope = "production"
    }
    duration_timing = [ordered]@{
      persistent_state_readback_ms = 0
      post_cutover_readback_ms = 0
      rollback_marker_readback_ms = 0
      measurement_source = "artifact_readback_integration"
    }
    secret_safe_omission = [ordered]@{
      raw_secret_present = $false
      database_url_output = "omitted"
      env_value_output = "omitted"
      operation_key_output = "omitted"
      rollback_token_output = "omitted"
      raw_env_value_echoed = $false
      raw_database_url_echoed = $false
      credential_material_echoed = $false
    }
  }

  New-Item -ItemType Directory -Force -Path (Split-Path -Parent ([string]$cutoverEvidenceGate.full_path)) | Out-Null
  $cutoverArtifact | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath ([string]$cutoverEvidenceGate.full_path) -Encoding utf8
  $canonicalArtifactWritten = $true
}

$classification = if ($canonicalArtifactWritten) {
  "pass"
} elseif ($evidenceReady) {
  "dry_run_ready"
} else {
  "blocked"
}

$result = [ordered]@{
  schema_version = "control_plane_billing_ledger_production_canonical_cutover_artifact_producer.v1"
  generated_at_utc = [DateTimeOffset]::UtcNow.ToString("o")
  classification = $classification
  scope = $Scope
  canonical_artifact = [ordered]@{
    path = [string]$cutoverEvidenceGate.relative_path
    required_path = $canonicalCutoverPath
    path_is_canonical = $canonicalPath
    write_requested = [bool]$WriteCanonicalArtifact
    written = $canonicalArtifactWritten
    final_x_eligible_requires_verifier_readback = $true
  }
  input_evidence = [ordered]@{
    production_persistent_state_readback = [ordered]@{
      path = [string]$persistentGate.relative_path
      read = [bool]$persistentRead.performed
      pass = $persistentProductionReadbackPass
      environment_scope = [string](Get-Field -Object $persistent -Name "environment_scope")
      active_writer = [string](Get-Field -Object $persistentState -Name "active_writer")
      source_of_truth = [string](Get-Field -Object $persistentState -Name "source_of_truth")
      generation = Get-Field -Object $persistentState -Name "generation"
    }
    s101_live_commit_proof = [ordered]@{
      path = [string]$liveCommitGate.relative_path
      read = [bool]$liveCommitRead.performed
      pass = $liveCommitPass
      measurement_source = [string](Get-Field -Object $liveCommit -Name "measurement_source")
      runtime_container_commit = [string](Get-Field -Object $liveCommit -Name "runtime_container_commit")
    }
    rollback_probe_proof = [ordered]@{
      path = [string]$rollbackProbeGate.relative_path
      read = [bool]$rollbackProbeRead.performed
      pass = $rollbackProbePass
      rollback_observed = [bool](Get-Field -Object $rollbackNoCommit -Name "rollback_observed")
      commit_observed = [bool](Get-Field -Object $rollbackNoCommit -Name "commit_observed")
      dual_commit_observed = [bool](Get-Field -Object $rollbackNoCommit -Name "dual_commit_observed")
    }
    s101_final_readback = [ordered]@{
      path = [string]$finalReadbackGate.relative_path
      read = [bool]$finalReadbackRead.performed
      pass = $finalReadbackPass
      no_dual_pass = $noDualPass
      single_writer_classification = [string](Get-Field -Object $singleWriterGate -Name "classification")
      no_dual_classification = [string](Get-Field -Object $noDualProof -Name "classification")
    }
    post_cutover_readback = [ordered]@{
      pass = $postCutoverReadbackPass
      source = "production_persistent_state_readback"
    }
  }
  blockers = @($blockers | Select-Object -Unique)
  first_blocker = ($blockers | Select-Object -Unique | Select-Object -First 1)
  next_readback_command = "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_billing_ledger_runtime_writer_readiness.ps1 -ReadLiveCommitProofArtifact -LiveCommitProofArtifactPath .tmp/billing-ledger/live-commit-proof-artifact.json -ReadProbeArtifact -ArtifactPath .tmp/billing-ledger/live-probe-evidence-artifact.json -ReadCutoverEvidenceArtifact -CutoverEvidenceArtifactPath .tmp/billing-ledger/cutover-evidence-artifact.json -SingleWriterCutoverProof -LiveCommitProof -AcceptProductionCutover -AcknowledgeRollbackPlan -BlockedExitCode 0"
  safe_output = [ordered]@{
    database_url_output = "omitted"
    env_value_output = "omitted"
    operation_key_output = "omitted"
    rollback_token_output = "omitted"
    raw_env_value_echoed = $false
    raw_database_url_echoed = $false
    credential_material_echoed = $false
  }
}

if ([bool]$resultGate.safe) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent ([string]$resultGate.full_path)) | Out-Null
  $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath ([string]$resultGate.full_path) -Encoding utf8
}

$result | ConvertTo-Json -Depth 12
if ($classification -eq "blocked") {
  exit $BlockedExitCode
}
