param(
  [string]$GatewayPaidHotPathArtifactPath = ".tmp\paid-beta\e8_gateway_paid_hot_path.json",
  [string]$ControlPlanePaidReadbackArtifactPath = ".tmp\paid-beta\e11_control_plane_paid_readback_reconciliation.json",
  [string]$OutputBundlePath = ".tmp\paid-beta\real_paid_evidence_bundle.json",
  [switch]$SelfTest,
  [int]$BlockedExitCode = 2
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$requiredEvidence = @(
  "gateway_hot_path_reserve_settle_refund",
  "insufficient_balance_prevents_provider_call",
  "settle_idempotency",
  "refund_idempotency",
  "post_commit_readback",
  "rollback_proof",
  "reconciliation_report"
)
$gatewayEvidence = @(
  "gateway_hot_path_reserve_settle_refund",
  "insufficient_balance_prevents_provider_call",
  "settle_idempotency",
  "refund_idempotency"
)
$controlPlaneEvidence = @(
  "post_commit_readback",
  "rollback_proof",
  "reconciliation_report"
)

function ConvertTo-JsonList {
  param([object]$Value)

  $list = [System.Collections.Generic.List[object]]::new()
  if ($null -eq $Value) {
    return ,$list
  }
  if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
    foreach ($item in $Value) {
      [void]$list.Add($item)
    }
    return ,$list
  }
  [void]$list.Add($Value)
  return ,$list
}

function Resolve-RepoBoundedPath {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [switch]$AllowFixturePath
  )

  $candidate = if ([System.IO.Path]::IsPathRooted($Path)) {
    [System.IO.Path]::GetFullPath($Path)
  } else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
  }
  $repoPrefix = $repoRoot.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
  if (-not $candidate.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "path_must_stay_inside_repo"
  }

  $relative = $candidate.Substring($repoPrefix.Length).Replace("\", "/")
  $allowed = $relative.StartsWith(".tmp/", [System.StringComparison]::OrdinalIgnoreCase) -or
    $relative.StartsWith("artifacts/", [System.StringComparison]::OrdinalIgnoreCase) -or
    ($AllowFixturePath -and $relative.StartsWith("tests/fixtures/billing/", [System.StringComparison]::OrdinalIgnoreCase))
  if (-not $allowed) {
    throw "path_must_be_under_tmp_or_artifacts"
  }

  return [ordered]@{
    full = $candidate
    relative = $relative
  }
}

function Test-SecretSafeText {
  param([AllowNull()][string]$Text)
  if ([string]::IsNullOrEmpty($Text)) {
    return $true
  }
  foreach ($pattern in @(
      '(?i)authorization\s*[:=]',
      '(?i)bearer\s+[A-Za-z0-9._~+/\-]+=*',
      '(?i)cookie\s*[:=]',
      '(?i)api[_-]?key\s*[:=]',
      '(?i)provider[_-]?key\s*[:=]',
      '(?i)virtual[_-]?key\s*[:=]',
      '(?i)database[_-]?url\s*[:=]',
      '(?i)postgres(?:ql)?://',
      '(?i)password\s*[:=]',
      'sk-[A-Za-z0-9]{8,}'
    )) {
    if ($Text -match $pattern) {
      return $false
    }
  }
  return $true
}

function Get-PropertyNames {
  param([AllowNull()]$Object)
  if ($null -eq $Object -or $null -eq $Object.PSObject) {
    return @()
  }
  return @($Object.PSObject.Properties.Name)
}

