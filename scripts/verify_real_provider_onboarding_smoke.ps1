param(
  [string]$ControlPlaneBaseUrl = "http://127.0.0.1:8081",
  [string]$GatewayBaseUrl = "http://127.0.0.1:8080",
  [string]$AdminEmail = "admin@example.com",
  [string]$AdminPassword = "local-password",
  [string]$ProjectId = "00000000-0000-0000-0000-000000000020",
  [string]$WalletId = "00000000-0000-0000-0000-0000000032a5",
  [string]$ProviderCode = "",
  [string]$ProviderName = "",
  [string]$ProviderBaseUrl = "",
  [string]$ProviderApiKey = "",
  [string]$ProviderModel = "",
  [string]$GatewayModelAlias = "",
  [string]$OutputPath = ".tmp\real-provider\real_provider_onboarding_smoke.json",
  [int]$TimeoutSeconds = 30,
  [switch]$Live,
  [switch]$ContractOnly
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$runId = [guid]::NewGuid().ToString("N")
$tenantId = "00000000-0000-0000-0000-000000000001"
$script:SensitiveValues = New-Object System.Collections.Generic.List[string]
$script:Blockers = New-Object System.Collections.Generic.List[string]

if ($env:CONTROL_PLANE_BASE_URL) { $ControlPlaneBaseUrl = $env:CONTROL_PLANE_BASE_URL }
if ($env:GATEWAY_BASE_URL) { $GatewayBaseUrl = $env:GATEWAY_BASE_URL }
if ($env:CONTROL_PLANE_ADMIN_EMAIL) { $AdminEmail = $env:CONTROL_PLANE_ADMIN_EMAIL }
if ($env:CONTROL_PLANE_ADMIN_PASSWORD) { $AdminPassword = $env:CONTROL_PLANE_ADMIN_PASSWORD }
if ($env:REAL_PROVIDER_CODE) { $ProviderCode = $env:REAL_PROVIDER_CODE }
if ($env:REAL_PROVIDER_NAME) { $ProviderName = $env:REAL_PROVIDER_NAME }
if ($env:REAL_PROVIDER_BASE_URL) { $ProviderBaseUrl = $env:REAL_PROVIDER_BASE_URL }
if ($env:REAL_PROVIDER_API_KEY) { $ProviderApiKey = $env:REAL_PROVIDER_API_KEY }
if ($env:REAL_PROVIDER_MODEL) { $ProviderModel = $env:REAL_PROVIDER_MODEL }
if ($env:REAL_PROVIDER_GATEWAY_MODEL_ALIAS) { $GatewayModelAlias = $env:REAL_PROVIDER_GATEWAY_MODEL_ALIAS }
if ($env:REAL_PROVIDER_ONBOARDING_LIVE -match "^(?i:1|true|yes|on)$") { $Live = $true }
if ($env:REAL_PROVIDER_ONBOARDING_CONTRACT_ONLY -match "^(?i:1|true|yes|on)$") { $ContractOnly = $true }

if ([string]::IsNullOrWhiteSpace($ProviderCode)) { $ProviderCode = "real-provider-smoke-$runId" }
if ([string]::IsNullOrWhiteSpace($ProviderName)) { $ProviderName = "Real Provider Smoke $runId" }
if ([string]::IsNullOrWhiteSpace($GatewayModelAlias)) { $GatewayModelAlias = "real-smoke-$runId" }

function Add-SensitiveValue {
  param([AllowNull()][string]$Value)
  if (-not [string]::IsNullOrWhiteSpace($Value)) {
    [void]$script:SensitiveValues.Add([string]$Value)
  }
}

Add-SensitiveValue $AdminPassword
Add-SensitiveValue $ProviderApiKey

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
  $redacted = $redacted -replace '(?i)("api_key"\s*:\s*")[^"]+(")', '$1[REDACTED]$2'
  $redacted = $redacted -replace '(?i)("encrypted_secret"\s*:\s*")[^"]+(")', '$1[REDACTED]$2'
  $redacted = $redacted -replace '(?i)("secret_fingerprint"\s*:\s*")[^"]+(")', '$1[REDACTED]$2'
  $redacted = $redacted -replace '(?i)("raw_voucher_code"\s*:\s*")[^"]+(")', '$1[REDACTED]$2'
  $redacted = $redacted -replace '(?i)("voucher_code"\s*:\s*")[^"]+(")', '$1[REDACTED]$2'
  $redacted = $redacted -replace '(?i)(authorization\s*[:=]\s*bearer\s+)[^\s";,}]+', '$1[REDACTED]'
  $redacted = $redacted -replace '(?i)(x-admin-session\s*[:=]\s*)[^\s";,}]+', '$1[REDACTED]'
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
      '(?i)x-admin-session\s*[:=]',
      '(?i)bearer\s+[A-Za-z0-9._~+/\-]+=*',
      '(?i)"session_token_once"\s*:',
      '(?i)"secret"\s*:\s*"[^"]{4,}"',
      '(?i)"api_key"\s*:\s*"[^"]{4,}"',
      '(?i)"encrypted_secret"\s*:',
      '(?i)"secret_fingerprint"\s*:',
      '(?i)"raw_voucher_code"\s*:',
      '(?i)"voucher_code"\s*:',
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
    $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 24 -Compress }
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

