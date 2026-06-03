[CmdletBinding()]
param(
  [string]$InputPath,

  [string]$ExistingStatePath
)

$ErrorActionPreference = "Stop"

$scriptPath = $PSCommandPath
if (-not $scriptPath) {
  $scriptPath = $MyInvocation.MyCommand.Path
}

$script:RepoRoot = (Resolve-Path (Join-Path (Split-Path -Parent $scriptPath) "..\..")).Path
$script:ApplyPlanScript = Join-Path $script:RepoRoot "scripts\importers\import-apply-plan.ps1"
$script:SqlExecutorFixturePath = Join-Path $script:RepoRoot "tests\fixtures\importers\apply_plan_canonical_only.sample.json"
$script:SqlExecutorContractPath = Join-Path $script:RepoRoot "tests\fixtures\importers\postgresql_sql_executor_contract.expected.json"

if ([string]::IsNullOrWhiteSpace($InputPath)) {
  $InputPath = Join-Path $script:RepoRoot "examples\importer_samples\internal_mapping_report_output.sample.json"
}
if ([string]::IsNullOrWhiteSpace($ExistingStatePath)) {
  $ExistingStatePath = Join-Path $script:RepoRoot "examples\importer_samples\apply_plan_existing_state.sample.json"
}

function Assert-Condition {
  param(
    [bool]$Condition,
    [string]$Message
  )

  if (-not $Condition) {
    throw "VERIFY FAILED: $Message"
  }
}

function Assert-Equal {
  param(
    [AllowNull()][object]$Actual,
    [AllowNull()][object]$Expected,
    [string]$Message
  )

  if ($Actual -ne $Expected) {
    throw "VERIFY FAILED: $Message. Expected '$Expected', got '$Actual'."
  }
}

