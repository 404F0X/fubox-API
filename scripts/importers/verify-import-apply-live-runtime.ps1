[CmdletBinding()]
param(
  [string]$ComposeFile = "deploy/docker-compose/docker-compose.yml",
  [string]$ArtifactPath = ".tmp\importers\import_apply_live_runtime_verification.json"
)

$ErrorActionPreference = "Stop"

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$script:Runner = Join-Path $script:RepoRoot "scripts\importers\invoke-import-apply-live.ps1"
$script:CanonicalFixture = Join-Path $script:RepoRoot "tests\fixtures\importers\apply_plan_canonical_only.sample.json"
$script:ChannelMappingFixture = Join-Path $script:RepoRoot "tests\fixtures\importers\apply_plan_channel_mapping_bound.sample.json"
$script:ProviderChannelUnboundFixture = Join-Path $script:RepoRoot "tests\fixtures\importers\apply_plan_provider_channel_unbound.sample.json"
$script:ModelAssociationFixture = Join-Path $script:RepoRoot "tests\fixtures\importers\apply_plan_model_association_bound.sample.json"
$script:ConflictBlockedFixture = Join-Path $script:RepoRoot "tests\fixtures\importers\apply_plan_conflict_blocked.sample.json"

. "$PSScriptRoot\..\common.ps1"

