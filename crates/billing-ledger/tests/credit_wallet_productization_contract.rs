use serde::{Deserialize, Serialize};
use serde_json::Value;

const FIXTURE: &str =
    include_str!("../../../tests/fixtures/billing/credit_wallet_productization_contract.json");

#[derive(Debug, Deserialize)]
struct ContractFixture {
    contract: String,
    status: String,
    controlled_paid_beta_blocker: bool,
    broader_commercial_distribution_blocker: bool,
    money_contract: MoneyContract,
    secret_safe_forbidden_terms: Vec<String>,
    allowed_accounting_markers: Vec<String>,
    endpoints: Vec<EndpointContract>,
    negative_contract_cases: Vec<NegativeContractCase>,
}

#[derive(Debug, Deserialize)]
struct MoneyContract {
    format: String,
    float_allowed: bool,
    scale: usize,
}

#[derive(Debug, Deserialize, Serialize)]
struct EndpointContract {
    name: String,
    method: String,
    path: String,
    write: bool,
    idempotency_required: bool,
    audit_required: bool,
    direct_wallet_snapshot_mutation_allowed: bool,
    accounting_markers: Vec<String>,
    request_money_fields: Vec<String>,
    response_money_fields: Vec<String>,
    request: Value,
    response: Value,
    #[serde(default)]
    idempotency_cases: Vec<IdempotencyCase>,
}

#[derive(Debug, Deserialize, Serialize)]
struct IdempotencyCase {
    name: String,
    same_idempotency_key: bool,
    same_body: bool,
    expected: String,
}

#[derive(Debug, Deserialize)]
struct NegativeContractCase {
    name: String,
    operation: String,
    direct_wallet_snapshot_mutation_allowed: bool,
    required_refusal: String,
}

#[test]
fn credit_wallet_productization_contract_fixture_enforces_invariants() {
    let fixture: ContractFixture = serde_json::from_str(FIXTURE).expect("fixture should parse");
    assert_eq!(
        fixture.contract,
        "billing_credit_wallet_productization_contract_v1"
    );
    assert_eq!(fixture.status, "contract_enforced_not_runtime_wired");
    assert!(
        !fixture.controlled_paid_beta_blocker,
        "TODO-32B must not block controlled paid beta"
    );
    assert!(
        fixture.broader_commercial_distribution_blocker,
        "TODO-32B must block broader commercial distribution"
    );
    assert_eq!(
        fixture.money_contract.format,
        "decimal_string_with_currency"
    );
    assert!(!fixture.money_contract.float_allowed);
    assert_eq!(fixture.money_contract.scale, 8);

    let endpoint_names = fixture
        .endpoints
        .iter()
        .map(|endpoint| endpoint.name.as_str())
        .collect::<Vec<_>>();
    for required in [
        "credit_grant_create_applied",
        "credit_grant_list_read_model",
        "credit_grant_expire_applied",
        "credit_grant_revoke_applied",
        "remaining_balance_summary_read_model",
        "opening_balance_import_applied",
        "admin_adjustment_applied",
    ] {
        assert!(
            endpoint_names.contains(&required),
            "missing endpoint contract `{required}`"
        );
    }

    for endpoint in &fixture.endpoints {
        assert_endpoint_shape(endpoint);
        assert_money_fields(endpoint, fixture.money_contract.scale);
        assert_secret_safe(endpoint, &fixture.secret_safe_forbidden_terms);
        assert_wallet_snapshot_is_not_accounting_fact(endpoint);
        assert_write_accounting_markers(endpoint, &fixture.allowed_accounting_markers);
        assert_idempotency_contract(endpoint);
    }

    assert_negative_contract_cases(&fixture.negative_contract_cases);
}

fn assert_endpoint_shape(endpoint: &EndpointContract) {
    assert!(
        !endpoint.name.trim().is_empty(),
        "endpoint name must be present"
    );
    assert!(
        matches!(endpoint.method.as_str(), "GET" | "POST"),
        "{} method must be stable",
        endpoint.name
    );
    assert!(
        endpoint.path.starts_with("/billing/"),
        "{} path must stay under billing API",
        endpoint.name
    );
    if endpoint.write {
        assert!(
            endpoint.idempotency_required,
            "{} write endpoint must require idempotency",
            endpoint.name
        );
        assert!(
            endpoint.audit_required,
            "{} write endpoint must require audit",
            endpoint.name
        );
        assert_string_field(&endpoint.request, "idempotency_key", &endpoint.name);
        assert_string_field(&endpoint.request, "reason", &endpoint.name);
        assert_string_field(&endpoint.request, "actor_id", &endpoint.name);
        assert_string_field(&endpoint.request, "actor_type", &endpoint.name);
        assert_string_field(&endpoint.response, "idempotency", &endpoint.name);
        assert_string_field(&endpoint.response, "audit_id", &endpoint.name);
    }
}

fn assert_money_fields(endpoint: &EndpointContract, scale: usize) {
    for field in &endpoint.request_money_fields {
        let value = endpoint
            .request
            .get(field)
            .unwrap_or_else(|| panic!("{} missing request money field `{field}`", endpoint.name));
        assert_decimal_string(value, scale, &endpoint.name, field);
    }
    for field in &endpoint.response_money_fields {
        if let Some(value) = endpoint.response.get(field) {
            assert_decimal_string(value, scale, &endpoint.name, field);
            continue;
        }
        if let Some(items) = endpoint.response.get("items").and_then(Value::as_array) {
            assert!(
                !items.is_empty(),
                "{} list response must include at least one item for money field `{field}`",
                endpoint.name
            );
            for item in items {
                let value = item.get(field).unwrap_or_else(|| {
                    panic!("{} list item missing money field `{field}`", endpoint.name)
                });
                assert_decimal_string(value, scale, &endpoint.name, field);
            }
            continue;
        }
        panic!("{} missing response money field `{field}`", endpoint.name);
    }
    if endpoint
        .request
        .get("currency")
        .or_else(|| endpoint.response.get("currency"))
        .is_some()
    {
        let currency = endpoint
            .request
            .get("currency")
            .or_else(|| endpoint.response.get("currency"))
            .and_then(Value::as_str)
            .expect("currency must be string");
        assert_eq!(currency.len(), 3, "{} currency code shape", endpoint.name);
        assert!(
            currency.chars().all(|ch| ch.is_ascii_uppercase()),
            "{} currency must be uppercase ASCII",
            endpoint.name
        );
    }
}

