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
  [switch]$MaterializePackageCache,
  [switch]$RealToolReadiness,
  [switch]$RealToolExecutionBridge,
  [switch]$CacheProbe,
  [switch]$CommandMatrix,
  [switch]$Clean,
  [switch]$SelfTest,
  [switch]$SimulateExternalBlocker,
  [switch]$SimulateSchemaMismatch,
  [switch]$SimulateClientMismatch,
  [switch]$SimulateSensitiveOutputTail,
  [switch]$SimulateSensitiveCommandFailure,
  [switch]$SimulateGeneratedClientInspectionPass,
  [switch]$SimulateGeneratedClientMissingRequired,
  [switch]$SimulateGeneratedClientReadinessMissingOutput,
  [switch]$SimulateGeneratedClientReadinessStaleMarker,
  [switch]$SimulateGeneratedClientReadinessUnsafeTarget,
  [switch]$SimulateSemanticEvidencePass,
  [switch]$SimulateSemanticEvidenceFailure,
  [switch]$SimulateSemanticEvidenceBlocker,
  [switch]$SimulateToolPreflightBlocker,
  [switch]$SimulateCacheProbe,
  [switch]$SimulatePackageMaterializationBoundary,
  [switch]$SimulateRealToolReadinessCurrent,
  [switch]$SimulateRealToolReadinessStale,
  [switch]$SimulateRealToolExecutionBridgeReady,
  [switch]$SimulateClosureMarkerCurrent,
  [switch]$SimulateClosureMarkerStale,
  [switch]$SimulateClosureMarkerSimulated,
  [switch]$SimulateClosureMarkerMissingGenerated,
  [switch]$SimulateRealExecutionEvidencePass,
  [switch]$SimulateRealExecutionEvidenceFailure,
  [switch]$SimulateRealExecutionEvidenceBlocker
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
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_MATERIALIZE_PACKAGE_CACHE) { $MaterializePackageCache = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_REAL_TOOL_READINESS) { $RealToolReadiness = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_REAL_TOOL_EXECUTION_BRIDGE) { $RealToolExecutionBridge = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_CACHE_PROBE) { $CacheProbe = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_COMMAND_MATRIX) { $CommandMatrix = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_CLEAN) { $Clean = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SELF_TEST) { $SelfTest = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_EXTERNAL_BLOCKER) { $SimulateExternalBlocker = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_SCHEMA_MISMATCH) { $SimulateSchemaMismatch = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_CLIENT_MISMATCH) { $SimulateClientMismatch = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_SENSITIVE_OUTPUT_TAIL) { $SimulateSensitiveOutputTail = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_SENSITIVE_COMMAND_FAILURE) { $SimulateSensitiveCommandFailure = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_GENERATED_CLIENT_INSPECTION_PASS) { $SimulateGeneratedClientInspectionPass = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_GENERATED_CLIENT_MISSING_REQUIRED) { $SimulateGeneratedClientMissingRequired = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_GENERATED_CLIENT_READINESS_MISSING_OUTPUT) { $SimulateGeneratedClientReadinessMissingOutput = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_GENERATED_CLIENT_READINESS_STALE_MARKER) { $SimulateGeneratedClientReadinessStaleMarker = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_GENERATED_CLIENT_READINESS_UNSAFE_TARGET) { $SimulateGeneratedClientReadinessUnsafeTarget = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_SEMANTIC_EVIDENCE_PASS) { $SimulateSemanticEvidencePass = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_SEMANTIC_EVIDENCE_FAILURE) { $SimulateSemanticEvidenceFailure = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_SEMANTIC_EVIDENCE_BLOCKER) { $SimulateSemanticEvidenceBlocker = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_TOOL_PREFLIGHT_BLOCKER) { $SimulateToolPreflightBlocker = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_CACHE_PROBE) { $SimulateCacheProbe = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_PACKAGE_MATERIALIZATION_BOUNDARY) { $SimulatePackageMaterializationBoundary = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_REAL_TOOL_READINESS_CURRENT) { $SimulateRealToolReadinessCurrent = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_REAL_TOOL_READINESS_STALE) { $SimulateRealToolReadinessStale = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_REAL_TOOL_EXECUTION_BRIDGE_READY) { $SimulateRealToolExecutionBridgeReady = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_CLOSURE_MARKER_CURRENT) { $SimulateClosureMarkerCurrent = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_CLOSURE_MARKER_STALE) { $SimulateClosureMarkerStale = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_CLOSURE_MARKER_SIMULATED) { $SimulateClosureMarkerSimulated = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_CLOSURE_MARKER_MISSING_GENERATED) { $SimulateClosureMarkerMissingGenerated = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_REAL_EXECUTION_EVIDENCE_PASS) { $SimulateRealExecutionEvidencePass = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_REAL_EXECUTION_EVIDENCE_FAILURE) { $SimulateRealExecutionEvidenceFailure = $true }
if (Test-TruthyEnv $env:CONTROL_PLANE_LEDGER_OPENAPI_SIMULATE_REAL_EXECUTION_EVIDENCE_BLOCKER) { $SimulateRealExecutionEvidenceBlocker = $true }
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

if ($CommandMatrix -or $CacheProbe) {
  $Redocly = $false
  $OpenApiGeneratorValidate = $false
  $OpenApiTypescript = $false
  $TypescriptFetch = $false
  $MaterializePackageCache = $false
  $RealToolReadiness = $false
  $RealToolExecutionBridge = $false
}

if ($RealToolExecutionBridge) {
  $Redocly = $false
  $OpenApiGeneratorValidate = $false
  $OpenApiTypescript = $false
  $TypescriptFetch = $false
  $MaterializePackageCache = $false
  $RealToolReadiness = $false
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

function Get-OpenApiGeneratorTransientConfigPath {
  return Join-Path $repoRoot "openapitools.json"
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
    (Join-Path $TempRoot "self-test-generated-client-missing-output"),
    (Join-Path $TempRoot "self-test-generated-client-stale-marker"),
    (Join-Path $TempRoot "self-test-cache-probe"),
    (Join-Path $TempRoot "self-test-package-download-opt-in"),
    (Join-Path $TempRoot "self-test-package-materialization-missing-download-opt-in"),
    (Join-Path $TempRoot "self-test-package-materialization-boundary"),
    (Join-Path $TempRoot "self-test-real-tool-readiness-current"),
    (Join-Path $TempRoot "self-test-real-tool-readiness-stale"),
    (Join-Path $TempRoot "self-test-real-tool-execution-bridge-ready"),
    (Join-Path $TempRoot "self-test-closure-marker-current"),
    (Join-Path $TempRoot "self-test-closure-marker-stale"),
    (Join-Path $TempRoot "self-test-closure-marker-simulated"),
    (Join-Path $TempRoot "self-test-closure-marker-missing-generated"),
    (Join-Path $TempRoot "self-test-real-execution-pass"),
    (Join-Path $TempRoot "self-test-real-execution-failure"),
    (Join-Path $TempRoot "self-test-real-execution-blocker"),
    (Join-Path $TempRoot "self-test-semantic-evidence-pass"),
    (Join-Path $TempRoot "self-test-semantic-evidence-failure"),
    (Join-Path $TempRoot "self-test-semantic-evidence-blocker"),
    (Join-Path $TempRoot "self-test-tool-preflight-blocker"),
    (Join-Path $TempRoot "self-test-cleanup-marker.txt"),
    (Join-Path $TempRoot "self-test-wrapper-owned-cleanup-marker.txt")
  )
}

function Remove-WrapperOwnedTempArtifacts {
  foreach ($path in @(Get-WrapperOwnedArtifactPaths)) {
    Assert-WrapperOwnedArtifactPath -Path $path -Label "wrapper-owned artifact cleanup path"
    Remove-Item -Recurse -Force $path -ErrorAction SilentlyContinue
  }

  Clear-OpenApiGeneratorTransientConfig

  if (Test-Path $TempRoot -PathType Container) {
    $remaining = @(Get-ChildItem -LiteralPath $TempRoot -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($remaining.Count -eq 0) {
      Remove-Item -Force $TempRoot -ErrorAction SilentlyContinue
    }
  }
}

function Clear-OpenApiGeneratorTransientConfig {
  $path = Get-OpenApiGeneratorTransientConfigPath
  if (-not (Test-Path $path -PathType Leaf)) {
    return
  }

  $raw = Get-Content -Path $path -Raw -ErrorAction SilentlyContinue
  if ($raw -match '"generator-cli"\s*:') {
    Remove-Item -Force $path -ErrorAction SilentlyContinue
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
  if ($MaterializePackageCache) { [void]$requestedChecks.Add("package_cache_materialization") }
  if ($RealToolReadiness) { [void]$requestedChecks.Add("real_tool_readiness") }
  if ($RealToolExecutionBridge) { [void]$requestedChecks.Add("real_tool_execution_bridge") }
  if ($requestedChecks.Count -eq 0) { [void]$requestedChecks.Add("lightweight_only") }

  $simulatedModes = New-Object System.Collections.Generic.List[string]
  if ($SimulateExternalBlocker) { [void]$simulatedModes.Add("external_blocker") }
  if ($SimulateSchemaMismatch) { [void]$simulatedModes.Add("schema_mismatch") }
  if ($SimulateClientMismatch) { [void]$simulatedModes.Add("client_mismatch") }
  if ($SimulateSensitiveOutputTail) { [void]$simulatedModes.Add("sensitive_output_tail") }
  if ($SimulateSensitiveCommandFailure) { [void]$simulatedModes.Add("sensitive_command_failure") }
  if ($SimulateGeneratedClientInspectionPass) { [void]$simulatedModes.Add("generated_client_inspection_pass") }
  if ($SimulateGeneratedClientMissingRequired) { [void]$simulatedModes.Add("generated_client_missing_required") }
  if ($SimulateGeneratedClientReadinessMissingOutput) { [void]$simulatedModes.Add("generated_client_readiness_missing_output") }
  if ($SimulateGeneratedClientReadinessStaleMarker) { [void]$simulatedModes.Add("generated_client_readiness_stale_marker") }
  if ($SimulateGeneratedClientReadinessUnsafeTarget) { [void]$simulatedModes.Add("generated_client_readiness_unsafe_target") }
  if ($SimulateSemanticEvidencePass) { [void]$simulatedModes.Add("semantic_evidence_pass") }
  if ($SimulateSemanticEvidenceFailure) { [void]$simulatedModes.Add("semantic_evidence_failure") }
  if ($SimulateSemanticEvidenceBlocker) { [void]$simulatedModes.Add("semantic_evidence_blocker") }
  if ($SimulateToolPreflightBlocker) { [void]$simulatedModes.Add("tool_preflight_blocker") }
  if ($SimulateCacheProbe) { [void]$simulatedModes.Add("cache_probe") }
  if ($SimulatePackageMaterializationBoundary) { [void]$simulatedModes.Add("package_materialization_boundary") }
  if ($SimulateRealToolReadinessCurrent) { [void]$simulatedModes.Add("real_tool_readiness_current") }
  if ($SimulateRealToolReadinessStale) { [void]$simulatedModes.Add("real_tool_readiness_stale") }
  if ($SimulateRealToolExecutionBridgeReady) { [void]$simulatedModes.Add("real_tool_execution_bridge_ready") }
  if ($SimulateClosureMarkerCurrent) { [void]$simulatedModes.Add("closure_marker_current") }
  if ($SimulateClosureMarkerStale) { [void]$simulatedModes.Add("closure_marker_stale") }
  if ($SimulateClosureMarkerSimulated) { [void]$simulatedModes.Add("closure_marker_simulated") }
  if ($SimulateClosureMarkerMissingGenerated) { [void]$simulatedModes.Add("closure_marker_missing_generated") }
  if ($SimulateRealExecutionEvidencePass) { [void]$simulatedModes.Add("real_execution_evidence_pass") }
  if ($SimulateRealExecutionEvidenceFailure) { [void]$simulatedModes.Add("real_execution_evidence_failure") }
  if ($SimulateRealExecutionEvidenceBlocker) { [void]$simulatedModes.Add("real_execution_evidence_blocker") }

  return [ordered]@{
    script = "scripts/verify_control_plane_ledger_adjustment_openapi_semantic.ps1"
    openapi_path = Get-RepoRelativePath $OpenApiPath
    temp_root = Format-BoundedPath $TempRoot
    npm_cache = Format-BoundedPath $NpmCache
    requested_checks = @($requestedChecks.ToArray())
    simulated_modes = @($simulatedModes.ToArray())
    allow_package_download = [bool]$AllowPackageDownload
    materialize_package_cache = [bool]$MaterializePackageCache
    real_tool_readiness = [bool]$RealToolReadiness
    real_tool_execution_bridge = [bool]$RealToolExecutionBridge
    cache_probe = [bool]$CacheProbe
    command_matrix = [bool]$CommandMatrix
    clean_requested = [bool]$Clean
    self_test = [bool]$SelfTest
  }
}

function Get-SafeToolPath {
  param([AllowNull()][object]$Command)

  if ($null -eq $Command) {
    return "unavailable"
  }

  $source = [string]$Command.Source
  if ([string]::IsNullOrWhiteSpace($source)) {
    $source = [string]$Command.Name
  }

  if ([string]::IsNullOrWhiteSpace($source)) {
    return "unavailable"
  }

  try {
    if ([System.IO.Path]::IsPathRooted($source)) {
      return Format-BoundedPath $source
    }
  } catch {
    return Redact-SafeText $source
  }

  return Redact-SafeText $source
}

function Get-ToolPreflightSummary {
  param(
    [Parameter(Mandatory = $true)][string[]]$Names
  )

  $parts = New-Object System.Collections.Generic.List[string]
  foreach ($name in $Names) {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
      [void]$parts.Add("$name=unavailable")
    } else {
      [void]$parts.Add("$name=$(Get-SafeToolPath $command)")
    }
  }
  return ($parts.ToArray() -join ";")
}

function Get-NpmPackageCacheStatus {
  if ($AllowPackageDownload) {
    return "download_allowed"
  }

  if (Test-Path $NpmCache) {
    return "offline_repo_cache_present"
  }

  return "offline_repo_cache_missing"
}

function Get-OpenApiNpmPackageList {
  return @("@redocly/cli", "@openapitools/openapi-generator-cli", "openapi-typescript")
}

function Get-BoundedDirectorySizeBytes {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path $Path)) {
    return 0
  }

  $total = [int64]0
  $count = 0
  try {
    foreach ($file in Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue) {
      $total += [int64]$file.Length
      $count += 1
      if ($count -ge 10000 -or $total -ge 1099511627776) {
        return $total
      }
    }
  } catch {
    return 0
  }
  return $total
}

