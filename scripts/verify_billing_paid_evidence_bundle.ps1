param(
  [Parameter(Mandatory = $true)]
  [string]$BundlePath,
  [int]$BlockedExitCode = 2
)

$ErrorActionPreference = "Stop"

$requiredEvidence = @(
  "gateway_hot_path_reserve_settle_refund",
  "insufficient_balance_prevents_provider_call",
  "settle_idempotency",
  "refund_idempotency",
  "post_commit_readback",
  "rollback_proof",
  "reconciliation_report"
)

function Test-Blank {
  param([AllowNull()][string]$Value)
  return [string]::IsNullOrWhiteSpace($Value)
}

function New-EvidenceMap {
  param([string[]]$AcceptedEvidence)

  $map = [ordered]@{}
  foreach ($name in $requiredEvidence) {
    $map[$name] = @($AcceptedEvidence) -contains $name
  }
  return $map
}

function Add-InvalidReason {
  param(
    [hashtable]$InvalidByKey,
    [string]$EvidenceKey,
    [string]$Reason
  )

  $key = if (Test-Blank $EvidenceKey) { "<blank>" } else { $EvidenceKey.Trim() }
  if (-not $InvalidByKey.ContainsKey($key)) {
    $InvalidByKey[$key] = New-Object System.Collections.Generic.List[string]
  }
  [void]$InvalidByKey[$key].Add($Reason)
}

function Test-SecretSafeText {
  param([string]$Text)

  if ([string]::IsNullOrEmpty($Text)) {
    return $true
  }

  $patterns = @(
    '(?i)authorization\s*[:=]',
    '(?i)bearer\s+[A-Za-z0-9._~+/\-]+=*',
    '(?i)api[_-]?key\s*[:=]',
    '(?i)provider[_-]?key\s*[:=]',
    '(?i)password\s*[:=]',
    'sk-[A-Za-z0-9]{8,}'
  )
  foreach ($pattern in $patterns) {
    if ($Text -match $pattern) {
      return $false
    }
  }

  return $true
}

$bundleText = Get-Content -Raw -LiteralPath $BundlePath
$bundle = $bundleText | ConvertFrom-Json
$accepted = New-Object System.Collections.Generic.List[string]
$seen = New-Object System.Collections.Generic.HashSet[string]
$invalidByKey = @{}
$refusals = New-Object System.Collections.Generic.List[string]

if ([string]$bundle.schema_version -ne "billing_paid_strong_consistency_evidence_bundle.v1") {
  [void]$refusals.Add("schema_version_mismatch")
}
if (Test-Blank ([string]$bundle.bundle_id)) {
  [void]$refusals.Add("bundle_id_missing")
}
if (Test-Blank ([string]$bundle.generated_at_utc)) {
  [void]$refusals.Add("bundle_generated_at_missing")
}
if (Test-Blank ([string]$bundle.generated_by)) {
  [void]$refusals.Add("bundle_generated_by_missing")
}

foreach ($item in @($bundle.evidence)) {
  $key = [string]$item.evidence_key
  $trimmedKey = $key.Trim()
  $itemInvalid = $false

  if (@($requiredEvidence) -notcontains $trimmedKey) {
    Add-InvalidReason -InvalidByKey $invalidByKey -EvidenceKey $key -Reason "unknown_evidence_key"
    $itemInvalid = $true
  }
  if (-not $seen.Add($trimmedKey)) {
    Add-InvalidReason -InvalidByKey $invalidByKey -EvidenceKey $key -Reason "duplicate_evidence_key"
    $itemInvalid = $true
  }
  if ([string]$item.status -ne "passed") {
    Add-InvalidReason -InvalidByKey $invalidByKey -EvidenceKey $key -Reason "evidence_status_not_passed"
    $itemInvalid = $true
  }
  if (-not [bool]$item.passed) {
    Add-InvalidReason -InvalidByKey $invalidByKey -EvidenceKey $key -Reason "evidence_passed_false"
    $itemInvalid = $true
  }
  if ((Test-Blank ([string]$item.evidence_id)) -and (Test-Blank ([string]$item.request_id))) {
    Add-InvalidReason -InvalidByKey $invalidByKey -EvidenceKey $key -Reason "evidence_id_or_request_id_missing"
    $itemInvalid = $true
  }
  if (Test-Blank ([string]$item.operation)) {
    Add-InvalidReason -InvalidByKey $invalidByKey -EvidenceKey $key -Reason "operation_missing"
    $itemInvalid = $true
  }
  if (Test-Blank ([string]$item.scenario)) {
    Add-InvalidReason -InvalidByKey $invalidByKey -EvidenceKey $key -Reason "scenario_missing"
    $itemInvalid = $true
  }
  if (Test-Blank ([string]$item.generated_at_utc)) {
    Add-InvalidReason -InvalidByKey $invalidByKey -EvidenceKey $key -Reason "evidence_generated_at_missing"
    $itemInvalid = $true
  }
  if (Test-Blank ([string]$item.source)) {
    Add-InvalidReason -InvalidByKey $invalidByKey -EvidenceKey $key -Reason "source_missing"
    $itemInvalid = $true
  }

  if (-not $itemInvalid) {
    [void]$accepted.Add($trimmedKey)
  }
}

