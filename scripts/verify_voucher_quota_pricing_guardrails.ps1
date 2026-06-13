param(
  [string]$OutputPath = ".tmp\launch\voucher_quota_pricing_guardrails.json",
  [string]$RechargeVoucherRuntimePath = ".tmp\credit-wallet\recharge_voucher_runtime.json",
  [string]$UserRemainingBalanceRuntimePath = ".tmp\credit-wallet\user_remaining_balance_ownership_runtime.json",
  [string]$VoucherAccountingGatePath = ".tmp\launch\voucher_backed_api_distribution_accounting_gate.json",
  [string]$GatewayVoucherReadinessPath = ".tmp\launch\gateway_voucher_distribution_readiness.json",
  [string]$GatewayPaidHotPathLaunchCheckPath = ".tmp\launch\e8_gateway_paid_hot_path_launch_check.json",
  [string]$GatewayRateLimitLaunchCheckPath = ".tmp\launch\e8_gateway_rate_limit_launch_check.json",
  [string]$VoucherApiDistributionReadinessPath = ".tmp\launch\voucher_api_distribution_readiness.json",
  [string]$VoucherPublicRouteVirtualKeyEvidencePath = ".tmp\launch\voucher_public_route_and_virtual_key_evidence.json",
  [string]$PricingPolicyFixturePath = "tests\fixtures\gateway\pricing_policy_selection.json"
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Resolve-RepoBoundedPath {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string[]]$AllowedPrefixes
  )

  $candidate = if ([System.IO.Path]::IsPathRooted($Path)) {
    [System.IO.Path]::GetFullPath($Path)
  } else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
  }

  $repoPrefix = $repoRoot.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
  if (-not $candidate.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "path_must_stay_inside_repo"
  }

  $relative = $candidate.Substring($repoPrefix.Length).Replace("\", "/")
  $allowed = $false
  foreach ($prefix in $AllowedPrefixes) {
    if ($relative.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      $allowed = $true
      break
    }
  }
  if (-not $allowed) {
    throw "path_prefix_not_allowed"
  }

  return [ordered]@{
    full = $candidate
    relative = $relative
  }
}

function Read-JsonArtifact {
  param([Parameter(Mandatory = $true)][string]$Path)

  $resolved = Resolve-RepoBoundedPath -Path $Path -AllowedPrefixes @(".tmp/", "artifacts/", "tests/fixtures/")
  if (-not (Test-Path -LiteralPath $resolved.full)) {
    return [ordered]@{
      exists = $false
      path = $resolved.relative
      json = $null
    }
  }

  try {
    return [ordered]@{
      exists = $true
      path = $resolved.relative
      json = ((Get-Content -Raw -LiteralPath $resolved.full) | ConvertFrom-Json)
    }
  } catch {
    return [ordered]@{
      exists = $true
      path = $resolved.relative
      json = $null
      parse_error = "json_parse_failed"
    }
  }
}

function Read-RepoText {
  param([Parameter(Mandatory = $true)][string]$Path)

  $resolved = Resolve-RepoBoundedPath -Path $Path -AllowedPrefixes @("apps/", "db/", "examples/", "tests/")
  if (-not (Test-Path -LiteralPath $resolved.full)) {
    return ""
  }
  return Get-Content -Raw -LiteralPath $resolved.full
}

function Get-JsonBool {
  param(
    [AllowNull()][object]$Json,
    [Parameter(Mandatory = $true)][string]$Name,
    [bool]$Default = $false
  )

  if ($null -eq $Json) { return $Default }
  if ($Json.PSObject.Properties.Name -notcontains $Name) { return $Default }
  $value = $Json.PSObject.Properties[$Name].Value
  if ($value -is [bool]) { return [bool]$value }
  if ($null -eq $value) { return $Default }
  $text = ([string]$value).Trim().ToLowerInvariant()
  if ($text -in @("true", "1", "yes", "pass", "passed")) { return $true }
  if ($text -in @("false", "0", "no", "blocked", "failed")) { return $false }
  return $Default
}

