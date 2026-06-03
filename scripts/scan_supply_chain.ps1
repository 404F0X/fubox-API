#requires -Version 5.1
[CmdletBinding()]
param(
  [switch]$Offline,
  [switch]$SkipNetwork
)

$ErrorActionPreference = "Stop"

$script:NetworkEnabled = -not ($Offline -or $SkipNetwork)
$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:Failures = New-Object System.Collections.Generic.List[string]
$script:CheckCount = 0
$script:ContainerImageCount = 0
$script:ContainerDigestPinnedCount = 0
$script:ExcludedDirectoryNames = @(".git", "target", "node_modules", "dist", "dev_starter_unpacked", ".docx_unpacked")

$scriptPath = $PSCommandPath
if (-not $scriptPath) {
  $scriptPath = $MyInvocation.MyCommand.Path
}
$script:RepoRoot = (Resolve-Path (Join-Path (Split-Path -Parent $scriptPath) "..")).Path

function Write-Ok {
  param([Parameter(Mandatory = $true)][string]$Message)
  $script:CheckCount += 1
  Write-Host "[OK] $Message"
}

function Write-Warn {
  param([Parameter(Mandatory = $true)][string]$Message)
  [void]$script:Warnings.Add($Message)
  Write-Host "[WARN] $Message"
}

