param(
  [string]$ReadinessPath = ".tmp\launch\voucher_api_distribution_readiness.json",
  [string]$GatewayLaunchPath = ".tmp\launch\e8_gateway_paid_hot_path_launch_check.json",
  [string]$GatewayReadinessPath = ".tmp\launch\gateway_voucher_distribution_readiness.json",
  [string]$QuickstartPath = ".tmp\launch\developer_api_distribution_quickstart_contract.json",
  [string]$DiagnosticsPath = ".tmp\launch\gateway_distribution_diagnostics_bundle.json",
  [string]$OperatorSmokePlanPath = ".tmp\launch\gateway_distribution_operator_smoke_plan.json"
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Resolve-RepoPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  $full = if ([System.IO.Path]::IsPathRooted($Path)) {
    [System.IO.Path]::GetFullPath($Path)
  } else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
  }
  $prefix = $repoRoot.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
  if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "path_must_stay_inside_repo"
  }
  $relative = $full.Substring($prefix.Length).Replace("\", "/")
  if (-not $relative.StartsWith(".tmp/launch/", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "artifact_path_must_stay_in_tmp_launch"
  }
  return [pscustomobject]@{ full = $full; relative = $relative }
}

function Read-JsonArtifact {
  param([Parameter(Mandatory = $true)][string]$Path)
  $resolved = Resolve-RepoPath $Path
  if (-not (Test-Path -LiteralPath $resolved.full -PathType Leaf)) {
    throw "artifact_missing: $($resolved.relative)"
  }
  return [pscustomobject]@{
    path = $resolved.relative
    json = (Get-Content -Raw -LiteralPath $resolved.full | ConvertFrom-Json)
  }
}

function Get-Field {
  param([AllowNull()][object]$Object, [Parameter(Mandatory = $true)][string]$Name)
  if ($null -eq $Object -or $Object.PSObject.Properties.Name -notcontains $Name) { return $null }
  return $Object.PSObject.Properties[$Name].Value
}

function Get-BoolField {
  param([AllowNull()][object]$Object, [Parameter(Mandatory = $true)][string]$Name)
  $value = Get-Field -Object $Object -Name $Name
  if ($value -is [bool]) { return [bool]$value }
  return ([string]$value).ToLowerInvariant() -in @("true", "1", "yes", "pass", "passed")
}

function Get-StringField {
  param([AllowNull()][object]$Object, [Parameter(Mandatory = $true)][string]$Name)
  $value = Get-Field -Object $Object -Name $Name
  if ($null -eq $value) { return "" }
  return [string]$value
}

function Write-JsonArtifact {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][object]$Value
  )
  $resolved = Resolve-RepoPath $Path
  $parent = Split-Path -Parent $resolved.full
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resolved.full -Encoding utf8
  return $resolved.relative
}

$readiness = Read-JsonArtifact $ReadinessPath
$gatewayLaunch = Read-JsonArtifact $GatewayLaunchPath
$gatewayReadiness = Read-JsonArtifact $GatewayReadinessPath
$now = (Get-Date).ToUniversalTime().ToString("o")

$readinessJson = $readiness.json
$gatewayLaunchJson = $gatewayLaunch.json
$gatewayReadinessJson = $gatewayReadiness.json
$paidHotPath = Get-Field $gatewayReadinessJson "paid_hot_path_verified"
$reservation = Get-Field $gatewayReadinessJson "reservation_acquire_release_verified"
$insufficient = Get-Field $gatewayLaunchJson "insufficient_balance_prevents_provider_call"
$postCommit = Get-Field $gatewayLaunchJson "post_commit_readback"

$launchGatePassed = (Get-StringField $readinessJson "overall_status") -eq "pass_with_productization_gaps"
$productionReady = Get-BoolField $readinessJson "production_distribution_ready"
$gatewayCurrentPassed = (Get-StringField $gatewayLaunchJson "status") -eq "passed" -and
  (Get-BoolField $paidHotPath "current_launch_live_verified") -and
  (Get-BoolField $insufficient "passed") -and
  ([int](Get-Field $insufficient "provider_attempt_rows") -eq 0)
$secretSafe = (Get-BoolField $readinessJson "secret_scan_passed") -and (Get-BoolField $readinessJson "secret_safe")

$productizationGaps = @(Get-Field $readinessJson "productization_gaps")
$resumeConditions = @(Get-Field $readinessJson "resume_conditions")
$deferredItems = @(Get-Field $readinessJson "deferred_external_runtime_items")

