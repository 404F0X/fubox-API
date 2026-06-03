param(
  [string]$GatewayBaseUrl = "http://127.0.0.1:8080",
  [string]$GatewayAuthToken = "dev_test_key_123456789",
  [string]$Model = "mock-gpt-4o-mini",
  [string]$ComposeFile = "deploy/docker-compose/docker-compose.yml",
  [string]$ExpectedRawProviderKey = "",
  [int]$TimeoutSeconds = 8,
  [int]$DbPollSeconds = 10,
  [switch]$SkipComposePs,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$fixturePath = Join-Path $repoRoot "tests\fixtures\gateway\provider_key_runtime_smoke.json"
$script:Failures = @()
$script:Fixture = $null
$script:ProviderKeyRow = $null
$script:ProviderKeySealedPayload = ""
$script:ProviderKeyFingerprint = ""
$script:ProviderKeyRawSecret = ""
$script:GatewayMasterKeyBase64 = ""
$script:ChatLogRows = @()

if ($env:GATEWAY_BASE_URL) { $GatewayBaseUrl = $env:GATEWAY_BASE_URL }
if ($env:GATEWAY_AUTH_TOKEN) { $GatewayAuthToken = $env:GATEWAY_AUTH_TOKEN }
if ($env:SMOKE_MODEL) { $Model = $env:SMOKE_MODEL }
if ($env:COMPOSE_FILE) { $ComposeFile = $env:COMPOSE_FILE }
if ($env:PROVIDER_KEY_RUNTIME_RAW_KEY_FOR_LEAK_CHECK) { $ExpectedRawProviderKey = $env:PROVIDER_KEY_RUNTIME_RAW_KEY_FOR_LEAK_CHECK }

function Test-TruthyEnv {
  param([string]$Value)

  return $Value -eq "1" -or $Value -match "^(true|yes|on)$"
}

if (Test-TruthyEnv $env:PROVIDER_KEY_RUNTIME_SMOKE_DRY_RUN) { $DryRun = $true }
if (Test-TruthyEnv $env:PROVIDER_KEY_RUNTIME_SMOKE_SKIP_COMPOSE_PS) { $SkipComposePs = $true }

Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Security

function Redact-SecretLikeString {
  param([AllowNull()][string]$Text)

  if ($null -eq $Text) {
    return ""
  }

  $redacted = $Text
  foreach ($knownSecret in @(
      $GatewayAuthToken,
      $ExpectedRawProviderKey,
      $script:ProviderKeyRawSecret,
      $script:ProviderKeySealedPayload,
      $script:ProviderKeyFingerprint,
      $script:GatewayMasterKeyBase64
    )) {
    if (-not [string]::IsNullOrEmpty($knownSecret)) {
      $redacted = $redacted.Replace([string]$knownSecret, "[REDACTED]")
    }
  }

  $redacted = $redacted -replace '(?i)(authorization\s*[:=]\s*bearer\s+)[^\s";,}]+', '${1}[REDACTED]'
  $redacted = $redacted -replace '(?i)(Bearer\s+)[A-Za-z0-9._~+/\-]+=*', '${1}[REDACTED]'
  $redacted = $redacted -replace '(?i)("(?:[^"\\]|\\.)*(?:token|password|passwd|secret|api[_-]?key|access[_-]?key|private[_-]?key|provider[_-]?key|fingerprint)(?:[^"\\]|\\.)*"\s*:\s*")(?:(?:\\.)|[^"\\])*(")', '${1}[REDACTED]${2}'
  $redacted = $redacted -replace '(?i)([a-z][a-z0-9+.-]*://)[^/?#@\s:]+:[^/?#@\s]*@', '${1}[REDACTED]:[REDACTED]@'
  $redacted = $redacted -replace '(?i)([a-z][a-z0-9+.-]*://)[^/?#@\s:]+@', '${1}[REDACTED]@'
  $redacted = $redacted -replace '(?i)([?&;][^=&#\s]*(?:api[_-]?key|token|password|passwd|secret)[^=&#\s]*=)[^&#\s"<>]+', '${1}[REDACTED]'
  $redacted = $redacted -replace '(?i)(\b[A-Za-z0-9_-]*(?:token|password|passwd|secret|api[_-]?key|access[_-]?key|private[_-]?key|provider[_-]?key|fingerprint)[A-Za-z0-9_-]*\s*[:=]\s*)[^\s";,}\]]+', '${1}[REDACTED]'
  $redacted = $redacted -replace 'sk-[A-Za-z0-9._~+\-/=]+', '[REDACTED]'
  $redacted = $redacted -replace 'dev_test_key_[A-Za-z0-9._~+\-/=]+', '[REDACTED]'
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

function Exit-WithFailuresIfAny {
  if ($script:Failures.Count -eq 0) {
    return
  }

  Write-SafeHost ""
  Write-SafeHost "Provider key runtime smoke failed:"
  foreach ($failure in $script:Failures) {
    Write-SafeHost $failure
  }
  exit 1
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
    [Parameter(Mandatory = $true)][string]$Content,
    [string]$MockScenario = ""
  )

  $json = '{"model":' + (ConvertTo-JsonString $RequestModel) + ',"messages":[{"role":"user","content":' + (ConvertTo-JsonString $Content) + '}],"stream":false'
  if (-not [string]::IsNullOrWhiteSpace($MockScenario)) {
    $json += ',"mock_scenario":' + (ConvertTo-JsonString $MockScenario)
  }

  return $json + '}'
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

function Read-Json {
  param([Parameter(Mandatory = $true)][string]$Content)

  try {
    return $Content | ConvertFrom-Json
  } catch {
    throw "expected JSON content: $($_.Exception.Message)"
  }
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

function Assert-NotBlank {
  param(
    [AllowNull()][string]$Value,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    throw "$Name was not populated"
  }
}

function Assert-NoSecretLeak {
  param(
    [AllowNull()][string]$Content,
    [Parameter(Mandatory = $true)][string]$Label
  )

  $text = [string]$Content
  $needles = @(
    [PSCustomObject]@{ Name = "sealed provider key payload"; Value = $script:ProviderKeySealedPayload },
    [PSCustomObject]@{ Name = "provider key fingerprint"; Value = $script:ProviderKeyFingerprint },
    [PSCustomObject]@{ Name = "raw provider key"; Value = $script:ProviderKeyRawSecret }
  )

  if (-not [string]::IsNullOrWhiteSpace($script:ProviderKeySealedPayload)) {
    try {
      $sealed = Read-Json $script:ProviderKeySealedPayload
      $needles += [PSCustomObject]@{ Name = "sealed provider key ciphertext"; Value = [string]$sealed.ciphertext }
      $needles += [PSCustomObject]@{ Name = "sealed provider key nonce"; Value = [string]$sealed.nonce }
    } catch {
      $null = $_
    }
  }

  foreach ($needle in $needles) {
    if (-not [string]::IsNullOrEmpty($needle.Value) -and $text.Contains([string]$needle.Value)) {
      throw "$Label leaked $($needle.Name)"
    }
  }
}

function Invoke-GatewayRequest {
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

function Read-Fixture {
  if (-not (Test-Path $fixturePath)) {
    throw "missing tests\fixtures\gateway\provider_key_runtime_smoke.json"
  }

  try {
    return Get-Content -Raw $fixturePath | ConvertFrom-Json
  } catch {
    throw "provider_key_runtime_smoke.json is not valid JSON: $($_.Exception.Message)"
  }
}

function Assert-FixtureContract {
  param([Parameter(Mandatory = $true)]$Fixture)

  $script:ProviderKeyFingerprint = [string]$Fixture.dev_seed.secret_fingerprint

  if ($Fixture.scenario -ne "provider_key_runtime_live_strict_smoke") {
    throw "fixture scenario must be provider_key_runtime_live_strict_smoke"
  }
  if ($Fixture.base_path -ne "/v1/chat/completions") {
    throw "fixture base_path must be /v1/chat/completions"
  }
  if ($Fixture.request.model -ne "mock-gpt-4o-mini" -or $Fixture.request.stream -ne $false) {
    throw "fixture request must declare non-stream mock-gpt-4o-mini"
  }
  if ($Fixture.compose.provider_key_master_key_env -ne "AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_BASE64") {
    throw "fixture compose provider_key_master_key_env must be AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_BASE64"
  }
  if ($Fixture.compose.provider_key_master_key_id_env -ne "AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_ID") {
    throw "fixture compose provider_key_master_key_id_env must be AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_ID"
  }
  foreach ($service in @("postgres", "gateway", "mock-provider")) {
    if (@($Fixture.compose.required_services | Where-Object { $_ -eq $service }).Count -ne 1) {
      throw "fixture compose.required_services must include '$service'"
    }
  }
  if ($Fixture.dev_seed.provider_key_id -ne "00000000-0000-0000-0000-000000000075") {
    throw "fixture dev_seed.provider_key_id must match the dev seed provider key"
  }
  if ($Fixture.dev_seed.encrypted_secret_algorithm -ne "aes-256-gcm") {
    throw "fixture dev_seed.encrypted_secret_algorithm must be aes-256-gcm"
  }
  if ([int]$Fixture.dev_seed.encrypted_secret_version -ne 1) {
    throw "fixture dev_seed.encrypted_secret_version must be 1"
  }
  if ($Fixture.dev_seed.master_key_id -ne "dev-seed-v1") {
    throw "fixture dev_seed.master_key_id must be dev-seed-v1"
  }
  foreach ($check in @("gateway_chat_success", "provider_key_id_persisted", "provider_error_redaction")) {
    if (@($Fixture.live_checks | Where-Object { $_.name -eq $check }).Count -ne 1) {
      throw "fixture live_checks must include '$check'"
    }
  }
}

function Get-ComposeServiceBlock {
  param(
    [Parameter(Mandatory = $true)][string]$Content,
    [Parameter(Mandatory = $true)][string]$Service
  )

  $pattern = "(?ms)^  " + [regex]::Escape($Service) + ":\s*\r?\n(?<block>.*?)(?=^  [A-Za-z0-9_-]+:\s*\r?\n|\z)"
  $match = [regex]::Match($Content, $pattern)
  if (-not $match.Success) {
    throw "compose service '$Service' was not found"
  }

  return $match.Groups["block"].Value
}

function Get-ComposeEnvValueFromBlock {
  param(
    [Parameter(Mandatory = $true)][string]$Block,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $pattern = "(?m)^\s{6}" + [regex]::Escape($Name) + ":\s*(?<value>.+?)\s*$"
  $match = [regex]::Match($Block, $pattern)
  if (-not $match.Success) {
    throw "compose service environment is missing $Name"
  }

  return $match.Groups["value"].Value.Trim().Trim('"').Trim("'")
}

function ConvertFrom-Base64MasterKey {
  param(
    [Parameter(Mandatory = $true)][string]$RawValue,
    [Parameter(Mandatory = $true)][string]$Name
  )

  try {
    $bytes = [Convert]::FromBase64String($RawValue.Trim())
  } catch {
    throw "$Name must be valid base64"
  }

  if ($bytes.Length -ne 32) {
    throw "$Name must decode to 32 bytes; got $($bytes.Length)"
  }

  return $bytes
}

function Assert-ComposeProviderKeyRuntimeContract {
  $path = Join-Path $repoRoot $ComposeFile
  if (-not (Test-Path $path)) {
    throw "missing $ComposeFile"
  }

  $content = Get-Content -Raw $path
  $gatewayBlock = Get-ComposeServiceBlock -Content $content -Service "gateway"
  $controlPlaneBlock = Get-ComposeServiceBlock -Content $content -Service "control-plane"
  $gatewayMasterKey = Get-ComposeEnvValueFromBlock -Block $gatewayBlock -Name "AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_BASE64"
  $controlPlaneMasterKey = Get-ComposeEnvValueFromBlock -Block $controlPlaneBlock -Name "AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_BASE64"
  $controlPlaneMasterKeyId = Get-ComposeEnvValueFromBlock -Block $controlPlaneBlock -Name "AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_ID"

  [void](ConvertFrom-Base64MasterKey -RawValue $gatewayMasterKey -Name "gateway AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_BASE64")
  [void](ConvertFrom-Base64MasterKey -RawValue $controlPlaneMasterKey -Name "control-plane AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_BASE64")
  $script:GatewayMasterKeyBase64 = $gatewayMasterKey

  if ($gatewayMasterKey -ne $controlPlaneMasterKey) {
    throw "gateway and control-plane provider key master keys must match for the dev sealed key contract"
  }

  if ($controlPlaneMasterKeyId -ne $script:Fixture.dev_seed.master_key_id) {
    throw "control-plane AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_ID expected '$($script:Fixture.dev_seed.master_key_id)'"
  }
}

function Assert-SealedPayloadShape {
  param(
    [Parameter(Mandatory = $true)][string]$PayloadJson,
    [Parameter(Mandatory = $true)][string]$Context
  )

  $payload = Read-Json $PayloadJson
  if ($payload.algorithm -ne $script:Fixture.dev_seed.encrypted_secret_algorithm) {
    throw "$Context sealed payload algorithm expected '$($script:Fixture.dev_seed.encrypted_secret_algorithm)'"
  }
  if ([int]$payload.version -ne [int]$script:Fixture.dev_seed.encrypted_secret_version) {
    throw "$Context sealed payload version expected '$($script:Fixture.dev_seed.encrypted_secret_version)'"
  }
  if ($payload.master_key_id -ne $script:Fixture.dev_seed.master_key_id) {
    throw "$Context sealed payload master_key_id expected '$($script:Fixture.dev_seed.master_key_id)'"
  }
  if ([string]$payload.nonce -notmatch '^[0-9a-f]{24}$') {
    throw "$Context sealed payload nonce must be 12 bytes of lowercase hex"
  }
  if ([string]$payload.ciphertext -notmatch '^[0-9a-f]{34,}$') {
    throw "$Context sealed payload ciphertext must be lowercase hex"
  }
}

function Assert-DevSeedSourceContract {
  foreach ($relativePath in @(
      "db\dev-seeds\0002_dev_gateway_seed.sql",
      "db\dev-seeds\0003_dev_smoke_seed_reconcile.sql"
    )) {
    $path = Join-Path $repoRoot $relativePath
    if (-not (Test-Path $path)) {
      throw "missing $relativePath"
    }

    $content = Get-Content -Raw $path
    foreach ($marker in @(
        [PSCustomObject]@{ Name = "provider_key_id"; Value = [string]$script:Fixture.dev_seed.provider_key_id },
        [PSCustomObject]@{ Name = "key_alias"; Value = [string]$script:Fixture.dev_seed.key_alias },
        [PSCustomObject]@{ Name = "master_key_id"; Value = [string]$script:Fixture.dev_seed.master_key_id },
        [PSCustomObject]@{ Name = "secret_fingerprint"; Value = [string]$script:Fixture.dev_seed.secret_fingerprint },
        [PSCustomObject]@{ Name = "metadata.dev_seed"; Value = '"dev_seed": true' },
        [PSCustomObject]@{ Name = "metadata.sealed_placeholder"; Value = '"sealed_placeholder": true' }
      )) {
      if (-not $content.Contains($marker.Value)) {
        throw "$relativePath does not contain expected dev provider key seed marker '$($marker.Name)'"
      }
    }

    if ($content.Contains("dev-only-placeholder-not-a-real-secret")) {
      throw "$relativePath still contains the old plaintext placeholder provider key"
    }

    $payloads = Get-SealedProviderKeyPayloadsFromSql -Content $content
    if ($payloads.Count -eq 0) {
      throw "$relativePath does not contain a sealed aes-256-gcm provider key payload"
    }

    foreach ($payload in $payloads) {
      Assert-SealedPayloadShape -PayloadJson $payload -Context $relativePath
      if ([string]::IsNullOrWhiteSpace($script:ProviderKeySealedPayload)) {
        $script:ProviderKeySealedPayload = $payload
      }
    }
  }
}

function Get-SealedProviderKeyPayloadsFromSql {
  param([Parameter(Mandatory = $true)][string]$Content)

  $payloads = New-Object "System.Collections.Generic.List[string]"
  foreach ($match in [regex]::Matches($Content, "'(?<payload>\{[^']+\})'")) {
    $payload = $match.Groups["payload"].Value
    try {
      $parsed = Read-Json $payload
      if ($parsed.algorithm -eq "aes-256-gcm" -and [int]$parsed.version -eq 1) {
        [void]$payloads.Add($payload)
      }
    } catch {
      $null = $_
    }
  }

  return $payloads
}

function Assert-ScriptStructure {
  $source = Get-Content -LiteralPath $PSCommandPath -Raw
  foreach ($needle in @(
      "open provider key",
      "provider_attempts.provider_key_id",
      "request_logs.provider_key_id",
      "Assert-NoSecretLeak",
      "mock_scenario",
      "AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_BASE64"
    )) {
    if (-not $source.Contains($needle)) {
      throw "script source is missing provider key runtime check marker '$needle'"
    }
  }
}

function Get-ComposeServiceEnvValue {
  param(
    [Parameter(Mandatory = $true)][string]$Service,
    [Parameter(Mandatory = $true)][string]$Name
  )

  Push-Location $repoRoot
  try {
    $output = Invoke-Docker compose -f $ComposeFile exec -T $Service printenv $Name
    if ($LASTEXITCODE -ne 0) {
      throw "compose service '$Service' is missing environment variable $Name"
    }

    $value = (($output | Out-String).Trim())
    if ([string]::IsNullOrWhiteSpace($value)) {
      throw "compose service '$Service' environment variable $Name is blank"
    }

    return $value
  } finally {
    Pop-Location
  }
}

function Assert-ComposeServicesRunning {
  Push-Location $repoRoot
  try {
    $running = @(Invoke-Docker compose -f $ComposeFile ps --services --status running)
    if ($LASTEXITCODE -ne 0) {
      throw "docker compose ps failed with exit code $LASTEXITCODE"
    }

    foreach ($service in @($script:Fixture.compose.required_services)) {
      if ($running -notcontains $service) {
        throw "service '$service' is not running; start the local compose stack or use -DryRun for structure-only validation"
      }
    }
  } finally {
    Pop-Location
  }
}

function Get-ProviderKeySeedRows {
  $tenantId = Escape-SqlLiteral ([string]$script:Fixture.dev_seed.tenant_id)
  $providerKeyId = Escape-SqlLiteral ([string]$script:Fixture.dev_seed.provider_key_id)
  $modelKey = Escape-SqlLiteral $Model

  $sql = @"
select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb)::text
from (
  select
    pk.tenant_id::text as tenant_id,
    pk.id::text as provider_key_id,
    pk.channel_id::text as provider_key_channel_id,
    pk.key_alias,
    pk.encrypted_secret,
    pk.secret_fingerprint,
    pk.status as provider_key_status,
    pk.deleted_at is null as provider_key_active,
    pk.metadata as provider_key_metadata,
    ch.id::text as channel_id,
    ch.provider_id::text as provider_id,
    ch.name as channel_name,
    ch.endpoint as channel_endpoint,
    ch.status as channel_status,
    pr.code as provider_code,
    pr.status as provider_status,
    cm.id::text as canonical_model_id,
    cm.model_key,
    cm.status as model_status,
    ma.id::text as association_id,
    ma.status as association_status,
    ma.upstream_model_name
  from provider_keys pk
  join channels ch
    on ch.tenant_id = pk.tenant_id
   and ch.id = pk.channel_id
   and ch.deleted_at is null
  join providers pr
    on pr.tenant_id = ch.tenant_id
   and pr.id = ch.provider_id
   and pr.deleted_at is null
  join model_associations ma
    on ma.tenant_id = pk.tenant_id
   and ma.channel_id = ch.id
   and ma.deleted_at is null
  join canonical_models cm
    on cm.tenant_id = ma.tenant_id
   and cm.id = ma.canonical_model_id
   and cm.deleted_at is null
  where pk.tenant_id = '$tenantId'
    and pk.id = '$providerKeyId'
    and cm.model_key = '$modelKey'
  order by ma.priority desc
  limit 1
) t;
"@

  $json = Invoke-ComposePsql $sql
  if ([string]::IsNullOrWhiteSpace($json)) {
    return @()
  }

  return @($json | ConvertFrom-Json)
}

function Assert-ProviderKeySeedRow {
  $rows = @(Get-ProviderKeySeedRows)
  if ($rows.Count -eq 0) {
    throw "dev seed is incomplete: provider key '$($script:Fixture.dev_seed.provider_key_id)' is not joined to model '$Model' in compose postgres"
  }

  $row = $rows[0]
  $missing = @()
  if ($row.tenant_id -ne $script:Fixture.dev_seed.tenant_id) { $missing += "tenant_id" }
  if ($row.provider_id -ne $script:Fixture.dev_seed.provider_id) { $missing += "provider_id" }
  if ($row.channel_id -ne $script:Fixture.dev_seed.channel_id) { $missing += "channel_id" }
  if ($row.provider_key_id -ne $script:Fixture.dev_seed.provider_key_id) { $missing += "provider_key_id" }
  if ($row.key_alias -ne $script:Fixture.dev_seed.key_alias) { $missing += "key_alias" }
  if ($row.provider_key_status -ne "enabled") { $missing += "provider_keys.status" }
  if ([bool]$row.provider_key_active -ne $true) { $missing += "provider_keys.deleted_at" }
  if ($row.secret_fingerprint -ne $script:Fixture.dev_seed.secret_fingerprint) { $missing += "provider_keys.secret_fingerprint" }
  if ($row.channel_status -ne "enabled") { $missing += "channels.status" }
  if ($row.provider_status -ne "enabled") { $missing += "providers.status" }
  if ($row.model_status -ne "active") { $missing += "canonical_models.status" }
  if ($row.association_status -ne "enabled") { $missing += "model_associations.status" }
  if ($row.upstream_model_name -ne $Model) { $missing += "model_associations.upstream_model_name" }

  $metadata = $row.provider_key_metadata
  foreach ($flag in @($script:Fixture.dev_seed.metadata_flags)) {
    if ([bool](Get-JsonPropertyValue $metadata $flag $false) -ne $true) {
      $missing += "provider_keys.metadata.$flag"
    }
  }

  Assert-SealedPayloadShape -PayloadJson ([string]$row.encrypted_secret) -Context "compose postgres provider_keys.encrypted_secret"

  if ($missing.Count -gt 0) {
    throw "dev seed is incomplete for provider key runtime: " + ($missing -join ", ")
  }

  $script:ProviderKeyRow = $row
  $script:ProviderKeySealedPayload = [string]$row.encrypted_secret
  $script:ProviderKeyFingerprint = [string]$row.secret_fingerprint
}

function Add-AadField {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[byte]]$Output,
    [Parameter(Mandatory = $true)][string]$Label,
    [Parameter(Mandatory = $true)][byte[]]$Value
  )

  $labelBytes = [System.Text.Encoding]::UTF8.GetBytes($Label)
  $labelLengthBytes = [System.BitConverter]::GetBytes([UInt32]$labelBytes.Length)
  [System.Array]::Reverse($labelLengthBytes)
  foreach ($byte in $labelLengthBytes) { $Output.Add($byte) }
  foreach ($byte in $labelBytes) { $Output.Add($byte) }

  $valueLengthBytes = [System.BitConverter]::GetBytes([UInt32]$Value.Length)
  [System.Array]::Reverse($valueLengthBytes)
  foreach ($byte in $valueLengthBytes) { $Output.Add($byte) }
  foreach ($byte in $Value) { $Output.Add($byte) }
}

function New-ProviderKeyContextAad {
  param([Parameter(Mandatory = $true)]$Row)

  $context = New-Object "System.Collections.Generic.List[byte]"
  Add-AadField -Output $context -Label "domain" -Value ([System.Text.Encoding]::UTF8.GetBytes("ai-gateway:provider-key:context:v1"))
  Add-AadField -Output $context -Label "tenant_id" -Value ([System.Text.Encoding]::UTF8.GetBytes([string]$Row.tenant_id))
  Add-AadField -Output $context -Label "provider_id" -Value ([System.Text.Encoding]::UTF8.GetBytes([string]$Row.provider_id))
  Add-AadField -Output $context -Label "provider_key_id" -Value ([System.Text.Encoding]::UTF8.GetBytes([string]$Row.provider_key_id))
  return $context.ToArray()
}

function New-ProviderKeyEncryptionAad {
  param(
    [Parameter(Mandatory = $true)]$Payload,
    [Parameter(Mandatory = $true)]$Row
  )

  $aad = New-Object "System.Collections.Generic.List[byte]"
  Add-AadField -Output $aad -Label "domain" -Value ([System.Text.Encoding]::UTF8.GetBytes("ai-gateway:provider-key:seal:v1"))
  Add-AadField -Output $aad -Label "algorithm" -Value ([System.Text.Encoding]::UTF8.GetBytes("aes-256-gcm"))
  Add-AadField -Output $aad -Label "version" -Value ([byte[]]@([byte]$Payload.version))
  Add-AadField -Output $aad -Label "master_key_id" -Value ([System.Text.Encoding]::UTF8.GetBytes([string]$Payload.master_key_id))
  Add-AadField -Output $aad -Label "context" -Value (New-ProviderKeyContextAad -Row $Row)
  return $aad.ToArray()
}

function Convert-HexToBytes {
  param([Parameter(Mandatory = $true)][string]$Hex)

  if ($Hex.Length % 2 -ne 0) {
    throw "hex value length must be even"
  }

  $bytes = New-Object "System.Byte[]" ($Hex.Length / 2)
  for ($i = 0; $i -lt $bytes.Length; $i++) {
    $bytes[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16)
  }

  return $bytes
}

function New-AesGcmInstance {
  param([Parameter(Mandatory = $true)][byte[]]$MasterKeyBytes)

  $type = [Type]::GetType("System.Security.Cryptography.AesGcm, System.Security.Cryptography.Algorithms", $false)
  if ($null -eq $type) {
    $type = [Type]::GetType("System.Security.Cryptography.AesGcm, System.Security.Cryptography", $false)
  }
  if ($null -eq $type) {
    return $null
  }

  try {
    return [Activator]::CreateInstance($type, [object[]]@($MasterKeyBytes, 16))
  } catch {
    try {
      return [Activator]::CreateInstance($type, [object[]]@($MasterKeyBytes))
    } catch {
      return $null
    }
  }
}

function Open-ProviderKeyWithDotNet {
  param(
    [Parameter(Mandatory = $true)][byte[]]$MasterKeyBytes,
    [Parameter(Mandatory = $true)]$Payload,
    [Parameter(Mandatory = $true)][byte[]]$Aad
  )

  $aes = New-AesGcmInstance -MasterKeyBytes $MasterKeyBytes
  if ($null -eq $aes) {
    return $null
  }

  $nonce = Convert-HexToBytes ([string]$Payload.nonce)
  $combined = Convert-HexToBytes ([string]$Payload.ciphertext)
  if ($combined.Length -le 16) {
    throw "sealed provider key ciphertext is too short to contain an AES-GCM tag"
  }

  $ciphertextLength = $combined.Length - 16
  $ciphertext = New-Object "System.Byte[]" $ciphertextLength
  $tag = New-Object "System.Byte[]" 16
  [System.Array]::Copy($combined, 0, $ciphertext, 0, $ciphertextLength)
  [System.Array]::Copy($combined, $ciphertextLength, $tag, 0, 16)
  $plaintext = New-Object "System.Byte[]" $ciphertextLength

  try {
    $aes.Decrypt($nonce, $ciphertext, $tag, $plaintext, $Aad)
    return [System.Text.Encoding]::UTF8.GetString($plaintext)
  } finally {
    $aes.Dispose()
  }
}

function Open-ProviderKeyWithNode {
  param(
    [Parameter(Mandatory = $true)][string]$MasterKeyBase64,
    [Parameter(Mandatory = $true)]$Payload,
    [Parameter(Mandatory = $true)][byte[]]$Aad
  )

  $node = Get-Command node -ErrorAction SilentlyContinue
  if (-not $node) {
    throw "cannot derive raw provider key for leak checks: .NET AesGcm is unavailable and node is not installed; run live smoke with PowerShell 7+, install node, or set PROVIDER_KEY_RUNTIME_RAW_KEY_FOR_LEAK_CHECK locally"
  }

  $input = @{
    masterKeyBase64 = $MasterKeyBase64
    nonce = [string]$Payload.nonce
    ciphertext = [string]$Payload.ciphertext
    aadBase64 = [Convert]::ToBase64String($Aad)
  } | ConvertTo-Json -Compress

  $nodeScript = "const crypto=require('crypto');const i=JSON.parse(process.env.PROVIDER_KEY_RUNTIME_NODE_INPUT);const key=Buffer.from(i.masterKeyBase64,'base64');const nonce=Buffer.from(i.nonce,'hex');const combined=Buffer.from(i.ciphertext,'hex');const tag=combined.subarray(combined.length-16);const ciphertext=combined.subarray(0,combined.length-16);const d=crypto.createDecipheriv('aes-256-gcm',key,nonce);d.setAAD(Buffer.from(i.aadBase64,'base64'));d.setAuthTag(tag);process.stdout.write(Buffer.concat([d.update(ciphertext),d.final()]).toString('utf8'));"
  $previous = $env:PROVIDER_KEY_RUNTIME_NODE_INPUT
  $env:PROVIDER_KEY_RUNTIME_NODE_INPUT = $input
  try {
    $output = & node -e $nodeScript
    if ($LASTEXITCODE -ne 0) {
      throw "node AES-GCM provider key open failed with exit code $LASTEXITCODE"
    }

    return (($output | Out-String).Trim())
  } finally {
    if ($null -eq $previous) {
      Remove-Item Env:\PROVIDER_KEY_RUNTIME_NODE_INPUT -ErrorAction SilentlyContinue
    } else {
      $env:PROVIDER_KEY_RUNTIME_NODE_INPUT = $previous
    }
  }
}

function Set-ProviderKeyRawSecretForLeakChecks {
  if (-not [string]::IsNullOrWhiteSpace($ExpectedRawProviderKey)) {
    $script:ProviderKeyRawSecret = $ExpectedRawProviderKey
    return
  }

  $payload = Read-Json $script:ProviderKeySealedPayload
  $masterKeyBytes = ConvertFrom-Base64MasterKey -RawValue $script:GatewayMasterKeyBase64 -Name "gateway AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_BASE64"
  $aad = New-ProviderKeyEncryptionAad -Payload $payload -Row $script:ProviderKeyRow
  $raw = Open-ProviderKeyWithDotNet -MasterKeyBytes $masterKeyBytes -Payload $payload -Aad $aad
  if ([string]::IsNullOrWhiteSpace($raw)) {
    $raw = Open-ProviderKeyWithNode -MasterKeyBase64 $script:GatewayMasterKeyBase64 -Payload $payload -Aad $aad
  }
  if ([string]::IsNullOrWhiteSpace($raw)) {
    throw "raw provider key could not be derived for leak checks"
  }

  $script:ProviderKeyRawSecret = $raw
}

function Assert-DevSeedPayloadOpensWithComposeMasterKey {
  Assert-NotBlank -Value $script:ProviderKeySealedPayload -Name "dev seed sealed provider key payload"
  Assert-NotBlank -Value $script:GatewayMasterKeyBase64 -Name "compose gateway provider key master key"

  $payload = Read-Json $script:ProviderKeySealedPayload
  $masterKeyBytes = ConvertFrom-Base64MasterKey -RawValue $script:GatewayMasterKeyBase64 -Name "gateway AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_BASE64"
  $row = [PSCustomObject]@{
    tenant_id = [string]$script:Fixture.dev_seed.tenant_id
    provider_id = [string]$script:Fixture.dev_seed.provider_id
    provider_key_id = [string]$script:Fixture.dev_seed.provider_key_id
  }
  $aad = New-ProviderKeyEncryptionAad -Payload $payload -Row $row
  $raw = Open-ProviderKeyWithDotNet -MasterKeyBytes $masterKeyBytes -Payload $payload -Aad $aad
  if ([string]::IsNullOrWhiteSpace($raw)) {
    $raw = Open-ProviderKeyWithNode -MasterKeyBase64 $script:GatewayMasterKeyBase64 -Payload $payload -Aad $aad
  }
  if ([string]::IsNullOrWhiteSpace($raw)) {
    throw "dev sealed provider key could not be opened with the compose gateway master key"
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
    rl.requested_model,
    rl.provider_key_id::text as request_provider_key_id,
    rl.resolved_provider_id::text as request_provider_id,
    rl.resolved_channel_id::text as request_channel_id,
    pa.id::text as attempt_id,
    pa.status as attempt_status,
    pa.http_status as attempt_http_status,
    pa.provider_id::text as attempt_provider_id,
    pa.channel_id::text as attempt_channel_id,
    pa.provider_key_id::text as attempt_provider_key_id
  from request_logs rl
  left join provider_attempts pa
    on pa.tenant_id = rl.tenant_id
   and pa.request_id = rl.id
  where rl.request_body_hash = '$hash'
  order by rl.created_at desc, pa.attempt_no asc
  limit 5
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

function Assert-ProviderKeyIdsPersisted {
  param(
    [Parameter(Mandatory = $true)][string]$RequestHash,
    [Parameter(Mandatory = $true)][string]$ExpectedProviderKeyId
  )

  $rows = @(Wait-RequestLogRowsByHash $RequestHash)
  $requestRow = $rows[0]
  Assert-NotBlank -Value ([string]$requestRow.request_provider_key_id) -Name "request_logs.provider_key_id"
  if ([string]$requestRow.request_provider_key_id -ne $ExpectedProviderKeyId) {
    throw "request_logs.provider_key_id expected '$ExpectedProviderKeyId', got '$($requestRow.request_provider_key_id)'"
  }
  if ($requestRow.request_status -ne "succeeded") {
    throw "request_logs.status expected 'succeeded', got '$($requestRow.request_status)'"
  }
  if ([int]$requestRow.request_http_status -ne 200) {
    throw "request_logs.http_status expected 200, got '$($requestRow.request_http_status)'"
  }

  $attemptRows = @($rows | Where-Object { $_.attempt_id })
  if ($attemptRows.Count -eq 0) {
    throw "provider_attempts row was not recorded"
  }

  Assert-NotBlank -Value ([string]$attemptRows[0].attempt_provider_key_id) -Name "provider_attempts.provider_key_id"
  if ([string]$attemptRows[0].attempt_provider_key_id -ne $ExpectedProviderKeyId) {
    throw "provider_attempts.provider_key_id expected '$ExpectedProviderKeyId', got '$($attemptRows[0].attempt_provider_key_id)'"
  }
  if ($attemptRows[0].attempt_status -ne "succeeded") {
    throw "provider_attempts.status expected 'succeeded', got '$($attemptRows[0].attempt_status)'"
  }
  if ([int]$attemptRows[0].attempt_http_status -ne 200) {
    throw "provider_attempts.http_status expected 200, got '$($attemptRows[0].attempt_http_status)'"
  }

  $script:ChatLogRows = $rows
}

$suffix = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$gatewayHeaders = @{ Authorization = "Bearer $GatewayAuthToken" }

Push-Location $repoRoot
try {
  Check "provider key runtime fixture files exist" {
    foreach ($relativePath in @(
        "scripts\verify_provider_key_runtime_smoke.ps1",
        "scripts\common.ps1",
        "tests\fixtures\gateway\provider_key_runtime_smoke.json",
        "db\dev-seeds\0002_dev_gateway_seed.sql",
        "db\dev-seeds\0003_dev_smoke_seed_reconcile.sql",
        "deploy\docker-compose\docker-compose.yml"
      )) {
      $path = Join-Path $repoRoot $relativePath
      if (-not (Test-Path $path)) {
        throw "missing $relativePath"
      }
    }
  }

  Check "provider key runtime fixture contract" {
    $script:Fixture = Read-Fixture
    Assert-FixtureContract $script:Fixture
  }

  Check "provider key runtime compose env contract" {
    Assert-ComposeProviderKeyRuntimeContract
  }

  Check "provider key runtime dev seed contract" {
    Assert-DevSeedSourceContract
  }

  Check "provider key runtime dev seed opens with compose master key" {
    Assert-DevSeedPayloadOpensWithComposeMasterKey
  }

  Check "provider key runtime script structure" {
    Assert-ScriptStructure
  }

  if ($DryRun) {
    Exit-WithFailuresIfAny
    Write-SafeHost ""
    Write-SafeHost "Provider key runtime smoke dry-run passed; runtime requests were not sent."
    exit 0
  }

  if (-not $SkipComposePs) {
    Check "docker compose provider key runtime services are running" {
      Assert-ComposeServicesRunning
    }
  }

  Check "gateway provider key master key env is configured" {
    $script:GatewayMasterKeyBase64 = Get-ComposeServiceEnvValue -Service "gateway" -Name "AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_BASE64"
    [void](ConvertFrom-Base64MasterKey -RawValue $script:GatewayMasterKeyBase64 -Name "gateway AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_BASE64")
  }

  Check "compose postgres dev provider key seed is complete" {
    Assert-ProviderKeySeedRow
  }

  Check "open provider key material for leak checks" {
    Set-ProviderKeyRawSecretForLeakChecks
  }

  Exit-WithFailuresIfAny

  Check "gateway provider key chat completion succeeds" {
    $body = New-ChatBodyJson -RequestModel $Model -Content "provider key runtime smoke success $suffix"
    $requestHash = Get-Sha256Hex $body
    $response = Invoke-GatewayRequest `
      -Method POST `
      -Uri (Join-Url $GatewayBaseUrl "/v1/chat/completions") `
      -Headers $gatewayHeaders `
      -JsonBody $body

    Assert-NoSecretLeak -Content $response.Content -Label "successful chat response"
    Assert-Status $response 200
    $payload = Read-Json $response.Content
    if ($payload.object -ne "chat.completion") {
      throw "expected object=chat.completion, got '$($payload.object)'"
    }
    Assert-Contains $response.Content '"finish_reason":"stop"'

    Assert-ProviderKeyIdsPersisted -RequestHash $requestHash -ExpectedProviderKeyId ([string]$script:Fixture.dev_seed.provider_key_id)
  }

  Check "gateway provider error output redacts provider key material" {
    $body = New-ChatBodyJson -RequestModel $Model -Content "provider key runtime smoke provider error $suffix" -MockScenario "429"
    $response = Invoke-GatewayRequest `
      -Method POST `
      -Uri (Join-Url $GatewayBaseUrl "/v1/chat/completions") `
      -Headers $gatewayHeaders `
      -JsonBody $body

    Assert-NoSecretLeak -Content $response.Content -Label "provider error response"
    Assert-Status $response 429
    Assert-Contains $response.Content "rate_limit_error"
  }
} finally {
  Pop-Location
}

if ($script:Failures.Count -gt 0) {
  Write-SafeHost ""
  Write-SafeHost "Provider key runtime smoke failed:"
  foreach ($failure in $script:Failures) {
    Write-SafeHost $failure
  }
  exit 1
}

Write-SafeHost ""
Write-SafeHost "Provider key runtime smoke passed."
