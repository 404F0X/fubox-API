param(
  [string]$OutputPath = ".tmp\launch\voucher_backed_api_distribution_accounting_gate.json",
  [string]$RechargeVoucherRuntimePath = ".tmp\credit-wallet\recharge_voucher_runtime.json",
  [string]$UserRemainingBalanceRuntimePath = ".tmp\credit-wallet\user_remaining_balance_ownership_runtime.json",
  [string]$CreditGrantCrudRuntimePath = ".tmp\credit-wallet\credit_grant_crud_runtime.json",
  [string]$OpeningBalanceImportRuntimePath = ".tmp\credit-wallet\opening_balance_import_runtime.json",
  [string]$GatewayPaidHotPathPath = ".tmp\paid-beta\e8_gateway_paid_hot_path.json",
  [string]$RealPaidEvidenceBundlePath = ".tmp\paid-beta\real_paid_evidence_bundle.json",
  [string]$GatewayVoucherDistributionReadinessPath = ".tmp\launch\gateway_voucher_distribution_readiness.json",
  [string]$GatewayPaidHotPathLaunchCheckPath = ".tmp\launch\e8_gateway_paid_hot_path_launch_check.json",
  [switch]$SelfTest
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
      path = $resolved.relative
      exists = $false
      json = $null
    }
  }
  try {
    return [ordered]@{
      path = $resolved.relative
      exists = $true
      json = ((Get-Content -Raw -LiteralPath $resolved.full) | ConvertFrom-Json)
    }
  } catch {
    return [ordered]@{
      path = $resolved.relative
      exists = $true
      json = $null
      parse_error = "json_parse_failed"
    }
  }
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
  if ($text -in @("true", "1", "yes", "passed", "pass")) { return $true }
  if ($text -in @("false", "0", "no", "blocked", "failed")) { return $false }
  return $Default
}

function Test-SecretSafeText {
  param([AllowNull()][string]$Text)

  if ([string]::IsNullOrWhiteSpace($Text)) {
    return $true
  }
  foreach ($pattern in @(
      '(?i)authorization\s*[:=]',
      '(?i)bearer\s+[A-Za-z0-9._~+/\-]+=*',
      '(?i)api[_-]?key\s*[:=]',
      '(?i)provider[_-]?key\s*[:=]',
      '(?i)virtual[_-]?key\s*[:=]',
      '(?i)database[_-]?url\s*[:=]',
      '(?i)postgres(?:ql)?://[^"\s]+',
      '(?i)password\s*[:=]',
      '(?i)client[_-]?secret\s*[:=]',
      'sk-[A-Za-z0-9]{8,}'
    )) {
    if ($Text -match $pattern) {
      return $false
    }
  }
  return $true
}

function Has-AnyTruthyField {
  param(
    [AllowNull()][object]$Json,
    [Parameter(Mandatory = $true)][string[]]$Names
  )

  if ($null -eq $Json) { return $false }
  foreach ($name in $Names) {
    if (Get-JsonBool -Json $Json -Name $name) {
      return $true
    }
    if ($Json.PSObject.Properties.Name -contains "checks") {
      if (Get-JsonBool -Json $Json.checks -Name $name) {
        return $true
      }
    }
    if ($Json.PSObject.Properties.Name -contains "readback") {
      if (Get-JsonBool -Json $Json.readback -Name $name) {
        return $true
      }
    }
  }
  return $false
}

function Test-ArtifactSecretSafe {
  param([AllowNull()][object]$Json)

  if ($null -eq $Json) { return $false }
  $textSafe = Test-SecretSafeText ($Json | ConvertTo-Json -Depth 32)
  if (-not $textSafe) { return $false }

  if ($Json.PSObject.Properties.Name -contains "secret_safe") {
    $value = $Json.PSObject.Properties["secret_safe"].Value
    if ($value -is [bool]) { return [bool]$value }
    if ($null -ne $value -and $value.PSObject.Properties.Name -contains "raw_secret_present") {
      return [bool](
        -not (Get-JsonBool -Json $value -Name "raw_secret_present") -and
        -not (Get-JsonBool -Json $value -Name "credential_material_echoed") -and
        -not (Get-JsonBool -Json $value -Name "database_url_echoed") -and
        -not (Get-JsonBool -Json $value -Name "env_value_echoed")
      )
    }
  }

  if ($Json.PSObject.Properties.Name -contains "secret_safety") {
    $value = $Json.PSObject.Properties["secret_safety"].Value
    return [bool](
      -not (Get-JsonBool -Json $value -Name "raw_or_secret_marker_present") -and
      -not (Get-JsonBool -Json $value -Name "raw_secret_present") -and
      -not (Get-JsonBool -Json $value -Name "credential_material_echoed") -and
      -not (Get-JsonBool -Json $value -Name "database_url_echoed")
    )
  }

  return $true
}

