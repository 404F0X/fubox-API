use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
};
use uuid::Uuid;

const DEFAULT_WEBHOOK_TIMEOUT_SECONDS: u64 = 10;
const MAX_WEBHOOK_TIMEOUT_SECONDS: u64 = 60;
const DEFAULT_WEBHOOK_RETRY_MAX_ATTEMPTS: u16 = 3;
const MAX_WEBHOOK_RETRY_MAX_ATTEMPTS: u16 = 5;
const DEFAULT_WEBHOOK_RETRY_BACKOFF_SECONDS: u64 = 2;
const MAX_WEBHOOK_RETRY_BACKOFF_SECONDS: u64 = 60;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum AlertWebhookMode {
    DryRun,
    Execute,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum AlertWebhookInputSource {
    Env,
    InputJson { path: String },
}

#[derive(Debug, Clone, Deserialize)]
pub(crate) struct AlertWebhookInput {
    #[serde(default)]
    webhook: AlertWebhookConfigInput,
    #[serde(default)]
    signals: AlertSignalsInput,
}

#[derive(Debug, Clone, Default, Deserialize)]
struct AlertWebhookConfigInput {
    #[serde(default)]
    enabled: Option<bool>,
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    secret: Option<String>,
    #[serde(default)]
    secret_header: Option<String>,
    #[serde(default)]
    headers: Option<BTreeMap<String, String>>,
    #[serde(default)]
    timeout_seconds: Option<u64>,
    #[serde(default)]
    retry: Option<AlertWebhookRetryInput>,
    #[serde(default)]
    retry_max_attempts: Option<u16>,
    #[serde(default)]
    retry_backoff_seconds: Option<u64>,
    #[serde(default, alias = "body", alias = "raw_body")]
    payload: Option<Value>,
}

#[derive(Debug, Clone, Default, Deserialize)]
struct AlertWebhookRetryInput {
    #[serde(default)]
    max_attempts: Option<u16>,
    #[serde(default)]
    backoff_seconds: Option<u64>,
}

#[derive(Debug, Clone, Default, Deserialize)]
struct AlertSignalsInput {
    #[serde(default)]
    error_rate: Option<ErrorRateSignal>,
    #[serde(default)]
    provider_key_cooldowns: Vec<ProviderKeyCooldownSignal>,
    #[serde(default)]
    ledger_lag: Option<LedgerLagSignal>,
}

#[derive(Debug, Clone, Default, Deserialize)]
struct ErrorRateSignal {
    #[serde(default)]
    window_seconds: Option<u64>,
    #[serde(default)]
    request_count: u64,
    #[serde(default)]
    error_count: u64,
    #[serde(default)]
    threshold: Option<f64>,
    #[serde(default)]
    severity: Option<String>,
    #[serde(default)]
    route: Option<String>,
    #[serde(default, alias = "model_key")]
    model: Option<String>,
    #[serde(default)]
    observed_at: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
struct ProviderKeyCooldownSignal {
    #[serde(default)]
    provider_id: Option<Uuid>,
    #[serde(default)]
    provider_code: Option<String>,
    #[serde(default)]
    channel_id: Option<Uuid>,
    #[serde(default)]
    channel_name: Option<String>,
    #[serde(default)]
    provider_key_id: Option<Uuid>,
    #[serde(default)]
    key_alias: Option<String>,
    #[serde(default, alias = "provider_key_status")]
    status: Option<String>,
    #[serde(default)]
    cooldown_until: Option<String>,
    #[serde(default)]
    last_error_code: Option<String>,
    #[serde(default)]
    health_score: Option<f64>,
    #[serde(default)]
    severity: Option<String>,
    #[serde(default)]
    observed_at: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
struct LedgerLagSignal {
    #[serde(default)]
    pending_event_count: u64,
    #[serde(default)]
    oldest_unsettled_age_seconds: u64,
    #[serde(default)]
    threshold_seconds: Option<u64>,
    #[serde(default)]
    severity: Option<String>,
    #[serde(default)]
    queue: Option<String>,
    #[serde(default)]
    observed_at: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub(crate) struct AlertWebhookPlan {
    schema_version: &'static str,
    dry_run: bool,
    mode: &'static str,
    outbound_call: bool,
    tenant_id: Uuid,
    source: AlertWebhookSourceReport,
    webhook: AlertWebhookDestinationPlan,
    input_payload: PayloadSummary,
    contract: AlertWebhookContractReport,
    alert_count: usize,
    alerts: Vec<AlertWebhookAlert>,
    sender: AlertWebhookSenderContractReport,
    delivery: AlertWebhookDeliveryReport,
    ssrf_guard: AlertWebhookSsrfGuardReport,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct AlertWebhookSourceReport {
    kind: &'static str,
    input_path: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct AlertWebhookDestinationPlan {
    configured: bool,
    enabled: bool,
    url_redacted: Option<String>,
    scheme: Option<String>,
    host: Option<String>,
    port: Option<u16>,
    path_redacted: bool,
    query_redacted: bool,
    secret_configured: bool,
    secret_redacted: bool,
    secret_header: Option<String>,
    headers_redacted: BTreeMap<String, String>,
    header_count: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct PayloadSummary {
    provided: bool,
    kind: Option<&'static str>,
    top_level_item_count: usize,
    redacted: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct AlertWebhookContractReport {
    covered_alert_types: Vec<&'static str>,
    stable_fields: Vec<&'static str>,
    payload_body_redacted: bool,
    provider_key_secret_redacted: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct AlertWebhookAlert {
    alert_type: &'static str,
    severity: String,
    would_send: bool,
    webhook_method: &'static str,
    dedupe_key: String,
    title: &'static str,
    summary: String,
    labels: BTreeMap<String, String>,
    facts: BTreeMap<String, Value>,
    payload: AlertPayloadPlan,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct AlertPayloadPlan {
    content_type: &'static str,
    body_redacted: bool,
    planned_body_fields: Vec<&'static str>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct AlertWebhookDeliveryReport {
    implemented: bool,
    dry_run_only: bool,
    send_supported: bool,
    force_required_for_send: bool,
    request_body_redacted: bool,
    note: &'static str,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct AlertWebhookSsrfGuardReport {
    https_required: bool,
    userinfo_rejected: bool,
    localhost_rejected: bool,
    private_literal_ip_rejected: bool,
    link_local_literal_ip_rejected: bool,
    multicast_or_unspecified_ip_rejected: bool,
    dns_not_resolved: bool,
    dry_run_only: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct AlertWebhookSenderContractReport {
    implemented: bool,
    network_supported: bool,
    transaction_schema_version: &'static str,
    attempt_schema_version: &'static str,
    preflight: AlertWebhookSenderPreflightReport,
    transaction: AlertWebhookSenderTransactionReport,
    timeout: AlertWebhookTimeoutReport,
    retry: AlertWebhookRetryReport,
    attempts: Vec<AlertWebhookSenderAttemptPlan>,
    no_payload_secret_echo: bool,
    no_header_value_echo: bool,
    no_error_secret_echo: bool,
    force_cannot_enable_network: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct AlertWebhookSenderPreflightReport {
    schema_version: &'static str,
    ready: bool,
    would_send: bool,
    network_call_allowed: bool,
    send_refused_in_this_slice: bool,
    validation_order: Vec<&'static str>,
    ssrf_guard: AlertWebhookSenderSsrfPreflightReport,
    headers: AlertWebhookHeaderPreflightReport,
    body: AlertWebhookBodyPreflightReport,
    transaction: AlertWebhookWouldSendTransactionReport,
    error_sanitization: AlertWebhookErrorSanitizationReport,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct AlertWebhookSenderSsrfPreflightReport {
    url_validated: bool,
    https_required: bool,
    userinfo_rejected: bool,
    literal_ip_checked: bool,
    suspicious_internal_dns_rejected: bool,
    dns_resolution_required_before_live_send: bool,
    dns_resolution_contract: AlertWebhookDnsResolutionContractReport,
    validation_happens_before_sender: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct AlertWebhookDnsResolutionContractReport {
    resolver_receives_host_only: bool,
    raw_url_path_query_available_to_resolver: bool,
    reject_if_any_resolved_ip_forbidden: bool,
    resolved_ips_serialized: bool,
    resolution_errors_redacted: bool,
    force_cannot_bypass_dns_recheck: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct AlertWebhookHeaderPreflightReport {
    custom_header_count: usize,
    managed_header_count: usize,
    headers_redacted: BTreeMap<String, String>,
    managed_headers_redacted: BTreeMap<String, String>,
    secret_header_redacted: bool,
    header_values_available_to_sender_contract: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct AlertWebhookBodyPreflightReport {
    content_type: &'static str,
    redaction_policy: &'static str,
    input_payload_provided: bool,
    input_payload_kind: Option<&'static str>,
    input_payload_top_level_item_count: usize,
    body_redacted: bool,
    raw_body_available_to_sender_contract: bool,
    planned_body_fields: Vec<&'static str>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct AlertWebhookWouldSendTransactionReport {
    schema_version: &'static str,
    method: &'static str,
    url_redacted: Option<String>,
    headers_redacted: BTreeMap<String, String>,
    alert_count: usize,
    timeout_seconds: u64,
    max_attempts: u16,
    retry_backoff_seconds: u64,
    body_redacted: bool,
    body_fields: Vec<&'static str>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct AlertWebhookErrorSanitizationReport {
    validation_errors_redacted: bool,
    sender_errors_redacted: bool,
    response_body_redacted: bool,
    raw_error_material_in_report: bool,
    sanitizer: &'static str,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct AlertWebhookSenderTransactionReport {
    method: &'static str,
    configured: bool,
    enabled: bool,
    alert_count: usize,
    url_redacted: Option<String>,
    headers_redacted: BTreeMap<String, String>,
    header_count: usize,
    secret_header: Option<String>,
    secret_redacted: bool,
    body_redacted: bool,
    body_fields: Vec<&'static str>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct AlertWebhookTimeoutReport {
    request_timeout_seconds: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct AlertWebhookRetryReport {
    max_attempts: u16,
    backoff_seconds: u64,
    retry_on: Vec<&'static str>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct AlertWebhookSenderAttemptPlan {
    attempt: u16,
    timeout_seconds: u64,
    backoff_before_seconds: u64,
    request_body_redacted: bool,
    response_body_redacted: bool,
    error_redacted: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ValidatedWebhookUrl {
    scheme: String,
    host: String,
    port: Option<u16>,
    redacted_url: String,
    path_redacted: bool,
    query_redacted: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct AlertWebhookSendPolicy {
    timeout_seconds: u64,
    max_attempts: u16,
    retry_backoff_seconds: u64,
}

#[allow(dead_code)]
pub(crate) trait AlertWebhookSender {
    fn network_access(&self) -> AlertWebhookSenderNetworkAccess;

    fn send(
        &self,
        transaction: &AlertWebhookSenderTransaction,
        attempt: u16,
    ) -> AlertWebhookSenderAttemptOutcome;
}

#[allow(dead_code)]
pub(crate) trait AlertWebhookDnsResolver {
    fn resolve_host(&self, host: &str) -> Result<Vec<IpAddr>, String>;
}

#[allow(dead_code)]
#[derive(Debug, Clone, Copy)]
struct ContractOnlyPublicDnsResolver;

impl AlertWebhookDnsResolver for ContractOnlyPublicDnsResolver {
    fn resolve_host(&self, host: &str) -> Result<Vec<IpAddr>, String> {
        if host.parse::<IpAddr>().is_ok() {
            return Ok(Vec::new());
        }

        Ok(vec![IpAddr::V4(Ipv4Addr::new(203, 0, 113, 10))])
    }
}

#[allow(dead_code)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum AlertWebhookSenderNetworkAccess {
    Disabled,
    Enabled,
}

#[allow(dead_code)]
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct AlertWebhookSenderTransaction {
    schema_version: &'static str,
    method: &'static str,
    url_redacted: String,
    headers_redacted: BTreeMap<String, String>,
    alert_count: usize,
    timeout_seconds: u64,
    max_attempts: u16,
    retry_backoff_seconds: u64,
    body_redacted: bool,
    body_fields: Vec<&'static str>,
    network_call_allowed: bool,
    send_refused_in_this_slice: bool,
}

#[allow(dead_code)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum AlertWebhookSenderAttemptStatus {
    Success,
    RetryableFailure,
    PermanentFailure,
}

#[allow(dead_code)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct AlertWebhookSenderAttemptOutcome {
    status: AlertWebhookSenderAttemptStatus,
    http_status: Option<u16>,
    error: Option<String>,
}

#[allow(dead_code)]
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct AlertWebhookSenderExecutionReport {
    transaction_schema_version: &'static str,
    attempted: bool,
    sent: bool,
    network_call_allowed: bool,
    sender_network_access: &'static str,
    preflight_passed: bool,
    dns_preflight_passed: bool,
    dns_resolved_ip_count: usize,
    dns_resolved_ips_redacted: bool,
    alert_count: usize,
    attempt_count: usize,
    attempts: Vec<AlertWebhookSenderAttemptExecutionReport>,
    request_body_redacted: bool,
    response_body_redacted: bool,
    no_payload_secret_echo: bool,
    no_header_value_echo: bool,
    no_error_secret_echo: bool,
    error_sanitization: AlertWebhookErrorSanitizationReport,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct AlertWebhookSenderAttemptExecutionReport {
    attempt: u16,
    status: &'static str,
    http_status: Option<u16>,
    error_redacted: Option<String>,
    will_retry: bool,
}

#[allow(dead_code)]
impl AlertWebhookSenderAttemptOutcome {
    pub(crate) fn success(http_status: u16) -> Self {
        Self {
            status: AlertWebhookSenderAttemptStatus::Success,
            http_status: Some(http_status),
            error: None,
        }
    }

    pub(crate) fn retryable_failure(http_status: Option<u16>, error: impl Into<String>) -> Self {
        Self {
            status: AlertWebhookSenderAttemptStatus::RetryableFailure,
            http_status,
            error: Some(error.into()),
        }
    }

    pub(crate) fn permanent_failure(http_status: Option<u16>, error: impl Into<String>) -> Self {
        Self {
            status: AlertWebhookSenderAttemptStatus::PermanentFailure,
            http_status,
            error: Some(error.into()),
        }
    }

    fn is_success(&self) -> bool {
        matches!(self.status, AlertWebhookSenderAttemptStatus::Success)
    }

    fn is_retryable_failure(&self) -> bool {
        matches!(
            self.status,
            AlertWebhookSenderAttemptStatus::RetryableFailure
        )
    }
}

impl AlertWebhookSenderAttemptStatus {
    fn as_report_str(&self) -> &'static str {
        match self {
            Self::Success => "success",
            Self::RetryableFailure => "retryable_failure",
            Self::PermanentFailure => "permanent_failure",
        }
    }
}

impl AlertWebhookSenderNetworkAccess {
    fn as_report_str(&self) -> &'static str {
        match self {
            Self::Disabled => "disabled",
            Self::Enabled => "enabled",
        }
    }

    fn is_enabled(&self) -> bool {
        matches!(self, Self::Enabled)
    }
}

pub(crate) fn read_alert_webhook_input(
    input_path: Option<&str>,
) -> Result<(AlertWebhookInputSource, AlertWebhookInput), String> {
    if let Some(path) = input_path {
        let body = fs::read_to_string(path).map_err(|error| {
            format!(
                "failed to read alert webhook input `{}`: {}",
                super::safe_plan_text(path),
                super::safe_error_text(&error.to_string())
            )
        })?;
        let input = alert_webhook_input_from_json_str(&body)?;
        return Ok((
            AlertWebhookInputSource::InputJson {
                path: path.to_string(),
            },
            input,
        ));
    }

    let input = alert_webhook_input_from_env_vars(std::env::vars())?;
    Ok((AlertWebhookInputSource::Env, input))
}

pub(crate) fn alert_webhook_input_from_json_str(body: &str) -> Result<AlertWebhookInput, String> {
    let value = serde_json::from_str::<Value>(body).map_err(|error| {
        format!(
            "alert webhook input must be valid JSON: {}",
            super::safe_error_text(&error.to_string())
        )
    })?;
    let input = value.get("input").cloned().unwrap_or(value);
    serde_json::from_value::<AlertWebhookInput>(input).map_err(|error| {
        format!(
            "alert webhook input shape is invalid: {}",
            super::safe_error_text(&error.to_string())
        )
    })
}

pub(crate) fn alert_webhook_input_from_env_vars(
    vars: impl IntoIterator<Item = (String, String)>,
) -> Result<AlertWebhookInput, String> {
    let vars = vars.into_iter().collect::<BTreeMap<_, _>>();
    let url = non_empty_env(&vars, "AI_GATEWAY_ALERT_WEBHOOK_URL");
    let enabled = match non_empty_env(&vars, "AI_GATEWAY_ALERT_WEBHOOK_ENABLED") {
        Some(value) => Some(parse_env_bool("AI_GATEWAY_ALERT_WEBHOOK_ENABLED", &value)?),
        None => url.as_ref().map(|_| true),
    };
    let headers = match non_empty_env(&vars, "AI_GATEWAY_ALERT_WEBHOOK_HEADERS_JSON") {
        Some(value) => Some(serde_json::from_str::<BTreeMap<String, String>>(&value).map_err(
            |error| {
                format!(
                    "AI_GATEWAY_ALERT_WEBHOOK_HEADERS_JSON must be a JSON object of string headers: {}",
                    super::safe_error_text(&error.to_string())
                )
            },
        )?),
        None => None,
    };
    let retry_max_attempts =
        parse_optional_env_u16(&vars, "AI_GATEWAY_ALERT_WEBHOOK_RETRY_MAX_ATTEMPTS")?;
    let retry_backoff_seconds =
        parse_optional_env_u64(&vars, "AI_GATEWAY_ALERT_WEBHOOK_RETRY_BACKOFF_SECONDS")?;
    let retry = (retry_max_attempts.is_some() || retry_backoff_seconds.is_some()).then_some(
        AlertWebhookRetryInput {
            max_attempts: retry_max_attempts,
            backoff_seconds: retry_backoff_seconds,
        },
    );

    Ok(AlertWebhookInput {
        webhook: AlertWebhookConfigInput {
            enabled,
            url,
            secret: non_empty_env(&vars, "AI_GATEWAY_ALERT_WEBHOOK_SECRET"),
            secret_header: non_empty_env(&vars, "AI_GATEWAY_ALERT_WEBHOOK_SECRET_HEADER"),
            headers,
            timeout_seconds: parse_optional_env_u64(
                &vars,
                "AI_GATEWAY_ALERT_WEBHOOK_TIMEOUT_SECONDS",
            )?,
            retry,
            retry_max_attempts: None,
            retry_backoff_seconds: None,
            payload: None,
        },
        signals: AlertSignalsInput::default(),
    })
}

pub(crate) fn alert_webhook_plan(
    tenant_id: Uuid,
    source: AlertWebhookInputSource,
    input: AlertWebhookInput,
) -> Result<AlertWebhookPlan, String> {
    let webhook = webhook_destination_plan(&input.webhook)?;
    let send_policy = sender_policy_plan(&input.webhook)?;
    let input_payload = payload_summary(input.webhook.payload.as_ref());
    let would_send = webhook.configured && webhook.enabled;
    let mut alerts = Vec::new();

    if let Some(signal) = &input.signals.error_rate
        && let Some(alert) = error_rate_alert(signal, would_send)
    {
        alerts.push(alert);
    }

    for (index, signal) in input.signals.provider_key_cooldowns.iter().enumerate() {
        if let Some(alert) = provider_key_cooldown_alert(signal, index, would_send) {
            alerts.push(alert);
        }
    }

    if let Some(signal) = &input.signals.ledger_lag
        && let Some(alert) = ledger_lag_alert(signal, would_send)
    {
        alerts.push(alert);
    }
    let sender = sender_contract_report(&webhook, &send_policy, alerts.len(), &input_payload);

    Ok(AlertWebhookPlan {
        schema_version: "alert_webhook_plan.v1",
        dry_run: true,
        mode: "plan_only",
        outbound_call: false,
        tenant_id,
        source: source_report(source),
        webhook,
        input_payload,
        contract: AlertWebhookContractReport {
            covered_alert_types: vec!["error_rate", "provider_key_cooldown", "ledger_lag"],
            stable_fields: vec![
                "schema_version",
                "dry_run",
                "outbound_call",
                "tenant_id",
                "webhook",
                "alert_count",
                "alerts",
                "sender",
                "delivery",
                "ssrf_guard",
            ],
            payload_body_redacted: true,
            provider_key_secret_redacted: true,
        },
        alert_count: alerts.len(),
        sender,
        alerts,
        delivery: AlertWebhookDeliveryReport {
            implemented: false,
            dry_run_only: true,
            send_supported: false,
            force_required_for_send: true,
            request_body_redacted: true,
            note: "plan only; no webhook request was sent",
        },
        ssrf_guard: AlertWebhookSsrfGuardReport {
            https_required: true,
            userinfo_rejected: true,
            localhost_rejected: true,
            private_literal_ip_rejected: true,
            link_local_literal_ip_rejected: true,
            multicast_or_unspecified_ip_rejected: true,
            dns_not_resolved: true,
            dry_run_only: true,
        },
    })
}

#[allow(dead_code)]
pub(crate) fn execute_alert_webhook_sender_contract<S: AlertWebhookSender>(
    force: bool,
    tenant_id: Uuid,
    source: AlertWebhookInputSource,
    input: AlertWebhookInput,
    sender: &S,
) -> Result<AlertWebhookSenderExecutionReport, String> {
    execute_alert_webhook_sender_contract_with_resolver(
        force,
        tenant_id,
        source,
        input,
        sender,
        &ContractOnlyPublicDnsResolver,
    )
}

#[allow(dead_code)]
pub(crate) fn execute_alert_webhook_sender_contract_with_resolver<
    S: AlertWebhookSender,
    R: AlertWebhookDnsResolver,
>(
    force: bool,
    tenant_id: Uuid,
    source: AlertWebhookInputSource,
    input: AlertWebhookInput,
    sender: &S,
    resolver: &R,
) -> Result<AlertWebhookSenderExecutionReport, String> {
    if !force {
        return Err(
            "alert webhook sender contract requires --force before any sender attempt".to_string(),
        );
    }

    let plan = alert_webhook_plan(tenant_id, source, input)?;
    let dns_resolved_ip_count = dns_ssrf_recheck_before_send(&plan, resolver)?;
    let sender_network_access = sender.network_access();
    if sender_network_access.is_enabled() {
        return Err(
            "alert webhook sender contract refuses network-capable sender in this dry-run slice; no webhook request was sent"
                .to_string(),
        );
    }
    let transaction = sender_transaction_from_plan(&plan)?;
    let mut attempts = Vec::new();
    let mut sent = false;

    for attempt in 1..=transaction.max_attempts {
        let outcome = sender.send(&transaction, attempt);
        let will_retry = outcome.is_retryable_failure() && attempt < transaction.max_attempts;
        if outcome.is_success() {
            sent = true;
        }
        attempts.push(AlertWebhookSenderAttemptExecutionReport {
            attempt,
            status: outcome.status.as_report_str(),
            http_status: outcome.http_status,
            error_redacted: outcome.error.as_deref().map(super::safe_plan_text),
            will_retry,
        });
        if sent || !will_retry {
            break;
        }
    }

    Ok(AlertWebhookSenderExecutionReport {
        transaction_schema_version: transaction.schema_version,
        attempted: !attempts.is_empty(),
        sent,
        network_call_allowed: transaction.network_call_allowed,
        sender_network_access: sender_network_access.as_report_str(),
        preflight_passed: true,
        dns_preflight_passed: true,
        dns_resolved_ip_count,
        dns_resolved_ips_redacted: true,
        alert_count: transaction.alert_count,
        attempt_count: attempts.len(),
        attempts,
        request_body_redacted: transaction.body_redacted,
        response_body_redacted: true,
        no_payload_secret_echo: true,
        no_header_value_echo: true,
        no_error_secret_echo: true,
        error_sanitization: error_sanitization_report(),
    })
}

fn sender_transaction_from_plan(
    plan: &AlertWebhookPlan,
) -> Result<AlertWebhookSenderTransaction, String> {
    let url_redacted = plan
        .webhook
        .url_redacted
        .clone()
        .ok_or_else(|| "alert webhook sender requires a configured webhook url".to_string())?;
    if !plan.webhook.enabled {
        return Err("alert webhook sender requires an enabled webhook".to_string());
    }
    if plan.alert_count == 0 {
        return Err("alert webhook sender requires at least one alert".to_string());
    }

    Ok(AlertWebhookSenderTransaction {
        schema_version: plan.sender.transaction_schema_version,
        method: "POST",
        url_redacted,
        headers_redacted: sender_headers_redacted(&plan.webhook),
        alert_count: plan.alert_count,
        timeout_seconds: plan.sender.timeout.request_timeout_seconds,
        max_attempts: plan.sender.retry.max_attempts,
        retry_backoff_seconds: plan.sender.retry.backoff_seconds,
        body_redacted: true,
        body_fields: sender_body_fields(),
        network_call_allowed: false,
        send_refused_in_this_slice: true,
    })
}

fn dns_ssrf_recheck_before_send<R: AlertWebhookDnsResolver>(
    plan: &AlertWebhookPlan,
    resolver: &R,
) -> Result<usize, String> {
    let host = plan.webhook.host.as_deref().ok_or_else(|| {
        "alert webhook DNS preflight requires a configured webhook host".to_string()
    })?;
    if host.parse::<IpAddr>().is_ok() {
        return Ok(1);
    }

    let resolved_ips = resolver.resolve_host(host).map_err(|error| {
        format!(
            "alert webhook DNS preflight failed for host `{}`: {}",
            super::safe_plan_text(host),
            super::safe_error_text(&error)
        )
    })?;
    if resolved_ips.is_empty() {
        return Err(
            "alert webhook DNS preflight must resolve at least one IP for configured host"
                .to_string(),
        );
    }
    if resolved_ips.iter().copied().any(is_forbidden_webhook_ip) {
        return Err(
            "alert webhook DNS preflight rejected host because at least one resolved IP is localhost, private, link-local, multicast, or unspecified"
                .to_string(),
        );
    }

    Ok(resolved_ips.len())
}

fn source_report(source: AlertWebhookInputSource) -> AlertWebhookSourceReport {
    match source {
        AlertWebhookInputSource::Env => AlertWebhookSourceReport {
            kind: "env",
            input_path: None,
        },
        AlertWebhookInputSource::InputJson { path } => AlertWebhookSourceReport {
            kind: "input_json",
            input_path: Some(super::safe_plan_text(&path)),
        },
    }
}

fn webhook_destination_plan(
    input: &AlertWebhookConfigInput,
) -> Result<AlertWebhookDestinationPlan, String> {
    let url = match input
        .url
        .as_deref()
        .map(str::trim)
        .filter(|url| !url.is_empty())
    {
        Some(raw_url) => Some(validate_webhook_url(raw_url)?),
        None => None,
    };
    let secret_configured = validate_optional_secret(input.secret.as_deref())?;
    let secret_header = validate_secret_header(input.secret_header.as_deref())?;
    let headers_redacted = validate_headers(input.headers.as_ref())?;
    validate_secret_header_not_duplicated(secret_header.as_deref(), input.headers.as_ref())?;
    let header_count = headers_redacted.len();

    Ok(AlertWebhookDestinationPlan {
        configured: url.is_some(),
        enabled: input.enabled.unwrap_or(false),
        url_redacted: url.as_ref().map(|url| url.redacted_url.clone()),
        scheme: url.as_ref().map(|url| url.scheme.clone()),
        host: url.as_ref().map(|url| url.host.clone()),
        port: url.as_ref().and_then(|url| url.port),
        path_redacted: url.as_ref().is_some_and(|url| url.path_redacted),
        query_redacted: url.as_ref().is_some_and(|url| url.query_redacted),
        secret_configured,
        secret_redacted: secret_configured,
        secret_header,
        headers_redacted,
        header_count,
    })
}

fn sender_policy_plan(input: &AlertWebhookConfigInput) -> Result<AlertWebhookSendPolicy, String> {
    let timeout_seconds = input
        .timeout_seconds
        .unwrap_or(DEFAULT_WEBHOOK_TIMEOUT_SECONDS);
    if timeout_seconds == 0 || timeout_seconds > MAX_WEBHOOK_TIMEOUT_SECONDS {
        return Err(format!(
            "webhook timeout_seconds must be between 1 and {MAX_WEBHOOK_TIMEOUT_SECONDS}"
        ));
    }

    let retry_max_attempts = input
        .retry_max_attempts
        .or_else(|| input.retry.as_ref().and_then(|retry| retry.max_attempts))
        .unwrap_or(DEFAULT_WEBHOOK_RETRY_MAX_ATTEMPTS);
    if retry_max_attempts == 0 || retry_max_attempts > MAX_WEBHOOK_RETRY_MAX_ATTEMPTS {
        return Err(format!(
            "webhook retry max_attempts must be between 1 and {MAX_WEBHOOK_RETRY_MAX_ATTEMPTS}"
        ));
    }

    let retry_backoff_seconds = input
        .retry_backoff_seconds
        .or_else(|| input.retry.as_ref().and_then(|retry| retry.backoff_seconds))
        .unwrap_or(DEFAULT_WEBHOOK_RETRY_BACKOFF_SECONDS);
    if retry_backoff_seconds > MAX_WEBHOOK_RETRY_BACKOFF_SECONDS {
        return Err(format!(
            "webhook retry backoff_seconds must be {MAX_WEBHOOK_RETRY_BACKOFF_SECONDS} or fewer"
        ));
    }

    Ok(AlertWebhookSendPolicy {
        timeout_seconds,
        max_attempts: retry_max_attempts,
        retry_backoff_seconds,
    })
}

fn sender_contract_report(
    webhook: &AlertWebhookDestinationPlan,
    policy: &AlertWebhookSendPolicy,
    alert_count: usize,
    input_payload: &PayloadSummary,
) -> AlertWebhookSenderContractReport {
    let preflight = sender_preflight_report(webhook, policy, alert_count, input_payload);
    let transaction_headers = sender_headers_redacted(webhook);
    let transaction_header_count = transaction_headers.len();

    AlertWebhookSenderContractReport {
        implemented: false,
        network_supported: false,
        transaction_schema_version: "alert_webhook_sender_transaction.v1",
        attempt_schema_version: "alert_webhook_sender_attempt.v1",
        preflight,
        transaction: AlertWebhookSenderTransactionReport {
            method: "POST",
            configured: webhook.configured,
            enabled: webhook.enabled,
            alert_count,
            url_redacted: webhook.url_redacted.clone(),
            headers_redacted: transaction_headers,
            header_count: transaction_header_count,
            secret_header: webhook.secret_header.clone(),
            secret_redacted: webhook.secret_redacted,
            body_redacted: true,
            body_fields: sender_body_fields(),
        },
        timeout: AlertWebhookTimeoutReport {
            request_timeout_seconds: policy.timeout_seconds,
        },
        retry: AlertWebhookRetryReport {
            max_attempts: policy.max_attempts,
            backoff_seconds: policy.retry_backoff_seconds,
            retry_on: vec!["transport_error", "timeout", "http_429", "http_5xx"],
        },
        attempts: (1..=policy.max_attempts)
            .map(|attempt| AlertWebhookSenderAttemptPlan {
                attempt,
                timeout_seconds: policy.timeout_seconds,
                backoff_before_seconds: if attempt == 1 {
                    0
                } else {
                    policy.retry_backoff_seconds
                },
                request_body_redacted: true,
                response_body_redacted: true,
                error_redacted: true,
            })
            .collect(),
        no_payload_secret_echo: true,
        no_header_value_echo: true,
        no_error_secret_echo: true,
        force_cannot_enable_network: true,
    }
}

fn sender_preflight_report(
    webhook: &AlertWebhookDestinationPlan,
    policy: &AlertWebhookSendPolicy,
    alert_count: usize,
    input_payload: &PayloadSummary,
) -> AlertWebhookSenderPreflightReport {
    let would_send = webhook.configured && webhook.enabled && alert_count > 0;
    AlertWebhookSenderPreflightReport {
        schema_version: "alert_webhook_sender_preflight.v1",
        ready: would_send,
        would_send,
        network_call_allowed: false,
        send_refused_in_this_slice: true,
        validation_order: vec![
            "url_ssrf_guard",
            "dns_resolution_ssrf_recheck",
            "header_redaction",
            "payload_body_redaction",
            "timeout_retry_bounds",
            "error_sanitization",
            "network_disabled_gate",
        ],
        ssrf_guard: AlertWebhookSenderSsrfPreflightReport {
            url_validated: webhook.configured,
            https_required: true,
            userinfo_rejected: true,
            literal_ip_checked: true,
            suspicious_internal_dns_rejected: true,
            dns_resolution_required_before_live_send: true,
            dns_resolution_contract: AlertWebhookDnsResolutionContractReport {
                resolver_receives_host_only: true,
                raw_url_path_query_available_to_resolver: false,
                reject_if_any_resolved_ip_forbidden: true,
                resolved_ips_serialized: false,
                resolution_errors_redacted: true,
                force_cannot_bypass_dns_recheck: true,
            },
            validation_happens_before_sender: true,
        },
        headers: AlertWebhookHeaderPreflightReport {
            custom_header_count: webhook.header_count,
            managed_header_count: managed_headers_redacted(webhook).len(),
            headers_redacted: webhook.headers_redacted.clone(),
            managed_headers_redacted: managed_headers_redacted(webhook),
            secret_header_redacted: webhook.secret_redacted,
            header_values_available_to_sender_contract: false,
        },
        body: AlertWebhookBodyPreflightReport {
            content_type: "application/json",
            redaction_policy: "metadata_only",
            input_payload_provided: input_payload.provided,
            input_payload_kind: input_payload.kind,
            input_payload_top_level_item_count: input_payload.top_level_item_count,
            body_redacted: true,
            raw_body_available_to_sender_contract: false,
            planned_body_fields: sender_body_fields(),
        },
        transaction: AlertWebhookWouldSendTransactionReport {
            schema_version: "alert_webhook_sender_transaction.v1",
            method: "POST",
            url_redacted: webhook.url_redacted.clone(),
            headers_redacted: sender_headers_redacted(webhook),
            alert_count,
            timeout_seconds: policy.timeout_seconds,
            max_attempts: policy.max_attempts,
            retry_backoff_seconds: policy.retry_backoff_seconds,
            body_redacted: true,
            body_fields: sender_body_fields(),
        },
        error_sanitization: error_sanitization_report(),
    }
}

fn error_sanitization_report() -> AlertWebhookErrorSanitizationReport {
    AlertWebhookErrorSanitizationReport {
        validation_errors_redacted: true,
        sender_errors_redacted: true,
        response_body_redacted: true,
        raw_error_material_in_report: false,
        sanitizer: "safe_plan_text",
    }
}

fn managed_headers_redacted(webhook: &AlertWebhookDestinationPlan) -> BTreeMap<String, String> {
    let mut headers =
        BTreeMap::from([("Content-Type".to_string(), "application/json".to_string())]);
    if let Some(secret_header) = &webhook.secret_header {
        headers.insert(secret_header.clone(), "[REDACTED]".to_string());
    }

    headers
}

fn sender_headers_redacted(webhook: &AlertWebhookDestinationPlan) -> BTreeMap<String, String> {
    let mut headers = webhook.headers_redacted.clone();
    headers.extend(managed_headers_redacted(webhook));
    headers
}

fn sender_body_fields() -> Vec<&'static str> {
    vec![
        "schema_version",
        "tenant_id",
        "alert_type",
        "severity",
        "dedupe_key",
        "title",
        "summary",
        "labels",
        "facts",
    ]
}

fn error_rate_alert(signal: &ErrorRateSignal, would_send: bool) -> Option<AlertWebhookAlert> {
    if signal.request_count == 0 || signal.error_count == 0 {
        return None;
    }

    let threshold = finite_or(signal.threshold, 0.05).clamp(0.0, 1.0);
    let error_rate = round_ratio(signal.error_count as f64 / signal.request_count as f64);
    if error_rate < threshold {
        return None;
    }

    let window_seconds = signal.window_seconds.unwrap_or(300);
    let severity = normalize_severity(signal.severity.as_deref(), "critical");
    let mut labels = base_labels("error_rate", &severity);
    insert_label(&mut labels, "model", signal.model.as_deref());
    insert_label(&mut labels, "route", signal.route.as_deref());

    let mut facts = BTreeMap::new();
    facts.insert("window_seconds".to_string(), json!(window_seconds));
    facts.insert("request_count".to_string(), json!(signal.request_count));
    facts.insert("error_count".to_string(), json!(signal.error_count));
    facts.insert("error_rate".to_string(), json!(error_rate));
    facts.insert("threshold".to_string(), json!(threshold));
    insert_fact_string(&mut facts, "model", signal.model.as_deref());
    insert_fact_string(&mut facts, "route", signal.route.as_deref());
    insert_fact_string(&mut facts, "observed_at", signal.observed_at.as_deref());

    Some(AlertWebhookAlert {
        alert_type: "error_rate",
        severity,
        would_send,
        webhook_method: "POST",
        dedupe_key: format!(
            "alert:error_rate:{}:{}",
            dedupe_component(signal.model.as_deref().or(signal.route.as_deref())),
            window_seconds
        ),
        title: "High error rate",
        summary: format!(
            "{} errors across {} requests in {}s window",
            signal.error_count, signal.request_count, window_seconds
        ),
        labels,
        facts,
        payload: default_alert_payload_plan(),
    })
}

fn provider_key_cooldown_alert(
    signal: &ProviderKeyCooldownSignal,
    index: usize,
    would_send: bool,
) -> Option<AlertWebhookAlert> {
    let status = signal.status.as_deref().unwrap_or("cooldown");
    if !matches!(status, "cooldown" | "recovery_probe") {
        return None;
    }

    let severity = normalize_severity(signal.severity.as_deref(), "warning");
    let mut labels = base_labels("provider_key_cooldown", &severity);
    insert_label(
        &mut labels,
        "provider_code",
        signal.provider_code.as_deref(),
    );
    insert_label(&mut labels, "channel_name", signal.channel_name.as_deref());
    labels.insert("status".to_string(), super::safe_plan_text(status));

    let mut facts = BTreeMap::new();
    insert_fact_uuid(&mut facts, "provider_id", signal.provider_id);
    insert_fact_string(&mut facts, "provider_code", signal.provider_code.as_deref());
    insert_fact_uuid(&mut facts, "channel_id", signal.channel_id);
    insert_fact_string(&mut facts, "channel_name", signal.channel_name.as_deref());
    insert_fact_uuid(&mut facts, "provider_key_id", signal.provider_key_id);
    insert_fact_string(&mut facts, "key_alias", signal.key_alias.as_deref());
    facts.insert("status".to_string(), json!(super::safe_plan_text(status)));
    insert_fact_string(
        &mut facts,
        "cooldown_until",
        signal.cooldown_until.as_deref(),
    );
    insert_fact_string(
        &mut facts,
        "last_error_code",
        signal.last_error_code.as_deref(),
    );
    if let Some(health_score) = signal.health_score.and_then(finite_value) {
        facts.insert("health_score".to_string(), json!(round_ratio(health_score)));
    }
    insert_fact_string(&mut facts, "observed_at", signal.observed_at.as_deref());

    Some(AlertWebhookAlert {
        alert_type: "provider_key_cooldown",
        severity,
        would_send,
        webhook_method: "POST",
        dedupe_key: format!(
            "alert:provider_key_cooldown:{}",
            signal
                .provider_key_id
                .map(|id| id.to_string())
                .unwrap_or_else(|| format!("fixture-{index}"))
        ),
        title: "Provider key cooldown",
        summary: "Provider key is in cooldown or recovery probe state".to_string(),
        labels,
        facts,
        payload: default_alert_payload_plan(),
    })
}

fn ledger_lag_alert(signal: &LedgerLagSignal, would_send: bool) -> Option<AlertWebhookAlert> {
    let threshold_seconds = signal.threshold_seconds.unwrap_or(300);
    if signal.pending_event_count == 0 || signal.oldest_unsettled_age_seconds < threshold_seconds {
        return None;
    }

    let severity = normalize_severity(signal.severity.as_deref(), "critical");
    let mut labels = base_labels("ledger_lag", &severity);
    insert_label(&mut labels, "queue", signal.queue.as_deref());

    let mut facts = BTreeMap::new();
    facts.insert(
        "pending_event_count".to_string(),
        json!(signal.pending_event_count),
    );
    facts.insert(
        "oldest_unsettled_age_seconds".to_string(),
        json!(signal.oldest_unsettled_age_seconds),
    );
    facts.insert("threshold_seconds".to_string(), json!(threshold_seconds));
    insert_fact_string(&mut facts, "queue", signal.queue.as_deref());
    insert_fact_string(&mut facts, "observed_at", signal.observed_at.as_deref());

    Some(AlertWebhookAlert {
        alert_type: "ledger_lag",
        severity,
        would_send,
        webhook_method: "POST",
        dedupe_key: format!(
            "alert:ledger_lag:{}",
            dedupe_component(signal.queue.as_deref())
        ),
        title: "Ledger lag",
        summary: format!(
            "{} pending ledger events; oldest unsettled age is {}s",
            signal.pending_event_count, signal.oldest_unsettled_age_seconds
        ),
        labels,
        facts,
        payload: default_alert_payload_plan(),
    })
}

fn validate_webhook_url(raw: &str) -> Result<ValidatedWebhookUrl, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err("webhook url must not be empty".to_string());
    }
    if trimmed.len() > 2048 {
        return Err("webhook url must be 2048 bytes or fewer".to_string());
    }

    let rest = trimmed
        .strip_prefix("https://")
        .ok_or_else(|| "webhook url must use https".to_string())?;
    let authority_end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let authority = &rest[..authority_end];
    if authority.is_empty() {
        return Err("webhook url must include a host".to_string());
    }
    if authority.contains('@') {
        return Err("webhook url must not include userinfo".to_string());
    }

    let (host, port) = parse_authority(authority)?;
    let host = normalize_host(&host);
    validate_webhook_host(&host)?;

    let after_authority = &rest[authority_end..];
    let query_redacted = after_authority.contains('?');
    let path_redacted = redacted_path_present(after_authority);

    Ok(ValidatedWebhookUrl {
        scheme: "https".to_string(),
        redacted_url: redacted_url(&host, port, path_redacted, query_redacted),
        host,
        port,
        path_redacted,
        query_redacted,
    })
}

fn parse_authority(authority: &str) -> Result<(String, Option<u16>), String> {
    if let Some(rest) = authority.strip_prefix('[') {
        let Some(end) = rest.find(']') else {
            return Err("webhook url host must be a valid IP literal or DNS name".to_string());
        };
        let host = &rest[..end];
        let after_host = &rest[end + 1..];
        let port = parse_optional_port(after_host)?;
        return Ok((host.to_string(), port));
    }

    if authority.matches(':').count() > 1 {
        return Err("webhook url IPv6 hosts must use brackets".to_string());
    }

    if let Some((host, port)) = authority.rsplit_once(':') {
        if host.is_empty() || port.is_empty() {
            return Err("webhook url must include a valid host and port".to_string());
        }
        return Ok((host.to_string(), Some(parse_port(port)?)));
    }

    Ok((authority.to_string(), None))
}

fn parse_optional_port(after_host: &str) -> Result<Option<u16>, String> {
    if after_host.is_empty() {
        return Ok(None);
    }
    let Some(port) = after_host.strip_prefix(':') else {
        return Err("webhook url host must be followed only by an optional port".to_string());
    };
    if port.is_empty() {
        return Err("webhook url port must not be empty".to_string());
    }
    Ok(Some(parse_port(port)?))
}

fn parse_port(raw: &str) -> Result<u16, String> {
    raw.parse::<u16>()
        .map_err(|_| "webhook url port must be a valid TCP port".to_string())
}

fn normalize_host(host: &str) -> String {
    host.trim_end_matches('.').to_ascii_lowercase()
}

fn redacted_path_present(after_authority: &str) -> bool {
    let Some(path_and_after) = after_authority.strip_prefix('/') else {
        return false;
    };
    let path = path_and_after.split(['?', '#']).next().unwrap_or_default();
    !path.is_empty()
}

fn validate_webhook_host(host: &str) -> Result<(), String> {
    if host.is_empty() {
        return Err("webhook url host must not be empty".to_string());
    }
    if host == "localhost"
        || host.ends_with(".localhost")
        || host.ends_with(".local")
        || host.ends_with(".internal")
    {
        return Err("webhook url host must be externally routable".to_string());
    }
    if let Ok(ip) = host.parse::<IpAddr>() {
        if is_forbidden_webhook_ip(ip) {
            return Err(
                "webhook url must not use localhost, private, link-local, multicast, or unspecified IPs"
                    .to_string(),
            );
        }
        return Ok(());
    }
    if !host.is_ascii() || host.len() > 253 {
        return Err("webhook url host must be an ASCII DNS name".to_string());
    }

    for label in host.split('.') {
        if label.is_empty() || label.len() > 63 {
            return Err("webhook url host must be a valid DNS name".to_string());
        }
        let bytes = label.as_bytes();
        if !bytes[0].is_ascii_alphanumeric()
            || !bytes[bytes.len() - 1].is_ascii_alphanumeric()
            || !bytes
                .iter()
                .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'-')
        {
            return Err("webhook url host must be a valid DNS name".to_string());
        }
    }

    Ok(())
}

fn is_forbidden_webhook_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => {
            ip.is_loopback()
                || ip.is_private()
                || ip.is_link_local()
                || ip.is_unspecified()
                || ip.is_broadcast()
                || ip.is_multicast()
        }
        IpAddr::V6(ip) => {
            ip.is_loopback()
                || ip.is_unspecified()
                || ip.is_multicast()
                || is_unique_local_ipv6(ip)
                || is_link_local_ipv6(ip)
                || ipv4_mapped(ip).is_some_and(|mapped| is_forbidden_webhook_ip(IpAddr::V4(mapped)))
        }
    }
}

fn is_unique_local_ipv6(ip: Ipv6Addr) -> bool {
    ip.segments()[0] & 0xfe00 == 0xfc00
}

fn is_link_local_ipv6(ip: Ipv6Addr) -> bool {
    ip.segments()[0] & 0xffc0 == 0xfe80
}

fn ipv4_mapped(ip: Ipv6Addr) -> Option<Ipv4Addr> {
    let segments = ip.segments();
    if segments[..5] == [0, 0, 0, 0, 0] && segments[5] == 0xffff {
        return Some(Ipv4Addr::new(
            (segments[6] >> 8) as u8,
            segments[6] as u8,
            (segments[7] >> 8) as u8,
            segments[7] as u8,
        ));
    }

    None
}

fn redacted_url(
    host: &str,
    port: Option<u16>,
    path_redacted: bool,
    query_redacted: bool,
) -> String {
    let host = if host.contains(':') {
        format!("[{host}]")
    } else {
        host.to_string()
    };
    let mut redacted = format!("https://{host}");
    if let Some(port) = port {
        redacted.push(':');
        redacted.push_str(&port.to_string());
    }
    if path_redacted {
        redacted.push_str("/[REDACTED_PATH]");
    }
    if query_redacted {
        redacted.push_str("?[REDACTED_QUERY]");
    }
    redacted
}

fn validate_optional_secret(secret: Option<&str>) -> Result<bool, String> {
    let Some(secret) = secret else {
        return Ok(false);
    };
    if secret.trim().is_empty() {
        return Err("webhook secret must not be empty when provided".to_string());
    }
    if secret.len() > 4096 || contains_crlf(secret) {
        return Err("webhook secret must be header-safe and 4096 bytes or fewer".to_string());
    }

    Ok(true)
}

fn validate_secret_header(secret_header: Option<&str>) -> Result<Option<String>, String> {
    let Some(secret_header) = secret_header else {
        return Ok(None);
    };
    let secret_header = secret_header.trim();
    validate_header_name(secret_header)?;
    Ok(Some(secret_header.to_string()))
}

fn validate_headers(
    headers: Option<&BTreeMap<String, String>>,
) -> Result<BTreeMap<String, String>, String> {
    let Some(headers) = headers else {
        return Ok(BTreeMap::new());
    };
    if headers.len() > 32 {
        return Err("webhook headers must contain 32 entries or fewer".to_string());
    }

    let mut redacted = BTreeMap::new();
    let mut seen = BTreeSet::new();
    for (name, value) in headers {
        let normalized_name = validate_header_name(name)?;
        if is_protected_header(&normalized_name) {
            return Err("webhook header is managed by the server".to_string());
        }
        if !seen.insert(normalized_name.clone()) {
            return Err("webhook headers must not contain duplicate names".to_string());
        }
        if value.len() > 4096 || contains_crlf(value) {
            return Err(
                "webhook header value must be header-safe and 4096 bytes or fewer".to_string(),
            );
        }

        let redacted_value = if is_sensitive_header(&normalized_name) {
            "[REDACTED]"
        } else {
            "configured"
        };
        redacted.insert(name.trim().to_string(), redacted_value.to_string());
    }

    Ok(redacted)
}

fn validate_secret_header_not_duplicated(
    secret_header: Option<&str>,
    headers: Option<&BTreeMap<String, String>>,
) -> Result<(), String> {
    let (Some(secret_header), Some(headers)) = (secret_header, headers) else {
        return Ok(());
    };
    let normalized_secret_header = secret_header.trim().to_ascii_lowercase();
    if headers
        .keys()
        .any(|name| name.trim().to_ascii_lowercase() == normalized_secret_header)
    {
        return Err("webhook secret header must not duplicate custom headers".to_string());
    }

    Ok(())
}

fn validate_header_name(name: &str) -> Result<String, String> {
    let name = name.trim();
    if name.is_empty() || name.len() > 128 || !name.bytes().all(is_header_name_byte) {
        return Err("webhook header names must be valid HTTP header tokens".to_string());
    }
    if ai_gateway_observability::redact_secrets(name) != name {
        return Err("webhook header names must not contain secret material".to_string());
    }

    Ok(name.to_ascii_lowercase())
}

fn is_header_name_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&byte)
}

fn is_protected_header(name: &str) -> bool {
    matches!(
        name,
        "connection"
            | "content-length"
            | "expect"
            | "host"
            | "content-type"
            | "te"
            | "trailer"
            | "transfer-encoding"
            | "upgrade"
    )
}

fn is_sensitive_header(name: &str) -> bool {
    name == "authorization"
        || name == "cookie"
        || name == "set-cookie"
        || name == "proxy-authorization"
        || name.contains("api-key")
        || name.contains("apikey")
        || name.contains("secret")
        || name.contains("signature")
        || name.contains("token")
}

fn contains_crlf(value: &str) -> bool {
    value.contains('\r') || value.contains('\n')
}

fn payload_summary(payload: Option<&Value>) -> PayloadSummary {
    let Some(payload) = payload else {
        return PayloadSummary {
            provided: false,
            kind: None,
            top_level_item_count: 0,
            redacted: true,
        };
    };

    let (kind, top_level_item_count) = match payload {
        Value::Null => ("null", 0),
        Value::Bool(_) => ("boolean", 0),
        Value::Number(_) => ("number", 0),
        Value::String(_) => ("string", 1),
        Value::Array(values) => ("array", values.len()),
        Value::Object(object) => ("object", object.len()),
    };

    PayloadSummary {
        provided: true,
        kind: Some(kind),
        top_level_item_count,
        redacted: true,
    }
}

fn base_labels(alert_type: &str, severity: &str) -> BTreeMap<String, String> {
    BTreeMap::from([
        ("alert_type".to_string(), alert_type.to_string()),
        ("severity".to_string(), severity.to_string()),
    ])
}

fn insert_label(labels: &mut BTreeMap<String, String>, name: &str, value: Option<&str>) {
    if let Some(value) = safe_optional_text(value) {
        labels.insert(name.to_string(), value);
    }
}

fn insert_fact_string(facts: &mut BTreeMap<String, Value>, name: &str, value: Option<&str>) {
    if let Some(value) = safe_optional_text(value) {
        facts.insert(name.to_string(), json!(value));
    }
}

fn insert_fact_uuid(facts: &mut BTreeMap<String, Value>, name: &str, value: Option<Uuid>) {
    if let Some(value) = value {
        facts.insert(name.to_string(), json!(value));
    }
}

fn safe_optional_text(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(super::safe_plan_text)
}

fn normalize_severity(value: Option<&str>, default: &str) -> String {
    let normalized = value.unwrap_or(default).trim().to_ascii_lowercase();
    match normalized.as_str() {
        "info" | "warning" | "critical" => normalized,
        _ => default.to_string(),
    }
}

fn default_alert_payload_plan() -> AlertPayloadPlan {
    AlertPayloadPlan {
        content_type: "application/json",
        body_redacted: true,
        planned_body_fields: vec![
            "schema_version",
            "tenant_id",
            "alert_type",
            "severity",
            "dedupe_key",
            "summary",
            "labels",
            "facts",
        ],
    }
}

fn dedupe_component(value: Option<&str>) -> String {
    let value = safe_optional_text(value).unwrap_or_else(|| "global".to_string());
    if value.contains("[REDACTED]") {
        "redacted".to_string()
    } else {
        value
            .chars()
            .map(|character| {
                if character.is_ascii_alphanumeric() || matches!(character, '-' | '_' | '.') {
                    character
                } else {
                    '-'
                }
            })
            .collect()
    }
}

fn finite_or(value: Option<f64>, default: f64) -> f64 {
    value.and_then(finite_value).unwrap_or(default)
}

fn finite_value(value: f64) -> Option<f64> {
    value.is_finite().then_some(value)
}

fn round_ratio(value: f64) -> f64 {
    (value * 10_000.0).round() / 10_000.0
}

fn non_empty_env(vars: &BTreeMap<String, String>, name: &str) -> Option<String> {
    vars.get(name)
        .map(|value| value.trim())
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

fn parse_env_bool(name: &str, value: &str) -> Result<bool, String> {
    match value.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" | "on" => Ok(true),
        "0" | "false" | "no" | "off" => Ok(false),
        _ => Err(format!("{name} must be a boolean")),
    }
}

fn parse_optional_env_u64(
    vars: &BTreeMap<String, String>,
    name: &str,
) -> Result<Option<u64>, String> {
    let Some(value) = non_empty_env(vars, name) else {
        return Ok(None);
    };

    value
        .parse::<u64>()
        .map(Some)
        .map_err(|_| format!("{name} must be an unsigned integer"))
}

fn parse_optional_env_u16(
    vars: &BTreeMap<String, String>,
    name: &str,
) -> Result<Option<u16>, String> {
    let Some(value) = non_empty_env(vars, name) else {
        return Ok(None);
    };

    value
        .parse::<u16>()
        .map(Some)
        .map_err(|_| format!("{name} must be an unsigned integer"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    const TENANT_ID: Uuid = Uuid::from_u128(0x00000000_0000_0000_0000_000000000001);

    #[derive(Debug)]
    struct MockAlertWebhookSender {
        outcomes: RefCell<Vec<AlertWebhookSenderAttemptOutcome>>,
        calls: RefCell<Vec<(u16, AlertWebhookSenderTransaction)>>,
    }

    impl MockAlertWebhookSender {
        fn new(outcomes: Vec<AlertWebhookSenderAttemptOutcome>) -> Self {
            Self {
                outcomes: RefCell::new(outcomes),
                calls: RefCell::new(Vec::new()),
            }
        }

        fn call_count(&self) -> usize {
            self.calls.borrow().len()
        }
    }

    impl AlertWebhookSender for MockAlertWebhookSender {
        fn network_access(&self) -> AlertWebhookSenderNetworkAccess {
            AlertWebhookSenderNetworkAccess::Disabled
        }

        fn send(
            &self,
            transaction: &AlertWebhookSenderTransaction,
            attempt: u16,
        ) -> AlertWebhookSenderAttemptOutcome {
            self.calls.borrow_mut().push((attempt, transaction.clone()));
            self.outcomes.borrow_mut().remove(0)
        }
    }

    #[derive(Debug)]
    struct MockAlertWebhookDnsResolver {
        resolved_ips: Vec<IpAddr>,
        error: Option<String>,
        hosts: RefCell<Vec<String>>,
    }

    impl MockAlertWebhookDnsResolver {
        fn new(resolved_ips: Vec<IpAddr>) -> Self {
            Self {
                resolved_ips,
                error: None,
                hosts: RefCell::new(Vec::new()),
            }
        }

        fn with_error(error: impl Into<String>) -> Self {
            Self {
                resolved_ips: Vec::new(),
                error: Some(error.into()),
                hosts: RefCell::new(Vec::new()),
            }
        }

        fn hosts(&self) -> Vec<String> {
            self.hosts.borrow().clone()
        }
    }

    impl AlertWebhookDnsResolver for MockAlertWebhookDnsResolver {
        fn resolve_host(&self, host: &str) -> Result<Vec<IpAddr>, String> {
            self.hosts.borrow_mut().push(host.to_string());
            if let Some(error) = &self.error {
                return Err(error.clone());
            }

            Ok(self.resolved_ips.clone())
        }
    }

    #[derive(Debug)]
    struct NetworkCapableAlertWebhookSender {
        calls: RefCell<usize>,
    }

    impl NetworkCapableAlertWebhookSender {
        fn new() -> Self {
            Self {
                calls: RefCell::new(0),
            }
        }

        fn call_count(&self) -> usize {
            *self.calls.borrow()
        }
    }

    impl AlertWebhookSender for NetworkCapableAlertWebhookSender {
        fn network_access(&self) -> AlertWebhookSenderNetworkAccess {
            AlertWebhookSenderNetworkAccess::Enabled
        }

        fn send(
            &self,
            _transaction: &AlertWebhookSenderTransaction,
            _attempt: u16,
        ) -> AlertWebhookSenderAttemptOutcome {
            *self.calls.borrow_mut() += 1;
            AlertWebhookSenderAttemptOutcome::success(202)
        }
    }

    #[test]
    fn fixture_builds_three_alert_contracts_without_outbound_call() {
        let input = alert_webhook_input_from_json_str(include_str!(
            "../../../tests/fixtures/worker/alert_webhook_plan_contract.json"
        ))
        .expect("fixture should parse");

        let plan = alert_webhook_plan(
            TENANT_ID,
            AlertWebhookInputSource::InputJson {
                path: "tests/fixtures/worker/alert_webhook_plan_contract.json".to_string(),
            },
            input,
        )
        .expect("plan should build");

        assert!(plan.dry_run);
        assert!(!plan.outbound_call);
        assert_eq!(plan.alert_count, 3);
        assert_eq!(
            plan.alerts
                .iter()
                .map(|alert| alert.alert_type)
                .collect::<Vec<_>>(),
            vec!["error_rate", "provider_key_cooldown", "ledger_lag"]
        );
        assert!(plan.alerts.iter().all(|alert| alert.would_send));
        assert_eq!(
            plan.webhook.url_redacted.as_deref(),
            Some("https://hooks.example.com/[REDACTED_PATH]?[REDACTED_QUERY]")
        );
        assert_eq!(plan.webhook.headers_redacted["Authorization"], "[REDACTED]");
        assert_eq!(plan.input_payload.kind, Some("object"));
        assert!(!plan.sender.implemented);
        assert!(!plan.sender.network_supported);
        assert_eq!(
            plan.sender.transaction_schema_version,
            "alert_webhook_sender_transaction.v1"
        );
        assert_eq!(plan.sender.timeout.request_timeout_seconds, 7);
        assert_eq!(plan.sender.retry.max_attempts, 3);
        assert_eq!(plan.sender.retry.backoff_seconds, 2);
        assert!(plan.sender.preflight.ready);
        assert!(plan.sender.preflight.would_send);
        assert!(!plan.sender.preflight.network_call_allowed);
        assert!(plan.sender.preflight.send_refused_in_this_slice);
        assert!(plan.sender.preflight.ssrf_guard.url_validated);
        assert!(
            plan.sender
                .preflight
                .ssrf_guard
                .validation_happens_before_sender
        );
        assert_eq!(plan.sender.preflight.body.redaction_policy, "metadata_only");
        assert!(plan.sender.preflight.body.body_redacted);
        assert!(
            !plan
                .sender
                .preflight
                .body
                .raw_body_available_to_sender_contract
        );
        assert_eq!(
            plan.sender.preflight.transaction.url_redacted.as_deref(),
            Some("https://hooks.example.com/[REDACTED_PATH]?[REDACTED_QUERY]")
        );
        assert_eq!(
            plan.sender.preflight.transaction.headers_redacted["Authorization"],
            "[REDACTED]"
        );
        assert_eq!(
            plan.sender.preflight.transaction.headers_redacted["X-Alert-Signature"],
            "[REDACTED]"
        );
        assert_eq!(
            plan.sender.preflight.transaction.headers_redacted["Content-Type"],
            "application/json"
        );
        assert_eq!(plan.sender.preflight.transaction.timeout_seconds, 7);
        assert_eq!(plan.sender.preflight.transaction.max_attempts, 3);
        assert_eq!(
            plan.sender.transaction.headers_redacted["Authorization"],
            "[REDACTED]"
        );
        assert!(plan.sender.transaction.body_redacted);
        assert_eq!(plan.sender.attempts.len(), 3);
    }

    #[test]
    fn plan_serialization_does_not_echo_secret_material_or_payload_body() {
        let fixture =
            include_str!("../../../tests/fixtures/worker/alert_webhook_plan_contract.json");
        let input = alert_webhook_input_from_json_str(fixture).expect("fixture should parse");
        let plan = alert_webhook_plan(TENANT_ID, AlertWebhookInputSource::Env, input)
            .expect("plan should build");
        let serialized = serde_json::to_string(&plan).expect("plan should serialize");

        for forbidden in [
            "fixture-webhook-secret",
            "fx-authz",
            "fixture-cookie-token",
            "fixture-provider-key-secret",
            "fixture-path-secret",
            "fixture-query-secret",
            "fixture-raw-payload-secret",
            "user:pass",
            "api_key",
            "provider_key_value",
            "secret_fingerprint",
        ] {
            assert!(
                !serialized.contains(forbidden),
                "serialized plan leaked `{forbidden}`"
            );
        }
    }

    #[test]
    fn env_input_reads_webhook_destination_without_alert_signals() {
        let input = alert_webhook_input_from_env_vars([
            (
                "AI_GATEWAY_ALERT_WEBHOOK_URL".to_string(),
                "https://hooks.example.com/alert".to_string(),
            ),
            (
                "AI_GATEWAY_ALERT_WEBHOOK_SECRET".to_string(),
                "env-secret".to_string(),
            ),
            (
                "AI_GATEWAY_ALERT_WEBHOOK_TIMEOUT_SECONDS".to_string(),
                "12".to_string(),
            ),
            (
                "AI_GATEWAY_ALERT_WEBHOOK_RETRY_MAX_ATTEMPTS".to_string(),
                "2".to_string(),
            ),
            (
                "AI_GATEWAY_ALERT_WEBHOOK_RETRY_BACKOFF_SECONDS".to_string(),
                "4".to_string(),
            ),
        ])
        .expect("env should parse");

        let plan = alert_webhook_plan(TENANT_ID, AlertWebhookInputSource::Env, input)
            .expect("plan should build");

        assert!(plan.webhook.configured);
        assert!(plan.webhook.enabled);
        assert_eq!(plan.sender.timeout.request_timeout_seconds, 12);
        assert_eq!(plan.sender.retry.max_attempts, 2);
        assert_eq!(plan.sender.retry.backoff_seconds, 4);
        assert_eq!(plan.alert_count, 0);
        let serialized = serde_json::to_string(&plan).expect("plan should serialize");
        assert!(!serialized.contains("env-secret"));
    }

    #[test]
    fn rejects_ssrf_prone_webhook_urls() {
        for url in [
            "http://hooks.example.com/alert",
            "https://localhost/alert",
            "https://metadata.google.internal/alert",
            "https://127.0.0.1/alert",
            "https://10.0.0.1/alert",
            "https://172.16.0.1/alert",
            "https://192.168.0.1/alert",
            "https://169.254.169.254/latest/meta-data",
            "https://[::1]/alert",
            "https://[fd00::1]/alert",
            "https://[::ffff:127.0.0.1]/alert",
            "https://user:pass@hooks.example.com/alert",
        ] {
            let input = AlertWebhookInput {
                webhook: AlertWebhookConfigInput {
                    enabled: Some(true),
                    url: Some(url.to_string()),
                    secret: None,
                    secret_header: None,
                    headers: None,
                    timeout_seconds: None,
                    retry: None,
                    retry_max_attempts: None,
                    retry_backoff_seconds: None,
                    payload: None,
                },
                signals: AlertSignalsInput::default(),
            };

            assert!(
                alert_webhook_plan(TENANT_ID, AlertWebhookInputSource::Env, input).is_err(),
                "{url} should be rejected"
            );
        }
    }

    #[test]
    fn preflight_rejects_secret_header_duplicate_and_content_type_override() {
        let mut duplicate_secret_header = BTreeMap::new();
        duplicate_secret_header.insert("x-alert-signature".to_string(), "custom".to_string());
        let duplicate_input = AlertWebhookInput {
            webhook: AlertWebhookConfigInput {
                enabled: Some(true),
                url: Some("https://hooks.example.com/alert".to_string()),
                secret: Some("fixture-webhook-secret".to_string()),
                secret_header: Some("X-Alert-Signature".to_string()),
                headers: Some(duplicate_secret_header),
                timeout_seconds: None,
                retry: None,
                retry_max_attempts: None,
                retry_backoff_seconds: None,
                payload: None,
            },
            signals: AlertSignalsInput::default(),
        };
        let duplicate_error =
            alert_webhook_plan(TENANT_ID, AlertWebhookInputSource::Env, duplicate_input)
                .expect_err("secret header should not duplicate custom headers");
        assert!(duplicate_error.contains("secret header"));

        let mut content_type = BTreeMap::new();
        content_type.insert("Content-Type".to_string(), "text/plain".to_string());
        let content_type_input = AlertWebhookInput {
            webhook: AlertWebhookConfigInput {
                enabled: Some(true),
                url: Some("https://hooks.example.com/alert".to_string()),
                secret: None,
                secret_header: None,
                headers: Some(content_type),
                timeout_seconds: None,
                retry: None,
                retry_max_attempts: None,
                retry_backoff_seconds: None,
                payload: None,
            },
            signals: AlertSignalsInput::default(),
        };
        let content_type_error =
            alert_webhook_plan(TENANT_ID, AlertWebhookInputSource::Env, content_type_input)
                .expect_err("content type should be managed by sender");
        assert!(content_type_error.contains("managed by the server"));
    }

    #[test]
    fn mock_sender_success_uses_redacted_transaction_contract() {
        let input = alert_webhook_input_from_json_str(include_str!(
            "../../../tests/fixtures/worker/alert_webhook_plan_contract.json"
        ))
        .expect("fixture should parse");
        let sender =
            MockAlertWebhookSender::new(vec![AlertWebhookSenderAttemptOutcome::success(202)]);

        let report = execute_alert_webhook_sender_contract(
            true,
            TENANT_ID,
            AlertWebhookInputSource::Env,
            input,
            &sender,
        )
        .expect("mock sender contract should run");

        assert!(report.attempted);
        assert!(report.sent);
        assert!(!report.network_call_allowed);
        assert_eq!(report.sender_network_access, "disabled");
        assert!(report.preflight_passed);
        assert!(report.dns_preflight_passed);
        assert_eq!(report.dns_resolved_ip_count, 1);
        assert!(report.dns_resolved_ips_redacted);
        assert_eq!(report.alert_count, 3);
        assert_eq!(report.attempt_count, 1);
        assert_eq!(sender.call_count(), 1);
        let calls = sender.calls.borrow();
        let (_, transaction) = &calls[0];
        assert_eq!(
            transaction.url_redacted,
            "https://hooks.example.com/[REDACTED_PATH]?[REDACTED_QUERY]"
        );
        assert_eq!(transaction.headers_redacted["Authorization"], "[REDACTED]");
        assert_eq!(
            transaction.headers_redacted["X-Alert-Signature"],
            "[REDACTED]"
        );
        assert_eq!(
            transaction.headers_redacted["Content-Type"],
            "application/json"
        );
        assert!(transaction.body_redacted);
        assert!(!transaction.network_call_allowed);
        assert!(transaction.send_refused_in_this_slice);
        assert_eq!(transaction.timeout_seconds, 7);
        assert_eq!(transaction.max_attempts, 3);

        let serialized =
            serde_json::to_string(transaction).expect("transaction should serialize safely");
        for forbidden in [
            "fixture-webhook-secret",
            "fx-authz",
            "fixture-cookie-token",
            "fixture-path-secret",
            "fixture-query-secret",
            "fixture-raw-payload-secret",
        ] {
            assert!(
                !serialized.contains(forbidden),
                "sender transaction leaked `{forbidden}`"
            );
        }
    }

    #[test]
    fn mock_sender_failure_retries_and_redacts_error_text() {
        let input = alert_webhook_input_from_json_str(include_str!(
            "../../../tests/fixtures/worker/alert_webhook_plan_contract.json"
        ))
        .expect("fixture should parse");
        let sender = MockAlertWebhookSender::new(vec![
            AlertWebhookSenderAttemptOutcome::retryable_failure(
                Some(500),
                "upstream echoed fixture-webhook-secret",
            ),
            AlertWebhookSenderAttemptOutcome::retryable_failure(
                None,
                "timeout with fixture-raw-payload-secret",
            ),
            AlertWebhookSenderAttemptOutcome::retryable_failure(
                Some(503),
                "still failing webhook auth marker",
            ),
        ]);

        let report = execute_alert_webhook_sender_contract(
            true,
            TENANT_ID,
            AlertWebhookInputSource::Env,
            input,
            &sender,
        )
        .expect("mock sender contract should run");

        assert!(report.attempted);
        assert!(!report.sent);
        assert!(!report.network_call_allowed);
        assert_eq!(report.sender_network_access, "disabled");
        assert!(report.no_error_secret_echo);
        assert!(!report.error_sanitization.raw_error_material_in_report);
        assert_eq!(report.attempt_count, 3);
        assert_eq!(sender.call_count(), 3);
        assert!(report.attempts[0].will_retry);
        assert!(report.attempts[1].will_retry);
        assert!(!report.attempts[2].will_retry);

        let serialized = serde_json::to_string(&report).expect("report should serialize");
        for forbidden in [
            "fixture-webhook-secret",
            "fixture-raw-payload-secret",
            "fx-authz",
        ] {
            assert!(
                !serialized.contains(forbidden),
                "sender report leaked `{forbidden}`"
            );
        }
    }

    #[test]
    fn sender_contract_without_force_does_not_invoke_sender() {
        let input = alert_webhook_input_from_json_str(include_str!(
            "../../../tests/fixtures/worker/alert_webhook_plan_contract.json"
        ))
        .expect("fixture should parse");
        let sender =
            MockAlertWebhookSender::new(vec![AlertWebhookSenderAttemptOutcome::success(202)]);

        let error = execute_alert_webhook_sender_contract(
            false,
            TENANT_ID,
            AlertWebhookInputSource::Env,
            input,
            &sender,
        )
        .expect_err("sender contract should require force");

        assert!(error.contains("requires --force"));
        assert_eq!(sender.call_count(), 0);
    }

    #[test]
    fn force_rejects_network_capable_sender_before_any_attempt() {
        let input = alert_webhook_input_from_json_str(include_str!(
            "../../../tests/fixtures/worker/alert_webhook_plan_contract.json"
        ))
        .expect("fixture should parse");
        let sender = NetworkCapableAlertWebhookSender::new();

        let error = execute_alert_webhook_sender_contract(
            true,
            TENANT_ID,
            AlertWebhookInputSource::Env,
            input,
            &sender,
        )
        .expect_err("network-capable sender should be refused in this slice");

        assert!(error.contains("refuses network-capable sender"));
        assert_eq!(sender.call_count(), 0);
    }

    #[test]
    fn ssrf_validation_runs_before_sender_contract_send() {
        let input = AlertWebhookInput {
            webhook: AlertWebhookConfigInput {
                enabled: Some(true),
                url: Some("https://127.0.0.1/alert".to_string()),
                secret: None,
                secret_header: None,
                headers: None,
                timeout_seconds: None,
                retry: None,
                retry_max_attempts: None,
                retry_backoff_seconds: None,
                payload: None,
            },
            signals: AlertSignalsInput {
                error_rate: Some(ErrorRateSignal {
                    request_count: 10,
                    error_count: 10,
                    ..ErrorRateSignal::default()
                }),
                ..AlertSignalsInput::default()
            },
        };
        let sender =
            MockAlertWebhookSender::new(vec![AlertWebhookSenderAttemptOutcome::success(202)]);

        let error = execute_alert_webhook_sender_contract(
            true,
            TENANT_ID,
            AlertWebhookInputSource::Env,
            input,
            &sender,
        )
        .expect_err("ssrf-prone url should fail before sender call");

        assert!(error.contains("localhost, private, link-local"));
        assert_eq!(sender.call_count(), 0);
    }

    #[test]
    fn dns_recheck_rejects_if_any_resolved_ip_is_forbidden_before_sender() {
        let input = alert_webhook_input_from_json_str(include_str!(
            "../../../tests/fixtures/worker/alert_webhook_plan_contract.json"
        ))
        .expect("fixture should parse");
        let sender =
            MockAlertWebhookSender::new(vec![AlertWebhookSenderAttemptOutcome::success(202)]);
        let resolver = MockAlertWebhookDnsResolver::new(vec![
            IpAddr::V4(Ipv4Addr::new(198, 51, 100, 7)),
            IpAddr::V4(Ipv4Addr::new(10, 0, 0, 7)),
        ]);

        let error = execute_alert_webhook_sender_contract_with_resolver(
            true,
            TENANT_ID,
            AlertWebhookInputSource::Env,
            input,
            &sender,
            &resolver,
        )
        .expect_err("forbidden resolved IP should fail before sender call");

        assert!(error.contains("at least one resolved IP"));
        assert_eq!(resolver.hosts(), vec!["hooks.example.com".to_string()]);
        assert_eq!(sender.call_count(), 0);
    }

    #[test]
    fn dns_recheck_error_does_not_echo_raw_url_secret_path_or_query() {
        let input = alert_webhook_input_from_json_str(include_str!(
            "../../../tests/fixtures/worker/alert_webhook_plan_contract.json"
        ))
        .expect("fixture should parse");
        let sender =
            MockAlertWebhookSender::new(vec![AlertWebhookSenderAttemptOutcome::success(202)]);
        let resolver = MockAlertWebhookDnsResolver::with_error(
            "resolver failed for https://hooks.example.com/services/T000/B000/fixture-path-secret?token=fixture-query-secret with fixture-webhook-secret",
        );

        let error = execute_alert_webhook_sender_contract_with_resolver(
            true,
            TENANT_ID,
            AlertWebhookInputSource::Env,
            input,
            &sender,
            &resolver,
        )
        .expect_err("resolver error should be sanitized");

        assert_eq!(resolver.hosts(), vec!["hooks.example.com".to_string()]);
        assert_eq!(sender.call_count(), 0);
        for forbidden in [
            "/services/T000/B000/fixture-path-secret",
            "fixture-path-secret",
            "fixture-query-secret",
            "fixture-webhook-secret",
        ] {
            assert!(
                !error.contains(forbidden),
                "DNS error leaked `{forbidden}`: {error}"
            );
        }
    }

    #[test]
    fn force_cannot_bypass_dns_recheck_for_network_capable_sender() {
        let input = alert_webhook_input_from_json_str(include_str!(
            "../../../tests/fixtures/worker/alert_webhook_plan_contract.json"
        ))
        .expect("fixture should parse");
        let sender = NetworkCapableAlertWebhookSender::new();
        let resolver = MockAlertWebhookDnsResolver::new(vec![IpAddr::V6(Ipv6Addr::LOCALHOST)]);

        let error = execute_alert_webhook_sender_contract_with_resolver(
            true,
            TENANT_ID,
            AlertWebhookInputSource::Env,
            input,
            &sender,
            &resolver,
        )
        .expect_err("DNS recheck should run before network-capable sender gate");

        assert!(error.contains("at least one resolved IP"));
        assert_eq!(resolver.hosts(), vec!["hooks.example.com".to_string()]);
        assert_eq!(sender.call_count(), 0);
    }
}
