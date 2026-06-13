mod alert_webhook;
mod billing_reconciliation;
mod clickhouse_log_store;
mod prompt_eval_shadow;

use ai_gateway_adapters::{OpenAiAdapterError, OpenAiCompatibleClient};
use ai_gateway_auth::{
    PROVIDER_KEY_ENCRYPTION_ALGORITHM, PROVIDER_KEY_MASTER_KEY_LEN, PROVIDER_KEY_NONCE_LEN,
    ProviderKeyContext, SealedProviderKey, open_provider_key,
};
use ai_gateway_config::AppConfig;
use ai_gateway_db::{
    DbRepository, RecoveryProbeCandidate, RecoveryProbeProviderKeyUpdate,
    RecoveryProbeSecretMaterial, connect,
};
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
    clickhouse_log_store_plan, clickhouse_log_store_plan_with_readback,
    clickhouse_log_store_plan_with_runtime_wal, clickhouse_log_store_plan_with_service_readiness,
    read_clickhouse_log_store_input,
};
use prompt_eval_shadow::{
    PromptEvalShadowInputSource, PromptEvalShadowMode, prompt_eval_shadow_execute_error,
    prompt_eval_shadow_plan, read_prompt_eval_shadow_input,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    env,
    future::Future,
    pin::Pin,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use uuid::Uuid;

const DEFAULT_TENANT_ID: Uuid = Uuid::from_u128(0x00000000_0000_0000_0000_000000000001);
const DEFAULT_RECOVERY_PROBE_LIMIT: i64 = 100;
const PROVIDER_KEY_MASTER_KEY_ENV: &str = "AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_BASE64";
const RECOVERY_PROBE_TIMEOUT_SECONDS: u64 = 5;
const SUBSCRIPTION_SCHEDULER_MAX_BACKOFF_SECONDS: u64 = 300;
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
            readback,
            write_artifact,
            service_readiness,
            write_service_readiness_artifact,
            local_smoke,
            write_local_smoke_artifact,
            production_smoke_artifact_path,
            ..
        }) => {
            run_clickhouse_log_store_dry_run(
                tenant_id,
                input_path,
                readback,
                write_artifact,
                service_readiness,
                write_service_readiness_artifact,
                local_smoke,
                write_local_smoke_artifact,
                false,
                false,
                production_smoke_artifact_path,
            )
            .await
        }
        Ok(WorkerCommand::ClickHouseLogStore {
            mode: ClickHouseLogStoreMode::Execute,
            force,
            ..
        }) => Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            clickhouse_log_store_execute_error(force),
        )
        .into()),
        Ok(WorkerCommand::SubscriptionScheduler {
            control_plane_base_url,
            admin_session_token_env,
            tenant_id,
            worker_id,
            limit,
            mode,
            event_status,
            event_type,
            reason,
            interval_seconds,
            max_runs,
            timeout_seconds,
        }) => {
            run_subscription_scheduler_worker(SubscriptionSchedulerWorkerConfig {
                control_plane_base_url,
                admin_session_token_env,
                tenant_id,
                worker_id,
                limit,
                mode,
                event_status,
                event_type,
                reason,
                interval_seconds,
                max_runs,
                timeout_seconds,
            })
            .await
        }
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
    let probe = HttpRecoveryProbeRunner::new(&repository);
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
    readback: bool,
    write_artifact: bool,
    service_readiness: bool,
    write_service_readiness_artifact: bool,
    local_smoke: bool,
    write_local_smoke_artifact: bool,
    dev_writer: bool,
    write_dev_writer_artifact: bool,
    production_smoke_artifact_path: Option<String>,
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
    let plan = if write_artifact {
        clickhouse_log_store_plan_with_runtime_wal(tenant_id, source, input, true, true)
    } else if write_service_readiness_artifact {
        clickhouse_log_store_plan_with_service_readiness(
            tenant_id,
            source,
            input,
            false,
            false,
            true,
            true,
            false,
            false,
            false,
            false,
            production_smoke_artifact_path,
        )
    } else if write_dev_writer_artifact {
        clickhouse_log_store_plan_with_service_readiness(
            tenant_id,
            source,
            input,
            false,
            false,
            false,
            false,
            false,
            false,
            true,
            true,
            production_smoke_artifact_path,
        )
    } else if dev_writer {
        clickhouse_log_store_plan_with_service_readiness(
            tenant_id,
            source,
            input,
            false,
            false,
            false,
            false,
            false,
            false,
            true,
            false,
            production_smoke_artifact_path,
        )
    } else if write_local_smoke_artifact {
        clickhouse_log_store_plan_with_service_readiness(
            tenant_id,
            source,
            input,
            false,
            false,
            false,
            false,
            true,
            true,
            false,
            false,
            production_smoke_artifact_path,
        )
    } else if local_smoke {
        clickhouse_log_store_plan_with_service_readiness(
            tenant_id,
            source,
            input,
            false,
            false,
            false,
            false,
            true,
            false,
            false,
            false,
            production_smoke_artifact_path,
        )
    } else if service_readiness {
        clickhouse_log_store_plan_with_service_readiness(
            tenant_id,
            source,
            input,
            false,
            false,
            true,
            false,
            false,
            false,
            false,
            false,
            production_smoke_artifact_path,
        )
    } else if readback {
        clickhouse_log_store_plan_with_readback(tenant_id, source, input, true)
    } else if production_smoke_artifact_path.is_some() {
        clickhouse_log_store_plan_with_service_readiness(
            tenant_id,
            source,
            input,
            false,
            false,
            false,
            false,
            false,
            false,
            false,
            false,
            production_smoke_artifact_path,
        )
    } else {
        clickhouse_log_store_plan(tenant_id, source, input)
    }
    .map_err(|error| {
        std::io::Error::new(std::io::ErrorKind::InvalidInput, safe_error_text(&error))
    })?;

    serde_json::to_writer_pretty(std::io::stdout(), &plan)?;
    println!();
    Ok(())
}

async fn run_subscription_scheduler_worker(
    config: SubscriptionSchedulerWorkerConfig,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let admin_session_token = env::var(&config.admin_session_token_env).map_err(|_| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!(
                "{} is required and will be sent as x-admin-session; token value is never printed",
                config.admin_session_token_env
            ),
        )
    })?;
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(config.timeout_seconds))
        .build()?;

    let mut run_number = 0_u64;
    let mut consecutive_errors = 0_u64;
    loop {
        run_number += 1;
        let started = Instant::now();
        let report = match run_subscription_scheduler_worker_once(
            &client,
            &config,
            &admin_session_token,
            run_number,
        )
        .await
        {
            Ok(report) => {
                consecutive_errors = 0;
                report
            }
            Err(error) => {
                consecutive_errors += 1;
                let report = subscription_scheduler_worker_error_report(
                    &config,
                    run_number,
                    started.elapsed(),
                    consecutive_errors,
                    error.as_ref(),
                );
                if config.interval_seconds.is_none() {
                    serde_json::to_writer_pretty(std::io::stdout(), &report)?;
                    println!();
                    return Err(error);
                }
                report
            }
        };

        if config.interval_seconds.is_some() {
            println!("{}", serde_json::to_string(&report)?);
        } else {
            serde_json::to_writer_pretty(std::io::stdout(), &report)?;
            println!();
        }

        if let Some(max_runs) = config.max_runs
            && run_number >= max_runs
        {
            break;
        }

        let Some(interval_seconds) = config.interval_seconds else {
            break;
        };
        let sleep_seconds = if consecutive_errors == 0 {
            interval_seconds
        } else {
            subscription_scheduler_backoff_seconds(interval_seconds, consecutive_errors)
        };
        tokio::time::sleep(Duration::from_secs(sleep_seconds)).await;
    }

    Ok(())
}

