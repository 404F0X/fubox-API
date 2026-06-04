use ai_gateway_billing_ledger::{
    ExactCacheBillingError, ExactCacheBillingRequest, ExactCacheDecisionInput,
    ExactCachePricingRules, ExactCacheReadPolicy, ExactCacheStatus, ExactCacheWritePolicy,
    FixedDecimal, LedgerContractError, LedgerEntryRecord, LedgerEntryStatus, LedgerEntryType,
    LedgerOperationOutcome, decide_exact_cache_request, plan_exact_cache_billing,
};
use serde::Deserialize;
use uuid::Uuid;

const FIXTURE: &str =
    include_str!("../../../tests/fixtures/billing/exact_cache_billing_contract.json");
const FORBIDDEN_TERMS: &[&str] = &[
    "authorization",
    "bearer",
    "api_key",
    "provider_key",
    "raw_key",
    "raw prompt",
    "raw_prompt",
    "payload",
    "secret",
    "idempotency_key",
];

#[derive(Debug, Deserialize)]
struct ContractFixture {
    contract: String,
    cases: Vec<CaseFixture>,
}

#[derive(Debug, Deserialize)]
struct CaseFixture {
    name: String,
    pricing: PricingFixture,
    #[serde(default)]
    decision_input: Option<ExactCacheDecisionInput>,
    #[serde(default)]
    expect_decision: Option<serde_json::Value>,
    request: RequestFixture,
    existing_entries: Vec<EntryFixture>,
    expect: Option<ExpectedPlan>,
    expect_error: Option<String>,
}

#[derive(Debug, Deserialize)]
struct PricingFixture {
    currency: String,
    scale: u32,
    input_token_rate_per_million: String,
    output_token_rate_per_million: String,
    cache_read_token_rate_per_million: String,
    cache_write_token_rate_per_million: String,
    fixed_cache_read_cost: String,
    fixed_cache_write_cost: String,
    fixed_request_cost: String,
}

#[derive(Debug, Deserialize)]
struct RequestFixture {
    request_id: Uuid,
    cache_status: ExactCacheStatus,
    cache_key_hash: String,
    #[serde(default)]
    cache_entry_id: Option<Uuid>,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    cache_write_tokens: u64,
    read_policy: ExactCacheReadPolicy,
    write_policy: ExactCacheWritePolicy,
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
    key_shape: String,
}

#[derive(Debug, Deserialize)]
struct ExpectedPlan {
    #[serde(default)]
    cache_operation_key_shape: Option<String>,
    #[serde(default)]
    cache_read_key_shape: Option<String>,
    #[serde(default)]
    cache_write_key_shape: Option<String>,
    #[serde(default)]
    ledger_key_shape: Option<String>,
    costs: ExpectedCosts,
    #[serde(default)]
    ledger: Option<ExpectedLedgerPlan>,
}

#[derive(Debug, Deserialize)]
struct ExpectedCosts {
    cached_input_tokens: u64,
    billable_input_tokens: u64,
    input_cost: String,
    output_cost: String,
    cache_read_cost: String,
    cache_write_cost: String,
    fixed_request_cost: String,
    total_cost: String,
}

#[derive(Debug, Deserialize)]
struct ExpectedLedgerPlan {
    outcome: String,
    #[serde(default)]
    existing_entry_id: Option<Uuid>,
    key_shape: String,
    entries: Vec<ExpectedEntry>,
    status_updates: Vec<ExpectedStatusUpdate>,
}

#[derive(Debug, Deserialize)]
struct ExpectedEntry {
    entry_type: String,
    #[serde(default)]
    related_ledger_entry_id: Option<Uuid>,
    amount: String,
    currency: String,
    status: String,
    metadata: serde_json::Value,
}

#[derive(Debug, Deserialize)]
struct ExpectedStatusUpdate {
    ledger_entry_id: Uuid,
    from: String,
    to: String,
    reason: String,
}

