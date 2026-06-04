#requires -Version 5.1
[CmdletBinding()]
param(
  [string[]]$Checks = @("all"),

  [switch]$RunRuntimeSmoke,
  [switch]$OnlineSecurity,
  [switch]$TreatWarningsAsFailures,
  [string]$SummaryPath = ""
)

$ErrorActionPreference = "Stop"

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:AllowedChecks = @("format", "test", "frontend", "build", "security", "backup", "helm", "smoke")

function Get-UtcNowText {
  return (Get-Date).ToUniversalTime().ToString("o")
}

function Protect-Text {
  param([string]$Text)

  if ([string]::IsNullOrEmpty($Text)) {
    return $Text
  }

  $redacted = $Text
  $redacted = $redacted -replace '(?i)(authorization\s*[:=]\s*bearer\s+)[^\s"'';]+', '$1[REDACTED]'
  $redacted = $redacted -replace '(?i)((?:token|password|passwd|secret|api[_-]?key|access[_-]?key|private[_-]?key|pgpassword)\s*[:=]\s*)[^\s"'';]+', '$1[REDACTED]'
  $redacted = $redacted -replace '(?i)(Bearer\s+)[A-Za-z0-9._~+/\-]+=*', '$1[REDACTED]'
  $redacted = $redacted -replace '(?i)(://[^:/@\s]+:)[^@\s]+(@)', '$1[REDACTED]$2'
  $redacted = $redacted -replace 'sk-[A-Za-z0-9]{8,}', 'sk-[REDACTED]'
  $redacted = $redacted -replace '(?i)(BEGIN [A-Z0-9 ]*PRIVATE KEY)[\s\S]*(END [A-Z0-9 ]*PRIVATE KEY)', '$1 [REDACTED] $2'
  return $redacted
}

