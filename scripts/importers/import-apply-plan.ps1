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

function Get-SqlExecutorSupport {
  param([object]$Operation)

  $kind = Convert-ToSafeText (Get-PropertyValue $Operation.target @("kind") "unknown")
  switch ($kind) {
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
      return [ordered]@{
        operation_id = $Operation.operation_id
        target = $Operation.target
        supported = $false
        adapter = "model_associations_pending_v1"
        reason = "model_association importer data still carries requested_model/source channel ids; DB schema requires canonical_model_id/channel_id binding before a safe writer can run"
      }
    }
    "channel_mapping_entry" {
      return [ordered]@{
        operation_id = $Operation.operation_id
        target = $Operation.target
        supported = $false
        adapter = "channel_model_mappings_pending_v1"
        reason = "channel mapping writes require source channel to internal channel binding and a channel model_mappings merge adapter"
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

    if ($operation.target.kind -eq "canonical_model") {
      $operationPlans.Add((New-PostgreSqlCanonicalModelOperationPlan $operation $TenantId)) | Out-Null
    }
  }

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
    }
    journal_contract = [ordered]@{
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
    }
    refusal_contract = [ordered]@{
      schema_version = "importer.apply-refusal-contract.v1"
      refuse_apply_when = @(
        "missing -Force with -Apply",
        "DryRun is false",
        "preflight_status is not pass",
        "blocking_conflicts preflight fails",
        "source_provider_channel_bindings preflight fails",
        "write_operations_supported_by_sql_executor preflight fails",
        "rollback_snapshot_shape preflight fails",
        "write idempotency keys are duplicated",
        "live PostgreSQL runner is unavailable"
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
    transaction = [ordered]@{
      transaction_id = $TransactionId
      isolation_hint = "single PostgreSQL transaction with row-level FOR UPDATE before-image capture"
      begin_sql = "begin;"
      advisory_lock_sql = "select pg_advisory_xact_lock(hashtextextended(:plan_idempotency_key, 0));"
      commit_sql = "commit;"
      rollback_sql = "rollback;"
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
  canonical_model = @{}
  model_association = @{}
  channel_mapping_entry = @{}
}
$existingStateSummary = [ordered]@{
  provided = $false
  input_file = $null
  counts = [ordered]@{
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

  $existingStateSummary.counts.canonical_models = $existingIndex.canonical_model.Count
  $existingStateSummary.counts.model_associations = $existingIndex.model_association.Count
  $existingStateSummary.counts.channel_mapping_entries = $existingIndex.channel_mapping_entry.Count
}

$inputFiles = Get-InputFiles $InputPath
$inputFilePaths = @($inputFiles | ForEach-Object { Get-RepoRelativePath $_.FullName })
$inputReportSummaries = New-Object System.Collections.Generic.List[object]
$allConflicts = New-Object System.Collections.Generic.List[object]
$allCanonicalModels = New-Object System.Collections.Generic.List[object]
$allAssociations = New-Object System.Collections.Generic.List[object]
$allChannelMappingEntries = New-Object System.Collections.Generic.List[object]
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

  foreach ($mapping in (Convert-ToImportArray (Get-PropertyValue $report @("channel_mappings") $null))) {
    $channelSourceId = Convert-ToSafeText (Get-PropertyValue $mapping @("channel_source_id") $null)
    $binding = New-SourceChannelBindingRef $mapping
    if ($null -ne $binding -and -not [string]::IsNullOrWhiteSpace($channelSourceId)) {
      $sourceChannelBindings[$channelSourceId] = $binding
    }
    $channelPresent = [bool](Get-PropertyValue $mapping @("channel_present") $true)
    foreach ($entry in (Convert-ToImportArray (Get-PropertyValue $mapping @("mapping_entries") $null))) {
      $safeEntry = Convert-ToSafeObject $entry
      if ($null -eq (Get-PropertyValue $safeEntry @("channel_source_id") $null)) {
        $safeEntry["channel_source_id"] = $channelSourceId
      }
      $safeEntry["channel_present"] = $channelPresent
      $allChannelMappingEntries.Add($safeEntry) | Out-Null
    }
  }
}

$plannedCreates = New-Object System.Collections.Generic.List[object]
$plannedUpdates = New-Object System.Collections.Generic.List[object]
$plannedSkips = New-Object System.Collections.Generic.List[object]
$emittedTargets = @{}

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
  $naturalKey = Get-AssociationNaturalKey $association
  $requestedModel = Convert-ToSafeText (Get-PropertyValue $association @("requested_model", "client_model", "source_model") $null)
  $channelSourceId = Convert-ToSafeText (Get-PropertyValue $association @("channel_source_id", "source_channel_id") $null)
  $conflictRefs = New-Object System.Collections.Generic.List[object]
  if (-not [string]::IsNullOrWhiteSpace($requestedModel) -and $blockedRequestedModels.ContainsKey($requestedModel)) {
    $conflictRefs.Add($blockedRequestedModels[$requestedModel]) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace($channelSourceId) -and $blockedChannels.ContainsKey($channelSourceId)) {
    $conflictRefs.Add($blockedChannels[$channelSourceId]) | Out-Null
  }

  if ($conflictRefs.Count -gt 0) {
    $operation = New-PlanOperation "skip" "model_association" $naturalKey $association $null "blocked_by_conflict" (Convert-ToObjectArray $conflictRefs)
    Add-Operation $plannedCreates $plannedUpdates $plannedSkips $emittedTargets $operation
    continue
  }

  if ([string]::IsNullOrWhiteSpace($requestedModel)) {
    $operation = New-PlanOperation "skip" "model_association" $naturalKey $association $null "missing_requested_model" @()
    Add-Operation $plannedCreates $plannedUpdates $plannedSkips $emittedTargets $operation
    continue
  }

  $actionInfo = Get-PlannedAction $existingIndex "model_association" $naturalKey $association
  $operation = New-PlanOperation $actionInfo.action "model_association" $naturalKey $association $actionInfo.before $actionInfo.reason @()
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
if ($script:ApplyRequested) {
  if ($preflightStatus -eq "pass") {
    $applyExecutionStatus = "prepared_sql_plan"
    $realApplyStatus = "prepared_sql_plan"
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
    "apply_operations_in_order",
    "commit_or_restore_from_rollback_snapshot"
  )
}

$targetCounts = [ordered]@{}
foreach ($kind in @("canonical_model", "model_association", "channel_mapping_entry")) {
  $targetCounts[$kind] = [ordered]@{
    creates = @($plannedCreates | Where-Object { $_.target.kind -eq $kind }).Count
    updates = @($plannedUpdates | Where-Object { $_.target.kind -eq $kind }).Count
    skips = @($plannedSkips | Where-Object { $_.target.kind -eq $kind }).Count
  }
}

$counts = [ordered]@{
  input_reports = $inputFiles.Count
  source_canonical_models = $allCanonicalModels.Count
  source_model_associations = $allAssociations.Count
  source_channel_mapping_entries = $allChannelMappingEntries.Count
  planned_creates = $plannedCreates.Count
  planned_updates = $plannedUpdates.Count
  planned_skips = $plannedSkips.Count
  operations = $plannedCreates.Count + $plannedUpdates.Count + $plannedSkips.Count
  conflicts = $allConflicts.Count
  blocking_conflicts = $blockingConflictCount
  rollback_snapshot_entries = $rollbackEntries.Count
  source_channel_bindings = $sourceChannelBindings.Count
}

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
    real_apply_requires = @("-Apply", "-Force", "preflight_status=pass", "source_provider_channel_bindings=pass", "supported_sql_adapters", "live_postgresql_runner")
    database_writes = $false
    live_database_connection = $false
    refusal_reason = $applyRefusalReason
    refusal_contract_schema = $sqlExecutorPlan.refusal_contract.schema_version
    preflight_status = $preflightStatus
    transaction_contract_schema = $transactionContract.schema_version
    sql_executor_plan_schema = $sqlExecutorPlan.schema_version
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
  counts = $counts
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
    "Resolve blocking conflicts before any real apply path is implemented.",
    "Run only canonical_model SQL adapters until model association requested-model aliases and source channel bindings are implemented.",
    "Bind source channel ids to internal provider/channel records before writing model associations or channel mappings.",
    "Persist rollback_snapshot and idempotency journal rows before each mutation when a live PostgreSQL runner is added.",
    "Provider key material is intentionally outside this plan and must use the secret-management path."
  )
}

$json = $report | ConvertTo-Json -Depth 96
$safeJson = Redact-SecretLikeString $json
if ($safeJson -match "([A-Za-z]:[\\/]|\\\\[^\\/`"\s]+[\\/])") {
  throw "Refusing to emit apply plan because output still contains an absolute local path."
}
if ($safeJson -match "sk-[A-Za-z0-9_-]+" -or $safeJson -match "(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}" -or $safeJson -match "(?i)(api[_-]?key|authorization|token|password)=([^<][^&\s`"]+)") {
  throw "Refusing to emit apply plan because output still contains secret-like material."
}

Write-Output $safeJson
