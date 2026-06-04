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
#[cfg(feature = "postgres-sqlx")]
use ai_gateway_billing_ledger::{
    ConsistentLedgerPostgresSqlxBindValue, ConsistentLedgerPostgresSqlxExecutableStatement,
    map_consistent_ledger_postgres_sqlx_error,
    plan_consistent_ledger_postgres_sqlx_executable_statements,
};
use serde::Deserialize;
use std::collections::BTreeMap;
#[cfg(feature = "postgres-sqlx")]
use std::{borrow::Cow, error::Error, fmt};
use uuid::Uuid;

const EXECUTOR_FIXTURE: &str =
    include_str!("../../../tests/fixtures/billing/consistent_writer_executor_contract.json");
const SQLX_ADAPTER_FIXTURE: &str = include_str!(
    "../../../tests/fixtures/billing/consistent_writer_postgres_sqlx_adapter_contract.json"
);
const SQLX_SCHEMA_FIXTURE: &str = include_str!(
    "../../../tests/fixtures/billing/consistent_writer_postgres_sqlx_schema_contract.json"
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
    #[allow(dead_code)]
    executable_conversion: ExecutableConversionFixture,
    db_error_cases: Vec<DbErrorCaseFixture>,
}

#[allow(dead_code)]
#[derive(Debug, Deserialize)]
struct SqlxSchemaFixture {
    contract: String,
    source_fixture: String,
    feature: String,
    live_smoke: LiveSmokeFixture,
    returning_schema_by_kind: BTreeMap<String, Vec<String>>,
    cases: Vec<SqlxSchemaCaseFixture>,
}

#[derive(Debug, Deserialize)]
struct LiveSmokeFixture {
    env_var: String,
    status_without_env: String,
    external_blocker: String,
}