function Get-PropertyValue {
  param(
    [AllowNull()]$Object,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if ((Get-PropertyNames $Object) -contains $Name) {
    return $Object.PSObject.Properties[$Name].Value
  }
  return $null
}

function Test-Truthy {
  param([AllowNull()]$Value)
  if ($Value -is [bool]) {
    return [bool]$Value
  }
  if ($null -eq $Value) {
    return $false
  }
  $text = ([string]$Value).Trim().ToLowerInvariant()
  return @("true", "pass", "passed", "ready", "allowed", "accepted", "accepted_shape", "readback_complete") -contains $text
}

function Test-EvidencePassed {
  param([AllowNull()]$Value)

  if ($null -eq $Value) {
    return $false
  }
  if (($Value -is [bool]) -or ($Value -is [string])) {
    return Test-Truthy $Value
  }
  $status = [string](Get-PropertyValue -Object $Value -Name "status")
  $passed = Get-PropertyValue -Object $Value -Name "passed"
  if (-not [string]::IsNullOrWhiteSpace($status)) {
    return $status.Trim().ToLowerInvariant() -eq "passed" -and (Test-Truthy $passed)
  }
  return Test-Truthy $passed
}

function Test-SyntheticOrFixture {
  param([AllowNull()]$Artifact)

  if ($null -eq $Artifact) {
    return $false
  }
  foreach ($flag in @("synthetic_selftest", "selftest_fixture", "fixture_only", "contract_fixture", "contract_shape_only")) {
    $value = Get-PropertyValue -Object $Artifact -Name $flag
    if (Test-Truthy $value) {
      return $true
    }
  }
  foreach ($name in @("artifact_id", "bundle_id", "generated_by", "environment_scope", "overall_status", "classification")) {
    $value = [string](Get-PropertyValue -Object $Artifact -Name $name)
    if ($value -match '(?i)(fixture|synthetic|contract[_-]?only|no_db_no_network)') {
      return $true
    }
  }
  return $false
}

function Read-Artifact {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$MissingCode,
    [switch]$AllowFixturePath
  )

  $bounded = Resolve-RepoBoundedPath -Path $Path -AllowFixturePath:$AllowFixturePath
  if (-not (Test-Path -LiteralPath $bounded.full -PathType Leaf)) {
    return [ordered]@{
      exists = $false
      path_bounded = $true
      path_output = "omitted"
      relative_path = $bounded.relative
      raw_text = $null
      json = $null
      blockers = @($MissingCode)
      secret_safe = $false
      synthetic_or_fixture = $false
    }
  }

  $raw = Get-Content -Raw -LiteralPath $bounded.full
  $secretSafe = Test-SecretSafeText $raw
  try {
    $json = $raw | ConvertFrom-Json
  } catch {
    return [ordered]@{
      exists = $true
      path_bounded = $true
      path_output = "omitted"
      relative_path = $bounded.relative
      raw_text = $raw
      json = $null
      blockers = @("artifact_json_parse_failed")
      secret_safe = $secretSafe
      synthetic_or_fixture = $false
    }
  }

  return [ordered]@{
    exists = $true
    path_bounded = $true
    path_output = "omitted"
    relative_path = $bounded.relative
    raw_text = $raw
    json = $json
    blockers = @()
    secret_safe = $secretSafe
    synthetic_or_fixture = Test-SyntheticOrFixture $json
  }
}

function Get-EvidenceItems {
  param([AllowNull()]$Artifact)

  $items = @()
  if ($null -eq $Artifact) {
    return @()
  }
  if ((Get-PropertyNames $Artifact) -contains "evidence") {
    $items += @($Artifact.evidence)
  }
  if ((Get-PropertyNames $Artifact) -contains "operations") {
    $items += @($Artifact.operations)
  }
  return @($items)
}

function Test-ComposerInputEvidenceMappingPresent {
  param(
    [AllowNull()]$Artifact,
    [string[]]$EvidenceKeys
  )

  $items = @(Get-EvidenceItems $Artifact)
  $mapped = New-Object System.Collections.Generic.HashSet[string]
  foreach ($item in $items) {
    $key = ([string](Get-PropertyValue -Object $item -Name "evidence_key")).Trim()
    if (@($EvidenceKeys) -contains $key) {
      [void]$mapped.Add($key)
    }
  }
  $readiness = Get-PropertyValue -Object $Artifact -Name "readiness_evidence"
  if ($null -ne $readiness) {
    foreach ($key in $EvidenceKeys) {
      if ((Get-PropertyNames $readiness) -contains $key -and [bool](Get-PropertyValue -Object $readiness -Name $key)) {
        [void]$mapped.Add($key)
      }
    }
  }
  foreach ($key in @((Get-PropertyValue -Object $Artifact -Name "accepted_evidence"))) {
    $trimmed = ([string]$key).Trim()
    if (@($EvidenceKeys) -contains $trimmed) {
      [void]$mapped.Add($trimmed)
    }
  }
  foreach ($key in $EvidenceKeys) {
    if (-not $mapped.Contains($key)) {
      return $false
    }
  }

  return $true
}

function Test-ComposerInputRequestOperationIdsPresent {
  param(
    [AllowNull()]$Artifact,
    [string[]]$EvidenceKeys
  )

  foreach ($key in $EvidenceKeys) {
    $item = Find-EvidenceItem -Artifact $Artifact -EvidenceKey $key
    if ($null -eq $item) {
      return $false
    }
    $requestId = [string](Get-PropertyValue -Object $item -Name "request_id")
    $operationId = [string](Get-PropertyValue -Object $item -Name "operation_id")
    $evidenceId = [string](Get-PropertyValue -Object $item -Name "evidence_id")
    if ([string]::IsNullOrWhiteSpace($requestId) -and [string]::IsNullOrWhiteSpace($operationId) -and [string]::IsNullOrWhiteSpace($evidenceId)) {
      return $false
    }
  }

  return $true
}

