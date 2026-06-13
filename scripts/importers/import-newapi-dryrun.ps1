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

  if ($null -eq $Object) {
    return $Default
  }

  foreach ($name in $Names) {
    $property = $Object.PSObject.Properties | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if ($null -ne $property -and $null -ne $property.Value) {
      return $property.Value
    }
  }

  return $Default
}

function Add-UnsupportedFields {
  param(
    [System.Collections.Generic.List[object]]$UnsupportedFields,
    [object]$Object,
    [string[]]$SupportedNames,
    [string]$Path,
    [string]$InputFile
  )

  if ($null -eq $Object -or $Object -is [string]) {
    return
  }

  $supported = @{}
  foreach ($name in $SupportedNames) {
    $supported[$name] = $true
  }

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

function Convert-ToImportArray {
  param([object]$Value)

  if ($null -eq $Value) {
    return @()
  }

  if ($Value -is [System.Array]) {
    return @($Value)
  }

  return @($Value)
}

function Convert-ToSlug {
  param([object]$Value)

  $text = [string]$Value
  $slug = $text.Trim().ToLowerInvariant() -replace "[^a-z0-9]+", "-"
  $slug = $slug.Trim("-")
  if ([string]::IsNullOrWhiteSpace($slug)) {
    return "unknown"
  }

  return $slug
}

function Redact-SecretLikeString {
  param([AllowNull()][object]$Value)

  if ($null -eq $Value) {
    return $null
  }

  $text = [string]$Value
  $text = $text -replace "\$\{[A-Za-z_][A-Za-z0-9_]*(KEY|TOKEN|SECRET|PASSWORD)[A-Za-z0-9_]*\}", "<redacted-env>"
  $text = $text -replace "(?i)\benv:[A-Z0-9_]*(KEY|TOKEN|SECRET|PASSWORD)[A-Z0-9_]*\b", "env:<redacted>"
  $text = $text -replace "sk-[A-Za-z0-9_-]+", "<redacted>"
  $text = $text -replace "(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+", '$1<redacted>'
  $text = $text -replace "(?i)(api[_-]?key|authorization|bearer|token|secret)=([^&\s""]+)", '$1=<redacted>'
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
  if ($Length -gt 0 -and $Length -lt $hash.Length) {
    return $hash.Substring(0, $Length)
  }

  return $hash
}

function Normalize-Status {
  param([object]$Value)

  if ($null -eq $Value) {
    return "enabled"
  }

  if ($Value -is [bool]) {
    if ($Value) {
      return "enabled"
    }
    return "disabled"
  }

  $text = ([string]$Value).Trim().ToLowerInvariant()
  switch ($text) {
    { $_ -in @("1", "true", "enabled", "enable", "active", "ok") } { return "enabled" }
    { $_ -in @("0", "false", "disabled", "disable", "manual_disabled", "deleted") } { return "disabled" }
    default { return (Redact-SecretLikeString $text) }
  }
}

function Normalize-ModelStatus {
  param([object]$Value)

  if ($null -eq $Value) {
    return "active"
  }

  $text = ([string]$Value).Trim().ToLowerInvariant()
  switch ($text) {
    { $_ -in @("active", "enabled", "enable", "1", "true", "ok") } { return "active" }
    { $_ -in @("deprecated", "disabled", "disable", "0", "false", "deleted") } { return "deprecated" }
    default { return (Redact-SecretLikeString $text) }
  }
}

function Convert-ToStringList {
  param([object]$Value)

  $items = New-Object System.Collections.Generic.List[string]

  foreach ($item in (Convert-ToImportArray $Value)) {
    if ($null -eq $item) {
      continue
    }

    if ($item -is [string]) {
      foreach ($part in ($item -split "[,\r\n]+")) {
        $text = (Redact-SecretLikeString $part).Trim()
        if (-not [string]::IsNullOrWhiteSpace($text)) {
          $items.Add($text)
        }
      }
      continue
    }

    $name = Get-PropertyValue $item @("model_key", "model", "client_model", "name", "key", "id")
    if ($null -ne $name) {
      $text = (Redact-SecretLikeString $name).Trim()
      if (-not [string]::IsNullOrWhiteSpace($text)) {
        $items.Add($text)
      }
    }
  }

  return @($items | Select-Object -Unique)
}

function Convert-ToMappingTable {
  param([object]$Value)

  $table = [ordered]@{}

  if ($null -eq $Value) {
    return $table
  }

  if ($Value -is [string]) {
    $trimmed = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
      return $table
    }

    if ($trimmed.StartsWith("{") -or $trimmed.StartsWith("[")) {
      try {
        return Convert-ToMappingTable (ConvertFrom-Json -InputObject $trimmed)
      } catch {
        throw "Invalid JSON model_mapping string: $($_.Exception.Message)"
      }
    }

    foreach ($pair in ($trimmed -split "[,\r\n]+")) {
      $parts = $pair -split "[:=]", 2
      if ($parts.Count -eq 2) {
        $from = (Redact-SecretLikeString $parts[0]).Trim()
        $to = (Redact-SecretLikeString $parts[1]).Trim()
        if ($from -and $to) {
          $table[$from] = $to
        }
      }
    }

    return $table
  }

  if ($Value -is [System.Array]) {
    foreach ($entry in $Value) {
      $from = Get-PropertyValue $entry @("client_model", "canonical_model", "source_model", "from", "model", "name")
      $to = Get-PropertyValue $entry @("upstream_model", "provider_model", "target_model", "to", "mapped_model", "value")
      if ($null -ne $from -and $null -ne $to) {
        $table[(Redact-SecretLikeString $from).Trim()] = (Redact-SecretLikeString $to).Trim()
      }
    }

    return $table
  }

  foreach ($property in $Value.PSObject.Properties) {
    if ($null -ne $property.Value) {
      $from = (Redact-SecretLikeString $property.Name).Trim()
      $to = (Redact-SecretLikeString $property.Value).Trim()
      if ($from -and $to) {
        $table[$from] = $to
      }
    }
  }

  return $table
}

function Test-HasSecret {
  param([object]$Value)

  if ($null -eq $Value) {
    return $false
  }

  if ($Value -is [string]) {
    return -not [string]::IsNullOrWhiteSpace($Value)
  }

  foreach ($name in @("secret", "secret_ref", "api_key", "apiKey", "key", "token", "value")) {
    $candidate = Get-PropertyValue $Value @($name)
    if ($candidate -is [string] -and -not [string]::IsNullOrWhiteSpace($candidate)) {
      return $true
    }
  }

  return $false
}

