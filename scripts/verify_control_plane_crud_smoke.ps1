param(
  [string]$ControlPlaneBaseUrl = "http://127.0.0.1:8081",
  [string]$ControlPlaneAuthToken = "devkey",
  [string]$AdminEmail = "admin@example.com",
  [string]$AdminPassword = "local-password",
  [string]$AdminSessionToken = "",
  [string]$ProjectId = "00000000-0000-0000-0000-000000000020",
  [string]$OutputPath = ".tmp/control-plane/control_plane_management_parity_smoke.json",
  [int]$TimeoutSeconds = 8,
  [switch]$IncludeFullCrud,
  [switch]$StrictFullCrud,
  [switch]$SkipAdminLogin,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$script:Failures = @()
$script:Pending = @()

function Test-TruthyEnv {
  param([string]$Value)

  return $Value -eq "1" -or $Value -match "^(true|yes|on)$"
}

if ($env:CONTROL_PLANE_BASE_URL) { $ControlPlaneBaseUrl = $env:CONTROL_PLANE_BASE_URL }
if ($env:CONTROL_PLANE_AUTH_TOKEN) { $ControlPlaneAuthToken = $env:CONTROL_PLANE_AUTH_TOKEN }
if ($env:CONTROL_PLANE_ADMIN_EMAIL) { $AdminEmail = $env:CONTROL_PLANE_ADMIN_EMAIL }
if ($env:CONTROL_PLANE_ADMIN_PASSWORD) { $AdminPassword = $env:CONTROL_PLANE_ADMIN_PASSWORD }
if ($env:CONTROL_PLANE_ADMIN_SESSION_TOKEN) { $AdminSessionToken = $env:CONTROL_PLANE_ADMIN_SESSION_TOKEN }
if ($env:CONTROL_PLANE_CRUD_PROJECT_ID) { $ProjectId = $env:CONTROL_PLANE_CRUD_PROJECT_ID }
if ($env:CONTROL_PLANE_CRUD_OUTPUT_PATH) { $OutputPath = $env:CONTROL_PLANE_CRUD_OUTPUT_PATH }
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  $OutputPath = ".tmp/control-plane/control_plane_management_parity_smoke.json"
}
if ($env:CONTROL_PLANE_FULL_CRUD -eq "1") { $IncludeFullCrud = $true }
if ($env:STRICT_CONTROL_PLANE_FULL_CRUD -eq "1") { $StrictFullCrud = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_CRUD_DRY_RUN) { $DryRun = $true }
if ($StrictFullCrud) { $IncludeFullCrud = $true }
if ([string]::IsNullOrWhiteSpace($AdminSessionToken) -and -not [string]::IsNullOrWhiteSpace($ControlPlaneAuthToken) -and $ControlPlaneAuthToken -ne "devkey") {
  $AdminSessionToken = $ControlPlaneAuthToken
}

$script:AdminSessionToken = $AdminSessionToken
$script:ProviderKeySecret = ""

Add-Type -AssemblyName System.Net.Http

