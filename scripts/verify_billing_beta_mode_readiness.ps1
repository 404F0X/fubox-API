param(
  [ValidateSet("usage_only_beta", "paid_controlled_beta")]
  [string]$BillingMode = "usage_only_beta",
  [string]$FixturePath,
  [string]$EvidencePath,
  [string]$PaidEvidenceBundlePath,
  [string]$OutputPath,
  [int]$BlockedExitCode = 2
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$defaultFixturePath = Join-Path $repoRoot "tests\fixtures\billing\billing_beta_mode_readiness_contract.json"
$effectiveFixturePath = if ([string]::IsNullOrWhiteSpace($FixturePath)) { $defaultFixturePath } else { $FixturePath }

$requiredEvidence = @(
  "gateway_hot_path_reserve_settle_refund",
  "insufficient_balance_prevents_provider_call",
  "settle_idempotency",
  "refund_idempotency",
  "post_commit_readback",
  "rollback_proof",
  "reconciliation_report"
)

function ConvertTo-EvidenceMap {
  param([object]$Evidence)

  $map = [ordered]@{}
  foreach ($name in $requiredEvidence) {
    $value = $false
    if ($null -ne $Evidence -and $null -ne $Evidence.PSObject.Properties[$name]) {
      $value = [bool]$Evidence.PSObject.Properties[$name].Value
    }
    $map[$name] = $value
  }
  return $map
}

function Get-MissingEvidence {
  param([hashtable]$Evidence)

  $missing = @()
  foreach ($name in $requiredEvidence) {
    if (-not [bool]$Evidence[$name]) {
      $missing += $name
    }
  }
  return @($missing)
}

function ConvertTo-JsonList {
  param([object]$Value)

  $list = [System.Collections.Generic.List[object]]::new()
  if ($null -eq $Value) {
    return ,$list
  }

  if ($Value -is [System.Array]) {
    foreach ($item in $Value) {
      [void]$list.Add($item)
    }
    return ,$list
  }

  [void]$list.Add($Value)
  return ,$list
}

function Resolve-ReadinessOutputPath {
  param([Parameter(Mandatory = $true)][string]$Path)

  $repoRootString = [System.IO.Path]::GetFullPath([string]$repoRoot)
  $candidate = if ([System.IO.Path]::IsPathRooted($Path)) {
    [System.IO.Path]::GetFullPath($Path)
  } else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRootString $Path))
  }
  $repoPrefix = $repoRootString.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  if (-not $candidate.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "output_path_must_stay_inside_repo"
  }

  $relative = $candidate.Substring($repoPrefix.Length).Replace("\", "/")
  if (-not ($relative.StartsWith(".tmp/", [System.StringComparison]::OrdinalIgnoreCase) -or
      $relative.StartsWith("artifacts/", [System.StringComparison]::OrdinalIgnoreCase))) {
    throw "output_path_must_be_under_tmp_or_artifacts"
  }
  if ([System.IO.Directory]::Exists($candidate)) {
    throw "output_path_must_be_file"
  }

  return [ordered]@{
    full_path = $candidate
    relative_path = $relative
  }
}

function Get-PowerShellExecutable {
  $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
  if ($pwsh) {
    return $pwsh.Source
  }

  $powershell = Get-Command powershell -ErrorAction SilentlyContinue
  if ($powershell) {
    return $powershell.Source
  }

  return ""
}

function Invoke-PaidEvidenceBundleVerifier {
  param([Parameter(Mandatory = $true)][string]$BundlePath)

  $ps = Get-PowerShellExecutable
  if ([string]::IsNullOrWhiteSpace($ps)) {
    return [ordered]@{
      verifier_available = $false
      verifier_exit_code = 127
      validation = $null
      error_code = "powershell_executable_missing"
    }
  }

  $verifierPath = Join-Path $PSScriptRoot "verify_billing_paid_evidence_bundle.ps1"
  $psArgs = @("-NoProfile")
  if ((Split-Path -Leaf $ps) -match '(?i)^powershell(\.exe)?$') {
    $psArgs += @("-ExecutionPolicy", "Bypass")
  }
  $psArgs += @("-File", $verifierPath, "-BundlePath", $BundlePath, "-BlockedExitCode", "2")

  $global:LASTEXITCODE = 0
  $output = @(& $ps @psArgs 2>&1)
  $exitCode = $global:LASTEXITCODE
  if ($null -eq $exitCode) {
    $exitCode = 0
  }

  $validation = $null
  try {
    $validation = ($output -join "`n") | ConvertFrom-Json
  } catch {
    return [ordered]@{
      verifier_available = $true
      verifier_exit_code = [int]$exitCode
      validation = $null
      error_code = "paid_evidence_bundle_validation_json_parse_failed"
    }
  }

  return [ordered]@{
    verifier_available = $true
    verifier_exit_code = [int]$exitCode
    validation = $validation
    error_code = "none"
  }
}

