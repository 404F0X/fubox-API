use ai_gateway_observability::{
    CLICKHOUSE_LOG_STORE_CONTRACT_VERSION, ClickHouseLogStoreConfig,
    clickhouse_log_store::{
        CLICKHOUSE_WAL_DRY_RUN_READBACK_CONTRACT_VERSION, clickhouse_wal_dry_run_readback_contract,
    },
    payload_sha256_hex,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    fs::{self, File},
    io::Write,
    path::{Path, PathBuf},
};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ClickHouseLogStoreMode {
    DryRun,
    Execute,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ClickHouseLogStoreInputSource {
    InputJson { path: String },
}

#[derive(Debug, Clone, Default, Deserialize)]
pub(crate) struct ClickHouseLogStoreInput {
    #[serde(default)]
    tenant_id: Option<Uuid>,
    #[serde(default, alias = "config_env", alias = "clickhouse_env")]
    env: BTreeMap<String, String>,
    #[serde(
        default,
        alias = "wal_readback",
        alias = "wal_dry_run",
        alias = "wal_writer_dry_run"
    )]
    wal_dry_run_readback: Option<Value>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub(crate) struct ClickHouseLogStoreWorkerPlan {
    schema_version: &'static str,
    dry_run: bool,
    mode: &'static str,
    read_only: bool,
    runtime_connected: bool,
    db_reads: bool,
    db_writes: bool,
    queue_writes: bool,
    file_system_writes: bool,
    outbound_calls: bool,
    network_requests: bool,
    tenant_id: Uuid,
    source: ClickHouseLogStoreSourceReport,
    clickhouse_config: Value,
    ingestion: ClickHouseIngestionPlan,
    queue: ClickHouseQueuePlan,
    durable_queue: ClickHouseDurableQueuePlan,
    wal_service_guard: Value,
    wal_dry_run_readback: Value,
    wal_runtime_writer: Value,
    wal_service_execution: Value,
    local_compose_wire_up: Value,
    local_smoke_prototype: Value,
    dev_writer_send_contract: Value,
    final_dod_matrix: Value,
    production_smoke_handoff: Value,
    production_smoke_acceptance: Value,
    final_closure_audit: Value,
    production_smoke_evidence_watcher: Value,
    backpressure: ClickHouseBackpressurePlan,
    dedup: ClickHouseDedupPlan,
    table_mapping: Vec<ClickHouseTableMappingPlan>,
    contract: ClickHouseWorkerContractReport,
    remaining_gaps: Vec<&'static str>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct ClickHouseLogStoreSourceReport {
    kind: &'static str,
    input_path: String,
    env_key_count: usize,
    env_values_output: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct ClickHouseIngestionPlan {
    enabled: bool,
    source_streams: Vec<&'static str>,
    execute_supported: bool,
    send_supported: bool,
    writer_supported: bool,
    queue_write_supported: bool,
    payload_body_output: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct ClickHouseQueuePlan {
    queue_type: &'static str,
    max_queue_rows: u64,
    batch_size: u64,
    flush_interval_ms: u64,
    enqueue_when_disabled: bool,
    bounded_memory: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct ClickHouseDurableQueuePlan {
    queue_type: &'static str,
    planned: bool,
    enabled_in_this_slice: bool,
    execute_supported: bool,
    file_system_writes: bool,
    wal_directory: ClickHouseWalDirectoryPlan,
    wal_record_shape: ClickHouseWalRecordShapePlan,
    disk_budget: ClickHouseWalDiskBudgetPlan,
    enqueue: ClickHouseQueueOperationPlan,
    dequeue: ClickHouseQueueOperationPlan,
    ack: ClickHouseQueueOperationPlan,
    retry: ClickHouseQueueRetryPlan,
    retention: ClickHouseWalRetentionPlan,
    load_safety: ClickHouseWalLoadSafetyPlan,
    dedup_journal_linkage: ClickHouseWalDedupJournalPlan,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct ClickHouseWalDirectoryPlan {
    root: &'static str,
    tenant_partition: String,
    segment_pattern: &'static str,
    checkpoint_file: &'static str,
    creates_directories: bool,
    writes_files: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct ClickHouseWalRecordShapePlan {
    encoding: &'static str,
    status_values: Vec<&'static str>,
    fields: Vec<&'static str>,
    payload_body_written: bool,
    credential_material_written: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct ClickHouseWalDiskBudgetPlan {
    bounded_disk: bool,
    max_bytes: u64,
    max_segment_bytes: u64,
    max_segments: u64,
    max_unacked_records: u64,
    overflow_action: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct ClickHouseQueueOperationPlan {
    operation: &'static str,
    idempotency_key_fields: Vec<&'static str>,
    status_from: Vec<&'static str>,
    status_to: &'static str,
    transaction_boundary: &'static str,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct ClickHouseQueueRetryPlan {
    idempotency_key_fields: Vec<&'static str>,
    max_attempts: u64,
    initial_backoff_ms: u64,
    max_backoff_ms: u64,
    retry_status: &'static str,
    exhausted_status: &'static str,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct ClickHouseWalRetentionPlan {
    delete_acked_segments_after_seconds: u64,
    delete_failed_segments_after_seconds: u64,
    checkpoint_after_acked_records: u64,
    requires_no_pending_records_before_segment_delete: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct ClickHouseWalLoadSafetyPlan {
    replay_order: &'static str,
    max_replay_batch_rows: u64,
    max_replay_bytes: u64,
    single_consumer_lock: &'static str,
    replay_requires_dedup_journal_check: bool,
    payload_policy_enforced_before_enqueue: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct ClickHouseWalDedupJournalPlan {
    journal_relation: &'static str,
    journal_key_fields: Vec<&'static str>,
    wal_link_fields: Vec<&'static str>,
    conflict_action: &'static str,
    payload_hash_mismatch_action: &'static str,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct ClickHouseBackpressurePlan {
    enabled: bool,
    max_queue_rows: u64,
    drop_policy: String,
    overflow_action: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct ClickHouseDedupPlan {
    enabled: bool,
    strategy: &'static str,
    key_material: &'static str,
    conflict_action: &'static str,
    per_sink_keys: Vec<ClickHouseDedupKeyPlan>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct ClickHouseDedupKeyPlan {
    sink: String,
    key_fields: Vec<&'static str>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct ClickHouseTableMappingPlan {
    sink: String,
    source_relation: String,
    target_database: String,
    target_table: String,
    qualified_target_table: String,
    schema_version: u64,
    enabled: bool,
    dedup_key_fields: Vec<&'static str>,
    payload_policy: Value,
    payload_body_written: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct ClickHouseWorkerContractReport {
    observability_contract: &'static str,
    stable_fields: Vec<&'static str>,
    config_validated_by_observability_crate: bool,
    network_requests_disabled: bool,
    db_reads_disabled: bool,
    db_writes_disabled: bool,
    queue_writes_disabled: bool,
    file_system_writes_disabled: bool,
    queue_plan_only: bool,
    credential_material_omitted: bool,
    env_values_omitted: bool,
    payload_body_omitted: bool,
}

pub(crate) fn read_clickhouse_log_store_input(
    input_path: Option<&str>,
) -> Result<(ClickHouseLogStoreInputSource, ClickHouseLogStoreInput), String> {
    let Some(path) = input_path else {
        return Err(
            "clickhouse-log-store dry-run requires --input <json>; DB/ClickHouse reads are future work"
                .to_string(),
        );
    };

    let body = fs::read_to_string(path).map_err(|error| {
        format!(
            "failed to read ClickHouse log store input `{}`: {}",
            super::safe_plan_text(path),
            super::safe_error_text(&error.to_string())
        )
    })?;
    let input = clickhouse_log_store_input_from_json_str(&body)?;

    Ok((
        ClickHouseLogStoreInputSource::InputJson {
            path: path.to_string(),
        },
        input,
    ))
}

pub(crate) fn clickhouse_log_store_input_from_json_str(
    body: &str,
) -> Result<ClickHouseLogStoreInput, String> {
    let value = serde_json::from_str::<Value>(body).map_err(|error| {
        format!(
            "ClickHouse log store input must be valid JSON: {}",
            super::safe_error_text(&error.to_string())
        )
    })?;
    let input = value.get("input").cloned().unwrap_or(value);
    serde_json::from_value::<ClickHouseLogStoreInput>(input).map_err(|error| {
        format!(
            "ClickHouse log store input shape is invalid: {}",
            super::safe_error_text(&error.to_string())
        )
    })
}

pub(crate) fn clickhouse_log_store_plan(
    tenant_id_override: Option<Uuid>,
    source: ClickHouseLogStoreInputSource,
    input: ClickHouseLogStoreInput,
) -> Result<ClickHouseLogStoreWorkerPlan, String> {
    clickhouse_log_store_plan_with_readback(tenant_id_override, source, input, false)
}

pub(crate) fn clickhouse_log_store_plan_with_readback(
    tenant_id_override: Option<Uuid>,
    source: ClickHouseLogStoreInputSource,
    input: ClickHouseLogStoreInput,
    readback_requested: bool,
) -> Result<ClickHouseLogStoreWorkerPlan, String> {
    clickhouse_log_store_plan_with_runtime_wal(
        tenant_id_override,
        source,
        input,
        readback_requested,
        false,
    )
}

pub(crate) fn clickhouse_log_store_plan_with_runtime_wal(
    tenant_id_override: Option<Uuid>,
    source: ClickHouseLogStoreInputSource,
    input: ClickHouseLogStoreInput,
    readback_requested: bool,
    runtime_write_opt_in: bool,
) -> Result<ClickHouseLogStoreWorkerPlan, String> {
    clickhouse_log_store_plan_with_service_readiness(
        tenant_id_override,
        source,
        input,
        readback_requested,
        runtime_write_opt_in,
        false,
        false,
        false,
        false,
        false,
        false,
        None,
    )
}

pub(crate) fn clickhouse_log_store_plan_with_service_readiness(
    tenant_id_override: Option<Uuid>,
    source: ClickHouseLogStoreInputSource,
    input: ClickHouseLogStoreInput,
    readback_requested: bool,
    runtime_write_opt_in: bool,
    service_readiness_requested: bool,
    service_readiness_artifact_opt_in: bool,
    local_smoke_requested: bool,
    local_smoke_artifact_opt_in: bool,
    dev_writer_requested: bool,
    dev_writer_artifact_opt_in: bool,
    production_smoke_artifact_path: Option<String>,
) -> Result<ClickHouseLogStoreWorkerPlan, String> {
    let env_key_count = input.env.len();
    let tenant_id = tenant_id_override
        .or(input.tenant_id)
        .unwrap_or(super::DEFAULT_TENANT_ID);
    let wal_dry_run_input = input.wal_dry_run_readback.clone();
    let production_smoke_artifact_path = production_smoke_artifact_path.or_else(|| {
        input
            .env
            .get("AI_GATEWAY_CLICKHOUSE_PRODUCTION_SMOKE_ARTIFACT_PATH")
            .or_else(|| {
                input
                    .env
                    .get("AI_GATEWAY_CLICKHOUSE_LOG_STORE_SMOKE_ARTIFACT_PATH")
            })
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
    });
    let source = match source {
        ClickHouseLogStoreInputSource::InputJson { path } => ClickHouseLogStoreSourceReport {
            kind: "input_json",
            input_path: super::safe_plan_text(&path),
            env_key_count,
            env_values_output: false,
        },
    };
    let config = ClickHouseLogStoreConfig::from_env_vars(input.env)
        .map_err(|error| super::safe_error_text(&error.to_string()))?;
    let clickhouse_config = config.write_plan().to_contract_json();
    let wal_service_guard = clickhouse_config
        .get("wal_service_guard")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let enabled = bool_at(&clickhouse_config, "enabled");
    let batch_size = u64_at(&clickhouse_config, "batch_size");
    let flush_interval_ms = u64_at(&clickhouse_config, "flush_interval_ms");
    let retry_max_attempts = u64_nested_at(&clickhouse_config, "retry", "max_attempts").max(1);
    let retry_initial_backoff_ms = u64_nested_at(&clickhouse_config, "retry", "initial_backoff_ms");
    let retry_max_backoff_ms = u64_nested_at(&clickhouse_config, "retry", "max_backoff_ms");
    let max_queue_rows = u64_nested_at(&clickhouse_config, "backpressure", "max_queue_rows");
    let drop_policy = string_nested_at(&clickhouse_config, "backpressure", "drop_policy")
        .unwrap_or_else(|| "drop_newest".to_string());
    let table_mapping = table_mapping_from_config(&clickhouse_config);
    let durable_queue = durable_queue_plan(
        tenant_id,
        max_queue_rows,
        batch_size,
        retry_max_attempts,
        retry_initial_backoff_ms,
        retry_max_backoff_ms,
        drop_policy_to_overflow_action(&drop_policy),
    );
    let wal_dry_run_readback = wal_dry_run_readback_plan(
        readback_requested,
        wal_dry_run_input,
        tenant_id,
        &durable_queue,
    )?;
    let wal_runtime_writer = wal_runtime_writer_plan(runtime_write_opt_in, &wal_dry_run_readback)?;
    let wal_service_execution = wal_service_execution_dry_run_plan(
        service_readiness_requested || service_readiness_artifact_opt_in,
        service_readiness_artifact_opt_in,
        tenant_id,
        &wal_service_guard,
    )?;
    let local_compose_wire_up =
        clickhouse_local_compose_wire_up(&clickhouse_config, &wal_service_guard);
    let local_smoke_prototype = clickhouse_local_smoke_prototype_plan(
        local_smoke_requested || local_smoke_artifact_opt_in,
        local_smoke_artifact_opt_in,
        tenant_id,
        &wal_dry_run_readback,
        &local_compose_wire_up,
    )?;
    let dev_writer_send_contract = clickhouse_dev_writer_send_contract_plan(
        dev_writer_requested || dev_writer_artifact_opt_in,
        dev_writer_artifact_opt_in,
        tenant_id,
        &wal_dry_run_readback,
        &local_compose_wire_up,
    )?;
    let final_dod_matrix = clickhouse_final_dod_matrix(&wal_service_guard);
    let production_smoke_handoff =
        clickhouse_production_smoke_handoff(&clickhouse_config, &wal_service_guard);
    let production_smoke_acceptance =
        production_smoke_artifact_acceptance(production_smoke_artifact_path.as_deref());
    let final_closure_audit =
        clickhouse_final_closure_audit(&production_smoke_handoff, &production_smoke_acceptance);
    let production_smoke_evidence_watcher =
        clickhouse_production_smoke_evidence_watcher(&production_smoke_handoff);

    Ok(ClickHouseLogStoreWorkerPlan {
        schema_version: "clickhouse_log_store_worker_plan.v1",
        dry_run: true,
        mode: if runtime_write_opt_in {
            "runtime_wal_artifact"
        } else if service_readiness_artifact_opt_in {
            "wal_service_readiness_artifact"
        } else if local_smoke_artifact_opt_in {
            "local_smoke_artifact"
        } else if local_smoke_requested {
            "local_smoke_dry_run"
        } else if dev_writer_artifact_opt_in {
            "dev_writer_artifact"
        } else if dev_writer_requested {
            "dev_writer_dry_run"
        } else if service_readiness_requested {
            "wal_service_readiness"
        } else if readback_requested {
            "dry_run_readback"
        } else {
            "plan_only"
        },
        read_only: true,
        runtime_connected: false,
        db_reads: false,
        db_writes: false,
        queue_writes: false,
        file_system_writes: runtime_write_opt_in
            || service_readiness_artifact_opt_in
            || local_smoke_artifact_opt_in
            || dev_writer_artifact_opt_in,
        outbound_calls: false,
        network_requests: false,
        tenant_id,
        source,
        clickhouse_config,
        ingestion: ClickHouseIngestionPlan {
            enabled,
            source_streams: vec!["request_logs", "provider_attempts", "event_log"],
            execute_supported: false,
            send_supported: false,
            writer_supported: false,
            queue_write_supported: false,
            payload_body_output: false,
        },
        queue: ClickHouseQueuePlan {
            queue_type: "bounded_in_memory_future",
            max_queue_rows,
            batch_size,
            flush_interval_ms,
            enqueue_when_disabled: false,
            bounded_memory: true,
        },
        durable_queue,
        wal_service_guard,
        wal_dry_run_readback,
        wal_runtime_writer,
        wal_service_execution,
        local_compose_wire_up,
        local_smoke_prototype,
        dev_writer_send_contract,
        final_dod_matrix,
        production_smoke_handoff,
        production_smoke_acceptance,
        final_closure_audit,
        production_smoke_evidence_watcher,
        backpressure: ClickHouseBackpressurePlan {
            enabled: true,
            max_queue_rows,
            overflow_action: drop_policy_to_overflow_action(&drop_policy),
            drop_policy,
        },
        dedup: ClickHouseDedupPlan {
            enabled: true,
            strategy: "stable_idempotency_key",
            key_material: "ids_and_payload_hash_only",
            conflict_action: "skip_duplicate_same_hash",
            per_sink_keys: ["request_logs", "provider_attempts", "event_log"]
                .into_iter()
                .map(|sink| ClickHouseDedupKeyPlan {
                    sink: sink.to_string(),
                    key_fields: dedup_key_fields(sink),
                })
                .collect(),
        },
        table_mapping,
        contract: ClickHouseWorkerContractReport {
            observability_contract: CLICKHOUSE_LOG_STORE_CONTRACT_VERSION,
            stable_fields: vec![
                "schema_version",
                "dry_run",
                "read_only",
                "network_requests",
                "clickhouse_config.contract",
                "queue.max_queue_rows",
                "queue.batch_size",
                "durable_queue.wal_directory",
                "durable_queue.disk_budget",
                "durable_queue.enqueue",
                "durable_queue.ack",
                "durable_queue.retry",
                "wal_service_guard",
                "wal_service_guard.production_service_readiness",
                "wal_service_guard.runtime_artifact_path_contract",
                "wal_dry_run_readback.contract",
                "wal_dry_run_readback.path_safety",
                "wal_dry_run_readback.write_readback_evidence",
                "wal_dry_run_readback.retention",
                "wal_runtime_writer.safe_path_gate",
                "wal_runtime_writer.artifact_readback",
                "wal_service_execution.command_skeleton",
                "wal_service_execution.runtime_service_readiness",
                "wal_service_execution.readiness_artifact",
                "local_compose_wire_up",
                "local_smoke_prototype",
                "dev_writer_send_contract",
                "final_dod_matrix",
                "production_smoke_handoff",
                "production_smoke_acceptance",
                "final_closure_audit",
                "production_smoke_evidence_watcher",
                "backpressure.drop_policy",
                "dedup.per_sink_keys",
                "table_mapping",
            ],
            config_validated_by_observability_crate: true,
            network_requests_disabled: true,
            db_reads_disabled: true,
            db_writes_disabled: true,
            queue_writes_disabled: true,
            file_system_writes_disabled: !(runtime_write_opt_in
                || service_readiness_artifact_opt_in
                || local_smoke_artifact_opt_in
                || dev_writer_artifact_opt_in),
            queue_plan_only: !(runtime_write_opt_in
                || service_readiness_artifact_opt_in
                || local_smoke_artifact_opt_in
                || dev_writer_artifact_opt_in),
            credential_material_omitted: true,
            env_values_omitted: true,
            payload_body_omitted: true,
        },
        remaining_gaps: vec![
            "real_clickhouse_writer",
            "database_changefeed_or_export_cursor",
            "production_durable_wal_writer",
            "dedup_journal_database_or_production_persistence",
            "load_and_retention_runtime_smoke",
        ],
    })
}

pub(crate) fn clickhouse_log_store_execute_error(force: bool) -> String {
    if force {
        return "clickhouse-log-store execute/send is not implemented in this dry-run slice; no DB read, queue write, WAL/file write, ClickHouse write, or network request was sent"
            .to_string();
    }

    "clickhouse-log-store execute/send requires --force and is not implemented in this dry-run slice; no DB read, queue write, WAL/file write, ClickHouse write, or network request was sent"
        .to_string()
}

fn durable_queue_plan(
    tenant_id: Uuid,
    max_queue_rows: u64,
    batch_size: u64,
    retry_max_attempts: u64,
    retry_initial_backoff_ms: u64,
    retry_max_backoff_ms: u64,
    overflow_action: String,
) -> ClickHouseDurableQueuePlan {
    const DEFAULT_MAX_WAL_BYTES: u64 = 512 * 1024 * 1024;
    const DEFAULT_SEGMENT_BYTES: u64 = 16 * 1024 * 1024;
    const DEFAULT_MAX_REPLAY_BYTES: u64 = 4 * 1024 * 1024;

    ClickHouseDurableQueuePlan {
        queue_type: "append_only_wal_future",
        planned: true,
        enabled_in_this_slice: false,
        execute_supported: false,
        file_system_writes: false,
        wal_directory: ClickHouseWalDirectoryPlan {
            root: "AI_GATEWAY_CLICKHOUSE_WAL_DIR or <data_dir>/clickhouse-log-store/wal",
            tenant_partition: format!("tenant_id={tenant_id}"),
            segment_pattern: "wal-{monotonic_sequence}.jsonl",
            checkpoint_file: "checkpoint.json",
            creates_directories: false,
            writes_files: false,
        },
        wal_record_shape: ClickHouseWalRecordShapePlan {
            encoding: "json_lines",
            status_values: vec!["pending", "leased", "acked", "retry", "dead_letter"],
            fields: vec![
                "wal_sequence",
                "tenant_id",
                "sink",
                "source_relation",
                "source_record_id",
                "request_id",
                "provider_attempt_id",
                "event_id",
                "dedup_key",
                "payload_hash",
                "payload_policy",
                "record_hash",
                "status",
                "attempt",
                "not_before_utc",
                "created_at_utc",
                "updated_at_utc",
                "metadata_redacted",
            ],
            payload_body_written: false,
            credential_material_written: false,
        },
        disk_budget: ClickHouseWalDiskBudgetPlan {
            bounded_disk: true,
            max_bytes: DEFAULT_MAX_WAL_BYTES,
            max_segment_bytes: DEFAULT_SEGMENT_BYTES,
            max_segments: DEFAULT_MAX_WAL_BYTES / DEFAULT_SEGMENT_BYTES,
            max_unacked_records: max_queue_rows,
            overflow_action,
        },
        enqueue: ClickHouseQueueOperationPlan {
            operation: "enqueue",
            idempotency_key_fields: vec!["tenant_id", "sink", "dedup_key", "record_hash"],
            status_from: vec!["missing"],
            status_to: "pending",
            transaction_boundary: "append_wal_record_then_update_dedup_journal_future",
        },
        dequeue: ClickHouseQueueOperationPlan {
            operation: "dequeue",
            idempotency_key_fields: vec!["tenant_id", "wal_sequence", "lease_id"],
            status_from: vec!["pending", "retry"],
            status_to: "leased",
            transaction_boundary: "lease_batch_before_clickhouse_send_future",
        },
        ack: ClickHouseQueueOperationPlan {
            operation: "ack",
            idempotency_key_fields: vec!["tenant_id", "wal_sequence", "sink", "dedup_key"],
            status_from: vec!["leased"],
            status_to: "acked",
            transaction_boundary: "ack_after_clickhouse_insert_and_dedup_confirm_future",
        },
        retry: ClickHouseQueueRetryPlan {
            idempotency_key_fields: vec!["tenant_id", "wal_sequence", "attempt"],
            max_attempts: retry_max_attempts,
            initial_backoff_ms: retry_initial_backoff_ms,
            max_backoff_ms: retry_max_backoff_ms,
            retry_status: "retry",
            exhausted_status: "dead_letter",
        },
        retention: ClickHouseWalRetentionPlan {
            delete_acked_segments_after_seconds: 86_400,
            delete_failed_segments_after_seconds: 604_800,
            checkpoint_after_acked_records: batch_size.max(1),
            requires_no_pending_records_before_segment_delete: true,
        },
        load_safety: ClickHouseWalLoadSafetyPlan {
            replay_order: "tenant_partition_then_wal_sequence",
            max_replay_batch_rows: batch_size.max(1),
            max_replay_bytes: DEFAULT_MAX_REPLAY_BYTES,
            single_consumer_lock: "advisory_file_lock_future",
            replay_requires_dedup_journal_check: true,
            payload_policy_enforced_before_enqueue: true,
        },
        dedup_journal_linkage: ClickHouseWalDedupJournalPlan {
            journal_relation: "clickhouse_log_store_dedup_journal_future",
            journal_key_fields: vec!["tenant_id", "sink", "dedup_key"],
            wal_link_fields: vec!["tenant_id", "wal_sequence", "record_hash", "payload_hash"],
            conflict_action: "skip_duplicate_same_record_hash",
            payload_hash_mismatch_action: "dead_letter_and_require_manual_review_future",
        },
    }
}

fn wal_dry_run_readback_plan(
    readback_requested: bool,
    input: Option<Value>,
    tenant_id: Uuid,
    durable_queue: &ClickHouseDurableQueuePlan,
) -> Result<Value, String> {
    if !readback_requested {
        return Ok(json!({
            "contract": CLICKHOUSE_WAL_DRY_RUN_READBACK_CONTRACT_VERSION,
            "requested": false,
            "mode": "plan_only",
            "read_only": true,
            "runtime_connected": false,
            "clickhouse_connected": false,
            "network_requests": false,
            "db_reads": false,
            "db_writes": false,
            "queue_writes": false,
            "file_system_writes": false,
            "directories_created": false,
            "files_written": false
        }));
    }

    let Some(mut input) = input else {
        return Err(
            "clickhouse-log-store --readback requires input.wal_dry_run_readback records"
                .to_string(),
        );
    };
    let Some(object) = input.as_object_mut() else {
        return Err("input.wal_dry_run_readback must be a JSON object".to_string());
    };

    object
        .entry("tenant_id".to_string())
        .or_insert_with(|| json!(tenant_id.to_string()));
    object
        .entry("wal_root".to_string())
        .or_insert_with(|| json!("tests/fixtures/worker/clickhouse-log-store/wal"));
    object
        .entry("segment_name".to_string())
        .or_insert_with(|| json!("wal-0000000000000001.jsonl"));
    object
        .entry("max_wal_bytes".to_string())
        .or_insert_with(|| json!(durable_queue.disk_budget.max_bytes));
    object
        .entry("max_segment_bytes".to_string())
        .or_insert_with(|| json!(durable_queue.disk_budget.max_segment_bytes));
    object
        .entry("max_unacked_records".to_string())
        .or_insert_with(|| json!(durable_queue.disk_budget.max_unacked_records));
    object
        .entry("checkpoint_after_acked_records".to_string())
        .or_insert_with(|| json!(durable_queue.retention.checkpoint_after_acked_records));
    object
        .entry("delete_acked_segments_after_seconds".to_string())
        .or_insert_with(|| json!(durable_queue.retention.delete_acked_segments_after_seconds));
    object
        .entry("delete_failed_segments_after_seconds".to_string())
        .or_insert_with(|| json!(durable_queue.retention.delete_failed_segments_after_seconds));
    object
        .entry("retry_max_attempts".to_string())
        .or_insert_with(|| json!(durable_queue.retry.max_attempts));

    clickhouse_wal_dry_run_readback_contract(&input)
        .map_err(|error| super::safe_error_text(&error.to_string()))
}

fn wal_runtime_writer_plan(runtime_write_opt_in: bool, readback: &Value) -> Result<Value, String> {
    if !runtime_write_opt_in {
        return Ok(json!({
            "contract": "clickhouse_log_store_wal_runtime_writer_artifact_v1",
            "requested": false,
            "opt_in": false,
            "mode": "disabled",
            "read_only": true,
            "runtime_connected": false,
            "clickhouse_connected": false,
            "network_requests": false,
            "db_reads": false,
            "db_writes": false,
            "queue_writes": false,
            "file_system_writes": false,
            "directories_created": false,
            "tmp_file_written": false,
            "segment_file_written": false,
            "dedup_journal_written": false
        }));
    }

    if !bool_path_at(readback, &["requested"]) {
        return Err("clickhouse-log-store --write-artifact requires --readback".to_string());
    }

    let path_safety = readback
        .get("path_safety")
        .ok_or_else(|| "wal readback contract is missing path_safety".to_string())?;
    let wal_root = required_json_str(path_safety, "wal_root")?;
    let tenant_partition = required_json_str(path_safety, "tenant_partition")?;
    let segment_name = required_json_str(path_safety, "segment_name")?;
    let records = readback
        .get("write_readback_evidence")
        .and_then(|value| value.get("records"))
        .and_then(Value::as_array)
        .ok_or_else(|| "wal readback contract is missing records".to_string())?;
    let safe_path_gate = wal_runtime_safe_path_gate(path_safety, wal_root, segment_name);

    if !bool_path_at(&safe_path_gate, &["allowed"]) {
        return Err(format!(
            "clickhouse-log-store --write-artifact refused WAL path `{}`; only repo-local .tmp WAL artifacts are allowed",
            super::safe_plan_text(wal_root)
        ));
    }

    let segment_dir = PathBuf::from(wal_root).join(tenant_partition);
    let segment_path = segment_dir.join(segment_name);
    let tmp_path = segment_dir.join(format!("{segment_name}.tmp"));
    let journal_path = segment_dir.join("dedup-journal.jsonl");

    fs::create_dir_all(&segment_dir).map_err(|error| {
        format!(
            "failed to create ClickHouse WAL artifact directory `{}`: {}",
            super::safe_plan_text(&segment_dir.display().to_string()),
            super::safe_error_text(&error.to_string())
        )
    })?;
    ensure_path_stays_under_tmp(&segment_dir)?;

    let segment_body = json_lines(records)?;
    write_file_synced(&tmp_path, segment_body.as_bytes())?;
    if segment_path.exists() {
        fs::remove_file(&segment_path).map_err(|error| {
            format!(
                "failed to replace ClickHouse WAL artifact `{}`: {}",
                super::safe_plan_text(&segment_path.display().to_string()),
                super::safe_error_text(&error.to_string())
            )
        })?;
    }
    fs::rename(&tmp_path, &segment_path).map_err(|error| {
        format!(
            "failed to publish ClickHouse WAL artifact `{}`: {}",
            super::safe_plan_text(&segment_path.display().to_string()),
            super::safe_error_text(&error.to_string())
        )
    })?;

    let journal_entries = journal_lines(records)?;
    write_file_synced(&journal_path, journal_entries.as_bytes())?;

    let readback_body = fs::read_to_string(&segment_path).map_err(|error| {
        format!(
            "failed to read back ClickHouse WAL artifact `{}`: {}",
            super::safe_plan_text(&segment_path.display().to_string()),
            super::safe_error_text(&error.to_string())
        )
    })?;
    let readback_records = parse_json_lines(&readback_body)?;
    let readback_hash_match_count = readback_records
        .iter()
        .filter(|record| bool_path_at(record, &["readback_hash_matches"]))
        .count();

    Ok(json!({
        "contract": "clickhouse_log_store_wal_runtime_writer_artifact_v1",
        "requested": true,
        "opt_in": true,
        "mode": "repo_bounded_artifact_write_readback",
        "read_only": false,
        "runtime_connected": false,
        "clickhouse_connected": false,
        "network_requests": false,
        "db_reads": false,
        "db_writes": false,
        "queue_writes": false,
        "file_system_writes": true,
        "safe_path_gate": safe_path_gate,
        "artifact_paths": {
            "segment_tmp_path": tmp_path.display().to_string(),
            "segment_path": segment_path.display().to_string(),
            "dedup_journal_path": journal_path.display().to_string(),
            "artifact_scope": ".tmp"
        },
        "write_evidence": {
            "directories_created": true,
            "tmp_file_written": true,
            "tmp_file_renamed": true,
            "segment_file_written": true,
            "dedup_journal_written": true,
            "bytes_written": segment_body.len(),
            "dedup_journal_bytes_written": journal_entries.len(),
            "segment_sha256": format!("sha256:{}", payload_sha256_hex(readback_body.as_bytes())),
            "payload_body_written": false,
            "credential_material_written": false
        },
        "artifact_readback": {
            "record_count": readback_records.len(),
            "readback_hash_match_count": readback_hash_match_count,
            "ack_retry_evidence_preserved": readback_records.iter().any(|record| str_path_at(record, &["operation"]) == Some("ack"))
                && readback_records.iter().any(|record| str_path_at(record, &["operation"]) == Some("retry")),
            "dedup_duplicate_evidence_preserved": readback_records.iter().any(|record| str_path_at(record, &["journal_decision"]) == Some("skip_duplicate_same_record_hash")),
            "journal_entry_count": journal_entries.lines().count()
        },
        "retention": readback.get("retention").cloned().unwrap_or_else(|| json!({})),
        "load_safety": {
            "readback_from_artifact_file": true,
            "single_consumer_lock": "not_acquired_in_artifact_slice",
            "replay_requires_dedup_journal_check": true,
            "bounded_to_repo_tmp": true
        }
    }))
}

fn wal_service_execution_dry_run_plan(
    requested: bool,
    readiness_artifact_opt_in: bool,
    tenant_id: Uuid,
    wal_service_guard: &Value,
) -> Result<Value, String> {
    let service_ready = bool_path_at(
        wal_service_guard,
        &["production_service_readiness", "ready"],
    );
    let readiness = str_path_at(wal_service_guard, &["readiness"]).unwrap_or("blocked");
    let blocker = wal_service_guard
        .get("blocker")
        .cloned()
        .unwrap_or(Value::Null);

    if !requested {
        return Ok(json!({
            "contract": "clickhouse_log_store_wal_service_execution_dry_run_v1",
            "requested": false,
            "mode": "plan_only",
            "dry_run": true,
            "read_only": true,
            "runtime_connected": false,
            "clickhouse_connected": false,
            "network_requests": false,
            "db_reads": false,
            "db_writes": false,
            "queue_writes": false,
            "file_system_writes": false,
            "production_root_writes": false,
            "readiness_artifact": {
                "requested": false,
                "written": false,
                "readback_performed": false
            }
        }));
    }

    let runtime_service_readiness = json!({
        "ready": service_ready,
        "readiness": readiness,
        "blocker": blocker,
        "production_root_present": wal_service_guard
            .get("production_root_present")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        "production_root_scope": wal_service_guard
            .get("root_scope")
            .and_then(Value::as_str)
            .unwrap_or("missing"),
        "production_root_writable_checked": false,
        "production_root_writes_enabled": false,
        "clickhouse_connectivity_checked": false,
        "clickhouse_network_requests_enabled": false,
        "artifact_tmp_can_satisfy_production_wal_root": false
    });
    let command_skeleton = json!({
        "command": "ai-worker clickhouse-log-store --service-readiness --input <json>",
        "write_artifact_command": "ai-worker clickhouse-log-store --service-readiness --write-service-readiness-artifact --input <json>",
        "dry_run": true,
        "default_readiness_only": true,
        "requires_explicit_artifact_opt_in": true,
        "service_loop_started": false,
        "wal_replay_started": false,
        "producer_started": false,
        "clickhouse_send_started": false,
        "production_wal_root_created": false,
        "production_wal_root_written": false
    });

    if !readiness_artifact_opt_in {
        return Ok(json!({
            "contract": "clickhouse_log_store_wal_service_execution_dry_run_v1",
            "requested": true,
            "mode": "service_readiness_dry_run",
            "dry_run": true,
            "read_only": true,
            "runtime_connected": false,
            "clickhouse_connected": false,
            "network_requests": false,
            "db_reads": false,
            "db_writes": false,
            "queue_writes": false,
            "file_system_writes": false,
            "production_root_writes": false,
            "command_skeleton": command_skeleton,
            "runtime_service_readiness": runtime_service_readiness,
            "readiness_artifact": {
                "requested": false,
                "written": false,
                "readback_performed": false,
                "artifact_scope": ".tmp",
                "production_wal_root_allowed": false
            }
        }));
    }

    let artifact_dir = PathBuf::from(".tmp")
        .join("clickhouse-log-store")
        .join("service-readiness");
    fs::create_dir_all(&artifact_dir).map_err(|error| {
        format!(
            "failed to create ClickHouse WAL service readiness artifact directory `{}`: {}",
            super::safe_plan_text(&artifact_dir.display().to_string()),
            super::safe_error_text(&error.to_string())
        )
    })?;
    ensure_path_stays_under_tmp(&artifact_dir)?;

    let artifact_path = artifact_dir.join(format!("tenant-{tenant_id}.json"));
    let artifact = json!({
        "schema_version": "clickhouse_log_store_wal_service_readiness_artifact_v1",
        "tenant_id": tenant_id,
        "generated_by": "ai-worker_clickhouse_log_store_service_readiness_dry_run",
        "runtime_service_readiness": runtime_service_readiness,
        "command_skeleton": command_skeleton,
        "side_effects": {
            "production_root_writes": false,
            "clickhouse_connected": false,
            "network_requests": false,
            "db_reads": false,
            "db_writes": false,
            "queue_writes": false
        }
    });
    let artifact_body = serde_json::to_vec_pretty(&artifact).map_err(|error| {
        format!(
            "failed to serialize ClickHouse WAL service readiness artifact: {}",
            super::safe_error_text(&error.to_string())
        )
    })?;
    write_file_synced(&artifact_path, &artifact_body)?;

    let readback_body = fs::read_to_string(&artifact_path).map_err(|error| {
        format!(
            "failed to read back ClickHouse WAL service readiness artifact `{}`: {}",
            super::safe_plan_text(&artifact_path.display().to_string()),
            super::safe_error_text(&error.to_string())
        )
    })?;
    let readback_json = serde_json::from_str::<Value>(&readback_body).map_err(|error| {
        format!(
            "failed to parse ClickHouse WAL service readiness artifact readback: {}",
            super::safe_error_text(&error.to_string())
        )
    })?;
    let readback_hash = format!("sha256:{}", payload_sha256_hex(readback_body.as_bytes()));
    let tenant_id_text = tenant_id.to_string();

    Ok(json!({
        "contract": "clickhouse_log_store_wal_service_execution_dry_run_v1",
        "requested": true,
        "mode": "service_readiness_artifact_write_readback",
        "dry_run": true,
        "read_only": false,
        "runtime_connected": false,
        "clickhouse_connected": false,
        "network_requests": false,
        "db_reads": false,
        "db_writes": false,
        "queue_writes": false,
        "file_system_writes": true,
        "production_root_writes": false,
        "command_skeleton": command_skeleton,
        "runtime_service_readiness": runtime_service_readiness,
        "readiness_artifact": {
            "requested": true,
            "written": true,
            "readback_performed": true,
            "artifact_scope": ".tmp",
            "path": artifact_path.display().to_string(),
            "schema_version": "clickhouse_log_store_wal_service_readiness_artifact_v1",
            "sha256": readback_hash,
            "readback_schema_matches": readback_json
                .get("schema_version")
                .and_then(Value::as_str)
                == Some("clickhouse_log_store_wal_service_readiness_artifact_v1"),
            "readback_tenant_matches": readback_json
                .get("tenant_id")
                .and_then(Value::as_str)
                == Some(tenant_id_text.as_str()),
            "production_wal_root_allowed": false,
            "production_root_written": false
        }
    }))
}

fn clickhouse_local_compose_wire_up(clickhouse_config: &Value, wal_service_guard: &Value) -> Value {
    let clickhouse_enabled = bool_path_at(clickhouse_config, &["enabled"]);
    let endpoint = clickhouse_config
        .get("endpoint")
        .and_then(Value::as_str)
        .unwrap_or("");
    let endpoint_is_local = endpoint.starts_with("http://127.0.0.1:")
        || endpoint.starts_with("http://localhost:")
        || endpoint.starts_with("http://clickhouse:");
    let wal_service_ready = bool_path_at(
        wal_service_guard,
        &["production_service_readiness", "ready"],
    );

    json!({
        "contract": "clickhouse_log_store_local_compose_wire_up_v1",
        "scope": "repo_local_dev_only",
        "compose_override": {
            "path": "deploy/docker-compose/docker-compose.clickhouse.local.yml",
            "profile": "clickhouse",
            "service": "clickhouse",
            "default_main_compose_service_present": false,
            "host_bind": "127.0.0.1:${CLICKHOUSE_HOST_PORT:-8123}:8123",
            "container_endpoint": "http://clickhouse:8123",
            "external_production_endpoint_allowed": false
        },
        "worker_env_contract": {
            "enabled_flag": "AI_GATEWAY_CLICKHOUSE_LOG_STORE_ENABLED=true",
            "endpoint": "AI_GATEWAY_CLICKHOUSE_ENDPOINT=http://clickhouse:8123",
            "database": "AI_GATEWAY_CLICKHOUSE_DATABASE=ai_gateway",
            "table": "AI_GATEWAY_CLICKHOUSE_TABLE=gateway_events",
            "wal_service_flag": "AI_GATEWAY_CLICKHOUSE_WAL_SERVICE_ENABLED=true",
            "wal_dir": "AI_GATEWAY_CLICKHOUSE_WAL_DIR=/var/lib/ai-gateway/clickhouse-log-store/wal",
            "values_output": false,
            "secret_values_required_for_local_default": false
        },
        "readiness": {
            "clickhouse_config_enabled": clickhouse_enabled,
            "endpoint_present": !endpoint.is_empty(),
            "endpoint_is_local_or_container": endpoint_is_local,
            "wal_service_ready": wal_service_ready,
            "safe_to_attempt_local_compose_smoke_after_operator_starts_profile": clickhouse_enabled && endpoint_is_local && wal_service_ready
        },
        "production_boundary": {
            "can_mark_final_x": false,
            "local_compose_can_substitute_production_smoke": false,
            "requires_real_writer_cursor_wal_dedup_load_retention_for_final": true,
            "default_connects_clickhouse": false,
            "default_network_requests": false
        }
    })
}

fn clickhouse_local_smoke_prototype_plan(
    requested: bool,
    write_artifact: bool,
    tenant_id: Uuid,
    wal_dry_run_readback: &Value,
    local_compose_wire_up: &Value,
) -> Result<Value, String> {
    let record_count = wal_dry_run_readback
        .get("segment")
        .and_then(|segment| segment.get("record_count"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let readback_hash_match_count = wal_dry_run_readback
        .get("write_readback_evidence")
        .and_then(|evidence| evidence.get("readback_hash_match_count"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let base = json!({
        "contract": "clickhouse_log_store_local_smoke_prototype_v1",
        "requested": requested,
        "mode": if write_artifact { "local_smoke_artifact_write_readback" } else if requested { "local_smoke_dry_run" } else { "not_requested" },
        "scope": "repo_local_dev_only",
        "dry_run": true,
        "runtime_connected": false,
        "clickhouse_connected": false,
        "network_requests": false,
        "db_reads": false,
        "db_writes": false,
        "queue_writes": false,
        "production_wal_root_writes": false,
        "writer_supported": false,
        "execute_supported": false,
        "send_supported": false,
        "production_smoke_passed": false,
        "final_x_eligible": false,
        "local_compose_wire_up_ready": bool_path_at(local_compose_wire_up, &["readiness", "safe_to_attempt_local_compose_smoke_after_operator_starts_profile"]),
        "prototype_counts": {
            "wal_dry_run_record_count": record_count,
            "wal_dry_run_readback_hash_match_count": readback_hash_match_count,
            "writer_insert_count": 0,
            "writer_readback_count": 0,
            "load_smoke_record_count": record_count
        },
        "production_boundary": {
            "local_prototype_can_mark_final_x": false,
            "local_prototype_can_mark_production_smoke_passed": false,
            "simulated_or_dry_run": true,
            "requires_future_live_writer_implementation": true
        }
    });

    if !write_artifact {
        return Ok(base);
    }

    let artifact_dir = PathBuf::from(".tmp")
        .join("clickhouse-log-store")
        .join("local-smoke");
    fs::create_dir_all(&artifact_dir).map_err(|error| {
        format!(
            "failed to create ClickHouse local smoke artifact directory `{}`: {}",
            super::safe_plan_text(&artifact_dir.display().to_string()),
            super::safe_error_text(&error.to_string())
        )
    })?;
    ensure_path_stays_under_tmp(&artifact_dir)?;

    let artifact_path = artifact_dir.join(format!("tenant-{tenant_id}.json"));
    let artifact = json!({
        "schema_version": "clickhouse_log_store_local_smoke_prototype_artifact_v1",
        "tenant_id": tenant_id,
        "generated_by": "ai-worker_clickhouse_log_store_local_smoke_prototype",
        "local_prototype": true,
        "simulated": true,
        "production_smoke_passed": false,
        "final_x_eligible": false,
        "clickhouse_connected": false,
        "network_requests": false,
        "production_wal_root_writes": false,
        "writer_supported": false,
        "execute_supported": false,
        "send_supported": false,
        "record_count": record_count,
        "readback_hash_match_count": readback_hash_match_count,
        "secret_safe_omissions": [
            "clickhouse_password",
            "clickhouse_token",
            "authorization_header",
            "payload_body",
            "env_values",
            "database_credentials"
        ]
    });
    let artifact_body = serde_json::to_vec_pretty(&artifact).map_err(|error| {
        format!(
            "failed to serialize ClickHouse local smoke prototype artifact: {}",
            super::safe_error_text(&error.to_string())
        )
    })?;
    write_file_synced(&artifact_path, &artifact_body)?;

    let readback_body = fs::read_to_string(&artifact_path).map_err(|error| {
        format!(
            "failed to read back ClickHouse local smoke prototype artifact `{}`: {}",
            super::safe_plan_text(&artifact_path.display().to_string()),
            super::safe_error_text(&error.to_string())
        )
    })?;
    let readback_json = serde_json::from_str::<Value>(&readback_body).map_err(|error| {
        format!(
            "failed to parse ClickHouse local smoke prototype artifact readback: {}",
            super::safe_error_text(&error.to_string())
        )
    })?;
    let tenant_id_text = tenant_id.to_string();

    Ok(json!({
        "contract": "clickhouse_log_store_local_smoke_prototype_v1",
        "requested": true,
        "mode": "local_smoke_artifact_write_readback",
        "scope": "repo_local_dev_only",
        "dry_run": true,
        "runtime_connected": false,
        "clickhouse_connected": false,
        "network_requests": false,
        "db_reads": false,
        "db_writes": false,
        "queue_writes": false,
        "file_system_writes": true,
        "production_wal_root_writes": false,
        "writer_supported": false,
        "execute_supported": false,
        "send_supported": false,
        "production_smoke_passed": false,
        "final_x_eligible": false,
        "artifact": {
            "written": true,
            "readback_performed": true,
            "artifact_scope": ".tmp",
            "path": artifact_path.display().to_string(),
            "schema_version": "clickhouse_log_store_local_smoke_prototype_artifact_v1",
            "sha256": format!("sha256:{}", payload_sha256_hex(readback_body.as_bytes())),
            "readback_schema_matches": readback_json.get("schema_version").and_then(Value::as_str)
                == Some("clickhouse_log_store_local_smoke_prototype_artifact_v1"),
            "readback_tenant_matches": readback_json.get("tenant_id").and_then(Value::as_str)
                == Some(tenant_id_text.as_str()),
            "production_smoke_artifact": false
        },
        "prototype_counts": {
            "wal_dry_run_record_count": record_count,
            "wal_dry_run_readback_hash_match_count": readback_hash_match_count,
            "writer_insert_count": 0,
            "writer_readback_count": 0,
            "load_smoke_record_count": record_count
        },
        "production_boundary": {
            "local_prototype_can_mark_final_x": false,
            "local_prototype_can_mark_production_smoke_passed": false,
            "simulated_or_dry_run": true,
            "requires_future_live_writer_implementation": true
        }
    }))
}

fn clickhouse_dev_writer_send_contract_plan(
    requested: bool,
    write_artifact: bool,
    tenant_id: Uuid,
    wal_dry_run_readback: &Value,
    local_compose_wire_up: &Value,
) -> Result<Value, String> {
    let record_count = wal_dry_run_readback
        .get("segment")
        .and_then(|segment| segment.get("record_count"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let readback_hash_match_count = wal_dry_run_readback
        .get("write_readback_evidence")
        .and_then(|evidence| evidence.get("readback_hash_match_count"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let compose_ready = bool_path_at(
        local_compose_wire_up,
        &[
            "readiness",
            "safe_to_attempt_local_compose_smoke_after_operator_starts_profile",
        ],
    );
    let base = json!({
        "contract": "clickhouse_log_store_dev_writer_send_contract_v1",
        "requested": requested,
        "mode": if write_artifact { "dev_writer_artifact_write_readback" } else if requested { "dev_writer_dry_run" } else { "not_requested" },
        "scope": "repo_local_dev_only",
        "dry_run": true,
        "runtime_connected": false,
        "clickhouse_connected": false,
        "network_requests": false,
        "db_reads": false,
        "db_writes": false,
        "queue_writes": false,
        "file_system_writes": false,
        "production_wal_root_writes": false,
        "writer_supported": false,
        "execute_supported": false,
        "send_supported": false,
        "compose_ready": compose_ready,
        "planned_writer": {
            "source": "wal_dry_run_readback_records",
            "target": "local_clickhouse_only",
            "insert_batches": 0,
            "readback_rows": 0,
            "payload_body_output": false,
            "credential_material_output": false
        },
        "prototype_counts": {
            "wal_dry_run_record_count": record_count,
            "wal_dry_run_readback_hash_match_count": readback_hash_match_count,
            "writer_insert_count": 0,
            "writer_readback_count": 0
        },
        "production_boundary": {
            "dev_writer_can_mark_final_x": false,
            "dev_writer_can_mark_production_smoke_passed": false,
            "simulated_or_dry_run": true,
            "requires_future_live_writer_implementation": true
        },
        "secret_safe_omissions": [
            "clickhouse_password",
            "clickhouse_token",
            "authorization_header",
            "payload_body",
            "env_values",
            "database_credentials"
        ]
    });

    if !write_artifact {
        return Ok(base);
    }

    let artifact_dir = PathBuf::from(".tmp")
        .join("clickhouse-log-store")
        .join("dev-writer");
    fs::create_dir_all(&artifact_dir).map_err(|error| {
        format!(
            "failed to create ClickHouse dev writer artifact directory `{}`: {}",
            super::safe_plan_text(&artifact_dir.display().to_string()),
            super::safe_error_text(&error.to_string())
        )
    })?;
    ensure_path_stays_under_tmp(&artifact_dir)?;

    let artifact_path = artifact_dir.join(format!("tenant-{tenant_id}.json"));
    let artifact = json!({
        "schema_version": "clickhouse_log_store_dev_writer_send_contract_artifact_v1",
        "tenant_id": tenant_id,
        "generated_by": "ai-worker_clickhouse_log_store_dev_writer_send_contract",
        "dev_writer_contract": true,
        "simulated": true,
        "production_smoke_passed": false,
        "final_x_eligible": false,
        "clickhouse_connected": false,
        "network_requests": false,
        "production_wal_root_writes": false,
        "writer_supported": false,
        "execute_supported": false,
        "send_supported": false,
        "record_count": record_count,
        "readback_hash_match_count": readback_hash_match_count,
        "secret_safe_omissions": [
            "clickhouse_password",
            "clickhouse_token",
            "authorization_header",
            "payload_body",
            "env_values",
            "database_credentials"
        ]
    });
    let artifact_body = serde_json::to_vec_pretty(&artifact).map_err(|error| {
        format!(
            "failed to serialize ClickHouse dev writer artifact: {}",
            super::safe_error_text(&error.to_string())
        )
    })?;
    write_file_synced(&artifact_path, &artifact_body)?;

    let readback_body = fs::read_to_string(&artifact_path).map_err(|error| {
        format!(
            "failed to read back ClickHouse dev writer artifact `{}`: {}",
            super::safe_plan_text(&artifact_path.display().to_string()),
            super::safe_error_text(&error.to_string())
        )
    })?;
    let readback_json = serde_json::from_str::<Value>(&readback_body).map_err(|error| {
        format!(
            "failed to parse ClickHouse dev writer artifact readback: {}",
            super::safe_error_text(&error.to_string())
        )
    })?;
    let tenant_id_text = tenant_id.to_string();

    Ok(json!({
        "contract": "clickhouse_log_store_dev_writer_send_contract_v1",
        "requested": true,
        "mode": "dev_writer_artifact_write_readback",
        "scope": "repo_local_dev_only",
        "dry_run": true,
        "runtime_connected": false,
        "clickhouse_connected": false,
        "network_requests": false,
        "db_reads": false,
        "db_writes": false,
        "queue_writes": false,
        "file_system_writes": true,
        "production_wal_root_writes": false,
        "writer_supported": false,
        "execute_supported": false,
        "send_supported": false,
        "compose_ready": compose_ready,
        "artifact": {
            "written": true,
            "readback_performed": true,
            "artifact_scope": ".tmp",
            "path": artifact_path.display().to_string(),
            "schema_version": "clickhouse_log_store_dev_writer_send_contract_artifact_v1",
            "sha256": format!("sha256:{}", payload_sha256_hex(readback_body.as_bytes())),
            "readback_schema_matches": readback_json.get("schema_version").and_then(Value::as_str)
                == Some("clickhouse_log_store_dev_writer_send_contract_artifact_v1"),
            "readback_tenant_matches": readback_json.get("tenant_id").and_then(Value::as_str)
                == Some(tenant_id_text.as_str()),
            "production_smoke_artifact": false
        },
        "prototype_counts": {
            "wal_dry_run_record_count": record_count,
            "wal_dry_run_readback_hash_match_count": readback_hash_match_count,
            "writer_insert_count": 0,
            "writer_readback_count": 0
        },
        "production_boundary": {
            "dev_writer_can_mark_final_x": false,
            "dev_writer_can_mark_production_smoke_passed": false,
            "simulated_or_dry_run": true,
            "requires_future_live_writer_implementation": true
        },
        "secret_safe_omissions": [
            "clickhouse_password",
            "clickhouse_token",
            "authorization_header",
            "payload_body",
            "env_values",
            "database_credentials"
        ]
    }))
}

fn clickhouse_final_dod_matrix(wal_service_guard: &Value) -> Value {
    let production_ready = bool_path_at(
        wal_service_guard,
        &["production_service_readiness", "ready"],
    );

    json!({
        "contract": "clickhouse_log_store_final_dod_matrix_v1",
        "target_todo": "E15-005",
        "final_status_target": "x_only_after_live_smoke_readback",
        "current_contract_stage": if production_ready {
            "production_ready_config_guard"
        } else {
            "blocked_before_production_ready"
        },
        "default_side_effects": {
            "production_root_writes": false,
            "clickhouse_connected": false,
            "network_requests": false,
            "db_reads": false,
            "db_writes": false,
            "queue_writes": false,
            "file_system_writes": false
        },
        "readiness_and_artifact_proof_scope": {
            "can_mark_production_ready": production_ready,
            "can_mark_final_x": false,
            "simulation_can_mark_final_x": false,
            "fixture_can_mark_final_x": false,
            "handoff_can_mark_final_x": false,
            "audit_without_real_artifact_can_mark_final_x": false,
            "refusal_can_mark_final_x": false,
            "reason": "readiness/artifact proof has no live ClickHouse insert, source changefeed, production WAL write, service loop replay/send, dedup persistence, or load-retention smoke",
            "repo_bounded_artifacts_allowed": true,
            "production_root_artifact_substitution_allowed": false
        },
        "acceptance_matrix": [
            final_dod_item(
                "real_clickhouse_insert_writer",
                "ClickHouse insert writer sends request_logs/provider_attempts/event_log batches to real ClickHouse",
                "live_insert_readback_required",
                "blocker",
                true,
            ),
            final_dod_item(
                "db_changefeed_or_export_cursor",
                "DB source cursor/changefeed exports request_logs/provider_attempts/event_log without raw payload or secrets",
                "live_source_cursor_readback_required",
                "blocker",
                true,
            ),
            final_dod_item(
                "production_wal_root_writes",
                "Production WAL root is created/written only after explicit production service opt-in and root readiness",
                "production_wal_segment_and_checkpoint_readback_required",
                "blocker",
                true,
            ),
            final_dod_item(
                "wal_service_loop_replay_send",
                "Service loop leases WAL records, replays in order, sends to ClickHouse, and acks only after insert success",
                "live_service_loop_replay_send_ack_readback_required",
                "blocker",
                true,
            ),
            final_dod_item(
                "dedup_journal_persistence",
                "Dedup journal persists across restarts and suppresses duplicate WAL records with same hash while blocking hash mismatch",
                "restart_persistence_and_duplicate_readback_required",
                "blocker",
                true,
            ),
            final_dod_item(
                "retention_load_smoke",
                "Bounded load smoke proves retention deletes only safe acked/failed segments and respects disk/replay budgets",
                "load_retention_smoke_artifact_required",
                "blocker",
                true,
            ),
            final_dod_item(
                "secret_safe_evidence",
                "All evidence is presence/hash/count/status only and omits credentials, raw payload, auth headers, and env values",
                "secret_safe_report_review_required",
                "blocker",
                false,
            ),
            final_dod_item(
                "no_network_default_and_execute_refusal",
                "Default CLI and config/readiness/artifact modes make no network requests; execute/send stays refused until final live implementation gate",
                "default_and_refusal_cli_checks_required",
                "blocker",
                false,
            )
        ],
        "final_x_requires": [
            "real_clickhouse_insert_writer_passed",
            "db_changefeed_or_export_cursor_passed",
            "production_wal_root_writes_passed",
            "wal_service_loop_replay_send_passed",
            "dedup_journal_persistence_passed",
            "retention_load_smoke_passed",
            "secret_safe_evidence_passed",
            "no_network_default_and_execute_refusal_passed"
        ],
        "remaining_blockers": [
            "real_clickhouse_insert_writer",
            "db_changefeed_or_export_cursor",
            "production_wal_root_writes",
            "wal_service_loop_replay_send",
            "dedup_journal_persistence",
            "retention_load_smoke"
        ]
    })
}

fn final_dod_item(
    id: &'static str,
    requirement: &'static str,
    required_live_evidence: &'static str,
    current_status: &'static str,
    requires_live_runtime: bool,
) -> Value {
    json!({
        "id": id,
        "requirement": requirement,
        "required_live_evidence": required_live_evidence,
        "current_status": current_status,
        "requires_live_runtime": requires_live_runtime,
        "readiness_or_artifact_proof_sufficient_for_final_x": false
    })
}

fn clickhouse_production_smoke_handoff(
    clickhouse_config: &Value,
    wal_service_guard: &Value,
) -> Value {
    let clickhouse_enabled = bool_path_at(clickhouse_config, &["enabled"]);
    let clickhouse_url_present = clickhouse_config
        .get("endpoint")
        .and_then(Value::as_str)
        .is_some();
    let wal_root_ready = bool_path_at(
        wal_service_guard,
        &["production_service_readiness", "ready"],
    );
    let production_smoke_ready = clickhouse_enabled && clickhouse_url_present && wal_root_ready;

    json!({
        "contract": "clickhouse_log_store_production_smoke_handoff_v1",
        "mode": "operator_handoff_contract_only",
        "default_side_effects": {
            "clickhouse_connected": false,
            "network_requests": false,
            "production_wal_root_writes": false,
            "db_reads": false,
            "db_writes": false,
            "queue_writes": false,
            "file_system_writes": false
        },
        "state_classification": {
            "production_smoke_ready": production_smoke_ready,
            "production_smoke_blocked": !production_smoke_ready,
            "final_x_eligible": false,
            "readiness_or_handoff_contract_can_close_final_gap": false,
            "handoff_can_mark_final_x": false,
            "fixture_can_mark_final_x": false,
            "simulation_can_mark_final_x": false,
            "audit_without_real_artifact_can_mark_final_x": false,
            "ready_means": "operator_has_required_config_presence_to_attempt_live_smoke",
            "final_x_requires": "live_writer_cursor_wal_dedup_retention_load_readback_artifact_pass"
        },
        "preflight_command_shape": {
            "default_contract_command": "ai-worker clickhouse-log-store --production-smoke-handoff --input <json>",
            "future_live_smoke_command": "ai-worker clickhouse-log-store --execute --production-smoke --force --input <json> --artifact <repo/.tmp/proof.json>",
            "requires_explicit_live_opt_in": true,
            "current_slice_executes_live_smoke": false,
            "clickhouse_url_env_presence_only": [
                "AI_GATEWAY_CLICKHOUSE_ENDPOINT",
                "AI_GATEWAY_CLICKHOUSE_LOG_STORE_ENDPOINT"
            ],
            "db_cursor_source": "DB changefeed/export cursor preflight must provide source relation, cursor position, lag, row count, and current commit without raw payload",
            "wal_root": "AI_GATEWAY_CLICKHOUSE_WAL_DIR or AI_GATEWAY_CLICKHOUSE_LOG_STORE_WAL_DIR; production root only, never .tmp",
            "dedup_journal_path": "<production_wal_root>/dedup-journal.jsonl or configured production dedup journal path",
            "retention_load_smoke_artifact_path": ".tmp/clickhouse-log-store/production-smoke/<run_id>.json for handoff/readback evidence"
        },
        "preflight_presence_readback": {
            "clickhouse_enabled": clickhouse_enabled,
            "clickhouse_url_present": clickhouse_url_present,
            "clickhouse_url_secret_echo": false,
            "wal_service_opt_in": wal_service_guard
                .get("service_opt_in")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            "production_wal_root_present": wal_service_guard
                .get("production_root_present")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            "production_wal_root_scope": wal_service_guard
                .get("root_scope")
                .and_then(Value::as_str)
                .unwrap_or("missing"),
            "production_wal_root_ready": wal_root_ready
        },
        "artifact_schema": {
            "schema_version": "clickhouse_log_store_production_smoke_artifact_v1",
            "required_fields": [
                "schema_version",
                "generated_at_utc",
                "current_commit",
                "runtime_commit",
                "writer_insert_count",
                "writer_readback_count",
                "cursor_position",
                "cursor_lag_rows",
                "wal_append_count",
                "wal_replay_count",
                "wal_send_count",
                "wal_ack_count",
                "dedup_hit_count",
                "dedup_miss_count",
                "dedup_journal_persisted",
                "retention_deleted_segment_count",
                "retention_readback_count",
                "load_smoke_duration_ms",
                "load_smoke_record_count",
                "secret_safe_omissions"
            ],
            "secret_safe_omissions": [
                "clickhouse_password",
                "clickhouse_token",
                "authorization_header",
                "payload_body",
                "env_values",
                "database_credentials"
            ],
            "simulated_artifact_can_pass": false,
            "stale_artifact_can_pass": false,
            "fixture_artifact_can_pass_final_x": false
        },
        "readback_acceptance": {
            "writer_insert_count_matches_readback_count": true,
            "cursor_position_current_required": true,
            "wal_append_replay_send_ack_counts_required": true,
            "dedup_hit_miss_and_journal_persistence_required": true,
            "retention_readback_required": true,
            "load_smoke_duration_required": true,
            "generated_at_and_current_commit_required": true,
            "secret_safe_omission_required": true
        },
        "failure_taxonomy": [
            "missing_clickhouse",
            "unsafe_url_or_secret_echo",
            "missing_db_cursor",
            "production_wal_path_not_opted_in",
            "dedup_journal_missing",
            "load_smoke_unavailable",
            "retention_readback_missing",
            "stale_artifact",
            "simulated_artifact",
            "network_attempted_without_opt_in"
        ],
        "refusal_boundaries": {
            "unsafe_clickhouse_url_refusal": true,
            "secret_echo_refusal": true,
            "missing_db_cursor_refusal": true,
            "artifact_tmp_as_production_wal_root_refusal": true,
            "network_without_live_opt_in_refusal": true,
            "production_wal_write_without_live_opt_in_refusal": true,
            "refusal_can_mark_final_x": false
        },
        "remaining_blockers": [
            "real_clickhouse_writer",
            "database_changefeed_or_export_cursor",
            "production_wal_service_loop_replay_send",
            "dedup_journal_persistence",
            "load_retention_smoke"
        ]
    })
}

fn production_smoke_artifact_acceptance(artifact_path: Option<&str>) -> Value {
    let Some(artifact_path) = artifact_path
        .map(str::trim)
        .filter(|value| !value.is_empty())
    else {
        return json!({
            "contract": "clickhouse_log_store_production_smoke_acceptance_gate_v1",
            "requested": false,
            "mode": "not_requested",
            "artifact_read": false,
            "production_smoke_evidence_accepted_for_review": false,
            "production_smoke_passed": false,
            "final_x_eligible": false,
            "simulation_can_mark_final_x": false,
            "fixture_can_mark_final_x": false,
            "refusal_can_mark_final_x": false,
            "default_side_effects": production_smoke_acceptance_default_side_effects(),
            "acceptance_schema": production_smoke_acceptance_schema(),
            "refusal_taxonomy": production_smoke_acceptance_refusal_taxonomy()
        });
    };

    let path_gate = production_smoke_artifact_path_gate(artifact_path);
    if !bool_path_at(&path_gate, &["allowed"]) {
        return production_smoke_acceptance_refused(
            artifact_path,
            path_gate,
            vec!["unsafe_path"],
            None,
        );
    }

    let body = match fs::read_to_string(artifact_path) {
        Ok(body) => body,
        Err(_) => {
            return production_smoke_acceptance_refused(
                artifact_path,
                path_gate,
                vec!["missing_artifact"],
                None,
            );
        }
    };
    let artifact = match serde_json::from_str::<Value>(&body) {
        Ok(artifact) => artifact,
        Err(_) => {
            return production_smoke_acceptance_refused(
                artifact_path,
                path_gate,
                vec!["artifact_parse_error"],
                None,
            );
        }
    };

    let mut review_refusals = Vec::<&'static str>::new();
    let mut final_blockers = Vec::<&'static str>::new();
    let required = production_smoke_required_artifact_fields();
    let missing_fields = required
        .iter()
        .filter(|field| artifact.get(**field).is_none())
        .copied()
        .collect::<Vec<_>>();
    if !missing_fields.is_empty() {
        review_refusals.push("missing_required_fields");
    }

    let writer_insert_count = artifact.get("writer_insert_count").and_then(Value::as_u64);
    let writer_readback_count = artifact
        .get("writer_readback_count")
        .and_then(Value::as_u64);
    if writer_insert_count.is_none() || writer_readback_count.is_none() {
        review_refusals.push("missing_writer_counts");
    } else if writer_insert_count != writer_readback_count {
        review_refusals.push("insert_readback_mismatch");
    }

    if artifact
        .get("cursor_position")
        .and_then(Value::as_str)
        .is_none()
        || artifact
            .get("cursor_lag_rows")
            .and_then(Value::as_u64)
            .is_none()
    {
        review_refusals.push("missing_db_cursor");
    }
    if [
        "wal_append_count",
        "wal_replay_count",
        "wal_send_count",
        "wal_ack_count",
    ]
    .iter()
    .any(|field| artifact.get(*field).and_then(Value::as_u64).is_none())
    {
        review_refusals.push("missing_wal_replay_send_ack");
    }
    if artifact
        .get("dedup_journal_persisted")
        .and_then(Value::as_bool)
        != Some(true)
    {
        review_refusals.push("dedup_journal_missing");
    }
    if artifact
        .get("retention_readback_count")
        .and_then(Value::as_u64)
        .is_none()
    {
        review_refusals.push("retention_readback_missing");
    }
    if artifact
        .get("load_smoke_duration_ms")
        .and_then(Value::as_u64)
        .is_none()
    {
        review_refusals.push("load_duration_missing_or_non_numeric");
    }
    let current_commit = artifact.get("current_commit").and_then(Value::as_str);
    let runtime_commit = artifact.get("runtime_commit").and_then(Value::as_str);
    if current_commit.is_none() || runtime_commit.is_none() || current_commit != runtime_commit {
        final_blockers.push("stale_artifact");
    }
    if artifact.get("simulated").and_then(Value::as_bool) == Some(true) {
        final_blockers.push("simulated_artifact");
    }
    if artifact
        .get("network_attempted_without_opt_in")
        .and_then(Value::as_bool)
        == Some(true)
    {
        review_refusals.push("network_attempted_without_opt_in");
    }
    if artifact.get("raw_dsn_present").and_then(Value::as_bool) == Some(true)
        || artifact.get("secret_echo_present").and_then(Value::as_bool) == Some(true)
    {
        review_refusals.push("secret_echo_or_raw_dsn_present");
    }
    if !secret_safe_omissions_present(&artifact) {
        review_refusals.push("secret_safe_omissions_missing");
    }

    let accepted_for_review = review_refusals.is_empty();
    let production_smoke_passed = accepted_for_review && final_blockers.is_empty();

    json!({
        "contract": "clickhouse_log_store_production_smoke_acceptance_gate_v1",
        "requested": true,
        "mode": "artifact_readback_gate",
        "artifact_read": true,
        "artifact_path": super::safe_plan_text(artifact_path),
        "path_gate": path_gate,
        "artifact_sha256": format!("sha256:{}", payload_sha256_hex(body.as_bytes())),
        "default_side_effects": production_smoke_acceptance_default_side_effects(),
        "acceptance_schema": production_smoke_acceptance_schema(),
        "artifact_provenance": {
            "schema_version": artifact.get("schema_version").and_then(Value::as_str),
            "generated_at_utc": artifact.get("generated_at_utc").and_then(Value::as_str),
            "current_commit": current_commit,
            "runtime_commit": runtime_commit,
            "simulated": artifact.get("simulated").and_then(Value::as_bool).unwrap_or(false),
            "stale": final_blockers.contains(&"stale_artifact")
        },
        "acceptance_matrix": {
            "writer_counts": accepted_or_refused(writer_insert_count.is_some() && writer_insert_count == writer_readback_count),
            "db_cursor": accepted_or_refused(!review_refusals.contains(&"missing_db_cursor")),
            "wal_replay_send_ack": accepted_or_refused(!review_refusals.contains(&"missing_wal_replay_send_ack")),
            "dedup_journal": accepted_or_refused(!review_refusals.contains(&"dedup_journal_missing")),
            "retention_load": accepted_or_refused(!review_refusals.contains(&"retention_readback_missing") && !review_refusals.contains(&"load_duration_missing_or_non_numeric")),
            "secret_safe": accepted_or_refused(!review_refusals.contains(&"secret_safe_omissions_missing") && !review_refusals.contains(&"secret_echo_or_raw_dsn_present")),
            "freshness": accepted_or_refused(!final_blockers.contains(&"stale_artifact")),
            "non_simulated": accepted_or_refused(!final_blockers.contains(&"simulated_artifact"))
        },
        "counts": {
            "writer_insert_count": writer_insert_count,
            "writer_readback_count": writer_readback_count,
            "cursor_lag_rows": artifact.get("cursor_lag_rows").and_then(Value::as_u64),
            "wal_append_count": artifact.get("wal_append_count").and_then(Value::as_u64),
            "wal_replay_count": artifact.get("wal_replay_count").and_then(Value::as_u64),
            "wal_send_count": artifact.get("wal_send_count").and_then(Value::as_u64),
            "wal_ack_count": artifact.get("wal_ack_count").and_then(Value::as_u64),
            "dedup_hit_count": artifact.get("dedup_hit_count").and_then(Value::as_u64),
            "dedup_miss_count": artifact.get("dedup_miss_count").and_then(Value::as_u64),
            "retention_readback_count": artifact.get("retention_readback_count").and_then(Value::as_u64),
            "load_smoke_duration_ms": artifact.get("load_smoke_duration_ms").and_then(Value::as_u64),
            "load_smoke_record_count": artifact.get("load_smoke_record_count").and_then(Value::as_u64)
        },
        "review_refusal_reasons": review_refusals,
        "final_x_blockers": final_blockers,
        "production_smoke_evidence_accepted_for_review": accepted_for_review,
        "production_smoke_passed": production_smoke_passed,
        "final_x_eligible": false,
        "simulation_can_mark_final_x": false,
        "fixture_can_mark_final_x": false,
        "refusal_can_mark_final_x": false,
        "refusal_taxonomy": production_smoke_acceptance_refusal_taxonomy()
    })
}

fn production_smoke_acceptance_refused(
    artifact_path: &str,
    path_gate: Value,
    reasons: Vec<&'static str>,
    artifact: Option<Value>,
) -> Value {
    json!({
        "contract": "clickhouse_log_store_production_smoke_acceptance_gate_v1",
        "requested": true,
        "mode": "artifact_readback_gate_refused",
        "artifact_read": false,
        "artifact_path": super::safe_plan_text(artifact_path),
        "path_gate": path_gate,
        "default_side_effects": production_smoke_acceptance_default_side_effects(),
        "acceptance_schema": production_smoke_acceptance_schema(),
        "artifact_provenance": artifact,
        "review_refusal_reasons": reasons,
        "production_smoke_evidence_accepted_for_review": false,
        "production_smoke_passed": false,
        "final_x_eligible": false,
        "simulation_can_mark_final_x": false,
        "fixture_can_mark_final_x": false,
        "refusal_can_mark_final_x": false,
        "refusal_taxonomy": production_smoke_acceptance_refusal_taxonomy()
    })
}

fn production_smoke_acceptance_default_side_effects() -> Value {
    json!({
        "artifact_read_default": false,
        "clickhouse_connected": false,
        "network_requests": false,
        "production_wal_root_writes": false,
        "db_reads": false,
        "db_writes": false,
        "queue_writes": false
    })
}

fn production_smoke_acceptance_schema() -> Value {
    json!({
        "artifact_schema_version": "clickhouse_log_store_production_smoke_artifact_v1",
        "required_fields": production_smoke_required_artifact_fields(),
        "accepted_shape_simulation_supported": true,
        "simulation_can_mark_final_x": false,
        "fixture_can_mark_final_x": false,
        "handoff_can_mark_final_x": false,
        "refusal_can_mark_final_x": false,
        "artifact_path_scopes": [".tmp", "tests/fixtures"]
    })
}

fn production_smoke_required_artifact_fields() -> Vec<&'static str> {
    vec![
        "schema_version",
        "generated_at_utc",
        "current_commit",
        "runtime_commit",
        "writer_insert_count",
        "writer_readback_count",
        "cursor_position",
        "cursor_lag_rows",
        "wal_append_count",
        "wal_replay_count",
        "wal_send_count",
        "wal_ack_count",
        "dedup_hit_count",
        "dedup_miss_count",
        "dedup_journal_persisted",
        "retention_readback_count",
        "load_smoke_duration_ms",
        "load_smoke_record_count",
        "secret_safe_omissions",
        "simulated",
    ]
}

fn production_smoke_acceptance_refusal_taxonomy() -> Vec<&'static str> {
    vec![
        "missing_artifact",
        "unsafe_path",
        "stale_artifact",
        "simulated_artifact",
        "missing_writer_counts",
        "insert_readback_mismatch",
        "missing_db_cursor",
        "missing_wal_replay_send_ack",
        "dedup_journal_missing",
        "retention_readback_missing",
        "load_duration_missing_or_non_numeric",
        "secret_echo_or_raw_dsn_present",
        "network_attempted_without_opt_in",
    ]
}

fn clickhouse_final_closure_audit(
    production_smoke_handoff: &Value,
    production_smoke_acceptance: &Value,
) -> Value {
    let acceptance_requested = bool_path_at(production_smoke_acceptance, &["requested"]);
    let artifact_read = bool_path_at(production_smoke_acceptance, &["artifact_read"]);
    let smoke_passed = bool_path_at(production_smoke_acceptance, &["production_smoke_passed"]);
    let simulation = bool_path_at(
        production_smoke_acceptance,
        &["artifact_provenance", "simulated"],
    );
    let fixture_artifact = str_path_at(
        production_smoke_acceptance,
        &["path_gate", "artifact_scope"],
    ) == Some("tests/fixtures");
    let matrix = production_smoke_acceptance
        .get("acceptance_matrix")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let required_evidence = final_closure_required_evidence(&matrix);
    let all_required_accepted = required_evidence
        .iter()
        .all(|item| item.get("state").and_then(Value::as_str) == Some("accepted"));
    let mut blocking_reasons = Vec::<String>::new();

    if !acceptance_requested {
        blocking_reasons.push("missing_production_smoke_artifact".to_string());
    }
    if acceptance_requested && !artifact_read {
        blocking_reasons.push("production_smoke_artifact_refused_or_unread".to_string());
    }
    if simulation {
        blocking_reasons.push("simulated_artifact".to_string());
    }
    if fixture_artifact {
        blocking_reasons.push("fixture_artifact".to_string());
    }
    if !smoke_passed {
        blocking_reasons.push("production_smoke_not_passed".to_string());
    }
    for reason in string_array_at(production_smoke_acceptance, &["review_refusal_reasons"]) {
        blocking_reasons.push(reason);
    }
    for reason in string_array_at(production_smoke_acceptance, &["final_x_blockers"]) {
        blocking_reasons.push(reason);
    }
    for item in &required_evidence {
        if item.get("state").and_then(Value::as_str) != Some("accepted") {
            if let Some(id) = item.get("id").and_then(Value::as_str) {
                blocking_reasons.push(format!("{id}_not_accepted"));
            }
        }
    }
    blocking_reasons.sort();
    blocking_reasons.dedup();

    let final_x_eligible = acceptance_requested
        && artifact_read
        && smoke_passed
        && !simulation
        && !fixture_artifact
        && all_required_accepted;

    json!({
        "contract": "clickhouse_log_store_final_closure_audit_v1",
        "target_todo": "E15-005",
        "final_x_eligible": final_x_eligible,
        "blocking_reasons": blocking_reasons,
        "required_evidence": required_evidence,
        "production_smoke_acceptance_state": {
            "requested": acceptance_requested,
            "artifact_read": artifact_read,
            "evidence_accepted_for_review": bool_path_at(production_smoke_acceptance, &["production_smoke_evidence_accepted_for_review"]),
            "production_smoke_passed": smoke_passed,
            "simulation_can_mark_final_x": false,
            "fixture_can_mark_final_x": false,
            "handoff_can_mark_final_x": false,
            "audit_without_real_artifact_can_mark_final_x": false,
            "refusal_can_mark_final_x": false
        },
        "writer_insert_readback_state": final_closure_state(&matrix, "writer_counts"),
        "db_cursor_state": final_closure_state(&matrix, "db_cursor"),
        "wal_append_replay_send_ack_state": final_closure_state(&matrix, "wal_replay_send_ack"),
        "dedup_journal_state": final_closure_state(&matrix, "dedup_journal"),
        "retention_load_state": final_closure_state(&matrix, "retention_load"),
        "secret_safe_omission_state": final_closure_state(&matrix, "secret_safe"),
        "artifact_provenance": {
            "generated_at_utc": production_smoke_acceptance
                .get("artifact_provenance")
                .and_then(|value| value.get("generated_at_utc"))
                .and_then(Value::as_str),
            "current_commit": production_smoke_acceptance
                .get("artifact_provenance")
                .and_then(|value| value.get("current_commit"))
                .and_then(Value::as_str),
            "runtime_commit": production_smoke_acceptance
                .get("artifact_provenance")
                .and_then(|value| value.get("runtime_commit"))
                .and_then(Value::as_str),
            "simulated": simulation,
            "fixture_artifact": fixture_artifact,
            "artifact_scope": str_path_at(production_smoke_acceptance, &["path_gate", "artifact_scope"]),
            "artifact_sha256": production_smoke_acceptance.get("artifact_sha256").and_then(Value::as_str)
        },
        "counts": production_smoke_acceptance.get("counts").cloned().unwrap_or_else(|| json!({})),
        "default_side_effects": {
            "artifact_read_default": false,
            "clickhouse_connected": false,
            "network_requests": false,
            "production_wal_root_writes": false,
            "db_reads": false,
            "db_writes": false,
            "queue_writes": false
        },
        "next_commands": {
            "handoff": "ai-worker clickhouse-log-store --production-smoke-handoff --input <json>",
            "final_closure_audit_default": "ai-worker clickhouse-log-store --final-closure-audit --input <json>",
            "read_artifact": "ai-worker clickhouse-log-store --final-closure-audit --read-production-smoke-artifact <repo/.tmp/production-smoke.json> --input <json>",
            "live_smoke_opt_in_shape": production_smoke_handoff
                .get("preflight_command_shape")
                .and_then(|value| value.get("future_live_smoke_command"))
                .and_then(Value::as_str)
                .unwrap_or("ai-worker clickhouse-log-store --execute --production-smoke --force --input <json> --artifact <repo/.tmp/proof.json>"),
            "artifact_path_safety": "artifact readback accepts repo-relative .tmp/**.json or tests/fixtures/**.json only; production WAL root paths are refused"
        },
        "audit_boundaries": {
            "default_reads_artifact": false,
            "default_connects_clickhouse": false,
            "default_network_requests": false,
            "default_writes_production_wal_root": false,
            "explicit_artifact_readback_required": true,
            "simulation_can_mark_final_x": false,
            "fixture_can_mark_final_x": false,
            "handoff_can_mark_final_x": false,
            "audit_without_real_artifact_can_mark_final_x": false,
            "refusal_can_mark_final_x": false,
            "watcher_can_mark_final_x": false,
            "final_x_requires_real_writer_cursor_wal_dedup_load_retention_secret_safe": true
        }
    })
}

fn final_closure_required_evidence(matrix: &Value) -> Vec<Value> {
    vec![
        final_closure_evidence_item(
            "writer_insert_readback",
            "real ClickHouse writer insert count equals readback count",
            final_closure_matrix_state(matrix, "writer_counts"),
        ),
        final_closure_evidence_item(
            "db_cursor",
            "DB changefeed/export cursor position and lag are present",
            final_closure_matrix_state(matrix, "db_cursor"),
        ),
        final_closure_evidence_item(
            "wal_append_replay_send_ack",
            "WAL append/replay/send/ack counts are present",
            final_closure_matrix_state(matrix, "wal_replay_send_ack"),
        ),
        final_closure_evidence_item(
            "dedup_journal",
            "dedup hit/miss counts and journal persistence are present",
            final_closure_matrix_state(matrix, "dedup_journal"),
        ),
        final_closure_evidence_item(
            "retention_load",
            "retention readback and load smoke duration/count are present",
            final_closure_matrix_state(matrix, "retention_load"),
        ),
        final_closure_evidence_item(
            "secret_safe_omission",
            "artifact omits secrets, raw DSN, auth headers, env values, and payload body",
            final_closure_matrix_state(matrix, "secret_safe"),
        ),
        final_closure_evidence_item(
            "fresh_current_commit",
            "generated_at/current commit/runtime commit prove fresh non-stale evidence",
            final_closure_matrix_state(matrix, "freshness"),
        ),
        final_closure_evidence_item(
            "non_simulated",
            "artifact is real production smoke evidence, not a simulation fixture",
            final_closure_matrix_state(matrix, "non_simulated"),
        ),
    ]
}

fn final_closure_evidence_item(
    id: &'static str,
    requirement: &'static str,
    state: &'static str,
) -> Value {
    json!({
        "id": id,
        "requirement": requirement,
        "state": state,
        "required_for_final_x": true
    })
}

fn final_closure_state(matrix: &Value, key: &str) -> Value {
    json!({
        "state": final_closure_matrix_state(matrix, key),
        "required_for_final_x": true
    })
}

fn final_closure_matrix_state(matrix: &Value, key: &str) -> &'static str {
    match matrix.get(key).and_then(Value::as_str) {
        Some("accepted") => "accepted",
        Some("refused") => "refused",
        _ => "missing",
    }
}

fn clickhouse_production_smoke_evidence_watcher(production_smoke_handoff: &Value) -> Value {
    json!({
        "contract": "clickhouse_log_store_production_smoke_evidence_watcher_v1",
        "mode": "watcher_checklist_only",
        "target_todo": "E15-005",
        "final_x_eligible": false,
        "status": "blocked_waiting_for_real_production_smoke_artifact",
        "blocking_reasons": [
            "missing_real_clickhouse_writer_evidence",
            "missing_db_changefeed_or_export_cursor_evidence",
            "missing_production_wal_replay_send_ack_evidence",
            "missing_dedup_journal_persistence_evidence",
            "missing_retention_load_smoke_evidence"
        ],
        "safe_defaults": {
            "artifact_read_default": false,
            "clickhouse_connected": false,
            "network_requests": false,
            "production_wal_root_writes": false,
            "db_reads": false,
            "db_writes": false,
            "queue_writes": false,
            "watcher_can_mark_final_x": false,
            "simulation_can_mark_final_x": false,
            "fixture_can_mark_final_x": false,
            "handoff_can_mark_final_x": false,
            "audit_without_real_artifact_can_mark_final_x": false,
            "refusal_can_mark_final_x": false
        },
        "expected_artifact_paths": {
            "operator_handoff_artifact": ".tmp/clickhouse-log-store/production-smoke/<run_id>.json",
            "final_review_readback_artifact": ".tmp/clickhouse-log-store/production-smoke/<run_id>.json",
            "production_wal_root": "AI_GATEWAY_CLICKHOUSE_WAL_DIR or AI_GATEWAY_CLICKHOUSE_LOG_STORE_WAL_DIR; production root only, never .tmp",
            "dedup_journal_path": "<production_wal_root>/dedup-journal.jsonl or configured production dedup journal path",
            "artifact_path_safety": "watcher does not read artifacts; final audit readback only accepts repo-relative .tmp/**.json or tests/fixtures/**.json, and fixtures cannot mark final [x]"
        },
        "required_artifact_fields": production_smoke_required_artifact_fields(),
        "required_evidence_checklist": [
            {
                "id": "writer_insert_readback",
                "state": "waiting_for_artifact",
                "required_fields": ["writer_insert_count", "writer_readback_count"],
                "final_requirement": "real ClickHouse writer insert count equals readback count"
            },
            {
                "id": "db_cursor",
                "state": "waiting_for_artifact",
                "required_fields": ["cursor_position", "cursor_lag_rows"],
                "final_requirement": "DB changefeed/export cursor position and lag are present"
            },
            {
                "id": "wal_append_replay_send_ack",
                "state": "waiting_for_artifact",
                "required_fields": ["wal_append_count", "wal_replay_count", "wal_send_count", "wal_ack_count"],
                "final_requirement": "production WAL append/replay/send/ack counts are present"
            },
            {
                "id": "dedup_journal",
                "state": "waiting_for_artifact",
                "required_fields": ["dedup_hit_count", "dedup_miss_count", "dedup_journal_persisted"],
                "final_requirement": "dedup journal persists and hit/miss evidence is present"
            },
            {
                "id": "retention_load",
                "state": "waiting_for_artifact",
                "required_fields": ["retention_readback_count", "load_smoke_duration_ms", "load_smoke_record_count"],
                "final_requirement": "retention readback and bounded load smoke evidence are present"
            },
            {
                "id": "secret_safe",
                "state": "waiting_for_artifact",
                "required_fields": ["secret_safe_omissions"],
                "final_requirement": "artifact omits secrets, raw DSN, auth headers, env values, and payload body"
            },
            {
                "id": "fresh_non_simulated",
                "state": "waiting_for_artifact",
                "required_fields": ["generated_at_utc", "current_commit", "runtime_commit", "simulated"],
                "final_requirement": "artifact is fresh, current commit matches runtime commit, and simulated=false"
            }
        ],
        "operator_actions": [
            "run production smoke only outside this dry-run watcher with explicit live opt-in",
            "collect writer/cursor/WAL/dedup/retention-load evidence into the expected artifact path",
            "omit secrets, raw DSN, auth headers, env values, and payload body from the artifact",
            "run final closure audit readback against the bounded artifact path"
        ],
        "next_commands": {
            "watcher": "ai-worker clickhouse-log-store --evidence-watcher --input <json>",
            "handoff": "ai-worker clickhouse-log-store --production-smoke-handoff --input <json>",
            "live_smoke_opt_in_shape": production_smoke_handoff
                .get("preflight_command_shape")
                .and_then(|value| value.get("future_live_smoke_command"))
                .and_then(Value::as_str)
                .unwrap_or("ai-worker clickhouse-log-store --execute --production-smoke --force --input <json> --artifact <repo/.tmp/proof.json>"),
            "final_audit_readback": "ai-worker clickhouse-log-store --final-closure-audit --read-production-smoke-artifact <repo/.tmp/production-smoke.json> --input <json>",
            "execute_refusal_check": "ai-worker clickhouse-log-store --production-smoke --force --input <json>"
        },
        "final_review_checklist": {
            "requires_real_clickhouse_writer": true,
            "requires_db_changefeed_or_export_cursor": true,
            "requires_production_wal_replay_send_ack": true,
            "requires_dedup_journal_persistence": true,
            "requires_retention_load_smoke": true,
            "requires_secret_safe_proof": true,
            "simulation_or_fixture_or_handoff_or_watcher_can_close": false,
            "use_final_closure_audit_after_artifact_arrives": true
        }
    })
}

fn production_smoke_artifact_path_gate(path: &str) -> Value {
    let trimmed = path.trim();
    let parent_traversal = artifact_path_has_parent_traversal(trimmed);
    let repo_relative = is_repo_relative_artifact_path(trimmed);
    let scope_allowed = trimmed.starts_with(".tmp/")
        || trimmed.starts_with(".tmp\\")
        || trimmed.starts_with("tests/fixtures/");
    let json_file = trimmed.ends_with(".json");
    let allowed = repo_relative && !parent_traversal && scope_allowed && json_file;

    json!({
        "allowed": allowed,
        "repo_relative": repo_relative,
        "scope_allowed": scope_allowed,
        "artifact_scope": if trimmed.starts_with("tests/fixtures/") { "tests/fixtures" } else { ".tmp" },
        "json_file": json_file,
        "absolute_path_allowed": false,
        "parent_traversal_allowed": false,
        "production_wal_root_allowed": false
    })
}

fn is_repo_relative_artifact_path(path: &str) -> bool {
    let trimmed = path.trim();
    !trimmed.is_empty()
        && !trimmed.starts_with('/')
        && !trimmed.starts_with('\\')
        && !trimmed.starts_with("//")
        && !trimmed.starts_with("\\\\")
        && !trimmed.as_bytes().get(1).is_some_and(|byte| *byte == b':')
}

fn artifact_path_has_parent_traversal(path: &str) -> bool {
    path.split(['/', '\\']).any(|component| component == "..")
}

fn accepted_or_refused(accepted: bool) -> &'static str {
    if accepted { "accepted" } else { "refused" }
}

fn secret_safe_omissions_present(artifact: &Value) -> bool {
    let Some(omissions) = artifact
        .get("secret_safe_omissions")
        .and_then(Value::as_array)
    else {
        return false;
    };
    [
        "clickhouse_password",
        "clickhouse_token",
        "authorization_header",
        "payload_body",
        "env_values",
    ]
    .iter()
    .all(|required| {
        omissions
            .iter()
            .any(|value| value.as_str() == Some(*required))
    })
}

fn wal_runtime_safe_path_gate(path_safety: &Value, wal_root: &str, segment_name: &str) -> Value {
    let observability_repo_local_safe = bool_path_at(path_safety, &["repo_local_safe"]);
    let tmp_scoped =
        wal_root == ".tmp" || wal_root.starts_with(".tmp/") || wal_root.starts_with(".tmp\\");
    let segment_jsonl = segment_name.starts_with("wal-") && segment_name.ends_with(".jsonl");
    let allowed = observability_repo_local_safe && tmp_scoped && segment_jsonl;

    json!({
        "allowed": allowed,
        "requires_explicit_opt_in": true,
        "observability_repo_local_safe": observability_repo_local_safe,
        "artifact_scope": ".tmp",
        "wal_root_tmp_scoped": tmp_scoped,
        "segment_jsonl": segment_jsonl,
        "absolute_path_allowed": false,
        "parent_traversal_allowed": false,
        "production_wal_root_allowed": false
    })
}

fn ensure_path_stays_under_tmp(path: &Path) -> Result<(), String> {
    let current_dir = std::env::current_dir().map_err(|error| {
        format!(
            "failed to resolve current directory for ClickHouse WAL artifact safety: {}",
            super::safe_error_text(&error.to_string())
        )
    })?;
    let tmp_root = current_dir.join(".tmp");
    let canonical_tmp_root = tmp_root.canonicalize().map_err(|error| {
        format!(
            "failed to resolve ClickHouse WAL .tmp root `{}`: {}",
            super::safe_plan_text(&tmp_root.display().to_string()),
            super::safe_error_text(&error.to_string())
        )
    })?;
    let canonical_path = path.canonicalize().map_err(|error| {
        format!(
            "failed to resolve ClickHouse WAL artifact path `{}`: {}",
            super::safe_plan_text(&path.display().to_string()),
            super::safe_error_text(&error.to_string())
        )
    })?;

    if canonical_path.starts_with(&canonical_tmp_root) {
        Ok(())
    } else {
        Err(format!(
            "ClickHouse WAL artifact path `{}` escaped repo .tmp scope",
            super::safe_plan_text(&path.display().to_string())
        ))
    }
}

fn json_lines(records: &[Value]) -> Result<String, String> {
    let mut output = String::new();
    for record in records {
        let line = serde_json::to_string(record).map_err(|error| {
            format!(
                "failed to serialize ClickHouse WAL artifact record: {}",
                super::safe_error_text(&error.to_string())
            )
        })?;
        output.push_str(&line);
        output.push('\n');
    }
    Ok(output)
}

fn journal_lines(records: &[Value]) -> Result<String, String> {
    let mut entries = BTreeMap::<String, Value>::new();
    for record in records {
        let key = format!(
            "{}|{}",
            str_path_at(record, &["sink"]).unwrap_or("unknown"),
            str_path_at(record, &["record_hash"]).unwrap_or("unknown")
        );
        entries.entry(key).or_insert_with(|| {
            json!({
                "sink": str_path_at(record, &["sink"]).unwrap_or("unknown"),
                "wal_sequence": record.get("wal_sequence").and_then(Value::as_u64).unwrap_or(0),
                "record_hash": str_path_at(record, &["record_hash"]).unwrap_or("unknown"),
                "payload_hash": str_path_at(record, &["payload_hash"]).unwrap_or("unknown"),
                "journal_decision": str_path_at(record, &["journal_decision"]).unwrap_or("unknown"),
                "status_after": str_path_at(record, &["status_after"]).unwrap_or("unknown")
            })
        });
    }
    let values = entries.into_values().collect::<Vec<_>>();
    json_lines(&values)
}

fn write_file_synced(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let mut file = File::create(path).map_err(|error| {
        format!(
            "failed to create ClickHouse WAL artifact `{}`: {}",
            super::safe_plan_text(&path.display().to_string()),
            super::safe_error_text(&error.to_string())
        )
    })?;
    file.write_all(bytes).map_err(|error| {
        format!(
            "failed to write ClickHouse WAL artifact `{}`: {}",
            super::safe_plan_text(&path.display().to_string()),
            super::safe_error_text(&error.to_string())
        )
    })?;
    file.sync_all().map_err(|error| {
        format!(
            "failed to sync ClickHouse WAL artifact `{}`: {}",
            super::safe_plan_text(&path.display().to_string()),
            super::safe_error_text(&error.to_string())
        )
    })
}

fn parse_json_lines(body: &str) -> Result<Vec<Value>, String> {
    body.lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            serde_json::from_str::<Value>(line).map_err(|error| {
                format!(
                    "failed to parse ClickHouse WAL artifact readback line: {}",
                    super::safe_error_text(&error.to_string())
                )
            })
        })
        .collect()
}

fn required_json_str<'a>(value: &'a Value, key: &'static str) -> Result<&'a str, String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("wal runtime writer requires `{key}`"))
}

fn bool_path_at(value: &Value, path: &[&str]) -> bool {
    path.iter()
        .try_fold(value, |value, key| value.get(*key))
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

fn str_path_at<'a>(value: &'a Value, path: &[&str]) -> Option<&'a str> {
    path.iter()
        .try_fold(value, |value, key| value.get(*key))
        .and_then(Value::as_str)
}

fn string_array_at(value: &Value, path: &[&str]) -> Vec<String> {
    path.iter()
        .try_fold(value, |value, key| value.get(*key))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(ToOwned::to_owned)
        .collect()
}

fn table_mapping_from_config(config: &Value) -> Vec<ClickHouseTableMappingPlan> {
    let database = string_at(config, "database").unwrap_or_else(|| "ai_gateway".to_string());
    let payload_policy = config
        .get("payload_policy")
        .cloned()
        .unwrap_or_else(|| json!({}));

    config
        .get("sinks")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|sink| {
            let name = sink.get("name")?.as_str()?.to_string();
            let table = sink.get("table")?.as_str()?.to_string();
            Some(ClickHouseTableMappingPlan {
                source_relation: name.clone(),
                qualified_target_table: format!("{database}.{table}"),
                target_database: database.clone(),
                target_table: table,
                schema_version: sink
                    .get("schema_version")
                    .and_then(Value::as_u64)
                    .unwrap_or(1),
                enabled: sink
                    .get("enabled")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
                dedup_key_fields: dedup_key_fields(&name),
                payload_policy: payload_policy.clone(),
                payload_body_written: false,
                sink: name,
            })
        })
        .collect()
}

fn dedup_key_fields(sink: &str) -> Vec<&'static str> {
    match sink {
        "provider_attempts" => vec!["tenant_id", "request_id", "provider_attempt_id"],
        "event_log" => vec!["tenant_id", "event_id", "event_type"],
        _ => vec!["tenant_id", "request_id"],
    }
}

fn drop_policy_to_overflow_action(drop_policy: &str) -> String {
    match drop_policy {
        "drop_oldest" => "evict_oldest_unflushed_record",
        "block" => "block_producer_until_capacity",
        _ => "drop_newest_record",
    }
    .to_string()
}

fn bool_at(value: &Value, key: &str) -> bool {
    value.get(key).and_then(Value::as_bool).unwrap_or(false)
}

fn u64_at(value: &Value, key: &str) -> u64 {
    value.get(key).and_then(Value::as_u64).unwrap_or(0)
}

fn u64_nested_at(value: &Value, section: &str, key: &str) -> u64 {
    value
        .get(section)
        .and_then(|value| value.get(key))
        .and_then(Value::as_u64)
        .unwrap_or(0)
}

fn string_at(value: &Value, key: &str) -> Option<String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(super::safe_plan_text)
}

fn string_nested_at(value: &Value, section: &str, key: &str) -> Option<String> {
    value
        .get(section)
        .and_then(|value| value.get(key))
        .and_then(Value::as_str)
        .map(super::safe_plan_text)
}

#[cfg(test)]
mod tests {
    use super::*;

    const TENANT_ID: Uuid = Uuid::from_u128(0x00000000_0000_0000_0000_000000000001);

    #[test]
    fn fixture_builds_secret_safe_ingestion_plan() {
        let fixture = fixture();
        let input = clickhouse_log_store_input_from_json_str(include_str!(
            "../../../tests/fixtures/worker/clickhouse_log_store_plan_contract.json"
        ))
        .expect("fixture should parse");
        let plan = clickhouse_log_store_plan(
            None,
            ClickHouseLogStoreInputSource::InputJson {
                path: "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string(),
            },
            input,
        )
        .expect("plan should build");

        assert_eq!(plan.schema_version, "clickhouse_log_store_worker_plan.v1");
        assert!(plan.dry_run);
        assert!(plan.read_only);
        assert!(!plan.runtime_connected);
        assert!(!plan.db_reads);
        assert!(!plan.db_writes);
        assert!(!plan.queue_writes);
        assert!(!plan.file_system_writes);
        assert!(!plan.outbound_calls);
        assert!(!plan.network_requests);
        assert_eq!(plan.tenant_id, TENANT_ID);
        assert_eq!(plan.source.env_key_count, 19);
        assert!(!plan.source.env_values_output);
        assert_eq!(
            plan.clickhouse_config["contract"].as_str(),
            Some(CLICKHOUSE_LOG_STORE_CONTRACT_VERSION)
        );
        assert_eq!(plan.clickhouse_config["enabled"].as_bool(), Some(true));
        assert_eq!(
            plan.clickhouse_config["endpoint"].as_str(),
            fixture["expected_output_contract"]["clickhouse_config"]["endpoint"].as_str()
        );
        assert!(
            !plan.clickhouse_config["network_requests"]
                .as_str()
                .unwrap()
                .is_empty()
        );
        assert!(!plan.ingestion.execute_supported);
        assert!(!plan.ingestion.writer_supported);
        assert!(!plan.ingestion.queue_write_supported);
        assert_eq!(plan.queue.max_queue_rows, 42);
        assert_eq!(plan.queue.batch_size, 2500);
        assert_eq!(plan.queue.flush_interval_ms, 750);
        assert!(plan.durable_queue.planned);
        assert!(!plan.durable_queue.enabled_in_this_slice);
        assert!(!plan.durable_queue.execute_supported);
        assert!(!plan.durable_queue.file_system_writes);
        assert_eq!(
            plan.durable_queue.wal_directory.root,
            "AI_GATEWAY_CLICKHOUSE_WAL_DIR or <data_dir>/clickhouse-log-store/wal"
        );
        assert_eq!(
            plan.durable_queue.wal_directory.tenant_partition,
            "tenant_id=00000000-0000-0000-0000-000000000001"
        );
        assert!(!plan.durable_queue.wal_directory.creates_directories);
        assert!(!plan.durable_queue.wal_directory.writes_files);
        assert_eq!(
            plan.wal_service_guard,
            fixture["expected_wal_service_guard"]
        );
        assert_eq!(plan.wal_service_guard["readiness"], "ready");
        assert_eq!(
            plan.wal_service_guard["production_wal_writes_enabled_in_this_slice"],
            false
        );
        assert_eq!(
            plan.wal_service_guard["production_service_readiness"]["ready"],
            true
        );
        assert_eq!(
            plan.wal_service_guard["runtime_artifact_path_contract"]["can_satisfy_production_wal_root"],
            false
        );
        assert_eq!(
            plan.wal_service_guard["runtime_artifact_path_contract"]["repo_bounded_runtime_artifact_allowed"],
            true
        );
        assert_eq!(
            plan.wal_dry_run_readback["contract"].as_str(),
            Some(CLICKHOUSE_WAL_DRY_RUN_READBACK_CONTRACT_VERSION)
        );
        assert_eq!(
            plan.wal_dry_run_readback["requested"].as_bool(),
            Some(false)
        );
        assert_eq!(
            plan.wal_dry_run_readback["file_system_writes"].as_bool(),
            Some(false)
        );
        assert_eq!(plan.wal_runtime_writer["requested"].as_bool(), Some(false));
        assert_eq!(
            plan.wal_runtime_writer["file_system_writes"].as_bool(),
            Some(false)
        );
        assert_eq!(
            plan.wal_service_execution["requested"].as_bool(),
            Some(false)
        );
        assert_eq!(
            plan.wal_service_execution["file_system_writes"].as_bool(),
            Some(false)
        );
        assert_eq!(
            plan.final_dod_matrix["contract"].as_str(),
            Some("clickhouse_log_store_final_dod_matrix_v1")
        );
        assert_eq!(
            plan.final_dod_matrix["readiness_and_artifact_proof_scope"]["can_mark_final_x"],
            false
        );
        assert_eq!(
            plan.final_dod_matrix["acceptance_matrix"]
                .as_array()
                .expect("acceptance matrix")
                .len(),
            8
        );
        assert_eq!(
            plan.production_smoke_handoff["contract"].as_str(),
            Some("clickhouse_log_store_production_smoke_handoff_v1")
        );
        assert_eq!(
            plan.production_smoke_handoff["default_side_effects"]["network_requests"],
            false
        );
        assert!(plan.durable_queue.disk_budget.bounded_disk);
        assert_eq!(plan.durable_queue.disk_budget.max_unacked_records, 42);
        assert_eq!(
            plan.durable_queue.enqueue.idempotency_key_fields,
            vec!["tenant_id", "sink", "dedup_key", "record_hash"]
        );
        assert_eq!(
            plan.durable_queue.ack.idempotency_key_fields,
            vec!["tenant_id", "wal_sequence", "sink", "dedup_key"]
        );
        assert_eq!(plan.durable_queue.retry.max_attempts, 5);
        assert_eq!(
            plan.durable_queue.dedup_journal_linkage.journal_key_fields,
            vec!["tenant_id", "sink", "dedup_key"]
        );
        assert!(
            plan.durable_queue
                .load_safety
                .replay_requires_dedup_journal_check
        );
        assert!(!plan.durable_queue.wal_record_shape.payload_body_written);
        assert!(
            !plan
                .durable_queue
                .wal_record_shape
                .credential_material_written
        );
        assert_eq!(plan.backpressure.drop_policy, "drop_oldest");
        assert_eq!(
            plan.backpressure.overflow_action,
            "evict_oldest_unflushed_record"
        );
        assert!(plan.dedup.enabled);
        assert_eq!(plan.dedup.per_sink_keys.len(), 3);
        assert_eq!(plan.table_mapping.len(), 3);
        assert_eq!(
            plan.table_mapping[0].qualified_target_table,
            "prod_logs.gateway_events_request_logs"
        );
        assert!(!plan.table_mapping[0].payload_body_written);
        assert!(plan.contract.config_validated_by_observability_crate);
        assert!(plan.contract.network_requests_disabled);
        assert!(plan.contract.db_writes_disabled);
        assert!(plan.contract.queue_writes_disabled);
        assert!(plan.contract.file_system_writes_disabled);
        assert!(plan.contract.credential_material_omitted);
        assert!(plan.contract.env_values_omitted);
    }

    #[test]
    fn fixture_builds_bounded_wal_dry_run_readback_contract() {
        let fixture = fixture();
        let input = clickhouse_log_store_input_from_json_str(include_str!(
            "../../../tests/fixtures/worker/clickhouse_log_store_plan_contract.json"
        ))
        .expect("fixture should parse");
        let plan = clickhouse_log_store_plan_with_readback(
            None,
            ClickHouseLogStoreInputSource::InputJson {
                path: "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string(),
            },
            input,
            true,
        )
        .expect("readback plan should build");
        let expected = &fixture["expected_readback_contract"];
        let readback = &plan.wal_dry_run_readback;

        assert_eq!(plan.mode, "dry_run_readback");
        assert_eq!(readback["contract"], expected["contract"]);
        assert_eq!(readback["mode"], expected["mode"]);
        assert_eq!(readback["read_only"], true);
        assert_eq!(readback["network_requests"], false);
        assert_eq!(readback["file_system_writes"], false);
        assert_eq!(
            readback["path_safety"]["repo_local_safe"],
            expected["path_safety"]["repo_local_safe"]
        );
        assert_eq!(
            readback["path_safety"]["segment_relative_path"],
            expected["path_safety"]["segment_relative_path"]
        );
        assert_eq!(
            readback["segment"]["record_count"],
            expected["segment"]["record_count"]
        );
        assert_eq!(readback["segment"]["bounded_disk"], true);
        assert_eq!(readback["segment"]["within_segment_budget"], true);
        assert_eq!(readback["segment"]["dry_run_writes_segment"], false);
        assert_eq!(plan.wal_runtime_writer["requested"], false);
        assert_eq!(plan.wal_runtime_writer["file_system_writes"], false);
        assert_eq!(
            readback["write_readback_evidence"]["readback_hash_match_count"],
            expected["write_readback_evidence"]["readback_hash_match_count"]
        );
        assert_eq!(
            readback["write_readback_evidence"]["dedup_journal_entries"],
            expected["write_readback_evidence"]["dedup_journal_entries"]
        );
        assert_eq!(
            readback["write_readback_evidence"]["records"][3]["journal_decision"],
            "skip_duplicate_same_record_hash"
        );
        assert_eq!(
            readback["retention"]["classification_counts"],
            expected["retention"]["classification_counts"]
        );
        assert_eq!(
            readback["retention"]["safe_to_delete_segment"],
            expected["retention"]["safe_to_delete_segment"]
        );
    }

    #[test]
    fn fixture_runtime_wal_writer_requires_opt_in_and_writes_repo_tmp_artifact() {
        cleanup_runtime_wal_fixture();
        let fixture = fixture();
        let input = clickhouse_log_store_input_from_json_str(include_str!(
            "../../../tests/fixtures/worker/clickhouse_log_store_plan_contract.json"
        ))
        .expect("fixture should parse");
        let plan = clickhouse_log_store_plan_with_runtime_wal(
            None,
            ClickHouseLogStoreInputSource::InputJson {
                path: "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string(),
            },
            input,
            true,
            true,
        )
        .expect("runtime wal artifact plan should build");
        let expected = &fixture["expected_runtime_writer_contract"];
        let writer = &plan.wal_runtime_writer;

        assert_eq!(plan.mode, "runtime_wal_artifact");
        assert!(plan.file_system_writes);
        assert_eq!(writer["contract"], expected["contract"]);
        assert_eq!(writer["mode"], expected["mode"]);
        assert_eq!(writer["opt_in"], true);
        assert_eq!(writer["network_requests"], false);
        assert_eq!(writer["db_writes"], false);
        assert_eq!(writer["queue_writes"], false);
        assert_eq!(writer["file_system_writes"], true);
        assert_eq!(
            writer["safe_path_gate"]["allowed"],
            expected["safe_path_gate"]["allowed"]
        );
        assert_eq!(
            writer["safe_path_gate"]["artifact_scope"],
            expected["safe_path_gate"]["artifact_scope"]
        );
        assert_eq!(
            writer["safe_path_gate"]["production_wal_root_allowed"],
            false
        );
        assert_eq!(
            writer["artifact_readback"]["record_count"],
            expected["artifact_readback"]["record_count"]
        );
        assert_eq!(
            writer["artifact_readback"]["readback_hash_match_count"],
            expected["artifact_readback"]["readback_hash_match_count"]
        );
        assert_eq!(
            writer["artifact_readback"]["ack_retry_evidence_preserved"],
            expected["artifact_readback"]["ack_retry_evidence_preserved"]
        );
        assert_eq!(
            writer["artifact_readback"]["dedup_duplicate_evidence_preserved"],
            expected["artifact_readback"]["dedup_duplicate_evidence_preserved"]
        );
        assert_eq!(
            writer["artifact_readback"]["journal_entry_count"],
            expected["artifact_readback"]["journal_entry_count"]
        );
        assert!(
            std::path::Path::new(
                writer["artifact_paths"]["segment_path"]
                    .as_str()
                    .expect("segment path")
            )
            .exists()
        );
        assert!(
            std::path::Path::new(
                writer["artifact_paths"]["dedup_journal_path"]
                    .as_str()
                    .expect("journal path")
            )
            .exists()
        );
        cleanup_runtime_wal_fixture();
    }

    #[test]
    fn runtime_wal_writer_refuses_production_root_for_artifact_mode() {
        let mut fixture = fixture();
        fixture["input"]["wal_dry_run_readback"]["wal_root"] =
            json!("/var/lib/ai-gateway/clickhouse-log-store/wal");
        let input = serde_json::from_value::<ClickHouseLogStoreInput>(fixture["input"].clone())
            .expect("mutated fixture input should parse");
        let error = clickhouse_log_store_plan_with_runtime_wal(
            None,
            ClickHouseLogStoreInputSource::InputJson {
                path: "fixture.json".to_string(),
            },
            input,
            true,
            true,
        )
        .expect_err("runtime artifact writer should refuse production root");

        assert!(error.contains("refused WAL path"));
        assert!(error.contains("repo-local .tmp"));
    }

    #[test]
    fn service_guard_blocks_tmp_root_even_though_runtime_artifact_can_use_tmp_with_opt_in() {
        let mut fixture = fixture();
        fixture["input"]["env"]["AI_GATEWAY_CLICKHOUSE_WAL_DIR"] =
            json!(".tmp/clickhouse-log-store/wal");
        let input = serde_json::from_value::<ClickHouseLogStoreInput>(fixture["input"].clone())
            .expect("mutated fixture input should parse");
        let plan = clickhouse_log_store_plan(
            None,
            ClickHouseLogStoreInputSource::InputJson {
                path: "fixture.json".to_string(),
            },
            input,
        )
        .expect("plan should build with blocked tmp production root");

        assert!(!plan.file_system_writes);
        assert_eq!(plan.wal_service_guard["root_scope"], "artifact_tmp");
        assert_eq!(plan.wal_service_guard["readiness"], "blocked");
        assert_eq!(
            plan.wal_service_guard["blocker"],
            "production_wal_root_points_to_artifact_tmp"
        );
        assert_eq!(
            plan.wal_service_guard["production_service_readiness"]["ready"],
            false
        );
        assert_eq!(
            plan.wal_service_guard["runtime_artifact_path_contract"]["can_satisfy_production_wal_root"],
            false
        );
        assert_eq!(
            plan.wal_service_guard["runtime_artifact_path_contract"]["requires_explicit_worker_opt_in"],
            true
        );
    }

    #[test]
    fn service_readiness_dry_run_emits_command_skeleton_without_io() {
        let fixture = fixture();
        let input = clickhouse_log_store_input_from_json_str(include_str!(
            "../../../tests/fixtures/worker/clickhouse_log_store_plan_contract.json"
        ))
        .expect("fixture should parse");
        let plan = clickhouse_log_store_plan_with_service_readiness(
            None,
            ClickHouseLogStoreInputSource::InputJson {
                path: "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string(),
            },
            input,
            false,
            false,
            true,
            false,
            false,
            false,
            false,
            false,
            None,
        )
        .expect("service readiness plan should build");
        let service = &plan.wal_service_execution;
        let expected = &fixture["expected_service_readiness_contract"];

        assert_eq!(plan.mode, "wal_service_readiness");
        assert!(!plan.file_system_writes);
        assert_eq!(service["contract"], expected["contract"]);
        assert_eq!(service["mode"], expected["mode"]);
        assert_eq!(service["file_system_writes"], false);
        assert_eq!(service["production_root_writes"], false);
        assert_eq!(service["network_requests"], false);
        assert_eq!(
            service["runtime_service_readiness"]["ready"],
            expected["runtime_service_readiness"]["ready"]
        );
        assert_eq!(service["command_skeleton"]["service_loop_started"], false);
        assert_eq!(service["readiness_artifact"]["written"], false);
    }

    #[test]
    fn service_readiness_artifact_opt_in_writes_only_repo_tmp_readback() {
        cleanup_service_readiness_fixture();
        let fixture = fixture();
        let input = clickhouse_log_store_input_from_json_str(include_str!(
            "../../../tests/fixtures/worker/clickhouse_log_store_plan_contract.json"
        ))
        .expect("fixture should parse");
        let plan = clickhouse_log_store_plan_with_service_readiness(
            None,
            ClickHouseLogStoreInputSource::InputJson {
                path: "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string(),
            },
            input,
            false,
            false,
            true,
            true,
            false,
            false,
            false,
            false,
            None,
        )
        .expect("service readiness artifact plan should build");
        let service = &plan.wal_service_execution;
        let expected = &fixture["expected_service_readiness_artifact_contract"];

        assert_eq!(plan.mode, "wal_service_readiness_artifact");
        assert!(plan.file_system_writes);
        assert_eq!(service["contract"], expected["contract"]);
        assert_eq!(service["mode"], expected["mode"]);
        assert_eq!(service["file_system_writes"], true);
        assert_eq!(service["production_root_writes"], false);
        assert_eq!(service["network_requests"], false);
        assert_eq!(
            service["readiness_artifact"]["artifact_scope"],
            expected["readiness_artifact"]["artifact_scope"]
        );
        assert_eq!(
            service["readiness_artifact"]["readback_schema_matches"],
            true
        );
        assert_eq!(
            service["readiness_artifact"]["readback_tenant_matches"],
            true
        );
        assert_eq!(
            service["readiness_artifact"]["production_wal_root_allowed"],
            false
        );
        assert!(
            std::path::Path::new(
                service["readiness_artifact"]["path"]
                    .as_str()
                    .expect("readiness artifact path")
            )
            .exists()
        );
        cleanup_service_readiness_fixture();
    }

    #[test]
    fn final_dod_matrix_separates_production_ready_from_final_x() {
        let fixture = fixture();
        let input = clickhouse_log_store_input_from_json_str(include_str!(
            "../../../tests/fixtures/worker/clickhouse_log_store_plan_contract.json"
        ))
        .expect("fixture should parse");
        let plan = clickhouse_log_store_plan(
            None,
            ClickHouseLogStoreInputSource::InputJson {
                path: "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string(),
            },
            input,
        )
        .expect("plan should build");
        let matrix = &plan.final_dod_matrix;
        let expected = &fixture["expected_final_dod_matrix"];

        assert_eq!(matrix["contract"], expected["contract"]);
        assert_eq!(
            matrix["current_contract_stage"],
            expected["current_contract_stage"]
        );
        assert_eq!(
            matrix["readiness_and_artifact_proof_scope"]["can_mark_production_ready"],
            true
        );
        assert_eq!(
            matrix["readiness_and_artifact_proof_scope"]["can_mark_final_x"],
            false
        );
        assert_eq!(
            matrix["acceptance_matrix"]
                .as_array()
                .expect("acceptance matrix")
                .iter()
                .filter(|item| item["requires_live_runtime"].as_bool() == Some(true))
                .count(),
            6
        );
        assert_eq!(
            matrix["final_x_requires"]
                .as_array()
                .expect("final requirements")
                .len(),
            8
        );
        assert_eq!(
            matrix["remaining_blockers"]
                .as_array()
                .expect("remaining blockers")
                .len(),
            6
        );
    }

    #[test]
    fn final_closure_audit_defaults_to_blocked_without_artifact_read() {
        let input = clickhouse_log_store_input_from_json_str(include_str!(
            "../../../tests/fixtures/worker/clickhouse_log_store_plan_contract.json"
        ))
        .expect("fixture should parse");
        let plan = clickhouse_log_store_plan(
            None,
            ClickHouseLogStoreInputSource::InputJson {
                path: "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string(),
            },
            input,
        )
        .expect("plan should build");
        let audit = &plan.final_closure_audit;

        assert_eq!(
            audit["contract"],
            "clickhouse_log_store_final_closure_audit_v1"
        );
        assert_eq!(audit["final_x_eligible"], false);
        assert_eq!(
            audit["production_smoke_acceptance_state"]["artifact_read"],
            false
        );
        assert_eq!(
            audit["audit_boundaries"]["default_connects_clickhouse"],
            false
        );
        assert_eq!(audit["audit_boundaries"]["default_network_requests"], false);
        assert_eq!(
            audit["audit_boundaries"]["default_writes_production_wal_root"],
            false
        );
        assert_eq!(audit["audit_boundaries"]["fixture_can_mark_final_x"], false);
        assert_eq!(audit["audit_boundaries"]["handoff_can_mark_final_x"], false);
        assert_eq!(
            audit["audit_boundaries"]["audit_without_real_artifact_can_mark_final_x"],
            false
        );
        assert_eq!(audit["audit_boundaries"]["refusal_can_mark_final_x"], false);
        assert_eq!(audit["audit_boundaries"]["watcher_can_mark_final_x"], false);
        assert!(
            audit["blocking_reasons"]
                .as_array()
                .expect("blocking reasons")
                .iter()
                .any(|reason| reason.as_str() == Some("missing_production_smoke_artifact"))
        );
        assert_eq!(
            audit["required_evidence"]
                .as_array()
                .expect("required evidence")
                .len(),
            8
        );
        assert_eq!(
            audit["next_commands"]["final_closure_audit_default"],
            "ai-worker clickhouse-log-store --final-closure-audit --input <json>"
        );
    }

    #[test]
    fn final_closure_audit_keeps_simulation_blocked() {
        let audit_fixture_dir = PathBuf::from(".tmp")
            .join("clickhouse-log-store")
            .join("final-closure-audit");
        let _ = fs::remove_dir_all(&audit_fixture_dir);
        let artifact_dir = PathBuf::from(".tmp")
            .join("clickhouse-log-store")
            .join("final-closure-audit");
        fs::create_dir_all(&artifact_dir).expect("artifact directory should be created");
        let artifact_path = artifact_dir.join("accepted-simulation.json");
        write_file_synced(
            &artifact_path,
            include_bytes!(
                "../../../tests/fixtures/worker/clickhouse_production_smoke_artifact_accepted_simulation.json"
            ),
        )
        .expect("simulation artifact should be written");
        let input = clickhouse_log_store_input_from_json_str(include_str!(
            "../../../tests/fixtures/worker/clickhouse_log_store_plan_contract.json"
        ))
        .expect("fixture should parse");
        let plan = clickhouse_log_store_plan_with_service_readiness(
            None,
            ClickHouseLogStoreInputSource::InputJson {
                path: "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string(),
            },
            input,
            false,
            false,
            false,
            false,
            false,
            false,
            false,
            false,
            Some(artifact_path.display().to_string().replace('\\', "/")),
        )
        .expect("plan should build");
        let audit = &plan.final_closure_audit;

        assert_eq!(
            audit["production_smoke_acceptance_state"]["artifact_read"],
            true
        );
        assert_eq!(
            audit["production_smoke_acceptance_state"]["evidence_accepted_for_review"],
            true
        );
        assert_eq!(audit["final_x_eligible"], false);
        assert_eq!(audit["artifact_provenance"]["simulated"], true);
        assert_eq!(audit["artifact_provenance"]["fixture_artifact"], false);
        assert_eq!(audit["writer_insert_readback_state"]["state"], "accepted");
        assert_eq!(audit["db_cursor_state"]["state"], "accepted");
        assert_eq!(
            audit["wal_append_replay_send_ack_state"]["state"],
            "accepted"
        );
        assert_eq!(audit["dedup_journal_state"]["state"], "accepted");
        assert_eq!(audit["retention_load_state"]["state"], "accepted");
        assert_eq!(audit["secret_safe_omission_state"]["state"], "accepted");
        assert!(
            audit["blocking_reasons"]
                .as_array()
                .expect("blocking reasons")
                .iter()
                .any(|reason| reason.as_str() == Some("simulated_artifact"))
        );
        assert_eq!(
            audit["audit_boundaries"]["simulation_can_mark_final_x"],
            false
        );
        let _ = fs::remove_dir_all(&audit_fixture_dir);
    }

    #[test]
    fn evidence_watcher_lists_required_artifact_without_reading_it() {
        let fixture = fixture();
        let input = clickhouse_log_store_input_from_json_str(include_str!(
            "../../../tests/fixtures/worker/clickhouse_log_store_plan_contract.json"
        ))
        .expect("fixture should parse");
        let plan = clickhouse_log_store_plan(
            None,
            ClickHouseLogStoreInputSource::InputJson {
                path: "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string(),
            },
            input,
        )
        .expect("plan should build");
        let watcher = &plan.production_smoke_evidence_watcher;
        let expected = &fixture["expected_production_smoke_evidence_watcher"];

        assert_eq!(watcher["contract"], expected["contract"]);
        assert_eq!(watcher["mode"], "watcher_checklist_only");
        assert_eq!(watcher["final_x_eligible"], false);
        assert_eq!(watcher["safe_defaults"]["artifact_read_default"], false);
        assert_eq!(watcher["safe_defaults"]["clickhouse_connected"], false);
        assert_eq!(watcher["safe_defaults"]["network_requests"], false);
        assert_eq!(
            watcher["safe_defaults"]["production_wal_root_writes"],
            false
        );
        assert_eq!(watcher["safe_defaults"]["watcher_can_mark_final_x"], false);
        assert_eq!(
            watcher["expected_artifact_paths"]["operator_handoff_artifact"],
            ".tmp/clickhouse-log-store/production-smoke/<run_id>.json"
        );
        assert_eq!(
            watcher["required_artifact_fields"]
                .as_array()
                .expect("required fields")
                .len(),
            20
        );
        assert_eq!(
            watcher["required_evidence_checklist"]
                .as_array()
                .expect("required evidence")
                .len(),
            7
        );
        assert_eq!(
            watcher["next_commands"]["final_audit_readback"],
            "ai-worker clickhouse-log-store --final-closure-audit --read-production-smoke-artifact <repo/.tmp/production-smoke.json> --input <json>"
        );
        assert_eq!(
            watcher["final_review_checklist"]["simulation_or_fixture_or_handoff_or_watcher_can_close"],
            false
        );
    }

    #[test]
    fn production_smoke_handoff_defines_operator_commands_schema_and_refusals() {
        let fixture = fixture();
        let input = clickhouse_log_store_input_from_json_str(include_str!(
            "../../../tests/fixtures/worker/clickhouse_log_store_plan_contract.json"
        ))
        .expect("fixture should parse");
        let plan = clickhouse_log_store_plan(
            None,
            ClickHouseLogStoreInputSource::InputJson {
                path: "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string(),
            },
            input,
        )
        .expect("plan should build");
        let handoff = &plan.production_smoke_handoff;
        let expected = &fixture["expected_production_smoke_handoff"];

        assert_eq!(handoff["contract"], expected["contract"]);
        assert_eq!(handoff["mode"], "operator_handoff_contract_only");
        assert_eq!(
            handoff["state_classification"]["production_smoke_ready"],
            true
        );
        assert_eq!(handoff["state_classification"]["final_x_eligible"], false);
        assert_eq!(
            handoff["default_side_effects"]["clickhouse_connected"],
            false
        );
        assert_eq!(handoff["default_side_effects"]["network_requests"], false);
        assert_eq!(
            handoff["default_side_effects"]["production_wal_root_writes"],
            false
        );
        assert_eq!(
            handoff["preflight_command_shape"]["requires_explicit_live_opt_in"],
            true
        );
        assert_eq!(
            handoff["artifact_schema"]["schema_version"],
            "clickhouse_log_store_production_smoke_artifact_v1"
        );
        assert_eq!(
            handoff["artifact_schema"]["required_fields"]
                .as_array()
                .expect("required fields")
                .len(),
            20
        );
        assert_eq!(
            handoff["failure_taxonomy"]
                .as_array()
                .expect("failure taxonomy")
                .len(),
            10
        );
        assert!(
            handoff["failure_taxonomy"]
                .as_array()
                .expect("failure taxonomy")
                .contains(&json!("network_attempted_without_opt_in"))
        );
        assert_eq!(
            handoff["artifact_schema"]["simulated_artifact_can_pass"],
            false
        );
        assert_eq!(handoff["artifact_schema"]["stale_artifact_can_pass"], false);
    }

    #[test]
    fn production_smoke_acceptance_defaults_to_no_artifact_read() {
        let input = clickhouse_log_store_input_from_json_str(include_str!(
            "../../../tests/fixtures/worker/clickhouse_log_store_plan_contract.json"
        ))
        .expect("fixture should parse");
        let plan = clickhouse_log_store_plan(
            None,
            ClickHouseLogStoreInputSource::InputJson {
                path: "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string(),
            },
            input,
        )
        .expect("plan should build");
        let acceptance = &plan.production_smoke_acceptance;

        assert_eq!(acceptance["requested"], false);
        assert_eq!(acceptance["artifact_read"], false);
        assert_eq!(
            acceptance["default_side_effects"]["clickhouse_connected"],
            false
        );
        assert_eq!(
            acceptance["default_side_effects"]["network_requests"],
            false
        );
        assert_eq!(
            acceptance["default_side_effects"]["production_wal_root_writes"],
            false
        );
    }

    #[test]
    fn production_smoke_acceptance_reads_simulation_shape_without_final_x() {
        cleanup_production_smoke_fixture();
        let artifact_dir = PathBuf::from(".tmp")
            .join("clickhouse-log-store")
            .join("production-smoke");
        fs::create_dir_all(&artifact_dir).expect("create production smoke fixture dir");
        let artifact_path = artifact_dir.join("accepted-simulation.json");
        write_file_synced(
            &artifact_path,
            include_bytes!(
                "../../../tests/fixtures/worker/clickhouse_production_smoke_artifact_accepted_simulation.json"
            ),
        )
        .expect("write production smoke fixture");

        let fixture = fixture();
        let input = clickhouse_log_store_input_from_json_str(include_str!(
            "../../../tests/fixtures/worker/clickhouse_log_store_plan_contract.json"
        ))
        .expect("fixture should parse");
        let plan = clickhouse_log_store_plan_with_service_readiness(
            None,
            ClickHouseLogStoreInputSource::InputJson {
                path: "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string(),
            },
            input,
            false,
            false,
            false,
            false,
            false,
            false,
            false,
            false,
            Some(artifact_path.display().to_string().replace('\\', "/")),
        )
        .expect("plan should build");
        let acceptance = &plan.production_smoke_acceptance;
        let expected = &fixture["expected_production_smoke_acceptance_simulation"];

        assert_eq!(acceptance["contract"], expected["contract"]);
        assert_eq!(acceptance["requested"], true);
        assert_eq!(acceptance["artifact_read"], true);
        assert_eq!(
            acceptance["production_smoke_evidence_accepted_for_review"],
            true
        );
        assert_eq!(acceptance["production_smoke_passed"], false);
        assert_eq!(acceptance["final_x_eligible"], false);
        assert_eq!(acceptance["simulation_can_mark_final_x"], false);
        assert_eq!(acceptance["acceptance_matrix"]["writer_counts"], "accepted");
        assert_eq!(acceptance["acceptance_matrix"]["non_simulated"], "refused");
        assert!(
            acceptance["final_x_blockers"]
                .as_array()
                .expect("final blockers")
                .contains(&json!("simulated_artifact"))
        );
        cleanup_production_smoke_fixture();
    }

    #[test]
    fn production_smoke_acceptance_refuses_unsafe_artifact_path_without_read() {
        let input = clickhouse_log_store_input_from_json_str(include_str!(
            "../../../tests/fixtures/worker/clickhouse_log_store_plan_contract.json"
        ))
        .expect("fixture should parse");
        let plan = clickhouse_log_store_plan_with_service_readiness(
            None,
            ClickHouseLogStoreInputSource::InputJson {
                path: "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string(),
            },
            input,
            false,
            false,
            false,
            false,
            false,
            false,
            false,
            false,
            Some("/var/lib/ai-gateway/prod-smoke.json".to_string()),
        )
        .expect("unsafe artifact path should classify instead of reading");
        let acceptance = &plan.production_smoke_acceptance;

        assert_eq!(acceptance["requested"], true);
        assert_eq!(acceptance["artifact_read"], false);
        assert_eq!(acceptance["path_gate"]["allowed"], false);
        assert!(
            acceptance["review_refusal_reasons"]
                .as_array()
                .expect("review refusals")
                .contains(&json!("unsafe_path"))
        );
        assert_eq!(
            acceptance["production_smoke_evidence_accepted_for_review"],
            false
        );
    }

    #[test]
    fn plan_serialization_omits_env_values_and_secret_material() {
        let fixture = fixture();
        let input = clickhouse_log_store_input_from_json_str(include_str!(
            "../../../tests/fixtures/worker/clickhouse_log_store_plan_contract.json"
        ))
        .expect("fixture should parse");
        let plan = clickhouse_log_store_plan(
            None,
            ClickHouseLogStoreInputSource::InputJson {
                path: "tests/fixtures/worker/clickhouse_log_store_plan_contract.json".to_string(),
            },
            input,
        )
        .expect("plan should build");
        let serialized = serde_json::to_string(&plan).expect("plan should serialize");

        for forbidden in fixture["must_not_echo"]
            .as_array()
            .expect("must_not_echo should be an array")
        {
            let forbidden = forbidden.as_str().expect("must_not_echo entry");
            assert!(
                !serialized.contains(forbidden),
                "serialized ClickHouse log store plan leaked `{forbidden}`"
            );
        }
    }

    #[test]
    fn invalid_config_error_is_redacted() {
        let input = clickhouse_log_store_input_from_json_str(
            r#"{"input":{"env":{"AI_GATEWAY_CLICKHOUSE_LOG_STORE_ENABLED":"true","AI_GATEWAY_CLICKHOUSE_ENDPOINT":"https://alice:plain-password@clickhouse.example.com:8443?api_key=fixture-api-secret"}}}"#,
        )
        .expect("shape should parse");
        let error = clickhouse_log_store_plan(
            None,
            ClickHouseLogStoreInputSource::InputJson {
                path: "fixture.json".to_string(),
            },
            input,
        )
        .expect_err("secret-bearing endpoint should fail validation");

        assert!(error.contains("clickhouse.example.com"));
        assert!(!error.contains("alice"));
        assert!(!error.contains("plain-password"));
        assert!(!error.contains("fixture-api-secret"));
    }

    #[test]
    fn execute_error_documents_refused_writes_and_sends() {
        assert!(clickhouse_log_store_execute_error(false).contains("requires --force"));
        assert!(clickhouse_log_store_execute_error(true).contains("ClickHouse write"));
        assert!(clickhouse_log_store_execute_error(true).contains("WAL/file write"));
    }

    fn fixture() -> Value {
        serde_json::from_str(include_str!(
            "../../../tests/fixtures/worker/clickhouse_log_store_plan_contract.json"
        ))
        .expect("ClickHouse log store contract fixture should be valid json")
    }

    fn cleanup_runtime_wal_fixture() {
        let _ = fs::remove_dir_all(
            ".tmp/clickhouse-log-store/wal/tenant_id=00000000-0000-0000-0000-000000000001",
        );
    }

    fn cleanup_service_readiness_fixture() {
        let _ = fs::remove_dir_all(".tmp/clickhouse-log-store/service-readiness");
    }

    fn cleanup_production_smoke_fixture() {
        let _ = fs::remove_dir_all(".tmp/clickhouse-log-store/production-smoke");
    }
}
