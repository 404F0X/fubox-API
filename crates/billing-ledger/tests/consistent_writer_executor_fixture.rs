use ai_gateway_billing_ledger::{
    CONSISTENT_LEDGER_COMMAND_EXECUTOR_SCHEMA, ConsistentBudgetDimension, ConsistentBudgetSnapshot,
    ConsistentCreditGrantSnapshot, ConsistentLedgerBoundedCommand,
    ConsistentLedgerBoundedCommandKind, ConsistentLedgerCommandExecutionOutcome,
    ConsistentLedgerCommandExecutor, ConsistentLedgerScope, ConsistentLedgerWriteRequest,
    ConsistentLedgerWriterState, ConsistentWalletSnapshot, FixedDecimal,
    InMemoryConsistentLedgerWriter, LedgerEntryRecord, LedgerEntryStatus, LedgerEntryType,
    plan_consistent_ledger_write, plan_consistent_ledger_write_commands,
};
use serde::Deserialize;
use uuid::Uuid;

const FIXTURE: &str =
    include_str!("../../../tests/fixtures/billing/consistent_writer_executor_contract.json");
const MONEY_SCALE: u32 = 8;

#[derive(Debug, Deserialize)]
struct ExecutorFixture {
    contract: String,
    secret_safe_forbidden_terms: Vec<String>,
    scope: ScopeFixture,
    next_ledger_entry_id: Uuid,
    cases: Vec<CaseFixture>,
}

#[derive(Debug, Deserialize)]
struct ScopeFixture {
    tenant_id: Uuid,
    project_id: Option<Uuid>,
    virtual_key_id: Option<Uuid>,
}