function Test-ReadbackRequestOperationHandoffPresent {
  param([AllowNull()]$Artifact)

  $gatewayArtifact = Get-PropertyValue -Object $Artifact -Name "gateway_artifact"
  if ($null -eq $gatewayArtifact) {
    return $false
  }
  return [bool](Get-PropertyValue -Object $gatewayArtifact -Name "request_ids_present") -and
    [bool](Get-PropertyValue -Object $gatewayArtifact -Name "operation_ids_present")
}

function Get-ArtifactNotPassedBlockers {
  param(
    [AllowNull()]$Artifact,
    [Parameter(Mandatory = $true)][string]$Prefix
  )

  $status = [string](Get-PropertyValue -Object $Artifact -Name "overall_status")
  if ([string]::IsNullOrWhiteSpace($status)) {
    $status = [string](Get-PropertyValue -Object $Artifact -Name "status")
  }
  if (@("passed", "pass", "accepted", "accepted_shape") -contains $status.Trim().ToLowerInvariant()) {
    return @()
  }

  $blockers = @("${Prefix}_not_passed")
  foreach ($item in (ConvertTo-JsonList (Get-PropertyValue -Object $Artifact -Name "blockers"))) {
    if (-not [string]::IsNullOrWhiteSpace([string]$item)) {
      $blockers += [string]$item
    }
  }
  foreach ($item in (ConvertTo-JsonList (Get-PropertyValue -Object $Artifact -Name "refusal_reasons"))) {
    if (-not [string]::IsNullOrWhiteSpace([string]$item)) {
      $blockers += [string]$item
    }
  }
  return @($blockers | Select-Object -Unique)
}

function Get-ReadinessEvidenceMap {
  param([AllowNull()]$Artifact)

  $map = [ordered]@{}
  foreach ($name in $requiredEvidence) {
    $map[$name] = $false
  }
  if ($null -eq $Artifact) {
    return ,$map
  }
  $readiness = Get-PropertyValue -Object $Artifact -Name "readiness_evidence"
  if ($null -ne $readiness) {
    foreach ($name in $requiredEvidence) {
      if ((Get-PropertyNames $readiness) -contains $name) {
        $map[$name] = [bool](Get-PropertyValue -Object $readiness -Name $name)
      }
    }
  }
  foreach ($item in (Get-EvidenceItems $Artifact)) {
    $key = ([string](Get-PropertyValue -Object $item -Name "evidence_key")).Trim()
    if (@($requiredEvidence) -contains $key) {
      $map[$key] = ([string](Get-PropertyValue -Object $item -Name "status") -eq "passed") -and
        [bool](Get-PropertyValue -Object $item -Name "passed")
    }
  }
  foreach ($name in $requiredEvidence) {
    if ((Get-PropertyNames $Artifact) -contains $name) {
      $map[$name] = [bool]$map[$name] -or (Test-EvidencePassed (Get-PropertyValue -Object $Artifact -Name $name))
    }
  }
  return ,$map
}

function Find-EvidenceItem {
  param(
    [AllowNull()]$Artifact,
    [Parameter(Mandatory = $true)][string]$EvidenceKey
  )
  foreach ($item in (Get-EvidenceItems $Artifact)) {
    if (([string](Get-PropertyValue -Object $item -Name "evidence_key")).Trim() -eq $EvidenceKey) {
      return $item
    }
  }
  return $null
}

