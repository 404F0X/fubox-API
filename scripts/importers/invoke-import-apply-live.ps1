[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$InputPath,

  [string]$ExistingStatePath,

  [string]$TenantId = "00000000-0000-0000-0000-000000000001",

  [string]$ComposeFile = "deploy/docker-compose/docker-compose.yml",

  [string]$ArtifactPath = ".tmp\importers\import_apply_live_runtime.json",

  [switch]$RollbackAfterApply,

  [switch]$ConfirmReviewedPlan,

  [switch]$Force
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\..\common.ps1"

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$script:ApplyPlanScript = Join-Path $script:RepoRoot "scripts\importers\import-apply-plan.ps1"
$script:ComposeFile = $ComposeFile
$script:TenantId = $TenantId
$script:Blockers = New-Object System.Collections.Generic.List[string]

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

function Escape-SqlLiteral {
  param([AllowNull()][object]$Value)
  if ($null -eq $Value) { return "" }
  return ([string]$Value).Replace("'", "''")
}

function Sql-Text {
  param([AllowNull()][object]$Value)
  if ($null -eq $Value) { return "null" }
  return "'" + (Escape-SqlLiteral $Value) + "'"
}

function Sql-TextRequired {
  param([AllowNull()][object]$Value)
  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
    throw "required SQL text value was empty"
  }
  return Sql-Text $Value
}

function Sql-NullableUuid {
  param([AllowNull()][object]$Value)
  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return "null" }
  return (Sql-Text $Value) + "::uuid"
}

function Sql-NullableInt {
  param([AllowNull()][object]$Value)
  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return "null" }
  return [string]([int]$Value)
}

function Sql-NullableDecimal {
  param([AllowNull()][object]$Value)
  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return "null" }
  return [string]([decimal]$Value)
}

function Sql-Bool {
  param([AllowNull()][object]$Value)
  if ([bool]$Value) { return "true" }
  return "false"
}

function ConvertTo-CompactJson {
  param(
    [AllowNull()][object]$Value,
    [int]$Depth = 64
  )
  if ($null -eq $Value) { return "null" }
  if ($Value -is [string]) { return [string]$Value }
  return ($Value | ConvertTo-Json -Depth $Depth -Compress)
}

function Sql-Json {
  param([AllowNull()][object]$Value)
  return (Sql-Text (ConvertTo-CompactJson $Value 96)) + "::jsonb"
}

function Get-OperationParameters {
  param([Parameter(Mandatory = $true)]$OperationPlan)
  $statements = @(Convert-ToArray $OperationPlan.statements)
  if ($statements.Count -eq 0) {
    throw "operation '$($OperationPlan.operation_id)' has no SQL statements"
  }
  return $statements[0].parameters
}

function Get-WriteOperation {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)][string]$OperationId
  )
  $writes = @(Convert-ToArray $Plan.planned_creates) + @(Convert-ToArray $Plan.planned_updates)
  $matched = @($writes | Where-Object { [string]$_.operation_id -eq $OperationId } | Select-Object -First 1)
  if ($matched.Count -ne 1) {
    throw "write operation '$OperationId' was not found in apply plan"
  }
  return $matched[0]
}

