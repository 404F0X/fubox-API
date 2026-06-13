param(
  [string]$OutputPath = ".tmp\credit-wallet\credit_grant_crud_runtime.json",
  [string]$ControlPlaneBaseUrl = "http://127.0.0.1:8081",
  [string]$SeedTenantId = "00000000-0000-0000-0000-000000000001",
  [string]$SeedWalletId = "00000000-0000-0000-0000-0000000032f3",
  [string]$AdminEmail = "admin@example.com",
  [string]$AdminPassword = "",
  [switch]$RunLiveRouteMatrix,
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
  if (-not (Test-SecretSafeText $json)) {
    throw "artifact_secret_safety_failed"
  }
  $parent = Split-Path -Parent $Output.full
  if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  Set-Content -LiteralPath $Output.full -Encoding UTF8 -Value $json
}

function Get-CurrentGitCommit {
  try {
    $commit = & git -C $repoRoot rev-parse HEAD 2>$null
    if (-not [string]::IsNullOrWhiteSpace($commit)) { return [string]$commit.Trim() }
  } catch {}
  return "unavailable"
}

function Get-NewestSourceTimestampUtc {
  $paths = @(
    "apps/control-plane/src",
    "apps/control-plane/Cargo.toml",
    "Cargo.toml",
    "Cargo.lock"
  )
  $newest = $null
  foreach ($relative in $paths) {
    $full = Join-Path $repoRoot $relative
    if (-not (Test-Path -LiteralPath $full)) { continue }
    $items = if ((Get-Item -LiteralPath $full).PSIsContainer) {
      Get-ChildItem -LiteralPath $full -Recurse -File
    } else {
      @(Get-Item -LiteralPath $full)
    }
    foreach ($item in $items) {
      if ($null -eq $newest -or $item.LastWriteTimeUtc -gt $newest) {
        $newest = $item.LastWriteTimeUtc
      }
    }
  }
  return $newest
}

function Parse-DockerTimestampUtc {
  param([string]$Value)
  try {
    return ([DateTimeOffset]::Parse($Value.Trim()).UtcDateTime)
  } catch {
    return $null
  }
}

function Get-RuntimeCurrentProbe {
  $sourceNewest = Get-NewestSourceTimestampUtc
  $sourceText = if ($null -eq $sourceNewest) { "unavailable" } else { $sourceNewest.ToString("o") }
  $probe = [ordered]@{
    checked = $true
    control_plane_runtime_current = $false
    classification = "runtime_current_unverified"
    blocker = "control_plane_container_unavailable"
    source_newest_utc = $sourceText
    container_created_utc = "unavailable"
    image_created_utc = "unavailable"
    image_id = "unavailable"
    git_commit = Get-CurrentGitCommit
    rebuild_command = "POSTGRES_HOST_PORT=55432 REDIS_HOST_PORT=56379 docker compose -f deploy/docker-compose/docker-compose.yml build control-plane; docker compose -f deploy/docker-compose/docker-compose.yml up -d control-plane"
  }
  $docker = Get-Command docker -ErrorAction SilentlyContinue
  if (-not $docker) {
    $probe.blocker = "docker_unavailable"
    return $probe
  }
  $containerId = (& $docker.Source compose -f (Join-Path $repoRoot "deploy/docker-compose/docker-compose.yml") ps -q control-plane 2>$null | Select-Object -First 1)
  if ([string]::IsNullOrWhiteSpace($containerId)) { return $probe }

  $inspect = & $docker.Source inspect -f "{{.Created}}|{{.Image}}" $containerId.Trim() 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($inspect)) {
    $probe.blocker = "control_plane_container_inspect_unavailable"
    return $probe
  }
  $parts = ([string]$inspect).Trim() -split "\|"
  $containerCreated = Parse-DockerTimestampUtc $parts[0]
  if ($null -ne $containerCreated) { $probe.container_created_utc = $containerCreated.ToString("o") }
  if ($parts.Count -gt 1 -and -not [string]::IsNullOrWhiteSpace($parts[1])) {
    $probe.image_id = [string]$parts[1]
  }
  $imageCreated = $null
  if ($probe.image_id -ne "unavailable") {
    $imageInspect = & $docker.Source image inspect -f "{{.Created}}" $probe.image_id 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($imageInspect)) {
      $imageCreated = Parse-DockerTimestampUtc $imageInspect
      if ($null -ne $imageCreated) { $probe.image_created_utc = $imageCreated.ToString("o") }
    }
  }
  if ($null -eq $sourceNewest -or $null -eq $imageCreated) {
    $probe.blocker = "runtime_current_timestamp_unavailable"
    return $probe
  }
  if ($sourceNewest -gt $imageCreated) {
    $probe.classification = "source_newer_than_runtime_image"
    $probe.blocker = "runtime_image_requires_rebuild"
    return $probe
  }
  $probe.control_plane_runtime_current = $true
  $probe.classification = "runtime_current_verified"
  $probe.blocker = "none"
  return $probe
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

