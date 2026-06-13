[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$InputPath,

  [string]$TenantId = "00000000-0000-0000-0000-000000000001",

  [string]$Currency = "USD",

  [switch]$DryRun = $true
)

$ErrorActionPreference = "Stop"

if (-not [bool]$DryRun) {
  throw "Only dry-run identity/billing planning is implemented. Re-run with -DryRun or omit the flag."
}

function Get-PropertyValue {
  param(
    [object]$Object,
    [string[]]$Names,
    [object]$Default = $null
  )

  if ($null -eq $Object) { return $Default }
  foreach ($name in $Names) {
    $property = $Object.PSObject.Properties | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
    if ($null -ne $property -and $null -ne $property.Value) { return $property.Value }
  }
  return $Default
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

function Redact-SecretLikeString {
  param([AllowNull()][object]$Value)

  if ($null -eq $Value) { return $null }
  $text = [string]$Value
  $text = $text -replace "\$\{[A-Za-z_][A-Za-z0-9_]*(KEY|TOKEN|SECRET|PASSWORD)[A-Za-z0-9_]*\}", "<redacted-env>"
  $text = $text -replace "(?i)\benv:[A-Z0-9_]*(KEY|TOKEN|SECRET|PASSWORD)[A-Z0-9_]*\b", "env:<redacted>"
  $text = $text -replace "sk-[A-Za-z0-9_-]+", "<redacted>"
  $text = $text -replace "(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+", '$1<redacted>'
  $text = $text -replace "(?i)(api[_-]?key|authorization|bearer|token|secret|password|refresh[_-]?token|access[_-]?token|client[_-]?secret|key)=([^&\s""]+)", '$1=<redacted>'
  return $text
}

function Get-StableHash {
  param(
    [AllowNull()][object]$Value,
    [int]$Length = 16
  )

  if ($null -eq $Value) {
    $text = ""
  } elseif ($Value -is [string]) {
    $text = [string]$Value
  } else {
    $text = $Value | ConvertTo-Json -Depth 32 -Compress
  }

  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $hashBytes = $sha.ComputeHash($bytes)
  } finally {
    $sha.Dispose()
  }

  $hash = ([System.BitConverter]::ToString($hashBytes)).Replace("-", "").ToLowerInvariant()
  if ($Length -gt 0 -and $Length -lt $hash.Length) { return $hash.Substring(0, $Length) }
  return $hash
}

function Convert-ToSafeAmount {
  param([AllowNull()][object]$Value)

  if ($null -eq $Value) { return $null }
  $text = (Redact-SecretLikeString $Value).Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  return $text
}

function New-PlanId {
  param([string]$Prefix, [object]$Seed)
  return "$Prefix-$(Get-StableHash $Seed 16)"
}

function New-UserKey {
  param([AllowNull()][object]$UserSourceId, [AllowNull()][object]$EmailHash)

  if ($null -ne $UserSourceId -and -not [string]::IsNullOrWhiteSpace([string]$UserSourceId)) {
    return [string]$UserSourceId
  }
  if ($null -ne $EmailHash -and -not [string]::IsNullOrWhiteSpace([string]$EmailHash)) {
    return "email:$EmailHash"
  }
  return "unknown"
}

$inputFull = (Resolve-Path $InputPath).Path
$report = Get-Content -LiteralPath $inputFull -Raw | ConvertFrom-Json

if ([string]$report.importer -ne "sub2api-source-dryrun") {
  throw "InputPath must point to output from import-sub2api-dryrun.ps1. Observed importer '$($report.importer)'."
}
if (-not [bool]$report.dry_run) {
  throw "Sub2API identity/billing planning requires a dry-run source report."
}

$currencyCode = ([string](Redact-SecretLikeString $Currency)).Trim().ToUpperInvariant()
if ($currencyCode -notmatch "^[A-Z]{3,8}$") {
  throw "Currency must be an uppercase currency or quota unit code."
}

$userProfileMappings = New-Object System.Collections.Generic.List[object]
$openingBalancePlans = New-Object System.Collections.Generic.List[object]
$userKeyReissueHandoffs = New-Object System.Collections.Generic.List[object]
$subscriptionReviewItems = New-Object System.Collections.Generic.List[object]
$manualReviewItems = New-Object System.Collections.Generic.List[object]