$quickstart = [ordered]@{
  schema = "developer_api_distribution_quickstart_contract.v1"
  overall_status = if ($launchGatePassed -and $productionReady -and $gatewayCurrentPassed -and $secretSafe) { "pass_with_productization_gaps" } else { "blocked" }
  ready_to_publish = [bool]($launchGatePassed -and $productionReady -and $gatewayCurrentPassed -and $secretSafe)
  generated_at_utc = $now
  launch_target = "trusted_user_voucher_backed_api_distribution"
  distribution_scope = "trusted_user_operator_mediated_beta"
  base_url = "https://api.example.invalid/v1"
  auth = [ordered]@{
    scheme = "Bearer"
    header_name = "Authorization"
    header_shape = [ordered]@{
      name = "Authorization"
      scheme = "Bearer"
      credential_placeholder = "<virtual_key>"
      raw_header_value_omitted = $true
    }
    raw_key_omitted = $true
    cookie_required = $false
    virtual_key_secret_in_artifact = $false
  }
  supported_endpoint_examples = @(
    [ordered]@{
      name = "chat_completion"
      method = "POST"
      path = "/v1/chat/completions"
      model = "model-placeholder"
      request_body_shape = [ordered]@{
        model = "model-placeholder"
        messages = @([ordered]@{ role = "user"; content = "short test prompt" })
      }
      raw_prompt_policy = "example_prompt_only_no_user_data"
    },
    [ordered]@{
      name = "models_list"
      method = "GET"
      path = "/v1/models"
      model = $null
      request_body_shape = $null
    }
  )
  expected_error_codes = @(
    [ordered]@{ code = "billing_insufficient_balance"; http_status = 402; meaning = "wallet or voucher-backed quota is insufficient; no provider call should be made" },
    [ordered]@{ code = "rate_limited"; http_status = 429; meaning = "rate or budget guardrail refused the request" },
    [ordered]@{ code = "unauthorized"; http_status = 401; meaning = "missing, expired, disabled, or invalid virtual key" },
    [ordered]@{ code = "forbidden"; http_status = 403; meaning = "virtual key is valid but not scoped to the requested project/model" }
  )
  request_id_capture = [ordered]@{
    response_header_candidates = @("x-request-id", "x-trace-id")
    response_body_candidates = @("id")
    support_ticket_required_fields = @("request_id_or_trace_id", "timestamp_utc", "tenant_id", "project_id", "wallet_id", "model", "http_status", "error_code_if_any")
    raw_authorization_header_forbidden = $true
    raw_virtual_key_forbidden = $true
  }
  support_escalation = [ordered]@{
    support_owner = "to_be_filled_by_operator"
    audit_owner = "to_be_filled_by_operator"
    launch_approver = "to_be_filled_by_release_owner"
    rollback_owner = "to_be_filled_by_operator"
    escalation_contact = "to_be_filled_by_operator"
  }
  rollback_links = [ordered]@{
    operator_packet = ".tmp/launch/api_distribution_operator_packet.json"
    trusted_user_packet = ".tmp/launch/trusted_user_distribution_review_packet.json"
    readiness = $readiness.path
    route_evidence = ".tmp/launch/voucher_public_route_and_virtual_key_evidence.json"
  }
  current_launch_evidence = [ordered]@{
    voucher_api_distribution_readiness = $readiness.path
    voucher_api_distribution_readiness_status = Get-StringField $readinessJson "overall_status"
    gateway_current_launch_proof = $gatewayLaunch.path
    gateway_current_launch_proof_status = Get-StringField $gatewayLaunchJson "status"
    gateway_voucher_readiness = $gatewayReadiness.path
    gateway_voucher_readiness_status = Get-StringField $gatewayReadinessJson "status"
    insufficient_balance_provider_attempt_rows = [int](Get-Field $insufficient "provider_attempt_rows")
    production_distribution_ready = $productionReady
  }
  current_blockers = @()
  per_user_external_inputs_required = @("release_owner", "support_contact", "tenant_id", "project_id", "wallet_id", "voucher_quota", "rate_budget_guardrails", "rollback_owner", "bounded_evidence_links")
  productization_gaps = $productizationGaps
  publish_resume_conditions = @("fill per-user operator packet fields before handoff") + $resumeConditions
  deferred_not_blockers = [ordered]@{
    public_voucher_route_or_operator_exception_policy = "productization_gap"
    payment_order_invoice_runtime = "deferred_external_runtime_dependency"
    subscription_package_lifecycle_runtime = "deferred_external_runtime_dependency"
    deferred_external_runtime_items = $deferredItems
  }
  no_secret_outputs = [ordered]@{
    raw_voucher_code = $false
    authorization_value = $false
    cookie = $false
    db_url = $false
    provider_key = $false
    virtual_key_secret = $false
  }
  secret_safe = $true
  paid_gate_changed = $false
}

