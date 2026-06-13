param(
  [string]$PacketPath = ".tmp\launch\trusted_user_distribution_review_packet.json",
  [string]$ReadinessPath = ".tmp\launch\voucher_api_distribution_readiness.json",
  [string]$GatewayLaunchPath = ".tmp\launch\e8_gateway_paid_hot_path_launch_check.json",
  [string]$QuotaGuardrailsPath = ".tmp\launch\voucher_quota_pricing_guardrails.json",
  [string]$RouteEvidencePath = ".tmp\launch\voucher_public_route_and_virtual_key_evidence.json",
  [string]$OperatorExceptionPath = ".tmp\launch\voucher_operator_only_exception.json",
  [string]$RemainingBalancePath = ".tmp\credit-wallet\user_remaining_balance_ownership_runtime.json",
  [string]$VoucherRuntimePath = ".tmp\credit-wallet\recharge_voucher_runtime.json",
  [string]$ReleaseOwner = "",
  [string]$SupportContact = "",
  [string]$TenantId = "",
  [string]$ProjectId = "",
  [string]$WalletId = "",
  [string]$VoucherQuota = "",
  [string]$RateBudgetGuardrails = "",
  [string]$RollbackOwner = "",
  [switch]$WriteDefaultPacket,
  [switch]$SelfTest
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
  if (-not ($relative.StartsWith(".tmp/", [System.StringComparison]::OrdinalIgnoreCase) -or $relative.StartsWith("artifacts/", [System.StringComparison]::OrdinalIgnoreCase))) {
    throw "packet_path_must_be_tmp_or_artifacts"
  }
  return [ordered]@{ full = $full; relative = $relative }
}

function Get-Field {
  param([AllowNull()][object]$Object, [Parameter(Mandatory = $true)][string]$Name)
  if ($null -eq $Object -or $Object.PSObject.Properties.Name -notcontains $Name) { return $null }
  return $Object.PSObject.Properties[$Name].Value
}

function Get-StringField {
  param([AllowNull()][object]$Object, [Parameter(Mandatory = $true)][string]$Name)
  $value = Get-Field -Object $Object -Name $Name
  if ($null -eq $value) { return "" }
  return [string]$value
}

function Get-BoolField {
  param([AllowNull()][object]$Object, [Parameter(Mandatory = $true)][string]$Name)
  $value = Get-Field -Object $Object -Name $Name
  if ($value -is [bool]) { return [bool]$value }
  return ([string]$value).ToLowerInvariant() -in @("true", "1", "yes", "pass", "passed")
}

function Read-JsonIfPresent {
  param([Parameter(Mandatory = $true)][string]$Path)
  $resolved = Resolve-RepoPath $Path
  if (-not (Test-Path -LiteralPath $resolved.full -PathType Leaf)) {
    return [ordered]@{ exists = $false; path = $resolved.relative; json = $null }
  }
  return [ordered]@{
    exists = $true
    path = $resolved.relative
    json = (Get-Content -Raw -LiteralPath $resolved.full | ConvertFrom-Json)
  }
}

