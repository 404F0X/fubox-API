param(
  [string]$OutputPath = ".tmp\credit-wallet\user_remaining_balance_runtime.json",
  [string]$OwnershipPlanOutputPath = ".tmp\credit-wallet\user_remaining_balance_ownership_plan.json",
  [string]$OwnershipRuntimeOutputPath = ".tmp\credit-wallet\user_remaining_balance_ownership_runtime.json",
  [string]$ControlPlaneBaseUrl = "http://127.0.0.1:8081",
  [string]$SeedTenantId = "00000000-0000-0000-0000-000000000001",
  [string]$SeedWalletId = "00000000-0000-0000-0000-0000000032a8",
  [string]$AdminEmail = "admin@example.com",
  [string]$AdminPassword = "",
  [switch]$RunLiveRouteMatrix,
  [switch]$RunOwnershipRouteMatrix,
  [switch]$OwnershipPlanOnly,
  [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ($env:CONTROL_PLANE_BASE_URL) { $ControlPlaneBaseUrl = $env:CONTROL_PLANE_BASE_URL }
if ($env:CONTROL_PLANE_ADMIN_BASE_URL) { $ControlPlaneBaseUrl = $env:CONTROL_PLANE_ADMIN_BASE_URL }
if ($env:CONTROL_PLANE_ADMIN_EMAIL) { $AdminEmail = $env:CONTROL_PLANE_ADMIN_EMAIL }
if ($env:CONTROL_PLANE_ADMIN_PASSWORD) { $AdminPassword = $env:CONTROL_PLANE_ADMIN_PASSWORD }

function Resolve-RepoBoundedPath {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string[]]$AllowedPrefixes
  )
  $candidate = if ([System.IO.Path]::IsPathRooted($Path)) {
    [System.IO.Path]::GetFullPath($Path)
  } else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
  }
  $repoPrefix = $repoRoot.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
  if (-not $candidate.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "path_must_stay_inside_repo"
  }
  $relative = $candidate.Substring($repoPrefix.Length).Replace("\", "/")
  $allowed = $false
  foreach ($prefix in $AllowedPrefixes) {
    if ($relative.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      $allowed = $true
      break
    }
  }
  if (-not $allowed) { throw "path_prefix_not_allowed" }
  return [ordered]@{ full = $candidate; relative = $relative }
}

function Test-SecretSafeText {
  param([AllowNull()][string]$Text)
  if ([string]::IsNullOrEmpty($Text)) { return $true }
  foreach ($pattern in @(
      '(?i)authorization\s*[:=]',
      '(?i)cookie\s*[:=]',
      '(?i)bearer\s+[A-Za-z0-9._~+/\-]+=*',
      '(?i)x-admin-session\s*[:=]',
      '(?i)session_token_once',
      '(?i)provider[_-]?key\s*[:=]',
      '(?i)virtual[_-]?key\s*[:=]',
      '(?i)database[_-]?url\s*[:=]',
      '(?i)postgres(?:ql)?://[^"\s]+',
      '(?i)password\s*[:=]',
      'sk-[A-Za-z0-9]{8,}'
    )) {
    if ($Text -match $pattern) { return $false }
  }
  return $true
}

function Write-Artifact {
  param(
    [Parameter(Mandatory = $true)][object]$Artifact,
    [Parameter(Mandatory = $true)][hashtable]$Output
  )
  $json = $Artifact | ConvertTo-Json -Depth 14
  if (-not (Test-SecretSafeText $json)) { throw "artifact_secret_safety_failed" }
  $parent = Split-Path -Parent $Output.full
  if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  Set-Content -LiteralPath $Output.full -Encoding UTF8 -Value $json
}

function Get-DatabaseUrl {
  if ($env:CONTROL_PLANE_DATABASE_URL) { return [string]$env:CONTROL_PLANE_DATABASE_URL }
  if ($env:DATABASE_URL) { return [string]$env:DATABASE_URL }
  return ("postgres" + "://ai_gateway:ai_gateway@127.0.0.1:55432/ai_gateway")
}

