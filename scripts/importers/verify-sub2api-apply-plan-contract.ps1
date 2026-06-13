[CmdletBinding()]
param(
  [string]$SourceFixturePath = "tests\fixtures\importers\sub2api_non_migratable.sample.json"
)

$ErrorActionPreference = "Stop"

$scriptPath = $PSCommandPath
if (-not $scriptPath) {
  $scriptPath = $MyInvocation.MyCommand.Path
}

$repoRoot = (Resolve-Path (Join-Path (Split-Path -Parent $scriptPath) "..\..")).Path
$sourceScript = Join-Path $repoRoot "scripts\importers\import-sub2api-dryrun.ps1"
$handoffScript = Join-Path $repoRoot "scripts\importers\import-sub2api-apply-plan.ps1"
$internalMappingScript = Join-Path $repoRoot "scripts\importers\import-internal-mapping-report.ps1"
$applyPlanScript = Join-Path $repoRoot "scripts\importers\import-apply-plan.ps1"
$artifactDir = Join-Path $repoRoot ".tmp\importers\sub2api_apply_plan"
$sourceReportPath = Join-Path $artifactDir "sub2api.source.json"
$handoffPlanPath = Join-Path $artifactDir "sub2api.operator_handoff_plan.json"
$internalMappingPath = Join-Path $artifactDir "sub2api.internal_mapping.json"
$applyPlanPath = Join-Path $artifactDir "sub2api.apply_plan.json"
$fixture = if ([System.IO.Path]::IsPathRooted($SourceFixturePath)) {
  $SourceFixturePath
} else {
  Join-Path $repoRoot $SourceFixturePath
}

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
    foreach ($item in $Value) { $items.Add($item) | Out-Null }
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
    Assert-Condition (-not ($RawJson -match $pattern)) "output contains secret-like material matching $pattern"
  }
}

function Assert-MappingQualityReadback {
  param(
    [object]$Readback,
    [string]$Context
  )

  Assert-Condition ($null -ne $Readback) "$Context includes mapping_quality_readback"
  Assert-Condition ($Readback.schema_version -eq "importer.mapping-quality-readback.v1") "$Context mapping quality schema"
  Assert-Condition ([bool]$Readback.secret_safe) "$Context mapping quality secret-safe"
  Assert-Condition ([bool]$Readback.dry_run_only) "$Context mapping quality dry-run only"
  foreach ($field in @("provider_mappings", "channel_mappings", "model_mappings", "user_mappings", "key_mappings", "wallet_mappings", "subscription_mappings", "conflicts")) {
    Assert-Condition ([int]$Readback.mapping_counts.$field -ge 0) "$Context mapping quality count $field"
  }
  Assert-Condition ($null -ne $Readback.conflicts) "$Context mapping quality conflicts"
  Assert-Condition ($null -ne $Readback.non_migratable_reasons) "$Context mapping quality non-migratable reasons"
  Assert-Condition ($null -ne $Readback.operator_handoff_refs_presence) "$Context mapping quality operator handoff refs"
  Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$Readback.safe_next_action)) "$Context mapping quality safe next action"
  Assert-Condition ($Readback.raw_provider_key_returned -eq $false) "$Context mapping quality omits raw provider key"
  Assert-Condition ($Readback.raw_user_key_returned -eq $false) "$Context mapping quality omits raw user key"
  Assert-Condition ($Readback.token_returned -eq $false) "$Context mapping quality omits token"
  Assert-Condition ($Readback.db_url_returned -eq $false) "$Context mapping quality omits DB URL"
  Assert-Condition ($Readback.raw_sql_returned -eq $false) "$Context mapping quality omits raw SQL"
  Assert-Condition ($Readback.authorization_returned -eq $false) "$Context mapping quality omits Authorization"
}

function Invoke-JsonScript {
  param(
    [string]$ScriptPath,
    [hashtable]$Arguments,
    [string]$Context
  )

  $output = & $ScriptPath @Arguments
  $raw = ($output | Out-String).Trim()
  Assert-Condition (-not [string]::IsNullOrWhiteSpace($raw)) "$Context emitted JSON"
  Assert-NoSecretMaterial $raw

  try {
    $json = $raw | ConvertFrom-Json
  } catch {
    throw "VERIFY FAILED: $Context output was not valid JSON. $($_.Exception.Message)"
  }

  return [pscustomobject]@{
    Raw = $raw
    Json = $json
  }
}

foreach ($path in @($sourceScript, $handoffScript, $internalMappingScript, $applyPlanScript, $fixture)) {
  Assert-Condition (Test-Path -LiteralPath $path -PathType Leaf) "required path exists: $path"
}

if (-not (Test-Path -LiteralPath $artifactDir)) {
  New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
}

$source = Invoke-JsonScript -ScriptPath $sourceScript -Arguments @{ InputPath = $fixture } -Context "Sub2API source dry-run"
Set-Content -LiteralPath $sourceReportPath -Value $source.Raw -Encoding UTF8

$planResult = Invoke-JsonScript -ScriptPath $handoffScript -Arguments @{ InputPath = $sourceReportPath } -Context "Sub2API operator handoff plan"
Set-Content -LiteralPath $handoffPlanPath -Value $planResult.Raw -Encoding UTF8

