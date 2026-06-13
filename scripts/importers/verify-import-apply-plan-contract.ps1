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
$script:NewApiDryRunScript = Join-Path $script:RepoRoot "scripts\importers\import-newapi-dryrun.ps1"
$script:InternalMappingScript = Join-Path $script:RepoRoot "scripts\importers\import-internal-mapping-report.ps1"
$script:SqlExecutorFixturePath = Join-Path $script:RepoRoot "tests\fixtures\importers\apply_plan_canonical_only.sample.json"
$script:ChannelMappingFixturePath = Join-Path $script:RepoRoot "tests\fixtures\importers\apply_plan_channel_mapping_bound.sample.json"
$script:SqlExecutorContractPath = Join-Path $script:RepoRoot "tests\fixtures\importers\postgresql_sql_executor_contract.expected.json"
$script:NewApiOpenAiFixturePath = Join-Path $script:RepoRoot "examples\importer_samples\new_api_openai_compatible.sample.json"

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

function Assert-MappingQualityReadback {
  param(
    [object]$Readback,
    [string]$Context
  )

  Assert-Condition ($null -ne $Readback) "$Context includes mapping_quality_readback"
  Assert-Equal $Readback.schema_version "importer.mapping-quality-readback.v1" "$Context mapping quality schema"
  Assert-Equal $Readback.secret_safe $true "$Context mapping quality secret-safe"
  Assert-Equal $Readback.dry_run_only $true "$Context mapping quality dry-run only"
  Assert-Condition ($null -ne $Readback.mapping_counts) "$Context mapping quality counts"
  foreach ($field in @("provider_mappings", "channel_mappings", "model_mappings", "user_mappings", "key_mappings", "wallet_mappings", "subscription_mappings", "conflicts")) {
    Assert-Condition ([int]$Readback.mapping_counts.$field -ge 0) "$Context mapping quality count $field"
  }
  Assert-Condition ($null -ne $Readback.conflicts) "$Context mapping quality conflicts"
  Assert-Condition ($null -ne $Readback.non_migratable_reasons) "$Context mapping quality non-migratable reasons"
  Assert-Condition ($null -ne $Readback.operator_handoff_refs_presence) "$Context mapping quality operator handoff refs"
  Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$Readback.safe_next_action)) "$Context mapping quality safe next action"
  Assert-Equal $Readback.raw_provider_key_returned $false "$Context mapping quality omits raw provider key"
  Assert-Equal $Readback.raw_user_key_returned $false "$Context mapping quality omits raw user key"
  Assert-Equal $Readback.token_returned $false "$Context mapping quality omits token"
  Assert-Equal $Readback.db_url_returned $false "$Context mapping quality omits DB URL"
  Assert-Equal $Readback.raw_sql_returned $false "$Context mapping quality omits raw SQL"
  Assert-Equal $Readback.authorization_returned $false "$Context mapping quality omits Authorization"
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

function Write-TextFile {
  param(
    [string]$Path,
    [string]$Content
  )

  $parent = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }

  Set-Content -LiteralPath $Path -Value $Content -Encoding UTF8
}