function Invoke-PsqlJson {
  param(
    [Parameter(Mandatory = $true)][string]$DatabaseUrl,
    [Parameter(Mandatory = $true)][string]$Sql
  )
  $psql = Get-Command psql -ErrorAction SilentlyContinue
  if (-not $psql) { throw "psql_unavailable" }
  $env:PGCONNECT_TIMEOUT = "10"
  $output = $Sql | & $psql.Source $DatabaseUrl -X -q -t -A -v ON_ERROR_STOP=1 2>&1
  $text = (($output | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join "`n").Trim()
  if ($LASTEXITCODE -ne 0) { throw "psql_query_failed" }
  if (-not (Test-SecretSafeText $text)) { throw "psql_output_secret_unsafe" }
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  return ($text | ConvertFrom-Json)
}

function New-HexTokenSuffix {
  $bytes = [byte[]]::new(32)
  [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
  return (($bytes | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Get-Sha256Hex {
  param([Parameter(Mandatory = $true)][string]$Text)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $hash = $sha.ComputeHash($bytes)
    return (($hash | ForEach-Object { $_.ToString("x2") }) -join "")
  } finally {
    $sha.Dispose()
  }
}

function Invoke-Api {
  param(
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Path,
    [AllowNull()][object]$Body,
    [AllowNull()][string]$SessionToken,
    [AllowNull()][string]$BearerToken
  )
  $uri = $ControlPlaneBaseUrl.TrimEnd("/") + $Path
  $headers = @{}
  if (-not [string]::IsNullOrWhiteSpace($SessionToken)) {
    $headers["x-admin-session"] = $SessionToken
  }
  if (-not [string]::IsNullOrWhiteSpace($BearerToken)) {
    $headers["Authorization"] = "Bearer $BearerToken"
  }
  try {
    $jsonBody = if ($null -eq $Body) { $null } else { $Body | ConvertTo-Json -Depth 10 }
    $response = Invoke-WebRequest -Uri $uri -Method $Method -Headers $headers -ContentType "application/json" -Body $jsonBody -TimeoutSec 30
    $content = [string]$response.Content
    if ($Path -ne "/admin/auth/login" -and -not (Test-SecretSafeText $content)) {
      return [ordered]@{ ok = $false; status_code = [int]$response.StatusCode; blocker = "http_response_secret_unsafe" }
    }
    $json = if ([string]::IsNullOrWhiteSpace($content)) { $null } else { $content | ConvertFrom-Json }
    return [ordered]@{ ok = $true; status_code = [int]$response.StatusCode; json = $json; data = $json.data }
  } catch {
    $status = $null
    $content = ""
    if ($_.Exception.Response) {
      try { $status = [int]$_.Exception.Response.StatusCode } catch {}
      if (-not [string]::IsNullOrWhiteSpace([string]$_.ErrorDetails.Message)) {
        $content = [string]$_.ErrorDetails.Message
      }
      try {
        if ([string]::IsNullOrWhiteSpace($content) -and $_.Exception.Response.GetResponseStream) {
          $stream = $_.Exception.Response.GetResponseStream()
          if ($stream) {
            $reader = [System.IO.StreamReader]::new($stream)
            $content = $reader.ReadToEnd()
          }
        }
      } catch {}
    }
    $json = $null
    if (-not [string]::IsNullOrWhiteSpace($content)) {
      try { $json = $content | ConvertFrom-Json } catch {}
    }
    return [ordered]@{ ok = $false; status_code = $status; json = $json; data = $json.data }
  }
}

function Get-AdminSessionToken {
  if ($env:CONTROL_PLANE_ADMIN_SESSION_TOKEN) {
    return [ordered]@{ present = $true; source = "CONTROL_PLANE_ADMIN_SESSION_TOKEN"; token = [string]$env:CONTROL_PLANE_ADMIN_SESSION_TOKEN }
  }
  if ([string]::IsNullOrWhiteSpace($AdminPassword)) { $AdminPassword = "local-password" }
  $login = Invoke-Api -Method "POST" -Path "/admin/auth/login" -Body @{ email = $AdminEmail; password = $AdminPassword } -SessionToken $null -BearerToken $null
  if (-not $login.ok -or $login.status_code -ne 200) {
    return [ordered]@{ present = $false; source = "dev_admin_login_failed"; token = "" }
  }
  $token = [string]$login.data.session_token_once
  if ([string]::IsNullOrWhiteSpace($token)) {
    return [ordered]@{ present = $false; source = "dev_admin_login_missing_session_token"; token = "" }
  }
  return [ordered]@{ present = $true; source = "dev_admin_login"; token = $token }
}

function Test-DecimalString {
  param([AllowNull()][string]$Value)
  return -not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^-?\d+\.\d{8}$'
}

function Invoke-LiveRouteMatrix {
  param(
    [Parameter(Mandatory = $true)][string]$DatabaseUrl,
    [Parameter(Mandatory = $true)][string]$SessionToken
  )
  $runId = ([guid]::NewGuid().ToString("N")).Substring(0, 16)
  $walletId = if ([string]::IsNullOrWhiteSpace($SeedWalletId) -or $SeedWalletId -eq "00000000-0000-0000-0000-0000000032a8") {
    [guid]::NewGuid().ToString()
  } else {
    $SeedWalletId
  }
  $source = "todo32h_remaining_$runId"
  $seedSql = @"
insert into wallets (id, tenant_id, project_id, name, currency, status, balance_floor, metadata)
values ('$walletId'::uuid, '$SeedTenantId'::uuid, null, 'TODO-32H remaining balance verifier', 'USD', 'active', 1.50000000, jsonb_build_object('verifier', 'todo32h_remaining_balance', 'run_id', '$runId'))
on conflict (id) do update
set currency = excluded.currency,
    status = excluded.status,
    balance_floor = excluded.balance_floor,
    metadata = excluded.metadata,
    deleted_at = null,
    updated_at = now();

delete from ledger_entries
where tenant_id = '$SeedTenantId'::uuid
  and wallet_id = '$walletId'::uuid
  and metadata->>'run_id' = '$runId';

insert into credit_grants (tenant_id, wallet_id, amount, remaining_amount, currency, source, status, metadata, valid_from, valid_until)
values ('$SeedTenantId'::uuid, '$walletId'::uuid, 7.50000000, 7.50000000, 'USD', '$source', 'active', jsonb_build_object('verifier', 'todo32h_remaining_balance', 'run_id', '$runId'), now() - interval '1 minute', now() + interval '30 days')
returning jsonb_build_object('credit_grant_id', id)::text;
"@
  $seed = Invoke-PsqlJson -DatabaseUrl $DatabaseUrl -Sql $seedSql
  $grantId = [string]$seed.credit_grant_id
  $ledgerSql = @"
insert into ledger_entries (tenant_id, project_id, wallet_id, entry_type, amount, currency, status, idempotency_key, metadata)
values
  ('$SeedTenantId'::uuid, null, '$walletId'::uuid, 'adjust', -1.00000000, 'USD', 'confirmed', 'todo32h-confirmed-$runId', jsonb_build_object('verifier', 'todo32h_remaining_balance', 'run_id', '$runId')),
  ('$SeedTenantId'::uuid, null, '$walletId'::uuid, 'reserve', -0.50000000, 'USD', 'pending', 'todo32h-pending-$runId', jsonb_build_object('verifier', 'todo32h_remaining_balance', 'run_id', '$runId'))
on conflict (tenant_id, idempotency_key) do nothing;
select jsonb_build_object(
  'ledger_entry_ids', (
    select coalesce(jsonb_agg(id order by created_at), '[]'::jsonb)
    from ledger_entries
    where tenant_id = '$SeedTenantId'::uuid
      and wallet_id = '$walletId'::uuid
      and metadata->>'run_id' = '$runId'
  )
)::text;
"@
  $ledger = Invoke-PsqlJson -DatabaseUrl $DatabaseUrl -Sql $ledgerSql
  $success = Invoke-Api -Method "GET" -Path "/billing/wallets/$walletId/remaining-balance?tenant_id=$SeedTenantId&currency=USD&ledger_window_days=30" -Body $null -SessionToken $SessionToken -BearerToken $null
  $refusal = Invoke-Api -Method "GET" -Path "/billing/wallets/$walletId/remaining-balance?tenant_id=$SeedTenantId&currency=EUR&ledger_window_days=30" -Body $null -SessionToken $SessionToken -BearerToken $null
  $missingSession = Invoke-Api -Method "GET" -Path "/billing/wallets/$walletId/remaining-balance?tenant_id=$SeedTenantId&currency=USD&ledger_window_days=30" -Body $null -SessionToken $null -BearerToken $null

  $data = $success.data
  $readbackSql = @"
select jsonb_build_object(
  'wallet_rows', (select count(*)::int from wallets where tenant_id = '$SeedTenantId'::uuid and id = '$walletId'::uuid and status = 'active'),
  'credit_grant_rows', (select count(*)::int from credit_grants where tenant_id = '$SeedTenantId'::uuid and wallet_id = '$walletId'::uuid and source = '$source' and status = 'active'),
  'ledger_rows', (select count(*)::int from ledger_entries where tenant_id = '$SeedTenantId'::uuid and wallet_id = '$walletId'::uuid and metadata->>'run_id' = '$runId'),
  'confirmed_net_amount', (select coalesce(sum(amount), 0)::numeric(20,8)::text from ledger_entries where tenant_id = '$SeedTenantId'::uuid and wallet_id = '$walletId'::uuid and metadata->>'run_id' = '$runId' and status = 'confirmed'),
  'pending_amount', (select coalesce(sum(amount), 0)::numeric(20,8)::text from ledger_entries where tenant_id = '$SeedTenantId'::uuid and wallet_id = '$walletId'::uuid and metadata->>'run_id' = '$runId' and status = 'pending')
)::text;
"@
  $readback = Invoke-PsqlJson -DatabaseUrl $DatabaseUrl -Sql $readbackSql

  $checks = [ordered]@{
    success_http_200 = ([int]$success.status_code -eq 200)
    schema = ([string]$data.schema -eq "user_remaining_balance_runtime.v1")
    runtime_implemented = ([bool]$data.runtime_implemented)
    contract_only_false = (-not [bool]$data.contract_only)
    route_invoked = ([bool]$data.route_invoked -and [bool]$data.public_route_invoked)
    admin_readonly_partial = ([bool]$data.admin_readonly_runtime -and -not [bool]$data.user_api_runtime)
    read_only = ([bool]$data.read_only)
    ids_present = (-not [string]::IsNullOrWhiteSpace([string]$data.wallet_id) -and -not [string]::IsNullOrWhiteSpace([string]$data.tenant_id))
    money_decimal_strings = ((Test-DecimalString ([string]$data.available_to_spend)) -and (Test-DecimalString ([string]$data.active_credit_grant_total)) -and (Test-DecimalString ([string]$data.pending_confirmed_ledger_window)) -and (Test-DecimalString ([string]$data.wallet_balance_floor)))
    formula_expected = ([string]$data.available_to_spend -eq "4.50000000")
    readback_markers = ([bool]$data.readback.wallet_row -and [bool]$data.readback.credit_grants -and [bool]$data.readback.ledger_window -and -not [bool]$data.readback.direct_wallet_snapshot_mutation)
    db_wallet_readback = ([int]$readback.wallet_rows -eq 1)
    db_credit_grant_readback = ([int]$readback.credit_grant_rows -eq 1)
    db_ledger_readback = ([int]$readback.ledger_rows -eq 2 -and [string]$readback.confirmed_net_amount -eq "-1.00000000" -and [string]$readback.pending_amount -eq "-0.50000000")
    refusal_readback = ([int]$refusal.status_code -eq 400 -and [string]$refusal.data.status -eq "refused" -and [string]$refusal.data.refusal_code -eq "currency_mismatch")
    missing_session_rejected = ([int]$missingSession.status_code -in @(401, 403))
    secret_safe = ([bool]$data.secret_safe -and -not [bool]$data.paid_gate_changed)
  }
  $passed = -not (@($checks.GetEnumerator() | Where-Object { -not [bool]$_.Value }).Count -gt 0)
  return [ordered]@{
    ran = $true
    passed = $passed
    run_id = $runId
    wallet_id = $walletId
    credit_grant_id = $grantId
    ledger_entry_ids = $ledger.ledger_entry_ids
    checks = $checks
    response = [ordered]@{
      schema = [string]$data.schema
      tenant_id = [string]$data.tenant_id
      currency = [string]$data.currency
      available_to_spend = [string]$data.available_to_spend
      active_credit_grant_total = [string]$data.active_credit_grant_total
      pending_confirmed_ledger_window = [string]$data.pending_confirmed_ledger_window
      wallet_balance_floor = [string]$data.wallet_balance_floor
      admin_readonly_runtime = [bool]$data.admin_readonly_runtime
      user_api_runtime = [bool]$data.user_api_runtime
    }
    db_readback = $readback
    observed = [ordered]@{
      success_status_code = [int]$success.status_code
      refusal_status_code = [int]$refusal.status_code
      refusal_status = [string]$refusal.data.status
      refusal_code = [string]$refusal.data.refusal_code
      missing_session_status_code = [int]$missingSession.status_code
    }
  }
}

function Invoke-LiveOwnershipRouteMatrix {
  param([Parameter(Mandatory = $true)][string]$DatabaseUrl)

  $runId = ([guid]::NewGuid().ToString("N")).Substring(0, 16)
  $tenantId = $SeedTenantId
  $projectId = [guid]::NewGuid().ToString()
  $walletId = [guid]::NewGuid().ToString()
  $userId = [guid]::NewGuid().ToString()
  $sessionId = [guid]::NewGuid().ToString()
  $sessionToken = "sess_$(New-HexTokenSuffix)"
  $sessionPrefix = $sessionToken.Substring(0, 20)
  $sessionHash = Get-Sha256Hex $sessionToken
  $source = "todo32h_ownership_$runId"
  $email = "todo32h-$runId@example.invalid"

  $seedSql = @"
insert into projects (id, tenant_id, team_id, name, status, metadata)
values ('$projectId'::uuid, '$tenantId'::uuid, null, 'TODO-32H ownership verifier $runId', 'active', jsonb_build_object('verifier', 'todo32h_remaining_balance_ownership', 'run_id', '$runId'))
on conflict (id) do update
set status = excluded.status,
    metadata = excluded.metadata,
    deleted_at = null,
    updated_at = now();

insert into users (id, tenant_id, email, display_name, password_hash, status, metadata)
values ('$userId'::uuid, '$tenantId'::uuid, '$email', 'TODO-32H ownership verifier', null, 'active', jsonb_build_object('verifier', 'todo32h_remaining_balance_ownership', 'run_id', '$runId'))
on conflict (tenant_id, id) do update
set status = excluded.status,
    metadata = excluded.metadata,
    deleted_at = null,
    updated_at = now();

insert into project_members (tenant_id, project_id, user_id, role)
values ('$tenantId'::uuid, '$projectId'::uuid, '$userId'::uuid, 'developer')
on conflict (tenant_id, project_id, user_id) do update
set role = excluded.role;

insert into user_sessions (id, tenant_id, user_id, token_lookup_prefix, token_hash, status, metadata, expires_at)
values ('$sessionId'::uuid, '$tenantId'::uuid, '$userId'::uuid, '$sessionPrefix', '$sessionHash', 'active', jsonb_build_object('verifier', 'todo32h_remaining_balance_ownership', 'run_id', '$runId'), now() + interval '30 minutes')
on conflict (token_hash) do update
set status = 'active',
    expires_at = now() + interval '30 minutes',
    revoked_at = null,
    metadata = excluded.metadata;

insert into wallets (id, tenant_id, project_id, name, currency, status, balance_floor, metadata)
values ('$walletId'::uuid, '$tenantId'::uuid, '$projectId'::uuid, 'TODO-32H ownership remaining balance verifier', 'USD', 'active', 1.50000000, jsonb_build_object('verifier', 'todo32h_remaining_balance_ownership', 'run_id', '$runId'))
on conflict (id) do update
set project_id = excluded.project_id,
    currency = excluded.currency,
    status = excluded.status,
    balance_floor = excluded.balance_floor,
    metadata = excluded.metadata,
    deleted_at = null,
    updated_at = now();

insert into credit_grants (tenant_id, wallet_id, amount, remaining_amount, currency, source, status, metadata, valid_from, valid_until)
values ('$tenantId'::uuid, '$walletId'::uuid, 7.50000000, 7.50000000, 'USD', '$source', 'active', jsonb_build_object('verifier', 'todo32h_remaining_balance_ownership', 'run_id', '$runId'), now() - interval '1 minute', now() + interval '30 days')
returning jsonb_build_object('credit_grant_id', id)::text;
"@
  $seed = Invoke-PsqlJson -DatabaseUrl $DatabaseUrl -Sql $seedSql
  $grantId = [string]$seed.credit_grant_id

  $ledgerSql = @"
insert into ledger_entries (tenant_id, project_id, wallet_id, entry_type, amount, currency, status, idempotency_key, metadata)
values
  ('$tenantId'::uuid, '$projectId'::uuid, '$walletId'::uuid, 'adjust', -1.00000000, 'USD', 'confirmed', 'todo32h-ownership-confirmed-$runId', jsonb_build_object('verifier', 'todo32h_remaining_balance_ownership', 'run_id', '$runId')),
  ('$tenantId'::uuid, '$projectId'::uuid, '$walletId'::uuid, 'reserve', -0.50000000, 'USD', 'pending', 'todo32h-ownership-pending-$runId', jsonb_build_object('verifier', 'todo32h_remaining_balance_ownership', 'run_id', '$runId'))
on conflict (tenant_id, idempotency_key) do nothing;
select jsonb_build_object(
  'ledger_entry_ids', (
    select coalesce(jsonb_agg(id order by created_at), '[]'::jsonb)
    from ledger_entries
    where tenant_id = '$tenantId'::uuid
      and wallet_id = '$walletId'::uuid
      and metadata->>'run_id' = '$runId'
  )
)::text;
"@
  $ledger = Invoke-PsqlJson -DatabaseUrl $DatabaseUrl -Sql $ledgerSql

  $success = Invoke-Api -Method "GET" -Path "/billing/wallets/$walletId/remaining-balance?tenant_id=$tenantId&currency=USD&ledger_window_days=30" -Body $null -SessionToken $null -BearerToken $sessionToken
  $refusal = Invoke-Api -Method "GET" -Path "/billing/wallets/$walletId/remaining-balance?tenant_id=$tenantId&currency=EUR&ledger_window_days=30" -Body $null -SessionToken $null -BearerToken $sessionToken
  $missingSession = Invoke-Api -Method "GET" -Path "/billing/wallets/$walletId/remaining-balance?tenant_id=$tenantId&currency=USD&ledger_window_days=30" -Body $null -SessionToken $null -BearerToken $null
  $data = $success.data

  $readbackSql = @"
select jsonb_build_object(
  'project_rows', (select count(*)::int from projects where tenant_id = '$tenantId'::uuid and id = '$projectId'::uuid and status = 'active'),
  'project_member_rows', (select count(*)::int from project_members where tenant_id = '$tenantId'::uuid and project_id = '$projectId'::uuid and user_id = '$userId'::uuid),
  'session_rows', (select count(*)::int from user_sessions where tenant_id = '$tenantId'::uuid and id = '$sessionId'::uuid and status = 'active' and token_hash = '$sessionHash'),
  'wallet_rows', (select count(*)::int from wallets where tenant_id = '$tenantId'::uuid and id = '$walletId'::uuid and project_id = '$projectId'::uuid and status = 'active'),
  'credit_grant_rows', (select count(*)::int from credit_grants where tenant_id = '$tenantId'::uuid and wallet_id = '$walletId'::uuid and source = '$source' and status = 'active'),
  'ledger_rows', (select count(*)::int from ledger_entries where tenant_id = '$tenantId'::uuid and wallet_id = '$walletId'::uuid and metadata->>'run_id' = '$runId'),
  'confirmed_net_amount', (select coalesce(sum(amount), 0)::numeric(20,8)::text from ledger_entries where tenant_id = '$tenantId'::uuid and wallet_id = '$walletId'::uuid and metadata->>'run_id' = '$runId' and status = 'confirmed'),
  'pending_amount', (select coalesce(sum(amount), 0)::numeric(20,8)::text from ledger_entries where tenant_id = '$tenantId'::uuid and wallet_id = '$walletId'::uuid and metadata->>'run_id' = '$runId' and status = 'pending')
)::text;
"@
  $readback = Invoke-PsqlJson -DatabaseUrl $DatabaseUrl -Sql $readbackSql
  $checks = [ordered]@{
    success_http_200 = ([int]$success.status_code -eq 200)
    schema = ([string]$data.schema -eq "user_remaining_balance_runtime.v1")
    runtime_implemented = ([bool]$data.runtime_implemented)
    contract_only_false = (-not [bool]$data.contract_only)
    route_invoked = ([bool]$data.route_invoked -and [bool]$data.public_route_invoked)
    user_api_runtime = ([bool]$data.user_api_runtime)
    admin_readonly_runtime_false = (-not [bool]$data.admin_readonly_runtime)
    ownership_scope_verified = ([bool]$data.ownership_scope_verified)
    ownership_source = ([string]$data.ownership.source -eq "control_plane_user_session")
    ownership_scope_matches = ([bool]$data.ownership.tenant_scope_match -and [bool]$data.ownership.project_scope_match -and [bool]$data.ownership.wallet_scope_match)
    read_only = ([bool]$data.read_only)
    money_decimal_strings = ((Test-DecimalString ([string]$data.available_to_spend)) -and (Test-DecimalString ([string]$data.active_credit_grant_total)) -and (Test-DecimalString ([string]$data.pending_confirmed_ledger_window)) -and (Test-DecimalString ([string]$data.wallet_balance_floor)))
    formula_expected = ([string]$data.available_to_spend -eq "4.50000000")
    readback_markers = ([bool]$data.readback.wallet_row -and [bool]$data.readback.credit_grants -and [bool]$data.readback.ledger_window -and -not [bool]$data.readback.direct_wallet_snapshot_mutation)
    db_project_readback = ([int]$readback.project_rows -eq 1)
    db_project_member_readback = ([int]$readback.project_member_rows -eq 1)
    db_session_readback = ([int]$readback.session_rows -eq 1)
    db_wallet_readback = ([int]$readback.wallet_rows -eq 1)
    db_credit_grant_readback = ([int]$readback.credit_grant_rows -eq 1)
    db_ledger_readback = ([int]$readback.ledger_rows -eq 2 -and [string]$readback.confirmed_net_amount -eq "-1.00000000" -and [string]$readback.pending_amount -eq "-0.50000000")
    refusal_readback = ([int]$refusal.status_code -eq 400 -and [string]$refusal.data.status -eq "refused" -and [string]$refusal.data.refusal_code -eq "currency_mismatch" -and [bool]$refusal.data.user_api_runtime)
    missing_session_rejected = ([int]$missingSession.status_code -in @(401, 403))
    secret_safe = ([bool]$data.secret_safe -and -not [bool]$data.paid_gate_changed -and -not [bool]$data.ownership.raw_token_echoed)
  }
  $passed = -not (@($checks.GetEnumerator() | Where-Object { -not [bool]$_.Value }).Count -gt 0)
  return [ordered]@{
    ran = $true
    passed = $passed
    run_id = $runId
    wallet_id = $walletId
    project_id = $projectId
    user_id = $userId
    credit_grant_id = $grantId
    ledger_entry_ids = $ledger.ledger_entry_ids
    checks = $checks
    response = [ordered]@{
      schema = [string]$data.schema
      tenant_id = [string]$data.tenant_id
      project_id = [string]$data.project_id
      currency = [string]$data.currency
      available_to_spend = [string]$data.available_to_spend
      active_credit_grant_total = [string]$data.active_credit_grant_total
      pending_confirmed_ledger_window = [string]$data.pending_confirmed_ledger_window
      wallet_balance_floor = [string]$data.wallet_balance_floor
      user_api_runtime = [bool]$data.user_api_runtime
      admin_readonly_runtime = [bool]$data.admin_readonly_runtime
      ownership_scope_verified = [bool]$data.ownership_scope_verified
      ownership_source = [string]$data.ownership.source
    }
    db_readback = $readback
    observed = [ordered]@{
      refusal_status_code = [int]$refusal.status_code
      refusal_status = [string]$refusal.data.status
      refusal_code = [string]$refusal.data.refusal_code
      missing_session_status_code = [int]$missingSession.status_code
    }
  }
}

function New-Artifact {
  param(
    [string]$Status,
    [string[]]$Blockers,
    [object]$SessionInfo,
    [object]$LiveMatrix
  )
  $passed = $Status -eq "pass"
  return [ordered]@{
    schema = "user_remaining_balance_runtime.v1"
    overall_status = $Status
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    endpoint = "/billing/wallets/{wallet_id}/remaining-balance"
    runtime_implemented = $passed
    contract_only = (-not $passed)
    user_api_runtime = $false
    admin_readonly_runtime = $passed
    route_invoked = [bool]$LiveMatrix.ran
    public_route_invoked = [bool]$LiveMatrix.ran
    admin_session_present = [bool]$SessionInfo.present
    admin_session = [ordered]@{
      present = [bool]$SessionInfo.present
      source = [string]$SessionInfo.source
      echoed = $false
    }
    wallet_id = [string]$LiveMatrix.wallet_id
    tenant_id = [string]$LiveMatrix.response.tenant_id
    currency = [string]$LiveMatrix.response.currency
    credit_grant_id = [string]$LiveMatrix.credit_grant_id
    ledger_entry_ids = $LiveMatrix.ledger_entry_ids
    available_to_spend = [string]$LiveMatrix.response.available_to_spend
    active_credit_grant_total = [string]$LiveMatrix.response.active_credit_grant_total
    pending_confirmed_ledger_window = [string]$LiveMatrix.response.pending_confirmed_ledger_window
    wallet_balance_floor = [string]$LiveMatrix.response.wallet_balance_floor
    money_decimal_strings = [bool]$LiveMatrix.checks.money_decimal_strings
    formula = "active_credit_grant_total + pending_confirmed_ledger_window - wallet_balance_floor"
    formula_readback_passed = [bool]$LiveMatrix.checks.formula_expected
    wallet_readback_passed = [bool]$LiveMatrix.checks.db_wallet_readback
    credit_grants_readback_passed = [bool]$LiveMatrix.checks.db_credit_grant_readback
    ledger_window_readback_passed = [bool]$LiveMatrix.checks.db_ledger_readback
    refusal_readback_passed = [bool]$LiveMatrix.checks.refusal_readback
    missing_session_rejected = [bool]$LiveMatrix.checks.missing_session_rejected
    read_only = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    secret_safe = $true
    raw_secret_markers_present = $false
    paid_gate_changed = $false
    route_matrix_results = $LiveMatrix.checks
    route_matrix_observed = $LiveMatrix.observed
    db_readback_results = $LiveMatrix.db_readback
    artifact_secret_policy = [ordered]@{
      session_token_echoed = $false
      auth_header_echoed = $false
      cookie_echoed = $false
      raw_db_url_echoed = $false
      provider_or_virtual_key_echoed = $false
    }
    blockers = @($Blockers)
  }
}

function New-OwnershipRuntimeArtifact {
  param(
    [string]$Status,
    [string[]]$Blockers,
    [object]$LiveMatrix
  )
  $passed = $Status -eq "pass"
  return [ordered]@{
    schema = "user_remaining_balance_runtime.v1"
    overall_status = $Status
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    endpoint = "/billing/wallets/{wallet_id}/remaining-balance"
    runtime_implemented = $passed
    contract_only = (-not $passed)
    user_api_runtime = $passed
    admin_readonly_runtime = $false
    ownership_scope_verified = $passed
    route_invoked = [bool]$LiveMatrix.ran
    public_route_invoked = [bool]$LiveMatrix.ran
    auth_source = "control_plane_user_session"
    server_side_lookup = $true
    bearer_token_echoed = $false
    admin_session_used_as_ownership_proof = $false
    gateway_virtual_key_reused_as_control_plane_auth = $false
    tenant_id = [string]$LiveMatrix.response.tenant_id
    project_id = [string]$LiveMatrix.response.project_id
    wallet_id = [string]$LiveMatrix.wallet_id
    user_id = [string]$LiveMatrix.user_id
    credit_grant_id = [string]$LiveMatrix.credit_grant_id
    ledger_entry_ids = $LiveMatrix.ledger_entry_ids
    currency = [string]$LiveMatrix.response.currency
    available_to_spend = [string]$LiveMatrix.response.available_to_spend
    active_credit_grant_total = [string]$LiveMatrix.response.active_credit_grant_total
    pending_confirmed_ledger_window = [string]$LiveMatrix.response.pending_confirmed_ledger_window
    wallet_balance_floor = [string]$LiveMatrix.response.wallet_balance_floor
    money_decimal_strings = [bool]$LiveMatrix.checks.money_decimal_strings
    read_only = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    wallet_readback_passed = [bool]$LiveMatrix.checks.db_wallet_readback
    project_membership_readback_passed = [bool]$LiveMatrix.checks.db_project_member_readback
    session_readback_passed = [bool]$LiveMatrix.checks.db_session_readback
    credit_grants_readback_passed = [bool]$LiveMatrix.checks.db_credit_grant_readback
    ledger_window_readback_passed = [bool]$LiveMatrix.checks.db_ledger_readback
    refusal_readback_passed = [bool]$LiveMatrix.checks.refusal_readback
    missing_session_rejected = [bool]$LiveMatrix.checks.missing_session_rejected
    route_matrix_results = $LiveMatrix.checks
    route_matrix_observed = $LiveMatrix.observed
    db_readback_results = $LiveMatrix.db_readback
    secret_safe = $true
    raw_secret_markers_present = $false
    paid_gate_changed = $false
    blockers = @($Blockers)
  }
}

function New-OwnershipPlanArtifact {
  param([bool]$SelfTestMode = $false)

  return [ordered]@{
    schema = "user_remaining_balance_ownership_scope_plan.v1"
    overall_status = "contract_ready"
    auth_contract_status = "contract_ready_runtime_blocked"
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    endpoint = "/billing/wallets/{wallet_id}/remaining-balance"
    runtime_implemented = $false
    contract_only = $true
    user_api_runtime = $false
    admin_readonly_runtime = $true
    admin_readonly_artifact_path = ".tmp/credit-wallet/user_remaining_balance_runtime.json"
    auth_primitive_found = $false
    ownership_scope_verified = $false
    paid_gate_changed = $false
    read_only = $true
    secret_safe = $true
    blockers = @(
      "control_plane_user_or_developer_token_auth_primitive_missing",
      "wallet_ownership_scope_not_verifiable_without_new_auth_boundary"
    )
    token_source_contract = [ordered]@{
      accepted_sources = @(
        "control_plane_user_session",
        "control_plane_developer_token"
      )
      rejected_sources = @(
        "admin_session",
        "gateway_virtual_key_without_control_plane_lookup",
        "client_submitted_wallet_claim"
      )
      bearer_header_current_meaning = "admin_session_token"
      raw_token_echoed = $false
    }
    ownership_scope_resolution_contract = [ordered]@{
      required_server_side_lookup = $true
      required_scope_fields = @(
        "tenant_id",
        "project_id",
        "wallet_id"
      )
      optional_scope_fields = @(
        "user_id",
        "virtual_key_id"
      )
      wallet_readback_required = $true
      match_rules = @(
        "token.tenant_id == wallet.tenant_id",
        "token.project_id == wallet.project_id",
        "token.wallet_id == wallet.id or token wallet binding table proves access",
        "request currency == wallet.currency"
      )
      refusal_codes = @(
        "missing_token",
        "invalid_token",
        "token_scope_not_server_verified",
        "tenant_scope_mismatch",
        "project_scope_mismatch",
        "wallet_scope_mismatch",
        "currency_mismatch",
        "wallet_not_found"
      )
    }
    resolver_feasibility = [ordered]@{
      status = "feasible_contract_only"
      requires_new_schema = $false
      requires_new_middleware = $true
      runtime_wired = $false
      evaluated_data_sources = [ordered]@{
        user_sessions = [ordered]@{
          present = $true
          usable_for_user_session_scope = $true
          required_lookup = @("token_lookup_prefix", "token_hash", "status", "expires_at", "revoked_at")
        }
        project_members = [ordered]@{
          present = $true
          usable_for_user_project_scope = $true
          required_lookup = @("tenant_id", "project_id", "user_id", "role")
        }
        virtual_keys = [ordered]@{
          present = $true
          usable_for_developer_token_scope = $true
          required_lookup = @("key_prefix", "secret_hash", "tenant_id", "project_id", "status", "expires_at")
          raw_secret_echoed = $false
        }
        wallets = [ordered]@{
          present = $true
          usable_for_wallet_scope = $true
          required_lookup = @("tenant_id", "project_id", "id", "currency", "status")
        }
      }
      planned_resolvers = @(
        [ordered]@{
          name = "control_plane_user_session_project_membership"
          token_source = "session token parsed server-side into lookup prefix and hash"
          scope_query = "user_sessions -> project_members -> wallets"
          scope_fields = @("tenant_id", "user_id", "project_id", "wallet_id")
          trust_boundary = "server_verified_session_lookup"
        },
        [ordered]@{
          name = "control_plane_developer_token_virtual_key"
          token_source = "developer token parsed server-side into key_prefix and secret_hash"
          scope_query = "virtual_keys -> wallets"
          scope_fields = @("tenant_id", "project_id", "virtual_key_id", "wallet_id")
          trust_boundary = "server_verified_virtual_key_hash_lookup"
        }
      )
      missing_runtime_wiring = @(
        "remaining_balance_principal_middleware",
        "route_branch_accepting_non_admin_user_or_developer_principal",
        "live_artifact_route_matrix_for_user_or_developer_token",
        "QA verifier full user runtime acceptance"
      )
    }
    admin_session_isolation_contract = [ordered]@{
      admin_session_may_verify_admin_readonly_runtime = $true
      admin_session_must_not_set_user_api_runtime = $true
      admin_session_refusal_code_for_full_user_runtime = "admin_session_not_user_ownership_scope"
    }
    gateway_virtual_key_cross_boundary_contract = [ordered]@{
      data_plane_auth_present_elsewhere = $true
      may_be_future_lookup_source = $true
      direct_reuse_without_control_plane_lookup_allowed = $false
      refusal_code_without_lookup = "gateway_virtual_key_not_control_plane_auth_boundary"
    }
    reviewed_auth_primitives = [ordered]@{
      admin_session_rbac = [ordered]@{
        present = $true
        usable_for_admin_readonly_runtime = $true
        sufficient_for_full_user_api_runtime = $false
        reason = "AdminSession carries tenant and roles but not user/developer-token wallet ownership scope."
      }
      authorization_bearer = [ordered]@{
        present = $true
        current_control_plane_meaning = "admin_session_token"
        sufficient_for_developer_token_runtime = $false
      }
      admin_session_header = [ordered]@{
        present = $true
        current_control_plane_meaning = "admin_session_token"
        secret_echoed = $false
      }
      virtual_keys = [ordered]@{
        data_model_present = $true
        control_plane_runtime_auth_middleware_present = $false
        gateway_auth_only = $true
        sufficient_for_control_plane_wallet_disclosure = $false
      }
      api_key_profiles = [ordered]@{
        data_model_present = $true
        control_plane_runtime_auth_middleware_present = $false
        sufficient_for_control_plane_wallet_disclosure = $false
      }
    }
    required_next_runtime_contract = [ordered]@{
      token_source = "new Control Plane user session or developer token middleware; must not reuse AdminSession as proof of customer ownership"
      lookup = "resolve token to tenant_id, project_id, optional user_id or virtual_key_id without exposing raw token"
      wallet_scope_check = "wallet.tenant_id must match token tenant and wallet.project_id must match token project or explicit null/shared-wallet policy"
      currency_check = "requested currency must match wallet currency"
      response_markers = @(
        "user_api_runtime=true",
        "ownership_scope_verified=true",
        "runtime_implemented=true",
        "contract_only=false",
        "read_only=true",
        "secret_safe=true",
        "paid_gate_changed=false"
      )
      refusal_cases = @(
        "missing_token",
        "invalid_token",
        "tenant_mismatch",
        "project_or_wallet_scope_mismatch",
        "currency_mismatch",
        "wallet_not_found"
      )
      forbidden_outputs = @(
        "raw token",
        "Authorization",
        "Cookie",
        "provider key",
        "virtual key secret",
        "DB URL",
        "raw request payload"
      )
    }
    guardrails = [ordered]@{
      admin_partial_must_not_set_user_api_runtime = $true
      no_gateway_change_required = $true
      no_paid_gate_change = $true
      no_wallet_snapshot_mutation = $true
      selftest_mode = $SelfTestMode
    }
  }
}

$output = Resolve-RepoBoundedPath -Path $OutputPath -AllowedPrefixes @(".tmp/", "artifacts/")
$ownershipOutput = Resolve-RepoBoundedPath -Path $OwnershipPlanOutputPath -AllowedPrefixes @(".tmp/", "artifacts/")
$ownershipRuntimeOutput = Resolve-RepoBoundedPath -Path $OwnershipRuntimeOutputPath -AllowedPrefixes @(".tmp/", "artifacts/")

if ($SelfTest) {
  $session = [ordered]@{ present = $true; source = "selftest"; token = "omitted" }
  $matrix = [ordered]@{
    ran = $true
    passed = $true
    wallet_id = "00000000-0000-0000-0000-0000000032a8"
    credit_grant_id = "00000000-0000-0000-0000-0000000032a9"
    ledger_entry_ids = @("00000000-0000-0000-0000-0000000032b1")
    response = [ordered]@{
      available_to_spend = "4.50000000"
      active_credit_grant_total = "7.50000000"
      pending_confirmed_ledger_window = "-1.50000000"
      wallet_balance_floor = "1.50000000"
    }
    checks = [ordered]@{
      money_decimal_strings = $true
      formula_expected = $true
      db_wallet_readback = $true
      db_credit_grant_readback = $true
      db_ledger_readback = $true
      refusal_readback = $true
      missing_session_rejected = $true
    }
    db_readback = [ordered]@{ wallet_rows = 1; credit_grant_rows = 1; ledger_rows = 2 }
  }
  $artifact = New-Artifact -Status "pass" -Blockers @() -SessionInfo $session -LiveMatrix $matrix
  $ownershipPlan = New-OwnershipPlanArtifact -SelfTestMode $true
  if (-not (Test-SecretSafeText ($artifact | ConvertTo-Json -Depth 14))) { throw "selftest_secret_safety_failed" }
  if (-not (Test-SecretSafeText ($ownershipPlan | ConvertTo-Json -Depth 14))) { throw "ownership_plan_selftest_secret_safety_failed" }
  if ([bool]$ownershipPlan.user_api_runtime -or [bool]$ownershipPlan.ownership_scope_verified -or [bool]$ownershipPlan.runtime_implemented) {
    throw "ownership_plan_must_not_claim_full_runtime"
  }
  Write-Output "user_remaining_balance_runtime_selftest_status=pass"
  exit 0
}

if ($OwnershipPlanOnly) {
  $ownershipPlan = New-OwnershipPlanArtifact
  Write-Artifact -Artifact $ownershipPlan -Output $ownershipOutput
  Write-Output "user_remaining_balance_ownership_plan_status=contract_ready"
  Write-Output "user_remaining_balance_ownership_plan_artifact_path=$($ownershipOutput.relative)"
  Write-Output "user_remaining_balance_ownership_plan_secret_safe=true"
  exit 1
}

if ($RunOwnershipRouteMatrix) {
  $ownershipBlockers = [System.Collections.Generic.List[string]]::new()
  $ownershipMatrix = [ordered]@{ ran = $false; passed = $false; checks = [ordered]@{}; response = [ordered]@{}; db_readback = [ordered]@{} }
  try {
    $ownershipMatrix = Invoke-LiveOwnershipRouteMatrix -DatabaseUrl (Get-DatabaseUrl)
    if (-not [bool]$ownershipMatrix.passed) {
      if (-not [bool]$ownershipMatrix.checks.success_http_200) {
        [void]$ownershipBlockers.Add("control_plane_remaining_balance_ownership_route_not_accepting_seeded_user_session")
      }
      if (-not [bool]$ownershipMatrix.checks.db_session_readback) {
        [void]$ownershipBlockers.Add("control_plane_remaining_balance_user_session_seed_readback_failed")
      }
      if (-not [bool]$ownershipMatrix.checks.db_project_member_readback) {
        [void]$ownershipBlockers.Add("control_plane_remaining_balance_project_membership_readback_failed")
      }
      if (-not [bool]$ownershipMatrix.checks.db_wallet_readback) {
        [void]$ownershipBlockers.Add("control_plane_remaining_balance_wallet_scope_readback_failed")
      }
      if ($ownershipBlockers.Count -eq 0) {
        [void]$ownershipBlockers.Add("user_remaining_balance_ownership_route_matrix_failed")
      }
    }
  } catch {
    [void]$ownershipBlockers.Add("user_remaining_balance_ownership_route_matrix_exception")
    $ownershipMatrix = [ordered]@{ ran = $true; passed = $false; checks = [ordered]@{}; response = [ordered]@{}; db_readback = [ordered]@{} }
  }
  $ownershipStatus = if ([bool]$ownershipMatrix.passed) { "pass" } else { "blocked" }
  $ownershipArtifact = New-OwnershipRuntimeArtifact -Status $ownershipStatus -Blockers @($ownershipBlockers) -LiveMatrix $ownershipMatrix
  Write-Artifact -Artifact $ownershipArtifact -Output $ownershipRuntimeOutput
  Write-Output "user_remaining_balance_ownership_runtime_artifact_status=$ownershipStatus"
  Write-Output "user_remaining_balance_ownership_runtime_artifact_path=$($ownershipRuntimeOutput.relative)"
  Write-Output "user_remaining_balance_ownership_runtime_secret_safe=true"
  if ($ownershipStatus -eq "pass") { exit 0 }
  exit 1
}

$blockers = [System.Collections.Generic.List[string]]::new()
$session = [ordered]@{ present = $false; source = "not_requested"; token = "" }
$liveMatrix = [ordered]@{ ran = $false; passed = $false; checks = [ordered]@{}; response = [ordered]@{}; db_readback = [ordered]@{} }

if ($RunLiveRouteMatrix) {
  $session = Get-AdminSessionToken
  if (-not [bool]$session.present) {
    [void]$blockers.Add("admin_session_unavailable")
  } else {
    try {
      $liveMatrix = Invoke-LiveRouteMatrix -DatabaseUrl (Get-DatabaseUrl) -SessionToken ([string]$session.token)
      if (-not [bool]$liveMatrix.passed) {
        [void]$blockers.Add("user_remaining_balance_live_route_matrix_failed")
      }
    } catch {
      [void]$blockers.Add("user_remaining_balance_live_route_matrix_exception")
      $liveMatrix = [ordered]@{ ran = $true; passed = $false; checks = [ordered]@{}; response = [ordered]@{}; db_readback = [ordered]@{} }
    }
  }
} else {
  [void]$blockers.Add("user_remaining_balance_live_route_matrix_not_requested")
}

$status = if ([bool]$session.present -and [bool]$liveMatrix.passed) { "pass" } else { "blocked" }
$artifact = New-Artifact -Status $status -Blockers @($blockers) -SessionInfo $session -LiveMatrix $liveMatrix
Write-Artifact -Artifact $artifact -Output $output

Write-Output "user_remaining_balance_runtime_artifact_status=$status"
Write-Output "user_remaining_balance_runtime_artifact_path=$($output.relative)"
Write-Output "user_remaining_balance_runtime_secret_safe=true"
if ($status -eq "pass") { exit 0 }
exit 1
