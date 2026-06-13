use serde::{Deserialize, Serialize};
use serde_json::Value;

const FIXTURE: &str =
    include_str!("../../../tests/fixtures/billing/payment_order_invoice_contract.json");

#[derive(Debug, Deserialize)]
struct PaymentOrderInvoiceContract {
    schema: String,
    status: String,
    runtime_implemented: bool,
    contract_only: bool,
    paid_gate_changed: bool,
    secret_safe: bool,
    money_contract: MoneyContract,
    order_states: Vec<String>,
    payment_states: Vec<String>,
    invoice_states: Vec<String>,
    secret_safe_contract: SecretSafeContract,
    accounting_contract: AccountingContract,
    runtime_acceptance_contract: RuntimeAcceptanceContract,
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
    provider_reference_bounded: bool,
    provider_reference_redacted: bool,
    raw_provider_secret_output_allowed: bool,
    client_secret_output_allowed: bool,
    raw_provider_payload_output_allowed: bool,
    pii_output_allowed: bool,
    forbidden_output_terms: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct AccountingContract {
    capture_success_requires_credit_grant_or_ledger_marker: bool,
    refund_or_cancel_requires_grant_revoke_or_ledger_reversal_marker: bool,
    reconciliation_markers_required: bool,
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
    order_lifecycle_readback_required: bool,
    provider_handoff_redacted_readback_required: bool,
    provider_callback_or_capture_readback_required: bool,
    payment_confirm_capture_readback_required: bool,
    invoice_receipt_readback_required: bool,
    refund_cancel_chargeback_reversal_readback_required: bool,
    reconciliation_readback_required: bool,
    idempotency_replay_readback_required: bool,
    conflict_no_duplicate_write_readback_required: bool,
    audit_readback_required: bool,
    money_decimal_strings_required: bool,
    secret_safe_required: bool,
    paid_gate_changed_required: bool,
    direct_wallet_snapshot_mutation_forbidden: bool,
    raw_provider_secret_output_allowed: bool,
    client_secret_output_allowed: bool,
    raw_provider_payload_output_allowed: bool,
    pii_output_allowed: bool,
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
    same_idempotency_key: bool,
    #[serde(default)]
    same_body: bool,
    #[serde(default)]
    new_credit_grant_row_written: Option<bool>,
    #[serde(default)]
    new_ledger_entry_written: Option<bool>,
    #[serde(default)]
    new_invoice_row_written: Option<bool>,
    #[serde(default)]
    new_refund_row_written: Option<bool>,
    #[serde(default)]
    ledger_write_allowed: Option<bool>,
    #[serde(default)]
    credit_grant_write_allowed: Option<bool>,
    #[serde(default)]
    invoice_write_allowed: Option<bool>,
    #[serde(default)]
    refund_write_allowed: Option<bool>,
    #[serde(default)]
    request: Value,
    response: Value,
    accounting_markers: Vec<String>,
    #[serde(default)]
    audit_metadata: Value,
    #[serde(default)]
    reconciliation: Value,
    #[serde(default)]
    refund_cancel_policy: Value,
}

#[test]
fn payment_order_invoice_contract_fixture_enforces_product_ledger_invariants() {
    let fixture: PaymentOrderInvoiceContract =
        serde_json::from_str(FIXTURE).expect("fixture parses");
    assert_eq!(fixture.schema, "payment_order_invoice_contract.v1");
    assert_eq!(fixture.status, "contract_enforced_not_runtime_wired");
    assert!(!fixture.runtime_implemented);
    assert!(fixture.contract_only);
    assert!(!fixture.paid_gate_changed);
    assert!(fixture.secret_safe);
    assert_money_contract(&fixture.money_contract);
    assert_lifecycle_states(&fixture);
    assert_secret_contract(&fixture.secret_safe_contract);
    assert_accounting_contract(&fixture.accounting_contract);
    assert_runtime_acceptance_contract(&fixture.runtime_acceptance_contract);

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

    assert_provider_handoff_case(&fixture.cases);
    assert_capture_success_case(&fixture.cases);
    assert_invoice_receipt_case(&fixture.cases);
    assert_replay_cases(&fixture.cases);
    assert_refund_cancel_cases(&fixture.cases);
    assert_refusal_cases(&fixture.cases);
}

fn assert_money_contract(contract: &MoneyContract) {
    assert_eq!(contract.format, "decimal_string_with_currency");
    assert_eq!(contract.scale, 8);
    assert!(!contract.float_allowed);
}

fn assert_lifecycle_states(fixture: &PaymentOrderInvoiceContract) {
    for state in [
        "created",
        "pending_payment",
        "paid",
        "cancelled",
        "expired",
        "refunded",
        "failed",
    ] {
        assert!(fixture.order_states.contains(&state.to_string()));
    }
    for state in [
        "intent_created",
        "provider_handoff",
        "captured",
        "cancelled",
        "refunded",
        "failed",
    ] {
        assert!(fixture.payment_states.contains(&state.to_string()));
    }
    for state in ["draft", "issued", "paid", "voided", "refunded"] {
        assert!(fixture.invoice_states.contains(&state.to_string()));
    }
}

fn assert_secret_contract(contract: &SecretSafeContract) {
    assert!(contract.provider_reference_bounded);
    assert!(contract.provider_reference_redacted);
    assert!(!contract.raw_provider_secret_output_allowed);
    assert!(!contract.client_secret_output_allowed);
    assert!(!contract.raw_provider_payload_output_allowed);
    assert!(!contract.pii_output_allowed);
}

fn assert_accounting_contract(contract: &AccountingContract) {
    assert!(contract.capture_success_requires_credit_grant_or_ledger_marker);
    assert!(contract.refund_or_cancel_requires_grant_revoke_or_ledger_reversal_marker);
    assert!(contract.reconciliation_markers_required);
    assert!(contract.audit_metadata_required);
    assert!(!contract.direct_wallet_snapshot_mutation_allowed);
}

fn assert_runtime_acceptance_contract(contract: &RuntimeAcceptanceContract) {
    assert_eq!(
        contract.runtime_artifact_schema,
        "payment_order_invoice_runtime.v1"
    );
    assert_eq!(
        contract.runtime_artifact_path,
        ".tmp/credit-wallet/payment_order_invoice_runtime.json"
    );
    assert!(contract.contract_artifact_must_not_mark_runtime_verified);
    assert!(contract.runtime_implemented_required);
    assert!(!contract.contract_only_required);
    assert!(contract.route_or_internal_runtime_invocation_required);
    assert!(contract.order_lifecycle_readback_required);
    assert!(contract.provider_handoff_redacted_readback_required);
    assert!(contract.provider_callback_or_capture_readback_required);
    assert!(contract.payment_confirm_capture_readback_required);
    assert!(contract.invoice_receipt_readback_required);
    assert!(contract.refund_cancel_chargeback_reversal_readback_required);
    assert!(contract.reconciliation_readback_required);
    assert!(contract.idempotency_replay_readback_required);
    assert!(contract.conflict_no_duplicate_write_readback_required);
    assert!(contract.audit_readback_required);
    assert!(contract.money_decimal_strings_required);
    assert!(contract.secret_safe_required);
    assert!(!contract.paid_gate_changed_required);
    assert!(contract.direct_wallet_snapshot_mutation_forbidden);
    assert!(!contract.raw_provider_secret_output_allowed);
    assert!(!contract.client_secret_output_allowed);
    assert!(!contract.raw_provider_payload_output_allowed);
    assert!(!contract.pii_output_allowed);
}

fn assert_case_shape(case: &ContractCase, fixture: &PaymentOrderInvoiceContract) {
    assert!(!case.name.trim().is_empty());
    assert!(!case.operation.trim().is_empty());
    assert!(
        fixture.order_states.contains(&case.decision)
            || fixture.payment_states.contains(&case.decision)
            || fixture.invoice_states.contains(&case.decision)
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
    visit_money_strings(&case.reconciliation, scale, &case.name);
    for container in [&case.request, &case.response, &case.reconciliation] {
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
                if key.contains("amount")
                    || key.contains("total")
                    || key.contains("subtotal")
                    || key.contains("quantity")
                {
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
    if matches!(case.decision.as_str(), "paid" | "captured") {
        assert!(
            case.accounting_markers
                .iter()
                .any(|marker| marker == "credit_grant_row" || marker == "admin_adjustment_entry"),
            "{} capture success must write grant or ledger/admin adjustment marker",
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
        assert_eq!(
            case.invoice_write_allowed,
            Some(false),
            "{} invoice write",
            case.name
        );
        assert_eq!(
            case.refund_write_allowed,
            Some(false),
            "{} refund write",
            case.name
        );
    }
}

fn assert_provider_handoff_case(cases: &[ContractCase]) {
    let case = cases
        .iter()
        .find(|case| case.name == "payment_intent_provider_handoff")
        .expect("provider handoff case");
    assert_eq!(case.decision, "provider_handoff");
    assert_eq!(
        case.response
            .get("provider_reference_redacted")
            .and_then(Value::as_bool),
        Some(true)
    );
    assert_eq!(
        case.response
            .get("provider_reference_bounded")
            .and_then(Value::as_bool),
        Some(true)
    );
    assert_eq!(
        case.response
            .get("client_credential_echoed")
            .and_then(Value::as_bool),
        Some(false)
    );
    assert_eq!(
        case.response
            .get("provider_payload_echoed")
            .and_then(Value::as_bool),
        Some(false)
    );
}

fn assert_capture_success_case(cases: &[ContractCase]) {
    let case = cases
        .iter()
        .find(|case| case.name == "payment_confirm_paid")
        .expect("capture success case");
    assert_eq!(case.decision, "paid");
    for marker in [
        "credit_grant_row",
        "admin_adjustment_entry",
        "invoice_row",
        "receipt_row",
        "reconciliation_marker",
    ] {
        assert!(
            case.accounting_markers.contains(&marker.to_string()),
            "capture success missing {marker}"
        );
    }
    assert_eq!(
        case.reconciliation.get("matched").and_then(Value::as_bool),
        Some(true)
    );
}

fn assert_invoice_receipt_case(cases: &[ContractCase]) {
    let case = cases
        .iter()
        .find(|case| case.name == "invoice_issued_receipt")
        .expect("invoice receipt case");
    assert_eq!(case.decision, "issued");
    assert!(case.response.get("invoice_id").is_some());
    assert!(case.response.get("invoice_number").is_some());
    assert_eq!(
        case.response
            .get("pii_payload_echoed")
            .and_then(Value::as_bool),
        Some(false)
    );
    let line_items = case
        .response
        .get("line_items")
        .and_then(Value::as_array)
        .expect("line items");
    assert!(!line_items.is_empty());
    assert_eq!(
        case.reconciliation.get("invoice_line_total"),
        case.reconciliation.get("payment_amount")
    );
}

fn assert_replay_cases(cases: &[ContractCase]) {
    for name in [
        "payment_confirm_idempotent_replay",
        "payment_refund_idempotent_replay",
    ] {
        let case = cases.iter().find(|case| case.name == name).unwrap();
        assert!(case.same_idempotency_key);
        assert!(case.same_body);
        assert_eq!(case.idempotency, "replayed");
        assert_eq!(case.new_credit_grant_row_written, Some(false));
        assert_eq!(case.new_ledger_entry_written, Some(false));
        assert_eq!(case.new_invoice_row_written, Some(false));
        assert_eq!(case.new_refund_row_written, Some(false));
    }
}

fn assert_refund_cancel_cases(cases: &[ContractCase]) {
    let refund = cases
        .iter()
        .find(|case| case.name == "payment_refund_applied")
        .expect("refund case");
    for marker in [
        "refund_row",
        "credit_grant_revoke_row",
        "ledger_reversal_entry",
        "reconciliation_marker",
    ] {
        assert!(
            refund.accounting_markers.contains(&marker.to_string()),
            "refund missing {marker}"
        );
    }
    assert_eq!(
        refund
            .reconciliation
            .get("matched")
            .and_then(Value::as_bool),
        Some(true)
    );

    let cancel = cases
        .iter()
        .find(|case| case.name == "order_cancelled_before_capture")
        .expect("cancel case");
    assert_eq!(
        cancel
            .refund_cancel_policy
            .get("credit_grant_revoke_or_ledger_reversal_required_if_credit_issued")
            .and_then(Value::as_bool),
        Some(true)
    );
}

fn assert_refusal_cases(cases: &[ContractCase]) {
    for (name, code) in [
        ("amount_mismatch_refused", "payment_amount_mismatch"),
        ("currency_mismatch_refused", "payment_currency_mismatch"),
        (
            "provider_status_mismatch_refused",
            "provider_status_mismatch",
        ),
        (
            "duplicate_provider_reference_refused",
            "duplicate_provider_reference",
        ),
        ("non_positive_amount_refused", "non_positive_payment_amount"),
        (
            "ownership_mismatch_refused",
            "payment_order_ownership_mismatch",
        ),
        (
            "refund_exceeds_captured_refused",
            "refund_exceeds_captured_amount",
        ),
        ("invoice_duplicate_refused", "duplicate_invoice_number"),
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
