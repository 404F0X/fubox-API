use ai_gateway_billing_ledger::{
    FixedDecimal, LedgerContractError, LedgerEntryRecord, LedgerEntryStatus, LedgerEntryType,
    LedgerOperationOutcome, RefundLedgerRequest, ReserveLedgerRequest, SettleLedgerRequest,
    plan_ledger_refund, plan_ledger_reserve, plan_ledger_settle,
};
use serde::Deserialize;
use uuid::Uuid;

const FIXTURE: &str =
    include_str!("../../../tests/fixtures/billing/reserve_settle_refund_ledger_contract.json");
const MONEY_SCALE: u32 = 8;

#[derive(Debug, Deserialize)]
struct ContractFixture {
    contract: String,
    secret_safe_forbidden_terms: Vec<String>,
    cases: Vec<CaseFixture>,
}

#[derive(Debug, Deserialize)]
struct CaseFixture {
    name: String,
    operation: String,
    request: serde_json::Value,
    existing_entries: Vec<EntryFixture>,
    expect: Option<ExpectedPlan>,
    expect_error: Option<String>,
}

#[derive(Debug, Deserialize)]
struct EntryFixture {
    id: Uuid,
    #[serde(default)]
    request_id: Option<Uuid>,
    #[serde(default)]
    related_ledger_entry_id: Option<Uuid>,
    entry_type: String,
    amount: String,
    currency: String,
    status: String,
    idempotency_key: String,
}

#[derive(Debug, Deserialize)]
struct ExpectedPlan {
    outcome: String,
    #[serde(default)]
    existing_entry_id: Option<Uuid>,
    idempotency_key: String,
    entries: Vec<ExpectedEntry>,
    status_updates: Vec<ExpectedStatusUpdate>,
}

#[derive(Debug, Deserialize)]
struct ExpectedEntry {
    entry_type: String,
    #[serde(default)]
    related_ledger_entry_id: Option<Uuid>,
    amount: String,
    currency: String,
    status: String,
    metadata: serde_json::Value,
}

#[derive(Debug, Deserialize)]
struct ExpectedStatusUpdate {
    ledger_entry_id: Uuid,
    from: String,
    to: String,
    reason: String,
}

