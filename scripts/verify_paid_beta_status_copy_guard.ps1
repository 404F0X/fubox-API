param(
  [string[]]$Paths = @(
    "project/RELEASE_CHECKLIST.md",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md",
    "TODO/AGENT_COORDINATION_2026-06-05.md",
    "scripts/release_check.ps1"
  )
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$allowedHistoricalPaths = @(
  "docs/todo/slices",
  "TODO/archive"
)

$patterns = @(
  [ordered]@{
    id = "paid_unselected_cn"
    regex = "未选择\s*`?paid`?"
    reason = "Current paid posture must say paid requested, blocked until real evidence."
  },
  [ordered]@{
    id = "usage_only_unique_cn"
    regex = "usage_only_beta\s*(是|为).{0,16}(唯一目标|唯一选择|唯一模式)"
    reason = "usage_only_beta is fallback/safe mode, not the only target after paid was requested."
  },
  [ordered]@{
    id = "usage_only_unique_en"
    regex = "(?i)usage_only_beta\s+(is|as|remains|stays).{0,40}(only|sole)\s+(target|goal|mode|choice)"
    reason = "usage_only_beta is fallback/safe mode, not the only target after paid was requested."
  },
  [ordered]@{
    id = "release_check_stale_note"
    regex = "validates current trusted Beta stays usage_only_beta"
    reason = "Billing release note must mention paid requested plus fallback and blocked-until-evidence."
  },
  [ordered]@{
    id = "usage_only_only_release"
    regex = "(?i)trusted Beta may proceed only as usage-only|paid remains unselected|usage-only only"
    reason = "Current release copy must not imply paid is unselected or impossible."
  }
)

function Resolve-RepoPath {
  param([Parameter(Mandatory = $true)][string]$Path)

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Get-RepoRelativePath {
  param([Parameter(Mandatory = $true)][string]$Path)

  $full = [System.IO.Path]::GetFullPath($Path)
  $prefix = $repoRoot.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
  if ($full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    return ($full.Substring($prefix.Length) -replace "\\", "/")
  }
  return ($full -replace "\\", "/")
}

$findings = New-Object System.Collections.Generic.List[object]
$scanned = New-Object System.Collections.Generic.List[string]
$missing = New-Object System.Collections.Generic.List[string]

foreach ($path in $Paths) {
  $full = Resolve-RepoPath $path
  $relative = Get-RepoRelativePath $full
  if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
    [void]$missing.Add($relative)
    continue
  }

  [void]$scanned.Add($relative)
  $lines = Get-Content -LiteralPath $full
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = [string]$lines[$i]
    foreach ($pattern in $patterns) {
      if ([regex]::IsMatch($line, [string]$pattern.regex)) {
        [void]$findings.Add([ordered]@{
            path = $relative
            line = $i + 1
            pattern_id = $pattern.id
            reason = $pattern.reason
            excerpt = ($line.Trim() -replace "\s+", " ")
          })
      }
    }
  }
}

$status = if ($findings.Count -eq 0) { "pass" } else { "fail" }

$result = [ordered]@{
  schema = "paid_beta_status_copy_guard_v1"
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  overall_status = $status
  scanned_paths = @($scanned.ToArray())
  missing_paths = @($missing.ToArray())
  allowed_historical_paths = @($allowedHistoricalPaths)
  patterns = @($patterns | ForEach-Object {
      [ordered]@{ id = $_.id; reason = $_.reason }
    })
  findings = @($findings.ToArray())
}

$result | ConvertTo-Json -Depth 8
if ($status -ne "pass") {
  exit 1
}
