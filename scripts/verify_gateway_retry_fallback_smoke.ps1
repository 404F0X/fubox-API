param(
  [string]$GatewayBaseUrl = "http://127.0.0.1:8080",
  [string]$MockProviderBaseUrl = "http://127.0.0.1:18080",
  [string]$GatewayAuthToken = "dev_test_key_123456789",
  [string]$GatewayProfileRef = "",
  [string]$Model = "mock-gpt-4o-mini",
  [ValidateSet("query", "header", "endpoint", "body")]
  [string]$MockProviderSelectorMode = "header",
  [string]$ComposeFile = "deploy/docker-compose/docker-compose.yml",
  [int]$TimeoutSeconds = 8,
  [int]$FailureTimeoutSeconds = 3,
  [int]$DbPollSeconds = 10,
  [switch]$DryRun,
  [switch]$SkipMockProvider,
  [switch]$SkipGateway,
  [switch]$SkipDbLogChecks,
  [switch]$StrictGatewayFallback,
  [switch]$PreflightOnly
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$fixturePath = Join-Path $repoRoot "tests\fixtures\gateway\retry_fallback_smoke.json"
$fixture = Get-Content -Raw $fixturePath | ConvertFrom-Json
$script:Failures = @()
$script:Pending = @()
$script:SmokeSuffix = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$mockProviderSelectorModeExplicit = $PSBoundParameters.ContainsKey("MockProviderSelectorMode") -or -not [string]::IsNullOrWhiteSpace($env:MOCK_PROVIDER_SELECTOR_MODE)

if ($env:GATEWAY_BASE_URL) { $GatewayBaseUrl = $env:GATEWAY_BASE_URL }
if ($env:MOCK_PROVIDER_BASE_URL) { $MockProviderBaseUrl = $env:MOCK_PROVIDER_BASE_URL }
if ($env:GATEWAY_AUTH_TOKEN) { $GatewayAuthToken = $env:GATEWAY_AUTH_TOKEN }
if ($env:GATEWAY_PROFILE_REF) { $GatewayProfileRef = $env:GATEWAY_PROFILE_REF }
if ($env:GATEWAY_AI_PROFILE) { $GatewayProfileRef = $env:GATEWAY_AI_PROFILE }
if ($env:SMOKE_MODEL) { $Model = $env:SMOKE_MODEL }
if ($env:MOCK_PROVIDER_SELECTOR_MODE) { $MockProviderSelectorMode = $env:MOCK_PROVIDER_SELECTOR_MODE }
if ($env:COMPOSE_FILE) { $ComposeFile = $env:COMPOSE_FILE }
if ($env:STRICT_GATEWAY_FALLBACK -eq "1") { $StrictGatewayFallback = $true }
if ($StrictGatewayFallback -and -not $mockProviderSelectorModeExplicit) {
  $MockProviderSelectorMode = "endpoint"
}
if ($StrictGatewayFallback -and [string]::IsNullOrWhiteSpace($GatewayProfileRef)) {
  $GatewayProfileRef = [string]$fixture.gateway_fallback_contract.strict_live_profile_ref
}

Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Security

function Join-Url {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$Path
  )

  return $BaseUrl.TrimEnd("/") + $Path
}

function New-ChatBody {
  param(
    [Parameter(Mandatory = $true)][string]$RequestModel,
    [Parameter(Mandatory = $true)][string]$Content
  )

  return [ordered]@{
    model = $RequestModel
    messages = @(@{ role = "user"; content = $Content })
    stream = $false
  }
}

function ConvertTo-RequestJson {
  param([Parameter(Mandatory = $true)]$Body)

  return ($Body | ConvertTo-Json -Depth 16 -Compress)
}