#[allow(dead_code)]
#[derive(Debug, Deserialize)]
struct SqlxSchemaCaseFixture {
    source_case: String,
    operation: String,
    expected_statement_order: Vec<String>,
    expected_insert_bind_markers: Vec<String>,
    expected_insert_returning: Vec<String>,
    expected_status_update_bind_markers: Option<Vec<String>>,
    expected_status_update_returning: Option<Vec<String>>,
    operation_key_bind_statement_count: usize,
    must_contain_sql_fragments: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct ExpectedSqlxAdapter {
    schema_version: String,
    sqlx_dependency_declared: bool,
    db_io_implemented_without_feature: bool,
    db_io_implemented_with_feature: bool,
    future_feature_gate: String,
    transaction_methods: Vec<String>,
    operation_key_bind_marker: String,
    required_statement_count: usize,
}

#[allow(dead_code)]
#[derive(Debug, Deserialize)]
struct ExecutableConversionFixture {
    source_case: String,
    automatic_conversion_implemented_with_feature: bool,
    operation_key_output: String,
    debug_sql_output: String,
    concrete_sql_template_placeholders_allowed: bool,
    required_statement_order: Vec<String>,
    lock_credit_grants_bind_markers: Vec<String>,
    insert_bind_markers: Vec<String>,
    insert_bind_types: Vec<String>,
    conversion_error_code: String,
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
    let expected_db_io_implemented = if cfg!(feature = "postgres-sqlx") {
        adapter_fixture.expected.db_io_implemented_with_feature
    } else {
        adapter_fixture.expected.db_io_implemented_without_feature
    };
    assert_eq!(
        adapter_contract.db_io_implemented,
        expected_db_io_implemented
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

#[test]
fn postgres_sqlx_schema_fixture_documents_live_smoke_boundary() {
    let schema_fixture: SqlxSchemaFixture =
        serde_json::from_str(SQLX_SCHEMA_FIXTURE).expect("schema fixture should parse");

    assert_eq!(
        schema_fixture.contract,
        "billing_ledger_postgres_sqlx_schema_contract_v1"
    );
    assert_eq!(
        schema_fixture.source_fixture,
        "consistent_writer_executor_contract.json"
    );
    assert_eq!(schema_fixture.feature, "postgres-sqlx");

    if std::env::var(&schema_fixture.live_smoke.env_var).is_err() {
        assert_eq!(schema_fixture.live_smoke.status_without_env, "not_run");
        assert!(
            schema_fixture
                .live_smoke
                .external_blocker
                .contains("live postgres database URL"),
            "fixture should document the live DB blocker"
        );
    }

    for operation in ["reserve", "settle", "refund_partial"] {
        assert!(
            schema_fixture
                .cases
                .iter()
                .any(|case| case.operation == operation),
            "fixture should cover {operation}"
        );
    }
}

#[cfg(feature = "postgres-sqlx")]
#[test]
fn postgres_sqlx_converter_builds_ordered_concrete_secret_safe_executables() {
    let source_fixture: SourceFixture =
        serde_json::from_str(EXECUTOR_FIXTURE).expect("source fixture should parse");
    let adapter_fixture: SqlxAdapterFixture =
        serde_json::from_str(SQLX_ADAPTER_FIXTURE).expect("adapter fixture should parse");
    let conversion = &adapter_fixture.executable_conversion;
    assert!(
        conversion.automatic_conversion_implemented_with_feature,
        "fixture should require feature-gated conversion"
    );
    assert!(
        !conversion.concrete_sql_template_placeholders_allowed,
        "fixture should reject template placeholders"
    );
    assert_eq!(conversion.operation_key_output, "bind_marker_only");
    assert_eq!(conversion.debug_sql_output, "omitted");

    let source_case = source_fixture
        .cases
        .iter()
        .find(|case| case.name == conversion.source_case)
        .expect("source case");
    let request = request_from_fixture(&source_fixture.scope, source_case);
    let state = state_from_fixture(&source_case.state);
    let writer_plan =
        plan_consistent_ledger_write(request, &state).expect("writer plan should build");
    let command_plan = plan_consistent_ledger_write_commands(&writer_plan);
    let postgres_plan = plan_consistent_ledger_postgres_execution(&writer_plan, &command_plan);
    let executable_statements =
        plan_consistent_ledger_postgres_sqlx_executable_statements(&writer_plan, &postgres_plan)
            .expect("sqlx executable statements should convert");

    assert_eq!(
        executable_statements.len(),
        postgres_plan.sql_statements.len()
    );
    let statement_order = executable_statements
        .iter()
        .map(|statement| statement_kind_name(statement.kind).to_string())
        .collect::<Vec<_>>();
    assert_eq!(statement_order, conversion.required_statement_order);

    for (executable, source_statement) in executable_statements
        .iter()
        .zip(&postgres_plan.sql_statements)
    {
        assert_eq!(executable.order, source_statement.order);
        assert_eq!(executable.kind, source_statement.kind);
        assert_eq!(executable.bind_markers.len(), executable.binds.len());
        assert!(!executable.sql.trim().is_empty());
        assert!(!executable.sql.contains("<private"));
        assert!(!executable.sql.contains("$tenant_id"));
    }

    let lock_credit_grants = executable_statements
        .iter()
        .find(|statement| statement.kind == ConsistentLedgerPostgresStatementKind::LockCreditGrants)
        .expect("credit grant lock executable");
    assert_eq!(
        bind_marker_names(&lock_credit_grants.bind_markers),
        conversion.lock_credit_grants_bind_markers
    );

    let insert = executable_statements
        .iter()
        .find(|statement| {
            statement.kind == ConsistentLedgerPostgresStatementKind::InsertLedgerEntry
        })
        .expect("insert executable");
    assert_eq!(
        bind_marker_names(&insert.bind_markers),
        conversion.insert_bind_markers
    );
    assert_eq!(bind_type_names(&insert.binds), conversion.insert_bind_types);
    assert!(insert.binds.iter().any(|bind| {
        matches!(
            bind,
            ConsistentLedgerPostgresSqlxBindValue::OperationKey(value)
                if value == &writer_plan.idempotency_key
        )
    }));

    let debug = format!("{executable_statements:?}");
    assert!(debug.contains("operation_key_bind"));
    assert!(debug.contains("OperationKey(<bind_marker_only>)"));
    assert!(debug.contains("<concrete_sql_omitted>"));
    assert!(!debug.contains(insert.sql));
    assert_secret_safe_text(
        &debug,
        &adapter_fixture.secret_safe_forbidden_terms,
        "generated sqlx executable debug",
    );

    let mut mismatched_plan = postgres_plan.clone();
    mismatched_plan.scope.tenant_id = Uuid::from_u128(999);
    let mismatch =
        plan_consistent_ledger_postgres_sqlx_executable_statements(&writer_plan, &mismatched_plan)
            .expect_err("mismatched plan should not convert");
    assert_eq!(mismatch.code, conversion.conversion_error_code);
    assert_eq!(mismatch.category, "statement_refusal");
    assert_eq!(mismatch.detail_output, "omitted");
}

#[cfg(feature = "postgres-sqlx")]
#[test]
fn postgres_sqlx_schema_contract_covers_reserve_settle_refund_executables() {
    let source_fixture: SourceFixture =
        serde_json::from_str(EXECUTOR_FIXTURE).expect("source fixture should parse");
    let adapter_fixture: SqlxAdapterFixture =
        serde_json::from_str(SQLX_ADAPTER_FIXTURE).expect("adapter fixture should parse");
    let schema_fixture: SqlxSchemaFixture =
        serde_json::from_str(SQLX_SCHEMA_FIXTURE).expect("schema fixture should parse");

    for schema_case in &schema_fixture.cases {
        let source_case = source_fixture
            .cases
            .iter()
            .find(|case| case.name == schema_case.source_case)
            .expect("source case");
        assert_eq!(source_case.operation, schema_case.operation);

        let request = request_from_fixture(&source_fixture.scope, source_case);
        let state = state_from_fixture(&source_case.state);
        let writer_plan =
            plan_consistent_ledger_write(request, &state).expect("writer plan should build");
        let command_plan = plan_consistent_ledger_write_commands(&writer_plan);
        let postgres_plan = plan_consistent_ledger_postgres_execution(&writer_plan, &command_plan);
        let executable_statements = plan_consistent_ledger_postgres_sqlx_executable_statements(
            &writer_plan,
            &postgres_plan,
        )
        .expect("sqlx executable statements should convert");

        let statement_order = executable_statements
            .iter()
            .map(|statement| statement_kind_name(statement.kind).to_string())
            .collect::<Vec<_>>();
        assert_eq!(statement_order, schema_case.expected_statement_order);

        let operation_key_bind_statement_count = executable_statements
            .iter()
            .filter(|statement| {
                statement
                    .bind_markers
                    .contains(&ConsistentLedgerPostgresSqlxBindMarker::OperationKeyBind)
            })
            .count();
        assert_eq!(
            operation_key_bind_statement_count,
            schema_case.operation_key_bind_statement_count
        );

        for executable in &executable_statements {
            let kind_name = statement_kind_name(executable.kind);
            let expected_returning = schema_fixture
                .returning_schema_by_kind
                .get(kind_name)
                .expect("expected returning schema");
            assert_eq!(
                column_names(&executable.returning_columns),
                *expected_returning,
                "{kind_name} returning schema"
            );
            assert_eq!(executable.bind_markers.len(), executable.binds.len());
            assert!(
                executable.sql.contains("$1"),
                "{kind_name} should use binds"
            );
            assert!(
                !executable.sql.contains("<private"),
                "{kind_name} should be concrete"
            );
            assert!(
                !executable.sql.contains("$tenant_id"),
                "{kind_name} should not expose template placeholders"
            );
            assert!(
                !executable.sql.contains("$private_operation_key"),
                "{kind_name} should not expose raw operation-key placeholders"
            );
        }

        let insert = executable_statements
            .iter()
            .find(|statement| {
                statement.kind == ConsistentLedgerPostgresStatementKind::InsertLedgerEntry
            })
            .expect("insert executable");
        assert_eq!(
            bind_marker_names(&insert.bind_markers),
            schema_case.expected_insert_bind_markers
        );
        assert_eq!(
            column_names(&insert.returning_columns),
            schema_case.expected_insert_returning
        );

        match &schema_case.expected_status_update_returning {
            Some(expected_returning) => {
                let update = executable_statements
                    .iter()
                    .find(|statement| {
                        statement.kind == ConsistentLedgerPostgresStatementKind::UpdateLedgerStatus
                    })
                    .expect("status update executable");
                assert_eq!(
                    bind_marker_names(&update.bind_markers),
                    schema_case
                        .expected_status_update_bind_markers
                        .clone()
                        .expect("expected status update bind markers")
                );
                assert_eq!(column_names(&update.returning_columns), *expected_returning);
                assert!(
                    !update.sql.contains("related_ledger_entry_id"),
                    "status update must target ledger_entry_id only"
                );
            }
            None => assert!(
                executable_statements.iter().all(|statement| {
                    statement.kind != ConsistentLedgerPostgresStatementKind::UpdateLedgerStatus
                }),
                "{} should not include a status update",
                schema_case.source_case
            ),
        }

        for fragment in &schema_case.must_contain_sql_fragments {
            assert!(
                executable_statements
                    .iter()
                    .any(|statement| statement.sql.contains(fragment)),
                "{} should contain SQL fragment `{fragment}`",
                schema_case.source_case
            );
        }

        let debug = format!("{executable_statements:?}");
        assert!(debug.contains("returning_columns"));
        assert!(debug.contains("<concrete_sql_omitted>"));
        assert!(debug.contains("OperationKey(<bind_marker_only>)"));
        assert_secret_safe_text(
            &debug,
            &adapter_fixture.secret_safe_forbidden_terms,
            &format!("{} sqlx schema debug", schema_case.source_case),
        );
    }
}

#[cfg(feature = "postgres-sqlx")]
#[test]
fn postgres_sqlx_feature_boundary_keeps_bind_values_private_and_maps_sqlx_errors() {
    let adapter_fixture: SqlxAdapterFixture =
        serde_json::from_str(SQLX_ADAPTER_FIXTURE).expect("adapter fixture should parse");
    let executable = ConsistentLedgerPostgresSqlxExecutableStatement {
        order: 7,
        kind: ConsistentLedgerPostgresStatementKind::InsertLedgerEntry,
        sql: "insert into ledger_entries (tenant_id, operation_key_hash, metadata) values ($1, $2, $3)",
        bind_markers: vec![
            ConsistentLedgerPostgresSqlxBindMarker::TenantId,
            ConsistentLedgerPostgresSqlxBindMarker::OperationKeyBind,
            ConsistentLedgerPostgresSqlxBindMarker::Metadata,
        ],
        returning_columns: vec!["id", "entry_type", "amount", "currency", "status"],
        binds: vec![
            ConsistentLedgerPostgresSqlxBindValue::Uuid(
                "00000000-0000-0000-0000-000000000001"
                    .parse()
                    .expect("uuid"),
            ),
            ConsistentLedgerPostgresSqlxBindValue::OperationKey(
                "reserve:00000000-0000-0000-0000-000000000111".to_string(),
            ),
            ConsistentLedgerPostgresSqlxBindValue::Json(serde_json::json!({
                "payload": "secret request material",
                "Authorization": "Bearer provider_key",
                "database_url": "postgres://user:pass@db",
            })),
        ],
    };

    let debug = format!("{executable:?}");
    assert!(debug.contains("operation_key_bind"));
    assert!(debug.contains("OperationKey(<bind_marker_only>)"));
    assert_secret_safe_text(
        &debug,
        &adapter_fixture.secret_safe_forbidden_terms,
        "sqlx executable debug",
    );

    let timeout = map_consistent_ledger_postgres_sqlx_error(
        &sqlx::Error::PoolTimedOut,
        Some(ConsistentLedgerPostgresStatementKind::LockWallet),
    );
    assert_eq!(timeout.code, "db_timeout");
    assert_eq!(timeout.category, "db_transaction");
    assert_eq!(timeout.detail_output, "omitted");

    let unique = map_consistent_ledger_postgres_sqlx_error(
        &sqlx::Error::Database(Box::new(FakeSqlxDatabaseError {
            code: "23505",
            message: "duplicate reserve:00000000-0000-0000-0000-000000000111 postgres://user:pass@db",
        })),
        Some(ConsistentLedgerPostgresStatementKind::InsertLedgerEntry),
    );
    assert_eq!(unique.code, "db_unique_constraint_violation");
    assert_eq!(unique.category, "db_constraint");
    assert_eq!(unique.detail_output, "omitted");

    let serialized = serde_json::to_string(&unique).expect("error should serialize");
    assert_secret_safe_text(
        &serialized,
        &adapter_fixture.secret_safe_forbidden_terms,
        "sqlx mapped db error",
    );
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

#[cfg(feature = "postgres-sqlx")]
fn bind_marker_names(markers: &[ConsistentLedgerPostgresSqlxBindMarker]) -> Vec<String> {
    markers
        .iter()
        .map(|marker| bind_marker_name(*marker).to_string())
        .collect()
}

#[cfg(feature = "postgres-sqlx")]
fn bind_marker_name(marker: ConsistentLedgerPostgresSqlxBindMarker) -> &'static str {
    match marker {
        ConsistentLedgerPostgresSqlxBindMarker::TenantId => "tenant_id",
        ConsistentLedgerPostgresSqlxBindMarker::ProjectId => "project_id",
        ConsistentLedgerPostgresSqlxBindMarker::VirtualKeyId => "virtual_key_id",
        ConsistentLedgerPostgresSqlxBindMarker::WalletId => "wallet_id",
        ConsistentLedgerPostgresSqlxBindMarker::Currency => "currency",
        ConsistentLedgerPostgresSqlxBindMarker::Now => "now",
        ConsistentLedgerPostgresSqlxBindMarker::RequestId => "request_id",
        ConsistentLedgerPostgresSqlxBindMarker::SourceLedgerEntryId => "source_ledger_entry_id",
        ConsistentLedgerPostgresSqlxBindMarker::RelatedLedgerEntryId => "related_ledger_entry_id",
        ConsistentLedgerPostgresSqlxBindMarker::LedgerEntryId => "ledger_entry_id",
        ConsistentLedgerPostgresSqlxBindMarker::BudgetId => "budget_id",
        ConsistentLedgerPostgresSqlxBindMarker::RequiredDebit => "required_debit",
        ConsistentLedgerPostgresSqlxBindMarker::AvailableBeforeWrite => "available_before_write",
        ConsistentLedgerPostgresSqlxBindMarker::EntryType => "entry_type",
        ConsistentLedgerPostgresSqlxBindMarker::Amount => "amount",
        ConsistentLedgerPostgresSqlxBindMarker::Status => "status",
        ConsistentLedgerPostgresSqlxBindMarker::FromStatus => "from_status",
        ConsistentLedgerPostgresSqlxBindMarker::ToStatus => "to_status",
        ConsistentLedgerPostgresSqlxBindMarker::Metadata => "metadata",
        ConsistentLedgerPostgresSqlxBindMarker::OperationKeyBind => "operation_key_bind",
    }
}

#[cfg(feature = "postgres-sqlx")]
fn bind_type_names(binds: &[ConsistentLedgerPostgresSqlxBindValue]) -> Vec<String> {
    binds
        .iter()
        .map(|bind| bind_type_name(bind).to_string())
        .collect()
}

#[cfg(feature = "postgres-sqlx")]
fn bind_type_name(bind: &ConsistentLedgerPostgresSqlxBindValue) -> &'static str {
    match bind {
        ConsistentLedgerPostgresSqlxBindValue::Uuid(_) => "uuid",
        ConsistentLedgerPostgresSqlxBindValue::OptionalUuid(_) => "optional_uuid",
        ConsistentLedgerPostgresSqlxBindValue::Text(_) => "text",
        ConsistentLedgerPostgresSqlxBindValue::OptionalText(_) => "optional_text",
        ConsistentLedgerPostgresSqlxBindValue::DecimalText(_) => "decimal_text",
        ConsistentLedgerPostgresSqlxBindValue::I64(_) => "i64",
        ConsistentLedgerPostgresSqlxBindValue::Bool(_) => "bool",
        ConsistentLedgerPostgresSqlxBindValue::Json(_) => "json",
        ConsistentLedgerPostgresSqlxBindValue::OperationKey(_) => "operation_key",
    }
}

#[cfg(feature = "postgres-sqlx")]
fn column_names(columns: &[&'static str]) -> Vec<String> {
    columns.iter().map(|column| (*column).to_string()).collect()
}

#[cfg(feature = "postgres-sqlx")]
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

#[cfg(feature = "postgres-sqlx")]
#[derive(Debug)]
struct FakeSqlxDatabaseError {
    code: &'static str,
    message: &'static str,
}

#[cfg(feature = "postgres-sqlx")]
impl fmt::Display for FakeSqlxDatabaseError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.message)
    }
}

#[cfg(feature = "postgres-sqlx")]
impl Error for FakeSqlxDatabaseError {}

#[cfg(feature = "postgres-sqlx")]
impl sqlx::error::DatabaseError for FakeSqlxDatabaseError {
    fn message(&self) -> &str {
        self.message
    }

    fn code(&self) -> Option<Cow<'_, str>> {
        Some(Cow::Borrowed(self.code))
    }

    fn as_error(&self) -> &(dyn Error + Send + Sync + 'static) {
        self
    }

    fn as_error_mut(&mut self) -> &mut (dyn Error + Send + Sync + 'static) {
        self
    }

    fn into_error(self: Box<Self>) -> Box<dyn Error + Send + Sync + 'static> {
        self
    }

    fn kind(&self) -> sqlx::error::ErrorKind {
        match self.code {
            "23505" => sqlx::error::ErrorKind::UniqueViolation,
            "23503" => sqlx::error::ErrorKind::ForeignKeyViolation,
            "23514" => sqlx::error::ErrorKind::CheckViolation,
            "23502" => sqlx::error::ErrorKind::NotNullViolation,
            _ => sqlx::error::ErrorKind::Other,
        }
    }
}
