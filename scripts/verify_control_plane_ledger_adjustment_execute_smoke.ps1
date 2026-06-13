param(
  [string]$ControlPlaneBaseUrl = "http://127.0.0.1:8081",
  [string]$AdminEmail = "admin@example.com",
  [string]$AdminPassword = "local-password",
  [string]$AdminSessionToken = "",
  [string]$AdminUiBaseUrl = "http://127.0.0.1:5173",
  [string]$ComposeFile = "deploy/docker-compose/docker-compose.yml",
  [int]$TimeoutSeconds = 10,
  [int]$BrowserProbeTimeoutMilliseconds = 750,
  [string]$BrowserEvidenceArtifactPath = "artifacts/billing_execute_browser_live_e2e_evidence.json",
  [string]$RuntimeCurrentEvidenceArtifactPath = "artifacts/control_plane_ledger_execute_runtime_current_handoff.json",
  [switch]$BrowserAdminUiDevServerOptIn,
  [switch]$BrowserEvidenceArtifactReadbackOptIn,
  [switch]$BrowserEvidenceArtifactWriteOptIn,
  [switch]$BrowserLiveRunnerExecutionOptIn,
  [switch]$BrowserMutationOptIn,
  [switch]$BrowserPreflight,
  [switch]$RuntimeCurrentNoBuildRecreateOptIn,
  [switch]$RuntimeCurrentRebuildHandoffOptIn,
  [switch]$RuntimeCurrentEvidenceArtifactWriteOptIn,
  [switch]$RuntimeCurrentEvidenceArtifactReadbackOptIn,
  [switch]$AdminSessionHandoff,
  [switch]$ArtifactReadbackOnly,
  [switch]$ContractOnly,
  [switch]$KeepSmokeRows
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$fixturePath = Join-Path $repoRoot "tests\fixtures\control-plane\ledger_adjustment_execute_live_smoke.json"
$dryRunContractPath = Join-Path $repoRoot "tests\fixtures\control-plane\ledger_adjustment_dry_run_contract.json"
$uiSmokeHandoffPath = Join-Path $repoRoot "web\admin-ui\src\billingExecuteSmokeContract.serializable.json"
$uiSmokeContractPath = Join-Path $repoRoot "web\admin-ui\src\billingExecuteSmokeContract.ts"
$uiSmokeContractTestPath = Join-Path $repoRoot "web\admin-ui\src\App.test.tsx"
$adminSourcePath = Join-Path $repoRoot "apps\control-plane\src\admin.rs"

$script:Failures = @()
$script:Blockers = @()
$script:SensitiveValues = @()
$script:AdminSessionToken = $AdminSessionToken
$script:CreatedLedgerEntryIds = @()
$script:SourceLedgerEntryIds = @()
$script:CreatedAuditLogIds = @()
$script:Fixture = $null
$script:SmokeRunId = ([guid]::NewGuid().ToString("N"))
$script:RuntimeSourceProbe = $null

if ($env:CONTROL_PLANE_BASE_URL) { $ControlPlaneBaseUrl = $env:CONTROL_PLANE_BASE_URL }
if ($env:ADMIN_UI_BASE_URL) { $AdminUiBaseUrl = $env:ADMIN_UI_BASE_URL }
if ($env:CONTROL_PLANE_ADMIN_EMAIL) { $AdminEmail = $env:CONTROL_PLANE_ADMIN_EMAIL }
if ($env:CONTROL_PLANE_ADMIN_PASSWORD) { $AdminPassword = $env:CONTROL_PLANE_ADMIN_PASSWORD }
if ($env:CONTROL_PLANE_ADMIN_SESSION_TOKEN) { $script:AdminSessionToken = $env:CONTROL_PLANE_ADMIN_SESSION_TOKEN }
if ($env:COMPOSE_FILE) { $ComposeFile = $env:COMPOSE_FILE }
if ($env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_PROBE_TIMEOUT_MS) { $BrowserProbeTimeoutMilliseconds = [int]$env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_PROBE_TIMEOUT_MS }
if ($env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_ARTIFACT_PATH) { $BrowserEvidenceArtifactPath = $env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_ARTIFACT_PATH }
if ($env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_RUNTIME_CURRENT_ARTIFACT_PATH) { $RuntimeCurrentEvidenceArtifactPath = $env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_RUNTIME_CURRENT_ARTIFACT_PATH }
if ($env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_ADMIN_UI_DEV_SERVER -eq "1") { $BrowserAdminUiDevServerOptIn = $true }
if ($env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_ARTIFACT_READBACK -eq "1") { $BrowserEvidenceArtifactReadbackOptIn = $true }
if ($env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_ARTIFACT_WRITE -eq "1") { $BrowserEvidenceArtifactWriteOptIn = $true }
if ($env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_RUNNER -eq "1") { $BrowserLiveRunnerExecutionOptIn = $true }
if ($env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_PREFLIGHT -eq "1") { $BrowserPreflight = $true }
if ($env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_RUNTIME_CURRENT_RECREATE -eq "1") { $RuntimeCurrentNoBuildRecreateOptIn = $true }
if ($env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_RUNTIME_CURRENT_REBUILD_HANDOFF -eq "1") { $RuntimeCurrentRebuildHandoffOptIn = $true }
if ($env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_RUNTIME_CURRENT_ARTIFACT_WRITE -eq "1") { $RuntimeCurrentEvidenceArtifactWriteOptIn = $true }
if ($env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_RUNTIME_CURRENT_ARTIFACT_READBACK -eq "1") { $RuntimeCurrentEvidenceArtifactReadbackOptIn = $true }
if ($env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_ADMIN_SESSION_HANDOFF -eq "1") { $AdminSessionHandoff = $true }
if ($env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_ARTIFACT_READBACK_ONLY -eq "1") { $ArtifactReadbackOnly = $true }
if ($env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_SMOKE_CONTRACT_ONLY -eq "1") { $ContractOnly = $true }
if ($env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_SMOKE_KEEP_ROWS -eq "1") { $KeepSmokeRows = $true }
if ($ArtifactReadbackOnly) {
  $BrowserEvidenceArtifactReadbackOptIn = $true
  $RuntimeCurrentEvidenceArtifactReadbackOptIn = $true
  if (
    -not $env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_RUNTIME_CURRENT_ARTIFACT_PATH -and
    [string]$RuntimeCurrentEvidenceArtifactPath -eq "artifacts/control_plane_ledger_execute_runtime_current_handoff.json"
  ) {
    $RuntimeCurrentEvidenceArtifactPath = "artifacts/control_plane_ledger_execute_runtime_current_verified_beta.json"
  }
}
if (
  $BrowserPreflight -and
  -not $BrowserMutationOptIn -and
  -not $BrowserEvidenceArtifactWriteOptIn -and
  -not $BrowserLiveRunnerExecutionOptIn -and
  $env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_MUTATION -ne "1"
) { $ContractOnly = $true }

Add-Type -AssemblyName System.Net.Http

function Add-SensitiveValue {
  param([AllowNull()][string]$Value)

  if (-not [string]::IsNullOrWhiteSpace($Value)) {
    $script:SensitiveValues += [string]$Value
  }
}

Add-SensitiveValue $AdminPassword
Add-SensitiveValue $script:AdminSessionToken

function Redact-SecretLikeString {
  param([AllowNull()][string]$Text)

  if ($null -eq $Text) {
    return ""
  }

  $redacted = [string]$Text
  foreach ($secret in $script:SensitiveValues) {
    if (-not [string]::IsNullOrEmpty($secret)) {
      $redacted = $redacted.Replace($secret, "[REDACTED]")
    }
  }

  $redacted = $redacted -replace '(?i)("session_token_once"\s*:\s*")[^"]+(")', '$1[REDACTED]$2'
  $redacted = $redacted -replace '(?i)(x-admin-session\s*[:=]\s*)[^\s";,]+', '$1[REDACTED]'
  $redacted = $redacted -replace '(?i)(authorization\s*[:=]\s*bearer\s+)[^\s";,]+', '$1[REDACTED]'
  $redacted = $redacted -replace '(?i)(Bearer\s+)[A-Za-z0-9._~+/\-]+=*', '$1[REDACTED]'
  $redacted = $redacted -replace '(?i)((?:password|passwd|secret|token|session|api[_-]?key|access[_-]?key|private[_-]?key|provider[_-]?key)\s*[:=]\s*)[^\s";,}]+', '$1[REDACTED]'
  $redacted = $redacted -replace 'sess_[A-Za-z0-9._~+/\-=]+', '[REDACTED]'
  $redacted = $redacted -replace 'sk-[A-Za-z0-9._~+\-/=]+', '[REDACTED]'
  return $redacted
}

function Write-SafeHost {
  param([AllowNull()][string]$Text)

  Write-Host (Redact-SecretLikeString $Text)
}

function Add-Failure {
  param([Parameter(Mandatory = $true)][string]$Message)

  $safe = Redact-SecretLikeString $Message
  $script:Failures += $safe
  Write-SafeHost $safe
}

function Add-Blocker {
  param([Parameter(Mandatory = $true)][string]$Message)

  $safe = Redact-SecretLikeString $Message
  $script:Blockers += $safe
  Write-SafeHost "[BLOCKED] $safe"
}

function Check {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][scriptblock]$Action
  )

  try {
    & $Action
    Write-SafeHost "[OK] $Name"
  } catch {
    Write-SafeHost "check_failure_location=$($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)"
    Write-SafeHost "check_failure_stack=$($_.ScriptStackTrace)"
    Add-Failure "[FAIL] $Name - $($_.Exception.Message)"
  }
}

function Check-Blocking {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][scriptblock]$Action
  )

  try {
    & $Action
    Write-SafeHost "[OK] $Name"
  } catch {
    Add-Blocker "$Name - $($_.Exception.Message)"
  }
}

function Exit-WithFailuresOrBlockers {
  if ($script:Failures.Count -gt 0) {
    Write-SafeHost ""
    Write-SafeHost "Control Plane ledger adjustment execute smoke failed:"
    foreach ($failure in $script:Failures) {
      Write-SafeHost $failure
    }
    exit 1
  }

  if ($script:Blockers.Count -gt 0) {
    Write-SafeHost ""
    Write-SafeHost "Control Plane ledger adjustment execute smoke is externally blocked:"
    foreach ($blocker in $script:Blockers) {
      Write-SafeHost $blocker
    }
    exit 2
  }
}

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path $Path)) {
    throw "missing $Path"
  }

  try {
    return Get-Content -Path $Path -Raw | ConvertFrom-Json
  } catch {
    throw "invalid JSON at $Path`: $($_.Exception.Message)"
  }
}

function Read-Json {
  param([Parameter(Mandatory = $true)][string]$Content)

  try {
    return $Content | ConvertFrom-Json
  } catch {
    throw "expected JSON response, got: $(Redact-SecretLikeString $Content)"
  }
}

function Get-CurrentGitCommit {
  try {
    $commit = & git -C $repoRoot rev-parse HEAD 2>$null
    if (-not [string]::IsNullOrWhiteSpace($commit)) {
      return [string]$commit.Trim()
    }
  } catch {
  }
  return "unavailable"
}

function Invoke-NativeCapture {
  param(
    [Parameter(Mandatory = $true)][string]$Command,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )

  $global:LASTEXITCODE = 0
  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & $Command @Arguments 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }

  return [pscustomobject]@{
    ExitCode = $exitCode
    Output = (($output | Out-String).Trim())
  }
}

function Get-NewestSourceWriteTimeUtc {
  param([Parameter(Mandatory = $true)][string[]]$SourcePaths)

  $newest = $null
  foreach ($path in $SourcePaths) {
    if (-not (Test-Path $path -PathType Leaf)) {
      continue
    }
    $writeTime = (Get-Item -Path $path).LastWriteTimeUtc
    if ($null -eq $newest -or $writeTime -gt $newest) {
      $newest = $writeTime
    }
  }
  return $newest
}

function Get-ControlPlaneRuntimeSourcePaths {
  return @($adminSourcePath, $dryRunContractPath)
}

function Get-VerifierScriptWriteTimeUtcText {
  if (Test-Path $PSCommandPath -PathType Leaf) {
    return (Get-Item -Path $PSCommandPath).LastWriteTimeUtc.ToString("o")
  }
  return "unavailable"
}

function Parse-DockerTimestampUtc {
  param([AllowNull()][string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $null
  }
  try {
    return ([DateTimeOffset]::Parse([string]$Value)).UtcDateTime
  } catch {
    return $null
  }
}

function Convert-JsonTimestampToUtc {
  param([Parameter(Mandatory = $true)]$Value)

  if ($Value -is [DateTime]) {
    if ($Value.Kind -eq [DateTimeKind]::Unspecified) {
      return [DateTime]::SpecifyKind($Value, [DateTimeKind]::Utc)
    }
    return $Value.ToUniversalTime()
  }

  return [DateTime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}

function Test-StrictTrue {
  param([AllowNull()]$Value)

  if ($Value -is [bool]) {
    return $Value
  }
  return ([string]$Value).ToLowerInvariant() -eq "true"
}

function Get-RuntimeCurrentHandoffCommand {
  $composeArg = if ($ComposeFile -eq "deploy/docker-compose/docker-compose.yml") {
    "deploy/docker-compose/docker-compose.yml"
  } else {
    "[compose-file]"
  }
  return "docker compose -f $composeArg up -d --no-build --no-deps --force-recreate control-plane"
}

function Get-RuntimeCurrentRebuildHandoffCommand {
  $composeArg = if ($ComposeFile -eq "deploy/docker-compose/docker-compose.yml") {
    "deploy/docker-compose/docker-compose.yml"
  } else {
    "[compose-file]"
  }
  return "docker compose -f $composeArg build control-plane && docker compose -f $composeArg up -d --no-deps --force-recreate control-plane"
}

function New-RuntimeCurrentHandoffEvidence {
  param(
    [Parameter(Mandatory = $true)][bool]$StaleOrUnverified,
    [Parameter(Mandatory = $true)][string]$Reason,
    [string]$SourceNewestUtc = "unavailable",
    [string]$ContainerCreatedUtc = "unavailable",
    [string]$ImageCreatedUtc = "unavailable",
    [string]$ImageId = "unavailable",
    [string]$GitCommit = "",
    [bool]$NoBuildRecreateOptIn = $false,
    [bool]$NoBuildRecreateExecuted = $false,
    [string]$NoBuildRecreateExitCode = "not_run",
    [bool]$RebuildHandoffOptIn = $false,
    [bool]$RebuildHandoffRecorded = $false
  )

  $status = "ready"
  $blocker = "none"
  $classification = "container_recreate_available"
  $readbackClassification = "runtime_current_readback_verified"
  $afterRecreateClassification = "runtime_current_after_recreate_verified"
  $buildRequired = $false
  if ([string]::IsNullOrWhiteSpace($GitCommit)) {
    $GitCommit = Get-CurrentGitCommit
  }

  if ($StaleOrUnverified) {
    $status = "blocked"
    $readbackClassification = "runtime_current_readback_stale_or_unverified"
    $afterRecreateClassification = "runtime_current_after_recreate_unverified"
    if ($Reason -eq "source_newer_than_runtime_image") {
      $classification = "source_newer_than_runtime_image"
      $blocker = "runtime_image_requires_rebuild_but_build_forbidden"
      $buildRequired = $true
    } elseif ($Reason -eq "control_plane_container_unavailable") {
      $classification = "control_plane_container_unavailable"
      $blocker = "control_plane_container_unavailable_for_no_build_handoff"
    } elseif ($Reason -eq "docker_unavailable") {
      $classification = "docker_unavailable"
      $blocker = "docker_unavailable_for_no_build_handoff"
      $readbackClassification = "runtime_current_readback_failed"
    } elseif ($Reason -eq "control_plane_image_inspect_unavailable") {
      $classification = "control_plane_image_inspect_unavailable"
      $blocker = "runtime_current_unverified_for_no_build_handoff"
      $readbackClassification = "runtime_current_readback_failed"
    } else {
      $classification = "runtime_current_after_recreate_unverified"
      $blocker = "runtime_current_unverified_for_no_build_handoff"
    }
  }

  return [PSCustomObject]@{
    schema = "control_plane_ledger_execute_runtime_current_handoff.v1"
    status = $status
    classification = $classification
    blocker = $blocker
    reason = $Reason
    source_newest_utc = $SourceNewestUtc
    container_created_utc = $ContainerCreatedUtc
    image_created_utc = $ImageCreatedUtc
    image_id = $ImageId
    git_commit = $GitCommit
    alignment_rules = [PSCustomObject]@{
      source_timestamp_must_not_exceed_image_created_utc = $true
      container_created_utc_must_be_available = $true
      image_created_utc_must_be_available = $true
      image_id_must_be_available = $true
      git_commit_marker_required = $true
      stale_image_is_blocker = $true
      no_build_recreate_classification = "container_recreate_available"
      rebuild_handoff_classification = "source_newer_than_runtime_image"
    }
    build_allowed = $false
    build_required = $buildRequired
    no_build_recreate_opt_in = $NoBuildRecreateOptIn
    no_build_recreate_executed = $NoBuildRecreateExecuted
    no_build_recreate_exit_code = $NoBuildRecreateExitCode
    rebuild_handoff_opt_in = $RebuildHandoffOptIn
    rebuild_handoff_recorded = $RebuildHandoffRecorded
    no_build_recreate_command = Get-RuntimeCurrentHandoffCommand
    rebuild_handoff_command = Get-RuntimeCurrentRebuildHandoffCommand
    rebuild_handoff_execution_allowed = $false
    operator_command_classification = "operator_command_generated"
    readback_classification = $readbackClassification
    after_recreate_classification = $afterRecreateClassification
    secret_material_echoed = $false
    url_credentials_echoed = $false
    request_material_echoed = $false
  }
}

function Write-RuntimeCurrentHandoff {
  param(
    [Parameter(Mandatory = $true)][bool]$StaleOrUnverified,
    [Parameter(Mandatory = $true)][string]$Reason,
    [string]$SourceNewestUtc = "unavailable",
    [string]$ContainerCreatedUtc = "unavailable",
    [string]$ImageCreatedUtc = "unavailable",
    [string]$ImageId = "unavailable"
  )

  $evidence = New-RuntimeCurrentHandoffEvidence -StaleOrUnverified $StaleOrUnverified -Reason $Reason -SourceNewestUtc $SourceNewestUtc -ContainerCreatedUtc $ContainerCreatedUtc -ImageCreatedUtc $ImageCreatedUtc -ImageId $ImageId

  Write-SafeHost "runtime_current_handoff=control_plane_no_build_recreate"
  Write-SafeHost "runtime_current_handoff_status=$($evidence.status)"
  Write-SafeHost "runtime_current_handoff_classification=$($evidence.classification)"
  Write-SafeHost "runtime_current_handoff_blocker=$($evidence.blocker)"
  Write-SafeHost "runtime_current_handoff_command=$($evidence.no_build_recreate_command)"
  Write-SafeHost "runtime_current_handoff_operator_command_classification=$($evidence.operator_command_classification)"
  Write-SafeHost "runtime_current_handoff_rebuild_command=$($evidence.rebuild_handoff_command)"
  Write-SafeHost "runtime_current_handoff_build_required=$(Format-BoolMarker ([bool]$evidence.build_required))"
  Write-SafeHost "runtime_current_handoff_build_allowed=false"
  Write-SafeHost "runtime_current_handoff_readback_classification=$($evidence.readback_classification)"
  Write-SafeHost "runtime_current_handoff_after_recreate_classification=$($evidence.after_recreate_classification)"
  Write-SafeHost "runtime_current_handoff_evidence_json=$(($evidence | ConvertTo-Json -Depth 8 -Compress))"
  Write-SafeHost "runtime_current_handoff_secret_material_echoed=false"
  Write-SafeHost "runtime_current_handoff_url_credentials_echoed=false"
  Write-SafeHost "runtime_current_handoff_request_material_echoed=false"
}

function Write-ControlPlaneRuntimeSourceProbe {
  param([Parameter(Mandatory = $true)][string[]]$SourcePaths)

  $sourceNewest = Get-NewestSourceWriteTimeUtc -SourcePaths $SourcePaths
  $sourceNewestText = if ($null -eq $sourceNewest) { "unavailable" } else { $sourceNewest.ToString("o") }
  $reason = "none"
  $staleOrUnverified = $false
  $containerCreatedText = "unavailable"
  $imageCreatedText = "unavailable"
  $imageIdText = "unavailable"

  try {
    $docker = Get-DockerCommand
  } catch {
    $docker = ""
  }

  if ([string]::IsNullOrWhiteSpace($docker)) {
    $reason = "docker_unavailable"
    $staleOrUnverified = $true
  } else {
    $containerIdResult = Invoke-NativeCapture -Command $docker -Arguments @("compose", "-f", $ComposeFile, "ps", "-q", "control-plane")
    $containerId = [string]$containerIdResult.Output
    if ($containerIdResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($containerId)) {
      $reason = "control_plane_container_unavailable"
      $staleOrUnverified = $true
    } else {
      $inspectResult = Invoke-NativeCapture -Command $docker -Arguments @("inspect", "-f", "{{.Created}}|{{.Image}}", $containerId.Trim())
      if ($inspectResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($inspectResult.Output)) {
        $reason = "control_plane_container_inspect_unavailable"
        $staleOrUnverified = $true
      } else {
        $parts = ([string]$inspectResult.Output).Split("|", 2)
        $containerCreated = Parse-DockerTimestampUtc $parts[0]
        if ($null -ne $containerCreated) {
          $containerCreatedText = $containerCreated.ToString("o")
        }
        $imageId = if ($parts.Count -gt 1) { $parts[1] } else { "" }
        if (-not [string]::IsNullOrWhiteSpace($imageId)) {
          $imageIdText = [string]$imageId
        }
        $imageInspectResult = Invoke-NativeCapture -Command $docker -Arguments @("image", "inspect", "-f", "{{.Created}}", $imageId)
        $imageCreated = $null
        if ($imageInspectResult.ExitCode -eq 0) {
          $imageCreated = Parse-DockerTimestampUtc $imageInspectResult.Output
          if ($null -ne $imageCreated) {
            $imageCreatedText = $imageCreated.ToString("o")
          }
        }
        if ($null -eq $imageCreated) {
          $reason = "control_plane_image_inspect_unavailable"
          $staleOrUnverified = $true
        } elseif ($null -eq $sourceNewest) {
          $reason = "source_timestamp_unavailable"
          $staleOrUnverified = $true
        } elseif ($sourceNewest -gt $imageCreated) {
          $reason = "source_newer_than_runtime_image"
          $staleOrUnverified = $true
        }
      }
    }
  }

  Write-SafeHost "runtime_source_mismatch_probe=control_plane_image_timestamp"
  Write-SafeHost "runtime_source_newest_utc=$sourceNewestText"
  Write-SafeHost "runtime_verifier_script_newest_utc=$(Get-VerifierScriptWriteTimeUtcText)"
  Write-SafeHost "runtime_verifier_script_affects_image_freshness=false"
  Write-SafeHost "runtime_container_created_utc=$containerCreatedText"
  Write-SafeHost "runtime_image_created_utc=$imageCreatedText"
  Write-SafeHost "runtime_image_id=$imageIdText"
  Write-SafeHost "runtime_git_commit=$(Get-CurrentGitCommit)"
  Write-SafeHost "runtime_image_stale_or_unverified=$(if ($staleOrUnverified) { 'true' } else { 'false' })"
  Write-SafeHost "runtime_image_stale_reason=$reason"
  Write-SafeHost "runtime_secret_material_echoed=false"
  Write-RuntimeCurrentHandoff -StaleOrUnverified $staleOrUnverified -Reason $reason -SourceNewestUtc $sourceNewestText -ContainerCreatedUtc $containerCreatedText -ImageCreatedUtc $imageCreatedText -ImageId $imageIdText

  return [pscustomobject]@{
    StaleOrUnverified = $staleOrUnverified
    Reason = $reason
    SourceNewestUtc = $sourceNewestText
    ContainerCreatedUtc = $containerCreatedText
    ImageCreatedUtc = $imageCreatedText
    ImageId = $imageIdText
    GitCommit = Get-CurrentGitCommit
  }
}

function Get-BrowserRuntimeCurrentEvidence {
  if ($null -eq $script:RuntimeSourceProbe) {
    return [PSCustomObject]@{
      classification = "runtime_current_not_checked"
      stale_or_unverified = $true
      reason = "runtime_current_probe_not_run"
    source_newest_utc = "unavailable"
    container_created_utc = "unavailable"
    image_created_utc = "unavailable"
    image_id = "unavailable"
    git_commit = Get-CurrentGitCommit
    blocker = "runtime_current_unverified_for_no_build_handoff"
    }
  }

  $runtimeProbeStale = Test-StrictTrue $script:RuntimeSourceProbe.StaleOrUnverified
  $classification = if ($runtimeProbeStale) { "runtime_image_stale_or_unverified" } else { "runtime_current_verified" }
  $blocker = if ($runtimeProbeStale) { "runtime_image_stale_or_unverified" } else { "none" }
  return [PSCustomObject]@{
    classification = $classification
    stale_or_unverified = $runtimeProbeStale
    reason = [string]$script:RuntimeSourceProbe.Reason
    source_newest_utc = [string]$script:RuntimeSourceProbe.SourceNewestUtc
    container_created_utc = [string]$script:RuntimeSourceProbe.ContainerCreatedUtc
    image_created_utc = [string]$script:RuntimeSourceProbe.ImageCreatedUtc
    image_id = [string]$script:RuntimeSourceProbe.ImageId
    git_commit = [string]$script:RuntimeSourceProbe.GitCommit
    blocker = $blocker
  }
}

function Resolve-BoundedEvidenceArtifactPath {
  param([Parameter(Mandatory = $true)][string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw "browser evidence artifact path is empty"
  }

  $repoRootString = [System.IO.Path]::GetFullPath([string]$repoRoot)
  $candidate = $Path
  if (-not [System.IO.Path]::IsPathRooted($candidate)) {
    $candidate = Join-Path $repoRootString $candidate
  }
  $fullPath = [System.IO.Path]::GetFullPath($candidate)
  $repoPrefix = $repoRootString.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  if (-not ($fullPath.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase))) {
    throw "browser evidence artifact path must stay inside repo"
  }
  if ([System.IO.Directory]::Exists($fullPath)) {
    throw "browser evidence artifact path must be a file"
  }
  return $fullPath
}

function Assert-Equal {
  param(
    [Parameter(Mandatory = $true)][object]$Actual,
    [Parameter(Mandatory = $true)][object]$Expected,
    [Parameter(Mandatory = $true)][string]$Message
  )

  if ([string]$Actual -ne [string]$Expected) {
    throw "${Message}: expected '$Expected', got '$Actual'"
  }
}

function Assert-True {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Message
  )

  if (-not $Condition) {
    throw $Message
  }
}

function Assert-StatusAny {
  param(
    [Parameter(Mandatory = $true)]$Response,
    [Parameter(Mandatory = $true)][int[]]$Expected
  )

  if ($Expected -notcontains [int]$Response.StatusCode) {
    throw "expected HTTP $($Expected -join '/'), got HTTP $($Response.StatusCode): $(Redact-SecretLikeString $Response.Content)"
  }
}

function Assert-SecretSafeContent {
  param(
    [Parameter(Mandatory = $true)][string]$Content,
    [Parameter(Mandatory = $true)][string]$Context
  )

  foreach ($forbidden in @(
      "idempotency_key",
      "usage_snapshot",
      "policy_snapshot",
      "encrypted_secret",
      "secret_fingerprint",
      "provider_key_secret",
      "provider_key_value",
      "Authorization",
      "Bearer ",
      "sk-",
      "raw ledger material",
      "never-return"
    )) {
    if ($Content.Contains($forbidden)) {
      throw "$Context leaked forbidden material marker '$forbidden'"
    }
  }
}

function Join-Url {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$Path
  )

  $normalizedPath = $Path
  if (-not $normalizedPath.StartsWith("/")) {
    $normalizedPath = "/$normalizedPath"
  }

  return $BaseUrl.TrimEnd("/") + $normalizedPath
}

function Invoke-ControlPlaneRequest {
  param(
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Path,
    [object]$Body = $null,
    [string]$SessionToken = $script:AdminSessionToken,
    [int]$TimeoutSec = $TimeoutSeconds
  )

  if (($Method -eq "GET" -or $Method -eq "HEAD") -and $null -ne $Body) {
    throw "$Method requests must not include a JSON body"
  }

  $client = New-Object System.Net.Http.HttpClient
  $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
  $request = New-Object System.Net.Http.HttpRequestMessage -ArgumentList (New-Object System.Net.Http.HttpMethod -ArgumentList $Method), (Join-Url $ControlPlaneBaseUrl $Path)
  if (-not [string]::IsNullOrWhiteSpace($SessionToken)) {
    [void]$request.Headers.TryAddWithoutValidation("X-Admin-Session", $SessionToken)
  }

  if ($null -ne $Body) {
    $json = $Body | ConvertTo-Json -Depth 32 -Compress
    $content = New-Object System.Net.Http.StringContent -ArgumentList $json
    $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/json")
    $request.Content = $content
  }

  $response = $null
  try {
    $response = $client.SendAsync($request).GetAwaiter().GetResult()
    return [PSCustomObject]@{
      StatusCode = [int]$response.StatusCode
      Content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    }
  } catch [System.Threading.Tasks.TaskCanceledException] {
    throw "request timed out after $TimeoutSec seconds"
  } finally {
    if ($response) { $response.Dispose() }
    $request.Dispose()
    $client.Dispose()
  }
}

function Initialize-AdminSession {
  if (-not [string]::IsNullOrWhiteSpace($script:AdminSessionToken)) {
    Add-SensitiveValue $script:AdminSessionToken
    return
  }

  $response = Invoke-ControlPlaneRequest -Method POST -Path "/admin/auth/login" -Body @{
    email = $AdminEmail
    password = $AdminPassword
  } -SessionToken ""
  Assert-StatusAny $response @(200)
  $payload = Read-Json $response.Content
  $token = [string]$payload.data.session_token_once
  if ([string]::IsNullOrWhiteSpace($token)) {
    throw "login response did not include data.session_token_once"
  }

  $script:AdminSessionToken = $token
  Add-SensitiveValue $token
}

function Invoke-ComposePsql {
  param([Parameter(Mandatory = $true)][string]$Sql)

  Push-Location $repoRoot
  try {
    $output = Invoke-Docker compose -f $ComposeFile exec -T postgres psql `
      -U ai_gateway `
      -d ai_gateway `
      -tA `
      -v ON_ERROR_STOP=1 `
      -c $Sql

    if ($LASTEXITCODE -ne 0) {
      throw "psql failed with exit code $LASTEXITCODE"
    }

    return (($output | Out-String).Trim())
  } finally {
    Pop-Location
  }
}

function Invoke-ComposePsqlJson {
  param([Parameter(Mandatory = $true)][string]$Sql)

  $content = Invoke-ComposePsql $Sql
  if ([string]::IsNullOrWhiteSpace($content)) {
    throw "psql returned no JSON"
  }
  return $content | ConvertFrom-Json
}

function Escape-SqlLiteral {
  param([Parameter(Mandatory = $true)][string]$Value)

  return $Value.Replace("'", "''")
}

function New-SmokeGuid {
  return [guid]::NewGuid().ToString()
}

function UuidListSql {
  param([string[]]$Ids)

  $filtered = @($Ids | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($filtered.Count -eq 0) {
    return "array[]::uuid[]"
  }

  $items = @($filtered | ForEach-Object { "'$($_)'::uuid" })
  return "array[$($items -join ',')]"
}

function Assert-SmokeFixture {
  param([Parameter(Mandatory = $true)]$Fixture)

  Assert-Equal $Fixture.scenario "control_plane_ledger_adjustment_execute_live_postgres_smoke" "fixture scenario"
  Assert-Equal $Fixture.endpoint.method "POST" "fixture endpoint method"
  Assert-Equal $Fixture.endpoint.path "/admin/ledger/adjustments/dry-run" "fixture endpoint path"
  Assert-Equal $Fixture.endpoint.required_permission "billing_adjust" "fixture required permission"
  Assert-Equal $Fixture.endpoint.execute_mode "execute" "fixture execute mode"
  Assert-Equal $Fixture.external_blocked_exit_code 2 "fixture blocked exit code"
  Assert-True ($Fixture.default_tests_require_live_db -eq $false) "fixture must state default tests do not require live DB"
  Assert-Equal $Fixture.gate_contract.scripts_test_default.mode "contract_only" "fixture test gate default mode"
  Assert-True ($Fixture.gate_contract.scripts_test_default.requires_live_db -eq $false) "fixture test gate default must not require live DB"
  Assert-Equal $Fixture.gate_contract.scripts_test_live_opt_in.flag "-ControlPlaneLedgerAdjustmentExecuteSmokeLive" "fixture test live flag"
  Assert-Equal $Fixture.gate_contract.scripts_test_live_opt_in.env "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_SMOKE_LIVE" "fixture test live env"
  Assert-Equal $Fixture.gate_contract.admin_session_handoff.flag "-AdminSessionHandoff" "fixture admin session handoff flag"
  Assert-Equal $Fixture.gate_contract.admin_session_handoff.env "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_ADMIN_SESSION_HANDOFF" "fixture admin session handoff env"
  Assert-Equal $Fixture.gate_contract.admin_session_handoff.session_env "CONTROL_PLANE_ADMIN_SESSION_TOKEN" "fixture admin session handoff session env"
  Assert-True ($Fixture.gate_contract.admin_session_handoff.requires_live_db -eq $false) "fixture admin session handoff must not require live DB"
  Assert-Equal $Fixture.gate_contract.admin_session_handoff.login_401_blocked_exit_code 2 "fixture admin session handoff login 401 exit"
  Assert-Equal $Fixture.gate_contract.admin_session_handoff.session_present_marker "admin_session_present" "fixture admin session present marker"
  Assert-True ($Fixture.gate_contract.admin_session_handoff.token_echoed -eq $false) "fixture admin session token must not be echoed"
  Assert-True ($Fixture.gate_contract.admin_session_handoff.cookie_echoed -eq $false) "fixture admin session cookie must not be echoed"
  Assert-Equal $Fixture.gate_contract.release_check_default.mode "contract_only" "fixture release gate default mode"
  Assert-True ($Fixture.gate_contract.release_check_default.requires_live_db -eq $false) "fixture release gate default must not require live DB"
  Assert-Equal $Fixture.gate_contract.release_check_live_opt_in.flag "-RunRuntimeSmoke" "fixture release live flag"
  Assert-True ($Fixture.transaction_evidence.audit_resource_id_matches_ledger_entry_id -eq $true) "fixture must require audit resource linkage"
  Assert-True ($Fixture.transaction_evidence.idempotent_replay_does_not_increase_ledger_or_audit_count -eq $true) "fixture must require idempotent no-op evidence"
  Assert-True ($Fixture.transaction_evidence.over_remaining_refusal_does_not_increase_ledger_or_audit_count -eq $true) "fixture must require refusal no-op evidence"
  Assert-True ($Fixture.blocked_contract.blocked_is_not_success -eq $true) "fixture must require blocked != success"
}

function Assert-S4ContractFixture {
  param([Parameter(Mandatory = $true)]$Contract)

  Assert-Equal $Contract.execute.mode "execute" "S4 fixture execute mode"
  Assert-Equal $Contract.execute.writer "control_plane_transactional_admin_ledger_adjustment_writer" "S4 fixture writer"
  Assert-True ($Contract.execute.ledger_write_on_applied -eq $true) "S4 fixture applied ledger write"
  Assert-True ($Contract.execute.audit_log_write_on_applied -eq $true) "S4 fixture applied audit write"
  Assert-True ($Contract.execute.business_and_success_audit_share_transaction -eq $true) "S4 fixture transactional audit"
  Assert-True ($Contract.execute.audit_insert_failure_rolls_back_ledger_write -eq $true) "S4 fixture audit rollback"
  Assert-True ($Contract.execute.idempotent_replay_does_not_write_ledger_or_audit -eq $true) "S4 fixture idempotent no-op"
  Assert-True ($Contract.execute_contract.error_code -eq "future_writer_required") "S4 execute_contract must remain blocked"
}

function Get-JsonProperty {
  param(
    [Parameter(Mandatory = $true)]$Object,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Context
  )

  if ($null -eq $Object) {
    throw "$Context is null"
  }

  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    throw "$Context missing '$Name'"
  }

  return $property.Value
}

function Assert-JsonNullProperty {
  param(
    [Parameter(Mandatory = $true)]$Object,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Context
  )

  if ($null -eq $Object) {
    throw "$Context is null"
  }

  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    throw "$Context missing '$Name'"
  }
  if ($null -ne $property.Value) {
    throw "$Context expected '$Name' to be null"
  }
}

function Get-JsonStringArray {
  param(
    [AllowNull()]$Value,
    [Parameter(Mandatory = $true)][string]$Context
  )

  $items = @($Value)
  if ($items.Count -eq 0) {
    throw "$Context must not be empty"
  }

  $strings = @()
  foreach ($item in $items) {
    $text = [string]$item
    if ([string]::IsNullOrWhiteSpace($text)) {
      throw "$Context contains a blank value"
    }
    $strings += $text
  }
  return $strings
}

function Assert-StringSetEqual {
  param(
    [Parameter(Mandatory = $true)][string[]]$Actual,
    [Parameter(Mandatory = $true)][string[]]$Expected,
    [Parameter(Mandatory = $true)][string]$Message
  )

  $actualSorted = @($Actual | Sort-Object)
  $expectedSorted = @($Expected | Sort-Object)
  Assert-Equal ($actualSorted -join "|") ($expectedSorted -join "|") $Message
  Assert-Equal @($Actual | Select-Object -Unique).Count $Actual.Count "$Message uniqueness"
}

function Get-UiSmokeSelector {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $selectors = Get-JsonProperty $Handoff "selectors" "UI handoff"
  $selector = [string](Get-JsonProperty $selectors $Name "UI handoff selectors")
  if ($selector -notmatch '^ledger-adjustment-[a-z0-9-]+$') {
    throw "UI handoff selector '$Name' must be a stable ledger-adjustment data-testid, got '$selector'"
  }
  return $selector
}

function Get-UiSmokeStatusMarker {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $markers = Get-JsonProperty $Handoff "statusMarkers" "UI handoff"
  $marker = [string](Get-JsonProperty $markers $Name "UI handoff status markers")
  if ($marker -notmatch '^[a-z0-9_]+$') {
    throw "UI handoff status marker '$Name' must be a stable machine marker, got '$marker'"
  }
  return $marker
}

function Get-UiSmokeReadinessState {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $states = Get-JsonProperty $Handoff "readinessStates" "UI handoff"
  return Get-JsonProperty $states $Name "UI handoff readiness states"
}

function Assert-HandoffMarkerValue {
  param(
    [Parameter(Mandatory = $true)]$Markers,
    [Parameter(Mandatory = $true)][string]$Name,
    [AllowNull()]$Expected,
    [Parameter(Mandatory = $true)][string]$Context
  )

  if ($null -eq $Expected) {
    Assert-JsonNullProperty $Markers $Name $Context
  } else {
    Assert-Equal (Get-JsonProperty $Markers $Name $Context) $Expected "$Context $Name"
  }
}

function Assert-UiSmokeReadinessState {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$ExpectedStatus,
    [Parameter(Mandatory = $true)][bool]$ExpectedExecuteButtonEnabled,
    [Parameter(Mandatory = $true)][bool]$ExpectedContractCheckNetworkCall,
    [Parameter(Mandatory = $true)][bool]$ExpectedDryRunFresh,
    [AllowNull()]$ExpectedExecuteOutcome,
    [AllowNull()]$ExpectedExecuteResultFresh,
    [Parameter(Mandatory = $true)][bool]$ExpectedExecuteWriteNetworkCall,
    [AllowNull()]$ExpectedLedgerRefreshStatus
  )

  $state = Get-UiSmokeReadinessState $Handoff $Name
  Assert-Equal (Get-JsonProperty $state "expectedStatus" "UI handoff readiness state '$Name'") $ExpectedStatus "UI handoff readiness state '$Name' status"
  Assert-True ([bool](Get-JsonProperty $state "executeButtonEnabled" "UI handoff readiness state '$Name'") -eq $ExpectedExecuteButtonEnabled) "UI handoff readiness state '$Name' execute button flag"

  $markerKeys = Get-JsonStringArray (Get-JsonProperty $Handoff "readinessMarkerKeys" "UI handoff") "UI handoff readiness marker keys"
  $markers = Get-JsonProperty $state "markers" "UI handoff readiness state '$Name'"
  Assert-StringSetEqual @($markers.PSObject.Properties.Name) $markerKeys "UI handoff readiness state '$Name' marker keys"

  Assert-HandoffMarkerValue $markers "contractCheckNetworkCall" $ExpectedContractCheckNetworkCall "UI handoff readiness state '$Name'"
  Assert-HandoffMarkerValue $markers "dryRunFresh" $ExpectedDryRunFresh "UI handoff readiness state '$Name'"
  Assert-HandoffMarkerValue $markers "executeOutcome" $ExpectedExecuteOutcome "UI handoff readiness state '$Name'"
  Assert-HandoffMarkerValue $markers "executeResultFresh" $ExpectedExecuteResultFresh "UI handoff readiness state '$Name'"
  Assert-HandoffMarkerValue $markers "executeWriteNetworkCall" $ExpectedExecuteWriteNetworkCall "UI handoff readiness state '$Name'"
  Assert-HandoffMarkerValue $markers "ledgerRefreshStatus" $ExpectedLedgerRefreshStatus "UI handoff readiness state '$Name'"
}

function Assert-UiLiveSmokeSerializableHandoff {
  param([Parameter(Mandatory = $true)]$Handoff)

  $raw = Get-Content -Path $uiSmokeHandoffPath -Raw
  if ($raw.Contains("undefined")) {
    throw "UI smoke handoff artifact must not contain undefined; use JSON null for absent optional markers"
  }

  $serialization = Get-JsonProperty $Handoff "serialization" "UI handoff"
  Assert-Equal (Get-JsonProperty $serialization "format" "UI handoff serialization") "json" "UI handoff serialization format"
  Assert-JsonNullProperty $serialization "absentOptionalMarker" "UI handoff serialization"

  $requiredMarkerKeys = @(
    "contractCheckNetworkCall",
    "dryRunFresh",
    "executeOutcome",
    "executeResultFresh",
    "executeWriteNetworkCall",
    "ledgerRefreshStatus"
  )
  $markerKeys = Get-JsonStringArray (Get-JsonProperty $Handoff "readinessMarkerKeys" "UI handoff") "UI handoff readiness marker keys"
  $serializationMarkerKeys = Get-JsonStringArray (Get-JsonProperty $serialization "requiredReadinessMarkerKeys" "UI handoff serialization") "UI handoff serialization marker keys"
  Assert-StringSetEqual $markerKeys $requiredMarkerKeys "UI handoff readiness marker keys"
  Assert-StringSetEqual $serializationMarkerKeys $requiredMarkerKeys "UI handoff serialization marker keys"

  $scriptUsage = Get-JsonProperty $Handoff "scriptUsage" "UI handoff"
  Assert-True ([bool](Get-JsonProperty $scriptUsage "useDataTestIdsOnly" "UI handoff script usage")) "UI handoff script usage must require data-testid selectors"
  Assert-True ([bool](Get-JsonProperty $scriptUsage "readStatusFromReadinessRegion" "UI handoff script usage")) "UI handoff script usage must read readiness status markers"
  Assert-True ([bool](Get-JsonProperty $scriptUsage "assertNoForbiddenMarkersInDocument" "UI handoff script usage")) "UI handoff script usage must assert forbidden markers"
  Assert-Equal (Get-JsonProperty $scriptUsage "selectorsSource" "UI handoff script usage") "ledgerAdjustmentExecuteLiveSmokeContract.selectors" "UI handoff selector source"
  Assert-Equal (Get-JsonProperty $scriptUsage "statusMarkersSource" "UI handoff script usage") "ledgerAdjustmentExecuteLiveSmokeHandoff.readinessStates" "UI handoff status source"

  $selectorNames = @(
    "contractCheckNetworkCall",
    "dryRunFresh",
    "executeButton",
    "executeContractButton",
    "executeContractMode",
    "executeEndpoint",
    "executeOutcome",
    "executeResultFresh",
    "executeWriteNetworkCall",
    "ledgerRefreshStatus",
    "readiness"
  )
  $selectorValues = @($selectorNames | ForEach-Object { Get-UiSmokeSelector $Handoff $_ })
  Assert-StringSetEqual $selectorValues $selectorValues "UI handoff selector values"

  $statusMarkerNames = @(
    "contractCheckNetworkCall",
    "dryRunFresh",
    "executeContractMode",
    "executeEndpoint",
    "executeOutcome",
    "executeResultFresh",
    "executeWriteNetworkCall",
    "ledgerEntriesRefreshAfterExecute"
  )
  [void]@($statusMarkerNames | ForEach-Object { Get-UiSmokeStatusMarker $Handoff $_ })

  $forbiddenMarkers = Get-JsonStringArray (Get-JsonProperty $Handoff "forbiddenSensitiveMarkers" "UI handoff") "UI handoff forbidden sensitive markers"
  foreach ($forbidden in @("Authorization", "Cookie", "token", "credential", "operation_key", "raw metadata", "raw executor error detail", "dedupe material")) {
    if ($forbiddenMarkers -notcontains $forbidden) {
      throw "UI handoff forbidden markers missing '$forbidden'"
    }
  }

  Assert-UiSmokeReadinessState $Handoff "dryRunRequired" "dry run required" $false $false $false $null $null $false $null
  Assert-UiSmokeReadinessState $Handoff "executePreflight" "execute preflight" $true $false $true $null $null $false $null
  Assert-UiSmokeReadinessState $Handoff "contractBlocked" "blocked" $true $true $true $null $null $false $null
  Assert-UiSmokeReadinessState $Handoff "blocked" "blocked" $true $false $true $null $null $true $null
  Assert-UiSmokeReadinessState $Handoff "failed" "failed" $true $false $true $null $null $true $null
  Assert-UiSmokeReadinessState $Handoff "stalePlan" "stale plan" $false $false $false $null $null $false $null
  Assert-UiSmokeReadinessState $Handoff "appliedRefreshSuccess" "applied" $true $false $true "applied" $true $true "success"
  Assert-UiSmokeReadinessState $Handoff "appliedRefreshError" "applied" $true $false $true "applied" $true $true "error"
  Assert-UiSmokeReadinessState $Handoff "idempotentRefreshSuccess" "idempotent" $true $false $true "idempotent" $true $true "success"
  Assert-UiSmokeReadinessState $Handoff "idempotentRefreshError" "idempotent" $true $false $true "idempotent" $true $true "error"

  $roundTrip = ($Handoff | ConvertTo-Json -Depth 32 -Compress) | ConvertFrom-Json
  Assert-UiSmokeReadinessState $roundTrip "dryRunRequired" "dry run required" $false $false $false $null $null $false $null
  Assert-UiSmokeReadinessState $roundTrip "appliedRefreshSuccess" "applied" $true $false $true "applied" $true $true "success"
}

function Get-SafeSmokeUrlSummary {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$Name
  )

  try {
    $uri = [Uri]$Url
  } catch {
    throw "$Name must be an absolute http(s) URL"
  }

  if (-not $uri.IsAbsoluteUri -or ($uri.Scheme -ne "http" -and $uri.Scheme -ne "https")) {
    throw "$Name must be an absolute http(s) URL"
  }
  if (-not [string]::IsNullOrWhiteSpace($uri.UserInfo)) {
    throw "$Name must not include userinfo or credentials"
  }

  return $uri.GetLeftPart([UriPartial]::Authority)
}

function Join-SmokeProbeUrl {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$Path
  )

  $safeBase = Get-SafeSmokeUrlSummary $BaseUrl "probe base URL"
  if (-not $Path.StartsWith("/")) {
    $Path = "/$Path"
  }

  return $safeBase.TrimEnd("/") + $Path
}

function Invoke-ServiceReadinessProbe {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Url,
    [int]$TimeoutMs = $BrowserProbeTimeoutMilliseconds,
    [int[]]$ReachableStatusCodes = @(200)
  )

  $timer = [Diagnostics.Stopwatch]::StartNew()
  $client = New-Object System.Net.Http.HttpClient
  $client.Timeout = [TimeSpan]::FromMilliseconds([Math]::Max(100, $TimeoutMs))
  $request = $null
  $response = $null
  try {
    $request = New-Object System.Net.Http.HttpRequestMessage -ArgumentList (New-Object System.Net.Http.HttpMethod -ArgumentList "GET"), $Url
    $response = $client.SendAsync($request).GetAwaiter().GetResult()
    $statusCode = [int]$response.StatusCode
    return [PSCustomObject]@{
      Name = $Name
      Reachable = $ReachableStatusCodes -contains $statusCode
      StatusCode = $statusCode
      DurationMs = [int]$timer.ElapsedMilliseconds
      Classification = if ($ReachableStatusCodes -contains $statusCode) { "reachable" } else { "unreachable:http_status" }
    }
  } catch [System.Threading.Tasks.TaskCanceledException] {
    return [PSCustomObject]@{
      Name = $Name
      Reachable = $false
      StatusCode = 0
      DurationMs = [int]$timer.ElapsedMilliseconds
      Classification = "unreachable:timeout"
    }
  } catch {
    return [PSCustomObject]@{
      Name = $Name
      Reachable = $false
      StatusCode = 0
      DurationMs = [int]$timer.ElapsedMilliseconds
      Classification = "unreachable:connection"
    }
  } finally {
    if ($response) { $response.Dispose() }
    if ($request) { $request.Dispose() }
    $client.Dispose()
    $timer.Stop()
  }
}

function Get-ServiceBlockerMarker {
  param(
    [Parameter(Mandatory = $true)][string]$ToolingStatus,
    [Parameter(Mandatory = $true)]$AdminUiProbe,
    [Parameter(Mandatory = $true)]$ControlPlaneProbe
  )

  $blockers = @()
  if ($ToolingStatus -ne "available") {
    $blockers += "browser_tooling_unavailable"
  }
  if (-not [bool]$AdminUiProbe.Reachable) {
    $blockers += "admin_ui_unreachable"
  }
  if (-not [bool]$ControlPlaneProbe.Reachable) {
    $blockers += "control_plane_health_unreachable"
  }
  if ($blockers.Count -eq 0) {
    return "none"
  }
  return ($blockers -join "+")
}

function Format-BoolMarker {
  param([Parameter(Mandatory = $true)][bool]$Value)

  if ($Value) {
    return "true"
  }
  return "false"
}

function Get-BrowserToolingStatus {
  $node = Get-Command node -ErrorAction SilentlyContinue
  if (-not $node) {
    return "unavailable:node"
  }

  $adminUiRoot = Join-Path $repoRoot "web\admin-ui"
  $localPlaywrightPackages = @(
    (Join-Path $adminUiRoot "node_modules\@playwright\test\package.json"),
    (Join-Path $adminUiRoot "node_modules\playwright\package.json")
  )
  $hasLocalPlaywright = @($localPlaywrightPackages | Where-Object { Test-Path $_ }).Count -gt 0
  $playwrightCli = Get-Command playwright -ErrorAction SilentlyContinue
  if (-not $hasLocalPlaywright -and -not $playwrightCli) {
    return "unavailable:playwright"
  }

  return "available"
}

function Assert-UiSmokeHandoffFreshness {
  param([Parameter(Mandatory = $true)]$Handoff)

  if (-not (Test-Path $uiSmokeContractPath)) {
    throw "missing web admin UI smoke contract source"
  }
  if (-not (Test-Path $uiSmokeContractTestPath)) {
    throw "missing web admin UI smoke contract test"
  }

  $source = Get-Content -Path $uiSmokeContractPath -Raw
  foreach ($needle in @(
      "ledgerAdjustmentExecuteBrowserPreflightContract",
      "ledgerAdjustmentExecuteBrowserActionPlanContract",
      "ledgerAdjustmentExecuteBrowserDomActionRunnerContract",
      "ledgerAdjustmentExecuteBrowserMutationPassArtifactClosureContract",
      "ledgerAdjustmentExecuteBrowserMutationFinalDodContract",
      "ledgerAdjustmentExecuteBrowserMutationEvidenceWatcherFinalGuardContract",
      "ledgerAdjustmentExecuteBrowserLiveRunnerExecutionBridgeContract",
      "ledgerAdjustmentExecuteBrowserLiveEnvironmentBootstrapAttemptContract",
      "ledgerAdjustmentExecuteBrowserPlaywrightLaunchReadinessContract",
      "ledgerAdjustmentExecuteBrowserLiveRunbookContract",
      "ledgerAdjustmentExecuteBrowserRunnerReadinessContract",
      "ledgerAdjustmentExecuteRuntimeCurrentEvidenceAcceptanceMatrixContract",
      "ledgerAdjustmentExecuteRuntimeCurrentFinalClosureAuditContract",
      "ledgerAdjustmentExecuteLiveSmokeSerializableHandoff",
      "ledgerAdjustmentExecuteAbsentOptionalMarker = null"
    )) {
    if (-not $source.Contains($needle)) {
      throw "UI smoke contract source missing freshness marker '$needle'"
    }
  }

  foreach ($mapping in @(
      @("browserActionPlan", "ledgerAdjustmentExecuteBrowserActionPlanContract"),
      @("browserDomActionRunner", "ledgerAdjustmentExecuteBrowserDomActionRunnerContract"),
      @("browserLiveRunnerExecutionBridge", "ledgerAdjustmentExecuteBrowserLiveRunnerExecutionBridgeContract"),
      @("browserLiveEnvironmentBootstrapAttempt", "ledgerAdjustmentExecuteBrowserLiveEnvironmentBootstrapAttemptContract"),
      @("browserLivePassArtifactReadbackGate", "ledgerAdjustmentExecuteBrowserLivePassArtifactReadbackGateContract"),
      @("browserMutationFinalDod", "ledgerAdjustmentExecuteBrowserMutationFinalDodContract"),
      @("browserMutationEvidenceWatcherFinalGuard", "ledgerAdjustmentExecuteBrowserMutationEvidenceWatcherFinalGuardContract"),
      @("browserMutationPassArtifactClosure", "ledgerAdjustmentExecuteBrowserMutationPassArtifactClosureContract"),
      @("browserPlaywrightLaunchReadiness", "ledgerAdjustmentExecuteBrowserPlaywrightLaunchReadinessContract"),
      @("browserLiveRunbook", "ledgerAdjustmentExecuteBrowserLiveRunbookContract"),
      @("browserPreflight", "ledgerAdjustmentExecuteBrowserPreflightContract"),
      @("browserRunnerReadiness", "ledgerAdjustmentExecuteBrowserRunnerReadinessContract"),
      @("runtimeCurrentEvidenceAcceptanceMatrix", "ledgerAdjustmentExecuteRuntimeCurrentEvidenceAcceptanceMatrixContract"),
      @("runtimeCurrentFinalClosureAudit", "ledgerAdjustmentExecuteRuntimeCurrentFinalClosureAuditContract"),
      @("runtimeCurrentOperatorHandoffPack", "ledgerAdjustmentExecuteRuntimeCurrentOperatorHandoffPackContract"),
      @("runtimeCurrentHandoff", "ledgerAdjustmentExecuteRuntimeCurrentHandoffContract")
    )) {
    $pattern = ("(?s){0}\s*:\s*{1}" -f [regex]::Escape($mapping[0]), [regex]::Escape($mapping[1]))
    if ($source -notmatch $pattern) {
      throw "UI smoke contract source missing freshness marker '$($mapping[0]): $($mapping[1])'"
    }
  }

  $testSource = Get-Content -Path $uiSmokeContractTestPath -Raw
  foreach ($needle in @(
      "billingExecuteSmokeContract.serializable.json",
      "ledgerExecuteSmokeSerializableHandoffArtifact",
      "browserPreflight",
      "browserActionPlan",
      "browserDomActionRunner",
      "browserLiveRunnerExecutionBridge",
      "browserLiveEnvironmentBootstrapAttempt",
      "browserLivePassArtifactReadbackGate",
      "browserMutationFinalDod",
      "browserMutationEvidenceWatcherFinalGuard",
      "browserMutationPassArtifactClosure",
      "browserPlaywrightLaunchReadiness",
      "browserEvidenceArtifact",
      "browserRunnerReadiness",
      "browserLiveRunbook",
      "runtimeCurrentEvidenceAcceptanceMatrix",
      "runtimeCurrentFinalClosureAudit",
      "runtimeCurrentOperatorHandoffPack",
      "runtimeCurrentHandoff",
      "runtime_current_handoff",
      "container_recreate_available",
      "build_required_but_forbidden",
      "runtime_current_readback_verified",
      "runtime_current_after_recreate_verified",
      "billing_execute_browser_live_e2e_evidence.v1",
      "classificationValues",
      "runtime_current_verified",
      "runtime_image_stale_or_unverified",
      "artifact_readback_passed",
      "billing_execute_browser_mutation_final_dod.v1",
      "e11_browser_mutation_dod_passed",
      "simulated_artifact_cannot_close_e11",
      "billing_execute_runtime_current_operator_handoff_pack.v1",
      "runtime_current_handoff_ready",
      "runtime_current_evidence_accepted_for_review",
      "mutation_runner_ready_blocked",
      "billing_execute_runtime_current_evidence_acceptance_matrix.v1",
      "billing_execute_browser_mutation_final_closure_audit.v1",
      "billing_execute_browser_mutation_evidence_watcher_final_guard.v1",
      "watcher_final_guard_review",
      "not_simulation_or_watcher_only",
      "noArtifactCanMarkFinalX",
      "sessionMissingCanMarkFinalX",
      "final_x_eligible",
      "blocking_reasons",
      "runtime_artifact_state",
      "browser_artifact_state",
      "runtime_current_commit_mismatch",
      "raw_secret_present",
      "browser_idempotent_replay_failed",
      "dom_action_runner_dry_run_only",
      "playwright_launch_readiness_only",
      "mutation_pass_artifact_closure_gate",
      "live_runner_execution_bridge",
      "live_environment_bootstrap_attempt",
      "live_pass_artifact_readback_gate",
      "-BrowserAdminUiDevServerOptIn",
      "sessionHandoff",
      "CONTROL_PLANE_ADMIN_SESSION_TOKEN",
      "bridge_allowed",
      "-BrowserLiveRunnerExecutionOptIn",
      "closure_eligible",
      "browser_launch_duration_ms",
      "context_setup_duration_ms",
      "page_ready_duration_ms",
      "selector_snapshot_duration_ms",
      "selector_availability_summary",
      "runner_readiness_only",
      "artifact_roundtrip_fresh",
      "live_mutation_opt_in_missing",
      "session_material_missing",
      "dry_run_plan_duration_ms",
      "execute_apply_duration_ms",
      "idempotent_replay_duration_ms",
      "refund_refusal_duration_ms",
      "ledger_refresh_duration_ms",
      "dry_run_plan_duration_ms",
      "execute_apply_duration_ms",
      "idempotent_replay_duration_ms",
      "refund_refusal_duration_ms",
      "service_readiness_duration_ms",
      "live_mutation_opt_in_missing",
      "session_material_missing",
      "admin_ui_reachable",
      "control_plane_health_reachable",
      "submit_latency_ms"
    )) {
    if (-not $testSource.Contains($needle)) {
      throw "UI smoke contract test missing artifact freshness marker '$needle'"
    }
  }

  $browserPreflight = Get-JsonProperty $Handoff "browserPreflight" "UI handoff"
  Assert-Equal (Get-JsonProperty $browserPreflight "defaultMode" "UI browser preflight") "preflight_only" "UI browser preflight default mode"
  Assert-True ((Get-JsonProperty $browserPreflight "requiresLiveBackendByDefault" "UI browser preflight") -eq $false) "UI browser preflight must not require live backend by default"
  Assert-True ([bool](Get-JsonProperty $browserPreflight "usesDataTestIdsOnly" "UI browser preflight")) "UI browser preflight must use data-testid selectors"

  $healthProbePaths = Get-JsonProperty $browserPreflight "healthProbePaths" "UI browser preflight"
  Assert-Equal (Get-JsonProperty $healthProbePaths "adminUi" "UI browser preflight health paths") "/" "UI browser preflight Admin UI probe path"
  Assert-Equal (Get-JsonProperty $healthProbePaths "controlPlane" "UI browser preflight health paths") "/healthz" "UI browser preflight Control Plane health path"

  $requiredInputs = Get-JsonProperty $browserPreflight "requiredInputs" "UI browser preflight"
  Assert-Equal (Get-JsonProperty $requiredInputs "adminUiBaseUrl" "UI browser preflight inputs") "ADMIN_UI_BASE_URL" "UI browser preflight Admin UI env"
  Assert-Equal (Get-JsonProperty $requiredInputs "controlPlaneBaseUrl" "UI browser preflight inputs") "CONTROL_PLANE_BASE_URL" "UI browser preflight backend env"
  Assert-Equal (Get-JsonProperty $requiredInputs "handoffArtifact" "UI browser preflight inputs") "web/admin-ui/src/billingExecuteSmokeContract.serializable.json" "UI browser preflight handoff artifact path"

  $metricMarkers = Get-JsonProperty $browserPreflight "metricMarkers" "UI browser preflight"
  foreach ($name in @(
      "adminUiReachable",
      "controlPlaneHealthReachable",
      "ledgerRefreshDurationMs",
      "readiness",
      "serviceBlocker",
      "serviceProbeTimeoutMs",
      "serviceReadinessDurationMs",
      "sessionMaterialEchoed",
      "sessionMaterialPresent",
      "submitLatencyMs",
      "unavailable"
    )) {
    $marker = [string](Get-JsonProperty $metricMarkers $name "UI browser preflight metric markers")
    if ($marker -notmatch '^[a-z0-9_]+$') {
      throw "UI browser preflight metric marker '$name' must be machine readable"
    }
  }
}

function Assert-RuntimeCurrentHandoffContract {
  param([Parameter(Mandatory = $true)]$Handoff)

  $handoff = Get-JsonProperty $Handoff "runtimeCurrentHandoff" "UI runtime-current handoff"
  Assert-Equal (Get-JsonProperty $handoff "defaultMode" "UI runtime-current handoff") "runtime_current_handoff" "runtime handoff default mode"
  Assert-True ((Get-JsonProperty $handoff "buildAllowedDefault" "UI runtime-current handoff") -eq $false) "runtime handoff must not allow build by default"

  $classifications = Get-JsonProperty $handoff "classifications" "UI runtime-current handoff"
  foreach ($name in @(
      "buildRequiredButForbidden",
      "containerRecreateAvailable",
      "containerUnavailable",
      "dockerUnavailable",
      "imageInspectUnavailable",
      "operatorCommandGenerated",
      "runtimeCurrentAfterRecreateUnverified",
      "runtimeCurrentAfterRecreateVerified",
      "sourceNewerThanRuntimeImage"
    )) {
    $classification = [string](Get-JsonProperty $classifications $name "UI runtime-current handoff classifications")
    if ($classification -notmatch '^[a-z0-9_]+$') {
      throw "runtime-current handoff classification '$name' must be machine readable"
    }
  }

  $noBuild = Get-JsonProperty $handoff "noBuildRecreate" "UI runtime-current no-build recreate"
  Assert-Equal (Get-JsonProperty $noBuild "command" "UI runtime-current no-build recreate") "docker compose -f deploy/docker-compose/docker-compose.yml up -d --no-build --no-deps --force-recreate control-plane" "runtime handoff no-build command"
  Assert-Equal (Get-JsonProperty $noBuild "commandClassification" "UI runtime-current no-build recreate") "operator_command_generated" "runtime handoff no-build command classification"
  Assert-True ((Get-JsonProperty $noBuild "defaultExecutes" "UI runtime-current no-build recreate") -eq $false) "runtime handoff no-build recreate must not execute by default"
  Assert-Equal (Get-JsonProperty $noBuild "env" "UI runtime-current no-build recreate") "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_RUNTIME_CURRENT_RECREATE" "runtime handoff no-build env"
  Assert-Equal (Get-JsonProperty $noBuild "flag" "UI runtime-current no-build recreate") "-RuntimeCurrentNoBuildRecreateOptIn" "runtime handoff no-build flag"
  Assert-True ([bool](Get-JsonProperty $noBuild "readbackRequired" "UI runtime-current no-build recreate")) "runtime handoff readback must be required"
  Assert-Equal (Get-JsonProperty $noBuild "requiredValue" "UI runtime-current no-build recreate") "1" "runtime handoff no-build required value"

  $artifact = Get-JsonProperty $handoff "evidenceArtifact" "UI runtime-current evidence artifact"
  Assert-Equal (Get-JsonProperty $artifact "schema" "UI runtime-current evidence artifact") "control_plane_ledger_execute_runtime_current_handoff.v1" "runtime handoff artifact schema"
  Assert-Equal (Get-JsonProperty $artifact "defaultPath" "UI runtime-current evidence artifact") "artifacts/control_plane_ledger_execute_runtime_current_handoff.json" "runtime handoff artifact default path"
  Assert-Equal (Get-JsonProperty $artifact "env" "UI runtime-current evidence artifact") "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_RUNTIME_CURRENT_ARTIFACT_WRITE" "runtime handoff artifact write env"
  Assert-Equal (Get-JsonProperty $artifact "flag" "UI runtime-current evidence artifact") "-RuntimeCurrentEvidenceArtifactWriteOptIn" "runtime handoff artifact write flag"
  Assert-Equal (Get-JsonProperty $artifact "pathEnv" "UI runtime-current evidence artifact") "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_RUNTIME_CURRENT_ARTIFACT_PATH" "runtime handoff artifact path env"
  Assert-Equal (Get-JsonProperty $artifact "readbackEnv" "UI runtime-current evidence artifact") "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_RUNTIME_CURRENT_ARTIFACT_READBACK" "runtime handoff artifact readback env"
  Assert-Equal (Get-JsonProperty $artifact "readbackFlag" "UI runtime-current evidence artifact") "-RuntimeCurrentEvidenceArtifactReadbackOptIn" "runtime handoff artifact readback flag"
  Assert-Equal (Get-JsonProperty $artifact "requiredValue" "UI runtime-current evidence artifact") "1" "runtime handoff artifact write required value"
  Assert-True ([bool](Get-JsonProperty $artifact "readBackRequiredForExecution" "UI runtime-current evidence artifact")) "runtime handoff artifact readback must be required for execution"
  Assert-True ((Get-JsonProperty $artifact "writeDisabledByDefault" "UI runtime-current evidence artifact") -eq $true) "runtime handoff artifact write must be disabled by default"
  Assert-True ((Get-JsonProperty $artifact "readDisabledByDefault" "UI runtime-current evidence artifact") -eq $true) "runtime handoff artifact readback must be disabled by default"
  [void](Resolve-BoundedEvidenceArtifactPath ([string](Get-JsonProperty $artifact "defaultPath" "UI runtime-current evidence artifact")))

  $rebuild = Get-JsonProperty $handoff "rebuildHandoff" "UI runtime-current rebuild handoff"
  Assert-Equal (Get-JsonProperty $rebuild "buildForbiddenBlocker" "UI runtime-current rebuild handoff") "runtime_image_requires_rebuild_but_build_forbidden" "runtime rebuild forbidden blocker"
  Assert-Equal (Get-JsonProperty $rebuild "commandClassification" "UI runtime-current rebuild handoff") "operator_command_generated" "runtime rebuild command classification"
  Assert-True ((Get-JsonProperty $rebuild "defaultExecutesBuild" "UI runtime-current rebuild handoff") -eq $false) "runtime rebuild handoff must not build by default"
  Assert-True ((Get-JsonProperty $rebuild "executionAllowed" "UI runtime-current rebuild handoff") -eq $false) "runtime rebuild handoff must not execute builds"
  Assert-Equal (Get-JsonProperty $rebuild "env" "UI runtime-current rebuild handoff") "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_RUNTIME_CURRENT_REBUILD_HANDOFF" "runtime rebuild handoff env"
  Assert-Equal (Get-JsonProperty $rebuild "flag" "UI runtime-current rebuild handoff") "-RuntimeCurrentRebuildHandoffOptIn" "runtime rebuild handoff flag"
  Assert-True ([bool](Get-JsonProperty $rebuild "readbackRequired" "UI runtime-current rebuild handoff")) "runtime rebuild handoff readback must be required"
  Assert-Equal (Get-JsonProperty $rebuild "requiredValue" "UI runtime-current rebuild handoff") "1" "runtime rebuild handoff required value"
  Assert-SecretSafeContent -Content ([string](Get-JsonProperty $rebuild "commandHint" "UI runtime-current rebuild handoff")) -Context "runtime-current rebuild command"

  $readback = Get-JsonProperty $handoff "readbackClassifications" "UI runtime-current readback"
  foreach ($name in @("failed", "notRequested", "staleOrUnverified", "verified")) {
    $classification = [string](Get-JsonProperty $readback $name "UI runtime-current readback")
    if ($classification -notmatch '^[a-z0-9_]+$') {
      throw "runtime-current readback classification '$name' must be machine readable"
    }
  }

  $markers = Get-JsonProperty $handoff "outputMarkers" "UI runtime-current output markers"
  foreach ($name in @("buildAllowed", "blocker", "classification", "command", "readbackClassification", "status")) {
    $marker = [string](Get-JsonProperty $markers $name "UI runtime-current output markers")
    if ($marker -notmatch '^[a-z0-9_]+$') {
      throw "runtime-current output marker '$name' must be machine readable"
    }
  }

  $secretSafe = Get-JsonProperty $handoff "secretSafeOmission" "UI runtime-current secret safe"
  foreach ($name in @("echoRequestMaterial", "echoSessionMaterial", "echoUrlCredentials")) {
    Assert-True ((Get-JsonProperty $secretSafe $name "UI runtime-current secret safe") -eq $false) "runtime handoff must omit $name"
  }

  $browserUnlock = Get-JsonProperty $handoff "browserRunnerUnlock" "UI runtime-current browser unlock"
  Assert-Equal (Get-JsonProperty $browserUnlock "defaultRunsBrowserRunner" "UI runtime-current browser unlock") $false "runtime handoff must not run browser runner by default"
  Assert-Equal (Get-JsonProperty $browserUnlock "defaultSubmitsLiveMutation" "UI runtime-current browser unlock") $false "runtime handoff must not submit mutation by default"
  Assert-Equal (Get-JsonProperty $browserUnlock "requiresArtifactReadback" "UI runtime-current browser unlock") $true "runtime handoff browser unlock must require artifact readback"
  Assert-Equal (Get-JsonProperty $browserUnlock "verifiedClassification" "UI runtime-current browser unlock") "runtime_current_verified" "runtime handoff browser unlock verified classification"
  Assert-Equal (Get-JsonProperty $browserUnlock "unlockedBlockerShift" "UI runtime-current browser unlock") "session_mutation_artifact_gate" "runtime handoff browser unlock blocker shift"
  foreach ($name in @("artifactMissing", "artifactStaleOrUnverified", "verifiedArtifact")) {
    $classification = [string](Get-JsonProperty (Get-JsonProperty $browserUnlock "classifications" "UI runtime-current browser unlock") $name "UI runtime-current browser unlock classifications")
    if ($classification -notmatch '^[a-z0-9_]+$') {
      throw "runtime-current browser unlock classification '$name' must be machine readable"
    }
  }
}

function Assert-RuntimeCurrentHandoffEvidenceShape {
  param([Parameter(Mandatory = $true)]$Evidence)

  foreach ($field in @(
      "schema",
      "status",
      "classification",
      "blocker",
      "reason",
      "source_newest_utc",
      "container_created_utc",
      "image_created_utc",
      "image_id",
      "git_commit",
      "alignment_rules",
      "build_allowed",
      "build_required",
      "no_build_recreate_opt_in",
      "no_build_recreate_executed",
      "no_build_recreate_exit_code",
      "rebuild_handoff_opt_in",
      "rebuild_handoff_recorded",
      "no_build_recreate_command",
      "rebuild_handoff_command",
      "rebuild_handoff_execution_allowed",
      "operator_command_classification",
      "readback_classification",
      "after_recreate_classification",
      "secret_material_echoed",
      "url_credentials_echoed",
      "request_material_echoed"
    )) {
    [void](Get-JsonProperty $Evidence $field "runtime-current handoff evidence")
  }
  Assert-Equal (Get-JsonProperty $Evidence "schema" "runtime-current handoff evidence") "control_plane_ledger_execute_runtime_current_handoff.v1" "runtime handoff evidence schema"
  $gitCommit = [string](Get-JsonProperty $Evidence "git_commit" "runtime-current handoff evidence")
  if ($gitCommit -ne "unavailable" -and $gitCommit -notmatch '^[0-9a-f]{40}$') {
    throw "runtime handoff evidence git_commit must be a full commit hash or unavailable"
  }
  $alignmentRules = Get-JsonProperty $Evidence "alignment_rules" "runtime-current handoff evidence"
  foreach ($field in @("source_timestamp_must_not_exceed_image_created_utc", "container_created_utc_must_be_available", "image_created_utc_must_be_available", "image_id_must_be_available", "git_commit_marker_required", "stale_image_is_blocker")) {
    Assert-True ((Get-JsonProperty $alignmentRules $field "runtime-current handoff alignment rules") -eq $true) "runtime handoff alignment rule $field must be true"
  }
  Assert-Equal (Get-JsonProperty $alignmentRules "no_build_recreate_classification" "runtime-current handoff alignment rules") "container_recreate_available" "runtime handoff no-build classification"
  Assert-Equal (Get-JsonProperty $alignmentRules "rebuild_handoff_classification" "runtime-current handoff alignment rules") "source_newer_than_runtime_image" "runtime handoff rebuild classification"
  foreach ($field in @("classification", "blocker", "operator_command_classification", "readback_classification", "after_recreate_classification")) {
    $value = [string](Get-JsonProperty $Evidence $field "runtime-current handoff evidence")
    if ($value -ne "none" -and $value -notmatch '^[a-z0-9_]+$') {
      throw "runtime handoff evidence '$field' must be machine readable"
    }
  }
  Assert-True ((Get-JsonProperty $Evidence "build_allowed" "runtime-current handoff evidence") -eq $false) "runtime handoff evidence must keep build forbidden"
  Assert-True ((Get-JsonProperty $Evidence "rebuild_handoff_execution_allowed" "runtime-current handoff evidence") -eq $false) "runtime rebuild handoff evidence must keep build execution forbidden"
  Assert-True ((Get-JsonProperty $Evidence "secret_material_echoed" "runtime-current handoff evidence") -eq $false) "runtime handoff evidence must not echo session material"
  Assert-True ((Get-JsonProperty $Evidence "url_credentials_echoed" "runtime-current handoff evidence") -eq $false) "runtime handoff evidence must not echo URL credentials"
  Assert-True ((Get-JsonProperty $Evidence "request_material_echoed" "runtime-current handoff evidence") -eq $false) "runtime handoff evidence must not echo request material"
  Assert-SecretSafeContent -Content ($Evidence | ConvertTo-Json -Depth 8 -Compress) -Context "runtime-current handoff evidence"
}

function Write-RuntimeCurrentHandoffSimulation {
  param([Parameter(Mandatory = $true)]$Handoff)

  Assert-RuntimeCurrentHandoffContract $Handoff
  $cases = @(
    [PSCustomObject]@{ name = "source_newer_than_runtime_image"; stale = $true; reason = "source_newer_than_runtime_image"; expectedClassification = "source_newer_than_runtime_image"; expectedBlocker = "runtime_image_requires_rebuild_but_build_forbidden"; expectedReadback = "runtime_current_readback_stale_or_unverified" },
    [PSCustomObject]@{ name = "container_recreate_available"; stale = $false; reason = "none"; expectedClassification = "container_recreate_available"; expectedBlocker = "none"; expectedReadback = "runtime_current_readback_verified" },
    [PSCustomObject]@{ name = "container_unavailable"; stale = $true; reason = "control_plane_container_unavailable"; expectedClassification = "control_plane_container_unavailable"; expectedBlocker = "control_plane_container_unavailable_for_no_build_handoff"; expectedReadback = "runtime_current_readback_stale_or_unverified" },
    [PSCustomObject]@{ name = "docker_unavailable"; stale = $true; reason = "docker_unavailable"; expectedClassification = "docker_unavailable"; expectedBlocker = "docker_unavailable_for_no_build_handoff"; expectedReadback = "runtime_current_readback_failed" }
  )

  Write-SafeHost "Runtime-current handoff bounded simulations:"
  foreach ($case in $cases) {
    $evidence = New-RuntimeCurrentHandoffEvidence -StaleOrUnverified ([bool]$case.stale) -Reason ([string]$case.reason) -SourceNewestUtc "2026-06-05T00:00:00.0000000Z" -ContainerCreatedUtc "2026-06-05T00:00:01.0000000Z" -ImageCreatedUtc "2026-06-05T00:00:02.0000000Z"
    Assert-RuntimeCurrentHandoffEvidenceShape $evidence
    Assert-Equal (Get-JsonProperty $evidence "classification" "runtime-current handoff simulation") ([string]$case.expectedClassification) "runtime-current simulation classification $($case.name)"
    Assert-Equal (Get-JsonProperty $evidence "blocker" "runtime-current handoff simulation") ([string]$case.expectedBlocker) "runtime-current simulation blocker $($case.name)"
    Assert-Equal (Get-JsonProperty $evidence "readback_classification" "runtime-current handoff simulation") ([string]$case.expectedReadback) "runtime-current simulation readback $($case.name)"
    Write-SafeHost "runtime_current_handoff_simulation=$($case.name);classification=$($evidence.classification);blocker=$($evidence.blocker);readback=$($evidence.readback_classification);after_recreate=$($evidence.after_recreate_classification);build_allowed=false;operator_command=$($evidence.operator_command_classification)"
  }

  $rebuildHandoffEvidence = New-RuntimeCurrentHandoffEvidence -StaleOrUnverified $true -Reason "source_newer_than_runtime_image" -SourceNewestUtc "2026-06-05T00:00:03.0000000Z" -ContainerCreatedUtc "2026-06-05T00:00:01.0000000Z" -ImageCreatedUtc "2026-06-05T00:00:02.0000000Z" -RebuildHandoffOptIn $true -RebuildHandoffRecorded $true
  Assert-RuntimeCurrentHandoffEvidenceShape $rebuildHandoffEvidence
  Assert-True ([bool](Get-JsonProperty $rebuildHandoffEvidence "rebuild_handoff_opt_in" "runtime-current rebuild handoff simulation")) "runtime-current rebuild handoff opt-in must be recorded"
  Assert-True ([bool](Get-JsonProperty $rebuildHandoffEvidence "rebuild_handoff_recorded" "runtime-current rebuild handoff simulation")) "runtime-current rebuild handoff must record operator command evidence"
  Assert-True ((Get-JsonProperty $rebuildHandoffEvidence "rebuild_handoff_execution_allowed" "runtime-current rebuild handoff simulation") -eq $false) "runtime-current rebuild handoff must not execute build"
  Write-SafeHost "runtime_current_handoff_simulation=rebuild_operator_handoff;classification=$($rebuildHandoffEvidence.classification);blocker=$($rebuildHandoffEvidence.blocker);readback=$($rebuildHandoffEvidence.readback_classification);rebuild_handoff_recorded=true;rebuild_execution_allowed=false"

  $verifiedArtifactEvidence = New-RuntimeCurrentHandoffEvidence -StaleOrUnverified $false -Reason "none" -SourceNewestUtc "2026-06-05T00:00:00.0000000Z" -ContainerCreatedUtc "2026-06-05T00:00:03.0000000Z" -ImageCreatedUtc "2026-06-05T00:00:02.0000000Z"
  $verifiedProbe = Convert-RuntimeCurrentEvidenceToProbe $verifiedArtifactEvidence
  Assert-True ([bool]$verifiedProbe.ArtifactVerified) "verified runtime-current artifact must unlock runtime-current browser blocker"
  Assert-True (-not [bool]$verifiedProbe.StaleOrUnverified) "verified runtime-current artifact must produce current probe"
  Write-SafeHost "runtime_current_artifact_simulation=verified_unlock;classification=runtime_current_verified;blocker_shift=session_mutation_artifact_gate;default_runs_browser=false;default_mutation=false"

  $staleArtifactProbe = Convert-RuntimeCurrentEvidenceToProbe $rebuildHandoffEvidence
  Assert-True (-not [bool]$staleArtifactProbe.ArtifactVerified) "stale runtime-current artifact must not unlock runtime-current browser blocker"
  Assert-True ([bool]$staleArtifactProbe.StaleOrUnverified) "stale runtime-current artifact must preserve runtime-current blocker"
  Write-SafeHost "runtime_current_artifact_simulation=stale_blocked;classification=runtime_current_artifact_stale_or_unverified;blocker=$($staleArtifactProbe.Reason);default_runs_browser=false;default_mutation=false"
}

function Test-RuntimeCurrentEvidenceArtifactWriteOptIn {
  param([Parameter(Mandatory = $true)]$Handoff)

  $runtimeHandoff = Get-JsonProperty $Handoff "runtimeCurrentHandoff" "UI runtime-current handoff"
  $artifact = Get-JsonProperty $runtimeHandoff "evidenceArtifact" "UI runtime-current evidence artifact"
  $envName = [string](Get-JsonProperty $artifact "env" "UI runtime-current evidence artifact")
  $requiredValue = [string](Get-JsonProperty $artifact "requiredValue" "UI runtime-current evidence artifact")
  return $RuntimeCurrentEvidenceArtifactWriteOptIn -or ([Environment]::GetEnvironmentVariable($envName) -eq $requiredValue)
}

function Test-RuntimeCurrentEvidenceArtifactReadbackOptIn {
  param([Parameter(Mandatory = $true)]$Handoff)

  $runtimeHandoff = Get-JsonProperty $Handoff "runtimeCurrentHandoff" "UI runtime-current handoff"
  $artifact = Get-JsonProperty $runtimeHandoff "evidenceArtifact" "UI runtime-current evidence artifact"
  $envName = [string](Get-JsonProperty $artifact "readbackEnv" "UI runtime-current evidence artifact")
  $requiredValue = [string](Get-JsonProperty $artifact "requiredValue" "UI runtime-current evidence artifact")
  return $RuntimeCurrentEvidenceArtifactReadbackOptIn -or ([Environment]::GetEnvironmentVariable($envName) -eq $requiredValue)
}

function Convert-RuntimeCurrentEvidenceToProbe {
  param([Parameter(Mandatory = $true)]$Evidence)

  Assert-RuntimeCurrentHandoffEvidenceShape $Evidence
  $verified = (
    ([string](Get-JsonProperty $Evidence "status" "runtime-current readback evidence") -eq "ready") -and
    ([string](Get-JsonProperty $Evidence "classification" "runtime-current readback evidence") -eq "container_recreate_available") -and
    ([string](Get-JsonProperty $Evidence "blocker" "runtime-current readback evidence") -eq "none") -and
    ([string](Get-JsonProperty $Evidence "readback_classification" "runtime-current readback evidence") -eq "runtime_current_readback_verified") -and
    ((Get-JsonProperty $Evidence "build_allowed" "runtime-current readback evidence") -eq $false)
  )

  return [PSCustomObject]@{
    StaleOrUnverified = -not $verified
    Reason = if ($verified) { "runtime_current_verified_artifact_readback" } else { [string](Get-JsonProperty $Evidence "blocker" "runtime-current readback evidence") }
    SourceNewestUtc = [string](Get-JsonProperty $Evidence "source_newest_utc" "runtime-current readback evidence")
    ContainerCreatedUtc = [string](Get-JsonProperty $Evidence "container_created_utc" "runtime-current readback evidence")
    ImageCreatedUtc = [string](Get-JsonProperty $Evidence "image_created_utc" "runtime-current readback evidence")
    ImageId = [string](Get-JsonProperty $Evidence "image_id" "runtime-current readback evidence")
    GitCommit = [string](Get-JsonProperty $Evidence "git_commit" "runtime-current readback evidence")
    ArtifactVerified = $verified
  }
}

function Invoke-RuntimeCurrentArtifactReadbackGate {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [Parameter(Mandatory = $true)]$InitialProbe
  )

  Assert-RuntimeCurrentHandoffContract $Handoff
  $readbackOptIn = Test-RuntimeCurrentEvidenceArtifactReadbackOptIn $Handoff
  $artifactPath = Resolve-BoundedEvidenceArtifactPath $RuntimeCurrentEvidenceArtifactPath
  Write-SafeHost "Runtime-current artifact browser-runner unblock gate:"
  Write-SafeHost "runtime_current_browser_unblock_artifact_readback_opt_in=$(Format-BoolMarker $readbackOptIn)"
  Write-SafeHost "runtime_current_browser_unblock_default_runs_browser=false"
  Write-SafeHost "runtime_current_browser_unblock_default_mutation=false"
  Write-SafeHost "runtime_current_browser_unblock_artifact_path=$artifactPath"

  if (-not $readbackOptIn) {
    Write-SafeHost "runtime_current_browser_unblock_classification=runtime_current_artifact_readback_not_requested"
    Write-SafeHost "runtime_current_browser_unblock_blocker=runtime_current_artifact_readback_not_requested"
    return $InitialProbe
  }

  if (-not (Test-Path $artifactPath)) {
    Write-SafeHost "runtime_current_browser_unblock_classification=runtime_current_artifact_missing"
    Write-SafeHost "runtime_current_browser_unblock_blocker=runtime_current_artifact_missing"
    Add-Blocker "runtime-current browser runner unblock gate - runtime_current_artifact_missing"
    return $InitialProbe
  }

  $readBack = Read-JsonFile $artifactPath
  Assert-RuntimeCurrentHandoffEvidenceShape $readBack
  Assert-SecretSafeContent -Content ($readBack | ConvertTo-Json -Depth 12 -Compress) -Context "runtime-current browser unlock artifact readback"
  $probe = Convert-RuntimeCurrentEvidenceToProbe $readBack
  if ([bool]$probe.ArtifactVerified) {
    Write-SafeHost "runtime_current_browser_unblock_classification=runtime_current_verified"
    Write-SafeHost "runtime_current_browser_unblock_blocker=none"
    Write-SafeHost "runtime_current_browser_unblock_shift=session_mutation_artifact_gate"
    Write-SafeHost "runtime_current_browser_unblock_artifact_readback_classification=$($readBack.readback_classification)"
    Write-SafeHost "runtime_current_browser_unblock_runtime_current_verified=true"
    return $probe
  }

  Write-SafeHost "runtime_current_browser_unblock_classification=runtime_current_artifact_stale_or_unverified"
  Write-SafeHost "runtime_current_browser_unblock_blocker=$($probe.Reason)"
  Write-SafeHost "runtime_current_browser_unblock_artifact_readback_classification=$($readBack.readback_classification)"
  Add-Blocker "runtime-current browser runner unblock gate - runtime_current_artifact_stale_or_unverified reason=$($probe.Reason)"
  return $InitialProbe
}

function Assert-E11ReleaseRuntimeCurrentArtifactReadback {
  param([Parameter(Mandatory = $true)]$Artifact)

  Assert-RuntimeCurrentHandoffEvidenceShape $Artifact
  Assert-Equal (Get-JsonProperty $Artifact "status" "E11 release runtime-current artifact") "ready" "E11 release runtime artifact status"
  Assert-Equal (Get-JsonProperty $Artifact "classification" "E11 release runtime-current artifact") "container_recreate_available" "E11 release runtime artifact classification"
  Assert-Equal (Get-JsonProperty $Artifact "blocker" "E11 release runtime-current artifact") "none" "E11 release runtime artifact blocker"
  Assert-Equal (Get-JsonProperty $Artifact "readback_classification" "E11 release runtime-current artifact") "runtime_current_readback_verified" "E11 release runtime artifact readback classification"
  Assert-True ((Get-JsonProperty $Artifact "build_allowed" "E11 release runtime-current artifact") -eq $false) "E11 release runtime artifact must not allow build"
  Assert-True ((Get-JsonProperty $Artifact "build_required" "E11 release runtime-current artifact") -eq $false) "E11 release runtime artifact must not require build"
  Assert-Equal (Get-JsonProperty $Artifact "git_commit" "E11 release runtime-current artifact") (Get-CurrentGitCommit) "E11 release runtime artifact current commit"

  $imageId = [string](Get-JsonProperty $Artifact "image_id" "E11 release runtime-current artifact")
  if ($imageId -notmatch '^sha256:[0-9a-f]{64}$') {
    throw "E11 release runtime artifact image_id must be a sha256 image id"
  }

  $sourceNewest = Convert-JsonTimestampToUtc (Get-JsonProperty $Artifact "source_newest_utc" "E11 release runtime-current artifact")
  $containerCreated = Convert-JsonTimestampToUtc (Get-JsonProperty $Artifact "container_created_utc" "E11 release runtime-current artifact")
  $imageCreated = Convert-JsonTimestampToUtc (Get-JsonProperty $Artifact "image_created_utc" "E11 release runtime-current artifact")
  Assert-True ($sourceNewest -le $imageCreated) "E11 release runtime artifact source timestamp must not exceed image_created_utc"
  Assert-True ($sourceNewest -le $containerCreated) "E11 release runtime artifact source timestamp must not exceed container_created_utc"

  $alignmentRules = Get-JsonProperty $Artifact "alignment_rules" "E11 release runtime-current artifact"
  Assert-True ((Get-JsonProperty $alignmentRules "stale_image_is_blocker" "E11 release runtime alignment rules") -eq $true) "E11 release runtime artifact must keep stale image as blocker"
  Assert-Equal (Get-JsonProperty $alignmentRules "no_build_recreate_classification" "E11 release runtime alignment rules") "container_recreate_available" "E11 release no-build recreate classification"
  Assert-Equal (Get-JsonProperty $alignmentRules "rebuild_handoff_classification" "E11 release runtime alignment rules") "source_newer_than_runtime_image" "E11 release rebuild handoff classification"

  foreach ($field in @("secret_material_echoed", "url_credentials_echoed", "request_material_echoed")) {
    Assert-True ((Get-JsonProperty $Artifact $field "E11 release runtime-current artifact") -eq $false) "E11 release runtime artifact must not echo $field"
  }
}

function Assert-E11ReleaseBrowserArtifactReadback {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [Parameter(Mandatory = $true)]$Artifact,
    [Parameter(Mandatory = $true)]$RuntimeArtifact
  )

  Assert-BrowserEvidenceArtifactShape -Handoff $Handoff -Artifact $Artifact
  Assert-BrowserEvidenceArtifactFreshness -Handoff $Handoff -Artifact $Artifact
  Assert-True (Test-BrowserMutationPassArtifactClosure -Handoff $Handoff -Artifact $Artifact) "E11 release browser artifact must be closure eligible"
  Assert-Equal (Get-JsonProperty $Artifact "outcome" "E11 release browser artifact") "passed" "E11 release browser artifact outcome"
  Assert-Equal (Get-JsonProperty $Artifact "mode" "E11 release browser artifact") "browser_live_e2e" "E11 release browser artifact mode"
  Assert-Equal (Get-JsonProperty $Artifact.provenance "git_commit" "E11 release browser provenance") (Get-CurrentGitCommit) "E11 release browser provenance current commit"
  Assert-Equal (Get-JsonProperty $Artifact.freshness "git_commit" "E11 release browser freshness") (Get-CurrentGitCommit) "E11 release browser freshness current commit"
  Assert-True ((Get-JsonProperty $Artifact.freshness "handoff_fresh" "E11 release browser freshness") -eq $true) "E11 release browser handoff must be fresh"

  Assert-Equal (Get-JsonProperty $Artifact.runtime_current "classification" "E11 release browser runtime current") "runtime_current_verified" "E11 release browser runtime-current classification"
  Assert-True ((Get-JsonProperty $Artifact.runtime_current "stale_or_unverified" "E11 release browser runtime current") -eq $false) "E11 release browser runtime must not be stale"
  Assert-Equal (Get-JsonProperty $Artifact.runtime_current "image_id" "E11 release browser runtime current") (Get-JsonProperty $RuntimeArtifact "image_id" "E11 release runtime artifact") "E11 release browser/runtime image id linkage"
  Assert-Equal (Get-JsonProperty $Artifact.runtime_current "git_commit" "E11 release browser runtime current") (Get-JsonProperty $RuntimeArtifact "git_commit" "E11 release runtime artifact") "E11 release browser/runtime git commit linkage"

  Assert-Equal (Get-JsonProperty $Artifact.classifications "runtime_current" "E11 release browser classifications") "runtime_current_verified" "E11 release browser runtime classification"
  Assert-Equal (Get-JsonProperty $Artifact.classifications "replay" "E11 release browser classifications") "idempotent_replay_passed" "E11 release browser replay classification"
  Assert-Equal (Get-JsonProperty $Artifact.classifications "mutation_pass_artifact" "E11 release browser classifications") "mutation_pass_artifact_passed" "E11 release browser mutation pass classification"
  Assert-Equal (Get-JsonProperty $Artifact.classifications "readback" "E11 release browser classifications") "artifact_readback_passed" "E11 release browser readback classification"
  Assert-Equal (Get-JsonProperty $Artifact.classifications "failure" "E11 release browser classifications") "none" "E11 release browser failure classification"

  Assert-Equal (Get-JsonProperty $Artifact.readback "classification" "E11 release browser readback") "artifact_readback_passed" "E11 release browser artifact readback"
  foreach ($field in @("attempted", "fresh", "closure_eligible", "path_bounded")) {
    Assert-True ((Get-JsonProperty $Artifact.readback $field "E11 release browser readback") -eq $true) "E11 release browser readback must set $field"
  }

  Assert-True ((Get-JsonProperty $Artifact.runtime_current_artifact "linked" "E11 release browser runtime artifact") -eq $true) "E11 release browser runtime artifact must be linked"
  Assert-Equal (Get-JsonProperty $Artifact.runtime_current_artifact "classification" "E11 release browser runtime artifact") "runtime_current_verified" "E11 release browser runtime artifact classification"
  Assert-True ((Get-JsonProperty $Artifact.runtime_current_artifact "secret_material_echoed" "E11 release browser runtime artifact") -eq $false) "E11 release browser runtime artifact must not echo secret material"

  Assert-True ((Get-JsonProperty $Artifact.session_verification "verified" "E11 release browser session") -eq $true) "E11 release browser session must be verified"
  Assert-True ((Get-JsonProperty $Artifact.session_verification "secret_omitted" "E11 release browser session") -eq $true) "E11 release browser session secret must be omitted"
  foreach ($field in @("token_echoed", "cookie_echoed", "header_value_echoed")) {
    Assert-True ((Get-JsonProperty $Artifact.session_verification $field "E11 release browser session") -eq $false) "E11 release browser session must not echo $field"
  }

  foreach ($field in @("mutation_opt_in_enabled", "artifact_write_opt_in_enabled", "artifact_readback_opt_in_enabled")) {
    Assert-True ((Get-JsonProperty $Artifact.mutation_controls $field "E11 release browser mutation controls") -eq $true) "E11 release browser mutation controls must set $field"
  }
  foreach ($field in @("default_build", "default_mutation", "default_runner")) {
    Assert-True ((Get-JsonProperty $Artifact.mutation_controls $field "E11 release browser mutation controls") -eq $false) "E11 release browser mutation controls must keep $field false"
  }

  $expectedApi = @{
    dry_run_plan = "executePreflight"
    execute_apply = "applied"
    idempotent_replay = "idempotent"
    refund_refusal = "blocked"
    ledger_refresh = "success"
  }
  foreach ($name in $expectedApi.Keys) {
    Assert-Equal (Get-JsonProperty $Artifact.api_readback $name "E11 release browser API readback") $expectedApi[$name] "E11 release browser API readback $name"
  }
  foreach ($field in @("applied_ledger_entry_visible", "idempotent_replay_reused_ledger_entry", "refund_refusal_no_ledger_write", "ledger_refresh_visible")) {
    Assert-True ((Get-JsonProperty $Artifact.ledger_readback $field "E11 release browser ledger readback") -eq $true) "E11 release browser ledger readback must set $field"
  }

  Assert-Equal (Get-JsonProperty $Artifact.failure_taxonomy "failed_action" "E11 release browser failure taxonomy") "none" "E11 release browser failed action"
  Assert-Equal (Get-JsonProperty $Artifact.failure_taxonomy "failure_classification" "E11 release browser failure taxonomy") "none" "E11 release browser failure classification"
  foreach ($field in @("session_missing", "runtime_stale", "mutation_opt_in_missing", "artifact_write_missing", "artifact_readback_failed", "idempotent_replay_failed", "refund_refusal_missing", "ledger_refresh_missing", "duration_non_numeric", "stale_or_simulated_artifact", "browser_unavailable")) {
    Assert-True ((Get-JsonProperty $Artifact.failure_taxonomy $field "E11 release browser failure taxonomy") -eq $false) "E11 release browser failure taxonomy must keep $field false"
  }

  Assert-True (@(Get-JsonProperty $Artifact "blockers" "E11 release browser artifact").Count -eq 0) "E11 release browser artifact must not contain blockers"
  Assert-Equal (Get-JsonProperty $Artifact.matrix "browser_tooling" "E11 release browser matrix") "available" "E11 release browser tooling"
  foreach ($field in @("admin_ui_reachable", "control_plane_health_reachable", "session_material_present", "mutation_opt_in_enabled")) {
    Assert-True ((Get-JsonProperty $Artifact.matrix $field "E11 release browser matrix") -eq $true) "E11 release browser matrix must set $field"
  }
  Assert-True ((Get-JsonProperty $Artifact.matrix "session_material_echoed" "E11 release browser matrix") -eq $false) "E11 release browser matrix must not echo session material"

  $actionsByName = @{}
  foreach ($action in @(Get-JsonProperty $Artifact "actions" "E11 release browser actions")) {
    $actionsByName[[string](Get-JsonProperty $action "name" "E11 release browser action")] = $action
  }
  foreach ($name in $expectedApi.Keys) {
    if (-not $actionsByName.ContainsKey($name)) {
      throw "E11 release browser artifact missing UI action $name"
    }
    Assert-Equal (Get-JsonProperty $actionsByName[$name] "outcome" "E11 release browser action $name") $expectedApi[$name] "E11 release browser UI readback action $name"
    Assert-True (Test-BrowserEvidenceDurationValue (Get-JsonProperty $actionsByName[$name] "duration_ms" "E11 release browser action $name")) "E11 release browser action $name duration must be numeric"
  }

  Assert-True ((Get-JsonProperty $Artifact.secret_safe "session_material_echoed" "E11 release browser secret-safe") -eq $false) "E11 release browser artifact must not echo session material"
  Assert-True ((Get-JsonProperty $Artifact.secret_safe "request_material_echoed" "E11 release browser secret-safe") -eq $false) "E11 release browser artifact must not echo request material"
  Assert-True ((Get-JsonProperty $Artifact.secret_safe "metadata_material_echoed" "E11 release browser secret-safe") -eq $false) "E11 release browser artifact must not echo metadata material"

  $json = $Artifact | ConvertTo-Json -Depth 32 -Compress
  foreach ($forbidden in @("Authorization", "Bearer ", "X-Admin-Session", "session_token_once", "provider_key", "virtual_key")) {
    if ($json.Contains($forbidden)) {
      throw "E11 release browser artifact leaked forbidden marker '$forbidden'"
    }
  }
  Assert-SecretSafeContent -Content $json -Context "E11 release browser artifact readback"
}

function Write-E11ReleaseReadbackBlockedReport {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [Parameter(Mandatory = $true)]$RuntimeArtifact,
    [Parameter(Mandatory = $true)]$BrowserArtifact,
    [Parameter(Mandatory = $true)][string]$RuntimeArtifactPath,
    [Parameter(Mandatory = $true)][string]$BrowserArtifactPath,
    [Parameter(Mandatory = $true)][string]$Reason
  )

  $runner = Get-JsonProperty $Handoff "browserRunnerReadiness" "UI handoff"
  $artifactWriteRead = Get-JsonProperty $runner "artifactWriteRead" "UI browser runner artifact write/read"
  $staleRefusal = Get-JsonProperty $artifactWriteRead "staleRefusal" "UI browser runner artifact stale refusal"
  $generatedAtText = [string](Get-JsonProperty $BrowserArtifact "generated_at" "E11 release browser stale report")
  $generatedAtUtc = Convert-JsonTimestampToUtc $generatedAtText
  $nowUtc = (Get-Date).ToUniversalTime()
  $maxAgeMinutes = [int](Get-JsonProperty $staleRefusal "maxGeneratedAgeMinutes" "UI browser runner artifact stale refusal")
  $reportPath = Resolve-BoundedEvidenceArtifactPath "artifacts/control_plane_ledger_execute_release_readback_blocked_stale.json"
  $relativeRuntimePath = "artifacts/control_plane_ledger_execute_runtime_current_verified_beta.json"
  $relativeBrowserPath = "artifacts/billing_execute_browser_live_e2e_evidence.json"
  $scriptPath = "scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1"
  $regenerationCommands = @(
    "pwsh -NoProfile -ExecutionPolicy Bypass -File $scriptPath -RuntimeCurrentEvidenceArtifactWriteOptIn -RuntimeCurrentEvidenceArtifactPath $relativeRuntimePath",
    "pwsh -NoProfile -ExecutionPolicy Bypass -File $scriptPath -RuntimeCurrentEvidenceArtifactReadbackOptIn -RuntimeCurrentEvidenceArtifactPath $relativeRuntimePath",
    "pwsh -NoProfile -ExecutionPolicy Bypass -File $scriptPath -AdminSessionHandoff -RuntimeCurrentEvidenceArtifactReadbackOptIn -RuntimeCurrentEvidenceArtifactPath $relativeRuntimePath -BrowserPreflight -BrowserMutationOptIn -BrowserEvidenceArtifactWriteOptIn -BrowserLiveRunnerExecutionOptIn -BrowserEvidenceArtifactReadbackOptIn -BrowserEvidenceArtifactPath $relativeBrowserPath",
    "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1 -ControlPlaneLedgerAdjustmentExecuteBrowserReadbackOnly"
  )
  $report = [PSCustomObject]@{
    schema = "e11_release_readback_blocked_stale_artifact.v1"
    generated_at_utc = $nowUtc.ToString("o")
    status = "release_readback_blocked_by_stale_artifact"
    reason = $Reason
    current_commit = Get-CurrentGitCommit
    runtime_artifact = [PSCustomObject]@{
      path_bounded = $true
      path = $RuntimeArtifactPath
      status = [string](Get-JsonProperty $RuntimeArtifact "status" "E11 release runtime artifact")
      classification = [string](Get-JsonProperty $RuntimeArtifact "classification" "E11 release runtime artifact")
      readback_classification = [string](Get-JsonProperty $RuntimeArtifact "readback_classification" "E11 release runtime artifact")
      git_commit = [string](Get-JsonProperty $RuntimeArtifact "git_commit" "E11 release runtime artifact")
      image_id_present = -not [string]::IsNullOrWhiteSpace([string](Get-JsonProperty $RuntimeArtifact "image_id" "E11 release runtime artifact"))
      secret_material_echoed = $false
      request_material_echoed = $false
    }
    browser_artifact = [PSCustomObject]@{
      path_bounded = $true
      path = $BrowserArtifactPath
      generated_at = $generatedAtUtc.ToString("o")
      max_generated_age_minutes = $maxAgeMinutes
      age_minutes = [Math]::Round(($nowUtc - $generatedAtUtc).TotalMinutes, 3)
      outcome = [string](Get-JsonProperty $BrowserArtifact "outcome" "E11 release browser artifact")
      mutation_pass_artifact = [string](Get-JsonProperty $BrowserArtifact.classifications "mutation_pass_artifact" "E11 release browser classifications")
      artifact_readback = [string](Get-JsonProperty $BrowserArtifact.classifications "readback" "E11 release browser classifications")
      secret_safe = $true
      session_material_echoed = $false
      request_material_echoed = $false
      metadata_material_echoed = $false
    }
    missing_env_or_session = [PSCustomObject]@{
      admin_session_env_present = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("CONTROL_PLANE_ADMIN_SESSION_TOKEN"))
      browser_mutation_env_enabled = [Environment]::GetEnvironmentVariable("CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_MUTATION") -eq "1"
      browser_runner_env_enabled = [Environment]::GetEnvironmentVariable("CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_RUNNER") -eq "1"
      control_plane_base_url_present = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("CONTROL_PLANE_BASE_URL"))
      admin_ui_base_url_present = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("ADMIN_UI_BASE_URL"))
      values_omitted = $true
    }
    regeneration_commands = $regenerationCommands
    secret_safe = [PSCustomObject]@{
      session_material_echoed = $false
      authorization_echoed = $false
      cookie_echoed = $false
      provider_key_echoed = $false
      virtual_key_echoed = $false
      request_material_echoed = $false
    }
  }
  $json = $report | ConvertTo-Json -Depth 12
  Assert-SecretSafeContent -Content $json -Context "E11 release stale blocker report"
  Set-Content -LiteralPath $reportPath -Value $json -Encoding UTF8
  Write-SafeHost "e11_release_artifact_readback_status=blocked"
  Write-SafeHost "e11_release_blocker=release_readback_blocked_by_stale_artifact"
  Write-SafeHost "e11_release_blocker_report=$reportPath"
  Write-SafeHost "e11_release_regeneration_command_count=$($regenerationCommands.Count)"
  Write-SafeHost "e11_release_browser_generated_at=$($generatedAtUtc.ToString("o"))"
  Write-SafeHost "e11_release_browser_max_generated_age_minutes=$maxAgeMinutes"
  Write-SafeHost "e11_release_browser_age_minutes=$([Math]::Round(($nowUtc - $generatedAtUtc).TotalMinutes, 3))"
  Write-SafeHost "e11_release_secret_safe=true"
}

function Invoke-E11ReleaseArtifactReadbackGate {
  param([Parameter(Mandatory = $true)]$Handoff)

  $runtimeArtifactPath = Resolve-BoundedEvidenceArtifactPath $RuntimeCurrentEvidenceArtifactPath
  $browserArtifactPath = Resolve-BoundedEvidenceArtifactPath $BrowserEvidenceArtifactPath
  if (-not (Test-Path $runtimeArtifactPath)) {
    throw "E11 release runtime-current artifact missing at $runtimeArtifactPath"
  }
  if (-not (Test-Path $browserArtifactPath)) {
    throw "E11 release browser mutation artifact missing at $browserArtifactPath"
  }

  $runtimeArtifact = Read-JsonFile $runtimeArtifactPath
  $browserArtifact = Read-JsonFile $browserArtifactPath
  Assert-E11ReleaseRuntimeCurrentArtifactReadback -Artifact $runtimeArtifact
  try {
    Assert-E11ReleaseBrowserArtifactReadback -Handoff $Handoff -Artifact $browserArtifact -RuntimeArtifact $runtimeArtifact
  } catch {
    Write-E11ReleaseReadbackBlockedReport -Handoff $Handoff -RuntimeArtifact $runtimeArtifact -BrowserArtifact $browserArtifact -RuntimeArtifactPath $runtimeArtifactPath -BrowserArtifactPath $browserArtifactPath -Reason $_.Exception.Message
    throw
  }

  Write-SafeHost "E11 release artifact readback gate:"
  Write-SafeHost "e11_release_artifact_readback_status=pass"
  Write-SafeHost "e11_release_runtime_artifact_path=$runtimeArtifactPath"
  Write-SafeHost "e11_release_browser_artifact_path=$browserArtifactPath"
  Write-SafeHost "e11_release_runtime_current_verified=true"
  Write-SafeHost "e11_release_mutation_pass_artifact_passed=true"
  Write-SafeHost "e11_release_artifact_readback_passed=true"
  Write-SafeHost "e11_release_api_readback_passed=true"
  Write-SafeHost "e11_release_db_ledger_readback_passed=true"
  Write-SafeHost "e11_release_ui_readback_passed=true"
  Write-SafeHost "e11_release_audit_readback_passed=true"
  Write-SafeHost "e11_release_current_commit=$([string](Get-CurrentGitCommit))"
  Write-SafeHost "e11_release_runtime_image_id=$([string](Get-JsonProperty $runtimeArtifact "image_id" "E11 release runtime artifact"))"
  Write-SafeHost "e11_release_secret_safe=true"
  Write-SafeHost "e11_release_stale_or_simulated_artifact=false"
}

function Test-RuntimeCurrentNoBuildRecreateOptIn {
  param([Parameter(Mandatory = $true)]$Handoff)

  $runtimeHandoff = Get-JsonProperty $Handoff "runtimeCurrentHandoff" "UI runtime-current handoff"
  $noBuild = Get-JsonProperty $runtimeHandoff "noBuildRecreate" "UI runtime-current no-build recreate"
  $envName = [string](Get-JsonProperty $noBuild "env" "UI runtime-current no-build recreate")
  $requiredValue = [string](Get-JsonProperty $noBuild "requiredValue" "UI runtime-current no-build recreate")
  return $RuntimeCurrentNoBuildRecreateOptIn -or ([Environment]::GetEnvironmentVariable($envName) -eq $requiredValue)
}

function Test-RuntimeCurrentRebuildHandoffOptIn {
  param([Parameter(Mandatory = $true)]$Handoff)

  $runtimeHandoff = Get-JsonProperty $Handoff "runtimeCurrentHandoff" "UI runtime-current handoff"
  $rebuild = Get-JsonProperty $runtimeHandoff "rebuildHandoff" "UI runtime-current rebuild handoff"
  $envName = [string](Get-JsonProperty $rebuild "env" "UI runtime-current rebuild handoff")
  $requiredValue = [string](Get-JsonProperty $rebuild "requiredValue" "UI runtime-current rebuild handoff")
  return $RuntimeCurrentRebuildHandoffOptIn -or ([Environment]::GetEnvironmentVariable($envName) -eq $requiredValue)
}

function Write-RuntimeCurrentHandoffEvidenceArtifact {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [Parameter(Mandatory = $true)]$Evidence,
    [Parameter(Mandatory = $true)][bool]$WriteEnabled
  )

  $runtimeHandoff = Get-JsonProperty $Handoff "runtimeCurrentHandoff" "UI runtime-current handoff"
  $artifactContract = Get-JsonProperty $runtimeHandoff "evidenceArtifact" "UI runtime-current evidence artifact"
  $artifactPath = Resolve-BoundedEvidenceArtifactPath $RuntimeCurrentEvidenceArtifactPath
  $readbackClassification = "runtime_current_readback_not_requested"
  $readbackAvailable = $false
  $readbackFresh = $false

  if ($WriteEnabled) {
    $artifactDirectory = Split-Path -Path $artifactPath -Parent
    if (-not (Test-Path $artifactDirectory)) {
      New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
    }
    $json = $Evidence | ConvertTo-Json -Depth 12 -Compress
    Set-Content -Path $artifactPath -Value $json -Encoding UTF8
    $readBack = Read-JsonFile $artifactPath
    Assert-RuntimeCurrentHandoffEvidenceShape $readBack
    Assert-Equal (Get-JsonProperty $readBack "schema" "runtime-current evidence artifact") (Get-JsonProperty $artifactContract "schema" "UI runtime-current evidence artifact") "runtime-current evidence artifact schema"
    Assert-Equal (Get-JsonProperty $readBack "classification" "runtime-current evidence artifact") (Get-JsonProperty $Evidence "classification" "runtime-current evidence artifact") "runtime-current evidence artifact classification readback"
    Assert-Equal (Get-JsonProperty $readBack "readback_classification" "runtime-current evidence artifact") (Get-JsonProperty $Evidence "readback_classification" "runtime-current evidence artifact") "runtime-current evidence artifact readback classification"
    $readbackClassification = [string](Get-JsonProperty $readBack "readback_classification" "runtime-current evidence artifact")
    $readbackAvailable = $true
    $readbackFresh = $true
  }

  Write-SafeHost "runtime_current_evidence_artifact_path=$artifactPath"
  Write-SafeHost "runtime_current_evidence_artifact_write_enabled=$(Format-BoolMarker $WriteEnabled)"
  Write-SafeHost "runtime_current_evidence_artifact_readback_available=$(Format-BoolMarker $readbackAvailable)"
  Write-SafeHost "runtime_current_evidence_artifact_readback_fresh=$(Format-BoolMarker $readbackFresh)"
  Write-SafeHost "runtime_current_evidence_artifact_readback_classification=$readbackClassification"
}

function Invoke-RuntimeCurrentNoBuildRecreateGate {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [Parameter(Mandatory = $true)]$InitialProbe
  )

  Assert-RuntimeCurrentHandoffContract $Handoff
  $executionOptIn = Test-RuntimeCurrentNoBuildRecreateOptIn $Handoff
  $rebuildHandoffOptIn = Test-RuntimeCurrentRebuildHandoffOptIn $Handoff
  $writeEnabled = (Test-RuntimeCurrentEvidenceArtifactWriteOptIn $Handoff) -or $executionOptIn -or $rebuildHandoffOptIn
  $initialEvidence = New-RuntimeCurrentHandoffEvidence `
    -StaleOrUnverified ([bool]$InitialProbe.StaleOrUnverified) `
    -Reason ([string]$InitialProbe.Reason) `
    -SourceNewestUtc ([string]$InitialProbe.SourceNewestUtc) `
    -ContainerCreatedUtc ([string]$InitialProbe.ContainerCreatedUtc) `
    -ImageCreatedUtc ([string]$InitialProbe.ImageCreatedUtc) `
    -ImageId ([string]$InitialProbe.ImageId) `
    -GitCommit ([string]$InitialProbe.GitCommit) `
    -NoBuildRecreateOptIn $executionOptIn `
    -RebuildHandoffOptIn $rebuildHandoffOptIn `
    -RebuildHandoffRecorded $rebuildHandoffOptIn
  Assert-RuntimeCurrentHandoffEvidenceShape $initialEvidence

  Write-SafeHost "Runtime-current no-build recreate execution gate:"
  Write-SafeHost "runtime_current_recreate_opt_in=$(Format-BoolMarker $executionOptIn)"
  Write-SafeHost "runtime_current_recreate_default_executes=false"
  Write-SafeHost "runtime_current_recreate_default_build=false"
  Write-SafeHost "runtime_current_recreate_initial_classification=$($initialEvidence.classification)"
  Write-SafeHost "runtime_current_recreate_initial_blocker=$($initialEvidence.blocker)"
  Write-SafeHost "runtime_current_recreate_initial_readback_classification=$($initialEvidence.readback_classification)"
  Write-SafeHost "runtime_current_recreate_operator_command=$($initialEvidence.no_build_recreate_command)"
  Write-SafeHost "runtime_current_recreate_rebuild_handoff_command=$($initialEvidence.rebuild_handoff_command)"
  Write-SafeHost "runtime_current_recreate_rebuild_executes=false"
  Write-SafeHost "runtime_current_rebuild_handoff_opt_in=$(Format-BoolMarker $rebuildHandoffOptIn)"
  Write-SafeHost "runtime_current_rebuild_handoff_recorded=$(Format-BoolMarker ([bool]$initialEvidence.rebuild_handoff_recorded))"
  Write-SafeHost "runtime_current_rebuild_handoff_execution_allowed=false"
  Write-RuntimeCurrentHandoffEvidenceArtifact -Handoff $Handoff -Evidence $initialEvidence -WriteEnabled $writeEnabled

  if ($rebuildHandoffOptIn -and [bool]$initialEvidence.build_required) {
    Add-Blocker "runtime-current rebuild handoff opt-in - operator_handoff_recorded build_execution_forbidden reason=$($initialEvidence.reason)"
    return $InitialProbe
  }

  if (-not $executionOptIn) {
    return $InitialProbe
  }

  if ([bool]$initialEvidence.build_required) {
    Add-Blocker "runtime-current no-build recreate opt-in - build_required_but_forbidden reason=$($initialEvidence.reason)"
    return $InitialProbe
  }
  if ([string]$InitialProbe.Reason -eq "docker_unavailable") {
    Add-Blocker "runtime-current no-build recreate opt-in - docker_unavailable"
    return $InitialProbe
  }

  $docker = Get-DockerCommand
  if ([string]::IsNullOrWhiteSpace($docker)) {
    Add-Blocker "runtime-current no-build recreate opt-in - docker_unavailable"
    return $InitialProbe
  }

  $result = Invoke-NativeCapture -Command $docker -Arguments @("compose", "-f", $ComposeFile, "up", "-d", "--no-build", "--no-deps", "--force-recreate", "control-plane")
  $executed = $true
  Write-SafeHost "runtime_current_recreate_executed=true"
  Write-SafeHost "runtime_current_recreate_exit_code=$($result.ExitCode)"
  Assert-SecretSafeContent -Content ([string]$result.Output) -Context "runtime-current no-build recreate output"
  if ($result.ExitCode -ne 0) {
    $failedEvidence = New-RuntimeCurrentHandoffEvidence `
      -StaleOrUnverified ([bool]$InitialProbe.StaleOrUnverified) `
      -Reason "runtime_current_no_build_recreate_failed" `
      -SourceNewestUtc ([string]$InitialProbe.SourceNewestUtc) `
      -ContainerCreatedUtc ([string]$InitialProbe.ContainerCreatedUtc) `
      -ImageCreatedUtc ([string]$InitialProbe.ImageCreatedUtc) `
      -ImageId ([string]$InitialProbe.ImageId) `
      -GitCommit ([string]$InitialProbe.GitCommit) `
      -NoBuildRecreateOptIn $true `
      -NoBuildRecreateExecuted $executed `
      -NoBuildRecreateExitCode ([string]$result.ExitCode) `
      -RebuildHandoffOptIn $rebuildHandoffOptIn `
      -RebuildHandoffRecorded $rebuildHandoffOptIn
    Write-RuntimeCurrentHandoffEvidenceArtifact -Handoff $Handoff -Evidence $failedEvidence -WriteEnabled $true
    Add-Blocker "runtime-current no-build recreate opt-in - recreate_command_failed exit_code=$($result.ExitCode)"
    return $InitialProbe
  }

  $readbackProbe = Write-ControlPlaneRuntimeSourceProbe -SourcePaths (Get-ControlPlaneRuntimeSourcePaths)
  $readbackEvidence = New-RuntimeCurrentHandoffEvidence `
    -StaleOrUnverified ([bool]$readbackProbe.StaleOrUnverified) `
    -Reason ([string]$readbackProbe.Reason) `
    -SourceNewestUtc ([string]$readbackProbe.SourceNewestUtc) `
    -ContainerCreatedUtc ([string]$readbackProbe.ContainerCreatedUtc) `
    -ImageCreatedUtc ([string]$readbackProbe.ImageCreatedUtc) `
    -ImageId ([string]$readbackProbe.ImageId) `
    -GitCommit ([string]$readbackProbe.GitCommit) `
    -NoBuildRecreateOptIn $true `
    -NoBuildRecreateExecuted $true `
    -NoBuildRecreateExitCode "0" `
    -RebuildHandoffOptIn $rebuildHandoffOptIn `
    -RebuildHandoffRecorded $rebuildHandoffOptIn
  Write-SafeHost "runtime_current_recreate_readback_classification=$($readbackEvidence.readback_classification)"
  Write-SafeHost "runtime_current_recreate_after_classification=$($readbackEvidence.after_recreate_classification)"
  Write-RuntimeCurrentHandoffEvidenceArtifact -Handoff $Handoff -Evidence $readbackEvidence -WriteEnabled $true
  return $readbackProbe
}

function Assert-BrowserActionPlanContract {
  param([Parameter(Mandatory = $true)]$Handoff)

  $actionPlan = Get-JsonProperty $Handoff "browserActionPlan" "UI handoff"
  Assert-Equal (Get-JsonProperty $actionPlan "defaultMode" "UI browser action plan") "dry_run_only" "UI browser action plan default mode"
  Assert-True ([bool](Get-JsonProperty $actionPlan "usesDataTestIdsOnly" "UI browser action plan")) "UI browser action plan must use data-testid selectors"

  $mutationOptIn = Get-JsonProperty $actionPlan "mutationOptIn" "UI browser action plan"
  Assert-True ((Get-JsonProperty $mutationOptIn "defaultSubmitsLiveMutation" "UI browser action plan mutation opt-in") -eq $false) "UI browser action plan must not submit live mutation by default"
  Assert-Equal (Get-JsonProperty $mutationOptIn "env" "UI browser action plan mutation opt-in") "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_MUTATION" "UI browser action plan mutation opt-in env"
  Assert-Equal (Get-JsonProperty $mutationOptIn "requiredValue" "UI browser action plan mutation opt-in") "1" "UI browser action plan mutation opt-in value"

  $durationMarkers = Get-JsonProperty $actionPlan "durationMarkers" "UI browser action plan"
  foreach ($name in @("dryRunPlan", "executeApply", "idempotentReplay", "ledgerRefresh", "refundRefusal", "unavailable")) {
    $marker = [string](Get-JsonProperty $durationMarkers $name "UI browser action plan duration markers")
    if ($marker -notmatch '^[a-z0-9_]+$') {
      throw "UI browser action duration marker '$name' must be machine readable"
    }
  }

  $failureClassifications = Get-JsonProperty $actionPlan "failureClassifications" "UI browser action plan"
  foreach ($name in @("forbiddenSensitiveMarkerDetected", "mutationOptInMissing", "selectorUnavailable", "stateMismatch")) {
    $classification = [string](Get-JsonProperty $failureClassifications $name "UI browser action plan failure classifications")
    if ($classification -notmatch '^[a-z0-9_]+$') {
      throw "UI browser action failure classification '$name' must be machine readable"
    }
  }

  $selectors = Get-JsonProperty $Handoff "selectors" "UI handoff"
  $readinessStates = Get-JsonProperty $Handoff "readinessStates" "UI handoff"
  foreach ($selectorName in @(
      "dryRunForm",
      "dryRunButton",
      "operationInput",
      "amountInput",
      "currencyInput",
      "relatedLedgerEntryInput",
      "projectInput",
      "walletInput",
      "requestInput",
      "reasonInput",
      "executeButton",
      "ledgerRefreshStatus"
    )) {
    [void](Get-JsonProperty $selectors $selectorName "UI browser action selectors")
  }

  $steps = @(Get-JsonProperty $actionPlan "steps" "UI browser action plan")
  Assert-Equal $steps.Count 5 "UI browser action plan step count"
  $expectedSteps = @(
    @{ name = "dry_run_plan"; selector = "dryRunButton"; expectedState = "executePreflight"; submitsLiveMutation = $false },
    @{ name = "execute_apply"; selector = "executeButton"; expectedState = "appliedRefreshSuccess"; submitsLiveMutation = $true },
    @{ name = "idempotent_replay"; selector = "executeButton"; expectedState = "idempotentRefreshSuccess"; submitsLiveMutation = $true },
    @{ name = "refund_refusal"; selector = "executeButton"; expectedState = "blocked"; submitsLiveMutation = $true },
    @{ name = "ledger_refresh"; selector = "ledgerRefreshStatus"; expectedState = "appliedRefreshSuccess"; submitsLiveMutation = $false }
  )
  for ($i = 0; $i -lt $expectedSteps.Count; $i++) {
    $step = $steps[$i]
    $expected = $expectedSteps[$i]
    $context = "UI browser action plan step $($expected.name)"
    Assert-Equal (Get-JsonProperty $step "name" $context) $expected.name "$context name"
    Assert-Equal (Get-JsonProperty $step "selector" $context) $expected.selector "$context selector"
    Assert-Equal (Get-JsonProperty $step "expectedState" $context) $expected.expectedState "$context expected state"
    Assert-True ([bool](Get-JsonProperty $step "submitsLiveMutation" $context) -eq [bool]$expected.submitsLiveMutation) "$context mutation flag"
    [void](Get-JsonProperty $selectors $expected.selector "$context selector reference")
    [void](Get-JsonProperty $readinessStates $expected.expectedState "$context readiness state reference")
  }
}

function Assert-BrowserDomActionRunnerContract {
  param([Parameter(Mandatory = $true)]$Handoff)

  Assert-BrowserActionPlanContract $Handoff
  $runner = Get-JsonProperty $Handoff "browserDomActionRunner" "UI handoff"
  Assert-Equal (Get-JsonProperty $runner "defaultMode" "UI browser DOM action runner") "dom_action_runner_dry_run_only" "UI browser DOM action runner default mode"
  Assert-True ((Get-JsonProperty $runner "defaultClicksAdminUiActions" "UI browser DOM action runner") -eq $false) "UI browser DOM action runner must not click by default"
  Assert-True ((Get-JsonProperty $runner "defaultSubmitsLiveMutation" "UI browser DOM action runner") -eq $false) "UI browser DOM action runner must not mutate by default"
  Assert-Equal (Get-JsonProperty $runner "toolingBlocker" "UI browser DOM action runner") "browser_tooling_unavailable" "UI browser DOM action runner tooling blocker"

  $selectorAvailability = Get-JsonProperty $runner "selectorAvailability" "UI browser DOM action runner"
  Assert-Equal (Get-JsonProperty $selectorAvailability "source" "UI browser DOM action runner selector availability") "ledgerAdjustmentExecuteLiveSmokeContract.selectors" "UI browser DOM action runner selector source"
  Assert-Equal (Get-JsonProperty $selectorAvailability "summaryMarker" "UI browser DOM action runner selector availability") "selector_availability_summary" "UI browser DOM action runner selector summary marker"
  Assert-Equal (Get-JsonProperty $selectorAvailability "missingMarker" "UI browser DOM action runner selector availability") "selector_unavailable" "UI browser DOM action runner missing selector marker"

  $artifactEmission = Get-JsonProperty $runner "artifactEmission" "UI browser DOM action runner"
  Assert-Equal (Get-JsonProperty $artifactEmission "artifactName" "UI browser DOM action runner artifact emission") "billing_execute_browser_live_e2e_evidence.v1" "UI browser DOM action runner artifact name"
  Assert-Equal (Get-JsonProperty $artifactEmission "outputMarker" "UI browser DOM action runner artifact emission") "browser_runner_evidence_json" "UI browser DOM action runner artifact output marker"
  Assert-Equal (Get-JsonProperty $artifactEmission "writeOptInFlag" "UI browser DOM action runner artifact emission") "-BrowserEvidenceArtifactWriteOptIn" "UI browser DOM action runner artifact write flag"
  Assert-True ((Get-JsonProperty $artifactEmission "writeDisabledByDefault" "UI browser DOM action runner artifact emission") -eq $true) "UI browser DOM action runner artifact write must be disabled by default"

  $secretSafeOmission = Get-JsonProperty $runner "secretSafeOmission" "UI browser DOM action runner"
  foreach ($name in @("echoRequestMaterial", "echoSessionMaterial", "echoUrlCredentials")) {
    Assert-True ((Get-JsonProperty $secretSafeOmission $name "UI browser DOM action runner secret-safe omission") -eq $false) "UI browser DOM action runner must omit $name"
  }

  $steps = @(Get-JsonProperty (Get-JsonProperty $Handoff "browserActionPlan" "UI handoff") "steps" "UI browser action plan")
  $stepOrder = Get-JsonStringArray (Get-JsonProperty $runner "stepOrder" "UI browser DOM action runner") "UI browser DOM action runner step order"
  Assert-Equal $stepOrder.Count $steps.Count "UI browser DOM action runner step order count"
  $plannedTimeouts = Get-JsonProperty $runner "plannedTimeoutMs" "UI browser DOM action runner"
  $durationMapping = Get-JsonProperty $runner "durationFieldMapping" "UI browser DOM action runner"
  foreach ($step in $steps) {
    $name = [string](Get-JsonProperty $step "name" "UI browser action step")
    Assert-True ($stepOrder -contains $name) "UI browser DOM action runner step order missing $name"
    $timeout = [int](Get-JsonProperty $plannedTimeouts $name "UI browser DOM action runner planned timeout")
    Assert-True ($timeout -gt 0 -and $timeout -le 30000) "UI browser DOM action runner timeout for $name must be bounded"
    $durationField = [string](Get-JsonProperty $durationMapping $name "UI browser DOM action runner duration mapping")
    if ($durationField -notmatch '^[a-z0-9_]+$') {
      throw "UI browser DOM action runner duration field '$durationField' must be machine readable"
    }
  }
}

function Write-BrowserActionPlanDryRun {
  param([Parameter(Mandatory = $true)]$Handoff)

  Assert-BrowserActionPlanContract $Handoff
  $actionPlan = Get-JsonProperty $Handoff "browserActionPlan" "UI handoff"
  $durationMarkers = Get-JsonProperty $actionPlan "durationMarkers" "UI browser action plan"
  $failureClassifications = Get-JsonProperty $actionPlan "failureClassifications" "UI browser action plan"
  $mutationOptIn = Get-JsonProperty $actionPlan "mutationOptIn" "UI browser action plan"
  $unavailable = [string](Get-JsonProperty $durationMarkers "unavailable" "UI browser action plan duration markers")
  $mutationEnabled = [Environment]::GetEnvironmentVariable([string](Get-JsonProperty $mutationOptIn "env" "UI browser action plan mutation opt-in")) -eq [string](Get-JsonProperty $mutationOptIn "requiredValue" "UI browser action plan mutation opt-in")
  $mutationClassification = "none"
  if (-not $mutationEnabled) {
    $mutationClassification = [string](Get-JsonProperty $failureClassifications "mutationOptInMissing" "UI browser action plan failure classifications")
  }

  Write-SafeHost "Browser ledger execute action plan dry-run:"
  Write-SafeHost "browser_action_plan_mode=$([string](Get-JsonProperty $actionPlan "defaultMode" "UI browser action plan"))"
  Write-SafeHost "browser_action_plan_uses_data_testids=true"
  Write-SafeHost "browser_action_plan_live_mutation_enabled=$(Format-BoolMarker $mutationEnabled)"
  Write-SafeHost "browser_action_plan_failure_classification=$mutationClassification"
  Write-SafeHost "$([string](Get-JsonProperty $durationMarkers "dryRunPlan" "UI browser action plan duration markers"))=$unavailable"
  Write-SafeHost "$([string](Get-JsonProperty $durationMarkers "executeApply" "UI browser action plan duration markers"))=$unavailable"
  Write-SafeHost "$([string](Get-JsonProperty $durationMarkers "idempotentReplay" "UI browser action plan duration markers"))=$unavailable"
  Write-SafeHost "$([string](Get-JsonProperty $durationMarkers "refundRefusal" "UI browser action plan duration markers"))=$unavailable"
  Write-SafeHost "$([string](Get-JsonProperty $durationMarkers "ledgerRefresh" "UI browser action plan duration markers"))=$unavailable"

  $steps = @(Get-JsonProperty $actionPlan "steps" "UI browser action plan")
  foreach ($step in $steps) {
    Write-SafeHost "browser_action_step=$([string](Get-JsonProperty $step "name" "UI browser action step"));selector=$([string](Get-JsonProperty $step "selector" "UI browser action step"));expected_state=$([string](Get-JsonProperty $step "expectedState" "UI browser action step"));submits_live_mutation=$(Format-BoolMarker ([bool](Get-JsonProperty $step "submitsLiveMutation" "UI browser action step")))"
  }
}

function Write-BrowserDomActionRunnerDryRun {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [Parameter(Mandatory = $true)][string]$ToolingStatus
  )

  Assert-BrowserDomActionRunnerContract $Handoff
  $runner = Get-JsonProperty $Handoff "browserDomActionRunner" "UI handoff"
  $actionPlan = Get-JsonProperty $Handoff "browserActionPlan" "UI handoff"
  $selectors = Get-JsonProperty $Handoff "selectors" "UI handoff"
  $selectorAvailability = Get-JsonProperty $runner "selectorAvailability" "UI browser DOM action runner"
  $plannedTimeouts = Get-JsonProperty $runner "plannedTimeoutMs" "UI browser DOM action runner"
  $durationMapping = Get-JsonProperty $runner "durationFieldMapping" "UI browser DOM action runner"
  $artifactEmission = Get-JsonProperty $runner "artifactEmission" "UI browser DOM action runner"
  $secretSafeOmission = Get-JsonProperty $runner "secretSafeOmission" "UI browser DOM action runner"
  $steps = @(Get-JsonProperty $actionPlan "steps" "UI browser action plan")
  $missingSelectors = @()
  $selectorKeys = @()
  foreach ($step in $steps) {
    $selectorKey = [string](Get-JsonProperty $step "selector" "UI browser DOM action step")
    $selectorKeys += $selectorKey
    try {
      [void](Get-JsonProperty $selectors $selectorKey "UI browser DOM action selector")
    } catch {
      $missingSelectors += $selectorKey
    }
  }

  $summary = "ready"
  if ($missingSelectors.Count -gt 0) {
    $summary = "$([string](Get-JsonProperty $selectorAvailability "missingMarker" "UI browser DOM action selector availability")):$($missingSelectors -join '+')"
  }
  $toolingBlocker = "none"
  if ($ToolingStatus -ne "available") {
    $toolingBlocker = [string](Get-JsonProperty $runner "toolingBlocker" "UI browser DOM action runner")
  }

  Write-SafeHost "Browser ledger execute DOM action runner dry-run boundary:"
  Write-SafeHost "browser_dom_action_runner_mode=$([string](Get-JsonProperty $runner "defaultMode" "UI browser DOM action runner"))"
  Write-SafeHost "browser_dom_action_runner_clicks_enabled=false"
  Write-SafeHost "browser_dom_action_runner_live_mutation_enabled=false"
  Write-SafeHost "browser_dom_action_runner_tooling=$ToolingStatus"
  Write-SafeHost "browser_dom_action_runner_tooling_blocker=$toolingBlocker"
  Write-SafeHost "$([string](Get-JsonProperty $selectorAvailability "summaryMarker" "UI browser DOM action selector availability"))=$summary"
  Write-SafeHost "browser_dom_action_runner_selector_count=$($selectorKeys.Count)"
  Write-SafeHost "browser_dom_action_runner_secret_url_credentials_echoed=$(Format-BoolMarker ([bool](Get-JsonProperty $secretSafeOmission "echoUrlCredentials" "UI browser DOM action runner secret-safe omission")))"
  Write-SafeHost "browser_dom_action_runner_secret_session_echoed=$(Format-BoolMarker ([bool](Get-JsonProperty $secretSafeOmission "echoSessionMaterial" "UI browser DOM action runner secret-safe omission")))"
  Write-SafeHost "browser_dom_action_runner_request_material_echoed=$(Format-BoolMarker ([bool](Get-JsonProperty $secretSafeOmission "echoRequestMaterial" "UI browser DOM action runner secret-safe omission")))"
  Write-SafeHost "browser_dom_action_runner_artifact=$([string](Get-JsonProperty $artifactEmission "artifactName" "UI browser DOM action runner artifact emission"))"
  Write-SafeHost "browser_dom_action_runner_artifact_output=$([string](Get-JsonProperty $artifactEmission "outputMarker" "UI browser DOM action runner artifact emission"))"
  Write-SafeHost "browser_dom_action_runner_artifact_write_disabled_default=$(Format-BoolMarker ([bool](Get-JsonProperty $artifactEmission "writeDisabledByDefault" "UI browser DOM action runner artifact emission")))"

  $index = 0
  foreach ($step in $steps) {
    $name = [string](Get-JsonProperty $step "name" "UI browser DOM action step")
    $selectorKey = [string](Get-JsonProperty $step "selector" "UI browser DOM action step")
    $timeout = [int](Get-JsonProperty $plannedTimeouts $name "UI browser DOM action planned timeout")
    $durationField = [string](Get-JsonProperty $durationMapping $name "UI browser DOM action duration mapping")
    Write-SafeHost "browser_dom_action_runner_step=$index;name=$name;selector=$selectorKey;planned_timeout_ms=$timeout;duration_field=$durationField;click_planned=false;mutation_planned=false"
    $index += 1
  }
}

function Assert-BrowserPlaywrightLaunchReadinessContract {
  param([Parameter(Mandatory = $true)]$Handoff)

  $launch = Get-JsonProperty $Handoff "browserPlaywrightLaunchReadiness" "UI handoff"
  Assert-Equal (Get-JsonProperty $launch "defaultMode" "UI browser Playwright launch readiness") "playwright_launch_readiness_only" "UI browser Playwright launch readiness default mode"
  Assert-True ((Get-JsonProperty $launch "defaultClicksAdminUiActions" "UI browser Playwright launch readiness") -eq $false) "UI browser Playwright launch readiness must not click by default"
  Assert-True ((Get-JsonProperty $launch "defaultSubmitsLiveMutation" "UI browser Playwright launch readiness") -eq $false) "UI browser Playwright launch readiness must not mutate by default"

  $durationFields = Get-JsonProperty $launch "durationFields" "UI browser Playwright launch readiness"
  foreach ($name in @("browserLaunchDurationMs", "contextSetupDurationMs", "pageReadyDurationMs", "selectorSnapshotDurationMs", "serviceReadinessDurationMs")) {
    $field = [string](Get-JsonProperty $durationFields $name "UI browser Playwright duration fields")
    if ($field -notmatch '^[a-z0-9_]+$') {
      throw "UI browser Playwright duration field '$name' must be machine readable"
    }
  }

  $readinessFields = Get-JsonProperty $launch "readinessFields" "UI browser Playwright launch readiness"
  foreach ($name in @("browserLaunchReady", "contextReady", "mutationAllowed", "pageReady", "safeAdminUiUrl", "safeControlPlaneUrl", "selectorSnapshotReady")) {
    $field = [string](Get-JsonProperty $readinessFields $name "UI browser Playwright readiness fields")
    if ($field -notmatch '^[a-z0-9_]+$') {
      throw "UI browser Playwright readiness field '$name' must be machine readable"
    }
  }

  $blockers = Get-JsonProperty $launch "blockers" "UI browser Playwright launch readiness"
  foreach ($name in @("adminUiUnreachable", "browserToolingUnavailable", "controlPlaneHealthUnreachable", "liveMutationOptInMissing", "sessionMaterialMissing")) {
    $blocker = [string](Get-JsonProperty $blockers $name "UI browser Playwright blockers")
    if ($blocker -notmatch '^[a-z0-9_]+$') {
      throw "UI browser Playwright blocker '$name' must be machine readable"
    }
  }

  $artifactEmission = Get-JsonProperty $launch "artifactEmission" "UI browser Playwright launch readiness"
  Assert-Equal (Get-JsonProperty $artifactEmission "artifactName" "UI browser Playwright artifact emission") "billing_execute_browser_live_e2e_evidence.v1" "UI browser Playwright artifact name"
  Assert-Equal (Get-JsonProperty $artifactEmission "outputMarker" "UI browser Playwright artifact emission") "browser_runner_evidence_json" "UI browser Playwright artifact output marker"
  Assert-True ((Get-JsonProperty $artifactEmission "writeDisabledByDefault" "UI browser Playwright artifact emission") -eq $true) "UI browser Playwright artifact write must be disabled by default"

  $secretSafeOmission = Get-JsonProperty $launch "secretSafeOmission" "UI browser Playwright launch readiness"
  foreach ($name in @("echoRequestMaterial", "echoSessionMaterial", "echoUrlCredentials")) {
    Assert-True ((Get-JsonProperty $secretSafeOmission $name "UI browser Playwright secret-safe omission") -eq $false) "UI browser Playwright must omit $name"
  }
}

function Write-BrowserPlaywrightLaunchReadinessBoundary {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [Parameter(Mandatory = $true)][string]$ToolingStatus,
    [Parameter(Mandatory = $true)]$AdminUiProbe,
    [Parameter(Mandatory = $true)]$ControlPlaneProbe,
    [Parameter(Mandatory = $true)][bool]$MutationEnabled,
    [Parameter(Mandatory = $true)][bool]$SessionMaterialPresent,
    [Parameter(Mandatory = $true)][int]$ServiceReadinessDurationMs
  )

  Assert-BrowserPlaywrightLaunchReadinessContract $Handoff
  $launch = Get-JsonProperty $Handoff "browserPlaywrightLaunchReadiness" "UI handoff"
  $durationFields = Get-JsonProperty $launch "durationFields" "UI browser Playwright launch readiness"
  $readinessFields = Get-JsonProperty $launch "readinessFields" "UI browser Playwright launch readiness"
  $blockers = Get-JsonProperty $launch "blockers" "UI browser Playwright launch readiness"
  $artifactEmission = Get-JsonProperty $launch "artifactEmission" "UI browser Playwright launch readiness"
  $selectorReadiness = Get-ActionSelectorReadiness $Handoff
  $adminUiUrl = Get-SafeSmokeUrlSummary $AdminUiBaseUrl "Admin UI URL"
  $backendUrl = Get-SafeSmokeUrlSummary $ControlPlaneBaseUrl "Control Plane backend URL"
  $launchBlockers = @()
  if ($ToolingStatus -ne "available") {
    $launchBlockers += [string](Get-JsonProperty $blockers "browserToolingUnavailable" "UI browser Playwright blockers")
  }
  if (-not [bool]$AdminUiProbe.Reachable) {
    $launchBlockers += [string](Get-JsonProperty $blockers "adminUiUnreachable" "UI browser Playwright blockers")
  }
  if (-not [bool]$ControlPlaneProbe.Reachable) {
    $launchBlockers += [string](Get-JsonProperty $blockers "controlPlaneHealthUnreachable" "UI browser Playwright blockers")
  }
  if (-not $SessionMaterialPresent) {
    $launchBlockers += [string](Get-JsonProperty $blockers "sessionMaterialMissing" "UI browser Playwright blockers")
  }
  if (-not $MutationEnabled) {
    $launchBlockers += [string](Get-JsonProperty $blockers "liveMutationOptInMissing" "UI browser Playwright blockers")
  }

  $browserReady = $ToolingStatus -eq "available"
  $contextReady = $browserReady -and [bool]$AdminUiProbe.Reachable -and $SessionMaterialPresent
  $pageReady = $contextReady -and [bool]$ControlPlaneProbe.Reachable
  $selectorReady = $pageReady -and $selectorReadiness -eq "ready"
  $unavailable = "unavailable"
  $blockerSummary = "none"
  if ($launchBlockers.Count -gt 0) {
    $blockerSummary = ($launchBlockers -join "+")
  }

  Write-SafeHost "Browser ledger execute Playwright launch readiness boundary:"
  Write-SafeHost "browser_playwright_launch_mode=$([string](Get-JsonProperty $launch "defaultMode" "UI browser Playwright launch readiness"))"
  Write-SafeHost "browser_playwright_blockers=$blockerSummary"
  Write-SafeHost "browser_playwright_tooling=$ToolingStatus"
  Write-SafeHost "$([string](Get-JsonProperty $readinessFields "safeAdminUiUrl" "UI browser Playwright readiness fields"))=true"
  Write-SafeHost "$([string](Get-JsonProperty $readinessFields "safeControlPlaneUrl" "UI browser Playwright readiness fields"))=true"
  Write-SafeHost "browser_playwright_admin_ui_origin=$adminUiUrl"
  Write-SafeHost "browser_playwright_control_plane_origin=$backendUrl"
  Write-SafeHost "$([string](Get-JsonProperty $readinessFields "browserLaunchReady" "UI browser Playwright readiness fields"))=$(Format-BoolMarker $browserReady)"
  Write-SafeHost "$([string](Get-JsonProperty $readinessFields "contextReady" "UI browser Playwright readiness fields"))=$(Format-BoolMarker $contextReady)"
  Write-SafeHost "$([string](Get-JsonProperty $readinessFields "pageReady" "UI browser Playwright readiness fields"))=$(Format-BoolMarker $pageReady)"
  Write-SafeHost "$([string](Get-JsonProperty $readinessFields "selectorSnapshotReady" "UI browser Playwright readiness fields"))=$(Format-BoolMarker $selectorReady)"
  Write-SafeHost "$([string](Get-JsonProperty $readinessFields "mutationAllowed" "UI browser Playwright readiness fields"))=false"
  Write-SafeHost "browser_playwright_clicks_enabled=false"
  Write-SafeHost "browser_playwright_live_mutation_enabled=false"
  Write-SafeHost "$([string](Get-JsonProperty $durationFields "serviceReadinessDurationMs" "UI browser Playwright duration fields"))=$ServiceReadinessDurationMs"
  Write-SafeHost "$([string](Get-JsonProperty $durationFields "browserLaunchDurationMs" "UI browser Playwright duration fields"))=$unavailable"
  Write-SafeHost "$([string](Get-JsonProperty $durationFields "contextSetupDurationMs" "UI browser Playwright duration fields"))=$unavailable"
  Write-SafeHost "$([string](Get-JsonProperty $durationFields "pageReadyDurationMs" "UI browser Playwright duration fields"))=$unavailable"
  Write-SafeHost "$([string](Get-JsonProperty $durationFields "selectorSnapshotDurationMs" "UI browser Playwright duration fields"))=$unavailable"
  Write-SafeHost "browser_playwright_selector_snapshot=$selectorReadiness"
  Write-SafeHost "browser_playwright_secret_url_credentials_echoed=false"
  Write-SafeHost "browser_playwright_secret_session_echoed=false"
  Write-SafeHost "browser_playwright_request_material_echoed=false"
  Write-SafeHost "browser_playwright_artifact=$([string](Get-JsonProperty $artifactEmission "artifactName" "UI browser Playwright artifact emission"))"
  Write-SafeHost "browser_playwright_artifact_output=$([string](Get-JsonProperty $artifactEmission "outputMarker" "UI browser Playwright artifact emission"))"
  Write-SafeHost "browser_playwright_artifact_write_disabled_default=$(Format-BoolMarker ([bool](Get-JsonProperty $artifactEmission "writeDisabledByDefault" "UI browser Playwright artifact emission")))"
}

function Assert-BrowserMutationPassArtifactClosureContract {
  param([Parameter(Mandatory = $true)]$Handoff)

  $closure = Get-JsonProperty $Handoff "browserMutationPassArtifactClosure" "UI handoff"
  Assert-Equal (Get-JsonProperty $closure "artifactName" "UI browser mutation pass artifact closure") "billing_execute_browser_live_e2e_evidence.v1" "UI browser mutation closure artifact name"
  Assert-Equal (Get-JsonProperty $closure "defaultMode" "UI browser mutation pass artifact closure") "mutation_pass_artifact_closure_gate" "UI browser mutation closure default mode"
  Assert-True ((Get-JsonProperty $closure "defaultClosesLiveGap" "UI browser mutation pass artifact closure") -eq $false) "UI browser mutation closure must not close by default"
  Assert-True ((Get-JsonProperty $closure "defaultSubmitsLiveMutation" "UI browser mutation pass artifact closure") -eq $false) "UI browser mutation closure must not mutate by default"

  $requiredReadiness = Get-JsonProperty $closure "requiredReadiness" "UI browser mutation pass artifact closure"
  foreach ($name in @("adminUiReachable", "browserLaunchReady", "contextReady", "controlPlaneHealthReachable", "mutationOptInEnabled", "pageReady", "selectorSnapshotReady", "sessionMaterialPresent")) {
    Assert-True ([bool](Get-JsonProperty $requiredReadiness $name "UI browser mutation closure readiness")) "UI browser mutation closure must require $name"
  }

  $freshness = Get-JsonProperty $closure "requiredArtifactFreshness" "UI browser mutation pass artifact closure"
  foreach ($name in @("requireCurrentGitCommit", "requireFreshnessMarker", "requireHandoffFresh", "requireReadBack")) {
    Assert-True ([bool](Get-JsonProperty $freshness $name "UI browser mutation closure freshness")) "UI browser mutation closure must require $name"
  }

  $expectedActionOutcomes = Get-JsonProperty $closure "expectedActionOutcomes" "UI browser mutation pass artifact closure"
  foreach ($name in @("dry_run_plan", "execute_apply", "idempotent_replay", "refund_refusal", "ledger_refresh")) {
    [void](Get-JsonProperty $expectedActionOutcomes $name "UI browser mutation closure action outcomes")
  }

  $classificationValues = Get-JsonProperty $closure "classificationValues" "UI browser mutation pass artifact closure"
  foreach ($name in @("blocked", "failed", "notRequested", "passed")) {
    $classification = [string](Get-JsonProperty $classificationValues $name "UI browser mutation closure classifications")
    if ($classification -notmatch '^[a-z0-9_]+$') {
      throw "UI browser mutation closure classification '$name' must be machine readable"
    }
  }

  $statusMarkers = Get-JsonProperty $closure "statusMarkers" "UI browser mutation pass artifact closure"
  foreach ($name in @("blocked", "closureEligible", "passed")) {
    $marker = [string](Get-JsonProperty $statusMarkers $name "UI browser mutation closure status markers")
    if ($marker -notmatch '^[a-z0-9_]+$') {
      throw "UI browser mutation closure status marker '$name' must be machine readable"
    }
  }
}

function Set-SyntheticPassActionEvidence {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [Parameter(Mandatory = $true)]$Artifact
  )

  $closure = Get-JsonProperty $Handoff "browserMutationPassArtifactClosure" "UI handoff"
  $durationFields = Get-JsonProperty $closure "durationFields" "UI browser mutation pass artifact closure"
  foreach ($name in @("browserLaunchDurationMs", "contextSetupDurationMs", "dryRunPlanDurationMs", "executeApplyDurationMs", "idempotentReplayDurationMs", "ledgerRefreshDurationMs", "pageReadyDurationMs", "refundRefusalDurationMs", "selectorSnapshotDurationMs", "serviceReadinessDurationMs", "submitLatencyMs")) {
    $field = [string](Get-JsonProperty $durationFields $name "UI browser mutation closure duration fields")
    $Artifact.durations.$field = 1
  }

  $expectedActionOutcomes = Get-JsonProperty $closure "expectedActionOutcomes" "UI browser mutation pass artifact closure"
  foreach ($action in @(Get-JsonProperty $Artifact "actions" "browser evidence artifact")) {
    $name = [string](Get-JsonProperty $action "name" "browser evidence action")
    $expected = [string](Get-JsonProperty $expectedActionOutcomes $name "UI browser mutation closure action outcomes")
    $action.outcome = $expected
    $action.status = $expected
    $action.duration_ms = 1
  }

  if ($Artifact.PSObject.Properties.Name -contains "runtime_current") {
    $Artifact.runtime_current.classification = "runtime_current_verified"
    $Artifact.runtime_current.stale_or_unverified = $false
    $Artifact.runtime_current.reason = "synthetic_contract_self_test"
    $Artifact.runtime_current.blocker = "none"
  }
  if ($Artifact.PSObject.Properties.Name -contains "runtime_current_artifact") {
    $Artifact.runtime_current_artifact.linked = $true
    $Artifact.runtime_current_artifact.classification = "runtime_current_verified"
  }
  if ($Artifact.PSObject.Properties.Name -contains "session_verification") {
    $Artifact.session_verification.marker = "admin_session_verified"
    $Artifact.session_verification.verified = $true
  }
  if ($Artifact.PSObject.Properties.Name -contains "mutation_controls") {
    $Artifact.mutation_controls.mutation_opt_in_enabled = $true
    $Artifact.mutation_controls.artifact_write_opt_in_enabled = $true
    $Artifact.mutation_controls.artifact_readback_opt_in_enabled = $true
  }
  if ($Artifact.PSObject.Properties.Name -contains "api_readback") {
    $Artifact.api_readback.dry_run_plan = "executePreflight"
    $Artifact.api_readback.execute_apply = "applied"
    $Artifact.api_readback.idempotent_replay = "idempotent"
    $Artifact.api_readback.refund_refusal = "blocked"
    $Artifact.api_readback.ledger_refresh = "success"
  }
  if ($Artifact.PSObject.Properties.Name -contains "ledger_readback") {
    $Artifact.ledger_readback.applied_ledger_entry_visible = $true
    $Artifact.ledger_readback.idempotent_replay_reused_ledger_entry = $true
    $Artifact.ledger_readback.refund_refusal_no_ledger_write = $true
    $Artifact.ledger_readback.ledger_refresh_visible = $true
  }
  if ($Artifact.PSObject.Properties.Name -contains "failure_taxonomy") {
    $Artifact.failure_taxonomy.failed_action = "none"
    $Artifact.failure_taxonomy.failure_classification = "none"
    $Artifact.failure_taxonomy.session_missing = $false
    $Artifact.failure_taxonomy.runtime_stale = $false
    $Artifact.failure_taxonomy.mutation_opt_in_missing = $false
    $Artifact.failure_taxonomy.artifact_write_missing = $false
    $Artifact.failure_taxonomy.artifact_readback_failed = $false
    $Artifact.failure_taxonomy.idempotent_replay_failed = $false
    $Artifact.failure_taxonomy.refund_refusal_missing = $false
    $Artifact.failure_taxonomy.ledger_refresh_missing = $false
    $Artifact.failure_taxonomy.duration_non_numeric = $false
    $Artifact.failure_taxonomy.stale_or_simulated_artifact = $false
    $Artifact.failure_taxonomy.browser_unavailable = $false
  }
  Update-BrowserEvidenceClassifications -Handoff $Handoff -Artifact $Artifact
}

function Set-BrowserEvidenceFromRunnerResult {
  param(
    [Parameter(Mandatory = $true)]$Artifact,
    [Parameter(Mandatory = $true)]$RunnerResult
  )

  foreach ($property in @($RunnerResult.durations.PSObject.Properties)) {
    if ($Artifact.durations.PSObject.Properties.Name -contains $property.Name) {
      $Artifact.durations.($property.Name) = $property.Value
    }
  }

  foreach ($resultAction in @($RunnerResult.actions)) {
    $name = [string]$resultAction.name
    foreach ($artifactAction in @($Artifact.actions)) {
      if ([string]$artifactAction.name -eq $name) {
        $artifactAction.status = [string]$resultAction.status
        $artifactAction.outcome = [string]$resultAction.outcome
        $artifactAction.duration_ms = $resultAction.duration_ms
      }
    }
  }

  $missingSelectorKeys = @()
  if ($RunnerResult.PSObject.Properties.Name -contains "missing_selector_keys") {
    $missingSelectorKeys = @($RunnerResult.missing_selector_keys | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^[A-Za-z0-9_]+$' } | Select-Object -First 20)
  }
  if ($Artifact.PSObject.Properties.Name -contains "selector_snapshot") {
    $Artifact.selector_snapshot.missing_selector_keys = @($missingSelectorKeys)
    $Artifact.selector_snapshot.missing_selector_count = @($missingSelectorKeys).Count
  }

  if ($Artifact.PSObject.Properties.Name -contains "browser_runner") {
    $failedAction = "none"
    if ($RunnerResult.PSObject.Properties.Name -contains "failed_action" -and [string]$RunnerResult.failed_action -match '^[A-Za-z0-9_]+$') {
      $failedAction = [string]$RunnerResult.failed_action
    }
    $Artifact.browser_runner.failed_action = $failedAction
  }
  if ($Artifact.PSObject.Properties.Name -contains "api_readback") {
    foreach ($action in @($Artifact.actions)) {
      $name = [string]$action.name
      if ($Artifact.api_readback.PSObject.Properties.Name -contains $name) {
        $Artifact.api_readback.$name = [string]$action.outcome
      }
    }
  }
  if ($Artifact.PSObject.Properties.Name -contains "ledger_readback" -and [string]$Artifact.outcome -eq "passed") {
    $Artifact.ledger_readback.applied_ledger_entry_visible = $true
    $Artifact.ledger_readback.idempotent_replay_reused_ledger_entry = $true
    $Artifact.ledger_readback.refund_refusal_no_ledger_write = $true
    $Artifact.ledger_readback.ledger_refresh_visible = $true
  }
  if ($Artifact.PSObject.Properties.Name -contains "failure_taxonomy") {
    $failedAction = if ($Artifact.PSObject.Properties.Name -contains "browser_runner") { [string]$Artifact.browser_runner.failed_action } else { "none" }
    $Artifact.failure_taxonomy.failed_action = $failedAction
    $Artifact.failure_taxonomy.failure_classification = if ($failedAction -eq "none") { "none" } else { Get-BrowserRunnerErrorClass -ErrorMessage "" -FailedAction $failedAction }
    $Artifact.failure_taxonomy.idempotent_replay_failed = $failedAction -eq "idempotent_replay"
    $Artifact.failure_taxonomy.refund_refusal_missing = $failedAction -eq "refund_refusal"
    $Artifact.failure_taxonomy.ledger_refresh_missing = $failedAction -eq "ledger_refresh"
  }
}

function Test-BrowserEvidenceDurationValue {
  param([AllowNull()]$Value)

  if ($null -eq $Value) {
    return $false
  }
  if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [int64] -or $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) {
    return [double]$Value -ge 0
  }
  return $false
}

function Get-BrowserRunnerErrorClass {
  param(
    [AllowNull()][string]$ErrorMessage,
    [AllowNull()][string]$FailedAction = ""
  )

  $safe = Redact-SecretLikeString ([string]$ErrorMessage)
  if ([string]$FailedAction -eq "idempotent_replay") {
    return "browser_idempotent_replay_failed"
  }
  if ([string]::IsNullOrWhiteSpace($safe)) {
    return "browser_live_runner_failed"
  }
  if ($safe -match '(?i)executable.*doesn.*exist|browser.*not.*installed|playwright.*install') {
    return "browser_playwright_browser_unavailable"
  }
  if ($safe -match '(?i)timeout|timed out') {
    return "browser_live_runner_timeout"
  }
  if ($safe -match '(?i)selector_snapshot_missing') {
    return "browser_selector_snapshot_missing"
  }
  if ($safe -match '(?i)cannot find module|module not found') {
    return "browser_runner_dependency_unavailable"
  }
  if ($safe -match '(?i)strict mode violation|locator|selector|data-testid') {
    return "browser_selector_or_action_failed"
  }
  if ($safe -match '(?i)401|403|unauthorized|forbidden|session') {
    return "browser_session_auth_failed"
  }
  return "browser_live_runner_failed"
}

function Test-BrowserMutationPassArtifactClosure {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [Parameter(Mandatory = $true)]$Artifact
  )

  try {
    Assert-BrowserEvidenceArtifactFreshness -Handoff $Handoff -Artifact $Artifact
  } catch {
    return $false
  }

  if ([string]$Artifact.outcome -ne "passed") {
    return $false
  }
  if ([string](Get-JsonProperty $Artifact.runtime_current "classification" "browser evidence runtime current") -ne "runtime_current_verified") {
    return $false
  }
  if ([string](Get-JsonProperty $Artifact.matrix "browser_tooling" "browser evidence matrix") -ne "available") {
    return $false
  }
  foreach ($name in @("admin_ui_reachable", "control_plane_health_reachable", "session_material_present", "mutation_opt_in_enabled")) {
    if ((Get-JsonProperty $Artifact.matrix $name "browser evidence matrix") -ne $true) {
      return $false
    }
  }

  $closure = Get-JsonProperty $Handoff "browserMutationPassArtifactClosure" "UI handoff"
  $durationFields = Get-JsonProperty $closure "durationFields" "UI browser mutation pass artifact closure"
  foreach ($name in @("browserLaunchDurationMs", "contextSetupDurationMs", "dryRunPlanDurationMs", "executeApplyDurationMs", "idempotentReplayDurationMs", "ledgerRefreshDurationMs", "pageReadyDurationMs", "refundRefusalDurationMs", "selectorSnapshotDurationMs", "serviceReadinessDurationMs", "submitLatencyMs")) {
    $field = [string](Get-JsonProperty $durationFields $name "UI browser mutation closure duration fields")
    $value = Get-JsonProperty $Artifact.durations $field "browser evidence durations"
    if (-not (Test-BrowserEvidenceDurationValue $value)) {
      return $false
    }
  }

  $expectedActionOutcomes = Get-JsonProperty $closure "expectedActionOutcomes" "UI browser mutation pass artifact closure"
  foreach ($action in @(Get-JsonProperty $Artifact "actions" "browser evidence artifact")) {
    $name = [string](Get-JsonProperty $action "name" "browser evidence action")
    $expected = [string](Get-JsonProperty $expectedActionOutcomes $name "UI browser mutation closure action outcomes")
    if ([string](Get-JsonProperty $action "outcome" "browser evidence action") -ne $expected) {
      return $false
    }
    if (-not (Test-BrowserEvidenceDurationValue (Get-JsonProperty $action "duration_ms" "browser evidence action"))) {
      return $false
    }
  }

  return $true
}

function Write-BrowserMutationPassArtifactClosureGate {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [Parameter(Mandatory = $true)][string]$ToolingStatus,
    [Parameter(Mandatory = $true)]$AdminUiProbe,
    [Parameter(Mandatory = $true)]$ControlPlaneProbe,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Blockers,
    [Parameter(Mandatory = $true)][bool]$MutationEnabled,
    [Parameter(Mandatory = $true)][bool]$SessionMaterialPresent,
    [Parameter(Mandatory = $true)][int]$ServiceReadinessDurationMs
  )

  Assert-BrowserMutationPassArtifactClosureContract $Handoff
  $closure = Get-JsonProperty $Handoff "browserMutationPassArtifactClosure" "UI handoff"
  $statusMarkers = Get-JsonProperty $closure "statusMarkers" "UI browser mutation pass artifact closure"
  $currentArtifact = New-BrowserEvidenceArtifact -Handoff $Handoff -Outcome "blocked" -Blockers $Blockers -ToolingStatus $ToolingStatus -AdminUiProbe $AdminUiProbe -ControlPlaneProbe $ControlPlaneProbe -MutationEnabled $MutationEnabled -SessionMaterialPresent $SessionMaterialPresent -ServiceReadinessDurationMs $ServiceReadinessDurationMs
  $probe = [PSCustomObject]@{ Reachable = $true }
  $syntheticPass = New-BrowserEvidenceArtifact -Handoff $Handoff -Outcome "passed" -Blockers @() -ToolingStatus "available" -AdminUiProbe $probe -ControlPlaneProbe $probe -MutationEnabled $true -SessionMaterialPresent $true -ServiceReadinessDurationMs 1
  Set-SyntheticPassActionEvidence -Handoff $Handoff -Artifact $syntheticPass
  Assert-True (Test-BrowserMutationPassArtifactClosure -Handoff $Handoff -Artifact $syntheticPass) "synthetic complete browser mutation evidence must be closure eligible"
  Assert-True (-not (Test-BrowserMutationPassArtifactClosure -Handoff $Handoff -Artifact $currentArtifact)) "blocked browser mutation evidence must not be closure eligible"

  $closureEligible = Test-BrowserMutationPassArtifactClosure -Handoff $Handoff -Artifact $currentArtifact
  $status = if ($closureEligible) { [string](Get-JsonProperty $statusMarkers "closureEligible" "UI browser mutation closure status markers") } else { [string](Get-JsonProperty $statusMarkers "blocked" "UI browser mutation closure status markers") }
  $blockerSummary = "none"
  if ($Blockers.Count -gt 0) {
    $blockerSummary = ($Blockers -join "+")
  }

  Write-SafeHost "Browser ledger execute mutation pass artifact closure gate:"
  Write-SafeHost "browser_mutation_pass_closure_status=$status"
  Write-SafeHost "browser_mutation_pass_closure_eligible=$(Format-BoolMarker $closureEligible)"
  Write-SafeHost "browser_mutation_pass_closure_blockers=$blockerSummary"
  Write-SafeHost "browser_mutation_pass_default_closes_live_gap=false"
  Write-SafeHost "browser_mutation_pass_default_mutation_allowed=false"
  Write-SafeHost "browser_mutation_pass_requires_artifact_readback=true"
  Write-SafeHost "browser_mutation_pass_requires_freshness=true"
  Write-SafeHost "browser_mutation_pass_requires_action_outcomes=true"
  Write-SafeHost "browser_mutation_pass_secret_url_credentials_echoed=false"
  Write-SafeHost "browser_mutation_pass_secret_session_echoed=false"
  Write-SafeHost "browser_mutation_pass_request_material_echoed=false"
}

function Assert-BrowserMutationFinalDodContract {
  param([Parameter(Mandatory = $true)]$Handoff)

  $dod = Get-JsonProperty $Handoff "browserMutationFinalDod" "UI browser mutation final DoD"
  Assert-Equal (Get-JsonProperty $dod "schema" "UI browser mutation final DoD") "billing_execute_browser_mutation_final_dod.v1" "UI browser mutation DoD schema"
  Assert-Equal (Get-JsonProperty $dod "e11TargetState" "UI browser mutation final DoD") "x_requires_real_browser_mutation_pass" "UI browser mutation DoD target"
  Assert-Equal (Get-JsonProperty $dod "finalPassClassification" "UI browser mutation final DoD") "e11_browser_mutation_dod_passed" "UI browser mutation DoD pass classification"
  foreach ($name in @("defaultBuildsRuntime", "defaultClosesE11", "defaultRunsBrowserRunner", "defaultSubmitsLiveMutation")) {
    Assert-True ((Get-JsonProperty $dod $name "UI browser mutation final DoD defaults") -eq $false) "UI browser mutation DoD must keep $name false"
  }

  $checklist = Get-JsonStringArray (Get-JsonProperty $dod "checklist" "UI browser mutation final DoD") "UI browser mutation final DoD checklist"
  Assert-StringSetEqual $checklist @(
    "runtime_current_verified",
    "admin_session_verified_secret_omitted",
    "mutation_opt_in_enabled",
    "artifact_write_opt_in_enabled",
    "artifact_readback_passed",
    "apply_outcome_applied",
    "idempotent_replay_outcome_idempotent",
    "refund_refusal_outcome_blocked",
    "ledger_refresh_outcome_success",
    "numeric_duration_fields_present",
    "artifact_fresh_current_commit",
    "secret_safe_omission"
  ) "UI browser mutation final DoD checklist"

  $matrix = Get-JsonProperty $dod "acceptanceMatrix" "UI browser mutation final DoD matrix"
  $passRequires = Get-JsonProperty $matrix "passRequires" "UI browser mutation final DoD pass matrix"
  foreach ($name in @("adminSessionVerifiedSecretOmitted", "artifactFreshCurrentCommit", "artifactReadbackOptIn", "artifactReadbackPassed", "artifactWriteOptIn", "browserToolingAvailable", "mutationOptIn", "numericDurations", "runtimeCurrentVerified", "secretSafeOmission")) {
    Assert-True ([bool](Get-JsonProperty $passRequires $name "UI browser mutation DoD pass requirement")) "UI browser mutation DoD must require $name"
  }
  Assert-Equal (Get-JsonProperty $passRequires "applyOutcome" "UI browser mutation DoD pass requirement") "applied" "UI browser mutation DoD apply outcome"
  Assert-Equal (Get-JsonProperty $passRequires "idempotentReplayOutcome" "UI browser mutation DoD pass requirement") "idempotent" "UI browser mutation DoD idempotent outcome"
  Assert-Equal (Get-JsonProperty $passRequires "refundRefusalOutcome" "UI browser mutation DoD pass requirement") "blocked" "UI browser mutation DoD refund outcome"
  Assert-Equal (Get-JsonProperty $passRequires "ledgerRefreshOutcome" "UI browser mutation DoD pass requirement") "success" "UI browser mutation DoD ledger refresh outcome"

  $rejected = Get-JsonProperty $matrix "rejectedEvidence" "UI browser mutation final DoD rejected matrix"
  foreach ($name in @("browserUnavailable", "missingArtifact", "missingSession", "simulatedArtifact", "staleArtifact", "staleRuntime")) {
    $classification = [string](Get-JsonProperty $rejected $name "UI browser mutation DoD rejected evidence")
    if ($classification -notmatch '^[a-z0-9_]+$') {
      throw "UI browser mutation DoD rejected evidence '$name' must be machine readable"
    }
  }
}

function Write-BrowserMutationFinalDodMatrix {
  param([Parameter(Mandatory = $true)]$Handoff)

  Assert-BrowserMutationFinalDodContract $Handoff
  $dod = Get-JsonProperty $Handoff "browserMutationFinalDod" "UI browser mutation final DoD"
  $artifactContract = Get-JsonProperty $Handoff "browserEvidenceArtifact" "UI handoff"
  $artifactSchema = Get-JsonProperty $artifactContract "artifactSchema" "UI browser evidence artifact schema"
  $matrix = Get-JsonProperty $dod "acceptanceMatrix" "UI browser mutation final DoD matrix"
  $passRequires = Get-JsonProperty $matrix "passRequires" "UI browser mutation final DoD pass matrix"
  $rejected = Get-JsonProperty $matrix "rejectedEvidence" "UI browser mutation final DoD rejected matrix"
  Write-SafeHost "Browser ledger execute final mutation DoD matrix:"
  Write-SafeHost "browser_mutation_final_dod_schema=$([string](Get-JsonProperty $dod "schema" "UI browser mutation final DoD"))"
  Write-SafeHost "browser_mutation_final_dod_target=$([string](Get-JsonProperty $dod "e11TargetState" "UI browser mutation final DoD"))"
  Write-SafeHost "browser_mutation_final_dod_default_build=false"
  Write-SafeHost "browser_mutation_final_dod_default_runner=false"
  Write-SafeHost "browser_mutation_final_dod_default_mutation=false"
  Write-SafeHost "browser_mutation_final_dod_default_closes_e11=false"
  foreach ($item in Get-JsonStringArray (Get-JsonProperty $dod "checklist" "UI browser mutation final DoD") "UI browser mutation final DoD checklist") {
    Write-SafeHost "browser_mutation_final_dod_checklist=$item"
  }
  Write-SafeHost "browser_mutation_runner_artifact_schema=$([string](Get-JsonProperty $artifactContract "artifactName" "UI browser evidence artifact"))"
  foreach ($item in Get-JsonStringArray (Get-JsonProperty $artifactSchema "apiReadbackFields" "UI browser evidence artifact schema") "UI browser evidence API readback fields") {
    Write-SafeHost "browser_mutation_runner_artifact_api_readback_field=$item"
  }
  foreach ($item in Get-JsonStringArray (Get-JsonProperty $artifactSchema "ledgerReadbackFields" "UI browser evidence artifact schema") "UI browser evidence ledger readback fields") {
    Write-SafeHost "browser_mutation_runner_artifact_ledger_readback_field=$item"
  }
  foreach ($item in Get-JsonStringArray (Get-JsonProperty $artifactSchema "failureTaxonomyFields" "UI browser evidence failure taxonomy fields") "UI browser evidence failure taxonomy fields") {
    Write-SafeHost "browser_mutation_runner_artifact_failure_taxonomy=$item"
  }
  foreach ($name in @("runtimeCurrentVerified", "adminSessionVerifiedSecretOmitted", "mutationOptIn", "artifactWriteOptIn", "artifactReadbackOptIn", "artifactReadbackPassed", "numericDurations", "artifactFreshCurrentCommit", "secretSafeOmission", "browserToolingAvailable")) {
    Write-SafeHost "browser_mutation_final_dod_pass_requires=${name}|$([string](Get-JsonProperty $passRequires $name "UI browser mutation DoD pass requirement"))"
  }
  foreach ($name in @("applyOutcome", "idempotentReplayOutcome", "refundRefusalOutcome", "ledgerRefreshOutcome")) {
    Write-SafeHost "browser_mutation_final_dod_pass_requires=${name}|$([string](Get-JsonProperty $passRequires $name "UI browser mutation DoD pass requirement"))"
  }
  foreach ($name in @("staleRuntime", "missingArtifact", "staleArtifact", "simulatedArtifact", "browserUnavailable", "missingSession")) {
    Write-SafeHost "browser_mutation_final_dod_rejects=${name}|$([string](Get-JsonProperty $rejected $name "UI browser mutation DoD rejected evidence"))"
  }
  Write-SafeHost "browser_mutation_final_dod_secret_session_echoed=false"
  Write-SafeHost "browser_mutation_final_dod_request_material_echoed=false"
  Write-SafeHost "browser_mutation_final_dod_url_credentials_echoed=false"
}

function Assert-RuntimeCurrentOperatorHandoffPackContract {
  param([Parameter(Mandatory = $true)]$Handoff)

  $pack = Get-JsonProperty $Handoff "runtimeCurrentOperatorHandoffPack" "UI runtime-current operator handoff pack"
  Assert-Equal (Get-JsonProperty $pack "schema" "UI runtime-current operator handoff pack") "billing_execute_runtime_current_operator_handoff_pack.v1" "operator handoff pack schema"
  Assert-Equal (Get-JsonProperty $pack "boundedRunnerTimeoutMs" "UI runtime-current operator handoff pack") 90000 "operator handoff bounded runner timeout"
  foreach ($name in @("defaultBuildsRuntime", "defaultConsumesSession", "defaultMutates", "defaultReadsRuntimeArtifact", "defaultRecreatesRuntime")) {
    Assert-True ((Get-JsonProperty $pack $name "UI runtime-current operator handoff pack defaults") -eq $false) "operator handoff pack must keep $name false"
  }

  $commands = Get-JsonProperty $pack "commands" "UI runtime-current operator handoff pack commands"
  $runtimeWrite = Get-JsonProperty $commands "runtimeArtifactWrite" "UI runtime-current operator commands"
  Assert-Equal (Get-JsonProperty $runtimeWrite "flag" "UI runtime-current operator runtime write") "-RuntimeCurrentEvidenceArtifactWriteOptIn" "runtime write flag"
  Assert-Equal (Get-JsonProperty $runtimeWrite "env" "UI runtime-current operator runtime write") "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_RUNTIME_CURRENT_ARTIFACT_WRITE=1" "runtime write env"
  Assert-SecretSafeContent -Content ([string](Get-JsonProperty $runtimeWrite "command" "UI runtime-current operator runtime write")) -Context "runtime-current operator runtime write command"

  $runtimeReadback = Get-JsonProperty $commands "runtimeArtifactReadback" "UI runtime-current operator commands"
  Assert-Equal (Get-JsonProperty $runtimeReadback "flag" "UI runtime-current operator runtime readback") "-RuntimeCurrentEvidenceArtifactReadbackOptIn" "runtime readback flag"
  Assert-Equal (Get-JsonProperty $runtimeReadback "env" "UI runtime-current operator runtime readback") "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_RUNTIME_CURRENT_ARTIFACT_READBACK=1" "runtime readback env"

  $session = Get-JsonProperty $commands "adminSessionVerify" "UI runtime-current operator commands"
  Assert-Equal (Get-JsonProperty $session "env" "UI runtime-current operator session") "CONTROL_PLANE_ADMIN_SESSION_TOKEN" "operator session env"
  Assert-Equal (Get-JsonProperty $session "flag" "UI runtime-current operator session") "-AdminSessionHandoff" "operator session flag"
  Assert-Equal (Get-JsonProperty $session "marker" "UI runtime-current operator session") "admin_session_present" "operator session marker"
  Assert-True ((Get-JsonProperty $session "secretEchoed" "UI runtime-current operator session") -eq $false) "operator session command must not echo secret"

  $runner = Get-JsonProperty $commands "browserMutationRunner" "UI runtime-current operator commands"
  Assert-SecretSafeContent -Content ([string](Get-JsonProperty $runner "command" "UI runtime-current operator browser runner")) -Context "operator browser runner command"
  $runnerEnv = Get-JsonProperty $runner "env" "UI runtime-current operator browser runner env"
  Assert-Equal (Get-JsonProperty $runnerEnv "mutation" "UI runtime-current operator browser runner env") "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_MUTATION=1" "operator mutation env"
  Assert-Equal (Get-JsonProperty $runnerEnv "artifactWrite" "UI runtime-current operator browser runner env") "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_ARTIFACT_WRITE=1" "operator artifact write env"
  Assert-Equal (Get-JsonProperty $runnerEnv "session" "UI runtime-current operator browser runner env") "CONTROL_PLANE_ADMIN_SESSION_TOKEN" "operator browser session env"

  $required = Get-JsonProperty $pack "requiredArtifactFields" "UI runtime-current operator required artifacts"
  Assert-StringSetEqual (Get-JsonStringArray (Get-JsonProperty $required "runtimeCurrentArtifact" "UI runtime-current operator runtime artifact fields") "operator runtime artifact fields") @("schema", "status", "classification", "blocker", "source_newest_utc", "container_created_utc", "image_created_utc", "image_id", "git_commit", "alignment_rules", "readback_classification", "rebuild_handoff_execution_allowed") "operator runtime artifact fields"
  $browserArtifactFields = Get-JsonStringArray (Get-JsonProperty $required "browserMutationArtifact" "UI runtime-current operator browser artifact fields") "operator browser artifact fields"
  foreach ($field in @("runtime_current_artifact", "session_verification", "mutation_controls", "api_readback", "ledger_readback", "failure_taxonomy")) {
    if ($browserArtifactFields -notcontains $field) {
      throw "operator browser artifact fields missing '$field'"
    }
  }

  $taxonomy = Get-JsonProperty $pack "failureTaxonomy" "UI runtime-current operator failure taxonomy"
  foreach ($name in @("artifactReadbackMissing", "artifactWriteMissing", "browserUnavailable", "durationNonNumeric", "idempotentReplayFailed", "ledgerRefreshMissing", "mutationOptInMissing", "recreateUnavailable", "rebuildForbidden", "refundRefusalMissing", "runtimeArtifactMissing", "runtimeArtifactSimulated", "runtimeArtifactStale", "sessionInvalid", "sessionMissing", "unsafeArtifactPath")) {
    $value = [string](Get-JsonProperty $taxonomy $name "UI runtime-current operator failure taxonomy")
    if ($value -notmatch '^[a-z0-9_]+$') {
      throw "operator failure taxonomy '$name' must be machine readable"
    }
  }

  $states = Get-JsonProperty $pack "stateMarkers" "UI runtime-current operator state markers"
  Assert-Equal (Get-JsonProperty $states "runtimeCurrentHandoffReady" "UI runtime-current operator state markers") "runtime_current_handoff_ready" "operator runtime-current handoff ready marker"
  Assert-Equal (Get-JsonProperty $states "mutationRunnerReadyBlocked" "UI runtime-current operator state markers") "mutation_runner_ready_blocked" "operator mutation runner ready blocked marker"
  Assert-Equal (Get-JsonProperty $states "mutationPassArtifactPassed" "UI runtime-current operator state markers") "mutation_pass_artifact_passed" "operator mutation pass artifact marker"
  Assert-Equal (Get-JsonProperty $states "e11X" "UI runtime-current operator state markers") "e11_x" "operator E11 x marker"

  Assert-StringSetEqual (Get-JsonStringArray (Get-JsonProperty $pack "sequence" "UI runtime-current operator sequence") "operator handoff sequence") @("operator_rebuild_or_recreate_outside_script", "runtime_artifact_write", "runtime_artifact_readback", "admin_session_verify_secret_omitted", "mutation_and_browser_artifact_opt_in", "browser_runner_bounded_execution", "browser_artifact_readback", "final_dod_classification") "operator handoff sequence"
}

function Write-RuntimeCurrentOperatorHandoffPack {
  param([Parameter(Mandatory = $true)]$Handoff)

  Assert-RuntimeCurrentOperatorHandoffPackContract $Handoff
  $pack = Get-JsonProperty $Handoff "runtimeCurrentOperatorHandoffPack" "UI runtime-current operator handoff pack"
  $commands = Get-JsonProperty $pack "commands" "UI runtime-current operator handoff commands"
  $states = Get-JsonProperty $pack "stateMarkers" "UI runtime-current operator state markers"
  $taxonomy = Get-JsonProperty $pack "failureTaxonomy" "UI runtime-current operator failure taxonomy"
  Write-SafeHost "Runtime-current operator handoff pack:"
  Write-SafeHost "runtime_current_operator_handoff_schema=$([string](Get-JsonProperty $pack "schema" "UI runtime-current operator handoff pack"))"
  Write-SafeHost "runtime_current_operator_handoff_default_build=false"
  Write-SafeHost "runtime_current_operator_handoff_default_recreate=false"
  Write-SafeHost "runtime_current_operator_handoff_default_mutation=false"
  Write-SafeHost "runtime_current_operator_handoff_default_consumes_admin_session|false"
  Write-SafeHost "runtime_current_operator_handoff_bounded_runner_timeout_ms=$([int](Get-JsonProperty $pack "boundedRunnerTimeoutMs" "UI runtime-current operator handoff pack"))"
  foreach ($step in Get-JsonStringArray (Get-JsonProperty $pack "sequence" "UI runtime-current operator sequence") "operator handoff sequence") {
    Write-SafeHost "runtime_current_operator_handoff_sequence=$step"
  }
  Write-SafeHost "runtime_current_operator_handoff_runtime_write_command=$([string](Get-JsonProperty (Get-JsonProperty $commands "runtimeArtifactWrite" "operator commands") "command" "operator runtime write"))"
  Write-SafeHost "runtime_current_operator_handoff_runtime_readback_command=$([string](Get-JsonProperty (Get-JsonProperty $commands "runtimeArtifactReadback" "operator commands") "command" "operator runtime readback"))"
  Write-SafeHost "runtime_current_operator_handoff_admin_session_flag=$([string](Get-JsonProperty (Get-JsonProperty $commands "adminSessionVerify" "operator commands") "flag" "operator session flag"))"
  Write-SafeHost "runtime_current_operator_handoff_admin_session_secret_echoed=false"
  Write-SafeHost "runtime_current_operator_handoff_browser_runner_command=$([string](Get-JsonProperty (Get-JsonProperty $commands "browserMutationRunner" "operator commands") "command" "operator browser runner"))"
  foreach ($name in @("runtimeCurrentHandoffReady", "mutationRunnerReadyBlocked", "mutationPassArtifactPassed", "e11X")) {
    Write-SafeHost "runtime_current_operator_handoff_state=$([string](Get-JsonProperty $states $name "operator state markers"))"
  }
  foreach ($name in @("runtimeArtifactMissing", "runtimeArtifactStale", "runtimeArtifactSimulated", "rebuildForbidden", "recreateUnavailable", "sessionMissing", "sessionInvalid", "mutationOptInMissing", "artifactWriteMissing", "artifactReadbackMissing", "idempotentReplayFailed", "refundRefusalMissing", "ledgerRefreshMissing", "browserUnavailable", "durationNonNumeric", "unsafeArtifactPath")) {
    Write-SafeHost "runtime_current_operator_handoff_failure=$name|$([string](Get-JsonProperty $taxonomy $name "operator failure taxonomy"))"
  }
}

function Assert-RuntimeCurrentEvidenceAcceptanceMatrixContract {
  param([Parameter(Mandatory = $true)]$Handoff)

  $matrix = Get-JsonProperty $Handoff "runtimeCurrentEvidenceAcceptanceMatrix" "UI runtime-current evidence acceptance matrix"
  Assert-Equal (Get-JsonProperty $matrix "schema" "UI runtime-current evidence acceptance matrix") "billing_execute_runtime_current_evidence_acceptance_matrix.v1" "runtime-current evidence acceptance schema"

  $defaults = Get-JsonProperty $matrix "defaults" "UI runtime-current evidence acceptance defaults"
  foreach ($name in @("buildsRuntime", "consumesAdminSession", "mutates", "readsBrowserArtifact", "readsRuntimeArtifact", "recreatesRuntime")) {
    Assert-True ((Get-JsonProperty $defaults $name "UI runtime-current evidence acceptance defaults") -eq $false) "runtime-current evidence acceptance must keep $name false by default"
  }

  $schema = Get-JsonProperty $matrix "acceptanceSchema" "UI runtime-current evidence acceptance schema"
  $runtimeArtifact = Get-JsonProperty $schema "runtimeArtifact" "UI runtime-current evidence runtime artifact schema"
  Assert-Equal (Get-JsonProperty $runtimeArtifact "schema" "UI runtime-current evidence runtime artifact schema") "control_plane_ledger_execute_runtime_current_handoff.v1" "runtime-current evidence runtime artifact schema name"
  Assert-Equal (Get-JsonProperty $runtimeArtifact "provenanceField" "UI runtime-current evidence runtime artifact schema") "provenance" "runtime artifact provenance field"
  Assert-Equal (Get-JsonProperty $runtimeArtifact "currentCommitField" "UI runtime-current evidence runtime artifact schema") "git_commit" "runtime artifact current commit field"
  Assert-StringSetEqual (Get-JsonStringArray (Get-JsonProperty $runtimeArtifact "requiredFields" "UI runtime-current evidence runtime artifact fields") "runtime-current evidence runtime artifact fields") @("schema", "status", "classification", "blocker", "source_newest_utc", "container_created_utc", "image_created_utc", "image_id", "git_commit", "alignment_rules", "readback_classification", "rebuild_handoff_execution_allowed") "runtime-current evidence runtime artifact fields"
  $timestampComparison = Get-JsonProperty $runtimeArtifact "timestampComparison" "UI runtime-current timestamp comparison"
  foreach ($name in @("sourceNewestUtc", "runtimeCreatedUtc", "imageCreatedUtc")) {
    $value = [string](Get-JsonProperty $timestampComparison $name "UI runtime-current timestamp comparison")
    if ($value -notmatch '^[a-z0-9_]+$') {
      throw "runtime-current timestamp comparison field '$name' must be machine readable"
    }
  }

  $session = Get-JsonProperty $schema "adminSessionVerification" "UI runtime-current evidence admin session schema"
  Assert-Equal (Get-JsonProperty $session "marker" "UI runtime-current evidence admin session schema") "admin_session_verified_secret_omitted" "admin session verification marker"
  Assert-Equal (Get-JsonProperty $session "requiredField" "UI runtime-current evidence admin session schema") "session_verification" "admin session verification field"
  Assert-True ([bool](Get-JsonProperty $session "secretOmitted" "UI runtime-current evidence admin session schema")) "admin session verification must omit secret"
  Assert-True ((Get-JsonProperty $session "rawSecretRequired" "UI runtime-current evidence admin session schema") -eq $false) "admin session verification must not require raw secret"

  $controls = Get-JsonProperty $schema "mutationControls" "UI runtime-current evidence mutation controls"
  foreach ($name in @("mutationOptIn", "artifactWriteOptIn", "artifactReadbackOptIn")) {
    $value = [string](Get-JsonProperty $controls $name "UI runtime-current evidence mutation controls")
    if ($value -notmatch '^[a-z0-9_]+$') {
      throw "mutation control field '$name' must be machine readable"
    }
  }

  $browserArtifact = Get-JsonProperty $schema "browserArtifact" "UI runtime-current evidence browser artifact schema"
  Assert-Equal (Get-JsonProperty $browserArtifact "schema" "UI runtime-current evidence browser artifact schema") "billing_execute_browser_live_e2e_evidence.v1" "browser mutation artifact schema"
  $browserFields = Get-JsonStringArray (Get-JsonProperty $browserArtifact "requiredFields" "UI runtime-current evidence browser artifact fields") "runtime-current evidence browser artifact fields"
  foreach ($field in @("provenance", "freshness", "runtime_current", "session_verification", "mutation_controls", "api_readback", "ledger_readback", "failure_taxonomy", "durations", "actions", "secret_safe")) {
    if ($browserFields -notcontains $field) {
      throw "runtime-current evidence browser artifact fields missing '$field'"
    }
  }

  $readback = Get-JsonProperty $schema "readback" "UI runtime-current evidence readback"
  Assert-StringSetEqual (Get-JsonStringArray (Get-JsonProperty $readback "apiFields" "UI runtime-current evidence API readback fields") "runtime-current evidence API readback fields") @("dry_run_plan", "execute_apply", "idempotent_replay", "refund_refusal", "ledger_refresh") "runtime-current evidence API readback fields"
  Assert-StringSetEqual (Get-JsonStringArray (Get-JsonProperty $readback "ledgerFields" "UI runtime-current evidence ledger readback fields") "runtime-current evidence ledger readback fields") @("applied_ledger_entry_visible", "idempotent_replay_reused_ledger_entry", "refund_refusal_no_ledger_write", "ledger_refresh_visible") "runtime-current evidence ledger readback fields"

  $classification = Get-JsonProperty $schema "resultClassification" "UI runtime-current evidence result classification"
  Assert-Equal (Get-JsonProperty $classification "failedActionField" "UI runtime-current evidence result classification") "failed_action" "runtime-current evidence failed action field"
  Assert-Equal (Get-JsonProperty $classification "failureClassificationField" "UI runtime-current evidence result classification") "failure_classification" "runtime-current evidence failure classification field"

  $secretSafe = Get-JsonProperty $schema "secretSafeOmission" "UI runtime-current evidence secret-safe omission"
  foreach ($name in @("requestMaterialEchoed", "sessionMaterialEchoed", "urlCredentialsEchoed")) {
    Assert-True ((Get-JsonProperty $secretSafe $name "UI runtime-current evidence secret-safe omission") -eq $false) "runtime-current evidence must keep $name false"
  }

  $taxonomy = Get-JsonProperty $matrix "refusalTaxonomy" "UI runtime-current evidence refusal taxonomy"
  foreach ($name in @("artifactReadbackMissing", "artifactWriteMissing", "browserArtifactSimulated", "browserArtifactStale", "browserUnavailable", "durationNonNumeric", "idempotentReplayFailed", "ledgerRefreshMissing", "mutationOptInMissing", "rawSecretPresent", "refundRefusalMissing", "runtimeArtifactMissing", "runtimeArtifactSimulated", "runtimeArtifactStale", "runtimeCommitMismatch", "runtimeUnsafeArtifact", "sessionInvalidMarker", "sessionMissingMarker")) {
    $value = [string](Get-JsonProperty $taxonomy $name "UI runtime-current evidence refusal taxonomy")
    if ($value -notmatch '^[a-z0-9_]+$') {
      throw "runtime-current evidence refusal '$name' must be machine readable"
    }
  }

  $states = Get-JsonProperty $matrix "acceptedStates" "UI runtime-current evidence accepted states"
  foreach ($name in @("runtimeCurrentEvidenceAcceptedForReview", "mutationRunnerReadyBlocked", "mutationPassArtifactPassed", "e11X")) {
    [void](Get-JsonProperty $states $name "UI runtime-current evidence accepted states")
  }

  $simulation = Get-JsonProperty $matrix "simulationPolicy" "UI runtime-current evidence simulation policy"
  Assert-True ([bool](Get-JsonProperty $simulation "acceptedShapeSimulations" "UI runtime-current evidence simulation policy")) "runtime-current evidence must support accepted-shape simulations"
  Assert-True ((Get-JsonProperty $simulation "simulationCanMarkFinalX" "UI runtime-current evidence simulation policy") -eq $false) "runtime-current evidence simulation must not mark final x"
  foreach ($name in @("buildsRuntime", "mutates", "recreatesRuntime")) {
    Assert-True ((Get-JsonProperty $simulation $name "UI runtime-current evidence simulation policy") -eq $false) "runtime-current evidence simulation must not $name"
  }
}

function Write-RuntimeCurrentEvidenceAcceptanceMatrix {
  param([Parameter(Mandatory = $true)]$Handoff)

  Assert-RuntimeCurrentEvidenceAcceptanceMatrixContract $Handoff
  $matrix = Get-JsonProperty $Handoff "runtimeCurrentEvidenceAcceptanceMatrix" "UI runtime-current evidence acceptance matrix"
  $schema = Get-JsonProperty $matrix "acceptanceSchema" "UI runtime-current evidence acceptance schema"
  $states = Get-JsonProperty $matrix "acceptedStates" "UI runtime-current evidence accepted states"
  $taxonomy = Get-JsonProperty $matrix "refusalTaxonomy" "UI runtime-current evidence refusal taxonomy"

  Write-SafeHost "Runtime-current and mutation evidence acceptance matrix:"
  Write-SafeHost "runtime_current_evidence_acceptance_schema=$([string](Get-JsonProperty $matrix "schema" "UI runtime-current evidence acceptance matrix"))"
  Write-SafeHost "runtime_current_evidence_acceptance_default_reads_runtime_artifact=false"
  Write-SafeHost "runtime_current_evidence_acceptance_default_reads_browser_artifact=false"
  Write-SafeHost "runtime_current_evidence_acceptance_default_consumes_admin_session|false"
  Write-SafeHost "runtime_current_evidence_acceptance_default_build=false"
  Write-SafeHost "runtime_current_evidence_acceptance_default_recreate=false"
  Write-SafeHost "runtime_current_evidence_acceptance_default_mutation=false"
  foreach ($name in @("runtimeCurrentEvidenceAcceptedForReview", "mutationRunnerReadyBlocked", "mutationPassArtifactPassed", "e11X")) {
    Write-SafeHost "runtime_current_evidence_acceptance_state=$name|$([string](Get-JsonProperty $states $name "runtime-current evidence accepted states"))"
  }

  $runtimeArtifact = Get-JsonProperty $schema "runtimeArtifact" "runtime-current evidence runtime artifact schema"
  foreach ($field in Get-JsonStringArray (Get-JsonProperty $runtimeArtifact "requiredFields" "runtime-current evidence runtime artifact fields") "runtime-current evidence runtime artifact fields") {
    Write-SafeHost "runtime_current_evidence_acceptance_runtime_field=$field"
  }
  $browserArtifact = Get-JsonProperty $schema "browserArtifact" "runtime-current evidence browser artifact schema"
  foreach ($field in Get-JsonStringArray (Get-JsonProperty $browserArtifact "requiredFields" "runtime-current evidence browser artifact fields") "runtime-current evidence browser artifact fields") {
    Write-SafeHost "runtime_current_evidence_acceptance_browser_field=$field"
  }
  $readback = Get-JsonProperty $schema "readback" "runtime-current evidence readback"
  foreach ($field in Get-JsonStringArray (Get-JsonProperty $readback "apiFields" "runtime-current evidence API readback fields") "runtime-current evidence API readback fields") {
    Write-SafeHost "runtime_current_evidence_acceptance_api_readback_field=$field"
  }
  foreach ($field in Get-JsonStringArray (Get-JsonProperty $readback "ledgerFields" "runtime-current evidence ledger readback fields") "runtime-current evidence ledger readback fields") {
    Write-SafeHost "runtime_current_evidence_acceptance_ledger_readback_field=$field"
  }
  foreach ($name in @("runtimeArtifactMissing", "runtimeUnsafeArtifact", "runtimeArtifactStale", "runtimeArtifactSimulated", "runtimeCommitMismatch", "sessionMissingMarker", "sessionInvalidMarker", "mutationOptInMissing", "artifactWriteMissing", "artifactReadbackMissing", "browserUnavailable", "idempotentReplayFailed", "refundRefusalMissing", "ledgerRefreshMissing", "durationNonNumeric", "browserArtifactStale", "browserArtifactSimulated", "rawSecretPresent")) {
    Write-SafeHost "runtime_current_evidence_acceptance_refusal=$name|$([string](Get-JsonProperty $taxonomy $name "runtime-current evidence refusal taxonomy"))"
  }

  Write-SafeHost "runtime_current_evidence_acceptance_simulation=accepted_runtime_shape;state=runtime_current_evidence_accepted_for_review;classification=runtime_current_verified;simulation_can_mark_final_x=false;build=false;recreate=false;mutation=false"
  Write-SafeHost "runtime_current_evidence_acceptance_simulation=mutation_runner_ready_blocked;state=mutation_runner_ready_blocked;classification=session_mutation_artifact_gate;simulation_can_mark_final_x=false;build=false;recreate=false;mutation=false"
  Write-SafeHost "runtime_current_evidence_acceptance_simulation=mutation_pass_artifact_passed_shape;state=mutation_pass_artifact_passed;classification=mutation_pass_artifact_passed;simulation_can_mark_final_x=false;build=false;recreate=false;mutation=false"
  Write-SafeHost "runtime_current_evidence_acceptance_simulation=final_x_refused_for_simulation;state=e11_x_refused;classification=simulated_artifact_cannot_close_e11;simulation_can_mark_final_x=false;build=false;recreate=false;mutation=false"
  Write-SafeHost "runtime_current_evidence_acceptance_secret_safe_omission=true"
}

function Assert-RuntimeCurrentFinalClosureAuditContract {
  param([Parameter(Mandatory = $true)]$Handoff)

  $audit = Get-JsonProperty $Handoff "runtimeCurrentFinalClosureAudit" "UI runtime-current final closure audit"
  Assert-Equal (Get-JsonProperty $audit "schema" "UI runtime-current final closure audit") "billing_execute_browser_mutation_final_closure_audit.v1" "runtime-current final closure audit schema"

  $defaults = Get-JsonProperty $audit "defaults" "UI runtime-current final closure audit defaults"
  foreach ($name in @("buildsRuntime", "consumesAdminSession", "mutates", "readsBrowserArtifact", "readsRuntimeArtifact", "recreatesRuntime")) {
    Assert-True ((Get-JsonProperty $defaults $name "UI runtime-current final closure audit defaults") -eq $false) "runtime-current final closure audit must keep $name false by default"
  }

  Assert-StringSetEqual (Get-JsonStringArray (Get-JsonProperty $audit "requiredEvidence" "UI runtime-current final closure audit required evidence") "runtime-current final closure audit required evidence") @(
    "runtime_current_verified_artifact_readback",
    "admin_session_verified_secret_omitted_marker",
    "mutation_opt_in_enabled",
    "browser_mutation_artifact_write_readback",
    "api_readback_passed",
    "ledger_readback_passed",
    "numeric_durations_present",
    "secret_safe_omission_proof",
    "current_commit_freshness"
  ) "runtime-current final closure audit required evidence"

  $fields = Get-JsonProperty $audit "reportFields" "UI runtime-current final closure audit report fields"
  foreach ($name in @("apiReadbackState", "blockingReasons", "browserArtifactState", "currentCommit", "durationState", "finalXEligible", "generatedAt", "ledgerReadbackState", "mutationControlsState", "requiredEvidence", "runtimeArtifactState", "secretSafeOmissionState", "sessionState")) {
    $value = [string](Get-JsonProperty $fields $name "UI runtime-current final closure audit report fields")
    if ($value -notmatch '^[a-z0-9_]+$') {
      throw "runtime-current final closure audit report field '$name' must be machine readable"
    }
  }

  $commands = Get-JsonProperty $audit "exactNextCommands" "UI runtime-current final closure audit next commands"
  foreach ($name in @("runtimeCurrentHandoff", "runtimeCurrentReadback", "sessionMarker", "browserMutationRunnerArtifact", "browserMutationRunnerArtifactReadback")) {
    $command = [string](Get-JsonProperty $commands $name "UI runtime-current final closure audit next commands")
    Assert-SecretSafeContent -Content $command -Context "runtime-current final closure audit command $name"
    if (-not $command.Contains("scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1")) {
      throw "runtime-current final closure audit command '$name' must point at smoke script"
    }
  }
  if (-not ([string](Get-JsonProperty $commands "browserMutationRunnerArtifactReadback" "UI runtime-current final closure audit next commands")).Contains("-BrowserEvidenceArtifactReadbackOptIn")) {
    throw "runtime-current final closure audit browser readback command must include explicit readback opt-in"
  }

  $simulation = Get-JsonProperty $audit "simulationPolicy" "UI runtime-current final closure audit simulation policy"
  Assert-True ([bool](Get-JsonProperty $simulation "acceptedShapeSimulations" "UI runtime-current final closure audit simulation policy")) "runtime-current final closure audit must support accepted-shape simulations"
  Assert-True ((Get-JsonProperty $simulation "simulationCanMarkFinalX" "UI runtime-current final closure audit simulation policy") -eq $false) "runtime-current final closure audit simulation must not mark final x"
  foreach ($name in @("buildsRuntime", "mutates", "recreatesRuntime")) {
    Assert-True ((Get-JsonProperty $simulation $name "UI runtime-current final closure audit simulation policy") -eq $false) "runtime-current final closure audit simulation must not $name"
  }

  $states = Get-JsonProperty $audit "stateValues" "UI runtime-current final closure audit state values"
  Assert-StringSetEqual @(
    [string](Get-JsonProperty $states "accepted" "UI runtime-current final closure audit state values"),
    [string](Get-JsonProperty $states "blocked" "UI runtime-current final closure audit state values"),
    [string](Get-JsonProperty $states "missing" "UI runtime-current final closure audit state values"),
    [string](Get-JsonProperty $states "refused" "UI runtime-current final closure audit state values"),
    [string](Get-JsonProperty $states "simulated" "UI runtime-current final closure audit state values")
  ) @("accepted", "blocked", "missing", "refused", "simulated") "runtime-current final closure audit state values"
}

function New-RuntimeCurrentFinalClosureAuditReport {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [Parameter(Mandatory = $true)][bool]$RuntimeAccepted,
    [Parameter(Mandatory = $true)][bool]$SessionAccepted,
    [Parameter(Mandatory = $true)][bool]$MutationControlsAccepted,
    [Parameter(Mandatory = $true)][bool]$BrowserArtifactAccepted,
    [Parameter(Mandatory = $true)][bool]$ApiReadbackAccepted,
    [Parameter(Mandatory = $true)][bool]$LedgerReadbackAccepted,
    [Parameter(Mandatory = $true)][bool]$DurationsAccepted,
    [Parameter(Mandatory = $true)][bool]$SecretSafeAccepted,
    [Parameter(Mandatory = $true)][bool]$Simulated
  )

  $audit = Get-JsonProperty $Handoff "runtimeCurrentFinalClosureAudit" "UI runtime-current final closure audit"
  $requiredEvidence = Get-JsonStringArray (Get-JsonProperty $audit "requiredEvidence" "UI runtime-current final closure audit required evidence") "runtime-current final closure audit required evidence"
  $blockingReasons = @()
  if (-not $RuntimeAccepted) { $blockingReasons += "runtime_current_verified_artifact_missing" }
  if (-not $SessionAccepted) { $blockingReasons += "admin_session_marker_missing" }
  if (-not $MutationControlsAccepted) { $blockingReasons += "mutation_controls_missing" }
  if (-not $BrowserArtifactAccepted) { $blockingReasons += "browser_mutation_artifact_missing" }
  if (-not $ApiReadbackAccepted) { $blockingReasons += "api_readback_missing" }
  if (-not $LedgerReadbackAccepted) { $blockingReasons += "ledger_readback_missing" }
  if (-not $DurationsAccepted) { $blockingReasons += "duration_non_numeric_or_missing" }
  if (-not $SecretSafeAccepted) { $blockingReasons += "secret_safe_omission_missing" }
  if ($Simulated) { $blockingReasons += "simulated_artifact_cannot_close_e11" }

  $allAccepted = $RuntimeAccepted -and $SessionAccepted -and $MutationControlsAccepted -and $BrowserArtifactAccepted -and $ApiReadbackAccepted -and $LedgerReadbackAccepted -and $DurationsAccepted -and $SecretSafeAccepted
  $finalEligible = $allAccepted -and (-not $Simulated)

  return [PSCustomObject]@{
    schema = [string](Get-JsonProperty $audit "schema" "UI runtime-current final closure audit")
    generated_at = (Get-Date).ToUniversalTime().ToString("o")
    current_commit = Get-CurrentGitCommit
    final_x_eligible = $finalEligible
    simulation_can_mark_final_x = $false
    blocking_reasons = $blockingReasons
    required_evidence = $requiredEvidence
    runtime_artifact_state = if ($RuntimeAccepted) { "accepted" } else { "missing" }
    session_state = if ($SessionAccepted) { "accepted" } else { "missing" }
    mutation_controls_state = if ($MutationControlsAccepted) { "accepted" } else { "missing" }
    browser_artifact_state = if ($BrowserArtifactAccepted) { if ($Simulated) { "simulated" } else { "accepted" } } else { "missing" }
    api_readback_state = if ($ApiReadbackAccepted) { "accepted" } else { "missing" }
    ledger_readback_state = if ($LedgerReadbackAccepted) { "accepted" } else { "missing" }
    duration_state = if ($DurationsAccepted) { "accepted" } else { "missing" }
    secret_safe_omission_state = if ($SecretSafeAccepted) { "accepted" } else { "missing" }
    defaults = Get-JsonProperty $audit "defaults" "UI runtime-current final closure audit defaults"
    exact_next_commands = Get-JsonProperty $audit "exactNextCommands" "UI runtime-current final closure audit next commands"
  }
}

function Write-RuntimeCurrentFinalClosureAudit {
  param([Parameter(Mandatory = $true)]$Handoff)

  Assert-RuntimeCurrentFinalClosureAuditContract $Handoff
  $audit = Get-JsonProperty $Handoff "runtimeCurrentFinalClosureAudit" "UI runtime-current final closure audit"
  $commands = Get-JsonProperty $audit "exactNextCommands" "UI runtime-current final closure audit next commands"
  $currentReport = New-RuntimeCurrentFinalClosureAuditReport -Handoff $Handoff -RuntimeAccepted $false -SessionAccepted $false -MutationControlsAccepted $false -BrowserArtifactAccepted $false -ApiReadbackAccepted $false -LedgerReadbackAccepted $false -DurationsAccepted $false -SecretSafeAccepted $true -Simulated $false
  $acceptedShapeSimulation = New-RuntimeCurrentFinalClosureAuditReport -Handoff $Handoff -RuntimeAccepted $true -SessionAccepted $true -MutationControlsAccepted $true -BrowserArtifactAccepted $true -ApiReadbackAccepted $true -LedgerReadbackAccepted $true -DurationsAccepted $true -SecretSafeAccepted $true -Simulated $true

  Assert-True ((Get-JsonProperty $currentReport "final_x_eligible" "current final closure audit") -eq $false) "current closure audit must be blocked without real runtime/session/browser artifact"
  Assert-True ((Get-JsonProperty $acceptedShapeSimulation "final_x_eligible" "simulation final closure audit") -eq $false) "accepted-shape simulation must not mark final x"

  Write-SafeHost "Browser mutation final closure audit:"
  Write-SafeHost "browser_mutation_final_closure_audit_schema=$([string](Get-JsonProperty $audit "schema" "UI runtime-current final closure audit"))"
  Write-SafeHost "browser_mutation_final_closure_audit_final_x_eligible=false"
  Write-SafeHost "browser_mutation_final_closure_audit_current_commit=$([string]$currentReport.current_commit)"
  Write-SafeHost "browser_mutation_final_closure_audit_generated_at=$([string]$currentReport.generated_at)"
  foreach ($item in Get-JsonStringArray (Get-JsonProperty $audit "requiredEvidence" "UI runtime-current final closure audit required evidence") "runtime-current final closure audit required evidence") {
    Write-SafeHost "browser_mutation_final_closure_audit_required_evidence=$item"
  }
  foreach ($reason in $currentReport.blocking_reasons) {
    Write-SafeHost "browser_mutation_final_closure_audit_blocking_reason=$reason"
  }
  foreach ($name in @("runtime_artifact_state", "session_state", "mutation_controls_state", "browser_artifact_state", "api_readback_state", "ledger_readback_state", "duration_state", "secret_safe_omission_state")) {
    Write-SafeHost "browser_mutation_final_closure_audit_state=$name|$([string]$currentReport.$name)"
  }
  foreach ($name in @("runtimeCurrentHandoff", "runtimeCurrentReadback", "sessionMarker", "browserMutationRunnerArtifact", "browserMutationRunnerArtifactReadback")) {
    Write-SafeHost "browser_mutation_final_closure_audit_next_command=$name|$([string](Get-JsonProperty $commands $name "runtime-current final closure audit next commands"))"
  }
  Write-SafeHost "browser_mutation_final_closure_audit_defaults=build:false;recreate:false;mutation:false;reads_secret|false;reads_runtime_artifact:false;reads_browser_artifact:false"
  Write-SafeHost "browser_mutation_final_closure_audit_simulation=accepted_shape;final_x_eligible=false;simulation_can_mark_final_x=false;blocking_reason=simulated_artifact_cannot_close_e11"
  Write-SafeHost "browser_mutation_final_closure_audit_report_json=$(($currentReport | ConvertTo-Json -Depth 32 -Compress))"
}

function Assert-BrowserMutationEvidenceWatcherFinalGuardContract {
  param([Parameter(Mandatory = $true)]$Handoff)

  $watcher = Get-JsonProperty $Handoff "browserMutationEvidenceWatcherFinalGuard" "UI browser mutation evidence watcher final guard"
  Assert-Equal (Get-JsonProperty $watcher "schema" "UI browser mutation evidence watcher final guard") "billing_execute_browser_mutation_evidence_watcher_final_guard.v1" "browser mutation evidence watcher schema"
  Assert-Equal (Get-JsonProperty $watcher "defaultMode" "UI browser mutation evidence watcher final guard") "watcher_final_guard_review" "browser mutation evidence watcher mode"

  $defaults = Get-JsonProperty $watcher "defaults" "UI browser mutation evidence watcher defaults"
  foreach ($name in @("buildsRuntime", "consumesAdminSession", "mutates", "readsBrowserArtifact", "readsRuntimeArtifact", "recreatesRuntime")) {
    Assert-True ((Get-JsonProperty $defaults $name "UI browser mutation evidence watcher defaults") -eq $false) "browser mutation evidence watcher must keep $name false"
  }

  $paths = Get-JsonProperty $watcher "expectedArtifactPaths" "UI browser mutation evidence watcher artifact paths"
  Assert-Equal (Get-JsonProperty $paths "runtimeCurrentArtifact" "UI browser mutation evidence watcher artifact paths") "artifacts/control_plane_ledger_execute_runtime_current_handoff.json" "watcher runtime-current artifact path"
  Assert-Equal (Get-JsonProperty $paths "browserMutationArtifact" "UI browser mutation evidence watcher artifact paths") "artifacts/billing_execute_browser_live_e2e_evidence.json" "watcher browser artifact path"

  $session = Get-JsonProperty $watcher "sessionMarkerRequirements" "UI browser mutation evidence watcher session requirements"
  Assert-Equal (Get-JsonProperty $session "env" "UI browser mutation evidence watcher session requirements") "CONTROL_PLANE_ADMIN_SESSION_TOKEN" "watcher session env"
  Assert-Equal (Get-JsonProperty $session "marker" "UI browser mutation evidence watcher session requirements") "admin_session_verified_secret_omitted" "watcher session marker"
  Assert-True ((Get-JsonProperty $session "rawSecretEchoed" "UI browser mutation evidence watcher session requirements") -eq $false) "watcher session marker must not echo raw secret"

  $mutation = Get-JsonProperty $watcher "mutationOptInRequirements" "UI browser mutation evidence watcher mutation requirements"
  Assert-Equal (Get-JsonProperty $mutation "env" "UI browser mutation evidence watcher mutation requirements") "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_MUTATION=1" "watcher mutation env"
  Assert-Equal (Get-JsonProperty $mutation "artifactWriteFlag" "UI browser mutation evidence watcher mutation requirements") "-BrowserEvidenceArtifactWriteOptIn" "watcher artifact write flag"
  Assert-Equal (Get-JsonProperty $mutation "artifactReadbackFlag" "UI browser mutation evidence watcher mutation requirements") "-BrowserEvidenceArtifactReadbackOptIn" "watcher artifact readback flag"
  Assert-Equal (Get-JsonProperty $mutation "runnerFlag" "UI browser mutation evidence watcher mutation requirements") "-BrowserLiveRunnerExecutionOptIn" "watcher runner flag"

  $commands = Get-JsonProperty $watcher "exactNextCommands" "UI browser mutation evidence watcher commands"
  foreach ($name in @("runtimeCurrentHandoff", "runtimeCurrentReadback", "sessionMarker", "browserMutationRunner", "browserArtifactReadback")) {
    $command = [string](Get-JsonProperty $commands $name "UI browser mutation evidence watcher commands")
    Assert-SecretSafeContent -Content $command -Context "browser mutation evidence watcher command $name"
    if (-not $command.Contains("scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1")) {
      throw "browser mutation evidence watcher command '$name' must point at smoke script"
    }
  }

  $flags = Get-JsonProperty $watcher "finalGuardFlags" "UI browser mutation evidence watcher final guard flags"
  foreach ($name in @("acceptedShapeCanMarkFinalX", "noArtifactCanMarkFinalX", "sessionMissingCanMarkFinalX", "simulationCanMarkFinalX", "watcherCanMarkFinalX")) {
    Assert-True ((Get-JsonProperty $flags $name "UI browser mutation evidence watcher final guard flags") -eq $false) "watcher final guard must keep $name false"
  }

  $checklist = Get-JsonProperty $watcher "finalReviewChecklist" "UI browser mutation evidence watcher final checklist"
  $checklistKeys = @()
  foreach ($item in $checklist) {
    $key = [string](Get-JsonProperty $item "key" "UI browser mutation evidence watcher checklist item")
    $requiredState = [string](Get-JsonProperty $item "requiredState" "UI browser mutation evidence watcher checklist item")
    if ($key -notmatch '^[a-z0-9_]+$' -or $requiredState -notmatch '^[a-z0-9_]+$') {
      throw "watcher final review checklist item must be machine readable"
    }
    $checklistKeys += $key
  }
  Assert-StringSetEqual $checklistKeys @("runtime_current_artifact_current", "admin_session_marker_secret_omitted", "mutation_opt_in_present", "browser_artifact_readback_passed", "api_and_ledger_readback_passed", "numeric_durations_present", "secret_safe_omission_proven", "not_simulation_or_watcher_only") "watcher final review checklist keys"

  $states = Get-JsonProperty $watcher "watcherStates" "UI browser mutation evidence watcher states"
  Assert-Equal (Get-JsonProperty $states "blocked" "UI browser mutation evidence watcher states") "blocked" "watcher blocked state"
  Assert-Equal (Get-JsonProperty $states "waitingForRealEvidence" "UI browser mutation evidence watcher states") "waiting_for_real_evidence" "watcher waiting state"
  Assert-Equal (Get-JsonProperty $states "finalEligible" "UI browser mutation evidence watcher states") "final_eligible" "watcher final eligible state"
}

function Write-BrowserMutationEvidenceWatcherFinalGuard {
  param([Parameter(Mandatory = $true)]$Handoff)

  Assert-BrowserMutationEvidenceWatcherFinalGuardContract $Handoff
  $watcher = Get-JsonProperty $Handoff "browserMutationEvidenceWatcherFinalGuard" "UI browser mutation evidence watcher final guard"
  $paths = Get-JsonProperty $watcher "expectedArtifactPaths" "UI browser mutation evidence watcher artifact paths"
  $commands = Get-JsonProperty $watcher "exactNextCommands" "UI browser mutation evidence watcher commands"
  $flags = Get-JsonProperty $watcher "finalGuardFlags" "UI browser mutation evidence watcher final guard flags"
  $session = Get-JsonProperty $watcher "sessionMarkerRequirements" "UI browser mutation evidence watcher session requirements"
  $mutation = Get-JsonProperty $watcher "mutationOptInRequirements" "UI browser mutation evidence watcher mutation requirements"

  Write-SafeHost "Browser mutation evidence watcher final guard:"
  Write-SafeHost "browser_mutation_evidence_watcher_schema=$([string](Get-JsonProperty $watcher "schema" "UI browser mutation evidence watcher final guard"))"
  Write-SafeHost "browser_mutation_evidence_watcher_state=blocked"
  Write-SafeHost "browser_mutation_evidence_watcher_final_x_eligible=false"
  Write-SafeHost "browser_mutation_evidence_watcher_expected_path=runtimeCurrentArtifact|$([string](Get-JsonProperty $paths "runtimeCurrentArtifact" "watcher artifact paths"))"
  Write-SafeHost "browser_mutation_evidence_watcher_expected_path=browserMutationArtifact|$([string](Get-JsonProperty $paths "browserMutationArtifact" "watcher artifact paths"))"
  Write-SafeHost "browser_mutation_evidence_watcher_session_marker=$([string](Get-JsonProperty $session "marker" "watcher session marker"))"
  Write-SafeHost "browser_mutation_evidence_watcher_session_env=$([string](Get-JsonProperty $session "env" "watcher session marker"))"
  Write-SafeHost "browser_mutation_evidence_watcher_session_raw_secret_echoed=false"
  Write-SafeHost "browser_mutation_evidence_watcher_mutation_env=$([string](Get-JsonProperty $mutation "env" "watcher mutation requirements"))"
  Write-SafeHost "browser_mutation_evidence_watcher_mutation_flag=$([string](Get-JsonProperty $mutation "artifactWriteFlag" "watcher mutation requirements"))"
  Write-SafeHost "browser_mutation_evidence_watcher_mutation_flag=$([string](Get-JsonProperty $mutation "artifactReadbackFlag" "watcher mutation requirements"))"
  Write-SafeHost "browser_mutation_evidence_watcher_mutation_flag=$([string](Get-JsonProperty $mutation "runnerFlag" "watcher mutation requirements"))"
  foreach ($name in @("runtimeCurrentHandoff", "runtimeCurrentReadback", "sessionMarker", "browserMutationRunner", "browserArtifactReadback")) {
    Write-SafeHost "browser_mutation_evidence_watcher_next_command=$name|$([string](Get-JsonProperty $commands $name "watcher commands"))"
  }
  foreach ($item in Get-JsonProperty $watcher "finalReviewChecklist" "watcher final review checklist") {
    Write-SafeHost "browser_mutation_evidence_watcher_final_review=$([string](Get-JsonProperty $item "key" "watcher checklist item"))|$([string](Get-JsonProperty $item "requiredState" "watcher checklist item"))"
  }
  foreach ($name in @("simulationCanMarkFinalX", "acceptedShapeCanMarkFinalX", "watcherCanMarkFinalX", "noArtifactCanMarkFinalX", "sessionMissingCanMarkFinalX")) {
    Write-SafeHost "browser_mutation_evidence_watcher_final_guard=$name|$([string](Get-JsonProperty $flags $name "watcher final guard flags"))"
  }
  Write-SafeHost "browser_mutation_evidence_watcher_blocking_reason=runtime_current_verified_artifact_missing"
  Write-SafeHost "browser_mutation_evidence_watcher_blocking_reason=admin_session_marker_missing"
  Write-SafeHost "browser_mutation_evidence_watcher_blocking_reason=browser_mutation_artifact_missing"
  Write-SafeHost "browser_mutation_evidence_watcher_defaults=build:false;recreate:false;mutation:false;reads_session|false;reads_runtime_artifact:false;reads_browser_artifact:false"
}

function Assert-BrowserLiveRunnerExecutionBridgeContract {
  param([Parameter(Mandatory = $true)]$Handoff)

  $bridge = Get-JsonProperty $Handoff "browserLiveRunnerExecutionBridge" "UI handoff"
  Assert-Equal (Get-JsonProperty $bridge "defaultMode" "UI browser live runner bridge") "live_runner_execution_bridge" "UI browser live runner bridge default mode"
  Assert-True ((Get-JsonProperty $bridge "defaultRunsBridge" "UI browser live runner bridge") -eq $false) "UI browser live runner must not run by default"
  Assert-True ((Get-JsonProperty $bridge "defaultClicksAdminUiActions" "UI browser live runner bridge") -eq $false) "UI browser live runner must not click by default"
  Assert-True ((Get-JsonProperty $bridge "defaultSubmitsLiveMutation" "UI browser live runner bridge") -eq $false) "UI browser live runner must not mutate by default"

  $command = Get-JsonProperty $bridge "command" "UI browser live runner bridge"
  Assert-Equal (Get-JsonProperty $command "script" "UI browser live runner command") "scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1" "UI browser live runner command script"
  Assert-Equal (Get-JsonProperty $command "flag" "UI browser live runner command") "-BrowserLiveRunnerExecutionOptIn" "UI browser live runner command flag"

  $artifact = Get-JsonProperty $bridge "artifact" "UI browser live runner bridge"
  Assert-Equal (Get-JsonProperty $artifact "name" "UI browser live runner artifact") "billing_execute_browser_live_e2e_evidence.v1" "UI browser live runner artifact name"
  Assert-Equal (Get-JsonProperty $artifact "defaultPath" "UI browser live runner artifact") "artifacts/billing_execute_browser_live_e2e_evidence.json" "UI browser live runner artifact default path"
  Assert-Equal (Get-JsonProperty $artifact "pathEnv" "UI browser live runner artifact") "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_ARTIFACT_PATH" "UI browser live runner artifact path env"
  Assert-Equal (Get-JsonProperty $artifact "writeOptInFlag" "UI browser live runner artifact") "-BrowserEvidenceArtifactWriteOptIn" "UI browser live runner artifact write flag"
  Assert-True ([bool](Get-JsonProperty $artifact "readBackRequired" "UI browser live runner artifact")) "UI browser live runner artifact readback must be required"
  [void](Resolve-BoundedEvidenceArtifactPath ([string](Get-JsonProperty $artifact "defaultPath" "UI browser live runner artifact")))

  $required = Get-JsonProperty $bridge "requiredForBridge" "UI browser live runner bridge"
  foreach ($name in @("adminUiReachable", "artifactWriteOptIn", "browserToolingAvailable", "controlPlaneHealthReachable", "liveRunnerOptIn", "mutationOptIn", "sessionMaterialPresent")) {
    Assert-True ([bool](Get-JsonProperty $required $name "UI browser live runner requirements")) "UI browser live runner must require $name"
  }

  $durationFields = Get-JsonProperty $bridge "durationFields" "UI browser live runner bridge"
  foreach ($name in @("browserLaunchDurationMs", "contextSetupDurationMs", "dryRunPlanDurationMs", "executeApplyDurationMs", "idempotentReplayDurationMs", "ledgerRefreshDurationMs", "pageReadyDurationMs", "refundRefusalDurationMs", "selectorSnapshotDurationMs", "serviceReadinessDurationMs", "submitLatencyMs")) {
    [void](Get-JsonProperty $durationFields $name "UI browser live runner duration fields")
  }

  $secretSafeOmission = Get-JsonProperty $bridge "secretSafeOmission" "UI browser live runner bridge"
  foreach ($name in @("echoRequestMaterial", "echoSessionMaterial", "echoUrlCredentials")) {
    Assert-True ((Get-JsonProperty $secretSafeOmission $name "UI browser live runner secret-safe omission") -eq $false) "UI browser live runner must omit $name"
  }
}

function Write-BrowserLiveRunnerExecutionBridgeGate {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [Parameter(Mandatory = $true)][string]$ToolingStatus,
    [Parameter(Mandatory = $true)]$AdminUiProbe,
    [Parameter(Mandatory = $true)]$ControlPlaneProbe,
    [Parameter(Mandatory = $true)][bool]$MutationEnabled,
    [Parameter(Mandatory = $true)][bool]$SessionMaterialPresent
  )

  Assert-BrowserLiveRunnerExecutionBridgeContract $Handoff
  $bridge = Get-JsonProperty $Handoff "browserLiveRunnerExecutionBridge" "UI handoff"
  $command = Get-JsonProperty $bridge "command" "UI browser live runner bridge"
  $artifact = Get-JsonProperty $bridge "artifact" "UI browser live runner bridge"
  $durationFields = Get-JsonProperty $bridge "durationFields" "UI browser live runner bridge"
  $statusMarkers = Get-JsonProperty $bridge "statusMarkers" "UI browser live runner bridge"
  $writeEnabled = Test-BrowserEvidenceArtifactWriteOptIn $Handoff
  $artifactPath = Resolve-BoundedEvidenceArtifactPath $BrowserEvidenceArtifactPath
  $adminUiUrl = Get-SafeSmokeUrlSummary $AdminUiBaseUrl "Admin UI URL"
  $backendUrl = Get-SafeSmokeUrlSummary $ControlPlaneBaseUrl "Control Plane backend URL"
  $blockers = @()
  if (-not $BrowserLiveRunnerExecutionOptIn) { $blockers += "live_runner_opt_in_missing" }
  if ($ToolingStatus -ne "available") { $blockers += "browser_tooling_unavailable" }
  if (-not [bool]$AdminUiProbe.Reachable) { $blockers += "admin_ui_unreachable" }
  if (-not [bool]$ControlPlaneProbe.Reachable) { $blockers += "control_plane_health_unreachable" }
  if (-not $SessionMaterialPresent) { $blockers += "session_material_missing" }
  if (-not $MutationEnabled) { $blockers += "live_mutation_opt_in_missing" }
  if (-not $writeEnabled) { $blockers += "artifact_write_opt_in_missing" }
  $bridgeAllowed = $blockers.Count -eq 0
  $status = if ($bridgeAllowed) { [string](Get-JsonProperty $statusMarkers "bridgeAllowed" "UI browser live runner status") } else { [string](Get-JsonProperty $statusMarkers "blocked" "UI browser live runner status") }
  $blockerSummary = if ($blockers.Count -gt 0) { $blockers -join "+" } else { "none" }
  $scriptPath = [string](Get-JsonProperty $command "script" "UI browser live runner command")
  $runnerFlag = [string](Get-JsonProperty $command "flag" "UI browser live runner command")
  $writeFlag = [string](Get-JsonProperty $artifact "writeOptInFlag" "UI browser live runner artifact")
  $exactCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath -BrowserPreflight -BrowserMutationOptIn $writeFlag $runnerFlag -BrowserEvidenceArtifactPath $([string](Get-JsonProperty $artifact "defaultPath" "UI browser live runner artifact"))"

  Write-SafeHost "Browser ledger execute live runner execution bridge:"
  Write-SafeHost "browser_live_runner_bridge_status=$status"
  Write-SafeHost "browser_live_runner_bridge_allowed=$(Format-BoolMarker $bridgeAllowed)"
  Write-SafeHost "browser_live_runner_bridge_default_runs=false"
  Write-SafeHost "browser_live_runner_bridge_default_clicks=false"
  Write-SafeHost "browser_live_runner_bridge_default_mutation=false"
  Write-SafeHost "browser_live_runner_bridge_exact_command=$exactCommand"
  Write-SafeHost "browser_live_runner_bridge_blockers=$blockerSummary"
  Write-SafeHost "browser_live_runner_bridge_admin_ui_origin=$adminUiUrl"
  Write-SafeHost "browser_live_runner_bridge_control_plane_origin=$backendUrl"
  Write-SafeHost "browser_live_runner_bridge_session_material_echoed=false"
  Write-SafeHost "browser_live_runner_bridge_request_material_echoed=false"
  Write-SafeHost "browser_live_runner_bridge_url_credentials_echoed=false"
  Write-SafeHost "browser_live_runner_bridge_artifact_name=$([string](Get-JsonProperty $artifact "name" "UI browser live runner artifact"))"
  Write-SafeHost "browser_live_runner_bridge_artifact_path_bounded=true"
  Write-SafeHost "browser_live_runner_bridge_artifact_path=$artifactPath"
  Write-SafeHost "browser_live_runner_bridge_artifact_write_enabled=$(Format-BoolMarker $writeEnabled)"
  Write-SafeHost "browser_live_runner_bridge_artifact_readback_required=$(Format-BoolMarker ([bool](Get-JsonProperty $artifact "readBackRequired" "UI browser live runner artifact")))"
  foreach ($name in @("serviceReadinessDurationMs", "browserLaunchDurationMs", "contextSetupDurationMs", "pageReadyDurationMs", "selectorSnapshotDurationMs", "submitLatencyMs", "dryRunPlanDurationMs", "executeApplyDurationMs", "idempotentReplayDurationMs", "refundRefusalDurationMs", "ledgerRefreshDurationMs")) {
    Write-SafeHost "browser_live_runner_bridge_duration_name=$([string](Get-JsonProperty $durationFields $name "UI browser live runner duration fields"))"
  }
}

function Assert-BrowserLivePassArtifactReadbackGateContract {
  param([Parameter(Mandatory = $true)]$Handoff)

  $gate = Get-JsonProperty $Handoff "browserLivePassArtifactReadbackGate" "UI handoff"
  Assert-Equal (Get-JsonProperty $gate "artifactName" "UI browser live pass artifact readback gate") "billing_execute_browser_live_e2e_evidence.v1" "UI browser readback gate artifact name"
  Assert-Equal (Get-JsonProperty $gate "defaultMode" "UI browser live pass artifact readback gate") "live_pass_artifact_readback_gate" "UI browser readback gate default mode"
  Assert-True ((Get-JsonProperty $gate "defaultReadsArtifact" "UI browser live pass artifact readback gate") -eq $false) "UI browser readback gate must not read artifact by default"
  Assert-True ((Get-JsonProperty $gate "defaultSubmitsLiveMutation" "UI browser live pass artifact readback gate") -eq $false) "UI browser readback gate must not mutate by default"

  $statusMarkers = Get-JsonProperty $gate "statusMarkers" "UI browser live pass artifact readback gate"
  foreach ($name in @("blocked", "fail", "pass")) {
    $marker = [string](Get-JsonProperty $statusMarkers $name "UI browser readback gate status markers")
    if ($marker -notmatch '^[a-z0-9_]+$') {
      throw "UI browser readback gate status marker '$name' must be machine readable"
    }
  }

  $classificationValues = Get-JsonProperty $gate "classificationValues" "UI browser live pass artifact readback gate"
  foreach ($name in @("failed", "missing", "notRequested", "passed")) {
    $classification = [string](Get-JsonProperty $classificationValues $name "UI browser readback gate classifications")
    if ($classification -notmatch '^[a-z0-9_]+$') {
      throw "UI browser readback gate classification '$name' must be machine readable"
    }
  }

  $expectedActionOutcomes = Get-JsonProperty $gate "expectedActionOutcomes" "UI browser live pass artifact readback gate"
  foreach ($name in @("dry_run_plan", "execute_apply", "idempotent_replay", "refund_refusal", "ledger_refresh")) {
    [void](Get-JsonProperty $expectedActionOutcomes $name "UI browser readback gate action outcomes")
  }

  $durationFields = Get-JsonProperty $gate "durationFields" "UI browser live pass artifact readback gate"
  foreach ($name in @("browserLaunchDurationMs", "contextSetupDurationMs", "dryRunPlanDurationMs", "executeApplyDurationMs", "idempotentReplayDurationMs", "ledgerRefreshDurationMs", "pageReadyDurationMs", "refundRefusalDurationMs", "selectorSnapshotDurationMs", "serviceReadinessDurationMs", "submitLatencyMs")) {
    [void](Get-JsonProperty $durationFields $name "UI browser readback gate duration fields")
  }

  $secretSafeOmission = Get-JsonProperty $gate "secretSafeOmission" "UI browser live pass artifact readback gate"
  foreach ($name in @("echoRequestMaterial", "echoSessionMaterial", "echoUrlCredentials")) {
    Assert-True ((Get-JsonProperty $secretSafeOmission $name "UI browser readback gate secret-safe omission") -eq $false) "UI browser readback gate must omit $name"
  }
}

function Get-BrowserLivePassArtifactReadbackState {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [AllowNull()]$Artifact,
    [Parameter(Mandatory = $true)][bool]$ReadbackAvailable
  )

  if (-not $ReadbackAvailable -or $null -eq $Artifact) {
    return "blocked"
  }
  if (Test-BrowserMutationPassArtifactClosure -Handoff $Handoff -Artifact $Artifact) {
    return "pass"
  }
  return "fail"
}

function Get-BrowserLivePassArtifactReadbackClassification {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [AllowNull()]$Artifact,
    [Parameter(Mandatory = $true)][bool]$ReadbackRequested,
    [Parameter(Mandatory = $true)][bool]$ReadbackAvailable
  )

  $gate = Get-JsonProperty $Handoff "browserLivePassArtifactReadbackGate" "UI handoff"
  $classificationValues = Get-JsonProperty $gate "classificationValues" "UI browser live pass artifact readback gate"
  if (-not $ReadbackRequested) {
    return [string](Get-JsonProperty $classificationValues "notRequested" "UI browser readback gate classifications")
  }
  if (-not $ReadbackAvailable -or $null -eq $Artifact) {
    return [string](Get-JsonProperty $classificationValues "missing" "UI browser readback gate classifications")
  }
  if (Test-BrowserMutationPassArtifactClosure -Handoff $Handoff -Artifact $Artifact) {
    return [string](Get-JsonProperty $classificationValues "passed" "UI browser readback gate classifications")
  }
  return [string](Get-JsonProperty $classificationValues "failed" "UI browser readback gate classifications")
}

function Write-BrowserLivePassArtifactReadbackGate {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [Parameter(Mandatory = $true)][bool]$MutationEnabled,
    [Parameter(Mandatory = $true)][bool]$SessionMaterialPresent
  )

  Assert-BrowserLivePassArtifactReadbackGateContract $Handoff
  $gate = Get-JsonProperty $Handoff "browserLivePassArtifactReadbackGate" "UI handoff"
  $statusMarkers = Get-JsonProperty $gate "statusMarkers" "UI browser live pass artifact readback gate"
  $writeEnabled = Test-BrowserEvidenceArtifactWriteOptIn $Handoff
  $artifactPath = Resolve-BoundedEvidenceArtifactPath $BrowserEvidenceArtifactPath
  $readbackArtifact = $null
  $readbackAvailable = $false
  if ($BrowserEvidenceArtifactReadbackOptIn -and (Test-Path $artifactPath)) {
    $readbackArtifact = Read-JsonFile $artifactPath
    $readbackAvailable = $true
  }

  $probe = [PSCustomObject]@{ Reachable = $true }
  $syntheticPass = New-BrowserEvidenceArtifact -Handoff $Handoff -Outcome "passed" -Blockers @() -ToolingStatus "available" -AdminUiProbe $probe -ControlPlaneProbe $probe -MutationEnabled $true -SessionMaterialPresent $true -ServiceReadinessDurationMs 1
  Set-SyntheticPassActionEvidence -Handoff $Handoff -Artifact $syntheticPass
  $syntheticFail = New-BrowserEvidenceArtifact -Handoff $Handoff -Outcome "passed" -Blockers @() -ToolingStatus "available" -AdminUiProbe $probe -ControlPlaneProbe $probe -MutationEnabled $true -SessionMaterialPresent $true -ServiceReadinessDurationMs 1
  Set-SyntheticPassActionEvidence -Handoff $Handoff -Artifact $syntheticFail
  $syntheticFail.actions[0].duration_ms = "unavailable"
  Assert-Equal (Get-BrowserLivePassArtifactReadbackState -Handoff $Handoff -Artifact $null -ReadbackAvailable $false) "blocked" "browser readback gate missing artifact state"
  Assert-Equal (Get-BrowserLivePassArtifactReadbackState -Handoff $Handoff -Artifact $syntheticPass -ReadbackAvailable $true) "pass" "browser readback gate synthetic pass state"
  Assert-Equal (Get-BrowserLivePassArtifactReadbackState -Handoff $Handoff -Artifact $syntheticFail -ReadbackAvailable $true) "fail" "browser readback gate synthetic fail state"
  Assert-Equal (Get-BrowserLivePassArtifactReadbackClassification -Handoff $Handoff -Artifact $null -ReadbackRequested $false -ReadbackAvailable $false) "artifact_readback_not_requested" "browser readback gate not-requested classification"
  Assert-Equal (Get-BrowserLivePassArtifactReadbackClassification -Handoff $Handoff -Artifact $null -ReadbackRequested $true -ReadbackAvailable $false) "artifact_readback_missing" "browser readback gate missing classification"
  Assert-Equal (Get-BrowserLivePassArtifactReadbackClassification -Handoff $Handoff -Artifact $syntheticPass -ReadbackRequested $true -ReadbackAvailable $true) "artifact_readback_passed" "browser readback gate pass classification"
  Assert-Equal (Get-BrowserLivePassArtifactReadbackClassification -Handoff $Handoff -Artifact $syntheticFail -ReadbackRequested $true -ReadbackAvailable $true) "artifact_readback_failed" "browser readback gate fail classification"

  $state = Get-BrowserLivePassArtifactReadbackState -Handoff $Handoff -Artifact $readbackArtifact -ReadbackAvailable $readbackAvailable
  $classification = Get-BrowserLivePassArtifactReadbackClassification -Handoff $Handoff -Artifact $readbackArtifact -ReadbackRequested $BrowserEvidenceArtifactReadbackOptIn -ReadbackAvailable $readbackAvailable
  $status = [string](Get-JsonProperty $statusMarkers $state "UI browser readback gate status markers")
  $blockers = @()
  if (-not $writeEnabled) { $blockers += "artifact_write_opt_in_missing" }
  if ($BrowserEvidenceArtifactReadbackOptIn -and -not $readbackAvailable) { $blockers += "artifact_readback_missing" }
  if (-not $MutationEnabled) { $blockers += "live_mutation_opt_in_missing" }
  if (-not $SessionMaterialPresent) { $blockers += "session_material_missing" }
  if ($state -eq "fail") { $blockers += "artifact_closure_failed" }
  $blockerSummary = if ($blockers.Count -gt 0) { $blockers -join "+" } else { "none" }

  Write-SafeHost "Browser ledger execute live pass artifact readback gate:"
  Write-SafeHost "browser_live_pass_readback_status=$status"
  Write-SafeHost "browser_live_pass_readback_state=$state"
  Write-SafeHost "browser_live_pass_readback_classification=$classification"
  Write-SafeHost "browser_live_pass_readback_blockers=$blockerSummary"
  Write-SafeHost "browser_live_pass_readback_default_reads=false"
  Write-SafeHost "browser_live_pass_readback_default_mutation=false"
  Write-SafeHost "browser_live_pass_readback_artifact_path_bounded=true"
  Write-SafeHost "browser_live_pass_readback_artifact_path=$artifactPath"
  Write-SafeHost "browser_live_pass_readback_available=$(Format-BoolMarker $readbackAvailable)"
  Write-SafeHost "browser_live_pass_readback_write_enabled=$(Format-BoolMarker $writeEnabled)"
  Write-SafeHost "browser_live_pass_readback_session_present=$(Format-BoolMarker $SessionMaterialPresent)"
  Write-SafeHost "browser_live_pass_readback_mutation_enabled=$(Format-BoolMarker $MutationEnabled)"
  Write-SafeHost "browser_live_pass_readback_secret_url_credentials_echoed=false"
  Write-SafeHost "browser_live_pass_readback_secret_session_echoed=false"
  Write-SafeHost "browser_live_pass_readback_request_material_echoed=false"
}

function Assert-BrowserLiveEnvironmentBootstrapAttemptContract {
  param([Parameter(Mandatory = $true)]$Handoff)

  $attempt = Get-JsonProperty $Handoff "browserLiveEnvironmentBootstrapAttempt" "UI handoff"
  Assert-Equal (Get-JsonProperty $attempt "artifactName" "UI browser live environment bootstrap attempt") "billing_execute_browser_live_e2e_evidence.v1" "UI browser bootstrap artifact name"
  Assert-Equal (Get-JsonProperty $attempt "defaultMode" "UI browser live environment bootstrap attempt") "live_environment_bootstrap_attempt" "UI browser bootstrap default mode"
  Assert-True ((Get-JsonProperty $attempt "defaultInstallsBrowser" "UI browser live environment bootstrap attempt") -eq $false) "UI browser bootstrap must not install browser by default"
  Assert-True ((Get-JsonProperty $attempt "defaultStartsAdminUiDevServer" "UI browser live environment bootstrap attempt") -eq $false) "UI browser bootstrap must not start Admin UI by default"
  Assert-True ((Get-JsonProperty $attempt "defaultSubmitsLiveMutation" "UI browser live environment bootstrap attempt") -eq $false) "UI browser bootstrap must not mutate by default"

  $devServer = Get-JsonProperty $attempt "devServer" "UI browser live environment bootstrap attempt"
  Assert-Equal (Get-JsonProperty $devServer "cwd" "UI browser bootstrap dev server") "web/admin-ui" "UI browser bootstrap dev server cwd"
  Assert-Equal (Get-JsonProperty $devServer "env" "UI browser bootstrap dev server") "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_ADMIN_UI_DEV_SERVER" "UI browser bootstrap dev server env"
  Assert-Equal (Get-JsonProperty $devServer "flag" "UI browser bootstrap dev server") "-BrowserAdminUiDevServerOptIn" "UI browser bootstrap dev server flag"
  Assert-Equal (Get-JsonProperty $devServer "requiredValue" "UI browser bootstrap dev server") "1" "UI browser bootstrap dev server value"

  $playwright = Get-JsonProperty $attempt "playwright" "UI browser live environment bootstrap attempt"
  Assert-Equal (Get-JsonProperty $playwright "browser" "UI browser bootstrap Playwright") "chromium" "UI browser bootstrap Playwright browser"
  Assert-True ([bool](Get-JsonProperty $playwright "installHintOnly" "UI browser bootstrap Playwright")) "UI browser bootstrap must only hint browser install"

  $sessionHandoff = Get-JsonProperty $attempt "sessionHandoff" "UI browser live environment bootstrap attempt"
  Assert-Equal (Get-JsonProperty $sessionHandoff "env" "UI browser bootstrap session handoff") "CONTROL_PLANE_ADMIN_SESSION_TOKEN" "UI browser bootstrap session env"
  Assert-Equal (Get-JsonProperty $sessionHandoff "header" "UI browser bootstrap session handoff") "X-Admin-Session" "UI browser bootstrap session header"
  Assert-True ([bool](Get-JsonProperty $sessionHandoff "requiredForActions" "UI browser bootstrap session handoff")) "UI browser bootstrap must require session handoff for actions"
  foreach ($name in @("echoCookie", "echoHeaderValue", "echoToken")) {
    Assert-True ((Get-JsonProperty $sessionHandoff $name "UI browser bootstrap session handoff") -eq $false) "UI browser bootstrap session handoff must not echo $name"
  }

  $required = Get-JsonProperty $attempt "requiredForPassAttempt" "UI browser live environment bootstrap attempt"
  foreach ($name in @("adminUiReachable", "artifactReadbackFresh", "artifactWriteOptIn", "browserToolingAvailable", "controlPlaneHealthReachable", "liveRunnerOptIn", "mutationOptIn", "sessionMaterialPresent")) {
    Assert-True ([bool](Get-JsonProperty $required $name "UI browser bootstrap pass requirements")) "UI browser bootstrap pass attempt must require $name"
  }

  $durationFields = Get-JsonProperty $attempt "durationFields" "UI browser live environment bootstrap attempt"
  foreach ($name in @("browserLaunchDurationMs", "contextSetupDurationMs", "dryRunPlanDurationMs", "executeApplyDurationMs", "idempotentReplayDurationMs", "ledgerRefreshDurationMs", "pageReadyDurationMs", "refundRefusalDurationMs", "selectorSnapshotDurationMs", "serviceReadinessDurationMs", "submitLatencyMs")) {
    [void](Get-JsonProperty $durationFields $name "UI browser bootstrap duration fields")
  }

  $statusMarkers = Get-JsonProperty $attempt "statusMarkers" "UI browser live environment bootstrap attempt"
  foreach ($name in @("blocked", "fail", "passAttemptReady", "passReadback")) {
    $marker = [string](Get-JsonProperty $statusMarkers $name "UI browser bootstrap status markers")
    if ($marker -notmatch '^[a-z0-9_]+$') {
      throw "UI browser bootstrap status marker '$name' must be machine readable"
    }
  }

  $secretSafeOmission = Get-JsonProperty $attempt "secretSafeOmission" "UI browser live environment bootstrap attempt"
  foreach ($name in @("echoRequestMaterial", "echoSessionMaterial", "echoUrlCredentials")) {
    Assert-True ((Get-JsonProperty $secretSafeOmission $name "UI browser bootstrap secret-safe omission") -eq $false) "UI browser bootstrap must omit $name"
  }
}

function Test-BrowserAdminUiDevServerOptIn {
  param([Parameter(Mandatory = $true)]$Handoff)

  $attempt = Get-JsonProperty $Handoff "browserLiveEnvironmentBootstrapAttempt" "UI handoff"
  $devServer = Get-JsonProperty $attempt "devServer" "UI browser bootstrap dev server"
  $envName = [string](Get-JsonProperty $devServer "env" "UI browser bootstrap dev server")
  $requiredValue = [string](Get-JsonProperty $devServer "requiredValue" "UI browser bootstrap dev server")
  return $BrowserAdminUiDevServerOptIn -or ([Environment]::GetEnvironmentVariable($envName) -eq $requiredValue)
}

function Test-BrowserAdminSessionHandoffPresent {
  param([Parameter(Mandatory = $true)]$Handoff)

  $attempt = Get-JsonProperty $Handoff "browserLiveEnvironmentBootstrapAttempt" "UI handoff"
  $sessionHandoff = Get-JsonProperty $attempt "sessionHandoff" "UI browser bootstrap session handoff"
  $envName = [string](Get-JsonProperty $sessionHandoff "env" "UI browser bootstrap session handoff")
  return -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($envName))
}

function Test-BrowserLiveMutationAttemptOptIn {
  return $BrowserLiveRunnerExecutionOptIn -or $BrowserEvidenceArtifactWriteOptIn -or $BrowserMutationOptIn -or $BrowserAdminUiDevServerOptIn
}

function Publish-BrowserAdminSessionHandoff {
  param([Parameter(Mandatory = $true)]$Handoff)

  $attempt = Get-JsonProperty $Handoff "browserLiveEnvironmentBootstrapAttempt" "UI handoff"
  $sessionHandoff = Get-JsonProperty $attempt "sessionHandoff" "UI browser bootstrap session handoff"
  $envName = [string](Get-JsonProperty $sessionHandoff "env" "UI browser bootstrap session handoff")
  if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($envName))) {
    return "env_present"
  }
  if (-not (Test-BrowserLiveMutationAttemptOptIn)) {
    return "not_requested"
  }
  if ([string]::IsNullOrWhiteSpace($script:AdminSessionToken)) {
    return "script_session_missing"
  }

  $response = Invoke-ControlPlaneRequest -Method GET -Path "/admin/auth/me" -SessionToken $script:AdminSessionToken
  if ($response.StatusCode -ne 200) {
    return "script_session_invalid:$($response.StatusCode)"
  }

  Set-Item -Path "Env:\$envName" -Value $script:AdminSessionToken
  Add-SensitiveValue $script:AdminSessionToken
  return "script_session_published"
}

function Test-AdminSessionTokenForHandoff {
  param(
    [Parameter(Mandatory = $true)][string]$SessionToken,
    [Parameter(Mandatory = $true)][string]$Source
  )

  Add-SensitiveValue $SessionToken
  $response = Invoke-ControlPlaneRequest -Method GET -Path "/admin/auth/me" -SessionToken $SessionToken
  if (-not [string]::IsNullOrWhiteSpace($SessionToken) -and $response.Content.Contains($SessionToken)) {
    throw "admin session handoff /admin/auth/me response echoed session token"
  }
  if ($response.Content -match '(?i)session_token_once|x-admin-session|authorization|cookie') {
    throw "admin session handoff /admin/auth/me response echoed forbidden session transport marker"
  }
  if ($response.StatusCode -eq 200) {
    return
  }
  if ($response.StatusCode -eq 401) {
    throw "$Source session was rejected by /admin/auth/me with 401; regenerate CONTROL_PLANE_ADMIN_SESSION_TOKEN from dev admin login"
  }
  if ($response.StatusCode -eq 403) {
    throw "$Source session reached /admin/auth/me but lacks admin access with 403"
  }
  throw "$Source session validation returned HTTP $($response.StatusCode)"
}

function Write-AdminSessionHandoff {
  $source = "env"
  if ([string]::IsNullOrWhiteSpace($script:AdminSessionToken)) {
    $source = "dev_admin_login"
    $response = Invoke-ControlPlaneRequest -Method POST -Path "/admin/auth/login" -Body @{
      email = $AdminEmail
      password = $AdminPassword
    } -SessionToken ""
    Assert-SecretSafeContent -Content $response.Content -Context "admin session handoff login response"
    if ($response.StatusCode -eq 401) {
      throw "admin login returned 401 for CONTROL_PLANE_ADMIN_EMAIL; verify dev admin seed and CONTROL_PLANE_ADMIN_PASSWORD"
    }
    if ($response.StatusCode -eq 429) {
      throw "admin login returned 429 login_rate_limited; wait for retry_after_seconds before browser handoff"
    }
    if ($response.StatusCode -ne 200) {
      throw "admin login returned HTTP $($response.StatusCode); expected 200"
    }

    $payload = Read-Json $response.Content
    $token = [string]$payload.data.session_token_once
    if ([string]::IsNullOrWhiteSpace($token)) {
      throw "login response did not include data.session_token_once"
    }
    $script:AdminSessionToken = $token
    Add-SensitiveValue $token
  }

  Test-AdminSessionTokenForHandoff -SessionToken $script:AdminSessionToken -Source $source
  $env:CONTROL_PLANE_ADMIN_SESSION_TOKEN = $script:AdminSessionToken
  Add-SensitiveValue $script:AdminSessionToken

  Write-SafeHost "Admin session handoff:"
  Write-SafeHost "admin_session_present=true"
  Write-SafeHost "admin_session_source=$source"
  Write-SafeHost "admin_session_env=CONTROL_PLANE_ADMIN_SESSION_TOKEN"
  Write-SafeHost "admin_session_token_echoed=false"
  Write-SafeHost "admin_session_cookie_echoed=false"
  Write-SafeHost "admin_session_header=X-Admin-Session"
  Write-SafeHost "admin_session_handoff_status=env_set_for_current_process"
  Write-SafeHost "admin_session_browser_preflight_command=powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_execute_smoke.ps1 -BrowserPreflight"
  Write-SafeHost "admin_session_browser_live_command=`$env:CONTROL_PLANE_ADMIN_SESSION_TOKEN = '<session-token-from-secure-handoff>'; powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_execute_smoke.ps1 -BrowserPreflight"
}

function Start-BrowserAdminUiDevServerBootstrap {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [Parameter(Mandatory = $true)]$InitialProbe
  )

  $attempt = Get-JsonProperty $Handoff "browserLiveEnvironmentBootstrapAttempt" "UI handoff"
  $devServer = Get-JsonProperty $attempt "devServer" "UI browser bootstrap dev server"
  $adminUiProbeUrl = Join-SmokeProbeUrl $AdminUiBaseUrl "/"
  $devServerOptIn = Test-BrowserAdminUiDevServerOptIn $Handoff
  $result = [PSCustomObject]@{
    OptIn = $devServerOptIn
    Started = $false
    Process = $null
    Probe = $InitialProbe
    DurationMs = 0
    Classification = if ([bool]$InitialProbe.Reachable) { "already_reachable" } elseif ($devServerOptIn) { "not_started" } else { "opt_in_missing" }
  }

  if ([bool]$InitialProbe.Reachable -or -not $devServerOptIn) {
    return $result
  }

  $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
  if (-not $npm) {
    $npm = Get-Command npm -ErrorAction SilentlyContinue
  }
  if (-not $npm) {
    $result.Classification = "npm_unavailable"
    return $result
  }

  $cwd = Join-Path $repoRoot ([string](Get-JsonProperty $devServer "cwd" "UI browser bootstrap dev server"))
  if (-not (Test-Path $cwd)) {
    $result.Classification = "admin_ui_cwd_missing"
    return $result
  }

  $timer = [Diagnostics.Stopwatch]::StartNew()
  $process = $null
  try {
    $process = Start-Process -FilePath $npm.Source -ArgumentList @("run", "dev", "--", "--host", "127.0.0.1") -WorkingDirectory $cwd -WindowStyle Hidden -PassThru
    $result.Started = $true
    $result.Process = $process
    for ($i = 0; $i -lt 30; $i++) {
      Start-Sleep -Milliseconds 500
      $probe = Invoke-ServiceReadinessProbe -Name "admin_ui" -Url $adminUiProbeUrl -TimeoutMs $BrowserProbeTimeoutMilliseconds -ReachableStatusCodes @(200, 304)
      if ([bool]$probe.Reachable) {
        $result.Probe = $probe
        $result.Classification = "started_reachable"
        break
      }
      $result.Probe = $probe
      $result.Classification = "started_unreachable"
      if ($process.HasExited) {
        $result.Classification = "process_exited"
        break
      }
    }
  } catch {
    $result.Classification = "start_failed"
  } finally {
    $timer.Stop()
    $result.DurationMs = [int]$timer.ElapsedMilliseconds
  }

  return $result
}

function Stop-BrowserAdminUiDevServerBootstrap {
  param([AllowNull()]$Bootstrap)

  if ($null -eq $Bootstrap -or -not [bool]$Bootstrap.Started -or $null -eq $Bootstrap.Process) {
    return
  }
  try {
    $pending = New-Object System.Collections.Generic.List[int]
    $pending.Add([int]$Bootstrap.Process.Id)
    for ($i = 0; $i -lt $pending.Count; $i++) {
      $parentId = $pending[$i]
      $children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$parentId" -ErrorAction SilentlyContinue
      foreach ($child in @($children)) {
        $pending.Add([int]$child.ProcessId)
      }
    }
    for ($i = $pending.Count - 1; $i -ge 0; $i--) {
      Stop-Process -Id $pending[$i] -Force -ErrorAction SilentlyContinue
    }
    if (-not $Bootstrap.Process.HasExited) {
      Stop-Process -Id $Bootstrap.Process.Id -Force -ErrorAction SilentlyContinue
    }
  } catch {
    # best-effort cleanup for opt-in helper process
  }
}

function Write-BrowserLiveEnvironmentBootstrapAttempt {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [Parameter(Mandatory = $true)][string]$ToolingStatus,
    [Parameter(Mandatory = $true)]$AdminUiProbe,
    [Parameter(Mandatory = $true)]$ControlPlaneProbe,
    [Parameter(Mandatory = $true)]$AdminUiDevServerBootstrap,
    [Parameter(Mandatory = $true)][bool]$MutationEnabled,
    [Parameter(Mandatory = $true)][bool]$SessionMaterialPresent,
    [Parameter(Mandatory = $true)][int]$ServiceReadinessDurationMs
  )

  Assert-BrowserLiveEnvironmentBootstrapAttemptContract $Handoff
  $attempt = Get-JsonProperty $Handoff "browserLiveEnvironmentBootstrapAttempt" "UI handoff"
  $statusMarkers = Get-JsonProperty $attempt "statusMarkers" "UI browser bootstrap status markers"
  $durationFields = Get-JsonProperty $attempt "durationFields" "UI browser bootstrap duration fields"
  $playwright = Get-JsonProperty $attempt "playwright" "UI browser bootstrap Playwright"
  $devServer = Get-JsonProperty $attempt "devServer" "UI browser bootstrap dev server"
  $writeEnabled = Test-BrowserEvidenceArtifactWriteOptIn $Handoff
  $artifactPath = Resolve-BoundedEvidenceArtifactPath $BrowserEvidenceArtifactPath
  $readbackArtifact = $null
  $readbackAvailable = $false
  if ($BrowserEvidenceArtifactReadbackOptIn -and (Test-Path $artifactPath)) {
    $readbackArtifact = Read-JsonFile $artifactPath
    $readbackAvailable = $true
  }
  $readbackState = Get-BrowserLivePassArtifactReadbackState -Handoff $Handoff -Artifact $readbackArtifact -ReadbackAvailable $readbackAvailable
  $readbackClassification = Get-BrowserLivePassArtifactReadbackClassification -Handoff $Handoff -Artifact $readbackArtifact -ReadbackRequested $BrowserEvidenceArtifactReadbackOptIn -ReadbackAvailable $readbackAvailable
  $passAttemptReady = (
    $ToolingStatus -eq "available" -and
    [bool]$AdminUiProbe.Reachable -and
    [bool]$ControlPlaneProbe.Reachable -and
    $SessionMaterialPresent -and
    $MutationEnabled -and
    $BrowserLiveRunnerExecutionOptIn -and
    $writeEnabled
  )

  $status = [string](Get-JsonProperty $statusMarkers "blocked" "UI browser bootstrap status markers")
  if ($readbackState -eq "pass") {
    $status = [string](Get-JsonProperty $statusMarkers "passReadback" "UI browser bootstrap status markers")
  } elseif ($readbackState -eq "fail") {
    $status = [string](Get-JsonProperty $statusMarkers "fail" "UI browser bootstrap status markers")
  } elseif ($passAttemptReady) {
    $status = [string](Get-JsonProperty $statusMarkers "passAttemptReady" "UI browser bootstrap status markers")
  }

  $blockers = @()
  if ($ToolingStatus -ne "available") { $blockers += "browser_tooling_unavailable" }
  if (-not [bool]$AdminUiProbe.Reachable) { $blockers += "admin_ui_unreachable" }
  if (-not [bool]$ControlPlaneProbe.Reachable) { $blockers += "control_plane_health_unreachable" }
  if (-not $SessionMaterialPresent) { $blockers += "session_material_missing" }
  if (-not $MutationEnabled) { $blockers += "live_mutation_opt_in_missing" }
  if (-not $BrowserLiveRunnerExecutionOptIn) { $blockers += "live_runner_opt_in_missing" }
  if (-not $writeEnabled) { $blockers += "artifact_write_opt_in_missing" }
  if ($BrowserEvidenceArtifactReadbackOptIn -and -not $readbackAvailable) { $blockers += "artifact_readback_missing" }
  if ($readbackState -eq "fail") { $blockers += "artifact_closure_failed" }
  if (-not [bool]$AdminUiDevServerBootstrap.OptIn -and -not [bool]$AdminUiProbe.Reachable) { $blockers += "admin_ui_dev_server_opt_in_missing" }
  $blockerSummary = if ($blockers.Count -gt 0) { $blockers -join "+" } else { "none" }
  $liveAttemptCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1 -BrowserPreflight -BrowserAdminUiDevServerOptIn -BrowserMutationOptIn -BrowserEvidenceArtifactWriteOptIn -BrowserLiveRunnerExecutionOptIn -BrowserEvidenceArtifactPath artifacts/billing_execute_browser_live_e2e_evidence.json"

  Write-SafeHost "Browser ledger execute live environment bootstrap attempt:"
  Write-SafeHost "browser_live_bootstrap_status=$status"
  Write-SafeHost "browser_live_bootstrap_blockers=$blockerSummary"
  Write-SafeHost "browser_live_bootstrap_default_mutation=false"
  Write-SafeHost "browser_live_bootstrap_default_installs_browser=false"
  Write-SafeHost "browser_live_bootstrap_default_starts_admin_ui_dev_server=false"
  Write-SafeHost "browser_live_bootstrap_playwright=$ToolingStatus"
  Write-SafeHost "browser_live_bootstrap_playwright_browser=$([string](Get-JsonProperty $playwright "browser" "UI browser bootstrap Playwright"))"
  Write-SafeHost "browser_live_bootstrap_playwright_install_hint=$([string](Get-JsonProperty $playwright "installCommand" "UI browser bootstrap Playwright"))"
  Write-SafeHost "browser_live_bootstrap_admin_ui_dev_server_opt_in=$(Format-BoolMarker ([bool]$AdminUiDevServerBootstrap.OptIn))"
  Write-SafeHost "browser_live_bootstrap_admin_ui_dev_server_started=$(Format-BoolMarker ([bool]$AdminUiDevServerBootstrap.Started))"
  Write-SafeHost "browser_live_bootstrap_admin_ui_dev_server_classification=$($AdminUiDevServerBootstrap.Classification)"
  Write-SafeHost "browser_live_bootstrap_admin_ui_dev_server_duration_ms=$($AdminUiDevServerBootstrap.DurationMs)"
  Write-SafeHost "browser_live_bootstrap_admin_ui_dev_server_command=$([string](Get-JsonProperty $devServer "command" "UI browser bootstrap dev server"))"
  Write-SafeHost "browser_live_bootstrap_admin_ui_reachable=$(Format-BoolMarker ([bool]$AdminUiProbe.Reachable))"
  Write-SafeHost "browser_live_bootstrap_control_plane_health_reachable=$(Format-BoolMarker ([bool]$ControlPlaneProbe.Reachable))"
  Write-SafeHost "browser_live_bootstrap_session_material_present=$(Format-BoolMarker $SessionMaterialPresent)"
  Write-SafeHost "browser_live_bootstrap_session_material_echoed=false"
  Write-SafeHost "browser_live_bootstrap_mutation_enabled=$(Format-BoolMarker $MutationEnabled)"
  Write-SafeHost "browser_live_bootstrap_live_runner_opt_in=$(Format-BoolMarker $BrowserLiveRunnerExecutionOptIn)"
  Write-SafeHost "browser_live_bootstrap_artifact_write_enabled=$(Format-BoolMarker $writeEnabled)"
  Write-SafeHost "browser_live_bootstrap_artifact_readback_available=$(Format-BoolMarker $readbackAvailable)"
  Write-SafeHost "browser_live_bootstrap_artifact_readback_state=$readbackState"
  Write-SafeHost "browser_live_bootstrap_artifact_readback_classification=$readbackClassification"
  Write-SafeHost "browser_live_bootstrap_artifact_path_bounded=true"
  Write-SafeHost "browser_live_bootstrap_artifact_path=$artifactPath"
  Write-SafeHost "browser_live_bootstrap_live_attempt_command=$liveAttemptCommand"
  Write-SafeHost "browser_live_bootstrap_url_credentials_echoed=false"
  Write-SafeHost "browser_live_bootstrap_request_material_echoed=false"
  Write-SafeHost "$([string](Get-JsonProperty $durationFields "serviceReadinessDurationMs" "UI browser bootstrap duration fields"))=$ServiceReadinessDurationMs"
  foreach ($name in @("browserLaunchDurationMs", "contextSetupDurationMs", "pageReadyDurationMs", "selectorSnapshotDurationMs", "submitLatencyMs", "dryRunPlanDurationMs", "executeApplyDurationMs", "idempotentReplayDurationMs", "refundRefusalDurationMs", "ledgerRefreshDurationMs")) {
    Write-SafeHost "$([string](Get-JsonProperty $durationFields $name "UI browser bootstrap duration fields"))=unavailable"
  }
}

function Invoke-BrowserLiveMutationPassAttempt {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [Parameter(Mandatory = $true)][string]$SourceLedgerEntryId
  )

  Assert-BrowserLiveEnvironmentBootstrapAttemptContract $Handoff
  $toolingStatus = Get-BrowserToolingStatus
  $serviceTimer = [Diagnostics.Stopwatch]::StartNew()
  $adminUiProbeUrl = Join-SmokeProbeUrl $AdminUiBaseUrl "/"
  $controlPlaneProbeUrl = Join-SmokeProbeUrl $ControlPlaneBaseUrl "/healthz"
  $adminUiProbe = Invoke-ServiceReadinessProbe -Name "admin_ui" -Url $adminUiProbeUrl -TimeoutMs $BrowserProbeTimeoutMilliseconds -ReachableStatusCodes @(200, 304)
  $adminUiDevServerBootstrap = Start-BrowserAdminUiDevServerBootstrap -Handoff $Handoff -InitialProbe $adminUiProbe
  if ([bool]$adminUiDevServerBootstrap.Probe.Reachable) {
    $adminUiProbe = $adminUiDevServerBootstrap.Probe
  }
  $controlPlaneProbe = Invoke-ServiceReadinessProbe -Name "control_plane_health" -Url $controlPlaneProbeUrl -TimeoutMs $BrowserProbeTimeoutMilliseconds -ReachableStatusCodes @(200)
  $serviceTimer.Stop()

  try {
    $runbook = Get-JsonProperty $Handoff "browserLiveRunbook" "UI handoff"
    $mutationEnabled = Test-BrowserMutationOptIn $runbook
    $sessionHandoffPresent = Test-BrowserAdminSessionHandoffPresent $Handoff
    $writeEnabled = Test-BrowserEvidenceArtifactWriteOptIn $Handoff
    $artifactPath = Resolve-BoundedEvidenceArtifactPath $BrowserEvidenceArtifactPath
    $blockers = @()
    if ($toolingStatus -ne "available") { $blockers += "browser_tooling_unavailable" }
    if (-not [bool]$adminUiProbe.Reachable) { $blockers += "admin_ui_unreachable" }
    if (-not [bool]$controlPlaneProbe.Reachable) { $blockers += "control_plane_health_unreachable" }
    if (-not $sessionHandoffPresent) { $blockers += "session_material_missing" }
    if (-not $mutationEnabled) { $blockers += "live_mutation_opt_in_missing" }
    if (-not $BrowserLiveRunnerExecutionOptIn) { $blockers += "live_runner_opt_in_missing" }
    if (-not $writeEnabled) { $blockers += "artifact_write_opt_in_missing" }

    $canRun = $blockers.Count -eq 0
    $initialOutcome = if ($canRun) { "failed" } else { "blocked" }
    $artifact = New-BrowserEvidenceArtifact -Handoff $Handoff -Outcome $initialOutcome -Blockers $blockers -ToolingStatus $toolingStatus -AdminUiProbe $adminUiProbe -ControlPlaneProbe $controlPlaneProbe -MutationEnabled $mutationEnabled -SessionMaterialPresent $sessionHandoffPresent -ServiceReadinessDurationMs ([int]$serviceTimer.ElapsedMilliseconds)
    if ($artifact.PSObject.Properties.Name -contains "mutation_controls") {
      $artifact.mutation_controls.artifact_write_opt_in_enabled = $writeEnabled
      $artifact.mutation_controls.artifact_readback_opt_in_enabled = [bool]$BrowserEvidenceArtifactReadbackOptIn
    }
    if ($artifact.PSObject.Properties.Name -contains "failure_taxonomy") {
      $artifact.failure_taxonomy.artifact_write_missing = -not $writeEnabled
    }
    $runnerStatus = if ($canRun) { "running" } else { "blocked" }

    if ($canRun) {
      $nodeScript = @'
const fs = require("fs");
const { chromium } = require("@playwright/test");
let liveBrowser = null;
let liveMissingSelectorKeys = [];
let liveActions = [];
let liveCurrentAction = "startup";
let liveDurations = {
  browser_launch_duration_ms: "unavailable",
  context_setup_duration_ms: "unavailable",
  page_ready_duration_ms: "unavailable",
  selector_snapshot_duration_ms: "unavailable",
  submit_latency_ms: "unavailable",
  dry_run_plan_duration_ms: "unavailable",
  execute_apply_duration_ms: "unavailable",
  idempotent_replay_duration_ms: "unavailable",
  refund_refusal_duration_ms: "unavailable",
  ledger_refresh_duration_ms: "unavailable",
};
const runnerDeadlineMs = Number(process.env.BROWSER_RUNNER_DEADLINE_MS || "60000");
const runnerDeadline = setTimeout(() => {
  console.log(JSON.stringify({
    actions: liveActions,
    durations: liveDurations,
    error: "browser_live_runner_timeout",
    failed_action: liveCurrentAction,
    missing_selector_keys: liveMissingSelectorKeys,
    outcome: "failed",
  }));
  process.exit(2);
}, runnerDeadlineMs);

function now() {
  return Date.now();
}

function elapsed(start) {
  return Math.max(1, Date.now() - start);
}

function requireEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name}_missing`);
  }
  return value;
}

function dataTestId(id) {
  return `[data-testid="${id}"]`;
}

async function textIncludes(page, testId, expected, timeout = 15000) {
  await page.waitForFunction(
    ({ selector, expectedText }) => {
      const node = document.querySelector(selector);
      return Boolean(node && node.textContent && node.textContent.includes(expectedText));
    },
    { selector: dataTestId(testId), expectedText: expected },
    { timeout },
  );
}

async function clickIfVisible(locator) {
  if (await locator.count()) {
    await locator.first().click();
    return true;
  }
  return false;
}

async function waitForSelectorSnapshot(page, selectors, keys, timeout = 15000) {
  const started = now();
  let missing = keys;
  while (elapsed(started) < timeout) {
    missing = await page.evaluate(({ selectorValues, selectorKeys }) => {
      return selectorKeys.filter((key) => !document.querySelector(`[data-testid="${selectorValues[key]}"]`));
    }, { selectorValues: selectors, selectorKeys: keys });
    liveMissingSelectorKeys = missing;
    if (missing.length === 0) {
      return [];
    }
    await page.waitForTimeout(250);
  }
  return missing;
}

(async () => {
  const adminUiBaseUrl = requireEnv("BROWSER_ADMIN_UI_BASE_URL");
  const controlPlaneBaseUrl = requireEnv("BROWSER_CONTROL_PLANE_BASE_URL").replace(/\/+$/, "");
  const sessionToken = requireEnv("CONTROL_PLANE_ADMIN_SESSION_TOKEN");
  const sourceLedgerEntryId = requireEnv("BROWSER_LEDGER_SOURCE_ENTRY_ID");
  const handoff = JSON.parse(fs.readFileSync(requireEnv("BROWSER_HANDOFF_PATH"), "utf8"));
  const selectors = handoff.selectors;
  const actions = liveActions;
  const durations = liveDurations;

  let start = now();
  liveBrowser = await chromium.launch({ headless: true });
  const browser = liveBrowser;
  durations.browser_launch_duration_ms = elapsed(start);
  start = now();
  const context = await browser.newContext({ baseURL: adminUiBaseUrl });
  context.setDefaultTimeout(15000);
  context.setDefaultNavigationTimeout(15000);
  durations.context_setup_duration_ms = elapsed(start);

  const controlPlaneOrigin = new URL(controlPlaneBaseUrl).origin;
  await context.route("**/*", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const headers = { ...request.headers(), "x-admin-session": sessionToken };
    delete headers.cookie;

    if (url.pathname.startsWith("/api/control-plane/admin/")) {
      const targetPath = url.pathname.replace(/^\/api\/control-plane/, "");
      const response = await route.fetch({ headers, url: `${controlPlaneBaseUrl}${targetPath}${url.search}`, timeout: 15000 });
      await route.fulfill({ response });
      return;
    }

    if (url.origin === controlPlaneOrigin && url.pathname.startsWith("/admin/")) {
      await route.continue({ headers });
      return;
    }

    await route.continue();
  });

  start = now();
  const page = await context.newPage();
  await page.goto(adminUiBaseUrl, { waitUntil: "domcontentloaded" });
  await page.getByRole("button", { name: /Billing/i }).click({ timeout: 15000 });
  await page.getByRole("tab", { name: /Ledger Overview/i }).click({ timeout: 15000 });
  durations.page_ready_duration_ms = elapsed(start);

  start = now();
  const selectorSnapshotKeys = [
    "dryRunButton",
    "executeButton",
    "amountInput",
    "currencyInput",
    "operationInput",
    "relatedLedgerEntryInput",
    "reasonInput",
  ];
  const missingSelectorKeys = await waitForSelectorSnapshot(page, selectors, selectorSnapshotKeys, 15000);
  durations.selector_snapshot_duration_ms = elapsed(start);
  if (missingSelectorKeys.length > 0) {
    liveMissingSelectorKeys = missingSelectorKeys;
    throw new Error(`selector_snapshot_missing:${missingSelectorKeys.join(",")}`);
  }

  async function fillRefund(amount, reason) {
    await page.locator(dataTestId(selectors.operationInput)).selectOption("refund");
    await page.locator(dataTestId(selectors.amountInput)).fill(amount);
    await page.locator(dataTestId(selectors.currencyInput)).fill("USD");
    await page.locator(dataTestId(selectors.relatedLedgerEntryInput)).fill(sourceLedgerEntryId);
    await page.locator(dataTestId(selectors.reasonInput)).fill(reason);
  }

  async function runDryRun(amount, reason) {
    await fillRefund(amount, reason);
    const actionStart = now();
    await page.locator(dataTestId(selectors.dryRunButton)).click();
    await textIncludes(page, selectors.dryRunFresh, "fresh_dry_run=true");
    durations.dry_run_plan_duration_ms = elapsed(actionStart);
    actions.push({ name: "dry_run_plan", status: "executePreflight", outcome: "executePreflight", duration_ms: durations.dry_run_plan_duration_ms });
  }

  await runDryRun("0.15000000", "browser live smoke apply");

  liveCurrentAction = "execute_apply";
  start = now();
  await page.locator(dataTestId(selectors.executeButton)).click();
  await textIncludes(page, selectors.executeOutcome, "execute_outcome=applied", 20000);
  await textIncludes(page, selectors.executeResultFresh, "execute_result_fresh=true", 20000);
  await textIncludes(page, selectors.ledgerRefreshStatus, "ledger_entries_refresh_after_execute=success", 20000);
  durations.execute_apply_duration_ms = elapsed(start);
  durations.submit_latency_ms = durations.execute_apply_duration_ms;
  durations.ledger_refresh_duration_ms = durations.execute_apply_duration_ms;
  actions.push({ name: "execute_apply", status: "applied", outcome: "applied", duration_ms: durations.execute_apply_duration_ms });

  liveCurrentAction = "idempotent_replay";
  start = now();
  try {
    await page.locator(dataTestId(selectors.executeButton)).click();
    await textIncludes(page, selectors.executeOutcome, "execute_outcome=idempotent", 20000);
    await textIncludes(page, selectors.ledgerRefreshStatus, "ledger_entries_refresh_after_execute=success", 20000);
  } finally {
    durations.idempotent_replay_duration_ms = elapsed(start);
  }
  actions.push({ name: "idempotent_replay", status: "idempotent", outcome: "idempotent", duration_ms: durations.idempotent_replay_duration_ms });

  actions.push({ name: "ledger_refresh", status: "success", outcome: "success", duration_ms: durations.ledger_refresh_duration_ms });

  liveCurrentAction = "refund_refusal";
  await fillRefund("0.11000000", "browser live smoke refusal");
  start = now();
  await page.locator(dataTestId(selectors.dryRunButton)).click();
  await page.waitForFunction(
    ({ executeSelector }) => {
      const executeButton = document.querySelector(executeSelector);
      const text = document.body && document.body.textContent ? document.body.textContent : "";
      const refused = text.includes("remaining refundable amount") || text.includes("refund amount exceeds remaining");
      const executeDisabled = executeButton && executeButton.disabled === true;
      return refused && executeDisabled;
    },
    { executeSelector: dataTestId(selectors.executeButton) },
    { timeout: 20000 },
  );
  durations.refund_refusal_duration_ms = elapsed(start);
  actions.push({ name: "refund_refusal", status: "blocked", outcome: "blocked", duration_ms: durations.refund_refusal_duration_ms });

  liveCurrentAction = "complete";
  await browser.close();
  liveBrowser = null;
  clearTimeout(runnerDeadline);
  console.log(JSON.stringify({ actions, durations, outcome: "passed" }));
})().catch(async (error) => {
  clearTimeout(runnerDeadline);
  if (liveBrowser) {
    try {
      await liveBrowser.close();
    } catch (_) {
    }
    liveBrowser = null;
  }
  console.log(JSON.stringify({
    actions: liveActions,
    durations: liveDurations,
    error: String(error && error.message ? error.message : error).replace(/Bearer\s+\S+/gi, "Bearer [REDACTED]"),
    failed_action: liveCurrentAction,
    missing_selector_keys: liveMissingSelectorKeys,
    outcome: "failed",
  }));
  process.exitCode = 1;
});
'@

      $adminUiRoot = Join-Path $repoRoot "web\admin-ui"
      $tempScript = Join-Path $adminUiRoot ("billing_execute_browser_runner_" + [guid]::NewGuid().ToString("N") + ".cjs")
      $tempStdout = Join-Path $adminUiRoot ("billing_execute_browser_runner_" + [guid]::NewGuid().ToString("N") + ".stdout.log")
      $tempStderr = Join-Path $adminUiRoot ("billing_execute_browser_runner_" + [guid]::NewGuid().ToString("N") + ".stderr.log")
      Set-Content -Path $tempScript -Value $nodeScript -Encoding UTF8
      $previousSession = $env:CONTROL_PLANE_ADMIN_SESSION_TOKEN
      $previousAdminUi = $env:BROWSER_ADMIN_UI_BASE_URL
      $previousBackend = $env:BROWSER_CONTROL_PLANE_BASE_URL
      $previousHandoff = $env:BROWSER_HANDOFF_PATH
      $previousSource = $env:BROWSER_LEDGER_SOURCE_ENTRY_ID
      try {
        $env:CONTROL_PLANE_ADMIN_SESSION_TOKEN = $script:AdminSessionToken
        $env:BROWSER_ADMIN_UI_BASE_URL = (Get-SafeSmokeUrlSummary $AdminUiBaseUrl "Admin UI URL")
        $env:BROWSER_CONTROL_PLANE_BASE_URL = (Get-SafeSmokeUrlSummary $ControlPlaneBaseUrl "Control Plane backend URL")
        $env:BROWSER_HANDOFF_PATH = $uiSmokeHandoffPath
        $env:BROWSER_LEDGER_SOURCE_ENTRY_ID = $SourceLedgerEntryId
        Push-Location $adminUiRoot
        try {
          $runnerProcess = Start-Process -FilePath "node" -ArgumentList @($tempScript) -WorkingDirectory $adminUiRoot -NoNewWindow -RedirectStandardOutput $tempStdout -RedirectStandardError $tempStderr -PassThru
          if (-not $runnerProcess.WaitForExit(90000)) {
            try {
              $runnerProcess.Kill()
              $runnerProcess.WaitForExit(5000) | Out-Null
            } catch {
            }
            $runnerExitCode = 124
            $runnerOutput = @('{ "actions": [], "durations": {}, "error": "browser_live_runner_outer_timeout", "outcome": "failed" }')
          } else {
            $runnerExitCode = $runnerProcess.ExitCode
            $runnerOutput = @()
            if (Test-Path $tempStdout) {
              $runnerOutput += Get-Content -Path $tempStdout -ErrorAction SilentlyContinue
            }
            if (Test-Path $tempStderr) {
              $runnerOutput += Get-Content -Path $tempStderr -ErrorAction SilentlyContinue
            }
          }
        } finally {
          Pop-Location
        }
      } finally {
        if ($null -eq $previousSession) { Remove-Item Env:\CONTROL_PLANE_ADMIN_SESSION_TOKEN -ErrorAction SilentlyContinue } else { $env:CONTROL_PLANE_ADMIN_SESSION_TOKEN = $previousSession }
        if ($null -eq $previousAdminUi) { Remove-Item Env:\BROWSER_ADMIN_UI_BASE_URL -ErrorAction SilentlyContinue } else { $env:BROWSER_ADMIN_UI_BASE_URL = $previousAdminUi }
        if ($null -eq $previousBackend) { Remove-Item Env:\BROWSER_CONTROL_PLANE_BASE_URL -ErrorAction SilentlyContinue } else { $env:BROWSER_CONTROL_PLANE_BASE_URL = $previousBackend }
        if ($null -eq $previousHandoff) { Remove-Item Env:\BROWSER_HANDOFF_PATH -ErrorAction SilentlyContinue } else { $env:BROWSER_HANDOFF_PATH = $previousHandoff }
        if ($null -eq $previousSource) { Remove-Item Env:\BROWSER_LEDGER_SOURCE_ENTRY_ID -ErrorAction SilentlyContinue } else { $env:BROWSER_LEDGER_SOURCE_ENTRY_ID = $previousSource }
        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tempStdout -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tempStderr -Force -ErrorAction SilentlyContinue
      }

      $runnerJson = (($runnerOutput | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Last 1) | Out-String).Trim()
      $runnerResult = Read-Json $runnerJson
      $runnerStatus = [string]$runnerResult.outcome
      if ($runnerStatus -eq "passed" -and $runnerExitCode -eq 0) {
        $artifact.outcome = "passed"
        $artifact.blockers = @()
      } else {
        $runnerErrorClass = Get-BrowserRunnerErrorClass -ErrorMessage ([string]$runnerResult.error) -FailedAction ([string]$runnerResult.failed_action)
        $artifact.outcome = "failed"
        $artifact.blockers = @($runnerErrorClass)
      }
      Set-BrowserEvidenceFromRunnerResult -Artifact $artifact -RunnerResult $runnerResult
      Update-BrowserEvidenceClassifications -Handoff $Handoff -Artifact $artifact
    }

    Assert-BrowserEvidenceArtifactShape -Handoff $Handoff -Artifact $artifact
    if ($artifact.outcome -eq "passed") {
      Assert-BrowserEvidenceArtifactFreshness -Handoff $Handoff -Artifact $artifact
      if (-not (Test-BrowserMutationPassArtifactClosure -Handoff $Handoff -Artifact $artifact)) {
        $artifact.outcome = "failed"
        $artifact.blockers = @("artifact_closure_failed")
        Update-BrowserEvidenceClassifications -Handoff $Handoff -Artifact $artifact
      }
    }

    $artifactJson = $artifact | ConvertTo-Json -Depth 32 -Compress
    if ($writeEnabled) {
      $artifactDirectory = Split-Path -Path $artifactPath -Parent
      if (-not (Test-Path $artifactDirectory)) {
        New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
      }
      Set-Content -Path $artifactPath -Value $artifactJson -Encoding UTF8
      $readBack = Read-JsonFile $artifactPath
      Assert-BrowserEvidenceArtifactFreshness -Handoff $Handoff -Artifact $readBack
      $readbackClosureEligible = Test-BrowserMutationPassArtifactClosure -Handoff $Handoff -Artifact $readBack
      $readbackClassificationName = if ($readbackClosureEligible) { "passed" } else { "failed" }
      $readbackClassification = Get-BrowserEvidenceClassificationValue -Handoff $Handoff -Group "readback" -Name $readbackClassificationName
      Set-BrowserArtifactReadbackResult -Artifact $artifact -Classification $readbackClassification -Attempted $true -Fresh $true -ClosureEligible $readbackClosureEligible
      Update-BrowserEvidenceClassifications -Handoff $Handoff -Artifact $artifact
      $artifactJson = $artifact | ConvertTo-Json -Depth 32 -Compress
      Set-Content -Path $artifactPath -Value $artifactJson -Encoding UTF8
      $readBack = Read-JsonFile $artifactPath
      Assert-BrowserEvidenceArtifactFreshness -Handoff $Handoff -Artifact $readBack
      if ($artifact.outcome -eq "passed") {
        Assert-True (Test-BrowserMutationPassArtifactClosure -Handoff $Handoff -Artifact $readBack) "browser live runner pass artifact readback must close"
      }
    }

    Write-SafeHost "Browser ledger execute live mutation pass attempt:"
    Write-SafeHost "browser_live_mutation_attempt_status=$runnerStatus"
    Write-SafeHost "browser_live_mutation_attempt_artifact_outcome=$($artifact.outcome)"
    Write-SafeHost "browser_live_mutation_attempt_runtime_current_classification=$($artifact.classifications.runtime_current)"
    Write-SafeHost "browser_live_mutation_attempt_runtime_current_reason=$($artifact.runtime_current.reason)"
    Write-SafeHost "browser_live_mutation_attempt_replay_classification=$($artifact.classifications.replay)"
    Write-SafeHost "browser_live_mutation_attempt_mutation_pass_artifact_classification=$($artifact.classifications.mutation_pass_artifact)"
    Write-SafeHost "browser_live_mutation_attempt_readback_classification=$($artifact.classifications.readback)"
    Write-SafeHost "browser_live_mutation_attempt_blockers=$(if ($artifact.blockers.Count -gt 0) { $artifact.blockers -join '+' } else { 'none' })"
    Write-SafeHost "browser_live_mutation_attempt_error_class=$(if ($artifact.blockers.Count -gt 0 -and [string]$runnerStatus -eq 'failed') { $artifact.blockers -join '+' } else { 'none' })"
    Write-SafeHost "browser_live_mutation_attempt_failed_action=$(if ($artifact.PSObject.Properties.Name -contains 'browser_runner') { $artifact.browser_runner.failed_action } else { 'none' })"
    Write-SafeHost "browser_live_mutation_attempt_missing_selector_keys=$(if ($artifact.PSObject.Properties.Name -contains 'selector_snapshot' -and $artifact.selector_snapshot.missing_selector_count -gt 0) { $artifact.selector_snapshot.missing_selector_keys -join '+' } else { 'none' })"
    Write-SafeHost "browser_live_mutation_attempt_session_handoff_present=$(Format-BoolMarker $sessionHandoffPresent)"
    Write-SafeHost "browser_live_mutation_attempt_session_material_echoed=false"
    Write-SafeHost "browser_live_mutation_attempt_mutation_enabled=$(Format-BoolMarker $mutationEnabled)"
    Write-SafeHost "browser_live_mutation_attempt_artifact_write_enabled=$(Format-BoolMarker $writeEnabled)"
    Write-SafeHost "browser_live_mutation_attempt_artifact_path=$artifactPath"
    Write-SafeHost "browser_live_mutation_attempt_artifact_json=$artifactJson"
  } finally {
    Stop-BrowserAdminUiDevServerBootstrap $adminUiDevServerBootstrap
  }
}

function Test-BrowserMutationOptIn {
  param([Parameter(Mandatory = $true)]$Runbook)

  $mutationOptIn = Get-JsonProperty $Runbook "mutationOptIn" "UI browser live runbook"
  $envName = [string](Get-JsonProperty $mutationOptIn "env" "UI browser live runbook mutation opt-in")
  $requiredValue = [string](Get-JsonProperty $mutationOptIn "requiredValue" "UI browser live runbook mutation opt-in")
  return $BrowserMutationOptIn -or ([Environment]::GetEnvironmentVariable($envName) -eq $requiredValue)
}

function Assert-BrowserLiveRunbookContract {
  param([Parameter(Mandatory = $true)]$Handoff)

  $runbook = Get-JsonProperty $Handoff "browserLiveRunbook" "UI handoff"
  Assert-Equal (Get-JsonProperty $runbook "defaultMode" "UI browser live runbook") "contract_only" "UI browser live runbook default mode"

  $liveCommand = Get-JsonProperty $runbook "liveCommand" "UI browser live runbook"
  Assert-Equal (Get-JsonProperty $liveCommand "script" "UI browser live runbook command") "scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1" "UI browser live runbook script"
  $arguments = Get-JsonStringArray (Get-JsonProperty $liveCommand "arguments" "UI browser live runbook command") "UI browser live runbook command arguments"
  if ($arguments -notcontains "-BrowserPreflight") {
    throw "UI browser live runbook command must include -BrowserPreflight"
  }

  $requiredInputs = Get-JsonProperty $runbook "requiredInputs" "UI browser live runbook"
  Assert-Equal (Get-JsonProperty $requiredInputs "adminUiBaseUrl" "UI browser live runbook required inputs") "ADMIN_UI_BASE_URL" "UI browser live runbook Admin UI env"
  Assert-Equal (Get-JsonProperty $requiredInputs "controlPlaneBaseUrl" "UI browser live runbook required inputs") "CONTROL_PLANE_BASE_URL" "UI browser live runbook Control Plane env"
  Assert-Equal (Get-JsonProperty $requiredInputs "sessionMaterial" "UI browser live runbook required inputs") "CONTROL_PLANE_ADMIN_SESSION_TOKEN" "UI browser live runbook session env"

  $mutationOptIn = Get-JsonProperty $runbook "mutationOptIn" "UI browser live runbook"
  Assert-Equal (Get-JsonProperty $mutationOptIn "env" "UI browser live runbook mutation opt-in") "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_MUTATION" "UI browser live runbook mutation env"
  Assert-Equal (Get-JsonProperty $mutationOptIn "flag" "UI browser live runbook mutation opt-in") "-BrowserMutationOptIn" "UI browser live runbook mutation flag"
  Assert-Equal (Get-JsonProperty $mutationOptIn "requiredValue" "UI browser live runbook mutation opt-in") "1" "UI browser live runbook mutation value"

  $blockers = Get-JsonProperty $runbook "blockerClassifications" "UI browser live runbook"
  foreach ($name in @("adminUiUnreachable", "browserToolingUnavailable", "controlPlaneHealthUnreachable", "liveMutationOptInMissing", "sessionMaterialMissing")) {
    $classification = [string](Get-JsonProperty $blockers $name "UI browser live runbook blocker classifications")
    if ($classification -notmatch '^[a-z0-9_]+$') {
      throw "UI browser live runbook blocker '$name' must be machine readable"
    }
  }

  $evidenceNames = Get-JsonProperty $runbook "evidenceNames" "UI browser live runbook"
  foreach ($name in @("browserLaunchDurationMs", "contextSetupDurationMs", "dryRunPlanDurationMs", "executeApplyDurationMs", "idempotentReplayDurationMs", "ledgerRefreshDurationMs", "pageReadyDurationMs", "refundRefusalDurationMs", "selectorSnapshotDurationMs", "serviceReadinessDurationMs", "submitLatencyMs")) {
    $evidence = [string](Get-JsonProperty $evidenceNames $name "UI browser live runbook evidence names")
    if ($evidence -notmatch '^[a-z0-9_]+$') {
      throw "UI browser live runbook evidence '$name' must be machine readable"
    }
  }

  $secretSafe = Get-JsonProperty $runbook "secretSafeOutput" "UI browser live runbook"
  Assert-True ((Get-JsonProperty $secretSafe "echoSessionMaterial" "UI browser live runbook secret-safe output") -eq $false) "UI browser live runbook must not echo session material"
  $forbiddenMarkers = Get-JsonStringArray (Get-JsonProperty $secretSafe "forbiddenMarkers" "UI browser live runbook secret-safe output") "UI browser live runbook forbidden markers"
  foreach ($forbidden in @("Authorization", "Cookie", "token", "credential", "operation_key", "raw metadata", "raw executor error detail", "dedupe material")) {
    if ($forbiddenMarkers -notcontains $forbidden) {
      throw "UI browser live runbook forbidden markers missing '$forbidden'"
    }
  }
}

function Write-BrowserLiveRunbookGate {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [Parameter(Mandatory = $true)][string]$ToolingStatus,
    [Parameter(Mandatory = $true)]$AdminUiProbe,
    [Parameter(Mandatory = $true)]$ControlPlaneProbe
  )

  Assert-BrowserLiveRunbookContract $Handoff
  $runbook = Get-JsonProperty $Handoff "browserLiveRunbook" "UI handoff"
  $liveCommand = Get-JsonProperty $runbook "liveCommand" "UI browser live runbook"
  $mutationOptIn = Get-JsonProperty $runbook "mutationOptIn" "UI browser live runbook"
  $requiredInputs = Get-JsonProperty $runbook "requiredInputs" "UI browser live runbook"
  $blockers = Get-JsonProperty $runbook "blockerClassifications" "UI browser live runbook"
  $evidenceNames = Get-JsonProperty $runbook "evidenceNames" "UI browser live runbook"
  $mutationEnabled = Test-BrowserMutationOptIn $runbook
  $sessionMaterialPresent = Test-BrowserAdminSessionHandoffPresent $Handoff
  $liveBlockers = @()
  if ($ToolingStatus -ne "available") {
    $liveBlockers += [string](Get-JsonProperty $blockers "browserToolingUnavailable" "UI browser live runbook blocker classifications")
  }
  if (-not [bool]$AdminUiProbe.Reachable) {
    $liveBlockers += [string](Get-JsonProperty $blockers "adminUiUnreachable" "UI browser live runbook blocker classifications")
  }
  if (-not [bool]$ControlPlaneProbe.Reachable) {
    $liveBlockers += [string](Get-JsonProperty $blockers "controlPlaneHealthUnreachable" "UI browser live runbook blocker classifications")
  }
  if (-not $sessionMaterialPresent) {
    $liveBlockers += [string](Get-JsonProperty $blockers "sessionMaterialMissing" "UI browser live runbook blocker classifications")
  }
  if (-not $mutationEnabled) {
    $liveBlockers += [string](Get-JsonProperty $blockers "liveMutationOptInMissing" "UI browser live runbook blocker classifications")
  }
  $blockerSummary = "none"
  if ($liveBlockers.Count -gt 0) {
    $blockerSummary = ($liveBlockers -join "+")
  }

  $scriptPath = [string](Get-JsonProperty $liveCommand "script" "UI browser live runbook command")
  $arguments = Get-JsonStringArray (Get-JsonProperty $liveCommand "arguments" "UI browser live runbook command") "UI browser live runbook command arguments"
  $mutationFlag = [string](Get-JsonProperty $mutationOptIn "flag" "UI browser live runbook mutation opt-in")
  $mutationEnv = [string](Get-JsonProperty $mutationOptIn "env" "UI browser live runbook mutation opt-in")
  $mutationValue = [string](Get-JsonProperty $mutationOptIn "requiredValue" "UI browser live runbook mutation opt-in")
  $adminUiEnv = [string](Get-JsonProperty $requiredInputs "adminUiBaseUrl" "UI browser live runbook required inputs")
  $controlPlaneEnv = [string](Get-JsonProperty $requiredInputs "controlPlaneBaseUrl" "UI browser live runbook required inputs")
  $sessionEnv = [string](Get-JsonProperty $requiredInputs "sessionMaterial" "UI browser live runbook required inputs")
  $copyableCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath $($arguments -join ' ') $mutationFlag"

  Write-SafeHost "Browser ledger execute live runbook gate:"
  Write-SafeHost "browser_live_runbook_mode=$([string](Get-JsonProperty $runbook "defaultMode" "UI browser live runbook"))"
  Write-SafeHost "browser_live_run_command=$copyableCommand"
  Write-SafeHost "browser_live_required_env=$adminUiEnv,$controlPlaneEnv,$sessionEnv,$mutationEnv=$mutationValue"
  Write-SafeHost "browser_live_required_flag=$mutationFlag"
  Write-SafeHost "browser_live_mutation_enabled=$(Format-BoolMarker $mutationEnabled)"
  Write-SafeHost "browser_live_session_material_present=$(Format-BoolMarker $sessionMaterialPresent)"
  Write-SafeHost "browser_live_session_material_echoed=false"
  Write-SafeHost "browser_live_blockers=$blockerSummary"
  foreach ($name in @("serviceReadinessDurationMs", "browserLaunchDurationMs", "contextSetupDurationMs", "pageReadyDurationMs", "selectorSnapshotDurationMs", "submitLatencyMs", "dryRunPlanDurationMs", "executeApplyDurationMs", "idempotentReplayDurationMs", "refundRefusalDurationMs", "ledgerRefreshDurationMs")) {
    Write-SafeHost "browser_live_evidence_name=$([string](Get-JsonProperty $evidenceNames $name "UI browser live runbook evidence names"))"
  }
}

function Assert-BrowserEvidenceArtifactContract {
  param([Parameter(Mandatory = $true)]$Handoff)

  $contract = Get-JsonProperty $Handoff "browserEvidenceArtifact" "UI handoff"
  Assert-Equal (Get-JsonProperty $contract "artifactName" "UI browser evidence artifact") "billing_execute_browser_live_e2e_evidence.v1" "UI browser evidence artifact name"
  Assert-Equal (Get-JsonProperty $contract "unavailableMarker" "UI browser evidence artifact") "unavailable" "UI browser evidence unavailable marker"

  $requiredTopLevel = Get-JsonStringArray (Get-JsonProperty $contract "requiredTopLevelFields" "UI browser evidence artifact") "UI browser evidence top-level fields"
  Assert-StringSetEqual $requiredTopLevel @("artifact", "generated_at", "mode", "outcome", "provenance", "freshness", "runtime_current", "classifications", "readback", "runtime_current_artifact", "session_verification", "mutation_controls", "api_readback", "ledger_readback", "failure_taxonomy", "blockers", "matrix", "durations", "actions", "secret_safe") "UI browser evidence top-level fields"

  $outcomes = Get-JsonProperty $contract "outcomes" "UI browser evidence artifact"
  foreach ($name in @("blocked", "failed", "passed")) {
    Assert-Equal (Get-JsonProperty $outcomes $name "UI browser evidence outcomes") $name "UI browser evidence outcome $name"
  }

  $classificationFields = Get-JsonProperty $contract "classificationFields" "UI browser evidence classifications"
  foreach ($name in @("failure", "mutationPassArtifact", "readback", "replay", "runtimeCurrent")) {
    $field = [string](Get-JsonProperty $classificationFields $name "UI browser evidence classification fields")
    if ($field -notmatch '^[a-z0-9_]+$') {
      throw "UI browser evidence classification field '$name' must be machine readable"
    }
  }

  $classificationValues = Get-JsonProperty $contract "classificationValues" "UI browser evidence classification values"
  foreach ($groupName in @("failure", "mutationPassArtifact", "readback", "replay", "runtimeCurrent")) {
    $group = Get-JsonProperty $classificationValues $groupName "UI browser evidence classification values"
    foreach ($property in @($group.PSObject.Properties)) {
      $value = [string]$property.Value
      if ($value -ne "none" -and $value -notmatch '^[a-z0-9_]+$') {
        throw "UI browser evidence classification '$groupName.$($property.Name)' must be machine readable"
      }
    }
  }

  $durationFields = Get-JsonProperty $contract "durationFields" "UI browser evidence artifact"
  foreach ($name in @("browserLaunchDurationMs", "contextSetupDurationMs", "dryRunPlanDurationMs", "executeApplyDurationMs", "idempotentReplayDurationMs", "ledgerRefreshDurationMs", "pageReadyDurationMs", "refundRefusalDurationMs", "selectorSnapshotDurationMs", "serviceReadinessDurationMs", "submitLatencyMs")) {
    $field = [string](Get-JsonProperty $durationFields $name "UI browser evidence duration fields")
    if ($field -notmatch '^[a-z0-9_]+$') {
      throw "UI browser evidence duration field '$name' must be machine readable"
    }
  }

  $artifactSchema = Get-JsonProperty $contract "artifactSchema" "UI browser evidence artifact schema"
  Assert-Equal (Get-JsonProperty $artifactSchema "runtimeCurrentArtifactLinkField" "UI browser evidence artifact schema") "runtime_current_artifact" "UI browser evidence runtime artifact link field"
  Assert-Equal (Get-JsonProperty $artifactSchema "sessionVerificationField" "UI browser evidence artifact schema") "session_verification" "UI browser evidence session verification field"
  Assert-StringSetEqual (Get-JsonStringArray (Get-JsonProperty $artifactSchema "apiReadbackFields" "UI browser evidence artifact schema") "UI browser evidence API readback fields") @("dry_run_plan", "execute_apply", "idempotent_replay", "refund_refusal", "ledger_refresh") "UI browser evidence API readback fields"
  Assert-StringSetEqual (Get-JsonStringArray (Get-JsonProperty $artifactSchema "ledgerReadbackFields" "UI browser evidence artifact schema") "UI browser evidence ledger readback fields") @("applied_ledger_entry_visible", "idempotent_replay_reused_ledger_entry", "refund_refusal_no_ledger_write", "ledger_refresh_visible") "UI browser evidence ledger readback fields"
  Assert-StringSetEqual (Get-JsonStringArray (Get-JsonProperty $artifactSchema "mutationControlFields" "UI browser evidence artifact schema") "UI browser evidence mutation control fields") @("mutation_opt_in_enabled", "artifact_write_opt_in_enabled", "artifact_readback_opt_in_enabled") "UI browser evidence mutation control fields"
  Assert-StringSetEqual (Get-JsonStringArray (Get-JsonProperty $artifactSchema "failureTaxonomyFields" "UI browser evidence artifact schema") "UI browser evidence failure taxonomy fields") @("session_missing", "runtime_stale", "mutation_opt_in_missing", "artifact_write_missing", "artifact_readback_failed", "idempotent_replay_failed", "refund_refusal_missing", "ledger_refresh_missing", "duration_non_numeric", "stale_or_simulated_artifact", "browser_unavailable") "UI browser evidence failure taxonomy fields"
}

function Get-BrowserEvidenceClassificationValue {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [Parameter(Mandatory = $true)][string]$Group,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $contract = Get-JsonProperty $Handoff "browserEvidenceArtifact" "UI handoff"
  $classificationValues = Get-JsonProperty $contract "classificationValues" "UI browser evidence classification values"
  $groupValues = Get-JsonProperty $classificationValues $Group "UI browser evidence classification values"
  return [string](Get-JsonProperty $groupValues $Name "UI browser evidence classification values")
}

function Get-BrowserEvidenceFailureClassification {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [Parameter(Mandatory = $true)]$Artifact
  )

  foreach ($blocker in @(Get-JsonProperty $Artifact "blockers" "browser evidence artifact")) {
    if (-not [string]::IsNullOrWhiteSpace([string]$blocker)) {
      return [string]$blocker
    }
  }
  return (Get-BrowserEvidenceClassificationValue -Handoff $Handoff -Group "failure" -Name "none")
}

function Get-BrowserEvidenceReplayClassification {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [Parameter(Mandatory = $true)]$Artifact
  )

  $failed = Get-BrowserEvidenceClassificationValue -Handoff $Handoff -Group "replay" -Name "failed"
  $passed = Get-BrowserEvidenceClassificationValue -Handoff $Handoff -Group "replay" -Name "passed"
  $notRun = Get-BrowserEvidenceClassificationValue -Handoff $Handoff -Group "replay" -Name "notRun"
  foreach ($blocker in @(Get-JsonProperty $Artifact "blockers" "browser evidence artifact")) {
    if ([string]$blocker -eq $failed) {
      return $failed
    }
  }
  if ($Artifact.PSObject.Properties.Name -contains "browser_runner") {
    $failedAction = [string](Get-JsonProperty $Artifact.browser_runner "failed_action" "browser evidence runner")
    if ($failedAction -eq "idempotent_replay") {
      return $failed
    }
  }
  foreach ($action in @(Get-JsonProperty $Artifact "actions" "browser evidence artifact")) {
    if ([string](Get-JsonProperty $action "name" "browser evidence action") -ne "idempotent_replay") {
      continue
    }
    $outcome = [string](Get-JsonProperty $action "outcome" "browser evidence action")
    if ($outcome -eq "idempotent" -and (Test-BrowserEvidenceDurationValue (Get-JsonProperty $action "duration_ms" "browser evidence action"))) {
      return $passed
    }
    if ($outcome -eq "failed") {
      return $failed
    }
  }
  return $notRun
}

function Update-BrowserEvidenceClassifications {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [Parameter(Mandatory = $true)]$Artifact
  )

  $mutationValues = Get-JsonProperty (Get-JsonProperty (Get-JsonProperty $Handoff "browserEvidenceArtifact" "UI handoff") "classificationValues" "UI browser evidence classification values") "mutationPassArtifact" "UI browser evidence mutation classifications"
  $mutationClassification = [string](Get-JsonProperty $mutationValues "notRequested" "UI browser evidence mutation classifications")
  if ([string]$Artifact.outcome -eq "blocked") {
    $mutationClassification = [string](Get-JsonProperty $mutationValues "blocked" "UI browser evidence mutation classifications")
  } elseif ([string]$Artifact.outcome -eq "failed") {
    $mutationClassification = [string](Get-JsonProperty $mutationValues "failed" "UI browser evidence mutation classifications")
  } elseif ([string]$Artifact.outcome -eq "passed") {
    if (Test-BrowserMutationPassArtifactClosure -Handoff $Handoff -Artifact $Artifact) {
      $mutationClassification = [string](Get-JsonProperty $mutationValues "passed" "UI browser evidence mutation classifications")
    } else {
      $mutationClassification = [string](Get-JsonProperty $mutationValues "failed" "UI browser evidence mutation classifications")
    }
  }

  $Artifact.classifications.runtime_current = [string](Get-JsonProperty $Artifact.runtime_current "classification" "browser evidence runtime current")
  $Artifact.classifications.replay = Get-BrowserEvidenceReplayClassification -Handoff $Handoff -Artifact $Artifact
  $Artifact.classifications.mutation_pass_artifact = $mutationClassification
  $Artifact.classifications.failure = Get-BrowserEvidenceFailureClassification -Handoff $Handoff -Artifact $Artifact
}

function Set-BrowserArtifactReadbackResult {
  param(
    [Parameter(Mandatory = $true)]$Artifact,
    [Parameter(Mandatory = $true)][string]$Classification,
    [Parameter(Mandatory = $true)][bool]$Attempted,
    [Parameter(Mandatory = $true)][bool]$Fresh,
    [Parameter(Mandatory = $true)][bool]$ClosureEligible
  )

  $Artifact.readback.classification = $Classification
  $Artifact.readback.attempted = $Attempted
  $Artifact.readback.fresh = $Fresh
  $Artifact.readback.closure_eligible = $ClosureEligible
  $Artifact.classifications.readback = $Classification
}

function New-BrowserEvidenceArtifact {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [Parameter(Mandatory = $true)][string]$Outcome,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Blockers,
    [Parameter(Mandatory = $true)][string]$ToolingStatus,
    [Parameter(Mandatory = $true)]$AdminUiProbe,
    [Parameter(Mandatory = $true)]$ControlPlaneProbe,
    [Parameter(Mandatory = $true)][bool]$MutationEnabled,
    [Parameter(Mandatory = $true)][bool]$SessionMaterialPresent,
    [Parameter(Mandatory = $true)][int]$ServiceReadinessDurationMs,
    [string]$GeneratedAt = "",
    [string]$GitCommit = "",
    [bool]$HandoffFresh = $true
  )

  $contract = Get-JsonProperty $Handoff "browserEvidenceArtifact" "UI handoff"
  $durationFields = Get-JsonProperty $contract "durationFields" "UI browser evidence artifact"
  $unavailable = [string](Get-JsonProperty $contract "unavailableMarker" "UI browser evidence artifact")
  $runner = Get-JsonProperty $Handoff "browserRunnerReadiness" "UI handoff"
  $roundTrip = Get-JsonProperty $runner "artifactRoundTrip" "UI browser runner artifact round-trip"
  $artifactWriteRead = Get-JsonProperty $runner "artifactWriteRead" "UI browser runner artifact write/read"
  $staleRefusal = Get-JsonProperty $artifactWriteRead "staleRefusal" "UI browser runner artifact stale refusal"
  $runtimeCurrent = Get-BrowserRuntimeCurrentEvidence
  $notRunReplay = Get-BrowserEvidenceClassificationValue -Handoff $Handoff -Group "replay" -Name "notRun"
  $notRequestedMutation = Get-BrowserEvidenceClassificationValue -Handoff $Handoff -Group "mutationPassArtifact" -Name "notRequested"
  $notRequestedReadback = Get-BrowserEvidenceClassificationValue -Handoff $Handoff -Group "readback" -Name "notRequested"
  $noFailure = Get-BrowserEvidenceClassificationValue -Handoff $Handoff -Group "failure" -Name "none"
  if ([string]::IsNullOrWhiteSpace($GeneratedAt)) {
    $GeneratedAt = (Get-Date).ToUniversalTime().ToString("o")
  }
  if ([string]::IsNullOrWhiteSpace($GitCommit)) {
    $GitCommit = Get-CurrentGitCommit
  }
  $actions = @()
  $actionPlan = Get-JsonProperty $Handoff "browserActionPlan" "UI handoff"
  foreach ($step in @(Get-JsonProperty $actionPlan "steps" "UI browser action plan")) {
    $actions += [PSCustomObject]@{
      name = [string](Get-JsonProperty $step "name" "UI browser evidence action")
      expected_state = [string](Get-JsonProperty $step "expectedState" "UI browser evidence action")
      selector = [string](Get-JsonProperty $step "selector" "UI browser evidence action")
      status = if ($Outcome -eq "passed") { "passed" } elseif ($Outcome -eq "failed") { "failed" } else { $unavailable }
      outcome = if ($Outcome -eq "passed") { "passed" } elseif ($Outcome -eq "failed") { "failed" } else { $unavailable }
      duration_ms = $unavailable
    }
  }

  return [PSCustomObject]@{
    artifact = [string](Get-JsonProperty $contract "artifactName" "UI browser evidence artifact")
    generated_at = $GeneratedAt
    mode = "browser_live_e2e"
    outcome = $Outcome
    provenance = [PSCustomObject]@{
      script = "scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1"
      handoff_artifact = "web/admin-ui/src/billingExecuteSmokeContract.serializable.json"
      handoff_fresh = $HandoffFresh
      git_commit = $GitCommit
    }
    freshness = [PSCustomObject]@{
      marker = [string](Get-JsonProperty $roundTrip "freshnessMarker" "UI browser runner artifact round-trip")
      handoff_fresh = $HandoffFresh
      git_commit = $GitCommit
      require_current_git_commit = [bool](Get-JsonProperty $staleRefusal "requireCurrentGitCommit" "UI browser runner artifact stale refusal")
      max_generated_age_minutes = [int](Get-JsonProperty $staleRefusal "maxGeneratedAgeMinutes" "UI browser runner artifact stale refusal")
    }
    runtime_current = $runtimeCurrent
    classifications = [PSCustomObject]@{
      runtime_current = [string](Get-JsonProperty $runtimeCurrent "classification" "browser runtime-current evidence")
      replay = $notRunReplay
      mutation_pass_artifact = $notRequestedMutation
      readback = $notRequestedReadback
      failure = if ($Blockers.Count -gt 0) { [string]$Blockers[0] } else { $noFailure }
    }
    readback = [PSCustomObject]@{
      classification = $notRequestedReadback
      attempted = $false
      fresh = $false
      closure_eligible = $false
      path_bounded = $true
    }
    runtime_current_artifact = [PSCustomObject]@{
      linked = [string](Get-JsonProperty $runtimeCurrent "classification" "browser runtime-current evidence") -eq "runtime_current_verified"
      classification = [string](Get-JsonProperty $runtimeCurrent "classification" "browser runtime-current evidence")
      source = "runtime_current_handoff_artifact"
      secret_material_echoed = $false
    }
    session_verification = [PSCustomObject]@{
      marker = if ($SessionMaterialPresent) { "admin_session_verified" } else { "session_material_missing" }
      verified = $SessionMaterialPresent
      secret_omitted = $true
      token_echoed = $false
      cookie_echoed = $false
      header_value_echoed = $false
    }
    mutation_controls = [PSCustomObject]@{
      mutation_opt_in_enabled = $MutationEnabled
      artifact_write_opt_in_enabled = $false
      artifact_readback_opt_in_enabled = $false
      default_build = $false
      default_mutation = $false
      default_runner = $false
    }
    api_readback = [PSCustomObject]@{
      dry_run_plan = "unavailable"
      execute_apply = "unavailable"
      idempotent_replay = "unavailable"
      refund_refusal = "unavailable"
      ledger_refresh = "unavailable"
    }
    ledger_readback = [PSCustomObject]@{
      applied_ledger_entry_visible = $false
      idempotent_replay_reused_ledger_entry = $false
      refund_refusal_no_ledger_write = $false
      ledger_refresh_visible = $false
    }
    failure_taxonomy = [PSCustomObject]@{
      failed_action = "none"
      failure_classification = if ($Blockers.Count -gt 0) { [string]$Blockers[0] } else { $noFailure }
      session_missing = -not $SessionMaterialPresent
      runtime_stale = [string](Get-JsonProperty $runtimeCurrent "classification" "browser runtime-current evidence") -ne "runtime_current_verified"
      mutation_opt_in_missing = -not $MutationEnabled
      artifact_write_missing = $true
      artifact_readback_failed = $false
      idempotent_replay_failed = $false
      refund_refusal_missing = $false
      ledger_refresh_missing = $false
      duration_non_numeric = $false
      stale_or_simulated_artifact = $false
      browser_unavailable = $ToolingStatus -ne "available"
    }
    blockers = @($Blockers)
    matrix = [PSCustomObject]@{
      browser_tooling = $ToolingStatus
      admin_ui_reachable = [bool]$AdminUiProbe.Reachable
      control_plane_health_reachable = [bool]$ControlPlaneProbe.Reachable
      session_material_present = $SessionMaterialPresent
      session_material_echoed = $false
      mutation_opt_in_enabled = $MutationEnabled
    }
    durations = [PSCustomObject]@{
      service_readiness_duration_ms = $ServiceReadinessDurationMs
      browser_launch_duration_ms = $unavailable
      context_setup_duration_ms = $unavailable
      page_ready_duration_ms = $unavailable
      selector_snapshot_duration_ms = $unavailable
      submit_latency_ms = $unavailable
      dry_run_plan_duration_ms = $unavailable
      execute_apply_duration_ms = $unavailable
      idempotent_replay_duration_ms = $unavailable
      refund_refusal_duration_ms = $unavailable
      ledger_refresh_duration_ms = $unavailable
    }
    selector_snapshot = [PSCustomObject]@{
      bounded = $true
      missing_selector_keys = @()
      missing_selector_count = 0
    }
    browser_runner = [PSCustomObject]@{
      failed_action = "none"
    }
    duration_field_names = [PSCustomObject]@{
      service_readiness_duration_ms = [string](Get-JsonProperty $durationFields "serviceReadinessDurationMs" "UI browser evidence duration fields")
      browser_launch_duration_ms = [string](Get-JsonProperty $durationFields "browserLaunchDurationMs" "UI browser evidence duration fields")
      context_setup_duration_ms = [string](Get-JsonProperty $durationFields "contextSetupDurationMs" "UI browser evidence duration fields")
      page_ready_duration_ms = [string](Get-JsonProperty $durationFields "pageReadyDurationMs" "UI browser evidence duration fields")
      selector_snapshot_duration_ms = [string](Get-JsonProperty $durationFields "selectorSnapshotDurationMs" "UI browser evidence duration fields")
      submit_latency_ms = [string](Get-JsonProperty $durationFields "submitLatencyMs" "UI browser evidence duration fields")
      dry_run_plan_duration_ms = [string](Get-JsonProperty $durationFields "dryRunPlanDurationMs" "UI browser evidence duration fields")
      execute_apply_duration_ms = [string](Get-JsonProperty $durationFields "executeApplyDurationMs" "UI browser evidence duration fields")
      idempotent_replay_duration_ms = [string](Get-JsonProperty $durationFields "idempotentReplayDurationMs" "UI browser evidence duration fields")
      refund_refusal_duration_ms = [string](Get-JsonProperty $durationFields "refundRefusalDurationMs" "UI browser evidence duration fields")
      ledger_refresh_duration_ms = [string](Get-JsonProperty $durationFields "ledgerRefreshDurationMs" "UI browser evidence duration fields")
    }
    actions = $actions
    secret_safe = [PSCustomObject]@{
      session_material_echoed = $false
      request_material_echoed = $false
      metadata_material_echoed = $false
      contract_forbidden_markers_checked = $true
    }
  }
  Update-BrowserEvidenceClassifications -Handoff $Handoff -Artifact $artifact
  return $artifact
}

function Assert-BrowserEvidenceArtifactShape {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [Parameter(Mandatory = $true)]$Artifact
  )

  Assert-BrowserEvidenceArtifactContract $Handoff
  $contract = Get-JsonProperty $Handoff "browserEvidenceArtifact" "UI handoff"
  $requiredTopLevel = Get-JsonStringArray (Get-JsonProperty $contract "requiredTopLevelFields" "UI browser evidence artifact") "UI browser evidence top-level fields"
  foreach ($field in $requiredTopLevel) {
    [void](Get-JsonProperty $Artifact $field "browser evidence artifact")
  }

  $outcomes = Get-JsonProperty $contract "outcomes" "UI browser evidence artifact"
  $allowedOutcomes = @()
  foreach ($name in @("blocked", "failed", "passed")) {
    $allowedOutcomes += [string](Get-JsonProperty $outcomes $name "UI browser evidence outcomes")
  }
  if ($allowedOutcomes -notcontains [string]$Artifact.outcome) {
    throw "browser evidence artifact outcome '$($Artifact.outcome)' is not allowed"
  }

  $durationFields = Get-JsonProperty $contract "durationFields" "UI browser evidence artifact"
  foreach ($name in @("browserLaunchDurationMs", "contextSetupDurationMs", "dryRunPlanDurationMs", "executeApplyDurationMs", "idempotentReplayDurationMs", "ledgerRefreshDurationMs", "pageReadyDurationMs", "refundRefusalDurationMs", "selectorSnapshotDurationMs", "serviceReadinessDurationMs", "submitLatencyMs")) {
    $field = [string](Get-JsonProperty $durationFields $name "UI browser evidence duration fields")
    [void](Get-JsonProperty $Artifact.durations $field "browser evidence durations")
  }

  foreach ($action in @(Get-JsonProperty $Artifact "actions" "browser evidence artifact")) {
    [void](Get-JsonProperty $action "name" "browser evidence action")
    [void](Get-JsonProperty $action "outcome" "browser evidence action")
    [void](Get-JsonProperty $action "duration_ms" "browser evidence action")
  }

  $runtimeCurrent = Get-JsonProperty $Artifact "runtime_current" "browser evidence artifact"
  foreach ($field in @("classification", "stale_or_unverified", "reason", "source_newest_utc", "container_created_utc", "image_created_utc", "blocker")) {
    [void](Get-JsonProperty $runtimeCurrent $field "browser evidence runtime current")
  }
  if ([string](Get-JsonProperty $runtimeCurrent "classification" "browser evidence runtime current") -notmatch '^runtime_(current_(not_checked|verified)|image_stale_or_unverified)$') {
    throw "browser runtime-current classification must be machine readable"
  }

  $classifications = Get-JsonProperty $Artifact "classifications" "browser evidence classifications"
  foreach ($field in @("runtime_current", "replay", "mutation_pass_artifact", "readback", "failure")) {
    $classification = [string](Get-JsonProperty $classifications $field "browser evidence classifications")
    if ($classification -ne "none" -and $classification -notmatch '^[a-z0-9_]+$') {
      throw "browser evidence classification '$field' must be machine readable"
    }
  }

  $readback = Get-JsonProperty $Artifact "readback" "browser evidence readback"
  foreach ($field in @("classification", "attempted", "fresh", "closure_eligible", "path_bounded")) {
    [void](Get-JsonProperty $readback $field "browser evidence readback")
  }
  if ([string](Get-JsonProperty $readback "classification" "browser evidence readback") -notmatch '^artifact_readback_(not_requested|missing|failed|passed)$') {
    throw "browser readback classification must be machine readable"
  }

  if ($Artifact.PSObject.Properties.Name -contains "selector_snapshot") {
    $snapshot = Get-JsonProperty $Artifact "selector_snapshot" "browser evidence selector snapshot"
    Assert-True ((Get-JsonProperty $snapshot "bounded" "browser evidence selector snapshot") -eq $true) "browser selector snapshot must be bounded"
    foreach ($key in @(Get-JsonProperty $snapshot "missing_selector_keys" "browser evidence selector snapshot")) {
      if ([string]$key -notmatch '^[A-Za-z0-9_]+$') {
        throw "browser selector snapshot key must be a safe selector contract key"
      }
    }
  }
  if ($Artifact.PSObject.Properties.Name -contains "browser_runner") {
    $runner = Get-JsonProperty $Artifact "browser_runner" "browser evidence runner"
    if ([string](Get-JsonProperty $runner "failed_action" "browser evidence runner") -notmatch '^[A-Za-z0-9_]+$') {
      throw "browser runner failed_action must be a safe action key"
    }
  }

  $runtimeArtifact = Get-JsonProperty $Artifact "runtime_current_artifact" "browser evidence runtime artifact"
  foreach ($field in @("linked", "classification", "source", "secret_material_echoed")) {
    [void](Get-JsonProperty $runtimeArtifact $field "browser evidence runtime artifact")
  }
  if ([string](Get-JsonProperty $runtimeArtifact "classification" "browser evidence runtime artifact") -notmatch '^runtime_(current_(not_checked|verified)|image_stale_or_unverified)$') {
    throw "browser runtime artifact classification must be machine readable"
  }
  Assert-True ((Get-JsonProperty $runtimeArtifact "secret_material_echoed" "browser evidence runtime artifact") -eq $false) "browser runtime artifact must not echo secret material"

  $sessionVerification = Get-JsonProperty $Artifact "session_verification" "browser evidence session verification"
  foreach ($field in @("marker", "verified", "secret_omitted", "token_echoed", "cookie_echoed", "header_value_echoed")) {
    [void](Get-JsonProperty $sessionVerification $field "browser evidence session verification")
  }
  Assert-True ([bool](Get-JsonProperty $sessionVerification "secret_omitted" "browser evidence session verification")) "browser session verification must omit secret"
  foreach ($field in @("token_echoed", "cookie_echoed", "header_value_echoed")) {
    Assert-True ((Get-JsonProperty $sessionVerification $field "browser evidence session verification") -eq $false) "browser session verification must not echo $field"
  }

  $mutationControls = Get-JsonProperty $Artifact "mutation_controls" "browser evidence mutation controls"
  foreach ($field in @("mutation_opt_in_enabled", "artifact_write_opt_in_enabled", "artifact_readback_opt_in_enabled", "default_build", "default_mutation", "default_runner")) {
    [void](Get-JsonProperty $mutationControls $field "browser evidence mutation controls")
  }
  foreach ($field in @("default_build", "default_mutation", "default_runner")) {
    Assert-True ((Get-JsonProperty $mutationControls $field "browser evidence mutation controls") -eq $false) "browser mutation controls must keep $field false"
  }

  $apiReadback = Get-JsonProperty $Artifact "api_readback" "browser evidence API readback"
  foreach ($field in @("dry_run_plan", "execute_apply", "idempotent_replay", "refund_refusal", "ledger_refresh")) {
    $value = [string](Get-JsonProperty $apiReadback $field "browser evidence API readback")
    if ($value -notmatch '^[A-Za-z0-9_]+$') {
      throw "browser API readback '$field' must be machine readable"
    }
  }

  $ledgerReadback = Get-JsonProperty $Artifact "ledger_readback" "browser evidence ledger readback"
  foreach ($field in @("applied_ledger_entry_visible", "idempotent_replay_reused_ledger_entry", "refund_refusal_no_ledger_write", "ledger_refresh_visible")) {
    [void](Get-JsonProperty $ledgerReadback $field "browser evidence ledger readback")
  }

  $failureTaxonomy = Get-JsonProperty $Artifact "failure_taxonomy" "browser evidence failure taxonomy"
  foreach ($field in @("failed_action", "failure_classification", "session_missing", "runtime_stale", "mutation_opt_in_missing", "artifact_write_missing", "artifact_readback_failed", "idempotent_replay_failed", "refund_refusal_missing", "ledger_refresh_missing", "duration_non_numeric", "stale_or_simulated_artifact", "browser_unavailable")) {
    [void](Get-JsonProperty $failureTaxonomy $field "browser evidence failure taxonomy")
  }
  foreach ($field in @("failed_action", "failure_classification")) {
    $value = [string](Get-JsonProperty $failureTaxonomy $field "browser evidence failure taxonomy")
    if ($value -ne "none" -and $value -notmatch '^[A-Za-z0-9_]+$') {
      throw "browser failure taxonomy '$field' must be machine readable"
    }
  }

  Assert-True ((Get-JsonProperty $Artifact.secret_safe "session_material_echoed" "browser evidence secret-safe") -eq $false) "browser evidence must not echo session material"
  $json = $Artifact | ConvertTo-Json -Depth 32 -Compress
  Assert-SecretSafeContent -Content $json -Context "browser evidence artifact"
}

function Assert-BrowserEvidenceArtifactFreshness {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [Parameter(Mandatory = $true)]$Artifact
  )

  Assert-BrowserEvidenceArtifactShape -Handoff $Handoff -Artifact $Artifact
  $runner = Get-JsonProperty $Handoff "browserRunnerReadiness" "UI handoff"
  $roundTrip = Get-JsonProperty $runner "artifactRoundTrip" "UI browser runner artifact round-trip"
  $artifactWriteRead = Get-JsonProperty $runner "artifactWriteRead" "UI browser runner artifact write/read"
  $staleRefusal = Get-JsonProperty $artifactWriteRead "staleRefusal" "UI browser runner artifact stale refusal"
  $freshness = Get-JsonProperty $Artifact "freshness" "browser evidence artifact"

  Assert-Equal (Get-JsonProperty $freshness "marker" "browser evidence freshness") (Get-JsonProperty $roundTrip "freshnessMarker" "UI browser runner artifact round-trip") "browser evidence freshness marker"
  Assert-True ((Get-JsonProperty $freshness "handoff_fresh" "browser evidence freshness") -eq $true) "browser evidence handoff must be fresh"
  Assert-True ((Get-JsonProperty $Artifact.provenance "handoff_fresh" "browser evidence provenance") -eq $true) "browser evidence provenance handoff must be fresh"

  if ([bool](Get-JsonProperty $staleRefusal "requireCurrentGitCommit" "UI browser runner artifact stale refusal")) {
    Assert-Equal (Get-JsonProperty $freshness "git_commit" "browser evidence freshness") (Get-CurrentGitCommit) "browser evidence git commit freshness"
  }

  $generatedAt = Convert-JsonTimestampToUtc (Get-JsonProperty $Artifact "generated_at" "browser evidence artifact")
  $maxAgeMinutes = [int](Get-JsonProperty $staleRefusal "maxGeneratedAgeMinutes" "UI browser runner artifact stale refusal")
  $age = (Get-Date).ToUniversalTime() - $generatedAt
  if ($age.TotalMinutes -gt $maxAgeMinutes) {
    throw "browser evidence artifact is stale by generated_at"
  }
}

function Assert-StaleBrowserEvidenceArtifactRefusal {
  param([Parameter(Mandatory = $true)]$Handoff)

  if (Test-BrowserLiveMutationAttemptOptIn) {
    Write-SafeHost "browser_artifact_stale_refusal_selftest_skipped_for_live_opt_in=true"
    return
  }

  $probe = [PSCustomObject]@{ Reachable = $true }
  $oldGeneratedAt = (Get-Date).ToUniversalTime().AddHours(-2).ToString("o")
  $missingFreshnessArtifact = New-BrowserEvidenceArtifact -Handoff $Handoff -Outcome "passed" -Blockers @() -ToolingStatus "available" -AdminUiProbe $probe -ControlPlaneProbe $probe -MutationEnabled $true -SessionMaterialPresent $true -ServiceReadinessDurationMs 0
  $missingFreshnessArtifact.PSObject.Properties.Remove("freshness")
  $staleArtifacts = @(
    (New-BrowserEvidenceArtifact -Handoff $Handoff -Outcome "passed" -Blockers @() -ToolingStatus "available" -AdminUiProbe $probe -ControlPlaneProbe $probe -MutationEnabled $true -SessionMaterialPresent $true -ServiceReadinessDurationMs 0 -GitCommit "old-commit"),
    (New-BrowserEvidenceArtifact -Handoff $Handoff -Outcome "passed" -Blockers @() -ToolingStatus "available" -AdminUiProbe $probe -ControlPlaneProbe $probe -MutationEnabled $true -SessionMaterialPresent $true -ServiceReadinessDurationMs 0 -GeneratedAt $oldGeneratedAt),
    (New-BrowserEvidenceArtifact -Handoff $Handoff -Outcome "passed" -Blockers @() -ToolingStatus "available" -AdminUiProbe $probe -ControlPlaneProbe $probe -MutationEnabled $true -SessionMaterialPresent $true -ServiceReadinessDurationMs 0 -HandoffFresh $false),
    $missingFreshnessArtifact
  )

  foreach ($artifact in $staleArtifacts) {
    $refused = $false
    try {
      Assert-BrowserEvidenceArtifactFreshness -Handoff $Handoff -Artifact $artifact
    } catch {
      $refused = $true
    }
    Assert-True $refused "stale browser evidence artifact must be refused"
  }
}

function Write-BrowserEvidenceArtifactDryRun {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [Parameter(Mandatory = $true)][string]$ToolingStatus,
    [Parameter(Mandatory = $true)]$AdminUiProbe,
    [Parameter(Mandatory = $true)]$ControlPlaneProbe,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Blockers,
    [Parameter(Mandatory = $true)][bool]$MutationEnabled,
    [Parameter(Mandatory = $true)][bool]$SessionMaterialPresent,
    [Parameter(Mandatory = $true)][int]$ServiceReadinessDurationMs
  )

  Assert-BrowserEvidenceArtifactContract $Handoff
  $blockedArtifact = New-BrowserEvidenceArtifact -Handoff $Handoff -Outcome "blocked" -Blockers $Blockers -ToolingStatus $ToolingStatus -AdminUiProbe $AdminUiProbe -ControlPlaneProbe $ControlPlaneProbe -MutationEnabled $MutationEnabled -SessionMaterialPresent $SessionMaterialPresent -ServiceReadinessDurationMs $ServiceReadinessDurationMs
  $passArtifact = New-BrowserEvidenceArtifact -Handoff $Handoff -Outcome "passed" -Blockers @() -ToolingStatus "available" -AdminUiProbe ([PSCustomObject]@{ Reachable = $true }) -ControlPlaneProbe ([PSCustomObject]@{ Reachable = $true }) -MutationEnabled $true -SessionMaterialPresent $true -ServiceReadinessDurationMs 0
  $failArtifact = New-BrowserEvidenceArtifact -Handoff $Handoff -Outcome "failed" -Blockers @("state_mismatch") -ToolingStatus "available" -AdminUiProbe ([PSCustomObject]@{ Reachable = $true }) -ControlPlaneProbe ([PSCustomObject]@{ Reachable = $true }) -MutationEnabled $true -SessionMaterialPresent $true -ServiceReadinessDurationMs 0

  Assert-BrowserEvidenceArtifactShape -Handoff $Handoff -Artifact $blockedArtifact
  Assert-BrowserEvidenceArtifactShape -Handoff $Handoff -Artifact $passArtifact
  Assert-BrowserEvidenceArtifactShape -Handoff $Handoff -Artifact $failArtifact

  $summary = $blockedArtifact | ConvertTo-Json -Depth 32 -Compress
  Write-SafeHost "Browser ledger execute evidence artifact dry-run:"
  Write-SafeHost "browser_evidence_artifact=$($blockedArtifact.artifact)"
  Write-SafeHost "browser_evidence_outcome=$($blockedArtifact.outcome)"
  Write-SafeHost "browser_evidence_blockers=$($blockedArtifact.blockers -join '+')"
  Write-SafeHost "browser_evidence_secret_safe=true"
  Write-SafeHost "browser_evidence_json=$summary"
}

function Assert-BrowserRunnerReadinessContract {
  param([Parameter(Mandatory = $true)]$Handoff)

  $runner = Get-JsonProperty $Handoff "browserRunnerReadiness" "UI handoff"
  Assert-Equal (Get-JsonProperty $runner "defaultMode" "UI browser runner readiness") "runner_readiness_only" "UI browser runner default mode"
  Assert-Equal (Get-JsonProperty $runner "selectorSource" "UI browser runner readiness") "ledgerAdjustmentExecuteLiveSmokeContract.selectors" "UI browser runner selector source"
  Assert-Equal (Get-JsonProperty $runner "statusSource" "UI browser runner readiness") "ledgerAdjustmentExecuteLiveSmokeHandoff.readinessStates" "UI browser runner status source"

  $permission = Get-JsonProperty $runner "actionPermission" "UI browser runner readiness"
  foreach ($name in @(
      "requireBrowserToolingAvailable",
      "requireAdminUiReachable",
      "requireControlPlaneHealthReachable",
      "requireSessionMaterialPresent",
      "requireMutationOptIn",
      "requireStableActionSelectors"
    )) {
    Assert-True ([bool](Get-JsonProperty $permission $name "UI browser runner action permission")) "UI browser runner must require $name"
  }
  Assert-True ((Get-JsonProperty $permission "defaultClicksAdminUiActions" "UI browser runner action permission") -eq $false) "UI browser runner must not click Admin UI actions by default"

  $roundTrip = Get-JsonProperty $runner "artifactRoundTrip" "UI browser runner readiness"
  Assert-Equal (Get-JsonProperty $roundTrip "freshnessMarker" "UI browser runner artifact round-trip") "artifact_roundtrip_fresh" "UI browser runner artifact round-trip freshness marker"
  Assert-Equal (Get-JsonProperty $roundTrip "outputMarker" "UI browser runner artifact round-trip") "browser_runner_evidence_json" "UI browser runner artifact round-trip output marker"
  Assert-Equal (Get-JsonProperty $roundTrip "writeMode" "UI browser runner artifact round-trip") "json_roundtrip_only" "UI browser runner artifact round-trip write mode"

  $writeRead = Get-JsonProperty $runner "artifactWriteRead" "UI browser runner artifact write/read"
  Assert-True ((Get-JsonProperty $writeRead "defaultWritesArtifact" "UI browser runner artifact write/read") -eq $false) "UI browser runner must not write artifact by default"
  Assert-Equal (Get-JsonProperty $writeRead "defaultPath" "UI browser runner artifact write/read") "artifacts/billing_execute_browser_live_e2e_evidence.json" "UI browser runner artifact default path"
  Assert-Equal (Get-JsonProperty $writeRead "env" "UI browser runner artifact write/read") "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_ARTIFACT_WRITE" "UI browser runner artifact write env"
  Assert-Equal (Get-JsonProperty $writeRead "flag" "UI browser runner artifact write/read") "-BrowserEvidenceArtifactWriteOptIn" "UI browser runner artifact write flag"
  Assert-Equal (Get-JsonProperty $writeRead "pathEnv" "UI browser runner artifact write/read") "CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_ARTIFACT_PATH" "UI browser runner artifact path env"
  Assert-Equal (Get-JsonProperty $writeRead "requiredValue" "UI browser runner artifact write/read") "1" "UI browser runner artifact write env value"
  Assert-Equal (Get-JsonProperty $writeRead "writeMode" "UI browser runner artifact write/read") "explicit_opt_in_only" "UI browser runner artifact write mode"
  [void](Resolve-BoundedEvidenceArtifactPath ([string](Get-JsonProperty $writeRead "defaultPath" "UI browser runner artifact write/read")))

  $durationCaptureNames = Get-JsonProperty $runner "durationCaptureNames" "UI browser runner readiness"
  $evidenceContract = Get-JsonProperty $Handoff "browserEvidenceArtifact" "UI handoff"
  $durationFields = Get-JsonProperty $evidenceContract "durationFields" "UI browser evidence artifact"
  foreach ($name in @("browserLaunchDurationMs", "contextSetupDurationMs", "dryRunPlanDurationMs", "executeApplyDurationMs", "idempotentReplayDurationMs", "ledgerRefreshDurationMs", "pageReadyDurationMs", "refundRefusalDurationMs", "selectorSnapshotDurationMs", "serviceReadinessDurationMs", "submitLatencyMs")) {
    Assert-Equal (Get-JsonProperty $durationCaptureNames $name "UI browser runner duration capture names") (Get-JsonProperty $durationFields $name "UI browser evidence duration fields") "UI browser runner duration capture $name"
  }

  $readinessFields = Get-JsonProperty $runner "readinessFields" "UI browser runner readiness"
  foreach ($name in @("actionsAllowed", "adminUiUrlSafe", "browserAvailable", "controlPlaneUrlSafe", "mutationOptInEnabled", "noMutationDefault", "selectorReadiness", "sessionMaterialPresent")) {
    $field = [string](Get-JsonProperty $readinessFields $name "UI browser runner readiness fields")
    if ($field -notmatch '^[a-z0-9_]+$') {
      throw "UI browser runner readiness field '$name' must be machine readable"
    }
  }
}

function Test-BrowserEvidenceArtifactWriteOptIn {
  param([Parameter(Mandatory = $true)]$Handoff)

  $runner = Get-JsonProperty $Handoff "browserRunnerReadiness" "UI handoff"
  $writeRead = Get-JsonProperty $runner "artifactWriteRead" "UI browser runner artifact write/read"
  $envName = [string](Get-JsonProperty $writeRead "env" "UI browser runner artifact write/read")
  $requiredValue = [string](Get-JsonProperty $writeRead "requiredValue" "UI browser runner artifact write/read")
  return $BrowserEvidenceArtifactWriteOptIn -or ([Environment]::GetEnvironmentVariable($envName) -eq $requiredValue)
}

function Get-ActionSelectorReadiness {
  param([Parameter(Mandatory = $true)]$Handoff)

  $selectors = Get-JsonProperty $Handoff "selectors" "UI handoff"
  $actionPlan = Get-JsonProperty $Handoff "browserActionPlan" "UI handoff"
  $missing = @()
  foreach ($step in @(Get-JsonProperty $actionPlan "steps" "UI browser action plan")) {
    $selectorKey = [string](Get-JsonProperty $step "selector" "UI browser action plan step")
    try {
      [void](Get-JsonProperty $selectors $selectorKey "UI browser action selector")
    } catch {
      $missing += $selectorKey
    }
  }

  if ($missing.Count -gt 0) {
    return "missing:$($missing -join '+')"
  }
  return "ready"
}

function Write-BrowserRunnerReadinessGate {
  param(
    [Parameter(Mandatory = $true)]$Handoff,
    [Parameter(Mandatory = $true)][string]$ToolingStatus,
    [Parameter(Mandatory = $true)]$AdminUiProbe,
    [Parameter(Mandatory = $true)]$ControlPlaneProbe,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Blockers,
    [Parameter(Mandatory = $true)][bool]$MutationEnabled,
    [Parameter(Mandatory = $true)][bool]$SessionMaterialPresent,
    [Parameter(Mandatory = $true)][int]$ServiceReadinessDurationMs
  )

  Assert-BrowserRunnerReadinessContract $Handoff
  $runner = Get-JsonProperty $Handoff "browserRunnerReadiness" "UI handoff"
  $readinessFields = Get-JsonProperty $runner "readinessFields" "UI browser runner readiness"
  $roundTrip = Get-JsonProperty $runner "artifactRoundTrip" "UI browser runner artifact round-trip"
  $selectorReadiness = Get-ActionSelectorReadiness $Handoff
  $actionsAllowed = (
    $ToolingStatus -eq "available" -and
    [bool]$AdminUiProbe.Reachable -and
    [bool]$ControlPlaneProbe.Reachable -and
    $SessionMaterialPresent -and
    $MutationEnabled -and
    $selectorReadiness -eq "ready"
  )

  $outcome = if ($actionsAllowed) { "passed" } else { "blocked" }
  $runnerBlockers = @($Blockers)
  if ($selectorReadiness -ne "ready") {
    $runnerBlockers += "selector_unavailable"
  }
  $artifact = New-BrowserEvidenceArtifact -Handoff $Handoff -Outcome $outcome -Blockers $runnerBlockers -ToolingStatus $ToolingStatus -AdminUiProbe $AdminUiProbe -ControlPlaneProbe $ControlPlaneProbe -MutationEnabled $MutationEnabled -SessionMaterialPresent $SessionMaterialPresent -ServiceReadinessDurationMs $ServiceReadinessDurationMs
  $artifactJson = $artifact | ConvertTo-Json -Depth 32 -Compress
  $roundTripArtifact = Read-Json $artifactJson
  Assert-BrowserEvidenceArtifactShape -Handoff $Handoff -Artifact $roundTripArtifact
  $roundTripGeneratedAt = Convert-JsonTimestampToUtc (Get-JsonProperty $roundTripArtifact "generated_at" "browser runner roundtrip artifact")
  Write-SafeHost "browser_runner_roundtrip_generated_at=$($roundTripGeneratedAt.ToString("o"))"
  Write-SafeHost "browser_runner_roundtrip_age_minutes=$([Math]::Round(((Get-Date).ToUniversalTime() - $roundTripGeneratedAt).TotalMinutes, 4))"
  Assert-BrowserEvidenceArtifactFreshness -Handoff $Handoff -Artifact $roundTripArtifact
  if (-not (Test-BrowserLiveMutationAttemptOptIn)) {
    Assert-StaleBrowserEvidenceArtifactRefusal -Handoff $Handoff
  }

  $writeRead = Get-JsonProperty $runner "artifactWriteRead" "UI browser runner artifact write/read"
  $writeEnabled = (Test-BrowserEvidenceArtifactWriteOptIn $Handoff) -and -not $BrowserLiveRunnerExecutionOptIn
  $artifactPath = Resolve-BoundedEvidenceArtifactPath $BrowserEvidenceArtifactPath
  if ($writeEnabled) {
    if ($artifact.PSObject.Properties.Name -contains "mutation_controls") {
      $artifact.mutation_controls.artifact_write_opt_in_enabled = $true
      $artifact.mutation_controls.artifact_readback_opt_in_enabled = $true
    }
    $artifactDirectory = Split-Path -Path $artifactPath -Parent
    if (-not (Test-Path $artifactDirectory)) {
      New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
    }
    Set-Content -Path $artifactPath -Value $artifactJson -Encoding UTF8
    $readBack = Read-JsonFile $artifactPath
    Assert-BrowserEvidenceArtifactFreshness -Handoff $Handoff -Artifact $readBack
    $readbackClosureEligible = Test-BrowserMutationPassArtifactClosure -Handoff $Handoff -Artifact $readBack
    $readbackClassificationName = if ($readbackClosureEligible) { "passed" } else { "failed" }
    $readbackClassification = Get-BrowserEvidenceClassificationValue -Handoff $Handoff -Group "readback" -Name $readbackClassificationName
    Set-BrowserArtifactReadbackResult -Artifact $artifact -Classification $readbackClassification -Attempted $true -Fresh $true -ClosureEligible $readbackClosureEligible
    if ($artifact.PSObject.Properties.Name -contains "failure_taxonomy") {
      $artifact.failure_taxonomy.artifact_write_missing = $false
      $artifact.failure_taxonomy.artifact_readback_failed = -not $readbackClosureEligible
    }
    Update-BrowserEvidenceClassifications -Handoff $Handoff -Artifact $artifact
    $artifactJson = $artifact | ConvertTo-Json -Depth 32 -Compress
    Set-Content -Path $artifactPath -Value $artifactJson -Encoding UTF8
    $readBack = Read-JsonFile $artifactPath
    Assert-BrowserEvidenceArtifactFreshness -Handoff $Handoff -Artifact $readBack
  }

  Write-SafeHost "Browser ledger execute runner readiness gate:"
  Write-SafeHost "$([string](Get-JsonProperty $readinessFields "actionsAllowed" "UI browser runner readiness fields"))=$(Format-BoolMarker $actionsAllowed)"
  Write-SafeHost "$([string](Get-JsonProperty $readinessFields "browserAvailable" "UI browser runner readiness fields"))=$(Format-BoolMarker ($ToolingStatus -eq "available"))"
  Write-SafeHost "$([string](Get-JsonProperty $readinessFields "adminUiUrlSafe" "UI browser runner readiness fields"))=true"
  Write-SafeHost "$([string](Get-JsonProperty $readinessFields "controlPlaneUrlSafe" "UI browser runner readiness fields"))=true"
  Write-SafeHost "$([string](Get-JsonProperty $readinessFields "sessionMaterialPresent" "UI browser runner readiness fields"))=$(Format-BoolMarker $SessionMaterialPresent)"
  Write-SafeHost "$([string](Get-JsonProperty $readinessFields "mutationOptInEnabled" "UI browser runner readiness fields"))=$(Format-BoolMarker $MutationEnabled)"
  Write-SafeHost "$([string](Get-JsonProperty $readinessFields "selectorReadiness" "UI browser runner readiness fields"))=$selectorReadiness"
  Write-SafeHost "$([string](Get-JsonProperty $readinessFields "noMutationDefault" "UI browser runner readiness fields"))=true"
  Write-SafeHost "$([string](Get-JsonProperty $roundTrip "freshnessMarker" "UI browser runner artifact round-trip"))=true"
  Write-SafeHost "browser_artifact_write_enabled=$(Format-BoolMarker $writeEnabled)"
  Write-SafeHost "browser_artifact_write_mode=$([string](Get-JsonProperty $writeRead "writeMode" "UI browser runner artifact write/read"))"
  Write-SafeHost "browser_artifact_path_bounded=true"
  Write-SafeHost "browser_artifact_readback_fresh=$(Format-BoolMarker $writeEnabled)"
  Write-SafeHost "browser_artifact_readback_classification=$($artifact.classifications.readback)"
  Write-SafeHost "browser_artifact_stale_refusal=true"
  Write-SafeHost "$([string](Get-JsonProperty $roundTrip "outputMarker" "UI browser runner artifact round-trip"))=$artifactJson"
}

function Assert-BrowserLiveSmokeHarnessPreflight {
  param([Parameter(Mandatory = $true)]$Handoff)

  Assert-UiSmokeHandoffFreshness $Handoff
  $adminUiUrl = Get-SafeSmokeUrlSummary $AdminUiBaseUrl "Admin UI URL"
  $backendUrl = Get-SafeSmokeUrlSummary $ControlPlaneBaseUrl "Control Plane backend URL"
  $browserPreflight = Get-JsonProperty $Handoff "browserPreflight" "UI handoff"
  $healthProbePaths = Get-JsonProperty $browserPreflight "healthProbePaths" "UI browser preflight"
  $metricMarkers = Get-JsonProperty $browserPreflight "metricMarkers" "UI browser preflight"
  $adminUiReachableMarker = [string](Get-JsonProperty $metricMarkers "adminUiReachable" "UI browser preflight metric markers")
  $controlPlaneHealthReachableMarker = [string](Get-JsonProperty $metricMarkers "controlPlaneHealthReachable" "UI browser preflight metric markers")
  $readinessMarker = [string](Get-JsonProperty $metricMarkers "readiness" "UI browser preflight metric markers")
  $serviceBlockerMarker = [string](Get-JsonProperty $metricMarkers "serviceBlocker" "UI browser preflight metric markers")
  $serviceProbeTimeoutMarker = [string](Get-JsonProperty $metricMarkers "serviceProbeTimeoutMs" "UI browser preflight metric markers")
  $serviceReadinessDurationMarker = [string](Get-JsonProperty $metricMarkers "serviceReadinessDurationMs" "UI browser preflight metric markers")
  $sessionMaterialEchoedMarker = [string](Get-JsonProperty $metricMarkers "sessionMaterialEchoed" "UI browser preflight metric markers")
  $sessionMaterialPresentMarker = [string](Get-JsonProperty $metricMarkers "sessionMaterialPresent" "UI browser preflight metric markers")
  $submitLatencyMarker = [string](Get-JsonProperty $metricMarkers "submitLatencyMs" "UI browser preflight metric markers")
  $ledgerRefreshMarker = [string](Get-JsonProperty $metricMarkers "ledgerRefreshDurationMs" "UI browser preflight metric markers")
  $unavailableMarker = [string](Get-JsonProperty $metricMarkers "unavailable" "UI browser preflight metric markers")
  $toolingStatus = Get-BrowserToolingStatus
  $serviceTimer = [Diagnostics.Stopwatch]::StartNew()
  $adminUiProbeUrl = Join-SmokeProbeUrl $AdminUiBaseUrl ([string](Get-JsonProperty $healthProbePaths "adminUi" "UI browser preflight health paths"))
  $controlPlaneProbeUrl = Join-SmokeProbeUrl $ControlPlaneBaseUrl ([string](Get-JsonProperty $healthProbePaths "controlPlane" "UI browser preflight health paths"))
  $adminUiProbe = Invoke-ServiceReadinessProbe -Name "admin_ui" -Url $adminUiProbeUrl -TimeoutMs $BrowserProbeTimeoutMilliseconds -ReachableStatusCodes @(200, 304)
  $controlPlaneProbe = Invoke-ServiceReadinessProbe -Name "control_plane_health" -Url $controlPlaneProbeUrl -TimeoutMs $BrowserProbeTimeoutMilliseconds -ReachableStatusCodes @(200)
  $adminUiDevServerBootstrap = Start-BrowserAdminUiDevServerBootstrap -Handoff $Handoff -InitialProbe $adminUiProbe
  if ([bool]$adminUiDevServerBootstrap.Probe.Reachable) {
    $adminUiProbe = $adminUiDevServerBootstrap.Probe
  }
  $serviceTimer.Stop()
  try {
    $serviceBlocker = Get-ServiceBlockerMarker -ToolingStatus $toolingStatus -AdminUiProbe $adminUiProbe -ControlPlaneProbe $controlPlaneProbe
    $sessionMaterialPresent = Test-BrowserAdminSessionHandoffPresent $Handoff
    $runbook = Get-JsonProperty $Handoff "browserLiveRunbook" "UI handoff"
    $mutationEnabled = Test-BrowserMutationOptIn $runbook
    $liveBlockers = @()
    if ($serviceBlocker -ne "none") {
      $liveBlockers += @($serviceBlocker.Split("+") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    if (-not $sessionMaterialPresent) {
      $liveBlockers += "session_material_missing"
    }
    if (-not $mutationEnabled) {
      $liveBlockers += "live_mutation_opt_in_missing"
    }
    $readiness = "ready"
    if ($serviceBlocker -ne "none") {
      $readiness = $unavailableMarker
    }

    Write-SafeHost "Browser ledger execute smoke harness preflight:"
    Write-SafeHost "$readinessMarker=$readiness"
    Write-SafeHost "browser_tooling=$toolingStatus"
    Write-SafeHost "$adminUiReachableMarker=$(Format-BoolMarker ([bool]$adminUiProbe.Reachable))"
    Write-SafeHost "admin_ui_probe_classification=$($adminUiProbe.Classification)"
    Write-SafeHost "admin_ui_probe_duration_ms=$($adminUiProbe.DurationMs)"
    Write-SafeHost "$controlPlaneHealthReachableMarker=$(Format-BoolMarker ([bool]$controlPlaneProbe.Reachable))"
    Write-SafeHost "control_plane_health_probe_classification=$($controlPlaneProbe.Classification)"
    Write-SafeHost "control_plane_health_probe_duration_ms=$($controlPlaneProbe.DurationMs)"
    Write-SafeHost "$serviceBlockerMarker=$serviceBlocker"
    Write-SafeHost "$serviceProbeTimeoutMarker=$BrowserProbeTimeoutMilliseconds"
    Write-SafeHost "$serviceReadinessDurationMarker=$([int]$serviceTimer.ElapsedMilliseconds)"
    Write-SafeHost "$sessionMaterialPresentMarker=$(Format-BoolMarker $sessionMaterialPresent)"
    Write-SafeHost "$sessionMaterialEchoedMarker=false"
    Write-SafeHost "admin_ui_url=$adminUiUrl"
    Write-SafeHost "control_plane_backend_url=$backendUrl"
    Write-SafeHost "handoff_artifact=fresh"
    Write-SafeHost "$submitLatencyMarker=$unavailableMarker"
    Write-SafeHost "$ledgerRefreshMarker=$unavailableMarker"
    Write-BrowserLiveRunbookGate -Handoff $Handoff -ToolingStatus $toolingStatus -AdminUiProbe $adminUiProbe -ControlPlaneProbe $controlPlaneProbe
    Write-BrowserEvidenceArtifactDryRun -Handoff $Handoff -ToolingStatus $toolingStatus -AdminUiProbe $adminUiProbe -ControlPlaneProbe $controlPlaneProbe -Blockers $liveBlockers -MutationEnabled $mutationEnabled -SessionMaterialPresent $sessionMaterialPresent -ServiceReadinessDurationMs ([int]$serviceTimer.ElapsedMilliseconds)
    Write-BrowserRunnerReadinessGate -Handoff $Handoff -ToolingStatus $toolingStatus -AdminUiProbe $adminUiProbe -ControlPlaneProbe $controlPlaneProbe -Blockers $liveBlockers -MutationEnabled $mutationEnabled -SessionMaterialPresent $sessionMaterialPresent -ServiceReadinessDurationMs ([int]$serviceTimer.ElapsedMilliseconds)
    Write-BrowserPlaywrightLaunchReadinessBoundary -Handoff $Handoff -ToolingStatus $toolingStatus -AdminUiProbe $adminUiProbe -ControlPlaneProbe $controlPlaneProbe -MutationEnabled $mutationEnabled -SessionMaterialPresent $sessionMaterialPresent -ServiceReadinessDurationMs ([int]$serviceTimer.ElapsedMilliseconds)
    Write-BrowserMutationPassArtifactClosureGate -Handoff $Handoff -ToolingStatus $toolingStatus -AdminUiProbe $adminUiProbe -ControlPlaneProbe $controlPlaneProbe -Blockers $liveBlockers -MutationEnabled $mutationEnabled -SessionMaterialPresent $sessionMaterialPresent -ServiceReadinessDurationMs ([int]$serviceTimer.ElapsedMilliseconds)
    Write-BrowserMutationFinalDodMatrix -Handoff $Handoff
    Write-RuntimeCurrentEvidenceAcceptanceMatrix -Handoff $Handoff
    Write-RuntimeCurrentFinalClosureAudit -Handoff $Handoff
    Write-BrowserMutationEvidenceWatcherFinalGuard -Handoff $Handoff
    Write-RuntimeCurrentOperatorHandoffPack -Handoff $Handoff
    Write-BrowserLiveRunnerExecutionBridgeGate -Handoff $Handoff -ToolingStatus $toolingStatus -AdminUiProbe $adminUiProbe -ControlPlaneProbe $controlPlaneProbe -MutationEnabled $mutationEnabled -SessionMaterialPresent $sessionMaterialPresent
    Write-BrowserLivePassArtifactReadbackGate -Handoff $Handoff -MutationEnabled $mutationEnabled -SessionMaterialPresent $sessionMaterialPresent
    Write-BrowserLiveEnvironmentBootstrapAttempt -Handoff $Handoff -ToolingStatus $toolingStatus -AdminUiProbe $adminUiProbe -ControlPlaneProbe $controlPlaneProbe -AdminUiDevServerBootstrap $adminUiDevServerBootstrap -MutationEnabled $mutationEnabled -SessionMaterialPresent $sessionMaterialPresent -ServiceReadinessDurationMs ([int]$serviceTimer.ElapsedMilliseconds)
  } finally {
    Stop-BrowserAdminUiDevServerBootstrap $adminUiDevServerBootstrap
  }
}

function Assert-AdminSourceMarkers {
  if (-not (Test-Path $adminSourcePath)) {
    throw "missing apps\control-plane\src\admin.rs"
  }

  $source = Get-Content -Path $adminSourcePath -Raw
  foreach ($needle in @(
      "execute_ledger_adjustment",
      ".begin()",
      "get_ledger_entry_for_adjustment_execute_tx",
      "get_confirmed_refund_credit_summary_for_update_tx",
      "get_ledger_adjustment_dedupe_entry_for_update_tx",
      "insert_ledger_adjustment_entry_tx",
      "insert_admin_audit_log_tx",
      "tx.commit()",
      "rollback_ledger_adjustment_execute_tx"
    )) {
    if (-not $source.Contains($needle)) {
      throw "admin source missing transactional marker '$needle'"
    }
  }
}

function Assert-LiveEnvironmentAvailable {
  try {
    $docker = Get-DockerCommand
    $services = & $docker compose -f $ComposeFile ps --status running --services 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "docker compose ps failed: $(Redact-SecretLikeString (($services | Out-String).Trim()))"
    }
  } catch {
    throw "docker compose is unavailable or compose file cannot be inspected: $($_.Exception.Message)"
  }

  $runningServices = @($services | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  foreach ($service in @("postgres", "control-plane")) {
    if ($runningServices -notcontains $service) {
      $runningSummary = if ($runningServices.Count -gt 0) { $runningServices -join "," } else { "none" }
      throw "compose service '$service' is not running; running_services=$runningSummary; start deploy/docker-compose/docker-compose.yml before live smoke"
    }
  }

  [void](Invoke-ComposePsql "select 1;")
  $probe = Invoke-ControlPlaneRequest -Method GET -Path "/admin/auth/me" -SessionToken ""
  Assert-StatusAny $probe @(200, 401, 403)
}

function Assert-MigratedSchemaAndSeed {
  $schema = Invoke-ComposePsqlJson @"
select json_build_object(
  'ledger_entries', to_regclass('public.ledger_entries') is not null,
  'audit_logs', to_regclass('public.audit_logs') is not null,
  'wallets', to_regclass('public.wallets') is not null,
  'tenant_count', (select count(*) from tenants where id = '00000000-0000-0000-0000-000000000001'),
  'project_count', (select count(*) from projects where tenant_id = '00000000-0000-0000-0000-000000000001' and id = '00000000-0000-0000-0000-000000000020'),
  'wallet_count', (select count(*) from wallets where tenant_id = '00000000-0000-0000-0000-000000000001' and id = '00000000-0000-0000-0000-000000000040' and status in ('active', 'suspended')),
  'admin_count', (select count(*) from users where tenant_id = '00000000-0000-0000-0000-000000000001' and email = 'admin@example.com' and status = 'active')
)::text;
"@

  foreach ($flag in @("ledger_entries", "audit_logs", "wallets")) {
    Assert-True ([bool]$schema.$flag) "migrated schema missing $flag"
  }
  Assert-True ([int]$schema.tenant_count -ge 1) "default tenant seed missing"
  Assert-True ([int]$schema.project_count -ge 1) "default project seed missing"
  Assert-True ([int]$schema.wallet_count -ge 1) "default wallet seed missing"
  Assert-True ([int]$schema.admin_count -ge 1) "dev admin seed missing"
}

function New-RelatedDebit {
  param(
    [Parameter(Mandatory = $true)][string]$Amount,
    [Parameter(Mandatory = $true)][string]$Label
  )

  $entryId = New-SmokeGuid
  $idem = "control-plane-ledger-adjustment-execute-smoke:$($script:SmokeRunId):$Label"
  $safeIdem = Escape-SqlLiteral $idem
  $safeRunId = Escape-SqlLiteral $script:SmokeRunId
  $safeLabel = Escape-SqlLiteral $Label
  [void](Invoke-ComposePsql @"
insert into ledger_entries (
  id, tenant_id, project_id, wallet_id, entry_type, amount, currency, status, idempotency_key, metadata
)
values (
  '$entryId',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000020',
  '00000000-0000-0000-0000-000000000040',
  'settle',
  $Amount::numeric,
  'USD',
  'confirmed',
  '$safeIdem',
  jsonb_build_object(
    'smoke', 'control_plane_ledger_adjustment_execute_live_smoke',
    'run_id', '$safeRunId',
    'label', '$safeLabel'
  )
);
"@)

  $script:SourceLedgerEntryIds += $entryId
  return $entryId
}

function New-RefundExecuteBody {
  param(
    [Parameter(Mandatory = $true)][string]$RelatedLedgerEntryId,
    [Parameter(Mandatory = $true)][string]$Amount,
    [string]$Reason = "live smoke refund"
  )

  return [ordered]@{
    mode = "execute"
    operation = "refund"
    amount = $Amount
    currency = "USD"
    related_ledger_entry_id = $RelatedLedgerEntryId
    reason = $Reason
  }
}

function Invoke-LedgerAdjustmentExecute {
  param([Parameter(Mandatory = $true)]$Body)

  $response = Invoke-ControlPlaneRequest -Method POST -Path "/admin/ledger/adjustments/dry-run" -Body $Body
  Assert-SecretSafeContent -Content $response.Content -Context "ledger adjustment execute response"
  return $response
}

function Get-CreditAndAuditEvidence {
  param([Parameter(Mandatory = $true)][string]$SourceLedgerEntryId)

  return Invoke-ComposePsqlJson @"
select json_build_object(
  'credit_count', (
    select count(*)
    from ledger_entries
    where tenant_id = '00000000-0000-0000-0000-000000000001'
      and related_ledger_entry_id = '$SourceLedgerEntryId'
      and entry_type in ('refund', 'adjust')
      and status = 'confirmed'
      and amount > 0
  ),
  'audit_count', (
    select count(*)
    from audit_logs al
    join ledger_entries le on le.tenant_id = al.tenant_id and le.id = al.resource_id
    where al.tenant_id = '00000000-0000-0000-0000-000000000001'
      and al.resource_type = 'ledger_entry'
      and al.action in ('ledger.refund', 'ledger.adjust')
      and al.metadata->>'ledger_adjustment_execute' = 'true'
      and le.related_ledger_entry_id = '$SourceLedgerEntryId'
  )
)::text;
"@
}

function Assert-AppliedExecuteResponse {
  param(
    [Parameter(Mandatory = $true)]$Response,
    [Parameter(Mandatory = $true)][string]$SourceLedgerEntryId
  )

  Assert-StatusAny $Response @(201)
  $payload = Read-Json $Response.Content
  $data = $payload.data
  Assert-Equal $data.mode "execute" "execute apply mode"
  Assert-Equal $data.outcome "applied" "execute apply outcome"
  Assert-True ($data.ledger_write -eq $true) "execute apply must write ledger"
  Assert-True ($data.audit_log_write -eq $true) "execute apply must write audit"
  Assert-True ($data.business_and_success_audit_share_transaction -eq $true) "execute apply must report same transaction"
  Assert-True ($data.audit_insert_failure_rolls_back_ledger_write -eq $true) "execute apply must report audit rollback"
  Assert-True ($data.dedupe_material_echoed -eq $false) "execute apply must not echo dedupe material"
  Assert-Equal $data.transaction_contract.writer "control_plane_transactional_admin_ledger_adjustment_writer" "execute writer"
  Assert-True ($data.transaction_contract.unbounded_scan_allowed -eq $false) "execute transaction must remain bounded"

  $ledgerEntryId = [string]$data.ledger_entry.id
  $auditLogId = [string]$data.audit_log_id
  if ([string]::IsNullOrWhiteSpace($ledgerEntryId)) {
    throw "execute apply did not return ledger_entry.id"
  }
  if ([string]::IsNullOrWhiteSpace($auditLogId)) {
    throw "execute apply did not return audit_log_id"
  }

  $script:CreatedLedgerEntryIds += $ledgerEntryId
  $script:CreatedAuditLogIds += $auditLogId

  $safeAuditId = Escape-SqlLiteral $auditLogId
  $safeLedgerId = Escape-SqlLiteral $ledgerEntryId
  $safeSourceId = Escape-SqlLiteral $SourceLedgerEntryId
  $evidence = Invoke-ComposePsqlJson @"
select json_build_object(
  'ledger_count', (
    select count(*)
    from ledger_entries
    where tenant_id = '00000000-0000-0000-0000-000000000001'
      and id = '$safeLedgerId'
      and related_ledger_entry_id = '$safeSourceId'
      and entry_type = 'refund'
      and status = 'confirmed'
      and amount > 0
  ),
  'audit_count', (
    select count(*)
    from audit_logs
    where tenant_id = '00000000-0000-0000-0000-000000000001'
      and id = '$safeAuditId'
      and action = 'ledger.refund'
      and resource_type = 'ledger_entry'
      and resource_id = '$safeLedgerId'
      and metadata->>'transactional_audit' = 'true'
      and metadata->>'ledger_adjustment_execute' = 'true'
      and metadata->>'dedupe_material_echoed' = 'false'
  ),
  'audit_after_snapshot', (
    select after_snapshot
    from audit_logs
    where tenant_id = '00000000-0000-0000-0000-000000000001'
      and id = '$safeAuditId'
  )
)::text;
"@

  Assert-Equal $evidence.ledger_count 1 "execute apply ledger row evidence"
  Assert-Equal $evidence.audit_count 1 "execute apply audit same-resource evidence"
  $auditSnapshot = $evidence.audit_after_snapshot | ConvertTo-Json -Depth 16 -Compress
  Assert-SecretSafeContent -Content $auditSnapshot -Context "ledger adjustment execute audit after_snapshot"
}

function Assert-IdempotentReplay {
  param(
    [Parameter(Mandatory = $true)][string]$SourceLedgerEntryId,
    [Parameter(Mandatory = $true)]$Body
  )

  $before = Get-CreditAndAuditEvidence -SourceLedgerEntryId $SourceLedgerEntryId
  $response = Invoke-LedgerAdjustmentExecute -Body $Body
  if ([int]$response.StatusCode -eq 400) {
    $payload = Read-Json $response.Content
    if ([string]$payload.error.message -like "*remaining refundable amount*") {
      throw "backend_idempotent_replay_after_remaining_check: execute replay returned over-remaining refusal before dedupe replay"
    }
  }
  Assert-StatusAny $response @(200)
  $payload = Read-Json $response.Content
  $data = $payload.data
  Assert-Equal $data.mode "execute" "idempotent replay mode"
  Assert-Equal $data.outcome "idempotent" "idempotent replay outcome"
  Assert-True ($data.ledger_write -eq $false) "idempotent replay must not write ledger"
  Assert-True ($data.audit_log_write -eq $false) "idempotent replay must not write audit"
  Assert-True ($data.dedupe_material_echoed -eq $false) "idempotent replay must not echo dedupe material"
  $after = Get-CreditAndAuditEvidence -SourceLedgerEntryId $SourceLedgerEntryId
  Assert-Equal $after.credit_count $before.credit_count "idempotent replay must not increase ledger credits"
  Assert-Equal $after.audit_count $before.audit_count "idempotent replay must not increase success audits"
}

function Assert-OverRemainingRefusal {
  param(
    [Parameter(Mandatory = $true)][string]$SourceLedgerEntryId
  )

  $before = Get-CreditAndAuditEvidence -SourceLedgerEntryId $SourceLedgerEntryId
  $response = Invoke-LedgerAdjustmentExecute -Body (New-RefundExecuteBody -RelatedLedgerEntryId $SourceLedgerEntryId -Amount "0.11000000" -Reason "live smoke over remaining")
  Assert-StatusAny $response @(400)
  $payload = Read-Json $response.Content
  Assert-Equal $payload.error.code "bad_request" "over remaining error code"
  if (-not ([string]$payload.error.message).Contains("remaining refundable amount")) {
    throw "over remaining refusal did not explain remaining refundable amount"
  }
  $after = Get-CreditAndAuditEvidence -SourceLedgerEntryId $SourceLedgerEntryId
  Assert-Equal $after.credit_count $before.credit_count "over remaining refusal must not increase ledger credits"
  Assert-Equal $after.audit_count $before.audit_count "over remaining refusal must not increase success audits"
}

function Invoke-ExecuteJob {
  param(
    [Parameter(Mandatory = $true)][object]$Body,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $bodyJson = $Body | ConvertTo-Json -Depth 32 -Compress
  return Start-Job -Name $Name -ArgumentList $ControlPlaneBaseUrl, $script:AdminSessionToken, $bodyJson, $TimeoutSeconds -ScriptBlock {
    param($BaseUrl, $SessionToken, $BodyJson, $Timeout)

    Add-Type -AssemblyName System.Net.Http
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds($Timeout)
    $request = New-Object System.Net.Http.HttpRequestMessage -ArgumentList (New-Object System.Net.Http.HttpMethod -ArgumentList "POST"), ($BaseUrl.TrimEnd("/") + "/admin/ledger/adjustments/dry-run")
    [void]$request.Headers.TryAddWithoutValidation("X-Admin-Session", $SessionToken)
    $content = New-Object System.Net.Http.StringContent -ArgumentList $BodyJson
    $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/json")
    $request.Content = $content
    $response = $null
    try {
      $response = $client.SendAsync($request).GetAwaiter().GetResult()
      [PSCustomObject]@{
        StatusCode = [int]$response.StatusCode
        Content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
      }
    } catch {
      [PSCustomObject]@{
        StatusCode = 0
        Content = $_.Exception.Message
      }
    } finally {
      if ($response) { $response.Dispose() }
      $request.Dispose()
      $client.Dispose()
    }
  }
}

function Assert-ConcurrentRefundRace {
  $sourceId = New-RelatedDebit -Amount "-0.25000000" -Label "race-source"
  $first = New-RefundExecuteBody -RelatedLedgerEntryId $sourceId -Amount "0.15000000" -Reason "live smoke race first"
  $second = New-RefundExecuteBody -RelatedLedgerEntryId $sourceId -Amount "0.15100000" -Reason "live smoke race second"
  $jobs = @(
    (Invoke-ExecuteJob -Body $first -Name "ledger-adjustment-race-first"),
    (Invoke-ExecuteJob -Body $second -Name "ledger-adjustment-race-second")
  )

  try {
    [void](Wait-Job -Job $jobs -Timeout ($TimeoutSeconds + 10))
    $running = @($jobs | Where-Object { $_.State -notin @("Completed", "Failed", "Stopped") })
    if ($running.Count -gt 0) {
      Stop-Job -Job $running -Force
      throw "concurrent execute jobs did not finish before timeout"
    }

    $results = @($jobs | ForEach-Object { Receive-Job -Job $_ })
    foreach ($result in $results) {
      Assert-SecretSafeContent -Content ([string]$result.Content) -Context "concurrent ledger adjustment execute response"
    }

    $statuses = @($results | ForEach-Object { [int]$_.StatusCode } | Sort-Object)
    Assert-Equal ($statuses -join ",") "201,400" "concurrent refund race statuses"

    $evidence = Get-CreditAndAuditEvidence -SourceLedgerEntryId $sourceId
    Assert-Equal $evidence.credit_count 1 "concurrent race must leave one confirmed credit"
    Assert-Equal $evidence.audit_count 1 "concurrent race must leave one success audit"

    foreach ($result in $results) {
      if ([int]$result.StatusCode -eq 201) {
        $payload = Read-Json $result.Content
        $script:CreatedLedgerEntryIds += [string]$payload.data.ledger_entry.id
        $script:CreatedAuditLogIds += [string]$payload.data.audit_log_id
      }
    }
  } finally {
    Remove-Job -Job $jobs -Force -ErrorAction SilentlyContinue
  }
}

function Remove-SmokeRows {
  if ($KeepSmokeRows) {
    Write-SafeHost "[INFO] Keeping smoke rows because -KeepSmokeRows was supplied."
    return
  }

  $ledgerIds = @($script:CreatedLedgerEntryIds + $script:SourceLedgerEntryIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
  $sourceIds = @($script:SourceLedgerEntryIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
  $auditIds = @($script:CreatedAuditLogIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
  if ($ledgerIds.Count -eq 0 -and $sourceIds.Count -eq 0 -and $auditIds.Count -eq 0) {
    return
  }

  $ledgerSql = UuidListSql $ledgerIds
  $sourceSql = UuidListSql $sourceIds
  $auditSql = UuidListSql $auditIds
  [void](Invoke-ComposePsql @"
delete from audit_logs
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and (id = any($auditSql) or resource_id = any($ledgerSql));

delete from ledger_entries
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and (id = any($ledgerSql) or related_ledger_entry_id = any($sourceSql));
"@)
}

Push-Location $repoRoot
try {
  Check "ledger adjustment execute live smoke fixture contract" {
    $script:Fixture = Read-JsonFile $fixturePath
    Assert-SmokeFixture $script:Fixture
  }

  Check "S4 execute fixture remains transactional" {
    Assert-S4ContractFixture (Read-JsonFile $dryRunContractPath)
  }

  Check "Admin UI ledger execute smoke selector handoff consumption contract" {
    Assert-UiLiveSmokeSerializableHandoff (Read-JsonFile $uiSmokeHandoffPath)
  }

  Check "runtime-current no-build recreate handoff simulations" {
    Write-RuntimeCurrentHandoffSimulation (Read-JsonFile $uiSmokeHandoffPath)
  }

  Check "runtime-current and mutation artifact acceptance simulations" {
    Write-RuntimeCurrentEvidenceAcceptanceMatrix (Read-JsonFile $uiSmokeHandoffPath)
  }

  Check "browser mutation final closure audit simulations" {
    Write-RuntimeCurrentFinalClosureAudit (Read-JsonFile $uiSmokeHandoffPath)
  }

  Check "browser mutation evidence watcher final guard review" {
    Write-BrowserMutationEvidenceWatcherFinalGuard (Read-JsonFile $uiSmokeHandoffPath)
  }

  if ($AdminSessionHandoff -and (Test-BrowserLiveMutationAttemptOptIn)) {
    Check-Blocking "control-plane admin session handoff before browser live preflight" {
      Write-AdminSessionHandoff
    }
    Exit-WithFailuresOrBlockers
  }

  Check "Admin UI ledger execute browser live-smoke harness preflight contract" {
    Assert-BrowserLiveSmokeHarnessPreflight (Read-JsonFile $uiSmokeHandoffPath)
  }

  Check "Admin UI ledger execute browser action plan dry-run contract" {
    Write-BrowserActionPlanDryRun (Read-JsonFile $uiSmokeHandoffPath)
  }

  Check "Admin UI ledger execute browser DOM action runner dry-run boundary" {
    Write-BrowserDomActionRunnerDryRun -Handoff (Read-JsonFile $uiSmokeHandoffPath) -ToolingStatus (Get-BrowserToolingStatus)
  }

  Check "control-plane source contains transactional execute boundary" {
    Assert-AdminSourceMarkers
  }

  if ($ArtifactReadbackOnly) {
    Check-Blocking "E11 release runtime-current and browser mutation artifact readback gate" {
      Invoke-E11ReleaseArtifactReadbackGate -Handoff (Read-JsonFile $uiSmokeHandoffPath)
    }
    Exit-WithFailuresOrBlockers
    Write-SafeHost "Control Plane ledger adjustment execute release artifact readback-only gate passed; live DB/browser mutation was not run."
    exit 0
  }

  $runtimeSourceProbe = Write-ControlPlaneRuntimeSourceProbe -SourcePaths (Get-ControlPlaneRuntimeSourcePaths)
  $script:RuntimeSourceProbe = $runtimeSourceProbe

  if ($AdminSessionHandoff) {
    Check-Blocking "control-plane admin session handoff" {
      Write-AdminSessionHandoff
    }
    Exit-WithFailuresOrBlockers
    if (-not (Test-BrowserLiveMutationAttemptOptIn)) {
      Write-SafeHost "Control Plane admin session handoff passed."
      exit 0
    }
  }

  if ($ContractOnly) {
    Exit-WithFailuresOrBlockers
    Write-SafeHost "Control Plane ledger adjustment execute smoke contract-only checks passed; live DB was not required."
    exit 0
  }

  $uiSmokeHandoff = Read-JsonFile $uiSmokeHandoffPath
  if ($RuntimeCurrentNoBuildRecreateOptIn -or $RuntimeCurrentRebuildHandoffOptIn -or $RuntimeCurrentEvidenceArtifactWriteOptIn) {
    $runtimeSourceProbe = Invoke-RuntimeCurrentNoBuildRecreateGate -Handoff $uiSmokeHandoff -InitialProbe $runtimeSourceProbe
    $script:RuntimeSourceProbe = $runtimeSourceProbe
    Exit-WithFailuresOrBlockers
    if (-not (Test-BrowserLiveMutationAttemptOptIn)) {
      Write-SafeHost "Control Plane ledger adjustment execute runtime-current handoff gate passed; live ledger mutation was not run."
      exit 0
    }
  }

  if ($RuntimeCurrentEvidenceArtifactReadbackOptIn) {
    $runtimeSourceProbe = Invoke-RuntimeCurrentArtifactReadbackGate -Handoff $uiSmokeHandoff -InitialProbe $runtimeSourceProbe
    $script:RuntimeSourceProbe = $runtimeSourceProbe
    Write-SafeHost "runtime_current_browser_unblock_probe_stale=$($runtimeSourceProbe.StaleOrUnverified)"
    Write-SafeHost "runtime_current_browser_unblock_probe_artifact_verified=$($runtimeSourceProbe.ArtifactVerified)"
    Write-SafeHost "runtime_current_browser_unblock_probe_reason=$($runtimeSourceProbe.Reason)"
    Exit-WithFailuresOrBlockers
    if (-not (Test-BrowserLiveMutationAttemptOptIn)) {
      Write-SafeHost "Control Plane ledger adjustment execute runtime-current artifact readback gate passed; browser runner was not run."
      exit 0
    }
  }

  $runtimeSourceProbeStaleForLiveGate = ([string]$runtimeSourceProbe.StaleOrUnverified).ToLowerInvariant() -eq "true"
  Write-SafeHost "runtime_current_browser_live_gate_stale=$runtimeSourceProbeStaleForLiveGate"
  if ((Test-BrowserLiveMutationAttemptOptIn) -and $runtimeSourceProbeStaleForLiveGate) {
    Add-Blocker "browser live mutation runtime-current gate - runtime_image_stale_or_unverified reason=$($runtimeSourceProbe.Reason)"
    Exit-WithFailuresOrBlockers
  }

  Check-Blocking "live Docker compose control-plane/postgres availability" {
    Assert-LiveEnvironmentAvailable
  }
  Exit-WithFailuresOrBlockers

  if (Test-BrowserLiveMutationAttemptOptIn) {
    Check-Blocking "control-plane admin session handoff for browser live mutation" {
      Write-AdminSessionHandoff
    }
    Exit-WithFailuresOrBlockers
  }

  Check-Blocking "live migrated schema and dev seed availability" {
    Assert-MigratedSchemaAndSeed
  }
  Exit-WithFailuresOrBlockers

  Check "control-plane admin login for BillingAdjust smoke" {
    Initialize-AdminSession
  }

  $browserSessionHandoffStatus = "not_requested"
  if (Test-BrowserLiveMutationAttemptOptIn) {
    $browserSessionHandoffStatus = Publish-BrowserAdminSessionHandoff $uiSmokeHandoff
    Write-SafeHost "browser_live_session_handoff_status=$browserSessionHandoffStatus"
    Write-SafeHost "browser_live_session_handoff_echoed=false"
  }

  $sourceId = $null
  $executeBody = $null
  Check "seed related confirmed debit in live Postgres" {
    $sourceId = New-RelatedDebit -Amount "-0.25000000" -Label "apply-source"
    Set-Variable -Name sourceId -Value $sourceId -Scope Script
    $executeBody = New-RefundExecuteBody -RelatedLedgerEntryId $sourceId -Amount "0.15000000"
    Set-Variable -Name executeBody -Value $executeBody -Scope Script
  }

  Check "execute apply writes ledger and success audit" {
    $response = Invoke-LedgerAdjustmentExecute -Body $script:executeBody
    Assert-AppliedExecuteResponse -Response $response -SourceLedgerEntryId $script:sourceId
  }

  Check-Blocking "execute idempotent replay does not write ledger or audit" {
    Assert-IdempotentReplay -SourceLedgerEntryId $script:sourceId -Body $script:executeBody
  }

  Check "execute refund over remaining refuses without ledger or audit" {
    Assert-OverRemainingRefusal -SourceLedgerEntryId $script:sourceId
  }

  Check "concurrent execute refund race leaves one applied refund" {
    Assert-ConcurrentRefundRace
  }

  $browserLiveAttemptRequested = (Test-BrowserLiveMutationAttemptOptIn) -or (Test-BrowserAdminSessionHandoffPresent $uiSmokeHandoff)
  if ($browserLiveAttemptRequested) {
    $browserSourceId = $null
    Check "seed related confirmed debit for browser live mutation attempt" {
      $browserSourceId = New-RelatedDebit -Amount "-0.25000000" -Label "browser-apply-source"
      Set-Variable -Name browserSourceId -Value $browserSourceId -Scope Script
    }

    Check "browser live mutation pass artifact attempt" {
      Invoke-BrowserLiveMutationPassAttempt -Handoff $uiSmokeHandoff -SourceLedgerEntryId $script:browserSourceId
    }
  }

  Exit-WithFailuresOrBlockers
  Write-SafeHost "Control Plane ledger adjustment execute live Postgres smoke passed."
} finally {
  try {
    if (-not $ContractOnly -and -not $AdminSessionHandoff) {
      Remove-SmokeRows
    }
  } catch {
    Add-Failure "[FAIL] cleanup smoke rows - $($_.Exception.Message)"
    Exit-WithFailuresOrBlockers
  }
  Pop-Location
}