function Invoke-ComposePsql {
  param([Parameter(Mandatory = $true)][string]$Sql)
  Push-Location $script:RepoRoot
  try {
    $output = Invoke-Docker compose -f $script:ComposeFile exec -T postgres psql `
      -U ai_gateway `
      -d ai_gateway `
      -tA `
      -v ON_ERROR_STOP=1 `
      -c $Sql
    if ($LASTEXITCODE -ne 0) {
      throw "psql failed with exit code $LASTEXITCODE"
    }
    return (($output | Out-String).Trim())
  } finally {
    Pop-Location
  }
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

function Initialize-ImporterJournalTables {
  param([Parameter(Mandatory = $true)]$Plan)
  $ddlStatements = @(Convert-ToArray $Plan.sql_executor_plan.journal_contract.sql_plan.ddl_statements)
  foreach ($statement in $ddlStatements) {
    [void](Invoke-ComposePsql ([string]$statement.sql))
  }
}

function New-ApplyRunSql {
  param([Parameter(Mandatory = $true)]$Plan)
  $transactionId = [string]$Plan.transaction_contract.transaction_id
  $planKey = [string]$Plan.sql_executor_plan.plan_idempotency_key
  $rollbackKey = [string]$Plan.sql_executor_plan.rollback_snapshot_idempotency_key
  $manifestKey = [string]$Plan.sql_executor_plan.idempotency_manifest_key
  $manifestJson = ConvertTo-CompactJson $Plan.idempotency_manifest 96
  return @"
insert into importer_apply_runs (
  transaction_id, plan_idempotency_key, rollback_snapshot_idempotency_key,
  idempotency_manifest_key, tenant_id, idempotency_manifest_json, status, dry_run_contract
)
values (
  $(Sql-TextRequired $transactionId), $(Sql-TextRequired $planKey), $(Sql-TextRequired $rollbackKey),
  $(Sql-TextRequired $manifestKey), $(Sql-TextRequired $script:TenantId)::uuid, $(Sql-TextRequired $manifestJson)::jsonb,
  'prepared', false
)
on conflict (transaction_id) do update
set plan_idempotency_key = excluded.plan_idempotency_key,
    rollback_snapshot_idempotency_key = excluded.rollback_snapshot_idempotency_key,
    idempotency_manifest_key = excluded.idempotency_manifest_key,
    idempotency_manifest_json = excluded.idempotency_manifest_json,
    status = 'prepared',
    dry_run_contract = false,
    updated_at = now();
"@
}

function New-ProviderApplySql {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$OperationPlan
  )
  $write = Get-WriteOperation $Plan ([string]$OperationPlan.operation_id)
  $p = Get-OperationParameters $OperationPlan
  $transactionId = [string]$Plan.transaction_contract.transaction_id
  $targetJson = ConvertTo-CompactJson $OperationPlan.target 32
  $afterJson = ConvertTo-CompactJson $write.after 64
  $rollbackEntryId = [string]$OperationPlan.rollback_snapshot_entry_id
  $operationId = [string]$OperationPlan.operation_id
  $idempotencyKey = [string]$OperationPlan.idempotency_key
  $targetKind = [string]$OperationPlan.target.kind
  $targetHash = [string]$OperationPlan.target.natural_key_hash
  $afterHash = [string]$p.after_hash

  return @"
with captured as (
  select to_jsonb(p.*) as object_json
  from providers p
  where p.tenant_id = $(Sql-TextRequired $script:TenantId)::uuid
    and p.code = $(Sql-TextRequired $p.provider_code)
    and p.deleted_at is null
  for update
),
before_image as (
  select case
    when exists (select 1 from captured) then jsonb_build_object(
      'schema_version', 'importer.before-image.v1',
      'object_exists', true,
      'object_hash', md5((select object_json::text from captured)),
      'object', (select object_json from captured),
      'capture_mode', 'live_for_update',
      'dry_run_shape_only', false,
      'required_for_rollback', true
    )
    else jsonb_build_object(
      'schema_version', 'importer.before-image.v1',
      'object_exists', false,
      'object_hash', null,
      'object', null,
      'capture_mode', 'live_for_update_not_found',
      'dry_run_shape_only', false,
      'required_for_rollback', true
    )
  end as image
),
rollback_entry as (
  select
    image,
    jsonb_build_object(
      'snapshot_entry_id', $(Sql-TextRequired $rollbackEntryId),
      'operation_id', $(Sql-TextRequired $operationId),
      'target', $(Sql-Json $targetJson),
      'rollback_action', case when (image->>'object_exists')::boolean then 'restore_previous_object' else 'delete_created_object' end,
      'before', null,
      'before_image', image,
      'after_preview', $(Sql-Json $afterJson),
      'after_preview_hash', $(Sql-TextRequired $afterHash),
      'snapshot_mode', 'live_before_apply'
    ) as entry
  from before_image
),
journal as (
  insert into importer_apply_operation_journal (
    snapshot_entry_id, transaction_id, operation_id, operation_idempotency_key,
    target_kind, target_natural_key_hash, rollback_action, before_image_json,
    before_image_hash, after_hash, rollback_entry_json, status
  )
  select
    $(Sql-TextRequired $rollbackEntryId), $(Sql-TextRequired $transactionId), $(Sql-TextRequired $operationId), $(Sql-TextRequired $idempotencyKey),
    $(Sql-TextRequired $targetKind), $(Sql-TextRequired $targetHash), entry->>'rollback_action', image,
    image->>'object_hash', $(Sql-TextRequired $afterHash), entry, 'prepared'
  from rollback_entry
  on conflict (snapshot_entry_id) do update
  set transaction_id = excluded.transaction_id,
      operation_id = excluded.operation_id,
      operation_idempotency_key = excluded.operation_idempotency_key,
      target_kind = excluded.target_kind,
      target_natural_key_hash = excluded.target_natural_key_hash,
      before_image_json = excluded.before_image_json,
      before_image_hash = excluded.before_image_hash,
      after_hash = excluded.after_hash,
      rollback_entry_json = excluded.rollback_entry_json,
      rollback_action = excluded.rollback_action,
      status = 'prepared',
      updated_at = now()
  returning snapshot_entry_id
)
select count(*) as journal_rows from journal;

with applied as (
  insert into providers (
    id, tenant_id, code, name, status, metadata
  )
  values (
    $(Sql-TextRequired $p.internal_provider_id)::uuid,
    $(Sql-TextRequired $script:TenantId)::uuid,
    $(Sql-TextRequired $p.provider_code),
    $(Sql-TextRequired $p.name),
    $(Sql-TextRequired $p.status),
    $(Sql-Json $p.metadata_json)
  )
  on conflict (tenant_id, code) do update
  set name = excluded.name,
      status = excluded.status,
      metadata = excluded.metadata,
      updated_at = now(),
      deleted_at = null
  returning to_jsonb(providers.*) as after_image
)
select count(*) as applied_rows from applied;

update importer_apply_operation_journal
set status = 'applied',
    updated_at = now()
where transaction_id = $(Sql-TextRequired $transactionId)
  and snapshot_entry_id = $(Sql-TextRequired $rollbackEntryId)
  and status = 'prepared'
returning snapshot_entry_id;
"@
}

function New-ChannelApplySql {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$OperationPlan
  )
  $write = Get-WriteOperation $Plan ([string]$OperationPlan.operation_id)
  $p = Get-OperationParameters $OperationPlan
  $transactionId = [string]$Plan.transaction_contract.transaction_id
  $targetJson = ConvertTo-CompactJson $OperationPlan.target 32
  $afterJson = ConvertTo-CompactJson $write.after 64
  $rollbackEntryId = [string]$OperationPlan.rollback_snapshot_entry_id
  $operationId = [string]$OperationPlan.operation_id
  $idempotencyKey = [string]$OperationPlan.idempotency_key
  $targetKind = [string]$OperationPlan.target.kind
  $targetHash = [string]$OperationPlan.target.natural_key_hash
  $afterHash = [string]$p.after_hash

  return @"
with captured as (
  select to_jsonb(ch.*) as object_json
  from channels ch
  join providers p
    on p.tenant_id = ch.tenant_id
   and p.id = ch.provider_id
  where ch.tenant_id = $(Sql-TextRequired $script:TenantId)::uuid
    and p.code = $(Sql-TextRequired $p.provider_code)
    and ch.name = $(Sql-TextRequired $p.channel_name)
    and ch.deleted_at is null
    and p.deleted_at is null
  for update
),
before_image as (
  select case
    when exists (select 1 from captured) then jsonb_build_object(
      'schema_version', 'importer.before-image.v1',
      'object_exists', true,
      'object_hash', md5((select object_json::text from captured)),
      'object', (select object_json from captured),
      'capture_mode', 'live_for_update',
      'dry_run_shape_only', false,
      'required_for_rollback', true
    )
    else jsonb_build_object(
      'schema_version', 'importer.before-image.v1',
      'object_exists', false,
      'object_hash', null,
      'object', null,
      'capture_mode', 'live_for_update_not_found',
      'dry_run_shape_only', false,
      'required_for_rollback', true
    )
  end as image
),
rollback_entry as (
  select
    image,
    jsonb_build_object(
      'snapshot_entry_id', $(Sql-TextRequired $rollbackEntryId),
      'operation_id', $(Sql-TextRequired $operationId),
      'target', $(Sql-Json $targetJson),
      'rollback_action', case when (image->>'object_exists')::boolean then 'restore_previous_object' else 'delete_created_object' end,
      'before', null,
      'before_image', image,
      'after_preview', $(Sql-Json $afterJson),
      'after_preview_hash', $(Sql-TextRequired $afterHash),
      'snapshot_mode', 'live_before_apply'
    ) as entry
  from before_image
),
journal as (
  insert into importer_apply_operation_journal (
    snapshot_entry_id, transaction_id, operation_id, operation_idempotency_key,
    target_kind, target_natural_key_hash, rollback_action, before_image_json,
    before_image_hash, after_hash, rollback_entry_json, status
  )
  select
    $(Sql-TextRequired $rollbackEntryId), $(Sql-TextRequired $transactionId), $(Sql-TextRequired $operationId), $(Sql-TextRequired $idempotencyKey),
    $(Sql-TextRequired $targetKind), $(Sql-TextRequired $targetHash), entry->>'rollback_action', image,
    image->>'object_hash', $(Sql-TextRequired $afterHash), entry, 'prepared'
  from rollback_entry
  on conflict (snapshot_entry_id) do update
  set transaction_id = excluded.transaction_id,
      operation_id = excluded.operation_id,
      operation_idempotency_key = excluded.operation_idempotency_key,
      target_kind = excluded.target_kind,
      target_natural_key_hash = excluded.target_natural_key_hash,
      before_image_json = excluded.before_image_json,
      before_image_hash = excluded.before_image_hash,
      after_hash = excluded.after_hash,
      rollback_entry_json = excluded.rollback_entry_json,
      rollback_action = excluded.rollback_action,
      status = 'prepared',
      updated_at = now()
  returning snapshot_entry_id
)
select count(*) as journal_rows from journal;

with provider as (
  select id
  from providers
  where tenant_id = $(Sql-TextRequired $script:TenantId)::uuid
    and code = $(Sql-TextRequired $p.provider_code)
    and deleted_at is null
  limit 1
),
applied as (
  insert into channels (
    id, tenant_id, provider_id, name, endpoint, protocol_mode, status,
    region, priority, weight, tags, model_mappings, request_overrides,
    timeout_policy, probe_policy, health_score
  )
  select
    $(Sql-TextRequired $p.internal_channel_id)::uuid,
    $(Sql-TextRequired $script:TenantId)::uuid,
    provider.id,
    $(Sql-TextRequired $p.channel_name),
    $(Sql-TextRequired $p.endpoint),
    $(Sql-TextRequired $p.protocol_mode),
    $(Sql-TextRequired $p.status),
    $(Sql-Text $p.region),
    $(Sql-NullableInt $p.priority),
    $(Sql-NullableInt $p.weight),
    $(Sql-Json $p.tags_json),
    $(Sql-Json $p.model_mappings_json),
    $(Sql-Json $p.request_overrides_json),
    $(Sql-Json $p.timeout_policy_json),
    $(Sql-Json $p.probe_policy_json),
    $(Sql-NullableDecimal $p.health_score)
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
  returning to_jsonb(channels.*) as after_image
)
select count(*) as applied_rows from applied;

update importer_apply_operation_journal
set status = 'applied',
    updated_at = now()
where transaction_id = $(Sql-TextRequired $transactionId)
  and snapshot_entry_id = $(Sql-TextRequired $rollbackEntryId)
  and status = 'prepared'
returning snapshot_entry_id;
"@
}

function New-CanonicalModelApplySql {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$OperationPlan
  )
  $write = Get-WriteOperation $Plan ([string]$OperationPlan.operation_id)
  $p = Get-OperationParameters $OperationPlan
  $transactionId = [string]$Plan.transaction_contract.transaction_id
  $targetJson = ConvertTo-CompactJson $OperationPlan.target 32
  $afterJson = ConvertTo-CompactJson $write.after 64
  $rollbackEntryId = [string]$OperationPlan.rollback_snapshot_entry_id
  $operationId = [string]$OperationPlan.operation_id
  $idempotencyKey = [string]$OperationPlan.idempotency_key
  $targetKind = [string]$OperationPlan.target.kind
  $targetHash = [string]$OperationPlan.target.natural_key_hash
  $afterHash = [string]$p.after_hash

  return @"
with captured as (
  select to_jsonb(cm.*) as object_json
  from canonical_models cm
  where cm.tenant_id = $(Sql-TextRequired $script:TenantId)::uuid
    and cm.model_key = $(Sql-TextRequired $p.model_key)
    and cm.deleted_at is null
  for update
),
before_image as (
  select case
    when exists (select 1 from captured) then jsonb_build_object(
      'schema_version', 'importer.before-image.v1',
      'object_exists', true,
      'object_hash', md5((select object_json::text from captured)),
      'object', (select object_json from captured),
      'capture_mode', 'live_for_update',
      'dry_run_shape_only', false,
      'required_for_rollback', true
    )
    else jsonb_build_object(
      'schema_version', 'importer.before-image.v1',
      'object_exists', false,
      'object_hash', null,
      'object', null,
      'capture_mode', 'live_for_update_not_found',
      'dry_run_shape_only', false,
      'required_for_rollback', true
    )
  end as image
),
rollback_entry as (
  select
    image,
    jsonb_build_object(
      'snapshot_entry_id', $(Sql-TextRequired $rollbackEntryId),
      'operation_id', $(Sql-TextRequired $operationId),
      'target', $(Sql-Json $targetJson),
      'rollback_action', case when (image->>'object_exists')::boolean then 'restore_previous_object' else 'delete_created_object' end,
      'before', null,
      'before_image', image,
      'after_preview', $(Sql-Json $afterJson),
      'after_preview_hash', $(Sql-TextRequired $afterHash),
      'snapshot_mode', 'live_before_apply'
    ) as entry
  from before_image
),
journal as (
  insert into importer_apply_operation_journal (
    snapshot_entry_id, transaction_id, operation_id, operation_idempotency_key,
    target_kind, target_natural_key_hash, rollback_action, before_image_json,
    before_image_hash, after_hash, rollback_entry_json, status
  )
  select
    $(Sql-TextRequired $rollbackEntryId), $(Sql-TextRequired $transactionId), $(Sql-TextRequired $operationId), $(Sql-TextRequired $idempotencyKey),
    $(Sql-TextRequired $targetKind), $(Sql-TextRequired $targetHash), entry->>'rollback_action', image,
    image->>'object_hash', $(Sql-TextRequired $afterHash), entry, 'prepared'
  from rollback_entry
  on conflict (snapshot_entry_id) do update
  set transaction_id = excluded.transaction_id,
      operation_id = excluded.operation_id,
      operation_idempotency_key = excluded.operation_idempotency_key,
      target_kind = excluded.target_kind,
      target_natural_key_hash = excluded.target_natural_key_hash,
      before_image_json = excluded.before_image_json,
      before_image_hash = excluded.before_image_hash,
      after_hash = excluded.after_hash,
      rollback_entry_json = excluded.rollback_entry_json,
      rollback_action = excluded.rollback_action,
      status = 'prepared',
      updated_at = now()
  returning snapshot_entry_id
)
select count(*) as journal_rows from journal;

with applied as (
  insert into canonical_models (
    tenant_id, model_key, display_name, family, capabilities, context_length,
    max_output_tokens, supports_stream, supports_tools, supports_vision,
    supports_audio, supports_reasoning, default_price_book_id, visibility, status
  )
  values (
    $(Sql-TextRequired $script:TenantId)::uuid, $(Sql-TextRequired $p.model_key), $(Sql-TextRequired $p.display_name), $(Sql-Text $p.family), $(Sql-Json $p.capabilities_json),
    $(Sql-NullableInt $p.context_length), $(Sql-NullableInt $p.max_output_tokens), $(Sql-Bool $p.supports_stream), $(Sql-Bool $p.supports_tools), $(Sql-Bool $p.supports_vision),
    $(Sql-Bool $p.supports_audio), $(Sql-Bool $p.supports_reasoning), $(Sql-NullableUuid $p.default_price_book_id),
    $(Sql-TextRequired $p.visibility), $(Sql-TextRequired $p.status)
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
  returning to_jsonb(canonical_models.*) as after_image
)
select count(*) as applied_rows from applied;

update importer_apply_operation_journal
set status = 'applied',
    updated_at = now()
where transaction_id = $(Sql-TextRequired $transactionId)
  and snapshot_entry_id = $(Sql-TextRequired $rollbackEntryId)
  and status = 'prepared'
returning snapshot_entry_id;
"@
}

function New-ChannelMappingApplySql {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$OperationPlan
  )
  $write = Get-WriteOperation $Plan ([string]$OperationPlan.operation_id)
  $p = Get-OperationParameters $OperationPlan
  $transactionId = [string]$Plan.transaction_contract.transaction_id
  $targetJson = ConvertTo-CompactJson $OperationPlan.target 32
  $afterJson = ConvertTo-CompactJson $write.after 64
  $rollbackEntryId = [string]$OperationPlan.rollback_snapshot_entry_id
  $operationId = [string]$OperationPlan.operation_id
  $idempotencyKey = [string]$OperationPlan.idempotency_key
  $targetKind = [string]$OperationPlan.target.kind
  $targetHash = [string]$OperationPlan.target.natural_key_hash
  $afterHash = [string]$p.after_hash

  return @"
with captured as (
  select jsonb_build_object(
    'channel', to_jsonb(ch.*),
    'existing_model_mappings', coalesce(ch.model_mappings, '{}'::jsonb),
    'requested_model', $(Sql-TextRequired $p.requested_model),
    'existing_upstream_model_name', coalesce(ch.model_mappings, '{}'::jsonb) ->> $(Sql-TextRequired $p.requested_model)
  ) as object_json
  from channels ch
  where ch.tenant_id = $(Sql-TextRequired $script:TenantId)::uuid
    and ch.id = $(Sql-TextRequired $p.internal_channel_id)::uuid
    and ch.deleted_at is null
  for update
),
before_image as (
  select case
    when exists (select 1 from captured) then jsonb_build_object(
      'schema_version', 'importer.before-image.v1',
      'object_exists', true,
      'object_hash', md5((select object_json::text from captured)),
      'object', (select object_json from captured),
      'capture_mode', 'live_for_update',
      'dry_run_shape_only', false,
      'required_for_rollback', true
    )
    else jsonb_build_object(
      'schema_version', 'importer.before-image.v1',
      'object_exists', false,
      'object_hash', null,
      'object', null,
      'capture_mode', 'live_for_update_not_found',
      'dry_run_shape_only', false,
      'required_for_rollback', true
    )
  end as image
),
rollback_entry as (
  select
    image,
    jsonb_build_object(
      'snapshot_entry_id', $(Sql-TextRequired $rollbackEntryId),
      'operation_id', $(Sql-TextRequired $operationId),
      'target', $(Sql-Json $targetJson),
      'rollback_action', 'restore_previous_object',
      'before', null,
      'before_image', image,
      'after_preview', $(Sql-Json $afterJson),
      'after_preview_hash', $(Sql-TextRequired $afterHash),
      'snapshot_mode', 'live_before_apply'
    ) as entry
  from before_image
),
journal as (
  insert into importer_apply_operation_journal (
    snapshot_entry_id, transaction_id, operation_id, operation_idempotency_key,
    target_kind, target_natural_key_hash, rollback_action, before_image_json,
    before_image_hash, after_hash, rollback_entry_json, status
  )
  select
    $(Sql-TextRequired $rollbackEntryId), $(Sql-TextRequired $transactionId), $(Sql-TextRequired $operationId), $(Sql-TextRequired $idempotencyKey),
    $(Sql-TextRequired $targetKind), $(Sql-TextRequired $targetHash), entry->>'rollback_action', image,
    image->>'object_hash', $(Sql-TextRequired $afterHash), entry, 'prepared'
  from rollback_entry
  on conflict (snapshot_entry_id) do update
  set transaction_id = excluded.transaction_id,
      operation_id = excluded.operation_id,
      operation_idempotency_key = excluded.operation_idempotency_key,
      target_kind = excluded.target_kind,
      target_natural_key_hash = excluded.target_natural_key_hash,
      before_image_json = excluded.before_image_json,
      before_image_hash = excluded.before_image_hash,
      after_hash = excluded.after_hash,
      rollback_entry_json = excluded.rollback_entry_json,
      rollback_action = excluded.rollback_action,
      status = 'prepared',
      updated_at = now()
  returning snapshot_entry_id
)
select count(*) as journal_rows from journal;

with applied as (
  update channels ch
  set model_mappings = coalesce(ch.model_mappings, '{}'::jsonb) || $(Sql-Json $p.mapping_patch_json),
      updated_at = now()
  where ch.tenant_id = $(Sql-TextRequired $script:TenantId)::uuid
    and ch.id = $(Sql-TextRequired $p.internal_channel_id)::uuid
    and ch.deleted_at is null
  returning to_jsonb(ch.*) as after_image
)
select count(*) as applied_rows from applied;

update importer_apply_operation_journal
set status = 'applied',
    updated_at = now()
where transaction_id = $(Sql-TextRequired $transactionId)
  and snapshot_entry_id = $(Sql-TextRequired $rollbackEntryId)
  and status = 'prepared'
returning snapshot_entry_id;
"@
}

function New-ModelAssociationApplySql {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$OperationPlan
  )
  $write = Get-WriteOperation $Plan ([string]$OperationPlan.operation_id)
  $p = Get-OperationParameters $OperationPlan
  $transactionId = [string]$Plan.transaction_contract.transaction_id
  $targetJson = ConvertTo-CompactJson $OperationPlan.target 32
  $afterJson = ConvertTo-CompactJson $write.after 64
  $rollbackEntryId = [string]$OperationPlan.rollback_snapshot_entry_id
  $operationId = [string]$OperationPlan.operation_id
  $idempotencyKey = [string]$OperationPlan.idempotency_key
  $targetKind = [string]$OperationPlan.target.kind
  $targetHash = [string]$OperationPlan.target.natural_key_hash
  $afterHash = [string]$p.after_hash

  return @"
with captured as (
  select to_jsonb(ma.*) as object_json
  from model_associations ma
  join canonical_models cm
    on cm.tenant_id = ma.tenant_id
   and cm.id = ma.canonical_model_id
  where ma.tenant_id = $(Sql-TextRequired $script:TenantId)::uuid
    and cm.model_key = $(Sql-TextRequired $p.canonical_model_key)
    and ma.association_type = 'explicit_channel'
    and ma.channel_id = $(Sql-TextRequired $p.internal_channel_id)::uuid
    and coalesce(ma.upstream_model_name, '') = coalesce($(Sql-Text $p.upstream_model_name), '')
    and ma.deleted_at is null
    and cm.deleted_at is null
  for update
),
before_image as (
  select case
    when exists (select 1 from captured) then jsonb_build_object(
      'schema_version', 'importer.before-image.v1',
      'object_exists', true,
      'object_hash', md5((select object_json::text from captured)),
      'object', (select object_json from captured),
      'capture_mode', 'live_for_update',
      'dry_run_shape_only', false,
      'required_for_rollback', true
    )
    else jsonb_build_object(
      'schema_version', 'importer.before-image.v1',
      'object_exists', false,
      'object_hash', null,
      'object', null,
      'capture_mode', 'live_for_update_not_found',
      'dry_run_shape_only', false,
      'required_for_rollback', true
    )
  end as image
),
rollback_entry as (
  select
    image,
    jsonb_build_object(
      'snapshot_entry_id', $(Sql-TextRequired $rollbackEntryId),
      'operation_id', $(Sql-TextRequired $operationId),
      'target', $(Sql-Json $targetJson),
      'rollback_action', case when (image->>'object_exists')::boolean then 'restore_previous_object' else 'delete_created_object' end,
      'before', null,
      'before_image', image,
      'after_preview', $(Sql-Json $afterJson),
      'after_preview_hash', $(Sql-TextRequired $afterHash),
      'snapshot_mode', 'live_before_apply'
    ) as entry
  from before_image
),
journal as (
  insert into importer_apply_operation_journal (
    snapshot_entry_id, transaction_id, operation_id, operation_idempotency_key,
    target_kind, target_natural_key_hash, rollback_action, before_image_json,
    before_image_hash, after_hash, rollback_entry_json, status
  )
  select
    $(Sql-TextRequired $rollbackEntryId), $(Sql-TextRequired $transactionId), $(Sql-TextRequired $operationId), $(Sql-TextRequired $idempotencyKey),
    $(Sql-TextRequired $targetKind), $(Sql-TextRequired $targetHash), entry->>'rollback_action', image,
    image->>'object_hash', $(Sql-TextRequired $afterHash), entry, 'prepared'
  from rollback_entry
  on conflict (snapshot_entry_id) do update
  set transaction_id = excluded.transaction_id,
      operation_id = excluded.operation_id,
      operation_idempotency_key = excluded.operation_idempotency_key,
      target_kind = excluded.target_kind,
      target_natural_key_hash = excluded.target_natural_key_hash,
      before_image_json = excluded.before_image_json,
      before_image_hash = excluded.before_image_hash,
      after_hash = excluded.after_hash,
      rollback_entry_json = excluded.rollback_entry_json,
      rollback_action = excluded.rollback_action,
      status = 'prepared',
      updated_at = now()
  returning snapshot_entry_id
)
select count(*) as journal_rows from journal;

with canonical as (
  select id
  from canonical_models
  where tenant_id = $(Sql-TextRequired $script:TenantId)::uuid
    and model_key = $(Sql-TextRequired $p.canonical_model_key)
    and deleted_at is null
  limit 1
),
channel as (
  select id
  from channels
  where tenant_id = $(Sql-TextRequired $script:TenantId)::uuid
    and id = $(Sql-TextRequired $p.internal_channel_id)::uuid
    and deleted_at is null
  limit 1
),
updated as (
  update model_associations ma
  set priority = $(Sql-NullableInt $p.priority),
      conditions = $(Sql-Json $p.conditions_json),
      fallback_allowed = $(Sql-Bool $p.fallback_allowed),
      canary_percent = $(Sql-NullableDecimal $p.canary_percent),
      status = $(Sql-TextRequired $p.status),
      updated_at = now(),
      deleted_at = null
  from canonical, channel
  where ma.tenant_id = $(Sql-TextRequired $script:TenantId)::uuid
    and ma.canonical_model_id = canonical.id
    and ma.association_type = 'explicit_channel'
    and ma.channel_id = channel.id
    and coalesce(ma.upstream_model_name, '') = coalesce(nullif($(Sql-Text $p.upstream_model_name), ''), '')
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
    $(Sql-TextRequired $script:TenantId)::uuid, canonical.id, 'explicit_channel', channel.id, null,
    null, nullif($(Sql-Text $p.upstream_model_name), ''), $(Sql-NullableInt $p.priority),
    $(Sql-Json $p.conditions_json), $(Sql-Bool $p.fallback_allowed),
    $(Sql-NullableDecimal $p.canary_percent), $(Sql-TextRequired $p.status)
  from canonical, channel
  where not exists (select 1 from updated)
  returning to_jsonb(model_associations.*) as after_image
),
applied as (
  select after_image from updated
  union all
  select after_image from inserted
)
select count(*) as applied_rows from applied;

update importer_apply_operation_journal
set status = 'applied',
    updated_at = now()
where transaction_id = $(Sql-TextRequired $transactionId)
  and snapshot_entry_id = $(Sql-TextRequired $rollbackEntryId)
  and status = 'prepared'
returning snapshot_entry_id;
"@
}

function New-ApplyTransactionSql {
  param([Parameter(Mandatory = $true)]$Plan)
  $transactionId = [string]$Plan.transaction_contract.transaction_id
  $planKey = [string]$Plan.sql_executor_plan.plan_idempotency_key
  $parts = New-Object System.Collections.Generic.List[string]
  [void]$parts.Add("begin;")
  [void]$parts.Add("select pg_advisory_xact_lock(hashtextextended($(Sql-TextRequired $planKey), 0));")
  [void]$parts.Add((New-ApplyRunSql $Plan))
  foreach ($operationPlan in @(Convert-ToArray $Plan.sql_executor_plan.transaction.operation_plans)) {
    if (-not [bool]$operationPlan.supported) {
      throw "unsupported operation '$($operationPlan.operation_id)' cannot be applied by live runner"
    }
    switch ([string]$operationPlan.adapter) {
      "providers_upsert_v1" {
        [void]$parts.Add((New-ProviderApplySql -Plan $Plan -OperationPlan $operationPlan))
      }
      "channels_upsert_v1" {
        [void]$parts.Add((New-ChannelApplySql -Plan $Plan -OperationPlan $operationPlan))
      }
      "canonical_models_upsert_v1" {
        [void]$parts.Add((New-CanonicalModelApplySql -Plan $Plan -OperationPlan $operationPlan))
      }
      "model_associations_upsert_v1" {
        [void]$parts.Add((New-ModelAssociationApplySql -Plan $Plan -OperationPlan $operationPlan))
      }
      "channel_model_mappings_jsonb_merge_v1" {
        [void]$parts.Add((New-ChannelMappingApplySql -Plan $Plan -OperationPlan $operationPlan))
      }
      default {
        throw "adapter '$($operationPlan.adapter)' is not supported by live runner"
      }
    }
  }
  [void]$parts.Add("update importer_apply_runs set status = 'applied', updated_at = now() where transaction_id = $(Sql-TextRequired $transactionId);")
  [void]$parts.Add("commit;")
  return ($parts -join "`n")
}

function New-ProviderRollbackSql {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$OperationPlan
  )
  $p = Get-OperationParameters $OperationPlan
  $transactionId = [string]$Plan.transaction_contract.transaction_id
  $entryId = [string]$OperationPlan.rollback_snapshot_entry_id
  return @"
with journal as (
  select before_image_json
  from importer_apply_operation_journal
  where transaction_id = $(Sql-TextRequired $transactionId)
    and snapshot_entry_id = $(Sql-TextRequired $entryId)
    and status = 'applied'
  for update
),
rolled as (
  select case
    when not exists (select 1 from journal) then 'missing_or_not_applied'
    when ((select before_image_json->>'object_exists' from journal)::boolean) = false then 'delete_created_object'
    else 'restore_previous_object'
  end as action
),
delete_created as (
  delete from providers p
  using rolled
  where rolled.action = 'delete_created_object'
    and p.tenant_id = $(Sql-TextRequired $script:TenantId)::uuid
    and p.code = $(Sql-TextRequired $p.provider_code)
  returning p.id
),
restore_previous as (
  update providers p
  set name = journal.before_image_json->'object'->>'name',
      status = coalesce(journal.before_image_json->'object'->>'status', 'enabled'),
      metadata = coalesce(journal.before_image_json->'object'->'metadata', '{}'::jsonb),
      deleted_at = nullif(journal.before_image_json->'object'->>'deleted_at', '')::timestamptz,
      updated_at = now()
  from journal, rolled
  where rolled.action = 'restore_previous_object'
    and p.tenant_id = $(Sql-TextRequired $script:TenantId)::uuid
    and p.code = $(Sql-TextRequired $p.provider_code)
  returning p.id
),
guard as (
  select case
    when (select action from rolled) = 'delete_created_object' and exists (select 1 from delete_created) then true
    when (select action from rolled) = 'restore_previous_object' and exists (select 1 from restore_previous) then true
    else false
  end as ok
)
update importer_apply_operation_journal
set status = 'rolled_back',
    updated_at = now()
from guard
where transaction_id = $(Sql-TextRequired $transactionId)
  and snapshot_entry_id = $(Sql-TextRequired $entryId)
  and status = 'applied'
  and guard.ok = true
returning snapshot_entry_id;
"@
}

