param(
  [switch]$GatewayRateLimitReservationSmokeOnly,
  [switch]$GatewayRateLimitReservationSmokePreflight,
  [switch]$GatewayRateLimitReservationSmokeLive,
  [switch]$ControlPlaneLedgerAdjustmentExecuteSmokeOnly,
  [switch]$ControlPlaneLedgerAdjustmentExecuteSmokeLive,
  [switch]$PromptProtectionPostgresProofOnly,
  [switch]$PromptProtectionPostgresProofLive
)

$ErrorActionPreference = "Stop"

function Test-TruthyEnv {
  param([AllowNull()][string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $false
  }

  return @("1", "true", "yes", "on").Contains($Value.Trim().ToLowerInvariant())
}

function Invoke-CheckedScript {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [hashtable]$Parameters = @{}
  )

  $global:LASTEXITCODE = 0
  & $Path @Parameters
  $scriptSucceeded = $?
  $exitCode = $global:LASTEXITCODE
  if (-not $scriptSucceeded) {
    if ($null -ne $exitCode -and $exitCode -ne 0) { exit $exitCode }
    exit 1
  }
  if ($null -ne $exitCode -and $exitCode -ne 0) { exit $exitCode }
}

function Get-GatewayRateLimitReservationSmokeParameters {
  if ($GatewayRateLimitReservationSmokeLive) {
    return @{}
  }

  if ($GatewayRateLimitReservationSmokePreflight) {
    return @{ PreflightOnly = $true }
  }

  return @{ DryRun = $true }
}

function Invoke-GatewayRateLimitReservationSmoke {
  $mode = "dry-run"
  if ($GatewayRateLimitReservationSmokeLive) {
    $mode = "live"
  } elseif ($GatewayRateLimitReservationSmokePreflight) {
    $mode = "preflight"
  }

  Write-Host "Gateway rate-limit reservation smoke mode: $mode"
  Invoke-CheckedScript `
    -Path "$PSScriptRoot\verify_gateway_rate_limit_reservation_smoke.ps1" `
    -Parameters (Get-GatewayRateLimitReservationSmokeParameters)
}

function Get-ControlPlaneLedgerAdjustmentExecuteSmokeParameters {
  if ($ControlPlaneLedgerAdjustmentExecuteSmokeLive) {
    return @{}
  }

  return @{ ContractOnly = $true }
}

