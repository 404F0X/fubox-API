<#
.SYNOPSIS
Runs live HTTP route proof against an already running local Compose stack.

.NOTES
This script uses docker compose exec for database readback, so Postgres/Redis
host-port overrides are only needed when starting Compose. If 5432/6379 are
occupied, start the stack with:
$env:POSTGRES_HOST_PORT = "55432"; $env:REDIS_HOST_PORT = "56379"; .\scripts\compose_up.ps1 -ForceRecreate
#>
param(
  [string]$ControlPlaneBaseUrl = "http://127.0.0.1:8081",
  [string]$GatewayBaseUrl = "http://127.0.0.1:8080",
  [string]$AdminEmail = "admin@example.com",
  [string]$AdminPassword = "local-password",
  [string]$GatewayModel = "mock-gpt-4o-mini",
  [string]$ComposeFile = "deploy/docker-compose/docker-compose.yml",
  [string]$OutputPath = ".tmp/route-live-http-proof/route_level_live_http_proof.json",
  [int]$TimeoutSeconds = 8,
  [int]$DbPollSeconds = 10,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$tenantId = "00000000-0000-0000-0000-000000000001"
$projectId = "00000000-0000-0000-0000-000000000020"
$profileId = "00000000-0000-0000-0000-000000000040"
$walletId = "00000000-0000-0000-0000-0000000032a5"
$runId = [guid]::NewGuid().ToString("N")
$script:SensitiveValues = @($AdminPassword)
$script:Blockers = New-Object System.Collections.Generic.List[string]

if ($env:CONTROL_PLANE_BASE_URL) { $ControlPlaneBaseUrl = $env:CONTROL_PLANE_BASE_URL }
if ($env:GATEWAY_BASE_URL) { $GatewayBaseUrl = $env:GATEWAY_BASE_URL }
if ($env:CONTROL_PLANE_ADMIN_EMAIL) { $AdminEmail = $env:CONTROL_PLANE_ADMIN_EMAIL }
if ($env:CONTROL_PLANE_ADMIN_PASSWORD) { $AdminPassword = $env:CONTROL_PLANE_ADMIN_PASSWORD }
if ($env:SMOKE_MODEL) { $GatewayModel = $env:SMOKE_MODEL }
if ($env:COMPOSE_FILE) { $ComposeFile = $env:COMPOSE_FILE }

Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Security

function Add-SensitiveValue {
  param([AllowNull()][string]$Value)
  if (-not [string]::IsNullOrWhiteSpace($Value)) {
    $script:SensitiveValues += [string]$Value
  }
}

function Redact-SecretLikeString {
  param([AllowNull()][string]$Text)

  if ($null -eq $Text) { return "" }
  $redacted = [string]$Text
  foreach ($secret in $script:SensitiveValues) {
    if (-not [string]::IsNullOrEmpty($secret)) {
      $redacted = $redacted.Replace($secret, "[REDACTED]")
    }
  }
  $redacted = $redacted -replace '(?i)("session_token_once"\s*:\s*")[^"]+(")', '$1[REDACTED]$2'
  $redacted = $redacted -replace '(?i)("secret"\s*:\s*")[^"]+(")', '$1[REDACTED]$2'
  $redacted = $redacted -replace '(?i)("voucher_code"\s*:\s*")[^"]+(")', '$1[REDACTED]$2'
  $redacted = $redacted -replace '(?i)("raw_voucher_code"\s*:\s*")[^"]+(")', '$1[REDACTED]$2'
  $redacted = $redacted -replace '(?i)(x-admin-session\s*[:=]\s*)[^\s";,]+', '$1[REDACTED]'
  $redacted = $redacted -replace '(?i)(authorization\s*[:=]\s*bearer\s+)[^\s";,]+', '$1[REDACTED]'
  $redacted = $redacted -replace '(?i)(Bearer\s+)[A-Za-z0-9._~+/\-]+=*', '$1[REDACTED]'
  $redacted = $redacted -replace 'sess_[A-Za-z0-9._~+/\-=]+', '[REDACTED]'
  $redacted = $redacted -replace 'sk-[A-Za-z0-9._~+\-/=]+', '[REDACTED]'
  return $redacted
}

function Test-SecretSafeText {
  param([AllowNull()][string]$Text)

  if ([string]::IsNullOrEmpty($Text)) { return $true }
  foreach ($secret in $script:SensitiveValues) {
    if (-not [string]::IsNullOrEmpty($secret) -and $Text.Contains($secret)) {
      return $false
    }
  }
  foreach ($pattern in @(
      '(?i)authorization\s*[:=]',
      '(?i)cookie\s*[:=]',
      '(?i)bearer\s+[A-Za-z0-9._~+/\-]+=*',
      '(?i)x-admin-session\s*[:=]',
      '(?i)"session_token_once"\s*:',
      '(?i)"raw_voucher_code"\s*:',
      '(?i)"voucher_code"\s*:',
      '(?i)"secret"\s*:',
      '(?i)postgres(?:ql)?://[^"\s]+',
      '(?i)password\s*[:=]'
    )) {
    if ($Text -match $pattern) { return $false }
  }
  return $true
}

function Join-Url {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$Path
  )
  if (-not $Path.StartsWith("/")) { $Path = "/$Path" }
  return $BaseUrl.TrimEnd("/") + $Path
}

