use std::{
    collections::BTreeMap,
    fmt::{Display, Write},
    sync::{Mutex, OnceLock},
};

use serde_json::{Map, Value};
use tracing_subscriber::{EnvFilter, fmt};

pub mod clickhouse_log_store;
pub mod otel;
pub mod payload_policy;
pub mod prompt_protection;

pub use clickhouse_log_store::{
    CLICKHOUSE_LOG_STORE_CONTRACT_VERSION, ClickHouseBackpressureConfig,
    ClickHouseCredentialPresence, ClickHouseDropPolicy, ClickHouseLogSink,
    ClickHouseLogStoreConfig, ClickHouseLogStoreConfigError, ClickHouseLogStorePlan,
    ClickHousePayloadPolicyPlan, ClickHouseRetryPolicy, ClickHouseSinkPlan, ClickHouseTlsConfig,
    DEFAULT_CLICKHOUSE_BATCH_SIZE, DEFAULT_CLICKHOUSE_DATABASE,
    DEFAULT_CLICKHOUSE_FLUSH_INTERVAL_MS, DEFAULT_CLICKHOUSE_MAX_QUEUE_ROWS,
    DEFAULT_CLICKHOUSE_PAYLOAD_POLICY, DEFAULT_CLICKHOUSE_RETRY_INITIAL_BACKOFF_MS,
    DEFAULT_CLICKHOUSE_RETRY_MAX_ATTEMPTS, DEFAULT_CLICKHOUSE_RETRY_MAX_BACKOFF_MS,
    DEFAULT_CLICKHOUSE_TABLE, plan_clickhouse_log_store,
};
pub use otel::{
    DEFAULT_OTEL_SERVICE_NAME, OtelConfig, OtelConfigError, OtelExporter, OtelInit,
    init_otel_exporter, sanitize_otel_resource_attributes, sanitize_otel_service_name,
};
pub use payload_policy::{
    DEFAULT_PAYLOAD_POLICY_PREVIEW_MAX_BYTES, PayloadPolicy, PayloadPolicyDecision,
    PayloadPolicyInput, PayloadPolicyOptions, PayloadStorageMode, apply_payload_policy,
    apply_payload_policy_to_json, apply_payload_policy_with_options, payload_sha256_hex,
};
pub use prompt_protection::{
    PromptProtectionAction, PromptProtectionHit, PromptProtectionHitKind, PromptProtectionResult,
    protect_prompt_json, protect_prompt_payload, protect_prompt_text,
};

pub const REDACTED_SECRET: &str = "[REDACTED]";

const SECRET_TOKEN_PREFIXES: &[&str] = &[
    "sk-",
    "sk_",
    "vk_",
    "dev_test_key_",
    "AIza",
    "xoxb-",
    "ghp_",
    "github_pat_",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PrometheusMetricType {
    Counter,
    Gauge,
    Histogram,
    Summary,
    Untyped,
}

impl PrometheusMetricType {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Counter => "counter",
            Self::Gauge => "gauge",
            Self::Histogram => "histogram",
            Self::Summary => "summary",
            Self::Untyped => "untyped",
        }
    }
}

const REQUEST_LATENCY_BUCKET_COUNT: usize = 12;
const REQUEST_LATENCY_BUCKETS_MS: [u64; REQUEST_LATENCY_BUCKET_COUNT] = [
    5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 30_000,
];
const UNKNOWN_LABEL_VALUE: &str = "unknown";
const NO_ERROR_LABEL_VALUE: &str = "none";

