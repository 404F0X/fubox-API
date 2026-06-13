param(
  [string]$FixturePath = "tests\fixtures\billing\recharge_voucher_contract.json",
  [string]$OutputPath = ".tmp\credit-wallet\recharge_voucher_contract.json"
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

function Test-SecretSafeText {
  param([AllowNull()][string]$Text)

  if ([string]::IsNullOrEmpty($Text)) {
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
      'sk-[A-Za-z0-9]{8,}'
    )) {
    if ($Text -match $pattern) {
      return $false
    }
  }
  return $true
}

function ConvertTo-StringArray {
  param([AllowNull()]$Value)

  $items = [System.Collections.Generic.List[string]]::new()
  if ($null -eq $Value) {
    return @()
  }
  foreach ($entry in @($Value)) {
    if ($null -eq $entry) {
      continue
    }
    $text = ([string]$entry).Trim()
    if (-not [string]::IsNullOrWhiteSpace($text)) {
      [void]$items.Add($text)
    }
  }
  return @($items.ToArray())
}

$fixturePathInfo = Resolve-RepoBoundedPath `
  -Path $FixturePath `
  -AllowedPrefixes @("tests/fixtures/billing/")
$outputPathInfo = Resolve-RepoBoundedPath `
  -Path $OutputPath `
  -AllowedPrefixes @(".tmp/", "artifacts/")

if (-not (Test-Path -LiteralPath $fixturePathInfo.full -PathType Leaf)) {
  throw "fixture_missing"
}

$rawFixture = Get-Content -Raw -LiteralPath $fixturePathInfo.full
if (-not (Test-SecretSafeText $rawFixture)) {
  throw "fixture_secret_unsafe"
}
$fixture = $rawFixture | ConvertFrom-Json

$caseNames = @($fixture.cases | ForEach-Object { [string]$_.name })
$requiredCases = ConvertTo-StringArray $fixture.required_cases
$missingCases = @($requiredCases | Where-Object { $caseNames -notcontains $_ })
$refusalCases = @($fixture.cases | Where-Object { [string]$_.decision -eq "refused" })

$moneyDecimalStrings = ([string]$fixture.money_contract.format -eq "decimal_string_with_currency") -and
  (-not [bool]$fixture.money_contract.float_allowed) -and
  ([int]$fixture.money_contract.scale -eq 8)
$secretSafeHandling = (-not [bool]$fixture.secret_safe_contract.raw_voucher_code_output_allowed) -and
  [bool]$fixture.secret_safe_contract.voucher_code_hash_required -and
  [bool]$fixture.secret_safe_contract.voucher_code_redaction_required -and
  (-not [bool]$fixture.secret_safe_contract.raw_provider_payment_payload_output_allowed)
$abuseGuard = [bool]$fixture.abuse_guard_contract.redeem_attempts_bounded -and
  [bool]$fixture.abuse_guard_contract.failed_attempts_do_not_echo_code -and
  ([string]$fixture.abuse_guard_contract.rate_limit_refusal_code -eq "voucher_redeem_rate_limited")
$redeemEffect = @($fixture.cases | Where-Object {
    [string]$_.name -eq "voucher_redeem_success" -and
    @($_.accounting_markers) -contains "credit_grant_row" -and
    @($_.accounting_markers) -contains "admin_adjustment_entry" -and
    @($_.accounting_markers) -contains "audit_log"
  }).Count -eq 1
$replayNoDuplicate = @($fixture.cases | Where-Object {
    [string]$_.name -eq "voucher_redeem_idempotent_replay" -and
    [bool]$_.same_redeemer -and
    [bool]$_.same_idempotency_key -and
    [bool]$_.same_body -and
    (-not [bool]$_.new_credit_grant_row_written) -and
    (-not [bool]$_.new_ledger_entry_written)
  }).Count -eq 1
$refusalsNoWrites = @($refusalCases | Where-Object {
    (-not [bool]$_.ledger_write_allowed) -and (-not [bool]$_.credit_grant_write_allowed)
  }).Count -eq @($refusalCases).Count
$refundCancelMapping = @($fixture.cases | Where-Object {
    ([string]$_.name -in @("recharge_intent_refunded", "voucher_revoke_after_redeem_requires_reversal")) -and
    @($_.accounting_markers) -contains "credit_grant_revoke_row" -and
    @($_.accounting_markers) -contains "ledger_reversal_entry"
  }).Count -eq 2
$secretSafe = Test-SecretSafeText ($fixture | ConvertTo-Json -Depth 64)

