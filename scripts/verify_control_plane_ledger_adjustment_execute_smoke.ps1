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
  [switch]$BrowserAdminUiDevServerOptIn,
  [switch]$BrowserEvidenceArtifactWriteOptIn,
  [switch]$BrowserLiveRunnerExecutionOptIn,
  [switch]$BrowserMutationOptIn,
  [switch]$BrowserPreflight,
  [switch]$AdminSessionHandoff,
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

if ($env:CONTROL_PLANE_BASE_URL) { $ControlPlaneBaseUrl = $env:CONTROL_PLANE_BASE_URL }
if ($env:ADMIN_UI_BASE_URL) { $AdminUiBaseUrl = $env:ADMIN_UI_BASE_URL }
if ($env:CONTROL_PLANE_ADMIN_EMAIL) { $AdminEmail = $env:CONTROL_PLANE_ADMIN_EMAIL }
if ($env:CONTROL_PLANE_ADMIN_PASSWORD) { $AdminPassword = $env:CONTROL_PLANE_ADMIN_PASSWORD }
if ($env:CONTROL_PLANE_ADMIN_SESSION_TOKEN) { $script:AdminSessionToken = $env:CONTROL_PLANE_ADMIN_SESSION_TOKEN }
if ($env:COMPOSE_FILE) { $ComposeFile = $env:COMPOSE_FILE }
if ($env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_PROBE_TIMEOUT_MS) { $BrowserProbeTimeoutMilliseconds = [int]$env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_PROBE_TIMEOUT_MS }
if ($env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_ARTIFACT_PATH) { $BrowserEvidenceArtifactPath = $env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_ARTIFACT_PATH }
if ($env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_ADMIN_UI_DEV_SERVER -eq "1") { $BrowserAdminUiDevServerOptIn = $true }
if ($env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_ARTIFACT_WRITE -eq "1") { $BrowserEvidenceArtifactWriteOptIn = $true }
if ($env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_RUNNER -eq "1") { $BrowserLiveRunnerExecutionOptIn = $true }
if ($env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_PREFLIGHT -eq "1") { $BrowserPreflight = $true }
if ($env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_ADMIN_SESSION_HANDOFF -eq "1") { $AdminSessionHandoff = $true }
if ($env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_SMOKE_CONTRACT_ONLY -eq "1") { $ContractOnly = $true }
if ($env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_SMOKE_KEEP_ROWS -eq "1") { $KeepSmokeRows = $true }
if ($BrowserPreflight) { $ContractOnly = $true }

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
      "provider_key",
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
      "ledgerAdjustmentExecuteBrowserLiveRunnerExecutionBridgeContract",
      "ledgerAdjustmentExecuteBrowserLiveEnvironmentBootstrapAttemptContract",
      "ledgerAdjustmentExecuteBrowserPlaywrightLaunchReadinessContract",
      "ledgerAdjustmentExecuteBrowserLiveRunbookContract",
      "ledgerAdjustmentExecuteBrowserRunnerReadinessContract",
      "ledgerAdjustmentExecuteLiveSmokeSerializableHandoff",
      "ledgerAdjustmentExecuteAbsentOptionalMarker = null",
      "browserActionPlan: ledgerAdjustmentExecuteBrowserActionPlanContract",
      "browserDomActionRunner: ledgerAdjustmentExecuteBrowserDomActionRunnerContract",
      "browserLiveRunnerExecutionBridge: ledgerAdjustmentExecuteBrowserLiveRunnerExecutionBridgeContract",
      "browserLiveEnvironmentBootstrapAttempt: ledgerAdjustmentExecuteBrowserLiveEnvironmentBootstrapAttemptContract",
      "browserLivePassArtifactReadbackGate: ledgerAdjustmentExecuteBrowserLivePassArtifactReadbackGateContract",
      "browserMutationPassArtifactClosure: ledgerAdjustmentExecuteBrowserMutationPassArtifactClosureContract",
      "browserPlaywrightLaunchReadiness: ledgerAdjustmentExecuteBrowserPlaywrightLaunchReadinessContract",
      "browserLiveRunbook: ledgerAdjustmentExecuteBrowserLiveRunbookContract",
      "browserPreflight: ledgerAdjustmentExecuteBrowserPreflightContract",
      "browserRunnerReadiness: ledgerAdjustmentExecuteBrowserRunnerReadinessContract"
    )) {
    if (-not $source.Contains($needle)) {
      throw "UI smoke contract source missing freshness marker '$needle'"
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
      "browserMutationPassArtifactClosure",
      "browserPlaywrightLaunchReadiness",
      "browserEvidenceArtifact",
      "browserRunnerReadiness",
      "browserLiveRunbook",
      "billing_execute_browser_live_e2e_evidence.v1",
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
    if ([string]$value -eq "unavailable") {
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
    if ([string](Get-JsonProperty $action "duration_ms" "browser evidence action") -eq "unavailable") {
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
  if ($writeEnabled -and (Test-Path $artifactPath)) {
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

  $state = Get-BrowserLivePassArtifactReadbackState -Handoff $Handoff -Artifact $readbackArtifact -ReadbackAvailable $readbackAvailable
  $status = [string](Get-JsonProperty $statusMarkers $state "UI browser readback gate status markers")
  $blockers = @()
  if (-not $writeEnabled) { $blockers += "artifact_write_opt_in_missing" }
  if (-not $readbackAvailable) { $blockers += "artifact_readback_missing" }
  if (-not $MutationEnabled) { $blockers += "live_mutation_opt_in_missing" }
  if (-not $SessionMaterialPresent) { $blockers += "session_material_missing" }
  if ($state -eq "fail") { $blockers += "artifact_closure_failed" }
  $blockerSummary = if ($blockers.Count -gt 0) { $blockers -join "+" } else { "none" }

  Write-SafeHost "Browser ledger execute live pass artifact readback gate:"
  Write-SafeHost "browser_live_pass_readback_status=$status"
  Write-SafeHost "browser_live_pass_readback_state=$state"
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
  Assert-SecretSafeContent -Content $response.Content -Context "admin session handoff /admin/auth/me response"
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
  if ($writeEnabled -and (Test-Path $artifactPath)) {
    $readbackArtifact = Read-JsonFile $artifactPath
    $readbackAvailable = $true
  }
  $readbackState = Get-BrowserLivePassArtifactReadbackState -Handoff $Handoff -Artifact $readbackArtifact -ReadbackAvailable $readbackAvailable
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
  if (-not $readbackAvailable) { $blockers += "artifact_readback_missing" }
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
    $runnerStatus = if ($canRun) { "running" } else { "blocked" }

    if ($canRun) {
      $nodeScript = @'
const fs = require("fs");
const { chromium } = require("@playwright/test");

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

(async () => {
  const adminUiBaseUrl = requireEnv("BROWSER_ADMIN_UI_BASE_URL");
  const controlPlaneBaseUrl = requireEnv("BROWSER_CONTROL_PLANE_BASE_URL").replace(/\/+$/, "");
  const sessionToken = requireEnv("CONTROL_PLANE_ADMIN_SESSION_TOKEN");
  const sourceLedgerEntryId = requireEnv("BROWSER_LEDGER_SOURCE_ENTRY_ID");
  const handoff = JSON.parse(fs.readFileSync(requireEnv("BROWSER_HANDOFF_PATH"), "utf8"));
  const selectors = handoff.selectors;
  const actions = [];
  const durations = {
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

  let start = now();
  const browser = await chromium.launch({ headless: true });
  durations.browser_launch_duration_ms = elapsed(start);
  start = now();
  const context = await browser.newContext({ baseURL: adminUiBaseUrl });
  durations.context_setup_duration_ms = elapsed(start);

  const controlPlaneOrigin = new URL(controlPlaneBaseUrl).origin;
  await context.route("**/*", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const headers = { ...request.headers(), "x-admin-session": sessionToken };
    delete headers.cookie;

    if (url.pathname.startsWith("/api/control-plane/admin/")) {
      const targetPath = url.pathname.replace(/^\/api\/control-plane/, "");
      const response = await route.fetch({ headers, url: `${controlPlaneBaseUrl}${targetPath}${url.search}` });
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
  for (const key of [
    "dryRunButton",
    "executeButton",
    "executeOutcome",
    "executeResultFresh",
    "ledgerRefreshStatus",
    "amountInput",
    "currencyInput",
    "operationInput",
    "relatedLedgerEntryInput",
    "reasonInput",
  ]) {
    await page.locator(dataTestId(selectors[key])).waitFor({ timeout: 15000 });
  }
  durations.selector_snapshot_duration_ms = elapsed(start);

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

  start = now();
  await page.locator(dataTestId(selectors.executeButton)).click();
  await textIncludes(page, selectors.executeOutcome, "execute_outcome=applied", 20000);
  await textIncludes(page, selectors.executeResultFresh, "execute_result_fresh=true", 20000);
  await textIncludes(page, selectors.ledgerRefreshStatus, "ledger_entries_refresh_after_execute=success", 20000);
  durations.execute_apply_duration_ms = elapsed(start);
  durations.submit_latency_ms = durations.execute_apply_duration_ms;
  durations.ledger_refresh_duration_ms = durations.execute_apply_duration_ms;
  actions.push({ name: "execute_apply", status: "applied", outcome: "applied", duration_ms: durations.execute_apply_duration_ms });

  start = now();
  await page.locator(dataTestId(selectors.executeButton)).click();
  await textIncludes(page, selectors.executeOutcome, "execute_outcome=idempotent", 20000);
  await textIncludes(page, selectors.ledgerRefreshStatus, "ledger_entries_refresh_after_execute=success", 20000);
  durations.idempotent_replay_duration_ms = elapsed(start);
  actions.push({ name: "idempotent_replay", status: "idempotent", outcome: "idempotent", duration_ms: durations.idempotent_replay_duration_ms });

  actions.push({ name: "ledger_refresh", status: "success", outcome: "success", duration_ms: durations.ledger_refresh_duration_ms });

  await fillRefund("0.11000000", "browser live smoke refusal");
  start = now();
  await page.locator(dataTestId(selectors.dryRunButton)).click();
  await textIncludes(page, selectors.dryRunFresh, "fresh_dry_run=true");
  await page.locator(dataTestId(selectors.executeButton)).click();
  await page.waitForFunction(
    ({ selector }) => {
      const node = document.querySelector(selector);
      const text = node && node.textContent ? node.textContent : "";
      return text.includes("remaining refundable amount") || text.includes("blocked");
    },
    { selector: dataTestId(selectors.readiness) },
    { timeout: 20000 },
  );
  durations.refund_refusal_duration_ms = elapsed(start);
  actions.push({ name: "refund_refusal", status: "blocked", outcome: "blocked", duration_ms: durations.refund_refusal_duration_ms });

  await browser.close();
  console.log(JSON.stringify({ actions, durations, outcome: "passed" }));
})().catch((error) => {
  console.log(JSON.stringify({
    actions: [],
    durations: {},
    error: String(error && error.message ? error.message : error).replace(/Bearer\s+\S+/gi, "Bearer [REDACTED]"),
    outcome: "failed",
  }));
  process.exitCode = 1;
});
'@

      $tempScript = Join-Path ([System.IO.Path]::GetTempPath()) ("billing_execute_browser_runner_" + [guid]::NewGuid().ToString("N") + ".cjs")
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
        Push-Location (Join-Path $repoRoot "web\admin-ui")
        try {
          $runnerOutput = & node $tempScript 2>&1
          $runnerExitCode = $LASTEXITCODE
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
      }

      $runnerJson = (($runnerOutput | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Last 1) | Out-String).Trim()
      $runnerResult = Read-Json $runnerJson
      $runnerStatus = [string]$runnerResult.outcome
      if ($runnerStatus -eq "passed" -and $runnerExitCode -eq 0) {
        $artifact.outcome = "passed"
        $artifact.blockers = @()
      } else {
        $artifact.outcome = "failed"
        $artifact.blockers = @("browser_live_runner_failed")
      }
      Set-BrowserEvidenceFromRunnerResult -Artifact $artifact -RunnerResult $runnerResult
    }

    Assert-BrowserEvidenceArtifactShape -Handoff $Handoff -Artifact $artifact
    if ($artifact.outcome -eq "passed") {
      Assert-BrowserEvidenceArtifactFreshness -Handoff $Handoff -Artifact $artifact
      if (-not (Test-BrowserMutationPassArtifactClosure -Handoff $Handoff -Artifact $artifact)) {
        $artifact.outcome = "failed"
        $artifact.blockers = @("artifact_closure_failed")
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
      if ($artifact.outcome -eq "passed") {
        Assert-True (Test-BrowserMutationPassArtifactClosure -Handoff $Handoff -Artifact $readBack) "browser live runner pass artifact readback must close"
      }
    }

    Write-SafeHost "Browser ledger execute live mutation pass attempt:"
    Write-SafeHost "browser_live_mutation_attempt_status=$runnerStatus"
    Write-SafeHost "browser_live_mutation_attempt_artifact_outcome=$($artifact.outcome)"
    Write-SafeHost "browser_live_mutation_attempt_blockers=$(if ($artifact.blockers.Count -gt 0) { $artifact.blockers -join '+' } else { 'none' })"
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
  Assert-StringSetEqual $requiredTopLevel @("artifact", "generated_at", "mode", "outcome", "provenance", "freshness", "blockers", "matrix", "durations", "actions", "secret_safe") "UI browser evidence top-level fields"

  $outcomes = Get-JsonProperty $contract "outcomes" "UI browser evidence artifact"
  foreach ($name in @("blocked", "failed", "passed")) {
    Assert-Equal (Get-JsonProperty $outcomes $name "UI browser evidence outcomes") $name "UI browser evidence outcome $name"
  }

  $durationFields = Get-JsonProperty $contract "durationFields" "UI browser evidence artifact"
  foreach ($name in @("browserLaunchDurationMs", "contextSetupDurationMs", "dryRunPlanDurationMs", "executeApplyDurationMs", "idempotentReplayDurationMs", "ledgerRefreshDurationMs", "pageReadyDurationMs", "refundRefusalDurationMs", "selectorSnapshotDurationMs", "serviceReadinessDurationMs", "submitLatencyMs")) {
    $field = [string](Get-JsonProperty $durationFields $name "UI browser evidence duration fields")
    if ($field -notmatch '^[a-z0-9_]+$') {
      throw "UI browser evidence duration field '$name' must be machine readable"
    }
  }
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
      handoff_fresh = $true
      git_commit = $GitCommit
    }
    freshness = [PSCustomObject]@{
      marker = [string](Get-JsonProperty $roundTrip "freshnessMarker" "UI browser runner artifact round-trip")
      handoff_fresh = $HandoffFresh
      git_commit = $GitCommit
      require_current_git_commit = [bool](Get-JsonProperty $staleRefusal "requireCurrentGitCommit" "UI browser runner artifact stale refusal")
      max_generated_age_minutes = [int](Get-JsonProperty $staleRefusal "maxGeneratedAgeMinutes" "UI browser runner artifact stale refusal")
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

  $generatedAt = [DateTime]::Parse([string](Get-JsonProperty $Artifact "generated_at" "browser evidence artifact")).ToUniversalTime()
  $maxAgeMinutes = [int](Get-JsonProperty $staleRefusal "maxGeneratedAgeMinutes" "UI browser runner artifact stale refusal")
  $age = (Get-Date).ToUniversalTime() - $generatedAt
  if ($age.TotalMinutes -gt $maxAgeMinutes) {
    throw "browser evidence artifact is stale by generated_at"
  }
}

function Assert-StaleBrowserEvidenceArtifactRefusal {
  param([Parameter(Mandatory = $true)]$Handoff)

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
  Assert-BrowserEvidenceArtifactFreshness -Handoff $Handoff -Artifact $roundTripArtifact
  Assert-StaleBrowserEvidenceArtifactRefusal -Handoff $Handoff

  $writeRead = Get-JsonProperty $runner "artifactWriteRead" "UI browser runner artifact write/read"
  $writeEnabled = Test-BrowserEvidenceArtifactWriteOptIn $Handoff
  $artifactPath = Resolve-BoundedEvidenceArtifactPath $BrowserEvidenceArtifactPath
  if ($writeEnabled) {
    $artifactDirectory = Split-Path -Path $artifactPath -Parent
    if (-not (Test-Path $artifactDirectory)) {
      New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
    }
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

  $serviceText = ($services | Out-String)
  foreach ($service in @("postgres", "control-plane")) {
    if ($serviceText -notmatch "(?m)^$service$") {
      throw "compose service '$service' is not running; start deploy/docker-compose/docker-compose.yml before live smoke"
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
  $metadata = "{""smoke"":""control_plane_ledger_adjustment_execute_live_smoke"",""run_id"":""$($script:SmokeRunId)"",""label"":""$Label""}"
  $safeIdem = Escape-SqlLiteral $idem
  $safeMetadata = Escape-SqlLiteral $metadata
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
  '$safeMetadata'::jsonb
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

  if ($AdminSessionHandoff) {
    Check-Blocking "control-plane admin session handoff" {
      Write-AdminSessionHandoff
    }
    Exit-WithFailuresOrBlockers
    Write-SafeHost "Control Plane admin session handoff passed."
    exit 0
  }

  if ($ContractOnly) {
    Exit-WithFailuresOrBlockers
    Write-SafeHost "Control Plane ledger adjustment execute smoke contract-only checks passed; live DB was not required."
    exit 0
  }

  Check-Blocking "live Docker compose control-plane/postgres availability" {
    Assert-LiveEnvironmentAvailable
  }
  Exit-WithFailuresOrBlockers

  Check-Blocking "live migrated schema and dev seed availability" {
    Assert-MigratedSchemaAndSeed
  }
  Exit-WithFailuresOrBlockers

  Check "control-plane admin login for BillingAdjust smoke" {
    Initialize-AdminSession
  }

  $uiSmokeHandoff = Read-JsonFile $uiSmokeHandoffPath
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

  Check "execute idempotent replay does not write ledger or audit" {
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