async fn run_subscription_scheduler_worker_once(
    client: &reqwest::Client,
    config: &SubscriptionSchedulerWorkerConfig,
    admin_session_token: &str,
    run_number: u64,
) -> Result<Value, Box<dyn std::error::Error + Send + Sync>> {
    let started = Instant::now();
    let run_due_url = control_plane_admin_url(
        &config.control_plane_base_url,
        "/admin/subscriptions/run-due-scheduler-events",
    );
    let handoff_url = control_plane_admin_url(
        &config.control_plane_base_url,
        "/admin/subscriptions/scheduler-worker",
    );
    let reason = config.reason.clone().or_else(|| {
        if config.mode == "dry_run" {
            None
        } else {
            Some("subscription scheduler worker command".to_string())
        }
    });
    let body = json!({
        "tenant_id": config.tenant_id,
        "worker_id": config.worker_id,
        "limit": config.limit,
        "mode": config.mode,
        "event_status": config.event_status,
        "event_type": config.event_type,
        "reason": reason
    });

    let run_due_response = client
        .post(&run_due_url)
        .header("x-admin-session", admin_session_token)
        .json(&body)
        .send()
        .await?;
    let run_due_status = run_due_response.status().as_u16();
    let run_due_json = response_json_or_error(run_due_response).await?;

    let handoff_status_filter = if config.event_status == "replayed" {
        "replayed"
    } else {
        "scheduled"
    };
    let handoff_response = client
        .get(&handoff_url)
        .header("x-admin-session", admin_session_token)
        .query(&[
            ("limit", config.limit.to_string()),
            ("event_status", handoff_status_filter.to_string()),
            ("event_type", config.event_type.clone()),
            ("worker_id", config.worker_id.clone()),
        ])
        .send()
        .await?;
    let handoff_status = handoff_response.status().as_u16();
    let handoff_json = response_json_or_error(handoff_response).await?;
    let run_due_counts = subscription_scheduler_counts(&run_due_json);
    let supervisor_counts = subscription_scheduler_counts(&handoff_json);
    let next_run = subscription_scheduler_next_run(&run_due_json, &handoff_json);
    let provider_executor_handoff_summary =
        subscription_scheduler_provider_executor_handoff_summary(&run_due_json);
    let refund_or_credit_note_handoff_summary =
        subscription_scheduler_refund_or_credit_note_handoff_summary(&run_due_json);
    let scheduler_worker_readback = subscription_scheduler_worker_readback_summary(
        &handoff_json,
        handoff_status,
        provider_executor_handoff_summary.clone(),
        refund_or_credit_note_handoff_summary.clone(),
    );
    let duration_ms = duration_ms(started.elapsed());

    Ok(json!({
        "schema": "ai_worker_subscription_scheduler_command.v1",
        "run_number": run_number,
        "status": "ok",
        "worker_id": config.worker_id,
        "tenant_id": config.tenant_id,
        "mode": config.mode,
        "limit": config.limit,
        "processed_count": run_due_counts.processed,
        "skipped_count": run_due_counts.skipped,
        "blocked_count": run_due_counts.blocked,
        "next_run": next_run,
        "payment_capture_handoff_summary": provider_executor_handoff_summary.clone(),
        "provider_executor_handoff_summary": provider_executor_handoff_summary.clone(),
        "refund_or_credit_note_handoff_summary": refund_or_credit_note_handoff_summary.clone(),
        "scheduler_worker_readback": scheduler_worker_readback,
        "duration_ms": duration_ms,
        "control_plane": {
            "base_url": safe_endpoint_text(&config.control_plane_base_url),
            "run_due_endpoint": "/admin/subscriptions/run-due-scheduler-events",
            "handoff_endpoint": "/admin/subscriptions/scheduler-worker",
            "admin_session_token_env": config.admin_session_token_env,
            "admin_session_token_value_returned": false
        },
        "request": {
            "mode": config.mode,
            "limit": config.limit,
            "event_status": config.event_status,
            "event_type": config.event_type,
            "reason_present": reason.is_some(),
            "interval_seconds": config.interval_seconds,
            "max_runs": config.max_runs,
            "max_iterations": config.max_runs,
            "timeout_seconds": config.timeout_seconds
        },
        "run_due": {
            "http_status": run_due_status,
            "summary": {
                "processed_count": run_due_counts.processed,
                "skipped_count": run_due_counts.skipped,
                "blocked_count": run_due_counts.blocked,
                "next_run": next_run,
                "payment_capture_handoff_summary": provider_executor_handoff_summary.clone(),
                "provider_executor_handoff_summary": provider_executor_handoff_summary.clone(),
                "refund_or_credit_note_handoff_summary": refund_or_credit_note_handoff_summary.clone()
            },
            "response": run_due_json
        },
        "supervisor_readback": {
            "http_status": handoff_status,
            "event_status_filter": handoff_status_filter,
            "summary": {
                "processed_count": supervisor_counts.processed,
                "skipped_count": supervisor_counts.skipped,
                "blocked_count": supervisor_counts.blocked,
                "payment_capture_handoff_summary": provider_executor_handoff_summary.clone(),
                "provider_executor_handoff_summary": provider_executor_handoff_summary.clone(),
                "refund_or_credit_note_handoff_summary": refund_or_credit_note_handoff_summary.clone()
            },
            "response": handoff_json
        },
        "loop": {
            "interval_seconds": config.interval_seconds,
            "bounded_sleep": true,
            "error_backoff_max_seconds": SUBSCRIPTION_SCHEDULER_MAX_BACKOFF_SECONDS,
            "next_sleep_seconds": config.interval_seconds.unwrap_or(0),
            "next_loop_attempt_unix_ms": config.interval_seconds.map(|seconds| unix_epoch_ms().saturating_add(seconds.saturating_mul(1000)))
        },
        "operator_entrypoints": {
            "one_shot": "cargo run -p ai-worker -- subscription-scheduler --once --worker-id <id> --mode apply --reason <reason>",
            "loop": "cargo run -p ai-worker -- subscription-scheduler --interval-seconds 60 --max-iterations 10 --worker-id <id> --mode apply --reason <reason>",
            "cronjob_supported": true,
            "systemd_timer_supported": true,
            "long_running_process_started_by_this_check": false
        },
        "secret_safe": true,
        "raw_admin_session_returned": false,
        "authorization_returned": false,
        "cookie_returned": false
    }))
}

