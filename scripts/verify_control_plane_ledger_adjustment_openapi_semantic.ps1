param(
  [string]$OpenApiPath = "examples/openapi_admin_skeleton.yaml",
  [string]$TempRoot = ".tmp\ledger-adjustment-openapi-semantic",
  [string]$NpmCache = ".tool-cache\npm",
  [switch]$Semantic,
  [switch]$Redocly,
  [switch]$OpenApiGeneratorValidate,
  [switch]$ClientGeneration,
  [switch]$OpenApiTypescript,
  [switch]$TypescriptFetch,
  [switch]$AllowPackageDownload,
  [switch]$Clean,
  [switch]$SelfTest,
  [switch]$SimulateExternalBlocker,
  [switch]$SimulateSchemaMismatch,
  [switch]$SimulateClientMismatch,
  [switch]$SimulateSensitiveOutputTail,
  [switch]$SimulateSensitiveCommandFailure,
  [switch]$SimulateGeneratedClientInspectionPass,
  [switch]$SimulateGeneratedClientMissingRequired,
  [switch]$SimulateSemanticEvidencePass,
  [switch]$SimulateSemanticEvidenceFailure,
  [switch]$SimulateSemanticEvidenceBlocker
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$contractGatePath = Join-Path $PSScriptRoot "verify_control_plane_ledger_adjustment_openapi_contract.ps1"

function Test-TruthyEnv {
  param([AllowNull()][string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $false
  }

  return @("1", "true", "yes", "on").Contains($Value.Trim().ToLowerInvariant())
}

if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SEMANTIC) { $Semantic = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_REDOCLY) { $Redocly = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_GENERATOR_VALIDATE) { $OpenApiGeneratorValidate = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_CLIENT_GENERATION) { $ClientGeneration = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_TYPESCRIPT) { $OpenApiTypescript = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_TYPESCRIPT_FETCH) { $TypescriptFetch = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_ALLOW_PACKAGE_DOWNLOAD) { $AllowPackageDownload = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_CLEAN) { $Clean = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SELF_TEST) { $SelfTest = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_EXTERNAL_BLOCKER) { $SimulateExternalBlocker = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_SCHEMA_MISMATCH) { $SimulateSchemaMismatch = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_CLIENT_MISMATCH) { $SimulateClientMismatch = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_SENSITIVE_OUTPUT_TAIL) { $SimulateSensitiveOutputTail = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_SENSITIVE_COMMAND_FAILURE) { $SimulateSensitiveCommandFailure = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_GENERATED_CLIENT_INSPECTION_PASS) { $SimulateGeneratedClientInspectionPass = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_GENERATED_CLIENT_MISSING_REQUIRED) { $SimulateGeneratedClientMissingRequired = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_SEMANTIC_EVIDENCE_PASS) { $SimulateSemanticEvidencePass = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_SEMANTIC_EVIDENCE_FAILURE) { $SimulateSemanticEvidenceFailure = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_SEMANTIC_EVIDENCE_BLOCKER) { $SimulateSemanticEvidenceBlocker = $true }
if (-not [string]::IsNullOrWhiteSpace($env:CONTROL_PLANE_LEDGER_OPENAPI_TEMP_ROOT)) {
  $TempRoot = $env:CONTROL_PLANE_LEDGER_OPENAPI_TEMP_ROOT
}
if (-not [string]::IsNullOrWhiteSpace($env:CONTROL_PLANE_LEDGER_OPENAPI_NPM_CACHE)) {
  $NpmCache = $env:CONTROL_PLANE_LEDGER_OPENAPI_NPM_CACHE
}

if ($Semantic) {
  $Redocly = $true
  $OpenApiGeneratorValidate = $true
}
if ($ClientGeneration) {
  $OpenApiTypescript = $true
  $TypescriptFetch = $true
}

function Resolve-RepoRelativePath {
  param([Parameter(Mandatory = $true)][string]$Path)

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }

  return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

$OpenApiPath = Resolve-RepoRelativePath $OpenApiPath
$TempRoot = Resolve-RepoRelativePath $TempRoot
$NpmCache = Resolve-RepoRelativePath $NpmCache

function Test-PathUnderRoot {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Root
  )

  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
  return $fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

function Format-BoundedPath {
  param([Parameter(Mandatory = $true)][string]$Path)

  $full = [System.IO.Path]::GetFullPath($Path)
  $repoPrefix = $repoRoot.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
  if ($full.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $full.Substring($repoPrefix.Length)
  }

  return "[outside_repo:" + [System.IO.Path]::GetFileName($full) + "]"
}

function Assert-PathUnderRepo {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Label
  )

  $repoPrefix = $repoRoot.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
  $full = [System.IO.Path]::GetFullPath($Path)
  if (-not $full.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "$Label must stay under repository root: $(Format-BoundedPath $full)"
  }
}

$tmpRoot = Join-Path $repoRoot ".tmp"
$toolCacheRoot = Join-Path $repoRoot ".tool-cache"
Assert-PathUnderRepo -Path $OpenApiPath -Label "OpenApiPath"
Assert-PathUnderRepo -Path $TempRoot -Label "TempRoot"
Assert-PathUnderRepo -Path $NpmCache -Label "NpmCache"
if (-not (Test-PathUnderRoot -Path $TempRoot -Root $tmpRoot)) {
  throw "TempRoot must stay under repository .tmp: $(Format-BoundedPath $TempRoot)"
}
if (
  -not (Test-PathUnderRoot -Path $NpmCache -Root $toolCacheRoot) -and
  -not (Test-PathUnderRoot -Path $NpmCache -Root $tmpRoot)
) {
  throw "NpmCache must stay under repository .tool-cache or .tmp: $(Format-BoundedPath $NpmCache)"
}

$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Blockers = New-Object System.Collections.Generic.List[string]
$script:EvidenceRecords = New-Object System.Collections.Generic.List[object]

function Redact-SafeText {
  param([AllowNull()][string]$Text)

  if ($null -eq $Text) {
    return ""
  }

  $redacted = [string]$Text
  $redacted = $redacted -replace '(?i)Authorization\s*[:=]\s*Bearer\s+[^\s,;)}]+', '[REDACTED_HEADER]'
  $redacted = $redacted -replace '(?i)Authorization\s*[:=]\s*[^\r\n,;)}]+', '[REDACTED_HEADER]'
  $redacted = $redacted -replace '(?i)Cookie\s*[:=]\s*[^\r\n]+', '[REDACTED_HEADER]'
  $redacted = $redacted -replace '(?i)Bearer\s+[A-Za-z0-9._~+/\-=]+', '[REDACTED_BEARER]'
  $redacted = $redacted -replace 'sk-[A-Za-z0-9._~+/\-=]+', 'sk-[REDACTED]'
  $redacted = $redacted -replace '(?i)(https?://)([^/\s:@]+):([^/\s@]+)@', '$1[REDACTED]@'
  $redacted = $redacted -replace '(?i)(_authToken\s*=\s*)[^\s;]+', '[REDACTED_MATERIAL]'
  $redacted = $redacted -replace '(?i)((?:password|passwd|secret|token|credential|api[_-]?key|operation[_-]?key|package[_-]?token|npm[_-]?token|raw[_-]?metadata|metadata)\s*[:=]\s*)[^\s''",;}]+', '[REDACTED_MATERIAL]'
  return $redacted
}

function Write-SafeHost {
  param([AllowNull()][string]$Text)

  Write-Host (Redact-SafeText $Text)
}

function Get-RepoRelativePath {
  param([Parameter(Mandatory = $true)][string]$Path)

  $full = [System.IO.Path]::GetFullPath($Path)
  $repoPrefix = $repoRoot.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
  if ($full.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $full.Substring($repoPrefix.Length)
  }

  return [System.IO.Path]::GetFileName($full)
}

function Get-EvidenceReportPath {
  param([string]$Root = $TempRoot)

  return Join-Path $Root "ledger-adjustment-openapi-semantic-evidence.json"
}

function Assert-WrapperOwnedArtifactPath {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Label
  )

  $full = [System.IO.Path]::GetFullPath($Path)
  if (-not (Test-PathUnderRoot -Path $full -Root $TempRoot)) {
    throw "$Label must stay under wrapper TempRoot: $(Format-BoundedPath $full)"
  }
}

function Get-WrapperOwnedArtifactPaths {
  return @(
    (Get-EvidenceReportPath),
    (Join-Path $TempRoot "openapi-typescript"),
    (Join-Path $TempRoot "typescript-fetch"),
    (Join-Path $TempRoot "self-test-default-lightweight-no-evidence"),
    (Join-Path $TempRoot "self-test-generated-client-pass"),
    (Join-Path $TempRoot "self-test-generated-client-missing-required"),
    (Join-Path $TempRoot "self-test-semantic-evidence-pass"),
    (Join-Path $TempRoot "self-test-semantic-evidence-failure"),
    (Join-Path $TempRoot "self-test-semantic-evidence-blocker"),
    (Join-Path $TempRoot "self-test-cleanup-marker.txt"),
    (Join-Path $TempRoot "self-test-wrapper-owned-cleanup-marker.txt")
  )
}