#[derive(Debug, Default)]
struct GatewayMetricsRegistry {
    requests: BTreeMap<RequestMetricKey, u64>,
    errors: BTreeMap<ErrorMetricKey, u64>,
    request_latency: BTreeMap<LatencyMetricKey, LatencyHistogram>,
    request_ttft: BTreeMap<TtftMetricKey, LatencyHistogram>,
    fallbacks: BTreeMap<FallbackMetricKey, u64>,
    request_cost: BTreeMap<CostMetricKey, f64>,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct RequestMetricKey {
    endpoint: String,
    method: String,
    status: String,
    status_class: String,
    outcome: String,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct ErrorMetricKey {
    endpoint: String,
    method: String,
    status: String,
    status_class: String,
    owner: String,
    code: String,
    retryable: String,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct LatencyMetricKey {
    endpoint: String,
    method: String,
    status_class: String,
    outcome: String,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct TtftMetricKey {
    endpoint: String,
    method: String,
    status: String,
    status_class: String,
    outcome: String,
    error_owner: String,
    error_code: String,
}

struct RequestTtftLabels<'a> {
    endpoint: &'a str,
    method: &'a str,
    status: i32,
    outcome: &'a str,
    error_owner: Option<&'a str>,
    error_code: Option<&'a str>,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct FallbackMetricKey {
    endpoint: String,
    method: String,
    reason: String,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct CostMetricKey {
    endpoint: String,
    method: String,
    currency: String,
}

#[derive(Debug, Clone, Default)]
struct LatencyHistogram {
    bucket_counts: [u64; REQUEST_LATENCY_BUCKET_COUNT],
    count: u64,
    sum_ms: u64,
}

impl GatewayMetricsRegistry {
    fn record_request(
        &mut self,
        endpoint: &str,
        method: &str,
        status: i32,
        outcome: &str,
        latency_ms: i32,
    ) {
        let endpoint = bounded_label_value(endpoint);
        let method = bounded_label_value(method);
        let status = status_label(status);
        let status_class = status_class_label(&status);
        let outcome = bounded_label_value(outcome);
        let key = RequestMetricKey {
            endpoint: endpoint.clone(),
            method: method.clone(),
            status: status.clone(),
            status_class: status_class.clone(),
            outcome: outcome.clone(),
        };

        *self.requests.entry(key).or_default() += 1;
        self.request_latency
            .entry(LatencyMetricKey {
                endpoint,
                method,
                status_class,
                outcome,
            })
            .or_default()
            .observe(non_negative_u64(latency_ms));
    }

    fn record_request_ttft(&mut self, labels: RequestTtftLabels<'_>, ttft_ms: i32) {
        let status = status_label(labels.status);
        let key = TtftMetricKey {
            endpoint: bounded_label_value(labels.endpoint),
            method: bounded_label_value(labels.method),
            status_class: status_class_label(&status),
            status,
            outcome: bounded_label_value(labels.outcome),
            error_owner: optional_error_label_value(labels.error_owner),
            error_code: optional_error_label_value(labels.error_code),
        };

        self.request_ttft
            .entry(key)
            .or_default()
            .observe(non_negative_u64(ttft_ms));
    }

    fn record_error(
        &mut self,
        endpoint: &str,
        method: &str,
        status: i32,
        owner: &str,
        code: &str,
        retryable: Option<bool>,
    ) {
        let status = status_label(status);
        let key = ErrorMetricKey {
            endpoint: bounded_label_value(endpoint),
            method: bounded_label_value(method),
            status_class: status_class_label(&status),
            status,
            owner: bounded_label_value(owner),
            code: bounded_label_value(code),
            retryable: retryable_label(retryable).to_string(),
        };

        *self.errors.entry(key).or_default() += 1;
    }

    fn record_fallback(&mut self, endpoint: &str, method: &str, reason: &str) {
        let key = FallbackMetricKey {
            endpoint: bounded_label_value(endpoint),
            method: bounded_label_value(method),
            reason: bounded_label_value(reason),
        };

        *self.fallbacks.entry(key).or_default() += 1;
    }

    fn record_cost(&mut self, endpoint: &str, method: &str, currency: &str, amount: &str) {
        let Ok(amount) = amount.parse::<f64>() else {
            return;
        };
        if !amount.is_finite() || amount <= 0.0 {
            return;
        }

        let key = CostMetricKey {
            endpoint: bounded_label_value(endpoint),
            method: bounded_label_value(method),
            currency: currency_label(currency),
        };

        *self.request_cost.entry(key).or_default() += amount;
    }

    fn render(&self, service_name: &str) -> String {
        let mut output = String::new();

        self.render_requests(service_name, &mut output);
        self.render_errors(service_name, &mut output);
        self.render_request_latency(service_name, &mut output);
        self.render_request_ttft(service_name, &mut output);
        self.render_fallbacks(service_name, &mut output);
        self.render_request_cost(service_name, &mut output);

        output
    }

    fn render_requests(&self, service_name: &str, output: &mut String) {
        if self.requests.is_empty() {
            return;
        }

        let metric_name = append_metric_header(
            output,
            "ai_gateway_requests_total",
            PrometheusMetricType::Counter,
            "Total gateway API requests by endpoint, status, and outcome",
        );
        for (key, value) in &self.requests {
            output.push_str(&prometheus_sample(
                &metric_name,
                &[
                    ("service", service_name),
                    ("endpoint", key.endpoint.as_str()),
                    ("method", key.method.as_str()),
                    ("status", key.status.as_str()),
                    ("status_class", key.status_class.as_str()),
                    ("outcome", key.outcome.as_str()),
                ],
                value,
            ));
        }
    }

    fn render_errors(&self, service_name: &str, output: &mut String) {
        if self.errors.is_empty() {
            return;
        }

        let metric_name = append_metric_header(
            output,
            "ai_gateway_errors_total",
            PrometheusMetricType::Counter,
            "Total gateway API errors by endpoint, owner, code, and retryability",
        );
        for (key, value) in &self.errors {
            output.push_str(&prometheus_sample(
                &metric_name,
                &[
                    ("service", service_name),
                    ("endpoint", key.endpoint.as_str()),
                    ("method", key.method.as_str()),
                    ("status", key.status.as_str()),
                    ("status_class", key.status_class.as_str()),
                    ("owner", key.owner.as_str()),
                    ("code", key.code.as_str()),
                    ("retryable", key.retryable.as_str()),
                ],
                value,
            ));
        }
    }

    fn render_request_latency(&self, service_name: &str, output: &mut String) {
        if self.request_latency.is_empty() {
            return;
        }

        let metric_name = append_metric_header(
            output,
            "ai_gateway_request_latency_ms",
            PrometheusMetricType::Histogram,
            "Gateway API request latency in milliseconds",
        );
        let bucket_metric_name = format!("{metric_name}_bucket");
        let sum_metric_name = format!("{metric_name}_sum");
        let count_metric_name = format!("{metric_name}_count");

        for (key, histogram) in &self.request_latency {
            for (bucket_index, bucket) in REQUEST_LATENCY_BUCKETS_MS.iter().enumerate() {
                let le = bucket.to_string();
                output.push_str(&prometheus_sample(
                    &bucket_metric_name,
                    &[
                        ("service", service_name),
                        ("endpoint", key.endpoint.as_str()),
                        ("method", key.method.as_str()),
                        ("status_class", key.status_class.as_str()),
                        ("outcome", key.outcome.as_str()),
                        ("le", le.as_str()),
                    ],
                    histogram.bucket_counts[bucket_index],
                ));
            }
            output.push_str(&prometheus_sample(
                &bucket_metric_name,
                &[
                    ("service", service_name),
                    ("endpoint", key.endpoint.as_str()),
                    ("method", key.method.as_str()),
                    ("status_class", key.status_class.as_str()),
                    ("outcome", key.outcome.as_str()),
                    ("le", "+Inf"),
                ],
                histogram.count,
            ));
            output.push_str(&prometheus_sample(
                &sum_metric_name,
                &[
                    ("service", service_name),
                    ("endpoint", key.endpoint.as_str()),
                    ("method", key.method.as_str()),
                    ("status_class", key.status_class.as_str()),
                    ("outcome", key.outcome.as_str()),
                ],
                histogram.sum_ms,
            ));
            output.push_str(&prometheus_sample(
                &count_metric_name,
                &[
                    ("service", service_name),
                    ("endpoint", key.endpoint.as_str()),
                    ("method", key.method.as_str()),
                    ("status_class", key.status_class.as_str()),
                    ("outcome", key.outcome.as_str()),
                ],
                histogram.count,
            ));
        }
    }

    fn render_request_ttft(&self, service_name: &str, output: &mut String) {
        if self.request_ttft.is_empty() {
            return;
        }

        let metric_name = append_metric_header(
            output,
            "ai_gateway_request_ttft_ms",
            PrometheusMetricType::Histogram,
            "Gateway API request time to first token in milliseconds",
        );
        let bucket_metric_name = format!("{metric_name}_bucket");
        let sum_metric_name = format!("{metric_name}_sum");
        let count_metric_name = format!("{metric_name}_count");

        for (key, histogram) in &self.request_ttft {
            for (bucket_index, bucket) in REQUEST_LATENCY_BUCKETS_MS.iter().enumerate() {
                let le = bucket.to_string();
                output.push_str(&prometheus_sample(
                    &bucket_metric_name,
                    &[
                        ("service", service_name),
                        ("endpoint", key.endpoint.as_str()),
                        ("method", key.method.as_str()),
                        ("status", key.status.as_str()),
                        ("status_class", key.status_class.as_str()),
                        ("outcome", key.outcome.as_str()),
                        ("error_owner", key.error_owner.as_str()),
                        ("error_code", key.error_code.as_str()),
                        ("le", le.as_str()),
                    ],
                    histogram.bucket_counts[bucket_index],
                ));
            }
            output.push_str(&prometheus_sample(
                &bucket_metric_name,
                &[
                    ("service", service_name),
                    ("endpoint", key.endpoint.as_str()),
                    ("method", key.method.as_str()),
                    ("status", key.status.as_str()),
                    ("status_class", key.status_class.as_str()),
                    ("outcome", key.outcome.as_str()),
                    ("error_owner", key.error_owner.as_str()),
                    ("error_code", key.error_code.as_str()),
                    ("le", "+Inf"),
                ],
                histogram.count,
            ));
            output.push_str(&prometheus_sample(
                &sum_metric_name,
                &[
                    ("service", service_name),
                    ("endpoint", key.endpoint.as_str()),
                    ("method", key.method.as_str()),
                    ("status", key.status.as_str()),
                    ("status_class", key.status_class.as_str()),
                    ("outcome", key.outcome.as_str()),
                    ("error_owner", key.error_owner.as_str()),
                    ("error_code", key.error_code.as_str()),
                ],
                histogram.sum_ms,
            ));
            output.push_str(&prometheus_sample(
                &count_metric_name,
                &[
                    ("service", service_name),
                    ("endpoint", key.endpoint.as_str()),
                    ("method", key.method.as_str()),
                    ("status", key.status.as_str()),
                    ("status_class", key.status_class.as_str()),
                    ("outcome", key.outcome.as_str()),
                    ("error_owner", key.error_owner.as_str()),
                    ("error_code", key.error_code.as_str()),
                ],
                histogram.count,
            ));
        }
    }

    fn render_fallbacks(&self, service_name: &str, output: &mut String) {
        if self.fallbacks.is_empty() {
            return;
        }

        let metric_name = append_metric_header(
            output,
            "ai_gateway_fallbacks_total",
            PrometheusMetricType::Counter,
            "Total gateway provider fallback attempts by endpoint and reason",
        );
        for (key, value) in &self.fallbacks {
            output.push_str(&prometheus_sample(
                &metric_name,
                &[
                    ("service", service_name),
                    ("endpoint", key.endpoint.as_str()),
                    ("method", key.method.as_str()),
                    ("reason", key.reason.as_str()),
                ],
                value,
            ));
        }
    }

    fn render_request_cost(&self, service_name: &str, output: &mut String) {
        if self.request_cost.is_empty() {
            return;
        }

        let metric_name = append_metric_header(
            output,
            "ai_gateway_request_cost_total",
            PrometheusMetricType::Counter,
            "Total rated gateway request cost by endpoint and currency",
        );
        for (key, value) in &self.request_cost {
            output.push_str(&prometheus_sample(
                &metric_name,
                &[
                    ("service", service_name),
                    ("endpoint", key.endpoint.as_str()),
                    ("method", key.method.as_str()),
                    ("currency", key.currency.as_str()),
                ],
                value,
            ));
        }
    }
}

impl LatencyHistogram {
    fn observe(&mut self, latency_ms: u64) {
        self.count = self.count.saturating_add(1);
        self.sum_ms = self.sum_ms.saturating_add(latency_ms);
        for (index, bucket) in REQUEST_LATENCY_BUCKETS_MS.iter().enumerate() {
            if latency_ms <= *bucket {
                self.bucket_counts[index] = self.bucket_counts[index].saturating_add(1);
            }
        }
    }
}

fn global_gateway_metrics() -> &'static Mutex<GatewayMetricsRegistry> {
    static GATEWAY_METRICS: OnceLock<Mutex<GatewayMetricsRegistry>> = OnceLock::new();
    GATEWAY_METRICS.get_or_init(|| Mutex::new(GatewayMetricsRegistry::default()))
}

fn with_gateway_metrics<R>(f: impl FnOnce(&GatewayMetricsRegistry) -> R) -> R {
    match global_gateway_metrics().lock() {
        Ok(metrics) => f(&metrics),
        Err(poisoned) => {
            let metrics = poisoned.into_inner();
            f(&metrics)
        }
    }
}

fn with_gateway_metrics_mut<R>(f: impl FnOnce(&mut GatewayMetricsRegistry) -> R) -> R {
    match global_gateway_metrics().lock() {
        Ok(mut metrics) => f(&mut metrics),
        Err(poisoned) => {
            let mut metrics = poisoned.into_inner();
            f(&mut metrics)
        }
    }
}

fn append_metric_header(
    output: &mut String,
    name: &str,
    metric_type: PrometheusMetricType,
    help: &str,
) -> String {
    let metric_name = prometheus_metric_name(name);
    let _ = writeln!(
        output,
        "# HELP {metric_name} {}",
        escape_prometheus_help(help)
    );
    let _ = writeln!(output, "# TYPE {metric_name} {}", metric_type.as_str());
    metric_name
}

fn bounded_label_value(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty()
        || trimmed.len() > 64
        || trimmed.chars().any(char::is_control)
        || redact_secrets(trimmed) != trimmed
    {
        UNKNOWN_LABEL_VALUE.to_string()
    } else if trimmed.chars().all(is_safe_metric_label_character) {
        trimmed.to_string()
    } else {
        UNKNOWN_LABEL_VALUE.to_string()
    }
}

fn optional_error_label_value(raw: Option<&str>) -> String {
    raw.map(bounded_label_value)
        .unwrap_or_else(|| NO_ERROR_LABEL_VALUE.to_string())
}

fn is_safe_metric_label_character(character: char) -> bool {
    character.is_ascii_alphanumeric() || matches!(character, '_' | '-' | '.' | ':')
}

fn currency_label(raw: &str) -> String {
    let currency = raw.trim().to_ascii_uppercase();
    if (3..=12).contains(&currency.len())
        && currency
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || character == '_')
    {
        currency
    } else {
        UNKNOWN_LABEL_VALUE.to_string()
    }
}

fn status_label(status: i32) -> String {
    if (100..=599).contains(&status) {
        status.to_string()
    } else {
        UNKNOWN_LABEL_VALUE.to_string()
    }
}

fn status_class_label(status: &str) -> String {
    status
        .parse::<u16>()
        .ok()
        .filter(|status| (100..=599).contains(status))
        .map(|status| format!("{}xx", status / 100))
        .unwrap_or_else(|| UNKNOWN_LABEL_VALUE.to_string())
}

fn retryable_label(retryable: Option<bool>) -> &'static str {
    match retryable {
        Some(true) => "true",
        Some(false) => "false",
        None => UNKNOWN_LABEL_VALUE,
    }
}

fn non_negative_u64(value: i32) -> u64 {
    u64::try_from(value).unwrap_or(0)
}

pub fn init_tracing(service_name: &'static str) {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    let subscriber = fmt().with_env_filter(filter).finish();
    let _ = tracing::subscriber::set_global_default(subscriber);
    tracing::info!(service.name = service_name, "tracing initialized");
}

pub fn metrics_body(service_name: &str) -> String {
    with_gateway_metrics(|metrics| metrics_body_with_gateway_metrics(service_name, metrics))
}

fn metrics_body_with_gateway_metrics(
    service_name: &str,
    metrics: &GatewayMetricsRegistry,
) -> String {
    let mut body = prometheus_metric_family(
        "ai_gateway_service_up",
        PrometheusMetricType::Gauge,
        "Service availability flag",
        &[("service", service_name)],
        1,
    );
    body.push_str(&metrics.render(service_name));
    body
}

pub fn record_gateway_request(
    endpoint: &str,
    method: &str,
    status: i32,
    outcome: &str,
    latency_ms: i32,
) {
    with_gateway_metrics_mut(|metrics| {
        metrics.record_request(endpoint, method, status, outcome, latency_ms);
    });
}

pub fn record_gateway_error(
    endpoint: &str,
    method: &str,
    status: i32,
    owner: &str,
    code: &str,
    retryable: Option<bool>,
) {
    with_gateway_metrics_mut(|metrics| {
        metrics.record_error(endpoint, method, status, owner, code, retryable);
    });
}

pub fn record_gateway_request_ttft(
    endpoint: &str,
    method: &str,
    status: i32,
    outcome: &str,
    error_owner: Option<&str>,
    error_code: Option<&str>,
    ttft_ms: i32,
) {
    with_gateway_metrics_mut(|metrics| {
        metrics.record_request_ttft(
            RequestTtftLabels {
                endpoint,
                method,
                status,
                outcome,
                error_owner,
                error_code,
            },
            ttft_ms,
        );
    });
}

pub fn record_gateway_fallback(endpoint: &str, method: &str, reason: &str) {
    with_gateway_metrics_mut(|metrics| {
        metrics.record_fallback(endpoint, method, reason);
    });
}

pub fn record_gateway_cost(endpoint: &str, method: &str, currency: &str, amount: &str) {
    with_gateway_metrics_mut(|metrics| {
        metrics.record_cost(endpoint, method, currency, amount);
    });
}

pub fn prometheus_metric_family(
    name: &str,
    metric_type: PrometheusMetricType,
    help: &str,
    labels: &[(&str, &str)],
    value: impl Display,
) -> String {
    let metric_name = prometheus_metric_name(name);
    let mut output = String::new();

    let _ = writeln!(
        output,
        "# HELP {metric_name} {}",
        escape_prometheus_help(help)
    );
    let _ = writeln!(output, "# TYPE {metric_name} {}", metric_type.as_str());
    output.push_str(&prometheus_sample(&metric_name, labels, value));

    output
}

pub fn prometheus_sample(name: &str, labels: &[(&str, &str)], value: impl Display) -> String {
    let mut output = String::new();

    output.push_str(&prometheus_metric_name(name));
    if !labels.is_empty() {
        output.push('{');
        for (index, (key, value)) in labels.iter().enumerate() {
            if index > 0 {
                output.push(',');
            }
            output.push_str(&prometheus_label_name(key));
            output.push_str("=\"");
            output.push_str(&escape_prometheus_label_value(value));
            output.push('"');
        }
        output.push('}');
    }

    let _ = writeln!(output, " {value}");
    output
}

pub fn escape_prometheus_label_value(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());

