param(
  [string]$ControlPlaneBaseUrl = "http://127.0.0.1:8081",
  [string]$ControlPlaneAuthToken = "devkey",
  [string]$AdminEmail = "admin@example.com",
  [string]$AdminPassword = "local-password",
  [string]$AdminSessionToken = "",
  [int]$TimeoutSeconds = 8,
  [switch]$IncludeFullCrud,
  [switch]$StrictFullCrud,
  [switch]$SkipAdminLogin,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
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
if ($env:CONTROL_PLANE_FULL_CRUD -eq "1") { $IncludeFullCrud = $true }
if ($env:STRICT_CONTROL_PLANE_FULL_CRUD -eq "1") { $StrictFullCrud = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_CRUD_DRY_RUN) { $DryRun = $true }
if ($StrictFullCrud) { $IncludeFullCrud = $true }
if ([string]::IsNullOrWhiteSpace($AdminSessionToken) -and -not [string]::IsNullOrWhiteSpace($ControlPlaneAuthToken) -and $ControlPlaneAuthToken -ne "devkey") {
  $AdminSessionToken = $ControlPlaneAuthToken
}

$script:AdminSessionToken = $AdminSessionToken

Add-Type -AssemblyName System.Net.Http

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

if ($IncludeFullCrud) {
  Check-FullCrud -Name "control-plane list providers" -Method GET -Uri (Join-Url $ControlPlaneBaseUrl "/admin/providers") -Expected @(200) -PendingMessage "GET /admin/providers collection is not implemented yet." -Assert {
    param($response)
    Assert-JsonContainsId $response.Content $script:providerId "provider"
  }

  Check-FullCrud -Name "control-plane list channels" -Method GET -Uri (Join-Url $ControlPlaneBaseUrl "/admin/channels") -Expected @(200) -PendingMessage "GET /admin/channels collection is not implemented yet." -Assert {
    param($response)
    Assert-JsonContainsId $response.Content $script:channelId "channel"
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

  Check-FullCrud -Name "control-plane delete canonical model" -Method DELETE -Uri (Join-Url $ControlPlaneBaseUrl "/admin/models/$script:modelId") -Expected @(200, 202, 204) -PendingMessage "DELETE /admin/models/{id} is not implemented yet." -Assert {
    Assert-DeletedResource -GetPath "/admin/models/$script:modelId" -ResourceName "model"
  }

  Check-FullCrud -Name "control-plane delete channel" -Method DELETE -Uri (Join-Url $ControlPlaneBaseUrl "/admin/channels/$script:channelId") -Expected @(200, 202, 204) -PendingMessage "DELETE /admin/channels/{id} is not implemented yet." -Assert {
    Assert-DeletedResource -GetPath "/admin/channels/$script:channelId" -ResourceName "channel"
  }

  Check-FullCrud -Name "control-plane delete provider" -Method DELETE -Uri (Join-Url $ControlPlaneBaseUrl "/admin/providers/$script:providerId") -Expected @(200, 202, 204) -PendingMessage "DELETE /admin/providers/{id} is not implemented yet." -Assert {
    Assert-DeletedResource -GetPath "/admin/providers/$script:providerId" -ResourceName "provider"
  }
}

if ($script:Failures.Count -gt 0) {
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
  Write-SafeHost "Control Plane CRUD full smoke passed."
} else {
  Write-SafeHost "Control Plane CRUD baseline smoke passed."
}
