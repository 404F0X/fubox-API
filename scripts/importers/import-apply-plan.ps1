[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$InputPath,

  [string]$ExistingStatePath,

  [ValidateSet("PostgreSqlSqlPlan")]
  [string]$ApplyExecutor = "PostgreSqlSqlPlan",

  [string]$TenantId = "00000000-0000-0000-0000-000000000001",

  [switch]$DryRun = $true,

  [switch]$Apply,

  [switch]$Force
)

$ErrorActionPreference = "Stop"

$script:ApplyRequested = [bool]$Apply
$script:ForceConfirmed = [bool]$Force
$script:ApplyExecutor = $ApplyExecutor
$script:TenantId = ([string]$TenantId).Trim()

if ($script:ApplyRequested -and -not $script:ForceConfirmed) {
  throw "Apply requires explicit -Apply -Force. This slice is read-only and no database writes were made."
}

if (-not [bool]$DryRun) {
  throw "Only dry-run apply planning is implemented. Omit -DryRun or pass -DryRun; no database writes were made."
}

$scriptPath = $PSCommandPath
if (-not $scriptPath) {
  $scriptPath = $MyInvocation.MyCommand.Path
}
$script:RepoRoot = (Resolve-Path (Join-Path (Split-Path -Parent $scriptPath) "..\..")).Path

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

  if ($Value -is [string]) {
    return @($Value)
  }

  if ($Value -is [System.Collections.IDictionary]) {
    return @($Value)
  }

  if ($Value -is [System.Array]) {
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

function Convert-ToObjectArray {
  param([object]$Value)

  if ($null -eq $Value) {
    return @()
  }

  return @(Convert-ToImportArray $Value)
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

function Test-AbsoluteLocalPath {
  param([AllowNull()][object]$Value)

  if ($null -eq $Value) {
    return $false
  }

  $text = [string]$Value
  return ($text -match "^[A-Za-z]:[\\/]" -or $text -match "^[\\/]{2}[^\\/]+[\\/]")
}

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

  $fileName = [System.IO.Path]::GetFileName($target)
  if ([string]::IsNullOrWhiteSpace($fileName)) {
    return "<absolute-path>"
  }

  return $fileName
}

function Convert-ToSafePathText {
  param([AllowNull()][object]$Value)

  if ($null -eq $Value) {
    return $null
  }

  $text = Redact-SecretLikeString $Value
  if ([string]::IsNullOrWhiteSpace($text)) {
    return $text
  }

  if (Test-AbsoluteLocalPath $text) {
    return Get-RepoRelativePath $text
  }

  return ($text -replace "\\", "/")
}

function Test-SensitiveFieldName {
  param([AllowNull()][object]$Name)

  if ($null -eq $Name) {
    return $false
  }

  $text = [string]$Name
  if ($text -match "(?i)(^|_)(input|output|cache_read|cache_write|reasoning|max_output)_tokens?$") {
    return $false
  }

  return $text -match "(?i)(api[_-]?key|authorization|bearer|token|secret|password|encrypted_secret|cookie)"
}

function Test-PathLikeFieldName {
  param([AllowNull()][object]$Name)

  if ($null -eq $Name) {
    return $false
  }

  return ([string]$Name) -match "(?i)(^|_)(path|paths|file|files|input_file|input_files|output_file|snapshot_file)$"
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
    if (Test-PathLikeFieldName $FieldName) {
      return Convert-ToSafePathText $Value
    }

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

function Convert-ToKeyPart {
  param([AllowNull()][object]$Value)

  $text = Convert-ToSafeText $Value ""
  if ([string]::IsNullOrWhiteSpace($text)) {
    return "<null>"
  }

  return $text
}

function Convert-ToSlug {
  param([AllowNull()][object]$Value)

  if ($null -eq $Value) {
    return "object"
  }

  $slug = ([string]$Value).Trim().ToLowerInvariant() -replace "[^a-z0-9]+", "_"
  $slug = $slug.Trim("_")
  if ([string]::IsNullOrWhiteSpace($slug)) {
    return "object"
  }

  return $slug
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
    $text = $Value | ConvertTo-Json -Depth 64 -Compress
  }
  if ($null -eq $text) {
    $text = ""
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

function New-DeterministicUuid {
  param([AllowNull()][object]$Seed)

  $hash = Get-StableHash $Seed 32
  return "{0}-{1}-{2}-{3}-{4}" -f `
    $hash.Substring(0, 8),
    $hash.Substring(8, 4),
    $hash.Substring(12, 4),
    $hash.Substring(16, 4),
    $hash.Substring(20, 12)
}

function New-BeforeImageSnapshot {
  param(
    [string]$Action,
    [AllowNull()][object]$Before
  )

  $objectExists = $false
  $captureMode = "not_found_in_existing_state"
  $objectHash = $null
  if ($null -ne $Before) {
    $objectExists = $true
    $captureMode = "existing_state_before_image"
    $objectHash = Get-StableHash $Before 32
  }

  return [ordered]@{
    schema_version = "importer.before-image.v1"
    object_exists = $objectExists
    object_hash = $objectHash
    object = $Before
    capture_mode = $captureMode
    dry_run_shape_only = $true
    required_for_rollback = ($Action -eq "update")
  }
}

function Select-ComparableFields {
  param(
    [string]$Kind,
    [object]$Object
  )

  $safe = Convert-ToSafeObject $Object
  $result = [ordered]@{}

  switch ($Kind) {
    "provider" {
      $fields = @(
        "provider_code", "code", "name", "status", "metadata"
      )
    }
    "channel" {
      $fields = @(
        "channel_source_id", "provider_code", "name", "channel_name", "endpoint",
        "protocol_mode", "status", "region", "priority", "weight", "tags",
        "model_mappings", "request_overrides", "timeout_policy", "probe_policy",
        "health_score"
      )
    }
    "canonical_model" {
      $fields = @(
        "model_key", "display_name", "family", "capabilities", "capability_flags",
        "context_length", "max_output_tokens", "default_price_book_id", "visibility",
        "status", "source_aliases"
      )
    }
    "model_association" {
      $fields = @(
        "canonical_model_key", "requested_model", "association_type", "channel_source_id",
        "channel_tag", "model_pattern", "upstream_model_name", "priority", "weight",
        "conditions", "fallback_allowed", "canary_percent", "status"
      )
    }
    "channel_mapping_entry" {
      $fields = @(
        "channel_source_id", "requested_model", "canonical_model_key",
        "upstream_model_name", "mapping_policy"
      )
    }
    default {
      return $safe
    }
  }

  foreach ($field in $fields) {
    $result[$field] = Get-PropertyValue $safe @($field) $null
  }

  return $result
}

function Get-ProviderNaturalKey {
  param([object]$Provider)

  $providerCode = Convert-ToKeyPart (Get-PropertyValue $Provider @("provider_code", "code", "provider", "provider_id", "id") $null)
  return "provider_code=$providerCode"
}

function Get-ChannelNaturalKey {
  param([object]$Channel)

  $providerCode = Convert-ToKeyPart (Get-PropertyValue $Channel @("provider_code", "provider", "provider_id") $null)
  $channelName = Convert-ToKeyPart (Get-PropertyValue $Channel @("name", "channel_name", "display_name") $null)
  return "provider_code=$providerCode|channel_name=$channelName"
}

function Get-CanonicalModelNaturalKey {
  param([object]$Model)

  $modelKey = Convert-ToKeyPart (Get-PropertyValue $Model @("model_key", "canonical_model_key", "model", "key", "name", "id") $null)
  return "model_key=$modelKey"
}

function Get-AssociationNaturalKey {
  param([object]$Association)

  $requestedModel = Convert-ToKeyPart (Get-PropertyValue $Association @("requested_model", "client_model", "source_model") $null)
  $canonicalModel = Convert-ToKeyPart (Get-PropertyValue $Association @("canonical_model_key", "canonical_model", "model_key") $null)
  $associationType = Convert-ToKeyPart (Get-PropertyValue $Association @("association_type") "explicit_channel")
  $channelSourceId = Convert-ToKeyPart (Get-PropertyValue $Association @("channel_source_id", "source_channel_id") $null)
  $channelTag = Convert-ToKeyPart (Get-PropertyValue $Association @("channel_tag") $null)
  $modelPattern = Convert-ToKeyPart (Get-PropertyValue $Association @("model_pattern") $null)
  $upstreamModel = Convert-ToKeyPart (Get-PropertyValue $Association @("upstream_model_name", "upstream_model", "provider_model") $null)

  return "requested_model=$requestedModel|canonical_model_key=$canonicalModel|association_type=$associationType|channel_source_id=$channelSourceId|channel_tag=$channelTag|model_pattern=$modelPattern|upstream_model_name=$upstreamModel"
}

function Get-ChannelMappingEntryNaturalKey {
  param([object]$Entry)

  $channelSourceId = Convert-ToKeyPart (Get-PropertyValue $Entry @("channel_source_id", "source_channel_id") $null)
  $requestedModel = Convert-ToKeyPart (Get-PropertyValue $Entry @("requested_model", "client_model", "source_model") $null)
  $canonicalModel = Convert-ToKeyPart (Get-PropertyValue $Entry @("canonical_model_key", "canonical_model", "model_key") $null)
  $upstreamModel = Convert-ToKeyPart (Get-PropertyValue $Entry @("upstream_model_name", "upstream_model", "provider_model") $null)

  return "channel_source_id=$channelSourceId|requested_model=$requestedModel|canonical_model_key=$canonicalModel|upstream_model_name=$upstreamModel"
}

function New-SourceChannelBindingRef {
  param([object]$Mapping)

  $channelSourceId = Convert-ToSafeText (Get-PropertyValue $Mapping @("channel_source_id", "source_channel_id") $null)
  if ([string]::IsNullOrWhiteSpace($channelSourceId)) {
    return $null
  }

  return [ordered]@{
    channel_source_id = $channelSourceId
    channel_present = [bool](Get-PropertyValue $Mapping @("channel_present") $true)
    provider_code = Convert-ToSafeText (Get-PropertyValue $Mapping @("provider_code") $null)
    channel_name = Convert-ToSafeText (Get-PropertyValue $Mapping @("channel_name", "name") $null)
    protocol_mode = Convert-ToSafeText (Get-PropertyValue $Mapping @("protocol_mode") $null)
    internal_provider_id = Convert-ToSafeText (Get-PropertyValue $Mapping @("internal_provider_id", "provider_id") $null)
    internal_channel_id = Convert-ToSafeText (Get-PropertyValue $Mapping @("internal_channel_id", "channel_id") $null)
  }
}

function New-ProviderPreviewFromChannelMapping {
  param(
    [object]$Mapping,
    [string]$TenantId
  )

  $channelPresent = [bool](Get-PropertyValue $Mapping @("channel_present") $true)
  if (-not $channelPresent) {
    return $null
  }

  $providerCode = Convert-ToSafeText (Get-PropertyValue $Mapping @("provider_code", "provider", "provider_id") $null)
  if ([string]::IsNullOrWhiteSpace($providerCode)) {
    return $null
  }

  $internalProviderId = Convert-ToSafeText (Get-PropertyValue $Mapping @("internal_provider_id", "provider_id") $null)
  if ([string]::IsNullOrWhiteSpace($internalProviderId)) {
    $internalProviderId = New-DeterministicUuid "$TenantId|provider|$providerCode"
  }

  $providerName = Convert-ToSafeText (Get-PropertyValue $Mapping @("provider_name", "provider_display_name", "provider_label", "provider_code") $providerCode)
  $channelSourceId = Convert-ToSafeText (Get-PropertyValue $Mapping @("channel_source_id", "source_channel_id") $null)

  return [ordered]@{
    internal_provider_id = $internalProviderId
    provider_code = $providerCode
    code = $providerCode
    name = $providerName
    status = Normalize-ProviderStatus (Get-PropertyValue $Mapping @("provider_status", "status") "enabled")
    metadata = [ordered]@{
      importer = "import-apply-plan"
      source = "channel_mappings"
      source_channel_id = $channelSourceId
      provider_key_material_imported = $false
    }
  }
}

function New-ChannelPreviewFromChannelMapping {
  param(
    [object]$Mapping,
    [string]$TenantId
  )

  $channelPresent = [bool](Get-PropertyValue $Mapping @("channel_present") $true)
  if (-not $channelPresent) {
    return $null
  }

  $channelSourceId = Convert-ToSafeText (Get-PropertyValue $Mapping @("channel_source_id", "source_channel_id") $null)
  $providerCode = Convert-ToSafeText (Get-PropertyValue $Mapping @("provider_code", "provider", "provider_id") $null)
  $channelName = Convert-ToSafeText (Get-PropertyValue $Mapping @("channel_name", "name", "display_name") $null)
  $endpoint = Convert-ToSafeText (Get-PropertyValue $Mapping @("endpoint", "base_url", "baseUrl", "url") $null)
  if ([string]::IsNullOrWhiteSpace($channelSourceId) -or [string]::IsNullOrWhiteSpace($providerCode) -or [string]::IsNullOrWhiteSpace($channelName) -or [string]::IsNullOrWhiteSpace($endpoint)) {
    return $null
  }

  $internalProviderId = Convert-ToSafeText (Get-PropertyValue $Mapping @("internal_provider_id", "provider_id") $null)
  if ([string]::IsNullOrWhiteSpace($internalProviderId)) {
    $internalProviderId = New-DeterministicUuid "$TenantId|provider|$providerCode"
  }

  $internalChannelId = Convert-ToSafeText (Get-PropertyValue $Mapping @("internal_channel_id", "channel_id") $null)
  if ([string]::IsNullOrWhiteSpace($internalChannelId)) {
    $internalChannelId = New-DeterministicUuid "$TenantId|channel|$providerCode|$channelName"
  }

  $priority = Get-NullableIntField $Mapping @("priority")
  if ($null -eq $priority) { $priority = 100 }
  $weight = Get-NullableIntField $Mapping @("weight")
  if ($null -eq $weight) { $weight = 100 }
  $healthScore = Get-NullableDecimalField $Mapping @("health_score", "healthScore")
  if ($null -eq $healthScore) { $healthScore = [decimal]1.0 }

  return [ordered]@{
    channel_source_id = $channelSourceId
    internal_provider_id = $internalProviderId
    internal_channel_id = $internalChannelId
    provider_code = $providerCode
    name = $channelName
    channel_name = $channelName
    endpoint = $endpoint
    protocol_mode = Convert-ToSafeText (Get-PropertyValue $Mapping @("protocol_mode", "protocol") "openai_compatible")
    status = Normalize-ChannelStatus (Get-PropertyValue $Mapping @("channel_status", "status") "enabled")
    region = Convert-ToSafeText (Get-PropertyValue $Mapping @("region") $null)
    priority = $priority
    weight = $weight
    tags = Convert-ToSafeObject (Get-PropertyValue $Mapping @("tags") @())
    model_mappings = Convert-ToSafeObject (Get-PropertyValue $Mapping @("model_mappings", "modelMappings") ([ordered]@{}))
    request_overrides = Convert-ToSafeObject (Get-PropertyValue $Mapping @("request_overrides", "requestOverrides") @())
    timeout_policy = Convert-ToSafeObject (Get-PropertyValue $Mapping @("timeout_policy", "timeoutPolicy") ([ordered]@{}))
    probe_policy = Convert-ToSafeObject (Get-PropertyValue $Mapping @("probe_policy", "probePolicy") ([ordered]@{}))
    health_score = $healthScore
  }
}

function Test-SourceChannelBindingShape {
  param(
    [object[]]$WriteOperations,
    [hashtable]$ChannelBindings
  )

  $errors = New-Object System.Collections.Generic.List[object]
  $checked = New-Object System.Collections.Generic.List[object]
  foreach ($operation in $WriteOperations) {
    if ($operation.target.kind -ne "model_association" -and $operation.target.kind -ne "channel_mapping_entry") {
      continue
    }

    $channelSourceId = Convert-ToSafeText (Get-PropertyValue $operation.after @("channel_source_id", "source_channel_id") $null)
    $providerCode = $null
    $internalProviderId = $null
    $internalChannelId = $null
    $channelPresent = $false
    if (-not [string]::IsNullOrWhiteSpace($channelSourceId) -and $ChannelBindings.ContainsKey($channelSourceId)) {
      $binding = $ChannelBindings[$channelSourceId]
      $providerCode = Convert-ToSafeText (Get-PropertyValue $binding @("provider_code") $null)
      $internalProviderId = Convert-ToSafeText (Get-PropertyValue $binding @("internal_provider_id") $null)
      $internalChannelId = Convert-ToSafeText (Get-PropertyValue $binding @("internal_channel_id") $null)
      $channelPresent = [bool](Get-PropertyValue $binding @("channel_present") $false)
    }

    $checked.Add([ordered]@{
        operation_id = $operation.operation_id
        target = $operation.target
        channel_source_id = $channelSourceId
        provider_code = $providerCode
        internal_provider_id_present = (-not [string]::IsNullOrWhiteSpace($internalProviderId))
        internal_channel_id_present = (-not [string]::IsNullOrWhiteSpace($internalChannelId))
      }) | Out-Null

    if ([string]::IsNullOrWhiteSpace($channelSourceId)) {
      $errors.Add([ordered]@{ operation_id = $operation.operation_id; target = $operation.target; reason = "missing_channel_source_id" }) | Out-Null
      continue
    }
    if (-not $ChannelBindings.ContainsKey($channelSourceId)) {
      $errors.Add([ordered]@{ operation_id = $operation.operation_id; target = $operation.target; channel_source_id = $channelSourceId; reason = "missing_source_channel_binding" }) | Out-Null
      continue
    }
    if (-not $channelPresent) {
      $errors.Add([ordered]@{ operation_id = $operation.operation_id; target = $operation.target; channel_source_id = $channelSourceId; reason = "source_channel_not_present" }) | Out-Null
    }
    if ([string]::IsNullOrWhiteSpace($providerCode) -and [string]::IsNullOrWhiteSpace($internalProviderId)) {
      $errors.Add([ordered]@{ operation_id = $operation.operation_id; target = $operation.target; channel_source_id = $channelSourceId; reason = "missing_source_provider_binding" }) | Out-Null
    }
    if ([string]::IsNullOrWhiteSpace($internalChannelId)) {
      $errors.Add([ordered]@{ operation_id = $operation.operation_id; target = $operation.target; channel_source_id = $channelSourceId; reason = "missing_internal_channel_binding" }) | Out-Null
    }
  }

  return [ordered]@{
    checked = @(Convert-ToObjectArray $checked)
    errors = @(Convert-ToObjectArray $errors)
  }
}

function Convert-ToOperatorProviderKeyPath {
  param([AllowNull()][object]$Value)

  $text = Convert-ToSafeText $Value "POST /admin/provider-keys"
  if ([string]::IsNullOrWhiteSpace($text) -or $text -eq "control_plane_provider_key_create") {
    return "POST /admin/provider-keys"
  }

  return $text
}

function New-ProviderKeyHandoffSidecar {
  param(
    [object]$Handoff,
    [hashtable]$ChannelBindings
  )

  $safe = Convert-ToSafeObject $Handoff
  $channelSourceId = Convert-ToSafeText (Get-PropertyValue $safe @("channel_source_id", "source_channel_id", "channel_id", "channel") $null)
  $keyAlias = Convert-ToSafeText (Get-PropertyValue $safe @("key_alias", "alias", "name", "label") $null)
  if ([string]::IsNullOrWhiteSpace($keyAlias)) {
    $keyAlias = if ([string]::IsNullOrWhiteSpace($channelSourceId)) { "provider-key" } else { "$channelSourceId-provider-key" }
  }

  $handoffKey = "$channelSourceId|$keyAlias"
  $handoffId = Convert-ToSafeText (Get-PropertyValue $safe @("handoff_id", "id") $null)
  if ([string]::IsNullOrWhiteSpace($handoffId)) {
    $handoffId = "provider-key-handoff:v1:$(Get-StableHash $handoffKey 24)"
  }

  $locatorHashes = New-Object System.Collections.Generic.List[object]
  foreach ($hash in (Convert-ToImportArray (Get-PropertyValue $safe @("credential_locator_hashes", "credential_locator_hash", "credential_ref_hash", "locator_hash") $null))) {
    $hashText = Convert-ToSafeText $hash $null
    if (-not [string]::IsNullOrWhiteSpace($hashText) -and -not @($locatorHashes.ToArray()).Contains($hashText)) {
      $locatorHashes.Add($hashText) | Out-Null
    }
  }

  $sourceReports = New-Object System.Collections.Generic.List[object]
  foreach ($sourceReport in (Convert-ToImportArray (Get-PropertyValue $safe @("source_reports", "source_report") $null))) {
    $sourceReportText = Convert-ToSafeText $sourceReport $null
    if (-not [string]::IsNullOrWhiteSpace($sourceReportText) -and -not @($sourceReports.ToArray()).Contains($sourceReportText)) {
      $sourceReports.Add($sourceReportText) | Out-Null
    }
  }

  $binding = $null
  $bindingStatus = "missing_channel_source_id"
  if (-not [string]::IsNullOrWhiteSpace($channelSourceId) -and $ChannelBindings.ContainsKey($channelSourceId)) {
    $binding = Convert-ToSafeObject $ChannelBindings[$channelSourceId]
    if ([bool](Get-PropertyValue $binding @("channel_present") $false)) {
      $bindingStatus = "bound"
    } else {
      $bindingStatus = "source_channel_not_present"
    }
  } elseif (-not [string]::IsNullOrWhiteSpace($channelSourceId)) {
    $bindingStatus = "missing_source_channel_binding"
  }

  $materialPresent = [bool](Get-PropertyValue $safe @("credential_material_present", "has_secret", "has_credential") $false)
  $rawMaterialExported = [bool](Get-PropertyValue $safe @("raw_material_exported") $false)
  $materialIncluded = [bool](Get-PropertyValue $safe @("provider_key_material_included", "key_material_included") $false)
  $applyDirectlySupported = [bool](Get-PropertyValue $safe @("apply_directly_supported") $false)
  $recommendedPath = Convert-ToOperatorProviderKeyPath (Get-PropertyValue $safe @("recommended_path", "operator_path") $null)
  $fingerprint = Convert-ToSafeText (Get-PropertyValue $safe @("fingerprint", "credential_fingerprint", "source_key_fingerprint", "secret_fingerprint") $null)
  if ([string]::IsNullOrWhiteSpace($fingerprint) -and $locatorHashes.Count -gt 0) {
    $fingerprint = "locator-sha256-v1:$($locatorHashes[0])"
  }
  $providerAlias = Convert-ToSafeText (Get-PropertyValue $safe @("provider_alias", "provider_code", "provider") $null)
  $channelAlias = Convert-ToSafeText (Get-PropertyValue $safe @("channel_alias", "channel_name", "channel") $channelSourceId)
  if ($null -ne $binding) {
    if ([string]::IsNullOrWhiteSpace($providerAlias)) {
      $providerAlias = Convert-ToSafeText (Get-PropertyValue $binding @("provider_code", "internal_provider_id") $null)
    }
    if ([string]::IsNullOrWhiteSpace($channelAlias)) {
      $channelAlias = Convert-ToSafeText (Get-PropertyValue $binding @("channel_name", "channel_source_id", "internal_channel_id") $channelSourceId)
    }
  }

  return [ordered]@{
    schema_version = "importer.provider-key-operator-sidecar.v1"
    handoff_id = $handoffId
    channel_source_id = if ([string]::IsNullOrWhiteSpace($channelSourceId)) { $null } else { $channelSourceId }
    key_alias = $keyAlias
    provider_alias = if ([string]::IsNullOrWhiteSpace($providerAlias)) { $null } else { $providerAlias }
    channel_alias = if ([string]::IsNullOrWhiteSpace($channelAlias)) { $null } else { $channelAlias }
    fingerprint = if ([string]::IsNullOrWhiteSpace($fingerprint)) { $null } else { $fingerprint }
    credential_material_present = $materialPresent
    credential_origin = Convert-ToSafeText (Get-PropertyValue $safe @("credential_origin", "credential_source") $(if ($materialPresent) { "unknown_redacted" } else { "missing" }))
    credential_locator_redacted = Convert-ToSafeText (Get-PropertyValue $safe @("credential_locator_redacted", "credential_ref_redacted", "locator_redacted") $null)
    credential_locator_hashes = @(Convert-ToObjectArray $locatorHashes)
    raw_material_exported = $rawMaterialExported
    provider_key_material_included = $materialIncluded
    requires_operator_entry = [bool](Get-PropertyValue $safe @("requires_operator_entry") $true)
    required_manual_secret_entry = $true
    recommended_path = $recommendedPath
    required_operator_path = "POST /admin/provider-keys"
    apply_directly_supported = $applyDirectlySupported
    apply_mode = "sidecar_only"
    raw_secret_in_artifact = $false
    secret_material_in_artifact = $false
    manual_secret_entry_contract = [ordered]@{
      schema_version = "importer.provider-key-manual-secret-entry.v1"
      required_manual_secret_entry = $true
      one_time_entry_only = $true
      raw_secret_source = "operator_out_of_band"
      entry_path = "POST /admin/provider-keys"
      allowed_prefill_fields = @("provider_id", "channel_id", "alias", "status", "imported_handoff_id", "source_channel_id")
      forbidden_prefill_fields = @("credential_value", "provider_credential", "user_credential", "credential_header", "encrypted_secret")
    }
    rotation_next_step = "After manual entry succeeds, use provider-key rotate flow for future changes; importer artifacts must keep only alias and fingerprint evidence."
    recovery_next_step = "If probe/readback fails after manual entry, run provider-key recovery probe from the Control Plane and re-enter the secret out-of-band if required."
    target_table = "provider_keys"
    target_secret_columns = @("encrypted_secret", "secret_fingerprint")
    binding_status = $bindingStatus
    source_channel_binding = $binding
    source_reports = @(Convert-ToObjectArray $sourceReports)
  }
}

function Test-ProviderKeyHandoffShape {
  param([object[]]$Handoffs)

  $errors = New-Object System.Collections.Generic.List[object]
  $warnings = New-Object System.Collections.Generic.List[object]
  foreach ($handoff in $Handoffs) {
    $handoffId = Convert-ToSafeText (Get-PropertyValue $handoff @("handoff_id") $null)
    $keyAlias = Convert-ToSafeText (Get-PropertyValue $handoff @("key_alias") $null)
    $channelSourceId = Convert-ToSafeText (Get-PropertyValue $handoff @("channel_source_id") $null)
    $bindingStatus = Convert-ToSafeText (Get-PropertyValue $handoff @("binding_status") "unknown")

    if ([string]::IsNullOrWhiteSpace($handoffId)) {
      $errors.Add([ordered]@{ key_alias = $keyAlias; reason = "missing_handoff_id" }) | Out-Null
    }
    if ([string]::IsNullOrWhiteSpace($keyAlias)) {
      $errors.Add([ordered]@{ handoff_id = $handoffId; reason = "missing_key_alias" }) | Out-Null
    }
    if ([string](Get-PropertyValue $handoff @("schema_version") $null) -ne "importer.provider-key-operator-sidecar.v1") {
      $errors.Add([ordered]@{ handoff_id = $handoffId; channel_source_id = $channelSourceId; key_alias = $keyAlias; reason = "missing_operator_sidecar_schema" }) | Out-Null
    }
    if (-not [bool](Get-PropertyValue $handoff @("required_manual_secret_entry") $false)) {
      $errors.Add([ordered]@{ handoff_id = $handoffId; channel_source_id = $channelSourceId; key_alias = $keyAlias; reason = "manual_secret_entry_not_required" }) | Out-Null
    }
    if ([string]::IsNullOrWhiteSpace([string](Get-PropertyValue $handoff @("fingerprint") $null))) {
      $errors.Add([ordered]@{ handoff_id = $handoffId; channel_source_id = $channelSourceId; key_alias = $keyAlias; reason = "missing_non_secret_fingerprint" }) | Out-Null
    }
    if ([string]::IsNullOrWhiteSpace([string](Get-PropertyValue $handoff @("provider_alias") $null))) {
      $warnings.Add([ordered]@{ handoff_id = $handoffId; channel_source_id = $channelSourceId; key_alias = $keyAlias; reason = "missing_provider_alias" }) | Out-Null
    }
    if ([string]::IsNullOrWhiteSpace([string](Get-PropertyValue $handoff @("channel_alias") $null))) {
      $warnings.Add([ordered]@{ handoff_id = $handoffId; channel_source_id = $channelSourceId; key_alias = $keyAlias; reason = "missing_channel_alias" }) | Out-Null
    }
    if ([bool](Get-PropertyValue $handoff @("raw_material_exported") $false)) {
      $errors.Add([ordered]@{ handoff_id = $handoffId; channel_source_id = $channelSourceId; key_alias = $keyAlias; reason = "raw_material_exported" }) | Out-Null
    }
    if ([bool](Get-PropertyValue $handoff @("provider_key_material_included") $false)) {
      $errors.Add([ordered]@{ handoff_id = $handoffId; channel_source_id = $channelSourceId; key_alias = $keyAlias; reason = "provider_key_material_included" }) | Out-Null
    }
    if ([bool](Get-PropertyValue $handoff @("raw_secret_in_artifact") $false) -or [bool](Get-PropertyValue $handoff @("secret_material_in_artifact") $false)) {
      $errors.Add([ordered]@{ handoff_id = $handoffId; channel_source_id = $channelSourceId; key_alias = $keyAlias; reason = "secret_material_in_artifact" }) | Out-Null
    }
    if ([bool](Get-PropertyValue $handoff @("apply_directly_supported") $false)) {
      $errors.Add([ordered]@{ handoff_id = $handoffId; channel_source_id = $channelSourceId; key_alias = $keyAlias; reason = "direct_apply_not_allowed" }) | Out-Null
    }
    if ([string]::IsNullOrWhiteSpace($channelSourceId)) {
      $warnings.Add([ordered]@{ handoff_id = $handoffId; key_alias = $keyAlias; reason = "missing_channel_source_id" }) | Out-Null
    } elseif ($bindingStatus -ne "bound") {
      $warnings.Add([ordered]@{ handoff_id = $handoffId; channel_source_id = $channelSourceId; key_alias = $keyAlias; reason = $bindingStatus }) | Out-Null
    }
    if (-not [bool](Get-PropertyValue $handoff @("credential_material_present") $false)) {
      $warnings.Add([ordered]@{ handoff_id = $handoffId; channel_source_id = $channelSourceId; key_alias = $keyAlias; reason = "credential_material_missing" }) | Out-Null
    }
  }

  return [ordered]@{
    errors = @(Convert-ToObjectArray $errors)
    warnings = @(Convert-ToObjectArray $warnings)
  }
}

function New-ConflictRef {
  param([object]$Conflict)

  return [ordered]@{
    type = Convert-ToSafeText (Get-PropertyValue $Conflict @("type") "unknown_conflict")
    severity = Convert-ToSafeText (Get-PropertyValue $Conflict @("severity") "error")
    key = Convert-ToSafeText (Get-PropertyValue $Conflict @("key") $null)
    description = Convert-ToSafeText (Get-PropertyValue $Conflict @("description") $null)
  }
}

function New-PlanOperation {
  param(
    [string]$Action,
    [string]$Kind,
    [string]$NaturalKey,
    [object]$After,
    [object]$Before = $null,
    [string]$Reason,
    [object[]]$ConflictRefs = @()
  )

  $safeAfter = Convert-ToSafeObject $After
  $safeBefore = Convert-ToSafeObject $Before
  $targetHash = Get-StableHash "$Kind|$NaturalKey" 16
  $target = [ordered]@{
    kind = $Kind
    natural_key = $NaturalKey
    natural_key_hash = $targetHash
  }

  $operationSeed = [ordered]@{
    action = $Action
    target = $target
    after = $safeAfter
    before = $safeBefore
  }
  $operationId = "op_$(Convert-ToSlug $Kind)_$(Get-StableHash $operationSeed 12)"
  $rollbackEntryId = "rb_$(Get-StableHash "$operationId|$Action|$Kind|$NaturalKey" 12)"
  $beforeImage = New-BeforeImageSnapshot $Action $safeBefore
  $afterPreviewHash = $null
  if ($null -ne $safeAfter) {
    $afterPreviewHash = Get-StableHash $safeAfter 32
  }

  if ($Action -eq "create") {
    $rollbackAction = "delete_created_object"
  } elseif ($Action -eq "update") {
    $rollbackAction = "restore_previous_object"
  } else {
    $rollbackAction = "none"
  }

  $rollback = [ordered]@{
    snapshot_entry_id = $rollbackEntryId
    operation_id = $operationId
    target = $target
    rollback_action = $rollbackAction
    before = $safeBefore
    before_image = $beforeImage
    after_preview = $safeAfter
    after_preview_hash = $afterPreviewHash
    snapshot_mode = "dry_run_shape_only"
  }

  return [ordered]@{
    operation_id = $operationId
    idempotency_key = "importer-apply-plan:v1:$(Convert-ToSlug $Kind):$targetHash"
    action = $Action
    target = $target
    reason = $Reason
    conflict_refs = @(Convert-ToObjectArray $ConflictRefs)
    before = $safeBefore
    after = $safeAfter
    rollback_snapshot_entry_id = $rollbackEntryId
    rollback = $rollback
  }
}

function Add-Operation {
  param(
    [System.Collections.Generic.List[object]]$Creates,
    [System.Collections.Generic.List[object]]$Updates,
    [System.Collections.Generic.List[object]]$Skips,
    [hashtable]$EmittedTargets,
    [object]$Operation
  )

  $targetKey = "$($Operation.target.kind)|$($Operation.target.natural_key)"
  if ($Operation.action -ne "skip" -and $EmittedTargets.ContainsKey($targetKey)) {
    $duplicate = New-PlanOperation "skip" $Operation.target.kind $Operation.target.natural_key $Operation.after $Operation.before "duplicate_plan_target" @()
    $Skips.Add($duplicate) | Out-Null
    return
  }

  if ($Operation.action -ne "skip") {
    $EmittedTargets[$targetKey] = $true
  }

  switch ($Operation.action) {
    "create" { $Creates.Add($Operation) | Out-Null }
    "update" { $Updates.Add($Operation) | Out-Null }
    default { $Skips.Add($Operation) | Out-Null }
  }
}

function Add-PreflightCheck {
  param(
    [System.Collections.Generic.List[object]]$Checks,
    [string]$Name,
    [string]$Status,
    [string]$Message,
    [object]$Details = $null
  )

  $Checks.Add([ordered]@{
      name = $Name
      status = $Status
      message = $Message
      details = Convert-ToSafeObject $Details
    }) | Out-Null
}

function Get-DuplicateValues {
  param([object[]]$Values)

  $duplicates = New-Object System.Collections.Generic.List[object]
  foreach ($group in ($Values | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Group-Object)) {
    if ($group.Count -gt 1) {
      $duplicates.Add([ordered]@{
          value = [string]$group.Name
          count = $group.Count
        }) | Out-Null
    }
  }

  return @(Convert-ToObjectArray $duplicates)
}

function New-IdempotencyManifest {
  param([object[]]$WriteOperations)

  $entries = New-Object System.Collections.Generic.List[object]
  foreach ($operation in @($WriteOperations | Sort-Object operation_id)) {
    $beforeHash = $null
    if ($null -ne $operation.before) {
      $beforeHash = Get-StableHash $operation.before 32
    }

    $afterHash = $null
    if ($null -ne $operation.after) {
      $afterHash = Get-StableHash $operation.after 32
    }

    $entries.Add([ordered]@{
        operation_id = $operation.operation_id
        idempotency_key = $operation.idempotency_key
        action = $operation.action
        target = $operation.target
        before_hash = $beforeHash
        after_hash = $afterHash
        rollback_snapshot_entry_id = $operation.rollback_snapshot_entry_id
        replay_policy = "same_idempotency_key_same_target_noop"
      }) | Out-Null
  }

  $manifestSeed = @($entries | ForEach-Object {
      "$($_.operation_id)|$($_.idempotency_key)|$($_.target.natural_key_hash)|$($_.action)|$($_.after_hash)"
    })

  return [ordered]@{
    schema_version = "importer.idempotency-manifest.v1"
    scope = "planned_write_operations"
    manifest_key = "importer-idempotency-manifest:v1:$(Get-StableHash $manifestSeed 24)"
    write_operation_count = $entries.Count
    entries = @(Convert-ToObjectArray $entries)
  }
}

function Test-RollbackSnapshotShape {
  param([object[]]$WriteOperations)

  $errors = New-Object System.Collections.Generic.List[object]
  $entryIds = New-Object System.Collections.Generic.List[object]
  foreach ($operation in $WriteOperations) {
    $rollback = $operation.rollback
    if ($null -eq $rollback) {
      $errors.Add("missing rollback entry for operation $($operation.operation_id)") | Out-Null
      continue
    }

    $entryIds.Add($rollback.snapshot_entry_id) | Out-Null

    if ([string]::IsNullOrWhiteSpace([string]$rollback.snapshot_entry_id)) {
      $errors.Add("rollback entry for $($operation.operation_id) is missing snapshot_entry_id") | Out-Null
    }
    if ($rollback.operation_id -ne $operation.operation_id) {
      $errors.Add("rollback entry operation_id mismatch for $($operation.operation_id)") | Out-Null
    }
    if ($rollback.target.natural_key_hash -ne $operation.target.natural_key_hash) {
      $errors.Add("rollback target mismatch for $($operation.operation_id)") | Out-Null
    }
    if ($null -eq $rollback.before_image) {
      $errors.Add("rollback entry for $($operation.operation_id) is missing before_image") | Out-Null
    } elseif ($operation.action -eq "create" -and [bool]$rollback.before_image.object_exists) {
      $errors.Add("create operation $($operation.operation_id) must have before_image.object_exists=false") | Out-Null
    } elseif ($operation.action -eq "update" -and -not [bool]$rollback.before_image.object_exists) {
      $errors.Add("update operation $($operation.operation_id) must have before_image.object_exists=true") | Out-Null
    }

    if ($operation.action -eq "create" -and $rollback.rollback_action -ne "delete_created_object") {
      $errors.Add("create operation $($operation.operation_id) must rollback by deleting created object") | Out-Null
    }
    if ($operation.action -eq "update" -and $rollback.rollback_action -ne "restore_previous_object") {
      $errors.Add("update operation $($operation.operation_id) must rollback by restoring previous object") | Out-Null
    }
    if ($operation.action -ne "skip" -and [string]::IsNullOrWhiteSpace([string]$rollback.after_preview_hash)) {
      $errors.Add("rollback entry for $($operation.operation_id) is missing after_preview_hash") | Out-Null
    }
  }

  foreach ($duplicate in (Get-DuplicateValues -Values @(Convert-ToObjectArray $entryIds))) {
    $errors.Add("duplicate rollback snapshot_entry_id: $($duplicate.value)") | Out-Null
  }

  return @(Convert-ToObjectArray $errors)
}

function Convert-ToCompactJson {
  param(
    [AllowNull()][object]$Value,
    [int]$Depth = 64
  )

  if ($null -eq $Value) {
    return "null"
  }

  return ($Value | ConvertTo-Json -Depth $Depth -Compress)
}

function Convert-ToCanonicalCapabilitiesObject {
  param([AllowNull()][object]$Capabilities)

  $safe = Convert-ToSafeObject $Capabilities
  if ($null -eq $safe) {
    return [ordered]@{}
  }

  if ($safe -is [System.Collections.IDictionary]) {
    return $safe
  }

  if ($safe -is [System.Array]) {
    $capabilityObject = [ordered]@{}
    foreach ($capability in $safe) {
      $name = Convert-ToSafeText $capability $null
      if (-not [string]::IsNullOrWhiteSpace($name)) {
        $capabilityObject[$name] = $true
      }
    }
    return $capabilityObject
  }

  return [ordered]@{
    value = $safe
  }
}

function Get-BooleanField {
  param(
    [AllowNull()][object]$Object,
    [string[]]$Names,
    [bool]$Default
  )

  $value = Get-PropertyValue $Object $Names $null
  if ($null -eq $value) {
    return $Default
  }

  return [bool]$value
}

function Get-CanonicalCapabilityFlag {
  param(
    [object]$After,
    [string]$Name,
    [bool]$Default
  )

  $direct = Get-PropertyValue $After @($Name) $null
  if ($null -ne $direct) {
    return [bool]$direct
  }

  $flags = Get-PropertyValue $After @("capability_flags", "capabilities_flags") $null
  return Get-BooleanField $flags @($Name) $Default
}

function Get-NullableIntField {
  param(
    [object]$Object,
    [string[]]$Names
  )

  $value = Get-PropertyValue $Object $Names $null
  if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
    return $null
  }

  return [int]$value
}

function Get-NullableDecimalField {
  param(
    [object]$Object,
    [string[]]$Names
  )

  $value = Get-PropertyValue $Object $Names $null
  if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
    return $null
  }

  return [decimal]$value
}

function Normalize-ProviderStatus {
  param([AllowNull()][object]$Status)

  $text = Convert-ToSafeText $Status "enabled"
  switch ($text.ToLowerInvariant()) {
    "active" { return "enabled" }
    "enabled" { return "enabled" }
    "true" { return "enabled" }
    "1" { return "enabled" }
    "disabled" { return "disabled" }
    "inactive" { return "disabled" }
    "false" { return "disabled" }
    "0" { return "disabled" }
    "deleted" { return "deleted" }
    default { return "enabled" }
  }
}

function Normalize-ChannelStatus {
  param([AllowNull()][object]$Status)

  $text = Convert-ToSafeText $Status "enabled"
  switch ($text.ToLowerInvariant()) {
    "active" { return "enabled" }
    "enabled" { return "enabled" }
    "true" { return "enabled" }
    "1" { return "enabled" }
    "disabled" { return "disabled" }
    "inactive" { return "disabled" }
    "false" { return "disabled" }
    "0" { return "disabled" }
    "degraded" { return "degraded" }
    "cooldown" { return "cooldown" }
    "deleted" { return "deleted" }
    default { return "enabled" }
  }
}

function Normalize-ModelAssociationStatus {
  param(
    [AllowNull()][object]$Status,
    [AllowNull()][object]$Enabled = $null
  )

  if ($null -ne $Enabled) {
    return $(if ([bool]$Enabled) { "enabled" } else { "disabled" })
  }

  $text = Convert-ToSafeText $Status "enabled"
  switch ($text.ToLowerInvariant()) {
    "active" { return "enabled" }
    "enabled" { return "enabled" }
    "true" { return "enabled" }
    "1" { return "enabled" }
    "disabled" { return "disabled" }
    "inactive" { return "disabled" }
    "false" { return "disabled" }
    "0" { return "disabled" }
    "deleted" { return "deleted" }
    default { return "enabled" }
  }
}

function Get-SqlExecutorSupport {
  param([object]$Operation)

  $kind = Convert-ToSafeText (Get-PropertyValue $Operation.target @("kind") "unknown")
  switch ($kind) {
    "provider" {
      $providerCode = Convert-ToSafeText (Get-PropertyValue $Operation.after @("provider_code", "code", "provider", "provider_id", "id") $null)
      $name = Convert-ToSafeText (Get-PropertyValue $Operation.after @("name", "display_name") $providerCode)
      if ([string]::IsNullOrWhiteSpace($providerCode) -or [string]::IsNullOrWhiteSpace($name)) {
        return [ordered]@{
          operation_id = $Operation.operation_id
          target = $Operation.target
          supported = $false
          adapter = "providers_upsert_v1"
          reason = "provider SQL adapter requires provider_code and name"
        }
      }

      return [ordered]@{
        operation_id = $Operation.operation_id
        target = $Operation.target
        supported = $true
        adapter = "providers_upsert_v1"
        reason = "target_schema_supported_for_provider_upsert"
      }
    }
    "channel" {
      $providerCode = Convert-ToSafeText (Get-PropertyValue $Operation.after @("provider_code", "provider", "provider_id") $null)
      $internalChannelId = Convert-ToSafeText (Get-PropertyValue $Operation.after @("internal_channel_id", "channel_id", "id") $null)
      $channelName = Convert-ToSafeText (Get-PropertyValue $Operation.after @("name", "channel_name", "display_name") $null)
      $endpoint = Convert-ToSafeText (Get-PropertyValue $Operation.after @("endpoint", "base_url", "baseUrl", "url") $null)
      if ([string]::IsNullOrWhiteSpace($providerCode) -or [string]::IsNullOrWhiteSpace($internalChannelId) -or [string]::IsNullOrWhiteSpace($channelName) -or [string]::IsNullOrWhiteSpace($endpoint)) {
        return [ordered]@{
          operation_id = $Operation.operation_id
          target = $Operation.target
          supported = $false
          adapter = "channels_upsert_v1"
          reason = "channel SQL adapter requires provider_code, internal_channel_id, name, and endpoint"
        }
      }

      return [ordered]@{
        operation_id = $Operation.operation_id
        target = $Operation.target
        supported = $true
        adapter = "channels_upsert_v1"
        reason = "target_schema_supported_for_channel_upsert"
      }
    }
    "canonical_model" {
      return [ordered]@{
        operation_id = $Operation.operation_id
        target = $Operation.target
        supported = $true
        adapter = "canonical_models_upsert_v1"
        reason = "target_schema_supported"
      }
    }
    "model_association" {
      $after = $Operation.after
      $associationType = Convert-ToSafeText (Get-PropertyValue $after @("association_type") "explicit_channel")
      $canonicalModelKey = Convert-ToSafeText (Get-PropertyValue $after @("canonical_model_key", "canonical_model", "model_key") $null)
      $internalChannelId = Convert-ToSafeText (Get-PropertyValue $after @("internal_channel_id", "channel_id") $null)
      $upstreamModel = Convert-ToSafeText (Get-PropertyValue $after @("upstream_model_name", "upstream_model", "provider_model") $null)

      if ($associationType -ne "explicit_channel") {
        return [ordered]@{
          operation_id = $Operation.operation_id
          target = $Operation.target
          supported = $false
          adapter = "model_associations_pending_v1"
          reason = "this live SQL adapter only supports explicit_channel associations; channel_tag/model_pattern/global remain pending"
        }
      }

      if ([string]::IsNullOrWhiteSpace($canonicalModelKey) -or [string]::IsNullOrWhiteSpace($internalChannelId)) {
        return [ordered]@{
          operation_id = $Operation.operation_id
          target = $Operation.target
          supported = $false
          adapter = "model_associations_pending_v1"
          reason = "model_association SQL adapter requires canonical_model_key and source-channel binding internal_channel_id"
        }
      }

      return [ordered]@{
        operation_id = $Operation.operation_id
        target = $Operation.target
        supported = $true
        adapter = "model_associations_upsert_v1"
        reason = "target_schema_supported_for_bound_explicit_channel_association"
        constraints = [ordered]@{
          association_type = $associationType
          canonical_model_key_required = $true
          internal_channel_id_required = $true
          upstream_model_name_present = (-not [string]::IsNullOrWhiteSpace($upstreamModel))
        }
      }
    }
    "channel_mapping_entry" {
      $requestedModel = Convert-ToSafeText (Get-PropertyValue $Operation.after @("requested_model", "client_model", "source_model") $null)
      $upstreamModel = Convert-ToSafeText (Get-PropertyValue $Operation.after @("upstream_model_name", "upstream_model", "provider_model") $requestedModel)
      $mappingPolicy = Convert-ToSafeText (Get-PropertyValue $Operation.after @("mapping_policy") $null)
      if ([string]::IsNullOrWhiteSpace($mappingPolicy)) {
        $mappingPolicy = if ($requestedModel -eq $upstreamModel) { "identity" } else { "explicit_upstream_name" }
      }

      if ([string]::IsNullOrWhiteSpace($requestedModel) -or [string]::IsNullOrWhiteSpace($upstreamModel)) {
        return [ordered]@{
          operation_id = $Operation.operation_id
          target = $Operation.target
          supported = $false
          adapter = "channel_model_mappings_jsonb_merge_v1"
          reason = "channel mapping SQL adapter requires requested_model and upstream_model_name"
        }
      }

      if (@("identity", "explicit_upstream_name") -notcontains $mappingPolicy) {
        return [ordered]@{
          operation_id = $Operation.operation_id
          target = $Operation.target
          supported = $false
          adapter = "channel_model_mappings_jsonb_merge_v1"
          reason = "channel mapping SQL adapter only supports identity or explicit_upstream_name mapping_policy"
        }
      }

      return [ordered]@{
        operation_id = $Operation.operation_id
        target = $Operation.target
        supported = $true
        adapter = "channel_model_mappings_jsonb_merge_v1"
        reason = "target_schema_supported_for_simple_model_mapping_merge"
      }
    }
    default {
      return [ordered]@{
        operation_id = $Operation.operation_id
        target = $Operation.target
        supported = $false
        adapter = "unsupported"
        reason = "no sql executor adapter is registered for this target kind"
      }
    }
  }
}

function New-PostgreSqlStatement {
  param(
    [string]$Phase,
    [string]$OperationId,
    [string]$Sql,
    [object]$Parameters
  )

  return [ordered]@{
    phase = $Phase
    operation_id = $OperationId
    parameter_style = "named"
    sql = $Sql.Trim()
    parameters = Convert-ToSafeObject $Parameters
  }
}

function New-PostgreSqlProviderOperationPlan {
  param(
    [object]$Operation,
    [string]$TenantId
  )

  $after = $Operation.after
  $providerId = Convert-ToSafeText (Get-PropertyValue $after @("internal_provider_id", "provider_id", "id") $null)
  $providerCode = Convert-ToSafeText (Get-PropertyValue $after @("provider_code", "code", "provider") $null)
  $name = Convert-ToSafeText (Get-PropertyValue $after @("name", "display_name") $providerCode)
  $status = Normalize-ProviderStatus (Get-PropertyValue $after @("status") "enabled")
  $metadata = Convert-ToSafeObject (Get-PropertyValue $after @("metadata") ([ordered]@{}))

  $parameters = [ordered]@{
    tenant_id = $TenantId
    operation_id = $Operation.operation_id
    idempotency_key = $Operation.idempotency_key
    rollback_snapshot_entry_id = $Operation.rollback_snapshot_entry_id
    internal_provider_id = $providerId
    provider_code = $providerCode
    name = $name
    status = $status
    metadata_json = Convert-ToCompactJson $metadata 32
    after_hash = Get-StableHash $Operation.after 32
  }

  $beforeSql = @'
select to_jsonb(p.*) as before_image
from providers p
where p.tenant_id = cast(:tenant_id as uuid)
  and p.code = :provider_code
  and p.deleted_at is null
for update;
'@

  $applySql = @'
insert into providers (
  id, tenant_id, code, name, status, metadata
)
values (
  cast(:internal_provider_id as uuid), cast(:tenant_id as uuid), :provider_code, :name,
  :status, cast(:metadata_json as jsonb)
)
on conflict (tenant_id, code) do update
set name = excluded.name,
    status = excluded.status,
    metadata = excluded.metadata,
    updated_at = now(),
    deleted_at = null
returning to_jsonb(providers.*) as after_image;
'@

  return [ordered]@{
    operation_id = $Operation.operation_id
    idempotency_key = $Operation.idempotency_key
    action = $Operation.action
    target = $Operation.target
    adapter = "providers_upsert_v1"
    supported = $true
    replay_policy = @(
      "capture provider before-image by tenant_id/provider_code",
      "insert provider with deterministic id when missing",
      "update provider name/status/metadata when natural key exists",
      "provider key material is not read or written by this adapter"
    )
    rollback_snapshot_entry_id = $Operation.rollback_snapshot_entry_id
    before_image_capture = [ordered]@{
      required = $true
      target_table = "providers"
      natural_key = "tenant_id, provider_code"
      operation_id = $Operation.operation_id
      idempotency_key = $Operation.idempotency_key
      rollback_snapshot_entry_id = $Operation.rollback_snapshot_entry_id
    }
    statements = @(
      New-PostgreSqlStatement "capture_before_image" $Operation.operation_id $beforeSql $parameters
      New-PostgreSqlStatement "apply_upsert" $Operation.operation_id $applySql $parameters
    )
  }
}

function New-PostgreSqlChannelOperationPlan {
  param(
    [object]$Operation,
    [string]$TenantId
  )

  $after = $Operation.after
  $channelSourceId = Convert-ToSafeText (Get-PropertyValue $after @("channel_source_id", "source_channel_id") $null)
  $providerCode = Convert-ToSafeText (Get-PropertyValue $after @("provider_code", "provider", "provider_id") $null)
  $internalProviderId = Convert-ToSafeText (Get-PropertyValue $after @("internal_provider_id", "provider_id") $null)
  $internalChannelId = Convert-ToSafeText (Get-PropertyValue $after @("internal_channel_id", "channel_id", "id") $null)
  $channelName = Convert-ToSafeText (Get-PropertyValue $after @("name", "channel_name", "display_name") $null)
  $endpoint = Convert-ToSafeText (Get-PropertyValue $after @("endpoint", "base_url", "baseUrl", "url") $null)
  $protocolMode = Convert-ToSafeText (Get-PropertyValue $after @("protocol_mode", "protocol") "openai_compatible")
  $status = Normalize-ChannelStatus (Get-PropertyValue $after @("status") "enabled")
  $region = Convert-ToSafeText (Get-PropertyValue $after @("region") $null)
  $priority = Get-NullableIntField $after @("priority")
  if ($null -eq $priority) { $priority = 100 }
  $weight = Get-NullableIntField $after @("weight")
  if ($null -eq $weight) { $weight = 100 }
  $tags = Convert-ToSafeObject (Get-PropertyValue $after @("tags") @())
  $modelMappings = Convert-ToSafeObject (Get-PropertyValue $after @("model_mappings", "modelMappings") ([ordered]@{}))
  $requestOverrides = Convert-ToSafeObject (Get-PropertyValue $after @("request_overrides", "requestOverrides") @())
  $timeoutPolicy = Convert-ToSafeObject (Get-PropertyValue $after @("timeout_policy", "timeoutPolicy") ([ordered]@{}))
  $probePolicy = Convert-ToSafeObject (Get-PropertyValue $after @("probe_policy", "probePolicy") ([ordered]@{}))
  $healthScore = Get-NullableDecimalField $after @("health_score", "healthScore")
  if ($null -eq $healthScore) { $healthScore = [decimal]1.0 }

  $parameters = [ordered]@{
    tenant_id = $TenantId
    operation_id = $Operation.operation_id
    idempotency_key = $Operation.idempotency_key
    rollback_snapshot_entry_id = $Operation.rollback_snapshot_entry_id
    channel_source_id = $channelSourceId
    provider_code = $providerCode
    internal_provider_id = $internalProviderId
    internal_channel_id = $internalChannelId
    channel_name = $channelName
    endpoint = $endpoint
    protocol_mode = $protocolMode
    status = $status
    region = $region
    priority = $priority
    weight = $weight
    tags_json = Convert-ToCompactJson $tags 32
    model_mappings_json = Convert-ToCompactJson $modelMappings 32
    request_overrides_json = Convert-ToCompactJson $requestOverrides 32
    timeout_policy_json = Convert-ToCompactJson $timeoutPolicy 32
    probe_policy_json = Convert-ToCompactJson $probePolicy 32
    health_score = $healthScore
    after_hash = Get-StableHash $Operation.after 32
  }

  $beforeSql = @'
select to_jsonb(ch.*) as before_image
from channels ch
join providers p
  on p.tenant_id = ch.tenant_id
 and p.id = ch.provider_id
where ch.tenant_id = cast(:tenant_id as uuid)
  and p.code = :provider_code
  and ch.name = :channel_name
  and ch.deleted_at is null
  and p.deleted_at is null
for update;
'@

  $applySql = @'
with provider as (
  select id
  from providers
  where tenant_id = cast(:tenant_id as uuid)
    and code = :provider_code
    and deleted_at is null
  limit 1
)
insert into channels (
  id, tenant_id, provider_id, name, endpoint, protocol_mode, status,
  region, priority, weight, tags, model_mappings, request_overrides,
  timeout_policy, probe_policy, health_score
)
select
  cast(:internal_channel_id as uuid), cast(:tenant_id as uuid), provider.id, :channel_name,
  :endpoint, :protocol_mode, :status, :region, :priority, :weight,
  cast(:tags_json as jsonb), cast(:model_mappings_json as jsonb),
  cast(:request_overrides_json as jsonb), cast(:timeout_policy_json as jsonb),
  cast(:probe_policy_json as jsonb), cast(:health_score as numeric)
from provider
on conflict (tenant_id, provider_id, name) do update
set endpoint = excluded.endpoint,
    protocol_mode = excluded.protocol_mode,
    status = excluded.status,
    region = excluded.region,
    priority = excluded.priority,
    weight = excluded.weight,
    tags = excluded.tags,
    model_mappings = excluded.model_mappings,
    request_overrides = excluded.request_overrides,
    timeout_policy = excluded.timeout_policy,
    probe_policy = excluded.probe_policy,
    health_score = excluded.health_score,
    updated_at = now(),
    deleted_at = null
returning to_jsonb(channels.*) as after_image;
'@

  return [ordered]@{
    operation_id = $Operation.operation_id
    idempotency_key = $Operation.idempotency_key
    action = $Operation.action
    target = $Operation.target
    adapter = "channels_upsert_v1"
    supported = $true
    replay_policy = @(
      "provider must exist by tenant_id/provider_code before channel upsert",
      "capture channel before-image by tenant_id/provider_code/channel_name",
      "insert channel with deterministic id when missing",
      "provider key material is not read or written by this adapter"
    )
    rollback_snapshot_entry_id = $Operation.rollback_snapshot_entry_id
    before_image_capture = [ordered]@{
      required = $true
      target_table = "channels"
      natural_key = "tenant_id, provider_code, channel_name"
      operation_id = $Operation.operation_id
      idempotency_key = $Operation.idempotency_key
      rollback_snapshot_entry_id = $Operation.rollback_snapshot_entry_id
    }
    statements = @(
      New-PostgreSqlStatement "capture_before_image" $Operation.operation_id $beforeSql $parameters
      New-PostgreSqlStatement "apply_upsert" $Operation.operation_id $applySql $parameters
    )
  }
}

function New-PostgreSqlCanonicalModelOperationPlan {
  param(
    [object]$Operation,
    [string]$TenantId
  )

  $after = $Operation.after
  $modelKey = Convert-ToSafeText (Get-PropertyValue $after @("model_key", "canonical_model_key", "model", "key", "name", "id") $null)
  $displayName = Convert-ToSafeText (Get-PropertyValue $after @("display_name", "name", "model_key", "canonical_model_key") $modelKey)
  $family = Convert-ToSafeText (Get-PropertyValue $after @("family") $null)
  $capabilities = Convert-ToCanonicalCapabilitiesObject (Get-PropertyValue $after @("capabilities") ([ordered]@{}))
  $contextLength = Get-NullableIntField $after @("context_length", "contextLength")
  $maxOutputTokens = Get-NullableIntField $after @("max_output_tokens", "maxOutputTokens")
  $defaultPriceBookId = Convert-ToSafeText (Get-PropertyValue $after @("default_price_book_id", "defaultPriceBookId") $null)
  $visibility = Convert-ToSafeText (Get-PropertyValue $after @("visibility") "internal")
  $status = Convert-ToSafeText (Get-PropertyValue $after @("status") "active")

  $parameters = [ordered]@{
    tenant_id = $TenantId
    operation_id = $Operation.operation_id
    idempotency_key = $Operation.idempotency_key
    rollback_snapshot_entry_id = $Operation.rollback_snapshot_entry_id
    model_key = $modelKey
    display_name = $displayName
    family = $family
    capabilities_json = Convert-ToCompactJson $capabilities 32
    context_length = $contextLength
    max_output_tokens = $maxOutputTokens
    supports_stream = Get-CanonicalCapabilityFlag $after "supports_stream" $true
    supports_tools = Get-CanonicalCapabilityFlag $after "supports_tools" $false
    supports_vision = Get-CanonicalCapabilityFlag $after "supports_vision" $false
    supports_audio = Get-CanonicalCapabilityFlag $after "supports_audio" $false
    supports_reasoning = Get-CanonicalCapabilityFlag $after "supports_reasoning" $false
    default_price_book_id = $defaultPriceBookId
    visibility = $visibility
    status = $status
    after_hash = Get-StableHash $Operation.after 32
  }

  $beforeSql = @'
select to_jsonb(cm.*) as before_image
from canonical_models cm
where cm.tenant_id = cast(:tenant_id as uuid)
  and cm.model_key = :model_key
  and cm.deleted_at is null
for update;
'@

  $applySql = @'
insert into canonical_models (
  tenant_id, model_key, display_name, family, capabilities, context_length,
  max_output_tokens, supports_stream, supports_tools, supports_vision,
  supports_audio, supports_reasoning, default_price_book_id, visibility, status
)
values (
  cast(:tenant_id as uuid), :model_key, :display_name, :family, cast(:capabilities_json as jsonb),
  :context_length, :max_output_tokens, :supports_stream, :supports_tools, :supports_vision,
  :supports_audio, :supports_reasoning, cast(nullif(:default_price_book_id, '') as uuid),
  :visibility, :status
)
on conflict (tenant_id, model_key) do update
set display_name = excluded.display_name,
    family = excluded.family,
    capabilities = excluded.capabilities,
    context_length = excluded.context_length,
    max_output_tokens = excluded.max_output_tokens,
    supports_stream = excluded.supports_stream,
    supports_tools = excluded.supports_tools,
    supports_vision = excluded.supports_vision,
    supports_audio = excluded.supports_audio,
    supports_reasoning = excluded.supports_reasoning,
    default_price_book_id = excluded.default_price_book_id,
    visibility = excluded.visibility,
    status = excluded.status,
    updated_at = now(),
    deleted_at = null
returning to_jsonb(canonical_models.*) as after_image;
'@

  return [ordered]@{
    operation_id = $Operation.operation_id
    idempotency_key = $Operation.idempotency_key
    action = $Operation.action
    target = $Operation.target
    adapter = "canonical_models_upsert_v1"
    supported = $true
    replay_policy = @(
      "capture_before_image_for_update_before_mutation",
      "if captured before-image hash equals after_hash, journal as skipped",
      "if no row exists, insert",
      "if row exists and differs, update by natural key"
    )
    rollback_snapshot_entry_id = $Operation.rollback_snapshot_entry_id
    before_image_capture = [ordered]@{
      required = $true
      target_table = "canonical_models"
      natural_key = "tenant_id, model_key"
      operation_id = $Operation.operation_id
      idempotency_key = $Operation.idempotency_key
      rollback_snapshot_entry_id = $Operation.rollback_snapshot_entry_id
    }
    statements = @(
      New-PostgreSqlStatement "capture_before_image" $Operation.operation_id $beforeSql $parameters
      New-PostgreSqlStatement "apply_upsert" $Operation.operation_id $applySql $parameters
    )
  }
}

function New-PostgreSqlChannelMappingEntryOperationPlan {
  param(
    [object]$Operation,
    [string]$TenantId
  )

  $after = $Operation.after
  $channelSourceId = Convert-ToSafeText (Get-PropertyValue $after @("channel_source_id", "source_channel_id") $null)
  $internalChannelId = Convert-ToSafeText (Get-PropertyValue $after @("internal_channel_id", "channel_id") $null)
  $requestedModel = Convert-ToSafeText (Get-PropertyValue $after @("requested_model", "client_model", "source_model") $null)
  $upstreamModel = Convert-ToSafeText (Get-PropertyValue $after @("upstream_model_name", "upstream_model", "provider_model") $requestedModel)
  $mappingPolicy = Convert-ToSafeText (Get-PropertyValue $after @("mapping_policy") $null)
  if ([string]::IsNullOrWhiteSpace($mappingPolicy)) {
    $mappingPolicy = if ($requestedModel -eq $upstreamModel) { "identity" } else { "explicit_upstream_name" }
  }

  $mappingPatch = [ordered]@{}
  if (-not [string]::IsNullOrWhiteSpace($requestedModel)) {
    $mappingPatch[$requestedModel] = $upstreamModel
  }

  $parameters = [ordered]@{
    tenant_id = $TenantId
    operation_id = $Operation.operation_id
    idempotency_key = $Operation.idempotency_key
    rollback_snapshot_entry_id = $Operation.rollback_snapshot_entry_id
    channel_source_id = $channelSourceId
    internal_channel_id = $internalChannelId
    requested_model = $requestedModel
    upstream_model_name = $upstreamModel
    mapping_policy = $mappingPolicy
    mapping_patch_json = Convert-ToCompactJson $mappingPatch 16
    after_hash = Get-StableHash $Operation.after 32
  }

  $beforeSql = @'
select jsonb_build_object(
  'channel', to_jsonb(ch.*),
  'existing_model_mappings', coalesce(ch.model_mappings, '{}'::jsonb),
  'requested_model', :requested_model,
  'existing_upstream_model_name', coalesce(ch.model_mappings, '{}'::jsonb) ->> :requested_model
) as before_image
from channels ch
where ch.tenant_id = cast(:tenant_id as uuid)
  and ch.id = cast(:internal_channel_id as uuid)
  and ch.deleted_at is null
for update;
'@

  $applySql = @'
update channels ch
set model_mappings = coalesce(ch.model_mappings, '{}'::jsonb) || cast(:mapping_patch_json as jsonb),
    updated_at = now()
where ch.tenant_id = cast(:tenant_id as uuid)
  and ch.id = cast(:internal_channel_id as uuid)
  and ch.deleted_at is null
returning to_jsonb(ch.*) as after_image;
'@

  return [ordered]@{
    operation_id = $Operation.operation_id
    idempotency_key = $Operation.idempotency_key
    action = $Operation.action
    target = $Operation.target
    adapter = "channel_model_mappings_jsonb_merge_v1"
    supported = $true
    replay_policy = @(
      "source channel binding preflight must provide internal_channel_id",
      "capture channel model_mappings before mutation with FOR UPDATE",
      "merge requested_model to upstream_model_name into channels.model_mappings",
      "future live runner should skip when existing requested_model already maps to upstream_model_name"
    )
    rollback_snapshot_entry_id = $Operation.rollback_snapshot_entry_id
    before_image_capture = [ordered]@{
      required = $true
      target_table = "channels"
      natural_key = "tenant_id, internal_channel_id, requested_model"
      operation_id = $Operation.operation_id
      idempotency_key = $Operation.idempotency_key
      rollback_snapshot_entry_id = $Operation.rollback_snapshot_entry_id
    }
    statements = @(
      New-PostgreSqlStatement "capture_before_image" $Operation.operation_id $beforeSql $parameters
      New-PostgreSqlStatement "apply_patch" $Operation.operation_id $applySql $parameters
    )
  }
}

function New-PostgreSqlModelAssociationOperationPlan {
  param(
    [object]$Operation,
    [string]$TenantId
  )

  $after = $Operation.after
  $canonicalModelKey = Convert-ToSafeText (Get-PropertyValue $after @("canonical_model_key", "canonical_model", "model_key") $null)
  $associationType = Convert-ToSafeText (Get-PropertyValue $after @("association_type") "explicit_channel")
  $channelSourceId = Convert-ToSafeText (Get-PropertyValue $after @("channel_source_id", "source_channel_id") $null)
  $internalChannelId = Convert-ToSafeText (Get-PropertyValue $after @("internal_channel_id", "channel_id") $null)
  $upstreamModel = Convert-ToSafeText (Get-PropertyValue $after @("upstream_model_name", "upstream_model", "provider_model") $null)
  $priority = Get-NullableIntField $after @("priority")
  if ($null -eq $priority) { $priority = 100 }
  $conditions = Convert-ToSafeObject (Get-PropertyValue $after @("conditions") ([ordered]@{}))
  $fallbackAllowed = Get-BooleanField $after @("fallback_allowed") $true
  $canaryPercent = Convert-ToSafeText (Get-PropertyValue $after @("canary_percent", "canaryPercent") "100")
  $status = Normalize-ModelAssociationStatus `
    -Status (Get-PropertyValue $after @("status") $null) `
    -Enabled (Get-PropertyValue $after @("enabled") $null)

  $parameters = [ordered]@{
    tenant_id = $TenantId
    operation_id = $Operation.operation_id
    idempotency_key = $Operation.idempotency_key
    rollback_snapshot_entry_id = $Operation.rollback_snapshot_entry_id
    canonical_model_key = $canonicalModelKey
    association_type = $associationType
    channel_source_id = $channelSourceId
    internal_channel_id = $internalChannelId
    upstream_model_name = $upstreamModel
    priority = $priority
    conditions_json = Convert-ToCompactJson $conditions 32
    fallback_allowed = $fallbackAllowed
    canary_percent = $canaryPercent
    status = $status
    after_hash = Get-StableHash $Operation.after 32
  }

  $beforeSql = @'
select to_jsonb(ma.*) as before_image
from model_associations ma
join canonical_models cm
  on cm.tenant_id = ma.tenant_id
 and cm.id = ma.canonical_model_id
where ma.tenant_id = cast(:tenant_id as uuid)
  and cm.model_key = :canonical_model_key
  and ma.association_type = 'explicit_channel'
  and ma.channel_id = cast(:internal_channel_id as uuid)
  and coalesce(ma.upstream_model_name, '') = coalesce(:upstream_model_name, '')
  and ma.deleted_at is null
  and cm.deleted_at is null
for update;
'@

  $applySql = @'
with canonical as (
  select id
  from canonical_models
  where tenant_id = cast(:tenant_id as uuid)
    and model_key = :canonical_model_key
    and deleted_at is null
  limit 1
),
channel as (
  select id
  from channels
  where tenant_id = cast(:tenant_id as uuid)
    and id = cast(:internal_channel_id as uuid)
    and deleted_at is null
  limit 1
)
,
updated as (
  update model_associations ma
  set priority = :priority,
      conditions = cast(:conditions_json as jsonb),
      fallback_allowed = :fallback_allowed,
      canary_percent = cast(:canary_percent as numeric),
      status = :status,
      updated_at = now(),
      deleted_at = null
  from canonical, channel
  where ma.tenant_id = cast(:tenant_id as uuid)
    and ma.canonical_model_id = canonical.id
    and ma.association_type = 'explicit_channel'
    and ma.channel_id = channel.id
    and coalesce(ma.upstream_model_name, '') = coalesce(nullif(:upstream_model_name, ''), '')
    and ma.deleted_at is null
    and ma.status <> 'deleted'
  returning to_jsonb(ma.*) as after_image
),
inserted as (
  insert into model_associations (
    tenant_id, canonical_model_id, association_type, channel_id, channel_tag,
    model_pattern, upstream_model_name, priority, conditions, fallback_allowed,
    canary_percent, status
  )
  select
    cast(:tenant_id as uuid), canonical.id, 'explicit_channel', channel.id, null,
    null, nullif(:upstream_model_name, ''), :priority, cast(:conditions_json as jsonb),
    :fallback_allowed, cast(:canary_percent as numeric), :status
  from canonical, channel
  where not exists (select 1 from updated)
  returning to_jsonb(model_associations.*) as after_image
)
select after_image from updated
union all
select after_image from inserted;
'@

  return [ordered]@{
    operation_id = $Operation.operation_id
    idempotency_key = $Operation.idempotency_key
    action = $Operation.action
    target = $Operation.target
    adapter = "model_associations_upsert_v1"
    supported = $true
    replay_policy = @(
      "source channel binding preflight must provide internal_channel_id",
      "canonical model must already exist by canonical_model_key",
      "capture existing explicit_channel association before mutation with FOR UPDATE",
      "insert or update explicit_channel association by tenant/canonical/channel/upstream natural key",
      "provider key material is not read or written by this adapter"
    )
    rollback_snapshot_entry_id = $Operation.rollback_snapshot_entry_id
    before_image_capture = [ordered]@{
      required = $true
      target_table = "model_associations"
      natural_key = "tenant_id, canonical_model_key, internal_channel_id, upstream_model_name"
      operation_id = $Operation.operation_id
      idempotency_key = $Operation.idempotency_key
      rollback_snapshot_entry_id = $Operation.rollback_snapshot_entry_id
    }
    statements = @(
      New-PostgreSqlStatement "capture_before_image" $Operation.operation_id $beforeSql $parameters
      New-PostgreSqlStatement "apply_upsert" $Operation.operation_id $applySql $parameters
    )
  }
}

function New-PostgreSqlUnsupportedOperationPlan {
  param([object]$Support)

  return [ordered]@{
    operation_id = $Support.operation_id
    target = $Support.target
    adapter = $Support.adapter
    supported = $false
    reason = $Support.reason
    statements = @()
  }
}

function New-PostgreSqlRollbackJournalSqlPlan {
  param(
    [object[]]$WriteOperations,
    [string]$TransactionId,
    [string]$PlanIdempotencyKey,
    [string]$RollbackSnapshotKey,
    [object]$IdempotencyManifest,
    [string]$TenantId
  )

  $applyRunsDdl = @'
create table if not exists importer_apply_runs (
  transaction_id text primary key,
  plan_idempotency_key text not null unique,
  rollback_snapshot_idempotency_key text not null,
  idempotency_manifest_key text not null,
  tenant_id uuid not null,
  idempotency_manifest_json jsonb not null,
  status text not null check (status in ('prepared', 'applied', 'rolled_back', 'blocked')),
  dry_run_contract boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (length(btrim(transaction_id)) > 0),
  check (length(btrim(plan_idempotency_key)) > 0),
  check (length(btrim(rollback_snapshot_idempotency_key)) > 0),
  check (length(btrim(idempotency_manifest_key)) > 0),
  check (jsonb_typeof(idempotency_manifest_json) = 'object')
);
'@

  $operationJournalDdl = @'
create table if not exists importer_apply_operation_journal (
  snapshot_entry_id text primary key,
  transaction_id text not null references importer_apply_runs(transaction_id) on delete cascade,
  operation_id text not null,
  operation_idempotency_key text not null,
  target_kind text not null,
  target_natural_key_hash text not null,
  rollback_action text not null check (rollback_action in ('delete_created_object', 'restore_previous_object')),
  before_image_json jsonb not null,
  before_image_hash text,
  after_hash text not null,
  rollback_entry_json jsonb not null,
  status text not null check (status in ('prepared', 'skipped_same_after_hash', 'applied', 'rolled_back', 'blocked')),
  error_summary_json jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (transaction_id, operation_id),
  unique (operation_idempotency_key, target_kind, target_natural_key_hash),
  check (length(btrim(snapshot_entry_id)) > 0),
  check (length(btrim(operation_id)) > 0),
  check (length(btrim(operation_idempotency_key)) > 0),
  check (length(btrim(target_kind)) > 0),
  check (length(btrim(target_natural_key_hash)) > 0),
  check (length(btrim(after_hash)) > 0),
  check (before_image_hash is null or length(btrim(before_image_hash)) > 0),
  check (jsonb_typeof(before_image_json) = 'object'),
  check (jsonb_typeof(rollback_entry_json) = 'object'),
  check (jsonb_typeof(error_summary_json) = 'object')
);
'@

  $journalIndexesDdl = @'
create index if not exists idx_importer_apply_operation_journal_transaction
  on importer_apply_operation_journal(transaction_id, status);
create index if not exists idx_importer_apply_operation_journal_target
  on importer_apply_operation_journal(target_kind, target_natural_key_hash);
'@

  $runInsertSql = @'
insert into importer_apply_runs (
  transaction_id, plan_idempotency_key, rollback_snapshot_idempotency_key,
  idempotency_manifest_key, tenant_id, idempotency_manifest_json, status, dry_run_contract
)
values (
  :transaction_id, :plan_idempotency_key, :rollback_snapshot_idempotency_key,
  :idempotency_manifest_key, cast(:tenant_id as uuid), cast(:idempotency_manifest_json as jsonb),
  'prepared', true
)
on conflict (transaction_id) do update
set plan_idempotency_key = excluded.plan_idempotency_key,
    rollback_snapshot_idempotency_key = excluded.rollback_snapshot_idempotency_key,
    idempotency_manifest_key = excluded.idempotency_manifest_key,
    idempotency_manifest_json = excluded.idempotency_manifest_json,
    status = 'prepared',
    updated_at = now();
'@

  $operationInsertSql = @'
insert into importer_apply_operation_journal (
  snapshot_entry_id, transaction_id, operation_id, operation_idempotency_key,
  target_kind, target_natural_key_hash, rollback_action, before_image_json,
  before_image_hash, after_hash, rollback_entry_json, status
)
values (
  :snapshot_entry_id, :transaction_id, :operation_id, :operation_idempotency_key,
  :target_kind, :target_natural_key_hash, :rollback_action, cast(:before_image_json as jsonb),
  :before_image_hash, :after_hash, cast(:rollback_entry_json as jsonb), 'prepared'
)
on conflict (snapshot_entry_id) do update
set before_image_json = excluded.before_image_json,
    before_image_hash = excluded.before_image_hash,
    after_hash = excluded.after_hash,
    rollback_entry_json = excluded.rollback_entry_json,
    status = 'prepared',
    updated_at = now();
'@

  $runParameters = [ordered]@{
    transaction_id = $TransactionId
    plan_idempotency_key = $PlanIdempotencyKey
    rollback_snapshot_idempotency_key = $RollbackSnapshotKey
    idempotency_manifest_key = $IdempotencyManifest.manifest_key
    tenant_id = $TenantId
    idempotency_manifest_json = Convert-ToCompactJson $IdempotencyManifest 96
  }

  $operationInsertStatements = New-Object System.Collections.Generic.List[object]
  foreach ($operation in $WriteOperations) {
    $rollback = $operation.rollback
    $beforeImageHash = $null
    if ($null -ne $rollback.before_image -and $null -ne $rollback.before_image.object_hash) {
      $beforeImageHash = $rollback.before_image.object_hash
    }

    $operationParameters = [ordered]@{
      snapshot_entry_id = $operation.rollback_snapshot_entry_id
      transaction_id = $TransactionId
      operation_id = $operation.operation_id
      operation_idempotency_key = $operation.idempotency_key
      target_kind = $operation.target.kind
      target_natural_key_hash = $operation.target.natural_key_hash
      rollback_action = $rollback.rollback_action
      before_image_json = Convert-ToCompactJson $rollback.before_image 96
      before_image_hash = $beforeImageHash
      after_hash = $rollback.after_preview_hash
      rollback_entry_json = Convert-ToCompactJson $rollback 96
    }
    $operationInsertStatements.Add((New-PostgreSqlStatement "persist_rollback_journal_row" $operation.operation_id $operationInsertSql $operationParameters)) | Out-Null
  }

  return [ordered]@{
    schema_version = "importer.rollback-journal-sql-plan.v1"
    required_for_live_runner = $true
    dry_run = $true
    database_writes = $false
    live_database_connection = $false
    tables = @("importer_apply_runs", "importer_apply_operation_journal")
    before_image_persistence = [ordered]@{
      capture_inside_transaction = $true
      persist_before_mutation = $true
      row_lock_required = $true
      before_image_schema = "importer.before-image.v1"
      rollback_entry_schema = "importer.rollback-snapshot-entry.v1"
    }
    ddl_statements = @(
      New-PostgreSqlStatement "journal_ddl" "importer_apply_runs" $applyRunsDdl ([ordered]@{})
      New-PostgreSqlStatement "journal_ddl" "importer_apply_operation_journal" $operationJournalDdl ([ordered]@{})
      New-PostgreSqlStatement "journal_index_ddl" "importer_apply_operation_journal" $journalIndexesDdl ([ordered]@{})
    )
    run_insert_statement = New-PostgreSqlStatement "persist_apply_run" "apply_run" $runInsertSql $runParameters
    operation_insert_statements = @(Convert-ToObjectArray $operationInsertStatements)
    persistence_order = @(
      "create rollback journal tables if missing",
      "insert apply run row",
      "capture before-image with SELECT ... FOR UPDATE",
      "insert operation rollback journal row",
      "execute mutation",
      "update operation journal status"
    )
  }
}

function New-PostgreSqlRollbackOperationSkeletonPlan {
  param(
    [object[]]$WriteOperations,
    [string]$TransactionId,
    [string]$RollbackSnapshotKey,
    [string]$TenantId
  )

  $lookupSql = @'
select before_image_json, rollback_entry_json, rollback_action, status
from importer_apply_operation_journal
where transaction_id = :transaction_id
  and operation_id = :operation_id
  and snapshot_entry_id = :snapshot_entry_id
for update;
'@

  $markOperationRolledBackSql = @'
update importer_apply_operation_journal
set status = 'rolled_back',
    updated_at = now()
where transaction_id = :transaction_id
  and operation_id = :operation_id
  and snapshot_entry_id = :snapshot_entry_id
  and status = 'applied'
returning rollback_entry_json;
'@

  $markRunRolledBackSql = @'
update importer_apply_runs
set status = 'rolled_back',
    updated_at = now()
where transaction_id = :transaction_id
  and rollback_snapshot_idempotency_key = :rollback_snapshot_idempotency_key
  and status = 'applied'
  and not exists (
    select 1
    from importer_apply_operation_journal j
    where j.transaction_id = importer_apply_runs.transaction_id
      and j.status not in ('rolled_back', 'skipped_same_after_hash')
  )
returning transaction_id, status;
'@

  $runParameters = [ordered]@{
    tenant_id = $TenantId
    transaction_id = $TransactionId
    rollback_snapshot_idempotency_key = $RollbackSnapshotKey
  }

  $operations = @(Convert-ToObjectArray $WriteOperations)
  $operationSkeletons = New-Object System.Collections.Generic.List[object]
  $rollbackSequence = 0
  for ($index = $operations.Count - 1; $index -ge 0; $index--) {
    $operation = $operations[$index]
    $rollbackSequence += 1

    $rollbackIntent = "no_compensating_action"
    if ($operation.rollback.rollback_action -eq "delete_created_object") {
      $rollbackIntent = "delete_created_object_by_natural_key"
    } elseif ($operation.rollback.rollback_action -eq "restore_previous_object") {
      $rollbackIntent = "restore_previous_object_from_before_image_json"
    }

    $futureAdapter = "unavailable_for_target_kind"
    $futureMutationIntent = @("refuse until a target-specific rollback adapter is implemented")
    switch ([string]$operation.target.kind) {
      "provider" {
        $futureAdapter = "providers_rollback_v1_planned"
        $futureMutationIntent = @(
          "delete_created_object by tenant_id/provider_code when before_image.object_exists=false",
          "restore_previous_object from before_image_json when before_image.object_exists=true",
          "verify the current provider still matches after_hash or refuse replay"
        )
      }
      "channel" {
        $futureAdapter = "channels_rollback_v1_planned"
        $futureMutationIntent = @(
          "delete_created_object by tenant_id/provider_code/channel_name when before_image.object_exists=false",
          "restore_previous_object from before_image_json when before_image.object_exists=true",
          "verify the current channel still matches after_hash or refuse replay"
        )
      }
      "canonical_model" {
        $futureAdapter = "canonical_models_rollback_v1_planned"
        $futureMutationIntent = @(
          "delete_created_object by tenant_id/model_key when before_image.object_exists=false",
          "restore_previous_object from before_image_json when before_image.object_exists=true",
          "verify the current row still matches after_hash or refuse replay"
        )
      }
      "channel_mapping_entry" {
        $futureAdapter = "channel_model_mappings_rollback_v1_planned"
        $futureMutationIntent = @(
          "restore channels.model_mappings from before_image_json.existing_model_mappings",
          "remove requested_model when before_image recorded no existing mapping",
          "verify the current mapping still matches after_hash or refuse replay"
        )
      }
      "model_association" {
        $futureAdapter = "model_associations_rollback_v1_planned"
        $futureMutationIntent = @(
          "delete_created_object by persisted model_association id when before_image.object_exists=false",
          "restore_previous_object from before_image_json when before_image.object_exists=true",
          "verify the current association still matches after_hash or refuse replay"
        )
      }
    }

    $parameters = [ordered]@{
      tenant_id = $TenantId
      transaction_id = $TransactionId
      rollback_snapshot_idempotency_key = $RollbackSnapshotKey
      operation_id = $operation.operation_id
      snapshot_entry_id = $operation.rollback_snapshot_entry_id
      target_kind = $operation.target.kind
      target_natural_key_hash = $operation.target.natural_key_hash
      rollback_action = $operation.rollback.rollback_action
    }

    $operationSkeletons.Add([ordered]@{
        rollback_sequence = $rollbackSequence
        execution_order = "reverse_apply_order"
        operation_id = $operation.operation_id
        target = $operation.target
        rollback_snapshot_entry_id = $operation.rollback_snapshot_entry_id
        rollback_action = $operation.rollback.rollback_action
        compensating_action = $rollbackIntent
        supported_by_current_slice = $false
        required_journal_status = @("applied")
        no_secret_material = $true
        lookup_statement = New-PostgreSqlStatement "rollback_lookup_journal_entry" $operation.operation_id $lookupSql $parameters
        mark_rolled_back_statement = New-PostgreSqlStatement "rollback_mark_operation_rolled_back" $operation.operation_id $markOperationRolledBackSql $parameters
        replay_idempotency_contract = [ordered]@{
          schema_version = "importer.rollback-replay-idempotency-contract.v1"
          replay_key = "$($RollbackSnapshotKey):$($operation.rollback_snapshot_entry_id)"
          already_rolled_back = "no_op"
          skipped_same_after_hash = "no_op"
          prepared_or_blocked_status = "refuse"
          applied_status = "eligible_after_before_image_and_target_hash_verification"
        }
        compensating_mutation_contract = [ordered]@{
          schema_version = "importer.rollback-compensating-mutation-contract.v1"
          future_adapter = $futureAdapter
          mutation_intent = $futureMutationIntent
          future_runner_must_verify = @(
            "journal row belongs to requested transaction_id and snapshot_entry_id",
            "operation target hash matches journal target hash",
            "journal status is applied before compensating mutation",
            "before_image_json schema is importer.before-image.v1",
            "before_image_hash matches before_image_json when object_exists=true",
            "current target state still matches after_hash or replay must refuse"
          )
          mutation_sql_status = "not_generated_in_this_slice"
          database_writes = $false
        }
      }) | Out-Null
  }

  return [ordered]@{
    schema_version = "importer.rollback-operation-plan.v1"
    execution_status = "refused_no_live_runner"
    execution_order = "reverse_apply_order"
    rollback_snapshot_idempotency_key = $RollbackSnapshotKey
    transaction_id = $TransactionId
    database_writes = $false
    live_database_connection = $false
    compensating_rollback_supported_by_current_slice = $false
    operation_order = [ordered]@{
      ordering = "reverse_apply_order"
      operation_count = $operations.Count
      operation_ids = @(Convert-ToObjectArray ($operationSkeletons | ForEach-Object { $_.operation_id }))
      reason = "Rollback must unwind later apply mutations before earlier mutations."
    }
    replay_contract = [ordered]@{
      schema_version = "importer.rollback-execution-replay-contract.v1"
      replay_key = $RollbackSnapshotKey
      replay_decision_order = @(
        "load apply run by transaction_id and rollback_snapshot_idempotency_key",
        "lock operation journal rows in reverse apply order",
        "skip rows already rolled_back or skipped_same_after_hash",
        "refuse rows that are prepared, blocked, or missing before_image_json",
        "verify before_image_hash and target after_hash",
        "execute target-specific compensating mutation",
        "mark operation rolled_back",
        "mark apply run rolled_back after every operation is rolled_back or skipped"
      )
    }
    mark_run_rolled_back_statement = New-PostgreSqlStatement "rollback_mark_apply_run_rolled_back" "apply_run" $markRunRolledBackSql $runParameters
    refusal_contract = [ordered]@{
      schema_version = "importer.rollback-execution-refusal-contract.v1"
      refusal_reason = "Rollback execution is plan-only in import-apply-plan.ps1; use scripts/importers/invoke-import-apply-live.ps1 for the supported live PostgreSQL apply/rollback adapters."
      execute_supported = $false
      refuse_execute_when = @(
        "direct rollback execution was requested from the plan generator instead of invoke-import-apply-live.ps1",
        "rollback journal rows are not available from a supported live apply transaction",
        "operation journal status is not applied",
        "before_image hash verification fails",
        "current target state no longer matches after_hash",
        "target kind rollback adapter is unavailable",
        "operation ordering cannot be reconstructed"
      )
    }
    operation_skeletons = @(Convert-ToObjectArray $operationSkeletons)
  }
}

function New-PostgreSqlApplyExecutorPlan {
  param(
    [object[]]$WriteOperations,
    [object[]]$SkipOperations,
    [object[]]$OperationSupport,
    [string]$PreflightStatus,
    [string]$TransactionId,
    [string]$PlanIdempotencyKey,
    [string]$RollbackSnapshotKey,
    [object]$IdempotencyManifest,
    [bool]$ApplyRequested,
    [bool]$ForceConfirmed,
    [string]$TenantId
  )

  $unsupported = @(Convert-ToObjectArray $OperationSupport | Where-Object { -not [bool]$_.supported })
  $supported = @(Convert-ToObjectArray $OperationSupport | Where-Object { [bool]$_.supported })
  if (-not $ApplyRequested) {
    $executionStatus = "dry_run_sql_plan"
  } elseif ($PreflightStatus -ne "pass") {
    $executionStatus = "blocked_by_preflight"
  } elseif ($unsupported.Count -gt 0) {
    $executionStatus = "blocked_by_unsupported_operations"
  } else {
    $executionStatus = "prepared_sql_plan"
  }

  $operationPlans = New-Object System.Collections.Generic.List[object]
  foreach ($operation in $WriteOperations) {
    $support = @(Convert-ToObjectArray $OperationSupport | Where-Object { $_.operation_id -eq $operation.operation_id } | Select-Object -First 1)
    if ($support.Count -eq 0 -or -not [bool]$support[0].supported) {
      if ($support.Count -gt 0) {
        $operationPlans.Add((New-PostgreSqlUnsupportedOperationPlan $support[0])) | Out-Null
      }
      continue
    }

    if ($operation.target.kind -eq "provider") {
      $operationPlans.Add((New-PostgreSqlProviderOperationPlan $operation $TenantId)) | Out-Null
    } elseif ($operation.target.kind -eq "channel") {
      $operationPlans.Add((New-PostgreSqlChannelOperationPlan $operation $TenantId)) | Out-Null
    } elseif ($operation.target.kind -eq "canonical_model") {
      $operationPlans.Add((New-PostgreSqlCanonicalModelOperationPlan $operation $TenantId)) | Out-Null
    } elseif ($operation.target.kind -eq "model_association") {
      $operationPlans.Add((New-PostgreSqlModelAssociationOperationPlan $operation $TenantId)) | Out-Null
    } elseif ($operation.target.kind -eq "channel_mapping_entry") {
      $operationPlans.Add((New-PostgreSqlChannelMappingEntryOperationPlan $operation $TenantId)) | Out-Null
    }
  }

  $rollbackJournalSqlPlan = New-PostgreSqlRollbackJournalSqlPlan `
    -WriteOperations $WriteOperations `
    -TransactionId $TransactionId `
    -PlanIdempotencyKey $PlanIdempotencyKey `
    -RollbackSnapshotKey $RollbackSnapshotKey `
    -IdempotencyManifest $IdempotencyManifest `
    -TenantId $TenantId
  $rollbackOperationPlan = New-PostgreSqlRollbackOperationSkeletonPlan `
    -WriteOperations $WriteOperations `
    -TransactionId $TransactionId `
    -RollbackSnapshotKey $RollbackSnapshotKey `
    -TenantId $TenantId
  $journalStatementCount = @(
    @(Convert-ToObjectArray $rollbackJournalSqlPlan.ddl_statements).Count
    1
    @(Convert-ToObjectArray $rollbackJournalSqlPlan.operation_insert_statements).Count
  ) | Measure-Object -Sum

  return [ordered]@{
    schema_version = "importer.postgresql-sql-executor-plan.v1"
    executor = "postgresql_sql_plan"
    executor_status = $executionStatus
    dry_run = (-not $ApplyRequested)
    apply_requested = $ApplyRequested
    force_confirmed = $ForceConfirmed
    live_database_connection = $false
    database_writes = $false
    sql_writes_when_executed_by_future_runner = ($supported.Count -gt 0)
    tenant_id = Convert-ToSafeText $TenantId
    plan_idempotency_key = $PlanIdempotencyKey
    idempotency_manifest_key = $IdempotencyManifest.manifest_key
    rollback_snapshot_idempotency_key = $RollbackSnapshotKey
    write_gate = [ordered]@{
      default_mode = "dry_run"
      apply_requires = @("-Apply", "-Force", "preflight_status=pass", "supported_sql_adapters")
      current_invocation_authorized = ($ApplyRequested -and $ForceConfirmed -and $PreflightStatus -eq "pass" -and $unsupported.Count -eq 0)
    }
    counts = [ordered]@{
      write_operations = $WriteOperations.Count
      skip_operations = $SkipOperations.Count
      supported_write_operations = $supported.Count
      unsupported_write_operations = $unsupported.Count
      generated_operation_plans = $operationPlans.Count
      generated_sql_statements = @($operationPlans | ForEach-Object { @(Convert-ToObjectArray $_.statements).Count } | Measure-Object -Sum).Sum
      generated_journal_sql_statements = $journalStatementCount.Sum
    }
    unsupported_operations = @(Convert-ToObjectArray $unsupported)
    idempotency_contract = [ordered]@{
      schema_version = "importer.apply-idempotency-contract.v1"
      replay_key = $IdempotencyManifest.manifest_key
      operation_keys = @(Convert-ToObjectArray $IdempotencyManifest.entries)
      replay_decision_order = @(
        "match idempotency key and target natural key",
        "capture current before-image inside the transaction",
        "skip if before-image hash equals operation after_hash",
        "update if target exists and differs",
        "insert if target is missing"
      )
    }
    rollback_contract = [ordered]@{
      schema_version = "importer.rollback-snapshot-writer-contract.v1"
      snapshot_key = $RollbackSnapshotKey
      capture_before_apply = $true
      persist_before_mutation = $true
      includes_operation_id = $true
      includes_idempotency_key = $true
      no_secret_material = $true
      entry_schema = [ordered]@{
        schema_version = "importer.rollback-snapshot-entry.v1"
        required_fields = @(
          "snapshot_entry_id",
          "operation_id",
          "target.kind",
          "target.natural_key_hash",
          "rollback_action",
          "before_image.schema_version",
          "before_image.object_exists",
          "after_preview_hash"
        )
        before_image_schema = [ordered]@{
          schema_version = "importer.before-image.v1"
          object_hash_required_when_object_exists = $true
          object_body_required_when_object_exists = $true
          tombstone_required_when_creating = $true
        }
      }
      journal_sql_plan_schema = $rollbackJournalSqlPlan.schema_version
      rollback_operation_plan_schema = $rollbackOperationPlan.schema_version
    }
    journal_contract = [ordered]@{
      schema_version = "importer.rollback-journal-contract.v1"
      required_for_live_runner = $true
      proposed_tables = @("importer_apply_runs", "importer_apply_operation_journal")
      minimum_fields = @(
        "transaction_id",
        "plan_idempotency_key",
        "operation_id",
        "operation_idempotency_key",
        "target_kind",
        "target_natural_key_hash",
        "before_image_json",
        "before_image_hash",
        "after_hash",
        "status"
      )
      status_values = @("prepared", "skipped_same_after_hash", "applied", "rolled_back", "blocked")
      persist_order = @(
        "insert apply run row",
        "insert idempotency manifest rows",
        "capture before-image with row lock",
        "insert rollback snapshot entry",
        "execute mutation",
        "update operation journal status"
      )
      sql_plan = $rollbackJournalSqlPlan
    }
    refusal_contract = [ordered]@{
      schema_version = "importer.apply-refusal-contract.v1"
      live_runner_refusal_reason = "import-apply-plan.ps1 prepares SQL and rollback journal contracts only; scripts/importers/invoke-import-apply-live.ps1 executes the supported live PostgreSQL adapters."
      refuse_apply_when = @(
        "missing -Force with -Apply",
        "DryRun is false",
        "preflight_status is not pass",
        "blocking_conflicts preflight fails",
        "source_provider_channel_bindings preflight fails",
        "provider_key_secret_management_handoff preflight fails",
        "write_operations_supported_by_sql_executor preflight fails",
        "rollback_snapshot_shape preflight fails",
        "write idempotency keys are duplicated",
        "direct DB execution was requested from import-apply-plan.ps1 instead of invoke-import-apply-live.ps1"
      )
      conflict_blocking = [ordered]@{
        error_level_conflicts_block_apply = $true
        blocked_operation_action = "skip"
        blocked_operation_reason = "blocked_by_conflict"
      }
      source_binding_required_for_target_kinds = @("model_association", "channel_mapping_entry")
    }
    operation_bundle_contract = [ordered]@{
      schema_version = "importer.apply-operation-bundle.v1"
      bundle_kind = "json_sql_contract"
      transaction_boundary = "single_transaction"
      idempotency_boundary = "plan_idempotency_key plus operation idempotency keys"
      statement_phase_order = @(
        "begin",
        "advisory_lock",
        "persist_idempotency_manifest",
        "capture_before_image",
        "persist_rollback_snapshot_entry",
        "apply_mutation",
        "persist_operation_result",
        "commit"
      )
      rollback_phase_order = @(
        "rollback_database_transaction_on_apply_error",
        "or restore_previous_object/delete_created_object from persisted rollback snapshot in a later compensating runner"
      )
    }
    rollback_operation_plan = $rollbackOperationPlan
    transaction = [ordered]@{
      transaction_id = $TransactionId
      isolation_hint = "single PostgreSQL transaction with row-level FOR UPDATE before-image capture"
      begin_sql = "begin;"
      advisory_lock_sql = "select pg_advisory_xact_lock(hashtextextended(:plan_idempotency_key, 0));"
      commit_sql = "commit;"
      rollback_sql = "rollback;"
      rollback_journal_sql_plan_schema = $rollbackJournalSqlPlan.schema_version
      operation_plans = @(Convert-ToObjectArray $operationPlans)
    }
  }
}

function Get-InputFiles {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    throw "InputPath not found: $Path"
  }

  $resolvedInput = Resolve-Path -LiteralPath $Path
  $inputFiles = New-Object System.Collections.Generic.List[System.IO.FileInfo]
  foreach ($resolvedPath in $resolvedInput) {
    $item = Get-Item -LiteralPath $resolvedPath.Path
    if ($item.PSIsContainer) {
      foreach ($file in (Get-ChildItem -LiteralPath $item.FullName -Filter "*.json" -File | Sort-Object FullName)) {
        $inputFiles.Add($file) | Out-Null
      }
    } else {
      $inputFiles.Add($item) | Out-Null
    }
  }

  if ($inputFiles.Count -eq 0) {
    throw "No JSON input files found at $Path."
  }

  return $inputFiles
}

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][System.IO.FileInfo]$File)

  $rawJson = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8
  try {
    return ConvertFrom-Json -InputObject $rawJson
  } catch {
    throw "Invalid JSON in '$(Get-RepoRelativePath $File.FullName)': $($_.Exception.Message)"
  }
}

function Add-ExistingStateItem {
  param(
    [hashtable]$Index,
    [string]$Kind,
    [string]$NaturalKey,
    [object]$Value
  )

  if ([string]::IsNullOrWhiteSpace($NaturalKey)) {
    return
  }

  $Index[$Kind][$NaturalKey] = Convert-ToSafeObject $Value
}

function Get-PlannedAction {
  param(
    [hashtable]$ExistingIndex,
    [string]$Kind,
    [string]$NaturalKey,
    [object]$After
  )

  if (-not $ExistingIndex[$Kind].ContainsKey($NaturalKey)) {
    return [ordered]@{ action = "create"; before = $null; reason = "not_found_in_existing_state" }
  }

  $before = $ExistingIndex[$Kind][$NaturalKey]
  $beforeComparable = Select-ComparableFields $Kind $before
  $afterComparable = Select-ComparableFields $Kind $After
  if ((Get-StableHash $beforeComparable 32) -eq (Get-StableHash $afterComparable 32)) {
    return [ordered]@{ action = "skip"; before = $before; reason = "already_matches_existing_state" }
  }

  return [ordered]@{ action = "update"; before = $before; reason = "differs_from_existing_state" }
}

$existingIndex = @{
  provider = @{}
  channel = @{}
  canonical_model = @{}
  model_association = @{}
  channel_mapping_entry = @{}
}
$existingStateSummary = [ordered]@{
  provided = $false
  input_file = $null
  counts = [ordered]@{
    providers = 0
    channels = 0
    canonical_models = 0
    model_associations = 0
    channel_mapping_entries = 0
  }
}

if (-not [string]::IsNullOrWhiteSpace($ExistingStatePath)) {
  $existingFile = Get-Item -LiteralPath $ExistingStatePath
  $existingState = Read-JsonFile $existingFile
  $existingStateSummary.provided = $true
  $existingStateSummary.input_file = Get-RepoRelativePath $existingFile.FullName

  foreach ($provider in (Convert-ToImportArray (Get-PropertyValue $existingState @("providers") $null))) {
    Add-ExistingStateItem $existingIndex "provider" (Get-ProviderNaturalKey $provider) $provider
  }

  foreach ($channel in (Convert-ToImportArray (Get-PropertyValue $existingState @("channels") $null))) {
    Add-ExistingStateItem $existingIndex "channel" (Get-ChannelNaturalKey $channel) $channel
  }

  foreach ($model in (Convert-ToImportArray (Get-PropertyValue $existingState @("canonical_models") $null))) {
    Add-ExistingStateItem $existingIndex "canonical_model" (Get-CanonicalModelNaturalKey $model) $model
  }

  foreach ($association in (Convert-ToImportArray (Get-PropertyValue $existingState @("model_associations", "associations") $null))) {
    Add-ExistingStateItem $existingIndex "model_association" (Get-AssociationNaturalKey $association) $association
  }

  foreach ($entry in (Convert-ToImportArray (Get-PropertyValue $existingState @("channel_mapping_entries") $null))) {
    Add-ExistingStateItem $existingIndex "channel_mapping_entry" (Get-ChannelMappingEntryNaturalKey $entry) $entry
  }

  foreach ($mapping in (Convert-ToImportArray (Get-PropertyValue $existingState @("channel_mappings") $null))) {
    foreach ($entry in (Convert-ToImportArray (Get-PropertyValue $mapping @("mapping_entries") $null))) {
      Add-ExistingStateItem $existingIndex "channel_mapping_entry" (Get-ChannelMappingEntryNaturalKey $entry) $entry
    }
  }

  $existingStateSummary.counts.providers = $existingIndex.provider.Count
  $existingStateSummary.counts.channels = $existingIndex.channel.Count
  $existingStateSummary.counts.canonical_models = $existingIndex.canonical_model.Count
  $existingStateSummary.counts.model_associations = $existingIndex.model_association.Count
  $existingStateSummary.counts.channel_mapping_entries = $existingIndex.channel_mapping_entry.Count
}

$inputFiles = Get-InputFiles $InputPath
$inputFilePaths = @($inputFiles | ForEach-Object { Get-RepoRelativePath $_.FullName })
$inputReportSummaries = New-Object System.Collections.Generic.List[object]
$allConflicts = New-Object System.Collections.Generic.List[object]
$allProviderPreviews = New-Object System.Collections.Generic.List[object]
$allChannelPreviews = New-Object System.Collections.Generic.List[object]
$providerPreviewKeys = @{}
$channelPreviewKeys = @{}
$allCanonicalModels = New-Object System.Collections.Generic.List[object]
$allAssociations = New-Object System.Collections.Generic.List[object]
$allChannelMappingEntries = New-Object System.Collections.Generic.List[object]
$allProviderKeyHandoffs = New-Object System.Collections.Generic.List[object]
$sourceSpecificApplyPlanArtifacts = New-Object System.Collections.Generic.List[object]
$sourceChannelBindings = @{}
$blockedRequestedModels = @{}
$blockedChannels = @{}
$blockingConflictCount = 0

foreach ($file in $inputFiles) {
  $report = Read-JsonFile $file
  $dryRun = Get-PropertyValue $report @("dry_run", "dryRun", "DryRun") $true
  if (-not [bool]$dryRun) {
    throw "Input report '$(Get-RepoRelativePath $file.FullName)' must be a dry-run report."
  }

  $importerName = Convert-ToSafeText (Get-PropertyValue $report @("importer", "source", "source_system") "unknown-importer")
  if ($importerName -ne "internal-mapping-report-dryrun") {
    throw "Input report '$(Get-RepoRelativePath $file.FullName)' must be produced by import-internal-mapping-report.ps1. Actual importer: $importerName"
  }

  $inputReportSummaries.Add([ordered]@{
      input_file = Get-RepoRelativePath $file.FullName
      importer = $importerName
      dry_run = $true
      counts = Convert-ToSafeObject (Get-PropertyValue $report @("counts", "summary") ([ordered]@{}))
      source_reports = @(Convert-ToObjectArray (Get-PropertyValue $report @("source_reports") @()) | ForEach-Object { Convert-ToSafeObject $_ })
    }) | Out-Null

  foreach ($conflict in (Convert-ToImportArray (Get-PropertyValue $report @("conflicts") $null))) {
    $safeConflict = Convert-ToSafeObject $conflict
    $allConflicts.Add($safeConflict) | Out-Null

    $severity = Convert-ToSafeText (Get-PropertyValue $conflict @("severity") "error")
    if ($severity -ne "error") {
      continue
    }

    $blockingConflictCount += 1
    $type = Convert-ToSafeText (Get-PropertyValue $conflict @("type") "unknown_conflict")
    $key = Convert-ToSafeText (Get-PropertyValue $conflict @("key") $null)
    $ref = New-ConflictRef $conflict
    if ($type -eq "requested_model_conflict" -and -not [string]::IsNullOrWhiteSpace($key)) {
      $blockedRequestedModels[$key] = $ref
    }
    if ($type -eq "missing_channel_reference" -and -not [string]::IsNullOrWhiteSpace($key)) {
      $blockedChannels[$key] = $ref
    }
  }

  foreach ($model in (Convert-ToImportArray (Get-PropertyValue $report @("canonical_models", "models") $null))) {
    $allCanonicalModels.Add($model) | Out-Null
  }

  foreach ($association in (Convert-ToImportArray (Get-PropertyValue $report @("model_associations", "associations") $null))) {
    $allAssociations.Add($association) | Out-Null
  }

  foreach ($handoff in (Convert-ToImportArray (Get-PropertyValue $report @("provider_key_handoffs") $null))) {
    $allProviderKeyHandoffs.Add($handoff) | Out-Null
  }

  foreach ($sourceArtifacts in (Convert-ToImportArray (Get-PropertyValue $report @("source_specific_apply_plan_artifacts") $null))) {
    $sourceSpecificApplyPlanArtifacts.Add((Convert-ToSafeObject $sourceArtifacts)) | Out-Null
  }

  foreach ($mapping in (Convert-ToImportArray (Get-PropertyValue $report @("channel_mappings") $null))) {
    $channelSourceId = Convert-ToSafeText (Get-PropertyValue $mapping @("channel_source_id") $null)
    $binding = New-SourceChannelBindingRef $mapping
    $providerPreview = $null
    $channelPreview = $null
    $internalProviderId = Convert-ToSafeText (Get-PropertyValue $binding @("internal_provider_id") $null)
    $internalChannelId = Convert-ToSafeText (Get-PropertyValue $binding @("internal_channel_id") $null)
    $shouldDeriveProviderChannel = $false
    if ($null -ne $binding -and [bool](Get-PropertyValue $binding @("channel_present") $false)) {
      $shouldDeriveProviderChannel = ([string]::IsNullOrWhiteSpace($internalProviderId) -or [string]::IsNullOrWhiteSpace($internalChannelId))
    }
    if ($shouldDeriveProviderChannel) {
      $providerPreview = New-ProviderPreviewFromChannelMapping $mapping $script:TenantId
      $channelPreview = New-ChannelPreviewFromChannelMapping $mapping $script:TenantId
      if ($null -ne $providerPreview -and $null -ne $channelPreview) {
        $providerKey = Get-ProviderNaturalKey $providerPreview
        $channelKey = Get-ChannelNaturalKey $channelPreview
        if (-not $providerPreviewKeys.ContainsKey($providerKey)) {
          $providerPreviewKeys[$providerKey] = $true
          $allProviderPreviews.Add($providerPreview) | Out-Null
        }
        if (-not $channelPreviewKeys.ContainsKey($channelKey)) {
          $channelPreviewKeys[$channelKey] = $true
          $allChannelPreviews.Add($channelPreview) | Out-Null
        }
        $binding["internal_provider_id"] = Convert-ToSafeText (Get-PropertyValue $providerPreview @("internal_provider_id") $null)
        $binding["internal_channel_id"] = Convert-ToSafeText (Get-PropertyValue $channelPreview @("internal_channel_id") $null)
      }
    }
    if ($null -ne $binding -and -not [string]::IsNullOrWhiteSpace($channelSourceId)) {
      $sourceChannelBindings[$channelSourceId] = $binding
    }
    $channelPresent = [bool](Get-PropertyValue $mapping @("channel_present") $true)
    foreach ($entry in (Convert-ToImportArray (Get-PropertyValue $mapping @("mapping_entries") $null))) {
      $safeEntry = Convert-ToSafeObject $entry
      if ($null -eq (Get-PropertyValue $safeEntry @("channel_source_id") $null)) {
        $safeEntry["channel_source_id"] = $channelSourceId
      }
      if (-not [string]::IsNullOrWhiteSpace($channelSourceId) -and $sourceChannelBindings.ContainsKey($channelSourceId)) {
        $binding = $sourceChannelBindings[$channelSourceId]
        $safeEntry["internal_provider_id"] = Convert-ToSafeText (Get-PropertyValue $binding @("internal_provider_id") $null)
        $safeEntry["internal_channel_id"] = Convert-ToSafeText (Get-PropertyValue $binding @("internal_channel_id") $null)
      }
      $safeEntry["channel_present"] = $channelPresent
      $allChannelMappingEntries.Add($safeEntry) | Out-Null
    }
  }
}

$providerKeyHandoffSidecarItems = New-Object System.Collections.Generic.List[object]
$providerKeyHandoffKeys = @{}
foreach ($handoff in $allProviderKeyHandoffs) {
  $sidecar = New-ProviderKeyHandoffSidecar $handoff $sourceChannelBindings
  $sidecarKey = "$($sidecar.channel_source_id)|$($sidecar.key_alias)"
  if ([string]::IsNullOrWhiteSpace($sidecarKey)) {
    $sidecarKey = $sidecar.handoff_id
  }
  if (-not $providerKeyHandoffKeys.ContainsKey($sidecarKey)) {
    $providerKeyHandoffKeys[$sidecarKey] = $true
    $providerKeyHandoffSidecarItems.Add($sidecar) | Out-Null
  }
}
$providerKeyHandoffSidecars = @($providerKeyHandoffSidecarItems | Sort-Object channel_source_id, key_alias, handoff_id)
$providerKeyHandoffValidation = Test-ProviderKeyHandoffShape $providerKeyHandoffSidecars

$plannedCreates = New-Object System.Collections.Generic.List[object]
$plannedUpdates = New-Object System.Collections.Generic.List[object]
$plannedSkips = New-Object System.Collections.Generic.List[object]
$emittedTargets = @{}

foreach ($provider in $allProviderPreviews) {
  $naturalKey = Get-ProviderNaturalKey $provider
  $providerCode = Convert-ToSafeText (Get-PropertyValue $provider @("provider_code", "code") $null)
  if ([string]::IsNullOrWhiteSpace($providerCode)) {
    $operation = New-PlanOperation "skip" "provider" $naturalKey $provider $null "missing_provider_code" @()
    Add-Operation $plannedCreates $plannedUpdates $plannedSkips $emittedTargets $operation
    continue
  }

  $actionInfo = Get-PlannedAction $existingIndex "provider" $naturalKey $provider
  $operation = New-PlanOperation $actionInfo.action "provider" $naturalKey $provider $actionInfo.before $actionInfo.reason @()
  Add-Operation $plannedCreates $plannedUpdates $plannedSkips $emittedTargets $operation
}

foreach ($channel in $allChannelPreviews) {
  $naturalKey = Get-ChannelNaturalKey $channel
  $providerCode = Convert-ToSafeText (Get-PropertyValue $channel @("provider_code") $null)
  $internalChannelId = Convert-ToSafeText (Get-PropertyValue $channel @("internal_channel_id", "channel_id", "id") $null)
  $channelName = Convert-ToSafeText (Get-PropertyValue $channel @("name", "channel_name") $null)
  $endpoint = Convert-ToSafeText (Get-PropertyValue $channel @("endpoint", "base_url", "url") $null)
  if ([string]::IsNullOrWhiteSpace($providerCode) -or [string]::IsNullOrWhiteSpace($internalChannelId) -or [string]::IsNullOrWhiteSpace($channelName) -or [string]::IsNullOrWhiteSpace($endpoint)) {
    $operation = New-PlanOperation "skip" "channel" $naturalKey $channel $null "missing_channel_apply_fields" @()
    Add-Operation $plannedCreates $plannedUpdates $plannedSkips $emittedTargets $operation
    continue
  }

  $actionInfo = Get-PlannedAction $existingIndex "channel" $naturalKey $channel
  $operation = New-PlanOperation $actionInfo.action "channel" $naturalKey $channel $actionInfo.before $actionInfo.reason @()
  Add-Operation $plannedCreates $plannedUpdates $plannedSkips $emittedTargets $operation
}

foreach ($model in $allCanonicalModels) {
  $naturalKey = Get-CanonicalModelNaturalKey $model
  $modelKey = Convert-ToSafeText (Get-PropertyValue $model @("model_key", "canonical_model_key", "model", "key", "name", "id") $null)
  if ([string]::IsNullOrWhiteSpace($modelKey)) {
    $operation = New-PlanOperation "skip" "canonical_model" $naturalKey $model $null "missing_model_key" @()
    Add-Operation $plannedCreates $plannedUpdates $plannedSkips $emittedTargets $operation
    continue
  }

  $actionInfo = Get-PlannedAction $existingIndex "canonical_model" $naturalKey $model
  $operation = New-PlanOperation $actionInfo.action "canonical_model" $naturalKey $model $actionInfo.before $actionInfo.reason @()
  Add-Operation $plannedCreates $plannedUpdates $plannedSkips $emittedTargets $operation
}

foreach ($association in $allAssociations) {
  $safeAssociation = Convert-ToSafeObject $association
  $channelSourceId = Convert-ToSafeText (Get-PropertyValue $safeAssociation @("channel_source_id", "source_channel_id") $null)
  if (-not [string]::IsNullOrWhiteSpace($channelSourceId) -and $sourceChannelBindings.ContainsKey($channelSourceId)) {
    $binding = $sourceChannelBindings[$channelSourceId]
    $safeAssociation["internal_provider_id"] = Convert-ToSafeText (Get-PropertyValue $binding @("internal_provider_id") $null)
    $safeAssociation["internal_channel_id"] = Convert-ToSafeText (Get-PropertyValue $binding @("internal_channel_id") $null)
    $safeAssociation["channel_present"] = [bool](Get-PropertyValue $binding @("channel_present") $false)
  }

  $naturalKey = Get-AssociationNaturalKey $safeAssociation
  $requestedModel = Convert-ToSafeText (Get-PropertyValue $safeAssociation @("requested_model", "client_model", "source_model") $null)
  $conflictRefs = New-Object System.Collections.Generic.List[object]
  if (-not [string]::IsNullOrWhiteSpace($requestedModel) -and $blockedRequestedModels.ContainsKey($requestedModel)) {
    $conflictRefs.Add($blockedRequestedModels[$requestedModel]) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace($channelSourceId) -and $blockedChannels.ContainsKey($channelSourceId)) {
    $conflictRefs.Add($blockedChannels[$channelSourceId]) | Out-Null
  }

  if ($conflictRefs.Count -gt 0) {
    $operation = New-PlanOperation "skip" "model_association" $naturalKey $safeAssociation $null "blocked_by_conflict" (Convert-ToObjectArray $conflictRefs)
    Add-Operation $plannedCreates $plannedUpdates $plannedSkips $emittedTargets $operation
    continue
  }

  if ([string]::IsNullOrWhiteSpace($requestedModel)) {
    $operation = New-PlanOperation "skip" "model_association" $naturalKey $safeAssociation $null "missing_requested_model" @()
    Add-Operation $plannedCreates $plannedUpdates $plannedSkips $emittedTargets $operation
    continue
  }

  $actionInfo = Get-PlannedAction $existingIndex "model_association" $naturalKey $safeAssociation
  $operation = New-PlanOperation $actionInfo.action "model_association" $naturalKey $safeAssociation $actionInfo.before $actionInfo.reason @()
  Add-Operation $plannedCreates $plannedUpdates $plannedSkips $emittedTargets $operation
}

foreach ($entry in $allChannelMappingEntries) {
  $naturalKey = Get-ChannelMappingEntryNaturalKey $entry
  $requestedModel = Convert-ToSafeText (Get-PropertyValue $entry @("requested_model", "client_model", "source_model") $null)
  $channelSourceId = Convert-ToSafeText (Get-PropertyValue $entry @("channel_source_id", "source_channel_id") $null)
  $channelPresent = [bool](Get-PropertyValue $entry @("channel_present") $true)
  $conflictRefs = New-Object System.Collections.Generic.List[object]
  if (-not [string]::IsNullOrWhiteSpace($requestedModel) -and $blockedRequestedModels.ContainsKey($requestedModel)) {
    $conflictRefs.Add($blockedRequestedModels[$requestedModel]) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace($channelSourceId) -and $blockedChannels.ContainsKey($channelSourceId)) {
    $conflictRefs.Add($blockedChannels[$channelSourceId]) | Out-Null
  }

  if ($conflictRefs.Count -gt 0) {
    $operation = New-PlanOperation "skip" "channel_mapping_entry" $naturalKey $entry $null "blocked_by_conflict" (Convert-ToObjectArray $conflictRefs)
    Add-Operation $plannedCreates $plannedUpdates $plannedSkips $emittedTargets $operation
    continue
  }

  if ([string]::IsNullOrWhiteSpace($requestedModel) -or [string]::IsNullOrWhiteSpace($channelSourceId)) {
    $operation = New-PlanOperation "skip" "channel_mapping_entry" $naturalKey $entry $null "missing_mapping_natural_key" @()
    Add-Operation $plannedCreates $plannedUpdates $plannedSkips $emittedTargets $operation
    continue
  }

  $actionInfo = Get-PlannedAction $existingIndex "channel_mapping_entry" $naturalKey $entry
  $operation = New-PlanOperation $actionInfo.action "channel_mapping_entry" $naturalKey $entry $actionInfo.before $actionInfo.reason @()
  Add-Operation $plannedCreates $plannedUpdates $plannedSkips $emittedTargets $operation
}

$writeOperations = @($plannedCreates.ToArray()) + @($plannedUpdates.ToArray())
$skipOperations = @($plannedSkips.ToArray())
$allPlannedOperations = $writeOperations + $skipOperations

$rollbackEntries = New-Object System.Collections.Generic.List[object]
foreach ($operation in $writeOperations) {
  $rollbackEntries.Add($operation.rollback) | Out-Null
}

$operationIds = @($allPlannedOperations | ForEach-Object { $_.operation_id } | Sort-Object)
$planSeed = [ordered]@{
  input_files = $inputFilePaths
  existing_state = $existingStateSummary
  operation_ids = $operationIds
  creates = $plannedCreates.Count
  updates = $plannedUpdates.Count
  skips = $plannedSkips.Count
  conflicts = $allConflicts.Count
  provider_key_handoffs = @($providerKeyHandoffSidecars | ForEach-Object { $_.handoff_id } | Sort-Object)
}
$planIdempotencyKey = "importer-apply-plan:v1:$(Get-StableHash $planSeed 24)"
$rollbackSnapshotKey = "importer-rollback-snapshot:v1:$(Get-StableHash @($rollbackEntries | ForEach-Object { $_.snapshot_entry_id }) 24)"
$idempotencyManifest = New-IdempotencyManifest $writeOperations
$operationSupport = New-Object System.Collections.Generic.List[object]
foreach ($operation in $writeOperations) {
  $operationSupport.Add((Get-SqlExecutorSupport $operation)) | Out-Null
}
$unsupportedSqlOperations = @(Convert-ToObjectArray $operationSupport | Where-Object { -not [bool]$_.supported })

$preflightChecks = New-Object System.Collections.Generic.List[object]
Add-PreflightCheck $preflightChecks "input_reports" "pass" "Input reports were loaded and parsed." ([ordered]@{ count = $inputFiles.Count })
if ($blockingConflictCount -gt 0) {
  Add-PreflightCheck $preflightChecks "blocking_conflicts" "fail" "Resolve error-level import conflicts before any real apply." ([ordered]@{ count = $blockingConflictCount })
} else {
  Add-PreflightCheck $preflightChecks "blocking_conflicts" "pass" "No error-level import conflicts were found." ([ordered]@{ count = 0 })
}

$writeIdempotencyDuplicates = Get-DuplicateValues -Values @($writeOperations | ForEach-Object { $_.idempotency_key })
if ($writeIdempotencyDuplicates.Count -gt 0) {
  Add-PreflightCheck $preflightChecks "write_idempotency_keys_unique" "fail" "Planned write idempotency keys must be unique." ([ordered]@{ duplicates = $writeIdempotencyDuplicates })
} else {
  Add-PreflightCheck $preflightChecks "write_idempotency_keys_unique" "pass" "Planned write idempotency keys are unique." ([ordered]@{ count = $writeOperations.Count })
}

$rollbackShapeErrors = Test-RollbackSnapshotShape $writeOperations
if ($rollbackShapeErrors.Count -gt 0) {
  Add-PreflightCheck $preflightChecks "rollback_snapshot_shape" "fail" "Rollback snapshot entries must match write operations." ([ordered]@{ errors = $rollbackShapeErrors })
} else {
  Add-PreflightCheck $preflightChecks "rollback_snapshot_shape" "pass" "Rollback snapshot entries match planned write operations." ([ordered]@{ entries = $rollbackEntries.Count })
}

$sourceBindingValidation = Test-SourceChannelBindingShape $writeOperations $sourceChannelBindings
if ($sourceBindingValidation.errors.Count -gt 0) {
  Add-PreflightCheck $preflightChecks "source_provider_channel_bindings" "fail" "Source channel writes require a verified source provider/channel binding and an internal channel id before apply." ([ordered]@{
      checked = $sourceBindingValidation.checked
      errors = $sourceBindingValidation.errors
      required_binding_fields = @("channel_source_id", "provider_code or internal_provider_id", "internal_channel_id")
    })
} else {
  Add-PreflightCheck $preflightChecks "source_provider_channel_bindings" "pass" "No unbound source provider/channel write was found." ([ordered]@{
      checked_count = $sourceBindingValidation.checked.Count
      source_channel_bindings = @(Convert-ToObjectArray $sourceChannelBindings.Values)
    })
}

if ($providerKeyHandoffValidation.errors.Count -gt 0) {
  Add-PreflightCheck $preflightChecks "provider_key_secret_management_handoff" "fail" "Provider key handoff is sidecar-only and must not include raw credential material or direct DB apply." ([ordered]@{
      handoff_count = $providerKeyHandoffSidecars.Count
      sidecar_only = $true
      raw_material_allowed = $false
      apply_directly_supported = $false
      errors = $providerKeyHandoffValidation.errors
      warnings = $providerKeyHandoffValidation.warnings
    })
} else {
  Add-PreflightCheck $preflightChecks "provider_key_secret_management_handoff" "pass" "Provider key handoff is sidecar-only; operators must enter provider keys through the Control Plane secret-management path." ([ordered]@{
      handoff_count = $providerKeyHandoffSidecars.Count
      sidecar_only = $true
      raw_material_allowed = $false
      apply_directly_supported = $false
      warning_count = $providerKeyHandoffValidation.warnings.Count
      warnings = $providerKeyHandoffValidation.warnings
      required_operator_path = "POST /admin/provider-keys"
    })
}

Add-PreflightCheck $preflightChecks "database_writer_available" "pass" "PostgreSQL SQL-plan executor is available; this slice does not open a live database connection." ([ordered]@{
    executor = $script:ApplyExecutor
    database_writes = $false
    live_database_connection = $false
  })

if ($unsupportedSqlOperations.Count -gt 0) {
  Add-PreflightCheck $preflightChecks "write_operations_supported_by_sql_executor" "fail" "Some planned writes need a later DB adapter before apply can run." ([ordered]@{
      unsupported_count = $unsupportedSqlOperations.Count
      unsupported_operations = @(Convert-ToObjectArray $unsupportedSqlOperations)
    })
} else {
  Add-PreflightCheck $preflightChecks "write_operations_supported_by_sql_executor" "pass" "All planned writes have SQL executor adapters." ([ordered]@{
      supported_count = $writeOperations.Count
    })
}

$preflightFailures = @($preflightChecks | Where-Object { $_.status -eq "fail" })
$preflightStatus = "pass"
if ($preflightFailures.Count -gt 0) {
  $preflightStatus = "blocked"
}

$preflight = [ordered]@{
  schema_version = "importer.apply-preflight.v1"
  status = $preflightStatus
  blocking_check_count = $preflightFailures.Count
  checks = @(Convert-ToObjectArray $preflightChecks)
}

$transactionOperationOrder = New-Object System.Collections.Generic.List[object]
foreach ($operation in $writeOperations) {
  $transactionOperationOrder.Add([ordered]@{
      operation_id = $operation.operation_id
      action = $operation.action
      target = $operation.target
      idempotency_key = $operation.idempotency_key
      rollback_snapshot_entry_id = $operation.rollback_snapshot_entry_id
    }) | Out-Null
}

$applyExecutionStatus = "not_requested"
$realApplyStatus = "dry_run_sql_plan"
$applyRefusalReason = $null
$realDatabaseWriteRefusalReason = "import-apply-plan.ps1 is plan-only: -Apply -Force prepares SQL, rollback journal DDL/insert plans, and rollback skeletons only. Use scripts/importers/invoke-import-apply-live.ps1 for supported live PostgreSQL apply/rollback execution."
if ($script:ApplyRequested) {
  if ($preflightStatus -eq "pass") {
    $applyExecutionStatus = "prepared_sql_plan"
    $realApplyStatus = "prepared_sql_plan"
    $applyRefusalReason = $realDatabaseWriteRefusalReason
  } else {
    $applyExecutionStatus = "blocked_by_preflight"
    $realApplyStatus = "blocked_by_preflight"
    $applyRefusalReason = "Apply execution is blocked by preflight checks; no database writes were made."
  }
}

$transactionSeed = "$planIdempotencyKey|$rollbackSnapshotKey|$($idempotencyManifest.manifest_key)"
$transactionId = "tx_importer_apply_plan_$(Get-StableHash $transactionSeed 16)"
$sqlExecutorPlan = New-PostgreSqlApplyExecutorPlan `
  -WriteOperations $writeOperations `
  -SkipOperations $skipOperations `
  -OperationSupport @(Convert-ToObjectArray $operationSupport) `
  -PreflightStatus $preflightStatus `
  -TransactionId $transactionId `
  -PlanIdempotencyKey $planIdempotencyKey `
  -RollbackSnapshotKey $rollbackSnapshotKey `
  -IdempotencyManifest $idempotencyManifest `
  -ApplyRequested $script:ApplyRequested `
  -ForceConfirmed $script:ForceConfirmed `
  -TenantId $script:TenantId

$transactionContract = [ordered]@{
  schema_version = "importer.apply-transaction-contract.v1"
  transaction_id = $transactionId
  apply_requested = $script:ApplyRequested
  force_confirmed = $script:ForceConfirmed
  dry_run = (-not $script:ApplyRequested)
  execution_status = $applyExecutionStatus
  refusal_reason = $applyRefusalReason
  real_database_write_refusal_reason = $realDatabaseWriteRefusalReason
  database_writes = $false
  executor = $script:ApplyExecutor
  executor_status = $sqlExecutorPlan.executor_status
  live_database_connection = $false
  sql_executor_plan_schema = $sqlExecutorPlan.schema_version
  preflight_status = $preflightStatus
  idempotency_manifest_key = $idempotencyManifest.manifest_key
  rollback_snapshot_idempotency_key = $rollbackSnapshotKey
  operation_order = @(Convert-ToObjectArray $transactionOperationOrder)
  phases = @(
    "preflight",
    "begin_database_transaction",
    "persist_idempotency_manifest",
    "capture_and_persist_rollback_snapshot",
    "persist_rollback_journal_rows",
    "apply_operations_in_order",
    "commit_or_restore_from_rollback_snapshot"
  )
}

$targetCounts = [ordered]@{}
foreach ($kind in @("provider", "channel", "canonical_model", "model_association", "channel_mapping_entry")) {
  $targetCounts[$kind] = [ordered]@{
    creates = @($plannedCreates | Where-Object { $_.target.kind -eq $kind }).Count
    updates = @($plannedUpdates | Where-Object { $_.target.kind -eq $kind }).Count
    skips = @($plannedSkips | Where-Object { $_.target.kind -eq $kind }).Count
  }
}

$counts = [ordered]@{
  input_reports = $inputFiles.Count
  source_provider_previews = $allProviderPreviews.Count
  source_channel_previews = $allChannelPreviews.Count
  source_canonical_models = $allCanonicalModels.Count
  source_model_associations = $allAssociations.Count
  source_channel_mapping_entries = $allChannelMappingEntries.Count
  source_provider_key_handoffs = $providerKeyHandoffSidecars.Count
  planned_creates = $plannedCreates.Count
  planned_updates = $plannedUpdates.Count
  planned_skips = $plannedSkips.Count
  operations = $plannedCreates.Count + $plannedUpdates.Count + $plannedSkips.Count
  conflicts = $allConflicts.Count
  blocking_conflicts = $blockingConflictCount
  rollback_snapshot_entries = $rollbackEntries.Count
  source_channel_bindings = $sourceChannelBindings.Count
  source_specific_apply_plan_artifacts = $sourceSpecificApplyPlanArtifacts.Count
}

function New-MappingQualityReadback {
  param(
    [object[]]$ProviderPreviews,
    [object[]]$ChannelPreviews,
    [object[]]$CanonicalModels,
    [object[]]$Associations,
    [object[]]$ChannelMappingEntries,
    [object[]]$ProviderKeyHandoffs,
    [object[]]$Conflicts,
    [int]$BlockingConflictCount,
    [object[]]$PlannedCreates,
    [object[]]$PlannedUpdates,
    [object[]]$PlannedSkips,
    [object[]]$SourceSpecificApplyPlanArtifacts,
    [string]$PreflightStatus
  )

  $conflictRefs = @($Conflicts | ForEach-Object {
      [ordered]@{
        severity = Convert-ToSafeText (Get-PropertyValue $_ @("severity") "warning")
        kind = Convert-ToSafeText (Get-PropertyValue $_ @("kind", "type") "conflict")
        key = Convert-ToSafeText (Get-PropertyValue $_ @("key", "natural_key", "source_key") $null)
        reason = Convert-ToSafeText (Get-PropertyValue $_ @("reason", "summary") "Conflict requires review.")
      }
    })
  $skipReasons = @($PlannedSkips | ForEach-Object {
      [ordered]@{
        type = Convert-ToSafeText (Get-PropertyValue $_.target @("kind") "planned_skip")
        severity = if ($_.reason -eq "blocked_by_conflict") { "error" } else { "warning" }
        reason = Convert-ToSafeText (Get-PropertyValue $_ @("reason") "planned_skip")
        recommended_action = "Resolve or explicitly accept this skipped mapping before live apply."
      }
    })

  $sourceArtifactSubscriptionCount = 0
  $sourceArtifactWalletCount = 0
  $sourceArtifactUserKeyCount = 0
  foreach ($artifact in $SourceSpecificApplyPlanArtifacts) {
    $inner = if ($null -ne $artifact.artifacts) { $artifact.artifacts } else { $artifact }
    $categories = Get-PropertyValue $inner @("categories") $null
    $manual = Get-PropertyValue $categories @("manual") $null
    $blocked = Get-PropertyValue $categories @("blocked") $null
    $sourceArtifactSubscriptionCount += @(Convert-ToObjectArray (Get-PropertyValue $manual @("subscription_mappings") @())).Count
    $sourceArtifactWalletCount += @(Convert-ToObjectArray (Get-PropertyValue $manual @("wallet_opening_balance_candidates") @())).Count
    $sourceArtifactUserKeyCount += @(Convert-ToObjectArray (Get-PropertyValue $blocked @("user_key_reissue_handoffs") @())).Count
  }

  return [ordered]@{
    schema_version = "importer.mapping-quality-readback.v1"
    source_system = "reviewed-apply-plan"
    status = if ($PreflightStatus -eq "pass") { "ready-for-reviewed-apply-plan" } else { "blocked" }
    dry_run_only = $true
    secret_safe = $true
    mapping_counts = [ordered]@{
      provider_mappings = $ProviderPreviews.Count
      channel_mappings = $ChannelPreviews.Count + $ChannelMappingEntries.Count
      model_mappings = $Associations.Count + $ChannelMappingEntries.Count
      canonical_model_candidates = $CanonicalModels.Count
      user_mappings = 0
      key_mappings = $ProviderKeyHandoffs.Count + $sourceArtifactUserKeyCount
      provider_key_handoffs = $ProviderKeyHandoffs.Count
      user_key_reissue_handoffs = $sourceArtifactUserKeyCount
      wallet_mappings = $sourceArtifactWalletCount
      subscription_mappings = $sourceArtifactSubscriptionCount
      planned_creates = $PlannedCreates.Count
      planned_updates = $PlannedUpdates.Count
      planned_skips = $PlannedSkips.Count
      non_migratable_items = $skipReasons.Count
      conflicts = $Conflicts.Count
    }
    conflicts = [ordered]@{
      count = $Conflicts.Count
      blocking_count = $BlockingConflictCount
      refs = $conflictRefs
    }
    non_migratable_reasons = $skipReasons
    operator_handoff_refs_presence = [ordered]@{
      provider_key_handoffs_present = $ProviderKeyHandoffs.Count -gt 0
      provider_key_handoff_refs_present = $ProviderKeyHandoffs.Count -gt 0
      user_key_reissue_refs_present = $sourceArtifactUserKeyCount -gt 0
      wallet_opening_balance_refs_present = $sourceArtifactWalletCount -gt 0
      subscription_mapping_refs_present = $sourceArtifactSubscriptionCount -gt 0
      required_operator_path_present = $ProviderKeyHandoffs.Count -gt 0 -or $sourceArtifactUserKeyCount -gt 0
    }
    safe_next_action = if ($PreflightStatus -eq "pass") {
      "Review write operations, rollback/idempotency contracts, and operator handoff refs before any live runner invocation."
    } else {
      "Resolve blocking conflicts and skipped mappings; do not run live apply while preflight is blocked."
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
  -ProviderPreviews @(Convert-ToObjectArray $allProviderPreviews) `
  -ChannelPreviews @(Convert-ToObjectArray $allChannelPreviews) `
  -CanonicalModels @(Convert-ToObjectArray $allCanonicalModels) `
  -Associations @(Convert-ToObjectArray $allAssociations) `
  -ChannelMappingEntries @(Convert-ToObjectArray $allChannelMappingEntries) `
  -ProviderKeyHandoffs @(Convert-ToObjectArray $providerKeyHandoffSidecars) `
  -Conflicts @(Convert-ToObjectArray $allConflicts) `
  -BlockingConflictCount $blockingConflictCount `
  -PlannedCreates @(Convert-ToObjectArray $plannedCreates) `
  -PlannedUpdates @(Convert-ToObjectArray $plannedUpdates) `
  -PlannedSkips @(Convert-ToObjectArray $plannedSkips) `
  -SourceSpecificApplyPlanArtifacts @(Convert-ToObjectArray $sourceSpecificApplyPlanArtifacts) `
  -PreflightStatus $preflightStatus

$report = [ordered]@{
  importer = "importer-apply-plan-dryrun"
  schema_version = "importer.apply-plan.v1"
  dry_run = $true
  generated_at = (Get-Date).ToUniversalTime().ToString("o")
  input_files = $inputFilePaths
  idempotency_key = $planIdempotencyKey
  apply_supported = $false
  sql_plan_executor_supported = $true
  apply_blocked = ($preflightStatus -ne "pass")
  apply_contract = [ordered]@{
    default_mode = "dry_run_sql_plan"
    real_apply_status = $realApplyStatus
    apply_requested = $script:ApplyRequested
    force_confirmed = $script:ForceConfirmed
    executor = $script:ApplyExecutor
    executor_status = $sqlExecutorPlan.executor_status
    real_apply_requires = @("-Apply", "-Force", "preflight_status=pass", "source_provider_channel_bindings=pass", "provider_key_secret_management_handoff=pass", "supported_sql_adapters", "live_postgresql_runner")
    database_writes = $false
    live_database_connection = $false
    refusal_reason = $applyRefusalReason
    real_database_write_refusal_reason = $realDatabaseWriteRefusalReason
    refusal_contract_schema = $sqlExecutorPlan.refusal_contract.schema_version
    preflight_status = $preflightStatus
    transaction_contract_schema = $transactionContract.schema_version
    sql_executor_plan_schema = $sqlExecutorPlan.schema_version
    journal_contract_schema = $sqlExecutorPlan.journal_contract.schema_version
    rollback_journal_sql_plan_schema = $sqlExecutorPlan.journal_contract.sql_plan.schema_version
    rollback_operation_plan_schema = $sqlExecutorPlan.rollback_operation_plan.schema_version
    rollback_execution_refusal_contract_schema = $sqlExecutorPlan.rollback_operation_plan.refusal_contract.schema_version
    rollback_snapshot_schema = "importer.rollback-snapshot.v1"
    idempotency_manifest_schema = $idempotencyManifest.schema_version
  }
  preflight = $preflight
  transaction_contract = $transactionContract
  sql_executor_plan = $sqlExecutorPlan
  idempotency_manifest = $idempotencyManifest
  existing_state = $existingStateSummary
  source_reports = @(Convert-ToObjectArray $inputReportSummaries)
  source_binding_contract = [ordered]@{
    schema_version = "importer.source-provider-channel-binding-contract.v1"
    required_for_target_kinds = @("model_association", "channel_mapping_entry")
    required_fields = @("channel_source_id", "provider_code or internal_provider_id", "internal_channel_id")
    secret_material_allowed = $false
    bindings = @(Convert-ToObjectArray $sourceChannelBindings.Values)
  }
  source_specific_apply_plan_artifacts = @(Convert-ToObjectArray $sourceSpecificApplyPlanArtifacts)
  provider_key_handoff_contract = [ordered]@{
    schema_version = "importer.provider-key-handoff-contract.v1"
    mode = "sidecar_only"
    raw_material_allowed = $false
    apply_directly_supported = $false
    required_operator_path = "POST /admin/provider-keys"
    target_table = "provider_keys"
    target_secret_columns = @("encrypted_secret", "secret_fingerprint")
    handoff_count = $providerKeyHandoffSidecars.Count
    warnings = $providerKeyHandoffValidation.warnings
  }
  provider_key_handoffs = @(Convert-ToObjectArray $providerKeyHandoffSidecars)
  counts = $counts
  mapping_quality_readback = $mappingQualityReadback
  target_counts = $targetCounts
  planned_creates = @(Convert-ToObjectArray $plannedCreates)
  planned_updates = @(Convert-ToObjectArray $plannedUpdates)
  planned_skips = @(Convert-ToObjectArray $plannedSkips)
  conflicts = @(Convert-ToObjectArray $allConflicts)
  rollback_snapshot = [ordered]@{
    schema_version = "importer.rollback-snapshot.v1"
    snapshot_mode = "dry_run_shape_only"
    captured_before_apply = $false
    database_writes = $false
    idempotency_key = $rollbackSnapshotKey
    entry_schema = $sqlExecutorPlan.rollback_contract.entry_schema
    operation_ids = @($writeOperations | ForEach-Object { $_.operation_id } | Sort-Object)
    entries = @(Convert-ToObjectArray $rollbackEntries)
    storage_hint = "The PostgreSQL SQL executor plan contains per-operation SELECT ... FOR UPDATE before-image capture statements; a future live runner must persist those results before each mutation."
  }
  next_steps = @(
    "Resolve blocking conflicts before running the live apply path; supported live runners must refuse blocked preflight with no database writes.",
    "Run provider, channel, canonical_model, bound explicit-channel model_association, and simple channel_mapping_entry SQL adapters through the live PostgreSQL runner; provider key creation remains a Control Plane operator action.",
    "Review generated source channel bindings before apply; missing source channels and requested-model conflicts still block database writes.",
    "Review provider_key_handoffs and enter provider keys through POST /admin/provider-keys before routing production traffic to imported channels.",
    "Persist rollback_snapshot and idempotency journal rows before each mutation when a live PostgreSQL runner is added.",
    "Provider key material is intentionally outside this plan and must use the secret-management path; this plan must never write provider_keys.encrypted_secret directly."
  )
}

$json = $report | ConvertTo-Json -Depth 96
$safeJson = Redact-SecretLikeString $json
if ($safeJson -match "((?<![A-Za-z])[A-Za-z]:[\\/]|\\\\(?!u[0-9A-Fa-f]{4})[^\\/`"\s]+[\\/])") {
  throw "Refusing to emit apply plan because output still contains an absolute local path."
}
if ($safeJson -match "sk-[A-Za-z0-9_-]+" -or $safeJson -match "(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}" -or $safeJson -match "(?i)(api[_-]?key|authorization|token|password)=([^<][^&\s`"]+)") {
  throw "Refusing to emit apply plan because output still contains secret-like material."
}

Write-Output $safeJson
