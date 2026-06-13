use serde::{Deserialize, Serialize};
use serde_json::Value;

const FIXTURE: &str =
    include_str!("../../../tests/fixtures/billing/user_remaining_balance_contract.json");

#[derive(Debug, Deserialize)]
struct UserRemainingBalanceContract {
    schema: String,
    status: String,
    runtime_implemented: bool,
    contract_only: bool,
    control_plane_endpoint_present: bool,
    paid_gate_changed: bool,
    read_only: bool,
    secret_safe: bool,
    money_contract: MoneyContract,
    ownership_scope_contract: OwnershipScopeContract,
    read_model_formula: ReadModelFormula,
    bounded_output_contract: BoundedOutputContract,
    allowed_consistency_markers: Vec<String>,
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
struct OwnershipScopeContract {
    tenant_scope_required: bool,
    project_scope_required: bool,
    user_scope_or_developer_token_required: bool,
    wallet_scope_check_required: bool,
    currency_check_required: bool,
}

#[derive(Debug, Deserialize)]
struct ReadModelFormula {
    formula: String,
    wallet_balance_floor_sign: String,
    active_grants_only: bool,
    expired_grants_counted: bool,
    revoked_grants_counted: bool,
    pending_ledger_window_included: bool,
    confirmed_ledger_window_included: bool,
    budget_remaining_included: bool,
}

#[derive(Debug, Deserialize)]
struct BoundedOutputContract {
    max_credit_grant_ids: usize,
    max_ledger_entry_ids: usize,
    raw_metadata_output_allowed: bool,
    raw_request_payload_output_allowed: bool,
    forbidden_output_terms: Vec<String>,
}

#[derive(Debug, Deserialize, Serialize)]
struct ContractCase {
    name: String,
    decision: String,
    read_only: bool,
    #[serde(default)]
    refusal_code: String,
    #[serde(default)]
    ownership_scope: Value,
    #[serde(default)]
    request: Value,
    #[serde(default)]
    inputs: Value,
    response: Value,
    mutations: MutationContract,
}

#[derive(Debug, Deserialize, Serialize)]
struct MutationContract {
    ledger_entries_written: bool,
    credit_grants_written: bool,
    audit_logs_written: bool,
    wallet_snapshot_mutated: bool,
}

#[test]
fn user_remaining_balance_contract_fixture_enforces_read_model_invariants() {
    let fixture: UserRemainingBalanceContract =
        serde_json::from_str(FIXTURE).expect("fixture parses");
    assert_eq!(fixture.schema, "user_remaining_balance_contract.v1");
    assert_eq!(fixture.status, "contract_enforced_not_runtime_wired");
    assert!(!fixture.runtime_implemented);
    assert!(fixture.contract_only);
    assert!(!fixture.control_plane_endpoint_present);
    assert!(!fixture.paid_gate_changed);
    assert!(fixture.read_only);
    assert!(fixture.secret_safe);
    assert_money_contract(&fixture.money_contract);
    assert_ownership_contract(&fixture.ownership_scope_contract);
    assert_formula_contract(&fixture.read_model_formula);
    assert_bounded_contract(&fixture.bounded_output_contract);

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
        assert_read_only(case);
        assert_money_fields(case, fixture.money_contract.scale);
        assert_consistency_marker(case, &fixture.allowed_consistency_markers);
        assert_bounded_ids(case, &fixture.bounded_output_contract);
        assert_secret_safe(
            case,
            &fixture.bounded_output_contract.forbidden_output_terms,
        );
    }

    assert_formula_case(&fixture.cases);
    assert_excluded_grants_case(&fixture.cases);
    assert_refusal_cases(&fixture.cases);
}

fn assert_money_contract(contract: &MoneyContract) {
    assert_eq!(contract.format, "decimal_string_with_currency");
    assert_eq!(contract.scale, 8);
    assert!(!contract.float_allowed);
}

fn assert_ownership_contract(contract: &OwnershipScopeContract) {
    assert!(contract.tenant_scope_required);
    assert!(contract.project_scope_required);
    assert!(contract.user_scope_or_developer_token_required);
    assert!(contract.wallet_scope_check_required);
    assert!(contract.currency_check_required);
}

fn assert_formula_contract(contract: &ReadModelFormula) {
    assert_eq!(
        contract.formula,
        "active_credit_grant_total + pending_confirmed_ledger_window - wallet_balance_floor"
    );
    assert_eq!(contract.wallet_balance_floor_sign, "subtract");
    assert!(contract.active_grants_only);
    assert!(!contract.expired_grants_counted);
    assert!(!contract.revoked_grants_counted);
    assert!(contract.pending_ledger_window_included);
    assert!(contract.confirmed_ledger_window_included);
    assert!(contract.budget_remaining_included);
}

fn assert_bounded_contract(contract: &BoundedOutputContract) {
    assert!(contract.max_credit_grant_ids > 0);
    assert!(contract.max_ledger_entry_ids > 0);
    assert!(!contract.raw_metadata_output_allowed);
    assert!(!contract.raw_request_payload_output_allowed);
}

