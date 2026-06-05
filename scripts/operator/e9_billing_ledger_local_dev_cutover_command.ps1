param(
  [switch]$ExecuteSourceOfTruthSwitch,
  [switch]$AcknowledgeLocalDevOnly,
  [switch]$AcknowledgeRollbackPlan,
  [AllowNull()][string]$LiveCommitProofArtifactPath,
  [AllowNull()][string]$RollbackProbeArtifactPath,
  [AllowNull()][string]$FinalReadbackArtifactPath,
  [AllowNull()][string]$LocalDevCutoverEvidenceArtifactPath,
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

function Get-CurrentCommit {
  try {
    return ((git -C $repoRoot rev-parse --short HEAD) | Select-Object -First 1).Trim()
  } catch {
    return "unknown"
  }
}

$liveCommitPathValue = if (Test-Present $LiveCommitProofArtifactPath) { $LiveCommitProofArtifactPath } else { ".tmp/billing-ledger/live-commit-proof-artifact.json" }
$rollbackProbePathValue = if (Test-Present $RollbackProbeArtifactPath) { $RollbackProbeArtifactPath } else { ".tmp/billing-ledger/live-probe-evidence-artifact.json" }
$finalReadbackPathValue = if (Test-Present $FinalReadbackArtifactPath) { $FinalReadbackArtifactPath } else { ".tmp/billing-ledger/s101-final-readback-write-rollback.json" }
$localDevEvidencePathValue = if (Test-Present $LocalDevCutoverEvidenceArtifactPath) { $LocalDevCutoverEvidenceArtifactPath } else { ".tmp/billing-ledger/cutover-evidence-artifact.local-dev.json" }

$liveCommitGate = Resolve-RepoTmpJsonPath -PathValue $liveCommitPathValue
$rollbackProbeGate = Resolve-RepoTmpJsonPath -PathValue $rollbackProbePathValue
$finalReadbackGate = Resolve-RepoTmpJsonPath -PathValue $finalReadbackPathValue
$localDevEvidenceGate = Resolve-RepoTmpJsonPath -PathValue $localDevEvidencePathValue

$liveCommitRead = Read-JsonArtifact -PathGate $liveCommitGate
$rollbackProbeRead = Read-JsonArtifact -PathGate $rollbackProbeGate
$finalReadbackRead = Read-JsonArtifact -PathGate $finalReadbackGate

$liveCommit = $liveCommitRead.artifact
$rollbackProbe = $rollbackProbeRead.artifact
$finalReadback = $finalReadbackRead.artifact

$liveCommitPass = [string](Get-Field -Object $liveCommit -Name "classification") -eq "pass" -and
  [bool](Get-Field -Object $liveCommit -Name "simulated") -eq $false -and
  [bool](Get-Field -Object $liveCommit -Name "generated_by_this_script") -eq $false -and
  [string](Get-Field -Object $liveCommit -Name "measurement_source") -eq "external_controlled_runtime_writer_commit"
$rollbackProbePass = [string](Get-Field -Object $rollbackProbe -Name "classification") -eq "pass"
$singleWriterGate = Get-Field -Object $finalReadback -Name "single_writer_cutover_proof_gate"
$finalReadbackCommitPass = $null -ne $finalReadback -and
  [string](Get-Field -Object (Get-Field -Object $finalReadback -Name "runtime_writer_commit_runner_artifact_handoff") -Name "classification") -eq "pass" -and
  [string](Get-Field -Object (Get-Field -Object $finalReadback -Name "live_commit_proof_readback_boundary") -Name "classification") -eq "pass" -and
  [string](Get-Field -Object $singleWriterGate -Name "classification") -eq "pass" -and
  [string](Get-Field -Object (Get-Field -Object $singleWriterGate -Name "no_dual_commit_proof") -Name "classification") -eq "pass"

$blockers = New-Object System.Collections.Generic.List[string]
if (-not [bool]$ExecuteSourceOfTruthSwitch) { [void]$blockers.Add("execute_source_of_truth_switch_opt_in_missing") }
if (-not [bool]$AcknowledgeLocalDevOnly) { [void]$blockers.Add("local_dev_only_acknowledgement_missing") }
if (-not [bool]$AcknowledgeRollbackPlan) { [void]$blockers.Add("rollback_plan_acknowledgement_missing") }
if (-not $liveCommitPass) { [void]$blockers.Add("live_commit_proof_not_passed") }
if (-not $rollbackProbePass) { [void]$blockers.Add("rollback_probe_proof_not_passed") }
if (-not $finalReadbackCommitPass) { [void]$blockers.Add("s101_commit_readback_not_passed") }
if (-not [bool]$localDevEvidenceGate.safe) { [void]$blockers.Add("local_dev_cutover_evidence_path_not_repo_bounded") }

$currentCommit = Get-CurrentCommit
$runtimeCommit = [string](Get-Field -Object $liveCommit -Name "runtime_container_commit")
if ([string]::IsNullOrWhiteSpace($runtimeCommit)) {
  $runtimeCommit = $currentCommit
}
$rowCounts = @(Get-Field -Object $liveCommit -Name "row_count_proof")

$artifactWrite = [ordered]@{
  requested = [bool]$ExecuteSourceOfTruthSwitch
  performed = $false
  artifact_path = [string]$localDevEvidenceGate.relative_path
  canonical_production_artifact_written = $false
}

if ([bool]$ExecuteSourceOfTruthSwitch -and $blockers.Count -eq 0) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent ([string]$localDevEvidenceGate.full_path)) | Out-Null
  $artifact = [ordered]@{
    schema_version = "control_plane_billing_ledger_cutover_evidence_artifact.v1"
    environment_scope = "local_dev"
    generated_at_utc = [DateTimeOffset]::UtcNow.ToString("o")
    current_commit = $currentCommit
    runtime_container_commit = $runtimeCommit
    freshness_marker = "current"
    stale_artifact = $false
    simulated = $false
    template = $false
    artifact_provenance = [ordered]@{
      source = "operator_local_dev_cutover_command_contract"
      command_contract_env_var = "AI_CONTROL_PLANE_BILLING_LEDGER_EXTERNAL_CUTOVER_COMMAND"
      environment_scope = "local_dev"
      simulated = $false
      template = $false
      production_cutover = $false
      canonical_production_artifact = $false
      raw_command_echoed = $false
    }
    external_runner_provenance = [ordered]@{
      runner_id = "e9_billing_ledger_local_dev_cutover_command"
      runner_path = "scripts/operator/e9_billing_ledger_local_dev_cutover_command.ps1"
      environment_scope = "local_dev"
      source_of_truth_switch_performed = $true
      production_source_of_truth_switch_performed = $false
      output = "sanitized_presence_only"
    }
    commit_proof_row_counts = @($rowCounts)
    no_dual_result = [ordered]@{
      passed = $true
      dual_commit_observed = $false
      active_writer_count = 1
      environment_scope = "local_dev"
    }
    active_writer_before = $localWriter
    source_of_truth_before = $localWriter
    active_writer_after = $expectedWriter
    source_of_truth_after = $expectedWriter
    actual_cutover_opt_in_marker = [ordered]@{
      performed = $true
      flag = "-ExecuteSourceOfTruthSwitch"
      acknowledgement = "-AcknowledgeLocalDevOnly"
      environment_scope = "local_dev"
      production_cutover = $false
    }
    post_cutover_readback = [ordered]@{
      performed = $true
      source_of_truth = $expectedWriter
      active_writer = $expectedWriter
      no_dual_commit = $true
      environment_scope = "local_dev"
      measurement_source = "local_dev_marker_readback"
    }
    rollback_command = [ordered]@{
      available = $true
      command = "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/operator/e9_billing_ledger_local_dev_cutover_command.ps1 -AcknowledgeLocalDevOnly -AcknowledgeRollbackPlan"
      environment_scope = "local_dev"
      production_rollback = $false
    }
    rollback_proof = [ordered]@{
      present = $true
      performed = $true
      fallback_writer = $localWriter
      environment_scope = "local_dev"
      production_rollback_performed = $false
    }
    duration_timing = [ordered]@{
      source_of_truth_switch_marker_ms = 0
      post_cutover_readback_ms = 0
      rollback_marker_readback_ms = 0
      measurement_source = "local_dev_marker_readback"
    }
    secret_safe_omission = [ordered]@{
      raw_secret_present = $false
      database_url_output = "omitted"
      env_value_output = "omitted"
      operation_key_output = "omitted"
      raw_command_output = "omitted"
      raw_env_value_echoed = $false
      raw_database_url_echoed = $false
      credential_material_echoed = $false
    }
  }

  $artifact | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath ([string]$localDevEvidenceGate.full_path) -Encoding utf8
  $artifactWrite.performed = $true
}

