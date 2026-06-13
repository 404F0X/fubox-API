[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$InputPath,

  [string]$TenantId = "00000000-0000-0000-0000-000000000001",

  [ValidateSet("OperatorHandoff", "GenericApplyPlanInput")]
  [string]$OutputFormat = "OperatorHandoff",

  [switch]$DryRun = $true
)

$ErrorActionPreference = "Stop"

if (-not [bool]$DryRun) {
  throw "Only dry-run operator handoff planning is implemented. Re-run with -DryRun or omit the flag."
}

function Get-PropertyValue {
  param(
    [object]$Object,
    [string[]]$Names,
    [object]$Default = $null
  )

  if ($null -eq $Object) { return $Default }
  if ($Object -is [System.Collections.IDictionary]) {
    foreach ($name in $Names) {
      if ($Object.Contains($name) -and $null -ne $Object[$name]) { return $Object[$name] }
    }
  }

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
  $text = $text -replace "://([^:/@\s]+):([^/@\s]+)@", "://<redacted>@"
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

function Convert-ToSlug {
  param([AllowNull()][object]$Value)

  $text = if ($null -eq $Value) { "unknown" } else { [string]$Value }
  $slug = $text.Trim().ToLowerInvariant() -replace "[^a-z0-9]+", "-"
  $slug = $slug.Trim("-")
  if ([string]::IsNullOrWhiteSpace($slug)) { return "unknown" }
  return $slug
}

function Convert-ToSafeObject {
  param([AllowNull()][object]$Value)

  if ($null -eq $Value) { return $null }
  $json = $Value | ConvertTo-Json -Depth 32 -Compress
  return (Redact-SecretLikeString $json) | ConvertFrom-Json
}

function Convert-ToObjectArray {
  param([AllowNull()][object]$Value)

  if ($null -eq $Value) { return @() }
  if ($Value -is [string]) { return @($Value) }
  if ($Value -is [System.Collections.IDictionary]) { return @($Value) }
  if ($Value -is [System.Collections.IEnumerable]) {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($item in $Value) { $items.Add($item) | Out-Null }
    return ,([object[]]$items.ToArray())
  }
  return @($Value)
}

function Add-UniqueText {
  param(
    [System.Collections.Generic.List[string]]$List,
    [AllowNull()][object]$Value
  )

  if ($null -eq $Value) { return }
  $text = (Redact-SecretLikeString $Value).Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { return }
  if (-not $List.Contains($text)) { $List.Add($text) | Out-Null }
}

function Get-AccountEndpoint {
  param([object]$Account)

  $extra = Get-PropertyValue $Account @("extra_preview") $null
  if ($null -eq $extra) { return $null }
  return Redact-SecretLikeString (Get-PropertyValue $extra @("base_url", "endpoint", "url") $null)
}

function New-HandoffId {
  param([string]$Prefix, [object]$Seed)
  return "$Prefix-$(Get-StableHash $Seed 16)"
}

$inputFull = (Resolve-Path $InputPath).Path
$report = Get-Content -LiteralPath $inputFull -Raw | ConvertFrom-Json

if ([string]$report.importer -ne "sub2api-source-dryrun") {
  throw "InputPath must point to output from import-sub2api-dryrun.ps1. Observed importer '$($report.importer)'."
}
if (-not [bool]$report.dry_run) {
  throw "Sub2API apply handoff requires a dry-run source report."
}

$providerPlans = New-Object System.Collections.Generic.List[object]
$channelPlans = New-Object System.Collections.Generic.List[object]
$providerKeyHandoffs = New-Object System.Collections.Generic.List[object]
$accountGroupBindings = New-Object System.Collections.Generic.List[object]
$operatorSteps = New-Object System.Collections.Generic.List[object]
$manualReview = New-Object System.Collections.Generic.List[object]

$proxiesByKey = @{}
foreach ($proxy in (Convert-ToArray $report.proxies)) {
  $proxyKey = Redact-SecretLikeString (Get-PropertyValue $proxy @("proxy_key", "key", "id", "name") $null)
  if (-not [string]::IsNullOrWhiteSpace($proxyKey)) {
    $proxiesByKey[$proxyKey] = $proxy
  }
}

$groupsBySourceId = @{}
foreach ($group in (Convert-ToArray $report.groups)) {
  $groupId = Redact-SecretLikeString (Get-PropertyValue $group @("source_id", "id", "name", "key") $null)
  if (-not [string]::IsNullOrWhiteSpace($groupId)) {
    $groupsBySourceId[$groupId] = $group
  }
}

$providerCodes = @{}
foreach ($account in (Convert-ToArray $report.accounts)) {
  $sourceId = Redact-SecretLikeString (Get-PropertyValue $account @("source_id") (Get-StableHash $account))
  $platform = Redact-SecretLikeString (Get-PropertyValue $account @("platform") "sub2api")
  $providerCode = Convert-ToSlug $platform
  $providerName = if ($platform) { $platform } else { "Sub2API" }
  $channelName = Redact-SecretLikeString (Get-PropertyValue $account @("name") $sourceId)
  $endpoint = Get-AccountEndpoint $account
  $channelSourceId = "sub2api:account:$sourceId"
  $providerKeyAlias = Convert-ToSlug "$providerCode-$channelName"
  $proxyKey = Redact-SecretLikeString (Get-PropertyValue $account @("proxy_key") $null)
  $proxyPreview = $null
  if (-not [string]::IsNullOrWhiteSpace($proxyKey) -and $proxiesByKey.ContainsKey($proxyKey)) {
    $proxyPreview = Convert-ToSafeObject $proxiesByKey[$proxyKey]
  }
  $groupPreviews = New-Object System.Collections.Generic.List[object]
  foreach ($groupName in (Convert-ToArray (Get-PropertyValue $account @("groups") @()))) {
    $safeGroupName = Redact-SecretLikeString $groupName
    if (-not [string]::IsNullOrWhiteSpace($safeGroupName) -and $groupsBySourceId.ContainsKey($safeGroupName)) {
      $groupPreviews.Add((Convert-ToSafeObject $groupsBySourceId[$safeGroupName])) | Out-Null
    }
  }

  if (-not $providerCodes.ContainsKey($providerCode)) {
    $providerCodes[$providerCode] = $true
    $providerPlans.Add([ordered]@{
        source = "sub2api"
        provider_code = $providerCode
        provider_name = $providerName
        provider_type = "openai-compatible"
        planned_action = "operator_review_then_upsert"
        metadata = [ordered]@{
          source_importer = "sub2api"
          tenant_id = Redact-SecretLikeString $TenantId
        }
      }) | Out-Null
  }

  $channelPlans.Add([ordered]@{
      source = "sub2api"
      channel_source_id = $channelSourceId
      provider_code = $providerCode
      channel_name = $channelName
      endpoint = $endpoint
      status = Redact-SecretLikeString (Get-PropertyValue $account @("status") "enabled")
      priority = Redact-SecretLikeString (Get-PropertyValue $account @("priority") $null)
      groups = @(Convert-ToArray (Get-PropertyValue $account @("groups") @()))
      rate_multiplier = Redact-SecretLikeString (Get-PropertyValue $account @("rate_multiplier") $null)
      planned_action = "operator_review_then_upsert"
      requires_provider_key = [bool](Get-PropertyValue $account @("credential_material_present") $false)
      metadata = [ordered]@{
        source_account_id = $sourceId
        proxy_key = $proxyKey
        proxy_preview = $proxyPreview
        group_previews = @($groupPreviews.ToArray())
        source_importer = "sub2api"
        provider_key_material_imported = $false
      }
    }) | Out-Null

  foreach ($groupName in (Convert-ToArray (Get-PropertyValue $account @("groups") @()))) {
    $accountGroupBindings.Add([ordered]@{
        channel_source_id = $channelSourceId
        group_source_id = Redact-SecretLikeString $groupName
        binding_status = "evidence_only"
      }) | Out-Null
  }

  if ([bool](Get-PropertyValue $account @("credential_material_present") $false)) {
    $credentialHash = Redact-SecretLikeString (Get-PropertyValue $account @("credential_locator_hash") $null)
    $providerKeyHandoffs.Add([ordered]@{
        handoff_id = New-HandoffId "sub2api-provider-key" "$channelSourceId|$credentialHash"
        source = "sub2api"
        channel_source_id = $channelSourceId
        provider_code = $providerCode
        channel_name = $channelName
        key_alias = $providerKeyAlias
        credential_material_present = $true
        credential_locator_redacted = "<redacted>"
        credential_locator_hashes = @($credentialHash)
        credential_keys = @(Convert-ToArray (Get-PropertyValue $account @("credential_keys") @()))
        raw_material_exported = $false
        provider_key_material_included = $false
        apply_directly_supported = $false
        apply_mode = "sidecar_only"
        required_operator_path = "POST /admin/provider-keys"
        recommended_path = "POST /admin/provider-keys"
        operator_instruction = "Create provider/channel first, then enter this upstream credential through the Provider Key page or POST /admin/provider-keys. Do not paste credentials into importer artifacts."
      }) | Out-Null
  } else {
    $manualReview.Add([ordered]@{
        type = "provider_key_missing"
        source_id = $sourceId
        reason = "Sub2API account did not include credential evidence; operator must decide whether a provider key is needed."
      }) | Out-Null
  }
}

foreach ($item in (Convert-ToArray $report.non_migratable_items)) {
  $manualReview.Add([ordered]@{
      type = Redact-SecretLikeString (Get-PropertyValue $item @("type") "unknown")
      source_id = Redact-SecretLikeString (Get-PropertyValue $item @("source_id") $null)
      severity = Redact-SecretLikeString (Get-PropertyValue $item @("severity") "warning")
      reason = Redact-SecretLikeString (Get-PropertyValue $item @("reason") "Manual review required.")
      recommended_action = Redact-SecretLikeString (Get-PropertyValue $item @("recommended_action") "Review before apply.")
      preview = Convert-ToSafeObject (Get-PropertyValue $item @("preview") $null)
    }) | Out-Null
}

$operatorSteps.Add([ordered]@{
    order = 1
    title = "Review Sub2API source evidence"
    command = "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/importers/import-sub2api-dryrun.ps1 -InputPath <sub2api-export.json>"
  }) | Out-Null
$operatorSteps.Add([ordered]@{
    order = 2
    title = "Create or confirm providers and channels"
    target_count = $channelPlans.Count
    database_writes_by_importer = $false
  }) | Out-Null
$operatorSteps.Add([ordered]@{
    order = 3
    title = "Enter provider keys through Control Plane"
    required_operator_path = "POST /admin/provider-keys"
    handoff_count = $providerKeyHandoffs.Count
    raw_material_allowed_in_artifact = $false
  }) | Out-Null
$operatorSteps.Add([ordered]@{
    order = 4
    title = "Map groups/users/subscriptions in a later reviewed apply plan"
    manual_review_count = $manualReview.Count
  }) | Out-Null

$preflightChecks = @(
  [ordered]@{
    name = "source_report_shape"
    status = "pass"
    note = "Input is a Sub2API source dry-run report."
  },
  [ordered]@{
    name = "provider_key_secret_management_handoff"
    status = "pass"
    note = "Provider key material is represented only as redacted sidecar metadata."
  },
  [ordered]@{
    name = "database_writer_available"
    status = "blocked"
    note = "This plan is operator-handoff only and intentionally performs no database writes."
  }
)

$counts = [ordered]@{
  input_reports = 1
  source_accounts = @(Convert-ToArray $report.accounts).Count
  planned_providers = $providerPlans.Count
  planned_channels = $channelPlans.Count
  source_account_group_bindings = $accountGroupBindings.Count
  provider_key_handoffs = $providerKeyHandoffs.Count
  manual_review_items = $manualReview.Count
  source_users = @(Convert-ToArray $report.users).Count
  source_api_keys = @(Convert-ToArray $report.api_keys).Count
  source_subscriptions = @(Convert-ToArray $report.subscriptions).Count
}

function New-MappingQualityReadback {
  param(
    [object[]]$ProviderPlans,
    [object[]]$ChannelPlans,
    [object[]]$ProviderKeyHandoffs,
    [object[]]$ManualReviewItems,
    [object[]]$SourceUsers,
    [object[]]$SourceApiKeys,
    [object[]]$SourceSubscriptions,
    [object[]]$AccountGroupBindings
  )

  $nonMigratableReasons = @($ManualReviewItems | ForEach-Object {
      [ordered]@{
        type = Redact-SecretLikeString (Get-PropertyValue $_ @("type") "manual_review")
        severity = Redact-SecretLikeString (Get-PropertyValue $_ @("severity") "warning")
        reason = Redact-SecretLikeString (Get-PropertyValue $_ @("reason", "summary") "Manual review required.")
        recommended_action = Redact-SecretLikeString (Get-PropertyValue $_ @("recommended_action") "Review before apply.")
      }
    })

  return [ordered]@{
    schema_version = "importer.mapping-quality-readback.v1"
    source_system = "sub2api"
    status = "operator-handoff-required"
    dry_run_only = $true
    secret_safe = $true
    mapping_counts = [ordered]@{
      provider_mappings = $ProviderPlans.Count
      channel_mappings = $ChannelPlans.Count
      model_mappings = 0
      canonical_model_candidates = 0
      user_mappings = $SourceUsers.Count
      key_mappings = $ProviderKeyHandoffs.Count + $SourceApiKeys.Count
      provider_key_handoffs = $ProviderKeyHandoffs.Count
      user_key_reissue_handoffs = $SourceApiKeys.Count
      wallet_mappings = $SourceUsers.Count
      subscription_mappings = $SourceSubscriptions.Count
      group_mappings = $AccountGroupBindings.Count
      non_migratable_items = $ManualReviewItems.Count
      conflicts = 0
    }
    conflicts = [ordered]@{
      count = 0
      blocking_count = 0
      refs = @()
    }
    non_migratable_reasons = $nonMigratableReasons
    operator_handoff_refs_presence = [ordered]@{
      provider_key_handoffs_present = $ProviderKeyHandoffs.Count -gt 0
      provider_key_handoff_refs_present = $ProviderKeyHandoffs.Count -gt 0
      user_key_reissue_refs_present = $SourceApiKeys.Count -gt 0
      wallet_opening_balance_refs_present = $SourceUsers.Count -gt 0
      subscription_mapping_refs_present = $SourceSubscriptions.Count -gt 0
      required_operator_path_present = $ProviderKeyHandoffs.Count -gt 0 -or $SourceApiKeys.Count -gt 0
    }
    safe_next_action = "Review provider/channel plans, enter provider keys through POST /admin/provider-keys, and keep users, wallets, user keys, and subscriptions on the reviewed operator handoff path."
    forbidden_material_returned = $false
    raw_provider_key_returned = $false
    raw_user_key_returned = $false
    token_returned = $false
    db_url_returned = $false
    raw_sql_returned = $false
    authorization_returned = $false
  }
}

$mappingQualityReadback = New-MappingQualityReadback `
  -ProviderPlans @($providerPlans.ToArray()) `
  -ChannelPlans @($channelPlans.ToArray()) `
  -ProviderKeyHandoffs @($providerKeyHandoffs.ToArray()) `
  -ManualReviewItems @($manualReview.ToArray()) `
  -SourceUsers @(Convert-ToArray $report.users) `
  -SourceApiKeys @(Convert-ToArray $report.api_keys) `
  -SourceSubscriptions @(Convert-ToArray $report.subscriptions) `
  -AccountGroupBindings @($accountGroupBindings.ToArray())

$sourceUserLinks = @((Convert-ToArray $report.users) | ForEach-Object {
    [ordered]@{
      source_user_id = Redact-SecretLikeString (Get-PropertyValue $_ @("source_id", "id") $null)
      source_email_hash = Redact-SecretLikeString (Get-PropertyValue $_ @("email_hash") $null)
      username = Redact-SecretLikeString (Get-PropertyValue $_ @("username") $null)
      status = Redact-SecretLikeString (Get-PropertyValue $_ @("status") "enabled")
      raw_email_exported = $false
      classification = "manual"
      target_action = "operator_review_then_create_or_link_user"
    }
  })

$sourceOpeningBalances = @((Convert-ToArray $report.users) | Where-Object { $null -ne (Get-PropertyValue $_ @("balance") $null) } | ForEach-Object {
    [ordered]@{
      source_user_id = Redact-SecretLikeString (Get-PropertyValue $_ @("source_id", "id") $null)
      opening_balance = Redact-SecretLikeString (Get-PropertyValue $_ @("balance") $null)
      unit = "source_system_units"
      classification = "manual"
      target_action = "opening_balance_ledger_import_after_unit_review"
      apply_supported = $false
    }
  })

$sourceKeyReissue = @((Convert-ToArray $report.api_keys) | ForEach-Object {
    [ordered]@{
      source_key_id = Redact-SecretLikeString (Get-PropertyValue $_ @("source_id", "id") $null)
      source_user_id = Redact-SecretLikeString (Get-PropertyValue $_ @("user_source_id", "user_id") $null)
      source_key_fingerprint = Redact-SecretLikeString (Get-PropertyValue $_ @("key_hash") $null)
      raw_key_exported = $false
      secret_material_included = $false
      classification = "blocked"
      target_action = "reissue_user_key"
      required_operator_path = "POST /auth/api-keys"
    }
  })

$sourceSubscriptionMappings = @((Convert-ToArray $report.subscriptions) | ForEach-Object {
    [ordered]@{
      source_subscription_id = Redact-SecretLikeString (Get-PropertyValue $_ @("source_id", "id") $null)
      source_user_id = Redact-SecretLikeString (Get-PropertyValue $_ @("user_source_id", "user_id") $null)
      group_source_id = Redact-SecretLikeString (Get-PropertyValue $_ @("group_source_id", "group_id") $null)
      plan = Redact-SecretLikeString (Get-PropertyValue $_ @("plan") $null)
      quota = Redact-SecretLikeString (Get-PropertyValue $_ @("quota") $null)
      classification = "manual"
      target_action = "manual_subscription_package_mapping_required"
      apply_supported = $false
    }
  })

$applyPlanArtifacts = [ordered]@{
  schema_version = "importer.source-specific-apply-plan-artifacts.v1"
  source_system = "sub2api"
  secret_safe = $true
  raw_provider_key_material_included = $false
  raw_user_key_material_included = $false
  categories = [ordered]@{
    migratable = [ordered]@{
      channels = @($channelPlans.ToArray())
      model_mappings = @()
    }
    manual = [ordered]@{
      provider_key_operator_handoffs = @($providerKeyHandoffs.ToArray())
      group_mappings = @($accountGroupBindings.ToArray())
      user_link_candidates = @($sourceUserLinks)
      wallet_opening_balance_candidates = @($sourceOpeningBalances)
      subscription_mappings = @($sourceSubscriptionMappings)
    }
    blocked = [ordered]@{
      provider_key_direct_import = @($providerKeyHandoffs.ToArray())
      user_key_reissue_handoffs = @($sourceKeyReissue)
      identity_billing_direct_apply = @(
        "users",
        "wallets",
        "opening_balances",
        "user_keys",
        "subscriptions"
      )
    }
  }
  classification_counts = [ordered]@{
    migratable = $channelPlans.Count
    manual = $providerKeyHandoffs.Count + $accountGroupBindings.Count + $sourceUserLinks.Count + $sourceOpeningBalances.Count + $sourceSubscriptionMappings.Count
    blocked = $providerKeyHandoffs.Count + $sourceKeyReissue.Count + 5
  }
  automation_matrix = [ordered]@{
    automatic_apply = @("channels")
    operator_handoff = @("provider_key_operator_handoffs", "group_mappings", "user_link_candidates", "wallet_opening_balance_candidates", "subscription_mappings")
    blocked_without_operator = @("provider_key_direct_import", "user_key_reissue_handoffs", "identity_billing_direct_apply")
  }
  executable_handoff = [ordered]@{
    schema_version = "importer.source-specific-executable-handoff.v1"
    source_system = "sub2api"
    generated_for = "reviewed_apply_plan"
    secret_safe = $true
    runner_inputs = [ordered]@{
      channels = @($channelPlans.ToArray())
      provider_key_reissue_handoffs = @($providerKeyHandoffs.ToArray())
      group_mappings = @($accountGroupBindings.ToArray())
      user_link_candidates = @($sourceUserLinks)
      wallet_opening_balance_candidates = @($sourceOpeningBalances)
      user_key_reissue_handoffs = @($sourceKeyReissue)
      subscription_mappings = @($sourceSubscriptionMappings)
    }
    executable_fields = [ordered]@{
      channel = @("channel_source_id", "provider_code", "channel_name", "endpoint", "status", "priority", "groups", "planned_action")
      provider_key = @("handoff_id", "channel_source_id", "provider_code", "key_alias", "credential_locator_hashes", "required_operator_path", "apply_mode")
      user_link = @("source_user_id", "source_email_hash", "username", "status", "target_action")
      wallet_lookup = @("source_user_id", "opening_balance", "unit", "target_action", "apply_supported")
      opening_balance = @("source_user_id", "opening_balance", "unit", "target_action", "apply_supported")
      key_reissue = @("source_key_id", "source_user_id", "source_key_fingerprint", "required_operator_path", "target_action")
      subscription_mapping = @("source_subscription_id", "source_user_id", "group_source_id", "plan", "quota", "target_action", "apply_supported")
    }
    apply_modes = [ordered]@{
      channel = "automatic_after_review"
      provider_key = "operator_handoff_only"
      user_link = "operator_create_or_link_required"
      wallet_lookup = "operator_lookup_or_create_required"
      opening_balance = "operator_unit_review_required"
      key_reissue = "operator_reissue_only"
      subscription_mapping = "operator_package_mapping_required"
    }
    difference_explanation = [ordered]@{
      automatic = "Sub2API account/provider-channel shape can feed reviewed provider/channel apply-plan without secret material."
      manual = "User link/create, wallet lookup, opening balance, provider key entry, and subscription package mapping require operator confirmation."
      blocked = "Raw provider credentials, raw user keys, payment secrets, and proxy passwords are never executable payload."
    }
    forbidden_payload_fields = @("raw_provider_key", "raw_user_key", "proxy_password", "payment_secret", "authorization", "bearer_token", "password")
  }
}

function New-GenericApplyPlanInputReport {
  param(
    [object[]]$ProviderPlans,
    [object[]]$ChannelPlans,
    [object[]]$ProviderKeyHandoffs,
    [object[]]$ManualReviewItems,
    [object[]]$AccountGroupBindings,
    [object]$SourceReport,
    [string]$InputFile,
    [string]$TenantIdValue
  )

  $providersByCode = @{}
  foreach ($provider in $ProviderPlans) {
    $providerCode = Redact-SecretLikeString (Get-PropertyValue $provider @("provider_code", "code") $null)
    if (-not [string]::IsNullOrWhiteSpace($providerCode) -and -not $providersByCode.ContainsKey($providerCode)) {
      $providersByCode[$providerCode] = $provider
    }
  }

  $channelMappings = New-Object System.Collections.Generic.List[object]
  foreach ($channel in $ChannelPlans) {
    $channelSourceId = Redact-SecretLikeString (Get-PropertyValue $channel @("channel_source_id", "source_id") $null)
    if ([string]::IsNullOrWhiteSpace($channelSourceId)) {
      continue
    }

    $providerCode = Redact-SecretLikeString (Get-PropertyValue $channel @("provider_code", "provider") "sub2api")
    $providerName = $providerCode
    if ($providersByCode.ContainsKey($providerCode)) {
      $providerName = Redact-SecretLikeString (Get-PropertyValue $providersByCode[$providerCode] @("provider_name", "name") $providerCode)
    }

    $tags = New-Object System.Collections.Generic.List[string]
    Add-UniqueText $tags "sub2api"
    foreach ($groupName in (Convert-ToArray (Get-PropertyValue $channel @("groups", "tags") @()))) {
      Add-UniqueText $tags $groupName
    }
    $proxyKey = Get-PropertyValue (Get-PropertyValue $channel @("metadata") $null) @("proxy_key") $null
    if (-not [string]::IsNullOrWhiteSpace([string]$proxyKey)) {
      Add-UniqueText $tags "proxy:$proxyKey"
    }

    $channelMappings.Add([ordered]@{
        channel_source_id = $channelSourceId
        channel_present = $true
        provider_code = $providerCode
        provider_name = $providerName
        channel_name = Redact-SecretLikeString (Get-PropertyValue $channel @("channel_name", "name") $channelSourceId)
        endpoint = Redact-SecretLikeString (Get-PropertyValue $channel @("endpoint", "base_url", "url") $null)
        protocol_mode = "openai_compatible"
        priority = Redact-SecretLikeString (Get-PropertyValue $channel @("priority") 100)
        weight = 100
        tags = @($tags.ToArray())
        status = Redact-SecretLikeString (Get-PropertyValue $channel @("status") "enabled")
        mapping_entries = @()
        planned_action = "bind_or_create_channel_mapping"
        source_context = [ordered]@{
          source = "sub2api"
          source_account_id = Redact-SecretLikeString (Get-PropertyValue (Get-PropertyValue $channel @("metadata") $null) @("source_account_id") $null)
          proxy_key = Redact-SecretLikeString $proxyKey
          account_groups = @(Convert-ToArray (Get-PropertyValue $channel @("groups") @()))
          proxy_preview = Convert-ToSafeObject (Get-PropertyValue (Get-PropertyValue $channel @("metadata") $null) @("proxy_preview") $null)
          group_previews = Convert-ToObjectArray (Get-PropertyValue (Get-PropertyValue $channel @("metadata") $null) @("group_previews") @())
          provider_key_material_imported = $false
        }
      }) | Out-Null
  }

  $bridgeManualReview = New-Object System.Collections.Generic.List[object]
  foreach ($item in $ManualReviewItems) {
    $bridgeManualReview.Add((Convert-ToSafeObject $item)) | Out-Null
  }

  $sourceCounts = Get-PropertyValue $SourceReport @("counts", "summary") ([ordered]@{})
  $identityEvidenceCount = [int](Get-PropertyValue $sourceCounts @("users") 0) + [int](Get-PropertyValue $sourceCounts @("api_keys") 0) + [int](Get-PropertyValue $sourceCounts @("subscriptions") 0)
  if ($identityEvidenceCount -gt 0) {
    $bridgeManualReview.Add([ordered]@{
        type = "sub2api_identity_billing_not_auto_applied"
        severity = "warning"
        key = "sub2api-identity-billing"
        summary = "Sub2API users, user keys, subscriptions, and balances are evidence-only in this apply chain."
        details = [ordered]@{
          source_users = Get-PropertyValue $sourceCounts @("users") 0
          source_api_keys = Get-PropertyValue $sourceCounts @("api_keys") 0
          source_subscriptions = Get-PropertyValue $sourceCounts @("subscriptions") 0
        }
        recommended_action = "Build a reviewed identity/billing migration plan before writing users, wallets, user keys, subscriptions, or balances."
      }) | Out-Null
  }

  if ($AccountGroupBindings.Count -gt 0) {
    $bridgeManualReview.Add([ordered]@{
        type = "sub2api_group_access_policy_handoff"
        severity = "info"
        key = "sub2api-groups"
        summary = "Sub2API account/group bindings are carried as channel tags and source context only."
        details = [ordered]@{
          account_group_bindings = Convert-ToObjectArray $AccountGroupBindings
          imported_as_identity_or_access_policy = $false
        }
        recommended_action = "Review group-to-profile or access-policy semantics before applying identity, billing, or route visibility rules."
      }) | Out-Null
  }

  $channelMappingEntryCount = 0
  foreach ($mapping in $channelMappings) {
    $channelMappingEntryCount += @(Convert-ToArray $mapping.mapping_entries).Count
  }

  $sourceReportKey = "$(Split-Path -Leaf $InputFile):sub2api-source-dryrun"
  return [ordered]@{
    importer = "internal-mapping-report-dryrun"
    dry_run = $true
    generated_at = (Get-Date).ToUniversalTime().ToString("o")
    input_files = @($InputFile)
    source_reports = @(
      [ordered]@{
        input_file = $InputFile
        importer = "sub2api-source-dryrun"
        dry_run = $true
        counts = Convert-ToSafeObject $sourceCounts
      }
    )
    bridge = [ordered]@{
      schema_version = "sub2api.generic-apply-plan-bridge.v1"
      source_importer = "sub2api-source-dryrun"
      tenant_id = Redact-SecretLikeString $TenantIdValue
      account_proxy_group_scope = $true
      generic_apply_plan_input = $true
      identity_billing_subscription_apply_supported = $false
      provider_key_material_imported = $false
      provider_key_handoff_only = $true
    }
    counts = [ordered]@{
      input_reports = 1
      source_providers = $ProviderPlans.Count
      source_channels = $ChannelPlans.Count
      source_provider_keys = $ProviderKeyHandoffs.Count
      source_models = 0
      source_associations = 0
      canonical_models = 0
      model_associations = 0
      channel_mappings = $channelMappings.Count
      channel_mapping_entries = $channelMappingEntryCount
      provider_key_handoffs = $ProviderKeyHandoffs.Count
      conflicts = 0
      manual_review_items = $bridgeManualReview.Count
    }
    mapping_quality_readback = $mappingQualityReadback
    canonical_models = @()
    model_associations = @()
    channel_mappings = Convert-ToObjectArray $channelMappings
    provider_key_handoffs = Convert-ToObjectArray $ProviderKeyHandoffs
    provider_key_handoff_contract = [ordered]@{
      schema_version = "importer.provider-key-handoff-contract.v1"
      raw_material_allowed = $false
      apply_directly_supported = $false
      required_operator_path = "POST /admin/provider-keys"
      target_table = "provider_keys"
      target_secret_columns = @("encrypted_secret", "secret_fingerprint")
      handoff_count = $ProviderKeyHandoffs.Count
    }
    conflicts = @()
    manual_review_items = Convert-ToObjectArray $bridgeManualReview
    next_steps = @(
      "Use this report directly with scripts/importers/import-apply-plan.ps1 to preview provider/channel writes.",
      "Review channel source_context for Sub2API proxy and group evidence before applying production routing.",
      "Enter provider keys through POST /admin/provider-keys; raw credential material is intentionally omitted.",
      "Keep Sub2API users, user keys, balances, and subscriptions on the identity/billing handoff path."
    )
  }
}

$plan = [ordered]@{
  importer = "sub2api-operator-handoff-plan-dryrun"
  schema_version = "sub2api.operator-handoff-plan.v1"
  dry_run = $true
  generated_at = (Get-Date).ToUniversalTime().ToString("o")
  input_files = @($inputFull)
  tenant_id = Redact-SecretLikeString $TenantId
  apply_supported = $false
  database_writes = $false
  live_database_connection = $false
  preflight = [ordered]@{
    schema_version = "sub2api.operator-handoff-preflight.v1"
    status = "blocked"
    checks = @($preflightChecks)
  }
  provider_key_handoff_contract = [ordered]@{
    schema_version = "importer.provider-key-handoff-contract.v1"
    mode = "sidecar_only"
    raw_material_allowed = $false
    apply_directly_supported = $false
    required_operator_path = "POST /admin/provider-keys"
    target_table = "provider_keys"
    target_secret_columns = @("encrypted_secret", "secret_fingerprint")
    handoff_count = $providerKeyHandoffs.Count
  }
  counts = $counts
  summary = $counts
  mapping_quality_readback = $mappingQualityReadback
  provider_plans = @($providerPlans.ToArray())
  channel_plans = @($channelPlans.ToArray())
  account_group_bindings = @($accountGroupBindings.ToArray())
  provider_key_handoffs = @($providerKeyHandoffs.ToArray())
  apply_plan_artifacts = $applyPlanArtifacts
  manual_review_items = @($manualReview.ToArray())
  operator_steps = @($operatorSteps.ToArray())
  next_steps = @(
    "Review provider_plans and channel_plans before creating Control Plane resources.",
    "Enter upstream credentials through POST /admin/provider-keys; importer artifacts must remain secret-free.",
    "Build a separate reviewed mapping for Sub2API groups, users, user keys, and subscriptions before any apply path."
  )
}

if ($OutputFormat -eq "GenericApplyPlanInput") {
  $genericReport = New-GenericApplyPlanInputReport `
    -ProviderPlans @($providerPlans.ToArray()) `
    -ChannelPlans @($channelPlans.ToArray()) `
    -ProviderKeyHandoffs @($providerKeyHandoffs.ToArray()) `
    -ManualReviewItems @($manualReview.ToArray()) `
    -AccountGroupBindings @($accountGroupBindings.ToArray()) `
    -SourceReport $report `
    -InputFile $inputFull `
    -TenantIdValue $TenantId

  $json = $genericReport | ConvertTo-Json -Depth 96
  $safeJson = Redact-SecretLikeString $json
  if ($safeJson -match "sk-[A-Za-z0-9_-]+" -or $safeJson -match "(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}" -or $safeJson -match "(?i)(api[_-]?key|authorization|token|password)=([^<][^&\s`"]+)") {
    throw "Refusing to emit Sub2API generic apply-plan bridge because output still contains secret-like material."
  }

  Write-Output $safeJson
  return
}

$json = $plan | ConvertTo-Json -Depth 64
$safeJson = Redact-SecretLikeString $json
if ($safeJson -match "sk-[A-Za-z0-9_-]+" -or $safeJson -match "(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}" -or $safeJson -match "(?i)(api[_-]?key|authorization|token|password)=([^<][^&\s`"]+)") {
  throw "Refusing to emit Sub2API operator handoff plan because output still contains secret-like material."
}

Write-Output $safeJson
