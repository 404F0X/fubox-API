[CmdletBinding()]
param(
  [string]$ArtifactDir = ".tmp\importers\provider_key_secret_path"
)

$ErrorActionPreference = "Stop"

$scriptPath = $PSCommandPath
if (-not $scriptPath) {
  $scriptPath = $MyInvocation.MyCommand.Path
}

$script:RepoRoot = (Resolve-Path (Join-Path (Split-Path -Parent $scriptPath) "..\..")).Path
$script:NewApiScript = Join-Path $script:RepoRoot "scripts\importers\import-newapi-dryrun.ps1"
$script:OneApiScript = Join-Path $script:RepoRoot "scripts\importers\import-oneapi-dryrun.ps1"
$script:MappingScript = Join-Path $script:RepoRoot "scripts\importers\import-internal-mapping-report.ps1"
$script:ApplyPlanScript = Join-Path $script:RepoRoot "scripts\importers\import-apply-plan.ps1"
$script:NewApiFixture = Join-Path $script:RepoRoot "examples\importer_samples\new_api_openai_compatible.sample.json"
$script:OneApiFixture = Join-Path $script:RepoRoot "examples\importer_samples\one_api_openai_compatible.sample.json"
$script:ArtifactRoot = Join-Path $script:RepoRoot $ArtifactDir

function Assert-Condition {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) {
    throw "VERIFY FAILED: $Message"
  }
}

function Convert-ToArray {
  param([AllowNull()][object]$Value)

  if ($null -eq $Value) { return @() }
  if ($Value -is [string]) { return @($Value) }
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
  param(
    [string]$RawJson,
    [string]$Context
  )

  $patterns = @(
    'sk-[A-Za-z0-9_-]+',
    '(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}',
    '(?i)(api[_-]?key|authorization|token|password)=([^<][^&\s"`]+)'
  )

  foreach ($pattern in $patterns) {
    Assert-Condition (-not ($RawJson -match $pattern)) "$Context contains secret-like material matching $pattern"
  }
}

function Assert-RawLocatorsOmitted {
  param(
    [string]$RawJson,
    [string]$Context
  )

  $forbiddenLiterals = @(
    '${OPENAI_API_KEY}',
    'env:AZURE_OPENAI_API_KEY',
    'env:AZURE_OPENAI_SECONDARY_KEY',
    '${ONE_API_OPENAI_KEY}'
  )

  foreach ($literal in $forbiddenLiterals) {
    Assert-Condition (-not $RawJson.Contains($literal)) "$Context contains raw credential locator '$literal'"
  }
}

function Read-Json {
  param([string]$Path)
  return ((Get-Content -LiteralPath $Path -Raw -Encoding UTF8) | ConvertFrom-Json)
}

function Write-ArtifactText {
  param(
    [string]$Path,
    [string]$Content
  )

  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  Set-Content -LiteralPath $Path -Value $Content -Encoding UTF8
}

function Invoke-JsonScript {
  param(
    [string]$ScriptPath,
    [hashtable]$Arguments,
    [string]$OutputPath,
    [string]$Context
  )

  $output = & $ScriptPath @Arguments
  if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    throw "$Context exited with $LASTEXITCODE"
  }

  $raw = ($output | Out-String).Trim()
  Assert-Condition (-not [string]::IsNullOrWhiteSpace($raw)) "$Context emitted JSON"
  Assert-NoSecretMaterial $raw $Context
  Assert-RawLocatorsOmitted $raw $Context
  Write-ArtifactText $OutputPath $raw

  try {
    return ($raw | ConvertFrom-Json)
  } catch {
    throw "VERIFY FAILED: $Context output was not valid JSON. $($_.Exception.Message)"
  }
}

function Assert-ProviderKeyHandoffOnly {
  param(
    [object]$ApplyPlan,
    [string]$Context
  )

  Assert-Condition ($ApplyPlan.provider_key_handoff_contract.schema_version -eq "importer.provider-key-handoff-contract.v1") "$Context has provider key handoff contract"
  Assert-Condition ($ApplyPlan.provider_key_handoff_contract.raw_material_allowed -eq $false) "$Context handoff contract rejects raw material"
  Assert-Condition ($ApplyPlan.provider_key_handoff_contract.apply_directly_supported -eq $false) "$Context handoff contract rejects direct apply"
  Assert-Condition ($ApplyPlan.provider_key_handoff_contract.required_operator_path -eq "POST /admin/provider-keys") "$Context handoff contract names Control Plane secret path"

  $handoffs = @(Convert-ToArray $ApplyPlan.provider_key_handoffs)
  Assert-Condition ($handoffs.Count -gt 0) "$Context exposes provider key handoff metadata"
  foreach ($handoff in $handoffs) {
    Assert-Condition ([bool]$handoff.credential_material_present) "$Context handoff records credential presence"
    Assert-Condition ($handoff.raw_material_exported -eq $false) "$Context handoff raw material omitted"
    Assert-Condition ($handoff.provider_key_material_included -eq $false) "$Context handoff provider key material omitted"
    Assert-Condition ($handoff.apply_directly_supported -eq $false) "$Context handoff direct apply disabled"
    Assert-Condition ($handoff.apply_mode -eq "sidecar_only") "$Context handoff is sidecar-only"
    Assert-Condition ($handoff.recommended_path -eq "POST /admin/provider-keys") "$Context handoff points to provider key API"
    Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$handoff.credential_locator_redacted)) "$Context handoff locator is redacted"
    Assert-Condition (@(Convert-ToArray $handoff.credential_locator_hashes).Count -gt 0) "$Context handoff includes locator hash"
  }

  $writeTargets = @(Convert-ToArray $ApplyPlan.planned_creates) + @(Convert-ToArray $ApplyPlan.planned_updates)
  Assert-Condition (@($writeTargets | Where-Object { $_.target.kind -match "provider_key|secret" }).Count -eq 0) "$Context provider keys are not planned write targets"

  $operationPlans = @(Convert-ToArray $ApplyPlan.sql_executor_plan.transaction.operation_plans)
  Assert-Condition (@($operationPlans | Where-Object { $_.target.kind -match "provider_key|secret" }).Count -eq 0) "$Context provider keys are not SQL operation targets"
  Assert-Condition (@(Convert-ToArray $ApplyPlan.sql_executor_plan.refusal_contract.refuse_apply_when | Where-Object {
        $_ -eq "provider_key_secret_management_handoff preflight fails"
      }).Count -eq 1) "$Context SQL refusal contract blocks unsafe provider key handoff"
}

