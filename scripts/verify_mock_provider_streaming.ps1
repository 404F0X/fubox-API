param(
  [string]$MockProviderBaseUrl = "http://127.0.0.1:18080",
  [string]$Model = "mock-gpt-4o-mini",
  [ValidateSet("query", "header", "endpoint", "body")]
  [string]$SelectorMode = "query",
  [int]$TimeoutSeconds = 8,
  [int]$FailureTimeoutSeconds = 3,
  [switch]$Offline,
  [switch]$DryRun,
  [switch]$SkipNetwork
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$script:Failures = @()

if ($env:MOCK_PROVIDER_BASE_URL) { $MockProviderBaseUrl = $env:MOCK_PROVIDER_BASE_URL }
if ($env:SMOKE_MODEL) { $Model = $env:SMOKE_MODEL }
if ($env:MOCK_PROVIDER_SELECTOR_MODE) { $SelectorMode = $env:MOCK_PROVIDER_SELECTOR_MODE }

$offlineMode = $Offline -or $DryRun -or $SkipNetwork

function Join-Url {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$Path
  )

  return $BaseUrl.TrimEnd("/") + $Path
}

function New-ChatBody {
  param([string]$Content = "mock-provider streaming probe")

  return [ordered]@{
    model = $Model
    messages = @(@{ role = "user"; content = $Content })
    stream = $true
  }
}

function New-ScenarioRequest {
  param([string]$Scenario = "")

  $headers = @{}
  $path = "/v1/chat/completions"
  $body = New-ChatBody -Content "mock-provider streaming scenario $Scenario"

  if ($Scenario) {
    $escapedScenario = [Uri]::EscapeDataString($Scenario)
    switch ($SelectorMode.ToLowerInvariant()) {
      "query" {
        $path = "/v1/chat/completions?scenario=$escapedScenario"
      }
      "header" {
        $headers["X-Mock-Scenario"] = $Scenario
      }
      "endpoint" {
        $path = "/__scenario/$escapedScenario/v1/chat/completions"
      }
      "body" {
        $body["mock_scenario"] = $Scenario
      }
    }
  }

  return [PSCustomObject]@{
    Uri = Join-Url $MockProviderBaseUrl $path
    Headers = $headers
    Body = $body
  }
}

function Invoke-ProviderRequest {
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [object]$Body = $null,
    [hashtable]$Headers = @{},
    [int]$TimeoutSec = $TimeoutSeconds
  )

  $invokeParams = @{
    Method = "POST"
    Uri = $Uri
    Headers = $Headers
    TimeoutSec = $TimeoutSec
    ErrorAction = "Stop"
  }

  if ($null -ne $Body) {
    $invokeParams.Body = ($Body | ConvertTo-Json -Depth 16 -Compress)
    $invokeParams.ContentType = "application/json"
  }

  if ($PSVersionTable.PSVersion.Major -lt 6) {
    $invokeParams.UseBasicParsing = $true
  }

  $response = Invoke-WebRequest @invokeParams
  return [PSCustomObject]@{
    StatusCode = [int]$response.StatusCode
    Content = [string]$response.Content
    Headers = $response.Headers
  }
}

function Invoke-ProviderGet {
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [int]$TimeoutSec = $TimeoutSeconds
  )

  $invokeParams = @{
    Method = "GET"
    Uri = $Uri
    TimeoutSec = $TimeoutSec
    ErrorAction = "Stop"
  }

  if ($PSVersionTable.PSVersion.Major -lt 6) {
    $invokeParams.UseBasicParsing = $true
  }

  $response = Invoke-WebRequest @invokeParams
  return [PSCustomObject]@{
    StatusCode = [int]$response.StatusCode
    Content = [string]$response.Content
    Headers = $response.Headers
  }
}

