param(
  [switch]$Apply,
  [string]$ComposeFile = "deploy\docker-compose\docker-compose.yml",
  [string]$SeedSqlPath = "db\dev-seeds\0003_dev_smoke_seed_reconcile.sql",
  [string]$OutputPath = ".tmp\new-api-mvp\mock_distribution_bootstrap.json"
)

$ErrorActionPreference = "Stop"

function Write-JsonArtifact {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][object]$Value
  )

  $directory = Split-Path -Parent $Path
  if ($directory) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
  }
  $Value | ConvertTo-Json -Depth 12 | Set-Content -Path $Path -Encoding UTF8
}

function Invoke-ComposePostgresSql {
  param(
    [Parameter(Mandatory = $true)][string]$Sql,
    [switch]$Quiet
  )

  $arguments = @(
    "compose",
    "-f",
    $ComposeFile,
    "exec",
    "-T",
    "postgres",
    "sh",
    "-lc",
    'export PGPASSWORD="$POSTGRES_PASSWORD"; psql -v ON_ERROR_STOP=1 -X -q -t -A -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
  )

  $output = $Sql | & docker @arguments 2>&1
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) {
    $message = ($output | Out-String).Trim()
    if ($message.Length -gt 600) {
      $message = $message.Substring(0, 600)
    }
    throw "postgres sql failed with exit ${exitCode}: $message"
  }

  if ($Quiet) {
    return $null
  }
  return ($output | Out-String).Trim()
}

function New-ReadbackSql {
  return @'
with constants as (
  select
    '00000000-0000-0000-0000-000000000001'::uuid as tenant_id,
    '00000000-0000-0000-0000-000000000020'::uuid as project_id,
    '00000000-0000-0000-0000-000000000030'::uuid as payload_policy_id,
    '00000000-0000-0000-0000-000000000040'::uuid as profile_id,
    '00000000-0000-0000-0000-000000000060'::uuid as provider_id,
    '00000000-0000-0000-0000-000000000070'::uuid as channel_id,
    '00000000-0000-0000-0000-000000000080'::uuid as model_id
),
checks as (
  select
    (select count(*) from tenants t, constants c where t.id = c.tenant_id and t.status = 'active' and t.deleted_at is null) as tenants,
    (select count(*) from projects p, constants c where p.tenant_id = c.tenant_id and p.id = c.project_id and p.status = 'active' and p.deleted_at is null) as projects,
    (select count(*) from payload_policies pp, constants c where pp.tenant_id = c.tenant_id and pp.id = c.payload_policy_id and pp.status = 'active' and pp.deleted_at is null and pp.mode = 'metadata_only') as payload_policies,
    (select count(*) from api_key_profiles akp, constants c where akp.tenant_id = c.tenant_id and akp.project_id = c.project_id and akp.id = c.profile_id and akp.status = 'active' and akp.deleted_at is null and akp.allowed_models ? 'mock-gpt-4o-mini') as api_key_profiles,
    (select count(*) from providers p, constants c where p.tenant_id = c.tenant_id and p.id = c.provider_id and p.code = 'mock-openai' and p.status = 'enabled' and p.deleted_at is null) as providers,
    (select count(*) from channels ch, constants c where ch.tenant_id = c.tenant_id and ch.id = c.channel_id and ch.provider_id = c.provider_id and ch.status = 'enabled' and ch.deleted_at is null and ch.endpoint like 'http://mock-provider:%') as channels,
    (select count(*) from provider_keys pk, constants c where pk.tenant_id = c.tenant_id and pk.channel_id = c.channel_id and pk.status = 'enabled' and pk.deleted_at is null and pk.secret_fingerprint is not null) as provider_keys,
    (select count(*) from canonical_models m, constants c where m.tenant_id = c.tenant_id and m.id = c.model_id and m.model_key = 'mock-gpt-4o-mini' and m.status = 'active' and m.deleted_at is null) as canonical_models,
    (select count(*) from model_associations ma, constants c where ma.tenant_id = c.tenant_id and ma.canonical_model_id = c.model_id and ma.channel_id = c.channel_id and ma.status = 'enabled' and ma.deleted_at is null and ma.upstream_model_name = 'mock-gpt-4o-mini') as model_associations
)
select jsonb_build_object(
  'tenant_active', tenants > 0,
  'project_active', projects > 0,
  'payload_policy_active', payload_policies > 0,
  'default_profile_active', api_key_profiles > 0,
  'mock_provider_enabled', providers > 0,
  'mock_channel_enabled', channels > 0,
  'mock_provider_key_enabled', provider_keys > 0,
  'mock_model_active', canonical_models > 0,
  'mock_model_routable', model_associations > 0,
  'counts', jsonb_build_object(
    'tenants', tenants,
    'projects', projects,
    'payload_policies', payload_policies,
    'api_key_profiles', api_key_profiles,
    'providers', providers,
    'channels', channels,
    'provider_keys', provider_keys,
    'canonical_models', canonical_models,
    'model_associations', model_associations
  )
)::text
from checks;
'@
}