function New-BundleEvidenceItem {
  param(
    [Parameter(Mandatory = $true)][string]$EvidenceKey,
    [Parameter(Mandatory = $true)][string]$SourceKind,
    [AllowNull()]$SourceArtifact,
    [AllowNull()]$SourceItem
  )

  $artifactId = [string](Get-PropertyValue -Object $SourceArtifact -Name "artifact_id")
  if ([string]::IsNullOrWhiteSpace($artifactId)) {
    $artifactId = [string](Get-PropertyValue -Object $SourceArtifact -Name "bundle_id")
  }
  if ([string]::IsNullOrWhiteSpace($artifactId)) {
    $artifactId = $SourceKind
  }

  $generatedAt = [string](Get-PropertyValue -Object $SourceItem -Name "generated_at_utc")
  if ([string]::IsNullOrWhiteSpace($generatedAt)) {
    $generatedAt = [string](Get-PropertyValue -Object $SourceArtifact -Name "generated_at_utc")
  }
  if ([string]::IsNullOrWhiteSpace($generatedAt)) {
    $generatedAt = (Get-Date).ToUniversalTime().ToString("o")
  }

  $requestId = [string](Get-PropertyValue -Object $SourceItem -Name "request_id")
  $operationId = [string](Get-PropertyValue -Object $SourceItem -Name "operation_id")
  $evidenceId = [string](Get-PropertyValue -Object $SourceItem -Name "evidence_id")
  if ([string]::IsNullOrWhiteSpace($evidenceId)) {
    $evidenceId = "${artifactId}:$EvidenceKey"
  }

  $operation = [string](Get-PropertyValue -Object $SourceItem -Name "operation")
  if ([string]::IsNullOrWhiteSpace($operation)) {
    $operation = [string](Get-PropertyValue -Object $SourceItem -Name "scenario")
  }
  if ([string]::IsNullOrWhiteSpace($operation)) {
    $operation = $EvidenceKey
  }
  $source = [string](Get-PropertyValue -Object $SourceItem -Name "source")
  if ([string]::IsNullOrWhiteSpace($source)) {
    $source = "compose_billing_paid_evidence_bundle:$SourceKind"
  }
  $scenario = [string](Get-PropertyValue -Object $SourceItem -Name "scenario")
  if ([string]::IsNullOrWhiteSpace($scenario)) {
    $scenario = "composed from $SourceKind artifact for paid controlled beta readiness"
  }

  $item = [ordered]@{
    evidence_key = $EvidenceKey
    status = "passed"
    passed = $true
    evidence_id = $evidenceId
    request_id = $requestId
    operation_id = $operationId
    operation = $operation
    scenario = $scenario
    generated_at_utc = $generatedAt
    source = $source
    composed_source_kind = $SourceKind
  }
  foreach ($name in @(
      "ledger_entry_id",
      "reserve_ledger_entry_id",
      "settle_ledger_entry_id",
      "refund_ledger_entry_id",
      "related_settle_ledger_entry_id",
      "refund_operation_id",
      "refund_idempotency_key",
      "expected_idempotency_key"
    )) {
    $value = [string](Get-PropertyValue -Object $SourceItem -Name $name)
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      $item[$name] = $value
    }
  }
  return $item
}

function Get-MissingFromMap {
  param(
    [object]$Map,
    [string[]]$Keys
  )
  if ($Map -is [System.Array] -and $Map.Count -eq 1) {
    $Map = $Map[0]
  }
  $missing = @()
  foreach ($key in $Keys) {
    $value = $false
    if ($null -ne $Map) {
      if ($Map -is [System.Collections.IDictionary] -and $Map.Contains($key)) {
        $value = [bool]$Map[$key]
      } elseif ((Get-PropertyNames $Map) -contains $key) {
        $value = [bool](Get-PropertyValue -Object $Map -Name $key)
      }
    }
    if (-not $value) {
      $missing += $key
    }
  }
  return @($missing)
}

function New-PublicArtifactSummary {
  param([AllowNull()]$Artifact)

  if ($null -eq $Artifact) {
    return [ordered]@{
      exists = $false
      path_bounded = $false
      path_output = "omitted"
      relative_path_output = "omitted"
      blockers = @()
      secret_safe = $false
      synthetic_or_fixture = $false
    }
  }

  [ordered]@{
    exists = [bool]$Artifact.exists
    path_bounded = [bool]$Artifact.path_bounded
    path_output = "omitted"
    relative_path_output = "omitted"
    blockers = ConvertTo-JsonList $Artifact.blockers
    secret_safe = [bool]$Artifact.secret_safe
    synthetic_or_fixture = [bool]$Artifact.synthetic_or_fixture
  }
}

function New-BlockedSummary {
  param(
    [string[]]$Blockers,
    [object]$GatewayArtifact,
    [object]$ControlPlaneArtifact,
    [object]$OutputPath
  )

  [ordered]@{
    schema_version = "billing_paid_evidence_bundle_composer.v1"
    script = "scripts/compose_billing_paid_evidence_bundle.ps1"
    overall_status = "blocked"
    paid_controlled_beta_requested = $true
    paid_controlled_beta_production_ready = $false
    output_bundle_written = $false
    blockers = ConvertTo-JsonList $Blockers
    gateway_paid_hot_path_artifact = New-PublicArtifactSummary $GatewayArtifact
    control_plane_paid_readback_artifact = New-PublicArtifactSummary $ControlPlaneArtifact
    output_bundle = $OutputPath
    secret_safe = [ordered]@{
      raw_secret_present = $false
      credential_material_echoed = $false
      database_url_echoed = $false
      env_value_echoed = $false
      raw_input_output = "omitted"
      raw_path_output = "omitted"
      secret_safe = $true
    }
    side_effects = [ordered]@{
      network_io_performed = $false
      db_io_performed = $false
      gateway_hot_path_modified = $false
      control_plane_modified = $false
    }
    exit_code_contract = [ordered]@{
      composed_exit_code = 0
      blocked_exit_code = $BlockedExitCode
      actual_exit_code = $BlockedExitCode
    }
  }
}

