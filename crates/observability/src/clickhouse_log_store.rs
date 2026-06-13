use std::{collections::BTreeMap, env, error::Error, fmt};

use serde_json::{Value, json};

use crate::{
    REDACTED_SECRET,
    payload_policy::{PayloadPolicy, PayloadStorageMode, payload_sha256_hex},
    redact_secrets,
};

pub const CLICKHOUSE_LOG_STORE_CONTRACT_VERSION: &str = "clickhouse_log_store_plan_v1";
pub const CLICKHOUSE_WAL_DRY_RUN_READBACK_CONTRACT_VERSION: &str =
    "clickhouse_log_store_wal_dry_run_readback_v1";
pub const DEFAULT_CLICKHOUSE_DATABASE: &str = "ai_gateway";
pub const DEFAULT_CLICKHOUSE_TABLE: &str = "gateway_logs";
pub const DEFAULT_CLICKHOUSE_BATCH_SIZE: u32 = 1_000;
pub const DEFAULT_CLICKHOUSE_FLUSH_INTERVAL_MS: u64 = 1_000;
pub const DEFAULT_CLICKHOUSE_MAX_QUEUE_ROWS: u32 = 100_000;
pub const DEFAULT_CLICKHOUSE_RETRY_MAX_ATTEMPTS: u32 = 3;
pub const DEFAULT_CLICKHOUSE_RETRY_INITIAL_BACKOFF_MS: u64 = 100;
pub const DEFAULT_CLICKHOUSE_RETRY_MAX_BACKOFF_MS: u64 = 5_000;
pub const DEFAULT_CLICKHOUSE_PAYLOAD_POLICY: &str = "hash";
pub const DEFAULT_CLICKHOUSE_WAL_PRODUCTION_ROOT: &str = "<data_dir>/clickhouse-log-store/wal";

