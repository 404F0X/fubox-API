param(
  [string]$FixturePath = "tests\fixtures\billing\payment_order_invoice_contract.json",
  [string]$OutputPath = ".tmp\credit-wallet\payment_order_invoice_contract.json"
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
$providerHandoffSafe = [bool]$fixture.secret_safe_contract.provider_reference_bounded -and
  [bool]$fixture.secret_safe_contract.provider_reference_redacted -and
  (-not [bool]$fixture.secret_safe_contract.raw_provider_secret_output_allowed) -and
  (-not [bool]$fixture.secret_safe_contract.client_secret_output_allowed) -and
  (-not [bool]$fixture.secret_safe_contract.raw_provider_payload_output_allowed)
$captureEffect = @($fixture.cases | Where-Object {
    [string]$_.name -eq "payment_confirm_paid" -and
    @($_.accounting_markers) -contains "credit_grant_row" -and
    @($_.accounting_markers) -contains "admin_adjustment_entry" -and
    @($_.accounting_markers) -contains "invoice_row" -and
    @($_.accounting_markers) -contains "receipt_row" -and
    @($_.accounting_markers) -contains "audit_log"
  }).Count -eq 1
$replayNoDuplicate = @($fixture.cases | Where-Object {
    ([string]$_.name -in @("payment_confirm_idempotent_replay", "payment_refund_idempotent_replay")) -and
    [bool]$_.same_idempotency_key -and
    [bool]$_.same_body -and
    (-not [bool]$_.new_credit_grant_row_written) -and
    (-not [bool]$_.new_ledger_entry_written) -and
    (-not [bool]$_.new_invoice_row_written) -and
    (-not [bool]$_.new_refund_row_written)
  }).Count -eq 2
$refusalsNoWrites = @($refusalCases | Where-Object {
    (-not [bool]$_.ledger_write_allowed) -and
    (-not [bool]$_.credit_grant_write_allowed) -and
    (-not [bool]$_.invoice_write_allowed) -and
    (-not [bool]$_.refund_write_allowed)
  }).Count -eq @($refusalCases).Count
$refundCancelMapping = @($fixture.cases | Where-Object {
    [string]$_.name -eq "payment_refund_applied" -and
    @($_.accounting_markers) -contains "credit_grant_revoke_row" -and
    @($_.accounting_markers) -contains "ledger_reversal_entry"
  }).Count -eq 1
$invoiceReceipt = @($fixture.cases | Where-Object {
    [string]$_.name -eq "invoice_issued_receipt" -and
    @($_.accounting_markers) -contains "invoice_row" -and
    @($_.accounting_markers) -contains "receipt_row" -and
    [string]$_.response.invoice_number -ne ""
  }).Count -eq 1
$reconciliation = @($fixture.cases | Where-Object {
    @($_.accounting_markers) -contains "reconciliation_marker" -and
    $null -ne $_.reconciliation -and
    [bool]$_.reconciliation.matched
  }).Count -ge 3
$secretSafe = Test-SecretSafeText ($fixture | ConvertTo-Json -Depth 64)

$runtimeImplemented = [bool]$fixture.runtime_implemented
$contractOnly = [bool]$fixture.contract_only
$paidGateChanged = [bool]$fixture.paid_gate_changed
$runtimeAcceptance = $fixture.runtime_acceptance_contract

$status = if (
  @($missingCases).Count -eq 0 -and
  $moneyDecimalStrings -and
  $providerHandoffSafe -and
  $captureEffect -and
  $replayNoDuplicate -and
  $refusalsNoWrites -and
  $refundCancelMapping -and
  $invoiceReceipt -and
  $reconciliation -and
  $secretSafe -and
  (-not $runtimeImplemented) -and
  $contractOnly -and
  (-not $paidGateChanged)
) {
  "pass"
} else {
  "fail"
}

$artifact = [ordered]@{
  schema = "payment_order_invoice_contract.v1"
  status = $status
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  test_name = "payment_order_invoice_contract_fixture_enforces_product_ledger_invariants"
  fixture_path = $fixturePathInfo.relative
  fixture_schema = [string]$fixture.schema
  fixture_status = [string]$fixture.status
  runtime_implemented = $runtimeImplemented
  contract_only = $contractOnly
  paid_gate_changed = $paidGateChanged
  secret_safe = [bool]$secretSafe
  contract_scope = @(
    "order_payment_invoice_lifecycle",
    "provider_handoff_bounded_redacted",
    "capture_success_credit_grant_or_ledger_effect",
    "idempotent_replay_no_duplicate_credit_invoice_refund",
    "payment_refusals_no_ledger_or_grant_or_invoice_write",
    "invoice_receipt_fixed_decimal_lines",
    "refund_cancel_reversal_mapping",
    "reconciliation_markers",
    "fixed_decimal_money_strings",
    "secret_safe_output"
  )
  cases = @($caseNames)
  missing_cases = @($missingCases)
  order_states = @(ConvertTo-StringArray $fixture.order_states)
  payment_states = @(ConvertTo-StringArray $fixture.payment_states)
  invoice_states = @(ConvertTo-StringArray $fixture.invoice_states)
  invariants_enforced = @(
    "order_created_pending_paid_cancelled_expired_refunded_failed",
    "payment_provider_handoff_reference_bounded_redacted",
    "capture_confirm_writes_credit_grant_or_ledger_marker_and_audit",
    "order_create_payment_confirm_refund_replay_does_not_duplicate_credit_invoice_refund",
    "amount_currency_provider_duplicate_non_positive_ownership_refusals",
    "refund_exceeds_captured_and_invoice_duplicate_refusals",
    "invoice_receipt_line_items_fixed_decimal_tax_currency",
    "refund_cancel_requires_grant_revoke_or_ledger_reversal",
    "reconciliation_payment_credit_invoice_ledger_amounts",
    "money_decimal_strings_no_float",
    "secret_safe_summary"
  )
  money_decimal_strings = [bool]$moneyDecimalStrings
  provider_handoff_secret_safe = [bool]$providerHandoffSafe
  capture_ledger_or_credit_effect_contract = [bool]$captureEffect
  replay_idempotency_contract = [bool]$replayNoDuplicate
  invoice_receipt_contract = [bool]$invoiceReceipt
  refusal_no_ledger_credit_invoice_refund_writes = [bool]$refusalsNoWrites
  refund_cancel_reversal_required = [bool]$refundCancelMapping
  reconciliation_contract = [bool]$reconciliation
  audit_required = [bool]$fixture.accounting_contract.audit_metadata_required
  direct_wallet_snapshot_mutation_forbidden = (-not [bool]$fixture.accounting_contract.direct_wallet_snapshot_mutation_allowed)
  runtime_acceptance_contract = [ordered]@{
    runtime_artifact_schema = [string]$runtimeAcceptance.runtime_artifact_schema
    runtime_artifact_path = [string]$runtimeAcceptance.runtime_artifact_path
    contract_artifact_must_not_mark_runtime_verified = [bool]$runtimeAcceptance.contract_artifact_must_not_mark_runtime_verified
    runtime_implemented_required = [bool]$runtimeAcceptance.runtime_implemented_required
    contract_only_required = [bool]$runtimeAcceptance.contract_only_required
    route_or_internal_runtime_invocation_required = [bool]$runtimeAcceptance.route_or_internal_runtime_invocation_required
    order_lifecycle_readback_required = [bool]$runtimeAcceptance.order_lifecycle_readback_required
    provider_handoff_redacted_readback_required = [bool]$runtimeAcceptance.provider_handoff_redacted_readback_required
    provider_callback_or_capture_readback_required = [bool]$runtimeAcceptance.provider_callback_or_capture_readback_required
    payment_confirm_capture_readback_required = [bool]$runtimeAcceptance.payment_confirm_capture_readback_required
    invoice_receipt_readback_required = [bool]$runtimeAcceptance.invoice_receipt_readback_required
    refund_cancel_chargeback_reversal_readback_required = [bool]$runtimeAcceptance.refund_cancel_chargeback_reversal_readback_required
    reconciliation_readback_required = [bool]$runtimeAcceptance.reconciliation_readback_required
    idempotency_replay_readback_required = [bool]$runtimeAcceptance.idempotency_replay_readback_required
    conflict_no_duplicate_write_readback_required = [bool]$runtimeAcceptance.conflict_no_duplicate_write_readback_required
    audit_readback_required = [bool]$runtimeAcceptance.audit_readback_required
    money_decimal_strings_required = [bool]$runtimeAcceptance.money_decimal_strings_required
    secret_safe_required = [bool]$runtimeAcceptance.secret_safe_required
    paid_gate_changed_required = [bool]$runtimeAcceptance.paid_gate_changed_required
    direct_wallet_snapshot_mutation_forbidden = [bool]$runtimeAcceptance.direct_wallet_snapshot_mutation_forbidden
    raw_provider_secret_output_allowed = [bool]$runtimeAcceptance.raw_provider_secret_output_allowed
    client_secret_output_allowed = [bool]$runtimeAcceptance.client_secret_output_allowed
    raw_provider_payload_output_allowed = [bool]$runtimeAcceptance.raw_provider_payload_output_allowed
    pii_output_allowed = [bool]$runtimeAcceptance.pii_output_allowed
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