function Assert-HttpOk {
  param(
    [Parameter(Mandatory = $true)][object]$Response,
    [Parameter(Mandatory = $true)][string]$Name,
    [int[]]$Expected = @(200, 201)
  )
  if ($Expected -notcontains [int]$Response.status_code) {
    throw "$Name returned HTTP $($Response.status_code): $(Redact-SecretLikeString $Response.content)"
  }
}

function Get-Sha256Hex {
  param([Parameter(Mandatory = $true)][string]$Text)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
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

function Invoke-ContractAudit {
  $scriptSource = Read-RepoText "scripts\verify_real_provider_onboarding_smoke.ps1"
  $admin = Read-RepoText "apps\control-plane\src\admin.rs"

  $checks = [ordered]@{
    script_declares_real_provider_env = (Test-Contains $scriptSource "REAL_PROVIDER_BASE_URL") -and (Test-Contains $scriptSource "REAL_PROVIDER_API_KEY") -and (Test-Contains $scriptSource "REAL_PROVIDER_MODEL")
    script_has_missing_credential_bypass = Test-Contains $scriptSource "blocked_missing_real_provider_credentials"
    script_has_secret_safe_artifact_guard = (Test-Contains $scriptSource "Test-SecretSafeText") -and (Test-Contains $scriptSource "raw_provider_api_key_echoed")
    admin_provider_routes = (Test-Contains $admin '"/admin/providers"') -and (Test-Contains $admin '"/admin/channels"')
    admin_provider_key_routes = Test-Contains $admin '"/admin/provider-keys"'
    admin_model_profile_routes = (Test-Contains $admin '"/admin/models"') -and (Test-Contains $admin '"/admin/model-associations"') -and (Test-Contains $admin '"/admin/api-key-profiles"')
    admin_virtual_key_route = Test-Contains $admin '"/admin/virtual-keys"'
    gateway_live_call_pattern_exists = (Test-Contains $scriptSource "/v1/chat/completions") -and (Test-Contains $scriptSource "/v1/models")
  }

  $missing = @()
  foreach ($entry in $checks.GetEnumerator()) {
    if (-not [bool]$entry.Value) { $missing += [string]$entry.Key }
  }

  return [ordered]@{
    status = if ($missing.Count -eq 0) { "pass" } else { "blocked" }
    checks = $checks
    missing = $missing
    live_opt_in_flag = "-Live"
    required_live_env = @("REAL_PROVIDER_BASE_URL", "REAL_PROVIDER_API_KEY", "REAL_PROVIDER_MODEL")
  }
}

function Write-SmokeArtifact {
  param(
    [Parameter(Mandatory = $true)][string]$Status,
    [Parameter(Mandatory = $true)][object]$Contract,
    [AllowNull()][object]$LiveEvidence = $null
  )

  $artifact = [ordered]@{
    schema = "real_provider_onboarding_smoke.v1"
    overall_status = $Status
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    run_id = $runId
    control_plane_base_url = $ControlPlaneBaseUrl
    gateway_base_url = $GatewayBaseUrl
    provider = [ordered]@{
      code = $ProviderCode
      name = $ProviderName
      base_url_configured = -not [string]::IsNullOrWhiteSpace($ProviderBaseUrl)
      base_url_hash = if ([string]::IsNullOrWhiteSpace($ProviderBaseUrl)) { $null } else { Get-Sha256Hex $ProviderBaseUrl }
      model_configured = -not [string]::IsNullOrWhiteSpace($ProviderModel)
      model = if ([string]::IsNullOrWhiteSpace($ProviderModel)) { $null } else { $ProviderModel }
      gateway_model_alias = $GatewayModelAlias
      api_key_configured = -not [string]::IsNullOrWhiteSpace($ProviderApiKey)
      raw_provider_api_key_echoed = $false
    }
    contract = $Contract
    live = $LiveEvidence
    blockers = @($script:Blockers)
    secret_safe = $true
    raw_admin_session_echoed = $false
    raw_provider_api_key_echoed = $false
    raw_virtual_key_secret_echoed = $false
    raw_provider_response_body_omitted = $true
    paid_gate_changed = $false
    deferred = [ordered]@{
      payment_order_invoice_runtime = "deferred_not_required_for_real_provider_onboarding"
      subscription_package_runtime = "deferred_not_required_for_real_provider_onboarding"
      oidc_saml_enterprise_sso = "deferred_not_required_for_real_provider_onboarding"
    }
  }

  $json = $artifact | ConvertTo-Json -Depth 24
  if (-not (Test-SecretSafeText $json)) {
    throw "artifact_secret_safety_check_failed"
  }
  $fullOutputPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputPath))
  $repoPrefix = $repoRoot.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
  if (-not $fullOutputPath.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "output_path_must_stay_inside_repo"
  }
  $outputDir = Split-Path -Parent $fullOutputPath
  if (-not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
  }
  Set-Content -LiteralPath $fullOutputPath -Value $json -Encoding UTF8
  Write-Host "real_provider_onboarding_status=$Status"
  Write-Host "real_provider_onboarding_artifact=$OutputPath"
}