function Remove-WrapperOwnedTempArtifacts {
  foreach ($path in @(Get-WrapperOwnedArtifactPaths)) {
    Assert-WrapperOwnedArtifactPath -Path $path -Label "wrapper-owned artifact cleanup path"
    Remove-Item -Recurse -Force $path -ErrorAction SilentlyContinue
  }

  if (Test-Path $TempRoot -PathType Container) {
    $remaining = @(Get-ChildItem -LiteralPath $TempRoot -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($remaining.Count -eq 0) {
      Remove-Item -Force $TempRoot -ErrorAction SilentlyContinue
    }
  }
}

function Clear-StaleEvidenceReport {
  $path = Get-EvidenceReportPath
  Assert-WrapperOwnedArtifactPath -Path $path -Label "stale evidence report path"
  Remove-Item -Force $path -ErrorAction SilentlyContinue
}

function Get-BoundedSafeLines {
  param(
    [AllowEmptyString()][AllowEmptyCollection()][string[]]$Lines = @(),
    [int]$TakeLast = 8,
    [int]$MaxLineLength = 240
  )

  $bounded = New-Object System.Collections.Generic.List[string]
  foreach ($line in @($Lines | Select-Object -Last $TakeLast)) {
    if ([string]::IsNullOrWhiteSpace($line)) {
      continue
    }

    $safe = Redact-SafeText ([string]$line)
    if ($safe.Length -gt $MaxLineLength) {
      $safe = $safe.Substring(0, $MaxLineLength) + "...[truncated]"
    }
    [void]$bounded.Add($safe)
  }
  return @($bounded.ToArray())
}

function Get-RepoCommitProvenance {
  $git = Get-Command git -ErrorAction SilentlyContinue
  if ($null -eq $git) {
    return [pscustomobject]@{ Commit = "unavailable"; Status = "unavailable" }
  }

  $global:LASTEXITCODE = 0
  $oldErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    $output = @(& $git.Source -C $repoRoot rev-parse --short HEAD 2>&1 | ForEach-Object { [string]$_ })
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }

  $exitCode = if ($null -eq $global:LASTEXITCODE) { 0 } else { [int]$global:LASTEXITCODE }
  if ($exitCode -eq 0 -and $output.Count -gt 0) {
    $commit = ([string]$output[0]).Trim()
    if ($commit -match "^[a-fA-F0-9]{7,40}$") {
      return [pscustomobject]@{ Commit = $commit.ToLowerInvariant(); Status = "resolved" }
    }
  }

  return [pscustomobject]@{ Commit = "unavailable"; Status = "unavailable" }
}

function Get-OpenApiFixtureFingerprint {
  if (-not (Test-Path $OpenApiPath -PathType Leaf)) {
    return [pscustomobject]@{
      Path = Get-RepoRelativePath $OpenApiPath
      Sha256 = "unavailable"
      SizeBytes = 0
      LastWriteUtc = "unavailable"
      Status = "unavailable"
    }
  }

  try {
    $item = Get-Item -Path $OpenApiPath
    $hash = (Get-FileHash -Path $OpenApiPath -Algorithm SHA256).Hash.ToLowerInvariant()
    return [pscustomobject]@{
      Path = Get-RepoRelativePath $OpenApiPath
      Sha256 = $hash
      SizeBytes = [int64]$item.Length
      LastWriteUtc = $item.LastWriteTimeUtc.ToString("o")
      Status = "resolved"
    }
  } catch {
    return [pscustomobject]@{
      Path = Get-RepoRelativePath $OpenApiPath
      Sha256 = "unavailable"
      SizeBytes = 0
      LastWriteUtc = "unavailable"
      Status = "unavailable"
    }
  }
}

function Get-ProvenanceMode {
  if ($script:EvidenceRecords.Count -eq 0) {
    return "none"
  }

  $modes = @($script:EvidenceRecords | ForEach-Object { [string]$_.provenance_mode } | Sort-Object -Unique)
  if ($modes.Count -eq 1) {
    return $modes[0]
  }

  return "mixed"
}

function Get-WrapperCommandSummary {
  $requestedChecks = New-Object System.Collections.Generic.List[string]
  if ($Redocly) { [void]$requestedChecks.Add("redocly") }
  if ($OpenApiGeneratorValidate) { [void]$requestedChecks.Add("openapi_generator_validate") }
  if ($OpenApiTypescript) { [void]$requestedChecks.Add("openapi_typescript") }
  if ($TypescriptFetch) { [void]$requestedChecks.Add("typescript_fetch") }
  if ($requestedChecks.Count -eq 0) { [void]$requestedChecks.Add("lightweight_only") }

  $simulatedModes = New-Object System.Collections.Generic.List[string]
  if ($SimulateExternalBlocker) { [void]$simulatedModes.Add("external_blocker") }
  if ($SimulateSchemaMismatch) { [void]$simulatedModes.Add("schema_mismatch") }
  if ($SimulateClientMismatch) { [void]$simulatedModes.Add("client_mismatch") }
  if ($SimulateSensitiveOutputTail) { [void]$simulatedModes.Add("sensitive_output_tail") }
  if ($SimulateSensitiveCommandFailure) { [void]$simulatedModes.Add("sensitive_command_failure") }
  if ($SimulateGeneratedClientInspectionPass) { [void]$simulatedModes.Add("generated_client_inspection_pass") }
  if ($SimulateGeneratedClientMissingRequired) { [void]$simulatedModes.Add("generated_client_missing_required") }
  if ($SimulateSemanticEvidencePass) { [void]$simulatedModes.Add("semantic_evidence_pass") }
  if ($SimulateSemanticEvidenceFailure) { [void]$simulatedModes.Add("semantic_evidence_failure") }
  if ($SimulateSemanticEvidenceBlocker) { [void]$simulatedModes.Add("semantic_evidence_blocker") }

  return [ordered]@{
    script = "scripts/verify_control_plane_ledger_adjustment_openapi_semantic.ps1"
    openapi_path = Get-RepoRelativePath $OpenApiPath
    temp_root = Format-BoundedPath $TempRoot
    npm_cache = Format-BoundedPath $NpmCache
    requested_checks = @($requestedChecks.ToArray())
    simulated_modes = @($simulatedModes.ToArray())
    allow_package_download = [bool]$AllowPackageDownload
    clean_requested = [bool]$Clean
    self_test = [bool]$SelfTest
  }
}

function Add-EvidenceRecord {
  param(
    [Parameter(Mandatory = $true)][string]$Kind,
    [Parameter(Mandatory = $true)][string]$Label,
    [Parameter(Mandatory = $true)][string]$Tool,
    [Parameter(Mandatory = $true)][string]$ToolVersion,
    [Parameter(Mandatory = $true)][string]$Package,
    [Parameter(Mandatory = $true)][ValidateSet("pass", "failure", "blocker")][string]$Classification,
    [Parameter(Mandatory = $true)][int]$ExitCode,
    [AllowNull()][string]$Command = "",
    [AllowEmptyString()][AllowEmptyCollection()][string[]]$Output = @(),
    [AllowNull()][string]$FailureReason = "",
    [AllowNull()][string]$BlockerReason = "",
    [ValidateSet("real", "simulated")][string]$ProvenanceMode = "real"
  )

  $record = [ordered]@{
    kind = Redact-SafeText $Kind
    label = Redact-SafeText $Label
    provenance_mode = $ProvenanceMode
    tool = Redact-SafeText $Tool
    tool_version = Redact-SafeText $ToolVersion
    package = Redact-SafeText $Package
    checked_schema = Get-RepoRelativePath $OpenApiPath
    classification = $Classification
    exit_code = $ExitCode
    command = Redact-SafeText $Command
    output_tail = @(Get-BoundedSafeLines -Lines $Output)
    failure_reason = Redact-SafeText $FailureReason
    blocker_reason = Redact-SafeText $BlockerReason
  }
  [void]$script:EvidenceRecords.Add([pscustomobject]$record)
}