function Get-RepoRelativePath {
  param([Parameter(Mandatory = $true)][string]$Path)

  $trimChars = [char[]]@("\", "/")
  $root = [System.IO.Path]::GetFullPath($script:RepoRoot).TrimEnd($trimChars)
  $target = [System.IO.Path]::GetFullPath($Path)
  if ([string]::Equals($target, $root, [System.StringComparison]::OrdinalIgnoreCase)) {
    return "."
  }

  $rootWithSeparator = $root + [System.IO.Path]::DirectorySeparatorChar
  if ($target.StartsWith($rootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
    return ($target.Substring($rootWithSeparator.Length) -replace "\\", "/")
  }

  return ($target -replace "\\", "/")
}

function Get-SafeLines {
  param(
    [object[]]$Output,
    [int]$MaxLines = 30
  )

  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($entry in @($Output)) {
    if ($null -eq $entry) {
      continue
    }

    $safe = Protect-Text ([string]$entry.ToString())
    foreach ($line in @($safe -split '\r?\n')) {
      if ([string]::IsNullOrWhiteSpace($line)) {
        continue
      }

      $trimmed = $line.TrimEnd()
      if ($trimmed.Length -gt 800) {
        $trimmed = $trimmed.Substring(0, 800) + "..."
      }
      [void]$lines.Add($trimmed)
    }
  }

  if ($lines.Count -gt $MaxLines) {
    return @($lines.ToArray() | Select-Object -Last $MaxLines)
  }

  return @($lines.ToArray())
}

function Get-WarningLines {
  param([object[]]$Output)

  $warnings = New-Object System.Collections.Generic.List[string]
  foreach ($line in @(Get-SafeLines -Output $Output -MaxLines 5000)) {
    if ($line -cmatch '\[WARN\]' -or $line -cmatch 'WARNING:') {
      [void]$warnings.Add($line)
    }
  }

  return @($warnings.ToArray() | Select-Object -First 20)
}

function Format-CommandText {
  param(
    [Parameter(Mandatory = $true)][string]$Command,
    [string[]]$Arguments = @()
  )

  $parts = New-Object System.Collections.Generic.List[string]
  [void]$parts.Add($Command)
  foreach ($argument in @($Arguments)) {
    if ($argument -match '\s') {
      [void]$parts.Add(('"{0}"' -f ($argument -replace '"', '\"')))
    } else {
      [void]$parts.Add($argument)
    }
  }

  return Protect-Text ($parts.ToArray() -join " ")
}

function Get-PowerShellExecutable {
  $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
  if ($pwsh) {
    return $pwsh.Source
  }

  $powershell = Get-Command powershell -ErrorAction SilentlyContinue
  if ($powershell) {
    return $powershell.Source
  }

  return ""
}

function Test-ToolAvailable {
  param([Parameter(Mandatory = $true)][string]$Name)

  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-DockerAvailable {
  if (Get-Command docker -ErrorAction SilentlyContinue) {
    return $true
  }

  $defaultDocker = "C:\Program Files\Docker\Docker\resources\bin\docker.exe"
  return (Test-Path -LiteralPath $defaultDocker)
}

function Invoke-GateCommand {
  param(
    [Parameter(Mandatory = $true)][string]$FileName,
    [string[]]$Arguments = @(),
    [Parameter(Mandatory = $true)][string]$DisplayCommand,
    [string]$WorkingDirectory = $script:RepoRoot
  )

  $started = Get-Date
  $output = @()
  $exitCode = 0

  Push-Location $WorkingDirectory
  try {
    $global:LASTEXITCODE = 0
    $output = @(& $FileName @Arguments 2>&1 6>&1)
    $exitCode = $global:LASTEXITCODE
    if ($null -eq $exitCode) {
      $exitCode = 0
    }
  } catch {
    $output = @($_.Exception.Message)
    $exitCode = 127
  } finally {
    Pop-Location
  }

  $ended = Get-Date
  return [ordered]@{
    command = Protect-Text $DisplayCommand
    exitCode = [int]$exitCode
    startedAt = $started.ToUniversalTime().ToString("o")
    endedAt = $ended.ToUniversalTime().ToString("o")
    durationMs = [int][Math]::Round(($ended - $started).TotalMilliseconds)
    warnings = @(Get-WarningLines -Output $output)
    outputTail = @(Get-SafeLines -Output $output -MaxLines 25)
  }
}

function Invoke-RepoScript {
  param(
    [Parameter(Mandatory = $true)][string]$RelativePath,
    [string[]]$Arguments = @()
  )

  $ps = Get-PowerShellExecutable
  if ([string]::IsNullOrWhiteSpace($ps)) {
    $started = Get-Date
    return [ordered]@{
      command = Format-CommandText -Command $RelativePath -Arguments $Arguments
      exitCode = 127
      startedAt = $started.ToUniversalTime().ToString("o")
      endedAt = $started.ToUniversalTime().ToString("o")
      durationMs = 0
      warnings = @()
      outputTail = @("PowerShell executable was not found.")
    }
  }

  $scriptPath = Join-Path $script:RepoRoot $RelativePath
  $psArgs = @("-NoProfile")
  if ((Split-Path -Leaf $ps) -match '(?i)^powershell(\.exe)?$') {
    $psArgs += @("-ExecutionPolicy", "Bypass")
  }
  $psArgs += @("-File", $scriptPath)
  $psArgs += $Arguments

  return Invoke-GateCommand `
    -FileName $ps `
    -Arguments $psArgs `
    -DisplayCommand (Format-CommandText -Command $RelativePath -Arguments $Arguments) `
    -WorkingDirectory $script:RepoRoot
}

function New-CheckResult {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Title,
    [Parameter(Mandatory = $true)][bool]$Required,
    [Parameter(Mandatory = $true)][string]$Status,
    [object[]]$Commands = @(),
    [string[]]$Warnings = @(),
    [string[]]$Notes = @(),
    [datetime]$StartedAt = (Get-Date)
  )

  $ended = Get-Date
  return [ordered]@{
    id = $Id
    title = $Title
    required = $Required
    status = $Status
    startedAt = $StartedAt.ToUniversalTime().ToString("o")
    endedAt = $ended.ToUniversalTime().ToString("o")
    durationMs = [int][Math]::Round(($ended - $StartedAt).TotalMilliseconds)
    warnings = @($Warnings)
    notes = @($Notes)
    commands = @($Commands)
  }
}

function New-CommandsCheckResult {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Title,
    [Parameter(Mandatory = $true)][bool]$Required,
    [object[]]$Commands = @(),
    [string[]]$Warnings = @(),
    [string[]]$Notes = @(),
    [datetime]$StartedAt = (Get-Date)
  )

  $allWarnings = New-Object System.Collections.Generic.List[string]
  foreach ($warning in @($Warnings)) {
    [void]$allWarnings.Add($warning)
  }
  foreach ($command in @($Commands)) {
    foreach ($warning in @($command.warnings)) {
      [void]$allWarnings.Add($warning)
    }
  }

  $failed = @($Commands | Where-Object { [int]$_.exitCode -ne 0 })
  $status = "pass"
  if ($failed.Count -gt 0) {
    $status = "fail"
  } elseif ($allWarnings.Count -gt 0) {
    $status = "warn"
  }

  return New-CheckResult `
    -Id $Id `
    -Title $Title `
    -Required $Required `
    -Status $status `
    -Commands $Commands `
    -Warnings @($allWarnings.ToArray()) `
    -Notes $Notes `
    -StartedAt $StartedAt
}

function New-MissingToolResult {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Title,
    [Parameter(Mandatory = $true)][bool]$Required,
    [Parameter(Mandatory = $true)][string]$ToolName,
    [Parameter(Mandatory = $true)][string]$Message,
    [switch]$Skip
  )

  $status = "fail"
  if ($Skip) {
    $status = "skip"
  }

  return New-CheckResult `
    -Id $Id `
    -Title $Title `
    -Required $Required `
    -Status $status `
    -Warnings @($Message) `
    -Notes @("missing tool: $ToolName")
}

