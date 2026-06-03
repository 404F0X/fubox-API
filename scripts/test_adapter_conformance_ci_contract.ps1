#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$scriptPath = $PSCommandPath
if (-not $scriptPath) {
  $scriptPath = $MyInvocation.MyCommand.Path
}

$script:RepoRoot = (Resolve-Path -LiteralPath (Join-Path (Split-Path -Parent $scriptPath) "..")).Path
$script:RegexOptions = [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase

function Assert-Matches {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [Parameter(Mandatory = $true)][string]$Pattern,
    [Parameter(Mandatory = $true)][string]$Message
  )

  if (-not [regex]::IsMatch($Text, $Pattern, $script:RegexOptions)) {
    throw $Message
  }
}

function Assert-LineMatches {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [Parameter(Mandatory = $true)][string]$Pattern,
    [Parameter(Mandatory = $true)][string]$Message
  )

  foreach ($line in ($Text -split "`r?`n")) {
    if ([regex]::IsMatch($line, $Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
      return
    }
  }

  throw $Message
}

function Assert-Order {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [Parameter(Mandatory = $true)][string]$FirstPattern,
    [Parameter(Mandatory = $true)][string]$SecondPattern,
    [Parameter(Mandatory = $true)][string]$Message
  )

  $first = [regex]::Match($Text, $FirstPattern, $script:RegexOptions)
  $second = [regex]::Match($Text, $SecondPattern, $script:RegexOptions)
  if (-not $first.Success -or -not $second.Success -or $first.Index -gt $second.Index) {
    throw $Message
  }
}

$ciPath = Join-Path $script:RepoRoot ".github/workflows/ci.yml"
$testWrapperPath = Join-Path $script:RepoRoot "scripts/test.ps1"

if (-not (Test-Path -LiteralPath $ciPath -PathType Leaf)) {
  throw "CI workflow not found: $ciPath"
}
if (-not (Test-Path -LiteralPath $testWrapperPath -PathType Leaf)) {
  throw "test wrapper not found: $testWrapperPath"
}

$ci = Get-Content -LiteralPath $ciPath -Raw
$testWrapper = Get-Content -LiteralPath $testWrapperPath -Raw

Assert-Matches `
  -Text $ci `
  -Pattern '(?m)^\s*-\s*name:\s*Adapter conformance strict\s*$' `
  -Message "CI workflow is missing the Adapter conformance strict step."
Assert-LineMatches `
  -Text $ci `
  -Pattern 'Invoke-CheckedScript\s+-Path\s+"\./scripts/adapter_conformance\.ps1"\s+-Parameters\s+@\{\s*Strict\s*=\s*\$true\s*\}' `
  -Message "CI workflow does not invoke scripts/adapter_conformance.ps1 with Strict = true."
Assert-Order `
  -Text $ci `
  -FirstPattern '(?m)^\s*-\s*name:\s*Adapter conformance strict\s*$' `
  -SecondPattern '(?m)^\s*-\s*name:\s*Tests\s*$' `
  -Message "CI adapter conformance strict step must run before the workspace Tests step."

Assert-LineMatches `
  -Text $testWrapper `
  -Pattern 'Invoke-CheckedScript\s+-Path\s+"\$PSScriptRoot\\adapter_conformance\.ps1"\s+-Parameters\s+@\{\s*Strict\s*=\s*\$true\s*\}' `
  -Message "scripts/test.ps1 does not invoke adapter_conformance.ps1 with Strict = true."
Assert-Order `
  -Text $testWrapper `
  -FirstPattern 'Invoke-CheckedScript\s+-Path\s+"\$PSScriptRoot\\adapter_conformance\.ps1"\s+-Parameters\s+@\{\s*Strict\s*=\s*\$true\s*\}' `
  -SecondPattern '(?m)^\s*cargo test --workspace --all-targets --all-features\s*$' `
  -Message "scripts/test.ps1 adapter conformance strict gate must run before workspace cargo tests."

Write-Host "[OK] adapter conformance CI contract passed"
