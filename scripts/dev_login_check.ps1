<#
.SYNOPSIS
Checks the local New API style MVP smoke path.

.DESCRIPTION
Verifies control-plane health, admin login, user registration, user voucher
redeem, user API key creation, gateway /v1/models, mock non-stream and stream
chat completions, user request log readback, and admin request detail readback.
Failures identify local stack, seed data, or MVP feature gaps; this is not a
production gate.
#>
param(
  [string]$ControlPlaneBaseUrl = "http://127.0.0.1:8081",
  [string]$GatewayBaseUrl = "http://127.0.0.1:8080",
  [string]$AdminUiBaseUrl = "http://127.0.0.1:5173",
  [string]$AdminEmail = "admin@example.com",
  [string]$AdminPassword = "local-password",
  [string]$GatewayAuthToken = "dev_test_key_123456789",
  [string]$Model = "mock-gpt-4o-mini",
  [string]$ForbiddenModels = "",
  [int]$TimeoutSeconds = 12,
  [string]$ArtifactPath = ".tmp/dev_login_check_artifact.json"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

function Test-SystemTempPath {
  param([AllowNull()][string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) { return $true }

  try {
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
  } catch {
    return $false
  }

  $candidates = @()
  if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA "Temp") }
  if ($env:USERPROFILE) { $candidates += (Join-Path $env:USERPROFILE "AppData\Local\Temp") }
  if ($env:WINDIR) { $candidates += (Join-Path $env:WINDIR "Temp") }
  $candidates += "C:\Windows\Temp"

  foreach ($candidate in $candidates) {
    try {
      $candidatePath = [System.IO.Path]::GetFullPath($candidate).TrimEnd("\", "/")
      if ([string]::Equals($fullPath, $candidatePath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
      }
    } catch {
      continue
    }
  }

  return $false
}

function Set-ProjectDefaultEnvironment {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Value,
    [switch]$TreatSystemTempAsUnset
  )

  $current = [System.Environment]::GetEnvironmentVariable($Name, "Process")
  $shouldSet = [string]::IsNullOrWhiteSpace($current)
  if (-not $shouldSet -and $TreatSystemTempAsUnset) {
    $shouldSet = Test-SystemTempPath -Path $current
  }

  if ($shouldSet) {
    [System.Environment]::SetEnvironmentVariable($Name, $Value, "Process")
  }
}

function Initialize-ProjectLocalCache {
  $tempDir = Join-Path $repoRoot ".tmp"
  $npmCacheDir = Join-Path $repoRoot ".tool-cache\npm"
  $cargoTargetDir = Join-Path $repoRoot "target-codex"

  foreach ($path in @($tempDir, $npmCacheDir, $cargoTargetDir)) {
    if (-not (Test-Path -LiteralPath $path)) {
      New-Item -ItemType Directory -Force -Path $path | Out-Null
    }
  }

  Set-ProjectDefaultEnvironment -Name "TEMP" -Value $tempDir -TreatSystemTempAsUnset
  Set-ProjectDefaultEnvironment -Name "TMP" -Value $tempDir -TreatSystemTempAsUnset
  Set-ProjectDefaultEnvironment -Name "npm_config_cache" -Value $npmCacheDir
  Set-ProjectDefaultEnvironment -Name "CARGO_TARGET_DIR" -Value $cargoTargetDir

  Write-Host "[dev-login-check] local temp/cache: TEMP=$env:TEMP; TMP=$env:TMP; npm_config_cache=$env:npm_config_cache; CARGO_TARGET_DIR=$env:CARGO_TARGET_DIR"
}

Initialize-ProjectLocalCache

if ($env:CONTROL_PLANE_BASE_URL) { $ControlPlaneBaseUrl = [string]$env:CONTROL_PLANE_BASE_URL }
if ($env:GATEWAY_BASE_URL) { $GatewayBaseUrl = [string]$env:GATEWAY_BASE_URL }
if ($env:ADMIN_UI_BASE_URL) { $AdminUiBaseUrl = [string]$env:ADMIN_UI_BASE_URL }
if ($env:GATEWAY_FORBIDDEN_MODELS) { $ForbiddenModels = [string]$env:GATEWAY_FORBIDDEN_MODELS }

$runId = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
$userEmail = "dev-user-$runId@example.com"
$userPassword = "local-password-$runId"
$voucherCode = "dev-voucher-$runId"
$nonStreamTraceId = "dev-login-check-$runId-non-stream"
$streamTraceId = "dev-login-check-$runId-stream"
$sensitiveValues = New-Object System.Collections.Generic.List[string]

function Add-SensitiveValue {
  param([AllowNull()][string]$Value)
  if (-not [string]::IsNullOrWhiteSpace($Value)) {
    [void]$sensitiveValues.Add($Value)
  }
}

function ConvertTo-SafeText {
  param([AllowNull()][string]$Text)

  if ([string]::IsNullOrEmpty($Text)) { return $Text }
  $safe = $Text
  foreach ($value in $sensitiveValues) {
    if (-not [string]::IsNullOrEmpty($value)) {
      $safe = $safe.Replace($value, "[REDACTED]")
    }
  }
  foreach ($value in @($AdminPassword, $GatewayAuthToken, $userPassword)) {
    if (-not [string]::IsNullOrEmpty($value)) {
      $safe = $safe.Replace($value, "[REDACTED]")
    }
  }
  $safe = $safe -replace '(?i)Bearer\s+[A-Za-z0-9._~+/=-]+', 'Bearer [REDACTED]'
  $safe = $safe -replace '(?i)(session_token_once"\s*:\s*")[^"]+', '$1[REDACTED]'
  $safe = $safe -replace '(?i)(secret"\s*:\s*")[^"]+', '$1[REDACTED]'
  return $safe
}

function Join-Url {
  param(
    [string]$BaseUrl,
    [string]$Path
  )

  return $BaseUrl.TrimEnd("/") + "/" + $Path.TrimStart("/")
}

function Read-ErrorBody {
  param([System.Management.Automation.ErrorRecord]$ErrorRecord)

  $response = $ErrorRecord.Exception.Response
  if ($null -eq $response) {
    return $ErrorRecord.Exception.Message
  }

  try {
    $stream = $response.GetResponseStream()
    if ($null -eq $stream) { return $ErrorRecord.Exception.Message }
    $reader = [System.IO.StreamReader]::new($stream)
    try {
      return $reader.ReadToEnd()
    } finally {
      $reader.Dispose()
    }
  } catch {
    return $ErrorRecord.Exception.Message
  }
}

function Invoke-Json {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Uri,
    [hashtable]$Headers = @{},
    [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession,
    [AllowNull()]$Body = $null
  )

  try {
    $args = @{
      Method = $Method
      Uri = $Uri
      TimeoutSec = $TimeoutSeconds
      Headers = $Headers
    }
    if ($WebSession) {
      $args.WebSession = $WebSession
    }
    if ($null -ne $Body) {
      $args.ContentType = "application/json"
      $args.Body = ($Body | ConvertTo-Json -Depth 20 -Compress)
    }
    return Invoke-RestMethod @args
  } catch {
    $status = $null
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
      $status = [int]$_.Exception.Response.StatusCode
    }
    $body = ConvertTo-SafeText (Read-ErrorBody -ErrorRecord $_)
    $statusText = if ($null -ne $status) { " HTTP $status." } else { "" }
    throw "$Name failed.$statusText $body"
  }
}