function Invoke-GeneratedProviderKeyHandoffPlan {
  $tmpDir = Join-Path $script:RepoRoot ".tmp\importers"
  $sourceReportPath = Join-Path $tmpDir "provider_key_handoff_source.newapi.generated.json"
  $mappingReportPath = Join-Path $tmpDir "provider_key_handoff_internal_mapping.generated.json"

  $sourceOutput = & $script:NewApiDryRunScript -InputPath $script:NewApiOpenAiFixturePath
  $sourceRaw = ($sourceOutput | Out-String).Trim()
  Assert-Condition (-not [string]::IsNullOrWhiteSpace($sourceRaw)) "generated NewAPI source dry-run produced JSON"
  Assert-NoSecretMaterial $sourceRaw
  Write-TextFile -Path $sourceReportPath -Content $sourceRaw

  $mappingOutput = & $script:InternalMappingScript -InputPath $sourceReportPath
  $mappingRaw = ($mappingOutput | Out-String).Trim()
  Assert-Condition (-not [string]::IsNullOrWhiteSpace($mappingRaw)) "generated internal mapping report produced JSON"
  Assert-NoSecretMaterial $mappingRaw
  Write-TextFile -Path $mappingReportPath -Content $mappingRaw

  $mappingReport = $mappingRaw | ConvertFrom-Json
  Assert-Condition ([int]$mappingReport.counts.provider_key_handoffs -gt 0) "generated internal mapping has provider key handoffs"
  Assert-Equal $mappingReport.provider_key_handoff_contract.schema_version "importer.provider-key-handoff-contract.v1" "generated internal mapping handoff contract schema"
  Assert-Equal $mappingReport.provider_key_handoff_contract.raw_material_allowed $false "generated internal mapping handoff raw material flag"
  Assert-Equal $mappingReport.provider_key_handoff_contract.apply_directly_supported $false "generated internal mapping handoff direct apply flag"

  return Invoke-ApplyPlan -PlanInputPath $mappingReportPath
}

Assert-Condition (Test-Path -LiteralPath $script:ApplyPlanScript -PathType Leaf) "apply plan script exists"
Assert-Condition (Test-Path -LiteralPath $script:NewApiDryRunScript -PathType Leaf) "NewAPI dry-run script exists"
Assert-Condition (Test-Path -LiteralPath $script:InternalMappingScript -PathType Leaf) "internal mapping script exists"
Assert-Condition (Test-Path -LiteralPath $InputPath -PathType Leaf) "input sample exists"
Assert-Condition (Test-Path -LiteralPath $ExistingStatePath -PathType Leaf) "existing-state sample exists"
Assert-Condition (Test-Path -LiteralPath $script:SqlExecutorFixturePath -PathType Leaf) "sql executor canonical-only fixture exists"
Assert-Condition (Test-Path -LiteralPath $script:ChannelMappingFixturePath -PathType Leaf) "sql executor channel mapping fixture exists"
Assert-Condition (Test-Path -LiteralPath $script:SqlExecutorContractPath -PathType Leaf) "sql executor contract fixture exists"
Assert-Condition (Test-Path -LiteralPath $script:NewApiOpenAiFixturePath -PathType Leaf) "NewAPI OpenAI-compatible fixture exists"

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
Assert-MappingQualityReadback $dryRun.Plan.mapping_quality_readback "apply plan dry-run"

$conflictCheck = Get-PreflightCheck $dryRun.Plan "blocking_conflicts"
Assert-Equal $conflictCheck.status "fail" "conflict preflight status"
$databaseWriterCheck = Get-PreflightCheck $dryRun.Plan "database_writer_available"
Assert-Equal $databaseWriterCheck.status "pass" "sql-plan database writer preflight status"
$unsupportedCheck = Get-PreflightCheck $dryRun.Plan "write_operations_supported_by_sql_executor"
Assert-Equal $unsupportedCheck.status "pass" "unsupported operation preflight status"
$sourceBindingCheck = Get-PreflightCheck $dryRun.Plan "source_provider_channel_bindings"
Assert-Equal $sourceBindingCheck.status "pass" "source provider/channel binding preflight status"
Assert-Equal ([int]$dryRun.Plan.counts.source_provider_previews) 2 "sample derives provider previews from unbound channel mappings"
Assert-Equal ([int]$dryRun.Plan.counts.source_channel_previews) 2 "sample derives channel previews from unbound channel mappings"
Assert-Equal ([int]$dryRun.Plan.target_counts.provider.creates) 2 "sample plans provider creates"
Assert-Equal ([int]$dryRun.Plan.target_counts.channel.creates) 2 "sample plans channel creates"
Assert-Condition (@(Convert-ToArray $dryRun.Plan.source_binding_contract.bindings | Where-Object {
      $_.channel_present -eq $true -and
      -not [string]::IsNullOrWhiteSpace([string]$_.internal_provider_id) -and
      -not [string]::IsNullOrWhiteSpace([string]$_.internal_channel_id)
    }).Count -ge 2) "source bindings include generated internal provider/channel ids"
