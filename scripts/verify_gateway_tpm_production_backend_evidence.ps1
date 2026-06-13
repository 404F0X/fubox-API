param(
  [switch]$ContractOnly,
  [switch]$EmitWatcher,
  [switch]$EmitExecutionPack,
  [switch]$EmitLiveCommand,
  [switch]$OptInArtifactReadback,
  [string]$ArtifactPath = "",
  [string]$ExpectedCommit = "",
  [string]$BackendKind = "",
  [string]$TokenSourceKind = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$schema = "gateway_tpm_trusted_numeric_source_production_backend_evidence_runbook_v1"
$runnerSchema = "gateway_tpm_trusted_numeric_source_production_runner_artifact_v1"
$acceptanceSchema = "gateway_tpm_trusted_numeric_source_production_backend_evidence_acceptance_matrix_v1"
$executionPackSchema = "gateway_tpm_trusted_numeric_source_production_backend_live_execution_pack_v1"
$closureAuditSchema = "gateway_tpm_trusted_numeric_source_final_closure_evidence_audit_v1"
$watcherSchema = "gateway_tpm_trusted_numeric_source_production_evidence_watcher_v1"
$scriptName = "scripts/verify_gateway_tpm_production_backend_evidence.ps1"

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

  $normalized = $Path.Replace("/", "\")
  return $normalized.StartsWith("tests\fixtures\gateway\") -or
    $normalized.StartsWith(".tmp\gateway_tpm_production_backend\")
}

function New-BaseContract {
  return [ordered]@{
    schema = $schema
    acceptance_schema = $acceptanceSchema
    execution_pack_schema = $executionPackSchema
    closure_audit_schema = $closureAuditSchema
    watcher_schema = $watcherSchema
    script = $scriptName
    default_mode = "contract_only_no_io"
    default_reads_artifact = $false
    default_connects_backend = $false
    default_reads_raw_material = $false
    default_sends_network = $false
    explicit_opt_in_required = $true
    required_env = @(
      "GATEWAY_TPM_PRODUCTION_BACKEND_EVIDENCE=1",
      "GATEWAY_TPM_TRUSTED_TOKENIZER_ENABLED=1 or GATEWAY_TPM_TRUSTED_READ_MODEL_ENABLED=1"
    )
    required_flags = @(
      "-OptInArtifactReadback",
      "-ArtifactPath <tests/fixtures/gateway|.tmp/gateway_tpm_production_backend/*.json>",
      "-ExpectedCommit <current-runtime-commit>",
      "-BackendKind tokenizer_backend|read_model_backend",
      "-TokenSourceKind prompt_tokens|input_tokens",
      "-EmitWatcher",
      "-EmitExecutionPack"
    )
    command_shapes = [ordered]@{
      preflight = "pwsh -File scripts/verify_gateway_tpm_production_backend_evidence.ps1 -ContractOnly"
      execution_pack = "pwsh -File scripts/verify_gateway_tpm_production_backend_evidence.ps1 -EmitExecutionPack -ExpectedCommit <commit> -BackendKind read_model_backend -TokenSourceKind input_tokens"
      watcher = "pwsh -File scripts/verify_gateway_tpm_production_backend_evidence.ps1 -EmitWatcher -ExpectedCommit <commit> -BackendKind read_model_backend -TokenSourceKind input_tokens"
      readback = "pwsh -File scripts/verify_gateway_tpm_production_backend_evidence.ps1 -OptInArtifactReadback -ArtifactPath .tmp/gateway_tpm_production_backend/<artifact>.json -ExpectedCommit <commit> -BackendKind read_model_backend -TokenSourceKind input_tokens"
      live_command_handoff = "GATEWAY_TPM_PRODUCTION_BACKEND_EVIDENCE=1 GATEWAY_TPM_TRUSTED_READ_MODEL_ENABLED=1 pwsh -File scripts/verify_gateway_tpm_production_backend_evidence.ps1 -EmitLiveCommand -ExpectedCommit <commit> -BackendKind read_model_backend -TokenSourceKind input_tokens"
      final_closure_audit = "pwsh -File scripts/verify_gateway_tpm_production_backend_evidence.ps1 -ContractOnly"
    }
    artifact_schema_fields = @(
      "artifact_provenance",
      "runner_provenance",
      "runner_command_provenance",
      "backend_kind",
      "backend_source",
      "runtime_current_marker",
      "runtime_commit",
      "current_commit",
      "generated_at",
      "token_source_kind",
      "token_count",
      "duration_ms",
      "latency_ms",
      "gateway_live_smoke_status",
      "reservation_capacity_projection",
      "db_acquire_evidence",
      "db_acquire_result",
      "db_acquire_readback_count",
      "db_result_readback_count",
      "live_smoke_command",
      "secret_safe_raw_omission",
      "local_prototype",
      "real_operator_evidence",
      "production_scope",
      "simulation_can_close_final_gap"
    )
    failure_taxonomy = @(
      "missing_opt_in",
      "unsafe_artifact_path",
      "missing_backend",
      "stale_runtime",
      "stale_artifact",
      "artifact_stale",
      "repo_fixture_only",
      "simulated_runner",
      "token_mismatch",
      "missing_live_smoke",
      "missing_db_acquire",
      "missing_db_result",
      "missing_duration",
      "duration_non_numeric",
      "raw_material_present"
      "commit_mismatch",
      "backend_kind_mismatch",
      "local_prototype",
      "missing_real_operator_evidence",
      "missing_production_scope"
    )
    acceptance_matrix = [ordered]@{
      accepted_for_review = @(
        "schema matches",
        "artifact provenance present",
        "runner command provenance present",
        "backend kind/source match expected values",
        "runtime/current commit markers match expected runtime",
        "generated_at present and artifact_fresh is not false",
        "token source/count match expected values",
        "duration_ms and latency_ms are numeric",
        "Gateway live smoke status is passed",
        "reservation projection is present",
        "DB acquire/result evidence and readback counts are present",
        "secret-safe raw omission is asserted",
        "real_operator_evidence is true for production final",
        "local_prototype is false for production final",
        "production_scope is production for production final"
      )
      refused = @(
        "missing opt-in",
        "unsafe path",
        "missing backend",
        "stale artifact",
        "stale runtime",
        "repo fixture only",
        "simulated runner",
        "token mismatch",
        "missing live smoke",
        "missing DB acquire/result",
        "duration non-numeric",
        "raw material present",
        "commit mismatch",
        "backend kind mismatch",
        "local prototype cannot close final gap",
        "missing real operator evidence",
        "missing production scope"
      )
    }
    status_semantics = [ordered]@{
      production_ready_blocked = "operator handoff is incomplete or non-production; cannot close E8"
      production_evidence_accepted_for_review = "bounded artifact has the required external evidence shape but is a repo simulation or still needs operator review; cannot close final E8 gap"
      production_backend_live_smoke_passed = "fresh non-simulated non-fixture production runner artifact passed readback with DB acquire/result evidence"
      final_e8_x = "requires production_backend_live_smoke_passed plus reviewed live Gateway smoke/readback; contract/selftest/fixture alone cannot substitute"
    }
    execution_pack = [ordered]@{
      schema = $executionPackSchema
      default_executes_live_command = $false
      default_reads_external_artifact = $false
      default_connects_backend = $false
      default_sends_network = $false
      artifact_directory = ".tmp/gateway_tpm_production_backend"
      artifact_write_path = ".tmp/gateway_tpm_production_backend/<commit>-<backend-kind>-e8-live-evidence.json"
      required_env = @(
        "GATEWAY_TPM_PRODUCTION_BACKEND_EVIDENCE=1",
        "GATEWAY_TPM_TRUSTED_READ_MODEL_ENABLED=1 or GATEWAY_TPM_TRUSTED_TOKENIZER_ENABLED=1",
        "GATEWAY_TPM_PRODUCTION_ARTIFACT_PATH=.tmp/gateway_tpm_production_backend/<artifact>.json",
        "DATABASE_URL=<operator-provided-secret-in-shell-only>"
      )
      preflight_checklist = @(
        "current runtime commit marker matches -ExpectedCommit",
        "backend kind/source are declared by operator",
        "token source kind/count are numeric and match expected count",
        "live smoke URL/scope is bounded to Gateway operator smoke",
        "DB reservation table/readback target is declared",
        "artifact path stays under .tmp/gateway_tpm_production_backend",
        "secret-safe raw omission is asserted"
      )
      commands = [ordered]@{
        preflight = "pwsh -File scripts/verify_gateway_tpm_production_backend_evidence.ps1 -ContractOnly"
        backend_runner = "GATEWAY_TPM_PRODUCTION_BACKEND_EVIDENCE=1 GATEWAY_TPM_TRUSTED_READ_MODEL_ENABLED=1 GATEWAY_TPM_PRODUCTION_BACKEND_RUNNER_COMMAND=<external-production-runner-command> pwsh -File scripts/run_gateway_tpm_production_backend_evidence.ps1 -RunBackendRunner -ExpectedCommit <commit> -BackendKind read_model_backend -TokenSourceKind input_tokens -ArtifactPath .tmp/gateway_tpm_production_backend/<artifact>.json"
        gateway_live_smoke = "GATEWAY_TPM_PRODUCTION_BACKEND_EVIDENCE=1 GATEWAY_TPM_TRUSTED_READ_MODEL_ENABLED=1 GATEWAY_TPM_GATEWAY_LIVE_SMOKE_COMMAND=<gateway-live-smoke-command> `$env:GATEWAY_TPM_GATEWAY_LIVE_SMOKE_COMMAND --scope e8-rate-limit-tpm --expected-commit <commit> --artifact-path .tmp/gateway_tpm_production_backend/<artifact>.json --omit-raw-material"
        db_acquire_readback = "psql `$env:DATABASE_URL -v ON_ERROR_STOP=1 -f scripts/operator/e8_rate_limit_db_acquire_readback.sql --set artifact_path=.tmp/gateway_tpm_production_backend/<artifact>.json"
        artifact_readback = "pwsh -File scripts/verify_gateway_tpm_production_backend_evidence.ps1 -OptInArtifactReadback -ArtifactPath .tmp/gateway_tpm_production_backend/<artifact>.json -ExpectedCommit <commit> -BackendKind read_model_backend -TokenSourceKind input_tokens"
        cleanup = "Remove-Item -LiteralPath .tmp/gateway_tpm_production_backend/<artifact>.json after evidence is copied to the operator evidence store"
        rollback = "unset GATEWAY_TPM_PRODUCTION_BACKEND_EVIDENCE, GATEWAY_TPM_TRUSTED_READ_MODEL_ENABLED, GATEWAY_TPM_TRUSTED_TOKENIZER_ENABLED, and GATEWAY_TPM_PRODUCTION_ARTIFACT_PATH; stop the smoke process without changing Gateway defaults"
      }
      expected_accepted_fields = @(
        "artifact_provenance",
        "runner_provenance",
        "runner_command_provenance",
        "backend_kind",
        "backend_source",
        "runtime_current_marker",
        "runtime_commit",
        "current_commit",
        "generated_at",
        "artifact_fresh",
        "token_source_kind",
        "token_count",
        "expected_token_count",
        "duration_ms",
        "latency_ms",
        "gateway_live_smoke_status",
        "reservation_capacity_projection",
        "db_acquire_evidence",
        "db_acquire_result",
        "db_acquire_readback_count",
        "db_result_readback_count",
        "live_smoke_command",
        "secret_safe_raw_omission",
        "raw_material_present",
        "simulated_runner",
        "repo_fixture_only",
        "simulation_can_close_final_gap"
      )
      final_proof_bundle = @(
        "production_backend_live_smoke_passed readback",
        "live Gateway smoke evidence",
        "DB acquire/readback evidence",
        "secret-safe proof with raw material omitted"
      )
    }
    closure_audit_contract = [ordered]@{
      schema = $closureAuditSchema
      default_final_x_eligible = $false
      simulation_can_mark_final_x = $false
      template_can_pass = $false
      watcher_can_mark_final_x = $false
      default_artifact_read = $false
      default_blocking_reasons = @("missing_opt_in", "missing_production_artifact", "missing_live_gateway_smoke", "missing_db_acquire_readback")
      required_evidence = @(
        "production_backend_live_smoke_passed artifact readback",
        "real non-simulated operator backend provenance",
        "current runtime marker and current commit",
        "live Gateway smoke status passed",
        "DB acquire/result/readback counts",
        "secret-safe raw omission proof",
        "generated_at/current commit in artifact"
      )
    }
    watcher_checklist_contract = [ordered]@{
      schema = $watcherSchema
      watcher_can_mark_final_x = $false
      template_can_pass = $false
      simulation_can_mark_final_x = $false
      safe_defaults = [ordered]@{
        polls = $false
        reads_artifact = $false
        sends_network = $false
        connects_backend = $false
        reads_raw_material = $false
      }
      expected_artifact_paths = @(
        ".tmp/gateway_tpm_production_backend/<commit>-<backend-kind>-e8-live-evidence.json",
        "tests/fixtures/gateway/<contract-only-fixture>.json"
      )
      required_operator_actions = @(
        "run the real production tokenizer/read-model backend runner",
        "run Gateway live smoke with bounded E8 rate-limit TPM scope",
        "write the production artifact under .tmp/gateway_tpm_production_backend",
        "include DB acquire/result/readback counts",
        "omit raw prompt/input/body/header material",
        "run explicit opt-in artifact readback"
      )
      final_review_checklist = @(
        "closure audit final_x_eligible is true",
        "artifact acceptance state is production_backend_live_smoke_passed",
        "real_operator_evidence is true",
        "simulation is false",
        "template_can_pass is false",
        "watcher_can_mark_final_x is false",
        "live smoke state is passed",
        "DB acquire/readback state is present",
        "secret-safe omission is true"
      )
    }
    final_guard_consistency = [ordered]@{
      simulation_can_mark_final_x = $false
      template_can_pass = $false
      watcher_can_mark_final_x = $false
      accepted_for_review_can_mark_final_x = $false
      production_shaped_temp_artifact_can_replace_real_evidence = $false
      final_x_requires = @(
        "real production backend runner",
        "live Gateway smoke/readback",
        "DB acquire/readback",
        "secret-safe proof"
      )
    }
  }
}

function New-ClosureAudit {
  param(
    [Parameter(Mandatory = $true)][string]$ArtifactAcceptanceState,
    [string]$Blocker = "",
    $Artifact = $null,
    [bool]$ArtifactRead = $false,
    [bool]$FinalEligible = $false
  )

  $blockingReasons = @()
  if (-not $FinalEligible) {
    if (-not [string]::IsNullOrWhiteSpace($Blocker)) {
      $blockingReasons += $Blocker
    }
    if (-not $ArtifactRead) {
      $blockingReasons += "missing_opt_in"
      $blockingReasons += "missing_production_artifact"
    }
    if ($null -eq $Artifact) {
      $blockingReasons += "missing_live_gateway_smoke"
      $blockingReasons += "missing_db_acquire_readback"
    } else {
      if ([string]$Artifact.gateway_live_smoke_status -ne "passed") { $blockingReasons += "missing_live_smoke" }
      if (-not $Artifact.db_acquire_evidence -or $null -eq $Artifact.db_acquire_readback_count) { $blockingReasons += "missing_db_acquire" }
      if (-not $Artifact.db_acquire_result -or $null -eq $Artifact.db_result_readback_count) { $blockingReasons += "missing_db_result" }
      if ($Artifact.local_prototype -eq $true) { $blockingReasons += "local_prototype_cannot_close_final_gap" }
      if ($Artifact.external_artifact_simulation -eq $true) { $blockingReasons += "accepted_simulation_cannot_close_final_gap" }
      if ($Artifact.simulated_runner -eq $true) { $blockingReasons += "simulated_runner" }
      if ($Artifact.repo_fixture_only -eq $true) { $blockingReasons += "repo_fixture_only" }
      if ($Artifact.simulation_can_close_final_gap -ne $true) { $blockingReasons += "simulation_can_close_final_gap_false" }
      if ($Artifact.simulation_can_close_final_gap -eq $true -and $Artifact.real_operator_evidence -ne $true) { $blockingReasons += "missing_real_operator_evidence" }
      if ($Artifact.simulation_can_close_final_gap -eq $true -and [string]$Artifact.production_scope -ne "production") { $blockingReasons += "missing_production_scope" }
      if ($Artifact.secret_safe_raw_omission -ne $true -or $Artifact.raw_material_present -eq $true) { $blockingReasons += "raw_material_present" }
    }
  }
  $blockingReasons = @($blockingReasons | Select-Object -Unique)

  return [ordered]@{
    schema = $closureAuditSchema
    final_x_eligible = $FinalEligible
    simulation_can_mark_final_x = $false
    template_can_pass = $false
    watcher_can_mark_final_x = $false
    blocking_reasons = $blockingReasons
    required_evidence = @(
      "production_backend_live_smoke_passed artifact readback",
      "real non-simulated operator backend provenance",
      "current runtime marker and current commit",
      "live Gateway smoke status passed",
      "DB acquire/result/readback counts",
      "secret-safe raw omission proof",
      "generated_at/current commit in artifact"
    )
    artifact_acceptance_state = $ArtifactAcceptanceState
    live_smoke_state = if ($null -eq $Artifact) { "missing" } else { [string]$Artifact.gateway_live_smoke_status }
    db_acquire_readback_state = if ($null -eq $Artifact) {
      "missing"
    } elseif ($Artifact.db_acquire_evidence -and $Artifact.db_acquire_result -and $null -ne $Artifact.db_acquire_readback_count -and $null -ne $Artifact.db_result_readback_count) {
      "present"
    } else {
      "missing"
    }
    backend_provenance = if ($null -eq $Artifact) { "missing" } else { [string]$Artifact.runner_provenance }
    backend_kind = if ($null -eq $Artifact) { $BackendKind } else { [string]$Artifact.backend_kind }
    backend_source_present = if ($null -eq $Artifact) { $false } else { [bool]$Artifact.backend_source }
    runtime_current_marker = if ($null -eq $Artifact) { "missing" } else { [string]$Artifact.runtime_current_marker }
    runtime_commit = if ($null -eq $Artifact) { "" } else { [string]$Artifact.runtime_commit }
    current_commit = if ($null -eq $Artifact) { $ExpectedCommit } else { [string]$Artifact.current_commit }
    generated_at = if ($null -eq $Artifact) { "" } else { [string]$Artifact.generated_at }
    secret_safe_omission = if ($null -eq $Artifact) { $false } else { [bool]$Artifact.secret_safe_raw_omission -and -not [bool]$Artifact.raw_material_present }
    artifact_read = $ArtifactRead
    simulation = if ($null -eq $Artifact) { $false } else { [bool]$Artifact.external_artifact_simulation -or [bool]$Artifact.simulated_runner }
    local_prototype = if ($null -eq $Artifact) { $false } else { [bool]$Artifact.local_prototype }
    real_operator_evidence = if ($null -eq $Artifact) { $false } else { [bool]$Artifact.real_operator_evidence -and -not [bool]$Artifact.external_artifact_simulation -and -not [bool]$Artifact.simulated_runner -and -not [bool]$Artifact.repo_fixture_only -and -not [bool]$Artifact.local_prototype }
    production_scope = if ($null -eq $Artifact) { "missing" } else { [string]$Artifact.production_scope }
    exact_next_commands = [ordered]@{
      execution_pack = "pwsh -File scripts/verify_gateway_tpm_production_backend_evidence.ps1 -EmitExecutionPack -ExpectedCommit <commit> -BackendKind read_model_backend -TokenSourceKind input_tokens"
      artifact_readback = "pwsh -File scripts/verify_gateway_tpm_production_backend_evidence.ps1 -OptInArtifactReadback -ArtifactPath .tmp/gateway_tpm_production_backend/<artifact>.json -ExpectedCommit <commit> -BackendKind read_model_backend -TokenSourceKind input_tokens"
      gateway_live_smoke = "GATEWAY_TPM_PRODUCTION_BACKEND_EVIDENCE=1 GATEWAY_TPM_TRUSTED_READ_MODEL_ENABLED=1 GATEWAY_TPM_GATEWAY_LIVE_SMOKE_COMMAND=<gateway-live-smoke-command> `$env:GATEWAY_TPM_GATEWAY_LIVE_SMOKE_COMMAND --scope e8-rate-limit-tpm --expected-commit <commit> --artifact-path .tmp/gateway_tpm_production_backend/<artifact>.json --omit-raw-material"
      db_acquire_readback = "psql `$env:DATABASE_URL -v ON_ERROR_STOP=1 -f scripts/operator/e8_rate_limit_db_acquire_readback.sql --set artifact_path=.tmp/gateway_tpm_production_backend/<artifact>.json"
    }
  }
}

function Test-NumericField {
  param($Value)

  if ($null -eq $Value) {
    return $false
  }
  $parsed = 0.0
  return [double]::TryParse(
    [string]$Value,
    [System.Globalization.NumberStyles]::Float,
    [System.Globalization.CultureInfo]::InvariantCulture,
    [ref]$parsed
  )
}

function Classify-Artifact {
  param([Parameter(Mandatory = $true)]$Artifact)

  if ([string]$Artifact.schema -ne $runnerSchema) { return "artifact_stale" }
  if (-not $Artifact.artifact_provenance) { return "missing_backend" }
  if (-not $Artifact.runner_provenance) { return "missing_backend" }
  if (-not $Artifact.runner_command_provenance) { return "missing_backend" }
  if (-not $Artifact.backend_present) { return "missing_backend" }
  if (-not $Artifact.runtime_current_marker_present) { return "stale_runtime" }
  if ([string]$Artifact.runtime_commit -ne [string]$Artifact.current_commit) { return "stale_runtime" }
  if ([string]$Artifact.current_commit -ne $ExpectedCommit) { return "commit_mismatch" }
  if (-not $Artifact.generated_at) { return "artifact_stale" }
  if ($Artifact.artifact_fresh -eq $false) { return "stale_artifact" }
  if ($Artifact.repo_fixture_only -eq $true) { return "repo_fixture_only" }
  if ($Artifact.simulated_runner -eq $true) { return "simulated_runner" }
  if ($BackendKind -and [string]$Artifact.backend_kind -ne $BackendKind) { return "backend_kind_mismatch" }
  if (-not $Artifact.backend_source) { return "missing_backend" }
  if ($TokenSourceKind -and [string]$Artifact.token_source_kind -ne $TokenSourceKind) { return "token_mismatch" }
  if ($null -eq $Artifact.token_count) { return "token_mismatch" }
  if ($null -eq $Artifact.expected_token_count) { return "token_mismatch" }
  if ([int64]$Artifact.token_count -ne [int64]$Artifact.expected_token_count) { return "token_mismatch" }
  if ($null -eq $Artifact.duration_ms) { return "missing_duration" }
  if (-not (Test-NumericField -Value $Artifact.duration_ms)) { return "duration_non_numeric" }
  if ($null -eq $Artifact.latency_ms) { return "missing_duration" }
  if (-not (Test-NumericField -Value $Artifact.latency_ms)) { return "duration_non_numeric" }
  if ([string]$Artifact.gateway_live_smoke_status -ne "passed") { return "missing_live_smoke" }
  if (-not $Artifact.reservation_capacity_projection) { return "token_mismatch" }
  if (-not $Artifact.db_acquire_evidence) { return "missing_db_acquire" }
  if (-not $Artifact.db_acquire_result) { return "missing_db_result" }
  if ($null -eq $Artifact.db_acquire_readback_count) { return "missing_db_acquire" }
  if ($null -eq $Artifact.db_result_readback_count) { return "missing_db_result" }
  if (-not $Artifact.live_smoke_command) { return "missing_backend" }
  if ($Artifact.secret_safe_raw_omission -ne $true) { return "raw_material_present" }
  if ($Artifact.raw_material_present -eq $true) { return "raw_material_present" }
  return $null
}

function New-WatcherChecklist {
  param(
    [Parameter(Mandatory = $true)][string]$CurrentStatus,
    [string]$Blocker = "",
    [string]$ArtifactAcceptanceState = "production_ready_blocked",
    [bool]$ArtifactRead = $false,
    [bool]$ArtifactExists = $false,
    [bool]$FinalEligible = $false
  )

  $artifactPathHint = if ([string]::IsNullOrWhiteSpace($ArtifactPath)) {
    ".tmp/gateway_tpm_production_backend/<commit>-<backend-kind>-e8-live-evidence.json"
  } else {
    $ArtifactPath
  }

  return [ordered]@{
    schema = $watcherSchema
    current_status = $CurrentStatus
    blocker = $Blocker
    final_x_eligible = $FinalEligible
    artifact_acceptance_state = $ArtifactAcceptanceState
    artifact_read = $ArtifactRead
    artifact_exists = $ArtifactExists
    expected_artifact_paths = @(
      ".tmp/gateway_tpm_production_backend/<commit>-<backend-kind>-e8-live-evidence.json",
      "tests/fixtures/gateway/<contract-only-fixture>.json"
    )
    required_operator_actions = @(
      "run the real production tokenizer/read-model backend runner",
      "run Gateway live smoke with bounded E8 rate-limit TPM scope",
      "write the production artifact under .tmp/gateway_tpm_production_backend",
      "include DB acquire/result/readback counts",
      "omit raw prompt/input/body/header material",
      "run explicit opt-in artifact readback"
    )
    exact_commands = [ordered]@{
      watcher_default = "pwsh -File scripts/verify_gateway_tpm_production_backend_evidence.ps1 -EmitWatcher -ExpectedCommit <commit> -BackendKind read_model_backend -TokenSourceKind input_tokens"
      execution_pack = "pwsh -File scripts/verify_gateway_tpm_production_backend_evidence.ps1 -EmitExecutionPack -ExpectedCommit <commit> -BackendKind read_model_backend -TokenSourceKind input_tokens"
      artifact_readback = "pwsh -File scripts/verify_gateway_tpm_production_backend_evidence.ps1 -OptInArtifactReadback -ArtifactPath $artifactPathHint -ExpectedCommit <commit> -BackendKind read_model_backend -TokenSourceKind input_tokens"
      final_closure_audit = "pwsh -File scripts/verify_gateway_tpm_production_backend_evidence.ps1 -ContractOnly"
    }
    final_review_checklist = @(
      "closure audit final_x_eligible is true",
      "artifact acceptance state is production_backend_live_smoke_passed",
      "real_operator_evidence is true",
      "simulation is false",
      "live smoke state is passed",
      "DB acquire/readback state is present",
      "secret-safe omission is true"
    )
    safe_defaults = [ordered]@{
      polls = $false
      reads_artifact = $false
      sends_network = $false
      connects_backend = $false
      reads_raw_material = $false
    }
  }
}

$contract = New-BaseContract

if ($ContractOnly -or (-not $OptInArtifactReadback -and -not $EmitLiveCommand -and -not $EmitExecutionPack -and -not $EmitWatcher)) {
  $contract.status = "production_ready_blocked"
  $contract.blocker = "missing_opt_in"
  $contract.artifact_read = $false
  $contract.command_plan_only = $true
  $contract.closure_audit = New-ClosureAudit -ArtifactAcceptanceState "production_ready_blocked" -Blocker "missing_opt_in" -ArtifactRead $false
  $contract.watcher_checklist = New-WatcherChecklist -CurrentStatus "production_ready_blocked" -Blocker "missing_opt_in"
  ConvertTo-SafeJson $contract
  exit 0
}

if ($EmitWatcher) {
  $contract.status = "production_ready_blocked"
  $contract.blocker = "waiting_for_production_evidence"
  $contract.artifact_read = $false
  $contract.command_plan_only = $true
  $contract.closure_audit = New-ClosureAudit -ArtifactAcceptanceState "production_ready_blocked" -Blocker "waiting_for_production_evidence" -ArtifactRead $false
  $contract.watcher_checklist = New-WatcherChecklist -CurrentStatus "production_ready_blocked" -Blocker "waiting_for_production_evidence"
  ConvertTo-SafeJson $contract
  exit 0
}

if ($EmitExecutionPack) {
  $contract.status = "production_ready_blocked"
  $contract.blocker = "execution_pack_plan_only"
  $contract.artifact_read = $false
  $contract.command_plan_only = $true
  $contract.closure_audit = New-ClosureAudit -ArtifactAcceptanceState "production_ready_blocked" -Blocker "execution_pack_plan_only" -ArtifactRead $false
  $contract.watcher_checklist = New-WatcherChecklist -CurrentStatus "production_ready_blocked" -Blocker "execution_pack_plan_only"
  ConvertTo-SafeJson $contract
  exit 0
}

if ($EmitLiveCommand) {
  $contract.status = "production_ready_blocked"
  $contract.blocker = "live_command_handoff_only"
  $contract.artifact_read = $false
  $contract.live_command = $contract.command_shapes.live_command_handoff
  $contract.closure_audit = New-ClosureAudit -ArtifactAcceptanceState "production_ready_blocked" -Blocker "live_command_handoff_only" -ArtifactRead $false
  $contract.watcher_checklist = New-WatcherChecklist -CurrentStatus "production_ready_blocked" -Blocker "live_command_handoff_only"
  ConvertTo-SafeJson $contract
  exit 0
}

if (-not $OptInArtifactReadback) {
  $contract.status = "production_ready_blocked"
  $contract.blocker = "missing_opt_in"
  $contract.artifact_read = $false
  $contract.closure_audit = New-ClosureAudit -ArtifactAcceptanceState "production_ready_blocked" -Blocker "missing_opt_in" -ArtifactRead $false
  $contract.watcher_checklist = New-WatcherChecklist -CurrentStatus "production_ready_blocked" -Blocker "missing_opt_in"
  ConvertTo-SafeJson $contract
  exit 0
}

if (-not (Test-BoundedArtifactPath -Path $ArtifactPath)) {
  $contract.status = "production_ready_blocked"
  $contract.blocker = "unsafe_artifact_path"
  $contract.artifact_read = $false
  $contract.closure_audit = New-ClosureAudit -ArtifactAcceptanceState "production_ready_blocked" -Blocker "unsafe_artifact_path" -ArtifactRead $false
  $contract.watcher_checklist = New-WatcherChecklist -CurrentStatus "production_ready_blocked" -Blocker "unsafe_artifact_path"
  ConvertTo-SafeJson $contract
  exit 0
}

$resolvedArtifact = Join-Path $repoRoot $ArtifactPath
if (-not (Test-Path $resolvedArtifact)) {
  $contract.status = "production_ready_blocked"
  $contract.blocker = "missing_backend"
  $contract.artifact_read = $false
  $contract.closure_audit = New-ClosureAudit -ArtifactAcceptanceState "production_ready_blocked" -Blocker "missing_backend" -ArtifactRead $false
  $contract.watcher_checklist = New-WatcherChecklist -CurrentStatus "production_ready_blocked" -Blocker "missing_backend" -ArtifactExists $false
  ConvertTo-SafeJson $contract
  exit 0
}

$artifact = Get-Content -Raw $resolvedArtifact | ConvertFrom-Json
$blocker = Classify-Artifact -Artifact $artifact
$contract.artifact_read = $true
$contract.artifact_path_scope = "tests/fixtures/gateway or .tmp/gateway_tpm_production_backend"
$contract.acceptance_schema = $acceptanceSchema
$contract.artifact_provenance_present = [bool]$artifact.artifact_provenance
$contract.runner_provenance_present = [bool]$artifact.runner_provenance
$contract.runner_command_provenance_present = [bool]$artifact.runner_command_provenance
$contract.backend_kind = [string]$artifact.backend_kind
$contract.backend_source_present = [bool]$artifact.backend_source
$contract.token_source_kind = [string]$artifact.token_source_kind
$contract.token_count = $artifact.token_count
$contract.duration_ms = $artifact.duration_ms
$contract.latency_ms = $artifact.latency_ms
$contract.gateway_live_smoke_status = [string]$artifact.gateway_live_smoke_status
$contract.current_commit_present = -not [string]::IsNullOrWhiteSpace([string]$artifact.current_commit)
$contract.generated_at_present = -not [string]::IsNullOrWhiteSpace([string]$artifact.generated_at)
$contract.reservation_capacity_projection_present = [bool]$artifact.reservation_capacity_projection
$contract.db_acquire_evidence_present = [bool]$artifact.db_acquire_evidence
$contract.db_acquire_result_present = [bool]$artifact.db_acquire_result
$contract.db_acquire_readback_count_present = $null -ne $artifact.db_acquire_readback_count
$contract.db_result_readback_count_present = $null -ne $artifact.db_result_readback_count
$contract.raw_value_omitted = -not [bool]$artifact.raw_material_present
$contract.simulation_can_close_final_gap = [bool]$artifact.simulation_can_close_final_gap
$contract.local_prototype = [bool]$artifact.local_prototype
$contract.real_operator_evidence = -not [bool]$artifact.external_artifact_simulation -and -not [bool]$artifact.simulated_runner -and -not [bool]$artifact.repo_fixture_only -and -not [bool]$artifact.local_prototype

if ($null -eq $blocker) {
  if ($artifact.external_artifact_simulation -eq $true -or $artifact.local_prototype -eq $true -or $artifact.simulation_can_close_final_gap -eq $false) {
    $contract.status = "production_evidence_accepted_for_review"
    $contract.blocker = $null
    $contract.review_required = $true
    $contract.final_gap_closure_allowed = $false
    $contract.closure_audit = New-ClosureAudit -ArtifactAcceptanceState "production_evidence_accepted_for_review" -Artifact $artifact -ArtifactRead $true -FinalEligible $false
    $contract.watcher_checklist = New-WatcherChecklist -CurrentStatus "production_evidence_accepted_for_review" -ArtifactAcceptanceState "production_evidence_accepted_for_review" -ArtifactRead $true -ArtifactExists $true -FinalEligible $false
  } else {
    $contract.status = "production_backend_live_smoke_passed"
    $contract.blocker = $null
    $contract.review_required = $true
    $contract.final_gap_closure_allowed = $true
    $contract.closure_audit = New-ClosureAudit -ArtifactAcceptanceState "production_backend_live_smoke_passed" -Artifact $artifact -ArtifactRead $true -FinalEligible $true
    $contract.watcher_checklist = New-WatcherChecklist -CurrentStatus "production_backend_live_smoke_passed" -ArtifactAcceptanceState "production_backend_live_smoke_passed" -ArtifactRead $true -ArtifactExists $true -FinalEligible $true
  }
} else {
  $contract.status = "production_ready_blocked"
  $contract.blocker = $blocker
  $contract.final_gap_closure_allowed = $false
  $contract.closure_audit = New-ClosureAudit -ArtifactAcceptanceState "production_ready_blocked" -Blocker $blocker -Artifact $artifact -ArtifactRead $true -FinalEligible $false
  $contract.watcher_checklist = New-WatcherChecklist -CurrentStatus "production_ready_blocked" -Blocker $blocker -ArtifactAcceptanceState "production_ready_blocked" -ArtifactRead $true -ArtifactExists $true -FinalEligible $false
}

ConvertTo-SafeJson $contract