function Get-HeaderValue {
  param(
    [Parameter(Mandatory = $true)]$Headers,
    [Parameter(Mandatory = $true)][string]$Name
  )

  foreach ($key in $Headers.Keys) {
    if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
      $value = $Headers[$key]
      if ($value -is [array]) {
        return [string]($value | Select-Object -First 1)
      }
      return [string]$value
    }
  }

  return $null
}

function Invoke-JsonWithHeaders {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Uri,
    [hashtable]$Headers = @{},
    [AllowNull()]$Body = $null
  )

  try {
    $args = @{
      Method = $Method
      Uri = $Uri
      TimeoutSec = $TimeoutSeconds
      Headers = $Headers
      UseBasicParsing = $true
    }
    if ($null -ne $Body) {
      $args.ContentType = "application/json"
      $args.Body = ($Body | ConvertTo-Json -Depth 20 -Compress)
    }
    $response = Invoke-WebRequest @args
    $json = if ([string]::IsNullOrWhiteSpace([string]$response.Content)) {
      $null
    } else {
      $response.Content | ConvertFrom-Json
    }
    return [pscustomobject]@{
      status_code = [int]$response.StatusCode
      headers = $response.Headers
      json = $json
      raw = [string]$response.Content
      request_id = Get-HeaderValue -Headers $response.Headers -Name "x-request-id"
      trace_id = Get-HeaderValue -Headers $response.Headers -Name "x-trace-id"
    }
  } catch {
    $status = $null
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
      $status = [int]$_.Exception.Response.StatusCode
    }
    $body = ConvertTo-SafeText (Read-ErrorBody -ErrorRecord $_)
    $statusText = if ($null -ne $status) { " HTTP $status." } else { "" }
    throw "$Name failed.$statusText $body"
  }
}

function Invoke-StreamChat {
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [Parameter(Mandatory = $true)][hashtable]$Headers,
    [Parameter(Mandatory = $true)]$Body
  )

  try {
    $response = Invoke-WebRequest -Method "POST" -Uri $Uri -TimeoutSec $TimeoutSeconds -Headers $Headers -ContentType "application/json" -Body ($Body | ConvertTo-Json -Depth 20 -Compress) -UseBasicParsing
    $content = [string]$response.Content
    $hasData = $content -match '(?m)^data:\s*'
    $hasDone = $content -match '\[DONE\]'
    if (-not $hasData) {
      throw "stream response did not include SSE data frames."
    }
    if (-not $hasDone) {
      throw "stream response did not include [DONE]."
    }
    return [pscustomobject]@{
      status_code = [int]$response.StatusCode
      headers = $response.Headers
      request_id = Get-HeaderValue -Headers $response.Headers -Name "x-request-id"
      trace_id = Get-HeaderValue -Headers $response.Headers -Name "x-trace-id"
      data_frame_count = ([regex]::Matches($content, '(?m)^data:\s*')).Count
      done_present = $hasDone
    }
  } catch {
    $status = $null
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
      $status = [int]$_.Exception.Response.StatusCode
    }
    $body = ConvertTo-SafeText (Read-ErrorBody -ErrorRecord $_)
    $message = if ([string]::IsNullOrWhiteSpace($body)) { $_.Exception.Message } else { $body }
    $statusText = if ($null -ne $status) { " HTTP $status." } else { "" }
    throw "gateway /v1/chat/completions stream failed.$statusText $(ConvertTo-SafeText $message)"
  }
}

