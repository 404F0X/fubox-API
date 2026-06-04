use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[cfg(feature = "postgres-sqlx")]
use std::fmt;

#[cfg(feature = "postgres-sqlx")]
use sqlx::Row;

use crate::{
    ConsistentLedgerBoundedCommand, ConsistentLedgerBoundedCommandKind,
    ConsistentLedgerCommandPlan, ConsistentLedgerScope, ConsistentLedgerWriterPlan, FixedDecimal,
    LedgerEntryMetadata, LedgerEntryStatus, LedgerEntryType, LedgerOperationKind,
    LedgerOperationOutcome,
};

pub const CONSISTENT_LEDGER_POSTGRES_EXECUTION_SCHEMA: &str =
    "billing_ledger_postgres_execution_plan.v1";
pub const CONSISTENT_LEDGER_POSTGRES_EXECUTOR_SCHEMA: &str = "billing_ledger_postgres_executor.v1";
pub const CONSISTENT_LEDGER_POSTGRES_EXECUTOR_SUMMARY_SCHEMA: &str =
    "billing_ledger_postgres_executor_summary.v1";
pub const CONSISTENT_LEDGER_POSTGRES_SQLX_ADAPTER_SCHEMA: &str =
    "billing_ledger_postgres_sqlx_adapter_contract.v1";

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ConsistentLedgerPostgresExecutionPlan {
    pub schema_version: &'static str,
    pub executor_boundary: ConsistentLedgerPostgresBoundaryContract,
    pub operation: LedgerOperationKind,
    pub outcome: LedgerOperationOutcome,
    pub scope: ConsistentLedgerScope,
    pub operation_key_output: &'static str,
    pub transaction_steps: Vec<ConsistentLedgerPostgresTransactionStep>,
    pub sql_statements: Vec<ConsistentLedgerPostgresStatement>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ConsistentLedgerPostgresExecutorResult {
    pub schema_version: &'static str,
    pub executor: &'static str,
    pub operation: LedgerOperationKind,
    pub outcome: ConsistentLedgerPostgresExecutorOutcome,
    pub operation_key_output: &'static str,
    pub committed: bool,
    pub rolled_back: bool,
    pub statement_results: Vec<ConsistentLedgerPostgresStatementResult>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ConsistentLedgerPostgresExecutorError>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ConsistentLedgerPostgresExecutorResultSummary {
    pub schema_version: &'static str,
    pub executor: &'static str,
    pub operation: LedgerOperationKind,
    pub outcome: ConsistentLedgerPostgresExecutorOutcome,
    pub operation_key_output: &'static str,
    pub committed: bool,
    pub rolled_back: bool,
    pub statement_count: usize,
    pub executed_statement_count: usize,
    pub refused_statement_count: usize,
    pub total_rows_affected: u64,
    pub final_statement_order: Option<u16>,
    pub final_statement_kind: Option<ConsistentLedgerPostgresStatementKind>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_category: Option<String>,
    pub error_detail_output: &'static str,
    pub row_count_mismatch: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ConsistentLedgerPostgresSqlxAdapterContract {
    pub schema_version: &'static str,
    pub adapter_name: &'static str,
    pub dependency_strategy: &'static str,
    pub sqlx_dependency_declared: bool,
    pub future_feature_gate: &'static str,
    pub db_io_implemented: bool,
    pub transaction_lifecycle: Vec<ConsistentLedgerPostgresSqlxTransactionStep>,
    pub row_count_enforcement: &'static str,
    pub operation_key_bind_contract: &'static str,
    pub db_error_mapping_contract: &'static str,
    pub statements: Vec<ConsistentLedgerPostgresSqlxStatementContract>,
    pub safe_output_contract: Vec<&'static str>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ConsistentLedgerPostgresSqlxTransactionStep {
    pub order: u8,
    pub method: &'static str,
    pub contract: &'static str,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ConsistentLedgerPostgresSqlxStatementContract {
    pub order: u16,
    pub kind: ConsistentLedgerPostgresStatementKind,
    pub target: &'static str,
    pub row_count_expectation: ConsistentLedgerPostgresRowCountExpectation,
    pub bounded_by: Vec<&'static str>,
    pub bind_markers: Vec<ConsistentLedgerPostgresSqlxBindMarker>,
    pub operation_key_output: &'static str,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConsistentLedgerPostgresSqlxBindMarker {
    TenantId,
    ProjectId,
    VirtualKeyId,
    WalletId,
    Currency,
    Now,
    RequestId,
    SourceLedgerEntryId,
    RelatedLedgerEntryId,
    LedgerEntryId,
    BudgetId,
    RequiredDebit,
    AvailableBeforeWrite,
    EntryType,
    Amount,
    Status,
    FromStatus,
    ToStatus,
    Metadata,
    OperationKeyBind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConsistentLedgerPostgresDbErrorInput {
    pub kind: ConsistentLedgerPostgresDbErrorKind,
    pub statement_kind: Option<ConsistentLedgerPostgresStatementKind>,
    pub private_detail: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConsistentLedgerPostgresDbErrorKind {
    UniqueViolation,
    ForeignKeyViolation,
    CheckViolation,
    NotNullViolation,
    SerializationFailure,
    DeadlockDetected,
    Timeout,
    Connection,
    Unknown,
}

#[cfg(feature = "postgres-sqlx")]
#[derive(Clone, PartialEq)]
pub struct ConsistentLedgerPostgresSqlxExecutableStatement<'a> {
    pub order: u16,
    pub kind: ConsistentLedgerPostgresStatementKind,
    pub sql: &'a str,
    pub bind_markers: Vec<ConsistentLedgerPostgresSqlxBindMarker>,
    pub returning_columns: Vec<&'static str>,
    pub binds: Vec<ConsistentLedgerPostgresSqlxBindValue>,
}

#[cfg(feature = "postgres-sqlx")]
impl fmt::Debug for ConsistentLedgerPostgresSqlxExecutableStatement<'_> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let bind_markers = self
            .bind_markers
            .iter()
            .map(|marker| sqlx_bind_marker_name(*marker))
            .collect::<Vec<_>>();
        formatter
            .debug_struct("ConsistentLedgerPostgresSqlxExecutableStatement")
            .field("order", &self.order)
            .field("kind", &self.kind)
            .field("sql", &"<concrete_sql_omitted>")
            .field("bind_markers", &bind_markers)
            .field("returning_columns", &self.returning_columns)
            .field("binds", &self.binds)
            .finish()
    }
}

#[cfg(feature = "postgres-sqlx")]
#[derive(Clone, PartialEq)]
pub enum ConsistentLedgerPostgresSqlxBindValue {
    Uuid(Uuid),
    OptionalUuid(Option<Uuid>),
    Text(String),
    OptionalText(Option<String>),
    DecimalText(String),
    I64(i64),
    Bool(bool),
    Json(serde_json::Value),
    OperationKey(String),
}

#[cfg(feature = "postgres-sqlx")]
impl fmt::Debug for ConsistentLedgerPostgresSqlxBindValue {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Uuid(value) => formatter.debug_tuple("Uuid").field(value).finish(),
            Self::OptionalUuid(value) => {
                formatter.debug_tuple("OptionalUuid").field(value).finish()
            }
            Self::Text(_) => formatter.write_str("Text(<omitted>)"),
            Self::OptionalText(Some(_)) => formatter.write_str("OptionalText(Some(<omitted>))"),
            Self::OptionalText(None) => formatter.write_str("OptionalText(None)"),
            Self::DecimalText(_) => formatter.write_str("DecimalText(<omitted>)"),
            Self::I64(value) => formatter.debug_tuple("I64").field(value).finish(),
            Self::Bool(value) => formatter.debug_tuple("Bool").field(value).finish(),
            Self::Json(_) => formatter.write_str("Json(<omitted>)"),
            Self::OperationKey(_) => formatter.write_str("OperationKey(<bind_marker_only>)"),
        }
    }
}

#[cfg(feature = "postgres-sqlx")]
fn sqlx_bind_marker_name(marker: ConsistentLedgerPostgresSqlxBindMarker) -> &'static str {
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConsistentLedgerPostgresExecutorOutcome {
    Applied,
    Idempotent,
    RolledBack,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ConsistentLedgerPostgresStatementResult {
    pub order: u16,
    pub kind: ConsistentLedgerPostgresStatementKind,
    pub target: &'static str,
    pub outcome: ConsistentLedgerPostgresStatementOutcome,
    pub rows_affected: u64,
    pub operation_key_output: &'static str,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConsistentLedgerPostgresRowCountExpectation {
    ExactlyOne,
    ZeroOrMore,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConsistentLedgerPostgresStatementOutcome {
    Executed,
    Refused,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ConsistentLedgerPostgresExecutorError {
    pub code: String,
    pub category: String,
    pub detail_output: &'static str,
}

impl ConsistentLedgerPostgresExecutorError {
    pub fn statement_refused(code: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            category: "statement_refusal".to_string(),
            detail_output: "omitted",
        }
    }

    pub fn transaction_error(code: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            category: "transaction".to_string(),
            detail_output: "omitted",
        }
    }

    pub fn row_count_mismatch(code: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            category: "row_count_enforcement".to_string(),
            detail_output: "omitted",
        }
    }

    pub fn db_error(code: impl Into<String>, category: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            category: category.into(),
            detail_output: "omitted",
        }
    }
}

