[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$InputPath,

  [switch]$DryRun = $true
)

$ErrorActionPreference = "Stop"

if (-not [bool]$DryRun) {
  throw "Only dry-run report mapping is implemented. Re-run with -DryRun or omit the flag."
}

$scriptPath = $PSCommandPath
if (-not $scriptPath) {
  $scriptPath = $MyInvocation.MyCommand.Path
}
$script:RepoRoot = (Resolve-Path (Join-Path (Split-Path -Parent $scriptPath) "..\..")).Path

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
  param([object]$Value)

  if ($null -eq $Value) {
    return @()
  }

  if ($Value -is [System.Array]) {
    return @($Value)
  }

  return @($Value)
}

function Convert-ToObjectArray {
  param([object]$Value)

  if ($null -eq $Value) {
    return @()
  }

  if ($Value -is [string]) {
    return @($Value)
  }

  if ($Value -is [System.Collections.IDictionary]) {
    return @($Value)
  }

  if ($Value -is [System.Collections.IEnumerable]) {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($item in $Value) {
      $items.Add($item) | Out-Null
    }
    return ,([object[]]$items.ToArray())
  }

  return @($Value)
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
  $text = $text -replace "(?i)(api[_-]?key|authorization|bearer|token|secret|password)=([^&\s""]+)", '$1=<redacted>'
  $text = $text -replace "://([^:/@\s]+):([^/@\s]+)@", "://<redacted>@"
  return $text
}

function Test-SensitiveFieldName {
  param([AllowNull()][object]$Name)

  if ($null -eq $Name) {
    return $false
  }

  return ([string]$Name) -match "(?i)(api[_-]?key|authorization|bearer|token|secret|password|encrypted_secret|cookie)"
}

function Convert-ToSafeObject {
  param(
    [AllowNull()][object]$Value,
    [string]$FieldName = ""
  )

  if ($null -eq $Value) {
    return $null
  }

  if (Test-SensitiveFieldName $FieldName) {
    return "<redacted>"
  }

  if ($Value -is [string]) {
    return Redact-SecretLikeString $Value
  }

  if ($Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [decimal] -or $Value -is [double] -or $Value -is [float]) {
    return $Value
  }

  if ($Value -is [System.Collections.IDictionary]) {
    $safeDictionary = [ordered]@{}
    foreach ($key in $Value.Keys) {
      $keyText = [string]$key
      $safeDictionary[$keyText] = Convert-ToSafeObject $Value[$key] $keyText
    }
    return $safeDictionary
  }

  if ($Value -is [System.Array]) {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($item in $Value) {
      $items.Add((Convert-ToSafeObject $item $FieldName)) | Out-Null
    }
    return ,([object[]]$items.ToArray())
  }

  $safe = [ordered]@{}
  foreach ($property in $Value.PSObject.Properties) {
    $safe[$property.Name] = Convert-ToSafeObject $property.Value $property.Name
  }

  return $safe
}

function Convert-ToSafeText {
  param(
    [AllowNull()][object]$Value,
    [AllowNull()][object]$Default = $null
  )

  if ($null -eq $Value) {
    if ($null -eq $Default) {
      return $null
    }
    $Value = $Default
  }

  return (Redact-SecretLikeString $Value).Trim()
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

    $name = Get-PropertyValue $item @("model_key", "canonical_model_key", "model", "name", "key", "id")
    if ($null -ne $name) {
      $text = (Redact-SecretLikeString $name).Trim()
      if (-not [string]::IsNullOrWhiteSpace($text)) {
        $items.Add($text)
      }
    }
  }

  return @($items | Select-Object -Unique)
}

