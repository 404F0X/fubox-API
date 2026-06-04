param(
  [string]$ControlPlaneBaseUrl = "http://127.0.0.1:8081",
  [string]$AdminEmail = "admin@example.com",
  [string]$AdminPassword = "local-password",
  [string]$ProtectedEndpointPath = "/admin/providers",
  [ValidateSet("GET", "HEAD", "POST", "PUT", "PATCH", "DELETE")]
  [string]$ProtectedEndpointMethod = "GET",
  [string]$ViewerEmail = "",
  [string]$ViewerPassword = "",
  [string]$ViewerDeniedEndpointPath = "/admin/providers/00000000-0000-0000-0000-000000000000",
  [ValidateSet("GET", "HEAD", "POST", "PUT", "PATCH", "DELETE")]
  [string]$ViewerDeniedEndpointMethod = "PATCH",
  [string]$ComposeFile = "deploy/docker-compose/docker-compose.yml",
  [int]$TimeoutSeconds = 8,
  [switch]$StrictViewerRbacDenied,
  [switch]$RepairDevAdminSessionPrereqs,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$fixturePath = Join-Path $repoRoot "tests\fixtures\control-plane\admin_auth_smoke.json"
$devAdminSeedPath = Join-Path $repoRoot "db\dev-seeds\0001_dev_admin_seed.sql"
$devSmokeSeedReconcilePath = Join-Path $repoRoot "db\dev-seeds\0003_dev_smoke_seed_reconcile.sql"
$sessionMigrationPath = Join-Path $repoRoot "db\migrations\0005_e1_e2_e3_e10_integrity_hardening.sql"
$authSourcePath = Join-Path $repoRoot "apps\control-plane\src\auth.rs"
$rbacSourcePath = Join-Path $repoRoot "apps\control-plane\src\rbac.rs"

$script:Failures = @()
$script:Blockers = @()
$script:Pending = @()
$script:SensitiveValues = @()
$script:Fixture = $null
$script:AdminSessionToken = ""
$script:AdminLoginData = $null
$script:ViewerSessionToken = ""
$script:ViewerLoginData = $null
$script:ViewerDeniedProbeSafe = $false

function Test-TruthyEnv {
  param([string]$Value)

  return $Value -eq "1" -or $Value -match "^(?i:true|yes|on)$"
}

if ($env:CONTROL_PLANE_BASE_URL) { $ControlPlaneBaseUrl = $env:CONTROL_PLANE_BASE_URL }
if ($env:CONTROL_PLANE_ADMIN_EMAIL) { $AdminEmail = $env:CONTROL_PLANE_ADMIN_EMAIL }
if ($env:CONTROL_PLANE_ADMIN_PASSWORD) { $AdminPassword = $env:CONTROL_PLANE_ADMIN_PASSWORD }
if ($env:CONTROL_PLANE_AUTH_SMOKE_PROTECTED_PATH) { $ProtectedEndpointPath = $env:CONTROL_PLANE_AUTH_SMOKE_PROTECTED_PATH }
if ($env:CONTROL_PLANE_AUTH_SMOKE_PROTECTED_METHOD) { $ProtectedEndpointMethod = $env:CONTROL_PLANE_AUTH_SMOKE_PROTECTED_METHOD.ToUpperInvariant() }
if ($env:CONTROL_PLANE_VIEWER_EMAIL) { $ViewerEmail = $env:CONTROL_PLANE_VIEWER_EMAIL }
if ($env:CONTROL_PLANE_VIEWER_PASSWORD) { $ViewerPassword = $env:CONTROL_PLANE_VIEWER_PASSWORD }
if ($env:CONTROL_PLANE_VIEWER_DENIED_PATH) { $ViewerDeniedEndpointPath = $env:CONTROL_PLANE_VIEWER_DENIED_PATH }
if ($env:CONTROL_PLANE_VIEWER_DENIED_METHOD) { $ViewerDeniedEndpointMethod = $env:CONTROL_PLANE_VIEWER_DENIED_METHOD.ToUpperInvariant() }
if ($env:COMPOSE_FILE) { $ComposeFile = $env:COMPOSE_FILE }
if (Test-TruthyEnv $env:STRICT_CONTROL_PLANE_VIEWER_RBAC) { $StrictViewerRbacDenied = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_AUTH_SMOKE_REPAIR_DEV_ADMIN_SESSION_PREREQS) { $RepairDevAdminSessionPrereqs = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_AUTH_SMOKE_DRY_RUN) { $DryRun = $true }

Add-Type -AssemblyName System.Net.Http

function Add-SensitiveValue {
  param([AllowNull()][string]$Value)

  if (-not [string]::IsNullOrWhiteSpace($Value)) {
    $script:SensitiveValues += [string]$Value
  }
}

Add-SensitiveValue $AdminPassword
Add-SensitiveValue $ViewerPassword

function Redact-SecretLikeString {
  param([AllowNull()][string]$Text)

  if ($null -eq $Text) {
    return ""
  }

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
  $redacted = $redacted -replace '(?i)((?:password|passwd|secret|token|session|api[_-]?key|access[_-]?key|private[_-]?key)\s*[:=]\s*)[^\s";,}]+', '$1[REDACTED]'
  $redacted = $redacted -replace 'sess_[A-Za-z0-9._~+/\-=]+', '[REDACTED]'
  $redacted = $redacted -replace 'sk-[A-Za-z0-9._~+\-/=]+', '[REDACTED]'
  return $redacted
}

function Write-SafeHost {
  param([AllowNull()][string]$Text)

  Write-Host (Redact-SecretLikeString $Text)
}

function Format-ResponseContentForError {
  param([AllowNull()][string]$Content)

  $safe = Redact-SecretLikeString $Content
  if ($safe.Length -gt 800) {
    return $safe.Substring(0, 800) + "...[truncated]"
  }

  return $safe
}

function Add-Failure {
  param([Parameter(Mandatory = $true)][string]$Message)

  $safe = Redact-SecretLikeString $Message
  $script:Failures += $safe
  Write-Host $safe
}

function Add-Blocker {
  param([Parameter(Mandatory = $true)][string]$Message)

  $safe = Redact-SecretLikeString $Message
  $script:Blockers += $safe
  Write-SafeHost "[BLOCKED] $safe"
}

function Add-Pending {
  param([Parameter(Mandatory = $true)][string]$Message)

  $safe = Redact-SecretLikeString $Message
  $script:Pending += $safe
  Write-Host $safe
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
    Add-Failure "[FAIL] $Name - $($_.Exception.Message)"
  }
}

