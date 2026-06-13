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
$identityBillingScript = Join-Path $repoRoot "scripts\importers\import-sub2api-identity-billing-plan.ps1"
$artifactDir = Join-Path $repoRoot ".tmp\importers\sub2api_identity_billing"
$sourceReportPath = Join-Path $artifactDir "sub2api.source.json"
$identityBillingPlanPath = Join-Path $artifactDir "sub2api.identity_billing_plan.json"
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

foreach ($path in @($sourceScript, $identityBillingScript, $fixture)) {
  Assert-Condition (Test-Path -LiteralPath $path -PathType Leaf) "required path exists: $path"
}

if (-not (Test-Path -LiteralPath $artifactDir)) {
  New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
}

$source = Invoke-JsonScript -ScriptPath $sourceScript -Arguments @{ InputPath = $fixture } -Context "Sub2API source dry-run"
Set-Content -LiteralPath $sourceReportPath -Value $source.Raw -Encoding UTF8

$planResult = Invoke-JsonScript -ScriptPath $identityBillingScript -Arguments @{ InputPath = $sourceReportPath; Currency = "USD" } -Context "Sub2API identity/billing plan"
Set-Content -LiteralPath $identityBillingPlanPath -Value $planResult.Raw -Encoding UTF8

$plan = $planResult.Json
Assert-Condition ($plan.importer -eq "sub2api-identity-billing-plan-dryrun") "identity/billing plan importer name"
Assert-Condition ($plan.schema_version -eq "sub2api.identity-billing-plan.v1") "identity/billing plan schema"
Assert-Condition ([bool]$plan.dry_run) "identity/billing plan remains dry-run"
Assert-Condition ($plan.apply_supported -eq $false) "identity/billing apply disabled"
Assert-Condition ($plan.database_writes -eq $false) "identity/billing plan does not write database"
Assert-Condition ($plan.secret_handling_contract.raw_user_key_material_allowed -eq $false) "raw user key material disallowed"
Assert-Condition ($plan.secret_handling_contract.raw_user_key_material_included -eq $false) "raw user key material omitted"
Assert-Condition ($plan.secret_handling_contract.raw_email_allowed -eq $false) "raw email disallowed"
Assert-Condition ($plan.secret_handling_contract.operator_reissue_required -eq $true) "operator key reissue required"
Assert-Condition ($plan.secret_handling_contract.required_user_key_path -eq "POST /auth/api-keys") "user key reissue path"
Assert-Condition ($plan.preflight.status -eq "blocked") "preflight stays blocked until reviewed apply exists"

Assert-Condition ([int]$plan.counts.user_profile_mappings -gt 0) "user mappings present"
Assert-Condition ([int]$plan.counts.opening_balance_plans -gt 0) "opening balance plans present"
Assert-Condition ([int]$plan.counts.user_key_reissue_handoffs -gt 0) "user key handoffs present"
Assert-Condition ([int]$plan.counts.subscription_review_items -gt 0) "subscription review items present"
Assert-Condition ([int]$plan.counts.manual_review_items -gt 0) "manual review items present"
Assert-Condition ($plan.apply_plan_artifacts.schema_version -eq "importer.source-specific-apply-plan-artifacts.v1") "source-specific artifact schema"
Assert-Condition ([bool]$plan.apply_plan_artifacts.secret_safe) "source-specific artifact marked secret-safe"
Assert-Condition ($plan.apply_plan_artifacts.raw_user_key_material_included -eq $false) "source-specific artifact omits raw user keys"
Assert-Condition ($plan.apply_plan_artifacts.raw_email_included -eq $false) "source-specific artifact omits raw email"
Assert-Condition ([int]$plan.apply_plan_artifacts.classification_counts.migratable -eq 0) "identity/billing has no direct migratable writes"
Assert-Condition ([int]$plan.apply_plan_artifacts.classification_counts.manual -gt 0) "identity/billing has manual items"
Assert-Condition ([int]$plan.apply_plan_artifacts.classification_counts.blocked -gt 0) "identity/billing has blocked items"
Assert-Condition (@(Convert-ToArray $plan.apply_plan_artifacts.categories.manual.user_link_candidates).Count -gt 0) "artifact emits user link candidates"
Assert-Condition (@(Convert-ToArray $plan.apply_plan_artifacts.categories.manual.wallet_opening_balance_candidates).Count -gt 0) "artifact emits wallet/opening balance candidates"
Assert-Condition (@(Convert-ToArray $plan.apply_plan_artifacts.categories.manual.user_key_reissue_handoffs).Count -gt 0) "artifact emits key reissue handoffs"
Assert-Condition (@(Convert-ToArray $plan.apply_plan_artifacts.categories.manual.subscription_mappings).Count -gt 0) "artifact emits subscription mappings"
Assert-Condition (@(Convert-ToArray $plan.apply_plan_artifacts.categories.blocked.raw_user_key_import).Count -gt 0) "artifact blocks raw user key import"
Assert-Condition ($plan.apply_plan_artifacts.executable_handoff.schema_version -eq "importer.source-specific-executable-handoff.v1") "artifact executable handoff schema"
Assert-Condition ([bool]$plan.apply_plan_artifacts.executable_handoff.secret_safe) "artifact executable handoff secret-safe"
Assert-Condition (@(Convert-ToArray $plan.apply_plan_artifacts.executable_handoff.runner_inputs.user_link_candidates).Count -gt 0) "executable handoff has user link candidates"
Assert-Condition (@(Convert-ToArray $plan.apply_plan_artifacts.executable_handoff.runner_inputs.wallet_opening_balance_candidates).Count -gt 0) "executable handoff has wallet/opening balance candidates"
Assert-Condition (@(Convert-ToArray $plan.apply_plan_artifacts.executable_handoff.runner_inputs.user_key_reissue_handoffs).Count -gt 0) "executable handoff has key reissue handoffs"
Assert-Condition (@(Convert-ToArray $plan.apply_plan_artifacts.executable_handoff.runner_inputs.subscription_mappings).Count -gt 0) "executable handoff has subscription mappings"
Assert-Condition ($plan.apply_plan_artifacts.executable_handoff.apply_modes.user_link -eq "operator_create_or_link_required") "user link mode requires operator"
Assert-Condition ($plan.apply_plan_artifacts.executable_handoff.apply_modes.opening_balance -eq "operator_unit_review_required") "opening balance mode requires unit review"
Assert-Condition ($plan.apply_plan_artifacts.executable_handoff.apply_modes.key_reissue -eq "operator_reissue_only") "key reissue mode requires operator"

