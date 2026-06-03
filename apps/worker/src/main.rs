mod alert_webhook;
mod billing_reconciliation;
mod clickhouse_log_store;
mod prompt_eval_shadow;

use ai_gateway_config::AppConfig;
use ai_gateway_db::{DbRepository, RecoveryProbeCandidate, connect};
use ai_gateway_observability::{init_tracing, redact_secrets};
use alert_webhook::{
    AlertWebhookInputSource, AlertWebhookMode, alert_webhook_plan, read_alert_webhook_input,
};
use billing_reconciliation::{
    BillingReconciliationInputSource, BillingReconciliationMode,
    billing_reconciliation_execute_error, billing_reconciliation_plan,
    read_billing_reconciliation_input,
};
use clickhouse_log_store::{
    ClickHouseLogStoreInputSource, ClickHouseLogStoreMode, clickhouse_log_store_execute_error,
    clickhouse_log_store_plan, read_clickhouse_log_store_input,
};
use prompt_eval_shadow::{
    PromptEvalShadowInputSource, PromptEvalShadowMode, prompt_eval_shadow_execute_error,
    prompt_eval_shadow_plan, read_prompt_eval_shadow_input,
};
use serde::Serialize;
use std::{future::Future, pin::Pin};
use uuid::Uuid;

const DEFAULT_TENANT_ID: Uuid = Uuid::from_u128(0x00000000_0000_0000_0000_000000000001);
const DEFAULT_RECOVERY_PROBE_LIMIT: i64 = 100;
type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    init_tracing("worker");

    match parse_command(std::env::args()) {
        Ok(WorkerCommand::RunWorker) => run_worker().await,
        Ok(WorkerCommand::RecoveryProbe {
            mode: RecoveryProbeMode::DryRun,
            tenant_id,
            limit,
        }) => run_recovery_probe_dry_run(tenant_id, limit).await,
        Ok(WorkerCommand::RecoveryProbe {
            mode: RecoveryProbeMode::Execute,
            tenant_id,
            limit,
        }) => run_recovery_probe_execute(tenant_id, limit).await,
        Ok(WorkerCommand::AlertWebhook {
            mode: AlertWebhookMode::DryRun,
            tenant_id,
            input_path,
            ..
        }) => run_alert_webhook_dry_run(tenant_id, input_path).await,
        Ok(WorkerCommand::AlertWebhook {
            mode: AlertWebhookMode::Execute,
            force,
            ..
        }) => Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            alert_webhook_execute_error(force),
        )
        .into()),
        Ok(WorkerCommand::BillingReconciliation {
            mode: BillingReconciliationMode::DryRun,
            tenant_id,
            project_ids,
            day,
            input_path,
            discrepancy_limit,
            ..
        }) => {
            run_billing_reconciliation_dry_run(
                tenant_id,
                project_ids,
                day,
                input_path,
                discrepancy_limit,
            )
            .await
        }
        Ok(WorkerCommand::BillingReconciliation {
            mode: BillingReconciliationMode::Execute,
            force,
            ..
        }) => Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            billing_reconciliation_execute_error(force),
        )
        .into()),
        Ok(WorkerCommand::PromptEvalShadow {
            mode: PromptEvalShadowMode::DryRun,
            tenant_id,
            input_path,
            ..
        }) => run_prompt_eval_shadow_dry_run(tenant_id, input_path).await,
        Ok(WorkerCommand::PromptEvalShadow {
            mode: PromptEvalShadowMode::Execute,
            force,
            ..
        }) => Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            prompt_eval_shadow_execute_error(force),
        )
        .into()),
        Ok(WorkerCommand::ClickHouseLogStore {
            mode: ClickHouseLogStoreMode::DryRun,
            tenant_id,
            input_path,
            ..
        }) => run_clickhouse_log_store_dry_run(tenant_id, input_path).await,
        Ok(WorkerCommand::ClickHouseLogStore {
            mode: ClickHouseLogStoreMode::Execute,
            force,
            ..
        }) => Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            clickhouse_log_store_execute_error(force),
        )
        .into()),
        Err(message) => Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!("{message}\n\n{}", usage()),
        )
        .into()),
    }
}

async fn run_worker() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let config = AppConfig::load_from_env()?;
    config.validate()?;

    tracing::info!(
        database_driver = %config.database.driver,
        redis = %config.redis.addr,
        "worker started"
    );

    tokio::signal::ctrl_c().await?;
    tracing::info!("worker shutdown requested");
    Ok(())
}

async fn run_recovery_probe_dry_run(
    tenant_id: Uuid,
    limit: i64,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let config = AppConfig::load_from_env()?;
    config.validate()?;

    let pool = connect(&config).await?;
    let repository = DbRepository::new(pool);
    let candidates = repository
        .list_recovery_probe_candidates(tenant_id, limit)
        .await?;
    let plan = recovery_probe_plan(tenant_id, candidates);

    serde_json::to_writer_pretty(std::io::stdout(), &plan)?;
    println!();
    Ok(())
}

async fn run_recovery_probe_execute(
    tenant_id: Uuid,
    limit: i64,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let config = AppConfig::load_from_env()?;
    config.validate()?;

    let pool = connect(&config).await?;
    let repository = DbRepository::new(pool);
    let candidates = repository
        .list_recovery_probe_candidates(tenant_id, limit)
        .await?;
    let probe = ContextUnavailableRecoveryProbe;
    let report = execute_recovery_probes(tenant_id, candidates, &probe, &repository).await;
    let migration_error_count = report.migration_error_count;

    serde_json::to_writer_pretty(std::io::stdout(), &report)?;
    println!();

    if migration_error_count > 0 {
        return Err(std::io::Error::other(
            "one or more recovery-probe status migrations failed; see redacted JSON report",
        )
        .into());
    }

    Ok(())
}

async fn run_alert_webhook_dry_run(
    tenant_id: Uuid,
    input_path: Option<String>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let (source, input) = read_alert_webhook_input(input_path.as_deref()).map_err(|error| {
        std::io::Error::new(std::io::ErrorKind::InvalidInput, safe_error_text(&error))
    })?;
    let source = match source {
        AlertWebhookInputSource::Env => AlertWebhookInputSource::Env,
        AlertWebhookInputSource::InputJson { path } => AlertWebhookInputSource::InputJson {
            path: safe_plan_text(&path),
        },
    };
    let plan = alert_webhook_plan(tenant_id, source, input).map_err(|error| {
        std::io::Error::new(std::io::ErrorKind::InvalidInput, safe_error_text(&error))
    })?;

    serde_json::to_writer_pretty(std::io::stdout(), &plan)?;
    println!();
    Ok(())
}

async fn run_billing_reconciliation_dry_run(
    tenant_id: Option<Uuid>,
    project_ids: Vec<Uuid>,
    day: Option<String>,
    input_path: Option<String>,
    discrepancy_limit: Option<usize>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let (source, input) =
        read_billing_reconciliation_input(input_path.as_deref()).map_err(|error| {
            std::io::Error::new(std::io::ErrorKind::InvalidInput, safe_error_text(&error))
        })?;
    let source = match source {
        BillingReconciliationInputSource::InputJson { path } => {
            BillingReconciliationInputSource::InputJson {
                path: safe_plan_text(&path),
            }
        }
    };
    let plan = billing_reconciliation_plan(
        tenant_id,
        project_ids,
        day,
        discrepancy_limit,
        source,
        input,
    )
    .map_err(|error| {
        std::io::Error::new(std::io::ErrorKind::InvalidInput, safe_error_text(&error))
    })?;

    serde_json::to_writer_pretty(std::io::stdout(), &plan)?;
    println!();
    Ok(())
}