$runtimeImplemented = [bool]$fixture.runtime_implemented
$contractOnly = [bool]$fixture.contract_only
$paidGateChanged = [bool]$fixture.paid_gate_changed
$runtimeAcceptance = $fixture.runtime_acceptance_contract
$runtimeFeasibility = $fixture.runtime_feasibility_plan
$missingPrimitiveNames = @($runtimeFeasibility.missing_primitives | ForEach-Object { [string]$_.primitive })
$reusablePrimitiveNames = @($runtimeFeasibility.reusable_primitives | ForEach-Object { [string]$_.primitive })
$runtimeFeasibilityReady = ([string]$runtimeFeasibility.status -eq "feasible_with_new_voucher_schema_and_control_plane_runtime") -and
  (-not [bool]$runtimeFeasibility.runtime_implemented) -and
  [bool]$runtimeFeasibility.contract_only -and
  (-not [bool]$runtimeFeasibility.paid_gate_changed) -and
  (-not [bool]$runtimeFeasibility.gateway_change_required) -and
  [bool]$runtimeFeasibility.control_plane_runtime_required -and
  [bool]$runtimeFeasibility.new_schema_required -and
  [bool]$runtimeFeasibility.external_payment_provider_required_for_recharge_capture -and
  ($reusablePrimitiveNames -contains "credit_grants") -and
  ($reusablePrimitiveNames -contains "ledger_entries_admin_adjustment") -and
  ($reusablePrimitiveNames -contains "audit_logs") -and
  ($missingPrimitiveNames -contains "voucher_campaigns_schema") -and
  ($missingPrimitiveNames -contains "voucher_issuances_schema") -and
  ($missingPrimitiveNames -contains "voucher_redemptions_schema") -and
  ($missingPrimitiveNames -contains "voucher_redeem_attempts_or_abuse_events_schema") -and
  ($missingPrimitiveNames -contains "payment_provider_handoff_and_callback_state")

$status = if (
  @($missingCases).Count -eq 0 -and
  $moneyDecimalStrings -and
  $secretSafeHandling -and
  $abuseGuard -and
  $redeemEffect -and
  $replayNoDuplicate -and
  $refusalsNoWrites -and
  $refundCancelMapping -and
  $secretSafe -and
  $runtimeFeasibilityReady -and
  (-not $runtimeImplemented) -and
  $contractOnly -and
  (-not $paidGateChanged)
) {
  "pass"
} else {
  "fail"
}

