param(
  [string]$ControlPlaneBaseUrl = "http://127.0.0.1:8081",
  [string]$AdminEmail = "admin@example.com",
  [string]$AdminPassword = "local-password",
  [string]$AdminSessionToken = "",
  [string]$ComposeFile = "deploy/docker-compose/docker-compose.yml",
  [int]$TimeoutSeconds = 10,
  [switch]$ContractOnly,
  [switch]$KeepSmokeRows
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$fixturePath = Join-Path $repoRoot "tests\fixtures\control-plane\ledger_adjustment_execute_live_smoke.json"
$dryRunContractPath = Join-Path $repoRoot "tests\fixtures\control-plane\ledger_adjustment_dry_run_contract.json"
$adminSourcePath = Join-Path $repoRoot "apps\control-plane\src\admin.rs"

$script:Failures = @()
$script:Blockers = @()
$script:SensitiveValues = @()
$script:AdminSessionToken = $AdminSessionToken
$script:CreatedLedgerEntryIds = @()
$script:SourceLedgerEntryIds = @()
$script:CreatedAuditLogIds = @()
$script:Fixture = $null
$script:SmokeRunId = ([guid]::NewGuid().ToString("N"))

if ($env:CONTROL_PLANE_BASE_URL) { $ControlPlaneBaseUrl = $env:CONTROL_PLANE_BASE_URL }
if ($env:CONTROL_PLANE_ADMIN_EMAIL) { $AdminEmail = $env:CONTROL_PLANE_ADMIN_EMAIL }
if ($env:CONTROL_PLANE_ADMIN_PASSWORD) { $AdminPassword = $env:CONTROL_PLANE_ADMIN_PASSWORD }
if ($env:CONTROL_PLANE_ADMIN_SESSION_TOKEN) { $script:AdminSessionToken = $env:CONTROL_PLANE_ADMIN_SESSION_TOKEN }
if ($env:COMPOSE_FILE) { $ComposeFile = $env:COMPOSE_FILE }
if ($env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_SMOKE_CONTRACT_ONLY -eq "1") { $ContractOnly = $true }
if ($env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_SMOKE_KEEP_ROWS -eq "1") { $KeepSmokeRows = $true }

Add-Type -AssemblyName System.Net.Http

function Add-SensitiveValue {
  param([AllowNull()][string]$Value)

  if (-not [string]::IsNullOrWhiteSpace($Value)) {
    $script:SensitiveValues += [string]$Value
  }
}

Add-SensitiveValue $AdminPassword
Add-SensitiveValue $script:AdminSessionToken

function Redact-SecretLikeString {
  param([AllowNull()][string]$Text)

  if ($null -eq $Text) {
    return ""
  }

  $redacted = [string]$Text
  foreach ($secret in $script:SensitiveValues) {
    if (-not [string]::IsNullOrEmpty($secret)) {
      $redacted = $redacted.Replace($secret, "[REDACTED]")
    }
  }

  $redacted = $redacted -replace '(?i)("session_token_once"\s*:\s*")[^"]+(")', '$1[REDACTED]$2'
  $redacted = $redacted -replace '(?i)(x-admin-session\s*[:=]\s*)[^\s";,]+', '$1[REDACTED]'
  $redacted = $redacted -replace '(?i)(authorization\s*[:=]\s*bearer\s+)[^\s";,]+', '$1[REDACTED]'
  $redacted = $redacted -replace '(?i)(Bearer\s+)[A-Za-z0-9._~+/\-]+=*', '$1[REDACTED]'
  $redacted = $redacted -replace '(?i)((?:password|passwd|secret|token|session|api[_-]?key|access[_-]?key|private[_-]?key|provider[_-]?key)\s*[:=]\s*)[^\s";,}]+', '$1[REDACTED]'
  $redacted = $redacted -replace 'sess_[A-Za-z0-9._~+/\-=]+', '[REDACTED]'
  $redacted = $redacted -replace 'sk-[A-Za-z0-9._~+\-/=]+', '[REDACTED]'
  return $redacted
}

function Write-SafeHost {
  param([AllowNull()][string]$Text)

  Write-Host (Redact-SecretLikeString $Text)
}

function Add-Failure {
  param([Parameter(Mandatory = $true)][string]$Message)

  $safe = Redact-SecretLikeString $Message
  $script:Failures += $safe
  Write-SafeHost $safe
}

function Add-Blocker {
  param([Parameter(Mandatory = $true)][string]$Message)

  $safe = Redact-SecretLikeString $Message
  $script:Blockers += $safe
  Write-SafeHost "[BLOCKED] $safe"
}

function Check {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][scriptblock]$Action
  )

  try {
    & $Action
    Write-SafeHost "[OK] $Name"
  } catch {
    Add-Failure "[FAIL] $Name - $($_.Exception.Message)"
  }
}