function New-ChannelRollbackSql {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$OperationPlan
  )
  $p = Get-OperationParameters $OperationPlan
  $transactionId = [string]$Plan.transaction_contract.transaction_id
  $entryId = [string]$OperationPlan.rollback_snapshot_entry_id
  return @"
with journal as (
  select before_image_json
  from importer_apply_operation_journal
  where transaction_id = $(Sql-TextRequired $transactionId)
    and snapshot_entry_id = $(Sql-TextRequired $entryId)
    and status = 'applied'
  for update
),
rolled as (
  select case
    when not exists (select 1 from journal) then 'missing_or_not_applied'
    when ((select before_image_json->>'object_exists' from journal)::boolean) = false then 'delete_created_object'
    else 'restore_previous_object'
  end as action
),
delete_created as (
  delete from channels ch
  using rolled
  where rolled.action = 'delete_created_object'
    and ch.tenant_id = $(Sql-TextRequired $script:TenantId)::uuid
    and ch.id = $(Sql-TextRequired $p.internal_channel_id)::uuid
  returning ch.id
),
restore_previous as (
  update channels ch
  set endpoint = journal.before_image_json->'object'->>'endpoint',
      protocol_mode = coalesce(journal.before_image_json->'object'->>'protocol_mode', 'openai_compatible'),
      status = coalesce(journal.before_image_json->'object'->>'status', 'enabled'),
      region = journal.before_image_json->'object'->>'region',
      priority = coalesce((journal.before_image_json->'object'->>'priority')::int, 100),
      weight = coalesce((journal.before_image_json->'object'->>'weight')::int, 100),
      tags = coalesce(journal.before_image_json->'object'->'tags', '[]'::jsonb),
      model_mappings = coalesce(journal.before_image_json->'object'->'model_mappings', '{}'::jsonb),
      request_overrides = coalesce(journal.before_image_json->'object'->'request_overrides', '[]'::jsonb),
      timeout_policy = coalesce(journal.before_image_json->'object'->'timeout_policy', '{}'::jsonb),
      probe_policy = coalesce(journal.before_image_json->'object'->'probe_policy', '{}'::jsonb),
      health_score = coalesce((journal.before_image_json->'object'->>'health_score')::numeric, 1.0),
      deleted_at = nullif(journal.before_image_json->'object'->>'deleted_at', '')::timestamptz,
      updated_at = now()
  from journal, rolled
  where rolled.action = 'restore_previous_object'
    and ch.tenant_id = $(Sql-TextRequired $script:TenantId)::uuid
    and ch.id = (journal.before_image_json->'object'->>'id')::uuid
  returning ch.id
),
guard as (
  select case
    when (select action from rolled) = 'delete_created_object' and exists (select 1 from delete_created) then true
    when (select action from rolled) = 'restore_previous_object' and exists (select 1 from restore_previous) then true
    else false
  end as ok
)
update importer_apply_operation_journal
set status = 'rolled_back',
    updated_at = now()
