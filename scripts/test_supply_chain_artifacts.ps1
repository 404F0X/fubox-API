#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$scriptPath = $PSCommandPath
if (-not $scriptPath) {
  $scriptPath = $MyInvocation.MyCommand.Path
}
$script:RepoRoot = (Resolve-Path (Join-Path (Split-Path -Parent $scriptPath) "..")).Path
$generator = Join-Path $script:RepoRoot "scripts/generate_supply_chain_artifacts.ps1"

function Get-PowerShellRunner {
  $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
  if ($pwsh) {
    return [pscustomobject]@{ Path = $pwsh.Source; IsWindowsPowerShell = $false }
  }

  $powershell = Get-Command powershell -ErrorAction SilentlyContinue
  if ($powershell) {
    return [pscustomobject]@{ Path = $powershell.Source; IsWindowsPowerShell = $true }
  }

  throw "No PowerShell runner found for supply-chain artifact self-test."
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

function Get-Sha256Digest {
  param([Parameter(Mandatory = $true)][string]$Path)

  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Write-Utf8NoBomFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Content
  )

  $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false
  [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

if (-not (Test-Path -LiteralPath $generator -PathType Leaf)) {
  throw ("Supply-chain artifact generator not found: {0}" -f $generator)
}

$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([char[]]@("\", "/"))
$tmpRoot = Join-Path $tempRoot ("ai-gateway-supply-chain-" + [guid]::NewGuid().ToString("N"))
$outputDir = Join-Path $tmpRoot "artifacts"
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

try {
  $runner = Get-PowerShellRunner
  $baseArguments = @("-NoLogo", "-NoProfile")
  if ($runner.IsWindowsPowerShell) {
    $baseArguments += @("-ExecutionPolicy", "Bypass")
  }
  $arguments = @($baseArguments + @("-File", $generator, "-OutputDirectory", $outputDir))

  $output = & $runner.Path @arguments 2>&1
  $exitCode = $LASTEXITCODE
  $lines = @($output | ForEach-Object { $_.ToString() })
  if ($exitCode -ne 0) {
    Write-Host ("[FAIL] supply-chain artifact generator exited with code {0}" -f $exitCode)
    $lines | Select-Object -Last 40 | ForEach-Object { Write-Host ("    {0}" -f $_) }
    exit $exitCode
  }

  $sbomPath = Join-Path $outputDir "sbom.cyclonedx.json"
  $provenancePath = Join-Path $outputDir "provenance.intoto.json"
  $summaryPath = Join-Path $outputDir "manifest.json"
  $checksumsPath = Join-Path $outputDir "SHA256SUMS"

  Assert-True (Test-Path -LiteralPath $sbomPath -PathType Leaf) "missing generated CycloneDX SBOM"
  Assert-True (Test-Path -LiteralPath $provenancePath -PathType Leaf) "missing generated provenance statement"
  Assert-True (Test-Path -LiteralPath $summaryPath -PathType Leaf) "missing generated artifact manifest"
  Assert-True (Test-Path -LiteralPath $checksumsPath -PathType Leaf) "missing generated SHA256SUMS"

  $sbomText = Get-Content -LiteralPath $sbomPath -Raw
  $provenanceText = Get-Content -LiteralPath $provenancePath -Raw
  $summaryText = Get-Content -LiteralPath $summaryPath -Raw
  $sbom = $sbomText | ConvertFrom-Json -ErrorAction Stop
  $provenance = $provenanceText | ConvertFrom-Json -ErrorAction Stop
  $summary = $summaryText | ConvertFrom-Json -ErrorAction Stop
  $allJson = $sbomText + $provenanceText + $summaryText

  Assert-True ([string]::Equals([string]$sbom.bomFormat, "CycloneDX", [System.StringComparison]::Ordinal)) "SBOM is not CycloneDX"
  Assert-True (@($sbom.components).Count -gt 0) "SBOM contains no components"
  Assert-True ([string]::Equals([string]$provenance.predicateType, "https://slsa.dev/provenance/v1", [System.StringComparison]::Ordinal)) "provenance predicate type is not SLSA v1"
  Assert-True ([string]::Equals([string]$provenance.predicate.buildDefinition.externalParameters.contractVersion, "supply-chain-artifacts/v1", [System.StringComparison]::Ordinal)) "provenance missing supply-chain artifact contract version"
  Assert-True ([bool]$provenance.predicate.buildDefinition.externalParameters.offline) "provenance does not mark the artifact generation as offline"
  Assert-True (@($provenance.predicate.buildDefinition.resolvedDependencies).Count -gt 0) "provenance contains no materials"
  Assert-True ([string]::Equals([string]$summary.schemaVersion, "supply-chain-artifacts/v1", [System.StringComparison]::Ordinal)) "manifest schema version is not the supply-chain artifact contract"
  Assert-True ([int]$summary.counts.components -eq @($sbom.components).Count) "summary component count does not match SBOM"
  Assert-True (-not ($allJson -match '(?i)placeholder')) "generated artifacts still contain placeholder text"

  $contract = $summary.contract
  Assert-True ($null -ne $contract) "manifest is missing the offline dry-run contract"
  Assert-True ([string]::Equals([string]$contract.kind, "supply-chain-offline-dry-run", [System.StringComparison]::Ordinal)) "manifest contract kind is unexpected"
  Assert-True ([int]$contract.version -eq 1) "manifest contract version is unexpected"
  foreach ($requiredArtifact in @("sbom.cyclonedx.json", "provenance.intoto.json", "manifest.json", "SHA256SUMS")) {
    Assert-True ((@($contract.requiredArtifacts) -contains $requiredArtifact)) ("manifest contract does not require {0}" -f $requiredArtifact)
  }
  Assert-True ((@($contract.coveredInputs.cargoLockFiles) -contains "Cargo.lock")) "manifest contract does not record Cargo.lock coverage"
  Assert-True (((@($contract.coveredInputs.npmLockFiles) | Where-Object { $_ -match 'package-lock\.json$' }).Count) -gt 0) "manifest contract does not record npm lockfile coverage"
  Assert-True (((@($contract.coveredInputs.containerFiles) | Where-Object { $_ -match '(Dockerfile|compose\.ya?ml)$' }).Count) -gt 0) "manifest contract does not record Dockerfile/Compose coverage"
  Assert-True ((@($contract.coveredInputs.ciWorkflowFiles) -contains ".github/workflows/ci.yml")) "manifest contract does not record CI workflow coverage"
  Assert-True ([string]$contract.localMissingToolPolicy -match 'warning/skip') "manifest contract does not preserve local missing-tool warning/skip policy"
  foreach ($remainingGap in @(
    "digest pinning is inspected but not enforced",
    "network-backed vulnerability scanning is skipped in offline dry-run mode",
    "real built image vulnerability scanning is not performed by this artifact generator"
  )) {
    Assert-True ((@($contract.remainingGaps) -contains $remainingGap)) ("manifest contract does not record remaining gap: {0}" -f $remainingGap)
  }

  $sbomDigest = Get-Sha256Digest $sbomPath
  $subject = @($provenance.subject | Where-Object { $_.name -eq "sbom.cyclonedx.json" } | Select-Object -First 1)
  Assert-True ($subject.Count -eq 1) "provenance does not identify the generated SBOM subject"
  Assert-True ([string]::Equals([string]$subject[0].digest.sha256, $sbomDigest, [System.StringComparison]::OrdinalIgnoreCase)) "provenance SBOM digest does not match file hash"

  $checksumLines = @(Get-Content -LiteralPath $checksumsPath)
  foreach ($file in @(Get-ChildItem -LiteralPath $outputDir -File | Where-Object { $_.Name -ne "SHA256SUMS" })) {
    $expected = "{0}  {1}" -f (Get-Sha256Digest $file.FullName), $file.Name
    Assert-True (($checksumLines -contains $expected)) ("SHA256SUMS missing or mismatched entry for {0}" -f $file.Name)
  }

  $planOutput = & $runner.Path @($baseArguments + @("-File", $generator, "-Plan")) 2>&1
  $planExitCode = $LASTEXITCODE
  if ($null -eq $planExitCode) {
    $planExitCode = 0
  }
  Assert-True ($planExitCode -eq 0) "manifest freshness plan exited non-zero"
  $plan = (($planOutput | ForEach-Object { $_.ToString() }) -join "`n") | ConvertFrom-Json -ErrorAction Stop
  Assert-True ([string]::Equals([string]$plan.schemaVersion, "manifest-freshness-plan/v1", [System.StringComparison]::Ordinal)) "plan schema version is unexpected"
  Assert-True ((@($plan.requiredArtifacts | ForEach-Object { $_.path }) -contains "sbom.cyclonedx.json")) "plan does not require SBOM"
  Assert-True ((@($plan.sourceFiles) -contains "Cargo.lock")) "plan does not include Cargo.lock as a source file"
  Assert-True (((@($plan.stalenessRules) | Where-Object { $_.id -eq "operator_evidence_not_implied" }).Count) -eq 1) "plan does not preserve operator evidence boundary"
  Assert-True ([string]$plan.purpose -match "does not execute clean-clone") "plan purpose does not state clean-clone boundary"

  $templatePath = Join-Path $outputDir "manifest.freshness.template.json"
  $templateOutput = & $runner.Path @($baseArguments + @("-File", $generator, "-Plan", "-WriteManifestTemplate", $templatePath)) 2>&1
  $templateExitCode = $LASTEXITCODE
  if ($null -eq $templateExitCode) {
    $templateExitCode = 0
  }
  Assert-True ($templateExitCode -eq 0) "manifest freshness template write exited non-zero"
  Assert-True (Test-Path -LiteralPath $templatePath -PathType Leaf) "manifest freshness template was not written"
  $template = (Get-Content -LiteralPath $templatePath -Raw) | ConvertFrom-Json -ErrorAction Stop
  Assert-True ([string]::Equals([string]$template.schemaVersion, "manifest-freshness-plan/v1", [System.StringComparison]::Ordinal)) "manifest freshness template schema is unexpected"

  $gateOutput = & $runner.Path @($baseArguments + @("-File", $generator, "-OutputDirectory", $outputDir, "-CheckManifestFreshness", $templatePath, "-DryRunGate")) 2>&1
  $gateExitCode = $LASTEXITCODE
  if ($null -eq $gateExitCode) {
    $gateExitCode = 0
  }
  Assert-True ($gateExitCode -eq 0) "manifest freshness dry-run gate accepted path exited non-zero"
  $gate = (($gateOutput | ForEach-Object { $_.ToString() }) -join "`n") | ConvertFrom-Json -ErrorAction Stop
  Assert-True ([string]::Equals([string]$gate.schemaVersion, "manifest-freshness-dry-run-gate/v1", [System.StringComparison]::Ordinal)) "manifest freshness dry-run gate schema is unexpected"
  Assert-True ([string]::Equals([string]$gate.classification, "accepted", [System.StringComparison]::Ordinal)) "manifest freshness dry-run gate did not accept matching template"
  Assert-True ([bool]$gate.accepted) "manifest freshness dry-run gate did not mark accepted=true"
  Assert-True ([bool]$gate.dryRunOnly) "manifest freshness dry-run gate must be dry-run only"
  Assert-True (-not [bool]$gate.releaseEvidenceClosure) "manifest freshness dry-run gate must not close release evidence"
  Assert-True (-not [bool]$gate.fullSbomApproval) "manifest freshness dry-run gate must not approve full SBOM"
  Assert-True (-not [bool]$gate.cleanCloneExecuted) "manifest freshness dry-run gate must not execute clean clone"
  Assert-True ([bool]$gate.readback.requiredArtifacts.match) "manifest freshness dry-run gate required artifact readback did not match"
  Assert-True ([bool]$gate.readback.sourceFiles.match) "manifest freshness dry-run gate source file readback did not match"
  Assert-True ([bool]$gate.readback.sourceFileGroups.groupNames.match) "manifest freshness dry-run gate source group names did not match"
  Assert-True ([bool]$gate.readback.stalenessRules.match) "manifest freshness dry-run gate staleness rules did not match"
  Assert-True ((@($gate.reasons.accepted | ForEach-Object { [string]$_.code }) -contains "manifest_freshness_contract_matches")) "manifest freshness dry-run gate missing accepted reason"

  $pendingOutput = & $runner.Path @($baseArguments + @("-File", $generator, "-OutputDirectory", $outputDir, "-DryRunGate")) 2>&1
  $pendingExitCode = $LASTEXITCODE
  if ($null -eq $pendingExitCode) {
    $pendingExitCode = 0
  }
  Assert-True ($pendingExitCode -eq 0) "manifest freshness dry-run gate pending path exited non-zero"
  $pendingGate = (($pendingOutput | ForEach-Object { $_.ToString() }) -join "`n") | ConvertFrom-Json -ErrorAction Stop
  Assert-True ([string]::Equals([string]$pendingGate.classification, "pending", [System.StringComparison]::Ordinal)) "manifest freshness dry-run gate did not mark missing template as pending"
  Assert-True ((@($pendingGate.reasons.pending | ForEach-Object { [string]$_.code }) -contains "manifest_template_not_supplied")) "manifest freshness dry-run gate missing pending reason"

  $blockedTemplatePath = Join-Path $outputDir "manifest.freshness.blocked-template.json"
  $blockedTemplate = (Get-Content -LiteralPath $templatePath -Raw) | ConvertFrom-Json -ErrorAction Stop
  $blockedTemplate.sourceFiles = @()
  Write-Utf8NoBomFile -Path $blockedTemplatePath -Content (($blockedTemplate | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
  $blockedOutput = & $runner.Path @($baseArguments + @("-File", $generator, "-OutputDirectory", $outputDir, "-CheckManifestFreshness", $blockedTemplatePath, "-DryRunGate")) 2>&1
  $blockedExitCode = $LASTEXITCODE
  Assert-True ($blockedExitCode -eq 2) "manifest freshness dry-run gate blocked path did not exit 2"
  $blockedGate = (($blockedOutput | ForEach-Object { $_.ToString() }) -join "`n") | ConvertFrom-Json -ErrorAction Stop
  Assert-True ([string]::Equals([string]$blockedGate.classification, "blocked", [System.StringComparison]::Ordinal)) "manifest freshness dry-run gate did not block stale template"
  Assert-True ((@($blockedGate.reasons.blocked | ForEach-Object { [string]$_.code }) -contains "missing_source_files")) "manifest freshness dry-run gate missing blocked reason"

  Write-Host "[OK] supply-chain artifact self-test passed"
} finally {
  $resolvedTmpRoot = [System.IO.Path]::GetFullPath($tmpRoot)
  $allowedPrefix = $tempRoot + [System.IO.Path]::DirectorySeparatorChar + "ai-gateway-supply-chain-"
  if ($resolvedTmpRoot.StartsWith($allowedPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTmpRoot)) {
    Remove-Item -LiteralPath $resolvedTmpRoot -Recurse -Force
  }
}