function Write-Fail {
  param([Parameter(Mandatory = $true)][string]$Message)
  [void]$script:Failures.Add($Message)
  Write-Host "[FAIL] $Message"
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

function Test-ExcludedDirectoryName {
  param([Parameter(Mandatory = $true)][string]$Name)

  foreach ($excluded in $script:ExcludedDirectoryNames) {
    if ([string]::Equals($Name, $excluded, [System.StringComparison]::OrdinalIgnoreCase)) {
      return $true
    }
  }

  return $false
}

function Get-RepositoryFiles {
  param([Parameter(Mandatory = $true)][string[]]$Names)

  $files = New-Object System.Collections.Generic.List[string]
  $stack = New-Object System.Collections.Generic.Stack[string]
  $stack.Push($script:RepoRoot)

  while ($stack.Count -gt 0) {
    $directory = $stack.Pop()
    try {
      $items = Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop
    } catch {
      Write-Warn ("unable to read directory: {0}" -f (Get-RepoRelativePath $directory))
      continue
    }

    foreach ($item in $items) {
      if ($item.PSIsContainer) {
        if (-not (Test-ExcludedDirectoryName $item.Name)) {
          $stack.Push($item.FullName)
        }
        continue
      }

      foreach ($name in $Names) {
        if ([string]::Equals($item.Name, $name, [System.StringComparison]::OrdinalIgnoreCase)) {
          [void]$files.Add($item.FullName)
          break
        }
      }
    }
  }

  return @($files.ToArray())
}

function Get-RepositoryFilesMatching {
  param([Parameter(Mandatory = $true)][string[]]$NamePatterns)

  $files = New-Object System.Collections.Generic.List[string]
  $stack = New-Object System.Collections.Generic.Stack[string]
  $stack.Push($script:RepoRoot)

  while ($stack.Count -gt 0) {
    $directory = $stack.Pop()
    try {
      $items = Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop
    } catch {
      Write-Warn ("unable to read directory: {0}" -f (Get-RepoRelativePath $directory))
      continue
    }

    foreach ($item in $items) {
      if ($item.PSIsContainer) {
        if (-not (Test-ExcludedDirectoryName $item.Name)) {
          $stack.Push($item.FullName)
        }
        continue
      }

      foreach ($pattern in $NamePatterns) {
        if ($item.Name -like $pattern) {
          [void]$files.Add($item.FullName)
          break
        }
      }
    }
  }

  return @($files.ToArray())
}

function Test-JsonProperty {
  param(
    [Parameter(Mandatory = $true)]$Object,
    [Parameter(Mandatory = $true)][string]$Name
  )

  return ($null -ne ($Object.PSObject.Properties | Where-Object { $_.Name -eq $Name } | Select-Object -First 1))
}

function Join-LimitedValues {
  param(
    [string[]]$Values,
    [int]$Limit = 5
  )

  $selected = @($Values | Select-Object -First $Limit)
  $text = ($selected -join ", ")
  if ($Values.Count -gt $Limit) {
    $text = $text + ", ..."
  }

  return $text
}

function Protect-LogText {
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

function Write-SafeTail {
  param(
    [string[]]$Lines,
    [int]$MaxLines = 25
  )

  foreach ($line in @($Lines | Select-Object -Last $MaxLines)) {
    $safeLine = Protect-LogText $line
    if ($safeLine.Length -gt 500) {
      $safeLine = $safeLine.Substring(0, 500) + "..."
    }
    if ($safeLine.Length -gt 0) {
      Write-Host ("    {0}" -f $safeLine)
    }
  }
}

function Invoke-External {
  param(
    [Parameter(Mandatory = $true)][string]$FileName,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$WorkingDirectory
  )

  Push-Location $WorkingDirectory
  try {
    $output = & $FileName @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) {
      $exitCode = 0
    }
  } catch {
    $output = @($_.Exception.Message)
    $exitCode = 127
  } finally {
    Pop-Location
  }

  return [pscustomobject]@{
    ExitCode = [int]$exitCode
    Output = @($output | ForEach-Object { $_.ToString() })
  }
}

function Test-CommandAvailable {
  param(
    [Parameter(Mandatory = $true)][string]$CommandName,
    [Parameter(Mandatory = $true)][string]$Purpose
  )

  $command = Get-Command $CommandName -ErrorAction SilentlyContinue
  if ($command) {
    Write-Ok ("command available: {0} ({1})" -f $CommandName, $Purpose)
    return $true
  }

  Write-Warn ("command not found: {0} ({1}); related checks will be skipped" -f $CommandName, $Purpose)
  return $false
}

function Test-CargoLock {
  param([Parameter(Mandatory = $true)][string]$LockPath)

  $relative = Get-RepoRelativePath $LockPath
  if (-not (Test-Path -LiteralPath $LockPath)) {
    Write-Fail ("missing Rust lockfile: {0}" -f $relative)
    return
  }

  $content = Get-Content -LiteralPath $LockPath -Raw
  if ([string]::IsNullOrWhiteSpace($content)) {
    Write-Fail ("Rust lockfile is empty: {0}" -f $relative)
    return
  }
  if ($content -notmatch '(?m)^\s*version\s*=\s*\d+\s*$') {
    Write-Fail ("Rust lockfile has no lockfile version: {0}" -f $relative)
    return
  }
  if ($content -notmatch '(?m)^\s*\[\[package\]\]\s*$') {
    Write-Fail ("Rust lockfile has no package entries: {0}" -f $relative)
    return
  }

  Write-Ok ("Rust lockfile structure valid: {0}" -f $relative)
}

function Get-CargoLockField {
  param(
    [Parameter(Mandatory = $true)][string]$Block,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $match = [regex]::Match($Block, ('(?m)^\s*{0}\s*=\s*"([^"]*)"\s*$' -f [regex]::Escape($Name)))
  if ($match.Success) {
    return [string]$match.Groups[1].Value
  }

  return ""
}

function Test-CargoLockProvenance {
  param([Parameter(Mandatory = $true)][string]$LockPath)

  $relative = Get-RepoRelativePath $LockPath
  $content = Get-Content -LiteralPath $LockPath -Raw
  $packageMatches = @([regex]::Matches($content, '(?ms)^\s*\[\[package\]\]\s*(.*?)(?=^\s*\[\[package\]\]\s*|\z)'))
  if ($packageMatches.Count -eq 0) {
    Write-Fail ("Cargo.lock has no package blocks to inspect for provenance: {0}" -f $relative)
    return
  }

  $registryCount = 0
  $gitCount = 0
  $localCount = 0
  $otherSourceCount = 0
  $missingChecksum = New-Object System.Collections.Generic.List[string]
  $invalidChecksum = New-Object System.Collections.Generic.List[string]
  $unpinnedGitSource = New-Object System.Collections.Generic.List[string]
  $otherUnchecksummedSource = New-Object System.Collections.Generic.List[string]

  foreach ($match in $packageMatches) {
    $block = [string]$match.Groups[1].Value
    $name = Get-CargoLockField -Block $block -Name "name"
    $source = Get-CargoLockField -Block $block -Name "source"
    $checksum = Get-CargoLockField -Block $block -Name "checksum"
    if ([string]::IsNullOrWhiteSpace($name)) {
      $name = "<unknown>"
    }

    if ([string]::IsNullOrWhiteSpace($source)) {
      $localCount += 1
      continue
    }

    if ($source.StartsWith("registry+", [System.StringComparison]::OrdinalIgnoreCase)) {
      $registryCount += 1
      if ([string]::IsNullOrWhiteSpace($checksum)) {
        [void]$missingChecksum.Add($name)
      } elseif ($checksum -notmatch '^[0-9a-fA-F]{64}$') {
        [void]$invalidChecksum.Add($name)
      }
      continue
    }

    if ($source.StartsWith("git+", [System.StringComparison]::OrdinalIgnoreCase)) {
      $gitCount += 1
      if ($source -notmatch '#[0-9a-fA-F]{7,40}$') {
        [void]$unpinnedGitSource.Add($name)
      }
      continue
    }

    $otherSourceCount += 1
    if ([string]::IsNullOrWhiteSpace($checksum)) {
      [void]$otherUnchecksummedSource.Add($name)
    }
  }

  if ($missingChecksum.Count -gt 0) {
    Write-Fail ("Cargo.lock registry packages missing checksum: {0} (count={1}; examples={2})" -f $relative, $missingChecksum.Count, (Join-LimitedValues $missingChecksum.ToArray()))
  }
  if ($invalidChecksum.Count -gt 0) {
    Write-Fail ("Cargo.lock registry packages have invalid checksum format: {0} (count={1}; examples={2})" -f $relative, $invalidChecksum.Count, (Join-LimitedValues $invalidChecksum.ToArray()))
  }
  if ($unpinnedGitSource.Count -gt 0) {
    Write-Fail ("Cargo.lock git packages are not pinned to a revision: {0} (count={1}; examples={2})" -f $relative, $unpinnedGitSource.Count, (Join-LimitedValues $unpinnedGitSource.ToArray()))
  }
  if ($otherUnchecksummedSource.Count -gt 0) {
    Write-Warn ("Cargo.lock packages use non-registry source without checksum: {0} (count={1}; examples={2})" -f $relative, $otherUnchecksummedSource.Count, (Join-LimitedValues $otherUnchecksummedSource.ToArray()))
  }

  if (($missingChecksum.Count + $invalidChecksum.Count + $unpinnedGitSource.Count) -eq 0) {
    Write-Ok ("Cargo.lock provenance fields valid: {0} (registry={1}, git={2}, local={3}, other={4})" -f $relative, $registryCount, $gitCount, $localCount, $otherSourceCount)
  }
}

function Test-NpmLockIntegrity {
  param([Parameter(Mandatory = $true)][string]$LockPath)

  $relative = Get-RepoRelativePath $LockPath
  if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Warn ("node not available; npm integrity coverage check skipped: {0}" -f $relative)
    return
  }

  $nodeScript = @'
const fs = require('fs');
const lockPath = process.argv[1];
const lock = JSON.parse(fs.readFileSync(lockPath, 'utf8'));
const findings = {
  missingResolved: [],
  missingIntegrity: [],
  invalidIntegrity: [],
};
let externalPackages = 0;
let localPackages = 0;

function isValidIntegrity(value) {
  return /^(sha512|sha384|sha256|sha1)-[A-Za-z0-9+\/=]+(\s+(sha512|sha384|sha256|sha1)-[A-Za-z0-9+\/=]+)*$/.test(value || '');
}

function checkEntry(entry, displayName) {
  if (!entry || entry.link === true) {
    return;
  }
  const resolved = String(entry.resolved || '');
  if (/^(file|link):/i.test(resolved)) {
    localPackages += 1;
    return;
  }
  externalPackages += 1;
  if (!resolved) {
    findings.missingResolved.push(displayName);
  }
  const integrity = String(entry.integrity || '');
  if (!integrity) {
    findings.missingIntegrity.push(displayName);
  } else if (!isValidIntegrity(integrity)) {
    findings.invalidIntegrity.push(displayName);
  }
}

function walkDependencies(dependencies, prefix) {
  for (const [name, entry] of Object.entries(dependencies || {})) {
    const displayName = prefix ? prefix + '>' + name : name;
    checkEntry(entry, displayName);
    if (entry && entry.dependencies) {
      walkDependencies(entry.dependencies, displayName);
    }
  }
}

if (lock.packages) {
  for (const [packagePath, entry] of Object.entries(lock.packages)) {
    if (!packagePath) {
      continue;
    }
    if (!/(^|\/)node_modules\//.test(packagePath)) {
      localPackages += 1;
      continue;
    }
    checkEntry(entry, packagePath);
  }
} else if (lock.dependencies) {
  walkDependencies(lock.dependencies, '');
}

process.stdout.write(JSON.stringify({
  externalPackages,
  localPackages,
  missingResolved: findings.missingResolved,
  missingIntegrity: findings.missingIntegrity,
  invalidIntegrity: findings.invalidIntegrity,
}));
'@

  $result = Invoke-External "node" @("-e", $nodeScript, $LockPath) $script:RepoRoot
  if ($result.ExitCode -ne 0) {
    Write-Fail ("npm lockfile integrity inspection failed: {0}" -f $relative)
    Write-SafeTail $result.Output
    return
  }

  try {
    $report = ($result.Output -join "`n") | ConvertFrom-Json -ErrorAction Stop
  } catch {
    Write-Warn ("npm lockfile integrity inspection produced unreadable summary: {0}" -f $relative)
    Write-SafeTail $result.Output
    return
  }

  $missingResolved = @($report.missingResolved)
  $missingIntegrity = @($report.missingIntegrity)
  $invalidIntegrity = @($report.invalidIntegrity)
  if ($missingResolved.Count -gt 0) {
    Write-Fail ("npm lockfile packages missing resolved source: {0} (count={1}; examples={2})" -f $relative, $missingResolved.Count, (Join-LimitedValues $missingResolved))
  }
  if ($missingIntegrity.Count -gt 0) {
    Write-Fail ("npm lockfile packages missing integrity: {0} (count={1}; examples={2})" -f $relative, $missingIntegrity.Count, (Join-LimitedValues $missingIntegrity))
  }
  if ($invalidIntegrity.Count -gt 0) {
    Write-Fail ("npm lockfile packages have invalid integrity format: {0} (count={1}; examples={2})" -f $relative, $invalidIntegrity.Count, (Join-LimitedValues $invalidIntegrity))
  }

  if (($missingResolved.Count + $missingIntegrity.Count + $invalidIntegrity.Count) -eq 0) {
    Write-Ok ("npm lockfile integrity coverage valid: {0} (external={1}, local={2})" -f $relative, $report.externalPackages, $report.localPackages)
  }
}

function Test-NpmLock {
  param([Parameter(Mandatory = $true)][string]$LockPath)

  $relative = Get-RepoRelativePath $LockPath
  $content = Get-Content -LiteralPath $LockPath -Raw

  if ([string]::IsNullOrWhiteSpace($content)) {
    Write-Fail ("npm lockfile is empty: {0}" -f $relative)
    return
  }

  if (Get-Command node -ErrorAction SilentlyContinue) {
    $nodeJsonCheck = Invoke-External "node" @("-e", "const fs=require('fs'); JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));", $LockPath) $script:RepoRoot
    if ($nodeJsonCheck.ExitCode -ne 0) {
      Write-Fail ("npm lockfile is not valid JSON: {0}" -f $relative)
      Write-SafeTail $nodeJsonCheck.Output
      return
    }
  } else {
    Write-Warn ("node not available; using structural npm lockfile checks only: {0}" -f $relative)
  }

  if ($content -notmatch '"lockfileVersion"\s*:\s*[0-9]+') {
    Write-Fail ("npm lockfile has no lockfileVersion: {0}" -f $relative)
    return
  }

  if (($content -notmatch '"packages"\s*:\s*\{') -and ($content -notmatch '"dependencies"\s*:\s*\{')) {
    Write-Fail ("npm lockfile has no dependency entries: {0}" -f $relative)
    return
  }

  Write-Ok ("npm lockfile structure valid: {0}" -f $relative)
  Test-NpmLockIntegrity $LockPath
}

function Invoke-NpmAudit {
  param([Parameter(Mandatory = $true)][string]$PackageDirectory)

  $relative = Get-RepoRelativePath $PackageDirectory
  $result = Invoke-External "npm" @("audit", "--package-lock-only", "--audit-level=high", "--json") $PackageDirectory
  $text = ($result.Output -join "`n")
  $audit = $null

  try {
    $audit = $text | ConvertFrom-Json -ErrorAction Stop
  } catch {
    $audit = $null
  }

  if ($null -ne $audit) {
    $high = 0
    $critical = 0
    if ((Test-JsonProperty $audit "metadata") -and (Test-JsonProperty $audit.metadata "vulnerabilities")) {
      $vulnerabilities = $audit.metadata.vulnerabilities
      if (Test-JsonProperty $vulnerabilities "high") {
        $high = [int]$vulnerabilities.high
      }
      if (Test-JsonProperty $vulnerabilities "critical") {
        $critical = [int]$vulnerabilities.critical
      }
    }

    if (($high + $critical) -gt 0) {
      Write-Fail ("npm audit found high/critical vulnerabilities in {0}: high={1}, critical={2}" -f $relative, $high, $critical)
      return
    }
    if ($result.ExitCode -eq 0) {
      Write-Ok ("npm audit passed at high threshold: {0}" -f $relative)
      return
    }
  }

  if ($result.ExitCode -ne 0) {
    Write-Warn ("npm audit did not return a usable vulnerability result for {0}; treating as advisory tool unavailable" -f $relative)
    Write-SafeTail $result.Output
    return
  }

  Write-Ok ("npm audit completed: {0}" -f $relative)
}

function Get-DockerfileBaseImages {
  param([Parameter(Mandatory = $true)][string]$DockerfilePath)

  $images = New-Object System.Collections.Generic.List[string]
  foreach ($line in Get-Content -LiteralPath $DockerfilePath) {
    $trimmed = $line.Trim()
    if ($trimmed.Length -eq 0 -or $trimmed.StartsWith("#")) {
      continue
    }
    if ($trimmed -notmatch '(?i)^FROM\s+') {
      continue
    }

    $parts = @($trimmed -split '\s+')
    $imageIndex = 1
    while ($imageIndex -lt $parts.Count -and $parts[$imageIndex].StartsWith("--")) {
      $imageIndex += 1
    }
    if ($imageIndex -lt $parts.Count) {
      [void]$images.Add($parts[$imageIndex])
    }
  }

  return @($images.ToArray())
}

function Test-ContainerImageReference {
  param(
    [Parameter(Mandatory = $true)][string]$ImageReference,
    [Parameter(Mandatory = $true)][string]$Context
  )

  if ([string]::Equals($ImageReference, "scratch", [System.StringComparison]::OrdinalIgnoreCase)) {
    return
  }

  $script:ContainerImageCount += 1
  $digestMatches = @([regex]::Matches($ImageReference, '@sha256:[0-9a-fA-F]{64}$'))
  $hasDigest = ($digestMatches.Count -eq 1)
  if ($ImageReference -match '@sha256:' -and -not $hasDigest) {
    Write-Fail ("container image has invalid sha256 digest pin: {0}" -f $Context)
    return
  }
  if ($hasDigest) {
    $script:ContainerDigestPinnedCount += 1
  }

  $imageWithoutDigest = ($ImageReference -split '@')[0]
  $lastSegment = ($imageWithoutDigest -split '/')[-1]
  if (-not $hasDigest -and $lastSegment -notmatch ':.+') {
    Write-Warn ("container image has no explicit tag: {0}" -f $Context)
    return
  }

  if (-not $hasDigest -and $lastSegment -match '(?i):latest$') {
    Write-Warn ("container image uses latest tag: {0}" -f $Context)
  }
  if (-not $hasDigest) {
    Write-Warn ("container image is tag-pinned but not digest-pinned: {0}" -f $Context)
  }
}

function Test-Dockerfile {
  param([Parameter(Mandatory = $true)][string]$DockerfilePath)

  $relative = Get-RepoRelativePath $DockerfilePath
  $content = Get-Content -LiteralPath $DockerfilePath -Raw
  if ([string]::IsNullOrWhiteSpace($content)) {
    Write-Fail ("Dockerfile is empty: {0}" -f $relative)
    return
  }

  $baseImages = @(Get-DockerfileBaseImages $DockerfilePath)
  if ($baseImages.Count -eq 0) {
    Write-Fail ("Dockerfile has no FROM stage: {0}" -f $relative)
    return
  }

  foreach ($image in $baseImages) {
    Test-ContainerImageReference -ImageReference $image -Context $relative
  }

  Write-Ok ("Dockerfile structure valid: {0} (stages={1})" -f $relative, $baseImages.Count)
}

function Test-ComposeManifest {
  param([Parameter(Mandatory = $true)][string]$ComposePath)

  $relative = Get-RepoRelativePath $ComposePath
  $content = Get-Content -LiteralPath $ComposePath -Raw
  if ([string]::IsNullOrWhiteSpace($content)) {
    Write-Fail ("Compose manifest is empty: {0}" -f $relative)
    return
  }

  if ($content -notmatch '(?im)^\s*services\s*:') {
    Write-Fail ("Compose manifest has no services block: {0}" -f $relative)
    return
  }

  $imageMatches = @([regex]::Matches($content, '(?im)^\s*image\s*:\s*[''"]?([^''"\s#]+)'))
  $buildMatches = @([regex]::Matches($content, '(?im)^\s*build\s*:'))
  if (($imageMatches.Count + $buildMatches.Count) -eq 0) {
    Write-Fail ("Compose manifest has no image or build declarations: {0}" -f $relative)
    return
  }

  foreach ($match in $imageMatches) {
    $image = [string]$match.Groups[1].Value
    Test-ContainerImageReference -ImageReference $image -Context $relative
  }

  Write-Ok ("Compose container declarations valid: {0} (images={1}, builds={2})" -f $relative, $imageMatches.Count, $buildMatches.Count)
}

function Invoke-ContainerScanner {
  param(
    [Parameter(Mandatory = $true)][bool]$DockerAvailable,
    [Parameter(Mandatory = $true)][bool]$TrivyAvailable,
    [Parameter(Mandatory = $true)][bool]$GrypeAvailable
  )

  if ($TrivyAvailable) {
    $trivy = Invoke-External "trivy" @("config", "--no-progress", "--severity", "HIGH,CRITICAL", "--exit-code", "1", ".") $script:RepoRoot
    if ($trivy.ExitCode -eq 0) {
      Write-Ok "trivy container config scan passed"
    } else {
      Write-Fail "trivy container config scan reported high/critical issues or failed"
      Write-SafeTail $trivy.Output
    }
    return
  }

  if ($GrypeAvailable) {
    Write-Warn "grype is available, but no built image name is provided by this dry-run contract; container image vulnerability scan skipped"
    return
  }

  if (-not $DockerAvailable) {
    Write-Warn "docker not found; built image vulnerability scan skipped"
    return
  }

  Write-Warn "no container scanner found (trivy or grype); container vulnerability scan skipped"
}

function Get-CiWorkflowFiles {
  $files = New-Object System.Collections.Generic.List[string]
  $seen = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)

  $exampleCi = Join-Path $script:RepoRoot "examples/ci_github_actions_example.yml"
  if (Test-Path -LiteralPath $exampleCi) {
    if ($seen.Add($exampleCi)) {
      [void]$files.Add($exampleCi)
    }
  }

  $githubWorkflows = Join-Path $script:RepoRoot ".github/workflows"
  if (Test-Path -LiteralPath $githubWorkflows) {
    foreach ($workflow in Get-ChildItem -LiteralPath $githubWorkflows -File -ErrorAction SilentlyContinue) {
      if ($workflow.Name.EndsWith(".yml", [System.StringComparison]::OrdinalIgnoreCase) -or
          $workflow.Name.EndsWith(".yaml", [System.StringComparison]::OrdinalIgnoreCase)) {
        if ($seen.Add($workflow.FullName)) {
          [void]$files.Add($workflow.FullName)
        }
      }
    }
  }

  return @($files.ToArray())
}