Assert-Equal $dryRun.Plan.source_binding_contract.schema_version "importer.source-provider-channel-binding-contract.v1" "source binding contract schema"
Assert-Equal $dryRun.Plan.source_binding_contract.secret_material_allowed $false "source binding contract excludes secret material"
Assert-Condition ([int]$dryRun.Plan.counts.blocking_conflicts -gt 0) "sample has blocking conflicts"
$blockedSkips = @(Convert-ToArray $dryRun.Plan.planned_skips | Where-Object { $_.reason -eq "blocked_by_conflict" })
Assert-Condition ($blockedSkips.Count -gt 0) "conflicts create blocked skip operations"
$dryRunOperationPlans = @(Convert-ToArray $dryRun.Plan.sql_executor_plan.transaction.operation_plans)
Assert-Condition (@($dryRunOperationPlans | Where-Object { $_.target.kind -eq "provider" -and $_.adapter -eq "providers_upsert_v1" -and $_.supported }).Count -ge 2) "sample emits supported provider adapter plans"
Assert-Condition (@($dryRunOperationPlans | Where-Object { $_.target.kind -eq "channel" -and $_.adapter -eq "channels_upsert_v1" -and $_.supported }).Count -ge 2) "sample emits supported channel adapter plans"

$generatedHandoffPlan = Invoke-GeneratedProviderKeyHandoffPlan
Assert-NoSecretMaterial $generatedHandoffPlan.Raw
Assert-Equal $generatedHandoffPlan.Plan.provider_key_handoff_contract.schema_version "importer.provider-key-handoff-contract.v1" "apply plan provider key handoff contract schema"
Assert-Equal $generatedHandoffPlan.Plan.provider_key_handoff_contract.raw_material_allowed $false "apply plan provider key handoff excludes raw material"
Assert-Equal $generatedHandoffPlan.Plan.provider_key_handoff_contract.apply_directly_supported $false "apply plan provider key handoff direct apply flag"
Assert-Equal $generatedHandoffPlan.Plan.provider_key_handoff_contract.required_operator_path "POST /admin/provider-keys" "apply plan provider key operator path"
Assert-MappingQualityReadback $generatedHandoffPlan.Plan.mapping_quality_readback "generated provider-key handoff apply plan"
Assert-Equal ([int]$generatedHandoffPlan.Plan.counts.source_provider_key_handoffs) 3 "apply plan carries source provider key handoffs"
Assert-Condition ([int]$generatedHandoffPlan.Plan.counts.source_specific_apply_plan_artifacts -gt 0) "apply plan carries source-specific apply-plan artifact count"
Assert-Condition (@(Convert-ToArray $generatedHandoffPlan.Plan.source_specific_apply_plan_artifacts).Count -gt 0) "apply plan preserves source-specific apply-plan artifacts"
$generatedSourceArtifacts = @(Convert-ToArray $generatedHandoffPlan.Plan.source_specific_apply_plan_artifacts | Select-Object -First 1)
Assert-Condition ($generatedSourceArtifacts.Count -eq 1) "apply plan exposes one generated source-specific artifact wrapper"
Assert-Equal $generatedSourceArtifacts[0].artifacts.executable_handoff.schema_version "importer.source-specific-executable-handoff.v1" "apply plan source-specific executable handoff schema"
$providerKeyHandoffPreflight = Get-PreflightCheck $generatedHandoffPlan.Plan "provider_key_secret_management_handoff"
Assert-Equal $providerKeyHandoffPreflight.status "pass" "provider key handoff preflight status"
$providerKeyHandoffs = @(Convert-ToArray $generatedHandoffPlan.Plan.provider_key_handoffs)
Assert-Equal $providerKeyHandoffs.Count 3 "apply plan exposes provider key handoff sidecars"
foreach ($handoff in $providerKeyHandoffs) {
  Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$handoff.handoff_id)) "provider key handoff has handoff_id"
  Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$handoff.key_alias)) "provider key handoff has key_alias"
  Assert-Condition ([bool]$handoff.credential_material_present) "provider key handoff records credential presence"
  Assert-Condition ([string]$handoff.credential_locator_redacted -like "*redacted*") "provider key handoff locator is redacted"
  Assert-Equal $handoff.raw_material_exported $false "provider key handoff does not export raw material"
  Assert-Equal $handoff.provider_key_material_included $false "provider key handoff omits provider key material"
  Assert-Equal $handoff.apply_directly_supported $false "provider key handoff is not directly applied"
  Assert-Equal $handoff.apply_mode "sidecar_only" "provider key handoff apply mode"
  Assert-Equal $handoff.recommended_path "POST /admin/provider-keys" "provider key handoff recommended path"
  Assert-Condition (@(Convert-ToArray $handoff.credential_locator_hashes).Count -gt 0) "provider key handoff includes locator hash"
}
$generatedWriteTargets = @(Convert-ToArray $generatedHandoffPlan.Plan.planned_creates) + @(Convert-ToArray $generatedHandoffPlan.Plan.planned_updates)
Assert-Condition (@($generatedWriteTargets | Where-Object { $_.target.kind -match "provider_key|secret" }).Count -eq 0) "provider key handoffs do not become write operations"
$generatedOperationPlans = @(Convert-ToArray $generatedHandoffPlan.Plan.sql_executor_plan.transaction.operation_plans)
Assert-Condition (@($generatedOperationPlans | Where-Object { $_.target.kind -match "provider_key|secret" }).Count -eq 0) "provider key handoffs do not become SQL operation plans"
Assert-Condition (@(Convert-ToArray $generatedHandoffPlan.Plan.sql_executor_plan.refusal_contract.refuse_apply_when | Where-Object { $_ -eq "provider_key_secret_management_handoff preflight fails" }).Count -eq 1) "refusal contract blocks unsafe provider key handoff"

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

