use std::fmt;

use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

use crate::{
    FixedDecimal, LedgerContractError, LedgerEntryRecord, LedgerEntryStatus, LedgerEntryType,
    LedgerOperationKind, LedgerOperationOutcome, LedgerOperationPlan, RefundLedgerRequest,
    ReserveLedgerRequest, SettleLedgerRequest, plan_ledger_refund, plan_ledger_reserve,
    plan_ledger_settle, refund_ledger_idempotency_key, refund_partial_ledger_idempotency_key,
    reserve_ledger_idempotency_key, settle_ledger_idempotency_key,
};

pub const CONSISTENT_LEDGER_WRITER_SCHEMA: &str = "billing_ledger_consistent_writer_plan.v1";

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum ConsistentLedgerWriterError {
    #[error("wallet row is required for consistent ledger writer")]
    WalletRequired,
    #[error(
        "wallet currency `{wallet_currency}` does not match request currency `{request_currency}`"
    )]
    WalletCurrencyMismatch {
        wallet_currency: String,
        request_currency: String,
    },
    #[error("wallet balance `{available}` is below required debit `{required}`")]
    InsufficientWalletBalance {
        available: FixedDecimal,
        required: FixedDecimal,
    },
    #[error(
        "budget `{budget_id}` for `{dimension}` has `{remaining}` below required debit `{required}`"
    )]
    InsufficientBudget {
        budget_id: Uuid,
        dimension: ConsistentBudgetDimension,
        remaining: FixedDecimal,
        required: FixedDecimal,
    },
    #[error("consistent writer amount scale mismatch: expected {expected}, got {actual}")]
    ScaleMismatch { expected: u32, actual: u32 },
    #[error("consistent writer arithmetic overflow")]
    ArithmeticOverflow,
    #[error(transparent)]
    Ledger(#[from] LedgerContractError),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConsistentLedgerWriteRequest {
    Reserve {
        scope: ConsistentLedgerScope,
        request_id: Uuid,
        amount: FixedDecimal,
        currency: String,
    },
    Settle {
        scope: ConsistentLedgerScope,
        request_id: Uuid,
        final_cost: FixedDecimal,
        currency: String,
    },
    RefundFull {
        scope: ConsistentLedgerScope,
        related_ledger_entry_id: Uuid,
        currency: String,
    },
    RefundPartial {
        scope: ConsistentLedgerScope,
        related_ledger_entry_id: Uuid,
        refund_operation_id: Uuid,
        amount: FixedDecimal,
        currency: String,
    },
}

impl ConsistentLedgerWriteRequest {
    pub const fn scope(&self) -> &ConsistentLedgerScope {
        match self {
            Self::Reserve { scope, .. }
            | Self::Settle { scope, .. }
            | Self::RefundFull { scope, .. }
            | Self::RefundPartial { scope, .. } => scope,
        }
    }

    pub fn currency(&self) -> &str {
        match self {
            Self::Reserve { currency, .. }
            | Self::Settle { currency, .. }
            | Self::RefundFull { currency, .. }
            | Self::RefundPartial { currency, .. } => currency,
        }
    }

    pub const fn operation(&self) -> LedgerOperationKind {
        match self {
            Self::Reserve { .. } => LedgerOperationKind::Reserve,
            Self::Settle { .. } => LedgerOperationKind::Settle,
            Self::RefundFull { .. } => LedgerOperationKind::Refund,
            Self::RefundPartial { .. } => LedgerOperationKind::RefundPartial,
        }
    }

