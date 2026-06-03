param(
  [string]$GatewayBaseUrl = "http://127.0.0.1:8080",
  [string]$ControlPlaneBaseUrl = "http://127.0.0.1:8081",
  [string]$MockProviderBaseUrl = "http://127.0.0.1:18080",
  [string]$AdminUiBaseUrl = "http://127.0.0.1:5173",
  [string]$GatewayAuthToken = "dev_test_key_123456789",
  [int]$TimeoutSeconds = 8,
  [switch]$SkipComposePs,
  [switch]$StrictGatewayContracts,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$script:Failures = @()

if ($env:GATEWAY_BASE_URL) { $GatewayBaseUrl = $env:GATEWAY_BASE_URL }
if ($env:CONTROL_PLANE_BASE_URL) { $ControlPlaneBaseUrl = $env:CONTROL_PLANE_BASE_URL }
if ($env:MOCK_PROVIDER_BASE_URL) { $MockProviderBaseUrl = $env:MOCK_PROVIDER_BASE_URL }
if ($env:ADMIN_UI_BASE_URL) { $AdminUiBaseUrl = $env:ADMIN_UI_BASE_URL }
if ($env:GATEWAY_AUTH_TOKEN) { $GatewayAuthToken = $env:GATEWAY_AUTH_TOKEN }
if ($env:STRICT_GATEWAY_CONTRACTS -eq "1") { $StrictGatewayContracts = $true }

Add-Type -AssemblyName System.Net.Http

function Join-Url {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$Path
  )

  return $BaseUrl.TrimEnd("/") + $Path
}

