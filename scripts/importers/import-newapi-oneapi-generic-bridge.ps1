[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$InputPath,

  [ValidateSet("Auto", "NewApi", "OneApi", "SourceDryRun", "InternalMappingReport")]
  [string]$SourceKind = "Auto",

  [ValidateSet("ApplyPlan", "InternalMappingReport", "Both")]
  [string]$OutputKind = "ApplyPlan",

  [string]$ArtifactDir,

  [string]$ExistingStatePath,

  [string]$TenantId = "00000000-0000-0000-0000-000000000001",

  [switch]$DryRun = $true
)

$ErrorActionPreference = "Stop"

if (-not [bool]$DryRun) {
  throw "Only dry-run bridging is implemented. Re-run with -DryRun or omit the flag."
}

$scriptPath = $PSCommandPath
if (-not $scriptPath) {
  $scriptPath = $MyInvocation.MyCommand.Path
}

$script:RepoRoot = (Resolve-Path (Join-Path (Split-Path -Parent $scriptPath) "..\..")).Path
$script:ImporterDir = Split-Path -Parent $scriptPath
$script:NewApiDryRunScript = Join-Path $script:ImporterDir "import-newapi-dryrun.ps1"
$script:OneApiDryRunScript = Join-Path $script:ImporterDir "import-oneapi-dryrun.ps1"
$script:InternalMappingScript = Join-Path $script:ImporterDir "import-internal-mapping-report.ps1"
$script:ApplyPlanScript = Join-Path $script:ImporterDir "import-apply-plan.ps1"

if ([string]::IsNullOrWhiteSpace($ArtifactDir)) {
  $ArtifactDir = Join-Path $script:RepoRoot ".tmp\importers\newapi-oneapi-generic-bridge"
}

function Get-RepoRelativePath {
  param([Parameter(Mandatory = $true)][string]$Path)

  $trimChars = [char[]]@("\", "/")
  $root = [System.IO.Path]::GetFullPath($script:RepoRoot).TrimEnd($trimChars)
  $target = [System.IO.Path]::GetFullPath($Path)
  if ([string]::Equals($target, $root, [System.StringComparison]::OrdinalIgnoreCase)) {
    return "."
  }

  $rootWithSeparator = $root + [System.IO.Path]::DirectorySeparatorChar
  if ($target.StartsWith($rootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
    return ($target.Substring($rootWithSeparator.Length) -replace "\\", "/")
  }

  return ($target -replace "\\", "/")
}

function Get-PropertyValue {
  param(
    [object]$Object,
    [string[]]$Names,
    [object]$Default = $null
  )

  if ($null -eq $Object) {
    return $Default
  }

  if ($Object -is [System.Collections.IDictionary]) {
    foreach ($name in $Names) {
      if ($Object.Contains($name) -and $null -ne $Object[$name]) {
        return $Object[$name]
      }
    }
  }

  foreach ($name in $Names) {
    $property = $Object.PSObject.Properties | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
    if ($null -ne $property -and $null -ne $property.Value) {
      return $property.Value
    }
  }

  return $Default
}

function Convert-ToImportArray {
  param([AllowNull()][object]$Value)

  if ($null -eq $Value) {
    return @()
  }

  if ($Value -is [string]) {
    return @($Value)
  }

  if ($Value -is [System.Collections.IEnumerable]) {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($item in $Value) {
      $items.Add($item) | Out-Null
    }
    return @($items.ToArray())
  }

  return @($Value)
}

function Assert-NoSecretMaterial {
  param([string]$RawJson)

  $patterns = @(
    'sk-[A-Za-z0-9_-]+',
    '(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}',
    '(?i)(api[_-]?key|authorization|token|password)=([^<][^&\s"`]+)'
  )

  foreach ($pattern in $patterns) {
    if ($RawJson -match $pattern) {
      throw "Refusing to bridge output because it contains secret-like material matching $pattern."
    }
  }
}

function Read-JsonObject {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }

  try {
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8) | ConvertFrom-Json
  } catch {
    return $null
  }
}

function Write-JsonArtifact {
  param(
    [string]$Path,
    [string]$RawJson
  )

  $parent = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }

  Assert-NoSecretMaterial $RawJson
  Set-Content -LiteralPath $Path -Value $RawJson -Encoding UTF8
}

function Invoke-JsonScript {
  param(
    [string]$ScriptPath,
    [hashtable]$Arguments
  )

  if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    throw "Required importer script not found: $ScriptPath"
  }

  $output = & $ScriptPath @Arguments
  $raw = ($output | Out-String).Trim()
  if ([string]::IsNullOrWhiteSpace($raw)) {
    throw "Importer script produced no JSON output: $(Get-RepoRelativePath $ScriptPath)"
  }

  Assert-NoSecretMaterial $raw
  try {
    $parsed = $raw | ConvertFrom-Json
  } catch {
    throw "Importer script output was not JSON: $(Get-RepoRelativePath $ScriptPath). $($_.Exception.Message)"
  }

  return [pscustomobject]@{
    Raw = $raw
    Json = $parsed
  }
}