function Invoke-WebCheck {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Uri
  )

  try {
    $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec $TimeoutSeconds
    if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 500) {
      throw "$Name returned HTTP $($response.StatusCode)"
    }
    return $response
  } catch {
    throw "$Name failed. $(ConvertTo-SafeText $_.Exception.Message)"
  }
}

function Write-Pass {
  param([string]$Name)
  Write-Host "[pass] $Name"
}

function Add-SmokeStep {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Status,
    [hashtable]$Evidence = @{}
  )

  $safeEvidence = [ordered]@{}
  foreach ($key in $Evidence.Keys) {
    $value = $Evidence[$key]
    if ($null -eq $value) {
      $safeEvidence[$key] = $null
    } elseif ($value -is [string]) {
      $safeEvidence[$key] = ConvertTo-SafeText $value
    } else {
      $safeEvidence[$key] = $value
    }
  }

  [void]$script:artifactSteps.Add([pscustomobject]@{
    name = $Name
    status = $Status
    evidence = [pscustomobject]$safeEvidence
  })
}

function Test-ArtifactSecretSafe {
  param([Parameter(Mandatory = $true)][string]$Json)

  foreach ($value in $sensitiveValues) {
    if (-not [string]::IsNullOrEmpty($value) -and $Json.Contains($value)) {
      return $false
    }
  }
  foreach ($value in @($AdminPassword, $GatewayAuthToken, $userPassword, $voucherCode)) {
    if (-not [string]::IsNullOrEmpty($value) -and $Json.Contains($value)) {
      return $false
    }
  }

  return $Json -notmatch '(?i)Bearer\s+[A-Za-z0-9._~+/=-]+' -and
    $Json -notmatch '(?i)"secret"\s*:\s*"[^"]+"' -and
    $Json -notmatch '(?i)"session_token_once"\s*:\s*"[^"]+"'
}

function New-GatewayUserMvpSummary {
  return [ordered]@{
    schema = "fubox_gateway_user_mvp_summary.v1"
    artifact_kind = "local_mvp_smoke_summary"
    local_only = $true
    production_evidence = $false
    secret_safe = $true
    model = $Model
    gateway_models = [ordered]@{
      endpoint = "/v1/models"
      status = if ($script:artifactEvidence.models.gateway_models_contains_expected) { "pass" } else { "not_passed" }
      contains_expected_model = [bool]$script:artifactEvidence.models.gateway_models_contains_expected
      forbidden_models_absent = $script:artifactEvidence.models.gateway_forbidden_models_absent
    }
    gateway_requests = [ordered]@{
      non_stream = [ordered]@{
        endpoint = "/v1/chat/completions"
        stream = $false
        status = if ($script:artifactEvidence.gateway.non_stream_chat_completion_choices_present) { "pass" } else { "not_passed" }
        request_id = $script:artifactEvidence.gateway.non_stream_request_id
        trace_id = $script:artifactEvidence.gateway.non_stream_trace_id
      }
      stream = [ordered]@{
        endpoint = "/v1/chat/completions"
        stream = $true
        status = if ($script:artifactEvidence.gateway.stream_chat_sse_present) { "pass" } else { "not_passed" }
        request_id = $script:artifactEvidence.gateway.stream_request_id
        trace_id = $script:artifactEvidence.gateway.stream_trace_id
      }
    }
    readback = [ordered]@{
      user_request_logs = [ordered]@{
        non_stream_status = if ($script:artifactEvidence.request_log.non_stream_user_request_log_found) { "pass" } else { "not_passed" }
        non_stream_request_id = $script:artifactEvidence.request_log.non_stream_request_id
        non_stream_trace_id = $script:artifactEvidence.request_log.non_stream_trace_id
        stream_status = if ($script:artifactEvidence.request_log.stream_user_request_log_found) { "pass" } else { "not_passed" }
        stream_request_id = $script:artifactEvidence.request_log.stream_request_id
        stream_trace_id = $script:artifactEvidence.request_log.stream_trace_id
      }
      admin_request_detail = [ordered]@{
        status = if ($script:artifactEvidence.request_log.admin_detail_readback) { "pass" } else { "not_passed" }
        readback_count = [int]$script:artifactEvidence.request_log.admin_detail_readback_count
        non_stream_ledger_settled = [bool]$script:artifactEvidence.request_log.ledger_settled
      }
    }
  }
}

