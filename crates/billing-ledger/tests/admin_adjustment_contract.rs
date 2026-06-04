use ai_gateway_billing_ledger::{
    AdminAdjustmentLedgerRequest, CONSISTENT_LEDGER_COMMAND_EXECUTOR_SCHEMA,
    CONSISTENT_LEDGER_POSTGRES_EXECUTOR_SCHEMA, CONSISTENT_LEDGER_POSTGRES_EXECUTOR_SUMMARY_SCHEMA,
    ConsistentBudgetDimension, ConsistentBudgetSnapshot, ConsistentCreditGrantSnapshot,
    ConsistentLedgerCommandExecutionOutcome, ConsistentLedgerCommandExecutor,
    ConsistentLedgerPostgresExecutorError, ConsistentLedgerPostgresExecutorOutcome,
    ConsistentLedgerPostgresExecutorResult, ConsistentLedgerPostgresRowCountExpectation,
    ConsistentLedgerPostgresStatement, ConsistentLedgerPostgresStatementKind,
    ConsistentLedgerPostgresStatementOutcome, ConsistentLedgerPostgresStatementResult,
    ConsistentLedgerPostgresTransactionExecutor, ConsistentLedgerScope,
    ConsistentLedgerWriteRequest, ConsistentLedgerWriterState, ConsistentWalletSnapshot,
    FixedDecimal, InMemoryConsistentLedgerWriter, LedgerAdminAdjustmentKind, LedgerEntryRecord,
    LedgerEntryStatus, LedgerEntryType, LedgerOperationKind, LedgerOperationOutcome,
    admin_adjustment_ledger_idempotency_key, execute_consistent_ledger_postgres_plan,
    plan_consistent_ledger_postgres_execution, plan_consistent_ledger_write,
    plan_consistent_ledger_write_commands, plan_ledger_admin_adjustment,
    summarize_consistent_ledger_postgres_executor_result,
};
#[cfg(feature = "postgres-sqlx")]
use ai_gateway_billing_ledger::{
    ConsistentLedgerPostgresSqlxBindMarker, ConsistentLedgerPostgresSqlxBindValue,
    plan_consistent_ledger_postgres_sqlx_adapter_contract,
    plan_consistent_ledger_postgres_sqlx_executable_statements,
};
use uuid::Uuid;

const MONEY_SCALE: u32 = 8;
const TENANT_ID: Uuid = Uuid::from_u128(1);
const PROJECT_ID: Uuid = Uuid::from_u128(2);
const VIRTUAL_KEY_ID: Uuid = Uuid::from_u128(3);
const WALLET_ID: Uuid = Uuid::from_u128(4);
const REQUEST_ID: Uuid = Uuid::from_u128(11);
const ADJUSTMENT_OPERATION_ID: Uuid = Uuid::from_u128(61);
const RELATED_LEDGER_ENTRY_ID: Uuid = Uuid::from_u128(31);
const NEXT_LEDGER_ENTRY_ID: Uuid = Uuid::from_u128(101);