    for character in value.chars() {
        match character {
            '\\' => escaped.push_str("\\\\"),
            '"' => escaped.push_str("\\\""),
            '\n' => escaped.push_str("\\n"),
            _ => escaped.push(character),
        }
    }

    escaped
}

pub fn redact_header_value(name: &str, value: &str) -> String {
    if is_sensitive_header_name(name) {
        REDACTED_SECRET.to_string()
    } else {
        redact_secrets(value)
    }
}

pub fn redact_sensitive_value(name: &str, value: &str) -> String {
    if is_sensitive_key_name(name) {
        REDACTED_SECRET.to_string()
    } else {
        redact_secrets(value)
    }
}

pub fn redact_secrets(input: &str) -> String {
    let redacted_assignments = redact_sensitive_assignments(input);
    let redacted_tokens = redact_secret_tokens(&redacted_assignments);
    redact_email_addresses(&redacted_tokens)
}

pub fn redact_payload_value(value: &Value) -> Value {
    redact_json_value_with_key(None, value)
}

pub fn redact_payload_text(input: &str) -> String {
    match serde_json::from_str::<Value>(input) {
        Ok(value) => redact_payload_value(&value).to_string(),
        Err(_) => redact_secrets(input),
    }
}

pub fn is_sensitive_header_name(name: &str) -> bool {
    matches!(
        sensitive_value_kind(name),
        Some(SensitiveValueKind::Authorization | SensitiveValueKind::Cookie)
    ) || is_sensitive_key_name(name)
}