function Get-CredentialMaterialCandidate {
  param([object]$Value)

  if ($null -eq $Value) {
    return $null
  }

  if ($Value -is [string]) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
      return $null
    }
    return [string]$Value
  }

  foreach ($name in @("secret_ref", "secret", "api_key", "apiKey", "key", "token", "value")) {
    $candidate = Get-PropertyValue $Value @($name)
    if ($candidate -is [string] -and -not [string]::IsNullOrWhiteSpace($candidate)) {
      return [string]$candidate
    }
  }

  return $null
}

function Get-CredentialHandoffPreview {
  param([object]$Value)

  $candidate = Get-CredentialMaterialCandidate $Value
  $present = -not [string]::IsNullOrWhiteSpace($candidate)
  $origin = "missing"
  if ($present) {
    if ($candidate -match "^\$\{[A-Za-z_][A-Za-z0-9_]*\}$" -or $candidate -match "(?i)^env:") {
      $origin = "environment_reference"
    } elseif ($null -ne $Value -and -not ($Value -is [string]) -and $null -ne (Get-PropertyValue $Value @("secret_ref") $null)) {
      $origin = "external_secret_reference"
    } else {
      $origin = "inline_redacted"
    }
  }

  return [ordered]@{
    credential_material_present = $present
    credential_origin = $origin
    credential_locator_redacted = if ($present) { Redact-SecretLikeString $candidate } else { $null }
    credential_locator_hash = if ($present) { Get-StableHash $candidate 24 } else { $null }
    raw_material_exported = $false
    requires_operator_entry = $present
    recommended_path = "control_plane_provider_key_create"
  }
}

function Get-KeyAlias {
  param(
    [object]$Value,
    [string]$DefaultAlias
  )

  if ($null -eq $Value -or $Value -is [string]) {
    return $DefaultAlias
  }

  $alias = Get-PropertyValue $Value @("alias", "key_alias", "name", "label") $DefaultAlias
  $aliasText = (Redact-SecretLikeString $alias).Trim()
  if ([string]::IsNullOrWhiteSpace($aliasText)) {
    return $DefaultAlias
  }

  return $aliasText
}

function Resolve-ProtocolMode {
  param([object]$Channel)

  $raw = Get-PropertyValue $Channel @("protocol_mode", "protocol", "adapter", "type", "kind") "openai-compatible"
  $text = ([string]$raw).Trim().ToLowerInvariant()
  switch -Regex ($text) {
    "native" { return "native_proxy" }
    "adapter|transform" { return "adapter_transform" }
    default { return "openai_compatible" }
  }
}

function Add-ProviderPreview {
  param(
    [System.Collections.Specialized.OrderedDictionary]$Providers,
    [string]$Code,
    [object]$Name,
    [object]$Kind,
    [object]$BaseUrl,
    [string]$SourceId,
    [string]$InputFile
  )

  $providerCode = Convert-ToSlug $Code
  if ($Providers.Contains($providerCode)) {
    return $providerCode
  }

  $displayName = (Redact-SecretLikeString $(if ($null -ne $Name) { $Name } else { $providerCode })).Trim()
  $kindText = (Redact-SecretLikeString $(if ($null -ne $Kind) { $Kind } else { "openai-compatible" })).Trim()

  $Providers[$providerCode] = [ordered]@{
    source_id = $SourceId
    code = $providerCode
    display_name = $displayName
    kind = $kindText
    base_url = Redact-SecretLikeString $BaseUrl
    default_protocol = "openai_compatible"
    input_file = $InputFile
  }

  return $providerCode
}

function Add-ModelPreview {
  param(
    [System.Collections.Specialized.OrderedDictionary]$Models,
    [object]$ModelKey,
    [object]$DisplayName = $null,
    [object]$Family = $null,
    [object]$Capabilities = $null,
    [object]$Aliases = $null,
    [object]$Status = "active"
  )

  if ($null -eq $ModelKey) {
    return
  }

  $key = (Redact-SecretLikeString $ModelKey).Trim()
  if ([string]::IsNullOrWhiteSpace($key)) {
    return
  }

  if ($Models.Contains($key)) {
    return
  }

  $capabilityList = Convert-ToStringList $Capabilities
  if ($capabilityList.Count -eq 0) {
    $capabilityList = @("text")
  }

  $Models[$key] = [ordered]@{
    model_key = $key
    display_name = (Redact-SecretLikeString $(if ($null -ne $DisplayName) { $DisplayName } else { $key })).Trim()
    family = (Redact-SecretLikeString $(if ($null -ne $Family) { $Family } else { ($key -split "[-_:]", 2)[0] })).Trim()
    capabilities = @($capabilityList)
    status = Normalize-ModelStatus $Status
    source_aliases = @(Convert-ToStringList $Aliases)
  }
}

function Add-AssociationPreview {
  param(
    [System.Collections.Generic.List[object]]$Associations,
    [hashtable]$AssociationKeys,
    [object]$CanonicalModel,
    [object]$RequestedModel,
    [object]$ChannelSourceId,
    [object]$UpstreamModel,
    [object]$Priority,
    [object]$Weight,
    [object]$Enabled,
    [object]$Conditions
  )

  $canonical = (Redact-SecretLikeString $CanonicalModel).Trim()
  if ([string]::IsNullOrWhiteSpace($canonical)) {
    return
  }

  $requested = (Redact-SecretLikeString $(if ($null -ne $RequestedModel) { $RequestedModel } else { $canonical })).Trim()
  $channel = (Redact-SecretLikeString $ChannelSourceId).Trim()
  $upstream = (Redact-SecretLikeString $(if ($null -ne $UpstreamModel) { $UpstreamModel } else { $canonical })).Trim()
  $dedupeKey = "$canonical|$requested|$channel|$upstream"
  if ($AssociationKeys.ContainsKey($dedupeKey)) {
    return
  }

  $AssociationKeys[$dedupeKey] = $true
  $Associations.Add([ordered]@{
      canonical_model_key = $canonical
      requested_model = $requested
      channel_source_id = $channel
      upstream_model_name = $upstream
      priority = if ($null -ne $Priority) { [int]$Priority } else { 0 }
      weight = if ($null -ne $Weight) { [int]$Weight } else { 100 }
      enabled = if ($null -ne $Enabled) { (Normalize-Status $Enabled) -eq "enabled" } else { $true }
      conditions = if ($null -ne $Conditions) { $Conditions } else { [ordered]@{} }
    }) | Out-Null
}