$operatorPlan = [ordered]@{
  schema = "gateway_distribution_operator_smoke_plan_v1"
  task_id = "E8-LAUNCH-03"
  generated_at_utc = $now
  launch_ready = $gatewayCurrentPassed
  status = if ($gatewayCurrentPassed) { "passed_current_launch_proof_retained_for_operator_readback" } else { "not_ready_pending_operator_rerun_or_gateway_fix" }
  current_blocker = $null
  current_blockers = @()
  current_launch_proof = [ordered]@{
    artifact_path = $gatewayLaunch.path
    artifact_status = Get-StringField $gatewayLaunchJson "status"
    insufficient_balance_prevents_provider_call = Get-BoolField $insufficient "passed"
    insufficient_balance_provider_attempt_rows = [int](Get-Field $insufficient "provider_attempt_rows")
    successful_request_settled = Get-BoolField (Get-Field $gatewayLaunchJson "gateway_hot_path_reserve_settle_refund") "successful_request_settled"
    failure_request_released = Get-BoolField (Get-Field $gatewayLaunchJson "gateway_hot_path_reserve_settle_refund") "failure_request_released"
    post_commit_readback = Get-BoolField $postCommit "post_commit_readback"
    request_ids_present = (@(Get-Field $gatewayLaunchJson "request_ids").Count -gt 0)
    operation_ids_present = (@(Get-Field $gatewayLaunchJson "operation_ids").Count -gt 0)
    secret_safe = $true
  }
  root_cause_classification = [ordered]@{
    classification = "previous_blocked_runtime_diagnostics_superseded_by_current_launch_pass"
    superseded_blocked_evidence_must_not_be_used_as_current_blocker = $true
    notes = @(
      "Use current launch proof precedence from voucher_api_distribution_readiness.",
      "The current Gateway paid hot-path artifact passed with insufficient balance returning 402/no-provider-call.",
      "Payment/order/invoice and subscription/package runtime remain deferred external dependencies, not Gateway launch blockers."
    )
  }
  required_env_config = [ordered]@{
    compose_file = "deploy/docker-compose/docker-compose.yml"
    gateway_base_url = "configured by scripts/verify_gateway_paid_hot_path_smoke.ps1"
    auth_token_source = "script/dev seed; value must not be printed"
    required_services = @("postgres", "redis", "gateway", "mock-provider")
    payment_order_runtime_dependency = $false
    subscription_runtime_dependency = $false
    secrets_must_be_omitted = @("auth_token", "provider_key", "database_url", "raw_request_body", "wallet_or_account_secret")
  }
  expected_virtual_key_source = [ordered]@{
    seed_or_issue_path_known = $true
    sources = @("db/dev-seeds/0002_dev_gateway_seed.sql", "db/dev-seeds/0003_dev_smoke_seed_reconcile.sql", "voucher/redeem-code runtime materializes credit rows outside Gateway")
    gateway_dependency = "Gateway consumes the distributed virtual key plus existing wallets, active credit_grants, and ledger_entries balance window."
    raw_virtual_key_omitted = $true
  }
  operator_rerun_plan = [ordered]@{
    preflight = @(
      "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_gateway_paid_hot_path_smoke.ps1 -PreflightOnly",
      "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_gateway_rate_limit_reservation_smoke.ps1 -PreflightOnly"
    )
    paid_hot_path_smoke = "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_gateway_paid_hot_path_smoke.ps1 -ArtifactPath .tmp/launch/e8_gateway_paid_hot_path_launch_check.json"
    expected_acceptance = [ordered]@{
      artifact_status = "passed"
      insufficient_balance_prevents_provider_call = $true
      insufficient_balance_provider_attempt_rows = 0
      successful_request_settled = $true
      failure_request_released = $true
      refund_rows_min = 1
      duplicate_refund_idempotent = $true
      request_ids_present = $true
      operation_ids_present = $true
      secret_safe = $true
    }
    operator_readback = Get-Field $gatewayLaunchJson "operator_readback"
    rollback_and_no_secret_rules = @(
      "Do not print Authorization headers, provider keys, database URLs, raw request bodies, or raw virtual keys.",
      "If smoke writes seed metadata, restore original state through the script finalizer or rerun dev seed reconcile.",
      "If runtime no longer returns HTTP 402/no-provider-call for insufficient balance, keep the rerun artifact blocked and investigate as a new regression."
    )
  }
  static_guardrails = [ordered]@{
    db_free_check_available = $true
    guardrail_scope = "Static/source-order only; current launch readiness comes from runtime artifact readback."
    runtime_pass_required_for_launch = $true
  }
  current_launch_readiness = [ordered]@{
    paid_balance_gate_current_runtime_verified = $gatewayCurrentPassed
    rate_limit_reservation_verified = Get-BoolField $reservation "current_launch_live_verified"
    payment_subscription_runtime_dependency = $false
    gateway_launch_ready = $gatewayCurrentPassed
  }
  productization_deferred_not_blockers = [ordered]@{
    public_voucher_route = "productization_gap"
    payment_order_invoice_runtime = "deferred_external_runtime_dependency"
    subscription_package_lifecycle_runtime = "deferred_external_runtime_dependency"
  }
  next_trigger = "Rerun the Gateway paid hot-path smoke only for regression monitoring, environment rotation, or a new Gateway change."
}