pub fn is_sensitive_key_name(name: &str) -> bool {
    sensitive_value_kind(name).is_some()
}

fn prometheus_metric_name(name: &str) -> String {
    sanitize_prometheus_identifier(name, true, "ai_gateway_metric")
}

fn prometheus_label_name(name: &str) -> String {
    sanitize_prometheus_identifier(name, false, "label")
}

fn sanitize_prometheus_identifier(raw: &str, allow_colon: bool, fallback: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return fallback.to_string();
    }

    let mut output = String::with_capacity(trimmed.len());
    for (index, character) in trimmed.chars().enumerate() {
        let valid_first = character.is_ascii_alphabetic()
            || character == '_'
            || (allow_colon && character == ':');
        let valid_rest = valid_first || character.is_ascii_digit();

        if (index == 0 && valid_first) || (index > 0 && valid_rest) {
            output.push(character);
        } else if index == 0 && character.is_ascii_digit() {
            output.push('_');
            output.push(character);
        } else {
            output.push('_');
        }
    }

    if output.chars().any(|character| character != '_') {
        output
    } else {
        fallback.to_string()
    }
}

fn escape_prometheus_help(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());

    for character in value.chars() {
        match character {
            '\\' => escaped.push_str("\\\\"),
            '\n' => escaped.push_str("\\n"),
            _ => escaped.push(character),
        }
    }

    escaped
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SensitiveValueKind {
    Authorization,
    Cookie,
    Generic,
}