function Get-JsonString {
  param(
    [AllowNull()][object]$Json,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if ($null -eq $Json) { return "" }
  if ($Json.PSObject.Properties.Name -notcontains $Name) { return "" }
  $value = $Json.PSObject.Properties[$Name].Value
  if ($null -eq $value) { return "" }
  return [string]$value
}

function Test-DecimalMoneyString {
  param([AllowNull()][string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  return $Value -match '^-?[0-9]+\.[0-9]{8}$'
}

function Test-SecretSafeText {
  param([AllowNull()][string]$Text)

  if ([string]::IsNullOrWhiteSpace($Text)) { return $true }
  foreach ($pattern in @(
      '(?i)authorization\s*[:=]\s*bearer\s+[A-Za-z0-9._~+/\-]+=*',
      '(?i)bearer\s+[A-Za-z0-9._~+/\-]{16,}=*',
      '(?i)postgres(?:ql)?://[^"\s]+',
      '(?i)database_url\s*[:=]\s*["''][^"'']+["'']',
      '(?i)client_secret\s*[:=]\s*["''][^"'']+["'']',
      '(?i)provider_secret\s*[:=]\s*["''][^"'']+["'']',
      'sk-[A-Za-z0-9]{16,}'
    )) {
    if ($Text -match $pattern) {
      return $false
    }
  }
  return $true
}

function Test-ArtifactSecretSafe {
  param([AllowNull()][object]$Json)

  if ($null -eq $Json) { return $false }
  if (-not (Test-SecretSafeText -Text ($Json | ConvertTo-Json -Depth 40))) {
    return $false
  }

  if ($Json.PSObject.Properties.Name -contains "secret_safe") {
    $secretSafe = $Json.PSObject.Properties["secret_safe"].Value
    if ($secretSafe -is [bool]) { return [bool]$secretSafe }
    if ($null -ne $secretSafe) {
      foreach ($property in $secretSafe.PSObject.Properties) {
        if (($property.Name -match '(?i)omitted|echoed|present|raw|secret|token|database|provider|virtual') -and
            ($property.Value -is [bool]) -and
            $property.Name -notmatch '(?i)omitted' -and
            [bool]$property.Value) {
          return $false
        }
      }
      return $true
    }
  }

  if ($Json.PSObject.Properties.Name -contains "no_secret_outputs") {
    foreach ($property in $Json.no_secret_outputs.PSObject.Properties) {
      if (($property.Value -is [bool]) -and [bool]$property.Value) {
        return $false
      }
    }
    return $true
  }

  return $true
}

function New-ArtifactSummary {
  param([Parameter(Mandatory = $true)][object]$Artifact)

  $json = $Artifact.json
  return [ordered]@{
    path = $Artifact.path
    exists = [bool]$Artifact.exists
    schema = Get-JsonString -Json $json -Name "schema"
    overall_status = Get-JsonString -Json $json -Name "overall_status"
    status = Get-JsonString -Json $json -Name "status"
    runtime_implemented = Get-JsonBool -Json $json -Name "runtime_implemented"
    contract_only = Get-JsonBool -Json $json -Name "contract_only"
    secret_safe = Test-ArtifactSecretSafe -Json $json
    paid_gate_changed = Get-JsonBool -Json $json -Name "paid_gate_changed"
  }
}

function Convert-Blockers {
  param([AllowNull()][object]$Blockers)

  $items = @()
  if ($null -eq $Blockers) { return $items }
  foreach ($item in @($Blockers)) {
    if ($null -eq $item) { continue }
    if ($item -is [string]) {
      $items += $item
    } elseif ($item.PSObject.Properties.Name -contains "id") {
      $items += [string]$item.id
    } elseif ($item.PSObject.Properties.Name -contains "blocker") {
      $items += [string]$item.blocker
    }
  }
  return $items
}

$output = Resolve-RepoBoundedPath -Path $OutputPath -AllowedPrefixes @(".tmp/", "artifacts/")
$outputDir = Split-Path -Parent $output.full
if (-not (Test-Path -LiteralPath $outputDir)) {
  New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
}

$recharge = Read-JsonArtifact -Path $RechargeVoucherRuntimePath
$balance = Read-JsonArtifact -Path $UserRemainingBalanceRuntimePath
$accountingGate = Read-JsonArtifact -Path $VoucherAccountingGatePath
$gatewayReadiness = Read-JsonArtifact -Path $GatewayVoucherReadinessPath
$gatewayLaunch = Read-JsonArtifact -Path $GatewayPaidHotPathLaunchCheckPath
$rateLimit = Read-JsonArtifact -Path $GatewayRateLimitLaunchCheckPath
$apiReadiness = Read-JsonArtifact -Path $VoucherApiDistributionReadinessPath
$routeEvidence = Read-JsonArtifact -Path $VoucherPublicRouteVirtualKeyEvidencePath
$pricingFixture = Read-JsonArtifact -Path $PricingPolicyFixturePath

$schemaText = (Read-RepoText -Path "examples\sql_schema_draft.sql") + "`n" +
  (Read-RepoText -Path "db\dev-seeds\0002_dev_gateway_seed.sql") + "`n" +
  (Read-RepoText -Path "db\dev-seeds\0003_dev_smoke_seed_reconcile.sql") + "`n" +
  (Read-RepoText -Path "apps\gateway\src\db.rs")

$rechargeJson = $recharge.json
$balanceJson = $balance.json
$accountingJson = $accountingGate.json
$gatewayReadinessJson = $gatewayReadiness.json
$gatewayLaunchJson = $gatewayLaunch.json
$rateLimitJson = $rateLimit.json
$apiReadinessJson = $apiReadiness.json
$routeEvidenceJson = $routeEvidence.json

$creditUnitCurrency = Get-JsonString -Json $rechargeJson -Name "currency"
$balanceCurrency = Get-JsonString -Json $balanceJson -Name "currency"
$currencyConsistent = -not [string]::IsNullOrWhiteSpace($creditUnitCurrency) -and $creditUnitCurrency -eq $balanceCurrency

$fixedDecimalMoney = [bool](
  (Get-JsonBool -Json $rechargeJson -Name "money_decimal_strings") -and
  (Get-JsonBool -Json $balanceJson -Name "money_decimal_strings") -and
  (Test-DecimalMoneyString -Value (Get-JsonString -Json $balanceJson -Name "available_to_spend")) -and
  (Test-DecimalMoneyString -Value (Get-JsonString -Json $balanceJson -Name "active_credit_grant_total")) -and
  (Test-DecimalMoneyString -Value (Get-JsonString -Json $balanceJson -Name "wallet_balance_floor"))
)

$voucherCreditEffectVerified = [bool](
  $recharge.exists -and
  (Get-JsonString -Json $rechargeJson -Name "schema") -eq "recharge_voucher_runtime.v1" -and
  (Get-JsonString -Json $rechargeJson -Name "overall_status") -eq "pass" -and
  (Get-JsonBool -Json $rechargeJson -Name "runtime_implemented") -and
  (Get-JsonBool -Json $rechargeJson -Name "ledger_or_credit_readback_passed") -and
  (Get-JsonBool -Json $rechargeJson -Name "direct_wallet_snapshot_mutation_forbidden") -and
  -not (Get-JsonBool -Json $rechargeJson -Name "paid_gate_changed") -and
  (Test-ArtifactSecretSafe -Json $rechargeJson)
)

$remainingBalanceReadbackVerified = [bool](
  $balance.exists -and
  (Get-JsonString -Json $balanceJson -Name "schema") -eq "user_remaining_balance_runtime.v1" -and
  (Get-JsonString -Json $balanceJson -Name "overall_status") -eq "pass" -and
  (Get-JsonBool -Json $balanceJson -Name "runtime_implemented") -and
  (Get-JsonBool -Json $balanceJson -Name "read_only") -and
  (Get-JsonBool -Json $balanceJson -Name "wallet_readback_passed") -and
  (Get-JsonBool -Json $balanceJson -Name "credit_grants_readback_passed") -and
  (Get-JsonBool -Json $balanceJson -Name "ledger_window_readback_passed") -and
  (Get-JsonBool -Json $balanceJson -Name "direct_wallet_snapshot_mutation_forbidden") -and
  -not (Get-JsonBool -Json $balanceJson -Name "paid_gate_changed") -and
  (Test-ArtifactSecretSafe -Json $balanceJson)
)

$virtualKeySchemaPresent = [bool](
  (($schemaText -match 'create table if not exists api_key_profiles') -or
   ($schemaText -match 'create table if not exists virtual_key_profiles')) -and
  $schemaText -match 'rate_limit_policy jsonb' -and
  $schemaText -match 'budget_policy jsonb' -and
  $schemaText -match 'create table if not exists virtual_key_profile_bindings'
)
$virtualKeyRouteContract = [bool](
  $routeEvidence.exists -and
  $null -ne $routeEvidenceJson.virtual_key_issue_readback_audit -and
  (Get-JsonBool -Json $routeEvidenceJson.virtual_key_issue_readback_audit -Name "bounded_db_free_route_contract_verified")
)
$virtualKeyBudgetOrProfileLimitsPresent = [bool]($virtualKeySchemaPresent -and $virtualKeyRouteContract)
$budgetPolicyRuntimeReadbackPresent = [bool](
  $gatewayReadiness.exists -and
  $null -ne $gatewayReadinessJson.balance_floor_enforced_or_gap -and
  (Get-JsonBool -Json $gatewayReadinessJson.balance_floor_enforced_or_gap -Name "code_contract_verified") -and
  ($schemaText -match 'from budgets b')
)

$rateLimitLiveCompleted = [bool](
  $rateLimit.exists -and
  (Get-JsonString -Json $rateLimitJson -Name "status") -eq "live_completed" -and
  $null -ne $rateLimitJson.performance -and
  $null -ne $rateLimitJson.performance.reservation_counts -and
  [int]$rateLimitJson.performance.reservation_counts.observed_acquire_count -ge 1
)
$forcedLimitNoProviderAttempt = [bool](
  $rateLimitLiveCompleted -and
  $null -ne $rateLimitJson.performance.row_count -and
  [int]$rateLimitJson.performance.row_count.forced_limit_provider_attempt_rows -eq 0
)
$trustedTpmPresent = [bool](
  $rateLimitLiveCompleted -and
  $null -ne $rateLimitJson.trusted_numeric_source_handoff -and
  (Get-JsonBool -Json $rateLimitJson.trusted_numeric_source_handoff -Name "request_path_trusted_numeric_present_field" -Default $false)
)
$estimatedTpmFallback = [bool](
  $rateLimitLiveCompleted -and
  $null -ne $rateLimitJson.request_trace_usage_handoff -and
  $null -ne $rateLimitJson.request_trace_usage_handoff.estimated_tpm_fallback -and
  (Get-JsonBool -Json $rateLimitJson.request_trace_usage_handoff.estimated_tpm_fallback -Name "estimated")
)
$rpmTpmStatus = if ($rateLimitLiveCompleted -and $forcedLimitNoProviderAttempt -and $estimatedTpmFallback) {
  "present_with_conservative_estimated_tpm_gap"
} elseif ($rateLimitLiveCompleted -and $forcedLimitNoProviderAttempt) {
  "present"
} else {
  "missing_or_unproven"
}

$pricePolicyPresent = [bool](
  $pricingFixture.exists -and
  ($schemaText -match 'create table if not exists price_books') -and
  ($schemaText -match 'create table if not exists price_versions') -and
  ($schemaText -match 'pricing_rules jsonb') -and
  ($schemaText -match 'RESOLVE_ACTIVE_PRICE_VERSION_SQL')
)

$gatewayCurrentVerified = [bool](
  $gatewayReadiness.exists -and
  $null -ne $gatewayReadinessJson.paid_hot_path_verified -and
  (Get-JsonBool -Json $gatewayReadinessJson.paid_hot_path_verified -Name "current_launch_live_verified")
)
$gatewayBlockers = @()
if ($gatewayReadinessJson.PSObject.Properties.Name -contains "blockers") {
  $gatewayBlockers += Convert-Blockers -Blockers $gatewayReadinessJson.blockers
}
if (-not $gatewayCurrentVerified) {
  $gatewayBlockers += "current_paid_live_smoke_insufficient_balance_gate_not_proven"
}
$gatewayBlockers = @($gatewayBlockers | Select-Object -Unique)

$secretSafe = [bool](
  (Test-ArtifactSecretSafe -Json $rechargeJson) -and
  (Test-ArtifactSecretSafe -Json $balanceJson) -and
  (Test-ArtifactSecretSafe -Json $accountingJson) -and
  (Test-ArtifactSecretSafe -Json $gatewayReadinessJson) -and
  (Test-ArtifactSecretSafe -Json $gatewayLaunchJson) -and
  (Test-ArtifactSecretSafe -Json $rateLimitJson) -and
  (Test-ArtifactSecretSafe -Json $apiReadinessJson) -and
  (Test-ArtifactSecretSafe -Json $routeEvidenceJson)
)

$missingGuardrails = [System.Collections.Generic.List[string]]::new()
$resumeConditions = [System.Collections.Generic.List[string]]::new()

if (-not $currencyConsistent) {
  $missingGuardrails.Add("credit_unit_currency_mismatch_or_missing")
  $resumeConditions.Add("Regenerate voucher runtime and remaining-balance artifacts with matching fixed currency markers.")
}
if (-not $fixedDecimalMoney) {
  $missingGuardrails.Add("fixed_decimal_money_not_proven")
  $resumeConditions.Add("Regenerate credit/readback artifacts with decimal-string money fields and no floating-point amount output.")
}
if (-not $voucherCreditEffectVerified) {
  $missingGuardrails.Add("voucher_credit_effect_not_verified")
  $resumeConditions.Add("Restore pass recharge_voucher_runtime.v1 evidence with ledger_or_credit_readback_passed=true and no direct wallet mutation.")
}
if (-not $remainingBalanceReadbackVerified) {
  $missingGuardrails.Add("remaining_balance_readback_not_verified")
  $resumeConditions.Add("Restore pass user_remaining_balance_runtime.v1 readback evidence for wallet/credit grants/ledger window.")
}
if (-not $virtualKeyBudgetOrProfileLimitsPresent) {
  $missingGuardrails.Add("virtual_key_budget_or_profile_limits_not_present")
  $resumeConditions.Add("Provide virtual-key profile/binding evidence with server-side profile or budget guardrails for distributed keys.")
}
if (-not $budgetPolicyRuntimeReadbackPresent) {
  $missingGuardrails.Add("distributed_virtual_key_budget_policy_runtime_readback_missing")
  $resumeConditions.Add("Produce launch evidence for a distributed virtual key showing a non-empty budget/profile policy or an explicit release-approved profile limit.")
}
if ($rpmTpmStatus -eq "missing_or_unproven") {
  $missingGuardrails.Add("rpm_tpm_limits_missing_or_unproven")
  $resumeConditions.Add("Produce rate-limit launch evidence with RPM/TPM reservation and forced-limit provider_attempt_rows=0.")
}
if (-not $pricePolicyPresent) {
  $missingGuardrails.Add("price_version_or_model_cost_policy_not_present")
  $resumeConditions.Add("Provide active price version/model cost policy evidence and selector guards for the launch model.")
}
if (-not $gatewayCurrentVerified) {
  $missingGuardrails.Add("gateway_current_enforcement_not_passed")
  $resumeConditions.Add("E8 must rerun current Gateway paid hot-path launch smoke until insufficient balance returns billing 402 and provider_attempt_rows=0, or release owner must document an explicit waiver.")
}
if (-not $secretSafe) {
  $missingGuardrails.Add("secret_safe_output_not_proven")
  $resumeConditions.Add("Remove raw token, DB URL, provider secret, virtual key, or voucher code material from launch artifacts.")
}

$launchReady = [bool](
  $voucherCreditEffectVerified -and
  $remainingBalanceReadbackVerified -and
  $currencyConsistent -and
  $fixedDecimalMoney -and
  $virtualKeyBudgetOrProfileLimitsPresent -and
  $budgetPolicyRuntimeReadbackPresent -and
  ($rpmTpmStatus -ne "missing_or_unproven") -and
  $pricePolicyPresent -and
  $gatewayCurrentVerified -and
  $secretSafe
)
$actualExitCode = if ($launchReady) { 0 } else { 2 }
$overallStatus = if ($launchReady) { "pass" } else { "blocked" }
$guardrailVerdict = if ($launchReady) {
  "launch_ready"
} elseif ($voucherCreditEffectVerified -and $remainingBalanceReadbackVerified) {
  "accounting_credit_acceptable_but_launch_guardrails_or_gateway_blocked"
} else {
  "blocked_accounting_or_guardrails_missing"
}

$summary = [ordered]@{
  schema = "voucher_quota_pricing_guardrails.v1"
  task_id = "E9-LAUNCH-04"
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  overall_status = $overallStatus
  guardrail_verdict = $guardrailVerdict
  launch_ready = $launchReady
  actual_exit_code = $actualExitCode
  launch_target = "trusted_user_voucher_backed_api_distribution"
  accounting_credit_verdict_unchanged = $true
  accounting_credit_acceptable = [bool](Get-JsonBool -Json $accountingJson -Name "accounting_credit_acceptable" -Default ($voucherCreditEffectVerified -and $remainingBalanceReadbackVerified))
  credit_unit_currency = [ordered]@{
    value = $creditUnitCurrency
    remaining_balance_currency = $balanceCurrency
    consistent = $currencyConsistent
  }
  fixed_decimal_money = $fixedDecimalMoney
  voucher_credit_effect_verified = $voucherCreditEffectVerified
  remaining_balance_readback_verified = $remainingBalanceReadbackVerified
  virtual_key_budget_or_profile_limits_present = $virtualKeyBudgetOrProfileLimitsPresent
  virtual_key_guardrails = [ordered]@{
    profile_table = if ($schemaText -match 'create table if not exists api_key_profiles') { "api_key_profiles" } else { "virtual_key_profiles" }
    profile_schema_present = $virtualKeySchemaPresent
    bounded_virtual_key_issue_contract_verified = $virtualKeyRouteContract
    budget_policy_runtime_readback_present = $budgetPolicyRuntimeReadbackPresent
    live_virtual_key_route_invoked = [bool]($routeEvidence.exists -and $null -ne $routeEvidenceJson.virtual_key_issue_readback_audit -and (Get-JsonBool -Json $routeEvidenceJson.virtual_key_issue_readback_audit -Name "route_invoked"))
    no_raw_virtual_key_secret = [bool](Test-ArtifactSecretSafe -Json $routeEvidenceJson)
  }
  rpm_tpm_limits_present_or_gap = [ordered]@{
    status = $rpmTpmStatus
    rate_limit_launch_artifact_present = [bool]$rateLimit.exists
    live_completed = $rateLimitLiveCompleted
    reservation_acquire_release_verified = $rateLimitLiveCompleted
    forced_limit_provider_attempt_rows_zero = $forcedLimitNoProviderAttempt
    trusted_numeric_tpm_source_present = $trustedTpmPresent
    conservative_estimated_tpm_fallback = $estimatedTpmFallback
    beta_gap = if ($estimatedTpmFallback -and -not $trustedTpmPresent) { "trusted_tpm_numeric_source_missing_conservative_fallback_only" } else { "" }
  }
  price_version_or_model_cost_policy_present = $pricePolicyPresent
  price_policy_evidence = [ordered]@{
    fixture_present = [bool]$pricingFixture.exists
    price_books_schema_present = [bool]($schemaText -match 'create table if not exists price_books')
    price_versions_schema_present = [bool]($schemaText -match 'create table if not exists price_versions')
    pricing_rules_schema_present = [bool]($schemaText -match 'pricing_rules jsonb')
    gateway_selector_sql_present = [bool]($schemaText -match 'RESOLVE_ACTIVE_PRICE_VERSION_SQL')
  }
  gateway_current_blocker_passthrough = [ordered]@{
    current_launch_verified = $gatewayCurrentVerified
    readiness_artifact = $gatewayReadiness.path
    launch_smoke_artifact = $gatewayLaunch.path
    blockers = $gatewayBlockers
    blocks_launch = [bool](-not $gatewayCurrentVerified)
  }
  deferred_runtime_items = [ordered]@{
    payment_order_invoice_deferred = $true
    subscription_lifecycle_deferred = $true
    todo_32j_runtime_false = $true
    todo_32k_runtime_false = $true
  }
  secret_safe = $secretSafe
  missing_guardrails = @($missingGuardrails)
  resume_conditions = @($resumeConditions)
  artifact_inputs = [ordered]@{
    recharge_voucher_runtime = New-ArtifactSummary -Artifact $recharge
    user_remaining_balance_runtime = New-ArtifactSummary -Artifact $balance
    voucher_accounting_gate = New-ArtifactSummary -Artifact $accountingGate
    gateway_voucher_readiness = New-ArtifactSummary -Artifact $gatewayReadiness
    gateway_paid_hot_path_launch_check = New-ArtifactSummary -Artifact $gatewayLaunch
    gateway_rate_limit_launch_check = New-ArtifactSummary -Artifact $rateLimit
    voucher_api_distribution_readiness = New-ArtifactSummary -Artifact $apiReadiness
    voucher_public_route_virtual_key_evidence = New-ArtifactSummary -Artifact $routeEvidence
    pricing_policy_fixture = New-ArtifactSummary -Artifact $pricingFixture
  }
  no_secret_outputs = [ordered]@{
    raw_voucher_code = $false
    authorization = $false
    cookie = $false
    db_url = $false
    provider_key = $false
    virtual_key_secret = $false
  }
}

$summary | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $output.full -Encoding UTF8
$summary | ConvertTo-Json -Depth 40
if (-not $launchReady) {
  exit 1
}