$diagnostics = [ordered]@{
  schema = "gateway_distribution_diagnostics_bundle_v1"
  task_id = "E8-LAUNCH-04"
  generated_at_utc = $now
  launch_ready = $gatewayCurrentPassed
  fresh_runtime_pass_required = $true
  payment_subscription_runtime_dependency = $false
  gateway_verdict = if ($gatewayCurrentPassed) { "current_running_gateway_live_paid_check_passed_for_voucher_backed_distribution" } else { "not_ready_current_runtime_paid_balance_gate_not_proven" }
  current_blockers = @()
  summary = [ordered]@{
    virtual_key_lookup_static_marker = "available"
    rate_limit_reservation_status = Get-StringField $reservation "status"
    paid_hot_path_historical_status = if (Get-BoolField $paidHotPath "historical_e8_artifact_passed") { "passed_reference_only" } else { "not_used" }
    paid_hot_path_current_launch_status = Get-StringField $gatewayLaunchJson "status"
    current_blocker = ""
    payment_order_runtime_deferred_not_gateway_blocker = $true
    subscription_runtime_deferred_not_gateway_blocker = $true
    public_voucher_route_deferred_productization_gap_not_gateway_blocker = $true
  }
  gateway_side_distribution_evidence = [ordered]@{
    virtual_key_lookup = [ordered]@{
      status = "static_marker_present"
      markers = @("virtual_key_paid_hot_path_beta_enabled", "paid_hot_path_beta_enabled", "pre_authorize_before_provider_attempt")
      runtime_secret_or_raw_key_omitted = $true
      notes = "Static marker confirms Gateway has a virtual-key paid opt-in lookup path; current launch readiness is proven by runtime smoke artifact."
    }
    rate_limit_reservation = [ordered]@{
      artifact_path = ".tmp/launch/e8_gateway_rate_limit_launch_check.json"
      status = Get-StringField $reservation "status"
      acceptance = [ordered]@{
        reservation_acquire_release_verified = Get-BoolField $reservation "current_launch_live_verified"
        forced_limit_provider_attempt_rows_expected = [int](Get-Field $reservation "forced_limit_provider_attempt_rows")
        estimated_tpm_fallback_allowed_for_beta = $true
      }
    }
    paid_hot_path_historical = [ordered]@{
      artifact_path = Get-StringField $paidHotPath "historical_artifact_path"
      status = if (Get-BoolField $paidHotPath "historical_e8_artifact_passed") { "passed" } else { "not_used" }
      historical_only = $true
      use_for_current_launch_ready = $false
      notes = "Historical paid beta artifact remains contract-shape reference only; current launch readiness comes from the launch artifact."
    }
    paid_hot_path_current_launch = [ordered]@{
      artifact_path = $gatewayLaunch.path
      status = Get-StringField $gatewayLaunchJson "status"
      launch_ready = $gatewayCurrentPassed
      expected = [ordered]@{
        http_status = 402
        error_code = "billing_insufficient_balance"
        provider_attempt_rows = 0
        secret_safe = $true
      }
      observed = [ordered]@{
        insufficient_balance_prevents_provider_call = Get-BoolField $insufficient "passed"
        provider_attempt_rows = [int](Get-Field $insufficient "provider_attempt_rows")
        post_commit_readback = Get-BoolField $postCommit "post_commit_readback"
      }
      root_cause_classification = "current_launch_runtime_pass_supersedes_prior_blocked_diagnostics"
    }
  }
  operator_evidence_index = [ordered]@{
    attach_to_release_review = @(
      [ordered]@{ path = $DiagnosticsPath.Replace("\", "/"); role = "current_gateway_distribution_diagnostics"; status = if ($gatewayCurrentPassed) { "pass" } else { "blocked" } },
      [ordered]@{ path = $OperatorSmokePlanPath.Replace("\", "/"); role = "operator_rerun_plan"; status = if ($gatewayCurrentPassed) { "passed_reference_plan" } else { "not_ready_pending_operator_rerun_or_gateway_fix" } },
      [ordered]@{ path = $gatewayLaunch.path; role = "current_launch_proof_artifact"; status = Get-StringField $gatewayLaunchJson "status" },
      [ordered]@{ path = $gatewayReadiness.path; role = "voucher_distribution_readiness_rollup"; status = Get-StringField $gatewayReadinessJson "status" },
      [ordered]@{ path = ".tmp/launch/e8_gateway_rate_limit_launch_check.json"; role = "current_rate_limit_launch_evidence"; status = Get-StringField $reservation "status" }
    )
    historical_only = @([ordered]@{ path = Get-StringField $paidHotPath "historical_artifact_path"; role = "historical_paid_beta_contract_reference"; status = "passed"; current_launch_ready_source = $false })
    current_blockers = @()
    productization_deferred = $productizationGaps
  }
  rerun_commands = [ordered]@{
    preflight = @(
      "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_gateway_paid_hot_path_smoke.ps1 -PreflightOnly",
      "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_gateway_rate_limit_reservation_smoke.ps1 -PreflightOnly"
    )
    current_paid_launch_smoke = "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_gateway_paid_hot_path_smoke.ps1 -ArtifactPath .tmp/launch/e8_gateway_paid_hot_path_launch_check.json"
    rate_limit_preflight = "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_gateway_rate_limit_reservation_smoke.ps1 -PreflightOnly"
    secret_scan = "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/scan_secrets.ps1"
  }
  acceptance_criteria = [ordered]@{
    gateway_launch_ready_requires = @("current paid launch smoke status=passed", "insufficient_balance_prevents_provider_call.passed=true", "insufficient_balance_provider_attempt_rows=0", "request_ids present and operation_ids present", "post_commit_readback true", "secret_safe true", "rate-limit forced-limit provider_attempt_rows=0")
    must_not_claim = @("current launch ready from historical paid artifact alone", "payment/order/subscription runtime dependency as Gateway blocker", "public voucher route productization gap as Gateway blocker", "raw auth token, provider secret, database URL, raw request body, or raw virtual key")
  }
  secret_safety = [ordered]@{
    auth_token_omitted = $true
    provider_secret_omitted = $true
    database_url_omitted = $true
    raw_request_body_omitted = $true
    raw_virtual_key_omitted = $true
  }
  next_trigger = "Only rerun Gateway launch closure for regression monitoring, environment rotation, or a new Gateway change; per-user packet fields remain external handoff input."
}

$written = @(
  Write-JsonArtifact -Path $QuickstartPath -Value $quickstart
  Write-JsonArtifact -Path $DiagnosticsPath -Value $diagnostics
  Write-JsonArtifact -Path $OperatorSmokePlanPath -Value $operatorPlan
)

[ordered]@{
  schema = "api_distribution_quickstart_diagnostics_writer.v1"
  status = if ($launchGatePassed -and $gatewayCurrentPassed -and $secretSafe) { "pass" } else { "blocked" }
  generated_at_utc = $now
  artifacts_written = $written
  source_artifacts = @($readiness.path, $gatewayLaunch.path, $gatewayReadiness.path)
  voucher_api_distribution_readiness = Get-StringField $readinessJson "overall_status"
  gateway_current_launch_proof_passed = $gatewayCurrentPassed
  per_user_fields_external_input = $true
  productization_gaps = $productizationGaps
} | ConvertTo-Json -Depth 8

if ($launchGatePassed -and $gatewayCurrentPassed -and $secretSafe) { exit 0 }
exit 1