function Get-PackageProvenance {
  param(
    [AllowNull()][string]$PackageCacheStatus = "",
    [bool]$PackageDownloadAllowed = [bool]$AllowPackageDownload
  )

  if ($PackageDownloadAllowed) {
    return "download_opt_in"
  }

  switch ([string]$PackageCacheStatus) {
    "offline_repo_cache_present" { return "preseeded_repo_cache" }
    "offline_repo_cache_missing" { return "offline_repo_cache_missing" }
    "download_allowed" { return "download_opt_in" }
    "simulated" { return "simulated" }
    "not_applicable" { return "not_applicable" }
    default { return "unknown" }
  }
}

function Get-PackageVersionMarker {
  param(
    [AllowNull()][string]$PackageCacheStatus = "",
    [AllowNull()][string]$ToolVersion = ""
  )

  if (-not [string]::IsNullOrWhiteSpace($ToolVersion) -and -not @("unavailable", "unknown", "not_requested").Contains([string]$ToolVersion)) {
    return Redact-SafeText $ToolVersion
  }

  switch ([string]$PackageCacheStatus) {
    "offline_repo_cache_present" { return "cache_entry_present" }
    "download_allowed" { return "download_opt_in_unresolved" }
    "simulated" { return "simulated" }
    default { return "unavailable" }
  }
}

function Assert-OpenApiNpmPackageAllowed {
  param([Parameter(Mandatory = $true)][string]$Package)

  if (-not @((Get-OpenApiNpmPackageList)).Contains($Package)) {
    Add-Failure "[FAIL] package materialization contract - package '$Package' is not on the OpenAPI allowlist"
    return $false
  }
  return $true
}

function Get-PackageMaterializationMarkerPath {
  return Join-Path $NpmCache ".ledger-openapi-package-materialization.json"
}

function Get-SafeWrapperMaterializationCommand {
  return "powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -MaterializePackageCache -AllowPackageDownload"
}

function Get-SafePackageMaterializationCommand {
  param([Parameter(Mandatory = $true)][string]$Package)

  return "npm cache add $Package --cache $(Format-BoundedPath $NpmCache)"
}

function Get-PackageClosurePreflightReason {
  param(
    [Parameter(Mandatory = $true)][object]$Entry,
    [Parameter(Mandatory = $true)][object]$MarkerStatus,
    [Parameter(Mandatory = $true)][object]$CacheProbe,
    [Parameter(Mandatory = $true)][string]$PreflightStatus
  )

  if ($PreflightStatus -ne "passed") {
    return "required tool preflight failed for $($Entry.name)"
  }
  if ([string]$MarkerStatus.Status -ne "current") {
    return "materialization marker $($MarkerStatus.Status) at $($MarkerStatus.Path)"
  }
  if ([string]$CacheProbe.Classification -ne "pass") {
    return "package cache readback $($CacheProbe.Status) for $($Entry.package)"
  }
  return "ready"
}

function Get-MaterializationMarkerStatus {
  param([Parameter(Mandatory = $true)][string[]]$Packages)

  $path = Get-PackageMaterializationMarkerPath
  if (-not (Test-Path $path)) {
    return [pscustomobject]@{
      Status = "missing"
      Path = Format-BoundedPath $path
      Output = @("materialization marker missing")
      Packages = @()
    }
  }

  try {
    $raw = Get-Content -Path $path -Raw
    $marker = $raw | ConvertFrom-Json
    $fixture = Get-OpenApiFixtureFingerprint
    $missingPackages = @($Packages | Where-Object { -not @($marker.packages).Contains($_) })
    if ([string]$marker.schema_version -ne "ledger_openapi_package_materialization.v1") {
      $status = "stale"
      $output = @("materialization marker schema mismatch")
    } elseif ([string]$marker.openapi_sha256 -ne [string]$fixture.Sha256) {
      $status = "stale"
      $output = @("materialization marker OpenAPI fixture hash stale")
    } elseif ($missingPackages.Count -gt 0) {
      $status = "incomplete"
      $output = @("materialization marker package list incomplete")
    } else {
      $status = "current"
      $output = @("materialization marker current")
    }
    return [pscustomobject]@{
      Status = $status
      Path = Format-BoundedPath $path
      Output = $output
      Packages = @($marker.packages)
    }
  } catch {
    return [pscustomobject]@{
      Status = "stale"
      Path = Format-BoundedPath $path
      Output = @("materialization marker unreadable")
      Packages = @()
    }
  }
}

function Write-PackageMaterializationMarker {
  $fixture = Get-OpenApiFixtureFingerprint
  $markerPath = Get-PackageMaterializationMarkerPath
  Assert-PathUnderRepo -Path $markerPath -Label "package materialization marker"
  if (
    -not (Test-PathUnderRoot -Path $markerPath -Root $toolCacheRoot) -and
    -not (Test-PathUnderRoot -Path $markerPath -Root $tmpRoot)
  ) {
    throw "package materialization marker must stay under repository .tool-cache or .tmp: $(Format-BoundedPath $markerPath)"
  }

  $marker = [ordered]@{
    schema_version = "ledger_openapi_package_materialization.v1"
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    openapi_path = Get-RepoRelativePath $OpenApiPath
    openapi_sha256 = $fixture.Sha256
    package_cache_path = Format-BoundedPath $NpmCache
    package_cache_bytes = [int64](Get-BoundedDirectorySizeBytes -Path $NpmCache)
    packages = @(Get-OpenApiNpmPackageList)
  }
  New-Item -ItemType Directory -Force (Split-Path -Parent $markerPath) | Out-Null
  ($marker | ConvertTo-Json -Depth 5) | Set-Content -Path $markerPath -Encoding ascii
  Write-SafeHost "[OK] package materialization marker: $(Format-BoundedPath $markerPath)"
}

function Get-OpenApiCommandMatrix {
  $cachePolicy = if ($AllowPackageDownload) { "download_allowed" } else { "offline_first_repo_cache" }
  return @(
    [ordered]@{
      name = "redocly_semantic"
      flag = "-Redocly"
      env = "CONTROL_PLANE_LEDGER_OPENAPI_REDOCLY=1"
      package = "@redocly/cli"
      tool = "redocly"
      required_tools = @("node", "npm")
      cache_policy = $cachePolicy
      expected_exit_classification = "0 pass; 1 schema_failure; 2 tool_or_cache_blocker"
      evidence_kind = "semantic_validator"
      evidence_fields = @("tool_path", "tool_version", "package_list", "package_version", "package_provenance", "package_cache_path", "package_cache_status", "package_cache_bytes", "package_download_allowed", "package_probe_duration_ms", "preflight_status", "duration_ms", "command", "output_tail")
      safe_command = "powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -Redocly"
    },
    [ordered]@{
      name = "openapi_generator_validate"
      flag = "-OpenApiGeneratorValidate"
      env = "CONTROL_PLANE_LEDGER_OPENAPI_GENERATOR_VALIDATE=1"
      package = "@openapitools/openapi-generator-cli"
      tool = "openapi-generator-cli"
      required_tools = @("node", "npm", "java")
      cache_policy = $cachePolicy
      expected_exit_classification = "0 pass; 1 schema_failure; 2 tool_or_cache_blocker"
      evidence_kind = "semantic_validator"
      evidence_fields = @("tool_path", "tool_version", "package_list", "package_version", "package_provenance", "package_cache_path", "package_cache_status", "package_cache_bytes", "package_download_allowed", "package_probe_duration_ms", "preflight_status", "duration_ms", "command", "output_tail")
      safe_command = "powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -OpenApiGeneratorValidate"
    },
    [ordered]@{
      name = "openapi_typescript"
      flag = "-OpenApiTypescript"
      env = "CONTROL_PLANE_LEDGER_OPENAPI_TYPESCRIPT=1"
      package = "openapi-typescript"
      tool = "openapi-typescript"
      required_tools = @("node", "npm")
      cache_policy = $cachePolicy
      expected_exit_classification = "0 pass_with_readiness; 1 generated_client_mismatch; 2 tool_or_cache_blocker"
      evidence_kind = "client_generation"
      evidence_fields = @("tool_path", "tool_version", "package_list", "package_version", "package_provenance", "package_cache_path", "package_cache_status", "package_cache_bytes", "package_download_allowed", "package_probe_duration_ms", "preflight_status", "duration_ms", "command", "output_tail", "readiness_marker", "closure_readiness_marker")
      safe_command = "powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -OpenApiTypescript"
    },
    [ordered]@{
      name = "typescript_fetch"
      flag = "-TypescriptFetch"
      env = "CONTROL_PLANE_LEDGER_OPENAPI_TYPESCRIPT_FETCH=1"
      package = "@openapitools/openapi-generator-cli"
      tool = "openapi-generator-cli"
      required_tools = @("node", "npm", "java")
      cache_policy = $cachePolicy
      expected_exit_classification = "0 pass_with_readiness; 1 generated_client_mismatch; 2 tool_or_cache_blocker"
      evidence_kind = "client_generation"
      evidence_fields = @("tool_path", "tool_version", "package_list", "package_version", "package_provenance", "package_cache_path", "package_cache_status", "package_cache_bytes", "package_download_allowed", "package_probe_duration_ms", "preflight_status", "duration_ms", "command", "output_tail", "readiness_marker", "closure_readiness_marker")
      safe_command = "powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -TypescriptFetch"
    }
  )
}

function Assert-OpenApiCommandMatrixContract {
  param([Parameter(Mandatory = $true)][object[]]$Matrix)

  if ($Matrix.Count -ne 4) {
    Add-Failure "[FAIL] command matrix contract - expected 4 entries, found $($Matrix.Count)"
    return
  }

  $expectedNames = @("redocly_semantic", "openapi_generator_validate", "openapi_typescript", "typescript_fetch")
  foreach ($expectedName in $expectedNames) {
    if (-not (@($Matrix | Where-Object { $_.name -eq $expectedName }).Count -eq 1)) {
      Add-Failure "[FAIL] command matrix contract - missing entry '$expectedName'"
    }
  }

  foreach ($entry in $Matrix) {
    foreach ($field in @("name", "flag", "env", "package", "tool", "required_tools", "cache_policy", "expected_exit_classification", "evidence_kind", "evidence_fields", "safe_command")) {
      if ($null -eq $entry[$field]) {
        Add-Failure "[FAIL] command matrix contract - '$($entry.name)' missing field '$field'"
      }
    }

    if (-not ([string]$entry.flag).StartsWith("-")) {
      Add-Failure "[FAIL] command matrix contract - '$($entry.name)' flag is not an opt-in flag"
    }
    if (-not ([string]$entry.env).StartsWith("CONTROL_PLANE_LEDGER_OPENAPI_")) {
      Add-Failure "[FAIL] command matrix contract - '$($entry.name)' env opt-in is not scoped"
    }
    if (-not @("semantic_validator", "client_generation").Contains([string]$entry.evidence_kind)) {
      Add-Failure "[FAIL] command matrix contract - '$($entry.name)' evidence_kind is invalid"
    }
    if (-not ([string]$entry.expected_exit_classification).Contains("2 tool_or_cache_blocker")) {
      Add-Failure "[FAIL] command matrix contract - '$($entry.name)' does not document blocker exit classification"
    }
    foreach ($requiredField in @("tool_path", "tool_version", "package_list", "package_version", "package_provenance", "package_cache_path", "package_cache_status", "package_cache_bytes", "package_download_allowed", "package_probe_duration_ms", "preflight_status", "duration_ms", "command", "output_tail")) {
      if (-not @($entry.evidence_fields).Contains($requiredField)) {
        Add-Failure "[FAIL] command matrix contract - '$($entry.name)' missing evidence field '$requiredField'"
      }
    }
    if ([string]$entry.evidence_kind -eq "client_generation") {
      foreach ($requiredClientField in @("readiness_marker", "closure_readiness_marker")) {
        if (-not @($entry.evidence_fields).Contains($requiredClientField)) {
          Add-Failure "[FAIL] command matrix contract - '$($entry.name)' missing generated-client evidence field '$requiredClientField'"
        }
      }
    }
    foreach ($tool in @($entry.required_tools)) {
      if (-not @("node", "npm", "java").Contains([string]$tool)) {
        Add-Failure "[FAIL] command matrix contract - '$($entry.name)' has unexpected required tool '$tool'"
      }
    }
    $safe = Redact-SafeText ([string]$entry.safe_command)
    if ($safe -ne [string]$entry.safe_command) {
      Add-Failure "[FAIL] command matrix contract - '$($entry.name)' safe_command needed redaction"
    }
    if ([string]$entry.safe_command -match "(?i)Authorization|Cookie|Bearer|secret|credential|api[_-]?key|operation[_-]?key|raw[_-]?metadata|payload|body") {
      Add-Failure "[FAIL] command matrix contract - '$($entry.name)' safe_command contains forbidden material"
    }
  }
}

