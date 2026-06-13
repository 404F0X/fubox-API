param(
  [string]$ControlPlaneBaseUrl = "http://127.0.0.1:8081",
  [string]$AdminEmail = "admin@example.com",
  [string]$AdminPassword = "local-password",
  [string]$ComposeFile = "deploy/docker-compose/docker-compose.yml",
  [string]$ProjectId = "00000000-0000-0000-0000-000000000020",
  [string]$ProfileId = "00000000-0000-0000-0000-000000000040",
  [string]$DefaultPriceBookId = "00000000-0000-0000-0000-0000000030b0",
  [string]$RequestedModel = "mock-gpt-4o-mini",
  [string]$CanonicalModelKey = "mock-gpt-4o-mini",
  [string]$PreviousSuccessfulChannelId = "00000000-0000-0000-0000-000000000070",
  [int]$Seed = 42,
  [int]$TimeoutSeconds = 8,
  [string]$OutputPath = ".tmp/control-plane/model_association_dry_run_live_verification.json",
  [switch]$NoWrite
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Blockers = New-Object System.Collections.Generic.List[string]
$script:Checks = New-Object System.Collections.Generic.List[object]
$script:SensitiveValues = New-Object System.Collections.Generic.List[string]
$script:AdminSessionToken = ""
$script:LiveResponse = $null
$script:DefaultPriceLive = $null
$script:AdminUiEvidence = $null
$script:ComposeServices = @()
$script:SeedStatus = $null

if ($env:CONTROL_PLANE_BASE_URL) { $ControlPlaneBaseUrl = $env:CONTROL_PLANE_BASE_URL }
if ($env:CONTROL_PLANE_ADMIN_EMAIL) { $AdminEmail = $env:CONTROL_PLANE_ADMIN_EMAIL }
if ($env:CONTROL_PLANE_ADMIN_PASSWORD) { $AdminPassword = $env:CONTROL_PLANE_ADMIN_PASSWORD }
if ($env:COMPOSE_FILE) { $ComposeFile = $env:COMPOSE_FILE }

Add-Type -AssemblyName System.Net.Http

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
  $prefix = $repoRoot.Path.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
  if ($full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    return ($full.Substring($prefix.Length) -replace "\\", "/")
  }
  return ($full -replace "\\", "/")
}

function Add-SensitiveValue {
  param([AllowNull()][string]$Value)
  if (-not [string]::IsNullOrWhiteSpace($Value)) {
    [void]$script:SensitiveValues.Add($Value)
  }
}

Add-SensitiveValue $AdminPassword

function Redact-SecretLikeString {
  param([AllowNull()][string]$Text)
  if ($null -eq $Text) { return "" }

  $redacted = [string]$Text
  foreach ($secret in $script:SensitiveValues) {
    if (-not [string]::IsNullOrEmpty($secret)) {
      $redacted = $redacted.Replace($secret, "[REDACTED]")
    }
  }
  $redacted = $redacted -replace '(?i)("session_token_once"\s*:\s*")[^"]+(")', '$1[REDACTED]$2'
  $redacted = $redacted -replace '(?i)("password"\s*:\s*")[^"]+(")', '$1[REDACTED]$2'
  $redacted = $redacted -replace '(?i)(x-admin-session\s*[:=]\s*)[^\s";,]+', '$1[REDACTED]'
  $redacted = $redacted -replace '(?i)(authorization\s*[:=]\s*bearer\s+)[^\s";,]+', '$1[REDACTED]'
  $redacted = $redacted -replace '(?i)((?:password|passwd|secret|token|session|api[_-]?key|access[_-]?key|private[_-]?key)\s*[:=]\s*)[^\s";,}]+', '$1[REDACTED]'
  $redacted = $redacted -replace 'sess_[A-Za-z0-9._~+/\-=]+', '[REDACTED]'
  $redacted = $redacted -replace 'sk-[A-Za-z0-9._~+\-/=]+', '[REDACTED]'
  return $redacted
}

