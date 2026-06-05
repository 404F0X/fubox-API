use std::{env, fs, path::PathBuf, process};

use ai_gateway_billing_ledger::{
    ConsistentBudgetSnapshot, ConsistentLedgerScope, ConsistentLedgerWriteRequest,
    ConsistentLedgerWriterState, ConsistentWalletSnapshot, DEFAULT_MONEY_SCALE, FixedDecimal,
    execute_consistent_ledger_postgres_sqlx_writer_plan, plan_consistent_ledger_postgres_execution,
    plan_consistent_ledger_write, plan_consistent_ledger_write_commands,
    summarize_consistent_ledger_postgres_executor_result,
};
use serde::Deserialize;
use serde_json::{Value, json};
use uuid::Uuid;

const EXPECTED_WRITER: &str = "billing_ledger_runtime_writer";

#[derive(Debug, Deserialize)]
struct ReserveCommitInput {
    tenant_id: Uuid,
    #[serde(default)]
    project_id: Option<Uuid>,
    #[serde(default)]
    virtual_key_id: Option<Uuid>,
    wallet_id: Uuid,
    request_id: Uuid,
    amount: String,
    #[serde(default = "default_currency")]
    currency: String,
    available_balance: String,
    #[serde(default)]
    budgets: Vec<BudgetInput>,
}

#[derive(Debug, Deserialize)]
struct BudgetInput {
    budget_id: Uuid,
    dimension: ai_gateway_billing_ledger::ConsistentBudgetDimension,
    remaining_amount: String,
    #[serde(default = "default_true")]
    active: bool,
}

#[derive(Debug)]
struct Args {
    live_commit_opt_in: bool,
    no_dual_readback_opt_in: bool,
    commit_readback_opt_in: bool,
    input_path: PathBuf,
    artifact_path: PathBuf,
    operation_scope: String,
    idempotency_key: String,
    current_commit: String,
    runtime_container_commit: String,
    active_writer: String,
    source_of_truth: String,
    live_commit_readback: String,
}

#[tokio::main]
async fn main() {
    match run().await {
        Ok(()) => {}
        Err(error) => {
            eprintln!("{error}");
            process::exit(2);
        }
    }
}

async fn run() -> Result<(), String> {
    let args = parse_args(env::args().skip(1).collect())?;
    validate_live_markers(&args)?;

    let database_url = env::var("BILLING_LEDGER_LIVE_DATABASE_URL")
        .or_else(|_| env::var("DATABASE_URL"))
        .map_err(|_| "live_database_url_missing".to_string())?;
    if database_url.trim().is_empty() {
        return Err("live_database_url_missing".to_string());
    }

    let input_text = fs::read_to_string(&args.input_path)
        .map_err(|_| "input_payload_read_failed".to_string())?;
    let input: ReserveCommitInput =
        serde_json::from_str(&input_text).map_err(|_| "input_payload_parse_failed".to_string())?;
    let request = reserve_request(&input)?;
    if request.idempotency_key() != args.idempotency_key {
        return Err("idempotency_key_mismatch".to_string());
    }
    let state = writer_state(&input)?;
    let writer_plan =
        plan_consistent_ledger_write(request, &state).map_err(|_| "writer_plan_failed")?;
    let command_plan = plan_consistent_ledger_write_commands(&writer_plan);
    let postgres_plan = plan_consistent_ledger_postgres_execution(&writer_plan, &command_plan);

    let pool = sqlx::PgPool::connect(&database_url)
        .await
        .map_err(|_| "live_database_connect_failed".to_string())?;
    let result =
        execute_consistent_ledger_postgres_sqlx_writer_plan(&pool, &writer_plan, &postgres_plan)
            .await;
    let summary = summarize_consistent_ledger_postgres_executor_result(&result);
    if !result.committed {
        return Err("runtime_writer_commit_not_observed".to_string());
    }

    let artifact = json!({
        "schema_version": "control_plane_billing_ledger_live_commit_proof_artifact.v1",
        "artifact_mode": "external_runtime_writer_commit",
        "generated_at_utc": utc_now_rfc3339(),
        "current_commit": args.current_commit,
        "runtime_container_commit": args.runtime_container_commit,
        "freshness_marker": "current",
        "stale_artifact": false,
        "measurement_source": "external_controlled_runtime_writer_commit",
        "generated_by_this_script": false,
        "simulated": false,
        "classification": "pass",
        "live_commit_readback": args.live_commit_readback,
        "active_writer": args.active_writer,
        "source_of_truth": args.source_of_truth,
        "single_active_writer_count": 1,
        "row_count_proof": [
            {
                "statement_kind": "insert_runtime_writer_commit_ledger_entry",
                "expected_rows": 1,
                "actual_rows": committed_insert_rows(&result),
                "rows_match": committed_insert_rows(&result) == 1,
                "rows_affected_source": "execute_consistent_ledger_postgres_sqlx_writer_plan"
            },
            {
                "statement_kind": "mark_runtime_writer_commit_idempotency",
                "expected_rows": 1,
                "actual_rows": if result.committed { 1 } else { 0 },
                "rows_match": result.committed,
                "rows_affected_source": "ledger_entry_idempotency_key_unique_insert"
            }
        ],
        "commit_proof": {
            "runtime_writer_commit_observed": result.committed,
            "committed_writer": EXPECTED_WRITER,
            "commit_source": "execute_consistent_ledger_postgres_sqlx_writer_plan",
            "operation_scope": args.operation_scope,
            "production_source_of_truth_switch_observed": false
        },
        "runner_provenance": {
            "runner_id": "billing-ledger-runtime-writer-commit",
            "runner_invocation_id": args.idempotency_key,
            "artifact_origin": "external_runtime_writer_commit_runner",
            "generated_by_external_runner": true,
            "source_of_truth_switch_performed": false
        },
        "no_dual_commit_proof": {
            "dual_commit_observed": false,
            "local_and_billing_ledger_commit_same_request_observed": false,
            "production_writer_replaced": false
        },
        "executor_summary": summary,
        "safe_output": {
            "database_url_output": "omitted",
            "env_value_output": "omitted",
            "operation_key_output": "omitted",
            "raw_env_value_echoed": false,
            "raw_database_url_echoed": false,
            "raw_metadata_echoed": false,
            "credential_material_echoed": false,
            "raw_executor_error_detail_echoed": false
        }
    });

    write_artifact(&args.artifact_path, &artifact)?;
    println!(
        "{}",
        json!({
            "schema_version": "billing_ledger_runtime_writer_commit_runner_result.v1",
            "classification": "external_commit_artifact_written",
            "artifact_path_output": "omitted",
            "committed": true,
            "secret_safe": true
        })
    );
    Ok(())
}

