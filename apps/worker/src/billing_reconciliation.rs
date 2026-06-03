use ai_gateway_billing_ledger::{
    BillingReconciliationInputRow, BillingReconciliationReport, DEFAULT_MONEY_SCALE, FixedDecimal,
    reconcile_billing_usage_ledger,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{collections::BTreeSet, fs};
use uuid::Uuid;

const DEFAULT_DISCREPANCY_LIMIT: usize = 50;
const MAX_DISCREPANCY_LIMIT: usize = 500;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum BillingReconciliationMode {
    DryRun,
    Execute,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum BillingReconciliationInputSource {
    InputJson { path: String },
}

#[derive(Debug, Clone, Deserialize)]
pub(crate) struct BillingReconciliationInput {
    #[serde(default)]
    tenant_id: Option<Uuid>,
    #[serde(default)]
    day: Option<String>,
    #[serde(default)]
    window: BillingReconciliationWindowInput,
    #[serde(default)]
    scheduler: BillingReconciliationSchedulerInput,
    #[serde(default)]
    project_id: Option<Uuid>,
    #[serde(default)]
    project_ids: Vec<Uuid>,
    #[serde(default, alias = "limit")]
    discrepancy_limit: Option<usize>,
    #[serde(default, alias = "reconciliation_rows")]
    rows: Vec<BillingReconciliationRowInput>,
}

#[derive(Debug, Clone, Default, Deserialize)]
struct BillingReconciliationWindowInput {
    #[serde(default)]
    period_start: Option<String>,
    #[serde(default)]
    period_end: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
struct BillingReconciliationSchedulerInput {
    #[serde(default)]
    now_utc: Option<String>,
    #[serde(default)]
    last_run: BillingReconciliationLastRunInput,
    #[serde(default)]
    watermark: BillingReconciliationWatermarkInput,
}

#[derive(Debug, Clone, Default, Deserialize)]
struct BillingReconciliationLastRunInput {
    #[serde(default)]
    run_id: Option<String>,
    #[serde(default)]
    status: Option<String>,
    #[serde(default)]
    started_at: Option<String>,
    #[serde(default)]
    finished_at: Option<String>,
    #[serde(default)]
    window_day: Option<String>,
    #[serde(default)]
    window_start: Option<String>,
    #[serde(default)]
    window_end: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
struct BillingReconciliationWatermarkInput {
    #[serde(default)]
    kind: Option<String>,
    #[serde(default)]
    value: Option<String>,
    #[serde(default)]
    updated_at: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
struct BillingReconciliationRowInput {
    #[serde(default)]
    tenant_id: Option<Uuid>,
    #[serde(default)]
    period_start: Option<String>,
    #[serde(default)]
    period_end: Option<String>,
    #[serde(default)]
    request_id: Option<Uuid>,
    #[serde(default)]
    project_id: Option<Uuid>,
    #[serde(default)]
    virtual_key_id: Option<Uuid>,
    #[serde(default)]
    trace_id: Option<String>,
    #[serde(default)]
    canonical_model_id: Option<Uuid>,
    #[serde(default)]
    resolved_provider_id: Option<Uuid>,
    #[serde(default)]
    resolved_channel_id: Option<Uuid>,
    #[serde(default)]
    requested_model: Option<String>,
    #[serde(default)]
    upstream_model: Option<String>,
    #[serde(default)]
    request_status: Option<String>,
    #[serde(default)]
    input_tokens: Option<i64>,
    #[serde(default)]
    output_tokens: Option<i64>,
    #[serde(default)]
    request_final_cost: Option<String>,
    #[serde(default)]
    request_currency: Option<String>,
    #[serde(default)]
    ledger_entry_ids: Vec<Uuid>,
    #[serde(default)]
    ledger_entry_count: Option<i64>,
    #[serde(default)]
    ledger_amount: Option<String>,
    #[serde(default)]
    ledger_currency: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub(crate) struct BillingReconciliationPlan {
    schema_version: &'static str,
    dry_run: bool,
    mode: &'static str,
    read_only: bool,
    db_writes: bool,
    outbound_calls: bool,
    alert_send: bool,
    scheduler: BillingReconciliationSchedulerPlan,
    window: BillingReconciliationWindowPlan,
    scope: BillingReconciliationScopePlan,
    source: BillingReconciliationSourceReport,
    input: BillingReconciliationInputReport,
    contract: BillingReconciliationContractReport,
    would_report: BillingReconciliationWouldReport,
    report: BillingReconciliationReport,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct BillingReconciliationSchedulerPlan {
    job_name: &'static str,
    cadence: &'static str,
    trigger: &'static str,
    timezone: &'static str,
    window_policy: &'static str,
    day_source: &'static str,
    now_utc: Option<String>,
    last_run: BillingReconciliationLastRunPlan,
    watermark: BillingReconciliationWatermarkPlan,
    execute_supported: bool,
    send_supported: bool,
    future_writer_required: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct BillingReconciliationWindowPlan {
    day: String,
    period_start: String,
    period_end: String,
    timezone: &'static str,
    bounds: &'static str,
    computed_from_utc_day: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct BillingReconciliationLastRunPlan {
    present: bool,
    run_id: Option<String>,
    status: Option<String>,
    started_at: Option<String>,
    finished_at: Option<String>,
    window_day: Option<String>,
    window_start: Option<String>,
    window_end: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct BillingReconciliationWatermarkPlan {
    present: bool,
    kind: String,
    value: Option<String>,
    updated_at: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
struct BillingReconciliationSchedulerState {
    now_utc: Option<String>,
    last_run: BillingReconciliationLastRunPlan,
    watermark: BillingReconciliationWatermarkPlan,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct BillingReconciliationScopePlan {
    tenant_id: Uuid,
    all_projects: bool,
    project_ids: Vec<Uuid>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct BillingReconciliationSourceReport {
    kind: &'static str,
    input_path: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct BillingReconciliationInputReport {
    row_count: usize,
    selected_row_count: usize,
    discrepancy_limit: usize,
    tenant_filter_applied: bool,
    project_filter_applied: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct BillingReconciliationContractReport {
    covered_scenarios: Vec<&'static str>,
    stable_fields: Vec<&'static str>,
    request_material_omitted: bool,
    header_credentials_redacted: bool,
    provider_credentials_redacted: bool,
    wallet_credentials_redacted: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct BillingReconciliationWouldReport {
    discrepancies: bool,
    discrepancy_count: usize,
    returned_discrepancy_count: usize,
    missing_settle_count: usize,
    unexpected_ledger_count: usize,
    amount_mismatch_count: usize,
    currency_mismatch_count: usize,
    zero_cost_matched_count: usize,
}

pub(crate) fn read_billing_reconciliation_input(
    input_path: Option<&str>,
) -> Result<(BillingReconciliationInputSource, BillingReconciliationInput), String> {
    let Some(path) = input_path else {
        return Err(
            "billing-reconciliation dry-run requires --input <json>; DB scheduler reads are future work"
                .to_string(),
        );
    };

    let body = fs::read_to_string(path).map_err(|error| {
        format!(
            "failed to read billing reconciliation input `{}`: {}",
            super::safe_plan_text(path),
            super::safe_error_text(&error.to_string())
        )
    })?;
    let input = billing_reconciliation_input_from_json_str(&body)?;

    Ok((
        BillingReconciliationInputSource::InputJson {
            path: path.to_string(),
        },
        input,
    ))
}

pub(crate) fn billing_reconciliation_input_from_json_str(
    body: &str,
) -> Result<BillingReconciliationInput, String> {
    let value = serde_json::from_str::<Value>(body).map_err(|error| {
        format!(
            "billing reconciliation input must be valid JSON: {}",
            super::safe_error_text(&error.to_string())
        )
    })?;
    let input = value.get("input").cloned().unwrap_or(value);
    serde_json::from_value::<BillingReconciliationInput>(input).map_err(|error| {
        format!(
            "billing reconciliation input shape is invalid: {}",
            super::safe_error_text(&error.to_string())
        )
    })
}

pub(crate) fn billing_reconciliation_plan(
    tenant_id_override: Option<Uuid>,
    project_id_overrides: Vec<Uuid>,
    day_override: Option<String>,
    discrepancy_limit_override: Option<usize>,
    source: BillingReconciliationInputSource,
    input: BillingReconciliationInput,
) -> Result<BillingReconciliationPlan, String> {
    let source_row_count = input.rows.len();
    let input_day = optional_iso_day(input.day)?;
    let override_day = optional_iso_day(day_override)?;
    let (day, day_source) = if let Some(day) = override_day {
        (day, "cli_day")
    } else if let Some(day) = input_day {
        (day, "input_day")
    } else if let Some(day) = day_from_period_start(input.window.period_start.as_deref()) {
        (day, "input_window")
    } else if let Some(day) = input
        .rows
        .iter()
        .find_map(|row| day_from_period_start(row.period_start.as_deref()))
    {
        (day, "row_period_start")
    } else if let Some(now_utc) = input.scheduler.now_utc.as_deref() {
        (previous_completed_utc_day(now_utc)?, "scheduler_now_utc")
    } else {
        return Err(
            "billing-reconciliation requires day/window metadata, scheduler.now_utc, or at least one row period_start"
                .to_string(),
        );
    };
    let scheduler_state = scheduler_state_report(input.scheduler, day_source)?;
    let window = resolved_window(&day, input.window)?;
    let tenant_id = tenant_id_override
        .or(input.tenant_id)
        .or_else(|| input.rows.iter().find_map(|row| row.tenant_id))
        .unwrap_or(super::DEFAULT_TENANT_ID);
    let project_ids = project_scope(project_id_overrides, input.project_id, input.project_ids);
    let discrepancy_limit =
        normalize_discrepancy_limit(discrepancy_limit_override.or(input.discrepancy_limit))?;

    let mut rows = input
        .rows
        .into_iter()
        .map(|row| row.into_reconciliation_row(tenant_id, &window))
        .collect::<Result<Vec<_>, _>>()?;
    rows.retain(|row| row.tenant_id == tenant_id);

    if !project_ids.is_empty() {
        rows.retain(|row| {
            row.project_id
                .is_some_and(|project_id| project_ids.contains(&project_id))
        });
    }

    let selected_row_count = rows.len();
    let project_filter_applied = !project_ids.is_empty();
    let zero_cost_matched_count = rows.iter().filter(|row| is_zero_cost_matched(row)).count();
    let report = reconcile_billing_usage_ledger(tenant_id, rows, discrepancy_limit)
        .map_err(|error| super::safe_error_text(&error.to_string()))?;

    Ok(BillingReconciliationPlan {
        schema_version: "billing_reconciliation_plan.v1",
        dry_run: true,
        mode: "plan_only",
        read_only: true,
        db_writes: false,
        outbound_calls: false,
        alert_send: false,
        scheduler: BillingReconciliationSchedulerPlan {
            job_name: "daily_billing_reconciliation",
            cadence: "daily",
            trigger: "manual_cli_dry_run",
            timezone: "UTC",
            window_policy: "previous_completed_utc_day",
            day_source,
            now_utc: scheduler_state.now_utc,
            last_run: scheduler_state.last_run,
            watermark: scheduler_state.watermark,
            execute_supported: false,
            send_supported: false,
            future_writer_required: true,
        },
        window,
        scope: BillingReconciliationScopePlan {
            tenant_id,
            all_projects: project_ids.is_empty(),
            project_ids,
        },
        source: source_report(source),
        input: BillingReconciliationInputReport {
            row_count: source_row_count,
            selected_row_count,
            discrepancy_limit,
            tenant_filter_applied: true,
            project_filter_applied,
        },
        contract: BillingReconciliationContractReport {
            covered_scenarios: vec![
                "missing_settle",
                "unexpected_ledger",
                "amount_mismatch",
                "zero_cost_matched",
                "daily_scheduler_window",
                "last_run_watermark",
            ],
            stable_fields: vec![
                "schema_version",
                "dry_run",
                "read_only",
                "scheduler",
                "scheduler.last_run",
                "scheduler.watermark",
                "window",
                "scope",
                "would_report",
                "report.summary",
                "report.discrepancies",
            ],
            request_material_omitted: true,
            header_credentials_redacted: true,
            provider_credentials_redacted: true,
            wallet_credentials_redacted: true,
        },
        would_report: BillingReconciliationWouldReport {
            discrepancies: report.summary.discrepancy_count > 0,
            discrepancy_count: report.summary.discrepancy_count,
            returned_discrepancy_count: report.summary.returned_discrepancy_count,
            missing_settle_count: report.summary.missing_ledger_count,
            unexpected_ledger_count: report.summary.unexpected_ledger_count,
            amount_mismatch_count: report.summary.amount_mismatch_count,
            currency_mismatch_count: report.summary.currency_mismatch_count,
            zero_cost_matched_count,
        },
        report,
    })
}

pub(crate) fn billing_reconciliation_execute_error(force: bool) -> String {
    if force {
        return "billing-reconciliation execute/send is not implemented in this dry-run slice; future DB writer and alert sender are required"
            .to_string();
    }

    "billing-reconciliation execute/send requires --force and is not implemented in this dry-run slice; future DB writer and alert sender are required"
        .to_string()
}

impl BillingReconciliationRowInput {
    fn into_reconciliation_row(
        self,
        tenant_id: Uuid,
        window: &BillingReconciliationWindowPlan,
    ) -> Result<BillingReconciliationInputRow, String> {
        let ledger_entry_count = self
            .ledger_entry_count
            .unwrap_or(self.ledger_entry_ids.len() as i64);
        if ledger_entry_count < 0 {
            return Err("ledger_entry_count must be zero or greater".to_string());
        }

        Ok(BillingReconciliationInputRow {
            tenant_id: self.tenant_id.unwrap_or(tenant_id),
            period_start: self
                .period_start
                .unwrap_or_else(|| window.period_start.clone()),
            period_end: self.period_end.unwrap_or_else(|| window.period_end.clone()),
            request_id: self.request_id,
            project_id: self.project_id,
            virtual_key_id: self.virtual_key_id,
            trace_id: self.trace_id.map(safe_text),
            canonical_model_id: self.canonical_model_id,
            resolved_provider_id: self.resolved_provider_id,
            resolved_channel_id: self.resolved_channel_id,
            requested_model: self.requested_model.map(safe_text),
            upstream_model: self.upstream_model.map(safe_text),
            request_status: self.request_status.map(safe_text),
            input_tokens: self.input_tokens,
            output_tokens: self.output_tokens,
            request_final_cost: self.request_final_cost,
            request_currency: self.request_currency.map(safe_text),
            ledger_entry_ids: self.ledger_entry_ids,
            ledger_entry_count,
            ledger_amount: self.ledger_amount,
            ledger_currency: self.ledger_currency.map(safe_text),
        })
    }
}

fn resolved_window(
    day: &str,
    input: BillingReconciliationWindowInput,
) -> Result<BillingReconciliationWindowPlan, String> {
    let computed_from_utc_day = input.period_start.is_none() && input.period_end.is_none();
    let default_period_start = format!("{day} 00:00:00+00");
    let default_period_end = format!("{} 00:00:00+00", next_iso_day(day)?);
    let period_start = optional_utc_timestamp(input.period_start, "window.period_start")?
        .unwrap_or(default_period_start);
    let period_end = optional_utc_timestamp(input.period_end, "window.period_end")?
        .unwrap_or(default_period_end);

    Ok(BillingReconciliationWindowPlan {
        day: day.to_string(),
        period_start,
        period_end,
        timezone: "UTC",
        bounds: "closed_open",
        computed_from_utc_day,
    })
}

fn scheduler_state_report(
    input: BillingReconciliationSchedulerInput,
    day_source: &'static str,
) -> Result<BillingReconciliationSchedulerState, String> {
    let now_utc = optional_utc_timestamp(input.now_utc, "scheduler.now_utc")?;
    let last_run = last_run_report(input.last_run)?;
    let watermark = watermark_report(input.watermark)?;

    if day_source == "scheduler_now_utc" && now_utc.is_none() {
        return Err(
            "scheduler.now_utc is required when deriving the day from scheduler state".to_string(),
        );
    }

    Ok(BillingReconciliationSchedulerState {
        now_utc,
        last_run,
        watermark,
    })
}

fn last_run_report(
    input: BillingReconciliationLastRunInput,
) -> Result<BillingReconciliationLastRunPlan, String> {
    let run_id = optional_safe_text(input.run_id);
    let status = optional_safe_text(input.status);
    let started_at = optional_utc_timestamp(input.started_at, "scheduler.last_run.started_at")?;
    let finished_at = optional_utc_timestamp(input.finished_at, "scheduler.last_run.finished_at")?;
    let window_day = optional_iso_day(input.window_day)?;
    let window_start =
        optional_utc_timestamp(input.window_start, "scheduler.last_run.window_start")?;
    let window_end = optional_utc_timestamp(input.window_end, "scheduler.last_run.window_end")?;
    let present = run_id.is_some()
        || status.is_some()
        || started_at.is_some()
        || finished_at.is_some()
        || window_day.is_some()
        || window_start.is_some()
        || window_end.is_some();

    Ok(BillingReconciliationLastRunPlan {
        present,
        run_id,
        status,
        started_at,
        finished_at,
        window_day,
        window_start,
        window_end,
    })
}

fn watermark_report(
    input: BillingReconciliationWatermarkInput,
) -> Result<BillingReconciliationWatermarkPlan, String> {
    let kind = optional_safe_text(input.kind).unwrap_or_else(|| "window_end".to_string());
    let value = optional_utc_timestamp(input.value, "scheduler.watermark.value")?;
    let updated_at = optional_utc_timestamp(input.updated_at, "scheduler.watermark.updated_at")?;
    let present = value.is_some() || updated_at.is_some();

    Ok(BillingReconciliationWatermarkPlan {
        present,
        kind,
        value,
        updated_at,
    })
}

fn project_scope(
    project_id_overrides: Vec<Uuid>,
    input_project_id: Option<Uuid>,
    input_project_ids: Vec<Uuid>,
) -> Vec<Uuid> {
    let mut unique = BTreeSet::new();
    if project_id_overrides.is_empty() {
        unique.extend(input_project_ids);
        if let Some(project_id) = input_project_id {
            unique.insert(project_id);
        }
    } else {
        unique.extend(project_id_overrides);
    }

    unique.into_iter().collect()
}

fn source_report(source: BillingReconciliationInputSource) -> BillingReconciliationSourceReport {
    match source {
        BillingReconciliationInputSource::InputJson { path } => BillingReconciliationSourceReport {
            kind: "input_json",
            input_path: super::safe_plan_text(&path),
        },
    }
}

fn normalize_discrepancy_limit(limit: Option<usize>) -> Result<usize, String> {
    let limit = limit.unwrap_or(DEFAULT_DISCREPANCY_LIMIT);
    if limit == 0 {
        return Err("limit must be at least 1".to_string());
    }
    Ok(limit.min(MAX_DISCREPANCY_LIMIT))
}

fn optional_iso_day(value: Option<String>) -> Result<Option<String>, String> {
    let Some(value) = value else {
        return Ok(None);
    };
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    if is_valid_iso_day(trimmed) {
        Ok(Some(trimmed.to_string()))
    } else {
        Err("day must use YYYY-MM-DD".to_string())
    }
}

fn optional_utc_timestamp(value: Option<String>, field: &str) -> Result<Option<String>, String> {
    let Some(value) = value else {
        return Ok(None);
    };
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    if !is_utc_timestamp(trimmed) {
        return Err(format!(
            "{field} must be a UTC timestamp ending in Z, +00, or +00:00"
        ));
    }

    Ok(Some(safe_text(trimmed.to_string())))
}

fn optional_safe_text(value: Option<String>) -> Option<String> {
    value
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .map(safe_text)
}

fn day_from_period_start(period_start: Option<&str>) -> Option<String> {
    let period_start = period_start?.trim();
    let day = period_start.get(..10)?;
    is_valid_iso_day(day).then(|| day.to_string())
}

fn previous_completed_utc_day(now_utc: &str) -> Result<String, String> {
    let day = utc_day_from_timestamp(now_utc)?;
    previous_iso_day(&day)
}

fn utc_day_from_timestamp(value: &str) -> Result<String, String> {
    let trimmed = value.trim();
    if !is_utc_timestamp(trimmed) {
        return Err(
            "scheduler.now_utc must be a UTC timestamp ending in Z, +00, or +00:00".to_string(),
        );
    }
    Ok(trimmed[..10].to_string())
}

fn is_utc_timestamp(value: &str) -> bool {
    value.len() >= 11
        && value.get(..10).is_some_and(is_valid_iso_day)
        && value
            .as_bytes()
            .get(10)
            .is_some_and(|byte| matches!(byte, b'T' | b' '))
        && (value.ends_with('Z') || value.ends_with("+00") || value.ends_with("+00:00"))
}

fn is_valid_iso_day(day: &str) -> bool {
    let bytes = day.as_bytes();
    if bytes.len() != 10 || bytes[4] != b'-' || bytes[7] != b'-' {
        return false;
    }
    if !bytes[..4].iter().all(u8::is_ascii_digit)
        || !bytes[5..7].iter().all(u8::is_ascii_digit)
        || !bytes[8..10].iter().all(u8::is_ascii_digit)
    {
        return false;
    }

    let Ok(year) = day[..4].parse::<u16>() else {
        return false;
    };
    let Ok(month) = day[5..7].parse::<u8>() else {
        return false;
    };
    let Ok(day_of_month) = day[8..10].parse::<u8>() else {
        return false;
    };
    if month == 0 || month > 12 || day_of_month == 0 {
        return false;
    }

    day_of_month <= max_day_of_month(year, month)
}

fn previous_iso_day(day: &str) -> Result<String, String> {
    let year = day[..4]
        .parse::<u16>()
        .map_err(|_| "day must use YYYY-MM-DD".to_string())?;
    let month = day[5..7]
        .parse::<u8>()
        .map_err(|_| "day must use YYYY-MM-DD".to_string())?;
    let day_of_month = day[8..10]
        .parse::<u8>()
        .map_err(|_| "day must use YYYY-MM-DD".to_string())?;

    let (previous_year, previous_month, previous_day) = if day_of_month > 1 {
        (year, month, day_of_month - 1)
    } else if month > 1 {
        let previous_month = month - 1;
        (year, previous_month, max_day_of_month(year, previous_month))
    } else if year > 0 {
        (year - 1, 12, 31)
    } else {
        return Err("day must be after 0000-01-01".to_string());
    };

    Ok(format!(
        "{previous_year:04}-{previous_month:02}-{previous_day:02}"
    ))
}

fn next_iso_day(day: &str) -> Result<String, String> {
    let year = day[..4]
        .parse::<u16>()
        .map_err(|_| "day must use YYYY-MM-DD".to_string())?;
    let month = day[5..7]
        .parse::<u8>()
        .map_err(|_| "day must use YYYY-MM-DD".to_string())?;
    let day_of_month = day[8..10]
        .parse::<u8>()
        .map_err(|_| "day must use YYYY-MM-DD".to_string())?;

    let max_day = max_day_of_month(year, month);
    let (next_year, next_month, next_day) = if day_of_month < max_day {
        (year, month, day_of_month + 1)
    } else if month < 12 {
        (year, month + 1, 1)
    } else {
        (year + 1, 1, 1)
    };

    Ok(format!("{next_year:04}-{next_month:02}-{next_day:02}"))
}

fn max_day_of_month(year: u16, month: u8) -> u8 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if is_leap_year(year) => 29,
        2 => 28,
        _ => 0,
    }
}

fn is_leap_year(year: u16) -> bool {
    (year.is_multiple_of(4) && !year.is_multiple_of(100)) || year.is_multiple_of(400)
}

fn is_zero_cost_matched(row: &BillingReconciliationInputRow) -> bool {
    row.request_final_cost
        .as_deref()
        .and_then(|value| FixedDecimal::parse(value, DEFAULT_MONEY_SCALE).ok())
        .is_some_and(FixedDecimal::is_zero)
        && row.ledger_entry_count == 0
}

fn safe_text(value: String) -> String {
    super::safe_plan_text(&value)
}

#[cfg(test)]
mod tests {
    use super::*;

    const TENANT_ID: Uuid = Uuid::from_u128(0x00000000_0000_0000_0000_000000000001);

    #[test]
    fn fixture_builds_daily_reconciliation_plan_contract() {
        let input = billing_reconciliation_input_from_json_str(include_str!(
            "../../../tests/fixtures/worker/billing_reconciliation_plan_contract.json"
        ))
        .expect("fixture should parse");

        let plan = billing_reconciliation_plan(
            None,
            Vec::new(),
            None,
            None,
            BillingReconciliationInputSource::InputJson {
                path: "tests/fixtures/worker/billing_reconciliation_plan_contract.json".to_string(),
            },
            input,
        )
        .expect("plan should build");

        assert!(plan.dry_run);
        assert!(plan.read_only);
        assert!(!plan.db_writes);
        assert!(!plan.outbound_calls);
        assert!(!plan.alert_send);
        assert_eq!(plan.scheduler.timezone, "UTC");
        assert_eq!(plan.scheduler.window_policy, "previous_completed_utc_day");
        assert_eq!(plan.scheduler.day_source, "input_day");
        assert!(plan.scheduler.last_run.present);
        assert_eq!(
            plan.scheduler.last_run.window_day.as_deref(),
            Some("2026-06-01")
        );
        assert!(plan.scheduler.watermark.present);
        assert_eq!(
            plan.scheduler.watermark.value.as_deref(),
            Some("2026-06-02T00:00:00Z")
        );
        assert_eq!(plan.window.day, "2026-06-02");
        assert_eq!(plan.window.bounds, "closed_open");
        assert_eq!(plan.scope.tenant_id, TENANT_ID);
        assert!(!plan.scope.all_projects);
        assert_eq!(plan.input.row_count, 5);
        assert_eq!(plan.input.selected_row_count, 5);
        assert!(plan.would_report.discrepancies);
        assert_eq!(plan.would_report.discrepancy_count, 3);
        assert_eq!(plan.would_report.returned_discrepancy_count, 3);
        assert_eq!(plan.would_report.missing_settle_count, 1);
        assert_eq!(plan.would_report.unexpected_ledger_count, 1);
        assert_eq!(plan.would_report.amount_mismatch_count, 1);
        assert_eq!(plan.would_report.zero_cost_matched_count, 1);
        assert_eq!(plan.report.summary.matched_request_count, 2);
    }

    #[test]
    fn plan_serialization_omits_request_and_credential_material() {
        let fixture = include_str!(
            "../../../tests/fixtures/worker/billing_reconciliation_plan_contract.json"
        );
        let input = billing_reconciliation_input_from_json_str(fixture).expect("fixture parses");
        let plan = billing_reconciliation_plan(
            None,
            Vec::new(),
            None,
            None,
            BillingReconciliationInputSource::InputJson {
                path: "tests/fixtures/worker/billing_reconciliation_plan_contract.json".to_string(),
            },
            input,
        )
        .expect("plan should build");
        let serialized = serde_json::to_string(&plan).expect("plan should serialize");

        for forbidden in [
            "fixture-raw-payload-marker",
            "fixture-request-material-marker",
            "X-Fixture-Credential",
            "fixture-header-marker",
            "fixture-header-credential-marker",
            "fixture-provider-credential-marker",
            "provider_key_value",
            "fixture-wallet-credential-marker",
            "raw_wallet_secret",
            "wallet_secret_value",
            "payload_body_redacted",
            "provider_key_secret_redacted",
            "wallet_secret_redacted",
        ] {
            assert!(
                !serialized.contains(forbidden),
                "serialized plan leaked `{forbidden}`"
            );
        }
    }

    #[test]
    fn scheduler_now_utc_derives_previous_completed_utc_day() {
        let input = billing_reconciliation_input_from_json_str(
            r#"{"input":{"tenant_id":"00000000-0000-0000-0000-000000000001","scheduler":{"now_utc":"2024-03-01T00:05:00Z"},"rows":[]}}"#,
        )
        .expect("shape should parse");

        let plan = billing_reconciliation_plan(
            None,
            Vec::new(),
            None,
            None,
            BillingReconciliationInputSource::InputJson {
                path: "fixture.json".to_string(),
            },
            input,
        )
        .expect("plan should derive scheduler day");

        assert_eq!(plan.scheduler.day_source, "scheduler_now_utc");
        assert_eq!(plan.window.day, "2024-02-29");
        assert_eq!(plan.window.period_start, "2024-02-29 00:00:00+00");
        assert_eq!(plan.window.period_end, "2024-03-01 00:00:00+00");
        assert!(plan.window.computed_from_utc_day);
    }

    #[test]
    fn scheduler_metadata_is_secret_safe() {
        let input = billing_reconciliation_input_from_json_str(
            r#"{"input":{"tenant_id":"00000000-0000-0000-0000-000000000001","scheduler":{"now_utc":"2026-06-03T01:15:00Z","last_run":{"run_id":"run-secret-token-marker","status":"finished with credential-marker","started_at":"2026-06-03T01:00:00Z"},"watermark":{"kind":"credential-marker","value":"2026-06-03T00:00:00Z","updated_at":"2026-06-03T01:01:00Z"}},"rows":[]}}"#,
        )
        .expect("shape should parse");

        let plan = billing_reconciliation_plan(
            None,
            Vec::new(),
            None,
            None,
            BillingReconciliationInputSource::InputJson {
                path: "fixture.json".to_string(),
            },
            input,
        )
        .expect("plan should build");
        let serialized = serde_json::to_string(&plan).expect("plan should serialize");

        assert!(!serialized.contains("run-secret-token-marker"));
        assert!(!serialized.contains("credential-marker"));
        assert!(serialized.contains("[REDACTED]"));
    }

    #[test]
    fn project_override_filters_fixture_rows() {
        let input = billing_reconciliation_input_from_json_str(include_str!(
            "../../../tests/fixtures/worker/billing_reconciliation_plan_contract.json"
        ))
        .expect("fixture should parse");
        let project_id = Uuid::from_u128(0x00000000_0000_0000_0000_000000000020);

        let plan = billing_reconciliation_plan(
            None,
            vec![project_id],
            None,
            Some(10),
            BillingReconciliationInputSource::InputJson {
                path: "fixture.json".to_string(),
            },
            input,
        )
        .expect("plan should build");

        assert_eq!(plan.scope.project_ids, vec![project_id]);
        assert_eq!(plan.input.selected_row_count, 5);
        assert_eq!(plan.input.discrepancy_limit, 10);
    }

    #[test]
    fn invalid_day_is_rejected() {
        let input = billing_reconciliation_input_from_json_str(
            r#"{"input":{"tenant_id":"00000000-0000-0000-0000-000000000001","day":"2026-02-29","rows":[]}}"#,
        )
        .expect("shape should parse");

        let error = billing_reconciliation_plan(
            None,
            Vec::new(),
            None,
            None,
            BillingReconciliationInputSource::InputJson {
                path: "fixture.json".to_string(),
            },
            input,
        )
        .expect_err("invalid calendar day should fail");

        assert!(error.contains("YYYY-MM-DD"));
    }

    #[test]
    fn scheduler_now_utc_must_be_utc() {
        let input = billing_reconciliation_input_from_json_str(
            r#"{"input":{"tenant_id":"00000000-0000-0000-0000-000000000001","scheduler":{"now_utc":"2026-06-03T01:15:00+08:00"},"rows":[]}}"#,
        )
        .expect("shape should parse");

        let error = billing_reconciliation_plan(
            None,
            Vec::new(),
            None,
            None,
            BillingReconciliationInputSource::InputJson {
                path: "fixture.json".to_string(),
            },
            input,
        )
        .expect_err("non-UTC scheduler timestamp should fail");

        assert!(error.contains("UTC timestamp"));
    }

    #[test]
    fn execute_error_requires_future_writer() {
        assert!(billing_reconciliation_execute_error(false).contains("requires --force"));
        assert!(billing_reconciliation_execute_error(true).contains("future DB writer"));
    }
}
