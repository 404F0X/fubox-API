use ai_gateway_billing_ledger::{
    ExtendedTokenUsage, RatingError, RatingResult, extract_runtime_token_usage_from_value,
    rate_runtime_usage_from_json,
};
use serde::Deserialize;

const FIXTURE: &str =
    include_str!("../../../tests/fixtures/billing/usage_rating_runtime_extraction_contract.json");

#[derive(Debug, Deserialize)]
struct ContractFixture {
    contract: String,
    pricing: serde_json::Value,
    secret_safe_forbidden_terms: Vec<String>,
    cases: Vec<CaseFixture>,
}

#[derive(Debug, Deserialize)]
struct CaseFixture {
    name: String,
    runtime_usage: serde_json::Value,
    #[serde(default)]
    expect_usage: Option<ExpectedUsage>,
    #[serde(default)]
    expect_rating: Option<ExpectedRating>,
    #[serde(default)]
    expect_error: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ExpectedUsage {
    input_tokens: u64,
    output_tokens: u64,
    #[serde(default)]
    cache_tokens: Option<u64>,
    #[serde(default)]
    reasoning_tokens: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct ExpectedRating {
    input_cost: String,
    output_cost: String,
    #[serde(default)]
    cache_cost: Option<String>,
    #[serde(default)]
    reasoning_cost: Option<String>,
    fixed_request_cost: String,
    total_cost: String,
    currency: String,
}

#[test]
fn usage_rating_runtime_extraction_fixture_matches_contract() {
    let fixture: ContractFixture = serde_json::from_str(FIXTURE).expect("fixture should parse");
    assert_eq!(
        fixture.contract,
        "billing_ledger_usage_rating_runtime_extraction_v1"
    );
    let pricing_json = serde_json::to_string(&fixture.pricing).expect("pricing serializes");

    for case in &fixture.cases {
        let extraction = extract_runtime_token_usage_from_value(&case.runtime_usage);
        let rating = rate_runtime_usage_from_json(&pricing_json, &case.runtime_usage.to_string());

        match (&case.expect_error, extraction, rating) {
            (Some(expected_error), Err(error), Err(rating_error)) => {
                assert_eq!(
                    error_tag(&error),
                    expected_error,
                    "{} extraction error",
                    case.name
                );
                assert_eq!(
                    error_tag(&rating_error),
                    expected_error,
                    "{} rating error",
                    case.name
                );
                assert_secret_safe_text(&error.to_string(), &fixture.secret_safe_forbidden_terms)
                    .unwrap_or_else(|term| {
                        panic!("{} extraction error leaked `{term}`", case.name)
                    });
                assert_secret_safe_text(
                    &rating_error.to_string(),
                    &fixture.secret_safe_forbidden_terms,
                )
                .unwrap_or_else(|term| panic!("{} rating error leaked `{term}`", case.name));
            }
            (None, Ok(actual_usage), Ok(actual_rating)) => {
                assert_usage(&actual_usage, &case.expect_usage, &case.name);
                assert_rating(&actual_rating, &case.expect_rating, &case.name);
                assert_secret_safe_json(
                    &serde_json::to_value(&actual_rating).expect("rating json"),
                    &fixture.secret_safe_forbidden_terms,
                    &case.name,
                );
            }
            (_, extraction, rating) => panic!(
                "{} unexpected outcome: extraction={:?} rating={:?}",
                case.name, extraction, rating
            ),
        }
    }
}

fn assert_usage(
    actual: &Option<ExtendedTokenUsage>,
    expected: &Option<ExpectedUsage>,
    label: &str,
) {
    match (actual, expected) {
        (None, None) => {}
        (Some(actual), Some(expected)) => {
            assert_eq!(
                actual.input_tokens, expected.input_tokens,
                "{label} input tokens"
            );
            assert_eq!(
                actual.output_tokens, expected.output_tokens,
                "{label} output tokens"
            );
            assert_eq!(
                actual.cache_tokens, expected.cache_tokens,
                "{label} cache tokens"
            );
            assert_eq!(
                actual.reasoning_tokens, expected.reasoning_tokens,
                "{label} reasoning tokens"
            );
        }
        (actual, expected) => panic!("{label} usage mismatch: {actual:?} {expected:?}"),
    }
}

fn assert_rating(actual: &Option<RatingResult>, expected: &Option<ExpectedRating>, label: &str) {
    match (actual, expected) {
        (None, None) => {}
        (Some(actual), Some(expected)) => {
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
                actual.cache_cost.map(|cost| cost.to_string()).as_deref(),
                expected.cache_cost.as_deref(),
                "{label} cache cost"
            );
            assert_eq!(
                actual
                    .reasoning_cost
                    .map(|cost| cost.to_string())
                    .as_deref(),
                expected.reasoning_cost.as_deref(),
                "{label} reasoning cost"
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
            assert_eq!(&actual.currency, &expected.currency, "{label} currency");
        }
        (actual, expected) => panic!("{label} rating mismatch: {actual:?} {expected:?}"),
    }
}

fn error_tag(error: &RatingError) -> &'static str {
    match error {
        RatingError::InvalidUsageField { .. } => "invalid_usage_field",
        RatingError::UsageCategoryExceedsTotal { .. } => "usage_category_exceeds_total",
        RatingError::InvalidUsageJson(_) => "invalid_usage_json",
        RatingError::InvalidPricingJson(_) => "invalid_pricing_json",
        RatingError::InvalidScale(_) => "invalid_scale",
        RatingError::InvalidCurrency(_) => "invalid_currency",
        RatingError::InvalidMoneyType { .. } => "invalid_money_type",
        RatingError::InvalidDecimal { .. } => "invalid_decimal",
        RatingError::TooManyFractionalDigits { .. } => "too_many_fractional_digits",
        RatingError::NegativeMoney { .. } => "negative_money",
        RatingError::ScaleMismatch { .. } => "scale_mismatch",
        RatingError::ArithmeticOverflow => "arithmetic_overflow",
    }
}

fn assert_secret_safe_json(value: &serde_json::Value, forbidden_terms: &[String], label: &str) {
    assert_secret_safe_text(&value.to_string(), forbidden_terms)
        .unwrap_or_else(|term| panic!("{label} leaked `{term}`"));
}

fn assert_secret_safe_text(serialized: &str, forbidden_terms: &[String]) -> Result<(), String> {
    let normalized = serialized.to_ascii_lowercase();
    for term in forbidden_terms {
        if normalized.contains(&term.to_ascii_lowercase()) {
            return Err(term.clone());
        }
    }

    Ok(())
}
