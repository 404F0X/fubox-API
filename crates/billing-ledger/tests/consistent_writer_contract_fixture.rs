use ai_gateway_billing_ledger::{
    CONSISTENT_LEDGER_WRITER_SCHEMA, ConsistentBudgetDimension, ConsistentBudgetSnapshot,
    ConsistentCreditGrantSnapshot, ConsistentLedgerScope, ConsistentLedgerWriteRequest,
    ConsistentLedgerWriterError, ConsistentLedgerWriterState, ConsistentWalletSnapshot,
    FixedDecimal, LedgerContractError, LedgerEntryRecord, LedgerEntryStatus, LedgerEntryType,
    LedgerOperationOutcome, plan_consistent_ledger_write,
};
use serde::Deserialize;
use uuid::Uuid;

const FIXTURE: &str =
    include_str!("../../../tests/fixtures/billing/consistent_writer_contract.json");
const MONEY_SCALE: u32 = 8;

#[derive(Debug, Deserialize)]
struct ContractFixture {
    contract: String,
    secret_safe_forbidden_terms: Vec<String>,
    scope: ScopeFixture,
    lock_contract: LockContractFixture,
    cases: Vec<CaseFixture>,
}

#[derive(Debug, Deserialize)]
struct ScopeFixture {
    tenant_id: Uuid,
    project_id: Option<Uuid>,
    virtual_key_id: Option<Uuid>,
}

#[derive(Debug, Deserialize)]
struct LockContractFixture {
    transaction: String,
    lock_order: Vec<String>,
    bounded_ledger_reads: Vec<String>,
    for_update_required: bool,
    unbounded_scan_allowed: bool,
}

#[derive(Debug, Deserialize)]
struct CaseFixture {
    name: String,
    operation: String,
    request: serde_json::Value,
    state: StateFixture,
    #[serde(default)]
    expect: Option<ExpectedPlan>,
    #[serde(default)]
    expect_error: Option<String>,
}

#[derive(Debug, Deserialize)]
struct StateFixture {
    wallet: WalletFixture,
    #[serde(default)]
    credit_grants: Vec<CreditGrantFixture>,
    #[serde(default)]
    budgets: Vec<BudgetFixture>,
    #[serde(default)]
    ledger_entries: Vec<EntryFixture>,
}

#[derive(Debug, Deserialize)]
struct WalletFixture {
    wallet_id: Uuid,
    currency: String,
    available_balance: String,
}

#[derive(Debug, Deserialize)]
struct CreditGrantFixture {
    grant_id: Uuid,
    currency: String,
    remaining_amount: String,
    active: bool,
}

#[derive(Debug, Deserialize)]
struct BudgetFixture {
    budget_id: Uuid,
    dimension: ConsistentBudgetDimension,
    currency: String,
    remaining_amount: String,
    active: bool,
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
    idempotency_key: String,
    available_before_write: String,
    required_debit: String,
    refund_credit: String,
    available_after_write: String,
    ledger_entry_count: usize,
    status_update_count: usize,
    budget_after: Vec<(String, String, bool)>,
}

#[test]
fn consistent_writer_contract_fixture_matches_plan() {
    let fixture: ContractFixture = serde_json::from_str(FIXTURE).expect("fixture should parse");
    assert_eq!(fixture.contract, "billing_ledger_consistent_writer_plan_v1");

    for case in &fixture.cases {
        let request = request_from_fixture(&fixture.scope, case);
        let state = state_from_fixture(&case.state);
        let result = plan_consistent_ledger_write(request, &state);

        match (&case.expect, &case.expect_error, result) {
            (Some(expected), None, Ok(plan)) => {
                assert_eq!(
                    plan.schema_version, CONSISTENT_LEDGER_WRITER_SCHEMA,
                    "{} schema",
                    case.name
                );
                assert_lock_contract(&plan, &fixture.lock_contract, &case.name);
                assert_eq!(
                    plan.idempotency_key, expected.idempotency_key,
                    "{} idempotency key",
                    case.name
                );
                match (&plan.outcome, expected.outcome.as_str()) {
                    (LedgerOperationOutcome::Apply, "apply") => {}
                    (LedgerOperationOutcome::Idempotent { .. }, "idempotent") => {}
                    _ => panic!("{} outcome mismatch: {:?}", case.name, plan.outcome),
                }
                assert_eq!(
                    plan.balance_window.available_before_write.to_string(),
                    expected.available_before_write,
                    "{} available_before_write",
                    case.name
                );
                assert_eq!(
                    plan.balance_window.required_debit.to_string(),
                    expected.required_debit,
                    "{} required_debit",
                    case.name
                );
                assert_eq!(
                    plan.balance_window.refund_credit.to_string(),
                    expected.refund_credit,
                    "{} refund_credit",
                    case.name
                );
                assert_eq!(
                    plan.balance_window.available_after_write.to_string(),
                    expected.available_after_write,
                    "{} available_after_write",
                    case.name
                );
                assert_eq!(
                    plan.ledger_plan.entries.len(),
                    expected.ledger_entry_count,
                    "{} ledger entries",
                    case.name
                );
                assert_eq!(
                    plan.ledger_plan.status_updates.len(),
                    expected.status_update_count,
                    "{} status updates",
                    case.name
                );
                assert_budget_checks(&plan, &expected.budget_after, &case.name);
                assert!(plan.wallet_check.passed, "{} wallet check", case.name);
                assert!(
                    plan.postgres_writer_contract
                        .cursor_or_scan_policy
                        .contains("bounded"),
                    "{} bounded scan contract",
                    case.name
                );
                assert!(
                    plan.state_machine
                        .concurrency_rejections
                        .contains(&"non_idempotent_duplicate_settle_for_request"),
                    "{} duplicate settle rejection contract",
                    case.name
                );

                let serialized = serde_json::to_string(&plan).expect("plan should serialize");
                assert_secret_safe_text(
                    &serialized,
                    &fixture.secret_safe_forbidden_terms,
                    &case.name,
                );
            }
            (None, Some(expected_error), Err(error)) => {
                assert_eq!(
                    error_tag(&error),
                    expected_error,
                    "{} expected error",
                    case.name
                );
                assert_secret_safe_text(
                    &error.to_string(),
                    &fixture.secret_safe_forbidden_terms,
                    &case.name,
                );
            }
            (_, _, outcome) => panic!("{} unexpected outcome: {:?}", case.name, outcome),
        }
    }
}