function Write-EvidenceReport {
  if ($script:EvidenceRecords.Count -eq 0) {
    return
  }

  $outcome = "pass"
  if ($script:Failures.Count -gt 0) {
    $outcome = "failure"
  } elseif ($script:Blockers.Count -gt 0) {
    $outcome = "blocker"
  }

  $repoCommit = Get-RepoCommitProvenance
  $fixture = Get-OpenApiFixtureFingerprint
  $report = [ordered]@{
    schema_version = "ledger_openapi_semantic_evidence.v1"
    report_type = "control_plane_ledger_adjustment_openapi_semantic"
    outcome = $outcome
    checked_schema = Get-RepoRelativePath $OpenApiPath
    repo_commit = $repoCommit.Commit
    repo_commit_status = $repoCommit.Status
    provenance_mode = Get-ProvenanceMode
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    command_summary = Get-WrapperCommandSummary
    openapi_fixture = [ordered]@{
      path = $fixture.Path
      sha256 = $fixture.Sha256
      size_bytes = $fixture.SizeBytes
      last_write_utc = $fixture.LastWriteUtc
      status = $fixture.Status
    }
    evidence = @($script:EvidenceRecords.ToArray())
  }

  $path = Get-EvidenceReportPath
  Assert-WrapperOwnedArtifactPath -Path $path -Label "evidence report path"
  New-Item -ItemType Directory -Force (Split-Path -Parent $path) | Out-Null
  ($report | ConvertTo-Json -Depth 8) | Set-Content -Path $path -Encoding ascii
  Write-SafeHost "[OK] evidence report: $(Format-BoundedPath $path)"
}

function Assert-EvidenceReportContract {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string[]]$ExpectedClassifications,
    [ValidateSet("", "real", "simulated", "mixed")][string]$ExpectedProvenanceMode = ""
  )

  if (-not (Test-Path $Path)) {
    Add-Failure "[FAIL] evidence report contract - missing report $Path"
    return
  }

  $raw = Get-Content -Path $Path -Raw
  foreach ($pattern in @(
      "(?i)Authorization\s*[:=]",
      "(?i)Cookie\s*[:=]",
      "(?i)Bearer\s+[A-Za-z0-9._~+/\-]+=*",
      "sk-[A-Za-z0-9._~+/\-]{8,}",
      "(?i)(password|passwd|secret|token|credential|api[_-]?key|operation[_-]?key|package[_-]?token|npm[_-]?token|raw[_-]?metadata|metadata)\s*[:=]\s*[^,\s]+",
      "(?i)https?://[^/\s:@]+:[^/\s@]+@"
    )) {
    if ($raw -match $pattern) {
      Add-Failure "[FAIL] evidence report contract - report contains forbidden material pattern"
      return
    }
  }

  $report = $raw | ConvertFrom-Json
  $rootFields = @($report.PSObject.Properties.Name)
  foreach ($field in $rootFields) {
    if (-not @("schema_version", "report_type", "outcome", "checked_schema", "repo_commit", "repo_commit_status", "provenance_mode", "generated_at_utc", "command_summary", "openapi_fixture", "evidence").Contains($field)) {
      Add-Failure "[FAIL] evidence report contract - unexpected root field '$field'"
    }
  }

  if ($report.schema_version -ne "ledger_openapi_semantic_evidence.v1") {
    Add-Failure "[FAIL] evidence report contract - unexpected schema_version '$($report.schema_version)'"
  }
  if (-not @("pass", "failure", "blocker").Contains([string]$report.outcome)) {
    Add-Failure "[FAIL] evidence report contract - invalid outcome '$($report.outcome)'"
  }
  if ($report.checked_schema -ne (Get-RepoRelativePath $OpenApiPath)) {
    Add-Failure "[FAIL] evidence report contract - checked_schema drifted"
  }
  if (-not @("resolved", "unavailable").Contains([string]$report.repo_commit_status)) {
    Add-Failure "[FAIL] evidence report contract - invalid repo_commit_status '$($report.repo_commit_status)'"
  }
  if ($report.repo_commit_status -eq "resolved" -and -not ([string]$report.repo_commit -match "^[a-f0-9]{7,40}$")) {
    Add-Failure "[FAIL] evidence report contract - invalid resolved repo_commit"
  }
  if ($report.repo_commit_status -eq "unavailable" -and [string]$report.repo_commit -ne "unavailable") {
    Add-Failure "[FAIL] evidence report contract - unavailable repo_commit must use unavailable marker"
  }
  if (-not @("real", "simulated", "mixed").Contains([string]$report.provenance_mode)) {
    Add-Failure "[FAIL] evidence report contract - invalid provenance_mode '$($report.provenance_mode)'"
  }
  if (-not [string]::IsNullOrWhiteSpace($ExpectedProvenanceMode) -and [string]$report.provenance_mode -ne $ExpectedProvenanceMode) {
    Add-Failure "[FAIL] evidence report contract - expected provenance_mode '$ExpectedProvenanceMode', got '$($report.provenance_mode)'"
  }
  try {
    [void][datetime]::Parse([string]$report.generated_at_utc)
  } catch {
    Add-Failure "[FAIL] evidence report contract - generated_at_utc is not parseable"
  }

  if ($null -eq $report.command_summary) {
    Add-Failure "[FAIL] evidence report contract - missing command_summary"
  } else {
    foreach ($field in @($report.command_summary.PSObject.Properties.Name)) {
      if (-not @("script", "openapi_path", "temp_root", "npm_cache", "requested_checks", "simulated_modes", "allow_package_download", "clean_requested", "self_test").Contains($field)) {
        Add-Failure "[FAIL] evidence report contract - unexpected command_summary field '$field'"
      }
    }
    if ([string]$report.command_summary.openapi_path -ne (Get-RepoRelativePath $OpenApiPath)) {
      Add-Failure "[FAIL] evidence report contract - command_summary openapi_path drifted"
    }
  }

  if ($null -eq $report.openapi_fixture) {
    Add-Failure "[FAIL] evidence report contract - missing openapi_fixture"
  } else {
    foreach ($field in @($report.openapi_fixture.PSObject.Properties.Name)) {
      if (-not @("path", "sha256", "size_bytes", "last_write_utc", "status").Contains($field)) {
        Add-Failure "[FAIL] evidence report contract - unexpected openapi_fixture field '$field'"
      }
    }
    if ([string]$report.openapi_fixture.path -ne (Get-RepoRelativePath $OpenApiPath)) {
      Add-Failure "[FAIL] evidence report contract - openapi_fixture path drifted"
    }
    if (-not @("resolved", "unavailable").Contains([string]$report.openapi_fixture.status)) {
      Add-Failure "[FAIL] evidence report contract - invalid openapi_fixture status '$($report.openapi_fixture.status)'"
    }
    if ($report.openapi_fixture.status -eq "resolved") {
      if (-not ([string]$report.openapi_fixture.sha256 -match "^[a-f0-9]{64}$")) {
        Add-Failure "[FAIL] evidence report contract - invalid openapi_fixture sha256"
      }
      if ([int64]$report.openapi_fixture.size_bytes -le 0) {
        Add-Failure "[FAIL] evidence report contract - invalid openapi_fixture size"
      }
      try {
        [void][datetime]::Parse([string]$report.openapi_fixture.last_write_utc)
      } catch {
        Add-Failure "[FAIL] evidence report contract - openapi_fixture last_write_utc is not parseable"
      }
    }
  }

  $records = @($report.evidence)
  if ($records.Count -eq 0) {
    Add-Failure "[FAIL] evidence report contract - evidence array is empty"
    return
  }

  foreach ($expected in $ExpectedClassifications) {
    if (-not (@($records | Where-Object { $_.classification -eq $expected }).Count -gt 0)) {
      Add-Failure "[FAIL] evidence report contract - missing classification '$expected'"
    }
  }

  foreach ($record in $records) {
    foreach ($field in @($record.PSObject.Properties.Name)) {
      if (-not @("kind", "label", "provenance_mode", "tool", "tool_version", "package", "checked_schema", "classification", "exit_code", "command", "output_tail", "failure_reason", "blocker_reason").Contains($field)) {
        Add-Failure "[FAIL] evidence report contract - unexpected evidence field '$field'"
      }
    }
    if (-not @("real", "simulated").Contains([string]$record.provenance_mode)) {
      Add-Failure "[FAIL] evidence report contract - invalid evidence provenance_mode '$($record.provenance_mode)'"
    }
    if (-not @("pass", "failure", "blocker").Contains([string]$record.classification)) {
      Add-Failure "[FAIL] evidence report contract - invalid classification '$($record.classification)'"
    }
    if ([string]::IsNullOrWhiteSpace([string]$record.tool_version)) {
      Add-Failure "[FAIL] evidence report contract - missing tool_version"
    }
    if ([string]$record.checked_schema -ne (Get-RepoRelativePath $OpenApiPath)) {
      Add-Failure "[FAIL] evidence report contract - record checked_schema drifted"
    }
    $tail = @($record.output_tail)
    if ($tail.Count -gt 8) {
      Add-Failure "[FAIL] evidence report contract - output_tail is unbounded"
    }
    foreach ($line in $tail) {
      if (([string]$line).Length -gt 260) {
        Add-Failure "[FAIL] evidence report contract - output_tail line is unbounded"
      }
    }
  }
}

function Add-Failure {
  param([Parameter(Mandatory = $true)][string]$Message)

  $safe = Redact-SafeText $Message
  [void]$script:Failures.Add($safe)
  Write-SafeHost $safe
}