function ConvertFrom-JsonArray {
  param([Parameter(Mandatory = $true)][string]$Json)

  $parsed = ConvertFrom-Json -InputObject $Json
  if ($null -eq $parsed) {
    return @()
  }

  if ($parsed -is [System.Array]) {
    return $parsed
  }

  return @($parsed)
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

function Invoke-SmokeRequest {
  param(
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Uri,
    [object]$Body = $null,
    [hashtable]$Headers = @{},
    [int]$TimeoutSec = $TimeoutSeconds
  )

  $client = New-Object System.Net.Http.HttpClient
  $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
  $request = New-Object System.Net.Http.HttpRequestMessage -ArgumentList (New-Object System.Net.Http.HttpMethod -ArgumentList $Method), $Uri

  foreach ($key in $Headers.Keys) {
    [void]$request.Headers.TryAddWithoutValidation($key, [string]$Headers[$key])
  }

  if ($null -ne $Body) {
    $json = ConvertTo-RequestJson $Body
    $content = New-Object System.Net.Http.StringContent -ArgumentList $json
    $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/json")
    $request.Content = $content
  }

  $response = $null
  try {
    $response = $client.SendAsync($request).GetAwaiter().GetResult()
    $headersOut = @{}

    foreach ($header in $response.Headers.GetEnumerator()) {
      $headersOut[$header.Key] = ($header.Value -join ",")
    }

    foreach ($header in $response.Content.Headers.GetEnumerator()) {
      $headersOut[$header.Key] = ($header.Value -join ",")
    }

    return [PSCustomObject]@{
      StatusCode = [int]$response.StatusCode
      Content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
      Headers = $headersOut
    }
  } finally {
    if ($response) { $response.Dispose() }
    $request.Dispose()
    $client.Dispose()
  }
}

function New-MockProviderScenarioRequest {
  param(
    [Parameter(Mandatory = $true)][string]$Scenario,
    [Parameter(Mandatory = $true)][string]$SelectorMode,
    [Parameter(Mandatory = $true)][string]$Content
  )

  $escapedScenario = [Uri]::EscapeDataString($Scenario)
  $headers = @{}
  $path = "/v1/chat/completions"
  $body = New-ChatBody -RequestModel $Model -Content $Content

  switch ($SelectorMode.ToLowerInvariant()) {
    "query" {
      $path = "/v1/chat/completions?scenario=$escapedScenario"
    }
    "header" {
      $headers["X-Mock-Scenario"] = $Scenario
    }
    "endpoint" {
      $path = "/__scenario/$escapedScenario/v1/chat/completions"
    }
    "body" {
      $body["mock_scenario"] = $Scenario
    }
  }

  return [PSCustomObject]@{
    Uri = Join-Url $MockProviderBaseUrl $path
    Headers = $headers
    Body = $body
    SelectorMode = $SelectorMode
  }
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

function Assert-ScenarioHeaders {
  param(
    [Parameter(Mandatory = $true)]$Response,
    [Parameter(Mandatory = $true)][string]$Scenario,
    [Parameter(Mandatory = $true)][string]$SelectorMode
  )

  if ($Response.Headers["X-Mock-Scenario"] -ne $Scenario) {
    throw "expected X-Mock-Scenario=$Scenario, got '$($Response.Headers["X-Mock-Scenario"])'"
  }

  if ($Response.Headers["X-Mock-Scenario-Source"] -ne $SelectorMode) {
    throw "expected X-Mock-Scenario-Source=$SelectorMode, got '$($Response.Headers["X-Mock-Scenario-Source"])'"
  }
}

function Assert-ExpectedTransportFailure {
  param(
    [Parameter(Mandatory = $true)][string]$ExpectedStatus,
    [Parameter(Mandatory = $true)][scriptblock]$Action
  )

  try {
    $response = & $Action
    throw "expected $ExpectedStatus, got HTTP $($response.StatusCode): $($response.Content)"
  } catch {
    $errorText = $_.Exception.ToString()
    if ($_.Exception.Message.StartsWith("expected $ExpectedStatus")) {
      throw
    }

    if ($ExpectedStatus -eq "timeout" -and $errorText -notmatch "timed out|canceled|cancelled|TaskCanceled") {
      throw "expected timeout-like failure, got: $($_.Exception.Message)"
    }

    if ($ExpectedStatus -eq "connection_closed") {
      if ($errorText -match "refused|actively refused|No such host|could not be resolved|Name or service") {
        throw "expected connection-closed failure, got: $($_.Exception.Message)"
      }
      if ($errorText -notmatch "closed|reset|EOF|unexpected|premature|response ended|while sending|error while sending|HttpRequestException") {
        throw "expected connection-closed failure, got: $($_.Exception.Message)"
      }
    }
  }
}

function Escape-SqlLiteral {
  param([Parameter(Mandatory = $true)][string]$Value)

  return $Value.Replace("'", "''")
}

function Assert-TextContains {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [Parameter(Mandatory = $true)][string]$Needle,
    [Parameter(Mandatory = $true)][string]$Context
  )

  if (-not $Text.Contains($Needle)) {
    throw "$Context does not contain '$Needle'"
  }
}

function Get-ExpectedFailingEndpoint {
  param([Parameter(Mandatory = $true)]$Case)

  $template = [string]$fixture.gateway_fallback_contract.failing_candidate_endpoint_template
  if ([string]::IsNullOrWhiteSpace($template) -or -not $template.Contains("{scenario}")) {
    throw "gateway_fallback_contract.failing_candidate_endpoint_template must contain {scenario}"
  }

  return $template.Replace("{scenario}", [string]$Case.scenario)
}

function Get-StrictLiveModel {
  param([Parameter(Mandatory = $true)]$Case)

  $model = [string]$Case.strict_live_model
  if ([string]::IsNullOrWhiteSpace($model)) {
    throw "$($Case.name) must define strict_live_model for StrictGatewayFallback"
  }

  return $model
}

function Get-GatewayProbeModel {
  param([Parameter(Mandatory = $true)]$Case)

  if ($StrictGatewayFallback) {
    return Get-StrictLiveModel -Case $Case
  }

  return $Model
}

function New-GatewayHeaders {
  $headers = @{ Authorization = "Bearer $GatewayAuthToken" }
  if (-not [string]::IsNullOrWhiteSpace($GatewayProfileRef)) {
    $headers["x-ai-profile"] = $GatewayProfileRef.Trim()
  }

  return $headers
}

function Get-GatewayProbeTimeoutSeconds {
  param([Parameter(Mandatory = $true)]$Case)

  if ($StrictGatewayFallback -and [string]$Case.scenario -eq "timeout") {
    $caseTimeout = 0
    if ($null -ne $Case.strict_live_probe_timeout_seconds) {
      $caseTimeout = [int]$Case.strict_live_probe_timeout_seconds
    }
    if ($caseTimeout -gt 0) {
      return $caseTimeout
    }
  }

  return $TimeoutSeconds
}

function Get-VirtualKeyPrefix {
  param([Parameter(Mandatory = $true)][string]$RawKey)

  $trimmed = $RawKey.Trim()
  if ($trimmed.Length -lt 12) {
    throw "GatewayAuthToken must be at least 12 characters"
  }

  return $trimmed.Substring(0, 12)
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

function Assert-StrictFallbackSeedContract {
  $contract = $fixture.gateway_fallback_contract
  if (-not $contract) {
    throw "fixture must define gateway_fallback_contract"
  }

  foreach ($field in @("strict_live_profile_ref", "strict_live_channel_tag", "strict_live_seed")) {
    if ([string]::IsNullOrWhiteSpace([string]$contract.$field)) {
      throw "gateway_fallback_contract.$field must be set"
    }
  }

  $seedRelativePath = ([string]$contract.strict_live_seed).Replace("/", [IO.Path]::DirectorySeparatorChar)
  $seedPath = Join-Path $repoRoot $seedRelativePath
  if (-not (Test-Path $seedPath)) {
    throw "strict live seed file not found: $($contract.strict_live_seed)"
  }

  $seedText = Get-Content -Raw $seedPath
  Assert-TextContains $seedText ([string]$contract.strict_live_profile_ref) $contract.strict_live_seed
  Assert-TextContains $seedText ([string]$contract.strict_live_channel_tag) $contract.strict_live_seed
  Assert-TextContains $seedText ([string]$contract.success_candidate_endpoint) $contract.strict_live_seed

  foreach ($case in @($fixture.failure_scenarios)) {
    $model = Get-StrictLiveModel -Case $case
    $failingEndpoint = Get-ExpectedFailingEndpoint -Case $case
    Assert-TextContains $seedText $model $contract.strict_live_seed
    Assert-TextContains $seedText $failingEndpoint $contract.strict_live_seed
  }
}

function Assert-StrictGatewayFallbackLiveConfig {
  if ([string]::IsNullOrWhiteSpace($GatewayProfileRef)) {
    throw "StrictGatewayFallback requires GatewayProfileRef or fixture gateway_fallback_contract.strict_live_profile_ref"
  }

  $profileRefSql = "null"
  if (-not [string]::IsNullOrWhiteSpace($GatewayProfileRef)) {
    $profileRefSql = "'" + (Escape-SqlLiteral $GatewayProfileRef.Trim()) + "'"
  }

  $keyPrefix = Escape-SqlLiteral (Get-VirtualKeyPrefix $GatewayAuthToken)
  $keyHash = Escape-SqlLiteral (Get-Sha256Hex ($GatewayAuthToken.Trim()))
  $successEndpoint = [string]$fixture.gateway_fallback_contract.success_candidate_endpoint

  $values = @()
  foreach ($case in @($fixture.failure_scenarios)) {
    $scenario = Escape-SqlLiteral ([string]$case.scenario)
    $model = Escape-SqlLiteral (Get-StrictLiveModel -Case $case)
    $failingEndpoint = Escape-SqlLiteral (Get-ExpectedFailingEndpoint -Case $case)
    $values += "('$scenario', '$model', '$failingEndpoint')"
  }
  $expectedValuesSql = $values -join ",`n    "

  $sql = @"
with expected(scenario, model_key, failing_endpoint) as (
  values
    $expectedValuesSql
),
key_input as (
  select
    '$keyPrefix'::text as key_prefix,
    '$keyHash'::text as secret_hash,
    $profileRefSql::text as profile_ref
),
auth_key as (
  select
    vk.id as virtual_key_id,
    vk.tenant_id,
    vk.project_id,
    vkb.profile_id
  from virtual_keys vk
  join key_input ki
    on vk.key_prefix = ki.key_prefix
   and vk.secret_hash = ki.secret_hash
  left join lateral (
    select b.profile_id
    from virtual_key_profile_bindings b
    join api_key_profiles selected_profile
      on selected_profile.tenant_id = b.tenant_id
     and selected_profile.project_id = b.project_id
     and selected_profile.id = b.profile_id
    where b.tenant_id = vk.tenant_id
      and b.project_id = vk.project_id
      and b.virtual_key_id = vk.id
      and (
        (ki.profile_ref is null and b.is_default = true)
        or (
          ki.profile_ref is not null
          and (
            selected_profile.id::text = lower(ki.profile_ref)
            or selected_profile.name = ki.profile_ref
          )
        )
      )
    order by
      case
        when ki.profile_ref is not null and selected_profile.id::text = lower(ki.profile_ref) then 0
        when ki.profile_ref is not null and selected_profile.name = ki.profile_ref then 1
        else 2
      end
    limit 1
  ) vkb on true
  where vk.status = 'active'
    and vk.deleted_at is null
    and (vk.expires_at is null or vk.expires_at > now())
  limit 1
),
auth_profile as (
  select
    ak.tenant_id,
    ak.project_id,
    ak.virtual_key_id,
    p.id as profile_id,
    p.name as profile_name,
    p.allowed_models,
    p.denied_models,
    p.allowed_channel_tags,
    p.blocked_provider_ids
  from auth_key ak
  join api_key_profiles p
    on p.tenant_id = ak.tenant_id
   and p.project_id = ak.project_id
   and p.id = ak.profile_id
   and p.status = 'active'
   and p.deleted_at is null
),
candidate_rows as (
  select
    e.scenario,
    e.model_key,
    e.failing_endpoint,
    ap.profile_name,
    cm.id::text as canonical_model_id,
    cm.visibility as canonical_model_visibility,
    ma.id::text as association_id,
    ma.priority as association_priority,
    ma.fallback_allowed,
    ch.id::text as channel_id,
    ch.name as channel_name,
    ch.endpoint,
    ch.timeout_policy,
    ch.priority as channel_priority,
    ch.weight,
    ch.tags,
    pk.id::text as provider_key_id,
    row_number() over (
      partition by e.scenario
      order by ma.priority asc, ch.priority asc, ch.weight desc, ma.id asc, ch.id asc
    ) as route_order
  from expected e
  join auth_profile ap on true
  join canonical_models cm
    on cm.tenant_id = ap.tenant_id
   and cm.model_key = e.model_key
   and cm.status = 'active'
   and cm.deleted_at is null
   and cm.visibility in ('public', 'internal')
   and (
     coalesce(jsonb_array_length(ap.allowed_models), 0) = 0
     or ap.allowed_models ? cm.model_key
   )
   and not (coalesce(ap.denied_models, '[]'::jsonb) ? cm.model_key)
  join model_associations ma
    on ma.tenant_id = cm.tenant_id
   and ma.canonical_model_id = cm.id
   and ma.status = 'enabled'
   and ma.deleted_at is null
  join channels ch
    on ch.tenant_id = ma.tenant_id
   and ch.deleted_at is null
   and ch.status <> 'deleted'
   and ch.protocol_mode = 'openai_compatible'
   and (
     (ma.association_type = 'explicit_channel' and ch.id = ma.channel_id)
     or (ma.association_type = 'channel_tag' and ma.channel_tag is not null and ch.tags ? ma.channel_tag)
     or ma.association_type = 'global'
     or (ma.association_type = 'model_pattern' and ma.model_pattern is not null and e.model_key ~ ma.model_pattern)
   )
  join providers pr
    on pr.tenant_id = ch.tenant_id
   and pr.id = ch.provider_id
   and pr.status = 'enabled'
   and pr.deleted_at is null
  join lateral (
    select pk.id
    from provider_keys pk
    where pk.tenant_id = ch.tenant_id
      and pk.channel_id = ch.id
      and pk.status in ('enabled', 'degraded', 'recovery_probe')
      and pk.deleted_at is null
      and (pk.cooldown_until is null or pk.cooldown_until <= now())
    order by
      case pk.status
        when 'enabled' then 0
        when 'recovery_probe' then 1
        when 'degraded' then 2
        else 3
      end asc,
      pk.health_score desc,
      pk.id asc
    limit 1
  ) pk on true
  where (
      coalesce(jsonb_array_length(ap.allowed_channel_tags), 0) = 0
      or exists (
        select 1
        from jsonb_array_elements_text(ap.allowed_channel_tags) allowed(tag)
        where ch.tags ? allowed.tag
      )
    )
    and not (coalesce(ap.blocked_provider_ids, '[]'::jsonb) ? ch.provider_id::text)
)
select coalesce(jsonb_agg(to_jsonb(candidate_rows) order by scenario, route_order), '[]'::jsonb)::text
from candidate_rows;
"@

  $json = Invoke-ComposePsql $sql
  $rows = @()
  if (-not [string]::IsNullOrWhiteSpace($json)) {
    $rows = @(ConvertFrom-JsonArray $json)
  }

  foreach ($case in @($fixture.failure_scenarios)) {
    $scenario = [string]$case.scenario
    $model = Get-StrictLiveModel -Case $case
    $failingEndpoint = Get-ExpectedFailingEndpoint -Case $case
    $caseRows = @($rows | Where-Object { $_.scenario -eq $scenario } | Sort-Object route_order)
    if ($caseRows.Count -eq 0) {
      throw "strict live route config found no candidates for model '$model' using profile '$GatewayProfileRef'; apply $($fixture.gateway_fallback_contract.strict_live_seed)"
    }
    if ($caseRows.Count -ne 2) {
      throw "strict live route config for model '$model' expected exactly 2 candidates, got $($caseRows.Count)"
    }
    if ($caseRows[0].endpoint -ne $failingEndpoint) {
      throw "strict live route config for model '$model' first endpoint expected '$failingEndpoint', got '$($caseRows[0].endpoint)'"
    }
    if ($caseRows[1].endpoint -ne $successEndpoint) {
      throw "strict live route config for model '$model' fallback endpoint expected '$successEndpoint', got '$($caseRows[1].endpoint)'"
    }
    foreach ($row in $caseRows) {
      if ($row.fallback_allowed -ne $true) {
        throw "strict live route config for model '$model' has fallback_allowed=false on channel '$($row.channel_name)'"
      }
      if (-not $row.provider_key_id) {
        throw "strict live route config for model '$model' channel '$($row.channel_name)' has no enabled provider key"
      }
      if (@($row.tags) -notcontains ([string]$fixture.gateway_fallback_contract.strict_live_channel_tag)) {
        throw "strict live route config for model '$model' channel '$($row.channel_name)' is missing tag '$($fixture.gateway_fallback_contract.strict_live_channel_tag)'"
      }
    }

    if ($scenario -eq "timeout") {
      $expectedTimeoutMs = 0
      if ($null -ne $case.strict_live_timeout_policy -and $null -ne $case.strict_live_timeout_policy.request_timeout_ms) {
        $expectedTimeoutMs = [int]$case.strict_live_timeout_policy.request_timeout_ms
      }
      if ($expectedTimeoutMs -gt 0) {
        $actualTimeoutMs = 0
        if ($null -ne $caseRows[0].timeout_policy -and $null -ne $caseRows[0].timeout_policy.request_timeout_ms) {
          $actualTimeoutMs = [int]$caseRows[0].timeout_policy.request_timeout_ms
        }
        if ($actualTimeoutMs -le 0 -or $actualTimeoutMs -gt $expectedTimeoutMs) {
          throw "strict live route config for model '$model' timeout request_timeout_ms expected <= $expectedTimeoutMs, got $actualTimeoutMs"
        }
      }
    }
  }
}

function Reset-StrictGatewayFallbackRuntimeState {
  $contract = $fixture.gateway_fallback_contract
  if (-not $contract) {
    throw "fixture must define gateway_fallback_contract"
  }

  $channelTag = Escape-SqlLiteral ([string]$contract.strict_live_channel_tag)
  $successEndpoint = Escape-SqlLiteral ([string]$contract.success_candidate_endpoint)
  $endpointValues = @("('$successEndpoint')")
  foreach ($case in @($fixture.failure_scenarios)) {
    $endpointValues += "('" + (Escape-SqlLiteral (Get-ExpectedFailingEndpoint -Case $case)) + "')"
  }
  $endpointValuesSql = $endpointValues -join ",`n    "

  $sql = @"
with expected(endpoint) as (
  values
    $endpointValuesSql
),
bounded_channels as (
  select ch.id, ch.tenant_id
  from channels ch
  join expected e on e.endpoint = ch.endpoint
  where ch.tags ? '$channelTag'
    and ch.deleted_at is null
),
updated as (
  update provider_keys pk
     set status = 'enabled',
         cooldown_until = null,
         last_error_code = null,
         health_score = 1.0,
         deleted_at = null,
         updated_at = now()
    from bounded_channels ch
   where pk.tenant_id = ch.tenant_id
     and pk.channel_id = ch.id
  returning pk.id::text
)
select coalesce(jsonb_agg(id), '[]'::jsonb)::text from updated;
"@

  $updated = @(ConvertFrom-JsonArray (Invoke-ComposePsql $sql))
  if ($updated.Count -lt 5) {
    throw "strict gateway fallback runtime reset expected at least 5 provider keys, updated $($updated.Count)"
  }
}

function Set-StrictGatewayFallbackTimeoutPolicy {
  $cases = @($fixture.failure_scenarios | Where-Object { [string]$_.scenario -eq "timeout" } | Select-Object -First 1)
  if ($cases.Count -ne 1) {
    throw "strict timeout fallback case not found"
  }
  $case = $cases[0]

  $requestTimeoutMs = 0
  if ($null -ne $case.strict_live_timeout_policy -and $null -ne $case.strict_live_timeout_policy.request_timeout_ms) {
    $requestTimeoutMs = [int]$case.strict_live_timeout_policy.request_timeout_ms
  }
  if ($requestTimeoutMs -le 0) {
    throw "timeout_then_fallback must define strict_live_timeout_policy.request_timeout_ms"
  }

  $failingEndpoint = Escape-SqlLiteral (Get-ExpectedFailingEndpoint -Case $case)
  $channelTag = Escape-SqlLiteral ([string]$fixture.gateway_fallback_contract.strict_live_channel_tag)
  $sql = @"
update channels
set timeout_policy = jsonb_set(
      coalesce(timeout_policy, '{}'::jsonb),
      '{request_timeout_ms}',
      to_jsonb(${requestTimeoutMs}::int),
      true
    ),
    updated_at = now()
where endpoint = '$failingEndpoint'
  and tags ? '$channelTag'
  and deleted_at is null
returning id::text;
"@

  $updated = Invoke-ComposePsql $sql
  if ([string]::IsNullOrWhiteSpace($updated)) {
    throw "strict timeout fallback channel was not updated for endpoint '$failingEndpoint'"
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
    rl.status as request_status,
    rl.http_status as request_http_status,
    rl.upstream_model as request_upstream_model,
    rl.resolved_provider_id::text as request_provider_id,
    rl.resolved_channel_id::text as request_channel_id,
    rl.provider_key_id::text as request_provider_key_id,
    rl.route_decision_snapshot,
    pa.id::text as attempt_id,
    pa.attempt_no,
    pa.status as attempt_status,
    pa.http_status as attempt_http_status,
    pa.error_code as attempt_error_code,
    pa.fallback_reason,
    pa.provider_id::text as attempt_provider_id,
    pa.channel_id::text as attempt_channel_id,
    pa.provider_key_id::text as attempt_provider_key_id,
    pa.upstream_model as attempt_upstream_model,
    pa.metadata
  from request_logs rl
  left join provider_attempts pa
    on pa.tenant_id = rl.tenant_id
   and pa.request_id = rl.id
  where rl.request_body_hash = '$hash'
  order by rl.created_at desc, pa.attempt_no asc
  limit 10
) t;
"@

  $json = Invoke-ComposePsql $sql
  if ([string]::IsNullOrWhiteSpace($json)) {
    return @()
  }

  return ConvertFrom-JsonArray $json
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

function Check {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][scriptblock]$Action
  )

  try {
    & $Action
    Write-Host "[OK] $Name"
  } catch {
    $message = "[FAIL] $Name - $($_.Exception.Message)"
    $script:Failures += $message
    Write-Host $message
  }
}

function Report-PendingOrFail {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Message,
    [switch]$Strict
  )

  if ($Strict) {
    $failure = "[FAIL] $Name - $Message"
    $script:Failures += $failure
    Write-Host $failure
    return
  }

  $pending = "[PENDING] $Name - $Message"
  $script:Pending += $pending
  Write-Host $pending
}

