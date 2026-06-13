param(
  [string]$ControlPlaneBaseUrl = "http://127.0.0.1:8081",
  [string]$AdminEmail = "admin@example.com",
  [string]$AdminPassword = "local-password",
  [string]$AdminSessionToken = "",
  [string]$ProviderKeyId = "00000000-0000-0000-0000-000000000075",
  [string]$OutputPath = ".tmp/control-plane/provider_key_audit_readback.json",
  [int]$TimeoutSeconds = 8,
  [ValidateSet("", "enabled", "manual_disabled", "degraded", "recovery_probe")]
  [string]$RestoreStatus = "",
  [switch]$SkipAdminLogin,
  [switch]$ExecuteMutation,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$fixturePath = Join-Path $repoRoot "tests\fixtures\control-plane\provider_key_status_contract.json"
$script:Failures = @()
$script:SensitiveValues = @()
$script:AdminSessionToken = $AdminSessionToken
$script:Observed = [ordered]@{}
$script:OriginalStatus = $null
$script:TargetStatus = $null

function Test-TruthyEnv {
  param([string]$Value)
  return $Value -eq "1" -or $Value -match "^(?i:true|yes|on)$"
}

if ($env:CONTROL_PLANE_BASE_URL) { $ControlPlaneBaseUrl = $env:CONTROL_PLANE_BASE_URL }
if ($env:CONTROL_PLANE_ADMIN_EMAIL) { $AdminEmail = $env:CONTROL_PLANE_ADMIN_EMAIL }
if ($env:CONTROL_PLANE_ADMIN_PASSWORD) { $AdminPassword = $env:CONTROL_PLANE_ADMIN_PASSWORD }
if ($env:CONTROL_PLANE_ADMIN_SESSION_TOKEN) { $script:AdminSessionToken = $env:CONTROL_PLANE_ADMIN_SESSION_TOKEN }
if ($env:PROVIDER_KEY_AUDIT_READBACK_ID) { $ProviderKeyId = $env:PROVIDER_KEY_AUDIT_READBACK_ID }
if ($env:PROVIDER_KEY_AUDIT_READBACK_OUTPUT_PATH) { $OutputPath = $env:PROVIDER_KEY_AUDIT_READBACK_OUTPUT_PATH }
if ($env:PROVIDER_KEY_AUDIT_READBACK_RESTORE_STATUS) { $RestoreStatus = $env:PROVIDER_KEY_AUDIT_READBACK_RESTORE_STATUS }
if (Test-TruthyEnv $env:PROVIDER_KEY_AUDIT_READBACK_EXECUTE_MUTATION) { $ExecuteMutation = $true }
if (Test-TruthyEnv $env:PROVIDER_KEY_AUDIT_READBACK_DRY_RUN) { $DryRun = $true }

Add-Type -AssemblyName System.Net.Http

function Add-SensitiveValue {
  param([AllowNull()][string]$Value)
  if (-not [string]::IsNullOrWhiteSpace($Value)) {
    $script:SensitiveValues += [string]$Value
  }
}

Add-SensitiveValue $AdminPassword
Add-SensitiveValue $script:AdminSessionToken

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
  $redacted = $redacted -replace '(?i)("password"\s*:\s*")[^"]+(")', '$1[REDACTED]$2'
  $redacted = $redacted -replace '(?i)(x-admin-session\s*[:=]\s*)[^\s";,]+', '$1[REDACTED]'
  $redacted = $redacted -replace '(?i)(authorization\s*[:=]\s*bearer\s+)[^\s";,]+', '$1[REDACTED]'
  $redacted = $redacted -replace '(?i)(Bearer\s+)[A-Za-z0-9._~+/\-]+=*', '$1[REDACTED]'
  $redacted = $redacted -replace '(?i)((?:password|passwd|secret|token|session|api[_-]?key|access[_-]?key|private[_-]?key|provider[_-]?key|fingerprint)\s*[:=]\s*)[^\s";,}]+', '$1[REDACTED]'
  $redacted = $redacted -replace 'sess_[A-Za-z0-9._~+/\-=]+', '[REDACTED]'
  $redacted = $redacted -replace 'sk-[A-Za-z0-9._~+\-/=]+', '[REDACTED]'
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

function Join-Url {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$Path
  )
  return $BaseUrl.TrimEnd("/") + $Path
}

function Read-Json {
  param([Parameter(Mandatory = $true)][string]$Content)
  try {
    return $Content | ConvertFrom-Json
  } catch {
    throw "expected JSON response: $($_.Exception.Message)"
  }
}