#[derive(Debug, Deserialize)]
struct CaseFixture {
    name: String,
    operation: String,
    request: serde_json::Value,
    state: StateFixture,
    expect: ExpectedExecution,
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
struct ExpectedExecution {
    outcome: String,
    command_kinds: Vec<String>,
    error_code: Option<String>,
    ledger_entry_count: usize,
    pending_reserve_count: usize,
    confirmed_settle_count: usize,
    confirmed_refund_count: usize,
    reversed_reserve_count: usize,
}

#[test]
fn consistent_writer_executor_fixture_matches_contract() {
    let fixture: ExecutorFixture = serde_json::from_str(FIXTURE).expect("fixture should parse");
    assert_eq!(fixture.contract, "billing_ledger_command_executor_v1");

    for case in &fixture.cases {
        let request = request_from_fixture(&fixture.scope, case);
        let state = state_from_fixture(&case.state);

        if let Ok(plan) = plan_consistent_ledger_write(request.clone(), &state) {
            let command_plan = plan_consistent_ledger_write_commands(&plan);
            assert_eq!(
                command_plan.schema_version, CONSISTENT_LEDGER_COMMAND_EXECUTOR_SCHEMA,
                "{} command plan schema",
                case.name
            );
            assert_eq!(
                command_plan.operation_key_output, "omitted",
                "{}",
                case.name
            );
            assert_eq!(
                command_plan.executor_contract.trait_name, "ConsistentLedgerCommandExecutor",
                "{} trait contract",
                case.name
            );
            assert!(
                command_plan.executor_contract.mockable,
                "{} mockable",
                case.name
            );
            assert!(
                command_plan
                    .executor_contract
                    .command_policy
                    .contains("bounded ledger writes"),
                "{} bounded command policy",
                case.name
            );
            assert_command_kinds(
                &command_plan.commands,
                &case.expect.command_kinds,
                &case.name,
            );
            assert_bounded_commands_are_secret_safe(&command_plan.commands, &case.name);

            let serialized =
                serde_json::to_string(&command_plan).expect("command plan should serialize");
            assert_secret_safe_text(
                &serialized,
                &fixture.secret_safe_forbidden_terms,
                &case.name,
            );
        }

        let mut writer = InMemoryConsistentLedgerWriter::new(state, fixture.next_ledger_entry_id);
        let execution = writer.execute_consistent_ledger_write(request);

        assert_eq!(
            execution.schema_version, CONSISTENT_LEDGER_COMMAND_EXECUTOR_SCHEMA,
            "{} execution schema",
            case.name
        );
        assert_eq!(execution.executor, "in_memory_consistent_ledger_writer");
        assert_eq!(
            execution_outcome_name(execution.outcome),
            case.expect.outcome,
            "{} outcome",
            case.name
        );
        assert_eq!(execution.operation_key_output, "omitted", "{}", case.name);
        assert_command_kinds(&execution.commands, &case.expect.command_kinds, &case.name);
        assert_bounded_commands_are_secret_safe(&execution.commands, &case.name);
        assert_error_contract(&execution.error, &case.expect.error_code, &case.name);

        assert_eq!(
            execution.state_summary.ledger_entry_count, case.expect.ledger_entry_count,
            "{} ledger entry count",
            case.name
        );
        assert_eq!(
            execution.state_summary.pending_reserve_count, case.expect.pending_reserve_count,
            "{} pending reserve count",
            case.name
        );
        assert_eq!(
            execution.state_summary.confirmed_settle_count, case.expect.confirmed_settle_count,
            "{} confirmed settle count",
            case.name
        );
        assert_eq!(
            execution.state_summary.confirmed_refund_count, case.expect.confirmed_refund_count,
            "{} confirmed refund count",
            case.name
        );
        assert_eq!(
            execution.state_summary.reversed_reserve_count, case.expect.reversed_reserve_count,
            "{} reversed reserve count",
            case.name
        );

        let serialized = serde_json::to_string(&execution).expect("execution should serialize");
        assert_secret_safe_text(
            &serialized,
            &fixture.secret_safe_forbidden_terms,
            &case.name,
        );
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

fn assert_command_kinds(
    commands: &[ConsistentLedgerBoundedCommand],
    expected: &[String],
    label: &str,
) {
    let actual = commands
        .iter()
        .map(|command| command_kind_name(command.kind).to_string())
        .collect::<Vec<_>>();
    assert_eq!(actual, expected, "{label} command kinds");
}

fn assert_bounded_commands_are_secret_safe(
    commands: &[ConsistentLedgerBoundedCommand],
    label: &str,
) {
    for command in commands {
        assert!(
            !command.bounded_by.is_empty(),
            "{label} command {} should be bounded",
            command.order
        );
        assert_eq!(
            command.operation_key_output, "omitted",
            "{label} command {} operation key output",
            command.order
        );
        assert!(
            !command
                .bounded_by
                .iter()
                .any(|bound| *bound == "idempotency_key"),
            "{label} command {} must not expose idempotency key bound",
            command.order
        );
        if command.kind == ConsistentLedgerBoundedCommandKind::UpdateLedgerStatus {
            assert!(
                command.ledger_entry_id.is_some(),
                "{label} command {} should target ledger_entry_id",
                command.order
            );
            assert!(
                command.related_ledger_entry_id.is_none(),
                "{label} command {} should not overload related_ledger_entry_id",
                command.order
            );
        }
    }
}

fn assert_error_contract(
    error: &Option<ai_gateway_billing_ledger::ConsistentLedgerCommandExecutionError>,
    expected_code: &Option<String>,
    label: &str,
) {
    match (error, expected_code) {
        (Some(error), Some(expected_code)) => {
            assert_eq!(error.code, expected_code, "{label} error code");
            assert_eq!(error.detail_output, "omitted", "{label} error detail");
        }
        (None, None) => {}
        (actual, expected) => panic!("{label} error mismatch: {actual:?} != {expected:?}"),
    }
}

const fn command_kind_name(kind: ConsistentLedgerBoundedCommandKind) -> &'static str {
    match kind {
        ConsistentLedgerBoundedCommandKind::AssertBalanceWindow => "assert_balance_window",
        ConsistentLedgerBoundedCommandKind::AssertBudgetWindow => "assert_budget_window",
        ConsistentLedgerBoundedCommandKind::InsertLedgerEntry => "insert_ledger_entry",
        ConsistentLedgerBoundedCommandKind::UpdateLedgerStatus => "update_ledger_status",
    }
}

const fn execution_outcome_name(outcome: ConsistentLedgerCommandExecutionOutcome) -> &'static str {
    match outcome {
        ConsistentLedgerCommandExecutionOutcome::Applied => "applied",
        ConsistentLedgerCommandExecutionOutcome::Idempotent => "idempotent",
        ConsistentLedgerCommandExecutionOutcome::Rejected => "rejected",
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