function Check-Blocking {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][scriptblock]$Action
  )

  try {
    & $Action
    Write-SafeHost "[OK] $Name"
  } catch {
    Add-Blocker "$Name - $($_.Exception.Message)"
  }
}

function Exit-WithFailuresOrBlockers {
  if ($script:Failures.Count -gt 0) {
    Write-SafeHost ""
    Write-SafeHost "Control Plane ledger adjustment execute smoke failed:"
    foreach ($failure in $script:Failures) {
      Write-SafeHost $failure
    }
    exit 1
  }

  if ($script:Blockers.Count -gt 0) {
    Write-SafeHost ""
    Write-SafeHost "Control Plane ledger adjustment execute smoke is externally blocked:"
    foreach ($blocker in $script:Blockers) {
      Write-SafeHost $blocker
    }
    exit 2
  }
}

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path $Path)) {
    throw "missing $Path"
  }

  try {
    return Get-Content -Path $Path -Raw | ConvertFrom-Json
  } catch {
    throw "invalid JSON at $Path`: $($_.Exception.Message)"
  }
}

function Read-Json {
  param([Parameter(Mandatory = $true)][string]$Content)

  try {
    return $Content | ConvertFrom-Json
  } catch {
    throw "expected JSON response, got: $(Redact-SecretLikeString $Content)"
  }
}

function Assert-Equal {
  param(
    [Parameter(Mandatory = $true)][object]$Actual,
    [Parameter(Mandatory = $true)][object]$Expected,
    [Parameter(Mandatory = $true)][string]$Message
  )

  if ([string]$Actual -ne [string]$Expected) {
    throw "${Message}: expected '$Expected', got '$Actual'"
  }
}

function Assert-True {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Message
  )

  if (-not $Condition) {
    throw $Message
  }
}

function Assert-StatusAny {
  param(
    [Parameter(Mandatory = $true)]$Response,
    [Parameter(Mandatory = $true)][int[]]$Expected
  )

  if ($Expected -notcontains [int]$Response.StatusCode) {
    throw "expected HTTP $($Expected -join '/'), got HTTP $($Response.StatusCode): $(Redact-SecretLikeString $Response.Content)"
  }
}

function Assert-SecretSafeContent {
  param(
    [Parameter(Mandatory = $true)][string]$Content,
    [Parameter(Mandatory = $true)][string]$Context
  )

  foreach ($forbidden in @(
      "idempotency_key",
      "usage_snapshot",
      "policy_snapshot",
      "encrypted_secret",
      "secret_fingerprint",
      "provider_key",
      "Authorization",
      "Bearer ",
      "sk-",
      "raw ledger material",
      "never-return"
    )) {
    if ($Content.Contains($forbidden)) {
      throw "$Context leaked forbidden material marker '$forbidden'"
    }
  }
}

function Join-Url {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$Path
  )

  $normalizedPath = $Path
  if (-not $normalizedPath.StartsWith("/")) {
    $normalizedPath = "/$normalizedPath"
  }

  return $BaseUrl.TrimEnd("/") + $normalizedPath
}