from guard
where transaction_id = $(Sql-TextRequired $transactionId)
  and snapshot_entry_id = $(Sql-TextRequired $entryId)
  and status = 'applied'
  and guard.ok = true
returning snapshot_entry_id;
"@
}

function New-CanonicalModelRollbackSql {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$OperationPlan
  )
  $p = Get-OperationParameters $OperationPlan
  $transactionId = [string]$Plan.transaction_contract.transaction_id
  $entryId = [string]$OperationPlan.rollback_snapshot_entry_id
  return @"
with journal as (
  select before_image_json
  from importer_apply_operation_journal
  where transaction_id = $(Sql-TextRequired $transactionId)
    and snapshot_entry_id = $(Sql-TextRequired $entryId)
    and status = 'applied'
  for update
),
rolled as (
  select case
    when not exists (select 1 from journal) then 'missing_or_not_applied'
    when ((select before_image_json->>'object_exists' from journal)::boolean) = false then 'delete_created_object'
    else 'restore_previous_object'
  end as action
),
delete_created as (
  delete from canonical_models cm
  using rolled
  where rolled.action = 'delete_created_object'
    and cm.tenant_id = $(Sql-TextRequired $script:TenantId)::uuid
    and cm.model_key = $(Sql-TextRequired $p.model_key)
  returning cm.id
),
restore_previous as (
  update canonical_models cm
  set display_name = journal.before_image_json->'object'->>'display_name',
      family = journal.before_image_json->'object'->>'family',
      capabilities = coalesce(journal.before_image_json->'object'->'capabilities', '{}'::jsonb),
      context_length = nullif(journal.before_image_json->'object'->>'context_length', '')::int,
      max_output_tokens = nullif(journal.before_image_json->'object'->>'max_output_tokens', '')::int,
      supports_stream = coalesce((journal.before_image_json->'object'->>'supports_stream')::boolean, true),
      supports_tools = coalesce((journal.before_image_json->'object'->>'supports_tools')::boolean, false),
      supports_vision = coalesce((journal.before_image_json->'object'->>'supports_vision')::boolean, false),
      supports_audio = coalesce((journal.before_image_json->'object'->>'supports_audio')::boolean, false),
      supports_reasoning = coalesce((journal.before_image_json->'object'->>'supports_reasoning')::boolean, false),
      default_price_book_id = nullif(journal.before_image_json->'object'->>'default_price_book_id', '')::uuid,
      visibility = coalesce(journal.before_image_json->'object'->>'visibility', 'internal'),
      status = coalesce(journal.before_image_json->'object'->>'status', 'active'),
      deleted_at = nullif(journal.before_image_json->'object'->>'deleted_at', '')::timestamptz,
      updated_at = now()
  from journal, rolled
  where rolled.action = 'restore_previous_object'
    and cm.tenant_id = $(Sql-TextRequired $script:TenantId)::uuid
    and cm.model_key = $(Sql-TextRequired $p.model_key)
  returning cm.id
),
guard as (
  select case
    when (select action from rolled) = 'delete_created_object' and exists (select 1 from delete_created) then true
    when (select action from rolled) = 'restore_previous_object' and exists (select 1 from restore_previous) then true
    else false
  end as ok
)
update importer_apply_operation_journal
set status = 'rolled_back',
    updated_at = now()
