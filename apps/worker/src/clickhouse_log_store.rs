use ai_gateway_observability::{CLICKHOUSE_LOG_STORE_CONTRACT_VERSION, ClickHouseLogStoreConfig};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{collections::BTreeMap, fs};
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
    outbound_calls: bool,
    network_requests: bool,
    tenant_id: Uuid,
    source: ClickHouseLogStoreSourceReport,
    clickhouse_config: Value,
    ingestion: ClickHouseIngestionPlan,
    queue: ClickHouseQueuePlan,
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
    let env_key_count = input.env.len();
    let tenant_id = tenant_id_override
        .or(input.tenant_id)
        .unwrap_or(super::DEFAULT_TENANT_ID);
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
    let enabled = bool_at(&clickhouse_config, "enabled");
    let batch_size = u64_at(&clickhouse_config, "batch_size");
    let flush_interval_ms = u64_at(&clickhouse_config, "flush_interval_ms");
    let max_queue_rows = u64_nested_at(&clickhouse_config, "backpressure", "max_queue_rows");
    let drop_policy = string_nested_at(&clickhouse_config, "backpressure", "drop_policy")
        .unwrap_or_else(|| "drop_newest".to_string());
    let table_mapping = table_mapping_from_config(&clickhouse_config);

    Ok(ClickHouseLogStoreWorkerPlan {
        schema_version: "clickhouse_log_store_worker_plan.v1",
        dry_run: true,
        mode: "plan_only",
        read_only: true,
        runtime_connected: false,
        db_reads: false,
        db_writes: false,
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
                "backpressure.drop_policy",
                "dedup.per_sink_keys",
                "table_mapping",
            ],
            config_validated_by_observability_crate: true,
            network_requests_disabled: true,
            db_reads_disabled: true,
            db_writes_disabled: true,
            queue_plan_only: true,
            credential_material_omitted: true,
            env_values_omitted: true,
            payload_body_omitted: true,
        },
        remaining_gaps: vec![
            "real_clickhouse_writer",
            "durable_queue_or_wal",
            "database_changefeed_or_export_cursor",
            "dedup_journal_persistence",
            "load_and_retention_smoke",
        ],
    })
}

pub(crate) fn clickhouse_log_store_execute_error(force: bool) -> String {
    if force {
        return "clickhouse-log-store execute/send is not implemented in this dry-run slice; no DB read, queue write, ClickHouse write, or network request was sent"
            .to_string();
    }

    "clickhouse-log-store execute/send requires --force and is not implemented in this dry-run slice; no DB read, queue write, ClickHouse write, or network request was sent"
        .to_string()
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
        assert!(!plan.outbound_calls);
        assert!(!plan.network_requests);
        assert_eq!(plan.tenant_id, TENANT_ID);
        assert_eq!(plan.source.env_key_count, 17);
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
        assert!(plan.contract.credential_material_omitted);
        assert!(plan.contract.env_values_omitted);
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
    }

    fn fixture() -> Value {
        serde_json::from_str(include_str!(
            "../../../tests/fixtures/worker/clickhouse_log_store_plan_contract.json"
        ))
        .expect("ClickHouse log store contract fixture should be valid json")
    }
}
