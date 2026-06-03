param(
  [string]$GatewayBaseUrl = "http://127.0.0.1:8080",
  [string]$GatewayAuthToken = "dev_test_key_123456789",
  [string]$Model = "mock-gpt-4o-mini",
  [string]$MissingRouteModel = "",
  [string]$ComposeFile = "deploy/docker-compose/docker-compose.yml",
  [int]$TimeoutSeconds = 8,
  [int]$DbPollSeconds = 10,
  [switch]$SkipComposePs,
  [switch]$StrictGatewayRouting
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$script:Failures = @()
$script:Pending = @()
$script:ChatRequestHash = $null
$script:ChatLogRows = @()

if ($env:GATEWAY_BASE_URL) { $GatewayBaseUrl = $env:GATEWAY_BASE_URL }
if ($env:GATEWAY_AUTH_TOKEN) { $GatewayAuthToken = $env:GATEWAY_AUTH_TOKEN }
if ($env:SMOKE_MODEL) { $Model = $env:SMOKE_MODEL }
if ($env:MISSING_ROUTE_MODEL) { $MissingRouteModel = $env:MISSING_ROUTE_MODEL }
if ($env:COMPOSE_FILE) { $ComposeFile = $env:COMPOSE_FILE }
if ($env:STRICT_GATEWAY_ROUTING -eq "1") { $StrictGatewayRouting = $true }

Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Security

function Join-Url {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$Path
  )

  return $BaseUrl.TrimEnd("/") + $Path
}

function ConvertTo-JsonString {
  param([Parameter(Mandatory = $true)][string]$Value)

  return ($Value | ConvertTo-Json -Compress)
}

function New-ChatBodyJson {
  param(
    [Parameter(Mandatory = $true)][string]$RequestModel,
    [Parameter(Mandatory = $true)][string]$Content
  )

  return '{"model":' + (ConvertTo-JsonString $RequestModel) + ',"messages":[{"role":"user","content":' + (ConvertTo-JsonString $Content) + '}],"stream":false}'
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

function Invoke-GatewayRequest {
  param(
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Uri,
    [string]$JsonBody = $null,
    [hashtable]$Headers = @{},
    [int]$TimeoutSec = $TimeoutSeconds
  )

  $client = New-Object System.Net.Http.HttpClient
  $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
  $request = New-Object System.Net.Http.HttpRequestMessage -ArgumentList (New-Object System.Net.Http.HttpMethod -ArgumentList $Method), $Uri

  foreach ($key in $Headers.Keys) {
    [void]$request.Headers.TryAddWithoutValidation($key, [string]$Headers[$key])
  }

  if (($Method -eq "GET" -or $Method -eq "HEAD") -and -not [string]::IsNullOrEmpty($JsonBody)) {
    throw "$Method requests must not include a JSON body"
  }

  if (-not [string]::IsNullOrEmpty($JsonBody)) {
    $content = New-Object System.Net.Http.StringContent -ArgumentList $JsonBody
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
  } finally {
    if ($response) { $response.Dispose() }
    $request.Dispose()
    $client.Dispose()
  }
}

function Assert-Status {
  param(
    [Parameter(Mandatory = $true)]$Response,
    [Parameter(Mandatory = $true)][int]$Expected
  )

  if ($Response.StatusCode -ne $Expected) {
    throw "expected HTTP $Expected, got HTTP $($Response.StatusCode): $($Response.Content)"
  }
}

function Assert-Contains {
  param(
    [Parameter(Mandatory = $true)][string]$Content,
    [Parameter(Mandatory = $true)][string]$Needle
  )

  if (-not $Content.Contains($Needle)) {
    throw "response does not contain '$Needle'"
  }
}

function Read-Json {
  param([Parameter(Mandatory = $true)][string]$Content)

  try {
    return $Content | ConvertFrom-Json
  } catch {
    throw "expected JSON response, got: $Content"
  }
}

function Test-ModelListContains {
  param(
    [Parameter(Mandatory = $true)]$Payload,
    [Parameter(Mandatory = $true)][string]$ExpectedModel
  )

  foreach ($modelEntry in @($Payload.data)) {
    if ($modelEntry.id -eq $ExpectedModel) {
      return $true
    }
  }

  return $false
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
      -c $Sql

    if ($LASTEXITCODE -ne 0) {
      throw "psql failed with exit code $LASTEXITCODE"
    }

    return (($output | Out-String).Trim())
  } finally {
    Pop-Location
  }
}

