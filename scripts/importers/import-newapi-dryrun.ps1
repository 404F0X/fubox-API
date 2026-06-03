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
$channelIdToSource = @{}

$documentSupportedFields = @(
  "source", "source_system", "system", "exported_at",
  "providers", "provider_configs", "provider",
  "channels", "channel_configs", "channel",
  "models", "canonical_models", "model_catalog",
  "provider_keys", "keys",
  "model_mappings", "model_associations", "associations"
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
      $providerKeys.Add([ordered]@{
          channel_source_id = $channelSourceId
          alias = Get-KeyAlias $keyEntry "$($channelSourceId)-key-$keyIndex"
          has_secret = Test-HasSecret $keyEntry
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

    $providerKeys.Add([ordered]@{
        channel_source_id = $channelSourceId
        alias = Get-KeyAlias $keyEntry "$channelSourceId-key"
        has_secret = Test-HasSecret $keyEntry
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

$counts = [ordered]@{
  providers = $providers.Count
  channels = $channels.Count
  provider_keys = $providerKeys.Count
  models = $models.Count
  associations = $associations.Count
  warnings = $warnings.Count
  unsupported_fields = $unsupportedFields.Count
}

$report = [ordered]@{
  importer = "newapi-openai-compatible-dryrun"
  dry_run = $true
  generated_at = (Get-Date).ToUniversalTime().ToString("o")
  input_files = $inputFilePaths
  counts = $counts
  summary = $counts
  providers = @($providerList)
  channels = @($channelList)
  provider_keys = @($providerKeyList)
  models = @($modelList)
  associations = @($associationList)
  warnings = @($warningList)
  unsupported_fields = @($unsupportedFieldList)
  next_steps = @(
    "Review warnings and duplicate names before implementing apply.",
    "Apply/write-to-database is intentionally not implemented in this prototype."
  )
}

$json = $report | ConvertTo-Json -Depth 32
Write-Output (Redact-SecretLikeString $json)
