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

if (-not (Test-Path -LiteralPath $generator -PathType Leaf)) {
  throw ("Supply-chain artifact generator not found: {0}" -f $generator)
}

$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([char[]]@("\", "/"))
$tmpRoot = Join-Path $tempRoot ("ai-gateway-supply-chain-" + [guid]::NewGuid().ToString("N"))
$outputDir = Join-Path $tmpRoot "artifacts"
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

try {
  $runner = Get-PowerShellRunner
  $arguments = @("-NoLogo", "-NoProfile")
  if ($runner.IsWindowsPowerShell) {
    $arguments += @("-ExecutionPolicy", "Bypass")
  }
  $arguments += @("-File", $generator, "-OutputDirectory", $outputDir)

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

  Write-Host "[OK] supply-chain artifact self-test passed"
} finally {
  $resolvedTmpRoot = [System.IO.Path]::GetFullPath($tmpRoot)
  $allowedPrefix = $tempRoot + [System.IO.Path]::DirectorySeparatorChar + "ai-gateway-supply-chain-"
  if ($resolvedTmpRoot.StartsWith($allowedPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTmpRoot)) {
    Remove-Item -LiteralPath $resolvedTmpRoot -Recurse -Force
  }
}
