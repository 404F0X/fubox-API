[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$InputPath,

  [string]$ExistingStatePath,

  [string]$TenantId = "00000000-0000-0000-0000-000000000001",

  [string]$DemoDbPath = ".tmp\importers\import_apply_live_demo_db.json",

  [string]$ArtifactPath = ".tmp\importers\import_apply_live_demo_runtime.json",

  [switch]$RollbackAfterApply,

  [switch]$ConfirmReviewedPlan,

  [switch]$Force
)

$ErrorActionPreference = "Stop"

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$script:ApplyPlanScript = Join-Path $script:RepoRoot "scripts\importers\import-apply-plan.ps1"
$script:TenantId = $TenantId

function Convert-ToArray {
  param([AllowNull()][object]$Value)
  if ($null -eq $Value) { return @() }
  if ($Value -is [string]) { return @($Value) }
  if ($Value -is [System.Collections.IEnumerable]) {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($item in $Value) { [void]$items.Add($item) }
    return @($items.ToArray())
  }
  return @($Value)
}

function ConvertTo-JsonText {
  param([AllowNull()][object]$Value)
  if ($null -eq $Value) { return "null" }
  return ($Value | ConvertTo-Json -Depth 96 -Compress)
}

function Get-StableHash {
  param(
    [AllowNull()][object]$Value,
    [int]$Length = 16
  )

  $text = if ($Value -is [string]) { [string]$Value } else { ConvertTo-JsonText $Value }
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))
  } finally {
    $sha.Dispose()
  }
  $hash = ([System.BitConverter]::ToString($hashBytes)).Replace("-", "").ToLowerInvariant()
  if ($Length -gt 0 -and $Length -lt $hash.Length) { return $hash.Substring(0, $Length) }
  return $hash
}

function Redact-SecretLikeString {
  param([AllowNull()][object]$Value)
  if ($null -eq $Value) { return $null }
  $text = [string]$Value
  $text = $text -replace "\$\{[A-Za-z_][A-Za-z0-9_]*(KEY|TOKEN|SECRET|PASSWORD)[A-Za-z0-9_]*\}", "<redacted-env>"
  $text = $text -replace "(?i)\benv:[A-Z0-9_]*(KEY|TOKEN|SECRET|PASSWORD)[A-Z0-9_]*\b", "env:<redacted>"
  $text = $text -replace "sk-[A-Za-z0-9_-]+", "<redacted>"
  $text = $text -replace "(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+", '$1<redacted>'
  $text = $text -replace "(?i)(api[_-]?key|authorization|bearer|token|secret|password)=([^&\s""]+)", '$1=<redacted>'
  return $text
}

function Convert-ToSecretSafeObject {
  param(
    [AllowNull()][object]$Value,
    [string]$FieldName = ""
  )

  if ($null -eq $Value) { return $null }
  if ($FieldName -match "(?i)(^|_)(input|output|cache_read|cache_write|reasoning|max_output)_tokens?$") {
    return $Value
  }
  if ($FieldName -match "(?i)(api[_-]?key|authorization|bearer|token|secret|password|encrypted_secret|raw_payload|payload)") {
    return "<redacted>"
  }
  if ($Value -is [string]) { return Redact-SecretLikeString $Value }
  if ($Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [decimal] -or $Value -is [double]) {
    return $Value
  }
  if ($Value -is [System.Collections.IDictionary]) {
    $safe = [ordered]@{}
    foreach ($key in $Value.Keys) {
      $keyText = [string]$key
      $safe[$keyText] = Convert-ToSecretSafeObject $Value[$key] $keyText
    }
    return $safe
  }
  if ($Value -is [System.Collections.IEnumerable]) {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($item in $Value) { [void]$items.Add((Convert-ToSecretSafeObject $item $FieldName)) }
    return @($items.ToArray())
  }
  $safeObject = [ordered]@{}
  foreach ($property in $Value.PSObject.Properties) {
    $safeObject[$property.Name] = Convert-ToSecretSafeObject $property.Value $property.Name
  }
  return $safeObject
}

function Resolve-RepoPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
  return (Join-Path $script:RepoRoot $Path)
}

