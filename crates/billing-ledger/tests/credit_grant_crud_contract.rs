use serde::{Deserialize, Serialize};
use serde_json::Value;

const FIXTURE: &str =
    include_str!("../../../tests/fixtures/billing/credit_grant_crud_contract.json");

#[derive(Debug, Deserialize)]
struct CreditGrantCrudContract {
    schema: String,
    status: String,
    runtime_implemented: bool,
    paid_gate_changed: bool,
    controlled_paid_beta_blocker: bool,
    broader_commercial_distribution_blocker: bool,
    money_contract: MoneyContract,
    secret_safe_contract: SecretSafeContract,
    accounting_contract: AccountingContract,
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
    secret_safe: bool,
    raw_idempotency_material_output_allowed: bool,
    raw_request_payload_output_allowed: bool,
    forbidden_output_terms: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct AccountingContract {
    direct_wallet_snapshot_mutation_allowed: bool,
    credit_grant_row_required_for_create: bool,
    audit_metadata_required_for_writes: bool,
    ledger_or_admin_adjustment_marker_required_when_balance_changes: bool,
    list_read_model_only: bool,
    allowed_markers: Vec<String>,
}

#[derive(Debug, Deserialize, Serialize)]
struct ContractCase {
    name: String,
    operation: String,
    #[serde(default)]
    method: String,
    #[serde(default)]
    path: String,
    write: bool,
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
    new_audit_success_row_written: Option<bool>,
    #[serde(default)]
    ledger_write_allowed: Option<bool>,
    #[serde(default)]
    credit_grant_write_allowed: Option<bool>,
    #[serde(default)]
    attempted_accounting_marker: String,
    #[serde(default)]
    request: Value,
    response: Value,
    accounting_markers: Vec<String>,
    #[serde(default)]
    audit_metadata: Value,
}

#[test]
fn credit_grant_crud_contract_fixture_enforces_accounting_invariants() {
    let fixture: CreditGrantCrudContract = serde_json::from_str(FIXTURE).expect("fixture parses");
    assert_eq!(fixture.schema, "credit_grant_crud_contract.v1");
    assert_eq!(fixture.status, "contract_enforced_not_runtime_wired");
    assert!(!fixture.runtime_implemented);
    assert!(!fixture.paid_gate_changed);
    assert!(!fixture.controlled_paid_beta_blocker);
    assert!(fixture.broader_commercial_distribution_blocker);
    assert_eq!(
        fixture.money_contract.format,
        "decimal_string_with_currency"
    );
    assert_eq!(fixture.money_contract.scale, 8);
    assert!(!fixture.money_contract.float_allowed);
    assert!(fixture.secret_safe_contract.secret_safe);
    assert!(
        !fixture
            .secret_safe_contract
            .raw_idempotency_material_output_allowed
    );
    assert!(
        !fixture
            .secret_safe_contract
            .raw_request_payload_output_allowed
    );
    assert!(
        !fixture
            .accounting_contract
            .direct_wallet_snapshot_mutation_allowed
    );
    assert!(
        fixture
            .accounting_contract
            .credit_grant_row_required_for_create
    );
    assert!(
        fixture
            .accounting_contract
            .audit_metadata_required_for_writes
    );
    assert!(
        fixture
            .accounting_contract
            .ledger_or_admin_adjustment_marker_required_when_balance_changes
    );
    assert!(fixture.accounting_contract.list_read_model_only);

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
        assert_secret_safe(case, &fixture.secret_safe_contract.forbidden_output_terms);
        assert_money_fields(case, fixture.money_contract.scale);
        assert_accounting_markers(case, &fixture.accounting_contract);
        assert_audit_and_idempotency(case);
    }

    assert_replay_and_conflict_cases(&fixture.cases);
    assert_refusal_cases(&fixture.cases);
}

fn assert_case_shape(case: &ContractCase, fixture: &CreditGrantCrudContract) {
    assert!(!case.name.trim().is_empty());
    assert!(!case.operation.trim().is_empty());
    if !case.method.is_empty() {
        assert!(matches!(case.method.as_str(), "GET" | "POST"));
    }
    if !case.path.is_empty() {
        assert!(case.path.starts_with("/billing/"));
    }
    assert!(
        !case.response.is_null(),
        "{} must define response shape",
        case.name
    );
    if case.write {
        assert!(
            case.request
                .get("idempotency_key_present")
                .and_then(Value::as_bool)
                .unwrap_or(case.same_idempotency_key),
            "{} write request must prove idempotency key presence",
            case.name
        );
    } else {
        assert!(
            case.accounting_markers.is_empty(),
            "{} read case must not claim mutation accounting markers",
            case.name
        );
        assert!(
            fixture.accounting_contract.list_read_model_only,
            "{} read case must remain read model only",
            case.name
        );
    }
}