function Add-UniqueString {
  param(
    [System.Collections.Generic.List[string]]$List,
    [AllowNull()][object]$Value
  )

  if ($null -eq $Value) {
    return
  }

  $text = (Redact-SecretLikeString $Value).Trim()
  if ([string]::IsNullOrWhiteSpace($text)) {
    return
  }

  if (-not $List.Contains($text)) {
    $List.Add($text) | Out-Null
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

function Normalize-AssociationStatus {
  param([object]$Enabled, [object]$Status)

  if ($null -ne $Enabled) {
    if ($Enabled -is [bool]) {
      if ($Enabled) {
        return "enabled"
      }
      return "disabled"
    }

    $text = ([string]$Enabled).Trim().ToLowerInvariant()
    if ($text -in @("1", "true", "enabled", "enable", "active", "ok")) {
      return "enabled"
    }
    if ($text -in @("0", "false", "disabled", "disable", "manual_disabled", "deleted")) {
      return "disabled"
    }
  }

  if ($null -ne $Status) {
    $statusText = ([string]$Status).Trim().ToLowerInvariant()
    if ($statusText -in @("enabled", "active", "1", "true", "ok")) {
      return "enabled"
    }
    if ($statusText -in @("disabled", "deleted", "manual_disabled", "0", "false")) {
      return "disabled"
    }
    return (Redact-SecretLikeString $statusText)
  }

  return "enabled"
}

function Get-DefaultFamily {
  param([string]$ModelKey)

  if ([string]::IsNullOrWhiteSpace($ModelKey)) {
    return "unknown"
  }

  return (($ModelKey -split "[-_:]", 2)[0])
}

function Get-DefaultCapabilities {
  param([string]$ModelKey)

  if ($ModelKey -match "(?i)embedding") {
    return @("embedding")
  }

  return @("text")
}

function Get-CapabilityFlags {
  param([object]$Capabilities)

  $capabilitySet = @{}
  foreach ($capability in (Convert-ToStringList $Capabilities)) {
    $capabilitySet[$capability.ToLowerInvariant()] = $true
  }

  return [ordered]@{
    supports_stream = $true
    supports_tools = ($capabilitySet.ContainsKey("tool") -or $capabilitySet.ContainsKey("tools"))
    supports_vision = ($capabilitySet.ContainsKey("vision") -or $capabilitySet.ContainsKey("image"))
    supports_audio = $capabilitySet.ContainsKey("audio")
    supports_reasoning = $capabilitySet.ContainsKey("reasoning")
  }
}

function Join-SortedList {
  param([object]$Value)

  return ((Convert-ToStringList $Value | Sort-Object -Unique) -join "|")
}

function Add-Conflict {
  param(
    [string]$Type,
    [string]$Severity,
    [string]$Key,
    [string]$Description,
    [object]$Items
  )

  $dedupeKey = "$Type|$Key|$Description"
  if ($script:conflictKeys.ContainsKey($dedupeKey)) {
    return
  }

  $script:conflictKeys[$dedupeKey] = $true
  $script:conflicts.Add([ordered]@{
      type = $Type
      severity = $Severity
      key = Redact-SecretLikeString $Key
      description = Redact-SecretLikeString $Description
      items = Convert-ToSafeObject $Items
    }) | Out-Null
}

function Add-ManualReviewItem {
  param(
    [string]$Type,
    [string]$Severity,
    [string]$Key,
    [string]$Summary,
    [object]$Details,
    [string]$RecommendedAction
  )

  $dedupeKey = "$Type|$Key|$Summary"
  if ($script:manualReviewKeys.ContainsKey($dedupeKey)) {
    return
  }

  $script:manualReviewKeys[$dedupeKey] = $true
  $script:manualReviewItems.Add([ordered]@{
      type = $Type
      severity = $Severity
      key = Redact-SecretLikeString $Key
      summary = Redact-SecretLikeString $Summary
      details = Convert-ToSafeObject $Details
      recommended_action = Redact-SecretLikeString $RecommendedAction
    }) | Out-Null
}

function Add-CanonicalModelPreview {
  param(
    [object]$ModelKey,
    [object]$DisplayName,
    [object]$Family,
    [object]$Capabilities,
    [object]$Aliases,
    [object]$Status,
    [string]$SourceReport,
    [string]$SourceReason
  )

  $key = Convert-ToSafeText $ModelKey
  if ([string]::IsNullOrWhiteSpace($key)) {
    Add-ManualReviewItem "missing_model_key" "error" $SourceReport "A model row has no model key." ([ordered]@{ source_reason = $SourceReason }) "Add a canonical model key before apply."
    return $null
  }

  $display = Convert-ToSafeText $DisplayName $key
  $familyText = Convert-ToSafeText $Family (Get-DefaultFamily $key)
  $capabilityList = @(Convert-ToStringList $Capabilities)
  if ($capabilityList.Count -eq 0) {
    $capabilityList = @(Get-DefaultCapabilities $key)
  }
  $statusText = Normalize-ModelStatus $Status
  $aliasList = @(Convert-ToStringList $Aliases)

  if (-not $script:canonicalModels.Contains($key)) {
    $capabilitiesList = New-Object System.Collections.Generic.List[string]
    foreach ($capability in $capabilityList) {
      Add-UniqueString $capabilitiesList $capability
    }

    $aliasesList = New-Object System.Collections.Generic.List[string]
    foreach ($alias in $aliasList) {
      Add-UniqueString $aliasesList $alias
    }

    $sourceReports = New-Object System.Collections.Generic.List[string]
    Add-UniqueString $sourceReports $SourceReport

    $sourceReasons = New-Object System.Collections.Generic.List[string]
    Add-UniqueString $sourceReasons $SourceReason

    $script:canonicalModels[$key] = [ordered]@{
      model_key = $key
      display_name = $display
      family = $familyText
      capabilities = $capabilitiesList
      capability_flags = Get-CapabilityFlags $capabilitiesList
      context_length = $null
      max_output_tokens = $null
      default_price_book_id = $null
      visibility = "internal"
      status = $statusText
      source_aliases = $aliasesList
      source_reports = $sourceReports
      source_reasons = $sourceReasons
      planned_action = "upsert"
    }

    return $key
  }

  $existing = $script:canonicalModels[$key]
  Add-UniqueString $existing.source_reports $SourceReport
  Add-UniqueString $existing.source_reasons $SourceReason

  if (-not [string]::IsNullOrWhiteSpace($display) -and $existing.display_name -ne $display) {
    Add-Conflict "canonical_model_definition_conflict" "warning" $key "Canonical model display_name differs across input reports." @(
      [ordered]@{ field = "display_name"; value = $existing.display_name; source = "first_seen" },
      [ordered]@{ field = "display_name"; value = $display; source = $SourceReport }
    )
  }

  if (-not [string]::IsNullOrWhiteSpace($familyText) -and $existing.family -ne $familyText) {
    Add-Conflict "canonical_model_definition_conflict" "warning" $key "Canonical model family differs across input reports." @(
      [ordered]@{ field = "family"; value = $existing.family; source = "first_seen" },
      [ordered]@{ field = "family"; value = $familyText; source = $SourceReport }
    )
  }

  if ($existing.status -ne $statusText) {
    Add-Conflict "canonical_model_definition_conflict" "warning" $key "Canonical model status differs across input reports." @(
      [ordered]@{ field = "status"; value = $existing.status; source = "first_seen" },
      [ordered]@{ field = "status"; value = $statusText; source = $SourceReport }
    )
  }

  $existingCapabilitySignature = Join-SortedList $existing.capabilities
  $newCapabilitySignature = Join-SortedList $capabilityList
  if ($existingCapabilitySignature -ne $newCapabilitySignature) {
    Add-Conflict "canonical_model_definition_conflict" "warning" $key "Canonical model capabilities differ across input reports; output uses the union." @(
      [ordered]@{ field = "capabilities"; value = @($existing.capabilities); source = "first_seen" },
      [ordered]@{ field = "capabilities"; value = @($capabilityList); source = $SourceReport }
    )
  }

  foreach ($capability in $capabilityList) {
    Add-UniqueString $existing.capabilities $capability
  }
  foreach ($alias in $aliasList) {
    Add-UniqueString $existing.source_aliases $alias
  }
  $existing.capability_flags = Get-CapabilityFlags $existing.capabilities

  return $key
}

function Add-ChannelPreview {
  param(
    [object]$Channel,
    [string]$SourceReport
  )

  $sourceId = Convert-ToSafeText (Get-PropertyValue $Channel @("source_id", "channel_source_id", "id", "channel_id"))
  if ([string]::IsNullOrWhiteSpace($sourceId)) {
    Add-ManualReviewItem "missing_channel_source_id" "error" $SourceReport "A channel row has no source_id." ([ordered]@{ channel = $Channel }) "Add a stable source channel id before apply."
    return $null
  }

  $providerCode = Convert-ToSafeText (Get-PropertyValue $Channel @("provider_code", "provider", "provider_id")) "unknown"
  $name = Convert-ToSafeText (Get-PropertyValue $Channel @("name", "display_name")) $sourceId
  $endpoint = Convert-ToSafeText (Get-PropertyValue $Channel @("endpoint", "base_url", "baseUrl", "url"))
  $protocolMode = Convert-ToSafeText (Get-PropertyValue $Channel @("protocol_mode", "protocol")) "openai_compatible"
  $status = Convert-ToSafeText (Get-PropertyValue $Channel @("status")) "enabled"
  $priority = [int](Get-PropertyValue $Channel @("priority", "order") 0)
  $weight = [int](Get-PropertyValue $Channel @("weight") 100)
  $tags = @(Convert-ToStringList (Get-PropertyValue $Channel @("tags", "groups", "group") $null))

  if (-not $script:channels.Contains($sourceId)) {
    $tagList = New-Object System.Collections.Generic.List[string]
    foreach ($tag in $tags) {
      Add-UniqueString $tagList $tag
    }

    $sourceReports = New-Object System.Collections.Generic.List[string]
    Add-UniqueString $sourceReports $SourceReport

    $script:channels[$sourceId] = [ordered]@{
      source_id = $sourceId
      provider_code = $providerCode
      name = $name
      endpoint = $endpoint
      protocol_mode = $protocolMode
      priority = $priority
      weight = $weight
      tags = $tagList
      status = $status
      source_reports = $sourceReports
    }

    return $sourceId
  }

  $existing = $script:channels[$sourceId]
  Add-UniqueString $existing.source_reports $SourceReport
  foreach ($tag in $tags) {
    Add-UniqueString $existing.tags $tag
  }

  foreach ($field in @("provider_code", "name", "endpoint", "protocol_mode", "status")) {
    $newValue = switch ($field) {
      "provider_code" { $providerCode }
      "name" { $name }
      "endpoint" { $endpoint }
      "protocol_mode" { $protocolMode }
      "status" { $status }
    }

    if ($null -ne $newValue -and $existing[$field] -ne $newValue) {
      Add-Conflict "channel_definition_conflict" "warning" $sourceId "Channel $field differs across input reports." @(
        [ordered]@{ field = $field; value = $existing[$field]; source = "first_seen" },
        [ordered]@{ field = $field; value = $newValue; source = $SourceReport }
      )
    }
  }

  return $sourceId
}

function Add-ProviderKeyHandoff {
  param(
    [object]$ProviderKey,
    [string]$SourceReport
  )

  $channelSourceId = Convert-ToSafeText (Get-PropertyValue $ProviderKey @("channel_source_id", "source_channel_id", "channel_id", "channel") $null)
  $aliasDefault = if ([string]::IsNullOrWhiteSpace($channelSourceId)) { "provider-key" } else { "$channelSourceId-provider-key" }
  $keyAlias = Convert-ToSafeText (Get-PropertyValue $ProviderKey @("alias", "key_alias", "name", "label") $aliasDefault)
  $materialPresent = [bool](Get-PropertyValue $ProviderKey @("credential_material_present", "has_secret", "has_credential") $false)
  $credentialOrigin = Convert-ToSafeText (Get-PropertyValue $ProviderKey @("credential_origin", "credential_source") $(if ($materialPresent) { "unknown_redacted" } else { "missing" }))
  $locatorRedacted = Convert-ToSafeText (Get-PropertyValue $ProviderKey @("credential_locator_redacted", "credential_ref_redacted", "locator_redacted") $null)
  $locatorHash = Convert-ToSafeText (Get-PropertyValue $ProviderKey @("credential_locator_hash", "credential_ref_hash", "locator_hash") $null)
  $locatorHashValues = @(Convert-ToImportArray (Get-PropertyValue $ProviderKey @("credential_locator_hashes", "credential_ref_hashes", "locator_hashes") $null))
  if ($locatorHashValues.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($locatorHash)) {
    $locatorHashValues = @($locatorHash)
  }
  $rawMaterialExported = [bool](Get-PropertyValue $ProviderKey @("raw_material_exported") $false)
  $recommendedPath = Convert-ToSafeText (Get-PropertyValue $ProviderKey @("recommended_path") "POST /admin/provider-keys")
  $requiresOperatorEntry = [bool](Get-PropertyValue $ProviderKey @("requires_operator_entry") $materialPresent)

  if ([string]::IsNullOrWhiteSpace($channelSourceId) -or $channelSourceId -eq "unassigned") {
    Add-ManualReviewItem "provider_key_missing_channel_binding" "error" "$SourceReport|$keyAlias" "Provider key evidence has no source channel binding." ([ordered]@{
        key_alias = $keyAlias
        source_report = $SourceReport
        credential_material_present = $materialPresent
        raw_material_exported = $rawMaterialExported
      }) "Bind this provider key evidence to an imported channel before entering credentials."
  } elseif (-not $script:channels.Contains($channelSourceId)) {
    Add-ManualReviewItem "provider_key_unknown_channel" "warning" "$channelSourceId|$keyAlias" "Provider key evidence references a source channel not present in imported channels." ([ordered]@{
        channel_source_id = $channelSourceId
        key_alias = $keyAlias
        source_report = $SourceReport
      }) "Map the source channel first, or discard this key handoff item."
  }

  if (-not $materialPresent) {
    Add-ManualReviewItem "provider_key_material_missing" "warning" "$channelSourceId|$keyAlias" "Provider key evidence is present but no credential material or credential reference was found." ([ordered]@{
        channel_source_id = $channelSourceId
        key_alias = $keyAlias
        source_report = $SourceReport
      }) "Enter a provider key manually through the Control Plane provider-key create path before traffic is routed to this channel."
  }

  if ($rawMaterialExported) {
    Add-Conflict "provider_key_raw_material_exported" "error" "$channelSourceId|$keyAlias" "Provider key handoff attempted to export raw credential material." ([ordered]@{
        channel_source_id = $channelSourceId
        key_alias = $keyAlias
        source_report = $SourceReport
      })
    Add-ManualReviewItem "provider_key_raw_material_exported" "error" "$channelSourceId|$keyAlias" "Remove raw provider key material from importer artifacts." ([ordered]@{
        channel_source_id = $channelSourceId
        key_alias = $keyAlias
      }) "Rerun the source importer and only use redacted credential references or the Control Plane secret-management path."
  }

  $handoffKey = "$channelSourceId|$keyAlias"
  if (-not $script:providerKeyHandoffKeys.ContainsKey($handoffKey)) {
    $sourceReports = New-Object System.Collections.Generic.List[string]
    Add-UniqueString $sourceReports $SourceReport

    $locatorHashes = New-Object System.Collections.Generic.List[string]
    foreach ($hash in $locatorHashValues) {
      Add-UniqueString $locatorHashes $hash
    }

    $script:providerKeyHandoffKeys[$handoffKey] = [ordered]@{
      handoff_id = "provider-key-handoff:v1:$(Get-StableHash $handoffKey 24)"
      channel_source_id = if ([string]::IsNullOrWhiteSpace($channelSourceId)) { $null } else { $channelSourceId }
      key_alias = $keyAlias
      credential_material_present = $materialPresent
      credential_origin = $credentialOrigin
      credential_locator_redacted = $locatorRedacted
      credential_locator_hashes = $locatorHashes
      raw_material_exported = $false
      provider_key_material_included = $false
      requires_operator_entry = $requiresOperatorEntry
      recommended_path = $recommendedPath
      apply_directly_supported = $false
      source_reports = $sourceReports
    }
    [void]$script:providerKeyHandoffs.Add($script:providerKeyHandoffKeys[$handoffKey])
    return
  }

  $existing = $script:providerKeyHandoffKeys[$handoffKey]
  Add-UniqueString $existing.source_reports $SourceReport
  foreach ($hash in $locatorHashValues) {
    Add-UniqueString $existing.credential_locator_hashes $hash
  }
  $existing.credential_material_present = ([bool]$existing.credential_material_present -or $materialPresent)
  $existing.requires_operator_entry = ([bool]$existing.requires_operator_entry -or $requiresOperatorEntry)
  if ([string]::IsNullOrWhiteSpace($existing.credential_locator_redacted) -and -not [string]::IsNullOrWhiteSpace($locatorRedacted)) {
    $existing.credential_locator_redacted = $locatorRedacted
  }
  if ($existing.credential_origin -ne $credentialOrigin -and -not [string]::IsNullOrWhiteSpace($credentialOrigin)) {
    Add-ManualReviewItem "provider_key_handoff_origin_conflict" "warning" "$channelSourceId|$keyAlias" "Provider key handoff has multiple credential origins for the same channel/key alias." ([ordered]@{
        channel_source_id = $channelSourceId
        key_alias = $keyAlias
        first_origin = $existing.credential_origin
        new_origin = $credentialOrigin
      }) "Confirm whether these refer to the same provider credential before creating provider keys."
  }
}

function Add-ChannelMappingEntry {
  param(
    [object]$ChannelSourceId,
    [object]$RequestedModel,
    [object]$CanonicalModelKey,
    [object]$UpstreamModelName,
    [string]$Source,
    [string]$SourceReport
  )

  $channel = Convert-ToSafeText $ChannelSourceId
  $requested = Convert-ToSafeText $RequestedModel
  if ([string]::IsNullOrWhiteSpace($channel) -or [string]::IsNullOrWhiteSpace($requested)) {
    return
  }

  $canonical = Convert-ToSafeText $CanonicalModelKey
  $upstream = Convert-ToSafeText $UpstreamModelName $requested
  $mappingKey = "$channel|$requested"

  if (-not $script:channelMappingEntries.Contains($mappingKey)) {
    $sources = New-Object System.Collections.Generic.List[string]
    Add-UniqueString $sources $Source

    $sourceReports = New-Object System.Collections.Generic.List[string]
    Add-UniqueString $sourceReports $SourceReport

    $script:channelMappingEntries[$mappingKey] = [ordered]@{
      channel_source_id = $channel
      requested_model = $requested
      canonical_model_key = $canonical
      upstream_model_name = $upstream
      mapping_policy = if ($requested -ne $upstream) { "explicit_upstream_name" } else { "identity" }
      sources = $sources
      source_reports = $sourceReports
    }

    return
  }

  $existing = $script:channelMappingEntries[$mappingKey]
  Add-UniqueString $existing.sources $Source
  Add-UniqueString $existing.source_reports $SourceReport

  if (-not [string]::IsNullOrWhiteSpace($canonical)) {
    if ([string]::IsNullOrWhiteSpace($existing.canonical_model_key)) {
      $existing.canonical_model_key = $canonical
    } elseif ($existing.canonical_model_key -ne $canonical) {
      Add-Conflict "channel_mapping_conflict" "error" $mappingKey "Same channel/requested model maps to different canonical models." @(
        [ordered]@{ channel_source_id = $channel; requested_model = $requested; canonical_model_key = $existing.canonical_model_key; source = "first_seen" },
        [ordered]@{ channel_source_id = $channel; requested_model = $requested; canonical_model_key = $canonical; source = $SourceReport }
      )
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($upstream) -and $existing.upstream_model_name -ne $upstream) {
    Add-Conflict "channel_mapping_conflict" "error" $mappingKey "Same channel/requested model maps to different upstream model names." @(
      [ordered]@{ channel_source_id = $channel; requested_model = $requested; upstream_model_name = $existing.upstream_model_name; source = "first_seen" },
      [ordered]@{ channel_source_id = $channel; requested_model = $requested; upstream_model_name = $upstream; source = $SourceReport }
    )
  }

  $existing.mapping_policy = if ($existing.requested_model -ne $existing.upstream_model_name) { "explicit_upstream_name" } else { "identity" }
}

function Add-RequestedModelIndex {
  param(
    [string]$RequestedModel,
    [string]$CanonicalModelKey,
    [object]$Association
  )

  if ([string]::IsNullOrWhiteSpace($RequestedModel) -or [string]::IsNullOrWhiteSpace($CanonicalModelKey)) {
    return
  }

  if (-not $script:requestedModelIndex.ContainsKey($RequestedModel)) {
    $script:requestedModelIndex[$RequestedModel] = [ordered]@{}
  }

  if (-not $script:requestedModelIndex[$RequestedModel].Contains($CanonicalModelKey)) {
    $script:requestedModelIndex[$RequestedModel][$CanonicalModelKey] = New-Object System.Collections.Generic.List[object]
  }

  $script:requestedModelIndex[$RequestedModel][$CanonicalModelKey].Add($Association) | Out-Null
}

function Add-AssociationPreview {
  param(
    [object]$Association,
    [string]$SourceReport
  )

  $canonical = Convert-ToSafeText (Get-PropertyValue $Association @("canonical_model_key", "canonical_model", "model_key", "model"))
  $requested = Convert-ToSafeText (Get-PropertyValue $Association @("requested_model", "client_model", "source_model", "from")) $canonical
  $channel = Convert-ToSafeText (Get-PropertyValue $Association @("channel_source_id", "channel_id", "channel"))
  $upstream = Convert-ToSafeText (Get-PropertyValue $Association @("upstream_model_name", "upstream_model", "provider_model", "to")) $canonical
  $priority = [int](Get-PropertyValue $Association @("priority", "order") 100)
  $weight = [int](Get-PropertyValue $Association @("weight") 100)
  $status = Normalize-AssociationStatus (Get-PropertyValue $Association @("enabled") $null) (Get-PropertyValue $Association @("status") $null)
  $conditions = Convert-ToSafeObject (Get-PropertyValue $Association @("conditions") ([ordered]@{}))

  if ([string]::IsNullOrWhiteSpace($canonical)) {
    Add-ManualReviewItem "missing_canonical_model" "error" $SourceReport "An association has no canonical model." ([ordered]@{ requested_model = $requested; channel_source_id = $channel }) "Assign a canonical model before apply."
    return
  }

  if (-not $script:canonicalModels.Contains($canonical)) {
    Add-CanonicalModelPreview $canonical $canonical (Get-DefaultFamily $canonical) (Get-DefaultCapabilities $canonical) @() "active" $SourceReport "association_reference" | Out-Null
    Add-ManualReviewItem "canonical_model_missing_definition" "warning" $canonical "Canonical model was referenced by an association but not defined in the source report model list." ([ordered]@{ canonical_model_key = $canonical; requested_model = $requested }) "Confirm display name, family, capabilities, visibility, and pricing before apply."
  }

  if (-not [string]::IsNullOrWhiteSpace($channel) -and -not $script:channels.Contains($channel)) {
    Add-Conflict "missing_channel_reference" "error" $channel "Association references a channel that is not present in the input report channels list." @(
      [ordered]@{ canonical_model_key = $canonical; requested_model = $requested; channel_source_id = $channel; source = $SourceReport }
    )
    Add-ManualReviewItem "missing_channel_reference" "error" $channel "Resolve missing source channel reference before apply." ([ordered]@{ channel_source_id = $channel; requested_model = $requested; canonical_model_key = $canonical }) "Map the source channel to an imported channel or remove the association."
  }

  $associationType = if ([string]::IsNullOrWhiteSpace($channel)) { "global" } else { "explicit_channel" }
  $dedupeKey = "$canonical|$requested|$associationType|$channel|$upstream|$priority|$weight|$status"
  if ($script:associationKeys.ContainsKey($dedupeKey)) {
    return
  }
  $script:associationKeys[$dedupeKey] = $true

  $sourceReports = New-Object System.Collections.Generic.List[string]
  Add-UniqueString $sourceReports $SourceReport

  $preview = [ordered]@{
    canonical_model_key = $canonical
    requested_model = $requested
    association_type = $associationType
    channel_source_id = if ([string]::IsNullOrWhiteSpace($channel)) { $null } else { $channel }
    channel_tag = $null
    model_pattern = $null
    upstream_model_name = $upstream
    priority = $priority
    weight = $weight
    conditions = $conditions
    fallback_allowed = $true
    canary_percent = 100
    status = $status
    planned_action = "upsert"
    source_reports = $sourceReports
  }

  $script:modelAssociations.Add($preview) | Out-Null
  Add-RequestedModelIndex $requested $canonical $preview

  if (-not [string]::IsNullOrWhiteSpace($channel)) {
    Add-ChannelMappingEntry $channel $requested $canonical $upstream "model_association" $SourceReport
  }
}

function Add-SourceWarningManualReview {
  param(
    [object]$Report,
    [string]$SourceReport
  )

  $warnings = @(Convert-ToImportArray (Get-PropertyValue $Report @("warnings") $null))
  if ($warnings.Count -gt 0) {
    Add-ManualReviewItem "source_report_warnings" "warning" $SourceReport "Source dry-run report contains warnings." ([ordered]@{ warnings = @($warnings | ForEach-Object { Redact-SecretLikeString $_ }) }) "Review and resolve source parser warnings before apply."
  }

  $unsupportedFields = @(Convert-ToImportArray (Get-PropertyValue $Report @("unsupported_fields") $null))
  if ($unsupportedFields.Count -gt 0) {
    Add-ManualReviewItem "source_report_unsupported_fields" "warning" $SourceReport "Source dry-run report contains unsupported fields." ([ordered]@{ unsupported_fields = @($unsupportedFields | ForEach-Object { Convert-ToSafeObject $_ }) }) "Confirm unsupported fields are not required for routing, billing, or access control."
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

$script:canonicalModels = [ordered]@{}
$script:channels = [ordered]@{}
$script:channelMappingEntries = [ordered]@{}
$script:providerKeyHandoffs = New-Object System.Collections.Generic.List[object]
$script:providerKeyHandoffKeys = @{}
$script:modelAssociations = New-Object System.Collections.Generic.List[object]
$script:associationKeys = @{}
$script:requestedModelIndex = @{}
$script:conflicts = New-Object System.Collections.Generic.List[object]
$script:conflictKeys = @{}
$script:manualReviewItems = New-Object System.Collections.Generic.List[object]
$script:manualReviewKeys = @{}
$sourceReports = New-Object System.Collections.Generic.List[object]
$sourceSpecificApplyPlanArtifacts = New-Object System.Collections.Generic.List[object]

$sourceProviderCount = 0
$sourceChannelCount = 0
$sourceProviderKeyCount = 0
$sourceModelCount = 0
$sourceAssociationCount = 0

foreach ($file in $inputFiles) {
  $rawJson = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
  try {
    $report = ConvertFrom-Json -InputObject $rawJson
  } catch {
    throw "Invalid JSON in '$($file.FullName)': $($_.Exception.Message)"
  }

  $inputDryRun = Get-PropertyValue $report @("dry_run", "dryRun", "DryRun") $true
  if (-not [bool]$inputDryRun) {
    throw "Input report '$($file.FullName)' must be a dry-run report."
  }

  $importerName = Convert-ToSafeText (Get-PropertyValue $report @("importer", "source", "source_system")) "unknown-importer"
  $sourceReportKey = "$($file.Name):$importerName"
  $reportCounts = Convert-ToSafeObject (Get-PropertyValue $report @("counts", "summary") ([ordered]@{}))

  $sourceReports.Add([ordered]@{
      input_file = Get-RepoRelativePath $file.FullName
      importer = $importerName
      dry_run = $true
      counts = $reportCounts
    }) | Out-Null

  $sourceSpecificArtifacts = Get-PropertyValue $report @("apply_plan_artifacts") $null
  if ($null -ne $sourceSpecificArtifacts) {
    $sourceSpecificApplyPlanArtifacts.Add([ordered]@{
        input_file = Get-RepoRelativePath $file.FullName
        importer = $importerName
        artifacts = Convert-ToSafeObject $sourceSpecificArtifacts
      }) | Out-Null
  }

  $sourceProviderCount += @(Convert-ToImportArray (Get-PropertyValue $report @("providers") $null)).Count
  $sourceChannelCount += @(Convert-ToImportArray (Get-PropertyValue $report @("channels") $null)).Count
  $sourceProviderKeyCount += @(Convert-ToImportArray (Get-PropertyValue $report @("provider_keys") $null)).Count
  $sourceModelCount += @(Convert-ToImportArray (Get-PropertyValue $report @("models", "canonical_models") $null)).Count
  $sourceAssociationCount += @(Convert-ToImportArray (Get-PropertyValue $report @("associations", "model_associations") $null)).Count

  if ($importerName -eq "sub2api-operator-handoff-plan-dryrun") {
    $sub2ProviderPlans = @(Convert-ToImportArray (Get-PropertyValue $report @("provider_plans") $null))
    $sub2ChannelPlans = @(Convert-ToImportArray (Get-PropertyValue $report @("channel_plans") $null))
    $sub2ProviderKeyHandoffs = @(Convert-ToImportArray (Get-PropertyValue $report @("provider_key_handoffs") $null))
    $sub2ManualReviewItems = @(Convert-ToImportArray (Get-PropertyValue $report @("manual_review_items") $null))

    $sourceProviderCount += $sub2ProviderPlans.Count
    $sourceChannelCount += $sub2ChannelPlans.Count
    $sourceProviderKeyCount += $sub2ProviderKeyHandoffs.Count

    foreach ($channelPlan in $sub2ChannelPlans) {
      $channelSourceId = Convert-ToSafeText (Get-PropertyValue $channelPlan @("channel_source_id", "source_id") $null)
      $channelName = Convert-ToSafeText (Get-PropertyValue $channelPlan @("channel_name", "name") $channelSourceId)
      $providerCode = Convert-ToSafeText (Get-PropertyValue $channelPlan @("provider_code", "provider") "sub2api")
      $endpoint = Convert-ToSafeText (Get-PropertyValue $channelPlan @("endpoint", "base_url", "url") $null)
      $status = Convert-ToSafeText (Get-PropertyValue $channelPlan @("status") "enabled")
      $priority = Get-PropertyValue $channelPlan @("priority") 100
      $groups = Convert-ToObjectArray (Get-PropertyValue $channelPlan @("groups", "tags") @())

      Add-ChannelPreview ([ordered]@{
          source_id = $channelSourceId
          provider_code = $providerCode
          name = $channelName
          endpoint = $endpoint
          protocol_mode = "openai_compatible"
          priority = $priority
          weight = 100
          tags = $groups
          status = $status
        }) $sourceReportKey | Out-Null

      if ([string]::IsNullOrWhiteSpace($endpoint)) {
        Add-ManualReviewItem "sub2api_channel_endpoint_missing" "warning" $channelSourceId "Sub2API channel has no endpoint in the handoff plan." ([ordered]@{
            channel_source_id = $channelSourceId
            provider_code = $providerCode
            channel_name = $channelName
          }) "Set or confirm the upstream endpoint before routing production traffic."
      }
    }

    foreach ($handoff in $sub2ProviderKeyHandoffs) {
      Add-ProviderKeyHandoff $handoff $sourceReportKey
    }

    if ($sub2ManualReviewItems.Count -gt 0) {
      Add-ManualReviewItem "sub2api_handoff_manual_review" "warning" $sourceReportKey "Sub2API handoff contains manual review items." ([ordered]@{
          items = Convert-ToSafeObject $sub2ManualReviewItems
        }) "Resolve or explicitly accept these handoff review items before apply."
    }

    $sub2Counts = Get-PropertyValue $report @("counts", "summary") ([ordered]@{})
    $identityEvidenceCount = [int](Get-PropertyValue $sub2Counts @("source_users") 0) + [int](Get-PropertyValue $sub2Counts @("source_api_keys") 0) + [int](Get-PropertyValue $sub2Counts @("source_subscriptions") 0)
    if ($identityEvidenceCount -gt 0) {
      Add-ManualReviewItem "sub2api_identity_billing_not_auto_applied" "warning" $sourceReportKey "Sub2API users, user keys, subscriptions, and balances are evidence-only in this apply chain." ([ordered]@{
          source_users = Get-PropertyValue $sub2Counts @("source_users") 0
          source_api_keys = Get-PropertyValue $sub2Counts @("source_api_keys") 0
          source_subscriptions = Get-PropertyValue $sub2Counts @("source_subscriptions") 0
        }) "Build a reviewed identity/billing migration plan before writing users, wallets, user keys, subscriptions, or balances."
    }

    Add-SourceWarningManualReview $report $sourceReportKey
    continue
  }

  foreach ($model in (Convert-ToImportArray (Get-PropertyValue $report @("models", "canonical_models") $null))) {
    $modelKey = Get-PropertyValue $model @("model_key", "canonical_model_key", "model", "key", "name", "id")
    Add-CanonicalModelPreview $modelKey `
      (Get-PropertyValue $model @("display_name", "displayName", "name") $modelKey) `
      (Get-PropertyValue $model @("family", "provider_family") $null) `
      (Get-PropertyValue $model @("capabilities", "capability") $null) `
      (Get-PropertyValue $model @("source_aliases", "aliases", "alias") $null) `
      (Get-PropertyValue $model @("status") "active") `
      $sourceReportKey `
      "source_model" | Out-Null
  }

  foreach ($channel in (Convert-ToImportArray (Get-PropertyValue $report @("channels") $null))) {
    $channelSourceId = Add-ChannelPreview $channel $sourceReportKey
    if ([string]::IsNullOrWhiteSpace($channelSourceId)) {
      continue
    }

    foreach ($mapping in (Convert-ToImportArray (Get-PropertyValue $channel @("model_mappings", "model_mapping", "models_mapping", "mapping") $null))) {
      $requested = Get-PropertyValue $mapping @("client_model", "requested_model", "source_model", "from", "model", "name")
      $upstream = Get-PropertyValue $mapping @("upstream_model", "upstream_model_name", "provider_model", "to", "mapped_model", "value")
      Add-ChannelMappingEntry $channelSourceId $requested $null $upstream "channel_model_mapping" $sourceReportKey
    }
  }

  foreach ($providerKey in (Convert-ToImportArray (Get-PropertyValue $report @("provider_keys") $null))) {
    Add-ProviderKeyHandoff $providerKey $sourceReportKey
  }

  foreach ($association in (Convert-ToImportArray (Get-PropertyValue $report @("associations", "model_associations") $null))) {
    Add-AssociationPreview $association $sourceReportKey
  }

  Add-SourceWarningManualReview $report $sourceReportKey
}

foreach ($requested in ($requestedModelIndex.Keys | Sort-Object)) {
  $canonicalKeys = @($requestedModelIndex[$requested].Keys | Sort-Object)
  if ($canonicalKeys.Count -le 1) {
    continue
  }

  $items = New-Object System.Collections.Generic.List[object]
  foreach ($canonicalKey in $canonicalKeys) {
    foreach ($association in $requestedModelIndex[$requested][$canonicalKey]) {
      $items.Add([ordered]@{
          requested_model = $requested
          canonical_model_key = $canonicalKey
          channel_source_id = $association.channel_source_id
          upstream_model_name = $association.upstream_model_name
          source_reports = Convert-ToObjectArray $association.source_reports
        }) | Out-Null
    }
  }

  $conflictItems = Convert-ToObjectArray $items
  Add-Conflict "requested_model_conflict" "error" $requested "Requested model maps to multiple canonical models." $conflictItems
  Add-ManualReviewItem "requested_model_conflict" "error" $requested "Choose one canonical model for this requested model, or split visibility/profile rules before apply." ([ordered]@{ requested_model = $requested; canonical_model_keys = @($canonicalKeys); associations = $conflictItems }) "Resolve the requested model mapping conflict before apply."
}

$canonicalModelKeys = @($canonicalModels.Keys | Sort-Object)
if ($canonicalModelKeys.Count -gt 0) {
  Add-ManualReviewItem "canonical_model_defaults" "info" "canonical_models" "Confirm canonical model visibility, limits, capabilities, and default price books." ([ordered]@{
      model_keys = @($canonicalModelKeys)
      default_visibility = "internal"
      default_price_book_id = $null
    }) "Set public/internal visibility and pricing before applying to production."
}

$channelSourceIds = @($channels.Keys | Sort-Object)
if ($channelSourceIds.Count -gt 0) {
  Add-ManualReviewItem "channel_binding_required" "info" "channels" "Bind source channel ids to internal provider/channel records before apply." ([ordered]@{
      channel_source_ids = @($channelSourceIds)
      provider_key_material_included = $false
    }) "Create or match channels first, then enter provider keys through the secret-management path."
}

foreach ($mappingEntry in $channelMappingEntries.Values) {
  if ([string]::IsNullOrWhiteSpace($mappingEntry.canonical_model_key)) {
    Add-ManualReviewItem "channel_mapping_without_association" "warning" "$($mappingEntry.channel_source_id)|$($mappingEntry.requested_model)" "Channel mapping has no matching model association." ([ordered]@{
        channel_source_id = $mappingEntry.channel_source_id
        requested_model = $mappingEntry.requested_model
        upstream_model_name = $mappingEntry.upstream_model_name
      }) "Add a model association or remove this channel mapping before apply."
  }
}

$channelMappingGroups = [ordered]@{}
foreach ($entry in $channelMappingEntries.Values) {
  if (-not $channelMappingGroups.Contains($entry.channel_source_id)) {
    $channelMappingGroups[$entry.channel_source_id] = New-Object System.Collections.Generic.List[object]
  }
  $channelMappingGroups[$entry.channel_source_id].Add($entry) | Out-Null
}

foreach ($channelSourceId in $channels.Keys) {
  if (-not $channelMappingGroups.Contains($channelSourceId)) {
    $channelMappingGroups[$channelSourceId] = New-Object System.Collections.Generic.List[object]
  }
}

$channelMappings = New-Object System.Collections.Generic.List[object]
foreach ($channelSourceId in ($channelMappingGroups.Keys | Sort-Object)) {
  $channel = $null
  $channelPresent = $channels.Contains($channelSourceId)
  if ($channelPresent) {
    $channel = $channels[$channelSourceId]
  }

  $entries = @($channelMappingGroups[$channelSourceId] | Sort-Object requested_model)
  $channelMappings.Add([ordered]@{
      channel_source_id = $channelSourceId
      channel_present = $channelPresent
      provider_code = if ($channelPresent) { $channel.provider_code } else { $null }
      channel_name = if ($channelPresent) { $channel.name } else { $null }
      endpoint = if ($channelPresent) { $channel.endpoint } else { $null }
      protocol_mode = if ($channelPresent) { $channel.protocol_mode } else { $null }
      priority = if ($channelPresent) { $channel.priority } else { $null }
      weight = if ($channelPresent) { $channel.weight } else { $null }
      tags = if ($channelPresent) { Convert-ToObjectArray $channel.tags } else { Convert-ToObjectArray @() }
      status = if ($channelPresent) { $channel.status } else { "missing_channel" }
      mapping_entries = @($entries)
      planned_action = if ($channelPresent) { "bind_or_create_channel_mapping" } else { "manual_channel_resolution" }
    }) | Out-Null
}

$canonicalModelList = New-Object System.Collections.Generic.List[object]
foreach ($modelKey in ($canonicalModels.Keys | Sort-Object)) {
  $model = $canonicalModels[$modelKey]
  $model.capability_flags = Get-CapabilityFlags $model.capabilities
  $canonicalModelList.Add($model) | Out-Null
}

$modelAssociationList = @($modelAssociations | Sort-Object canonical_model_key, requested_model, channel_source_id, upstream_model_name)
$channelMappingEntryCount = 0
foreach ($mapping in $channelMappings) {
  $channelMappingEntryCount += @($mapping.mapping_entries).Count
}
$providerKeyHandoffList = @($providerKeyHandoffs | Sort-Object channel_source_id, key_alias, handoff_id)

$inputFilePaths = @()
foreach ($file in $inputFiles) {
  $inputFilePaths += (Get-RepoRelativePath $file.FullName)
}

$counts = [ordered]@{
  input_reports = $inputFiles.Count
  source_providers = $sourceProviderCount
  source_channels = $sourceChannelCount
  source_provider_keys = $sourceProviderKeyCount
  source_models = $sourceModelCount
  source_associations = $sourceAssociationCount
  canonical_models = $canonicalModelList.Count
  model_associations = $modelAssociationList.Count
  channel_mappings = $channelMappings.Count
  channel_mapping_entries = $channelMappingEntryCount
  provider_key_handoffs = $providerKeyHandoffList.Count
  conflicts = $conflicts.Count
  manual_review_items = $manualReviewItems.Count
}

$sourceArtifactSubscriptionCount = 0
$sourceArtifactWalletCount = 0
$sourceArtifactUserKeyCount = 0
foreach ($artifact in $sourceSpecificApplyPlanArtifacts) {
  $inner = if ($null -ne $artifact.artifacts) { $artifact.artifacts } else { $artifact }
  $categories = Get-PropertyValue $inner @("categories") $null
  $manual = Get-PropertyValue $categories @("manual") $null
  $blocked = Get-PropertyValue $categories @("blocked") $null
  $sourceArtifactSubscriptionCount += @(Convert-ToObjectArray (Get-PropertyValue $manual @("subscription_mappings") @())).Count
  $sourceArtifactWalletCount += @(Convert-ToObjectArray (Get-PropertyValue $manual @("wallet_opening_balance_candidates") @())).Count
  $sourceArtifactUserKeyCount += @(Convert-ToObjectArray (Get-PropertyValue $blocked @("user_key_reissue_handoffs") @())).Count
}

$mappingQualityReadback = [ordered]@{
  schema_version = "importer.mapping-quality-readback.v1"
  source_system = "internal-mapping-report"
  status = if ($conflicts.Count -gt 0) { "manual-review-required" } else { "ready-for-apply-plan-review" }
  dry_run_only = $true
  secret_safe = $true
  mapping_counts = [ordered]@{
    provider_mappings = $sourceProviderCount
    channel_mappings = $sourceChannelCount + $channelMappings.Count
    model_mappings = $modelAssociationList.Count + $channelMappingEntryCount
    canonical_model_candidates = $canonicalModelList.Count
    user_mappings = 0
    key_mappings = $providerKeyHandoffList.Count + $sourceArtifactUserKeyCount
    provider_key_handoffs = $providerKeyHandoffList.Count
    user_key_reissue_handoffs = $sourceArtifactUserKeyCount
    wallet_mappings = $sourceArtifactWalletCount
    subscription_mappings = $sourceArtifactSubscriptionCount
    non_migratable_items = $manualReviewItems.Count
    conflicts = $conflicts.Count
  }
  conflicts = [ordered]@{
    count = $conflicts.Count
    blocking_count = @($conflicts | Where-Object { $_.severity -eq "error" }).Count
    refs = @(Convert-ToObjectArray $conflicts | ForEach-Object {
        [ordered]@{
          severity = $_.severity
          kind = $_.kind
          key = $_.key
          reason = $_.reason
        }
      })
  }
  non_migratable_reasons = @(Convert-ToObjectArray $manualReviewItems | ForEach-Object {
      [ordered]@{
        type = Get-PropertyValue $_ @("type") "manual_review"
        severity = Get-PropertyValue $_ @("severity") "warning"
        reason = Get-PropertyValue $_ @("summary", "reason") "Manual review required."
        recommended_action = Get-PropertyValue $_ @("recommended_action") "Review before apply."
      }
    })
  operator_handoff_refs_presence = [ordered]@{
    provider_key_handoffs_present = $providerKeyHandoffList.Count -gt 0
    provider_key_handoff_refs_present = $providerKeyHandoffList.Count -gt 0
    user_key_reissue_refs_present = $sourceArtifactUserKeyCount -gt 0
    wallet_opening_balance_refs_present = $sourceArtifactWalletCount -gt 0
    subscription_mapping_refs_present = $sourceArtifactSubscriptionCount -gt 0
    required_operator_path_present = $providerKeyHandoffList.Count -gt 0 -or $sourceArtifactUserKeyCount -gt 0
  }
  safe_next_action = if ($conflicts.Count -gt 0) {
    "Resolve conflicts and manual review items before generating a reviewed apply-plan."
  } else {
    "Generate import-apply-plan dry-run and review provider/channel/model mappings plus operator handoff refs."
  }
  forbidden_material_returned = $false
  raw_provider_key_returned = $false
  raw_user_key_returned = $false
  token_returned = $false
  db_url_returned = $false
  raw_sql_returned = $false
  authorization_returned = $false
}

$report = [ordered]@{
  importer = "internal-mapping-report-dryrun"
  dry_run = $true
  generated_at = (Get-Date).ToUniversalTime().ToString("o")
  input_files = $inputFilePaths
  source_reports = Convert-ToObjectArray $sourceReports
  counts = $counts
  mapping_quality_readback = $mappingQualityReadback
  canonical_models = Convert-ToObjectArray $canonicalModelList
  model_associations = Convert-ToObjectArray $modelAssociationList
  channel_mappings = Convert-ToObjectArray $channelMappings
  provider_key_handoffs = Convert-ToObjectArray $providerKeyHandoffList
  source_specific_apply_plan_artifacts = Convert-ToObjectArray $sourceSpecificApplyPlanArtifacts
  provider_key_handoff_contract = [ordered]@{
    schema_version = "importer.provider-key-handoff-contract.v1"
    raw_material_allowed = $false
    apply_directly_supported = $false
    required_operator_path = "POST /admin/provider-keys"
    target_table = "provider_keys"
    target_secret_columns = @("encrypted_secret", "secret_fingerprint")
    handoff_count = $providerKeyHandoffList.Count
  }
  conflicts = Convert-ToObjectArray $conflicts
  manual_review_items = Convert-ToObjectArray $manualReviewItems
  next_steps = @(
    "Resolve all conflicts, especially requested_model conflicts and missing channel references.",
    "Confirm canonical model visibility, capabilities, limits, and default price books.",
    "Review provider_key_handoffs and enter provider keys through the Control Plane secret-management path; this report intentionally omits raw credential material.",
    "Use the reviewed report as the preview contract for a future apply + rollback snapshot implementation."
  )
}

$json = $report | ConvertTo-Json -Depth 64
Write-Output (Redact-SecretLikeString $json)
