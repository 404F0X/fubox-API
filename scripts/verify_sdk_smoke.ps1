param(
  [string]$GatewayBaseUrl = "http://127.0.0.1:8080",
  [string]$GatewayAuthToken = "dev_test_key_123456789",
  [string]$Model = "mock-gpt-4o-mini",
  [switch]$SkipInstall,
  [switch]$IncludeStreaming,
  [switch]$AllowStreamingSkip,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Test-TruthyEnv {
  param([string]$Value)

  return $Value -eq "1" -or $Value -match "^(true|yes|on)$"
}

if ($env:GATEWAY_BASE_URL) { $GatewayBaseUrl = $env:GATEWAY_BASE_URL }
if ($env:GATEWAY_AUTH_TOKEN) { $GatewayAuthToken = $env:GATEWAY_AUTH_TOKEN }
if ($env:SMOKE_MODEL) { $Model = $env:SMOKE_MODEL }
if (Test-TruthyEnv $env:SDK_SMOKE_INCLUDE_STREAMING) { $IncludeStreaming = $true }
if (Test-TruthyEnv $env:SDK_SMOKE_ALLOW_STREAMING_SKIP) { $AllowStreamingSkip = $true }
if (Test-TruthyEnv $env:SDK_SMOKE_DRY_RUN) { $DryRun = $true }

$sdkDir = Resolve-Path (Join-Path $PSScriptRoot "..\tests\integration\sdk-smoke")

Push-Location $sdkDir
try {
  if (-not $SkipInstall -and -not $DryRun) {
    npm ci --ignore-scripts --no-audit --fund=false
    if ($LASTEXITCODE -ne 0) { throw "npm ci failed with exit code $LASTEXITCODE" }
  }

  $env:GATEWAY_BASE_URL = $GatewayBaseUrl
  $env:GATEWAY_AUTH_TOKEN = $GatewayAuthToken
  $env:SMOKE_MODEL = $Model
  if ($IncludeStreaming) {
    $env:SDK_SMOKE_INCLUDE_STREAMING = "1"
  } else {
    Remove-Item Env:\SDK_SMOKE_INCLUDE_STREAMING -ErrorAction SilentlyContinue
  }
  if ($AllowStreamingSkip) {
    $env:SDK_SMOKE_ALLOW_STREAMING_SKIP = "1"
  } else {
    Remove-Item Env:\SDK_SMOKE_ALLOW_STREAMING_SKIP -ErrorAction SilentlyContinue
  }

  if ($DryRun) {
    npm run check
    if ($LASTEXITCODE -ne 0) { throw "SDK smoke syntax check failed with exit code $LASTEXITCODE" }

    Write-Host "SDK smoke dry-run passed; runtime requests were not sent. IncludeStreaming=$IncludeStreaming AllowStreamingSkip=$AllowStreamingSkip"
    return
  }

  npm run smoke
  if ($LASTEXITCODE -ne 0) { throw "SDK smoke failed with exit code $LASTEXITCODE" }
} finally {
  Pop-Location
}
