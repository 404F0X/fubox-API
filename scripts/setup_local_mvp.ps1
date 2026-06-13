<#
.SYNOPSIS
Applies the local MVP setup seed for a development compose database.

.DESCRIPTION
This is a local/dev-only setup entry for the Setup Wizard MVP. It creates or
repairs the deterministic development admin, mock provider, default mock model,
model route, provider key placeholder, and smoke virtual key records by applying
the existing idempotent migration/dev-seed SQL files inside the compose
PostgreSQL container.

It is not a production installer. It never prints provider secrets or raw API key
values; use scripts/dev_login_check.ps1 defaults for the local smoke path.
#>
param(
  [int]$TimeoutSeconds = 60,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\common.ps1"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$composeFile = Join-Path $repoRoot "deploy\docker-compose\docker-compose.yml"

$seedFiles = @(
  "/app/db/migrations/0002_upgrade_dev_skeleton.sql",
  "/app/db/migrations/0011_opening_balance_imports.sql",
  "/app/db/migrations/0012_recharge_voucher_boundary.sql",
  "/app/db/dev-seeds/0002_dev_gateway_seed.sql",
  "/app/db/dev-seeds/0003_dev_smoke_seed_reconcile.sql",
  "/app/db/dev-seeds/0001_dev_admin_seed.sql"
)

function Write-Step {
  param([string]$Message)
  Write-Host "[setup-local-mvp] $Message"
}

function Invoke-Capture {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [int]$TimeoutSeconds = 60
  )

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo.FileName = $FilePath
  foreach ($arg in $Arguments) {
    [void]$process.StartInfo.ArgumentList.Add($arg)
  }
  $process.StartInfo.WorkingDirectory = $repoRoot
  $process.StartInfo.UseShellExecute = $false
  $process.StartInfo.RedirectStandardOutput = $true
  $process.StartInfo.RedirectStandardError = $true

  try {
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
      try { $process.Kill($true) } catch { $process.Kill() }
      return [PSCustomObject]@{
        ExitCode = 124
        Stdout = ""
        Stderr = "command timed out after ${TimeoutSeconds}s"
      }
    }

    return [PSCustomObject]@{
      ExitCode = $process.ExitCode
      Stdout = $stdoutTask.GetAwaiter().GetResult()
      Stderr = $stderrTask.GetAwaiter().GetResult()
    }
  } finally {
    $process.Dispose()
  }
}

function Invoke-PostgresSql {
  param(
    [Parameter(Mandatory = $true)][string]$Sql,
    [int]$TimeoutSeconds = 60
  )

  $result = Invoke-Capture -FilePath $docker -Arguments @(
    "compose", "-f", $composeFile, "exec", "-T", "postgres",
    "psql", "-U", "ai_gateway", "-d", "ai_gateway",
    "-v", "ON_ERROR_STOP=1", "--tuples-only", "--no-align", "-c", $Sql
  ) -TimeoutSeconds $TimeoutSeconds
  if ($result.ExitCode -ne 0) {
    throw "local MVP readback failed: $($result.Stderr.Trim()) $($result.Stdout.Trim())"
  }

  return $result.Stdout.Trim()
}

if ($TimeoutSeconds -le 0) { throw "TimeoutSeconds must be greater than zero." }
if (-not (Test-Path -LiteralPath $composeFile)) { throw "Missing compose file: $composeFile" }

$docker = Get-DockerCommand
Write-Step "scope=local_dev only; production installer=false; secret_output=omitted"
Write-Step "compose file: $composeFile"

if ($DryRun) {
  foreach ($seed in $seedFiles) {
    Write-Step "would apply idempotent seed: $seed"
  }
  Write-Step "would run secret-safe readback for four Setup Wizard steps: admin, mock provider/channel/model, test-key, gateway model/chat readiness"
  Write-Host "setup_local_mvp_status=dry-run"
  Write-Host "setup_local_mvp_contract=admin_setup_readback.v1 four_steps prod_credentials_required=false secret_output=omitted"
  exit 0
}

