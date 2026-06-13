use serde::{Deserialize, Serialize};
use serde_json::Value;

const FIXTURE: &str =
    include_str!("../../../tests/fixtures/billing/recharge_voucher_contract.json");

#[derive(Debug, Deserialize)]
struct RechargeVoucherContract {
    schema: String,
    status: String,
    runtime_implemented: bool,
    contract_only: bool,
    paid_gate_changed: bool,
    secret_safe: bool,
    money_contract: MoneyContract,
    recharge_lifecycle_states: Vec<String>,
    voucher_lifecycle_states: Vec<String>,
    secret_safe_contract: SecretSafeContract,
    abuse_guard_contract: AbuseGuardContract,
    accounting_contract: AccountingContract,
    runtime_acceptance_contract: RuntimeAcceptanceContract,
    runtime_feasibility_plan: RuntimeFeasibilityPlan,
    required_cases: Vec<String>,
    cases: Vec<ContractCase>,
}

#[derive(Debug, Deserialize)]
struct MoneyContract {
    format: String,
    scale: usize,
    float_allowed: bool,
}

#[derive(Debug, Deserialize)]
struct SecretSafeContract {
    raw_voucher_code_output_allowed: bool,
    voucher_code_hash_required: bool,
    voucher_code_redaction_required: bool,
    raw_provider_payment_payload_output_allowed: bool,
    forbidden_output_terms: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct AbuseGuardContract {
    redeem_attempts_bounded: bool,
    max_failed_attempts_per_window: usize,
    failed_attempts_do_not_echo_code: bool,
    rate_limit_refusal_code: String,
}

#[derive(Debug, Deserialize)]
struct AccountingContract {
    redeem_success_requires_credit_grant_or_ledger_marker: bool,
    refund_or_cancel_requires_grant_revoke_or_ledger_reversal_marker: bool,
    audit_metadata_required: bool,
    direct_wallet_snapshot_mutation_allowed: bool,
    allowed_markers: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct RuntimeAcceptanceContract {
    runtime_artifact_schema: String,
    runtime_artifact_path: String,
    contract_artifact_must_not_mark_runtime_verified: bool,
    runtime_implemented_required: bool,
    contract_only_required: bool,
    route_or_internal_runtime_invocation_required: bool,
    voucher_storage_readback_required: bool,
    voucher_code_hash_readback_required: bool,
    voucher_code_redacted_output_required: bool,
    redeem_readback_required: bool,
    redeem_idempotency_readback_required: bool,
    abuse_refusal_no_write_readback_required: bool,
    ledger_or_credit_effect_readback_required: bool,
    refund_cancel_reversal_readback_required: bool,
    audit_readback_required: bool,
    secret_safe_required: bool,
    paid_gate_changed_required: bool,
    direct_wallet_snapshot_mutation_forbidden: bool,
    raw_voucher_code_output_allowed: bool,
    raw_provider_payment_payload_output_allowed: bool,
}

#[derive(Debug, Deserialize)]
struct RuntimeFeasibilityPlan {
    status: String,
    runtime_implemented: bool,
    contract_only: bool,
    paid_gate_changed: bool,
    gateway_change_required: bool,
    control_plane_runtime_required: bool,
    new_schema_required: bool,
    external_payment_provider_required_for_recharge_capture: bool,
    reusable_primitives: Vec<RuntimePrimitive>,
    missing_primitives: Vec<RuntimePrimitive>,
    proposed_slices: Vec<ProposedRuntimeSlice>,
}

#[derive(Debug, Deserialize)]
struct RuntimePrimitive {
    primitive: String,
    status: Option<String>,
    usage: Option<String>,
    required: Option<bool>,
    reason: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ProposedRuntimeSlice {
    slice: String,
    owner: String,
    scope: String,
    requires_migration: bool,
    runtime_acceptance: bool,
}

#[derive(Debug, Deserialize, Serialize)]
struct ContractCase {
    name: String,
    operation: String,
    decision: String,
    #[serde(default)]
    idempotency: String,
    #[serde(default)]
    refusal_code: String,
    #[serde(default)]
    same_redeemer: bool,
    #[serde(default)]
    same_idempotency_key: bool,
    #[serde(default)]
    same_body: bool,
    #[serde(default)]
    new_credit_grant_row_written: Option<bool>,
    #[serde(default)]
    new_ledger_entry_written: Option<bool>,
    #[serde(default)]
    ledger_write_allowed: Option<bool>,
    #[serde(default)]
    credit_grant_write_allowed: Option<bool>,
    #[serde(default)]
    request: Value,
    response: Value,
    accounting_markers: Vec<String>,
    #[serde(default)]
    audit_metadata: Value,
    #[serde(default)]
    abuse_guard: Value,
    #[serde(default)]
    refund_cancel_policy: Value,
}

#[test]
fn recharge_voucher_contract_fixture_enforces_product_ledger_invariants() {
    let fixture: RechargeVoucherContract = serde_json::from_str(FIXTURE).expect("fixture parses");
    assert_eq!(fixture.schema, "recharge_voucher_contract.v1");
    assert_eq!(fixture.status, "contract_enforced_not_runtime_wired");
    assert!(!fixture.runtime_implemented);
    assert!(fixture.contract_only);
    assert!(!fixture.paid_gate_changed);
    assert!(fixture.secret_safe);
    assert_money_contract(&fixture.money_contract);
    assert_lifecycle_states(&fixture);
    assert_secret_contract(&fixture.secret_safe_contract);
    assert_abuse_contract(&fixture.abuse_guard_contract);
    assert_accounting_contract(&fixture.accounting_contract);
    assert_runtime_acceptance_contract(&fixture.runtime_acceptance_contract);
    assert_runtime_feasibility_plan(&fixture.runtime_feasibility_plan);

    let case_names = fixture
        .cases
        .iter()
        .map(|case| case.name.as_str())
        .collect::<Vec<_>>();
    for required in &fixture.required_cases {
        assert!(
            case_names.contains(&required.as_str()),
            "missing required case {required}"
        );
    }

    for case in &fixture.cases {
        assert_case_shape(case, &fixture);
        assert_money_fields(case, fixture.money_contract.scale);
        assert_secret_safe(case, &fixture.secret_safe_contract.forbidden_output_terms);
        assert_accounting_markers(case, &fixture.accounting_contract);
    }

    assert_voucher_issue_case(&fixture.cases);
    assert_redeem_success_case(&fixture.cases);
    assert_replay_case(&fixture.cases);
    assert_refusal_cases(&fixture.cases);
    assert_refund_cancel_cases(&fixture.cases);
}

fn assert_money_contract(contract: &MoneyContract) {
    assert_eq!(contract.format, "decimal_string_with_currency");
    assert_eq!(contract.scale, 8);
    assert!(!contract.float_allowed);
}

fn assert_lifecycle_states(fixture: &RechargeVoucherContract) {
    for state in ["created", "pending", "paid", "cancelled", "refunded"] {
        assert!(
            fixture
                .recharge_lifecycle_states
                .contains(&state.to_string())
        );
    }
    for state in ["issued", "redeemed", "expired", "revoked"] {
        assert!(
            fixture
                .voucher_lifecycle_states
                .contains(&state.to_string())
        );
    }
}

fn assert_secret_contract(contract: &SecretSafeContract) {
    assert!(!contract.raw_voucher_code_output_allowed);
    assert!(contract.voucher_code_hash_required);
    assert!(contract.voucher_code_redaction_required);
    assert!(!contract.raw_provider_payment_payload_output_allowed);
}

fn assert_abuse_contract(contract: &AbuseGuardContract) {
    assert!(contract.redeem_attempts_bounded);
    assert!(contract.max_failed_attempts_per_window > 0);
    assert!(contract.failed_attempts_do_not_echo_code);
    assert_eq!(
        contract.rate_limit_refusal_code,
        "voucher_redeem_rate_limited"
    );
}

fn assert_accounting_contract(contract: &AccountingContract) {
    assert!(contract.redeem_success_requires_credit_grant_or_ledger_marker);
    assert!(contract.refund_or_cancel_requires_grant_revoke_or_ledger_reversal_marker);
    assert!(contract.audit_metadata_required);
    assert!(!contract.direct_wallet_snapshot_mutation_allowed);
}

fn assert_runtime_acceptance_contract(contract: &RuntimeAcceptanceContract) {
    assert_eq!(
        contract.runtime_artifact_schema,
        "recharge_voucher_runtime.v1"
    );
    assert_eq!(
        contract.runtime_artifact_path,
        ".tmp/credit-wallet/recharge_voucher_runtime.json"
    );
    assert!(contract.contract_artifact_must_not_mark_runtime_verified);
    assert!(contract.runtime_implemented_required);
    assert!(!contract.contract_only_required);
    assert!(contract.route_or_internal_runtime_invocation_required);
    assert!(contract.voucher_storage_readback_required);
    assert!(contract.voucher_code_hash_readback_required);
    assert!(contract.voucher_code_redacted_output_required);
    assert!(contract.redeem_readback_required);
    assert!(contract.redeem_idempotency_readback_required);
    assert!(contract.abuse_refusal_no_write_readback_required);
    assert!(contract.ledger_or_credit_effect_readback_required);
    assert!(contract.refund_cancel_reversal_readback_required);
    assert!(contract.audit_readback_required);
    assert!(contract.secret_safe_required);
    assert!(!contract.paid_gate_changed_required);
    assert!(contract.direct_wallet_snapshot_mutation_forbidden);
    assert!(!contract.raw_voucher_code_output_allowed);
    assert!(!contract.raw_provider_payment_payload_output_allowed);
}

fn assert_runtime_feasibility_plan(plan: &RuntimeFeasibilityPlan) {
    assert_eq!(
        plan.status,
        "feasible_with_new_voucher_schema_and_control_plane_runtime"
    );
    assert!(!plan.runtime_implemented);
    assert!(plan.contract_only);
    assert!(!plan.paid_gate_changed);
    assert!(!plan.gateway_change_required);
    assert!(plan.control_plane_runtime_required);
    assert!(plan.new_schema_required);
    assert!(plan.external_payment_provider_required_for_recharge_capture);

    let reusable = plan
        .reusable_primitives
        .iter()
        .map(|item| item.primitive.as_str())
        .collect::<Vec<_>>();
    for primitive in [
        "wallets",
        "credit_grants",
        "ledger_entries_admin_adjustment",
        "audit_logs",
        "opening_balance_import_idempotent_transaction_pattern",
        "credit_grant_crud_runtime",
        "remaining_balance_read_model",
    ] {
        assert!(
            reusable.contains(&primitive),
            "missing reusable primitive {primitive}"
        );
    }
    for primitive in &plan.reusable_primitives {
        assert_eq!(primitive.status.as_deref(), Some("available"));
        assert!(
            primitive
                .usage
                .as_deref()
                .is_some_and(|usage| !usage.trim().is_empty()),
            "{} must describe usage",
            primitive.primitive
        );
    }

    let missing = plan
        .missing_primitives
        .iter()
        .map(|item| item.primitive.as_str())
        .collect::<Vec<_>>();
    for primitive in [
        "recharge_intents_schema",
        "voucher_campaigns_schema",
        "voucher_issuances_schema",
        "voucher_redemptions_schema",
        "voucher_redeem_attempts_or_abuse_events_schema",
        "payment_provider_handoff_and_callback_state",
        "live_route_matrix_artifact",
    ] {
        assert!(
            missing.contains(&primitive),
            "missing required runtime gap {primitive}"
        );
    }
    for primitive in &plan.missing_primitives {
        assert_eq!(primitive.required, Some(true));
        assert!(
            primitive
                .reason
                .as_deref()
                .is_some_and(|reason| !reason.trim().is_empty()),
            "{} must describe reason",
            primitive.primitive
        );
    }

    assert_eq!(plan.proposed_slices.len(), 5);
    assert!(
        plan.proposed_slices
            .iter()
            .any(|slice| slice.requires_migration),
        "at least one slice must own schema migration"
    );
    assert!(
        plan.proposed_slices
            .iter()
            .any(|slice| slice.runtime_acceptance),
        "one slice must own runtime acceptance artifact"
    );
    for slice in &plan.proposed_slices {
        assert!(slice.slice.starts_with("TODO-32I-S"));
        assert!(!slice.owner.trim().is_empty());
        assert!(!slice.scope.trim().is_empty());
    }
}

fn assert_case_shape(case: &ContractCase, fixture: &RechargeVoucherContract) {
    assert!(!case.name.trim().is_empty());
    assert!(!case.operation.trim().is_empty());
    assert!(
        fixture.recharge_lifecycle_states.contains(&case.decision)
            || fixture.voucher_lifecycle_states.contains(&case.decision)
            || matches!(case.decision.as_str(), "refused" | "replayed"),
        "{} unsupported decision {}",
        case.name,
        case.decision
    );
    assert_eq!(
        case.response.get("secret_safe").and_then(Value::as_bool),
        Some(true),
        "{} response must be secret_safe",
        case.name
    );
}

fn assert_money_fields(case: &ContractCase, scale: usize) {
    visit_money_strings(&case.request, scale, &case.name);
    visit_money_strings(&case.response, scale, &case.name);
    for container in [&case.request, &case.response] {
        if let Some(currency) = container.get("currency").and_then(Value::as_str) {
            assert_eq!(currency.len(), 3, "{} currency length", case.name);
            assert!(
                currency.chars().all(|ch| ch.is_ascii_uppercase()),
                "{} currency must be uppercase ASCII",
                case.name
            );
        }
    }
}

fn visit_money_strings(value: &Value, scale: usize, label: &str) {
    match value {
        Value::Object(map) => {
            for (key, item) in map {
                if key.contains("amount") {
                    assert_decimal_string(item, scale, label, key);
                }
                visit_money_strings(item, scale, label);
            }
        }
        Value::Array(items) => {
            for item in items {
                visit_money_strings(item, scale, label);
            }
        }
        _ => {}
    }
}

fn assert_decimal_string(value: &Value, scale: usize, label: &str, field: &str) {
    let text = value
        .as_str()
        .unwrap_or_else(|| panic!("{label}.{field} must be a string, not number"));
    let signless = text.strip_prefix('-').unwrap_or(text);
    let (whole, fractional) = signless
        .split_once('.')
        .unwrap_or_else(|| panic!("{label}.{field} must contain decimal point"));
    assert!(
        !whole.is_empty() && whole.chars().all(|ch| ch.is_ascii_digit()),
        "{label}.{field} invalid whole decimal part"
    );
    assert_eq!(fractional.len(), scale, "{label}.{field} scale");
    assert!(fractional.chars().all(|ch| ch.is_ascii_digit()));
}

fn assert_secret_safe(case: &ContractCase, forbidden_terms: &[String]) {
    let serialized = serde_json::to_string(case).expect("case serializes");
    let normalized = serialized.to_ascii_lowercase();
    for term in forbidden_terms {
        assert!(
            !normalized.contains(&term.to_ascii_lowercase()),
            "{} contains forbidden output term `{term}`",
            case.name
        );
    }
}

fn assert_accounting_markers(case: &ContractCase, contract: &AccountingContract) {
    for marker in &case.accounting_markers {
        assert!(
            contract.allowed_markers.contains(marker),
            "{} unsupported accounting marker `{marker}`",
            case.name
        );
    }
    if matches!(case.decision.as_str(), "paid" | "redeemed") {
        assert!(
            case.accounting_markers
                .iter()
                .any(|marker| marker == "credit_grant_row" || marker == "admin_adjustment_entry"),
            "{} successful credit effect must write grant or ledger/admin adjustment marker",
            case.name
        );
    }
    if case.decision == "refused" {
        assert_eq!(
            case.ledger_write_allowed,
            Some(false),
            "{} ledger write",
            case.name
        );
        assert_eq!(
            case.credit_grant_write_allowed,
            Some(false),
            "{} grant write",
            case.name
        );
    }
}

fn assert_voucher_issue_case(cases: &[ContractCase]) {
    let case = cases
        .iter()
        .find(|case| case.name == "voucher_issued_hashed_redacted")
        .expect("voucher issue case");
    assert_eq!(case.decision, "issued");
    assert_eq!(
        case.response
            .get("code_hash_present")
            .and_then(Value::as_bool),
        Some(true)
    );
    assert_eq!(
        case.response.get("code_redacted").and_then(Value::as_bool),
        Some(true)
    );
    assert_eq!(
        case.request.get("max_redemptions").and_then(Value::as_i64),
        Some(1)
    );
}

fn assert_redeem_success_case(cases: &[ContractCase]) {
    let case = cases
        .iter()
        .find(|case| case.name == "voucher_redeem_success")
        .expect("redeem success case");
    assert_eq!(case.decision, "redeemed");
    assert!(
        case.accounting_markers
            .iter()
            .any(|marker| marker == "credit_grant_row")
    );
    assert!(
        case.accounting_markers
            .iter()
            .any(|marker| marker == "admin_adjustment_entry")
    );
    assert_eq!(
        case.abuse_guard
            .get("raw_code_echoed")
            .and_then(Value::as_bool),
        Some(false)
    );
}

fn assert_replay_case(cases: &[ContractCase]) {
    let case = cases
        .iter()
        .find(|case| case.name == "voucher_redeem_idempotent_replay")
        .expect("redeem replay case");
    assert!(case.same_redeemer);
    assert!(case.same_idempotency_key);
    assert!(case.same_body);
    assert_eq!(case.idempotency, "replayed");
    assert_eq!(case.new_credit_grant_row_written, Some(false));
    assert_eq!(case.new_ledger_entry_written, Some(false));
}

fn assert_refusal_cases(cases: &[ContractCase]) {
    for (name, code) in [
        (
            "voucher_redeem_same_code_different_user_refused",
            "voucher_already_redeemed_by_different_user",
        ),
        (
            "voucher_redeem_over_max_redemptions_refused",
            "voucher_max_redemptions_exceeded",
        ),
        ("voucher_redeem_expired_refused", "voucher_expired"),
        ("voucher_redeem_revoked_refused", "voucher_revoked"),
        (
            "voucher_redeem_currency_mismatch_refused",
            "voucher_currency_mismatch",
        ),
        (
            "voucher_redeem_non_positive_amount_refused",
            "non_positive_voucher_amount",
        ),
        (
            "voucher_redeem_ownership_mismatch_refused",
            "voucher_scope_ownership_mismatch",
        ),
        (
            "voucher_redeem_rate_limited_refused",
            "voucher_redeem_rate_limited",
        ),
    ] {
        let case = cases.iter().find(|case| case.name == name).unwrap();
        assert_eq!(case.decision, "refused");
        assert_eq!(case.refusal_code, code);
        assert_eq!(
            case.response.get("refusal_code").and_then(Value::as_str),
            Some(code)
        );
    }
}

fn assert_refund_cancel_cases(cases: &[ContractCase]) {
    for name in [
        "recharge_intent_refunded",
        "voucher_revoke_after_redeem_requires_reversal",
    ] {
        let case = cases.iter().find(|case| case.name == name).unwrap();
        assert!(
            case.accounting_markers
                .iter()
                .any(|marker| marker == "credit_grant_revoke_row")
        );
        assert!(
            case.accounting_markers
                .iter()
                .any(|marker| marker == "ledger_reversal_entry")
        );
        assert_eq!(
            case.refund_cancel_policy
                .get("credit_grant_revoke_or_ledger_reversal_required_if_credit_issued")
                .and_then(Value::as_bool),
            Some(true)
        );
    }
}