function Invoke-Compose {
  param(
    [Parameter(Mandatory = $true)][string]$GatewayPath,
    [Parameter(Mandatory = $true)][string]$ControlPlanePath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [switch]$AllowFixturePath
  )

  $gateway = Read-Artifact -Path $GatewayPath -MissingCode "gateway_paid_hot_path_artifact_missing" -AllowFixturePath:$AllowFixturePath
  $control = Read-Artifact -Path $ControlPlanePath -MissingCode "control_plane_paid_readback_artifact_missing" -AllowFixturePath:$AllowFixturePath
  $output = Resolve-RepoBoundedPath -Path $OutputPath -AllowFixturePath:$false
  $outputSummary = [ordered]@{
    path_bounded = $true
    path_output = "omitted"
    relative_path = $output.relative
  }

  $blockers = @()
  $blockers += @($gateway.blockers)
  $blockers += @($control.blockers)
  if ([bool]$gateway.exists -and -not [bool]$gateway.secret_safe) {
    $blockers += "gateway_paid_hot_path_artifact_secret_unsafe"
  }
  if ([bool]$control.exists -and -not [bool]$control.secret_safe) {
    $blockers += "control_plane_paid_readback_artifact_secret_unsafe"
  }

  if ($blockers.Count -gt 0) {
    if (Test-Path -LiteralPath $output.full -PathType Leaf) {
      Remove-Item -LiteralPath $output.full -Force
    }
    return [ordered]@{
      summary = New-BlockedSummary -Blockers ($blockers | Select-Object -Unique) -GatewayArtifact $gateway -ControlPlaneArtifact $control -OutputPath $outputSummary
      exit_code = $BlockedExitCode
    }
  }

  $gatewayEvidenceMappingPresent = Test-ComposerInputEvidenceMappingPresent -Artifact $gateway.json -EvidenceKeys $gatewayEvidence
  $gatewayRequestOperationIdsPresent = Test-ComposerInputRequestOperationIdsPresent -Artifact $gateway.json -EvidenceKeys $gatewayEvidence
  if (-not $gatewayEvidenceMappingPresent -or -not $gatewayRequestOperationIdsPresent) {
    $shapeBlockers = @()
    if (-not $gatewayEvidenceMappingPresent) {
      $shapeBlockers += "gateway_paid_hot_path_evidence_mapping_missing"
    }
    if (-not $gatewayRequestOperationIdsPresent) {
      $shapeBlockers += "gateway_paid_hot_path_request_or_operation_ids_missing"
    }
    if (Test-Path -LiteralPath $output.full -PathType Leaf) {
      Remove-Item -LiteralPath $output.full -Force
    }
    return [ordered]@{
      summary = New-BlockedSummary -Blockers $shapeBlockers -GatewayArtifact $gateway -ControlPlaneArtifact $control -OutputPath $outputSummary
      exit_code = $BlockedExitCode
    }
  }

  $gatewayNotPassedBlockers = @(Get-ArtifactNotPassedBlockers -Artifact $gateway.json -Prefix "gateway_paid_hot_path")
  if ($gatewayNotPassedBlockers.Count -gt 0) {
    if (Test-Path -LiteralPath $output.full -PathType Leaf) {
      Remove-Item -LiteralPath $output.full -Force
    }
    return [ordered]@{
      summary = New-BlockedSummary -Blockers $gatewayNotPassedBlockers -GatewayArtifact $gateway -ControlPlaneArtifact $control -OutputPath $outputSummary
      exit_code = $BlockedExitCode
    }
  }

  $controlEvidenceMappingPresent = Test-ComposerInputEvidenceMappingPresent -Artifact $control.json -EvidenceKeys $controlPlaneEvidence
  $controlRequestOperationIdsPresent = (Test-ComposerInputRequestOperationIdsPresent -Artifact $control.json -EvidenceKeys $controlPlaneEvidence) -or
    (Test-ReadbackRequestOperationHandoffPresent -Artifact $control.json)
  if (-not $controlEvidenceMappingPresent -or -not $controlRequestOperationIdsPresent) {
    $shapeBlockers = @()
    if (-not $controlEvidenceMappingPresent) {
      $shapeBlockers += "control_plane_paid_readback_evidence_mapping_missing"
    }
    if (-not $controlRequestOperationIdsPresent) {
      $shapeBlockers += "control_plane_paid_readback_request_or_operation_ids_missing"
    }
    if (Test-Path -LiteralPath $output.full -PathType Leaf) {
      Remove-Item -LiteralPath $output.full -Force
    }
    return [ordered]@{
      summary = New-BlockedSummary -Blockers $shapeBlockers -GatewayArtifact $gateway -ControlPlaneArtifact $control -OutputPath $outputSummary
      exit_code = $BlockedExitCode
    }
  }

  $controlNotPassedBlockers = @(Get-ArtifactNotPassedBlockers -Artifact $control.json -Prefix "control_plane_paid_readback")
  if ($controlNotPassedBlockers.Count -gt 0) {
    if (Test-Path -LiteralPath $output.full -PathType Leaf) {
      Remove-Item -LiteralPath $output.full -Force
    }
    return [ordered]@{
      summary = New-BlockedSummary -Blockers $controlNotPassedBlockers -GatewayArtifact $gateway -ControlPlaneArtifact $control -OutputPath $outputSummary
      exit_code = $BlockedExitCode
    }
  }

  $gatewayMap = Get-ReadinessEvidenceMap $gateway.json
  $controlMap = Get-ReadinessEvidenceMap $control.json
  $missingGateway = Get-MissingFromMap -Map $gatewayMap -Keys $gatewayEvidence
  $missingControl = Get-MissingFromMap -Map $controlMap -Keys $controlPlaneEvidence
  $missing = @($missingGateway + $missingControl | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  $syntheticOrFixture = [bool]$gateway.synthetic_or_fixture -or [bool]$control.synthetic_or_fixture -or [bool]$AllowFixturePath
  $contractShapeOnly = $syntheticOrFixture -or
    [bool](Get-PropertyValue -Object $gateway.json -Name "contract_shape_only") -or
    [bool](Get-PropertyValue -Object $control.json -Name "contract_shape_only")
  $productionHotPathClaim = (-not $syntheticOrFixture) -and (-not $contractShapeOnly) -and $missing.Count -eq 0
  $productionReady = $productionHotPathClaim

  $evidenceItems = New-Object System.Collections.Generic.List[object]
  foreach ($key in $gatewayEvidence) {
    if ([bool]$gatewayMap[$key]) {
      [void]$evidenceItems.Add((New-BundleEvidenceItem -EvidenceKey $key -SourceKind "gateway_paid_hot_path" -SourceArtifact $gateway.json -SourceItem (Find-EvidenceItem -Artifact $gateway.json -EvidenceKey $key)))
    }
  }
  foreach ($key in $controlPlaneEvidence) {
    if ([bool]$controlMap[$key]) {
      [void]$evidenceItems.Add((New-BundleEvidenceItem -EvidenceKey $key -SourceKind "control_plane_paid_readback" -SourceArtifact $control.json -SourceItem (Find-EvidenceItem -Artifact $control.json -EvidenceKey $key)))
    }
  }

  $bundle = [ordered]@{
    schema_version = "billing_paid_strong_consistency_evidence_bundle.v1"
    bundle_id = if ($syntheticOrFixture) { "paid-evidence-composer-synthetic-selftest-v1" } else { "paid-evidence-composer-real-$(Get-Date -Format yyyyMMddHHmmss)" }
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    generated_by = "scripts/compose_billing_paid_evidence_bundle.ps1"
    environment_scope = if ($syntheticOrFixture) { "synthetic_selftest" } else { "paid_beta_candidate" }
    overall_status = if ($productionReady) { "accepted_contract_shape" } elseif ($missing.Count -gt 0) { "composed_incomplete" } elseif ($syntheticOrFixture) { "composed_synthetic_selftest" } elseif ($contractShapeOnly) { "composed_contract_shape_only" } else { "composed_real_candidate" }
    accepted_contract_shape = [bool]($missing.Count -eq 0)
    real_paid_evidence_bundle_accepted = [bool]$productionReady
    real_provenance = [bool]$productionReady
    non_synthetic = [bool](-not $syntheticOrFixture)
    production_hot_path_claim = [bool]$productionHotPathClaim
    contract_shape_only = [bool]$contractShapeOnly
    synthetic_selftest = [bool]$syntheticOrFixture
    paid_controlled_beta_production_ready = [bool]$productionReady
    source_artifacts = [ordered]@{
      gateway_paid_hot_path_artifact_path_output = "omitted"
      control_plane_paid_readback_artifact_path_output = "omitted"
      gateway_artifact_synthetic_or_fixture = [bool]$gateway.synthetic_or_fixture
      control_plane_artifact_synthetic_or_fixture = [bool]$control.synthetic_or_fixture
    }
    secret_safe = [ordered]@{
      raw_secret_present = $false
      credential_material_echoed = $false
      database_url_echoed = $false
      env_value_echoed = $false
    }
    evidence = @($evidenceItems.ToArray())
  }

  if ($missing.Count -gt 0) {
    $bundle.contract_shape_only = $true
    $bundle.paid_controlled_beta_production_ready = $false
  }

  $outputDirectory = Split-Path -Parent $output.full
  if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
  }
  $bundle | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $output.full -Encoding UTF8

  $status = if ($missing.Count -gt 0) {
    "composed_incomplete"
  } elseif ($syntheticOrFixture) {
    "composed_synthetic_selftest"
  } elseif ($contractShapeOnly) {
    "composed_contract_shape_only"
  } else {
    "composed_real_candidate"
  }
  $exitCode = if ($missing.Count -gt 0) { 1 } else { 0 }
  $summary = [ordered]@{
    schema_version = "billing_paid_evidence_bundle_composer.v1"
    script = "scripts/compose_billing_paid_evidence_bundle.ps1"
    overall_status = $status
    paid_controlled_beta_requested = $true
    paid_controlled_beta_production_ready = [bool]$productionReady
    contract_shape_only = [bool]$bundle.contract_shape_only
    synthetic_selftest = [bool]$bundle.synthetic_selftest
    output_bundle_written = $true
    required_evidence = @($requiredEvidence)
    missing_evidence = ConvertTo-JsonList $missing
    gateway_paid_hot_path_artifact = New-PublicArtifactSummary $gateway
    control_plane_paid_readback_artifact = New-PublicArtifactSummary $control
    output_bundle = $outputSummary
    blockers = ConvertTo-JsonList @()
    warnings = ConvertTo-JsonList $(if ($syntheticOrFixture) { @("synthetic_or_fixture_inputs_not_release_artifact") } else { @() })
    secret_safe = [ordered]@{
      raw_secret_present = $false
      credential_material_echoed = $false
      database_url_echoed = $false
      env_value_echoed = $false
      raw_input_output = "omitted"
      raw_path_output = "omitted"
      secret_safe = $true
    }
    side_effects = [ordered]@{
      network_io_performed = $false
      db_io_performed = $false
      gateway_hot_path_modified = $false
      control_plane_modified = $false
    }
    exit_code_contract = [ordered]@{
      composed_exit_code = 0
      incomplete_exit_code = 1
      blocked_exit_code = $BlockedExitCode
      actual_exit_code = $exitCode
    }
  }

  return [ordered]@{
    summary = $summary
    exit_code = $exitCode
  }
}

