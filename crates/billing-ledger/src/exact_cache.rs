use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

use crate::{
    FixedDecimal, LedgerContractError, LedgerEntryRecord, LedgerOperationPlan, RatingError,
    SettleLedgerRequest, settle_ledger_idempotency_key,
};

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum ExactCacheBillingError {
    #[error("exact cache key must be a sha256 digest")]
    InvalidCacheKeyHash,
    #[error("exact cache hit requires a cache entry id")]
    CacheHitEntryIdRequired,
    #[error("exact cache money field `{field}` must not be negative")]
    NegativeMoney { field: &'static str },
    #[error(transparent)]
    Rating(#[from] RatingError),
    #[error(transparent)]
    Ledger(#[from] LedgerContractError),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ExactCacheStatus {
    Hit,
    Miss,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ExactCacheReadPolicy {
    Disabled,
    DiscountedInputTokens,
    FixedCost,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ExactCacheWritePolicy {
    Disabled,
    TokenRate,
    FixedCost,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExactCachePricingRules {
    pub currency: String,
    pub scale: u32,
    pub input_token_rate_per_million: FixedDecimal,
    pub output_token_rate_per_million: FixedDecimal,
    pub cache_read_token_rate_per_million: FixedDecimal,
    pub cache_write_token_rate_per_million: FixedDecimal,
    pub fixed_cache_read_cost: FixedDecimal,
    pub fixed_cache_write_cost: FixedDecimal,
    pub fixed_request_cost: FixedDecimal,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExactCacheBillingRequest {
    pub request_id: Uuid,
    pub cache_status: ExactCacheStatus,
    pub cache_key_hash: String,
    pub cache_entry_id: Option<Uuid>,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_write_tokens: u64,
    pub read_policy: ExactCacheReadPolicy,
    pub write_policy: ExactCacheWritePolicy,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ExactCacheRatingResult {
    pub cache_status: ExactCacheStatus,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_write_tokens: u64,
    pub read_policy: ExactCacheReadPolicy,
    pub write_policy: ExactCacheWritePolicy,
    pub input_cost: FixedDecimal,
    pub output_cost: FixedDecimal,
    pub cache_read_cost: FixedDecimal,
    pub cache_write_cost: FixedDecimal,
    pub fixed_request_cost: FixedDecimal,
    pub total_cost: FixedDecimal,
    pub currency: String,
    pub scale: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ExactCacheBillingPlan {
    pub cache_status: ExactCacheStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_operation_idempotency_key: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ledger_idempotency_key: Option<String>,
    pub rating: ExactCacheRatingResult,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ledger_plan: Option<LedgerOperationPlan>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExactCacheLedgerMetadata {
    pub status: ExactCacheStatus,
    pub cache_key_hash: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_entry_id: Option<Uuid>,
    pub read_policy: ExactCacheReadPolicy,
    pub write_policy: ExactCacheWritePolicy,
    pub usage_summary: ExactCacheUsageSummary,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExactCacheUsageSummary {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_write_tokens: u64,
}

pub fn exact_cache_read_idempotency_key(
    request_id: Uuid,
    cache_key_hash: &str,
) -> Result<String, ExactCacheBillingError> {
    validate_cache_key_hash(cache_key_hash)?;
    Ok(format!("exact_cache:read:{request_id}:{cache_key_hash}"))
}

pub fn exact_cache_write_idempotency_key(
    request_id: Uuid,
    cache_key_hash: &str,
) -> Result<String, ExactCacheBillingError> {
    validate_cache_key_hash(cache_key_hash)?;
    Ok(format!("exact_cache:write:{request_id}:{cache_key_hash}"))
}

pub fn plan_exact_cache_billing(
    request: ExactCacheBillingRequest,
    pricing: &ExactCachePricingRules,
    existing_entries: &[LedgerEntryRecord],
) -> Result<ExactCacheBillingPlan, ExactCacheBillingError> {
    validate_cache_key_hash(&request.cache_key_hash)?;
    if request.cache_status == ExactCacheStatus::Hit && request.cache_entry_id.is_none() {
        return Err(ExactCacheBillingError::CacheHitEntryIdRequired);
    }

    let cache_operation_idempotency_key = match request.cache_status {
        ExactCacheStatus::Hit => Some(exact_cache_read_idempotency_key(
            request.request_id,
            &request.cache_key_hash,
        )?),
        ExactCacheStatus::Miss if request.write_policy != ExactCacheWritePolicy::Disabled => Some(
            exact_cache_write_idempotency_key(request.request_id, &request.cache_key_hash)?,
        ),
        ExactCacheStatus::Miss => None,
    };

    let rating = rate_exact_cache_request(&request, pricing)?;
    let ledger_idempotency_key = if rating.total_cost.is_zero() {
        None
    } else {
        Some(settle_ledger_idempotency_key(request.request_id))
    };
    let ledger_plan = if rating.total_cost.is_zero() {
        None
    } else {
        Some(crate::ledger::plan_ledger_settle_with_metadata(
            SettleLedgerRequest {
                request_id: request.request_id,
                final_cost: rating.total_cost,
                currency: rating.currency.clone(),
            },
            existing_entries,
            crate::ledger::LedgerEntryMetadata::settle_with_exact_cache(
                request.request_id,
                ExactCacheLedgerMetadata {
                    status: request.cache_status,
                    cache_key_hash: request.cache_key_hash.clone(),
                    cache_entry_id: request.cache_entry_id,
                    read_policy: request.read_policy,
                    write_policy: request.write_policy,
                    usage_summary: ExactCacheUsageSummary {
                        input_tokens: request.input_tokens,
                        output_tokens: request.output_tokens,
                        cache_read_tokens: request.cache_read_tokens,
                        cache_write_tokens: request.cache_write_tokens,
                    },
                },
            ),
        )?)
    };

    Ok(ExactCacheBillingPlan {
        cache_status: request.cache_status,
        cache_operation_idempotency_key,
        ledger_idempotency_key,
        rating,
        ledger_plan,
    })
}

fn rate_exact_cache_request(
    request: &ExactCacheBillingRequest,
    pricing: &ExactCachePricingRules,
) -> Result<ExactCacheRatingResult, ExactCacheBillingError> {
    ensure_pricing_is_non_negative(pricing)?;

    let zero = FixedDecimal::zero(pricing.scale)?;
    let (input_cost, output_cost, fixed_request_cost) = match request.cache_status {
        ExactCacheStatus::Hit => (zero, zero, zero),
        ExactCacheStatus::Miss => (
            crate::rating::rate_tokens(request.input_tokens, pricing.input_token_rate_per_million)?,
            crate::rating::rate_tokens(
                request.output_tokens,
                pricing.output_token_rate_per_million,
            )?,
            pricing.fixed_request_cost,
        ),
    };

    let cache_read_cost = match (request.cache_status, request.read_policy) {
        (ExactCacheStatus::Hit, ExactCacheReadPolicy::DiscountedInputTokens) => {
            crate::rating::rate_tokens(
                request.cache_read_tokens,
                pricing.cache_read_token_rate_per_million,
            )?
        }
        (ExactCacheStatus::Hit, ExactCacheReadPolicy::FixedCost) => pricing.fixed_cache_read_cost,
        _ => zero,
    };

    let cache_write_cost = match (request.cache_status, request.write_policy) {
        (ExactCacheStatus::Miss, ExactCacheWritePolicy::TokenRate) => crate::rating::rate_tokens(
            request.cache_write_tokens,
            pricing.cache_write_token_rate_per_million,
        )?,
        (ExactCacheStatus::Miss, ExactCacheWritePolicy::FixedCost) => {
            pricing.fixed_cache_write_cost
        }
        _ => zero,
    };

    let total_cost = input_cost
        .checked_add(output_cost)?
        .checked_add(cache_read_cost)?
        .checked_add(cache_write_cost)?
        .checked_add(fixed_request_cost)?;

    Ok(ExactCacheRatingResult {
        cache_status: request.cache_status,
        input_tokens: request.input_tokens,
        output_tokens: request.output_tokens,
        cache_read_tokens: request.cache_read_tokens,
        cache_write_tokens: request.cache_write_tokens,
        read_policy: request.read_policy,
        write_policy: request.write_policy,
        input_cost,
        output_cost,
        cache_read_cost,
        cache_write_cost,
        fixed_request_cost,
        total_cost,
        currency: pricing.currency.clone(),
        scale: pricing.scale,
    })
}

fn validate_cache_key_hash(cache_key_hash: &str) -> Result<(), ExactCacheBillingError> {
    let Some(digest) = cache_key_hash.strip_prefix("sha256:") else {
        return Err(ExactCacheBillingError::InvalidCacheKeyHash);
    };

    if digest.len() == 64
        && digest
            .chars()
            .all(|character| character.is_ascii_hexdigit())
    {
        Ok(())
    } else {
        Err(ExactCacheBillingError::InvalidCacheKeyHash)
    }
}

fn ensure_pricing_is_non_negative(
    pricing: &ExactCachePricingRules,
) -> Result<(), ExactCacheBillingError> {
    ensure_non_negative_money(
        "input_token_rate_per_million",
        pricing.input_token_rate_per_million,
    )?;
    ensure_non_negative_money(
        "output_token_rate_per_million",
        pricing.output_token_rate_per_million,
    )?;
    ensure_non_negative_money(
        "cache_read_token_rate_per_million",
        pricing.cache_read_token_rate_per_million,
    )?;
    ensure_non_negative_money(
        "cache_write_token_rate_per_million",
        pricing.cache_write_token_rate_per_million,
    )?;
    ensure_non_negative_money("fixed_cache_read_cost", pricing.fixed_cache_read_cost)?;
    ensure_non_negative_money("fixed_cache_write_cost", pricing.fixed_cache_write_cost)?;
    ensure_non_negative_money("fixed_request_cost", pricing.fixed_request_cost)?;
    Ok(())
}

fn ensure_non_negative_money(
    field: &'static str,
    amount: FixedDecimal,
) -> Result<(), ExactCacheBillingError> {
    if amount.units() >= 0 {
        Ok(())
    } else {
        Err(ExactCacheBillingError::NegativeMoney { field })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{DEFAULT_MONEY_SCALE, LedgerEntryStatus, LedgerEntryType};

    const REQUEST_ID: Uuid = Uuid::from_u128(101);
    const LEDGER_ID: Uuid = Uuid::from_u128(102);
    const CACHE_ENTRY_ID: Uuid = Uuid::from_u128(103);
    const CACHE_KEY_HASH: &str =
        "sha256:1111111111111111111111111111111111111111111111111111111111111111";

    #[test]
    fn cache_hit_discounted_input_tokens_settles_once_with_safe_metadata() {
        let plan = plan_exact_cache_billing(
            ExactCacheBillingRequest {
                request_id: REQUEST_ID,
                cache_status: ExactCacheStatus::Hit,
                cache_key_hash: CACHE_KEY_HASH.to_string(),
                cache_entry_id: Some(CACHE_ENTRY_ID),
                input_tokens: 1_000,
                output_tokens: 0,
                cache_read_tokens: 1_000,
                cache_write_tokens: 0,
                read_policy: ExactCacheReadPolicy::DiscountedInputTokens,
                write_policy: ExactCacheWritePolicy::Disabled,
            },
            &pricing(),
            &[],
        )
        .expect("cache hit should plan");

        assert_eq!(
            plan.cache_operation_idempotency_key.as_deref(),
            Some(
                "exact_cache:read:00000000-0000-0000-0000-000000000065:sha256:1111111111111111111111111111111111111111111111111111111111111111"
            )
        );
        assert_eq!(
            plan.ledger_idempotency_key,
            Some(format!("settle:{REQUEST_ID}"))
        );
        assert_eq!(plan.rating.total_cost.to_string(), "0.00005000");

        let ledger_plan = plan.ledger_plan.expect("non-zero hit should settle");
        assert_eq!(ledger_plan.entries[0].amount.to_string(), "-0.00005000");
        let metadata =
            serde_json::to_value(&ledger_plan.entries[0].metadata).expect("metadata json");
        assert_eq!(
            metadata["exact_cache"]["cache_key_hash"],
            serde_json::json!(CACHE_KEY_HASH)
        );
        assert!(
            !serde_json::to_string(&metadata)
                .unwrap()
                .contains("idempotency_key")
        );
        assert!(!serde_json::to_string(&metadata).unwrap().contains("raw"));
    }

    #[test]
    fn cache_hit_settle_replay_is_idempotent_and_does_not_double_charge() {
        let existing = LedgerEntryRecord {
            id: LEDGER_ID,
            request_id: Some(REQUEST_ID),
            related_ledger_entry_id: None,
            entry_type: LedgerEntryType::Settle,
            amount: money("-0.00005000"),
            currency: "USD".to_string(),
            status: LedgerEntryStatus::Confirmed,
            idempotency_key: settle_ledger_idempotency_key(REQUEST_ID),
        };

        let plan = plan_exact_cache_billing(
            ExactCacheBillingRequest {
                request_id: REQUEST_ID,
                cache_status: ExactCacheStatus::Hit,
                cache_key_hash: CACHE_KEY_HASH.to_string(),
                cache_entry_id: Some(CACHE_ENTRY_ID),
                input_tokens: 1_000,
                output_tokens: 0,
                cache_read_tokens: 1_000,
                cache_write_tokens: 0,
                read_policy: ExactCacheReadPolicy::DiscountedInputTokens,
                write_policy: ExactCacheWritePolicy::Disabled,
            },
            &pricing(),
            &[existing],
        )
        .expect("cache hit replay should be idempotent");

        let ledger_plan = plan.ledger_plan.expect("non-zero hit should settle");
        assert!(ledger_plan.entries.is_empty());
        assert_eq!(
            ledger_plan.outcome,
            crate::LedgerOperationOutcome::Idempotent {
                existing_entry_id: LEDGER_ID
            }
        );
    }

    #[test]
    fn cache_hash_must_be_digest_only() {
        let error = exact_cache_read_idempotency_key(REQUEST_ID, "cache-entry-id-only")
            .expect_err("raw cache key shape should be rejected");

        assert_eq!(error, ExactCacheBillingError::InvalidCacheKeyHash);
    }

    fn pricing() -> ExactCachePricingRules {
        ExactCachePricingRules {
            currency: "USD".to_string(),
            scale: DEFAULT_MONEY_SCALE,
            input_token_rate_per_million: money("1.00000000"),
            output_token_rate_per_million: money("2.00000000"),
            cache_read_token_rate_per_million: money("0.05000000"),
            cache_write_token_rate_per_million: money("0.02000000"),
            fixed_cache_read_cost: money("0.00100000"),
            fixed_cache_write_cost: money("0.00030000"),
            fixed_request_cost: money("0.00010000"),
        }
    }

    fn money(value: &str) -> FixedDecimal {
        FixedDecimal::parse(value, DEFAULT_MONEY_SCALE).expect("valid money")
    }
}
