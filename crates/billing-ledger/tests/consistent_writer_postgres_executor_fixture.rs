use std::collections::HashMap;

use ai_gateway_billing_ledger::{
    CONSISTENT_LEDGER_POSTGRES_EXECUTOR_SCHEMA, ConsistentBudgetDimension,
    ConsistentBudgetSnapshot, ConsistentCreditGrantSnapshot, ConsistentLedgerPostgresExecutionPlan,
    ConsistentLedgerPostgresExecutorError, ConsistentLedgerPostgresExecutorOutcome,
    ConsistentLedgerPostgresStatement, ConsistentLedgerPostgresStatementKind,
    ConsistentLedgerPostgresStatementOutcome, ConsistentLedgerPostgresStatementResult,
    ConsistentLedgerPostgresTransactionExecutor, ConsistentLedgerScope,
    ConsistentLedgerWriteRequest, ConsistentLedgerWriterState, ConsistentWalletSnapshot,
    FixedDecimal, LedgerEntryRecord, LedgerEntryStatus, LedgerEntryType,
    execute_consistent_ledger_postgres_plan, plan_consistent_ledger_postgres_execution,
    plan_consistent_ledger_write, plan_consistent_ledger_write_commands,
};
use serde::Deserialize;
use uuid::Uuid;

const EXECUTOR_FIXTURE: &str =
    include_str!("../../../tests/fixtures/billing/consistent_writer_executor_contract.json");
const POSTGRES_EXECUTOR_FIXTURE: &str = include_str!(
    "../../../tests/fixtures/billing/consistent_writer_postgres_executor_contract.json"
);
const MONEY_SCALE: u32 = 8;

#[derive(Debug, Deserialize)]
struct SourceFixture {
    contract: String,
    scope: ScopeFixture,
    cases: Vec<SourceCaseFixture>,
}

#[derive(Debug, Deserialize)]
struct PostgresExecutorFixture {
    contract: String,
    source_fixture: String,
    secret_safe_forbidden_terms: Vec<String>,
    cases: Vec<PostgresExecutorCaseFixture>,
}

#[derive(Debug, Deserialize)]
struct PostgresExecutorCaseFixture {
    name: String,
    source_case: String,
    fail_on_statement_kind: Option<String>,
    row_count_override_statement_kind: Option<String>,
    row_count_override: Option<u64>,
    failure_code: Option<String>,
    internal_failure_detail: Option<String>,
    expected_outcome: String,
    expected_committed: bool,
    expected_rolled_back: bool,
    expected_error_code: Option<String>,
    expected_error_category: Option<String>,
    expected_statement_result_count: usize,
    expected_event_suffix: String,
}

#[derive(Debug, Deserialize)]
struct ScopeFixture {
    tenant_id: Uuid,
    project_id: Option<Uuid>,
    virtual_key_id: Option<Uuid>,
}