$startedAt = (Get-Date).ToUniversalTime()
$blockers = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]
$readback = $null
$applyAttempted = [bool]$Apply
$applySucceeded = $false

try {
  if ($Apply) {
    if (-not (Test-Path -LiteralPath $SeedSqlPath)) {
      throw "seed sql not found: $SeedSqlPath"
    }
    $seedSql = Get-Content -Raw -LiteralPath $SeedSqlPath
    [void](Invoke-ComposePostgresSql -Sql $seedSql -Quiet)
    $applySucceeded = $true
  }

  $readbackText = Invoke-ComposePostgresSql -Sql (New-ReadbackSql)
  $readback = $readbackText | ConvertFrom-Json

  foreach ($property in @(
      "tenant_active",
      "project_active",
      "payload_policy_active",
      "default_profile_active",
      "mock_provider_enabled",
      "mock_channel_enabled",
      "mock_provider_key_enabled",
      "mock_model_active",
      "mock_model_routable"
    )) {
    if (-not [bool]$readback.$property) {
      [void]$blockers.Add($property)
    }
  }
} catch {
  [void]$blockers.Add("bootstrap_readback_failed")
  [void]$warnings.Add(($_.Exception.Message -replace '(?i)(password|authorization|cookie|provider[_-]?key|virtual[_-]?key|database[_-]?url)\s*[:=]\s*\S+', '$1=[REDACTED]'))
}

$status = if ($blockers.Count -eq 0) { "pass" } elseif ($Apply -and -not $applySucceeded) { "failed" } else { "blocked" }
$artifact = [ordered]@{
  schema = "new_api_mock_distribution_bootstrap.v1"
  generated_at_utc = $startedAt.ToString("o")
  status = $status
  apply_attempted = $applyAttempted
  apply_succeeded = $applySucceeded
  scope = "local_open_source_alpha_mock_provider_default_distribution"
  compose_file = $ComposeFile.Replace("\", "/")
  seed_sql_path = $SeedSqlPath.Replace("\", "/")
  default_tenant_id = "00000000-0000-0000-0000-000000000001"
  default_project_id = "00000000-0000-0000-0000-000000000020"
  default_profile_name = "Default OpenAI Compatible"
  model = "mock-gpt-4o-mini"
  mock_provider_path = $true
  readback = $readback
  secret_safe_policy = [ordered]@{
    raw_provider_key_echoed = $false
    raw_virtual_key_secret_echoed = $false
    authorization_header_echoed = $false
    database_url_echoed = $false
    raw_voucher_code_echoed = $false
  }
  warnings = @($warnings)
  blockers = @($blockers)
  completed_at_utc = (Get-Date).ToUniversalTime().ToString("o")
}

Write-JsonArtifact -Path $OutputPath -Value $artifact

if ($status -eq "pass") {
  exit 0
}
if ($status -eq "blocked") {
  exit 2
}
exit 1
