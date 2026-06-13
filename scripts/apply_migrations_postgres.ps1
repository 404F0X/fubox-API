param(
  [string]$DatabaseUrl = "",
  [string]$MigrationsPath = "db\migrations",
  [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Get-DatabaseUrl {
  if (-not [string]::IsNullOrWhiteSpace($DatabaseUrl)) {
    return $DatabaseUrl
  }
  if (-not [string]::IsNullOrWhiteSpace($env:CONTROL_PLANE_DATABASE_URL)) {
    return [string]$env:CONTROL_PLANE_DATABASE_URL
  }
  if (-not [string]::IsNullOrWhiteSpace($env:DATABASE_URL)) {
    return [string]$env:DATABASE_URL
  }
  throw "CONTROL_PLANE_DATABASE_URL or DATABASE_URL is required"
}

function Resolve-RepoBoundedPath {
  param([Parameter(Mandatory = $true)][string]$Path)

  $candidate = if ([System.IO.Path]::IsPathRooted($Path)) {
    [System.IO.Path]::GetFullPath($Path)
  } else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
  }
  $repoPrefix = $repoRoot.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
  if (-not $candidate.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "migrations_path_must_stay_inside_repo"
  }
  return $candidate
}

function Redact-SecretText {
  param([AllowNull()][string]$Text)
  if ([string]::IsNullOrEmpty($Text)) { return $Text }
  return (($Text -replace '(?i)postgres(?:ql)?://[^"\s]+', 'postgres://<redacted>') `
      -replace '(?i)(password\s*[:=]\s*)[^;\s]+', '$1<redacted>')
}

$dbUrl = Get-DatabaseUrl
$psql = Get-Command psql -ErrorAction SilentlyContinue
if ($null -eq $psql) {
  throw "psql executable was not found on PATH"
}

$resolvedMigrationsPath = Resolve-RepoBoundedPath -Path $MigrationsPath
if (-not (Test-Path -LiteralPath $resolvedMigrationsPath -PathType Container)) {
  throw "migrations_path_not_found: $MigrationsPath"
}

$migrationFiles = @(Get-ChildItem -LiteralPath $resolvedMigrationsPath -File -Filter "*.sql" | Sort-Object Name)
if (@($migrationFiles).Count -eq 0) {
  throw "no_postgres_migrations_found: $MigrationsPath"
}

$applied = [System.Collections.Generic.List[string]]::new()
foreach ($migration in $migrationFiles) {
  $relative = $migration.FullName.Substring(($repoRoot.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar).Length).Replace("\", "/")
  if ($WhatIf) {
    [void]$applied.Add($relative)
    continue
  }

  Write-Host "Applying $relative"
  $output = & $psql.Source $dbUrl -v ON_ERROR_STOP=1 -f $migration.FullName 2>&1
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) {
    $redactedOutput = Redact-SecretText (($output | Out-String).Trim())
    throw "migration_failed: $relative`n$redactedOutput"
  }
  [void]$applied.Add($relative)
}

$result = [ordered]@{
  schema = "postgres_migration_runner.v1"
  status = "pass"
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  docker_required = $false
  database_url_env = if (-not [string]::IsNullOrWhiteSpace($env:CONTROL_PLANE_DATABASE_URL)) { "CONTROL_PLANE_DATABASE_URL" } elseif (-not [string]::IsNullOrWhiteSpace($env:DATABASE_URL)) { "DATABASE_URL" } else { "DatabaseUrlParameter" }
  migrations_path = $MigrationsPath.Replace("\", "/")
  migration_count = @($applied).Count
  applied_migrations = @($applied.ToArray())
  what_if = [bool]$WhatIf
  secret_safe = $true
}

$result | ConvertTo-Json -Depth 8