function New-SummaryFromArtifact {
  param(
    [Parameter(Mandatory = $true)][object]$Artifact,
    [string[]]$KeepFields = @()
  )

  $json = $Artifact.json
  $summary = [ordered]@{
    path = $Artifact.path
    exists = [bool]$Artifact.exists
    schema = Get-JsonString -Json $json -Name "schema"
    schema_version = Get-JsonString -Json $json -Name "schema_version"
    status = Get-JsonString -Json $json -Name "status"
    overall_status = Get-JsonString -Json $json -Name "overall_status"
    runtime_implemented = Get-JsonBool -Json $json -Name "runtime_implemented"
    contract_only = Get-JsonBool -Json $json -Name "contract_only"
    secret_safe = Test-ArtifactSecretSafe -Json $json
    paid_gate_changed = Get-JsonBool -Json $json -Name "paid_gate_changed"
  }
  foreach ($field in $KeepFields) {
    $summary[$field] = Get-JsonBool -Json $json -Name $field
  }
  return $summary
}

function New-GateResult {
  param(
    [Parameter(Mandatory = $true)][object]$Recharge,
    [Parameter(Mandatory = $true)][object]$Balance,
    [Parameter(Mandatory = $true)][object]$CreditGrant,
    [Parameter(Mandatory = $true)][object]$OpeningImport,
    [Parameter(Mandatory = $true)][object]$Gateway,
    [Parameter(Mandatory = $true)][object]$Bundle,
    [Parameter(Mandatory = $true)][object]$GatewayLaunchReadiness,
    [Parameter(Mandatory = $true)][object]$GatewayLaunchCheck
  )

  $accountingBlockers = [System.Collections.Generic.List[string]]::new()
  $launchBlockers = [System.Collections.Generic.List[string]]::new()
  $deferred = [System.Collections.Generic.List[string]]::new()

  $rechargeJson = $Recharge.json
  $balanceJson = $Balance.json
  $creditGrantJson = $CreditGrant.json
  $openingJson = $OpeningImport.json
  $gatewayJson = $Gateway.json
  $bundleJson = $Bundle.json
  $gatewayLaunchReadinessJson = $GatewayLaunchReadiness.json
  $gatewayLaunchCheckJson = $GatewayLaunchCheck.json

  $voucherRuntimeVerified = [bool](
    $Recharge.exists -and
    (Get-JsonString -Json $rechargeJson -Name "schema") -eq "recharge_voucher_runtime.v1" -and
    (Get-JsonString -Json $rechargeJson -Name "overall_status") -eq "pass" -and
    (Get-JsonBool -Json $rechargeJson -Name "runtime_implemented") -and
    -not (Get-JsonBool -Json $rechargeJson -Name "contract_only" -Default $true) -and
    (Get-JsonBool -Json $rechargeJson -Name "secret_safe") -and
    -not (Get-JsonBool -Json $rechargeJson -Name "paid_gate_changed" -Default $true)
  )
  if (-not $voucherRuntimeVerified) { [void]$accountingBlockers.Add("voucher_runtime_not_verified") }

  $ledgerOrCreditEffectVerified = [bool](
    $voucherRuntimeVerified -and
    (Has-AnyTruthyField -Json $rechargeJson -Names @("ledger_or_credit_readback_passed", "ledger_or_credit_effect_contract", "credit_grant_effect_readback_passed", "ledger_effect_readback_passed")) -and
    (
      (Get-JsonString -Json $rechargeJson -Name "credit_grant_id").Length -gt 0 -or
      (Get-JsonString -Json $rechargeJson -Name "ledger_entry_id").Length -gt 0
    )
  )
  if (-not $ledgerOrCreditEffectVerified) { [void]$accountingBlockers.Add("voucher_ledger_or_credit_effect_not_verified") }

  $remainingBalanceRuntimeVerified = [bool](
    $Balance.exists -and
    (Get-JsonString -Json $balanceJson -Name "schema") -eq "user_remaining_balance_runtime.v1" -and
    (Get-JsonString -Json $balanceJson -Name "overall_status") -eq "pass" -and
    (Get-JsonBool -Json $balanceJson -Name "runtime_implemented") -and
    -not (Get-JsonBool -Json $balanceJson -Name "contract_only" -Default $true) -and
    (Get-JsonBool -Json $balanceJson -Name "secret_safe") -and
    -not (Get-JsonBool -Json $balanceJson -Name "paid_gate_changed" -Default $true) -and
    (Has-AnyTruthyField -Json $balanceJson -Names @("wallet_readback_passed", "credit_grants_readback_passed", "ledger_window_readback_passed", "ownership_scope_verified"))
  )
  if (-not $remainingBalanceRuntimeVerified) { [void]$accountingBlockers.Add("remaining_balance_runtime_not_verified") }

  $creditGrantCrudRuntimeVerified = [bool](
    $CreditGrant.exists -and
    (Get-JsonString -Json $creditGrantJson -Name "schema") -eq "credit_grant_crud_runtime.v1" -and
    (Get-JsonString -Json $creditGrantJson -Name "overall_status") -eq "pass" -and
    (Get-JsonBool -Json $creditGrantJson -Name "runtime_implemented") -and
    -not (Get-JsonBool -Json $creditGrantJson -Name "contract_only" -Default $true) -and
    (Get-JsonBool -Json $creditGrantJson -Name "secret_safe") -and
    -not (Get-JsonBool -Json $creditGrantJson -Name "paid_gate_changed" -Default $true)
  )
  if (-not $creditGrantCrudRuntimeVerified) { [void]$accountingBlockers.Add("credit_grant_crud_runtime_not_verified") }

  $openingBalanceImportRuntimeVerified = [bool](
    $OpeningImport.exists -and
    (Get-JsonString -Json $openingJson -Name "schema") -eq "opening_balance_import_runtime.v1" -and
    (Get-JsonString -Json $openingJson -Name "overall_status") -eq "pass" -and
    (Get-JsonBool -Json $openingJson -Name "runtime_implemented") -and
    -not (Get-JsonBool -Json $openingJson -Name "contract_only" -Default $true) -and
    (Get-JsonBool -Json $openingJson -Name "secret_safe") -and
    -not (Get-JsonBool -Json $openingJson -Name "paid_gate_changed" -Default $true)
  )
  if (-not $openingBalanceImportRuntimeVerified) { [void]$accountingBlockers.Add("opening_balance_import_runtime_not_verified") }

  $gatewayPaidHotPathPresent = [bool](
    $Gateway.exists -and
    ((Get-JsonString -Json $gatewayJson -Name "schema") -eq "gateway_paid_hot_path_smoke_v1" -or (Get-JsonString -Json $gatewayJson -Name "schema_version") -eq "gateway_paid_hot_path_smoke_v1") -and
    (Get-JsonString -Json $gatewayJson -Name "status") -eq "passed" -and
    (Test-ArtifactSecretSafe -Json $gatewayJson)
  )
  if (-not $gatewayPaidHotPathPresent) { [void]$accountingBlockers.Add("gateway_paid_hot_path_not_present") }

  $realPaidEvidenceBundleAccepted = [bool](
    $Bundle.exists -and
    ((Get-JsonString -Json $bundleJson -Name "schema") -eq "billing_paid_strong_consistency_evidence_bundle.v1" -or (Get-JsonString -Json $bundleJson -Name "schema_version") -eq "billing_paid_strong_consistency_evidence_bundle.v1") -and
    (Get-JsonBool -Json $bundleJson -Name "paid_controlled_beta_production_ready") -and
    -not (Get-JsonBool -Json $bundleJson -Name "contract_shape_only" -Default $true) -and
    (
      (Get-JsonBool -Json $bundleJson -Name "non_synthetic") -or
      -not (Get-JsonBool -Json $bundleJson -Name "synthetic" -Default $false) -and -not (Get-JsonBool -Json $bundleJson -Name "synthetic_selftest" -Default $false)
    ) -and
    (Test-ArtifactSecretSafe -Json $bundleJson)
  )
  if (-not $realPaidEvidenceBundleAccepted) { [void]$accountingBlockers.Add("real_paid_evidence_bundle_not_accepted") }

  $directWalletSnapshotMutationForbidden = [bool](
    (Has-AnyTruthyField -Json $rechargeJson -Names @("direct_wallet_snapshot_mutation_forbidden")) -and
    (Has-AnyTruthyField -Json $balanceJson -Names @("read_only", "direct_wallet_snapshot_mutation_forbidden")) -and
    (Has-AnyTruthyField -Json $creditGrantJson -Names @("direct_wallet_snapshot_mutation_forbidden")) -and
    (Has-AnyTruthyField -Json $openingJson -Names @("direct_wallet_snapshot_mutation_forbidden"))
  )
  if (-not $directWalletSnapshotMutationForbidden) { [void]$accountingBlockers.Add("direct_wallet_snapshot_mutation_contract_not_verified") }

  $artifactText = (@($Recharge, $Balance, $CreditGrant, $OpeningImport, $Gateway, $Bundle) | ForEach-Object {
      if ($_.exists -and $null -ne $_.json) { $_.json | ConvertTo-Json -Depth 32 } else { "" }
    }) -join "`n"
  $gatewayLaunchText = (@($GatewayLaunchReadiness, $GatewayLaunchCheck) | ForEach-Object {
      if ($_.exists -and $null -ne $_.json) { $_.json | ConvertTo-Json -Depth 32 } else { "" }
    }) -join "`n"
  $secretSafe = [bool](
    (Test-SecretSafeText $artifactText) -and
    (Test-SecretSafeText $gatewayLaunchText) -and
    (Test-ArtifactSecretSafe -Json $rechargeJson) -and
    (Test-ArtifactSecretSafe -Json $balanceJson) -and
    (Test-ArtifactSecretSafe -Json $creditGrantJson) -and
    (Test-ArtifactSecretSafe -Json $openingJson) -and
    (Test-ArtifactSecretSafe -Json $gatewayJson) -and
    (Test-ArtifactSecretSafe -Json $bundleJson) -and
    (-not $GatewayLaunchReadiness.exists -or (Test-ArtifactSecretSafe -Json $gatewayLaunchReadinessJson)) -and
    (-not $GatewayLaunchCheck.exists -or (Test-ArtifactSecretSafe -Json $gatewayLaunchCheckJson))
  )
  if (-not $secretSafe) { [void]$accountingBlockers.Add("secret_safety_not_verified") }

  $gatewayLaunchArtifactPresent = [bool]($GatewayLaunchReadiness.exists -or $GatewayLaunchCheck.exists)
  $gatewayReadinessLiveVerified = $false
  if ($GatewayLaunchReadiness.exists -and $null -ne $gatewayLaunchReadinessJson -and $gatewayLaunchReadinessJson.PSObject.Properties.Name -contains "paid_hot_path_verified") {
    $gatewayReadinessLiveVerified = Get-JsonBool -Json $gatewayLaunchReadinessJson.paid_hot_path_verified -Name "current_launch_live_verified"
  }
  $gatewayLaunchCheckPassed = [bool](
    $GatewayLaunchCheck.exists -and
    (Get-JsonString -Json $gatewayLaunchCheckJson -Name "schema") -eq "gateway_paid_hot_path_smoke_v1" -and
    (Get-JsonString -Json $gatewayLaunchCheckJson -Name "status") -eq "passed" -and
    (Test-ArtifactSecretSafe -Json $gatewayLaunchCheckJson)
  )
  $gatewayCurrentEnforcementVerified = [bool]($gatewayReadinessLiveVerified -or $gatewayLaunchCheckPassed)
  $gatewayEnforcementRequiredForLaunch = $true
  $blocksApiDistributionUntilGatewayPass = [bool](-not $gatewayCurrentEnforcementVerified)
  if (-not $gatewayLaunchArtifactPresent) {
    [void]$launchBlockers.Add("gateway_launch_enforcement_artifact_missing")
  } elseif ($blocksApiDistributionUntilGatewayPass) {
    [void]$launchBlockers.Add("current_paid_live_smoke_insufficient_balance_gate_not_proven")
  }

  [void]$deferred.Add("payment_order_invoice_deferred")
  [void]$deferred.Add("subscription_lifecycle_deferred")

  $corePass = [bool](
    $voucherRuntimeVerified -and
    $ledgerOrCreditEffectVerified -and
    $remainingBalanceRuntimeVerified -and
    $creditGrantCrudRuntimeVerified -and
    $openingBalanceImportRuntimeVerified -and
    $gatewayPaidHotPathPresent -and
    $realPaidEvidenceBundleAccepted -and
    $directWalletSnapshotMutationForbidden -and
    $secretSafe
  )

  $launchReady = [bool]($corePass -and -not $blocksApiDistributionUntilGatewayPass)
  $status = if ($launchReady) {
    "launch_ready_with_productization_gaps"
  } elseif ($corePass -and $blocksApiDistributionUntilGatewayPass) {
    "blocked_by_gateway_enforcement"
  } else {
    "blocked"
  }
  $accountingVerdict = if ($corePass) { "acceptable_with_productization_gaps" } else { "blocked" }
  $exitCode = if ($launchReady) { 0 } else { 2 }

  return [ordered]@{
    schema = "voucher_backed_api_distribution_accounting_gate.v1"
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    overall_status = $status
    accounting_verdict = $accountingVerdict
    actual_exit_code = $exitCode
    accounting_credit_acceptable = $corePass
    api_distribution_launch_ready = $launchReady
    voucher_backed_quota_distributable_beta_credit = $corePass
    voucher_runtime_verified = $voucherRuntimeVerified
    ledger_or_credit_effect_verified = $ledgerOrCreditEffectVerified
    remaining_balance_runtime_verified = $remainingBalanceRuntimeVerified
    credit_grant_crud_runtime_verified = $creditGrantCrudRuntimeVerified
    opening_balance_import_runtime_verified = $openingBalanceImportRuntimeVerified
    gateway_paid_hot_path_present = $gatewayPaidHotPathPresent
    real_paid_evidence_bundle_accepted = $realPaidEvidenceBundleAccepted
    direct_wallet_snapshot_mutation_forbidden = $directWalletSnapshotMutationForbidden
    secret_safe = $secretSafe
    payment_order_invoice_deferred = $true
    subscription_lifecycle_deferred = $true
    gateway_enforcement_required_for_launch = $gatewayEnforcementRequiredForLaunch
    gateway_current_enforcement_verified = $gatewayCurrentEnforcementVerified
    blocks_api_distribution_until_gateway_pass = $blocksApiDistributionUntilGatewayPass
    controlled_paid_beta_reopened = $false
    gateway_modified = $false
    payment_provider_required_for_this_gate = $false
    subscription_scheduler_required_for_this_gate = $false
    evidence = [ordered]@{
      recharge_voucher_runtime = New-SummaryFromArtifact -Artifact $Recharge
      user_remaining_balance_runtime = New-SummaryFromArtifact -Artifact $Balance
      credit_grant_crud_runtime = New-SummaryFromArtifact -Artifact $CreditGrant
      opening_balance_import_runtime = New-SummaryFromArtifact -Artifact $OpeningImport
      gateway_paid_hot_path = New-SummaryFromArtifact -Artifact $Gateway
      real_paid_evidence_bundle = New-SummaryFromArtifact -Artifact $Bundle -KeepFields @("paid_controlled_beta_production_ready", "contract_shape_only", "synthetic")
      gateway_voucher_distribution_readiness = New-SummaryFromArtifact -Artifact $GatewayLaunchReadiness
      e8_gateway_paid_hot_path_launch_check = New-SummaryFromArtifact -Artifact $GatewayLaunchCheck
    }
    deferred_items = @(
      [ordered]@{
        item = "payment_order_invoice"
        status = "deferred_runtime_external_dependency"
        blocker = "provider_callback_or_approved_bounded_internal_policy_and_invoice_reconciliation_readbacks_missing"
        blocks_voucher_backed_api_distribution = $false
      },
      [ordered]@{
        item = "subscription_package_lifecycle"
        status = "deferred_runtime_external_dependency"
        blocker = "scheduler_provider_dunning_and_subscription_lifecycle_readbacks_missing"
        blocks_voucher_backed_api_distribution = $false
      }
    )
    accounting_blockers = @($accountingBlockers)
    launch_blockers = @($launchBlockers)
    blockers = @($accountingBlockers) + @($launchBlockers)
    resume_conditions = @(
      "keep_recharge_voucher_runtime_verified_true",
      "keep_user_remaining_balance_runtime_verified_true",
      "keep_credit_grant_crud_runtime_verified_true",
      "keep_gateway_paid_hot_path_and_real_paid_bundle_accepted",
      "do_not_mutate_wallet_snapshot_as_accounting_truth",
      "rerun_e8_gateway_paid_hot_path_launch_check_until_insufficient_balance_returns_402_and_provider_attempt_rows_0",
      "for_full_commercial_launch_resume_payment_order_invoice_runtime",
      "for_subscription_launch_resume_subscription_package_lifecycle_runtime"
    )
  }
}

