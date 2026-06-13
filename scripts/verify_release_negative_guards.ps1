param(
  [string]$TempRoot = ".tmp\release-negative-guards"
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Invoke-JsonCommand {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string[]]$Arguments = @()
  )

  $global:LASTEXITCODE = 0
  $extension = [System.IO.Path]::GetExtension($FilePath)
  if ($extension -ieq ".ps1") {
    $ps = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $ps) {
      $ps = Get-Command powershell -ErrorAction SilentlyContinue
    }
    if (-not $ps) {
      throw "PowerShell executable was not found."
    }
    $psArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $FilePath) + @($Arguments)
    $output = @(& $ps.Source @psArgs 2>&1)
  } else {
    $output = @(& $FilePath @Arguments 2>&1)
  }
  $exitCode = if ($null -eq $global:LASTEXITCODE) { 0 } else { [int]$global:LASTEXITCODE }
  if ($exitCode -ne 0) {
    throw ("command failed ({0}): {1}" -f $exitCode, (($output | Select-Object -Last 12) -join "`n"))
  }
  return (($output -join "`n") | ConvertFrom-Json -ErrorAction Stop)
}

function Assert-True {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Message
  )
  if (-not $Condition) {
    throw $Message
  }
}

function Get-CurrentCommit {
  try {
    return ((git -C $repoRoot rev-parse HEAD) | Select-Object -First 1).Trim()
  } catch {
    return "unknown"
  }
}

function Resolve-RepoTmpPath {
  param([Parameter(Mandatory = $true)][string]$RelativePath)

  $full = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $RelativePath))
  $root = [System.IO.Path]::GetFullPath($repoRoot)
  $relative = [System.IO.Path]::GetRelativePath($root, $full).Replace("\", "/")
  if ($relative.StartsWith("../") -or [System.IO.Path]::IsPathRooted($relative) -or -not $relative.StartsWith(".tmp/")) {
    throw "TempRoot must stay under repo .tmp."
  }
  return $full
}

$tempRootFull = Resolve-RepoTmpPath -RelativePath $TempRoot
New-Item -ItemType Directory -Force -Path $tempRootFull | Out-Null

$currentCommit = Get-CurrentCommit

$e8Artifact = ".tmp/gateway_tpm_production_backend/release-negative-guards-e8-local-prototype.json"
$e8Run = Invoke-JsonCommand `
  -FilePath (Join-Path $PSScriptRoot "run_gateway_tpm_production_backend_evidence.ps1") `
  -Arguments @(
    "-RunLocalPrototype",
    "-DryRun",
    "-ArtifactPath", $e8Artifact,
    "-ExpectedCommit", $currentCommit,
    "-BackendKind", "read_model_backend",
    "-TokenSourceKind", "input_tokens"
  )
Assert-True ([bool]$e8Run.local_prototype -eq $true) "E8 local prototype runner did not mark local_prototype=true."
Assert-True ([bool]$e8Run.real_operator_evidence -eq $false) "E8 local prototype runner marked real_operator_evidence=true."
Assert-True ([bool]$e8Run.local_prototype_artifact_written -eq $false) "E8 local prototype dry-run wrote an artifact."

$e8Readback = Invoke-JsonCommand `
  -FilePath (Join-Path $PSScriptRoot "verify_gateway_tpm_production_backend_evidence.ps1") `
  -Arguments @(
    "-OptInArtifactReadback",
    "-ArtifactPath", "tests/fixtures/gateway/production_backend_runner_artifact_repo_fixture_only.json",
    "-ExpectedCommit", "commit-current",
    "-BackendKind", "read_model_backend",
    "-TokenSourceKind", "input_tokens"
  )
Assert-True ([string]$e8Readback.status -eq "production_ready_blocked") "E8 repo fixture readback was not blocked."
Assert-True ([bool]$e8Readback.closure_audit.final_x_eligible -eq $false) "E8 repo fixture readback became final-x eligible."
Assert-True ([string]$e8Readback.blocker -eq "repo_fixture_only") "E8 repo fixture top-level blocker missing."
Assert-True (@($e8Readback.closure_audit.blocking_reasons | Where-Object { [string]$_ -eq "repo_fixture_only" }).Count -eq 1) "E8 repo fixture blocker missing."