pub trait ConsistentLedgerPostgresTransactionExecutor {
    fn begin_transaction(&mut self) -> Result<(), ConsistentLedgerPostgresExecutorError>;

    fn execute_statement(
        &mut self,
        statement: &ConsistentLedgerPostgresStatement,
    ) -> Result<ConsistentLedgerPostgresStatementResult, ConsistentLedgerPostgresExecutorError>;

    fn commit_transaction(&mut self) -> Result<(), ConsistentLedgerPostgresExecutorError>;

    fn rollback_transaction(&mut self) -> Result<(), ConsistentLedgerPostgresExecutorError>;
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ConsistentLedgerPostgresBoundaryContract {
    pub db_io_implemented: bool,
    pub planned_executor: &'static str,
    pub future_sqlx_entrypoint: &'static str,
    pub private_operation_key_contract: &'static str,
    pub idempotent_replay_contract: &'static str,
    pub bounded_scan_policy: &'static str,
    pub safe_output_contract: Vec<&'static str>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ConsistentLedgerPostgresTransactionStep {
    pub order: u16,
    pub kind: ConsistentLedgerPostgresTransactionStepKind,
    pub description: &'static str,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConsistentLedgerPostgresTransactionStepKind {
    BeginTransaction,
    AcquireOrderedLocks,
    RecomputeLockedWindows,
    ExecuteBoundedCommands,
    CommitOrRollback,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ConsistentLedgerPostgresStatement {
    pub order: u16,
    pub kind: ConsistentLedgerPostgresStatementKind,
    pub target: &'static str,
    pub statement_shape: &'static str,
    pub lock_clause: Option<&'static str>,
    pub where_bounds: Vec<&'static str>,
    pub ordered_by: Vec<&'static str>,
    pub command_order: Option<u16>,
    pub command_kind: Option<ConsistentLedgerBoundedCommandKind>,
    pub row_count_expectation: ConsistentLedgerPostgresRowCountExpectation,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_id: Option<Uuid>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ledger_entry_id: Option<Uuid>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub related_ledger_entry_id: Option<Uuid>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub budget_id: Option<Uuid>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub entry_type: Option<LedgerEntryType>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub amount: Option<FixedDecimal>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub currency: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<LedgerEntryStatus>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata: Option<LedgerEntryMetadata>,
    pub operation_key_output: &'static str,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConsistentLedgerPostgresStatementKind {
    LockWallet,
    LockCreditGrants,
    LockBudgets,
    LockLedgerEntries,
    AssertBalanceWindow,
    AssertBudgetWindow,
    InsertLedgerEntry,
    UpdateLedgerStatus,
}

pub fn plan_consistent_ledger_postgres_execution(
    writer_plan: &ConsistentLedgerWriterPlan,
    command_plan: &ConsistentLedgerCommandPlan,
) -> ConsistentLedgerPostgresExecutionPlan {
    let mut sql_statements = ordered_lock_statements(writer_plan);
    let mut next_order = sql_statements.len() as u16 + 1;

    for command in &command_plan.commands {
        sql_statements.push(command_statement(next_order, command));
        next_order += 1;
    }

    ConsistentLedgerPostgresExecutionPlan {
        schema_version: CONSISTENT_LEDGER_POSTGRES_EXECUTION_SCHEMA,
        executor_boundary: postgres_boundary_contract(),
        operation: writer_plan.operation,
        outcome: writer_plan.outcome.clone(),
        scope: writer_plan.scope,
        operation_key_output: "omitted",
        transaction_steps: transaction_steps(command_plan.commands.is_empty()),
        sql_statements,
    }
}

pub fn execute_consistent_ledger_postgres_plan<E>(
    executor: &mut E,
    plan: &ConsistentLedgerPostgresExecutionPlan,
) -> ConsistentLedgerPostgresExecutorResult
where
    E: ConsistentLedgerPostgresTransactionExecutor,
{
    if let Err(error) = executor.begin_transaction() {
        return executor_result(
            plan,
            ConsistentLedgerPostgresExecutorOutcome::RolledBack,
            false,
            false,
            Vec::new(),
            Some(error),
        );
    }

    let mut statement_results = Vec::new();
    for statement in &plan.sql_statements {
        match executor.execute_statement(statement) {
            Ok(result) => {
                let mut result = sanitized_statement_result(statement, result);
                if result.outcome == ConsistentLedgerPostgresStatementOutcome::Refused {
                    statement_results.push(result);
                    let rolled_back = executor.rollback_transaction().is_ok();
                    return executor_result(
                        plan,
                        ConsistentLedgerPostgresExecutorOutcome::RolledBack,
                        false,
                        rolled_back,
                        statement_results,
                        Some(ConsistentLedgerPostgresExecutorError::statement_refused(
                            "statement_refused",
                        )),
                    );
                }
                if let Some(error) = enforce_statement_row_count(statement, result.rows_affected) {
                    result.outcome = ConsistentLedgerPostgresStatementOutcome::Refused;
                    statement_results.push(result);
                    let rolled_back = executor.rollback_transaction().is_ok();
                    return executor_result(
                        plan,
                        ConsistentLedgerPostgresExecutorOutcome::RolledBack,
                        false,
                        rolled_back,
                        statement_results,
                        Some(error),
                    );
                }
                statement_results.push(result);
            }
            Err(error) => {
                statement_results.push(refused_statement_result(statement));
                let rolled_back = executor.rollback_transaction().is_ok();
                return executor_result(
                    plan,
                    ConsistentLedgerPostgresExecutorOutcome::RolledBack,
                    false,
                    rolled_back,
                    statement_results,
                    Some(error),
                );
            }
        }
    }

    if let Err(error) = executor.commit_transaction() {
        let rolled_back = executor.rollback_transaction().is_ok();
        return executor_result(
            plan,
            ConsistentLedgerPostgresExecutorOutcome::RolledBack,
            false,
            rolled_back,
            statement_results,
            Some(error),
        );
    }

    let outcome = if matches!(plan.outcome, LedgerOperationOutcome::Idempotent { .. }) {
        ConsistentLedgerPostgresExecutorOutcome::Idempotent
    } else {
        ConsistentLedgerPostgresExecutorOutcome::Applied
    };
    executor_result(plan, outcome, true, false, statement_results, None)
}

pub fn summarize_consistent_ledger_postgres_executor_result(
    result: &ConsistentLedgerPostgresExecutorResult,
) -> ConsistentLedgerPostgresExecutorResultSummary {
    let executed_statement_count = result
        .statement_results
        .iter()
        .filter(|statement| statement.outcome == ConsistentLedgerPostgresStatementOutcome::Executed)
        .count();
    let refused_statement_count = result
        .statement_results
        .iter()
        .filter(|statement| statement.outcome == ConsistentLedgerPostgresStatementOutcome::Refused)
        .count();
    let total_rows_affected = result
        .statement_results
        .iter()
        .map(|statement| statement.rows_affected)
        .sum();
    let final_statement = result.statement_results.last();
    let error_code = result.error.as_ref().map(|error| error.code.clone());
    let error_category = result.error.as_ref().map(|error| error.category.clone());
    let error_detail_output = result
        .error
        .as_ref()
        .map(|error| error.detail_output)
        .unwrap_or("omitted");
    let row_count_mismatch = result
        .error
        .as_ref()
        .is_some_and(|error| error.category == "row_count_enforcement");

    ConsistentLedgerPostgresExecutorResultSummary {
        schema_version: CONSISTENT_LEDGER_POSTGRES_EXECUTOR_SUMMARY_SCHEMA,
        executor: result.executor,
        operation: result.operation,
        outcome: result.outcome,
        operation_key_output: "omitted",
        committed: result.committed,
        rolled_back: result.rolled_back,
        statement_count: result.statement_results.len(),
        executed_statement_count,
        refused_statement_count,
        total_rows_affected,
        final_statement_order: final_statement.map(|statement| statement.order),
        final_statement_kind: final_statement.map(|statement| statement.kind),
        error_code,
        error_category,
        error_detail_output,
        row_count_mismatch,
    }
}

pub fn plan_consistent_ledger_postgres_sqlx_adapter_contract(
    plan: &ConsistentLedgerPostgresExecutionPlan,
) -> ConsistentLedgerPostgresSqlxAdapterContract {
    ConsistentLedgerPostgresSqlxAdapterContract {
        schema_version: CONSISTENT_LEDGER_POSTGRES_SQLX_ADAPTER_SCHEMA,
        adapter_name: "SqlxConsistentLedgerPostgresTransactionExecutor",
        dependency_strategy: "optional_workspace_sqlx_dependency_feature_gated",
        sqlx_dependency_declared: true,
        future_feature_gate: "postgres-sqlx",
        db_io_implemented: cfg!(feature = "postgres-sqlx"),
        transaction_lifecycle: vec![
            ConsistentLedgerPostgresSqlxTransactionStep {
                order: 1,
                method: "begin_transaction",
                contract: "begin one postgres transaction before executing any statement",
            },
            ConsistentLedgerPostgresSqlxTransactionStep {
                order: 2,
                method: "execute_statement",
                contract: "bind statement parameters only; operation key value is never logged or serialized",
            },
            ConsistentLedgerPostgresSqlxTransactionStep {
                order: 3,
                method: "commit_transaction",
                contract: "commit only after outer executor row-count enforcement accepts all statement results",
            },
            ConsistentLedgerPostgresSqlxTransactionStep {
                order: 4,
                method: "rollback_transaction",
                contract: "rollback on DB error, statement refusal, or outer row-count enforcement failure",
            },
        ],
        row_count_enforcement: "outer execute_consistent_ledger_postgres_plan validates row_count_expectation after adapter returns rows_affected",
        operation_key_bind_contract: "adapter receives operation key only as a private bind value; public contract exposes only operation_key_bind marker",
        db_error_mapping_contract: "adapter maps postgres/sqlx errors to stable code/category and omits DB messages, private bind values, DSNs, request material, and credentials",
        statements: plan
            .sql_statements
            .iter()
            .map(sqlx_statement_contract)
            .collect(),
        safe_output_contract: vec![
            "operation_key_bind_marker_only",
            "operation_key_value_omitted",
            "auth_header_omitted",
            "provider_credential_omitted",
            "wallet_credential_omitted",
            "db_url_omitted",
            "request_material_omitted",
        ],
    }
}

pub fn map_consistent_ledger_postgres_db_error(
    error: ConsistentLedgerPostgresDbErrorInput,
) -> ConsistentLedgerPostgresExecutorError {
    match error.kind {
        ConsistentLedgerPostgresDbErrorKind::UniqueViolation => {
            ConsistentLedgerPostgresExecutorError::db_error(
                "db_unique_constraint_violation",
                "db_constraint",
            )
        }
        ConsistentLedgerPostgresDbErrorKind::ForeignKeyViolation => {
            ConsistentLedgerPostgresExecutorError::db_error(
                "db_foreign_key_violation",
                "db_constraint",
            )
        }
        ConsistentLedgerPostgresDbErrorKind::CheckViolation => {
            ConsistentLedgerPostgresExecutorError::db_error(
                "db_check_constraint_violation",
                "db_constraint",
            )
        }
        ConsistentLedgerPostgresDbErrorKind::NotNullViolation => {
            ConsistentLedgerPostgresExecutorError::db_error(
                "db_not_null_violation",
                "db_constraint",
            )
        }
        ConsistentLedgerPostgresDbErrorKind::SerializationFailure => {
            ConsistentLedgerPostgresExecutorError::db_error(
                "db_serialization_failure",
                "db_transaction",
            )
        }
        ConsistentLedgerPostgresDbErrorKind::DeadlockDetected => {
            ConsistentLedgerPostgresExecutorError::db_error(
                "db_deadlock_detected",
                "db_transaction",
            )
        }
        ConsistentLedgerPostgresDbErrorKind::Timeout => {
            ConsistentLedgerPostgresExecutorError::db_error("db_timeout", "db_transaction")
        }
        ConsistentLedgerPostgresDbErrorKind::Connection => {
            ConsistentLedgerPostgresExecutorError::db_error("db_connection_error", "db_connection")
        }
        ConsistentLedgerPostgresDbErrorKind::Unknown => {
            ConsistentLedgerPostgresExecutorError::db_error("db_error", "db_unknown")
        }
    }
}

#[cfg(feature = "postgres-sqlx")]
pub fn map_consistent_ledger_postgres_sqlx_error(
    error: &sqlx::Error,
    statement_kind: Option<ConsistentLedgerPostgresStatementKind>,
) -> ConsistentLedgerPostgresExecutorError {
    let kind = match error {
        sqlx::Error::Database(error) => postgres_sqlx_database_error_kind(error.as_ref()),
        sqlx::Error::PoolTimedOut => ConsistentLedgerPostgresDbErrorKind::Timeout,
        sqlx::Error::PoolClosed | sqlx::Error::Io(_) | sqlx::Error::Tls(_) => {
            ConsistentLedgerPostgresDbErrorKind::Connection
        }
        _ => ConsistentLedgerPostgresDbErrorKind::Unknown,
    };

    map_consistent_ledger_postgres_db_error(ConsistentLedgerPostgresDbErrorInput {
        kind,
        statement_kind,
        private_detail: None,
    })
}

#[cfg(feature = "postgres-sqlx")]
pub fn plan_consistent_ledger_postgres_sqlx_executable_statements(
    writer_plan: &ConsistentLedgerWriterPlan,
    plan: &ConsistentLedgerPostgresExecutionPlan,
) -> Result<
    Vec<ConsistentLedgerPostgresSqlxExecutableStatement<'static>>,
    ConsistentLedgerPostgresExecutorError,
> {
    if writer_plan.operation != plan.operation || writer_plan.scope != plan.scope {
        return Err(ConsistentLedgerPostgresExecutorError::statement_refused(
            "sqlx_plan_context_mismatch",
        ));
    }
    if writer_plan.idempotency_key.trim().is_empty() {
        return Err(ConsistentLedgerPostgresExecutorError::statement_refused(
            "sqlx_operation_key_missing",
        ));
    }

    plan.sql_statements
        .iter()
        .map(|statement| sqlx_executable_statement(writer_plan, statement))
        .collect()
}

#[cfg(feature = "postgres-sqlx")]
pub async fn execute_consistent_ledger_postgres_sqlx_plan(
    pool: &sqlx::PgPool,
    plan: &ConsistentLedgerPostgresExecutionPlan,
    executable_statements: &[ConsistentLedgerPostgresSqlxExecutableStatement<'_>],
) -> ConsistentLedgerPostgresExecutorResult {
    if let Some(error) = validate_sqlx_executable_statement_set(plan, executable_statements) {
        return executor_result(
            plan,
            ConsistentLedgerPostgresExecutorOutcome::RolledBack,
            false,
            false,
            Vec::new(),
            Some(error),
        );
    }

    let mut transaction = match pool.begin().await {
        Ok(transaction) => transaction,
        Err(error) => {
            return executor_result(
                plan,
                ConsistentLedgerPostgresExecutorOutcome::RolledBack,
                false,
                false,
                Vec::new(),
                Some(map_consistent_ledger_postgres_sqlx_error(&error, None)),
            );
        }
    };

    let mut statement_results = Vec::new();
    for statement in &plan.sql_statements {
        let executable = executable_statements
            .iter()
            .find(|executable| executable.order == statement.order)
            .expect("executable statement set was validated");

        match execute_sqlx_executable_statement(&mut transaction, statement, executable).await {
            Ok(result) => {
                let mut result = sanitized_statement_result(statement, result);
                if let Some(error) = enforce_statement_row_count(statement, result.rows_affected) {
                    result.outcome = ConsistentLedgerPostgresStatementOutcome::Refused;
                    statement_results.push(result);
                    let rolled_back = transaction.rollback().await.is_ok();
                    return executor_result(
                        plan,
                        ConsistentLedgerPostgresExecutorOutcome::RolledBack,
                        false,
                        rolled_back,
                        statement_results,
                        Some(error),
                    );
                }
                statement_results.push(result);
            }
            Err(error) => {
                statement_results.push(refused_statement_result(statement));
                let rolled_back = transaction.rollback().await.is_ok();
                return executor_result(
                    plan,
                    ConsistentLedgerPostgresExecutorOutcome::RolledBack,
                    false,
                    rolled_back,
                    statement_results,
                    Some(error),
                );
            }
        }
    }

    if let Err(error) = transaction.commit().await {
        return executor_result(
            plan,
            ConsistentLedgerPostgresExecutorOutcome::RolledBack,
            false,
            false,
            statement_results,
            Some(map_consistent_ledger_postgres_sqlx_error(&error, None)),
        );
    }

    let outcome = if matches!(plan.outcome, LedgerOperationOutcome::Idempotent { .. }) {
        ConsistentLedgerPostgresExecutorOutcome::Idempotent
    } else {
        ConsistentLedgerPostgresExecutorOutcome::Applied
    };
    executor_result(plan, outcome, true, false, statement_results, None)
}

#[cfg(feature = "postgres-sqlx")]
pub async fn execute_consistent_ledger_postgres_sqlx_writer_plan(
    pool: &sqlx::PgPool,
    writer_plan: &ConsistentLedgerWriterPlan,
    plan: &ConsistentLedgerPostgresExecutionPlan,
) -> ConsistentLedgerPostgresExecutorResult {
    let executable_statements =
        match plan_consistent_ledger_postgres_sqlx_executable_statements(writer_plan, plan) {
            Ok(executable_statements) => executable_statements,
            Err(error) => {
                return executor_result(
                    plan,
                    ConsistentLedgerPostgresExecutorOutcome::RolledBack,
                    false,
                    false,
                    Vec::new(),
                    Some(error),
                );
            }
        };

    execute_consistent_ledger_postgres_sqlx_plan(pool, plan, &executable_statements).await
}

#[cfg(feature = "postgres-sqlx")]
fn validate_sqlx_executable_statement_set(
    plan: &ConsistentLedgerPostgresExecutionPlan,
    executable_statements: &[ConsistentLedgerPostgresSqlxExecutableStatement<'_>],
) -> Option<ConsistentLedgerPostgresExecutorError> {
    for statement in &plan.sql_statements {
        let matches = executable_statements
            .iter()
            .filter(|executable| executable.order == statement.order)
            .collect::<Vec<_>>();
        match matches.as_slice() {
            [] => {
                return Some(ConsistentLedgerPostgresExecutorError::statement_refused(
                    "sqlx_executable_statement_missing",
                ));
            }
            [executable] if executable.kind != statement.kind => {
                return Some(ConsistentLedgerPostgresExecutorError::statement_refused(
                    "sqlx_executable_statement_kind_mismatch",
                ));
            }
            [executable]
                if executable.sql.trim().is_empty()
                    || contains_sql_template_placeholder(executable.sql) =>
            {
                return Some(ConsistentLedgerPostgresExecutorError::statement_refused(
                    "sqlx_executable_statement_not_concrete",
                ));
            }
            [executable]
                if executable.bind_markers != sqlx_bind_markers_for_statement(statement.kind) =>
            {
                return Some(ConsistentLedgerPostgresExecutorError::statement_refused(
                    "sqlx_executable_bind_marker_mismatch",
                ));
            }
            [executable]
                if executable.returning_columns
                    != sqlx_returning_columns_for_statement(statement.kind) =>
            {
                return Some(ConsistentLedgerPostgresExecutorError::statement_refused(
                    "sqlx_executable_returning_schema_mismatch",
                ));
            }
            [executable] if executable.binds.len() != executable.bind_markers.len() => {
                return Some(ConsistentLedgerPostgresExecutorError::statement_refused(
                    "sqlx_executable_bind_count_mismatch",
                ));
            }
            [executable]
                if sqlx_bind_markers_for_statement(statement.kind)
                    .contains(&ConsistentLedgerPostgresSqlxBindMarker::OperationKeyBind)
                    && !executable
                        .bind_markers
                        .contains(&ConsistentLedgerPostgresSqlxBindMarker::OperationKeyBind) =>
            {
                return Some(ConsistentLedgerPostgresExecutorError::statement_refused(
                    "sqlx_operation_key_bind_marker_missing",
                ));
            }
            [_] => {}
            _ => {
                return Some(ConsistentLedgerPostgresExecutorError::statement_refused(
                    "sqlx_executable_statement_duplicate",
                ));
            }
        }
    }

    if executable_statements.iter().any(|executable| {
        !plan
            .sql_statements
            .iter()
            .any(|statement| statement.order == executable.order)
    }) {
        return Some(ConsistentLedgerPostgresExecutorError::statement_refused(
            "sqlx_executable_statement_unplanned",
        ));
    }

    None
}

#[cfg(feature = "postgres-sqlx")]
fn sqlx_executable_statement(
    writer_plan: &ConsistentLedgerWriterPlan,
    statement: &ConsistentLedgerPostgresStatement,
) -> Result<
    ConsistentLedgerPostgresSqlxExecutableStatement<'static>,
    ConsistentLedgerPostgresExecutorError,
> {
    let bind_markers = sqlx_bind_markers_for_statement(statement.kind);
    let binds = bind_markers
        .iter()
        .map(|marker| sqlx_bind_value(writer_plan, statement, *marker))
        .collect::<Result<Vec<_>, _>>()?;

    Ok(ConsistentLedgerPostgresSqlxExecutableStatement {
        order: statement.order,
        kind: statement.kind,
        sql: sqlx_statement_sql(statement.kind),
        bind_markers,
        returning_columns: sqlx_returning_columns_for_statement(statement.kind),
        binds,
    })
}

#[cfg(feature = "postgres-sqlx")]
fn contains_sql_template_placeholder(sql: &str) -> bool {
    sql.contains("<private")
        || sql.contains("$tenant_id")
        || sql.contains("$project_id")
        || sql.contains("$virtual_key_id")
        || sql.contains("$wallet_id")
        || sql.contains("$request_id")
        || sql.contains("$private_operation_key")
        || sql.contains("$operation_key")
}

#[cfg(feature = "postgres-sqlx")]
fn sqlx_bind_value(
    writer_plan: &ConsistentLedgerWriterPlan,
    statement: &ConsistentLedgerPostgresStatement,
    marker: ConsistentLedgerPostgresSqlxBindMarker,
) -> Result<ConsistentLedgerPostgresSqlxBindValue, ConsistentLedgerPostgresExecutorError> {
    match marker {
        ConsistentLedgerPostgresSqlxBindMarker::TenantId => Ok(
            ConsistentLedgerPostgresSqlxBindValue::Uuid(writer_plan.scope.tenant_id),
        ),
        ConsistentLedgerPostgresSqlxBindMarker::ProjectId => Ok(
            ConsistentLedgerPostgresSqlxBindValue::OptionalUuid(writer_plan.scope.project_id),
        ),
        ConsistentLedgerPostgresSqlxBindMarker::VirtualKeyId => Ok(
            ConsistentLedgerPostgresSqlxBindValue::OptionalUuid(writer_plan.scope.virtual_key_id),
        ),
        ConsistentLedgerPostgresSqlxBindMarker::WalletId => Ok(
            ConsistentLedgerPostgresSqlxBindValue::Uuid(writer_plan.wallet_check.wallet_id),
        ),
        ConsistentLedgerPostgresSqlxBindMarker::Currency => {
            Ok(ConsistentLedgerPostgresSqlxBindValue::Text(
                statement
                    .currency
                    .clone()
                    .unwrap_or_else(|| writer_plan.balance_window.currency.clone()),
            ))
        }
        ConsistentLedgerPostgresSqlxBindMarker::Now => Ok(
            ConsistentLedgerPostgresSqlxBindValue::Text("now".to_string()),
        ),
        ConsistentLedgerPostgresSqlxBindMarker::RequestId => {
            Ok(ConsistentLedgerPostgresSqlxBindValue::OptionalUuid(
                statement
                    .request_id
                    .or_else(|| first_ledger_entry_request_id(writer_plan)),
            ))
        }
        ConsistentLedgerPostgresSqlxBindMarker::SourceLedgerEntryId => {
            Ok(ConsistentLedgerPostgresSqlxBindValue::OptionalUuid(
                source_ledger_entry_id(writer_plan, statement),
            ))
        }
        ConsistentLedgerPostgresSqlxBindMarker::RelatedLedgerEntryId => {
            Ok(ConsistentLedgerPostgresSqlxBindValue::OptionalUuid(
                statement
                    .related_ledger_entry_id
                    .or_else(|| source_ledger_entry_id(writer_plan, statement)),
            ))
        }
        ConsistentLedgerPostgresSqlxBindMarker::LedgerEntryId => {
            required_uuid(statement.ledger_entry_id, "sqlx_ledger_entry_id_missing")
                .map(ConsistentLedgerPostgresSqlxBindValue::Uuid)
        }
        ConsistentLedgerPostgresSqlxBindMarker::BudgetId => {
            required_uuid(statement.budget_id, "sqlx_budget_id_missing")
                .map(ConsistentLedgerPostgresSqlxBindValue::Uuid)
        }
        ConsistentLedgerPostgresSqlxBindMarker::RequiredDebit => {
            Ok(ConsistentLedgerPostgresSqlxBindValue::DecimalText(
                statement
                    .amount
                    .unwrap_or(writer_plan.balance_window.required_debit)
                    .to_string(),
            ))
        }
        ConsistentLedgerPostgresSqlxBindMarker::AvailableBeforeWrite => {
            Ok(ConsistentLedgerPostgresSqlxBindValue::DecimalText(
                writer_plan
                    .balance_window
                    .available_before_write
                    .to_string(),
            ))
        }
        ConsistentLedgerPostgresSqlxBindMarker::EntryType => {
            let entry_type = statement.entry_type.ok_or_else(|| {
                ConsistentLedgerPostgresExecutorError::statement_refused("sqlx_entry_type_missing")
            })?;
            Ok(ConsistentLedgerPostgresSqlxBindValue::Text(
                ledger_entry_type_sql(entry_type).to_string(),
            ))
        }
        ConsistentLedgerPostgresSqlxBindMarker::Amount => {
            let amount = statement.amount.ok_or_else(|| {
                ConsistentLedgerPostgresExecutorError::statement_refused("sqlx_amount_missing")
            })?;
            Ok(ConsistentLedgerPostgresSqlxBindValue::DecimalText(
                amount.to_string(),
            ))
        }
        ConsistentLedgerPostgresSqlxBindMarker::Status => {
            let status = statement.status.ok_or_else(|| {
                ConsistentLedgerPostgresExecutorError::statement_refused("sqlx_status_missing")
            })?;
            Ok(ConsistentLedgerPostgresSqlxBindValue::Text(
                ledger_entry_status_sql(status).to_string(),
            ))
        }
        ConsistentLedgerPostgresSqlxBindMarker::FromStatus => {
            Ok(ConsistentLedgerPostgresSqlxBindValue::Text(
                ledger_entry_status_sql(LedgerEntryStatus::Pending).to_string(),
            ))
        }
        ConsistentLedgerPostgresSqlxBindMarker::ToStatus => {
            let status = statement.status.ok_or_else(|| {
                ConsistentLedgerPostgresExecutorError::statement_refused("sqlx_to_status_missing")
            })?;
            Ok(ConsistentLedgerPostgresSqlxBindValue::Text(
                ledger_entry_status_sql(status).to_string(),
            ))
        }
        ConsistentLedgerPostgresSqlxBindMarker::Metadata => {
            let metadata = statement.metadata.as_ref().ok_or_else(|| {
                ConsistentLedgerPostgresExecutorError::statement_refused("sqlx_metadata_missing")
            })?;
            let value = serde_json::to_value(metadata).map_err(|_| {
                ConsistentLedgerPostgresExecutorError::statement_refused(
                    "sqlx_metadata_serialization_failed",
                )
            })?;
            Ok(ConsistentLedgerPostgresSqlxBindValue::Json(value))
        }
        ConsistentLedgerPostgresSqlxBindMarker::OperationKeyBind => {
            Ok(ConsistentLedgerPostgresSqlxBindValue::OperationKey(
                writer_plan.idempotency_key.clone(),
            ))
        }
    }
}

#[cfg(feature = "postgres-sqlx")]
fn required_uuid(
    value: Option<Uuid>,
    code: &'static str,
) -> Result<Uuid, ConsistentLedgerPostgresExecutorError> {
    value.ok_or_else(|| ConsistentLedgerPostgresExecutorError::statement_refused(code))
}

#[cfg(feature = "postgres-sqlx")]
fn first_ledger_entry_request_id(writer_plan: &ConsistentLedgerWriterPlan) -> Option<Uuid> {
    writer_plan
        .ledger_plan
        .entries
        .first()
        .and_then(|entry| entry.request_id)
}

#[cfg(feature = "postgres-sqlx")]
fn source_ledger_entry_id(
    writer_plan: &ConsistentLedgerWriterPlan,
    statement: &ConsistentLedgerPostgresStatement,
) -> Option<Uuid> {
    statement.related_ledger_entry_id.or_else(|| {
        writer_plan
            .ledger_plan
            .entries
            .first()
            .and_then(|entry| entry.related_ledger_entry_id)
    })
}

#[cfg(feature = "postgres-sqlx")]
const fn ledger_entry_type_sql(entry_type: LedgerEntryType) -> &'static str {
    match entry_type {
        LedgerEntryType::Reserve => "reserve",
        LedgerEntryType::Settle => "settle",
        LedgerEntryType::Refund => "refund",
    }
}

#[cfg(feature = "postgres-sqlx")]
const fn ledger_entry_status_sql(status: LedgerEntryStatus) -> &'static str {
    match status {
        LedgerEntryStatus::Pending => "pending",
        LedgerEntryStatus::Confirmed => "confirmed",
        LedgerEntryStatus::Reversed => "reversed",
    }
}

#[cfg(feature = "postgres-sqlx")]
const fn sqlx_statement_sql(kind: ConsistentLedgerPostgresStatementKind) -> &'static str {
    match kind {
        ConsistentLedgerPostgresStatementKind::LockWallet => {
            "select id, balance_floor::text as balance_floor from wallets where tenant_id = $1 and project_id is not distinct from $2 and currency = $3 and status in ('active','suspended') for update"
        }
        ConsistentLedgerPostgresStatementKind::LockCreditGrants => {
            "select id, remaining_amount::text as remaining_amount from credit_grants where tenant_id = $1 and wallet_id = $2 and currency = $3 and status = 'active' and valid_from <= now() and (valid_until is null or valid_until > now()) order by id for update"
        }
        ConsistentLedgerPostgresStatementKind::LockBudgets => {
            "select id, scope, limit_amount::text as limit_amount from budgets where tenant_id = $1 and (scope = 'tenant' or (scope = 'project' and project_id is not distinct from $2) or (scope = 'virtual_key' and virtual_key_id is not distinct from $3)) and currency = $4 and status = 'active' and deleted_at is null order by scope, id for update"
        }
        ConsistentLedgerPostgresStatementKind::LockLedgerEntries => {
            "select id, request_id, related_ledger_entry_id, entry_type, amount::text as amount, currency, status from ledger_entries where tenant_id = $1 and (($2::uuid is not null and request_id = $2) or ($3::uuid is not null and id = $3) or ($4::uuid is not null and related_ledger_entry_id = $4) or idempotency_key = $5) order by created_at, id for update"
        }
        ConsistentLedgerPostgresStatementKind::AssertBalanceWindow => {
            "select true as passed where $1::uuid is not null and $2::text is not null and $3::numeric >= $4::numeric"
        }
        ConsistentLedgerPostgresStatementKind::AssertBudgetWindow => {
            "select true as passed from budgets where tenant_id = $1 and id = $2 and currency = $3 and limit_amount >= $4::numeric"
        }
        ConsistentLedgerPostgresStatementKind::InsertLedgerEntry => {
            "insert into ledger_entries (tenant_id, project_id, virtual_key_id, wallet_id, request_id, related_ledger_entry_id, entry_type, amount, currency, status, idempotency_key, metadata) values ($1, $2, $3, $4, $5, $6, $7, $8::numeric, $9, $10, $11, $12) on conflict (tenant_id, idempotency_key) do nothing returning id, entry_type, amount::text as amount, currency, status"
        }
        ConsistentLedgerPostgresStatementKind::UpdateLedgerStatus => {
            "update ledger_entries set status = $4 where tenant_id = $1 and id = $2 and status = $3 returning id, status"
        }
    }
}

#[cfg(feature = "postgres-sqlx")]
fn sqlx_returning_columns_for_statement(
    kind: ConsistentLedgerPostgresStatementKind,
) -> Vec<&'static str> {
    match kind {
        ConsistentLedgerPostgresStatementKind::LockWallet => vec!["id", "balance_floor"],
        ConsistentLedgerPostgresStatementKind::LockCreditGrants => {
            vec!["id", "remaining_amount"]
        }
        ConsistentLedgerPostgresStatementKind::LockBudgets => vec!["id", "scope", "limit_amount"],
        ConsistentLedgerPostgresStatementKind::LockLedgerEntries => vec![
            "id",
            "request_id",
            "related_ledger_entry_id",
            "entry_type",
            "amount",
            "currency",
            "status",
        ],
        ConsistentLedgerPostgresStatementKind::AssertBalanceWindow
        | ConsistentLedgerPostgresStatementKind::AssertBudgetWindow => vec!["passed"],
        ConsistentLedgerPostgresStatementKind::InsertLedgerEntry => {
            vec!["id", "entry_type", "amount", "currency", "status"]
        }
        ConsistentLedgerPostgresStatementKind::UpdateLedgerStatus => vec!["id", "status"],
    }
}

