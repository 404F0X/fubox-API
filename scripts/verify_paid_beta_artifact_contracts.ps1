param(
  [string]$GatewayPaidHotPathArtifactPath = ".tmp\paid-beta\e8_gateway_paid_hot_path.json",
  [string]$ControlPlanePaidReadbackArtifactPath = ".tmp\paid-beta\e11_control_plane_paid_readback_reconciliation.json",
  [string]$E9ReadinessPath = ".tmp\paid-beta\e9_paid_readiness_gate.json",
  [string]$RealPaidEvidenceBundlePath = ".tmp\paid-beta\real_paid_evidence_bundle.json",
  [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

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

function Test-BoundedPath {
  param([Parameter(Mandatory = $true)][string]$Path)

  $full = Resolve-RepoPath $Path
  $relative = Get-RepoRelativePath $full
  $normalized = $relative -replace "\\", "/"
  $withinRepo = -not [System.IO.Path]::IsPathRooted($normalized)
  $allowed = $normalized.StartsWith(".tmp/", [System.StringComparison]::OrdinalIgnoreCase) -or
    $normalized.StartsWith("artifacts/", [System.StringComparison]::OrdinalIgnoreCase)
  return [ordered]@{
    requested_path = $Path
    resolved_path = $full
    path = $normalized
    bounded = [bool]($withinRepo -and $allowed)
  }
}

function Read-Artifact {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Path
  )

  $scope = Test-BoundedPath -Path $Path
  if (-not [bool]$scope.bounded) {
    return [ordered]@{
      id = $Id
      path = $scope.path
      exists = $false
      bounded = $false
      json = $null
      read_status = "unsafe_path_refused"
    }
  }

  if (-not (Test-Path -LiteralPath $scope.resolved_path -PathType Leaf)) {
    return [ordered]@{
      id = $Id
      path = $scope.path
      exists = $false
      bounded = $true
      json = $null
      read_status = "missing"
    }
  }

  try {
    $json = Get-Content -Raw -LiteralPath $scope.resolved_path | ConvertFrom-Json
    return [ordered]@{
      id = $Id
      path = $scope.path
      exists = $true
      bounded = $true
      json = $json
      read_status = "read"
    }
  } catch {
    return [ordered]@{
      id = $Id
      path = $scope.path
      exists = $true
      bounded = $true
      json = $null
      read_status = "json_parse_failed"
    }
  }
}

function Get-Field {
  param(
    [AllowNull()][object]$Json,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if ($null -eq $Json) { return $null }
  if ($Json.PSObject.Properties.Name -notcontains $Name) { return $null }
  return $Json.PSObject.Properties[$Name].Value
}

function Get-TextField {
  param(
    [AllowNull()][object]$Json,
    [Parameter(Mandatory = $true)][string[]]$Names
  )

  foreach ($name in $Names) {
    $value = Get-Field -Json $Json -Name $name
    if ($null -eq $value) { continue }
    $text = ([string]$value).Trim()
    if (-not [string]::IsNullOrWhiteSpace($text)) {
      return $text
    }
  }
  return $null
}

function Get-ExitCode {
  param([AllowNull()][object]$Json)

  $direct = Get-Field -Json $Json -Name "actual_exit_code"
  if ($null -ne $direct -and ([string]$direct).Trim() -match "^-?\d+$") {
    return [int]$direct
  }
  $contract = Get-Field -Json $Json -Name "exit_code_contract"
  $nested = Get-Field -Json $contract -Name "actual_exit_code"
  if ($null -ne $nested -and ([string]$nested).Trim() -match "^-?\d+$") {
    return [int]$nested
  }
  return $null
}

function Get-StringList {
  param(
    [AllowNull()][object]$Json,
    [Parameter(Mandatory = $true)][string[]]$Names
  )

  $items = New-Object System.Collections.Generic.List[string]
  foreach ($name in $Names) {
    $value = Get-Field -Json $Json -Name $name
    if ($null -eq $value) { continue }
    foreach ($entry in @($value)) {
      if ($null -eq $entry) { continue }
      $text = ([string]$entry).Trim()
      if (-not [string]::IsNullOrWhiteSpace($text) -and -not $items.Contains($text)) {
        [void]$items.Add($text)
      }
    }
  }
  return @($items.ToArray())
}

function Test-Truthy {
  param(
    [AllowNull()][object]$Json,
    [Parameter(Mandatory = $true)][string[]]$Names
  )

  foreach ($name in $Names) {
    $value = Get-Field -Json $Json -Name $name
    if ($value -is [bool] -and $value) { return $true }
    if ($null -ne $value) {
      $text = ([string]$value).Trim().ToLowerInvariant()
      if (@("true", "pass", "passed", "accepted", "allowed", "ready") -contains $text) {
        return $true
      }
    }
  }
  return $false
}

function Get-RequestIdsFromGateway {
  param([AllowNull()][object]$Gateway)

  $ids = New-Object System.Collections.Generic.List[string]
  $trace = Get-Field -Json $Gateway -Name "request_trace"
  $traceIds = Get-Field -Json $trace -Name "request_ids"
  foreach ($id in @($traceIds)) {
    if ($null -ne $id -and -not [string]::IsNullOrWhiteSpace([string]$id) -and -not $ids.Contains([string]$id)) {
      [void]$ids.Add([string]$id)
    }
  }

  foreach ($name in @("success_request_id", "failure_request_id", "insufficient_request_id")) {
    $id = Get-Field -Json $trace -Name $name
    if ($null -ne $id -and -not [string]::IsNullOrWhiteSpace([string]$id) -and -not $ids.Contains([string]$id)) {
      [void]$ids.Add([string]$id)
    }
  }

  $operator = Get-Field -Json $Gateway -Name "operator_readback"
  $params = Get-Field -Json $operator -Name "parameters"
  foreach ($name in @("success_request_id", "failure_request_id", "insufficient_request_id")) {
    $id = Get-Field -Json $params -Name $name
    if ($null -ne $id -and -not [string]::IsNullOrWhiteSpace([string]$id) -and -not $ids.Contains([string]$id)) {
      [void]$ids.Add([string]$id)
    }
  }

  return @($ids.ToArray())
}

function Add-UniqueText {
  param(
    [Parameter(Mandatory = $true)]$List,
    [AllowNull()]$Value
  )

  if ($null -eq $Value) { return }
  $text = ([string]$Value).Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { return }
  if (-not $List.Contains($text)) {
    [void]$List.Add($text)
  }
}

function Get-ObjectArrayField {
  param(
    [AllowNull()][object]$Json,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $value = Get-Field -Json $Json -Name $Name
  if ($null -eq $value) { return @() }
  if ($value -is [System.Array]) { return @($value) }
  return @(,$value)
}

function Get-OperationIdsFromGateway {
  param([AllowNull()][object]$Gateway)

  $ids = New-Object System.Collections.Generic.List[string]
  foreach ($id in @(Get-Field -Json $Gateway -Name "operation_ids")) {
    Add-UniqueText -List $ids -Value $id
  }
  foreach ($id in @(Get-Field -Json $Gateway -Name "ledger_operation_ids")) {
    Add-UniqueText -List $ids -Value $id
  }

  foreach ($entry in (Get-ObjectArrayField -Json $Gateway -Name "evidence")) {
    foreach ($name in @(
        "operation_id",
        "reserve_operation_id",
        "settle_operation_id",
        "release_operation_id",
        "refund_operation_id",
        "related_ledger_entry_id"
      )) {
      Add-UniqueText -List $ids -Value (Get-Field -Json $entry -Name $name)
    }
  }

  $readback = Get-Field -Json $Gateway -Name "post_commit_readback"
  $operationEvidence = Get-Field -Json $readback -Name "operation_evidence"
  foreach ($name in @(
      "success_settle_ledger_entry_id",
      "failure_release_ledger_entry_id",
      "success_reserve_ledger_entry_id",
      "failure_release_idempotency_key"
    )) {
    Add-UniqueText -List $ids -Value (Get-Field -Json $operationEvidence -Name $name)
  }

  return @($ids.ToArray())
}

function Test-EvidenceMapping {
  param([AllowNull()][object]$Gateway)

  $readback = Get-Field -Json $Gateway -Name "post_commit_readback"
  $mapping = [ordered]@{
    gateway_hot_path_reserve_settle_refund = (Test-Truthy -Json $Gateway -Names @("gateway_hot_path_reserve_settle_refund")) -or
      ((Test-Truthy -Json $readback -Names @("reserve_before_provider_side_effect")) -and
        (Test-Truthy -Json $readback -Names @("successful_request_settled")) -and
        (Test-Truthy -Json $readback -Names @("failure_request_released")))
    insufficient_balance_prevents_provider_call = (Test-Truthy -Json $Gateway -Names @("insufficient_balance_prevents_provider_call")) -or
      (Test-Truthy -Json $readback -Names @("insufficient_balance_prevents_provider_call"))
    settle_idempotency = (Test-Truthy -Json $Gateway -Names @("settle_idempotency")) -or
      (Test-Truthy -Json $readback -Names @("settle_idempotency"))
    refund_idempotency = $false
    post_commit_readback = (Test-Truthy -Json $Gateway -Names @("post_commit_readback")) -or
      (Test-Truthy -Json $readback -Names @("post_commit_readback"))
    rollback_proof = $null -ne (Get-Field -Json $Gateway -Name "rollback_proof") -or
      $null -ne (Get-Field -Json $readback -Name "rollback_proof")
    reconciliation_report = $null -ne (Get-Field -Json $Gateway -Name "reconciliation_report") -or
      $null -ne (Get-Field -Json $readback -Name "reconciliation_report")
  }

  $refund = Get-Field -Json $Gateway -Name "refund_idempotency"
  if ($null -eq $refund) { $refund = Get-Field -Json $readback -Name "refund_idempotency" }
  if ($null -ne $refund) {
    $mapping.refund_idempotency = (Test-Truthy -Json $refund -Names @("passed", "release_idempotency_seen"))
  }

  return $mapping
}

function Test-E11ConsumerCanReadGateway {
  param([AllowNull()][object]$E11)

  $gatewayArtifact = Get-Field -Json $E11 -Name "gateway_artifact"
  return (Test-Truthy -Json $gatewayArtifact -Names @("request_ids_present")) -and
    (Test-Truthy -Json $gatewayArtifact -Names @("operation_ids_present"))
}

function New-MissingResult {
  param(
    [Parameter(Mandatory = $true)][object]$Artifact,
    [Parameter(Mandatory = $true)][string]$ConsumerStatus,
    [Parameter(Mandatory = $true)][string]$Blocker
  )

  return [ordered]@{
    id = $Artifact.id
    path = $Artifact.path
    exists = [bool]$Artifact.exists
    read_status = $Artifact.read_status
    consumer_status = $ConsumerStatus
    status = "blocked"
    actual_exit_code = $null
    blockers = @($Blocker)
  }
}

function Invoke-SelfTest {
  $evidenceOnlyGateway = @'
{
  "schema": "gateway_paid_hot_path_smoke_v1",
  "status": "passed",
  "evidence": [
    {"evidence_key": "gateway_hot_path_reserve_settle_refund", "operation_id": "op-a", "reserve_operation_id": "op-reserve"},
    {"evidence_key": "insufficient_balance_prevents_provider_call", "operation_id": "op-b"}
  ]
}
'@ | ConvertFrom-Json

  $missingOperationGateway = @'
{
  "schema": "gateway_paid_hot_path_smoke_v1",
  "status": "passed",
  "evidence": [
    {"evidence_key": "gateway_hot_path_reserve_settle_refund", "request_id": "req-a"},
    {"evidence_key": "insufficient_balance_prevents_provider_call", "request_id": "req-b"}
  ]
}
'@ | ConvertFrom-Json

  $evidenceOnlyIds = Get-OperationIdsFromGateway -Gateway $evidenceOnlyGateway
  $missingIds = Get-OperationIdsFromGateway -Gateway $missingOperationGateway

  $cases = @(
    [ordered]@{
      id = "evidence_array_operation_ids_are_consumed"
      expected = "operation_id_count_gt_zero"
      actual_operation_id_count = $evidenceOnlyIds.Count
      status = if ($evidenceOnlyIds.Count -gt 0) { "pass" } else { "fail" }
    },
    [ordered]@{
      id = "missing_operation_ids_do_not_pass"
      expected = "operation_id_count_zero"
      actual_operation_id_count = $missingIds.Count
      status = if ($missingIds.Count -eq 0) { "pass" } else { "fail" }
    }
  )
  $failed = @($cases | Where-Object { $_.status -ne "pass" })
  $result = [ordered]@{
    schema = "paid_beta_artifact_consumer_contracts_selftest_v1"
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    overall_status = if ($failed.Count -eq 0) { "pass" } else { "fail" }
    actual_exit_code = if ($failed.Count -eq 0) { 0 } else { 1 }
    cases = @($cases)
  }

  $script:SelfTestExitCode = [int]$result.actual_exit_code
  Write-Output ($result | ConvertTo-Json -Depth 8)
  return
}

if ($SelfTest) {
  Invoke-SelfTest
  exit $script:SelfTestExitCode
}

$gateway = Read-Artifact -Id "e8_gateway_paid_hot_path" -Path $GatewayPaidHotPathArtifactPath
$e11 = Read-Artifact -Id "e11_control_plane_paid_readback_reconciliation" -Path $ControlPlanePaidReadbackArtifactPath
$e9 = Read-Artifact -Id "e9_paid_readiness_gate" -Path $E9ReadinessPath
$bundle = Read-Artifact -Id "real_paid_evidence_bundle" -Path $RealPaidEvidenceBundlePath

$results = New-Object System.Collections.Generic.List[object]
$toolFailures = New-Object System.Collections.Generic.List[object]

foreach ($artifact in @($gateway, $e11, $e9, $bundle)) {
  if (-not [bool]$artifact.bounded) {
    [void]$toolFailures.Add([ordered]@{ id = $artifact.id; path = $artifact.path; reason = "unsafe_path_refused" })
  } elseif ([string]$artifact.read_status -eq "json_parse_failed") {
    [void]$toolFailures.Add([ordered]@{ id = $artifact.id; path = $artifact.path; reason = "json_parse_failed" })
  }
}

if ([bool]$gateway.exists -and [string]$gateway.read_status -eq "read") {
  $requestIds = Get-RequestIdsFromGateway -Gateway $gateway.json
  $evidenceMapping = Test-EvidenceMapping -Gateway $gateway.json
  $operationIds = Get-OperationIdsFromGateway -Gateway $gateway.json
  $e11ConsumerReadable = if ([bool]$e11.exists -and [string]$e11.read_status -eq "read") {
    Test-E11ConsumerCanReadGateway -E11 $e11.json
  } else {
    $false
  }

  $missingShape = New-Object System.Collections.Generic.List[string]
  if ($requestIds.Count -eq 0) { [void]$missingShape.Add("request_ids_missing") }
  if ($operationIds.Count -eq 0) { [void]$missingShape.Add("operation_ids_missing") }
  foreach ($property in $evidenceMapping.Keys) {
    if (-not [bool]$evidenceMapping[$property]) {
      [void]$missingShape.Add("${property}_mapping_missing")
    }
  }
  if (-not $e11ConsumerReadable) { [void]$missingShape.Add("e11_consumer_request_or_operation_ids_missing") }

  [void]$results.Add([ordered]@{
      id = $gateway.id
      path = $gateway.path
      exists = $true
      read_status = "read"
      status = Get-TextField -Json $gateway.json -Names @("overall_status", "status", "classification")
      consumer_status = if ($missingShape.Count -eq 0) { "pass" } else { "blocked" }
      actual_exit_code = Get-ExitCode -Json $gateway.json
      request_id_count = $requestIds.Count
      operation_id_count = $operationIds.Count
      evidence_mapping = $evidenceMapping
      blockers = if ($missingShape.Count -eq 0) { @() } else { @("gateway_paid_hot_path_consumer_shape_missing") + @($missingShape.ToArray()) }
    })
} else {
  [void]$results.Add((New-MissingResult -Artifact $gateway -ConsumerStatus "missing" -Blocker "gateway_paid_hot_path_artifact_missing"))
}

if ([bool]$e11.exists -and [string]$e11.read_status -eq "read") {
  $artifactBlockers = Get-StringList -Json $e11.json -Names @("blockers", "refusal_reasons", "missing_evidence")
  [void]$results.Add([ordered]@{
      id = $e11.id
      path = $e11.path
      exists = $true
      read_status = "read"
      status = Get-TextField -Json $e11.json -Names @("overall_status", "status", "classification")
      consumer_status = if ((Get-TextField -Json $e11.json -Names @("overall_status", "status", "classification")) -in @("pass", "passed", "accepted")) { "pass" } else { "blocked" }
      actual_exit_code = Get-ExitCode -Json $e11.json
      blockers = @($artifactBlockers)
    })
} else {
  [void]$results.Add((New-MissingResult -Artifact $e11 -ConsumerStatus "missing" -Blocker "control_plane_paid_readback_artifact_missing"))
}

if ([bool]$e9.exists -and [string]$e9.read_status -eq "read") {
  $artifactBlockers = Get-StringList -Json $e9.json -Names @("blockers", "refusal_reasons", "missing_evidence")
  $status = Get-TextField -Json $e9.json -Names @("overall_status", "status", "classification")
  [void]$results.Add([ordered]@{
      id = $e9.id
      path = $e9.path
      exists = $true
      read_status = "read"
      status = $status
      consumer_status = if ($status -in @("pass", "passed", "accepted")) { "pass" } else { "blocked" }
      actual_exit_code = Get-ExitCode -Json $e9.json
      decision = Get-TextField -Json $e9.json -Names @("decision")
      paid_controlled_beta_allowed = [bool](Test-Truthy -Json $e9.json -Names @("paid_controlled_beta_allowed"))
      blockers = @($artifactBlockers)
    })
} else {
  [void]$results.Add((New-MissingResult -Artifact $e9 -ConsumerStatus "missing" -Blocker "e9_paid_readiness_artifact_missing"))
}

if ([bool]$bundle.exists -and [string]$bundle.read_status -eq "read") {
  $artifactBlockers = Get-StringList -Json $bundle.json -Names @("blockers", "refusal_reasons", "missing_evidence", "invalid_evidence")
  $status = Get-TextField -Json $bundle.json -Names @("overall_status", "status", "classification")
  $bundleAccepted = ($status -in @("pass", "passed", "accepted", "accepted_contract_shape")) -and
    (Test-Truthy -Json $bundle.json -Names @("accepted_contract_shape", "real_paid_evidence_bundle_accepted", "paid_controlled_beta_production_ready")) -and
    -not (Test-Truthy -Json $bundle.json -Names @("contract_shape_only", "synthetic_selftest")) -and
    @($artifactBlockers).Count -eq 0
  [void]$results.Add([ordered]@{
      id = $bundle.id
      path = $bundle.path
      exists = $true
      read_status = "read"
      status = $status
      consumer_status = if ($bundleAccepted) { "pass" } else { "blocked" }
      actual_exit_code = Get-ExitCode -Json $bundle.json
      blockers = @($artifactBlockers)
    })
} else {
  [void]$results.Add((New-MissingResult -Artifact $bundle -ConsumerStatus "missing" -Blocker "real_paid_evidence_bundle_missing"))
}

$blocked = @($results.ToArray() | Where-Object { $_.consumer_status -ne "pass" })
$overallStatus = if ($toolFailures.Count -gt 0) {
  "fail"
} elseif ($blocked.Count -gt 0) {
  "blocked"
} else {
  "pass"
}
$actualExitCode = if ($overallStatus -eq "pass") { 0 } elseif ($overallStatus -eq "blocked") { 2 } else { 1 }

$result = [ordered]@{
  schema = "paid_beta_artifact_consumer_contracts_v1"
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  overall_status = $overallStatus
  actual_exit_code = $actualExitCode
  artifacts = @($results.ToArray())
  blockers = @($blocked | ForEach-Object { $_.blockers } | ForEach-Object { $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
  failed_checks = @($toolFailures.ToArray())
}

$result | ConvertTo-Json -Depth 16
exit $actualExitCode