fn sensitive_value_kind(name: &str) -> Option<SensitiveValueKind> {
    let normalized = normalize_sensitive_name(name);

    if normalized.is_empty() {
        return None;
    }

    if is_explicitly_non_sensitive_key_name(&normalized) {
        return None;
    }

    if normalized == "authorization" || normalized.ends_with("_authorization") {
        return Some(SensitiveValueKind::Authorization);
    }

    if normalized == "cookie"
        || normalized == "set_cookie"
        || normalized.ends_with("_cookie")
        || normalized.ends_with("_set_cookie")
    {
        return Some(SensitiveValueKind::Cookie);
    }

    if normalized == "key"
        || normalized == "token"
        || normalized.ends_with("_key")
        || normalized.ends_with("_token")
        || normalized.contains("api_key")
        || normalized.contains("apikey")
        || normalized.contains("secret")
        || normalized.contains("password")
        || normalized.contains("credential")
    {
        return Some(SensitiveValueKind::Generic);
    }

    None
}

fn is_explicitly_non_sensitive_key_name(normalized: &str) -> bool {
    matches!(
        normalized,
        "model_key" | "cache_key" | "public_key" | "public_key_id"
    ) || normalized.ends_with("_model_key")
        || normalized.ends_with("_cache_key")
        || normalized.ends_with("_public_key")
        || normalized.ends_with("_public_key_id")
}

fn normalize_sensitive_name(name: &str) -> String {
    name.trim_matches(|character: char| {
        character.is_whitespace() || matches!(character, '"' | '\'' | '`')
    })
    .chars()
    .map(|character| {
        if matches!(character, '-' | '.' | ' ') {
            '_'
        } else {
            character.to_ascii_lowercase()
        }
    })
    .collect()
}

fn redact_json_value_with_key(key: Option<&str>, value: &Value) -> Value {
    if key.is_some_and(is_sensitive_key_name) {
        return Value::String(REDACTED_SECRET.to_string());
    }

    match value {
        Value::Object(object) => Value::Object(redact_json_object(object)),
        Value::Array(values) => Value::Array(
            values
                .iter()
                .map(|value| redact_json_value_with_key(None, value))
                .collect(),
        ),
        Value::String(value) => Value::String(redact_secrets(value)),
        Value::Null | Value::Bool(_) | Value::Number(_) => value.clone(),
    }
}

fn redact_json_object(object: &Map<String, Value>) -> Map<String, Value> {
    object
        .iter()
        .map(|(key, value)| (key.clone(), redact_json_value_with_key(Some(key), value)))
        .collect()
}