$fixture = $null
if (Test-Path -LiteralPath $effectiveFixturePath) {
  $fixture = Get-Content -Raw -LiteralPath $effectiveFixturePath | ConvertFrom-Json
}

$defaultEvidence = if ($null -ne $fixture -and $null -ne $fixture.default_evidence) {
  ConvertTo-EvidenceMap $fixture.default_evidence
} else {
  ConvertTo-EvidenceMap $null
}

$evidence = $defaultEvidence
if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
  $evidenceInput = Get-Content -Raw -LiteralPath $EvidencePath | ConvertFrom-Json
  $evidence = ConvertTo-EvidenceMap $evidenceInput
}

$paidBundleInvocation = $null
$paidBundleValidation = $null
$readinessEvidenceFromBundle = $null
$bundleProductionReady = $false
$bundleContractShapeOnly = $null
$bundleStatus = "not_provided"
if (-not [string]::IsNullOrWhiteSpace($PaidEvidenceBundlePath)) {
  $paidBundleInvocation = Invoke-PaidEvidenceBundleVerifier -BundlePath $PaidEvidenceBundlePath
  $paidBundleValidation = $paidBundleInvocation.validation
  if ($null -ne $paidBundleValidation) {
    $bundleStatus = [string]$paidBundleValidation.overall_status
    $bundleContractShapeOnly = [bool]$paidBundleValidation.contract_shape_only
    $bundleProductionReady = [bool]$paidBundleValidation.paid_controlled_beta_production_ready
    $readinessEvidenceFromBundle = ConvertTo-EvidenceMap $paidBundleValidation.readiness_evidence
    $evidence = $readinessEvidenceFromBundle
  } else {
    $bundleStatus = [string]$paidBundleInvocation.error_code
    $readinessEvidenceFromBundle = ConvertTo-EvidenceMap $null
    $evidence = $readinessEvidenceFromBundle
  }
}

$missingEvidence = @(Get-MissingEvidence $evidence)
$paidRequested = $BillingMode -eq "paid_controlled_beta"
$paidAllowed = $paidRequested -and $missingEvidence.Count -eq 0 -and $bundleProductionReady
$usageAllowed = $BillingMode -eq "usage_only_beta"
$decision = if ($usageAllowed) {
  "usage_only_beta_allowed"
} elseif ($paidAllowed) {
  "paid_controlled_beta_allowed"
} elseif ($paidRequested -and $missingEvidence.Count -eq 0) {
  "paid_controlled_beta_requested_blocked_not_production_ready"
} else {
  "paid_controlled_beta_refused_missing_evidence"
}
$blockers = if ($paidRequested -and -not $paidAllowed) {
  $items = @($missingEvidence)
  if (-not [string]::IsNullOrWhiteSpace($PaidEvidenceBundlePath)) {
    if ($null -eq $paidBundleValidation) {
      $items += "paid_evidence_bundle_validation_unavailable"
    } elseif (-not [bool]$paidBundleValidation.accepted_contract_shape) {
      $items += "paid_evidence_bundle_refused"
    } elseif ([bool]$paidBundleValidation.contract_shape_only) {
      $items += "paid_evidence_bundle_contract_shape_only_not_production_ready"
    } elseif (-not [bool]$paidBundleValidation.production_hot_path_claim) {
      $items += "paid_evidence_bundle_missing_production_hot_path_claim"
    } elseif ([bool]$paidBundleValidation.synthetic_selftest) {
      $items += "paid_evidence_bundle_synthetic_selftest_not_release_artifact"
    } elseif (-not [bool]$paidBundleValidation.paid_controlled_beta_production_ready) {
      $items += "paid_evidence_bundle_not_production_ready"
    }
  } else {
    $items += "paid_evidence_bundle_missing"
  }
  @($items | Select-Object -Unique)
} else {
  @()
}
$blockers = @($blockers)
$exitCode = if ($paidRequested -and -not $paidAllowed) {
  $BlockedExitCode
} else {
  0
}

