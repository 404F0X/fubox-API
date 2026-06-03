<#
.SYNOPSIS
  Create a PostgreSQL backup dump.

.DESCRIPTION
  Writes one PostgreSQL custom-format dump file with pg_dump. Connection details
  can be supplied through -DatabaseUrl, DATABASE_URL, POSTGRES_URL, or explicit
  database parameters. Passwords are passed through PGPASSWORD and are never
  printed by this script.

  -DryRun and -Preflight validate the plan without creating directories or
  executing pg_dump. Tool availability is reported as a warning in those modes.

.EXAMPLE
  .\scripts\db\backup.ps1 -DryRun -DatabaseUrl "postgres://fubox:<secret>@localhost:5432/fubox"

.EXAMPLE
  .\scripts\db\backup.ps1 -OutputPath D:\backups\fubox\postgres.dump -DbHost localhost -DbName fubox -DbUser fubox
#>
[CmdletBinding()]
param(
  [string]$OutputPath = "",
  [switch]$DryRun,
  [switch]$Preflight,
  [switch]$Force,

  [Alias("PostgresUrl")]
  [string]$DatabaseUrl = $(if ($env:DATABASE_URL) { $env:DATABASE_URL } elseif ($env:POSTGRES_URL) { $env:POSTGRES_URL } else { "" }),

  [Alias("PostgresHost")]
  [string]$DbHost = $(if ($env:PGHOST) { $env:PGHOST } else { "" }),

  [Alias("PostgresPort")]
  [string]$DbPort = $(if ($env:PGPORT) { $env:PGPORT } else { "5432" }),

  [Alias("PostgresDatabase")]
  [string]$DbName = $(if ($env:PGDATABASE) { $env:PGDATABASE } else { "" }),

  [Alias("PostgresUser")]
  [string]$DbUser = $(if ($env:PGUSER) { $env:PGUSER } else { "" }),

  [Alias("PostgresPassword")]
  [string]$DbPassword = $(if ($env:PGPASSWORD) { $env:PGPASSWORD } else { "" })
)

$ErrorActionPreference = "Stop"

function Write-Log {
  param([string]$Message)
  $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Write-Host "[$stamp] $Message"
}

function Write-WarnLog {
  param([string]$Message)
  $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Write-Host "[$stamp] WARNING: $Message"
}

function Write-ErrorLog {
  param([string]$Message)
  $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Write-Host "[$stamp] ERROR: $Message"
}

function Fail {
  param([string]$Message)
  throw $Message
}

function Assert-NotBlank {
  param(
    [string]$Name,
    [string]$Value
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    Fail "$Name is required."
  }
}

function Convert-ToPort {
  param(
    [string]$Name,
    [string]$Value
  )

  $parsed = 0
  if (-not [int]::TryParse($Value, [ref]$parsed)) {
    Fail "$Name must be an integer from 1 to 65535."
  }
  if ($parsed -lt 1 -or $parsed -gt 65535) {
    Fail "$Name must be an integer from 1 to 65535."
  }
  return $parsed
}

function Get-RepoRoot {
  $scriptPath = $PSCommandPath
  if ([string]::IsNullOrWhiteSpace($scriptPath)) {
    $scriptPath = $MyInvocation.MyCommand.Path
  }
  if ([string]::IsNullOrWhiteSpace($scriptPath)) {
    return (Get-Location).Path
  }

  $scriptDirectory = Split-Path -Parent $scriptPath
  return (Resolve-Path (Join-Path $scriptDirectory "..\..")).Path
}

function Get-DefaultOutputPath {
  $root = $env:BACKUP_ROOT
  if ([string]::IsNullOrWhiteSpace($root)) {
    $root = Join-Path (Get-RepoRoot) "backups"
  }

  $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
  return (Join-Path (Join-Path $root "db") "postgres-$timestamp.dump")
}

function Resolve-UnresolvedPath {
  param([string]$Path)
  return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Redact-ConnectionText {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return ""
  }

  $redacted = $Value -replace "(?i)(password\s*=\s*)[^ ;&]+", '${1}****'
  $redacted = $redacted -replace "(?i)(://[^:/@]*:)[^@]+@", '${1}****@'
  return $redacted
}

function Remove-UrlPassword {
  param(
    [string]$Url,
    [ref]$PasswordRef
  )

  if ([string]::IsNullOrWhiteSpace($Url)) {
    return $Url
  }

  try {
    $uri = [Uri]$Url
  } catch {
    return $Url
  }

  if (($uri.Scheme -ne "postgres") -and ($uri.Scheme -ne "postgresql")) {
    return $Url
  }
  if ([string]::IsNullOrWhiteSpace($uri.UserInfo) -or ($uri.UserInfo -notmatch ":")) {
    return $Url
  }

  $separator = $uri.UserInfo.IndexOf(":")
  $userName = $uri.UserInfo.Substring(0, $separator)
  $password = $uri.UserInfo.Substring($separator + 1)
  if ([string]::IsNullOrWhiteSpace($PasswordRef.Value)) {
    $PasswordRef.Value = [Uri]::UnescapeDataString($password)
  }

  $builder = New-Object System.UriBuilder($uri)
  $builder.UserName = $userName
  $builder.Password = ""
  return ($builder.Uri.AbsoluteUri -replace "://([^:@/]+):@", '://${1}@')
}