function Write-OpenApiCommandMatrix {
  $matrix = @(Get-OpenApiCommandMatrix)
  Assert-OpenApiCommandMatrixContract -Matrix $matrix
  if ($script:Failures.Count -gt 0) {
    return
  }

  Write-SafeHost "Control Plane ledger adjustment OpenAPI opt-in command matrix"
  foreach ($entry in $matrix) {
    Write-SafeHost ("[MATRIX] {0} flag={1} env={2} tools={3} package={4} cache={5} exit='{6}' evidence={7} command='{8}'" -f `
        $entry.name,
        $entry.flag,
        $entry.env,
        (@($entry.required_tools) -join "+"),
        $entry.package,
        $entry.cache_policy,
        $entry.expected_exit_classification,
        (@($entry.evidence_fields) -join "+"),
        $entry.safe_command)
  }
  Write-RealToolExecutionBridgeMatrix
}

function Get-RealToolExecutionBridgePlan {
  $openApiTypescriptTargetDir = Join-Path $TempRoot "openapi-typescript"
  $openApiTypescriptTarget = Join-Path $openApiTypescriptTargetDir "admin-api.d.ts"
  $typescriptFetchTarget = Join-Path $TempRoot "typescript-fetch"
  return [ordered]@{
    name = "real_tool_materialized_execution_bridge"
    flag = "-RealToolExecutionBridge"
    env = "CONTROL_PLANE_LEDGER_OPENAPI_REAL_TOOL_EXECUTION_BRIDGE=1"
    readiness_command = "powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -RealToolReadiness"
    execution_command = "powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -Semantic -ClientGeneration"
    required_materialization_marker = Format-BoundedPath (Get-PackageMaterializationMarkerPath)
    package_cache_path = Format-BoundedPath $NpmCache
    generated_client_targets = @(
      "openapi-typescript=$(Format-BoundedPath $openApiTypescriptTarget)",
      "typescript-fetch=$(Format-BoundedPath $typescriptFetchTarget)"
    )
    closure_marker_targets = @(
      "openapi-typescript=$(Format-BoundedPath (Get-RealToolClosureReadinessMarkerPath -Path $openApiTypescriptTargetDir))",
      "typescript-fetch=$(Format-BoundedPath (Get-RealToolClosureReadinessMarkerPath -Path $typescriptFetchTarget))"
    )
    closure_rule = "real command pass + current materialization marker + current generated-client readiness marker + current closure marker"
  }
}

function Assert-RealToolExecutionBridgePlanContract {
  param([Parameter(Mandatory = $true)][object]$Plan)

  foreach ($field in @("name", "flag", "env", "readiness_command", "execution_command", "required_materialization_marker", "package_cache_path", "generated_client_targets", "closure_marker_targets", "closure_rule")) {
    if ($null -eq $Plan[$field]) {
      Add-Failure "[FAIL] real-tool execution bridge contract - missing field '$field'"
    }
  }
  if ([string]$Plan.flag -ne "-RealToolExecutionBridge") {
    Add-Failure "[FAIL] real-tool execution bridge contract - unexpected bridge flag"
  }
  if (-not ([string]$Plan.env).StartsWith("CONTROL_PLANE_LEDGER_OPENAPI_")) {
    Add-Failure "[FAIL] real-tool execution bridge contract - env opt-in is not scoped"
  }
  foreach ($command in @([string]$Plan.readiness_command, [string]$Plan.execution_command)) {
    $safe = Redact-SafeText $command
    if ($safe -ne $command) {
      Add-Failure "[FAIL] real-tool execution bridge contract - command needed redaction"
    }
    if ($command -match "(?i)Authorization|Cookie|Bearer|secret|credential|api[_-]?key|operation[_-]?key|raw[_-]?metadata|payload|body") {
      Add-Failure "[FAIL] real-tool execution bridge contract - command contains forbidden material"
    }
  }
  foreach ($target in @($Plan.generated_client_targets + $Plan.closure_marker_targets)) {
    $safe = Redact-SafeText ([string]$target)
    if ($safe -ne [string]$target) {
      Add-Failure "[FAIL] real-tool execution bridge contract - target needed redaction"
    }
  }
}

function Write-RealToolExecutionBridgeMatrix {
  $plan = Get-RealToolExecutionBridgePlan
  Assert-RealToolExecutionBridgePlanContract -Plan $plan
  if ($script:Failures.Count -gt 0) {
    return
  }

  Write-SafeHost (
    "[BRIDGE] {0} flag={1} env={2} readiness='{3}' execute='{4}' materialization_marker='{5}' npm_cache='{6}' generated_targets='{7}' closure_markers='{8}' closure_rule='{9}'" -f `
      $plan.name,
      $plan.flag,
      $plan.env,
      $plan.readiness_command,
      $plan.execution_command,
      $plan.required_materialization_marker,
      $plan.package_cache_path,
      (@($plan.generated_client_targets) -join ";"),
      (@($plan.closure_marker_targets) -join ";"),
      $plan.closure_rule
  )
}

function Invoke-RealToolExecutionBridge {
  param([switch]$SimulatedReady)

  $ready = if ($SimulatedReady) {
    Add-RealToolReadinessEvidence -SimulatedCurrent
  } else {
    Add-RealToolReadinessEvidence
  }

  if (-not $ready) {
    Add-Blocker "[BLOCKED] real-tool execution bridge - materialized package cache or tool readiness failed before real semantic/client-generation execution"
    return
  }

  Write-SafeHost "Control Plane ledger adjustment OpenAPI real-tool execution bridge"
  Write-RealToolExecutionBridgeMatrix
  Write-SafeHost "[OK] bridge dry-run only; run the execute command in a controlled environment to generate real closure evidence."
}

function Assert-ControlledRealToolExecutionPassGate {
  $requestedRealTools = @()
  if ($Redocly) { $requestedRealTools += "redocly_semantic" }
  if ($OpenApiGeneratorValidate) { $requestedRealTools += "openapi_generator_validate" }
  if ($OpenApiTypescript) { $requestedRealTools += "openapi_typescript" }
  if ($TypescriptFetch) { $requestedRealTools += "typescript_fetch" }
  if ($requestedRealTools.Count -eq 0) {
    return $true
  }

  $plan = Get-RealToolExecutionBridgePlan
  Assert-RealToolExecutionBridgePlanContract -Plan $plan
  if ($script:Failures.Count -gt 0) {
    return $false
  }

  Write-SafeHost "[OK] controlled real-tool execution pass gate requested: $($requestedRealTools -join ',')"
  Write-RealToolExecutionBridgeMatrix

  $ready = Add-RealToolReadinessEvidence
  if (-not $ready) {
    Add-Blocker "[BLOCKED] controlled real-tool execution pass gate - materialized package cache or tool readiness failed before running requested semantic/client-generation commands"
    return $false
  }

  foreach ($target in @($plan.generated_client_targets + $plan.closure_marker_targets)) {
    if ([string]$target -match "(?i)Authorization|Cookie|Bearer|secret|credential|api[_-]?key|operation[_-]?key|raw[_-]?metadata|payload|body") {
      Add-Failure "[FAIL] controlled real-tool execution pass gate - generated target summary contains forbidden material"
      return $false
    }
  }

  Write-SafeHost "[OK] controlled real-tool execution pass gate ready; requested commands may run."
  return $true
}

function Invoke-LightweightToolVersionProbe {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )

  $command = Get-Command $Name -ErrorAction SilentlyContinue
  if ($null -eq $command) {
    return [pscustomobject]@{
      Name = $Name
      Status = "missing"
      Version = "unavailable"
      ToolPath = "unavailable"
      DurationMs = 0
      Output = @("$Name not found")
    }
  }

  $result = Invoke-Process -FileName $command.Source -Arguments $Arguments -Label "$Name availability probe"
  $versionLines = @(Get-BoundedSafeLines -Lines $result.Output -TakeLast 3 -MaxLineLength 120)
  $version = if ($versionLines.Count -gt 0) { $versionLines[0] } else { "unknown" }
  $status = if ($result.ExitCode -eq 0) { "available" } else { "blocked" }
  return [pscustomobject]@{
    Name = $Name
    Status = $status
    Version = $version
    ToolPath = Get-SafeToolPath $command
    DurationMs = $result.DurationMs
    Output = @($result.Output)
  }
}

function Invoke-NpmCachePackageProbe {
  param([Parameter(Mandatory = $true)][string]$Package)

  $timer = [System.Diagnostics.Stopwatch]::StartNew()
  $npm = Get-Command npm -ErrorAction SilentlyContinue
  if ($null -eq $npm) {
    $timer.Stop()
    return [pscustomobject]@{
      Status = "blocked"
      Classification = "blocker"
      ExitCode = 2
      DurationMs = [int64]$timer.Elapsed.TotalMilliseconds
      Output = @("npm not found")
    }
  }

  if (-not (Test-Path $NpmCache)) {
    $timer.Stop()
    return [pscustomobject]@{
      Status = "offline_repo_cache_missing"
      Classification = "blocker"
      ExitCode = 2
      DurationMs = [int64]$timer.Elapsed.TotalMilliseconds
      Output = @("offline npm cache missing")
    }
  }
  $timer.Stop()

  $args = @("cache", "ls", $Package, "--cache", $NpmCache, "--offline")
  $result = Invoke-Process -FileName $npm.Source -Arguments $args -Label "npm cache probe $Package" -ExternalTool
  $outputText = ($result.Output -join "`n")
  if ($result.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($outputText)) {
    $status = "offline_repo_cache_present"
    $classification = "pass"
    $exitCode = 0
  } else {
    $status = "offline_repo_cache_missing"
    $classification = "blocker"
    $exitCode = 2
  }

  return [pscustomobject]@{
    Status = $status
    Classification = $classification
    ExitCode = $exitCode
    DurationMs = $result.DurationMs
    Output = @($result.Output)
  }
}