function Get-RequestLogRowsByHash {
  param([Parameter(Mandatory = $true)][string]$RequestHash)

  $hash = Escape-SqlLiteral $RequestHash
  $sql = @"
select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb)::text
from (
  select
    rl.id::text as request_id,
    rl.status as request_status,
    rl.http_status as request_http_status,
    rl.requested_model,
    rl.canonical_model_id::text as canonical_model_id,
    rl.upstream_model as request_upstream_model,
    rl.resolved_provider_id::text as resolved_provider_id,
    rl.resolved_channel_id::text as resolved_channel_id,
    rl.route_policy_version,
    pa.id::text as attempt_id,
    pa.status as attempt_status,
    pa.http_status as attempt_http_status,
    pa.provider_id::text as attempt_provider_id,
    pa.channel_id::text as attempt_channel_id,
    pa.upstream_model
  from request_logs rl
  left join provider_attempts pa
    on pa.tenant_id = rl.tenant_id
   and pa.request_id = rl.id
  where rl.request_body_hash = '$hash'
  order by rl.created_at desc, pa.attempt_no asc
  limit 5
) t;
"@

  $json = Invoke-ComposePsql $sql
  if ([string]::IsNullOrWhiteSpace($json)) {
    return @()
  }

  return @($json | ConvertFrom-Json)
}

function Wait-RequestLogRowsByHash {
  param([Parameter(Mandatory = $true)][string]$RequestHash)

  $deadline = (Get-Date).AddSeconds($DbPollSeconds)
  while ((Get-Date) -lt $deadline) {
    $rows = @(Get-RequestLogRowsByHash $RequestHash)
    if ($rows.Count -gt 0) {
      return $rows
    }

    Start-Sleep -Seconds 1
  }

  throw "request_logs row with request_body_hash=$RequestHash was not observed within $DbPollSeconds seconds"
}

function Check {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][scriptblock]$Action
  )

  try {
    & $Action
    Write-Host "[OK] $Name"
  } catch {
    $message = "[FAIL] $Name - $($_.Exception.Message)"
    $script:Failures += $message
    Write-Host $message
  }
}

function Report-PendingOrFail {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Message,
    [switch]$Strict
  )

  if ($Strict) {
    $failure = "[FAIL] $Name - $Message"
    $script:Failures += $failure
    Write-Host $failure
    return
  }

  $pending = "[PENDING] $Name - $Message"
  $script:Pending += $pending
  Write-Host $pending
}

function Check-ResolvedRoutingIds {
  $name = "gateway chat logs resolved routing ids"
  $rows = @($script:ChatLogRows)
  if ($rows.Count -eq 0) {
    $message = "[FAIL] $name - chat request log prerequisite did not pass"
    $script:Failures += $message
    Write-Host $message
    return
  }

  $requestRow = $rows[0]
  $attemptRows = @($rows | Where-Object { $_.attempt_id })
  $missing = @()

  if (-not $requestRow.canonical_model_id) { $missing += "request_logs.canonical_model_id" }
  if (-not $requestRow.request_upstream_model) { $missing += "request_logs.upstream_model" }
  if (-not $requestRow.resolved_provider_id) { $missing += "request_logs.resolved_provider_id" }
  if (-not $requestRow.resolved_channel_id) { $missing += "request_logs.resolved_channel_id" }
  if ($requestRow.route_policy_version -ne "gateway_db_route_v1") { $missing += "request_logs.route_policy_version" }
  if ($attemptRows.Count -eq 0) {
    $missing += "provider_attempts row"
  } else {
    if (-not $attemptRows[0].attempt_provider_id) { $missing += "provider_attempts.provider_id" }
    if (-not $attemptRows[0].attempt_channel_id) { $missing += "provider_attempts.channel_id" }
    if (-not $attemptRows[0].upstream_model) { $missing += "provider_attempts.upstream_model" }
    if ($attemptRows[0].upstream_model -and $requestRow.request_upstream_model -and $attemptRows[0].upstream_model -ne $requestRow.request_upstream_model) {
      $missing += "provider_attempts.upstream_model mismatch"
    }
  }

  if ($missing.Count -gt 0) {
    Report-PendingOrFail -Name $name -Message ("routing is not writing resolved ids yet: " + ($missing -join ", ")) -Strict:$StrictGatewayRouting
    return
  }

  Write-Host "[OK] $name"
}