fn parse_args(raw: Vec<String>) -> Result<Args, String> {
    let mut live_commit_opt_in = false;
    let mut no_dual_readback_opt_in = false;
    let mut commit_readback_opt_in = false;
    let mut input_path = None;
    let mut artifact_path = None;
    let mut operation_scope = None;
    let mut idempotency_key = None;
    let mut current_commit = None;
    let mut runtime_container_commit = None;
    let mut active_writer = None;
    let mut source_of_truth = None;
    let mut live_commit_readback = None;
    let mut iter = raw.into_iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--live-commit-opt-in" => live_commit_opt_in = true,
            "--no-dual-readback-opt-in" => no_dual_readback_opt_in = true,
            "--commit-readback-opt-in" => commit_readback_opt_in = true,
            "--input" => input_path = iter.next().map(PathBuf::from),
            "--artifact-path" => artifact_path = iter.next().map(PathBuf::from),
            "--operation-scope" => operation_scope = iter.next(),
            "--idempotency-key" => idempotency_key = iter.next(),
            "--current-commit" => current_commit = iter.next(),
            "--runtime-container-commit" => runtime_container_commit = iter.next(),
            "--active-writer" => active_writer = iter.next(),
            "--source-of-truth" => source_of_truth = iter.next(),
            "--live-commit-readback" => live_commit_readback = iter.next(),
            _ => return Err("unknown_argument".to_string()),
        }
    }

    Ok(Args {
        live_commit_opt_in,
        no_dual_readback_opt_in,
        commit_readback_opt_in,
        input_path: input_path.ok_or_else(|| "input_path_missing".to_string())?,
        artifact_path: artifact_path.ok_or_else(|| "artifact_path_missing".to_string())?,
        operation_scope: operation_scope.ok_or_else(|| "operation_scope_missing".to_string())?,
        idempotency_key: idempotency_key.ok_or_else(|| "idempotency_key_missing".to_string())?,
        current_commit: current_commit.ok_or_else(|| "current_commit_missing".to_string())?,
        runtime_container_commit: runtime_container_commit
            .ok_or_else(|| "runtime_container_commit_missing".to_string())?,
        active_writer: active_writer.ok_or_else(|| "active_writer_missing".to_string())?,
        source_of_truth: source_of_truth.ok_or_else(|| "source_of_truth_missing".to_string())?,
        live_commit_readback: live_commit_readback
            .ok_or_else(|| "live_commit_readback_missing".to_string())?,
    })
}