function Get-DetectedSourceKind {
  param(
    [string]$Path,
    [string]$RequestedKind
  )

  if ($RequestedKind -ne "Auto") {
    return $RequestedKind
  }

  $document = Read-JsonObject $Path
  if ($null -eq $document) {
    throw "SourceKind Auto can only inspect a JSON file. Pass -SourceKind NewApi or -SourceKind OneApi for directories or non-standard exports."
  }

  $importer = [string](Get-PropertyValue $document @("importer") "")
  switch ($importer) {
    "internal-mapping-report-dryrun" { return "InternalMappingReport" }
    "newapi-openai-compatible-dryrun" { return "SourceDryRun" }
    "oneapi-openai-compatible-dryrun" { return "SourceDryRun" }
  }

  $source = ([string](Get-PropertyValue $document @("source", "source_system") "")).ToLowerInvariant()
  if ($source -match "one[-_ ]?api") {
    return "OneApi"
  }
  if ($source -match "new[-_ ]?api") {
    return "NewApi"
  }

  if ($null -ne (Get-PropertyValue $document @("Channels", "Tokens") $null)) {
    return "OneApi"
  }

  if ($null -ne (Get-PropertyValue $document @("channels", "tokens", "providers") $null)) {
    return "NewApi"
  }

  throw "Unable to detect source kind. Pass -SourceKind NewApi, OneApi, SourceDryRun, or InternalMappingReport."
}

function Test-ProviderKeyHandoffContract {
  param([object]$Report)

  $contract = Get-PropertyValue $Report @("provider_key_handoff_contract") $null
  if ($null -eq $contract) {
    return
  }

  if ([bool](Get-PropertyValue $contract @("raw_material_allowed") $false)) {
    throw "Provider key handoff contract unexpectedly allows raw material."
  }

  if ([bool](Get-PropertyValue $contract @("apply_directly_supported") $false)) {
    throw "Provider key handoff contract unexpectedly allows direct apply."
  }
}

function Test-NoProviderKeyWriteOperations {
  param([object]$Plan)

  $writeTargets = @()
  $writeTargets += Convert-ToImportArray (Get-PropertyValue $Plan @("planned_creates") $null)
  $writeTargets += Convert-ToImportArray (Get-PropertyValue $Plan @("planned_updates") $null)
  foreach ($operation in $writeTargets) {
    $kind = [string](Get-PropertyValue (Get-PropertyValue $operation @("target") $operation) @("kind", "target_kind") "")
    if ($kind -match "provider_key|secret") {
      throw "Provider key or secret target appeared in planned write operations."
    }
  }

  foreach ($operationPlan in (Convert-ToImportArray (Get-PropertyValue (Get-PropertyValue (Get-PropertyValue $Plan @("sql_executor_plan") $null) @("transaction") $null) @("operation_plans") $null))) {
    $kind = [string](Get-PropertyValue (Get-PropertyValue $operationPlan @("target") $operationPlan) @("kind", "target_kind") "")
    if ($kind -match "provider_key|secret") {
      throw "Provider key or secret target appeared in SQL operation plans."
    }
  }
}

$resolvedInputPath = (Resolve-Path -LiteralPath $InputPath).Path
$resolvedArtifactDir = $ArtifactDir
New-Item -ItemType Directory -Force -Path $resolvedArtifactDir | Out-Null

$detectedKind = Get-DetectedSourceKind -Path $resolvedInputPath -RequestedKind $SourceKind
$sourceDryRunPath = $null
$internalMappingPath = $null
$applyPlanPath = $null
$sourceDryRun = $null
$internalMapping = $null
$applyPlan = $null

switch ($detectedKind) {
  "NewApi" {
    $sourceDryRun = Invoke-JsonScript $script:NewApiDryRunScript @{ InputPath = $resolvedInputPath; DryRun = $true }
    $sourceDryRunPath = Join-Path $resolvedArtifactDir "newapi-source-dryrun.generated.json"
    Write-JsonArtifact -Path $sourceDryRunPath -RawJson $sourceDryRun.Raw
  }
  "OneApi" {
    $sourceDryRun = Invoke-JsonScript $script:OneApiDryRunScript @{ InputPath = $resolvedInputPath; DryRun = $true }
    $sourceDryRunPath = Join-Path $resolvedArtifactDir "oneapi-source-dryrun.generated.json"
    Write-JsonArtifact -Path $sourceDryRunPath -RawJson $sourceDryRun.Raw
  }
  "SourceDryRun" {
    $sourceDryRunPath = $resolvedInputPath
  }
  "InternalMappingReport" {
    $internalMappingPath = $resolvedInputPath
  }
  default {
    throw "Unsupported source kind: $detectedKind"
  }
}