function Assert-RetryFallbackFixtureContract {
  if ($fixture.scenario -ne "gateway_retry_fallback_smoke") {
    throw "fixture scenario must be gateway_retry_fallback_smoke"
  }

  foreach ($required in @("429", "5xx", "timeout", "eof")) {
    $match = @($fixture.failure_scenarios | Where-Object { $_.scenario -eq $required })
    if ($match.Count -ne 1) {
      throw "expected exactly one fixture case for scenario '$required'"
    }
  }

  if ($fixture.mock_provider_selector_modes -notcontains $MockProviderSelectorMode) {
    throw "fixture does not list selector mode '$MockProviderSelectorMode'"
  }

  $contract = $fixture.gateway_fallback_contract
  if (-not $contract) {
    throw "fixture must define gateway_fallback_contract"
  }
  if ($contract.probe_mode -ne "route_candidate_endpoint") {
    throw "gateway_fallback_contract.probe_mode must be route_candidate_endpoint"
  }
  if ($contract.request_body_must_not_set_mock_scenario -ne $true) {
    throw "gateway fallback probe must not set mock_scenario in the request body"
  }
  if ($contract.provider_attempts_authoritative -ne $true) {
    throw "gateway_fallback_contract.provider_attempts_authoritative must be true"
  }
  if ([string]::IsNullOrWhiteSpace([string]$contract.failing_candidate_endpoint_template)) {
    throw "gateway_fallback_contract.failing_candidate_endpoint_template must be set"
  }
  if (-not ([string]$contract.failing_candidate_endpoint_template).Contains("{scenario}")) {
    throw "gateway_fallback_contract.failing_candidate_endpoint_template must contain {scenario}"
  }
  if ([string]::IsNullOrWhiteSpace([string]$contract.success_candidate_endpoint)) {
    throw "gateway_fallback_contract.success_candidate_endpoint must be set"
  }
  foreach ($field in @("strict_live_profile_ref", "strict_live_channel_tag", "strict_live_seed")) {
    if ([string]::IsNullOrWhiteSpace([string]$contract.$field)) {
      throw "gateway_fallback_contract.$field must be set"
    }
  }

  foreach ($field in @("resolved_provider_id", "resolved_channel_id", "provider_key_id", "upstream_model")) {
    if (@($contract.request_logs_final_route_fields | Where-Object { $_ -eq $field }).Count -ne 1) {
      throw "request_logs_final_route_fields must include '$field'"
    }
  }

  if ($contract.fallback_metadata.provider_attempts_schema -ne "gateway_retry_fallback_v1") {
    throw "provider_attempts fallback metadata schema must be gateway_retry_fallback_v1"
  }
  if ($contract.fallback_metadata.request_logs_snapshot_schema -ne "gateway_retry_fallback_v1") {
    throw "request_logs fallback snapshot schema must be gateway_retry_fallback_v1"
  }

  $strictModels = @{}
  foreach ($case in @($fixture.failure_scenarios)) {
    $strictModel = Get-StrictLiveModel -Case $case
    if ($strictModels.ContainsKey($strictModel)) {
      throw "$($case.name) strict_live_model '$strictModel' is duplicated"
    }
    $strictModels[$strictModel] = $true
    [void](Get-ExpectedFailingEndpoint -Case $case)

    if ($case.expected_provider_attempts.minimum_count -lt 2) {
      throw "$($case.name) must expect at least two provider_attempts"
    }
    if ($case.expected_provider_attempts.failed_attempt.fallback_reason -ne $case.expected_gateway_error_code) {
      throw "$($case.name) fallback_reason must match expected_gateway_error_code"
    }
    if ($case.expected_provider_attempts.final_attempt.status -ne "succeeded") {
      throw "$($case.name) final provider attempt must be succeeded"
    }
    if ($case.expected_request_log.final_route_fields_update -ne $true) {
      throw "$($case.name) must require request_logs final route field update"
    }
    if ($case.expected_request_log.route_decision_snapshot_fallback_schema -ne "gateway_retry_fallback_v1") {
      throw "$($case.name) must require request_logs fallback snapshot schema"
    }

    if ([string]$case.scenario -eq "timeout") {
      $requestTimeoutMs = 0
      if ($null -ne $case.strict_live_timeout_policy -and $null -ne $case.strict_live_timeout_policy.request_timeout_ms) {
        $requestTimeoutMs = [int]$case.strict_live_timeout_policy.request_timeout_ms
      }
      $probeTimeoutSeconds = 0
      if ($null -ne $case.strict_live_probe_timeout_seconds) {
        $probeTimeoutSeconds = [int]$case.strict_live_probe_timeout_seconds
      }
      if ($requestTimeoutMs -le 0) {
        throw "$($case.name) must define strict_live_timeout_policy.request_timeout_ms"
      }
      if ($probeTimeoutSeconds -le 0) {
        throw "$($case.name) must define strict_live_probe_timeout_seconds"
      }
      if (($requestTimeoutMs / 1000.0) -ge $probeTimeoutSeconds) {
        throw "$($case.name) strict_live_probe_timeout_seconds must be greater than request_timeout_ms"
      }
    }
  }
}