const MAX_IDENTIFIER_LEN: usize = 64;
const MAX_ENDPOINT_LEN: usize = 512;
const MAX_ERROR_VALUE_LEN: usize = 96;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClickHouseLogStoreConfig {
    enabled: bool,
    endpoint: Option<String>,
    database: String,
    table: String,
    batch_size: u32,
    flush_interval_ms: u64,
    tls: ClickHouseTlsConfig,
    credentials: ClickHouseCredentialPresence,
    backpressure: ClickHouseBackpressureConfig,
    retry: ClickHouseRetryPolicy,
    wal_service: ClickHouseWalServiceGuard,
    requested_payload_policy: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ClickHouseTlsConfig {
    enabled: bool,
    verify_certificate: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ClickHouseCredentialPresence {
    basic_user: bool,
    basic_secret: bool,
    api_secret: bool,
    bearer_header: bool,
    endpoint_userinfo: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ClickHouseBackpressureConfig {
    max_queue_rows: u32,
    drop_policy: ClickHouseDropPolicy,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClickHouseDropPolicy {
    DropNewest,
    DropOldest,
    Block,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClickHouseRetryPolicy {
    max_attempts: u32,
    initial_backoff_ms: u64,
    max_backoff_ms: u64,
    jitter: bool,
    retry_on: Vec<&'static str>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClickHouseWalServiceGuard {
    service_opt_in: bool,
    production_root_present: bool,
    production_root: Option<String>,
    root_scope: &'static str,
    readiness: &'static str,
    blocker: Option<&'static str>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClickHouseLogStorePlan {
    enabled: bool,
    endpoint: Option<String>,
    database: String,
    table: String,
    batch_size: u32,
    flush_interval_ms: u64,
    tls: ClickHouseTlsConfig,
    credentials: ClickHouseCredentialPresence,
    sinks: Vec<ClickHouseSinkPlan>,
    backpressure: ClickHouseBackpressureConfig,
    retry: ClickHouseRetryPolicy,
    wal_service: ClickHouseWalServiceGuard,
    payload_policy: ClickHousePayloadPolicyPlan,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClickHouseSinkPlan {
    sink: ClickHouseLogSink,
    table: String,
    schema_version: u16,
    enabled: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClickHouseLogSink {
    RequestLogs,
    ProviderAttempts,
    EventLog,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClickHousePayloadPolicyPlan {
    requested_policy: String,
    effective_policy: PayloadPolicy,
    policy_was_recognized: bool,
    default_storage_mode: PayloadStorageMode,
    sampled_storage_mode: Option<PayloadStorageMode>,
    payload_body_by_default: bool,
    payload_body_storage_enabled: bool,
    fallback_reason: Option<&'static str>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClickHouseLogStoreConfigError {
    MissingEndpoint,
    InvalidEndpoint {
        endpoint: String,
        reason: &'static str,
    },
    InvalidIdentifier {
        field: &'static str,
        value: String,
        reason: &'static str,
    },
    InvalidBoolean {
        field: &'static str,
        value: String,
    },
    InvalidInteger {
        field: &'static str,
        value: String,
        min: u64,
        max: u64,
    },
    InvalidDropPolicy {
        value: String,
    },
}

impl Default for ClickHouseLogStoreConfig {
    fn default() -> Self {
        Self::disabled()
    }
}

impl ClickHouseLogStoreConfig {
    pub fn disabled() -> Self {
        Self {
            enabled: false,
            endpoint: None,
            database: DEFAULT_CLICKHOUSE_DATABASE.to_string(),
            table: DEFAULT_CLICKHOUSE_TABLE.to_string(),
            batch_size: DEFAULT_CLICKHOUSE_BATCH_SIZE,
            flush_interval_ms: DEFAULT_CLICKHOUSE_FLUSH_INTERVAL_MS,
            tls: ClickHouseTlsConfig {
                enabled: false,
                verify_certificate: true,
            },
            credentials: ClickHouseCredentialPresence::default(),
            backpressure: ClickHouseBackpressureConfig::default(),
            retry: ClickHouseRetryPolicy::default(),
            wal_service: ClickHouseWalServiceGuard::default(),
            requested_payload_policy: DEFAULT_CLICKHOUSE_PAYLOAD_POLICY.to_string(),
        }
    }

    pub fn from_env() -> Result<Self, ClickHouseLogStoreConfigError> {
        Self::from_env_vars(env::vars())
    }

    pub fn from_env_vars<I, K, V>(vars: I) -> Result<Self, ClickHouseLogStoreConfigError>
    where
        I: IntoIterator<Item = (K, V)>,
        K: Into<String>,
        V: Into<String>,
    {
        let vars = vars
            .into_iter()
            .map(|(key, value)| (key.into(), value.into()))
            .collect::<BTreeMap<_, _>>();

        let enabled = parse_bool_env(
            &vars,
            &[
                "AI_GATEWAY_CLICKHOUSE_LOG_STORE_ENABLED",
                "AI_GATEWAY_LOG_STORE_CLICKHOUSE_ENABLED",
            ],
            false,
            "AI_GATEWAY_CLICKHOUSE_LOG_STORE_ENABLED",
        )?;

        if !enabled {
            return Ok(Self::disabled());
        }

        let endpoint = first_nonempty_env(
            &vars,
            &[
                "AI_GATEWAY_CLICKHOUSE_ENDPOINT",
                "AI_GATEWAY_CLICKHOUSE_LOG_STORE_ENDPOINT",
            ],
        )
        .ok_or(ClickHouseLogStoreConfigError::MissingEndpoint)?;
        let endpoint = validate_clickhouse_endpoint(endpoint)?;

        let database = sanitize_identifier(
            first_nonempty_env(
                &vars,
                &[
                    "AI_GATEWAY_CLICKHOUSE_DATABASE",
                    "AI_GATEWAY_CLICKHOUSE_LOG_STORE_DATABASE",
                ],
            )
            .unwrap_or(DEFAULT_CLICKHOUSE_DATABASE),
            "database",
        )?;
        let table = sanitize_identifier(
            first_nonempty_env(
                &vars,
                &[
                    "AI_GATEWAY_CLICKHOUSE_TABLE",
                    "AI_GATEWAY_CLICKHOUSE_LOG_STORE_TABLE",
                ],
            )
            .unwrap_or(DEFAULT_CLICKHOUSE_TABLE),
            "table",
        )?;

        let batch_size = parse_u32_env(
            &vars,
            &[
                "AI_GATEWAY_CLICKHOUSE_BATCH_SIZE",
                "AI_GATEWAY_CLICKHOUSE_LOG_STORE_BATCH_SIZE",
            ],
            DEFAULT_CLICKHOUSE_BATCH_SIZE,
            1,
            100_000,
            "AI_GATEWAY_CLICKHOUSE_BATCH_SIZE",
        )?;
        let flush_interval_ms = parse_u64_env(
            &vars,
            &[
                "AI_GATEWAY_CLICKHOUSE_FLUSH_INTERVAL_MS",
                "AI_GATEWAY_CLICKHOUSE_LOG_STORE_FLUSH_INTERVAL_MS",
            ],
            DEFAULT_CLICKHOUSE_FLUSH_INTERVAL_MS,
            10,
            60_000,
            "AI_GATEWAY_CLICKHOUSE_FLUSH_INTERVAL_MS",
        )?;
        let verify_certificate = parse_bool_env(
            &vars,
            &[
                "AI_GATEWAY_CLICKHOUSE_TLS_VERIFY",
                "AI_GATEWAY_CLICKHOUSE_LOG_STORE_TLS_VERIFY",
            ],
            true,
            "AI_GATEWAY_CLICKHOUSE_TLS_VERIFY",
        )?;

        let credentials = ClickHouseCredentialPresence {
            basic_user: first_nonempty_env(
                &vars,
                &["AI_GATEWAY_CLICKHOUSE_USERNAME", "CLICKHOUSE_USER"],
            )
            .is_some(),
            basic_secret: first_nonempty_env(
                &vars,
                &["AI_GATEWAY_CLICKHOUSE_PASSWORD", "CLICKHOUSE_PASSWORD"],
            )
            .is_some(),
            api_secret: first_nonempty_env(
                &vars,
                &[
                    "AI_GATEWAY_CLICKHOUSE_TOKEN",
                    "AI_GATEWAY_CLICKHOUSE_API_KEY",
                    "CLICKHOUSE_TOKEN",
                ],
            )
            .is_some(),
            bearer_header: first_nonempty_env(
                &vars,
                &[
                    "AI_GATEWAY_CLICKHOUSE_AUTHORIZATION",
                    "AI_GATEWAY_CLICKHOUSE_AUTH_HEADER",
                ],
            )
            .is_some(),
            endpoint_userinfo: false,
        };

        let backpressure = ClickHouseBackpressureConfig {
            max_queue_rows: parse_u32_env(
                &vars,
                &[
                    "AI_GATEWAY_CLICKHOUSE_BACKPRESSURE_MAX_QUEUE_ROWS",
                    "AI_GATEWAY_CLICKHOUSE_LOG_STORE_MAX_QUEUE_ROWS",
                ],
                DEFAULT_CLICKHOUSE_MAX_QUEUE_ROWS,
                1,
                10_000_000,
                "AI_GATEWAY_CLICKHOUSE_BACKPRESSURE_MAX_QUEUE_ROWS",
            )?,
            drop_policy: parse_drop_policy_env(&vars)?,
        };

        let retry = ClickHouseRetryPolicy {
            max_attempts: parse_u32_env(
                &vars,
                &[
                    "AI_GATEWAY_CLICKHOUSE_RETRY_MAX_ATTEMPTS",
                    "AI_GATEWAY_CLICKHOUSE_LOG_STORE_RETRY_MAX_ATTEMPTS",
                ],
                DEFAULT_CLICKHOUSE_RETRY_MAX_ATTEMPTS,
                0,
                10,
                "AI_GATEWAY_CLICKHOUSE_RETRY_MAX_ATTEMPTS",
            )?,
            initial_backoff_ms: parse_u64_env(
                &vars,
                &[
                    "AI_GATEWAY_CLICKHOUSE_RETRY_INITIAL_BACKOFF_MS",
                    "AI_GATEWAY_CLICKHOUSE_LOG_STORE_RETRY_INITIAL_BACKOFF_MS",
                ],
                DEFAULT_CLICKHOUSE_RETRY_INITIAL_BACKOFF_MS,
                1,
                60_000,
                "AI_GATEWAY_CLICKHOUSE_RETRY_INITIAL_BACKOFF_MS",
            )?,
            max_backoff_ms: parse_u64_env(
                &vars,
                &[
                    "AI_GATEWAY_CLICKHOUSE_RETRY_MAX_BACKOFF_MS",
                    "AI_GATEWAY_CLICKHOUSE_LOG_STORE_RETRY_MAX_BACKOFF_MS",
                ],
                DEFAULT_CLICKHOUSE_RETRY_MAX_BACKOFF_MS,
                1,
                300_000,
                "AI_GATEWAY_CLICKHOUSE_RETRY_MAX_BACKOFF_MS",
            )?,
            jitter: true,
            retry_on: default_retry_on(),
        };
        let wal_service = ClickHouseWalServiceGuard::from_env_vars(&vars)?;

        let tls = ClickHouseTlsConfig {
            enabled: endpoint.tls_enabled,
            verify_certificate: endpoint.tls_enabled && verify_certificate,
        };

        Ok(Self {
            enabled: true,
            endpoint: Some(endpoint.value),
            database,
            table,
            batch_size,
            flush_interval_ms,
            tls,
            credentials,
            backpressure,
            retry,
            wal_service,
            requested_payload_policy: first_nonempty_env(
                &vars,
                &[
                    "AI_GATEWAY_CLICKHOUSE_PAYLOAD_POLICY",
                    "AI_GATEWAY_CLICKHOUSE_LOG_STORE_PAYLOAD_POLICY",
                ],
            )
            .unwrap_or(DEFAULT_CLICKHOUSE_PAYLOAD_POLICY)
            .trim()
            .to_string(),
        })
    }

    pub fn write_plan(&self) -> ClickHouseLogStorePlan {
        plan_clickhouse_log_store(self)
    }

    pub fn is_enabled(&self) -> bool {
        self.enabled
    }

    pub fn endpoint(&self) -> Option<&str> {
        self.endpoint.as_deref()
    }
}

impl Default for ClickHouseBackpressureConfig {
    fn default() -> Self {
        Self {
            max_queue_rows: DEFAULT_CLICKHOUSE_MAX_QUEUE_ROWS,
            drop_policy: ClickHouseDropPolicy::DropNewest,
        }
    }
}

impl ClickHouseDropPolicy {
    pub fn parse(value: &str) -> Option<Self> {
        match normalize_config_value(value).as_str() {
            "drop_newest" | "drop_latest" | "drop_when_full" => Some(Self::DropNewest),
            "drop_oldest" => Some(Self::DropOldest),
            "block" | "wait" | "backpressure" => Some(Self::Block),
            _ => None,
        }
    }

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::DropNewest => "drop_newest",
            Self::DropOldest => "drop_oldest",
            Self::Block => "block",
        }
    }
}

impl Default for ClickHouseRetryPolicy {
    fn default() -> Self {
        Self {
            max_attempts: DEFAULT_CLICKHOUSE_RETRY_MAX_ATTEMPTS,
            initial_backoff_ms: DEFAULT_CLICKHOUSE_RETRY_INITIAL_BACKOFF_MS,
            max_backoff_ms: DEFAULT_CLICKHOUSE_RETRY_MAX_BACKOFF_MS,
            jitter: true,
            retry_on: default_retry_on(),
        }
    }
}

impl Default for ClickHouseWalServiceGuard {
    fn default() -> Self {
        Self {
            service_opt_in: false,
            production_root_present: false,
            production_root: None,
            root_scope: "missing",
            readiness: "blocked",
            blocker: Some("production_wal_root_missing"),
        }
    }
}

impl ClickHouseWalServiceGuard {
    fn from_env_vars(
        vars: &BTreeMap<String, String>,
    ) -> Result<Self, ClickHouseLogStoreConfigError> {
        let service_opt_in = parse_bool_env(
            vars,
            &[
                "AI_GATEWAY_CLICKHOUSE_WAL_SERVICE_ENABLED",
                "AI_GATEWAY_CLICKHOUSE_LOG_STORE_WAL_SERVICE_ENABLED",
            ],
            false,
            "AI_GATEWAY_CLICKHOUSE_WAL_SERVICE_ENABLED",
        )?;
        let production_root = first_nonempty_env(
            vars,
            &[
                "AI_GATEWAY_CLICKHOUSE_WAL_DIR",
                "AI_GATEWAY_CLICKHOUSE_LOG_STORE_WAL_DIR",
            ],
        )
        .map(safe_wal_root_for_contract);
        let production_root_present = production_root.is_some();
        let root_scope = production_root
            .as_deref()
            .map(wal_root_scope)
            .unwrap_or("missing");
        let blocker = match (service_opt_in, production_root_present, root_scope) {
            (false, _, _) => Some("wal_service_not_opted_in"),
            (true, false, _) => Some("production_wal_root_missing"),
            (true, true, "artifact_tmp") => Some("production_wal_root_points_to_artifact_tmp"),
            (true, true, "unsafe") => Some("production_wal_root_unsafe"),
            (true, true, "production") => None,
            _ => Some("production_wal_root_invalid"),
        };
        let readiness = if blocker.is_none() {
            "ready"
        } else {
            "blocked"
        };

        Ok(Self {
            service_opt_in,
            production_root_present,
            production_root,
            root_scope,
            readiness,
            blocker,
        })
    }

    fn to_contract_json(&self) -> Value {
        json!({
            "service_opt_in": self.service_opt_in,
            "production_root_present": self.production_root_present,
            "production_root": self.production_root,
            "default_production_root": DEFAULT_CLICKHOUSE_WAL_PRODUCTION_ROOT,
            "root_scope": self.root_scope,
            "readiness": self.readiness,
            "blocker": self.blocker,
            "production_service_readiness": {
                "ready": self.readiness == "ready",
                "requires_service_opt_in": true,
                "requires_production_root": true,
                "requires_production_root_scope": true,
                "blocker": self.blocker
            },
            "runtime_artifact_path_contract": {
                "artifact_scope": ".tmp",
                "requires_explicit_worker_opt_in": true,
                "repo_bounded_runtime_artifact_allowed": true,
                "service_readiness_artifact_allowed": true,
                "can_satisfy_production_wal_root": false,
                "artifact_tmp_root_is_production_blocker": true,
                "production_directory_writes_enabled_by_config_readback": false
            },
            "service_execution_dry_run_contract": {
                "default_readiness_only": true,
                "requires_explicit_artifact_opt_in": true,
                "service_loop_start_enabled": false,
                "wal_replay_enabled": false,
                "clickhouse_send_enabled": false,
                "production_wal_root_write_enabled": false
            },
            "final_dod_contract_summary": {
                "readiness_or_artifact_proof_can_mark_production_ready": self.readiness == "ready",
                "readiness_or_artifact_proof_can_mark_final_x": false,
                "final_x_requires_live_smoke_readback": true,
                "required_live_evidence": [
                    "real_clickhouse_insert_writer",
                    "db_changefeed_or_export_cursor",
                    "production_wal_root_writes",
                    "wal_service_loop_replay_send",
                    "dedup_journal_persistence",
                    "retention_load_smoke",
                    "secret_safe_evidence",
                    "no_network_default_and_execute_refusal"
                ]
            },
            "production_smoke_handoff_summary": {
                "contract": "clickhouse_log_store_production_smoke_handoff_v1",
                "default_connects_clickhouse": false,
                "default_network_requests": false,
                "default_writes_production_wal_root": false,
                "requires_explicit_live_opt_in": true,
                "simulated_artifact_can_pass": false,
                "fixture_can_mark_final_x": false,
                "handoff_can_mark_final_x": false,
                "stale_artifact_can_pass": false,
                "final_x_requires_live_smoke_readback": true
            },
            "production_smoke_acceptance_gate_summary": {
                "contract": "clickhouse_log_store_production_smoke_acceptance_gate_v1",
                "default_reads_artifact": false,
                "default_connects_clickhouse": false,
                "default_network_requests": false,
                "default_writes_production_wal_root": false,
                "requires_explicit_artifact_readback": true,
                "accepted_shape_simulation_supported": true,
                "simulation_can_mark_final_x": false,
                "fixture_can_mark_final_x": false,
                "refusal_can_mark_final_x": false,
                "unsafe_path_refusal": true,
                "secret_echo_refusal": true
            },
            "final_closure_audit_summary": {
                "contract": "clickhouse_log_store_final_closure_audit_v1",
                "default_reads_artifact": false,
                "default_connects_clickhouse": false,
                "default_network_requests": false,
                "default_writes_production_wal_root": false,
                "requires_explicit_artifact_readback": true,
                "simulation_can_mark_final_x": false,
                "fixture_can_mark_final_x": false,
                "handoff_can_mark_final_x": false,
                "audit_without_real_artifact_can_mark_final_x": false,
                "refusal_can_mark_final_x": false,
                "watcher_can_mark_final_x": false,
                "final_x_requires_accepted_live_smoke_artifact": true,
                "final_x_requires_real_writer_cursor_wal_dedup_load_retention_secret_safe": true,
                "reports_blocking_reasons": true
            },
            "production_smoke_evidence_watcher_summary": {
                "contract": "clickhouse_log_store_production_smoke_evidence_watcher_v1",
                "default_reads_artifact": false,
                "default_connects_clickhouse": false,
                "default_network_requests": false,
                "default_writes_production_wal_root": false,
                "watcher_can_mark_final_x": false,
                "simulation_can_mark_final_x": false,
                "fixture_can_mark_final_x": false,
                "handoff_can_mark_final_x": false,
                "refusal_can_mark_final_x": false,
                "requires_real_writer_cursor_wal_dedup_load_retention_secret_safe": true
            },
            "artifact_tmp_allowed_for_runtime_artifact_only": true,
            "production_wal_writes_enabled_in_this_slice": false,
            "clickhouse_network_requests_enabled": false,
            "secret_safe": true
        })
    }
}

impl ClickHouseLogSink {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::RequestLogs => "request_logs",
            Self::ProviderAttempts => "provider_attempts",
            Self::EventLog => "event_log",
        }
    }

    pub const fn schema_version(self) -> u16 {
        match self {
            Self::RequestLogs | Self::ProviderAttempts | Self::EventLog => 1,
        }
    }

    const fn table_suffix(self) -> &'static str {
        match self {
            Self::RequestLogs => "request_logs",
            Self::ProviderAttempts => "provider_attempts",
            Self::EventLog => "event_log",
        }
    }
}

impl ClickHouseLogStorePlan {
    pub fn to_contract_json(&self) -> Value {
        json!({
            "contract": CLICKHOUSE_LOG_STORE_CONTRACT_VERSION,
            "enabled": self.enabled,
            "network_requests": "never",
            "connectivity_check_enabled": false,
            "endpoint": self.endpoint,
            "database": self.database,
            "table": self.table,
            "batch_size": self.batch_size,
            "flush_interval_ms": self.flush_interval_ms,
            "tls": {
                "enabled": self.tls.enabled,
                "verify_certificate": self.tls.verify_certificate
            },
            "credentials": {
                "basic_user_present": self.credentials.basic_user,
                "basic_secret_present": self.credentials.basic_secret,
                "api_secret_present": self.credentials.api_secret,
                "bearer_header_present": self.credentials.bearer_header,
                "endpoint_userinfo_present": self.credentials.endpoint_userinfo,
                "redaction": "presence_only"
            },
            "sinks": self.sinks.iter().map(ClickHouseSinkPlan::to_contract_json).collect::<Vec<_>>(),
            "backpressure": {
                "max_queue_rows": self.backpressure.max_queue_rows,
                "drop_policy": self.backpressure.drop_policy.as_str()
            },
            "retry": {
                "max_attempts": self.retry.max_attempts,
                "initial_backoff_ms": self.retry.initial_backoff_ms,
                "max_backoff_ms": self.retry.max_backoff_ms,
                "jitter": self.retry.jitter,
                "retry_on": self.retry.retry_on
            },
            "wal_service_guard": self.wal_service.to_contract_json(),
            "payload_policy": self.payload_policy.to_contract_json()
        })
    }

    pub fn network_requests_enabled(&self) -> bool {
        false
    }

    pub fn sinks(&self) -> &[ClickHouseSinkPlan] {
        &self.sinks
    }
}

impl ClickHouseSinkPlan {
    fn to_contract_json(&self) -> Value {
        json!({
            "name": self.sink.as_str(),
            "table": self.table,
            "schema_version": self.schema_version,
            "enabled": self.enabled
        })
    }
}

impl ClickHousePayloadPolicyPlan {
    fn to_contract_json(&self) -> Value {
        json!({
            "requested_policy": self.requested_policy,
            "effective_policy": self.effective_policy.as_str(),
            "policy_was_recognized": self.policy_was_recognized,
            "default_storage_mode": self.default_storage_mode.as_str(),
            "sampled_storage_mode": self.sampled_storage_mode.map(PayloadStorageMode::as_str),
            "payload_body_by_default": self.payload_body_by_default,
            "payload_body_storage_enabled": self.payload_body_storage_enabled,
            "fallback_reason": self.fallback_reason
        })
    }
}

impl fmt::Display for ClickHouseLogStoreConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingEndpoint => write!(
                f,
                "ClickHouse log store is enabled but no http or https endpoint was configured"
            ),
            Self::InvalidEndpoint { endpoint, reason } => {
                write!(f, "invalid ClickHouse endpoint `{endpoint}`: {reason}")
            }
            Self::InvalidIdentifier {
                field,
                value,
                reason,
            } => write!(
                f,
                "invalid ClickHouse {field} identifier `{value}`: {reason}"
            ),
            Self::InvalidBoolean { field, value } => {
                write!(f, "invalid boolean `{value}` for {field}")
            }
            Self::InvalidInteger {
                field,
                value,
                min,
                max,
            } => write!(
                f,
                "invalid integer `{value}` for {field}; expected {min}..={max}"
            ),
            Self::InvalidDropPolicy { value } => write!(
                f,
                "invalid ClickHouse backpressure drop policy `{value}`; expected drop_newest, drop_oldest, or block"
            ),
        }
    }
}