if ([string]::IsNullOrWhiteSpace($internalMappingPath)) {
  $internalMapping = Invoke-JsonScript $script:InternalMappingScript @{ InputPath = $sourceDryRunPath; DryRun = $true }
  $internalMappingPath = Join-Path $resolvedArtifactDir "internal-mapping-report-dryrun.generated.json"
  Write-JsonArtifact -Path $internalMappingPath -RawJson $internalMapping.Raw
} else {
  $internalMapping = [pscustomobject]@{
    Raw = (Get-Content -LiteralPath $internalMappingPath -Raw -Encoding UTF8).Trim()
    Json = Read-JsonObject $internalMappingPath
  }
  Assert-NoSecretMaterial $internalMapping.Raw
}

$internalImporter = [string](Get-PropertyValue $internalMapping.Json @("importer") "")
if ($internalImporter -ne "internal-mapping-report-dryrun") {
  throw "Bridge internal mapping stage expected internal-mapping-report-dryrun, got '$internalImporter'."
}
Test-ProviderKeyHandoffContract $internalMapping.Json

if ($OutputKind -ne "InternalMappingReport") {
  $applyArgs = @{
    InputPath = $internalMappingPath
    DryRun = $true
    TenantId = $TenantId
  }
  if (-not [string]::IsNullOrWhiteSpace($ExistingStatePath)) {
    $applyArgs["ExistingStatePath"] = (Resolve-Path -LiteralPath $ExistingStatePath).Path
  }

  $applyPlan = Invoke-JsonScript $script:ApplyPlanScript $applyArgs
  $applyPlanPath = Join-Path $resolvedArtifactDir "generic-apply-plan-dryrun.generated.json"
  Write-JsonArtifact -Path $applyPlanPath -RawJson $applyPlan.Raw
  Test-ProviderKeyHandoffContract $applyPlan.Json
  Test-NoProviderKeyWriteOperations $applyPlan.Json
}

switch ($OutputKind) {
  "InternalMappingReport" {
    Write-Output $internalMapping.Raw
  }
  "ApplyPlan" {
    Write-Output $applyPlan.Raw
  }
  "Both" {
    $manifest = [ordered]@{
      importer = "newapi-oneapi-generic-bridge-dryrun"
      dry_run = $true
      generated_at = (Get-Date).ToUniversalTime().ToString("o")
      source_kind = $detectedKind
      input_path = Get-RepoRelativePath $resolvedInputPath
      artifacts = [ordered]@{
        source_dryrun = if ([string]::IsNullOrWhiteSpace($sourceDryRunPath)) { $null } else { Get-RepoRelativePath $sourceDryRunPath }
        internal_mapping_report = Get-RepoRelativePath $internalMappingPath
        generic_apply_plan = if ([string]::IsNullOrWhiteSpace($applyPlanPath)) { $null } else { Get-RepoRelativePath $applyPlanPath }
      }
      counts = [ordered]@{
        canonical_models = [int](Get-PropertyValue (Get-PropertyValue $internalMapping.Json @("counts") $null) @("canonical_models") 0)
        model_associations = [int](Get-PropertyValue (Get-PropertyValue $internalMapping.Json @("counts") $null) @("model_associations") 0)
        channel_mappings = [int](Get-PropertyValue (Get-PropertyValue $internalMapping.Json @("counts") $null) @("channel_mappings") 0)
        provider_key_handoffs = [int](Get-PropertyValue (Get-PropertyValue $internalMapping.Json @("counts") $null) @("provider_key_handoffs") 0)
        planned_creates = if ($null -eq $applyPlan) { 0 } else { [int](Get-PropertyValue (Get-PropertyValue $applyPlan.Json @("counts") $null) @("planned_creates") 0) }
        planned_updates = if ($null -eq $applyPlan) { 0 } else { [int](Get-PropertyValue (Get-PropertyValue $applyPlan.Json @("counts") $null) @("planned_updates") 0) }
      }
      provider_key_secret_handling = [ordered]@{
        raw_material_allowed = $false
        apply_directly_supported = $false
        required_operator_path = "POST /admin/provider-keys"
      }
      next_steps = @(
        "Review the generated internal mapping report before apply.",
        "Use the generated generic apply plan for read-only planning; provider key material remains sidecar/manual review only."
      )
    }
    $rawManifest = $manifest | ConvertTo-Json -Depth 32
    Assert-NoSecretMaterial $rawManifest
    Write-Output $rawManifest
  }
}