#[test]
fn admin_adjustment_contract_plans_confirmed_credit_and_debit_without_secret_output() {
    let credit = plan_ledger_admin_adjustment(
        AdminAdjustmentLedgerRequest {
            adjustment_operation_id: ADJUSTMENT_OPERATION_ID,
            request_id: Some(REQUEST_ID),
            related_ledger_entry_id: None,
            amount: money("0.15000000"),
            currency: "USD".to_string(),
        },
        &[],
    )
    .expect("admin credit should plan");

    assert_eq!(credit.operation, LedgerOperationKind::AdminAdjustment);
    assert_eq!(credit.outcome, LedgerOperationOutcome::Apply);
    assert_eq!(credit.entries.len(), 1);
    assert_eq!(credit.entries[0].entry_type, LedgerEntryType::Adjust);
    assert_eq!(credit.entries[0].status, LedgerEntryStatus::Confirmed);
    assert_eq!(credit.entries[0].amount.to_string(), "0.15000000");
    assert_eq!(
        credit.entries[0].metadata.admin_adjustment_kind,
        Some(LedgerAdminAdjustmentKind::Credit)
    );

    let debit = plan_ledger_admin_adjustment(
        AdminAdjustmentLedgerRequest {
            adjustment_operation_id: Uuid::from_u128(62),
            request_id: Some(REQUEST_ID),
            related_ledger_entry_id: Some(RELATED_LEDGER_ENTRY_ID),
            amount: money("-0.05000000"),
            currency: "USD".to_string(),
        },
        &[],
    )
    .expect("admin debit should plan");

    assert_eq!(debit.entries[0].entry_type, LedgerEntryType::Adjust);
    assert_eq!(debit.entries[0].status, LedgerEntryStatus::Confirmed);
    assert_eq!(debit.entries[0].amount.to_string(), "-0.05000000");
    assert_eq!(
        debit.entries[0].metadata.admin_adjustment_kind,
        Some(LedgerAdminAdjustmentKind::Debit)
    );

    let serialized = serde_json::to_string(&debit).expect("debit plan should serialize");
    assert_secret_safe("admin adjustment plan", &serialized);
}

#[test]
fn admin_adjustment_contract_replays_idempotently_without_public_operation_key() {
    let existing = LedgerEntryRecord {
        id: ADJUSTMENT_OPERATION_ID,
        request_id: Some(REQUEST_ID),
        related_ledger_entry_id: None,
        entry_type: LedgerEntryType::Adjust,
        amount: money("0.15000000"),
        currency: "USD".to_string(),
        status: LedgerEntryStatus::Confirmed,
        idempotency_key: admin_adjustment_ledger_idempotency_key(ADJUSTMENT_OPERATION_ID),
    };

    let replay = plan_ledger_admin_adjustment(
        AdminAdjustmentLedgerRequest {
            adjustment_operation_id: ADJUSTMENT_OPERATION_ID,
            request_id: Some(REQUEST_ID),
            related_ledger_entry_id: None,
            amount: money("0.15000000"),
            currency: "USD".to_string(),
        },
        &[existing],
    )
    .expect("same admin adjustment should replay");

    assert_eq!(
        replay.outcome,
        LedgerOperationOutcome::Idempotent {
            existing_entry_id: ADJUSTMENT_OPERATION_ID
        }
    );
    assert!(replay.entries.is_empty());

    let serialized = serde_json::to_string(&replay).expect("replay should serialize");
    assert_secret_safe("admin adjustment replay", &serialized);
}