function Invoke-ControlPlaneLedgerAdjustmentExecuteSmoke {
  $mode = "contract-only"
  if ($ControlPlaneLedgerAdjustmentExecuteSmokeLive) {
    $mode = "live"
  }

  Write-Host "Control Plane ledger adjustment execute smoke mode: $mode"
  Invoke-CheckedScript `
    -Path "$PSScriptRoot\verify_control_plane_ledger_adjustment_openapi_contract.ps1"
  Invoke-CheckedScript `
    -Path "$PSScriptRoot\verify_control_plane_ledger_adjustment_execute_smoke.ps1" `
    -Parameters (Get-ControlPlaneLedgerAdjustmentExecuteSmokeParameters)
}

function Get-PromptProtectionPostgresProofParameters {
  if ($PromptProtectionPostgresProofLive) {
    return @{ Live = $true }
  }

  return @{ ContractOnly = $true }
}

function Invoke-PromptProtectionPostgresProof {
  $mode = "contract-only"
  if ($PromptProtectionPostgresProofLive) {
    $mode = "live"
  }

  Write-Host "Prompt Protection Postgres proof mode: $mode"
  Invoke-CheckedScript `
    -Path "$PSScriptRoot\verify_prompt_protection_postgres_proof.ps1" `
    -Parameters (Get-PromptProtectionPostgresProofParameters)
}

if (Test-TruthyEnv $env:GATEWAY_RATE_LIMIT_RESERVATION_SMOKE_ONLY) {
  $GatewayRateLimitReservationSmokeOnly = $true
}
if (Test-TruthyEnv $env:GATEWAY_RATE_LIMIT_RESERVATION_SMOKE_PREFLIGHT) {
  $GatewayRateLimitReservationSmokePreflight = $true
}
if (Test-TruthyEnv $env:GATEWAY_RATE_LIMIT_RESERVATION_SMOKE_LIVE) {
  $GatewayRateLimitReservationSmokeLive = $true
}
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_SMOKE_ONLY) {
  $ControlPlaneLedgerAdjustmentExecuteSmokeOnly = $true
}
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_SMOKE_LIVE) {
  $ControlPlaneLedgerAdjustmentExecuteSmokeLive = $true
}
if (Test-TruthyEnv $env:PROMPT_PROTECTION_POSTGRES_PROOF_ONLY) {
  $PromptProtectionPostgresProofOnly = $true
}
if (Test-TruthyEnv $env:E13_PROMPT_PROTECTION_POSTGRES_PROOF_ONLY) {
  $PromptProtectionPostgresProofOnly = $true
}
if (Test-TruthyEnv $env:PROMPT_PROTECTION_POSTGRES_PROOF_LIVE) {
  $PromptProtectionPostgresProofLive = $true
}
if (Test-TruthyEnv $env:E13_PROMPT_PROTECTION_POSTGRES_PROOF_LIVE) {
  $PromptProtectionPostgresProofLive = $true
}

if ($GatewayRateLimitReservationSmokePreflight -and $GatewayRateLimitReservationSmokeLive) {
  throw "Use either -GatewayRateLimitReservationSmokePreflight or -GatewayRateLimitReservationSmokeLive, not both."
}
$smokeOnlyCount = @(
  $GatewayRateLimitReservationSmokeOnly,
  $ControlPlaneLedgerAdjustmentExecuteSmokeOnly,
  $PromptProtectionPostgresProofOnly
) | Where-Object { $_ } | Measure-Object | Select-Object -ExpandProperty Count
if ($smokeOnlyCount -gt 1) {
  throw "Use only one smoke-only switch at a time."
}

if ($GatewayRateLimitReservationSmokeOnly) {
  Invoke-GatewayRateLimitReservationSmoke
  exit 0
}
if ($ControlPlaneLedgerAdjustmentExecuteSmokeOnly) {
  Invoke-ControlPlaneLedgerAdjustmentExecuteSmoke
  exit 0
}
if ($PromptProtectionPostgresProofOnly) {
  Invoke-PromptProtectionPostgresProof
  exit 0
}

Invoke-CheckedScript -Path "$PSScriptRoot\test_adapter_conformance_ci_contract.ps1"
Invoke-CheckedScript -Path "$PSScriptRoot\adapter_conformance.ps1" -Parameters @{ Strict = $true }

cargo test --workspace --all-targets --all-features
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Invoke-CheckedScript -Path "$PSScriptRoot\verify_control_plane_auth_smoke.ps1" -Parameters @{ DryRun = $true }
Invoke-CheckedScript -Path "$PSScriptRoot\verify_control_plane_crud_smoke.ps1" -Parameters @{ DryRun = $true }
Invoke-CheckedScript -Path "$PSScriptRoot\verify_gateway_profile_smoke.ps1" -Parameters @{ DryRun = $true }
Invoke-CheckedScript -Path "$PSScriptRoot\verify_gateway_streaming_smoke.ps1" -Parameters @{ DryRun = $true }
Invoke-CheckedScript -Path "$PSScriptRoot\verify_gateway_retry_fallback_smoke.ps1" -Parameters @{ DryRun = $true }
Invoke-CheckedScript -Path "$PSScriptRoot\verify_provider_key_runtime_smoke.ps1" -Parameters @{ DryRun = $true }
Invoke-GatewayRateLimitReservationSmoke
Invoke-ControlPlaneLedgerAdjustmentExecuteSmoke
Invoke-PromptProtectionPostgresProof
Invoke-CheckedScript -Path "$PSScriptRoot\verify_compose_smoke.ps1" -Parameters @{ DryRun = $true }
Invoke-CheckedScript -Path "$PSScriptRoot\test_supply_chain_scan.ps1"
Invoke-CheckedScript -Path "$PSScriptRoot\test_supply_chain_artifacts.ps1"

npm --prefix web/admin-ui ci
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

npm --prefix web/admin-ui test
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

npm --prefix web/admin-ui run build
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

npm --prefix web/admin-ui run check:bundle
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
