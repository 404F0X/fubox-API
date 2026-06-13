param(
  [string]$GatewayBaseUrl = "http://127.0.0.1:8080",
  [string]$GatewayAuthToken = "dev_test_key_123456789",
  [string]$DefaultModel = "mock-gpt-4o-mini",
  [string]$SwitchProfile = "",
  [string]$SwitchModel = "",
  [string]$InvalidProfile = "",
  [string]$ComposeFile = "deploy/docker-compose/docker-compose.yml",
  [int]$TimeoutSeconds = 8,
  [int]$DbPollSeconds = 10,
  [switch]$SkipComposePs,
  [switch]$SkipDbLog,
  [switch]$SkipNetwork,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$fixturePath = Join-Path $repoRoot "tests\fixtures\gateway\profile_switching.json"
$v1ModelsFixturePath = Join-Path $repoRoot "tests\fixtures\gateway\v1_models_profile_visibility_contract.json"
$script:Failures = @()
$script:Pending = @()
$script:SwitchProfileWasProvided = -not [string]::IsNullOrWhiteSpace($SwitchProfile)
$script:SwitchModelWasProvided = -not [string]::IsNullOrWhiteSpace($SwitchModel)
$script:SelectedSwitchModel = $SwitchModel

function Test-TruthyEnv {
  param([string]$Value)

  return $Value -eq "1" -or $Value -match "^(true|yes|on)$"
}

if ($env:GATEWAY_BASE_URL) { $GatewayBaseUrl = $env:GATEWAY_BASE_URL }
if ($env:GATEWAY_AUTH_TOKEN) { $GatewayAuthToken = $env:GATEWAY_AUTH_TOKEN }
if ($env:SMOKE_MODEL) { $DefaultModel = $env:SMOKE_MODEL }
if ($env:PROFILE_SMOKE_DEFAULT_MODEL) { $DefaultModel = $env:PROFILE_SMOKE_DEFAULT_MODEL }
if ($env:PROFILE_SMOKE_SWITCH_PROFILE) {
  $SwitchProfile = $env:PROFILE_SMOKE_SWITCH_PROFILE
  $script:SwitchProfileWasProvided = $true
}
if ($env:PROFILE_SMOKE_SWITCH_MODEL) {
  $SwitchModel = $env:PROFILE_SMOKE_SWITCH_MODEL
  $script:SelectedSwitchModel = $SwitchModel
  $script:SwitchModelWasProvided = $true
}
if ($env:PROFILE_SMOKE_INVALID_PROFILE) { $InvalidProfile = $env:PROFILE_SMOKE_INVALID_PROFILE }
if ($env:COMPOSE_FILE) { $ComposeFile = $env:COMPOSE_FILE }
if (Test-TruthyEnv $env:PROFILE_SMOKE_SKIP_COMPOSE_PS) { $SkipComposePs = $true }
if (Test-TruthyEnv $env:PROFILE_SMOKE_SKIP_DB_LOG) { $SkipDbLog = $true }
if (Test-TruthyEnv $env:PROFILE_SMOKE_SKIP_NETWORK) { $SkipNetwork = $true }
if (Test-TruthyEnv $env:PROFILE_SMOKE_DRY_RUN) { $DryRun = $true }

Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Security

function Redact-SecretLikeString {
  param([AllowNull()][string]$Text)

  if ($null -eq $Text) {
    return ""
  }

  $redacted = $Text
  foreach ($knownSecret in @($GatewayAuthToken, $ControlPlaneAuthToken, $AdminPassword, $AdminSessionToken, $script:AdminSessionToken)) {
    if (-not [string]::IsNullOrEmpty($knownSecret)) {
      $redacted = $redacted.Replace([string]$knownSecret, "[REDACTED]")
    }
  }

  $redacted = $redacted -replace '(?i)(authorization\s*[:=]\s*bearer\s+)[^\s";,}]+', '${1}[REDACTED]'
  $redacted = $redacted -replace '(?i)(Bearer\s+)[A-Za-z0-9._~+/\-]+=*', '${1}[REDACTED]'
  $redacted = $redacted -replace '(?i)("(?:[^"\\]|\\.)*(?:token|password|passwd|secret|api[_-]?key|access[_-]?key|private[_-]?key|provider[_-]?key)(?:[^"\\]|\\.)*"\s*:\s*")(?:(?:\\.)|[^"\\])*(")', '${1}[REDACTED]${2}'
  $redacted = $redacted -replace '(?i)([a-z][a-z0-9+.-]*://)[^/?#@\s:]+:[^/?#@\s]*@', '${1}[REDACTED]:[REDACTED]@'
  $redacted = $redacted -replace '(?i)([a-z][a-z0-9+.-]*://)[^/?#@\s:]+@', '${1}[REDACTED]@'
  $redacted = $redacted -replace '(?i)([?&;][^=&#\s]*(?:api[_-]?key|token|password|passwd|secret)[^=&#\s]*=)[^&#\s"<>]+', '${1}[REDACTED]'
  $redacted = $redacted -replace '(?i)(\b[A-Za-z0-9_-]*(?:token|password|passwd|secret|api[_-]?key|access[_-]?key|private[_-]?key|provider[_-]?key)[A-Za-z0-9_-]*\s*[:=]\s*)[^\s";,}\]]+', '${1}[REDACTED]'
  $redacted = $redacted -replace 'sk-[A-Za-z0-9._~+\-/=]+', '[REDACTED]'
  $redacted = $redacted -replace 'dev_test_key_[A-Za-z0-9._~+\-/=]+', '[REDACTED]'
  $redacted = $redacted -replace '(?i)\$env:[A-Z0-9_]*(?:token|password|passwd|secret|api[_-]?key|access[_-]?key|private[_-]?key|provider[_-]?key)[A-Z0-9_]*', '[REDACTED]'
  $redacted = $redacted -replace '(?i)(?<![A-Za-z0-9_])env:[/\\]?[A-Z0-9_]*(?:token|password|passwd|secret|api[_-]?key|access[_-]?key|private[_-]?key|provider[_-]?key)[A-Z0-9_]*', '[REDACTED]'
  $redacted = $redacted -replace '(?i)\$\{[A-Z0-9_]*(?:token|password|passwd|secret|api[_-]?key|access[_-]?key|private[_-]?key|provider[_-]?key)[A-Z0-9_]*\}', '[REDACTED]'
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

function Add-Pending {
  param([Parameter(Mandatory = $true)][string]$Message)

  $safe = Redact-SecretLikeString $Message
  $script:Pending += $safe
  Write-SafeHost $safe
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

function Report-Pending {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Message
  )

  Add-Pending "[PENDING] $Name - $Message"
}

function Join-Url {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$Path
  )

  return $BaseUrl.TrimEnd("/") + $Path
}

function ConvertTo-JsonString {
  param([Parameter(Mandatory = $true)][string]$Value)

  return ($Value | ConvertTo-Json -Compress)
}

function New-ChatBodyJson {
  param(
    [Parameter(Mandatory = $true)][string]$RequestModel,
    [Parameter(Mandatory = $true)][string]$Content
  )

  return '{"model":' + (ConvertTo-JsonString $RequestModel) + ',"messages":[{"role":"user","content":' + (ConvertTo-JsonString $Content) + '}],"stream":false}'
}

function Get-Sha256Hex {
  param([Parameter(Mandatory = $true)][string]$Text)

  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Escape-SqlLiteral {
  param([Parameter(Mandatory = $true)][string]$Value)

  return $Value.Replace("'", "''")
}

function Get-VirtualKeyPrefix {
  param([Parameter(Mandatory = $true)][string]$RawKey)

  $trimmed = $RawKey.Trim()
  if ($trimmed.Length -lt 12) {
    throw "GatewayAuthToken is too short to derive the virtual key prefix"
  }

  return $trimmed.Substring(0, 12)
}

function Get-JsonPropertyValue {
  param(
    [AllowNull()]$Object,
    [Parameter(Mandatory = $true)][string]$Name,
    $Default = $null
  )

  if ($null -eq $Object) {
    return $Default
  }

  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $Default
  }

  return $property.Value
}

function Read-Json {
  param([Parameter(Mandatory = $true)][string]$Content)

  try {
    return $Content | ConvertFrom-Json
  } catch {
    throw "expected JSON response, got: $Content"
  }
}

function Read-Fixture {
  if (-not (Test-Path $fixturePath)) {
    throw "missing tests\fixtures\gateway\profile_switching.json"
  }

  try {
    return Get-Content -Raw $fixturePath | ConvertFrom-Json
  } catch {
    throw "profile_switching.json is not valid JSON: $($_.Exception.Message)"
  }
}

function Read-V1ModelsFixture {
  if (-not (Test-Path $v1ModelsFixturePath)) {
    throw "missing tests\fixtures\gateway\v1_models_profile_visibility_contract.json"
  }

  try {
    return Get-Content -Raw $v1ModelsFixturePath | ConvertFrom-Json
  } catch {
    throw "v1_models_profile_visibility_contract.json is not valid JSON: $($_.Exception.Message)"
  }
}

function Assert-FixtureEndpointIntent {
  param([Parameter(Mandatory = $true)]$Fixture)

  if ($Fixture.scenario -ne "gateway_profile_switching_smoke") {
    throw "fixture scenario must be gateway_profile_switching_smoke"
  }
  if ($Fixture.profile_header -ne "x-ai-profile") {
    throw "fixture profile_header must be x-ai-profile"
  }
  if ($Fixture.profiles.default.selector -ne "omit x-ai-profile header") {
    throw "fixture default selector must omit x-ai-profile header"
  }
  if ($Fixture.profiles.default.missing_profile_header_behavior -ne "use_default_profile") {
    throw "fixture default missing_profile_header_behavior must be use_default_profile"
  }
  if ($Fixture.profiles.switch.selector -notmatch "x-ai-profile") {
    throw "fixture switch selector must explicitly use x-ai-profile"
  }
  if ($Fixture.endpoints.models.method -ne "GET" -or $Fixture.endpoints.models.path -ne "/v1/models") {
    throw "fixture must declare GET /v1/models"
  }
  if ($Fixture.endpoints.chat_completions.method -ne "POST" -or $Fixture.endpoints.chat_completions.path -ne "/v1/chat/completions") {
    throw "fixture must declare POST /v1/chat/completions"
  }
  if (-not $Fixture.profiles.default.expected_visible_models -or $Fixture.profiles.default.expected_visible_models.Count -eq 0) {
    throw "fixture default profile must declare expected_visible_models"
  }
  if ($Fixture.profiles.default.expected_visible_model_visibility -ne "public") {
    throw "fixture default profile expected_visible_model_visibility must be public"
  }
  if (-not $Fixture.profiles.switch.example_expected_visible_models -or $Fixture.profiles.switch.example_expected_visible_models.Count -eq 0) {
    throw "fixture switch profile must declare example_expected_visible_models"
  }
  if ($Fixture.profiles.switch.example_expected_visible_model_visibility -ne "internal") {
    throw "fixture switch profile example_expected_visible_model_visibility must be internal"
  }
  if (-not $Fixture.profiles.switch.must_differ_from_default_models) {
    throw "fixture switch profile must require a different model set"
  }
  $defaultModelSet = ConvertTo-ModelSetKey @([string[]]$Fixture.profiles.default.expected_visible_models)
  $switchModelSet = ConvertTo-ModelSetKey @([string[]]$Fixture.profiles.switch.example_expected_visible_models)
  if ($defaultModelSet -eq $switchModelSet) {
    throw "fixture default and switch expected model sets must differ"
  }
  if ($Fixture.profiles.invalid.expected_status -ne 403) {
    throw "fixture invalid profile expected_status must be 403"
  }
  if ($Fixture.profiles.invalid.expected_error_code -ne "api_key_profile_forbidden") {
    throw "fixture invalid profile expected_error_code must be api_key_profile_forbidden"
  }
  if ([string]::IsNullOrWhiteSpace([string]$Fixture.profiles.invalid.profile_ref)) {
    throw "fixture invalid profile must declare profile_ref"
  }
}

function Assert-FixtureVisibilityContract {
  param([Parameter(Mandatory = $true)]$Fixture)

  $contract = $Fixture.model_visibility_contract
  if (-not $contract) {
    throw "fixture must declare model_visibility_contract"
  }

  $visible = @($contract.visible_visibilities | ForEach-Object { [string]$_ })
  foreach ($visibility in @("public", "internal")) {
    if ($visible -notcontains $visibility) {
      throw "model_visibility_contract.visible_visibilities must include $visibility"
    }
  }

  if ($contract.default_profile_visibility -ne "public") {
    throw "model_visibility_contract.default_profile_visibility must be public"
  }
  if ($contract.switched_profile_visibility -ne "internal") {
    throw "model_visibility_contract.switched_profile_visibility must be internal"
  }
  if ($contract.private_models_visible -ne $false) {
    throw "model_visibility_contract.private_models_visible must be false"
  }
  if ($contract.internal_models_require_profile_binding -ne $true) {
    throw "model_visibility_contract.internal_models_require_profile_binding must be true"
  }
}

function Assert-V1ModelsFixtureContract {
  param([Parameter(Mandatory = $true)]$Fixture)

  if ($Fixture.scenario -ne "gateway_v1_models_profile_visibility_contract") {
    throw "v1 models fixture scenario must be gateway_v1_models_profile_visibility_contract"
  }
  if ($Fixture.endpoint.method -ne "GET" -or $Fixture.endpoint.path -ne "/v1/models") {
    throw "v1 models fixture must declare GET /v1/models"
  }
  if ($Fixture.endpoint.profile_header -ne "x-ai-profile") {
    throw "v1 models fixture profile_header must be x-ai-profile"
  }

  $predicates = @($Fixture.filter_contract.model_sql_predicates | ForEach-Object { [string]$_ })
  foreach ($required in @(
      "empty allowed_models means no profile allowlist restriction",
      "non-empty allowed_models must contain canonical_models.model_key",
      "denied_models containing canonical_models.model_key excludes the model",
      "allowed_channel_tags must match at least one enabled OpenAI-compatible route channel when configured",
      "blocked_provider_ids excludes models whose only candidate routes use blocked providers",
      "a model is listed only when at least one enabled model_association, non-deleted OpenAI-compatible channel, enabled provider, and currently usable provider_key exists"
    )) {
    if ($predicates -notcontains $required) {
      throw "v1 models fixture is missing predicate: $required"
    }
  }

  $negativeCase = @($Fixture.acceptance_cases | Where-Object { $_.name -eq "unroutable_or_provider_blocked_model_hidden" })
  if ($negativeCase.Count -ne 1) {
    throw "v1 models fixture must include unroutable_or_provider_blocked_model_hidden acceptance case"
  }
  if ($Fixture.secret_safety.full_virtual_key_returned -ne $false -or
      $Fixture.secret_safety.authorization_header_returned -ne $false -or
      $Fixture.secret_safety.provider_key_returned -ne $false) {
    throw "v1 models fixture secret_safety must forbid key/header/provider secret echoes"
  }
}

function Assert-DryRunHeaderConstruction {
  param([Parameter(Mandatory = $true)]$Fixture)

  $profileHeader = [string]$Fixture.profile_header
  $defaultHeaders = New-GatewayHeaders
  if ($defaultHeaders.ContainsKey($profileHeader)) {
    throw "default profile request must omit $profileHeader"
  }

  $switchProfileRef = [string]$Fixture.profiles.switch.example_profile_ref
  if ([string]::IsNullOrWhiteSpace($switchProfileRef)) {
    throw "fixture switch profile must declare example_profile_ref"
  }
  $switchHeaders = New-GatewayHeaders -ProfileRef $switchProfileRef
  if ($switchHeaders[$profileHeader] -ne $switchProfileRef) {
    throw "switch profile request must send $profileHeader=$switchProfileRef"
  }

  $invalidProfileRef = [string]$Fixture.profiles.invalid.profile_ref
  $invalidHeaders = New-GatewayHeaders -ProfileRef $invalidProfileRef
  if ($invalidHeaders[$profileHeader] -ne $invalidProfileRef) {
    throw "invalid profile request must send $profileHeader=$invalidProfileRef"
  }
}

function Invoke-ProfileRequest {
  param(
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Uri,
    [string]$JsonBody = $null,
    [hashtable]$Headers = @{},
    [int]$TimeoutSec = $TimeoutSeconds
  )

  $client = New-Object System.Net.Http.HttpClient
  $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
  $request = New-Object System.Net.Http.HttpRequestMessage -ArgumentList (New-Object System.Net.Http.HttpMethod -ArgumentList $Method), $Uri

  foreach ($key in $Headers.Keys) {
    [void]$request.Headers.TryAddWithoutValidation($key, [string]$Headers[$key])
  }

  if (($Method -eq "GET" -or $Method -eq "HEAD") -and -not [string]::IsNullOrEmpty($JsonBody)) {
    throw "$Method requests must not include a JSON body"
  }

  if (-not [string]::IsNullOrEmpty($JsonBody)) {
    $content = New-Object System.Net.Http.StringContent -ArgumentList $JsonBody
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
  } finally {
    if ($response) { $response.Dispose() }
    $request.Dispose()
    $client.Dispose()
  }
}

function New-GatewayHeaders {
  param([string]$ProfileRef = "")

  $headers = @{ Authorization = "Bearer $GatewayAuthToken" }
  if (-not [string]::IsNullOrWhiteSpace($ProfileRef)) {
    $headers["x-ai-profile"] = $ProfileRef
  }

  return $headers
}

function Assert-Status {
  param(
    [Parameter(Mandatory = $true)]$Response,
    [Parameter(Mandatory = $true)][int]$Expected
  )

  if ($Response.StatusCode -ne $Expected) {
    throw "expected HTTP $Expected, got HTTP $($Response.StatusCode): $($Response.Content)"
  }
}

function Assert-Contains {
  param(
    [Parameter(Mandatory = $true)][string]$Content,
    [Parameter(Mandatory = $true)][string]$Needle
  )

  if (-not $Content.Contains($Needle)) {
    throw "response does not contain '$Needle'"
  }
}

function Assert-ErrorResponse {
  param(
    [Parameter(Mandatory = $true)]$Response,
    [Parameter(Mandatory = $true)][int]$ExpectedStatus,
    [Parameter(Mandatory = $true)][string]$ExpectedCode
  )

  Assert-Status $Response $ExpectedStatus
  $payload = Read-Json $Response.Content
  $actualCode = Get-JsonPropertyValue (Get-JsonPropertyValue $payload "error") "code"
  if ($actualCode -ne $ExpectedCode) {
    throw "expected error.code=$ExpectedCode, got '$actualCode': $($Response.Content)"
  }
}

function Get-ModelIds {
  param([Parameter(Mandatory = $true)]$Payload)

  $ids = @()
  foreach ($entry in @($Payload.data)) {
    if ($entry -and $entry.id) {
      $ids += [string]$entry.id
    }
  }

  return @($ids)
}

function ConvertTo-ModelSetKey {
  param([string[]]$ModelIds)

  return ((@($ModelIds) | Sort-Object -Unique) -join "`n")
}

function Test-ModelListContains {
  param(
    [string[]]$ModelIds,
    [Parameter(Mandatory = $true)][string]$ExpectedModel
  )

  return @($ModelIds) -contains $ExpectedModel
}

function Get-ProfileIdFromModelsPayload {
  param([Parameter(Mandatory = $true)]$Payload)

  $gateway = Get-JsonPropertyValue $Payload "gateway"
  $profileId = Get-JsonPropertyValue $gateway "profile_id"
  if ($null -eq $profileId) {
    return ""
  }

  return [string]$profileId
}

function Assert-ModelsResponse {
  param(
    [Parameter(Mandatory = $true)]$Response,
    [Parameter(Mandatory = $true)][string]$Name
  )

  Assert-Status $Response 200
  $payload = Read-Json $Response.Content
  if ($payload.object -ne "list") {
    throw "$Name expected object=list, got '$($payload.object)'"
  }

  $models = @(Get-ModelIds $payload)
  if ($models.Count -eq 0) {
    throw "$Name returned an empty data[] model list"
  }

  $profileId = Get-ProfileIdFromModelsPayload $payload
  if ([string]::IsNullOrWhiteSpace($profileId)) {
    throw "$Name response did not include gateway.profile_id"
  }

  return [PSCustomObject]@{
    Payload = $payload
    ModelIds = $models
    ProfileId = $profileId
  }
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

function Reset-DefaultProfileRuntimeState {
  $prefix = Escape-SqlLiteral (Get-VirtualKeyPrefix $GatewayAuthToken)
  $hash = Escape-SqlLiteral (Get-Sha256Hex $GatewayAuthToken)
  $model = Escape-SqlLiteral $DefaultModel

  $sql = @"
with key_info as (
  select tenant_id, project_id, id as virtual_key_id
  from virtual_keys
  where key_prefix = '$prefix'
    and secret_hash = '$hash'
    and status <> 'deleted'
    and deleted_at is null
),
default_profile as (
  select p.*
  from key_info ki
  join virtual_key_profile_bindings b
    on b.tenant_id = ki.tenant_id
   and b.project_id = ki.project_id
   and b.virtual_key_id = ki.virtual_key_id
   and b.is_default = true
  join api_key_profiles p
    on p.tenant_id = b.tenant_id
   and p.project_id = b.project_id
   and p.id = b.profile_id
   and p.status = 'active'
   and p.deleted_at is null
),
canonical as (
  select m.*
  from default_profile p
  join canonical_models m
    on m.tenant_id = p.tenant_id
   and m.model_key = coalesce(nullif(p.model_aliases ->> '$model', ''), '$model')
   and m.status = 'active'
   and m.visibility in ('public', 'internal')
   and m.deleted_at is null
  where (
      coalesce(jsonb_array_length(p.allowed_models), 0) = 0
      or p.allowed_models ? m.model_key
    )
    and not (coalesce(p.denied_models, '[]'::jsonb) ? m.model_key)
),
candidate_channels as (
  select distinct ch.tenant_id, ch.id as channel_id
  from default_profile p
  join canonical m on m.tenant_id = p.tenant_id
  join model_associations ma
    on ma.tenant_id = p.tenant_id
   and ma.canonical_model_id = m.id
   and ma.status = 'enabled'
   and ma.deleted_at is null
  join channels ch
    on ch.tenant_id = ma.tenant_id
   and (
     (ma.association_type = 'explicit_channel' and ch.id = ma.channel_id)
     or (ma.association_type = 'channel_tag' and ma.channel_tag is not null and ch.tags ? ma.channel_tag)
     or ma.association_type = 'global'
     or (ma.association_type = 'model_pattern' and ma.model_pattern is not null and m.model_key ~ ma.model_pattern)
   )
   and ch.status <> 'deleted'
   and ch.deleted_at is null
  join providers pr
    on pr.tenant_id = ch.tenant_id
   and pr.id = ch.provider_id
   and pr.status = 'enabled'
   and pr.deleted_at is null
  where (
      coalesce(jsonb_array_length(p.allowed_channel_tags), 0) = 0
      or exists (
        select 1
        from jsonb_array_elements_text(p.allowed_channel_tags) allowed(tag)
        where ch.tags ? allowed.tag
      )
    )
    and not (coalesce(p.blocked_provider_ids, '[]'::jsonb) ? pr.id::text)
),
updated as (
  update provider_keys pk
     set status = 'enabled',
         cooldown_until = null,
         last_error_code = null,
         health_score = 1.0,
         updated_at = now()
    from candidate_channels ch
   where pk.tenant_id = ch.tenant_id
     and pk.channel_id = ch.channel_id
     and pk.deleted_at is null
     and pk.status in ('enabled', 'cooldown', 'degraded', 'auth_failed', 'quota_exhausted', 'recovery_probe')
  returning pk.id::text
)
select coalesce(jsonb_agg(id), '[]'::jsonb)::text from updated;
"@

  $updated = @(Invoke-ComposePsql $sql | ConvertFrom-Json)
  if ($updated.Count -lt 1) {
    throw "default profile runtime reset did not find an eligible provider key for model '$DefaultModel'"
  }
}

function Get-BoundProfilesForToken {
  $prefix = Escape-SqlLiteral (Get-VirtualKeyPrefix $GatewayAuthToken)
  $hash = Escape-SqlLiteral (Get-Sha256Hex $GatewayAuthToken)

  $sql = @"
select coalesce(jsonb_agg(to_jsonb(t) order by t.is_default desc, t.profile_name asc), '[]'::jsonb)::text
from (
  select
    p.id::text as profile_id,
    p.name as profile_name,
    p.status as profile_status,
    b.is_default,
    p.allowed_models
  from virtual_keys vk
  join virtual_key_profile_bindings b
    on b.tenant_id = vk.tenant_id
   and b.project_id = vk.project_id
   and b.virtual_key_id = vk.id
  join api_key_profiles p
    on p.tenant_id = b.tenant_id
   and p.project_id = b.project_id
   and p.id = b.profile_id
   and p.deleted_at is null
  where vk.key_prefix = '$prefix'
    and vk.secret_hash = '$hash'
    and vk.status <> 'deleted'
) t;
"@

  $json = Invoke-ComposePsql $sql
  if ([string]::IsNullOrWhiteSpace($json)) {
    return @()
  }

  return @($json | ConvertFrom-Json)
}

function Set-DiscoveredSwitchProfile {
  param([object[]]$Profiles)

  if ($script:SwitchProfileWasProvided -or -not [string]::IsNullOrWhiteSpace($SwitchProfile)) {
    return
  }

  $candidate = @($Profiles | Where-Object { -not $_.is_default -and $_.profile_status -eq "active" } | Select-Object -First 1)
  if ($candidate.Count -eq 0) {
    return
  }

  if (-not [string]::IsNullOrWhiteSpace([string]$candidate[0].profile_name)) {
    $script:SwitchProfile = [string]$candidate[0].profile_name
  } else {
    $script:SwitchProfile = [string]$candidate[0].profile_id
  }
}

function Assert-BoundProfilePreconditions {
  param([object[]]$Profiles)

  if ($Profiles.Count -eq 0) {
    throw "no profile bindings found for the supplied virtual key in compose postgres"
  }

  $defaultProfiles = @($Profiles | Where-Object { $_.is_default -and $_.profile_status -eq "active" })
  if ($defaultProfiles.Count -eq 0) {
    throw "the supplied virtual key does not have an active default profile binding"
  }

  if ([string]::IsNullOrWhiteSpace($SwitchProfile)) {
    throw "no switch profile was supplied or discovered; set PROFILE_SMOKE_SWITCH_PROFILE or bind a second active profile to the same virtual key"
  }

  $switch = @($Profiles | Where-Object {
      $_.profile_status -eq "active" -and (
        ([string]$_.profile_id).ToLowerInvariant() -eq $SwitchProfile.ToLowerInvariant() -or
        [string]$_.profile_name -eq $SwitchProfile
      )
    })
  if ($switch.Count -eq 0) {
    if (-not $script:SwitchProfileWasProvided) {
      throw "switch profile '$SwitchProfile' is not an active profile binding for the supplied virtual key"
    }
    return
  }

  if ($Profiles.Count -lt 2) {
    throw "expected at least two profile bindings for the same virtual key"
  }
}

function Get-RequestLogRowsByHash {
  param([Parameter(Mandatory = $true)][string]$RequestHash)

  $hash = Escape-SqlLiteral $RequestHash
  $sql = @"
select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb)::text
from (
  select
    rl.id::text as request_id,
    rl.api_key_profile_id::text as api_key_profile_id,
    rl.status as request_status,
    rl.http_status as request_http_status,
    rl.requested_model,
    rl.canonical_model_id::text as canonical_model_id,
    rl.upstream_model,
    rl.resolved_provider_id::text as resolved_provider_id,
    rl.resolved_channel_id::text as resolved_channel_id,
    rl.route_policy_version,
    rl.route_decision_snapshot
  from request_logs rl
  where rl.request_body_hash = '$hash'
  order by rl.created_at desc
  limit 1
) t;
"@

  $json = Invoke-ComposePsql $sql
  if ([string]::IsNullOrWhiteSpace($json)) {
    return @()
  }

  return @($json | ConvertFrom-Json)
}

function Wait-RequestLogRowsByHash {
  param([Parameter(Mandatory = $true)][string]$RequestHash)

  $deadline = (Get-Date).AddSeconds($DbPollSeconds)
  while ((Get-Date) -lt $deadline) {
    $rows = @(Get-RequestLogRowsByHash $RequestHash)
    if ($rows.Count -gt 0) {
      return $rows
    }

    Start-Sleep -Seconds 1
  }

  throw "request_logs row with request_body_hash=$RequestHash was not observed within $DbPollSeconds seconds"
}

function Assert-ChatLogProfile {
  param(
    [Parameter(Mandatory = $true)][string]$RequestHash,
    [Parameter(Mandatory = $true)][string]$ExpectedProfileId,
    [Parameter(Mandatory = $true)][string]$ExpectedModel,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $rows = @(Wait-RequestLogRowsByHash $RequestHash)
  $row = $rows[0]
  if ([string]$row.api_key_profile_id -ne $ExpectedProfileId) {
    throw "$Name request_logs.api_key_profile_id expected '$ExpectedProfileId', got '$($row.api_key_profile_id)'"
  }
  if ($row.requested_model -ne $ExpectedModel) {
    throw "$Name request_logs.requested_model expected '$ExpectedModel', got '$($row.requested_model)'"
  }
  if ($row.request_status -ne "succeeded") {
    throw "$Name request_logs.status expected 'succeeded', got '$($row.request_status)'"
  }
  if ([int]$row.request_http_status -ne 200) {
    throw "$Name request_logs.http_status expected 200, got '$($row.request_http_status)'"
  }
  if (-not $row.resolved_provider_id) {
    throw "$Name request_logs.resolved_provider_id was not populated"
  }
  if (-not $row.resolved_channel_id) {
    throw "$Name request_logs.resolved_channel_id was not populated"
  }
  if (-not $row.upstream_model) {
    throw "$Name request_logs.upstream_model was not populated"
  }
}

function Invoke-ChatCompletionProbe {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][hashtable]$Headers,
    [Parameter(Mandatory = $true)][string]$Model,
    [Parameter(Mandatory = $true)][string]$Content
  )

  $body = New-ChatBodyJson -RequestModel $Model -Content $Content
  $hash = Get-Sha256Hex $body
  $response = Invoke-ProfileRequest `
    -Method POST `
    -Uri (Join-Url $GatewayBaseUrl "/v1/chat/completions") `
    -Headers $Headers `
    -JsonBody $body

  Assert-Status $response 200
  $payload = Read-Json $response.Content
  if ($payload.object -ne "chat.completion") {
    throw "$Name expected object=chat.completion, got '$($payload.object)'"
  }

  return [PSCustomObject]@{
    RequestHash = $hash
    Response = $response
  }
}