function Invoke-ApiRequest {
  param(
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Uri,
    [object]$Body = $null
  )

  $client = New-Object System.Net.Http.HttpClient
  $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
  $request = New-Object System.Net.Http.HttpRequestMessage -ArgumentList (New-Object System.Net.Http.HttpMethod -ArgumentList $Method), $Uri
  if (-not [string]::IsNullOrWhiteSpace($script:AdminSessionToken)) {
    [void]$request.Headers.TryAddWithoutValidation("X-Admin-Session", $script:AdminSessionToken)
  }

  if ($null -ne $Body) {
    if ($Method -eq "GET" -or $Method -eq "HEAD") {
      throw "$Method requests must not include a JSON body"
    }
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

function Assert-HttpStatus {
  param(
    [Parameter(Mandatory = $true)]$Response,
    [Parameter(Mandatory = $true)][int[]]$Expected
  )
  if (@($Expected | Where-Object { $_ -eq $Response.StatusCode }).Count -eq 0) {
    throw "expected HTTP $($Expected -join '/'), got HTTP $($Response.StatusCode): $(Redact-SecretLikeString $Response.Content)"
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
  Assert-HttpStatus -Response $response -Expected @(200)
  $payload = Read-Json $response.Content
  $token = [string]$payload.data.session_token_once
  if ([string]::IsNullOrWhiteSpace($token)) {
    throw "login response did not include data.session_token_once"
  }
  $script:AdminSessionToken = $token
  Add-SensitiveValue $token
}

function Test-SecretSafeText {
  param([AllowNull()][string]$Text)
  if ([string]::IsNullOrEmpty($Text)) { return $true }

  foreach ($secret in $script:SensitiveValues) {
    if (-not [string]::IsNullOrEmpty($secret) -and $Text.Contains($secret)) {
      return $false
    }
  }

  foreach ($pattern in @(
      '(?i)"(?:secret|api_key|encrypted_secret|secret_fingerprint|current_window_state)"\s*:',
      '(?i)"(?:authorization|cookie|x-admin-session)"\s*:',
      '(?i)authorization\s*[:=]\s*bearer\s+[^"\s,}]+',
      '(?i)fingerprint\s*[:=]\s*[^"\s,}]+',
      '(?i)encrypted[_-]?secret\s*[:=]\s*[^"\s,}]+',
      'sk-[A-Za-z0-9._~+\-/=]{8,}',
      'sess_[A-Za-z0-9._~+/\-=]{8,}'
    )) {
    if ($Text -match $pattern) {
      return $false
    }
  }
  return $true
}

function Assert-SecretSafeText {
  param(
    [AllowNull()][string]$Text,
    [Parameter(Mandatory = $true)][string]$Label
  )
  if (-not (Test-SecretSafeText $Text)) {
    throw "$Label contains forbidden credential material"
  }
}

function Assert-ProviderKeyPayloadSafe {
  param(
    [Parameter(Mandatory = $true)]$Payload,
    [Parameter(Mandatory = $true)][string]$Label
  )
  $data = $Payload.data
  if ($null -eq $data) { throw "$Label response does not include data" }
  if ([bool]$data.credential_configured -ne $true) { throw "$Label did not expose credential_configured=true" }
  if ([bool]$data.secret_redacted -ne $true) { throw "$Label did not expose secret_redacted=true" }
  foreach ($field in @("secret", "api_key", "encrypted_secret", "secret_fingerprint", "current_window_state", "Authorization", "authorization", "raw_endpoint", "endpoint", "raw_payload", "payload")) {
    if ($null -ne $data.PSObject.Properties[$field]) {
      throw "$Label unexpectedly returned $field"
    }
  }
  foreach ($field in @("lifecycle_state", "credential_generation", "last_probe_summary", "rotation_needed", "safe_next_action", "omitted_secret_policy")) {
    if ($null -eq $data.PSObject.Properties[$field]) {
      throw "$Label missing safe readback field $field"
    }
  }
  if ([bool]$data.omitted_secret_policy.key_secret_returned -ne $false) {
    throw "$Label omitted_secret_policy must keep key_secret_returned=false"
  }
  if ([bool]$data.omitted_secret_policy.raw_endpoint_returned -ne $false) {
    throw "$Label omitted_secret_policy must keep raw_endpoint_returned=false"
  }
  if ([bool]$data.omitted_secret_policy.raw_payload_returned -ne $false) {
    throw "$Label omitted_secret_policy must keep raw_payload_returned=false"
  }
  Assert-SecretSafeText -Text ($Payload | ConvertTo-Json -Depth 32 -Compress) -Label $Label
}

function Get-ProviderKey {
  $response = Invoke-ApiRequest -Method GET -Uri (Join-Url $ControlPlaneBaseUrl "/admin/provider-keys/$ProviderKeyId")
  Assert-HttpStatus -Response $response -Expected @(200)
  $payload = Read-Json $response.Content
  Assert-ProviderKeyPayloadSafe -Payload $payload -Label "provider key GET"
  return $payload.data
}

function Get-AuditLogs {
  param(
    [Parameter(Mandatory = $true)][string]$Action,
    [Parameter(Mandatory = $true)][string]$ResourceId
  )
  $path = "/admin/audit-logs?limit=20&action=$([uri]::EscapeDataString($Action))&resource_type=provider_key&resource_id=$([uri]::EscapeDataString($ResourceId))"
  $response = Invoke-ApiRequest -Method GET -Uri (Join-Url $ControlPlaneBaseUrl $path)
  Assert-HttpStatus -Response $response -Expected @(200)
  Assert-SecretSafeText -Text $response.Content -Label "audit log readback"
  return @((Read-Json $response.Content).data)
}

function Assert-ContractFixture {
  if (-not (Test-Path $fixturePath)) {
    throw "missing tests\fixtures\control-plane\provider_key_status_contract.json"
  }
  $fixture = Get-Content -Raw $fixturePath | ConvertFrom-Json
  if ($fixture.scenario -ne "control_plane_provider_key_status_contract") {
    throw "fixture scenario must be control_plane_provider_key_status_contract"
  }
  if ($fixture.read_contract.credential_material_omitted -ne $true) {
    throw "read contract must omit credential material"
  }
  if ($fixture.view_audit_contract.list_get_never_return_secret -ne $true) {
    throw "view audit contract must forbid secret readback"
  }
  if ($fixture.recovery_contract.audit_secret_safe -ne $true) {
    throw "recovery contract must require secret-safe audit"
  }
  if ($fixture.rotation_contract.audit_action -ne "provider_key.rotate") {
    throw "rotation contract must reserve provider_key.rotate action"
  }
  foreach ($field in @(
      "lifecycle_state",
      "credential_generation",
      "last_probe_summary",
      "rotation_needed",
      "safe_next_action",
      "omitted_secret_policy"
    )) {
    if ($fixture.read_contract.required_safe_readback_fields -notcontains $field) {
      throw "read contract must require safe readback field $field"
    }
  }
}

function Assert-SourceContract {
  $adminSource = Get-Content -Raw (Join-Path $repoRoot "apps\control-plane\src\admin.rs")
  $clientSource = Get-Content -Raw (Join-Path $repoRoot "web\admin-ui\src\api\client.ts")
  $uiSource = Get-Content -Raw (Join-Path $repoRoot "web\admin-ui\src\features\providers\ProviderKeysTable.tsx")

  foreach ($needle in @(
      "provider_key_response",
      '"credential_configured"',
      '"credential_generation"',
      '"lifecycle_state"',
      '"last_probe_summary"',
      '"rotation_needed"',
      '"safe_next_action"',
      '"omitted_secret_policy"',
      '"secret_redacted"',
      "reject_provider_key_secret_fields",
      "provider_key.recovery_request",
      "provider_key.rotate",
      "/admin/audit-logs"
    )) {
    if (-not $adminSource.Contains($needle)) {
      throw "Control Plane source missing provider-key audit/readback marker '$needle'"
    }
  }
  foreach ($forbiddenRoute in @("provider_key.view")) {
    if ($adminSource.Contains($forbiddenRoute)) {
      throw "unexpected implemented marker '$forbiddenRoute'; update verifier/runbook before claiming runtime rotation/view audit"
    }
  }
  if (-not $clientSource.Contains("requestProviderKeyRecovery")) {
    throw "Admin API client missing provider key recovery call"
  }
  foreach ($needle in @("credential_generation", "last_probe_summary", "rotation_needed", "omitted_secret_policy")) {
    if (-not $clientSource.Contains($needle)) {
      throw "Admin API client missing provider key lifecycle field $needle"
    }
  }
  if (-not $uiSource.Contains("sanitizeSecretJson")) {
    throw "ProviderKeysTable must sanitize metadata before display"
  }
  foreach ($needle in @("lifecycle_state", "credential_generation", "rotation_needed", "safe_next_action")) {
    if (-not $uiSource.Contains($needle)) {
      throw "ProviderKeysTable missing lifecycle/recovery readback field $needle"
    }
  }
}

function Resolve-OutputPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  $full = if ([System.IO.Path]::IsPathRooted($Path)) {
    [System.IO.Path]::GetFullPath($Path)
  } else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
  }
  $root = $repoRoot.Path.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
  if (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputPath must stay inside repository"
  }
  $relative = $full.Substring($root.Length) -replace "\\", "/"
  if (-not $relative.StartsWith(".tmp/control-plane/", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputPath must stay under .tmp/control-plane/"
  }
  return $full
}

function Write-Artifact {
  param([Parameter(Mandatory = $true)][string]$Status)
  $full = Resolve-OutputPath $OutputPath
  $directory = Split-Path -Parent $full
  if (-not (Test-Path $directory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }

  $artifact = [ordered]@{
    schema = "provider_key_audit_readback.v1"
    status = $Status
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    provider_key_id = $ProviderKeyId
    dry_run = [bool]$DryRun
    execute_mutation = [bool]$ExecuteMutation
    restore_status_override_used = (-not [string]::IsNullOrWhiteSpace($RestoreStatus))
    secret_safe = ($script:Failures.Count -eq 0)
    checks = $script:Observed
    external_dependencies = @{
      production_rotation_requires_kms_or_master_key_policy = $true
      runtime_rotate_endpoint_implemented = $true
      view_audit_endpoint_implemented = $false
    }
    failures = @($script:Failures)
  }
  $json = $artifact | ConvertTo-Json -Depth 32
  Assert-SecretSafeText -Text $json -Label "artifact"
  Set-Content -Path $full -Value $json -Encoding UTF8
}

Check "provider key status fixture contract" {
  Assert-ContractFixture
  $script:Observed.fixture_contract = "pass"
}

Check "provider key Control Plane/Admin UI source contract" {
  Assert-SourceContract
  $script:Observed.source_contract = "pass"
}

if (-not $DryRun) {
  Check "admin session initialized" {
    Initialize-AdminSession
    if ([string]::IsNullOrWhiteSpace($script:AdminSessionToken) -and -not $SkipAdminLogin) {
      throw "admin session token was not initialized"
    }
    $script:Observed.admin_session = "initialized"
  }

  Check "provider key GET readback is credential-safe" {
    $key = Get-ProviderKey
    $script:OriginalStatus = [string]$key.status
    $script:Observed.initial_status = $script:OriginalStatus
    $script:Observed.get_readback_secret_safe = $true
  }

  if ($ExecuteMutation) {
    $script:TargetStatus = if ($script:OriginalStatus -eq "degraded") { "recovery_probe" } else { "degraded" }
    Check "provider key status mutation is credential-safe" {
      $response = Invoke-ApiRequest -Method PATCH -Uri (Join-Url $ControlPlaneBaseUrl "/admin/provider-keys/$ProviderKeyId") -Body @{
        status = $script:TargetStatus
      }
      Assert-HttpStatus -Response $response -Expected @(200)
      $payload = Read-Json $response.Content
      Assert-ProviderKeyPayloadSafe -Payload $payload -Label "provider key PATCH"
      if ([string]$payload.data.status -ne $script:TargetStatus) {
        throw "provider key PATCH did not reach target status '$($script:TargetStatus)'"
      }
      $script:Observed.mutation_target_status = $script:TargetStatus
      $script:Observed.patch_response_secret_safe = $true
    }

    Check "provider key update audit readback is credential-safe" {
      $logs = @(Get-AuditLogs -Action "provider_key.update" -ResourceId $ProviderKeyId)
      if ($logs.Count -lt 1) {
        throw "provider_key.update audit log was not observed"
      }
      $script:Observed.update_audit_readback_count = $logs.Count
      $script:Observed.update_audit_secret_safe = $true
    }

    $restoreTargetStatus = if ([string]::IsNullOrWhiteSpace($RestoreStatus)) { $script:OriginalStatus } else { $RestoreStatus }
    if (-not [string]::IsNullOrWhiteSpace($restoreTargetStatus) -and $restoreTargetStatus -ne $script:TargetStatus) {
      Check "provider key original status restored" {
        $response = Invoke-ApiRequest -Method PATCH -Uri (Join-Url $ControlPlaneBaseUrl "/admin/provider-keys/$ProviderKeyId") -Body @{
          status = $restoreTargetStatus
        }
        Assert-HttpStatus -Response $response -Expected @(200)
        $payload = Read-Json $response.Content
        Assert-ProviderKeyPayloadSafe -Payload $payload -Label "provider key restore PATCH"
        if ([string]$payload.data.status -ne $restoreTargetStatus) {
          throw "provider key restore did not reach restore status '$restoreTargetStatus'"
        }
        $script:Observed.restored_status = $restoreTargetStatus
      }
    }
  } else {
    $script:Observed.mutation_skipped = "pass - rerun with -ExecuteMutation for bounded status/audit readback"
  }
} else {
  $script:Observed.live_readback_skipped = "dry_run"
}

$status = if ($script:Failures.Count -eq 0) { "pass" } else { "fail" }
Write-Artifact -Status $status

if ($script:Failures.Count -gt 0) {
  Write-SafeHost ""
  Write-SafeHost "Provider key audit readback verifier failed:"
  foreach ($failure in $script:Failures) {
    Write-SafeHost $failure
  }
  exit 1
}

Write-SafeHost ""
Write-SafeHost "Provider key audit readback verifier passed."
