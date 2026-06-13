<#
.SYNOPSIS
Starts the minimum local development stack without force-recreating containers.

.DESCRIPTION
Uses the existing Docker Compose file to start PostgreSQL, Redis, mock-provider,
gateway, control-plane, and admin-ui. The script preflights host ports so an
unrelated local service is not overwritten by compose, then waits for the
browser-facing endpoints to answer.
#>
param(
  [int]$ComposeTimeoutSeconds = 600,
  [int]$ReadyTimeoutSeconds = 180,
  [switch]$SkipSeedRepair,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\common.ps1"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$composeFile = Join-Path $repoRoot "deploy\docker-compose\docker-compose.yml"
$services = @("postgres", "redis", "mock-provider", "gateway", "control-plane", "admin-ui")

$postgresPort = if ($env:POSTGRES_HOST_PORT) { [int]$env:POSTGRES_HOST_PORT } else { 5432 }
$redisPort = if ($env:REDIS_HOST_PORT) { [int]$env:REDIS_HOST_PORT } else { 6379 }
$gatewayPort = if ($env:GATEWAY_HOST_PORT) { [int]$env:GATEWAY_HOST_PORT } else { 8080 }
$controlPlanePort = if ($env:CONTROL_PLANE_HOST_PORT) { [int]$env:CONTROL_PLANE_HOST_PORT } else { 8081 }
$adminUiPort = if ($env:ADMIN_UI_HOST_PORT) { [int]$env:ADMIN_UI_HOST_PORT } else { 5173 }
$mockProviderPort = if ($env:MOCK_PROVIDER_HOST_PORT) { [int]$env:MOCK_PROVIDER_HOST_PORT } else { 18080 }
$fixedPorts = @(
  @{ Name = "gateway"; Port = $gatewayPort; Override = "GATEWAY_HOST_PORT" },
  @{ Name = "control-plane"; Port = $controlPlanePort; Override = "CONTROL_PLANE_HOST_PORT" },
  @{ Name = "admin-ui"; Port = $adminUiPort; Override = "ADMIN_UI_HOST_PORT" },
  @{ Name = "mock-provider"; Port = $mockProviderPort; Override = "MOCK_PROVIDER_HOST_PORT" }
)
$portChecks = @(
  @{ Name = "postgres"; Port = $postgresPort; Override = "POSTGRES_HOST_PORT" },
  @{ Name = "redis"; Port = $redisPort; Override = "REDIS_HOST_PORT" }
) + $fixedPorts

function Write-Step {
  param([string]$Message)
  Write-Host "[dev-up] $Message"
}

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

  Write-Step "local temp/cache: TEMP=$env:TEMP; TMP=$env:TMP; npm_config_cache=$env:npm_config_cache; CARGO_TARGET_DIR=$env:CARGO_TARGET_DIR"
}

function Invoke-Capture {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [int]$TimeoutSeconds = 60
  )

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo.FileName = $FilePath
  foreach ($arg in $Arguments) {
    [void]$process.StartInfo.ArgumentList.Add($arg)
  }
  $process.StartInfo.WorkingDirectory = $repoRoot
  $process.StartInfo.UseShellExecute = $false
  $process.StartInfo.RedirectStandardOutput = $true
  $process.StartInfo.RedirectStandardError = $true

  try {
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
      try { $process.Kill($true) } catch { $process.Kill() }
      return [PSCustomObject]@{
        ExitCode = 124
        Stdout = ""
        Stderr = "command timed out after ${TimeoutSeconds}s"
      }
    }

    return [PSCustomObject]@{
      ExitCode = $process.ExitCode
      Stdout = $stdoutTask.GetAwaiter().GetResult()
      Stderr = $stderrTask.GetAwaiter().GetResult()
    }
  } finally {
    $process.Dispose()
  }
}

function Test-PortOpen {
  param([int]$Port)

  $client = [System.Net.Sockets.TcpClient]::new()
  try {
    $connect = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
    if (-not $connect.AsyncWaitHandle.WaitOne(250)) {
      return $false
    }
    $client.EndConnect($connect)
    return $true
  } catch {
    return $false
  } finally {
    $client.Dispose()
  }
}

function Get-ComposePublishedPorts {
  param([string]$Docker)

  $ports = @{}
  foreach ($service in $services) {
    $result = Invoke-Capture -FilePath $Docker -Arguments @("compose", "-f", $composeFile, "port", $service, "8080") -TimeoutSeconds 10
    if ($result.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($result.Stdout)) {
      $result.Stdout -split "`n" | ForEach-Object {
        if ($_ -match "127\.0\.0\.1:(\d+)") {
          $ports[[int]$Matches[1]] = $service
        }
      }
    }
  }

  foreach ($entry in @(
      @{ Service = "postgres"; ContainerPort = "5432" },
      @{ Service = "redis"; ContainerPort = "6379" },
      @{ Service = "mock-provider"; ContainerPort = "18080" },
      @{ Service = "gateway"; ContainerPort = "8080" },
      @{ Service = "control-plane"; ContainerPort = "8081" },
      @{ Service = "admin-ui"; ContainerPort = "8080" }
    )) {
    $result = Invoke-Capture -FilePath $Docker -Arguments @("compose", "-f", $composeFile, "port", $entry.Service, $entry.ContainerPort) -TimeoutSeconds 10
    if ($result.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($result.Stdout)) {
      $result.Stdout -split "`n" | ForEach-Object {
        if ($_ -match "127\.0\.0\.1:(\d+)") {
          $ports[[int]$Matches[1]] = $entry.Service
        }
      }
    }
  }
  return $ports
}