#[test]
fn admin_adjustment_runtime_writer_applies_credit_and_debit_with_bounded_commands() {
    let credit_request = admin_adjustment_request("0.15000000", ADJUSTMENT_OPERATION_ID);
    let credit_state = writer_state("1.00000000", "0.00000000");
    let credit_plan = plan_consistent_ledger_write(credit_request.clone(), &credit_state)
        .expect("admin adjustment credit writer plan");

    assert_eq!(credit_plan.operation, LedgerOperationKind::AdminAdjustment);
    assert_eq!(
        credit_plan.schema_version,
        "billing_ledger_consistent_writer_plan.v1"
    );
    assert_eq!(
        credit_plan.balance_window.required_debit.to_string(),
        "0.00000000"
    );
    assert_eq!(
        credit_plan.balance_window.refund_credit.to_string(),
        "0.15000000"
    );
    assert_eq!(
        credit_plan.balance_window.available_after_write.to_string(),
        "1.15000000"
    );
    assert_eq!(
        credit_plan.ledger_plan.entries[0].entry_type,
        LedgerEntryType::Adjust
    );
    assert_eq!(
        credit_plan.lock_plan.lock_order[3].bounded_by,
        vec![
            "tenant_id",
            "request_id",
            "related_ledger_entry_id",
            "idempotency_key"
        ]
    );

    let credit_command_plan = plan_consistent_ledger_write_commands(&credit_plan);
    assert_eq!(credit_command_plan.operation_key_output, "omitted");
    assert_eq!(credit_command_plan.commands.len(), 3);
    assert_eq!(
        credit_command_plan.commands[2].entry_type,
        Some(LedgerEntryType::Adjust)
    );
    assert_eq!(
        credit_command_plan.commands[2].status,
        Some(LedgerEntryStatus::Confirmed)
    );
    assert_eq!(
        credit_command_plan.commands[2].operation_key_output,
        "omitted"
    );
    assert!(
        !credit_command_plan.commands[2]
            .bounded_by
            .iter()
            .any(|bound| *bound == "idempotency_key")
    );

    let mut writer = InMemoryConsistentLedgerWriter::new(credit_state, NEXT_LEDGER_ENTRY_ID);
    let credit_execution = writer.execute_consistent_ledger_write(credit_request);
    assert_eq!(
        credit_execution.schema_version,
        CONSISTENT_LEDGER_COMMAND_EXECUTOR_SCHEMA
    );
    assert_eq!(
        credit_execution.operation,
        LedgerOperationKind::AdminAdjustment
    );
    assert_eq!(
        credit_execution.outcome,
        ConsistentLedgerCommandExecutionOutcome::Applied
    );
    assert_eq!(credit_execution.operation_key_output, "omitted");
    assert_eq!(credit_execution.state_summary.confirmed_adjustment_count, 1);
    assert_secret_safe(
        "admin adjustment credit execution",
        &serde_json::to_string(&credit_execution).expect("credit execution should serialize"),
    );

    let debit_request = admin_adjustment_request("-0.25000000", Uuid::from_u128(62));
    let debit_state = writer_state("1.00000000", "1.00000000");
    let debit_plan = plan_consistent_ledger_write(debit_request.clone(), &debit_state)
        .expect("admin adjustment debit writer plan");

    assert_eq!(
        debit_plan.balance_window.required_debit.to_string(),
        "0.25000000"
    );
    assert_eq!(
        debit_plan.balance_window.refund_credit.to_string(),
        "0.00000000"
    );
    assert_eq!(
        debit_plan.balance_window.available_after_write.to_string(),
        "0.75000000"
    );
    assert_eq!(
        debit_plan.budget_checks[0].required_debit.to_string(),
        "0.25000000"
    );
    assert!(debit_plan.budget_checks[0].passed);

    let mut writer = InMemoryConsistentLedgerWriter::new(debit_state, NEXT_LEDGER_ENTRY_ID);
    let debit_execution = writer.execute_consistent_ledger_write(debit_request);
    assert_eq!(
        debit_execution.outcome,
        ConsistentLedgerCommandExecutionOutcome::Applied
    );
    assert_eq!(debit_execution.state_summary.confirmed_adjustment_count, 1);
    assert_secret_safe(
        "admin adjustment debit execution",
        &serde_json::to_string(&debit_execution).expect("debit execution should serialize"),
    );
}