$channelMappingDryRun = Invoke-ApplyPlan -PlanInputPath $script:ChannelMappingFixturePath
$channelMappingApplyForce = Invoke-ApplyPlan -PlanInputPath $script:ChannelMappingFixturePath -Apply -Force
Assert-NoSecretMaterial $channelMappingDryRun.Raw
Assert-NoSecretMaterial $channelMappingApplyForce.Raw
Assert-Equal $channelMappingDryRun.Plan.preflight.status "pass" "channel mapping fixture preflight status"
Assert-Equal $channelMappingDryRun.Plan.sql_executor_plan.executor_status "dry_run_sql_plan" "channel mapping dry-run executor status"
Assert-Equal $channelMappingApplyForce.Plan.sql_executor_plan.executor_status "prepared_sql_plan" "channel mapping apply-force executor status"
Assert-Equal $channelMappingApplyForce.Plan.sql_executor_plan.database_writes $false "channel mapping apply-force database_writes"
Assert-Equal $channelMappingApplyForce.Plan.sql_executor_plan.live_database_connection $false "channel mapping apply-force live connection flag"
$channelMappingSourceBindingCheck = Get-PreflightCheck $channelMappingApplyForce.Plan "source_provider_channel_bindings"
Assert-Equal $channelMappingSourceBindingCheck.status "pass" "channel mapping source binding preflight status"

