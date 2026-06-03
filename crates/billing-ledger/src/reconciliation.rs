use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

use crate::{DEFAULT_MONEY_SCALE, FixedDecimal, RatingError};

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum ReconciliationError {
    #[error("invalid reconciliation money field `{field}` value `{value}`: {source}")]
    InvalidMoney {
        field: &'static str,
        value: String,
        source: RatingError,
    },
    #[error("reconciliation arithmetic overflow")]
    ArithmeticOverflow,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BillingReconciliationInputRow {
    pub tenant_id: Uuid,
    pub period_start: String,
    pub period_end: String,
    pub request_id: Option<Uuid>,
    pub project_id: Option<Uuid>,
    pub virtual_key_id: Option<Uuid>,
    pub trace_id: Option<String>,
    pub canonical_model_id: Option<Uuid>,
    pub resolved_provider_id: Option<Uuid>,
    pub resolved_channel_id: Option<Uuid>,
    pub requested_model: Option<String>,
    pub upstream_model: Option<String>,
    pub request_status: Option<String>,
    pub input_tokens: Option<i64>,
    pub output_tokens: Option<i64>,
    pub request_final_cost: Option<String>,
    pub request_currency: Option<String>,
    pub ledger_entry_ids: Vec<Uuid>,
    pub ledger_entry_count: i64,
    pub ledger_amount: Option<String>,
    pub ledger_currency: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BillingReconciliationReport {
    pub report_version: u8,
    pub tenant_id: Uuid,
    pub period_start: String,
    pub period_end: String,
    pub summary: BillingReconciliationSummary,
    pub discrepancies: Vec<BillingReconciliationDiscrepancy>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BillingReconciliationSummary {
    pub request_count: usize,
    pub billable_request_count: usize,
    pub ledger_entry_count: i64,
    pub matched_request_count: usize,
    pub discrepancy_count: usize,
    pub missing_ledger_count: usize,
    pub unexpected_ledger_count: usize,
    pub amount_mismatch_count: usize,
    pub currency_mismatch_count: usize,
    pub returned_discrepancy_count: usize,
    pub currency_totals: Vec<BillingReconciliationCurrencyTotal>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BillingReconciliationCurrencyTotal {
    pub currency: String,
    pub request_final_cost_total: String,
    pub expected_ledger_amount_total: String,
    pub ledger_amount_total: String,
    pub difference_amount: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BillingReconciliationDiscrepancy {
    pub issues: Vec<ReconciliationIssue>,
    pub request_id: Option<Uuid>,
    pub ledger_entry_ids: Vec<Uuid>,
    pub project_id: Option<Uuid>,
    pub virtual_key_id: Option<Uuid>,
    pub trace_id: Option<String>,
    pub canonical_model_id: Option<Uuid>,
    pub resolved_provider_id: Option<Uuid>,
    pub resolved_channel_id: Option<Uuid>,
    pub requested_model: Option<String>,
    pub upstream_model: Option<String>,
    pub request_status: Option<String>,
    pub input_tokens: Option<i64>,
    pub output_tokens: Option<i64>,
    pub request_final_cost: Option<String>,
    pub expected_ledger_amount: Option<String>,
    pub request_currency: Option<String>,
    pub ledger_amount: Option<String>,
    pub ledger_currency: Option<String>,
    pub difference_amount: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReconciliationIssue {
    MissingLedger,
    UnexpectedLedger,
    AmountMismatch,
    CurrencyMismatch,
}

pub fn reconcile_billing_usage_ledger<I>(
    tenant_id: Uuid,
    rows: I,
    discrepancy_limit: usize,
) -> Result<BillingReconciliationReport, ReconciliationError>
where
    I: IntoIterator<Item = BillingReconciliationInputRow>,
{
    let zero = FixedDecimal::zero(DEFAULT_MONEY_SCALE)
        .map_err(|_| ReconciliationError::ArithmeticOverflow)?;
    let mut period_start = None;
    let mut period_end = None;
    let mut request_count = 0_usize;
    let mut billable_request_count = 0_usize;
    let mut ledger_entry_count = 0_i64;
    let mut matched_request_count = 0_usize;
    let mut missing_ledger_count = 0_usize;
    let mut unexpected_ledger_count = 0_usize;
    let mut amount_mismatch_count = 0_usize;
    let mut currency_mismatch_count = 0_usize;
    let mut currency_totals = BTreeMap::<String, CurrencyAccumulator>::new();
    let mut discrepancies = Vec::new();
    let mut discrepancy_count = 0_usize;

    for row in rows {
        if period_start.is_none() {
            period_start = Some(row.period_start.clone());
        }
        if period_end.is_none() {
            period_end = Some(row.period_end.clone());
        }

        let request_present = row.request_final_cost.is_some();
        let ledger_present = row.ledger_entry_count > 0;
        if !request_present && !ledger_present {
            continue;
        }

        let request_final_cost =
            parse_optional_money("request_final_cost", row.request_final_cost.as_deref())?;
        let expected_ledger_amount = request_final_cost.map(checked_neg).transpose()?;
        let ledger_amount = parse_optional_money("ledger_amount", row.ledger_amount.as_deref())?;
        let ledger_amount = if ledger_present {
            Some(ledger_amount.unwrap_or(zero))
        } else {
            None
        };

        if request_present {
            request_count += 1;
            if expected_ledger_amount.is_some_and(|amount| !amount.is_zero()) {
                billable_request_count += 1;
            }
        }
        ledger_entry_count += row.ledger_entry_count;

        if let (Some(currency), Some(cost), Some(expected)) = (
            row.request_currency.as_deref(),
            request_final_cost,
            expected_ledger_amount,
        ) {
            currency_totals
                .entry(currency.to_string())
                .or_default()
                .add_request(cost, expected)?;
        }
        if let (Some(currency), Some(amount)) = (row.ledger_currency.as_deref(), ledger_amount) {
            currency_totals
                .entry(currency.to_string())
                .or_default()
                .add_ledger(amount)?;
        }

        let mut issues = Vec::new();
        if request_present && !ledger_present {
            if expected_ledger_amount.is_some_and(|amount| !amount.is_zero()) {
                issues.push(ReconciliationIssue::MissingLedger);
            }
        } else if !request_present && ledger_present {
            issues.push(ReconciliationIssue::UnexpectedLedger);
        } else if request_present && ledger_present {
            let currency_matches = row.request_currency == row.ledger_currency;
            if !currency_matches {
                issues.push(ReconciliationIssue::CurrencyMismatch);
            }
            if currency_matches && ledger_amount != expected_ledger_amount {
                issues.push(ReconciliationIssue::AmountMismatch);
            }
        }

        if issues.is_empty() {
            if request_present {
                matched_request_count += 1;
            }
            continue;
        }

        if issues.contains(&ReconciliationIssue::MissingLedger) {
            missing_ledger_count += 1;
        }
        if issues.contains(&ReconciliationIssue::UnexpectedLedger) {
            unexpected_ledger_count += 1;
        }
        if issues.contains(&ReconciliationIssue::AmountMismatch) {
            amount_mismatch_count += 1;
        }
        if issues.contains(&ReconciliationIssue::CurrencyMismatch) {
            currency_mismatch_count += 1;
        }
        discrepancy_count += 1;

        if discrepancies.len() < discrepancy_limit {
            let difference_amount = match (
                row.request_currency == row.ledger_currency,
                ledger_amount,
                expected_ledger_amount,
            ) {
                (true, Some(ledger), Some(expected)) => {
                    Some(checked_subtract(ledger, expected)?.to_string())
                }
                _ => None,
            };

            discrepancies.push(BillingReconciliationDiscrepancy {
                issues,
                request_id: row.request_id,
                ledger_entry_ids: row.ledger_entry_ids,
                project_id: row.project_id,
                virtual_key_id: row.virtual_key_id,
                trace_id: row.trace_id.map(redact_reconciliation_text),
                canonical_model_id: row.canonical_model_id,
                resolved_provider_id: row.resolved_provider_id,
                resolved_channel_id: row.resolved_channel_id,
                requested_model: row.requested_model.map(redact_reconciliation_text),
                upstream_model: row.upstream_model.map(redact_reconciliation_text),
                request_status: row.request_status.map(redact_reconciliation_text),
                input_tokens: row.input_tokens,
                output_tokens: row.output_tokens,
                request_final_cost: row.request_final_cost,
                expected_ledger_amount: expected_ledger_amount.map(|amount| amount.to_string()),
                request_currency: row.request_currency.map(redact_reconciliation_text),
                ledger_amount: row.ledger_amount,
                ledger_currency: row.ledger_currency.map(redact_reconciliation_text),
                difference_amount,
            });
        }
    }

    let currency_totals = currency_totals
        .into_iter()
        .map(|(currency, totals)| totals.into_total(redact_reconciliation_text(currency)))
        .collect::<Result<Vec<_>, _>>()?;

    Ok(BillingReconciliationReport {
        report_version: 1,
        tenant_id,
        period_start: period_start.unwrap_or_default(),
        period_end: period_end.unwrap_or_default(),
        summary: BillingReconciliationSummary {
            request_count,
            billable_request_count,
            ledger_entry_count,
            matched_request_count,
            discrepancy_count,
            missing_ledger_count,
            unexpected_ledger_count,
            amount_mismatch_count,
            currency_mismatch_count,
            returned_discrepancy_count: discrepancies.len(),
            currency_totals,
        },
        discrepancies,
    })
}

fn redact_reconciliation_text(value: String) -> String {
    let trimmed = value.trim();
    let normalized = trimmed.to_ascii_lowercase();
    let looks_sensitive = trimmed.starts_with("sk-")
        || (trimmed.starts_with("vk_") && trimmed.len() > 16)
        || normalized.contains("bearer ")
        || normalized.contains("api_key=")
        || normalized.contains("apikey=")
        || normalized.contains("authorization=")
        || normalized.contains("token=")
        || normalized.contains("password=")
        || normalized.contains("secret=");

    if looks_sensitive {
        "[REDACTED]".to_string()
    } else {
        value
    }
}

#[derive(Debug, Clone, Copy)]
struct CurrencyAccumulator {
    request_final_cost_total: FixedDecimal,
    expected_ledger_amount_total: FixedDecimal,
    ledger_amount_total: FixedDecimal,
}

impl Default for CurrencyAccumulator {
    fn default() -> Self {
        let zero =
            FixedDecimal::zero(DEFAULT_MONEY_SCALE).expect("default money scale should be valid");
        Self {
            request_final_cost_total: zero,
            expected_ledger_amount_total: zero,
            ledger_amount_total: zero,
        }
    }
}

impl CurrencyAccumulator {
    fn add_request(
        &mut self,
        request_final_cost: FixedDecimal,
        expected_ledger_amount: FixedDecimal,
    ) -> Result<(), ReconciliationError> {
        self.request_final_cost_total = self
            .request_final_cost_total
            .checked_add(request_final_cost)
            .map_err(|_| ReconciliationError::ArithmeticOverflow)?;
        self.expected_ledger_amount_total = self
            .expected_ledger_amount_total
            .checked_add(expected_ledger_amount)
            .map_err(|_| ReconciliationError::ArithmeticOverflow)?;
        Ok(())
    }

    fn add_ledger(&mut self, amount: FixedDecimal) -> Result<(), ReconciliationError> {
        self.ledger_amount_total = self
            .ledger_amount_total
            .checked_add(amount)
            .map_err(|_| ReconciliationError::ArithmeticOverflow)?;
        Ok(())
    }

    fn into_total(
        self,
        currency: String,
    ) -> Result<BillingReconciliationCurrencyTotal, ReconciliationError> {
        Ok(BillingReconciliationCurrencyTotal {
            currency,
            request_final_cost_total: self.request_final_cost_total.to_string(),
            expected_ledger_amount_total: self.expected_ledger_amount_total.to_string(),
            ledger_amount_total: self.ledger_amount_total.to_string(),
            difference_amount: checked_subtract(
                self.ledger_amount_total,
                self.expected_ledger_amount_total,
            )?
            .to_string(),
        })
    }
}

fn parse_optional_money(
    field: &'static str,
    value: Option<&str>,
) -> Result<Option<FixedDecimal>, ReconciliationError> {
    value
        .map(|value| {
            FixedDecimal::parse(value, DEFAULT_MONEY_SCALE).map_err(|source| {
                ReconciliationError::InvalidMoney {
                    field,
                    value: value.to_string(),
                    source,
                }
            })
        })
        .transpose()
}

fn checked_neg(value: FixedDecimal) -> Result<FixedDecimal, ReconciliationError> {
    let units = value
        .units()
        .checked_neg()
        .ok_or(ReconciliationError::ArithmeticOverflow)?;
    FixedDecimal::from_units(units, value.scale())
        .map_err(|_| ReconciliationError::ArithmeticOverflow)
}

fn checked_subtract(
    left: FixedDecimal,
    right: FixedDecimal,
) -> Result<FixedDecimal, ReconciliationError> {
    left.checked_add(checked_neg(right)?)
        .map_err(|_| ReconciliationError::ArithmeticOverflow)
}

#[cfg(test)]
mod tests {
    use super::*;

    const TENANT_ID: Uuid = Uuid::from_u128(1);
    const PERIOD_START: &str = "2026-06-02 00:00:00+00";
    const PERIOD_END: &str = "2026-06-03 00:00:00+00";

    #[test]
    fn reconciliation_reports_missing_unexpected_and_amount_mismatches() {
        let matched_request_id = Uuid::from_u128(10);
        let missing_request_id = Uuid::from_u128(11);
        let mismatched_request_id = Uuid::from_u128(12);
        let unexpected_ledger_id = Uuid::from_u128(99);
        let report = reconcile_billing_usage_ledger(
            TENANT_ID,
            vec![
                request_with_ledger(matched_request_id, "0.25000000", "-0.25000000"),
                request_without_ledger(missing_request_id, "1.50000000"),
                request_with_ledger(mismatched_request_id, "2.00000000", "-1.75000000"),
                ledger_without_request(unexpected_ledger_id, "-0.12500000"),
            ],
            10,
        )
        .expect("report should reconcile");

        assert_eq!(report.tenant_id, TENANT_ID);
        assert_eq!(report.period_start, PERIOD_START);
        assert_eq!(report.period_end, PERIOD_END);
        assert_eq!(report.summary.request_count, 3);
        assert_eq!(report.summary.billable_request_count, 3);
        assert_eq!(report.summary.ledger_entry_count, 3);
        assert_eq!(report.summary.matched_request_count, 1);
        assert_eq!(report.summary.discrepancy_count, 3);
        assert_eq!(report.summary.missing_ledger_count, 1);
        assert_eq!(report.summary.unexpected_ledger_count, 1);
        assert_eq!(report.summary.amount_mismatch_count, 1);
        assert_eq!(report.summary.currency_mismatch_count, 0);
        assert_eq!(report.summary.returned_discrepancy_count, 3);
        assert_eq!(
            report.summary.currency_totals,
            vec![BillingReconciliationCurrencyTotal {
                currency: "USD".to_string(),
                request_final_cost_total: "3.75000000".to_string(),
                expected_ledger_amount_total: "-3.75000000".to_string(),
                ledger_amount_total: "-2.12500000".to_string(),
                difference_amount: "1.62500000".to_string(),
            }]
        );

        assert_eq!(
            report.discrepancies[0].issues,
            vec![ReconciliationIssue::MissingLedger]
        );
        assert_eq!(report.discrepancies[0].request_id, Some(missing_request_id));
        assert_eq!(
            report.discrepancies[0].expected_ledger_amount.as_deref(),
            Some("-1.50000000")
        );
        assert_eq!(
            report.discrepancies[1].issues,
            vec![ReconciliationIssue::AmountMismatch]
        );
        assert_eq!(
            report.discrepancies[1].difference_amount.as_deref(),
            Some("0.25000000")
        );
        assert_eq!(
            report.discrepancies[2].issues,
            vec![ReconciliationIssue::UnexpectedLedger]
        );
        assert_eq!(
            report.discrepancies[2].ledger_entry_ids,
            vec![unexpected_ledger_id]
        );
    }

    #[test]
    fn reconciliation_limits_returned_discrepancies_without_truncating_summary() {
        let report = reconcile_billing_usage_ledger(
            TENANT_ID,
            vec![
                request_without_ledger(Uuid::from_u128(21), "1.00000000"),
                request_without_ledger(Uuid::from_u128(22), "2.00000000"),
            ],
            1,
        )
        .expect("report should reconcile");

        assert_eq!(report.summary.discrepancy_count, 2);
        assert_eq!(report.summary.returned_discrepancy_count, 1);
        assert_eq!(report.discrepancies.len(), 1);
    }

    #[test]
    fn reconciliation_flags_currency_mismatch_without_amount_diff() {
        let mut row = request_with_ledger(Uuid::from_u128(31), "1.00000000", "-1.00000000");
        row.ledger_currency = Some("EUR".to_string());

        let report = reconcile_billing_usage_ledger(TENANT_ID, vec![row], 10)
            .expect("report should reconcile");

        assert_eq!(report.summary.currency_mismatch_count, 1);
        assert_eq!(
            report.discrepancies[0].issues,
            vec![ReconciliationIssue::CurrencyMismatch]
        );
        assert_eq!(report.discrepancies[0].difference_amount, None);
        assert_eq!(report.summary.currency_totals.len(), 2);
    }

    #[test]
    fn reconciliation_treats_zero_cost_without_ledger_as_matched() {
        let report = reconcile_billing_usage_ledger(
            TENANT_ID,
            vec![request_without_ledger(Uuid::from_u128(41), "0.00000000")],
            10,
        )
        .expect("report should reconcile");

        assert_eq!(report.summary.request_count, 1);
        assert_eq!(report.summary.billable_request_count, 0);
        assert_eq!(report.summary.matched_request_count, 1);
        assert_eq!(report.summary.discrepancy_count, 0);
        assert!(report.discrepancies.is_empty());
    }

    #[test]
    fn reconciliation_redacts_secret_like_display_fields() {
        let mut row = request_without_ledger(Uuid::from_u128(51), "1.00000000");
        row.trace_id = Some("Bearer trace-secret".to_string());
        row.requested_model = Some("sk-model-secret".to_string());
        row.upstream_model = Some("safe-upstream".to_string());
        row.request_currency = Some("api_key=currency-secret".to_string());

        let report =
            reconcile_billing_usage_ledger(TENANT_ID, vec![row], 10).expect("report should build");
        let serialized = serde_json::to_string(&report).expect("report should serialize");

        assert_eq!(
            report.discrepancies[0].trace_id.as_deref(),
            Some("[REDACTED]")
        );
        assert_eq!(
            report.discrepancies[0].requested_model.as_deref(),
            Some("[REDACTED]")
        );
        assert_eq!(
            report.discrepancies[0].upstream_model.as_deref(),
            Some("safe-upstream")
        );
        assert!(!serialized.contains("trace-secret"));
        assert!(!serialized.contains("sk-model-secret"));
        assert!(!serialized.contains("currency-secret"));
    }

    fn request_without_ledger(request_id: Uuid, final_cost: &str) -> BillingReconciliationInputRow {
        base_row(Some(request_id), vec![], 0, None).with_request(final_cost)
    }

    fn request_with_ledger(
        request_id: Uuid,
        final_cost: &str,
        ledger_amount: &str,
    ) -> BillingReconciliationInputRow {
        base_row(
            Some(request_id),
            vec![Uuid::from_u128(request_id.as_u128() + 1_000)],
            1,
            Some(ledger_amount),
        )
        .with_request(final_cost)
    }

    fn ledger_without_request(ledger_id: Uuid, amount: &str) -> BillingReconciliationInputRow {
        base_row(None, vec![ledger_id], 1, Some(amount))
    }

    fn base_row(
        request_id: Option<Uuid>,
        ledger_entry_ids: Vec<Uuid>,
        ledger_entry_count: i64,
        ledger_amount: Option<&str>,
    ) -> BillingReconciliationInputRow {
        BillingReconciliationInputRow {
            tenant_id: TENANT_ID,
            period_start: PERIOD_START.to_string(),
            period_end: PERIOD_END.to_string(),
            request_id,
            project_id: Some(Uuid::from_u128(2)),
            virtual_key_id: Some(Uuid::from_u128(3)),
            trace_id: Some("trace-safe".to_string()),
            canonical_model_id: Some(Uuid::from_u128(4)),
            resolved_provider_id: Some(Uuid::from_u128(5)),
            resolved_channel_id: Some(Uuid::from_u128(6)),
            requested_model: Some("gpt-test".to_string()),
            upstream_model: Some("provider-gpt-test".to_string()),
            request_status: None,
            input_tokens: None,
            output_tokens: None,
            request_final_cost: None,
            request_currency: None,
            ledger_entry_ids,
            ledger_entry_count,
            ledger_amount: ledger_amount.map(str::to_string),
            ledger_currency: ledger_amount.map(|_| "USD".to_string()),
        }
    }

    trait WithRequest {
        fn with_request(self, final_cost: &str) -> Self;
    }

    impl WithRequest for BillingReconciliationInputRow {
        fn with_request(mut self, final_cost: &str) -> Self {
            self.request_status = Some("succeeded".to_string());
            self.input_tokens = Some(12);
            self.output_tokens = Some(34);
            self.request_final_cost = Some(final_cost.to_string());
            self.request_currency = Some("USD".to_string());
            self
        }
    }
}