$plan = $planResult.Json
Assert-Condition ($plan.importer -eq "sub2api-operator-handoff-plan-dryrun") "handoff plan importer name"
Assert-Condition ($plan.schema_version -eq "sub2api.operator-handoff-plan.v1") "handoff plan schema"
Assert-MappingQualityReadback $plan.mapping_quality_readback "Sub2API handoff plan"
Assert-Condition ([bool]$plan.dry_run) "handoff plan remains dry-run"
Assert-Condition ($plan.apply_supported -eq $false) "handoff plan apply is disabled"
Assert-Condition ($plan.database_writes -eq $false) "handoff plan does not write database"
Assert-Condition ($plan.provider_key_handoff_contract.schema_version -eq "importer.provider-key-handoff-contract.v1") "provider key handoff contract schema"
Assert-Condition ($plan.provider_key_handoff_contract.raw_material_allowed -eq $false) "provider key raw material disallowed"
Assert-Condition ($plan.provider_key_handoff_contract.apply_directly_supported -eq $false) "provider key direct apply disallowed"
Assert-Condition ($plan.provider_key_handoff_contract.required_operator_path -eq "POST /admin/provider-keys") "provider key operator path"
Assert-Condition ([int]$plan.counts.planned_providers -gt 0) "provider plans present"
Assert-Condition ([int]$plan.counts.planned_channels -gt 0) "channel plans present"
Assert-Condition ([int]$plan.counts.provider_key_handoffs -gt 0) "provider key handoffs present"
Assert-Condition ([int]$plan.counts.manual_review_items -gt 0) "manual review items present"
Assert-Condition ($plan.apply_plan_artifacts.schema_version -eq "importer.source-specific-apply-plan-artifacts.v1") "source-specific artifact schema"
Assert-Condition ([bool]$plan.apply_plan_artifacts.secret_safe) "source-specific artifact marked secret-safe"
Assert-Condition ($plan.apply_plan_artifacts.raw_provider_key_material_included -eq $false) "source-specific artifact omits raw provider keys"
Assert-Condition ($plan.apply_plan_artifacts.raw_user_key_material_included -eq $false) "source-specific artifact omits raw user keys"
Assert-Condition ([int]$plan.apply_plan_artifacts.classification_counts.migratable -gt 0) "source-specific artifact has migratable items"
Assert-Condition ([int]$plan.apply_plan_artifacts.classification_counts.manual -gt 0) "source-specific artifact has manual items"
Assert-Condition ([int]$plan.apply_plan_artifacts.classification_counts.blocked -gt 0) "source-specific artifact has blocked items"
Assert-Condition (@(Convert-ToArray $plan.apply_plan_artifacts.categories.migratable.channels).Count -gt 0) "artifact classifies channels as migratable"
Assert-Condition (@(Convert-ToArray $plan.apply_plan_artifacts.categories.manual.provider_key_operator_handoffs).Count -gt 0) "artifact classifies provider keys as manual"
Assert-Condition (@(Convert-ToArray $plan.apply_plan_artifacts.categories.manual.group_mappings).Count -gt 0) "artifact emits group mappings"
Assert-Condition (@(Convert-ToArray $plan.apply_plan_artifacts.categories.manual.user_link_candidates).Count -gt 0) "artifact emits user link candidates"
Assert-Condition (@(Convert-ToArray $plan.apply_plan_artifacts.categories.manual.wallet_opening_balance_candidates).Count -gt 0) "artifact emits wallet/opening balance candidates"
Assert-Condition (@(Convert-ToArray $plan.apply_plan_artifacts.categories.manual.subscription_mappings).Count -gt 0) "artifact emits subscription mappings"
Assert-Condition (@(Convert-ToArray $plan.apply_plan_artifacts.categories.blocked.user_key_reissue_handoffs).Count -gt 0) "artifact blocks raw user key import"
Assert-Condition ($plan.apply_plan_artifacts.executable_handoff.schema_version -eq "importer.source-specific-executable-handoff.v1") "artifact executable handoff schema"
Assert-Condition ([bool]$plan.apply_plan_artifacts.executable_handoff.secret_safe) "artifact executable handoff secret-safe"
Assert-Condition (@(Convert-ToArray $plan.apply_plan_artifacts.executable_handoff.runner_inputs.channels).Count -gt 0) "artifact executable handoff has channels"
Assert-Condition (@(Convert-ToArray $plan.apply_plan_artifacts.executable_handoff.runner_inputs.user_link_candidates).Count -gt 0) "artifact executable handoff has user link candidates"
Assert-Condition (@(Convert-ToArray $plan.apply_plan_artifacts.executable_handoff.runner_inputs.wallet_opening_balance_candidates).Count -gt 0) "artifact executable handoff has wallet/opening balance candidates"
Assert-Condition (@(Convert-ToArray $plan.apply_plan_artifacts.executable_handoff.runner_inputs.user_key_reissue_handoffs).Count -gt 0) "artifact executable handoff has key reissue handoffs"
Assert-Condition (@(Convert-ToArray $plan.apply_plan_artifacts.executable_handoff.runner_inputs.subscription_mappings).Count -gt 0) "artifact executable handoff has subscription mappings"
Assert-Condition ($plan.apply_plan_artifacts.executable_handoff.apply_modes.subscription_mapping -eq "operator_package_mapping_required") "artifact executable handoff subscription mode requires operator"