function Add-NonMigratableItem {
  param(
    [System.Collections.Generic.List[object]]$Items,
    [string]$Type,
    [string]$Severity,
    [string]$SourceKey,
    [string]$Summary,
    [object]$Details,
    [string]$RecommendedAction,
    [string]$InputFile
  )

  $Items.Add([ordered]@{
      type = $Type
      severity = $Severity
      source_key = Redact-SecretLikeString $SourceKey
      summary = Redact-SecretLikeString $Summary
      details = $Details
      recommended_action = Redact-SecretLikeString $RecommendedAction
      input_file = $InputFile
    }) | Out-Null
}

function Add-AccountEvidence {
  param(
    [System.Collections.Generic.List[object]]$Profiles,
    [System.Collections.Generic.List[object]]$Balances,
    [System.Collections.Generic.List[object]]$NonMigratableItems,
    [object]$Account,
    [string]$InputFile
  )

  $userId = Get-PropertyValue $Account @("id", "user_id", "account_id", "username", "email") "unknown-user"
  $group = Get-PropertyValue $Account @("group", "group_name", "role", "tier") $null
  $profile = [ordered]@{
    source_user_id = Redact-SecretLikeString $userId
    username = Redact-SecretLikeString (Get-PropertyValue $Account @("username", "name") $null)
    email_present = -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $Account @("email", "mail") $null))
    group = Redact-SecretLikeString $group
    status = Normalize-Status (Get-PropertyValue $Account @("status", "enabled") $null)
    input_file = $InputFile
  }
  $Profiles.Add($profile) | Out-Null
  Add-NonMigratableItem $NonMigratableItems "user_profile" "warning" ([string]$userId) "User/profile rows are not imported by the API routing importer." $profile "Map identities and groups through the account migration path before applying routing data." $InputFile

  $balance = Get-PropertyValue $Account @("balance", "quota", "remaining_quota", "remaining", "credit") $null
  $used = Get-PropertyValue $Account @("used_quota", "used", "spent", "request_count") $null
  if ($null -ne $balance -or $null -ne $used) {
    $balanceEvidence = [ordered]@{
      source_user_id = Redact-SecretLikeString $userId
      balance = Redact-SecretLikeString $balance
      used_quota = Redact-SecretLikeString $used
      unit = Redact-SecretLikeString (Get-PropertyValue $Account @("unit", "balance_unit", "quota_unit") "source_system_units")
      input_file = $InputFile
    }
    $Balances.Add($balanceEvidence) | Out-Null
    Add-NonMigratableItem $NonMigratableItems "opening_balance" "error" ([string]$userId) "Source balance/quota is evidence only and is not imported by this dry-run." $balanceEvidence "Convert balances into an opening-balance ledger import with explicit unit and audit evidence." $InputFile
  }
}

function Add-TokenEvidence {
  param(
    [System.Collections.Generic.List[object]]$Tokens,
    [System.Collections.Generic.List[object]]$NonMigratableItems,
    [object]$Token,
    [string]$InputFile
  )

  $tokenId = Get-PropertyValue $Token @("id", "token_id", "name", "key", "token") "unknown-token"
  $secret = Get-PropertyValue $Token @("key", "token", "value", "secret", "api_key") $null
  $preview = [ordered]@{
    source_token_id = Redact-SecretLikeString $tokenId
    name = Redact-SecretLikeString (Get-PropertyValue $Token @("name", "label") $null)
    source_user_id = Redact-SecretLikeString (Get-PropertyValue $Token @("user_id", "account_id", "owner_id") $null)
    has_secret = Test-HasSecret $Token
    source_key_fingerprint = if ($null -ne $secret) { Get-StableHash $secret 24 } else { $null }
    secret_material = if ($null -ne $secret) { "<redacted>" } else { $null }
    quota = Redact-SecretLikeString (Get-PropertyValue $Token @("quota", "remain_quota", "remaining_quota") $null)
    used_quota = Redact-SecretLikeString (Get-PropertyValue $Token @("used_quota", "used") $null)
    status = Normalize-Status (Get-PropertyValue $Token @("status", "enabled") $null)
    input_file = $InputFile
  }
  $Tokens.Add($preview) | Out-Null
  Add-NonMigratableItem $NonMigratableItems "user_token" "error" ([string]$tokenId) "User token/API key material is not migrated by this importer." $preview "Reissue or import virtual keys through the secret-management path; carry quota evidence separately." $InputFile
}

function Add-GroupEvidence {
  param(
    [System.Collections.Generic.List[object]]$Groups,
    [System.Collections.Generic.List[object]]$Multipliers,
    [System.Collections.Generic.List[object]]$NonMigratableItems,
    [object]$Group,
    [string]$InputFile
  )

  $groupId = Get-PropertyValue $Group @("id", "name", "group", "key") "unknown-group"
  $preview = [ordered]@{
    source_group_id = Redact-SecretLikeString $groupId
    name = Redact-SecretLikeString (Get-PropertyValue $Group @("name", "group", "key") $groupId)
    ratio = Redact-SecretLikeString (Get-PropertyValue $Group @("ratio", "multiplier", "quota_multiplier") $null)
    model_ratio = Redact-SecretLikeString (Get-PropertyValue $Group @("model_ratio", "model_multiplier", "model_ratios") $null)
    input_file = $InputFile
  }
  $Groups.Add($preview) | Out-Null
  Add-NonMigratableItem $NonMigratableItems "access_group" "warning" ([string]$groupId) "Access groups are evidence only in the routing importer." $preview "Map source groups to internal tenants/groups and pricing profiles before apply." $InputFile

  if ($null -ne $preview.ratio -or $null -ne $preview.model_ratio) {
    $Multipliers.Add([ordered]@{
        source_key = Redact-SecretLikeString $groupId
        scope = "group"
        ratio = $preview.ratio
        model_ratio = $preview.model_ratio
        input_file = $InputFile
      }) | Out-Null
  }
}