async fn run_prompt_eval_shadow_dry_run(
    tenant_id: Option<Uuid>,
    input_path: Option<String>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let (source, input) =
        read_prompt_eval_shadow_input(input_path.as_deref()).map_err(|error| {
            std::io::Error::new(std::io::ErrorKind::InvalidInput, safe_error_text(&error))
        })?;
    let source = match source {
        PromptEvalShadowInputSource::InputJson { path } => PromptEvalShadowInputSource::InputJson {
            path: safe_plan_text(&path),
        },
    };
    let plan = prompt_eval_shadow_plan(tenant_id, source, input).map_err(|error| {
        std::io::Error::new(std::io::ErrorKind::InvalidInput, safe_error_text(&error))
    })?;

    serde_json::to_writer_pretty(std::io::stdout(), &plan)?;
    println!();
    Ok(())
}

async fn run_clickhouse_log_store_dry_run(
    tenant_id: Option<Uuid>,
    input_path: Option<String>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let (source, input) =
        read_clickhouse_log_store_input(input_path.as_deref()).map_err(|error| {
            std::io::Error::new(std::io::ErrorKind::InvalidInput, safe_error_text(&error))
        })?;
    let source = match source {
        ClickHouseLogStoreInputSource::InputJson { path } => {
            ClickHouseLogStoreInputSource::InputJson {
                path: safe_plan_text(&path),
            }
        }
    };
    let plan = clickhouse_log_store_plan(tenant_id, source, input).map_err(|error| {
        std::io::Error::new(std::io::ErrorKind::InvalidInput, safe_error_text(&error))
    })?;

    serde_json::to_writer_pretty(std::io::stdout(), &plan)?;
    println!();
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum WorkerCommand {
    RunWorker,
    RecoveryProbe {
        mode: RecoveryProbeMode,
        tenant_id: Uuid,
        limit: i64,
    },
    AlertWebhook {
        mode: AlertWebhookMode,
        tenant_id: Uuid,
        input_path: Option<String>,
        force: bool,
    },
    BillingReconciliation {
        mode: BillingReconciliationMode,
        tenant_id: Option<Uuid>,
        project_ids: Vec<Uuid>,
        day: Option<String>,
        input_path: Option<String>,
        discrepancy_limit: Option<usize>,
        force: bool,
    },
    PromptEvalShadow {
        mode: PromptEvalShadowMode,
        tenant_id: Option<Uuid>,
        input_path: Option<String>,
        force: bool,
    },
    ClickHouseLogStore {
        mode: ClickHouseLogStoreMode,
        tenant_id: Option<Uuid>,
        input_path: Option<String>,
        force: bool,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RecoveryProbeMode {
    DryRun,
    Execute,
}

fn parse_command(args: impl IntoIterator<Item = String>) -> Result<WorkerCommand, String> {
    let mut args = args.into_iter();
    let _program = args.next();

    let Some(command) = args.next() else {
        return Ok(WorkerCommand::RunWorker);
    };

    match command.as_str() {
        "recovery-probe" | "recovery-probe-plan" => {
            let mut tenant_id = DEFAULT_TENANT_ID;
            let mut limit = DEFAULT_RECOVERY_PROBE_LIMIT;
            let mut explicit_mode = None;

            while let Some(arg) = args.next() {
                match arg.as_str() {
                    "--dry-run" => {
                        set_recovery_probe_mode(
                            &mut explicit_mode,
                            RecoveryProbeMode::DryRun,
                            "--dry-run",
                        )?;
                    }
                    "--execute" | "--live" => {
                        set_recovery_probe_mode(
                            &mut explicit_mode,
                            RecoveryProbeMode::Execute,
                            arg.as_str(),
                        )?;
                    }
                    "--tenant-id" => {
                        let raw = args
                            .next()
                            .ok_or_else(|| "--tenant-id requires a UUID value".to_string())?;
                        tenant_id = raw
                            .parse()
                            .map_err(|_| format!("invalid --tenant-id UUID `{raw}`"))?;
                    }
                    "--limit" => {
                        let raw = args
                            .next()
                            .ok_or_else(|| "--limit requires an integer value".to_string())?;
                        limit = raw
                            .parse::<i64>()
                            .map_err(|_| format!("invalid --limit integer `{raw}`"))?;
                        if limit < 0 {
                            return Err("--limit must be zero or greater".to_string());
                        }
                    }
                    "--help" | "-h" => return Err(usage()),
                    other => return Err(format!("unknown recovery-probe argument `{other}`")),
                }
            }

            Ok(WorkerCommand::RecoveryProbe {
                mode: explicit_mode.unwrap_or(RecoveryProbeMode::DryRun),
                tenant_id,
                limit,
            })
        }
        "alert-webhook" | "alert-webhook-plan" => {
            let mut tenant_id = DEFAULT_TENANT_ID;
            let mut input_path = None;
            let mut force = false;
            let mut explicit_mode = None;

            while let Some(arg) = args.next() {
                match arg.as_str() {
                    "--dry-run" => {
                        set_alert_webhook_mode(
                            &mut explicit_mode,
                            AlertWebhookMode::DryRun,
                            "--dry-run",
                        )?;
                    }
                    "--send" | "--execute" => {
                        set_alert_webhook_mode(
                            &mut explicit_mode,
                            AlertWebhookMode::Execute,
                            arg.as_str(),
                        )?;
                    }
                    "--force" => {
                        force = true;
                    }
                    "--input" => {
                        let raw = args
                            .next()
                            .ok_or_else(|| "--input requires a JSON file path".to_string())?;
                        input_path = Some(raw);
                    }
                    "--tenant-id" => {
                        let raw = args
                            .next()
                            .ok_or_else(|| "--tenant-id requires a UUID value".to_string())?;
                        tenant_id = raw
                            .parse()
                            .map_err(|_| format!("invalid --tenant-id UUID `{raw}`"))?;
                    }
                    "--help" | "-h" => return Err(usage()),
                    other => return Err(format!("unknown alert-webhook argument `{other}`")),
                }
            }

            Ok(WorkerCommand::AlertWebhook {
                mode: explicit_mode.unwrap_or(AlertWebhookMode::DryRun),
                tenant_id,
                input_path,
                force,
            })
        }
        "billing-reconciliation" | "billing-reconciliation-plan" => {
            let mut tenant_id = None;
            let mut project_ids = Vec::new();
            let mut day = None;
            let mut input_path = None;
            let mut discrepancy_limit = None;
            let mut force = false;
            let mut explicit_mode = None;

            while let Some(arg) = args.next() {
                match arg.as_str() {
                    "--dry-run" => {
                        set_billing_reconciliation_mode(
                            &mut explicit_mode,
                            BillingReconciliationMode::DryRun,
                            "--dry-run",
                        )?;
                    }
                    "--execute" | "--send" => {
                        set_billing_reconciliation_mode(
                            &mut explicit_mode,
                            BillingReconciliationMode::Execute,
                            arg.as_str(),
                        )?;
                    }
                    "--force" => {
                        force = true;
                    }
                    "--input" => {
                        let raw = args
                            .next()
                            .ok_or_else(|| "--input requires a JSON file path".to_string())?;
                        input_path = Some(raw);
                    }
                    "--tenant-id" => {
                        let raw = args
                            .next()
                            .ok_or_else(|| "--tenant-id requires a UUID value".to_string())?;
                        tenant_id = Some(
                            raw.parse()
                                .map_err(|_| format!("invalid --tenant-id UUID `{raw}`"))?,
                        );
                    }
                    "--project-id" => {
                        let raw = args
                            .next()
                            .ok_or_else(|| "--project-id requires a UUID value".to_string())?;
                        project_ids.push(
                            raw.parse()
                                .map_err(|_| format!("invalid --project-id UUID `{raw}`"))?,
                        );
                    }
                    "--day" => {
                        let raw = args
                            .next()
                            .ok_or_else(|| "--day requires a YYYY-MM-DD value".to_string())?;
                        day = Some(raw);
                    }
                    "--limit" => {
                        let raw = args
                            .next()
                            .ok_or_else(|| "--limit requires an integer value".to_string())?;
                        let limit = raw
                            .parse::<usize>()
                            .map_err(|_| format!("invalid --limit integer `{raw}`"))?;
                        if limit == 0 {
                            return Err("--limit must be at least 1".to_string());
                        }
                        discrepancy_limit = Some(limit);
                    }
                    "--help" | "-h" => return Err(usage()),
                    other => {
                        return Err(format!("unknown billing-reconciliation argument `{other}`"));
                    }
                }
            }

            Ok(WorkerCommand::BillingReconciliation {
                mode: explicit_mode.unwrap_or(BillingReconciliationMode::DryRun),
                tenant_id,
                project_ids,
                day,
                input_path,
                discrepancy_limit,
                force,
            })
        }
        "prompt-eval-shadow"
        | "prompt-eval-shadow-plan"
        | "prompt-registry-shadow"
        | "prompt-registry-shadow-plan" => {
            let mut tenant_id = None;
            let mut input_path = None;
            let mut force = false;
            let mut explicit_mode = None;

            while let Some(arg) = args.next() {
                match arg.as_str() {
                    "--dry-run" => {
                        set_prompt_eval_shadow_mode(
                            &mut explicit_mode,
                            PromptEvalShadowMode::DryRun,
                            "--dry-run",
                        )?;
                    }
                    "--execute" | "--send" => {
                        set_prompt_eval_shadow_mode(
                            &mut explicit_mode,
                            PromptEvalShadowMode::Execute,
                            arg.as_str(),
                        )?;
                    }
                    "--force" => {
                        force = true;
                    }
                    "--input" => {
                        let raw = args
                            .next()
                            .ok_or_else(|| "--input requires a JSON file path".to_string())?;
                        input_path = Some(raw);
                    }
                    "--tenant-id" => {
                        let raw = args
                            .next()
                            .ok_or_else(|| "--tenant-id requires a UUID value".to_string())?;
                        tenant_id = Some(
                            raw.parse()
                                .map_err(|_| format!("invalid --tenant-id UUID `{raw}`"))?,
                        );
                    }
                    "--help" | "-h" => return Err(usage()),
                    other => return Err(format!("unknown prompt-eval-shadow argument `{other}`")),
                }
            }

            Ok(WorkerCommand::PromptEvalShadow {
                mode: explicit_mode.unwrap_or(PromptEvalShadowMode::DryRun),
                tenant_id,
                input_path,
                force,
            })
        }
        "clickhouse-log-store" | "clickhouse-log-store-plan" => {
            let mut tenant_id = None;
            let mut input_path = None;
            let mut force = false;
            let mut explicit_mode = None;

            while let Some(arg) = args.next() {
                match arg.as_str() {
                    "--dry-run" => {
                        set_clickhouse_log_store_mode(
                            &mut explicit_mode,
                            ClickHouseLogStoreMode::DryRun,
                            "--dry-run",
                        )?;
                    }
                    "--execute" | "--send" => {
                        set_clickhouse_log_store_mode(
                            &mut explicit_mode,
                            ClickHouseLogStoreMode::Execute,
                            arg.as_str(),
                        )?;
                    }
                    "--force" => {
                        force = true;
                    }
                    "--input" => {
                        let raw = args
                            .next()
                            .ok_or_else(|| "--input requires a JSON file path".to_string())?;
                        input_path = Some(raw);
                    }
                    "--tenant-id" => {
                        let raw = args
                            .next()
                            .ok_or_else(|| "--tenant-id requires a UUID value".to_string())?;
                        tenant_id = Some(
                            raw.parse()
                                .map_err(|_| format!("invalid --tenant-id UUID `{raw}`"))?,
                        );
                    }
                    "--help" | "-h" => return Err(usage()),
                    other => {
                        return Err(format!("unknown clickhouse-log-store argument `{other}`"));
                    }
                }
            }

            Ok(WorkerCommand::ClickHouseLogStore {
                mode: explicit_mode.unwrap_or(ClickHouseLogStoreMode::DryRun),
                tenant_id,
                input_path,
                force,
            })
        }
        "--help" | "-h" => Err(usage()),
        other => Err(format!("unknown worker command `{other}`")),
    }
}

fn set_recovery_probe_mode(
    explicit_mode: &mut Option<RecoveryProbeMode>,
    mode: RecoveryProbeMode,
    flag: &str,
) -> Result<(), String> {
    if let Some(existing_mode) = explicit_mode
        && *existing_mode != mode
    {
        return Err(format!(
            "choose either --dry-run or --execute/--live for recovery-probe, not both; `{flag}` conflicts with the existing mode"
        ));
    }

    *explicit_mode = Some(mode);
    Ok(())
}

fn set_alert_webhook_mode(
    explicit_mode: &mut Option<AlertWebhookMode>,
    mode: AlertWebhookMode,
    flag: &str,
) -> Result<(), String> {
    if let Some(existing_mode) = explicit_mode
        && *existing_mode != mode
    {
        return Err(format!(
            "choose either --dry-run or --send/--execute for alert-webhook, not both; `{flag}` conflicts with the existing mode"
        ));
    }

    *explicit_mode = Some(mode);
    Ok(())
}

fn set_billing_reconciliation_mode(
    explicit_mode: &mut Option<BillingReconciliationMode>,
    mode: BillingReconciliationMode,
    flag: &str,
) -> Result<(), String> {
    if let Some(existing_mode) = explicit_mode
        && *existing_mode != mode
    {
        return Err(format!(
            "choose either --dry-run or --execute/--send for billing-reconciliation, not both; `{flag}` conflicts with the existing mode"
        ));
    }

    *explicit_mode = Some(mode);
    Ok(())
}

fn set_prompt_eval_shadow_mode(
    explicit_mode: &mut Option<PromptEvalShadowMode>,
    mode: PromptEvalShadowMode,
    flag: &str,
) -> Result<(), String> {
    if let Some(existing_mode) = explicit_mode
        && *existing_mode != mode
    {
        return Err(format!(
            "choose either --dry-run or --execute/--send for prompt-eval-shadow, not both; `{flag}` conflicts with the existing mode"
        ));
    }

    *explicit_mode = Some(mode);
    Ok(())
}

fn set_clickhouse_log_store_mode(
    explicit_mode: &mut Option<ClickHouseLogStoreMode>,
    mode: ClickHouseLogStoreMode,
    flag: &str,
) -> Result<(), String> {
    if let Some(existing_mode) = explicit_mode
        && *existing_mode != mode
    {
        return Err(format!(
            "choose either --dry-run or --execute/--send for clickhouse-log-store, not both; `{flag}` conflicts with the existing mode"
        ));
    }

    *explicit_mode = Some(mode);
    Ok(())
}

fn usage() -> String {
    "Usage:\n  ai-worker\n  ai-worker recovery-probe [--dry-run|--execute] [--tenant-id <uuid>] [--limit <n>]\n  ai-worker alert-webhook [--dry-run] [--input <json>] [--tenant-id <uuid>]  # emits sender contract, no network send\n  ai-worker alert-webhook --send|--execute [--force]  # refused in this dry-run slice\n  ai-worker billing-reconciliation [--dry-run] --input <json> [--day <YYYY-MM-DD>] [--tenant-id <uuid>] [--project-id <uuid>] [--limit <n>]\n  ai-worker billing-reconciliation --execute|--send [--force]  # refused in this dry-run slice\n  ai-worker prompt-eval-shadow [--dry-run] --input <json> [--tenant-id <uuid>]  # emits prompt registry/eval dataset/shadow traffic plan, no writes or sends\n  ai-worker prompt-eval-shadow --execute|--send [--force]  # refused in this dry-run slice\n  ai-worker clickhouse-log-store [--dry-run] --input <json> [--tenant-id <uuid>]  # emits queue/backpressure/dedup/table mapping plan, no DB or network\n  ai-worker clickhouse-log-store --execute|--send [--force]  # refused in this dry-run slice"
        .to_string()
}

fn alert_webhook_execute_error(force: bool) -> String {
    if force {
        return "alert-webhook send/execute is not implemented in this dry-run slice; no webhook request was sent; use --dry-run to inspect the future sender transaction contract".to_string();
    }

    "alert-webhook send/execute requires --force and is not implemented in this dry-run slice; no webhook request was sent; use --dry-run to inspect the future sender transaction contract".to_string()
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct RecoveryProbePlan {
    dry_run: bool,
    upstream_calls: bool,
    tenant_id: Uuid,
    candidate_count: usize,
    actions: Vec<RecoveryProbeAction>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct RecoveryProbeAction {
    action: &'static str,
    object_type: &'static str,
    tenant_id: Uuid,
    provider_id: Uuid,
    provider_code: String,
    channel_id: Uuid,
    channel_name: String,
    channel_endpoint: String,
    channel_protocol_mode: String,
    channel_status: String,
    provider_key_id: Uuid,
    key_alias: String,
    provider_key_status: String,
    provider_key_health_score: f64,
    cooldown_until: Option<String>,
    last_error_code: Option<String>,
    credential_configured: bool,
    secret_redacted: bool,
    planned_transition_on_success: &'static str,
    planned_transition_on_failure: &'static str,
}

fn recovery_probe_plan(
    tenant_id: Uuid,
    candidates: Vec<RecoveryProbeCandidate>,
) -> RecoveryProbePlan {
    let actions = candidates
        .into_iter()
        .filter(is_recovery_probe_candidate)
        .map(recovery_probe_action)
        .collect::<Vec<_>>();

    RecoveryProbePlan {
        dry_run: true,
        upstream_calls: false,
        tenant_id,
        candidate_count: actions.len(),
        actions,
    }
}

fn is_recovery_probe_candidate(candidate: &RecoveryProbeCandidate) -> bool {
    matches!(
        candidate.provider_key_status.as_str(),
        "cooldown" | "recovery_probe"
    ) && matches!(
        candidate.channel_status.as_str(),
        "enabled" | "degraded" | "cooldown" | "recovery_probe"
    )
}

fn recovery_probe_action(candidate: RecoveryProbeCandidate) -> RecoveryProbeAction {
    RecoveryProbeAction {
        action: "provider_key_recovery_probe",
        object_type: "provider_key",
        tenant_id: candidate.tenant_id,
        provider_id: candidate.provider_id,
        provider_code: safe_plan_text(&candidate.provider_code),
        channel_id: candidate.channel_id,
        channel_name: safe_plan_text(&candidate.channel_name),
        channel_endpoint: safe_endpoint_text(&candidate.channel_endpoint),
        channel_protocol_mode: safe_plan_text(&candidate.channel_protocol_mode),
        channel_status: safe_plan_text(&candidate.channel_status),
        provider_key_id: candidate.provider_key_id,
        key_alias: safe_plan_text(&candidate.key_alias),
        provider_key_status: safe_plan_text(&candidate.provider_key_status),
        provider_key_health_score: candidate.provider_key_health_score,
        cooldown_until: candidate.cooldown_until,
        last_error_code: candidate.last_error_code.as_deref().map(safe_plan_text),
        credential_configured: candidate.has_secret_fingerprint,
        secret_redacted: candidate.secret_redacted,
        planned_transition_on_success: "enabled",
        planned_transition_on_failure: failure_transition_status(&candidate.provider_key_status),
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct RecoveryProbeExecutionReport {
    dry_run: bool,
    upstream_calls: bool,
    tenant_id: Uuid,
    candidate_count: usize,
    success_count: usize,
    failure_count: usize,
    migration_applied_count: usize,
    migration_error_count: usize,
    results: Vec<RecoveryProbeExecutionResult>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct RecoveryProbeExecutionResult {
    action: RecoveryProbeAction,
    probe_result: &'static str,
    probe_error_code: Option<String>,
    upstream_call: bool,
    transition_from_status: String,
    transition_to_status: String,
    status_update_attempted: bool,
    status_update_applied: bool,
    status_update_error: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct RecoveryProbeCheck {
    status: RecoveryProbeCheckStatus,
    upstream_call: bool,
    error_code: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RecoveryProbeCheckStatus {
    Success,
    Failure,
}

impl RecoveryProbeCheck {
    #[cfg(test)]
    fn success(upstream_call: bool) -> Self {
        Self {
            status: RecoveryProbeCheckStatus::Success,
            upstream_call,
            error_code: None,
        }
    }

    fn failure(error_code: impl Into<String>, upstream_call: bool) -> Self {
        Self {
            status: RecoveryProbeCheckStatus::Failure,
            upstream_call,
            error_code: Some(error_code.into()),
        }
    }

    fn result_label(&self) -> &'static str {
        match self.status {
            RecoveryProbeCheckStatus::Success => "success",
            RecoveryProbeCheckStatus::Failure => "failure",
        }
    }

    fn is_success(&self) -> bool {
        self.status == RecoveryProbeCheckStatus::Success
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct RecoveryProbeTransition {
    from_status: String,
    to_status: String,
    update_required: bool,
}

trait RecoveryProbeRunner {
    fn probe<'a>(
        &'a self,
        candidate: &'a RecoveryProbeCandidate,
    ) -> BoxFuture<'a, RecoveryProbeCheck>;
}

trait ProviderKeyStatusWriter {
    fn set_provider_key_status<'a>(
        &'a self,
        tenant_id: Uuid,
        provider_key_id: Uuid,
        status: &'a str,
    ) -> BoxFuture<'a, Result<bool, String>>;
}

struct ContextUnavailableRecoveryProbe;

impl RecoveryProbeRunner for ContextUnavailableRecoveryProbe {
    fn probe<'a>(
        &'a self,
        _candidate: &'a RecoveryProbeCandidate,
    ) -> BoxFuture<'a, RecoveryProbeCheck> {
        Box::pin(async move { RecoveryProbeCheck::failure("probe_context_unavailable", false) })
    }
}

impl ProviderKeyStatusWriter for DbRepository {
    fn set_provider_key_status<'a>(
        &'a self,
        tenant_id: Uuid,
        provider_key_id: Uuid,
        status: &'a str,
    ) -> BoxFuture<'a, Result<bool, String>> {
        Box::pin(async move {
            DbRepository::update_provider_key_status(self, tenant_id, provider_key_id, status)
                .await
                .map(|updated| updated.is_some())
                .map_err(|error| safe_error_text(&error.to_string()))
        })
    }
}

async fn execute_recovery_probes(
    tenant_id: Uuid,
    candidates: Vec<RecoveryProbeCandidate>,
    probe: &impl RecoveryProbeRunner,
    status_writer: &impl ProviderKeyStatusWriter,
) -> RecoveryProbeExecutionReport {
    let candidates = candidates
        .into_iter()
        .filter(is_recovery_probe_candidate)
        .collect::<Vec<_>>();
    let mut results = Vec::with_capacity(candidates.len());
    let mut upstream_calls = false;
    let mut success_count = 0;
    let mut failure_count = 0;
    let mut migration_applied_count = 0;
    let mut migration_error_count = 0;

    for candidate in candidates {
        let action = recovery_probe_action(candidate.clone());
        let check = probe.probe(&candidate).await;
        let transition = recovery_probe_transition(&candidate, &check);
        upstream_calls |= check.upstream_call;

        if check.is_success() {
            success_count += 1;
        } else {
            failure_count += 1;
        }

        let mut status_update_attempted = false;
        let mut status_update_applied = false;
        let mut status_update_error = None;

        if transition.update_required {
            status_update_attempted = true;
            match status_writer
                .set_provider_key_status(
                    candidate.tenant_id,
                    candidate.provider_key_id,
                    &transition.to_status,
                )
                .await
            {
                Ok(applied) => {
                    status_update_applied = applied;
                    if applied {
                        migration_applied_count += 1;
                    }
                }
                Err(error) => {
                    migration_error_count += 1;
                    status_update_error = Some(safe_error_text(&error));
                }
            }
        }

        results.push(RecoveryProbeExecutionResult {
            action,
            probe_result: check.result_label(),
            probe_error_code: check.error_code.as_deref().map(safe_error_text),
            upstream_call: check.upstream_call,
            transition_from_status: safe_plan_text(&transition.from_status),
            transition_to_status: safe_plan_text(&transition.to_status),
            status_update_attempted,
            status_update_applied,
            status_update_error,
        });
    }

    RecoveryProbeExecutionReport {
        dry_run: false,
        upstream_calls,
        tenant_id,
        candidate_count: results.len(),
        success_count,
        failure_count,
        migration_applied_count,
        migration_error_count,
        results,
    }
}

fn recovery_probe_transition(
    candidate: &RecoveryProbeCandidate,
    check: &RecoveryProbeCheck,
) -> RecoveryProbeTransition {
    let to_status = if check.is_success() {
        "enabled"
    } else {
        failure_transition_status(&candidate.provider_key_status)
    };

    RecoveryProbeTransition {
        from_status: candidate.provider_key_status.clone(),
        to_status: to_status.to_string(),
        update_required: candidate.provider_key_status != to_status,
    }
}

fn failure_transition_status(provider_key_status: &str) -> &'static str {
    match provider_key_status {
        "recovery_probe" => "recovery_probe",
        _ => "cooldown",
    }
}

fn safe_plan_text(value: &str) -> String {
    redact_forbidden_tokens(&redact_secrets(&strip_url_userinfo(value)))
}

fn safe_error_text(value: &str) -> String {
    safe_plan_text(value)
}

fn safe_endpoint_text(value: &str) -> String {
    let endpoint_without_query = value.split(['?', '#']).next().unwrap_or(value);
    safe_plan_text(endpoint_without_query)
}

fn strip_url_userinfo(value: &str) -> String {
    let mut output = String::with_capacity(value.len());
    let mut start = 0;

    while let Some(relative_scheme_index) = value[start..].find("://") {
        let scheme_end = start + relative_scheme_index + 3;
        output.push_str(&value[start..scheme_end]);

        let rest = &value[scheme_end..];
        let authority_end = rest
            .find(['/', '?', '#', ' ', '\t', '\r', '\n'])
            .unwrap_or(rest.len());
        let authority = &rest[..authority_end];

        if let Some((_, host)) = authority.rsplit_once('@') {
            output.push_str(host);
        } else {
            output.push_str(authority);
        }

        start = scheme_end + authority_end;
    }

    output.push_str(&value[start..]);
    output
}

fn redact_forbidden_tokens(value: &str) -> String {
    value
        .split_whitespace()
        .map(|token| {
            let normalized = token.to_ascii_lowercase();
            if normalized.contains("authorization")
                || normalized.contains("fingerprint")
                || normalized.contains("api_key")
                || normalized.contains("apikey")
                || normalized.contains("token")
                || normalized.contains("secret")
                || normalized.contains("credential")
                || (normalized.contains("encrypted") && normalized.contains("credential"))
            {
                "[REDACTED]"
            } else {
                token
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    use std::{collections::HashMap, sync::Mutex};

    #[test]
    fn recovery_probe_command_defaults_to_dry_run() {
        let command = parse_command([
            "ai-worker".to_string(),
            "recovery-probe".to_string(),
            "--limit".to_string(),
            "3".to_string(),
        ])
        .expect("command should parse");

        assert_eq!(
            command,
            WorkerCommand::RecoveryProbe {
                mode: RecoveryProbeMode::DryRun,
                tenant_id: DEFAULT_TENANT_ID,
                limit: 3
            }
        );
    }

    #[test]
    fn recovery_probe_command_accepts_explicit_execute() {
        let command = parse_command([
            "ai-worker".to_string(),
            "recovery-probe".to_string(),
            "--execute".to_string(),
        ])
        .expect("execute probes should parse");

        assert_eq!(
            command,
            WorkerCommand::RecoveryProbe {
                mode: RecoveryProbeMode::Execute,
                tenant_id: DEFAULT_TENANT_ID,
                limit: DEFAULT_RECOVERY_PROBE_LIMIT,
            }
        );
    }

    #[test]
    fn recovery_probe_command_rejects_conflicting_modes() {
        let error = parse_command([
            "ai-worker".to_string(),
            "recovery-probe".to_string(),
            "--execute".to_string(),
            "--dry-run".to_string(),
        ])
        .expect_err("conflicting modes should fail");

        assert!(error.contains("either --dry-run or --execute"));
    }

    #[test]
    fn alert_webhook_command_defaults_to_dry_run_with_input() {
        let command = parse_command([
            "ai-worker".to_string(),
            "alert-webhook".to_string(),
            "--input".to_string(),
            "tests/fixtures/worker/alert_webhook_plan_contract.json".to_string(),
        ])
        .expect("alert webhook command should parse");

        assert_eq!(
            command,
            WorkerCommand::AlertWebhook {
                mode: AlertWebhookMode::DryRun,
                tenant_id: DEFAULT_TENANT_ID,
                input_path: Some(
                    "tests/fixtures/worker/alert_webhook_plan_contract.json".to_string()
                ),
                force: false,
            }
        );
    }

    #[test]
    fn alert_webhook_send_mode_is_parsed_for_refusal() {
        let command = parse_command([
            "ai-worker".to_string(),
            "alert-webhook".to_string(),
            "--send".to_string(),
            "--force".to_string(),
        ])
        .expect("send mode should parse before runtime refusal");

        assert_eq!(
            command,
            WorkerCommand::AlertWebhook {
                mode: AlertWebhookMode::Execute,
                tenant_id: DEFAULT_TENANT_ID,
                input_path: None,
                force: true,
            }
        );
        assert!(alert_webhook_execute_error(true).contains("not implemented"));
    }

    #[test]
    fn alert_webhook_command_rejects_conflicting_modes() {
        let error = parse_command([
            "ai-worker".to_string(),
            "alert-webhook".to_string(),
            "--send".to_string(),
            "--dry-run".to_string(),
        ])
        .expect_err("conflicting alert webhook modes should fail");

        assert!(error.contains("either --dry-run or --send/--execute"));
    }

    #[test]
    fn billing_reconciliation_command_defaults_to_dry_run_with_input() {
        let command = parse_command([
            "ai-worker".to_string(),
            "billing-reconciliation".to_string(),
            "--input".to_string(),
            "tests/fixtures/worker/billing_reconciliation_plan_contract.json".to_string(),
            "--day".to_string(),
            "2026-06-02".to_string(),
            "--project-id".to_string(),
            "00000000-0000-0000-0000-000000000020".to_string(),
            "--limit".to_string(),
            "3".to_string(),
        ])
        .expect("billing reconciliation command should parse");

        assert_eq!(
            command,
            WorkerCommand::BillingReconciliation {
                mode: BillingReconciliationMode::DryRun,
                tenant_id: None,
                project_ids: vec![Uuid::from_u128(0x00000000_0000_0000_0000_000000000020)],
                day: Some("2026-06-02".to_string()),
                input_path: Some(
                    "tests/fixtures/worker/billing_reconciliation_plan_contract.json".to_string()
                ),
                discrepancy_limit: Some(3),
                force: false,
            }
        );
    }

    #[test]
    fn billing_reconciliation_execute_mode_is_parsed_for_refusal() {
        let command = parse_command([
            "ai-worker".to_string(),
            "billing-reconciliation".to_string(),
            "--send".to_string(),
            "--force".to_string(),
        ])
        .expect("send mode should parse before runtime refusal");

        assert_eq!(
            command,
            WorkerCommand::BillingReconciliation {
                mode: BillingReconciliationMode::Execute,
                tenant_id: None,
                project_ids: Vec::new(),
                day: None,
                input_path: None,
                discrepancy_limit: None,
                force: true,
            }
        );
        assert!(billing_reconciliation_execute_error(true).contains("future DB reader/writer"));
    }

    #[test]
    fn billing_reconciliation_command_rejects_conflicting_modes() {
        let error = parse_command([
            "ai-worker".to_string(),
            "billing-reconciliation".to_string(),
            "--execute".to_string(),
            "--dry-run".to_string(),
        ])
        .expect_err("conflicting billing reconciliation modes should fail");

        assert!(error.contains("either --dry-run or --execute/--send"));
    }

    #[test]
    fn prompt_eval_shadow_command_defaults_to_dry_run_with_input() {
        let command = parse_command([
            "ai-worker".to_string(),
            "prompt-eval-shadow".to_string(),
            "--input".to_string(),
            "tests/fixtures/worker/prompt_eval_shadow_plan_contract.json".to_string(),
        ])
        .expect("prompt eval shadow command should parse");

        assert_eq!(
            command,
            WorkerCommand::PromptEvalShadow {
                mode: PromptEvalShadowMode::DryRun,
                tenant_id: None,
                input_path: Some(
                    "tests/fixtures/worker/prompt_eval_shadow_plan_contract.json".to_string()
                ),
                force: false,
            }
        );
    }

    #[test]
    fn prompt_eval_shadow_execute_mode_is_parsed_for_refusal() {
        let command = parse_command([
            "ai-worker".to_string(),
            "prompt-registry-shadow-plan".to_string(),
            "--send".to_string(),
            "--force".to_string(),
        ])
        .expect("send mode should parse before runtime refusal");

        assert_eq!(
            command,
            WorkerCommand::PromptEvalShadow {
                mode: PromptEvalShadowMode::Execute,
                tenant_id: None,
                input_path: None,
                force: true,
            }
        );
        assert!(prompt_eval_shadow_execute_error(true).contains("Gateway dispatch"));
    }

    #[test]
    fn prompt_eval_shadow_command_rejects_conflicting_modes() {
        let error = parse_command([
            "ai-worker".to_string(),
            "prompt-eval-shadow".to_string(),
            "--execute".to_string(),
            "--dry-run".to_string(),
        ])
        .expect_err("conflicting prompt eval shadow modes should fail");

        assert!(error.contains("either --dry-run or --execute/--send"));
    }

    #[test]
    fn clickhouse_log_store_command_defaults_to_dry_run_with_input() {
        let command = parse_command([
            "ai-worker".to_string(),
            "clickhouse-log-store".to_string(),
            "--input".to_string(),
            "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string(),
        ])
        .expect("ClickHouse log store command should parse");

        assert_eq!(
            command,
            WorkerCommand::ClickHouseLogStore {
                mode: ClickHouseLogStoreMode::DryRun,
                tenant_id: None,
                input_path: Some(
                    "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string()
                ),
                force: false,
            }
        );
    }

    #[test]
    fn clickhouse_log_store_execute_mode_is_parsed_for_refusal() {
        let command = parse_command([
            "ai-worker".to_string(),
            "clickhouse-log-store-plan".to_string(),
            "--execute".to_string(),
            "--force".to_string(),
        ])
        .expect("execute mode should parse before runtime refusal");

        assert_eq!(
            command,
            WorkerCommand::ClickHouseLogStore {
                mode: ClickHouseLogStoreMode::Execute,
                tenant_id: None,
                input_path: None,
                force: true,
            }
        );
        assert!(clickhouse_log_store_execute_error(true).contains("ClickHouse write"));
    }

    #[test]
    fn clickhouse_log_store_command_rejects_conflicting_modes() {
        let error = parse_command([
            "ai-worker".to_string(),
            "clickhouse-log-store".to_string(),
            "--execute".to_string(),
            "--dry-run".to_string(),
        ])
        .expect_err("conflicting ClickHouse log store modes should fail");

        assert!(error.contains("either --dry-run or --execute/--send"));
    }

    #[test]
    fn recovery_probe_plan_filters_candidate_statuses() {
        let plan = recovery_probe_plan(
            DEFAULT_TENANT_ID,
            vec![
                candidate(1, "recovery_probe", "enabled"),
                candidate(2, "cooldown", "degraded"),
                candidate(3, "enabled", "enabled"),
                candidate(4, "auth_failed", "enabled"),
                candidate(5, "cooldown", "manual_disabled"),
            ],
        );

        assert_eq!(plan.candidate_count, 2);
        assert_eq!(plan.actions[0].provider_key_status, "recovery_probe");
        assert_eq!(plan.actions[1].provider_key_status, "cooldown");
        assert_eq!(
            plan.actions[0].planned_transition_on_failure,
            "recovery_probe"
        );
        assert_eq!(plan.actions[1].planned_transition_on_failure, "cooldown");
        assert!(plan.dry_run);
        assert!(!plan.upstream_calls);
    }

    #[test]
    fn recovery_probe_plan_serialization_omits_secret_material() {
        let raw_provider_secret = raw_provider_secret_fixture();
        let mut candidate = candidate(1, "cooldown", "enabled");
        candidate.channel_endpoint =
            format!("https://user:pass@provider.example/v1?api_key={raw_provider_secret}");
        candidate.key_alias = format!("primary {raw_provider_secret}");
        candidate.last_error_code =
            Some(format!("{} {}", raw_bearer_scheme(), raw_provider_secret));
        let plan = recovery_probe_plan(DEFAULT_TENANT_ID, vec![candidate]);
        let serialized = serde_json::to_string(&plan).expect("plan should serialize");

        assert!(serialized.contains("\"credential_configured\":true"));
        assert!(serialized.contains("\"secret_redacted\":true"));
        assert!(serialized.contains("[REDACTED]"));
        assert!(!serialized.contains("encrypted_secret"));
        assert!(!serialized.contains("secret_fingerprint"));
        assert!(!serialized.contains("fingerprint-never-return"));
        assert!(!serialized.contains(&raw_provider_secret));
        assert!(!serialized.contains("user:pass"));
        assert!(!serialized.contains("api_key"));
        assert!(!serialized.contains("token"));
    }

    #[test]
    fn recovery_probe_contract_fixture_self_tests_dry_run_candidate_plan() {
        let fixture = recovery_probe_contract_fixture();
        let command = parse_command(command_args_from_fixture(&fixture, "dry_run"))
            .expect("dry-run command should parse");

        assert_eq!(
            command,
            WorkerCommand::RecoveryProbe {
                mode: RecoveryProbeMode::DryRun,
                tenant_id: DEFAULT_TENANT_ID,
                limit: 4,
            }
        );
        assert_eq!(
            fixture["safety_contract"]["credential_material_read"].as_bool(),
            Some(false)
        );
        assert_eq!(
            fixture["safety_contract"]["credential_material_output"].as_bool(),
            Some(false)
        );
        assert_eq!(
            fixture["safety_contract"]["raw_metadata_read"].as_bool(),
            Some(false)
        );
        assert_eq!(
            fixture["safety_contract"]["raw_metadata_output"].as_bool(),
            Some(false)
        );
        assert_eq!(
            fixture["safety_contract"]["billing_ledger_write"].as_bool(),
            Some(false)
        );

        let plan = recovery_probe_plan(
            DEFAULT_TENANT_ID,
            vec![
                candidate(1, "cooldown", "enabled"),
                candidate(2, "recovery_probe", "degraded"),
                candidate(3, "enabled", "enabled"),
                candidate(4, "auth_failed", "enabled"),
                candidate(5, "cooldown", "manual_disabled"),
            ],
        );
        let serialized = serde_json::to_string(&plan).expect("plan should serialize");

        assert_eq!(
            plan.dry_run,
            fixture["expected_plan"]["dry_run"].as_bool().unwrap()
        );
        assert_eq!(
            plan.upstream_calls,
            fixture["expected_plan"]["upstream_calls"]
                .as_bool()
                .unwrap()
        );
        assert_eq!(
            plan.candidate_count as u64,
            fixture["expected_plan"]["candidate_count"]
                .as_u64()
                .unwrap()
        );
        assert_eq!(
            plan.actions
                .iter()
                .map(|action| action.provider_key_status.as_str())
                .collect::<Vec<_>>(),
            fixture_string_array(&fixture["expected_plan"]["included_statuses"])
        );
        assert_contract_must_not_echo(&serialized, &fixture);
    }

    #[tokio::test]
    async fn recovery_probe_execute_success_enables_provider_key() {
        let probe =
            MockRecoveryProbeRunner::new([(Uuid::from_u128(1), RecoveryProbeCheck::success(true))]);
        let status_writer = MockProviderKeyStatusWriter::default();

        let report = execute_recovery_probes(
            DEFAULT_TENANT_ID,
            vec![candidate(1, "cooldown", "enabled")],
            &probe,
            &status_writer,
        )
        .await;

        assert!(!report.dry_run);
        assert!(report.upstream_calls);
        assert_eq!(report.candidate_count, 1);
        assert_eq!(report.success_count, 1);
        assert_eq!(report.failure_count, 0);
        assert_eq!(report.migration_applied_count, 1);
        assert_eq!(report.migration_error_count, 0);
        assert_eq!(
            status_writer.updates(),
            vec![(DEFAULT_TENANT_ID, Uuid::from_u128(1), "enabled".to_string())]
        );
        assert_eq!(report.results[0].probe_result, "success");
        assert_eq!(report.results[0].transition_from_status, "cooldown");
        assert_eq!(report.results[0].transition_to_status, "enabled");
        assert!(report.results[0].status_update_attempted);
        assert!(report.results[0].status_update_applied);
    }

    #[tokio::test]
    async fn recovery_probe_contract_fixture_self_tests_mock_execute() {
        let fixture = recovery_probe_contract_fixture();
        let command = parse_command(command_args_from_fixture(&fixture, "execute"))
            .expect("execute command should parse");

        assert_eq!(
            command,
            WorkerCommand::RecoveryProbe {
                mode: RecoveryProbeMode::Execute,
                tenant_id: DEFAULT_TENANT_ID,
                limit: 4,
            }
        );

        let must_not_echo = fixture_string_array(&fixture["must_not_echo"]);
        let raw_provider_secret = must_not_echo[0].to_string();
        let raw_fingerprint = must_not_echo[1].to_string();
        let raw_encrypted_secret = must_not_echo[2].to_string();
        let auth_header_name = raw_authorization_header_name();
        let bearer_scheme = raw_bearer_scheme();
        let probe = MockRecoveryProbeRunner::new([
            (Uuid::from_u128(1), RecoveryProbeCheck::success(true)),
            (
                Uuid::from_u128(2),
                RecoveryProbeCheck::failure(
                    format!(
                        "probe failed {auth_header_name}: {bearer_scheme} {raw_provider_secret} {raw_fingerprint} {raw_encrypted_secret}",
                    ),
                    true,
                ),
            ),
            (
                Uuid::from_u128(3),
                RecoveryProbeCheck::failure("provider_rate_limited", true),
            ),
            (Uuid::from_u128(4), RecoveryProbeCheck::success(true)),
        ]);
        let status_writer = MockProviderKeyStatusWriter::failing_for(
            Uuid::from_u128(4),
            format!(
                "db rejected {auth_header_name}: {bearer_scheme} {raw_provider_secret} with {raw_fingerprint}",
            ),
        );

        let report = execute_recovery_probes(
            DEFAULT_TENANT_ID,
            vec![
                candidate(1, "cooldown", "enabled"),
                candidate(2, "cooldown", "enabled"),
                candidate(3, "recovery_probe", "enabled"),
                candidate(4, "cooldown", "enabled"),
            ],
            &probe,
            &status_writer,
        )
        .await;
        let serialized = serde_json::to_string(&report).expect("report should serialize");

        assert_eq!(
            report.dry_run,
            fixture["expected_execution"]["dry_run"].as_bool().unwrap()
        );
        assert_eq!(
            report.upstream_calls,
            fixture["expected_execution"]["upstream_calls"]
                .as_bool()
                .unwrap()
        );
        assert_eq!(
            report.candidate_count as u64,
            fixture["expected_execution"]["candidate_count"]
                .as_u64()
                .unwrap()
        );
        assert_eq!(
            report.success_count as u64,
            fixture["expected_execution"]["success_count"]
                .as_u64()
                .unwrap()
        );
        assert_eq!(
            report.failure_count as u64,
            fixture["expected_execution"]["failure_count"]
                .as_u64()
                .unwrap()
        );
        assert_eq!(
            report.migration_applied_count as u64,
            fixture["expected_execution"]["migration_applied_count"]
                .as_u64()
                .unwrap()
        );
        assert_eq!(
            report.migration_error_count as u64,
            fixture["expected_execution"]["migration_error_count"]
                .as_u64()
                .unwrap()
        );
        assert_eq!(
            status_writer.updates(),
            vec![(DEFAULT_TENANT_ID, Uuid::from_u128(1), "enabled".to_string())]
        );

        let expected_results = fixture["expected_execution"]["results"]
            .as_array()
            .expect("expected execution results should be an array");
        assert_eq!(report.results.len(), expected_results.len());
        for (result, expected) in report.results.iter().zip(expected_results) {
            assert_eq!(
                result.action.provider_key_id.to_string(),
                expected["provider_key_id"].as_str().unwrap()
            );
            assert_eq!(
                result.probe_result,
                expected["probe_result"].as_str().unwrap()
            );
            assert_eq!(
                result.transition_from_status,
                expected["from"].as_str().unwrap()
            );
            assert_eq!(
                result.transition_to_status,
                expected["to"].as_str().unwrap()
            );
            assert_eq!(
                result.status_update_attempted,
                expected["status_update_attempted"].as_bool().unwrap()
            );
            assert_eq!(
                result.status_update_applied,
                expected["status_update_applied"].as_bool().unwrap()
            );
        }
        assert!(report.results[3].status_update_error.is_some());
        assert_contract_must_not_echo(&serialized, &fixture);
        assert!(!serialized.contains(&raw_provider_secret));
        assert!(!serialized.contains(&raw_fingerprint));
        assert!(!serialized.contains(&raw_encrypted_secret));
        assert!(!serialized.contains(&auth_header_name));
    }

    #[tokio::test]
    async fn recovery_probe_execute_failure_keeps_cooldown_without_status_update() {
        let auth_header_name = raw_authorization_header_name();
        let bearer_scheme = raw_bearer_scheme();
        let raw_provider_secret = raw_provider_secret_fixture();
        let raw_fingerprint = raw_fingerprint_fixture();
        let raw_encrypted_secret = raw_encrypted_secret_fixture();
        let mut cooldown_candidate = candidate(1, "cooldown", "enabled");
        cooldown_candidate.channel_endpoint =
            format!("https://user:pass@provider.example/v1?api_key={raw_provider_secret}");
        let probe = MockRecoveryProbeRunner::new([(
            Uuid::from_u128(1),
            RecoveryProbeCheck::failure(
                format!(
                    "{auth_header_name}: {bearer_scheme} {raw_provider_secret} secret_fingerprint={raw_fingerprint} encrypted_secret={raw_encrypted_secret}",
                ),
                true,
            ),
        )]);
        let status_writer = MockProviderKeyStatusWriter::default();

        let report = execute_recovery_probes(
            DEFAULT_TENANT_ID,
            vec![cooldown_candidate],
            &probe,
            &status_writer,
        )
        .await;
        let serialized = serde_json::to_string(&report).expect("report should serialize");

        assert_eq!(report.failure_count, 1);
        assert_eq!(report.migration_applied_count, 0);
        assert!(status_writer.updates().is_empty());
        assert_eq!(report.results[0].probe_result, "failure");
        assert_eq!(report.results[0].transition_to_status, "cooldown");
        assert!(!report.results[0].status_update_attempted);
        assert!(!serialized.contains(&raw_provider_secret));
        assert!(!serialized.contains(&raw_fingerprint));
        assert!(!serialized.contains(&raw_encrypted_secret));
        assert!(!serialized.contains("secret_fingerprint"));
        assert!(!serialized.contains("encrypted_secret"));
        assert!(!serialized.contains(&auth_header_name));
        assert!(!serialized.contains("user:pass"));
        assert!(!serialized.contains("api_key"));
    }

    #[tokio::test]
    async fn recovery_probe_execute_failure_preserves_recovery_probe_status() {
        let probe = MockRecoveryProbeRunner::new([(
            Uuid::from_u128(1),
            RecoveryProbeCheck::failure("provider_rate_limited", true),
        )]);
        let status_writer = MockProviderKeyStatusWriter::default();

        let report = execute_recovery_probes(
            DEFAULT_TENANT_ID,
            vec![candidate(1, "recovery_probe", "enabled")],
            &probe,
            &status_writer,
        )
        .await;

        assert_eq!(report.failure_count, 1);
        assert!(status_writer.updates().is_empty());
        assert_eq!(report.results[0].transition_from_status, "recovery_probe");
        assert_eq!(report.results[0].transition_to_status, "recovery_probe");
        assert!(!report.results[0].status_update_attempted);
    }

    #[tokio::test]
    async fn recovery_probe_execute_redacts_status_update_errors() {
        let auth_header_name = raw_authorization_header_name();
        let bearer_scheme = raw_bearer_scheme();
        let raw_provider_secret = raw_provider_secret_fixture();
        let raw_fingerprint = raw_fingerprint_fixture();
        let probe =
            MockRecoveryProbeRunner::new([(Uuid::from_u128(1), RecoveryProbeCheck::success(true))]);
        let status_writer = MockProviderKeyStatusWriter::failing(format!(
            "db rejected {auth_header_name}: {bearer_scheme} {raw_provider_secret} with {raw_fingerprint}",
        ));

        let report = execute_recovery_probes(
            DEFAULT_TENANT_ID,
            vec![candidate(1, "cooldown", "enabled")],
            &probe,
            &status_writer,
        )
        .await;
        let serialized = serde_json::to_string(&report).expect("report should serialize");

        assert_eq!(report.migration_error_count, 1);
        assert!(report.results[0].status_update_attempted);
        assert!(!report.results[0].status_update_applied);
        assert!(!serialized.contains(&auth_header_name));
        assert!(!serialized.contains(&raw_provider_secret));
        assert!(!serialized.contains(&raw_fingerprint));
    }

    #[test]
    fn recovery_probe_endpoint_sanitizer_removes_userinfo_and_query() {
        let sanitized =
            safe_endpoint_text("https://raw-user:raw-pass@provider.example/v1?api_key=raw-token");

        assert_eq!(sanitized, "https://provider.example/v1");
    }

    #[derive(Default)]
    struct MockProviderKeyStatusWriter {
        updates: Mutex<Vec<(Uuid, Uuid, String)>>,
        error: Option<String>,
        errors_by_id: HashMap<Uuid, String>,
    }

    impl MockProviderKeyStatusWriter {
        fn failing(error: impl Into<String>) -> Self {
            Self {
                updates: Mutex::new(Vec::new()),
                error: Some(error.into()),
                errors_by_id: HashMap::new(),
            }
        }

        fn failing_for(provider_key_id: Uuid, error: impl Into<String>) -> Self {
            Self {
                updates: Mutex::new(Vec::new()),
                error: None,
                errors_by_id: HashMap::from([(provider_key_id, error.into())]),
            }
        }

        fn updates(&self) -> Vec<(Uuid, Uuid, String)> {
            self.updates.lock().expect("updates lock").clone()
        }
    }

    impl ProviderKeyStatusWriter for MockProviderKeyStatusWriter {
        fn set_provider_key_status<'a>(
            &'a self,
            tenant_id: Uuid,
            provider_key_id: Uuid,
            status: &'a str,
        ) -> BoxFuture<'a, Result<bool, String>> {
            let error = self
                .errors_by_id
                .get(&provider_key_id)
                .or(self.error.as_ref());
            let result = if let Some(error) = error {
                Err(error.clone())
            } else {
                self.updates.lock().expect("updates lock").push((
                    tenant_id,
                    provider_key_id,
                    status.to_string(),
                ));
                Ok(true)
            };

            Box::pin(async move { result })
        }
    }

    struct MockRecoveryProbeRunner {
        checks: HashMap<Uuid, RecoveryProbeCheck>,
    }

    impl MockRecoveryProbeRunner {
        fn new(entries: impl IntoIterator<Item = (Uuid, RecoveryProbeCheck)>) -> Self {
            Self {
                checks: entries.into_iter().collect(),
            }
        }
    }

    impl RecoveryProbeRunner for MockRecoveryProbeRunner {
        fn probe<'a>(
            &'a self,
            candidate: &'a RecoveryProbeCandidate,
        ) -> BoxFuture<'a, RecoveryProbeCheck> {
            let check = self
                .checks
                .get(&candidate.provider_key_id)
                .cloned()
                .unwrap_or_else(|| RecoveryProbeCheck::failure("probe_not_mocked", false));

            Box::pin(async move { check })
        }
    }

    fn recovery_probe_contract_fixture() -> Value {
        serde_json::from_str(include_str!(
            "../../../tests/fixtures/worker/recovery_probe_contract.json"
        ))
        .expect("recovery probe contract fixture should be valid json")
    }

    fn command_args_from_fixture(fixture: &Value, command_name: &str) -> Vec<String> {
        fixture["commands"][command_name]
            .as_str()
            .expect("fixture command should be a string")
            .split_whitespace()
            .map(str::to_string)
            .collect()
    }

    fn fixture_string_array(value: &Value) -> Vec<&str> {
        value
            .as_array()
            .expect("fixture value should be an array")
            .iter()
            .map(|value| value.as_str().expect("fixture value should be a string"))
            .collect()
    }

    fn assert_contract_must_not_echo(serialized: &str, fixture: &Value) {
        for forbidden in fixture["must_not_echo"]
            .as_array()
            .expect("must_not_echo should be an array")
        {
            let forbidden = forbidden
                .as_str()
                .expect("must_not_echo entries should be strings");
            assert!(
                !serialized.contains(forbidden),
                "serialized recovery probe contract leaked `{forbidden}`"
            );
        }
    }

    fn raw_authorization_header_name() -> String {
        ["Author", "ization"].concat()
    }

    fn raw_bearer_scheme() -> String {
        ["Bear", "er"].concat()
    }

    fn raw_provider_secret_fixture() -> String {
        ["sk", "live", "provider", "secret"].join("-")
    }

    fn raw_fingerprint_fixture() -> String {
        ["fingerprint", "never", "return"].join("-")
    }

    fn raw_encrypted_secret_fixture() -> String {
        ["encrypted", "secret", "never", "return"].join("-")
    }

    fn candidate(
        id: u128,
        provider_key_status: &str,
        channel_status: &str,
    ) -> RecoveryProbeCandidate {
        RecoveryProbeCandidate {
            tenant_id: DEFAULT_TENANT_ID,
            provider_id: Uuid::from_u128(10),
            provider_code: "openai".to_string(),
            provider_name: "OpenAI".to_string(),
            channel_id: Uuid::from_u128(20),
            channel_name: "primary".to_string(),
            channel_endpoint: "https://provider.example/v1".to_string(),
            channel_protocol_mode: "openai_compatible".to_string(),
            channel_status: channel_status.to_string(),
            provider_key_id: Uuid::from_u128(id),
            key_alias: "primary".to_string(),
            provider_key_status: provider_key_status.to_string(),
            provider_key_health_score: 0.25,
            cooldown_until: Some("2026-06-02 12:05:00+00".to_string()),
            last_error_code: Some("provider_rate_limited".to_string()),
            has_secret_fingerprint: true,
            secret_redacted: true,
        }
    }
}
