param(
  [switch]$DryRun,
  [int]$MissingDatabaseExitCode = 2
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$fixturePath = Join-Path $repoRoot "tests\fixtures\billing\consistent_writer_postgres_sqlx_schema_contract.json"
$fixture = Get-Content -Raw $fixturePath | ConvertFrom-Json
$envVar = [string]$fixture.live_smoke.env_var
$liveTestName = [string]$fixture.live_smoke.ignored_test_name
$externalBlocker = [string]$fixture.live_smoke.external_blocker

$staticContractCommand = @(
  "cargo",
  "test",
  "-p",
  "ai-gateway-billing-ledger",
  "--features",
  "postgres-sqlx",
  "--test",
  "consistent_writer_postgres_sqlx_adapter_fixture",
  "postgres_sqlx_schema_contract_covers_reserve_settle_refund_executables",
  "--",
  "--exact"
)

$livePreflightCommand = @(
  "cargo",
  "test",
  "-p",
  "ai-gateway-billing-ledger",
  "--features",
  "postgres-sqlx",
  "--test",
  "consistent_writer_postgres_sqlx_adapter_fixture",
  $liveTestName,
  "--",
  "--ignored",
  "--exact"
)

function Join-CommandForDisplay {
  param([Parameter(Mandatory = $true)][string[]]$Command)

  return ($Command -join " ")
}

function Test-LiveDatabaseEnv {
  $value = [Environment]::GetEnvironmentVariable($envVar)
  return -not [string]::IsNullOrWhiteSpace($value)
}

function Invoke-RepoCommand {
  param([Parameter(Mandatory = $true)][string[]]$Command)

  & $Command[0] @($Command[1..($Command.Count - 1)])
  if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
  }
}

Write-Host "Billing ledger SQLx live smoke preflight"
Write-Host "Static contract command: $(Join-CommandForDisplay $staticContractCommand)"
Write-Host "Live preflight command: $(Join-CommandForDisplay $livePreflightCommand)"

$hasLiveDatabase = Test-LiveDatabaseEnv
if (-not $hasLiveDatabase) {
  Write-Host "[BLOCKED] $envVar is not set; $externalBlocker."
  exit $MissingDatabaseExitCode
}

if ($DryRun) {
  Write-Host "[READY] $envVar is set. Re-run without -DryRun to execute the live SQLx preflight."
  exit 0
}

Push-Location $repoRoot
try {
  Invoke-RepoCommand $staticContractCommand
  Invoke-RepoCommand $livePreflightCommand
} finally {
  Pop-Location
}

Write-Host "[OK] Billing ledger SQLx live smoke preflight completed."