function Invoke-SmokeRequest {
  param(
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Uri,
    [object]$Body = $null,
    [hashtable]$Headers = @{},
    [int]$TimeoutSec = $TimeoutSeconds
  )

  $client = New-Object System.Net.Http.HttpClient
  $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
  $request = New-Object System.Net.Http.HttpRequestMessage -ArgumentList (New-Object System.Net.Http.HttpMethod -ArgumentList $Method), $Uri

  foreach ($key in $Headers.Keys) {
    [void]$request.Headers.TryAddWithoutValidation($key, [string]$Headers[$key])
  }

  if (($Method -eq "GET" -or $Method -eq "HEAD") -and $null -ne $Body) {
    throw "$Method requests must not include a JSON body"
  }

  if ($null -ne $Body) {
    $json = $Body | ConvertTo-Json -Depth 16 -Compress
    $content = New-Object System.Net.Http.StringContent -ArgumentList $json
    $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/json")
    $request.Content = $content
  }

  $response = $null
  try {
    $response = $client.SendAsync($request).GetAwaiter().GetResult()
    $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $responseHeaders = @{}

    foreach ($header in $response.Headers.GetEnumerator()) {
      $responseHeaders[$header.Key] = ($header.Value -join ",")
    }

    foreach ($header in $response.Content.Headers.GetEnumerator()) {
      $responseHeaders[$header.Key] = ($header.Value -join ",")
    }

    return [PSCustomObject]@{
      StatusCode = [int]$response.StatusCode
      Content = $content
      Headers = $responseHeaders
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

function Assert-HeaderContains {
  param(
    [Parameter(Mandatory = $true)]$Response,
    [Parameter(Mandatory = $true)][string]$HeaderName,
    [Parameter(Mandatory = $true)][string]$Needle
  )

  $value = $Response.Headers[$HeaderName]
  if ([string]::IsNullOrEmpty($value) -or $value.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
    throw "response header '$HeaderName' does not contain '$Needle'"
  }
}

function Assert-JsonProperty {
  param(
    [Parameter(Mandatory = $true)][string]$Content,
    [Parameter(Mandatory = $true)][string]$PropertyName,
    [Parameter(Mandatory = $true)][object]$Expected
  )

  $json = $Content | ConvertFrom-Json
  if ($json.$PropertyName -ne $Expected) {
    throw "expected JSON property '$PropertyName' to be '$Expected', got '$($json.$PropertyName)'"
  }
}

function Assert-RequestFails {
  param(
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Uri,
    [object]$Body = $null,
    [int]$TimeoutSec = 3
  )

  try {
    $response = Invoke-SmokeRequest -Method $Method -Uri $Uri -Body $Body -TimeoutSec $TimeoutSec
    throw "expected request failure, got HTTP $($response.StatusCode)"
  } catch {
    if ($_.Exception.Message.StartsWith("expected request failure")) {
      throw
    }
  }
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

  Write-Host "[PENDING] $Name - $Message"
}

function Probe-GatewayModels {
  param(
    [Parameter(Mandatory = $true)][hashtable]$Headers
  )

  $name = "gateway models endpoint contract"
  try {
    $response = Invoke-SmokeRequest -Method GET -Uri (Join-Url $GatewayBaseUrl "/v1/models") -Headers $Headers
    if ($response.StatusCode -eq 200) {
      Assert-JsonProperty $response.Content "object" "list"
      Assert-Contains $response.Content "mock-gpt-4o-mini"
      Write-Host "[OK] $name"
      return
    }

    if ($response.StatusCode -eq 404 -or $response.StatusCode -eq 405) {
      Report-PendingOrFail -Name $name -Message "GET /v1/models is not implemented by gateway yet; run with -StrictGatewayContracts after E4/E5 wiring." -Strict:$StrictGatewayContracts
      return
    }

    throw "expected HTTP 200, 404, or 405, got HTTP $($response.StatusCode): $($response.Content)"
  } catch {
    $message = "[FAIL] $name - $($_.Exception.Message)"
    $script:Failures += $message
    Write-Host $message
  }
}

function Probe-GatewayAuthRequired {
  param(
    [Parameter(Mandatory = $true)]$ChatBody
  )

  $name = "gateway chat requires Authorization Bearer"
  try {
    $response = Invoke-SmokeRequest -Method POST -Uri (Join-Url $GatewayBaseUrl "/v1/chat/completions") -Body $ChatBody
    if ($response.StatusCode -eq 401 -or $response.StatusCode -eq 403) {
      Write-Host "[OK] $name"
      return
    }

    if ($response.StatusCode -eq 200) {
      Report-PendingOrFail -Name $name -Message "gateway accepts chat without Authorization; auth is not enforced yet. Run with -StrictGatewayContracts after auth wiring." -Strict:$StrictGatewayContracts
      return
    }

    throw "expected HTTP 401/403 when Authorization is missing, got HTTP $($response.StatusCode): $($response.Content)"
  } catch {
    $message = "[FAIL] $name - $($_.Exception.Message)"
    $script:Failures += $message
    Write-Host $message
  }
}

function Assert-GatewayStreamingContract {
  param(
    [Parameter(Mandatory = $true)]$Response
  )

  Assert-Status $Response 200
  Assert-HeaderContains $Response "Content-Type" "text/event-stream"
  Assert-Contains $Response.Content "chat.completion.chunk"
  Assert-Contains $Response.Content "data: [DONE]"
}

function Probe-GatewayStreaming {
  param(
    [Parameter(Mandatory = $true)][hashtable]$Headers,
    [Parameter(Mandatory = $true)]$ChatBody
  )

  $name = "gateway chat completion stream 200"
  try {
    $body = $ChatBody.Clone()
    $body.stream = $true
    $response = Invoke-SmokeRequest -Method POST -Uri (Join-Url $GatewayBaseUrl "/v1/chat/completions") -Headers $Headers -Body $body
    if ($response.StatusCode -eq 200) {
      Assert-GatewayStreamingContract -Response $response
      Write-Host "[OK] $name"
      return
    }

    if (
      $response.StatusCode -eq 404 -or
      $response.StatusCode -eq 405 -or
      ($response.StatusCode -eq 501 -and $response.Content.Contains("streaming_not_implemented"))
    ) {
      Report-PendingOrFail -Name $name -Message "gateway streaming is not enabled or implemented in this environment; run with -StrictGatewayContracts after streaming is required." -Strict:$StrictGatewayContracts
      return
    }

    throw "expected HTTP 200 SSE stream, 404, 405, or 501 streaming_not_implemented, got HTTP $($response.StatusCode): $($response.Content)"
  } catch {
    $message = "[FAIL] $name - $($_.Exception.Message)"
    $script:Failures += $message
    Write-Host $message
  }
}

function Assert-GatewayModelsContract {
  param(
    [Parameter(Mandatory = $true)][hashtable]$Headers
  )

  $response = Invoke-SmokeRequest -Method GET -Uri (Join-Url $GatewayBaseUrl "/v1/models") -Headers $Headers
  Assert-Status $response 200
  Assert-JsonProperty $response.Content "object" "list"
  Assert-Contains $response.Content "mock-gpt-4o-mini"
}

function Assert-GatewayMissingAuthContract {
  param(
    [Parameter(Mandatory = $true)]$ChatBody
  )

  $response = Invoke-SmokeRequest -Method POST -Uri (Join-Url $GatewayBaseUrl "/v1/chat/completions") -Body $ChatBody
  if ($response.StatusCode -ne 401 -and $response.StatusCode -ne 403) {
    throw "expected HTTP 401/403 when Authorization is missing, got HTTP $($response.StatusCode): $($response.Content)"
  }
}

function Assert-DryRunText {
  param(
    [Parameter(Mandatory = $true)][string]$Content,
    [Parameter(Mandatory = $true)][string]$Needle
  )

  if (-not $Content.Contains($Needle)) {
    throw "dry-run text check failed: missing '$Needle'"
  }
}

if ($DryRun) {
  $source = Get-Content -LiteralPath $PSCommandPath -Raw
  Assert-DryRunText $source "Probe-GatewayStreaming"
  Assert-DryRunText $source "text/event-stream"
  Assert-DryRunText $source "chat.completion.chunk"
  Assert-DryRunText $source "data: [DONE]"

  $oldStreamingCheckName = "gateway chat completion rejects " + "stream"
  if ($source.Contains($oldStreamingCheckName)) {
    throw "dry-run text check failed: old gateway streaming rejection check is still present"
  }

  if ($source -match 'Assert-Status\s+\$response\s+501') {
    throw "dry-run text check failed: old gateway stream HTTP 501 assertion is still present"
  }

  if ($source -match 'Join-Url\s+\$ControlPlaneBaseUrl\s+"/admin/') {
    throw "dry-run text check failed: verify_compose_smoke.ps1 should not call Control Plane /admin/*"
  }

  Write-Host "[OK] compose smoke dry-run self-checks"
  exit 0
}

Push-Location $repoRoot
try {
  if (-not $SkipComposePs) {
    Check "docker compose services are running" {
      . "$PSScriptRoot\common.ps1"
      $running = @(Invoke-Docker compose -f deploy/docker-compose/docker-compose.yml ps --services --status running)
      if ($LASTEXITCODE -ne 0) { throw "docker compose ps failed with exit code $LASTEXITCODE" }

      foreach ($service in @("postgres", "redis", "mock-provider", "gateway", "control-plane", "worker", "admin-ui")) {
        if ($running -notcontains $service) {
          throw "service '$service' is not running"
        }
      }
    }
  }

  Check "gateway healthz" {
    $response = Invoke-SmokeRequest -Method GET -Uri (Join-Url $GatewayBaseUrl "/healthz")
    Assert-Status $response 200
    Assert-JsonProperty $response.Content "status" "ok"
  }

  Check "gateway readyz" {
    $response = Invoke-SmokeRequest -Method GET -Uri (Join-Url $GatewayBaseUrl "/readyz")
    Assert-Status $response 200
    Assert-JsonProperty $response.Content "status" "ready"
    if ($StrictGatewayContracts) {
      Assert-JsonProperty $response.Content "database_gateway_store" "connected"
    }
  }

  Check "gateway metrics" {
    $response = Invoke-SmokeRequest -Method GET -Uri (Join-Url $GatewayBaseUrl "/metrics")
    Assert-Status $response 200
    Assert-Contains $response.Content 'ai_gateway_service_up{service="gateway"} 1'
  }

  $chatBody = @{
    model = "mock-gpt-4o-mini"
    messages = @(@{ role = "user"; content = "ping" })
  }
  $gatewayAuthHeaders = @{ Authorization = "Bearer $GatewayAuthToken" }

  if ($StrictGatewayContracts) {
    Check "gateway models endpoint contract (strict)" {
      Assert-GatewayModelsContract -Headers $gatewayAuthHeaders
    }

    Check "gateway missing Authorization contract (strict)" {
      Assert-GatewayMissingAuthContract -ChatBody $chatBody
    }
  } else {
    Probe-GatewayModels -Headers $gatewayAuthHeaders

    Probe-GatewayAuthRequired -ChatBody $chatBody
  }

  Check "gateway chat completion 200" {
    $response = Invoke-SmokeRequest -Method POST -Uri (Join-Url $GatewayBaseUrl "/v1/chat/completions") -Headers $gatewayAuthHeaders -Body $chatBody
    Assert-Status $response 200
    Assert-JsonProperty $response.Content "object" "chat.completion"
    Assert-Contains $response.Content '"finish_reason":"stop"'
  }

  Probe-GatewayStreaming -Headers $gatewayAuthHeaders -ChatBody $chatBody

  Check "gateway chat completion rejects missing model" {
    $response = Invoke-SmokeRequest -Method POST -Uri (Join-Url $GatewayBaseUrl "/v1/chat/completions") -Headers $gatewayAuthHeaders -Body @{
      messages = @(@{ role = "user"; content = "ping" })
    }
    Assert-Status $response 400
    Assert-Contains $response.Content '"param":"model"'
  }

  Check "gateway propagates provider 429 as JSON" {
    $body = $chatBody.Clone()
    $body.mock_scenario = "429"
    $response = Invoke-SmokeRequest -Method POST -Uri (Join-Url $GatewayBaseUrl "/v1/chat/completions") -Headers $gatewayAuthHeaders -Body $body
    Assert-Status $response 429
    Assert-Contains $response.Content "provider_429"
    Assert-Contains $response.Content "rate_limit_error"
  }

  Check "control-plane healthz" {
    $response = Invoke-SmokeRequest -Method GET -Uri (Join-Url $ControlPlaneBaseUrl "/healthz")
    Assert-Status $response 200
    Assert-JsonProperty $response.Content "status" "ok"
  }

  Check "control-plane readyz" {
    $response = Invoke-SmokeRequest -Method GET -Uri (Join-Url $ControlPlaneBaseUrl "/readyz")
    Assert-Status $response 200
    Assert-JsonProperty $response.Content "status" "ready"
  }

  Check "admin-ui root" {
    $response = Invoke-SmokeRequest -Method GET -Uri (Join-Url $AdminUiBaseUrl "/")
    Assert-Status $response 200
    Assert-Contains $response.Content "<div id=`"root`"></div>"
  }

  Check "mock-provider healthz" {
    $response = Invoke-SmokeRequest -Method GET -Uri (Join-Url $MockProviderBaseUrl "/healthz")
    Assert-Status $response 200
    Assert-JsonProperty $response.Content "status" "ok"
  }

  Check "mock-provider models" {
    $response = Invoke-SmokeRequest -Method GET -Uri (Join-Url $MockProviderBaseUrl "/v1/models")
    Assert-Status $response 200
    Assert-JsonProperty $response.Content "object" "list"
    Assert-Contains $response.Content "mock-gpt-4o-mini"
  }

  Check "mock-provider chat completion 200" {
    $response = Invoke-SmokeRequest -Method POST -Uri (Join-Url $MockProviderBaseUrl "/v1/chat/completions") -Body $chatBody
    Assert-Status $response 200
    Assert-JsonProperty $response.Content "object" "chat.completion"
    Assert-Contains $response.Content '"finish_reason":"stop"'
  }

  Check "mock-provider chat completion stream 200" {
    $body = $chatBody.Clone()
    $body.stream = $true
    $response = Invoke-SmokeRequest -Method POST -Uri (Join-Url $MockProviderBaseUrl "/v1/chat/completions") -Body $body
    Assert-Status $response 200
    Assert-Contains $response.Content "chat.completion.chunk"
    Assert-Contains $response.Content "data: [DONE]"
  }

  Check "mock-provider scenario 429" {
    $response = Invoke-SmokeRequest -Method POST -Uri (Join-Url $MockProviderBaseUrl "/v1/chat/completions?scenario=429") -Body $chatBody
    Assert-Status $response 429
    Assert-Contains $response.Content "rate_limit_error"
    if ($response.Headers["Retry-After"] -ne "1") {
      throw "expected Retry-After header to be 1"
    }
  }

  Check "mock-provider scenario 5xx" {
    $response = Invoke-SmokeRequest -Method POST -Uri (Join-Url $MockProviderBaseUrl "/v1/chat/completions?scenario=5xx") -Body $chatBody
    Assert-Status $response 502
    Assert-Contains $response.Content "server_error"
  }

  Check "mock-provider body-selected scenario 5xx" {
    $body = $chatBody.Clone()
    $body.mock_scenario = "5xx"
    $response = Invoke-SmokeRequest -Method POST -Uri (Join-Url $MockProviderBaseUrl "/v1/chat/completions") -Body $body
    Assert-Status $response 502
    Assert-Contains $response.Content "server_error"
  }

  Check "mock-provider scenario invalid_sse" {
    $response = Invoke-SmokeRequest -Method POST -Uri (Join-Url $MockProviderBaseUrl "/v1/chat/completions?scenario=invalid_sse") -Body $chatBody
    Assert-Status $response 200
    Assert-Contains $response.Content "data: {not-json}"
  }

  Check "mock-provider scenario large_chunk" {
    $response = Invoke-SmokeRequest -Method POST -Uri (Join-Url $MockProviderBaseUrl "/v1/chat/completions?scenario=large_chunk") -Body $chatBody
    Assert-Status $response 200
    Assert-Contains $response.Content "data: [DONE]"
    if ($response.Content.Length -lt (70 * 1024)) {
      throw "expected response body >= 70KB, got $($response.Content.Length) bytes"
    }
  }

  Check "mock-provider scenario eof" {
    Assert-RequestFails -Method POST -Uri (Join-Url $MockProviderBaseUrl "/v1/chat/completions?scenario=eof") -Body $chatBody -TimeoutSec 3
  }

  Check "mock-provider scenario timeout" {
    Assert-RequestFails -Method POST -Uri (Join-Url $MockProviderBaseUrl "/v1/chat/completions?scenario=timeout") -Body $chatBody -TimeoutSec 3
  }
} finally {
  Pop-Location
}

if ($script:Failures.Count -gt 0) {
  Write-Host ""
  Write-Host "Smoke verification failed:"
  foreach ($failure in $script:Failures) {
    Write-Host $failure
  }
  exit 1
}

Write-Host ""
Write-Host "Smoke verification passed."