from guard
where transaction_id = $(Sql-TextRequired $transactionId)
  and snapshot_entry_id = $(Sql-TextRequired $entryId)
  and status = 'applied'
  and guard.ok = true
returning snapshot_entry_id;
"@
}

function New-ChannelMappingRollbackSql {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$OperationPlan
  )
  $p = Get-OperationParameters $OperationPlan
  $transactionId = [string]$Plan.transaction_contract.transaction_id
  $entryId = [string]$OperationPlan.rollback_snapshot_entry_id
  return @"
with journal as (
  select before_image_json
  from importer_apply_operation_journal
  where transaction_id = $(Sql-TextRequired $transactionId)
    and snapshot_entry_id = $(Sql-TextRequired $entryId)
    and status = 'applied'
  for update
),
restored as (
  update channels ch
  set model_mappings = coalesce(journal.before_image_json->'object'->'existing_model_mappings', '{}'::jsonb),
      updated_at = now()
  from journal
  where ch.tenant_id = $(Sql-TextRequired $script:TenantId)::uuid
    and ch.id = $(Sql-TextRequired $p.internal_channel_id)::uuid
    and ch.deleted_at is null
  returning ch.id
),
guard as (
  select exists (select 1 from restored) as ok
)
update importer_apply_operation_journal
set status = 'rolled_back',
    updated_at = now()