$artifact = [ordered]@{
  schema = "recharge_voucher_contract.v1"
  status = $status
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  test_name = "recharge_voucher_contract_fixture_enforces_product_ledger_invariants"
  fixture_path = $fixturePathInfo.relative
  fixture_schema = [string]$fixture.schema
  fixture_status = [string]$fixture.status
  runtime_implemented = $runtimeImplemented
  contract_only = $contractOnly
  paid_gate_changed = $paidGateChanged
  secret_safe = [bool]$secretSafe
  contract_scope = @(
    "recharge_intent_lifecycle",
    "voucher_issuance_hashed_redacted",
    "voucher_redeem_success_credit_grant_or_ledger_effect",
    "voucher_redeem_idempotent_replay_no_duplicate_credit",
    "voucher_redeem_refusals_no_ledger_or_grant_write",
    "abuse_rate_limit_guard",
    "refund_cancel_reversal_mapping",
    "fixed_decimal_money_strings",
    "secret_safe_output"
  )
  cases = @($caseNames)
  missing_cases = @($missingCases)
  recharge_lifecycle_states = @(ConvertTo-StringArray $fixture.recharge_lifecycle_states)
  voucher_lifecycle_states = @(ConvertTo-StringArray $fixture.voucher_lifecycle_states)
  invariants_enforced = @(
    "top_up_intent_created_pending_paid_cancelled_refunded",
    "voucher_code_hash_and_redaction_required",
    "redeem_success_writes_credit_grant_or_ledger_marker_and_audit",
    "same_redeemer_idempotent_replay_does_not_duplicate_credit",
    "same_code_different_user_or_over_max_redemption_refused",
    "expired_revoked_currency_non_positive_ownership_refused",
    "abuse_guard_bounded_attempts_no_raw_code_echo",
    "refund_cancel_requires_grant_revoke_or_ledger_reversal",
    "money_decimal_strings_no_float",
    "secret_safe_summary"
  )
  money_decimal_strings = [bool]$moneyDecimalStrings
  voucher_code_hashed_or_redacted = [bool]$secretSafeHandling
  redeem_idempotency_contract = [bool]$replayNoDuplicate
  abuse_guard_contract = [bool]$abuseGuard
  ledger_or_credit_effect_contract = [bool]$redeemEffect
  refusal_no_ledger_or_credit_grant_writes = [bool]$refusalsNoWrites
  refund_cancel_reversal_required = [bool]$refundCancelMapping
  audit_required = [bool]$fixture.accounting_contract.audit_metadata_required
  direct_wallet_snapshot_mutation_forbidden = (-not [bool]$fixture.accounting_contract.direct_wallet_snapshot_mutation_allowed)
  runtime_acceptance_contract = [ordered]@{
    runtime_artifact_schema = [string]$runtimeAcceptance.runtime_artifact_schema
    runtime_artifact_path = [string]$runtimeAcceptance.runtime_artifact_path
    contract_artifact_must_not_mark_runtime_verified = [bool]$runtimeAcceptance.contract_artifact_must_not_mark_runtime_verified
    runtime_implemented_required = [bool]$runtimeAcceptance.runtime_implemented_required
    contract_only_required = [bool]$runtimeAcceptance.contract_only_required
    route_or_internal_runtime_invocation_required = [bool]$runtimeAcceptance.route_or_internal_runtime_invocation_required
    voucher_storage_readback_required = [bool]$runtimeAcceptance.voucher_storage_readback_required
    voucher_code_hash_readback_required = [bool]$runtimeAcceptance.voucher_code_hash_readback_required
    voucher_code_redacted_output_required = [bool]$runtimeAcceptance.voucher_code_redacted_output_required
    redeem_readback_required = [bool]$runtimeAcceptance.redeem_readback_required
    redeem_idempotency_readback_required = [bool]$runtimeAcceptance.redeem_idempotency_readback_required
    abuse_refusal_no_write_readback_required = [bool]$runtimeAcceptance.abuse_refusal_no_write_readback_required
    ledger_or_credit_effect_readback_required = [bool]$runtimeAcceptance.ledger_or_credit_effect_readback_required
    refund_cancel_reversal_readback_required = [bool]$runtimeAcceptance.refund_cancel_reversal_readback_required
    audit_readback_required = [bool]$runtimeAcceptance.audit_readback_required
    secret_safe_required = [bool]$runtimeAcceptance.secret_safe_required
    paid_gate_changed_required = [bool]$runtimeAcceptance.paid_gate_changed_required
    direct_wallet_snapshot_mutation_forbidden = [bool]$runtimeAcceptance.direct_wallet_snapshot_mutation_forbidden
    raw_voucher_code_output_allowed = [bool]$runtimeAcceptance.raw_voucher_code_output_allowed
    raw_provider_payment_payload_output_allowed = [bool]$runtimeAcceptance.raw_provider_payment_payload_output_allowed
  }
  runtime_feasibility_plan = [ordered]@{
    status = [string]$runtimeFeasibility.status
    runtime_implemented = [bool]$runtimeFeasibility.runtime_implemented
    contract_only = [bool]$runtimeFeasibility.contract_only
    paid_gate_changed = [bool]$runtimeFeasibility.paid_gate_changed
    gateway_change_required = [bool]$runtimeFeasibility.gateway_change_required
    control_plane_runtime_required = [bool]$runtimeFeasibility.control_plane_runtime_required
    new_schema_required = [bool]$runtimeFeasibility.new_schema_required
    external_payment_provider_required_for_recharge_capture = [bool]$runtimeFeasibility.external_payment_provider_required_for_recharge_capture
    reusable_primitives = @($runtimeFeasibility.reusable_primitives | ForEach-Object {
        [ordered]@{
          primitive = [string]$_.primitive
          status = [string]$_.status
          usage = [string]$_.usage
        }
      })
    missing_primitives = @($runtimeFeasibility.missing_primitives | ForEach-Object {
        [ordered]@{
          primitive = [string]$_.primitive
          required = [bool]$_.required
          reason = [string]$_.reason
        }
      })
    proposed_slices = @($runtimeFeasibility.proposed_slices | ForEach-Object {
        [ordered]@{
          slice = [string]$_.slice
          owner = [string]$_.owner
          scope = [string]$_.scope
          requires_migration = [bool]$_.requires_migration
          runtime_acceptance = [bool]$_.runtime_acceptance
        }
      })
  }
  side_effects = [ordered]@{
    gateway_modified = $false
    control_plane_modified = $false
    admin_ui_modified = $false
    paid_artifacts_modified = $false
    network_io_performed = $false
    db_io_performed = $false
  }
  source = [ordered]@{
    fixture_path_output = "omitted"
    output_path_output = "omitted"
    raw_fixture_output = "omitted"
  }
}

$outputDirectory = Split-Path -Parent $outputPathInfo.full
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
  New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
}
$artifact | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $outputPathInfo.full -Encoding UTF8
$artifact | ConvertTo-Json -Depth 16

if ($status -ne "pass") {
  exit 2
}
exit 0
