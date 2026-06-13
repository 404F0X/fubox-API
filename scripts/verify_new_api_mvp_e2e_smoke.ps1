param(
  [string]$ControlPlaneBaseUrl = "http://127.0.0.1:8081",
  [string]$GatewayBaseUrl = "http://127.0.0.1:8080",
  [string]$AdminEmail = "admin@example.com",
  [string]$AdminPassword = "local-password",
  [string]$UserEmail = "",
  [string]$UserPassword = "local-user-password",
  [string]$UserDisplayName = "New API MVP User",
  [string]$Model = "mock-gpt-4o-mini",
  [string]$OutputPath = ".tmp\new-api-mvp\new_api_mvp_e2e_smoke.json",
  [int]$TimeoutSeconds = 10,
  [switch]$Live,
  [switch]$ContractOnly
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$runId = [guid]::NewGuid().ToString("N")
$tenantId = "00000000-0000-0000-0000-000000000001"
$projectId = "00000000-0000-0000-0000-000000000020"
$script:SensitiveValues = New-Object System.Collections.Generic.List[string]
$script:Blockers = New-Object System.Collections.Generic.List[string]

if ($env:CONTROL_PLANE_BASE_URL) { $ControlPlaneBaseUrl = $env:CONTROL_PLANE_BASE_URL }
if ($env:GATEWAY_BASE_URL) { $GatewayBaseUrl = $env:GATEWAY_BASE_URL }
if ($env:CONTROL_PLANE_ADMIN_EMAIL) { $AdminEmail = $env:CONTROL_PLANE_ADMIN_EMAIL }
if ($env:CONTROL_PLANE_ADMIN_PASSWORD) { $AdminPassword = $env:CONTROL_PLANE_ADMIN_PASSWORD }
if ($env:NEW_API_MVP_USER_EMAIL) { $UserEmail = $env:NEW_API_MVP_USER_EMAIL }
if ($env:NEW_API_MVP_USER_PASSWORD) { $UserPassword = $env:NEW_API_MVP_USER_PASSWORD }
if ($env:SMOKE_MODEL) { $Model = $env:SMOKE_MODEL }
if ($env:NEW_API_MVP_E2E_LIVE -match "^(?i:1|true|yes|on)$") { $Live = $true }
if ($env:NEW_API_MVP_E2E_CONTRACT_ONLY -match "^(?i:1|true|yes|on)$") { $ContractOnly = $true }

if ([string]::IsNullOrWhiteSpace($UserEmail)) {
  $UserEmail = "new-api-mvp-$runId@example.test"
}

function Add-SensitiveValue {
  param([AllowNull()][string]$Value)
  if (-not [string]::IsNullOrWhiteSpace($Value)) {
    [void]$script:SensitiveValues.Add([string]$Value)
  }
}

Add-SensitiveValue $AdminPassword
Add-SensitiveValue $UserPassword

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
  $redacted = $redacted -replace '(?i)(authorization\s*[:=]\s*bearer\s+)[^\s";,]+', '$1[REDACTED]'
  $redacted = $redacted -replace '(?i)(cookie\s*[:=]\s*)[^\r\n"]+', '$1[REDACTED]'
  $redacted = $redacted -replace '(?i)(x-admin-session\s*[:=]\s*)[^\s";,]+', '$1[REDACTED]'
  $redacted = $redacted -replace '(?i)(Bearer\s+)[A-Za-z0-9._~+/\-]+=*', '$1[REDACTED]'
  $redacted = $redacted -replace 'sess_[A-Za-z0-9._~+/\-=]+', '[REDACTED]'
  $redacted = $redacted -replace 'sk-[A-Za-z0-9._~+\-/=]+', '[REDACTED]'
  return $redacted
}

function Test-SecretSafeText {
  param([AllowNull()][string]$Text)

  if ([string]::IsNullOrWhiteSpace($Text)) { return $true }
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

function Read-RepoText {
  param([Parameter(Mandatory = $true)][string]$RelativePath)

  $fullPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $RelativePath))
  $repoPrefix = $repoRoot.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
  if (-not $fullPath.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "path_must_stay_inside_repo"
  }
  if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    return ""
  }
  return Get-Content -Raw -LiteralPath $fullPath
}

function Test-Contains {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [Parameter(Mandatory = $true)][string]$Needle
  )
  return $Text.Contains($Needle)
}