function Add-Blocker {
  param([Parameter(Mandatory = $true)][string]$Message)

  $safe = Redact-SafeText $Message
  [void]$script:Blockers.Add($safe)
  Write-SafeHost $safe
}

function Exit-WithResult {
  Write-EvidenceReport

  if ($script:Failures.Count -gt 0) {
    Write-SafeHost ""
    Write-SafeHost "Control Plane ledger adjustment OpenAPI semantic validation failed:"
    foreach ($failure in $script:Failures) {
      Write-SafeHost $failure
    }
    exit 1
  }

  if ($script:Blockers.Count -gt 0) {
    Write-SafeHost ""
    Write-SafeHost "Control Plane ledger adjustment OpenAPI semantic validation is externally blocked:"
    foreach ($blocker in $script:Blockers) {
      Write-SafeHost $blocker
    }
    exit 2
  }

  Write-SafeHost "Control Plane ledger adjustment OpenAPI semantic validation passed."
  exit 0
}

function Test-ToolAvailable {
  param([Parameter(Mandatory = $true)][string]$Name)

  return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Assert-ToolAvailable {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Reason
  )

  if (-not (Test-ToolAvailable $Name)) {
    throw "$Name not found; $Reason"
  }
}

function Format-CommandLine {
  param(
    [Parameter(Mandatory = $true)][string]$FileName,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )

  $parts = New-Object System.Collections.Generic.List[string]
  [void]$parts.Add($FileName)
  foreach ($argument in $Arguments) {
    $text = [string]$argument
    if ($text -match "\s") {
      $text = '"' + $text.Replace('"', '\"') + '"'
    }
    [void]$parts.Add($text)
  }
  return Redact-SafeText ($parts.ToArray() -join " ")
}

function Test-BlockerOutput {
  param([Parameter(Mandatory = $true)][string]$Text)

  foreach ($pattern in @(
      "ENOTCACHED",
      "EAI_AGAIN",
      "ECONNRESET",
      "ECONNREFUSED",
      "ENETUNREACH",
      "ETIMEDOUT",
      "ENOTFOUND",
      "network",
      "offline",
      "only-if-cached",
      "not in cache",
      "No cached",
      "could not determine executable",
      "unable to get local issuer certificate",
      "self signed certificate",
      "could not resolve",
      "Connection refused"
    )) {
    if ($Text -match [regex]::Escape($pattern)) {
      return $true
    }
  }

  return $false
}

function Invoke-Process {
  param(
    [Parameter(Mandatory = $true)][string]$FileName,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$Label,
    [switch]$ExternalTool
  )

  $global:LASTEXITCODE = 0
  $oldErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    $output = @(& $FileName @Arguments 2>&1 | ForEach-Object { [string]$_ })
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }
  $exitCode = if ($null -eq $global:LASTEXITCODE) { 0 } else { [int]$global:LASTEXITCODE }
  $commandLine = Format-CommandLine -FileName $FileName -Arguments $Arguments

  if ($exitCode -eq 0) {
    Write-SafeHost "[OK] $Label"
    foreach ($line in $output | Select-Object -Last 8) {
      if (-not [string]::IsNullOrWhiteSpace($line)) {
        Write-SafeHost $line
      }
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output; Command = $commandLine; Classification = "pass" }
  }

  $joined = Redact-SafeText ($output -join "`n")
  if ($ExternalTool -and (Test-BlockerOutput $joined)) {
    Add-Blocker "[BLOCKED] $Label - external tool/package cache unavailable while running: $commandLine"
    $classification = "blocker"
  } else {
    Add-Failure "[FAIL] $Label - exit $exitCode while running: $commandLine`n$joined"
    $classification = "failure"
  }
  return [pscustomobject]@{ ExitCode = $exitCode; Output = $output; Command = $commandLine; Classification = $classification }
}

function Invoke-ContractGate {
  $ps = Get-PowerShellRunner
  if ($null -eq $ps) {
    Add-Blocker "[BLOCKED] lightweight OpenAPI contract gate - powershell/pwsh not found"
    return
  }

  [void](Invoke-Process `
      -FileName $ps.Source `
      -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $contractGatePath, "-OpenApiPath", $OpenApiPath) `
      -Label "lightweight ledger execute OpenAPI contract gate")
}

function Get-PowerShellRunner {
  $ps = Get-Command powershell -ErrorAction SilentlyContinue
  if ($null -eq $ps) {
    $ps = Get-Command pwsh -ErrorAction SilentlyContinue
  }
  return $ps
}

function New-NpmExecArguments {
  param(
    [Parameter(Mandatory = $true)][string]$Package,
    [Parameter(Mandatory = $true)][string[]]$ToolArguments
  )

  $arguments = @("exec", "--yes")
  if (-not $AllowPackageDownload) {
    $arguments += "--offline"
  }
  $arguments += @("--package", $Package, "--")
  $arguments += $ToolArguments
  return $arguments
}

function Invoke-NpmTool {
  param(
    [Parameter(Mandatory = $true)][string]$Package,
    [Parameter(Mandatory = $true)][string[]]$ToolArguments,
    [Parameter(Mandatory = $true)][string]$Label,
    [Parameter(Mandatory = $true)][string]$ToolName,
    [Parameter(Mandatory = $true)][string]$EvidenceKind,
    [string[]]$VersionToolArguments = @(),
    [switch]$RequireJava
  )

  try {
    Assert-ToolAvailable -Name "node" -Reason "Node is required for npm OpenAPI tools"
    Assert-ToolAvailable -Name "npm" -Reason "npm is required for npm OpenAPI tools"
    if ($RequireJava) {
      Assert-ToolAvailable -Name "java" -Reason "Java is required by @openapitools/openapi-generator-cli"
    }
  } catch {
    Add-Blocker "[BLOCKED] $Label - $($_.Exception.Message)"
    Add-EvidenceRecord `
      -Kind $EvidenceKind `
      -Label $Label `
      -Tool $ToolName `
      -ToolVersion "unavailable" `
      -Package $Package `
      -Classification "blocker" `
      -ExitCode 2 `
      -Command "$ToolName not run" `
      -Output @($_.Exception.Message) `
      -BlockerReason "required local tool unavailable"
    return
  }

  New-Item -ItemType Directory -Force $NpmCache | Out-Null
  $oldCache = $env:npm_config_cache
  try {
    $env:npm_config_cache = $NpmCache
    $toolVersion = "not_requested"
    if ($VersionToolArguments.Count -gt 0) {
      $versionResult = Invoke-Process `
        -FileName "npm" `
        -Arguments (New-NpmExecArguments -Package $Package -ToolArguments $VersionToolArguments) `
        -Label "$Label version probe" `
        -ExternalTool

      if ($versionResult.ExitCode -ne 0) {
        $versionFailureReason = ""
        $versionBlockerReason = ""
        if ($versionResult.Classification -eq "failure") {
          $versionFailureReason = "version probe failed before requested check"
        } elseif ($versionResult.Classification -eq "blocker") {
          $versionBlockerReason = "version probe was externally blocked before requested check"
        }
        Add-EvidenceRecord `
          -Kind $EvidenceKind `
          -Label $Label `
          -Tool $ToolName `
          -ToolVersion "unavailable" `
          -Package $Package `
          -Classification $versionResult.Classification `
          -ExitCode $versionResult.ExitCode `
          -Command $versionResult.Command `
          -Output $versionResult.Output `
          -FailureReason $versionFailureReason `
          -BlockerReason $versionBlockerReason
        return $versionResult
      }

      $versionLines = @(Get-BoundedSafeLines -Lines $versionResult.Output -TakeLast 4 -MaxLineLength 120)
      if ($versionLines.Count -gt 0) {
        $toolVersion = $versionLines[0]
      } else {
        $toolVersion = "unknown"
      }
    }

    $result = Invoke-Process `
      -FileName "npm" `
      -Arguments (New-NpmExecArguments -Package $Package -ToolArguments $ToolArguments) `
      -Label $Label `
      -ExternalTool

    $failureReason = ""
    $blockerReason = ""
    if ($result.Classification -eq "failure") {
      $failureReason = "requested semantic/client contract check failed"
    } elseif ($result.Classification -eq "blocker") {
      $blockerReason = "external tool/package cache unavailable"
    }
    Add-EvidenceRecord `
      -Kind $EvidenceKind `
      -Label $Label `
      -Tool $ToolName `
      -ToolVersion $toolVersion `
      -Package $Package `
      -Classification $result.Classification `
      -ExitCode $result.ExitCode `
      -Command $result.Command `
      -Output $result.Output `
      -FailureReason $failureReason `
      -BlockerReason $blockerReason
    return $result
  } finally {
    $env:npm_config_cache = $oldCache
  }
}

function Assert-FileContains {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string[]]$Needles,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if (-not (Test-Path $Path)) {
    Add-Failure "[FAIL] $Label - missing generated file $Path"
    return
  }

  $text = Get-Content -Path $Path -Raw
  foreach ($needle in $Needles) {
    if (-not $text.Contains($needle)) {
      Add-Failure "[FAIL] $Label - generated output is missing '$needle'"
    }
  }
}

function Assert-TreeContainsAny {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string[]]$Needles,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if (-not (Test-Path $Path)) {
    Add-Failure "[FAIL] $Label - missing generated directory $Path"
    return
  }

  $files = @(Get-ChildItem -Path $Path -Recurse -File -Include *.ts,*.tsx,*.js,*.json,*.md 2>$null)
  $text = ($files | ForEach-Object { Get-Content -Path $_.FullName -Raw }) -join "`n"
  foreach ($needle in $Needles) {
    if (-not $text.Contains($needle)) {
      Add-Failure "[FAIL] $Label - generated tree is missing '$needle'"
    }
  }
}