#[test]
fn exact_cache_billing_contract_fixture_matches_pure_plans() {
    assert_forbidden_terms_absent(FIXTURE, "exact cache fixture");
    let fixture: ContractFixture = serde_json::from_str(FIXTURE).expect("fixture should parse");
    assert_eq!(fixture.contract, "billing_ledger_exact_cache_v1");

    for case in &fixture.cases {
        if let Some(decision_input) = &case.decision_input {
            let decision = decide_exact_cache_request(decision_input.clone())
                .unwrap_or_else(|error| panic!("{} decision failed: {error}", case.name));
            let actual = serde_json::to_value(decision).expect("decision json");
            let expected = case
                .expect_decision
                .as_ref()
                .unwrap_or_else(|| panic!("{} missing expect_decision", case.name));
            assert_eq!(actual, *expected, "{} decision", case.name);
            assert_forbidden_terms_absent(&actual.to_string(), &case.name);
        }

        let existing_entries = case
            .existing_entries
            .iter()
            .map(to_entry_record)
            .collect::<Vec<_>>();
        let result = plan_exact_cache_billing(
            ExactCacheBillingRequest {
                request_id: case.request.request_id,
                cache_status: case.request.cache_status,
                cache_key_hash: case.request.cache_key_hash.clone(),
                cache_entry_id: case.request.cache_entry_id,
                input_tokens: case.request.input_tokens,
                output_tokens: case.request.output_tokens,
                cache_read_tokens: case.request.cache_read_tokens,
                cache_write_tokens: case.request.cache_write_tokens,
                read_policy: case.request.read_policy,
                write_policy: case.request.write_policy,
            },
            &to_pricing(&case.pricing),
            &existing_entries,
        );

        match (&case.expect, &case.expect_error, result) {
            (Some(expected), None, Ok(plan)) => {
                assert_eq!(
                    plan.cache_status, case.request.cache_status,
                    "{} status",
                    case.name
                );
                assert_eq!(
                    plan.cache_operation_idempotency_key,
                    expected
                        .cache_operation_key_shape
                        .as_deref()
                        .map(|shape| render_key_shape(shape, &case.request)),
                    "{} cache operation idempotency key",
                    case.name
                );
                assert_eq!(
                    plan.cache_read_idempotency_key,
                    expected
                        .cache_read_key_shape
                        .as_deref()
                        .map(|shape| render_key_shape(shape, &case.request)),
                    "{} cache read idempotency key",
                    case.name
                );
                assert_eq!(
                    plan.cache_write_idempotency_key,
                    expected
                        .cache_write_key_shape
                        .as_deref()
                        .map(|shape| render_key_shape(shape, &case.request)),
                    "{} cache write idempotency key",
                    case.name
                );
                assert_eq!(
                    plan.ledger_idempotency_key,
                    expected
                        .ledger_key_shape
                        .as_deref()
                        .map(|shape| render_key_shape(shape, &case.request)),
                    "{} ledger idempotency key",
                    case.name
                );
                assert_costs(&plan.rating, &expected.costs, &case.name);
                assert_ledger_plan(
                    &plan.ledger_plan,
                    &expected.ledger,
                    &case.request,
                    &case.name,
                );
            }
            (None, Some(expected_error), Err(error)) => {
                assert_eq!(
                    error_tag(&error),
                    expected_error,
                    "{} expected error",
                    case.name
                );
            }
            (_, _, outcome) => panic!("{} unexpected outcome: {:?}", case.name, outcome),
        }
    }
}

fn to_pricing(pricing: &PricingFixture) -> ExactCachePricingRules {
    ExactCachePricingRules {
        currency: pricing.currency.clone(),
        scale: pricing.scale,
        input_token_rate_per_million: money(&pricing.input_token_rate_per_million, pricing.scale),
        output_token_rate_per_million: money(&pricing.output_token_rate_per_million, pricing.scale),
        cache_read_token_rate_per_million: money(
            &pricing.cache_read_token_rate_per_million,
            pricing.scale,
        ),
        cache_write_token_rate_per_million: money(
            &pricing.cache_write_token_rate_per_million,
            pricing.scale,
        ),
        fixed_cache_read_cost: money(&pricing.fixed_cache_read_cost, pricing.scale),
        fixed_cache_write_cost: money(&pricing.fixed_cache_write_cost, pricing.scale),
        fixed_request_cost: money(&pricing.fixed_request_cost, pricing.scale),
    }
}