#[cfg(feature = "postgres-sqlx")]
async fn execute_sqlx_executable_statement(
    transaction: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    statement: &ConsistentLedgerPostgresStatement,
    executable: &ConsistentLedgerPostgresSqlxExecutableStatement<'_>,
) -> Result<ConsistentLedgerPostgresStatementResult, ConsistentLedgerPostgresExecutorError> {
    let mut query = sqlx::query(executable.sql);
    for bind in &executable.binds {
        query = bind_sqlx_value(query, bind);
    }

    let rows = query
        .fetch_all(&mut **transaction)
        .await
        .map_err(|error| map_consistent_ledger_postgres_sqlx_error(&error, Some(statement.kind)))?;
    validate_sqlx_returning_schema(statement.kind, &rows)?;

    Ok(ConsistentLedgerPostgresStatementResult {
        order: statement.order,
        kind: statement.kind,
        target: statement.target,
        outcome: ConsistentLedgerPostgresStatementOutcome::Executed,
        rows_affected: rows.len() as u64,
        operation_key_output: "omitted",
    })
}

#[cfg(feature = "postgres-sqlx")]
fn validate_sqlx_returning_schema(
    kind: ConsistentLedgerPostgresStatementKind,
    rows: &[sqlx::postgres::PgRow],
) -> Result<(), ConsistentLedgerPostgresExecutorError> {
    for row in rows {
        match kind {
            ConsistentLedgerPostgresStatementKind::LockWallet => {
                get_uuid_column(row, "id")?;
                get_text_column(row, "balance_floor")?;
            }
            ConsistentLedgerPostgresStatementKind::LockCreditGrants => {
                get_uuid_column(row, "id")?;
                get_text_column(row, "remaining_amount")?;
            }
            ConsistentLedgerPostgresStatementKind::LockBudgets => {
                get_uuid_column(row, "id")?;
                get_text_column(row, "scope")?;
                get_text_column(row, "limit_amount")?;
            }
            ConsistentLedgerPostgresStatementKind::LockLedgerEntries => {
                get_uuid_column(row, "id")?;
                get_optional_uuid_column(row, "request_id")?;
                get_optional_uuid_column(row, "related_ledger_entry_id")?;
                get_text_column(row, "entry_type")?;
                get_text_column(row, "amount")?;
                get_text_column(row, "currency")?;
                get_text_column(row, "status")?;
            }
            ConsistentLedgerPostgresStatementKind::AssertBalanceWindow
            | ConsistentLedgerPostgresStatementKind::AssertBudgetWindow => {
                get_bool_column(row, "passed")?;
            }
            ConsistentLedgerPostgresStatementKind::InsertLedgerEntry => {
                get_uuid_column(row, "id")?;
                get_text_column(row, "entry_type")?;
                get_text_column(row, "amount")?;
                get_text_column(row, "currency")?;
                get_text_column(row, "status")?;
            }
            ConsistentLedgerPostgresStatementKind::UpdateLedgerStatus => {
                get_uuid_column(row, "id")?;
                get_text_column(row, "status")?;
            }
        }
    }

    Ok(())
}