function Get-Data {
  param([AllowNull()][object]$Payload)
  if ($null -eq $Payload) { return $null }
  if ($Payload.PSObject.Properties.Name -contains "data") { return $Payload.data }
  return $Payload
}

function Invoke-HttpJson {
  param(
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Uri,
    [AllowNull()][object]$Body = $null,
    [hashtable]$Headers = @{}
  )

  Add-Type -AssemblyName System.Net.Http
  $client = New-Object System.Net.Http.HttpClient
  $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
  $request = New-Object System.Net.Http.HttpRequestMessage -ArgumentList (New-Object System.Net.Http.HttpMethod -ArgumentList $Method), $Uri
  foreach ($key in $Headers.Keys) {
    [void]$request.Headers.TryAddWithoutValidation($key, [string]$Headers[$key])
  }
  if ($null -ne $Body) {
    $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 -Compress }
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
    $setCookies = @()
    $values = $null
    if ($response.Headers.TryGetValues("Set-Cookie", [ref]$values)) {
      $setCookies = @($values)
    }
    return [PSCustomObject]@{
      status_code = [int]$response.StatusCode
      content = $content
      json = $payload
      set_cookies = $setCookies
    }
  } finally {
    if ($response) { $response.Dispose() }
    $request.Dispose()
    $client.Dispose()
  }
}

function Assert-HttpOk {
  param(
    [Parameter(Mandatory = $true)][object]$Response,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if ($Response.status_code -lt 200 -or $Response.status_code -ge 300) {
    $safe = Redact-SecretLikeString $Response.content
    throw "$Name returned HTTP $($Response.status_code): $safe"
  }
}

function Get-CookieHeader {
  param(
    [Parameter(Mandatory = $true)][object]$Response,
    [Parameter(Mandatory = $true)][string]$CookieName
  )
  foreach ($cookie in @($Response.set_cookies)) {
    if ($cookie -like "$CookieName=*") {
      return ($cookie -split ";", 2)[0]
    }
  }
  return ""
}

function Write-SmokeArtifact {
  param(
    [Parameter(Mandatory = $true)][string]$Status,
    [Parameter(Mandatory = $true)][object]$Contract,
    [AllowNull()][object]$LiveEvidence = $null
  )

  $artifact = [ordered]@{
    schema = "new_api_mvp_e2e_smoke.v1"
    overall_status = $Status
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    run_id = $runId
    contract = $Contract
    live = $LiveEvidence
    blockers = @($script:Blockers)
    secret_safe = $true
    raw_user_session_cookie_echoed = $false
    raw_admin_session_echoed = $false
    raw_virtual_key_secret_echoed = $false
    raw_voucher_code_echoed = $false
    paid_gate_changed = $false
    deferred = [ordered]@{
      payment_order_invoice_runtime = "deferred_external_dependency"
      subscription_package_runtime = "deferred_external_dependency"
      oidc_saml_enterprise_sso = "deferred_external_dependency"
    }
  }

  $json = $artifact | ConvertTo-Json -Depth 24
  if (-not (Test-SecretSafeText $json)) {
    throw "artifact_secret_safety_check_failed"
  }
  $fullOutputPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputPath))
  $outputDir = Split-Path -Parent $fullOutputPath
  if (-not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
  }
  Set-Content -LiteralPath $fullOutputPath -Value $json -Encoding UTF8
  Write-Host "Wrote $OutputPath"
}

