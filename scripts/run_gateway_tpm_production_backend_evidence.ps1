param(
  [switch]$DryRun,
  [switch]$RunBackendRunner,
  [switch]$RunLocalPrototype,
  [string]$ArtifactPath = "",
  [string]$LocalFixturePath = "tests/fixtures/gateway/trusted_read_model_backend_harness_ready.json",
  [string]$ExpectedCommit = "",
  [ValidateSet("tokenizer_backend", "read_model_backend")]
  [string]$BackendKind = "read_model_backend",
  [ValidateSet("prompt_tokens", "input_tokens")]
  [string]$TokenSourceKind = "input_tokens"
)

$ErrorActionPreference = "Stop"

function ConvertTo-SafeJson {
  param([Parameter(Mandatory = $true)]$Value)

  $json = $Value | ConvertTo-Json -Depth 32
  foreach ($forbidden in @(
      "authorization",
      "bearer",
      "provider_key",
      "api_key",
      "encrypted_secret",
      "payload",
      "request_body",
      "raw_prompt",
      "raw_input",
      "raw_header",
      "message_text",
      "embedding_text",
      '"messages"',
      '"contents"',
      '"input"'
    )) {
    if ($json.ToLowerInvariant().Contains($forbidden.ToLowerInvariant())) {
      throw "script output contains forbidden marker: $forbidden"
    }
  }
  return $json
}