function Resolve-RequestedChecks {
  $normalized = New-Object System.Collections.Generic.List[string]
  foreach ($rawCheck in @($Checks)) {
    foreach ($part in @(([string]$rawCheck) -split ",")) {
      $trimmed = $part.Trim().ToLowerInvariant()
      if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
        [void]$normalized.Add($trimmed)
      }
    }
  }

  if ($normalized.Count -eq 0) {
    [void]$normalized.Add("all")
  }

  $allowed = @("all") + @($script:AllowedChecks)
  $invalid = @($normalized.ToArray() | Where-Object { $allowed -notcontains $_ })
  if ($invalid.Count -gt 0) {
    throw ("Invalid -Checks value(s): {0}. Allowed values: {1}" -f (($invalid | Select-Object -Unique) -join ", "), ($allowed -join ", "))
  }

  if ($normalized.Contains("all")) {
    return @($script:AllowedChecks)
  }

  $requested = New-Object System.Collections.Generic.List[string]
  foreach ($check in $script:AllowedChecks) {
    if ($normalized.Contains($check)) {
      [void]$requested.Add($check)
    }
  }
  return @($requested.ToArray())
}

function Test-BackupConfigurationAvailable {
  if (-not [string]::IsNullOrWhiteSpace($env:DATABASE_URL)) {
    return $true
  }
  if (-not [string]::IsNullOrWhiteSpace($env:POSTGRES_URL)) {
    return $true
  }

  return (
    -not [string]::IsNullOrWhiteSpace($env:PGHOST) -and
    -not [string]::IsNullOrWhiteSpace($env:PGDATABASE) -and
    -not [string]::IsNullOrWhiteSpace($env:PGUSER)
  )
}

function Invoke-FormatCheck {
  $started = Get-Date
  if (-not (Test-ToolAvailable "cargo")) {
    return New-MissingToolResult -Id "format" -Title "Rust format check" -Required $true -ToolName "cargo" -Message "cargo not found; cannot run cargo fmt --check."
  }

  $commands = @(
    Invoke-RepoScript -RelativePath "scripts/fmt.ps1" -Arguments @("-Check")
  )
  return New-CommandsCheckResult -Id "format" -Title "Rust format check" -Required $true -Commands $commands -StartedAt $started
}

