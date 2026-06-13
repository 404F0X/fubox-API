[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$InputPath,

  [switch]$DryRun = $true
)

$ErrorActionPreference = "Stop"

if (-not [bool]$DryRun) {
  throw "Only dry-run parsing is implemented. Re-run with -DryRun or omit the flag."
}

function Get-PropertyValue {
  param(
    [object]$Object,
    [string[]]$Names,
    [object]$Default = $null
  )

  if ($null -eq $Object) { return $Default }

  foreach ($name in $Names) {
    $property = $Object.PSObject.Properties | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if ($null -ne $property -and $null -ne $property.Value) {
      return $property.Value
    }
  }

  return $Default
}

function Convert-ToImportArray {
  param([object]$Value)

  if ($null -eq $Value) { return @() }
  if ($Value -is [System.Array]) { return @($Value) }
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

function Convert-ToSlug {
  param([object]$Value)

  $text = [string]$Value
  $slug = $text.Trim().ToLowerInvariant() -replace "[^a-z0-9]+", "-"
  $slug = $slug.Trim("-")
  if ([string]::IsNullOrWhiteSpace($slug)) { return "unknown" }
  return $slug
}

function Normalize-Status {
  param([object]$Value)

  if ($null -eq $Value) { return "enabled" }
  if ($Value -is [bool]) {
    if ($Value) { return "enabled" }
    return "disabled"
  }

  $text = ([string]$Value).Trim().ToLowerInvariant()
  switch ($text) {
    { $_ -in @("1", "true", "enabled", "enable", "active", "ok", "normal") } { return "enabled" }
    { $_ -in @("0", "false", "disabled", "disable", "deleted", "expired", "paused") } { return "disabled" }
    default { return (Redact-SecretLikeString $text) }
  }
}

function Convert-ToStringList {
  param([object]$Value)

  $items = New-Object System.Collections.Generic.List[string]
  foreach ($item in (Convert-ToImportArray $Value)) {
    if ($null -eq $item) { continue }
    if ($item -is [string]) {
      foreach ($part in ($item -split "[,\r\n]+")) {
        $text = (Redact-SecretLikeString $part).Trim()
        if (-not [string]::IsNullOrWhiteSpace($text)) { $items.Add($text) | Out-Null }
      }
      continue
    }

    $name = Get-PropertyValue $item @("name", "key", "id", "group_id", "group") $null
    if ($null -ne $name) {
      $text = (Redact-SecretLikeString $name).Trim()
      if (-not [string]::IsNullOrWhiteSpace($text)) { $items.Add($text) | Out-Null }
    }
  }

  return @($items | Select-Object -Unique)
}

function Convert-ToSafeObject {
  param([AllowNull()][object]$Value)

  if ($null -eq $Value) { return $null }
  $json = $Value | ConvertTo-Json -Depth 32 -Compress
  return (Redact-SecretLikeString $json) | ConvertFrom-Json
}

function Add-UnsupportedFields {
  param(
    [System.Collections.Generic.List[object]]$UnsupportedFields,
    [object]$Object,
    [string[]]$SupportedNames,
    [string]$Path,
    [string]$InputFile
  )

  if ($null -eq $Object -or $Object -is [string] -or $Object.GetType().IsPrimitive) { return }
  $supported = @{}
  foreach ($name in $SupportedNames) { $supported[$name] = $true }
  foreach ($property in $Object.PSObject.Properties) {
    if (-not $supported.ContainsKey($property.Name)) {
      $UnsupportedFields.Add([ordered]@{
          input_file = $InputFile
          path = $Path
          field = $property.Name
        }) | Out-Null
    }
  }
}

function New-NonMigratableItem {
  param(
    [string]$Type,
    [string]$SourceId,
    [string]$Reason,
    [object]$Preview,
    [string]$InputFile,
    [string]$Severity = "warning"
  )

  return [ordered]@{
    type = $Type
    severity = $Severity
    source_id = Redact-SecretLikeString $SourceId
    reason = $Reason
    preview = $Preview
    recommended_action = "Review this Sub2API artifact before building an apply plan."
    input_file = $InputFile
  }
}

function Get-CredentialKeys {
  param([AllowNull()][object]$Credentials)

  if ($null -eq $Credentials -or $Credentials -is [string]) { return @() }
  return @($Credentials.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
}

function Get-EmailHash {
  param([AllowNull()][object]$Value)

  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
  return Get-StableHash ([string]$Value) 16
}

$resolved = Resolve-Path $InputPath
$inputFiles = @()
$item = Get-Item -LiteralPath $resolved
if ($item.PSIsContainer) {
  $inputFiles = @(Get-ChildItem -LiteralPath $item.FullName -Filter *.json -File | Sort-Object FullName)
} else {
  $inputFiles = @($item)
}

if ($inputFiles.Count -eq 0) {
  throw "No JSON input files found at $InputPath."
}

$accounts = New-Object System.Collections.Generic.List[object]
$proxies = New-Object System.Collections.Generic.List[object]
$groups = New-Object System.Collections.Generic.List[object]
$bindings = New-Object System.Collections.Generic.List[object]
$users = New-Object System.Collections.Generic.List[object]
$apiKeys = New-Object System.Collections.Generic.List[object]
$subscriptions = New-Object System.Collections.Generic.List[object]
$warnings = New-Object System.Collections.Generic.List[object]
$unsupportedFields = New-Object System.Collections.Generic.List[object]
$nonMigratableItems = New-Object System.Collections.Generic.List[object]

foreach ($file in $inputFiles) {
  $document = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
  $sourceType = Get-PropertyValue $document @("type", "source") "sub2api-data"
  $version = Get-PropertyValue $document @("version") 1
  if ([string]$sourceType -notin @("sub2api-data", "sub2api-bundle", "sub2api")) {
    $warnings.Add([ordered]@{
        input_file = $file.Name
        warning = "Unexpected Sub2API source type."
        observed_type = Redact-SecretLikeString $sourceType
      }) | Out-Null
  }
  if ([int]$version -ne 1) {
    $warnings.Add([ordered]@{
        input_file = $file.Name
        warning = "Unexpected Sub2API export version."
        observed_version = Redact-SecretLikeString $version
      }) | Out-Null
  }

  Add-UnsupportedFields $unsupportedFields $document @("type", "source", "version", "exported_at", "proxies", "accounts", "groups", "account_groups", "users", "api_keys", "subscriptions", "settings") "$" $file.Name

  foreach ($proxy in (Convert-ToImportArray (Get-PropertyValue $document @("proxies") $null))) {
    $proxyKey = Get-PropertyValue $proxy @("proxy_key", "key", "id", "name") "proxy"
    $password = Get-PropertyValue $proxy @("password", "pass", "secret") $null
    $preview = [ordered]@{
      proxy_key = Redact-SecretLikeString $proxyKey
      name = Redact-SecretLikeString (Get-PropertyValue $proxy @("name") $proxyKey)
      protocol = Redact-SecretLikeString (Get-PropertyValue $proxy @("protocol", "scheme", "type") $null)
      host_redacted = Redact-SecretLikeString (Get-PropertyValue $proxy @("host", "hostname", "url") $null)
      port = Redact-SecretLikeString (Get-PropertyValue $proxy @("port") $null)
      status = Normalize-Status (Get-PropertyValue $proxy @("status", "enabled") $null)
      expires_at = Redact-SecretLikeString (Get-PropertyValue $proxy @("expires_at", "expired_at") $null)
      password_present = $null -ne $password
      password_hash = if ($null -ne $password) { Get-StableHash $password } else { $null }
      input_file = $file.Name
    }
    $proxies.Add($preview) | Out-Null
  }

  foreach ($account in (Convert-ToImportArray (Get-PropertyValue $document @("accounts") $null))) {
    $sourceId = Get-PropertyValue $account @("id", "uuid", "name") (Get-StableHash $account)
    $name = Get-PropertyValue $account @("name") $sourceId
    $credentials = Get-PropertyValue $account @("credentials", "credential", "auth") $null
    $groupsForAccount = Convert-ToStringList (Get-PropertyValue $account @("groups", "group_names", "group_ids") $null)
    $accountPreview = [ordered]@{
      source_id = Redact-SecretLikeString $sourceId
      name = Redact-SecretLikeString $name
      platform = Redact-SecretLikeString (Get-PropertyValue $account @("platform", "provider") $null)
      type = Redact-SecretLikeString (Get-PropertyValue $account @("type", "account_type") $null)
      status = Normalize-Status (Get-PropertyValue $account @("status", "enabled") $null)
      concurrency = Redact-SecretLikeString (Get-PropertyValue $account @("concurrency", "concurrency_limit") $null)
      priority = Redact-SecretLikeString (Get-PropertyValue $account @("priority") $null)
      rate_multiplier = Redact-SecretLikeString (Get-PropertyValue $account @("rate_multiplier", "ratio") $null)
      expires_at = Redact-SecretLikeString (Get-PropertyValue $account @("expires_at", "expired_at") $null)
      auto_pause_on_expired = Get-PropertyValue $account @("auto_pause_on_expired") $null
      proxy_key = Redact-SecretLikeString (Get-PropertyValue $account @("proxy_key") $null)
      groups = @($groupsForAccount)
      credential_material_present = $null -ne $credentials
      credential_locator_hash = if ($null -ne $credentials) { Get-StableHash $credentials } else { $null }
      credential_locator_redacted = if ($null -ne $credentials) { "<redacted>" } else { $null }
      credential_keys = @(Get-CredentialKeys $credentials)
      extra_preview = Convert-ToSafeObject (Get-PropertyValue $account @("extra", "metadata") $null)
      input_file = $file.Name
    }
    $accounts.Add($accountPreview) | Out-Null

    foreach ($groupName in $groupsForAccount) {
      $bindings.Add([ordered]@{
          account_source_id = Redact-SecretLikeString $sourceId
          group_source_id = Redact-SecretLikeString $groupName
          priority = Redact-SecretLikeString (Get-PropertyValue $account @("priority") $null)
          input_file = $file.Name
        }) | Out-Null
    }
  }

  foreach ($group in (Convert-ToImportArray (Get-PropertyValue $document @("groups") $null))) {
    $sourceId = Get-PropertyValue $group @("id", "name", "key") (Get-StableHash $group)
    $preview = [ordered]@{
      source_id = Redact-SecretLikeString $sourceId
      name = Redact-SecretLikeString (Get-PropertyValue $group @("name") $sourceId)
      platform = Redact-SecretLikeString (Get-PropertyValue $group @("platform") $null)
      subscription_type = Redact-SecretLikeString (Get-PropertyValue $group @("subscription_type", "plan_type") $null)
      rate_multiplier = Redact-SecretLikeString (Get-PropertyValue $group @("rate_multiplier", "ratio") $null)
      daily_limit_usd = Redact-SecretLikeString (Get-PropertyValue $group @("daily_limit_usd", "daily_limit") $null)
      weekly_limit_usd = Redact-SecretLikeString (Get-PropertyValue $group @("weekly_limit_usd", "weekly_limit") $null)
      monthly_limit_usd = Redact-SecretLikeString (Get-PropertyValue $group @("monthly_limit_usd", "monthly_limit") $null)
      supported_model_scopes = @(Convert-ToStringList (Get-PropertyValue $group @("supported_model_scopes", "models") $null))
      rpm_limit = Redact-SecretLikeString (Get-PropertyValue $group @("rpm_limit", "rpm") $null)
      status = Normalize-Status (Get-PropertyValue $group @("status", "enabled") $null)
      input_file = $file.Name
    }
    $groups.Add($preview) | Out-Null
    $nonMigratableItems.Add((New-NonMigratableItem "access_group" ([string]$sourceId) "Sub2API groups are evidence-only until profile/apply mapping is reviewed." $preview $file.Name)) | Out-Null
  }

  foreach ($binding in (Convert-ToImportArray (Get-PropertyValue $document @("account_groups") $null))) {
    $bindings.Add([ordered]@{
        account_source_id = Redact-SecretLikeString (Get-PropertyValue $binding @("account_id", "account_source_id", "account") $null)
        group_source_id = Redact-SecretLikeString (Get-PropertyValue $binding @("group_id", "group_source_id", "group") $null)
        priority = Redact-SecretLikeString (Get-PropertyValue $binding @("priority") $null)
        input_file = $file.Name
      }) | Out-Null
  }

  foreach ($user in (Convert-ToImportArray (Get-PropertyValue $document @("users") $null))) {
    $sourceId = Get-PropertyValue $user @("id", "uuid", "email", "username") (Get-StableHash $user)
    $preview = [ordered]@{
      source_id = Redact-SecretLikeString $sourceId
      email_hash = Get-EmailHash (Get-PropertyValue $user @("email") $null)
      username = Redact-SecretLikeString (Get-PropertyValue $user @("username", "name") $null)
      role = Redact-SecretLikeString (Get-PropertyValue $user @("role") $null)
      status = Normalize-Status (Get-PropertyValue $user @("status", "enabled") $null)
      balance = Redact-SecretLikeString (Get-PropertyValue $user @("balance", "quota") $null)
      concurrency = Redact-SecretLikeString (Get-PropertyValue $user @("concurrency", "concurrency_limit") $null)
      rpm_limit = Redact-SecretLikeString (Get-PropertyValue $user @("rpm_limit", "rpm") $null)
      input_file = $file.Name
    }
    $users.Add($preview) | Out-Null
    $nonMigratableItems.Add((New-NonMigratableItem "user_profile" ([string]$sourceId) "Sub2API users are not applied by source dry-run." $preview $file.Name)) | Out-Null
  }

  foreach ($apiKey in (Convert-ToImportArray (Get-PropertyValue $document @("api_keys", "keys", "tokens") $null))) {
    $sourceId = Get-PropertyValue $apiKey @("id", "name", "key") (Get-StableHash $apiKey)
    $rawKey = Get-PropertyValue $apiKey @("key", "token", "secret") $null
    $preview = [ordered]@{
      source_id = Redact-SecretLikeString $sourceId
      name = Redact-SecretLikeString (Get-PropertyValue $apiKey @("name") $sourceId)
      user_source_id = Redact-SecretLikeString (Get-PropertyValue $apiKey @("user_id", "user") $null)
      user_email_hash = Get-EmailHash (Get-PropertyValue $apiKey @("email", "user_email") $null)
      group_source_id = Redact-SecretLikeString (Get-PropertyValue $apiKey @("group_id", "group") $null)
      status = Normalize-Status (Get-PropertyValue $apiKey @("status", "enabled") $null)
      quota = Redact-SecretLikeString (Get-PropertyValue $apiKey @("quota", "limit") $null)
      quota_used = Redact-SecretLikeString (Get-PropertyValue $apiKey @("quota_used", "used_quota") $null)
      expires_at = Redact-SecretLikeString (Get-PropertyValue $apiKey @("expires_at", "expired_at") $null)
      rate_limit_rpm = Redact-SecretLikeString (Get-PropertyValue $apiKey @("rpm_limit", "rpm") $null)
      key_hash = if ($null -ne $rawKey) { Get-StableHash $rawKey } else { $null }
      has_secret = $null -ne $rawKey
      secret_material = if ($null -ne $rawKey) { "<redacted>" } else { $null }
      input_file = $file.Name
    }
    $apiKeys.Add($preview) | Out-Null
    $nonMigratableItems.Add((New-NonMigratableItem "user_token" ([string]$sourceId) "Sub2API API keys require user/profile mapping before apply." $preview $file.Name)) | Out-Null
  }

  foreach ($subscription in (Convert-ToImportArray (Get-PropertyValue $document @("subscriptions") $null))) {
    $sourceId = Get-PropertyValue $subscription @("id", "name", "user_id") (Get-StableHash $subscription)
    $preview = [ordered]@{
      source_id = Redact-SecretLikeString $sourceId
      user_source_id = Redact-SecretLikeString (Get-PropertyValue $subscription @("user_id", "user") $null)
      group_source_id = Redact-SecretLikeString (Get-PropertyValue $subscription @("group_id", "group") $null)
      plan = Redact-SecretLikeString (Get-PropertyValue $subscription @("plan", "plan_name") $null)
      starts_at = Redact-SecretLikeString (Get-PropertyValue $subscription @("starts_at", "start_at") $null)
      expires_at = Redact-SecretLikeString (Get-PropertyValue $subscription @("expires_at", "end_at") $null)
      quota = Redact-SecretLikeString (Get-PropertyValue $subscription @("quota", "limit") $null)
      input_file = $file.Name
    }
    $subscriptions.Add($preview) | Out-Null
    $nonMigratableItems.Add((New-NonMigratableItem "subscription" ([string]$sourceId) "Sub2API subscriptions need package lifecycle mapping before apply." $preview $file.Name)) | Out-Null
  }

  $settings = Get-PropertyValue $document @("settings") $null
  if ($null -ne $settings) {
    $nonMigratableItems.Add((New-NonMigratableItem "settings" "settings" "Sub2API global settings are not imported by this source dry-run." (Convert-ToSafeObject $settings) $file.Name)) | Out-Null
  }
}

$inputFilePaths = @($inputFiles | ForEach-Object { $_.FullName })
$counts = [ordered]@{
  accounts = $accounts.Count
  proxies = $proxies.Count
  groups = $groups.Count
  account_group_bindings = $bindings.Count
  users = $users.Count
  api_keys = $apiKeys.Count
  subscriptions = $subscriptions.Count
  warnings = $warnings.Count
  unsupported_fields = $unsupportedFields.Count
  non_migratable_items = $nonMigratableItems.Count
}

function New-MappingQualityReadback {
  param(
    [object[]]$Accounts,
    [object[]]$Groups,
    [object[]]$Bindings,
    [object[]]$Users,
    [object[]]$ApiKeys,
    [object[]]$Subscriptions,
    [object[]]$NonMigratableItems
  )

  $nonMigratableReasons = @($NonMigratableItems | ForEach-Object {
      [ordered]@{
        type = $_.type
        severity = $_.severity
        reason = $_.reason
        recommended_action = $_.recommended_action
      }
    })
  $accountCredentialHandoffs = @($Accounts | Where-Object { [bool]$_.credential_material_present })
  $blockedCount = @($NonMigratableItems | Where-Object { $_.severity -eq "error" }).Count
  $manualCount = $NonMigratableItems.Count + $accountCredentialHandoffs.Count + $ApiKeys.Count + $Subscriptions.Count

  return [ordered]@{
    schema_version = "importer.mapping-quality-readback.v1"
    source_system = "sub2api"
    status = if ($manualCount -gt 0 -or $blockedCount -gt 0) { "operator-handoff-required" } else { "ready-for-apply-plan-review" }
    dry_run_only = $true
    secret_safe = $true
    mapping_counts = [ordered]@{
      provider_mappings = $Accounts.Count
      channel_mappings = $Accounts.Count
      model_mappings = 0
      canonical_model_candidates = 0
      user_mappings = $Users.Count
      key_mappings = $accountCredentialHandoffs.Count + $ApiKeys.Count
      provider_key_handoffs = $accountCredentialHandoffs.Count
      user_key_reissue_handoffs = $ApiKeys.Count
      wallet_mappings = $Users.Count
      subscription_mappings = $Subscriptions.Count
      group_mappings = $Groups.Count + $Bindings.Count
      non_migratable_items = $NonMigratableItems.Count
      conflicts = 0
    }
    conflicts = [ordered]@{
      count = 0
      blocking_count = 0
      refs = @()
    }
    non_migratable_reasons = $nonMigratableReasons
    operator_handoff_refs_presence = [ordered]@{
      provider_key_handoffs_present = $accountCredentialHandoffs.Count -gt 0
      provider_key_handoff_refs_present = $accountCredentialHandoffs.Count -gt 0
      user_key_reissue_refs_present = $ApiKeys.Count -gt 0
      wallet_opening_balance_refs_present = $Users.Count -gt 0
      subscription_mapping_refs_present = $Subscriptions.Count -gt 0
      required_operator_path_present = $accountCredentialHandoffs.Count -gt 0 -or $ApiKeys.Count -gt 0
    }
    safe_next_action = if ($manualCount -gt 0) {
      "Generate the Sub2API operator handoff/apply-plan bridge, then review user, wallet, key reissue, and subscription mappings before any apply path."
    } else {
      "Generate the reviewed provider/channel apply-plan bridge; keep keys and subscriptions on operator handoff paths."
    }
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
  -Accounts @($accounts.ToArray()) `
  -Groups @($groups.ToArray()) `
  -Bindings @($bindings.ToArray()) `
  -Users @($users.ToArray()) `
  -ApiKeys @($apiKeys.ToArray()) `
  -Subscriptions @($subscriptions.ToArray()) `
  -NonMigratableItems @($nonMigratableItems.ToArray())

$report = [ordered]@{
  importer = "sub2api-source-dryrun"
  dry_run = $true
  generated_at = (Get-Date).ToUniversalTime().ToString("o")
  input_files = $inputFilePaths
  counts = $counts
  summary = $counts
  mapping_quality_readback = $mappingQualityReadback
  accounts = @($accounts.ToArray())
  proxies = @($proxies.ToArray())
  groups = @($groups.ToArray())
  account_group_bindings = @($bindings.ToArray())
  users = @($users.ToArray())
  api_keys = @($apiKeys.ToArray())
  subscriptions = @($subscriptions.ToArray())
  non_migratable_items = @($nonMigratableItems.ToArray())
  warnings = @($warnings.ToArray())
  unsupported_fields = @($unsupportedFields.ToArray())
  next_steps = @(
    "Review Sub2API account/group/API key evidence before building an apply plan.",
    "Map accounts into provider/channel/provider-key handoff in a separate reviewed step.",
    "Do not import raw credential material; operators must re-enter provider and user key secrets through approved secret paths."
  )
}

$json = $report | ConvertTo-Json -Depth 32
Write-Output (Redact-SecretLikeString $json)
