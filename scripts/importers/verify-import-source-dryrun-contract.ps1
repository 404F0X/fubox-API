[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$scriptPath = $PSCommandPath
if (-not $scriptPath) {
  $scriptPath = $MyInvocation.MyCommand.Path
}

$repoRoot = (Resolve-Path (Join-Path (Split-Path -Parent $scriptPath) "..\..")).Path
$newApiScript = Join-Path $repoRoot "scripts\importers\import-newapi-dryrun.ps1"
$oneApiScript = Join-Path $repoRoot "scripts\importers\import-oneapi-dryrun.ps1"
$sub2ApiScript = Join-Path $repoRoot "scripts\importers\import-sub2api-dryrun.ps1"
$sub2ApiApplyPlanScript = Join-Path $repoRoot "scripts\importers\import-sub2api-apply-plan.ps1"
$newApiFixture = Join-Path $repoRoot "tests\fixtures\importers\newapi_non_migratable.sample.json"
$oneApiFixture = Join-Path $repoRoot "tests\fixtures\importers\oneapi_non_migratable.sample.json"
$sub2ApiFixture = Join-Path $repoRoot "tests\fixtures\importers\sub2api_non_migratable.sample.json"

function Assert-Condition {
  param(
    [bool]$Condition,
    [string]$Message
  )

  if (-not $Condition) {
    throw "VERIFY FAILED: $Message"
  }
}

function Convert-ToArray {
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
    Assert-Condition (-not ($RawJson -match $pattern)) "output contains secret-like material matching $pattern"
  }
}

function Invoke-SourceDryRun {
  param(
    [string]$ScriptPath,
    [string]$InputPath
  )

  $output = & $ScriptPath -InputPath $InputPath
  $raw = ($output | Out-String).Trim()
  Assert-Condition (-not [string]::IsNullOrWhiteSpace($raw)) "source dry-run produced JSON"
  Assert-NoSecretMaterial $raw

  try {
    $report = $raw | ConvertFrom-Json
  } catch {
    throw "VERIFY FAILED: source dry-run output was not JSON. $($_.Exception.Message)"
  }

  return [pscustomobject]@{
    Raw = $raw
    Report = $report
  }
}

function Assert-SourceSpecificArtifacts {
  param(
    [object]$Artifacts,
    [string]$Context
  )

  Assert-Condition ($null -ne $Artifacts) "$Context includes source-specific apply-plan artifacts"
  Assert-Condition ($Artifacts.schema_version -eq "importer.source-specific-apply-plan-artifacts.v1") "$Context artifact schema"
  Assert-Condition ([bool]$Artifacts.secret_safe) "$Context artifact is marked secret-safe"
  Assert-Condition ($Artifacts.raw_provider_key_material_included -eq $false) "$Context omits raw provider key material"
  Assert-Condition ($Artifacts.raw_user_key_material_included -eq $false) "$Context omits raw user key material"
  Assert-Condition ($null -ne $Artifacts.categories.migratable) "$Context has migratable category"
  Assert-Condition ($null -ne $Artifacts.categories.manual) "$Context has manual category"
  Assert-Condition ($null -ne $Artifacts.categories.blocked) "$Context has blocked category"
  Assert-Condition ([int]$Artifacts.classification_counts.migratable -gt 0) "$Context has migratable items"
  Assert-Condition ([int]$Artifacts.classification_counts.manual -gt 0) "$Context has manual items"
  Assert-Condition ([int]$Artifacts.classification_counts.blocked -gt 0) "$Context has blocked items"
  Assert-Condition ($Artifacts.executable_handoff.schema_version -eq "importer.source-specific-executable-handoff.v1") "$Context executable handoff schema"
  Assert-Condition ([bool]$Artifacts.executable_handoff.secret_safe) "$Context executable handoff is secret-safe"
  Assert-Condition ($null -ne $Artifacts.executable_handoff.runner_inputs) "$Context executable handoff runner inputs"
  Assert-Condition ($null -ne $Artifacts.executable_handoff.executable_fields) "$Context executable handoff executable fields"
  Assert-Condition ($null -ne $Artifacts.executable_handoff.apply_modes) "$Context executable handoff apply modes"
  Assert-Condition (@(Convert-ToArray $Artifacts.executable_handoff.forbidden_payload_fields | Where-Object { $_ -match "raw|authorization|bearer|password" }).Count -gt 0) "$Context executable handoff forbids raw secrets"
}