from guard
where transaction_id = $(Sql-TextRequired $transactionId)
  and snapshot_entry_id = $(Sql-TextRequired $entryId)
  and status = 'applied'
  and guard.ok = true
returning snapshot_entry_id;
"@
}

function New-ModelAssociationRollbackSql {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$OperationPlan
  )
  $p = Get-OperationParameters $OperationPlan
  $transactionId = [string]$Plan.transaction_contract.transaction_id
  $entryId = [string]$OperationPlan.rollback_snapshot_entry_id
  return @"
with journal as (
  select before_image_json
  from importer_apply_operation_journal
  where transaction_id = $(Sql-TextRequired $transactionId)
    and snapshot_entry_id = $(Sql-TextRequired $entryId)
    and status = 'applied'
  for update
),
rolled as (
  select case
    when not exists (select 1 from journal) then 'missing_or_not_applied'
    when ((select before_image_json->>'object_exists' from journal)::boolean) = false then 'delete_created_object'
    else 'restore_previous_object'
  end as action
),
target as (
  select ma.id
  from model_associations ma
  join canonical_models cm
    on cm.tenant_id = ma.tenant_id
   and cm.id = ma.canonical_model_id
  where ma.tenant_id = $(Sql-TextRequired $script:TenantId)::uuid
    and cm.model_key = $(Sql-TextRequired $p.canonical_model_key)
    and ma.association_type = 'explicit_channel'
    and ma.channel_id = $(Sql-TextRequired $p.internal_channel_id)::uuid
    and coalesce(ma.upstream_model_name, '') = coalesce($(Sql-Text $p.upstream_model_name), '')
    and ma.deleted_at is null
  limit 1
),
delete_created as (
  delete from model_associations ma
  using rolled, target
  where rolled.action = 'delete_created_object'
    and ma.id = target.id
  returning ma.id
),
restore_previous as (
  update model_associations ma
  set canonical_model_id = (journal.before_image_json->'object'->>'canonical_model_id')::uuid,
      association_type = journal.before_image_json->'object'->>'association_type',
      channel_id = nullif(journal.before_image_json->'object'->>'channel_id', '')::uuid,
      channel_tag = journal.before_image_json->'object'->>'channel_tag',
      model_pattern = journal.before_image_json->'object'->>'model_pattern',
      upstream_model_name = journal.before_image_json->'object'->>'upstream_model_name',
      priority = coalesce((journal.before_image_json->'object'->>'priority')::int, 100),
      conditions = coalesce(journal.before_image_json->'object'->'conditions', '{}'::jsonb),
      fallback_allowed = coalesce((journal.before_image_json->'object'->>'fallback_allowed')::boolean, true),
      canary_percent = coalesce((journal.before_image_json->'object'->>'canary_percent')::numeric, 100),
      status = coalesce(journal.before_image_json->'object'->>'status', 'enabled'),
      deleted_at = nullif(journal.before_image_json->'object'->>'deleted_at', '')::timestamptz,
      updated_at = now()
  from journal, rolled, target
  where rolled.action = 'restore_previous_object'
    and ma.id = target.id
  returning ma.id
),
guard as (
  select case
    when (select action from rolled) = 'delete_created_object' and exists (select 1 from delete_created) then true
    when (select action from rolled) = 'restore_previous_object' and exists (select 1 from restore_previous) then true
    else false
  end as ok
)
update importer_apply_operation_journal
set status = 'rolled_back',
    updated_at = now()
from guard
where transaction_id = $(Sql-TextRequired $transactionId)
  and snapshot_entry_id = $(Sql-TextRequired $entryId)
  and status = 'applied'
  and guard.ok = true
returning snapshot_entry_id;
"@
}