$handoffs = @(Convert-ToArray $plan.provider_key_handoffs)
foreach ($handoff in $handoffs) {
  Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$handoff.handoff_id)) "handoff has id"
  Assert-Condition ([bool]$handoff.credential_material_present) "handoff records credential presence"
  Assert-Condition ($handoff.raw_material_exported -eq $false) "handoff omits raw material"
  Assert-Condition ($handoff.provider_key_material_included -eq $false) "handoff omits provider key material"
  Assert-Condition ($handoff.apply_directly_supported -eq $false) "handoff direct apply disabled"
  Assert-Condition ($handoff.apply_mode -eq "sidecar_only") "handoff is sidecar only"
  Assert-Condition ($handoff.recommended_path -eq "POST /admin/provider-keys") "handoff recommended path"
  Assert-Condition (@(Convert-ToArray $handoff.credential_locator_hashes).Count -gt 0) "handoff includes credential hash"
}

$mappingResult = Invoke-JsonScript -ScriptPath $internalMappingScript -Arguments @{ InputPath = $handoffPlanPath } -Context "Sub2API internal mapping bridge"
Set-Content -LiteralPath $internalMappingPath -Value $mappingResult.Raw -Encoding UTF8
$mapping = $mappingResult.Json
Assert-Condition ($mapping.importer -eq "internal-mapping-report-dryrun") "bridge emits internal mapping report"
Assert-Condition ([bool]$mapping.dry_run) "bridge remains dry-run"
Assert-MappingQualityReadback $mapping.mapping_quality_readback "Sub2API internal mapping bridge"
Assert-Condition ([int]$mapping.counts.channel_mappings -gt 0) "bridge exposes channel mappings"
Assert-Condition ([int]$mapping.counts.provider_key_handoffs -gt 0) "bridge carries provider key handoffs"
Assert-Condition ([int]$mapping.counts.model_associations -eq 0) "Sub2API bridge does not invent model associations"
Assert-Condition (@(Convert-ToArray $mapping.manual_review_items | Where-Object { $_.type -eq "sub2api_identity_billing_not_auto_applied" }).Count -gt 0) "identity and billing evidence remains manual review"
Assert-Condition (@(Convert-ToArray $mapping.source_specific_apply_plan_artifacts).Count -gt 0) "bridge preserves source-specific apply-plan artifacts"

$applyResult = Invoke-JsonScript -ScriptPath $applyPlanScript -Arguments @{ InputPath = $internalMappingPath } -Context "Sub2API bridged apply plan"
Set-Content -LiteralPath $applyPlanPath -Value $applyResult.Raw -Encoding UTF8
$applyPlan = $applyResult.Json
Assert-Condition ($applyPlan.importer -eq "importer-apply-plan-dryrun") "bridged apply plan importer"
Assert-MappingQualityReadback $applyPlan.mapping_quality_readback "Sub2API bridged apply plan"
Assert-Condition ([int]$applyPlan.counts.source_provider_previews -gt 0) "bridged apply plan derives provider previews"
Assert-Condition ([int]$applyPlan.counts.source_channel_previews -gt 0) "bridged apply plan derives channel previews"
Assert-Condition ([int]$applyPlan.counts.source_provider_key_handoffs -gt 0) "bridged apply plan carries provider key handoffs"
Assert-Condition ([int]$applyPlan.counts.source_specific_apply_plan_artifacts -gt 0) "bridged apply plan counts source-specific apply-plan artifacts"
Assert-Condition (@(Convert-ToArray $applyPlan.source_specific_apply_plan_artifacts).Count -gt 0) "bridged apply plan preserves source-specific apply-plan artifacts"
Assert-Condition ($applyPlan.provider_key_handoff_contract.raw_material_allowed -eq $false) "bridged apply plan provider key raw material disallowed"
$writeTargets = @(Convert-ToArray $applyPlan.planned_creates) + @(Convert-ToArray $applyPlan.planned_updates)
Assert-Condition (@($writeTargets | Where-Object { $_.target.kind -match "provider_key|secret" }).Count -eq 0) "bridged apply plan does not write provider keys"

Write-Output "sub2api apply-plan contract verification passed"
Write-Output ("source_artifact={0}" -f (($sourceReportPath.Substring($repoRoot.Length + 1) -replace "\\", "/")))
Write-Output ("handoff_artifact={0}" -f (($handoffPlanPath.Substring($repoRoot.Length + 1) -replace "\\", "/")))
Write-Output ("internal_mapping_artifact={0}" -f (($internalMappingPath.Substring($repoRoot.Length + 1) -replace "\\", "/")))
Write-Output ("apply_plan_artifact={0}" -f (($applyPlanPath.Substring($repoRoot.Length + 1) -replace "\\", "/")))
