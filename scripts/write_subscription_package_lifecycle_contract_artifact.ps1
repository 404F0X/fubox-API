param(
  [string]$FixturePath = "tests\fixtures\billing\subscription_package_lifecycle_contract.json",
  [string]$OutputPath = ".tmp\credit-wallet\subscription_package_lifecycle_contract.json"
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
$secretContract = (-not [bool]$fixture.secret_safe_contract.raw_provider_payload_output_allowed) -and
  (-not [bool]$fixture.secret_safe_contract.raw_plan_payload_output_allowed) -and
  (-not [bool]$fixture.secret_safe_contract.token_output_allowed) -and
  (-not [bool]$fixture.secret_safe_contract.voucher_or_code_output_allowed)
$creditEffect = @($fixture.cases | Where-Object {
    ([string]$_.name -in @("subscription_created_trial", "subscription_active_credit_issued", "subscription_renewed", "subscription_proration_applied")) -and
    @($_.accounting_markers) -contains "credit_grant_row" -and
    @($_.accounting_markers) -contains "reconciliation_marker"
  }).Count -eq 4
$invoiceOrderLinkage = @($fixture.cases | Where-Object {
    ([string]$_.name -in @("trial_end_activates_subscription", "subscription_active_credit_issued", "subscription_renewed")) -and
    @($_.accounting_markers) -contains "invoice_link" -and
    @($_.accounting_markers) -contains "order_link"
  }).Count -eq 3
$replayNoDuplicate = @($fixture.cases | Where-Object {
    [string]$_.name -eq "subscription_create_idempotent_replay" -and
    [bool]$_.same_idempotency_key -and
    [bool]$_.same_body -and
    (-not [bool]$_.new_subscription_row_written) -and
    (-not [bool]$_.new_credit_grant_row_written) -and
    (-not [bool]$_.new_ledger_entry_written) -and
    (-not [bool]$_.new_invoice_row_written)
  }).Count -eq 1
$refusalsNoWrites = @($refusalCases | Where-Object {
    (-not [bool]$_.subscription_write_allowed) -and
    (-not [bool]$_.ledger_write_allowed) -and
    (-not [bool]$_.credit_grant_write_allowed) -and
    (-not [bool]$_.invoice_write_allowed)
  }).Count -eq @($refusalCases).Count
$cancelReversal = @($fixture.cases | Where-Object {
    ([string]$_.name -in @("subscription_cancelled", "subscription_terminated")) -and
    @($_.accounting_markers) -contains "credit_grant_revoke_row" -and
    @($_.accounting_markers) -contains "ledger_reversal_entry"
  }).Count -eq 2
$dunning = @($fixture.cases | Where-Object {
    [string]$_.name -eq "subscription_payment_failed_dunning" -and
    @($_.accounting_markers) -contains "dunning_event" -and
    (-not [bool]$_.response.credit_issued)
  }).Count -eq 1
$secretSafe = Test-SecretSafeText ($fixture | ConvertTo-Json -Depth 64)

$runtimeImplemented = [bool]$fixture.runtime_implemented
$contractOnly = [bool]$fixture.contract_only
$paidGateChanged = [bool]$fixture.paid_gate_changed
$runtimeAcceptance = $fixture.runtime_acceptance_contract
$expectedPaymentReconciliation = $fixture.expected_payment_reconciliation
$runtimeFeasibility = $fixture.runtime_feasibility_plan
$schemaContract = $fixture.schema_contract
$schemaTableNames = @($schemaContract.tables | ForEach-Object { [string]$_.name })
$schemaContractReady = ([string]$schemaContract.schema_contract_version -eq "subscription_package_lifecycle_schema_contract.v1") -and
  (-not [bool]$schemaContract.runtime_implemented) -and
  [bool]$schemaContract.contract_only -and
  (-not [bool]$schemaContract.paid_gate_changed) -and
  [bool]$schemaContract.migration_required -and
  ([string]$schemaContract.draft_migration_path -eq "db/migrations/TODO-32K_subscription_package_lifecycle.sql") -and
  ($schemaTableNames -contains "subscription_plans") -and
  ($schemaTableNames -contains "subscription_packages") -and
  ($schemaTableNames -contains "subscriptions") -and
  ($schemaTableNames -contains "subscription_events_or_schedules")
$paymentReconciliationContractReady = ([string]$expectedPaymentReconciliation.schema -eq "admin_subscription_scheduler_expected_payment_reconciliation.v1") -and
  ([string]$expectedPaymentReconciliation.source_handoff_schema -eq "admin_subscription_scheduler_provider_capture_reconciliation_plan.v1") -and
  ([string]$expectedPaymentReconciliation.candidate_schema -eq "payment_provider_stripe_like_response_object_reconciliation.v1") -and
  [bool]$expectedPaymentReconciliation.candidate_required_before_subscription_capture_apply -and
  (-not [bool]$expectedPaymentReconciliation.payment_logic_reimplemented_by_subscription) -and
  @($expectedPaymentReconciliation.expected_provider_object_types) -contains "payment_intent" -and
  @($expectedPaymentReconciliation.expected_provider_object_types) -contains "charge" -and
  @($expectedPaymentReconciliation.expected_provider_statuses) -contains "succeeded" -and
  @($expectedPaymentReconciliation.expected_local_refs) -contains "payment_intent_id" -and
  (-not [bool]$expectedPaymentReconciliation.scheduler_handoff_network_call_enabled) -and
  (-not [bool]$expectedPaymentReconciliation.scheduler_handoff_network_call_performed) -and
  ([string]$expectedPaymentReconciliation.scheduler_handoff_writes.payment_captures -eq "not_written_by_subscription_handoff") -and
  ([string]$expectedPaymentReconciliation.scheduler_handoff_writes.ledger_entries -eq "not_written_by_subscription_handoff") -and
  ([string]$expectedPaymentReconciliation.scheduler_handoff_writes.credit_grants -eq "not_written_by_subscription_handoff") -and
  (-not [bool]$expectedPaymentReconciliation.raw_provider_payload_output_allowed) -and
  (-not [bool]$expectedPaymentReconciliation.authorization_output_allowed) -and
  (-not [bool]$expectedPaymentReconciliation.provider_secret_output_allowed) -and
  [bool]$expectedPaymentReconciliation.secret_safe

$status = if (
  @($missingCases).Count -eq 0 -and
  $moneyDecimalStrings -and
  $secretContract -and
  $creditEffect -and
  $invoiceOrderLinkage -and
  $replayNoDuplicate -and
  $refusalsNoWrites -and
  $cancelReversal -and
  $dunning -and
  $secretSafe -and
  $schemaContractReady -and
  $paymentReconciliationContractReady -and
  (-not $runtimeImplemented) -and
  $contractOnly -and
  (-not $paidGateChanged)
) {
  "pass"
} else {
  "fail"
}

$artifact = [ordered]@{
  schema = "subscription_package_lifecycle_contract.v1"
  status = $status
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  test_name = "subscription_package_contract_fixture_enforces_product_ledger_invariants"
  fixture_path = $fixturePathInfo.relative
  fixture_schema = [string]$fixture.schema
  fixture_status = [string]$fixture.status
  runtime_implemented = $runtimeImplemented
  contract_only = $contractOnly
  paid_gate_changed = $paidGateChanged
  secret_safe = [bool]$secretSafe
  contract_scope = @(
    "plan_package_lifecycle",
    "subscription_create_trial_active_renew_cancel_pause_resume",
    "trial_end_proration_dunning_expire_terminate",
    "credit_grant_or_ledger_effect",
    "invoice_order_linkage",
    "payment_provider_capture_reconciliation_handoff",
    "stripe_like_response_object_reconciliation_candidate_mapping",
    "idempotent_replay_and_conflict_refusal",
    "ownership_currency_non_positive_invalid_plan_refusals",
    "fixed_decimal_money_strings",
    "secret_safe_output"
  )
  cases = @($caseNames)
  missing_cases = @($missingCases)
  plan_states = @(ConvertTo-StringArray $fixture.plan_states)
  subscription_states = @(ConvertTo-StringArray $fixture.subscription_states)
  invariants_enforced = @(
    "plan_package_create_update_archive_contract",
    "subscription_create_trial_active_renew_pause_resume_cancel",
    "end_of_trial_proration_dunning_expire_terminate",
    "subscription_credit_writes_credit_grant_or_ledger_marker",
    "renewal_requires_invoice_or_order_linkage",
    "cancel_or_terminate_requires_grant_revoke_or_ledger_reversal",
    "idempotent_replay_does_not_duplicate_subscription_credit_invoice",
    "same_key_conflict_ownership_currency_non_positive_invalid_plan_refusals",
    "direct_wallet_snapshot_mutation_forbidden",
    "money_decimal_strings_no_float",
    "secret_safe_summary"
  )
  money_decimal_strings = [bool]$moneyDecimalStrings
  subscription_credit_effect_contract = [bool]$creditEffect
  invoice_order_linkage_contract = [bool]$invoiceOrderLinkage
  replay_idempotency_contract = [bool]$replayNoDuplicate
  refusal_no_subscription_ledger_credit_invoice_writes = [bool]$refusalsNoWrites
  cancel_terminate_reversal_required = [bool]$cancelReversal
  dunning_payment_failed_contract = [bool]$dunning
  audit_required = [bool]$fixture.accounting_contract.audit_metadata_required
  direct_wallet_snapshot_mutation_forbidden = (-not [bool]$fixture.accounting_contract.direct_wallet_snapshot_mutation_allowed)
  runtime_acceptance_contract = [ordered]@{
    runtime_artifact_schema = [string]$runtimeAcceptance.runtime_artifact_schema
    runtime_artifact_path = [string]$runtimeAcceptance.runtime_artifact_path
    contract_artifact_must_not_mark_runtime_verified = [bool]$runtimeAcceptance.contract_artifact_must_not_mark_runtime_verified
    runtime_implemented_required = [bool]$runtimeAcceptance.runtime_implemented_required
    contract_only_required = [bool]$runtimeAcceptance.contract_only_required
    route_or_internal_runtime_invocation_required = [bool]$runtimeAcceptance.route_or_internal_runtime_invocation_required
    plan_package_crud_readback_required = [bool]$runtimeAcceptance.plan_package_crud_readback_required
    subscription_lifecycle_readback_required = [bool]$runtimeAcceptance.subscription_lifecycle_readback_required
    subscription_state_transitions_readback_required = [bool]$runtimeAcceptance.subscription_state_transitions_readback_required
    trial_proration_dunning_readback_required = [bool]$runtimeAcceptance.trial_proration_dunning_readback_required
    credit_grant_or_ledger_effect_readback_required = [bool]$runtimeAcceptance.credit_grant_or_ledger_effect_readback_required
    invoice_order_linkage_readback_required = [bool]$runtimeAcceptance.invoice_order_linkage_readback_required
    idempotency_replay_readback_required = [bool]$runtimeAcceptance.idempotency_replay_readback_required
    conflict_no_duplicate_write_readback_required = [bool]$runtimeAcceptance.conflict_no_duplicate_write_readback_required
    refusal_no_write_readback_required = [bool]$runtimeAcceptance.refusal_no_write_readback_required
    audit_readback_required = [bool]$runtimeAcceptance.audit_readback_required
    expected_payment_reconciliation_required = [bool]$paymentReconciliationContractReady
    money_decimal_strings_required = [bool]$runtimeAcceptance.money_decimal_strings_required
    secret_safe_required = [bool]$runtimeAcceptance.secret_safe_required
    paid_gate_changed_required = [bool]$runtimeAcceptance.paid_gate_changed_required
    direct_wallet_snapshot_mutation_forbidden = [bool]$runtimeAcceptance.direct_wallet_snapshot_mutation_forbidden
    raw_provider_payload_output_allowed = [bool]$runtimeAcceptance.raw_provider_payload_output_allowed
    raw_plan_payload_output_allowed = [bool]$runtimeAcceptance.raw_plan_payload_output_allowed
    token_output_allowed = [bool]$runtimeAcceptance.token_output_allowed
    voucher_or_code_output_allowed = [bool]$runtimeAcceptance.voucher_or_code_output_allowed
  }
  expected_payment_reconciliation = [ordered]@{
    schema = [string]$expectedPaymentReconciliation.schema
    source_handoff_schema = [string]$expectedPaymentReconciliation.source_handoff_schema
    candidate_schema = [string]$expectedPaymentReconciliation.candidate_schema
    candidate_source = [string]$expectedPaymentReconciliation.candidate_source
    candidate_required_before_subscription_capture_apply = [bool]$expectedPaymentReconciliation.candidate_required_before_subscription_capture_apply
    payment_logic_reimplemented_by_subscription = [bool]$expectedPaymentReconciliation.payment_logic_reimplemented_by_subscription
    expected_provider_object_types = @(ConvertTo-StringArray $expectedPaymentReconciliation.expected_provider_object_types)
    expected_provider_statuses = @(ConvertTo-StringArray $expectedPaymentReconciliation.expected_provider_statuses)
    expected_local_refs = @(ConvertTo-StringArray $expectedPaymentReconciliation.expected_local_refs)
    status_mapping = [ordered]@{
      matched = [string]$expectedPaymentReconciliation.status_mapping.matched
      mismatch = [string]$expectedPaymentReconciliation.status_mapping.mismatch
      blocked = [string]$expectedPaymentReconciliation.status_mapping.blocked
    }
    safe_next_action_mapping = [ordered]@{
      matched = [string]$expectedPaymentReconciliation.safe_next_action_mapping.matched
      mismatch = [string]$expectedPaymentReconciliation.safe_next_action_mapping.mismatch
      blocked_retryable = [string]$expectedPaymentReconciliation.safe_next_action_mapping.blocked_retryable
      blocked_missing_summary = [string]$expectedPaymentReconciliation.safe_next_action_mapping.blocked_missing_summary
    }
    scheduler_handoff_network_call_enabled = [bool]$expectedPaymentReconciliation.scheduler_handoff_network_call_enabled
    scheduler_handoff_network_call_performed = [bool]$expectedPaymentReconciliation.scheduler_handoff_network_call_performed
    scheduler_handoff_writes = [ordered]@{
      payment_captures = [string]$expectedPaymentReconciliation.scheduler_handoff_writes.payment_captures
      ledger_entries = [string]$expectedPaymentReconciliation.scheduler_handoff_writes.ledger_entries
      credit_grants = [string]$expectedPaymentReconciliation.scheduler_handoff_writes.credit_grants
    }
    secret_safe = [bool]$expectedPaymentReconciliation.secret_safe
  }
  runtime_feasibility_plan = [ordered]@{
    status = [string]$runtimeFeasibility.status
    runtime_implemented = [bool]$runtimeFeasibility.runtime_implemented
    contract_only = [bool]$runtimeFeasibility.contract_only
    paid_gate_changed = [bool]$runtimeFeasibility.paid_gate_changed
    gateway_change_required = [bool]$runtimeFeasibility.gateway_change_required
    control_plane_runtime_required = [bool]$runtimeFeasibility.control_plane_runtime_required
    new_schema_required = [bool]$runtimeFeasibility.new_schema_required
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
  schema_contract = [ordered]@{
    schema_contract_version = [string]$schemaContract.schema_contract_version
    runtime_implemented = [bool]$schemaContract.runtime_implemented
    contract_only = [bool]$schemaContract.contract_only
    paid_gate_changed = [bool]$schemaContract.paid_gate_changed
    migration_required = [bool]$schemaContract.migration_required
    draft_migration_path = [string]$schemaContract.draft_migration_path
    tables = @($schemaContract.tables | ForEach-Object {
        [ordered]@{
          name = [string]$_.name
          required = [bool]$_.required
          purpose = [string]$_.purpose
          required_columns = @(ConvertTo-StringArray $_.required_columns)
          money_decimal_columns = @(ConvertTo-StringArray $_.money_decimal_columns)
          unique_constraints = @(ConvertTo-StringArray $_.unique_constraints)
          foreign_keys = @(ConvertTo-StringArray $_.foreign_keys)
          secret_safe_columns = @(ConvertTo-StringArray $_.secret_safe_columns)
        }
      })
    required_relationships = @(ConvertTo-StringArray $schemaContract.required_relationships)
    invariants = @(ConvertTo-StringArray $schemaContract.invariants)
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
