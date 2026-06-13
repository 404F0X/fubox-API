param(
  [string]$GatewayBaseUrl = "http://127.0.0.1:8080",
  [string]$GatewayAuthToken = "dev_test_key_123456789",
  [string]$Model = "mock-gpt-4o-mini",
  [switch]$SkipInstall,
  [switch]$IncludeStreaming,
  [switch]$AllowStreamingSkip,
  [switch]$ContractOnly,
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
if (Test-TruthyEnv $env:SDK_SMOKE_CONTRACT_ONLY) { $ContractOnly = $true }
if (Test-TruthyEnv $env:SDK_SMOKE_DRY_RUN) { $DryRun = $true }

$sdkDir = Resolve-Path (Join-Path $PSScriptRoot "..\tests\integration\sdk-smoke")
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$protocolContractPath = Join-Path $repoRoot "tests\fixtures\gateway\api_distribution_protocol_contract.json"
$sdkSmokeSourcePath = Join-Path $sdkDir "sdk_smoke.mjs"

function Assert-True {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Message
  )

  if (-not $Condition) {
    throw $Message
  }
}

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path $Path)) {
    throw "missing contract file: $Path"
  }

  try {
    return Get-Content -Raw $Path | ConvertFrom-Json
  } catch {
    throw "contract file is not valid JSON: $Path - $($_.Exception.Message)"
  }
}

function Test-SourceContains {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Needle
  )

  return $Source.Contains($Needle)
}

function Invoke-GatewayProtocolContractAudit {
  $contract = Read-JsonFile -Path $protocolContractPath
  Assert-True ($contract.scenario -eq "gateway_api_distribution_protocol_contract_v1") "unexpected protocol contract scenario"

  if (-not (Test-Path $sdkSmokeSourcePath)) {
    throw "missing SDK smoke source: $sdkSmokeSourcePath"
  }

  $sdkSource = Get-Content -Raw $sdkSmokeSourcePath
  $requiredNames = @(
    "openai_chat_stream",
    "openai_responses_stream_terminal",
    "anthropic_messages",
    "gemini_generate_content",
    "models_gateway_filtering"
  )
  foreach ($name in $requiredNames) {
    $matches = @($contract.endpoints | Where-Object { $_.name -eq $name })
    Assert-True ($matches.Count -eq 1) "protocol contract must define endpoint '$name' exactly once"
  }

  Assert-True (Test-Path (Join-Path $repoRoot "tests\fixtures\gateway\streaming_acceptance.json")) "missing OpenAI chat stream fixture"
  Assert-True (Test-Path (Join-Path $repoRoot "tests\fixtures\gateway\responses_stream_runtime_contract.json")) "missing Responses stream fixture"
  Assert-True (Test-Path (Join-Path $repoRoot "tests\fixtures\gateway\anthropic_messages_runtime_contract.json")) "missing Anthropic Messages fixture"
  Assert-True (Test-Path (Join-Path $repoRoot "tests\fixtures\gateway\gemini_generate_content_stream_runtime_contract.json")) "missing Gemini GenerateContent fixture"

  $sdkCoverage = [ordered]@{
    openai_chat_non_stream = (Test-SourceContains $sdkSource "client.chat.completions.create") -and (Test-SourceContains $sdkSource "stream: false")
    openai_chat_stream = (Test-SourceContains $sdkSource "SDK_SMOKE_INCLUDE_STREAMING") -and (Test-SourceContains $sdkSource "stream: true")
    openai_responses_stream_terminal = Test-SourceContains $sdkSource "client.responses"
    anthropic_messages = Test-SourceContains $sdkSource "/v1/messages"
    gemini_generate_content = Test-SourceContains $sdkSource "generateContent"
    models_gateway_filtering = Test-SourceContains $sdkSource "/v1/models"
  }

  $statuses = @()
  foreach ($endpoint in $contract.endpoints) {
    $status = [string]$endpoint.expected_status
    if ([string]::IsNullOrWhiteSpace($status)) {
      $status = "blocker"
    }

    $sdkKey = [string]$endpoint.name
    if ($sdkKey -eq "openai_responses_stream_terminal") { $sdkCovered = [bool]$sdkCoverage.openai_responses_stream_terminal }
    elseif ($sdkKey -eq "models_gateway_filtering") { $sdkCovered = [bool]$sdkCoverage.models_gateway_filtering }
    else { $sdkCovered = [bool]$sdkCoverage[$sdkKey] }

    $statuses += [ordered]@{
      name = $endpoint.name
      path = $endpoint.path
      status = $status
      sdk_smoke_covered = $sdkCovered
      gateway_contract = $endpoint.coverage.gateway_contract
    }
  }

  $summary = [ordered]@{
    schema = "gateway_protocol_contract_audit_v1"
    contract = "tests/fixtures/gateway/api_distribution_protocol_contract.json"
    sdk_smoke = "tests/integration/sdk-smoke/sdk_smoke.mjs"
    sdk_coverage = $sdkCoverage
    endpoints = $statuses
  }

  $summary | ConvertTo-Json -Depth 8
}

if ($ContractOnly) {
  Invoke-GatewayProtocolContractAudit
  return
}

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

    Invoke-GatewayProtocolContractAudit
    Write-Host "SDK smoke dry-run passed; runtime requests were not sent. IncludeStreaming=$IncludeStreaming AllowStreamingSkip=$AllowStreamingSkip"
    return
  }

  npm run smoke
  if ($LASTEXITCODE -ne 0) { throw "SDK smoke failed with exit code $LASTEXITCODE" }
} finally {
  Pop-Location
}