function Convert-ToArray {
  param([AllowNull()][object]$Value)

  if ($null -eq $Value) {
    return @()
  }

  if ($Value -is [string]) {
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

function Read-JsonObject {
  param([string]$Path)

  try {
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8) | ConvertFrom-Json
  } catch {
    throw "VERIFY FAILED: unable to read JSON fixture '$Path'. $($_.Exception.Message)"
  }
}

function Invoke-ApplyPlan {
  param(
    [string]$PlanInputPath,
    [string]$PlanExistingStatePath,
    [switch]$Apply,
    [switch]$Force
  )

  $arguments = @{
    InputPath = $PlanInputPath
  }
  if (-not [string]::IsNullOrWhiteSpace($PlanExistingStatePath)) {
    $arguments["ExistingStatePath"] = $PlanExistingStatePath
  }
  if ($Apply) {
    $arguments["Apply"] = $true
  }
  if ($Force) {
    $arguments["Force"] = $true
  }

  $output = & $script:ApplyPlanScript @arguments
  $raw = ($output | Out-String).Trim()
  Assert-Condition (-not [string]::IsNullOrWhiteSpace($raw)) "apply plan produced JSON output"

  try {
    $plan = $raw | ConvertFrom-Json
  } catch {
    throw "VERIFY FAILED: apply plan output was not valid JSON. $($_.Exception.Message)"
  }

  return [pscustomobject]@{
    Raw = $raw
    Plan = $plan
  }
}

function Get-PreflightCheck {
  param(
    [object]$Plan,
    [string]$Name
  )

  return @(Convert-ToArray $Plan.preflight.checks | Where-Object { $_.name -eq $Name } | Select-Object -First 1)
}

Assert-Condition (Test-Path -LiteralPath $script:ApplyPlanScript -PathType Leaf) "apply plan script exists"
Assert-Condition (Test-Path -LiteralPath $InputPath -PathType Leaf) "input sample exists"
Assert-Condition (Test-Path -LiteralPath $ExistingStatePath -PathType Leaf) "existing-state sample exists"
Assert-Condition (Test-Path -LiteralPath $script:SqlExecutorFixturePath -PathType Leaf) "sql executor canonical-only fixture exists"
Assert-Condition (Test-Path -LiteralPath $script:SqlExecutorContractPath -PathType Leaf) "sql executor contract fixture exists"

$sqlExecutorContract = Read-JsonObject $script:SqlExecutorContractPath

$dryRun = Invoke-ApplyPlan -PlanInputPath $InputPath
$dryRunAgain = Invoke-ApplyPlan -PlanInputPath $InputPath
Assert-NoSecretMaterial $dryRun.Raw
Assert-Equal $dryRun.Plan.importer "importer-apply-plan-dryrun" "importer name"
Assert-Equal $dryRun.Plan.apply_contract.database_writes $false "dry-run database_writes"
Assert-Equal $dryRun.Plan.sql_plan_executor_supported $true "sql plan executor support flag"
Assert-Equal $dryRun.Plan.sql_executor_plan.schema_version "importer.postgresql-sql-executor-plan.v1" "sql executor plan schema"
Assert-Equal $dryRun.Plan.idempotency_key $dryRunAgain.Plan.idempotency_key "plan idempotency key is stable"
Assert-Equal $dryRun.Plan.idempotency_manifest.manifest_key $dryRunAgain.Plan.idempotency_manifest.manifest_key "idempotency manifest key is stable"

$conflictCheck = Get-PreflightCheck $dryRun.Plan "blocking_conflicts"
Assert-Equal $conflictCheck.status "fail" "conflict preflight status"
$databaseWriterCheck = Get-PreflightCheck $dryRun.Plan "database_writer_available"
Assert-Equal $databaseWriterCheck.status "pass" "sql-plan database writer preflight status"
$unsupportedCheck = Get-PreflightCheck $dryRun.Plan "write_operations_supported_by_sql_executor"
Assert-Equal $unsupportedCheck.status "fail" "unsupported operation preflight status"
$sourceBindingCheck = Get-PreflightCheck $dryRun.Plan "source_provider_channel_bindings"
Assert-Equal $sourceBindingCheck.status "fail" "source provider/channel binding preflight status"
Assert-Condition (@(Convert-ToArray $sourceBindingCheck.details.errors | Where-Object { $_.reason -eq "missing_internal_channel_binding" }).Count -gt 0) "source binding preflight blocks missing internal channel bindings"
Assert-Equal $dryRun.Plan.source_binding_contract.schema_version "importer.source-provider-channel-binding-contract.v1" "source binding contract schema"
Assert-Equal $dryRun.Plan.source_binding_contract.secret_material_allowed $false "source binding contract excludes secret material"
Assert-Condition ([int]$dryRun.Plan.counts.blocking_conflicts -gt 0) "sample has blocking conflicts"
$blockedSkips = @(Convert-ToArray $dryRun.Plan.planned_skips | Where-Object { $_.reason -eq "blocked_by_conflict" })
Assert-Condition ($blockedSkips.Count -gt 0) "conflicts create blocked skip operations"

$idempotencyEntries = @(Convert-ToArray $dryRun.Plan.idempotency_manifest.entries)
Assert-Equal $idempotencyEntries.Count ([int]$dryRun.Plan.counts.rollback_snapshot_entries) "idempotency entries match planned writes"
$idempotencyKeys = @($idempotencyEntries | ForEach-Object { $_.idempotency_key })
$uniqueIdempotencyKeys = @($idempotencyKeys | Sort-Object -Unique)
Assert-Equal $idempotencyKeys.Count $uniqueIdempotencyKeys.Count "planned write idempotency keys are unique"
Assert-Condition ($idempotencyKeys.Count -gt 0) "idempotency manifest has write entries"

$rollbackShapeCheck = Get-PreflightCheck $dryRun.Plan "rollback_snapshot_shape"
Assert-Equal $rollbackShapeCheck.status "pass" "rollback snapshot shape preflight status"
$rollbackEntries = @(Convert-ToArray $dryRun.Plan.rollback_snapshot.entries)
Assert-Equal $rollbackEntries.Count ([int]$dryRun.Plan.counts.rollback_snapshot_entries) "rollback entry count"
foreach ($entry in $rollbackEntries) {
  Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$entry.snapshot_entry_id)) "rollback entry has snapshot_entry_id"
  Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$entry.operation_id)) "rollback entry has operation_id"
  Assert-Equal $entry.before_image.schema_version "importer.before-image.v1" "before-image schema"
  Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$entry.after_preview_hash)) "rollback entry has after_preview_hash"
  if ($entry.rollback_action -eq "delete_created_object") {
    Assert-Equal $entry.before_image.object_exists $false "create rollback before-image tombstone"
  }
}