function Get-HeaderValue {
  param(
    [Parameter(Mandatory = $true)]$Response,
    [Parameter(Mandatory = $true)][string]$Name
  )

  foreach ($key in $Response.Headers.Keys) {
    if ($key -ieq $Name) {
      return ($Response.Headers[$key] -join ",")
    }
  }

  return ""
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

  $contentType = Get-HeaderValue -Response $Response -Name "Content-Type"
  if (-not $contentType.StartsWith($ExpectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "expected Content-Type to start with '$ExpectedPrefix', got '$contentType'"
  }
}

function Assert-ScenarioHeaders {
  param(
    [Parameter(Mandatory = $true)]$Response,
    [Parameter(Mandatory = $true)][string]$Scenario
  )

  $actualScenario = Get-HeaderValue -Response $Response -Name "X-Mock-Scenario"
  if ($actualScenario -ne $Scenario) {
    throw "expected X-Mock-Scenario=$Scenario, got '$actualScenario'"
  }

  $actualSource = Get-HeaderValue -Response $Response -Name "X-Mock-Scenario-Source"
  if ($actualSource -ne $SelectorMode) {
    throw "expected X-Mock-Scenario-Source=$SelectorMode, got '$actualSource'"
  }
}

function Assert-TransportFailure {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][scriptblock]$Action,
    [string]$MessagePattern = "timed out|canceled|cancelled|closed|premature|forcibly|Unable to read|An error occurred"
  )

  try {
    $response = & $Action
    if ($response.Content.Contains("data: [DONE]")) {
      throw "expected transport failure for $Name, got terminal [DONE]"
    }
  } catch {
    if ($_.Exception.Message -match $MessagePattern) {
      return
    }

    if ($_.Exception.Message.StartsWith("expected transport failure")) {
      throw
    }

    throw "unexpected failure for ${Name}: $($_.Exception.Message)"
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

function Invoke-OfflineChecks {
  $requiredFiles = @(
    "deploy\mock-provider\server.mjs",
    "tests\fixtures\mock-provider\stream_200.json",
    "tests\fixtures\mock-provider\invalid_sse.json",
    "tests\fixtures\mock-provider\invalid_json_chunk.json",
    "tests\fixtures\mock-provider\large_chunk.json",
    "tests\fixtures\mock-provider\missing_done.json",
    "tests\fixtures\mock-provider\stream_timeout.json",
    "tests\fixtures\mock-provider\stream_eof.json",
    "tests\fixtures\mock-provider\scenarios\openai_chat_streaming.json",
    "tests\fixtures\mock-provider\scenarios\chat_stream_valid_done.sse",
    "tests\fixtures\mock-provider\scenarios\chat_stream_invalid_json_chunk.sse",
    "tests\fixtures\mock-provider\scenarios\chat_stream_missing_done.sse",
    "tests\fixtures\gateway\streaming_acceptance.json"
  )

  Check "streaming fixture files exist" {
    foreach ($relativePath in $requiredFiles) {
      $path = Join-Path $repoRoot $relativePath
      if (-not (Test-Path $path)) {
        throw "missing $relativePath"
      }
    }
  }

  Check "streaming JSON fixtures parse" {
    foreach ($relativePath in @($requiredFiles | Where-Object { $_.EndsWith(".json") })) {
      $path = Join-Path $repoRoot $relativePath
      [void](Get-Content -Raw $path | ConvertFrom-Json)
    }
  }

  Check "streaming manifest contains required scenarios" {
    $manifestPath = Join-Path $repoRoot "tests\fixtures\mock-provider\scenarios\openai_chat_streaming.json"
    $manifest = Get-Content -Raw $manifestPath | ConvertFrom-Json
    foreach ($scenario in @("200", "invalid_json_chunk", "large_chunk", "missing_done", "timeout", "eof", "stream_timeout", "stream_eof")) {
      $matches = @($manifest.scenarios | Where-Object { $_.scenario -eq $scenario })
      if ($matches.Count -ne 1) {
        throw "expected one manifest entry for scenario '$scenario'"
      }
    }
  }

  Check "SSE samples contain data events" {
    foreach ($relativePath in @($requiredFiles | Where-Object { $_.EndsWith(".sse") })) {
      $path = Join-Path $repoRoot $relativePath
      $content = Get-Content -Raw $path
      if (-not $content.Contains("data: ")) {
        throw "$relativePath does not contain SSE data events"
      }
    }
  }

  Check "mock-provider server syntax" {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) {
      Write-Host "[SKIP] node is not available; skipped node --check"
      return
    }

    Push-Location $repoRoot
    try {
      & node --check "deploy/mock-provider/server.mjs"
      if ($LASTEXITCODE -ne 0) {
        throw "node --check failed with exit code $LASTEXITCODE"
      }
    } finally {
      Pop-Location
    }
  }
}