#[derive(Debug, Deserialize)]
struct SourceCaseFixture {
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
fn postgres_executor_fixture_matches_boundary_contract() {
    let source_fixture: SourceFixture =
        serde_json::from_str(EXECUTOR_FIXTURE).expect("source fixture should parse");
    let executor_fixture: PostgresExecutorFixture =
        serde_json::from_str(POSTGRES_EXECUTOR_FIXTURE).expect("executor fixture should parse");

    assert_eq!(
        source_fixture.contract,
        "billing_ledger_command_executor_v1"
    );
    assert_eq!(
        executor_fixture.contract,
        "billing_ledger_postgres_executor_v1"
    );
    assert_eq!(
        executor_fixture.source_fixture,
        "consistent_writer_executor_contract.json"
    );

    let source_cases = source_fixture
        .cases
        .iter()
        .map(|case| (case.name.as_str(), case))
        .collect::<HashMap<_, _>>();

    for case in &executor_fixture.cases {
        let source = source_cases
            .get(case.source_case.as_str())
            .unwrap_or_else(|| panic!("missing source case `{}`", case.source_case));
        let request = request_from_fixture(&source_fixture.scope, source);
        let state = state_from_fixture(&source.state);
        let writer_plan =
            plan_consistent_ledger_write(request, &state).expect("writer plan should build");
        let command_plan = plan_consistent_ledger_write_commands(&writer_plan);
        let postgres_plan = plan_consistent_ledger_postgres_execution(&writer_plan, &command_plan);

        let mut executor = FakePostgresExecutor::new(
            case.fail_on_statement_kind
                .as_deref()
                .map(statement_kind_from_name),
            case.row_count_override_statement_kind
                .as_deref()
                .map(statement_kind_from_name),
            case.row_count_override,
            case.failure_code.clone(),
            case.internal_failure_detail.clone(),
        );
        let result = execute_consistent_ledger_postgres_plan(&mut executor, &postgres_plan);

        assert_eq!(
            result.schema_version, CONSISTENT_LEDGER_POSTGRES_EXECUTOR_SCHEMA,
            "{} schema",
            case.name
        );
        assert_eq!(
            executor_outcome_name(result.outcome),
            case.expected_outcome,
            "{} outcome",
            case.name
        );
        assert_eq!(
            result.committed, case.expected_committed,
            "{} committed",
            case.name
        );
        assert_eq!(
            result.rolled_back, case.expected_rolled_back,
            "{} rolled back",
            case.name
        );
        assert_eq!(
            result.operation_key_output, "omitted",
            "{} operation key output",
            case.name
        );
        assert_eq!(
            result.statement_results.len(),
            case.expected_statement_result_count,
            "{} statement result count",
            case.name
        );
        assert_statement_result_order_matches_plan(
            &result.statement_results,
            &postgres_plan.sql_statements,
            &case.name,
        );
        assert_executor_events_match(
            &executor.events,
            &result.statement_results,
            &case.expected_event_suffix,
            &case.name,
        );
        assert_error_contract(
            &result.error,
            &case.expected_error_code,
            &case.expected_error_category,
            &case.name,
        );

        if case.expected_outcome == "idempotent" {
            assert!(
                result
                    .statement_results
                    .iter()
                    .all(|statement| statement.kind
                        != ConsistentLedgerPostgresStatementKind::InsertLedgerEntry
                        && statement.kind
                            != ConsistentLedgerPostgresStatementKind::UpdateLedgerStatus),
                "{} idempotent replay should not write",
                case.name
            );
        }

        if case.expected_rolled_back {
            assert_eq!(
                result
                    .statement_results
                    .last()
                    .map(|statement| statement.outcome),
                Some(ConsistentLedgerPostgresStatementOutcome::Refused),
                "{} final statement should be refused",
                case.name
            );
        }

        if case.internal_failure_detail.is_some() {
            assert!(
                executor.observed_internal_failure_detail_len > 0,
                "{} fake executor should observe private detail",
                case.name
            );
        }

        let serialized = serde_json::to_string(&result).expect("result should serialize");
        assert_secret_safe_text(
            &serialized,
            &executor_fixture.secret_safe_forbidden_terms,
            &case.name,
        );
    }
}

#[test]
fn postgres_executor_public_statement_results_are_normalized() {
    let postgres_plan = postgres_plan_for_source_case(
        "reserve_apply_generates_bounded_commands_and_inserts_pending_debit",
    );
    let mut executor = MisreportingPostgresExecutor::default();
    let result = execute_consistent_ledger_postgres_plan(&mut executor, &postgres_plan);

    assert!(result.committed);
    assert!(!result.rolled_back);
    assert_eq!(result.error, None);

    let first_result = result.statement_results.first().expect("statement result");
    let first_statement = postgres_plan.sql_statements.first().expect("statement");
    assert_eq!(first_result.order, first_statement.order);
    assert_eq!(first_result.kind, first_statement.kind);
    assert_eq!(first_result.target, first_statement.target);
    assert_eq!(first_result.rows_affected, 1);
    assert_eq!(first_result.operation_key_output, "omitted");

    let serialized = serde_json::to_string(&result).expect("result should serialize");
    assert!(!serialized.contains("reserve:00000000"));
    assert!(!serialized.contains("idempotency_key"));
    assert!(!serialized.contains("raw private key"));
}

#[test]
fn postgres_executor_ok_refused_rolls_back_and_sanitizes_statement_result() {
    let postgres_plan = postgres_plan_for_source_case(
        "reserve_apply_generates_bounded_commands_and_inserts_pending_debit",
    );
    let mut executor = RefusingOkPostgresExecutor::default();
    let result = execute_consistent_ledger_postgres_plan(&mut executor, &postgres_plan);

    assert_eq!(
        result.outcome,
        ConsistentLedgerPostgresExecutorOutcome::RolledBack
    );
    assert!(!result.committed);
    assert!(result.rolled_back);
    assert_eq!(
        result.error.as_ref().map(|error| error.code.as_str()),
        Some("statement_refused")
    );
    assert_eq!(executor.events, vec!["begin", "execute", "rollback"]);

    let refused = result.statement_results.first().expect("refused result");
    let first_statement = postgres_plan.sql_statements.first().expect("statement");
    assert_eq!(refused.order, first_statement.order);
    assert_eq!(refused.kind, first_statement.kind);
    assert_eq!(refused.target, first_statement.target);
    assert_eq!(
        refused.outcome,
        ConsistentLedgerPostgresStatementOutcome::Refused
    );
    assert_eq!(refused.operation_key_output, "omitted");

    let serialized = serde_json::to_string(&result).expect("result should serialize");
    assert!(!serialized.contains("reserve:00000000"));
    assert!(!serialized.contains("idempotency_key"));
    assert!(!serialized.contains("raw private key"));
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct FakePostgresExecutor {
    fail_on_statement_kind: Option<ConsistentLedgerPostgresStatementKind>,
    row_count_override_statement_kind: Option<ConsistentLedgerPostgresStatementKind>,
    row_count_override: Option<u64>,
    failure_code: Option<String>,
    internal_failure_detail: Option<String>,
    observed_internal_failure_detail_len: usize,
    events: Vec<String>,
}

impl FakePostgresExecutor {
    fn new(
        fail_on_statement_kind: Option<ConsistentLedgerPostgresStatementKind>,
        row_count_override_statement_kind: Option<ConsistentLedgerPostgresStatementKind>,
        row_count_override: Option<u64>,
        failure_code: Option<String>,
        internal_failure_detail: Option<String>,
    ) -> Self {
        Self {
            fail_on_statement_kind,
            row_count_override_statement_kind,
            row_count_override,
            failure_code,
            internal_failure_detail,
            observed_internal_failure_detail_len: 0,
            events: Vec::new(),
        }
    }
}

impl ConsistentLedgerPostgresTransactionExecutor for FakePostgresExecutor {
    fn begin_transaction(&mut self) -> Result<(), ConsistentLedgerPostgresExecutorError> {
        self.events.push("begin".to_string());
        Ok(())
    }

    fn execute_statement(
        &mut self,
        statement: &ConsistentLedgerPostgresStatement,
    ) -> Result<ConsistentLedgerPostgresStatementResult, ConsistentLedgerPostgresExecutorError>
    {
        self.events
            .push(format!("execute:{}", statement_kind_name(statement.kind)));
        if self.fail_on_statement_kind == Some(statement.kind) {
            self.observed_internal_failure_detail_len = self
                .internal_failure_detail
                .as_ref()
                .map(|detail| detail.len())
                .unwrap_or_default();
            return Err(ConsistentLedgerPostgresExecutorError::statement_refused(
                self.failure_code.as_deref().unwrap_or("statement_refused"),
            ));
        }

        let rows_affected = if self.row_count_override_statement_kind == Some(statement.kind) {
            self.row_count_override.unwrap_or(1)
        } else {
            1
        };

        Ok(ConsistentLedgerPostgresStatementResult {
            order: statement.order,
            kind: statement.kind,
            target: statement.target,
            outcome: ConsistentLedgerPostgresStatementOutcome::Executed,
            rows_affected,
            operation_key_output: "omitted",
        })
    }

    fn commit_transaction(&mut self) -> Result<(), ConsistentLedgerPostgresExecutorError> {
        self.events.push("commit".to_string());
        Ok(())
    }

    fn rollback_transaction(&mut self) -> Result<(), ConsistentLedgerPostgresExecutorError> {
        self.events.push("rollback".to_string());
        Ok(())
    }
}

#[derive(Debug, Default)]
struct MisreportingPostgresExecutor;

impl ConsistentLedgerPostgresTransactionExecutor for MisreportingPostgresExecutor {
    fn begin_transaction(&mut self) -> Result<(), ConsistentLedgerPostgresExecutorError> {
        Ok(())
    }

    fn execute_statement(
        &mut self,
        _statement: &ConsistentLedgerPostgresStatement,
    ) -> Result<ConsistentLedgerPostgresStatementResult, ConsistentLedgerPostgresExecutorError>
    {
        Ok(ConsistentLedgerPostgresStatementResult {
            order: u16::MAX,
            kind: ConsistentLedgerPostgresStatementKind::UpdateLedgerStatus,
            target: "idempotency_key",
            outcome: ConsistentLedgerPostgresStatementOutcome::Executed,
            rows_affected: 1,
            operation_key_output: "reserve:00000000 raw private key",
        })
    }

    fn commit_transaction(&mut self) -> Result<(), ConsistentLedgerPostgresExecutorError> {
        Ok(())
    }

    fn rollback_transaction(&mut self) -> Result<(), ConsistentLedgerPostgresExecutorError> {
        Ok(())
    }
}

#[derive(Debug, Default)]
struct RefusingOkPostgresExecutor {
    events: Vec<&'static str>,
}

impl ConsistentLedgerPostgresTransactionExecutor for RefusingOkPostgresExecutor {
    fn begin_transaction(&mut self) -> Result<(), ConsistentLedgerPostgresExecutorError> {
        self.events.push("begin");
        Ok(())
    }

    fn execute_statement(
        &mut self,
        _statement: &ConsistentLedgerPostgresStatement,
    ) -> Result<ConsistentLedgerPostgresStatementResult, ConsistentLedgerPostgresExecutorError>
    {
        self.events.push("execute");
        Ok(ConsistentLedgerPostgresStatementResult {
            order: u16::MAX,
            kind: ConsistentLedgerPostgresStatementKind::UpdateLedgerStatus,
            target: "idempotency_key",
            outcome: ConsistentLedgerPostgresStatementOutcome::Refused,
            rows_affected: 0,
            operation_key_output: "reserve:00000000 raw private key",
        })
    }

    fn commit_transaction(&mut self) -> Result<(), ConsistentLedgerPostgresExecutorError> {
        self.events.push("commit");
        Ok(())
    }

    fn rollback_transaction(&mut self) -> Result<(), ConsistentLedgerPostgresExecutorError> {
        self.events.push("rollback");
        Ok(())
    }
}

fn request_from_fixture(
    scope: &ScopeFixture,
    case: &SourceCaseFixture,
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

fn postgres_plan_for_source_case(case_name: &str) -> ConsistentLedgerPostgresExecutionPlan {
    let source_fixture: SourceFixture =
        serde_json::from_str(EXECUTOR_FIXTURE).expect("source fixture should parse");
    let source = source_fixture
        .cases
        .iter()
        .find(|case| case.name == case_name)
        .unwrap_or_else(|| panic!("missing source case `{case_name}`"));
    let request = request_from_fixture(&source_fixture.scope, source);
    let state = state_from_fixture(&source.state);
    let writer_plan = plan_consistent_ledger_write(request, &state).expect("writer plan");
    let command_plan = plan_consistent_ledger_write_commands(&writer_plan);
    plan_consistent_ledger_postgres_execution(&writer_plan, &command_plan)
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

fn assert_statement_result_order_matches_plan(
    results: &[ConsistentLedgerPostgresStatementResult],
    statements: &[ConsistentLedgerPostgresStatement],
    label: &str,
) {
    for (result, statement) in results.iter().zip(statements) {
        assert_eq!(result.order, statement.order, "{label} result order");
        assert_eq!(result.kind, statement.kind, "{label} result kind");
        assert_eq!(
            result.operation_key_output, "omitted",
            "{label} operation key output"
        );
    }
}

fn assert_executor_events_match(
    events: &[String],
    results: &[ConsistentLedgerPostgresStatementResult],
    expected_suffix: &str,
    label: &str,
) {
    assert_eq!(
        events.first().map(String::as_str),
        Some("begin"),
        "{label} begin"
    );
    assert_eq!(
        events.last().map(String::as_str),
        Some(expected_suffix),
        "{label} final tx event"
    );
    let execute_events = events
        .iter()
        .filter_map(|event| event.strip_prefix("execute:"))
        .collect::<Vec<_>>();
    let result_kinds = results
        .iter()
        .map(|result| statement_kind_name(result.kind))
        .collect::<Vec<_>>();
    assert_eq!(execute_events, result_kinds, "{label} execute order");
}

fn assert_error_contract(
    error: &Option<ConsistentLedgerPostgresExecutorError>,
    expected_code: &Option<String>,
    expected_category: &Option<String>,
    label: &str,
) {
    match (error, expected_code, expected_category) {
        (Some(error), Some(expected_code), Some(expected_category)) => {
            assert_eq!(&error.code, expected_code, "{label} error code");
            assert_eq!(&error.category, expected_category, "{label} error category");
            assert_eq!(error.detail_output, "omitted", "{label} error detail");
        }
        (None, None, None) => {}
        (actual, expected_code, expected_category) => {
            panic!("{label} error mismatch: {actual:?} != {expected_code:?}/{expected_category:?}")
        }
    }
}

fn statement_kind_from_name(name: &str) -> ConsistentLedgerPostgresStatementKind {
    match name {
        "lock_wallet" => ConsistentLedgerPostgresStatementKind::LockWallet,
        "lock_credit_grants" => ConsistentLedgerPostgresStatementKind::LockCreditGrants,
        "lock_budgets" => ConsistentLedgerPostgresStatementKind::LockBudgets,
        "lock_ledger_entries" => ConsistentLedgerPostgresStatementKind::LockLedgerEntries,
        "assert_balance_window" => ConsistentLedgerPostgresStatementKind::AssertBalanceWindow,
        "assert_budget_window" => ConsistentLedgerPostgresStatementKind::AssertBudgetWindow,
        "insert_ledger_entry" => ConsistentLedgerPostgresStatementKind::InsertLedgerEntry,
        "update_ledger_status" => ConsistentLedgerPostgresStatementKind::UpdateLedgerStatus,
        name => panic!("unsupported statement kind `{name}`"),
    }
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

const fn executor_outcome_name(outcome: ConsistentLedgerPostgresExecutorOutcome) -> &'static str {
    match outcome {
        ConsistentLedgerPostgresExecutorOutcome::Applied => "applied",
        ConsistentLedgerPostgresExecutorOutcome::Idempotent => "idempotent",
        ConsistentLedgerPostgresExecutorOutcome::RolledBack => "rolled_back",
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