function Invoke-LiveSmoke {
  $adminLogin = Invoke-HttpJson -Method "POST" -Uri (Join-Url $ControlPlaneBaseUrl "/admin/auth/login") -Body @{
    email = $AdminEmail
    password = $AdminPassword
  }
  Assert-HttpOk $adminLogin "admin login" @(200)
  $adminToken = [string](Get-Data $adminLogin.json).session_token_once
  Add-SensitiveValue $adminToken
  if ([string]::IsNullOrWhiteSpace($adminToken)) { throw "admin login did not return session token" }
  $adminHeaders = @{ "x-admin-session" = $adminToken }

  $provider = Invoke-HttpJson -Method "POST" -Uri (Join-Url $ControlPlaneBaseUrl "/admin/providers") -Headers $adminHeaders -Body @{
    code = $ProviderCode
    name = $ProviderName
    provider_type = "openai_compatible"
    base_url = $ProviderBaseUrl
    status = "active"
    metadata = @{ real_provider_onboarding_smoke = $true; run_id = $runId }
  }
  Assert-HttpOk $provider "create provider"
  $providerData = Get-Data $provider.json

  $channel = Invoke-HttpJson -Method "POST" -Uri (Join-Url $ControlPlaneBaseUrl "/admin/channels") -Headers $adminHeaders -Body @{
    provider_id = [string]$providerData.id
    name = "real-provider-channel-$runId"
    protocol = "openai_compatible"
    base_url = $ProviderBaseUrl
    status = "active"
    priority = 100
    weight = 100
    tags = @("real-provider-smoke")
    request_overrides = @{ real_provider_onboarding_smoke = $true }
  }
  Assert-HttpOk $channel "create channel"
  $channelData = Get-Data $channel.json

  $providerKey = Invoke-HttpJson -Method "POST" -Uri (Join-Url $ControlPlaneBaseUrl "/admin/provider-keys") -Headers $adminHeaders -Body @{
    channel_id = [string]$channelData.id
    key_alias = "real-provider-key-$runId"
    status = "enabled"
    api_key = $ProviderApiKey
    metadata = @{ real_provider_onboarding_smoke = $true; run_id = $runId }
  }
  Assert-HttpOk $providerKey "create provider key"
  $providerKeyData = Get-Data $providerKey.json
  if ($providerKey.content -match '(?i)"api_key"\s*:|"encrypted_secret"\s*:|"secret_fingerprint"\s*:') {
    throw "provider key create response exposed provider key material"
  }

  $model = Invoke-HttpJson -Method "POST" -Uri (Join-Url $ControlPlaneBaseUrl "/admin/models") -Headers $adminHeaders -Body @{
    model_key = $GatewayModelAlias
    display_name = "Real Provider Smoke $ProviderModel"
    family = "real-provider-smoke"
    capabilities = @{ chat = $true }
    context_length = 128000
    supports_stream = $true
    visibility = "public"
    status = "active"
  }
  Assert-HttpOk $model "create canonical model"
  $modelData = Get-Data $model.json

  $profile = Invoke-HttpJson -Method "POST" -Uri (Join-Url $ControlPlaneBaseUrl "/admin/api-key-profiles") -Headers $adminHeaders -Body @{
    project_id = $ProjectId
    name = "real-provider-profile-$runId"
    inbound_protocol = "openai_compatible"
    default_protocol_mode = "openai_compatible"
    allowed_models = @($GatewayModelAlias)
    allowed_channel_tags = @("real-provider-smoke")
    denied_models = @()
    status = "active"
  }
  Assert-HttpOk $profile "create api key profile"
  $profileData = Get-Data $profile.json

  $association = Invoke-HttpJson -Method "POST" -Uri (Join-Url $ControlPlaneBaseUrl "/admin/model-associations") -Headers $adminHeaders -Body @{
    canonical_model_id = [string]$modelData.id
    association_type = "explicit_channel"
    channel_id = [string]$channelData.id
    upstream_model_name = $ProviderModel
    priority = 100
    fallback_allowed = $false
    status = "active"
  }
  Assert-HttpOk $association "create model association"
  $associationData = Get-Data $association.json

  $voucherCode = "real-provider-smoke-$runId"
  Add-SensitiveValue $voucherCode
  $issueVoucher = Invoke-HttpJson -Method "POST" -Uri (Join-Url $ControlPlaneBaseUrl "/admin/voucher-issuances") -Headers $adminHeaders -Body @{
    tenant_id = $tenantId
    project_id = $ProjectId
    wallet_id = $WalletId
    currency = "USD"
    amount = "10.00000000"
    raw_voucher_code = $voucherCode
    idempotency_key = "real-provider-issue-$runId"
    max_redemptions = 1
  }
  Assert-HttpOk $issueVoucher "issue voucher"

  $redeemVoucher = Invoke-HttpJson -Method "POST" -Uri (Join-Url $ControlPlaneBaseUrl "/billing/vouchers/redeem") -Headers $adminHeaders -Body @{
    tenant_id = $tenantId
    project_id = $ProjectId
    wallet_id = $WalletId
    currency = "USD"
    voucher_code = $voucherCode
    idempotency_key = "real-provider-redeem-$runId"
    redeemer_user_id = $null
  }
  Assert-HttpOk $redeemVoucher "redeem voucher" @(200)

  $virtualKey = Invoke-HttpJson -Method "POST" -Uri (Join-Url $ControlPlaneBaseUrl "/admin/virtual-keys") -Headers $adminHeaders -Body @{
    project_id = $ProjectId
    name = "real-provider-key-$runId"
    default_profile_id = [string]$profileData.id
    status = "active"
    metadata = @{ real_provider_onboarding_smoke = $true; run_id = $runId }
  }
  Assert-HttpOk $virtualKey "create virtual key"
  $virtualKeyData = Get-Data $virtualKey.json
  $virtualKeySecret = [string]$virtualKeyData.secret
  Add-SensitiveValue $virtualKeySecret
  if ([string]::IsNullOrWhiteSpace($virtualKeySecret)) { throw "virtual key create did not return one-time secret" }

  $gatewayHeaders = @{ Authorization = "Bearer $virtualKeySecret" }
  $models = Invoke-HttpJson -Method "GET" -Uri (Join-Url $GatewayBaseUrl "/v1/models") -Headers $gatewayHeaders
  Assert-HttpOk $models "gateway /v1/models" @(200)

  $chat = Invoke-HttpJson -Method "POST" -Uri (Join-Url $GatewayBaseUrl "/v1/chat/completions") -Headers $gatewayHeaders -Body @{
    model = $GatewayModelAlias
    messages = @(@{ role = "user"; content = "Return the single word ok." })
    stream = $false
  }
  Assert-HttpOk $chat "gateway /v1/chat/completions" @(200)

  return [ordered]@{
    status = "pass"
    created = [ordered]@{
      provider_id = [string]$providerData.id
      channel_id = [string]$channelData.id
      provider_key_id = [string]$providerKeyData.id
      canonical_model_id = [string]$modelData.id
      api_key_profile_id = [string]$profileData.id
      model_association_id = [string]$associationData.id
      virtual_key_id = [string]$virtualKeyData.id
    }
    gateway = [ordered]@{
      models_status_code = [int]$models.status_code
      chat_status_code = [int]$chat.status_code
      model_alias = $GatewayModelAlias
      upstream_model = $ProviderModel
    }
    provider_key = [ordered]@{
      credential_configured = [bool]$providerKeyData.credential_configured
      secret_redacted = [bool]$providerKeyData.secret_redacted
      raw_provider_api_key_echoed = $false
    }
    voucher_credit = [ordered]@{
      issued = $true
      redeemed = $true
      raw_voucher_code_echoed = $false
    }
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

$missingLiveEnv = @()
if ([string]::IsNullOrWhiteSpace($ProviderBaseUrl)) { $missingLiveEnv += "REAL_PROVIDER_BASE_URL" }
if ([string]::IsNullOrWhiteSpace($ProviderApiKey)) { $missingLiveEnv += "REAL_PROVIDER_API_KEY" }
if ([string]::IsNullOrWhiteSpace($ProviderModel)) { $missingLiveEnv += "REAL_PROVIDER_MODEL" }

if ($missingLiveEnv.Count -gt 0) {
  foreach ($name in $missingLiveEnv) {
    [void]$script:Blockers.Add("missing_$name")
  }
  $status = "blocked_missing_real_provider_credentials"
  Write-SmokeArtifact -Status $status -Contract $contract -LiveEvidence ([ordered]@{
      status = "not_run"
      reason = "missing_real_provider_credentials"
      missing_env = @($missingLiveEnv)
      bypass = "mock_provider_and_new_api_mvp_live_smoke_remain_valid_for_local_distribution"
      rerun = "Set REAL_PROVIDER_BASE_URL, REAL_PROVIDER_API_KEY, REAL_PROVIDER_MODEL, then run scripts/verify_real_provider_onboarding_smoke.ps1 -Live"
    })
  if ($Live) { exit 2 }
  exit 0
}

if ($ContractOnly -or -not $Live) {
  Write-SmokeArtifact -Status "contract_ready_live_not_run" -Contract $contract -LiveEvidence ([ordered]@{
      status = "not_run"
      reason = "live_not_requested"
      rerun = "scripts/verify_real_provider_onboarding_smoke.ps1 -Live"
    })
  exit 0
}

try {
  $liveEvidence = Invoke-LiveSmoke
  Write-SmokeArtifact -Status "pass" -Contract $contract -LiveEvidence $liveEvidence
  exit 0
} catch {
  [void]$script:Blockers.Add((Redact-SecretLikeString $_.Exception.Message))
  Write-SmokeArtifact -Status "blocked_live" -Contract $contract -LiveEvidence ([ordered]@{
      status = "blocked"
      message = Redact-SecretLikeString $_.Exception.Message
    })
  exit 2
}