$missing = @()
foreach ($name in $requiredEvidence) {
  if (@($accepted.ToArray()) -notcontains $name) {
    $missing += $name
  }
}

if ($missing.Count -gt 0) {
  [void]$refusals.Add("required_evidence_missing_or_invalid")
}
if ($invalidByKey.Count -gt 0) {
  [void]$refusals.Add("evidence_shape_invalid")
}

$secretFlags = [ordered]@{
  raw_secret_present = if ($null -eq $bundle.secret_safe.raw_secret_present) { $false } else { [bool]$bundle.secret_safe.raw_secret_present }
  credential_material_echoed = if ($null -eq $bundle.secret_safe.credential_material_echoed) { $false } else { [bool]$bundle.secret_safe.credential_material_echoed }
  database_url_echoed = if ($null -eq $bundle.secret_safe.database_url_echoed) { $false } else { [bool]$bundle.secret_safe.database_url_echoed }
  env_value_echoed = if ($null -eq $bundle.secret_safe.env_value_echoed) { $false } else { [bool]$bundle.secret_safe.env_value_echoed }
}
$textSecretSafe = Test-SecretSafeText $bundleText
$secretSafe = (-not [bool]$secretFlags.raw_secret_present) -and
  (-not [bool]$secretFlags.credential_material_echoed) -and
  (-not [bool]$secretFlags.database_url_echoed) -and
  (-not [bool]$secretFlags.env_value_echoed) -and
  $textSecretSafe
if (-not $secretSafe) {
  [void]$refusals.Add("secret_safe_contract_failed")
}

$invalidEvidence = @()
foreach ($key in @($invalidByKey.Keys | Sort-Object)) {
  $invalidEvidence += [ordered]@{
    evidence_key = $key
    reasons = @($invalidByKey[$key].ToArray())
  }
}

$acceptedEvidence = @($accepted.ToArray() | Sort-Object)
$acceptedContractShape = $refusals.Count -eq 0 -and $missing.Count -eq 0
$contractShapeOnly = if ($null -eq $bundle.contract_shape_only) { $true } else { [bool]$bundle.contract_shape_only }
$syntheticSelftest = if ($null -eq $bundle.synthetic_selftest) { $false } else { [bool]$bundle.synthetic_selftest }
$productionHotPathClaim = if ($null -eq $bundle.production_hot_path_claim) { $false } else { [bool]$bundle.production_hot_path_claim }
$bundleProductionReadyClaim = if ($null -eq $bundle.paid_controlled_beta_production_ready) { $false } else { [bool]$bundle.paid_controlled_beta_production_ready }
$paidControlledBetaProductionReady = $acceptedContractShape -and
  (-not $contractShapeOnly) -and
  (-not $syntheticSelftest) -and
  $productionHotPathClaim -and
  $bundleProductionReadyClaim -and
  $secretSafe
$exitCode = if ($acceptedContractShape) { 0 } else { $BlockedExitCode }

$summary = [ordered]@{
  schema_version = "billing_paid_strong_consistency_evidence_bundle_validation.v1"
  script = "scripts/verify_billing_paid_evidence_bundle.ps1"
  overall_status = if ($acceptedContractShape) { "accepted_contract_shape" } else { "refused" }
  accepted_contract_shape = $acceptedContractShape
  production_hot_path_claim = $productionHotPathClaim
  contract_shape_only = $contractShapeOnly
  synthetic_selftest = $syntheticSelftest
  paid_controlled_beta_production_ready = $paidControlledBetaProductionReady
  required_evidence = @($requiredEvidence)
  accepted_evidence = @($acceptedEvidence)
  missing_evidence = @($missing)
  invalid_evidence = @($invalidEvidence)
  refusal_reasons = @($refusals.ToArray() | Select-Object -Unique)
  readiness_evidence = (New-EvidenceMap -AcceptedEvidence $acceptedEvidence)
  secret_safe = [ordered]@{
    raw_secret_present = [bool]$secretFlags.raw_secret_present
    credential_material_echoed = [bool]$secretFlags.credential_material_echoed
    database_url_echoed = [bool]$secretFlags.database_url_echoed
    env_value_echoed = [bool]$secretFlags.env_value_echoed
    forbidden_secret_pattern_present = -not $textSecretSafe
    secret_safe = $secretSafe
    output_contains_raw_bundle = $false
  }
  side_effects = [ordered]@{
    network_io_performed = $false
    db_io_performed = $false
    gateway_hot_path_modified = $false
    paid_mode_selected = $false
  }
  source = [ordered]@{
    bundle_path_output = "omitted"
    raw_bundle_output = "omitted"
  }
  exit_code_contract = [ordered]@{
    accepted_contract_shape_exit_code = 0
    refused_exit_code = $BlockedExitCode
    actual_exit_code = $exitCode
  }
}

$summary | ConvertTo-Json -Depth 12
exit $exitCode