function Write-SmokeArtifact {
  param(
    [Parameter(Mandatory = $true)][string]$Status,
    [AllowNull()][string]$FailureReason = $null
  )

  $stage = "prepare_failure_reason"
  try {
  $safeFailureReason = $null
  if ($FailureReason) {
    $safeFailureReason = ConvertTo-SafeText $FailureReason
  }

  $stage = "build_artifact"
  $stage = "build_endpoints"
  $endpoints = [System.Collections.Specialized.OrderedDictionary]::new()
  $endpoints.Add("control_plane", $ControlPlaneBaseUrl)
  $endpoints.Add("gateway", $GatewayBaseUrl)
  $endpoints.Add("admin_ui", $AdminUiBaseUrl)

  $stage = "build_artifact_schema"
  $artifact = [System.Collections.Specialized.OrderedDictionary]::new()
  $artifact.Add("schema", "fubox_dev_login_check.v1")
  $stage = "build_artifact_status"
  $artifact.Add("status", $Status)
  $stage = "build_artifact_generated_at"
  $artifact.Add("generated_at_utc", (Get-Date).ToUniversalTime().ToString("o"))
  $stage = "build_artifact_run_id"
  $artifact.Add("run_id", $runId)
  $stage = "build_artifact_endpoints"
  $artifact.Add("endpoints", $endpoints)
  $stage = "build_artifact_model"
  $artifact.Add("model", $Model)
  $stage = "build_local_mvp_summary"
  $artifact.Add("gateway_user_mvp_summary", (New-GatewayUserMvpSummary))
  $stage = "build_artifact_checks_collect"
  $checkList = [System.Collections.ArrayList]::new()
  for ($index = 0; $index -lt $script:artifactSteps.Count; $index++) {
    $step = $script:artifactSteps[$index]
    [void]$checkList.Add([object]$step)
  }
  $stage = "build_artifact_checks_add"
  $artifact.Add("checks", [object]$checkList)
  $stage = "build_artifact_evidence"
  $artifact.Add("evidence", $script:artifactEvidence)
  $stage = "build_artifact_failure_reason"
  $artifact.Add("failure_reason", $safeFailureReason)
  $stage = "build_artifact_secret_safe"
  $artifact.Add("secret_safe", $true)
  $stage = "build_artifact_raw_admin_session"
  $artifact.Add("raw_admin_session_echoed", $false)
  $stage = "build_artifact_raw_user_session"
  $artifact.Add("raw_user_session_echoed", $false)
  $stage = "build_artifact_raw_user_api_key"
  $artifact.Add("raw_user_api_key_echoed", $false)
  $stage = "build_artifact_raw_gateway_key"
  $artifact.Add("raw_gateway_key_echoed", $false)
  $stage = "build_artifact_raw_voucher_code"
  $artifact.Add("raw_voucher_code_echoed", $false)

  $stage = "serialize_artifact"
  $json = $artifact | ConvertTo-Json -Depth 24
  $stage = "secret_safety_check"
  if (-not (Test-ArtifactSecretSafe -Json $json)) {
    throw "dev_login_check artifact failed secret-safety validation."
  }

  $stage = "resolve_artifact_path"
  $fullPath = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $ArtifactPath))
  $directory = Split-Path -Parent $fullPath
  $stage = "ensure_artifact_directory"
  if (-not (Test-Path -LiteralPath $directory)) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
  }
  $stage = "write_artifact"
  Set-Content -LiteralPath $fullPath -Value $json -Encoding UTF8
  Write-Host "artifact=$fullPath"
  } catch {
    throw "artifact_stage=$stage; $($_.Exception.Message)"
  }
}

function Assert-ReadinessCheckNotBlocked {
  param(
    [Parameter(Mandatory = $true)]$Readiness,
    [Parameter(Mandatory = $true)][string]$Code
  )

  $check = @($Readiness.data.checks | Where-Object { $_.code -eq $Code } | Select-Object -First 1)
  if (-not $check) {
    throw "user readiness did not include required check '$Code'."
  }
  if ([string]$check[0].status -eq "blocked") {
    throw "user readiness check '$Code' is blocked. $($check[0].detail) Next: $($check[0].next_action)"
  }
}