fn assert_decimal_string(value: &Value, scale: usize, label: &str, field: &str) {
    let text = value
        .as_str()
        .unwrap_or_else(|| panic!("{label}.{field} must be a string, not float/number"));
    let (signless, negative_ok) = if let Some(stripped) = text.strip_prefix('-') {
        (stripped, true)
    } else {
        (text, false)
    };
    assert!(
        !negative_ok || !signless.is_empty(),
        "{label}.{field} invalid negative decimal"
    );
    let (whole, fractional) = signless
        .split_once('.')
        .unwrap_or_else(|| panic!("{label}.{field} must contain decimal point"));
    assert!(
        !whole.is_empty() && whole.chars().all(|ch| ch.is_ascii_digit()),
        "{label}.{field} whole decimal part"
    );
    assert_eq!(
        fractional.len(),
        scale,
        "{label}.{field} must use scale {scale}"
    );
    assert!(
        fractional.chars().all(|ch| ch.is_ascii_digit()),
        "{label}.{field} fractional decimal part"
    );
}

fn assert_secret_safe(endpoint: &EndpointContract, forbidden_terms: &[String]) {
    assert_eq!(
        endpoint
            .response
            .get("secret_safe")
            .and_then(Value::as_bool),
        Some(true),
        "{} response must be secret_safe",
        endpoint.name
    );
    let serialized = serde_json::to_string(endpoint).expect("endpoint should serialize");
    let normalized = serialized.to_ascii_lowercase();
    for term in forbidden_terms {
        assert!(
            !normalized.contains(&term.to_ascii_lowercase()),
            "{} contains forbidden term `{term}`",
            endpoint.name
        );
    }
}

fn assert_wallet_snapshot_is_not_accounting_fact(endpoint: &EndpointContract) {
    assert!(
        !endpoint.direct_wallet_snapshot_mutation_allowed,
        "{} must forbid direct wallet snapshot mutation",
        endpoint.name
    );
    let serialized = serde_json::to_string(endpoint).expect("endpoint should serialize");
    assert!(
        !serialized.contains("direct_wallet_snapshot_update"),
        "{} must not use direct wallet snapshot update marker",
        endpoint.name
    );
}

fn assert_write_accounting_markers(endpoint: &EndpointContract, allowed_markers: &[String]) {
    if !endpoint.write {
        assert!(
            endpoint.accounting_markers.is_empty(),
            "{} read endpoint must not claim write accounting markers",
            endpoint.name
        );
        return;
    }
    assert!(
        !endpoint.accounting_markers.is_empty(),
        "{} write endpoint must produce an accounting marker",
        endpoint.name
    );
    for marker in &endpoint.accounting_markers {
        assert!(
            allowed_markers.contains(marker),
            "{} has unsupported accounting marker `{marker}`",
            endpoint.name
        );
    }
    assert!(
        endpoint.accounting_markers.iter().any(|marker| {
            matches!(
                marker.as_str(),
                "credit_grant_row"
                    | "ledger_entry"
                    | "admin_adjustment_entry"
                    | "opening_entry"
                    | "credit_grant_consumption_row"
            )
        }),
        "{} must produce credit grant/ledger/admin adjustment/opening marker",
        endpoint.name
    );
}

fn assert_idempotency_contract(endpoint: &EndpointContract) {
    if !endpoint.write {
        assert!(
            endpoint.idempotency_cases.is_empty(),
            "{} read endpoint should not define write idempotency cases",
            endpoint.name
        );
        return;
    }
    assert!(
        !endpoint.idempotency_cases.is_empty(),
        "{} write endpoint must define idempotency cases",
        endpoint.name
    );
    assert!(
        endpoint
            .idempotency_cases
            .iter()
            .any(|case| case.same_idempotency_key && case.same_body && case.expected == "replay"),
        "{} must cover idempotent replay",
        endpoint.name
    );
    for case in &endpoint.idempotency_cases {
        assert!(
            !case.name.trim().is_empty(),
            "{} idempotency case name",
            endpoint.name
        );
        if case.same_idempotency_key && !case.same_body {
            assert_eq!(
                case.expected, "conflict_refused",
                "{} same key/different body must refuse",
                endpoint.name
            );
        }
    }
}

fn assert_negative_contract_cases(cases: &[NegativeContractCase]) {
    assert!(
        cases.iter().any(|case| {
            case.name == "direct_wallet_snapshot_mutation_is_not_accounting_fact"
                && case.operation == "opening_balance_import"
                && !case.direct_wallet_snapshot_mutation_allowed
                && case.required_refusal == "direct_wallet_snapshot_mutation_forbidden"
        }),
        "fixture must explicitly forbid direct wallet snapshot mutation"
    );
}

fn assert_string_field(value: &Value, field: &str, label: &str) {
    assert!(
        value
            .get(field)
            .and_then(Value::as_str)
            .is_some_and(|text| !text.trim().is_empty()),
        "{label} missing string field `{field}`"
    );
}