function Test-SecretSafeText {
  param([AllowNull()][string]$Text)
  if ([string]::IsNullOrEmpty($Text)) { return $true }

  foreach ($pattern in @(
      '(?i)"(?:encrypted_secret|secret_fingerprint|provider_secret|raw_key)"\s*:',
      '(?i)"(?:api_key|secret|token|password)"\s*:\s*"[^"]{4,}"',
      '(?i)authorization\s*[:=]\s*bearer\s+[^"\s,}]+',
      '(?i)x-admin-session\s*[:=]',
      '(?i)postgres(?:ql)?://[^"\s]+',
      'sess_[A-Za-z0-9._~+/\-=]+',
      'sk-[A-Za-z0-9._~+\-/=]{8,}'
    )) {
    if ($Text -match $pattern) { return $false }
  }
  return $true
}

function Add-Failure {
  param([Parameter(Mandatory = $true)][string]$Message)
  $safe = Redact-SecretLikeString $Message
  [void]$script:Failures.Add($safe)
  Write-Host $safe
}

function Add-Blocker {
  param([Parameter(Mandatory = $true)][string]$Message)
  $safe = Redact-SecretLikeString $Message
  [void]$script:Blockers.Add($safe)
  Write-Host "[BLOCKED] $safe"
}

function Check {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][scriptblock]$Action
  )

  try {
    & $Action
    [void]$script:Checks.Add([pscustomobject]@{ name = $Name; status = "pass" })
    Write-Host "[OK] $Name"
  } catch {
    [void]$script:Checks.Add([pscustomobject]@{ name = $Name; status = "fail"; error = (Redact-SecretLikeString $_.Exception.Message) })
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
    [void]$script:Checks.Add([pscustomobject]@{ name = $Name; status = "pass" })
    Write-Host "[OK] $Name"
  } catch {
    [void]$script:Checks.Add([pscustomobject]@{ name = $Name; status = "blocked"; error = (Redact-SecretLikeString $_.Exception.Message) })
    Add-Blocker "$Name - $($_.Exception.Message)"
  }
}

function Assert-True {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Message
  )
  if (-not $Condition) { throw $Message }
}

function Join-Url {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$Path
  )
  if (-not $Path.StartsWith("/")) { $Path = "/$Path" }
  return $BaseUrl.TrimEnd("/") + $Path
}

function Read-Json {
  param([Parameter(Mandatory = $true)][string]$Content)
  try {
    return $Content | ConvertFrom-Json
  } catch {
    throw "expected JSON response, got: $(Redact-SecretLikeString $Content)"
  }
}

function Invoke-ApiRequest {
  param(
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Path,
    [object]$Body = $null,
    [string]$SessionToken = ""
  )

  $client = New-Object System.Net.Http.HttpClient
  $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
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
    return [pscustomobject]@{
      StatusCode = [int]$response.StatusCode
      Content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    }
  } catch [System.Threading.Tasks.TaskCanceledException] {
    throw "request timed out after $TimeoutSeconds seconds"
  } finally {
    if ($response) { $response.Dispose() }
    $request.Dispose()
    $client.Dispose()
  }
}