impl Error for ClickHouseLogStoreConfigError {}

pub fn plan_clickhouse_log_store(config: &ClickHouseLogStoreConfig) -> ClickHouseLogStorePlan {
    ClickHouseLogStorePlan {
        enabled: config.enabled,
        endpoint: config.endpoint.clone(),
        database: config.database.clone(),
        table: config.table.clone(),
        batch_size: config.batch_size,
        flush_interval_ms: config.flush_interval_ms,
        tls: config.tls,
        credentials: config.credentials,
        sinks: ClickHouseLogSink::all()
            .iter()
            .map(|sink| ClickHouseSinkPlan {
                sink: *sink,
                table: format!("{}_{}", config.table, sink.table_suffix()),
                schema_version: sink.schema_version(),
                enabled: config.enabled,
            })
            .collect(),
        backpressure: config.backpressure,
        retry: config.retry.clone(),
        wal_service: config.wal_service.clone(),
        payload_policy: clickhouse_payload_policy_plan(&config.requested_payload_policy),
    }
}

pub fn clickhouse_wal_dry_run_readback_contract(
    input: &Value,
) -> Result<Value, ClickHouseWalDryRunReadbackError> {
    const DEFAULT_MAX_WAL_BYTES: u64 = 512 * 1024 * 1024;
    const DEFAULT_MAX_SEGMENT_BYTES: u64 = 16 * 1024 * 1024;
    const DEFAULT_DELETE_ACKED_SECONDS: u64 = 86_400;
    const DEFAULT_DELETE_FAILED_SECONDS: u64 = 604_800;

    let tenant_id = required_string(input, "tenant_id")?;
    let wal_root = required_string(input, "wal_root")?;
    let segment_name = required_string(input, "segment_name")?;
    let max_wal_bytes = optional_u64(input, "max_wal_bytes").unwrap_or(DEFAULT_MAX_WAL_BYTES);
    let max_segment_bytes =
        optional_u64(input, "max_segment_bytes").unwrap_or(DEFAULT_MAX_SEGMENT_BYTES);
    let max_unacked_records = optional_u64(input, "max_unacked_records").unwrap_or(100_000);
    let checkpoint_after_acked_records =
        optional_u64(input, "checkpoint_after_acked_records").unwrap_or(1);
    let retry_max_attempts = optional_u64(input, "retry_max_attempts")
        .unwrap_or(3)
        .max(1);
    let delete_acked_after_seconds = optional_u64(input, "delete_acked_segments_after_seconds")
        .unwrap_or(DEFAULT_DELETE_ACKED_SECONDS);
    let delete_failed_after_seconds = optional_u64(input, "delete_failed_segments_after_seconds")
        .unwrap_or(DEFAULT_DELETE_FAILED_SECONDS);
    let reference_time_utc = optional_string(input, "reference_time_utc")
        .unwrap_or("dry_run_reference_time_not_used_for_io");
    let records = input
        .get("records")
        .and_then(Value::as_array)
        .ok_or_else(|| ClickHouseWalDryRunReadbackError::InvalidField {
            field: "records",
            reason: "must be an array",
        })?;

    if records.len() as u64 > max_unacked_records {
        return Err(ClickHouseWalDryRunReadbackError::InvalidField {
            field: "records",
            reason: "record count exceeds max_unacked_records",
        });
    }

    let path_safety = wal_path_safety(wal_root, tenant_id, segment_name);
    let mut dedup_journal = BTreeMap::<String, DedupJournalEntry>::new();
    let mut rendered_records = Vec::with_capacity(records.len());
    let mut estimated_segment_bytes = 0_u64;
    let mut hash_match_count = 0_u64;
    let mut previous_sequence = 0_u64;
    let mut readback_order_valid = true;
    let mut pending_or_leased_records = 0_u64;
    let mut retention_classes = BTreeMap::<String, u64>::new();

    for (index, record) in records.iter().enumerate() {
        let wal_sequence = optional_u64(record, "wal_sequence").unwrap_or(index as u64 + 1);
        if wal_sequence <= previous_sequence {
            readback_order_valid = false;
        }
        previous_sequence = wal_sequence;

        let sink = required_string(record, "sink")?;
        let source_relation = optional_string(record, "source_relation").unwrap_or(sink);
        let source_record_id = required_string(record, "source_record_id")?;
        let dedup_key = required_string(record, "dedup_key")?;
        let payload_hash = normalize_sha256(required_string(record, "payload_hash")?)?;
        let payload_policy = optional_string(record, "payload_policy").unwrap_or("hash");
        let status = optional_string(record, "status").unwrap_or("pending");
        let attempt = optional_u64(record, "attempt").unwrap_or(0);
        let age_seconds = optional_u64(record, "age_seconds").unwrap_or(0);
        let simulated_operation = optional_string(record, "simulate_operation").unwrap_or("write");
        let final_status =
            final_status_for_operation(status, simulated_operation, attempt, retry_max_attempts);
        let retention_class = retention_class_for_status(
            final_status,
            age_seconds,
            delete_acked_after_seconds,
            delete_failed_after_seconds,
        );
        *retention_classes
            .entry(retention_class.to_string())
            .or_default() += 1;
        if matches!(final_status, "pending" | "leased" | "retry") {
            pending_or_leased_records += 1;
        }

        let record_material = json!({
            "tenant_id": tenant_id,
            "sink": sink,
            "source_relation": source_relation,
            "source_record_id": source_record_id,
            "request_id": optional_string(record, "request_id"),
            "provider_attempt_id": optional_string(record, "provider_attempt_id"),
            "event_id": optional_string(record, "event_id"),
            "dedup_key": dedup_key,
            "payload_hash": payload_hash,
            "payload_policy": payload_policy,
            "status": status,
            "attempt": attempt,
            "metadata_redacted": true
        });
        let record_hash = format!(
            "sha256:{}",
            payload_sha256_hex(record_material.to_string().as_bytes())
        );
        let journal_key = format!("{tenant_id}|{sink}|{dedup_key}");
        let journal_decision = match dedup_journal.get(&journal_key) {
            Some(entry)
                if entry.record_hash == record_hash && entry.payload_hash == payload_hash =>
            {
                "skip_duplicate_same_record_hash"
            }
            Some(_) => "dead_letter_payload_hash_mismatch",
            None => {
                dedup_journal.insert(
                    journal_key.clone(),
                    DedupJournalEntry {
                        record_hash: record_hash.clone(),
                        payload_hash: payload_hash.clone(),
                    },
                );
                "insert_pending"
            }
        };
        let readback_hash = format!(
            "sha256:{}",
            payload_sha256_hex(record_material.to_string().as_bytes())
        );
        let hash_matches = readback_hash == record_hash;
        if hash_matches {
            hash_match_count += 1;
        }

        let idempotency_key = format!(
            "sha256:{}",
            payload_sha256_hex(format!("{tenant_id}|{sink}|{dedup_key}|{record_hash}").as_bytes())
        );
        let operation_idempotency_key = format!(
            "sha256:{}",
            payload_sha256_hex(
                format!("{tenant_id}|{wal_sequence}|{simulated_operation}|{attempt}").as_bytes()
            )
        );
        let rendered_record = json!({
            "wal_sequence": wal_sequence,
            "segment_name": segment_name,
            "sink": sink,
            "source_relation": source_relation,
            "source_record_id": source_record_id,
            "dedup_key_hash": format!("sha256:{}", payload_sha256_hex(dedup_key.as_bytes())),
            "payload_hash": payload_hash,
            "record_hash": record_hash,
            "readback_record_hash": readback_hash,
            "readback_hash_matches": hash_matches,
            "idempotency_key": idempotency_key,
            "operation": simulated_operation,
            "operation_idempotency_key": operation_idempotency_key,
            "status_before": status,
            "status_after": final_status,
            "attempt_before": attempt,
            "journal_decision": journal_decision,
            "retention_class": retention_class,
            "payload_body_written": false,
            "credential_material_written": false
        });
        estimated_segment_bytes = estimated_segment_bytes
            .saturating_add(rendered_record.to_string().len() as u64)
            .saturating_add(1);
        rendered_records.push(rendered_record);
    }

    let segment_within_budget = estimated_segment_bytes <= max_segment_bytes;
    let wal_within_budget = estimated_segment_bytes <= max_wal_bytes;
    let retention_safe_to_delete_segment = pending_or_leased_records == 0
        && retention_classes
            .keys()
            .all(|class| class.starts_with("eligible_"));

    Ok(json!({
        "contract": CLICKHOUSE_WAL_DRY_RUN_READBACK_CONTRACT_VERSION,
        "requested": true,
        "mode": "dry_run_readback",
        "read_only": true,
        "runtime_connected": false,
        "clickhouse_connected": false,
        "network_requests": false,
        "db_reads": false,
        "db_writes": false,
        "queue_writes": false,
        "file_system_writes": false,
        "directories_created": false,
        "files_written": false,
        "payload_body_output": false,
        "credential_material_output": false,
        "reference_time_utc": reference_time_utc,
        "path_safety": path_safety,
        "segment": {
            "encoding": "json_lines",
            "segment_name": segment_name,
            "record_count": rendered_records.len(),
            "estimated_bytes": estimated_segment_bytes,
            "max_segment_bytes": max_segment_bytes,
            "within_segment_budget": segment_within_budget,
            "max_wal_bytes": max_wal_bytes,
            "within_wal_budget": wal_within_budget,
            "max_unacked_records": max_unacked_records,
            "bounded_disk": true,
            "write_protocol": "append_jsonl_temp_segment_then_fsync_then_rename_future",
            "dry_run_writes_segment": false
        },
        "record_schema": {
            "required_fields": [
                "wal_sequence",
                "tenant_id",
                "sink",
                "source_relation",
                "source_record_id",
                "dedup_key",
                "payload_hash",
                "record_hash",
                "status",
                "attempt"
            ],
            "payload_body_written": false,
            "credential_material_written": false
        },
        "write_readback_evidence": {
            "record_count": rendered_records.len(),
            "readback_hash_match_count": hash_match_count,
            "readback_order": "wal_sequence_ascending",
            "readback_order_valid": readback_order_valid,
            "dedup_journal_entries": dedup_journal.len(),
            "records": rendered_records
        },
        "operation_evidence": {
            "enqueue": "append_wal_record_then_update_dedup_journal_dry_run",
            "readback": "parse_jsonl_then_recompute_record_hash_dry_run",
            "ack": "acked_records_are_retention_classified_after_clickhouse_insert_future",
            "retry": "retry_records_keep_attempt_idempotency_key_until_exhausted",
            "dedup_journal": "tenant_sink_dedup_key_maps_to_record_and_payload_hash"
        },
        "retention": {
            "delete_acked_segments_after_seconds": delete_acked_after_seconds,
            "delete_failed_segments_after_seconds": delete_failed_after_seconds,
            "checkpoint_after_acked_records": checkpoint_after_acked_records,
            "requires_no_pending_records_before_segment_delete": true,
            "pending_or_leased_records": pending_or_leased_records,
            "safe_to_delete_segment": retention_safe_to_delete_segment,
            "classification_counts": retention_classes
        },
        "load_safety": {
            "bounded_replay_batch_rows": max_unacked_records.min(rendered_records.len() as u64),
            "single_consumer_lock": "advisory_file_lock_future",
            "replay_requires_dedup_journal_check": true,
            "path_validation_before_open": true,
            "payload_policy_enforced_before_enqueue": true
        }
    }))
}