function Redact-SecretLikeString {
  param([AllowNull()][string]$Text)

  if ($null -eq $Text) {
    return ""
  }

  $redacted = $Text
  foreach ($knownSecret in @($GatewayAuthToken, $ControlPlaneAuthToken, $AdminPassword, $AdminSessionToken, $script:AdminSessionToken, $script:ProviderKeySecret)) {
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
  $redacted = $redacted -replace 'cp-crud-provider-key-[A-Za-z0-9._~+\-/=]+', '[REDACTED]'
  $redacted = $redacted -replace '(?i)\$env:[A-Z0-9_]*(?:token|password|passwd|secret|api[_-]?key|access[_-]?key|private[_-]?key|provider[_-]?key)[A-Z0-9_]*', '[REDACTED]'
  $redacted = $redacted -replace '(?i)(?<![A-Za-z0-9_])env:[/\\]?[A-Z0-9_]*(?:token|password|passwd|secret|api[_-]?key|access[_-]?key|private[_-]?key|provider[_-]?key)[A-Z0-9_]*', '[REDACTED]'
  $redacted = $redacted -replace '(?i)\$\{[A-Z0-9_]*(?:token|password|passwd|secret|api[_-]?key|access[_-]?key|private[_-]?key|provider[_-]?key)[A-Z0-9_]*\}', '[REDACTED]'
  return $redacted
}

function Resolve-RepoPath {
  param([Parameter(Mandatory = $true)][string]$Path)

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }

  return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Get-RepoRelativePath {
  param([Parameter(Mandatory = $true)][string]$Path)

  $full = [System.IO.Path]::GetFullPath($Path)
  $prefix = $repoRoot.Path.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
  if ($full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    return ($full.Substring($prefix.Length) -replace "\\", "/")
  }

  return ($full -replace "\\", "/")
}

function Assert-OutputPathIsSafe {
  param([Parameter(Mandatory = $true)][string]$Path)

  $full = Resolve-RepoPath $Path
  $relative = Get-RepoRelativePath $full
  if ($relative.StartsWith("..", [System.StringComparison]::Ordinal) -or [System.IO.Path]::IsPathRooted($relative)) {
    throw "OutputPath must stay inside the repository."
  }
  if (-not ($relative.StartsWith(".tmp/control-plane/", [System.StringComparison]::OrdinalIgnoreCase) -or $relative.StartsWith(".tmp/open-source-alpha/", [System.StringComparison]::OrdinalIgnoreCase))) {
    throw "OutputPath must stay under .tmp/control-plane/ or .tmp/open-source-alpha/."
  }

  return $full
}

function Test-SecretSafeText {
  param([AllowNull()][string]$Text)

  if ([string]::IsNullOrEmpty($Text)) {
    return $true
  }

  foreach ($knownSecret in @($ControlPlaneAuthToken, $AdminPassword, $AdminSessionToken, $script:AdminSessionToken, $script:ProviderKeySecret)) {
    if (-not [string]::IsNullOrEmpty($knownSecret) -and $Text.Contains([string]$knownSecret)) {
      return $false
    }
  }

  foreach ($pattern in @(
      '(?i)authorization\s*[:=]\s*bearer\s+[^"\s,}]+',
      '(?i)cookie\s*[:=]',
      '(?i)x-admin-session\s*[:=]',
      '(?i)"session_token_once"\s*:',
      '(?i)"secret"\s*:\s*"[^"]{4,}"',
      '(?i)"api_key"\s*:\s*"[^"]{4,}"',
      '(?i)"encrypted_secret"\s*:',
      '(?i)"secret_fingerprint"\s*:',
      '(?i)postgres(?:ql)?://[^"\s]+',
      '(?i)password\s*[:=]\s*[^"\s,}]+',
      'sk-[A-Za-z0-9._~+\-/=]{8,}',
      'sess_[A-Za-z0-9._~+/\-=]{8,}',
      'cp-crud-provider-key-[A-Za-z0-9._~+\-/=]{4,}'
    )) {
    if ($Text -match $pattern) {
      return $false
    }
  }

  return $true
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

function Join-Url {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$Path
  )

  return $BaseUrl.TrimEnd("/") + $Path
}

function Invoke-ApiRequest {
  param(
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Uri,
    [object]$Body = $null,
    [int]$TimeoutSec = $TimeoutSeconds
  )

  $client = New-Object System.Net.Http.HttpClient
  $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
  $request = New-Object System.Net.Http.HttpRequestMessage -ArgumentList (New-Object System.Net.Http.HttpMethod -ArgumentList $Method), $Uri
  if (-not [string]::IsNullOrWhiteSpace($script:AdminSessionToken)) {
    [void]$request.Headers.TryAddWithoutValidation("X-Admin-Session", $script:AdminSessionToken)
  }

  if (($Method -eq "GET" -or $Method -eq "HEAD") -and $null -ne $Body) {
    throw "$Method requests must not include a JSON body"
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
  } finally {
    if ($response) { $response.Dispose() }
    $request.Dispose()
    $client.Dispose()
  }
}

function Assert-StatusAny {
  param(
    [Parameter(Mandatory = $true)]$Response,
    [Parameter(Mandatory = $true)][int[]]$Expected
  )

  if ($Expected -notcontains $Response.StatusCode) {
    throw "expected HTTP $($Expected -join '/'), got HTTP $($Response.StatusCode): $($Response.Content)"
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

function Initialize-AdminSession {
  if (-not [string]::IsNullOrWhiteSpace($script:AdminSessionToken) -or $SkipAdminLogin) {
    return
  }

  $response = Invoke-ApiRequest -Method POST -Uri (Join-Url $ControlPlaneBaseUrl "/admin/auth/login") -Body @{
    email = $AdminEmail
    password = $AdminPassword
  }
  Assert-StatusAny $response @(200)
  $payload = Read-Json $response.Content
  $token = $payload.data.session_token_once
  if ([string]::IsNullOrWhiteSpace($token)) {
    throw "login response did not include a one-time admin session token"
  }

  $script:AdminSessionToken = [string]$token
}

function Get-CreatedId {
  param(
    [Parameter(Mandatory = $true)]$Payload,
    [Parameter(Mandatory = $true)][string]$ResourceName
  )

  foreach ($candidate in @(
      $Payload.id,
      $Payload.data.id,
      $Payload.$ResourceName.id
    )) {
    if ($candidate) {
      return [string]$candidate
    }
  }

  throw "created $ResourceName response does not expose id/data.id/$ResourceName.id"
}

function Test-JsonContainsId {
  param(
    [object]$Value,
    [Parameter(Mandatory = $true)][string]$Id
  )

  if ($null -eq $Value) { return $false }

  if ($Value -is [string] -or $Value.GetType().IsValueType) {
    return $false
  }

  if ($Value -is [System.Collections.IEnumerable]) {
    foreach ($item in $Value) {
      if (Test-JsonContainsId -Value $item -Id $Id) {
        return $true
      }
    }
    return $false
  }

  foreach ($property in $Value.PSObject.Properties) {
    if ($property.Name -eq "id" -and [string]$property.Value -eq $Id) {
      return $true
    }

    if (Test-JsonContainsId -Value $property.Value -Id $Id) {
      return $true
    }
  }

  return $false
}

function Assert-JsonContainsId {
  param(
    [Parameter(Mandatory = $true)][string]$Content,
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$ResourceName
  )

  if (-not (Test-JsonContainsId -Value (Read-Json $Content) -Id $Id)) {
    throw "$ResourceName list response does not include created id $Id"
  }
}

function Test-JsonContainsPropertyValue {
  param(
    [object]$Value,
    [Parameter(Mandatory = $true)][string]$PropertyName,
    [Parameter(Mandatory = $true)][object]$Expected
  )

  if ($null -eq $Value) { return $false }

  if ($Value -is [string] -or $Value.GetType().IsValueType) {
    return $false
  }

  if ($Value -is [System.Collections.IEnumerable]) {
    foreach ($item in $Value) {
      if (Test-JsonContainsPropertyValue -Value $item -PropertyName $PropertyName -Expected $Expected) {
        return $true
      }
    }
    return $false
  }

  foreach ($property in $Value.PSObject.Properties) {
    if ($property.Name -eq $PropertyName -and [string]$property.Value -eq [string]$Expected) {
      return $true
    }

    if (Test-JsonContainsPropertyValue -Value $property.Value -PropertyName $PropertyName -Expected $Expected) {
      return $true
    }
  }

  return $false
}

function Assert-JsonContainsPropertyValue {
  param(
    [Parameter(Mandatory = $true)][string]$Content,
    [Parameter(Mandatory = $true)][string]$PropertyName,
    [Parameter(Mandatory = $true)][object]$Expected
  )

  if (-not (Test-JsonContainsPropertyValue -Value (Read-Json $Content) -PropertyName $PropertyName -Expected $Expected)) {
    throw "response does not include JSON property '$PropertyName' with value '$Expected'"
  }
}

function Get-JsonPropertyValue {
  param(
    [AllowNull()]$Object,
    [Parameter(Mandatory = $true)][string]$Name,
    $Default = $null
  )

  if ($null -eq $Object) {
    return $Default
  }

  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $Default
  }

  return $property.Value
}

function Assert-JsonOmitsSensitiveProviderKeyMaterial {
  param(
    [Parameter(Mandatory = $true)][string]$Content,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if (-not (Test-SecretSafeText $Content)) {
    throw "$Name response contains secret-like material"
  }
}

function Assert-ProviderKeyResponseIsRedacted {
  param(
    [Parameter(Mandatory = $true)]$Payload,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $data = Get-JsonPropertyValue -Object $Payload -Name "data" -Default $Payload
  if ($null -eq $data) {
    throw "$Name response does not include data"
  }
  if ((Get-JsonPropertyValue -Object $data -Name "credential_configured" -Default $null) -ne $true) {
    throw "$Name response did not report credential_configured=true"
  }
  if ((Get-JsonPropertyValue -Object $data -Name "secret_redacted" -Default $null) -ne $true) {
    throw "$Name response did not report secret_redacted=true"
  }
  foreach ($field in @("secret", "api_key", "encrypted_secret", "secret_fingerprint", "has_secret_fingerprint")) {
    if ($data.PSObject.Properties.Name -contains $field) {
      throw "$Name response exposed provider key field '$field'"
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
    Write-SafeHost "[OK] $Name"
  } catch {
    Add-Failure "[FAIL] $Name - $($_.Exception.Message)"
  }
}

function Report-PendingOrFail {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Message,
    [switch]$Strict
  )

  if ($Strict) {
    Add-Failure "[FAIL] $Name - $Message"
    return
  }

  Add-Pending "[PENDING] $Name - $Message"
}

function Check-FullCrud {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Uri,
    [object]$Body = $null,
    [Parameter(Mandatory = $true)][int[]]$Expected,
    [Parameter(Mandatory = $true)][string]$PendingMessage,
    [scriptblock]$Assert = $null
  )

  try {
    $response = Invoke-ApiRequest -Method $Method -Uri $Uri -Body $Body
    if ($response.StatusCode -eq 404 -or $response.StatusCode -eq 405) {
      Report-PendingOrFail -Name $Name -Message $PendingMessage -Strict:$StrictFullCrud
      return
    }

    Assert-StatusAny $response $Expected
    if ($Assert) {
      & $Assert $response
    }

    Write-SafeHost "[OK] $Name"
  } catch {
    Add-Failure "[FAIL] $Name - $($_.Exception.Message)"
  }
}

function Assert-PatchedResource {
  param(
    [Parameter(Mandatory = $true)]$PatchResponse,
    [Parameter(Mandatory = $true)][string]$GetPath,
    [Parameter(Mandatory = $true)][string]$PropertyName,
    [Parameter(Mandatory = $true)][object]$Expected
  )

  if ($PatchResponse.StatusCode -eq 204 -or [string]::IsNullOrWhiteSpace($PatchResponse.Content)) {
    $getResponse = Invoke-ApiRequest -Method GET -Uri (Join-Url $ControlPlaneBaseUrl $GetPath)
    Assert-StatusAny $getResponse @(200)
    Assert-JsonContainsPropertyValue $getResponse.Content $PropertyName $Expected
    return
  }

  try {
    Assert-JsonContainsPropertyValue $PatchResponse.Content $PropertyName $Expected
  } catch {
    $getResponse = Invoke-ApiRequest -Method GET -Uri (Join-Url $ControlPlaneBaseUrl $GetPath)
    Assert-StatusAny $getResponse @(200)
    Assert-JsonContainsPropertyValue $getResponse.Content $PropertyName $Expected
  }
}

function Assert-DeletedResource {
  param(
    [Parameter(Mandatory = $true)][string]$GetPath,
    [Parameter(Mandatory = $true)][string]$ResourceName
  )

  $getResponse = Invoke-ApiRequest -Method GET -Uri (Join-Url $ControlPlaneBaseUrl $GetPath)
  if ($getResponse.StatusCode -eq 404) {
    return
  }

  if ($getResponse.StatusCode -eq 200) {
    Assert-JsonContainsPropertyValue $getResponse.Content "status" "deleted"
    return
  }

  throw "expected deleted $ResourceName to return HTTP 404 or status=deleted, got HTTP $($getResponse.StatusCode): $($getResponse.Content)"
}

function Assert-HasId {
  param(
    [object]$Value,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if (-not $Value) {
    throw "$Name is missing because the prerequisite create step did not pass"
  }
}

$suffix = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$providerId = $null
$channelId = $null
$modelId = $null
$associationId = $null
$providerKeyId = $null
$profileId = $null
$routeDryRunStatus = "not_run"
$routeDryRunFallbackAllowed = $null
$routeDryRunSelectedChannelId = $null
$routeDryRunCandidateCount = 0
$providerKeySecretRedacted = $false
$providerKeyCredentialConfigured = $false
$profileCreated = $false

if ($DryRun) {
  Write-SafeHost ""
  Write-SafeHost "Control Plane CRUD smoke dry-run passed; runtime requests were not sent."
  exit 0
}

Check "control-plane admin login" {
  Initialize-AdminSession
  if ([string]::IsNullOrWhiteSpace($script:AdminSessionToken) -and -not $SkipAdminLogin) {
    throw "admin session token was not initialized"
  }
}

Check "control-plane create provider" {
  $response = Invoke-ApiRequest -Method POST -Uri (Join-Url $ControlPlaneBaseUrl "/admin/providers") -Body @{
    code = "mock-provider-$suffix"
    name = "Mock Provider $suffix"
    provider_type = "openai_compatible"
    base_url = "http://mock-provider:18080"
    status = "active"
  }
  Assert-StatusAny $response @(200, 201)
  $providerId = Get-CreatedId -Payload (Read-Json $response.Content) -ResourceName "provider"
  Set-Variable -Name providerId -Value $providerId -Scope Script
}

Check "control-plane get provider" {
  Assert-HasId $script:providerId "provider id"
  $response = Invoke-ApiRequest -Method GET -Uri (Join-Url $ControlPlaneBaseUrl "/admin/providers/$script:providerId")
  Assert-StatusAny $response @(200)
  Assert-JsonContainsId $response.Content $script:providerId "provider"
}

Check "control-plane create channel" {
  Assert-HasId $script:providerId "provider id"
  $response = Invoke-ApiRequest -Method POST -Uri (Join-Url $ControlPlaneBaseUrl "/admin/channels") -Body @{
    provider_id = $script:providerId
    name = "mock-channel-$suffix"
    protocol = "openai_compatible"
    base_url = "http://mock-provider:18080"
    status = "active"
    priority = 10
    weight = 100
    tags = @("smoke", "mock")
  }
  Assert-StatusAny $response @(200, 201)
  $channelId = Get-CreatedId -Payload (Read-Json $response.Content) -ResourceName "channel"
  Set-Variable -Name channelId -Value $channelId -Scope Script
}

Check "control-plane create provider key through secret-management path" {
  Assert-HasId $script:channelId "channel id"
  $script:ProviderKeySecret = "cp-crud-provider-key-$suffix"
  $response = Invoke-ApiRequest -Method POST -Uri (Join-Url $ControlPlaneBaseUrl "/admin/provider-keys") -Body @{
    channel_id = $script:channelId
    key_alias = "mock-provider-key-$suffix"
    secret = $script:ProviderKeySecret
    status = "enabled"
    metadata = @{
      smoke = $true
      source = "control-plane-crud-smoke"
    }
  }
  Assert-StatusAny $response @(200, 201)
  Assert-JsonOmitsSensitiveProviderKeyMaterial -Content $response.Content -Name "provider key create"
  $payload = Read-Json $response.Content
  Assert-ProviderKeyResponseIsRedacted -Payload $payload -Name "provider key create"
  $providerKeyId = Get-CreatedId -Payload $payload -ResourceName "provider_key"
  Set-Variable -Name providerKeyId -Value $providerKeyId -Scope Script
  $script:providerKeySecretRedacted = $true
  $script:providerKeyCredentialConfigured = $true
}

Check "control-plane get provider key redacts credential material" {
  Assert-HasId $script:providerKeyId "provider key id"
  $response = Invoke-ApiRequest -Method GET -Uri (Join-Url $ControlPlaneBaseUrl "/admin/provider-keys/$script:providerKeyId")
  Assert-StatusAny $response @(200)
  Assert-JsonContainsId $response.Content $script:providerKeyId "provider key"
  Assert-JsonOmitsSensitiveProviderKeyMaterial -Content $response.Content -Name "provider key get"
  Assert-ProviderKeyResponseIsRedacted -Payload (Read-Json $response.Content) -Name "provider key get"
}

Check "control-plane get channel" {
  Assert-HasId $script:channelId "channel id"
  $response = Invoke-ApiRequest -Method GET -Uri (Join-Url $ControlPlaneBaseUrl "/admin/channels/$script:channelId")
  Assert-StatusAny $response @(200)
  Assert-JsonContainsId $response.Content $script:channelId "channel"
}

Check "control-plane create canonical model" {
  $response = Invoke-ApiRequest -Method POST -Uri (Join-Url $ControlPlaneBaseUrl "/admin/models") -Body @{
    name = "canonical/mock-gpt-4o-mini-$suffix"
    display_name = "Mock GPT 4o Mini $suffix"
    family = "chat"
    visibility = "public"
    status = "active"
  }
  Assert-StatusAny $response @(200, 201)
  $modelId = Get-CreatedId -Payload (Read-Json $response.Content) -ResourceName "model"
  Set-Variable -Name modelId -Value $modelId -Scope Script
}

Check "control-plane create api key profile" {
  Assert-HasId $script:modelId "model id"
  $profileName = "crud-profile-$suffix"
  $response = Invoke-ApiRequest -Method POST -Uri (Join-Url $ControlPlaneBaseUrl "/admin/api-key-profiles") -Body @{
    project_id = $ProjectId
    name = $profileName
    inbound_protocol = "openai"
    default_protocol_mode = "openai_compatible"
    allowed_models = @("canonical/mock-gpt-4o-mini-$suffix")
    denied_models = @()
    allowed_channel_tags = @("smoke")
    blocked_provider_ids = @()
    trace_header_rules = @{}
    ip_allowlist = @()
    request_overrides = @()
    status = "active"
  }
  Assert-StatusAny $response @(200, 201)
  $profileId = Get-CreatedId -Payload (Read-Json $response.Content) -ResourceName "api_key_profile"
  Set-Variable -Name profileId -Value $profileId -Scope Script
  $script:profileCreated = $true
}

Check "control-plane get api key profile" {
  Assert-HasId $script:profileId "api key profile id"
  $response = Invoke-ApiRequest -Method GET -Uri (Join-Url $ControlPlaneBaseUrl "/admin/api-key-profiles/$script:profileId")
  Assert-StatusAny $response @(200)
  Assert-JsonContainsId $response.Content $script:profileId "api key profile"
  Assert-JsonContainsPropertyValue $response.Content "project_id" $ProjectId
}

Check "control-plane get canonical model" {
  Assert-HasId $script:modelId "model id"
  $response = Invoke-ApiRequest -Method GET -Uri (Join-Url $ControlPlaneBaseUrl "/admin/models/$script:modelId")
  Assert-StatusAny $response @(200)
  Assert-JsonContainsId $response.Content $script:modelId "model"
}

Check "control-plane create model association" {
  Assert-HasId $script:modelId "model id"
  Assert-HasId $script:channelId "channel id"
  $response = Invoke-ApiRequest -Method POST -Uri (Join-Url $ControlPlaneBaseUrl "/admin/model-associations") -Body @{
    canonical_model_id = $script:modelId
    association_type = "explicit_channel"
    channel_id = $script:channelId
    upstream_model_name = "mock-gpt-4o-mini"
    priority = 10
    fallback_allowed = $false
    status = "active"
  }
  Assert-StatusAny $response @(200, 201)
  $associationId = Get-CreatedId -Payload (Read-Json $response.Content) -ResourceName "association"
  Set-Variable -Name associationId -Value $associationId -Scope Script
}

Check "control-plane get model association" {
  Assert-HasId $script:associationId "association id"
  $response = Invoke-ApiRequest -Method GET -Uri (Join-Url $ControlPlaneBaseUrl "/admin/model-associations/$script:associationId")
  Assert-StatusAny $response @(200)
  Assert-JsonContainsId $response.Content $script:associationId "association"
}

Check "control-plane model association dry-run returns selected route and fallback policy" {
  Assert-HasId $script:profileId "api key profile id"
  Assert-HasId $script:modelId "model id"
  Assert-HasId $script:channelId "channel id"
  $response = Invoke-ApiRequest -Method POST -Uri (Join-Url $ControlPlaneBaseUrl "/admin/model-associations/dry-run") -Body @{
    project_id = $ProjectId
    profile_id = $script:profileId
    requested_model = "canonical/mock-gpt-4o-mini-$suffix"
    canonical_model_id = $script:modelId
    seed = 42
  }
  Assert-StatusAny $response @(200)
  Assert-JsonOmitsSensitiveProviderKeyMaterial -Content $response.Content -Name "model association dry-run"
  $payload = Read-Json $response.Content
  $data = Get-JsonPropertyValue -Object $payload -Name "data"
  $selection = Get-JsonPropertyValue -Object $data -Name "selection"
  $status = [string](Get-JsonPropertyValue -Object $selection -Name "status")
  if ($status -ne "selected") {
    throw "dry-run expected selection.status=selected, got '$status'"
  }
  $selectedCandidate = Get-JsonPropertyValue -Object $data -Name "selected_candidate"
  if ($null -eq $selectedCandidate) {
    throw "dry-run did not return selected_candidate"
  }
  $selectedChannelId = [string](Get-JsonPropertyValue -Object $selectedCandidate -Name "channel_id")
  if ($selectedChannelId -ne $script:channelId) {
    throw "dry-run selected channel '$selectedChannelId', expected '$script:channelId'"
  }
  $fallbackAllowed = Get-JsonPropertyValue -Object $selectedCandidate -Name "fallback_allowed"
  if ($fallbackAllowed -ne $false) {
    throw "dry-run selected_candidate.fallback_allowed expected false"
  }
  $candidates = @(Get-JsonPropertyValue -Object $data -Name "candidates" -Default @())
  if ($candidates.Count -lt 1) {
    throw "dry-run did not return route candidates"
  }
  $script:routeDryRunStatus = $status
  $script:routeDryRunFallbackAllowed = $fallbackAllowed
  $script:routeDryRunSelectedChannelId = $selectedChannelId
  $script:routeDryRunCandidateCount = $candidates.Count
}

if ($IncludeFullCrud) {
  Check-FullCrud -Name "control-plane list providers" -Method GET -Uri (Join-Url $ControlPlaneBaseUrl "/admin/providers") -Expected @(200) -PendingMessage "GET /admin/providers collection is not implemented yet." -Assert {
    param($response)
    Assert-JsonContainsId $response.Content $script:providerId "provider"
  }

  Check-FullCrud -Name "control-plane list channels" -Method GET -Uri (Join-Url $ControlPlaneBaseUrl "/admin/channels") -Expected @(200) -PendingMessage "GET /admin/channels collection is not implemented yet." -Assert {
    param($response)
    Assert-JsonContainsId $response.Content $script:channelId "channel"
  }

  Check-FullCrud -Name "control-plane list provider keys" -Method GET -Uri (Join-Url $ControlPlaneBaseUrl "/admin/provider-keys") -Expected @(200) -PendingMessage "GET /admin/provider-keys collection is not implemented yet." -Assert {
    param($response)
    Assert-JsonContainsId $response.Content $script:providerKeyId "provider key"
    Assert-JsonOmitsSensitiveProviderKeyMaterial -Content $response.Content -Name "provider key list"
  }

  Check-FullCrud -Name "control-plane list api key profiles" -Method GET -Uri (Join-Url $ControlPlaneBaseUrl "/admin/api-key-profiles?project_id=$ProjectId") -Expected @(200) -PendingMessage "GET /admin/api-key-profiles collection is not implemented yet." -Assert {
    param($response)
    Assert-JsonContainsId $response.Content $script:profileId "api key profile"
  }

  Check-FullCrud -Name "control-plane list canonical models" -Method GET -Uri (Join-Url $ControlPlaneBaseUrl "/admin/models") -Expected @(200) -PendingMessage "GET /admin/models collection is not implemented yet." -Assert {
    param($response)
    Assert-JsonContainsId $response.Content $script:modelId "model"
  }

  Check-FullCrud -Name "control-plane list model associations" -Method GET -Uri (Join-Url $ControlPlaneBaseUrl "/admin/model-associations") -Expected @(200) -PendingMessage "GET /admin/model-associations collection is not implemented yet." -Assert {
    param($response)
    Assert-JsonContainsId $response.Content $script:associationId "association"
  }

  $patchedProviderName = "Mock Provider Patched $suffix"
  Check-FullCrud -Name "control-plane patch provider" -Method PATCH -Uri (Join-Url $ControlPlaneBaseUrl "/admin/providers/$script:providerId") -Body @{
    name = $patchedProviderName
  } -Expected @(200, 204) -PendingMessage "PATCH /admin/providers/{id} is not implemented yet." -Assert {
    param($response)
    Assert-PatchedResource -PatchResponse $response -GetPath "/admin/providers/$script:providerId" -PropertyName "name" -Expected $patchedProviderName
  }

  $patchedChannelName = "mock-channel-patched-$suffix"
  Check-FullCrud -Name "control-plane patch channel" -Method PATCH -Uri (Join-Url $ControlPlaneBaseUrl "/admin/channels/$script:channelId") -Body @{
    name = $patchedChannelName
  } -Expected @(200, 204) -PendingMessage "PATCH /admin/channels/{id} is not implemented yet." -Assert {
    param($response)
    Assert-PatchedResource -PatchResponse $response -GetPath "/admin/channels/$script:channelId" -PropertyName "name" -Expected $patchedChannelName
  }

  Check-FullCrud -Name "control-plane patch provider key" -Method PATCH -Uri (Join-Url $ControlPlaneBaseUrl "/admin/provider-keys/$script:providerKeyId") -Body @{
    status = "manual_disabled"
    metadata = @{
      smoke = $true
      patched = $true
    }
  } -Expected @(200, 204) -PendingMessage "PATCH /admin/provider-keys/{id} is not implemented yet." -Assert {
    param($response)
    Assert-PatchedResource -PatchResponse $response -GetPath "/admin/provider-keys/$script:providerKeyId" -PropertyName "status" -Expected "manual_disabled"
    Assert-JsonOmitsSensitiveProviderKeyMaterial -Content $response.Content -Name "provider key patch"
  }

  Check-FullCrud -Name "control-plane patch provider key back to enabled" -Method PATCH -Uri (Join-Url $ControlPlaneBaseUrl "/admin/provider-keys/$script:providerKeyId") -Body @{
    status = "enabled"
  } -Expected @(200, 204) -PendingMessage "PATCH /admin/provider-keys/{id} is not implemented yet." -Assert {
    param($response)
    Assert-PatchedResource -PatchResponse $response -GetPath "/admin/provider-keys/$script:providerKeyId" -PropertyName "status" -Expected "enabled"
    Assert-JsonOmitsSensitiveProviderKeyMaterial -Content $response.Content -Name "provider key enable patch"
  }

  Check-FullCrud -Name "control-plane patch api key profile" -Method PATCH -Uri (Join-Url $ControlPlaneBaseUrl "/admin/api-key-profiles/$script:profileId") -Body @{
    name = "crud-profile-patched-$suffix"
  } -Expected @(200, 204) -PendingMessage "PATCH /admin/api-key-profiles/{id} is not implemented yet." -Assert {
    param($response)
    Assert-PatchedResource -PatchResponse $response -GetPath "/admin/api-key-profiles/$script:profileId" -PropertyName "name" -Expected "crud-profile-patched-$suffix"
  }

  $patchedDisplayName = "Mock GPT 4o Mini Patched $suffix"
  Check-FullCrud -Name "control-plane patch canonical model" -Method PATCH -Uri (Join-Url $ControlPlaneBaseUrl "/admin/models/$script:modelId") -Body @{
    display_name = $patchedDisplayName
  } -Expected @(200, 204) -PendingMessage "PATCH /admin/models/{id} is not implemented yet." -Assert {
    param($response)
    Assert-PatchedResource -PatchResponse $response -GetPath "/admin/models/$script:modelId" -PropertyName "display_name" -Expected $patchedDisplayName
  }

  Check-FullCrud -Name "control-plane patch model association" -Method PATCH -Uri (Join-Url $ControlPlaneBaseUrl "/admin/model-associations/$script:associationId") -Body @{
    priority = 11
  } -Expected @(200, 204) -PendingMessage "PATCH /admin/model-associations/{id} is not implemented yet." -Assert {
    param($response)
    Assert-PatchedResource -PatchResponse $response -GetPath "/admin/model-associations/$script:associationId" -PropertyName "priority" -Expected 11
  }

  Check-FullCrud -Name "control-plane delete model association" -Method DELETE -Uri (Join-Url $ControlPlaneBaseUrl "/admin/model-associations/$script:associationId") -Expected @(200, 202, 204) -PendingMessage "DELETE /admin/model-associations/{id} is not implemented yet." -Assert {
    Assert-DeletedResource -GetPath "/admin/model-associations/$script:associationId" -ResourceName "association"
  }

  Check-FullCrud -Name "control-plane delete api key profile" -Method DELETE -Uri (Join-Url $ControlPlaneBaseUrl "/admin/api-key-profiles/$script:profileId") -Expected @(200, 202, 204) -PendingMessage "DELETE /admin/api-key-profiles/{id} is not implemented yet." -Assert {
    Assert-DeletedResource -GetPath "/admin/api-key-profiles/$script:profileId" -ResourceName "api key profile"
  }

  Check-FullCrud -Name "control-plane delete canonical model" -Method DELETE -Uri (Join-Url $ControlPlaneBaseUrl "/admin/models/$script:modelId") -Expected @(200, 202, 204) -PendingMessage "DELETE /admin/models/{id} is not implemented yet." -Assert {
    Assert-DeletedResource -GetPath "/admin/models/$script:modelId" -ResourceName "model"
  }

  Check-FullCrud -Name "control-plane delete provider key" -Method DELETE -Uri (Join-Url $ControlPlaneBaseUrl "/admin/provider-keys/$script:providerKeyId") -Expected @(200, 202, 204) -PendingMessage "DELETE /admin/provider-keys/{id} is not implemented yet." -Assert {
    Assert-DeletedResource -GetPath "/admin/provider-keys/$script:providerKeyId" -ResourceName "provider key"
  }

  Check-FullCrud -Name "control-plane delete channel" -Method DELETE -Uri (Join-Url $ControlPlaneBaseUrl "/admin/channels/$script:channelId") -Expected @(200, 202, 204) -PendingMessage "DELETE /admin/channels/{id} is not implemented yet." -Assert {
    Assert-DeletedResource -GetPath "/admin/channels/$script:channelId" -ResourceName "channel"
  }

  Check-FullCrud -Name "control-plane delete provider" -Method DELETE -Uri (Join-Url $ControlPlaneBaseUrl "/admin/providers/$script:providerId") -Expected @(200, 202, 204) -PendingMessage "DELETE /admin/providers/{id} is not implemented yet." -Assert {
    Assert-DeletedResource -GetPath "/admin/providers/$script:providerId" -ResourceName "provider"
  }
}

if ($script:Failures.Count -gt 0) {
  $artifact = [ordered]@{
    schema = "control_plane_management_parity_smoke.v1"
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    status = "fail"
    strict_full_crud = [bool]$IncludeFullCrud
    project_id = $ProjectId
    routes = [ordered]@{
      admin_login = -not [string]::IsNullOrWhiteSpace($script:AdminSessionToken)
      provider = [ordered]@{ created = -not [string]::IsNullOrWhiteSpace($script:providerId) }
      channel = [ordered]@{ created = -not [string]::IsNullOrWhiteSpace($script:channelId) }
      provider_key = [ordered]@{
        created = -not [string]::IsNullOrWhiteSpace($script:providerKeyId)
        credential_configured = [bool]$script:providerKeyCredentialConfigured
        secret_redacted = [bool]$script:providerKeySecretRedacted
        raw_secret_omitted = $true
      }
      api_key_profile = [ordered]@{ created = [bool]$script:profileCreated }
      canonical_model = [ordered]@{ created = -not [string]::IsNullOrWhiteSpace($script:modelId) }
      model_association = [ordered]@{ created = -not [string]::IsNullOrWhiteSpace($script:associationId) }
      model_association_dry_run = [ordered]@{
        status = $script:routeDryRunStatus
        selected_channel_id_present = -not [string]::IsNullOrWhiteSpace($script:routeDryRunSelectedChannelId)
        candidate_count = [int]$script:routeDryRunCandidateCount
        fallback_allowed_observed = $script:routeDryRunFallbackAllowed
      }
    }
    secret_safe = $true
    raw_secret_omitted = $true
    raw_command_output_omitted = $true
    failures = @($script:Failures)
    pending = @($script:Pending)
  }
  $json = $artifact | ConvertTo-Json -Depth 16
  if (Test-SecretSafeText $json) {
    $outputFull = Assert-OutputPathIsSafe -Path $OutputPath
    $outputDir = Split-Path -Parent $outputFull
    if (-not (Test-Path -LiteralPath $outputDir)) {
      New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    }
    Set-Content -LiteralPath $outputFull -Encoding UTF8 -Value $json
    Write-SafeHost "control_plane_management_parity_artifact=$(Get-RepoRelativePath $outputFull)"
  }
  Write-SafeHost ""
  Write-SafeHost "Control Plane CRUD smoke failed:"
  foreach ($failure in $script:Failures) {
    Write-SafeHost $failure
  }
  exit 1
}

Write-SafeHost ""
if ($script:Pending.Count -gt 0) {
  Write-SafeHost "Control Plane CRUD baseline passed. Full CRUD checks pending:"
  foreach ($pending in $script:Pending) {
    Write-SafeHost $pending
  }
  exit 0
}

if ($IncludeFullCrud) {
  $artifactStatus = "pass"
  $artifact = [ordered]@{
    schema = "control_plane_management_parity_smoke.v1"
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    status = $artifactStatus
    strict_full_crud = [bool]$IncludeFullCrud
    project_id = $ProjectId
    routes = [ordered]@{
      admin_login = -not [string]::IsNullOrWhiteSpace($script:AdminSessionToken)
      provider = [ordered]@{ create_get = -not [string]::IsNullOrWhiteSpace($script:providerId); full_crud = $true }
      channel = [ordered]@{ create_get = -not [string]::IsNullOrWhiteSpace($script:channelId); full_crud = $true }
      provider_key = [ordered]@{
        create_get = -not [string]::IsNullOrWhiteSpace($script:providerKeyId)
        list_patch_delete = $true
        credential_configured = [bool]$script:providerKeyCredentialConfigured
        secret_redacted = [bool]$script:providerKeySecretRedacted
        encrypted_secret_response_omitted = $true
        fingerprint_response_omitted = $true
        raw_secret_omitted = $true
      }
      api_key_profile = [ordered]@{
        create_get = [bool]$script:profileCreated
        list_patch_delete = $true
        allowed_models_exercised = $true
        allowed_channel_tags_exercised = $true
      }
      canonical_model = [ordered]@{ create_get = -not [string]::IsNullOrWhiteSpace($script:modelId); full_crud = $true }
      model_association = [ordered]@{
        create_get = -not [string]::IsNullOrWhiteSpace($script:associationId)
        full_crud = $true
        fallback_allowed_written = $false
      }
      model_association_dry_run = [ordered]@{
        status = $script:routeDryRunStatus
        selected_channel_id_present = -not [string]::IsNullOrWhiteSpace($script:routeDryRunSelectedChannelId)
        candidate_count = [int]$script:routeDryRunCandidateCount
        fallback_allowed_observed = $script:routeDryRunFallbackAllowed
        upstream_call = $false
      }
    }
    replacement_parity_scope = [ordered]@{
      os_a1_02 = "provider/channel/provider-key/canonical-model/model-association/profile/fallback-policy Admin API smoke"
      admin_ui_required = $false
      documented_api_fallback = $true
    }
    secret_safe = $true
    raw_secret_omitted = $true
    raw_command_output_omitted = $true
    blockers = @()
    pending = @($script:Pending)
  }
  $json = $artifact | ConvertTo-Json -Depth 16
  if (-not (Test-SecretSafeText $json)) {
    throw "control plane management parity artifact failed secret-safe validation"
  }
  $outputFull = Assert-OutputPathIsSafe -Path $OutputPath
  $outputDir = Split-Path -Parent $outputFull
  if (-not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
  }
  Set-Content -LiteralPath $outputFull -Encoding UTF8 -Value $json
  Write-SafeHost "control_plane_management_parity_status=$artifactStatus"
  Write-SafeHost "control_plane_management_parity_artifact=$(Get-RepoRelativePath $outputFull)"
  Write-SafeHost "Control Plane CRUD full smoke passed."
} else {
  $artifactStatus = "pass"
  $artifact = [ordered]@{
    schema = "control_plane_management_parity_smoke.v1"
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    status = $artifactStatus
    strict_full_crud = [bool]$IncludeFullCrud
    project_id = $ProjectId
    routes = [ordered]@{
      admin_login = -not [string]::IsNullOrWhiteSpace($script:AdminSessionToken)
      provider = [ordered]@{ create_get = -not [string]::IsNullOrWhiteSpace($script:providerId) }
      channel = [ordered]@{ create_get = -not [string]::IsNullOrWhiteSpace($script:channelId) }
      provider_key = [ordered]@{
        create_get = -not [string]::IsNullOrWhiteSpace($script:providerKeyId)
        credential_configured = [bool]$script:providerKeyCredentialConfigured
        secret_redacted = [bool]$script:providerKeySecretRedacted
        raw_secret_omitted = $true
      }
      api_key_profile = [ordered]@{ create_get = [bool]$script:profileCreated }
      canonical_model = [ordered]@{ create_get = -not [string]::IsNullOrWhiteSpace($script:modelId) }
      model_association = [ordered]@{
        create_get = -not [string]::IsNullOrWhiteSpace($script:associationId)
        fallback_allowed_written = $false
      }
      model_association_dry_run = [ordered]@{
        status = $script:routeDryRunStatus
        selected_channel_id_present = -not [string]::IsNullOrWhiteSpace($script:routeDryRunSelectedChannelId)
        candidate_count = [int]$script:routeDryRunCandidateCount
        fallback_allowed_observed = $script:routeDryRunFallbackAllowed
        upstream_call = $false
      }
    }
    secret_safe = $true
    raw_secret_omitted = $true
    raw_command_output_omitted = $true
    blockers = @()
    pending = @($script:Pending)
  }
  $json = $artifact | ConvertTo-Json -Depth 16
  if (-not (Test-SecretSafeText $json)) {
    throw "control plane management parity artifact failed secret-safe validation"
  }
  $outputFull = Assert-OutputPathIsSafe -Path $OutputPath
  $outputDir = Split-Path -Parent $outputFull
  if (-not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
  }
  Set-Content -LiteralPath $outputFull -Encoding UTF8 -Value $json
  Write-SafeHost "control_plane_management_parity_status=$artifactStatus"
  Write-SafeHost "control_plane_management_parity_artifact=$(Get-RepoRelativePath $outputFull)"
  Write-SafeHost "Control Plane CRUD baseline smoke passed."
}