function New-SourceSpecificApplyPlanArtifacts {
  param(
    [string]$SourceSystem,
    [object[]]$Channels,
    [object[]]$ProviderKeys,
    [object[]]$Associations,
    [object[]]$AccessGroups,
    [object[]]$UserProfiles,
    [object[]]$UserTokens,
    [object[]]$BalanceRecords,
    [object[]]$PricingMultipliers
  )

  $channelPlans = @($Channels | ForEach-Object {
      [ordered]@{
        channel_source_id = $_.source_id
        provider_code = $_.provider_code
        channel_name = $_.name
        endpoint = $_.endpoint
        protocol_mode = $_.protocol_mode
        groups = @($_.tags)
        status = $_.status
        classification = "migratable"
        target_action = "reviewed_provider_channel_upsert"
      }
    })

  $modelMappings = @($Associations | ForEach-Object {
      [ordered]@{
        requested_model = $_.requested_model
        canonical_model_key = $_.canonical_model_key
        upstream_model_name = $_.upstream_model_name
        channel_source_id = $_.channel_source_id
        classification = "migratable"
        target_action = "reviewed_model_association_upsert"
      }
    })

  $providerKeyHandoffs = @($ProviderKeys | ForEach-Object {
      [ordered]@{
        channel_source_id = $_.channel_source_id
        alias = $_.alias
        credential_fingerprint = $_.credential_locator_hash
        credential_origin = $_.credential_origin
        raw_material_exported = $false
        classification = "manual"
        target_action = "operator_handoff_provider_key_create"
        required_operator_path = $_.recommended_path
      }
    })

  $groupMappings = @($AccessGroups | ForEach-Object {
      [ordered]@{
        source_group_id = $_.source_group_id
        name = $_.name
        ratio = $_.ratio
        model_ratio = $_.model_ratio
        classification = "manual"
        target_action = "map_source_group_to_profile_or_price_book"
      }
    })

  $userLinks = @($UserProfiles | ForEach-Object {
      [ordered]@{
        source_user_id = $_.source_user_id
        username = $_.username
        email_present = $_.email_present
        group = $_.group
        status = $_.status
        classification = "manual"
        target_action = "operator_review_then_create_or_link_user"
        raw_email_exported = $false
      }
    })

  $openingBalances = @($BalanceRecords | ForEach-Object {
      [ordered]@{
        source_user_id = $_.source_user_id
        opening_balance = $_.balance
        used_quota = $_.used_quota
        unit = $_.unit
        classification = "manual"
        target_action = "opening_balance_ledger_import_after_unit_review"
        apply_supported = $false
      }
    })

  $keyReissue = @($UserTokens | ForEach-Object {
      [ordered]@{
        source_token_id = $_.source_token_id
        source_user_id = $_.source_user_id
        name = $_.name
        source_key_fingerprint = $_.source_key_fingerprint
        raw_key_exported = $false
        secret_material_included = $false
        classification = "blocked"
        target_action = "reissue_user_key"
        required_operator_path = "POST /auth/api-keys"
      }
    })

  $priceBookMappings = @($PricingMultipliers | ForEach-Object {
      [ordered]@{
        source_key = $_.source_key
        scope = $_.scope
        ratio = $_.ratio
        prompt_ratio = $_.prompt_ratio
        completion_ratio = $_.completion_ratio
        classification = "manual"
        target_action = "map_source_multiplier_to_price_book"
      }
    })

  $sourceSystemName = if ($SourceSystem -eq "one-api") { "oneapi" } else { "newapi" }
  $rateFields = if ($SourceSystem -eq "one-api") {
    @("group_mappings.ratio", "group_mappings.model_ratio", "price_book_multiplier_mappings.ratio")
  } else {
    @("group_mappings.ratio", "group_mappings.model_ratio", "price_book_multiplier_mappings.ratio", "price_book_multiplier_mappings.prompt_ratio", "price_book_multiplier_mappings.completion_ratio")
  }

  return [ordered]@{
    schema_version = "importer.source-specific-apply-plan-artifacts.v1"
    source_system = $SourceSystem
    secret_safe = $true
    raw_provider_key_material_included = $false
    raw_user_key_material_included = $false
    categories = [ordered]@{
      migratable = [ordered]@{
        channels = @($channelPlans)
        model_mappings = @($modelMappings)
      }
      manual = [ordered]@{
        provider_key_operator_handoffs = @($providerKeyHandoffs)
        group_mappings = @($groupMappings)
        user_link_candidates = @($userLinks)
        wallet_opening_balance_candidates = @($openingBalances)
        price_book_multiplier_mappings = @($priceBookMappings)
        subscription_mappings = @()
      }
      blocked = [ordered]@{
        provider_key_direct_import = @($providerKeyHandoffs)
        user_key_reissue_handoffs = @($keyReissue)
        opening_balance_direct_apply = @($openingBalances)
      }
    }
    classification_counts = [ordered]@{
      migratable = $channelPlans.Count + $modelMappings.Count
      manual = $providerKeyHandoffs.Count + $groupMappings.Count + $userLinks.Count + $openingBalances.Count + $priceBookMappings.Count
      blocked = $providerKeyHandoffs.Count + $keyReissue.Count + $openingBalances.Count
    }
    automation_matrix = [ordered]@{
      automatic_apply = @("channels", "model_mappings")
      operator_handoff = @("provider_key_operator_handoffs", "group_mappings", "price_book_multiplier_mappings", "wallet_opening_balance_candidates")
      blocked_without_operator = @("provider_key_direct_import", "user_key_reissue_handoffs", "opening_balance_direct_apply")
    }
    executable_handoff = [ordered]@{
      schema_version = "importer.source-specific-executable-handoff.v1"
      source_system = $SourceSystem
      generated_for = "reviewed_apply_plan"
      secret_safe = $true
      runner_inputs = [ordered]@{
        channels = @($channelPlans)
        model_mappings = @($modelMappings)
        group_mappings = @($groupMappings)
        rate_mappings = @($priceBookMappings)
        provider_key_reissue_handoffs = @($providerKeyHandoffs)
        user_key_reissue_handoffs = @($keyReissue)
        wallet_opening_balance_candidates = @($openingBalances)
      }
      executable_fields = [ordered]@{
        channel = @("channel_source_id", "provider_code", "channel_name", "endpoint", "protocol_mode", "groups", "status", "target_action")
        model_mapping = @("requested_model", "canonical_model_key", "upstream_model_name", "channel_source_id", "target_action")
        group = @("source_group_id", "name", "ratio", "model_ratio", "target_action")
        rate = $rateFields
        key_reissue = @("source_token_id", "source_user_id", "source_key_fingerprint", "required_operator_path", "target_action")
      }
      apply_modes = [ordered]@{
        channel = "automatic_after_review"
        model_mapping = "automatic_after_review"
        group = "operator_mapping_required"
        rate = "operator_price_book_mapping_required"
        provider_key = "operator_handoff_only"
        user_key = "operator_reissue_only"
        opening_balance = "operator_unit_review_required"
      }
      difference_explanation = [ordered]@{
        automatic = "Channel and model mapping records have enough non-secret fields for reviewed apply-plan generation."
        manual = "$sourceSystemName groups, rates, provider keys, user links, and opening balances need operator review before any live writer can run."
        blocked = "Raw provider keys and raw user tokens are never executable payload; only alias/fingerprint/operator handoff fields are emitted."
      }
      forbidden_payload_fields = @("raw_provider_key", "raw_user_key", "secret_material", "authorization", "bearer_token", "password")
    }
  }
}

