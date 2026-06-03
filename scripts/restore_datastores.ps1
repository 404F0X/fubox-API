<#
.SYNOPSIS
  Restore PostgreSQL from a backup directory or dump file.

.DESCRIPTION
  The script is dry-run by default. It performs a destructive PostgreSQL restore
  only when -ConfirmRestore is supplied. It never drops or creates the target
  database automatically and does not pass pg_restore --clean.

  Redis RDB restore is intentionally not automated because restoring an RDB file
  requires service-level control of the Redis data directory. Use -IncludeRedis
  to have the script validate and print the Redis restore plan.

.EXAMPLE
  .\scripts\restore_datastores.ps1 -BackupPath D:\backups\fubox\20260602-181500 -PostgresHost localhost -PostgresDatabase fubox_restore -PostgresUser fubox

.EXAMPLE
  .\scripts\restore_datastores.ps1 -DryRun -PostgresDumpPath D:\backups\fubox\postgres.dump -PostgresUrl "postgres://fubox@localhost:5432/fubox_restore"

.EXAMPLE
  .\scripts\restore_datastores.ps1 -ConfirmRestore -BackupPath D:\backups\fubox\20260602-181500 -PostgresUrl "postgres://fubox@localhost:5432/fubox_restore"
#>
[CmdletBinding()]
param(
  [string]$BackupPath = "",
  [string]$PostgresDumpPath = "",

  [switch]$ConfirmRestore,
  [switch]$DryRun,
  [switch]$SkipPostgres,
  [string]$PostgresUrl = $(if ($env:DATABASE_URL) { $env:DATABASE_URL } elseif ($env:POSTGRES_URL) { $env:POSTGRES_URL } else { "" }),
  [string]$PostgresHost = $(if ($env:PGHOST) { $env:PGHOST } else { "" }),
  [string]$PostgresPort = $(if ($env:PGPORT) { $env:PGPORT } else { "5432" }),
  [string]$PostgresDatabase = $(if ($env:PGDATABASE) { $env:PGDATABASE } else { "" }),
  [string]$PostgresUser = $(if ($env:PGUSER) { $env:PGUSER } else { "" }),
  [string]$PostgresPassword = $(if ($env:PGPASSWORD) { $env:PGPASSWORD } else { "" }),

  [switch]$IncludeRedis,
  [string]$RedisRdbPath = ""
)

$ErrorActionPreference = "Stop"

function Write-Log {
  param([string]$Message)
  $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Write-Host "[$stamp] $Message"
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

function Resolve-RequiredTool {
  param([string]$Name)

  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if (-not $cmd) {
    Fail "Required tool '$Name' was not found in PATH."
  }
  return $cmd.Source
}

function Redact-ConnectionText {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return ""
  }

  $redacted = $Value -replace "(?i)(password\s*=\s*)[^ ;]+", '${1}****'
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

  if ([string]::IsNullOrWhiteSpace($uri.UserInfo) -or ($uri.UserInfo -notmatch ":")) {
    return $Url
  }

  $parts = $uri.UserInfo.Split(":", 2)
  if ([string]::IsNullOrWhiteSpace($PasswordRef.Value)) {
    $PasswordRef.Value = [Uri]::UnescapeDataString($parts[1])
  }

  $builder = [UriBuilder]::new($uri)
  $builder.UserName = $parts[0]
  $builder.Password = ""
  return $builder.Uri.AbsoluteUri
}