function Assert-Status {
  param(
    [Parameter(Mandatory = $true)]$Response,
    [Parameter(Mandatory = $true)][int]$Expected
  )
  if ($Response.StatusCode -ne $Expected) {
    throw "expected HTTP $Expected, got HTTP $($Response.StatusCode): $(Redact-SecretLikeString $Response.Content)"
  }
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

function Get-DockerCommand {
  $docker = Get-Command docker -ErrorAction SilentlyContinue
  if (-not $docker) { throw "docker CLI is unavailable" }
  return $docker.Source
}

function Invoke-ComposePsql {
  param([Parameter(Mandatory = $true)][string]$Sql)

  $docker = Get-DockerCommand
  $result = Invoke-NativeCapture -Command $docker -Arguments @(
    "compose", "-f", $ComposeFile, "exec", "-T", "postgres", "psql",
    "-U", "ai_gateway", "-d", "ai_gateway", "-tA", "-v", "ON_ERROR_STOP=1", "-c", $Sql
  )
  if ($result.ExitCode -ne 0) {
    throw "compose postgres psql failed: $(Redact-SecretLikeString $result.Output)"
  }
  return $result.Output
}

function Get-ComposeServices {
  $docker = Get-DockerCommand
  $result = Invoke-NativeCapture -Command $docker -Arguments @("compose", "-f", $ComposeFile, "ps", "--format", "json")
  if ($result.ExitCode -ne 0) {
    throw "docker compose ps failed: $($result.Output)"
  }
  if ([string]::IsNullOrWhiteSpace($result.Output)) {
    throw "docker compose returned no services"
  }

  $lines = @($result.Output -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  return @($lines | ForEach-Object { $_ | ConvertFrom-Json })
}

function Assert-ServiceRunning {
  param(
    [Parameter(Mandatory = $true)][object[]]$Services,
    [Parameter(Mandatory = $true)][string]$ServiceName
  )
  $service = @($Services | Where-Object { $_.Service -eq $ServiceName } | Select-Object -First 1)
  if ($service.Count -eq 0) {
    throw "compose service '$ServiceName' is not present"
  }
  $state = [string]$service[0].State
  if ($state -ne "running") {
    throw "compose service '$ServiceName' is state '$state'"
  }
}

function Get-SeedStatus {
  $json = Invoke-ComposePsql @"
select json_build_object(
  'project_count', (select count(*) from projects where tenant_id = '00000000-0000-0000-0000-000000000001' and id = '$ProjectId'),
  'profile_count', (select count(*) from api_key_profiles where tenant_id = '00000000-0000-0000-0000-000000000001' and id = '$ProfileId' and project_id = '$ProjectId' and status = 'active' and deleted_at is null),
  'canonical_model_count', (select count(*) from canonical_models where tenant_id = '00000000-0000-0000-0000-000000000001' and model_key = '$CanonicalModelKey' and status = 'active' and deleted_at is null),
  'default_price_book_count', (select count(*) from price_books where tenant_id = '00000000-0000-0000-0000-000000000001' and id = '$DefaultPriceBookId' and status = 'active'),
  'active_default_price_version_count', (
    select count(*)
    from price_versions pv
    join canonical_models cm on cm.tenant_id = pv.tenant_id and cm.id = pv.canonical_model_id
    where pv.tenant_id = '00000000-0000-0000-0000-000000000001'
      and pv.price_book_id = '$DefaultPriceBookId'
      and cm.model_key = '$CanonicalModelKey'
      and pv.status = 'active'
      and pv.effective_at <= now()
      and (pv.retired_at is null or pv.retired_at > now())
  ),
  'provider_count', (select count(*) from providers where tenant_id = '00000000-0000-0000-0000-000000000001' and code = 'mock-openai' and status = 'enabled' and deleted_at is null),
  'channel_count', (select count(*) from channels where tenant_id = '00000000-0000-0000-0000-000000000001' and id = '$PreviousSuccessfulChannelId' and status = 'enabled' and deleted_at is null),
  'association_count', (
    select count(*)
    from model_associations ma
    join canonical_models cm on cm.tenant_id = ma.tenant_id and cm.id = ma.canonical_model_id
    where ma.tenant_id = '00000000-0000-0000-0000-000000000001'
      and cm.model_key = '$CanonicalModelKey'
      and ma.channel_id = '$PreviousSuccessfulChannelId'
      and ma.status = 'enabled'
      and ma.deleted_at is null
  ),
  'fallback_allowed_count', (
    select count(*)
    from model_associations ma
    join canonical_models cm on cm.tenant_id = ma.tenant_id and cm.id = ma.canonical_model_id
    where ma.tenant_id = '00000000-0000-0000-0000-000000000001'
      and cm.model_key = '$CanonicalModelKey'
      and ma.channel_id = '$PreviousSuccessfulChannelId'
      and ma.status = 'enabled'
      and ma.deleted_at is null
      and ma.fallback_allowed = true
  )
)
"@
  return Read-Json $json
}

function Assert-SeedStatus {
  param([Parameter(Mandatory = $true)]$Status)
  foreach ($field in @("project_count", "profile_count", "canonical_model_count", "default_price_book_count", "active_default_price_version_count", "provider_count", "channel_count", "association_count", "fallback_allowed_count")) {
    if ([int]$Status.$field -lt 1) {
      throw "dev seed prerequisite '$field' is missing"
    }
  }
}

function Invoke-AdminLogin {
  $response = Invoke-ApiRequest -Method "POST" -Path "/admin/auth/login" -Body @{
    email = $AdminEmail
    password = $AdminPassword
  }
  Assert-Status -Response $response -Expected 200
  $payload = Read-Json $response.Content
  $token = [string]$payload.data.session_token_once
  if ([string]::IsNullOrWhiteSpace($token)) {
    throw "login response did not include data.session_token_once"
  }
  Add-SensitiveValue $token
  return $token
}

function Invoke-AdminLogout {
  param([Parameter(Mandatory = $true)][string]$SessionToken)
  $response = Invoke-ApiRequest -Method "POST" -Path "/admin/auth/logout" -SessionToken $SessionToken
  Assert-Status -Response $response -Expected 200
}

function Assert-DryRunResponse {
  param([Parameter(Mandatory = $true)]$Payload)

  $data = $Payload.data
  Assert-True ($null -ne $data) "response must include data envelope"
  Assert-True ([string]$data.requested_model -eq $RequestedModel) "requested_model mismatch"
  Assert-True ([string]$data.route_policy_version -eq "gateway_db_route_v1") "route_policy_version mismatch"
  Assert-True ([int]$data.decision_snapshot_version -eq 1) "decision_snapshot_version mismatch"
  Assert-True ([string]$data.selection.status -eq "selected") "selection.status must be selected"
  Assert-True ($null -ne $data.selected_candidate) "selected_candidate is required"
  Assert-True ($data.selected_candidate.selected -eq $true) "selected_candidate.selected must be true"
  Assert-True ($data.selected_candidate.fallback_allowed -is [bool]) "selected_candidate.fallback_allowed must be boolean"
  Assert-True ($data.selected_candidate.fallback_allowed -eq $true) "dev seeded selected_candidate.fallback_allowed must be true"
  Assert-True (@($data.candidates).Count -gt 0) "candidates must contain at least one candidate"
  Assert-True (@($data.candidates | Where-Object { $_.selected -eq $true }).Count -eq 1) "exactly one candidate must be selected"
  Assert-True (@($data.candidates | Where-Object { $_.fallback_allowed -is [bool] }).Count -eq @($data.candidates).Count) "all candidates must expose boolean fallback_allowed"
  Assert-True ($null -ne $data.route_decision_snapshot) "route_decision_snapshot is required"
  Assert-True ($data.route_decision_snapshot.version -eq $data.decision_snapshot_version) "snapshot version must match response version"
  Assert-True (Test-SecretSafeText ($Payload | ConvertTo-Json -Depth 64 -Compress)) "dry-run response leaks credential-like material"
}

function Get-CanonicalModelIdFromLiveResponse {
  if ($null -ne $script:LiveResponse -and $null -ne $script:LiveResponse.data -and $null -ne $script:LiveResponse.data.canonical_model) {
    $modelId = [string]$script:LiveResponse.data.canonical_model.id
    if (-not [string]::IsNullOrWhiteSpace($modelId)) {
      return $modelId
    }
  }
  throw "dry-run response did not include canonical_model.id for default price selector smoke"
}

function Assert-CanonicalModelDefaultPrice {
  param(
    [Parameter(Mandatory = $true)]$Payload,
    [AllowNull()][string]$ExpectedDefaultPriceBookId
  )

  $data = $Payload.data
  Assert-True ($null -ne $data) "model response must include data envelope"
  Assert-True ([string]$data.model_key -eq $CanonicalModelKey) "model_key mismatch"
  if ($null -eq $ExpectedDefaultPriceBookId) {
    Assert-True ($null -eq $data.default_price_book_id) "default_price_book_id must be null"
  } else {
    Assert-True ([string]$data.default_price_book_id -eq $ExpectedDefaultPriceBookId) "default_price_book_id readback mismatch"
  }
  Assert-True (Test-SecretSafeText ($Payload | ConvertTo-Json -Depth 64 -Compress)) "model default price response leaks credential-like material"
}

function Invoke-DefaultPriceSelectorLiveSmoke {
  param([Parameter(Mandatory = $true)][string]$SessionToken)

  $modelId = Get-CanonicalModelIdFromLiveResponse
  $getResponse = Invoke-ApiRequest -Method "GET" -Path "/admin/models/$modelId" -SessionToken $SessionToken
  Assert-Status -Response $getResponse -Expected 200
  $originalPayload = Read-Json $getResponse.Content
  $originalDefaultPriceBookId = if ($null -eq $originalPayload.data.default_price_book_id) { $null } else { [string]$originalPayload.data.default_price_book_id }

  $setResponse = Invoke-ApiRequest -Method "PATCH" -Path "/admin/models/$modelId" -Body @{
    default_price_book_id = $DefaultPriceBookId
  } -SessionToken $SessionToken
  Assert-Status -Response $setResponse -Expected 200
  $setPayload = Read-Json $setResponse.Content
  Assert-CanonicalModelDefaultPrice -Payload $setPayload -ExpectedDefaultPriceBookId $DefaultPriceBookId

  $readbackResponse = Invoke-ApiRequest -Method "GET" -Path "/admin/models/$modelId" -SessionToken $SessionToken
  Assert-Status -Response $readbackResponse -Expected 200
  $readbackPayload = Read-Json $readbackResponse.Content
  Assert-CanonicalModelDefaultPrice -Payload $readbackPayload -ExpectedDefaultPriceBookId $DefaultPriceBookId

  $restoreSucceeded = $false
  try {
    $restoreResponse = Invoke-ApiRequest -Method "PATCH" -Path "/admin/models/$modelId" -Body @{
      default_price_book_id = $originalDefaultPriceBookId
    } -SessionToken $SessionToken
    Assert-Status -Response $restoreResponse -Expected 200
    $restorePayload = Read-Json $restoreResponse.Content
    Assert-CanonicalModelDefaultPrice -Payload $restorePayload -ExpectedDefaultPriceBookId $originalDefaultPriceBookId
    $restoreSucceeded = $true
  } catch {
    Add-Failure "[FAIL] restore model default price selector - $($_.Exception.Message)"
  }

  return [ordered]@{
    endpoint_chain = @("GET /admin/models/{id}", "PATCH /admin/models/{id}", "GET /admin/models/{id}", "PATCH /admin/models/{id} restore")
    model_id = $modelId
    canonical_model_key = $CanonicalModelKey
    configured_default_price_book_id = $DefaultPriceBookId
    original_default_price_book_id = $originalDefaultPriceBookId
    set_readback_default_price_book_id = [string]$readbackPayload.data.default_price_book_id
    restored = $restoreSucceeded
    credential_material_omitted = $true
    secret_safe_response = (Test-SecretSafeText (@($setPayload, $readbackPayload) | ConvertTo-Json -Depth 64 -Compress))
  }
}

function Get-AdminUiEntryEvidence {
  $modelsPagePath = Resolve-RepoPath "web/admin-ui/src/components/ModelsPage.tsx"
  $dryRunPath = Resolve-RepoPath "web/admin-ui/src/components/ModelAssociationDryRun.tsx"
  $clientPath = Resolve-RepoPath "web/admin-ui/src/api/client.ts"
  $modelsPage = Get-Content -Raw $modelsPagePath
  $dryRunComponent = Get-Content -Raw $dryRunPath
  $client = Get-Content -Raw $clientPath

  $dryRunEntryPresent = (
    $modelsPage -match 'ModelAssociationDryRun' -and
    $dryRunComponent -match 'dryRunModelAssociation' -and
    $client -match '/admin/model-associations/dry-run'
  )
  $defaultPriceUiPresent = (
    $modelsPage -match 'defaultPriceBookId|default_price_book_id|Price book' -and
    $client -match 'default_price_book_id'
  )

  $blockers = @()
  if (-not $defaultPriceUiPresent) {
    $blockers += "Admin UI default price book selector/config control is not implemented in ModelsPage/client static coverage."
  }
  $blockers += "No real browser or Playwright session was executed by this PowerShell verifier; API distribution is unaffected."

  return [ordered]@{
    static_source_scan = [ordered]@{
      files = @(
        Get-RepoRelativePath $modelsPagePath
        Get-RepoRelativePath $dryRunPath
        Get-RepoRelativePath $clientPath
      )
      model_association_dry_run_entry_present = [bool]$dryRunEntryPresent
      default_price_selector_ui_present = [bool]$defaultPriceUiPresent
      dry_run_endpoint_client_present = [bool]($client -match '/admin/model-associations/dry-run')
      default_price_api_client_typed = [bool]($client -match 'default_price_book_id')
    }
    browser_session = [ordered]@{
      executed = $false
      tool = "not_invoked"
      blocker = "No real browser or Playwright session was provided/executed in this verifier environment."
    }
    blockers = $blockers
  }
}

function New-ResumeCommand {
  if ($script:Blockers.Count -gt 0 -and ($script:Blockers -join " ") -match "dev seed prerequisite") {
    return "docker compose -f deploy/docker-compose/docker-compose.yml exec -T postgres psql -U ai_gateway -d ai_gateway -f /app/db/dev-seeds/0003_dev_smoke_seed_reconcile.sql; powershell -ExecutionPolicy Bypass -File scripts/verify_control_plane_model_association_dry_run_live.ps1"
  }
  if ($script:Blockers.Count -gt 0 -and ($script:Blockers -join " ") -match "admin login|session_token|401|403|unauthorized") {
    return "powershell -ExecutionPolicy Bypass -File scripts/verify_control_plane_auth_smoke.ps1 -RepairDevAdminSessionPrereqs; powershell -ExecutionPolicy Bypass -File scripts/verify_control_plane_model_association_dry_run_live.ps1"
  }
  if ($script:Blockers.Count -gt 0) {
    return "docker compose -f deploy/docker-compose/docker-compose.yml up -d postgres redis control-plane admin-ui; powershell -ExecutionPolicy Bypass -File scripts/verify_control_plane_model_association_dry_run_live.ps1"
  }
  return "powershell -ExecutionPolicy Bypass -File scripts/verify_control_plane_model_association_dry_run_live.ps1"
}

function Write-ArtifactAndExit {
  $status = if ($script:Failures.Count -eq 0 -and $script:Blockers.Count -eq 0) { "pass" } elseif ($script:Failures.Count -gt 0) { "fail" } else { "blocked" }
  $selected = $null
  $candidates = @()
  $selection = $null
  if ($null -ne $script:LiveResponse -and $null -ne $script:LiveResponse.data) {
    $selection = $script:LiveResponse.data.selection
    $selected = $script:LiveResponse.data.selected_candidate
    $candidates = @($script:LiveResponse.data.candidates)
  }

  $artifact = [ordered]@{
    schema_version = "control_plane_model_association_dry_run_live_verification.v1"
    status = $status
    checked_at_utc = [DateTimeOffset]::UtcNow.ToString("o")
    live_api = [ordered]@{
      base_url = $ControlPlaneBaseUrl
      endpoint = "POST /admin/model-associations/dry-run"
      admin_session_source = "dev_admin_login"
      admin_session_token_recorded = $false
      request = [ordered]@{
        project_id = $ProjectId
        profile_id = $ProfileId
        requested_model = $RequestedModel
        canonical_model_key = $CanonicalModelKey
        seed = $Seed
        trace_id = "e4-live-chain-model-association-dry-run"
        previous_successful_channel_id = $PreviousSuccessfulChannelId
      }
      selection = $selection
      selected_candidate = $selected
      candidate_count = @($candidates).Count
      candidates = $candidates
      credential_material_omitted = $true
      secret_safe_response = if ($null -eq $script:LiveResponse) { $null } else { Test-SecretSafeText ($script:LiveResponse | ConvertTo-Json -Depth 64 -Compress) }
    }
    default_price_config_api_live = $script:DefaultPriceLive
    admin_ui_operation_chain_evidence = $script:AdminUiEvidence
    compose = [ordered]@{
      file = $ComposeFile
      required_services = @("postgres", "control-plane", "admin-ui")
      services = @($script:ComposeServices | ForEach-Object {
          [ordered]@{
            service = $_.Service
            state = $_.State
            ports = $_.Publishers
          }
        })
    }
    seed_status = $script:SeedStatus
    checks = @($script:Checks.ToArray())
    failures = @($script:Failures.ToArray())
    blockers = @($script:Blockers.ToArray())
    resume_command = New-ResumeCommand
    notes = @(
      "Live verification logs into the real Control Plane admin API and posts to /admin/model-associations/dry-run.",
      "Default price selector live smoke patches the seeded canonical model default_price_book_id, reads it back, then restores the original selector.",
      "Admin UI evidence is static source coverage plus an explicit browser-session blocker when no real browser chain was run.",
      "The artifact intentionally omits session tokens, provider encrypted_secret, secret_fingerprint, and raw provider credentials."
    )
  }

  $artifactText = $artifact | ConvertTo-Json -Depth 64
  if (-not (Test-SecretSafeText $artifactText)) {
    Add-Failure "[FAIL] artifact secret safety - generated artifact contains credential-like material"
    $artifact.failures = @($script:Failures.ToArray())
    $artifact.status = "fail"
    $artifactText = $artifact | ConvertTo-Json -Depth 64
  }

  if (-not $NoWrite) {
    $outputFullPath = Resolve-RepoPath $OutputPath
    $outputRelative = Get-RepoRelativePath $outputFullPath
    if ($outputRelative.StartsWith("..", [System.StringComparison]::Ordinal) -or [System.IO.Path]::IsPathRooted($outputRelative)) {
      throw "OutputPath must stay inside the repository"
    }
    if (-not $outputRelative.StartsWith(".tmp/control-plane/", [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "OutputPath must stay under .tmp/control-plane/"
    }
    $outputDirectory = Split-Path -Parent $outputFullPath
    if (-not (Test-Path $outputDirectory)) {
      New-Item -ItemType Directory -Path $outputDirectory | Out-Null
    }
    $artifactText | Set-Content -Path $outputFullPath -Encoding UTF8
    Write-Host "Wrote $(Get-RepoRelativePath $outputFullPath)"
  }

  if ($script:Failures.Count -gt 0) { exit 1 }
  if ($script:Blockers.Count -gt 0) { exit 2 }
  exit 0
}

Push-Location $repoRoot
try {
  Check "parameters" {
    $uri = [Uri]$ControlPlaneBaseUrl
    Assert-True ($uri.IsAbsoluteUri -and ($uri.Scheme -eq "http" -or $uri.Scheme -eq "https")) "ControlPlaneBaseUrl must be an absolute http(s) URL"
    Assert-True ($TimeoutSeconds -ge 1) "TimeoutSeconds must be at least 1"
    Assert-True (-not [string]::IsNullOrWhiteSpace($AdminEmail)) "AdminEmail must not be empty"
    Assert-True (-not [string]::IsNullOrWhiteSpace($AdminPassword)) "AdminPassword must not be empty"
    Assert-True (-not [string]::IsNullOrWhiteSpace($DefaultPriceBookId)) "DefaultPriceBookId must not be empty"
  }

  Check "admin UI static entry coverage" {
    $script:AdminUiEvidence = Get-AdminUiEntryEvidence
    Assert-True ($script:AdminUiEvidence.static_source_scan.model_association_dry_run_entry_present -eq $true) "Admin UI model association dry-run entry is missing"
  }

  Check-Blocking "compose control-plane/admin session/dev admin services available" {
    $script:ComposeServices = @(Get-ComposeServices)
    Assert-ServiceRunning -Services $script:ComposeServices -ServiceName "postgres"
    Assert-ServiceRunning -Services $script:ComposeServices -ServiceName "control-plane"
    Assert-ServiceRunning -Services $script:ComposeServices -ServiceName "admin-ui"
  }

  Check-Blocking "seeded model association dry-run data available" {
    $script:SeedStatus = Get-SeedStatus
    Assert-SeedStatus -Status $script:SeedStatus
  }

  Check-Blocking "dev admin login returns usable session" {
    $script:AdminSessionToken = Invoke-AdminLogin
  }

  if ($script:Blockers.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($script:AdminSessionToken)) {
    Check "live POST /admin/model-associations/dry-run selected candidate" {
      $body = @{
        project_id = $ProjectId
        profile_id = $ProfileId
        requested_model = $RequestedModel
        canonical_model_key = $CanonicalModelKey
        seed = $Seed
        trace_id = "e4-live-chain-model-association-dry-run"
        previous_successful_channel_id = $PreviousSuccessfulChannelId
      }
      $response = Invoke-ApiRequest -Method "POST" -Path "/admin/model-associations/dry-run" -Body $body -SessionToken $script:AdminSessionToken
      Assert-Status -Response $response -Expected 200
      $script:LiveResponse = Read-Json $response.Content
      Assert-DryRunResponse -Payload $script:LiveResponse
    }

    Check "live default price selector PATCH/GET/restore" {
      $script:DefaultPriceLive = Invoke-DefaultPriceSelectorLiveSmoke -SessionToken $script:AdminSessionToken
      Assert-True ($script:DefaultPriceLive.restored -eq $true) "default price selector restore did not complete"
      Assert-True ($script:DefaultPriceLive.secret_safe_response -eq $true) "default price selector response leaks credential-like material"
    }
  }
} finally {
  if (-not [string]::IsNullOrWhiteSpace($script:AdminSessionToken)) {
    try {
      Invoke-AdminLogout -SessionToken $script:AdminSessionToken
    } catch {
      Add-Failure "[FAIL] dev admin logout - $($_.Exception.Message)"
    }
  }
  Pop-Location
}

Write-ArtifactAndExit
