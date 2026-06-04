use ai_gateway_billing_ledger::{
    AdminAdjustmentLedgerRequest, CONSISTENT_LEDGER_POSTGRES_EXECUTOR_SCHEMA,
    CONSISTENT_LEDGER_POSTGRES_EXECUTOR_SUMMARY_SCHEMA, ConsistentLedgerPostgresExecutorError,
    ConsistentLedgerPostgresExecutorOutcome, ConsistentLedgerPostgresExecutorResult,
    ConsistentLedgerPostgresStatementKind, ConsistentLedgerPostgresStatementOutcome,
    ConsistentLedgerPostgresStatementResult, FixedDecimal, LedgerAdminAdjustmentKind,
    LedgerEntryRecord, LedgerEntryStatus, LedgerEntryType, LedgerOperationKind,
    LedgerOperationOutcome, admin_adjustment_ledger_idempotency_key, plan_ledger_admin_adjustment,
    summarize_consistent_ledger_postgres_executor_result,
};
use uuid::Uuid;

const MONEY_SCALE: u32 = 8;
const REQUEST_ID: Uuid = Uuid::from_u128(11);
const ADJUSTMENT_OPERATION_ID: Uuid = Uuid::from_u128(61);
const RELATED_LEDGER_ENTRY_ID: Uuid = Uuid::from_u128(31);

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