$withExistingState = Invoke-ApplyPlan -PlanInputPath $InputPath -PlanExistingStatePath $ExistingStatePath
Assert-NoSecretMaterial $withExistingState.Raw
Assert-Condition ([int]$withExistingState.Plan.counts.planned_updates -gt 0) "existing-state fixture creates update operations"
$restoreEntries = @(Convert-ToArray $withExistingState.Plan.rollback_snapshot.entries | Where-Object { $_.rollback_action -eq "restore_previous_object" })
Assert-Condition ($restoreEntries.Count -gt 0) "update operations have restore rollback entries"
foreach ($entry in $restoreEntries) {
  Assert-Equal $entry.before_image.object_exists $true "update rollback before-image exists"
  Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$entry.before_image.object_hash)) "update rollback before-image has object_hash"
  Assert-Condition ($null -ne $entry.before_image.object) "update rollback before-image has object"
}

$applyForce = Invoke-ApplyPlan -PlanInputPath $InputPath -Apply -Force
Assert-NoSecretMaterial $applyForce.Raw
Assert-Equal $applyForce.Plan.apply_contract.apply_requested $true "apply contract records apply request"
Assert-Equal $applyForce.Plan.apply_contract.force_confirmed $true "apply contract records force confirmation"
Assert-Equal $applyForce.Plan.apply_contract.real_apply_status "blocked_by_preflight" "conflicted apply force is blocked by preflight"
Assert-Equal $applyForce.Plan.transaction_contract.execution_status "blocked_by_preflight" "transaction contract records preflight block"
Assert-Equal $applyForce.Plan.transaction_contract.database_writes $false "apply force makes no database writes"
Assert-Condition ((Convert-ToArray $applyForce.Plan.rollback_snapshot.entries).Count -gt 0) "apply force still emits rollback snapshot contract"

$sqlDryRun = Invoke-ApplyPlan -PlanInputPath $script:SqlExecutorFixturePath
Assert-NoSecretMaterial $sqlDryRun.Raw
Assert-Equal $sqlDryRun.Plan.preflight.status $sqlExecutorContract.expected.preflight_status "canonical-only sql executor fixture preflight status"
Assert-Equal $sqlDryRun.Plan.sql_executor_plan.executor_status $sqlExecutorContract.expected.dry_run_executor_status "canonical-only dry-run executor status"
Assert-Equal $sqlDryRun.Plan.sql_executor_plan.database_writes $sqlExecutorContract.expected.database_writes "sql executor dry-run database_writes"
Assert-Equal $sqlDryRun.Plan.sql_executor_plan.live_database_connection $sqlExecutorContract.expected.live_database_connection "sql executor dry-run live connection flag"
$sqlDryRunSourceBindingCheck = Get-PreflightCheck $sqlDryRun.Plan "source_provider_channel_bindings"
Assert-Equal $sqlDryRunSourceBindingCheck.status $sqlExecutorContract.expected.source_binding_preflight "canonical-only source binding preflight status"

$sqlApplyForce = Invoke-ApplyPlan -PlanInputPath $script:SqlExecutorFixturePath -Apply -Force
$sqlApplyForceAgain = Invoke-ApplyPlan -PlanInputPath $script:SqlExecutorFixturePath -Apply -Force
Assert-NoSecretMaterial $sqlApplyForce.Raw
Assert-Equal $sqlApplyForce.Plan.preflight.status $sqlExecutorContract.expected.preflight_status "canonical-only apply preflight status"
Assert-Equal $sqlApplyForce.Plan.apply_contract.real_apply_status $sqlExecutorContract.expected.apply_force_executor_status "canonical-only apply status"
Assert-Equal $sqlApplyForce.Plan.sql_executor_plan.executor_status $sqlExecutorContract.expected.apply_force_executor_status "canonical-only executor status"
Assert-Equal $sqlApplyForce.Plan.transaction_contract.execution_status $sqlExecutorContract.expected.apply_force_executor_status "canonical-only transaction status"
Assert-Equal $sqlApplyForce.Plan.sql_executor_plan.database_writes $sqlExecutorContract.expected.database_writes "sql executor apply database_writes"
Assert-Equal $sqlApplyForce.Plan.sql_executor_plan.live_database_connection $sqlExecutorContract.expected.live_database_connection "sql executor apply live connection flag"
Assert-Equal $sqlApplyForce.Plan.idempotency_manifest.manifest_key $sqlApplyForceAgain.Plan.idempotency_manifest.manifest_key "sql apply force idempotency manifest is stable"