function ConvertTo-JsonString {
  param([Parameter(Mandatory = $true)][string]$Value)
  return ($Value | ConvertTo-Json -Compress)
}

function Get-Sha256Hex {
  param([Parameter(Mandatory = $true)][string]$Text)
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Invoke-HttpJson {
  param(
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Uri,
    [object]$Body = $null,
    [hashtable]$Headers = @{}
  )

  $client = New-Object System.Net.Http.HttpClient
  $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
  $request = New-Object System.Net.Http.HttpRequestMessage -ArgumentList (New-Object System.Net.Http.HttpMethod -ArgumentList $Method), $Uri
  foreach ($key in $Headers.Keys) {
    [void]$request.Headers.TryAddWithoutValidation($key, [string]$Headers[$key])
  }
  if ($null -ne $Body) {
    $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 16 -Compress }
    $content = New-Object System.Net.Http.StringContent -ArgumentList $json
    $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/json")
    $request.Content = $content
  }
  $response = $null
  try {
    $response = $client.SendAsync($request).GetAwaiter().GetResult()
    $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $payload = $null
    if (-not [string]::IsNullOrWhiteSpace($content)) {
      try { $payload = $content | ConvertFrom-Json } catch { $payload = $null }
    }
    return [PSCustomObject]@{
      status_code = [int]$response.StatusCode
      content = $content
      json = $payload
    }
  } finally {
    if ($response) { $response.Dispose() }
    $request.Dispose()
    $client.Dispose()
  }
}

function Escape-SqlLiteral {
  param([Parameter(Mandatory = $true)][string]$Value)
  return $Value.Replace("'", "''")
}

