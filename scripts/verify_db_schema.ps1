param(
  [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = "Continue"
. "$PSScriptRoot\common.ps1"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$containerName = "ai-gateway-schema-check-" + [guid]::NewGuid().ToString("N").Substring(0, 12)
$migrationMount = "$repoRoot/db/migrations:/docker-entrypoint-initdb.d:ro"
$expectedTables = "api_key_profiles,model_associations,ledger_entries,audit_logs"

Push-Location $repoRoot
try {
  Invoke-Docker run `
    --name $containerName `
    -e POSTGRES_USER=ai_gateway `
    -e POSTGRES_PASSWORD=ai_gateway `
    -e POSTGRES_DB=ai_gateway `
    -v $migrationMount `
    -d postgres:16 | Out-Null

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $ready = $false
  $tableProbe = @"
select concat_ws(
  ',',
  to_regclass('public.api_key_profiles'),
  to_regclass('public.model_associations'),
  to_regclass('public.ledger_entries'),
  to_regclass('public.audit_logs')
);
"@

  while ((Get-Date) -lt $deadline) {
    $probe = Invoke-Docker exec $containerName psql `
      -U ai_gateway `
      -d ai_gateway `
      -tA `
      -v ON_ERROR_STOP=1 `
      -c $tableProbe 2>$null

    if ($LASTEXITCODE -eq 0 -and (($probe -join "").Trim() -eq $expectedTables)) {
      $ready = $true
      break
    }

    Start-Sleep -Seconds 1
  }

  if (-not $ready) {
    Write-Host "Schema check did not observe all expected tables before timeout."
    Invoke-Docker logs $containerName
    exit 1
  }

  Start-Sleep -Seconds 5
  $finalReady = $false
  while ((Get-Date) -lt $deadline) {
    Invoke-Docker exec $containerName psql `
      -U ai_gateway `
      -d ai_gateway `
      -tA `
      -v ON_ERROR_STOP=1 `
      -c "select 1;" 2>$null | Out-Null

    if ($LASTEXITCODE -eq 0) {
      $finalReady = $true
      break
    }

    Start-Sleep -Seconds 1
  }

  if (-not $finalReady) {
    Write-Host "Schema check database did not stabilize after initialization."
    Invoke-Docker logs $containerName
    exit 1
  }

  $assertions = @'
do $$
declare
  other_tenant_id uuid := gen_random_uuid();
  request_id uuid := gen_random_uuid();
begin
  begin
    insert into tenants (name, slug, status)
    values ('Invalid Tenant', 'invalid-tenant-status', 'invalid');
    raise exception 'invalid tenant status was accepted';
  exception when check_violation then
    null;
  end;

  insert into tenants (id, name, slug)
  values (other_tenant_id, 'Other Tenant', 'other-tenant');

  begin
    insert into request_logs (tenant_id, project_id, status)
    values (
      other_tenant_id,
      '00000000-0000-0000-0000-000000000020',
      'started'
    );
    raise exception 'cross-tenant project reference was accepted';
  exception when foreign_key_violation then
    null;
  end;

  insert into request_logs (id, tenant_id, project_id, status)
  values (
    request_id,
    '00000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000020',
    'started'
  );

  insert into ledger_entries (
    tenant_id,
    project_id,
    request_id,
    entry_type,
    amount,
    currency,
    idempotency_key
  )
  values (
    '00000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000020',
    request_id,
    'settle',
    1,
    'USD',
    'schema-check-settle-1'
  );

  begin
    insert into ledger_entries (
      tenant_id,
      project_id,
      request_id,
      entry_type,
      amount,
      currency,
      idempotency_key
    )
    values (
      '00000000-0000-0000-0000-000000000001',
      '00000000-0000-0000-0000-000000000020',
      request_id,
      'settle',
      2,
      'USD',
      'schema-check-settle-2'
    );
    raise exception 'duplicate settle for one request was accepted';
  exception when unique_violation then
    null;
  end;
end $$;
'@

  Invoke-Docker exec $containerName psql `
    -U ai_gateway `
    -d ai_gateway `
    -v ON_ERROR_STOP=1 `
    -c $assertions
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

  Invoke-Docker exec $containerName psql `
    -U ai_gateway `
    -d ai_gateway `
    -v ON_ERROR_STOP=1 `
    -c "select count(*) as tables from information_schema.tables where table_schema = 'public';"
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

  Write-Host "DB schema verification passed."
} finally {
  Invoke-Docker rm -f $containerName | Out-Null
  Pop-Location
}
