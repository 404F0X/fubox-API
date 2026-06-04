use std::collections::HashMap;

use ai_gateway_billing_ledger::{
    CONSISTENT_LEDGER_POSTGRES_EXECUTION_SCHEMA, ConsistentBudgetDimension,
    ConsistentBudgetSnapshot, ConsistentCreditGrantSnapshot, ConsistentLedgerPostgresStatement,
    ConsistentLedgerPostgresStatementKind, ConsistentLedgerPostgresTransactionStepKind,
    ConsistentLedgerScope, ConsistentLedgerWriteRequest, ConsistentLedgerWriterState,
    ConsistentWalletSnapshot, FixedDecimal, LedgerEntryRecord, LedgerEntryStatus, LedgerEntryType,
    plan_consistent_ledger_postgres_execution, plan_consistent_ledger_write,
    plan_consistent_ledger_write_commands,
};
use serde::Deserialize;
use uuid::Uuid;

const EXECUTOR_FIXTURE: &str =
    include_str!("../../../tests/fixtures/billing/consistent_writer_executor_contract.json");
const POSTGRES_FIXTURE: &str = include_str!(
    "../../../tests/fixtures/billing/consistent_writer_postgres_execution_contract.json"
);
const MONEY_SCALE: u32 = 8;

#[derive(Debug, Deserialize)]
struct ExecutorFixture {
    contract: String,
    scope: ScopeFixture,
    cases: Vec<ExecutorCaseFixture>,
}

#[derive(Debug, Deserialize)]
struct PostgresFixture {
    contract: String,
    db_io_implemented: bool,
    source_fixture: String,
    secret_safe_forbidden_terms: Vec<String>,
    required_lock_order: Vec<String>,
    cases: Vec<PostgresCaseFixture>,
}