function Invoke-SelfTest {
  $selftestRoot = Join-Path $repoRoot ".tmp\billing-ledger\composer-selftest"
  New-Item -ItemType Directory -Force -Path $selftestRoot | Out-Null
  $output = Join-Path $selftestRoot "paid-evidence-bundle.synthetic.json"
  $missingOutput = Join-Path $selftestRoot "missing-output.json"
  if (Test-Path -LiteralPath $output) {
    Remove-Item -LiteralPath $output -Force
  }
  if (Test-Path -LiteralPath $missingOutput) {
    Remove-Item -LiteralPath $missingOutput -Force
  }

  $missing = Invoke-Compose `
    -GatewayPath ".tmp\billing-ledger\composer-selftest\missing-gateway.json" `
    -ControlPlanePath ".tmp\billing-ledger\composer-selftest\missing-control.json" `
    -OutputPath ".tmp\billing-ledger\composer-selftest\missing-output.json"
  if ($missing.exit_code -ne $BlockedExitCode) {
    throw "missing input selftest did not block"
  }
  if (@($missing.summary.blockers) -notcontains "gateway_paid_hot_path_artifact_missing" -or
    @($missing.summary.blockers) -notcontains "control_plane_paid_readback_artifact_missing") {
    throw "missing input selftest did not report expected blockers"
  }
  if (Test-Path -LiteralPath $missingOutput) {
    throw "missing input selftest wrote output bundle"
  }

  $missingShape = Invoke-Compose `
    -GatewayPath "tests\fixtures\billing\paid_evidence_composer.gateway_passed_missing_required_shape.json" `
    -ControlPlanePath "tests\fixtures\billing\paid_evidence_composer.control_plane_real_shape_selftest.json" `
    -OutputPath ".tmp\billing-ledger\composer-selftest\missing-shape-output.json" `
    -AllowFixturePath
  if ($missingShape.exit_code -ne $BlockedExitCode) {
    throw "missing gateway shape selftest did not block"
  }
  if (@($missingShape.summary.blockers) -notcontains "gateway_paid_hot_path_evidence_mapping_missing" -or
    @($missingShape.summary.blockers) -notcontains "gateway_paid_hot_path_request_or_operation_ids_missing") {
    throw "missing gateway shape selftest did not report expected blockers"
  }

  $blockedReadback = Invoke-Compose `
    -GatewayPath "tests\fixtures\billing\paid_evidence_composer.gateway_real_shape_selftest.json" `
    -ControlPlanePath "tests\fixtures\billing\paid_evidence_composer.control_plane_shape_present_blocked_readback.json" `
    -OutputPath ".tmp\billing-ledger\composer-selftest\blocked-readback-output.json" `
    -AllowFixturePath
  if ($blockedReadback.exit_code -ne $BlockedExitCode) {
    throw "blocked readback shape selftest did not block"
  }
  if (@($blockedReadback.summary.blockers) -contains "control_plane_paid_readback_evidence_mapping_missing" -or
    @($blockedReadback.summary.blockers) -contains "control_plane_paid_readback_request_or_operation_ids_missing") {
    throw "blocked readback shape selftest incorrectly reported mapping blockers"
  }
  if (@($blockedReadback.summary.blockers) -notcontains "control_plane_paid_readback_sql_unavailable") {
    throw "blocked readback shape selftest did not report SQL/readback blocker"
  }

  $composed = Invoke-Compose `
    -GatewayPath "tests\fixtures\billing\paid_evidence_composer.gateway_real_shape_selftest.json" `
    -ControlPlanePath "tests\fixtures\billing\paid_evidence_composer.control_plane_real_shape_selftest.json" `
    -OutputPath ".tmp\billing-ledger\composer-selftest\paid-evidence-bundle.synthetic.json" `
    -AllowFixturePath
  if ($composed.exit_code -ne 0) {
    throw "synthetic real-shape selftest did not compose"
  }
  $bundle = Get-Content -Raw -LiteralPath $output | ConvertFrom-Json
  if (-not [bool]$bundle.synthetic_selftest) {
    throw "selftest bundle must be marked synthetic_selftest"
  }
  if ([bool]$bundle.paid_controlled_beta_production_ready) {
    throw "selftest bundle must not be production ready"
  }
  if (@($bundle.evidence).Count -ne 7) {
    throw "selftest bundle did not contain all seven evidence items"
  }

  [ordered]@{
    schema_version = "billing_paid_evidence_bundle_composer_selftest.v1"
    script = "scripts/compose_billing_paid_evidence_bundle.ps1"
    overall_status = "selftest_passed"
    cases = @(
      [ordered]@{
        name = "missing_inputs_blocked"
        exit_code = $missing.exit_code
        blockers = $missing.summary.blockers
        output_bundle_written = $false
      },
      [ordered]@{
        name = "synthetic_real_shape_inputs_compose_but_do_not_open_paid"
        exit_code = $composed.exit_code
        output_bundle_path_output = "omitted"
        synthetic_selftest = [bool]$bundle.synthetic_selftest
        paid_controlled_beta_production_ready = [bool]$bundle.paid_controlled_beta_production_ready
        evidence_count = @($bundle.evidence).Count
      },
      [ordered]@{
        name = "gateway_passed_missing_required_shape_blocked"
        exit_code = $missingShape.exit_code
        blockers = $missingShape.summary.blockers
        output_bundle_written = $false
      },
      [ordered]@{
        name = "control_plane_shape_present_but_readback_blocked"
        exit_code = $blockedReadback.exit_code
        blockers = $blockedReadback.summary.blockers
        output_bundle_written = $false
      }
    )
    artifacts_written = @("omitted:.tmp/billing-ledger/composer-selftest/paid-evidence-bundle.synthetic.json")
    side_effects = [ordered]@{
      network_io_performed = $false
      db_io_performed = $false
      gateway_hot_path_modified = $false
      control_plane_modified = $false
    }
    secret_safe = [ordered]@{
      raw_secret_present = $false
      credential_material_echoed = $false
      raw_input_output = "omitted"
      raw_path_output = "omitted"
      secret_safe = $true
    }
    exit_code_contract = [ordered]@{
      selftest_exit_code = 0
      actual_exit_code = 0
    }
  }
}

if ($SelfTest) {
  Invoke-SelfTest | ConvertTo-Json -Depth 16
  exit 0
}

try {
  $result = Invoke-Compose `
    -GatewayPath $GatewayPaidHotPathArtifactPath `
    -ControlPlanePath $ControlPlanePaidReadbackArtifactPath `
    -OutputPath $OutputBundlePath
  $result.summary | ConvertTo-Json -Depth 16
  exit ([int]$result.exit_code)
} catch {
  $summary = [ordered]@{
    schema_version = "billing_paid_evidence_bundle_composer.v1"
    script = "scripts/compose_billing_paid_evidence_bundle.ps1"
    overall_status = "blocked"
    paid_controlled_beta_requested = $true
    paid_controlled_beta_production_ready = $false
    output_bundle_written = $false
    blockers = @("path_safety_or_json_error_refused", [string]$_.Exception.Message)
    secret_safe = [ordered]@{
      raw_secret_present = $false
      credential_material_echoed = $false
      database_url_echoed = $false
      env_value_echoed = $false
      raw_input_output = "omitted"
      raw_path_output = "omitted"
      secret_safe = $true
    }
    side_effects = [ordered]@{
      network_io_performed = $false
      db_io_performed = $false
      gateway_hot_path_modified = $false
      control_plane_modified = $false
    }
    exit_code_contract = [ordered]@{
      composed_exit_code = 0
      blocked_exit_code = $BlockedExitCode
      actual_exit_code = $BlockedExitCode
    }
  }
  $summary | ConvertTo-Json -Depth 8
  exit $BlockedExitCode
}