fn redact_sensitive_assignments(input: &str) -> String {
    let mut output = String::with_capacity(input.len());
    let mut index = 0;

    while index < input.len() {
        if let Some(redaction) = sensitive_assignment_at(input, index) {
            output.push_str(&input[index..redaction.value_start]);
            output.push_str(REDACTED_SECRET);
            if let Some(quote) = redaction.closing_quote {
                output.push(quote);
            }
            index = redaction.next_index;
            continue;
        }

        let character = input[index..]
            .chars()
            .next()
            .expect("index is inside a non-empty string slice");
        output.push(character);
        index += character.len_utf8();
    }

    output
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct SensitiveAssignment {
    value_start: usize,
    next_index: usize,
    closing_quote: Option<char>,
}

fn sensitive_assignment_at(input: &str, index: usize) -> Option<SensitiveAssignment> {
    if !is_assignment_key_boundary(input, index) {
        return None;
    }

    let (key, after_key) = read_assignment_key(input, index)?;
    let kind = sensitive_value_kind(key)?;
    let separator = skip_ascii_whitespace(input, after_key);
    let separator_char = input[separator..].chars().next()?;

    if separator_char != ':' && separator_char != '=' {
        return None;
    }

    let value_start = skip_ascii_whitespace(input, separator + separator_char.len_utf8());
    read_assignment_value(input, value_start, kind)
}

fn is_assignment_key_boundary(input: &str, index: usize) -> bool {
    if index == 0 {
        return true;
    }

    input[..index]
        .chars()
        .next_back()
        .map(|character| {
            character.is_whitespace() || matches!(character, ',' | ';' | '{' | '[' | '(')
        })
        .unwrap_or(true)
}

fn read_assignment_key(input: &str, index: usize) -> Option<(&str, usize)> {
    let first = input[index..].chars().next()?;

    if first == '"' || first == '\'' {
        let key_start = index + first.len_utf8();
        let key_end = find_closing_quote(input, key_start, first)?;
        return Some((&input[key_start..key_end], key_end + first.len_utf8()));
    }

    let mut key_end = None;
    for (offset, character) in input[index..].char_indices() {
        if offset > 96 {
            return None;
        }

        if character == ':' || character == '=' {
            key_end = Some(index + offset);
            break;
        }

        if matches!(
            character,
            '\r' | '\n' | ',' | ';' | ')' | ']' | '}' | '"' | '\''
        ) {
            return None;
        }
    }

    let key_end = key_end?;
    let key = input[index..key_end].trim();
    if key.is_empty() {
        None
    } else {
        Some((key, key_end))
    }
}

fn read_assignment_value(
    input: &str,
    value_start: usize,
    kind: SensitiveValueKind,
) -> Option<SensitiveAssignment> {
    let first = input[value_start..].chars().next()?;

    if first == '"' || first == '\'' {
        let content_start = value_start + first.len_utf8();
        let closing_quote_index = find_closing_quote(input, content_start, first);
        return Some(SensitiveAssignment {
            value_start: content_start,
            next_index: closing_quote_index
                .map(|index| index + first.len_utf8())
                .unwrap_or(input.len()),
            closing_quote: closing_quote_index.map(|_| first),
        });
    }

    let value_end = unquoted_sensitive_value_end(input, value_start, kind);
    Some(SensitiveAssignment {
        value_start,
        next_index: value_end,
        closing_quote: None,
    })
}

fn unquoted_sensitive_value_end(
    input: &str,
    value_start: usize,
    kind: SensitiveValueKind,
) -> usize {
    match kind {
        SensitiveValueKind::Authorization => authorization_value_end(input, value_start),
        SensitiveValueKind::Cookie => lineish_value_end(input, value_start),
        SensitiveValueKind::Generic => token_value_end(input, value_start),
    }
}

fn authorization_value_end(input: &str, value_start: usize) -> usize {
    let rest = &input[value_start..];

    if let Some(after_scheme) = bearer_scheme_len(rest).or_else(|| basic_scheme_len(rest)) {
        let token_start = value_start + after_scheme;
        let token_end = token_value_end(input, token_start);
        return token_end;
    }

    token_value_end(input, value_start)
}

fn lineish_value_end(input: &str, value_start: usize) -> usize {
    input[value_start..]
        .char_indices()
        .find(|(_, character)| matches!(character, '\r' | '\n' | ',' | '}' | ']'))
        .map(|(offset, _)| value_start + offset)
        .unwrap_or(input.len())
}

fn token_value_end(input: &str, value_start: usize) -> usize {
    input[value_start..]
        .char_indices()
        .find(|(_, character)| {
            character.is_whitespace()
                || matches!(character, ',' | ';' | '&' | ')' | ']' | '}' | '"' | '\'')
        })
        .map(|(offset, _)| value_start + offset)
        .unwrap_or(input.len())
}

fn skip_ascii_whitespace(input: &str, mut index: usize) -> usize {
    while index < input.len() {
        let character = input[index..]
            .chars()
            .next()
            .expect("index is inside a non-empty string slice");
        if !character.is_ascii_whitespace() {
            break;
        }
        index += character.len_utf8();
    }

    index
}

fn find_closing_quote(input: &str, start: usize, quote: char) -> Option<usize> {
    let mut escaped = false;

    for (offset, character) in input[start..].char_indices() {
        if escaped {
            escaped = false;
            continue;
        }

        if character == '\\' {
            escaped = true;
            continue;
        }

        if character == quote {
            return Some(start + offset);
        }
    }

    None
}

fn redact_secret_tokens(input: &str) -> String {
    let mut output = String::with_capacity(input.len());
    let mut index = 0;

    while index < input.len() {
        let rest = &input[index..];

        if let Some(scheme_len) = bearer_scheme_len(rest).or_else(|| basic_scheme_len(rest)) {
            output.push_str(&rest[..scheme_len]);
            output.push_str(REDACTED_SECRET);
            index += scheme_len + secret_token_len(&rest[scheme_len..]);
            continue;
        }

        if SECRET_TOKEN_PREFIXES
            .iter()
            .any(|prefix| rest.starts_with(prefix))
        {
            output.push_str(REDACTED_SECRET);
            index += secret_token_len(rest);
            continue;
        }

        let character = rest
            .chars()
            .next()
            .expect("index is inside a non-empty string slice");
        output.push(character);
        index += character.len_utf8();
    }

    output
}

fn redact_email_addresses(input: &str) -> String {
    let mut output = String::with_capacity(input.len());
    let mut index = 0;

    while index < input.len() {
        if let Some(redaction_len) = email_address_len_at(input, index) {
            output.push_str(REDACTED_SECRET);
            index += redaction_len;
            continue;
        }

        let character = input[index..]
            .chars()
            .next()
            .expect("index is inside a non-empty string slice");
        output.push(character);
        index += character.len_utf8();
    }

    output
}

fn email_address_len_at(input: &str, index: usize) -> Option<usize> {
    if !is_email_boundary_before(input, index) {
        return None;
    }

    let rest = &input[index..];
    let at_offset = rest.find('@')?;
    if at_offset == 0 || at_offset > 128 {
        return None;
    }

    let local = &rest[..at_offset];
    if !local.chars().all(is_email_local_character) {
        return None;
    }

    let domain_start = at_offset + 1;
    let domain_len = rest[domain_start..]
        .char_indices()
        .find(|(_, character)| !is_email_domain_character(*character))
        .map(|(offset, _)| offset)
        .unwrap_or(rest.len() - domain_start);

    let mut domain_end = domain_start + domain_len;
    while domain_end > domain_start
        && rest.as_bytes()[domain_end - 1].is_ascii()
        && matches!(rest.as_bytes()[domain_end - 1], b'.' | b'-')
    {
        domain_end -= 1;
    }

    let domain = &rest[domain_start..domain_end];
    if !is_valid_email_domain(domain) {
        return None;
    }

    let candidate_len = domain_end;
    if is_email_boundary_after(input, index + candidate_len) {
        Some(candidate_len)
    } else {
        None
    }
}

fn is_email_boundary_before(input: &str, index: usize) -> bool {
    if index == 0 {
        return true;
    }

    input[..index]
        .chars()
        .next_back()
        .map(|character| !is_email_local_character(character))
        .unwrap_or(true)
}

fn is_email_boundary_after(input: &str, index: usize) -> bool {
    if index >= input.len() {
        return true;
    }

    input[index..]
        .chars()
        .next()
        .map(|character| !(character.is_ascii_alphanumeric() || character == '-'))
        .unwrap_or(true)
}

fn is_email_local_character(character: char) -> bool {
    character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '%' | '+' | '-')
}

fn is_email_domain_character(character: char) -> bool {
    character.is_ascii_alphanumeric() || matches!(character, '.' | '-')
}

fn is_valid_email_domain(domain: &str) -> bool {
    if domain.len() < 3 || !domain.contains('.') {
        return false;
    }

    let mut labels = domain.split('.');
    let Some(top_level_domain) = labels.next_back() else {
        return false;
    };

    top_level_domain.len() >= 2
        && top_level_domain
            .chars()
            .all(|character| character.is_ascii_alphabetic())
        && labels.all(|label| {
            !label.is_empty()
                && !label.starts_with('-')
                && !label.ends_with('-')
                && label
                    .chars()
                    .all(|character| character.is_ascii_alphanumeric() || character == '-')
        })
}

fn bearer_scheme_len(input: &str) -> Option<usize> {
    auth_scheme_len(input, "Bearer")
}

fn basic_scheme_len(input: &str) -> Option<usize> {
    auth_scheme_len(input, "Basic")
}

fn auth_scheme_len(input: &str, scheme: &str) -> Option<usize> {
    if !input
        .get(..scheme.len())
        .is_some_and(|candidate| candidate.eq_ignore_ascii_case(scheme))
    {
        return None;
    }

    let mut index = scheme.len();
    let mut saw_whitespace = false;

    while index < input.len() {
        let character = input[index..]
            .chars()
            .next()
            .expect("index is inside a non-empty string slice");
        if !character.is_ascii_whitespace() {
            break;
        }

        saw_whitespace = true;
        index += character.len_utf8();
    }

    if saw_whitespace { Some(index) } else { None }
}

fn secret_token_len(rest: &str) -> usize {
    rest.char_indices()
        .find(|(_, character)| is_secret_delimiter(*character))
        .map(|(index, _)| index)
        .unwrap_or(rest.len())
}