function Remove-ConnectionPassword {
  param(
    [string]$Connection,
    [ref]$PasswordRef
  )

  $withoutUrlPassword = Remove-UrlPassword -Url $Connection -PasswordRef $PasswordRef
  if ($withoutUrlPassword -ne $Connection) {
    return $withoutUrlPassword
  }

  if ($Connection -match "(?i)(^|\s)password\s*=\s*([^ ;]+)") {
    if ([string]::IsNullOrWhiteSpace($PasswordRef.Value)) {
      $PasswordRef.Value = $matches[2].Trim("'`"")
    }
    return (($Connection -replace "(?i)\s*password\s*=\s*[^ ;]+", "").Trim())
  }

  return $Connection
}

function Get-PostgresBackupPlan {
  param([string]$DumpPath)

  if (-not [string]::IsNullOrWhiteSpace($DatabaseUrl)) {
    $passwordCopy = $DbPassword
    $safeConnection = Remove-ConnectionPassword -Connection $DatabaseUrl -PasswordRef ([ref]$passwordCopy)
    Assert-NotBlank "DatabaseUrl/DATABASE_URL" $safeConnection

    $envVars = @{}
    if (-not [string]::IsNullOrWhiteSpace($passwordCopy)) {
      $envVars["PGPASSWORD"] = $passwordCopy
    }

    return @{
      Args = @("--format=custom", "--no-owner", "--file", $DumpPath, $safeConnection)
      Env = $envVars
      Summary = Redact-ConnectionText $DatabaseUrl
    }
  }

  Assert-NotBlank "DbHost or DatabaseUrl/DATABASE_URL" $DbHost
  Assert-NotBlank "DbName or PGDATABASE" $DbName
  Assert-NotBlank "DbUser or PGUSER" $DbUser
  $port = Convert-ToPort "DbPort/PGPORT" $DbPort

  $envVars = @{}
  if (-not [string]::IsNullOrWhiteSpace($DbPassword)) {
    $envVars["PGPASSWORD"] = $DbPassword
  }

  return @{
    Args = @(
      "--format=custom",
      "--no-owner",
      "--file",
      $DumpPath,
      "--host",
      $DbHost,
      "--port",
      [string]$port,
      "--username",
      $DbUser,
      "--dbname",
      $DbName
    )
    Env = $envVars
    Summary = "host=$DbHost port=$port db=$DbName user=$DbUser"
  }
}

function Assert-BackupOutputPath {
  param(
    [string]$Path,
    [bool]$CanOverwrite
  )

  if (Test-Path -LiteralPath $Path -PathType Container) {
    Fail "OutputPath must be a dump file path, not a directory: $Path"
  }

  if ((Test-Path -LiteralPath $Path -PathType Leaf) -and (-not $CanOverwrite)) {
    Fail "OutputPath already exists. Pass -Force to overwrite it: $Path"
  }

  $parent = Split-Path -Parent $Path
  if ([string]::IsNullOrWhiteSpace($parent)) {
    $parent = (Get-Location).Path
  }
  if ((Test-Path -LiteralPath $parent) -and (-not (Test-Path -LiteralPath $parent -PathType Container))) {
    Fail "OutputPath parent is not a directory: $parent"
  }
}

function Resolve-RequiredTool {
  param([string]$Name)

  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if (-not $cmd) {
    Fail "Required tool '$Name' was not found in PATH."
  }
  return $cmd.Source
}

function Report-ToolAvailability {
  param([string]$Name)

  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if ($cmd) {
    Write-Log "$Name found: $($cmd.Source)"
  } else {
    Write-WarnLog "$Name was not found in PATH. Actual backup execution requires it."
  }
}

function Invoke-External {
  param(
    [string]$Tool,
    [string[]]$Arguments,
    [hashtable]$TemporaryEnvironment
  )

  $previous = @{}
  foreach ($key in $TemporaryEnvironment.Keys) {
    $previous[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
    [Environment]::SetEnvironmentVariable($key, [string]$TemporaryEnvironment[$key], "Process")
  }

  try {
    & $Tool @Arguments
    if ($LASTEXITCODE -ne 0) {
      Fail "$Tool exited with code $LASTEXITCODE."
    }
  } finally {
    foreach ($key in $TemporaryEnvironment.Keys) {
      [Environment]::SetEnvironmentVariable($key, $previous[$key], "Process")
    }
  }
}

try {
  if ($DryRun -and $Preflight) {
    Fail "Use either -DryRun or -Preflight, not both."
  }

  if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Get-DefaultOutputPath
  }
  $resolvedOutputPath = Resolve-UnresolvedPath $OutputPath
  Assert-BackupOutputPath -Path $resolvedOutputPath -CanOverwrite ([bool]$Force)

  $plan = Get-PostgresBackupPlan -DumpPath $resolvedOutputPath
  $checkOnly = $DryRun -or $Preflight

  if ($Preflight) {
    Write-Log "Mode: preflight. No directories will be created and pg_dump will not run."
  } elseif ($DryRun) {
    Write-Log "Mode: dry-run. No directories will be created and pg_dump will not run."
  } else {
    Write-Log "Mode: execute. pg_dump will write the requested backup file."
  }

  Write-Log "Backup output path: $resolvedOutputPath"
  Write-Log "PostgreSQL source: $($plan.Summary)"

  if ($checkOnly) {
    Report-ToolAvailability "pg_dump"
    Write-Log "Backup check complete."
    exit 0
  }

  $pgDump = Resolve-RequiredTool "pg_dump"
  $parent = Split-Path -Parent $resolvedOutputPath
  if (-not [string]::IsNullOrWhiteSpace($parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  if ((Test-Path -LiteralPath $resolvedOutputPath -PathType Leaf) -and $Force) {
    Remove-Item -LiteralPath $resolvedOutputPath -Force
  }

  Write-Log "Running pg_dump."
  Invoke-External -Tool $pgDump -Arguments ([string[]]$plan.Args) -TemporaryEnvironment $plan.Env
  Write-Log "Backup completed: $resolvedOutputPath"
  exit 0
} catch {
  Write-ErrorLog $_.Exception.Message
  exit 1
}