$usersBySource = @{}
foreach ($user in (Convert-ToArray $report.users)) {
  $sourceId = Redact-SecretLikeString (Get-PropertyValue $user @("source_id") (Get-StableHash $user))
  $emailHash = Redact-SecretLikeString (Get-PropertyValue $user @("email_hash") $null)
  $mappingId = New-PlanId "sub2api-user" "$sourceId|$emailHash"
  $userKey = New-UserKey $sourceId $emailHash
  $usersBySource[$userKey] = $mappingId

  $userProfileMappings.Add([ordered]@{
      mapping_id = $mappingId
      source = "sub2api"
      source_user_id = $sourceId
      source_email_hash = $emailHash
      username = Redact-SecretLikeString (Get-PropertyValue $user @("username") $null)
      status = Redact-SecretLikeString (Get-PropertyValue $user @("status") "enabled")
      target_action = "operator_review_then_create_or_link_user"
      raw_email_exported = $false
      raw_password_exported = $false
      database_writes_by_importer = $false
    }) | Out-Null

  $balance = Convert-ToSafeAmount (Get-PropertyValue $user @("balance") $null)
  if ($null -ne $balance) {
    $openingBalancePlans.Add([ordered]@{
        plan_id = New-PlanId "sub2api-opening-balance" "$sourceId|$balance|$currencyCode"
        source = "sub2api"
        source_user_id = $sourceId
        source_user_mapping_id = $mappingId
        target_wallet_lookup = "operator_review_required"
        amount = $balance
        currency = $currencyCode
        ledger_entry_type = "opening_balance_import"
        reason = "Sub2API opening balance migration; operator must verify source quota unit and currency before apply."
        apply_supported = $false
        requires_unit_review = $true
        database_writes_by_importer = $false
      }) | Out-Null
  }
}

foreach ($apiKey in (Convert-ToArray $report.api_keys)) {
  $sourceId = Redact-SecretLikeString (Get-PropertyValue $apiKey @("source_id") (Get-StableHash $apiKey))
  $userSourceId = Redact-SecretLikeString (Get-PropertyValue $apiKey @("user_source_id") $null)
  $emailHash = Redact-SecretLikeString (Get-PropertyValue $apiKey @("user_email_hash") $null)
  $userKey = New-UserKey $userSourceId $emailHash
  $mappingId = if ($usersBySource.ContainsKey($userKey)) { $usersBySource[$userKey] } else { $null }

  $userKeyReissueHandoffs.Add([ordered]@{
      handoff_id = New-PlanId "sub2api-user-key" "$sourceId|$userKey"
      source = "sub2api"
      source_key_id = $sourceId
      source_user_id = $userSourceId
      source_user_email_hash = $emailHash
      source_user_mapping_id = $mappingId
      name = Redact-SecretLikeString (Get-PropertyValue $apiKey @("name") $sourceId)
      status = Redact-SecretLikeString (Get-PropertyValue $apiKey @("status") "enabled")
      group_source_id = Redact-SecretLikeString (Get-PropertyValue $apiKey @("group_source_id") $null)
      quota = Convert-ToSafeAmount (Get-PropertyValue $apiKey @("quota") $null)
      quota_used = Convert-ToSafeAmount (Get-PropertyValue $apiKey @("quota_used") $null)
      expires_at = Redact-SecretLikeString (Get-PropertyValue $apiKey @("expires_at") $null)
      rate_limit_rpm = Redact-SecretLikeString (Get-PropertyValue $apiKey @("rate_limit_rpm") $null)
      source_key_hash = Redact-SecretLikeString (Get-PropertyValue $apiKey @("key_hash") $null)
      source_secret_present = [bool](Get-PropertyValue $apiKey @("has_secret") $false)
      raw_key_exported = $false
      secret_material_included = $false
      apply_directly_supported = $false
      apply_mode = "operator_reissue_only"
      required_operator_path = "POST /auth/api-keys"
      operator_instruction = "Create a fresh Fubox user key for the mapped user. Do not import or reuse the Sub2API raw key material."
    }) | Out-Null

  if ($null -eq $mappingId) {
    $manualReviewItems.Add([ordered]@{
        type = "user_key_without_user_mapping"
        severity = "warning"
        source_id = $sourceId
        reason = "Sub2API user key could not be matched to a planned user profile mapping."
        recommended_action = "Map or create the user before reissuing this API key."
      }) | Out-Null
  }
}