Push-Location $repoRoot
try {
  Invoke-OfflineChecks

  if ($offlineMode) {
    Write-Host ""
    Write-Host "Mock-provider streaming verification skipped network checks."
  } else {
    Check "mock-provider healthz" {
      $response = Invoke-ProviderGet -Uri (Join-Url $MockProviderBaseUrl "/healthz")
      Assert-Status $response 200
      Assert-Contains $response.Content '"status":"ok"'
    }

    Check "normal stream contains chunks and DONE" {
      $request = New-ScenarioRequest
      $response = Invoke-ProviderRequest -Uri $request.Uri -Headers $request.Headers -Body $request.Body
      Assert-Status $response 200
      Assert-ContentType $response "text/event-stream"
      Assert-Contains $response.Content "chat.completion.chunk"
      Assert-Contains $response.Content "data: [DONE]"
    }

    Check "selected invalid_json_chunk stream contains invalid JSON event" {
      $request = New-ScenarioRequest -Scenario "invalid_json_chunk"
      $response = Invoke-ProviderRequest -Uri $request.Uri -Headers $request.Headers -Body $request.Body
      Assert-Status $response 200
      Assert-ContentType $response "text/event-stream"
      Assert-ScenarioHeaders $response "invalid_json_chunk"
      Assert-Contains $response.Content "data: {not-json}"
      Assert-Contains $response.Content "data: [DONE]"
    }

    Check "selected large_chunk stream contains DONE and large payload" {
      $request = New-ScenarioRequest -Scenario "large_chunk"
      $response = Invoke-ProviderRequest -Uri $request.Uri -Headers $request.Headers -Body $request.Body
      Assert-Status $response 200
      Assert-ContentType $response "text/event-stream"
      Assert-ScenarioHeaders $response "large_chunk"
      Assert-Contains $response.Content "data: [DONE]"
      if ($response.Content.Length -lt (70 * 1024)) {
        throw "expected response body >= 70KB, got $($response.Content.Length) bytes"
      }
    }

    Check "selected missing_done stream omits DONE" {
      $request = New-ScenarioRequest -Scenario "missing_done"
      $response = Invoke-ProviderRequest -Uri $request.Uri -Headers $request.Headers -Body $request.Body
      Assert-Status $response 200
      Assert-ContentType $response "text/event-stream"
      Assert-ScenarioHeaders $response "missing_done"
      Assert-Contains $response.Content "chat.completion.chunk"
      Assert-NotContains $response.Content "data: [DONE]"
    }

    Check "selected eof closes before response" {
      $request = New-ScenarioRequest -Scenario "eof"
      Assert-TransportFailure -Name "eof" {
        Invoke-ProviderRequest -Uri $request.Uri -Headers $request.Headers -Body $request.Body -TimeoutSec $FailureTimeoutSeconds
      }
    }

    Check "selected timeout times out before first byte" {
      $request = New-ScenarioRequest -Scenario "timeout"
      Assert-TransportFailure -Name "timeout" -MessagePattern "timed out|canceled|cancelled|TaskCanceled" {
        Invoke-ProviderRequest -Uri $request.Uri -Headers $request.Headers -Body $request.Body -TimeoutSec $FailureTimeoutSeconds
      }
    }

    Check "selected stream_eof closes before DONE" {
      $request = New-ScenarioRequest -Scenario "stream_eof"
      Assert-TransportFailure -Name "stream_eof" {
        Invoke-ProviderRequest -Uri $request.Uri -Headers $request.Headers -Body $request.Body -TimeoutSec $FailureTimeoutSeconds
      }
    }

    Check "selected stream_timeout times out before DONE" {
      $request = New-ScenarioRequest -Scenario "stream_timeout"
      Assert-TransportFailure -Name "stream_timeout" -MessagePattern "timed out|canceled|cancelled|TaskCanceled" {
        Invoke-ProviderRequest -Uri $request.Uri -Headers $request.Headers -Body $request.Body -TimeoutSec $FailureTimeoutSeconds
      }
    }
  }
} finally {
  Pop-Location
}

if ($script:Failures.Count -gt 0) {
  Write-Host ""
  Write-Host "Mock-provider streaming verification failed:"
  foreach ($failure in $script:Failures) {
    Write-Host $failure
  }
  exit 1
}

Write-Host ""
Write-Host "Mock-provider streaming verification passed."