#[cfg(feature = "postgres-sqlx")]
fn get_uuid_column(
    row: &sqlx::postgres::PgRow,
    column: &'static str,
) -> Result<Uuid, ConsistentLedgerPostgresExecutorError> {
    row.try_get(column)
        .map_err(|_| sqlx_returning_schema_error(column))
}

#[cfg(feature = "postgres-sqlx")]
fn get_optional_uuid_column(
    row: &sqlx::postgres::PgRow,
    column: &'static str,
) -> Result<Option<Uuid>, ConsistentLedgerPostgresExecutorError> {
    row.try_get(column)
        .map_err(|_| sqlx_returning_schema_error(column))
}

#[cfg(feature = "postgres-sqlx")]
fn get_text_column(
    row: &sqlx::postgres::PgRow,
    column: &'static str,
) -> Result<String, ConsistentLedgerPostgresExecutorError> {
    row.try_get(column)
        .map_err(|_| sqlx_returning_schema_error(column))
}

#[cfg(feature = "postgres-sqlx")]
fn get_bool_column(
    row: &sqlx::postgres::PgRow,
    column: &'static str,
) -> Result<bool, ConsistentLedgerPostgresExecutorError> {
    row.try_get(column)
        .map_err(|_| sqlx_returning_schema_error(column))
}

