use ai_gateway_billing_ledger::{
    CONSISTENT_LEDGER_POSTGRES_SQLX_ADAPTER_SCHEMA, ConsistentBudgetDimension,
    ConsistentBudgetSnapshot, ConsistentCreditGrantSnapshot, ConsistentLedgerPostgresDbErrorInput,
    ConsistentLedgerPostgresDbErrorKind, ConsistentLedgerPostgresSqlxBindMarker,
    ConsistentLedgerPostgresStatementKind, ConsistentLedgerScope, ConsistentLedgerWriteRequest,
    ConsistentLedgerWriterState, ConsistentWalletSnapshot, FixedDecimal, LedgerEntryRecord,
    LedgerEntryStatus, LedgerEntryType, map_consistent_ledger_postgres_db_error,
    plan_consistent_ledger_postgres_execution,
    plan_consistent_ledger_postgres_sqlx_adapter_contract, plan_consistent_ledger_write,
    plan_consistent_ledger_write_commands,
};
use serde::Deserialize;
use uuid::Uuid;

const EXECUTOR_FIXTURE: &str =
    include_str!("../../../tests/fixtures/billing/consistent_writer_executor_contract.json");
const SQLX_ADAPTER_FIXTURE: &str = include_str!(
    "../../../tests/fixtures/billing/consistent_writer_postgres_sqlx_adapter_contract.json"
);
const MONEY_SCALE: u32 = 8;

#[derive(Debug, Deserialize)]
struct SourceFixture {
    contract: String,
    scope: ScopeFixture,
    cases: Vec<SourceCaseFixture>,
}

#[derive(Debug, Deserialize)]
struct SqlxAdapterFixture {
    contract: String,
    source_fixture: String,
    source_case: String,
    secret_safe_forbidden_terms: Vec<String>,
    expected: ExpectedSqlxAdapter,
    db_error_cases: Vec<DbErrorCaseFixture>,
}

#[derive(Debug, Deserialize)]
struct ExpectedSqlxAdapter {
    schema_version: String,
    sqlx_dependency_declared: bool,
    db_io_implemented: bool,
    future_feature_gate: String,
    transaction_methods: Vec<String>,
    operation_key_bind_marker: String,
    required_statement_count: usize,
}

#[derive(Debug, Deserialize)]
struct DbErrorCaseFixture {
    kind: ConsistentLedgerPostgresDbErrorKind,
    private_detail: String,
    expected_code: String,
    expected_category: String,
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
fn sqlx_adapter_fixture_matches_contract_boundary() {
    let source_fixture: SourceFixture =
        serde_json::from_str(EXECUTOR_FIXTURE).expect("source fixture should parse");
    let adapter_fixture: SqlxAdapterFixture =
        serde_json::from_str(SQLX_ADAPTER_FIXTURE).expect("adapter fixture should parse");

    assert_eq!(
        source_fixture.contract,
        "billing_ledger_command_executor_v1"
    );
    assert_eq!(
        adapter_fixture.contract,
        "billing_ledger_postgres_sqlx_adapter_contract_v1"
    );
    assert_eq!(
        adapter_fixture.source_fixture,
        "consistent_writer_executor_contract.json"
    );

    let source_case = source_fixture
        .cases
        .iter()
        .find(|case| case.name == adapter_fixture.source_case)
        .expect("source case");
    let request = request_from_fixture(&source_fixture.scope, source_case);
    let state = state_from_fixture(&source_case.state);
    let writer_plan =
        plan_consistent_ledger_write(request, &state).expect("writer plan should build");
    let command_plan = plan_consistent_ledger_write_commands(&writer_plan);
    let postgres_plan = plan_consistent_ledger_postgres_execution(&writer_plan, &command_plan);
    let adapter_contract = plan_consistent_ledger_postgres_sqlx_adapter_contract(&postgres_plan);

    assert_eq!(
        adapter_contract.schema_version,
        CONSISTENT_LEDGER_POSTGRES_SQLX_ADAPTER_SCHEMA
    );
    assert_eq!(
        adapter_contract.schema_version,
        adapter_fixture.expected.schema_version
    );
    assert_eq!(
        adapter_contract.sqlx_dependency_declared,
        adapter_fixture.expected.sqlx_dependency_declared
    );
    assert_eq!(
        adapter_contract.db_io_implemented,
        adapter_fixture.expected.db_io_implemented
    );
    assert_eq!(
        adapter_contract.future_feature_gate,
        adapter_fixture.expected.future_feature_gate
    );
    assert_eq!(
        adapter_contract.statements.len(),
        adapter_fixture.expected.required_statement_count
    );

    let transaction_methods = adapter_contract
        .transaction_lifecycle
        .iter()
        .map(|step| step.method.to_string())
        .collect::<Vec<_>>();
    assert_eq!(
        transaction_methods,
        adapter_fixture.expected.transaction_methods
    );

    for (statement, source_statement) in adapter_contract
        .statements
        .iter()
        .zip(&postgres_plan.sql_statements)
    {
        assert_eq!(statement.order, source_statement.order);
        assert_eq!(statement.kind, source_statement.kind);
        assert_eq!(
            statement.row_count_expectation,
            source_statement.row_count_expectation
        );
        assert!(
            !statement.bounded_by.is_empty(),
            "statement {} should remain bounded",
            statement.order
        );
        assert!(
            !statement.bounded_by.contains(&"private_operation_key"),
            "statement {} must expose only public bind marker",
            statement.order
        );

        if statement
            .bind_markers
            .contains(&ConsistentLedgerPostgresSqlxBindMarker::OperationKeyBind)
        {
            assert_eq!(statement.operation_key_output, "bind_marker_only");
            assert!(
                statement.bounded_by.contains(&"operation_key_bind")
                    || statement.kind == ConsistentLedgerPostgresStatementKind::InsertLedgerEntry,
                "statement {} should expose operation key bind marker",
                statement.order
            );
        }
    }

    let marker_json =
        serde_json::to_string(&ConsistentLedgerPostgresSqlxBindMarker::OperationKeyBind)
            .expect("marker should serialize");
    assert_eq!(
        marker_json.trim_matches('"'),
        adapter_fixture.expected.operation_key_bind_marker
    );

    let serialized =
        serde_json::to_string(&adapter_contract).expect("adapter contract should serialize");
    assert!(serialized.contains("operation_key_bind"));
    assert!(serialized.contains("row_count_expectation"));
    assert_secret_safe_text(
        &serialized,
        &adapter_fixture.secret_safe_forbidden_terms,
        "adapter contract",
    );
}

#[test]
fn postgres_db_error_mapping_is_stable_and_secret_safe() {
    let adapter_fixture: SqlxAdapterFixture =
        serde_json::from_str(SQLX_ADAPTER_FIXTURE).expect("adapter fixture should parse");

    for case in &adapter_fixture.db_error_cases {
        let private_detail_len = case.private_detail.len();
        let error = map_consistent_ledger_postgres_db_error(ConsistentLedgerPostgresDbErrorInput {
            kind: case.kind,
            statement_kind: Some(ConsistentLedgerPostgresStatementKind::InsertLedgerEntry),
            private_detail: Some(case.private_detail.clone()),
        });

        assert!(
            private_detail_len > 0,
            "{} private detail",
            case.expected_code
        );
        assert_eq!(error.code, case.expected_code);
        assert_eq!(error.category, case.expected_category);
        assert_eq!(error.detail_output, "omitted");

        let serialized = serde_json::to_string(&error).expect("error should serialize");
        assert_secret_safe_text(
            &serialized,
            &adapter_fixture.secret_safe_forbidden_terms,
            &case.expected_code,
        );
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