fn assert_costs(
    actual: &ai_gateway_billing_ledger::ExactCacheRatingResult,
    expected: &ExpectedCosts,
    label: &str,
) {
    assert_eq!(
        actual.cached_input_tokens, expected.cached_input_tokens,
        "{label} cached input tokens"
    );
    assert_eq!(
        actual.billable_input_tokens, expected.billable_input_tokens,
        "{label} billable input tokens"
    );
    assert_eq!(
        actual.input_cost.to_string(),
        expected.input_cost,
        "{label} input cost"
    );
    assert_eq!(
        actual.output_cost.to_string(),
        expected.output_cost,
        "{label} output cost"
    );
    assert_eq!(
        actual.cache_read_cost.to_string(),
        expected.cache_read_cost,
        "{label} cache read cost"
    );
    assert_eq!(
        actual.cache_write_cost.to_string(),
        expected.cache_write_cost,
        "{label} cache write cost"
    );
    assert_eq!(
        actual.fixed_request_cost.to_string(),
        expected.fixed_request_cost,
        "{label} fixed request cost"
    );
    assert_eq!(
        actual.total_cost.to_string(),
        expected.total_cost,
        "{label} total cost"
    );
}

fn assert_ledger_plan(
    actual: &Option<ai_gateway_billing_ledger::LedgerOperationPlan>,
    expected: &Option<ExpectedLedgerPlan>,
    request: &RequestFixture,
    label: &str,
) {
    match (actual, expected) {
        (None, None) => {}
        (Some(actual), Some(expected)) => {
            assert_eq!(
                actual.idempotency_key,
                render_key_shape(&expected.key_shape, request),
                "{label} ledger idempotency key"
            );
            match (&actual.outcome, expected.outcome.as_str()) {
                (LedgerOperationOutcome::Apply, "apply") => {}
                (LedgerOperationOutcome::Idempotent { existing_entry_id }, "idempotent") => {
                    assert_eq!(
                        Some(*existing_entry_id),
                        expected.existing_entry_id,
                        "{label} existing entry id"
                    );
                }
                _ => panic!("{label} ledger outcome mismatch: {:?}", actual.outcome),
            }

            assert_eq!(
                actual.entries.len(),
                expected.entries.len(),
                "{label} entries"
            );
            for (actual, expected) in actual.entries.iter().zip(&expected.entries) {
                assert_eq!(
                    serde_json::to_value(actual.entry_type).unwrap(),
                    serde_json::json!(expected.entry_type),
                    "{label} entry type"
                );
                assert_eq!(
                    actual.related_ledger_entry_id, expected.related_ledger_entry_id,
                    "{label} related ledger entry id"
                );
                assert_eq!(actual.amount.to_string(), expected.amount, "{label} amount");
                assert_eq!(actual.currency, expected.currency, "{label} currency");
                assert_eq!(
                    serde_json::to_value(actual.status).unwrap(),
                    serde_json::json!(expected.status),
                    "{label} status"
                );
                let metadata = serde_json::to_value(&actual.metadata).expect("metadata json");
                assert_eq!(metadata, expected.metadata, "{label} metadata");
                assert_forbidden_terms_absent(&metadata.to_string(), label);
            }

            assert_eq!(
                actual.status_updates.len(),
                expected.status_updates.len(),
                "{label} status updates"
            );
            for (actual, expected) in actual.status_updates.iter().zip(&expected.status_updates) {
                assert_eq!(
                    actual.ledger_entry_id, expected.ledger_entry_id,
                    "{label} status update id"
                );
                assert_eq!(
                    serde_json::to_value(actual.from).unwrap(),
                    serde_json::json!(expected.from),
                    "{label} status update from"
                );
                assert_eq!(
                    serde_json::to_value(actual.to).unwrap(),
                    serde_json::json!(expected.to),
                    "{label} status update to"
                );
                assert_eq!(
                    serde_json::to_value(actual.reason).unwrap(),
                    serde_json::json!(expected.reason),
                    "{label} status update reason"
                );
            }
        }
        (actual, expected) => panic!("{label} ledger presence mismatch: {actual:?} {expected:?}"),
    }
}

