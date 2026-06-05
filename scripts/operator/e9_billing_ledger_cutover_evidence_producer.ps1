param(
  [switch]$ExecuteProductionCutover,
  [switch]$AcknowledgeRollbackPlan,
  [AllowNull()][string]$LiveCommitProofArtifactPath,
  [AllowNull()][string]$RollbackProbeArtifactPath,
  [AllowNull()][string]$FinalReadbackArtifactPath,
  [AllowNull()][string]$CutoverEvidenceArtifactPath,
  [AllowNull()][string]$ExternalCutoverCommand,
  [int]$BlockedExitCode = 2
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$expectedWriter = "billing_ledger_runtime_writer"

function Test-Present {
  param([AllowNull()][string]$Value)
  return -not [string]::IsNullOrWhiteSpace($Value)
}

function Test-TruthyEnv {
  param([AllowNull()][string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  return $Value.Trim().ToLowerInvariant() -in @("1", "true", "yes", "ready", "accepted", "enabled")
}

function Resolve-RepoTmpJsonPath {
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
  param(
    [Parameter(Mandatory = $true)]$PathGate
  )

  if (-not [bool]$PathGate.safe) {
    return [ordered]@{
      performed = $false
      classification = "blocker"
      reason = "unsafe_path"
      artifact = $null
    }
  }
  if (-not (Test-Path -LiteralPath ([string]$PathGate.full_path))) {
    return [ordered]@{
      performed = $false
      classification = "blocker"
      reason = "artifact_missing"
      artifact = $null
    }
  }
  try {
    return [ordered]@{
      performed = $true
      classification = "read"
      reason = "artifact_read"
      artifact = Get-Content -LiteralPath ([string]$PathGate.full_path) -Raw | ConvertFrom-Json -ErrorAction Stop
    }
  } catch {
    return [ordered]@{
      performed = $false
      classification = "fail"
      reason = "artifact_json_parse_failed"
      artifact = $null
    }
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

$liveCommitPathValue = if (Test-Present $LiveCommitProofArtifactPath) { $LiveCommitProofArtifactPath } else { ".tmp/billing-ledger/live-commit-proof-artifact.json" }
$rollbackProbePathValue = if (Test-Present $RollbackProbeArtifactPath) { $RollbackProbeArtifactPath } else { ".tmp/billing-ledger/live-probe-evidence-artifact.json" }
$finalReadbackPathValue = if (Test-Present $FinalReadbackArtifactPath) { $FinalReadbackArtifactPath } else { ".tmp/billing-ledger/s101-final-readback-write-rollback.json" }
$cutoverEvidencePathValue = if (Test-Present $CutoverEvidenceArtifactPath) { $CutoverEvidenceArtifactPath } else { ".tmp/billing-ledger/cutover-evidence-artifact.json" }
$externalCommandValue = if (Test-Present $ExternalCutoverCommand) { $ExternalCutoverCommand } else { [Environment]::GetEnvironmentVariable("AI_CONTROL_PLANE_BILLING_LEDGER_EXTERNAL_CUTOVER_COMMAND") }

$executeCutover = [bool]$ExecuteProductionCutover -or (Test-TruthyEnv ([Environment]::GetEnvironmentVariable("AI_CONTROL_PLANE_BILLING_LEDGER_EXECUTE_PRODUCTION_CUTOVER")))
$rollbackAcknowledged = [bool]$AcknowledgeRollbackPlan -or (Test-TruthyEnv ([Environment]::GetEnvironmentVariable("AI_CONTROL_PLANE_BILLING_LEDGER_ROLLBACK_PLAN_ACKNOWLEDGED")))

$liveCommitGate = Resolve-RepoTmpJsonPath -PathValue $liveCommitPathValue
$rollbackProbeGate = Resolve-RepoTmpJsonPath -PathValue $rollbackProbePathValue
$finalReadbackGate = Resolve-RepoTmpJsonPath -PathValue $finalReadbackPathValue
$cutoverEvidenceGate = Resolve-RepoTmpJsonPath -PathValue $cutoverEvidencePathValue

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
$finalReadbackCommitPass = $null -ne $finalReadback -and
  [string](Get-Field -Object (Get-Field -Object $finalReadback -Name "runtime_writer_commit_runner_artifact_handoff") -Name "classification") -eq "pass" -and
  [string](Get-Field -Object (Get-Field -Object $finalReadback -Name "live_commit_proof_readback_boundary") -Name "classification") -eq "pass" -and
  [string](Get-Field -Object (Get-Field -Object $finalReadback -Name "single_writer_cutover_proof_gate") -Name "classification") -eq "pass" -and
  [string](Get-Field -Object (Get-Field -Object (Get-Field -Object $finalReadback -Name "single_writer_cutover_proof_gate") -Name "no_dual_commit_proof") -Name "classification") -eq "pass"

$blockers = New-Object System.Collections.Generic.List[string]
if (-not $executeCutover) { [void]$blockers.Add("execute_production_cutover_opt_in_missing") }
if (-not $rollbackAcknowledged) { [void]$blockers.Add("rollback_plan_acknowledgement_missing") }
if (-not $liveCommitPass) { [void]$blockers.Add("live_commit_proof_not_passed") }
if (-not $rollbackProbePass) { [void]$blockers.Add("rollback_probe_proof_not_passed") }
if (-not $finalReadbackCommitPass) { [void]$blockers.Add("s101_commit_readback_not_passed") }
if (-not (Test-Present $externalCommandValue)) { [void]$blockers.Add("external_cutover_command_missing") }
if (-not [bool]$cutoverEvidenceGate.safe) { [void]$blockers.Add("cutover_evidence_path_not_repo_bounded") }

$externalRunner = [ordered]@{
  requested = $executeCutover
  executed = $false
  classification = if ($executeCutover) { "blocked_before_execution" } else { "not_requested" }
  exit_code = "not_run"
  reason = if ($blockers.Count -gt 0) { ($blockers | Select-Object -First 1) } else { "ready" }
  raw_command_echoed = $false
  stdout_output = "omitted"
  stderr_output = "omitted"
}

if ($executeCutover -and $blockers.Count -eq 0) {
  $logDir = Join-Path $repoRoot ".tmp\billing-ledger"
  New-Item -ItemType Directory -Force -Path $logDir | Out-Null
  $stdoutPath = Join-Path $logDir "cutover-producer.stdout.omitted"
  $stderrPath = Join-Path $logDir "cutover-producer.stderr.omitted"
  try {
    $process = Start-Process -FilePath "pwsh" `
      -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $externalCommandValue) `
      -WorkingDirectory $repoRoot `
      -Wait `
      -PassThru `
      -WindowStyle Hidden `
      -RedirectStandardOutput $stdoutPath `
      -RedirectStandardError $stderrPath
    $externalRunner.executed = $true
    $externalRunner.exit_code = [int]$process.ExitCode
    $externalRunner.classification = if ([int]$process.ExitCode -eq 0) { "external_cutover_command_executed" } else { "external_cutover_command_failed" }
    $externalRunner.reason = if ([int]$process.ExitCode -eq 0) { "cutover_artifact_readback_required" } else { "external_cutover_command_exit_nonzero" }
  } finally {
    Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
  }
}

$cutoverEvidenceExists = [bool]$cutoverEvidenceGate.safe -and (Test-Path -LiteralPath ([string]$cutoverEvidenceGate.full_path))

$result = [ordered]@{
  schema_version = "control_plane_billing_ledger_cutover_evidence_producer_boundary.v1"
  generated_at_utc = [DateTimeOffset]::UtcNow.ToString("o")
  classification = if ($blockers.Count -eq 0 -and [bool]$externalRunner.executed) { "external_cutover_attempted" } elseif ($blockers.Count -eq 0) { "ready" } else { "blocked" }
  default_cutover = $false
  script_generates_accepted_cutover_evidence = $false
  script_performs_cutover_without_external_command = $false
  live_commit_proof = [ordered]@{
    read = [bool]$liveCommitRead.performed
    classification = [string](Get-Field -Object $liveCommit -Name "classification")
    pass = $liveCommitPass
    artifact_path = [string]$liveCommitGate.relative_path
  }
  rollback_probe_proof = [ordered]@{
    read = [bool]$rollbackProbeRead.performed
    classification = [string](Get-Field -Object $rollbackProbe -Name "classification")
    pass = $rollbackProbePass
    artifact_path = [string]$rollbackProbeGate.relative_path
  }
  s101_readback = [ordered]@{
    read = [bool]$finalReadbackRead.performed
    commit_handoff = [string](Get-Field -Object (Get-Field -Object $finalReadback -Name "runtime_writer_commit_runner_artifact_handoff") -Name "classification")
    live_commit_readback = [string](Get-Field -Object (Get-Field -Object $finalReadback -Name "live_commit_proof_readback_boundary") -Name "classification")
    single_writer = [string](Get-Field -Object (Get-Field -Object $finalReadback -Name "single_writer_cutover_proof_gate") -Name "classification")
    no_dual = [string](Get-Field -Object (Get-Field -Object (Get-Field -Object $finalReadback -Name "single_writer_cutover_proof_gate") -Name "no_dual_commit_proof") -Name "classification")
    final_x_eligible = [bool](Get-Field -Object (Get-Field -Object $finalReadback -Name "cutover_final_closure_audit") -Name "final_x_eligible")
    artifact_path = [string]$finalReadbackGate.relative_path
  }
  cutover_evidence_artifact = [ordered]@{
    path_safe = [bool]$cutoverEvidenceGate.safe
    exists = $cutoverEvidenceExists
    relative_path = [string]$cutoverEvidenceGate.relative_path
    accepted_artifact_generated_by_this_script = $false
  }
  external_cutover_command = [ordered]@{
    env_var = "AI_CONTROL_PLANE_BILLING_LEDGER_EXTERNAL_CUTOVER_COMMAND"
    present = (Test-Present $externalCommandValue)
    value_output = "omitted"
    raw_command_echoed = $false
  }
  blockers = @($blockers)
  first_blocker = ($blockers | Select-Object -First 1)
  external_runner = $externalRunner
  expected_external_command_contract = [ordered]@{
    must_perform_actual_source_of_truth_switch = $true
    must_write_artifact = ".tmp/billing-ledger/cutover-evidence-artifact.json"
    artifact_schema_version = "control_plane_billing_ledger_cutover_evidence_artifact.v1"
    required_after_state = [ordered]@{
      active_writer_after = $expectedWriter
      source_of_truth_after = $expectedWriter
      post_cutover_readback_source_of_truth = $expectedWriter
      post_cutover_readback_active_writer = $expectedWriter
      no_dual_commit = $true
      rollback_proof_present = $true
    }
  }
  next_readback_command = "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_billing_ledger_runtime_writer_readiness.ps1 -ReadLiveCommitProofArtifact -LiveCommitProofArtifactPath .tmp/billing-ledger/live-commit-proof-artifact.json -ReadProbeArtifact -ArtifactPath .tmp/billing-ledger/live-probe-evidence-artifact.json -ReadCutoverEvidenceArtifact -CutoverEvidenceArtifactPath .tmp/billing-ledger/cutover-evidence-artifact.json -SingleWriterCutoverProof -LiveCommitProof -AcceptProductionCutover -AcknowledgeRollbackPlan -BlockedExitCode 0"
  safe_output = [ordered]@{
    database_url_output = "omitted"
    env_value_output = "omitted"
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