#[test]
fn admin_adjustment_runtime_writer_replays_and_refuses_without_secret_output() {
    let existing = LedgerEntryRecord {
        id: ADJUSTMENT_OPERATION_ID,
        request_id: Some(REQUEST_ID),
        related_ledger_entry_id: Some(RELATED_LEDGER_ENTRY_ID),
        entry_type: LedgerEntryType::Adjust,
        amount: money("-0.25000000"),
        currency: "USD".to_string(),
        status: LedgerEntryStatus::Confirmed,
        idempotency_key: admin_adjustment_ledger_idempotency_key(ADJUSTMENT_OPERATION_ID),
    };
    let replay_state = ConsistentLedgerWriterState {
        ledger_entries: vec![existing],
        ..writer_state("1.00000000", "1.00000000")
    };
    let replay_request = admin_adjustment_request("-0.25000000", ADJUSTMENT_OPERATION_ID);
    let replay_plan = plan_consistent_ledger_write(replay_request.clone(), &replay_state)
        .expect("same admin adjustment should be idempotent");
    assert_eq!(
        replay_plan.outcome,
        LedgerOperationOutcome::Idempotent {
            existing_entry_id: ADJUSTMENT_OPERATION_ID
        }
    );
    assert!(
        plan_consistent_ledger_write_commands(&replay_plan)
            .commands
            .is_empty()
    );

    let mut writer = InMemoryConsistentLedgerWriter::new(replay_state, NEXT_LEDGER_ENTRY_ID);
    let replay_execution = writer.execute_consistent_ledger_write(replay_request);
    assert_eq!(
        replay_execution.outcome,
        ConsistentLedgerCommandExecutionOutcome::Idempotent
    );
    assert_eq!(replay_execution.commands.len(), 0);
    assert_eq!(replay_execution.operation_key_output, "omitted");
    assert_secret_safe(
        "admin adjustment replay execution",
        &serde_json::to_string(&replay_execution).expect("replay execution should serialize"),
    );

    let mut writer = InMemoryConsistentLedgerWriter::new(
        writer_state("0.10000000", "1.00000000"),
        NEXT_LEDGER_ENTRY_ID,
    );
    let refused = writer.execute_consistent_ledger_write(admin_adjustment_request(
        "-0.25000000",
        Uuid::from_u128(62),
    ));
    assert_eq!(
        refused.outcome,
        ConsistentLedgerCommandExecutionOutcome::Rejected
    );
    assert_eq!(refused.operation, LedgerOperationKind::AdminAdjustment);
    assert_eq!(refused.operation_key_output, "omitted");
    assert_eq!(
        refused.error.as_ref().map(|error| error.code),
        Some("insufficient_wallet_balance")
    );
    assert_eq!(
        refused.error.as_ref().map(|error| error.detail_output),
        Some("omitted")
    );
    assert_secret_safe(
        "admin adjustment refused execution",
        &serde_json::to_string(&refused).expect("refused execution should serialize"),
    );
}