function Invoke-ControlPlaneRequest {
  param(
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Path,
    [object]$Body = $null,
    [string]$SessionToken = $script:AdminSessionToken,
    [int]$TimeoutSec = $TimeoutSeconds
  )

  if (($Method -eq "GET" -or $Method -eq "HEAD") -and $null -ne $Body) {
    throw "$Method requests must not include a JSON body"
  }

  $client = New-Object System.Net.Http.HttpClient
  $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
  $request = New-Object System.Net.Http.HttpRequestMessage -ArgumentList (New-Object System.Net.Http.HttpMethod -ArgumentList $Method), (Join-Url $ControlPlaneBaseUrl $Path)
  if (-not [string]::IsNullOrWhiteSpace($SessionToken)) {
    [void]$request.Headers.TryAddWithoutValidation("X-Admin-Session", $SessionToken)
  }

  if ($null -ne $Body) {
    $json = $Body | ConvertTo-Json -Depth 32 -Compress
    $content = New-Object System.Net.Http.StringContent -ArgumentList $json
    $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/json")
    $request.Content = $content
  }

  $response = $null
  try {
    $response = $client.SendAsync($request).GetAwaiter().GetResult()
    return [PSCustomObject]@{
      StatusCode = [int]$response.StatusCode
      Content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    }
  } catch [System.Threading.Tasks.TaskCanceledException] {
    throw "request timed out after $TimeoutSec seconds"
  } finally {
    if ($response) { $response.Dispose() }
    $request.Dispose()
    $client.Dispose()
  }
}

function Initialize-AdminSession {
  if (-not [string]::IsNullOrWhiteSpace($script:AdminSessionToken)) {
    Add-SensitiveValue $script:AdminSessionToken
    return
  }

  $response = Invoke-ControlPlaneRequest -Method POST -Path "/admin/auth/login" -Body @{
    email = $AdminEmail
    password = $AdminPassword
  } -SessionToken ""
  Assert-StatusAny $response @(200)
  $payload = Read-Json $response.Content
  $token = [string]$payload.data.session_token_once
  if ([string]::IsNullOrWhiteSpace($token)) {
    throw "login response did not include data.session_token_once"
  }

  $script:AdminSessionToken = $token
  Add-SensitiveValue $token
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
      -c $Sql

    if ($LASTEXITCODE -ne 0) {
      throw "psql failed with exit code $LASTEXITCODE"
    }

    return (($output | Out-String).Trim())
  } finally {
    Pop-Location
  }
}

function Invoke-ComposePsqlJson {
  param([Parameter(Mandatory = $true)][string]$Sql)

  $content = Invoke-ComposePsql $Sql
  if ([string]::IsNullOrWhiteSpace($content)) {
    throw "psql returned no JSON"
  }
  return $content | ConvertFrom-Json
}

function Escape-SqlLiteral {
  param([Parameter(Mandatory = $true)][string]$Value)

  return $Value.Replace("'", "''")
}

function New-SmokeGuid {
  return [guid]::NewGuid().ToString()
}