impl ClickHouseLogSink {
    fn all() -> &'static [Self] {
        &[Self::RequestLogs, Self::ProviderAttempts, Self::EventLog]
    }
}

fn clickhouse_payload_policy_plan(requested: &str) -> ClickHousePayloadPolicyPlan {
    let requested_policy = if requested.trim().is_empty() {
        DEFAULT_CLICKHOUSE_PAYLOAD_POLICY.to_string()
    } else {
        requested.trim().to_string()
    };

    let (parsed, policy_was_recognized) = match PayloadPolicy::parse(&requested_policy) {
        Some(policy) => (policy, true),
        None => (PayloadPolicy::Hash, false),
    };

    let (effective_policy, default_storage_mode, sampled_storage_mode, fallback_reason) =
        match parsed {
            PayloadPolicy::MetadataOnly => (
                PayloadPolicy::MetadataOnly,
                PayloadStorageMode::MetadataOnly,
                None,
                None,
            ),
            PayloadPolicy::Hash => (PayloadPolicy::Hash, PayloadStorageMode::Hash, None, None),
            PayloadPolicy::Redacted => (
                PayloadPolicy::Redacted,
                PayloadStorageMode::Redacted,
                None,
                None,
            ),
            PayloadPolicy::Sampled => (
                PayloadPolicy::Sampled,
                PayloadStorageMode::Hash,
                Some(PayloadStorageMode::Redacted),
                None,
            ),
            PayloadPolicy::Full => (
                PayloadPolicy::Hash,
                PayloadStorageMode::Hash,
                None,
                Some("payload_body_storage_disabled"),
            ),
        };

    let fallback_reason = if policy_was_recognized {
        fallback_reason
    } else {
        Some("unrecognized_policy_fallback_to_hash")
    };

    ClickHousePayloadPolicyPlan {
        requested_policy,
        effective_policy,
        policy_was_recognized,
        default_storage_mode,
        sampled_storage_mode,
        payload_body_by_default: false,
        payload_body_storage_enabled: false,
        fallback_reason,
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ValidEndpoint {
    value: String,
    tls_enabled: bool,
}

fn validate_clickhouse_endpoint(raw: &str) -> Result<ValidEndpoint, ClickHouseLogStoreConfigError> {
    let endpoint = raw.trim();
    if endpoint.is_empty() {
        return Err(ClickHouseLogStoreConfigError::MissingEndpoint);
    }

    if endpoint.len() > MAX_ENDPOINT_LEN {
        return Err(invalid_endpoint(endpoint, "must be 512 bytes or shorter"));
    }

    if endpoint
        .chars()
        .any(|character| character.is_control() || character.is_ascii_whitespace())
    {
        return Err(invalid_endpoint(
            endpoint,
            "must not contain whitespace or control characters",
        ));
    }

    if endpoint.contains('?') || endpoint.contains('#') {
        return Err(invalid_endpoint(
            endpoint,
            "must not contain query strings or fragments",
        ));
    }

    if redact_secrets(endpoint) != endpoint {
        return Err(invalid_endpoint(
            endpoint,
            "must not contain secret-like material",
        ));
    }

    let lower = endpoint.to_ascii_lowercase();
    let (after_scheme, tls_enabled) = if lower.starts_with("http://") {
        (&endpoint["http://".len()..], false)
    } else if lower.starts_with("https://") {
        (&endpoint["https://".len()..], true)
    } else {
        return Err(invalid_endpoint(endpoint, "scheme must be http or https"));
    };

    let authority_end = after_scheme.find('/').unwrap_or(after_scheme.len());
    let authority = &after_scheme[..authority_end];
    if authority.is_empty() {
        return Err(invalid_endpoint(endpoint, "host is required"));
    }

    if authority.contains('@') {
        return Err(invalid_endpoint(
            endpoint,
            "must not contain user information",
        ));
    }

    validate_authority(endpoint, authority)?;

    Ok(ValidEndpoint {
        value: endpoint.trim_end_matches('/').to_string(),
        tls_enabled,
    })
}

fn validate_authority(
    endpoint: &str,
    authority: &str,
) -> Result<(), ClickHouseLogStoreConfigError> {
    if authority.starts_with('[') {
        let Some(close_index) = authority.find(']') else {
            return Err(invalid_endpoint(endpoint, "invalid IPv6 host"));
        };
        let host = &authority[1..close_index];
        if host.is_empty() || !host.chars().all(is_valid_ipv6_host_character) {
            return Err(invalid_endpoint(endpoint, "invalid IPv6 host"));
        }
        let rest = &authority[close_index + 1..];
        if let Some(port) = rest.strip_prefix(':') {
            validate_port(endpoint, port)?;
        } else if !rest.is_empty() {
            return Err(invalid_endpoint(endpoint, "invalid host or port"));
        }
        return Ok(());
    }

    let (host, port) = match authority.rsplit_once(':') {
        Some((host, port)) => (host, Some(port)),
        None => (authority, None),
    };

    if host.is_empty()
        || host.starts_with('.')
        || host.ends_with('.')
        || !host.chars().all(is_valid_hostname_character)
    {
        return Err(invalid_endpoint(endpoint, "invalid host"));
    }

    if let Some(port) = port {
        validate_port(endpoint, port)?;
    }

    Ok(())
}

fn validate_port(endpoint: &str, port: &str) -> Result<(), ClickHouseLogStoreConfigError> {
    let Ok(port) = port.parse::<u16>() else {
        return Err(invalid_endpoint(endpoint, "invalid port"));
    };

    if port == 0 {
        Err(invalid_endpoint(endpoint, "invalid port"))
    } else {
        Ok(())
    }
}

fn is_valid_hostname_character(character: char) -> bool {
    character.is_ascii_alphanumeric() || matches!(character, '.' | '-' | '_')
}

fn is_valid_ipv6_host_character(character: char) -> bool {
    character.is_ascii_hexdigit() || character == ':'
}

fn sanitize_identifier(
    raw: &str,
    field: &'static str,
) -> Result<String, ClickHouseLogStoreConfigError> {
    let value = raw.trim();
    if value.is_empty() {
        return Err(invalid_identifier(field, value, "must not be empty"));
    }
    if value.len() > MAX_IDENTIFIER_LEN {
        return Err(invalid_identifier(
            field,
            value,
            "must be 64 bytes or shorter",
        ));
    }
    if redact_secrets(value) != value {
        return Err(invalid_identifier(
            field,
            value,
            "must not contain secret-like material",
        ));
    }

    let mut characters = value.chars();
    let Some(first) = characters.next() else {
        return Err(invalid_identifier(field, value, "must not be empty"));
    };
    if !(first.is_ascii_alphabetic() || first == '_') {
        return Err(invalid_identifier(
            field,
            value,
            "must start with an ASCII letter or underscore",
        ));
    }
    if !characters.all(|character| character.is_ascii_alphanumeric() || character == '_') {
        return Err(invalid_identifier(
            field,
            value,
            "must contain only ASCII letters, digits, and underscore",
        ));
    }

    Ok(value.to_string())
}

fn parse_bool_env(
    vars: &BTreeMap<String, String>,
    keys: &[&str],
    default: bool,
    field: &'static str,
) -> Result<bool, ClickHouseLogStoreConfigError> {
    let Some(value) = first_nonempty_env(vars, keys) else {
        return Ok(default);
    };

    match normalize_config_value(value).as_str() {
        "1" | "true" | "yes" | "on" | "enabled" => Ok(true),
        "0" | "false" | "no" | "off" | "disabled" => Ok(false),
        _ => Err(ClickHouseLogStoreConfigError::InvalidBoolean {
            field,
            value: safe_config_value_for_error(value),
        }),
    }
}

fn parse_u32_env(
    vars: &BTreeMap<String, String>,
    keys: &[&str],
    default: u32,
    min: u32,
    max: u32,
    field: &'static str,
) -> Result<u32, ClickHouseLogStoreConfigError> {
    let value = parse_u64_env(
        vars,
        keys,
        u64::from(default),
        u64::from(min),
        u64::from(max),
        field,
    )?;

    Ok(value as u32)
}

fn parse_u64_env(
    vars: &BTreeMap<String, String>,
    keys: &[&str],
    default: u64,
    min: u64,
    max: u64,
    field: &'static str,
) -> Result<u64, ClickHouseLogStoreConfigError> {
    let Some(value) = first_nonempty_env(vars, keys) else {
        return Ok(default);
    };

    let Ok(parsed) = value.parse::<u64>() else {
        return Err(ClickHouseLogStoreConfigError::InvalidInteger {
            field,
            value: safe_config_value_for_error(value),
            min,
            max,
        });
    };

    if parsed < min || parsed > max {
        return Err(ClickHouseLogStoreConfigError::InvalidInteger {
            field,
            value: safe_config_value_for_error(value),
            min,
            max,
        });
    }

    Ok(parsed)
}

fn parse_drop_policy_env(
    vars: &BTreeMap<String, String>,
) -> Result<ClickHouseDropPolicy, ClickHouseLogStoreConfigError> {
    let Some(value) = first_nonempty_env(
        vars,
        &[
            "AI_GATEWAY_CLICKHOUSE_BACKPRESSURE_DROP_POLICY",
            "AI_GATEWAY_CLICKHOUSE_LOG_STORE_DROP_POLICY",
        ],
    ) else {
        return Ok(ClickHouseDropPolicy::DropNewest);
    };

    ClickHouseDropPolicy::parse(value).ok_or_else(|| {
        ClickHouseLogStoreConfigError::InvalidDropPolicy {
            value: safe_config_value_for_error(value),
        }
    })
}

fn default_retry_on() -> Vec<&'static str> {
    vec!["transport_error", "timeout", "http_429", "http_5xx"]
}

fn first_nonempty_env<'a>(vars: &'a BTreeMap<String, String>, keys: &[&str]) -> Option<&'a str> {
    keys.iter().find_map(|key| {
        vars.get(*key)
            .map(String::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
    })
}