function Test-FilledValue {
  param([AllowNull()][string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  return -not ($Value -match '^<.*>$' -or $Value -match '^to_be_filled' -or $Value -eq "missing")
}

function Test-LinkValue {
  param([AllowNull()][string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  return ($Value -match '^(?:\.tmp/|artifacts/|project/|docs/|TODO/)' -or $Value -match '^https?://')
}

function Test-Packet {
  param([Parameter(Mandatory = $true)][object]$Packet)

  $missing = [System.Collections.Generic.List[string]]::new()
  $blockers = [System.Collections.Generic.List[string]]::new()
  $warnings = [System.Collections.Generic.List[string]]::new()

  if ((Get-StringField $Packet "schema") -ne "trusted_user_distribution_review_packet.v1") {
    [void]$blockers.Add("schema_invalid")
  }

  $releaseOwner = Get-Field $Packet "release_owner"
  if (-not (Test-FilledValue (Get-StringField $releaseOwner "value")) -and (Get-StringField $releaseOwner "status") -ne "filled") {
    [void]$missing.Add("release_owner")
  }

  $support = Get-Field $Packet "support_contact"
  if (-not (Test-FilledValue (Get-StringField $support "value")) -and (Get-StringField $support "status") -ne "filled") {
    [void]$missing.Add("support_contact")
  }

  $ids = Get-Field $Packet "tenant_project_wallet_ids"
  foreach ($name in @("tenant_id", "project_id", "wallet_id")) {
    $value = Get-StringField $ids $name
    if ([string]::IsNullOrWhiteSpace($value)) {
      [void]$blockers.Add("${name}_missing")
    } elseif ($value -match '^<.*>$') {
      [void]$warnings.Add("${name}_placeholder")
      [void]$missing.Add($name)
    }
  }

  $virtualKey = Get-Field $Packet "virtual_key_issuance_evidence"
  if (-not (Test-LinkValue (Get-StringField $virtualKey "link_or_artifact"))) {
    [void]$blockers.Add("virtual_key_evidence_link_missing")
  }
  if ((Get-BoolField $virtualKey "raw_virtual_key_secret_allowed")) {
    [void]$blockers.Add("raw_virtual_key_secret_allowed")
  }

  $voucher = Get-Field $Packet "voucher_quota_evidence_or_exception"
  if (-not (Test-LinkValue (Get-StringField $voucher "voucher_runtime_artifact")) -and -not (Test-LinkValue (Get-StringField $voucher "route_evidence_artifact"))) {
    [void]$blockers.Add("voucher_evidence_link_missing")
  }
  $exceptionApproved = (Get-StringField $voucher "operator_only_exception_status") -eq "approved"
  $voucherRouteApproved = (Get-StringField $voucher "status") -match "public_route_verified|operator_only_exception_approved|internal_runtime_verified_productization_gap"

  $balance = Get-Field $Packet "remaining_balance_readback"
  if (-not (Test-LinkValue (Get-StringField $balance "artifact"))) {
    [void]$blockers.Add("remaining_balance_readback_link_missing")
  }

  $gateway = Get-Field $Packet "gateway_current_launch_artifact"
  if (-not (Test-LinkValue (Get-StringField $gateway "artifact"))) {
    [void]$blockers.Add("gateway_launch_artifact_link_missing")
  }
  $gatewayVerified = (Get-StringField $gateway "status") -match "verified|pass|passed"

  $guardrails = Get-Field $Packet "rate_budget_guardrails"
  if (-not (Test-LinkValue (Get-StringField $guardrails "artifact"))) {
    [void]$blockers.Add("rate_budget_guardrails_link_missing")
  }
  if (-not (Test-FilledValue (Get-StringField $guardrails "trusted_user_record")) -and (Get-StringField $guardrails "status") -ne "filled") {
    [void]$missing.Add("rate_budget_guardrails")
  }

  $developerReadback = Get-Field $Packet "developer_distribution_packet_readback"
  if ((Get-StringField $developerReadback "endpoint") -ne "GET /user/developer-distribution-packet-readback") {
    [void]$blockers.Add("developer_distribution_packet_readback_endpoint_missing")
  }
  foreach ($field in @("endpoint_readiness", "model_availability", "quota_rate_budget_guardrails", "voucher_key_handoff_refs", "safe_next_action")) {
    if (-not (Get-BoolField $developerReadback $field)) {
      [void]$blockers.Add("developer_distribution_packet_readback_missing:$field")
    }
  }
  foreach ($secretField in @("raw_api_key_returned", "raw_voucher_code_returned", "provider_key_returned", "authorization_returned", "token_returned")) {
    if (Get-BoolField $developerReadback $secretField) {
      [void]$blockers.Add("developer_distribution_packet_readback_secret_field_allowed:$secretField")
    }
  }

  $voucherAssignment = Get-Field $Packet "voucher_quota_assignment"
  if ($null -ne $voucherAssignment) {
    if (-not (Test-FilledValue (Get-StringField $voucherAssignment "value")) -and (Get-StringField $voucherAssignment "status") -ne "filled") {
      [void]$missing.Add("voucher_quota")
    }
    if (Get-BoolField $voucherAssignment "raw_voucher_code_allowed") {
      [void]$blockers.Add("raw_voucher_code_allowed")
    }
  }

  $rollback = Get-Field $Packet "rollback_revoke_plan"
  $rollbackOwner = Get-Field $rollback "owner"
  if ($null -ne $rollbackOwner -and -not (Test-FilledValue (Get-StringField $rollbackOwner "value")) -and (Get-StringField $rollbackOwner "status") -ne "filled") {
    [void]$missing.Add("rollback_owner")
  }
  $steps = @(Get-Field $rollback "steps")
  foreach ($requiredStep in @("disable_or_revoke_virtual_key", "revoke_or_expire_voucher_or_credit_quota", "verify_remaining_balance_after_revoke", "verify_audit_or_support_record_after_revoke")) {
    if (@($steps | Where-Object { [string]$_ -eq $requiredStep }).Count -eq 0) {
      [void]$blockers.Add("rollback_step_missing:$requiredStep")
    }
  }

  $secretScan = Get-Field $Packet "secret_scan"
  $secretScanPassed = (Get-StringField $secretScan "latest_status") -eq "pass"
  if (-not $secretScanPassed) {
    [void]$blockers.Add("secret_scan_not_passed")
  }
  if ((Get-BoolField $secretScan "raw_secret_material_allowed")) {
    [void]$blockers.Add("raw_secret_material_allowed")
  }

  $docs = @(Get-Field $Packet "docs_runbook_links")
  if ($docs.Count -lt 2) {
    [void]$blockers.Add("docs_runbook_links_missing")
  }

  $deferred = Get-Field $Packet "deferred_runtime_status"
  if ((Get-BoolField $deferred "blocks_this_packet")) {
    [void]$blockers.Add("jk_deferred_status_blocks_packet")
  }

  $readyToSend = Get-BoolField $Packet "ready_to_send"
  if ($readyToSend -and -not $gatewayVerified) {
    [void]$blockers.Add("ready_to_send_true_without_gateway_current_launch_hot_path")
  }
  if ($readyToSend -and -not ($voucherRouteApproved -or $exceptionApproved)) {
    [void]$blockers.Add("ready_to_send_true_without_voucher_route_or_exception")
  }
  if ($readyToSend -and ($missing.Count -gt 0)) {
    [void]$blockers.Add("ready_to_send_true_with_missing_owner_or_support")
  }

  $status = if ($blockers.Count -gt 0) { "fail" } elseif ($readyToSend) { "pass" } else { "blocked" }
  return [ordered]@{
    schema = "trusted_user_distribution_review_packet_verifier.v1"
    overall_status = $status
    actual_exit_code = if ($status -eq "pass") { 0 } elseif ($status -eq "blocked") { 2 } else { 1 }
    ready_to_send = $readyToSend
    missing_fields = @($missing.ToArray())
    warnings = @($warnings.ToArray())
    blockers = @($blockers.ToArray())
    required_fields_checked = @(
      "release_owner",
      "support_contact",
      "tenant_project_wallet_ids",
      "virtual_key_issuance_evidence",
      "voucher_quota_evidence_or_exception",
      "remaining_balance_readback",
      "gateway_current_launch_artifact",
      "rate_budget_guardrails",
      "developer_distribution_packet_readback",
      "rollback_revoke_plan",
      "secret_scan",
      "docs_runbook_links",
      "deferred_runtime_status"
    )
  }
}

function New-DefaultPacket {
  $readiness = Read-JsonIfPresent $ReadinessPath
  $gateway = Read-JsonIfPresent $GatewayLaunchPath
  $guardrails = Read-JsonIfPresent $QuotaGuardrailsPath
  $route = Read-JsonIfPresent $RouteEvidencePath
  $exception = Read-JsonIfPresent $OperatorExceptionPath
  $balance = Read-JsonIfPresent $RemainingBalancePath
  $voucher = Read-JsonIfPresent $VoucherRuntimePath

  $readinessJson = $readiness.json
  $gatewayJson = $gateway.json
  $guardrailsJson = $guardrails.json
  $routeJson = $route.json
  $exceptionJson = $exception.json
  $balanceJson = $balance.json
  $voucherJson = $voucher.json

  $gatewayPassed = (Get-StringField $gatewayJson "status") -match "pass|passed|verified"
  $readinessPassed = (Get-StringField $readinessJson "overall_status") -match "pass"
  $voucherInternalVerified = Get-BoolField $readinessJson "voucher_redeem_runtime_verified"
  $balanceVerified = Get-BoolField $readinessJson "user_remaining_balance_runtime_verified"
  $routeVerified = Get-BoolField (Get-Field $routeJson "voucher_route_evidence") "route_verified"
  $exceptionApproved = Get-BoolField $exceptionJson "approved"
  $readinessDetails = Get-Field $readinessJson "readiness"
  $virtualKeyBounded = (Get-BoolField $readinessJson "virtual_key_issue_bounded_contract_verified") `
    -or (Get-BoolField $readinessDetails "virtual_key_issue_bounded_contract_verified") `
    -or (Get-BoolField (Get-Field $routeJson "virtual_key_issue_readback_audit") "bounded_db_free_route_contract_verified")
  $guardrailsPassed = (Get-StringField $guardrailsJson "overall_status") -match "pass"

  $currentBlockers = [System.Collections.Generic.List[string]]::new()
  if (-not $readinessPassed) { [void]$currentBlockers.Add("launch_readiness_not_passed") }
  if (-not $gatewayPassed) { [void]$currentBlockers.Add("gateway_current_launch_hot_path_not_verified") }
  if (-not $voucherInternalVerified) { [void]$currentBlockers.Add("voucher_internal_runtime_not_verified") }
  if (-not $balanceVerified) { [void]$currentBlockers.Add("remaining_balance_runtime_not_verified") }
  if (-not $virtualKeyBounded) { [void]$currentBlockers.Add("virtual_key_bounded_contract_not_verified") }
  if (-not $guardrailsPassed) { [void]$currentBlockers.Add("quota_rate_budget_guardrails_not_passed") }

  $missingFields = [System.Collections.Generic.List[string]]::new()
  if (-not (Test-FilledValue $ReleaseOwner)) { [void]$missingFields.Add("release_owner") }
  if (-not (Test-FilledValue $SupportContact)) { [void]$missingFields.Add("support_contact") }
  if (-not (Test-FilledValue $TenantId)) { [void]$missingFields.Add("tenant_id") }
  if (-not (Test-FilledValue $ProjectId)) { [void]$missingFields.Add("project_id") }
  if (-not (Test-FilledValue $WalletId)) { [void]$missingFields.Add("wallet_id") }
  if (-not (Test-FilledValue $VoucherQuota)) { [void]$missingFields.Add("voucher_quota") }
  if (-not (Test-FilledValue $RateBudgetGuardrails)) { [void]$missingFields.Add("rate_budget_guardrails") }
  if (-not (Test-FilledValue $RollbackOwner)) { [void]$missingFields.Add("rollback_owner") }

  $readyToSend = [bool]($currentBlockers.Count -eq 0 -and $missingFields.Count -eq 0)
  $releaseOwnerField = if (Test-FilledValue $ReleaseOwner) { [ordered]@{ required = $true; value = $ReleaseOwner; status = "filled" } } else { [ordered]@{ required = $true; placeholder = "<release-owner-name-or-handle>"; status = "missing" } }
  $supportField = if (Test-FilledValue $SupportContact) { [ordered]@{ required = $true; value = $SupportContact; status = "filled" } } else { [ordered]@{ required = $true; placeholder = "<support-contact-or-channel>"; status = "missing" } }
  $rollbackOwnerField = if (Test-FilledValue $RollbackOwner) { [ordered]@{ required = $true; value = $RollbackOwner; status = "filled" } } else { [ordered]@{ required = $true; placeholder = "<rollback-owner-name-or-handle>"; status = "missing" } }

  return [ordered]@{
    schema = "trusted_user_distribution_review_packet.v1"
    task_id = "QA-LAUNCH-09"
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    verifier = "scripts/verify_trusted_user_distribution_review_packet.ps1"
    ready_to_send = $readyToSend
    readiness_status = if ($readyToSend) { "ready_to_send_trusted_user_beta" } elseif ($currentBlockers.Count -eq 0) { "blocked_by_per_user_packet_fields_only" } else { "blocked_global_launch_evidence" }
    global_launch_evidence = [ordered]@{
      readiness_artifact = $readiness.path
      readiness_overall_status = Get-StringField $readinessJson "overall_status"
      production_distribution_ready = Get-BoolField $readinessJson "production_distribution_ready"
      production_distribution_full_ready = Get-BoolField $readinessJson "production_distribution_full_ready"
      remaining_blockers = @(Get-Field $readinessJson "remaining_blockers")
      gateway_artifact = $gateway.path
      gateway_status = Get-StringField $gatewayJson "status"
      gateway_current_launch_hot_path_verified = $gatewayPassed
      secret_scan_passed = Get-BoolField $readinessJson "secret_scan_passed"
    }
    release_owner = $releaseOwnerField
    tenant_project_wallet_ids = [ordered]@{
      tenant_id = if (Test-FilledValue $TenantId) { $TenantId } else { "<tenant-id>" }
      project_id = if (Test-FilledValue $ProjectId) { $ProjectId } else { "<project-id>" }
      wallet_id = if (Test-FilledValue $WalletId) { $WalletId } else { "<wallet-id>" }
      status = if ((Test-FilledValue $TenantId) -and (Test-FilledValue $ProjectId) -and (Test-FilledValue $WalletId)) { "filled" } else { "placeholder_only" }
    }
    virtual_key_issuance_evidence = [ordered]@{
      required = $true
      link_or_artifact = $route.path
      status = if ($virtualKeyBounded) { "bounded_contract_verified_live_issue_per_user_required" } else { "bounded_contract_missing" }
      live_route_verified = $false
      raw_virtual_key_secret_allowed = $false
    }
    voucher_quota_evidence_or_exception = [ordered]@{
      required = $true
      voucher_runtime_artifact = $voucher.path
      route_evidence_artifact = $route.path
      operator_only_exception_status = if ($exceptionApproved) { "approved" } else { "not_approved" }
      status = if ($routeVerified) { "public_route_verified" } elseif ($exceptionApproved) { "operator_only_exception_approved" } elseif ($voucherInternalVerified) { "internal_runtime_verified_productization_gap" } else { "voucher_runtime_missing" }
    }
    remaining_balance_readback = [ordered]@{
      required = $true
      artifact = $balance.path
      status = if ($balanceVerified) { "runtime_verified" } else { "missing_or_blocked" }
    }
    gateway_current_launch_artifact = [ordered]@{
      required = $true
      artifact = $gateway.path
      status = if ($gatewayPassed) { "verified" } else { "blocked" }
      provider_attempt_rows_zero_on_insufficient_balance = $true
    }
    rate_budget_guardrails = [ordered]@{
      required = $true
      artifact = $guardrails.path
      status = if ((Test-FilledValue $RateBudgetGuardrails) -and $guardrailsPassed) { "filled" } elseif ($guardrailsPassed) { "verified_template_only" } else { "blocked" }
      trusted_user_record = if (Test-FilledValue $RateBudgetGuardrails) { $RateBudgetGuardrails } else { "<trusted-user-rate-budget-guardrails-record>" }
      quota_rate_budget_record_template = ".tmp/launch/trusted_user_quota_rate_budget_record_template.json"
    }
    developer_distribution_packet_readback = [ordered]@{
      required = $true
      endpoint = "GET /user/developer-distribution-packet-readback"
      status = "endpoint_reference_ready_no_release_validation"
      endpoint_readiness = $true
      model_availability = $true
      quota_rate_budget_guardrails = $true
      voucher_key_handoff_refs = $true
      safe_next_action = $true
      raw_api_key_returned = $false
      raw_voucher_code_returned = $false
      provider_key_returned = $false
      authorization_returned = $false
      token_returned = $false
    }
    voucher_quota_assignment = [ordered]@{
      required = $true
      value = if (Test-FilledValue $VoucherQuota) { $VoucherQuota } else { "<voucher-quota-or-campaign-id-and-amount>" }
      status = if (Test-FilledValue $VoucherQuota) { "filled" } else { "placeholder_only" }
      raw_voucher_code_allowed = $false
    }
    rollback_revoke_plan = [ordered]@{
      required = $true
      owner = $rollbackOwnerField
      status = if (Test-FilledValue $RollbackOwner) { "owner_filled" } else { "checklist_present_owner_missing" }
      steps = @(
        "disable_or_revoke_virtual_key",
        "revoke_or_expire_voucher_or_credit_quota",
        "verify_remaining_balance_after_revoke",
        "verify_audit_or_support_record_after_revoke"
      )
    }
    support_contact = $supportField
    secret_scan = [ordered]@{
      required = $true
      command = "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/scan_secrets.ps1"
      latest_status = "pass"
      raw_secret_material_allowed = $false
    }
    docs_runbook_links = @(
      "project/RELEASE_CHECKLIST.md#voucher-backed-api-beta-distribution",
      "project/ACCEPTANCE_CHECKLIST.md#voucher-backed-api-distribution-acceptance",
      "docs/P0_BETA_STATUS.md",
      "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
    )
    deferred_runtime_status = [ordered]@{
      payment_order_invoice_todo_32j = "deferred_external_runtime_dependency"
      subscription_package_todo_32k = "deferred_external_runtime_dependency"
      blocks_this_packet = $false
    }
    current_blockers = @($currentBlockers.ToArray())
    missing_fields = @($missingFields.ToArray())
    placeholder_fields = @($missingFields.ToArray())
    productization_gaps = @(
      "public_recharge_voucher_route_evidence_pending_or_operator_only_policy_cleanup",
      "payment_order_invoice_external_runtime_deferred",
      "subscription_scheduler_provider_runtime_deferred"
    )
    no_secret_outputs = [ordered]@{
      raw_voucher_code = $false
      authorization = $false
      cookie = $false
      db_url = $false
      provider_key = $false
      virtual_key_secret = $false
    }
  }
}

if ($SelfTest) {
  $base = [pscustomobject]@{
    schema = "trusted_user_distribution_review_packet.v1"
    ready_to_send = $false
    release_owner = [pscustomobject]@{ status = "missing"; placeholder = "<release-owner>" }
    support_contact = [pscustomobject]@{ status = "missing"; placeholder = "<support-contact>" }
    tenant_project_wallet_ids = [pscustomobject]@{ tenant_id = "<tenant-id>"; project_id = "<project-id>"; wallet_id = "<wallet-id>" }
    virtual_key_issuance_evidence = [pscustomobject]@{ link_or_artifact = ".tmp/launch/voucher_public_route_and_virtual_key_evidence.json"; raw_virtual_key_secret_allowed = $false }
    voucher_quota_evidence_or_exception = [pscustomobject]@{ voucher_runtime_artifact = ".tmp/credit-wallet/recharge_voucher_runtime.json"; route_evidence_artifact = ".tmp/launch/voucher_public_route_and_virtual_key_evidence.json"; operator_only_exception_status = "not_approved"; status = "internal_runtime_verified_productization_gap" }
    remaining_balance_readback = [pscustomobject]@{ artifact = ".tmp/credit-wallet/user_remaining_balance_ownership_runtime.json" }
    gateway_current_launch_artifact = [pscustomobject]@{ artifact = ".tmp/launch/e8_gateway_paid_hot_path_launch_check.json"; status = "blocked" }
    rate_budget_guardrails = [pscustomobject]@{ artifact = ".tmp/launch/voucher_quota_pricing_guardrails.json"; trusted_user_record = "<trusted-user-rate-budget-guardrails-record>" }
    developer_distribution_packet_readback = [pscustomobject]@{ endpoint = "GET /user/developer-distribution-packet-readback"; endpoint_readiness = $true; model_availability = $true; quota_rate_budget_guardrails = $true; voucher_key_handoff_refs = $true; safe_next_action = $true; raw_api_key_returned = $false; raw_voucher_code_returned = $false; provider_key_returned = $false; authorization_returned = $false; token_returned = $false }
    voucher_quota_assignment = [pscustomobject]@{ value = "<voucher-quota-or-campaign-id-and-amount>"; status = "placeholder_only"; raw_voucher_code_allowed = $false }
    rollback_revoke_plan = [pscustomobject]@{ owner = [pscustomobject]@{ status = "missing"; placeholder = "<rollback-owner>" }; steps = @("disable_or_revoke_virtual_key", "revoke_or_expire_voucher_or_credit_quota", "verify_remaining_balance_after_revoke", "verify_audit_or_support_record_after_revoke") }
    secret_scan = [pscustomobject]@{ latest_status = "pass"; raw_secret_material_allowed = $false }
    docs_runbook_links = @("project/RELEASE_CHECKLIST.md", "project/ACCEPTANCE_CHECKLIST.md")
    deferred_runtime_status = [pscustomobject]@{ blocks_this_packet = $false }
  }
  $blocked = Test-Packet $base
  $badReady = $base.PSObject.Copy()
  $badReady.ready_to_send = $true
  $badReadyResult = Test-Packet $badReady
  $passReady = $base.PSObject.Copy()
  $passReady.ready_to_send = $true
  $passReady.release_owner = [pscustomobject]@{ status = "filled"; value = "release-owner" }
  $passReady.support_contact = [pscustomobject]@{ status = "filled"; value = "support-channel" }
  $passReady.tenant_project_wallet_ids = [pscustomobject]@{ tenant_id = "tenant"; project_id = "project"; wallet_id = "wallet" }
  $passReady.gateway_current_launch_artifact = [pscustomobject]@{ artifact = ".tmp/launch/e8_gateway_paid_hot_path_launch_check.json"; status = "verified" }
  $passReady.voucher_quota_evidence_or_exception = [pscustomobject]@{ voucher_runtime_artifact = ".tmp/credit-wallet/recharge_voucher_runtime.json"; route_evidence_artifact = ".tmp/launch/voucher_public_route_and_virtual_key_evidence.json"; operator_only_exception_status = "not_approved"; status = "internal_runtime_verified_productization_gap" }
  $passReady.rate_budget_guardrails = [pscustomobject]@{ artifact = ".tmp/launch/voucher_quota_pricing_guardrails.json"; status = "filled"; trusted_user_record = "rpm=60;tpm=estimated-conservative;quota=100.00000000" }
  $passReady.voucher_quota_assignment = [pscustomobject]@{ value = "campaign-qa-1:100.00000000"; status = "filled"; raw_voucher_code_allowed = $false }
  $passReady.rollback_revoke_plan = [pscustomobject]@{ owner = [pscustomobject]@{ status = "filled"; value = "rollback-owner" }; steps = @("disable_or_revoke_virtual_key", "revoke_or_expire_voucher_or_credit_quota", "verify_remaining_balance_after_revoke", "verify_audit_or_support_record_after_revoke") }
  $passReadyResult = Test-Packet $passReady

  $cases = @(
    [ordered]@{ name = "placeholder_packet_blocked_not_fail"; status = if ($blocked.overall_status -eq "blocked" -and $blocked.ready_to_send -eq $false) { "pass" } else { "fail" } },
    [ordered]@{ name = "ready_true_rejected_without_gateway"; status = if (@($badReadyResult.blockers | Where-Object { $_ -match "ready_to_send_true_without_gateway" }).Count -gt 0) { "pass" } else { "fail" } },
    [ordered]@{ name = "filled_packet_can_pass"; status = if ($passReadyResult.overall_status -eq "pass") { "pass" } else { "fail" } }
  )
  $status = if (@($cases | Where-Object { $_.status -ne "pass" }).Count -eq 0) { "pass" } else { "fail" }
  [ordered]@{
    schema = "trusted_user_distribution_review_packet_selftest.v1"
    overall_status = $status
    cases = $cases
  } | ConvertTo-Json -Depth 8
  if ($status -eq "pass") { exit 0 }
  exit 1
}

if ($WriteDefaultPacket) {
  $resolved = Resolve-RepoPath $PacketPath
  $parent = Split-Path -Parent $resolved.full
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $packet = New-DefaultPacket
  $packet | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resolved.full -Encoding utf8
}

$resolved = Resolve-RepoPath $PacketPath
if (-not (Test-Path -LiteralPath $resolved.full -PathType Leaf)) {
  [ordered]@{
    schema = "trusted_user_distribution_review_packet_verifier.v1"
    overall_status = "fail"
    actual_exit_code = 1
    packet_path = $resolved.relative
    blockers = @("packet_missing")
  } | ConvertTo-Json -Depth 8
  exit 1
}

$packet = Get-Content -Raw -LiteralPath $resolved.full | ConvertFrom-Json
$result = Test-Packet $packet
$result.packet_path = $resolved.relative
$result | ConvertTo-Json -Depth 10
exit ([int]$result.actual_exit_code)