function Invoke-ApplyPlan {
  $args = @{
    InputPath = $InputPath
    Apply = $true
    Force = $true
    TenantId = $script:TenantId
  }
  if (-not [string]::IsNullOrWhiteSpace($ExistingStatePath)) {
    $args["ExistingStatePath"] = $ExistingStatePath
  }
  $raw = (& $script:ApplyPlanScript @args | Out-String).Trim()
  if ([string]::IsNullOrWhiteSpace($raw)) {
    throw "import-apply-plan produced no output"
  }
  return ($raw | ConvertFrom-Json)
}

function New-EmptyDemoDb {
  return [ordered]@{
    schema_version = "importer.apply-live-demo-db.v1"
    tenant_id = $script:TenantId
    targets = [ordered]@{}
    runs = @()
    operation_journal = @()
  }
}

function Read-DemoDb {
  $path = Resolve-RepoPath $DemoDbPath
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    return New-EmptyDemoDb
  }
  $db = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
  if ($null -eq $db.targets) { $db | Add-Member -NotePropertyName targets -NotePropertyValue ([ordered]@{}) }
  if ($null -eq $db.runs) { $db | Add-Member -NotePropertyName runs -NotePropertyValue @() }
  if ($null -eq $db.operation_journal) { $db | Add-Member -NotePropertyName operation_journal -NotePropertyValue @() }
  $targetMap = [ordered]@{}
  foreach ($property in $db.targets.PSObject.Properties) {
    $targetMap[$property.Name] = $property.Value
  }
  $db.targets = $targetMap
  return $db
}

function Write-JsonFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Value
  )
  $full = Resolve-RepoPath $Path
  $dir = Split-Path -Parent $full
  if (-not (Test-Path -LiteralPath $dir)) {
    [void](New-Item -ItemType Directory -Force -Path $dir)
  }
  $json = $Value | ConvertTo-Json -Depth 96
  $safeJson = Redact-SecretLikeString $json
  if ($safeJson -match "sk-[A-Za-z0-9_-]+" -or $safeJson -match "(?i)authorization\s*[:=]\s*(`"Bearer|Bearer)\s+[A-Za-z0-9._~+/=-]{8,}" -or $safeJson -match "(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}") {
    throw "Refusing to write import apply-live demo artifact because it still contains secret-like material."
  }
  Set-Content -LiteralPath $full -Value $safeJson -Encoding UTF8
}

function Get-TargetKey {
  param([Parameter(Mandatory = $true)]$OperationPlan)
  return "$($OperationPlan.target.kind):$($OperationPlan.target.natural_key_hash)"
}

function Get-PlanWriteOperation {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)][string]$OperationId
  )
  $writes = @(Convert-ToArray $Plan.planned_creates) + @(Convert-ToArray $Plan.planned_updates)
  $match = @($writes | Where-Object { [string]$_.operation_id -eq $OperationId } | Select-Object -First 1)
  if ($match.Count -ne 1) { throw "write operation '$OperationId' was not found in apply plan" }
  return $match[0]
}

function Get-TargetValue {
  param(
    [Parameter(Mandatory = $true)]$DemoDb,
    [Parameter(Mandatory = $true)][string]$TargetKey
  )
  if ($DemoDb.targets -is [System.Collections.IDictionary] -and $DemoDb.targets.Contains($TargetKey)) {
    return $DemoDb.targets[$TargetKey]
  }
  return $null
}

function Set-TargetValue {
  param(
    [Parameter(Mandatory = $true)]$DemoDb,
    [Parameter(Mandatory = $true)][string]$TargetKey,
    [AllowNull()][object]$Value
  )
  if ($DemoDb.targets -isnot [System.Collections.IDictionary]) {
    throw "demo DB targets must be a dictionary"
  }
  $DemoDb.targets[$TargetKey] = $Value
}

function Remove-TargetValue {
  param(
    [Parameter(Mandatory = $true)]$DemoDb,
    [Parameter(Mandatory = $true)][string]$TargetKey
  )
  if ($DemoDb.targets -is [System.Collections.IDictionary] -and $DemoDb.targets.Contains($TargetKey)) {
    $DemoDb.targets.Remove($TargetKey)
  }
}