foreach ($subscription in (Convert-ToArray $report.subscriptions)) {
  $sourceId = Redact-SecretLikeString (Get-PropertyValue $subscription @("source_id") (Get-StableHash $subscription))
  $userSourceId = Redact-SecretLikeString (Get-PropertyValue $subscription @("user_source_id") $null)
  $userKey = New-UserKey $userSourceId $null
  $mappingId = if ($usersBySource.ContainsKey($userKey)) { $usersBySource[$userKey] } else { $null }

  $subscriptionReviewItems.Add([ordered]@{
      review_id = New-PlanId "sub2api-subscription" "$sourceId|$userSourceId"
      source = "sub2api"
      source_subscription_id = $sourceId
      source_user_id = $userSourceId
      source_user_mapping_id = $mappingId
      group_source_id = Redact-SecretLikeString (Get-PropertyValue $subscription @("group_source_id") $null)
      plan = Redact-SecretLikeString (Get-PropertyValue $subscription @("plan") $null)
      starts_at = Redact-SecretLikeString (Get-PropertyValue $subscription @("starts_at") $null)
      expires_at = Redact-SecretLikeString (Get-PropertyValue $subscription @("expires_at") $null)
      quota = Convert-ToSafeAmount (Get-PropertyValue $subscription @("quota") $null)
      target_action = "manual_subscription_package_mapping_required"
      apply_supported = $false
      database_writes_by_importer = $false
    }) | Out-Null

  $manualReviewItems.Add([ordered]@{
      type = "subscription_package_mapping_required"
      severity = "warning"
      source_id = $sourceId
      reason = "Sub2API subscription needs explicit Fubox package lifecycle mapping before any apply path."
      recommended_action = "Review plan, quota, expiry, and target package semantics before migration."
    }) | Out-Null
}

$counts = [ordered]@{
  input_reports = 1
  source_users = @(Convert-ToArray $report.users).Count
  source_api_keys = @(Convert-ToArray $report.api_keys).Count
  source_subscriptions = @(Convert-ToArray $report.subscriptions).Count
  user_profile_mappings = $userProfileMappings.Count
  opening_balance_plans = $openingBalancePlans.Count
  user_key_reissue_handoffs = $userKeyReissueHandoffs.Count
  subscription_review_items = $subscriptionReviewItems.Count
  manual_review_items = $manualReviewItems.Count
}

$applyPlanArtifacts = [ordered]@{
  schema_version = "importer.source-specific-apply-plan-artifacts.v1"
  source_system = "sub2api"
  secret_safe = $true
  raw_provider_key_material_included = $false
  raw_user_key_material_included = $false
  raw_email_included = $false
  categories = [ordered]@{
    migratable = [ordered]@{
      channels = @()
      model_mappings = @()
    }
    manual = [ordered]@{
      user_link_candidates = @($userProfileMappings.ToArray())
      wallet_opening_balance_candidates = @($openingBalancePlans.ToArray())
      user_key_reissue_handoffs = @($userKeyReissueHandoffs.ToArray())
      subscription_mappings = @($subscriptionReviewItems.ToArray())
    }
    blocked = [ordered]@{
      raw_user_key_import = @($userKeyReissueHandoffs.ToArray())
      opening_balance_direct_apply_without_unit_review = @($openingBalancePlans.ToArray())
      subscription_direct_apply_without_package_mapping = @($subscriptionReviewItems.ToArray())
    }
  }
  classification_counts = [ordered]@{
    migratable = 0
    manual = $userProfileMappings.Count + $openingBalancePlans.Count + $userKeyReissueHandoffs.Count + $subscriptionReviewItems.Count
    blocked = $userKeyReissueHandoffs.Count + $openingBalancePlans.Count + $subscriptionReviewItems.Count
  }
  automation_matrix = [ordered]@{
    automatic_apply = @()
    operator_handoff = @("user_link_candidates", "wallet_opening_balance_candidates", "user_key_reissue_handoffs", "subscription_mappings")
    blocked_without_operator = @("raw_user_key_import", "opening_balance_direct_apply_without_unit_review", "subscription_direct_apply_without_package_mapping")
  }
  executable_handoff = [ordered]@{
    schema_version = "importer.source-specific-executable-handoff.v1"
    source_system = "sub2api"
    generated_for = "identity_billing_reviewed_apply_plan"
    secret_safe = $true
    runner_inputs = [ordered]@{
      user_link_candidates = @($userProfileMappings.ToArray())
      wallet_opening_balance_candidates = @($openingBalancePlans.ToArray())
      user_key_reissue_handoffs = @($userKeyReissueHandoffs.ToArray())
      subscription_mappings = @($subscriptionReviewItems.ToArray())
    }
    executable_fields = [ordered]@{
      user_link = @("mapping_id", "source_user_id", "source_email_hash", "username", "status", "target_action")
      wallet_lookup = @("plan_id", "source_user_id", "source_user_mapping_id", "target_wallet_lookup", "amount", "currency")
      opening_balance = @("plan_id", "source_user_mapping_id", "amount", "currency", "ledger_entry_type", "requires_unit_review")
      key_reissue = @("handoff_id", "source_key_id", "source_user_mapping_id", "source_key_hash", "required_operator_path", "apply_mode")
      subscription_mapping = @("review_id", "source_subscription_id", "source_user_mapping_id", "group_source_id", "plan", "quota", "target_action")
    }
    apply_modes = [ordered]@{
      user_link = "operator_create_or_link_required"
      wallet_lookup = "operator_lookup_or_create_required"
      opening_balance = "operator_unit_review_required"
      key_reissue = "operator_reissue_only"
      subscription_mapping = "operator_package_mapping_required"
    }
    difference_explanation = [ordered]@{
      automatic = "No Sub2API identity/billing write is automatic in this slice."
      manual = "User link/create, wallet lookup/opening balance, key reissue, and subscription mapping have secret-safe executable fields for reviewed operator handoff."
      blocked = "Raw user key import, unreviewed opening balance import, and subscription direct apply without package mapping are blocked."
    }
    forbidden_payload_fields = @("raw_user_key", "raw_email", "raw_password", "payment_secret", "authorization", "bearer_token", "password")
  }
}