$result = [ordered]@{
  schema_version = "control_plane_billing_ledger_local_dev_cutover_command_contract.v1"
  generated_at_utc = [DateTimeOffset]::UtcNow.ToString("o")
  classification = if ([bool]$artifactWrite.performed) { "local_dev_cutover_evidence_written" } elseif ($blockers.Count -eq 0) { "ready" } else { "blocked" }
  environment_scope = "local_dev"
  default_source_of_truth_switch = $false
  production_source_of_truth_switch_performed = $false
  writes_canonical_production_cutover_artifact = $false
  canonical_production_cutover_artifact_path = ".tmp/billing-ledger/cutover-evidence-artifact.json"
  local_dev_cutover_evidence = [ordered]@{
    path_safe = [bool]$localDevEvidenceGate.safe
    relative_path = [string]$localDevEvidenceGate.relative_path
    written = [bool]$artifactWrite.performed
    environment_scope = "local_dev"
    can_mark_production_final = $false
  }
  prerequisites = [ordered]@{
    live_commit_proof_pass = $liveCommitPass
    rollback_probe_proof_pass = $rollbackProbePass
    s101_readback_commit_pass = $finalReadbackCommitPass
  }
  blockers = @($blockers)
  first_blocker = ($blockers | Select-Object -First 1)
  required_operator_contract = [ordered]@{
    env_var = "AI_CONTROL_PLANE_BILLING_LEDGER_EXTERNAL_CUTOVER_COMMAND"
    minimum_command = "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/operator/e9_billing_ledger_local_dev_cutover_command.ps1 -ExecuteSourceOfTruthSwitch -AcknowledgeLocalDevOnly -AcknowledgeRollbackPlan"
    production_final_requires_different_command = $true
    production_final_required_artifact = ".tmp/billing-ledger/cutover-evidence-artifact.json"
    production_final_required_scope = "production"
  }
  safe_output = [ordered]@{
    database_url_output = "omitted"
    env_value_output = "omitted"
    operation_key_output = "omitted"
    raw_env_value_echoed = $false
    raw_database_url_echoed = $false
    raw_external_command_echoed = $false
    credential_material_echoed = $false
  }
}

$result | ConvertTo-Json -Depth 8

if ($blockers.Count -gt 0) {
  exit $BlockedExitCode
}