if (-not $Force) {
  throw "Demo apply-live requires -Force because it mutates the local demo DB JSON file."
}
if (-not $ConfirmReviewedPlan) {
  throw "Demo apply-live requires -ConfirmReviewedPlan after the apply-plan diff, idempotency manifest, rollback snapshot, and provider-key handoff have been reviewed."
}

$status = "pass"
$blockers = New-Object System.Collections.Generic.List[string]
$plan = $null
$db = $null
$applyOperations = New-Object System.Collections.Generic.List[object]
$rollbackOperations = New-Object System.Collections.Generic.List[object]
$idempotencyEvents = New-Object System.Collections.Generic.List[object]

try {
  $plan = Invoke-ApplyPlan
  if ([string]$plan.preflight.status -ne "pass") {
    [void]$blockers.Add("apply_plan_preflight_not_pass")
  }
  if ([string]$plan.sql_executor_plan.executor_status -ne "prepared_sql_plan") {
    [void]$blockers.Add("apply_plan_not_prepared_sql_plan")
  }
  foreach ($operationPlan in @(Convert-ToArray $plan.sql_executor_plan.transaction.operation_plans)) {
    if (-not [bool]$operationPlan.supported) {
      [void]$blockers.Add("unsupported_operation:$($operationPlan.operation_id)")
    }
  }

  if ($blockers.Count -eq 0) {
    $db = Read-DemoDb
    $transactionId = [string]$plan.transaction_contract.transaction_id
    $run = [ordered]@{
      transaction_id = $transactionId
      plan_idempotency_key = [string]$plan.sql_executor_plan.plan_idempotency_key
      rollback_snapshot_idempotency_key = [string]$plan.sql_executor_plan.rollback_snapshot_idempotency_key
      idempotency_manifest_key = [string]$plan.sql_executor_plan.idempotency_manifest_key
      status = "prepared"
      applied_at_utc = [DateTimeOffset]::UtcNow.ToString("O")
      reviewed_plan_confirmed = [bool]$ConfirmReviewedPlan
    }

    foreach ($operationPlan in @(Convert-ToArray $plan.sql_executor_plan.transaction.operation_plans)) {
      $write = Get-PlanWriteOperation -Plan $plan -OperationId ([string]$operationPlan.operation_id)
      $targetKey = Get-TargetKey $operationPlan
      $before = Get-TargetValue -DemoDb $db -TargetKey $targetKey
      $after = Convert-ToSecretSafeObject $write.after
      $afterHash = Get-StableHash $after 32
      $existingHash = if ($null -eq $before) { $null } else { Get-StableHash $before 32 }
      $sameAfter = ($null -ne $existingHash -and $existingHash -eq $afterHash)
      $operationStatus = if ($sameAfter) { "skipped_same_after_hash" } else { "applied" }
      $rollbackAction = if ($null -eq $before) { "delete_created_object" } else { "restore_previous_object" }
      $beforeImage = [ordered]@{
        schema_version = "importer.before-image.v1"
        object_exists = ($null -ne $before)
        object_hash = $existingHash
        object = $before
        capture_mode = if ($null -eq $before) { "demo_db_not_found" } else { "demo_db_before_apply" }
        dry_run_shape_only = $false
        required_for_rollback = $true
      }
      $journalEntry = [ordered]@{
        snapshot_entry_id = [string]$operationPlan.rollback_snapshot_entry_id
        transaction_id = $transactionId
        operation_id = [string]$operationPlan.operation_id
        operation_idempotency_key = [string]$operationPlan.idempotency_key
        target_kind = [string]$operationPlan.target.kind
        target_natural_key_hash = [string]$operationPlan.target.natural_key_hash
        target_key = $targetKey
        rollback_action = $rollbackAction
        before_image = $beforeImage
        after_hash = $afterHash
        status = $operationStatus
      }
      $db.operation_journal = @($db.operation_journal) + $journalEntry
      [void]$applyOperations.Add([ordered]@{
          operation_id = [string]$operationPlan.operation_id
          target_kind = [string]$operationPlan.target.kind
          status = $operationStatus
          rollback_action = $rollbackAction
          before_image_object_exists = ($null -ne $before)
        })
      [void]$idempotencyEvents.Add([ordered]@{
          operation_id = [string]$operationPlan.operation_id
          operation_idempotency_key_fingerprint = Get-StableHash ([string]$operationPlan.idempotency_key) 16
          target_kind = [string]$operationPlan.target.kind
          target_natural_key_hash = [string]$operationPlan.target.natural_key_hash
          result = if ($sameAfter) { "duplicate_same_after_hash" } else { "applied" }
        })
      if (-not $sameAfter) {
        Set-TargetValue -DemoDb $db -TargetKey $targetKey -Value $after
      }
    }

    $run.status = "applied"
    $db.runs = @($db.runs) + $run

    if ($RollbackAfterApply) {
      $currentTransactionEntries = @(Convert-ToArray $db.operation_journal | Where-Object { [string]$_.transaction_id -eq $transactionId })
      [array]::Reverse($currentTransactionEntries)
      foreach ($entry in $currentTransactionEntries) {
        if ([string]$entry.status -eq "skipped_same_after_hash") {
          [void]$rollbackOperations.Add([ordered]@{
              operation_id = [string]$entry.operation_id
              target_kind = [string]$entry.target_kind
              status = "skipped_same_after_hash"
              rollback_action = [string]$entry.rollback_action
            })
          continue
        }
        if ([bool]$entry.before_image.object_exists) {
          Set-TargetValue -DemoDb $db -TargetKey ([string]$entry.target_key) -Value $entry.before_image.object
        } else {
          Remove-TargetValue -DemoDb $db -TargetKey ([string]$entry.target_key)
        }
        $entry.status = "rolled_back"
        [void]$rollbackOperations.Add([ordered]@{
            operation_id = [string]$entry.operation_id
            target_kind = [string]$entry.target_kind
            status = "rolled_back"
            rollback_action = [string]$entry.rollback_action
          })
      }
      $run.status = "rolled_back"
    }

    Write-JsonFile -Path $DemoDbPath -Value $db
  }
} catch {
  $status = "fail"
  [void]$blockers.Add($_.Exception.Message)
}

