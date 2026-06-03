<#
.SYNOPSIS
  Restore PostgreSQL from a backup dump.

.DESCRIPTION
  Restores one PostgreSQL custom-format dump with pg_restore. -InputPath is
  either a dump file path or a backup directory containing postgres.dump.

  Restore is dry-run by default. Pass -Force to execute pg_restore after
  confirming the target database is the intended restore target. The script does
  not create or drop databases and does not pass --clean.

.EXAMPLE
  .\scripts\db\restore.ps1 -InputPath D:\backups\fubox\postgres.dump -DatabaseUrl "postgres://fubox:<secret>@localhost:5432/fubox_restore"

.EXAMPLE
  .\scripts\db\restore.ps1 -Force -InputPath D:\backups\fubox\postgres.dump -DbHost localhost -DbName fubox_restore -DbUser fubox
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$InputPath,

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

function Resolve-RestoreInputPath {
  param([string]$Path)

  Assert-NotBlank "InputPath" $Path
  $resolved = Resolve-UnresolvedPath $Path
  if (Test-Path -LiteralPath $resolved -PathType Container) {
    return (Join-Path $resolved "postgres.dump")
  }
  return $resolved
}

function Get-PostgresRestorePlan {
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
      Args = @(
        "--dbname",
        $safeConnection,
        "--single-transaction",
        "--exit-on-error",
        "--no-owner",
        "--no-acl",
        $DumpPath
      )
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
      "--host",
      $DbHost,
      "--port",
      [string]$port,
      "--username",
      $DbUser,
      "--dbname",
      $DbName,
      "--single-transaction",
      "--exit-on-error",
      "--no-owner",
      "--no-acl",
      $DumpPath
    )
    Env = $envVars
    Summary = "host=$DbHost port=$port db=$DbName user=$DbUser"
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
    Write-WarnLog "$Name was not found in PATH. Actual restore execution requires it."
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
  if ($Force -and ($DryRun -or $Preflight)) {
    Fail "Use -Force only for execution. Do not combine it with -DryRun or -Preflight."
  }
  if ($DryRun -and $Preflight) {
    Fail "Use either -DryRun or -Preflight, not both."
  }

  $resolvedInputPath = Resolve-RestoreInputPath $InputPath
  $plan = Get-PostgresRestorePlan -DumpPath $resolvedInputPath

  $checkOnly = $DryRun -or $Preflight -or (-not $Force)
  if ($Force) {
    Write-Log "Mode: execute. -Force confirms the target database is the intended restore target."
  } elseif ($Preflight) {
    Write-Log "Mode: preflight. pg_restore will not run."
  } else {
    Write-Log "Mode: dry-run. Pass -Force to execute pg_restore."
  }

  Write-Log "Restore input path: $resolvedInputPath"
  Write-Log "PostgreSQL target: $($plan.Summary)"

  $inputExists = Test-Path -LiteralPath $resolvedInputPath -PathType Leaf
  if (-not $inputExists) {
    if ($Force -or $Preflight) {
      Fail "Input dump file was not found: $resolvedInputPath"
    }
    Write-WarnLog "Input dump file was not found. Dry-run continues without executing pg_restore."
  }

  if ($checkOnly) {
    Report-ToolAvailability "pg_restore"
    Write-Log "Restore check complete."
    exit 0
  }

  $pgRestore = Resolve-RequiredTool "pg_restore"
  Write-Log "Running pg_restore without --clean or --create."
  Invoke-External -Tool $pgRestore -Arguments ([string[]]$plan.Args) -TemporaryEnvironment $plan.Env
  Write-Log "Restore completed."
  exit 0
} catch {
  Write-ErrorLog $_.Exception.Message
  exit 1
}