function Assert-GatewayFallbackLogs {
  param(
    [Parameter(Mandatory = $true)]$Case,
    [Parameter(Mandatory = $true)][string]$RequestHash
  )

  $rows = @(Wait-RequestLogRowsByHash $RequestHash)
  $requestRow = $rows[0]
  $attemptRows = @($rows | Where-Object { $_.attempt_id })

  if ($requestRow.request_status -ne "succeeded") {
    throw "request_logs.status expected succeeded, got '$($requestRow.request_status)'"
  }
  if ([int]$requestRow.request_http_status -ne 200) {
    throw "request_logs.http_status expected 200, got '$($requestRow.request_http_status)'"
  }
  foreach ($field in @("request_provider_id", "request_channel_id", "request_provider_key_id", "request_upstream_model")) {
    if (-not $requestRow.$field) {
      throw "request_logs.$field was not populated"
    }
  }
  if ($requestRow.route_decision_snapshot.fallback.schema -ne "gateway_retry_fallback_v1") {
    throw "request_logs.route_decision_snapshot.fallback.schema was not gateway_retry_fallback_v1"
  }
  if ([int]$requestRow.route_decision_snapshot.fallback.fallback_count -lt 1) {
    throw "request_logs.route_decision_snapshot.fallback.fallback_count must be at least 1"
  }

  $minimumAttempts = [int]$Case.expected_provider_attempts.minimum_count
  if ($attemptRows.Count -lt $minimumAttempts) {
    throw "provider_attempts expected at least $minimumAttempts rows, got $($attemptRows.Count)"
  }

  $fallbackRows = @($attemptRows | Where-Object { $_.fallback_reason -eq $Case.expected_gateway_error_code })
  if ($fallbackRows.Count -lt 1) {
    throw "provider_attempts.fallback_reason expected '$($Case.expected_gateway_error_code)'"
  }
  if ($fallbackRows[0].metadata.fallback.schema -ne "gateway_retry_fallback_v1") {
    throw "provider_attempts.metadata.fallback.schema was not gateway_retry_fallback_v1"
  }

  $finalAttempt = @($attemptRows | Where-Object { $_.attempt_status -eq "succeeded" } | Select-Object -Last 1)
  if ($finalAttempt.Count -ne 1) {
    throw "provider_attempts final succeeded attempt was not recorded"
  }
  if ($requestRow.request_provider_id -ne $finalAttempt[0].attempt_provider_id) {
    throw "request_logs.resolved_provider_id does not match final provider_attempts.provider_id"
  }
  if ($requestRow.request_channel_id -ne $finalAttempt[0].attempt_channel_id) {
    throw "request_logs.resolved_channel_id does not match final provider_attempts.channel_id"
  }
  if ($requestRow.request_provider_key_id -ne $finalAttempt[0].attempt_provider_key_id) {
    throw "request_logs.provider_key_id does not match final provider_attempts.provider_key_id"
  }
  if ($requestRow.request_upstream_model -ne $finalAttempt[0].attempt_upstream_model) {
    throw "request_logs.upstream_model does not match final provider_attempts.upstream_model"
  }
}