function Assert-MappingQualityReadback {
  param(
    [object]$Readback,
    [string]$Context
  )

  Assert-Condition ($null -ne $Readback) "$Context includes mapping_quality_readback"
  Assert-Condition ($Readback.schema_version -eq "importer.mapping-quality-readback.v1") "$Context mapping quality schema"
  Assert-Condition ([bool]$Readback.secret_safe) "$Context mapping quality is secret-safe"
  Assert-Condition ([bool]$Readback.dry_run_only) "$Context mapping quality is dry-run only"
  Assert-Condition ($null -ne $Readback.mapping_counts) "$Context mapping quality counts"
  Assert-Condition ([int]$Readback.mapping_counts.provider_mappings -ge 0) "$Context provider mapping count"
  Assert-Condition ([int]$Readback.mapping_counts.channel_mappings -ge 0) "$Context channel mapping count"
  Assert-Condition ([int]$Readback.mapping_counts.model_mappings -ge 0) "$Context model mapping count"
  Assert-Condition ([int]$Readback.mapping_counts.user_mappings -ge 0) "$Context user mapping count"
  Assert-Condition ([int]$Readback.mapping_counts.key_mappings -ge 0) "$Context key mapping count"
  Assert-Condition ([int]$Readback.mapping_counts.wallet_mappings -ge 0) "$Context wallet mapping count"
  Assert-Condition ([int]$Readback.mapping_counts.subscription_mappings -ge 0) "$Context subscription mapping count"
  Assert-Condition ($null -ne $Readback.conflicts) "$Context conflicts summary"
  Assert-Condition ($null -ne $Readback.non_migratable_reasons) "$Context non-migratable reasons"
  Assert-Condition ($null -ne $Readback.operator_handoff_refs_presence) "$Context operator handoff refs presence"
  Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$Readback.safe_next_action)) "$Context safe next action"
  Assert-Condition ($Readback.raw_provider_key_returned -eq $false) "$Context omits raw provider key"
  Assert-Condition ($Readback.raw_user_key_returned -eq $false) "$Context omits raw user key"
  Assert-Condition ($Readback.token_returned -eq $false) "$Context omits token"
  Assert-Condition ($Readback.db_url_returned -eq $false) "$Context omits DB URL"
  Assert-Condition ($Readback.raw_sql_returned -eq $false) "$Context omits raw SQL in mapping quality readback"
  Assert-Condition ($Readback.authorization_returned -eq $false) "$Context omits Authorization"
}

foreach ($path in @($newApiScript, $oneApiScript, $sub2ApiScript, $sub2ApiApplyPlanScript, $newApiFixture, $oneApiFixture, $sub2ApiFixture)) {
  Assert-Condition (Test-Path -LiteralPath $path -PathType Leaf) "required contract path exists: $path"
}

$reports = @(
  (Invoke-SourceDryRun $newApiScript $newApiFixture),
  (Invoke-SourceDryRun $oneApiScript $oneApiFixture)
)

$sub2ApiResult = Invoke-SourceDryRun $sub2ApiScript $sub2ApiFixture
$sub2ApplyPlanInputPath = Join-Path $repoRoot ".tmp\importers\sub2api_source_for_handoff_contract.json"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $sub2ApplyPlanInputPath) | Out-Null
Set-Content -LiteralPath $sub2ApplyPlanInputPath -Value $sub2ApiResult.Raw -Encoding UTF8
$sub2ApplyPlanResult = Invoke-SourceDryRun $sub2ApiApplyPlanScript $sub2ApplyPlanInputPath