function Invoke-Api {
  param(
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Path,
    [AllowNull()][object]$Body,
    [AllowNull()][string]$SessionToken
  )

  $uri = $ControlPlaneBaseUrl.TrimEnd("/") + $Path
  $headers = @{}
  if (-not [string]::IsNullOrWhiteSpace($SessionToken)) {
    $headers["x-admin-session"] = $SessionToken
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
      $status = [int]$_.Exception.Response.StatusCode
      try {
        $stream = $_.Exception.Response.GetResponseStream()
        if ($stream) {
          $reader = [System.IO.StreamReader]::new($stream)
          $content = $reader.ReadToEnd()
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
  if ([string]::IsNullOrWhiteSpace($AdminPassword)) {
    $AdminPassword = "local-password"
  }
  $login = Invoke-Api -Method "POST" -Path "/admin/auth/login" -Body @{ email = $AdminEmail; password = $AdminPassword } -SessionToken $null
  if (-not $login.ok -or $login.status_code -ne 200) {
    return [ordered]@{ present = $false; source = "dev_admin_login_failed"; token = "" }
  }
  $token = [string]$login.data.session_token_once
  if ([string]::IsNullOrWhiteSpace($token)) {
    return [ordered]@{ present = $false; source = "dev_admin_login_missing_session_token"; token = "" }
  }
  return [ordered]@{ present = $true; source = "dev_admin_login"; token = $token }
}

function New-CreateBody {
  param(
    [string]$RunId,
    [string]$WalletId,
    [string]$Amount,
    [string]$Currency,
    [string]$Source,
    [string]$Key
  )
  return [ordered]@{
    tenant_id = $SeedTenantId
    wallet_id = $WalletId
    amount = $Amount
    currency = $Currency
    source = $Source
    valid_from = "2026-06-05T12:00:00Z"
    valid_until = "2026-07-05T12:00:00Z"
    reason = "runtime verifier bounded credit grant CRUD test $RunId"
    actor_id = "00000000-0000-0000-0000-0000000032a1"
    actor_type = "operator"
    idempotency_key = $Key
  }
}

function New-LifecycleBody {
  param(
    [string]$GrantId,
    [string]$WalletId,
    [string]$Currency,
    [string]$Reason,
    [string]$Key
  )
  return [ordered]@{
    tenant_id = $SeedTenantId
    wallet_id = $WalletId
    currency = $Currency
    reason = $Reason
    actor_id = "00000000-0000-0000-0000-0000000032a1"
    actor_type = "operator"
    idempotency_key = $Key
  }
}

function Invoke-LiveRouteMatrix {
  param(
    [Parameter(Mandatory = $true)][string]$DatabaseUrl,
    [Parameter(Mandatory = $true)][string]$SessionToken
  )

  $runId = ([guid]::NewGuid().ToString("N")).Substring(0, 16)
  $sourceA = "e11_credit_crud_$runId"
  $sourceB = "e11_credit_crud_revoke_$runId"
  $walletId = $SeedWalletId
  $mismatchWalletId = "00000000-0000-0000-0000-0000000032e2"
  $seedSql = @"
insert into wallets (id, tenant_id, project_id, name, currency, status, balance_floor, metadata)
values
  ('$walletId'::uuid, '$SeedTenantId'::uuid, null, 'E11 credit grant CRUD verifier', 'USD', 'active', 0, '{"verifier":"e11_credit_grant_crud"}'::jsonb),
  ('$mismatchWalletId'::uuid, '$SeedTenantId'::uuid, null, 'E11 credit grant CRUD mismatch verifier', 'EUR', 'active', 0, '{"verifier":"e11_credit_grant_crud"}'::jsonb)
on conflict (id) do update
set currency = excluded.currency,
    status = excluded.status,
    deleted_at = null,
    updated_at = now();
select jsonb_build_object('wallet_seeded', true)::text;
"@
  [void](Invoke-PsqlJson -DatabaseUrl $DatabaseUrl -Sql $seedSql)

  $createBody = New-CreateBody -RunId $runId -WalletId $walletId -Amount "15.25000000" -Currency "USD" -Source $sourceA -Key "e11-credit-create-$runId"
  $create = Invoke-Api -Method "POST" -Path "/admin/credit-grants" -Body $createBody -SessionToken $SessionToken
  $replay = Invoke-Api -Method "POST" -Path "/admin/credit-grants" -Body $createBody -SessionToken $SessionToken
  $conflictBody = New-CreateBody -RunId $runId -WalletId $walletId -Amount "16.25000000" -Currency "USD" -Source $sourceA -Key "e11-credit-create-$runId"
  $conflict = Invoke-Api -Method "POST" -Path "/admin/credit-grants" -Body $conflictBody -SessionToken $SessionToken
  $nonPositive = Invoke-Api -Method "POST" -Path "/admin/credit-grants" -Body (New-CreateBody -RunId $runId -WalletId $walletId -Amount "-1.00000000" -Currency "USD" -Source "e11_credit_negative_$runId" -Key "e11-credit-negative-$runId") -SessionToken $SessionToken
  $walletMismatch = Invoke-Api -Method "POST" -Path "/admin/credit-grants" -Body (New-CreateBody -RunId $runId -WalletId $mismatchWalletId -Amount "5.00000000" -Currency "USD" -Source "e11_credit_wallet_mismatch_$runId" -Key "e11-credit-wallet-mismatch-$runId") -SessionToken $SessionToken

  $grantId = [string]$create.data.credit_grant_id
  $auditId = [string]$create.data.audit_id
  $list = Invoke-Api -Method "GET" -Path "/admin/credit-grants?wallet_id=$walletId&status=active&limit=25" -Body $null -SessionToken $SessionToken
  $read = Invoke-Api -Method "GET" -Path "/admin/credit-grants/$grantId" -Body $null -SessionToken $SessionToken
  $expire = Invoke-Api -Method "POST" -Path "/admin/credit-grants/$grantId/expire" -Body (New-LifecycleBody -GrantId $grantId -WalletId $walletId -Currency "USD" -Reason "expire runtime verifier $runId" -Key "e11-credit-expire-$runId") -SessionToken $SessionToken
  $expireReplay = Invoke-Api -Method "POST" -Path "/admin/credit-grants/$grantId/expire" -Body (New-LifecycleBody -GrantId $grantId -WalletId $walletId -Currency "USD" -Reason "expire runtime verifier $runId" -Key "e11-credit-expire-$runId") -SessionToken $SessionToken
  $statusNotActive = Invoke-Api -Method "POST" -Path "/admin/credit-grants/$grantId/expire" -Body (New-LifecycleBody -GrantId $grantId -WalletId $walletId -Currency "USD" -Reason "expire runtime verifier second refusal $runId" -Key "e11-credit-expire-second-$runId") -SessionToken $SessionToken
  $readExpired = Invoke-Api -Method "GET" -Path "/admin/credit-grants/$grantId" -Body $null -SessionToken $SessionToken

  $revokeBody = New-CreateBody -RunId $runId -WalletId $walletId -Amount "7.50000000" -Currency "USD" -Source $sourceB -Key "e11-credit-create-revoke-$runId"
  $createRevoke = Invoke-Api -Method "POST" -Path "/admin/credit-grants" -Body $revokeBody -SessionToken $SessionToken
  $revokeGrantId = [string]$createRevoke.data.credit_grant_id
  $revoke = Invoke-Api -Method "POST" -Path "/admin/credit-grants/$revokeGrantId/revoke" -Body (New-LifecycleBody -GrantId $revokeGrantId -WalletId $walletId -Currency "USD" -Reason "revoke runtime verifier $runId" -Key "e11-credit-revoke-$runId") -SessionToken $SessionToken
  $revokeReplay = Invoke-Api -Method "POST" -Path "/admin/credit-grants/$revokeGrantId/revoke" -Body (New-LifecycleBody -GrantId $revokeGrantId -WalletId $walletId -Currency "USD" -Reason "revoke runtime verifier $runId" -Key "e11-credit-revoke-$runId") -SessionToken $SessionToken
  $readRevoked = Invoke-Api -Method "GET" -Path "/admin/credit-grants/$revokeGrantId" -Body $null -SessionToken $SessionToken

  $readbackSql = @"
select jsonb_build_object(
  'grant_rows_for_run', (
    select count(*)::int from credit_grants
    where tenant_id = '$SeedTenantId'::uuid
      and wallet_id = '$walletId'::uuid
      and source in ('$sourceA', '$sourceB')
  ),
  'created_grant_count', (
    select count(*)::int from credit_grants
    where tenant_id = '$SeedTenantId'::uuid
      and id = '$grantId'::uuid
      and source = '$sourceA'
      and status = 'expired'
  ),
  'revoked_grant_count', (
    select count(*)::int from credit_grants
    where tenant_id = '$SeedTenantId'::uuid
      and id = '$revokeGrantId'::uuid
      and source = '$sourceB'
      and status = 'voided'
  ),
  'negative_grant_count', (
    select count(*)::int from credit_grants
    where tenant_id = '$SeedTenantId'::uuid
      and source = 'e11_credit_negative_$runId'
  ),
  'wallet_mismatch_grant_count', (
    select count(*)::int from credit_grants
    where tenant_id = '$SeedTenantId'::uuid
      and source = 'e11_credit_wallet_mismatch_$runId'
  ),
  'create_audit_count', (
    select count(*)::int from audit_logs
    where tenant_id = '$SeedTenantId'::uuid
      and resource_type = 'credit_grant'
      and resource_id in ('$grantId'::uuid, '$revokeGrantId'::uuid)
      and action = 'credit_grant.create'
  ),
  'expire_audit_count', (
    select count(*)::int from audit_logs
    where tenant_id = '$SeedTenantId'::uuid
      and resource_type = 'credit_grant'
      and resource_id = '$grantId'::uuid
      and action = 'credit_grant.expire'
  ),
  'revoke_audit_count', (
    select count(*)::int from audit_logs
    where tenant_id = '$SeedTenantId'::uuid
      and resource_type = 'credit_grant'
      and resource_id = '$revokeGrantId'::uuid
      and action = 'credit_grant.revoke'
  )
)::text;
"@
  $readback = Invoke-PsqlJson -DatabaseUrl $DatabaseUrl -Sql $readbackSql

  $listIds = @($list.data | ForEach-Object { [string]$_.id })
  $sameCreateReplayGrant = [string]$replay.data.credit_grant_id -eq $grantId
  $sameCreateReplayAudit = [string]$replay.data.audit_id -eq $auditId
  $sameExpireReplayGrant = [string]$expireReplay.data.credit_grant_id -eq $grantId
  $sameExpireReplayAudit = [string]$expireReplay.data.audit_id -eq [string]$expire.data.audit_id
  $sameRevokeReplayGrant = [string]$revokeReplay.data.credit_grant_id -eq $revokeGrantId
  $sameRevokeReplayAudit = [string]$revokeReplay.data.audit_id -eq [string]$revoke.data.audit_id

  $checks = [ordered]@{
    create_http_201 = ([int]$create.status_code -eq 201)
    create_schema_passed = ([string]$create.data.schema -eq "credit_grant_crud_runtime.v1")
    create_status_active = ([string]$create.data.status -eq "active")
    create_ids_present = (-not [string]::IsNullOrWhiteSpace($grantId) -and -not [string]::IsNullOrWhiteSpace($auditId))
    create_secret_safe = ([bool]$create.data.secret_safe -and -not [bool]$create.data.paid_gate_changed)
    create_replay_http_200 = ([int]$replay.status_code -eq 200)
    create_replay_same_grant_id = $sameCreateReplayGrant
    create_replay_same_audit_id = $sameCreateReplayAudit
    create_replay_same_ids = ($sameCreateReplayGrant -and $sameCreateReplayAudit)
    idempotency_conflict_refused = ([string]$conflict.data.status -eq "refused" -and [string]$conflict.data.outcome -eq "idempotency_conflict")
    non_positive_amount_refused = ([int]$nonPositive.status_code -eq 400)
    wallet_mismatch_refused = ([string]$walletMismatch.data.status -eq "refused" -and [string]$walletMismatch.data.outcome -eq "wallet_currency_mismatch")
    list_sees_created_grant = $listIds.Contains($grantId)
    read_sees_created_grant = ([string]$read.data.id -eq $grantId -and [string]$read.data.status -eq "active")
    expire_status_expired = ([string]$expire.data.status -eq "expired" -and [string]$expire.data.outcome -eq "expire" -and -not [string]::IsNullOrWhiteSpace([string]$expire.data.audit_id))
    expire_replay_same_grant_id = $sameExpireReplayGrant
    expire_replay_same_audit_id = $sameExpireReplayAudit
    expire_replay_same_ids = ($sameExpireReplayGrant -and $sameExpireReplayAudit)
    read_expired_status = ([string]$readExpired.data.status -eq "expired")
    status_not_active_refused = (
      ([string]$statusNotActive.data.status -eq "refused") -and
      (([string]$statusNotActive.data.outcome) -in @("already_expired", "credit_grant_status_not_active"))
    )
    revoke_create_active = ([string]$createRevoke.data.status -eq "active" -and -not [string]::IsNullOrWhiteSpace($revokeGrantId))
    revoke_status_voided = ([string]$revoke.data.status -eq "voided" -and [string]$revoke.data.outcome -eq "revoke" -and -not [string]::IsNullOrWhiteSpace([string]$revoke.data.audit_id))
    revoke_replay_same_grant_id = $sameRevokeReplayGrant
    revoke_replay_same_audit_id = $sameRevokeReplayAudit
    revoke_replay_same_ids = ($sameRevokeReplayGrant -and $sameRevokeReplayAudit)
    read_revoked_status = ([string]$readRevoked.data.status -eq "voided")
    db_two_grants_only = ([int]$readback.grant_rows_for_run -eq 2)
    db_created_grant_expired = ([int]$readback.created_grant_count -eq 1)
    db_revoked_grant_voided = ([int]$readback.revoked_grant_count -eq 1)
    db_refusals_no_grant = ([int]$readback.negative_grant_count -eq 0 -and [int]$readback.wallet_mismatch_grant_count -eq 0)
    db_create_audits = ([int]$readback.create_audit_count -eq 2)
    db_expire_audit = ([int]$readback.expire_audit_count -eq 1)
    db_revoke_audit = ([int]$readback.revoke_audit_count -eq 1)
  }
  $observed = [ordered]@{
    status_not_active_status = [string]$statusNotActive.data.status
    status_not_active_outcome = [string]$statusNotActive.data.outcome
    status_not_active_status_code = [int]$statusNotActive.status_code
  }
  $allPassed = -not (@($checks.GetEnumerator() | Where-Object { -not [bool]$_.Value }).Count -gt 0)

  return [ordered]@{
    ran = $true
    passed = $allPassed
    run_id = $runId
    grant_id = $grantId
    audit_id = $auditId
    revoke_grant_id = $revokeGrantId
    expire_audit_id = [string]$expire.data.audit_id
    revoke_audit_id = [string]$revoke.data.audit_id
    route_matrix_results = $checks
    route_matrix_observed = $observed
    db_readback_counts = $readback
  }
}

function New-Artifact {
  param(
    [string]$Status,
    [string[]]$Blockers,
    [object]$RuntimeProbe,
    [object]$SessionInfo,
    [object]$LiveMatrix
  )

  $passed = $Status -eq "pass"
  return [ordered]@{
    schema = "credit_grant_crud_runtime.v1"
    overall_status = $Status
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    endpoint = "/admin/credit-grants"
    endpoints = @(
      "POST /admin/credit-grants",
      "GET /admin/credit-grants",
      "GET /admin/credit-grants/{credit_grant_id}",
      "POST /admin/credit-grants/{credit_grant_id}/expire",
      "POST /admin/credit-grants/{credit_grant_id}/revoke"
    )
    runtime_implemented = $passed
    contract_only = (-not $passed)
    route_invoked = [bool]$LiveMatrix.ran
    public_route_invoked = [bool]$LiveMatrix.ran
    control_plane_runtime_current = [bool]$RuntimeProbe.control_plane_runtime_current
    runtime_current = $RuntimeProbe
    admin_session_present = [bool]$SessionInfo.present
    admin_session = [ordered]@{
      present = [bool]$SessionInfo.present
      source = [string]$SessionInfo.source
      echoed = $false
    }
    credit_grant_crud_endpoints_present = $true
    credit_grant_id = [string]$LiveMatrix.grant_id
    grant_id = [string]$LiveMatrix.grant_id
    audit_id = [string]$LiveMatrix.audit_id
    revoke_credit_grant_id = [string]$LiveMatrix.revoke_grant_id
    expire_audit_id = [string]$LiveMatrix.expire_audit_id
    revoke_audit_id = [string]$LiveMatrix.revoke_audit_id
    grant_id_present = $passed
    audit_id_present = $passed
    create_readback_passed = [bool]$LiveMatrix.route_matrix_results.create_status_active
    list_readback_passed = [bool]$LiveMatrix.route_matrix_results.list_sees_created_grant
    read_readback_passed = [bool]$LiveMatrix.route_matrix_results.read_sees_created_grant
    expire_readback_passed = [bool]($LiveMatrix.route_matrix_results.expire_status_expired -and $LiveMatrix.route_matrix_results.read_expired_status)
    revoke_readback_passed = [bool]($LiveMatrix.route_matrix_results.revoke_status_voided -and $LiveMatrix.route_matrix_results.read_revoked_status)
    status_readback_passed = [bool]($LiveMatrix.route_matrix_results.read_expired_status -and $LiveMatrix.route_matrix_results.read_revoked_status)
    replay_readback_passed = [bool]($LiveMatrix.route_matrix_results.create_replay_same_ids -and $LiveMatrix.route_matrix_results.expire_replay_same_ids -and $LiveMatrix.route_matrix_results.revoke_replay_same_ids)
    conflict_or_refusal_no_write_passed = [bool]($LiveMatrix.route_matrix_results.idempotency_conflict_refused -and $LiveMatrix.route_matrix_results.non_positive_amount_refused -and $LiveMatrix.route_matrix_results.wallet_mismatch_refused -and $LiveMatrix.route_matrix_results.status_not_active_refused -and $LiveMatrix.route_matrix_results.db_refusals_no_grant)
    audit_readback_passed = [bool]($LiveMatrix.route_matrix_results.db_create_audits -and $LiveMatrix.route_matrix_results.db_expire_audit -and $LiveMatrix.route_matrix_results.db_revoke_audit)
    money_decimal_strings = $true
    idempotency_contract = $true
    audit_required = $true
    direct_wallet_snapshot_mutation_forbidden = $true
    secret_safe = $true
    raw_secret_markers_present = $false
    paid_gate_changed = $false
    route_matrix_results = $LiveMatrix.route_matrix_results
    route_matrix_observed = $LiveMatrix.route_matrix_observed
    db_readback_results = [ordered]@{
      counts = $LiveMatrix.db_readback_counts
      grant_rows_expected = 2
      create_audits_expected = 2
      expire_audits_expected = 1
      revoke_audits_expected = 1
    }
    artifact_secret_policy = [ordered]@{
      session_token_echoed = $false
      auth_header_echoed = $false
      cookie_echoed = $false
      raw_db_url_echoed = $false
      provider_or_virtual_key_echoed = $false
      raw_idempotency_material_echoed = $false
    }
    blockers = @($Blockers)
  }
}

$output = Resolve-RepoBoundedPath -Path $OutputPath -AllowedPrefixes @(".tmp/", "artifacts/")

if ($SelfTest) {
  $probe = [ordered]@{ control_plane_runtime_current = $true; classification = "runtime_current_verified"; blocker = "none"; git_commit = "selftest" }
  $session = [ordered]@{ present = $true; source = "selftest"; token = "omitted" }
  $matrix = [ordered]@{
    ran = $true
    passed = $true
    grant_id = "00000000-0000-0000-0000-000000003201"
    audit_id = "00000000-0000-0000-0000-000000003202"
    revoke_grant_id = "00000000-0000-0000-0000-000000003203"
    expire_audit_id = "00000000-0000-0000-0000-000000003204"
    revoke_audit_id = "00000000-0000-0000-0000-000000003205"
    route_matrix_results = [ordered]@{
      create_status_active = $true; list_sees_created_grant = $true; read_sees_created_grant = $true
      expire_status_expired = $true; read_expired_status = $true; revoke_status_voided = $true; read_revoked_status = $true
      create_replay_same_ids = $true; expire_replay_same_ids = $true; revoke_replay_same_ids = $true
      idempotency_conflict_refused = $true; non_positive_amount_refused = $true; wallet_mismatch_refused = $true; status_not_active_refused = $true
      db_refusals_no_grant = $true; db_create_audits = $true; db_expire_audit = $true; db_revoke_audit = $true
    }
    db_readback_counts = [ordered]@{ grant_rows_for_run = 2; create_audit_count = 2; expire_audit_count = 1; revoke_audit_count = 1 }
  }
  $artifact = New-Artifact -Status "pass" -Blockers @() -RuntimeProbe $probe -SessionInfo $session -LiveMatrix $matrix
  if (-not (Test-SecretSafeText ($artifact | ConvertTo-Json -Depth 14))) { throw "selftest_secret_safety_failed" }
  Write-Output "credit_grant_crud_runtime_selftest_status=pass"
  exit 0
}

$blockers = [System.Collections.Generic.List[string]]::new()
$runtimeProbe = Get-RuntimeCurrentProbe
if (-not [bool]$runtimeProbe.control_plane_runtime_current) {
  [void]$blockers.Add([string]$runtimeProbe.blocker)
}

$session = [ordered]@{ present = $false; source = "not_requested"; token = "" }
$liveMatrix = [ordered]@{ ran = $false; passed = $false; route_matrix_results = [ordered]@{}; db_readback_counts = [ordered]@{} }

if ($RunLiveRouteMatrix) {
  $session = Get-AdminSessionToken
  if (-not [bool]$session.present) {
    [void]$blockers.Add("admin_session_unavailable")
  } elseif ([bool]$runtimeProbe.control_plane_runtime_current) {
    try {
      $liveMatrix = Invoke-LiveRouteMatrix -DatabaseUrl (Get-DatabaseUrl) -SessionToken ([string]$session.token)
      if (-not [bool]$liveMatrix.passed) {
        [void]$blockers.Add("credit_grant_crud_live_route_matrix_failed")
      }
    } catch {
      [void]$blockers.Add("credit_grant_crud_live_route_matrix_exception")
      $liveMatrix = [ordered]@{ ran = $true; passed = $false; route_matrix_results = [ordered]@{}; db_readback_counts = [ordered]@{} }
    }
  }
} else {
  [void]$blockers.Add("credit_grant_crud_live_route_matrix_not_requested")
}

$status = if ([bool]$runtimeProbe.control_plane_runtime_current -and [bool]$session.present -and [bool]$liveMatrix.passed) { "pass" } else { "blocked" }
$artifact = New-Artifact -Status $status -Blockers @($blockers) -RuntimeProbe $runtimeProbe -SessionInfo $session -LiveMatrix $liveMatrix
Write-Artifact -Artifact $artifact -Output $output

Write-Output "credit_grant_crud_runtime_artifact_status=$status"
Write-Output "credit_grant_crud_runtime_artifact_path=$($output.relative)"
Write-Output "credit_grant_crud_runtime_secret_safe=true"
if ($status -eq "pass") { exit 0 }
exit 1
