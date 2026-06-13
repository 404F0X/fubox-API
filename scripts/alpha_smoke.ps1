param(
  [switch]$StartCompose,
  [switch]$SkipSdkSmoke,
  [switch]$SkipSecretScan,
  [int]$Retries = 6,
  [int]$RetryDelaySeconds = 5,
  [int]$TimeoutSeconds = 12,
  [int]$ComposeTimeoutSeconds = 600,
  [switch]$NoForceRecreate,
  [string]$OutputPath = ".tmp/open-source-alpha/alpha_smoke.json"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$outputFullPath = Join-Path $repoRoot $OutputPath
$outputDir = Split-Path -Parent $outputFullPath
if (-not (Test-Path $outputDir)) {
  New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
}

if ($env:COMPOSE_TIMEOUT_SECONDS) {
  $ComposeTimeoutSeconds = [int]$env:COMPOSE_TIMEOUT_SECONDS
}

if ($ComposeTimeoutSeconds -le 0) {
  throw "ComposeTimeoutSeconds must be greater than zero."
}

$steps = @()
$lastStep = $null
$fatalBlockers = @()
$diagnostics = @()
$exitCodeToReturn = 0

function ConvertTo-SafeNote {
  param([AllowNull()][string]$Message)

  if ([string]::IsNullOrEmpty($Message)) { return $Message }

  $safe = $Message
  foreach ($secret in @($env:GATEWAY_AUTH_TOKEN, "dev_test_key_123456789")) {
    if (-not [string]::IsNullOrEmpty($secret)) {
      $safe = $safe.Replace($secret, "[REDACTED]")
    }
  }
  $safe = $safe -replace '(?i)Bearer\s+[A-Za-z0-9._~+/=-]+', 'Bearer [REDACTED]'
  return $safe
}

function Invoke-Capture {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo.FileName = $FilePath
  foreach ($arg in $Arguments) {
    [void]$process.StartInfo.ArgumentList.Add($arg)
  }
  $process.StartInfo.UseShellExecute = $false
  $process.StartInfo.RedirectStandardOutput = $true
  $process.StartInfo.RedirectStandardError = $true

  try {
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return [PSCustomObject]@{
      exit_code = $process.ExitCode
      stdout = ConvertTo-SafeNote $stdout
      stderr = ConvertTo-SafeNote $stderr
    }
  } finally {
    $process.Dispose()
  }
}

function Get-ComposeFailureDiagnostics {
  $result = [ordered]@{
    name = "compose_state_after_failure"
    status = "unknown"
    stale_compose_container_image = $false
    exited_container_count = 0
    images_exit_code = $null
    images_error = $null
    note = $null
  }

  try {
    . "$PSScriptRoot\common.ps1"
    $docker = Get-DockerCommand
    $psResult = Invoke-Capture -FilePath $docker -Arguments @("compose", "-f", "deploy/docker-compose/docker-compose.yml", "ps", "-a")
    $imagesResult = Invoke-Capture -FilePath $docker -Arguments @("compose", "-f", "deploy/docker-compose/docker-compose.yml", "images")

    $result.images_exit_code = $imagesResult.exit_code
    if ($imagesResult.exit_code -ne 0) {
      $result.images_error = ($imagesResult.stderr + $imagesResult.stdout).Trim()
    }

    $exitedMatches = [regex]::Matches($psResult.stdout, "Exited\s*\(")
    $result.exited_container_count = $exitedMatches.Count
    $missingImage = (($imagesResult.stderr + $imagesResult.stdout) -match "No such image")
    $result.stale_compose_container_image = ($result.exited_container_count -gt 0 -and $missingImage)
    $result.status = if ($result.stale_compose_container_image) { "fail" } else { "pass" }
    if ($result.stale_compose_container_image) {
      $result.note = "stale compose container references a missing local image; run docker compose down, then rebuild with --force-recreate"
    }
  } catch {
    $result.status = "fail"
    $result.note = "compose diagnostics failed: $(ConvertTo-SafeNote $_.Exception.Message)"
  }

  return [PSCustomObject]$result
}

function Invoke-Step {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][scriptblock]$Script
  )

  $script:lastStep = $Name
  $started = Get-Date
  $result = [ordered]@{
    name = $Name
    status = "running"
    exit_code = $null
    started_at_utc = $started.ToUniversalTime().ToString("o")
    finished_at_utc = $null
    duration_ms = $null
    note = $null
  }

  try {
    $scriptOutput = & $Script
    $exitCode = if ($null -eq $global:LASTEXITCODE) { 0 } else { [int]$global:LASTEXITCODE }
    if ($exitCode -ne 0) {
      throw "exit code $exitCode"
    }

    $result.status = "pass"
    $result.exit_code = 0
  } catch {
    $exitCode = if ($null -eq $global:LASTEXITCODE) { 1 } else { [int]$global:LASTEXITCODE }
    if ($exitCode -eq 0) { $exitCode = 1 }
    $result.status = "fail"
    $result.exit_code = $exitCode
    $result.note = ConvertTo-SafeNote $_.Exception.Message
    if ($Name -eq "compose_up") {
      $composeDiagnostics = Get-ComposeFailureDiagnostics
      $script:diagnostics += $composeDiagnostics
      if ($composeDiagnostics.stale_compose_container_image) {
        $result.note = "$($result.note); stale compose container/image state detected"
      }
    }
  } finally {
    $finished = Get-Date
    $result.finished_at_utc = $finished.ToUniversalTime().ToString("o")
    $result.duration_ms = [int](New-TimeSpan -Start $started -End $finished).TotalMilliseconds
  }

  return [PSCustomObject]$result
}

