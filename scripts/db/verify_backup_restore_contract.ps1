#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$scriptPath = $PSCommandPath
if (-not $scriptPath) {
  $scriptPath = $MyInvocation.MyCommand.Path
}
$script:RepoRoot = (Resolve-Path (Join-Path (Split-Path -Parent $scriptPath) "..\..")).Path
$script:BackupScript = Join-Path $script:RepoRoot "scripts\db\backup.ps1"
$script:RestoreScript = Join-Path $script:RepoRoot "scripts\db\restore.ps1"

function Protect-TestLogText {
  param([string]$Text)

  if ([string]::IsNullOrEmpty($Text)) {
    return $Text
  }

  $redacted = $Text
  $redacted = $redacted -replace '(?i)(://[^:/@\s]+:)[^@\s]+(@)', '$1[REDACTED]$2'
  $redacted = $redacted -replace '(?i)(password\s*=\s*)[^ ;&]+', '$1[REDACTED]'
  $redacted = $redacted -replace '(?i)(PGPASSWORD=)[^\s;]+', '$1[REDACTED]'
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

  throw "No PowerShell runner found for backup/restore contract verification."
}

function Invoke-DbScript {
  param(
    [string]$Path,
    [string[]]$Arguments
  )

  $runner = Get-PowerShellRunner
  $commandArguments = @("-NoLogo", "-NoProfile")
  if ($runner.IsWindowsPowerShell) {
    $commandArguments += @("-ExecutionPolicy", "Bypass")
  }
  $commandArguments += @("-File", $Path)
  $commandArguments += $Arguments

  $output = & $runner.Path @commandArguments 2>&1
  $lines = @($output | ForEach-Object { $_.ToString() })

  return [pscustomobject]@{
    ExitCode = $LASTEXITCODE
    Lines = $lines
    Text = ($lines -join "`n")
  }
}

function Assert-ExitCode {
  param(
    [string]$Name,
    [object]$Result,
    [int]$Expected
  )

  if ($Result.ExitCode -ne $Expected) {
    Write-Host ("[FAIL] {0} exited with code {1}, expected {2}" -f $Name, $Result.ExitCode, $Expected)
    Write-SafeOutputTail $Result.Lines
    exit 1
  }
}

function Assert-Contains {
  param(
    [string]$Name,
    [object]$Result,
    [string]$Expected
  )

  if ($Result.Text -notlike "*$Expected*") {
    Write-Host ("[FAIL] {0} missing expected output: {1}" -f $Name, $Expected)
    Write-SafeOutputTail $Result.Lines
    exit 1
  }
}

function Assert-NotContains {
  param(
    [string]$Name,
    [object]$Result,
    [string]$Forbidden
  )

  if ($Result.Text -like "*$Forbidden*") {
    Write-Host ("[FAIL] {0} leaked forbidden output: {1}" -f $Name, (Protect-TestLogText $Forbidden))
    Write-SafeOutputTail $Result.Lines
    exit 1
  }
}

function Assert-PathMissing {
  param(
    [string]$Name,
    [string]$Path
  )

  if (Test-Path -LiteralPath $Path) {
    Write-Host ("[FAIL] {0} unexpectedly created path: {1}" -f $Name, $Path)
    exit 1
  }
}