#[test]
fn admin_adjustment_postgres_bridge_maps_apply_idempotent_and_refusal_summaries() {
    let debit_request = admin_adjustment_request("-0.25000000", ADJUSTMENT_OPERATION_ID);
    let debit_state = writer_state("1.00000000", "1.00000000");
    let writer_plan =
        plan_consistent_ledger_write(debit_request, &debit_state).expect("writer plan");
    let command_plan = plan_consistent_ledger_write_commands(&writer_plan);
    let postgres_plan = plan_consistent_ledger_postgres_execution(&writer_plan, &command_plan);

    assert_eq!(
        postgres_plan.operation,
        LedgerOperationKind::AdminAdjustment
    );
    assert_eq!(postgres_plan.operation_key_output, "omitted");
    assert!(postgres_plan.sql_statements.iter().all(|statement| {
        !statement.where_bounds.is_empty()
            && statement.operation_key_output == "omitted"
            && !statement
                .where_bounds
                .iter()
                .any(|bound| *bound == "idempotency_key")
    }));
    let ledger_lock = postgres_plan
        .sql_statements
        .iter()
        .find(|statement| {
            statement.kind == ConsistentLedgerPostgresStatementKind::LockLedgerEntries
        })
        .expect("ledger lock statement");
    assert_eq!(
        ledger_lock.where_bounds,
        vec![
            "tenant_id",
            "request_id",
            "related_ledger_entry_id",
            "private_operation_key"
        ]
    );
    assert_eq!(
        ledger_lock.row_count_expectation,
        ConsistentLedgerPostgresRowCountExpectation::ZeroOrMore
    );
    let insert = postgres_plan
        .sql_statements
        .iter()
        .find(|statement| {
            statement.kind == ConsistentLedgerPostgresStatementKind::InsertLedgerEntry
        })
        .expect("insert statement");
    assert_eq!(
        insert.row_count_expectation,
        ConsistentLedgerPostgresRowCountExpectation::ExactlyOne
    );
    assert_eq!(insert.entry_type, Some(LedgerEntryType::Adjust));
    assert_eq!(insert.status, Some(LedgerEntryStatus::Confirmed));

    let mut executor = FakePostgresExecutor::default();
    let applied = execute_consistent_ledger_postgres_plan(&mut executor, &postgres_plan);
    let applied_summary = summarize_consistent_ledger_postgres_executor_result(&applied);
    assert_eq!(
        applied_summary.operation,
        LedgerOperationKind::AdminAdjustment
    );
    assert_eq!(
        applied_summary.outcome,
        ConsistentLedgerPostgresExecutorOutcome::Applied
    );
    assert!(applied_summary.committed);
    assert!(!applied_summary.rolled_back);
    assert_eq!(applied_summary.refused_statement_count, 0);
    assert_eq!(applied_summary.error_detail_output, "omitted");
    assert!(!applied_summary.row_count_mismatch);
    assert_secret_safe(
        "admin adjustment postgres applied summary",
        &serde_json::to_string(&applied_summary).expect("applied summary should serialize"),
    );

    let existing_state = ConsistentLedgerWriterState {
        ledger_entries: vec![LedgerEntryRecord {
            id: ADJUSTMENT_OPERATION_ID,
            request_id: Some(REQUEST_ID),
            related_ledger_entry_id: Some(RELATED_LEDGER_ENTRY_ID),
            entry_type: LedgerEntryType::Adjust,
            amount: money("-0.25000000"),
            currency: "USD".to_string(),
            status: LedgerEntryStatus::Confirmed,
            idempotency_key: admin_adjustment_ledger_idempotency_key(ADJUSTMENT_OPERATION_ID),
        }],
        ..writer_state("1.00000000", "1.00000000")
    };
    let idempotent_writer_plan = plan_consistent_ledger_write(
        admin_adjustment_request("-0.25000000", ADJUSTMENT_OPERATION_ID),
        &existing_state,
    )
    .expect("idempotent writer plan");
    let idempotent_command_plan = plan_consistent_ledger_write_commands(&idempotent_writer_plan);
    assert!(idempotent_command_plan.commands.is_empty());
    let idempotent_postgres_plan = plan_consistent_ledger_postgres_execution(
        &idempotent_writer_plan,
        &idempotent_command_plan,
    );
    let mut executor = FakePostgresExecutor::default();
    let idempotent =
        execute_consistent_ledger_postgres_plan(&mut executor, &idempotent_postgres_plan);
    let idempotent_summary = summarize_consistent_ledger_postgres_executor_result(&idempotent);
    assert_eq!(
        idempotent_summary.outcome,
        ConsistentLedgerPostgresExecutorOutcome::Idempotent
    );
    assert!(idempotent_summary.committed);
    assert!(!idempotent_summary.rolled_back);
    assert_eq!(idempotent_summary.executed_statement_count, 4);
    assert_eq!(idempotent_summary.refused_statement_count, 0);
    assert_eq!(idempotent_summary.operation_key_output, "omitted");

    let mut executor = FakePostgresExecutor {
        row_count_override_kind: Some(ConsistentLedgerPostgresStatementKind::InsertLedgerEntry),
        row_count_override: Some(0),
    };
    let refused = execute_consistent_ledger_postgres_plan(&mut executor, &postgres_plan);
    let refused_summary = summarize_consistent_ledger_postgres_executor_result(&refused);
    assert_eq!(
        refused_summary.outcome,
        ConsistentLedgerPostgresExecutorOutcome::RolledBack
    );
    assert!(!refused_summary.committed);
    assert!(refused_summary.rolled_back);
    assert_eq!(refused_summary.refused_statement_count, 1);
    assert_eq!(
        refused_summary.error_code.as_deref(),
        Some("ledger_insert_conflict_no_row")
    );
    assert_eq!(
        refused_summary.error_category.as_deref(),
        Some("row_count_enforcement")
    );
    assert_eq!(refused_summary.error_detail_output, "omitted");
    assert!(refused_summary.row_count_mismatch);
    assert_secret_safe(
        "admin adjustment postgres refused summary",
        &serde_json::to_string(&refused_summary).expect("refused summary should serialize"),
    );
}