function New-RollbackTransactionSql {
  param([Parameter(Mandatory = $true)]$Plan)
  $transactionId = [string]$Plan.transaction_contract.transaction_id
  $rollbackKey = [string]$Plan.sql_executor_plan.rollback_snapshot_idempotency_key
  $operations = @(Convert-ToArray $Plan.sql_executor_plan.transaction.operation_plans)
  [array]::Reverse($operations)
  $parts = New-Object System.Collections.Generic.List[string]
  [void]$parts.Add("begin;")
  [void]$parts.Add("select pg_advisory_xact_lock(hashtextextended($(Sql-TextRequired $rollbackKey), 0));")
  foreach ($operationPlan in $operations) {
    switch ([string]$operationPlan.adapter) {
      "providers_upsert_v1" {
        [void]$parts.Add((New-ProviderRollbackSql -Plan $Plan -OperationPlan $operationPlan))
      }
      "channels_upsert_v1" {
        [void]$parts.Add((New-ChannelRollbackSql -Plan $Plan -OperationPlan $operationPlan))
      }
      "canonical_models_upsert_v1" {
        [void]$parts.Add((New-CanonicalModelRollbackSql -Plan $Plan -OperationPlan $operationPlan))
      }
      "model_associations_upsert_v1" {
        [void]$parts.Add((New-ModelAssociationRollbackSql -Plan $Plan -OperationPlan $operationPlan))
      }
      "channel_model_mappings_jsonb_merge_v1" {
        [void]$parts.Add((New-ChannelMappingRollbackSql -Plan $Plan -OperationPlan $operationPlan))
      }
      default {
        throw "adapter '$($operationPlan.adapter)' is not supported by rollback runner"
      }
    }
  }
  [void]$parts.Add(@"
update importer_apply_runs
set status = 'rolled_back',
    updated_at = now()
where transaction_id = $(Sql-TextRequired $transactionId)
  and not exists (
    select 1
    from importer_apply_operation_journal j
    where j.transaction_id = importer_apply_runs.transaction_id
      and j.status not in ('rolled_back', 'skipped_same_after_hash')
  );
"@)
  [void]$parts.Add("commit;")
  return ($parts -join "`n")
}

function Readback-Plan {
  param([Parameter(Mandatory = $true)]$Plan)
  $transactionId = [string]$Plan.transaction_contract.transaction_id
  $sql = @"
select jsonb_build_object(
  'run', (
    select to_jsonb(r)
    from importer_apply_runs r
    where r.transaction_id = $(Sql-TextRequired $transactionId)
  ),
  'operations', coalesce((
    select jsonb_agg(jsonb_build_object(
      'snapshot_entry_id', snapshot_entry_id,
      'operation_id', operation_id,
      'target_kind', target_kind,
      'status', status,
      'rollback_action', rollback_action,
      'before_image_object_exists', (before_image_json->>'object_exists')::boolean
    ) order by created_at, operation_id)
    from importer_apply_operation_journal
    where transaction_id = $(Sql-TextRequired $transactionId)
  ), '[]'::jsonb)
)::text;
"@
  $raw = Invoke-ComposePsql $sql
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  return ($raw | ConvertFrom-Json)
}

function Readback-Targets {
  param([Parameter(Mandatory = $true)]$Plan)
  $items = New-Object System.Collections.Generic.List[object]
  foreach ($operationPlan in @(Convert-ToArray $Plan.sql_executor_plan.transaction.operation_plans)) {
    $p = Get-OperationParameters $operationPlan
    if ([string]$operationPlan.adapter -eq "providers_upsert_v1") {
      $sql = @"
select coalesce((
  select jsonb_build_object(
    'kind', 'provider',
    'operation_id', $(Sql-TextRequired $operationPlan.operation_id),
    'provider_code', code,
    'internal_provider_id', id::text,
    'exists', true,
    'status', status,
    'deleted_at_is_null', deleted_at is null
  )
  from providers
  where tenant_id = $(Sql-TextRequired $script:TenantId)::uuid
    and code = $(Sql-TextRequired $p.provider_code)
    and deleted_at is null
  limit 1
), jsonb_build_object(
  'kind', 'provider',
  'operation_id', $(Sql-TextRequired $operationPlan.operation_id),
  'provider_code', $(Sql-TextRequired $p.provider_code),
  'exists', false
))::text;
"@
      [void]$items.Add((Invoke-ComposePsql $sql | ConvertFrom-Json))
    } elseif ([string]$operationPlan.adapter -eq "channels_upsert_v1") {
      $sql = @"
select coalesce((
  select jsonb_build_object(
    'kind', 'channel',
    'operation_id', $(Sql-TextRequired $operationPlan.operation_id),
    'provider_code', p.code,
    'channel_name', ch.name,
    'internal_channel_id', ch.id::text,
    'endpoint', ch.endpoint,
    'exists', true,
    'status', ch.status,
    'deleted_at_is_null', ch.deleted_at is null
  )
  from channels ch
  join providers p
    on p.tenant_id = ch.tenant_id
   and p.id = ch.provider_id
  where ch.tenant_id = $(Sql-TextRequired $script:TenantId)::uuid
    and ch.id = $(Sql-TextRequired $p.internal_channel_id)::uuid
    and ch.deleted_at is null
    and p.deleted_at is null
  limit 1
), jsonb_build_object(
  'kind', 'channel',
  'operation_id', $(Sql-TextRequired $operationPlan.operation_id),
  'provider_code', $(Sql-TextRequired $p.provider_code),
  'channel_name', $(Sql-TextRequired $p.channel_name),
  'internal_channel_id', $(Sql-TextRequired $p.internal_channel_id),
  'exists', false
))::text;
"@
      [void]$items.Add((Invoke-ComposePsql $sql | ConvertFrom-Json))
    } elseif ([string]$operationPlan.adapter -eq "canonical_models_upsert_v1") {
      $sql = @"
select coalesce((
  select jsonb_build_object(
    'kind', 'canonical_model',
    'operation_id', $(Sql-TextRequired $operationPlan.operation_id),
    'model_key', model_key,
    'exists', true,
    'status', status,
    'deleted_at_is_null', deleted_at is null
  )
  from canonical_models
  where tenant_id = $(Sql-TextRequired $script:TenantId)::uuid
    and model_key = $(Sql-TextRequired $p.model_key)
    and deleted_at is null
  limit 1
), jsonb_build_object(
  'kind', 'canonical_model',
  'operation_id', $(Sql-TextRequired $operationPlan.operation_id),
  'model_key', $(Sql-TextRequired $p.model_key),
  'exists', false
))::text;
"@
      [void]$items.Add((Invoke-ComposePsql $sql | ConvertFrom-Json))
    } elseif ([string]$operationPlan.adapter -eq "model_associations_upsert_v1") {
      $sql = @"
select coalesce((
  select jsonb_build_object(
    'kind', 'model_association',
    'operation_id', $(Sql-TextRequired $operationPlan.operation_id),
    'canonical_model_key', cm.model_key,
    'internal_channel_id', ma.channel_id::text,
    'upstream_model_name', ma.upstream_model_name,
    'fallback_allowed', ma.fallback_allowed,
    'status', ma.status,
    'exists', true
  )
  from model_associations ma
  join canonical_models cm
    on cm.tenant_id = ma.tenant_id
   and cm.id = ma.canonical_model_id
  where ma.tenant_id = $(Sql-TextRequired $script:TenantId)::uuid
    and cm.model_key = $(Sql-TextRequired $p.canonical_model_key)
    and ma.association_type = 'explicit_channel'
    and ma.channel_id = $(Sql-TextRequired $p.internal_channel_id)::uuid
    and coalesce(ma.upstream_model_name, '') = coalesce($(Sql-Text $p.upstream_model_name), '')
    and ma.deleted_at is null
  limit 1
), jsonb_build_object(
  'kind', 'model_association',
  'operation_id', $(Sql-TextRequired $operationPlan.operation_id),
  'canonical_model_key', $(Sql-TextRequired $p.canonical_model_key),
  'internal_channel_id', $(Sql-TextRequired $p.internal_channel_id),
  'upstream_model_name', $(Sql-Text $p.upstream_model_name),
  'exists', false
))::text;
"@
      [void]$items.Add((Invoke-ComposePsql $sql | ConvertFrom-Json))
    } elseif ([string]$operationPlan.adapter -eq "channel_model_mappings_jsonb_merge_v1") {
      $sql = @"
select coalesce((
  select jsonb_build_object(
    'kind', 'channel_mapping_entry',
    'operation_id', $(Sql-TextRequired $operationPlan.operation_id),
    'internal_channel_id', id::text,
    'requested_model', $(Sql-TextRequired $p.requested_model),
    'upstream_model_name', model_mappings ->> $(Sql-TextRequired $p.requested_model),
    'exists', (model_mappings ? $(Sql-TextRequired $p.requested_model))
  )
  from channels
  where tenant_id = $(Sql-TextRequired $script:TenantId)::uuid
    and id = $(Sql-TextRequired $p.internal_channel_id)::uuid
    and deleted_at is null
  limit 1
), jsonb_build_object(
  'kind', 'channel_mapping_entry',
  'operation_id', $(Sql-TextRequired $operationPlan.operation_id),
  'internal_channel_id', $(Sql-TextRequired $p.internal_channel_id),
  'requested_model', $(Sql-TextRequired $p.requested_model),
  'exists', false
))::text;
"@
      [void]$items.Add((Invoke-ComposePsql $sql | ConvertFrom-Json))
    }
  }
  return @($items.ToArray())
}

function Assert-OperationReadbackComplete {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$Readback,
    [Parameter(Mandatory = $true)][string]$Phase
  )

  $expected = @(Convert-ToArray $Plan.sql_executor_plan.transaction.operation_plans)
  $actual = @(Convert-ToArray $Readback.operations)
  if ($actual.Count -ne $expected.Count) {
    throw "$Phase operation journal readback count mismatch: expected $($expected.Count), got $($actual.Count)"
  }

  foreach ($operationPlan in $expected) {
    $operationId = [string]$operationPlan.operation_id
    $matches = @($actual | Where-Object { [string]$_.operation_id -eq $operationId })
    if ($matches.Count -ne 1) {
      throw "$Phase operation journal missing operation '$operationId'"
    }
  }
}