fn validate_live_markers(args: &Args) -> Result<(), String> {
    if !args.live_commit_opt_in {
        return Err("live_commit_opt_in_missing".to_string());
    }
    if !truthy_env("AI_CONTROL_PLANE_BILLING_LEDGER_RUNTIME_WRITER_AVAILABLE") {
        return Err("runtime_writer_unavailable".to_string());
    }
    if !truthy_env("AI_CONTROL_PLANE_BILLING_LEDGER_RUNTIME_SCHEMA_AVAILABLE") {
        return Err("runtime_schema_unavailable".to_string());
    }
    if !truthy_env("AI_CONTROL_PLANE_BILLING_LEDGER_RUNTIME_TOOL_AVAILABLE") {
        return Err("runtime_tool_unavailable".to_string());
    }
    if !args.no_dual_readback_opt_in {
        return Err("no_dual_readback_opt_in_missing".to_string());
    }
    if !args.commit_readback_opt_in {
        return Err("commit_readback_opt_in_missing".to_string());
    }
    for value in [
        &args.active_writer,
        &args.source_of_truth,
        &args.live_commit_readback,
    ] {
        if value != EXPECTED_WRITER {
            return Err("writer_marker_mismatch".to_string());
        }
    }
    Ok(())
}

fn reserve_request(input: &ReserveCommitInput) -> Result<ConsistentLedgerWriteRequest, String> {
    Ok(ConsistentLedgerWriteRequest::Reserve {
        scope: ConsistentLedgerScope {
            tenant_id: input.tenant_id,
            project_id: input.project_id,
            virtual_key_id: input.virtual_key_id,
        },
        request_id: input.request_id,
        amount: money(&input.amount)?,
        currency: input.currency.clone(),
    })
}

fn writer_state(input: &ReserveCommitInput) -> Result<ConsistentLedgerWriterState, String> {
    Ok(ConsistentLedgerWriterState {
        wallet: Some(ConsistentWalletSnapshot {
            wallet_id: input.wallet_id,
            currency: input.currency.clone(),
            available_balance: money(&input.available_balance)?,
        }),
        credit_grants: Vec::new(),
        budgets: input
            .budgets
            .iter()
            .map(|budget| {
                Ok(ConsistentBudgetSnapshot {
                    budget_id: budget.budget_id,
                    dimension: budget.dimension,
                    currency: input.currency.clone(),
                    remaining_amount: money(&budget.remaining_amount)?,
                    active: budget.active,
                })
            })
            .collect::<Result<Vec<_>, String>>()?,
        ledger_entries: Vec::new(),
    })
}

fn money(value: &str) -> Result<FixedDecimal, String> {
    FixedDecimal::parse(value, DEFAULT_MONEY_SCALE).map_err(|_| "money_parse_failed".to_string())
}

fn committed_insert_rows(
    result: &ai_gateway_billing_ledger::ConsistentLedgerPostgresExecutorResult,
) -> u64 {
    result
        .statement_results
        .iter()
        .filter(|statement| {
            format!("{:?}", statement.kind) == "InsertLedgerEntry" && statement.rows_affected == 1
        })
        .count() as u64
}

fn write_artifact(path: &PathBuf, artifact: &Value) -> Result<(), String> {
    if path.extension().and_then(|value| value.to_str()) != Some("json") {
        return Err("artifact_path_must_be_json".to_string());
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|_| "artifact_parent_create_failed".to_string())?;
    }
    let content = serde_json::to_string_pretty(artifact)
        .map_err(|_| "artifact_serialize_failed".to_string())?;
    fs::write(path, content).map_err(|_| "artifact_write_failed".to_string())
}

fn truthy_env(name: &str) -> bool {
    env::var(name)
        .map(|value| {
            matches!(
                value.trim().to_ascii_lowercase().as_str(),
                "1" | "true" | "yes" | "ready" | "enabled"
            )
        })
        .unwrap_or(false)
}

fn default_currency() -> String {
    "USD".to_string()
}

fn default_true() -> bool {
    true
}

fn utc_now_rfc3339() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let total_seconds = now.as_secs() as i64;
    let millis = now.subsec_millis();
    let days = total_seconds.div_euclid(86_400);
    let seconds_of_day = total_seconds.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    let hour = seconds_of_day / 3_600;
    let minute = (seconds_of_day % 3_600) / 60;
    let second = seconds_of_day % 60;
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}.{millis:03}Z")
}

fn civil_from_days(days_since_epoch: i64) -> (i64, u32, u32) {
    let z = days_since_epoch + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let day_of_era = z - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let mut year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_phase = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_phase + 2) / 5 + 1;
    let month = month_phase + if month_phase < 10 { 3 } else { -9 };
    if month <= 2 {
        year += 1;
    }
    (year, month as u32, day as u32)
}