#[cfg(feature = "postgres-sqlx")]
#[test]
fn admin_adjustment_sqlx_bridge_uses_bind_only_operation_key() {
    let writer_plan = plan_consistent_ledger_write(
        admin_adjustment_request("-0.25000000", ADJUSTMENT_OPERATION_ID),
        &writer_state("1.00000000", "1.00000000"),
    )
    .expect("admin adjustment writer plan");
    let command_plan = plan_consistent_ledger_write_commands(&writer_plan);
    let postgres_plan = plan_consistent_ledger_postgres_execution(&writer_plan, &command_plan);
    let adapter_contract = plan_consistent_ledger_postgres_sqlx_adapter_contract(&postgres_plan);
    let executable_statements =
        plan_consistent_ledger_postgres_sqlx_executable_statements(&writer_plan, &postgres_plan)
            .expect("admin adjustment sqlx statements should convert");

    let ledger_lock = executable_statements
        .iter()
        .find(|statement| {
            statement.kind == ConsistentLedgerPostgresStatementKind::LockLedgerEntries
        })
        .expect("ledger lock executable");
    assert!(
        ledger_lock
            .bind_markers
            .contains(&ConsistentLedgerPostgresSqlxBindMarker::OperationKeyBind)
    );
    let insert = executable_statements
        .iter()
        .find(|statement| {
            statement.kind == ConsistentLedgerPostgresStatementKind::InsertLedgerEntry
        })
        .expect("insert executable");
    assert!(
        insert
            .bind_markers
            .contains(&ConsistentLedgerPostgresSqlxBindMarker::OperationKeyBind)
    );
    assert!(insert.binds.iter().any(|bind| {
        matches!(
            bind,
            ConsistentLedgerPostgresSqlxBindValue::OperationKey(value)
                if value == &writer_plan.idempotency_key
        )
    }));
    let insert_contract = adapter_contract
        .statements
        .iter()
        .find(|statement| {
            statement.kind == ConsistentLedgerPostgresStatementKind::InsertLedgerEntry
        })
        .expect("insert sqlx contract");
    assert_eq!(insert_contract.operation_key_output, "bind_marker_only");

    let debug = format!("{executable_statements:?}");
    assert!(debug.contains("operation_key_bind"));
    assert!(debug.contains("OperationKey(<bind_marker_only>)"));
    assert!(debug.contains("<concrete_sql_omitted>"));
    assert_secret_safe("admin adjustment sqlx executable debug", &debug);
}