#[cfg(feature = "postgres-sqlx")]
fn sqlx_returning_schema_error(column: &'static str) -> ConsistentLedgerPostgresExecutorError {
    ConsistentLedgerPostgresExecutorError::statement_refused(format!(
        "sqlx_returning_schema_mismatch_{column}"
    ))
}

#[cfg(feature = "postgres-sqlx")]
fn bind_sqlx_value<'query>(
    query: sqlx::query::Query<'query, sqlx::Postgres, sqlx::postgres::PgArguments>,
    bind: &'query ConsistentLedgerPostgresSqlxBindValue,
) -> sqlx::query::Query<'query, sqlx::Postgres, sqlx::postgres::PgArguments> {
    match bind {
        ConsistentLedgerPostgresSqlxBindValue::Uuid(value) => query.bind(*value),
        ConsistentLedgerPostgresSqlxBindValue::OptionalUuid(value) => query.bind(*value),
        ConsistentLedgerPostgresSqlxBindValue::Text(value) => query.bind(value.as_str()),
        ConsistentLedgerPostgresSqlxBindValue::OptionalText(value) => query.bind(value.as_deref()),
        ConsistentLedgerPostgresSqlxBindValue::DecimalText(value) => query.bind(value.as_str()),
        ConsistentLedgerPostgresSqlxBindValue::I64(value) => query.bind(*value),
        ConsistentLedgerPostgresSqlxBindValue::Bool(value) => query.bind(*value),
        ConsistentLedgerPostgresSqlxBindValue::Json(value) => {
            query.bind(sqlx::types::Json(value.clone()))
        }
        ConsistentLedgerPostgresSqlxBindValue::OperationKey(value) => query.bind(value.as_str()),
    }
}