function Get-ToolProbeVersion {
  param(
    [Parameter(Mandatory = $true)][hashtable]$ToolProbes,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if (-not $ToolProbes.ContainsKey($Name)) {
    return "unavailable"
  }
  return [string]$ToolProbes[$Name].Version
}

function Get-ToolProbePathSummary {
  param(
    [Parameter(Mandatory = $true)][hashtable]$ToolProbes,
    [Parameter(Mandatory = $true)][string[]]$Names
  )

  $parts = New-Object System.Collections.Generic.List[string]
  foreach ($name in $Names) {
    if ($ToolProbes.ContainsKey($name)) {
      [void]$parts.Add("$name=$($ToolProbes[$name].ToolPath)")
    } else {
      [void]$parts.Add("$name=unavailable")
    }
  }
  return ($parts.ToArray() -join ";")
}

function Get-ToolProbePreflightStatus {
  param(
    [Parameter(Mandatory = $true)][hashtable]$ToolProbes,
    [Parameter(Mandatory = $true)][string[]]$Names
  )

  foreach ($name in $Names) {
    if (-not $ToolProbes.ContainsKey($name) -or $ToolProbes[$name].Status -ne "available") {
      return "blocked"
    }
  }
  return "passed"
}

function Get-ToolProbeOutput {
  param(
    [Parameter(Mandatory = $true)][hashtable]$ToolProbes,
    [Parameter(Mandatory = $true)][string[]]$Names
  )

  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($name in $Names) {
    if ($ToolProbes.ContainsKey($name)) {
      [void]$lines.Add("$name=$($ToolProbes[$name].Version)")
    } else {
      [void]$lines.Add("$name=unavailable")
    }
  }
  return @($lines.ToArray())
}

function Add-OpenApiCacheProbeEvidence {
  param([switch]$Simulated)

  $matrix = @(Get-OpenApiCommandMatrix)
  Assert-OpenApiCommandMatrixContract -Matrix $matrix
  if ($script:Failures.Count -gt 0) {
    return
  }

  $toolProbes = @{}
  if ($Simulated) {
    $toolProbes["node"] = [pscustomobject]@{ Status = "available"; Version = "v20.0.0-simulated"; ToolPath = "node=simulated"; DurationMs = 1; Output = @("node simulated") }
    $toolProbes["npm"] = [pscustomobject]@{ Status = "available"; Version = "10.0.0-simulated"; ToolPath = "npm=simulated"; DurationMs = 1; Output = @("npm simulated") }
    $toolProbes["java"] = [pscustomobject]@{ Status = "missing"; Version = "unavailable"; ToolPath = "java=unavailable"; DurationMs = 0; Output = @("java not found") }
  } else {
    $toolProbes["node"] = Invoke-LightweightToolVersionProbe -Name "node" -Arguments @("--version")
    $toolProbes["npm"] = Invoke-LightweightToolVersionProbe -Name "npm" -Arguments @("--version")
    $toolProbes["java"] = Invoke-LightweightToolVersionProbe -Name "java" -Arguments @("-version")
  }

  foreach ($entry in $matrix) {
    $requiredTools = @($entry.required_tools)
    $preflightStatus = Get-ToolProbePreflightStatus -ToolProbes $toolProbes -Names $requiredTools
    $toolPath = Get-ToolProbePathSummary -ToolProbes $toolProbes -Names $requiredTools
    $toolOutput = @(Get-ToolProbeOutput -ToolProbes $toolProbes -Names $requiredTools)
    if ($AllowPackageDownload) {
      $cacheProbe = [pscustomobject]@{ Status = "download_allowed"; Classification = "pass"; ExitCode = 0; DurationMs = 1; Output = @("package download explicitly allowed; cache probe did not download packages") }
    } elseif ($Simulated) {
      $cacheProbe = if ([string]$entry.package -eq "@openapitools/openapi-generator-cli") {
        [pscustomobject]@{ Status = "offline_repo_cache_missing"; Classification = "blocker"; ExitCode = 2; DurationMs = 2; Output = @("simulated package cache missing") }
      } else {
        [pscustomobject]@{ Status = "offline_repo_cache_present"; Classification = "pass"; ExitCode = 0; DurationMs = 2; Output = @("simulated package cache present") }
      }
    } else {
      $cacheProbe = Invoke-NpmCachePackageProbe -Package ([string]$entry.package)
    }

    $classification = if ($preflightStatus -eq "passed" -and $cacheProbe.Classification -eq "pass") { "pass" } else { "blocker" }
    $exitCode = if ($classification -eq "pass") { 0 } else { 2 }
    $blockerReason = ""
    if ($classification -eq "blocker") {
      $blockerReason = "tool or offline package cache unavailable before opt-in command"
      Add-Blocker "[BLOCKED] cache/tool probe $($entry.name) - $blockerReason"
    }

    Add-EvidenceRecord `
      -Kind ([string]$entry.evidence_kind) `
      -Label "cache/tool availability probe $($entry.name)" `
      -Tool ([string]$entry.tool) `
      -ToolVersion (Get-ToolProbeVersion -ToolProbes $toolProbes -Name ([string]$requiredTools[0])) `
      -Package ([string]$entry.package) `
      -Classification $classification `
      -ExitCode $exitCode `
      -Command ([string]$entry.safe_command) `
      -Output ($toolOutput + @($cacheProbe.Output)) `
      -BlockerReason $blockerReason `
      -ProvenanceMode $(if ($Simulated) { "simulated" } else { "real" }) `
      -ToolPath $toolPath `
      -PreflightStatus $preflightStatus `
      -PackageCacheStatus ([string]$cacheProbe.Status) `
      -PackageDownloadAllowed ([bool]$AllowPackageDownload) `
      -PackageVersion (Get-PackageVersionMarker -PackageCacheStatus ([string]$cacheProbe.Status) -ToolVersion "") `
      -PackageProbeDurationMs ([int64]$cacheProbe.DurationMs) `
      -DurationMs ([int64]($cacheProbe.DurationMs + ($requiredTools | ForEach-Object { if ($toolProbes.ContainsKey($_)) { $toolProbes[$_].DurationMs } else { 0 } } | Measure-Object -Sum).Sum)) `
      -ExecutionMode "cache_probe" `
      -RealCommandExecuted $false `
      -ReadinessMarkerStatus $(if ([string]$entry.evidence_kind -eq "client_generation") { "missing" } else { "not_applicable" }) `
      -ClosureEligible $false
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
    [ValidateSet("real", "simulated")][string]$ProvenanceMode = "real",
    [AllowNull()][string]$ToolPath = "",
    [ValidateSet("passed", "blocked", "simulated", "not_run")][string]$PreflightStatus = "not_run",
    [AllowNull()][string]$PackageCacheStatus = "",
    [bool]$PackageDownloadAllowed = [bool]$AllowPackageDownload,
    [AllowNull()][string]$PackageList = "",
    [AllowNull()][string]$PackageVersion = "",
    [AllowNull()][string]$PackageProvenance = "",
    [AllowNull()][string]$PackageCachePath = "",
    [int64]$PackageCacheBytes = -1,
    [int64]$PackageProbeDurationMs = 0,
    [int64]$DurationMs = 0,
    [ValidateSet("real_tool_execution", "real_tool_readiness", "package_materialization", "cache_probe", "command_matrix", "simulated", "not_run")][string]$ExecutionMode = "not_run",
    [bool]$RealCommandExecuted = $false,
    [ValidateSet("current", "missing", "stale", "incomplete", "not_applicable", "pending")][string]$ReadinessMarkerStatus = "not_applicable",
    [bool]$ClosureEligible = $false
  )

  if ([string]::IsNullOrWhiteSpace($ToolPath)) {
    $ToolPath = "unavailable"
  }
  if ([string]::IsNullOrWhiteSpace($PackageCacheStatus)) {
    $PackageCacheStatus = Get-NpmPackageCacheStatus
  }
  if ([string]::IsNullOrWhiteSpace($PackageList)) {
    $PackageList = (Get-OpenApiNpmPackageList) -join ","
  }
  if ([string]::IsNullOrWhiteSpace($PackageVersion)) {
    $PackageVersion = Get-PackageVersionMarker -PackageCacheStatus $PackageCacheStatus -ToolVersion $ToolVersion
  }
  if ([string]::IsNullOrWhiteSpace($PackageProvenance)) {
    $PackageProvenance = Get-PackageProvenance -PackageCacheStatus $PackageCacheStatus -PackageDownloadAllowed ([bool]$PackageDownloadAllowed)
  }
  if ([string]::IsNullOrWhiteSpace($PackageCachePath)) {
    $PackageCachePath = Format-BoundedPath $NpmCache
  }
  if ($PackageCacheBytes -lt 0) {
    $PackageCacheBytes = Get-BoundedDirectorySizeBytes -Path $NpmCache
  }
  if ($PackageProbeDurationMs -lt 0) {
    $PackageProbeDurationMs = 0
  }
  if ($DurationMs -lt 0) {
    $DurationMs = 0
  }

  $record = [ordered]@{
    kind = Redact-SafeText $Kind
    label = Redact-SafeText $Label
    provenance_mode = $ProvenanceMode
    tool = Redact-SafeText $Tool
    tool_path = Redact-SafeText $ToolPath
    tool_version = Redact-SafeText $ToolVersion
    package = Redact-SafeText $Package
    package_list = Redact-SafeText $PackageList
    package_version = Redact-SafeText $PackageVersion
    package_provenance = Redact-SafeText $PackageProvenance
    package_cache_path = Redact-SafeText $PackageCachePath
    package_cache_status = Redact-SafeText $PackageCacheStatus
    package_cache_bytes = [int64]$PackageCacheBytes
    package_download_allowed = [bool]$PackageDownloadAllowed
    package_probe_duration_ms = [int64]$PackageProbeDurationMs
    preflight_status = $PreflightStatus
    execution_mode = $ExecutionMode
    real_command_executed = [bool]$RealCommandExecuted
    readiness_marker_status = $ReadinessMarkerStatus
    closure_eligible = [bool]$ClosureEligible
    checked_schema = Get-RepoRelativePath $OpenApiPath
    classification = $Classification
    exit_code = $ExitCode
    duration_ms = [int64]$DurationMs
    command = Redact-SafeText $Command
    output_tail = @(Get-BoundedSafeLines -Lines $Output)
    failure_reason = Redact-SafeText $FailureReason
    blocker_reason = Redact-SafeText $BlockerReason
  }
  [void]$script:EvidenceRecords.Add([pscustomobject]$record)
}

function Set-ClientGenerationEvidenceReadiness {
  param(
    [Parameter(Mandatory = $true)][string]$Tool,
    [Parameter(Mandatory = $true)][ValidateSet("current", "missing", "stale", "not_applicable", "pending")][string]$Status,
    [bool]$ClosureReady = $false
  )

  for ($index = $script:EvidenceRecords.Count - 1; $index -ge 0; $index -= 1) {
    $record = $script:EvidenceRecords[$index]
    if ([string]$record.kind -eq "client_generation" -and [string]$record.tool -eq $Tool) {
      $record.readiness_marker_status = $Status
      if ([string]$record.provenance_mode -eq "real" -and [string]$record.execution_mode -eq "real_tool_execution" -and [bool]$record.real_command_executed -and [string]$record.classification -eq "pass" -and $Status -eq "current" -and [bool]$ClosureReady) {
        $record.closure_eligible = $true
      }
      return
    }
  }
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
      if (-not @("script", "openapi_path", "temp_root", "npm_cache", "requested_checks", "simulated_modes", "allow_package_download", "materialize_package_cache", "real_tool_readiness", "real_tool_execution_bridge", "cache_probe", "command_matrix", "clean_requested", "self_test").Contains($field)) {
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
      if (-not @("kind", "label", "provenance_mode", "tool", "tool_path", "tool_version", "package", "package_list", "package_version", "package_provenance", "package_cache_path", "package_cache_status", "package_cache_bytes", "package_download_allowed", "package_probe_duration_ms", "preflight_status", "execution_mode", "real_command_executed", "readiness_marker_status", "closure_eligible", "checked_schema", "classification", "exit_code", "duration_ms", "command", "output_tail", "failure_reason", "blocker_reason").Contains($field)) {
        Add-Failure "[FAIL] evidence report contract - unexpected evidence field '$field'"
      }
    }
    if (-not @("real", "simulated").Contains([string]$record.provenance_mode)) {
      Add-Failure "[FAIL] evidence report contract - invalid evidence provenance_mode '$($record.provenance_mode)'"
    }
    if (-not @("semantic_validator", "client_generation", "package_materialization", "real_tool_readiness").Contains([string]$record.kind)) {
      Add-Failure "[FAIL] evidence report contract - invalid evidence kind '$($record.kind)'"
    }
    if (-not @("pass", "failure", "blocker").Contains([string]$record.classification)) {
      Add-Failure "[FAIL] evidence report contract - invalid classification '$($record.classification)'"
    }
    if ([string]::IsNullOrWhiteSpace([string]$record.tool_version)) {
      Add-Failure "[FAIL] evidence report contract - missing tool_version"
    }
    if ([string]::IsNullOrWhiteSpace([string]$record.tool_path)) {
      Add-Failure "[FAIL] evidence report contract - missing tool_path"
    }
    if (-not @("passed", "blocked", "simulated", "not_run").Contains([string]$record.preflight_status)) {
      Add-Failure "[FAIL] evidence report contract - invalid preflight_status '$($record.preflight_status)'"
    }
    if (-not @("real_tool_execution", "real_tool_readiness", "package_materialization", "cache_probe", "command_matrix", "simulated", "not_run").Contains([string]$record.execution_mode)) {
      Add-Failure "[FAIL] evidence report contract - invalid execution_mode '$($record.execution_mode)'"
    }
    if ($null -eq $record.real_command_executed) {
      Add-Failure "[FAIL] evidence report contract - missing real_command_executed"
    }
    if (-not @("current", "missing", "stale", "incomplete", "not_applicable", "pending").Contains([string]$record.readiness_marker_status)) {
      Add-Failure "[FAIL] evidence report contract - invalid readiness_marker_status '$($record.readiness_marker_status)'"
    }
    if ($null -eq $record.closure_eligible) {
      Add-Failure "[FAIL] evidence report contract - missing closure_eligible"
    }
    if ([bool]$record.closure_eligible -and (-not ([string]$record.kind -eq "client_generation" -and [string]$record.provenance_mode -eq "real" -and [string]$record.execution_mode -eq "real_tool_execution" -and [bool]$record.real_command_executed -and [string]$record.classification -eq "pass" -and [string]$record.readiness_marker_status -eq "current"))) {
      Add-Failure "[FAIL] evidence report contract - closure_eligible requires real client-generation pass with current markers"
    }
    if (-not @("download_allowed", "offline_repo_cache_present", "offline_repo_cache_missing", "simulated", "not_applicable").Contains([string]$record.package_cache_status)) {
      Add-Failure "[FAIL] evidence report contract - invalid package_cache_status '$($record.package_cache_status)'"
    }
    if ([string]::IsNullOrWhiteSpace([string]$record.package_list)) {
      Add-Failure "[FAIL] evidence report contract - missing package_list"
    } else {
      foreach ($packageName in Get-OpenApiNpmPackageList) {
        if (-not ([string]$record.package_list).Contains($packageName)) {
          Add-Failure "[FAIL] evidence report contract - package_list missing '$packageName'"
        }
      }
    }
    if (-not @((Get-OpenApiNpmPackageList)).Contains([string]$record.package)) {
      Add-Failure "[FAIL] evidence report contract - package '$($record.package)' is not on the OpenAPI allowlist"
    }
    if ([string]::IsNullOrWhiteSpace([string]$record.package_version)) {
      Add-Failure "[FAIL] evidence report contract - missing package_version"
    }
    if (-not @("preseeded_repo_cache", "offline_repo_cache_missing", "download_opt_in", "simulated", "not_applicable", "unknown").Contains([string]$record.package_provenance)) {
      Add-Failure "[FAIL] evidence report contract - invalid package_provenance '$($record.package_provenance)'"
    }
    if ([string]::IsNullOrWhiteSpace([string]$record.package_cache_path)) {
      Add-Failure "[FAIL] evidence report contract - missing package_cache_path"
    }
    if ([string]$record.package_cache_path -match "\.\.|\.git|scripts\\|apps\\|crates\\|web\\") {
      Add-Failure "[FAIL] evidence report contract - unsafe package_cache_path '$($record.package_cache_path)'"
    }
    try {
      $cacheBytes = [int64]$record.package_cache_bytes
      if ($cacheBytes -lt 0 -or $cacheBytes -gt 1099511627776) {
        Add-Failure "[FAIL] evidence report contract - package_cache_bytes is unbounded"
      }
    } catch {
      Add-Failure "[FAIL] evidence report contract - package_cache_bytes is not numeric"
    }
    if ($null -eq $record.package_download_allowed) {
      Add-Failure "[FAIL] evidence report contract - missing package_download_allowed"
    }
    if ([bool]$record.package_download_allowed -and [string]$record.package_provenance -ne "download_opt_in") {
      Add-Failure "[FAIL] evidence report contract - package download opt-in missing provenance marker"
    }
    try {
      $probeDurationMs = [int64]$record.package_probe_duration_ms
      if ($probeDurationMs -lt 0 -or $probeDurationMs -gt 86400000) {
        Add-Failure "[FAIL] evidence report contract - package_probe_duration_ms is unbounded"
      }
    } catch {
      Add-Failure "[FAIL] evidence report contract - package_probe_duration_ms is not numeric"
    }
    try {
      $durationMs = [int64]$record.duration_ms
      if ($durationMs -lt 0 -or $durationMs -gt 86400000) {
        Add-Failure "[FAIL] evidence report contract - duration_ms is unbounded"
      }
    } catch {
      Add-Failure "[FAIL] evidence report contract - duration_ms is not numeric"
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
  $timer = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $ErrorActionPreference = "Continue"
    $output = @(& $FileName @Arguments 2>&1 | ForEach-Object { [string]$_ })
  } finally {
    $timer.Stop()
    $ErrorActionPreference = $oldErrorActionPreference
  }
  $exitCode = if ($null -eq $global:LASTEXITCODE) { 0 } else { [int]$global:LASTEXITCODE }
  $commandLine = Format-CommandLine -FileName $FileName -Arguments $Arguments
  $durationMs = [int64]$timer.Elapsed.TotalMilliseconds

  if ($exitCode -eq 0) {
    Write-SafeHost "[OK] $Label"
    foreach ($line in $output | Select-Object -Last 8) {
      if (-not [string]::IsNullOrWhiteSpace($line)) {
        Write-SafeHost $line
      }
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output; Command = $commandLine; Classification = "pass"; DurationMs = $durationMs }
  }

  $joined = Redact-SafeText ($output -join "`n")
  if ($ExternalTool -and (Test-BlockerOutput $joined)) {
    Add-Blocker "[BLOCKED] $Label - external tool/package cache unavailable while running: $commandLine"
    $classification = "blocker"
  } else {
    Add-Failure "[FAIL] $Label - exit $exitCode while running: $commandLine`n$joined"
    $classification = "failure"
  }
  return [pscustomobject]@{ ExitCode = $exitCode; Output = $output; Command = $commandLine; Classification = $classification; DurationMs = $durationMs }
}

function Invoke-MaterializationProcess {
  param(
    [Parameter(Mandatory = $true)][string]$Package
  )

  $npm = Get-Command npm -ErrorAction SilentlyContinue
  if ($null -eq $npm) {
    return [pscustomobject]@{
      ExitCode = 2
      Output = @("npm not found")
      Command = "npm cache add $Package --cache $(Format-BoundedPath $NpmCache)"
      Classification = "blocker"
      DurationMs = 0
    }
  }

  $arguments = @("cache", "add", $Package, "--cache", $NpmCache)
  $global:LASTEXITCODE = 0
  $oldErrorActionPreference = $ErrorActionPreference
  $timer = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $ErrorActionPreference = "Continue"
    $output = @(& $npm.Source @arguments 2>&1 | ForEach-Object { [string]$_ })
  } finally {
    $timer.Stop()
    $ErrorActionPreference = $oldErrorActionPreference
  }
  $exitCode = if ($null -eq $global:LASTEXITCODE) { 0 } else { [int]$global:LASTEXITCODE }
  $classification = if ($exitCode -eq 0) { "pass" } else { "blocker" }
  if ($exitCode -eq 0) {
    Write-SafeHost "[OK] npm package cache materialization $Package"
  }

  return [pscustomobject]@{
    ExitCode = $exitCode
    Output = @($output)
    Command = "npm cache add $Package --cache $(Format-BoundedPath $NpmCache)"
    Classification = $classification
    DurationMs = [int64]$timer.Elapsed.TotalMilliseconds
  }
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

  $requiredTools = @("node", "npm")
  if ($RequireJava) {
    $requiredTools += "java"
  }
  $toolPathSummary = Get-ToolPreflightSummary -Names $requiredTools
  $packageCacheStatus = Get-NpmPackageCacheStatus

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
      -BlockerReason "required local tool unavailable" `
      -ToolPath $toolPathSummary `
      -PreflightStatus "blocked" `
      -PackageCacheStatus $packageCacheStatus `
      -PackageDownloadAllowed ([bool]$AllowPackageDownload) `
      -PackageVersion (Get-PackageVersionMarker -PackageCacheStatus $packageCacheStatus -ToolVersion "unavailable") `
      -PackageProbeDurationMs 0 `
      -DurationMs 0 `
      -ExecutionMode "real_tool_execution" `
      -RealCommandExecuted $false `
      -ReadinessMarkerStatus "not_applicable" `
      -ClosureEligible $false
    return
  }

  $ready = Add-RealToolReadinessEvidence -OnlyPackage $Package
  if (-not $ready) {
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
          -BlockerReason $versionBlockerReason `
          -ToolPath $toolPathSummary `
          -PreflightStatus "passed" `
          -PackageCacheStatus $packageCacheStatus `
          -PackageDownloadAllowed ([bool]$AllowPackageDownload) `
          -PackageVersion (Get-PackageVersionMarker -PackageCacheStatus $packageCacheStatus -ToolVersion "unavailable") `
          -PackageProbeDurationMs $versionResult.DurationMs `
          -DurationMs $versionResult.DurationMs `
          -ExecutionMode "real_tool_execution" `
          -RealCommandExecuted $false `
          -ReadinessMarkerStatus "not_applicable" `
          -ClosureEligible $false
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
      -BlockerReason $blockerReason `
      -ToolPath $toolPathSummary `
      -PreflightStatus "passed" `
      -PackageCacheStatus $packageCacheStatus `
      -PackageDownloadAllowed ([bool]$AllowPackageDownload) `
      -PackageVersion (Get-PackageVersionMarker -PackageCacheStatus $packageCacheStatus -ToolVersion $toolVersion) `
      -PackageProbeDurationMs $result.DurationMs `
      -DurationMs $result.DurationMs `
      -ExecutionMode "real_tool_execution" `
      -RealCommandExecuted $true `
      -ReadinessMarkerStatus $(if ($EvidenceKind -eq "client_generation") { "pending" } else { "not_applicable" }) `
      -ClosureEligible $false
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

function Get-GeneratedClientReadinessRoot {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (Test-Path $Path -PathType Leaf) {
    return (Split-Path -Parent ([System.IO.Path]::GetFullPath($Path)))
  }

  return [System.IO.Path]::GetFullPath($Path)
}

function Assert-GeneratedClientTargetSafe {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Label
  )

  $root = Get-GeneratedClientReadinessRoot -Path $Path
  if (-not (Test-PathUnderRoot -Path $root -Root $TempRoot)) {
    Add-Failure "[FAIL] $Label - generated-client target must stay under TempRoot: $(Format-BoundedPath $root)"
    return $false
  }

  return $true
}

function Get-GeneratedClientReadinessMarkerPath {
  param([Parameter(Mandatory = $true)][string]$Path)

  return Join-Path (Get-GeneratedClientReadinessRoot -Path $Path) ".ledger-openapi-generated-client-readiness.json"
}

function Get-RealToolClosureReadinessMarkerPath {
  param([Parameter(Mandatory = $true)][string]$Path)

  return Join-Path (Get-GeneratedClientReadinessRoot -Path $Path) ".ledger-openapi-real-tool-closure-readiness.json"
}

function Write-GeneratedClientReadinessMarker {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][string]$Tool,
    [ValidateSet("real", "simulated")][string]$ProvenanceMode = "real",
    [string]$OpenApiSha256 = "",
    [int64]$DurationMs = 0,
    [string]$PackageCacheStatus = "",
    [bool]$PackageDownloadAllowed = [bool]$AllowPackageDownload
  )

  if (-not (Assert-GeneratedClientTargetSafe -Path $Path -Label "$Target generated-client readiness marker")) {
    return
  }

  $fixture = Get-OpenApiFixtureFingerprint
  if ([string]::IsNullOrWhiteSpace($OpenApiSha256)) {
    $OpenApiSha256 = $fixture.Sha256
  }
  if ([string]::IsNullOrWhiteSpace($PackageCacheStatus)) {
    $PackageCacheStatus = Get-NpmPackageCacheStatus
  }
  if ($DurationMs -lt 0) {
    $DurationMs = 0
  }

  $marker = [ordered]@{
    schema_version = "ledger_openapi_generated_client_readiness.v1"
    target = Redact-SafeText $Target
    tool = Redact-SafeText $Tool
    provenance_mode = $ProvenanceMode
    checked_schema = Get-RepoRelativePath $OpenApiPath
    openapi_fixture_sha256 = Redact-SafeText $OpenApiSha256
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    package_cache_status = Redact-SafeText $PackageCacheStatus
    package_download_allowed = [bool]$PackageDownloadAllowed
    duration_ms = [int64]$DurationMs
  }

  $markerPath = Get-GeneratedClientReadinessMarkerPath -Path $Path
  Assert-WrapperOwnedArtifactPath -Path $markerPath -Label "generated-client readiness marker"
  New-Item -ItemType Directory -Force (Split-Path -Parent $markerPath) | Out-Null
  ($marker | ConvertTo-Json -Depth 5) | Set-Content -Path $markerPath -Encoding ascii
}

function Assert-GeneratedClientReadinessMarker {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Label
  )

  $markerPath = Get-GeneratedClientReadinessMarkerPath -Path $Path
  if (-not (Test-Path $markerPath -PathType Leaf)) {
    Add-Failure "[FAIL] $Label - generated-client readiness marker is missing: $(Format-BoundedPath $markerPath)"
    return $false
  }

  $raw = Get-Content -Path $markerPath -Raw
  foreach ($pattern in @(
      "(?i)Authorization\s*[:=]",
      "(?i)Cookie\s*[:=]",
      "(?i)Bearer\s+[A-Za-z0-9._~+/\-]+=*",
      "(?i)(password|passwd|secret|token|credential|api[_-]?key|operation[_-]?key|package[_-]?token|npm[_-]?token|raw[_-]?metadata|metadata)\s*[:=]\s*[^,\s]+"
    )) {
    if ($raw -match $pattern) {
      Add-Failure "[FAIL] $Label - generated-client readiness marker contains forbidden material pattern"
      return $false
    }
  }

  $marker = $raw | ConvertFrom-Json
  foreach ($field in @($marker.PSObject.Properties.Name)) {
    if (-not @("schema_version", "target", "tool", "provenance_mode", "checked_schema", "openapi_fixture_sha256", "generated_at_utc", "package_cache_status", "package_download_allowed", "duration_ms").Contains($field)) {
      Add-Failure "[FAIL] $Label - generated-client readiness marker has unexpected field '$field'"
    }
  }
  if ([string]$marker.schema_version -ne "ledger_openapi_generated_client_readiness.v1") {
    Add-Failure "[FAIL] $Label - generated-client readiness marker schema_version mismatch"
  }
  if (-not @("real", "simulated").Contains([string]$marker.provenance_mode)) {
    Add-Failure "[FAIL] $Label - generated-client readiness marker provenance_mode mismatch"
  }
  if ([string]$marker.checked_schema -ne (Get-RepoRelativePath $OpenApiPath)) {
    Add-Failure "[FAIL] $Label - generated-client readiness marker checked_schema drifted"
  }
  $fixture = Get-OpenApiFixtureFingerprint
  if ([string]$marker.openapi_fixture_sha256 -ne $fixture.Sha256) {
    Add-Failure "[FAIL] $Label - generated-client readiness marker is stale for current OpenAPI fixture"
  }
  try {
    [void][datetime]::Parse([string]$marker.generated_at_utc)
  } catch {
    Add-Failure "[FAIL] $Label - generated-client readiness marker generated_at_utc is not parseable"
  }
  if (-not @("download_allowed", "offline_repo_cache_present", "offline_repo_cache_missing", "simulated", "not_applicable").Contains([string]$marker.package_cache_status)) {
    Add-Failure "[FAIL] $Label - generated-client readiness marker package_cache_status mismatch"
  }
  try {
    $durationMs = [int64]$marker.duration_ms
    if ($durationMs -lt 0 -or $durationMs -gt 86400000) {
      Add-Failure "[FAIL] $Label - generated-client readiness marker duration_ms is unbounded"
    }
  } catch {
    Add-Failure "[FAIL] $Label - generated-client readiness marker duration_ms is not numeric"
  }

  return $script:Failures.Count -eq 0
}

function Assert-GeneratedClientReadinessGate {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if (-not (Assert-GeneratedClientTargetSafe -Path $Path -Label $Label)) {
    return
  }
  if (-not (Test-Path $Path)) {
    Add-Failure "[FAIL] $Label - generated-client output is missing: $(Format-BoundedPath $Path)"
    return
  }
  if (-not (Assert-GeneratedClientReadinessMarker -Path $Path -Label $Label)) {
    return
  }
  Assert-GeneratedClientInspectionContract -Path $Path -Label $Label
}

function Assert-RealGeneratedClientOutputPresent {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if (-not (Assert-GeneratedClientTargetSafe -Path $Path -Label $Label)) {
    return $false
  }
  if (-not (Test-Path $Path)) {
    Add-Blocker "[BLOCKED] $Label - generated-client target is missing after real command pass: $(Format-BoundedPath $Path)"
    return $false
  }
  if ((Test-Path $Path -PathType Container) -and @(Get-GeneratedClientFiles -Path $Path).Count -eq 0) {
    Add-Blocker "[BLOCKED] $Label - generated-client target has no inspectable files after real command pass: $(Format-BoundedPath $Path)"
    return $false
  }
  return $true
}

function Write-RealToolClosureReadinessMarker {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][string]$Tool,
    [Parameter(Mandatory = $true)][string]$Package,
    [ValidateSet("real", "simulated")][string]$ProvenanceMode = "real",
    [string]$OpenApiSha256 = "",
    [string]$GeneratedClientReadinessStatus = "current",
    [string]$MaterializationStatus = "current",
    [int64]$DurationMs = 0,
    [string]$PackageCacheStatus = "",
    [bool]$PackageDownloadAllowed = [bool]$AllowPackageDownload
  )

  if (-not (Assert-GeneratedClientTargetSafe -Path $Path -Label "$Target real-tool closure marker")) {
    return
  }

  $fixture = Get-OpenApiFixtureFingerprint
  if ([string]::IsNullOrWhiteSpace($OpenApiSha256)) {
    $OpenApiSha256 = $fixture.Sha256
  }
  if ([string]::IsNullOrWhiteSpace($PackageCacheStatus)) {
    $PackageCacheStatus = Get-NpmPackageCacheStatus
  }
  if ($DurationMs -lt 0) {
    $DurationMs = 0
  }
  $repoCommit = Get-RepoCommitProvenance
  $marker = [ordered]@{
    schema_version = "ledger_openapi_real_tool_closure_readiness.v1"
    target = Redact-SafeText $Target
    tool = Redact-SafeText $Tool
    package = Redact-SafeText $Package
    provenance_mode = $ProvenanceMode
    checked_schema = Get-RepoRelativePath $OpenApiPath
    openapi_fixture_sha256 = Redact-SafeText $OpenApiSha256
    repo_commit = $repoCommit.Commit
    repo_commit_status = $repoCommit.Status
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    package_cache_status = Redact-SafeText $PackageCacheStatus
    package_download_allowed = [bool]$PackageDownloadAllowed
    package_cache_path = Format-BoundedPath $NpmCache
    package_cache_bytes = [int64](Get-BoundedDirectorySizeBytes -Path $NpmCache)
    materialization_marker_status = Redact-SafeText $MaterializationStatus
    generated_client_readiness_marker_status = Redact-SafeText $GeneratedClientReadinessStatus
    duration_ms = [int64]$DurationMs
  }

  $markerPath = Get-RealToolClosureReadinessMarkerPath -Path $Path
  Assert-WrapperOwnedArtifactPath -Path $markerPath -Label "real-tool closure readiness marker"
  New-Item -ItemType Directory -Force (Split-Path -Parent $markerPath) | Out-Null
  ($marker | ConvertTo-Json -Depth 5) | Set-Content -Path $markerPath -Encoding ascii
}

function Assert-RealToolClosureReadinessMarker {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if (-not (Assert-GeneratedClientReadinessMarker -Path $Path -Label $Label)) {
    return $false
  }

  $markerPath = Get-RealToolClosureReadinessMarkerPath -Path $Path
  if (-not (Test-Path $markerPath -PathType Leaf)) {
    Add-Failure "[FAIL] $Label - real-tool closure readiness marker is missing: $(Format-BoundedPath $markerPath)"
    return $false
  }

  $raw = Get-Content -Path $markerPath -Raw
  foreach ($pattern in @(
      "(?i)Authorization\s*[:=]",
      "(?i)Cookie\s*[:=]",
      "(?i)Bearer\s+[A-Za-z0-9._~+/\-]+=*",
      "(?i)(password|passwd|secret|token|credential|api[_-]?key|operation[_-]?key|package[_-]?token|npm[_-]?token|raw[_-]?metadata|metadata)\s*[:=]\s*[^,\s]+"
    )) {
    if ($raw -match $pattern) {
      Add-Failure "[FAIL] $Label - real-tool closure readiness marker contains forbidden material pattern"
      return $false
    }
  }

  $marker = $raw | ConvertFrom-Json
  foreach ($field in @($marker.PSObject.Properties.Name)) {
    if (-not @("schema_version", "target", "tool", "package", "provenance_mode", "checked_schema", "openapi_fixture_sha256", "repo_commit", "repo_commit_status", "generated_at_utc", "package_cache_status", "package_download_allowed", "package_cache_path", "package_cache_bytes", "materialization_marker_status", "generated_client_readiness_marker_status", "duration_ms").Contains($field)) {
      Add-Failure "[FAIL] $Label - real-tool closure readiness marker has unexpected field '$field'"
    }
  }
  if ([string]$marker.schema_version -ne "ledger_openapi_real_tool_closure_readiness.v1") {
    Add-Failure "[FAIL] $Label - real-tool closure readiness marker schema_version mismatch"
  }
  if ([string]$marker.provenance_mode -ne "real") {
    Add-Failure "[FAIL] $Label - real-tool closure readiness marker must have real provenance"
  }
  if ([string]$marker.checked_schema -ne (Get-RepoRelativePath $OpenApiPath)) {
    Add-Failure "[FAIL] $Label - real-tool closure readiness marker checked_schema drifted"
  }
  $fixture = Get-OpenApiFixtureFingerprint
  if ([string]$marker.openapi_fixture_sha256 -ne $fixture.Sha256) {
    Add-Failure "[FAIL] $Label - real-tool closure readiness marker is stale for current OpenAPI fixture"
  }
  if (-not @("resolved", "unavailable").Contains([string]$marker.repo_commit_status)) {
    Add-Failure "[FAIL] $Label - real-tool closure readiness marker repo_commit_status mismatch"
  }
  if ([string]$marker.materialization_marker_status -ne "current") {
    Add-Failure "[FAIL] $Label - real-tool closure readiness marker materialization status is not current"
  }
  if ([string]$marker.generated_client_readiness_marker_status -ne "current") {
    Add-Failure "[FAIL] $Label - real-tool closure readiness marker generated-client status is not current"
  }
  try {
    [void][datetime]::Parse([string]$marker.generated_at_utc)
  } catch {
    Add-Failure "[FAIL] $Label - real-tool closure readiness marker generated_at_utc is not parseable"
  }
  try {
    $cacheBytes = [int64]$marker.package_cache_bytes
    if ($cacheBytes -lt 0 -or $cacheBytes -gt 1099511627776) {
      Add-Failure "[FAIL] $Label - real-tool closure readiness marker package_cache_bytes is unbounded"
    }
  } catch {
    Add-Failure "[FAIL] $Label - real-tool closure readiness marker package_cache_bytes is not numeric"
  }
  try {
    $durationMs = [int64]$marker.duration_ms
    if ($durationMs -lt 0 -or $durationMs -gt 86400000) {
      Add-Failure "[FAIL] $Label - real-tool closure readiness marker duration_ms is unbounded"
    }
  } catch {
    Add-Failure "[FAIL] $Label - real-tool closure readiness marker duration_ms is not numeric"
  }

  return $script:Failures.Count -eq 0
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
      foreach ($model in $Models) {
        if (Test-GeneratedClientModelDefinitionLine -Line $lines[$index] -Model $model) {
          [void]$snippets.Add((Get-GeneratedClientDefinitionSnippet -Lines $lines -StartIndex $index))
          break
        }
      }
    }
  }

  return ($snippets.ToArray() -join "`n")
}