fn normalize_config_value(value: &str) -> String {
    value
        .trim()
        .chars()
        .map(|character| {
            if matches!(character, '-' | ' ') {
                '_'
            } else {
                character.to_ascii_lowercase()
            }
        })
        .collect()
}

fn invalid_endpoint(endpoint: &str, reason: &'static str) -> ClickHouseLogStoreConfigError {
    ClickHouseLogStoreConfigError::InvalidEndpoint {
        endpoint: safe_endpoint_for_error(endpoint),
        reason,
    }
}

fn invalid_identifier(
    field: &'static str,
    value: &str,
    reason: &'static str,
) -> ClickHouseLogStoreConfigError {
    ClickHouseLogStoreConfigError::InvalidIdentifier {
        field,
        value: safe_config_value_for_error(value),
        reason,
    }
}

fn safe_endpoint_for_error(endpoint: &str) -> String {
    let endpoint = endpoint.split(['?', '#']).next().unwrap_or(endpoint).trim();
    let endpoint = redact_endpoint_userinfo(endpoint);
    let redacted = redact_secrets(&endpoint);
    truncate_for_error(&redacted, MAX_ERROR_VALUE_LEN)
}

fn safe_config_value_for_error(value: &str) -> String {
    truncate_for_error(&redact_secrets(value.trim()), MAX_ERROR_VALUE_LEN)
}