async fn response_json_or_error(
    response: reqwest::Response,
) -> Result<Value, Box<dyn std::error::Error + Send + Sync>> {
    let status = response.status();
    let body = response.text().await.unwrap_or_default();
    if !status.is_success() {
        return Err(std::io::Error::other(format!(
            "control-plane request failed with HTTP {}: {}",
            status.as_u16(),
            safe_error_text(&body)
        ))
        .into());
    }

    serde_json::from_str(&body).map_err(|error| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("control-plane returned non-JSON body: {error}"),
        )
        .into()
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct SubscriptionSchedulerCounts {
    processed: u64,
    skipped: u64,
    blocked: u64,
}

fn subscription_scheduler_counts(value: &Value) -> SubscriptionSchedulerCounts {
    let data = response_data(value);
    SubscriptionSchedulerCounts {
        processed: json_u64(data, &["processed_count", "processed"])
            .unwrap_or_else(|| json_array_len(data.get("processed"))),
        skipped: json_u64(data, &["skipped_count", "skipped"])
            .unwrap_or_else(|| json_array_len(data.get("skipped"))),
        blocked: json_u64(data, &["blocked_count", "blocked"])
            .unwrap_or_else(|| json_array_len(data.get("blocked"))),
    }
}

fn subscription_scheduler_next_run(run_due: &Value, supervisor: &Value) -> Value {
    let run_due_data = response_data(run_due);
    if let Some(next_run) = run_due_data.get("next_run") {
        return next_run.clone();
    }

    let supervisor_data = response_data(supervisor);
    json!({
        "at": supervisor_data.get("next_run_at").cloned().unwrap_or(Value::Null),
        "source": "subscription_scheduler_worker_supervisors.next_run_at",
        "runtime_daemon_running": false,
        "operator_polling_supported": true
    })
}

fn subscription_scheduler_worker_readback_summary(
    value: &Value,
    http_status: u16,
    provider_executor_handoff_summary: Value,
    refund_or_credit_note_handoff_summary: Value,
) -> Value {
    let data = response_data(value);
    let counts = subscription_scheduler_counts(value);
    json!({
        "http_status": http_status,
        "schema": data.get("schema").cloned().unwrap_or(Value::Null),
        "state_available": data.get("state_available").cloned().unwrap_or(Value::Null),
        "status": data.get("status").cloned().unwrap_or(Value::Null),
        "worker_id": data.get("worker_id").cloned().unwrap_or(Value::Null),
        "lease_heartbeat_at": data.get("lease_heartbeat_at").cloned().unwrap_or(Value::Null),
        "last_run_at": data.get("last_run_at").cloned().unwrap_or(Value::Null),
        "next_run_at": data.get("next_run_at").cloned().unwrap_or(Value::Null),
        "processed_count": counts.processed,
        "skipped_count": counts.skipped,
        "blocked_count": counts.blocked,
        "payment_capture_handoff_summary": provider_executor_handoff_summary.clone(),
        "provider_executor_handoff_summary": provider_executor_handoff_summary,
        "refund_or_credit_note_handoff_summary": refund_or_credit_note_handoff_summary,
        "last_mode": data.get("last_mode").cloned().unwrap_or(Value::Null),
        "background_process_started": data.get("background_process_started").cloned().unwrap_or(Value::Null),
        "secret_safe": data.get("secret_safe").cloned().unwrap_or(json!(true)),
        "authorization_returned": data.get("authorization_returned").cloned().unwrap_or(json!(false))
    })
}

#[derive(Default)]
struct SubscriptionSchedulerRefundOrCreditNoteHandoffSummary {
    handoff_count: u64,
    local_credit_note_ref_present_count: u64,
    local_payment_refund_ref_present_count: u64,
    provider_refund_ref_present_count: u64,
    refund_executed_true_count: u64,
    refund_executed_false_count: u64,
    blocked_reason_counts: BTreeMap<String, u64>,
}

fn subscription_scheduler_refund_or_credit_note_handoff_summary(value: &Value) -> Value {
    let mut summary = SubscriptionSchedulerRefundOrCreditNoteHandoffSummary::default();
    collect_subscription_scheduler_refund_or_credit_note_handoffs(
        response_data(value),
        &mut summary,
    );

    json!({
        "schema": "ai_worker_subscription_scheduler_refund_or_credit_note_handoff_summary.v1",
        "source": "control_plane_run_due.refund_or_credit_note_handoff",
        "handoff_count": summary.handoff_count,
        "local_credit_note_ref_present_count": summary.local_credit_note_ref_present_count,
        "local_payment_refund_ref_present_count": summary.local_payment_refund_ref_present_count,
        "provider_refund_ref_present_count": summary.provider_refund_ref_present_count,
        "blocked_reason_counts": summary.blocked_reason_counts,
        "refund_executed": summary.refund_executed_true_count > 0,
        "refund_executed_false_count": summary.refund_executed_false_count,
        "refund_executed_true_count": summary.refund_executed_true_count,
        "refund_executed_all_false": summary.handoff_count > 0 && summary.refund_executed_true_count == 0,
        "network_or_provider_call_performed": false,
        "raw_payload_returned": false,
        "authorization_returned": false,
        "cookie_returned": false,
        "secret_safe": true
    })
}

fn collect_subscription_scheduler_refund_or_credit_note_handoffs(
    data: &Value,
    summary: &mut SubscriptionSchedulerRefundOrCreditNoteHandoffSummary,
) {
    collect_subscription_scheduler_refund_or_credit_note_handoffs_from_items(
        data.get("processed"),
        summary,
    );
    collect_subscription_scheduler_refund_or_credit_note_handoffs_from_items(
        data.get("skipped"),
        summary,
    );
    collect_subscription_scheduler_refund_or_credit_note_handoffs_from_items(
        data.get("blocked"),
        summary,
    );
}

fn collect_subscription_scheduler_refund_or_credit_note_handoffs_from_items(
    items: Option<&Value>,
    summary: &mut SubscriptionSchedulerRefundOrCreditNoteHandoffSummary,
) {
    let Some(items) = items.and_then(Value::as_array) else {
        return;
    };

    for item in items {
        if let Some(handoff) = subscription_scheduler_refund_or_credit_note_handoff_value(item) {
            record_subscription_scheduler_refund_or_credit_note_handoff(handoff, summary);
        }
    }
}

fn subscription_scheduler_refund_or_credit_note_handoff_value(item: &Value) -> Option<&Value> {
    item.get("refund_or_credit_note_handoff")
        .or_else(|| item.pointer("/event/refund_or_credit_note_handoff"))
        .or_else(|| item.pointer("/status_transition/refund_or_credit_note_handoff"))
        .or_else(|| item.pointer("/local_execution_readback/refund_or_credit_note_handoff"))
}

fn record_subscription_scheduler_refund_or_credit_note_handoff(
    handoff: &Value,
    summary: &mut SubscriptionSchedulerRefundOrCreditNoteHandoffSummary,
) {
    summary.handoff_count += 1;
    if handoff
        .pointer("/local_refs/local_credit_note_refs_present")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        summary.local_credit_note_ref_present_count += 1;
    }
    if handoff
        .pointer("/local_refs/local_payment_refund_ref_present")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        summary.local_payment_refund_ref_present_count += 1;
    }
    if handoff
        .pointer("/payment_refund/provider_refund_ref_present")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        summary.provider_refund_ref_present_count += 1;
    }
    if handoff
        .get("refund_executed")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        summary.refund_executed_true_count += 1;
    } else {
        summary.refund_executed_false_count += 1;
    }
    if let Some(reasons) = handoff.get("blocked_reasons").and_then(Value::as_array) {
        for reason in reasons {
            if let Some(reason) = reason.as_str() {
                *summary
                    .blocked_reason_counts
                    .entry(safe_error_text(reason))
                    .or_insert(0) += 1;
            }
        }
    }
}

#[derive(Default)]
struct SubscriptionSchedulerProviderHandoffSummary {
    handoff_count: u64,
    ready_for_provider_executor_count: u64,
    not_ready_for_provider_executor_count: u64,
    provider_object_ref_present_count: u64,
    provider_object_ref_missing_count: u64,
    provider_object_ref_unknown_count: u64,
    payment_capture_executed_true_count: u64,
    payment_capture_executed_false_count: u64,
    payment_capture_executed_unknown_count: u64,
    blocked_reason_counts: BTreeMap<String, u64>,
}

fn subscription_scheduler_provider_executor_handoff_summary(value: &Value) -> Value {
    let mut summary = SubscriptionSchedulerProviderHandoffSummary::default();
    collect_subscription_scheduler_provider_handoffs(response_data(value), &mut summary);

    json!({
        "schema": "ai_worker_subscription_scheduler_provider_executor_handoff_summary.v1",
        "source": "control_plane_run_due.payment_capture_handoff",
        "handoff_count": summary.handoff_count,
        "ready_for_provider_executor_count": summary.ready_for_provider_executor_count,
        "not_ready_for_provider_executor_count": summary.not_ready_for_provider_executor_count,
        "blocked_reason_counts": summary.blocked_reason_counts,
        "provider_object_ref_present_counts": {
            "present": summary.provider_object_ref_present_count,
            "missing": summary.provider_object_ref_missing_count,
            "unknown": summary.provider_object_ref_unknown_count
        },
        "payment_capture_executed": summary.payment_capture_executed_true_count > 0,
        "payment_capture_executed_false_count": summary.payment_capture_executed_false_count,
        "payment_capture_executed_true_count": summary.payment_capture_executed_true_count,
        "payment_capture_executed_unknown_count": summary.payment_capture_executed_unknown_count,
        "payment_capture_executed_all_false": summary.handoff_count > 0
            && summary.payment_capture_executed_true_count == 0
            && summary.payment_capture_executed_unknown_count == 0,
        "network_or_provider_call_performed": false,
        "raw_payload_returned": false,
        "authorization_returned": false,
        "cookie_returned": false,
        "secret_safe": true
    })
}

fn collect_subscription_scheduler_provider_handoffs(
    data: &Value,
    summary: &mut SubscriptionSchedulerProviderHandoffSummary,
) {
    collect_subscription_scheduler_provider_handoffs_from_items(data.get("processed"), summary);
    collect_subscription_scheduler_provider_handoffs_from_items(data.get("skipped"), summary);
    collect_subscription_scheduler_provider_handoffs_from_items(data.get("blocked"), summary);
}

fn collect_subscription_scheduler_provider_handoffs_from_items(
    items: Option<&Value>,
    summary: &mut SubscriptionSchedulerProviderHandoffSummary,
) {
    let Some(items) = items.and_then(Value::as_array) else {
        return;
    };

    for item in items {
        if let Some(handoff) = subscription_scheduler_provider_handoff_value(item) {
            record_subscription_scheduler_provider_handoff(handoff, summary);
        }
    }
}

fn subscription_scheduler_provider_handoff_value(item: &Value) -> Option<&Value> {
    item.get("payment_capture_handoff")
        .or_else(|| item.get("payment_provider_executor_handoff"))
        .or_else(|| item.pointer("/event/payment_capture_handoff"))
        .or_else(|| item.pointer("/event/payment_provider_executor_handoff"))
        .or_else(|| item.pointer("/status_transition/payment_capture_handoff"))
        .or_else(|| item.pointer("/local_execution_readback/payment_capture_handoff"))
}

fn record_subscription_scheduler_provider_handoff(
    handoff: &Value,
    summary: &mut SubscriptionSchedulerProviderHandoffSummary,
) {
    summary.handoff_count += 1;
    if handoff
        .get("ready_for_provider_executor")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        summary.ready_for_provider_executor_count += 1;
    } else {
        summary.not_ready_for_provider_executor_count += 1;
    }

    match handoff
        .pointer("/provider_refs/provider_object_ref_present")
        .and_then(Value::as_bool)
    {
        Some(true) => summary.provider_object_ref_present_count += 1,
        Some(false) => summary.provider_object_ref_missing_count += 1,
        None => summary.provider_object_ref_unknown_count += 1,
    }

    match handoff
        .get("payment_capture_executed")
        .and_then(Value::as_bool)
    {
        Some(true) => summary.payment_capture_executed_true_count += 1,
        Some(false) => summary.payment_capture_executed_false_count += 1,
        None => summary.payment_capture_executed_unknown_count += 1,
    }

    if let Some(reasons) = handoff.get("blocked_reasons").and_then(Value::as_array) {
        for reason in reasons {
            if let Some(reason) = reason.as_str() {
                *summary
                    .blocked_reason_counts
                    .entry(safe_error_text(reason))
                    .or_insert(0) += 1;
            }
        }
    }
}