function UuidListSql {
  param([string[]]$Ids)

  $filtered = @($Ids | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($filtered.Count -eq 0) {
    return "array[]::uuid[]"
  }

  $items = @($filtered | ForEach-Object { "'$($_)'::uuid" })
  return "array[$($items -join ',')]"
}

function Assert-SmokeFixture {
  param([Parameter(Mandatory = $true)]$Fixture)

  Assert-Equal $Fixture.scenario "control_plane_ledger_adjustment_execute_live_postgres_smoke" "fixture scenario"
  Assert-Equal $Fixture.endpoint.method "POST" "fixture endpoint method"
  Assert-Equal $Fixture.endpoint.path "/admin/ledger/adjustments/dry-run" "fixture endpoint path"
  Assert-Equal $Fixture.endpoint.required_permission "billing_adjust" "fixture required permission"
  Assert-Equal $Fixture.endpoint.execute_mode "execute" "fixture execute mode"
  Assert-Equal $Fixture.external_blocked_exit_code 2 "fixture blocked exit code"
  Assert-True ($Fixture.default_tests_require_live_db -eq $false) "fixture must state default tests do not require live DB"
  Assert-True ($Fixture.transaction_evidence.audit_resource_id_matches_ledger_entry_id -eq $true) "fixture must require audit resource linkage"
  Assert-True ($Fixture.transaction_evidence.idempotent_replay_does_not_increase_ledger_or_audit_count -eq $true) "fixture must require idempotent no-op evidence"
  Assert-True ($Fixture.transaction_evidence.over_remaining_refusal_does_not_increase_ledger_or_audit_count -eq $true) "fixture must require refusal no-op evidence"
  Assert-True ($Fixture.blocked_contract.blocked_is_not_success -eq $true) "fixture must require blocked != success"
}

function Assert-S4ContractFixture {
  param([Parameter(Mandatory = $true)]$Contract)

  Assert-Equal $Contract.execute.mode "execute" "S4 fixture execute mode"
  Assert-Equal $Contract.execute.writer "control_plane_transactional_admin_ledger_adjustment_writer" "S4 fixture writer"
  Assert-True ($Contract.execute.ledger_write_on_applied -eq $true) "S4 fixture applied ledger write"
  Assert-True ($Contract.execute.audit_log_write_on_applied -eq $true) "S4 fixture applied audit write"
  Assert-True ($Contract.execute.business_and_success_audit_share_transaction -eq $true) "S4 fixture transactional audit"
  Assert-True ($Contract.execute.audit_insert_failure_rolls_back_ledger_write -eq $true) "S4 fixture audit rollback"
  Assert-True ($Contract.execute.idempotent_replay_does_not_write_ledger_or_audit -eq $true) "S4 fixture idempotent no-op"
  Assert-True ($Contract.execute_contract.error_code -eq "future_writer_required") "S4 execute_contract must remain blocked"
}

function Assert-AdminSourceMarkers {
  if (-not (Test-Path $adminSourcePath)) {
    throw "missing apps\control-plane\src\admin.rs"
  }

  $source = Get-Content -Path $adminSourcePath -Raw
  foreach ($needle in @(
      "execute_ledger_adjustment",
      ".begin()",
      "get_ledger_entry_for_adjustment_execute_tx",
      "get_confirmed_refund_credit_summary_for_update_tx",
      "get_ledger_adjustment_dedupe_entry_for_update_tx",
      "insert_ledger_adjustment_entry_tx",
      "insert_admin_audit_log_tx",
      "tx.commit()",
      "rollback_ledger_adjustment_execute_tx"
    )) {
    if (-not $source.Contains($needle)) {
      throw "admin source missing transactional marker '$needle'"
    }
  }
}

function Assert-LiveEnvironmentAvailable {
  try {
    $docker = Get-DockerCommand
    $services = & $docker compose -f $ComposeFile ps --status running --services 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "docker compose ps failed: $(Redact-SecretLikeString (($services | Out-String).Trim()))"
    }
  } catch {
    throw "docker compose is unavailable or compose file cannot be inspected: $($_.Exception.Message)"
  }

  $serviceText = ($services | Out-String)
  foreach ($service in @("postgres", "control-plane")) {
    if ($serviceText -notmatch "(?m)^$service$") {
      throw "compose service '$service' is not running; start deploy/docker-compose/docker-compose.yml before live smoke"
    }
  }

  [void](Invoke-ComposePsql "select 1;")
  $probe = Invoke-ControlPlaneRequest -Method GET -Path "/admin/auth/me" -SessionToken ""
  Assert-StatusAny $probe @(200, 401, 403)
}

function Assert-MigratedSchemaAndSeed {
  $schema = Invoke-ComposePsqlJson @"
select json_build_object(
  'ledger_entries', to_regclass('public.ledger_entries') is not null,
  'audit_logs', to_regclass('public.audit_logs') is not null,
  'wallets', to_regclass('public.wallets') is not null,
  'tenant_count', (select count(*) from tenants where id = '00000000-0000-0000-0000-000000000001'),
  'project_count', (select count(*) from projects where tenant_id = '00000000-0000-0000-0000-000000000001' and id = '00000000-0000-0000-0000-000000000020'),
  'wallet_count', (select count(*) from wallets where tenant_id = '00000000-0000-0000-0000-000000000001' and id = '00000000-0000-0000-0000-000000000040' and status in ('active', 'suspended')),
  'admin_count', (select count(*) from users where tenant_id = '00000000-0000-0000-0000-000000000001' and email = 'admin@example.com' and status = 'active')
)::text;
"@

  foreach ($flag in @("ledger_entries", "audit_logs", "wallets")) {
    Assert-True ([bool]$schema.$flag) "migrated schema missing $flag"
  }
  Assert-True ([int]$schema.tenant_count -ge 1) "default tenant seed missing"
  Assert-True ([int]$schema.project_count -ge 1) "default project seed missing"
  Assert-True ([int]$schema.wallet_count -ge 1) "default wallet seed missing"
  Assert-True ([int]$schema.admin_count -ge 1) "dev admin seed missing"
}