if ($blockers.Count -gt 0) {
  $status = "fail"
}

$applyEvents = @($applyOperations.ToArray())
$rollbackEvents = @($rollbackOperations.ToArray())
$idempotencyEventArray = @($idempotencyEvents.ToArray())
$applyCount = $applyEvents.Count
$idempotentSkipCount = @($idempotencyEventArray | Where-Object { [string]$_.result -eq "duplicate_same_after_hash" }).Count
$artifact = [ordered]@{
  importer = "importer-apply-live-demo-runtime"
  schema = "importer_apply_live_demo_runtime.v1"
  schema_version = "importer.apply-live-demo-runtime.v1"
  generated_at_utc = [DateTimeOffset]::UtcNow.ToString("O")
  status = $status
  dry_run = $false
  input_path = $InputPath
  existing_state_path = if ([string]::IsNullOrWhiteSpace($ExistingStatePath)) { $null } else { $ExistingStatePath }
  tenant_id = $script:TenantId
  demo_db_path = ($DemoDbPath -replace "\\", "/")
  apply_supported = $true
  apply_blocked = ($status -ne "pass")
  local_demo_db = $true
  live_database_connection = $false
  database_writes = ($status -eq "pass")
  reviewed_plan_confirmed = [bool]$ConfirmReviewedPlan
  rollback_after_apply = [bool]$RollbackAfterApply
  secret_safe = $true
  artifact_secret_safe = $true
  raw_sql_omitted = $true
  raw_payload_omitted = $true
  authorization_omitted = $true
  provider_key_material_allowed = $false
  provider_key_material_written = $false
  raw_token_material_written = $false
  apply_contract = [ordered]@{
    default_mode = "local_json_demo_db_apply_live"
    real_apply_status = if ($status -eq "pass") { "local_demo_apply_live_pass" } else { "local_demo_apply_live_failed" }
    apply_requested = $true
    force_confirmed = [bool]$Force
    reviewed_plan_confirmed = [bool]$ConfirmReviewedPlan
    executor = "scripts/importers/invoke-import-apply-live-demo.ps1"
    executor_status = if ($status -eq "pass") { "applied" } else { "failed_or_refused" }
    database_writes = ($status -eq "pass")
    live_database_connection = $false
    local_demo_db = $true
    demo_db_path = ($DemoDbPath -replace "\\", "/")
    rollback_after_apply = [bool]$RollbackAfterApply
    provider_key_material_allowed = $false
    raw_sql_omitted = $true
    raw_payload_omitted = $true
    artifact_secret_safe = $true
  }
  plan = if ($null -eq $plan) { $null } else { [ordered]@{
      schema_version = [string]$plan.schema_version
      preflight_status = [string]$plan.preflight.status
      transaction_id = [string]$plan.transaction_contract.transaction_id
      plan_idempotency_key_fingerprint = Get-StableHash ([string]$plan.sql_executor_plan.plan_idempotency_key) 16
      rollback_snapshot_idempotency_key_fingerprint = Get-StableHash ([string]$plan.sql_executor_plan.rollback_snapshot_idempotency_key) 16
      idempotency_manifest_key_fingerprint = Get-StableHash ([string]$plan.sql_executor_plan.idempotency_manifest_key) 16
      executor_status = [string]$plan.sql_executor_plan.executor_status
      operation_count = @(Convert-ToArray $plan.sql_executor_plan.transaction.operation_plans).Count
      adapters = @(Convert-ToArray $plan.sql_executor_plan.transaction.operation_plans | ForEach-Object { [string]$_.adapter })
    } }
  apply_readback = [ordered]@{
    run = if ($null -eq $plan) { $null } else { [ordered]@{
        transaction_id = [string]$plan.transaction_contract.transaction_id
        status = if ($RollbackAfterApply -and $status -eq "pass") { "rolled_back" } elseif ($status -eq "pass") { "applied" } else { "failed" }
      } }
    operations = $applyEvents
  }
  rollback_readback = if ($RollbackAfterApply) { [ordered]@{
      run = if ($null -eq $plan) { $null } else { [ordered]@{
          transaction_id = [string]$plan.transaction_contract.transaction_id
          status = if ($status -eq "pass") { "rolled_back" } else { "failed" }
        } }
      operations = $rollbackEvents
    } } else { $null }
  rollback_journal = [ordered]@{
    schema_version = "importer.rollback-journal.demo.v1"
    storage = "local_json_demo_db"
    captured_before_apply = ($status -eq "pass")
    no_secret_material = $true
    entries = @($applyEvents | ForEach-Object {
        [ordered]@{
          operation_id = [string]$_.operation_id
          target_kind = [string]$_.target_kind
          rollback_action = [string]$_.rollback_action
          before_image_object_exists = [bool]$_.before_image_object_exists
          status = [string]$_.status
        }
      })
  }
  rollback_journal_summary = [ordered]@{
    schema_version = "importer.rollback-journal.summary.v1"
    storage = "local_json_demo_db"
    captured_before_apply = ($status -eq "pass")
    entries = $applyCount
    rolled_back_entries = @($rollbackEvents | Where-Object { [string]$_.status -eq "rolled_back" }).Count
    skipped_same_after_hash = @($rollbackEvents | Where-Object { [string]$_.status -eq "skipped_same_after_hash" }).Count
    no_secret_material = $true
  }
  idempotency_summary = [ordered]@{
    schema_version = "importer.idempotency-summary.v1"
    manifest_key_fingerprint = if ($null -eq $plan) { $null } else { Get-StableHash ([string]$plan.sql_executor_plan.idempotency_manifest_key) 16 }
    plan_key_fingerprint = if ($null -eq $plan) { $null } else { Get-StableHash ([string]$plan.sql_executor_plan.plan_idempotency_key) 16 }
    operation_count = $idempotencyEventArray.Count
    applied = @($idempotencyEventArray | Where-Object { [string]$_.result -eq "applied" }).Count
    duplicate_same_after_hash = $idempotentSkipCount
    raw_idempotency_keys_omitted = $true
    events = $idempotencyEventArray
  }
  artifact_policy = [ordered]@{
    schema_version = "importer.secret-safe-artifact-policy.v1"
    provider_key_allowed = $false
    authorization_header_allowed = $false
    raw_token_allowed = $false
    raw_payload_allowed = $false
    allowed_secret_references = @("alias", "fingerprint", "operator_handoff")
  }
  blockers = @($blockers.ToArray())
}

Write-JsonFile -Path $ArtifactPath -Value $artifact
$artifact | ConvertTo-Json -Depth 96

if ($status -ne "pass") {
  exit 1
}