fn safe_wal_root_for_contract(value: &str) -> String {
    truncate_for_error(&redact_secrets(value.trim()), MAX_ENDPOINT_LEN)
}

fn wal_root_scope(value: &str) -> &'static str {
    let root = value.trim();
    if root.is_empty() || root.contains("..") || root.chars().any(char::is_control) {
        return "unsafe";
    }
    if root == ".tmp" || root.starts_with(".tmp/") || root.starts_with(".tmp\\") {
        return "artifact_tmp";
    }
    if root.starts_with('/') || root.starts_with('\\') || root.as_bytes().get(1) == Some(&b':') {
        return "production";
    }
    if root.starts_with("<data_dir>/") || root.starts_with("data/") || root.starts_with("var/") {
        return "production";
    }

    "unsafe"
}

fn redact_endpoint_userinfo(endpoint: &str) -> String {
    let Some((scheme, after_scheme)) = endpoint.split_once("://") else {
        return endpoint.to_string();
    };
    let authority_end = after_scheme.find('/').unwrap_or(after_scheme.len());
    let authority = &after_scheme[..authority_end];
    let Some(at_index) = authority.rfind('@') else {
        return endpoint.to_string();
    };

    let after_authority = &after_scheme[authority_end..];
    let host = &authority[at_index + 1..];
    format!("{scheme}://{REDACTED_SECRET}@{host}{after_authority}")
}

fn truncate_for_error(value: &str, max_len: usize) -> String {
    let mut output = String::new();

    for character in value.chars() {
        if output.len() + character.len_utf8() > max_len {
            output.push_str("...");
            return output;
        }
        output.push(character);
    }

    output
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClickHouseWalDryRunReadbackError {
    MissingField {
        field: &'static str,
    },
    InvalidField {
        field: &'static str,
        reason: &'static str,
    },
}

impl fmt::Display for ClickHouseWalDryRunReadbackError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingField { field } => {
                write!(f, "missing ClickHouse WAL dry-run readback field `{field}`")
            }
            Self::InvalidField { field, reason } => {
                write!(
                    f,
                    "invalid ClickHouse WAL dry-run readback field `{field}`: {reason}"
                )
            }
        }
    }
}

impl Error for ClickHouseWalDryRunReadbackError {}

#[derive(Debug, Clone, PartialEq, Eq)]
struct DedupJournalEntry {
    record_hash: String,
    payload_hash: String,
}

fn required_string<'a>(
    value: &'a Value,
    field: &'static str,
) -> Result<&'a str, ClickHouseWalDryRunReadbackError> {
    optional_string(value, field).ok_or(ClickHouseWalDryRunReadbackError::MissingField { field })
}

fn optional_string<'a>(value: &'a Value, field: &str) -> Option<&'a str> {
    value.get(field).and_then(Value::as_str).map(str::trim)
}

fn optional_u64(value: &Value, field: &str) -> Option<u64> {
    value.get(field).and_then(Value::as_u64)
}

fn normalize_sha256(raw: &str) -> Result<String, ClickHouseWalDryRunReadbackError> {
    let digest = raw.trim().strip_prefix("sha256:").unwrap_or(raw.trim());
    if digest.len() == 64
        && digest
            .chars()
            .all(|character| character.is_ascii_hexdigit())
    {
        Ok(format!("sha256:{}", digest.to_ascii_lowercase()))
    } else {
        Err(ClickHouseWalDryRunReadbackError::InvalidField {
            field: "payload_hash",
            reason: "must be a sha256 digest",
        })
    }
}

fn wal_path_safety(wal_root: &str, tenant_id: &str, segment_name: &str) -> Value {
    let tenant_partition = format!("tenant_id={tenant_id}");
    let root_is_relative = is_repo_relative_path(wal_root);
    let root_has_parent_traversal = path_has_parent_traversal(wal_root);
    let tenant_partition_safe = !tenant_partition.contains(['/', '\\'])
        && !tenant_partition.contains("..")
        && tenant_partition.chars().all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '_' | '-' | '=')
        });
    let segment_name_safe = segment_name.starts_with("wal-")
        && segment_name.ends_with(".jsonl")
        && !segment_name.contains(['/', '\\'])
        && !segment_name.contains("..")
        && segment_name.chars().all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '-' | '_' | '.')
        });
    let repo_local_safe = root_is_relative
        && !root_has_parent_traversal
        && tenant_partition_safe
        && segment_name_safe;

    json!({
        "wal_root": wal_root,
        "tenant_partition": tenant_partition,
        "segment_name": segment_name,
        "segment_relative_path": format!("{wal_root}/{tenant_partition}/{segment_name}"),
        "repo_local_safe": repo_local_safe,
        "root_is_relative": root_is_relative,
        "root_has_parent_traversal": root_has_parent_traversal,
        "tenant_partition_safe": tenant_partition_safe,
        "segment_name_safe": segment_name_safe,
        "absolute_path_allowed": false,
        "parent_traversal_allowed": false,
        "creates_directories": false,
        "writes_files": false
    })
}