    pub fn idempotency_key(&self) -> String {
        match self {
            Self::Reserve { request_id, .. } => reserve_ledger_idempotency_key(*request_id),
            Self::Settle { request_id, .. } => settle_ledger_idempotency_key(*request_id),
            Self::RefundFull {
                related_ledger_entry_id,
                ..
            } => refund_ledger_idempotency_key(*related_ledger_entry_id),
            Self::RefundPartial {
                related_ledger_entry_id,
                refund_operation_id,
                ..
            } => refund_partial_ledger_idempotency_key(
                *related_ledger_entry_id,
                *refund_operation_id,
            ),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConsistentLedgerScope {
    pub tenant_id: Uuid,
    pub project_id: Option<Uuid>,
    pub virtual_key_id: Option<Uuid>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConsistentLedgerWriterState {
    pub wallet: Option<ConsistentWalletSnapshot>,
    pub credit_grants: Vec<ConsistentCreditGrantSnapshot>,
    pub budgets: Vec<ConsistentBudgetSnapshot>,
    pub ledger_entries: Vec<LedgerEntryRecord>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConsistentWalletSnapshot {
    pub wallet_id: Uuid,
    pub currency: String,
    pub available_balance: FixedDecimal,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConsistentCreditGrantSnapshot {
    pub grant_id: Uuid,
    pub currency: String,
    pub remaining_amount: FixedDecimal,
    pub active: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConsistentBudgetSnapshot {
    pub budget_id: Uuid,
    pub dimension: ConsistentBudgetDimension,
    pub currency: String,
    pub remaining_amount: FixedDecimal,
    pub active: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConsistentBudgetDimension {
    Tenant,
    Project,
    VirtualKey,
}

impl ConsistentBudgetDimension {
    const fn sort_key(self) -> u8 {
        match self {
            Self::Tenant => 0,
            Self::Project => 1,
            Self::VirtualKey => 2,
        }
    }

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Tenant => "tenant",
            Self::Project => "project",
            Self::VirtualKey => "virtual_key",
        }
    }
}

impl fmt::Display for ConsistentBudgetDimension {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ConsistentLedgerWriterPlan {
    pub schema_version: &'static str,
    pub operation: LedgerOperationKind,
    pub idempotency_key: String,
    pub outcome: LedgerOperationOutcome,
    pub scope: ConsistentLedgerScope,
    pub lock_plan: ConsistentWriterLockPlan,
    pub balance_window: ConsistentBalanceWindow,
    pub wallet_check: ConsistentWalletCheck,
    pub budget_checks: Vec<ConsistentBudgetCheck>,
    pub state_machine: ConsistentWriterStateMachine,
    pub postgres_writer_contract: ConsistentPostgresWriterContract,
    pub ledger_plan: LedgerOperationPlan,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ConsistentWriterLockPlan {
    pub transaction: &'static str,
    pub lock_order: Vec<ConsistentWriterLockStep>,
    pub unique_constraints: Vec<&'static str>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ConsistentWriterLockStep {
    pub order: u8,
    pub resource: &'static str,
    pub lock_mode: &'static str,
    pub query_shape: &'static str,
    pub bounded_by: Vec<&'static str>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ConsistentBalanceWindow {
    pub currency: String,
    pub wallet_available_balance: FixedDecimal,
    pub active_credit_grant_total: FixedDecimal,
    pub active_ledger_effect: FixedDecimal,
    pub available_before_write: FixedDecimal,
    pub required_debit: FixedDecimal,
    pub refund_credit: FixedDecimal,
    pub available_after_write: FixedDecimal,
    pub calculation: &'static str,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ConsistentWalletCheck {
    pub required: bool,
    pub passed: bool,
    pub reason: &'static str,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ConsistentBudgetCheck {
    pub budget_id: Uuid,
    pub dimension: ConsistentBudgetDimension,
    pub remaining_before_write: FixedDecimal,
    pub required_debit: FixedDecimal,
    pub remaining_after_write: FixedDecimal,
    pub passed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ConsistentWriterStateMachine {
    pub reserve: &'static str,
    pub settle: &'static str,
    pub refund: &'static str,
    pub idempotency: &'static str,
    pub concurrency_rejections: Vec<&'static str>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ConsistentPostgresWriterContract {
    pub read_write_scope: &'static str,
    pub balance_window: &'static str,
    pub budget_dimensions: Vec<&'static str>,
    pub cursor_or_scan_policy: &'static str,
    pub safe_output_contract: Vec<&'static str>,
}

pub fn plan_consistent_ledger_write(
    request: ConsistentLedgerWriteRequest,
    state: &ConsistentLedgerWriterState,
) -> Result<ConsistentLedgerWriterPlan, ConsistentLedgerWriterError> {
    let ledger_plan = plan_inner_ledger_write(&request, &state.ledger_entries)?;
    let wallet = state
        .wallet
        .as_ref()
        .ok_or(ConsistentLedgerWriterError::WalletRequired)?;
    if wallet.currency != request.currency() {
        return Err(ConsistentLedgerWriterError::WalletCurrencyMismatch {
            wallet_currency: wallet.currency.clone(),
            request_currency: request.currency().to_string(),
        });
    }

    let idempotent = matches!(
        ledger_plan.outcome,
        LedgerOperationOutcome::Idempotent { .. }
    );
    let required_debit = if idempotent {
        zero(wallet.available_balance.scale())?
    } else {
        required_debit_for_write(&request, state)?
    };
    let refund_credit = refund_credit_for_plan(&ledger_plan, wallet.available_balance.scale())?;
    let balance_window = balance_window(
        request.currency(),
        wallet,
        state,
        required_debit,
        refund_credit,
    )?;
    let wallet_check = wallet_check(balance_window.available_before_write, required_debit);
    if !wallet_check.passed {
        return Err(ConsistentLedgerWriterError::InsufficientWalletBalance {
            available: balance_window.available_before_write,
            required: required_debit,
        });
    }

    let budget_checks = budget_checks(&state.budgets, request.currency(), required_debit)?;
    if let Some(failed) = budget_checks.iter().find(|check| !check.passed) {
        return Err(ConsistentLedgerWriterError::InsufficientBudget {
            budget_id: failed.budget_id,
            dimension: failed.dimension,
            remaining: failed.remaining_before_write,
            required: failed.required_debit,
        });
    }

    Ok(ConsistentLedgerWriterPlan {
        schema_version: CONSISTENT_LEDGER_WRITER_SCHEMA,
        operation: request.operation(),
        idempotency_key: request.idempotency_key(),
        outcome: ledger_plan.outcome.clone(),
        scope: *request.scope(),
        lock_plan: lock_plan_for_request(&request),
        balance_window,
        wallet_check,
        budget_checks,
        state_machine: state_machine_contract(),
        postgres_writer_contract: postgres_writer_contract(),
        ledger_plan,
    })
}

fn plan_inner_ledger_write(
    request: &ConsistentLedgerWriteRequest,
    existing_entries: &[LedgerEntryRecord],
) -> Result<LedgerOperationPlan, LedgerContractError> {
    match request {
        ConsistentLedgerWriteRequest::Reserve {
            request_id,
            amount,
            currency,
            ..
        } => plan_ledger_reserve(
            ReserveLedgerRequest {
                request_id: *request_id,
                amount: *amount,
                currency: currency.clone(),
            },
            existing_entries,
        ),
        ConsistentLedgerWriteRequest::Settle {
            request_id,
            final_cost,
            currency,
            ..
        } => plan_ledger_settle(
            SettleLedgerRequest {
                request_id: *request_id,
                final_cost: *final_cost,
                currency: currency.clone(),
            },
            existing_entries,
        ),
        ConsistentLedgerWriteRequest::RefundFull {
            related_ledger_entry_id,
            currency,
            ..
        } => plan_ledger_refund(
            RefundLedgerRequest::Full {
                related_ledger_entry_id: *related_ledger_entry_id,
                currency: currency.clone(),
                amount: None,
            },
            existing_entries,
        ),
        ConsistentLedgerWriteRequest::RefundPartial {
            related_ledger_entry_id,
            refund_operation_id,
            amount,
            currency,
            ..
        } => plan_ledger_refund(
            RefundLedgerRequest::Partial {
                related_ledger_entry_id: *related_ledger_entry_id,
                refund_operation_id: Some(*refund_operation_id),
                amount: Some(*amount),
                currency: currency.clone(),
            },
            existing_entries,
        ),
    }
}

fn required_debit_for_write(
    request: &ConsistentLedgerWriteRequest,
    state: &ConsistentLedgerWriterState,
) -> Result<FixedDecimal, ConsistentLedgerWriterError> {
    match request {
        ConsistentLedgerWriteRequest::Reserve { amount, .. } => Ok(*amount),
        ConsistentLedgerWriteRequest::Settle {
            request_id,
            final_cost,
            ..
        } => {
            let reserved = pending_reserve_amount_for_request(&state.ledger_entries, *request_id)?;
            if *final_cost > reserved {
                checked_subtract(*final_cost, reserved)
            } else {
                zero(final_cost.scale())
            }
        }
        ConsistentLedgerWriteRequest::RefundFull { .. }
        | ConsistentLedgerWriteRequest::RefundPartial { .. } => {
            let scale = state
                .wallet
                .as_ref()
                .map(|wallet| wallet.available_balance.scale())
                .unwrap_or(crate::DEFAULT_MONEY_SCALE);
            zero(scale)
        }
    }
}

fn pending_reserve_amount_for_request(
    entries: &[LedgerEntryRecord],
    request_id: Uuid,
) -> Result<FixedDecimal, ConsistentLedgerWriterError> {
    let scale = entries
        .iter()
        .find(|entry| entry.request_id == Some(request_id))
        .map(|entry| entry.amount.scale())
        .unwrap_or(crate::DEFAULT_MONEY_SCALE);
    let zero = zero(scale)?;

    entries
        .iter()
        .filter(|entry| {
            entry.request_id == Some(request_id)
                && entry.entry_type == LedgerEntryType::Reserve
                && entry.status == LedgerEntryStatus::Pending
        })
        .try_fold(zero, |total, entry| {
            let reserved = checked_neg(entry.amount)?;
            checked_add(total, reserved)
        })
}

fn refund_credit_for_plan(
    ledger_plan: &LedgerOperationPlan,
    scale: u32,
) -> Result<FixedDecimal, ConsistentLedgerWriterError> {
    let zero = zero(scale)?;
    ledger_plan.entries.iter().try_fold(zero, |total, entry| {
        if entry.entry_type == LedgerEntryType::Refund {
            checked_add(total, entry.amount)
        } else {
            Ok(total)
        }
    })
}

fn balance_window(
    currency: &str,
    wallet: &ConsistentWalletSnapshot,
    state: &ConsistentLedgerWriterState,
    required_debit: FixedDecimal,
    refund_credit: FixedDecimal,
) -> Result<ConsistentBalanceWindow, ConsistentLedgerWriterError> {
    let active_credit_grant_total = active_credit_grant_total(
        &state.credit_grants,
        currency,
        wallet.available_balance.scale(),
    )?;
    let active_ledger_effect = active_ledger_effect(
        &state.ledger_entries,
        currency,
        wallet.available_balance.scale(),
    )?;
    let available_before_write = checked_add(
        checked_add(wallet.available_balance, active_credit_grant_total)?,
        active_ledger_effect,
    )?;
    let available_after_debit = checked_subtract(available_before_write, required_debit)?;
    let available_after_write = checked_add(available_after_debit, refund_credit)?;

    Ok(ConsistentBalanceWindow {
        currency: currency.to_string(),
        wallet_available_balance: wallet.available_balance,
        active_credit_grant_total,
        active_ledger_effect,
        available_before_write,
        required_debit,
        refund_credit,
        available_after_write,
        calculation: "wallet_available_balance + active_credit_grants + active_pending_or_confirmed_ledger - required_debit + refund_credit",
    })
}

fn active_credit_grant_total(
    grants: &[ConsistentCreditGrantSnapshot],
    currency: &str,
    scale: u32,
) -> Result<FixedDecimal, ConsistentLedgerWriterError> {
    grants
        .iter()
        .filter(|grant| grant.active && grant.currency == currency)
        .try_fold(zero(scale)?, |total, grant| {
            checked_add(total, grant.remaining_amount)
        })
}

fn active_ledger_effect(
    entries: &[LedgerEntryRecord],
    currency: &str,
    scale: u32,
) -> Result<FixedDecimal, ConsistentLedgerWriterError> {
    entries
        .iter()
        .filter(|entry| {
            entry.currency == currency
                && matches!(
                    entry.status,
                    LedgerEntryStatus::Pending | LedgerEntryStatus::Confirmed
                )
        })
        .try_fold(zero(scale)?, |total, entry| {
            checked_add(total, entry.amount)
        })
}

fn wallet_check(
    available_before_write: FixedDecimal,
    required_debit: FixedDecimal,
) -> ConsistentWalletCheck {
    let passed = required_debit.is_zero() || available_before_write >= required_debit;
    ConsistentWalletCheck {
        required: !required_debit.is_zero(),
        passed,
        reason: if passed {
            "available_balance_covers_required_debit"
        } else {
            "available_balance_below_required_debit"
        },
    }
}

fn budget_checks(
    budgets: &[ConsistentBudgetSnapshot],
    currency: &str,
    required_debit: FixedDecimal,
) -> Result<Vec<ConsistentBudgetCheck>, ConsistentLedgerWriterError> {
    let mut budgets = budgets
        .iter()
        .filter(|budget| budget.active && budget.currency == currency)
        .collect::<Vec<_>>();
    budgets.sort_by_key(|budget| (budget.dimension.sort_key(), budget.budget_id));

    budgets
        .into_iter()
        .map(|budget| {
            let remaining_after_write = checked_subtract(budget.remaining_amount, required_debit)?;
            Ok(ConsistentBudgetCheck {
                budget_id: budget.budget_id,
                dimension: budget.dimension,
                remaining_before_write: budget.remaining_amount,
                required_debit,
                remaining_after_write,
                passed: budget.remaining_amount >= required_debit,
            })
        })
        .collect()
}

fn lock_plan_for_request(request: &ConsistentLedgerWriteRequest) -> ConsistentWriterLockPlan {
    let mut lock_order = vec![
        ConsistentWriterLockStep {
            order: 1,
            resource: "wallets",
            lock_mode: "for_update",
            query_shape: "select wallet row by tenant/project/currency for update",
            bounded_by: vec!["tenant_id", "project_id", "currency"],
        },
        ConsistentWriterLockStep {
            order: 2,
            resource: "credit_grants",
            lock_mode: "for_update_ordered",
            query_shape: "select active credit grants by wallet/currency/effective window ordered by grant_id for update",
            bounded_by: vec!["wallet_id", "currency", "effective_at", "expires_at"],
        },
        ConsistentWriterLockStep {
            order: 3,
            resource: "budgets",
            lock_mode: "for_update_ordered",
            query_shape: "select active tenant/project/virtual_key budgets ordered by dimension,budget_id for update",
            bounded_by: vec!["tenant_id", "project_id", "virtual_key_id", "currency"],
        },
    ];

    match request {
        ConsistentLedgerWriteRequest::Reserve { .. }
        | ConsistentLedgerWriteRequest::Settle { .. } => {
            lock_order.push(ConsistentWriterLockStep {
                order: 4,
                resource: "ledger_entries",
                lock_mode: "for_update_ordered",
                query_shape: "select ledger rows by tenant/request_id or idempotency_key ordered by created_at,id for update",
                bounded_by: vec![
                    "tenant_id",
                    "request_id",
                    "related_ledger_entry_id",
                    "idempotency_key",
                ],
            });
        }
        ConsistentLedgerWriteRequest::RefundFull { .. }
        | ConsistentLedgerWriteRequest::RefundPartial { .. } => {
            lock_order.push(ConsistentWriterLockStep {
                order: 4,
                resource: "ledger_entries",
                lock_mode: "for_update_ordered",
                query_shape: "select source settle and related refund rows by tenant/source_ledger_entry_id/idempotency_key ordered by created_at,id for update",
                bounded_by: vec![
                    "tenant_id",
                    "request_id",
                    "related_ledger_entry_id",
                    "idempotency_key",
                ],
            });
        }
    }

    ConsistentWriterLockPlan {
        transaction: "read_committed_single_transaction_with_explicit_for_update_locks",
        lock_order,
        unique_constraints: vec![
            "ledger_entries(tenant_id,idempotency_key)",
            "one active settle per tenant/request_id",
            "one active reserve per tenant/request_id",
        ],
    }
}

fn state_machine_contract() -> ConsistentWriterStateMachine {
    ConsistentWriterStateMachine {
        reserve: "reserve:{request_id} inserts one pending debit after locked wallet/grant/budget balance covers required debit",
        settle: "settle:{request_id} inserts one confirmed debit and reverses pending reserve for the same request; only final_cost minus locked pending reserve requires additional balance",
        refund: "refund keys insert confirmed positive credits against a locked confirmed settle source; remaining refundable amount is recomputed while source and related refunds are locked",
        idempotency: "same idempotency key with identical ledger shape returns idempotent without additional debit; same key with different amount/currency/status is rejected",
        concurrency_rejections: vec![
            "non_idempotent_duplicate_reserve_for_request",
            "non_idempotent_duplicate_settle_for_request",
            "refund_against_missing_uncommitted_or_locked_settle_source",
            "refund_amount_exceeds_remaining_after_locked_refunds",
            "same_refund_operation_id_with_different_amount_or_currency",
        ],
    }
}

fn postgres_writer_contract() -> ConsistentPostgresWriterContract {
    ConsistentPostgresWriterContract {
        read_write_scope: "single tenant-scoped transaction; no cross-tenant rows; no unbounded table scan",
        balance_window: "recompute wallet + active credit grants + pending/confirmed ledger debits/credits after all FOR UPDATE locks are acquired",
        budget_dimensions: vec!["tenant", "project", "virtual_key"],
        cursor_or_scan_policy: "all ledger reads are bounded by tenant_id plus request_id, related_ledger_entry_id, or idempotency_key",
        safe_output_contract: vec![
            "request_material_omitted",
            "auth_header_omitted",
            "provider_credential_omitted",
            "wallet_credential_omitted",
            "db_url_omitted",
        ],
    }
}

fn checked_add(
    left: FixedDecimal,
    right: FixedDecimal,
) -> Result<FixedDecimal, ConsistentLedgerWriterError> {
    ensure_same_scale(left, right)?;
    left.checked_add(right)
        .map_err(|_| ConsistentLedgerWriterError::ArithmeticOverflow)
}

fn checked_subtract(
    left: FixedDecimal,
    right: FixedDecimal,
) -> Result<FixedDecimal, ConsistentLedgerWriterError> {
    ensure_same_scale(left, right)?;
    let units = left
        .units()
        .checked_sub(right.units())
        .ok_or(ConsistentLedgerWriterError::ArithmeticOverflow)?;
    FixedDecimal::from_units(units, left.scale())
        .map_err(|_| ConsistentLedgerWriterError::ArithmeticOverflow)
}

fn checked_neg(value: FixedDecimal) -> Result<FixedDecimal, ConsistentLedgerWriterError> {
    let units = value
        .units()
        .checked_neg()
        .ok_or(ConsistentLedgerWriterError::ArithmeticOverflow)?;
    FixedDecimal::from_units(units, value.scale())
        .map_err(|_| ConsistentLedgerWriterError::ArithmeticOverflow)
}

fn zero(scale: u32) -> Result<FixedDecimal, ConsistentLedgerWriterError> {
    FixedDecimal::zero(scale).map_err(|_| ConsistentLedgerWriterError::ArithmeticOverflow)
}

fn ensure_same_scale(
    left: FixedDecimal,
    right: FixedDecimal,
) -> Result<(), ConsistentLedgerWriterError> {
    if left.scale() == right.scale() {
        Ok(())
    } else {
        Err(ConsistentLedgerWriterError::ScaleMismatch {
            expected: left.scale(),
            actual: right.scale(),
        })
    }
}