$channelMappingOperationPlans = @(Convert-ToArray $channelMappingApplyForce.Plan.sql_executor_plan.transaction.operation_plans)
$channelMappingPlans = @($channelMappingOperationPlans | Where-Object { $_.target.kind -eq "channel_mapping_entry" })
Assert-Equal $channelMappingPlans.Count 1 "channel mapping fixture emits one channel_mapping_entry plan"
Assert-Equal $channelMappingPlans[0].supported $true "channel mapping adapter is supported"
Assert-Equal $channelMappingPlans[0].adapter "channel_model_mappings_jsonb_merge_v1" "channel mapping adapter name"
$channelMappingStatements = @(Convert-ToArray $channelMappingPlans[0].statements)
Assert-Condition (@($channelMappingStatements | Where-Object { $_.phase -eq "capture_before_image" }).Count -eq 1) "channel mapping emits before-image capture"
Assert-Condition (@($channelMappingStatements | Where-Object { $_.phase -eq "apply_patch" }).Count -eq 1) "channel mapping emits apply patch"
$channelMappingSqlText = (($channelMappingStatements | ForEach-Object { [string]$_.sql }) -join "`n").ToLowerInvariant()
foreach ($fragment in @("for update", "update channels", "model_mappings", "cast(:mapping_patch_json as jsonb)")) {
  Assert-Condition ($channelMappingSqlText.Contains($fragment)) "channel mapping SQL contains '$fragment'"
}

$channelMappingJournalPlan = $channelMappingApplyForce.Plan.sql_executor_plan.journal_contract.sql_plan
$channelMappingJournalRows = @(Convert-ToArray $channelMappingJournalPlan.operation_insert_statements)
Assert-Equal $channelMappingJournalRows.Count 1 "channel mapping fixture emits one rollback journal row"
Assert-Equal $channelMappingJournalRows[0].operation_id $channelMappingPlans[0].operation_id "channel mapping journal row is tied to operation"
$channelMappingRollbackEntries = @(Convert-ToArray $channelMappingApplyForce.Plan.rollback_snapshot.entries)
Assert-Equal $channelMappingRollbackEntries.Count 1 "channel mapping fixture emits one rollback snapshot entry"

