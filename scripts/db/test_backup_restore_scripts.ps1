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
$script:RawPassword = "fixture-db-pw:with@at"
$script:EncodedPassword = "fixture-db-pw%3Awith%40at"

function Protect-TestLogText {
  param([string]$Text)

  if ([string]::IsNullOrEmpty($Text)) {
    return $Text
  }

  $redacted = $Text
  $redacted = $redacted -replace '(?i)(://[^:/@\s]+:)[^@\s]+(@)', '$1[REDACTED]$2'
  $redacted = $redacted -replace '(?i)(password\s*=\s*)[^ ;&]+', '$1[REDACTED]'
  $redacted = $redacted -replace [regex]::Escape($script:RawPassword), "[REDACTED]"
  $redacted = $redacted -replace [regex]::Escape($script:EncodedPassword), "[REDACTED]"
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

  throw "No PowerShell runner found for backup/restore script tests."
}

function Invoke-DbScript {
  param(
    [string]$Path,
    [string[]]$Arguments,
    [hashtable]$Environment = @{}
  )

  $runner = Get-PowerShellRunner
  $commandArguments = @("-NoLogo", "-NoProfile")
  if ($runner.IsWindowsPowerShell) {
    $commandArguments += @("-ExecutionPolicy", "Bypass")
  }
  $commandArguments += @("-File", $Path)
  $commandArguments += $Arguments

  $managedNames = New-Object System.Collections.Generic.List[string]
  foreach ($name in @(
    "DATABASE_URL",
    "POSTGRES_URL",
    "PGHOST",
    "PGPORT",
    "PGDATABASE",
    "PGUSER",
    "PGPASSWORD",
    "FUBOX_DB_TEST_CAPTURE",
    "PATH"
  )) {
    [void]$managedNames.Add($name)
  }
  foreach ($name in $Environment.Keys) {
    if (-not $managedNames.Contains($name)) {
      [void]$managedNames.Add($name)
    }
  }

  $previous = @{}
  foreach ($name in $managedNames) {
    $previous[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
    [Environment]::SetEnvironmentVariable($name, $null, "Process")
  }
  foreach ($name in $Environment.Keys) {
    [Environment]::SetEnvironmentVariable($name, [string]$Environment[$name], "Process")
  }

  try {
    $output = & $runner.Path @commandArguments 2>&1
    $lines = @($output | ForEach-Object { $_.ToString() })
    return [pscustomobject]@{
      ExitCode = $LASTEXITCODE
      Lines = $lines
      Text = ($lines -join "`n")
    }
  } finally {
    foreach ($name in $managedNames) {
      [Environment]::SetEnvironmentVariable($name, $previous[$name], "Process")
    }
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

function Assert-NotContainsText {
  param(
    [string]$Name,
    [string]$Text,
    [string]$Forbidden
  )

  if ($Text -like "*$Forbidden*") {
    Write-Host ("[FAIL] {0} leaked forbidden text" -f $Name)
    Write-SafeOutputTail @($Text -split "`n")
    exit 1
  }
}

function Assert-OutputDoesNotLeakSecret {
  param(
    [string]$Name,
    [object]$Result
  )

  Assert-NotContainsText $Name $Result.Text $script:RawPassword
  Assert-NotContainsText $Name $Result.Text $script:EncodedPassword
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

function Assert-Capture {
  param(
    [string]$Name,
    [string]$Path,
    [string]$ExpectedTool,
    [string]$ExpectedPassword,
    [string]$ForbiddenText,
    [string[]]$RequiredArgs
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Write-Host ("[FAIL] {0} did not execute fake tool" -f $Name)
    exit 1
  }

  $captureText = Get-Content -LiteralPath $Path -Raw
  $capture = $captureText | ConvertFrom-Json

  if ($capture.Tool -ne $ExpectedTool) {
    Write-Host ("[FAIL] {0} executed {1}, expected {2}" -f $Name, $capture.Tool, $ExpectedTool)
    exit 1
  }
  if ($capture.PgPassword -ne $ExpectedPassword) {
    Write-Host ("[FAIL] {0} did not pass the DATABASE_URL password through PGPASSWORD" -f $Name)
    exit 1
  }

  $argsText = (@($capture.Args) -join "`n")
  Assert-NotContainsText "$Name captured args" $argsText $ExpectedPassword
  Assert-NotContainsText "$Name captured args" $argsText $ForbiddenText

  foreach ($required in $RequiredArgs) {
    if (@($capture.Args) -notcontains $required) {
      Write-Host ("[FAIL] {0} missing captured arg: {1}" -f $Name, $required)
      exit 1
    }
  }
}

function New-TestTempRoot {
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ("fubox-db-script-test-" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $root -Force | Out-Null
  return (Resolve-Path $root).Path
}

function Remove-TestTempRoot {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
    return
  }

  $trimChars = [char[]]@("\", "/")
  $resolvedPath = [System.IO.Path]::GetFullPath($Path).TrimEnd($trimChars)
  $resolvedTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd($trimChars)
  $tempPrefix = $resolvedTemp + [System.IO.Path]::DirectorySeparatorChar
  if (-not $resolvedPath.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove temp root outside system temp: $resolvedPath"
  }

  Remove-Item -LiteralPath $resolvedPath -Recurse -Force
}

function New-FakePostgresTool {
  param(
    [string]$Directory,
    [string]$Name
  )

  $path = Join-Path $Directory "$Name.ps1"
  $source = @'
#requires -Version 5.1
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$RemainingArguments
)

$capturePath = $env:FUBOX_DB_TEST_CAPTURE
if ([string]::IsNullOrWhiteSpace($capturePath)) {
  Write-Host "FUBOX_DB_TEST_CAPTURE is required"
  exit 90
}

$parent = Split-Path -Parent $capturePath
if (-not [string]::IsNullOrWhiteSpace($parent)) {
  New-Item -ItemType Directory -Path $parent -Force | Out-Null
}

$record = [ordered]@{
  Tool = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)
  Args = @($RemainingArguments)
  PgPassword = $env:PGPASSWORD
}

$record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $capturePath -Encoding UTF8
exit 0
'@
  Set-Content -LiteralPath $path -Value $source -Encoding ASCII
}

if (-not (Test-Path -LiteralPath $script:BackupScript -PathType Leaf)) {
  throw "Backup script not found: $script:BackupScript"
}
if (-not (Test-Path -LiteralPath $script:RestoreScript -PathType Leaf)) {
  throw "Restore script not found: $script:RestoreScript"
}

$tempRoot = New-TestTempRoot
try {
  $toolsDir = Join-Path $tempRoot "tools"
  $emptyPathDir = Join-Path $tempRoot "empty-path"
  $captureDir = Join-Path $tempRoot "captures"
  New-Item -ItemType Directory -Path $toolsDir, $emptyPathDir, $captureDir -Force | Out-Null
  New-FakePostgresTool $toolsDir "pg_dump"
  New-FakePostgresTool $toolsDir "pg_restore"

  $databaseUrl = "postgresql://fubox:$($script:EncodedPassword)@db.example.test:6543/fubox_contract?sslmode=require"
  $baseEnv = @{
    DATABASE_URL = $databaseUrl
  }

  $backupDryRunPath = Join-Path $tempRoot "dry-run-output\postgres.dump"
  $backupMissingTool = Invoke-DbScript $script:BackupScript @(
    "-DryRun",
    "-OutputPath",
    $backupDryRunPath
  ) ($baseEnv + @{ PATH = $emptyPathDir })
  Assert-ExitCode "backup dry-run without pg_dump" $backupMissingTool 0
  Assert-Contains "backup dry-run without pg_dump" $backupMissingTool "Mode: dry-run"
  Assert-Contains "backup dry-run without pg_dump" $backupMissingTool "WARNING: pg_dump was not found in PATH"
  Assert-Contains "backup dry-run without pg_dump" $backupMissingTool "****"
  Assert-OutputDoesNotLeakSecret "backup dry-run without pg_dump" $backupMissingTool
  Assert-PathMissing "backup dry-run without pg_dump" $backupDryRunPath

  $existingOutput = Join-Path $tempRoot "existing\postgres.dump"
  New-Item -ItemType Directory -Path (Split-Path -Parent $existingOutput) -Force | Out-Null
  Set-Content -LiteralPath $existingOutput -Value "existing" -Encoding ASCII

  $backupOverwriteBlocked = Invoke-DbScript $script:BackupScript @(
    "-DryRun",
    "-OutputPath",
    $existingOutput
  ) ($baseEnv + @{ PATH = $toolsDir })
  Assert-ExitCode "backup overwrite without Force" $backupOverwriteBlocked 1
  Assert-Contains "backup overwrite without Force" $backupOverwriteBlocked "OutputPath already exists"
  Assert-OutputDoesNotLeakSecret "backup overwrite without Force" $backupOverwriteBlocked

  $backupOverwriteAllowed = Invoke-DbScript $script:BackupScript @(
    "-DryRun",
    "-Force",
    "-OutputPath",
    $existingOutput
  ) ($baseEnv + @{ PATH = $toolsDir })
  Assert-ExitCode "backup overwrite with Force dry-run" $backupOverwriteAllowed 0
  Assert-Contains "backup overwrite with Force dry-run" $backupOverwriteAllowed "Backup check complete."
  Assert-OutputDoesNotLeakSecret "backup overwrite with Force dry-run" $backupOverwriteAllowed
  if (-not (Test-Path -LiteralPath $existingOutput -PathType Leaf)) {
    Write-Host "[FAIL] backup dry-run with Force deleted the existing output"
    exit 1
  }

  $backupCapture = Join-Path $captureDir "pg_dump.json"
  $backupExecOutput = Join-Path $tempRoot "exec\postgres.dump"
  $backupExec = Invoke-DbScript $script:BackupScript @(
    "-OutputPath",
    $backupExecOutput
  ) ($baseEnv + @{ PATH = $toolsDir; FUBOX_DB_TEST_CAPTURE = $backupCapture })
  Assert-ExitCode "backup DATABASE_URL execution with fake pg_dump" $backupExec 0
  Assert-Contains "backup DATABASE_URL execution with fake pg_dump" $backupExec "Running pg_dump"
  Assert-OutputDoesNotLeakSecret "backup DATABASE_URL execution with fake pg_dump" $backupExec
  Assert-Capture "backup DATABASE_URL execution with fake pg_dump" $backupCapture "pg_dump" $script:RawPassword $script:EncodedPassword @(
    "--format=custom",
    "--no-owner",
    "--file",
    $backupExecOutput
  )

  $restoreInput = Join-Path $tempRoot "input\postgres.dump"
  New-Item -ItemType Directory -Path (Split-Path -Parent $restoreInput) -Force | Out-Null
  Set-Content -LiteralPath $restoreInput -Value "not-a-real-dump" -Encoding ASCII

  $restoreMissingTool = Invoke-DbScript $script:RestoreScript @(
    "-InputPath",
    $restoreInput
  ) ($baseEnv + @{ PATH = $emptyPathDir })
  Assert-ExitCode "restore default dry-run without pg_restore" $restoreMissingTool 0
  Assert-Contains "restore default dry-run without pg_restore" $restoreMissingTool "Mode: dry-run"
  Assert-Contains "restore default dry-run without pg_restore" $restoreMissingTool "WARNING: pg_restore was not found in PATH"
  Assert-Contains "restore default dry-run without pg_restore" $restoreMissingTool "Restore check complete."
  Assert-OutputDoesNotLeakSecret "restore default dry-run without pg_restore" $restoreMissingTool

  $restoreNoForceCapture = Join-Path $captureDir "pg_restore-no-force.json"
  $restoreNoForce = Invoke-DbScript $script:RestoreScript @(
    "-InputPath",
    $restoreInput
  ) ($baseEnv + @{ PATH = $toolsDir; FUBOX_DB_TEST_CAPTURE = $restoreNoForceCapture })
  Assert-ExitCode "restore without Force" $restoreNoForce 0
  Assert-Contains "restore without Force" $restoreNoForce "Mode: dry-run"
  Assert-Contains "restore without Force" $restoreNoForce "Pass -Force to execute pg_restore"
  Assert-OutputDoesNotLeakSecret "restore without Force" $restoreNoForce
  Assert-PathMissing "restore without Force" $restoreNoForceCapture

  $restoreConflict = Invoke-DbScript $script:RestoreScript @(
    "-Force",
    "-DryRun",
    "-InputPath",
    $restoreInput
  ) ($baseEnv + @{ PATH = $toolsDir })
  Assert-ExitCode "restore Force DryRun conflict" $restoreConflict 1
  Assert-Contains "restore Force DryRun conflict" $restoreConflict "Do not combine"
  Assert-OutputDoesNotLeakSecret "restore Force DryRun conflict" $restoreConflict

  $restoreCapture = Join-Path $captureDir "pg_restore.json"
  $restoreExec = Invoke-DbScript $script:RestoreScript @(
    "-Force",
    "-InputPath",
    $restoreInput
  ) ($baseEnv + @{ PATH = $toolsDir; FUBOX_DB_TEST_CAPTURE = $restoreCapture })
  Assert-ExitCode "restore DATABASE_URL execution with fake pg_restore" $restoreExec 0
  Assert-Contains "restore DATABASE_URL execution with fake pg_restore" $restoreExec "Running pg_restore"
  Assert-OutputDoesNotLeakSecret "restore DATABASE_URL execution with fake pg_restore" $restoreExec
  Assert-Capture "restore DATABASE_URL execution with fake pg_restore" $restoreCapture "pg_restore" $script:RawPassword $script:EncodedPassword @(
    "--single-transaction",
    "--exit-on-error",
    "--no-owner",
    "--no-acl",
    $restoreInput
  )

  $missingRestoreInput = Join-Path $tempRoot "missing\postgres.dump"
  $restoreMissingInput = Invoke-DbScript $script:RestoreScript @(
    "-InputPath",
    $missingRestoreInput
  ) ($baseEnv + @{ PATH = $toolsDir })
  Assert-ExitCode "restore default dry-run missing input" $restoreMissingInput 0
  Assert-Contains "restore default dry-run missing input" $restoreMissingInput "Input dump file was not found"
  Assert-Contains "restore default dry-run missing input" $restoreMissingInput "Restore check complete."
  Assert-OutputDoesNotLeakSecret "restore default dry-run missing input" $restoreMissingInput

  Write-Host "[OK] backup/restore script contract tests passed"
} finally {
  Remove-TestTempRoot $tempRoot
}