$userMapping = @(Convert-ToArray $plan.user_profile_mappings | Select-Object -First 1)
Assert-Condition ($userMapping.Count -eq 1) "first user mapping present"
Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$userMapping[0].source_email_hash)) "user mapping uses email hash"
Assert-Condition ($userMapping[0].raw_email_exported -eq $false) "user mapping omits raw email"
Assert-Condition ($userMapping[0].raw_password_exported -eq $false) "user mapping omits raw password"

$balancePlan = @(Convert-ToArray $plan.opening_balance_plans | Select-Object -First 1)
Assert-Condition ($balancePlan.Count -eq 1) "opening balance plan present"
Assert-Condition ($balancePlan[0].ledger_entry_type -eq "opening_balance_import") "opening balance ledger entry type"
Assert-Condition ($balancePlan[0].currency -eq "USD") "opening balance currency"
Assert-Condition ($balancePlan[0].apply_supported -eq $false) "opening balance apply disabled"
Assert-Condition ([bool]$balancePlan[0].requires_unit_review) "opening balance requires unit review"

$keyHandoff = @(Convert-ToArray $plan.user_key_reissue_handoffs | Select-Object -First 1)
Assert-Condition ($keyHandoff.Count -eq 1) "user key handoff present"
Assert-Condition ([bool]$keyHandoff[0].source_secret_present) "source key secret presence recorded"
Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$keyHandoff[0].source_key_hash)) "source key hash present"
Assert-Condition ($keyHandoff[0].raw_key_exported -eq $false) "raw user key omitted"
Assert-Condition ($keyHandoff[0].secret_material_included -eq $false) "user key secret material omitted"
Assert-Condition ($keyHandoff[0].apply_directly_supported -eq $false) "user key direct apply disabled"
Assert-Condition ($keyHandoff[0].required_operator_path -eq "POST /auth/api-keys") "user key operator path"

$subscriptionReview = @(Convert-ToArray $plan.subscription_review_items | Select-Object -First 1)
Assert-Condition ($subscriptionReview.Count -eq 1) "subscription review present"
Assert-Condition ($subscriptionReview[0].target_action -eq "manual_subscription_package_mapping_required") "subscription requires package mapping"
Assert-Condition ($subscriptionReview[0].apply_supported -eq $false) "subscription apply disabled"

Write-Output "sub2api identity/billing plan contract verification passed"
Write-Output ("source_artifact={0}" -f (($sourceReportPath.Substring($repoRoot.Length + 1) -replace "\\", "/")))
Write-Output ("identity_billing_plan_artifact={0}" -f (($identityBillingPlanPath.Substring($repoRoot.Length + 1) -replace "\\", "/")))