function Write-GateArtifact {
  param(
    [Parameter(Mandatory = $true)][object]$Artifact,
    [Parameter(Mandatory = $true)][string]$Path
  )

  $resolved = Resolve-RepoBoundedPath -Path $Path -AllowedPrefixes @(".tmp/launch/", "artifacts/")
  $dir = Split-Path -Parent $resolved.full
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  $Artifact | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $resolved.full -Encoding UTF8
  return $resolved
}

if ($SelfTest) {
  $runtimePass = [pscustomobject]@{
    schema = "recharge_voucher_runtime.v1"
    overall_status = "pass"
    runtime_implemented = $true
    contract_only = $false
    secret_safe = $true
    paid_gate_changed = $false
    credit_grant_id = "grant-test"
    ledger_entry_id = "ledger-test"
    checks = [pscustomobject]@{
      ledger_or_credit_readback_passed = $true
      direct_wallet_snapshot_mutation_forbidden = $true
    }
  }
  $balancePass = [pscustomobject]@{
    schema = "user_remaining_balance_runtime.v1"
    overall_status = "pass"
    runtime_implemented = $true
    contract_only = $false
    secret_safe = $true
    paid_gate_changed = $false
    checks = [pscustomobject]@{
      wallet_readback_passed = $true
      credit_grants_readback_passed = $true
      ledger_window_readback_passed = $true
      ownership_scope_verified = $true
      read_only = $true
    }
  }
  $creditPass = [pscustomobject]@{
    schema = "credit_grant_crud_runtime.v1"
    overall_status = "pass"
    runtime_implemented = $true
    contract_only = $false
    secret_safe = $true
    paid_gate_changed = $false
    checks = [pscustomobject]@{ direct_wallet_snapshot_mutation_forbidden = $true }
  }
  $openingPass = [pscustomobject]@{
    schema = "opening_balance_import_runtime.v1"
    overall_status = "pass"
    runtime_implemented = $true
    contract_only = $false
    secret_safe = $true
    paid_gate_changed = $false
    checks = [pscustomobject]@{ direct_wallet_snapshot_mutation_forbidden = $true }
  }
  $gatewayPass = [pscustomobject]@{
    schema = "gateway_paid_hot_path_smoke_v1"
    status = "passed"
    secret_safe = $true
  }
  $gatewayLaunchReadinessPass = [pscustomobject]@{
    schema = "gateway_voucher_distribution_readiness_v1"
    status = "pass"
    paid_hot_path_verified = [pscustomobject]@{
      current_launch_live_verified = $true
    }
    secret_safe = [pscustomobject]@{
      raw_virtual_key_omitted = $true
      auth_token_omitted = $true
      provider_secret_omitted = $true
      database_url_omitted = $true
      raw_request_body_omitted = $true
    }
  }
  $gatewayLaunchReadinessBlocked = [pscustomobject]@{
    schema = "gateway_voucher_distribution_readiness_v1"
    status = "blocked_current_runtime_paid_balance_gate_not_proven"
    paid_hot_path_verified = [pscustomobject]@{
      current_launch_live_verified = $false
    }
    secret_safe = [pscustomobject]@{
      raw_virtual_key_omitted = $true
      auth_token_omitted = $true
      provider_secret_omitted = $true
      database_url_omitted = $true
      raw_request_body_omitted = $true
    }
  }
  $gatewayLaunchCheckPass = [pscustomobject]@{
    schema = "gateway_paid_hot_path_smoke_v1"
    status = "passed"
    secret_safe = [pscustomobject]@{
      auth_token_omitted = $true
      provider_secret_omitted = $true
      database_url_omitted = $true
      raw_request_body_omitted = $true
    }
  }
  $gatewayLaunchCheckBlocked = [pscustomobject]@{
    schema = "gateway_paid_hot_path_smoke_v1"
    status = "blocked"
    secret_safe = [pscustomobject]@{
      auth_token_omitted = $true
      provider_secret_omitted = $true
      database_url_omitted = $true
      raw_request_body_omitted = $true
    }
  }
  $bundlePass = [pscustomobject]@{
    schema = "billing_paid_strong_consistency_evidence_bundle.v1"
    paid_controlled_beta_production_ready = $true
    contract_shape_only = $false
    synthetic = $false
    secret_safe = $true
  }

  $wrap = {
    param($path, $json)
    [ordered]@{ path = $path; exists = $true; json = $json }
  }

  $positive = New-GateResult `
    -Recharge (& $wrap "positive/recharge.json" $runtimePass) `
    -Balance (& $wrap "positive/balance.json" $balancePass) `
    -CreditGrant (& $wrap "positive/credit.json" $creditPass) `
    -OpeningImport (& $wrap "positive/opening.json" $openingPass) `
    -Gateway (& $wrap "positive/gateway.json" $gatewayPass) `
    -Bundle (& $wrap "positive/bundle.json" $bundlePass) `
    -GatewayLaunchReadiness (& $wrap "positive/gateway_launch_readiness.json" $gatewayLaunchReadinessPass) `
    -GatewayLaunchCheck (& $wrap "positive/gateway_launch_check.json" $gatewayLaunchCheckPass)

  $gatewayBlocked = New-GateResult `
    -Recharge (& $wrap "positive/recharge.json" $runtimePass) `
    -Balance (& $wrap "positive/balance.json" $balancePass) `
    -CreditGrant (& $wrap "positive/credit.json" $creditPass) `
    -OpeningImport (& $wrap "positive/opening.json" $openingPass) `
    -Gateway (& $wrap "positive/gateway.json" $gatewayPass) `
    -Bundle (& $wrap "positive/bundle.json" $bundlePass) `
    -GatewayLaunchReadiness (& $wrap "blocked/gateway_launch_readiness.json" $gatewayLaunchReadinessBlocked) `
    -GatewayLaunchCheck (& $wrap "blocked/gateway_launch_check.json" $gatewayLaunchCheckBlocked)

  $missingVoucher = New-GateResult `
    -Recharge ([ordered]@{ path = "missing/recharge.json"; exists = $false; json = $null }) `
    -Balance (& $wrap "positive/balance.json" $balancePass) `
    -CreditGrant (& $wrap "positive/credit.json" $creditPass) `
    -OpeningImport (& $wrap "positive/opening.json" $openingPass) `
    -Gateway (& $wrap "positive/gateway.json" $gatewayPass) `
    -Bundle (& $wrap "positive/bundle.json" $bundlePass) `
    -GatewayLaunchReadiness (& $wrap "positive/gateway_launch_readiness.json" $gatewayLaunchReadinessPass) `
    -GatewayLaunchCheck (& $wrap "positive/gateway_launch_check.json" $gatewayLaunchCheckPass)

  $secretUnsafe = [pscustomobject]@{
    schema = "recharge_voucher_runtime.v1"
    overall_status = "pass"
    runtime_implemented = $true
    contract_only = $false
    secret_safe = $true
    paid_gate_changed = $false
    credit_grant_id = "grant-test"
    ledger_entry_id = "ledger-test"
    metadata = "Authorization: Bearer should-not-pass"
    checks = [pscustomobject]@{
      ledger_or_credit_readback_passed = $true
      direct_wallet_snapshot_mutation_forbidden = $true
    }
  }
  $secretUnsafeResult = New-GateResult `
    -Recharge (& $wrap "unsafe/recharge.json" $secretUnsafe) `
    -Balance (& $wrap "positive/balance.json" $balancePass) `
    -CreditGrant (& $wrap "positive/credit.json" $creditPass) `
    -OpeningImport (& $wrap "positive/opening.json" $openingPass) `
    -Gateway (& $wrap "positive/gateway.json" $gatewayPass) `
    -Bundle (& $wrap "positive/bundle.json" $bundlePass) `
    -GatewayLaunchReadiness (& $wrap "positive/gateway_launch_readiness.json" $gatewayLaunchReadinessPass) `
    -GatewayLaunchCheck (& $wrap "positive/gateway_launch_check.json" $gatewayLaunchCheckPass)

  $selfTestPass = [bool](
    $positive.actual_exit_code -eq 0 -and
    $positive.api_distribution_launch_ready -and
    $positive.voucher_backed_quota_distributable_beta_credit -and
    $positive.payment_order_invoice_deferred -and
    $positive.subscription_lifecycle_deferred -and
    $gatewayBlocked.actual_exit_code -eq 2 -and
    $gatewayBlocked.accounting_credit_acceptable -and
    -not $gatewayBlocked.api_distribution_launch_ready -and
    ($gatewayBlocked.launch_blockers -contains "current_paid_live_smoke_insufficient_balance_gate_not_proven") -and
    $missingVoucher.actual_exit_code -eq 2 -and
    ($missingVoucher.blockers -contains "voucher_runtime_not_verified") -and
    $secretUnsafeResult.actual_exit_code -eq 2 -and
    ($secretUnsafeResult.blockers -contains "secret_safety_not_verified")
  )

  [ordered]@{
    schema = "voucher_backed_api_distribution_accounting_gate_selftest.v1"
    status = if ($selfTestPass) { "pass" } else { "fail" }
    actual_exit_code = if ($selfTestPass) { 0 } else { 1 }
    positive_passed = [bool]($positive.actual_exit_code -eq 0)
    gateway_blocked_preserves_accounting = [bool]($gatewayBlocked.accounting_credit_acceptable -and -not $gatewayBlocked.api_distribution_launch_ready)
    missing_voucher_rejected = [bool]($missingVoucher.blockers -contains "voucher_runtime_not_verified")
    secret_unsafe_rejected = [bool]($secretUnsafeResult.blockers -contains "secret_safety_not_verified")
  } | ConvertTo-Json -Depth 16
  if ($selfTestPass) { exit 0 }
  exit 1
}

$result = New-GateResult `
  -Recharge (Read-JsonArtifact -Path $RechargeVoucherRuntimePath) `
  -Balance (Read-JsonArtifact -Path $UserRemainingBalanceRuntimePath) `
  -CreditGrant (Read-JsonArtifact -Path $CreditGrantCrudRuntimePath) `
  -OpeningImport (Read-JsonArtifact -Path $OpeningBalanceImportRuntimePath) `
  -Gateway (Read-JsonArtifact -Path $GatewayPaidHotPathPath) `
  -Bundle (Read-JsonArtifact -Path $RealPaidEvidenceBundlePath) `
  -GatewayLaunchReadiness (Read-JsonArtifact -Path $GatewayVoucherDistributionReadinessPath) `
  -GatewayLaunchCheck (Read-JsonArtifact -Path $GatewayPaidHotPathLaunchCheckPath)

$written = Write-GateArtifact -Artifact $result -Path $OutputPath
$result["artifact_path"] = $written.relative
$result | ConvertTo-Json -Depth 32
exit ([int]$result.actual_exit_code)