function Test-GeneratedClientModelDefinitionLine {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line,
    [Parameter(Mandatory = $true)][string]$Model
  )

  $escaped = [regex]::Escape($Model)
  return $Line -match "^\s*(?:""?$escaped""?\s*:|export\s+(?:interface|type)\s+$escaped\b|class\s+$escaped\b)"
}

function Get-GeneratedClientDefinitionSnippet {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Lines,
    [Parameter(Mandatory = $true)][int]$StartIndex
  )

  $max = [Math]::Min($Lines.Count - 1, $StartIndex + 220)
  $end = $StartIndex
  $depth = 0
  for ($cursor = $StartIndex; $cursor -le $max; $cursor += 1) {
    $line = $Lines[$cursor]
    $depth += ([regex]::Matches($line, "\{")).Count
    $depth -= ([regex]::Matches($line, "\}")).Count
    $end = $cursor
    if ($cursor -gt $StartIndex -and $depth -le 0 -and $line -match "^\s*}\s*;?\s*$") {
      $end = $cursor
      break
    }
  }

  return ($Lines[$StartIndex..$end] -join "`n")
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
      if (-not (Test-GeneratedClientModelDefinitionLine -Line $lines[$index] -Model $Model)) {
        continue
      }

      [void]$snippets.Add((Get-GeneratedClientDefinitionSnippet -Lines $lines -StartIndex $index))
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
    -ProvenanceMode "simulated" `
    -ToolPath "simulated-tool" `
    -PreflightStatus "simulated" `
    -PackageCacheStatus "simulated" `
    -PackageDownloadAllowed $false `
    -DurationMs 12 `
    -ExecutionMode "simulated" `
    -RealCommandExecuted $false `
    -ReadinessMarkerStatus "not_applicable" `
    -ClosureEligible $false
}

function Add-SimulatedToolPreflightBlockerEvidence {
  $safeTail = @(
    "node=unavailable",
    "npm=unavailable",
    "offline package cache unavailable",
    "Authorization: Bearer selftest-token-123456789",
    "package_token=selftest-package-token"
  )

  Add-EvidenceRecord `
    -Kind "semantic_validator" `
    -Label "simulated real-tool opt-in preflight blocker" `
    -Tool "redocly" `
    -ToolVersion "unavailable" `
    -Package "@redocly/cli" `
    -Classification "blocker" `
    -ExitCode 2 `
    -Command "redocly lint examples/openapi_admin_skeleton.yaml --package_token=selftest-package-token" `
    -Output $safeTail `
    -BlockerReason "required local tool unavailable" `
    -ProvenanceMode "simulated" `
    -ToolPath "node=unavailable;npm=unavailable" `
    -PreflightStatus "blocked" `
    -PackageCacheStatus "offline_repo_cache_missing" `
    -PackageDownloadAllowed $false `
    -DurationMs 0 `
    -ExecutionMode "simulated" `
    -RealCommandExecuted $false `
    -ReadinessMarkerStatus "not_applicable" `
    -ClosureEligible $false
}

function Add-SimulatedRealExecutionEvidence {
  param(
    [Parameter(Mandatory = $true)][ValidateSet("pass", "failure", "blocker")][string]$Classification
  )

  $exitCode = switch ($Classification) {
    "pass" { 0 }
    "failure" { 1 }
    "blocker" { 2 }
  }
  $failureReason = if ($Classification -eq "failure") { "simulated real command schema/client mismatch" } else { "" }
  $blockerReason = if ($Classification -eq "blocker") { "simulated real command tool/cache blocker" } else { "" }
  $output = @(
    "simulated real opt-in command completed",
    "Authorization: Bearer selftest-token-123456789",
    "Cookie: session=selftest-cookie",
    "package_token=selftest-package-token",
    "operation_key=selftest-operation-key",
    "raw_metadata={never-return}"
  )

  Add-EvidenceRecord `
    -Kind "client_generation" `
    -Label "simulated real-tool opt-in execution evidence $Classification" `
    -Tool "openapi-typescript" `
    -ToolVersion "simulated-1.0.0" `
    -Package "openapi-typescript" `
    -Classification $Classification `
    -ExitCode $exitCode `
    -Command "powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -OpenApiTypescript --package_token=selftest-package-token" `
    -Output $output `
    -FailureReason $failureReason `
    -BlockerReason $blockerReason `
    -ProvenanceMode "simulated" `
    -ToolPath "node=simulated;npm=simulated" `
    -PreflightStatus $(if ($Classification -eq "blocker") { "blocked" } else { "passed" }) `
    -PackageCacheStatus $(if ($Classification -eq "blocker") { "offline_repo_cache_missing" } else { "offline_repo_cache_present" }) `
    -PackageDownloadAllowed $false `
    -DurationMs 24 `
    -ExecutionMode "real_tool_execution" `
    -RealCommandExecuted $($Classification -ne "blocker") `
    -ReadinessMarkerStatus $(if ($Classification -eq "pass") { "current" } elseif ($Classification -eq "failure") { "missing" } else { "not_applicable" }) `
    -ClosureEligible $false
}