function Invoke-TestCheck {
  $started = Get-Date
  if (-not (Test-ToolAvailable "cargo")) {
    return New-MissingToolResult -Id "test" -Title "Rust workspace tests" -Required $true -ToolName "cargo" -Message "cargo not found; cannot run workspace tests."
  }

  $commands = @(
    Invoke-GateCommand `
      -FileName "cargo" `
      -Arguments @("test", "--workspace", "--all-targets", "--all-features") `
      -DisplayCommand "cargo test --workspace --all-targets --all-features"
  )
  return New-CommandsCheckResult -Id "test" -Title "Rust workspace tests" -Required $true -Commands $commands -StartedAt $started
}

function Invoke-FrontendCheck {
  $started = Get-Date
  if (-not (Test-ToolAvailable "node")) {
    return New-MissingToolResult -Id "frontend" -Title "Admin UI tests and typecheck" -Required $true -ToolName "node" -Message "node not found; cannot run frontend checks."
  }
  if (-not (Test-ToolAvailable "npm")) {
    return New-MissingToolResult -Id "frontend" -Title "Admin UI tests and typecheck" -Required $true -ToolName "npm" -Message "npm not found; cannot run frontend checks."
  }

  $commands = @(
    (Invoke-GateCommand -FileName "npm" -Arguments @("--prefix", "web/admin-ui", "run", "typecheck") -DisplayCommand "npm --prefix web/admin-ui run typecheck"),
    (Invoke-GateCommand -FileName "npm" -Arguments @("--prefix", "web/admin-ui", "test") -DisplayCommand "npm --prefix web/admin-ui test")
  )
  return New-CommandsCheckResult -Id "frontend" -Title "Admin UI tests and typecheck" -Required $true -Commands $commands -StartedAt $started
}

function Invoke-BuildCheck {
  $started = Get-Date
  if (-not (Test-ToolAvailable "cargo")) {
    return New-MissingToolResult -Id "build" -Title "Workspace and Admin UI build" -Required $true -ToolName "cargo" -Message "cargo not found; cannot build Rust workspace."
  }
  if (-not (Test-ToolAvailable "node")) {
    return New-MissingToolResult -Id "build" -Title "Workspace and Admin UI build" -Required $true -ToolName "node" -Message "node not found; cannot build Admin UI."
  }
  if (-not (Test-ToolAvailable "npm")) {
    return New-MissingToolResult -Id "build" -Title "Workspace and Admin UI build" -Required $true -ToolName "npm" -Message "npm not found; cannot build Admin UI."
  }

  $commands = @(
    (Invoke-GateCommand -FileName "cargo" -Arguments @("build", "--workspace", "--all-targets", "--all-features") -DisplayCommand "cargo build --workspace --all-targets --all-features"),
    (Invoke-GateCommand -FileName "npm" -Arguments @("--prefix", "web/admin-ui", "run", "build") -DisplayCommand "npm --prefix web/admin-ui run build"),
    (Invoke-GateCommand -FileName "npm" -Arguments @("--prefix", "web/admin-ui", "run", "check:bundle") -DisplayCommand "npm --prefix web/admin-ui run check:bundle")
  )
  return New-CommandsCheckResult -Id "build" -Title "Workspace and Admin UI build" -Required $true -Commands $commands -StartedAt $started
}

function Invoke-SecurityCheck {
  $started = Get-Date
  $supplyChainArgs = @()
  $notes = @()
  if ($OnlineSecurity) {
    $notes += "network-backed cargo audit, npm audit, and container scanner probes are enabled when tools are available."
  } else {
    $supplyChainArgs += "-SkipNetwork"
    $notes += "network-backed vulnerability audits are disabled by default; pass -OnlineSecurity for release-candidate audit runs."
  }
  $notes += "supply-chain artifact generation is part of the security gate and writes SBOM/provenance/manifest/checksum files under artifacts/supply-chain."

  $commands = @(
    (Invoke-RepoScript -RelativePath "scripts/scan_secrets.ps1"),
    (Invoke-RepoScript -RelativePath "scripts/scan_supply_chain.ps1" -Arguments $supplyChainArgs),
    (Invoke-RepoScript -RelativePath "scripts/generate_supply_chain_artifacts.ps1" -Arguments @("-OutputDirectory", "artifacts/supply-chain"))
  )
  return New-CommandsCheckResult -Id "security" -Title "Secret scan, supply-chain scan, and artifact generation" -Required $true -Commands $commands -Notes $notes -StartedAt $started
}

function Invoke-BackupCheck {
  $started = Get-Date
  $warnings = New-Object System.Collections.Generic.List[string]
  $notes = New-Object System.Collections.Generic.List[string]
  $commands = New-Object System.Collections.Generic.List[object]

  [void]$commands.Add((Invoke-RepoScript -RelativePath "scripts/db/verify_backup_restore_contract.ps1"))
  [void]$notes.Add("backup/restore contract self-test is always run and does not execute pg_dump or pg_restore.")

  if (-not (Test-BackupConfigurationAvailable)) {
    [void]$warnings.Add("local warning: database connection parameters are not configured; backup execution preflight skipped. Set DATABASE_URL/POSTGRES_URL or PGHOST+PGDATABASE+PGUSER to run preflight without printing secret values.")
    [void]$notes.Add("backup preflight skipped; contract self-test still validates dry-run/restore safety semantics.")
    return New-CommandsCheckResult `
      -Id "backup" `
      -Title "PostgreSQL backup preflight" `
      -Required $false `
      -Commands @($commands.ToArray()) `
      -Warnings @($warnings.ToArray()) `
      -Notes @($notes.ToArray()) `
      -StartedAt $started
  }

  if (-not (Test-ToolAvailable "pg_dump")) {
    [void]$warnings.Add("local warning: pg_dump not found; backup execution preflight skipped on this machine. Rerun in an environment with pg_dump before release approval.")
    [void]$notes.Add("missing tool: pg_dump")
    return New-CommandsCheckResult `
      -Id "backup" `
      -Title "PostgreSQL backup preflight" `
      -Required $false `
      -Commands @($commands.ToArray()) `
      -Warnings @($warnings.ToArray()) `
      -Notes @($notes.ToArray()) `
      -StartedAt $started
  }

  $outputPath = Join-Path $script:RepoRoot "backups\db\release-gate-preflight.dump"
  [void]$commands.Add((Invoke-RepoScript -RelativePath "scripts/db/backup.ps1" -Arguments @("-Preflight", "-OutputPath", $outputPath)))
  [void]$notes.Add("backup gate uses -Preflight; no directories are created and pg_dump is not executed.")
  return New-CommandsCheckResult `
    -Id "backup" `
    -Title "PostgreSQL backup preflight" `
    -Required $false `
    -Commands @($commands.ToArray()) `
    -Warnings @($warnings.ToArray()) `
    -Notes @($notes.ToArray()) `
    -StartedAt $started
}

function Invoke-HelmCheck {
  $started = Get-Date
  $chartPath = Join-Path $script:RepoRoot "deploy\helm"
  if (-not (Test-Path -LiteralPath $chartPath -PathType Container)) {
    return New-CheckResult -Id "helm" -Title "Helm chart validation" -Required $false -Status "fail" -Warnings @("deploy/helm chart directory was not found.")
  }

  $warnings = New-Object System.Collections.Generic.List[string]
  $commands = New-Object System.Collections.Generic.List[object]

  if (Test-ToolAvailable "python") {
    [void]$commands.Add((Invoke-GateCommand -FileName "python" -Arguments @("deploy/helm/validate_chart.py", "--skip-helm", "--self-test") -DisplayCommand "python deploy/helm/validate_chart.py --skip-helm --self-test"))
  } else {
    [void]$warnings.Add("local warning: python not found; static Helm chart validation and contract self-test skipped on this machine.")
  }

  if (Test-ToolAvailable "helm") {
    [void]$commands.Add((Invoke-GateCommand -FileName "helm" -Arguments @("lint", "deploy/helm") -DisplayCommand "helm lint deploy/helm"))
    [void]$commands.Add((Invoke-GateCommand -FileName "helm" -Arguments @("template", "fubox", "deploy/helm") -DisplayCommand "helm template fubox deploy/helm"))
  } else {
    [void]$warnings.Add("local warning: helm not found; chart lint/template checks skipped on this machine. Static chart validation and contract self-test still run when python is available; rerun with Helm before staging or release approval.")
  }

  if ($commands.Count -eq 0) {
    return New-CheckResult `
      -Id "helm" `
      -Title "Helm chart validation" `
      -Required $false `
      -Status "skip" `
      -Warnings @($warnings.ToArray()) `
      -StartedAt $started
  }

  return New-CommandsCheckResult `
    -Id "helm" `
    -Title "Helm chart validation" `
    -Required $false `
    -Commands @($commands.ToArray()) `
    -Warnings @($warnings.ToArray()) `
    -StartedAt $started
}

function Invoke-SmokeCheck {
  $started = Get-Date
  $warnings = New-Object System.Collections.Generic.List[string]
  $commands = New-Object System.Collections.Generic.List[object]

  [void]$commands.Add((Invoke-RepoScript -RelativePath "scripts/verify_compose_smoke.ps1" -Arguments @("-DryRun")))
  [void]$commands.Add((Invoke-RepoScript -RelativePath "scripts/verify_gateway_rate_limit_reservation_smoke.ps1" -Arguments @("-DryRun")))

  $missingSdkTools = New-Object System.Collections.Generic.List[string]
  if (-not (Test-ToolAvailable "node")) {
    [void]$missingSdkTools.Add("node")
  }
  if (-not (Test-ToolAvailable "npm")) {
    [void]$missingSdkTools.Add("npm")
  }

  $notes = @("smoke gate always runs compose and gateway rate-limit reservation dry-run checks; SDK dry-run runs when node and npm are available.")
  if ($RunRuntimeSmoke) {
    $notes += "runtime smoke was requested explicitly."
  }

  if ($missingSdkTools.Count -gt 0) {
    $missingText = ($missingSdkTools.ToArray() -join "/")
    if ($RunRuntimeSmoke) {
      return New-CheckResult `
        -Id "smoke" `
        -Title "Smoke contracts" `
        -Required $true `
        -Status "fail" `
        -Commands @($commands.ToArray()) `
        -Warnings @("explicit runtime smoke request failed: $missingText not found; SDK smoke cannot run on this machine.") `
        -Notes $notes
    }

    [void]$warnings.Add("local warning: $missingText not found; SDK smoke dry-run skipped on this machine. Rerun with node and npm before release approval.")
  } else {
    [void]$commands.Add((Invoke-RepoScript -RelativePath "scripts/verify_sdk_smoke.ps1" -Arguments @("-DryRun", "-SkipInstall")))
  }

  $dockerAvailable = Test-DockerAvailable
  if (-not $dockerAvailable) {
    if ($RunRuntimeSmoke) {
      return New-CheckResult `
        -Id "smoke" `
        -Title "Smoke contracts" `
        -Required $true `
        -Status "fail" `
        -Commands @($commands.ToArray()) `
        -Warnings @("explicit runtime smoke request failed: docker not found; runtime compose smoke cannot run on this machine.") `
        -Notes $notes
    }

    [void]$warnings.Add("local warning: docker not found; runtime compose smoke skipped. Default smoke gate remains dry-run only.")
  } elseif ($RunRuntimeSmoke) {
    [void]$commands.Add((Invoke-RepoScript -RelativePath "scripts/verify_compose_smoke.ps1"))
    [void]$commands.Add((Invoke-RepoScript -RelativePath "scripts/verify_gateway_rate_limit_reservation_smoke.ps1"))
    [void]$commands.Add((Invoke-RepoScript -RelativePath "scripts/verify_sdk_smoke.ps1" -Arguments @("-SkipInstall", "-AllowStreamingSkip")))
  }

  $notes += "pass -RunRuntimeSmoke only after the local compose stack is up; gateway rate-limit reservation live smoke also requires seeded Postgres, Gateway, and mock-provider."

  return New-CommandsCheckResult `
    -Id "smoke" `
    -Title "Smoke contracts" `
    -Required $true `
    -Commands @($commands.ToArray()) `
    -Warnings @($warnings.ToArray()) `
    -Notes $notes `
    -StartedAt $started
}

$requestedChecks = Resolve-RequestedChecks
$results = New-Object System.Collections.Generic.List[object]

foreach ($check in $requestedChecks) {
  switch ($check) {
    "format" { [void]$results.Add((Invoke-FormatCheck)) }
    "test" { [void]$results.Add((Invoke-TestCheck)) }
    "frontend" { [void]$results.Add((Invoke-FrontendCheck)) }
    "build" { [void]$results.Add((Invoke-BuildCheck)) }
    "security" { [void]$results.Add((Invoke-SecurityCheck)) }
    "backup" { [void]$results.Add((Invoke-BackupCheck)) }
    "helm" { [void]$results.Add((Invoke-HelmCheck)) }
    "smoke" { [void]$results.Add((Invoke-SmokeCheck)) }
  }
}

$counts = [ordered]@{
  pass = 0
  warn = 0
  skip = 0
  fail = 0
}

foreach ($result in @($results.ToArray())) {
  $status = [string]$result.status
  if (-not $counts.Contains($status)) {
    $counts[$status] = 0
  }
  $counts[$status] = [int]$counts[$status] + 1
}

$overallStatus = "pass"
if ([int]$counts.fail -gt 0) {
  $overallStatus = "fail"
} elseif ($TreatWarningsAsFailures -and (([int]$counts.warn + [int]$counts.skip) -gt 0)) {
  $overallStatus = "fail"
} elseif ((([int]$counts.warn + [int]$counts.skip) -gt 0)) {
  $overallStatus = "warn"
}

$summary = [ordered]@{
  schemaVersion = "release-gate.v1"
  generatedAt = Get-UtcNowText
  repoRoot = Get-RepoRelativePath $script:RepoRoot
  statusPolicy = [ordered]@{
    pass = "all selected checks completed without warnings or skips."
    warn = "no selected check failed, but one or more checks emitted warnings or skips, including local missing-tool warnings."
    fail = "one or more selected checks failed, or warnings/skips were promoted by -TreatWarningsAsFailures."
    localMissingToolWarnings = "missing Docker, Helm, pg_dump, node, or npm is a warning in default dry-run/preflight gates unless an explicit runtime action requiring that tool was requested."
  }
  mode = [ordered]@{
    destructiveActionsAllowed = $false
    backup = "preflight"
    smoke = $(if ($RunRuntimeSmoke) { "dry-run+runtime" } else { "dry-run" })
    securityNetwork = [bool]$OnlineSecurity
    warningsAreFailures = [bool]$TreatWarningsAsFailures
  }
  requestedChecks = @($requestedChecks)
  overallStatus = $overallStatus
  counts = $counts
  checks = @($results.ToArray())
}

$json = $summary | ConvertTo-Json -Depth 12

if (-not [string]::IsNullOrWhiteSpace($SummaryPath)) {
  $resolvedSummaryPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SummaryPath)
  $summaryParent = Split-Path -Parent $resolvedSummaryPath
  if (-not [string]::IsNullOrWhiteSpace($summaryParent) -and -not (Test-Path -LiteralPath $summaryParent)) {
    New-Item -ItemType Directory -Path $summaryParent -Force | Out-Null
  }
  Set-Content -LiteralPath $resolvedSummaryPath -Encoding UTF8 -Value $json
}

Write-Output $json

if ($overallStatus -eq "fail") {
  exit 1
}

exit 0