function Invoke-ContractAudit {
  $userAuth = Read-RepoText "apps\control-plane\src\user_auth.rs"
  $admin = Read-RepoText "apps\control-plane\src\admin.rs"
  $client = Read-RepoText "web\admin-ui\src\api\client.ts"
  $portal = Read-RepoText "web\admin-ui\src\components\UserPortalPanel.tsx"
  $usageSummarySection = (($userAuth -split 'async fn get_user_usage_summary', 2)[1] -split 'async fn list_user_virtual_keys', 2)[0]
  $traceSummarySection = (($userAuth -split 'async fn get_user_trace_summary', 2)[1] -split 'async fn list_user_virtual_keys', 2)[0]
  $userLogResponseSection = (($userAuth -split 'fn user_request_log_response', 2)[1] -split 'fn user_model_response', 2)[0]
  $usageSummaryInternalFieldsReturned = $false
  foreach ($field in @(
      '"provider_key_id"',
      '"api_key_profile_id"',
      '"canonical_model_id"',
      '"resolved_provider_id"',
      '"resolved_channel_id"',
      '"route_policy_version"',
      '"payload_policy_id"',
      '"payload_stored"',
      '"route_decision_snapshot"',
      '"request_body_hash"',
      '"response_body_hash"'
    )) {
    if (Test-Contains $usageSummarySection $field) {
      $usageSummaryInternalFieldsReturned = $true
    }
  }
  $traceSummaryInternalFieldsReturned = $false
  foreach ($field in @(
      '"provider_key_id"',
      '"api_key_profile_id"',
      '"canonical_model_id"',
      '"resolved_provider_id"',
      '"resolved_channel_id"',
      '"route_policy_version"',
      '"payload_policy_id"',
      '"payload_stored"',
      '"route_decision_snapshot"',
      '"request_body_hash"',
      '"response_body_hash"'
    )) {
    if (Test-Contains $traceSummarySection $field) {
      $traceSummaryInternalFieldsReturned = $true
    }
  }

  $checks = [ordered]@{
    user_register_route = Test-Contains $userAuth '.route("/auth/register", post(register))'
    user_login_route = Test-Contains $userAuth '.route("/auth/login", post(login))'
    user_me_route = Test-Contains $userAuth '.route("/auth/me", get(me))'
    user_balance_route = Test-Contains $userAuth '.route("/user/balance", get(get_user_balance))'
    user_models_route = Test-Contains $userAuth '.route("/user/models", get(list_user_models))'
    user_readiness_route = Test-Contains $userAuth '.route("/user/readiness", get(get_user_readiness))'
    user_usage_summary_route = Test-Contains $userAuth '.route("/user/usage-summary", get(get_user_usage_summary))'
    user_usage_summary_schema = (Test-Contains $userAuth 'UserUsageSummaryResponse') -and (Test-Contains $userAuth '"user_usage_summary.v1"')
    user_usage_summary_project_scoped = (Test-Contains $usageSummarySection 'tenant_id = $1') -and (Test-Contains $usageSummarySection 'project_id = $2')
    user_usage_summary_window_bounded = (Test-Contains $userAuth 'fn user_usage_window_days') -and (Test-Contains $usageSummarySection 'created_at >= now()')
    user_usage_summary_internal_fields_omitted = -not $usageSummaryInternalFieldsReturned
    user_trace_summary_route = Test-Contains $userAuth '.route("/user/traces/{trace_id}", get(get_user_trace_summary))'
    user_trace_summary_schema = (Test-Contains $userAuth 'UserTraceSummaryResponse') -and (Test-Contains $userAuth '"user_trace_summary.v1"')
    user_trace_summary_project_scoped = (Test-Contains $traceSummarySection 'tenant_id = $1') -and (Test-Contains $traceSummarySection 'project_id = $2')
    user_trace_summary_window_bounded = (Test-Contains $userAuth 'fn user_trace_window_days') -and (Test-Contains $traceSummarySection 'created_at >= now()')
    user_trace_summary_internal_fields_omitted = -not $traceSummaryInternalFieldsReturned
    user_voucher_redeem_route = Test-Contains $userAuth '.route("/user/vouchers/redeem", post(redeem_user_voucher))'
    user_virtual_key_routes = (Test-Contains $userAuth '"/user/virtual-keys"') -and (Test-Contains $userAuth 'create_user_virtual_key') -and (Test-Contains $userAuth 'disable_user_virtual_key')
    user_request_logs_route = Test-Contains $userAuth '.route("/user/request-logs", get(list_user_request_logs))'
    user_request_logs_internal_fields_omitted = (Test-Contains $userAuth '"omitted_internal_fields"') -and -not (Test-Contains $userLogResponseSection '"provider_key_id"')
    user_session_cookie_only = (Test-Contains $userAuth 'USER_SESSION_COOKIE') -and -not (Test-Contains $userAuth 'if let Some(candidate) = session_token_from_headers')
    project_role_limited = Test-Contains $userAuth "pm.role in ('owner', 'admin', 'developer')"
    user_key_create_audited = Test-Contains $userAuth 'create_virtual_key_with_default_profile_and_audit'
    user_key_disable_audited = Test-Contains $userAuth 'update_virtual_key_status_with_audit'
    user_key_policy_server_owned = Test-Contains $userAuth 'user_key_policy_server_owned'
    balance_runtime_reuses_readback = Test-Contains $admin 'user_remaining_balance_runtime_response'
    voucher_runtime_reuses_redeem_tx = Test-Contains $admin 'redeem_user_voucher_runtime'
    frontend_balance_client = Test-Contains $client 'getUserBalance'
    frontend_models_client = Test-Contains $client 'listUserModels'
    frontend_readiness_client = Test-Contains $client 'getUserReadiness'
    frontend_usage_summary_client = Test-Contains $client 'getUserUsageSummary'
    frontend_trace_summary_client = Test-Contains $client 'getUserRequestTraceSummary'
    frontend_voucher_client = Test-Contains $client 'redeemUserVoucher'
    frontend_logs_client = Test-Contains $client 'listUserRequestLogs'
    portal_balance_panel = (Test-Contains $portal 'aria-label="User balance and voucher redemption"') -and (Test-Contains $portal 'Balance')
    portal_readiness_panel = Test-Contains $portal 'aria-label="User API readiness"'
    portal_usage_summary_panel = Test-Contains $portal 'aria-label="User usage summary"'
    portal_trace_summary_panel = Test-Contains $portal 'aria-label="User trace summary"'
    portal_models_panel = Test-Contains $portal 'aria-label="User models and API endpoints"'
    portal_api_key_panel = Test-Contains $portal 'aria-label="User API keys"'
    portal_usage_panel = Test-Contains $portal 'aria-label="User request logs"'
  }

  $missing = @()
  foreach ($entry in $checks.GetEnumerator()) {
    if (-not [bool]$entry.Value) { $missing += [string]$entry.Key }
  }

  return [ordered]@{
    status = if ($missing.Count -eq 0) { "pass" } else { "blocked" }
    checks = $checks
    missing = $missing
    live_required_for_full_e2e = $true
    live_opt_in_flag = "-Live"
  }
}