function Add-OpenApiPackageMaterializationEvidence {
  param([switch]$Simulated)

  $packageList = Get-OpenApiNpmPackageList
  $allPackagesReady = $true
  $toolProbes = @{}
  if ($Simulated) {
    $toolProbes["node"] = [pscustomobject]@{ Status = "available"; Version = "v20.0.0-simulated"; ToolPath = "node=simulated"; DurationMs = 1; Output = @("node simulated") }
    $toolProbes["npm"] = [pscustomobject]@{ Status = "available"; Version = "10.0.0-simulated"; ToolPath = "npm=simulated"; DurationMs = 1; Output = @("npm simulated") }
  } else {
    $toolProbes["node"] = Invoke-LightweightToolVersionProbe -Name "node" -Arguments @("--version")
    $toolProbes["npm"] = Invoke-LightweightToolVersionProbe -Name "npm" -Arguments @("--version")
  }

  $preflightStatus = Get-ToolProbePreflightStatus -ToolProbes $toolProbes -Names @("node", "npm")
  $toolPath = Get-ToolProbePathSummary -ToolProbes $toolProbes -Names @("node", "npm")
  $toolOutput = @(Get-ToolProbeOutput -ToolProbes $toolProbes -Names @("node", "npm"))
  $toolDurationMs = [int64](($toolProbes.Values | ForEach-Object { [int64]$_.DurationMs } | Measure-Object -Sum).Sum)

  foreach ($package in $packageList) {
    if (-not (Assert-OpenApiNpmPackageAllowed -Package $package)) {
      continue
    }

    $classification = "blocker"
    $exitCode = 2
    $command = "npm cache add $package not run"
    $output = @(
      $toolOutput +
      @(
        "package=$package",
        "wrapper_materialization_command=$(Get-SafeWrapperMaterializationCommand)",
        "package_materialization_command=$(Get-SafePackageMaterializationCommand -Package $package)",
        "package_cache_path=$(Format-BoundedPath $NpmCache)",
        "package_cache_bytes=$(Get-BoundedDirectorySizeBytes -Path $NpmCache)",
        "closure_preflight=blocked_until_current_materialization_marker_and_cache_readback"
      )
    )
    $blockerReason = ""
    $cacheStatus = Get-NpmPackageCacheStatus
    $packageVersion = Get-PackageVersionMarker -PackageCacheStatus $cacheStatus -ToolVersion ""
    $packageDurationMs = [int64]0
    $realCommandExecuted = $false

    if (-not $AllowPackageDownload) {
      $blockerReason = "package materialization requires both -MaterializePackageCache and -AllowPackageDownload"
      $output += "package materialization disabled because package download opt-in is missing"
    } elseif ($preflightStatus -ne "passed") {
      $blockerReason = "required local npm tooling unavailable before package materialization"
      $output += "package materialization blocked before npm cache add"
    } elseif ($Simulated) {
      $realCommandExecuted = $true
      $packageDurationMs = 5
      $command = "npm cache add $package --cache $(Format-BoundedPath $NpmCache)"
      if ($package -eq "@openapitools/openapi-generator-cli") {
        $blockerReason = "simulated incomplete package cache marker after materialization"
        $cacheStatus = "offline_repo_cache_missing"
        $packageVersion = "unavailable"
        $output += "simulated incomplete cache marker for package materialization"
      } else {
        $classification = "pass"
        $exitCode = 0
        $cacheStatus = "offline_repo_cache_present"
        $packageVersion = "cache_entry_present"
        $output += "simulated package materialized into cache"
      }
    } else {
      New-Item -ItemType Directory -Force $NpmCache | Out-Null
      $oldCache = $env:npm_config_cache
      try {
        $env:npm_config_cache = $NpmCache
        $materializeResult = Invoke-MaterializationProcess -Package $package
        $realCommandExecuted = $true
        $command = "npm cache add $package --cache $(Format-BoundedPath $NpmCache)"
        $output = @($toolOutput + $materializeResult.Output)
        $packageDurationMs = [int64]$materializeResult.DurationMs

        if ($materializeResult.Classification -eq "blocker") {
          $classification = "blocker"
          $exitCode = 2
          $blockerReason = "package materialization was externally blocked"
        } else {
          $cacheProbe = Invoke-NpmCachePackageProbe -Package $package
          $output = @($output + $cacheProbe.Output)
          $packageDurationMs += [int64]$cacheProbe.DurationMs
          $cacheStatus = [string]$cacheProbe.Status
          if ($cacheProbe.Classification -eq "pass") {
            $classification = "pass"
            $exitCode = 0
            $packageVersion = "cache_entry_present"
          } else {
            $classification = "blocker"
            $exitCode = 2
            $blockerReason = "package cache materialization incomplete after npm cache add"
          }
        }
      } finally {
        $env:npm_config_cache = $oldCache
      }
    }

    if ($classification -eq "blocker") {
      $allPackagesReady = $false
      Add-Blocker "[BLOCKED] package materialization $package - $blockerReason"
    }

    Add-EvidenceRecord `
      -Kind "package_materialization" `
      -Label "package cache materialization $package" `
      -Tool "npm" `
      -ToolVersion (Get-ToolProbeVersion -ToolProbes $toolProbes -Name "npm") `
      -Package $package `
      -Classification $classification `
      -ExitCode $exitCode `
      -Command $command `
      -Output $output `
      -BlockerReason $blockerReason `
      -ProvenanceMode $(if ($Simulated) { "simulated" } else { "real" }) `
      -ToolPath $toolPath `
      -PreflightStatus $preflightStatus `
      -PackageCacheStatus $cacheStatus `
      -PackageDownloadAllowed ([bool]$AllowPackageDownload) `
      -PackageVersion $packageVersion `
      -PackageProbeDurationMs $packageDurationMs `
      -DurationMs ([int64]($toolDurationMs + $packageDurationMs)) `
      -ExecutionMode "package_materialization" `
      -RealCommandExecuted $realCommandExecuted `
      -ReadinessMarkerStatus $(if ($classification -eq "pass") { "current" } else { "missing" }) `
      -ClosureEligible $false
  }

  if (-not $Simulated -and [bool]$AllowPackageDownload -and $allPackagesReady) {
    Write-PackageMaterializationMarker
  }
}