#[derive(Debug, Deserialize)]
struct PostgresCaseFixture {
    name: String,
    expected_statement_kinds: Vec<String>,
    expected_command_statement_kinds: Vec<String>,
    status_update_target_field: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ScopeFixture {
    tenant_id: Uuid,
    project_id: Option<Uuid>,
    virtual_key_id: Option<Uuid>,
}

#[derive(Debug, Deserialize)]
struct ExecutorCaseFixture {
    name: String,
    operation: String,
    request: serde_json::Value,
    state: StateFixture,
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

#[test]
fn postgres_execution_fixture_matches_statement_contract() {
    let executor_fixture: ExecutorFixture =
        serde_json::from_str(EXECUTOR_FIXTURE).expect("executor fixture should parse");
    let postgres_fixture: PostgresFixture =
        serde_json::from_str(POSTGRES_FIXTURE).expect("postgres fixture should parse");

    assert_eq!(
        executor_fixture.contract,
        "billing_ledger_command_executor_v1"
    );
    assert_eq!(
        postgres_fixture.contract,
        "billing_ledger_postgres_execution_plan_v1"
    );
    assert_eq!(
        postgres_fixture.source_fixture,
        "consistent_writer_executor_contract.json"
    );

    let source_cases = executor_fixture
        .cases
        .iter()
        .map(|case| (case.name.as_str(), case))
        .collect::<HashMap<_, _>>();

    for expected in &postgres_fixture.cases {
        let source = source_cases
            .get(expected.name.as_str())
            .unwrap_or_else(|| panic!("missing source case `{}`", expected.name));
        let request = request_from_fixture(&executor_fixture.scope, source);
        let state = state_from_fixture(&source.state);
        let writer_plan =
            plan_consistent_ledger_write(request, &state).expect("writer plan should build");
        let command_plan = plan_consistent_ledger_write_commands(&writer_plan);
        let postgres_plan = plan_consistent_ledger_postgres_execution(&writer_plan, &command_plan);

        assert_eq!(
            postgres_plan.schema_version, CONSISTENT_LEDGER_POSTGRES_EXECUTION_SCHEMA,
            "{} schema",
            expected.name
        );
        assert_eq!(
            postgres_plan.executor_boundary.db_io_implemented, postgres_fixture.db_io_implemented,
            "{} db boundary",
            expected.name
        );
        assert_eq!(
            postgres_plan.operation_key_output, "omitted",
            "{} operation key output",
            expected.name
        );
        assert_eq!(
            postgres_plan.executor_boundary.future_sqlx_entrypoint,
            "execute_consistent_ledger_postgres_transaction",
            "{} future sqlx entrypoint",
            expected.name
        );

        assert_transaction_steps(&postgres_plan.transaction_steps, &expected.name);
        assert_statement_kinds(
            &postgres_plan.sql_statements,
            &expected.expected_statement_kinds,
            &expected.name,
        );
        assert_lock_order(
            &postgres_plan.sql_statements,
            &postgres_fixture.required_lock_order,
            &expected.name,
        );
        assert_bounded_sql_shapes(&postgres_plan.sql_statements, &expected.name);
        assert_command_statement_mapping(
            &postgres_plan.sql_statements,
            &expected.expected_command_statement_kinds,
            &expected.name,
        );

        if expected.expected_command_statement_kinds.is_empty() {
            let execute_step = postgres_plan
                .transaction_steps
                .iter()
                .find(|step| {
                    step.kind == ConsistentLedgerPostgresTransactionStepKind::ExecuteBoundedCommands
                })
                .expect("execute step");
            assert!(
                execute_step.description.contains("idempotent replay"),
                "{} idempotent transaction step",
                expected.name
            );
        }

        if expected.status_update_target_field.as_deref() == Some("ledger_entry_id") {
            assert_status_update_targets_ledger_entry_id(
                &postgres_plan.sql_statements,
                &expected.name,
            );
        }

        let serialized =
            serde_json::to_string(&postgres_plan).expect("postgres plan should serialize");
        assert_secret_safe_text(
            &serialized,
            &postgres_fixture.secret_safe_forbidden_terms,
            &expected.name,
        );
    }
}

fn request_from_fixture(
    scope: &ScopeFixture,
    case: &ExecutorCaseFixture,
) -> ConsistentLedgerWriteRequest {
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

fn assert_transaction_steps(
    steps: &[ai_gateway_billing_ledger::ConsistentLedgerPostgresTransactionStep],
    label: &str,
) {
    let actual = steps
        .iter()
        .map(|step| transaction_step_kind_name(step.kind).to_string())
        .collect::<Vec<_>>();
    assert_eq!(
        actual,
        vec![
            "begin_transaction",
            "acquire_ordered_locks",
            "recompute_locked_windows",
            "execute_bounded_commands",
            "commit_or_rollback"
        ],
        "{label} transaction steps"
    );
    for (index, step) in steps.iter().enumerate() {
        assert_eq!(
            step.order as usize,
            index + 1,
            "{label} transaction step order"
        );
    }
}

fn assert_statement_kinds(
    statements: &[ConsistentLedgerPostgresStatement],
    expected: &[String],
    label: &str,
) {
    let actual = statements
        .iter()
        .map(|statement| statement_kind_name(statement.kind).to_string())
        .collect::<Vec<_>>();
    assert_eq!(actual, expected, "{label} statement kinds");
    for (index, statement) in statements.iter().enumerate() {
        assert_eq!(
            statement.order as usize,
            index + 1,
            "{label} statement order"
        );
    }
}

fn assert_lock_order(
    statements: &[ConsistentLedgerPostgresStatement],
    expected: &[String],
    label: &str,
) {
    let actual = statements
        .iter()
        .take(expected.len())
        .map(|statement| statement_kind_name(statement.kind).to_string())
        .collect::<Vec<_>>();
    assert_eq!(actual, expected, "{label} lock order");
}

fn assert_bounded_sql_shapes(statements: &[ConsistentLedgerPostgresStatement], label: &str) {
    for statement in statements {
        let sql = statement.statement_shape.to_ascii_lowercase();
        assert!(
            !sql.contains("select *"),
            "{label} statement {} must not select all columns",
            statement.order
        );
        assert!(
            !sql.contains("full table") && !sql.contains("unbounded"),
            "{label} statement {} must not describe an unbounded scan",
            statement.order
        );
        assert!(
            !statement.where_bounds.is_empty(),
            "{label} statement {} should expose bounded parameters",
            statement.order
        );

        match statement.kind {
            ConsistentLedgerPostgresStatementKind::LockWallet
            | ConsistentLedgerPostgresStatementKind::LockCreditGrants
            | ConsistentLedgerPostgresStatementKind::LockBudgets
            | ConsistentLedgerPostgresStatementKind::LockLedgerEntries => {
                assert!(
                    sql.contains(" where "),
                    "{label} lock statement {} must have where clause",
                    statement.order
                );
                assert!(
                    sql.contains("for update"),
                    "{label} lock statement {} must have for update",
                    statement.order
                );
                assert!(
                    statement.lock_clause.is_some(),
                    "{label} lock statement {} lock clause",
                    statement.order
                );
            }
            ConsistentLedgerPostgresStatementKind::AssertBalanceWindow
            | ConsistentLedgerPostgresStatementKind::AssertBudgetWindow
            | ConsistentLedgerPostgresStatementKind::UpdateLedgerStatus => {
                assert!(
                    sql.contains(" where "),
                    "{label} command statement {} must have where clause",
                    statement.order
                );
            }
            ConsistentLedgerPostgresStatementKind::InsertLedgerEntry => {
                assert!(
                    sql.contains("insert into ledger_entries"),
                    "{label} insert statement {} shape",
                    statement.order
                );
                assert!(
                    sql.contains("on conflict"),
                    "{label} insert statement {} must document replay boundary",
                    statement.order
                );
            }
        }
    }
}

fn assert_command_statement_mapping(
    statements: &[ConsistentLedgerPostgresStatement],
    expected: &[String],
    label: &str,
) {
    let actual = statements
        .iter()
        .filter(|statement| statement.command_order.is_some())
        .map(|statement| statement_kind_name(statement.kind).to_string())
        .collect::<Vec<_>>();
    assert_eq!(actual, expected, "{label} command statement mapping");
}

fn assert_status_update_targets_ledger_entry_id(
    statements: &[ConsistentLedgerPostgresStatement],
    label: &str,
) {
    let update = statements
        .iter()
        .find(|statement| {
            statement.kind == ConsistentLedgerPostgresStatementKind::UpdateLedgerStatus
        })
        .expect("status update statement");
    assert!(
        update.ledger_entry_id.is_some(),
        "{label} update should carry ledger_entry_id"
    );
    assert!(
        update.related_ledger_entry_id.is_none(),
        "{label} update should not carry related_ledger_entry_id"
    );
    assert!(
        update.where_bounds.contains(&"ledger_entry_id"),
        "{label} update should be bounded by ledger_entry_id"
    );
    assert!(
        !update.where_bounds.contains(&"related_ledger_entry_id"),
        "{label} update should not be bounded by related_ledger_entry_id"
    );
    let sql = update.statement_shape.to_ascii_lowercase();
    assert!(
        sql.contains("$ledger_entry_id"),
        "{label} update SQL should bind ledger_entry_id"
    );
    assert!(
        !sql.contains("$related_ledger_entry_id"),
        "{label} update SQL should not bind related_ledger_entry_id"
    );
}

const fn statement_kind_name(kind: ConsistentLedgerPostgresStatementKind) -> &'static str {
    match kind {
        ConsistentLedgerPostgresStatementKind::LockWallet => "lock_wallet",
        ConsistentLedgerPostgresStatementKind::LockCreditGrants => "lock_credit_grants",
        ConsistentLedgerPostgresStatementKind::LockBudgets => "lock_budgets",
        ConsistentLedgerPostgresStatementKind::LockLedgerEntries => "lock_ledger_entries",
        ConsistentLedgerPostgresStatementKind::AssertBalanceWindow => "assert_balance_window",
        ConsistentLedgerPostgresStatementKind::AssertBudgetWindow => "assert_budget_window",
        ConsistentLedgerPostgresStatementKind::InsertLedgerEntry => "insert_ledger_entry",
        ConsistentLedgerPostgresStatementKind::UpdateLedgerStatus => "update_ledger_status",
    }
}

const fn transaction_step_kind_name(
    kind: ConsistentLedgerPostgresTransactionStepKind,
) -> &'static str {
    match kind {
        ConsistentLedgerPostgresTransactionStepKind::BeginTransaction => "begin_transaction",
        ConsistentLedgerPostgresTransactionStepKind::AcquireOrderedLocks => "acquire_ordered_locks",
        ConsistentLedgerPostgresTransactionStepKind::RecomputeLockedWindows => {
            "recompute_locked_windows"
        }
        ConsistentLedgerPostgresTransactionStepKind::ExecuteBoundedCommands => {
            "execute_bounded_commands"
        }
        ConsistentLedgerPostgresTransactionStepKind::CommitOrRollback => "commit_or_rollback",
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