fn is_repo_relative_path(path: &str) -> bool {
    let trimmed = path.trim();
    !trimmed.is_empty()
        && !trimmed.starts_with('/')
        && !trimmed.starts_with('\\')
        && !trimmed.starts_with("//")
        && !trimmed.starts_with("\\\\")
        && !trimmed.as_bytes().get(1).is_some_and(|byte| *byte == b':')
}

fn path_has_parent_traversal(path: &str) -> bool {
    path.split(['/', '\\']).any(|component| component == "..")
}

fn final_status_for_operation<'a>(
    status: &'a str,
    operation: &str,
    attempt: u64,
    retry_max_attempts: u64,
) -> &'a str {
    match operation {
        "ack" => "acked",
        "retry" if attempt.saturating_add(1) >= retry_max_attempts => "dead_letter",
        "retry" => "retry",
        "lease" => "leased",
        _ => status,
    }
}

fn retention_class_for_status(
    status: &str,
    age_seconds: u64,
    delete_acked_after_seconds: u64,
    delete_failed_after_seconds: u64,
) -> &'static str {
    match status {
        "acked" if age_seconds >= delete_acked_after_seconds => "eligible_acked_segment_delete",
        "acked" => "retain_acked_until_ttl",
        "dead_letter" if age_seconds >= delete_failed_after_seconds => {
            "eligible_failed_segment_delete"
        }
        "dead_letter" => "retain_failed_until_ttl",
        "retry" => "retain_retry",
        "leased" => "retain_leased",
        _ => "retain_pending",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const CLICKHOUSE_LOG_STORE_CONTRACT_FIXTURE: &str = include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../tests/fixtures/observability/clickhouse_log_store_contract.json"
    ));

    #[test]
    fn default_config_is_disabled_and_never_requests_network() {
        let config = ClickHouseLogStoreConfig::from_env_vars(std::iter::empty::<(&str, &str)>())
            .expect("default clickhouse config");
        let plan = config.write_plan();

        assert!(!config.is_enabled());
        assert!(!plan.network_requests_enabled());
        assert_eq!(plan.endpoint, None);
        assert_eq!(plan.database, DEFAULT_CLICKHOUSE_DATABASE);
        assert_eq!(plan.table, DEFAULT_CLICKHOUSE_TABLE);
        assert_eq!(plan.batch_size, DEFAULT_CLICKHOUSE_BATCH_SIZE);
        assert_eq!(plan.flush_interval_ms, DEFAULT_CLICKHOUSE_FLUSH_INTERVAL_MS);
        assert_eq!(plan.sinks().len(), 3);
        assert!(plan.sinks().iter().all(|sink| !sink.enabled));
        assert_eq!(
            plan.payload_policy.default_storage_mode,
            PayloadStorageMode::Hash
        );
        assert!(!plan.payload_policy.payload_body_by_default);
        assert!(!plan.payload_policy.payload_body_storage_enabled);
    }

    #[test]
    fn enabled_plan_redacts_credential_presence_and_keeps_secret_values_out() {
        let config = ClickHouseLogStoreConfig::from_env_vars([
            ("AI_GATEWAY_CLICKHOUSE_LOG_STORE_ENABLED", "true"),
            (
                "AI_GATEWAY_CLICKHOUSE_ENDPOINT",
                "https://clickhouse.example.com:8443",
            ),
            ("AI_GATEWAY_CLICKHOUSE_DATABASE", "prod_logs"),
            ("AI_GATEWAY_CLICKHOUSE_TABLE", "gateway_events"),
            ("AI_GATEWAY_CLICKHOUSE_BATCH_SIZE", "2500"),
            ("AI_GATEWAY_CLICKHOUSE_FLUSH_INTERVAL_MS", "750"),
            ("AI_GATEWAY_CLICKHOUSE_USERNAME", "ops-user"),
            ("AI_GATEWAY_CLICKHOUSE_PASSWORD", "plain-password"),
            ("AI_GATEWAY_CLICKHOUSE_TOKEN", "fixture-api-secret"),
            (
                "AI_GATEWAY_CLICKHOUSE_AUTHORIZATION",
                "Bearer fixture-bearer-secret",
            ),
            ("AI_GATEWAY_CLICKHOUSE_PAYLOAD_POLICY", "redacted"),
        ])
        .expect("enabled clickhouse config");
        let plan = config.write_plan();
        let rendered = format!("{config:?}\n{plan:?}\n{}", plan.to_contract_json());

        assert!(plan.enabled);
        assert_eq!(
            plan.endpoint.as_deref(),
            Some("https://clickhouse.example.com:8443")
        );
        assert!(plan.tls.enabled);
        assert!(plan.tls.verify_certificate);
        assert!(plan.credentials.basic_user);
        assert!(plan.credentials.basic_secret);
        assert!(plan.credentials.api_secret);
        assert!(plan.credentials.bearer_header);
        assert!(!rendered.contains("plain-password"));
        assert!(!rendered.contains("fixture-api-secret"));
        assert!(!rendered.contains("fixture-bearer-secret"));
        assert!(!rendered.contains("Bearer fixture-bearer-secret"));
        assert!(!rendered.contains("raw_payload"));
    }

    #[test]
    fn full_payload_policy_is_downgraded_for_clickhouse_plan() {
        let config = ClickHouseLogStoreConfig::from_env_vars([
            ("AI_GATEWAY_CLICKHOUSE_LOG_STORE_ENABLED", "true"),
            ("AI_GATEWAY_CLICKHOUSE_ENDPOINT", "http://localhost:8123"),
            ("AI_GATEWAY_CLICKHOUSE_PAYLOAD_POLICY", "full"),
        ])
        .expect("full payload config");
        let plan = config.write_plan();

        assert_eq!(plan.payload_policy.requested_policy, "full");
        assert_eq!(plan.payload_policy.effective_policy, PayloadPolicy::Hash);
        assert_eq!(
            plan.payload_policy.fallback_reason,
            Some("payload_body_storage_disabled")
        );
        assert!(!plan.payload_policy.payload_body_by_default);
        assert!(!plan.payload_policy.payload_body_storage_enabled);
    }

    #[test]
    fn invalid_endpoint_errors_are_secret_safe() {
        let error = ClickHouseLogStoreConfig::from_env_vars([
            ("AI_GATEWAY_CLICKHOUSE_LOG_STORE_ENABLED", "true"),
            (
                "AI_GATEWAY_CLICKHOUSE_ENDPOINT",
                "https://alice:plain-password@clickhouse.example.com:8443?api_key=fixture-api-secret",
            ),
        ])
        .unwrap_err()
        .to_string();

        assert!(error.contains("clickhouse.example.com"));
        assert!(error.contains("query strings"));
        assert!(!error.contains("alice"));
        assert!(!error.contains("plain-password"));
        assert!(!error.contains("api_key"));
        assert!(!error.contains("fixture-api-secret"));
    }

    #[test]
    fn clickhouse_log_store_contract_fixture_matches_plan_boundary() {
        let fixture: Value = serde_json::from_str(CLICKHOUSE_LOG_STORE_CONTRACT_FIXTURE)
            .expect("clickhouse log store contract fixture");

        assert_eq!(fixture["contract"], CLICKHOUSE_LOG_STORE_CONTRACT_VERSION);
        assert_eq!(fixture["network_requests"], "never");
        assert_eq!(fixture["runtime_connected"], false);

        let default_config =
            ClickHouseLogStoreConfig::from_env_vars(env_pairs(&fixture["default"]))
                .expect("default fixture config");
        assert_eq!(
            default_config.write_plan().to_contract_json(),
            fixture["default"]["expected"]
        );

        for case in fixture["plans"].as_array().expect("plan cases") {
            let config =
                ClickHouseLogStoreConfig::from_env_vars(env_pairs(case)).expect("plan config");
            let plan = config.write_plan();

            assert_eq!(
                plan.to_contract_json(),
                case["expected"],
                "{}",
                case["name"]
            );
            assert!(!plan.network_requests_enabled());

            let rendered = plan.to_contract_json().to_string();
            for excluded in fixture["secret_safe_output_excludes"]
                .as_array()
                .expect("secret-safe excludes")
            {
                let excluded = excluded.as_str().expect("excluded string");
                assert!(
                    !rendered.contains(excluded),
                    "plan output for {} should not contain {}",
                    case["name"],
                    excluded
                );
            }
        }

        for case in fixture["errors"].as_array().expect("error cases") {
            let error = ClickHouseLogStoreConfig::from_env_vars(env_pairs(case))
                .expect_err("invalid config")
                .to_string();

            for expected in case["expected_error_contains"]
                .as_array()
                .expect("expected error contains")
            {
                let expected = expected.as_str().expect("expected contains string");
                assert!(
                    error.contains(expected),
                    "error `{error}` should contain `{expected}`"
                );
            }

            for excluded in case["expected_error_excludes"]
                .as_array()
                .expect("expected error excludes")
            {
                let excluded = excluded.as_str().expect("expected excludes string");
                assert!(
                    !error.contains(excluded),
                    "error `{error}` should not contain `{excluded}`"
                );
            }
        }
    }

    #[test]
    fn wal_service_guard_distinguishes_production_root_from_runtime_artifact_tmp() {
        let missing_root = ClickHouseLogStoreConfig::from_env_vars([
            ("AI_GATEWAY_CLICKHOUSE_LOG_STORE_ENABLED", "true"),
            ("AI_GATEWAY_CLICKHOUSE_ENDPOINT", "http://localhost:8123"),
            ("AI_GATEWAY_CLICKHOUSE_WAL_SERVICE_ENABLED", "true"),
        ])
        .expect("missing production root should be a config readback blocker")
        .write_plan()
        .to_contract_json();
        let missing_guard = &missing_root["wal_service_guard"];

        assert_eq!(missing_guard["readiness"], "blocked");
        assert_eq!(missing_guard["blocker"], "production_wal_root_missing");
        assert_eq!(
            missing_guard["production_service_readiness"]["requires_production_root"],
            true
        );
        assert_eq!(
            missing_guard["runtime_artifact_path_contract"]["can_satisfy_production_wal_root"],
            false
        );
        assert_eq!(
            missing_guard["runtime_artifact_path_contract"]["service_readiness_artifact_allowed"],
            true
        );
        assert_eq!(
            missing_guard["service_execution_dry_run_contract"]["service_loop_start_enabled"],
            false
        );
        assert_eq!(
            missing_guard["final_dod_contract_summary"]["readiness_or_artifact_proof_can_mark_final_x"],
            false
        );
        assert_eq!(
            missing_guard["production_smoke_handoff_summary"]["default_network_requests"],
            false
        );
        assert_eq!(
            missing_guard["production_smoke_handoff_summary"]["requires_explicit_live_opt_in"],
            true
        );
        assert_eq!(
            missing_guard["production_smoke_acceptance_gate_summary"]["default_reads_artifact"],
            false
        );
        assert_eq!(
            missing_guard["production_smoke_acceptance_gate_summary"]["requires_explicit_artifact_readback"],
            true
        );
        assert_eq!(
            missing_guard["final_closure_audit_summary"]["audit_without_real_artifact_can_mark_final_x"],
            false
        );
        assert_eq!(
            missing_guard["final_closure_audit_summary"]["watcher_can_mark_final_x"],
            false
        );

        let tmp_root = ClickHouseLogStoreConfig::from_env_vars([
            ("AI_GATEWAY_CLICKHOUSE_LOG_STORE_ENABLED", "true"),
            ("AI_GATEWAY_CLICKHOUSE_ENDPOINT", "http://localhost:8123"),
            ("AI_GATEWAY_CLICKHOUSE_WAL_SERVICE_ENABLED", "true"),
            (
                "AI_GATEWAY_CLICKHOUSE_WAL_DIR",
                ".tmp/clickhouse-log-store/wal",
            ),
        ])
        .expect("tmp root should parse but not satisfy production service readiness")
        .write_plan()
        .to_contract_json();
        let tmp_guard = &tmp_root["wal_service_guard"];

        assert_eq!(tmp_guard["root_scope"], "artifact_tmp");
        assert_eq!(tmp_guard["readiness"], "blocked");
        assert_eq!(
            tmp_guard["blocker"],
            "production_wal_root_points_to_artifact_tmp"
        );
        assert_eq!(
            tmp_guard["runtime_artifact_path_contract"]["artifact_tmp_root_is_production_blocker"],
            true
        );
        assert_eq!(
            tmp_guard["service_execution_dry_run_contract"]["production_wal_root_write_enabled"],
            false
        );

        let production_root = ClickHouseLogStoreConfig::from_env_vars([
            ("AI_GATEWAY_CLICKHOUSE_LOG_STORE_ENABLED", "true"),
            ("AI_GATEWAY_CLICKHOUSE_ENDPOINT", "http://localhost:8123"),
            ("AI_GATEWAY_CLICKHOUSE_WAL_SERVICE_ENABLED", "true"),
            (
                "AI_GATEWAY_CLICKHOUSE_WAL_DIR",
                "/var/lib/ai-gateway/clickhouse-log-store/wal",
            ),
        ])
        .expect("production root should satisfy config presence")
        .write_plan()
        .to_contract_json();
        let production_guard = &production_root["wal_service_guard"];

        assert_eq!(production_guard["root_scope"], "production");
        assert_eq!(production_guard["readiness"], "ready");
        assert_eq!(production_guard["blocker"], Value::Null);
        assert_eq!(
            production_guard["production_wal_writes_enabled_in_this_slice"],
            false
        );
        assert_eq!(
            production_guard["clickhouse_network_requests_enabled"],
            false
        );
        assert_eq!(
            production_guard["service_execution_dry_run_contract"]["clickhouse_send_enabled"],
            false
        );
        assert_eq!(
            production_guard["final_dod_contract_summary"]["readiness_or_artifact_proof_can_mark_production_ready"],
            true
        );
        assert_eq!(
            production_guard["final_dod_contract_summary"]["final_x_requires_live_smoke_readback"],
            true
        );
        assert_eq!(
            production_guard["production_smoke_handoff_summary"]["final_x_requires_live_smoke_readback"],
            true
        );
        assert_eq!(
            production_guard["production_smoke_handoff_summary"]["simulated_artifact_can_pass"],
            false
        );
        assert_eq!(
            production_guard["production_smoke_handoff_summary"]["handoff_can_mark_final_x"],
            false
        );
        assert_eq!(
            production_guard["production_smoke_acceptance_gate_summary"]["simulation_can_mark_final_x"],
            false
        );
        assert_eq!(
            production_guard["production_smoke_acceptance_gate_summary"]["fixture_can_mark_final_x"],
            false
        );
        assert_eq!(
            production_guard["production_smoke_acceptance_gate_summary"]["refusal_can_mark_final_x"],
            false
        );
        assert_eq!(
            production_guard["final_closure_audit_summary"]["final_x_requires_real_writer_cursor_wal_dedup_load_retention_secret_safe"],
            true
        );
        assert_eq!(
            production_guard["production_smoke_acceptance_gate_summary"]["unsafe_path_refusal"],
            true
        );
    }

    #[test]
    fn clickhouse_wal_dry_run_readback_fixture_proves_bounded_local_contract() {
        let fixture: Value = serde_json::from_str(CLICKHOUSE_LOG_STORE_CONTRACT_FIXTURE)
            .expect("clickhouse log store contract fixture");
        let wal_fixture = &fixture["wal_dry_run_readback"];
        let contract = clickhouse_wal_dry_run_readback_contract(&wal_fixture["input"])
            .expect("wal dry-run readback contract");
        let expected = &wal_fixture["expected"];

        assert_eq!(contract["contract"], expected["contract"]);
        assert_eq!(contract["mode"], expected["mode"]);
        assert_eq!(contract["read_only"], true);
        assert_eq!(contract["clickhouse_connected"], false);
        assert_eq!(contract["network_requests"], false);
        assert_eq!(contract["file_system_writes"], false);
        assert_eq!(
            contract["path_safety"]["repo_local_safe"],
            expected["path_repo_local_safe"]
        );
        assert_eq!(contract["path_safety"]["absolute_path_allowed"], false);
        assert_eq!(contract["path_safety"]["parent_traversal_allowed"], false);
        assert_eq!(
            contract["segment"]["record_count"],
            expected["record_count"]
        );
        assert_eq!(contract["segment"]["bounded_disk"], true);
        assert_eq!(contract["segment"]["within_segment_budget"], true);
        assert_eq!(contract["segment"]["dry_run_writes_segment"], false);
        assert_eq!(
            contract["write_readback_evidence"]["readback_hash_match_count"],
            expected["readback_hash_match_count"]
        );
        assert_eq!(
            contract["write_readback_evidence"]["dedup_journal_entries"],
            expected["dedup_journal_entries"]
        );
        assert_eq!(
            contract["write_readback_evidence"]["records"][3]["journal_decision"],
            "skip_duplicate_same_record_hash"
        );
        assert_eq!(
            contract["retention"]["pending_or_leased_records"],
            expected["pending_or_leased_records"]
        );
        assert_eq!(
            contract["retention"]["safe_to_delete_segment"],
            expected["safe_to_delete_segment"]
        );
        assert_eq!(
            contract["retention"]["classification_counts"],
            expected["classification_counts"]
        );
    }

    fn env_pairs(case: &Value) -> Vec<(String, String)> {
        case["env"]
            .as_object()
            .map(|env| {
                env.iter()
                    .map(|(key, value)| {
                        (
                            key.clone(),
                            value.as_str().expect("env value string").to_string(),
                        )
                    })
                    .collect()
            })
            .unwrap_or_default()
    }
}