#[cfg(feature = "postgres-sqlx")]
fn postgres_sqlx_database_error_kind(
    error: &(dyn sqlx::error::DatabaseError + 'static),
) -> ConsistentLedgerPostgresDbErrorKind {
    if let Some(code) = error.code() {
        match code.as_ref() {
            "23505" => return ConsistentLedgerPostgresDbErrorKind::UniqueViolation,
            "23503" => return ConsistentLedgerPostgresDbErrorKind::ForeignKeyViolation,
            "23514" => return ConsistentLedgerPostgresDbErrorKind::CheckViolation,
            "23502" => return ConsistentLedgerPostgresDbErrorKind::NotNullViolation,
            "40001" => return ConsistentLedgerPostgresDbErrorKind::SerializationFailure,
            "40P01" => return ConsistentLedgerPostgresDbErrorKind::DeadlockDetected,
            _ => {}
        }
    }

    match error.kind() {
        sqlx::error::ErrorKind::UniqueViolation => {
            ConsistentLedgerPostgresDbErrorKind::UniqueViolation
        }
        sqlx::error::ErrorKind::ForeignKeyViolation => {
            ConsistentLedgerPostgresDbErrorKind::ForeignKeyViolation
        }
        sqlx::error::ErrorKind::CheckViolation => {
            ConsistentLedgerPostgresDbErrorKind::CheckViolation
        }
        sqlx::error::ErrorKind::NotNullViolation => {
            ConsistentLedgerPostgresDbErrorKind::NotNullViolation
        }
        _ => ConsistentLedgerPostgresDbErrorKind::Unknown,
    }
}

fn sqlx_statement_contract(
    statement: &ConsistentLedgerPostgresStatement,
) -> ConsistentLedgerPostgresSqlxStatementContract {
    ConsistentLedgerPostgresSqlxStatementContract {
        order: statement.order,
        kind: statement.kind,
        target: statement.target,
        row_count_expectation: statement.row_count_expectation,
        bounded_by: statement
            .where_bounds
            .iter()
            .map(|bound| {
                if *bound == "private_operation_key" {
                    "operation_key_bind"
                } else {
                    *bound
                }
            })
            .collect(),
        bind_markers: sqlx_bind_markers_for_statement(statement.kind),
        operation_key_output: if statement
            .where_bounds
            .iter()
            .any(|bound| *bound == "private_operation_key")
        {
            "bind_marker_only"
        } else {
            "not_required"
        },
    }
}

fn sqlx_bind_markers_for_statement(
    kind: ConsistentLedgerPostgresStatementKind,
) -> Vec<ConsistentLedgerPostgresSqlxBindMarker> {
    match kind {
        ConsistentLedgerPostgresStatementKind::LockWallet => vec![
            ConsistentLedgerPostgresSqlxBindMarker::TenantId,
            ConsistentLedgerPostgresSqlxBindMarker::ProjectId,
            ConsistentLedgerPostgresSqlxBindMarker::Currency,
        ],
        ConsistentLedgerPostgresStatementKind::LockCreditGrants => vec![
            ConsistentLedgerPostgresSqlxBindMarker::TenantId,
            ConsistentLedgerPostgresSqlxBindMarker::WalletId,
            ConsistentLedgerPostgresSqlxBindMarker::Currency,
        ],
        ConsistentLedgerPostgresStatementKind::LockBudgets => vec![
            ConsistentLedgerPostgresSqlxBindMarker::TenantId,
            ConsistentLedgerPostgresSqlxBindMarker::ProjectId,
            ConsistentLedgerPostgresSqlxBindMarker::VirtualKeyId,
            ConsistentLedgerPostgresSqlxBindMarker::Currency,
        ],
        ConsistentLedgerPostgresStatementKind::LockLedgerEntries => vec![
            ConsistentLedgerPostgresSqlxBindMarker::TenantId,
            ConsistentLedgerPostgresSqlxBindMarker::RequestId,
            ConsistentLedgerPostgresSqlxBindMarker::SourceLedgerEntryId,
            ConsistentLedgerPostgresSqlxBindMarker::RelatedLedgerEntryId,
            ConsistentLedgerPostgresSqlxBindMarker::OperationKeyBind,
        ],
        ConsistentLedgerPostgresStatementKind::AssertBalanceWindow => vec![
            ConsistentLedgerPostgresSqlxBindMarker::TenantId,
            ConsistentLedgerPostgresSqlxBindMarker::Currency,
            ConsistentLedgerPostgresSqlxBindMarker::AvailableBeforeWrite,
            ConsistentLedgerPostgresSqlxBindMarker::RequiredDebit,
        ],
        ConsistentLedgerPostgresStatementKind::AssertBudgetWindow => vec![
            ConsistentLedgerPostgresSqlxBindMarker::TenantId,
            ConsistentLedgerPostgresSqlxBindMarker::BudgetId,
            ConsistentLedgerPostgresSqlxBindMarker::Currency,
            ConsistentLedgerPostgresSqlxBindMarker::RequiredDebit,
        ],
        ConsistentLedgerPostgresStatementKind::InsertLedgerEntry => vec![
            ConsistentLedgerPostgresSqlxBindMarker::TenantId,
            ConsistentLedgerPostgresSqlxBindMarker::ProjectId,
            ConsistentLedgerPostgresSqlxBindMarker::VirtualKeyId,
            ConsistentLedgerPostgresSqlxBindMarker::WalletId,
            ConsistentLedgerPostgresSqlxBindMarker::RequestId,
            ConsistentLedgerPostgresSqlxBindMarker::RelatedLedgerEntryId,
            ConsistentLedgerPostgresSqlxBindMarker::EntryType,
            ConsistentLedgerPostgresSqlxBindMarker::Amount,
            ConsistentLedgerPostgresSqlxBindMarker::Currency,
            ConsistentLedgerPostgresSqlxBindMarker::Status,
            ConsistentLedgerPostgresSqlxBindMarker::OperationKeyBind,
            ConsistentLedgerPostgresSqlxBindMarker::Metadata,
        ],
        ConsistentLedgerPostgresStatementKind::UpdateLedgerStatus => vec![
            ConsistentLedgerPostgresSqlxBindMarker::TenantId,
            ConsistentLedgerPostgresSqlxBindMarker::LedgerEntryId,
            ConsistentLedgerPostgresSqlxBindMarker::FromStatus,
            ConsistentLedgerPostgresSqlxBindMarker::ToStatus,
        ],
    }
}

fn executor_result(
    plan: &ConsistentLedgerPostgresExecutionPlan,
    outcome: ConsistentLedgerPostgresExecutorOutcome,
    committed: bool,
    rolled_back: bool,
    statement_results: Vec<ConsistentLedgerPostgresStatementResult>,
    error: Option<ConsistentLedgerPostgresExecutorError>,
) -> ConsistentLedgerPostgresExecutorResult {
    ConsistentLedgerPostgresExecutorResult {
        schema_version: CONSISTENT_LEDGER_POSTGRES_EXECUTOR_SCHEMA,
        executor: "consistent_ledger_postgres_transaction_executor",
        operation: plan.operation,
        outcome,
        operation_key_output: "omitted",
        committed,
        rolled_back,
        statement_results,
        error,
    }
}

fn sanitized_statement_result(
    statement: &ConsistentLedgerPostgresStatement,
    result: ConsistentLedgerPostgresStatementResult,
) -> ConsistentLedgerPostgresStatementResult {
    ConsistentLedgerPostgresStatementResult {
        order: statement.order,
        kind: statement.kind,
        target: statement.target,
        outcome: result.outcome,
        rows_affected: result.rows_affected,
        operation_key_output: "omitted",
    }
}

fn refused_statement_result(
    statement: &ConsistentLedgerPostgresStatement,
) -> ConsistentLedgerPostgresStatementResult {
    ConsistentLedgerPostgresStatementResult {
        order: statement.order,
        kind: statement.kind,
        target: statement.target,
        outcome: ConsistentLedgerPostgresStatementOutcome::Refused,
        rows_affected: 0,
        operation_key_output: "omitted",
    }
}

fn enforce_statement_row_count(
    statement: &ConsistentLedgerPostgresStatement,
    rows_affected: u64,
) -> Option<ConsistentLedgerPostgresExecutorError> {
    match statement.row_count_expectation {
        ConsistentLedgerPostgresRowCountExpectation::ExactlyOne if rows_affected != 1 => {
            Some(ConsistentLedgerPostgresExecutorError::row_count_mismatch(
                row_count_mismatch_code(statement.kind, rows_affected),
            ))
        }
        ConsistentLedgerPostgresRowCountExpectation::ExactlyOne
        | ConsistentLedgerPostgresRowCountExpectation::ZeroOrMore => None,
    }
}

fn row_count_mismatch_code(
    kind: ConsistentLedgerPostgresStatementKind,
    rows_affected: u64,
) -> &'static str {
    match (kind, rows_affected) {
        (ConsistentLedgerPostgresStatementKind::LockWallet, 0) => "wallet_lock_missing_row",
        (ConsistentLedgerPostgresStatementKind::LockWallet, _) => "wallet_lock_row_count_mismatch",
        (ConsistentLedgerPostgresStatementKind::AssertBalanceWindow, 0) => {
            "balance_assert_missing_row"
        }
        (ConsistentLedgerPostgresStatementKind::AssertBalanceWindow, _) => {
            "balance_assert_row_count_mismatch"
        }
        (ConsistentLedgerPostgresStatementKind::AssertBudgetWindow, 0) => {
            "budget_assert_missing_row"
        }
        (ConsistentLedgerPostgresStatementKind::AssertBudgetWindow, _) => {
            "budget_assert_row_count_mismatch"
        }
        (ConsistentLedgerPostgresStatementKind::InsertLedgerEntry, 0) => {
            "ledger_insert_conflict_no_row"
        }
        (ConsistentLedgerPostgresStatementKind::InsertLedgerEntry, _) => {
            "ledger_insert_row_count_mismatch"
        }
        (ConsistentLedgerPostgresStatementKind::UpdateLedgerStatus, 0) => {
            "ledger_update_missing_row"
        }
        (ConsistentLedgerPostgresStatementKind::UpdateLedgerStatus, _) => {
            "ledger_update_row_count_mismatch"
        }
        (ConsistentLedgerPostgresStatementKind::LockCreditGrants, _)
        | (ConsistentLedgerPostgresStatementKind::LockBudgets, _)
        | (ConsistentLedgerPostgresStatementKind::LockLedgerEntries, _) => {
            "lock_row_count_mismatch"
        }
    }
}