foreach ($path in @($script:NewApiScript, $script:OneApiScript, $script:MappingScript, $script:ApplyPlanScript, $script:NewApiFixture, $script:OneApiFixture)) {
  Assert-Condition (Test-Path -LiteralPath $path -PathType Leaf) "required path exists: $path"
}

if (-not (Test-Path -LiteralPath $script:ArtifactRoot)) {
  New-Item -ItemType Directory -Force -Path $script:ArtifactRoot | Out-Null
}

$cases = @(
  [ordered]@{
    name = "newapi"
    source_script = $script:NewApiScript
    fixture = $script:NewApiFixture
  },
  [ordered]@{
    name = "oneapi"
    source_script = $script:OneApiScript
    fixture = $script:OneApiFixture
  }
)

$summaryCases = New-Object System.Collections.Generic.List[object]
foreach ($case in $cases) {
  $sourcePath = Join-Path $script:ArtifactRoot "$($case.name).source.json"
  $mappingPath = Join-Path $script:ArtifactRoot "$($case.name).mapping.json"
  $applyPlanPath = Join-Path $script:ArtifactRoot "$($case.name).apply_plan.json"

  $source = Invoke-JsonScript `
    -ScriptPath $case.source_script `
    -Arguments @{ InputPath = $case.fixture } `
    -OutputPath $sourcePath `
    -Context "$($case.name) source dry-run"
  Assert-Condition ([int]$source.counts.provider_keys -gt 0) "$($case.name) source report includes provider key evidence"

  $mapping = Invoke-JsonScript `
    -ScriptPath $script:MappingScript `
    -Arguments @{ InputPath = $sourcePath } `
    -OutputPath $mappingPath `
    -Context "$($case.name) internal mapping"
  Assert-Condition ([int]$mapping.counts.provider_key_handoffs -gt 0) "$($case.name) mapping report includes provider key handoffs"
  Assert-Condition ($mapping.provider_key_handoff_contract.raw_material_allowed -eq $false) "$($case.name) mapping raw material disabled"
  Assert-Condition ($mapping.provider_key_handoff_contract.apply_directly_supported -eq $false) "$($case.name) mapping direct apply disabled"

  $applyPlan = Invoke-JsonScript `
    -ScriptPath $script:ApplyPlanScript `
    -Arguments @{ InputPath = $mappingPath } `
    -OutputPath $applyPlanPath `
    -Context "$($case.name) apply plan"
  Assert-ProviderKeyHandoffOnly $applyPlan "$($case.name) apply plan"

  $summaryCases.Add([ordered]@{
      name = $case.name
      source_artifact = ($sourcePath.Substring($script:RepoRoot.Length + 1) -replace "\\", "/")
      mapping_artifact = ($mappingPath.Substring($script:RepoRoot.Length + 1) -replace "\\", "/")
      apply_plan_artifact = ($applyPlanPath.Substring($script:RepoRoot.Length + 1) -replace "\\", "/")
      source_provider_keys = [int]$source.counts.provider_keys
      mapping_provider_key_handoffs = [int]$mapping.counts.provider_key_handoffs
      apply_plan_provider_key_handoffs = [int]$applyPlan.counts.source_provider_key_handoffs
      planned_provider_key_writes = 0
      sql_provider_key_operations = 0
    }) | Out-Null
}

$summary = [ordered]@{
  schema = "importer.provider-key-secret-path-artifact-verification.v1"
  generated_at_utc = [DateTimeOffset]::UtcNow.ToString("O")
  status = "pass"
  artifact_dir = ($script:ArtifactRoot.Substring($script:RepoRoot.Length + 1) -replace "\\", "/")
  secret_safe = $true
  raw_material_allowed = $false
  apply_directly_supported = $false
  required_operator_path = "POST /admin/provider-keys"
  cases = @($summaryCases.ToArray())
}

$summaryPath = Join-Path $script:ArtifactRoot "summary.json"
$summaryJson = $summary | ConvertTo-Json -Depth 32
Assert-NoSecretMaterial $summaryJson "summary artifact"
Assert-RawLocatorsOmitted $summaryJson "summary artifact"
Write-ArtifactText $summaryPath $summaryJson

Write-Output "import provider key secret path artifact verification passed"
Write-Output ("artifact={0}" -f (($summaryPath.Substring($script:RepoRoot.Length + 1) -replace "\\", "/")))