fn assert_secret_safe(case: &ContractCase, forbidden_terms: &[String]) {
    assert_eq!(
        case.response.get("secret_safe").and_then(Value::as_bool),
        Some(true),
        "{} response must be secret_safe",
        case.name
    );
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

fn assert_money_fields(case: &ContractCase, scale: usize) {
    visit_money_strings(&case.request, scale, &case.name);
    visit_money_strings(&case.response, scale, &case.name);
    for container in [&case.request, &case.response] {
        if let Some(currency) = container.get("currency").and_then(Value::as_str) {
            if case.refusal_code == "invalid_currency" {
                continue;
            }
            assert_eq!(currency.len(), 3, "{} currency length", case.name);
            assert!(
                currency.chars().all(|ch| ch.is_ascii_uppercase()),
                "{} currency must be uppercase ISO-like code",
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
                    || key.contains("balance")
                    || key == "remaining_amount_before"
                    || key == "remaining_amount_after"
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
    assert_eq!(
        fractional.len(),
        scale,
        "{label}.{field} must use scale {scale}"
    );
    assert!(
        fractional.chars().all(|ch| ch.is_ascii_digit()),
        "{label}.{field} invalid fractional decimal part"
    );
}

fn assert_accounting_markers(case: &ContractCase, contract: &AccountingContract) {
    if case.attempted_accounting_marker == "wallet_snapshot_balance_update" {
        assert_eq!(
            case.decision, "refused",
            "{} direct wallet marker",
            case.name
        );
        assert_eq!(
            case.refusal_code, "direct_wallet_snapshot_mutation_forbidden",
            "{} direct wallet marker must be refused",
            case.name
        );
    }
    for marker in &case.accounting_markers {
        assert!(
            contract.allowed_markers.contains(marker),
            "{} unsupported accounting marker `{marker}`",
            case.name
        );
    }
    if case.write && case.decision == "applied" {
        assert!(
            case.accounting_markers
                .iter()
                .any(|marker| marker == "credit_grant_row"
                    || marker == "credit_grant_state_change_row"),
            "{} applied write must include credit grant row/state marker",
            case.name
        );
        assert!(
            case.accounting_markers
                .iter()
                .any(|marker| marker == "ledger_entry" || marker == "admin_adjustment_entry"),
            "{} applied balance change must include ledger/admin adjustment marker",
            case.name
        );
    }
    if case.write {
        assert!(
            case.accounting_markers
                .iter()
                .any(|marker| marker == "audit_log"),
            "{} write/refusal must include audit marker",
            case.name
        );
    }
    if case.decision == "refused" {
        assert_eq!(
            case.ledger_write_allowed,
            Some(false),
            "{} refusal must not write ledger",
            case.name
        );
        assert_eq!(
            case.credit_grant_write_allowed,
            Some(false),
            "{} refusal must not write credit grant",
            case.name
        );
    }
}

fn assert_audit_and_idempotency(case: &ContractCase) {
    if !case.write {
        return;
    }
    if case.decision == "applied" {
        assert_eq!(case.idempotency, "applied", "{} idempotency", case.name);
        assert_eq!(
            case.audit_metadata
                .get("actor_id_present")
                .and_then(Value::as_bool),
            Some(true),
            "{} audit actor id required",
            case.name
        );
        assert_string(&case.audit_metadata, "actor_type", &case.name);
        assert_string(&case.audit_metadata, "reason", &case.name);
        assert_eq!(
            case.audit_metadata
                .get("request_or_operation_id_present")
                .and_then(Value::as_bool),
            Some(true),
            "{} audit request/operation id required",
            case.name
        );
    }
    if case.decision == "replayed" {
        assert_eq!(case.idempotency, "replayed", "{} replay", case.name);
        assert_eq!(
            case.new_credit_grant_row_written,
            Some(false),
            "{} replay must not write new grant row",
            case.name
        );
        assert_eq!(
            case.new_audit_success_row_written,
            Some(false),
            "{} replay must not write new success audit row",
            case.name
        );
    }
}

fn assert_string(value: &Value, field: &str, label: &str) {
    assert!(
        value
            .get(field)
            .and_then(Value::as_str)
            .is_some_and(|text| !text.trim().is_empty()),
        "{label} missing `{field}`"
    );
}

fn assert_replay_and_conflict_cases(cases: &[ContractCase]) {
    let replay = cases
        .iter()
        .find(|case| case.name == "idempotent_replay")
        .expect("idempotent replay case");
    assert!(replay.same_idempotency_key);
    assert!(replay.same_body);
    assert_eq!(replay.decision, "replayed");

    let conflict = cases
        .iter()
        .find(|case| case.name == "same_key_conflict_refusal")
        .expect("same-key conflict case");
    assert!(conflict.same_idempotency_key);
    assert!(!conflict.same_body);
    assert_eq!(conflict.decision, "refused");
    assert_eq!(conflict.refusal_code, "idempotency_conflict");
}

fn assert_refusal_cases(cases: &[ContractCase]) {
    for (name, code) in [
        ("invalid_currency_refusal", "invalid_currency"),
        ("non_positive_amount_refusal", "non_positive_amount"),
        ("invalid_time_window_refusal", "invalid_time_window"),
        (
            "direct_wallet_snapshot_mutation_forbidden",
            "direct_wallet_snapshot_mutation_forbidden",
        ),
    ] {
        let case = cases.iter().find(|case| case.name == name).unwrap();
        assert_eq!(case.decision, "refused");
        assert_eq!(case.refusal_code, code);
        assert_eq!(
            case.response.get("refusal_code").and_then(Value::as_str),
            Some(code),
            "{name} response refusal code"
        );
    }
}