function Assert-PortsAvailableOrOwned {
  param([string]$Docker)

  $composePorts = Get-ComposePublishedPorts -Docker $Docker
  foreach ($check in $portChecks) {
    $port = [int]$check.Port
    if (-not (Test-PortOpen -Port $port)) {
      continue
    }

    if ($composePorts.ContainsKey($port)) {
      Write-Step "port $port is already used by compose service '$($composePorts[$port])'; will reuse it."
      continue
    }

    $hint = if ($check.Override) {
      "Set `$env:$($check.Override) to another port before running this script."
    } else {
      "Stop the process using port $port or adjust deploy/docker-compose/docker-compose.yml."
    }
    throw "port $port for $($check.Name) is already in use by a non-compose process. $hint"
  }
}

function Wait-Tcp {
  param(
    [string]$Name,
    [int]$Port,
    [datetime]$Deadline
  )

  while ((Get-Date) -lt $Deadline) {
    if (Test-PortOpen -Port $Port) {
      Write-Step "$Name tcp ready on 127.0.0.1:$Port"
      return
    }
    Start-Sleep -Seconds 2
  }
  throw "$Name did not open TCP port $Port within $ReadyTimeoutSeconds seconds."
}

function Wait-Http {
  param(
    [string]$Name,
    [string]$Uri,
    [datetime]$Deadline
  )

  $lastError = $null
  while ((Get-Date) -lt $Deadline) {
    try {
      $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 5
      if ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 500) {
        Write-Step "$Name ready: $Uri -> $($response.StatusCode)"
        return
      }
      $lastError = "HTTP $($response.StatusCode)"
    } catch {
      $lastError = $_.Exception.Message
    }
    Start-Sleep -Seconds 2
  }
  throw "$Name did not become ready at $Uri within $ReadyTimeoutSeconds seconds. Last error: $lastError"
}

function Invoke-SeedRepair {
  param([string]$Docker)

  $setupScript = Join-Path $PSScriptRoot "setup_local_mvp.ps1"
  if (-not (Test-Path -LiteralPath $setupScript)) {
    throw "Missing local setup script: $setupScript"
  }

  Write-Step "running local/dev-only MVP setup seed entry"
  & $setupScript -TimeoutSeconds 60
  if ($LASTEXITCODE -ne 0) {
    throw "local MVP setup failed with exit code $LASTEXITCODE"
  }
}

if ($ComposeTimeoutSeconds -le 0) { throw "ComposeTimeoutSeconds must be greater than zero." }
if ($ReadyTimeoutSeconds -le 0) { throw "ReadyTimeoutSeconds must be greater than zero." }
if (-not (Test-Path $composeFile)) { throw "Missing compose file: $composeFile" }

Initialize-ProjectLocalCache

$docker = Get-DockerCommand
Write-Step "using docker: $docker"
Write-Step "compose file: $composeFile"

Assert-PortsAvailableOrOwned -Docker $docker

$composeArgs = @("compose", "-f", $composeFile, "up", "--build", "-d") + $services
Write-Step "compose command: docker $($composeArgs -join ' ')"
if ($DryRun) {
  Write-Step "dry run complete; no containers were started."
  exit 0
}

$up = Invoke-Capture -FilePath $docker -Arguments $composeArgs -TimeoutSeconds $ComposeTimeoutSeconds
if (-not [string]::IsNullOrWhiteSpace($up.Stdout)) { Write-Host $up.Stdout.TrimEnd() }
if (-not [string]::IsNullOrWhiteSpace($up.Stderr)) { [Console]::Error.WriteLine($up.Stderr.TrimEnd()) }
if ($up.ExitCode -ne 0) {
  Write-Host 'postgres_port_override_hint=$env:POSTGRES_HOST_PORT = "55432"'
  Write-Host 'redis_port_override_hint=$env:REDIS_HOST_PORT = "56379"'
  Write-Host 'gateway_port_override_hint=$env:GATEWAY_HOST_PORT = "18082"'
  Write-Host 'control_plane_port_override_hint=$env:CONTROL_PLANE_HOST_PORT = "18081"'
  Write-Host 'admin_ui_port_override_hint=$env:ADMIN_UI_HOST_PORT = "15173"'
  Write-Host 'mock_provider_port_override_hint=$env:MOCK_PROVIDER_HOST_PORT = "28080"'
  exit $up.ExitCode
}

$deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
Wait-Tcp -Name "postgres" -Port $postgresPort -Deadline $deadline
Wait-Tcp -Name "redis" -Port $redisPort -Deadline $deadline
Wait-Http -Name "mock-provider" -Uri "http://127.0.0.1:$mockProviderPort/healthz" -Deadline $deadline
Wait-Http -Name "gateway" -Uri "http://127.0.0.1:$gatewayPort/readyz" -Deadline $deadline
Wait-Http -Name "control-plane" -Uri "http://127.0.0.1:$controlPlanePort/readyz" -Deadline $deadline
Wait-Http -Name "admin-ui" -Uri "http://127.0.0.1:$adminUiPort/" -Deadline $deadline

if (-not $SkipSeedRepair) {
  Invoke-SeedRepair -Docker $docker
}

Write-Step "local stack is ready."
Write-Host "admin_ui=http://127.0.0.1:$adminUiPort"
Write-Host "control_plane=http://127.0.0.1:$controlPlanePort"
Write-Host "gateway=http://127.0.0.1:$gatewayPort"
Write-Host "next_check=pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\dev_login_check.ps1 -ControlPlaneBaseUrl http://127.0.0.1:$controlPlanePort -GatewayBaseUrl http://127.0.0.1:$gatewayPort -AdminUiBaseUrl http://127.0.0.1:$adminUiPort"