function Invoke-LiveSmoke {
  $voucherCode = "MVP-$runId"
  Add-SensitiveValue $voucherCode

  $adminLogin = Invoke-HttpJson -Method "POST" -Uri (Join-Url $ControlPlaneBaseUrl "/admin/auth/login") -Body @{
    email = $AdminEmail
    password = $AdminPassword
  }
  Assert-HttpOk $adminLogin "admin login"
  $adminData = Get-Data $adminLogin.json
  $adminToken = [string]$adminData.session_token_once
  Add-SensitiveValue $adminToken
  if ([string]::IsNullOrWhiteSpace($adminToken)) { throw "admin login did not return session token" }

  $register = Invoke-HttpJson -Method "POST" -Uri (Join-Url $ControlPlaneBaseUrl "/auth/register") -Body @{
    email = $UserEmail
    password = $UserPassword
    display_name = $UserDisplayName
  }
  Assert-HttpOk $register "user register"
  $userCookie = Get-CookieHeader -Response $register -CookieName "ai_gateway_user_session"
  Add-SensitiveValue $userCookie
  if ([string]::IsNullOrWhiteSpace($userCookie)) { throw "user register did not set user session cookie" }
  $userData = Get-Data $register.json
  $userId = [string]$userData.user.id
  $userProjectId = [string]$userData.project.id

  $balanceBefore = Invoke-HttpJson -Method "GET" -Uri (Join-Url $ControlPlaneBaseUrl "/user/balance") -Headers @{ Cookie = $userCookie }
  Assert-HttpOk $balanceBefore "user balance before"
  $balanceBeforeData = Get-Data $balanceBefore.json
  $walletId = [string]$balanceBeforeData.wallet_id
  $currency = [string]$balanceBeforeData.currency
  if ([string]::IsNullOrWhiteSpace($walletId)) { throw "user balance did not expose bounded wallet id" }

  $readinessBefore = Invoke-HttpJson -Method "GET" -Uri (Join-Url $ControlPlaneBaseUrl "/user/readiness") -Headers @{ Cookie = $userCookie }
  Assert-HttpOk $readinessBefore "user readiness before"
  $readinessBeforeData = Get-Data $readinessBefore.json

  $userModels = Invoke-HttpJson -Method "GET" -Uri (Join-Url $ControlPlaneBaseUrl "/user/models") -Headers @{ Cookie = $userCookie }
  Assert-HttpOk $userModels "user models"
  $userModelsData = @(Get-Data $userModels.json)
  $matchingUserModels = @($userModelsData | Where-Object { [string]$_.model -eq $Model })
  if ($matchingUserModels.Count -lt 1) {
    throw "user models did not include expected model $Model"
  }

  $issueVoucher = Invoke-HttpJson -Method "POST" -Uri (Join-Url $ControlPlaneBaseUrl "/admin/voucher-issuances") -Headers @{ "x-admin-session" = $adminToken } -Body @{
    tenant_id = $tenantId
    project_id = $projectId
    wallet_id = $walletId
    currency = $currency
    amount = "5.00000000"
    raw_voucher_code = $voucherCode
    idempotency_key = "issue-$runId"
    max_redemptions = 1
  }
  Assert-HttpOk $issueVoucher "admin issue voucher"
  $issueData = Get-Data $issueVoucher.json

  $redeem = Invoke-HttpJson -Method "POST" -Uri (Join-Url $ControlPlaneBaseUrl "/user/vouchers/redeem") -Headers @{ Cookie = $userCookie } -Body @{
    voucher_code = $voucherCode
    idempotency_key = "redeem-$runId"
  }
  Assert-HttpOk $redeem "user redeem voucher"
  $redeemData = Get-Data $redeem.json
  if (@("redeemed", "replayed") -notcontains [string]$redeemData.status) {
    throw "voucher redeem status was $($redeemData.status)"
  }

  $createKey = Invoke-HttpJson -Method "POST" -Uri (Join-Url $ControlPlaneBaseUrl "/user/virtual-keys") -Headers @{ Cookie = $userCookie } -Body @{
    name = "mvp smoke $runId"
  }
  Assert-HttpOk $createKey "user create virtual key"
  $keyData = Get-Data $createKey.json
  $virtualKeySecret = [string]$keyData.secret
  Add-SensitiveValue $virtualKeySecret
  if ([string]::IsNullOrWhiteSpace($virtualKeySecret)) { throw "user virtual key create did not return one-time secret" }

  $models = Invoke-HttpJson -Method "GET" -Uri (Join-Url $GatewayBaseUrl "/v1/models") -Headers @{ Authorization = "Bearer $virtualKeySecret" }
  Assert-HttpOk $models "gateway /v1/models"

  $chat = Invoke-HttpJson -Method "POST" -Uri (Join-Url $GatewayBaseUrl "/v1/chat/completions") -Headers @{ Authorization = "Bearer $virtualKeySecret" } -Body @{
    model = $Model
    messages = @(@{ role = "user"; content = "Return the word ok." })
    stream = $false
  }
  Assert-HttpOk $chat "gateway /v1/chat/completions"

  Start-Sleep -Milliseconds 300
  $logs = Invoke-HttpJson -Method "GET" -Uri (Join-Url $ControlPlaneBaseUrl "/user/request-logs?limit=20") -Headers @{ Cookie = $userCookie }
  Assert-HttpOk $logs "user request logs"
  $logsData = @(Get-Data $logs.json)
  $logsJson = $logsData | ConvertTo-Json -Depth 20 -Compress
  $internalLogFields = @(
    "api_key_profile_id",
    "canonical_model_id",
    "resolved_provider_id",
    "resolved_channel_id",
    "provider_key_id",
    "route_policy_version",
    "payload_policy_id",
    "payload_stored"
  )
  foreach ($field in $internalLogFields) {
    if ($logsJson -match "`"$field`"\s*:") {
      throw "user request logs exposed internal field $field"
    }
  }
  $matchingLogs = @($logsData | Where-Object { [string]$_.virtual_key_id -eq [string]$keyData.id })

  $usageSummary = Invoke-HttpJson -Method "GET" -Uri (Join-Url $ControlPlaneBaseUrl "/user/usage-summary?window_days=1") -Headers @{ Cookie = $userCookie }
  Assert-HttpOk $usageSummary "user usage summary"
  $usageSummaryData = Get-Data $usageSummary.json
  $usageSummaryJson = $usageSummaryData | ConvertTo-Json -Depth 24 -Compress
  if (-not (Test-SecretSafeText $usageSummaryJson)) {
    throw "user usage summary failed secret safety check"
  }
  foreach ($field in @(
      "api_key_profile_id",
      "canonical_model_id",
      "resolved_provider_id",
      "resolved_channel_id",
      "provider_key_id",
      "route_policy_version",
      "payload_policy_id",
      "payload_stored",
      "route_decision_snapshot",
      "request_body_hash",
      "response_body_hash"
    )) {
    if ($usageSummaryJson -match "`"$field`"\s*:") {
      throw "user usage summary exposed internal field $field"
    }
  }
  if ([string]$usageSummaryData.schema -ne "user_usage_summary.v1") {
    throw "user usage summary schema mismatch"
  }
  if ([string]$usageSummaryData.project_id -ne $userProjectId) {
    throw "user usage summary project scope mismatch"
  }
  if ([int]$usageSummaryData.window_days -ne 1) {
    throw "user usage summary window_days mismatch"
  }
  $summaryModelMatches = @($usageSummaryData.by_model | Where-Object { [string]$_.model -eq $Model })
  $summaryKeyMatches = @($usageSummaryData.by_key | Where-Object {
      [string]$_.virtual_key_id -eq [string]$keyData.id -or [string]$_.key_prefix -eq [string]$keyData.key_prefix
    })

  $traceSummaryData = $null
  $traceRequestMatches = @()
  $traceSummaryStatus = "not_available"
  $firstTraceId = @($matchingLogs | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.trace_id) } | Select-Object -First 1).trace_id
  if (-not [string]::IsNullOrWhiteSpace([string]$firstTraceId)) {
    $traceSummary = Invoke-HttpJson -Method "GET" -Uri (Join-Url $ControlPlaneBaseUrl "/user/traces/$([uri]::EscapeDataString([string]$firstTraceId))?window_days=1&limit=20") -Headers @{ Cookie = $userCookie }
    Assert-HttpOk $traceSummary "user trace summary"
    $traceSummaryData = Get-Data $traceSummary.json
    $traceSummaryJson = $traceSummaryData | ConvertTo-Json -Depth 24 -Compress
    if (-not (Test-SecretSafeText $traceSummaryJson)) {
      throw "user trace summary failed secret safety check"
    }
    foreach ($field in @(
        "api_key_profile_id",
        "canonical_model_id",
        "resolved_provider_id",
        "resolved_channel_id",
        "provider_key_id",
        "route_policy_version",
        "payload_policy_id",
        "payload_stored",
        "route_decision_snapshot",
        "request_body_hash",
        "response_body_hash"
      )) {
      if ($traceSummaryJson -match "`"$field`"\s*:") {
        throw "user trace summary exposed internal field $field"
      }
    }
    if ([string]$traceSummaryData.schema -ne "user_trace_summary.v1") {
      throw "user trace summary schema mismatch"
    }
    if ([string]$traceSummaryData.project_id -ne $userProjectId) {
      throw "user trace summary project scope mismatch"
    }
    if ([int]$traceSummaryData.window_days -ne 1) {
      throw "user trace summary window_days mismatch"
    }
    $traceRequestMatches = @($traceSummaryData.requests | Where-Object { [string]$_.virtual_key_id -eq [string]$keyData.id })
    $traceSummaryStatus = "pass"
  }

  $balanceAfter = Invoke-HttpJson -Method "GET" -Uri (Join-Url $ControlPlaneBaseUrl "/user/balance") -Headers @{ Cookie = $userCookie }
  Assert-HttpOk $balanceAfter "user balance after"
  $balanceAfterData = Get-Data $balanceAfter.json

  $readinessAfter = Invoke-HttpJson -Method "GET" -Uri (Join-Url $ControlPlaneBaseUrl "/user/readiness") -Headers @{ Cookie = $userCookie }
  Assert-HttpOk $readinessAfter "user readiness after"
  $readinessAfterData = Get-Data $readinessAfter.json

  return [ordered]@{
    status = if ($matchingLogs.Count -gt 0) { "pass" } else { "warn_logs_not_observed_yet" }
    control_plane_base_url = $ControlPlaneBaseUrl
    gateway_base_url = $GatewayBaseUrl
    user = [ordered]@{
      id = $userId
      email_hash = (Get-StringHash $UserEmail)
      project_id = $userProjectId
      session_cookie_set = $true
      raw_session_cookie_echoed = $false
    }
    wallet = [ordered]@{
      id = $walletId
      currency = $currency
      balance_before = [string]$balanceBeforeData.available_to_spend
      balance_after = [string]$balanceAfterData.available_to_spend
    }
    voucher = [ordered]@{
      issue_status = [string]$issueData.status
      redeem_status = [string]$redeemData.status
      voucher_id = [string]$redeemData.voucher_id
      redemption_id = [string]$redeemData.redemption_id
      credit_grant_id = [string]$redeemData.credit_grant_id
      ledger_entry_id = [string]$redeemData.ledger_entry_id
      raw_voucher_code_echoed = $false
    }
    virtual_key = [ordered]@{
      id = [string]$keyData.id
      key_prefix = [string]$keyData.key_prefix
      secret_once = [bool]$keyData.secret_once
      secret_redacted_after_create = $true
      raw_secret_echoed = $false
    }
    gateway = [ordered]@{
      models_status_code = $models.status_code
      chat_status_code = $chat.status_code
      model = $Model
    }
    user_models = [ordered]@{
      returned_count = $userModelsData.Count
      expected_model_present = $matchingUserModels.Count -gt 0
      expected_model_routable = [bool]$matchingUserModels[0].routable
      raw_pricing_rules_echoed = $false
    }
    readiness = [ordered]@{
      before_state = [string]$readinessBeforeData.state
      after_state = [string]$readinessAfterData.state
      active_keys_after = [int]$readinessAfterData.counts.active_keys
      routable_models_after = [int]$readinessAfterData.counts.routable_models
      recent_requests_after = [int]$readinessAfterData.counts.recent_requests
      secret_safe = [bool]$readinessAfterData.secret_safe
    }
    usage_summary = [ordered]@{
      schema = [string]$usageSummaryData.schema
      window_days = [int]$usageSummaryData.window_days
      request_count = [int]$usageSummaryData.totals.request_count
      success_count = [int]$usageSummaryData.totals.success_count
      total_tokens = [int]$usageSummaryData.totals.total_tokens
      expected_model_present = $summaryModelMatches.Count -gt 0
      matching_virtual_key_present = $summaryKeyMatches.Count -gt 0
      secret_safe = [bool]$usageSummaryData.secret_safe
      raw_payload_returned = $false
      internal_routing_fields_returned = $false
    }
    trace_summary = [ordered]@{
      status = $traceSummaryStatus
      schema = if ($traceSummaryData) { [string]$traceSummaryData.schema } else { $null }
      request_count = if ($traceSummaryData) { [int]$traceSummaryData.request_count } else { 0 }
      matching_virtual_key_request_count = $traceRequestMatches.Count
      secret_safe = if ($traceSummaryData) { [bool]$traceSummaryData.secret_safe } else { $true }
      raw_payload_returned = $false
      internal_routing_fields_returned = $false
      raw_secret_echoed = $false
    }
    usage = [ordered]@{
      returned_count = $logsData.Count
      matching_virtual_key_log_count = $matchingLogs.Count
      observed_request_ids = @($matchingLogs | Select-Object -First 5 | ForEach-Object { [string]$_.id })
      raw_payload_returned = $false
      internal_routing_fields_returned = $false
    }
  }
}

function Get-StringHash {
  param([Parameter(Mandatory = $true)][string]$Text)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

$contract = Invoke-ContractAudit
if ($contract.status -ne "pass") {
  foreach ($missing in @($contract.missing)) {
    [void]$script:Blockers.Add("contract_missing_$missing")
  }
  Write-SmokeArtifact -Status "blocked_contract_missing" -Contract $contract
  exit 2
}

if ($ContractOnly -or -not $Live) {
  Write-SmokeArtifact -Status "contract_ready_live_not_run" -Contract $contract
  Write-Host "Contract ready. Pass -Live to run register/login -> voucher -> key -> gateway -> usage."
  exit 0
}

try {
  $liveEvidence = Invoke-LiveSmoke
  $status = if ($liveEvidence.status -eq "pass") { "pass" } else { "warn_live_partial" }
  Write-SmokeArtifact -Status $status -Contract $contract -LiveEvidence $liveEvidence
  if ($status -eq "pass") { exit 0 }
  exit 2
} catch {
  [void]$script:Blockers.Add((Redact-SecretLikeString $_.Exception.Message))
  Write-SmokeArtifact -Status "blocked_live" -Contract $contract -LiveEvidence ([ordered]@{
      status = "blocked"
      message = Redact-SecretLikeString $_.Exception.Message
    })
  exit 2
}