function Test-CiArtifactGeneration {
  param([Parameter(Mandatory = $true)][string[]]$CiPaths)

  if ($CiPaths.Count -eq 0) {
    Write-Warn "no CI workflow manifests found for SBOM/provenance artifact generation check"
    return
  }

  $supplyChainScanFiles = New-Object System.Collections.Generic.List[string]
  $artifactGenerationFiles = New-Object System.Collections.Generic.List[string]
  foreach ($ciPath in $CiPaths) {
    $relative = Get-RepoRelativePath $ciPath
    $content = Get-Content -LiteralPath $ciPath -Raw
    if ([string]::IsNullOrWhiteSpace($content)) {
      Write-Fail ("CI workflow manifest is empty: {0}" -f $relative)
      continue
    }

    $hasSupplyChainScan = ($content -match 'scan_supply_chain\.ps1\s+-(SkipNetwork|Offline)')
    $hasArtifactGenerator = ($content -match 'generate_supply_chain_artifacts\.ps1')
    $hasArtifactOutputDirectory = ($content -match 'generate_supply_chain_artifacts\.ps1[^\r\n]*-OutputDirectory\s+[''"]?artifacts/supply-chain[''"]?')
    $hasUploadArtifact = ($content -match '(?i)actions/upload-artifact@')
    $hasUploadPath = ($content -match '(?im)^\s*path\s*:\s*[''"]?artifacts/supply-chain/?[''"]?\s*$')
    $hasUploadFailureMode = ($content -match '(?im)^\s*if-no-files-found\s*:\s*error\s*$')
    $hasSupplyChainArtifactName = ($content -match '(?im)^\s*name\s*:\s*[''"]?[^''"\r\n]*supply-chain[^''"\r\n]*(sbom|provenance)[^''"\r\n]*[''"]?\s*$')
    $hasSbom = ($content -match '(?i)\bsbom\b')
    $hasProvenance = ($content -match '(?i)\b(provenance|attest|attestation|slsa)\b')
    $hasChecksum = ($content -match '(?i)\b(sha256|checksums?|SHA256SUMS)\b')

    if ($hasSupplyChainScan) {
      [void]$supplyChainScanFiles.Add($relative)
    }

    if ($hasArtifactGenerator -and $hasArtifactOutputDirectory -and $hasUploadArtifact -and $hasUploadPath -and $hasUploadFailureMode -and $hasSupplyChainArtifactName -and $hasSbom -and $hasProvenance -and $hasChecksum) {
      [void]$artifactGenerationFiles.Add($relative)
    } elseif ($relative.StartsWith(".github/workflows/", [System.StringComparison]::OrdinalIgnoreCase)) {
      $missing = New-Object System.Collections.Generic.List[string]
      if (-not $hasArtifactGenerator) { [void]$missing.Add("artifact generator") }
      if (-not $hasArtifactOutputDirectory) { [void]$missing.Add("artifacts/supply-chain output directory") }
      if (-not $hasUploadArtifact) { [void]$missing.Add("actions/upload-artifact") }
      if (-not $hasUploadPath) { [void]$missing.Add("upload path artifacts/supply-chain") }
      if (-not $hasUploadFailureMode) { [void]$missing.Add("if-no-files-found:error") }
      if (-not $hasSupplyChainArtifactName) { [void]$missing.Add("supply-chain SBOM/provenance artifact name") }
      if (-not $hasSbom) { [void]$missing.Add("SBOM marker") }
      if (-not $hasProvenance) { [void]$missing.Add("provenance marker") }
      if (-not $hasChecksum) { [void]$missing.Add("checksum marker") }
      Write-Warn ("CI workflow lacks generated SBOM/provenance/checksum artifact upload contract: {0} (missing: {1})" -f $relative, (Join-LimitedValues -Values $missing.ToArray() -Limit 9))
    }
  }

  if ($supplyChainScanFiles.Count -gt 0) {
    Write-Ok ("CI supply-chain scan step present: {0}" -f (Join-LimitedValues $supplyChainScanFiles.ToArray()))
  } else {
    Write-Warn "CI workflow manifests do not reference scan_supply_chain.ps1 -SkipNetwork/-Offline"
  }

  if ($artifactGenerationFiles.Count -gt 0) {
    Write-Ok ("CI SBOM/provenance artifact generation present: {0}" -f (Join-LimitedValues $artifactGenerationFiles.ToArray()))
    Write-Ok ("CI supply-chain artifact upload dry-run contract present: {0}" -f (Join-LimitedValues $artifactGenerationFiles.ToArray()))
  } else {
    Write-Warn "CI workflow manifests do not generate and upload SBOM/provenance/checksum artifacts"
  }
}