function Check-Blocking {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][scriptblock]$Action
  )

  try {
    & $Action
    Write-Host "[OK] $Name"
  } catch {
    Add-Blocker "$Name - $($_.Exception.Message)"
  }
}

function Exit-WithFailuresOrBlockers {
  if ($script:Failures.Count -gt 0) {
    Write-SafeHost ""
    Write-SafeHost "Control Plane admin auth smoke failed:"
    foreach ($failure in $script:Failures) {
      Write-SafeHost $failure
    }
    exit 1
  }

  if ($script:Blockers.Count -gt 0) {
    Write-SafeHost ""
    Write-SafeHost "Control Plane admin auth smoke is externally blocked:"
    foreach ($blocker in $script:Blockers) {
      Write-SafeHost $blocker
    }
    exit 2
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

function Join-Url {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$Path
  )

  $normalizedPath = $Path
  if (-not $normalizedPath.StartsWith("/")) {
    $normalizedPath = "/$normalizedPath"
  }

  return $BaseUrl.TrimEnd("/") + $normalizedPath
}

function Read-Json {
  param([Parameter(Mandatory = $true)][string]$Content)

  try {
    return $Content | ConvertFrom-Json
  } catch {
    throw "expected JSON response, got: $(Format-ResponseContentForError $Content)"
  }
}

function Get-ResponseData {
  param([Parameter(Mandatory = $true)]$Payload)

  if ($Payload.PSObject.Properties.Name -contains "data") {
    return $Payload.data
  }

  return $Payload
}

function Invoke-ApiRequest {
  param(
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Uri,
    [object]$Body = $null,
    [string]$SessionToken = "",
    [int]$TimeoutSec = $TimeoutSeconds
  )

  if (($Method -eq "GET" -or $Method -eq "HEAD") -and $null -ne $Body) {
    throw "$Method requests must not include a JSON body"
  }

  $client = New-Object System.Net.Http.HttpClient
  $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
  $request = New-Object System.Net.Http.HttpRequestMessage -ArgumentList (New-Object System.Net.Http.HttpMethod -ArgumentList $Method), $Uri

  if (-not [string]::IsNullOrWhiteSpace($SessionToken)) {
    [void]$request.Headers.TryAddWithoutValidation("X-Admin-Session", $SessionToken)
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
  } catch [System.Threading.Tasks.TaskCanceledException] {
    throw "request timed out after $TimeoutSec seconds"
  } finally {
    if ($response) { $response.Dispose() }
    $request.Dispose()
    $client.Dispose()
  }
}

function Get-DockerCommand {
  $docker = Get-Command docker -ErrorAction SilentlyContinue
  if (-not $docker) {
    throw "docker CLI is unavailable; cannot inspect compose auth prerequisites"
  }
  return $docker.Source
}

function Invoke-NativeCapture {
  param(
    [Parameter(Mandatory = $true)][string]$Command,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )

  $global:LASTEXITCODE = 0
  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & $Command @Arguments 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }

  return [pscustomobject]@{
    ExitCode = $exitCode
    Output = (($output | Out-String).Trim())
  }
}

function Get-NewestSourceWriteTimeUtc {
  param([Parameter(Mandatory = $true)][string[]]$SourcePaths)

  $newest = $null
  foreach ($path in $SourcePaths) {
    if (-not (Test-Path $path -PathType Leaf)) {
      continue
    }
    $writeTime = (Get-Item -Path $path).LastWriteTimeUtc
    if ($null -eq $newest -or $writeTime -gt $newest) {
      $newest = $writeTime
    }
  }
  return $newest
}