function Invoke-ComposePsql {
  param([Parameter(Mandatory = $true)][string]$Sql)
  Push-Location $script:RepoRoot
  try {
    $output = Invoke-Docker compose -f $ComposeFile exec -T postgres psql `
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

function Assert-Condition {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw "VERIFY FAILED: $Message" }
}

function Reset-FixtureState {
  $sql = @'
do $$
begin
  if to_regclass('public.importer_apply_operation_journal') is not null then
    delete from importer_apply_operation_journal
    where transaction_id in (
      'tx_importer_apply_plan_3d3a3df7d13ffecd',
      'tx_importer_apply_plan_4db7b5bb648795d6',
      'tx_importer_apply_plan_80b9b202cdfe8e34',
      'tx_importer_apply_plan_885d9f31a8778636',
      'tx_importer_apply_plan_c8857f2e35ce4fec'
    );
  end if;
  if to_regclass('public.importer_apply_runs') is not null then
    delete from importer_apply_runs
    where transaction_id in (
      'tx_importer_apply_plan_3d3a3df7d13ffecd',
      'tx_importer_apply_plan_4db7b5bb648795d6',
      'tx_importer_apply_plan_80b9b202cdfe8e34',
      'tx_importer_apply_plan_885d9f31a8778636',
      'tx_importer_apply_plan_c8857f2e35ce4fec'
    );
  end if;
end $$;

delete from model_associations
where tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
  and channel_id = '7adcf326-8406-1065-ab4f-657823dac8c3'::uuid;

delete from model_associations ma
using canonical_models cm
where ma.tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
  and cm.tenant_id = ma.tenant_id
  and cm.id = ma.canonical_model_id
  and cm.model_key = 'fixture-gpt-4o'
  and ma.channel_id = '22222222-2222-4222-8222-222222222222'::uuid
  and coalesce(ma.upstream_model_name, '') = 'openai/gpt-4o-2024-08-06';

delete from canonical_models
where tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
  and model_key in ('fixture-gpt-4o', 'fixture-conflict-gpt-4o');

update channels
set model_mappings = model_mappings - 'fixture-auto-gpt',
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
  and (
    id = '7adcf326-8406-1065-ab4f-657823dac8c3'::uuid
    or name = 'fixture-auto-openai-primary'
  );

delete from channels
where tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
  and (
    id = '7adcf326-8406-1065-ab4f-657823dac8c3'::uuid
    or name = 'fixture-auto-openai-primary'
  );

delete from providers
where tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
  and code = 'fixture-auto-openai';

insert into providers (id, tenant_id, code, name, status, metadata)
values (
  '11111111-1111-4111-8111-111111111111'::uuid,
  '00000000-0000-0000-0000-000000000001'::uuid,
  'fixture-import-openai',
  'Fixture Import OpenAI',
  'enabled',
  '{"fixture":"import_apply_live"}'::jsonb
)
on conflict (tenant_id, code) do update
set name = excluded.name,
    status = 'enabled',
    deleted_at = null,
    updated_at = now();

insert into channels (
  id, tenant_id, provider_id, name, endpoint, protocol_mode, status,
  region, priority, weight, tags, model_mappings, request_overrides,
  timeout_policy, probe_policy, health_score
)
values (
  '22222222-2222-4222-8222-222222222222'::uuid,
  '00000000-0000-0000-0000-000000000001'::uuid,
  '11111111-1111-4111-8111-111111111111'::uuid,
  'fixture-import-openai-primary',
  'http://mock-provider:18080',
  'openai_compatible',
  'enabled',
  'local',
  100,
  100,
  '["fixture","import-apply-live"]'::jsonb,
  '{}'::jsonb,
  '[]'::jsonb,
  '{}'::jsonb,
  '{}'::jsonb,
  1.0
)
on conflict (tenant_id, provider_id, name) do update
set endpoint = excluded.endpoint,
    protocol_mode = excluded.protocol_mode,
    status = 'enabled',
    deleted_at = null,
    updated_at = now();

update channels
set model_mappings = model_mappings - 'fixture-gpt-4o',
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
  and id = '22222222-2222-4222-8222-222222222222'::uuid;
'@
  [void](Invoke-ComposePsql $sql)
}

function Seed-AssociationFixtureCanonicalModel {
  $sql = @'
insert into canonical_models (
  id, tenant_id, model_key, display_name, family, capabilities,
  context_length, max_output_tokens, supports_stream, supports_tools,
  supports_vision, supports_audio, supports_reasoning, visibility, status
)
values (
  '33333333-3333-4333-8333-333333333333'::uuid,
  '00000000-0000-0000-0000-000000000001'::uuid,
  'fixture-gpt-4o',
  'Fixture GPT-4o',
  'gpt-4o',
  '{"text":true,"tool":true}'::jsonb,
  128000,
  4096,
  true,
  true,
  false,
  false,
  false,
  'internal',
  'active'
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
    visibility = excluded.visibility,
    status = excluded.status,
    deleted_at = null,
    updated_at = now();
'@
  [void](Invoke-ComposePsql $sql)
}

function Invoke-LiveRunner {
  param(
    [string]$Name,
    [string]$InputPath,
    [string]$OutputPath
  )
  $raw = & $script:Runner `
    -InputPath $InputPath `
    -ComposeFile $ComposeFile `
    -ArtifactPath $OutputPath `
    -RollbackAfterApply `
    -ConfirmReviewedPlan `
    -Force
  if ($LASTEXITCODE -ne 0) {
    throw "$Name live runner exited with $LASTEXITCODE"
  }
  $text = ($raw | Out-String).Trim()
  Assert-Condition (-not [string]::IsNullOrWhiteSpace($text)) "$Name live runner emitted JSON"
  return ($text | ConvertFrom-Json)
}

function Invoke-LiveRunnerExpectRefusal {
  param(
    [string]$Name,
    [string]$InputPath,
    [string]$OutputPath
  )
  $raw = & $script:Runner `
    -InputPath $InputPath `
    -ComposeFile $ComposeFile `
    -ArtifactPath $OutputPath `
    -RollbackAfterApply `
    -ConfirmReviewedPlan `
    -Force
  $exitCode = $LASTEXITCODE
  $text = ($raw | Out-String).Trim()
  Assert-Condition ($exitCode -ne 0) "$Name live runner refused with non-zero exit"
  Assert-Condition (-not [string]::IsNullOrWhiteSpace($text)) "$Name live runner emitted refusal JSON"
  return ($text | ConvertFrom-Json)
}

function Read-CanonicalModelPresence {
  param([Parameter(Mandatory = $true)][string]$ModelKey)
  $safeModelKey = $ModelKey.Replace("'", "''")
  $sql = @"
select coalesce((
  select jsonb_build_object(
    'kind', 'canonical_model',
    'model_key', model_key,
    'exists', true
  )
  from canonical_models
  where tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
    and model_key = '$safeModelKey'
    and deleted_at is null
  limit 1
), jsonb_build_object(
  'kind', 'canonical_model',
  'model_key', '$safeModelKey',
  'exists', false
))::text;
"@
  return (Invoke-ComposePsql $sql | ConvertFrom-Json)
}

$canonicalArtifactPath = ".tmp\importers\import_apply_live_runtime.canonical.json"
$channelArtifactPath = ".tmp\importers\import_apply_live_runtime.channel_mapping.json"
$providerChannelArtifactPath = ".tmp\importers\import_apply_live_runtime.provider_channel_unbound.json"
$associationArtifactPath = ".tmp\importers\import_apply_live_runtime.model_association.json"
$conflictBlockedArtifactPath = ".tmp\importers\import_apply_live_runtime.conflict_blocked.json"
$blockers = New-Object System.Collections.Generic.List[string]
$canonical = $null
$channel = $null
$providerChannel = $null
$association = $null
$conflictBlocked = $null
$conflictTargetAfterRefusal = $null

try {
  Assert-Condition (Test-Path -LiteralPath $script:Runner -PathType Leaf) "live runner exists"
  Assert-Condition (Test-Path -LiteralPath $script:CanonicalFixture -PathType Leaf) "canonical fixture exists"
  Assert-Condition (Test-Path -LiteralPath $script:ChannelMappingFixture -PathType Leaf) "channel mapping fixture exists"
  Assert-Condition (Test-Path -LiteralPath $script:ProviderChannelUnboundFixture -PathType Leaf) "provider/channel unbound fixture exists"
  Assert-Condition (Test-Path -LiteralPath $script:ModelAssociationFixture -PathType Leaf) "model association fixture exists"
  Assert-Condition (Test-Path -LiteralPath $script:ConflictBlockedFixture -PathType Leaf) "conflict-blocked fixture exists"

  Reset-FixtureState

  $canonical = Invoke-LiveRunner "canonical_model" $script:CanonicalFixture $canonicalArtifactPath
  Assert-Condition ($canonical.status -eq "pass") "canonical live apply status pass"
  Assert-Condition ($canonical.apply_readback.run.status -eq "applied") "canonical run applied"
  Assert-Condition ($canonical.rollback_readback.run.status -eq "rolled_back") "canonical run rolled back"
  Assert-Condition (@($canonical.target_after_apply | Where-Object { $_.kind -eq "canonical_model" -and $_.exists }).Count -eq 1) "canonical target exists after apply"
  Assert-Condition (@($canonical.target_after_rollback | Where-Object { $_.kind -eq "canonical_model" -and -not $_.exists }).Count -eq 1) "canonical target removed after rollback"

  $providerChannel = Invoke-LiveRunner "provider_channel_unbound" $script:ProviderChannelUnboundFixture $providerChannelArtifactPath
  Assert-Condition ($providerChannel.status -eq "pass") "provider/channel unbound live apply status pass"
  Assert-Condition ($providerChannel.provider_key_material_allowed -eq $false) "provider/channel unbound does not import provider key material"
  Assert-Condition ($providerChannel.apply_readback.run.status -eq "applied") "provider/channel unbound run applied"
  Assert-Condition ($providerChannel.rollback_readback.run.status -eq "rolled_back") "provider/channel unbound run rolled back"
  Assert-Condition (@($providerChannel.target_after_apply | Where-Object {
        $_.kind -eq "provider" -and
        $_.exists -and
        $_.provider_code -eq "fixture-auto-openai"
      }).Count -eq 1) "provider/channel unbound provider exists after apply"
  Assert-Condition (@($providerChannel.target_after_apply | Where-Object {
        $_.kind -eq "channel" -and
        $_.exists -and
        $_.provider_code -eq "fixture-auto-openai" -and
        $_.channel_name -eq "fixture-auto-openai-primary"
      }).Count -eq 1) "provider/channel unbound channel exists after apply"
  Assert-Condition (@($providerChannel.target_after_apply | Where-Object {
        $_.kind -eq "channel_mapping_entry" -and
        $_.exists -and
        $_.requested_model -eq "fixture-auto-gpt" -and
        $_.upstream_model_name -eq "openai/fixture-auto-gpt"
      }).Count -eq 1) "provider/channel unbound channel mapping exists after apply"
  Assert-Condition (@($providerChannel.target_after_rollback | Where-Object {
        $_.kind -eq "provider" -and
        $_.provider_code -eq "fixture-auto-openai" -and
        -not $_.exists
      }).Count -eq 1) "provider/channel unbound provider removed after rollback"
  Assert-Condition (@($providerChannel.target_after_rollback | Where-Object {
        $_.kind -eq "channel" -and
        $_.channel_name -eq "fixture-auto-openai-primary" -and
        -not $_.exists
      }).Count -eq 1) "provider/channel unbound channel removed after rollback"
  Assert-Condition (@($providerChannel.target_after_rollback | Where-Object {
        $_.kind -eq "channel_mapping_entry" -and
        $_.requested_model -eq "fixture-auto-gpt" -and
        -not $_.exists
      }).Count -eq 1) "provider/channel unbound channel mapping removed after rollback"

  $channel = Invoke-LiveRunner "channel_mapping_entry" $script:ChannelMappingFixture $channelArtifactPath
  Assert-Condition ($channel.status -eq "pass") "channel mapping live apply status pass"
  Assert-Condition ($channel.apply_readback.run.status -eq "applied") "channel mapping run applied"
  Assert-Condition ($channel.rollback_readback.run.status -eq "rolled_back") "channel mapping run rolled back"
  Assert-Condition (@($channel.target_after_apply | Where-Object {
        $_.kind -eq "channel_mapping_entry" -and
        $_.exists -and
        $_.upstream_model_name -eq "openai/gpt-4o-2024-08-06"
      }).Count -eq 1) "channel mapping target exists after apply"
  Assert-Condition (@($channel.target_after_rollback | Where-Object {
        $_.kind -eq "channel_mapping_entry" -and
        -not $_.exists
      }).Count -eq 1) "channel mapping target removed after rollback"

  Seed-AssociationFixtureCanonicalModel
  $association = Invoke-LiveRunner "model_association" $script:ModelAssociationFixture $associationArtifactPath
  Assert-Condition ($association.status -eq "pass") "model association live apply status pass"
  Assert-Condition ($association.apply_readback.run.status -eq "applied") "model association run applied"
  Assert-Condition ($association.rollback_readback.run.status -eq "rolled_back") "model association run rolled back"
  Assert-Condition (@($association.target_after_apply | Where-Object {
        $_.kind -eq "model_association" -and
        $_.exists -and
        $_.canonical_model_key -eq "fixture-gpt-4o" -and
        $_.upstream_model_name -eq "openai/gpt-4o-2024-08-06" -and
        $_.fallback_allowed -eq $false
      }).Count -eq 1) "model association target exists after apply"
  Assert-Condition (@($association.target_after_rollback | Where-Object {
        $_.kind -eq "model_association" -and
        -not $_.exists
      }).Count -eq 1) "model association target removed after rollback"

  $conflictBlocked = Invoke-LiveRunnerExpectRefusal "conflict_blocked" $script:ConflictBlockedFixture $conflictBlockedArtifactPath
  Assert-Condition ($conflictBlocked.status -eq "fail") "conflict-blocked refusal artifact status fail"
  Assert-Condition ($conflictBlocked.database_writes -eq $false) "conflict-blocked refusal records no database writes"
  Assert-Condition ($conflictBlocked.plan.preflight_status -eq "blocked") "conflict-blocked preflight status blocked"
  Assert-Condition (@($conflictBlocked.blockers | Where-Object { $_ -eq "apply_plan_preflight_not_pass" }).Count -eq 1) "conflict-blocked refusal includes preflight blocker"
  $conflictTargetAfterRefusal = Read-CanonicalModelPresence "fixture-conflict-gpt-4o"
  Assert-Condition (-not [bool]$conflictTargetAfterRefusal.exists) "conflict-blocked target was not written"
} catch {
  [void]$blockers.Add($_.Exception.Message)
}

$status = if ($blockers.Count -eq 0) { "pass" } else { "fail" }
$artifact = [ordered]@{
  schema = "importer_apply_live_runtime_verification.v1"
  generated_at_utc = [DateTimeOffset]::UtcNow.ToString("O")
  status = $status
  live_database_connection = $true
  database_writes = ($status -eq "pass")
  rollback_verified = ($status -eq "pass")
  reviewed_plan_confirmed = ($status -eq "pass")
  secret_safe = $true
  raw_sql_omitted = $true
  compose_file = $ComposeFile
  cases = @(
    [ordered]@{
      name = "canonical_model"
      artifact_path = $canonicalArtifactPath
      status = if ($null -eq $canonical) { "not_run" } else { [string]$canonical.status }
      transaction_id = if ($null -eq $canonical -or $null -eq $canonical.plan) { $null } else { [string]$canonical.plan.transaction_id }
    }
    [ordered]@{
      name = "provider_channel_unbound"
      artifact_path = $providerChannelArtifactPath
      status = if ($null -eq $providerChannel) { "not_run" } else { [string]$providerChannel.status }
      provider_key_material_allowed = if ($null -eq $providerChannel) { $null } else { [bool]$providerChannel.provider_key_material_allowed }
      transaction_id = if ($null -eq $providerChannel -or $null -eq $providerChannel.plan) { $null } else { [string]$providerChannel.plan.transaction_id }
    }
    [ordered]@{
      name = "channel_mapping_entry"
      artifact_path = $channelArtifactPath
      status = if ($null -eq $channel) { "not_run" } else { [string]$channel.status }
      transaction_id = if ($null -eq $channel -or $null -eq $channel.plan) { $null } else { [string]$channel.plan.transaction_id }
    }
    [ordered]@{
      name = "model_association"
      artifact_path = $associationArtifactPath
      status = if ($null -eq $association) { "not_run" } else { [string]$association.status }
      transaction_id = if ($null -eq $association -or $null -eq $association.plan) { $null } else { [string]$association.plan.transaction_id }
    }
    [ordered]@{
      name = "conflict_blocked_no_write_refusal"
      artifact_path = $conflictBlockedArtifactPath
      expected_refusal = $true
      status = if ($null -eq $conflictBlocked) { "not_run" } else { [string]$conflictBlocked.status }
      preflight_status = if ($null -eq $conflictBlocked -or $null -eq $conflictBlocked.plan) { $null } else { [string]$conflictBlocked.plan.preflight_status }
      database_writes = if ($null -eq $conflictBlocked) { $null } else { [bool]$conflictBlocked.database_writes }
      target_after_refusal = $conflictTargetAfterRefusal
      transaction_id = if ($null -eq $conflictBlocked -or $null -eq $conflictBlocked.plan) { $null } else { [string]$conflictBlocked.plan.transaction_id }
    }
  )
  blockers = @($blockers.ToArray())
}

$full = Join-Path $script:RepoRoot $ArtifactPath
$dir = Split-Path -Parent $full
if (-not (Test-Path $dir)) {
  [void](New-Item -ItemType Directory -Force -Path $dir)
}
$artifact | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $full -Encoding UTF8

if ($status -eq "pass") {
  Write-Host "import_apply_live_runtime_verification=pass"
  Write-Host "artifact=$ArtifactPath"
  exit 0
}

Write-Host "import_apply_live_runtime_verification=fail"
foreach ($blocker in $blockers) {
  Write-Host $blocker
}
exit 1