fn assert_case_shape(case: &ContractCase, fixture: &UserRemainingBalanceContract) {
    assert!(!case.name.trim().is_empty());
    assert!(case.read_only);
    assert_eq!(
        case.response.get("read_only").and_then(Value::as_bool),
        Some(true),
        "{} response must be read_only",
        case.name
    );
    assert_eq!(
        case.response.get("secret_safe").and_then(Value::as_bool),
        Some(true),
        "{} response must be secret_safe",
        case.name
    );
    if case.decision == "summary_returned" {
        assert_decimal_string(
            case.response
                .get("available_to_spend")
                .unwrap_or_else(|| panic!("{} missing available_to_spend", case.name)),
            fixture.money_contract.scale,
            &case.name,
            "available_to_spend",
        );
        assert!(
            case.response
                .get("budget_remaining")
                .and_then(Value::as_str)
                .is_some(),
            "{} must include budget_remaining",
            case.name
        );
    }
}

fn assert_read_only(case: &ContractCase) {
    assert!(!case.mutations.ledger_entries_written);
    assert!(!case.mutations.credit_grants_written);
    assert!(!case.mutations.audit_logs_written);
    assert!(!case.mutations.wallet_snapshot_mutated);
}

fn assert_money_fields(case: &ContractCase, scale: usize) {
    visit_money_strings(&case.inputs, scale, &case.name);
    visit_money_strings(&case.response, scale, &case.name);
    for container in [&case.request, &case.inputs, &case.response] {
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
                    || key.contains("balance")
                    || key.contains("total")
                    || key.contains("effect")
                    || key == "available_to_spend"
                    || key == "budget_remaining"
                    || key == "wallet_balance_floor"
                    || key == "pending_confirmed_ledger_window"
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

fn assert_consistency_marker(case: &ContractCase, allowed: &[String]) {
    if case.decision != "summary_returned" {
        return;
    }
    let marker = case
        .response
        .get("consistency")
        .and_then(Value::as_str)
        .unwrap_or_else(|| panic!("{} missing consistency marker", case.name));
    assert!(
        allowed.iter().any(|allowed| allowed == marker),
        "{} unsupported consistency marker {marker}",
        case.name
    );
}

fn assert_bounded_ids(case: &ContractCase, contract: &BoundedOutputContract) {
    if case.decision != "summary_returned" {
        return;
    }
    let grant_ids = case
        .response
        .get("bounded_credit_grant_ids")
        .and_then(Value::as_array)
        .unwrap_or_else(|| panic!("{} missing bounded grant ids", case.name));
    let ledger_ids = case
        .response
        .get("bounded_ledger_entry_ids")
        .and_then(Value::as_array)
        .unwrap_or_else(|| panic!("{} missing bounded ledger ids", case.name));
    assert!(grant_ids.len() <= contract.max_credit_grant_ids);
    assert!(ledger_ids.len() <= contract.max_ledger_entry_ids);
    for id in grant_ids.iter().chain(ledger_ids.iter()) {
        let text = id.as_str().expect("bounded id must be string");
        assert_eq!(text.len(), 36, "bounded id must be UUID-like");
    }
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

fn assert_formula_case(cases: &[ContractCase]) {
    let case = cases
        .iter()
        .find(|case| case.name == "strong_summary_applies_formula")
        .expect("strong formula case");
    assert_eq!(
        case.response
            .get("available_to_spend")
            .and_then(Value::as_str),
        Some("18.00000000")
    );
    assert_eq!(
        case.inputs
            .get("active_credit_grant_total")
            .and_then(Value::as_str),
        Some("30.00000000")
    );
    assert_eq!(
        case.inputs
            .get("pending_confirmed_ledger_window")
            .and_then(Value::as_str),
        Some("-10.00000000")
    );
    assert_eq!(
        case.inputs
            .get("wallet_balance_floor")
            .and_then(Value::as_str),
        Some("2.00000000")
    );
}

fn assert_excluded_grants_case(cases: &[ContractCase]) {
    let case = cases
        .iter()
        .find(|case| case.name == "expired_and_revoked_grants_excluded")
        .expect("excluded grants case");
    assert_eq!(
        case.response
            .get("available_to_spend")
            .and_then(Value::as_str),
        Some("11.00000000")
    );
    assert_eq!(
        case.response
            .get("excluded_expired_credit_grant_total")
            .and_then(Value::as_str),
        Some("20.00000000")
    );
    assert_eq!(
        case.response
            .get("excluded_revoked_credit_grant_total")
            .and_then(Value::as_str),
        Some("7.50000000")
    );
}

fn assert_refusal_cases(cases: &[ContractCase]) {
    for (name, code) in [
        ("currency_mismatch_refusal", "currency_mismatch"),
        ("missing_wallet_refusal", "wallet_not_found"),
        ("ownership_mismatch_refusal", "ownership_scope_mismatch"),
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