function Parse-DockerTimestampUtc {
  param([AllowNull()][string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $null
  }
  try {
    return ([DateTimeOffset]::Parse([string]$Value)).UtcDateTime
  } catch {
    return $null
  }
}

function Write-ControlPlaneRuntimeSourceProbe {
  param([Parameter(Mandatory = $true)][string[]]$SourcePaths)

  $sourceNewest = Get-NewestSourceWriteTimeUtc -SourcePaths $SourcePaths
  $sourceNewestText = if ($null -eq $sourceNewest) { "unavailable" } else { $sourceNewest.ToString("o") }
  $reason = "none"
  $staleOrUnverified = $false
  $containerCreatedText = "unavailable"
  $imageCreatedText = "unavailable"

  $docker = Get-Command docker -ErrorAction SilentlyContinue
  if (-not $docker) {
    $reason = "docker_unavailable"
    $staleOrUnverified = $true
  } else {
    $containerIdResult = Invoke-NativeCapture -Command $docker.Source -Arguments @("compose", "-f", $ComposeFile, "ps", "-q", "control-plane")
    $containerId = [string]$containerIdResult.Output
    if ($containerIdResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($containerId)) {
      $reason = "control_plane_container_unavailable"
      $staleOrUnverified = $true
    } else {
      $inspectResult = Invoke-NativeCapture -Command $docker.Source -Arguments @("inspect", "-f", "{{.Created}}|{{.Image}}", $containerId.Trim())
      if ($inspectResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($inspectResult.Output)) {
        $reason = "control_plane_container_inspect_unavailable"
        $staleOrUnverified = $true
      } else {
        $parts = ([string]$inspectResult.Output).Split("|", 2)
        $containerCreated = Parse-DockerTimestampUtc $parts[0]
        if ($null -ne $containerCreated) {
          $containerCreatedText = $containerCreated.ToString("o")
        }
        $imageId = if ($parts.Count -gt 1) { $parts[1] } else { "" }
        $imageInspectResult = Invoke-NativeCapture -Command $docker.Source -Arguments @("image", "inspect", "-f", "{{.Created}}", $imageId)
        $imageCreated = $null
        if ($imageInspectResult.ExitCode -eq 0) {
          $imageCreated = Parse-DockerTimestampUtc $imageInspectResult.Output
          if ($null -ne $imageCreated) {
            $imageCreatedText = $imageCreated.ToString("o")
          }
        }
        if ($null -eq $imageCreated) {
          $reason = "control_plane_image_inspect_unavailable"
          $staleOrUnverified = $true
        } elseif ($null -eq $sourceNewest) {
          $reason = "source_timestamp_unavailable"
          $staleOrUnverified = $true
        } elseif ($sourceNewest -gt $imageCreated) {
          $reason = "source_newer_than_runtime_image"
          $staleOrUnverified = $true
        }
      }
    }
  }

  Write-SafeHost "runtime_source_mismatch_probe=control_plane_image_timestamp"
  Write-SafeHost "runtime_source_newest_utc=$sourceNewestText"
  Write-SafeHost "runtime_container_created_utc=$containerCreatedText"
  Write-SafeHost "runtime_image_created_utc=$imageCreatedText"
  Write-SafeHost "runtime_image_stale_or_unverified=$(if ($staleOrUnverified) { 'true' } else { 'false' })"
  Write-SafeHost "runtime_image_stale_reason=$reason"
  Write-SafeHost "runtime_secret_material_echoed=false"
}

function Invoke-ComposePsql {
  param([Parameter(Mandatory = $true)][string]$Sql)

  $docker = Get-DockerCommand
  $global:LASTEXITCODE = 0
  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & $docker compose -f $ComposeFile exec -T postgres psql `
      -U ai_gateway `
      -d ai_gateway `
      -tA `
      -v ON_ERROR_STOP=1 `
      -c $Sql 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }
  if ($exitCode -ne 0) {
    throw "compose postgres psql failed: $(Redact-SecretLikeString (($output | Out-String).Trim()))"
  }

  return (($output | Out-String).Trim())
}

function Get-ComposeDbSqlPath {
  param([Parameter(Mandatory = $true)][string]$Path)

  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $dbRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "db")).TrimEnd("\", "/")
  $dbPrefix = $dbRoot + [System.IO.Path]::DirectorySeparatorChar
  if (-not $fullPath.StartsWith($dbPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "repair SQL path must stay inside repository db directory"
  }

  $relative = $fullPath.Substring($dbPrefix.Length).TrimStart("\", "/")
  if ([string]::IsNullOrWhiteSpace($relative) -or $relative.Contains("..")) {
    throw "repair SQL path has an unsafe relative component"
  }

  return "/app/db/$($relative -replace '\\', '/')"
}

function Invoke-ComposePsqlFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $repoPrefix = ([string]$repoRoot).TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
  if (-not $fullPath.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "repair SQL path must stay inside repository"
  }
  $allowed = @(
    [System.IO.Path]::GetFullPath($sessionMigrationPath),
    [System.IO.Path]::GetFullPath($devAdminSeedPath),
    [System.IO.Path]::GetFullPath($devSmokeSeedReconcilePath)
  )
  if ($allowed -notcontains $fullPath) {
    throw "repair SQL path is not in the auth prereq allowlist"
  }
  if (-not (Test-Path $fullPath -PathType Leaf)) {
    throw "repair SQL file is missing: $fullPath"
  }

  $docker = Get-DockerCommand
  $containerPath = Get-ComposeDbSqlPath -Path $fullPath
  $global:LASTEXITCODE = 0
  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & $docker compose -f $ComposeFile exec -T postgres psql `
      -U ai_gateway `
      -d ai_gateway `
      -v ON_ERROR_STOP=1 `
      -f $containerPath 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }
  if ($exitCode -ne 0) {
    throw "compose postgres repair failed for $([IO.Path]::GetFileName($fullPath)): $(Redact-SecretLikeString (($output | Out-String).Trim()))"
  }
}

function Get-AuthPrereqStatus {
  $json = Invoke-ComposePsql @"
select json_build_object(
  'user_sessions_table', to_regclass('public.user_sessions') is not null,
  'admin_user_count', (
    select count(*) from users
    where tenant_id = '00000000-0000-0000-0000-000000000001'
      and lower(email) = lower('admin@example.com')
  ),
  'admin_active_count', (
    select count(*) from users
    where tenant_id = '00000000-0000-0000-0000-000000000001'
      and lower(email) = lower('admin@example.com')
      and status = 'active'
      and deleted_at is null
  ),
  'admin_dev_seed_count', (
    select count(*) from users
    where tenant_id = '00000000-0000-0000-0000-000000000001'
      and lower(email) = lower('admin@example.com')
      and metadata->>'dev_seed' = 'true'
  ),
  'admin_password_hash_present', (
    select coalesce(bool_or(password_hash is not null), false) from users
    where tenant_id = '00000000-0000-0000-0000-000000000001'
      and lower(email) = lower('admin@example.com')
  ),
  'admin_password_hash_algorithm', (
    select coalesce(max(split_part(password_hash, '$', 1)), 'missing') from users
    where tenant_id = '00000000-0000-0000-0000-000000000001'
      and lower(email) = lower('admin@example.com')
  ),
  'team_owner_count', (
    select count(*) from team_members
    where tenant_id = '00000000-0000-0000-0000-000000000001'
      and team_id = '00000000-0000-0000-0000-000000000010'
      and user_id = '00000000-0000-0000-0000-0000000000a1'
      and role = 'owner'
  ),
  'project_owner_count', (
    select count(*) from project_members
    where tenant_id = '00000000-0000-0000-0000-000000000001'
      and project_id = '00000000-0000-0000-0000-000000000020'
      and user_id = '00000000-0000-0000-0000-0000000000a1'
      and role = 'owner'
  )
);
"@
  return Read-Json $json
}

function Get-AuthPrereqMissingReasons {
  param([Parameter(Mandatory = $true)]$Status)

  $missing = @()
  if ($Status.user_sessions_table -ne $true) { $missing += "user_sessions_migration_missing" }
  if ([int]$Status.admin_user_count -lt 1) { $missing += "dev_admin_user_missing" }
  if ([int]$Status.admin_active_count -lt 1) { $missing += "dev_admin_user_not_active" }
  if ([int]$Status.admin_dev_seed_count -lt 1) { $missing += "dev_admin_seed_marker_missing" }
  if ($Status.admin_password_hash_present -ne $true) { $missing += "dev_admin_password_hash_missing" }
  if ([string]$Status.admin_password_hash_algorithm -ne "pbkdf2-sha256") { $missing += "dev_admin_password_hash_algorithm_mismatch" }
  if ([int]$Status.team_owner_count -lt 1) { $missing += "dev_admin_team_owner_missing" }
  if ([int]$Status.project_owner_count -lt 1) { $missing += "dev_admin_project_owner_missing" }
  return @($missing)
}

function Write-AuthPrereqStatus {
  param(
    [Parameter(Mandatory = $true)]$Status,
    [string[]]$Missing = @()
  )

  Write-SafeHost "auth_prereq_user_sessions_table=$(if ($Status.user_sessions_table -eq $true) { 'present' } else { 'missing' })"
  Write-SafeHost "auth_prereq_admin_user_count=$([int]$Status.admin_user_count)"
  Write-SafeHost "auth_prereq_admin_active_count=$([int]$Status.admin_active_count)"
  Write-SafeHost "auth_prereq_admin_dev_seed_count=$([int]$Status.admin_dev_seed_count)"
  Write-SafeHost "auth_prereq_admin_password_hash_present=$(if ($Status.admin_password_hash_present -eq $true) { 'true' } else { 'false' })"
  Write-SafeHost "auth_prereq_admin_password_hash_algorithm=$([string]$Status.admin_password_hash_algorithm)"
  Write-SafeHost "auth_prereq_team_owner_count=$([int]$Status.team_owner_count)"
  Write-SafeHost "auth_prereq_project_owner_count=$([int]$Status.project_owner_count)"
  Write-SafeHost "auth_prereq_missing=$(if ($Missing.Count -eq 0) { 'none' } else { $Missing -join '+' })"
  Write-SafeHost "auth_prereq_secret_material_echoed=false"
}

function Repair-DevAdminSessionPrereqs {
  Write-SafeHost "auth_prereq_repair_mode=bounded_allowlist"
  foreach ($path in @($sessionMigrationPath, $devAdminSeedPath, $devSmokeSeedReconcilePath)) {
    Write-SafeHost "auth_prereq_repair_apply=$([IO.Path]::GetFileName($path))"
    Invoke-ComposePsqlFile -Path $path
  }
}

function Assert-OrRepairAuthPrereqs {
  $status = Get-AuthPrereqStatus
  $missing = @(Get-AuthPrereqMissingReasons -Status $status)
  Write-AuthPrereqStatus -Status $status -Missing $missing
  if ($missing.Count -eq 0) {
    return
  }

  if (-not $RepairDevAdminSessionPrereqs) {
    throw "auth prerequisites missing: $($missing -join '+'); rerun with -RepairDevAdminSessionPrereqs or CONTROL_PLANE_AUTH_SMOKE_REPAIR_DEV_ADMIN_SESSION_PREREQS=1 to apply db/migrations/0005_e1_e2_e3_e10_integrity_hardening.sql and bounded dev admin seeds"
  }

  Repair-DevAdminSessionPrereqs
  $after = Get-AuthPrereqStatus
  $afterMissing = @(Get-AuthPrereqMissingReasons -Status $after)
  Write-AuthPrereqStatus -Status $after -Missing $afterMissing
  if ($afterMissing.Count -gt 0) {
    throw "auth prerequisites still missing after repair: $($afterMissing -join '+')"
  }
}

function Assert-StatusAny {
  param(
    [Parameter(Mandatory = $true)]$Response,
    [Parameter(Mandatory = $true)][int[]]$Expected
  )

  if ($Expected -notcontains $Response.StatusCode) {
    throw "expected HTTP $($Expected -join '/'), got HTTP $($Response.StatusCode): $(Format-ResponseContentForError $Response.Content)"
  }
}

function Assert-ErrorCode {
  param(
    [Parameter(Mandatory = $true)]$Response,
    [Parameter(Mandatory = $true)][string]$ExpectedCode
  )

  $payload = Read-Json $Response.Content
  $actualCode = [string]$payload.error.code
  if ($actualCode -ne $ExpectedCode) {
    throw "expected error code '$ExpectedCode', got '$actualCode'"
  }
}

function Assert-AdminSessionData {
  param(
    [Parameter(Mandatory = $true)]$Data,
    [Parameter(Mandatory = $true)][string]$ExpectedEmail,
    [string]$ExpectedSessionId = ""
  )

  $actualEmail = [string]$Data.user.email
  if ([string]::IsNullOrWhiteSpace($actualEmail)) {
    throw "response did not include data.user.email"
  }
  if (-not [string]::Equals($actualEmail, $ExpectedEmail, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "expected data.user.email '$ExpectedEmail', got '$actualEmail'"
  }

  $roles = @($Data.user.roles)
  if ($roles.Count -lt 1) {
    throw "response did not include any admin roles"
  }

  $sessionId = [string]$Data.session.id
  if ([string]::IsNullOrWhiteSpace($sessionId)) {
    throw "response did not include data.session.id"
  }
  if (-not [string]::IsNullOrWhiteSpace($ExpectedSessionId) -and $sessionId -ne $ExpectedSessionId) {
    throw "expected data.session.id '$ExpectedSessionId', got '$sessionId'"
  }
}

function Invoke-AdminLogin {
  param(
    [Parameter(Mandatory = $true)][string]$Email,
    [Parameter(Mandatory = $true)][string]$Password
  )

  $response = Invoke-ApiRequest -Method POST -Uri (Join-Url $ControlPlaneBaseUrl "/admin/auth/login") -Body @{
    email = $Email
    password = $Password
  }
  Assert-StatusAny $response @(200)

  $payload = Read-Json $response.Content
  $data = Get-ResponseData $payload
  Assert-AdminSessionData -Data $data -ExpectedEmail $Email

  $token = [string]$data.session_token_once
  if ([string]::IsNullOrWhiteSpace($token)) {
    throw "login response did not include data.session_token_once"
  }
  Add-SensitiveValue $token

  return [PSCustomObject]@{
    Data = $data
    SessionToken = $token
  }
}

function Invoke-AdminLogout {
  param([Parameter(Mandatory = $true)][string]$SessionToken)

  $response = Invoke-ApiRequest -Method POST -Uri (Join-Url $ControlPlaneBaseUrl "/admin/auth/logout") -SessionToken $SessionToken
  Assert-StatusAny $response @(200)
  $payload = Read-Json $response.Content
  $data = Get-ResponseData $payload
  if ($data.logged_out -ne $true) {
    throw "logout response did not include data.logged_out=true"
  }
}

function Assert-PathLooksProtected {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw "$Name must not be empty"
  }
  if (-not $Path.StartsWith("/admin/")) {
    throw "$Name must be an /admin/ path"
  }
  if ($Path -eq "/admin/auth/login") {
    throw "$Name must not point at the public login endpoint"
  }
}

function Assert-SmokeParameters {
  if ($TimeoutSeconds -lt 1) {
    throw "TimeoutSeconds must be at least 1"
  }

  try {
    $uri = [Uri]$ControlPlaneBaseUrl
  } catch {
    throw "ControlPlaneBaseUrl must be an absolute http(s) URL"
  }
  if (-not $uri.IsAbsoluteUri -or ($uri.Scheme -ne "http" -and $uri.Scheme -ne "https")) {
    throw "ControlPlaneBaseUrl must be an absolute http(s) URL"
  }

  if ([string]::IsNullOrWhiteSpace($AdminEmail) -or -not $AdminEmail.Contains("@")) {
    throw "AdminEmail must be a non-empty email address"
  }
  if ([string]::IsNullOrWhiteSpace($AdminPassword)) {
    throw "AdminPassword must not be empty"
  }

  Assert-PathLooksProtected -Path $ProtectedEndpointPath -Name "ProtectedEndpointPath"
  Assert-PathLooksProtected -Path $ViewerDeniedEndpointPath -Name "ViewerDeniedEndpointPath"
  if (($ViewerDeniedEndpointMethod -eq "GET" -or $ViewerDeniedEndpointMethod -eq "HEAD") -and $StrictViewerRbacDenied) {
    throw "StrictViewerRbacDenied needs a write method so RBAC can deny provider_manage"
  }

  $hasViewerEmail = -not [string]::IsNullOrWhiteSpace($ViewerEmail)
  $hasViewerPassword = -not [string]::IsNullOrWhiteSpace($ViewerPassword)
  if ($hasViewerEmail -xor $hasViewerPassword) {
    throw "ViewerEmail and ViewerPassword must be supplied together"
  }
  if ($StrictViewerRbacDenied -and -not ($hasViewerEmail -and $hasViewerPassword)) {
    throw "StrictViewerRbacDenied requires ViewerEmail and ViewerPassword"
  }
}

function Read-Fixture {
  if (-not (Test-Path $fixturePath)) {
    throw "missing tests\fixtures\control-plane\admin_auth_smoke.json"
  }

  try {
    return (Get-Content -Path $fixturePath -Raw) | ConvertFrom-Json
  } catch {
    throw "fixture is not valid JSON: $($_.Exception.Message)"
  }
}

function Assert-FixtureEndpointIntent {
  param([Parameter(Mandatory = $true)]$Fixture)

  if ($Fixture.scenario -ne "control_plane_admin_auth_rbac_smoke") {
    throw "fixture scenario must be control_plane_admin_auth_rbac_smoke"
  }

  $expected = @(
    @("login", "POST", "/admin/auth/login"),
    @("me", "GET", "/admin/auth/me"),
    @("logout", "POST", "/admin/auth/logout")
  )
  foreach ($endpoint in $expected) {
    $name = $endpoint[0]
    $method = $endpoint[1]
    $path = $endpoint[2]
    if ($Fixture.auth_endpoints.$name.method -ne $method -or $Fixture.auth_endpoints.$name.path -ne $path) {
      throw "fixture endpoint '$name' must be $method $path"
    }
  }

  if ($Fixture.auth_endpoints.login.response_token_field -ne "data.session_token_once") {
    throw "fixture login token field must be data.session_token_once"
  }
  if ($Fixture.protected_no_session.expected_status -ne 401) {
    throw "fixture protected_no_session expected_status must be 401"
  }
  if ($Fixture.dev_admin_session_prereqs.diagnostic_default -ne $true) {
    throw "fixture dev_admin_session_prereqs must keep diagnostic default enabled"
  }
  if ($Fixture.dev_admin_session_prereqs.repair_flag -ne "-RepairDevAdminSessionPrereqs") {
    throw "fixture dev admin repair flag drifted"
  }
  if ($Fixture.dev_admin_session_prereqs.repair_env -ne "CONTROL_PLANE_AUTH_SMOKE_REPAIR_DEV_ADMIN_SESSION_PREREQS") {
    throw "fixture dev admin repair env drifted"
  }
  if ($Fixture.dev_admin_session_prereqs.blocked_exit_code -ne 2) {
    throw "fixture dev admin missing prereq blocked exit code must be 2"
  }
  foreach ($marker in @("user_sessions_migration_missing", "dev_admin_user_missing", "dev_admin_team_owner_missing", "dev_admin_project_owner_missing")) {
    if (@($Fixture.dev_admin_session_prereqs.missing_markers) -notcontains $marker) {
      throw "fixture dev admin missing marker '$marker' is absent"
    }
  }
  foreach ($name in @("session_token_echoed", "cookie_echoed", "password_hash_echoed")) {
    if ($Fixture.dev_admin_session_prereqs.secret_safe_output.$name -ne $false) {
      throw "fixture dev admin secret-safe output '$name' must be false"
    }
  }
  if ($Fixture.runtime_source_mismatch_diagnostic.diagnostic_default -ne $true) {
    throw "fixture runtime source mismatch diagnostic must run by default"
  }
  if ($Fixture.runtime_source_mismatch_diagnostic.does_not_trigger_build -ne $true) {
    throw "fixture runtime source mismatch diagnostic must not trigger builds"
  }
  if ($Fixture.runtime_source_mismatch_diagnostic.non_blocking_marker -ne "runtime_image_stale_or_unverified") {
    throw "fixture runtime source mismatch marker drifted"
  }
  if ($Fixture.runtime_source_mismatch_diagnostic.probe -ne "control_plane_image_timestamp") {
    throw "fixture runtime source mismatch probe drifted"
  }
  foreach ($reason in @("source_newer_than_runtime_image", "control_plane_container_unavailable", "control_plane_image_inspect_unavailable", "docker_unavailable", "source_timestamp_unavailable")) {
    if (@($Fixture.runtime_source_mismatch_diagnostic.stale_or_unverified_reasons) -notcontains $reason) {
      throw "fixture runtime source mismatch reason '$reason' is absent"
    }
  }
  foreach ($name in @("token_echoed", "cookie_echoed", "dsn_echoed")) {
    if ($Fixture.runtime_source_mismatch_diagnostic.secret_safe_output.$name -ne $false) {
      throw "fixture runtime source mismatch secret-safe output '$name' must be false"
    }
  }
}

function Assert-DevAdminSeedIntent {
  if (-not (Test-Path $devAdminSeedPath)) {
    throw "missing db\dev-seeds\0001_dev_admin_seed.sql"
  }
  if (-not (Test-Path $devSmokeSeedReconcilePath)) {
    throw "missing db\dev-seeds\0003_dev_smoke_seed_reconcile.sql"
  }
  if (-not (Test-Path $sessionMigrationPath)) {
    throw "missing db\migrations\0005_e1_e2_e3_e10_integrity_hardening.sql"
  }

  $sessionMigration = Get-Content -Path $sessionMigrationPath -Raw
  foreach ($needle in @(
      "create table if not exists user_sessions",
      "token_lookup_prefix",
      "token_hash",
      "expires_at"
    )) {
    if (-not $sessionMigration.Contains($needle)) {
      throw "session migration is missing expected auth session marker '$needle'"
    }
  }

  $seed = Get-Content -Path $devAdminSeedPath -Raw
  foreach ($needle in @(
      "admin@example.com",
      "pbkdf2-sha256",
      "09d4ad00a3fbf85ac4bebe70a5a4598357f830d572331c94000d9d898062deb8",
      '"dev_seed": true',
      "insert into team_members",
      "insert into project_members",
      "'owner'"
    )) {
    if (-not $seed.Contains($needle)) {
      throw "dev admin seed is missing expected marker '$needle'"
    }
  }

  $reconcileSeed = Get-Content -Path $devSmokeSeedReconcilePath -Raw
  foreach ($needle in @(
      "insert into team_members",
      "insert into project_members",
      "update team_members",
      "update project_members",
      "'00000000-0000-0000-0000-0000000000a1'",
      "and not exists",
      "'owner'"
    )) {
    if (-not $reconcileSeed.Contains($needle)) {
      throw "dev smoke seed reconcile is missing admin membership repair marker '$needle'"
    }
  }
}

function Assert-AuthSourceIntent {
  foreach ($path in @($authSourcePath, $rbacSourcePath)) {
    if (-not (Test-Path $path)) {
      throw "missing $([IO.Path]::GetFileName($path))"
    }
  }

  $authSource = Get-Content -Path $authSourcePath -Raw
  foreach ($needle in @(
      'route("/admin/auth/login"',
      'route("/admin/auth/me"',
      'route("/admin/auth/logout"',
      'session_token_once',
      'ADMIN_SESSION_HEADER'
    )) {
    if (-not $authSource.Contains($needle)) {
      throw "auth endpoint source is missing expected marker '$needle'"
    }
  }

  $rbacSource = Get-Content -Path $rbacSourcePath -Raw
  foreach ($needle in @(
      '"/admin/auth/login"',
      "permission_for_admin_request",
      "provider_manage_path",
      "key_manage_path"
    )) {
    if (-not $rbacSource.Contains($needle)) {
      throw "RBAC source is missing expected marker '$needle'"
    }
  }
}

function Get-ViewerDeniedBody {
  if ($script:Fixture) {
    $viewerDenial = @($script:Fixture.optional_role_denials | Where-Object { $_.role -eq "viewer" } | Select-Object -First 1)
    if ($viewerDenial.Count -gt 0 -and $viewerDenial[0].body) {
      return $viewerDenial[0].body
    }
  }

  return @{ name = "auth smoke denied probe" }
}

function Assert-ViewerProbeSafe {
  param([Parameter(Mandatory = $true)]$Data)

  $roles = @($Data.user.roles | ForEach-Object { ([string]$_).ToLowerInvariant() })
  if ($roles -notcontains "viewer") {
    throw "viewer RBAC credential must include role 'viewer'; got '$($roles -join ',')'"
  }

  $providerManageRoles = @("owner", "admin", "ops")
  $grantingRoles = @($roles | Where-Object { $providerManageRoles -contains $_ })
  if ($grantingRoles.Count -gt 0) {
    throw "viewer RBAC credential has provider_manage role(s) '$($grantingRoles -join ',')'; refusing denied write probe"
  }

  if ($ViewerDeniedEndpointMethod -eq "GET" -or $ViewerDeniedEndpointMethod -eq "HEAD") {
    throw "viewer denied probe must use a write method"
  }
}

Push-Location $repoRoot
try {
  Check "control-plane auth smoke parameters" {
    Assert-SmokeParameters
  }

  Check "control-plane admin auth fixture intent" {
    $script:Fixture = Read-Fixture
    Assert-FixtureEndpointIntent $script:Fixture
  }

  Check "dev-only admin seed intent" {
    Assert-DevAdminSeedIntent
  }

  Check "control-plane auth endpoints intent" {
    Assert-AuthSourceIntent
  }

  if ($DryRun) {
    Write-SafeHost ""
    Write-SafeHost "Control Plane admin auth smoke dry-run passed; runtime requests were not sent."
  } else {
    Check-Blocking "compose dev admin/session prerequisites" {
      Assert-OrRepairAuthPrereqs
    }
    Exit-WithFailuresOrBlockers
    Write-ControlPlaneRuntimeSourceProbe -SourcePaths @($authSourcePath, $rbacSourcePath, $PSCommandPath)

    Check "protected admin endpoint rejects missing session" {
      $response = Invoke-ApiRequest -Method $ProtectedEndpointMethod -Uri (Join-Url $ControlPlaneBaseUrl $ProtectedEndpointPath)
      Assert-StatusAny $response @(401)
      Assert-ErrorCode -Response $response -ExpectedCode "unauthorized"
    }

    Check "control-plane admin login" {
      $login = Invoke-AdminLogin -Email $AdminEmail -Password $AdminPassword
      $script:AdminSessionToken = $login.SessionToken
      $script:AdminLoginData = $login.Data
    }

    if (-not [string]::IsNullOrWhiteSpace($script:AdminSessionToken)) {
      Check "control-plane admin me" {
        $response = Invoke-ApiRequest -Method GET -Uri (Join-Url $ControlPlaneBaseUrl "/admin/auth/me") -SessionToken $script:AdminSessionToken
        Assert-StatusAny $response @(200)
        $payload = Read-Json $response.Content
        $data = Get-ResponseData $payload
        Assert-AdminSessionData -Data $data -ExpectedEmail $AdminEmail -ExpectedSessionId ([string]$script:AdminLoginData.session.id)
      }

      if (-not [string]::IsNullOrWhiteSpace($ViewerEmail) -and -not [string]::IsNullOrWhiteSpace($ViewerPassword)) {
        Check "control-plane viewer login" {
          $login = Invoke-AdminLogin -Email $ViewerEmail -Password $ViewerPassword
          $script:ViewerSessionToken = $login.SessionToken
          $script:ViewerLoginData = $login.Data
        }

        if (-not [string]::IsNullOrWhiteSpace($script:ViewerSessionToken)) {
          Check "control-plane viewer denied probe is safe" {
            Assert-ViewerProbeSafe -Data $script:ViewerLoginData
            $script:ViewerDeniedProbeSafe = $true
          }

          if ($script:ViewerDeniedProbeSafe) {
            Check "control-plane viewer provider write denied" {
              $body = Get-ViewerDeniedBody
              $response = Invoke-ApiRequest `
                -Method $ViewerDeniedEndpointMethod `
                -Uri (Join-Url $ControlPlaneBaseUrl $ViewerDeniedEndpointPath) `
                -SessionToken $script:ViewerSessionToken `
                -Body $body
              Assert-StatusAny $response @(403)
              Assert-ErrorCode -Response $response -ExpectedCode "forbidden"
            }
          }

          Check "control-plane viewer logout" {
            Invoke-AdminLogout -SessionToken $script:ViewerSessionToken
          }
        }
      } else {
        Report-PendingOrFail `
          -Name "control-plane viewer provider write denied" `
          -Message "set -ViewerEmail/-ViewerPassword or CONTROL_PLANE_VIEWER_EMAIL/CONTROL_PLANE_VIEWER_PASSWORD to verify viewer 403 without mutating database state" `
          -Strict:$StrictViewerRbacDenied
      }

      Check "control-plane admin logout" {
        Invoke-AdminLogout -SessionToken $script:AdminSessionToken
      }

      Check "control-plane admin me rejected after logout" {
        $response = Invoke-ApiRequest -Method GET -Uri (Join-Url $ControlPlaneBaseUrl "/admin/auth/me") -SessionToken $script:AdminSessionToken
        Assert-StatusAny $response @(401)
        Assert-ErrorCode -Response $response -ExpectedCode "unauthorized"
      }
    }
  }
} finally {
  Pop-Location
}

Exit-WithFailuresOrBlockers

Write-SafeHost ""
if ($script:Pending.Count -gt 0) {
  Write-SafeHost "Control Plane admin auth smoke passed with pending checks:"
  foreach ($pending in $script:Pending) {
    Write-SafeHost $pending
  }
  exit 0
}

Write-SafeHost "Control Plane admin auth smoke passed."