function Assert-TreeContainsOneOf {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string[]]$Needles,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if (-not (Test-Path $Path)) {
    Add-Failure "[FAIL] $Label - missing generated directory $Path"
    return
  }

  $files = @(Get-ChildItem -Path $Path -Recurse -File -Include *.ts,*.tsx,*.js,*.json,*.md 2>$null)
  $text = ($files | ForEach-Object { Get-Content -Path $_.FullName -Raw }) -join "`n"
  foreach ($needle in $Needles) {
    if ($text.Contains($needle)) {
      return
    }
  }
  Add-Failure "[FAIL] $Label - generated tree is missing one of: $($Needles -join ", ")"
}

function Get-GeneratedClientRequiredModels {
  return @(
    "LedgerAdjustmentExecuteResult",
    "LedgerAdjustmentExecuteContractEnvelope",
    "LedgerAdjustmentExecuteContract",
    "LedgerAdjustmentExecutorSummaryContract",
    "LedgerAdjustmentExecutorRefusalSummaryContract",
    "LedgerAdjustmentExecutorRollbackSummaryContract",
    "LedgerAdjustmentExecutorSummary"
  )
}

function Get-GeneratedClientRequiredFieldGroups {
  $groups = New-Object System.Collections.Generic.List[object]
  foreach ($group in @(
      @("ledger_executor_summary_contract", "ledgerExecutorSummaryContract"),
      @("ledger_executor_summary", "ledgerExecutorSummary"),
      @("transaction_contract", "transactionContract"),
      @("rollback_executor_summary_contract", "rollbackExecutorSummaryContract"),
      @("ledger_executor_refusal_summary_contract", "ledgerExecutorRefusalSummaryContract"),
      @("preflight_refusal_summary", "preflightRefusalSummary"),
      @("schema_version", "schemaVersion"),
      @("response_field", "responseField"),
      @("operation_key_output", "operationKeyOutput"),
      @("error_detail_output", "errorDetailOutput"),
      @("dedupe_material_echoed", "dedupeMaterialEchoed"),
      @("raw_metadata_echoed", "rawMetadataEchoed"),
      @("credential_material_echoed", "credentialMaterialEchoed"),
      @("raw_executor_error_detail_echoed", "rawExecutorErrorDetailEchoed"),
      @("committed"),
      @("rolled_back", "rolledBack"),
      @("statement_count", "statementCount"),
      @("executed_statement_count", "executedStatementCount"),
      @("refused_statement_count", "refusedStatementCount"),
      @("total_rows_affected", "totalRowsAffected"),
      @("final_statement_order", "finalStatementOrder"),
      @("final_statement_kind", "finalStatementKind"),
      @("row_count_mismatch", "rowCountMismatch"),
      @("omitted_material", "omittedMaterial")
    )) {
    [void]$groups.Add([pscustomobject]@{ Candidates = @($group) })
  }
  return @($groups.ToArray())
}

function Get-GeneratedClientModelRequiredFieldGroups {
  param([Parameter(Mandatory = $true)][string]$Model)

  $groups = New-Object System.Collections.Generic.List[object]
  $rawGroups = switch ($Model) {
    "LedgerAdjustmentExecuteResult" {
      @(
        @("ledger_executor_summary_contract", "ledgerExecutorSummaryContract"),
        @("ledger_executor_summary", "ledgerExecutorSummary"),
        @("transaction_contract", "transactionContract"),
        @("ledger_entry", "ledgerEntry"),
        @("validated_plan", "validatedPlan")
      )
    }
    "LedgerAdjustmentExecuteContractEnvelope" {
      @(
        @("ledger_executor_summary", "ledgerExecutorSummary"),
        @("execute_contract", "executeContract")
      )
    }
    "LedgerAdjustmentExecuteContract" {
      @(
        @("ledger_executor_summary_contract", "ledgerExecutorSummaryContract"),
        @("ledger_executor_refusal_summary_contract", "ledgerExecutorRefusalSummaryContract"),
        @("preflight_refusal_summary", "preflightRefusalSummary"),
        @("rollback_executor_summary_contract", "rollbackExecutorSummaryContract")
      )
    }
    "LedgerAdjustmentExecutorSummaryContract" {
      @(
        @("schema_version", "schemaVersion"),
        @("response_field", "responseField"),
        @("operation_key_output", "operationKeyOutput"),
        @("error_detail_output", "errorDetailOutput"),
        @("dedupe_material_echoed", "dedupeMaterialEchoed"),
        @("raw_metadata_echoed", "rawMetadataEchoed"),
        @("credential_material_echoed", "credentialMaterialEchoed")
      )
    }
    "LedgerAdjustmentExecutorSummary" {
      @(
        @("schema_version", "schemaVersion"),
        @("operation_key_output", "operationKeyOutput"),
        @("error_detail_output", "errorDetailOutput"),
        @("committed"),
        @("rolled_back", "rolledBack"),
        @("statement_count", "statementCount"),
        @("executed_statement_count", "executedStatementCount"),
        @("refused_statement_count", "refusedStatementCount"),
        @("total_rows_affected", "totalRowsAffected"),
        @("final_statement_order", "finalStatementOrder"),
        @("final_statement_kind", "finalStatementKind"),
        @("row_count_mismatch", "rowCountMismatch"),
        @("omitted_material", "omittedMaterial")
      )
    }
    default {
      @()
    }
  }

  foreach ($group in $rawGroups) {
    [void]$groups.Add([pscustomobject]@{ Candidates = @($group) })
  }
  return @($groups.ToArray())
}

function Get-GeneratedClientForbiddenFieldPatterns {
  return @(
    "(?i)\bidempotency_key\b\s*[?:]",
    "(?i)\bidempotencyKey\b\s*[?:]",
    "(?i)\bauthorization\b\s*[?:]",
    "(?i)\bcookie\b\s*[?:]",
    "(?i)\bprovider_key\b\s*[?:]",
    "(?i)\bproviderKey\b\s*[?:]",
    "(?i)\boperation_key\b\s*[?:]",
    "(?i)\boperationKey\b\s*[?:]",
    "(?i)\bapi_key\b\s*[?:]",
    "(?i)\bapiKey\b\s*[?:]",
    "(?i)\braw_metadata\b\s*[?:]",
    "(?i)\brawMetadata\b\s*[?:]",
    "(?i)\braw_headers\b\s*[?:]",
    "(?i)\brawHeaders\b\s*[?:]",
    "(?i)\brequest_body\b\s*[?:]",
    "(?i)\brequestBody\b\s*[?:]",
    "(?i)\bpayload\b\s*[?:]",
    "(?i)\bbody\b\s*[?:]",
    "(?i)\bcredentials?\b\s*[?:]",
    "(?i)\bsecrets?\b\s*[?:]",
    "(?i)\btokens?\b\s*[?:]",
    "(?i)Bearer\s+[A-Za-z0-9._~+/\-]+=*",
    "sk-[A-Za-z0-9._~+/\-]{8,}"
  )
}

function Test-GeneratedClientTextContainsField {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [Parameter(Mandatory = $true)][string]$Field
  )

  $pattern = "(?<![A-Za-z0-9_])" + [regex]::Escape($Field) + "(?![A-Za-z0-9_])"
  return [regex]::IsMatch($Text, $pattern)
}

function Get-GeneratedClientFiles {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (Test-Path $Path -PathType Leaf) {
    return @(Get-Item -Path $Path)
  }

  if (Test-Path $Path -PathType Container) {
    return @(Get-ChildItem -Path $Path -Recurse -File -Include *.ts,*.tsx,*.js,*.json,*.md 2>$null)
  }

  return @()
}