#[test]
fn admin_adjustment_executor_summary_matches_postgres_summary_schema() {
    let applied = summarize_consistent_ledger_postgres_executor_result(&executor_result(
        ConsistentLedgerPostgresExecutorOutcome::Applied,
        true,
        false,
        vec![statement_result(
            ConsistentLedgerPostgresStatementOutcome::Executed,
            1,
        )],
        None,
    ));
    assert_eq!(
        applied.schema_version,
        CONSISTENT_LEDGER_POSTGRES_EXECUTOR_SUMMARY_SCHEMA
    );
    assert_eq!(applied.operation, LedgerOperationKind::AdminAdjustment);
    assert_eq!(
        applied.outcome,
        ConsistentLedgerPostgresExecutorOutcome::Applied
    );
    assert_eq!(applied.operation_key_output, "omitted");
    assert!(applied.committed);
    assert!(!applied.rolled_back);
    assert_eq!(applied.statement_count, 1);
    assert_eq!(applied.executed_statement_count, 1);
    assert_eq!(applied.refused_statement_count, 0);
    assert_eq!(applied.total_rows_affected, 1);
    assert_eq!(
        applied.final_statement_kind,
        Some(ConsistentLedgerPostgresStatementKind::InsertLedgerEntry)
    );
    assert_eq!(applied.error_code, None);
    assert_eq!(applied.error_category, None);
    assert_eq!(applied.error_detail_output, "omitted");
    assert!(!applied.row_count_mismatch);

    let idempotent = summarize_consistent_ledger_postgres_executor_result(&executor_result(
        ConsistentLedgerPostgresExecutorOutcome::Idempotent,
        true,
        false,
        Vec::new(),
        None,
    ));
    assert_eq!(
        idempotent.outcome,
        ConsistentLedgerPostgresExecutorOutcome::Idempotent
    );
    assert!(idempotent.committed);
    assert!(!idempotent.rolled_back);
    assert_eq!(idempotent.statement_count, 0);
    assert_eq!(idempotent.executed_statement_count, 0);
    assert_eq!(idempotent.refused_statement_count, 0);
    assert_eq!(idempotent.total_rows_affected, 0);
    assert_eq!(idempotent.operation_key_output, "omitted");
    assert_eq!(idempotent.error_detail_output, "omitted");
    assert!(!idempotent.row_count_mismatch);

    let refused = summarize_consistent_ledger_postgres_executor_result(&executor_result(
        ConsistentLedgerPostgresExecutorOutcome::RolledBack,
        false,
        true,
        vec![statement_result(
            ConsistentLedgerPostgresStatementOutcome::Refused,
            0,
        )],
        Some(ConsistentLedgerPostgresExecutorError::row_count_mismatch(
            "admin_adjustment_insert_row_count_mismatch",
        )),
    ));
    assert_eq!(
        refused.outcome,
        ConsistentLedgerPostgresExecutorOutcome::RolledBack
    );
    assert!(!refused.committed);
    assert!(refused.rolled_back);
    assert_eq!(refused.statement_count, 1);
    assert_eq!(refused.executed_statement_count, 0);
    assert_eq!(refused.refused_statement_count, 1);
    assert_eq!(refused.total_rows_affected, 0);
    assert_eq!(
        refused.error_code.as_deref(),
        Some("admin_adjustment_insert_row_count_mismatch")
    );
    assert_eq!(
        refused.error_category.as_deref(),
        Some("row_count_enforcement")
    );
    assert_eq!(refused.error_detail_output, "omitted");
    assert!(refused.row_count_mismatch);

    for (label, value) in [
        (
            "admin adjustment applied summary",
            serde_json::to_string(&applied).expect("applied summary"),
        ),
        (
            "admin adjustment idempotent summary",
            serde_json::to_string(&idempotent).expect("idempotent summary"),
        ),
        (
            "admin adjustment refused summary",
            serde_json::to_string(&refused).expect("refused summary"),
        ),
        ("admin adjustment refused debug", format!("{refused:?}")),
    ] {
        assert_secret_safe(label, &value);
    }
}

fn executor_result(
    outcome: ConsistentLedgerPostgresExecutorOutcome,
    committed: bool,
    rolled_back: bool,
    statement_results: Vec<ConsistentLedgerPostgresStatementResult>,
    error: Option<ConsistentLedgerPostgresExecutorError>,
) -> ConsistentLedgerPostgresExecutorResult {
    ConsistentLedgerPostgresExecutorResult {
        schema_version: CONSISTENT_LEDGER_POSTGRES_EXECUTOR_SCHEMA,
        executor: "postgres_consistent_ledger_command_executor",
        operation: LedgerOperationKind::AdminAdjustment,
        outcome,
        operation_key_output: "omitted",
        committed,
        rolled_back,
        statement_results,
        error,
    }
}