foreach ($seed in $seedFiles) {
  Write-Step "applying idempotent seed: $seed"
  $result = Invoke-Capture -FilePath $docker -Arguments @(
    "compose", "-f", $composeFile, "exec", "-T", "postgres",
    "psql", "-U", "ai_gateway", "-d", "ai_gateway", "-v", "ON_ERROR_STOP=1", "-f", $seed
  ) -TimeoutSeconds $TimeoutSeconds
  if ($result.ExitCode -ne 0) {
    throw "local MVP setup seed failed for ${seed}: $($result.Stderr.Trim()) $($result.Stdout.Trim())"
  }
}

$readbackSql = @'
with checks as (
  select
    exists (
      select 1 from users
      where tenant_id = '00000000-0000-0000-0000-000000000001'
        and id = '00000000-0000-0000-0000-0000000000a1'
        and email = 'admin@example.com'
        and status = 'active'
        and deleted_at is null
    ) as admin_exists,
    exists (
      select 1 from providers
      where tenant_id = '00000000-0000-0000-0000-000000000001'
        and code = 'mock-openai'
        and status = 'enabled'
        and deleted_at is null
    ) as mock_provider_enabled,
    exists (
      select 1 from channels c
      join providers p on p.id = c.provider_id and p.tenant_id = c.tenant_id
      where c.tenant_id = '00000000-0000-0000-0000-000000000001'
        and p.code = 'mock-openai'
        and c.name = 'mock-openai-default'
        and c.status = 'enabled'
        and c.deleted_at is null
    ) as mock_channel_enabled,
    exists (
      select 1 from provider_keys pk
      join channels c on c.id = pk.channel_id and c.tenant_id = pk.tenant_id
      where pk.tenant_id = '00000000-0000-0000-0000-000000000001'
        and c.name = 'mock-openai-default'
        and pk.key_alias = 'mock-dev-key'
        and pk.status = 'enabled'
        and pk.secret_fingerprint is not null
        and pk.deleted_at is null
    ) as mock_provider_key_configured,
    exists (
      select 1 from canonical_models
      where tenant_id = '00000000-0000-0000-0000-000000000001'
        and model_key = 'mock-gpt-4o-mini'
        and status = 'active'
        and deleted_at is null
    ) as default_model_active,
    exists (
      select 1
      from model_associations ma
      join canonical_models cm on cm.id = ma.canonical_model_id and cm.tenant_id = ma.tenant_id
      join channels c on c.id = ma.channel_id and c.tenant_id = ma.tenant_id
      where ma.tenant_id = '00000000-0000-0000-0000-000000000001'
        and cm.model_key = 'mock-gpt-4o-mini'
        and c.name = 'mock-openai-default'
        and ma.status = 'enabled'
        and ma.deleted_at is null
    ) as default_model_association_enabled,
    exists (
      select 1 from virtual_keys
      where tenant_id = '00000000-0000-0000-0000-000000000001'
        and project_id = '00000000-0000-0000-0000-000000000020'
        and key_prefix = 'dev_test_key'
        and status = 'active'
        and deleted_at is null
    ) as test_key_present,
    exists (
      select 1 from api_key_profiles
      where tenant_id = '00000000-0000-0000-0000-000000000001'
        and project_id = '00000000-0000-0000-0000-000000000020'
        and status = 'active'
        and deleted_at is null
    ) as active_profile_present,
    (
      select count(*)::int from request_logs
      where tenant_id = '00000000-0000-0000-0000-000000000001'
        and requested_model = 'mock-gpt-4o-mini'
        and (status = 'succeeded' or http_status = 200)
    ) as successful_mock_chat_requests
)
select jsonb_build_object(
  'schema', 'setup_local_mvp_readback.v1',
  'secret_safe', true,
  'admin_exists', admin_exists,
  'mock_provider_enabled', mock_provider_enabled,
  'mock_channel_enabled', mock_channel_enabled,
  'mock_provider_key_configured', mock_provider_key_configured,
  'default_model_active', default_model_active,
  'default_model_association_enabled', default_model_association_enabled,
  'test_key_present', test_key_present,
  'gateway_model_ready', (
    default_model_active
    and default_model_association_enabled
    and test_key_present
    and active_profile_present
  ),
  'gateway_chat_ready', successful_mock_chat_requests > 0,
  'successful_mock_chat_requests', successful_mock_chat_requests,
  'wizard_steps', jsonb_build_array(
    jsonb_build_object(
      'code', 'admin',
      'label', 'Admin',
      'status', case when admin_exists then 'ready' else 'blocked' end,
      'evidence', case when admin_exists then 'admin account present; raw password omitted' else 'admin account missing' end,
      'next_action', case when admin_exists then 'Login to Admin UI' else 'Run scripts/setup_local_mvp.ps1' end,
      'production_credentials_required', false
    ),
    jsonb_build_object(
      'code', 'mock_provider_channel_model',
      'label', 'Mock provider/channel/model',
      'status', case when mock_provider_enabled and mock_channel_enabled and mock_provider_key_configured and default_model_active and default_model_association_enabled then 'ready' else 'blocked' end,
      'evidence', concat(
        'provider=', case when mock_provider_enabled then 'ready' else 'missing' end,
        ' channel=', case when mock_channel_enabled then 'ready' else 'missing' end,
        ' provider_key=', case when mock_provider_key_configured then 'ready' else 'missing' end,
        ' model=', case when default_model_active then 'ready' else 'missing' end,
        ' association=', case when default_model_association_enabled then 'ready' else 'missing' end
      ),
      'next_action', case when mock_provider_enabled and mock_channel_enabled and mock_provider_key_configured and default_model_active and default_model_association_enabled then 'Keep mock provider running for local smoke' else 'Run scripts/setup_local_mvp.ps1' end,
      'production_credentials_required', false
    ),
    jsonb_build_object(
      'code', 'test_key',
      'label', 'Test key',
      'status', case when test_key_present then 'ready' else 'blocked' end,
      'evidence', case when test_key_present then 'dev_test_key active; raw secret omitted' else 'dev_test_key missing or inactive' end,
      'next_action', case when test_key_present then 'Use scripts/dev_login_check.ps1 for local smoke' else 'Run scripts/setup_local_mvp.ps1' end,
      'production_credentials_required', false
    ),
    jsonb_build_object(
      'code', 'gateway_model_chat_readiness',
      'label', 'Gateway model/chat readiness',
      'status', case when successful_mock_chat_requests > 0 then 'ready' when default_model_active and default_model_association_enabled and test_key_present and active_profile_present then 'attention' else 'blocked' end,
      'evidence', concat(
        'model=', case when default_model_active and default_model_association_enabled and test_key_present and active_profile_present then 'ready' else 'missing' end,
        ' chat_successes=', successful_mock_chat_requests
      ),
      'next_action', case when successful_mock_chat_requests > 0 then 'Open request logs for readback' when default_model_active and default_model_association_enabled and test_key_present and active_profile_present then 'Run scripts/dev_login_check.ps1 to exercise /v1/chat/completions' else 'Repair local seed/model/profile/key readiness with scripts/setup_local_mvp.ps1' end,
      'production_credentials_required', false
    )
  ),
  'omitted_fields', jsonb_build_array(
    'raw_admin_password',
    'provider_secret',
    'test_key_secret',
    'authorization',
    'raw_payload'
  ),
  'next_check', 'pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\dev_login_check.ps1'
)::text
from checks;
'@

$readbackJson = Invoke-PostgresSql -Sql $readbackSql -TimeoutSeconds $TimeoutSeconds
Write-Host "setup_local_mvp_status=pass"
Write-Host "setup_local_mvp_readback=$readbackJson"
Write-Host "admin_login_hint=local admin is seeded; raw password is intentionally not printed."
Write-Host "test_key_hint=local smoke key is seeded; raw key is intentionally not printed. scripts/dev_login_check.ps1 uses its default dev-only input."
Write-Host "ui_handoff=Admin Dashboard Setup Wizard can read GET /admin/setup/readback; User Portal handoff is /?mode=developer-console."
Write-Host "next_check=pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\dev_login_check.ps1"