function Invoke-ComposeSmokeWithRetry {
  $attempts = @()
  for ($attempt = 1; $attempt -le $Retries; $attempt++) {
    $script:lastStep = "compose_smoke attempt $attempt"
    $started = Get-Date
    $attemptResult = [ordered]@{
      attempt = $attempt
      status = "running"
      exit_code = $null
      started_at_utc = $started.ToUniversalTime().ToString("o")
      finished_at_utc = $null
      duration_ms = $null
      note = $null
    }

    try {
      & "$PSScriptRoot\verify_compose_smoke.ps1" -TimeoutSeconds $TimeoutSeconds
      $exitCode = if ($null -eq $global:LASTEXITCODE) { 0 } else { [int]$global:LASTEXITCODE }
      if ($exitCode -ne 0) {
        throw "exit code $exitCode"
      }

      $attemptResult.status = "pass"
      $attemptResult.exit_code = 0
    } catch {
      $exitCode = if ($null -eq $global:LASTEXITCODE) { 1 } else { [int]$global:LASTEXITCODE }
      if ($exitCode -eq 0) { $exitCode = 1 }
      $attemptResult.status = "fail"
      $attemptResult.exit_code = $exitCode
      $attemptResult.note = ConvertTo-SafeNote $_.Exception.Message
    } finally {
      $finished = Get-Date
      $attemptResult.finished_at_utc = $finished.ToUniversalTime().ToString("o")
      $attemptResult.duration_ms = [int](New-TimeSpan -Start $started -End $finished).TotalMilliseconds
      $attempts += [PSCustomObject]$attemptResult
    }

    if ($attemptResult.status -eq "pass") {
      return [PSCustomObject]@{
        status = "pass"
        exit_code = 0
        attempts = $attempts
      }
    }

    if ($attempt -lt $Retries) {
      Start-Sleep -Seconds $RetryDelaySeconds
    }
  }

  return [PSCustomObject]@{
    status = "fail"
    exit_code = 1
    attempts = $attempts
  }
}