function Get-GeneratedClientInspectionText {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string[]]$Models
  )

  $snippets = New-Object System.Collections.Generic.List[string]
  foreach ($file in @(Get-GeneratedClientFiles -Path $Path)) {
    $content = Get-Content -Path $file.FullName -Raw
    $fileNameMatched = $false
    foreach ($model in $Models) {
      if ($file.Name.Contains($model)) {
        $fileNameMatched = $true
        break
      }
    }
    if ($fileNameMatched) {
      [void]$snippets.Add($content)
      continue
    }

    $lines = @($content -split "`r?`n")
    for ($index = 0; $index -lt $lines.Count; $index += 1) {
      $matched = $false
      foreach ($model in $Models) {
        if ($lines[$index].Contains($model) -or $lines[$index].Contains("ledger_executor_summary") -or $lines[$index].Contains("ledgerExecutorSummary")) {
          $matched = $true
          break
        }
      }
      if ($matched) {
        $end = [Math]::Min($lines.Count - 1, $index + 140)
        [void]$snippets.Add(($lines[$index..$end] -join "`n"))
      }
    }
  }

  return ($snippets.ToArray() -join "`n")
}

function Get-GeneratedClientModelText {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Model,
    [Parameter(Mandatory = $true)][string[]]$Models
  )

  $snippets = New-Object System.Collections.Generic.List[string]
  foreach ($file in @(Get-GeneratedClientFiles -Path $Path)) {
    $content = Get-Content -Path $file.FullName -Raw
    if ($file.Name.Contains($Model)) {
      [void]$snippets.Add($content)
      continue
    }

    $lines = @($content -split "`r?`n")
    for ($index = 0; $index -lt $lines.Count; $index += 1) {
      if (-not $lines[$index].Contains($Model)) {
        continue
      }

      $end = [Math]::Min($lines.Count - 1, $index + 220)
      for ($cursor = $index + 1; $cursor -le $end; $cursor += 1) {
        foreach ($otherModel in $Models) {
          if ($otherModel -eq $Model) {
            continue
          }
          $boundary = "^\s*(?:""?" + [regex]::Escape($otherModel) + """?\s*:|export\s+(?:interface|type)\s+" + [regex]::Escape($otherModel) + "\b)"
          if ($lines[$cursor] -match $boundary) {
            $end = [Math]::Max($index, $cursor - 1)
            break
          }
        }
      }
      [void]$snippets.Add(($lines[$index..$end] -join "`n"))
    }
  }

  return ($snippets.ToArray() -join "`n")
}

function Assert-GeneratedClientInspectionContract {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if (-not (Test-Path $Path)) {
    Add-Failure "[FAIL] $Label - generated client path is missing: $Path"
    return
  }

  $models = @(Get-GeneratedClientRequiredModels)
  $files = @(Get-GeneratedClientFiles -Path $Path)
  $allText = ($files | ForEach-Object { Get-Content -Path $_.FullName -Raw }) -join "`n"
  $inspectionText = Get-GeneratedClientInspectionText -Path $Path -Models $models
  if ([string]::IsNullOrWhiteSpace($inspectionText)) {
    Add-Failure "[FAIL] $Label - generated client did not expose ledger execute inspection text"
    return
  }

  foreach ($model in $models) {
    if (-not $allText.Contains($model)) {
      Add-Failure "[FAIL] $Label - generated client is missing model '$model'"
    }
  }

  foreach ($group in @(Get-GeneratedClientRequiredFieldGroups)) {
    $found = $false
    foreach ($candidate in @($group.Candidates)) {
      if (Test-GeneratedClientTextContainsField -Text $inspectionText -Field ([string]$candidate)) {
        $found = $true
        break
      }
    }
    if (-not $found) {
      Add-Failure "[FAIL] $Label - generated ledger execute contract is missing one of: $($group.Candidates -join ", ")"
    }
  }

  foreach ($pattern in @(Get-GeneratedClientForbiddenFieldPatterns)) {
    if ($inspectionText -match $pattern) {
      Add-Failure "[FAIL] $Label - generated ledger execute contract contains forbidden secret-like field pattern '$pattern'"
    }
  }

  foreach ($model in $models) {
    $modelText = Get-GeneratedClientModelText -Path $Path -Model $model -Models $models
    if ([string]::IsNullOrWhiteSpace($modelText)) {
      Add-Failure "[FAIL] $Label - generated client is missing inspectable model text for '$model'"
      continue
    }

    foreach ($group in @(Get-GeneratedClientModelRequiredFieldGroups -Model $model)) {
      $found = $false
      foreach ($candidate in @($group.Candidates)) {
        if (Test-GeneratedClientTextContainsField -Text $modelText -Field ([string]$candidate)) {
          $found = $true
          break
        }
      }
      if (-not $found) {
        Add-Failure "[FAIL] $Label - generated model '$model' is missing one of: $($group.Candidates -join ", ")"
      }
    }

    foreach ($pattern in @(Get-GeneratedClientForbiddenFieldPatterns)) {
      if ($modelText -match $pattern) {
        Add-Failure "[FAIL] $Label - generated model '$model' contains forbidden secret-like field pattern '$pattern'"
      }
    }
  }
}

function Write-SimulatedGeneratedClientFixture {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [switch]$MissingRequired
  )

  Remove-Item -Recurse -Force $Path -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force $Path | Out-Null

  $summaryField = if ($MissingRequired) { "" } else { "  ledger_executor_summary: LedgerAdjustmentExecutorSummary;" }
  $content = @"
export interface LedgerAdjustmentExecuteResult {
  mode: "execute";
  outcome: "applied" | "idempotent";
  ledger_write: boolean;
  audit_log_write: boolean;
  ledger_executor_summary_contract: LedgerAdjustmentExecutorSummaryContract;
$summaryField
  transaction_contract: object;
  ledger_entry: object;
  validated_plan: object;
}

export interface LedgerAdjustmentExecuteContractEnvelope {
  error: object;
  data: {
    mode: "execute_contract";
    validated_plan: object;
    ledger_executor_summary: LedgerAdjustmentExecutorSummary;
    execute_contract: LedgerAdjustmentExecuteContract;
  };
}

export interface LedgerAdjustmentExecuteContract {
  ledger_executor_summary_contract: LedgerAdjustmentExecutorSummaryContract;
  ledger_executor_refusal_summary_contract: LedgerAdjustmentExecutorRefusalSummaryContract;
  preflight_refusal_summary: LedgerAdjustmentExecutorSummary;
  transaction_contract: {
    rollback_executor_summary_contract: LedgerAdjustmentExecutorRollbackSummaryContract;
  };
}

export interface LedgerAdjustmentExecutorSummaryContract {
  schema_version: "billing_ledger_postgres_executor_summary.v1";
  response_field: "ledger_executor_summary";
  operation_key_output: "omitted";
  error_detail_output: "omitted";
  dedupe_material_echoed: false;
  raw_metadata_echoed: false;
  credential_material_echoed: false;
}

export interface LedgerAdjustmentExecutorRefusalSummaryContract {
  schema_version: "billing_ledger_postgres_executor_summary.v1";
  response_field: "ledger_executor_summary";
  raw_executor_error_detail_echoed: false;
  operation_key_output: "omitted";
  error_detail_output: "omitted";
}

export interface LedgerAdjustmentExecutorRollbackSummaryContract {
  schema_version: "billing_ledger_postgres_executor_summary.v1";
  response_field: "ledger_executor_summary";
  raw_executor_error_detail_echoed: false;
}

export interface LedgerAdjustmentExecutorSummary {
  schema_version: "billing_ledger_postgres_executor_summary.v1";
  executor: "control_plane_transactional_admin_ledger_adjustment_writer";
  operation: "adjust" | "refund";
  outcome: "applied" | "idempotent" | "refused_preflight" | "refused_rollback";
  operation_key_output: "omitted";
  error_detail_output: "omitted";
  committed: boolean;
  rolled_back: boolean;
  statement_count: number;
  executed_statement_count: number;
  refused_statement_count: number;
  total_rows_affected: number;
  final_statement_order: number | null;
  final_statement_kind: string | null;
  row_count_mismatch: boolean;
  dedupe_material_echoed: false;
  raw_metadata_echoed: false;
  credential_material_echoed: false;
  raw_executor_error_detail_echoed: false;
  omitted_material: string[];
}
"@

  Set-Content -Path (Join-Path $Path "ledger-execute-generated.ts") -Value $content -Encoding ascii
}

function Add-SimulatedSemanticEvidence {
  param(
    [Parameter(Mandatory = $true)][ValidateSet("pass", "failure", "blocker")][string]$Classification,
    [Parameter(Mandatory = $true)][int]$ExitCode
  )

  $sensitiveTail = @(
    "simulated semantic validator checked ledger execute schemas",
    "Authorization: Bearer selftest-token-123456789",
    "Cookie: session=selftest-cookie",
    "operation_key=selftest-operation-key",
    "raw_metadata={never-return}",
    "schema=examples/openapi_admin_skeleton.yaml"
  )
  $failureReason = ""
  $blockerReason = ""
  if ($Classification -eq "failure") {
    $failureReason = "simulated semantic validator schema mismatch"
  } elseif ($Classification -eq "blocker") {
    $blockerReason = "simulated semantic validator package cache blocker"
  }

  Add-EvidenceRecord `
    -Kind "semantic_validator" `
    -Label "simulated semantic validator evidence $Classification" `
    -Tool "redocly-simulated" `
    -ToolVersion "simulated-1.0.0" `
    -Package "@redocly/cli" `
    -Classification $Classification `
    -ExitCode $ExitCode `
    -Command "redocly lint examples/openapi_admin_skeleton.yaml --operation_key=selftest-operation-key" `
    -Output $sensitiveTail `
    -FailureReason $failureReason `
    -BlockerReason $blockerReason `
    -ProvenanceMode "simulated"
}

function Invoke-Redocly {
  Invoke-NpmTool `
    -Package "@redocly/cli" `
    -ToolArguments @("redocly", "lint", $OpenApiPath) `
    -Label "Redocly semantic OpenAPI validation" `
    -ToolName "redocly" `
    -EvidenceKind "semantic_validator" `
    -VersionToolArguments @("redocly", "--version")
}

function Invoke-OpenApiGeneratorValidate {
  Invoke-NpmTool `
    -Package "@openapitools/openapi-generator-cli" `
    -ToolArguments @("openapi-generator-cli", "validate", "-i", $OpenApiPath) `
    -ToolName "openapi-generator-cli" `
    -EvidenceKind "semantic_validator" `
    -VersionToolArguments @("openapi-generator-cli", "version") `
    -Label "OpenAPI Generator semantic validation" `
    -RequireJava
}

function Invoke-OpenApiTypescript {
  $outDir = Join-Path $TempRoot "openapi-typescript"
  $outFile = Join-Path $outDir "admin-api.d.ts"
  New-Item -ItemType Directory -Force $outDir | Out-Null
  Remove-Item -Force $outFile -ErrorAction SilentlyContinue

  Invoke-NpmTool `
    -Package "openapi-typescript" `
    -ToolArguments @("openapi-typescript", $OpenApiPath, "-o", $outFile) `
    -ToolName "openapi-typescript" `
    -EvidenceKind "client_generation" `
    -VersionToolArguments @("openapi-typescript", "--version") `
    -Label "openapi-typescript client type generation"

  if ($script:Blockers.Count -eq 0) {
    Assert-GeneratedClientInspectionContract -Path $outFile -Label "openapi-typescript ledger execute generated-client inspection"
  }
}

function Invoke-TypescriptFetch {
  $outDir = Join-Path $TempRoot "typescript-fetch"
  Remove-Item -Recurse -Force $outDir -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force $outDir | Out-Null

  Invoke-NpmTool `
    -Package "@openapitools/openapi-generator-cli" `
    -ToolArguments @(
      "openapi-generator-cli",
      "generate",
      "-i",
      $OpenApiPath,
      "-g",
      "typescript-fetch",
      "-o",
      $outDir,
      "--additional-properties=typescriptThreePlus=true,enumUnknownDefaultCase=true"
    ) `
    -ToolName "openapi-generator-cli" `
    -EvidenceKind "client_generation" `
    -VersionToolArguments @("openapi-generator-cli", "version") `
    -Label "OpenAPI Generator typescript-fetch client generation" `
    -RequireJava

  if ($script:Blockers.Count -eq 0) {
    Assert-GeneratedClientInspectionContract -Path $outDir -Label "typescript-fetch ledger execute generated-client inspection"
  }
}

function Assert-SelfTestOutputSecretSafe {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [AllowEmptyString()][AllowEmptyCollection()][string[]]$Output = @()
  )

  $text = $Output -join "`n"
  foreach ($pattern in @(
      "(?i)Authorization\s*[:=]",
      "(?i)Cookie\s*[:=]",
      "(?i)Bearer\s+[A-Za-z0-9._~+/\-]+=*",
      "sk-[A-Za-z0-9._~+/\-]{8,}",
      "(?i)(password|passwd|secret|token|credential|api[_-]?key|operation[_-]?key|package[_-]?token|npm[_-]?token|raw[_-]?metadata|metadata)\s*[:=]\s*[^,\s]+",
      "(?i)https?://[^/\s:@]+:[^/\s@]+@"
    )) {
    if ($text -match $pattern) {
      Add-Failure "[FAIL] self-test output secret-safe check - $Name printed forbidden material pattern"
      return
    }
  }
}

function Invoke-SelfTestChild {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [string[]]$Arguments = @(),
    [string]$ChildTempRoot = $TempRoot,
    [string]$ChildNpmCache = $NpmCache,
    [Parameter(Mandatory = $true)][int]$ExpectedExitCode,
    [string[]]$ExpectedEvidenceClassifications = @(),
    [ValidateSet("", "real", "simulated", "mixed")][string]$ExpectedProvenanceMode = "",
    [switch]$ExpectedEvidenceAbsent
  )

  $ps = Get-PowerShellRunner
  if ($null -eq $ps) {
    Add-Blocker "[BLOCKED] self-test child runner - powershell/pwsh not found"
    return
  }

  $childArgs = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    $PSCommandPath,
    "-OpenApiPath",
    $OpenApiPath,
    "-TempRoot",
    $ChildTempRoot,
    "-NpmCache",
    $ChildNpmCache
  ) + $Arguments

  $global:LASTEXITCODE = 0
  $oldErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    $output = @(& $ps.Source @childArgs 2>&1 | ForEach-Object { [string]$_ })
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }

  $exitCode = if ($null -eq $global:LASTEXITCODE) { 0 } else { [int]$global:LASTEXITCODE }
  Assert-SelfTestOutputSecretSafe -Name $Name -Output $output

  if ($exitCode -ne $ExpectedExitCode) {
    Add-Failure "[FAIL] self-test $Name - expected exit $ExpectedExitCode, got exit $exitCode"
    foreach ($line in $output | Select-Object -Last 12) {
      if (-not [string]::IsNullOrWhiteSpace($line)) {
        Write-SafeHost $line
      }
    }
    return
  }

  Write-SafeHost "[OK] self-test $Name returned exit $ExpectedExitCode"

  if ($ExpectedEvidenceClassifications.Count -gt 0) {
    Assert-EvidenceReportContract `
      -Path (Get-EvidenceReportPath -Root $ChildTempRoot) `
      -ExpectedClassifications $ExpectedEvidenceClassifications `
      -ExpectedProvenanceMode $ExpectedProvenanceMode
  }

  if ($ExpectedEvidenceAbsent) {
    $evidencePath = Get-EvidenceReportPath -Root $ChildTempRoot
    if (Test-Path $evidencePath) {
      Add-Failure "[FAIL] self-test $Name - evidence report remained at $(Format-BoundedPath $evidencePath)"
    } else {
      Write-SafeHost "[OK] self-test $Name left no evidence report"
    }
  }
}

function Invoke-SelfTest {
  Write-SafeHost "Control Plane ledger adjustment OpenAPI semantic wrapper self-test"
  Write-SafeHost "Self-test uses only the lightweight gate and simulated outcomes; it does not run npm tools, generate clients, or call live services."

  $defaultNoEvidenceRoot = Join-Path $TempRoot "self-test-default-lightweight-no-evidence"
  New-Item -ItemType Directory -Force $defaultNoEvidenceRoot | Out-Null
  Set-Content -Path (Get-EvidenceReportPath -Root $defaultNoEvidenceRoot) -Value "stale evidence should be removed" -Encoding ascii
  Invoke-SelfTestChild `
    -Name "default lightweight path clears stale evidence" `
    -Arguments @() `
    -ChildTempRoot $defaultNoEvidenceRoot `
    -ExpectedExitCode 0 `
    -ExpectedEvidenceAbsent
  Invoke-SelfTestChild -Name "simulated external blocker" -Arguments @("-SimulateExternalBlocker") -ExpectedExitCode 2
  Invoke-SelfTestChild -Name "simulated schema mismatch" -Arguments @("-SimulateSchemaMismatch") -ExpectedExitCode 1
  Invoke-SelfTestChild -Name "simulated client mismatch" -Arguments @("-SimulateClientMismatch") -ExpectedExitCode 1
  Invoke-SelfTestChild -Name "sensitive success output tail redacted" -Arguments @("-SimulateSensitiveOutputTail") -ExpectedExitCode 0
  Invoke-SelfTestChild -Name "sensitive failing command display redacted" -Arguments @("-SimulateSensitiveCommandFailure") -ExpectedExitCode 1
  Invoke-SelfTestChild -Name "simulated generated-client inspection pass" -Arguments @("-SimulateGeneratedClientInspectionPass") -ExpectedExitCode 0
  Invoke-SelfTestChild -Name "simulated generated-client missing required field" -Arguments @("-SimulateGeneratedClientMissingRequired") -ExpectedExitCode 1
  Invoke-SelfTestChild `
    -Name "simulated semantic validator evidence pass" `
    -Arguments @("-SimulateSemanticEvidencePass") `
    -ChildTempRoot (Join-Path $TempRoot "self-test-semantic-evidence-pass") `
    -ExpectedExitCode 0 `
    -ExpectedEvidenceClassifications @("pass") `
    -ExpectedProvenanceMode "simulated"
  Invoke-SelfTestChild `
    -Name "simulated semantic validator evidence failure" `
    -Arguments @("-SimulateSemanticEvidenceFailure") `
    -ChildTempRoot (Join-Path $TempRoot "self-test-semantic-evidence-failure") `
    -ExpectedExitCode 1 `
    -ExpectedEvidenceClassifications @("failure") `
    -ExpectedProvenanceMode "simulated"
  Invoke-SelfTestChild `
    -Name "simulated semantic validator evidence blocker" `
    -Arguments @("-SimulateSemanticEvidenceBlocker") `
    -ChildTempRoot (Join-Path $TempRoot "self-test-semantic-evidence-blocker") `
    -ExpectedExitCode 2 `
    -ExpectedEvidenceClassifications @("blocker") `
    -ExpectedProvenanceMode "simulated"
  Invoke-SelfTestChild -Name "temp root repo escape rejected" -Arguments @() -ChildTempRoot (Join-Path $repoRoot "..\ledger-openapi-outside") -ExpectedExitCode 1
  Invoke-SelfTestChild -Name "source temp root rejected" -Arguments @() -ChildTempRoot (Join-Path $repoRoot "scripts\ledger-openapi-semantic") -ExpectedExitCode 1
  Invoke-SelfTestChild -Name "git temp root rejected" -Arguments @() -ChildTempRoot (Join-Path $repoRoot ".git\ledger-openapi-semantic") -ExpectedExitCode 1
  Invoke-SelfTestChild -Name "npm cache repo escape rejected" -Arguments @() -ChildNpmCache (Join-Path $repoRoot "..\ledger-openapi-cache-outside") -ExpectedExitCode 1

  $cleanupProbe = Join-Path $TempRoot "self-test-cleanup-marker.txt"
  $cleanupEvidence = Get-EvidenceReportPath
  $cleanupOwnedDir = Join-Path $TempRoot "openapi-typescript"
  $cleanupNonOwnedProbe = Join-Path $TempRoot "self-test-non-owned-cleanup-marker.txt"
  New-Item -ItemType Directory -Force $TempRoot | Out-Null
  New-Item -ItemType Directory -Force $cleanupOwnedDir | Out-Null
  Set-Content -Path $cleanupProbe -Value "wrapper-owned cleanup marker" -Encoding ascii
  Set-Content -Path $cleanupEvidence -Value "stale evidence should be removed by clean" -Encoding ascii
  Set-Content -Path $cleanupNonOwnedProbe -Value "non-owned marker should survive child clean" -Encoding ascii
  Invoke-SelfTestChild -Name "artifact cleanup removes wrapper-owned artifacts" -Arguments @("-Clean") -ExpectedExitCode 0 -ExpectedEvidenceAbsent
  if (Test-Path $cleanupProbe) {
    Add-Failure "[FAIL] self-test artifact cleanup - wrapper-owned marker remained after -Clean"
  } elseif (Test-Path $cleanupEvidence) {
    Add-Failure "[FAIL] self-test artifact cleanup - stale evidence report remained after -Clean"
  } elseif (Test-Path $cleanupOwnedDir) {
    Add-Failure "[FAIL] self-test artifact cleanup - generated client artifact remained after -Clean"
  } elseif (-not (Test-Path $cleanupNonOwnedProbe)) {
    Add-Failure "[FAIL] self-test artifact cleanup - non-owned temp marker was removed by -Clean"
  } else {
    Write-SafeHost "[OK] self-test artifact cleanup removed wrapper-owned artifacts and preserved non-owned temp marker"
  }
  Remove-Item -Force $cleanupNonOwnedProbe -ErrorAction SilentlyContinue
  if (Test-Path $TempRoot -PathType Container) {
    $remaining = @(Get-ChildItem -LiteralPath $TempRoot -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($remaining.Count -eq 0) {
      Remove-Item -Force $TempRoot -ErrorAction SilentlyContinue
    }
  }

  Exit-WithResult
}

if ($Clean) {
  Remove-WrapperOwnedTempArtifacts
  Write-SafeHost "[OK] cleaned wrapper-owned temp artifacts under: $(Format-BoundedPath $TempRoot)"
} else {
  Clear-StaleEvidenceReport
}

if (-not (Test-Path $OpenApiPath)) {
  Add-Failure "[FAIL] OpenAPI skeleton missing: $OpenApiPath"
  Exit-WithResult
}

if ($SelfTest) {
  Invoke-SelfTest
}

Write-SafeHost "Control Plane ledger adjustment OpenAPI semantic wrapper"
Write-SafeHost "OpenAPI: $(Format-BoundedPath $OpenApiPath)"
Write-SafeHost "TempRoot: $(Format-BoundedPath $TempRoot)"
Write-SafeHost "NpmCache: $(Format-BoundedPath $NpmCache)"
Write-SafeHost "Package download allowed: $([bool]$AllowPackageDownload)"

Invoke-ContractGate
if ($script:Failures.Count -gt 0 -or $script:Blockers.Count -gt 0) {
  Exit-WithResult
}

if ($SimulateExternalBlocker) {
  Add-Blocker "[BLOCKED] simulated external semantic-tool blocker - package cache or local tool unavailable"
  Exit-WithResult
}
if ($SimulateSchemaMismatch) {
  Add-Failure "[FAIL] simulated OpenAPI schema mismatch - ledger execute response contract drift"
  Exit-WithResult
}
if ($SimulateClientMismatch) {
  Add-Failure "[FAIL] simulated generated-client contract mismatch - ledger executor summary field drift"
  Exit-WithResult
}
if ($SimulateSensitiveOutputTail) {
  $ps = Get-PowerShellRunner
  [void](Invoke-Process `
      -FileName $ps.Source `
      -Arguments @(
        "-NoProfile",
        "-Command",
        "Write-Output 'Authorization: Bearer selftest-token-123456789'; Write-Output 'Cookie: session=selftest-cookie'; Write-Output 'api_key=selftest-api-key'; Write-Output 'operation_key=selftest-operation-key'; Write-Output 'raw_metadata={never-return}'"
      ) `
      -Label "simulated sensitive output tail")
  Exit-WithResult
}
if ($SimulateSensitiveCommandFailure) {
  $ps = Get-PowerShellRunner
  [void](Invoke-Process `
      -FileName $ps.Source `
      -Arguments @(
        "-NoProfile",
        "-Command",
        "Write-Error 'Authorization: Bearer selftest-token-123456789 package_token=selftest-package-token raw_metadata={never-return}'; exit 9"
      ) `
      -Label "simulated sensitive command failure")
  Exit-WithResult
}
if ($SimulateGeneratedClientInspectionPass) {
  $path = Join-Path $TempRoot "self-test-generated-client-pass"
  Write-SimulatedGeneratedClientFixture -Path $path
  Assert-GeneratedClientInspectionContract -Path $path -Label "simulated generated-client inspection pass"
  Exit-WithResult
}
if ($SimulateGeneratedClientMissingRequired) {
  $path = Join-Path $TempRoot "self-test-generated-client-missing-required"
  Write-SimulatedGeneratedClientFixture -Path $path -MissingRequired
  Assert-GeneratedClientInspectionContract -Path $path -Label "simulated generated-client missing required field"
  Exit-WithResult
}
if ($SimulateSemanticEvidencePass) {
  Add-SimulatedSemanticEvidence -Classification "pass" -ExitCode 0
  Exit-WithResult
}
if ($SimulateSemanticEvidenceFailure) {
  Add-SimulatedSemanticEvidence -Classification "failure" -ExitCode 1
  Add-Failure "[FAIL] simulated semantic validator evidence failure - ledger execute schema drift"
  Exit-WithResult
}
if ($SimulateSemanticEvidenceBlocker) {
  Add-SimulatedSemanticEvidence -Classification "blocker" -ExitCode 2
  Add-Blocker "[BLOCKED] simulated semantic validator evidence blocker - package cache unavailable"
  Exit-WithResult
}

if (-not ($Redocly -or $OpenApiGeneratorValidate -or $OpenApiTypescript -or $TypescriptFetch)) {
  Write-SafeHost "[OK] semantic/client generation tools were not requested; default mode performed lightweight gate only."
  Exit-WithResult
}

if ($Redocly) {
  Invoke-Redocly
}
if ($OpenApiGeneratorValidate) {
  Invoke-OpenApiGeneratorValidate
}
if ($OpenApiTypescript) {
  Invoke-OpenApiTypescript
}
if ($TypescriptFetch) {
  Invoke-TypescriptFetch
}

Exit-WithResult