$fixture = $null
$offlineMode = $DryRun -or $SkipNetwork
$suffix = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

Push-Location $repoRoot
try {
  Check "profile switching fixture files exist" {
    foreach ($relativePath in @(
        "scripts\verify_gateway_profile_smoke.ps1",
        "scripts\common.ps1",
        "tests\fixtures\gateway\profile_switching.json",
        "tests\fixtures\gateway\v1_models_profile_visibility_contract.json"
      )) {
      $path = Join-Path $repoRoot $relativePath
      if (-not (Test-Path $path)) {
        throw "missing $relativePath"
      }
    }
  }

  Check "profile switching fixture endpoint intent" {
    $script:fixture = Read-Fixture
    Assert-FixtureEndpointIntent $script:fixture
    Assert-FixtureVisibilityContract $script:fixture
    Assert-V1ModelsFixtureContract (Read-V1ModelsFixture)
    Assert-DryRunHeaderConstruction $script:fixture
  }

  if ([string]::IsNullOrWhiteSpace($InvalidProfile) -and $script:fixture) {
    $InvalidProfile = [string]$script:fixture.profiles.invalid.profile_ref
  }
  if ([string]::IsNullOrWhiteSpace($InvalidProfile)) {
    $InvalidProfile = "profile-smoke-unbound-$suffix"
  }

  if ($offlineMode) {
    Write-SafeHost ""
    Write-SafeHost "Gateway profile smoke dry-run passed; runtime requests were not sent."
  } else {
    if (-not $SkipComposePs) {
      Check "docker compose profile smoke services are running" {
        $running = @(Invoke-Docker compose -f $ComposeFile ps --services --status running)
        if ($LASTEXITCODE -ne 0) { throw "docker compose ps failed with exit code $LASTEXITCODE" }

        foreach ($service in @("postgres", "gateway", "mock-provider")) {
          if ($running -notcontains $service) {
            throw "service '$service' is not running"
          }
        }
      }
    }

    if (-not $SkipDbLog) {
      Check "virtual key has multi-profile bindings" {
        $profiles = @(Get-BoundProfilesForToken)
        Set-DiscoveredSwitchProfile -Profiles $profiles
        Assert-BoundProfilePreconditions -Profiles $profiles
      }

      Check "default profile runtime route state reset" {
        Reset-DefaultProfileRuntimeState
      }
    }

    if ([string]::IsNullOrWhiteSpace($SwitchProfile) -and $script:fixture) {
      $SwitchProfile = [string]$script:fixture.profiles.switch.example_profile_ref
    }
    if ([string]::IsNullOrWhiteSpace($SwitchProfile)) {
      Add-Failure "[FAIL] switch profile configuration - set -SwitchProfile or PROFILE_SMOKE_SWITCH_PROFILE for live profile switching checks"
    } else {
      $defaultModels = $null
      $switchModels = $null

      Check "default profile models list" {
        $response = Invoke-ProfileRequest `
          -Method GET `
          -Uri (Join-Url $GatewayBaseUrl "/v1/models") `
          -Headers (New-GatewayHeaders)
        $defaultModels = Assert-ModelsResponse -Response $response -Name "default profile"
        if (-not (Test-ModelListContains -ModelIds $defaultModels.ModelIds -ExpectedModel $DefaultModel)) {
          throw "default profile model list does not include '$DefaultModel'"
        }
        $script:DefaultModels = $defaultModels
      }

      Check "x-ai-profile switched models list" {
        $response = Invoke-ProfileRequest `
          -Method GET `
          -Uri (Join-Url $GatewayBaseUrl "/v1/models") `
          -Headers (New-GatewayHeaders -ProfileRef $SwitchProfile)
        $switchModels = Assert-ModelsResponse -Response $response -Name "switched profile"
        if ((ConvertTo-ModelSetKey $script:DefaultModels.ModelIds) -eq (ConvertTo-ModelSetKey $switchModels.ModelIds)) {
          throw "switched profile model set is identical to the default profile model set"
        }
        if (-not [string]::IsNullOrWhiteSpace($SwitchModel) -and -not (Test-ModelListContains -ModelIds $switchModels.ModelIds -ExpectedModel $SwitchModel)) {
          throw "switched profile model list does not include '$SwitchModel'"
        }
        $script:SwitchModels = $switchModels
      }

      Check "select switched chat model" {
        if ([string]::IsNullOrWhiteSpace($script:SelectedSwitchModel)) {
          $uniqueSwitchModels = @($script:SwitchModels.ModelIds | Where-Object { @($script:DefaultModels.ModelIds) -notcontains $_ })
          if ($uniqueSwitchModels.Count -gt 0) {
            $script:SelectedSwitchModel = [string]$uniqueSwitchModels[0]
          } elseif ($script:SwitchModels.ModelIds.Count -gt 0) {
            $script:SelectedSwitchModel = [string]$script:SwitchModels.ModelIds[0]
          }
        }

        if ([string]::IsNullOrWhiteSpace($script:SelectedSwitchModel) -and $script:fixture) {
          $fixtureModels = @($script:fixture.profiles.switch.example_expected_visible_models)
          if ($fixtureModels.Count -gt 0) {
            $script:SelectedSwitchModel = [string]$fixtureModels[0]
          }
        }

        if ([string]::IsNullOrWhiteSpace($script:SelectedSwitchModel)) {
          throw "could not determine a switched profile chat model; set -SwitchModel or PROFILE_SMOKE_SWITCH_MODEL"
        }
        if (-not (Test-ModelListContains -ModelIds $script:SwitchModels.ModelIds -ExpectedModel $script:SelectedSwitchModel)) {
          throw "selected switched profile chat model '$script:SelectedSwitchModel' is not visible in switched /v1/models"
        }
        $script:SwitchModelVisibleInDefault = Test-ModelListContains -ModelIds $script:DefaultModels.ModelIds -ExpectedModel $script:SelectedSwitchModel
        if ($SkipDbLog -and $script:SwitchModelVisibleInDefault) {
          throw "selected switched profile chat model '$script:SelectedSwitchModel' is also visible in the default profile; disable -SkipDbLog or choose a switch-only model"
        }
      }

      if ($script:SwitchModelVisibleInDefault) {
        Write-SafeHost "[SKIP] default profile rejects switch-only chat model - selected switched model is also visible in the default profile"
      } else {
        Check "default profile rejects switch-only chat model" {
          $body = New-ChatBodyJson -RequestModel $script:SelectedSwitchModel -Content "gateway profile smoke default rejects switched model $suffix"
          $response = Invoke-ProfileRequest `
            -Method POST `
            -Uri (Join-Url $GatewayBaseUrl "/v1/chat/completions") `
            -Headers (New-GatewayHeaders) `
            -JsonBody $body
          if ($response.StatusCode -eq 200) {
            throw "default profile accepted switch-only model '$script:SelectedSwitchModel'"
          }
          Assert-Contains $response.Content "error"
        }
      }

      $defaultChat = $null
      $switchChat = $null

      Check "default profile chat completion" {
        $defaultChat = Invoke-ChatCompletionProbe `
          -Name "default profile chat" `
          -Headers (New-GatewayHeaders) `
          -Model $DefaultModel `
          -Content "gateway profile smoke default route $suffix"
        $script:DefaultChat = $defaultChat
      }

      Check "x-ai-profile switched chat completion" {
        $switchChat = Invoke-ChatCompletionProbe `
          -Name "switched profile chat" `
          -Headers (New-GatewayHeaders -ProfileRef $SwitchProfile) `
          -Model $script:SelectedSwitchModel `
          -Content "gateway profile smoke switched route $suffix"
        $script:SwitchChat = $switchChat
      }

      if ($SkipDbLog) {
        Report-Pending -Name "chat route profile log verification" -Message "skipped request_logs checks; HTTP checks passed but route/profile persistence was not verified"
      } else {
        Check "default profile chat route used default profile" {
          Assert-ChatLogProfile `
            -RequestHash $script:DefaultChat.RequestHash `
            -ExpectedProfileId $script:DefaultModels.ProfileId `
            -ExpectedModel $DefaultModel `
            -Name "default profile chat"
        }

        Check "x-ai-profile switched chat route used switched profile" {
          Assert-ChatLogProfile `
            -RequestHash $script:SwitchChat.RequestHash `
            -ExpectedProfileId $script:SwitchModels.ProfileId `
            -ExpectedModel $script:SelectedSwitchModel `
            -Name "switched profile chat"
        }

        Check "default and switched profile ids differ" {
          if ($script:DefaultModels.ProfileId -eq $script:SwitchModels.ProfileId) {
            throw "default and switched /v1/models returned the same gateway.profile_id"
          }
        }
      }

      Check "invalid x-ai-profile rejected on models" {
        $response = Invoke-ProfileRequest `
          -Method GET `
          -Uri (Join-Url $GatewayBaseUrl "/v1/models") `
          -Headers (New-GatewayHeaders -ProfileRef $InvalidProfile)
        Assert-ErrorResponse -Response $response -ExpectedStatus 403 -ExpectedCode "api_key_profile_forbidden"
      }

      Check "invalid x-ai-profile rejected on chat" {
        $body = New-ChatBodyJson -RequestModel $DefaultModel -Content "gateway profile smoke invalid profile $suffix"
        $response = Invoke-ProfileRequest `
          -Method POST `
          -Uri (Join-Url $GatewayBaseUrl "/v1/chat/completions") `
          -Headers (New-GatewayHeaders -ProfileRef $InvalidProfile) `
          -JsonBody $body
        Assert-ErrorResponse -Response $response -ExpectedStatus 403 -ExpectedCode "api_key_profile_forbidden"
      }
    }
  }
} finally {
  Pop-Location
}

if ($script:Failures.Count -gt 0) {
  Write-SafeHost ""
  Write-SafeHost "Gateway profile smoke failed:"
  foreach ($failure in $script:Failures) {
    Write-SafeHost $failure
  }
  exit 1
}

Write-SafeHost ""
if ($script:Pending.Count -gt 0) {
  Write-SafeHost "Gateway profile smoke passed with pending checks:"
  foreach ($pending in $script:Pending) {
    Write-SafeHost $pending
  }
  exit 0
}

Write-SafeHost "Gateway profile smoke passed."
