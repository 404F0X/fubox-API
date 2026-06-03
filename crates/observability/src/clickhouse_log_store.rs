use std::{collections::BTreeMap, env, error::Error, fmt};

use serde_json::{Value, json};

use crate::{
    REDACTED_SECRET,
    payload_policy::{PayloadPolicy, PayloadStorageMode},
    redact_secrets,
};

pub const CLICKHOUSE_LOG_STORE_CONTRACT_VERSION: &str = "clickhouse_log_store_plan_v1";
pub const DEFAULT_CLICKHOUSE_DATABASE: &str = "ai_gateway";
pub const DEFAULT_CLICKHOUSE_TABLE: &str = "gateway_logs";
pub const DEFAULT_CLICKHOUSE_BATCH_SIZE: u32 = 1_000;
pub const DEFAULT_CLICKHOUSE_FLUSH_INTERVAL_MS: u64 = 1_000;
pub const DEFAULT_CLICKHOUSE_MAX_QUEUE_ROWS: u32 = 100_000;
pub const DEFAULT_CLICKHOUSE_RETRY_MAX_ATTEMPTS: u32 = 3;
pub const DEFAULT_CLICKHOUSE_RETRY_INITIAL_BACKOFF_MS: u64 = 100;
pub const DEFAULT_CLICKHOUSE_RETRY_MAX_BACKOFF_MS: u64 = 5_000;
pub const DEFAULT_CLICKHOUSE_PAYLOAD_POLICY: &str = "hash";

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
        payload_policy: clickhouse_payload_policy_plan(&config.requested_payload_policy),
    }
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