function New-ContractTempRoot {
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ("fubox-db-contract-" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $root -Force | Out-Null
  return (Resolve-Path $root).Path
}

function Remove-ContractTempRoot {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
    return
  }

  $resolvedPath = (Resolve-Path $Path).Path
  $resolvedTemp = (Resolve-Path ([System.IO.Path]::GetTempPath())).Path
  if (-not $resolvedPath.StartsWith($resolvedTemp, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove temp root outside system temp: $resolvedPath"
  }

  Remove-Item -LiteralPath $resolvedPath -Recurse -Force
}

if (-not (Test-Path -LiteralPath $script:BackupScript -PathType Leaf)) {
  throw "Backup script not found: $script:BackupScript"
}
if (-not (Test-Path -LiteralPath $script:RestoreScript -PathType Leaf)) {
  throw "Restore script not found: $script:RestoreScript"
}

$tempRoot = New-ContractTempRoot
try {
  $rawPassword = "fixture-db-password"
  $databaseUrl = "postgres://fubox:${rawPassword}@localhost:5432/fubox"
  $backupPath = Join-Path $tempRoot "postgres-contract.dump"

  $backupDryRun = Invoke-DbScript $script:BackupScript @(
    "-DryRun",
    "-OutputPath",
    $backupPath,
    "-DatabaseUrl",
    $databaseUrl
  )
  Assert-ExitCode "backup dry-run" $backupDryRun 0
  Assert-Contains "backup dry-run" $backupDryRun "Mode: dry-run"
  Assert-Contains "backup dry-run" $backupDryRun "Backup check complete."
  Assert-Contains "backup dry-run" $backupDryRun "****"
  Assert-NotContains "backup dry-run" $backupDryRun $rawPassword
  Assert-PathMissing "backup dry-run" $backupPath

  New-Item -ItemType File -Path $backupPath -Force | Out-Null
  $backupExistingFile = Invoke-DbScript $script:BackupScript @(
    "-DryRun",
    "-OutputPath",
    $backupPath,
    "-DatabaseUrl",
    $databaseUrl
  )
  Assert-ExitCode "backup existing output without Force" $backupExistingFile 1
  Assert-Contains "backup existing output without Force" $backupExistingFile "OutputPath already exists"
  Assert-NotContains "backup existing output without Force" $backupExistingFile $rawPassword

  $backupExistingFileForce = Invoke-DbScript $script:BackupScript @(
    "-DryRun",
    "-Force",
    "-OutputPath",
    $backupPath,
    "-DatabaseUrl",
    $databaseUrl
  )
  Assert-ExitCode "backup existing output with Force dry-run" $backupExistingFileForce 0
  Assert-Contains "backup existing output with Force dry-run" $backupExistingFileForce "Backup check complete."
  Assert-NotContains "backup existing output with Force dry-run" $backupExistingFileForce $rawPassword
  if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
    Write-Host "[FAIL] backup dry-run with Force should not delete existing output"
    exit 1
  }

  $missingDumpPath = Join-Path $tempRoot "missing.dump"
  $restoreDryRun = Invoke-DbScript $script:RestoreScript @(
    "-InputPath",
    $missingDumpPath,
    "-DatabaseUrl",
    $databaseUrl
  )
  Assert-ExitCode "restore default dry-run missing dump" $restoreDryRun 0
  Assert-Contains "restore default dry-run missing dump" $restoreDryRun "Mode: dry-run"
  Assert-Contains "restore default dry-run missing dump" $restoreDryRun "Input dump file was not found"
  Assert-Contains "restore default dry-run missing dump" $restoreDryRun "Restore check complete."
  Assert-NotContains "restore default dry-run missing dump" $restoreDryRun $rawPassword

  $restorePreflightMissing = Invoke-DbScript $script:RestoreScript @(
    "-Preflight",
    "-InputPath",
    $missingDumpPath,
    "-DatabaseUrl",
    $databaseUrl
  )
  Assert-ExitCode "restore preflight missing dump" $restorePreflightMissing 1
  Assert-Contains "restore preflight missing dump" $restorePreflightMissing "Input dump file was not found"
  Assert-NotContains "restore preflight missing dump" $restorePreflightMissing $rawPassword

  $restoreForceDryRunConflict = Invoke-DbScript $script:RestoreScript @(
    "-Force",
    "-DryRun",
    "-InputPath",
    $missingDumpPath,
    "-DatabaseUrl",
    $databaseUrl
  )
  Assert-ExitCode "restore Force and DryRun conflict" $restoreForceDryRunConflict 1
  Assert-Contains "restore Force and DryRun conflict" $restoreForceDryRunConflict "Do not combine"
  Assert-NotContains "restore Force and DryRun conflict" $restoreForceDryRunConflict $rawPassword

  $backupDirectory = Join-Path $tempRoot "backup-directory"
  New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
  $directoryDumpPath = Join-Path $backupDirectory "postgres.dump"
  Set-Content -LiteralPath $directoryDumpPath -Value "not-a-real-dump" -Encoding ASCII

  $restoreDirectoryDryRun = Invoke-DbScript $script:RestoreScript @(
    "-InputPath",
    $backupDirectory,
    "-DatabaseUrl",
    $databaseUrl
  )
  Assert-ExitCode "restore directory input dry-run" $restoreDirectoryDryRun 0
  Assert-Contains "restore directory input dry-run" $restoreDirectoryDryRun "postgres.dump"
  Assert-Contains "restore directory input dry-run" $restoreDirectoryDryRun "Restore check complete."
  Assert-NotContains "restore directory input dry-run" $restoreDirectoryDryRun $rawPassword

  Write-Host "[OK] backup/restore contract self-test passed"
} finally {
  Remove-ContractTempRoot $tempRoot
}