fn subscription_scheduler_worker_error_report(
    config: &SubscriptionSchedulerWorkerConfig,
    run_number: u64,
    elapsed: Duration,
    consecutive_errors: u64,
    error: &(dyn std::error::Error + Send + Sync),
) -> Value {
    let next_sleep_seconds = config
        .interval_seconds
        .map(|interval_seconds| {
            subscription_scheduler_backoff_seconds(interval_seconds, consecutive_errors)
        })
        .unwrap_or(0);

    json!({
        "schema": "ai_worker_subscription_scheduler_command.v1",
        "run_number": run_number,
        "status": "error",
        "worker_id": config.worker_id,
        "tenant_id": config.tenant_id,
        "mode": config.mode,
        "limit": config.limit,
        "processed_count": 0,
        "skipped_count": 0,
        "blocked_count": 1,
        "next_run": Value::Null,
        "payment_capture_handoff_summary": subscription_scheduler_provider_executor_handoff_summary(&json!({})),
        "provider_executor_handoff_summary": subscription_scheduler_provider_executor_handoff_summary(&json!({})),
        "refund_or_credit_note_handoff_summary": subscription_scheduler_refund_or_credit_note_handoff_summary(&json!({})),
        "scheduler_worker_readback": {
            "http_status": Value::Null,
            "state_available": Value::Null,
            "status": "unavailable",
            "processed_count": 0,
            "skipped_count": 0,
            "blocked_count": 1,
            "payment_capture_handoff_summary": subscription_scheduler_provider_executor_handoff_summary(&json!({})),
            "provider_executor_handoff_summary": subscription_scheduler_provider_executor_handoff_summary(&json!({})),
            "refund_or_credit_note_handoff_summary": subscription_scheduler_refund_or_credit_note_handoff_summary(&json!({})),
            "secret_safe": true,
            "authorization_returned": false
        },
        "duration_ms": duration_ms(elapsed),
        "error": {
            "message": safe_error_text(&error.to_string()),
            "consecutive_errors": consecutive_errors,
            "admin_session_token_value_returned": false,
            "authorization_returned": false,
            "cookie_returned": false
        },
        "request": {
            "mode": config.mode,
            "limit": config.limit,
            "event_status": config.event_status,
            "event_type": config.event_type,
            "interval_seconds": config.interval_seconds,
            "max_runs": config.max_runs,
            "max_iterations": config.max_runs,
            "timeout_seconds": config.timeout_seconds
        },
        "loop": {
            "interval_seconds": config.interval_seconds,
            "bounded_sleep": true,
            "error_backoff": true,
            "error_backoff_max_seconds": SUBSCRIPTION_SCHEDULER_MAX_BACKOFF_SECONDS,
            "next_sleep_seconds": next_sleep_seconds,
            "next_loop_attempt_unix_ms": config.interval_seconds.map(|_| unix_epoch_ms().saturating_add(next_sleep_seconds.saturating_mul(1000)))
        },
        "secret_safe": true,
        "raw_admin_session_returned": false,
        "authorization_returned": false,
        "cookie_returned": false
    })
}

fn response_data(value: &Value) -> &Value {
    value.get("data").unwrap_or(value)
}

fn json_u64(value: &Value, keys: &[&str]) -> Option<u64> {
    for key in keys {
        if let Some(number) = value.get(*key).and_then(Value::as_u64) {
            return Some(number);
        }
    }
    None
}

fn json_array_len(value: Option<&Value>) -> u64 {
    value
        .and_then(Value::as_array)
        .map(|items| items.len() as u64)
        .unwrap_or(0)
}

fn subscription_scheduler_backoff_seconds(interval_seconds: u64, consecutive_errors: u64) -> u64 {
    let exponent = consecutive_errors.saturating_sub(1).min(8) as u32;
    let multiplier = 1_u64.checked_shl(exponent).unwrap_or(u64::MAX);
    interval_seconds
        .saturating_mul(multiplier)
        .clamp(1, SUBSCRIPTION_SCHEDULER_MAX_BACKOFF_SECONDS)
}

fn duration_ms(duration: Duration) -> u128 {
    duration.as_millis()
}

fn unix_epoch_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .try_into()
        .unwrap_or(u64::MAX)
}