foreach ($result in $reports) {
  $report = $result.Report
  Assert-Condition ([bool]$report.dry_run) "$($report.importer) reports dry_run=true"
  Assert-Condition ([int]$report.counts.channels -gt 0) "$($report.importer) includes channel evidence"
  Assert-Condition ([int]$report.counts.associations -gt 0) "$($report.importer) includes model mapping association evidence"
  Assert-Condition ([int]$report.counts.access_groups -gt 0) "$($report.importer) includes access group evidence"
  Assert-Condition ([int]$report.counts.user_profiles -gt 0) "$($report.importer) includes user/profile evidence"
  Assert-Condition ([int]$report.counts.user_tokens -gt 0) "$($report.importer) includes token evidence"
  Assert-Condition ([int]$report.counts.balance_records -gt 0) "$($report.importer) includes balance evidence"
  Assert-Condition ([int]$report.counts.pricing_multipliers -gt 0) "$($report.importer) includes multiplier/pricing evidence"
  Assert-Condition ([int]$report.counts.provider_keys -gt 0) "$($report.importer) includes provider key handoff evidence"
  Assert-Condition ([int]$report.counts.non_migratable_items -ge 5) "$($report.importer) reports non-migratable items"
  Assert-MappingQualityReadback $report.mapping_quality_readback $report.importer

  $types = @(Convert-ToArray $report.non_migratable_items | ForEach-Object { $_.type } | Sort-Object -Unique)
  foreach ($requiredType in @("access_group", "opening_balance", "pricing_multiplier", "user_profile", "user_token")) {
    Assert-Condition (@($types | Where-Object { $_ -eq $requiredType }).Count -eq 1) "$($report.importer) includes non-migratable type $requiredType"
  }

  $tokenPreview = @(Convert-ToArray $report.user_tokens | Select-Object -First 1)
  Assert-Condition ($tokenPreview.Count -eq 1) "$($report.importer) includes a token preview"
  Assert-Condition ([bool]$tokenPreview[0].has_secret) "$($report.importer) marks token secret presence"
  Assert-Condition ($tokenPreview[0].secret_material -eq "<redacted>") "$($report.importer) redacts token secret material"

  $providerKeyPreview = @(Convert-ToArray $report.provider_keys | Select-Object -First 1)
  Assert-Condition ($providerKeyPreview.Count -eq 1) "$($report.importer) includes a provider key handoff preview"
  Assert-Condition ([bool]$providerKeyPreview[0].credential_material_present) "$($report.importer) marks provider key credential presence"
  Assert-Condition ([string]$providerKeyPreview[0].credential_locator_redacted -like "*redacted*") "$($report.importer) redacts provider key credential locator"
  Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$providerKeyPreview[0].credential_locator_hash)) "$($report.importer) emits provider key credential locator hash"
  Assert-Condition (-not [bool]$providerKeyPreview[0].raw_material_exported) "$($report.importer) does not export raw provider key material"
  Assert-Condition ([bool]$providerKeyPreview[0].requires_operator_entry) "$($report.importer) requires operator entry for provider key"
  Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$providerKeyPreview[0].recommended_path)) "$($report.importer) recommends provider key secret-management path"

  Assert-SourceSpecificArtifacts $report.apply_plan_artifacts $report.importer
  Assert-Condition (@(Convert-ToArray $report.apply_plan_artifacts.categories.migratable.channels).Count -gt 0) "$($report.importer) classifies channels as migratable"
  Assert-Condition (@(Convert-ToArray $report.apply_plan_artifacts.categories.migratable.model_mappings).Count -gt 0) "$($report.importer) classifies model mappings as migratable"
  Assert-Condition (@(Convert-ToArray $report.apply_plan_artifacts.categories.manual.provider_key_operator_handoffs).Count -gt 0) "$($report.importer) classifies provider keys as manual handoffs"
  Assert-Condition (@(Convert-ToArray $report.apply_plan_artifacts.categories.manual.group_mappings).Count -gt 0) "$($report.importer) classifies groups as manual"
  Assert-Condition (@(Convert-ToArray $report.apply_plan_artifacts.categories.manual.user_link_candidates).Count -gt 0) "$($report.importer) emits user link candidates"
  Assert-Condition (@(Convert-ToArray $report.apply_plan_artifacts.categories.manual.wallet_opening_balance_candidates).Count -gt 0) "$($report.importer) emits wallet/opening balance candidates"
  Assert-Condition (@(Convert-ToArray $report.apply_plan_artifacts.categories.blocked.user_key_reissue_handoffs).Count -gt 0) "$($report.importer) blocks raw user key import with reissue handoff"
  Assert-Condition (@(Convert-ToArray $report.apply_plan_artifacts.executable_handoff.runner_inputs.channels).Count -gt 0) "$($report.importer) executable handoff exposes channels"
  Assert-Condition (@(Convert-ToArray $report.apply_plan_artifacts.executable_handoff.runner_inputs.model_mappings).Count -gt 0) "$($report.importer) executable handoff exposes model mappings"
  Assert-Condition (@(Convert-ToArray $report.apply_plan_artifacts.executable_handoff.runner_inputs.group_mappings).Count -gt 0) "$($report.importer) executable handoff exposes group mappings"
  Assert-Condition (@(Convert-ToArray $report.apply_plan_artifacts.executable_handoff.runner_inputs.rate_mappings).Count -gt 0) "$($report.importer) executable handoff exposes rate mappings"
  Assert-Condition (@(Convert-ToArray $report.apply_plan_artifacts.executable_handoff.runner_inputs.user_key_reissue_handoffs).Count -gt 0) "$($report.importer) executable handoff exposes key reissue handoffs"
  Assert-Condition ($report.apply_plan_artifacts.executable_handoff.apply_modes.provider_key -eq "operator_handoff_only") "$($report.importer) provider key apply mode is operator-only"
}

