param(
  [Alias("PaidReadinessGatePath")]
  [string]$E9ReadinessPath = ".tmp\paid-beta\e9_paid_readiness_gate.json",
  [string]$GatewayPaidHotPathArtifactPath = ".tmp\paid-beta\e8_gateway_paid_hot_path.json",
  [string]$ControlPlanePaidReadbackArtifactPath = ".tmp\paid-beta\e11_control_plane_paid_readback_reconciliation.json",
  [Alias("PaidEvidenceBundlePath")]
  [string]$RealPaidEvidenceBundlePath = ".tmp\paid-beta\real_paid_evidence_bundle.json",
  [string]$OutputPath = "",
  [switch]$SkipSecretScan,
  [switch]$TestMode,
  [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$defaultExitCodes = [ordered]@{
  pass = 0
  tool_failure = 1
  unsafe_path_refused = 1
  blocked = 2
}
$requiredEvidence = @(
  "gateway_hot_path_reserve_settle_refund",
  "insufficient_balance_prevents_provider_call",
  "control_plane_paid_readback_reconciliation",
  "real_paid_evidence_bundle_accepted",
  "release_gate_paid_allowed"
)

function Resolve-RepoPath {
  param([Parameter(Mandatory = $true)][string]$Path)

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Get-RepoRelativePath {
  param([Parameter(Mandatory = $true)][string]$Path)

  $full = [System.IO.Path]::GetFullPath($Path)
  $prefix = $repoRoot.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
  if ($full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    return ($full.Substring($prefix.Length) -replace "\\", "/")
  }
  return ($full -replace "\\", "/")
}

function Test-RepoBoundedEvidencePath {
  param([Parameter(Mandatory = $true)][string]$Path)

  $full = Resolve-RepoPath $Path
  $relative = Get-RepoRelativePath $full
  $normalized = $relative -replace "\\", "/"
  $withinRepo = -not [System.IO.Path]::IsPathRooted($normalized)
  $allowedPrefix = $normalized.StartsWith(".tmp/", [System.StringComparison]::OrdinalIgnoreCase) -or
    $normalized.StartsWith("artifacts/", [System.StringComparison]::OrdinalIgnoreCase)

  return [ordered]@{
    requested_path = $Path
    resolved_path = $full
    path = $normalized
    bounded = [bool]($withinRepo -and $allowedPrefix)
  }
}

function Get-JsonBool {
  param(
    [AllowNull()][object]$Json,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if ($null -eq $Json) { return $null }
  if ($Json.PSObject.Properties.Name -notcontains $Name) { return $null }
  $value = $Json.PSObject.Properties[$Name].Value
  if ($value -is [bool]) { return [bool]$value }
  if ($null -eq $value) { return $null }
  $text = ([string]$value).Trim().ToLowerInvariant()
  if (@("true", "yes", "1", "pass", "passed", "accepted", "allowed", "ready") -contains $text) { return $true }
  if (@("false", "no", "0", "fail", "failed", "blocked", "refused") -contains $text) { return $false }
  return $null
}

function Test-TruthyField {
  param(
    [AllowNull()][object]$Json,
    [string[]]$Names
  )

  foreach ($name in $Names) {
    $value = Get-JsonBool -Json $Json -Name $name
    if ($true -eq $value) { return $true }
  }

  return $false
}

function Test-DenyFlag {
  param([AllowNull()][object]$Json)

  foreach ($name in @("synthetic", "simulated", "simulation", "contract_only", "dry_run", "fixture_loaded", "test_mode", "synthetic_selftest")) {
    $value = Get-JsonBool -Json $Json -Name $name
    if ($true -eq $value) { return $true }
  }

  return $false
}

function Test-RealProvenance {
  param([AllowNull()][object]$Json)

  if ($null -eq $Json) { return $false }
  if (Test-DenyFlag -Json $Json) { return $false }

  if (Test-TruthyField -Json $Json -Names @(
      "non_synthetic",
      "real_provenance",
      "runtime_current_verified",
      "artifact_readback_passed",
      "live_requests_sent",
      "provider_attempts_zero",
      "provenance_verified",
      "paid_controlled_beta_allowed",
      "real_paid_evidence_bundle_accepted"
    )) {
    return $true
  }

  if ($Json.PSObject.Properties.Name -contains "provenance") {
    $provenance = $Json.PSObject.Properties["provenance"].Value
    if (Test-TruthyField -Json $provenance -Names @("pass", "passed", "verified", "runtime_current_verified", "non_synthetic")) {
      return $true
    }
  }

  return $false
}

function Test-AcceptedShape {
  param([AllowNull()][object]$Json)

  return (Test-TruthyField -Json $Json -Names @(
      "passed",
      "pass",
      "accepted",
      "accepted_contract_shape",
      "accepted_shape",
      "paid_controlled_beta_allowed",
      "gateway_paid_hot_path_passed",
      "control_plane_paid_readback_passed",
      "reconciliation_passed",
      "real_paid_evidence_bundle_accepted"
    )) -or
    (Test-TruthyField -Json $Json -Names @("status", "overall_status", "classification"))
}

function Test-TestModeFixturePass {
  param(
    [AllowNull()][object]$Json,
    [Parameter(Mandatory = $true)][string]$Path
  )

  $isReleaseArtifact = ($Path -replace "\\", "/").StartsWith("artifacts/", [System.StringComparison]::OrdinalIgnoreCase)
  if ($isReleaseArtifact) { return $false }
  if (-not (Test-AcceptedShape -Json $Json)) { return $false }
  if (Test-TruthyField -Json $Json -Names @("synthetic", "simulated", "simulation")) { return $false }
  return $true
}

function Test-ArtifactPass {
  param(
    [AllowNull()][object]$Json,
    [Parameter(Mandatory = $true)][string]$Path,
    [bool]$AllowTestFixture
  )

  if ($AllowTestFixture -and (Test-TestModeFixturePass -Json $Json -Path $Path)) {
    return [ordered]@{ passed = $true; reason = "accepted_test_mode_fixture" }
  }

  return Test-ArtifactReleasePass -Json $Json -Path $Path
}

function Get-JsonFieldValue {
  param(
    [AllowNull()][object]$Json,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if ($null -eq $Json) { return $null }
  if ($Json.PSObject.Properties.Name -notcontains $Name) { return $null }
  return $Json.PSObject.Properties[$Name].Value
}

function Get-StringFieldValue {
  param(
    [AllowNull()][object]$Json,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $value = Get-JsonFieldValue -Json $Json -Name $Name
  if ($null -eq $value) { return $null }
  $text = ([string]$value).Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  return $text
}

function Get-ExitCodeFieldValue {
  param([AllowNull()][object]$Json)

  $direct = Get-JsonFieldValue -Json $Json -Name "actual_exit_code"
  if ($null -ne $direct -and ([string]$direct).Trim() -match "^-?\d+$") {
    return [int]$direct
  }

  $contract = Get-JsonFieldValue -Json $Json -Name "exit_code_contract"
  if ($null -ne $contract) {
    $nested = Get-JsonFieldValue -Json $contract -Name "actual_exit_code"
    if ($null -ne $nested -and ([string]$nested).Trim() -match "^-?\d+$") {
      return [int]$nested
    }
  }

  return $null
}

function Get-StringListFieldValue {
  param(
    [AllowNull()][object]$Json,
    [Parameter(Mandatory = $true)][string[]]$Names
  )

  $items = New-Object System.Collections.Generic.List[string]
  foreach ($name in $Names) {
    $value = Get-JsonFieldValue -Json $Json -Name $name
    if ($null -eq $value) { continue }

    if ($value -is [string]) {
      if (-not [string]::IsNullOrWhiteSpace($value)) {
        [void]$items.Add($value.Trim())
      }
      continue
    }

    foreach ($entry in @($value)) {
      if ($null -eq $entry) { continue }
      $text = ([string]$entry).Trim()
      if (-not [string]::IsNullOrWhiteSpace($text)) {
        [void]$items.Add($text)
      }
    }
  }

  $unique = New-Object System.Collections.Generic.List[string]
  foreach ($item in @($items.ToArray())) {
    if (-not $unique.Contains($item)) {
      [void]$unique.Add($item)
    }
  }

  return @($unique.ToArray())
}

function Test-HasBlockingArtifactFields {
  param([AllowNull()][object]$Json)

  if ($null -eq $Json) { return $false }
  foreach ($name in @("blockers", "refusal_reasons", "missing_evidence", "invalid_evidence")) {
    $value = Get-JsonFieldValue -Json $Json -Name $name
    foreach ($entry in @($value)) {
      if ($null -ne $entry -and -not [string]::IsNullOrWhiteSpace([string]$entry)) {
        return $true
      }
    }
  }
  return $false
}

function Test-ArtifactSecretSafe {
  param([AllowNull()][object]$Json)

  $secretSafe = Get-JsonFieldValue -Json $Json -Name "secret_safe"
  if ($null -eq $secretSafe) { return $true }

  foreach ($name in @(
      "raw_secret_present",
      "credential_material_echoed",
      "database_url_echoed",
      "provider_key_echoed",
      "virtual_key_echoed",
      "raw_secret_echoed",
      "raw_or_secret_marker_present"
    )) {
    $value = Get-JsonBool -Json $secretSafe -Name $name
    if ($true -eq $value) { return $false }
  }

  $safe = Get-JsonBool -Json $secretSafe -Name "secret_safe"
  if ($false -eq $safe) { return $false }
  return $true
}

function Test-ActualExitCodeAccepted {
  param([AllowNull()][object]$Json)

  $exitCode = Get-ExitCodeFieldValue -Json $Json
  return ($null -eq $exitCode -or [int]$exitCode -eq 0)
}

function Get-ObjectArrayField {
  param(
    [AllowNull()][object]$Json,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $value = Get-JsonFieldValue -Json $Json -Name $Name
  if ($null -eq $value) { return @() }
  if ($value -is [System.Array]) { return @($value) }
  return @(,$value)
}

function Test-GatewayConsumerShape {
  param([AllowNull()][object]$Json)

  $requestIds = New-Object System.Collections.Generic.List[string]
  $trace = Get-JsonFieldValue -Json $Json -Name "request_trace"
  foreach ($id in @(Get-JsonFieldValue -Json $trace -Name "request_ids")) {
    if ($null -ne $id -and -not [string]::IsNullOrWhiteSpace([string]$id)) {
      [void]$requestIds.Add([string]$id)
    }
  }

  $operationIds = New-Object System.Collections.Generic.List[string]
  foreach ($entry in (Get-ObjectArrayField -Json $Json -Name "evidence")) {
    foreach ($name in @("operation_id", "reserve_operation_id", "settle_operation_id", "release_operation_id", "refund_operation_id", "related_ledger_entry_id")) {
      $id = Get-JsonFieldValue -Json $entry -Name $name
      if ($null -ne $id -and -not [string]::IsNullOrWhiteSpace([string]$id)) {
        [void]$operationIds.Add([string]$id)
      }
    }
  }

  return ($requestIds.Count -gt 0 -and $operationIds.Count -gt 0)
}

function Test-ControlPlaneReadbackConsumerShape {
  param([AllowNull()][object]$Json)

  $gatewayArtifact = Get-JsonFieldValue -Json $Json -Name "gateway_artifact"
  $requestIdsPresent = Get-JsonBool -Json $gatewayArtifact -Name "request_ids_present"
  $operationIdsPresent = Get-JsonBool -Json $gatewayArtifact -Name "operation_ids_present"
  if ($false -eq $requestIdsPresent -or $false -eq $operationIdsPresent) { return $false }

  $acceptedEvidence = Get-JsonFieldValue -Json $Json -Name "accepted_evidence"
  return (@($acceptedEvidence).Count -gt 0)
}

function Test-BundleProductionReady {
  param([AllowNull()][object]$Json)

  return (Test-TruthyField -Json $Json -Names @("real_paid_evidence_bundle_accepted", "paid_controlled_beta_production_ready", "real_provenance", "non_synthetic")) -and
    -not (Test-TruthyField -Json $Json -Names @("contract_shape_only", "synthetic_selftest"))
}

function Test-ArtifactReleasePass {
  param(
    [AllowNull()][object]$Json,
    [Parameter(Mandatory = $true)][string]$Path
  )

  if (-not (Test-AcceptedShape -Json $Json)) {
    return [ordered]@{ passed = $false; reason = "not_accepted_shape" }
  }
  if (Test-HasBlockingArtifactFields -Json $Json) {
    return [ordered]@{ passed = $false; reason = "artifact_reports_blockers" }
  }
  if (Test-DenyFlag -Json $Json) {
    return [ordered]@{ passed = $false; reason = "synthetic_fixture_or_dry_run_artifact" }
  }
  if (-not (Test-ActualExitCodeAccepted -Json $Json)) {
    return [ordered]@{ passed = $false; reason = "artifact_actual_exit_code_nonzero" }
  }
  if (-not (Test-ArtifactSecretSafe -Json $Json)) {
    return [ordered]@{ passed = $false; reason = "artifact_secret_safety_failed" }
  }

  $schema = Get-StringFieldValue -Json $Json -Name "schema"
  if ($null -eq $schema) { $schema = Get-StringFieldValue -Json $Json -Name "schema_version" }
  $normalizedPath = $Path -replace "\\", "/"

  if ($schema -eq "gateway_paid_hot_path_smoke_v1" -or $normalizedPath -like "*e8_gateway_paid_hot_path.json") {
    if (-not (Test-GatewayConsumerShape -Json $Json)) {
      return [ordered]@{ passed = $false; reason = "gateway_paid_hot_path_consumer_shape_missing" }
    }
    return [ordered]@{ passed = $true; reason = "accepted_real_provenance" }
  }

  if ($schema -eq "control_plane_paid_ledger_readback_verification.v1" -or $normalizedPath -like "*e11_control_plane_paid_readback_reconciliation.json") {
    if (-not (Test-ControlPlaneReadbackConsumerShape -Json $Json)) {
      return [ordered]@{ passed = $false; reason = "control_plane_paid_readback_consumer_shape_missing" }
    }
    return [ordered]@{ passed = $true; reason = "accepted_real_provenance" }
  }

  if ($schema -eq "billing_paid_strong_consistency_evidence_bundle.v1" -or $normalizedPath -like "*real_paid_evidence_bundle.json") {
    if (-not (Test-BundleProductionReady -Json $Json)) {
      return [ordered]@{ passed = $false; reason = "real_paid_bundle_not_production_ready" }
    }
    return [ordered]@{ passed = $true; reason = "accepted_real_provenance" }
  }

  if (Test-RealProvenance -Json $Json) {
    return [ordered]@{ passed = $true; reason = "accepted_real_provenance" }
  }

  return [ordered]@{ passed = $false; reason = "missing_real_provenance_or_release_mode_blocks_fixture" }
}

function Get-ArtifactBlockedSummary {
  param(
    [AllowNull()][object]$Json,
    [Parameter(Mandatory = $true)][string]$FallbackReason
  )

  $status = Get-StringFieldValue -Json $Json -Name "overall_status"
  if ($null -eq $status) { $status = Get-StringFieldValue -Json $Json -Name "classification" }
  if ($null -eq $status) { $status = Get-StringFieldValue -Json $Json -Name "status" }

  $decision = Get-StringFieldValue -Json $Json -Name "decision"
  $actualExitCode = Get-ExitCodeFieldValue -Json $Json
  $blockers = Get-StringListFieldValue -Json $Json -Names @("blockers", "refusal_reasons", "missing_evidence", "invalid_evidence")

  $summary = [ordered]@{
    reason = if ($null -ne $status) { "artifact_reported_$status" } else { $FallbackReason }
    artifact_overall_status = $status
    artifact_actual_exit_code = $actualExitCode
    artifact_decision = $decision
    artifact_blockers = @($blockers)
  }

  return $summary
}

function Read-JsonIfPresent {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Id
  )

  $scope = Test-RepoBoundedEvidencePath -Path $Path
  if (-not [bool]$scope.bounded) {
    return [ordered]@{
      id = $Id
      exists = $false
      path = $scope.path
      json = $null
      parse_error = "unsafe_path_refused"
      bounded = $false
    }
  }

  if (-not (Test-Path -LiteralPath $scope.resolved_path -PathType Leaf)) {
    return [ordered]@{
      id = $Id
      exists = $false
      path = $scope.path
      json = $null
      parse_error = "missing"
      bounded = $true
    }
  }

  try {
    $json = Get-Content -Raw -LiteralPath $scope.resolved_path | ConvertFrom-Json
    return [ordered]@{
      id = $Id
      exists = $true
      path = $scope.path
      json = $json
      parse_error = "none"
      bounded = $true
    }
  } catch {
    return [ordered]@{
      id = $Id
      exists = $true
      path = $scope.path
      json = $null
      parse_error = "json_parse_failed"
      bounded = $true
    }
  }
}

function Invoke-SecretScan {
  param([bool]$SkipScan = $false)

  if ($SkipScan) {
    return [ordered]@{
      skipped = $true
      command = "scripts/scan_secrets.ps1"
      exit_code = $null
      status = "skipped"
    }
  }

  $ps = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
  $args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $repoRoot "scripts\scan_secrets.ps1"))
  $global:LASTEXITCODE = 0
  [void](& $ps @args 2>&1 | ForEach-Object { [string]$_ })
  $exitCode = if ($null -eq $global:LASTEXITCODE) { 0 } else { [int]$global:LASTEXITCODE }
  return [ordered]@{
    skipped = $false
    command = "scripts/scan_secrets.ps1"
    exit_code = $exitCode
    status = if ($exitCode -eq 0) { "pass" } else { "fail" }
  }
}

function Write-JsonResult {
  param(
    [Parameter(Mandatory = $true)]$Result,
    [string]$DestinationPath = ""
  )

  $script:WriteResultExitCode = [int]$Result.actual_exit_code
  $json = $Result | ConvertTo-Json -Depth 16
  if (-not [string]::IsNullOrWhiteSpace($DestinationPath)) {
    $scope = Test-RepoBoundedEvidencePath -Path $DestinationPath
    if (-not [bool]$scope.bounded) {
      $Result["output_path"] = [ordered]@{
        requested = $DestinationPath
        status = "unsafe_path_refused"
      }
      $Result["overall_status"] = "refused"
      $Result["actual_exit_code"] = $defaultExitCodes.unsafe_path_refused
      $Result["failed_checks"] = @(@($Result.failed_checks) + [ordered]@{
          id = "output_path_scope"
          status = "fail"
          reason = "OutputPath must be under .tmp/** or artifacts/**"
        })
      $json = $Result | ConvertTo-Json -Depth 16
      Write-Output $json
      $script:WriteResultExitCode = $defaultExitCodes.unsafe_path_refused
      return
    }

    $parent = Split-Path -Parent $scope.resolved_path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
      [void](New-Item -ItemType Directory -Force -Path $parent)
    }
    $json | Set-Content -LiteralPath $scope.resolved_path -Encoding UTF8
  }

  Write-Output $json
  return
}

function Invoke-Aggregation {
  param(
    [Parameter(Mandatory = $true)][string]$E9Path,
    [Parameter(Mandatory = $true)][string]$GatewayPath,
    [Parameter(Mandatory = $true)][string]$ControlPlanePath,
    [Parameter(Mandatory = $true)][string]$BundlePath,
    [string]$DestinationPath = "",
    [bool]$SkipScan = $false,
    [bool]$AllowTestFixture = $false
  )

  $inputs = @(
    (Read-JsonIfPresent -Path $E9Path -Id "e9_paid_readiness_gate_json"),
    (Read-JsonIfPresent -Path $GatewayPath -Id "e8_gateway_paid_hot_path_artifact"),
    (Read-JsonIfPresent -Path $ControlPlanePath -Id "e11_control_plane_paid_readback_reconciliation_artifact"),
    (Read-JsonIfPresent -Path $BundlePath -Id "real_paid_evidence_bundle")
  )

  $requiredArtifacts = @($inputs | ForEach-Object {
      [ordered]@{ id = $_.id; path = $_.path }
    })

  $missingArtifacts = @()
  $passChecks = New-Object System.Collections.Generic.List[object]
  $blockedChecks = New-Object System.Collections.Generic.List[object]
  $failedChecks = New-Object System.Collections.Generic.List[object]

  foreach ($artifact in $inputs) {
    if (-not [bool]$artifact.bounded) {
      [void]$failedChecks.Add([ordered]@{
          id = $artifact.id
          status = "fail"
          path = $artifact.path
          reason = "unsafe_path_refused"
        })
      continue
    }

    if (-not [bool]$artifact.exists) {
      $missingArtifacts += $artifact.path
    }
  }

  $secretScan = Invoke-SecretScan -SkipScan $SkipScan
  if ([string]$secretScan.status -eq "pass" -or [string]$secretScan.status -eq "skipped") {
    [void]$passChecks.Add([ordered]@{ id = "secret_scan"; status = $secretScan.status; exit_code = $secretScan.exit_code })
  } else {
    [void]$failedChecks.Add([ordered]@{ id = "secret_scan"; status = $secretScan.status; exit_code = $secretScan.exit_code })
  }

  $artifactCheckIds = @{
    e9_paid_readiness_gate_json = "e9_paid_readiness_gate_json"
    e8_gateway_paid_hot_path_artifact = "gateway_paid_hot_path_reserve_settle_refund"
    e11_control_plane_paid_readback_reconciliation_artifact = "control_plane_paid_readback_reconciliation"
    real_paid_evidence_bundle = "real_paid_evidence_bundle_accepted"
  }

  foreach ($artifact in $inputs) {
    if (-not [bool]$artifact.bounded) { continue }

    $checkId = $artifactCheckIds[$artifact.id]
    if ([bool]$artifact.exists -and [string]$artifact.parse_error -eq "none") {
      $passResult = Test-ArtifactPass -Json $artifact.json -Path $artifact.path -AllowTestFixture:$AllowTestFixture
      if ([bool]$passResult.passed) {
        [void]$passChecks.Add([ordered]@{ id = $checkId; status = "pass"; path = $artifact.path; reason = $passResult.reason })
        continue
      }
      $blockedSummary = Get-ArtifactBlockedSummary -Json $artifact.json -FallbackReason $passResult.reason
      [void]$blockedChecks.Add([ordered]@{
          id = $checkId
          status = "blocked"
          path = $artifact.path
          reason = $blockedSummary.reason
          artifact_overall_status = $blockedSummary.artifact_overall_status
          artifact_actual_exit_code = $blockedSummary.artifact_actual_exit_code
          artifact_decision = $blockedSummary.artifact_decision
          artifact_blockers = @($blockedSummary.artifact_blockers)
        })
      continue
    }

    [void]$blockedChecks.Add([ordered]@{
        id = $checkId
        status = "blocked"
        path = $artifact.path
        reason = $artifact.parse_error
      })
  }

  $toolFailed = $failedChecks.Count -gt 0
  $paidAllowed = (
    -not $toolFailed -and
    $blockedChecks.Count -eq 0 -and
    $missingArtifacts.Count -eq 0
  )

  if (-not $toolFailed -and -not $paidAllowed) {
    [void]$blockedChecks.Add([ordered]@{
        id = "release_gate_paid_allowed"
        status = "blocked"
        reason = "paid_controlled_beta_allowed remains false until all real paid evidence inputs pass"
      })
  }

  $actualExitCode = if ($paidAllowed) {
    $defaultExitCodes.pass
  } elseif ($toolFailed) {
    $defaultExitCodes.tool_failure
  } else {
    $defaultExitCodes.blocked
  }

  $result = [ordered]@{
    schema = "paid_beta_acceptance_aggregator_v2"
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    overall_status = if ($paidAllowed) { "pass" } elseif ($toolFailed) { "fail" } else { "blocked" }
    actual_exit_code = $actualExitCode
    exit_code_contract = [ordered]@{
      pass = 0
      unsafe_or_tool_failure = 1
      blocked_until_real_evidence = 2
    }
    mode = if ($AllowTestFixture) { "test_fixture" } else { "release" }
    paid_controlled_beta_requested = $true
    paid_controlled_beta_allowed = [bool]$paidAllowed
    required_artifacts = @($requiredArtifacts)
    missing_artifacts = @($missingArtifacts)
    required_evidence = @($requiredEvidence)
    blocked_checks = @($blockedChecks.ToArray())
    pass_checks = @($passChecks.ToArray())
    failed_checks = @($failedChecks.ToArray())
    not_final_if_blocked = -not $paidAllowed
    secret_scan_result = $secretScan
  }

  return $result
}

function New-SelfTestArtifact {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [bool]$FixtureLoaded = $true,
    [bool]$Simulation = $false,
    [bool]$ContractOnly = $false
  )

  $scope = Test-RepoBoundedEvidencePath -Path $Path
  $parent = Split-Path -Parent $scope.resolved_path
  [void](New-Item -ItemType Directory -Force -Path $parent)
  $body = [ordered]@{
    status = "pass"
    accepted_contract_shape = $true
    non_synthetic = -not $Simulation
    fixture_loaded = $FixtureLoaded
    simulation = $Simulation
    contract_only = $ContractOnly
    secret_safe = $true
  }
  $body | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $scope.resolved_path -Encoding UTF8
}

function Write-SelfTestJson {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Body
  )

  $scope = Test-RepoBoundedEvidencePath -Path $Path
  $parent = Split-Path -Parent $scope.resolved_path
  [void](New-Item -ItemType Directory -Force -Path $parent)
  $Body | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $scope.resolved_path -Encoding UTF8
}

function Write-SelfTestReleasePassArtifacts {
  param(
    [Parameter(Mandatory = $true)][string]$Base,
    [bool]$GatewayMissingOperationIds = $false
  )

  $evidence = if ($GatewayMissingOperationIds) {
    @(
      [ordered]@{ evidence_key = "gateway_hot_path_reserve_settle_refund"; status = "passed"; passed = $true; request_id = "req-success" }
    )
  } else {
    @(
      [ordered]@{ evidence_key = "gateway_hot_path_reserve_settle_refund"; status = "passed"; passed = $true; request_id = "req-success"; operation_id = "op-success" },
      [ordered]@{ evidence_key = "refund_idempotency"; status = "passed"; passed = $true; request_id = "req-success"; operation_id = "op-refund"; refund_operation_id = "op-refund" }
    )
  }

  Write-SelfTestJson -Path "$Base/e8.json" -Body ([ordered]@{
      schema = "gateway_paid_hot_path_smoke_v1"
      status = "passed"
      request_trace = [ordered]@{ request_ids = @("req-success", "req-failure") }
      evidence = $evidence
      secret_safe = [ordered]@{ raw_or_secret_marker_present = $false }
    })

  Write-SelfTestJson -Path "$Base/e11.json" -Body ([ordered]@{
      schema_version = "control_plane_paid_ledger_readback_verification.v1"
      overall_status = "passed"
      actual_exit_code = 0
      accepted_evidence = @("post_commit_readback", "rollback_proof", "reconciliation_report")
      missing_evidence = @()
      blockers = @()
      gateway_artifact = [ordered]@{ request_ids_present = $true; operation_ids_present = $true }
      secret_safe = [ordered]@{ secret_safe = $true; raw_secret_present = $false }
    })

  Write-SelfTestJson -Path "$Base/e9.json" -Body ([ordered]@{
      schema_version = "billing_beta_mode_readiness.v1"
      classification = "pass"
      paid_controlled_beta_allowed = $true
      paid_controlled_beta_production_ready = $true
      blockers = @()
      missing_evidence = @()
      exit_code_contract = [ordered]@{ actual_exit_code = 0 }
      secret_safe = [ordered]@{ raw_secret_echoed = $false; credential_material_echoed = $false }
    })

  Write-SelfTestJson -Path "$Base/bundle.json" -Body ([ordered]@{
      schema_version = "billing_paid_strong_consistency_evidence_bundle.v1"
      overall_status = "accepted_contract_shape"
      accepted_contract_shape = $true
      real_paid_evidence_bundle_accepted = $true
      real_provenance = $true
      non_synthetic = $true
      contract_shape_only = $false
      synthetic_selftest = $false
      paid_controlled_beta_production_ready = $true
      missing_evidence = @()
      invalid_evidence = @()
      refusal_reasons = @()
      secret_safe = [ordered]@{ raw_secret_present = $false; credential_material_echoed = $false }
    })
}

function Invoke-SelfTest {
  $base = ".tmp/paid-beta-aggregator-selftest"
  $cases = New-Object System.Collections.Generic.List[object]

  $missingResult = Invoke-Aggregation `
    -E9Path "$base/missing/e9.json" `
    -GatewayPath "$base/missing/e8.json" `
    -ControlPlanePath "$base/missing/e11.json" `
    -BundlePath "$base/missing/bundle.json" `
    -SkipScan $true
  $missingExit = [int]$missingResult.actual_exit_code
  [void]$cases.Add([ordered]@{ id = "missing_inputs_blocked"; expected_exit_code = 2; actual_exit_code = $missingExit; status = if ($missingExit -eq 2) { "pass" } else { "fail" } })

  $unsafeResult = Invoke-Aggregation `
    -E9Path "..\unsafe-paid.json" `
    -GatewayPath "$base/missing/e8.json" `
    -ControlPlanePath "$base/missing/e11.json" `
    -BundlePath "$base/missing/bundle.json" `
    -SkipScan $true
  $unsafeExit = [int]$unsafeResult.actual_exit_code
  [void]$cases.Add([ordered]@{ id = "unsafe_path_refused"; expected_exit_code = 1; actual_exit_code = $unsafeExit; status = if ($unsafeExit -eq 1) { "pass" } else { "fail" } })

  foreach ($name in @("e9", "e8", "e11", "bundle")) {
    New-SelfTestArtifact -Path "$base/synthetic/$name.json" -FixtureLoaded $true -Simulation $true -ContractOnly $true
  }
  $syntheticResult = Invoke-Aggregation `
    -E9Path "$base/synthetic/e9.json" `
    -GatewayPath "$base/synthetic/e8.json" `
    -ControlPlanePath "$base/synthetic/e11.json" `
    -BundlePath "$base/synthetic/bundle.json" `
    -SkipScan $true
  $syntheticExit = [int]$syntheticResult.actual_exit_code
  [void]$cases.Add([ordered]@{ id = "synthetic_contract_only_release_blocked"; expected_exit_code = 2; actual_exit_code = $syntheticExit; status = if ($syntheticExit -eq 2) { "pass" } else { "fail" } })

  foreach ($name in @("e9", "e8", "e11", "bundle")) {
    New-SelfTestArtifact -Path "$base/fixture/$name.json" -FixtureLoaded $true -Simulation $false -ContractOnly $false
  }
  $releaseFixtureResult = Invoke-Aggregation `
    -E9Path "$base/fixture/e9.json" `
    -GatewayPath "$base/fixture/e8.json" `
    -ControlPlanePath "$base/fixture/e11.json" `
    -BundlePath "$base/fixture/bundle.json" `
    -SkipScan $true
  $releaseFixtureExit = [int]$releaseFixtureResult.actual_exit_code
  [void]$cases.Add([ordered]@{ id = "accepted_fixture_release_mode_blocked"; expected_exit_code = 2; actual_exit_code = $releaseFixtureExit; status = if ($releaseFixtureExit -eq 2) { "pass" } else { "fail" } })

  $testFixtureResult = Invoke-Aggregation `
    -E9Path "$base/fixture/e9.json" `
    -GatewayPath "$base/fixture/e8.json" `
    -ControlPlanePath "$base/fixture/e11.json" `
    -BundlePath "$base/fixture/bundle.json" `
    -SkipScan $true `
    -AllowTestFixture $true
  $testFixtureExit = [int]$testFixtureResult.actual_exit_code
  [void]$cases.Add([ordered]@{ id = "accepted_fixture_test_mode_pass"; expected_exit_code = 0; actual_exit_code = $testFixtureExit; status = if ($testFixtureExit -eq 0) { "pass" } else { "fail" } })

  Write-SelfTestReleasePassArtifacts -Base "$base/release-pass"
  $releasePassResult = Invoke-Aggregation `
    -E9Path "$base/release-pass/e9.json" `
    -GatewayPath "$base/release-pass/e8.json" `
    -ControlPlanePath "$base/release-pass/e11.json" `
    -BundlePath "$base/release-pass/bundle.json" `
    -SkipScan $true
  $releasePassExit = [int]$releasePassResult.actual_exit_code
  [void]$cases.Add([ordered]@{ id = "e8_e11_passed_release_artifacts_pass"; expected_exit_code = 0; actual_exit_code = $releasePassExit; status = if ($releasePassExit -eq 0) { "pass" } else { "fail" } })

  Write-SelfTestReleasePassArtifacts -Base "$base/release-missing-operation" -GatewayMissingOperationIds $true
  $missingOperationResult = Invoke-Aggregation `
    -E9Path "$base/release-missing-operation/e9.json" `
    -GatewayPath "$base/release-missing-operation/e8.json" `
    -ControlPlanePath "$base/release-missing-operation/e11.json" `
    -BundlePath "$base/release-missing-operation/bundle.json" `
    -SkipScan $true
  $missingOperationExit = [int]$missingOperationResult.actual_exit_code
  [void]$cases.Add([ordered]@{ id = "e8_missing_operation_ids_release_blocked"; expected_exit_code = 2; actual_exit_code = $missingOperationExit; status = if ($missingOperationExit -eq 2) { "pass" } else { "fail" } })

  $failed = @($cases.ToArray() | Where-Object { $_.status -ne "pass" })
  $result = [ordered]@{
    schema = "paid_beta_acceptance_aggregator_selftest_v1"
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    overall_status = if ($failed.Count -eq 0) { "pass" } else { "fail" }
    actual_exit_code = if ($failed.Count -eq 0) { 0 } else { 1 }
    cases = @($cases.ToArray())
    note = "Self-test artifacts are bounded under .tmp and are not release artifacts."
  }

  $script:SelfTestExitCode = [int]$result.actual_exit_code
  Write-Output ($result | ConvertTo-Json -Depth 8)
  return
}

if ($SelfTest) {
  Invoke-SelfTest
  exit $script:SelfTestExitCode
}

$result = Invoke-Aggregation `
  -E9Path $E9ReadinessPath `
  -GatewayPath $GatewayPaidHotPathArtifactPath `
  -ControlPlanePath $ControlPlanePaidReadbackArtifactPath `
  -BundlePath $RealPaidEvidenceBundlePath `
  -DestinationPath $OutputPath `
  -SkipScan ([bool]$SkipSecretScan) `
  -AllowTestFixture ([bool]$TestMode)

Write-JsonResult -Result $result -DestinationPath $OutputPath
exit $script:WriteResultExitCode