fn request_from_fixture(scope: &ScopeFixture, case: &CaseFixture) -> ConsistentLedgerWriteRequest {
    let scope = ConsistentLedgerScope {
        tenant_id: scope.tenant_id,
        project_id: scope.project_id,
        virtual_key_id: scope.virtual_key_id,
    };
    match case.operation.as_str() {
        "reserve" => {
            let request: ReserveRequestFixture =
                serde_json::from_value(case.request.clone()).expect("reserve request");
            ConsistentLedgerWriteRequest::Reserve {
                scope,
                request_id: request.request_id,
                amount: money(&request.amount),
                currency: request.currency,
            }
        }
        "settle" => {
            let request: SettleRequestFixture =
                serde_json::from_value(case.request.clone()).expect("settle request");
            ConsistentLedgerWriteRequest::Settle {
                scope,
                request_id: request.request_id,
                final_cost: money(&request.final_cost),
                currency: request.currency,
            }
        }
        "refund_full" => {
            let request: FullRefundRequestFixture =
                serde_json::from_value(case.request.clone()).expect("full refund request");
            ConsistentLedgerWriteRequest::RefundFull {
                scope,
                related_ledger_entry_id: request.related_ledger_entry_id,
                currency: request.currency,
            }
        }
        "refund_partial" => {
            let request: PartialRefundRequestFixture =
                serde_json::from_value(case.request.clone()).expect("partial refund request");
            ConsistentLedgerWriteRequest::RefundPartial {
                scope,
                related_ledger_entry_id: request.related_ledger_entry_id,
                refund_operation_id: request.refund_operation_id,
                amount: money(&request.amount),
                currency: request.currency,
            }
        }
        operation => panic!("unsupported operation `{operation}`"),
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

fn state_from_fixture(state: &StateFixture) -> ConsistentLedgerWriterState {
    ConsistentLedgerWriterState {
        wallet: Some(ConsistentWalletSnapshot {
            wallet_id: state.wallet.wallet_id,
            currency: state.wallet.currency.clone(),
            available_balance: money(&state.wallet.available_balance),
        }),
        credit_grants: state
            .credit_grants
            .iter()
            .map(|grant| ConsistentCreditGrantSnapshot {
                grant_id: grant.grant_id,
                currency: grant.currency.clone(),
                remaining_amount: money(&grant.remaining_amount),
                active: grant.active,
            })
            .collect(),
        budgets: state
            .budgets
            .iter()
            .map(|budget| ConsistentBudgetSnapshot {
                budget_id: budget.budget_id,
                dimension: budget.dimension,
                currency: budget.currency.clone(),
                remaining_amount: money(&budget.remaining_amount),
                active: budget.active,
            })
            .collect(),
        ledger_entries: state.ledger_entries.iter().map(entry_record).collect(),
    }
}

fn entry_record(entry: &EntryFixture) -> LedgerEntryRecord {
    LedgerEntryRecord {
        id: entry.id,
        request_id: entry.request_id,
        related_ledger_entry_id: entry.related_ledger_entry_id,
        entry_type: match entry.entry_type.as_str() {
            "reserve" => LedgerEntryType::Reserve,
            "settle" => LedgerEntryType::Settle,
            "refund" => LedgerEntryType::Refund,
            entry_type => panic!("unsupported entry_type `{entry_type}`"),
        },
        amount: money(&entry.amount),
        currency: entry.currency.clone(),
        status: match entry.status.as_str() {
            "pending" => LedgerEntryStatus::Pending,
            "confirmed" => LedgerEntryStatus::Confirmed,
            "reversed" => LedgerEntryStatus::Reversed,
            status => panic!("unsupported status `{status}`"),
        },
        idempotency_key: entry.idempotency_key.clone(),
    }
}

fn assert_lock_contract(
    plan: &ai_gateway_billing_ledger::ConsistentLedgerWriterPlan,
    expected: &LockContractFixture,
    label: &str,
) {
    assert_eq!(
        plan.lock_plan.transaction, expected.transaction,
        "{label} tx"
    );
    assert!(expected.for_update_required, "{label} fixture contract");
    assert!(!expected.unbounded_scan_allowed, "{label} fixture contract");
    let actual_order = plan
        .lock_plan
        .lock_order
        .iter()
        .map(|step| step.resource.to_string())
        .collect::<Vec<_>>();
    assert_eq!(actual_order, expected.lock_order, "{label} lock order");
    for step in &plan.lock_plan.lock_order {
        assert!(
            step.lock_mode.contains("for_update"),
            "{label} lock step {} must use FOR UPDATE",
            step.resource
        );
    }
    let ledger_step = plan
        .lock_plan
        .lock_order
        .iter()
        .find(|step| step.resource == "ledger_entries")
        .expect("ledger lock step");
    for key in &expected.bounded_ledger_reads {
        assert!(
            ledger_step.bounded_by.iter().any(|actual| actual == key),
            "{label} ledger step missing bound `{key}`"
        );
    }
}

fn assert_budget_checks(
    plan: &ai_gateway_billing_ledger::ConsistentLedgerWriterPlan,
    expected: &[(String, String, bool)],
    label: &str,
) {
    assert_eq!(
        plan.budget_checks.len(),
        expected.len(),
        "{label} budget checks"
    );
    for (actual, expected) in plan.budget_checks.iter().zip(expected) {
        assert_eq!(actual.dimension.as_str(), expected.0, "{label} dimension");
        assert_eq!(
            actual.remaining_after_write.to_string(),
            expected.1,
            "{label} remaining"
        );
        assert_eq!(actual.passed, expected.2, "{label} budget pass");
    }
}

fn error_tag(error: &ConsistentLedgerWriterError) -> &'static str {
    match error {
        ConsistentLedgerWriterError::WalletRequired => "wallet_required",
        ConsistentLedgerWriterError::WalletCurrencyMismatch { .. } => "wallet_currency_mismatch",
        ConsistentLedgerWriterError::InsufficientWalletBalance { .. } => {
            "insufficient_wallet_balance"
        }
        ConsistentLedgerWriterError::InsufficientBudget { .. } => "insufficient_budget",
        ConsistentLedgerWriterError::ScaleMismatch { .. } => "scale_mismatch",
        ConsistentLedgerWriterError::ArithmeticOverflow => "arithmetic_overflow",
        ConsistentLedgerWriterError::InMemoryStateConflict { .. } => "in_memory_state_conflict",
        ConsistentLedgerWriterError::Ledger(error) => ledger_error_tag(error),
    }
}

fn ledger_error_tag(error: &LedgerContractError) -> &'static str {
    match error {
        LedgerContractError::IdempotencyConflict { .. } => "idempotency_conflict",
        LedgerContractError::RequestAlreadySettled { .. } => "request_already_settled",
        LedgerContractError::RequestAlreadyReserved { .. } => "request_already_reserved",
        LedgerContractError::RefundSourceNotFound { .. } => "refund_source_not_found",
        LedgerContractError::RefundSourceNotConfirmedSettleDebit { .. } => {
            "refund_source_not_confirmed_settle_debit"
        }
        LedgerContractError::RefundCurrencyMismatch { .. } => "refund_currency_mismatch",
        LedgerContractError::FullRefundAmountNotAllowed => "full_refund_amount_not_allowed",
        LedgerContractError::PartialRefundAmountRequired => "partial_refund_amount_required",
        LedgerContractError::PartialRefundOperationIdRequired => {
            "partial_refund_operation_id_required"
        }
        LedgerContractError::PartialRefundConsumesRemaining { .. } => {
            "partial_refund_consumes_remaining"
        }
        LedgerContractError::AdminAdjustmentZeroAmount => "admin_adjustment_zero_amount",
        LedgerContractError::RefundAmountExceedsRemaining { .. } => {
            "refund_amount_exceeds_remaining"
        }
        LedgerContractError::NonPositiveAmount { .. } => "non_positive_amount",
        LedgerContractError::InvalidCurrency { .. } => "invalid_currency",
        LedgerContractError::ReserveCurrencyMismatch { .. } => "reserve_currency_mismatch",
        LedgerContractError::ScaleMismatch { .. } => "ledger_scale_mismatch",
        LedgerContractError::ArithmeticOverflow => "ledger_arithmetic_overflow",
    }
}

fn money(value: &str) -> FixedDecimal {
    FixedDecimal::parse(value, MONEY_SCALE).expect("valid fixture money")
}

fn assert_secret_safe_text(serialized: &str, forbidden_terms: &[String], label: &str) {
    let normalized = serialized.to_ascii_lowercase();
    for forbidden in forbidden_terms {
        assert!(
            !normalized.contains(&forbidden.to_ascii_lowercase()),
            "{label} contains forbidden term `{forbidden}`"
        );
    }
}