if (-not (Test-Path -LiteralPath $InputPath)) {
  throw "InputPath not found: $InputPath"
}

$resolvedInput = Resolve-Path -LiteralPath $InputPath
$inputFiles = New-Object System.Collections.Generic.List[System.IO.FileInfo]
foreach ($path in $resolvedInput) {
  $item = Get-Item -LiteralPath $path.Path
  if ($item.PSIsContainer) {
    foreach ($file in (Get-ChildItem -LiteralPath $item.FullName -Filter "*.json" -File | Sort-Object FullName)) {
      $inputFiles.Add($file)
    }
  } else {
    $inputFiles.Add($item)
  }
}

if ($inputFiles.Count -eq 0) {
  throw "No JSON input files found at $InputPath."
}

$providers = [ordered]@{}
$models = [ordered]@{}
$channels = New-Object System.Collections.Generic.List[object]
$providerKeys = New-Object System.Collections.Generic.List[object]
$associations = New-Object System.Collections.Generic.List[object]
$associationKeys = @{}
$warnings = New-Object System.Collections.Generic.List[string]
$unsupportedFields = New-Object System.Collections.Generic.List[object]
$accessGroups = New-Object System.Collections.Generic.List[object]
$userProfiles = New-Object System.Collections.Generic.List[object]
$userTokens = New-Object System.Collections.Generic.List[object]
$balanceRecords = New-Object System.Collections.Generic.List[object]
$pricingMultipliers = New-Object System.Collections.Generic.List[object]
$nonMigratableItems = New-Object System.Collections.Generic.List[object]
$channelIdToSource = @{}

$documentSupportedFields = @(
  "source", "source_system", "system", "exported_at",
  "providers", "provider_configs", "provider",
  "channels", "channel_configs", "channel",
  "models", "canonical_models", "model_catalog",
  "provider_keys", "keys",
  "model_mappings", "model_associations", "associations",
  "groups", "access_groups", "users", "accounts", "tokens", "user_tokens",
  "balances", "pricing", "model_pricing", "multipliers", "redemption_codes"
)
$providerSupportedFields = @("code", "id", "provider_id", "name", "type", "display_name", "kind", "adapter", "protocol", "base_url", "baseUrl", "endpoint", "url")
$modelSupportedFields = @("model_key", "model", "key", "name", "id", "display_name", "displayName", "family", "provider_family", "capabilities", "capability", "aliases", "source_aliases", "alias", "status")
$channelSupportedFields = @("id", "channel_id", "source_id", "provider", "provider_code", "provider_id", "provider_name", "type", "kind", "protocol", "endpoint", "base_url", "baseUrl", "url", "model_mappings", "model_mapping", "models_mapping", "mapping", "models", "model_list", "modelList", "tags", "tag", "groups", "group", "name", "display_name", "weight", "priority", "order", "status", "enabled", "keys", "provider_keys", "key", "api_key", "apiKey", "token", "secret", "provider_key", "protocol_mode", "adapter")
$keySupportedFields = @("channel_source_id", "channel_id", "channel", "source_channel_id", "alias", "key_alias", "name", "label", "secret", "secret_ref", "api_key", "apiKey", "key", "token", "value")
$mappingSupportedFields = @("canonical_model", "canonical_model_key", "target_model", "model", "client_model", "requested_model", "source_model", "from", "upstream_model", "provider_model", "to", "channel_source_id", "channel_id", "channel", "source_channel_id", "priority", "order", "weight", "enabled", "conditions")