$operationPlans = @(Convert-ToArray $sqlApplyForce.Plan.sql_executor_plan.transaction.operation_plans)
Assert-Condition ($operationPlans.Count -gt 0) "sql executor emits operation plans"
$canonicalPlan = @($operationPlans | Where-Object { $_.target.kind -eq "canonical_model" } | Select-Object -First 1)
Assert-Condition ($canonicalPlan.Count -eq 1) "sql executor emits canonical model adapter"
Assert-Equal $canonicalPlan[0].supported $true "canonical model adapter is supported"
foreach ($targetKind in (Convert-ToArray $sqlExecutorContract.expected.supported_target_kinds)) {
  Assert-Condition (@($operationPlans | Where-Object { $_.target.kind -eq $targetKind -and $_.supported }).Count -gt 0) "sql executor supports target kind $targetKind"
}

$statements = @(Convert-ToArray $canonicalPlan[0].statements)
foreach ($phase in (Convert-ToArray $sqlExecutorContract.expected.required_statement_phases)) {
  Assert-Condition (@($statements | Where-Object { $_.phase -eq $phase }).Count -gt 0) "sql executor emits $phase statement"
}
$sqlText = (($statements | ForEach-Object { [string]$_.sql }) -join "`n").ToLowerInvariant()
foreach ($fragment in (Convert-ToArray $sqlExecutorContract.expected.required_sql_fragments)) {
  Assert-Condition ($sqlText.Contains(([string]$fragment).ToLowerInvariant())) "sql executor SQL contains '$fragment'"
}
Assert-Equal $sqlApplyForce.Plan.sql_executor_plan.rollback_contract.capture_before_apply $sqlExecutorContract.expected.rollback_contract.capture_before_apply "rollback contract captures before apply"
Assert-Equal $sqlApplyForce.Plan.sql_executor_plan.rollback_contract.includes_operation_id $sqlExecutorContract.expected.rollback_contract.includes_operation_id "rollback contract includes operation id"
Assert-Equal $sqlApplyForce.Plan.sql_executor_plan.rollback_contract.includes_idempotency_key $sqlExecutorContract.expected.rollback_contract.includes_idempotency_key "rollback contract includes idempotency key"
Assert-Equal $sqlApplyForce.Plan.sql_executor_plan.rollback_contract.no_secret_material $sqlExecutorContract.expected.rollback_contract.no_secret_material "rollback contract excludes secret material"
Assert-Equal $sqlApplyForce.Plan.sql_executor_plan.refusal_contract.schema_version $sqlExecutorContract.expected.refusal_contract_schema "refusal contract schema"
Assert-Equal $sqlApplyForce.Plan.sql_executor_plan.operation_bundle_contract.schema_version $sqlExecutorContract.expected.operation_bundle_schema "operation bundle schema"
Assert-Equal $sqlApplyForce.Plan.sql_executor_plan.rollback_contract.entry_schema.schema_version $sqlExecutorContract.expected.rollback_entry_schema "rollback entry schema"
Assert-Condition (@(Convert-ToArray $sqlApplyForce.Plan.sql_executor_plan.refusal_contract.refuse_apply_when | Where-Object { $_ -eq "source_provider_channel_bindings preflight fails" }).Count -eq 1) "refusal contract blocks failed source bindings"
Assert-Condition (@(Convert-ToArray $sqlApplyForce.Plan.sql_executor_plan.operation_bundle_contract.statement_phase_order | Where-Object { $_ -eq "persist_rollback_snapshot_entry" }).Count -eq 1) "operation bundle persists rollback snapshot before mutation"

$missingForceFailed = $false
try {
  Invoke-ApplyPlan -PlanInputPath $InputPath -Apply | Out-Null
} catch {
  if ($_.Exception.Message -match "Apply requires explicit -Apply -Force") {
    $missingForceFailed = $true
  }
}
Assert-Condition $missingForceFailed "apply without force is rejected"

Write-Output "import-apply-plan contract verification passed"
Write-Output ("plan idempotency_key: {0}" -f $dryRun.Plan.idempotency_key)
Write-Output ("write operations: {0}; rollback entries: {1}; blocking conflicts: {2}" -f $idempotencyEntries.Count, $rollbackEntries.Count, $dryRun.Plan.counts.blocking_conflicts)
