param(
  [string]$OutputPath = ".tmp\credit-wallet\recharge_voucher_runtime_plan.json"
)

$ErrorActionPreference = "Stop"

function Resolve-RepoPath {
  param([string]$Path)
  $root = (Get-Location).Path
  $full = [System.IO.Path]::GetFullPath((Join-Path $root $Path))
  if (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "output_path_outside_repo"
  }
  return $full
}

$target = Resolve-RepoPath -Path $OutputPath
$parent = Split-Path -Parent $target
if ($parent) {
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
}

$artifact = [ordered]@{
  schema = "recharge_voucher_runtime_plan.v1"
  overall_status = "contract_ready_runtime_pending"
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  runtime_implemented = $false
  contract_only = $true
  control_plane_runtime_invoked = $false
  external_payment_provider_implemented = $false
  gateway_changed = $false
  paid_gate_changed = $false
  secret_safe = $true
  money_decimal_strings = $true
  raw_secret_markers_present = $false
  existing_primitives = [ordered]@{
    wallets_table = $true
    credit_grants_table = $true
    ledger_entries_table = $true
    admin_audit_log_writer = $true
    opening_balance_import_runtime = $true
    credit_grant_crud_runtime = $true
    remaining_balance_runtime = $true
  }
  missing_runtime_primitives = @(
    "recharge_intents_table",
    "voucher_campaigns_table",
    "voucher_issuances_table",
    "voucher_redemptions_table",
    "voucher_redeem_attempts_or_abuse_events_table",
    "payment_provider_handoff_contract_runtime",
    "refund_cancel_reversal_runtime_matrix",
    "qa_live_route_artifact"
  )
  required_guardrails = [ordered]@{
    admin_or_user_auth_required = $true
    idempotency_required_for_writes = $true
    voucher_code_hash_required = $true
    raw_voucher_code_output_allowed = $false
    raw_provider_payload_output_allowed = $false
    direct_wallet_snapshot_mutation_forbidden = $true
    success_audit_required = $true
    refusal_audit_or_attempt_required = $true
    refusal_no_credit_or_ledger_write_required = $true
  }
  proposed_slices = @(
    [ordered]@{
      slice = "TODO-32I-S1"
      owner = "E11 Control Plane"
      scope = "schema_and_openapi_boundary"
      output = "migrations for recharge_intents, voucher_campaigns, voucher_issuances, voucher_redemptions, voucher_redeem_attempts; OpenAPI contract; no provider runtime"
      runtime_implemented = $false
    },
    [ordered]@{
      slice = "TODO-32I-S2"
      owner = "E11 Control Plane"
      scope = "voucher_issue_and_redeem_internal_tx"
      output = "internal SQLx transaction functions and DB-free plus opt-in DB tests for issue/redeem/replay/refusal/audit"
      runtime_implemented = $false
    },
    [ordered]@{
      slice = "TODO-32I-S3"
      owner = "Product/E11/Security"
      scope = "abuse_and_hashing_runtime"
      output = "server-side voucher code hashing, bounded redeem attempts, rate-limit refusal, redacted responses"
      runtime_implemented = $false
    },
    [ordered]@{
      slice = "TODO-32I-S4"
      owner = "Product/Payments/E11"
      scope = "recharge_payment_provider_stub_or_handoff"
      output = "provider-handoff/callback contract, no raw provider payload echo, paid/cancel/refund state machine"
      runtime_implemented = $false
    },
    [ordered]@{
      slice = "TODO-32I-S5"
      owner = "QA/E11"
      scope = "live_route_matrix_artifact"
      output = ".tmp/credit-wallet/recharge_voucher_runtime.json with voucher storage/code hash/readback, redeem replay/refusal, ledger/credit effect, reversal, audit, secret-safe"
      runtime_implemented = $false
    }
  )
  acceptance_blockers = @(
    "recharge_voucher_schema_missing",
    "voucher_code_hash_storage_missing",
    "abuse_attempt_persistence_missing",
    "payment_provider_handoff_runtime_missing",
    "live_route_matrix_missing"
  )
  notes = "This artifact is a feasibility/plan artifact only. It must not satisfy recharge_voucher_runtime_verified."
}

$artifact | ConvertTo-Json -Depth 12 | Set-Content -Path $target -Encoding UTF8

Write-Output "recharge_voucher_runtime_plan_artifact_status=contract_ready_runtime_pending"
Write-Output "recharge_voucher_runtime_plan_artifact_path=$OutputPath"
Write-Output "recharge_voucher_runtime_plan_runtime_implemented=false"