function Test-SupplyChainArtifactScripts {
  $generator = Join-Path $script:RepoRoot "scripts/generate_supply_chain_artifacts.ps1"
  $scanSelfTest = Join-Path $script:RepoRoot "scripts/test_supply_chain_scan.ps1"
  $selfTest = Join-Path $script:RepoRoot "scripts/test_supply_chain_artifacts.ps1"

  if (Test-Path -LiteralPath $generator -PathType Leaf) {
    Write-Ok "Supply-chain artifact generator script present: scripts/generate_supply_chain_artifacts.ps1"
  } else {
    Write-Fail "Supply-chain artifact generator script is missing: scripts/generate_supply_chain_artifacts.ps1"
  }

  if (Test-Path -LiteralPath $scanSelfTest -PathType Leaf) {
    Write-Ok "Supply-chain scan self-test script present: scripts/test_supply_chain_scan.ps1"
  } else {
    Write-Fail "Supply-chain scan self-test script is missing: scripts/test_supply_chain_scan.ps1"
  }

  if (Test-Path -LiteralPath $selfTest -PathType Leaf) {
    Write-Ok "Supply-chain artifact self-test script present: scripts/test_supply_chain_artifacts.ps1"
  } else {
    Write-Fail "Supply-chain artifact self-test script is missing: scripts/test_supply_chain_artifacts.ps1"
  }
}