function New-RelatedDebit {
  param(
    [Parameter(Mandatory = $true)][string]$Amount,
    [Parameter(Mandatory = $true)][string]$Label
  )

  $entryId = New-SmokeGuid
  $idem = "control-plane-ledger-adjustment-execute-smoke:$($script:SmokeRunId):$Label"
  $metadata = "{""smoke"":""control_plane_ledger_adjustment_execute_live_smoke"",""run_id"":""$($script:SmokeRunId)"",""label"":""$Label""}"
  $safeIdem = Escape-SqlLiteral $idem
  $safeMetadata = Escape-SqlLiteral $metadata
  [void](Invoke-ComposePsql @"
insert into ledger_entries (
  id, tenant_id, project_id, wallet_id, entry_type, amount, currency, status, idempotency_key, metadata
)
values (
  '$entryId',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000020',
  '00000000-0000-0000-0000-000000000040',
  'settle',
  $Amount::numeric,
  'USD',
  'confirmed',
  '$safeIdem',
  '$safeMetadata'::jsonb
);
"@)

  $script:SourceLedgerEntryIds += $entryId
  return $entryId
}

function New-RefundExecuteBody {
  param(
    [Parameter(Mandatory = $true)][string]$RelatedLedgerEntryId,
    [Parameter(Mandatory = $true)][string]$Amount,
    [string]$Reason = "live smoke refund"
  )

  return [ordered]@{
    mode = "execute"
    operation = "refund"
    amount = $Amount
    currency = "USD"
    related_ledger_entry_id = $RelatedLedgerEntryId
    reason = $Reason
  }
}

function Invoke-LedgerAdjustmentExecute {
  param([Parameter(Mandatory = $true)]$Body)

  $response = Invoke-ControlPlaneRequest -Method POST -Path "/admin/ledger/adjustments/dry-run" -Body $Body
  Assert-SecretSafeContent -Content $response.Content -Context "ledger adjustment execute response"
  return $response
}

function Get-CreditAndAuditEvidence {
  param([Parameter(Mandatory = $true)][string]$SourceLedgerEntryId)

  return Invoke-ComposePsqlJson @"
select json_build_object(
  'credit_count', (
    select count(*)
    from ledger_entries
    where tenant_id = '00000000-0000-0000-0000-000000000001'
      and related_ledger_entry_id = '$SourceLedgerEntryId'
      and entry_type in ('refund', 'adjust')
      and status = 'confirmed'
      and amount > 0
  ),
  'audit_count', (
    select count(*)
    from audit_logs al
    join ledger_entries le on le.tenant_id = al.tenant_id and le.id = al.resource_id
    where al.tenant_id = '00000000-0000-0000-0000-000000000001'
      and al.resource_type = 'ledger_entry'
      and al.action in ('ledger.refund', 'ledger.adjust')
      and al.metadata->>'ledger_adjustment_execute' = 'true'
      and le.related_ledger_entry_id = '$SourceLedgerEntryId'
  )
)::text;
"@
}

function Assert-AppliedExecuteResponse {
  param(
    [Parameter(Mandatory = $true)]$Response,
    [Parameter(Mandatory = $true)][string]$SourceLedgerEntryId
  )

  Assert-StatusAny $Response @(201)
  $payload = Read-Json $Response.Content
  $data = $payload.data
  Assert-Equal $data.mode "execute" "execute apply mode"
  Assert-Equal $data.outcome "applied" "execute apply outcome"
  Assert-True ($data.ledger_write -eq $true) "execute apply must write ledger"
  Assert-True ($data.audit_log_write -eq $true) "execute apply must write audit"
  Assert-True ($data.business_and_success_audit_share_transaction -eq $true) "execute apply must report same transaction"
  Assert-True ($data.audit_insert_failure_rolls_back_ledger_write -eq $true) "execute apply must report audit rollback"
  Assert-True ($data.dedupe_material_echoed -eq $false) "execute apply must not echo dedupe material"
  Assert-Equal $data.transaction_contract.writer "control_plane_transactional_admin_ledger_adjustment_writer" "execute writer"
  Assert-True ($data.transaction_contract.unbounded_scan_allowed -eq $false) "execute transaction must remain bounded"

  $ledgerEntryId = [string]$data.ledger_entry.id
  $auditLogId = [string]$data.audit_log_id
  if ([string]::IsNullOrWhiteSpace($ledgerEntryId)) {
    throw "execute apply did not return ledger_entry.id"
  }
  if ([string]::IsNullOrWhiteSpace($auditLogId)) {
    throw "execute apply did not return audit_log_id"
  }

  $script:CreatedLedgerEntryIds += $ledgerEntryId
  $script:CreatedAuditLogIds += $auditLogId

  $safeAuditId = Escape-SqlLiteral $auditLogId
  $safeLedgerId = Escape-SqlLiteral $ledgerEntryId
  $safeSourceId = Escape-SqlLiteral $SourceLedgerEntryId
  $evidence = Invoke-ComposePsqlJson @"
select json_build_object(
  'ledger_count', (
    select count(*)
    from ledger_entries
    where tenant_id = '00000000-0000-0000-0000-000000000001'
      and id = '$safeLedgerId'
      and related_ledger_entry_id = '$safeSourceId'
      and entry_type = 'refund'
      and status = 'confirmed'
      and amount > 0
  ),
  'audit_count', (
    select count(*)
    from audit_logs
    where tenant_id = '00000000-0000-0000-0000-000000000001'
      and id = '$safeAuditId'
      and action = 'ledger.refund'
      and resource_type = 'ledger_entry'
      and resource_id = '$safeLedgerId'
      and metadata->>'transactional_audit' = 'true'
      and metadata->>'ledger_adjustment_execute' = 'true'
      and metadata->>'dedupe_material_echoed' = 'false'
  ),
  'audit_after_snapshot', (
    select after_snapshot
    from audit_logs
    where tenant_id = '00000000-0000-0000-0000-000000000001'
      and id = '$safeAuditId'
  )
)::text;
"@

  Assert-Equal $evidence.ledger_count 1 "execute apply ledger row evidence"
  Assert-Equal $evidence.audit_count 1 "execute apply audit same-resource evidence"
  $auditSnapshot = $evidence.audit_after_snapshot | ConvertTo-Json -Depth 16 -Compress
  Assert-SecretSafeContent -Content $auditSnapshot -Context "ledger adjustment execute audit after_snapshot"
}

function Assert-IdempotentReplay {
  param(
    [Parameter(Mandatory = $true)][string]$SourceLedgerEntryId,
    [Parameter(Mandatory = $true)]$Body
  )

  $before = Get-CreditAndAuditEvidence -SourceLedgerEntryId $SourceLedgerEntryId
  $response = Invoke-LedgerAdjustmentExecute -Body $Body
  Assert-StatusAny $response @(200)
  $payload = Read-Json $response.Content
  $data = $payload.data
  Assert-Equal $data.mode "execute" "idempotent replay mode"
  Assert-Equal $data.outcome "idempotent" "idempotent replay outcome"
  Assert-True ($data.ledger_write -eq $false) "idempotent replay must not write ledger"
  Assert-True ($data.audit_log_write -eq $false) "idempotent replay must not write audit"
  Assert-True ($data.dedupe_material_echoed -eq $false) "idempotent replay must not echo dedupe material"
  $after = Get-CreditAndAuditEvidence -SourceLedgerEntryId $SourceLedgerEntryId
  Assert-Equal $after.credit_count $before.credit_count "idempotent replay must not increase ledger credits"
  Assert-Equal $after.audit_count $before.audit_count "idempotent replay must not increase success audits"
}

function Assert-OverRemainingRefusal {
  param(
    [Parameter(Mandatory = $true)][string]$SourceLedgerEntryId
  )

  $before = Get-CreditAndAuditEvidence -SourceLedgerEntryId $SourceLedgerEntryId
  $response = Invoke-LedgerAdjustmentExecute -Body (New-RefundExecuteBody -RelatedLedgerEntryId $SourceLedgerEntryId -Amount "0.11000000" -Reason "live smoke over remaining")
  Assert-StatusAny $response @(400)
  $payload = Read-Json $response.Content
  Assert-Equal $payload.error.code "bad_request" "over remaining error code"
  if (-not ([string]$payload.error.message).Contains("remaining refundable amount")) {
    throw "over remaining refusal did not explain remaining refundable amount"
  }
  $after = Get-CreditAndAuditEvidence -SourceLedgerEntryId $SourceLedgerEntryId
  Assert-Equal $after.credit_count $before.credit_count "over remaining refusal must not increase ledger credits"
  Assert-Equal $after.audit_count $before.audit_count "over remaining refusal must not increase success audits"
}

function Invoke-ExecuteJob {
  param(
    [Parameter(Mandatory = $true)][object]$Body,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $bodyJson = $Body | ConvertTo-Json -Depth 32 -Compress
  return Start-Job -Name $Name -ArgumentList $ControlPlaneBaseUrl, $script:AdminSessionToken, $bodyJson, $TimeoutSeconds -ScriptBlock {
    param($BaseUrl, $SessionToken, $BodyJson, $Timeout)

    Add-Type -AssemblyName System.Net.Http
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds($Timeout)
    $request = New-Object System.Net.Http.HttpRequestMessage -ArgumentList (New-Object System.Net.Http.HttpMethod -ArgumentList "POST"), ($BaseUrl.TrimEnd("/") + "/admin/ledger/adjustments/dry-run")
    [void]$request.Headers.TryAddWithoutValidation("X-Admin-Session", $SessionToken)
    $content = New-Object System.Net.Http.StringContent -ArgumentList $BodyJson
    $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/json")
    $request.Content = $content
    $response = $null
    try {
      $response = $client.SendAsync($request).GetAwaiter().GetResult()
      [PSCustomObject]@{
        StatusCode = [int]$response.StatusCode
        Content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
      }
    } catch {
      [PSCustomObject]@{
        StatusCode = 0
        Content = $_.Exception.Message
      }
    } finally {
      if ($response) { $response.Dispose() }
      $request.Dispose()
      $client.Dispose()
    }
  }
}

function Assert-ConcurrentRefundRace {
  $sourceId = New-RelatedDebit -Amount "-0.25000000" -Label "race-source"
  $first = New-RefundExecuteBody -RelatedLedgerEntryId $sourceId -Amount "0.15000000" -Reason "live smoke race first"
  $second = New-RefundExecuteBody -RelatedLedgerEntryId $sourceId -Amount "0.15100000" -Reason "live smoke race second"
  $jobs = @(
    (Invoke-ExecuteJob -Body $first -Name "ledger-adjustment-race-first"),
    (Invoke-ExecuteJob -Body $second -Name "ledger-adjustment-race-second")
  )

  try {
    [void](Wait-Job -Job $jobs -Timeout ($TimeoutSeconds + 10))
    $running = @($jobs | Where-Object { $_.State -notin @("Completed", "Failed", "Stopped") })
    if ($running.Count -gt 0) {
      Stop-Job -Job $running -Force
      throw "concurrent execute jobs did not finish before timeout"
    }

    $results = @($jobs | ForEach-Object { Receive-Job -Job $_ })
    foreach ($result in $results) {
      Assert-SecretSafeContent -Content ([string]$result.Content) -Context "concurrent ledger adjustment execute response"
    }

    $statuses = @($results | ForEach-Object { [int]$_.StatusCode } | Sort-Object)
    Assert-Equal ($statuses -join ",") "201,400" "concurrent refund race statuses"

    $evidence = Get-CreditAndAuditEvidence -SourceLedgerEntryId $sourceId
    Assert-Equal $evidence.credit_count 1 "concurrent race must leave one confirmed credit"
    Assert-Equal $evidence.audit_count 1 "concurrent race must leave one success audit"

    foreach ($result in $results) {
      if ([int]$result.StatusCode -eq 201) {
        $payload = Read-Json $result.Content
        $script:CreatedLedgerEntryIds += [string]$payload.data.ledger_entry.id
        $script:CreatedAuditLogIds += [string]$payload.data.audit_log_id
      }
    }
  } finally {
    Remove-Job -Job $jobs -Force -ErrorAction SilentlyContinue
  }
}

function Remove-SmokeRows {
  if ($KeepSmokeRows) {
    Write-SafeHost "[INFO] Keeping smoke rows because -KeepSmokeRows was supplied."
    return
  }

  $ledgerIds = @($script:CreatedLedgerEntryIds + $script:SourceLedgerEntryIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
  $sourceIds = @($script:SourceLedgerEntryIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
  $auditIds = @($script:CreatedAuditLogIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
  if ($ledgerIds.Count -eq 0 -and $sourceIds.Count -eq 0 -and $auditIds.Count -eq 0) {
    return
  }

  $ledgerSql = UuidListSql $ledgerIds
  $sourceSql = UuidListSql $sourceIds
  $auditSql = UuidListSql $auditIds
  [void](Invoke-ComposePsql @"
delete from audit_logs
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and (id = any($auditSql) or resource_id = any($ledgerSql));

delete from ledger_entries
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and (id = any($ledgerSql) or related_ledger_entry_id = any($sourceSql));
"@)
}

Push-Location $repoRoot
try {
  Check "ledger adjustment execute live smoke fixture contract" {
    $script:Fixture = Read-JsonFile $fixturePath
    Assert-SmokeFixture $script:Fixture
  }

  Check "S4 execute fixture remains transactional" {
    Assert-S4ContractFixture (Read-JsonFile $dryRunContractPath)
  }

  Check "control-plane source contains transactional execute boundary" {
    Assert-AdminSourceMarkers
  }

  if ($ContractOnly) {
    Exit-WithFailuresOrBlockers
    Write-SafeHost "Control Plane ledger adjustment execute smoke contract-only checks passed; live DB was not required."
    exit 0
  }

  Check-Blocking "live Docker compose control-plane/postgres availability" {
    Assert-LiveEnvironmentAvailable
  }
  Exit-WithFailuresOrBlockers

  Check-Blocking "live migrated schema and dev seed availability" {
    Assert-MigratedSchemaAndSeed
  }
  Exit-WithFailuresOrBlockers

  Check "control-plane admin login for BillingAdjust smoke" {
    Initialize-AdminSession
  }

  $sourceId = $null
  $executeBody = $null
  Check "seed related confirmed debit in live Postgres" {
    $sourceId = New-RelatedDebit -Amount "-0.25000000" -Label "apply-source"
    Set-Variable -Name sourceId -Value $sourceId -Scope Script
    $executeBody = New-RefundExecuteBody -RelatedLedgerEntryId $sourceId -Amount "0.15000000"
    Set-Variable -Name executeBody -Value $executeBody -Scope Script
  }

  Check "execute apply writes ledger and success audit" {
    $response = Invoke-LedgerAdjustmentExecute -Body $script:executeBody
    Assert-AppliedExecuteResponse -Response $response -SourceLedgerEntryId $script:sourceId
  }

  Check "execute idempotent replay does not write ledger or audit" {
    Assert-IdempotentReplay -SourceLedgerEntryId $script:sourceId -Body $script:executeBody
  }

  Check "execute refund over remaining refuses without ledger or audit" {
    Assert-OverRemainingRefusal -SourceLedgerEntryId $script:sourceId
  }

  Check "concurrent execute refund race leaves one applied refund" {
    Assert-ConcurrentRefundRace
  }

  Exit-WithFailuresOrBlockers
  Write-SafeHost "Control Plane ledger adjustment execute live Postgres smoke passed."
} finally {
  try {
    if (-not $ContractOnly) {
      Remove-SmokeRows
    }
  } catch {
    Add-Failure "[FAIL] cleanup smoke rows - $($_.Exception.Message)"
    Exit-WithFailuresOrBlockers
  }
  Pop-Location
}