#[test]
fn reserve_settle_refund_contract_fixture_matches_pure_ledger_plans() {
    let fixture: ContractFixture = serde_json::from_str(FIXTURE).expect("fixture should parse");
    assert_eq!(fixture.contract, "billing_ledger_reserve_settle_refund_v2");
    assert_fixture_cases_are_secret_safe(&fixture);

    for case in &fixture.cases {
        let existing_entries = case
            .existing_entries
            .iter()
            .map(to_entry_record)
            .collect::<Vec<_>>();
        let result = run_case(case, &existing_entries);

        match (&case.expect, &case.expect_error, result) {
            (Some(expected), None, Ok(plan)) => {
                assert_eq!(
                    plan.idempotency_key, expected.idempotency_key,
                    "{} idempotency key",
                    case.name
                );
                match (&plan.outcome, expected.outcome.as_str()) {
                    (LedgerOperationOutcome::Apply, "apply") => {}
                    (LedgerOperationOutcome::Idempotent { existing_entry_id }, "idempotent") => {
                        assert_eq!(
                            Some(*existing_entry_id),
                            expected.existing_entry_id,
                            "{} existing id",
                            case.name
                        )
                    }
                    _ => panic!("{} outcome mismatch: {:?}", case.name, plan.outcome),
                }

                assert_eq!(
                    plan.entries.len(),
                    expected.entries.len(),
                    "{} entries",
                    case.name
                );
                for (actual, expected) in plan.entries.iter().zip(&expected.entries) {
                    assert_eq!(
                        serde_json::to_value(actual.entry_type).unwrap(),
                        serde_json::json!(expected.entry_type),
                        "{} entry_type",
                        case.name
                    );
                    assert_eq!(
                        actual.related_ledger_entry_id, expected.related_ledger_entry_id,
                        "{} related_ledger_entry_id",
                        case.name
                    );
                    assert_eq!(
                        actual.amount.to_string(),
                        expected.amount,
                        "{} amount",
                        case.name
                    );
                    assert_eq!(actual.currency, expected.currency, "{} currency", case.name);
                    assert_eq!(
                        serde_json::to_value(actual.status).unwrap(),
                        serde_json::json!(expected.status),
                        "{} status",
                        case.name
                    );
                    assert_eq!(
                        serde_json::to_value(&actual.metadata).unwrap(),
                        expected.metadata,
                        "{} metadata",
                        case.name
                    );
                    assert_secret_safe_value(
                        &serde_json::to_value(&actual.metadata).unwrap(),
                        &fixture.secret_safe_forbidden_terms,
                        &case.name,
                    );
                }

                assert_eq!(
                    plan.status_updates.len(),
                    expected.status_updates.len(),
                    "{} status_updates",
                    case.name
                );
                for (actual, expected) in plan.status_updates.iter().zip(&expected.status_updates) {
                    assert_eq!(
                        actual.ledger_entry_id, expected.ledger_entry_id,
                        "{} status update id",
                        case.name
                    );
                    assert_eq!(
                        serde_json::to_value(actual.from).unwrap(),
                        serde_json::json!(expected.from),
                        "{} status update from",
                        case.name
                    );
                    assert_eq!(
                        serde_json::to_value(actual.to).unwrap(),
                        serde_json::json!(expected.to),
                        "{} status update to",
                        case.name
                    );
                    assert_eq!(
                        serde_json::to_value(actual.reason).unwrap(),
                        serde_json::json!(expected.reason),
                        "{} status update reason",
                        case.name
                    );
                }
            }
            (None, Some(expected_error), Err(error)) => {
                assert_eq!(
                    error_tag(&error),
                    expected_error,
                    "{} expected error",
                    case.name
                );
            }
            (_, _, outcome) => panic!("{} unexpected outcome: {:?}", case.name, outcome),
        }
    }
}

fn run_case(
    case: &CaseFixture,
    existing_entries: &[LedgerEntryRecord],
) -> Result<ai_gateway_billing_ledger::LedgerOperationPlan, LedgerContractError> {
    match case.operation.as_str() {
        "reserve" => {
            let request: ReserveRequestFixture =
                serde_json::from_value(case.request.clone()).expect("reserve request");
            plan_ledger_reserve(
                ReserveLedgerRequest {
                    request_id: request.request_id,
                    amount: money(&request.amount),
                    currency: request.currency,
                },
                existing_entries,
            )
        }
        "settle" => {
            let request: SettleRequestFixture =
                serde_json::from_value(case.request.clone()).expect("settle request");
            plan_ledger_settle(
                SettleLedgerRequest {
                    request_id: request.request_id,
                    final_cost: money(&request.final_cost),
                    currency: request.currency,
                },
                existing_entries,
            )
        }
        "refund_full" => {
            let request: FullRefundRequestFixture =
                serde_json::from_value(case.request.clone()).expect("full refund request");
            plan_ledger_refund(
                RefundLedgerRequest::Full {
                    related_ledger_entry_id: request.related_ledger_entry_id,
                    currency: request.currency,
                    amount: None,
                },
                existing_entries,
            )
        }
        "refund_partial" => {
            let request: PartialRefundRequestFixture =
                serde_json::from_value(case.request.clone()).expect("partial refund request");
            plan_ledger_refund(
                RefundLedgerRequest::Partial {
                    related_ledger_entry_id: request.related_ledger_entry_id,
                    refund_operation_id: Some(request.refund_operation_id),
                    amount: Some(money(&request.amount)),
                    currency: request.currency,
                },
                existing_entries,
            )
        }
        operation => panic!("unsupported fixture operation `{operation}`"),
    }
}

#[derive(Debug, Deserialize)]
struct ReserveRequestFixture {
    request_id: Uuid,
    amount: String,
    currency: String,
}

#[derive(Debug, Deserialize)]
struct SettleRequestFixture {
    request_id: Uuid,
    final_cost: String,
    currency: String,
}

