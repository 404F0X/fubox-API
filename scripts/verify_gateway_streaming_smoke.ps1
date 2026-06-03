param(
  [string]$GatewayBaseUrl = "http://127.0.0.1:8080",
  [string]$GatewayAuthToken = "dev_test_key_123456789",
  [string]$Model = "mock-gpt-4o-mini",
  [string]$ComposeFile = "deploy/docker-compose/docker-compose.yml",
  [int]$TimeoutSeconds = 8,
  [int]$FailureTimeoutSeconds = 3,
  [int]$DbPollSeconds = 10,
  [switch]$SkipComposePs,
  [switch]$SkipDbLog,
  [switch]$SkipNetwork,
  [switch]$DryRun,
  [switch]$StrictGatewayStreaming
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$fixturePath = Join-Path $repoRoot "tests\fixtures\gateway\streaming_acceptance.json"
$script:Failures = @()
$script:Pending = @()

function Test-TruthyEnv {
  param([string]$Value)

  return $Value -eq "1" -or $Value -match "^(true|yes|on)$"
}

if ($env:GATEWAY_BASE_URL) { $GatewayBaseUrl = $env:GATEWAY_BASE_URL }
if ($env:GATEWAY_AUTH_TOKEN) { $GatewayAuthToken = $env:GATEWAY_AUTH_TOKEN }
if ($env:SMOKE_MODEL) { $Model = $env:SMOKE_MODEL }
if ($env:COMPOSE_FILE) { $ComposeFile = $env:COMPOSE_FILE }
if (Test-TruthyEnv $env:GATEWAY_STREAMING_SKIP_COMPOSE_PS) { $SkipComposePs = $true }
if (Test-TruthyEnv $env:GATEWAY_STREAMING_SKIP_DB_LOG) { $SkipDbLog = $true }
if (Test-TruthyEnv $env:GATEWAY_STREAMING_SKIP_NETWORK) { $SkipNetwork = $true }
if (Test-TruthyEnv $env:GATEWAY_STREAMING_DRY_RUN) { $DryRun = $true }
if (Test-TruthyEnv $env:STRICT_GATEWAY_STREAMING) { $StrictGatewayStreaming = $true }

Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Security

function Redact-SecretLikeString {
  param([AllowNull()][string]$Text)

  if ($null -eq $Text) {
    return ""
  }

  $redacted = $Text
  foreach ($knownSecret in @($GatewayAuthToken, $ControlPlaneAuthToken, $AdminPassword, $AdminSessionToken, $script:AdminSessionToken)) {
    if (-not [string]::IsNullOrEmpty($knownSecret)) {
      $redacted = $redacted.Replace([string]$knownSecret, "[REDACTED]")
    }
  }

  $redacted = $redacted -replace '(?i)(authorization\s*[:=]\s*bearer\s+)[^\s";,}]+', '${1}[REDACTED]'
  $redacted = $redacted -replace '(?i)(Bearer\s+)[A-Za-z0-9._~+/\-]+=*', '${1}[REDACTED]'
  $redacted = $redacted -replace '(?i)("(?:[^"\\]|\\.)*(?:token|password|passwd|secret|api[_-]?key|access[_-]?key|private[_-]?key|provider[_-]?key)(?:[^"\\]|\\.)*"\s*:\s*")(?:(?:\\.)|[^"\\])*(")', '${1}[REDACTED]${2}'
  $redacted = $redacted -replace '(?i)([a-z][a-z0-9+.-]*://)[^/?#@\s:]+:[^/?#@\s]*@', '${1}[REDACTED]:[REDACTED]@'
  $redacted = $redacted -replace '(?i)([a-z][a-z0-9+.-]*://)[^/?#@\s:]+@', '${1}[REDACTED]@'
  $redacted = $redacted -replace '(?i)([?&;][^=&#\s]*(?:api[_-]?key|token|password|passwd|secret)[^=&#\s]*=)[^&#\s"<>]+', '${1}[REDACTED]'
  $redacted = $redacted -replace '(?i)(\b[A-Za-z0-9_-]*(?:token|password|passwd|secret|api[_-]?key|access[_-]?key|private[_-]?key|provider[_-]?key)[A-Za-z0-9_-]*\s*[:=]\s*)[^\s";,}\]]+', '${1}[REDACTED]'
  $redacted = $redacted -replace 'sk-[A-Za-z0-9._~+\-/=]+', '[REDACTED]'
  $redacted = $redacted -replace 'dev_test_key_[A-Za-z0-9._~+\-/=]+', '[REDACTED]'
  $redacted = $redacted -replace '(?i)\$env:[A-Z0-9_]*(?:token|password|passwd|secret|api[_-]?key|access[_-]?key|private[_-]?key|provider[_-]?key)[A-Z0-9_]*', '[REDACTED]'
  $redacted = $redacted -replace '(?i)(?<![A-Za-z0-9_])env:[/\\]?[A-Z0-9_]*(?:token|password|passwd|secret|api[_-]?key|access[_-]?key|private[_-]?key|provider[_-]?key)[A-Z0-9_]*', '[REDACTED]'
  $redacted = $redacted -replace '(?i)\$\{[A-Z0-9_]*(?:token|password|passwd|secret|api[_-]?key|access[_-]?key|private[_-]?key|provider[_-]?key)[A-Z0-9_]*\}', '[REDACTED]'
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

function Add-Pending {
  param([Parameter(Mandatory = $true)][string]$Message)

  $safe = Redact-SecretLikeString $Message
  $script:Pending += $safe
  Write-SafeHost $safe
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

function Report-PendingOrFail {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Message
  )

  if ($StrictGatewayStreaming) {
    Add-Failure "[FAIL] $Name - $Message"
  } else {
    Add-Pending "[PENDING] $Name - $Message"
  }
}

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
    [Parameter(Mandatory = $true)][string]$Content,
    [string]$Scenario = ""
  )

  $json = '{"model":' + (ConvertTo-JsonString $RequestModel) + ',"messages":[{"role":"user","content":' + (ConvertTo-JsonString $Content) + '}],"stream":true'
  if (-not [string]::IsNullOrWhiteSpace($Scenario)) {
    $json += ',"mock_scenario":' + (ConvertTo-JsonString $Scenario)
  }

  return $json + '}'
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

function Escape-SqlLiteral {
  param([Parameter(Mandatory = $true)][string]$Value)

  return $Value.Replace("'", "''")
}

function Read-Json {
  param([Parameter(Mandatory = $true)][string]$Content)

  try {
    return $Content | ConvertFrom-Json
  } catch {
    throw "expected JSON response, got: $Content"
  }
}

function Read-Fixture {
  if (-not (Test-Path $fixturePath)) {
    throw "missing tests\fixtures\gateway\streaming_acceptance.json"
  }

  try {
    return Get-Content -Raw $fixturePath | ConvertFrom-Json
  } catch {
    throw "streaming_acceptance.json is not valid JSON: $($_.Exception.Message)"
  }
}

function Assert-FixtureContract {
  param([Parameter(Mandatory = $true)]$Fixture)

  if ($Fixture.scenario -ne "gateway_openai_chat_streaming_acceptance") {
    throw "fixture scenario must be gateway_openai_chat_streaming_acceptance"
  }
  if ($Fixture.base_path -ne "/v1/chat/completions") {
    throw "fixture base_path must be /v1/chat/completions"
  }
  if ($Fixture.request_body.stream -ne $true) {
    throw "fixture request_body.stream must be true"
  }

  foreach ($scenario in @("200", "invalid_json_chunk", "large_chunk", "missing_done", "timeout", "eof", "stream_timeout", "stream_eof")) {
    if (@($Fixture.required_mock_scenarios | Where-Object { $_ -eq $scenario }).Count -ne 1) {
      throw "fixture required_mock_scenarios must include '$scenario'"
    }
  }

  $normal = @($Fixture.acceptance_checks | Where-Object { $_.mock_scenario -eq "200" } | Select-Object -First 1)
  if ($normal.Count -ne 1 -or $normal[0].expected_request_log.stream_end_reason -ne "completed") {
    throw "fixture must define normal stream completed request log expectations"
  }

  $missingDone = @($Fixture.acceptance_checks | Where-Object { $_.mock_scenario -eq "missing_done" } | Select-Object -First 1)
  if ($missingDone.Count -ne 1 -or $missingDone[0].expected_request_log.stream_end_reason -ne "upstream_eof") {
    throw "fixture must define missing_done upstream_eof expectations"
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

  if (-not [string]::IsNullOrEmpty($JsonBody)) {
    $content = New-Object System.Net.Http.StringContent -ArgumentList $JsonBody
    $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/json")
    $request.Content = $content
  }

  $response = $null
  try {
    $response = $client.SendAsync($request).GetAwaiter().GetResult()
    $headersOut = @{}
    foreach ($header in $response.Headers.GetEnumerator()) {
      $headersOut[$header.Key] = ($header.Value -join ",")
    }
    foreach ($header in $response.Content.Headers.GetEnumerator()) {
      $headersOut[$header.Key] = ($header.Value -join ",")
    }

    return [PSCustomObject]@{
      StatusCode = [int]$response.StatusCode
      Content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
      Headers = $headersOut
    }
  } finally {
    if ($response) { $response.Dispose() }
    $request.Dispose()
    $client.Dispose()
  }
}

function New-GatewayHeaders {
  return @{ Authorization = "Bearer $GatewayAuthToken" }
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

function Assert-NotContains {
  param(
    [Parameter(Mandatory = $true)][string]$Content,
    [Parameter(Mandatory = $true)][string]$Needle
  )

  if ($Content.Contains($Needle)) {
    throw "response unexpectedly contains '$Needle'"
  }
}

function Assert-ContentType {
  param(
    [Parameter(Mandatory = $true)]$Response,
    [Parameter(Mandatory = $true)][string]$ExpectedPrefix
  )

  $contentType = [string]$Response.Headers["Content-Type"]
  if (-not $contentType.StartsWith($ExpectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "expected Content-Type to start with '$ExpectedPrefix', got '$contentType'"
  }
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

function Get-RequestLogByHash {
  param([Parameter(Mandatory = $true)][string]$RequestHash)

  $hash = Escape-SqlLiteral $RequestHash
  $sql = @"
select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb)::text
from (
  select
    rl.id::text as request_id,
    rl.status,
    rl.http_status,
    rl.partial_sent,
    rl.stream_end_reason,
    rl.error_code,
    rl.ttft_ms,
    rl.latency_ms,
    rl.requested_model,
    rl.upstream_model,
    count(pa.id)::int as provider_attempt_count,
    max(pa.status) as provider_attempt_status,
    max(pa.error_code) as provider_attempt_error_code
  from request_logs rl
  left join provider_attempts pa
    on pa.tenant_id = rl.tenant_id
   and pa.request_id = rl.id
  where rl.request_body_hash = '$hash'
  group by rl.id
  order by rl.created_at desc
  limit 1
) t;
"@

  $json = Invoke-ComposePsql $sql
  if ([string]::IsNullOrWhiteSpace($json)) {
    return @()
  }

  return @($json | ConvertFrom-Json)
}

function Wait-RequestLogByHash {
  param([Parameter(Mandatory = $true)][string]$RequestHash)

  $deadline = (Get-Date).AddSeconds($DbPollSeconds)
  while ((Get-Date) -lt $deadline) {
    $rows = @(Get-RequestLogByHash $RequestHash)
    if ($rows.Count -gt 0) {
      return $rows[0]
    }

    Start-Sleep -Seconds 1
  }

  throw "request_logs row with request_body_hash=$RequestHash was not observed within $DbPollSeconds seconds"
}

function Assert-RequestLog {
  param(
    [Parameter(Mandatory = $true)][string]$RequestHash,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$ExpectedStatus,
    [Parameter(Mandatory = $true)][bool]$ExpectedPartialSent,
    [Parameter(Mandatory = $true)][string]$ExpectedEndReason,
    [string]$ExpectedErrorCode = "",
    [int]$ExpectedHttpStatus = 0
  )

  if ($SkipDbLog) {
    Report-PendingOrFail -Name "$Name request log" -Message "skipped request_logs verification"
    return
  }

  $row = Wait-RequestLogByHash $RequestHash
  if ($row.status -ne $ExpectedStatus) {
    throw "$Name request_logs.status expected '$ExpectedStatus', got '$($row.status)'"
  }
  if ([bool]$row.partial_sent -ne $ExpectedPartialSent) {
    throw "$Name request_logs.partial_sent expected '$ExpectedPartialSent', got '$($row.partial_sent)'"
  }
  if ($row.stream_end_reason -ne $ExpectedEndReason) {
    throw "$Name request_logs.stream_end_reason expected '$ExpectedEndReason', got '$($row.stream_end_reason)'"
  }
  if ($ExpectedErrorCode -and $row.error_code -ne $ExpectedErrorCode) {
    throw "$Name request_logs.error_code expected '$ExpectedErrorCode', got '$($row.error_code)'"
  }
  if ($ExpectedHttpStatus -gt 0 -and [int]$row.http_status -ne $ExpectedHttpStatus) {
    throw "$Name request_logs.http_status expected $ExpectedHttpStatus, got '$($row.http_status)'"
  }
  if ([int]$row.provider_attempt_count -lt 1) {
    throw "$Name provider_attempts row was not recorded"
  }
}

function Invoke-StreamProbe {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Scenario,
    [int]$TimeoutSec = $TimeoutSeconds
  )

  $body = New-ChatBodyJson -RequestModel $Model -Content "gateway streaming smoke $Name" -Scenario $Scenario
  $hash = Get-Sha256Hex $body
  $response = Invoke-GatewayRequest `
    -Method POST `
    -Uri (Join-Url $GatewayBaseUrl "/v1/chat/completions") `
    -Headers (New-GatewayHeaders) `
    -JsonBody $body `
    -TimeoutSec $TimeoutSec

  return [PSCustomObject]@{
    RequestHash = $hash
    Response = $response
  }
}

$fixture = $null
$offlineMode = $DryRun -or $SkipNetwork

Push-Location $repoRoot
try {
  Check "gateway streaming fixture files exist" {
    foreach ($relativePath in @(
        "scripts\verify_gateway_streaming_smoke.ps1",
        "scripts\common.ps1",
        "tests\fixtures\gateway\streaming_acceptance.json",
        "tests\fixtures\mock-provider\scenarios\openai_chat_streaming.json",
        "tests\fixtures\mock-provider\scenarios\chat_stream_valid_done.sse",
        "tests\fixtures\mock-provider\scenarios\chat_stream_invalid_json_chunk.sse",
        "tests\fixtures\mock-provider\scenarios\chat_stream_missing_done.sse"
      )) {
      $path = Join-Path $repoRoot $relativePath
      if (-not (Test-Path $path)) {
        throw "missing $relativePath"
      }
    }
  }

  Check "gateway streaming fixture contract" {
    $script:fixture = Read-Fixture
    Assert-FixtureContract $script:fixture
  }

  Check "mock-provider streaming manifest parses" {
    [void](Get-Content -Raw (Join-Path $repoRoot "tests\fixtures\mock-provider\scenarios\openai_chat_streaming.json") | ConvertFrom-Json)
  }

  if ($offlineMode) {
    Write-SafeHost ""
    Write-SafeHost "Gateway streaming smoke dry-run passed; runtime requests were not sent."
  } else {
    if (-not $SkipComposePs) {
      Check "docker compose streaming services are running" {
        $running = @(Invoke-Docker compose -f $ComposeFile ps --services --status running)
        if ($LASTEXITCODE -ne 0) { throw "docker compose ps failed with exit code $LASTEXITCODE" }

        foreach ($service in @("postgres", "gateway", "mock-provider")) {
          if ($running -notcontains $service) {
            throw "service '$service' is not running"
          }
        }
      }
    }

    Check "normal stream contains chunks and DONE" {
      $result = Invoke-StreamProbe -Name "normal" -Scenario "200"
      Assert-Status $result.Response 200
      Assert-ContentType $result.Response "text/event-stream"
      Assert-Contains $result.Response.Content "chat.completion.chunk"
      Assert-Contains $result.Response.Content "data: [DONE]"
      Assert-RequestLog `
        -RequestHash $result.RequestHash `
        -Name "normal stream" `
        -ExpectedStatus "succeeded" `
        -ExpectedPartialSent $true `
        -ExpectedEndReason "completed" `
        -ExpectedHttpStatus 200
    }

    Check "large chunk stream stays bounded and completes" {
      $result = Invoke-StreamProbe -Name "large chunk" -Scenario "large_chunk"
      Assert-Status $result.Response 200
      Assert-ContentType $result.Response "text/event-stream"
      Assert-Contains $result.Response.Content "data: [DONE]"
      if ($result.Response.Content.Length -lt (70 * 1024)) {
        throw "expected response body >= 70KB, got $($result.Response.Content.Length) bytes"
      }
      Assert-RequestLog `
        -RequestHash $result.RequestHash `
        -Name "large chunk stream" `
        -ExpectedStatus "succeeded" `
        -ExpectedPartialSent $true `
        -ExpectedEndReason "completed" `
        -ExpectedHttpStatus 200
    }

    Check "missing DONE records upstream_eof without late fallback" {
      $result = Invoke-StreamProbe -Name "missing done" -Scenario "missing_done"
      Assert-Status $result.Response 200
      Assert-ContentType $result.Response "text/event-stream"
      Assert-Contains $result.Response.Content "chat.completion.chunk"
      Assert-NotContains $result.Response.Content "data: [DONE]"
      Assert-RequestLog `
        -RequestHash $result.RequestHash `
        -Name "missing DONE stream" `
        -ExpectedStatus "partial" `
        -ExpectedPartialSent $true `
        -ExpectedEndReason "upstream_eof" `
        -ExpectedErrorCode "stream_upstream_eof"
    }

    Check "invalid JSON chunk records parser_error after partial stream" {
      $body = New-ChatBodyJson -RequestModel $Model -Content "gateway streaming smoke invalid json" -Scenario "invalid_json_chunk"
      $hash = Get-Sha256Hex $body
      try {
        $response = Invoke-GatewayRequest `
          -Method POST `
          -Uri (Join-Url $GatewayBaseUrl "/v1/chat/completions") `
          -Headers (New-GatewayHeaders) `
          -JsonBody $body `
          -TimeoutSec $FailureTimeoutSeconds
        if ($response.StatusCode -ne 200) {
          throw "expected HTTP 200 headers before parser error, got HTTP $($response.StatusCode)"
        }
        Assert-NotContains $response.Content "data: [DONE]"
      } catch {
        if ($_.Exception.Message -notmatch "chat stream ended with parser_error|error while copying content|An error occurred|response ended prematurely|IOException") {
          throw
        }
      }
      Assert-RequestLog `
        -RequestHash $hash `
        -Name "invalid JSON stream" `
        -ExpectedStatus "partial" `
        -ExpectedPartialSent $true `
        -ExpectedEndReason "parser_error" `
        -ExpectedErrorCode "stream_parser_error"
    }

    Check "mid-stream EOF records partial upstream_error/eof without late fallback" {
      $body = New-ChatBodyJson -RequestModel $Model -Content "gateway streaming smoke stream eof" -Scenario "stream_eof"
      $hash = Get-Sha256Hex $body
      try {
        $response = Invoke-GatewayRequest `
          -Method POST `
          -Uri (Join-Url $GatewayBaseUrl "/v1/chat/completions") `
          -Headers (New-GatewayHeaders) `
          -JsonBody $body `
          -TimeoutSec $FailureTimeoutSeconds
        Assert-Status $response 200
        Assert-NotContains $response.Content "data: [DONE]"
      } catch {
        if ($_.Exception.Message -notmatch "chat stream ended with upstream_error|error while copying content|An error occurred|response ended prematurely|IOException") {
          throw
        }
      }

      if (-not $SkipDbLog) {
        $row = Wait-RequestLogByHash $hash
        if (-not [bool]$row.partial_sent) {
          throw "stream_eof should mark request_logs.partial_sent=true"
        }
        if (@("upstream_error", "upstream_eof") -notcontains [string]$row.stream_end_reason) {
          throw "stream_eof expected stream_end_reason upstream_error/upstream_eof, got '$($row.stream_end_reason)'"
        }
        if ([int]$row.provider_attempt_count -ne 1) {
          throw "stream_eof should not late-fallback after partial_sent; expected one provider_attempt, got $($row.provider_attempt_count)"
        }
      } else {
        Report-PendingOrFail -Name "mid-stream EOF request log" -Message "skipped request_logs verification"
      }
    }
  }
} finally {
  Pop-Location
}

if ($script:Failures.Count -gt 0) {
  Write-SafeHost ""
  Write-SafeHost "Gateway streaming smoke failed:"
  foreach ($failure in $script:Failures) {
    Write-SafeHost $failure
  }
  exit 1
}

Write-SafeHost ""
if ($script:Pending.Count -gt 0) {
  Write-SafeHost "Gateway streaming smoke passed with pending checks:"
  foreach ($pending in $script:Pending) {
    Write-SafeHost $pending
  }
  exit 0
}

Write-SafeHost "Gateway streaming smoke passed."