function Write-Artifact {
  param([Parameter(Mandatory = $true)]$Artifact)
  $full = Join-Path $script:RepoRoot $ArtifactPath
  $dir = Split-Path -Parent $full
  if (-not (Test-Path $dir)) {
    [void](New-Item -ItemType Directory -Force -Path $dir)
  }
  $Artifact | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $full -Encoding UTF8
}

if (-not $Force) {
  throw "Live importer apply requires -Force because it writes to PostgreSQL."
}

if (-not $ConfirmReviewedPlan) {
  throw "Live importer apply requires -ConfirmReviewedPlan after the apply-plan diff, idempotency manifest, rollback snapshot, and provider-key handoff have been reviewed."
}

$status = "pass"
$plan = $null
$applyReadback = $null
$rollbackReadback = $null
$targetAfterApply = @()
$targetAfterRollback = @()

try {
  $plan = Invoke-ApplyPlan
  if ([string]$plan.preflight.status -ne "pass") {
    [void]$script:Blockers.Add("apply_plan_preflight_not_pass")
  }
  if ([string]$plan.sql_executor_plan.executor_status -ne "prepared_sql_plan") {
    [void]$script:Blockers.Add("apply_plan_not_prepared_sql_plan")
  }
  $unsupported = @(Convert-ToArray $plan.sql_executor_plan.unsupported_operations)
  if ($unsupported.Count -gt 0) {
    [void]$script:Blockers.Add("unsupported_operations_present")
  }

  foreach ($operationPlan in @(Convert-ToArray $plan.sql_executor_plan.transaction.operation_plans)) {
    if (@("providers_upsert_v1", "channels_upsert_v1", "canonical_models_upsert_v1", "model_associations_upsert_v1", "channel_model_mappings_jsonb_merge_v1") -notcontains [string]$operationPlan.adapter) {
      [void]$script:Blockers.Add("unsupported_adapter:$($operationPlan.adapter)")
    }
  }

  if ($script:Blockers.Count -eq 0) {
    Initialize-ImporterJournalTables $plan
    [void](Invoke-ComposePsql (New-ApplyTransactionSql $plan))
    $applyReadback = Readback-Plan $plan
    Assert-OperationReadbackComplete -Plan $plan -Readback $applyReadback -Phase "apply"
    $targetAfterApply = @(Readback-Targets $plan)
    foreach ($operation in @(Convert-ToArray $applyReadback.operations)) {
      if ([string]$operation.status -ne "applied") {
        throw "operation '$($operation.operation_id)' was not marked applied"
      }
    }
    foreach ($target in $targetAfterApply) {
      if (-not [bool]$target.exists) {
        throw "target '$($target.kind)' for operation '$($target.operation_id)' was not present after apply"
      }
    }
    if ($RollbackAfterApply) {
      [void](Invoke-ComposePsql (New-RollbackTransactionSql $plan))
      $rollbackReadback = Readback-Plan $plan
      Assert-OperationReadbackComplete -Plan $plan -Readback $rollbackReadback -Phase "rollback"
      $targetAfterRollback = @(Readback-Targets $plan)
      foreach ($operation in @(Convert-ToArray $rollbackReadback.operations)) {
        if ([string]$operation.status -ne "rolled_back" -and [string]$operation.status -ne "skipped_same_after_hash") {
          throw "operation '$($operation.operation_id)' was not rolled back"
        }
      }
    }
  }
} catch {
  $status = "fail"
  [void]$script:Blockers.Add($_.Exception.Message)
}

if ($script:Blockers.Count -gt 0) {
  $status = "fail"
}

$artifact = [ordered]@{
  importer = "importer-apply-live-runtime"
  schema = "importer_apply_live_runtime.v1"
  schema_version = "importer.apply-live-runtime.v1"
  generated_at_utc = [DateTimeOffset]::UtcNow.ToString("O")
  status = $status
  dry_run = $false
  input_path = $InputPath
  existing_state_path = if ([string]::IsNullOrWhiteSpace($ExistingStatePath)) { $null } else { $ExistingStatePath }
  tenant_id = $script:TenantId
  compose_file = $script:ComposeFile
  apply_supported = $true
  sql_plan_executor_supported = $true
  apply_blocked = ($status -ne "pass")
  apply_contract = [ordered]@{
    default_mode = "local_demo_postgresql_apply_live"
    real_apply_status = if ($status -eq "pass") { "local_demo_apply_live_pass" } else { "local_demo_apply_live_failed" }
    apply_requested = $true
    force_confirmed = [bool]$Force
    reviewed_plan_confirmed = [bool]$ConfirmReviewedPlan
    executor = "scripts/importers/invoke-import-apply-live.ps1"
    executor_status = if ($status -eq "pass") { "applied" } else { "failed_or_refused" }
    database_writes = ($status -eq "pass")
    live_database_connection = $true
    rollback_after_apply = [bool]$RollbackAfterApply
    provider_key_material_allowed = $false
    raw_sql_omitted = $true
    artifact_secret_safe = $true
  }
  live_database_connection = $true
  database_writes = ($status -eq "pass")
  rollback_after_apply = [bool]$RollbackAfterApply
  reviewed_plan_confirmed = [bool]$ConfirmReviewedPlan
  secret_safe = $true
  raw_sql_omitted = $true
  provider_key_material_allowed = $false
  plan = if ($null -eq $plan) { $null } else { [ordered]@{
      schema_version = [string]$plan.schema_version
      preflight_status = [string]$plan.preflight.status
      transaction_id = [string]$plan.transaction_contract.transaction_id
      plan_idempotency_key = [string]$plan.sql_executor_plan.plan_idempotency_key
      rollback_snapshot_idempotency_key = [string]$plan.sql_executor_plan.rollback_snapshot_idempotency_key
      executor_status = [string]$plan.sql_executor_plan.executor_status
      operation_count = @(Convert-ToArray $plan.sql_executor_plan.transaction.operation_plans).Count
      adapters = @(Convert-ToArray $plan.sql_executor_plan.transaction.operation_plans | ForEach-Object { [string]$_.adapter })
    } }
  apply_readback = $applyReadback
  target_after_apply = $targetAfterApply
  rollback_readback = $rollbackReadback
  target_after_rollback = $targetAfterRollback
  blockers = @($script:Blockers.ToArray())
}

Write-Artifact $artifact
$artifact | ConvertTo-Json -Depth 64

if ($status -ne "pass") {
  exit 1
}
