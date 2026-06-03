#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$scriptPath = $PSCommandPath
if (-not $scriptPath) {
  $scriptPath = $MyInvocation.MyCommand.Path
}
$script:RepoRoot = (Resolve-Path (Join-Path (Split-Path -Parent $scriptPath) "..")).Path
$scanScript = Join-Path $script:RepoRoot "scripts/scan_supply_chain.ps1"

function Protect-TestLogText {
  param([string]$Text)

  if ([string]::IsNullOrEmpty($Text)) {
    return $Text
  }

  $redacted = $Text
  $redacted = $redacted -replace '(?i)(authorization\s*[:=]\s*bearer\s+)[^\s";]+', '$1[REDACTED]'
  $redacted = $redacted -replace '(?i)((?:token|password|passwd|secret|api[_-]?key|access[_-]?key|private[_-]?key)\s*[:=]\s*)[^\s";]+', '$1[REDACTED]'
  $redacted = $redacted -replace '(?i)(Bearer\s+)[A-Za-z0-9._~+/\-]+=*', '$1[REDACTED]'
  $redacted = $redacted -replace '(?i)(://[^:/@\s]+:)[^@\s]+(@)', '$1[REDACTED]$2'
  return $redacted
}

function Write-SafeOutputTail {
  param(
    [string[]]$Lines,
    [int]$MaxLines = 40
  )

  foreach ($line in @($Lines | Select-Object -Last $MaxLines)) {
    $safeLine = Protect-TestLogText $line
    if ($safeLine.Length -gt 500) {
      $safeLine = $safeLine.Substring(0, 500) + "..."
    }
    if ($safeLine.Length -gt 0) {
      Write-Host ("    {0}" -f $safeLine)
    }
  }
}

function Get-PowerShellRunner {
  $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
  if ($pwsh) {
    return [pscustomobject]@{ Path = $pwsh.Source; IsWindowsPowerShell = $false }
  }

  $powershell = Get-Command powershell -ErrorAction SilentlyContinue
  if ($powershell) {
    return [pscustomobject]@{ Path = $powershell.Source; IsWindowsPowerShell = $true }
  }

  throw "No PowerShell runner found for supply-chain scan self-test."
}

if (-not (Test-Path -LiteralPath $scanScript)) {
  throw ("Supply-chain scan script not found: {0}" -f $scanScript)
}

$runner = Get-PowerShellRunner
$arguments = @("-NoLogo", "-NoProfile")
if ($runner.IsWindowsPowerShell) {
  $arguments += @("-ExecutionPolicy", "Bypass")
}
$arguments += @("-File", $scanScript, "-SkipNetwork")

$output = & $runner.Path @arguments 2>&1
$exitCode = $LASTEXITCODE
$lines = @($output | ForEach-Object { $_.ToString() })

if ($exitCode -ne 0) {
  Write-Host ("[FAIL] supply-chain scan exited with code {0}" -f $exitCode)
  Write-SafeOutputTail $lines
  exit $exitCode
}

$requiredPatterns = @(
  [pscustomobject]@{ Pattern = 'Cargo\.lock provenance fields valid'; Description = 'Cargo.lock source/checksum provenance check' },
  [pscustomobject]@{ Pattern = 'npm lockfile integrity coverage valid'; Description = 'npm package-lock integrity check' },
  [pscustomobject]@{ Pattern = 'container image pinning inspected'; Description = 'Docker base image pinning check' },
  [pscustomobject]@{ Pattern = 'Supply-chain artifact generator script present'; Description = 'supply-chain artifact generator script check' },
  [pscustomobject]@{ Pattern = 'Supply-chain scan self-test script present'; Description = 'supply-chain scan self-test script check' },
  [pscustomobject]@{ Pattern = 'CI SBOM/provenance artifact generation present'; Description = 'CI SBOM/provenance artifact generation check' },
  [pscustomobject]@{ Pattern = 'CI supply-chain artifact upload dry-run contract present'; Description = 'CI artifact upload dry-run contract check' },
  [pscustomobject]@{ Pattern = 'remaining supply-chain hardening gaps: digest pinning enforcement, network vulnerability scans, real built image scans'; Description = 'explicit remaining supply-chain gaps check' },
  [pscustomobject]@{ Pattern = 'network-backed cargo audit, npm audit, and container vulnerability scan skipped'; Description = 'offline SkipNetwork skip contract' }
)

foreach ($required in $requiredPatterns) {
  if (-not ($lines | Where-Object { $_ -match $required.Pattern } | Select-Object -First 1)) {
    Write-Host ("[FAIL] missing expected output: {0}" -f $required.Description)
    Write-SafeOutputTail $lines
    exit 1
  }
}

Write-Host "[OK] supply-chain scan self-test passed"