function Check-MockProviderScenario {
  param([Parameter(Mandatory = $true)]$Case)

  $scenario = [string]$Case.scenario
  $request = New-MockProviderScenarioRequest `
    -Scenario $scenario `
    -SelectorMode $MockProviderSelectorMode `
    -Content "mock provider retry fallback fixture $scenario"

  if ($Case.expected_mock_status -is [int] -or $Case.expected_mock_status -is [long]) {
    $response = Invoke-SmokeRequest -Method POST -Uri $request.Uri -Headers $request.Headers -Body $request.Body
    Assert-Status $response ([int]$Case.expected_mock_status)
    Assert-ScenarioHeaders $response $scenario $MockProviderSelectorMode

    if ($scenario -eq "429") {
      if ($response.Headers["Retry-After"] -ne "1") {
        throw "expected Retry-After=1, got '$($response.Headers["Retry-After"])'"
      }
      Assert-Contains $response.Content "rate_limit_error"
      return
    }

    Assert-Contains $response.Content "error"
    return
  }

  Assert-ExpectedTransportFailure -ExpectedStatus ([string]$Case.expected_mock_status) {
    Invoke-SmokeRequest `
      -Method POST `
      -Uri $request.Uri `
      -Headers $request.Headers `
      -Body $request.Body `
      -TimeoutSec $FailureTimeoutSeconds
  }
}