Write-Host ("Supply-chain scan starting at {0}" -f (Get-RepoRelativePath $script:RepoRoot))
if ($script:NetworkEnabled) {
  Write-Host "Network-backed vulnerability audits are enabled."
} else {
  Write-Host "Network-backed vulnerability audits are skipped by -Offline/-SkipNetwork."
}

$trackedNames = @("Cargo.toml", "Cargo.lock", "package.json", "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml")
$trackedFiles = Get-RepositoryFiles -Names $trackedNames
$containerFiles = Get-RepositoryFilesMatching -NamePatterns @("Dockerfile", "*.Dockerfile", "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml")
$ciFiles = Get-CiWorkflowFiles

$cargoTomls = @($trackedFiles | Where-Object { [string]::Equals([System.IO.Path]::GetFileName($_), "Cargo.toml", [System.StringComparison]::OrdinalIgnoreCase) })
$cargoLocks = @($trackedFiles | Where-Object { [string]::Equals([System.IO.Path]::GetFileName($_), "Cargo.lock", [System.StringComparison]::OrdinalIgnoreCase) })
$packageJsons = @($trackedFiles | Where-Object { [string]::Equals([System.IO.Path]::GetFileName($_), "package.json", [System.StringComparison]::OrdinalIgnoreCase) })
$npmLockFiles = @($trackedFiles | Where-Object {
  $name = [System.IO.Path]::GetFileName($_)
  [string]::Equals($name, "package-lock.json", [System.StringComparison]::OrdinalIgnoreCase) -or
  [string]::Equals($name, "npm-shrinkwrap.json", [System.StringComparison]::OrdinalIgnoreCase)
})
$dockerfiles = @($containerFiles | Where-Object {
  $name = [System.IO.Path]::GetFileName($_)
  [string]::Equals($name, "Dockerfile", [System.StringComparison]::OrdinalIgnoreCase) -or $name.EndsWith(".Dockerfile", [System.StringComparison]::OrdinalIgnoreCase)
})
$composeFiles = @($containerFiles | Where-Object {
  $name = [System.IO.Path]::GetFileName($_)
  [string]::Equals($name, "docker-compose.yml", [System.StringComparison]::OrdinalIgnoreCase) -or
  [string]::Equals($name, "docker-compose.yaml", [System.StringComparison]::OrdinalIgnoreCase) -or
  [string]::Equals($name, "compose.yml", [System.StringComparison]::OrdinalIgnoreCase) -or
  [string]::Equals($name, "compose.yaml", [System.StringComparison]::OrdinalIgnoreCase)
})