function Write-AlphaSmokeArtifact {
  param(
    [array]$Steps = @(),
    [array]$ExtraBlockers = @()
  )

  $failed = @($Steps | Where-Object { $_.status -ne "pass" })
  $blockers = @($ExtraBlockers + ($failed | ForEach-Object {
    if ([string]::IsNullOrEmpty($_.note)) { $_.name } else { "$($_.name): $($_.note)" }
  }))
  if ($blockers.Count -gt 0) {
    $blockers += @($script:diagnostics | Where-Object { $_.stale_compose_container_image } | ForEach-Object {
      if ([string]::IsNullOrEmpty($_.note)) { "stale compose container/image state detected" } else { $_.note }
    })
  }

  $summary = [ordered]@{
    schema = "open_source_alpha_smoke.v1"
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    status = if ($blockers.Count -eq 0) { "pass" } else { "fail" }
    ready_for_open_source_alpha = ($blockers.Count -eq 0)
    start_compose = [bool]$StartCompose
    retries = $Retries
    retry_delay_seconds = $RetryDelaySeconds
    timeout_seconds = $TimeoutSeconds
    compose_timeout_seconds = $ComposeTimeoutSeconds
    last_step = $script:lastStep
    suggested_rerun_command = "pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\alpha_smoke.ps1 -StartCompose -ComposeTimeoutSeconds $ComposeTimeoutSeconds"
    suggested_port_override_rerun_command = '$env:POSTGRES_HOST_PORT = "55432"; $env:REDIS_HOST_PORT = "56379"; pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\alpha_smoke.ps1 -StartCompose -ComposeTimeoutSeconds ' + $ComposeTimeoutSeconds
    suggested_compose_command = "docker compose -f deploy/docker-compose/docker-compose.yml up --build --force-recreate -d"
    suggested_port_override_compose_command = '$env:POSTGRES_HOST_PORT = "55432"; $env:REDIS_HOST_PORT = "56379"; docker compose -f deploy/docker-compose/docker-compose.yml up --build --force-recreate -d'
    suggested_cleanup_command = "docker compose -f deploy/docker-compose/docker-compose.yml down"
    gateway_base_url = if ($env:GATEWAY_BASE_URL) { $env:GATEWAY_BASE_URL } else { "http://127.0.0.1:8080" }
    admin_ui_base_url = if ($env:ADMIN_UI_BASE_URL) { $env:ADMIN_UI_BASE_URL } else { "http://127.0.0.1:5173" }
    default_gateway_auth_token_ref = "local dev seed token; raw value omitted"
    raw_gateway_auth_token_omitted = $true
    secret_safe = $true
    simulation = $false
    steps = $Steps
    diagnostics = $script:diagnostics
    blockers = $blockers
  }

  $summary | ConvertTo-Json -Depth 12 | Set-Content -Path $outputFullPath -Encoding UTF8
  Write-Host "alpha_smoke_status=$($summary.status)"
  Write-Host "alpha_smoke_artifact=$OutputPath"
  return $summary
}

Push-Location $repoRoot
try {
  if ($StartCompose) {
    $preflightDiagnostics = Get-ComposeFailureDiagnostics
    $preflightDiagnostics.name = "compose_state_preflight"
    $diagnostics += $preflightDiagnostics

    $composeUpStep = Invoke-Step -Name "compose_up" -Script {
      & "$PSScriptRoot\compose_up.ps1" -ComposeTimeoutSeconds $ComposeTimeoutSeconds -ForceRecreate:(!$NoForceRecreate)
    }
    $steps += $composeUpStep
    if ($composeUpStep.status -ne "pass") {
      $exitCodeToReturn = $composeUpStep.exit_code
      throw "compose_up failed; downstream smoke checks skipped"
    }
  }

  $composeResult = Invoke-ComposeSmokeWithRetry
  $steps += [PSCustomObject]@{
    name = "compose_smoke"
    status = $composeResult.status
    exit_code = $composeResult.exit_code
    started_at_utc = if ($composeResult.attempts.Count -gt 0) { $composeResult.attempts[0].started_at_utc } else { $null }
    finished_at_utc = if ($composeResult.attempts.Count -gt 0) { $composeResult.attempts[-1].finished_at_utc } else { $null }
    duration_ms = if ($composeResult.attempts.Count -gt 0) {
      [int](New-TimeSpan -Start ([DateTime]::Parse($composeResult.attempts[0].started_at_utc)) -End ([DateTime]::Parse($composeResult.attempts[-1].finished_at_utc))).TotalMilliseconds
    } else { 0 }
    note = "bounded retry over scripts/verify_compose_smoke.ps1"
    attempts = $composeResult.attempts
  }

  if (-not $SkipSdkSmoke) {
    $steps += Invoke-Step -Name "sdk_smoke" -Script {
      & "$PSScriptRoot\verify_sdk_smoke.ps1" -SkipInstall
    }
  }

  if (-not $SkipSecretScan) {
    $steps += Invoke-Step -Name "secret_scan" -Script {
      & "$PSScriptRoot\scan_secrets.ps1"
    }
  }
} catch {
  $exitCodeToReturn = 1
  $fatalBlockers += "alpha_smoke: $(ConvertTo-SafeNote $_.Exception.Message)"
} finally {
  $summary = Write-AlphaSmokeArtifact -Steps $steps -ExtraBlockers $fatalBlockers
  Pop-Location
}

if ($summary.status -ne "pass") {
  if ($exitCodeToReturn -eq 0) { $exitCodeToReturn = 1 }
  exit $exitCodeToReturn
}