fn is_secret_delimiter(character: char) -> bool {
    character.is_whitespace()
        || matches!(
            character,
            '"' | '\'' | ',' | ';' | ':' | '(' | ')' | '[' | ']' | '{' | '}'
        )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn metrics_body_escapes_service_label_value() {
        let body = metrics_body("gateway\"\\\ninjected_metric 1");

        assert_eq!(body.lines().count(), 3);
        assert!(body.contains("# HELP ai_gateway_service_up Service availability flag"));
        assert!(body.contains("# TYPE ai_gateway_service_up gauge"));
        assert!(body.contains("service=\"gateway\\\"\\\\\\ninjected_metric 1\""));
    }

    #[test]
    fn prometheus_sample_sanitizes_names_and_formats_labels() {
        let sample = prometheus_sample(
            "1 bad metric",
            &[("service.name", "gateway"), ("tenant", "a\"b")],
            42,
        );

        assert_eq!(
            sample,
            "_1_bad_metric{service_name=\"gateway\",tenant=\"a\\\"b\"} 42\n"
        );
    }

    #[test]
    fn gateway_metrics_registry_renders_runtime_metric_families() {
        let mut metrics = GatewayMetricsRegistry::default();
        metrics.record_request("chat_completions", "POST", 200, "succeeded", 37);
        metrics.record_request_ttft(
            RequestTtftLabels {
                endpoint: "chat_completions",
                method: "POST",
                status: 200,
                outcome: "succeeded",
                error_owner: None,
                error_code: None,
            },
            12,
        );
        metrics.record_error(
            "chat_completions",
            "POST",
            502,
            "network",
            "provider_timeout",
            Some(true),
        );
        metrics.record_fallback("chat_completions", "POST", "provider_timeout");
        metrics.record_cost("chat_completions", "POST", "usd", "2.10000000");

        let body = metrics.render("gateway");

        assert!(body.contains("# TYPE ai_gateway_requests_total counter"));
        assert!(body.contains("ai_gateway_requests_total{service=\"gateway\",endpoint=\"chat_completions\",method=\"POST\",status=\"200\",status_class=\"2xx\",outcome=\"succeeded\"} 1"));
        assert!(body.contains("ai_gateway_errors_total{service=\"gateway\",endpoint=\"chat_completions\",method=\"POST\",status=\"502\",status_class=\"5xx\",owner=\"network\",code=\"provider_timeout\",retryable=\"true\"} 1"));
        assert!(body.contains("# TYPE ai_gateway_request_latency_ms histogram"));
        assert!(body.contains("ai_gateway_request_latency_ms_sum{service=\"gateway\",endpoint=\"chat_completions\",method=\"POST\",status_class=\"2xx\",outcome=\"succeeded\"} 37"));
        assert!(body.contains("ai_gateway_request_latency_ms_count{service=\"gateway\",endpoint=\"chat_completions\",method=\"POST\",status_class=\"2xx\",outcome=\"succeeded\"} 1"));
        assert!(body.contains("# TYPE ai_gateway_request_ttft_ms histogram"));
        assert!(body.contains("ai_gateway_request_ttft_ms_sum{service=\"gateway\",endpoint=\"chat_completions\",method=\"POST\",status=\"200\",status_class=\"2xx\",outcome=\"succeeded\",error_owner=\"none\",error_code=\"none\"} 12"));
        assert!(body.contains("ai_gateway_request_ttft_ms_count{service=\"gateway\",endpoint=\"chat_completions\",method=\"POST\",status=\"200\",status_class=\"2xx\",outcome=\"succeeded\",error_owner=\"none\",error_code=\"none\"} 1"));
        assert!(body.contains("ai_gateway_fallbacks_total{service=\"gateway\",endpoint=\"chat_completions\",method=\"POST\",reason=\"provider_timeout\"} 1"));
        assert!(body.contains("ai_gateway_request_cost_total{service=\"gateway\",endpoint=\"chat_completions\",method=\"POST\",currency=\"USD\"} 2.1"));
        assert!(!body.contains("request_id"));
        assert!(!body.contains("model="));
    }

    #[test]
    fn gateway_ttft_metrics_body_includes_histogram() {
        let mut metrics = GatewayMetricsRegistry::default();
        metrics.record_request_ttft(
            RequestTtftLabels {
                endpoint: "chat_completions",
                method: "POST",
                status: 200,
                outcome: "succeeded",
                error_owner: None,
                error_code: None,
            },
            42,
        );

        let body = metrics_body_with_gateway_metrics("gateway", &metrics);

        assert!(body.contains("# TYPE ai_gateway_service_up gauge"));
        assert!(body.contains("# TYPE ai_gateway_request_ttft_ms histogram"));
        assert!(body.contains("ai_gateway_request_ttft_ms_bucket{service=\"gateway\",endpoint=\"chat_completions\",method=\"POST\",status=\"200\",status_class=\"2xx\",outcome=\"succeeded\",error_owner=\"none\",error_code=\"none\",le=\"50\"} 1"));
        assert!(body.contains("ai_gateway_request_ttft_ms_sum{service=\"gateway\",endpoint=\"chat_completions\",method=\"POST\",status=\"200\",status_class=\"2xx\",outcome=\"succeeded\",error_owner=\"none\",error_code=\"none\"} 42"));
        assert!(body.contains("ai_gateway_request_ttft_ms_count{service=\"gateway\",endpoint=\"chat_completions\",method=\"POST\",status=\"200\",status_class=\"2xx\",outcome=\"succeeded\",error_owner=\"none\",error_code=\"none\"} 1"));
    }

    #[test]
    fn gateway_metric_labels_drop_secret_like_or_unbounded_values() {
        let mut metrics = GatewayMetricsRegistry::default();
        metrics.record_error(
            "chat_completions",
            "POST",
            502,
            "provider",
            "sk-live-secret",
            Some(true),
        );
        metrics.record_fallback("chat_completions", "POST", "rate limit with spaces");

        let body = metrics.render("gateway");

        assert!(!body.contains("sk-live-secret"));
        assert!(!body.contains("rate limit with spaces"));
        assert!(body.contains("code=\"unknown\""));
        assert!(body.contains("reason=\"unknown\""));
    }

    #[test]
    fn gateway_ttft_metric_labels_drop_secret_like_or_unbounded_values() {
        let mut metrics = GatewayMetricsRegistry::default();
        metrics.record_request_ttft(
            RequestTtftLabels {
                endpoint: "chat_completions",
                method: "POST",
                status: 502,
                outcome: "partial",
                error_owner: Some("provider"),
                error_code: Some("sk-live-secret"),
            },
            9,
        );
        metrics.record_request_ttft(
            RequestTtftLabels {
                endpoint: "chat_completions",
                method: "POST",
                status: 502,
                outcome: "partial",
                error_owner: Some("provider key with spaces"),
                error_code: Some("stream_upstream_eof"),
            },
            11,
        );

        let body = metrics.render("gateway");

        assert!(!body.contains("sk-live-secret"));
        assert!(!body.contains("provider key with spaces"));
        assert!(body.contains("ai_gateway_request_ttft_ms_count{service=\"gateway\",endpoint=\"chat_completions\",method=\"POST\",status=\"502\",status_class=\"5xx\",outcome=\"partial\",error_owner=\"provider\",error_code=\"unknown\"} 1"));
        assert!(body.contains("ai_gateway_request_ttft_ms_count{service=\"gateway\",endpoint=\"chat_completions\",method=\"POST\",status=\"502\",status_class=\"5xx\",outcome=\"partial\",error_owner=\"unknown\",error_code=\"stream_upstream_eof\"} 1"));
    }

    #[test]
    fn sensitive_header_values_are_fully_redacted() {
        assert_eq!(
            redact_header_value("Authorization", "Bearer virtual-token"),
            REDACTED_SECRET
        );
        assert_eq!(
            redact_header_value("x-api-key", "provider-token"),
            REDACTED_SECRET
        );
        assert_eq!(
            redact_header_value("Cookie", "session=abc; csrftoken=def"),
            REDACTED_SECRET
        );
    }

    #[test]
    fn non_sensitive_header_values_still_redact_embedded_tokens() {
        let value = redact_header_value("x-request-note", "upstream Bearer provider-token");

        assert!(!value.contains("provider-token"));
        assert_eq!(value, format!("upstream Bearer {REDACTED_SECRET}"));
    }

    #[test]
    fn redact_secrets_masks_inline_authorization_api_key_and_cookie() {
        let input = concat!(
            "Authorization: Bearer virtual-token\n",
            "x-api-key=provider-token ",
            "cookie=\"session=abc; csrftoken=def\" ",
            "model=ok"
        );

        let redacted = redact_secrets(input);

        assert!(!redacted.contains("virtual-token"));
        assert!(!redacted.contains("provider-token"));
        assert!(!redacted.contains("session=abc"));
        assert!(!redacted.contains("csrftoken=def"));
        assert!(redacted.contains("model=ok"));
        assert!(redacted.contains(REDACTED_SECRET));
    }

    #[test]
    fn redact_secrets_masks_known_token_prefixes() {
        let redacted = redact_secrets("provider returned sk-test-value and dev_test_key_123456789");

        assert!(!redacted.contains("sk-test-value"));
        assert!(!redacted.contains("dev_test_key_123456789"));
        assert_eq!(
            redacted,
            format!("provider returned {REDACTED_SECRET} and {REDACTED_SECRET}")
        );
    }

    #[test]
    fn redact_secrets_masks_virtual_key_prefix() {
        let redacted = redact_secrets("virtual key vk_123456789abcdef is active");

        assert!(!redacted.contains("vk_123456789abcdef"));
        assert_eq!(redacted, format!("virtual key {REDACTED_SECRET} is active"));
    }

    #[test]
    fn redact_secrets_masks_email_addresses() {
        let redacted = redact_secrets("Contact Jane at jane.doe+ops@example.com.");

        assert!(!redacted.contains("jane.doe+ops@example.com"));
        assert_eq!(redacted, format!("Contact Jane at {REDACTED_SECRET}."));
    }

    #[test]
    fn redact_payload_value_recurses_through_json_objects_and_arrays() {
        let payload = json!({
            "messages": [
                {
                    "role": "user",
                    "content": "email alice@example.com with Bearer upstream-token"
                }
            ],
            "metadata": {
                "api_key": "provider-token",
                "authorization": "Bearer virtual-token",
                "cookie": "session=abc",
                "password": "p4ssw0rd",
                "nested": {
                    "client_secret": "secret-value"
                }
            }
        });

        let redacted = redact_payload_value(&payload);

        assert_eq!(redacted["metadata"]["api_key"], REDACTED_SECRET);
        assert_eq!(redacted["metadata"]["authorization"], REDACTED_SECRET);
        assert_eq!(redacted["metadata"]["cookie"], REDACTED_SECRET);
        assert_eq!(redacted["metadata"]["password"], REDACTED_SECRET);
        assert_eq!(
            redacted["metadata"]["nested"]["client_secret"],
            REDACTED_SECRET
        );
        assert_eq!(
            redacted["messages"][0]["content"],
            format!("email {REDACTED_SECRET} with Bearer {REDACTED_SECRET}")
        );
    }

    #[test]
    fn redact_payload_value_does_not_over_redact_known_non_secret_keys() {
        let payload = json!({
            "model_key": "openai:gpt-4.1-mini",
            "cache_key": "tenant-route-cache-entry",
            "public_key_id": "pk_live_public_identifier",
            "nested_model_key": "anthropic:claude",
            "token": "secret-token"
        });

        let redacted = redact_payload_value(&payload);

        assert_eq!(redacted["model_key"], "openai:gpt-4.1-mini");
        assert_eq!(redacted["cache_key"], "tenant-route-cache-entry");
        assert_eq!(redacted["public_key_id"], "pk_live_public_identifier");
        assert_eq!(redacted["nested_model_key"], "anthropic:claude");
        assert_eq!(redacted["token"], REDACTED_SECRET);
    }

    #[test]
    fn redact_payload_text_redacts_json_or_plain_text_payloads() {
        let redacted_json = redact_payload_text(
            r#"{"email":"bob@example.com","api_key":"provider-token","model":"gpt"}"#,
        );
        let parsed: Value = serde_json::from_str(&redacted_json).expect("redacted JSON");

        assert_eq!(parsed["email"], REDACTED_SECRET);
        assert_eq!(parsed["api_key"], REDACTED_SECRET);
        assert_eq!(parsed["model"], "gpt");

        let redacted_text =
            redact_payload_text("user=bob@example.com authorization=Bearer provider-token");

        assert!(!redacted_text.contains("bob@example.com"));
        assert!(!redacted_text.contains("provider-token"));
        assert_eq!(
            redacted_text,
            format!("user={REDACTED_SECRET} authorization={REDACTED_SECRET}")
        );
    }

    #[test]
    fn sensitive_name_detection_covers_required_variants() {
        assert!(is_sensitive_header_name("authorization"));
        assert!(is_sensitive_header_name("set-cookie"));
        assert!(is_sensitive_key_name("apiKey"));
        assert!(is_sensitive_key_name("provider_api_key"));
        assert!(is_sensitive_key_name("refresh-token"));
        assert!(is_sensitive_key_name("password"));
        assert!(is_sensitive_key_name("client_secret"));
        assert!(is_sensitive_key_name("cookie"));
        assert!(!is_sensitive_key_name("model"));
        assert!(!is_sensitive_key_name("model_key"));
        assert!(!is_sensitive_key_name("cache_key"));
        assert!(!is_sensitive_key_name("public_key_id"));
    }
}