$sub2ApiReport = $sub2ApiResult.Report
Assert-Condition ([bool]$sub2ApiReport.dry_run) "$($sub2ApiReport.importer) reports dry_run=true"
Assert-MappingQualityReadback $sub2ApiReport.mapping_quality_readback $sub2ApiReport.importer
Assert-Condition ([int]$sub2ApiReport.counts.accounts -gt 0) "$($sub2ApiReport.importer) includes account evidence"
Assert-Condition ([int]$sub2ApiReport.counts.proxies -gt 0) "$($sub2ApiReport.importer) includes proxy evidence"
Assert-Condition ([int]$sub2ApiReport.counts.groups -gt 0) "$($sub2ApiReport.importer) includes group evidence"
Assert-Condition ([int]$sub2ApiReport.counts.account_group_bindings -gt 0) "$($sub2ApiReport.importer) includes account/group binding evidence"
Assert-Condition ([int]$sub2ApiReport.counts.users -gt 0) "$($sub2ApiReport.importer) includes user evidence"
Assert-Condition ([int]$sub2ApiReport.counts.api_keys -gt 0) "$($sub2ApiReport.importer) includes API key evidence"
Assert-Condition ([int]$sub2ApiReport.counts.subscriptions -gt 0) "$($sub2ApiReport.importer) includes subscription evidence"
Assert-Condition ([int]$sub2ApiReport.counts.non_migratable_items -ge 4) "$($sub2ApiReport.importer) reports non-migratable items"

$sub2Types = @(Convert-ToArray $sub2ApiReport.non_migratable_items | ForEach-Object { $_.type } | Sort-Object -Unique)
foreach ($requiredType in @("access_group", "settings", "subscription", "user_profile", "user_token")) {
  Assert-Condition (@($sub2Types | Where-Object { $_ -eq $requiredType }).Count -eq 1) "$($sub2ApiReport.importer) includes non-migratable type $requiredType"
}

$accountPreview = @(Convert-ToArray $sub2ApiReport.accounts | Select-Object -First 1)
Assert-Condition ($accountPreview.Count -eq 1) "$($sub2ApiReport.importer) includes account preview"
Assert-Condition ([bool]$accountPreview[0].credential_material_present) "$($sub2ApiReport.importer) marks account credential presence"
Assert-Condition ([string]$accountPreview[0].credential_locator_redacted -like "*redacted*") "$($sub2ApiReport.importer) redacts account credential material"
Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$accountPreview[0].credential_locator_hash)) "$($sub2ApiReport.importer) emits account credential hash"

$sub2TokenPreview = @(Convert-ToArray $sub2ApiReport.api_keys | Select-Object -First 1)
Assert-Condition ($sub2TokenPreview.Count -eq 1) "$($sub2ApiReport.importer) includes API key preview"
Assert-Condition ([bool]$sub2TokenPreview[0].has_secret) "$($sub2ApiReport.importer) marks API key secret presence"
Assert-Condition ($sub2TokenPreview[0].secret_material -eq "<redacted>") "$($sub2ApiReport.importer) redacts API key secret material"
Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$sub2TokenPreview[0].key_hash)) "$($sub2ApiReport.importer) emits API key hash"