fn control_plane_admin_url(base_url: &str, path: &str) -> String {
    format!(
        "{}/{}",
        base_url.trim_end_matches('/'),
        path.trim_start_matches('/')
    )
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
        readback: bool,
        write_artifact: bool,
        service_readiness: bool,
        write_service_readiness_artifact: bool,
        local_smoke: bool,
        write_local_smoke_artifact: bool,
        production_smoke_artifact_path: Option<String>,
        force: bool,
    },
    SubscriptionScheduler {
        control_plane_base_url: String,
        admin_session_token_env: String,
        tenant_id: Uuid,
        worker_id: String,
        limit: i64,
        mode: String,
        event_status: String,
        event_type: String,
        reason: Option<String>,
        interval_seconds: Option<u64>,
        max_runs: Option<u64>,
        timeout_seconds: u64,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct SubscriptionSchedulerWorkerConfig {
    control_plane_base_url: String,
    admin_session_token_env: String,
    tenant_id: Uuid,
    worker_id: String,
    limit: i64,
    mode: String,
    event_status: String,
    event_type: String,
    reason: Option<String>,
    interval_seconds: Option<u64>,
    max_runs: Option<u64>,
    timeout_seconds: u64,
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
            let mut readback = false;
            let mut write_artifact = false;
            let mut service_readiness = false;
            let mut write_service_readiness_artifact = false;
            let mut local_smoke = false;
            let mut write_local_smoke_artifact = false;
            let mut production_smoke_artifact_path = None;
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
                    "--check-config" | "--config-readback" => {
                        set_clickhouse_log_store_mode(
                            &mut explicit_mode,
                            ClickHouseLogStoreMode::DryRun,
                            arg.as_str(),
                        )?;
                    }
                    "--final-dod"
                    | "--acceptance-matrix"
                    | "--production-smoke-handoff"
                    | "--final-closure-audit"
                    | "--closure-audit"
                    | "--evidence-watcher"
                    | "--watch-evidence" => {
                        set_clickhouse_log_store_mode(
                            &mut explicit_mode,
                            ClickHouseLogStoreMode::DryRun,
                            arg.as_str(),
                        )?;
                    }
                    "--read-production-smoke-artifact" => {
                        set_clickhouse_log_store_mode(
                            &mut explicit_mode,
                            ClickHouseLogStoreMode::DryRun,
                            arg.as_str(),
                        )?;
                        let raw = args
                            .next()
                            .ok_or_else(|| format!("{arg} requires a JSON file path"))?;
                        production_smoke_artifact_path = Some(raw);
                    }
                    "--artifact" => {
                        let raw = args
                            .next()
                            .ok_or_else(|| "--artifact requires a JSON file path".to_string())?;
                        production_smoke_artifact_path = Some(raw);
                    }
                    "--service-readiness" | "--service-readiness-check" => {
                        set_clickhouse_log_store_mode(
                            &mut explicit_mode,
                            ClickHouseLogStoreMode::DryRun,
                            arg.as_str(),
                        )?;
                        service_readiness = true;
                    }
                    "--write-service-readiness-artifact" => {
                        set_clickhouse_log_store_mode(
                            &mut explicit_mode,
                            ClickHouseLogStoreMode::DryRun,
                            arg.as_str(),
                        )?;
                        service_readiness = true;
                        write_service_readiness_artifact = true;
                    }
                    "--local-smoke-dry-run" | "--local-compose-smoke" => {
                        set_clickhouse_log_store_mode(
                            &mut explicit_mode,
                            ClickHouseLogStoreMode::DryRun,
                            arg.as_str(),
                        )?;
                        local_smoke = true;
                    }
                    "--write-local-smoke-artifact" => {
                        set_clickhouse_log_store_mode(
                            &mut explicit_mode,
                            ClickHouseLogStoreMode::DryRun,
                            arg.as_str(),
                        )?;
                        local_smoke = true;
                        write_local_smoke_artifact = true;
                    }
                    "--readback" => {
                        set_clickhouse_log_store_mode(
                            &mut explicit_mode,
                            ClickHouseLogStoreMode::DryRun,
                            "--readback",
                        )?;
                        readback = true;
                    }
                    "--write-artifact" | "--write-wal-artifact" => {
                        set_clickhouse_log_store_mode(
                            &mut explicit_mode,
                            ClickHouseLogStoreMode::DryRun,
                            arg.as_str(),
                        )?;
                        readback = true;
                        write_artifact = true;
                    }
                    "--execute" | "--send" | "--production-smoke" => {
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
                readback,
                write_artifact,
                service_readiness,
                write_service_readiness_artifact,
                local_smoke,
                write_local_smoke_artifact,
                production_smoke_artifact_path,
                force,
            })
        }
        "subscription-scheduler" | "subscription-scheduler-worker" => {
            let mut control_plane_base_url = env::var("CONTROL_PLANE_BASE_URL")
                .or_else(|_| env::var("CONTROL_PLANE_ADMIN_BASE_URL"))
                .unwrap_or_else(|_| "http://127.0.0.1:8081".to_string());
            let mut admin_session_token_env = "CONTROL_PLANE_ADMIN_SESSION_TOKEN".to_string();
            let mut tenant_id = DEFAULT_TENANT_ID;
            let mut worker_id = env::var("SUBSCRIPTION_SCHEDULER_WORKER_ID")
                .unwrap_or_else(|_| format!("subscription-scheduler-worker-{}", Uuid::new_v4()));
            let mut limit = 50_i64;
            let mut mode = "dry_run".to_string();
            let mut event_status = "scheduled".to_string();
            let mut event_type = "all".to_string();
            let mut reason = None;
            let mut interval_seconds = None;
            let mut max_runs = Some(1_u64);
            let mut timeout_seconds = 30_u64;

            while let Some(arg) = args.next() {
                match arg.as_str() {
                    "--once" => {
                        interval_seconds = None;
                        max_runs = Some(1);
                    }
                    "--control-plane-url" | "--control-plane-base-url" => {
                        control_plane_base_url = args
                            .next()
                            .ok_or_else(|| format!("{arg} requires a URL value"))?;
                    }
                    "--admin-session-token-env" => {
                        admin_session_token_env = args.next().ok_or_else(|| {
                            "--admin-session-token-env requires an env var name".to_string()
                        })?;
                    }
                    "--tenant-id" => {
                        let raw = args
                            .next()
                            .ok_or_else(|| "--tenant-id requires a UUID value".to_string())?;
                        tenant_id = raw
                            .parse()
                            .map_err(|_| format!("invalid --tenant-id UUID `{raw}`"))?;
                    }
                    "--worker-id" => {
                        worker_id = args
                            .next()
                            .ok_or_else(|| "--worker-id requires a non-empty value".to_string())?;
                        if worker_id.trim().is_empty() {
                            return Err("--worker-id must not be empty".to_string());
                        }
                    }
                    "--limit" => {
                        let raw = args
                            .next()
                            .ok_or_else(|| "--limit requires an integer value".to_string())?;
                        limit = raw
                            .parse::<i64>()
                            .map_err(|_| format!("invalid --limit integer `{raw}`"))?;
                        if limit <= 0 {
                            return Err("--limit must be at least 1".to_string());
                        }
                    }
                    "--mode" => {
                        mode = args.next().ok_or_else(|| {
                            "--mode requires dry_run, apply, refuse, or replay".to_string()
                        })?;
                        validate_subscription_scheduler_mode(&mode)?;
                    }
                    "--event-status" => {
                        event_status = args.next().ok_or_else(|| {
                            "--event-status requires scheduled, replayed, or all".to_string()
                        })?;
                    }
                    "--event-type" => {
                        event_type = args.next().ok_or_else(|| {
                            "--event-type requires all, renew, payment_failed, dunning, expire, or prorate".to_string()
                        })?;
                    }
                    "--reason" => {
                        reason = Some(
                            args.next()
                                .ok_or_else(|| "--reason requires a value".to_string())?,
                        );
                    }
                    "--interval-seconds" => {
                        let raw = args.next().ok_or_else(|| {
                            "--interval-seconds requires an integer value".to_string()
                        })?;
                        let parsed = raw
                            .parse::<u64>()
                            .map_err(|_| format!("invalid --interval-seconds integer `{raw}`"))?;
                        if parsed == 0 {
                            return Err("--interval-seconds must be at least 1".to_string());
                        }
                        interval_seconds = Some(parsed);
                        max_runs = None;
                    }
                    "--max-runs" | "--max-iterations" => {
                        let raw = args
                            .next()
                            .ok_or_else(|| format!("{arg} requires an integer value"))?;
                        let parsed = raw
                            .parse::<u64>()
                            .map_err(|_| format!("invalid {arg} integer `{raw}`"))?;
                        if parsed == 0 {
                            return Err(format!("{arg} must be at least 1"));
                        }
                        max_runs = Some(parsed);
                    }
                    "--timeout-seconds" => {
                        let raw = args.next().ok_or_else(|| {
                            "--timeout-seconds requires an integer value".to_string()
                        })?;
                        timeout_seconds = raw
                            .parse::<u64>()
                            .map_err(|_| format!("invalid --timeout-seconds integer `{raw}`"))?;
                        if timeout_seconds == 0 {
                            return Err("--timeout-seconds must be at least 1".to_string());
                        }
                    }
                    "--help" | "-h" => return Err(usage()),
                    other => {
                        return Err(format!("unknown subscription-scheduler argument `{other}`"));
                    }
                }
            }

            validate_subscription_scheduler_mode(&mode)?;
            if mode != "dry_run" && reason.as_ref().is_none_or(|value| value.trim().is_empty()) {
                reason = Some("subscription scheduler worker command".to_string());
            }

            Ok(WorkerCommand::SubscriptionScheduler {
                control_plane_base_url,
                admin_session_token_env,
                tenant_id,
                worker_id: safe_plan_text(&worker_id),
                limit,
                mode,
                event_status,
                event_type,
                reason: reason.map(|value| safe_plan_text(&value)),
                interval_seconds,
                max_runs,
                timeout_seconds,
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
            "choose either --dry-run/--readback/--write-artifact/--service-readiness or --execute/--send for clickhouse-log-store, not both; `{flag}` conflicts with the existing mode"
        ));
    }

    *explicit_mode = Some(mode);
    Ok(())
}

fn validate_subscription_scheduler_mode(mode: &str) -> Result<(), String> {
    match mode {
        "dry_run" | "apply" | "refuse" | "replay" => Ok(()),
        _ => Err("--mode must be dry_run, apply, refuse, or replay".to_string()),
    }
}

fn usage() -> String {
    "Usage:\n  ai-worker\n  ai-worker recovery-probe [--dry-run|--execute] [--tenant-id <uuid>] [--limit <n>]\n  ai-worker alert-webhook [--dry-run] [--input <json>] [--tenant-id <uuid>]  # emits sender contract, no network send\n  ai-worker alert-webhook --send|--execute [--force]  # refused in this dry-run slice\n  ai-worker billing-reconciliation [--dry-run] --input <json> [--day <YYYY-MM-DD>] [--tenant-id <uuid>] [--project-id <uuid>] [--limit <n>]\n  ai-worker billing-reconciliation --execute|--send [--force]  # refused in this dry-run slice\n  ai-worker prompt-eval-shadow [--dry-run] --input <json> [--tenant-id <uuid>]  # emits prompt registry/eval dataset/shadow traffic plan, no writes or sends\n  ai-worker prompt-eval-shadow --execute|--send [--force]  # refused in this dry-run slice\n  ai-worker clickhouse-log-store [--dry-run|--check-config|--config-readback|--final-dod|--acceptance-matrix|--production-smoke-handoff|--final-closure-audit|--evidence-watcher] [--read-production-smoke-artifact <json>] [--readback] [--write-artifact] [--service-readiness] [--write-service-readiness-artifact] [--local-smoke-dry-run] [--write-local-smoke-artifact] --input <json> [--tenant-id <uuid>]  # emits config guard, local compose smoke prototype, service readiness, production smoke handoff/readback gate, evidence watcher/checklist, final closure audit/DoD matrix, queue/backpressure/dedup/table mapping/WAL readback contract; opt-in artifact writes only repo .tmp artifacts\n  ai-worker clickhouse-log-store --execute|--send|--production-smoke [--force]  # refused in this dry-run slice\n  ai-worker subscription-scheduler [--once] [--control-plane-url <url>] [--admin-session-token-env <env>] [--tenant-id <uuid>] [--worker-id <id>] [--mode dry_run|apply|refuse|replay] [--limit <n>] [--event-status all|scheduled|replayed] [--event-type all|renew|payment_failed|dunning|expire|prorate] [--reason <text>] [--interval-seconds <n>] [--max-runs <n>|--max-iterations <n>] [--timeout-seconds <n>]  # calls run-due and prints JSON/NDJSON supervisor heartbeat/readback"
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
    fn persist_provider_key_recovery_probe<'a>(
        &'a self,
        update: RecoveryProbeProviderKeyUpdate,
    ) -> BoxFuture<'a, Result<bool, String>>;
}

struct HttpRecoveryProbeRunner<'a> {
    repository: &'a DbRepository,
}

impl<'a> HttpRecoveryProbeRunner<'a> {
    fn new(repository: &'a DbRepository) -> Self {
        Self { repository }
    }
}

