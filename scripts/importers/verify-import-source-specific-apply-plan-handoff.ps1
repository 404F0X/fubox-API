[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$scriptPath = $PSCommandPath
if (-not $scriptPath) {
  $scriptPath = $MyInvocation.MyCommand.Path
}

$repoRoot = (Resolve-Path (Join-Path (Split-Path -Parent $scriptPath) "..\..")).Path
$artifactDir = Join-Path $repoRoot ".tmp\importers\source_specific_apply_plan_handoff"
$summaryPath = Join-Path $artifactDir "summary.json"

$newApiScript = Join-Path $repoRoot "scripts\importers\import-newapi-dryrun.ps1"
$oneApiScript = Join-Path $repoRoot "scripts\importers\import-oneapi-dryrun.ps1"
$sub2SourceScript = Join-Path $repoRoot "scripts\importers\import-sub2api-dryrun.ps1"
$sub2ApplyScript = Join-Path $repoRoot "scripts\importers\import-sub2api-apply-plan.ps1"
$sub2IdentityScript = Join-Path $repoRoot "scripts\importers\import-sub2api-identity-billing-plan.ps1"

$newApiFixture = Join-Path $repoRoot "tests\fixtures\importers\newapi_non_migratable.sample.json"
$oneApiFixture = Join-Path $repoRoot "tests\fixtures\importers\oneapi_non_migratable.sample.json"
$sub2Fixture = Join-Path $repoRoot "tests\fixtures\importers\sub2api_non_migratable.sample.json"

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

function Get-ObjectPropertyNames {
  param([AllowNull()][object]$Value)

  if ($null -eq $Value) { return @() }
  return @($Value.PSObject.Properties | ForEach-Object { $_.Name })
}

function Assert-NoSecretMaterial {
  param([string]$RawJson, [string]$Context)

  $patterns = @(
    'sk-[A-Za-z0-9_-]+',
    '(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}',
    '(?i)"authorization"\s*:',
    '(?i)"raw_payload"\s*:',
    '(?i)(api[_-]?key|authorization|token|password)=([^<][^&\s"`]+)'
  )

  foreach ($pattern in $patterns) {
    Assert-Condition (-not ($RawJson -match $pattern)) "$Context contains secret-like material matching $pattern"
  }
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
  Assert-NoSecretMaterial $raw $Context

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

function Assert-ContainsAll {
  param(
    [object[]]$Actual,
    [string[]]$Expected,
    [string]$Context
  )

  foreach ($expectedValue in $Expected) {
    Assert-Condition (@($Actual | Where-Object { $_ -eq $expectedValue }).Count -eq 1) "$Context includes $expectedValue"
  }
}

function Assert-NonEmptyCategory {
  param(
    [object]$Categories,
    [string]$Category,
    [string[]]$Fields,
    [string]$Context
  )

  $categoryObject = $Categories.PSObject.Properties[$Category].Value
  foreach ($field in $Fields) {
    $value = $categoryObject.PSObject.Properties[$field].Value
    Assert-Condition (@(Convert-ToArray $value).Count -gt 0) "$Context has non-empty $Category.$field"
  }
}

function Get-HandoffSummary {
  param(
    [string]$SourceName,
    [object]$Artifacts,
    [hashtable]$Expected
  )

  Assert-Condition ($Artifacts.schema_version -eq "importer.source-specific-apply-plan-artifacts.v1") "$SourceName artifact schema"
  Assert-Condition ([bool]$Artifacts.secret_safe) "$SourceName artifact is secret-safe"
  Assert-Condition ($Artifacts.raw_provider_key_material_included -eq $false) "$SourceName omits raw provider key material"
  Assert-Condition ($Artifacts.raw_user_key_material_included -eq $false) "$SourceName omits raw user key material"
  if ($null -ne $Artifacts.PSObject.Properties["raw_email_included"]) {
    Assert-Condition ($Artifacts.raw_email_included -eq $false) "$SourceName omits raw email"
  }

  $matrix = $Artifacts.automation_matrix
  Assert-ContainsAll (Convert-ToArray $matrix.automatic_apply) $Expected.automatic "$SourceName automatic_apply"
  Assert-ContainsAll (Convert-ToArray $matrix.operator_handoff) $Expected.manual "$SourceName operator_handoff"
  Assert-ContainsAll (Convert-ToArray $matrix.blocked_without_operator) $Expected.blocked "$SourceName blocked_without_operator"

  Assert-NonEmptyCategory $Artifacts.categories "migratable" $Expected.non_empty_migratable "$SourceName"
  Assert-NonEmptyCategory $Artifacts.categories "manual" $Expected.non_empty_manual "$SourceName"
  Assert-NonEmptyCategory $Artifacts.categories "blocked" $Expected.non_empty_blocked "$SourceName"

  $handoff = $Artifacts.executable_handoff
  Assert-Condition ($handoff.schema_version -eq "importer.source-specific-executable-handoff.v1") "$SourceName executable handoff schema"
  Assert-Condition ([bool]$handoff.secret_safe) "$SourceName executable handoff is secret-safe"
  Assert-ContainsAll (Get-ObjectPropertyNames $handoff.runner_inputs) $Expected.runner_inputs "$SourceName runner inputs"
  Assert-ContainsAll (Get-ObjectPropertyNames $handoff.apply_modes) $Expected.apply_modes "$SourceName apply modes"
  Assert-ContainsAll (Convert-ToArray $handoff.forbidden_payload_fields) $Expected.forbidden "$SourceName forbidden payload fields"

  return [ordered]@{
    source_system = $SourceName
    schema_version = $Artifacts.schema_version
    secret_safe = [bool]$Artifacts.secret_safe
    automatic_apply = @(Convert-ToArray $matrix.automatic_apply)
    operator_handoff = @(Convert-ToArray $matrix.operator_handoff)
    blocked_without_operator = @(Convert-ToArray $matrix.blocked_without_operator)
    runner_inputs = @(Get-ObjectPropertyNames $handoff.runner_inputs)
    executable_fields = @(Get-ObjectPropertyNames $handoff.executable_fields)
    apply_modes = @(Get-ObjectPropertyNames $handoff.apply_modes)
    remaining_post_apply_gap = $Expected.remaining_gap
  }
}

foreach ($path in @($newApiScript, $oneApiScript, $sub2SourceScript, $sub2ApplyScript, $sub2IdentityScript, $newApiFixture, $oneApiFixture, $sub2Fixture)) {
  Assert-Condition (Test-Path -LiteralPath $path -PathType Leaf) "required path exists: $path"
}

New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null

$newApi = Invoke-JsonScript $newApiScript @{ InputPath = $newApiFixture } "NewAPI dry-run"
$oneApi = Invoke-JsonScript $oneApiScript @{ InputPath = $oneApiFixture } "OneAPI dry-run"

$sub2Source = Invoke-JsonScript $sub2SourceScript @{ InputPath = $sub2Fixture } "Sub2API dry-run"
$sub2SourcePath = Join-Path $artifactDir "sub2api.source.json"
Set-Content -LiteralPath $sub2SourcePath -Value $sub2Source.Raw -Encoding UTF8

$sub2Apply = Invoke-JsonScript $sub2ApplyScript @{ InputPath = $sub2SourcePath } "Sub2API operator handoff apply-plan"
$sub2Identity = Invoke-JsonScript $sub2IdentityScript @{ InputPath = $sub2SourcePath; Currency = "USD" } "Sub2API identity/billing handoff"

$newApiExpected = @{
  automatic = @("channels", "model_mappings")
  manual = @("provider_key_operator_handoffs", "group_mappings", "price_book_multiplier_mappings", "wallet_opening_balance_candidates")
  blocked = @("provider_key_direct_import", "user_key_reissue_handoffs", "opening_balance_direct_apply")
  non_empty_migratable = @("channels", "model_mappings")
  non_empty_manual = @("provider_key_operator_handoffs", "group_mappings", "wallet_opening_balance_candidates", "price_book_multiplier_mappings")
  non_empty_blocked = @("provider_key_direct_import", "user_key_reissue_handoffs", "opening_balance_direct_apply")
  runner_inputs = @("channels", "model_mappings", "group_mappings", "rate_mappings", "provider_key_reissue_handoffs", "user_key_reissue_handoffs", "wallet_opening_balance_candidates")
  apply_modes = @("channel", "model_mapping", "group", "rate", "provider_key", "user_key", "opening_balance")
  forbidden = @("raw_provider_key", "raw_user_key", "secret_material", "authorization", "bearer_token", "password")
  remaining_gap = "production apply-live still needs reviewed price-book/group mapping, opening-balance unit confirmation, provider-key operator entry, and user-key reissue execution"
}

$oneApiExpected = @{
  automatic = @("channels", "model_mappings")
  manual = @("provider_key_operator_handoffs", "group_mappings", "price_book_multiplier_mappings", "wallet_opening_balance_candidates")
  blocked = @("provider_key_direct_import", "user_key_reissue_handoffs", "opening_balance_direct_apply")
  non_empty_migratable = @("channels", "model_mappings")
  non_empty_manual = @("provider_key_operator_handoffs", "group_mappings", "wallet_opening_balance_candidates", "price_book_multiplier_mappings")
  non_empty_blocked = @("provider_key_direct_import", "user_key_reissue_handoffs", "opening_balance_direct_apply")
  runner_inputs = @("channels", "model_mappings", "group_mappings", "rate_mappings", "provider_key_reissue_handoffs", "user_key_reissue_handoffs", "wallet_opening_balance_candidates")
  apply_modes = @("channel", "token", "group", "model_mapping", "provider_key", "user_key", "opening_balance")
  forbidden = @("raw_provider_key", "raw_channel_key", "raw_user_key", "secret_material", "authorization", "bearer_token", "password")
  remaining_gap = "production apply-live still needs operator token/provider-key entry, reviewed group mapping, opening-balance unit confirmation, and user-key reissue execution"
}

$sub2ApplyExpected = @{
  automatic = @("channels")
  manual = @("provider_key_operator_handoffs", "group_mappings", "user_link_candidates", "wallet_opening_balance_candidates", "subscription_mappings")
  blocked = @("provider_key_direct_import", "user_key_reissue_handoffs", "identity_billing_direct_apply")
  non_empty_migratable = @("channels")
  non_empty_manual = @("provider_key_operator_handoffs", "group_mappings", "user_link_candidates", "wallet_opening_balance_candidates", "subscription_mappings")
  non_empty_blocked = @("provider_key_direct_import", "user_key_reissue_handoffs", "identity_billing_direct_apply")
  runner_inputs = @("channels", "provider_key_reissue_handoffs", "group_mappings", "user_link_candidates", "wallet_opening_balance_candidates", "user_key_reissue_handoffs", "subscription_mappings")
  apply_modes = @("channel", "provider_key", "user_link", "wallet_lookup", "opening_balance", "key_reissue", "subscription_mapping")
  forbidden = @("raw_provider_key", "raw_user_key", "proxy_password", "payment_secret", "authorization", "bearer_token", "password")
  remaining_gap = "production apply-live still needs identity/billing writer wiring plus operator provider-key entry and subscription package mapping"
}

$sub2IdentityExpected = @{
  automatic = @()
  manual = @("user_link_candidates", "wallet_opening_balance_candidates", "user_key_reissue_handoffs", "subscription_mappings")
  blocked = @("raw_user_key_import", "opening_balance_direct_apply_without_unit_review", "subscription_direct_apply_without_package_mapping")
  non_empty_migratable = @()
  non_empty_manual = @("user_link_candidates", "wallet_opening_balance_candidates", "user_key_reissue_handoffs", "subscription_mappings")
  non_empty_blocked = @("raw_user_key_import", "opening_balance_direct_apply_without_unit_review", "subscription_direct_apply_without_package_mapping")
  runner_inputs = @("user_link_candidates", "wallet_opening_balance_candidates", "user_key_reissue_handoffs", "subscription_mappings")
  apply_modes = @("user_link", "wallet_lookup", "opening_balance", "key_reissue", "subscription_mapping")
  forbidden = @("raw_user_key", "raw_email", "raw_password", "payment_secret", "authorization", "bearer_token", "password")
  remaining_gap = "production apply-live still needs reviewed user create/link, wallet lookup/create, opening-balance ledger import, user-key reissue, and subscription package apply runner"
}

$summary = [ordered]@{
  schema_version = "importer.source-specific-apply-plan-handoff-summary.v1"
  generated_at = (Get-Date).ToUniversalTime().ToString("o")
  secret_safe = $true
  artifacts = @(
    (Get-HandoffSummary "new-api" $newApi.Json.apply_plan_artifacts $newApiExpected),
    (Get-HandoffSummary "one-api" $oneApi.Json.apply_plan_artifacts $oneApiExpected),
    (Get-HandoffSummary "sub2api-provider-channel" $sub2Apply.Json.apply_plan_artifacts $sub2ApplyExpected),
    (Get-HandoffSummary "sub2api-identity-billing" $sub2Identity.Json.apply_plan_artifacts $sub2IdentityExpected)
  )
}

$summaryJson = $summary | ConvertTo-Json -Depth 32
Assert-NoSecretMaterial $summaryJson "source-specific handoff summary"
Set-Content -LiteralPath $summaryPath -Value $summaryJson -Encoding UTF8

Write-Output "import source-specific apply-plan handoff verification passed"
Write-Output ("summary_artifact={0}" -f (($summaryPath.Substring($repoRoot.Length + 1) -replace "\\", "/")))