fn ordered_lock_statements(
    writer_plan: &ConsistentLedgerWriterPlan,
) -> Vec<ConsistentLedgerPostgresStatement> {
    vec![
        ConsistentLedgerPostgresStatement {
            order: 1,
            kind: ConsistentLedgerPostgresStatementKind::LockWallet,
            target: "wallets",
            statement_shape: "select id, balance_floor from wallets where tenant_id = $tenant_id and project_id is not distinct from $project_id and currency = $currency and status in ('active','suspended') for update",
            lock_clause: Some("for_update"),
            where_bounds: vec!["tenant_id", "project_id", "currency"],
            ordered_by: Vec::new(),
            command_order: None,
            command_kind: None,
            row_count_expectation: ConsistentLedgerPostgresRowCountExpectation::ExactlyOne,
            request_id: None,
            ledger_entry_id: None,
            related_ledger_entry_id: None,
            budget_id: None,
            entry_type: None,
            amount: None,
            currency: Some(writer_plan.balance_window.currency.clone()),
            status: None,
            metadata: None,
            operation_key_output: "omitted",
        },
        ConsistentLedgerPostgresStatement {
            order: 2,
            kind: ConsistentLedgerPostgresStatementKind::LockCreditGrants,
            target: "credit_grants",
            statement_shape: "select id, remaining_amount from credit_grants where tenant_id = $tenant_id and wallet_id = $wallet_id and currency = $currency and status = 'active' and valid_from <= now() and (valid_until is null or valid_until > now()) order by id for update",
            lock_clause: Some("for_update_ordered"),
            where_bounds: vec!["tenant_id", "wallet_id", "currency", "validity_window"],
            ordered_by: vec!["id"],
            command_order: None,
            command_kind: None,
            row_count_expectation: ConsistentLedgerPostgresRowCountExpectation::ZeroOrMore,
            request_id: None,
            ledger_entry_id: None,
            related_ledger_entry_id: None,
            budget_id: None,
            entry_type: None,
            amount: None,
            currency: Some(writer_plan.balance_window.currency.clone()),
            status: None,
            metadata: None,
            operation_key_output: "omitted",
        },
        ConsistentLedgerPostgresStatement {
            order: 3,
            kind: ConsistentLedgerPostgresStatementKind::LockBudgets,
            target: "budgets",
            statement_shape: "select id, scope, limit_amount from budgets where tenant_id = $tenant_id and currency = $currency and status = 'active' and deleted_at is null and (scope = 'tenant' or (scope = 'project' and project_id is not distinct from $project_id) or (scope = 'virtual_key' and virtual_key_id is not distinct from $virtual_key_id)) order by scope, id for update",
            lock_clause: Some("for_update_ordered"),
            where_bounds: vec!["tenant_id", "project_id", "virtual_key_id", "currency"],
            ordered_by: vec!["scope", "id"],
            command_order: None,
            command_kind: None,
            row_count_expectation: ConsistentLedgerPostgresRowCountExpectation::ZeroOrMore,
            request_id: None,
            ledger_entry_id: None,
            related_ledger_entry_id: None,
            budget_id: None,
            entry_type: None,
            amount: None,
            currency: Some(writer_plan.balance_window.currency.clone()),
            status: None,
            metadata: None,
            operation_key_output: "omitted",
        },
        ledger_lock_statement(4, writer_plan.operation),
    ]
}