$e9ArtifactRel = (Join-Path $TempRoot "e9-local-dev-cutover.json")
$e9ArtifactFull = Resolve-RepoTmpPath -RelativePath $e9ArtifactRel
$e9Artifact = [ordered]@{
  schema_version = "control_plane_billing_ledger_cutover_evidence_artifact.v1"
  environment_scope = "local_dev"
  current_commit = $currentCommit
  runtime_container_commit = $currentCommit
  freshness_marker = "current"
  stale_artifact = $false
  simulated = $false
  template = $false
  artifact_provenance = [ordered]@{
    source = "release_negative_guard_local_dev_fixture"
    environment_scope = "local_dev"
    simulated = $false
    template = $false
    production_cutover = $false
  }
  external_runner_provenance = [ordered]@{
    runner_id = "release_negative_guard"
    environment_scope = "local_dev"
    source_of_truth_switch_performed = $true
    production_source_of_truth_switch_performed = $false
  }
  commit_proof_row_counts = @([ordered]@{ operation = "negative_guard"; rows_match = $true })
  no_dual_result = [ordered]@{ passed = $true; dual_commit_observed = $false }
  active_writer_before = "control_plane_local_sql_writer"
  source_of_truth_before = "control_plane_local_sql_writer"
  active_writer_after = "billing_ledger_runtime_writer"
  source_of_truth_after = "billing_ledger_runtime_writer"
  actual_cutover_opt_in_marker = [ordered]@{ performed = $true; environment_scope = "local_dev"; production_cutover = $false }
  post_cutover_readback = [ordered]@{ performed = $true; source_of_truth = "billing_ledger_runtime_writer"; active_writer = "billing_ledger_runtime_writer"; no_dual_commit = $true; environment_scope = "local_dev" }
  rollback_command = [ordered]@{ available = $true; environment_scope = "local_dev"; production_rollback = $false }
  rollback_proof = [ordered]@{ present = $true; performed = $true; environment_scope = "local_dev"; production_rollback_performed = $false }
  duration_timing = [ordered]@{ duration_ms = 1 }
  secret_safe_omission = [ordered]@{ raw_secret_present = $false; database_url_output = "omitted"; env_value_output = "omitted"; raw_command_output = "omitted" }
}
$e9Artifact | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $e9ArtifactFull -Encoding UTF8

$e9Readback = Invoke-JsonCommand `
  -FilePath (Join-Path $PSScriptRoot "verify_control_plane_billing_ledger_runtime_writer_readiness.ps1") `
  -Arguments @(
    "-ReadCutoverEvidenceArtifact",
    "-CutoverEvidenceArtifactPath", $e9ArtifactRel,
    "-BlockedExitCode", "0"
  )
Assert-True ([bool]$e9Readback.cutover_evidence_acceptance_matrix.final_x_eligible -eq $false) "E9 local-dev cutover artifact became final-x eligible."
Assert-True ([string]$e9Readback.cutover_evidence_acceptance_matrix.evidence.environment_scope -eq "local_dev") "E9 local-dev cutover scope was not read back."
Assert-True (@($e9Readback.cutover_final_closure_audit.blocking_reasons | Where-Object { [string]$_ -eq "local_dev_cutover_artifact_not_production_final" }).Count -eq 1) "E9 local-dev cutover blocker missing."

$worker = Join-Path $repoRoot "target\debug\ai-worker.exe"
if (Test-Path -LiteralPath $worker) {
  $e15Readback = Invoke-JsonCommand `
    -FilePath $worker `
    -Arguments @(
      "clickhouse-log-store",
      "--final-closure-audit",
      "--read-production-smoke-artifact", "tests/fixtures/worker/clickhouse_production_smoke_artifact_accepted_simulation.json",
      "--input", "tests/fixtures/worker/clickhouse_log_store_plan_contract.json"
    )
  Assert-True ([bool]$e15Readback.final_closure_audit.final_x_eligible -eq $false) "E15 simulation fixture became final-x eligible."
  Assert-True ([bool]$e15Readback.production_smoke_acceptance.production_smoke_passed -eq $false) "E15 simulation fixture became production_smoke_passed."
  Assert-True (@($e15Readback.final_closure_audit.blocking_reasons | Where-Object { [string]$_ -eq "simulated_artifact" }).Count -eq 1) "E15 simulated_artifact blocker missing."
} else {
  $global:LASTEXITCODE = 0
  cargo test -p ai-worker final_closure_audit_keeps_simulation_blocked
  if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
  }
}

Write-Host "Release negative guards passed: E8 local prototype, E9 local-dev cutover, E15 simulation fixture remain non-final."