Write-Ok ("discovered manifests: Rust={0}, npm={1}" -f $cargoTomls.Count, $packageJsons.Count)
Write-Ok ("discovered container manifests: Dockerfiles={0}, Compose={1}" -f $dockerfiles.Count, $composeFiles.Count)
Write-Ok ("discovered CI workflow manifests: {0}" -f $ciFiles.Count)

$cargoAvailable = Test-CommandAvailable "cargo" "Rust manifest and cargo-audit entry point"
if ($packageJsons.Count -gt 0) {
  $nodeAvailable = Test-CommandAvailable "node" "npm package runtime"
  $npmAvailable = Test-CommandAvailable "npm" "npm lockfile audit"
} else {
  $nodeAvailable = $false
  $npmAvailable = $false
}
[void](Test-CommandAvailable "rg" "secret scan support")
$dockerAvailable = $false
$trivyAvailable = $false
$grypeAvailable = $false
if (($dockerfiles.Count + $composeFiles.Count) -gt 0) {
  $dockerAvailable = Test-CommandAvailable "docker" "optional container image scan runtime"
  $trivyAvailable = Test-CommandAvailable "trivy" "container config scanner"
  $grypeAvailable = Test-CommandAvailable "grype" "container image scanner"
}

if ($cargoTomls.Count -gt 0) {
  $rootCargoToml = Join-Path $script:RepoRoot "Cargo.toml"
  $rootCargoLock = Join-Path $script:RepoRoot "Cargo.lock"

  if (-not (Test-Path -LiteralPath $rootCargoToml)) {
    Write-Fail "Cargo manifests were found but repository root Cargo.toml is missing"
  }

  if (Test-Path -LiteralPath $rootCargoLock) {
    Test-CargoLock $rootCargoLock
    Test-CargoLockProvenance $rootCargoLock
  } else {
    Write-Fail "Cargo manifests were found but repository root Cargo.lock is missing"
  }

  foreach ($lock in $cargoLocks) {
    if (-not [string]::Equals((Get-RepoRelativePath $lock), "Cargo.lock", [System.StringComparison]::OrdinalIgnoreCase)) {
      Test-CargoLock $lock
      Test-CargoLockProvenance $lock
    }
  }

  if ($cargoAvailable -and (Test-Path -LiteralPath $rootCargoToml)) {
    $metadata = Invoke-External "cargo" @("metadata", "--locked", "--no-deps", "--format-version", "1") $script:RepoRoot
    if ($metadata.ExitCode -eq 0) {
      Write-Ok "cargo metadata --locked succeeded"
    } else {
      Write-Fail "cargo metadata --locked failed; Rust lockfile may be stale or manifest parsing may be broken"
      Write-SafeTail $metadata.Output
    }
  } else {
    Write-Warn "cargo metadata --locked skipped"
  }
} else {
  Write-Warn "no Rust manifests found"
}