Assert-Equal $sqlApplyForce.Plan.sql_executor_plan.rollback_contract.capture_before_apply $sqlExecutorContract.expected.rollback_contract.capture_before_apply "rollback contract captures before apply"
Assert-Equal $sqlApplyForce.Plan.sql_executor_plan.rollback_contract.includes_operation_id $sqlExecutorContract.expected.rollback_contract.includes_operation_id "rollback contract includes operation id"
Assert-Equal $sqlApplyForce.Plan.sql_executor_plan.rollback_contract.includes_idempotency_key $sqlExecutorContract.expected.rollback_contract.includes_idempotency_key "rollback contract includes idempotency key"
Assert-Equal $sqlApplyForce.Plan.sql_executor_plan.rollback_contract.no_secret_material $sqlExecutorContract.expected.rollback_contract.no_secret_material "rollback contract excludes secret material"
Assert-Equal $sqlApplyForce.Plan.sql_executor_plan.refusal_contract.schema_version $sqlExecutorContract.expected.refusal_contract_schema "refusal contract schema"
Assert-Equal $sqlApplyForce.Plan.sql_executor_plan.operation_bundle_contract.schema_version $sqlExecutorContract.expected.operation_bundle_schema "operation bundle schema"
Assert-Equal $sqlApplyForce.Plan.sql_executor_plan.rollback_contract.entry_schema.schema_version $sqlExecutorContract.expected.rollback_entry_schema "rollback entry schema"
Assert-Equal $sqlApplyForce.Plan.sql_executor_plan.journal_contract.schema_version $sqlExecutorContract.expected.journal_contract_schema "rollback journal contract schema"
Assert-Equal $sqlApplyForce.Plan.sql_executor_plan.journal_contract.sql_plan.schema_version $sqlExecutorContract.expected.journal_sql_plan_schema "rollback journal sql plan schema"
Assert-Equal $sqlApplyForce.Plan.sql_executor_plan.rollback_operation_plan.schema_version $sqlExecutorContract.expected.rollback_operation_plan_schema "rollback operation plan schema"
Assert-Equal $sqlApplyForce.Plan.sql_executor_plan.rollback_operation_plan.execution_status $sqlExecutorContract.expected.rollback_operation_execution_status "rollback operation execution status"
Assert-Equal $sqlApplyForce.Plan.sql_executor_plan.rollback_operation_plan.execution_order $sqlExecutorContract.expected.rollback_operation_execution_order "rollback operation execution order"
Assert-Equal $sqlApplyForce.Plan.sql_executor_plan.rollback_operation_plan.operation_order.ordering $sqlExecutorContract.expected.rollback_operation_execution_order "rollback operation order contract"
Assert-Equal $sqlApplyForce.Plan.sql_executor_plan.rollback_operation_plan.replay_contract.schema_version $sqlExecutorContract.expected.rollback_replay_contract_schema "rollback replay contract schema"
Assert-Equal $sqlApplyForce.Plan.sql_executor_plan.rollback_operation_plan.refusal_contract.schema_version $sqlExecutorContract.expected.rollback_execution_refusal_contract_schema "rollback execution refusal contract schema"
Assert-Equal $sqlApplyForce.Plan.sql_executor_plan.rollback_operation_plan.database_writes $false "rollback operation plan makes no database writes"
Assert-Equal $sqlApplyForce.Plan.sql_executor_plan.rollback_operation_plan.live_database_connection $false "rollback operation plan makes no live database connection"
Assert-Equal $sqlApplyForce.Plan.sql_executor_plan.rollback_operation_plan.mark_run_rolled_back_statement.phase $sqlExecutorContract.expected.rollback_run_status_statement_phase "rollback run status statement phase"
Assert-Condition (@(Convert-ToArray $sqlApplyForce.Plan.sql_executor_plan.refusal_contract.refuse_apply_when | Where-Object { $_ -eq "source_provider_channel_bindings preflight fails" }).Count -eq 1) "refusal contract blocks failed source bindings"
Assert-Condition (@(Convert-ToArray $sqlApplyForce.Plan.sql_executor_plan.operation_bundle_contract.statement_phase_order | Where-Object { $_ -eq "persist_rollback_snapshot_entry" }).Count -eq 1) "operation bundle persists rollback snapshot before mutation"

$journalPlan = $sqlApplyForce.Plan.sql_executor_plan.journal_contract.sql_plan
foreach ($table in (Convert-ToArray $sqlExecutorContract.expected.required_journal_tables)) {
  Assert-Condition (@(Convert-ToArray $journalPlan.tables | Where-Object { $_ -eq $table }).Count -eq 1) "rollback journal plan includes table $table"
}

$journalStatements = @()
$journalStatements += @(Convert-ToArray $journalPlan.ddl_statements)
$journalStatements += @(Convert-ToArray $journalPlan.run_insert_statement)
$journalStatements += @(Convert-ToArray $journalPlan.operation_insert_statements)
Assert-Condition ($journalStatements.Count -gt 0) "rollback journal SQL plan emits statements"
foreach ($phase in (Convert-ToArray $sqlExecutorContract.expected.required_journal_statement_phases)) {
  Assert-Condition (@($journalStatements | Where-Object { $_.phase -eq $phase }).Count -gt 0) "rollback journal SQL plan emits $phase statement"
}
$journalSqlText = (($journalStatements | ForEach-Object { [string]$_.sql }) -join "`n").ToLowerInvariant()
foreach ($fragment in (Convert-ToArray $sqlExecutorContract.expected.required_journal_sql_fragments)) {
  Assert-Condition ($journalSqlText.Contains(([string]$fragment).ToLowerInvariant())) "rollback journal SQL contains '$fragment'"
}