$sub2Plan = $sub2ApplyPlanResult.Report
Assert-Condition ($sub2Plan.importer -eq "sub2api-operator-handoff-plan-dryrun") "Sub2API handoff plan importer name"
Assert-MappingQualityReadback $sub2Plan.mapping_quality_readback "Sub2API handoff plan"
Assert-Condition ($sub2Plan.provider_key_handoff_contract.raw_material_allowed -eq $false) "Sub2API handoff plan disallows raw provider key material"
Assert-Condition ($sub2Plan.provider_key_handoff_contract.apply_directly_supported -eq $false) "Sub2API handoff plan disables direct provider key apply"
Assert-Condition ($sub2Plan.provider_key_handoff_contract.required_operator_path -eq "POST /admin/provider-keys") "Sub2API handoff plan points to provider key API"
Assert-Condition ([int]$sub2Plan.counts.planned_providers -gt 0) "Sub2API handoff plan includes provider plans"
Assert-Condition ([int]$sub2Plan.counts.planned_channels -gt 0) "Sub2API handoff plan includes channel plans"
Assert-Condition ([int]$sub2Plan.counts.provider_key_handoffs -gt 0) "Sub2API handoff plan includes provider key handoffs"
Assert-Condition ([int]$sub2Plan.counts.manual_review_items -gt 0) "Sub2API handoff plan includes manual review items"
Assert-SourceSpecificArtifacts $sub2Plan.apply_plan_artifacts "Sub2API handoff plan"
Assert-Condition (@(Convert-ToArray $sub2Plan.apply_plan_artifacts.categories.migratable.channels).Count -gt 0) "Sub2API handoff classifies channels as migratable"
Assert-Condition (@(Convert-ToArray $sub2Plan.apply_plan_artifacts.categories.manual.provider_key_operator_handoffs).Count -gt 0) "Sub2API handoff classifies provider keys as manual"
Assert-Condition (@(Convert-ToArray $sub2Plan.apply_plan_artifacts.categories.manual.user_link_candidates).Count -gt 0) "Sub2API handoff emits user link candidates"
Assert-Condition (@(Convert-ToArray $sub2Plan.apply_plan_artifacts.categories.manual.wallet_opening_balance_candidates).Count -gt 0) "Sub2API handoff emits wallet/opening balance candidates"
Assert-Condition (@(Convert-ToArray $sub2Plan.apply_plan_artifacts.categories.manual.subscription_mappings).Count -gt 0) "Sub2API handoff emits subscription mappings"
Assert-Condition (@(Convert-ToArray $sub2Plan.apply_plan_artifacts.categories.blocked.user_key_reissue_handoffs).Count -gt 0) "Sub2API handoff blocks raw user key import"
Assert-Condition (@(Convert-ToArray $sub2Plan.apply_plan_artifacts.executable_handoff.runner_inputs.channels).Count -gt 0) "Sub2API executable handoff exposes channels"
Assert-Condition (@(Convert-ToArray $sub2Plan.apply_plan_artifacts.executable_handoff.runner_inputs.user_link_candidates).Count -gt 0) "Sub2API executable handoff exposes user link candidates"
Assert-Condition (@(Convert-ToArray $sub2Plan.apply_plan_artifacts.executable_handoff.runner_inputs.wallet_opening_balance_candidates).Count -gt 0) "Sub2API executable handoff exposes wallet/opening balance candidates"
Assert-Condition (@(Convert-ToArray $sub2Plan.apply_plan_artifacts.executable_handoff.runner_inputs.user_key_reissue_handoffs).Count -gt 0) "Sub2API executable handoff exposes key reissue handoffs"
Assert-Condition (@(Convert-ToArray $sub2Plan.apply_plan_artifacts.executable_handoff.runner_inputs.subscription_mappings).Count -gt 0) "Sub2API executable handoff exposes subscription mappings"
Assert-Condition ($sub2Plan.apply_plan_artifacts.executable_handoff.apply_modes.user_link -eq "operator_create_or_link_required") "Sub2API user link apply mode requires operator"

$sub2Handoff = @(Convert-ToArray $sub2Plan.provider_key_handoffs | Select-Object -First 1)
Assert-Condition ($sub2Handoff.Count -eq 1) "Sub2API handoff plan exposes provider key handoff"
Assert-Condition ([bool]$sub2Handoff[0].credential_material_present) "Sub2API handoff records credential presence"
Assert-Condition ($sub2Handoff[0].raw_material_exported -eq $false) "Sub2API handoff omits raw material"
Assert-Condition ($sub2Handoff[0].provider_key_material_included -eq $false) "Sub2API handoff omits provider key material"
Assert-Condition ($sub2Handoff[0].apply_directly_supported -eq $false) "Sub2API handoff direct apply disabled"
Assert-Condition ($sub2Handoff[0].recommended_path -eq "POST /admin/provider-keys") "Sub2API handoff recommended path"

Write-Output "import source dry-run contract verification passed"