function Add-RealToolReadinessEvidence {
  param(
    [switch]$SimulatedCurrent,
    [switch]$SimulatedStale,
    [AllowNull()][string]$OnlyPackage = ""
  )

  $matrix = @(Get-OpenApiCommandMatrix)
  Assert-OpenApiCommandMatrixContract -Matrix $matrix
  if ($script:Failures.Count -gt 0) {
    return $false
  }

  $toolProbes = @{}
  if ($SimulatedCurrent -or $SimulatedStale) {
    $toolProbes["node"] = [pscustomobject]@{ Status = "available"; Version = "v20.0.0-simulated"; ToolPath = "node=simulated"; DurationMs = 1; Output = @("node simulated") }
    $toolProbes["npm"] = [pscustomobject]@{ Status = "available"; Version = "10.0.0-simulated"; ToolPath = "npm=simulated"; DurationMs = 1; Output = @("npm simulated") }
    $toolProbes["java"] = [pscustomobject]@{ Status = $(if ($SimulatedCurrent) { "available" } else { "missing" }); Version = $(if ($SimulatedCurrent) { "17.0.0-simulated" } else { "unavailable" }); ToolPath = $(if ($SimulatedCurrent) { "java=simulated" } else { "java=unavailable" }); DurationMs = 1; Output = @("java simulated") }
  } else {
    $toolProbes["node"] = Invoke-LightweightToolVersionProbe -Name "node" -Arguments @("--version")
    $toolProbes["npm"] = Invoke-LightweightToolVersionProbe -Name "npm" -Arguments @("--version")
    $toolProbes["java"] = Invoke-LightweightToolVersionProbe -Name "java" -Arguments @("-version")
  }

  $packages = Get-OpenApiNpmPackageList
  $markerStatus = if ($SimulatedCurrent) {
    [pscustomobject]@{ Status = "current"; Path = Format-BoundedPath (Get-PackageMaterializationMarkerPath); Output = @("simulated materialization marker current"); Packages = @($packages) }
  } elseif ($SimulatedStale) {
    [pscustomobject]@{ Status = "stale"; Path = Format-BoundedPath (Get-PackageMaterializationMarkerPath); Output = @("simulated materialization marker stale"); Packages = @($packages[0]) }
  } else {
    Get-MaterializationMarkerStatus -Packages $packages
  }

  $allReady = $true
  foreach ($entry in $matrix) {
    if (-not [string]::IsNullOrWhiteSpace($OnlyPackage) -and [string]$entry.package -ne $OnlyPackage) {
      continue
    }

    $requiredTools = @($entry.required_tools)
    $preflightStatus = Get-ToolProbePreflightStatus -ToolProbes $toolProbes -Names $requiredTools
    $toolPath = Get-ToolProbePathSummary -ToolProbes $toolProbes -Names $requiredTools
    $toolOutput = @(Get-ToolProbeOutput -ToolProbes $toolProbes -Names $requiredTools)
    $cacheProbe = if ($SimulatedCurrent) {
      [pscustomobject]@{ Status = "offline_repo_cache_present"; Classification = "pass"; ExitCode = 0; DurationMs = 2; Output = @("simulated cache readback present") }
    } elseif ($SimulatedStale) {
      [pscustomobject]@{ Status = "offline_repo_cache_missing"; Classification = "blocker"; ExitCode = 2; DurationMs = 2; Output = @("simulated cache readback incomplete") }
    } else {
      Invoke-NpmCachePackageProbe -Package ([string]$entry.package)
    }

    $readinessStatus = [string]$markerStatus.Status
    if (-not @("current", "missing", "stale", "incomplete").Contains($readinessStatus)) {
      $readinessStatus = "stale"
    }

    $classification = if ($preflightStatus -eq "passed" -and $markerStatus.Status -eq "current" -and $cacheProbe.Classification -eq "pass") { "pass" } else { "blocker" }
    $exitCode = if ($classification -eq "pass") { 0 } else { 2 }
    $closureReason = Get-PackageClosurePreflightReason -Entry $entry -MarkerStatus $markerStatus -CacheProbe $cacheProbe -PreflightStatus $preflightStatus
    $readinessOutput = @(
      $toolOutput +
      @($markerStatus.Output) +
      @($cacheProbe.Output) +
      @(
        "package=$($entry.package)",
        "closure_preflight_reason=$closureReason",
        "wrapper_materialization_command=$(Get-SafeWrapperMaterializationCommand)",
        "package_materialization_command=$(Get-SafePackageMaterializationCommand -Package ([string]$entry.package))",
        "package_cache_path=$(Format-BoundedPath $NpmCache)",
        "package_cache_bytes=$(Get-BoundedDirectorySizeBytes -Path $NpmCache)",
        "materialization_marker_path=$($markerStatus.Path)",
        "materialization_marker_status=$($markerStatus.Status)"
      )
    )
    $blockerReason = ""
    if ($classification -eq "blocker") {
      $allReady = $false
      $blockerReason = "closure preflight blocked: $closureReason; materialize with $(Get-SafeWrapperMaterializationCommand)"
      Add-Blocker "[BLOCKED] real-tool readiness $($entry.name) - $blockerReason"
    }

    Add-EvidenceRecord `
      -Kind "real_tool_readiness" `
      -Label "real-tool execution readiness $($entry.name)" `
      -Tool ([string]$entry.tool) `
      -ToolVersion (Get-ToolProbeVersion -ToolProbes $toolProbes -Name ([string]$requiredTools[0])) `
      -Package ([string]$entry.package) `
      -Classification $classification `
      -ExitCode $exitCode `
      -Command "real-tool readiness readback for $($entry.name)" `
      -Output $readinessOutput `
      -BlockerReason $blockerReason `
      -ProvenanceMode $(if ($SimulatedCurrent -or $SimulatedStale) { "simulated" } else { "real" }) `
      -ToolPath $toolPath `
      -PreflightStatus $preflightStatus `
      -PackageCacheStatus ([string]$cacheProbe.Status) `
      -PackageDownloadAllowed ([bool]$AllowPackageDownload) `
      -PackageVersion (Get-PackageVersionMarker -PackageCacheStatus ([string]$cacheProbe.Status) -ToolVersion "") `
      -PackageProbeDurationMs ([int64]$cacheProbe.DurationMs) `
      -DurationMs ([int64]($cacheProbe.DurationMs + ($requiredTools | ForEach-Object { if ($toolProbes.ContainsKey($_)) { [int64]$toolProbes[$_].DurationMs } else { 0 } } | Measure-Object -Sum).Sum)) `
      -ExecutionMode "real_tool_readiness" `
      -RealCommandExecuted $false `
      -ReadinessMarkerStatus $readinessStatus `
      -ClosureEligible $false
  }

  return $allReady
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
  try {
    Invoke-NpmTool `
      -Package "@openapitools/openapi-generator-cli" `
      -ToolArguments @("openapi-generator-cli", "validate", "-i", $OpenApiPath) `
      -ToolName "openapi-generator-cli" `
      -EvidenceKind "semantic_validator" `
      -VersionToolArguments @("openapi-generator-cli", "version") `
      -Label "OpenAPI Generator semantic validation" `
      -RequireJava
  } finally {
    Clear-OpenApiGeneratorTransientConfig
  }
}

function Invoke-OpenApiTypescript {
  $outDir = Join-Path $TempRoot "openapi-typescript"
  $outFile = Join-Path $outDir "admin-api.d.ts"
  New-Item -ItemType Directory -Force $outDir | Out-Null
  Remove-Item -Force $outFile -ErrorAction SilentlyContinue

  $result = Invoke-NpmTool `
    -Package "openapi-typescript" `
    -ToolArguments @("openapi-typescript", $OpenApiPath, "-o", $outFile) `
    -ToolName "openapi-typescript" `
    -EvidenceKind "client_generation" `
    -VersionToolArguments @("openapi-typescript", "--version") `
    -Label "openapi-typescript client type generation"

  if ($script:Blockers.Count -eq 0 -and $null -ne $result -and $result.ExitCode -eq 0) {
    if (-not (Assert-RealGeneratedClientOutputPresent -Path $outFile -Label "openapi-typescript controlled real generated-client output")) {
      return
    }
    Write-GeneratedClientReadinessMarker `
      -Path $outFile `
      -Target "openapi-typescript" `
      -Tool "openapi-typescript" `
      -ProvenanceMode "real" `
      -DurationMs $result.DurationMs `
      -PackageCacheStatus (Get-NpmPackageCacheStatus) `
      -PackageDownloadAllowed ([bool]$AllowPackageDownload)
    Assert-GeneratedClientReadinessGate -Path $outFile -Label "openapi-typescript ledger execute generated-client readiness"
    if ($script:Failures.Count -eq 0) {
      Write-RealToolClosureReadinessMarker `
        -Path $outFile `
        -Target "openapi-typescript" `
        -Tool "openapi-typescript" `
        -Package "openapi-typescript" `
        -ProvenanceMode "real" `
        -GeneratedClientReadinessStatus "current" `
        -MaterializationStatus "current" `
        -DurationMs $result.DurationMs `
        -PackageCacheStatus (Get-NpmPackageCacheStatus) `
        -PackageDownloadAllowed ([bool]$AllowPackageDownload)
    }
    $closureReady = if ($script:Failures.Count -eq 0) { Assert-RealToolClosureReadinessMarker -Path $outFile -Label "openapi-typescript real-tool closure readiness" } else { $false }
    Set-ClientGenerationEvidenceReadiness -Tool "openapi-typescript" -Status $(if ($script:Failures.Count -eq 0 -and $closureReady) { "current" } else { "missing" }) -ClosureReady $closureReady
  }
}

function Invoke-TypescriptFetch {
  $outDir = Join-Path $TempRoot "typescript-fetch"
  Remove-Item -Recurse -Force $outDir -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force $outDir | Out-Null

  try {
    $result = Invoke-NpmTool `
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
  } finally {
    Clear-OpenApiGeneratorTransientConfig
  }

  if ($script:Blockers.Count -eq 0 -and $null -ne $result -and $result.ExitCode -eq 0) {
    if (-not (Assert-RealGeneratedClientOutputPresent -Path $outDir -Label "typescript-fetch controlled real generated-client output")) {
      return
    }
    Write-GeneratedClientReadinessMarker `
      -Path $outDir `
      -Target "typescript-fetch" `
      -Tool "openapi-generator-cli" `
      -ProvenanceMode "real" `
      -DurationMs $result.DurationMs `
      -PackageCacheStatus (Get-NpmPackageCacheStatus) `
      -PackageDownloadAllowed ([bool]$AllowPackageDownload)
    Assert-GeneratedClientReadinessGate -Path $outDir -Label "typescript-fetch ledger execute generated-client readiness"
    if ($script:Failures.Count -eq 0) {
      Write-RealToolClosureReadinessMarker `
        -Path $outDir `
        -Target "typescript-fetch" `
        -Tool "openapi-generator-cli" `
        -Package "@openapitools/openapi-generator-cli" `
        -ProvenanceMode "real" `
        -GeneratedClientReadinessStatus "current" `
        -MaterializationStatus "current" `
        -DurationMs $result.DurationMs `
        -PackageCacheStatus (Get-NpmPackageCacheStatus) `
        -PackageDownloadAllowed ([bool]$AllowPackageDownload)
    }
    $closureReady = if ($script:Failures.Count -eq 0) { Assert-RealToolClosureReadinessMarker -Path $outDir -Label "typescript-fetch real-tool closure readiness" } else { $false }
    Set-ClientGenerationEvidenceReadiness -Tool "openapi-generator-cli" -Status $(if ($script:Failures.Count -eq 0 -and $closureReady) { "current" } else { "missing" }) -ClosureReady $closureReady
  }
}

