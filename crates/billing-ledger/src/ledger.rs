use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

use crate::{ExactCacheLedgerMetadata, FixedDecimal};

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum LedgerContractError {
    #[error("ledger amount field `{field}` must be positive")]
    NonPositiveAmount { field: &'static str },
    #[error("invalid ledger currency `{currency}`")]
    InvalidCurrency { currency: String },
    #[error("ledger idempotency key already belongs to a different operation")]
    IdempotencyConflict { key: String },
    #[error("ledger request `{request_id}` is already reserved")]
    RequestAlreadyReserved { request_id: Uuid },
    #[error("ledger request `{request_id}` is already settled")]
    RequestAlreadySettled { request_id: Uuid },
    #[error(
        "pending reserve currency `{reserve_currency}` does not match settle currency `{settle_currency}`"
    )]
    ReserveCurrencyMismatch {
        reserve_currency: String,
        settle_currency: String,
    },
    #[error("ledger refund source `{ledger_entry_id}` was not found")]
    RefundSourceNotFound { ledger_entry_id: Uuid },
    #[error("ledger refund source `{ledger_entry_id}` must be a confirmed settle debit")]
    RefundSourceNotConfirmedSettleDebit { ledger_entry_id: Uuid },
    #[error("ledger refund currency `{actual}` does not match source currency `{expected}`")]
    RefundCurrencyMismatch { expected: String, actual: String },
    #[error("full ledger refund amount must be omitted so the remaining debit is refunded")]
    FullRefundAmountNotAllowed,
    #[error("partial ledger refund requires a positive amount")]
    PartialRefundAmountRequired,
    #[error("partial ledger refund requires an operation id")]
    PartialRefundOperationIdRequired,
    #[error("partial ledger refund amount must be less than the remaining refundable amount")]
    PartialRefundConsumesRemaining {
        requested: FixedDecimal,
        remaining: FixedDecimal,
    },
    #[error("ledger refund amount `{requested}` exceeds remaining refundable amount `{remaining}`")]
    RefundAmountExceedsRemaining {
        requested: FixedDecimal,
        remaining: FixedDecimal,
    },
    #[error("ledger amount has incompatible scale: expected {expected}, got {actual}")]
    ScaleMismatch { expected: u32, actual: u32 },
    #[error("ledger arithmetic overflow")]
    ArithmeticOverflow,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LedgerEntryType {
    Reserve,
    Settle,
    Refund,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LedgerEntryStatus {
    Pending,
    Confirmed,
    Reversed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LedgerOperationKind {
    Reserve,
    Settle,
    Refund,
    RefundPartial,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LedgerRefundKind {
    Full,
    Partial,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LedgerStatusUpdateReason {
    ReserveSettled,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LedgerEntryRecord {
    pub id: Uuid,
    pub request_id: Option<Uuid>,
    pub related_ledger_entry_id: Option<Uuid>,
    pub entry_type: LedgerEntryType,
    pub amount: FixedDecimal,
    pub currency: String,
    pub status: LedgerEntryStatus,
    pub idempotency_key: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LedgerEntryDraft {
    pub request_id: Option<Uuid>,
    pub related_ledger_entry_id: Option<Uuid>,
    pub entry_type: LedgerEntryType,
    pub amount: FixedDecimal,
    pub currency: String,
    pub status: LedgerEntryStatus,
    #[serde(skip_serializing)]
    pub idempotency_key: String,
    pub metadata: LedgerEntryMetadata,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LedgerEntryMetadata {
    pub operation: LedgerOperationKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_id: Option<Uuid>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub related_ledger_entry_id: Option<Uuid>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub refund_kind: Option<LedgerRefundKind>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exact_cache: Option<ExactCacheLedgerMetadata>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LedgerStatusUpdate {
    pub ledger_entry_id: Uuid,
    pub from: LedgerEntryStatus,
    pub to: LedgerEntryStatus,
    pub reason: LedgerStatusUpdateReason,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LedgerOperationPlan {
    pub operation: LedgerOperationKind,
    #[serde(skip_serializing)]
    pub idempotency_key: String,
    pub outcome: LedgerOperationOutcome,
    pub entries: Vec<LedgerEntryDraft>,
    pub status_updates: Vec<LedgerStatusUpdate>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LedgerOperationOutcome {
    Apply,
    Idempotent { existing_entry_id: Uuid },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReserveLedgerRequest {
    pub request_id: Uuid,
    pub amount: FixedDecimal,
    pub currency: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SettleLedgerRequest {
    pub request_id: Uuid,
    pub final_cost: FixedDecimal,
    pub currency: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RefundLedgerRequest {
    Full {
        related_ledger_entry_id: Uuid,
        currency: String,
        amount: Option<FixedDecimal>,
    },
    Partial {
        related_ledger_entry_id: Uuid,
        refund_operation_id: Option<Uuid>,
        amount: Option<FixedDecimal>,
        currency: String,
    },
}

pub fn reserve_ledger_idempotency_key(request_id: Uuid) -> String {
    format!("reserve:{request_id}")
}

pub fn settle_ledger_idempotency_key(request_id: Uuid) -> String {
    format!("settle:{request_id}")
}

pub fn refund_ledger_idempotency_key(related_ledger_entry_id: Uuid) -> String {
    format!("refund:{related_ledger_entry_id}")
}

pub fn refund_partial_ledger_idempotency_key(
    related_ledger_entry_id: Uuid,
    refund_operation_id: Uuid,
) -> String {
    format!("refund_partial:{related_ledger_entry_id}:{refund_operation_id}")
}

pub fn plan_ledger_reserve(
    request: ReserveLedgerRequest,
    existing_entries: &[LedgerEntryRecord],
) -> Result<LedgerOperationPlan, LedgerContractError> {
    validate_currency(&request.currency)?;
    let amount = debit_amount("amount", request.amount)?;
    let idempotency_key = reserve_ledger_idempotency_key(request.request_id);

    let draft = LedgerEntryDraft {
        request_id: Some(request.request_id),
        related_ledger_entry_id: None,
        entry_type: LedgerEntryType::Reserve,
        amount,
        currency: request.currency,
        status: LedgerEntryStatus::Pending,
        idempotency_key: idempotency_key.clone(),
        metadata: LedgerEntryMetadata::reserve(request.request_id),
    };

    if let Some(existing) = find_by_idempotency_key(existing_entries, &idempotency_key) {
        ensure_existing_matches_draft(existing, &draft)?;
        return Ok(idempotent_plan(
            LedgerOperationKind::Reserve,
            idempotency_key,
            existing.id,
        ));
    }

    if find_active_settle_for_request(existing_entries, request.request_id).is_some() {
        return Err(LedgerContractError::RequestAlreadySettled {
            request_id: request.request_id,
        });
    }

    if find_active_reserve_for_request(existing_entries, request.request_id).is_some() {
        return Err(LedgerContractError::RequestAlreadyReserved {
            request_id: request.request_id,
        });
    }

    Ok(apply_plan(
        LedgerOperationKind::Reserve,
        idempotency_key,
        draft,
    ))
}

pub fn plan_ledger_settle(
    request: SettleLedgerRequest,
    existing_entries: &[LedgerEntryRecord],
) -> Result<LedgerOperationPlan, LedgerContractError> {
    let metadata = LedgerEntryMetadata::settle(request.request_id);
    plan_ledger_settle_with_metadata(request, existing_entries, metadata)
}

pub(crate) fn plan_ledger_settle_with_metadata(
    request: SettleLedgerRequest,
    existing_entries: &[LedgerEntryRecord],
    metadata: LedgerEntryMetadata,
) -> Result<LedgerOperationPlan, LedgerContractError> {
    validate_currency(&request.currency)?;
    let amount = debit_amount("final_cost", request.final_cost)?;
    let idempotency_key = settle_ledger_idempotency_key(request.request_id);

    let draft = LedgerEntryDraft {
        request_id: Some(request.request_id),
        related_ledger_entry_id: None,
        entry_type: LedgerEntryType::Settle,
        amount,
        currency: request.currency,
        status: LedgerEntryStatus::Confirmed,
        idempotency_key: idempotency_key.clone(),
        metadata,
    };

    if let Some(existing) = find_by_idempotency_key(existing_entries, &idempotency_key) {
        ensure_existing_matches_draft(existing, &draft)?;
        return Ok(idempotent_plan(
            LedgerOperationKind::Settle,
            idempotency_key,
            existing.id,
        ));
    }

    if find_active_settle_for_request(existing_entries, request.request_id).is_some() {
        return Err(LedgerContractError::RequestAlreadySettled {
            request_id: request.request_id,
        });
    }

    let status_updates =
        pending_reserve_updates_for_settle(existing_entries, request.request_id, &draft.currency)?;

    Ok(LedgerOperationPlan {
        operation: LedgerOperationKind::Settle,
        idempotency_key,
        outcome: LedgerOperationOutcome::Apply,
        entries: vec![draft],
        status_updates,
    })
}

pub fn plan_ledger_refund(
    request: RefundLedgerRequest,
    existing_entries: &[LedgerEntryRecord],
) -> Result<LedgerOperationPlan, LedgerContractError> {
    let refund = normalize_refund_request(request)?;
    validate_currency(&refund.currency)?;

    let source = find_refund_source(existing_entries, refund.related_ledger_entry_id)?;
    if source.currency != refund.currency {
        return Err(LedgerContractError::RefundCurrencyMismatch {
            expected: source.currency.clone(),
            actual: refund.currency,
        });
    }

    if let Some(existing) = find_by_idempotency_key(existing_entries, &refund.idempotency_key) {
        let remaining_excluding_existing =
            remaining_refundable_amount_excluding(source, existing_entries, existing.id)?;
        ensure_existing_matches_refund(existing, &refund, remaining_excluding_existing)?;
        return Ok(idempotent_plan(
            refund.operation,
            refund.idempotency_key,
            existing.id,
        ));
    }

    let remaining = remaining_refundable_amount(source, existing_entries)?;
    let amount = match refund.kind {
        LedgerRefundKind::Full => remaining,
        LedgerRefundKind::Partial => {
            let requested = refund
                .amount
                .ok_or(LedgerContractError::PartialRefundAmountRequired)?;
            require_positive("amount", requested)?;
            ensure_same_scale(remaining, requested)?;
            if requested >= remaining {
                return Err(LedgerContractError::PartialRefundConsumesRemaining {
                    requested,
                    remaining,
                });
            }
            requested
        }
    };

    require_positive("remaining_refundable_amount", amount)?;
    if amount > remaining {
        return Err(LedgerContractError::RefundAmountExceedsRemaining {
            requested: amount,
            remaining,
        });
    }

    let draft = LedgerEntryDraft {
        request_id: source.request_id,
        related_ledger_entry_id: Some(source.id),
        entry_type: LedgerEntryType::Refund,
        amount,
        currency: source.currency.clone(),
        status: LedgerEntryStatus::Confirmed,
        idempotency_key: refund.idempotency_key.clone(),
        metadata: LedgerEntryMetadata::refund(source.id, refund.kind),
    };

    Ok(apply_plan(refund.operation, refund.idempotency_key, draft))
}

fn apply_plan(
    operation: LedgerOperationKind,
    idempotency_key: String,
    draft: LedgerEntryDraft,
) -> LedgerOperationPlan {
    LedgerOperationPlan {
        operation,
        idempotency_key,
        outcome: LedgerOperationOutcome::Apply,
        entries: vec![draft],
        status_updates: Vec::new(),
    }
}

fn idempotent_plan(
    operation: LedgerOperationKind,
    idempotency_key: String,
    existing_entry_id: Uuid,
) -> LedgerOperationPlan {
    LedgerOperationPlan {
        operation,
        idempotency_key,
        outcome: LedgerOperationOutcome::Idempotent { existing_entry_id },
        entries: Vec::new(),
        status_updates: Vec::new(),
    }
}

fn debit_amount(
    field: &'static str,
    amount: FixedDecimal,
) -> Result<FixedDecimal, LedgerContractError> {
    require_positive(field, amount)?;
    checked_neg(amount)
}

fn require_positive(field: &'static str, amount: FixedDecimal) -> Result<(), LedgerContractError> {
    if amount.units() > 0 {
        Ok(())
    } else {
        Err(LedgerContractError::NonPositiveAmount { field })
    }
}

fn validate_currency(currency: &str) -> Result<(), LedgerContractError> {
    let mut characters = currency.chars();
    let Some(first) = characters.next() else {
        return Err(LedgerContractError::InvalidCurrency {
            currency: currency.to_string(),
        });
    };

    let valid = first.is_ascii_uppercase()
        && currency.len() >= 3
        && currency.len() <= 32
        && characters.all(|character| {
            character.is_ascii_uppercase() || character.is_ascii_digit() || character == '_'
        });

    if valid {
        Ok(())
    } else {
        Err(LedgerContractError::InvalidCurrency {
            currency: currency.to_string(),
        })
    }
}

fn find_by_idempotency_key<'a>(
    existing_entries: &'a [LedgerEntryRecord],
    idempotency_key: &str,
) -> Option<&'a LedgerEntryRecord> {
    existing_entries
        .iter()
        .find(|entry| entry.idempotency_key == idempotency_key)
}

fn find_active_reserve_for_request(
    existing_entries: &[LedgerEntryRecord],
    request_id: Uuid,
) -> Option<&LedgerEntryRecord> {
    existing_entries.iter().find(|entry| {
        entry.request_id == Some(request_id)
            && entry.entry_type == LedgerEntryType::Reserve
            && matches!(
                entry.status,
                LedgerEntryStatus::Pending | LedgerEntryStatus::Confirmed
            )
    })
}

fn find_active_settle_for_request(
    existing_entries: &[LedgerEntryRecord],
    request_id: Uuid,
) -> Option<&LedgerEntryRecord> {
    existing_entries.iter().find(|entry| {
        entry.request_id == Some(request_id)
            && entry.entry_type == LedgerEntryType::Settle
            && matches!(
                entry.status,
                LedgerEntryStatus::Pending | LedgerEntryStatus::Confirmed
            )
    })
}

fn pending_reserve_updates_for_settle(
    existing_entries: &[LedgerEntryRecord],
    request_id: Uuid,
    settle_currency: &str,
) -> Result<Vec<LedgerStatusUpdate>, LedgerContractError> {
    existing_entries
        .iter()
        .filter(|entry| {
            entry.request_id == Some(request_id)
                && entry.entry_type == LedgerEntryType::Reserve
                && entry.status == LedgerEntryStatus::Pending
        })
        .map(|entry| {
            if entry.currency != settle_currency {
                return Err(LedgerContractError::ReserveCurrencyMismatch {
                    reserve_currency: entry.currency.clone(),
                    settle_currency: settle_currency.to_string(),
                });
            }

            Ok(LedgerStatusUpdate {
                ledger_entry_id: entry.id,
                from: LedgerEntryStatus::Pending,
                to: LedgerEntryStatus::Reversed,
                reason: LedgerStatusUpdateReason::ReserveSettled,
            })
        })
        .collect()
}

fn find_refund_source(
    existing_entries: &[LedgerEntryRecord],
    related_ledger_entry_id: Uuid,
) -> Result<&LedgerEntryRecord, LedgerContractError> {
    let source = existing_entries
        .iter()
        .find(|entry| entry.id == related_ledger_entry_id)
        .ok_or(LedgerContractError::RefundSourceNotFound {
            ledger_entry_id: related_ledger_entry_id,
        })?;

    if source.entry_type != LedgerEntryType::Settle
        || source.status != LedgerEntryStatus::Confirmed
        || source.amount.units() >= 0
    {
        return Err(LedgerContractError::RefundSourceNotConfirmedSettleDebit {
            ledger_entry_id: related_ledger_entry_id,
        });
    }

    Ok(source)
}

fn remaining_refundable_amount(
    source: &LedgerEntryRecord,
    existing_entries: &[LedgerEntryRecord],
) -> Result<FixedDecimal, LedgerContractError> {
    remaining_refundable_amount_excluding(source, existing_entries, Uuid::nil())
}

fn remaining_refundable_amount_excluding(
    source: &LedgerEntryRecord,
    existing_entries: &[LedgerEntryRecord],
    excluded_entry_id: Uuid,
) -> Result<FixedDecimal, LedgerContractError> {
    let zero = FixedDecimal::zero(source.amount.scale())
        .map_err(|_| LedgerContractError::ArithmeticOverflow)?;
    let debited = checked_neg(source.amount)?;
    let refunded = existing_entries
        .iter()
        .filter(|entry| {
            entry.related_ledger_entry_id == Some(source.id)
                && entry.id != excluded_entry_id
                && entry.entry_type == LedgerEntryType::Refund
                && matches!(
                    entry.status,
                    LedgerEntryStatus::Pending | LedgerEntryStatus::Confirmed
                )
        })
        .try_fold(zero, |total, entry| {
            require_positive("refund.amount", entry.amount)?;
            total
                .checked_add(entry.amount)
                .map_err(|_| LedgerContractError::ArithmeticOverflow)
        })?;

    checked_subtract(debited, refunded)
}

fn ensure_existing_matches_draft(
    existing: &LedgerEntryRecord,
    draft: &LedgerEntryDraft,
) -> Result<(), LedgerContractError> {
    let status_matches = existing.status == draft.status
        || (draft.entry_type == LedgerEntryType::Reserve
            && draft.status == LedgerEntryStatus::Pending
            && existing.status == LedgerEntryStatus::Reversed);

    if existing.request_id == draft.request_id
        && existing.related_ledger_entry_id == draft.related_ledger_entry_id
        && existing.entry_type == draft.entry_type
        && existing.amount == draft.amount
        && existing.currency == draft.currency
        && status_matches
    {
        Ok(())
    } else {
        Err(LedgerContractError::IdempotencyConflict {
            key: draft.idempotency_key.clone(),
        })
    }
}

fn ensure_existing_matches_refund(
    existing: &LedgerEntryRecord,
    refund: &NormalizedRefundRequest,
    remaining_excluding_existing: FixedDecimal,
) -> Result<(), LedgerContractError> {
    let idempotent = existing.related_ledger_entry_id == Some(refund.related_ledger_entry_id)
        && existing.entry_type == LedgerEntryType::Refund
        && existing.status == LedgerEntryStatus::Confirmed
        && existing.currency == refund.currency
        && existing.amount.units() > 0;

    if !idempotent {
        return Err(LedgerContractError::IdempotencyConflict {
            key: refund.idempotency_key.clone(),
        });
    }

    let expected_amount = refund.amount.unwrap_or(remaining_excluding_existing);
    if existing.amount != expected_amount {
        return Err(LedgerContractError::IdempotencyConflict {
            key: refund.idempotency_key.clone(),
        });
    }

    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct NormalizedRefundRequest {
    related_ledger_entry_id: Uuid,
    amount: Option<FixedDecimal>,
    currency: String,
    kind: LedgerRefundKind,
    operation: LedgerOperationKind,
    idempotency_key: String,
}

fn normalize_refund_request(
    request: RefundLedgerRequest,
) -> Result<NormalizedRefundRequest, LedgerContractError> {
    match request {
        RefundLedgerRequest::Full {
            related_ledger_entry_id,
            currency,
            amount,
        } => {
            if amount.is_some() {
                return Err(LedgerContractError::FullRefundAmountNotAllowed);
            }

            Ok(NormalizedRefundRequest {
                related_ledger_entry_id,
                amount,
                currency,
                kind: LedgerRefundKind::Full,
                operation: LedgerOperationKind::Refund,
                idempotency_key: refund_ledger_idempotency_key(related_ledger_entry_id),
            })
        }
        RefundLedgerRequest::Partial {
            related_ledger_entry_id,
            refund_operation_id,
            amount,
            currency,
        } => {
            let refund_operation_id =
                refund_operation_id.ok_or(LedgerContractError::PartialRefundOperationIdRequired)?;

            Ok(NormalizedRefundRequest {
                related_ledger_entry_id,
                amount,
                currency,
                kind: LedgerRefundKind::Partial,
                operation: LedgerOperationKind::RefundPartial,
                idempotency_key: refund_partial_ledger_idempotency_key(
                    related_ledger_entry_id,
                    refund_operation_id,
                ),
            })
        }
    }
}

impl LedgerEntryMetadata {
    fn reserve(request_id: Uuid) -> Self {
        Self {
            operation: LedgerOperationKind::Reserve,
            request_id: Some(request_id),
            related_ledger_entry_id: None,
            refund_kind: None,
            exact_cache: None,
        }
    }

    fn settle(request_id: Uuid) -> Self {
        Self {
            operation: LedgerOperationKind::Settle,
            request_id: Some(request_id),
            related_ledger_entry_id: None,
            refund_kind: None,
            exact_cache: None,
        }
    }

    pub(crate) fn settle_with_exact_cache(
        request_id: Uuid,
        exact_cache: ExactCacheLedgerMetadata,
    ) -> Self {
        Self {
            operation: LedgerOperationKind::Settle,
            request_id: Some(request_id),
            related_ledger_entry_id: None,
            refund_kind: None,
            exact_cache: Some(exact_cache),
        }
    }

    fn refund(related_ledger_entry_id: Uuid, refund_kind: LedgerRefundKind) -> Self {
        Self {
            operation: match refund_kind {
                LedgerRefundKind::Full => LedgerOperationKind::Refund,
                LedgerRefundKind::Partial => LedgerOperationKind::RefundPartial,
            },
            request_id: None,
            related_ledger_entry_id: Some(related_ledger_entry_id),
            refund_kind: Some(refund_kind),
            exact_cache: None,
        }
    }
}

fn checked_neg(value: FixedDecimal) -> Result<FixedDecimal, LedgerContractError> {
    let units = value
        .units()
        .checked_neg()
        .ok_or(LedgerContractError::ArithmeticOverflow)?;
    FixedDecimal::from_units(units, value.scale())
        .map_err(|_| LedgerContractError::ArithmeticOverflow)
}

fn checked_subtract(
    left: FixedDecimal,
    right: FixedDecimal,
) -> Result<FixedDecimal, LedgerContractError> {
    ensure_same_scale(left, right)?;
    left.checked_add(checked_neg(right)?)
        .map_err(|_| LedgerContractError::ArithmeticOverflow)
}

fn ensure_same_scale(
    expected: FixedDecimal,
    actual: FixedDecimal,
) -> Result<(), LedgerContractError> {
    if expected.scale() == actual.scale() {
        Ok(())
    } else {
        Err(LedgerContractError::ScaleMismatch {
            expected: expected.scale(),
            actual: actual.scale(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::DEFAULT_MONEY_SCALE;

    const REQUEST_ID: Uuid = Uuid::from_u128(11);
    const RESERVE_ID: Uuid = Uuid::from_u128(21);
    const SETTLE_ID: Uuid = Uuid::from_u128(31);
    const REFUND_ID: Uuid = Uuid::from_u128(41);
    const REFUND_OPERATION_ID: Uuid = Uuid::from_u128(51);

    #[test]
    fn ledger_reserve_plans_pending_debit_with_canonical_idempotency_key() {
        let plan = plan_ledger_reserve(
            ReserveLedgerRequest {
                request_id: REQUEST_ID,
                amount: money("1.25000000"),
                currency: "USD".to_string(),
            },
            &[],
        )
        .expect("reserve should plan");

        assert_eq!(plan.operation, LedgerOperationKind::Reserve);
        assert_eq!(plan.idempotency_key, format!("reserve:{REQUEST_ID}"));
        assert_eq!(plan.outcome, LedgerOperationOutcome::Apply);
        assert!(plan.status_updates.is_empty());
        assert_eq!(plan.entries.len(), 1);
        assert_eq!(plan.entries[0].entry_type, LedgerEntryType::Reserve);
        assert_eq!(plan.entries[0].status, LedgerEntryStatus::Pending);
        assert_eq!(plan.entries[0].amount.to_string(), "-1.25000000");
        assert_eq!(
            plan.entries[0].metadata.operation,
            LedgerOperationKind::Reserve
        );
    }

    #[test]
    fn ledger_reserve_replay_is_idempotent_and_conflicting_replay_is_rejected() {
        let existing = reserve_record("-1.25000000", "USD");

        let replay = plan_ledger_reserve(
            ReserveLedgerRequest {
                request_id: REQUEST_ID,
                amount: money("1.25000000"),
                currency: "USD".to_string(),
            },
            std::slice::from_ref(&existing),
        )
        .expect("same reserve should be idempotent");

        assert_eq!(
            replay.outcome,
            LedgerOperationOutcome::Idempotent {
                existing_entry_id: RESERVE_ID
            }
        );
        assert!(replay.entries.is_empty());

        let mut settled_reserve = existing.clone();
        settled_reserve.status = LedgerEntryStatus::Reversed;
        let settled_replay = plan_ledger_reserve(
            ReserveLedgerRequest {
                request_id: REQUEST_ID,
                amount: money("1.25000000"),
                currency: "USD".to_string(),
            },
            &[settled_reserve],
        )
        .expect("same reserve should stay idempotent after settle reverses the hold");

        assert_eq!(
            settled_replay.outcome,
            LedgerOperationOutcome::Idempotent {
                existing_entry_id: RESERVE_ID
            }
        );
        assert!(settled_replay.entries.is_empty());

        let conflict = plan_ledger_reserve(
            ReserveLedgerRequest {
                request_id: REQUEST_ID,
                amount: money("2.00000000"),
                currency: "USD".to_string(),
            },
            &[existing],
        )
        .expect_err("same key with different amount should conflict");

        assert!(matches!(
            conflict,
            LedgerContractError::IdempotencyConflict { .. }
        ));
    }

    #[test]
    fn ledger_settle_plans_confirmed_debit_and_reverses_pending_reserve() {
        let reserve = reserve_record("-1.25000000", "USD");
        let plan = plan_ledger_settle(
            SettleLedgerRequest {
                request_id: REQUEST_ID,
                final_cost: money("0.75000000"),
                currency: "USD".to_string(),
            },
            &[reserve],
        )
        .expect("settle should plan");

        assert_eq!(plan.operation, LedgerOperationKind::Settle);
        assert_eq!(plan.idempotency_key, format!("settle:{REQUEST_ID}"));
        assert_eq!(plan.entries.len(), 1);
        assert_eq!(plan.entries[0].entry_type, LedgerEntryType::Settle);
        assert_eq!(plan.entries[0].status, LedgerEntryStatus::Confirmed);
        assert_eq!(plan.entries[0].amount.to_string(), "-0.75000000");
        assert_eq!(
            plan.status_updates,
            vec![LedgerStatusUpdate {
                ledger_entry_id: RESERVE_ID,
                from: LedgerEntryStatus::Pending,
                to: LedgerEntryStatus::Reversed,
                reason: LedgerStatusUpdateReason::ReserveSettled,
            }]
        );
    }

    #[test]
    fn ledger_settle_replay_is_idempotent_and_duplicate_request_is_rejected() {
        let existing = settle_record(SETTLE_ID, REQUEST_ID, "-0.75000000", "USD");

        let replay = plan_ledger_settle(
            SettleLedgerRequest {
                request_id: REQUEST_ID,
                final_cost: money("0.75000000"),
                currency: "USD".to_string(),
            },
            std::slice::from_ref(&existing),
        )
        .expect("same settle should be idempotent");

        assert_eq!(
            replay.outcome,
            LedgerOperationOutcome::Idempotent {
                existing_entry_id: SETTLE_ID
            }
        );
        assert!(replay.entries.is_empty());

        let mut legacy_key = existing;
        legacy_key.idempotency_key = "legacy-settle-key".to_string();

        let duplicate = plan_ledger_settle(
            SettleLedgerRequest {
                request_id: REQUEST_ID,
                final_cost: money("0.75000000"),
                currency: "USD".to_string(),
            },
            &[legacy_key],
        )
        .expect_err("one active settle per request should be enforced");

        assert_eq!(
            duplicate,
            LedgerContractError::RequestAlreadySettled {
                request_id: REQUEST_ID
            }
        );
    }

    #[test]
    fn ledger_rejects_non_positive_debits_and_invalid_currency() {
        assert!(matches!(
            plan_ledger_reserve(
                ReserveLedgerRequest {
                    request_id: REQUEST_ID,
                    amount: money("0.00000000"),
                    currency: "USD".to_string(),
                },
                &[],
            ),
            Err(LedgerContractError::NonPositiveAmount { field: "amount" })
        ));

        assert!(matches!(
            plan_ledger_settle(
                SettleLedgerRequest {
                    request_id: REQUEST_ID,
                    final_cost: money("-0.01000000"),
                    currency: "usd".to_string(),
                },
                &[],
            ),
            Err(LedgerContractError::InvalidCurrency { currency }) if currency == "usd"
        ));
    }

    #[test]
    fn ledger_partial_refund_plans_confirmed_positive_credit_and_is_idempotent() {
        let source = settle_record(SETTLE_ID, REQUEST_ID, "-1.00000000", "USD");
        let plan = plan_ledger_refund(
            RefundLedgerRequest::Partial {
                related_ledger_entry_id: SETTLE_ID,
                refund_operation_id: Some(REFUND_OPERATION_ID),
                amount: Some(money("0.25000000")),
                currency: "USD".to_string(),
            },
            std::slice::from_ref(&source),
        )
        .expect("partial refund should plan");

        assert_eq!(plan.operation, LedgerOperationKind::RefundPartial);
        assert_eq!(
            plan.idempotency_key,
            format!("refund_partial:{SETTLE_ID}:{REFUND_OPERATION_ID}")
        );
        assert_eq!(plan.entries.len(), 1);
        assert_eq!(plan.entries[0].entry_type, LedgerEntryType::Refund);
        assert_eq!(plan.entries[0].status, LedgerEntryStatus::Confirmed);
        assert_eq!(plan.entries[0].amount.to_string(), "0.25000000");
        assert_eq!(plan.entries[0].related_ledger_entry_id, Some(SETTLE_ID));
        assert_eq!(
            plan.entries[0].metadata.refund_kind,
            Some(LedgerRefundKind::Partial)
        );

        let mut existing_refund = refund_record(REFUND_ID, SETTLE_ID, "0.25000000", "USD");
        existing_refund.idempotency_key = plan.idempotency_key.clone();

        let replay = plan_ledger_refund(
            RefundLedgerRequest::Partial {
                related_ledger_entry_id: SETTLE_ID,
                refund_operation_id: Some(REFUND_OPERATION_ID),
                amount: Some(money("0.25000000")),
                currency: "USD".to_string(),
            },
            &[source, existing_refund],
        )
        .expect("same partial refund should be idempotent");

        assert_eq!(
            replay.outcome,
            LedgerOperationOutcome::Idempotent {
                existing_entry_id: REFUND_ID
            }
        );
        assert!(replay.entries.is_empty());
    }

    #[test]
    fn ledger_full_refund_refunds_remaining_after_partial_refunds() {
        let source = settle_record(SETTLE_ID, REQUEST_ID, "-1.00000000", "USD");
        let mut partial = refund_record(REFUND_ID, SETTLE_ID, "0.25000000", "USD");
        partial.idempotency_key =
            refund_partial_ledger_idempotency_key(SETTLE_ID, REFUND_OPERATION_ID);

        let plan = plan_ledger_refund(
            RefundLedgerRequest::Full {
                related_ledger_entry_id: SETTLE_ID,
                currency: "USD".to_string(),
                amount: None,
            },
            &[source, partial],
        )
        .expect("full refund should plan remaining amount");

        assert_eq!(plan.operation, LedgerOperationKind::Refund);
        assert_eq!(plan.idempotency_key, format!("refund:{SETTLE_ID}"));
        assert_eq!(plan.entries[0].amount.to_string(), "0.75000000");
        assert_eq!(
            plan.entries[0].metadata.refund_kind,
            Some(LedgerRefundKind::Full)
        );
    }

    #[test]
    fn ledger_refund_validates_source_currency_and_remaining_amount() {
        let source = settle_record(SETTLE_ID, REQUEST_ID, "-1.00000000", "USD");

        let wrong_currency = plan_ledger_refund(
            RefundLedgerRequest::Full {
                related_ledger_entry_id: SETTLE_ID,
                currency: "EUR".to_string(),
                amount: None,
            },
            std::slice::from_ref(&source),
        )
        .expect_err("refund currency must match source");

        assert_eq!(
            wrong_currency,
            LedgerContractError::RefundCurrencyMismatch {
                expected: "USD".to_string(),
                actual: "EUR".to_string(),
            }
        );

        let equal_remaining_partial = plan_ledger_refund(
            RefundLedgerRequest::Partial {
                related_ledger_entry_id: SETTLE_ID,
                refund_operation_id: Some(REFUND_OPERATION_ID),
                amount: Some(money("1.00000000")),
                currency: "USD".to_string(),
            },
            std::slice::from_ref(&source),
        )
        .expect_err("partial refund should not consume the whole remaining amount");

        assert!(matches!(
            equal_remaining_partial,
            LedgerContractError::PartialRefundConsumesRemaining { .. }
        ));

        let reserve = reserve_record("-1.00000000", "USD");
        let invalid_source = plan_ledger_refund(
            RefundLedgerRequest::Full {
                related_ledger_entry_id: RESERVE_ID,
                currency: "USD".to_string(),
                amount: None,
            },
            &[reserve],
        )
        .expect_err("refund source must be a confirmed settle debit");

        assert_eq!(
            invalid_source,
            LedgerContractError::RefundSourceNotConfirmedSettleDebit {
                ledger_entry_id: RESERVE_ID
            }
        );
    }

    #[test]
    fn ledger_metadata_is_contract_safe_and_does_not_carry_payload_secret_or_raw_key() {
        let plan = plan_ledger_settle(
            SettleLedgerRequest {
                request_id: REQUEST_ID,
                final_cost: money("0.75000000"),
                currency: "USD".to_string(),
            },
            &[],
        )
        .expect("settle should plan");

        let serialized_metadata =
            serde_json::to_string(&plan.entries[0].metadata).expect("metadata should serialize");

        assert_eq!(
            serialized_metadata,
            format!(r#"{{"operation":"settle","request_id":"{REQUEST_ID}"}}"#)
        );
        assert!(!serialized_metadata.contains("payload"));
        assert!(!serialized_metadata.contains("secret"));
        assert!(!serialized_metadata.contains("raw_key"));
        assert!(!serialized_metadata.contains("idempotency_key"));
    }

    fn money(value: &str) -> FixedDecimal {
        FixedDecimal::parse(value, DEFAULT_MONEY_SCALE).expect("valid money")
    }

    fn reserve_record(amount: &str, currency: &str) -> LedgerEntryRecord {
        LedgerEntryRecord {
            id: RESERVE_ID,
            request_id: Some(REQUEST_ID),
            related_ledger_entry_id: None,
            entry_type: LedgerEntryType::Reserve,
            amount: money(amount),
            currency: currency.to_string(),
            status: LedgerEntryStatus::Pending,
            idempotency_key: reserve_ledger_idempotency_key(REQUEST_ID),
        }
    }

    fn settle_record(
        id: Uuid,
        request_id: Uuid,
        amount: &str,
        currency: &str,
    ) -> LedgerEntryRecord {
        LedgerEntryRecord {
            id,
            request_id: Some(request_id),
            related_ledger_entry_id: None,
            entry_type: LedgerEntryType::Settle,
            amount: money(amount),
            currency: currency.to_string(),
            status: LedgerEntryStatus::Confirmed,
            idempotency_key: settle_ledger_idempotency_key(request_id),
        }
    }

    fn refund_record(
        id: Uuid,
        related_ledger_entry_id: Uuid,
        amount: &str,
        currency: &str,
    ) -> LedgerEntryRecord {
        LedgerEntryRecord {
            id,
            request_id: Some(REQUEST_ID),
            related_ledger_entry_id: Some(related_ledger_entry_id),
            entry_type: LedgerEntryType::Refund,
            amount: money(amount),
            currency: currency.to_string(),
            status: LedgerEntryStatus::Confirmed,
            idempotency_key: refund_ledger_idempotency_key(related_ledger_entry_id),
        }
    }
}