$packageDirectories = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($packageJson in $packageJsons) {
  [void]$packageDirectories.Add((Split-Path -Parent $packageJson))
}

foreach ($packageJson in $packageJsons) {
  $packageDirectory = Split-Path -Parent $packageJson
  $relativePackage = Get-RepoRelativePath $packageJson
  $packageLock = Join-Path $packageDirectory "package-lock.json"
  $shrinkwrap = Join-Path $packageDirectory "npm-shrinkwrap.json"

  if (Test-Path -LiteralPath $packageLock) {
    Test-NpmLock $packageLock
  } elseif (Test-Path -LiteralPath $shrinkwrap) {
    Test-NpmLock $shrinkwrap
  } else {
    Write-Fail ("npm manifest has no npm lockfile: {0}" -f $relativePackage)
  }
}

foreach ($npmLock in $npmLockFiles) {
  $lockDirectory = Split-Path -Parent $npmLock
  if (-not $packageDirectories.Contains($lockDirectory)) {
    Write-Fail ("npm lockfile has no adjacent package.json: {0}" -f (Get-RepoRelativePath $npmLock))
  }
}

if (($dockerfiles.Count + $composeFiles.Count) -gt 0) {
  foreach ($dockerfile in $dockerfiles) {
    Test-Dockerfile $dockerfile
  }

  foreach ($composeFile in $composeFiles) {
    Test-ComposeManifest $composeFile
  }

  Write-Ok ("container image pinning inspected: images={0}, digest_pinned={1}" -f $script:ContainerImageCount, $script:ContainerDigestPinnedCount)
} else {
  Write-Warn "no container manifests found"
}