function Wait-UserRequestLog {
  param(
    [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession,
    [string]$Model,
    [AllowNull()][string]$TraceId = $null,
    [AllowNull()][string]$RequestId = $null
  )

  $deadline = (Get-Date).AddSeconds([Math]::Max(8, $TimeoutSeconds))
  $lastCount = 0
  do {
    $logs = Invoke-Json -Name "user request logs" -Method "GET" -Uri (Join-Url $ControlPlaneBaseUrl "/user/request-logs?limit=10") -WebSession $WebSession
    $rows = @($logs.data)
    $lastCount = $rows.Count
    $matching = @($rows | Where-Object {
      $modelMatches = [string]$_.requested_model -eq $Model -or [string]$_.upstream_model -eq $Model
      $traceMatches = [string]::IsNullOrWhiteSpace($TraceId) -or [string]$_.trace_id -eq $TraceId
      $requestMatches = [string]::IsNullOrWhiteSpace($RequestId) -or [string]$_.id -eq $RequestId
      $modelMatches -and $traceMatches -and $requestMatches
    })
    if ($matching.Count -gt 0) {
      return $matching[0]
    }
    Start-Sleep -Seconds 1
  } while ((Get-Date) -lt $deadline)

  throw "user request logs did not include model '$Model' after gateway chat. trace_id=$TraceId request_id=$RequestId observed_logs=$lastCount"
}

function Read-AdminRequestDetail {
  param(
    [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession,
    [string]$RequestId,
    [AllowNull()][string]$TraceId = $null,
    [switch]$RequireSettledLedger
  )

  if ([string]::IsNullOrWhiteSpace($RequestId)) {
    throw "cannot verify admin request detail without a request id."
  }

  $detail = Invoke-Json -Name "admin request log detail" -Method "GET" -Uri (Join-Url $ControlPlaneBaseUrl "/admin/request-logs/$RequestId") -WebSession $WebSession
  if ([string]$detail.data.request_log.id -ne $RequestId) {
    throw "admin request log detail returned unexpected request id."
  }
  if (-not [string]::IsNullOrWhiteSpace($TraceId) -and [string]$detail.data.request_log.trace_id -ne $TraceId) {
    throw "admin request log detail returned unexpected trace id. expected=$TraceId actual=$($detail.data.request_log.trace_id)"
  }

  $ledger = $detail.data.ledger
  if ($RequireSettledLedger -and ($null -eq $ledger -or [int]$ledger.returned_count -lt 1)) {
    throw "admin request log detail did not return ledger entries for request '$RequestId'."
  }

  $entries = @($ledger.entries)
  $settled = @(
    $entries | Where-Object {
      [string]$_.request_id -eq $RequestId -and
      [string]$_.entry_type -eq "settle" -and
      [string]$_.status -eq "confirmed" -and
      [string]$_.currency -eq "USD" -and
      ([decimal]([string]$_.amount)) -lt 0
    }
  )
  if ($RequireSettledLedger -and $settled.Count -lt 1) {
    $observed = $entries | ConvertTo-Json -Depth 8 -Compress
    throw "admin request log detail did not include a confirmed negative USD settle ledger entry for request '$RequestId'. observed=$(ConvertTo-SafeText $observed)"
  }

  return [pscustomobject]@{
    detail = $detail
    ledger_settled = ($settled.Count -ge 1)
    ledger_returned_count = if ($null -eq $ledger) { 0 } else { [int]$ledger.returned_count }
  }
}

Add-SensitiveValue $AdminPassword
Add-SensitiveValue $GatewayAuthToken
Add-SensitiveValue $userPassword
Add-SensitiveValue $voucherCode

$checks = New-Object System.Collections.Generic.List[string]
$artifactSteps = New-Object System.Collections.Generic.List[object]
$artifactEvidence = [ordered]@{
  admin_login = [ordered]@{ email = $AdminEmail; session_token_once_present = $false }
  user = [ordered]@{ email = $userEmail; registered = $false; user_id = $null; tenant_id = $null; project_id = $null }
  voucher = [ordered]@{ issued = $false; redeemed = $false; raw_code_echoed = $false }
  balance = [ordered]@{ wallet_id = $null; available_to_spend_usd = $null }
  models = [ordered]@{ user_models_contains_expected = $false; gateway_models_contains_expected = $false; gateway_forbidden_models_absent = $null }
  gateway = [ordered]@{
    user_api_key_created = $false
    non_stream_chat_completion_choices_present = $false
    non_stream_request_id = $null
    non_stream_trace_id = $nonStreamTraceId
    stream_chat_sse_present = $false
    stream_request_id = $null
    stream_trace_id = $streamTraceId
  }
  request_log = [ordered]@{
    non_stream_user_request_log_found = $false
    non_stream_request_id = $null
    non_stream_trace_id = $nonStreamTraceId
    stream_user_request_log_found = $false
    stream_request_id = $null
    stream_trace_id = $streamTraceId
    admin_detail_readback = $false
    admin_detail_readback_count = 0
    ledger_settled = $false
  }
}
$adminSession = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
$userSession = [Microsoft.PowerShell.Commands.WebRequestSession]::new()

try {
  Invoke-Json -Name "control-plane health" -Method "GET" -Uri (Join-Url $ControlPlaneBaseUrl "/healthz") | Out-Null
  $checks.Add("control-plane /healthz") | Out-Null
  Add-SmokeStep -Name "control-plane /healthz" -Status "pass"
  Write-Pass "control-plane /healthz"

  Invoke-Json -Name "control-plane ready" -Method "GET" -Uri (Join-Url $ControlPlaneBaseUrl "/readyz") | Out-Null
  $checks.Add("control-plane /readyz") | Out-Null
  Add-SmokeStep -Name "control-plane /readyz" -Status "pass"
  Write-Pass "control-plane /readyz"

  Invoke-WebCheck -Name "admin-ui" -Uri $AdminUiBaseUrl | Out-Null
  $checks.Add("admin-ui") | Out-Null
  Add-SmokeStep -Name "admin-ui" -Status "pass" -Evidence @{ url = $AdminUiBaseUrl }
  Write-Pass "admin-ui reachable"

  $adminLogin = Invoke-Json -Name "admin login" -Method "POST" -Uri (Join-Url $ControlPlaneBaseUrl "/admin/auth/login") -Body @{
    email = $AdminEmail
    password = $AdminPassword
  } -WebSession $adminSession
  $adminToken = [string]$adminLogin.data.session_token_once
  Add-SensitiveValue $adminToken
  if ([string]::IsNullOrWhiteSpace($adminToken)) {
    throw "admin login failed. response did not include data.session_token_once"
  }
  $artifactEvidence.admin_login.session_token_once_present = $true
  $checks.Add("admin login") | Out-Null
  Add-SmokeStep -Name "admin login" -Status "pass" -Evidence @{ email = $AdminEmail; session_token_once_present = $true }
  Write-Pass "admin login"

  $register = Invoke-Json -Name "user register" -Method "POST" -Uri (Join-Url $ControlPlaneBaseUrl "/auth/register") -Body @{
    email = $userEmail
    password = $userPassword
    display_name = "Dev User $runId"
  } -WebSession $userSession
  $userId = [string]$register.data.user.id
  $tenantId = [string]$register.data.user.tenant_id
  $projectId = [string]$register.data.project.id
  if ([string]::IsNullOrWhiteSpace($userId)) {
    throw "user register failed. response did not include data.user.id"
  }
  if ([string]::IsNullOrWhiteSpace($tenantId) -or [string]::IsNullOrWhiteSpace($projectId)) {
    throw "user register failed. response did not include tenant_id/project.id"
  }
  $artifactEvidence.user.registered = $true
  $artifactEvidence.user.user_id = $userId
  $artifactEvidence.user.tenant_id = $tenantId
  $artifactEvidence.user.project_id = $projectId
  $checks.Add("user register") | Out-Null
  Add-SmokeStep -Name "user register" -Status "pass" -Evidence @{ email = $userEmail; user_id = $userId; tenant_id = $tenantId; project_id = $projectId }
  Write-Pass "user register"

  $readiness = Invoke-Json -Name "user readiness" -Method "GET" -Uri (Join-Url $ControlPlaneBaseUrl "/user/readiness") -WebSession $userSession
  foreach ($code in @("wallet", "profile", "model")) {
    Assert-ReadinessCheckNotBlocked -Readiness $readiness -Code $code
  }
  $checks.Add("user readiness") | Out-Null
  Add-SmokeStep -Name "user readiness" -Status "pass" -Evidence @{ required_checks = @("wallet", "profile", "model") }
  Write-Pass "user readiness"

  $balanceBefore = Invoke-Json -Name "user balance before voucher" -Method "GET" -Uri (Join-Url $ControlPlaneBaseUrl "/user/balance?currency=USD") -WebSession $userSession
  $walletId = [string]$balanceBefore.data.wallet_id
  if ([string]::IsNullOrWhiteSpace($walletId)) {
    throw "user balance failed. response did not include data.wallet_id"
  }
  $artifactEvidence.balance.wallet_id = $walletId
  $checks.Add("user balance") | Out-Null
  Add-SmokeStep -Name "user balance" -Status "pass" -Evidence @{ wallet_id = $walletId }
  Write-Pass "user balance"

  $voucherIssue = Invoke-Json -Name "admin voucher issue" -Method "POST" -Uri (Join-Url $ControlPlaneBaseUrl "/admin/voucher-issuances") -WebSession $adminSession -Body @{
    tenant_id = $tenantId
    project_id = $projectId
    wallet_id = $walletId
    currency = "USD"
    amount = "10.00"
    raw_voucher_code = $voucherCode
    idempotency_key = "dev-login-check-voucher-issue-$runId"
    max_redemptions = 1
  }
  if ([string]$voucherIssue.data.status -notin @("issued", "replayed")) {
    throw "admin voucher issue did not return issued/replayed status."
  }
  $artifactEvidence.voucher.issued = $true
  $checks.Add("admin voucher issue") | Out-Null
  Add-SmokeStep -Name "admin voucher issue" -Status "pass" -Evidence @{ status = [string]$voucherIssue.data.status; raw_code_echoed = $false }
  Write-Pass "admin voucher issue"

  $voucherRedeem = Invoke-Json -Name "user voucher redeem" -Method "POST" -Uri (Join-Url $ControlPlaneBaseUrl "/user/vouchers/redeem") -WebSession $userSession -Body @{
    currency = "USD"
    voucher_code = $voucherCode
    idempotency_key = "dev-login-check-voucher-redeem-$runId"
  }
  if ([string]$voucherRedeem.data.status -ne "redeemed") {
    throw "user voucher redeem did not return redeemed status."
  }
  $artifactEvidence.voucher.redeemed = $true
  $checks.Add("user voucher redeem") | Out-Null
  Add-SmokeStep -Name "user voucher redeem" -Status "pass" -Evidence @{ status = [string]$voucherRedeem.data.status; raw_code_echoed = $false }
  Write-Pass "user voucher redeem"

  $balanceAfter = Invoke-Json -Name "user balance after voucher" -Method "GET" -Uri (Join-Url $ControlPlaneBaseUrl "/user/balance?currency=USD") -WebSession $userSession
  $availableToSpend = [string]$balanceAfter.data.available_to_spend
  if ([string]::IsNullOrWhiteSpace($availableToSpend) -or $availableToSpend -eq "0" -or $availableToSpend -eq "0.00") {
    throw "user balance after voucher did not show available credit."
  }
  $artifactEvidence.balance.available_to_spend_usd = $availableToSpend
  $checks.Add("user voucher balance") | Out-Null
  Add-SmokeStep -Name "user voucher balance" -Status "pass" -Evidence @{ available_to_spend_usd = $availableToSpend }
  Write-Pass "user voucher balance"

  $userModels = Invoke-Json -Name "user models" -Method "GET" -Uri (Join-Url $ControlPlaneBaseUrl "/user/models") -WebSession $userSession
  $userModelsJson = $userModels | ConvertTo-Json -Depth 20 -Compress
  if ($userModelsJson -notmatch [regex]::Escape($Model)) {
    throw "user models did not include expected model '$Model'."
  }
  $artifactEvidence.models.user_models_contains_expected = $true
  $checks.Add("user models") | Out-Null
  Add-SmokeStep -Name "user models" -Status "pass" -Evidence @{ expected_model = $Model; contains_expected = $true }
  Write-Pass "user models"

  $userKey = Invoke-Json -Name "user api key create" -Method "POST" -Uri (Join-Url $ControlPlaneBaseUrl "/user/virtual-keys") -WebSession $userSession -Body @{
    name = "dev-login-check-$runId"
  }
  $userGatewayToken = [string]$userKey.data.secret
  Add-SensitiveValue $userGatewayToken
  if ([string]::IsNullOrWhiteSpace($userGatewayToken)) {
    throw "user api key create failed. response did not include data.secret"
  }
  $artifactEvidence.gateway.user_api_key_created = $true
  $checks.Add("user api key create") | Out-Null
  Add-SmokeStep -Name "user api key create" -Status "pass" -Evidence @{ secret_once_present = $true; raw_secret_echoed = $false }
  Write-Pass "user api key create"

  $models = Invoke-Json -Name "gateway /v1/models" -Method "GET" -Uri (Join-Url $GatewayBaseUrl "/v1/models") -Headers @{
    Authorization = "Bearer $userGatewayToken"
  }
  $modelsJson = $models | ConvertTo-Json -Depth 20 -Compress
  if ($modelsJson -notmatch [regex]::Escape($Model)) {
    throw "gateway /v1/models did not include expected model '$Model'."
  }
  $forbiddenModelList = @(
    $ForbiddenModels.Split(",", [System.StringSplitOptions]::RemoveEmptyEntries) |
      ForEach-Object { $_.Trim() } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  )
  foreach ($forbiddenModel in $forbiddenModelList) {
    if ($modelsJson -match [regex]::Escape($forbiddenModel)) {
      throw "gateway /v1/models leaked forbidden model '$forbiddenModel'."
    }
  }
  $artifactEvidence.models.gateway_models_contains_expected = $true
  if ($forbiddenModelList.Count -gt 0) {
    $artifactEvidence.models.gateway_forbidden_models_absent = $true
  }
  $checks.Add("gateway /v1/models") | Out-Null
  Add-SmokeStep -Name "gateway /v1/models" -Status "pass" -Evidence @{ expected_model = $Model; contains_expected = $true; forbidden_models_checked = $forbiddenModelList.Count }
  Write-Pass "gateway /v1/models"

  $chat = Invoke-JsonWithHeaders -Name "gateway /v1/chat/completions non-stream" -Method "POST" -Uri (Join-Url $GatewayBaseUrl "/v1/chat/completions") -Headers @{
    Authorization = "Bearer $userGatewayToken"
    "x-ai-trace-id" = $nonStreamTraceId
  } -Body @{
    model = $Model
    messages = @(@{ role = "user"; content = "Return the word ok." })
    stream = $false
  }
  $chatJson = $chat.json | ConvertTo-Json -Depth 20 -Compress
  if ($chatJson -notmatch '"choices"\s*:') {
    throw "gateway /v1/chat/completions non-stream response did not include choices."
  }
  $nonStreamGatewayRequestId = [string]$chat.request_id
  if ([string]::IsNullOrWhiteSpace($nonStreamGatewayRequestId)) {
    throw "gateway /v1/chat/completions non-stream did not include x-request-id."
  }
  $artifactEvidence.gateway.non_stream_chat_completion_choices_present = $true
  $artifactEvidence.gateway.non_stream_request_id = $nonStreamGatewayRequestId
  $checks.Add("gateway /v1/chat/completions non-stream") | Out-Null
  Add-SmokeStep -Name "gateway /v1/chat/completions non-stream" -Status "pass" -Evidence @{ choices_present = $true; request_id = $nonStreamGatewayRequestId; trace_id = $nonStreamTraceId }
  Write-Pass "gateway /v1/chat/completions non-stream request_id=$nonStreamGatewayRequestId trace_id=$nonStreamTraceId"

  $streamChat = Invoke-StreamChat -Uri (Join-Url $GatewayBaseUrl "/v1/chat/completions") -Headers @{
    Authorization = "Bearer $userGatewayToken"
    "x-ai-trace-id" = $streamTraceId
  } -Body @{
    model = $Model
    messages = @(@{ role = "user"; content = "Stream the word ok." })
    stream = $true
  }
  $streamGatewayRequestId = [string]$streamChat.request_id
  if ([string]::IsNullOrWhiteSpace($streamGatewayRequestId)) {
    throw "gateway /v1/chat/completions stream did not include x-request-id."
  }
  $artifactEvidence.gateway.stream_chat_sse_present = $true
  $artifactEvidence.gateway.stream_request_id = $streamGatewayRequestId
  $checks.Add("gateway /v1/chat/completions stream") | Out-Null
  Add-SmokeStep -Name "gateway /v1/chat/completions stream" -Status "pass" -Evidence @{ sse_data_frames = $streamChat.data_frame_count; done_present = $streamChat.done_present; request_id = $streamGatewayRequestId; trace_id = $streamTraceId }
  Write-Pass "gateway /v1/chat/completions stream request_id=$streamGatewayRequestId trace_id=$streamTraceId"

  $requestLog = Wait-UserRequestLog -WebSession $userSession -Model $Model -TraceId $nonStreamTraceId -RequestId $nonStreamGatewayRequestId
  $requestLogId = [string]$requestLog.id
  $artifactEvidence.request_log.non_stream_user_request_log_found = $true
  $artifactEvidence.request_log.non_stream_request_id = $requestLogId
  $checks.Add("user request logs non-stream") | Out-Null
  Add-SmokeStep -Name "user request logs non-stream" -Status "pass" -Evidence @{ request_id = $requestLogId; trace_id = $nonStreamTraceId; expected_model = $Model }
  Write-Pass "user request logs non-stream request_id=$requestLogId trace_id=$nonStreamTraceId"

  $streamRequestLog = Wait-UserRequestLog -WebSession $userSession -Model $Model -TraceId $streamTraceId -RequestId $streamGatewayRequestId
  $streamRequestLogId = [string]$streamRequestLog.id
  $artifactEvidence.request_log.stream_user_request_log_found = $true
  $artifactEvidence.request_log.stream_request_id = $streamRequestLogId
  $checks.Add("user request logs stream") | Out-Null
  Add-SmokeStep -Name "user request logs stream" -Status "pass" -Evidence @{ request_id = $streamRequestLogId; trace_id = $streamTraceId; expected_model = $Model }
  Write-Pass "user request logs stream request_id=$streamRequestLogId trace_id=$streamTraceId"

  $nonStreamDetail = Read-AdminRequestDetail -WebSession $adminSession -RequestId $requestLogId -TraceId $nonStreamTraceId -RequireSettledLedger
  $streamDetail = Read-AdminRequestDetail -WebSession $adminSession -RequestId $streamRequestLogId -TraceId $streamTraceId
  $artifactEvidence.request_log.admin_detail_readback = $true
  $artifactEvidence.request_log.admin_detail_readback_count = 2
  $artifactEvidence.request_log.ledger_settled = [bool]$nonStreamDetail.ledger_settled
  $checks.Add("admin request detail readback") | Out-Null
  Add-SmokeStep -Name "admin request detail readback" -Status "pass" -Evidence @{ non_stream_request_id = $requestLogId; non_stream_trace_id = $nonStreamTraceId; non_stream_ledger_settled = $nonStreamDetail.ledger_settled; stream_request_id = $streamRequestLogId; stream_trace_id = $streamTraceId; stream_ledger_returned_count = $streamDetail.ledger_returned_count }
  Write-Pass "admin request detail readback non_stream_request_id=$requestLogId stream_request_id=$streamRequestLogId"

  Write-SmokeArtifact -Status "pass"
  $summaryJson = (New-GatewayUserMvpSummary) | ConvertTo-Json -Depth 12 -Compress
  if (-not (Test-ArtifactSecretSafe -Json $summaryJson)) {
    throw "gateway user MVP summary failed secret-safety validation."
  }
  Write-Host "gateway_user_mvp_summary=$summaryJson"
  Write-Host "dev_login_check_status=pass"
  Write-Host "checked=$($checks.Count)"
  Write-Host "registered_user=$userEmail"
  Write-Host "user_balance_usd=$availableToSpend"
  Write-Host "non_stream_request_id=$requestLogId"
  Write-Host "non_stream_trace_id=$nonStreamTraceId"
  Write-Host "stream_request_id=$streamRequestLogId"
  Write-Host "stream_trace_id=$streamTraceId"
  exit 0
} catch {
  $failure = ConvertTo-SafeText $_.Exception.Message
  Add-SmokeStep -Name "dev_login_check" -Status "fail" -Evidence @{ reason = $failure }
  try {
    Write-SmokeArtifact -Status "fail" -FailureReason $failure
  } catch {
    $artifactError = ConvertTo-SafeText $_.Exception.Message
    $artifactErrorType = $_.Exception.GetType().FullName
    $artifactErrorPosition = ConvertTo-SafeText ([string]$_.InvocationInfo.PositionMessage)
    Write-Host "artifact_write_failed=$artifactError"
    Write-Host "artifact_write_failed_type=$artifactErrorType"
    Write-Host "artifact_write_failed_at=$artifactErrorPosition"
  }
  Write-Host "dev_login_check_status=fail"
  Write-Host "failed_reason=$failure"
  Write-Host "failure_scope=local_stack_or_mvp_feature_gap"
  Write-Host "next_step=pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\dev_up.ps1"
  exit 1
}