fn to_entry_record(entry: &EntryFixture) -> LedgerEntryRecord {
    let scale = 8;
    LedgerEntryRecord {
        id: entry.id,
        request_id: entry.request_id,
        related_ledger_entry_id: entry.related_ledger_entry_id,
        entry_type: match entry.entry_type.as_str() {
            "reserve" => LedgerEntryType::Reserve,
            "settle" => LedgerEntryType::Settle,
            "refund" => LedgerEntryType::Refund,
            entry_type => panic!("unsupported fixture entry_type `{entry_type}`"),
        },
        amount: money(&entry.amount, scale),
        currency: entry.currency.clone(),
        status: match entry.status.as_str() {
            "pending" => LedgerEntryStatus::Pending,
            "confirmed" => LedgerEntryStatus::Confirmed,
            "reversed" => LedgerEntryStatus::Reversed,
            status => panic!("unsupported fixture status `{status}`"),
        },
        idempotency_key: render_entry_key_shape(entry),
    }
}

fn render_key_shape(shape: &str, request: &RequestFixture) -> String {
    shape
        .replace("{request_id}", &request.request_id.to_string())
        .replace("{cache_key_hash}", &request.cache_key_hash)
}

fn render_entry_key_shape(entry: &EntryFixture) -> String {
    match entry.key_shape.as_str() {
        "settle:{request_id}" => {
            let request_id = entry
                .request_id
                .expect("settle key shape requires request_id");
            format!("settle:{request_id}")
        }
        "legacy_settle" => "legacy-settle-key".to_string(),
        key_shape => panic!("unsupported fixture key shape `{key_shape}`"),
    }
}

fn money(value: &str, scale: u32) -> FixedDecimal {
    FixedDecimal::parse(value, scale).expect("valid fixture money")
}

fn error_tag(error: &ExactCacheBillingError) -> &'static str {
    match error {
        ExactCacheBillingError::InvalidCacheKeyHash => "invalid_cache_key_hash",
        ExactCacheBillingError::CacheHitEntryIdRequired => "cache_hit_entry_id_required",
        ExactCacheBillingError::CacheReadTokensExceedInputTokens => {
            "cache_read_tokens_exceed_input_tokens"
        }
        ExactCacheBillingError::InvalidHitTokenSplit => "invalid_hit_token_split",
        ExactCacheBillingError::InvalidMissTokenSplit => "invalid_miss_token_split",
        ExactCacheBillingError::InvalidPartialHitTokenSplit => "invalid_partial_hit_token_split",
        ExactCacheBillingError::NegativeMoney { .. } => "negative_money",
        ExactCacheBillingError::Rating(_) => "rating_error",
        ExactCacheBillingError::Ledger(error) => ledger_error_tag(error),
    }
}

fn ledger_error_tag(error: &LedgerContractError) -> &'static str {
    match error {
        LedgerContractError::IdempotencyConflict { .. } => "idempotency_conflict",
        LedgerContractError::RequestAlreadySettled { .. } => "request_already_settled",
        LedgerContractError::RequestAlreadyReserved { .. } => "request_already_reserved",
        LedgerContractError::RefundSourceNotFound { .. } => "refund_source_not_found",
        LedgerContractError::RefundSourceNotConfirmedSettleDebit { .. } => {
            "refund_source_not_confirmed_settle_debit"
        }
        LedgerContractError::RefundCurrencyMismatch { .. } => "refund_currency_mismatch",
        LedgerContractError::FullRefundAmountNotAllowed => "full_refund_amount_not_allowed",
        LedgerContractError::PartialRefundAmountRequired => "partial_refund_amount_required",
        LedgerContractError::PartialRefundOperationIdRequired => {
            "partial_refund_operation_id_required"
        }
        LedgerContractError::PartialRefundConsumesRemaining { .. } => {
            "partial_refund_consumes_remaining"
        }
        LedgerContractError::AdminAdjustmentZeroAmount => "admin_adjustment_zero_amount",
        LedgerContractError::RefundAmountExceedsRemaining { .. } => {
            "refund_amount_exceeds_remaining"
        }
        LedgerContractError::NonPositiveAmount { .. } => "non_positive_amount",
        LedgerContractError::InvalidCurrency { .. } => "invalid_currency",
        LedgerContractError::ReserveCurrencyMismatch { .. } => "reserve_currency_mismatch",
        LedgerContractError::ScaleMismatch { .. } => "scale_mismatch",
        LedgerContractError::ArithmeticOverflow => "arithmetic_overflow",
    }
}

fn assert_forbidden_terms_absent(serialized: &str, label: &str) {
    let normalized = serialized.to_ascii_lowercase();
    for term in FORBIDDEN_TERMS {
        assert!(
            !normalized.contains(term),
            "{label} contains forbidden term `{term}`"
        );
    }
}