$summary = [ordered]@{
  schema_version = "billing_beta_mode_readiness.v1"
  script = "scripts/verify_billing_beta_mode_readiness.ps1"
  billing_mode_requested = $BillingMode
  paid_controlled_beta_requested = $paidRequested
  usage_only_beta_allowed = $usageAllowed
  paid_controlled_beta_allowed = $paidAllowed
  required_evidence = @($requiredEvidence)
  evidence = $evidence
  missing_evidence = @($missingEvidence)
  paid_evidence_bundle_status = [ordered]@{
    provided = -not [string]::IsNullOrWhiteSpace($PaidEvidenceBundlePath)
    verifier_exit_code = if ($null -eq $paidBundleInvocation) { $null } else { [int]$paidBundleInvocation.verifier_exit_code }
    overall_status = $bundleStatus
    accepted_contract_shape = if ($null -eq $paidBundleValidation) { $false } else { [bool]$paidBundleValidation.accepted_contract_shape }
    contract_shape_only = if ($null -eq $bundleContractShapeOnly) { $null } else { [bool]$bundleContractShapeOnly }
    production_hot_path_claim = if ($null -eq $paidBundleValidation) { $false } else { [bool]$paidBundleValidation.production_hot_path_claim }
    synthetic_selftest = if ($null -eq $paidBundleValidation) { $false } else { [bool]$paidBundleValidation.synthetic_selftest }
    paid_controlled_beta_production_ready = $bundleProductionReady
    missing_evidence = if ($null -eq $paidBundleValidation) { ConvertTo-JsonList $null } else { ConvertTo-JsonList $paidBundleValidation.missing_evidence }
    invalid_evidence = if ($null -eq $paidBundleValidation) { ConvertTo-JsonList $null } else { ConvertTo-JsonList $paidBundleValidation.invalid_evidence }
    refusal_reasons = if ($null -eq $paidBundleValidation) { ConvertTo-JsonList $null } else { ConvertTo-JsonList $paidBundleValidation.refusal_reasons }
  }
  contract_shape_only = if ($null -eq $bundleContractShapeOnly) { $null } else { [bool]$bundleContractShapeOnly }
  paid_controlled_beta_production_ready = $bundleProductionReady
  readiness_evidence_from_bundle = if ($null -eq $readinessEvidenceFromBundle) { $null } else { $readinessEvidenceFromBundle }
  decision = $decision
  classification = if ($exitCode -eq 0) { "pass" } else { "blocked" }
  blockers = @($blockers)
  exit_code_contract = [ordered]@{
    usage_only_allowed_exit_code = 0
    paid_allowed_exit_code = 0
    paid_refused_missing_evidence_exit_code = $BlockedExitCode
    actual_exit_code = $exitCode
  }
  side_effects = [ordered]@{
    network_io_performed = $false
    db_io_performed = $false
    gateway_hot_path_modified = $false
    paid_mode_selected = $paidAllowed
  }
  secret_safe = [ordered]@{
    database_url_output = "omitted"
    env_value_output = "omitted"
    raw_path_output = "omitted"
    raw_secret_echoed = $false
    credential_material_echoed = $false
  }
  source = [ordered]@{
    fixture_loaded = $null -ne $fixture
    fixture_path_output = "omitted"
    evidence_path_output = "omitted"
    paid_evidence_bundle_path_output = "omitted"
    output_path_output = "omitted"
  }
}

$summaryJson = $summary | ConvertTo-Json -Depth 12
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
  $resolvedOutput = Resolve-ReadinessOutputPath -Path $OutputPath
  $outputDirectory = Split-Path -Parent $resolvedOutput.full_path
  if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
  }
  $summaryJson | Set-Content -LiteralPath $resolvedOutput.full_path -Encoding UTF8
}

$summaryJson
exit $exitCode
