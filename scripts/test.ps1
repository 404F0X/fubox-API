$ErrorActionPreference = "Stop"

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
