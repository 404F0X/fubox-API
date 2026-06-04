use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{
    ConsistentLedgerBoundedCommand, ConsistentLedgerBoundedCommandKind,
    ConsistentLedgerCommandPlan, ConsistentLedgerScope, ConsistentLedgerWriterPlan,
    LedgerEntryStatus, LedgerOperationKind, LedgerOperationOutcome,
};

pub const CONSISTENT_LEDGER_POSTGRES_EXECUTION_SCHEMA: &str =
    "billing_ledger_postgres_execution_plan.v1";
pub const CONSISTENT_LEDGER_POSTGRES_EXECUTOR_SCHEMA: &str = "billing_ledger_postgres_executor.v1";

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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_id: Option<Uuid>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ledger_entry_id: Option<Uuid>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub related_ledger_entry_id: Option<Uuid>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<LedgerEntryStatus>,
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
                let result = sanitized_statement_result(statement, result);
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

fn ordered_lock_statements(
    writer_plan: &ConsistentLedgerWriterPlan,
) -> Vec<ConsistentLedgerPostgresStatement> {
    vec![
        ConsistentLedgerPostgresStatement {
            order: 1,
            kind: ConsistentLedgerPostgresStatementKind::LockWallet,
            target: "wallets",
            statement_shape: "select id, available_balance from wallets where tenant_id = $tenant_id and project_id is not distinct from $project_id and currency = $currency for update",
            lock_clause: Some("for_update"),
            where_bounds: vec!["tenant_id", "project_id", "currency"],
            ordered_by: Vec::new(),
            command_order: None,
            command_kind: None,
            request_id: None,
            ledger_entry_id: None,
            related_ledger_entry_id: None,
            status: None,
            operation_key_output: "omitted",
        },
        ConsistentLedgerPostgresStatement {
            order: 2,
            kind: ConsistentLedgerPostgresStatementKind::LockCreditGrants,
            target: "credit_grants",
            statement_shape: "select id, remaining_amount from credit_grants where wallet_id = $wallet_id and currency = $currency and active = true and effective_at <= $now and (expires_at is null or expires_at > $now) order by id for update",
            lock_clause: Some("for_update_ordered"),
            where_bounds: vec!["wallet_id", "currency", "effective_at", "expires_at"],
            ordered_by: vec!["id"],
            command_order: None,
            command_kind: None,
            request_id: None,
            ledger_entry_id: None,
            related_ledger_entry_id: None,
            status: None,
            operation_key_output: "omitted",
        },
        ConsistentLedgerPostgresStatement {
            order: 3,
            kind: ConsistentLedgerPostgresStatementKind::LockBudgets,
            target: "budgets",
            statement_shape: "select id, dimension, remaining_amount from budgets where tenant_id = $tenant_id and currency = $currency and active = true and (dimension = 'tenant' or (dimension = 'project' and project_id = $project_id) or (dimension = 'virtual_key' and virtual_key_id = $virtual_key_id)) order by dimension, id for update",
            lock_clause: Some("for_update_ordered"),
            where_bounds: vec!["tenant_id", "project_id", "virtual_key_id", "currency"],
            ordered_by: vec!["dimension", "id"],
            command_order: None,
            command_kind: None,
            request_id: None,
            ledger_entry_id: None,
            related_ledger_entry_id: None,
            status: None,
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
                request_id: None,
                ledger_entry_id: None,
                related_ledger_entry_id: None,
                status: None,
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
                request_id: None,
                ledger_entry_id: None,
                related_ledger_entry_id: None,
                status: None,
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
                request_id: command.request_id,
                ledger_entry_id: command.ledger_entry_id,
                related_ledger_entry_id: command.related_ledger_entry_id,
                status: command.status,
                operation_key_output: "omitted",
            }
        }
        ConsistentLedgerBoundedCommandKind::AssertBudgetWindow => {
            ConsistentLedgerPostgresStatement {
                order,
                kind: ConsistentLedgerPostgresStatementKind::AssertBudgetWindow,
                target: "locked_budget_window",
                statement_shape: "select (remaining_amount >= $required_debit) as passed from locked_budget_window where tenant_id = $tenant_id and budget_id = $budget_id and currency = $currency",
                lock_clause: None,
                where_bounds: vec!["tenant_id", "budget_id", "currency"],
                ordered_by: Vec::new(),
                command_order: Some(command.order),
                command_kind: Some(command.kind),
                request_id: command.request_id,
                ledger_entry_id: command.ledger_entry_id,
                related_ledger_entry_id: command.related_ledger_entry_id,
                status: command.status,
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
                request_id: command.request_id,
                ledger_entry_id: command.ledger_entry_id,
                related_ledger_entry_id: command.related_ledger_entry_id,
                status: command.status,
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
                request_id: command.request_id,
                ledger_entry_id: command.ledger_entry_id,
                related_ledger_entry_id: None,
                status: command.status,
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