function Invoke-SimulatedClosureMarkerCase {
  param(
    [Parameter(Mandatory = $true)][ValidateSet("current", "stale", "simulated", "missing_generated")][string]$Case
  )

  $casePathName = $Case.Replace("_", "-")
  $path = Join-Path $TempRoot "self-test-closure-marker-$casePathName"
  if ($Case -ne "missing_generated") {
    Write-SimulatedGeneratedClientFixture -Path $path
    Write-GeneratedClientReadinessMarker `
      -Path $path `
      -Target "simulated-closure-marker-$Case" `
      -Tool "openapi-typescript" `
      -ProvenanceMode "real" `
      -DurationMs 9 `
      -PackageCacheStatus "offline_repo_cache_present" `
      -PackageDownloadAllowed $false
  } else {
    New-Item -ItemType Directory -Force $path | Out-Null
  }

  $openApiSha = if ($Case -eq "stale") { "0000000000000000000000000000000000000000000000000000000000000000" } else { "" }
  $provenance = if ($Case -eq "simulated") { "simulated" } else { "real" }
  Write-RealToolClosureReadinessMarker `
    -Path $path `
    -Target "simulated-closure-marker-$Case" `
    -Tool "openapi-typescript" `
    -Package "openapi-typescript" `
    -ProvenanceMode $provenance `
    -OpenApiSha256 $openApiSha `
    -GeneratedClientReadinessStatus $(if ($Case -eq "missing_generated") { "missing" } else { "current" }) `
    -MaterializationStatus "current" `
    -DurationMs 11 `
    -PackageCacheStatus "offline_repo_cache_present" `
    -PackageDownloadAllowed $false
  [void](Assert-RealToolClosureReadinessMarker -Path $path -Label "simulated real-tool closure marker $Case")
  Exit-WithResult
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
  Invoke-SelfTestChild -Name "simulated generated-client readiness missing output" -Arguments @("-SimulateGeneratedClientReadinessMissingOutput") -ExpectedExitCode 1
  Invoke-SelfTestChild -Name "simulated generated-client readiness stale marker" -Arguments @("-SimulateGeneratedClientReadinessStaleMarker") -ExpectedExitCode 1
  Invoke-SelfTestChild -Name "simulated generated-client readiness unsafe target" -Arguments @("-SimulateGeneratedClientReadinessUnsafeTarget") -ExpectedExitCode 1
  Invoke-SelfTestChild -Name "command matrix dry-run" -Arguments @("-CommandMatrix") -ExpectedExitCode 0 -ExpectedEvidenceAbsent
  Invoke-SelfTestChild `
    -Name "simulated cache/tool availability probe" `
    -Arguments @("-SimulateCacheProbe") `
    -ChildTempRoot (Join-Path $TempRoot "self-test-cache-probe") `
    -ExpectedExitCode 2 `
    -ExpectedEvidenceClassifications @("pass", "blocker") `
    -ExpectedProvenanceMode "simulated"
  Invoke-SelfTestChild `
    -Name "simulated package download opt-in evidence" `
    -Arguments @("-SimulateCacheProbe", "-AllowPackageDownload") `
    -ChildTempRoot (Join-Path $TempRoot "self-test-package-download-opt-in") `
    -ExpectedExitCode 2 `
    -ExpectedEvidenceClassifications @("pass", "blocker") `
    -ExpectedProvenanceMode "simulated"
  Invoke-SelfTestChild `
    -Name "package materialization missing download opt-in" `
    -Arguments @("-MaterializePackageCache") `
    -ChildTempRoot (Join-Path $TempRoot "self-test-package-materialization-missing-download-opt-in") `
    -ExpectedExitCode 2 `
    -ExpectedEvidenceClassifications @("blocker") `
    -ExpectedProvenanceMode "real"
  Invoke-SelfTestChild `
    -Name "simulated package materialization boundary" `
    -Arguments @("-SimulatePackageMaterializationBoundary", "-MaterializePackageCache", "-AllowPackageDownload") `
    -ChildTempRoot (Join-Path $TempRoot "self-test-package-materialization-boundary") `
    -ExpectedExitCode 2 `
    -ExpectedEvidenceClassifications @("pass", "blocker") `
    -ExpectedProvenanceMode "simulated"
  Invoke-SelfTestChild `
    -Name "simulated real-tool readiness current" `
    -Arguments @("-SimulateRealToolReadinessCurrent", "-RealToolReadiness") `
    -ChildTempRoot (Join-Path $TempRoot "self-test-real-tool-readiness-current") `
    -ExpectedExitCode 0 `
    -ExpectedEvidenceClassifications @("pass") `
    -ExpectedProvenanceMode "simulated"
  Invoke-SelfTestChild `
    -Name "simulated real-tool readiness stale" `
    -Arguments @("-SimulateRealToolReadinessStale", "-RealToolReadiness") `
    -ChildTempRoot (Join-Path $TempRoot "self-test-real-tool-readiness-stale") `
    -ExpectedExitCode 2 `
    -ExpectedEvidenceClassifications @("blocker") `
    -ExpectedProvenanceMode "simulated"
  Invoke-SelfTestChild `
    -Name "simulated real-tool execution bridge ready" `
    -Arguments @("-RealToolExecutionBridge", "-SimulateRealToolExecutionBridgeReady") `
    -ChildTempRoot (Join-Path $TempRoot "self-test-real-tool-execution-bridge-ready") `
    -ExpectedExitCode 0 `
    -ExpectedEvidenceClassifications @("pass") `
    -ExpectedProvenanceMode "simulated"
  Invoke-SelfTestChild `
    -Name "simulated real-tool closure marker current" `
    -Arguments @("-SimulateClosureMarkerCurrent") `
    -ChildTempRoot (Join-Path $TempRoot "self-test-closure-marker-current") `
    -ExpectedExitCode 0 `
    -ExpectedEvidenceAbsent
  Invoke-SelfTestChild `
    -Name "simulated real-tool closure marker stale" `
    -Arguments @("-SimulateClosureMarkerStale") `
    -ChildTempRoot (Join-Path $TempRoot "self-test-closure-marker-stale") `
    -ExpectedExitCode 1 `
    -ExpectedEvidenceAbsent
  Invoke-SelfTestChild `
    -Name "simulated real-tool closure marker simulated provenance" `
    -Arguments @("-SimulateClosureMarkerSimulated") `
    -ChildTempRoot (Join-Path $TempRoot "self-test-closure-marker-simulated") `
    -ExpectedExitCode 1 `
    -ExpectedEvidenceAbsent
  Invoke-SelfTestChild `
    -Name "simulated real-tool closure marker missing generated-client marker" `
    -Arguments @("-SimulateClosureMarkerMissingGenerated") `
    -ChildTempRoot (Join-Path $TempRoot "self-test-closure-marker-missing-generated") `
    -ExpectedExitCode 1 `
    -ExpectedEvidenceAbsent
  Invoke-SelfTestChild `
    -Name "simulated real-tool execution evidence pass" `
    -Arguments @("-SimulateRealExecutionEvidencePass") `
    -ChildTempRoot (Join-Path $TempRoot "self-test-real-execution-pass") `
    -ExpectedExitCode 0 `
    -ExpectedEvidenceClassifications @("pass") `
    -ExpectedProvenanceMode "simulated"
  Invoke-SelfTestChild `
    -Name "simulated real-tool execution evidence failure" `
    -Arguments @("-SimulateRealExecutionEvidenceFailure") `
    -ChildTempRoot (Join-Path $TempRoot "self-test-real-execution-failure") `
    -ExpectedExitCode 1 `
    -ExpectedEvidenceClassifications @("failure") `
    -ExpectedProvenanceMode "simulated"
  Invoke-SelfTestChild `
    -Name "simulated real-tool execution evidence blocker" `
    -Arguments @("-SimulateRealExecutionEvidenceBlocker") `
    -ChildTempRoot (Join-Path $TempRoot "self-test-real-execution-blocker") `
    -ExpectedExitCode 2 `
    -ExpectedEvidenceClassifications @("blocker") `
    -ExpectedProvenanceMode "simulated"
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
  Invoke-SelfTestChild `
    -Name "simulated real-tool preflight blocker evidence" `
    -Arguments @("-SimulateToolPreflightBlocker") `
    -ChildTempRoot (Join-Path $TempRoot "self-test-tool-preflight-blocker") `
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
  $cleanupOpenApiTools = Get-OpenApiGeneratorTransientConfigPath
  New-Item -ItemType Directory -Force $TempRoot | Out-Null
  New-Item -ItemType Directory -Force $cleanupOwnedDir | Out-Null
  Set-Content -Path $cleanupProbe -Value "wrapper-owned cleanup marker" -Encoding ascii
  Set-Content -Path $cleanupEvidence -Value "stale evidence should be removed by clean" -Encoding ascii
  Set-Content -Path $cleanupNonOwnedProbe -Value "non-owned marker should survive child clean" -Encoding ascii
  Set-Content -Path $cleanupOpenApiTools -Value '{ "generator-cli": { "version": "self-test" } }' -Encoding ascii
  Invoke-SelfTestChild -Name "artifact cleanup removes wrapper-owned artifacts" -Arguments @("-Clean") -ExpectedExitCode 0 -ExpectedEvidenceAbsent
  if (Test-Path $cleanupProbe) {
    Add-Failure "[FAIL] self-test artifact cleanup - wrapper-owned marker remained after -Clean"
  } elseif (Test-Path $cleanupEvidence) {
    Add-Failure "[FAIL] self-test artifact cleanup - stale evidence report remained after -Clean"
  } elseif (Test-Path $cleanupOwnedDir) {
    Add-Failure "[FAIL] self-test artifact cleanup - generated client artifact remained after -Clean"
  } elseif (Test-Path $cleanupOpenApiTools) {
    Add-Failure "[FAIL] self-test artifact cleanup - OpenAPI Generator transient config remained after -Clean"
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
  Write-GeneratedClientReadinessMarker `
    -Path $path `
    -Target "simulated-generated-client-pass" `
    -Tool "simulated-client-generator" `
    -ProvenanceMode "simulated" `
    -DurationMs 8 `
    -PackageCacheStatus "simulated" `
    -PackageDownloadAllowed $false
  Assert-GeneratedClientReadinessGate -Path $path -Label "simulated generated-client readiness pass"
  Exit-WithResult
}
if ($SimulateGeneratedClientMissingRequired) {
  $path = Join-Path $TempRoot "self-test-generated-client-missing-required"
  Write-SimulatedGeneratedClientFixture -Path $path -MissingRequired
  Write-GeneratedClientReadinessMarker `
    -Path $path `
    -Target "simulated-generated-client-missing-required" `
    -Tool "simulated-client-generator" `
    -ProvenanceMode "simulated" `
    -DurationMs 8 `
    -PackageCacheStatus "simulated" `
    -PackageDownloadAllowed $false
  Assert-GeneratedClientReadinessGate -Path $path -Label "simulated generated-client missing required field"
  Exit-WithResult
}
if ($SimulateGeneratedClientReadinessMissingOutput) {
  $path = Join-Path $TempRoot "self-test-generated-client-missing-output"
  Assert-GeneratedClientReadinessGate -Path $path -Label "simulated generated-client readiness missing output"
  Exit-WithResult
}
if ($SimulateGeneratedClientReadinessStaleMarker) {
  $path = Join-Path $TempRoot "self-test-generated-client-stale-marker"
  Write-SimulatedGeneratedClientFixture -Path $path
  Write-GeneratedClientReadinessMarker `
    -Path $path `
    -Target "simulated-generated-client-stale-marker" `
    -Tool "simulated-client-generator" `
    -ProvenanceMode "simulated" `
    -OpenApiSha256 "0000000000000000000000000000000000000000000000000000000000000000" `
    -DurationMs 8 `
    -PackageCacheStatus "simulated" `
    -PackageDownloadAllowed $false
  Assert-GeneratedClientReadinessGate -Path $path -Label "simulated generated-client readiness stale marker"
  Exit-WithResult
}
if ($SimulateGeneratedClientReadinessUnsafeTarget) {
  $path = Join-Path $repoRoot "scripts\self-test-generated-client-unsafe-target"
  Assert-GeneratedClientReadinessGate -Path $path -Label "simulated generated-client readiness unsafe target"
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
if ($SimulateToolPreflightBlocker) {
  Add-SimulatedToolPreflightBlockerEvidence
  Add-Blocker "[BLOCKED] simulated real-tool preflight blocker - required local tool unavailable"
  Exit-WithResult
}

if ($SimulateCacheProbe) {
  Add-OpenApiCacheProbeEvidence -Simulated
  Exit-WithResult
}
if ($SimulatePackageMaterializationBoundary) {
  Add-OpenApiPackageMaterializationEvidence -Simulated
  Exit-WithResult
}
if ($SimulateRealToolReadinessCurrent) {
  [void](Add-RealToolReadinessEvidence -SimulatedCurrent)
  Exit-WithResult
}
if ($SimulateRealToolReadinessStale) {
  [void](Add-RealToolReadinessEvidence -SimulatedStale)
  Exit-WithResult
}
if ($SimulateRealToolExecutionBridgeReady) {
  Invoke-RealToolExecutionBridge -SimulatedReady
  Exit-WithResult
}
if ($SimulateClosureMarkerCurrent) {
  Invoke-SimulatedClosureMarkerCase -Case "current"
}
if ($SimulateClosureMarkerStale) {
  Invoke-SimulatedClosureMarkerCase -Case "stale"
}
if ($SimulateClosureMarkerSimulated) {
  Invoke-SimulatedClosureMarkerCase -Case "simulated"
}
if ($SimulateClosureMarkerMissingGenerated) {
  Invoke-SimulatedClosureMarkerCase -Case "missing_generated"
}
if ($SimulateRealExecutionEvidencePass) {
  Add-SimulatedRealExecutionEvidence -Classification "pass"
  Exit-WithResult
}
if ($SimulateRealExecutionEvidenceFailure) {
  Add-SimulatedRealExecutionEvidence -Classification "failure"
  Add-Failure "[FAIL] simulated real-tool execution evidence failure - semantic/client mismatch"
  Exit-WithResult
}
if ($SimulateRealExecutionEvidenceBlocker) {
  Add-SimulatedRealExecutionEvidence -Classification "blocker"
  Add-Blocker "[BLOCKED] simulated real-tool execution evidence blocker - tool/cache unavailable"
  Exit-WithResult
}

if ($CommandMatrix) {
  Write-OpenApiCommandMatrix
  Exit-WithResult
}

if ($CacheProbe) {
  Add-OpenApiCacheProbeEvidence
  Exit-WithResult
}

if ($MaterializePackageCache) {
  Add-OpenApiPackageMaterializationEvidence
  Exit-WithResult
}

if ($RealToolReadiness) {
  [void](Add-RealToolReadinessEvidence)
  Exit-WithResult
}

if ($RealToolExecutionBridge) {
  Invoke-RealToolExecutionBridge
  Exit-WithResult
}

if (-not ($Redocly -or $OpenApiGeneratorValidate -or $OpenApiTypescript -or $TypescriptFetch)) {
  Write-SafeHost "[OK] semantic/client generation tools were not requested; default mode performed lightweight gate only."
  Exit-WithResult
}

if (-not (Assert-ControlledRealToolExecutionPassGate)) {
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