$rollbackSkeletons = @(Convert-ToArray $sqlApplyForce.Plan.sql_executor_plan.rollback_operation_plan.operation_skeletons)
Assert-Condition ($rollbackSkeletons.Count -gt 0) "rollback operation plan emits skeletons"
$applyOperationIds = @(Convert-ToArray $operationPlans | ForEach-Object { $_.operation_id })
$rollbackOperationIds = @(Convert-ToArray $rollbackSkeletons | ForEach-Object { $_.operation_id })
Assert-Equal $rollbackOperationIds.Count $applyOperationIds.Count "rollback skeleton count matches apply operation count"
for ($i = 0; $i -lt $rollbackOperationIds.Count; $i++) {
  $expectedReverseId = $applyOperationIds[($applyOperationIds.Count - 1 - $i)]
  Assert-Equal $rollbackOperationIds[$i] $expectedReverseId "rollback skeletons are ordered in reverse apply order"
}
foreach ($skeleton in $rollbackSkeletons) {
  Assert-Equal $skeleton.supported_by_current_slice $false "rollback skeleton is plan-only"
  Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$skeleton.lookup_statement.sql)) "rollback skeleton has journal lookup SQL"
  Assert-Equal $skeleton.execution_order $sqlExecutorContract.expected.rollback_operation_execution_order "rollback skeleton execution order"
  Assert-Condition ([int]$skeleton.rollback_sequence -gt 0) "rollback skeleton has sequence"
  Assert-Equal $skeleton.replay_idempotency_contract.schema_version $sqlExecutorContract.expected.rollback_operation_replay_contract_schema "rollback skeleton replay contract schema"
  $rollbackStatements = @($skeleton.lookup_statement, $skeleton.mark_rolled_back_statement)
  foreach ($phase in (Convert-ToArray $sqlExecutorContract.expected.rollback_required_operation_statement_phases)) {
    $phaseMatches = @($rollbackStatements | Where-Object { $_.phase -eq $phase })
    Assert-Condition ($phaseMatches.Count -gt 0) "rollback skeleton emits $phase statement"
  }
  Assert-Equal $skeleton.mark_rolled_back_statement.parameters.rollback_snapshot_idempotency_key $sqlApplyForce.Plan.sql_executor_plan.rollback_snapshot_idempotency_key "rollback skeleton carries rollback snapshot key"
  Assert-Equal $skeleton.compensating_mutation_contract.database_writes $false "rollback compensating mutation contract is no-write"
  Assert-Condition (@(Convert-ToArray $skeleton.compensating_mutation_contract.future_runner_must_verify | Where-Object { $_ -eq "current target state still matches after_hash or replay must refuse" }).Count -eq 1) "rollback skeleton refuses stale target state"
}

$channelMappingRollbackPlan = $channelMappingApplyForce.Plan.sql_executor_plan.rollback_operation_plan
Assert-Equal $channelMappingRollbackPlan.execution_order $sqlExecutorContract.expected.rollback_operation_execution_order "channel mapping rollback execution order"
Assert-Equal $channelMappingRollbackPlan.database_writes $false "channel mapping rollback plan database_writes"
Assert-Equal $channelMappingRollbackPlan.live_database_connection $false "channel mapping rollback plan live connection"
$channelMappingRollbackSkeletons = @(Convert-ToArray $channelMappingRollbackPlan.operation_skeletons)
Assert-Equal $channelMappingRollbackSkeletons.Count 1 "channel mapping rollback emits one skeleton"
Assert-Equal $channelMappingRollbackSkeletons[0].compensating_mutation_contract.future_adapter "channel_model_mappings_rollback_v1_planned" "channel mapping rollback future adapter"
Assert-Equal $channelMappingRollbackSkeletons[0].mark_rolled_back_statement.phase $sqlExecutorContract.expected.rollback_required_operation_statement_phases[1] "channel mapping rollback status phase"

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