function Invoke-Tool {
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

function Resolve-PostgresDumpPath {
  if (-not [string]::IsNullOrWhiteSpace($PostgresDumpPath)) {
    return $PostgresDumpPath
  }

  Assert-NotBlank "BackupPath or PostgresDumpPath" $BackupPath

  if (Test-Path -LiteralPath $BackupPath -PathType Leaf) {
    return $BackupPath
  }

  return (Join-Path $BackupPath "postgres.dump")
}

function Resolve-RedisRdbPath {
  if (-not [string]::IsNullOrWhiteSpace($RedisRdbPath)) {
    return $RedisRdbPath
  }

  Assert-NotBlank "BackupPath or RedisRdbPath" $BackupPath
  return (Join-Path $BackupPath "redis.rdb")
}

function Get-PostgresRestorePlan {
  param([string]$DumpPath)

  if (-not [string]::IsNullOrWhiteSpace($PostgresUrl)) {
    $passwordCopy = $PostgresPassword
    $safeUrl = Remove-UrlPassword -Url $PostgresUrl -PasswordRef ([ref]$passwordCopy)
    $args = @(
      "--dbname",
      $safeUrl,
      "--single-transaction",
      "--exit-on-error",
      "--no-owner",
      "--no-acl",
      $DumpPath
    )
    $envVars = @{}
    if (-not [string]::IsNullOrWhiteSpace($passwordCopy)) {
      $envVars["PGPASSWORD"] = $passwordCopy
    }
    return @{
      Args = $args
      Env = $envVars
      Summary = Redact-ConnectionText $PostgresUrl
    }
  }

  Assert-NotBlank "PostgresHost or PostgresUrl/DATABASE_URL" $PostgresHost
  Assert-NotBlank "PostgresDatabase or PGDATABASE" $PostgresDatabase
  Assert-NotBlank "PostgresUser or PGUSER" $PostgresUser
  $pgPort = Convert-ToPort "PostgresPort/PGPORT" $PostgresPort

  $args = @(
    "--host",
    $PostgresHost,
    "--port",
    [string]$pgPort,
    "--username",
    $PostgresUser,
    "--dbname",
    $PostgresDatabase,
    "--single-transaction",
    "--exit-on-error",
    "--no-owner",
    "--no-acl",
    $DumpPath
  )
  $envVars = @{}
  if (-not [string]::IsNullOrWhiteSpace($PostgresPassword)) {
    $envVars["PGPASSWORD"] = $PostgresPassword
  }

  return @{
    Args = $args
    Env = $envVars
    Summary = "host=$PostgresHost port=$pgPort db=$PostgresDatabase user=$PostgresUser"
  }
}

try {
  if ($DryRun -and $ConfirmRestore) {
    Fail "Use either -DryRun or -ConfirmRestore, not both."
  }

  $dryRun = $DryRun -or (-not $ConfirmRestore)

  if ($dryRun) {
    Write-Log "Dry-run mode. Pass -ConfirmRestore to execute PostgreSQL restore."
  } else {
    Write-Log "ConfirmRestore supplied. PostgreSQL restore may modify the target database."
  }

  if (-not $SkipPostgres) {
    $dumpPath = Resolve-PostgresDumpPath
    $pgPlan = Get-PostgresRestorePlan -DumpPath $dumpPath
    Write-Log "PostgreSQL restore target: $($pgPlan.Summary)"
    Write-Log "PostgreSQL dump path: $dumpPath"

    if (-not (Test-Path -LiteralPath $dumpPath -PathType Leaf)) {
      if ($dryRun) {
        Write-Log "Dump file was not found. Dry-run continues without executing pg_restore."
      } else {
        Fail "PostgreSQL dump file was not found: $dumpPath"
      }
    }

    if (-not $dryRun) {
      $pgRestore = Resolve-RequiredTool "pg_restore"
      Write-Log "Running pg_restore without --clean or --create."
      Invoke-Tool -Tool $pgRestore -Arguments ([string[]]$pgPlan.Args) -TemporaryEnvironment $pgPlan.Env
      Write-Log "PostgreSQL restore completed."
    }
  } else {
    Write-Log "PostgreSQL restore skipped by -SkipPostgres."
  }

  if ($IncludeRedis) {
    $rdbPath = Resolve-RedisRdbPath
    Write-Log "Redis RDB path: $rdbPath"
    if (-not (Test-Path -LiteralPath $rdbPath -PathType Leaf)) {
      if ($dryRun) {
        Write-Log "Redis RDB file was not found. Dry-run continues without Redis changes."
      } else {
        Fail "Redis RDB file was not found: $rdbPath"
      }
    }

    if ($dryRun) {
      Write-Log "Redis RDB restore is manual: stop Redis, replace the configured dump.rdb, then start Redis."
    } else {
      Fail "Automatic Redis RDB restore is intentionally not implemented. Follow docs/backup_restore.md for the manual service-level restore."
    }
  }

  if ($dryRun) {
    Write-Log "Dry-run complete. No restore commands were executed."
  }
  exit 0
} catch {
  Write-ErrorLog $_.Exception.Message
  exit 1
}