fn statement_result(
    outcome: ConsistentLedgerPostgresStatementOutcome,
    rows_affected: u64,
) -> ConsistentLedgerPostgresStatementResult {
    ConsistentLedgerPostgresStatementResult {
        order: 1,
        kind: ConsistentLedgerPostgresStatementKind::InsertLedgerEntry,
        target: "ledger_entries",
        outcome,
        rows_affected,
        operation_key_output: "omitted",
    }
}

#[derive(Debug, Default)]
struct FakePostgresExecutor {
    row_count_override_kind: Option<ConsistentLedgerPostgresStatementKind>,
    row_count_override: Option<u64>,
}

impl ConsistentLedgerPostgresTransactionExecutor for FakePostgresExecutor {
    fn begin_transaction(&mut self) -> Result<(), ConsistentLedgerPostgresExecutorError> {
        Ok(())
    }

    fn execute_statement(
        &mut self,
        statement: &ConsistentLedgerPostgresStatement,
    ) -> Result<ConsistentLedgerPostgresStatementResult, ConsistentLedgerPostgresExecutorError>
    {
        let rows_affected = if self.row_count_override_kind == Some(statement.kind) {
            self.row_count_override.unwrap_or(0)
        } else if statement.row_count_expectation
            == ConsistentLedgerPostgresRowCountExpectation::ExactlyOne
        {
            1
        } else {
            0
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
        Ok(())
    }

    fn rollback_transaction(&mut self) -> Result<(), ConsistentLedgerPostgresExecutorError> {
        Ok(())
    }
}

fn admin_adjustment_request(
    amount: &str,
    adjustment_operation_id: Uuid,
) -> ConsistentLedgerWriteRequest {
    ConsistentLedgerWriteRequest::AdminAdjustment {
        scope: scope(),
        adjustment_operation_id,
        request_id: Some(REQUEST_ID),
        related_ledger_entry_id: Some(RELATED_LEDGER_ENTRY_ID),
        amount: money(amount),
        currency: "USD".to_string(),
    }
}

fn scope() -> ConsistentLedgerScope {
    ConsistentLedgerScope {
        tenant_id: TENANT_ID,
        project_id: Some(PROJECT_ID),
        virtual_key_id: Some(VIRTUAL_KEY_ID),
    }
}

fn writer_state(wallet_balance: &str, budget_remaining: &str) -> ConsistentLedgerWriterState {
    ConsistentLedgerWriterState {
        wallet: Some(ConsistentWalletSnapshot {
            wallet_id: WALLET_ID,
            currency: "USD".to_string(),
            available_balance: money(wallet_balance),
        }),
        credit_grants: vec![ConsistentCreditGrantSnapshot {
            grant_id: Uuid::from_u128(5),
            currency: "USD".to_string(),
            remaining_amount: money("0.00000000"),
            active: true,
        }],
        budgets: vec![ConsistentBudgetSnapshot {
            budget_id: Uuid::from_u128(6),
            dimension: ConsistentBudgetDimension::Project,
            currency: "USD".to_string(),
            remaining_amount: money(budget_remaining),
            active: true,
        }],
        ledger_entries: Vec::new(),
    }
}

fn money(value: &str) -> FixedDecimal {
    FixedDecimal::parse(value, MONEY_SCALE).expect("valid money")
}

fn assert_secret_safe(label: &str, serialized: &str) {
    for forbidden in [
        "admin_adjustment:00000000",
        "idempotency_key",
        "private_operation_key",
        "dedupe",
        "payload",
        "authorization",
        "bearer",
        "credential",
        "db_url",
        "postgres://",
        "raw executor",
        "sk-live",
    ] {
        assert!(
            !serialized.to_ascii_lowercase().contains(forbidden),
            "{label} contains forbidden term `{forbidden}`"
        );
    }
}