function Check-GatewayFallbackProbe {
  param([Parameter(Mandatory = $true)]$Case)

  $scenario = [string]$Case.scenario
  $name = "gateway fallback probe $scenario"
  $probeModel = Get-GatewayProbeModel -Case $Case
  $body = New-ChatBody -RequestModel $probeModel -Content "gateway retry fallback probe $scenario $script:SmokeSuffix"
  $requestHash = Get-Sha256Hex (ConvertTo-RequestJson $body)
  $headers = New-GatewayHeaders
  $probeTimeoutSeconds = Get-GatewayProbeTimeoutSeconds -Case $Case

  try {
    $response = Invoke-SmokeRequest `
      -Method POST `
      -Uri (Join-Url $GatewayBaseUrl "/v1/chat/completions") `
      -Headers $headers `
      -Body $body `
      -TimeoutSec $probeTimeoutSeconds

    if ($response.StatusCode -eq [int]$Case.fallback_expected_status) {
      Assert-Contains $response.Content "chat.completion"
      if ($SkipDbLogChecks) {
        Report-PendingOrFail -Name "$name log contract" -Message "HTTP 200 observed, but DB log verification was skipped; provider_attempts fallback evidence was not checked." -Strict:$StrictGatewayFallback
        return
      }

      try {
        Assert-GatewayFallbackLogs -Case $Case -RequestHash $requestHash
        Write-Host "[OK] $name"
      } catch {
        Report-PendingOrFail -Name "$name log contract" -Message $_.Exception.Message -Strict:$StrictGatewayFallback
      }
      return
    }

    $message = "gateway surfaced HTTP $($response.StatusCode) for fallback scenario=$scenario instead of fallback HTTP $($Case.fallback_expected_status): $($response.Content)"
    Report-PendingOrFail -Name $name -Message $message -Strict:$StrictGatewayFallback
  } catch {
    $message = "gateway request did not complete for fallback scenario=${scenario}: $($_.Exception.Message)"
    Report-PendingOrFail -Name $name -Message $message -Strict:$StrictGatewayFallback
  }
}

if ($DryRun) {
  Check "retry/fallback fixture dry-run contract" {
    Assert-RetryFallbackFixtureContract
  }
  Check "retry/fallback strict live seed dry-run contract" {
    Assert-StrictFallbackSeedContract
  }

  if ($script:Failures.Count -gt 0) {
    Write-Host ""
    Write-Host "Gateway retry/fallback smoke dry-run failed:"
    foreach ($failure in $script:Failures) {
      Write-Host $failure
    }
    exit 1
  }

  Write-Host ""
  Write-Host "Gateway retry/fallback smoke dry-run passed; runtime requests were not sent."
  exit 0
}

Push-Location $repoRoot
try {
  Check "retry/fallback fixture contract" {
    Assert-RetryFallbackFixtureContract
  }
  Check "retry/fallback strict live seed contract" {
    Assert-StrictFallbackSeedContract
  }

  if ($PreflightOnly -and -not $StrictGatewayFallback) {
    Check "retry/fallback preflight mode" {
      throw "-PreflightOnly requires -StrictGatewayFallback"
    }
  }

  if ($StrictGatewayFallback) {
    Check "strict gateway fallback runtime options" {
      if ($SkipGateway) {
        throw "StrictGatewayFallback cannot be combined with -SkipGateway because fallback cannot be proven"
      }
      if ($SkipDbLogChecks) {
        throw "StrictGatewayFallback cannot be combined with -SkipDbLogChecks because provider_attempts evidence is required"
      }
      if ([string]::IsNullOrWhiteSpace($GatewayProfileRef)) {
        throw "StrictGatewayFallback requires GatewayProfileRef or fixture strict_live_profile_ref"
      }
    }

    Check "strict gateway fallback live route config" {
      Reset-StrictGatewayFallbackRuntimeState
      Set-StrictGatewayFallbackTimeoutPolicy
      Assert-StrictGatewayFallbackLiveConfig
    }
  }

  if (-not $PreflightOnly -and -not $SkipMockProvider) {
    foreach ($case in @($fixture.failure_scenarios)) {
      Check "mock-provider $MockProviderSelectorMode selector scenario $($case.scenario)" {
        Check-MockProviderScenario -Case $case
      }
    }
  }

  if (-not $PreflightOnly -and -not $SkipGateway) {
    foreach ($case in @($fixture.failure_scenarios)) {
      Check-GatewayFallbackProbe -Case $case
    }
  }
} finally {
  Pop-Location
}

if ($script:Failures.Count -gt 0) {
  Write-Host ""
  Write-Host "Gateway retry/fallback smoke failed:"
  foreach ($failure in $script:Failures) {
    Write-Host $failure
  }
  exit 1
}

Write-Host ""
if ($PreflightOnly) {
  Write-Host "Gateway retry/fallback strict live preflight passed; runtime requests were not sent."
  exit 0
}

if ($script:Pending.Count -gt 0) {
  Write-Host "Retry/fallback fixture checks passed. Gateway fallback checks pending:"
  foreach ($pending in $script:Pending) {
    Write-Host $pending
  }
  exit 0
}

Write-Host "Gateway retry/fallback smoke passed."
