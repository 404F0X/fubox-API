use std::fmt;

use serde::{Deserialize, Serialize, Serializer};
use serde_json::Value;
use thiserror::Error;

pub const DEFAULT_CURRENCY: &str = "USD";
pub const DEFAULT_MONEY_SCALE: u32 = 8;
pub const MAX_MONEY_SCALE: u32 = 18;
pub const TOKENS_PER_MILLION: i128 = 1_000_000;

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum RatingError {
    #[error("invalid pricing json: {0}")]
    InvalidPricingJson(String),
    #[error("money scale must be between 0 and {MAX_MONEY_SCALE}, got {0}")]
    InvalidScale(u32),
    #[error("invalid currency `{0}`")]
    InvalidCurrency(String),
    #[error("money field `{field}` must be a decimal string or integer fixed-unit value")]
    InvalidMoneyType { field: &'static str },
    #[error("money field `{field}` has invalid decimal `{value}`")]
    InvalidDecimal { field: &'static str, value: String },
    #[error("money field `{field}` has more than {scale} fractional digits: `{value}`")]
    TooManyFractionalDigits {
        field: &'static str,
        value: String,
        scale: u32,
    },
    #[error("money field `{field}` must not be negative")]
    NegativeMoney { field: &'static str },
    #[error("cannot combine fixed decimals with scales {left} and {right}")]
    ScaleMismatch { left: u32, right: u32 },
    #[error("rating arithmetic overflow")]
    ArithmeticOverflow,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct FixedDecimal {
    units: i128,
    scale: u32,
}

impl FixedDecimal {
    pub fn zero(scale: u32) -> Result<Self, RatingError> {
        Self::from_units(0, scale)
    }

    pub fn from_units(units: i128, scale: u32) -> Result<Self, RatingError> {
        validate_scale(scale)?;
        Ok(Self { units, scale })
    }

    pub fn parse(value: &str, scale: u32) -> Result<Self, RatingError> {
        parse_decimal_string("decimal", value, scale)
    }

    pub const fn units(self) -> i128 {
        self.units
    }

    pub const fn scale(self) -> u32 {
        self.scale
    }

    pub const fn is_zero(self) -> bool {
        self.units == 0
    }

    pub fn checked_add(self, other: Self) -> Result<Self, RatingError> {
        if self.scale != other.scale {
            return Err(RatingError::ScaleMismatch {
                left: self.scale,
                right: other.scale,
            });
        }

        let units = self
            .units
            .checked_add(other.units)
            .ok_or(RatingError::ArithmeticOverflow)?;

        Ok(Self {
            units,
            scale: self.scale,
        })
    }
}

impl fmt::Display for FixedDecimal {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.scale == 0 {
            return write!(formatter, "{}", self.units);
        }

        let negative = self.units < 0;
        let magnitude = self.units.unsigned_abs();
        let factor = pow10(self.scale).ok_or(fmt::Error)?;
        let major = magnitude / factor;
        let minor = magnitude % factor;

        if negative {
            write!(formatter, "-")?;
        }

        write!(
            formatter,
            "{major}.{minor:0width$}",
            width = self.scale as usize
        )
    }
}

impl Serialize for FixedDecimal {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(&self.to_string())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TokenUsage {
    pub input_tokens: u64,
    pub output_tokens: u64,
}

impl TokenUsage {
    pub const fn new(input_tokens: u64, output_tokens: u64) -> Self {
        Self {
            input_tokens,
            output_tokens,
        }
    }

    pub const fn with_cache_tokens(self, cache_tokens: u64) -> ExtendedTokenUsage {
        ExtendedTokenUsage::new(self.input_tokens, self.output_tokens)
            .with_cache_tokens(cache_tokens)
    }

    pub const fn with_reasoning_tokens(self, reasoning_tokens: u64) -> ExtendedTokenUsage {
        ExtendedTokenUsage::new(self.input_tokens, self.output_tokens)
            .with_reasoning_tokens(reasoning_tokens)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ExtendedTokenUsage {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_tokens: Option<u64>,
    pub reasoning_tokens: Option<u64>,
}

impl ExtendedTokenUsage {
    pub const fn new(input_tokens: u64, output_tokens: u64) -> Self {
        Self {
            input_tokens,
            output_tokens,
            cache_tokens: None,
            reasoning_tokens: None,
        }
    }

    pub const fn with_cache_tokens(mut self, cache_tokens: u64) -> Self {
        self.cache_tokens = Some(cache_tokens);
        self
    }

    pub const fn with_reasoning_tokens(mut self, reasoning_tokens: u64) -> Self {
        self.reasoning_tokens = Some(reasoning_tokens);
        self
    }
}

impl From<TokenUsage> for ExtendedTokenUsage {
    fn from(usage: TokenUsage) -> Self {
        Self::new(usage.input_tokens, usage.output_tokens)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PricingRules {
    pub currency: String,
    pub scale: u32,
    pub input_token_rate_per_million: FixedDecimal,
    pub output_token_rate_per_million: FixedDecimal,
    pub cache_token_rate_per_million: FixedDecimal,
    pub reasoning_token_rate_per_million: FixedDecimal,
    pub fixed_request_cost: FixedDecimal,
}

impl PricingRules {
    /// Parses the minimal `pricing_rules` JSON shape used by this slice.
    ///
    /// Expected money fields are decimal strings in major units, with the
    /// configured fixed scale, or integer fixed-unit values. JSON float money
    /// values are rejected.
    ///
    /// ```json
    /// {
    ///   "currency": "USD",
    ///   "scale": 8,
    ///   "input_token_rate_per_1m": "0.15000000",
    ///   "output_token_rate_per_1m": "0.60000000",
    ///   "fixed_request_cost": "0.00010000"
    /// }
    /// ```
    pub fn from_json_str(pricing_json: &str) -> Result<Self, RatingError> {
        let value: Value = serde_json::from_str(pricing_json)
            .map_err(|error| RatingError::InvalidPricingJson(error.to_string()))?;

        Self::from_json_value(value)
    }

    pub fn from_json_value(value: Value) -> Result<Self, RatingError> {
        let wire: PricingRulesWire = serde_json::from_value(value)
            .map_err(|error| RatingError::InvalidPricingJson(error.to_string()))?;

        let scale = wire.scale.unwrap_or(DEFAULT_MONEY_SCALE);
        validate_scale(scale)?;

        let currency = wire
            .currency
            .unwrap_or_else(|| DEFAULT_CURRENCY.to_string());
        validate_currency(&currency)?;

        Ok(Self {
            currency,
            scale,
            input_token_rate_per_million: parse_optional_money_field(
                "input_token_rate_per_1m",
                wire.input_token_rate_per_1m,
                scale,
            )?,
            output_token_rate_per_million: parse_optional_money_field(
                "output_token_rate_per_1m",
                wire.output_token_rate_per_1m,
                scale,
            )?,
            cache_token_rate_per_million: parse_optional_money_field(
                "cache_token_rate_per_1m",
                wire.cache_token_rate_per_1m,
                scale,
            )?,
            reasoning_token_rate_per_million: parse_optional_money_field(
                "reasoning_token_rate_per_1m",
                wire.reasoning_token_rate_per_1m,
                scale,
            )?,
            fixed_request_cost: parse_optional_money_field(
                "fixed_request_cost",
                wire.fixed_request_cost,
                scale,
            )?,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RatingResult {
    pub input_tokens: u64,
    pub output_tokens: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_tokens: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning_tokens: Option<u64>,
    pub input_cost: FixedDecimal,
    pub output_cost: FixedDecimal,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_cost: Option<FixedDecimal>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning_cost: Option<FixedDecimal>,
    pub fixed_request_cost: FixedDecimal,
    pub total_cost: FixedDecimal,
    pub currency: String,
    pub scale: u32,
}

pub fn rate_usage_from_json<U>(pricing_json: &str, usage: U) -> Result<RatingResult, RatingError>
where
    U: Into<ExtendedTokenUsage>,
{
    let pricing = PricingRules::from_json_str(pricing_json)?;
    rate_usage(&pricing, usage)
}

pub fn rate_usage<U>(pricing: &PricingRules, usage: U) -> Result<RatingResult, RatingError>
where
    U: Into<ExtendedTokenUsage>,
{
    let usage = usage.into();
    let input_cost = rate_tokens(usage.input_tokens, pricing.input_token_rate_per_million)?;
    let output_cost = rate_tokens(usage.output_tokens, pricing.output_token_rate_per_million)?;
    let cache_cost = usage
        .cache_tokens
        .map(|tokens| rate_tokens(tokens, pricing.cache_token_rate_per_million))
        .transpose()?;
    let reasoning_cost = usage
        .reasoning_tokens
        .map(|tokens| rate_tokens(tokens, pricing.reasoning_token_rate_per_million))
        .transpose()?;
    let total_cost = input_cost
        .checked_add(output_cost)?
        .checked_add(cache_cost.unwrap_or(FixedDecimal::zero(pricing.scale)?))?
        .checked_add(reasoning_cost.unwrap_or(FixedDecimal::zero(pricing.scale)?))?
        .checked_add(pricing.fixed_request_cost)?;

    Ok(RatingResult {
        input_tokens: usage.input_tokens,
        output_tokens: usage.output_tokens,
        cache_tokens: usage.cache_tokens,
        reasoning_tokens: usage.reasoning_tokens,
        input_cost,
        output_cost,
        cache_cost,
        reasoning_cost,
        fixed_request_cost: pricing.fixed_request_cost,
        total_cost,
        currency: pricing.currency.clone(),
        scale: pricing.scale,
    })
}

pub(crate) fn rate_tokens(
    tokens: u64,
    rate_per_million: FixedDecimal,
) -> Result<FixedDecimal, RatingError> {
    if rate_per_million.units < 0 {
        return Err(RatingError::NegativeMoney {
            field: "rate_per_million",
        });
    }

    let numerator = i128::from(tokens)
        .checked_mul(rate_per_million.units)
        .ok_or(RatingError::ArithmeticOverflow)?;
    let units = div_round_half_up(numerator, TOKENS_PER_MILLION)?;

    FixedDecimal::from_units(units, rate_per_million.scale)
}

fn div_round_half_up(numerator: i128, denominator: i128) -> Result<i128, RatingError> {
    if denominator <= 0 || numerator < 0 {
        return Err(RatingError::ArithmeticOverflow);
    }

    let quotient = numerator / denominator;
    let remainder = numerator % denominator;

    if remainder
        .checked_mul(2)
        .ok_or(RatingError::ArithmeticOverflow)?
        >= denominator
    {
        quotient
            .checked_add(1)
            .ok_or(RatingError::ArithmeticOverflow)
    } else {
        Ok(quotient)
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct PricingRulesWire {
    #[serde(default)]
    currency: Option<String>,
    #[serde(default)]
    scale: Option<u32>,
    #[serde(
        default,
        alias = "input_token_rate_per_million",
        alias = "input_tokens_per_1m"
    )]
    input_token_rate_per_1m: Option<Value>,
    #[serde(
        default,
        alias = "output_token_rate_per_million",
        alias = "output_tokens_per_1m"
    )]
    output_token_rate_per_1m: Option<Value>,
    #[serde(
        default,
        alias = "cache_token_rate_per_million",
        alias = "cache_tokens_per_1m",
        alias = "cached_token_rate_per_1m",
        alias = "cached_token_rate_per_million",
        alias = "cached_input_token_rate_per_1m",
        alias = "cached_input_token_rate_per_million",
        alias = "input_cache_token_rate_per_1m",
        alias = "input_cache_token_rate_per_million"
    )]
    cache_token_rate_per_1m: Option<Value>,
    #[serde(
        default,
        alias = "reasoning_token_rate_per_million",
        alias = "reasoning_tokens_per_1m"
    )]
    reasoning_token_rate_per_1m: Option<Value>,
    #[serde(default)]
    fixed_request_cost: Option<Value>,
}

fn parse_optional_money_field(
    field: &'static str,
    value: Option<Value>,
    scale: u32,
) -> Result<FixedDecimal, RatingError> {
    match value {
        None | Some(Value::Null) => FixedDecimal::zero(scale),
        Some(Value::String(value)) => {
            let money = parse_decimal_string(field, &value, scale)?;
            reject_negative(field, money)?;
            Ok(money)
        }
        Some(Value::Number(number)) => {
            let units = if let Some(units) = number.as_i64() {
                i128::from(units)
            } else if let Some(units) = number.as_u64() {
                i128::from(units)
            } else {
                return Err(RatingError::InvalidMoneyType { field });
            };
            let money = FixedDecimal::from_units(units, scale)?;
            reject_negative(field, money)?;
            Ok(money)
        }
        Some(_) => Err(RatingError::InvalidMoneyType { field }),
    }
}

fn parse_decimal_string(
    field: &'static str,
    value: &str,
    scale: u32,
) -> Result<FixedDecimal, RatingError> {
    validate_scale(scale)?;

    let value = value.trim();
    if value.is_empty() {
        return Err(RatingError::InvalidDecimal {
            field,
            value: value.to_string(),
        });
    }

    let (negative, unsigned) = if let Some(unsigned) = value.strip_prefix('-') {
        (true, unsigned)
    } else if let Some(unsigned) = value.strip_prefix('+') {
        (false, unsigned)
    } else {
        (false, value)
    };

    if unsigned.is_empty() {
        return Err(RatingError::InvalidDecimal {
            field,
            value: value.to_string(),
        });
    }

    let mut parts = unsigned.split('.');
    let whole = parts.next().expect("split always yields one part");
    let fraction = parts.next();
    if parts.next().is_some()
        || whole.is_empty()
        || !whole.chars().all(|character| character.is_ascii_digit())
        || !fraction
            .unwrap_or_default()
            .chars()
            .all(|character| character.is_ascii_digit())
    {
        return Err(RatingError::InvalidDecimal {
            field,
            value: value.to_string(),
        });
    }

    let fraction = fraction.unwrap_or_default();
    if fraction.len() > scale as usize {
        return Err(RatingError::TooManyFractionalDigits {
            field,
            value: value.to_string(),
            scale,
        });
    }

    let factor = pow10(scale).ok_or(RatingError::ArithmeticOverflow)?;
    let whole_units = whole
        .parse::<i128>()
        .map_err(|_| RatingError::InvalidDecimal {
            field,
            value: value.to_string(),
        })?
        .checked_mul(i128::try_from(factor).map_err(|_| RatingError::ArithmeticOverflow)?)
        .ok_or(RatingError::ArithmeticOverflow)?;

    let mut fraction_digits = fraction.to_string();
    while fraction_digits.len() < scale as usize {
        fraction_digits.push('0');
    }

    let fraction_units = if fraction_digits.is_empty() {
        0
    } else {
        fraction_digits
            .parse::<i128>()
            .map_err(|_| RatingError::InvalidDecimal {
                field,
                value: value.to_string(),
            })?
    };

    let units = whole_units
        .checked_add(fraction_units)
        .ok_or(RatingError::ArithmeticOverflow)?;
    let units = if negative {
        units.checked_neg().ok_or(RatingError::ArithmeticOverflow)?
    } else {
        units
    };

    FixedDecimal::from_units(units, scale)
}

fn reject_negative(field: &'static str, money: FixedDecimal) -> Result<(), RatingError> {
    if money.units < 0 {
        Err(RatingError::NegativeMoney { field })
    } else {
        Ok(())
    }
}

fn validate_scale(scale: u32) -> Result<(), RatingError> {
    if scale <= MAX_MONEY_SCALE {
        Ok(())
    } else {
        Err(RatingError::InvalidScale(scale))
    }
}

fn validate_currency(currency: &str) -> Result<(), RatingError> {
    let mut characters = currency.chars();
    let Some(first) = characters.next() else {
        return Err(RatingError::InvalidCurrency(currency.to_string()));
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
        Err(RatingError::InvalidCurrency(currency.to_string()))
    }
}

fn pow10(scale: u32) -> Option<u128> {
    let mut value = 1_u128;
    for _ in 0..scale {
        value = value.checked_mul(10)?;
    }
    Some(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rounds_token_costs_half_up_to_configured_scale() {
        let below_half = rate_usage_from_json(
            r#"{
                "currency": "USD",
                "scale": 8,
                "input_token_rate_per_1m": "0.00499999"
            }"#,
            TokenUsage::new(1, 0),
        )
        .unwrap();

        assert_eq!(below_half.total_cost.to_string(), "0.00000000");

        let half = rate_usage_from_json(
            r#"{
                "currency": "USD",
                "scale": 8,
                "input_token_rate_per_1m": "0.00500000"
            }"#,
            TokenUsage::new(1, 0),
        )
        .unwrap();

        assert_eq!(half.input_cost.to_string(), "0.00000001");
        assert_eq!(half.total_cost.to_string(), "0.00000001");
    }

    #[test]
    fn missing_rates_price_as_zero() {
        let result = rate_usage_from_json(
            r#"{
                "currency": "CREDIT",
                "scale": 8
            }"#,
            TokenUsage::new(12_345, 67_890),
        )
        .unwrap();

        assert_eq!(result.input_tokens, 12_345);
        assert_eq!(result.output_tokens, 67_890);
        assert_eq!(result.currency, "CREDIT");
        assert_eq!(result.scale, 8);
        assert_eq!(result.total_cost.to_string(), "0.00000000");

        let serialized = serde_json::to_value(&result).unwrap();
        assert!(serialized.get("cache_tokens").is_none());
        assert!(serialized.get("reasoning_tokens").is_none());
        assert!(serialized.get("cache_cost").is_none());
        assert!(serialized.get("reasoning_cost").is_none());
    }

    #[test]
    fn rates_input_output_and_fixed_request_cost() {
        let result = rate_usage_from_json(
            r#"{
                "currency": "USD",
                "scale": 8,
                "input_token_rate_per_1m": "1.00000000",
                "output_token_rate_per_1m": "2.00000000",
                "fixed_request_cost": "0.12500000"
            }"#,
            TokenUsage::new(1_500_000, 250_000),
        )
        .unwrap();

        assert_eq!(result.input_cost.to_string(), "1.50000000");
        assert_eq!(result.output_cost.to_string(), "0.50000000");
        assert_eq!(result.fixed_request_cost.to_string(), "0.12500000");
        assert_eq!(result.total_cost.to_string(), "2.12500000");
    }

    #[test]
    fn supports_large_token_counts_without_float_math() {
        let result = rate_usage_from_json(
            r#"{
                "currency": "USD",
                "scale": 8,
                "input_token_rate_per_1m": "1.00000000",
                "output_token_rate_per_1m": "2.00000000",
                "fixed_request_cost": "0.00000001"
            }"#,
            TokenUsage::new(1_000_000_000_000, 500_000_000_000),
        )
        .unwrap();

        assert_eq!(result.input_cost.to_string(), "1000000.00000000");
        assert_eq!(result.output_cost.to_string(), "1000000.00000000");
        assert_eq!(result.total_cost.to_string(), "2000000.00000001");
    }

    #[test]
    fn rates_cache_tokens_when_present() {
        let result = rate_usage_from_json(
            r#"{
                "currency": "USD",
                "scale": 8,
                "cache_token_rate_per_1m": "0.25000000"
            }"#,
            TokenUsage::new(0, 0).with_cache_tokens(2_000_000),
        )
        .unwrap();

        assert_eq!(result.cache_tokens, Some(2_000_000));
        assert_eq!(result.reasoning_tokens, None);
        assert_eq!(result.cache_cost.unwrap().to_string(), "0.50000000");
        assert_eq!(result.reasoning_cost, None);
        assert_eq!(result.total_cost.to_string(), "0.50000000");
    }

    #[test]
    fn rates_reasoning_tokens_when_present_using_alias() {
        let result = rate_usage_from_json(
            r#"{
                "currency": "USD",
                "scale": 8,
                "reasoning_token_rate_per_million": "3.00000000"
            }"#,
            TokenUsage::new(0, 0).with_reasoning_tokens(500_000),
        )
        .unwrap();

        assert_eq!(result.cache_tokens, None);
        assert_eq!(result.reasoning_tokens, Some(500_000));
        assert_eq!(result.cache_cost, None);
        assert_eq!(result.reasoning_cost.unwrap().to_string(), "1.50000000");
        assert_eq!(result.total_cost.to_string(), "1.50000000");
    }

    #[test]
    fn rates_input_output_cache_reasoning_and_fixed_request_cost() {
        let result = rate_usage_from_json(
            r#"{
                "currency": "USD",
                "scale": 8,
                "input_token_rate_per_1m": "1.00000000",
                "output_token_rate_per_1m": "2.00000000",
                "cached_input_token_rate_per_1m": "0.25000000",
                "reasoning_tokens_per_1m": "4.00000000",
                "fixed_request_cost": "0.12500000"
            }"#,
            TokenUsage::new(1_000_000, 500_000)
                .with_cache_tokens(2_000_000)
                .with_reasoning_tokens(250_000),
        )
        .unwrap();

        assert_eq!(result.input_cost.to_string(), "1.00000000");
        assert_eq!(result.output_cost.to_string(), "1.00000000");
        assert_eq!(result.cache_cost.unwrap().to_string(), "0.50000000");
        assert_eq!(result.reasoning_cost.unwrap().to_string(), "1.00000000");
        assert_eq!(result.fixed_request_cost.to_string(), "0.12500000");
        assert_eq!(result.total_cost.to_string(), "3.62500000");
    }

    #[test]
    fn rejects_invalid_pricing_json() {
        assert!(matches!(
            rate_usage_from_json(r#"{"input_token_rate_per_1m": 0.1}"#, TokenUsage::new(1, 0)),
            Err(RatingError::InvalidMoneyType {
                field: "input_token_rate_per_1m"
            })
        ));

        assert!(matches!(
            rate_usage_from_json(
                r#"{"scale": 8, "fixed_request_cost": "0.000000001"}"#,
                TokenUsage::new(0, 0)
            ),
            Err(RatingError::TooManyFractionalDigits {
                field: "fixed_request_cost",
                ..
            })
        ));

        assert!(matches!(
            rate_usage_from_json(r#"{"currency": "usd"}"#, TokenUsage::new(0, 0)),
            Err(RatingError::InvalidCurrency(currency)) if currency == "usd"
        ));

        assert!(matches!(
            rate_usage_from_json(r#"{"unexpected": "field"}"#, TokenUsage::new(0, 0)),
            Err(RatingError::InvalidPricingJson(_))
        ));

        assert!(matches!(
            rate_usage_from_json(r#"{"cache_token_rate_per_1m": 0.1}"#, TokenUsage::new(0, 0)),
            Err(RatingError::InvalidMoneyType {
                field: "cache_token_rate_per_1m"
            })
        ));

        assert!(matches!(
            rate_usage_from_json(
                r#"{"scale": 8, "reasoning_token_rate_per_1m": "0.000000001"}"#,
                TokenUsage::new(0, 0)
            ),
            Err(RatingError::TooManyFractionalDigits {
                field: "reasoning_token_rate_per_1m",
                ..
            })
        ));
    }

    #[test]
    fn accepts_integer_fixed_units_and_rejects_negative_money() {
        let result = rate_usage_from_json(
            r#"{
                "currency": "USD",
                "scale": 8,
                "input_token_rate_per_1m": 100000000,
                "fixed_request_cost": 1
            }"#,
            TokenUsage::new(1_000_000, 0),
        )
        .unwrap();

        assert_eq!(result.input_cost.to_string(), "1.00000000");
        assert_eq!(result.fixed_request_cost.to_string(), "0.00000001");
        assert_eq!(result.total_cost.to_string(), "1.00000001");

        assert!(matches!(
            rate_usage_from_json(
                r#"{"input_token_rate_per_1m": "-0.00000001"}"#,
                TokenUsage::new(1, 0)
            ),
            Err(RatingError::NegativeMoney {
                field: "input_token_rate_per_1m"
            })
        ));
    }

    #[test]
    fn rejects_scale_mismatch_when_adding_fixed_decimals() {
        let left = FixedDecimal::from_units(1, 8).unwrap();
        let right = FixedDecimal::from_units(1, 6).unwrap();

        assert!(matches!(
            left.checked_add(right),
            Err(RatingError::ScaleMismatch { left: 8, right: 6 })
        ));
    }
}
