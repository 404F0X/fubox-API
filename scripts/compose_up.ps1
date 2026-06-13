<#
.SYNOPSIS
Starts the local Docker Compose stack.

.NOTES
If local PostgreSQL or Redis already owns host ports 5432/6379, set
$env:POSTGRES_HOST_PORT and $env:REDIS_HOST_PORT before running this script.
Example:
$env:POSTGRES_HOST_PORT = "55432"; $env:REDIS_HOST_PORT = "56379"; .\scripts\compose_up.ps1 -ForceRecreate
#>
param(
  [int]$ComposeTimeoutSeconds = 600,
  [switch]$ForceRecreate
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"

if ($env:COMPOSE_TIMEOUT_SECONDS) {
  $ComposeTimeoutSeconds = [int]$env:COMPOSE_TIMEOUT_SECONDS
}

if ($ComposeTimeoutSeconds -le 0) {
  throw "ComposeTimeoutSeconds must be greater than zero."
}

$docker = Get-DockerCommand
$process = New-Object System.Diagnostics.Process
$process.StartInfo.FileName = $docker
$composeArgs = @("compose", "-f", "deploy/docker-compose/docker-compose.yml", "up", "--build")
if ($ForceRecreate) {
  $composeArgs += "--force-recreate"
}
$composeArgs += "-d"
foreach ($arg in $composeArgs) {
  [void]$process.StartInfo.ArgumentList.Add($arg)
}
$process.StartInfo.UseShellExecute = $false
$process.StartInfo.RedirectStandardOutput = $true
$process.StartInfo.RedirectStandardError = $true

try {
  [void]$process.Start()
  $stdoutTask = $process.StandardOutput.ReadToEndAsync()
  $stderrTask = $process.StandardError.ReadToEndAsync()

  if (-not $process.WaitForExit($ComposeTimeoutSeconds * 1000)) {
    try {
      $process.Kill($true)
    } catch {
      $process.Kill()
    }
    Write-Host "compose_up_status=timeout"
    Write-Host "compose_up_timeout_seconds=$ComposeTimeoutSeconds"
    exit 124
  }

  $stdout = $stdoutTask.GetAwaiter().GetResult()
  $stderr = $stderrTask.GetAwaiter().GetResult()
  if (-not [string]::IsNullOrWhiteSpace($stdout)) { Write-Host $stdout.TrimEnd() }
  if (-not [string]::IsNullOrWhiteSpace($stderr)) { [Console]::Error.WriteLine($stderr.TrimEnd()) }
  if ($process.ExitCode -ne 0) {
    Write-Host 'compose_up_port_override_hint=$env:POSTGRES_HOST_PORT = "55432"; $env:REDIS_HOST_PORT = "56379"; .\scripts\compose_up.ps1 -ForceRecreate'
    exit $process.ExitCode
  }
} finally {
  $process.Dispose()
}