impl RecoveryProbeRunner for HttpRecoveryProbeRunner<'_> {
    fn probe<'a>(
        &'a self,
        candidate: &'a RecoveryProbeCandidate,
    ) -> BoxFuture<'a, RecoveryProbeCheck> {
        Box::pin(async move { execute_http_recovery_probe(self.repository, candidate).await })
    }
}

impl ProviderKeyStatusWriter for DbRepository {
    fn persist_provider_key_recovery_probe<'a>(
        &'a self,
        update: RecoveryProbeProviderKeyUpdate,
    ) -> BoxFuture<'a, Result<bool, String>> {
        Box::pin(async move {
            DbRepository::update_provider_key_recovery_probe_result(self, update)
                .await
                .map(|updated| updated.is_some())
                .map_err(|error| safe_error_text(&error.to_string()))
        })
    }
}

async fn execute_http_recovery_probe(
    repository: &DbRepository,
    candidate: &RecoveryProbeCandidate,
) -> RecoveryProbeCheck {
    if !candidate
        .channel_protocol_mode
        .eq_ignore_ascii_case("openai_compatible")
    {
        return RecoveryProbeCheck::failure("unsupported_protocol", false);
    }

    let material = match repository
        .get_recovery_probe_secret_material(
            candidate.tenant_id,
            candidate.provider_id,
            candidate.channel_id,
            candidate.provider_key_id,
        )
        .await
    {
        Ok(Some(material)) => material,
        Ok(None) => return RecoveryProbeCheck::failure("secret_material_unavailable", false),
        Err(error) => {
            let _ = safe_error_text(&error.to_string());
            return RecoveryProbeCheck::failure("secret_material_unavailable", false);
        }
    };

    match open_recovery_probe_provider_key(&material) {
        Ok(secret) => {
            let client = match OpenAiCompatibleClient::new_with_timeout(
                material.channel_endpoint,
                Duration::from_secs(RECOVERY_PROBE_TIMEOUT_SECONDS),
            ) {
                Ok(client) => client,
                Err(error) => {
                    return RecoveryProbeCheck::failure(recovery_probe_error_code(&error), false);
                }
            };

            match client
                .models_with_provider_key(Some(secret.expose_secret()))
                .await
            {
                Ok(_) => RecoveryProbeCheck {
                    status: RecoveryProbeCheckStatus::Success,
                    upstream_call: true,
                    error_code: None,
                },
                Err(error) => RecoveryProbeCheck::failure(recovery_probe_error_code(&error), true),
            }
        }
        Err(error_code) => RecoveryProbeCheck::failure(error_code, false),
    }
}

fn open_recovery_probe_provider_key(
    material: &RecoveryProbeSecretMaterial,
) -> Result<ai_gateway_auth::ProviderKeySecret, &'static str> {
    if !material
        .channel_protocol_mode
        .eq_ignore_ascii_case("openai_compatible")
    {
        return Err("unsupported_protocol");
    }

    let master_key = load_recovery_probe_provider_key_master_key()?;
    let sealed = sealed_provider_key_from_payload(&material.encrypted_secret)?;
    let context = ProviderKeyContext::new(
        material.tenant_id.to_string(),
        material.provider_id.to_string(),
        material.provider_key_id.to_string(),
    )
    .map_err(|_| "provider_key_context_invalid")?;

    open_provider_key(&master_key, &context, &sealed).map_err(|_| "provider_key_decrypt_failed")
}

fn load_recovery_probe_provider_key_master_key()
-> Result<[u8; PROVIDER_KEY_MASTER_KEY_LEN], &'static str> {
    let raw = env::var(PROVIDER_KEY_MASTER_KEY_ENV)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .ok_or("provider_key_master_key_not_configured")?;
    let decoded = decode_base64(&raw).map_err(|_| "provider_key_master_key_invalid")?;
    decoded
        .try_into()
        .map_err(|_bytes: Vec<u8>| "provider_key_master_key_invalid")
}

#[derive(Debug, Deserialize)]
struct SealedProviderKeyPayload {
    version: u8,
    algorithm: String,
    master_key_id: String,
    nonce: String,
    ciphertext: String,
}

fn sealed_provider_key_from_payload(
    encrypted_secret: &str,
) -> Result<SealedProviderKey, &'static str> {
    let payload = serde_json::from_str::<SealedProviderKeyPayload>(encrypted_secret)
        .map_err(|_| "provider_key_secret_invalid")?;

    if payload.algorithm != PROVIDER_KEY_ENCRYPTION_ALGORITHM {
        return Err("provider_key_secret_invalid");
    }

    let nonce = hex::decode(payload.nonce).map_err(|_| "provider_key_secret_invalid")?;
    let nonce: [u8; PROVIDER_KEY_NONCE_LEN] = nonce
        .try_into()
        .map_err(|_bytes: Vec<u8>| "provider_key_secret_invalid")?;
    let ciphertext = hex::decode(payload.ciphertext).map_err(|_| "provider_key_secret_invalid")?;

    Ok(SealedProviderKey {
        version: payload.version,
        master_key_id: payload.master_key_id,
        nonce,
        ciphertext,
    })
}

fn recovery_probe_error_code(error: &OpenAiAdapterError) -> &'static str {
    match error {
        OpenAiAdapterError::InvalidUpstreamBaseUrl(_) => "invalid_upstream_base_url",
        OpenAiAdapterError::ProviderAuthorizationInvalid => "provider_authorization_invalid",
        OpenAiAdapterError::UpstreamTimeout => "provider_timeout",
        OpenAiAdapterError::UpstreamStatus {
            status: 401 | 403, ..
        } => "provider_auth_failed",
        OpenAiAdapterError::UpstreamStatus { status: 429, .. } => "provider_rate_limited",
        OpenAiAdapterError::UpstreamStatus { status, .. } if *status >= 500 => "provider_5xx",
        OpenAiAdapterError::UpstreamConnect(_)
        | OpenAiAdapterError::UpstreamRequest(_)
        | OpenAiAdapterError::UpstreamRead(_)
        | OpenAiAdapterError::UpstreamInvalidJson { .. }
        | OpenAiAdapterError::HttpClient(_) => "provider_probe_failed",
        OpenAiAdapterError::InvalidJson(_)
        | OpenAiAdapterError::InvalidRequest { .. }
        | OpenAiAdapterError::RequestSerialize(_)
        | OpenAiAdapterError::StreamingNotImplemented
        | OpenAiAdapterError::UpstreamStatus { .. } => "provider_probe_failed",
    }
}

fn decode_base64(raw: &str) -> Result<Vec<u8>, ()> {
    let bytes = raw
        .bytes()
        .filter(|byte| !byte.is_ascii_whitespace())
        .collect::<Vec<_>>();
    if bytes.is_empty() || bytes.len() % 4 != 0 {
        return Err(());
    }

    let mut output = Vec::with_capacity(bytes.len() / 4 * 3);
    let chunk_count = bytes.len() / 4;
    for (index, chunk) in bytes.chunks_exact(4).enumerate() {
        let is_last = index + 1 == chunk_count;
        let padding = chunk.iter().rev().take_while(|byte| **byte == b'=').count();
        if padding > 2 || (padding > 0 && !is_last) || chunk[0] == b'=' || chunk[1] == b'=' {
            return Err(());
        }
        if padding == 1 && chunk[2] == b'=' {
            return Err(());
        }
        if padding == 2 && chunk[2] != b'=' {
            return Err(());
        }

        let b0 = base64_value(chunk[0])?;
        let b1 = base64_value(chunk[1])?;
        output.push((b0 << 2) | (b1 >> 4));

        if padding < 2 {
            let b2 = base64_value(chunk[2])?;
            output.push((b1 << 4) | (b2 >> 2));

            if padding == 0 {
                let b3 = base64_value(chunk[3])?;
                output.push((b2 << 6) | b3);
            }
        }
    }

    Ok(output)
}