fn ledger_lock_statement(
    order: u16,
    operation: LedgerOperationKind,
) -> ConsistentLedgerPostgresStatement {
    match operation {
        LedgerOperationKind::Reserve | LedgerOperationKind::Settle => {
            ConsistentLedgerPostgresStatement {
                order,
                kind: ConsistentLedgerPostgresStatementKind::LockLedgerEntries,
                target: "ledger_entries",
                statement_shape: "select id, request_id, related_ledger_entry_id, entry_type, amount, currency, status from ledger_entries where tenant_id = $tenant_id and (request_id = $request_id or <private operation key column> = $private_operation_key) order by created_at, id for update",
                lock_clause: Some("for_update_ordered"),
                where_bounds: vec!["tenant_id", "request_id", "private_operation_key"],
                ordered_by: vec!["created_at", "id"],
                command_order: None,
                command_kind: None,
                row_count_expectation: ConsistentLedgerPostgresRowCountExpectation::ZeroOrMore,
                request_id: None,
                ledger_entry_id: None,
                related_ledger_entry_id: None,
                budget_id: None,
                entry_type: None,
                amount: None,
                currency: None,
                status: None,
                metadata: None,
                operation_key_output: "omitted",
            }
        }
        LedgerOperationKind::Refund | LedgerOperationKind::RefundPartial => {
            ConsistentLedgerPostgresStatement {
                order,
                kind: ConsistentLedgerPostgresStatementKind::LockLedgerEntries,
                target: "ledger_entries",
                statement_shape: "select id, request_id, related_ledger_entry_id, entry_type, amount, currency, status from ledger_entries where tenant_id = $tenant_id and (id = $source_ledger_entry_id or related_ledger_entry_id = $source_ledger_entry_id or <private operation key column> = $private_operation_key) order by created_at, id for update",
                lock_clause: Some("for_update_ordered"),
                where_bounds: vec![
                    "tenant_id",
                    "source_ledger_entry_id",
                    "related_ledger_entry_id",
                    "private_operation_key",
                ],
                ordered_by: vec!["created_at", "id"],
                command_order: None,
                command_kind: None,
                row_count_expectation: ConsistentLedgerPostgresRowCountExpectation::ZeroOrMore,
                request_id: None,
                ledger_entry_id: None,
                related_ledger_entry_id: None,
                budget_id: None,
                entry_type: None,
                amount: None,
                currency: None,
                status: None,
                metadata: None,
                operation_key_output: "omitted",
            }
        }
    }
}

fn command_statement(
    order: u16,
    command: &ConsistentLedgerBoundedCommand,
) -> ConsistentLedgerPostgresStatement {
    match command.kind {
        ConsistentLedgerBoundedCommandKind::AssertBalanceWindow => {
            ConsistentLedgerPostgresStatement {
                order,
                kind: ConsistentLedgerPostgresStatementKind::AssertBalanceWindow,
                target: "locked_balance_window",
                statement_shape: "select ($available_before_write >= $required_debit) as passed from locked_balance_window where tenant_id = $tenant_id and currency = $currency",
                lock_clause: None,
                where_bounds: vec!["tenant_id", "currency"],
                ordered_by: Vec::new(),
                command_order: Some(command.order),
                command_kind: Some(command.kind),
                row_count_expectation: ConsistentLedgerPostgresRowCountExpectation::ExactlyOne,
                request_id: command.request_id,
                ledger_entry_id: command.ledger_entry_id,
                related_ledger_entry_id: command.related_ledger_entry_id,
                budget_id: command.budget_id,
                entry_type: command.entry_type,
                amount: command.amount,
                currency: command.currency.clone(),
                status: command.status,
                metadata: command.metadata.clone(),
                operation_key_output: "omitted",
            }
        }
        ConsistentLedgerBoundedCommandKind::AssertBudgetWindow => {
            ConsistentLedgerPostgresStatement {
                order,
                kind: ConsistentLedgerPostgresStatementKind::AssertBudgetWindow,
                target: "locked_budget_window",
                statement_shape: "select (limit_amount >= $required_debit) as passed from locked_budget_window where tenant_id = $tenant_id and budget_id = $budget_id and currency = $currency",
                lock_clause: None,
                where_bounds: vec!["tenant_id", "budget_id", "currency"],
                ordered_by: Vec::new(),
                command_order: Some(command.order),
                command_kind: Some(command.kind),
                row_count_expectation: ConsistentLedgerPostgresRowCountExpectation::ExactlyOne,
                request_id: command.request_id,
                ledger_entry_id: command.ledger_entry_id,
                related_ledger_entry_id: command.related_ledger_entry_id,
                budget_id: command.budget_id,
                entry_type: command.entry_type,
                amount: command.amount,
                currency: command.currency.clone(),
                status: command.status,
                metadata: command.metadata.clone(),
                operation_key_output: "omitted",
            }
        }
        ConsistentLedgerBoundedCommandKind::InsertLedgerEntry => {
            ConsistentLedgerPostgresStatement {
                order,
                kind: ConsistentLedgerPostgresStatementKind::InsertLedgerEntry,
                target: "ledger_entries",
                statement_shape: "insert into ledger_entries (tenant_id, project_id, virtual_key_id, request_id, related_ledger_entry_id, entry_type, amount, currency, status, <private operation key column>, metadata) values ($tenant_id, $project_id, $virtual_key_id, $request_id, $related_ledger_entry_id, $entry_type, $amount, $currency, $status, $private_operation_key, $metadata) on conflict (tenant_id, <private operation key column>) do nothing returning id",
                lock_clause: None,
                where_bounds: vec![
                    "tenant_id",
                    "request_id",
                    "related_ledger_entry_id",
                    "private_operation_key",
                ],
                ordered_by: Vec::new(),
                command_order: Some(command.order),
                command_kind: Some(command.kind),
                row_count_expectation: ConsistentLedgerPostgresRowCountExpectation::ExactlyOne,
                request_id: command.request_id,
                ledger_entry_id: command.ledger_entry_id,
                related_ledger_entry_id: command.related_ledger_entry_id,
                budget_id: command.budget_id,
                entry_type: command.entry_type,
                amount: command.amount,
                currency: command.currency.clone(),
                status: command.status,
                metadata: command.metadata.clone(),
                operation_key_output: "omitted",
            }
        }
        ConsistentLedgerBoundedCommandKind::UpdateLedgerStatus => {
            ConsistentLedgerPostgresStatement {
                order,
                kind: ConsistentLedgerPostgresStatementKind::UpdateLedgerStatus,
                target: "ledger_entries",
                statement_shape: "update ledger_entries set status = $to_status where tenant_id = $tenant_id and id = $ledger_entry_id and status = $from_status",
                lock_clause: None,
                where_bounds: vec!["tenant_id", "ledger_entry_id"],
                ordered_by: Vec::new(),
                command_order: Some(command.order),
                command_kind: Some(command.kind),
                row_count_expectation: ConsistentLedgerPostgresRowCountExpectation::ExactlyOne,
                request_id: command.request_id,
                ledger_entry_id: command.ledger_entry_id,
                related_ledger_entry_id: None,
                budget_id: command.budget_id,
                entry_type: command.entry_type,
                amount: command.amount,
                currency: command.currency.clone(),
                status: command.status,
                metadata: command.metadata.clone(),
                operation_key_output: "omitted",
            }
        }
    }
}

fn transaction_steps(idempotent_replay: bool) -> Vec<ConsistentLedgerPostgresTransactionStep> {
    vec![
        ConsistentLedgerPostgresTransactionStep {
            order: 1,
            kind: ConsistentLedgerPostgresTransactionStepKind::BeginTransaction,
            description: "begin read committed transaction",
        },
        ConsistentLedgerPostgresTransactionStep {
            order: 2,
            kind: ConsistentLedgerPostgresTransactionStepKind::AcquireOrderedLocks,
            description: "acquire wallet, credit grant, budget, then ledger row locks in deterministic order",
        },
        ConsistentLedgerPostgresTransactionStep {
            order: 3,
            kind: ConsistentLedgerPostgresTransactionStepKind::RecomputeLockedWindows,
            description: "recompute balance, budget, replay, and refund remaining windows after locks are held",
        },
        ConsistentLedgerPostgresTransactionStep {
            order: 4,
            kind: ConsistentLedgerPostgresTransactionStepKind::ExecuteBoundedCommands,
            description: if idempotent_replay {
                "idempotent replay returns existing result without insert or update statements"
            } else {
                "execute bounded assert, insert, and update command statements in order"
            },
        },
        ConsistentLedgerPostgresTransactionStep {
            order: 5,
            kind: ConsistentLedgerPostgresTransactionStepKind::CommitOrRollback,
            description: "commit only after all statements match expected row counts; otherwise rollback and return sanitized error",
        },
    ]
}

fn postgres_boundary_contract() -> ConsistentLedgerPostgresBoundaryContract {
    ConsistentLedgerPostgresBoundaryContract {
        db_io_implemented: false,
        planned_executor: "PostgresConsistentLedgerCommandExecutor",
        future_sqlx_entrypoint: "execute_consistent_ledger_postgres_transaction",
        private_operation_key_contract: "raw operation key is accepted only as a private bind parameter and is omitted from public plan output",
        idempotent_replay_contract: "same private operation key with matching locked row returns idempotent with no write commands; conflicting locked row rejects before insert",
        bounded_scan_policy: "every statement has a tenant, wallet, request, source ledger row, budget, or private operation key bound; no full-table scan is allowed",
        safe_output_contract: vec![
            "operation_key_omitted",
            "request_material_omitted",
            "auth_header_omitted",
            "provider_credential_omitted",
            "wallet_credential_omitted",
            "db_url_omitted",
        ],
    }
}