foreach ($file in $inputFiles) {
  $rawJson = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
  try {
    $document = ConvertFrom-Json -InputObject $rawJson
  } catch {
    throw "Invalid JSON in '$($file.FullName)': $($_.Exception.Message)"
  }

  Add-UnsupportedFields $unsupportedFields $document $documentSupportedFields "$" $file.Name
  $sourceName = Get-PropertyValue $document @("source", "source_system", "system") "new-api"
  $sourceSlug = Convert-ToSlug $sourceName

  $providerIndex = 0
  foreach ($provider in (Convert-ToImportArray (Get-PropertyValue $document @("providers", "provider_configs", "provider")))) {
    $providerIndex += 1
    Add-UnsupportedFields $unsupportedFields $provider $providerSupportedFields "$.providers[$providerIndex]" $file.Name
    $providerId = Get-PropertyValue $provider @("code", "id", "provider_id", "name", "type") "openai-compatible"
    $providerName = Get-PropertyValue $provider @("display_name", "name", "code") $providerId
    $providerKind = Get-PropertyValue $provider @("kind", "type", "adapter", "protocol") "openai-compatible"
    $baseUrl = Get-PropertyValue $provider @("base_url", "baseUrl", "endpoint", "url") $null
    Add-ProviderPreview $providers $providerId $providerName $providerKind $baseUrl "${sourceSlug}:provider:${providerId}" $file.Name | Out-Null
  }

  $modelIndex = 0
  foreach ($model in (Convert-ToImportArray (Get-PropertyValue $document @("models", "canonical_models", "model_catalog")))) {
    $modelIndex += 1
    Add-UnsupportedFields $unsupportedFields $model $modelSupportedFields "$.models[$modelIndex]" $file.Name
    $modelKey = Get-PropertyValue $model @("model_key", "model", "key", "name", "id")
    Add-ModelPreview $models $modelKey `
      (Get-PropertyValue $model @("display_name", "displayName", "name") $modelKey) `
      (Get-PropertyValue $model @("family", "provider_family") $null) `
      (Get-PropertyValue $model @("capabilities", "capability") $null) `
      (Get-PropertyValue $model @("aliases", "source_aliases", "alias") $null) `
      (Get-PropertyValue $model @("status") "active")
  }

  $channelIndex = 0
  foreach ($channel in (Convert-ToImportArray (Get-PropertyValue $document @("channels", "channel_configs", "channel")))) {
    $channelIndex += 1
    Add-UnsupportedFields $unsupportedFields $channel $channelSupportedFields "$.channels[$channelIndex]" $file.Name
    $rawChannelId = Get-PropertyValue $channel @("id", "channel_id", "source_id") $channelIndex
    $channelSourceId = "${sourceSlug}:channel:${rawChannelId}"
    $channelIdToSource[[string]$rawChannelId] = $channelSourceId

    $providerRef = Get-PropertyValue $channel @("provider", "provider_code", "provider_id", "provider_name", "type") "openai-compatible"
    if ($providerRef -isnot [string]) {
      $providerRef = Get-PropertyValue $providerRef @("code", "id", "name", "type") "openai-compatible"
    }

    $endpoint = Get-PropertyValue $channel @("endpoint", "base_url", "baseUrl", "url") $null
    $providerCode = Add-ProviderPreview $providers $providerRef $providerRef (Get-PropertyValue $channel @("type", "kind", "protocol") "openai-compatible") $endpoint "${sourceSlug}:provider:${providerRef}" $file.Name
    $modelMappings = Convert-ToMappingTable (Get-PropertyValue $channel @("model_mappings", "model_mapping", "models_mapping", "mapping") $null)
    $channelModels = Convert-ToStringList (Get-PropertyValue $channel @("models", "model_list", "modelList") $null)
    $tags = @(
      Convert-ToStringList (Get-PropertyValue $channel @("tags", "tag") $null)
      Convert-ToStringList (Get-PropertyValue $channel @("groups", "group") $null)
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    $mappingPreview = foreach ($key in ($modelMappings.Keys | Sort-Object)) {
      [ordered]@{
        client_model = $key
        upstream_model = $modelMappings[$key]
      }
    }

    $channels.Add([ordered]@{
        source_id = $channelSourceId
        provider_code = $providerCode
        name = (Redact-SecretLikeString (Get-PropertyValue $channel @("name", "display_name") "channel-$rawChannelId")).Trim()
        endpoint = Redact-SecretLikeString $endpoint
        protocol_mode = Resolve-ProtocolMode $channel
        weight = [int](Get-PropertyValue $channel @("weight") 100)
        priority = [int](Get-PropertyValue $channel @("priority", "order") 0)
        tags = @($tags)
        status = Normalize-Status (Get-PropertyValue $channel @("status", "enabled") $null)
        model_mappings = @($mappingPreview)
      }) | Out-Null

    $inlineKeys = @()
    $inlineKeys += Convert-ToImportArray (Get-PropertyValue $channel @("keys", "provider_keys") $null)
    $singleKey = Get-PropertyValue $channel @("key", "api_key", "apiKey", "token", "secret", "provider_key") $null
    if ($null -ne $singleKey) {
      $inlineKeys += $singleKey
    }

    if ($inlineKeys.Count -eq 0) {
      $warnings.Add("Channel $channelSourceId has no provider key material in the input.") | Out-Null
    }

    $keyIndex = 0
    foreach ($keyEntry in $inlineKeys) {
      $keyIndex += 1
      Add-UnsupportedFields $unsupportedFields $keyEntry $keySupportedFields "$.channels[$channelIndex].keys[$keyIndex]" $file.Name
      $handoff = Get-CredentialHandoffPreview $keyEntry
      $providerKeys.Add([ordered]@{
          channel_source_id = $channelSourceId
          alias = Get-KeyAlias $keyEntry "$($channelSourceId)-key-$keyIndex"
          has_secret = Test-HasSecret $keyEntry
          credential_material_present = $handoff.credential_material_present
          credential_origin = $handoff.credential_origin
          credential_locator_redacted = $handoff.credential_locator_redacted
          credential_locator_hash = $handoff.credential_locator_hash
          raw_material_exported = $handoff.raw_material_exported
          requires_operator_entry = $handoff.requires_operator_entry
          recommended_path = $handoff.recommended_path
        }) | Out-Null
    }

    foreach ($modelName in $channelModels) {
      Add-ModelPreview $models $modelName
      $upstream = if ($modelMappings.Contains($modelName)) { $modelMappings[$modelName] } else { $modelName }
      Add-AssociationPreview $associations $associationKeys $modelName $modelName $channelSourceId $upstream `
        (Get-PropertyValue $channel @("priority", "order") 0) `
        (Get-PropertyValue $channel @("weight") 100) `
        ((Normalize-Status (Get-PropertyValue $channel @("status", "enabled") $null)) -eq "enabled") `
        ([ordered]@{ tags = @($tags) })
    }

    foreach ($mappedModel in $modelMappings.Keys) {
      if ($channelModels -notcontains $mappedModel) {
        Add-ModelPreview $models $mappedModel
        Add-AssociationPreview $associations $associationKeys $mappedModel $mappedModel $channelSourceId $modelMappings[$mappedModel] `
          (Get-PropertyValue $channel @("priority", "order") 0) `
          (Get-PropertyValue $channel @("weight") 100) `
          ((Normalize-Status (Get-PropertyValue $channel @("status", "enabled") $null)) -eq "enabled") `
          ([ordered]@{ tags = @($tags) })
      }
    }
  }

  $topLevelKeyIndex = 0
  foreach ($keyEntry in (Convert-ToImportArray (Get-PropertyValue $document @("provider_keys", "keys") $null))) {
    $topLevelKeyIndex += 1
    Add-UnsupportedFields $unsupportedFields $keyEntry $keySupportedFields "$.provider_keys[$topLevelKeyIndex]" $file.Name
    $channelRef = Get-PropertyValue $keyEntry @("channel_source_id", "channel_id", "channel", "source_channel_id") $null
    $channelSourceId = if ($null -ne $channelRef -and $channelIdToSource.ContainsKey([string]$channelRef)) {
      $channelIdToSource[[string]$channelRef]
    } elseif ($null -ne $channelRef) {
      (Redact-SecretLikeString $channelRef).Trim()
    } else {
      "unassigned"
    }

    if ($channelSourceId -eq "unassigned") {
      $warnings.Add("Top-level provider key has no channel reference.") | Out-Null
    }

    $handoff = Get-CredentialHandoffPreview $keyEntry
    $providerKeys.Add([ordered]@{
        channel_source_id = $channelSourceId
        alias = Get-KeyAlias $keyEntry "$channelSourceId-key"
        has_secret = Test-HasSecret $keyEntry
        credential_material_present = $handoff.credential_material_present
        credential_origin = $handoff.credential_origin
        credential_locator_redacted = $handoff.credential_locator_redacted
        credential_locator_hash = $handoff.credential_locator_hash
        raw_material_exported = $handoff.raw_material_exported
        requires_operator_entry = $handoff.requires_operator_entry
        recommended_path = $handoff.recommended_path
      }) | Out-Null
  }

  $mappingIndex = 0
  foreach ($mapping in (Convert-ToImportArray (Get-PropertyValue $document @("model_mappings", "model_associations", "associations") $null))) {
    $mappingIndex += 1
    Add-UnsupportedFields $unsupportedFields $mapping $mappingSupportedFields "$.model_mappings[$mappingIndex]" $file.Name
    $canonical = Get-PropertyValue $mapping @("canonical_model", "canonical_model_key", "target_model", "model") $null
    $requested = Get-PropertyValue $mapping @("client_model", "requested_model", "source_model", "from") $canonical
    $upstream = Get-PropertyValue $mapping @("upstream_model", "provider_model", "to") $canonical
    $channelRef = Get-PropertyValue $mapping @("channel_source_id", "channel_id", "channel", "source_channel_id") $null
    $channelSourceId = if ($null -ne $channelRef -and $channelIdToSource.ContainsKey([string]$channelRef)) {
      $channelIdToSource[[string]$channelRef]
    } else {
      Redact-SecretLikeString $channelRef
    }

    if ($null -eq $canonical) {
      $warnings.Add("Model mapping for requested model '$requested' has no canonical model.") | Out-Null
      continue
    }

    Add-ModelPreview $models $canonical
    Add-AssociationPreview $associations $associationKeys $canonical $requested $channelSourceId $upstream `
      (Get-PropertyValue $mapping @("priority", "order") 0) `
      (Get-PropertyValue $mapping @("weight") 100) `
      (Get-PropertyValue $mapping @("enabled") $true) `
      (Get-PropertyValue $mapping @("conditions") ([ordered]@{}))
  }

  foreach ($group in (Convert-ToImportArray (Get-PropertyValue $document @("groups", "access_groups") $null))) {
    Add-GroupEvidence $accessGroups $pricingMultipliers $nonMigratableItems $group $file.Name
  }

  foreach ($account in (Convert-ToImportArray (Get-PropertyValue $document @("users", "accounts") $null))) {
    Add-AccountEvidence $userProfiles $balanceRecords $nonMigratableItems $account $file.Name
  }

  foreach ($balance in (Convert-ToImportArray (Get-PropertyValue $document @("balances") $null))) {
    Add-AccountEvidence $userProfiles $balanceRecords $nonMigratableItems $balance $file.Name
  }

  foreach ($token in (Convert-ToImportArray (Get-PropertyValue $document @("tokens", "user_tokens") $null))) {
    Add-TokenEvidence $userTokens $nonMigratableItems $token $file.Name
  }

  foreach ($pricing in (Convert-ToImportArray (Get-PropertyValue $document @("pricing", "model_pricing", "multipliers") $null))) {
    $sourceKey = Get-PropertyValue $pricing @("model", "model_key", "group", "name", "id") "pricing"
    $preview = [ordered]@{
      source_key = Redact-SecretLikeString $sourceKey
      scope = Redact-SecretLikeString (Get-PropertyValue $pricing @("scope", "type") "pricing")
      ratio = Redact-SecretLikeString (Get-PropertyValue $pricing @("ratio", "multiplier") $null)
      prompt_ratio = Redact-SecretLikeString (Get-PropertyValue $pricing @("prompt_ratio", "input_ratio") $null)
      completion_ratio = Redact-SecretLikeString (Get-PropertyValue $pricing @("completion_ratio", "output_ratio") $null)
      input_file = $file.Name
    }
    $pricingMultipliers.Add($preview) | Out-Null
    Add-NonMigratableItem $nonMigratableItems "pricing_multiplier" "warning" ([string]$sourceKey) "Source pricing/multiplier data is not applied by this importer." $preview "Map source multipliers into internal price books and review units before apply." $file.Name
  }

  foreach ($code in (Convert-ToImportArray (Get-PropertyValue $document @("redemption_codes") $null))) {
    $codeId = Get-PropertyValue $code @("id", "code", "name") "redemption-code"
    Add-NonMigratableItem $nonMigratableItems "redemption_code" "error" ([string]$codeId) "Redemption/voucher artifacts are outside this importer." (Convert-ToStringList $code) "Use the voucher import/accounting path; do not import voucher artifacts through routing migration." $file.Name
  }
}

$inputFilePaths = @()
foreach ($file in $inputFiles) {
  $inputFilePaths += $file.FullName
}

$providerList = @()
foreach ($provider in $providers.Values) {
  $providerList += $provider
}

$modelList = @()
foreach ($model in $models.Values) {
  $modelList += $model
}

$channelList = @()
foreach ($channel in $channels) {
  $channelList += $channel
}

$providerKeyList = @()
foreach ($providerKey in $providerKeys) {
  $providerKeyList += $providerKey
}

$associationList = @()
foreach ($association in $associations) {
  $associationList += $association
}

$warningList = @()
foreach ($warning in $warnings) {
  $warningList += $warning
}

$unsupportedFieldList = @()
foreach ($unsupportedField in $unsupportedFields) {
  $unsupportedFieldList += $unsupportedField
}

$accessGroupList = @()
foreach ($accessGroup in $accessGroups) {
  $accessGroupList += $accessGroup
}

$userProfileList = @()
foreach ($userProfile in $userProfiles) {
  $userProfileList += $userProfile
}

$userTokenList = @()
foreach ($userToken in $userTokens) {
  $userTokenList += $userToken
}

$balanceRecordList = @()
foreach ($balanceRecord in $balanceRecords) {
  $balanceRecordList += $balanceRecord
}

$pricingMultiplierList = @()
foreach ($pricingMultiplier in $pricingMultipliers) {
  $pricingMultiplierList += $pricingMultiplier
}

$nonMigratableItemList = @()
foreach ($nonMigratableItem in $nonMigratableItems) {
  $nonMigratableItemList += $nonMigratableItem
}

function New-MappingQualityReadback {
  param(
    [string]$SourceSystem,
    [object[]]$ProviderList,
    [object[]]$ChannelList,
    [object[]]$ModelList,
    [object[]]$AssociationList,
    [object[]]$ProviderKeyList,
    [object[]]$UserProfileList,
    [object[]]$UserTokenList,
    [object[]]$BalanceRecordList,
    [object[]]$NonMigratableItemList
  )

  $nonMigratableReasons = @($NonMigratableItemList | ForEach-Object {
      [ordered]@{
        type = $_.type
        severity = $_.severity
        reason = if ($null -ne $_.summary) { $_.summary } else { $_.reason }
        recommended_action = $_.recommended_action
      }
    })
  $providerKeyHandoffRefs = @($ProviderKeyList | Where-Object {
      -not [string]::IsNullOrWhiteSpace([string]$_.recommended_path) -or
      -not [string]::IsNullOrWhiteSpace([string]$_.credential_locator_hash)
    })
  $blockedCount = @($NonMigratableItemList | Where-Object { $_.severity -eq "error" }).Count
  $manualCount = $NonMigratableItemList.Count + $ProviderKeyList.Count + $UserTokenList.Count + $BalanceRecordList.Count

  return [ordered]@{
    schema_version = "importer.mapping-quality-readback.v1"
    source_system = $SourceSystem
    status = if ($blockedCount -gt 0) { "manual-review-required" } else { "ready-for-apply-plan-review" }
    dry_run_only = $true
    secret_safe = $true
    mapping_counts = [ordered]@{
      provider_mappings = $ProviderList.Count
      channel_mappings = $ChannelList.Count
      model_mappings = $AssociationList.Count
      canonical_model_candidates = $ModelList.Count
      user_mappings = $UserProfileList.Count
      key_mappings = $ProviderKeyList.Count + $UserTokenList.Count
      provider_key_handoffs = $ProviderKeyList.Count
      user_key_reissue_handoffs = $UserTokenList.Count
      wallet_mappings = $BalanceRecordList.Count
      subscription_mappings = 0
      non_migratable_items = $NonMigratableItemList.Count
      conflicts = 0
    }
    conflicts = [ordered]@{
      count = 0
      blocking_count = 0
      refs = @()
    }
    non_migratable_reasons = $nonMigratableReasons
    operator_handoff_refs_presence = [ordered]@{
      provider_key_handoffs_present = $ProviderKeyList.Count -gt 0
      provider_key_handoff_refs_present = $providerKeyHandoffRefs.Count -gt 0
      user_key_reissue_refs_present = $UserTokenList.Count -gt 0
      wallet_opening_balance_refs_present = $BalanceRecordList.Count -gt 0
      subscription_mapping_refs_present = $false
      required_operator_path_present = $providerKeyHandoffRefs.Count -gt 0
    }
    safe_next_action = if ($manualCount -gt 0) {
      "Review mapping_quality_readback, resolve non-migratable reasons, then generate a reviewed apply-plan without raw key material."
    } else {
      "Generate the reviewed apply-plan and keep provider/user keys on operator handoff paths."
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

$counts = [ordered]@{
  providers = $providers.Count
  channels = $channels.Count
  provider_keys = $providerKeys.Count
  models = $models.Count
  associations = $associations.Count
  warnings = $warnings.Count
  unsupported_fields = $unsupportedFields.Count
  access_groups = $accessGroups.Count
  user_profiles = $userProfiles.Count
  user_tokens = $userTokens.Count
  balance_records = $balanceRecords.Count
  pricing_multipliers = $pricingMultipliers.Count
  non_migratable_items = $nonMigratableItems.Count
}

$applyPlanArtifacts = New-SourceSpecificApplyPlanArtifacts `
  -SourceSystem "new-api" `
  -Channels $channelList `
  -ProviderKeys $providerKeyList `
  -Associations $associationList `
  -AccessGroups $accessGroupList `
  -UserProfiles $userProfileList `
  -UserTokens $userTokenList `
  -BalanceRecords $balanceRecordList `
  -PricingMultipliers $pricingMultiplierList

$mappingQualityReadback = New-MappingQualityReadback `
  -SourceSystem "new-api" `
  -ProviderList $providerList `
  -ChannelList $channelList `
  -ModelList $modelList `
  -AssociationList $associationList `
  -ProviderKeyList $providerKeyList `
  -UserProfileList $userProfileList `
  -UserTokenList $userTokenList `
  -BalanceRecordList $balanceRecordList `
  -NonMigratableItemList $nonMigratableItemList

$report = [ordered]@{
  importer = "newapi-openai-compatible-dryrun"
  dry_run = $true
  generated_at = (Get-Date).ToUniversalTime().ToString("o")
  input_files = $inputFilePaths
  counts = $counts
  summary = $counts
  mapping_quality_readback = $mappingQualityReadback
  providers = @($providerList)
  channels = @($channelList)
  provider_keys = @($providerKeyList)
  models = @($modelList)
  associations = @($associationList)
  access_groups = @($accessGroupList)
  user_profiles = @($userProfileList)
  user_tokens = @($userTokenList)
  balance_records = @($balanceRecordList)
  pricing_multipliers = @($pricingMultiplierList)
  apply_plan_artifacts = $applyPlanArtifacts
  non_migratable_items = @($nonMigratableItemList)
  warnings = @($warningList)
  unsupported_fields = @($unsupportedFieldList)
  next_steps = @(
    "Review warnings and duplicate names before implementing apply.",
    "Apply/write-to-database is intentionally not implemented in this prototype."
  )
}

$json = $report | ConvertTo-Json -Depth 32
Write-Output (Redact-SecretLikeString $json)