#[derive(Debug, Deserialize)]
struct FullRefundRequestFixture {
    related_ledger_entry_id: Uuid,
    currency: String,
}

#[derive(Debug, Deserialize)]
struct PartialRefundRequestFixture {
    related_ledger_entry_id: Uuid,
    refund_operation_id: Uuid,
    amount: String,
    currency: String,
}

fn to_entry_record(entry: &EntryFixture) -> LedgerEntryRecord {
    LedgerEntryRecord {
        id: entry.id,
        request_id: entry.request_id,
        related_ledger_entry_id: entry.related_ledger_entry_id,
        entry_type: match entry.entry_type.as_str() {
            "reserve" => LedgerEntryType::Reserve,
            "settle" => LedgerEntryType::Settle,
            "refund" => LedgerEntryType::Refund,
            entry_type => panic!("unsupported fixture entry_type `{entry_type}`"),
        },
        amount: money(&entry.amount),
        currency: entry.currency.clone(),
        status: match entry.status.as_str() {
            "pending" => LedgerEntryStatus::Pending,
            "confirmed" => LedgerEntryStatus::Confirmed,
            "reversed" => LedgerEntryStatus::Reversed,
            status => panic!("unsupported fixture status `{status}`"),
        },
        idempotency_key: entry.idempotency_key.clone(),
    }
}

fn money(value: &str) -> FixedDecimal {
    FixedDecimal::parse(value, MONEY_SCALE).expect("valid fixture money")
}

fn error_tag(error: &LedgerContractError) -> &'static str {
    match error {
        LedgerContractError::IdempotencyConflict { .. } => "idempotency_conflict",
        LedgerContractError::RequestAlreadySettled { .. } => "request_already_settled",
        LedgerContractError::RequestAlreadyReserved { .. } => "request_already_reserved",
        LedgerContractError::RefundSourceNotFound { .. } => "refund_source_not_found",
        LedgerContractError::RefundSourceNotConfirmedSettleDebit { .. } => {
            "refund_source_not_confirmed_settle_debit"
        }
        LedgerContractError::RefundCurrencyMismatch { .. } => "refund_currency_mismatch",
        LedgerContractError::RefundAmountExceedsRemaining { .. } => {
            "refund_amount_exceeds_remaining"
        }
        LedgerContractError::PartialRefundConsumesRemaining { .. } => {
            "partial_refund_consumes_remaining"
        }
        LedgerContractError::AdminAdjustmentZeroAmount => "admin_adjustment_zero_amount",
        LedgerContractError::PartialRefundAmountRequired => "partial_refund_amount_required",
        LedgerContractError::PartialRefundOperationIdRequired => {
            "partial_refund_operation_id_required"
        }
        LedgerContractError::FullRefundAmountNotAllowed => "full_refund_amount_not_allowed",
        LedgerContractError::NonPositiveAmount { .. } => "non_positive_amount",
        LedgerContractError::InvalidCurrency { .. } => "invalid_currency",
        LedgerContractError::ReserveCurrencyMismatch { .. } => "reserve_currency_mismatch",
        LedgerContractError::ScaleMismatch { .. } => "scale_mismatch",
        LedgerContractError::ArithmeticOverflow => "arithmetic_overflow",
    }
}

fn assert_fixture_cases_are_secret_safe(fixture: &ContractFixture) {
    let raw_fixture: serde_json::Value = serde_json::from_str(FIXTURE).expect("fixture value");
    let cases = raw_fixture
        .get("cases")
        .expect("fixture should contain cases");
    assert_secret_safe_value(cases, &fixture.secret_safe_forbidden_terms, "fixture cases");
}

fn assert_secret_safe_value(value: &serde_json::Value, forbidden_terms: &[String], label: &str) {
    let serialized = serde_json::to_string(value)
        .expect("secret-safe value should serialize")
        .to_ascii_lowercase();
    for forbidden in forbidden_terms {
        assert!(
            !serialized.contains(&forbidden.to_ascii_lowercase()),
            "{label} contains forbidden term `{forbidden}`"
        );
    }
}