function Check-MissingRouteBehavior {
  param(
    [Parameter(Mandatory = $true)][hashtable]$Headers,
    [Parameter(Mandatory = $true)][string]$RequestModel
  )

  $name = "gateway missing route behavior"
  try {
    $body = New-ChatBodyJson -RequestModel $RequestModel -Content "gateway routing smoke missing route"
    $response = Invoke-GatewayRequest -Method POST -Uri (Join-Url $GatewayBaseUrl "/v1/chat/completions") -Headers $Headers -JsonBody $body

    if ($response.StatusCode -eq 404) {
      Assert-Contains $response.Content "error"
      if ($response.Content -notmatch "route|model|not_found") {
        throw "missing route response should identify route/model not_found semantics: $($response.Content)"
      }
      Write-Host "[OK] $name"
      return
    }

    if ($response.StatusCode -eq 200) {
      Report-PendingOrFail -Name $name -Message "Gateway forwarded unknown model '$RequestModel' instead of rejecting a missing route; strict routing is not wired yet." -Strict:$StrictGatewayRouting
      return
    }

    throw "expected HTTP 404 for missing route or HTTP 200 pending current static forwarding, got HTTP $($response.StatusCode): $($response.Content)"
  } catch {
    $message = "[FAIL] $name - $($_.Exception.Message)"
    $script:Failures += $message
    Write-Host $message
  }
}

$suffix = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
if ([string]::IsNullOrWhiteSpace($MissingRouteModel)) {
  $MissingRouteModel = "missing-route-smoke-$suffix"
}

$gatewayAuthHeaders = @{ Authorization = "Bearer $GatewayAuthToken" }

Push-Location $repoRoot
try {
  if (-not $SkipComposePs) {
    Check "docker compose routing services are running" {
      $running = @(Invoke-Docker compose -f $ComposeFile ps --services --status running)
      if ($LASTEXITCODE -ne 0) { throw "docker compose ps failed with exit code $LASTEXITCODE" }

      foreach ($service in @("postgres", "gateway", "mock-provider")) {
        if ($running -notcontains $service) {
          throw "service '$service' is not running"
        }
      }
    }
  }

  Check "gateway models routing list" {
    $response = Invoke-GatewayRequest -Method GET -Uri (Join-Url $GatewayBaseUrl "/v1/models") -Headers $gatewayAuthHeaders
    Assert-Status $response 200
    $payload = Read-Json $response.Content
    if ($payload.object -ne "list") {
      throw "expected object=list, got '$($payload.object)'"
    }
    if (-not (Test-ModelListContains -Payload $payload -ExpectedModel $Model)) {
      throw "model list does not include '$Model'"
    }
  }

  Check "gateway chat completion writes request and attempt logs" {
    $chatBody = New-ChatBodyJson -RequestModel $Model -Content "gateway routing smoke $suffix"
    $script:ChatRequestHash = Get-Sha256Hex $chatBody
    $response = Invoke-GatewayRequest -Method POST -Uri (Join-Url $GatewayBaseUrl "/v1/chat/completions") -Headers $gatewayAuthHeaders -JsonBody $chatBody
    Assert-Status $response 200
    $payload = Read-Json $response.Content
    if ($payload.object -ne "chat.completion") {
      throw "expected object=chat.completion, got '$($payload.object)'"
    }

    $rows = @(Wait-RequestLogRowsByHash $script:ChatRequestHash)
    $requestRow = $rows[0]
    if ($requestRow.requested_model -ne $Model) {
      throw "request_logs.requested_model expected '$Model', got '$($requestRow.requested_model)'"
    }
    if ($requestRow.request_status -ne "succeeded") {
      throw "request_logs.status expected 'succeeded', got '$($requestRow.request_status)'"
    }
    if ([int]$requestRow.request_http_status -ne 200) {
      throw "request_logs.http_status expected 200, got '$($requestRow.request_http_status)'"
    }

    $attemptRows = @($rows | Where-Object { $_.attempt_id })
    if ($attemptRows.Count -eq 0) {
      throw "provider_attempts row was not created for request $($requestRow.request_id)"
    }
    if ($attemptRows[0].attempt_status -ne "succeeded") {
      throw "provider_attempts.status expected 'succeeded', got '$($attemptRows[0].attempt_status)'"
    }
    if ([int]$attemptRows[0].attempt_http_status -ne 200) {
      throw "provider_attempts.http_status expected 200, got '$($attemptRows[0].attempt_http_status)'"
    }

    $script:ChatLogRows = $rows
  }

  Check-ResolvedRoutingIds
  Check-MissingRouteBehavior -Headers $gatewayAuthHeaders -RequestModel $MissingRouteModel
} finally {
  Pop-Location
}

if ($script:Failures.Count -gt 0) {
  Write-Host ""
  Write-Host "Gateway routing smoke failed:"
  foreach ($failure in $script:Failures) {
    Write-Host $failure
  }
  exit 1
}

Write-Host ""
if ($script:Pending.Count -gt 0) {
  Write-Host "Gateway routing baseline passed. Strict routing checks pending:"
  foreach ($pending in $script:Pending) {
    Write-Host $pending
  }
  exit 0
}

Write-Host "Gateway routing smoke passed."