$plan = [ordered]@{
  importer = "sub2api-identity-billing-plan-dryrun"
  schema_version = "sub2api.identity-billing-plan.v1"
  dry_run = $true
  generated_at = (Get-Date).ToUniversalTime().ToString("o")
  input_files = @($inputFull)
  tenant_id = Redact-SecretLikeString $TenantId
  currency = $currencyCode
  apply_supported = $false
  database_writes = $false
  live_database_connection = $false
  secret_handling_contract = [ordered]@{
    schema_version = "importer.identity-billing-secret-contract.v1"
    raw_user_key_material_allowed = $false
    raw_user_key_material_included = $false
    raw_email_allowed = $false
    operator_reissue_required = $true
    required_user_key_path = "POST /auth/api-keys"
  }
  preflight = [ordered]@{
    schema_version = "sub2api.identity-billing-preflight.v1"
    status = "blocked"
    checks = @(
      [ordered]@{
        name = "source_report_shape"
        status = "pass"
        note = "Input is a Sub2API source dry-run report."
      },
      [ordered]@{
        name = "secret_material_boundary"
        status = "pass"
        note = "User key secrets are represented only by source hashes and reissue handoff metadata."
      },
      [ordered]@{
        name = "identity_and_billing_writer"
        status = "blocked"
        note = "This plan is review-only and intentionally performs no user, wallet, key, subscription, or ledger writes."
      }
    )
  }
  counts = $counts
  summary = $counts
  user_profile_mappings = @($userProfileMappings.ToArray())
  opening_balance_plans = @($openingBalancePlans.ToArray())
  user_key_reissue_handoffs = @($userKeyReissueHandoffs.ToArray())
  subscription_review_items = @($subscriptionReviewItems.ToArray())
  apply_plan_artifacts = $applyPlanArtifacts
  manual_review_items = @($manualReviewItems.ToArray())
  next_steps = @(
    "Review user_profile_mappings and decide whether to create or link Fubox users.",
    "Verify opening_balance_plans currency/unit semantics before any ledger import.",
    "Reissue user API keys through POST /auth/api-keys; do not import raw Sub2API key material.",
    "Map subscriptions to Fubox package lifecycle rules before any subscription apply path."
  )
}

$json = $plan | ConvertTo-Json -Depth 64
$safeJson = Redact-SecretLikeString $json
if ($safeJson -match "sk-[A-Za-z0-9_-]+" -or $safeJson -match "(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}" -or $safeJson -match "(?i)(api[_-]?key|authorization|token|password)=([^<][^&\s`"]+)") {
  throw "Refusing to emit Sub2API identity/billing plan because output still contains secret-like material."
}

Write-Output $safeJson
