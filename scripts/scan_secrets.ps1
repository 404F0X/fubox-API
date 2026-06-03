#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$scriptPath = $PSCommandPath
if (-not $scriptPath) {
  $scriptPath = $MyInvocation.MyCommand.Path
}

$script:RepoRoot = (Resolve-Path (Join-Path (Split-Path -Parent $scriptPath) "..")).Path
$script:SecretPattern = '(sk-[A-Za-z0-9]{20,}|BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY|Authorization:\s*Bearer\s+[A-Za-z0-9._~+/\-]{20,}=*)'
$script:ExcludedDirectoryNames = @(".git", "target", "node_modules", "dist", "dev_starter_unpacked", ".docx_unpacked")
$script:ExcludedRelativePaths = @("scripts/scan_secrets.ps1", "Makefile")
$script:SkippedExtensions = @(".7z", ".dll", ".docx", ".exe", ".gif", ".gz", ".ico", ".jpeg", ".jpg", ".pdf", ".png", ".rlib", ".rmeta", ".tar", ".webp", ".zip")
$script:HitCount = 0
$script:Warnings = New-Object System.Collections.Generic.List[string]

function Write-Warn {
  param([Parameter(Mandatory = $true)][string]$Message)

  [void]$script:Warnings.Add($Message)
  Write-Host "[WARN] $Message"
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

function Test-ExcludedRelativePath {
  param([Parameter(Mandatory = $true)][string]$Path)

  $relative = Get-RepoRelativePath $Path
  foreach ($excluded in $script:ExcludedRelativePaths) {
    if ([string]::Equals($relative, $excluded, [System.StringComparison]::OrdinalIgnoreCase)) {
      return $true
    }
  }

  return $false
}

function Test-SkippedExtension {
  param([Parameter(Mandatory = $true)][string]$Path)

  $extension = [System.IO.Path]::GetExtension($Path)
  foreach ($skipped in $script:SkippedExtensions) {
    if ([string]::Equals($extension, $skipped, [System.StringComparison]::OrdinalIgnoreCase)) {
      return $true
    }
  }

  return $false
}

function Get-SecretKind {
  param([string]$MatchedText)

  if ($MatchedText -match '(?i)^sk-') {
    return "api-key"
  }
  if ($MatchedText -match '(?i)PRIVATE KEY') {
    return "private-key"
  }
  if ($MatchedText -match '(?i)Authorization:\s*Bearer') {
    return "bearer-token"
  }

  return "secret-pattern"
}

function Write-SecretHit {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][int]$LineNumber,
    [Parameter(Mandatory = $true)][string]$Kind
  )

  $script:HitCount += 1
  Write-Host ("[FAIL] secret-like material detected: {0}:{1} ({2})" -f (Get-RepoRelativePath $Path), $LineNumber, $Kind)
}

function Get-RepositoryFiles {
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

      if ((Test-ExcludedRelativePath $item.FullName) -or (Test-SkippedExtension $item.FullName)) {
        continue
      }

      [void]$files.Add($item.FullName)
    }
  }

  return @($files.ToArray())
}

function Invoke-RipgrepScan {
  $rg = Get-Command rg -ErrorAction SilentlyContinue
  if (-not $rg) {
    Write-Warn "rg not found; using PowerShell fallback secret scan"
    return $false
  }

  $arguments = @(
    "--json",
    "--color", "never",
    $script:SecretPattern,
    ".",
    "-g", "!target/**",
    "-g", "!**/node_modules/**",
    "-g", "!**/dist/**",
    "-g", "!dev_starter_unpacked/**",
    "-g", "!.docx_unpacked/**",
    "-g", "!scripts/scan_secrets.ps1",
    "-g", "!Makefile"
  )

  Push-Location $script:RepoRoot
  try {
    $output = & rg @arguments 2>&1
    $exitCode = $LASTEXITCODE
  } catch {
    Write-Warn "rg secret scan failed to start; using PowerShell fallback"
    return $false
  } finally {
    Pop-Location
  }

  if ($exitCode -eq 1) {
    return $true
  }

  if ($exitCode -ne 0) {
    Write-Warn ("rg secret scan exited with code {0}; using PowerShell fallback" -f $exitCode)
    return $false
  }

  foreach ($line in $output) {
    if ([string]::IsNullOrWhiteSpace([string]$line)) {
      continue
    }

    try {
      $event = ([string]$line) | ConvertFrom-Json -ErrorAction Stop
    } catch {
      continue
    }

    if ($event.type -ne "match") {
      continue
    }

    $path = [string]$event.data.path.text
    $lineNumber = [int]$event.data.line_number
    $kind = "secret-pattern"
    $firstSubmatch = $event.data.submatches | Select-Object -First 1
    if ($null -ne $firstSubmatch) {
      $kind = Get-SecretKind ([string]$firstSubmatch.match.text)
    }

    Write-SecretHit -Path (Join-Path $script:RepoRoot $path) -LineNumber $lineNumber -Kind $kind
  }

  return $true
}

function Invoke-PowerShellFallbackScan {
  foreach ($file in Get-RepositoryFiles) {
    try {
      $matches = Select-String -LiteralPath $file -Pattern $script:SecretPattern -AllMatches -ErrorAction Stop
    } catch {
      Write-Warn ("unable to scan file: {0}" -f (Get-RepoRelativePath $file))
      continue
    }

    foreach ($matchInfo in $matches) {
      $kind = "secret-pattern"
      $firstMatch = $matchInfo.Matches | Select-Object -First 1
      if ($null -ne $firstMatch) {
        $kind = Get-SecretKind ([string]$firstMatch.Value)
      }

      Write-SecretHit -Path $file -LineNumber ([int]$matchInfo.LineNumber) -Kind $kind
    }
  }
}

Write-Host ("Secret scan starting at {0}" -f (Get-RepoRelativePath $script:RepoRoot))

$scannedWithRipgrep = Invoke-RipgrepScan
if (-not $scannedWithRipgrep) {
  Invoke-PowerShellFallbackScan
}

if ($script:HitCount -gt 0) {
  Write-Host ("Summary: hits={0}, warnings={1}" -f $script:HitCount, $script:Warnings.Count)
  exit 1
}

Write-Host ("[OK] no secret-like material detected")
Write-Host ("Summary: hits=0, warnings={0}" -f $script:Warnings.Count)
exit 0
