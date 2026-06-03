<#
.SYNOPSIS
  Back up PostgreSQL and optionally Redis into a timestamped directory.

.DESCRIPTION
  Uses pg_dump for PostgreSQL. Redis is skipped by default and can be enabled
  with -IncludeRedis, which uses redis-cli --rdb to capture the Redis instance
  RDB file.

  Connection values can be supplied through parameters or environment
  variables. Passwords are passed through child-process environment variables
  where possible and are never printed.

.EXAMPLE
  .\scripts\backup_datastores.ps1 -PostgresHost localhost -PostgresDatabase fubox -PostgresUser fubox

.EXAMPLE
  $env:DATABASE_URL = "postgres://fubox:secret@localhost:5432/fubox"
  .\scripts\backup_datastores.ps1 -OutputRoot D:\backups\fubox

.EXAMPLE
  .\scripts\backup_datastores.ps1 -IncludeRedis -RedisHost localhost -RedisPort 6379

.EXAMPLE
  .\scripts\backup_datastores.ps1 -DryRun -PostgresHost localhost -PostgresDatabase fubox -PostgresUser fubox
#>
[CmdletBinding()]
param(
  [string]$OutputRoot = "",

  [switch]$SkipPostgres,
  [string]$PostgresUrl = $(if ($env:DATABASE_URL) { $env:DATABASE_URL } elseif ($env:POSTGRES_URL) { $env:POSTGRES_URL } else { "" }),
  [string]$PostgresHost = $(if ($env:PGHOST) { $env:PGHOST } else { "" }),
  [string]$PostgresPort = $(if ($env:PGPORT) { $env:PGPORT } else { "5432" }),
  [string]$PostgresDatabase = $(if ($env:PGDATABASE) { $env:PGDATABASE } else { "" }),
  [string]$PostgresUser = $(if ($env:PGUSER) { $env:PGUSER } else { "" }),
  [string]$PostgresPassword = $(if ($env:PGPASSWORD) { $env:PGPASSWORD } else { "" }),

  [switch]$IncludeRedis,
  [string]$RedisUrl = $(if ($env:REDIS_URL) { $env:REDIS_URL } else { "" }),
  [string]$RedisHost = $(if ($env:REDIS_HOST) { $env:REDIS_HOST } else { "127.0.0.1" }),
  [string]$RedisPort = $(if ($env:REDIS_PORT) { $env:REDIS_PORT } else { "6379" }),
  [string]$RedisDatabase = $(if ($env:REDIS_DATABASE) { $env:REDIS_DATABASE } elseif ($env:REDIS_DB) { $env:REDIS_DB } else { "0" }),
  [string]$RedisUsername = $(if ($env:REDIS_USERNAME) { $env:REDIS_USERNAME } else { "" }),
  [string]$RedisPassword = $(if ($env:REDIS_PASSWORD) { $env:REDIS_PASSWORD } else { "" }),
  [switch]$RedisTls,

  [string]$TimestampFormat = "yyyyMMdd-HHmmss",
  [switch]$DryRun
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

function Convert-ToNonNegativeInt {
  param(
    [string]$Name,
    [string]$Value
  )

  $parsed = 0
  if (-not [int]::TryParse($Value, [ref]$parsed)) {
    Fail "$Name must be a non-negative integer."
  }
  if ($parsed -lt 0) {
    Fail "$Name must be a non-negative integer."
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

function Get-DefaultOutputRoot {
  if (-not [string]::IsNullOrWhiteSpace($env:BACKUP_ROOT)) {
    return $env:BACKUP_ROOT
  }

  $scriptPath = $PSCommandPath
  if ([string]::IsNullOrWhiteSpace($scriptPath)) {
    $scriptPath = $MyInvocation.MyCommand.Path
  }
  if ([string]::IsNullOrWhiteSpace($scriptPath)) {
    $scriptRootValue = (Get-Location).Path
  } else {
    $scriptRootValue = Split-Path -Parent $scriptPath
  }

  $repoRoot = Resolve-Path (Join-Path $scriptRootValue "..")
  return (Join-Path $repoRoot "backups")
}

function Get-PostgresDumpPlan {
  param([string]$DumpPath)

  if (-not [string]::IsNullOrWhiteSpace($PostgresUrl)) {
    $passwordCopy = $PostgresPassword
    $safeUrl = Remove-UrlPassword -Url $PostgresUrl -PasswordRef ([ref]$passwordCopy)
    $args = @("--format=custom", "--no-owner", "--file", $DumpPath, $safeUrl)
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
    "--format=custom",
    "--no-owner",
    "--file",
    $DumpPath,
    "--host",
    $PostgresHost,
    "--port",
    [string]$pgPort,
    "--username",
    $PostgresUser,
    "--dbname",
    $PostgresDatabase
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

function Get-RedisRdbPlan {
  param([string]$RdbPath)

  if (-not [string]::IsNullOrWhiteSpace($RedisUrl)) {
    $passwordCopy = $RedisPassword
    $safeUrl = Remove-UrlPassword -Url $RedisUrl -PasswordRef ([ref]$passwordCopy)
    $args = @("-u", $safeUrl, "--rdb", $RdbPath)
    if ($RedisTls) {
      $args = @("--tls") + $args
    }
    $envVars = @{}
    if (-not [string]::IsNullOrWhiteSpace($passwordCopy)) {
      $envVars["REDISCLI_AUTH"] = $passwordCopy
    }
    return @{
      Args = $args
      Env = $envVars
      Summary = Redact-ConnectionText $RedisUrl
    }
  }

  Assert-NotBlank "RedisHost or RedisUrl/REDIS_URL" $RedisHost
  $redisPortValue = Convert-ToPort "RedisPort/REDIS_PORT" $RedisPort
  $redisDatabaseValue = Convert-ToNonNegativeInt "RedisDatabase/REDIS_DATABASE" $RedisDatabase

  $args = @(
    "--no-auth-warning",
    "-h",
    $RedisHost,
    "-p",
    [string]$redisPortValue,
    "-n",
    [string]$redisDatabaseValue,
    "--rdb",
    $RdbPath
  )
  if ($RedisTls) {
    $args = @("--tls") + $args
  }
  if (-not [string]::IsNullOrWhiteSpace($RedisUsername)) {
    $args = @("--user", $RedisUsername) + $args
  }

  $envVars = @{}
  if (-not [string]::IsNullOrWhiteSpace($RedisPassword)) {
    $envVars["REDISCLI_AUTH"] = $RedisPassword
  }

  return @{
    Args = $args
    Env = $envVars
    Summary = "host=$RedisHost port=$redisPortValue db=$redisDatabaseValue user=$RedisUsername"
  }
}

try {
  if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Get-DefaultOutputRoot
  }
  Assert-NotBlank "OutputRoot" $OutputRoot

  $timestamp = Get-Date -Format $TimestampFormat
  $backupDirectory = Join-Path $OutputRoot $timestamp
  $postgresDumpPath = Join-Path $backupDirectory "postgres.dump"
  $redisRdbPath = Join-Path $backupDirectory "redis.rdb"

  Write-Log "Backup directory: $backupDirectory"

  if (-not $SkipPostgres) {
    $pgPlan = Get-PostgresDumpPlan -DumpPath $postgresDumpPath
    Write-Log "PostgreSQL backup enabled: $($pgPlan.Summary)"
  } else {
    Write-Log "PostgreSQL backup skipped by -SkipPostgres."
  }

  if ($IncludeRedis) {
    $redisPlan = Get-RedisRdbPlan -RdbPath $redisRdbPath
    Write-Log "Redis RDB backup enabled: $($redisPlan.Summary)"
  } else {
    Write-Log "Redis backup skipped. Pass -IncludeRedis to run redis-cli --rdb."
  }

  if ($DryRun) {
    Write-Log "Dry-run complete. No directories were created and no backup tools were executed."
    exit 0
  }

  $pgDump = $null
  $redisCli = $null
  if (-not $SkipPostgres) {
    $pgDump = Resolve-RequiredTool "pg_dump"
  }
  if ($IncludeRedis) {
    $redisCli = Resolve-RequiredTool "redis-cli"
  }

  New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null

  if (-not $SkipPostgres) {
    Write-Log "Running pg_dump to $postgresDumpPath"
    Invoke-Tool -Tool $pgDump -Arguments ([string[]]$pgPlan.Args) -TemporaryEnvironment $pgPlan.Env
    Write-Log "PostgreSQL backup completed."
  }

  if ($IncludeRedis) {
    Write-Log "Running redis-cli --rdb to $redisRdbPath"
    Invoke-Tool -Tool $redisCli -Arguments ([string[]]$redisPlan.Args) -TemporaryEnvironment $redisPlan.Env
    Write-Log "Redis RDB backup completed."
  }

  $metadata = [ordered]@{
    created_at = (Get-Date).ToUniversalTime().ToString("o")
    postgres = (-not $SkipPostgres)
    redis = [bool]$IncludeRedis
    postgres_dump = $(if (-not $SkipPostgres) { "postgres.dump" } else { $null })
    redis_rdb = $(if ($IncludeRedis) { "redis.rdb" } else { $null })
  }
  $metadata | ConvertTo-Json | Set-Content -Path (Join-Path $backupDirectory "metadata.json") -Encoding UTF8

  Write-Log "Backup finished: $backupDirectory"
  exit 0
} catch {
  Write-ErrorLog $_.Exception.Message
  exit 1
}