function Invoke-ComposePsql {
  param([Parameter(Mandatory = $true)][string]$Sql)

  Push-Location $repoRoot
  try {
    $output = Invoke-Docker compose -f $ComposeFile exec -T postgres psql `
      -U ai_gateway `
      -d ai_gateway `
      -tA `
      -v ON_ERROR_STOP=1 `
      -c $Sql 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "psql failed: $(Redact-SecretLikeString (($output | Out-String).Trim()))"
    }
    return (($output | Out-String).Trim())
  } finally {
    Pop-Location
  }
}

function Invoke-ComposePsqlJson {
  param([Parameter(Mandatory = $true)][string]$Sql)
  $text = Invoke-ComposePsql $Sql
  if ([string]::IsNullOrWhiteSpace($text)) { throw "psql returned empty result" }
  return $text | ConvertFrom-Json
}

function Write-ProofArtifact {
  param(
    [Parameter(Mandatory = $true)][string]$Status,
    [Parameter(Mandatory = $true)][object]$Sections,
    [string[]]$Blockers = @()
  )

  $artifact = [ordered]@{
    schema = "route_level_live_http_proof.v1"
    overall_status = $Status
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    run_id = $runId
    control_plane_base_url = $ControlPlaneBaseUrl
    gateway_base_url = $GatewayBaseUrl
    model = $GatewayModel
    compose_file = $ComposeFile
    admin_login = $Sections.admin_login
    virtual_key = $Sections.virtual_key
    gateway_route = $Sections.gateway_route
    voucher = $Sections.voucher
    secret_safe = $true
    paid_gate_changed = $false
    simulation = $false
    raw_secret_omitted = $true
    raw_voucher_code_omitted = $true
    blockers = @($Blockers)
  }

  $json = $artifact | ConvertTo-Json -Depth 16
  if (-not (Test-SecretSafeText $json)) {
    throw "artifact_secret_safety_failed"
  }
  $full = if ([System.IO.Path]::IsPathRooted($OutputPath)) {
    [System.IO.Path]::GetFullPath($OutputPath)
  } else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputPath))
  }
  $repoPrefix = $repoRoot.Path.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
  if (-not $full.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "output_path_must_stay_inside_repo"
  }
  $parent = Split-Path -Parent $full
  if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
  Set-Content -Path $full -Encoding UTF8 -Value $json
  Write-Host "route_level_live_http_proof_status=$Status"
  Write-Host "route_level_live_http_proof_artifact=$OutputPath"
}

function New-DefaultSections {
  return [ordered]@{
    admin_login = [ordered]@{ route_invoked = $false; session_token_returned_once = $false }
    virtual_key = [ordered]@{ route_invoked = $false; created = $false; get_redacted = $false; audit_readback = $false; gateway_accepted_created_secret = $false; raw_secret_in_artifact = $false }
    gateway_route = [ordered]@{ route_invoked = $false; model = $GatewayModel; http_status = $null; request_log_readback = $false; provider_attempt_readback = $false; resolved_provider_id_present = $false; resolved_channel_id_present = $false; route_policy_version = $null }
    voucher = [ordered]@{ issue_route_invoked = $false; redeem_route_invoked = $false; issue_readback = $false; redeem_readback = $false; attempt_readback = $false; credit_grant_readback = $false; ledger_readback = $false; audit_readback = $false; raw_voucher_code_in_artifact = $false }
  }
}

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Ensure-ProofWallet {
  $sql = @"
insert into wallets (id, tenant_id, project_id, name, currency, status, metadata)
values ('$walletId'::uuid, '$tenantId'::uuid, '$projectId'::uuid, 'Route live proof wallet', 'USD', 'active', jsonb_build_object('route_live_http_proof', true))
on conflict (id) do update
set status = 'active',
    currency = 'USD',
    project_id = '$projectId'::uuid,
    metadata = wallets.metadata || jsonb_build_object('route_live_http_proof', true),
    updated_at = now();
"@
  [void](Invoke-ComposePsql $sql)
}

if ($DryRun) {
  $sections = New-DefaultSections
  Write-ProofArtifact -Status "dry_run" -Sections $sections -Blockers @("dry_run_no_live_routes_invoked")
  exit 0
}

$sections = New-DefaultSections
try {
  Ensure-ProofWallet

  $loginResponse = Invoke-HttpJson -Method "POST" -Uri (Join-Url $ControlPlaneBaseUrl "/admin/auth/login") -Body @{
    email = $AdminEmail
    password = $AdminPassword
  }
  Assert-True ($loginResponse.status_code -eq 200) "admin login expected HTTP 200 got $($loginResponse.status_code)"
  $sessionToken = [string]$loginResponse.json.data.session_token_once
  Assert-True (-not [string]::IsNullOrWhiteSpace($sessionToken)) "admin login did not return session token"
  Add-SensitiveValue $sessionToken
  $sections.admin_login = [ordered]@{
    route_invoked = $true
    user_email = $AdminEmail
    session_token_returned_once = $true
  }
  $adminHeaders = @{ "x-admin-session" = $sessionToken }

  $createKeyResponse = Invoke-HttpJson -Method "POST" -Uri (Join-Url $ControlPlaneBaseUrl "/admin/virtual-keys") -Headers $adminHeaders -Body @{
    project_id = $projectId
    name = "route live proof $runId"
    default_profile_id = $profileId
    status = "active"
    metadata = @{ route_live_http_proof = $true; run_id = $runId }
  }
  Assert-True ($createKeyResponse.status_code -eq 201) "virtual key create expected HTTP 201 got $($createKeyResponse.status_code)"
  $createdKey = $createKeyResponse.json.data
  $virtualKeyId = [string]$createdKey.id
  $keyPrefix = [string]$createdKey.key_prefix
  $virtualKeySecret = [string]$createdKey.secret
  Assert-True (-not [string]::IsNullOrWhiteSpace($virtualKeySecret)) "virtual key create did not return one-time secret"
  Add-SensitiveValue $virtualKeySecret
  Assert-True ([bool]$createdKey.secret_once) "virtual key create did not mark secret_once"
  Assert-True (-not [bool]$createdKey.secret_redacted) "virtual key create should not redact one-time secret response"

  $getKeyResponse = Invoke-HttpJson -Method "GET" -Uri (Join-Url $ControlPlaneBaseUrl "/admin/virtual-keys/$virtualKeyId") -Headers $adminHeaders
  Assert-True ($getKeyResponse.status_code -eq 200) "virtual key get expected HTTP 200 got $($getKeyResponse.status_code)"
  $getKeyData = $getKeyResponse.json.data
  Assert-True ([bool]$getKeyData.secret_redacted) "virtual key get must be redacted"
  Assert-True (-not ($getKeyData.PSObject.Properties.Name -contains "secret")) "virtual key get returned secret"

  $vkSql = @"
select jsonb_build_object(
  'virtual_key_exists', vk.id is not null,
  'key_prefix_matches', vk.key_prefix = '$(Escape-SqlLiteral $keyPrefix)',
  'secret_hash_not_empty', length(vk.secret_hash) > 0,
  'status', vk.status,
  'default_profile_id', vk.default_profile_id::text,
  'binding_exists', exists (
    select 1 from virtual_key_profile_bindings b
    where b.tenant_id = vk.tenant_id
      and b.project_id = vk.project_id
      and b.virtual_key_id = vk.id
      and b.profile_id = vk.default_profile_id
      and b.is_default = true
  ),
  'audit_exists', exists (
    select 1 from audit_logs a
    where a.tenant_id = vk.tenant_id
      and a.resource_type = 'virtual_key'
      and a.resource_id = vk.id
      and a.action = 'virtual_key.create'
  )
)::text
from virtual_keys vk
where vk.id = '$virtualKeyId'::uuid;
"@
  $vkReadback = Invoke-ComposePsqlJson $vkSql
  $sections.virtual_key = [ordered]@{
    route_invoked = $true
    created = $true
    key_prefix_matches = [bool]$vkReadback.key_prefix_matches
    secret_hash_not_empty = [bool]$vkReadback.secret_hash_not_empty
    get_redacted = $true
    audit_readback = [bool]$vkReadback.audit_exists
    binding_readback = [bool]$vkReadback.binding_exists
    gateway_accepted_created_secret = $false
    raw_secret_in_artifact = $false
  }
  Assert-True ([bool]$vkReadback.audit_exists) "virtual key audit readback missing"
  Assert-True ([bool]$vkReadback.binding_exists) "virtual key default profile binding missing"

  $chatJson = '{"model":' + (ConvertTo-JsonString $GatewayModel) + ',"messages":[{"role":"user","content":' + (ConvertTo-JsonString "route live proof $runId") + '}],"stream":false}'
  $chatHash = Get-Sha256Hex $chatJson
  $gatewayResponse = Invoke-HttpJson -Method "POST" -Uri (Join-Url $GatewayBaseUrl "/v1/chat/completions") -Headers @{ Authorization = "Bearer $virtualKeySecret" } -Body $chatJson
  Assert-True ($gatewayResponse.status_code -eq 200) "gateway chat expected HTTP 200 got $($gatewayResponse.status_code)"

  $requestRows = @()
  $deadline = (Get-Date).AddSeconds($DbPollSeconds)
  do {
    $hash = Escape-SqlLiteral $chatHash
    $sql = @"
select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb)::text
from (
  select
    rl.id::text as request_id,
    rl.status as request_status,
    rl.http_status as request_http_status,
    rl.requested_model,
    rl.resolved_provider_id::text as resolved_provider_id,
    rl.resolved_channel_id::text as resolved_channel_id,
    rl.route_policy_version,
    pa.id::text as attempt_id,
    pa.status as attempt_status,
    pa.http_status as attempt_http_status
  from request_logs rl
  left join provider_attempts pa
    on pa.tenant_id = rl.tenant_id
   and pa.request_id = rl.id
  where rl.request_body_hash = '$hash'
  order by rl.created_at desc, pa.attempt_no asc
  limit 5
) t;
"@
    $requestRows = @(Invoke-ComposePsqlJson $sql)
    if ($requestRows.Count -gt 0) { break }
    Start-Sleep -Milliseconds 500
  } while ((Get-Date) -lt $deadline)
  Assert-True ($requestRows.Count -gt 0) "request log readback missing"
  $firstRequest = $requestRows[0]
  $providerAttemptReadback = @($requestRows | Where-Object { $_.attempt_id -and $_.attempt_status -eq "succeeded" }).Count -gt 0
  $gatewayRequestIds = @($requestRows | ForEach-Object { [string]$_.request_id } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
  $sections.virtual_key.gateway_accepted_created_secret = $true
  $sections.gateway_route = [ordered]@{
    route_invoked = $true
    model = $GatewayModel
    http_status = [int]$gatewayResponse.status_code
    request_id = [string]$firstRequest.request_id
    request_ids = [object[]]@($gatewayRequestIds)
    request_log_readback = $true
    provider_attempt_readback = $providerAttemptReadback
    resolved_provider_id_present = -not [string]::IsNullOrWhiteSpace([string]$firstRequest.resolved_provider_id)
    resolved_channel_id_present = -not [string]::IsNullOrWhiteSpace([string]$firstRequest.resolved_channel_id)
    route_policy_version = [string]$firstRequest.route_policy_version
  }
  Assert-True $providerAttemptReadback "provider attempt readback missing"

  $voucherCode = "route-proof-$runId"
  Add-SensitiveValue $voucherCode
  $issueResponse = Invoke-HttpJson -Method "POST" -Uri (Join-Url $ControlPlaneBaseUrl "/admin/voucher-issuances") -Headers $adminHeaders -Body @{
    tenant_id = $tenantId
    project_id = $projectId
    wallet_id = $walletId
    campaign_id = $null
    currency = "USD"
    amount = "25.00000000"
    raw_voucher_code = $voucherCode
    idempotency_key = "route-proof-issue-$runId"
    max_redemptions = 1
    expires_at = $null
  }
  Assert-True ($issueResponse.status_code -in @(200, 201)) "voucher issue expected HTTP 200/201 got $($issueResponse.status_code)"
  $issue = $issueResponse.json.data
  Assert-True ([string]$issue.status -eq "issued") "voucher issue did not return issued"
  Assert-True (-not [bool]$issue.raw_voucher_code_echoed) "voucher issue echoed raw code"

  $redeemResponse = Invoke-HttpJson -Method "POST" -Uri (Join-Url $ControlPlaneBaseUrl "/billing/vouchers/redeem") -Headers $adminHeaders -Body @{
    tenant_id = $tenantId
    project_id = $projectId
    wallet_id = $walletId
    currency = "USD"
    voucher_code = $voucherCode
    idempotency_key = "route-proof-redeem-$runId"
    redeemer_user_id = $null
  }
  Assert-True ($redeemResponse.status_code -eq 200) "voucher redeem expected HTTP 200 got $($redeemResponse.status_code)"
  $redeem = $redeemResponse.json.data
  Assert-True ([string]$redeem.status -eq "redeemed") "voucher redeem did not return redeemed"
  Assert-True (-not [bool]$redeem.raw_voucher_code_echoed) "voucher redeem echoed raw code"

  $voucherId = [string]$redeem.voucher_id
  $redemptionId = [string]$redeem.redemption_id
  $creditGrantId = [string]$redeem.credit_grant_id
  $ledgerEntryId = [string]$redeem.ledger_entry_id
  $voucherSql = @"
select jsonb_build_object(
  'issue_row', exists (
    select 1 from voucher_issuances
    where id = '$voucherId'::uuid
      and code_hash is not null
      and code_lookup_prefix is not null
      and code_redacted like 'redacted:last4:%'
      and status in ('issued','redeemed')
      and audit_id is not null
  ),
  'redeem_row', exists (
    select 1 from voucher_redemptions
    where id = '$redemptionId'::uuid
      and voucher_id = '$voucherId'::uuid
      and credit_grant_id = '$creditGrantId'::uuid
      and ledger_entry_id = '$ledgerEntryId'::uuid
      and audit_id is not null
      and status = 'redeemed'
  ),
  'attempt_row', exists (
    select 1 from voucher_redeem_attempts
    where tenant_id = '$tenantId'::uuid
      and outcome = 'accepted'
      and code_lookup_prefix is not null
  ),
  'credit_grant_row', exists (
    select 1 from credit_grants
    where id = '$creditGrantId'::uuid
      and source = 'voucher_redeem'
  ),
  'ledger_row', exists (
    select 1 from ledger_entries
    where id = '$ledgerEntryId'::uuid
      and entry_type = 'credit_grant'
      and status = 'confirmed'
  ),
  'audit_rows', (
    select count(*) >= 2 from audit_logs
    where action in ('voucher.issue','voucher.redeem')
      and resource_id in ('$voucherId'::uuid, '$redemptionId'::uuid)
  )
)::text;
"@
  $voucherReadback = Invoke-ComposePsqlJson $voucherSql
  $sections.voucher = [ordered]@{
    issue_route_invoked = $true
    redeem_route_invoked = $true
    issue_readback = [bool]$voucherReadback.issue_row
    redeem_readback = [bool]$voucherReadback.redeem_row
    attempt_readback = [bool]$voucherReadback.attempt_row
    credit_grant_readback = [bool]$voucherReadback.credit_grant_row
    ledger_readback = [bool]$voucherReadback.ledger_row
    audit_readback = [bool]$voucherReadback.audit_rows
    raw_voucher_code_in_artifact = $false
  }
  Assert-True ([bool]$voucherReadback.issue_row) "voucher issue readback missing"
  Assert-True ([bool]$voucherReadback.redeem_row) "voucher redeem readback missing"
  Assert-True ([bool]$voucherReadback.attempt_row) "voucher attempt readback missing"
  Assert-True ([bool]$voucherReadback.credit_grant_row) "voucher credit grant readback missing"
  Assert-True ([bool]$voucherReadback.ledger_row) "voucher ledger readback missing"
  Assert-True ([bool]$voucherReadback.audit_rows) "voucher audit readback missing"

  Write-ProofArtifact -Status "pass" -Sections $sections
} catch {
  $safe = Redact-SecretLikeString $_.Exception.Message
  [void]$script:Blockers.Add($safe)
  Write-ProofArtifact -Status "blocked" -Sections $sections -Blockers @($script:Blockers)
  exit 2
}