Test-SupplyChainArtifactScripts
Test-CiArtifactGeneration -CiPaths $ciFiles

Write-Host "[INFO] remaining supply-chain hardening gaps: digest pinning enforcement, network vulnerability scans, real built image scans"

if ($script:NetworkEnabled) {
  if ($cargoAvailable -and $cargoTomls.Count -gt 0) {
    $cargoAuditProbe = Invoke-External "cargo" @("audit", "--version") $script:RepoRoot
    if ($cargoAuditProbe.ExitCode -eq 0) {
      $cargoAudit = Invoke-External "cargo" @("audit", "--deny", "warnings") $script:RepoRoot
      if ($cargoAudit.ExitCode -eq 0) {
        Write-Ok "cargo audit passed"
      } else {
        Write-Fail "cargo audit reported vulnerabilities or failed"
        Write-SafeTail $cargoAudit.Output
      }
    } else {
      Write-Warn "cargo-audit is not available; Rust vulnerability audit skipped"
    }
  }

  if ($npmAvailable -and $npmLockFiles.Count -gt 0) {
    $npmAuditProbe = Invoke-External "npm" @("audit", "--help") $script:RepoRoot
    if ($npmAuditProbe.ExitCode -eq 0) {
      foreach ($npmLock in $npmLockFiles) {
        Invoke-NpmAudit (Split-Path -Parent $npmLock)
      }
    } else {
      Write-Warn "npm audit is not available; npm vulnerability audit skipped"
    }
  }

  if (($dockerfiles.Count + $composeFiles.Count) -gt 0) {
    Invoke-ContainerScanner -DockerAvailable $dockerAvailable -TrivyAvailable $trivyAvailable -GrypeAvailable $grypeAvailable
  }
} else {
  Write-Ok "network-backed cargo audit, npm audit, and container vulnerability scan skipped"
}

Write-Host ("Summary: checks={0}, warnings={1}, failures={2}" -f $script:CheckCount, $script:Warnings.Count, $script:Failures.Count)
if ($script:Failures.Count -gt 0) {
  exit 1
}

exit 0