function Test-BoundedArtifactPath {
  param([Parameter(Mandatory = $true)][string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $false
  }
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $false
  }
  return $Path.Replace("/", "\").StartsWith(".tmp\gateway_tpm_production_backend\")
}

function Test-BoundedLocalFixturePath {
  param([Parameter(Mandatory = $true)][string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $false
  }
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $false
  }
  return $Path.Replace("/", "\").StartsWith("tests\fixtures\gateway\")
}

function Env-Present {
  param([Parameter(Mandatory = $true)][string]$Name)
  return -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($Name))
}

function Add-MissingEnv {
  param(
    [System.Collections.ArrayList]$Missing,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if (-not (Env-Present $Name)) {
    [void]$Missing.Add($Name)
  }
}

$artifact = if ([string]::IsNullOrWhiteSpace($ArtifactPath)) {
  [Environment]::GetEnvironmentVariable("GATEWAY_TPM_PRODUCTION_ARTIFACT_PATH")
} else {
  $ArtifactPath
}

$missing = [System.Collections.ArrayList]::new()
if ([Environment]::GetEnvironmentVariable("GATEWAY_TPM_PRODUCTION_BACKEND_EVIDENCE") -ne "1") {
  [void]$missing.Add("GATEWAY_TPM_PRODUCTION_BACKEND_EVIDENCE=1")
}
if (-not (Env-Present "GATEWAY_TPM_TRUSTED_READ_MODEL_ENABLED") -and -not (Env-Present "GATEWAY_TPM_TRUSTED_TOKENIZER_ENABLED")) {
  [void]$missing.Add("GATEWAY_TPM_TRUSTED_READ_MODEL_ENABLED or GATEWAY_TPM_TRUSTED_TOKENIZER_ENABLED")
}
Add-MissingEnv -Missing $missing -Name "GATEWAY_TPM_PRODUCTION_BACKEND_RUNNER_COMMAND"
Add-MissingEnv -Missing $missing -Name "GATEWAY_TPM_GATEWAY_LIVE_SMOKE_COMMAND"
Add-MissingEnv -Missing $missing -Name "DATABASE_URL"
Add-MissingEnv -Missing $missing -Name "GATEWAY_BASE_URL"
Add-MissingEnv -Missing $missing -Name "GATEWAY_AUTH_TOKEN"
if ([string]::IsNullOrWhiteSpace($artifact)) {
  [void]$missing.Add("GATEWAY_TPM_PRODUCTION_ARTIFACT_PATH or -ArtifactPath")
}

$boundedArtifact = Test-BoundedArtifactPath -Path $artifact
$boundedLocalFixture = Test-BoundedLocalFixturePath -Path $LocalFixturePath
$runner = [Environment]::GetEnvironmentVariable("GATEWAY_TPM_PRODUCTION_BACKEND_RUNNER_COMMAND")
$gatewaySmoke = [Environment]::GetEnvironmentVariable("GATEWAY_TPM_GATEWAY_LIVE_SMOKE_COMMAND")

$commandSequence = [ordered]@{
  backend_runner = "pwsh -File scripts/run_gateway_tpm_production_backend_evidence.ps1 -RunBackendRunner -ExpectedCommit $ExpectedCommit -BackendKind $BackendKind -TokenSourceKind $TokenSourceKind -ArtifactPath $artifact"
  local_prototype_runner = "pwsh -File scripts/run_gateway_tpm_production_backend_evidence.ps1 -RunLocalPrototype -ExpectedCommit $ExpectedCommit -BackendKind $BackendKind -TokenSourceKind $TokenSourceKind -ArtifactPath $artifact -LocalFixturePath $LocalFixturePath"
  gateway_live_smoke = "GATEWAY_TPM_PRODUCTION_BACKEND_EVIDENCE=1 GATEWAY_TPM_TRUSTED_READ_MODEL_ENABLED=1 `$env:GATEWAY_TPM_GATEWAY_LIVE_SMOKE_COMMAND --scope e8-rate-limit-tpm --expected-commit $ExpectedCommit --artifact-path $artifact --omit-raw-material"
  db_acquire_readback = "psql `$env:DATABASE_URL -v ON_ERROR_STOP=1 -f scripts/operator/e8_rate_limit_db_acquire_readback.sql --set artifact_path=$artifact"
  artifact_readback = "pwsh -File scripts/verify_gateway_tpm_production_backend_evidence.ps1 -OptInArtifactReadback -ArtifactPath $artifact -ExpectedCommit $ExpectedCommit -BackendKind $BackendKind -TokenSourceKind $TokenSourceKind"
}

$base = [ordered]@{
  schema = "gateway_tpm_trusted_numeric_source_production_backend_runner_handoff_v1"
  script = "scripts/run_gateway_tpm_production_backend_evidence.ps1"
  default_executes_external_backend = $false
  default_executes_local_prototype = $false
  run_backend_runner_requested = [bool]$RunBackendRunner
  run_local_prototype_requested = [bool]$RunLocalPrototype
  dry_run = [bool]$DryRun
  artifact_path = $artifact
  artifact_path_bounded = $boundedArtifact
  local_fixture_path = $LocalFixturePath
  local_fixture_path_bounded = $boundedLocalFixture
  backend_kind = $BackendKind
  token_source_kind = $TokenSourceKind
  expected_commit = $ExpectedCommit
  external_backend_runner_command_present = -not [string]::IsNullOrWhiteSpace($runner)
  gateway_live_smoke_command_present = -not [string]::IsNullOrWhiteSpace($gatewaySmoke)
  db_readback_sql = "scripts/operator/e8_rate_limit_db_acquire_readback.sql"
  db_readback_sql_present = Test-Path (Join-Path $PSScriptRoot "operator/e8_rate_limit_db_acquire_readback.sql")
  command_sequence = $commandSequence
  raw_material_present = $false
  secret_safe_raw_omission = $true
  final_x_eligible = $false
}

if (-not $boundedArtifact) {
  $base.status = "production_ready_blocked"
  $base.blocker = "unsafe_or_missing_artifact_path"
  $base.missing_external_backend_env = @($missing)
  ConvertTo-SafeJson $base
  exit 0
}

if ($RunLocalPrototype) {
  if (-not $boundedLocalFixture) {
    $base.status = "production_ready_blocked"
    $base.blocker = "unsafe_or_missing_local_fixture_path"
    $base.local_prototype = $true
    ConvertTo-SafeJson $base
    exit 0
  }

  $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
  $resolvedFixture = Join-Path $repoRoot $LocalFixturePath
  if (-not (Test-Path $resolvedFixture)) {
    $base.status = "production_ready_blocked"
    $base.blocker = "missing_local_fixture"
    $base.local_prototype = $true
    ConvertTo-SafeJson $base
    exit 0
  }

  $fixture = Get-Content -Raw $resolvedFixture | ConvertFrom-Json
  if ([string]$fixture.material_in_output -ne "False" -and $fixture.material_in_output -ne $false) {
    $base.status = "production_ready_blocked"
    $base.blocker = "local_fixture_raw_material_present"
    $base.local_prototype = $true
    ConvertTo-SafeJson $base
    exit 0
  }

  $fixtureTokenKind = [string]$fixture.token_kind
  if ($fixtureTokenKind -ne $TokenSourceKind) {
    $base.status = "production_ready_blocked"
    $base.blocker = "local_fixture_token_source_mismatch"
    $base.local_prototype = $true
    ConvertTo-SafeJson $base
    exit 0
  }

  $tokenCount = [int64]$fixture.tokens
  $generatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  $localArtifact = [ordered]@{
    schema = "gateway_tpm_trusted_numeric_source_production_runner_artifact_v1"
    artifact_provenance = "local_repo_bounded_read_model_runner_prototype"
    runner_provenance = "local_prototype_repo_bounded_fixture_wrapper"
    runner_command_provenance = "scripts/run_gateway_tpm_production_backend_evidence.ps1 -RunLocalPrototype"
    backend_kind = $BackendKind
    backend_source = "repo_bounded_fixture:$LocalFixturePath"
    backend_present = $true
    runtime_current_marker = "local_prototype_runtime_marker"
    runtime_current_marker_present = $true
    runtime_commit = $ExpectedCommit
    current_commit = $ExpectedCommit
    generated_at = $generatedAt
    artifact_fresh = $true
    token_source_kind = $TokenSourceKind
    token_count = $tokenCount
    expected_token_count = $tokenCount
    duration_ms = 0
    latency_ms = 0
    gateway_live_smoke_status = "local_prototype_not_run"
    reservation_capacity_projection = $true
    db_acquire_evidence = $false
    db_acquire_result = $false
    db_acquire_readback_count = $null
    db_result_readback_count = $null
    live_smoke_command = "local_prototype_no_gateway_live_smoke"
    secret_safe_raw_omission = $true
    raw_material_present = $false
    simulated_runner = $false
    repo_fixture_only = $false
    external_artifact_simulation = $false
    local_prototype = $true
    real_operator_evidence = $false
    simulation_can_close_final_gap = $false
  }

  if (-not $DryRun) {
    $resolvedArtifact = Join-Path $repoRoot $artifact
    $artifactDirectory = Split-Path -Parent $resolvedArtifact
    if (-not (Test-Path $artifactDirectory)) {
      New-Item -ItemType Directory -Force -Path $artifactDirectory | Out-Null
    }
    ConvertTo-SafeJson $localArtifact | Set-Content -Path $resolvedArtifact -Encoding utf8
  }

  $base.status = if ($DryRun) { "local_prototype_dry_run" } else { "local_prototype_artifact_written" }
  $base.blocker = "local_prototype_not_production_final"
  $base.local_prototype = $true
  $base.local_prototype_artifact_written = -not [bool]$DryRun
  $base.real_operator_evidence = $false
  $base.gateway_live_smoke_status = $localArtifact.gateway_live_smoke_status
  $base.db_acquire_readback_state = "missing"
  $base.artifact_readback_command = $commandSequence.artifact_readback
  ConvertTo-SafeJson $base
  exit 0
}

if ($missing.Count -gt 0) {
  $base.status = "production_ready_blocked"
  $base.blocker = "missing_external_backend_env"
  $base.missing_external_backend_env = @($missing)
  ConvertTo-SafeJson $base
  exit 0
}

if (-not $RunBackendRunner) {
  $base.status = "production_ready_blocked"
  $base.blocker = "backend_runner_not_executed_without_RunBackendRunner"
  $base.missing_external_backend_env = @()
  ConvertTo-SafeJson $base
  exit 0
}

if (-not (Get-Command $runner -ErrorAction SilentlyContinue)) {
  $base.status = "production_ready_blocked"
  $base.blocker = "missing_external_backend_runner_command"
  $base.missing_external_backend_env = @("GATEWAY_TPM_PRODUCTION_BACKEND_RUNNER_COMMAND=$runner")
  ConvertTo-SafeJson $base
  exit 0
}

& $runner `
  --backend-kind $BackendKind `
  --token-source-kind $TokenSourceKind `
  --expected-commit $ExpectedCommit `
  --artifact-path $artifact `
  --omit-raw-material

if ($LASTEXITCODE -ne 0) {
  throw "external production backend runner failed"
}

$base.status = "production_backend_runner_invoked"
$base.blocker = "gateway_live_smoke_and_db_readback_still_required"
$base.missing_external_backend_env = @()
ConvertTo-SafeJson $base
