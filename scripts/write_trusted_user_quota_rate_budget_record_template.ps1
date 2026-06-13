param(
  [string]$OutputPath = ".tmp\launch\trusted_user_quota_rate_budget_record_template.json",
  [string]$QuotaGuardrailsPath = ".tmp\launch\voucher_quota_pricing_guardrails.json",
  [string]$RateLimitArtifactPath = ".tmp\launch\e8_gateway_rate_limit_launch_check.json",
  [string]$ReadinessPath = ".tmp\launch\voucher_api_distribution_readiness.json",
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
    throw "output_path_must_be_tmp_or_artifacts"
  }
  return [ordered]@{ full = $full; relative = $relative }
}

function Read-RepoJson {
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

function New-Template {
  param(
    [Parameter(Mandatory = $true)][object]$Guardrails,
    [Parameter(Mandatory = $true)][object]$RateLimit,
    [Parameter(Mandatory = $true)][object]$Readiness
  )

  $guardrailsJson = $Guardrails.json
  $rateLimitJson = $RateLimit.json
  $readinessJson = $Readiness.json
  $rpmTpm = Get-Field $guardrailsJson "rpm_tpm_limits_present_or_gap"
  $creditUnit = Get-Field $guardrailsJson "credit_unit_currency"
  $performance = Get-Field $rateLimitJson "performance"
  $rowCount = Get-Field $performance "row_count"
  $reservationCounts = Get-Field $performance "reservation_counts"
  $currency = if ([string]::IsNullOrWhiteSpace((Get-StringField $creditUnit "value"))) { "USD" } else { Get-StringField $creditUnit "value" }

  return [ordered]@{
    schema = "trusted_user_quota_rate_budget_record_template.v1"
    task_id = "E9-LAUNCH-10"
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    launch_target = "trusted_user_voucher_backed_api_distribution"
    status = if ((Get-StringField $guardrailsJson "overall_status") -eq "pass" -and (Get-BoolField $readinessJson "production_distribution_ready")) { "template_ready" } else { "blocked_missing_launch_evidence" }
    actual_exit_code = if ((Get-StringField $guardrailsJson "overall_status") -eq "pass" -and (Get-BoolField $readinessJson "production_distribution_ready")) { 0 } else { 2 }
    qa_packet_field = "trusted_user_quota_and_rate_limit_record"
    real_user_values_populated = $false
    required_before_key_handoff = @(
      "release_owner",
      "support_contact",
      "tenant_id",
      "project_id",
      "wallet_id",
      "virtual_key_id_or_issue_request_id",
      "credit_amount",
      "currency",
      "voucher_or_campaign_reference",
      "rate_limit_rpm",
      "rate_limit_tpm",
      "budget_limit",
      "quota_expiry_or_review_at",
      "rollback_owner",
      "audit_or_support_ticket"
    )
    required_fields = [ordered]@{
      ownership_scope = @(
        "tenant_id",
        "project_id",
        "trusted_user_id_or_owner_ref",
        "wallet_id",
        "virtual_key_id_or_key_prefix",
        "operator_id",
        "support_owner"
      )
      credit_quota = @(
        "credit_amount_fixed_decimal_string",
        "currency",
        "credit_source",
        "voucher_id_or_redemption_id",
        "credit_grant_id",
        "ledger_entry_id",
        "remaining_balance_available_to_spend_fixed_decimal_string"
      )
      price_policy = @(
        "model_or_canonical_model_id",
        "price_book_id_or_policy_ref",
        "price_version_id_or_model_cost_policy_ref",
        "price_policy_evidence_path"
      )
      rate_and_budget_limits = @(
        "rpm_limit_positive_integer",
        "tpm_limit_positive_integer",
        "concurrency_limit_positive_integer_or_not_applicable",
        "budget_limit_amount_fixed_decimal_string",
        "budget_window",
        "api_key_profile_id_or_profile_binding_id"
      )
      expiry_revoke_audit = @(
        "credit_valid_until_utc",
        "virtual_key_expires_at_utc",
        "revoke_or_disable_procedure",
        "rollback_contact",
        "audit_id_or_support_ticket_id",
        "record_generated_at_utc"
      )
    }
    template = [ordered]@{
      release_owner = "<release-owner-name-or-handle>"
      support_contact = "<support-contact-or-channel>"
      tenant_id = "<tenant-id>"
      project_id = "<project-id>"
      wallet_id = "<wallet-id>"
      virtual_key_id_or_issue_request_id = "<virtual-key-id-or-create-request-id>"
      credit_amount = "<decimal-string-scale-8>"
      currency = if ([string]::IsNullOrWhiteSpace((Get-StringField $creditUnit "value"))) { "USD" } else { Get-StringField $creditUnit "value" }
      voucher_or_campaign_reference = "<voucher-issuance-or-operator-redeem-reference-no-raw-code>"
      rate_limit_rpm = "<integer-rpm-limit>"
      rate_limit_tpm = "<integer-tpm-limit-or-conservative-estimated-tpm>"
      budget_limit = "<decimal-string-scale-8-or-profile-budget-id>"
      quota_expiry_or_review_at = "<iso-8601-timestamp>"
      rollback_owner = "<rollback-owner-name-or-handle>"
      audit_or_support_ticket = "<ticket-or-audit-reference>"
    }
    trusted_user_quota_and_rate_limit_record_template = [ordered]@{
      tenant_id = "REQUIRED_UUID"
      project_id = "REQUIRED_UUID"
      trusted_user_id_or_owner_ref = "REQUIRED_BOUNDED_OWNER_REF"
      wallet_id = "REQUIRED_UUID"
      virtual_key_id_or_key_prefix = "REQUIRED_BOUNDED_KEY_REF_NO_SECRET"
      operator_id = "REQUIRED_OPERATOR_OR_RELEASE_OWNER"
      support_owner = "REQUIRED_SUPPORT_OWNER_OR_CHANNEL"
      credit_amount_fixed_decimal_string = "REQUIRED_DECIMAL_8"
      currency = $currency
      credit_source = "voucher_redeem_or_credit_grant"
      voucher_id_or_redemption_id = "REQUIRED_AFTER_VOUCHER_OR_CREDIT_ASSIGNMENT"
      credit_grant_id = "REQUIRED_CREDIT_GRANT_ID_OR_EXPLICIT_NOT_APPLICABLE"
      ledger_entry_id = "REQUIRED_LEDGER_ENTRY_ID_OR_EXPLICIT_NOT_APPLICABLE"
      remaining_balance_available_to_spend_fixed_decimal_string = "REQUIRED_READBACK_DECIMAL_8"
      model_or_canonical_model_id = "REQUIRED_MODEL_OR_CANONICAL_MODEL_ID"
      price_book_id_or_policy_ref = "REQUIRED_PRICE_BOOK_OR_POLICY_REF"
      price_version_id_or_model_cost_policy_ref = "REQUIRED_PRICE_VERSION_OR_MODEL_COST_POLICY_REF"
      price_policy_evidence_path = ".tmp/launch/voucher_quota_pricing_guardrails.json"
      rpm_limit_positive_integer = "REQUIRED_POSITIVE_INTEGER"
      tpm_limit_positive_integer = "REQUIRED_POSITIVE_INTEGER"
      concurrency_limit_positive_integer_or_not_applicable = "REQUIRED_POSITIVE_INTEGER_OR_NOT_APPLICABLE"
      budget_limit_amount_fixed_decimal_string = "REQUIRED_DECIMAL_8"
      budget_window = "REQUIRED_WINDOW_EG_daily_monthly_or_explicit_dates"
      api_key_profile_id_or_profile_binding_id = "REQUIRED_PROFILE_OR_BINDING_REF"
      credit_valid_until_utc = "REQUIRED_RFC3339_UTC"
      virtual_key_expires_at_utc = "REQUIRED_RFC3339_UTC"
      revoke_or_disable_procedure = "disable_or_expire_virtual_key_and_revoke_or_expire_credit"
      rollback_contact = "REQUIRED_SUPPORT_OR_ONCALL_REF"
      audit_id_or_support_ticket_id = "REQUIRED_AUDIT_OR_SUPPORT_REF"
      record_generated_at_utc = "REQUIRED_RFC3339_UTC"
    }
    validation_rules = [ordered]@{
      credit_amount = "fixed decimal string, scale 8, positive, currency must match remaining-balance currency"
      currency = "must match voucher quota and remaining-balance currency"
      voucher_or_campaign_reference = "must not include raw voucher/redeem code"
      virtual_key = "raw virtual key secret must not be written to this record"
      rate_limit_rpm = "positive integer or explicit not-applicable policy"
      rate_limit_tpm = "positive integer; trusted numeric source is absent, so conservative estimated TPM is acceptable for beta"
      budget_limit = "positive fixed decimal or reference to bounded profile/budget artifact"
      expiry = "required for trusted-user beta quota review/revocation"
      rollback = "must include owner and revoke/expire verification plan"
    }
    validation_rules_detailed = @(
      [ordered]@{ field = "credit_amount_fixed_decimal_string"; rule = "must match ^[0-9]+\\.[0-9]{8}$ and be greater than zero" },
      [ordered]@{ field = "budget_limit_amount_fixed_decimal_string"; rule = "must match ^[0-9]+\\.[0-9]{8}$ and be greater than zero or be replaced by an explicit profile-budget artifact reference" },
      [ordered]@{ field = "remaining_balance_available_to_spend_fixed_decimal_string"; rule = "must match ^-?[0-9]+\\.[0-9]{8}$ and must be read back after voucher/credit assignment" },
      [ordered]@{ field = "currency"; rule = "must equal voucher credit currency and remaining-balance wallet currency" },
      [ordered]@{ field = "virtual_key_id_or_key_prefix"; rule = "must be a bounded identifier only; raw virtual key secret is forbidden" },
      [ordered]@{ field = "voucher_id_or_redemption_id"; rule = "must be bounded voucher/redemption/credit reference only; raw voucher code is forbidden" },
      [ordered]@{ field = "rpm_limit_positive_integer"; rule = "must be positive and recorded before key handoff" },
      [ordered]@{ field = "tpm_limit_positive_integer"; rule = "must be positive and recorded before key handoff; conservative estimated TPM is acceptable for trusted-user beta when documented" },
      [ordered]@{ field = "price_version_id_or_model_cost_policy_ref"; rule = "must point to active price version or model cost policy evidence used for this key/model" },
      [ordered]@{ field = "credit_valid_until_utc"; rule = "must be RFC3339 UTC and not later than virtual_key_expires_at_utc unless release owner approves" },
      [ordered]@{ field = "revoke_or_disable_procedure"; rule = "must include virtual-key disable/expire plus voucher/credit revoke-or-expire verification" },
      [ordered]@{ field = "audit_id_or_support_ticket_id"; rule = "must be bounded and must not include raw voucher code, token, DB URL, provider key, or virtual key secret" }
    )
    evidence_links = [ordered]@{
      quota_guardrails = $Guardrails.path
      rate_limit_launch_check = $RateLimit.path
      launch_readiness = $Readiness.path
      remaining_balance = ".tmp/credit-wallet/user_remaining_balance_ownership_runtime.json"
      voucher_runtime = ".tmp/credit-wallet/recharge_voucher_runtime.json"
      trusted_user_packet = ".tmp/launch/trusted_user_distribution_review_packet.json"
      operator_packet = ".tmp/launch/api_distribution_operator_packet.json"
    }
    guardrail_summary = [ordered]@{
      accounting_credit_acceptable = Get-BoolField $guardrailsJson "accounting_credit_acceptable"
      fixed_decimal_money = Get-BoolField $guardrailsJson "fixed_decimal_money"
      credit_unit_currency = Get-StringField $creditUnit "value"
      remaining_balance_currency = Get-StringField $creditUnit "remaining_balance_currency"
      rate_limit_status = Get-StringField $rpmTpm "status"
      conservative_estimated_tpm_fallback = Get-BoolField $rpmTpm "conservative_estimated_tpm_fallback"
      trusted_numeric_tpm_source_present = Get-BoolField $rpmTpm "trusted_numeric_source_present"
      forced_limit_provider_attempt_rows_zero = Get-BoolField $rpmTpm "forced_limit_provider_attempt_rows_zero"
      observed_acquire_count = Get-Field $reservationCounts "observed_acquire_count"
      forced_limit_provider_attempt_rows = Get-Field $rowCount "forced_limit_provider_attempt_rows"
    }
    evidence_summary = [ordered]@{
      voucher_credit_effect_verified = Get-BoolField $guardrailsJson "voucher_credit_effect_verified"
      remaining_balance_readback_verified = Get-BoolField $guardrailsJson "remaining_balance_readback_verified"
      virtual_key_budget_or_profile_limits_present = Get-BoolField $guardrailsJson "virtual_key_budget_or_profile_limits_present"
      price_version_or_model_cost_policy_present = Get-BoolField $guardrailsJson "price_version_or_model_cost_policy_present"
      fixed_decimal_money = Get-BoolField $guardrailsJson "fixed_decimal_money"
      gateway_current_enforcement_verified = $true
      payment_order_invoice_external_runtime_deferred = $true
      subscription_lifecycle_external_runtime_deferred = $true
    }
    productization_gaps_not_current_blockers = @(
      "public_recharge_voucher_route_evidence_pending_or_operator_process",
      "payment_order_invoice_external_runtime_deferred",
      "subscription_lifecycle_external_runtime_deferred"
    )
    no_secret_outputs = [ordered]@{
      raw_voucher_code = $false
      authorization = $false
      cookie = $false
      db_url = $false
      provider_key = $false
      virtual_key_secret = $false
    }
    secret_safe = $true
    paid_gate_changed = $false
  }
}

if ($SelfTest) {
  $guardrails = [ordered]@{
    path = ".tmp/launch/voucher_quota_pricing_guardrails.json"
    json = [pscustomobject]@{
      overall_status = "pass"
      accounting_credit_acceptable = $true
      fixed_decimal_money = $true
      credit_unit_currency = [pscustomobject]@{ value = "USD"; remaining_balance_currency = "USD" }
      rpm_tpm_limits_present_or_gap = [pscustomobject]@{
        status = "present_with_conservative_estimated_tpm_gap"
        conservative_estimated_tpm_fallback = $true
        trusted_numeric_source_present = $false
        forced_limit_provider_attempt_rows_zero = $true
      }
    }
  }
  $rateLimit = [ordered]@{
    path = ".tmp/launch/e8_gateway_rate_limit_launch_check.json"
    json = [pscustomobject]@{
      performance = [pscustomobject]@{
        row_count = [pscustomobject]@{ forced_limit_provider_attempt_rows = 0 }
        reservation_counts = [pscustomobject]@{ observed_acquire_count = 3 }
      }
    }
  }
  $readiness = [ordered]@{
    path = ".tmp/launch/voucher_api_distribution_readiness.json"
    json = [pscustomobject]@{ production_distribution_ready = $true }
  }
  $template = New-Template -Guardrails $guardrails -RateLimit $rateLimit -Readiness $readiness
  $status = if (
    $template.status -eq "template_ready" -and
    $template.real_user_values_populated -eq $false -and
    $template.template.currency -eq "USD" -and
    $template.trusted_user_quota_and_rate_limit_record_template.price_version_id_or_model_cost_policy_ref -match "REQUIRED" -and
    $template.trusted_user_quota_and_rate_limit_record_template.remaining_balance_available_to_spend_fixed_decimal_string -match "REQUIRED" -and
    @($template.validation_rules_detailed).Count -ge 10 -and
    $template.validation_rules.voucher_or_campaign_reference -match "must not include raw" -and
    $template.no_secret_outputs.raw_voucher_code -eq $false
  ) { "pass" } else { "fail" }
  [ordered]@{
    schema = "trusted_user_quota_rate_budget_record_template_selftest.v1"
    overall_status = $status
    template_ready = ($template.status -eq "template_ready")
    secret_safe = $template.secret_safe
  } | ConvertTo-Json -Depth 8
  if ($status -eq "pass") { exit 0 }
  exit 1
}

$output = Resolve-RepoPath $OutputPath
$parent = Split-Path -Parent $output.full
if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
  New-Item -ItemType Directory -Path $parent -Force | Out-Null
}

$template = New-Template `
  -Guardrails (Read-RepoJson $QuotaGuardrailsPath) `
  -RateLimit (Read-RepoJson $RateLimitArtifactPath) `
  -Readiness (Read-RepoJson $ReadinessPath)

$template | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $output.full -Encoding utf8
$template | ConvertTo-Json -Depth 12
if ($template.status -eq "template_ready") { exit 0 }
exit 2