fn base64_value(byte: u8) -> Result<u8, ()> {
    match byte {
        b'A'..=b'Z' => Ok(byte - b'A'),
        b'a'..=b'z' => Ok(byte - b'a' + 26),
        b'0'..=b'9' => Ok(byte - b'0' + 52),
        b'+' => Ok(62),
        b'/' => Ok(63),
        _ => Err(()),
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

        let status_update_attempted = transition.update_required;
        let mut status_update_applied = false;
        let mut status_update_error = None;

        let persistence_update =
            recovery_probe_provider_key_update(&candidate, &check, &transition);
        match status_writer
            .persist_provider_key_recovery_probe(persistence_update)
            .await
        {
            Ok(applied) => {
                if transition.update_required {
                    status_update_applied = applied;
                    if applied {
                        migration_applied_count += 1;
                    }
                }
            }
            Err(error) => {
                migration_error_count += 1;
                status_update_error = Some(safe_error_text(&error));
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

fn recovery_probe_provider_key_update(
    candidate: &RecoveryProbeCandidate,
    check: &RecoveryProbeCheck,
    transition: &RecoveryProbeTransition,
) -> RecoveryProbeProviderKeyUpdate {
    let last_error_code = check.error_code.as_deref().map(safe_error_text);

    RecoveryProbeProviderKeyUpdate {
        tenant_id: candidate.tenant_id,
        provider_key_id: candidate.provider_key_id,
        status: transition.to_status.clone(),
        health_score: recovery_probe_health_score(candidate, check),
        last_error_code: last_error_code.clone(),
        recovery_probe_summary: json!({
            "result": check.result_label(),
            "error_code": last_error_code,
            "upstream_call": check.upstream_call,
            "from_status": safe_plan_text(&transition.from_status),
            "to_status": safe_plan_text(&transition.to_status),
        }),
    }
}

fn recovery_probe_health_score(
    candidate: &RecoveryProbeCandidate,
    check: &RecoveryProbeCheck,
) -> f64 {
    if check.is_success() {
        1.0
    } else {
        candidate.provider_key_health_score.clamp(0.0, 0.25)
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
    fn subscription_scheduler_accepts_max_iterations_alias() {
        let command = parse_command([
            "ai-worker".to_string(),
            "subscription-scheduler".to_string(),
            "--worker-id".to_string(),
            "scheduler-worker-a".to_string(),
            "--interval-seconds".to_string(),
            "5".to_string(),
            "--max-iterations".to_string(),
            "3".to_string(),
        ])
        .expect("subscription scheduler command should parse");

        assert_eq!(
            command,
            WorkerCommand::SubscriptionScheduler {
                control_plane_base_url: "http://127.0.0.1:8081".to_string(),
                admin_session_token_env: "CONTROL_PLANE_ADMIN_SESSION_TOKEN".to_string(),
                tenant_id: DEFAULT_TENANT_ID,
                worker_id: "scheduler-worker-a".to_string(),
                limit: 50,
                mode: "dry_run".to_string(),
                event_status: "scheduled".to_string(),
                event_type: "all".to_string(),
                reason: None,
                interval_seconds: Some(5),
                max_runs: Some(3),
                timeout_seconds: 30,
            }
        );
    }

    #[test]
    fn subscription_scheduler_error_backoff_is_bounded() {
        assert_eq!(subscription_scheduler_backoff_seconds(10, 1), 10);
        assert_eq!(subscription_scheduler_backoff_seconds(10, 3), 40);
        assert_eq!(
            subscription_scheduler_backoff_seconds(120, 8),
            SUBSCRIPTION_SCHEDULER_MAX_BACKOFF_SECONDS
        );
    }

    #[test]
    fn subscription_scheduler_provider_handoff_summary_is_secret_safe_counts_only() {
        let summary = subscription_scheduler_provider_executor_handoff_summary(&json!({
            "data": {
                "processed": [
                    {
                        "event": {
                            "payment_capture_handoff": {
                                "ready_for_provider_executor": false,
                                "blocked_reasons": [
                                    "provider_payment_intent_ref_missing",
                                    "network_disabled"
                                ],
                                "provider_refs": {
                                    "provider_object_ref_present": false,
                                    "provider_object_ref_raw_echoed": false,
                                    "raw_ref": "pi_secret_should_not_escape"
                                },
                                "payment_capture_executed": false,
                                "authorization": "secret_should_not_escape",
                                "raw_provider_payload": {"secret": true}
                            }
                        }
                    },
                    {
                        "payment_provider_executor_handoff": {
                            "ready_for_provider_executor": false,
                            "blocked_reasons": ["provider_payment_intent_ref_missing"],
                            "provider_refs": {
                                "provider_object_ref_present": true
                            },
                            "payment_capture_executed": false
                        }
                    }
                ],
                "skipped": [],
                "blocked": []
            }
        }));

        assert_eq!(summary["handoff_count"], json!(2));
        assert_eq!(summary["ready_for_provider_executor_count"], json!(0));
        assert_eq!(summary["not_ready_for_provider_executor_count"], json!(2));
        assert_eq!(
            summary["blocked_reason_counts"]["provider_payment_intent_ref_missing"],
            json!(2)
        );
        assert_eq!(
            summary["blocked_reason_counts"]["network_disabled"],
            json!(1)
        );
        assert_eq!(
            summary["provider_object_ref_present_counts"],
            json!({"present": 1, "missing": 1, "unknown": 0})
        );
        assert_eq!(summary["payment_capture_executed"], json!(false));
        assert_eq!(summary["payment_capture_executed_false_count"], json!(2));
        assert_eq!(summary["payment_capture_executed_all_false"], json!(true));
        assert_eq!(summary["authorization_returned"], json!(false));
        assert_eq!(summary["raw_payload_returned"], json!(false));
        assert!(!summary.to_string().contains("secret_should_not_escape"));
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
                readback: false,
                write_artifact: false,
                service_readiness: false,
                write_service_readiness_artifact: false,
                local_smoke: false,
                write_local_smoke_artifact: false,
                production_smoke_artifact_path: None,
                force: false,
            }
        );
    }

    #[test]
    fn clickhouse_log_store_readback_is_dry_run_mode() {
        let command = parse_command([
            "ai-worker".to_string(),
            "clickhouse-log-store".to_string(),
            "--dry-run".to_string(),
            "--readback".to_string(),
            "--input".to_string(),
            "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string(),
        ])
        .expect("ClickHouse log store readback command should parse");

        assert_eq!(
            command,
            WorkerCommand::ClickHouseLogStore {
                mode: ClickHouseLogStoreMode::DryRun,
                tenant_id: None,
                input_path: Some(
                    "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string()
                ),
                readback: true,
                write_artifact: false,
                service_readiness: false,
                write_service_readiness_artifact: false,
                local_smoke: false,
                write_local_smoke_artifact: false,
                production_smoke_artifact_path: None,
                force: false,
            }
        );
    }

    #[test]
    fn clickhouse_log_store_config_readback_is_plan_only_dry_run_mode() {
        let command = parse_command([
            "ai-worker".to_string(),
            "clickhouse-log-store".to_string(),
            "--config-readback".to_string(),
            "--input".to_string(),
            "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string(),
        ])
        .expect("ClickHouse log store config readback command should parse");

        assert_eq!(
            command,
            WorkerCommand::ClickHouseLogStore {
                mode: ClickHouseLogStoreMode::DryRun,
                tenant_id: None,
                input_path: Some(
                    "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string()
                ),
                readback: false,
                write_artifact: false,
                service_readiness: false,
                write_service_readiness_artifact: false,
                local_smoke: false,
                write_local_smoke_artifact: false,
                production_smoke_artifact_path: None,
                force: false,
            }
        );
    }

    #[test]
    fn clickhouse_log_store_final_dod_is_plan_only_dry_run_mode() {
        let command = parse_command([
            "ai-worker".to_string(),
            "clickhouse-log-store".to_string(),
            "--final-dod".to_string(),
            "--input".to_string(),
            "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string(),
        ])
        .expect("ClickHouse log store final DoD command should parse");

        assert_eq!(
            command,
            WorkerCommand::ClickHouseLogStore {
                mode: ClickHouseLogStoreMode::DryRun,
                tenant_id: None,
                input_path: Some(
                    "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string()
                ),
                readback: false,
                write_artifact: false,
                service_readiness: false,
                write_service_readiness_artifact: false,
                local_smoke: false,
                write_local_smoke_artifact: false,
                production_smoke_artifact_path: None,
                force: false,
            }
        );
    }

    #[test]
    fn clickhouse_log_store_production_smoke_handoff_is_plan_only_dry_run_mode() {
        let command = parse_command([
            "ai-worker".to_string(),
            "clickhouse-log-store".to_string(),
            "--production-smoke-handoff".to_string(),
            "--input".to_string(),
            "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string(),
        ])
        .expect("ClickHouse log store production smoke handoff command should parse");

        assert_eq!(
            command,
            WorkerCommand::ClickHouseLogStore {
                mode: ClickHouseLogStoreMode::DryRun,
                tenant_id: None,
                input_path: Some(
                    "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string()
                ),
                readback: false,
                write_artifact: false,
                service_readiness: false,
                write_service_readiness_artifact: false,
                local_smoke: false,
                write_local_smoke_artifact: false,
                production_smoke_artifact_path: None,
                force: false,
            }
        );
    }

    #[test]
    fn clickhouse_log_store_final_closure_audit_is_plan_only_dry_run_mode() {
        let command = parse_command([
            "ai-worker".to_string(),
            "clickhouse-log-store".to_string(),
            "--final-closure-audit".to_string(),
            "--input".to_string(),
            "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string(),
        ])
        .expect("ClickHouse log store final closure audit command should parse");

        assert_eq!(
            command,
            WorkerCommand::ClickHouseLogStore {
                mode: ClickHouseLogStoreMode::DryRun,
                tenant_id: None,
                input_path: Some(
                    "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string()
                ),
                readback: false,
                write_artifact: false,
                service_readiness: false,
                write_service_readiness_artifact: false,
                local_smoke: false,
                write_local_smoke_artifact: false,
                production_smoke_artifact_path: None,
                force: false,
            }
        );
    }

    #[test]
    fn clickhouse_log_store_evidence_watcher_is_plan_only_dry_run_mode() {
        let command = parse_command([
            "ai-worker".to_string(),
            "clickhouse-log-store".to_string(),
            "--evidence-watcher".to_string(),
            "--input".to_string(),
            "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string(),
        ])
        .expect("ClickHouse log store evidence watcher command should parse");

        assert_eq!(
            command,
            WorkerCommand::ClickHouseLogStore {
                mode: ClickHouseLogStoreMode::DryRun,
                tenant_id: None,
                input_path: Some(
                    "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string()
                ),
                readback: false,
                write_artifact: false,
                service_readiness: false,
                write_service_readiness_artifact: false,
                local_smoke: false,
                write_local_smoke_artifact: false,
                production_smoke_artifact_path: None,
                force: false,
            }
        );
    }

    #[test]
    fn clickhouse_log_store_production_smoke_artifact_readback_is_plan_only_dry_run_mode() {
        let command = parse_command([
            "ai-worker".to_string(),
            "clickhouse-log-store".to_string(),
            "--read-production-smoke-artifact".to_string(),
            "tests/fixtures/worker/clickhouse_production_smoke_artifact_accepted_simulation.json"
                .to_string(),
            "--input".to_string(),
            "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string(),
        ])
        .expect("ClickHouse log store production smoke artifact readback should parse");

        assert_eq!(
            command,
            WorkerCommand::ClickHouseLogStore {
                mode: ClickHouseLogStoreMode::DryRun,
                tenant_id: None,
                input_path: Some(
                    "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string()
                ),
                readback: false,
                write_artifact: false,
                service_readiness: false,
                write_service_readiness_artifact: false,
                local_smoke: false,
                write_local_smoke_artifact: false,
                production_smoke_artifact_path: Some(
                    "tests/fixtures/worker/clickhouse_production_smoke_artifact_accepted_simulation.json".to_string()
                ),
                force: false,
            }
        );
    }

    #[test]
    fn clickhouse_log_store_service_readiness_is_plan_only_dry_run_mode() {
        let command = parse_command([
            "ai-worker".to_string(),
            "clickhouse-log-store".to_string(),
            "--service-readiness".to_string(),
            "--input".to_string(),
            "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string(),
        ])
        .expect("ClickHouse log store service readiness command should parse");

        assert_eq!(
            command,
            WorkerCommand::ClickHouseLogStore {
                mode: ClickHouseLogStoreMode::DryRun,
                tenant_id: None,
                input_path: Some(
                    "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string()
                ),
                readback: false,
                write_artifact: false,
                service_readiness: true,
                write_service_readiness_artifact: false,
                local_smoke: false,
                write_local_smoke_artifact: false,
                production_smoke_artifact_path: None,
                force: false,
            }
        );
    }

    #[test]
    fn clickhouse_log_store_service_readiness_artifact_requires_explicit_opt_in() {
        let command = parse_command([
            "ai-worker".to_string(),
            "clickhouse-log-store".to_string(),
            "--write-service-readiness-artifact".to_string(),
            "--input".to_string(),
            "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string(),
        ])
        .expect("ClickHouse log store service readiness artifact command should parse");

        assert_eq!(
            command,
            WorkerCommand::ClickHouseLogStore {
                mode: ClickHouseLogStoreMode::DryRun,
                tenant_id: None,
                input_path: Some(
                    "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string()
                ),
                readback: false,
                write_artifact: false,
                service_readiness: true,
                write_service_readiness_artifact: true,
                local_smoke: false,
                write_local_smoke_artifact: false,
                production_smoke_artifact_path: None,
                force: false,
            }
        );
    }

    #[test]
    fn clickhouse_log_store_write_artifact_is_explicit_dry_run_mode() {
        let command = parse_command([
            "ai-worker".to_string(),
            "clickhouse-log-store".to_string(),
            "--write-artifact".to_string(),
            "--input".to_string(),
            "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string(),
        ])
        .expect("ClickHouse log store artifact writer command should parse");

        assert_eq!(
            command,
            WorkerCommand::ClickHouseLogStore {
                mode: ClickHouseLogStoreMode::DryRun,
                tenant_id: None,
                input_path: Some(
                    "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string()
                ),
                readback: true,
                write_artifact: true,
                service_readiness: false,
                write_service_readiness_artifact: false,
                local_smoke: false,
                write_local_smoke_artifact: false,
                production_smoke_artifact_path: None,
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
                readback: false,
                write_artifact: false,
                service_readiness: false,
                write_service_readiness_artifact: false,
                local_smoke: false,
                write_local_smoke_artifact: false,
                production_smoke_artifact_path: None,
                force: true,
            }
        );
        assert!(clickhouse_log_store_execute_error(true).contains("ClickHouse write"));
    }

    #[test]
    fn clickhouse_log_store_production_smoke_is_execute_refusal_mode() {
        let command = parse_command([
            "ai-worker".to_string(),
            "clickhouse-log-store".to_string(),
            "--production-smoke".to_string(),
            "--force".to_string(),
        ])
        .expect("production smoke mode should parse before runtime refusal");

        assert_eq!(
            command,
            WorkerCommand::ClickHouseLogStore {
                mode: ClickHouseLogStoreMode::Execute,
                tenant_id: None,
                input_path: None,
                readback: false,
                write_artifact: false,
                service_readiness: false,
                write_service_readiness_artifact: false,
                local_smoke: false,
                write_local_smoke_artifact: false,
                production_smoke_artifact_path: None,
                force: true,
            }
        );
        assert!(clickhouse_log_store_execute_error(true).contains("network request"));
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

        assert!(error.contains(
            "either --dry-run/--readback/--write-artifact/--service-readiness or --execute/--send"
        ));
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
        assert_eq!(status_writer.persists().len(), 1);
        assert_eq!(status_writer.persists()[0].last_error_code, None);
        assert_eq!(status_writer.persists()[0].health_score, 1.0);
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
        let persists = status_writer.persists();
        assert_eq!(persists.len(), 1);
        assert_eq!(persists[0].status, "cooldown");
        assert_eq!(persists[0].health_score, 0.25);
        let persisted_error = persists[0]
            .last_error_code
            .as_deref()
            .expect("failure should persist error code");
        assert!(persisted_error.contains("[REDACTED]"));
        assert!(!persisted_error.contains(&raw_provider_secret));
        assert!(!persisted_error.contains(&raw_fingerprint));
        assert!(!persisted_error.contains(&raw_encrypted_secret));
        assert_eq!(
            persists[0].recovery_probe_summary["result"].as_str(),
            Some("failure")
        );
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
        persists: Mutex<Vec<RecoveryProbeProviderKeyUpdate>>,
        updates: Mutex<Vec<(Uuid, Uuid, String)>>,
        error: Option<String>,
        errors_by_id: HashMap<Uuid, String>,
    }

    impl MockProviderKeyStatusWriter {
        fn failing(error: impl Into<String>) -> Self {
            Self {
                persists: Mutex::new(Vec::new()),
                updates: Mutex::new(Vec::new()),
                error: Some(error.into()),
                errors_by_id: HashMap::new(),
            }
        }

        fn failing_for(provider_key_id: Uuid, error: impl Into<String>) -> Self {
            Self {
                persists: Mutex::new(Vec::new()),
                updates: Mutex::new(Vec::new()),
                error: None,
                errors_by_id: HashMap::from([(provider_key_id, error.into())]),
            }
        }

        fn updates(&self) -> Vec<(Uuid, Uuid, String)> {
            self.updates.lock().expect("updates lock").clone()
        }

        fn persists(&self) -> Vec<RecoveryProbeProviderKeyUpdate> {
            self.persists.lock().expect("persists lock").clone()
        }
    }

    impl ProviderKeyStatusWriter for MockProviderKeyStatusWriter {
        fn persist_provider_key_recovery_probe<'a>(
            &'a self,
            update: RecoveryProbeProviderKeyUpdate,
        ) -> BoxFuture<'a, Result<bool, String>> {
            let provider_key_id = update.provider_key_id;
            let error = self
                .errors_by_id
                .get(&provider_key_id)
                .or(self.error.as_ref());
            let result = if let Some(error) = error {
                Err(error.clone())
            } else {
                if update.status == "enabled" {
                    self.updates.lock().expect("updates lock").push((
                        update.tenant_id,
                        provider_key_id,
                        update.status.clone(),
                    ));
                }
                self.persists.lock().expect("persists lock").push(update);
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
