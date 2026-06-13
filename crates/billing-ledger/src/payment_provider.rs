use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

pub const PAYMENT_PROVIDER_RUNTIME_SKELETON_SCHEMA: &str = "payment_provider_runtime_skeleton.v1";
pub const PAYMENT_PROVIDER_ADAPTER_CONFIG_SCHEMA: &str =
    "payment_provider_adapter_config_status.v1";
pub const PAYMENT_PROVIDER_STRIPE_LIKE_SANDBOX_ADAPTER_SCHEMA: &str =
    "payment_provider_stripe_like_sandbox_adapter.v1";
pub const PAYMENT_PROVIDER_STRIPE_API_SOURCE_OF_TRUTH_SCHEMA: &str =
    "payment_provider_stripe_api_source_of_truth.v1";
pub const PAYMENT_PROVIDER_STRIPE_API_FETCH_ADAPTER_SCHEMA: &str =
    "payment_provider_stripe_api_fetch_adapter.v1";
pub const PAYMENT_PROVIDER_STRIPE_LIKE_CLIENT_PLAN_SCHEMA: &str =
    "payment_provider_stripe_like_client_plan.v1";
pub const PAYMENT_PROVIDER_STRIPE_LIKE_FETCH_EXECUTOR_SCHEMA: &str =
    "payment_provider_stripe_like_fetch_executor.v1";
pub const PAYMENT_PROVIDER_STRIPE_LIKE_CLIENT_HANDOFF_SCHEMA: &str =
    "payment_provider_stripe_like_client_handoff.v1";
pub const PAYMENT_PROVIDER_STRIPE_LIKE_SOURCE_OF_TRUTH_SUMMARY_SCHEMA: &str =
    "payment_provider_stripe_like_source_of_truth_summary.v1";
pub const PAYMENT_PROVIDER_STRIPE_LIKE_RESPONSE_OBJECT_RECONCILIATION_SCHEMA: &str =
    "payment_provider_stripe_like_response_object_reconciliation.v1";
pub const PAYMENT_PROVIDER_EXECUTOR_CONTRACT_SCHEMA: &str = "payment_provider_executor_contract.v1";
pub const STRIPE_LIKE_SANDBOX_ADAPTER: &str = "stripe_like_sandbox";
pub const STRIPE_LIKE_SIGNATURE_TOLERANCE_SECONDS: u64 = 300;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PaymentProviderEventType {
    Callback,
    Capture,
    Refund,
    Chargeback,
}

impl PaymentProviderEventType {
    fn action_result(self) -> &'static str {
        match self {
            Self::Callback => "callback_recorded_config_needed",
            Self::Capture => "capture_planned_config_needed",
            Self::Refund => "refund_planned_config_needed",
            Self::Chargeback => "chargeback_planned_config_needed",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PaymentProviderHandoffRequest {
    pub provider: String,
    pub event_type: PaymentProviderEventType,
    pub external_event_id_hash: String,
    pub amount: String,
    pub currency: String,
    pub idempotency_key_hash: Option<String>,
    #[serde(default)]
    pub refs: PaymentProviderRefs,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PaymentProviderAdapterConfigInput {
    pub provider: Option<String>,
    pub adapter_enabled: bool,
    pub merchant_account_present: bool,
    pub credential_present: bool,
    pub credential_fingerprint_prefix: Option<String>,
    pub webhook_secret_present: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PaymentProviderAdapterConfigStatus {
    pub schema: &'static str,
    pub provider: String,
    pub status: &'static str,
    pub adapter_enabled: bool,
    pub merchant_account_present: bool,
    pub credential_present: bool,
    pub credential_status: &'static str,
    pub credential_fingerprint_present: bool,
    pub credential_fingerprint_prefix: Option<String>,
    pub credential_lifecycle: PaymentProviderCredentialLifecycleReadback,
    pub signature_verifier_status: &'static str,
    pub supported_events: Vec<PaymentProviderEventType>,
    pub adapter: String,
    pub signature_format_support: PaymentProviderSignatureFormatSupport,
    pub stripe_api_source_of_truth: PaymentProviderStripeApiSourceOfTruthReadback,
    pub next_step: &'static str,
    pub merchant_connected: bool,
    pub production_payment_evidence: bool,
    pub secret_safe: bool,
    pub credential_value_echoed: bool,
    pub provider_secret_echoed: bool,
    pub authorization_echoed: bool,
    pub raw_webhook_body_echoed: bool,
    pub db_url_echoed: bool,
    pub omitted_fields: &'static [&'static str],
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PaymentProviderStripeApiSourceOfTruthInput {
    pub provider: String,
    pub credential_source: String,
    pub credential_source_ready: bool,
    pub event_type: Option<PaymentProviderEventType>,
    pub provider_event_id_present: bool,
    pub provider_object_id_present: bool,
    pub local_payment_intent_ref_present: bool,
    pub local_payment_capture_ref_present: bool,
    pub local_refund_ref_present: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PaymentProviderStripeApiSourceOfTruthReadback {
    pub schema: &'static str,
    pub adapter: &'static str,
    pub provider: String,
    pub api_read_model: &'static str,
    pub source_of_truth_status: &'static str,
    pub source_of_truth_blocked_reason: Option<&'static str>,
    pub network_call_enabled: bool,
    pub secret_ref_required: bool,
    pub credential_source: String,
    pub credential_source_ready: bool,
    pub object_ref_requirements: PaymentProviderStripeApiObjectRefRequirements,
    pub object_ref_readback: PaymentProviderStripeApiObjectRefReadback,
    pub fetch_adapter: StripeApiFetchAdapterReadback,
    pub capture_source_selection: &'static str,
    pub refund_source_selection: &'static str,
    pub chargeback_source_selection: &'static str,
    pub callback_source_selection: &'static str,
    pub sandbox_local_only: bool,
    pub production_payment_evidence: bool,
    pub secret_safe: bool,
    pub authorization_echoed: bool,
    pub provider_secret_echoed: bool,
    pub raw_provider_payload_echoed: bool,
    pub raw_webhook_body_echoed: bool,
    pub omitted_fields: &'static [&'static str],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum StripeApiObjectType {
    Event,
    PaymentIntent,
    Charge,
    Refund,
    Dispute,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StripeLikeClientOperation {
    RetrievePaymentIntent,
    RetrieveCharge,
    RetrieveRefund,
    RetrieveDispute,
    CapturePaymentIntent,
    CreateRefund,
    ChargebackAck,
}

impl StripeLikeClientOperation {
    fn http_method(self) -> &'static str {
        match self {
            Self::RetrievePaymentIntent
            | Self::RetrieveCharge
            | Self::RetrieveRefund
            | Self::RetrieveDispute => "GET",
            Self::CapturePaymentIntent | Self::CreateRefund | Self::ChargebackAck => "POST",
        }
    }

    fn path_template(self) -> &'static str {
        match self {
            Self::RetrievePaymentIntent => "/v1/payment_intents/{payment_intent_ref}",
            Self::RetrieveCharge => "/v1/charges/{charge_ref}",
            Self::RetrieveRefund => "/v1/refunds/{refund_ref}",
            Self::RetrieveDispute => "/v1/disputes/{dispute_ref}",
            Self::CapturePaymentIntent => "/v1/payment_intents/{payment_intent_ref}/capture",
            Self::CreateRefund => "/v1/refunds",
            Self::ChargebackAck => "/v1/disputes/{dispute_ref}/close",
        }
    }

    fn required_refs(self) -> &'static [&'static str] {
        match self {
            Self::RetrievePaymentIntent | Self::CapturePaymentIntent => {
                &["provider_object_ref_or_payment_intent_ref"]
            }
            Self::RetrieveCharge => &["charge_ref_or_provider_object_ref"],
            Self::RetrieveRefund => &["refund_ref_or_provider_object_ref"],
            Self::RetrieveDispute | Self::ChargebackAck => &["dispute_ref_or_provider_object_ref"],
            Self::CreateRefund => &["charge_ref_or_payment_intent_ref", "idempotency"],
        }
    }

    fn idempotency_header_required(self) -> bool {
        matches!(
            self,
            Self::CapturePaymentIntent | Self::CreateRefund | Self::ChargebackAck
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StripeLikeClientRequest {
    pub provider: String,
    pub operation: StripeLikeClientOperation,
    pub credential_source: String,
    pub credential_source_ready: bool,
    pub merchant_account_ref_present: bool,
    #[serde(default)]
    pub idempotency: PaymentProviderExecutorIdempotency,
    #[serde(default)]
    pub provider_refs: PaymentProviderExecutorProviderRefs,
    pub amount: Option<String>,
    pub currency: Option<String>,
    pub reason: Option<String>,
    #[serde(default)]
    pub local_refs: PaymentProviderRefs,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct StripeLikeClientBodyFieldReadback {
    pub name: &'static str,
    pub source: &'static str,
    pub value_present: bool,
    pub value_echoed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct StripeLikeHttpTimeoutReadback {
    pub connect_timeout_ms: u64,
    pub request_timeout_ms: u64,
    pub response_body_timeout_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct StripeLikeRetryPolicyReadback {
    pub max_attempts: u8,
    pub retry_on_timeout: bool,
    pub retry_on_429: bool,
    pub retry_on_5xx: bool,
    pub backoff: &'static str,
    pub idempotency_required_for_post_retry: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct StripeLikeRequestBuilderReadback {
    pub method: &'static str,
    pub path_template: &'static str,
    pub path_ref_source: &'static str,
    pub path_ref_present: bool,
    pub authorization_header_required: bool,
    pub authorization_header_present: bool,
    pub authorization_header_value_echoed: bool,
    pub idempotency_header_required: bool,
    pub idempotency_header_present: bool,
    pub idempotency_header_value_echoed: bool,
    pub body_fields: Vec<StripeLikeClientBodyFieldReadback>,
    pub timeout: StripeLikeHttpTimeoutReadback,
    pub retry_policy: StripeLikeRetryPolicyReadback,
    pub raw_secret_echoed: bool,
    pub raw_provider_ref_echoed: bool,
    pub raw_body_echoed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct StripeLikeClientRequestPlan {
    pub operation: StripeLikeClientOperation,
    pub method: &'static str,
    pub path_template: &'static str,
    pub path_ref_source: &'static str,
    pub path_ref_present: bool,
    pub body_fields: Vec<StripeLikeClientBodyFieldReadback>,
    pub idempotency_header_required: bool,
    pub idempotency_header_present: bool,
    pub idempotency_header_value_echoed: bool,
    pub credential_source_required: bool,
    pub credential_source_ready: bool,
    pub authorization_header_required: bool,
    pub authorization_header_value_echoed: bool,
    pub merchant_account_ref_required: bool,
    pub merchant_account_ref_present: bool,
    pub timeout: StripeLikeHttpTimeoutReadback,
    pub retry_policy: StripeLikeRetryPolicyReadback,
    pub raw_provider_payload_echoed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct StripeLikeClientResult {
    pub schema: &'static str,
    pub provider: String,
    pub status: &'static str,
    pub request: StripeLikeClientRequestPlan,
    pub network_call_performed: bool,
    pub http_client: &'static str,
    pub object_found: Option<bool>,
    pub credential_source_required: bool,
    pub credential_source: String,
    pub required_refs: &'static [&'static str],
    pub validation_errors: Vec<&'static str>,
    pub blocked_reasons: Vec<&'static str>,
    pub secret_safe: bool,
    pub raw_secret_echoed: bool,
    pub authorization_echoed: bool,
    pub raw_idempotency_key_echoed: bool,
    pub raw_provider_payload_echoed: bool,
    pub raw_provider_ref_echoed: bool,
    pub omitted_fields: &'static [&'static str],
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StripeLikeFetchExecutorRequest {
    pub provider: String,
    pub request_plan: StripeLikeClientRequestPlan,
    pub network_enabled: bool,
    pub fixture_response: Option<serde_json::Value>,
    pub response_header_summary: Option<StripeLikeResponseHeaderSummaryInput>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StripeLikeResponseHeaderSummaryInput {
    pub http_status: Option<u16>,
    #[serde(default)]
    pub retry_after_present: bool,
    pub retry_after_seconds: Option<u64>,
    #[serde(default)]
    pub stripe_request_id_present: bool,
    pub stripe_request_id_hash: Option<String>,
    pub rate_limit_category: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct StripeLikeRateLimitReadback {
    pub retry_after_present: bool,
    pub retry_after_seconds: Option<u64>,
    pub stripe_request_id_present: bool,
    pub stripe_request_id_hash: Option<String>,
    pub rate_limit_category: Option<String>,
    pub should_retry: bool,
    pub backoff_reason: &'static str,
    pub header_summary_present: bool,
    pub header_summary_source: &'static str,
    pub raw_headers_echoed: bool,
    pub authorization_echoed: bool,
    pub secret_safe: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct StripeLikeSourceOfTruthHandoffReadback {
    pub adapter: &'static str,
    pub fetch_adapter_schema: &'static str,
    pub required_provider_object_summary_schema: &'static str,
    pub provider_object_summary_present: bool,
    pub response_header_summary_present: bool,
    pub source_of_truth_handoff_ready: bool,
    pub reconciliation_handoff: &'static str,
    pub network_call_performed: bool,
    pub raw_object_ref_echoed: bool,
    pub raw_provider_payload_echoed: bool,
    pub raw_headers_echoed: bool,
    pub authorization_echoed: bool,
    pub provider_secret_echoed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct StripeLikeClientHandoffReadback {
    pub schema: &'static str,
    pub status: &'static str,
    pub implementation: &'static str,
    pub provider: String,
    pub runtime_secret_ref_required: bool,
    pub runtime_secret_ref_resolved: bool,
    pub reqwest_client_configured: bool,
    pub request_builder_configured: bool,
    pub object_ref_present: bool,
    pub object_fetch_would_be_sent: bool,
    pub object_fetch_blocked_reasons: Vec<&'static str>,
    pub retry_policy: StripeLikeRetryPolicyReadback,
    pub source_of_truth_handoff: StripeLikeSourceOfTruthHandoffReadback,
    pub network_call_enabled: bool,
    pub network_call_performed: bool,
    pub secret_safe: bool,
    pub raw_secret_echoed: bool,
    pub authorization_echoed: bool,
    pub raw_provider_ref_echoed: bool,
    pub raw_headers_echoed: bool,
    pub raw_body_echoed: bool,
    pub omitted_fields: &'static [&'static str],
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct StripeLikeFetchExecutorResult {
    pub schema: &'static str,
    pub provider: String,
    pub status: &'static str,
    pub interface: &'static str,
    pub implementation: &'static str,
    pub replace_with: &'static str,
    pub request_plan: StripeLikeClientRequestPlan,
    pub network_call_enabled: bool,
    pub network_call_performed: bool,
    pub http_client: &'static str,
    pub request_builder: StripeLikeRequestBuilderReadback,
    pub client_handoff: StripeLikeClientHandoffReadback,
    pub object_found: Option<bool>,
    pub provider_object_summary: Option<StripeLikeProviderObjectSummary>,
    pub response_header_summary: StripeLikeRateLimitReadback,
    pub rate_limit_readback: StripeLikeRateLimitReadback,
    pub fixture_response_parsed: bool,
    pub parser_summary_available: bool,
    pub blocked_reasons: Vec<&'static str>,
    pub secret_safe: bool,
    pub raw_secret_echoed: bool,
    pub authorization_echoed: bool,
    pub raw_idempotency_key_echoed: bool,
    pub raw_provider_payload_echoed: bool,
    pub raw_provider_ref_echoed: bool,
    pub omitted_fields: &'static [&'static str],
}

pub trait StripeLikeFetchExecutor {
    fn execute(&self, request: StripeLikeFetchExecutorRequest) -> StripeLikeFetchExecutorResult;
}

#[derive(Debug, Default, Clone, Copy)]
pub struct NetworkDisabledStripeLikeFetchExecutor;

impl StripeLikeFetchExecutor for NetworkDisabledStripeLikeFetchExecutor {
    fn execute(&self, request: StripeLikeFetchExecutorRequest) -> StripeLikeFetchExecutorResult {
        execute_stripe_like_fetch_executor(request)
    }
}

#[derive(Debug, Clone)]
pub struct ReqwestStripeLikeFetchExecutorConfig {
    pub network_enabled: bool,
    pub runtime_secret_present: bool,
    pub connect_timeout_ms: u64,
    pub request_timeout_ms: u64,
    pub response_body_timeout_ms: u64,
    pub max_retry_attempts: u8,
}

impl Default for ReqwestStripeLikeFetchExecutorConfig {
    fn default() -> Self {
        Self {
            network_enabled: false,
            runtime_secret_present: false,
            connect_timeout_ms: 2_000,
            request_timeout_ms: 10_000,
            response_body_timeout_ms: 10_000,
            max_retry_attempts: 2,
        }
    }
}

#[derive(Debug, Clone)]
pub struct ReqwestStripeLikeFetchExecutor {
    http_client: Option<reqwest::Client>,
    config: ReqwestStripeLikeFetchExecutorConfig,
}

impl ReqwestStripeLikeFetchExecutor {
    pub fn not_configured(network_enabled: bool) -> Self {
        Self {
            http_client: None,
            config: ReqwestStripeLikeFetchExecutorConfig {
                network_enabled,
                ..ReqwestStripeLikeFetchExecutorConfig::default()
            },
        }
    }

    pub fn from_reqwest_client(
        http_client: reqwest::Client,
        config: ReqwestStripeLikeFetchExecutorConfig,
    ) -> Self {
        Self {
            http_client: Some(http_client),
            config,
        }
    }

    pub fn request_builder_readback(
        &self,
        request_plan: &StripeLikeClientRequestPlan,
    ) -> StripeLikeRequestBuilderReadback {
        stripe_like_request_builder_readback(
            request_plan,
            self.config.runtime_secret_present,
            stripe_like_http_timeout_readback_for_config(&self.config),
            stripe_like_retry_policy_readback(self.config.max_retry_attempts),
        )
    }
}

impl StripeLikeFetchExecutor for ReqwestStripeLikeFetchExecutor {
    fn execute(
        &self,
        mut request: StripeLikeFetchExecutorRequest,
    ) -> StripeLikeFetchExecutorResult {
        if !self.config.network_enabled || !request.network_enabled {
            request.network_enabled = false;
            return NetworkDisabledStripeLikeFetchExecutor.execute(request);
        }

        let mut result = execute_stripe_like_fetch_executor_with_boundary(
            request,
            "reqwest_boundary",
            "reqwest_client_available_but_network_send_not_wired",
            self.http_client.is_some(),
            self.config.runtime_secret_present,
            stripe_like_http_timeout_readback_for_config(&self.config),
            stripe_like_retry_policy_readback(self.config.max_retry_attempts),
        );

        if self.http_client.is_none() || !self.config.runtime_secret_present {
            result.status = "network_client_not_configured";
            result.http_client = "reqwest_not_configured";
            if self.http_client.is_none() {
                result.blocked_reasons.push("http_client_not_configured");
            }
            if !self.config.runtime_secret_present {
                result.blocked_reasons.push("runtime_secret_not_configured");
            }
            result.client_handoff = stripe_like_client_handoff_readback(
                &result.provider,
                result.implementation,
                result.network_call_enabled,
                self.http_client.is_some(),
                self.config.runtime_secret_present,
                &result.request_builder,
                result.provider_object_summary.is_some(),
                result.response_header_summary.header_summary_present,
                result.blocked_reasons.clone(),
            );
        }

        result
    }
}

pub fn execute_stripe_like_fetch_executor(
    request: StripeLikeFetchExecutorRequest,
) -> StripeLikeFetchExecutorResult {
    execute_stripe_like_fetch_executor_with_boundary(
        request,
        "network_disabled_fixture_parser",
        "reqwest-backed StripeLikeFetchExecutor that preserves this request/result boundary and secret-safe readback",
        false,
        false,
        stripe_like_default_http_timeout_readback(),
        stripe_like_default_retry_policy_readback(),
    )
}

fn execute_stripe_like_fetch_executor_with_boundary(
    request: StripeLikeFetchExecutorRequest,
    implementation: &'static str,
    replace_with: &'static str,
    http_client_configured: bool,
    runtime_secret_present: bool,
    timeout: StripeLikeHttpTimeoutReadback,
    retry_policy: StripeLikeRetryPolicyReadback,
) -> StripeLikeFetchExecutorResult {
    let mut blocked_reasons = Vec::new();
    if !request.request_plan.credential_source_ready {
        blocked_reasons.push("credential_source_not_ready");
    }
    if !request.request_plan.merchant_account_ref_present {
        blocked_reasons.push("merchant_account_ref_missing");
    }
    if !request.request_plan.path_ref_present {
        blocked_reasons.push("provider_object_ref_missing");
    }
    if request.request_plan.idempotency_header_required
        && !request.request_plan.idempotency_header_present
    {
        blocked_reasons.push("idempotency_safe_marker_missing");
    }
    if !request.network_enabled {
        blocked_reasons.push("network_disabled");
    } else if !http_client_configured || !runtime_secret_present {
        blocked_reasons.push("network_client_not_configured");
    }

    let response_header_summary =
        stripe_like_response_header_summary_readback(request.response_header_summary.as_ref());
    let provider_object_summary = request.fixture_response.as_ref().map(|fixture| {
        let object = fixture
            .get("data")
            .and_then(|value| value.get("object"))
            .unwrap_or(fixture);
        summarize_stripe_like_provider_object(&request.provider, object)
    });
    let fixture_response_parsed = provider_object_summary.is_some();
    let object_found = provider_object_summary
        .as_ref()
        .map(|summary| summary.provider_object_id_present);
    let status = if fixture_response_parsed {
        "fixture_parsed"
    } else if request.network_enabled && (!http_client_configured || !runtime_secret_present) {
        "network_client_not_configured"
    } else if request.network_enabled {
        "network_ready_not_executed"
    } else {
        "object_not_loaded"
    };
    let request_builder = stripe_like_request_builder_readback(
        &request.request_plan,
        runtime_secret_present,
        timeout,
        retry_policy,
    );
    let client_handoff = stripe_like_client_handoff_readback(
        &request.provider,
        implementation,
        request.network_enabled,
        http_client_configured,
        runtime_secret_present,
        &request_builder,
        fixture_response_parsed,
        response_header_summary.header_summary_present,
        blocked_reasons.clone(),
    );

    StripeLikeFetchExecutorResult {
        schema: PAYMENT_PROVIDER_STRIPE_LIKE_FETCH_EXECUTOR_SCHEMA,
        provider: request.provider,
        status,
        interface: "StripeLikeClientRequestPlan + optional fixture_response -> StripeLikeFetchExecutorResult",
        implementation,
        replace_with,
        request_plan: request.request_plan,
        network_call_enabled: request.network_enabled,
        network_call_performed: false,
        http_client: if http_client_configured {
            "reqwest_configured"
        } else {
            "not_configured"
        },
        request_builder,
        client_handoff,
        object_found,
        response_header_summary: response_header_summary.clone(),
        rate_limit_readback: response_header_summary,
        parser_summary_available: fixture_response_parsed,
        provider_object_summary,
        fixture_response_parsed,
        blocked_reasons,
        secret_safe: true,
        raw_secret_echoed: false,
        authorization_echoed: false,
        raw_idempotency_key_echoed: false,
        raw_provider_payload_echoed: false,
        raw_provider_ref_echoed: false,
        omitted_fields: &[
            "provider_api_key",
            "credential_value",
            "authorization",
            "raw_idempotency_key",
            "idempotency_key",
            "raw_provider_payload",
            "raw_response_headers",
            "response_body",
            "fixture_response",
            "stripe_response_payload",
            "stripe_request_id_raw",
            "payment_intent_id_raw",
            "charge_id_raw",
            "refund_id_raw",
            "dispute_id_raw",
        ],
    }
}

fn stripe_like_client_handoff_readback(
    provider: &str,
    implementation: &'static str,
    network_call_enabled: bool,
    http_client_configured: bool,
    runtime_secret_present: bool,
    request_builder: &StripeLikeRequestBuilderReadback,
    provider_object_summary_present: bool,
    response_header_summary_present: bool,
    blocked_reasons: Vec<&'static str>,
) -> StripeLikeClientHandoffReadback {
    let runtime_secret_ref_resolved = runtime_secret_present
        && request_builder.authorization_header_required
        && request_builder.authorization_header_present;
    let request_builder_configured = request_builder.path_ref_present
        && (!request_builder.idempotency_header_required
            || request_builder.idempotency_header_present)
        && runtime_secret_ref_resolved;
    let object_fetch_would_be_sent = network_call_enabled
        && http_client_configured
        && request_builder_configured
        && blocked_reasons.is_empty();
    let status = if object_fetch_would_be_sent {
        "object_fetch_would_be_sent_but_network_suppressed"
    } else {
        "blocked"
    };
    let source_of_truth_handoff_ready = object_fetch_would_be_sent
        || provider_object_summary_present
        || response_header_summary_present;

    StripeLikeClientHandoffReadback {
        schema: PAYMENT_PROVIDER_STRIPE_LIKE_CLIENT_HANDOFF_SCHEMA,
        status,
        implementation,
        provider: provider.to_string(),
        runtime_secret_ref_required: request_builder.authorization_header_required,
        runtime_secret_ref_resolved,
        reqwest_client_configured: http_client_configured,
        request_builder_configured,
        object_ref_present: request_builder.path_ref_present,
        object_fetch_would_be_sent,
        object_fetch_blocked_reasons: blocked_reasons,
        retry_policy: request_builder.retry_policy.clone(),
        source_of_truth_handoff: StripeLikeSourceOfTruthHandoffReadback {
            adapter: "stripe_api_source_of_truth.fetch_adapter",
            fetch_adapter_schema: PAYMENT_PROVIDER_STRIPE_API_FETCH_ADAPTER_SCHEMA,
            required_provider_object_summary_schema:
                PAYMENT_PROVIDER_STRIPE_LIKE_SOURCE_OF_TRUTH_SUMMARY_SCHEMA,
            provider_object_summary_present,
            response_header_summary_present,
            source_of_truth_handoff_ready,
            reconciliation_handoff:
                PAYMENT_PROVIDER_STRIPE_LIKE_RESPONSE_OBJECT_RECONCILIATION_SCHEMA,
            network_call_performed: false,
            raw_object_ref_echoed: false,
            raw_provider_payload_echoed: false,
            raw_headers_echoed: false,
            authorization_echoed: false,
            provider_secret_echoed: false,
        },
        network_call_enabled,
        network_call_performed: false,
        secret_safe: true,
        raw_secret_echoed: false,
        authorization_echoed: false,
        raw_provider_ref_echoed: false,
        raw_headers_echoed: false,
        raw_body_echoed: false,
        omitted_fields: &[
            "provider_api_key",
            "credential_value",
            "authorization",
            "raw_object_ref",
            "raw_provider_ref",
            "raw_request_headers",
            "raw_response_headers",
            "raw_request_body",
            "raw_response_body",
            "provider_object_source_of_truth",
            "stripe_response_payload",
        ],
    }
}

fn stripe_like_response_header_summary_readback(
    input: Option<&StripeLikeResponseHeaderSummaryInput>,
) -> StripeLikeRateLimitReadback {
    let Some(input) = input else {
        return StripeLikeRateLimitReadback {
            retry_after_present: false,
            retry_after_seconds: None,
            stripe_request_id_present: false,
            stripe_request_id_hash: None,
            rate_limit_category: None,
            should_retry: false,
            backoff_reason: "none",
            header_summary_present: false,
            header_summary_source: "not_supplied",
            raw_headers_echoed: false,
            authorization_echoed: false,
            secret_safe: true,
        };
    };

    let rate_limit_category = input
        .rate_limit_category
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .and_then(stripe_like_allowed_rate_limit_category)
        .map(ToString::to_string);
    let retry_after_present = input.retry_after_present || input.retry_after_seconds.is_some();
    let stripe_request_id_hash = input
        .stripe_request_id_hash
        .as_deref()
        .map(str::trim)
        .filter(|value| is_sha256_hex(value))
        .map(ToString::to_string);
    let stripe_request_id_present =
        input.stripe_request_id_present || stripe_request_id_hash.is_some();
    let status_retryable = matches!(input.http_status, Some(429) | Some(500..=599));
    let rate_limited = matches!(input.http_status, Some(429)) || rate_limit_category.is_some();
    let should_retry = status_retryable || retry_after_present || rate_limited;
    let backoff_reason = if retry_after_present {
        "retry_after_header"
    } else if rate_limited {
        "provider_rate_limit"
    } else if matches!(input.http_status, Some(500..=599)) {
        "provider_server_error"
    } else {
        "none"
    };

    StripeLikeRateLimitReadback {
        retry_after_present,
        retry_after_seconds: input.retry_after_seconds,
        stripe_request_id_present,
        stripe_request_id_hash,
        rate_limit_category,
        should_retry,
        backoff_reason,
        header_summary_present: true,
        header_summary_source: "fixture_safe_header_metadata_or_synthetic_response_summary",
        raw_headers_echoed: false,
        authorization_echoed: false,
        secret_safe: true,
    }
}

fn stripe_like_allowed_rate_limit_category(value: &str) -> Option<&'static str> {
    match value {
        "global" => Some("global"),
        "endpoint" => Some("endpoint"),
        "concurrency" => Some("concurrency"),
        "resource_specific" => Some("resource_specific"),
        "lock_timeout" => Some("lock_timeout"),
        "unknown" => Some("unknown"),
        _ => None,
    }
}

fn is_sha256_hex(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn stripe_like_default_http_timeout_readback() -> StripeLikeHttpTimeoutReadback {
    stripe_like_http_timeout_readback_for_config(&ReqwestStripeLikeFetchExecutorConfig::default())
}

fn stripe_like_http_timeout_readback_for_config(
    config: &ReqwestStripeLikeFetchExecutorConfig,
) -> StripeLikeHttpTimeoutReadback {
    StripeLikeHttpTimeoutReadback {
        connect_timeout_ms: config.connect_timeout_ms,
        request_timeout_ms: config.request_timeout_ms,
        response_body_timeout_ms: config.response_body_timeout_ms,
    }
}

fn stripe_like_default_retry_policy_readback() -> StripeLikeRetryPolicyReadback {
    stripe_like_retry_policy_readback(
        ReqwestStripeLikeFetchExecutorConfig::default().max_retry_attempts,
    )
}

fn stripe_like_retry_policy_readback(max_attempts: u8) -> StripeLikeRetryPolicyReadback {
    StripeLikeRetryPolicyReadback {
        max_attempts,
        retry_on_timeout: true,
        retry_on_429: true,
        retry_on_5xx: true,
        backoff: "bounded_exponential_jitter_summary_only",
        idempotency_required_for_post_retry: true,
    }
}

fn stripe_like_request_builder_readback(
    request_plan: &StripeLikeClientRequestPlan,
    runtime_secret_present: bool,
    timeout: StripeLikeHttpTimeoutReadback,
    retry_policy: StripeLikeRetryPolicyReadback,
) -> StripeLikeRequestBuilderReadback {
    StripeLikeRequestBuilderReadback {
        method: request_plan.method,
        path_template: request_plan.path_template,
        path_ref_source: request_plan.path_ref_source,
        path_ref_present: request_plan.path_ref_present,
        authorization_header_required: request_plan.authorization_header_required,
        authorization_header_present: request_plan.authorization_header_required
            && runtime_secret_present
            && request_plan.credential_source_ready,
        authorization_header_value_echoed: false,
        idempotency_header_required: request_plan.idempotency_header_required,
        idempotency_header_present: request_plan.idempotency_header_present,
        idempotency_header_value_echoed: false,
        body_fields: request_plan.body_fields.clone(),
        timeout,
        retry_policy,
        raw_secret_echoed: false,
        raw_provider_ref_echoed: false,
        raw_body_echoed: false,
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct StripeApiFetchRequest {
    pub object_type: StripeApiObjectType,
    pub object_ref_source: &'static str,
    pub object_ref_present: bool,
    pub credential_secret_ref_required: bool,
    pub merchant_account_ref_required: bool,
    pub expand: &'static [&'static str],
    pub raw_object_ref_echoed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct StripeApiFetchResult {
    pub object_type: StripeApiObjectType,
    pub status: &'static str,
    pub blocked_reason: Option<&'static str>,
    pub network_call_performed: bool,
    pub http_client: &'static str,
    pub object_ref_present: bool,
    pub object_found: Option<bool>,
    pub secret_safe: bool,
    pub authorization_echoed: bool,
    pub provider_secret_echoed: bool,
    pub raw_object_payload_echoed: bool,
    pub raw_object_ref_echoed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct StripeApiFetchAdapterReadback {
    pub schema: &'static str,
    pub adapter: &'static str,
    pub interface: &'static str,
    pub implementation: &'static str,
    pub provider_supported: bool,
    pub credential_source_ready: bool,
    pub object_refs_ready: bool,
    pub adapter_ready_for_network_client: bool,
    pub network_call_enabled: bool,
    pub network_call_performed: bool,
    pub requests: Vec<StripeApiFetchRequest>,
    pub results: Vec<StripeApiFetchResult>,
    pub replace_with: &'static str,
    pub omitted_fields: &'static [&'static str],
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct StripeLikeProviderObjectSummary {
    pub schema: &'static str,
    pub provider: String,
    pub provider_object_type: Option<StripeApiObjectType>,
    pub provider_object_type_raw: Option<String>,
    pub provider_object_id_present: bool,
    pub provider_object_id_hash: Option<String>,
    pub status: Option<String>,
    pub amount: Option<String>,
    pub currency: Option<String>,
    pub local_refs: StripeLikeProviderLocalRefsSummary,
    pub captured: StripeLikeProviderStateReadback,
    pub refunded: StripeLikeProviderStateReadback,
    pub disputed: StripeLikeProviderStateReadback,
    pub unsupported_field_reasons: Vec<&'static str>,
    pub missing_field_reasons: Vec<&'static str>,
    pub sensitive_field_presence_detected: bool,
    pub secret_safe: bool,
    pub raw_provider_payload_echoed: bool,
    pub raw_customer_echoed: bool,
    pub raw_email_echoed: bool,
    pub raw_payment_method_echoed: bool,
    pub raw_receipt_url_echoed: bool,
    pub raw_billing_details_echoed: bool,
    pub omitted_fields: &'static [&'static str],
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct StripeLikeProviderLocalRefsSummary {
    pub metadata_present: bool,
    pub local_ref_count: usize,
    pub refs: Vec<StripeLikeProviderLocalRefReadback>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct StripeLikeProviderLocalRefReadback {
    pub name: &'static str,
    pub present: bool,
    pub value_hash: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct StripeLikeProviderStateReadback {
    pub present: bool,
    pub status: &'static str,
    pub amount: Option<String>,
    pub reason: Option<&'static str>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PaymentProviderStripeApiObjectRefRequirements {
    pub event_id_required: bool,
    pub object_id_required: bool,
    pub merchant_account_ref_required: bool,
    pub credential_secret_ref_required: bool,
    pub webhook_secret_ref_required_for_callback: bool,
    pub local_intent_or_capture_ref_required_for_accounting: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PaymentProviderStripeApiObjectRefReadback {
    pub event_type: Option<PaymentProviderEventType>,
    pub provider_event_id_present: bool,
    pub provider_object_id_present: bool,
    pub local_payment_intent_ref_present: bool,
    pub local_payment_capture_ref_present: bool,
    pub local_refund_ref_present: bool,
    pub api_object_ref_mapping: &'static str,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PaymentProviderSignatureFormatSupport {
    pub header_names: &'static [&'static str],
    pub formats: &'static [&'static str],
    pub timestamp_tolerance_seconds: Option<u64>,
    pub raw_header_echoed: bool,
    pub raw_signature_echoed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PaymentProviderCredentialLifecycleReadback {
    pub status: &'static str,
    pub enabled: bool,
    pub credential_present: bool,
    pub fingerprint_present: bool,
    pub fingerprint_prefix: Option<String>,
    pub disabled_reason: Option<&'static str>,
    pub refusal_reason: Option<&'static str>,
    pub secret_returned: bool,
    pub credential_value_echoed: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PaymentProviderRefs {
    pub order_id: Option<String>,
    pub payment_intent_id: Option<String>,
    pub payment_capture_id: Option<String>,
    pub refund_id: Option<String>,
    pub credit_grant_id: Option<String>,
    pub ledger_entry_id: Option<String>,
    pub reversal_ledger_entry_id: Option<String>,
    pub invoice_id: Option<String>,
    pub audit_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PaymentProviderRuntimeReadback {
    pub schema: &'static str,
    pub mode: &'static str,
    pub provider: String,
    pub event_type: PaymentProviderEventType,
    pub external_event_id_hash: String,
    pub amount: String,
    pub currency: String,
    pub action_result: &'static str,
    pub signature_verification: &'static str,
    pub merchant_connected: bool,
    pub production_payment_evidence: bool,
    pub secret_safe: bool,
    pub raw_webhook_body_echoed: bool,
    pub raw_idempotency_key_echoed: bool,
    pub authorization_echoed: bool,
    pub provider_secret_echoed: bool,
    pub db_url_echoed: bool,
    pub idempotency_key_hash: Option<String>,
    pub refs: PaymentProviderRefs,
    pub omitted_fields: &'static [&'static str],
    pub notes: &'static [&'static str],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PaymentProviderExecutorAction {
    Callback,
    Capture,
    Refund,
    ChargebackAck,
}

impl PaymentProviderExecutorAction {
    fn result_label(self) -> &'static str {
        match self {
            Self::Callback => "callback_normalized",
            Self::Capture => "capture_planned",
            Self::Refund => "refund_planned",
            Self::ChargebackAck => "chargeback_ack_planned",
        }
    }

    fn required_refs(self) -> &'static [&'static str] {
        match self {
            Self::Callback => &["provider_event_ref", "provider_object_ref", "idempotency"],
            Self::Capture => &["provider_object_ref", "idempotency"],
            Self::Refund => &["provider_object_ref", "payment_capture_id", "idempotency"],
            Self::ChargebackAck => &["provider_event_or_dispute_ref", "idempotency"],
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PaymentProviderSafeRef {
    pub present: bool,
    pub hash: Option<String>,
    pub fingerprint: Option<String>,
}

impl PaymentProviderSafeRef {
    pub fn presence() -> Self {
        Self {
            present: true,
            hash: None,
            fingerprint: None,
        }
    }

    pub fn hashed(hash: impl Into<String>) -> Self {
        Self {
            present: true,
            hash: Some(hash.into()),
            fingerprint: None,
        }
    }

    pub fn fingerprint(fingerprint: impl Into<String>) -> Self {
        Self {
            present: true,
            hash: None,
            fingerprint: Some(fingerprint.into()),
        }
    }

    fn has_safe_marker(&self) -> bool {
        self.present || self.hash.is_some() || self.fingerprint.is_some()
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PaymentProviderExecutorProviderRefs {
    pub provider_event_ref: PaymentProviderSafeRef,
    pub provider_object_ref: PaymentProviderSafeRef,
    pub dispute_ref: PaymentProviderSafeRef,
    pub charge_ref: PaymentProviderSafeRef,
    pub refund_ref: PaymentProviderSafeRef,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PaymentProviderExecutorIdempotency {
    pub present: bool,
    pub key_hash: Option<String>,
    pub fingerprint: Option<String>,
}

impl PaymentProviderExecutorIdempotency {
    pub fn hashed(hash: impl Into<String>) -> Self {
        Self {
            present: true,
            key_hash: Some(hash.into()),
            fingerprint: None,
        }
    }

    pub fn fingerprint(fingerprint: impl Into<String>) -> Self {
        Self {
            present: true,
            key_hash: None,
            fingerprint: Some(fingerprint.into()),
        }
    }

    fn has_safe_marker(&self) -> bool {
        self.present || self.key_hash.is_some() || self.fingerprint.is_some()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PaymentProviderExecutorGateInput {
    pub adapter_enabled: bool,
    pub merchant_connected: bool,
    pub credential_present: bool,
    pub credential_fingerprint_present: bool,
    pub signature_verified: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PaymentProviderExecutorRequest {
    pub provider: String,
    pub action: PaymentProviderExecutorAction,
    pub amount: String,
    pub currency: String,
    pub reason: String,
    pub idempotency: PaymentProviderExecutorIdempotency,
    #[serde(default)]
    pub provider_refs: PaymentProviderExecutorProviderRefs,
    #[serde(default)]
    pub local_refs: PaymentProviderRefs,
    pub gate: PaymentProviderExecutorGateInput,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PaymentProviderExecutorGateReadback {
    pub status: &'static str,
    pub adapter_enabled: bool,
    pub merchant_connected: bool,
    pub credential_present: bool,
    pub credential_fingerprint_present: bool,
    pub signature_verified: bool,
    pub network_call_enabled: bool,
    pub production_payment_evidence: bool,
    pub refusal_reasons: Vec<&'static str>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PaymentProviderExecutorIdempotencyReadback {
    pub status: &'static str,
    pub key_hash_present: bool,
    pub fingerprint_present: bool,
    pub replay_safe: bool,
    pub conflict_refusal_reason: Option<&'static str>,
    pub raw_idempotency_key_echoed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PaymentProviderExecutorStatusMappingReadback {
    pub provider_status_source: &'static str,
    pub normalized_status: &'static str,
    pub terminal: bool,
    pub local_write_allowed: bool,
    pub refusal_code: Option<&'static str>,
    pub refusal_reasons: Vec<&'static str>,
    pub callback_readback_available: bool,
    pub capture_readback_available: bool,
    pub refund_readback_available: bool,
    pub chargeback_readback_available: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PaymentProviderExecutorLedgerHandoffReadback {
    pub ledger_write_performed: bool,
    pub ledger_write_allowed_by_executor: bool,
    pub ledger_handoff_required: bool,
    pub reversal_handoff_required: bool,
    pub handoff_target: &'static str,
    pub handoff_status: &'static str,
    pub local_apply_requires_reconciliation_match: bool,
    pub direct_merchant_success_forged: bool,
    pub invoice_metadata_echoed: bool,
    pub raw_invoice_metadata_echoed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PaymentProviderExecutorResult {
    pub schema: &'static str,
    pub provider: String,
    pub action: PaymentProviderExecutorAction,
    pub status: &'static str,
    pub action_result: &'static str,
    pub required_refs: &'static [&'static str],
    pub amount: String,
    pub currency: String,
    pub reason_present: bool,
    pub idempotency_key_hash_present: bool,
    pub idempotency_fingerprint: Option<String>,
    pub idempotency_readback: PaymentProviderExecutorIdempotencyReadback,
    pub status_mapping: PaymentProviderExecutorStatusMappingReadback,
    pub ledger_handoff: PaymentProviderExecutorLedgerHandoffReadback,
    pub provider_refs: PaymentProviderExecutorProviderRefs,
    pub local_refs: PaymentProviderRefs,
    pub gate_readback: PaymentProviderExecutorGateReadback,
    pub secret_safe: bool,
    pub normalized_executor_result_readback: bool,
    pub raw_provider_payload_echoed: bool,
    pub raw_webhook_body_echoed: bool,
    pub raw_idempotency_key_echoed: bool,
    pub authorization_echoed: bool,
    pub provider_secret_echoed: bool,
    pub provider_ref_raw_echoed: bool,
    pub raw_invoice_metadata_echoed: bool,
    pub validation_errors: Vec<&'static str>,
    pub omitted_fields: &'static [&'static str],
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct StripeLikeResponseObjectReconciliation {
    pub schema: &'static str,
    pub status: &'static str,
    pub action: PaymentProviderExecutorAction,
    pub source_of_truth_candidate: &'static str,
    pub matched: bool,
    pub provider: String,
    pub source_object_presence: StripeLikeSourceObjectPresenceReadback,
    pub provider_object_summary_present: bool,
    pub response_header_summary_present: bool,
    pub provider_object_type_matches: Option<bool>,
    pub provider_status_matches: Option<bool>,
    pub amount_matches: Option<bool>,
    pub currency_matches: Option<bool>,
    pub local_refs_match: Option<bool>,
    pub idempotency_key_hash_present: bool,
    pub idempotency_fingerprint_present: bool,
    pub idempotency_safe_marker_present: bool,
    pub expected_provider_object_types: &'static [&'static str],
    pub expected_provider_statuses: &'static [&'static str],
    pub expected_local_refs: &'static [&'static str],
    pub mismatch_reasons: Vec<&'static str>,
    pub blocked_reasons: Vec<&'static str>,
    pub retry_recommended: bool,
    pub retry_reason: &'static str,
    pub safe_next_action: &'static str,
    pub network_call_performed: bool,
    pub secret_safe: bool,
    pub raw_provider_payload_echoed: bool,
    pub raw_headers_echoed: bool,
    pub raw_provider_ref_echoed: bool,
    pub authorization_echoed: bool,
    pub provider_secret_echoed: bool,
    pub omitted_fields: &'static [&'static str],
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct StripeLikeSourceObjectPresenceReadback {
    pub provider_object_summary_present: bool,
    pub provider_object_id_present: bool,
    pub event_object_present: bool,
    pub payment_intent_object_present: bool,
    pub charge_object_present: bool,
    pub refund_object_present: bool,
    pub dispute_object_present: bool,
    pub parser_error_present: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PaymentProviderHeaderValue {
    pub name: String,
    pub value: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct StripeLikeSandboxAdapterInput {
    pub provider: String,
    pub headers: Vec<PaymentProviderHeaderValue>,
    pub payload: serde_json::Value,
    pub payload_sha256: Option<String>,
    pub signature_verification: Option<PaymentProviderSignatureVerificationReadback>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PaymentProviderSignatureParseReadback {
    pub header_present: bool,
    pub header_name: Option<String>,
    pub format: &'static str,
    pub timestamp_present: bool,
    pub timestamp: Option<i64>,
    pub signature_present: bool,
    pub signature_count: usize,
    pub selected_scheme: Option<String>,
    pub unsupported_reason: Option<&'static str>,
    pub raw_header_echoed: bool,
    pub raw_signature_echoed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PaymentProviderSignatureVerificationReadback {
    pub status: &'static str,
    pub format: &'static str,
    pub timestamp_present: bool,
    pub timestamp_tolerance_seconds: Option<u64>,
    pub timestamp_age_seconds: Option<i64>,
    pub replay_window_ok: bool,
    pub signature_present: bool,
    pub signature_match: bool,
    pub signed_payload_basis: &'static str,
    pub signed_payload_sha256: Option<String>,
    pub payload_sha256: String,
    pub mismatch_reason: Option<&'static str>,
    pub raw_header_echoed: bool,
    pub raw_signature_echoed: bool,
    pub raw_payload_echoed: bool,
    pub secret_echoed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PaymentProviderEventMappingReadback {
    pub provider_event_type: Option<String>,
    pub normalized_event_type: Option<PaymentProviderEventType>,
    pub supported: bool,
    pub unsupported_reason: Option<&'static str>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PaymentProviderNormalizedEvent {
    pub event_type: PaymentProviderEventType,
    pub external_event_id: String,
    pub amount: String,
    pub currency: String,
    pub idempotency_key: Option<String>,
    pub tenant_id: Option<String>,
    pub order_id: Option<String>,
    pub project_id: Option<String>,
    pub wallet_id: Option<String>,
    pub payment_intent_id: Option<String>,
    pub payment_capture_id: Option<String>,
    pub refund_id: Option<String>,
    pub credit_grant_id: Option<String>,
    pub ledger_entry_id: Option<String>,
    pub reversal_ledger_entry_id: Option<String>,
    pub invoice_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PaymentProviderEventReadback {
    pub provider_event_id_present: bool,
    pub provider_event_id_hash: Option<String>,
    pub provider_event_type_present: bool,
    pub provider_event_type: Option<String>,
    pub provider_object_id_present: bool,
    pub provider_object_id_hash: Option<String>,
    pub amount_present: bool,
    pub currency_present: bool,
    pub metadata_present: bool,
    pub tenant_id_present: bool,
    pub local_ref_count: usize,
    pub schema_valid: bool,
    pub refusal_reason: Option<&'static str>,
    pub raw_provider_payload_echoed: bool,
    pub raw_idempotency_key_echoed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct StripeLikeSandboxAdapterReadback {
    pub schema: &'static str,
    pub adapter: &'static str,
    pub provider: String,
    pub provider_supported: bool,
    pub signature_format_support: PaymentProviderSignatureFormatSupport,
    pub signature_parse: PaymentProviderSignatureParseReadback,
    pub signature_verification_readback: Option<PaymentProviderSignatureVerificationReadback>,
    pub event_mapping: PaymentProviderEventMappingReadback,
    pub provider_event_readback: PaymentProviderEventReadback,
    pub normalized_event: Option<PaymentProviderNormalizedEvent>,
    pub unsupported_reason: Option<&'static str>,
    pub raw_webhook_body_echoed: bool,
    pub raw_provider_payload_echoed: bool,
    pub raw_idempotency_key_echoed: bool,
    pub authorization_echoed: bool,
    pub provider_secret_echoed: bool,
    pub db_url_echoed: bool,
    pub secret_safe: bool,
    pub omitted_fields: &'static [&'static str],
}

pub fn plan_payment_provider_adapter_config_status(
    input: PaymentProviderAdapterConfigInput,
) -> PaymentProviderAdapterConfigStatus {
    let provider = input
        .provider
        .clone()
        .unwrap_or_else(|| "unconfigured".to_string());
    let credential_refusal_reason = payment_provider_credential_refusal_reason(&input);
    let credential_enabled = input.adapter_enabled && input.credential_present;
    let credential_status = if !input.adapter_enabled || !input.credential_present {
        "disabled"
    } else {
        "enabled"
    };
    let credential_lifecycle = PaymentProviderCredentialLifecycleReadback {
        status: credential_status,
        enabled: credential_enabled,
        credential_present: input.credential_present,
        fingerprint_present: input.credential_fingerprint_prefix.is_some(),
        fingerprint_prefix: input.credential_fingerprint_prefix.clone(),
        disabled_reason: if credential_enabled {
            None
        } else {
            credential_refusal_reason
        },
        refusal_reason: credential_refusal_reason,
        secret_returned: false,
        credential_value_echoed: false,
    };
    let status = if !input.adapter_enabled {
        "disabled"
    } else if input.merchant_account_present
        && input.credential_present
        && input.webhook_secret_present
    {
        "ready-for-sandbox"
    } else {
        "config-needed"
    };
    let signature_verifier_status = if !input.adapter_enabled {
        "disabled"
    } else if input.webhook_secret_present {
        "configured-not-validated"
    } else {
        "config-needed"
    };
    let next_step = match status {
        "disabled" => "enable a sandbox payment provider adapter in control-plane configuration",
        "ready-for-sandbox" => {
            "run a sandbox callback/capture/refund/chargeback fixture before production validation"
        }
        _ if !input.merchant_account_present => "configure merchant/account identifier",
        _ if !input.credential_present => "configure provider API credential presence",
        _ => "configure webhook signing secret and signature verifier",
    };

    PaymentProviderAdapterConfigStatus {
        schema: PAYMENT_PROVIDER_ADAPTER_CONFIG_SCHEMA,
        provider: provider.clone(),
        status,
        adapter_enabled: input.adapter_enabled,
        merchant_account_present: input.merchant_account_present,
        credential_present: input.credential_present,
        credential_status,
        credential_fingerprint_present: credential_lifecycle.fingerprint_present,
        credential_fingerprint_prefix: credential_lifecycle.fingerprint_prefix.clone(),
        credential_lifecycle,
        signature_verifier_status,
        supported_events: vec![
            PaymentProviderEventType::Callback,
            PaymentProviderEventType::Capture,
            PaymentProviderEventType::Refund,
            PaymentProviderEventType::Chargeback,
        ],
        adapter: STRIPE_LIKE_SANDBOX_ADAPTER.to_string(),
        signature_format_support: stripe_like_signature_format_support(),
        stripe_api_source_of_truth: plan_payment_provider_stripe_api_source_of_truth(
            PaymentProviderStripeApiSourceOfTruthInput {
                provider,
                credential_source: "config_status".to_string(),
                credential_source_ready: status == "ready-for-sandbox",
                event_type: None,
                provider_event_id_present: false,
                provider_object_id_present: false,
                local_payment_intent_ref_present: false,
                local_payment_capture_ref_present: false,
                local_refund_ref_present: false,
            },
        ),
        next_step,
        merchant_connected: status == "ready-for-sandbox",
        production_payment_evidence: false,
        secret_safe: true,
        credential_value_echoed: false,
        provider_secret_echoed: false,
        authorization_echoed: false,
        raw_webhook_body_echoed: false,
        db_url_echoed: false,
        omitted_fields: &[
            "provider_secret",
            "provider_api_key",
            "credential_value",
            "credential_fingerprint_full",
            "webhook_signing_secret",
            "authorization",
            "raw_webhook_body",
            "provider_payload",
            "database_url",
        ],
    }
}

pub fn payment_provider_credential_refusal_reason(
    input: &PaymentProviderAdapterConfigInput,
) -> Option<&'static str> {
    if !input.adapter_enabled {
        Some("provider_disabled")
    } else if !input.credential_present {
        Some("credential_missing")
    } else if !input.merchant_account_present {
        Some("merchant_account_missing")
    } else if !input.webhook_secret_present {
        Some("webhook_secret_missing")
    } else {
        None
    }
}

pub fn plan_payment_provider_stripe_api_source_of_truth(
    input: PaymentProviderStripeApiSourceOfTruthInput,
) -> PaymentProviderStripeApiSourceOfTruthReadback {
    let provider_supported =
        input.provider == "stripe_like" || input.provider == STRIPE_LIKE_SANDBOX_ADAPTER;
    let source_of_truth_blocked_reason = if !provider_supported {
        Some("provider_not_supported_by_stripe_api_source_of_truth_adapter")
    } else if !input.credential_source_ready {
        Some("credential_source_not_ready")
    } else {
        Some("stripe_network_client_not_enabled")
    };
    let source_of_truth_status = if !provider_supported {
        "unsupported_provider"
    } else if !input.credential_source_ready {
        "credential_source_not_ready"
    } else {
        "ready_for_network_client_but_disabled"
    };
    let api_object_ref_mapping = match input.event_type {
        Some(PaymentProviderEventType::Callback) => {
            "stripe.event.id -> payment_events.external_event_id_hash; stripe.data.object.id -> provider_callback_object_ref"
        }
        Some(PaymentProviderEventType::Capture) => {
            "stripe.payment_intent|charge.id -> local payment_intent/payment_capture refs before credit accounting"
        }
        Some(PaymentProviderEventType::Refund) => {
            "stripe.refund|charge.id -> local refund/capture refs before reversal accounting"
        }
        Some(PaymentProviderEventType::Chargeback) => {
            "stripe.dispute|charge.id -> local chargeback/refund/capture refs before reversal accounting"
        }
        None => {
            "stripe.event.id and stripe.data.object.id are required before selecting a provider API object read model"
        }
    };
    let object_ref_readback = PaymentProviderStripeApiObjectRefReadback {
        event_type: input.event_type,
        provider_event_id_present: input.provider_event_id_present,
        provider_object_id_present: input.provider_object_id_present,
        local_payment_intent_ref_present: input.local_payment_intent_ref_present,
        local_payment_capture_ref_present: input.local_payment_capture_ref_present,
        local_refund_ref_present: input.local_refund_ref_present,
        api_object_ref_mapping,
    };
    let fetch_adapter = plan_stripe_api_fetch_adapter_readback(
        provider_supported,
        input.credential_source_ready,
        &object_ref_readback,
    );

    PaymentProviderStripeApiSourceOfTruthReadback {
        schema: PAYMENT_PROVIDER_STRIPE_API_SOURCE_OF_TRUTH_SCHEMA,
        adapter: "stripe_api_source_of_truth",
        provider: input.provider,
        api_read_model: "stripe_api_object_fetch_plan_v1",
        source_of_truth_status,
        source_of_truth_blocked_reason,
        network_call_enabled: false,
        secret_ref_required: true,
        credential_source: input.credential_source,
        credential_source_ready: input.credential_source_ready,
        object_ref_requirements: PaymentProviderStripeApiObjectRefRequirements {
            event_id_required: true,
            object_id_required: true,
            merchant_account_ref_required: true,
            credential_secret_ref_required: true,
            webhook_secret_ref_required_for_callback: true,
            local_intent_or_capture_ref_required_for_accounting: true,
        },
        object_ref_readback,
        fetch_adapter,
        capture_source_selection: "webhook-normalized capture is local-only until Stripe payment_intent/charge fetch is enabled",
        refund_source_selection: "webhook-normalized refund is local-only until Stripe refund/charge fetch is enabled",
        chargeback_source_selection: "webhook-normalized chargeback is local-only until Stripe dispute/charge fetch is enabled",
        callback_source_selection: "webhook signature is verified locally; Stripe event retrieval is planned but network disabled",
        sandbox_local_only: true,
        production_payment_evidence: false,
        secret_safe: true,
        authorization_echoed: false,
        provider_secret_echoed: false,
        raw_provider_payload_echoed: false,
        raw_webhook_body_echoed: false,
        omitted_fields: &[
            "provider_api_key",
            "credential_value",
            "webhook_signing_secret",
            "authorization",
            "stripe_event_payload",
            "stripe_object_payload",
            "raw_webhook_body",
            "database_url",
        ],
    }
}

pub fn plan_stripe_api_fetch_adapter_readback(
    provider_supported: bool,
    credential_source_ready: bool,
    object_ref_readback: &PaymentProviderStripeApiObjectRefReadback,
) -> StripeApiFetchAdapterReadback {
    let requests = stripe_api_fetch_requests_for_readback(object_ref_readback);
    let object_refs_ready =
        !requests.is_empty() && requests.iter().all(|request| request.object_ref_present);
    let adapter_ready_for_network_client =
        provider_supported && credential_source_ready && object_refs_ready;
    let results = requests
        .iter()
        .map(|request| {
            let blocked_reason = if !provider_supported {
                Some("unsupported_provider")
            } else if !credential_source_ready {
                Some("credential_source_not_ready")
            } else if !request.object_ref_present {
                Some("stripe_object_ref_missing")
            } else {
                Some("stripe_network_client_not_enabled")
            };
            StripeApiFetchResult {
                object_type: request.object_type,
                status: if adapter_ready_for_network_client {
                    "network_disabled_ready"
                } else {
                    "blocked"
                },
                blocked_reason,
                network_call_performed: false,
                http_client: "network_disabled",
                object_ref_present: request.object_ref_present,
                object_found: None,
                secret_safe: true,
                authorization_echoed: false,
                provider_secret_echoed: false,
                raw_object_payload_echoed: false,
                raw_object_ref_echoed: false,
            }
        })
        .collect();

    StripeApiFetchAdapterReadback {
        schema: PAYMENT_PROVIDER_STRIPE_API_FETCH_ADAPTER_SCHEMA,
        adapter: "stripe_api_fetch",
        interface: "StripeApiFetchRequest -> StripeApiFetchResult",
        implementation: "network_disabled",
        provider_supported,
        credential_source_ready,
        object_refs_ready,
        adapter_ready_for_network_client,
        network_call_enabled: false,
        network_call_performed: false,
        requests,
        results,
        replace_with: "reqwest-backed StripeApiFetchClient using operator secret refs, without changing webhook executor contract",
        omitted_fields: &[
            "provider_api_key",
            "credential_value",
            "authorization",
            "stripe_event_payload",
            "stripe_object_payload",
            "raw_object_ref",
            "database_url",
        ],
    }
}

pub fn plan_stripe_like_client_request(request: StripeLikeClientRequest) -> StripeLikeClientResult {
    let provider_supported =
        request.provider == "stripe_like" || request.provider == STRIPE_LIKE_SANDBOX_ADAPTER;
    let mut validation_errors = Vec::new();
    if request.provider.trim().is_empty() {
        validation_errors.push("provider_missing");
    }
    if request.operation.idempotency_header_required() || request.idempotency.has_safe_marker() {
        validate_executor_idempotency(&request.idempotency, &mut validation_errors);
    }
    validate_provider_ref(
        "provider_event_ref",
        &request.provider_refs.provider_event_ref,
        &mut validation_errors,
    );
    validate_provider_ref(
        "provider_object_ref",
        &request.provider_refs.provider_object_ref,
        &mut validation_errors,
    );
    validate_provider_ref(
        "dispute_ref",
        &request.provider_refs.dispute_ref,
        &mut validation_errors,
    );
    validate_provider_ref(
        "charge_ref",
        &request.provider_refs.charge_ref,
        &mut validation_errors,
    );
    validate_provider_ref(
        "refund_ref",
        &request.provider_refs.refund_ref,
        &mut validation_errors,
    );
    validate_stripe_like_client_operation(&request, &mut validation_errors);

    let (path_ref_source, path_ref_present) = stripe_like_client_path_ref(&request);
    let body_fields = stripe_like_client_body_fields(&request);
    let idempotency_header_required = request.operation.idempotency_header_required();
    let idempotency_header_present =
        idempotency_header_required && request.idempotency.has_safe_marker();
    let credential_source_required = true;
    let authorization_header_required = true;
    let merchant_account_ref_required = true;

    let mut blocked_reasons = Vec::new();
    if !provider_supported {
        blocked_reasons.push("unsupported_provider");
    }
    if !request.credential_source_ready {
        blocked_reasons.push("credential_source_not_ready");
    }
    if !request.merchant_account_ref_present {
        blocked_reasons.push("merchant_account_ref_missing");
    }
    if !path_ref_present {
        blocked_reasons.push("provider_object_ref_missing");
    }
    if idempotency_header_required && !idempotency_header_present {
        blocked_reasons.push("idempotency_safe_marker_missing");
    }

    let ready_for_executor =
        provider_supported && validation_errors.is_empty() && blocked_reasons.is_empty();

    StripeLikeClientResult {
        schema: PAYMENT_PROVIDER_STRIPE_LIKE_CLIENT_PLAN_SCHEMA,
        provider: request.provider,
        status: if ready_for_executor {
            "network_disabled_ready"
        } else {
            "blocked"
        },
        request: StripeLikeClientRequestPlan {
            operation: request.operation,
            method: request.operation.http_method(),
            path_template: request.operation.path_template(),
            path_ref_source,
            path_ref_present,
            body_fields,
            idempotency_header_required,
            idempotency_header_present,
            idempotency_header_value_echoed: false,
            credential_source_required,
            credential_source_ready: request.credential_source_ready,
            authorization_header_required,
            authorization_header_value_echoed: false,
            merchant_account_ref_required,
            merchant_account_ref_present: request.merchant_account_ref_present,
            timeout: stripe_like_default_http_timeout_readback(),
            retry_policy: stripe_like_default_retry_policy_readback(),
            raw_provider_payload_echoed: false,
        },
        network_call_performed: false,
        http_client: "request_plan_only",
        object_found: None,
        credential_source_required,
        credential_source: request.credential_source,
        required_refs: request.operation.required_refs(),
        validation_errors,
        blocked_reasons,
        secret_safe: true,
        raw_secret_echoed: false,
        authorization_echoed: false,
        raw_idempotency_key_echoed: false,
        raw_provider_payload_echoed: false,
        raw_provider_ref_echoed: false,
        omitted_fields: &[
            "provider_api_key",
            "credential_value",
            "authorization",
            "raw_idempotency_key",
            "idempotency_key",
            "raw_provider_payload",
            "stripe_response_payload",
            "payment_intent_id_raw",
            "charge_id_raw",
            "refund_id_raw",
            "dispute_id_raw",
            "database_url",
        ],
    }
}

fn validate_stripe_like_client_operation(
    request: &StripeLikeClientRequest,
    validation_errors: &mut Vec<&'static str>,
) {
    match request.operation {
        StripeLikeClientOperation::RetrievePaymentIntent
        | StripeLikeClientOperation::CapturePaymentIntent => {
            if !request.provider_refs.provider_object_ref.has_safe_marker() {
                validation_errors.push("payment_intent_safe_ref_required");
            }
        }
        StripeLikeClientOperation::RetrieveCharge => {
            if !request.provider_refs.charge_ref.has_safe_marker()
                && !request.provider_refs.provider_object_ref.has_safe_marker()
            {
                validation_errors.push("charge_safe_ref_required");
            }
        }
        StripeLikeClientOperation::RetrieveRefund => {
            if !request.provider_refs.refund_ref.has_safe_marker()
                && !request.provider_refs.provider_object_ref.has_safe_marker()
            {
                validation_errors.push("refund_safe_ref_required");
            }
        }
        StripeLikeClientOperation::RetrieveDispute | StripeLikeClientOperation::ChargebackAck => {
            if !request.provider_refs.dispute_ref.has_safe_marker()
                && !request.provider_refs.provider_object_ref.has_safe_marker()
            {
                validation_errors.push("dispute_safe_ref_required");
            }
        }
        StripeLikeClientOperation::CreateRefund => {
            if !request.provider_refs.charge_ref.has_safe_marker()
                && !request.provider_refs.provider_object_ref.has_safe_marker()
            {
                validation_errors.push("charge_or_payment_intent_safe_ref_required");
            }
            if request
                .amount
                .as_deref()
                .map_or(true, |value| value.trim().is_empty())
            {
                validation_errors.push("amount_required_for_refund_create");
            }
            if request
                .currency
                .as_deref()
                .map_or(true, |value| value.trim().is_empty())
            {
                validation_errors.push("currency_required_for_refund_create");
            }
        }
    }
}

fn stripe_like_client_path_ref(request: &StripeLikeClientRequest) -> (&'static str, bool) {
    match request.operation {
        StripeLikeClientOperation::RetrievePaymentIntent
        | StripeLikeClientOperation::CapturePaymentIntent => (
            "provider_refs.provider_object_ref",
            request.provider_refs.provider_object_ref.has_safe_marker(),
        ),
        StripeLikeClientOperation::RetrieveCharge => (
            "provider_refs.charge_ref_or_provider_object_ref",
            request.provider_refs.charge_ref.has_safe_marker()
                || request.provider_refs.provider_object_ref.has_safe_marker(),
        ),
        StripeLikeClientOperation::RetrieveRefund => (
            "provider_refs.refund_ref_or_provider_object_ref",
            request.provider_refs.refund_ref.has_safe_marker()
                || request.provider_refs.provider_object_ref.has_safe_marker(),
        ),
        StripeLikeClientOperation::RetrieveDispute | StripeLikeClientOperation::ChargebackAck => (
            "provider_refs.dispute_ref_or_provider_object_ref",
            request.provider_refs.dispute_ref.has_safe_marker()
                || request.provider_refs.provider_object_ref.has_safe_marker(),
        ),
        StripeLikeClientOperation::CreateRefund => (
            "body.charge_or_payment_intent_safe_ref",
            request.provider_refs.charge_ref.has_safe_marker()
                || request.provider_refs.provider_object_ref.has_safe_marker(),
        ),
    }
}

fn stripe_like_client_body_fields(
    request: &StripeLikeClientRequest,
) -> Vec<StripeLikeClientBodyFieldReadback> {
    match request.operation {
        StripeLikeClientOperation::CapturePaymentIntent => vec![
            body_field("amount_to_capture", "amount", request.amount.is_some()),
            body_field("currency", "currency", request.currency.is_some()),
            body_field(
                "metadata[local_refs_present]",
                "local_refs",
                local_refs_present(&request.local_refs),
            ),
        ],
        StripeLikeClientOperation::CreateRefund => vec![
            body_field(
                "charge",
                "provider_refs.charge_ref",
                request.provider_refs.charge_ref.has_safe_marker(),
            ),
            body_field(
                "payment_intent",
                "provider_refs.provider_object_ref",
                request.provider_refs.provider_object_ref.has_safe_marker(),
            ),
            body_field("amount", "amount", request.amount.is_some()),
            body_field("currency", "currency", request.currency.is_some()),
            body_field("reason", "reason", request.reason.is_some()),
            body_field(
                "metadata[local_refs_present]",
                "local_refs",
                local_refs_present(&request.local_refs),
            ),
        ],
        StripeLikeClientOperation::ChargebackAck => vec![
            body_field("metadata[acknowledged_by_ledger]", "constant", true),
            body_field(
                "metadata[local_refs_present]",
                "local_refs",
                local_refs_present(&request.local_refs),
            ),
        ],
        StripeLikeClientOperation::RetrievePaymentIntent
        | StripeLikeClientOperation::RetrieveCharge
        | StripeLikeClientOperation::RetrieveRefund
        | StripeLikeClientOperation::RetrieveDispute => Vec::new(),
    }
}

fn body_field(
    name: &'static str,
    source: &'static str,
    value_present: bool,
) -> StripeLikeClientBodyFieldReadback {
    StripeLikeClientBodyFieldReadback {
        name,
        source,
        value_present,
        value_echoed: false,
    }
}

fn local_refs_present(refs: &PaymentProviderRefs) -> bool {
    refs.order_id.is_some()
        || refs.payment_intent_id.is_some()
        || refs.payment_capture_id.is_some()
        || refs.refund_id.is_some()
        || refs.credit_grant_id.is_some()
        || refs.ledger_entry_id.is_some()
        || refs.reversal_ledger_entry_id.is_some()
        || refs.invoice_id.is_some()
        || refs.audit_id.is_some()
}

fn stripe_api_fetch_requests_for_readback(
    readback: &PaymentProviderStripeApiObjectRefReadback,
) -> Vec<StripeApiFetchRequest> {
    match readback.event_type {
        Some(PaymentProviderEventType::Callback) => vec![StripeApiFetchRequest {
            object_type: StripeApiObjectType::Event,
            object_ref_source: "stripe.event.id",
            object_ref_present: readback.provider_event_id_present,
            credential_secret_ref_required: true,
            merchant_account_ref_required: true,
            expand: &["data.object"],
            raw_object_ref_echoed: false,
        }],
        Some(PaymentProviderEventType::Capture) => vec![
            StripeApiFetchRequest {
                object_type: StripeApiObjectType::PaymentIntent,
                object_ref_source: "stripe.data.object.id when object is payment_intent",
                object_ref_present: readback.provider_object_id_present,
                credential_secret_ref_required: true,
                merchant_account_ref_required: true,
                expand: &["latest_charge"],
                raw_object_ref_echoed: false,
            },
            StripeApiFetchRequest {
                object_type: StripeApiObjectType::Charge,
                object_ref_source: "stripe.charge.id or payment_intent.latest_charge",
                object_ref_present: readback.provider_object_id_present,
                credential_secret_ref_required: true,
                merchant_account_ref_required: true,
                expand: &["balance_transaction"],
                raw_object_ref_echoed: false,
            },
        ],
        Some(PaymentProviderEventType::Refund) => vec![
            StripeApiFetchRequest {
                object_type: StripeApiObjectType::Refund,
                object_ref_source: "stripe.refund.id",
                object_ref_present: readback.provider_object_id_present,
                credential_secret_ref_required: true,
                merchant_account_ref_required: true,
                expand: &["charge", "balance_transaction"],
                raw_object_ref_echoed: false,
            },
            StripeApiFetchRequest {
                object_type: StripeApiObjectType::Charge,
                object_ref_source: "stripe.refund.charge",
                object_ref_present: readback.provider_object_id_present
                    || readback.local_payment_capture_ref_present,
                credential_secret_ref_required: true,
                merchant_account_ref_required: true,
                expand: &["payment_intent"],
                raw_object_ref_echoed: false,
            },
        ],
        Some(PaymentProviderEventType::Chargeback) => vec![
            StripeApiFetchRequest {
                object_type: StripeApiObjectType::Dispute,
                object_ref_source: "stripe.dispute.id",
                object_ref_present: readback.provider_object_id_present,
                credential_secret_ref_required: true,
                merchant_account_ref_required: true,
                expand: &["charge", "payment_intent"],
                raw_object_ref_echoed: false,
            },
            StripeApiFetchRequest {
                object_type: StripeApiObjectType::Charge,
                object_ref_source: "stripe.dispute.charge",
                object_ref_present: readback.provider_object_id_present
                    || readback.local_payment_capture_ref_present,
                credential_secret_ref_required: true,
                merchant_account_ref_required: true,
                expand: &["payment_intent", "balance_transaction"],
                raw_object_ref_echoed: false,
            },
        ],
        None => Vec::new(),
    }
}

pub fn stripe_like_signature_format_support() -> PaymentProviderSignatureFormatSupport {
    PaymentProviderSignatureFormatSupport {
        header_names: &["stripe-signature", "x-fubox-payment-signature"],
        formats: &[
            "stripe_like:t=<unix_timestamp>,v1=<hmac_sha256_hex>",
            "fubox_simulated:sha256=<hmac_sha256_hex>",
            "fubox_simulated:<hmac_sha256_hex>",
        ],
        timestamp_tolerance_seconds: Some(STRIPE_LIKE_SIGNATURE_TOLERANCE_SECONDS),
        raw_header_echoed: false,
        raw_signature_echoed: false,
    }
}

pub fn normalize_stripe_like_sandbox_event(
    input: StripeLikeSandboxAdapterInput,
) -> StripeLikeSandboxAdapterReadback {
    let provider_supported =
        input.provider == "stripe_like" || input.provider == STRIPE_LIKE_SANDBOX_ADAPTER;
    let signature_parse = parse_stripe_like_signature_headers(&input.headers);
    let provider_event_type = input.payload.get("type").and_then(|value| value.as_str());
    let event_mapping = map_stripe_like_event_type(provider_event_type);
    let _payload_sha256 = input
        .payload_sha256
        .unwrap_or_else(|| sha256_hex(input.payload.to_string().as_bytes()));
    let (provider_event_readback, normalized_event) =
        if provider_supported && event_mapping.supported {
            normalize_stripe_like_event_payload(&input.payload, event_mapping.normalized_event_type)
        } else {
            (
                provider_event_readback_from_payload(
                    &input.payload,
                    if provider_supported {
                        event_mapping.unsupported_reason
                    } else {
                        Some("provider_not_supported_by_stripe_like_sandbox_adapter")
                    },
                ),
                None,
            )
        };
    let unsupported_reason = if !provider_supported {
        Some("provider_not_supported_by_stripe_like_sandbox_adapter")
    } else if let Some(reason) = event_mapping.unsupported_reason {
        Some(reason)
    } else if let Some(reason) = provider_event_readback.refusal_reason {
        Some(reason)
    } else {
        None
    };

    StripeLikeSandboxAdapterReadback {
        schema: PAYMENT_PROVIDER_STRIPE_LIKE_SANDBOX_ADAPTER_SCHEMA,
        adapter: STRIPE_LIKE_SANDBOX_ADAPTER,
        provider: input.provider,
        provider_supported,
        signature_format_support: stripe_like_signature_format_support(),
        signature_parse,
        signature_verification_readback: input.signature_verification,
        event_mapping,
        provider_event_readback,
        normalized_event,
        unsupported_reason,
        raw_webhook_body_echoed: false,
        raw_provider_payload_echoed: false,
        raw_idempotency_key_echoed: false,
        authorization_echoed: false,
        provider_secret_echoed: false,
        db_url_echoed: false,
        secret_safe: true,
        omitted_fields: &[
            "raw_webhook_body",
            "provider_payload",
            "authorization",
            "provider_secret",
            "webhook_signing_secret",
            "raw_idempotency_key",
            "database_url",
        ],
    }
}

fn parse_stripe_like_signature_headers(
    headers: &[PaymentProviderHeaderValue],
) -> PaymentProviderSignatureParseReadback {
    let selected = headers
        .iter()
        .find(|header| header.name.eq_ignore_ascii_case("stripe-signature"))
        .or_else(|| {
            headers.iter().find(|header| {
                header
                    .name
                    .eq_ignore_ascii_case("x-fubox-payment-signature")
            })
        });
    let Some(header) = selected else {
        return PaymentProviderSignatureParseReadback {
            header_present: false,
            header_name: None,
            format: "missing",
            timestamp_present: false,
            timestamp: None,
            signature_present: false,
            signature_count: 0,
            selected_scheme: None,
            unsupported_reason: Some("signature_header_missing"),
            raw_header_echoed: false,
            raw_signature_echoed: false,
        };
    };
    let lower_name = header.name.to_ascii_lowercase();
    let value = header.value.trim();
    let timestamp = stripe_like_signature_timestamp(value);
    let timestamp_present = timestamp.is_some();
    let stripe_v1_count = stripe_like_signature_values(value, "v1").len();
    let stripe_v1_present = stripe_v1_count > 0;
    let fubox_sha256_present = value.starts_with("sha256=") || value.contains(",sha256=");
    let bare_hex_present = value.len() == 64 && value.chars().all(|c| c.is_ascii_hexdigit());
    let (format, selected_scheme, signature_present, unsupported_reason) =
        if lower_name == "stripe-signature" && timestamp_present && stripe_v1_present {
            ("stripe_like", Some("v1".to_string()), true, None)
        } else if fubox_sha256_present {
            (
                "fubox_simulated_sha256",
                Some("sha256".to_string()),
                true,
                None,
            )
        } else if lower_name == "x-fubox-payment-signature" && bare_hex_present {
            (
                "fubox_simulated_bare_hex",
                Some("sha256".to_string()),
                true,
                None,
            )
        } else {
            (
                "unsupported",
                None,
                false,
                Some("signature_header_format_unsupported"),
            )
        };

    PaymentProviderSignatureParseReadback {
        header_present: true,
        header_name: Some(lower_name),
        format,
        timestamp_present,
        timestamp,
        signature_present,
        signature_count: if stripe_v1_count > 0 {
            stripe_v1_count
        } else if fubox_sha256_present || bare_hex_present {
            1
        } else {
            0
        },
        selected_scheme,
        unsupported_reason,
        raw_header_echoed: false,
        raw_signature_echoed: false,
    }
}

pub fn verify_stripe_like_signature_headers(
    headers: &[PaymentProviderHeaderValue],
    body: &[u8],
    webhook_secret: &str,
    current_timestamp: i64,
) -> PaymentProviderSignatureVerificationReadback {
    let payload_sha256 = sha256_hex(body);
    let parse = parse_stripe_like_signature_headers(headers);
    let Some(header_name) = parse.header_name.as_deref() else {
        return signature_verification_refused(
            parse.format,
            parse.timestamp_present,
            None,
            parse.signature_present,
            "raw_body",
            payload_sha256,
            None,
            "signature_header_missing",
        );
    };
    if webhook_secret.trim().is_empty() {
        return signature_verification_refused(
            parse.format,
            parse.timestamp_present,
            None,
            parse.signature_present,
            "raw_body",
            payload_sha256,
            None,
            "webhook_secret_missing",
        );
    }
    let Some(header_value) = headers
        .iter()
        .find(|header| header.name.eq_ignore_ascii_case(header_name))
        .map(|header| header.value.trim())
    else {
        return signature_verification_refused(
            parse.format,
            parse.timestamp_present,
            None,
            parse.signature_present,
            "raw_body",
            payload_sha256,
            None,
            "signature_header_missing",
        );
    };

    if parse.format == "stripe_like" {
        let Some(timestamp) = parse.timestamp else {
            return signature_verification_refused(
                parse.format,
                false,
                None,
                parse.signature_present,
                "stripe:t.raw_body",
                payload_sha256,
                None,
                "signature_timestamp_missing",
            );
        };
        let age = current_timestamp.saturating_sub(timestamp);
        let replay_window_ok = age.unsigned_abs() <= STRIPE_LIKE_SIGNATURE_TOLERANCE_SECONDS;
        let signed_payload = stripe_like_signed_payload(timestamp, body);
        let signed_payload_sha256 = sha256_hex(signed_payload.as_bytes());
        if !replay_window_ok {
            return PaymentProviderSignatureVerificationReadback {
                status: "refused",
                format: parse.format,
                timestamp_present: true,
                timestamp_tolerance_seconds: Some(STRIPE_LIKE_SIGNATURE_TOLERANCE_SECONDS),
                timestamp_age_seconds: Some(age),
                replay_window_ok: false,
                signature_present: parse.signature_present,
                signature_match: false,
                signed_payload_basis: "stripe:t.raw_body",
                signed_payload_sha256: Some(signed_payload_sha256),
                payload_sha256,
                mismatch_reason: Some("signature_replay_window_refused"),
                raw_header_echoed: false,
                raw_signature_echoed: false,
                raw_payload_echoed: false,
                secret_echoed: false,
            };
        }
        let expected = hmac_sha256_hex(webhook_secret.as_bytes(), signed_payload.as_bytes());
        let signature_match = stripe_like_signature_values(header_value, "v1")
            .iter()
            .any(|candidate| constant_time_str_eq(candidate, &expected));
        return PaymentProviderSignatureVerificationReadback {
            status: if signature_match {
                "verified"
            } else {
                "refused"
            },
            format: parse.format,
            timestamp_present: true,
            timestamp_tolerance_seconds: Some(STRIPE_LIKE_SIGNATURE_TOLERANCE_SECONDS),
            timestamp_age_seconds: Some(age),
            replay_window_ok: true,
            signature_present: parse.signature_present,
            signature_match,
            signed_payload_basis: "stripe:t.raw_body",
            signed_payload_sha256: Some(signed_payload_sha256),
            payload_sha256,
            mismatch_reason: if signature_match {
                None
            } else {
                Some("signature_mismatch")
            },
            raw_header_echoed: false,
            raw_signature_echoed: false,
            raw_payload_echoed: false,
            secret_echoed: false,
        };
    }

    if parse.format == "fubox_simulated_sha256" || parse.format == "fubox_simulated_bare_hex" {
        let expected = hmac_sha256_hex(webhook_secret.as_bytes(), body);
        let provided = normalize_simulated_signature_header(header_value);
        let signature_match = constant_time_str_eq(&provided, &expected);
        return PaymentProviderSignatureVerificationReadback {
            status: if signature_match {
                "verified"
            } else {
                "refused"
            },
            format: parse.format,
            timestamp_present: parse.timestamp_present,
            timestamp_tolerance_seconds: None,
            timestamp_age_seconds: None,
            replay_window_ok: true,
            signature_present: parse.signature_present,
            signature_match,
            signed_payload_basis: "raw_body",
            signed_payload_sha256: Some(payload_sha256.clone()),
            payload_sha256,
            mismatch_reason: if signature_match {
                None
            } else {
                Some("signature_mismatch")
            },
            raw_header_echoed: false,
            raw_signature_echoed: false,
            raw_payload_echoed: false,
            secret_echoed: false,
        };
    }

    signature_verification_refused(
        parse.format,
        parse.timestamp_present,
        None,
        parse.signature_present,
        "raw_body",
        payload_sha256,
        None,
        parse
            .unsupported_reason
            .unwrap_or("signature_header_format_unsupported"),
    )
}

fn signature_verification_refused(
    format: &'static str,
    timestamp_present: bool,
    timestamp_age_seconds: Option<i64>,
    signature_present: bool,
    signed_payload_basis: &'static str,
    payload_sha256: String,
    signed_payload_sha256: Option<String>,
    mismatch_reason: &'static str,
) -> PaymentProviderSignatureVerificationReadback {
    PaymentProviderSignatureVerificationReadback {
        status: "refused",
        format,
        timestamp_present,
        timestamp_tolerance_seconds: Some(STRIPE_LIKE_SIGNATURE_TOLERANCE_SECONDS),
        timestamp_age_seconds,
        replay_window_ok: false,
        signature_present,
        signature_match: false,
        signed_payload_basis,
        signed_payload_sha256,
        payload_sha256,
        mismatch_reason: Some(mismatch_reason),
        raw_header_echoed: false,
        raw_signature_echoed: false,
        raw_payload_echoed: false,
        secret_echoed: false,
    }
}

fn map_stripe_like_event_type(
    provider_event_type: Option<&str>,
) -> PaymentProviderEventMappingReadback {
    let normalized_event_type = match provider_event_type {
        Some("checkout.session.completed") | Some("payment_intent.created") => {
            Some(PaymentProviderEventType::Callback)
        }
        Some("payment_intent.succeeded") | Some("charge.succeeded") => {
            Some(PaymentProviderEventType::Capture)
        }
        Some("charge.refunded") | Some("refund.created") | Some("refund.succeeded") => {
            Some(PaymentProviderEventType::Refund)
        }
        Some("charge.dispute.created") | Some("charge.dispute.closed") => {
            Some(PaymentProviderEventType::Chargeback)
        }
        Some(_) => None,
        None => None,
    };
    let unsupported_reason = if provider_event_type.is_none() {
        Some("event_type_missing")
    } else if normalized_event_type.is_none() {
        Some("event_type_not_supported")
    } else {
        None
    };

    PaymentProviderEventMappingReadback {
        provider_event_type: provider_event_type.map(ToOwned::to_owned),
        normalized_event_type,
        supported: normalized_event_type.is_some(),
        unsupported_reason,
    }
}

fn normalize_stripe_like_event_payload(
    payload: &serde_json::Value,
    event_type: Option<PaymentProviderEventType>,
) -> (
    PaymentProviderEventReadback,
    Option<PaymentProviderNormalizedEvent>,
) {
    let Some(event_type) = event_type else {
        return (
            provider_event_readback_from_payload(payload, Some("event_type_not_supported")),
            None,
        );
    };
    let mut readback = provider_event_readback_from_payload(payload, None);
    let Some(external_event_id) = payload
        .get("id")
        .and_then(|value| value.as_str())
        .map(str::trim)
    else {
        readback.refusal_reason = Some("event_id_missing");
        readback.schema_valid = false;
        return (readback, None);
    };
    if external_event_id.is_empty() {
        readback.refusal_reason = Some("event_id_missing");
        readback.schema_valid = false;
        return (readback, None);
    }
    let object = payload
        .get("data")
        .and_then(|value| value.get("object"))
        .unwrap_or(payload);
    let Some(object_id) = object
        .get("id")
        .and_then(|value| value.as_str())
        .map(str::trim)
    else {
        readback.refusal_reason = Some("provider_object_id_missing");
        readback.schema_valid = false;
        return (readback, None);
    };
    if object_id.is_empty() {
        readback.refusal_reason = Some("provider_object_id_missing");
        readback.schema_valid = false;
        return (readback, None);
    }
    let amount_minor = object
        .get("amount_received")
        .or_else(|| object.get("amount_paid"))
        .or_else(|| object.get("amount_refunded"))
        .or_else(|| object.get("amount"))
        .and_then(|value| value.as_i64());
    let Some(amount_minor) = amount_minor else {
        readback.refusal_reason = Some("amount_missing");
        readback.schema_valid = false;
        return (readback, None);
    };
    let Some(currency) = object
        .get("currency")
        .and_then(|value| value.as_str())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| value.to_ascii_uppercase())
    else {
        readback.refusal_reason = Some("currency_missing");
        readback.schema_valid = false;
        return (readback, None);
    };
    if currency.is_empty() {
        readback.refusal_reason = Some("currency_missing");
        readback.schema_valid = false;
        return (readback, None);
    }
    let metadata = object.get("metadata").and_then(|value| value.as_object());
    if metadata
        .and_then(|map| metadata_string(map, "tenant_id"))
        .is_none()
    {
        readback.refusal_reason = Some("tenant_id_metadata_missing");
        readback.schema_valid = false;
        return (readback, None);
    }
    readback.refusal_reason = None;
    readback.schema_valid = true;
    let normalized = PaymentProviderNormalizedEvent {
        event_type,
        external_event_id: external_event_id.to_string(),
        amount: format_minor_amount(amount_minor),
        currency,
        idempotency_key: None,
        tenant_id: metadata.and_then(|map| metadata_string(map, "tenant_id")),
        order_id: metadata.and_then(|map| metadata_string(map, "order_id")),
        project_id: metadata.and_then(|map| metadata_string(map, "project_id")),
        wallet_id: metadata.and_then(|map| metadata_string(map, "wallet_id")),
        payment_intent_id: metadata.and_then(|map| metadata_string(map, "payment_intent_id")),
        payment_capture_id: metadata.and_then(|map| metadata_string(map, "payment_capture_id")),
        refund_id: metadata.and_then(|map| metadata_string(map, "refund_id")),
        credit_grant_id: metadata.and_then(|map| metadata_string(map, "credit_grant_id")),
        ledger_entry_id: metadata.and_then(|map| metadata_string(map, "ledger_entry_id")),
        reversal_ledger_entry_id: metadata
            .and_then(|map| metadata_string(map, "reversal_ledger_entry_id")),
        invoice_id: metadata.and_then(|map| metadata_string(map, "invoice_id")),
    };
    (readback, Some(normalized))
}

fn provider_event_readback_from_payload(
    payload: &serde_json::Value,
    refusal_reason: Option<&'static str>,
) -> PaymentProviderEventReadback {
    let provider_event_id = payload
        .get("id")
        .and_then(|value| value.as_str())
        .map(str::trim);
    let provider_event_type = payload
        .get("type")
        .and_then(|value| value.as_str())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned);
    let object = payload
        .get("data")
        .and_then(|value| value.get("object"))
        .unwrap_or(payload);
    let provider_object_id = object
        .get("id")
        .and_then(|value| value.as_str())
        .map(str::trim);
    let metadata = object.get("metadata").and_then(|value| value.as_object());
    let local_ref_count = metadata
        .map(|map| {
            [
                "tenant_id",
                "order_id",
                "project_id",
                "wallet_id",
                "payment_intent_id",
                "payment_capture_id",
                "refund_id",
                "credit_grant_id",
                "ledger_entry_id",
                "reversal_ledger_entry_id",
                "invoice_id",
            ]
            .iter()
            .filter(|key| metadata_string(map, key).is_some())
            .count()
        })
        .unwrap_or(0);
    let amount_present = object
        .get("amount_received")
        .or_else(|| object.get("amount_paid"))
        .or_else(|| object.get("amount_refunded"))
        .or_else(|| object.get("amount"))
        .and_then(|value| value.as_i64())
        .is_some();
    let currency_present = object
        .get("currency")
        .and_then(|value| value.as_str())
        .map(str::trim)
        .is_some_and(|value| !value.is_empty());
    let tenant_id_present = metadata
        .and_then(|map| metadata_string(map, "tenant_id"))
        .is_some();
    PaymentProviderEventReadback {
        provider_event_id_present: provider_event_id.is_some_and(|value| !value.is_empty()),
        provider_event_id_hash: provider_event_id
            .filter(|value| !value.is_empty())
            .map(|value| sha256_hex(value.as_bytes())),
        provider_event_type_present: provider_event_type.is_some(),
        provider_event_type,
        provider_object_id_present: provider_object_id.is_some_and(|value| !value.is_empty()),
        provider_object_id_hash: provider_object_id
            .filter(|value| !value.is_empty())
            .map(|value| sha256_hex(value.as_bytes())),
        amount_present,
        currency_present,
        metadata_present: metadata.is_some(),
        tenant_id_present,
        local_ref_count,
        schema_valid: refusal_reason.is_none()
            && provider_event_id.is_some_and(|value| !value.is_empty())
            && provider_object_id.is_some_and(|value| !value.is_empty())
            && amount_present
            && currency_present
            && tenant_id_present,
        refusal_reason,
        raw_provider_payload_echoed: false,
        raw_idempotency_key_echoed: false,
    }
}

pub fn summarize_stripe_like_provider_object(
    provider: impl Into<String>,
    object: &serde_json::Value,
) -> StripeLikeProviderObjectSummary {
    let provider_object_type_raw = object
        .get("object")
        .and_then(|value| value.as_str())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned);
    let provider_object_type = provider_object_type_raw
        .as_deref()
        .and_then(stripe_like_object_type_from_raw);
    let source_object = stripe_like_source_object_for_summary(provider_object_type, object);
    let mut unsupported_field_reasons = Vec::new();
    let mut missing_field_reasons = Vec::new();

    if provider_object_type_raw.is_none() {
        missing_field_reasons.push("object_type_missing");
    } else if provider_object_type.is_none() {
        unsupported_field_reasons.push("object_type_unsupported");
    }

    let provider_object_id = object
        .get("id")
        .and_then(|value| value.as_str())
        .map(str::trim)
        .filter(|value| !value.is_empty());
    if provider_object_id.is_none() {
        missing_field_reasons.push("provider_object_id_missing");
    }

    let status = stripe_like_provider_status(provider_object_type, object);
    if status.is_none() {
        missing_field_reasons.push("status_missing");
    }

    let amount_minor = provider_object_type
        .and_then(|object_type| stripe_like_amount_minor(object_type, source_object));
    if amount_minor.is_none() {
        missing_field_reasons.push("amount_missing");
    }
    let currency = source_object
        .get("currency")
        .and_then(|value| value.as_str())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| value.to_ascii_uppercase());
    if currency.is_none() {
        missing_field_reasons.push("currency_missing");
    }

    StripeLikeProviderObjectSummary {
        schema: PAYMENT_PROVIDER_STRIPE_LIKE_SOURCE_OF_TRUTH_SUMMARY_SCHEMA,
        provider: provider.into(),
        provider_object_type,
        provider_object_type_raw,
        provider_object_id_present: provider_object_id.is_some(),
        provider_object_id_hash: provider_object_id.map(|value| sha256_hex(value.as_bytes())),
        status,
        amount: amount_minor.map(format_minor_amount),
        currency,
        local_refs: stripe_like_local_refs_summary(source_object),
        captured: stripe_like_captured_readback(provider_object_type, source_object),
        refunded: stripe_like_refunded_readback(provider_object_type, source_object),
        disputed: stripe_like_disputed_readback(provider_object_type, source_object),
        unsupported_field_reasons,
        missing_field_reasons,
        sensitive_field_presence_detected: stripe_like_sensitive_field_present(object),
        secret_safe: true,
        raw_provider_payload_echoed: false,
        raw_customer_echoed: false,
        raw_email_echoed: false,
        raw_payment_method_echoed: false,
        raw_receipt_url_echoed: false,
        raw_billing_details_echoed: false,
        omitted_fields: &[
            "raw_provider_payload",
            "customer",
            "customer_email",
            "email",
            "payment_method",
            "payment_method_details",
            "receipt_url",
            "billing_details",
            "source",
            "shipping",
        ],
    }
}

fn stripe_like_object_type_from_raw(raw: &str) -> Option<StripeApiObjectType> {
    match raw {
        "event" => Some(StripeApiObjectType::Event),
        "payment_intent" => Some(StripeApiObjectType::PaymentIntent),
        "charge" => Some(StripeApiObjectType::Charge),
        "refund" => Some(StripeApiObjectType::Refund),
        "dispute" => Some(StripeApiObjectType::Dispute),
        _ => None,
    }
}

fn stripe_like_object_type_raw(object_type: StripeApiObjectType) -> &'static str {
    match object_type {
        StripeApiObjectType::Event => "event",
        StripeApiObjectType::PaymentIntent => "payment_intent",
        StripeApiObjectType::Charge => "charge",
        StripeApiObjectType::Refund => "refund",
        StripeApiObjectType::Dispute => "dispute",
    }
}

fn stripe_like_source_object_for_summary<'a>(
    object_type: Option<StripeApiObjectType>,
    object: &'a serde_json::Value,
) -> &'a serde_json::Value {
    if object_type == Some(StripeApiObjectType::Event) {
        object
            .get("data")
            .and_then(|value| value.get("object"))
            .unwrap_or(object)
    } else {
        object
    }
}

fn stripe_like_provider_status(
    object_type: Option<StripeApiObjectType>,
    object: &serde_json::Value,
) -> Option<String> {
    match object_type {
        Some(StripeApiObjectType::Event) => object
            .get("type")
            .and_then(|value| value.as_str())
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToOwned::to_owned),
        _ => object
            .get("status")
            .and_then(|value| value.as_str())
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToOwned::to_owned),
    }
}

fn stripe_like_amount_minor(
    object_type: StripeApiObjectType,
    object: &serde_json::Value,
) -> Option<i64> {
    match object_type {
        StripeApiObjectType::Event => object
            .get("amount_received")
            .or_else(|| object.get("amount"))
            .and_then(|value| value.as_i64()),
        StripeApiObjectType::PaymentIntent => object
            .get("amount_received")
            .or_else(|| object.get("amount"))
            .and_then(|value| value.as_i64()),
        StripeApiObjectType::Charge
        | StripeApiObjectType::Refund
        | StripeApiObjectType::Dispute => object.get("amount").and_then(|value| value.as_i64()),
    }
}

fn stripe_like_local_refs_summary(
    object: &serde_json::Value,
) -> StripeLikeProviderLocalRefsSummary {
    const LOCAL_REF_KEYS: &[&str] = &[
        "tenant_id",
        "order_id",
        "project_id",
        "wallet_id",
        "payment_intent_id",
        "payment_capture_id",
        "refund_id",
        "credit_grant_id",
        "ledger_entry_id",
        "reversal_ledger_entry_id",
        "invoice_id",
        "audit_id",
    ];

    let metadata = object.get("metadata").and_then(|value| value.as_object());
    let refs: Vec<_> = LOCAL_REF_KEYS
        .iter()
        .map(|key| {
            let value = metadata.and_then(|map| metadata_string(map, key));
            StripeLikeProviderLocalRefReadback {
                name: key,
                present: value.is_some(),
                value_hash: value.as_deref().map(|value| sha256_hex(value.as_bytes())),
            }
        })
        .collect();
    let local_ref_count = refs
        .iter()
        .filter(|ref_readback| ref_readback.present)
        .count();

    StripeLikeProviderLocalRefsSummary {
        metadata_present: metadata.is_some(),
        local_ref_count,
        refs,
    }
}

fn stripe_like_captured_readback(
    object_type: Option<StripeApiObjectType>,
    object: &serde_json::Value,
) -> StripeLikeProviderStateReadback {
    match object_type {
        Some(StripeApiObjectType::Event) => {
            let status = object
                .get("status")
                .and_then(|value| value.as_str())
                .is_some_and(|status| status == "succeeded")
                || object
                    .get("amount_received")
                    .and_then(|value| value.as_i64())
                    .unwrap_or(0)
                    > 0;
            StripeLikeProviderStateReadback {
                present: status,
                status: if status { "captured" } else { "not_captured" },
                amount: object
                    .get("amount_received")
                    .or_else(|| object.get("amount"))
                    .and_then(|value| value.as_i64())
                    .map(format_minor_amount),
                reason: None,
            }
        }
        Some(StripeApiObjectType::PaymentIntent) => {
            let amount_received = object
                .get("amount_received")
                .and_then(|value| value.as_i64())
                .unwrap_or(0);
            let captured = object
                .get("status")
                .and_then(|value| value.as_str())
                .is_some_and(|status| status == "succeeded")
                || amount_received > 0;
            StripeLikeProviderStateReadback {
                present: captured,
                status: if captured { "captured" } else { "not_captured" },
                amount: Some(format_minor_amount(amount_received)),
                reason: None,
            }
        }
        Some(StripeApiObjectType::Charge) => {
            let captured = object
                .get("captured")
                .and_then(|value| value.as_bool())
                .unwrap_or(false);
            StripeLikeProviderStateReadback {
                present: captured,
                status: if captured { "captured" } else { "not_captured" },
                amount: object
                    .get("amount_captured")
                    .or_else(|| object.get("amount"))
                    .and_then(|value| value.as_i64())
                    .map(format_minor_amount),
                reason: None,
            }
        }
        _ => StripeLikeProviderStateReadback {
            present: false,
            status: "not_applicable",
            amount: None,
            reason: Some("object_type_has_no_capture_state"),
        },
    }
}

fn stripe_like_refunded_readback(
    object_type: Option<StripeApiObjectType>,
    object: &serde_json::Value,
) -> StripeLikeProviderStateReadback {
    match object_type {
        Some(StripeApiObjectType::Event) => StripeLikeProviderStateReadback {
            present: object
                .get("object")
                .and_then(|value| value.as_str())
                .is_some_and(|value| value == "refund"),
            status: if object
                .get("object")
                .and_then(|value| value.as_str())
                .is_some_and(|value| value == "refund")
            {
                "refund_object"
            } else {
                "not_refunded"
            },
            amount: object
                .get("amount")
                .and_then(|value| value.as_i64())
                .map(format_minor_amount),
            reason: None,
        },
        Some(StripeApiObjectType::Charge) => {
            let amount_refunded = object
                .get("amount_refunded")
                .and_then(|value| value.as_i64())
                .unwrap_or(0);
            let refunded = object
                .get("refunded")
                .and_then(|value| value.as_bool())
                .unwrap_or(false)
                || amount_refunded > 0;
            StripeLikeProviderStateReadback {
                present: refunded,
                status: if refunded { "refunded" } else { "not_refunded" },
                amount: Some(format_minor_amount(amount_refunded)),
                reason: None,
            }
        }
        Some(StripeApiObjectType::Refund) => StripeLikeProviderStateReadback {
            present: true,
            status: "refund_object",
            amount: object
                .get("amount")
                .and_then(|value| value.as_i64())
                .map(format_minor_amount),
            reason: None,
        },
        _ => StripeLikeProviderStateReadback {
            present: false,
            status: "not_applicable",
            amount: None,
            reason: Some("object_type_has_no_refund_state"),
        },
    }
}

fn stripe_like_disputed_readback(
    object_type: Option<StripeApiObjectType>,
    object: &serde_json::Value,
) -> StripeLikeProviderStateReadback {
    match object_type {
        Some(StripeApiObjectType::Event) => StripeLikeProviderStateReadback {
            present: object
                .get("object")
                .and_then(|value| value.as_str())
                .is_some_and(|value| value == "dispute"),
            status: if object
                .get("object")
                .and_then(|value| value.as_str())
                .is_some_and(|value| value == "dispute")
            {
                "dispute_object"
            } else {
                "not_disputed"
            },
            amount: object
                .get("amount")
                .and_then(|value| value.as_i64())
                .map(format_minor_amount),
            reason: None,
        },
        Some(StripeApiObjectType::Charge) => {
            let disputed = object
                .get("disputed")
                .and_then(|value| value.as_bool())
                .unwrap_or(false);
            StripeLikeProviderStateReadback {
                present: disputed,
                status: if disputed { "disputed" } else { "not_disputed" },
                amount: None,
                reason: None,
            }
        }
        Some(StripeApiObjectType::Dispute) => StripeLikeProviderStateReadback {
            present: true,
            status: "dispute_object",
            amount: object
                .get("amount")
                .and_then(|value| value.as_i64())
                .map(format_minor_amount),
            reason: None,
        },
        _ => StripeLikeProviderStateReadback {
            present: false,
            status: "not_applicable",
            amount: None,
            reason: Some("object_type_has_no_dispute_state"),
        },
    }
}

fn stripe_like_sensitive_field_present(object: &serde_json::Value) -> bool {
    stripe_like_value_has_sensitive_field(object)
}

fn stripe_like_value_has_sensitive_field(value: &serde_json::Value) -> bool {
    match value {
        serde_json::Value::Object(map) => map.iter().any(|(key, value)| {
            stripe_like_is_sensitive_key(key) || stripe_like_value_has_sensitive_field(value)
        }),
        serde_json::Value::Array(values) => {
            values.iter().any(stripe_like_value_has_sensitive_field)
        }
        _ => false,
    }
}

fn stripe_like_is_sensitive_key(key: &str) -> bool {
    matches!(
        key,
        "customer"
            | "customer_email"
            | "email"
            | "payment_method"
            | "payment_method_details"
            | "receipt_url"
            | "billing_details"
            | "source"
            | "shipping"
    )
}

fn metadata_string(
    metadata: &serde_json::Map<String, serde_json::Value>,
    key: &str,
) -> Option<String> {
    metadata
        .get(key)
        .and_then(|value| value.as_str())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

fn stripe_like_signature_timestamp(value: &str) -> Option<i64> {
    value.split(',').find_map(|part| {
        part.trim()
            .strip_prefix("t=")
            .and_then(|timestamp| timestamp.parse::<i64>().ok())
    })
}

fn stripe_like_signature_values(value: &str, scheme: &str) -> Vec<String> {
    let prefix = format!("{scheme}=");
    value
        .split(',')
        .filter_map(|part| part.trim().strip_prefix(&prefix))
        .map(str::trim)
        .filter(|value| value.len() == 64 && value.chars().all(|c| c.is_ascii_hexdigit()))
        .map(|value| value.to_ascii_lowercase())
        .collect()
}

fn normalize_simulated_signature_header(value: &str) -> String {
    value
        .split(',')
        .find_map(|part| {
            let part = part.trim();
            part.strip_prefix("sha256=").or_else(|| {
                if part.len() == 64 && part.chars().all(|c| c.is_ascii_hexdigit()) {
                    Some(part)
                } else {
                    None
                }
            })
        })
        .unwrap_or_default()
        .to_ascii_lowercase()
}

fn stripe_like_signed_payload(timestamp: i64, body: &[u8]) -> String {
    format!("{timestamp}.{}", String::from_utf8_lossy(body))
}

fn format_minor_amount(amount_minor: i64) -> String {
    let sign = if amount_minor < 0 { "-" } else { "" };
    let absolute = amount_minor.abs();
    format!(
        "{sign}{}.{:08}",
        absolute / 100,
        (absolute % 100) * 1_000_000
    )
}

fn sha256_hex(value: &[u8]) -> String {
    hex_encode(&Sha256::digest(value))
}

fn hmac_sha256_hex(key: &[u8], data: &[u8]) -> String {
    const SHA256_BLOCK_LEN: usize = 64;
    let mut normalized_key = [0_u8; SHA256_BLOCK_LEN];
    if key.len() > SHA256_BLOCK_LEN {
        normalized_key[..32].copy_from_slice(&Sha256::digest(key));
    } else {
        normalized_key[..key.len()].copy_from_slice(key);
    }

    let mut inner_pad = [0x36_u8; SHA256_BLOCK_LEN];
    let mut outer_pad = [0x5c_u8; SHA256_BLOCK_LEN];
    for index in 0..SHA256_BLOCK_LEN {
        inner_pad[index] ^= normalized_key[index];
        outer_pad[index] ^= normalized_key[index];
    }

    let mut inner = Sha256::new();
    inner.update(inner_pad);
    inner.update(data);
    let inner_hash = inner.finalize();

    let mut outer = Sha256::new();
    outer.update(outer_pad);
    outer.update(inner_hash);
    hex_encode(&outer.finalize())
}

fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(HEX[(byte >> 4) as usize] as char);
        output.push(HEX[(byte & 0x0f) as usize] as char);
    }
    output
}

fn constant_time_str_eq(left: &str, right: &str) -> bool {
    let left = left.as_bytes();
    let right = right.as_bytes();
    if left.len() != right.len() {
        return false;
    }
    left.iter()
        .zip(right.iter())
        .fold(0_u8, |acc, (left, right)| acc | (left ^ right))
        == 0
}

pub fn plan_payment_provider_runtime_readback(
    request: PaymentProviderHandoffRequest,
) -> PaymentProviderRuntimeReadback {
    PaymentProviderRuntimeReadback {
        schema: PAYMENT_PROVIDER_RUNTIME_SKELETON_SCHEMA,
        mode: "manual_local_simulator",
        provider: request.provider,
        event_type: request.event_type,
        external_event_id_hash: request.external_event_id_hash,
        amount: request.amount,
        currency: request.currency,
        action_result: request.event_type.action_result(),
        signature_verification: "config-needed",
        merchant_connected: false,
        production_payment_evidence: false,
        secret_safe: true,
        raw_webhook_body_echoed: false,
        raw_idempotency_key_echoed: false,
        authorization_echoed: false,
        provider_secret_echoed: false,
        db_url_echoed: false,
        idempotency_key_hash: request.idempotency_key_hash,
        refs: request.refs,
        omitted_fields: &[
            "raw_webhook_body",
            "raw_idempotency_key",
            "authorization",
            "provider_secret",
            "client_secret",
            "provider_payload",
            "database_url",
        ],
        notes: &[
            "provider-neutral runtime skeleton only",
            "real merchant credentials are not configured",
            "signature verification must be wired before production use",
        ],
    }
}

pub fn plan_payment_provider_executor_contract(
    request: PaymentProviderExecutorRequest,
) -> PaymentProviderExecutorResult {
    let mut validation_errors = Vec::new();
    if request.provider.trim().is_empty() {
        validation_errors.push("provider_missing");
    }
    if request.amount.trim().is_empty() {
        validation_errors.push("amount_missing");
    }
    if request.currency.trim().is_empty() {
        validation_errors.push("currency_missing");
    }
    if request.reason.trim().is_empty() {
        validation_errors.push("reason_missing");
    }
    validate_executor_idempotency(&request.idempotency, &mut validation_errors);
    validate_provider_ref(
        "provider_event_ref",
        &request.provider_refs.provider_event_ref,
        &mut validation_errors,
    );
    validate_provider_ref(
        "provider_object_ref",
        &request.provider_refs.provider_object_ref,
        &mut validation_errors,
    );
    validate_provider_ref(
        "dispute_ref",
        &request.provider_refs.dispute_ref,
        &mut validation_errors,
    );
    validate_provider_ref(
        "charge_ref",
        &request.provider_refs.charge_ref,
        &mut validation_errors,
    );
    validate_provider_ref(
        "refund_ref",
        &request.provider_refs.refund_ref,
        &mut validation_errors,
    );
    validate_action_refs(&request, &mut validation_errors);

    let mut gate_refusal_reasons = Vec::new();
    if !request.gate.adapter_enabled {
        gate_refusal_reasons.push("adapter_disabled");
    }
    if !request.gate.merchant_connected {
        gate_refusal_reasons.push("merchant_not_connected");
    }
    if !request.gate.credential_present {
        gate_refusal_reasons.push("credential_missing");
    }
    if !request.gate.credential_fingerprint_present {
        gate_refusal_reasons.push("credential_fingerprint_missing");
    }
    if !request.gate.signature_verified {
        gate_refusal_reasons.push("signature_not_verified");
    }

    let allowed = validation_errors.is_empty() && gate_refusal_reasons.is_empty();
    let reason_present = !request.reason.trim().is_empty();
    let idempotency_key_hash_present = request.idempotency.key_hash.is_some();
    let idempotency_fingerprint = request.idempotency.fingerprint.clone();
    let idempotency_readback =
        executor_idempotency_readback(&request.idempotency, allowed, &validation_errors);
    let status_mapping = executor_status_mapping_readback(
        request.action,
        allowed,
        validation_errors.clone(),
        gate_refusal_reasons.clone(),
    );
    let ledger_handoff = executor_ledger_handoff_readback(request.action, allowed);
    PaymentProviderExecutorResult {
        schema: PAYMENT_PROVIDER_EXECUTOR_CONTRACT_SCHEMA,
        provider: request.provider,
        action: request.action,
        status: if allowed { "planned" } else { "refused" },
        action_result: if allowed {
            request.action.result_label()
        } else {
            "executor_refused"
        },
        required_refs: request.action.required_refs(),
        amount: request.amount,
        currency: request.currency,
        reason_present,
        idempotency_key_hash_present,
        idempotency_fingerprint,
        idempotency_readback,
        status_mapping,
        ledger_handoff,
        provider_refs: request.provider_refs,
        local_refs: request.local_refs,
        gate_readback: PaymentProviderExecutorGateReadback {
            status: if gate_refusal_reasons.is_empty() {
                "allowed"
            } else {
                "blocked"
            },
            adapter_enabled: request.gate.adapter_enabled,
            merchant_connected: request.gate.merchant_connected,
            credential_present: request.gate.credential_present,
            credential_fingerprint_present: request.gate.credential_fingerprint_present,
            signature_verified: request.gate.signature_verified,
            network_call_enabled: false,
            production_payment_evidence: false,
            refusal_reasons: gate_refusal_reasons,
        },
        secret_safe: true,
        normalized_executor_result_readback: true,
        raw_provider_payload_echoed: false,
        raw_webhook_body_echoed: false,
        raw_idempotency_key_echoed: false,
        authorization_echoed: false,
        provider_secret_echoed: false,
        provider_ref_raw_echoed: false,
        raw_invoice_metadata_echoed: false,
        validation_errors,
        omitted_fields: &[
            "raw_provider_payload",
            "raw_webhook_body",
            "authorization",
            "provider_secret",
            "client_secret",
            "provider_event_ref_raw",
            "provider_object_ref_raw",
            "raw_idempotency_key",
            "raw_invoice_metadata",
            "invoice_metadata",
            "database_url",
        ],
    }
}

fn executor_idempotency_readback(
    idempotency: &PaymentProviderExecutorIdempotency,
    allowed: bool,
    validation_errors: &[&'static str],
) -> PaymentProviderExecutorIdempotencyReadback {
    let marker_present = idempotency.has_safe_marker();
    let conflict_refusal_reason = if validation_errors
        .iter()
        .any(|error| error.contains("idempotency"))
    {
        Some("idempotency_marker_invalid_or_missing")
    } else {
        None
    };
    PaymentProviderExecutorIdempotencyReadback {
        status: if allowed && marker_present {
            "accepted_for_replay_check"
        } else if marker_present {
            "present_but_request_refused"
        } else {
            "missing"
        },
        key_hash_present: idempotency.key_hash.is_some(),
        fingerprint_present: idempotency.fingerprint.is_some(),
        replay_safe: allowed && marker_present,
        conflict_refusal_reason,
        raw_idempotency_key_echoed: false,
    }
}

fn executor_status_mapping_readback(
    action: PaymentProviderExecutorAction,
    allowed: bool,
    validation_errors: Vec<&'static str>,
    gate_refusal_reasons: Vec<&'static str>,
) -> PaymentProviderExecutorStatusMappingReadback {
    let mut refusal_reasons = validation_errors;
    refusal_reasons.extend(gate_refusal_reasons);
    let refusal_code = if allowed {
        None
    } else if refusal_reasons
        .iter()
        .any(|reason| reason.contains("idempotency"))
    {
        Some("idempotency_refused")
    } else if refusal_reasons
        .iter()
        .any(|reason| reason.contains("signature"))
    {
        Some("provider_signature_refused")
    } else if refusal_reasons
        .iter()
        .any(|reason| reason.contains("merchant"))
    {
        Some("merchant_not_connected")
    } else if refusal_reasons
        .iter()
        .any(|reason| reason.contains("credential"))
    {
        Some("provider_credential_refused")
    } else if refusal_reasons
        .iter()
        .any(|reason| reason.contains("amount") || reason.contains("currency"))
    {
        Some("payment_amount_or_currency_refused")
    } else {
        Some("provider_executor_refused")
    };

    PaymentProviderExecutorStatusMappingReadback {
        provider_status_source: "normalized_provider_summary_or_callback_required_not_raw_payload",
        normalized_status: if allowed {
            match action {
                PaymentProviderExecutorAction::Callback => "callback_recorded",
                PaymentProviderExecutorAction::Capture => "capture_candidate_ready",
                PaymentProviderExecutorAction::Refund => "refund_reversal_candidate_ready",
                PaymentProviderExecutorAction::ChargebackAck => {
                    "chargeback_reversal_candidate_ready"
                }
            }
        } else {
            "refused"
        },
        terminal: matches!(
            action,
            PaymentProviderExecutorAction::Capture
                | PaymentProviderExecutorAction::Refund
                | PaymentProviderExecutorAction::ChargebackAck
        ) && allowed,
        local_write_allowed: allowed,
        refusal_code,
        refusal_reasons,
        callback_readback_available: matches!(action, PaymentProviderExecutorAction::Callback),
        capture_readback_available: matches!(action, PaymentProviderExecutorAction::Capture),
        refund_readback_available: matches!(action, PaymentProviderExecutorAction::Refund),
        chargeback_readback_available: matches!(
            action,
            PaymentProviderExecutorAction::ChargebackAck
        ),
    }
}

fn executor_ledger_handoff_readback(
    action: PaymentProviderExecutorAction,
    allowed: bool,
) -> PaymentProviderExecutorLedgerHandoffReadback {
    let reversal_handoff_required = matches!(
        action,
        PaymentProviderExecutorAction::Refund | PaymentProviderExecutorAction::ChargebackAck
    );
    let ledger_handoff_required = matches!(
        action,
        PaymentProviderExecutorAction::Capture
            | PaymentProviderExecutorAction::Refund
            | PaymentProviderExecutorAction::ChargebackAck
    );
    let handoff_target = match action {
        PaymentProviderExecutorAction::Callback => "payment_events_normalized_callback_readback",
        PaymentProviderExecutorAction::Capture => {
            "payment_capture_apply_requires_credit_grant_or_ledger_marker"
        }
        PaymentProviderExecutorAction::Refund => {
            "refund_apply_requires_credit_grant_revoke_or_ledger_reversal"
        }
        PaymentProviderExecutorAction::ChargebackAck => {
            "chargeback_apply_requires_ledger_reversal_or_dispute_reconciliation"
        }
    };

    PaymentProviderExecutorLedgerHandoffReadback {
        ledger_write_performed: false,
        ledger_write_allowed_by_executor: false,
        ledger_handoff_required,
        reversal_handoff_required,
        handoff_target,
        handoff_status: if allowed {
            "handoff_ready_no_local_write_performed"
        } else {
            "blocked_no_local_write_performed"
        },
        local_apply_requires_reconciliation_match: ledger_handoff_required,
        direct_merchant_success_forged: false,
        invoice_metadata_echoed: false,
        raw_invoice_metadata_echoed: false,
    }
}

pub fn map_stripe_like_response_object_reconciliation(
    provider: impl Into<String>,
    action: PaymentProviderExecutorAction,
    amount: &str,
    currency: &str,
    idempotency: &PaymentProviderExecutorIdempotency,
    local_refs: &PaymentProviderRefs,
    provider_object_summary: Option<&StripeLikeProviderObjectSummary>,
    response_header_summary: &StripeLikeRateLimitReadback,
) -> StripeLikeResponseObjectReconciliation {
    let provider = provider.into();
    let expected_provider_object_types = stripe_like_reconciliation_expected_object_types(action);
    let expected_provider_statuses = stripe_like_reconciliation_expected_statuses(action);
    let expected_local_refs = stripe_like_reconciliation_expected_local_refs(action);
    let source_object_presence =
        stripe_like_source_object_presence_readback(provider_object_summary);
    let mut mismatch_reasons = Vec::new();
    let mut blocked_reasons = Vec::new();

    let Some(summary) = provider_object_summary else {
        blocked_reasons.push("provider_object_summary_missing");
        if response_header_summary.should_retry {
            blocked_reasons.push("provider_response_retryable");
        }
        return stripe_like_response_object_reconciliation_result(
            provider,
            action,
            false,
            response_header_summary,
            None,
            None,
            None,
            None,
            None,
            idempotency,
            source_object_presence,
            expected_provider_object_types,
            expected_provider_statuses,
            expected_local_refs,
            mismatch_reasons,
            blocked_reasons,
        );
    };

    if !summary.missing_field_reasons.is_empty() {
        blocked_reasons.push("provider_object_summary_missing_required_fields");
    }
    if !summary.unsupported_field_reasons.is_empty() {
        blocked_reasons.push("provider_object_summary_unsupported_object_type");
    }

    let provider_object_type_matches = summary
        .provider_object_type
        .map(stripe_like_object_type_raw)
        .map(|object_type| expected_provider_object_types.contains(&object_type));
    match provider_object_type_matches {
        Some(false) => mismatch_reasons.push("provider_object_type_mismatch"),
        None => blocked_reasons.push("provider_object_type_missing"),
        Some(true) => {}
    }

    let provider_status_matches = summary
        .status
        .as_deref()
        .map(|status| expected_provider_statuses.contains(&status));
    match provider_status_matches {
        Some(false) => mismatch_reasons.push("provider_status_mismatch"),
        None => blocked_reasons.push("provider_status_missing"),
        Some(true) => {}
    }

    let amount_matches = summary.amount.as_deref().map(|provider_amount| {
        provider_amount == amount
            && match action {
                PaymentProviderExecutorAction::Capture => {
                    summary.captured.present
                        && summary
                            .captured
                            .amount
                            .as_deref()
                            .unwrap_or(provider_amount)
                            == amount
                }
                PaymentProviderExecutorAction::Refund => {
                    summary.refunded.present
                        && summary
                            .refunded
                            .amount
                            .as_deref()
                            .unwrap_or(provider_amount)
                            == amount
                }
                PaymentProviderExecutorAction::ChargebackAck => {
                    summary.disputed.present
                        && summary
                            .disputed
                            .amount
                            .as_deref()
                            .unwrap_or(provider_amount)
                            == amount
                }
                PaymentProviderExecutorAction::Callback => provider_amount == amount,
            }
    });
    match amount_matches {
        Some(false) => mismatch_reasons.push("provider_amount_mismatch"),
        None => blocked_reasons.push("provider_amount_missing"),
        Some(true) => {}
    }

    let currency_matches = summary
        .currency
        .as_deref()
        .map(|provider_currency| provider_currency.eq_ignore_ascii_case(currency));
    match currency_matches {
        Some(false) => mismatch_reasons.push("provider_currency_mismatch"),
        None => blocked_reasons.push("provider_currency_missing"),
        Some(true) => {}
    }

    let local_refs_match =
        stripe_like_reconciliation_local_refs_match(local_refs, summary, expected_local_refs);
    match local_refs_match {
        Some(false) => mismatch_reasons.push("provider_local_ref_mismatch"),
        None => blocked_reasons.push("provider_local_refs_missing"),
        Some(true) => {}
    }

    let matched = blocked_reasons.is_empty() && mismatch_reasons.is_empty();
    stripe_like_response_object_reconciliation_result(
        provider,
        action,
        matched,
        response_header_summary,
        provider_object_type_matches,
        provider_status_matches,
        amount_matches,
        currency_matches,
        local_refs_match,
        idempotency,
        source_object_presence,
        expected_provider_object_types,
        expected_provider_statuses,
        expected_local_refs,
        mismatch_reasons,
        blocked_reasons,
    )
}

fn stripe_like_response_object_reconciliation_result(
    provider: String,
    action: PaymentProviderExecutorAction,
    matched: bool,
    response_header_summary: &StripeLikeRateLimitReadback,
    provider_object_type_matches: Option<bool>,
    provider_status_matches: Option<bool>,
    amount_matches: Option<bool>,
    currency_matches: Option<bool>,
    local_refs_match: Option<bool>,
    idempotency: &PaymentProviderExecutorIdempotency,
    mut source_object_presence: StripeLikeSourceObjectPresenceReadback,
    expected_provider_object_types: &'static [&'static str],
    expected_provider_statuses: &'static [&'static str],
    expected_local_refs: &'static [&'static str],
    mismatch_reasons: Vec<&'static str>,
    blocked_reasons: Vec<&'static str>,
) -> StripeLikeResponseObjectReconciliation {
    let status = if matched {
        "matched"
    } else if !mismatch_reasons.is_empty() {
        "mismatch"
    } else {
        "blocked"
    };
    let retry_recommended = status == "blocked" && response_header_summary.should_retry;
    let retry_reason = if retry_recommended {
        response_header_summary.backoff_reason
    } else {
        "none"
    };
    let parser_error_present = blocked_reasons.iter().any(|reason| {
        matches!(
            *reason,
            "provider_object_summary_missing_required_fields"
                | "provider_object_summary_unsupported_object_type"
                | "provider_object_type_missing"
                | "provider_status_missing"
                | "provider_amount_missing"
                | "provider_currency_missing"
        )
    });
    source_object_presence.parser_error_present |= parser_error_present;
    let safe_next_action = match status {
        "matched" => "accept_reconciliation_candidate_then_apply_or_replay_local_action",
        "mismatch" => "do_not_apply_local_action_review_mismatch_reasons",
        _ if retry_recommended => "retry_provider_object_fetch_after_backoff_without_local_write",
        _ if parser_error_present => {
            "fix_provider_object_parser_or_fixture_summary_before_local_write"
        }
        _ => "load_provider_object_summary_before_local_write",
    };

    StripeLikeResponseObjectReconciliation {
        schema: PAYMENT_PROVIDER_STRIPE_LIKE_RESPONSE_OBJECT_RECONCILIATION_SCHEMA,
        status,
        action,
        source_of_truth_candidate: stripe_like_reconciliation_source_candidate(action),
        matched,
        provider,
        provider_object_summary_present: source_object_presence.provider_object_summary_present,
        source_object_presence,
        response_header_summary_present: response_header_summary.header_summary_present,
        provider_object_type_matches,
        provider_status_matches,
        amount_matches,
        currency_matches,
        local_refs_match,
        idempotency_key_hash_present: idempotency.key_hash.is_some(),
        idempotency_fingerprint_present: idempotency.fingerprint.is_some(),
        idempotency_safe_marker_present: idempotency.has_safe_marker(),
        expected_provider_object_types,
        expected_provider_statuses,
        expected_local_refs,
        mismatch_reasons,
        blocked_reasons,
        retry_recommended,
        retry_reason,
        safe_next_action,
        network_call_performed: false,
        secret_safe: true,
        raw_provider_payload_echoed: false,
        raw_headers_echoed: false,
        raw_provider_ref_echoed: false,
        authorization_echoed: false,
        provider_secret_echoed: false,
        omitted_fields: &[
            "provider_object_source_of_truth",
            "raw_provider_payload",
            "raw_response_headers",
            "stripe_request_id_raw",
            "provider_object_ref_raw",
            "raw_idempotency_key",
            "authorization",
            "provider_secret",
            "credential_value",
        ],
    }
}

fn stripe_like_source_object_presence_readback(
    summary: Option<&StripeLikeProviderObjectSummary>,
) -> StripeLikeSourceObjectPresenceReadback {
    let provider_object_type_raw =
        summary.and_then(|summary| summary.provider_object_type_raw.as_deref());
    StripeLikeSourceObjectPresenceReadback {
        provider_object_summary_present: summary.is_some(),
        provider_object_id_present: summary
            .is_some_and(|summary| summary.provider_object_id_present),
        event_object_present: provider_object_type_raw == Some("event"),
        payment_intent_object_present: provider_object_type_raw == Some("payment_intent"),
        charge_object_present: provider_object_type_raw == Some("charge"),
        refund_object_present: provider_object_type_raw == Some("refund"),
        dispute_object_present: provider_object_type_raw == Some("dispute"),
        parser_error_present: summary.is_some_and(|summary| {
            !summary.missing_field_reasons.is_empty()
                || !summary.unsupported_field_reasons.is_empty()
        }),
    }
}

fn stripe_like_reconciliation_expected_object_types(
    action: PaymentProviderExecutorAction,
) -> &'static [&'static str] {
    match action {
        PaymentProviderExecutorAction::Callback => &["event", "payment_intent", "charge"],
        PaymentProviderExecutorAction::Capture => &["event", "payment_intent", "charge"],
        PaymentProviderExecutorAction::Refund => &["event", "refund"],
        PaymentProviderExecutorAction::ChargebackAck => &["event", "dispute"],
    }
}

fn stripe_like_reconciliation_source_candidate(
    action: PaymentProviderExecutorAction,
) -> &'static str {
    match action {
        PaymentProviderExecutorAction::Callback => "callback_source_of_truth_candidate",
        PaymentProviderExecutorAction::Capture => "capture_source_of_truth_candidate",
        PaymentProviderExecutorAction::Refund => "refund_source_of_truth_candidate",
        PaymentProviderExecutorAction::ChargebackAck => "chargeback_source_of_truth_candidate",
    }
}

fn stripe_like_reconciliation_expected_statuses(
    action: PaymentProviderExecutorAction,
) -> &'static [&'static str] {
    match action {
        PaymentProviderExecutorAction::Callback => &[
            "succeeded",
            "payment_intent.succeeded",
            "charge.succeeded",
            "charge.refunded",
            "charge.dispute.created",
        ],
        PaymentProviderExecutorAction::Capture => {
            &["succeeded", "payment_intent.succeeded", "charge.succeeded"]
        }
        PaymentProviderExecutorAction::Refund => {
            &["succeeded", "refund.succeeded", "charge.refunded"]
        }
        PaymentProviderExecutorAction::ChargebackAck => &[
            "closed",
            "won",
            "charge.dispute.created",
            "charge.dispute.closed",
        ],
    }
}

fn stripe_like_reconciliation_expected_local_refs(
    action: PaymentProviderExecutorAction,
) -> &'static [&'static str] {
    match action {
        PaymentProviderExecutorAction::Callback => &["payment_intent_id"],
        PaymentProviderExecutorAction::Capture => &["payment_intent_id"],
        PaymentProviderExecutorAction::Refund => &["payment_capture_id", "refund_id"],
        PaymentProviderExecutorAction::ChargebackAck => &["payment_capture_id"],
    }
}

fn stripe_like_reconciliation_local_refs_match(
    local_refs: &PaymentProviderRefs,
    summary: &StripeLikeProviderObjectSummary,
    expected_local_refs: &[&str],
) -> Option<bool> {
    let mut saw_expected = false;
    for expected in expected_local_refs {
        let local_value = payment_provider_local_ref_value(local_refs, expected);
        let provider_ref = summary
            .local_refs
            .refs
            .iter()
            .find(|provider_ref| provider_ref.name == *expected);
        let Some(local_value) = local_value else {
            return Some(false);
        };
        let Some(provider_ref) = provider_ref else {
            return Some(false);
        };
        if !provider_ref.present {
            return Some(false);
        }
        let Some(provider_hash) = provider_ref.value_hash.as_deref() else {
            return Some(false);
        };
        saw_expected = true;
        if sha256_hex(local_value.as_bytes()) != provider_hash {
            return Some(false);
        }
    }

    if saw_expected { Some(true) } else { None }
}

fn payment_provider_local_ref_value<'a>(
    local_refs: &'a PaymentProviderRefs,
    name: &str,
) -> Option<&'a str> {
    match name {
        "order_id" => local_refs.order_id.as_deref(),
        "payment_intent_id" => local_refs.payment_intent_id.as_deref(),
        "payment_capture_id" => local_refs.payment_capture_id.as_deref(),
        "refund_id" => local_refs.refund_id.as_deref(),
        "credit_grant_id" => local_refs.credit_grant_id.as_deref(),
        "ledger_entry_id" => local_refs.ledger_entry_id.as_deref(),
        "reversal_ledger_entry_id" => local_refs.reversal_ledger_entry_id.as_deref(),
        "invoice_id" => local_refs.invoice_id.as_deref(),
        "audit_id" => local_refs.audit_id.as_deref(),
        _ => None,
    }
}

fn validate_action_refs(
    request: &PaymentProviderExecutorRequest,
    validation_errors: &mut Vec<&'static str>,
) {
    match request.action {
        PaymentProviderExecutorAction::Callback => {
            if !request.provider_refs.provider_event_ref.has_safe_marker() {
                validation_errors.push("provider_event_ref_required_for_callback");
            }
            if !request.provider_refs.provider_object_ref.has_safe_marker() {
                validation_errors.push("provider_object_ref_required_for_callback");
            }
        }
        PaymentProviderExecutorAction::Capture => {
            if !request.provider_refs.provider_object_ref.has_safe_marker() {
                validation_errors.push("provider_object_ref_required_for_capture");
            }
        }
        PaymentProviderExecutorAction::Refund => {
            if !request.provider_refs.provider_object_ref.has_safe_marker()
                && !request.provider_refs.refund_ref.has_safe_marker()
            {
                validation_errors.push("provider_object_or_refund_ref_required_for_refund");
            }
            if request.local_refs.payment_capture_id.is_none() {
                validation_errors.push("payment_capture_id_required_for_refund");
            }
        }
        PaymentProviderExecutorAction::ChargebackAck => {
            if !request.provider_refs.provider_event_ref.has_safe_marker()
                && !request.provider_refs.dispute_ref.has_safe_marker()
            {
                validation_errors.push("provider_event_or_dispute_ref_required_for_chargeback_ack");
            }
        }
    }
}

fn validate_executor_idempotency(
    idempotency: &PaymentProviderExecutorIdempotency,
    validation_errors: &mut Vec<&'static str>,
) {
    if !idempotency.has_safe_marker() {
        validation_errors.push("idempotency_hash_or_fingerprint_required");
    }
    if let Some(hash) = idempotency.key_hash.as_deref() {
        validate_hash_marker("idempotency_key_hash", hash, validation_errors);
    }
    if let Some(fingerprint) = idempotency.fingerprint.as_deref() {
        validate_fingerprint_marker("idempotency_fingerprint", fingerprint, validation_errors);
    }
}

fn validate_provider_ref(
    label: &'static str,
    value: &PaymentProviderSafeRef,
    validation_errors: &mut Vec<&'static str>,
) {
    if value.hash.is_some() || value.fingerprint.is_some() {
        if !value.present {
            validation_errors.push("safe_ref_marker_requires_presence");
        }
    }
    if let Some(hash) = value.hash.as_deref() {
        validate_hash_marker(label, hash, validation_errors);
    }
    if let Some(fingerprint) = value.fingerprint.as_deref() {
        validate_fingerprint_marker(label, fingerprint, validation_errors);
    }
}

fn validate_hash_marker(
    label: &'static str,
    value: &str,
    validation_errors: &mut Vec<&'static str>,
) {
    if value.len() != 64 || !value.chars().all(|c| c.is_ascii_hexdigit()) {
        validation_errors.push(match label {
            "idempotency_key_hash" => "idempotency_key_hash_must_be_sha256_hex",
            "provider_event_ref" => "provider_event_ref_hash_must_be_sha256_hex",
            "provider_object_ref" => "provider_object_ref_hash_must_be_sha256_hex",
            "dispute_ref" => "dispute_ref_hash_must_be_sha256_hex",
            "charge_ref" => "charge_ref_hash_must_be_sha256_hex",
            "refund_ref" => "refund_ref_hash_must_be_sha256_hex",
            _ => "hash_must_be_sha256_hex",
        });
    }
}

fn validate_fingerprint_marker(
    label: &'static str,
    value: &str,
    validation_errors: &mut Vec<&'static str>,
) {
    let normalized = value.trim().to_ascii_lowercase();
    let safe_shape = (8..=64).contains(&value.len())
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
    let suspicious = normalized.contains("authorization")
        || normalized.contains("bearer")
        || normalized.contains("secret")
        || normalized.contains("whsec")
        || normalized.contains("sk_live")
        || normalized.contains("sk_test")
        || ["evt_", "pi_", "ch_", "re_", "dp_", "du_"]
            .iter()
            .any(|prefix| normalized.starts_with(prefix));

    if !safe_shape || suspicious {
        validation_errors.push(match label {
            "idempotency_fingerprint" => "idempotency_fingerprint_must_not_be_raw",
            "provider_event_ref" => "provider_event_ref_fingerprint_must_not_be_raw",
            "provider_object_ref" => "provider_object_ref_fingerprint_must_not_be_raw",
            "dispute_ref" => "dispute_ref_fingerprint_must_not_be_raw",
            "charge_ref" => "charge_ref_fingerprint_must_not_be_raw",
            "refund_ref" => "refund_ref_fingerprint_must_not_be_raw",
            _ => "fingerprint_must_not_be_raw",
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const EXECUTOR_CONTRACT_FIXTURE: &str =
        include_str!("../../../tests/fixtures/billing/payment_provider_executor_contract.json");
    const STRIPE_LIKE_CLIENT_PLAN_FIXTURE: &str = include_str!(
        "../../../tests/fixtures/billing/payment_provider_stripe_like_client_plan_contract.json"
    );
    const STRIPE_LIKE_SOURCE_OF_TRUTH_FIXTURE: &str = include_str!(
        "../../../tests/fixtures/billing/payment_provider_stripe_like_source_of_truth_summary_contract.json"
    );
    const STRIPE_LIKE_CLIENT_HANDOFF_FIXTURE: &str = include_str!(
        "../../../tests/fixtures/billing/payment_provider_stripe_like_client_handoff_contract.json"
    );

    #[test]
    fn adapter_config_status_exposes_presence_without_secrets() {
        let disabled =
            plan_payment_provider_adapter_config_status(PaymentProviderAdapterConfigInput {
                provider: None,
                adapter_enabled: false,
                merchant_account_present: false,
                credential_present: false,
                credential_fingerprint_prefix: None,
                webhook_secret_present: false,
            });
        assert_eq!(disabled.schema, PAYMENT_PROVIDER_ADAPTER_CONFIG_SCHEMA);
        assert_eq!(disabled.status, "disabled");
        assert_eq!(disabled.signature_verifier_status, "disabled");
        assert!(!disabled.merchant_connected);

        let ready =
            plan_payment_provider_adapter_config_status(PaymentProviderAdapterConfigInput {
                provider: Some("stripe_like".to_string()),
                adapter_enabled: true,
                merchant_account_present: true,
                credential_present: true,
                credential_fingerprint_prefix: Some("abc123def4567890".to_string()),
                webhook_secret_present: true,
            });
        assert_eq!(ready.status, "ready-for-sandbox");
        assert_eq!(ready.adapter, STRIPE_LIKE_SANDBOX_ADAPTER);
        assert!(
            ready
                .signature_format_support
                .formats
                .contains(&"stripe_like:t=<unix_timestamp>,v1=<hmac_sha256_hex>")
        );
        assert_eq!(ready.signature_verifier_status, "configured-not-validated");
        assert!(ready.merchant_connected);
        assert_eq!(ready.credential_status, "enabled");
        assert!(ready.credential_fingerprint_present);
        assert_eq!(
            ready.credential_lifecycle.fingerprint_prefix.as_deref(),
            Some("abc123def4567890")
        );
        assert_eq!(ready.credential_lifecycle.refusal_reason, None);
        assert!(!ready.production_payment_evidence);
        assert!(!ready.credential_value_echoed);
        assert!(!ready.provider_secret_echoed);

        let serialized = serde_json::to_string(&ready).expect("serialize adapter status");
        assert!(!serialized.contains("sk_live"));
        assert!(!serialized.contains("Bearer "));
        assert!(!serialized.contains("postgres://"));
    }

    #[test]
    fn stripe_like_sandbox_adapter_normalizes_capture_event() {
        let readback = normalize_stripe_like_sandbox_event(StripeLikeSandboxAdapterInput {
            provider: "stripe_like".to_string(),
            headers: vec![PaymentProviderHeaderValue {
                name: "Stripe-Signature".to_string(),
                value: format!("t=1710000000,v1={}", "a".repeat(64)),
            }],
            payload_sha256: None,
            signature_verification: None,
            payload: serde_json::json!({
                "id": "evt_capture_1",
                "type": "payment_intent.succeeded",
                "data": {
                    "object": {
                        "id": "pi_123",
                        "amount_received": 1299,
                        "currency": "usd",
                        "metadata": {
                            "tenant_id": "00000000-0000-0000-0000-000000000003",
                            "order_id": "00000000-0000-0000-0000-000000000001",
                            "wallet_id": "00000000-0000-0000-0000-000000000002"
                        }
                    }
                }
            }),
        });

        assert_eq!(readback.adapter, STRIPE_LIKE_SANDBOX_ADAPTER);
        assert_eq!(readback.signature_parse.format, "stripe_like");
        assert_eq!(readback.signature_parse.timestamp, Some(1710000000));
        assert_eq!(
            readback.event_mapping.normalized_event_type,
            Some(PaymentProviderEventType::Capture)
        );
        assert!(readback.provider_event_readback.schema_valid);
        assert!(readback.provider_event_readback.provider_object_id_present);
        let normalized = readback.normalized_event.expect("normalized event");
        assert_eq!(normalized.external_event_id, "evt_capture_1");
        assert_eq!(normalized.amount, "12.99000000");
        assert_eq!(normalized.currency, "USD");
        assert_eq!(normalized.payment_intent_id, None);
        assert!(!readback.raw_webhook_body_echoed);
        assert!(!readback.provider_secret_echoed);
    }

    #[test]
    fn stripe_like_sandbox_adapter_reports_unsupported_event() {
        let readback = normalize_stripe_like_sandbox_event(StripeLikeSandboxAdapterInput {
            provider: "stripe_like".to_string(),
            headers: vec![PaymentProviderHeaderValue {
                name: "x-fubox-payment-signature".to_string(),
                value: format!("sha256={}", "b".repeat(64)),
            }],
            payload_sha256: None,
            signature_verification: None,
            payload: serde_json::json!({
                "id": "evt_unknown_1",
                "type": "customer.created",
                "data": { "object": { "id": "cus_1", "amount": 100, "currency": "usd" } }
            }),
        });

        assert_eq!(readback.signature_parse.format, "fubox_simulated_sha256");
        assert!(!readback.event_mapping.supported);
        assert_eq!(
            readback.unsupported_reason,
            Some("event_type_not_supported")
        );
        assert!(readback.normalized_event.is_none());
    }

    #[test]
    fn stripe_like_signature_verification_uses_timestamped_payload_basis() {
        let body = br#"{"id":"evt_1","type":"payment_intent.succeeded"}"#;
        let timestamp = 1_710_000_000_i64;
        let signature = hmac_sha256_hex(
            b"whsec_test",
            stripe_like_signed_payload(timestamp, body).as_bytes(),
        );
        let readback = verify_stripe_like_signature_headers(
            &[PaymentProviderHeaderValue {
                name: "Stripe-Signature".to_string(),
                value: format!("t={timestamp},v1={signature}"),
            }],
            body,
            "whsec_test",
            timestamp + 120,
        );

        assert_eq!(readback.status, "verified");
        assert_eq!(readback.signed_payload_basis, "stripe:t.raw_body");
        assert!(readback.replay_window_ok);
        assert!(readback.signature_match);
        assert_eq!(readback.timestamp_age_seconds, Some(120));
        assert!(!readback.raw_payload_echoed);
        assert!(!readback.secret_echoed);
    }

    #[test]
    fn stripe_like_signature_verification_refuses_replay_window() {
        let body = br#"{"id":"evt_1","type":"payment_intent.succeeded"}"#;
        let timestamp = 1_710_000_000_i64;
        let signature = hmac_sha256_hex(
            b"whsec_test",
            stripe_like_signed_payload(timestamp, body).as_bytes(),
        );
        let readback = verify_stripe_like_signature_headers(
            &[PaymentProviderHeaderValue {
                name: "Stripe-Signature".to_string(),
                value: format!("t={timestamp},v1={signature}"),
            }],
            body,
            "whsec_test",
            timestamp + 301,
        );

        assert_eq!(readback.status, "refused");
        assert_eq!(
            readback.mismatch_reason,
            Some("signature_replay_window_refused")
        );
        assert!(!readback.replay_window_ok);
    }

    #[test]
    fn stripe_like_adapter_refuses_missing_provider_object_id() {
        let readback = normalize_stripe_like_sandbox_event(StripeLikeSandboxAdapterInput {
            provider: "stripe_like".to_string(),
            headers: vec![PaymentProviderHeaderValue {
                name: "Stripe-Signature".to_string(),
                value: format!("t=1710000000,v1={}", "c".repeat(64)),
            }],
            payload_sha256: None,
            signature_verification: None,
            payload: serde_json::json!({
                "id": "evt_capture_1",
                "type": "payment_intent.succeeded",
                "data": {
                    "object": {
                        "amount_received": 1299,
                        "currency": "usd",
                        "metadata": {
                            "tenant_id": "00000000-0000-0000-0000-000000000003"
                        }
                    }
                }
            }),
        });

        assert_eq!(
            readback.unsupported_reason,
            Some("provider_object_id_missing")
        );
        assert!(!readback.provider_event_readback.schema_valid);
        assert!(readback.normalized_event.is_none());
    }

    #[test]
    fn provider_runtime_readback_is_secret_safe_and_config_needed() {
        let readback = plan_payment_provider_runtime_readback(PaymentProviderHandoffRequest {
            provider: "stripe_like".to_string(),
            event_type: PaymentProviderEventType::Chargeback,
            external_event_id_hash: "hash-event".to_string(),
            amount: "10.00000000".to_string(),
            currency: "USD".to_string(),
            idempotency_key_hash: Some("hash-idempotency".to_string()),
            refs: PaymentProviderRefs {
                payment_capture_id: Some("capture-1".to_string()),
                ledger_entry_id: Some("ledger-1".to_string()),
                audit_id: Some("audit-1".to_string()),
                ..PaymentProviderRefs::default()
            },
        });

        assert_eq!(readback.schema, PAYMENT_PROVIDER_RUNTIME_SKELETON_SCHEMA);
        assert_eq!(readback.action_result, "chargeback_planned_config_needed");
        assert_eq!(readback.signature_verification, "config-needed");
        assert!(!readback.merchant_connected);
        assert!(!readback.production_payment_evidence);
        assert!(readback.secret_safe);
        assert!(!readback.raw_webhook_body_echoed);
        assert!(!readback.raw_idempotency_key_echoed);
        assert!(!readback.authorization_echoed);
        assert!(!readback.provider_secret_echoed);
        assert!(!readback.db_url_echoed);

        let serialized = serde_json::to_string(&readback).expect("serialize readback");
        assert!(!serialized.contains("sk_live"));
        assert!(!serialized.contains("Bearer "));
        assert!(!serialized.contains("postgres://"));
        assert!(!serialized.contains("raw webhook"));
    }

    #[test]
    fn payment_provider_executor_contract_plans_supported_actions_without_secrets() {
        let hash = "a".repeat(64);
        let callback = plan_payment_provider_executor_contract(PaymentProviderExecutorRequest {
            provider: "stripe_like".to_string(),
            action: PaymentProviderExecutorAction::Callback,
            amount: "12.99000000".to_string(),
            currency: "USD".to_string(),
            reason: "signed callback normalized".to_string(),
            idempotency: PaymentProviderExecutorIdempotency::hashed(hash.clone()),
            provider_refs: PaymentProviderExecutorProviderRefs {
                provider_event_ref: PaymentProviderSafeRef::hashed(hash.clone()),
                provider_object_ref: PaymentProviderSafeRef::hashed(hash.clone()),
                ..PaymentProviderExecutorProviderRefs::default()
            },
            local_refs: PaymentProviderRefs {
                order_id: Some("00000000-0000-0000-0000-000000000001".to_string()),
                payment_intent_id: Some("00000000-0000-0000-0000-000000000002".to_string()),
                ..PaymentProviderRefs::default()
            },
            gate: ready_executor_gate(),
        });
        assert_eq!(callback.status, "planned");
        assert_eq!(callback.action_result, "callback_normalized");
        assert!(callback.normalized_executor_result_readback);
        assert_eq!(
            callback.status_mapping.normalized_status,
            "callback_recorded"
        );
        assert_eq!(
            callback.ledger_handoff.handoff_target,
            "payment_events_normalized_callback_readback"
        );
        assert!(!callback.ledger_handoff.ledger_write_performed);

        let capture = plan_payment_provider_executor_contract(PaymentProviderExecutorRequest {
            provider: "stripe_like".to_string(),
            action: PaymentProviderExecutorAction::Capture,
            amount: "12.99000000".to_string(),
            currency: "USD".to_string(),
            reason: "provider callback confirmed capture".to_string(),
            idempotency: PaymentProviderExecutorIdempotency::hashed(hash.clone()),
            provider_refs: PaymentProviderExecutorProviderRefs {
                provider_object_ref: PaymentProviderSafeRef::hashed(hash.clone()),
                ..PaymentProviderExecutorProviderRefs::default()
            },
            local_refs: PaymentProviderRefs {
                order_id: Some("00000000-0000-0000-0000-000000000001".to_string()),
                payment_intent_id: Some("00000000-0000-0000-0000-000000000002".to_string()),
                ..PaymentProviderRefs::default()
            },
            gate: ready_executor_gate(),
        });
        assert_eq!(capture.schema, PAYMENT_PROVIDER_EXECUTOR_CONTRACT_SCHEMA);
        assert_eq!(capture.status, "planned");
        assert_eq!(capture.action_result, "capture_planned");
        assert_eq!(capture.gate_readback.status, "allowed");
        assert!(capture.idempotency_key_hash_present);
        assert_eq!(
            capture.status_mapping.normalized_status,
            "capture_candidate_ready"
        );
        assert!(capture.ledger_handoff.ledger_handoff_required);
        assert!(!capture.ledger_handoff.reversal_handoff_required);
        assert!(capture.secret_safe);

        let refund = plan_payment_provider_executor_contract(PaymentProviderExecutorRequest {
            provider: "stripe_like".to_string(),
            action: PaymentProviderExecutorAction::Refund,
            amount: "5.00000000".to_string(),
            currency: "USD".to_string(),
            reason: "customer requested partial refund".to_string(),
            idempotency: PaymentProviderExecutorIdempotency::hashed(hash.clone()),
            provider_refs: PaymentProviderExecutorProviderRefs {
                refund_ref: PaymentProviderSafeRef::fingerprint("refundfp_1234"),
                ..PaymentProviderExecutorProviderRefs::default()
            },
            local_refs: PaymentProviderRefs {
                payment_capture_id: Some("00000000-0000-0000-0000-000000000003".to_string()),
                refund_id: Some("00000000-0000-0000-0000-000000000004".to_string()),
                ..PaymentProviderRefs::default()
            },
            gate: ready_executor_gate(),
        });
        assert_eq!(refund.status, "planned");
        assert_eq!(refund.action, PaymentProviderExecutorAction::Refund);
        assert_eq!(
            refund.status_mapping.normalized_status,
            "refund_reversal_candidate_ready"
        );
        assert!(refund.ledger_handoff.reversal_handoff_required);
        assert_eq!(
            refund.ledger_handoff.handoff_target,
            "refund_apply_requires_credit_grant_revoke_or_ledger_reversal"
        );
        assert!(!refund.ledger_handoff.direct_merchant_success_forged);

        let chargeback_ack =
            plan_payment_provider_executor_contract(PaymentProviderExecutorRequest {
                provider: "stripe_like".to_string(),
                action: PaymentProviderExecutorAction::ChargebackAck,
                amount: "12.99000000".to_string(),
                currency: "USD".to_string(),
                reason: "dispute acknowledged".to_string(),
                idempotency: PaymentProviderExecutorIdempotency::fingerprint("idemfp_1234"),
                provider_refs: PaymentProviderExecutorProviderRefs {
                    dispute_ref: PaymentProviderSafeRef::hashed(hash),
                    ..PaymentProviderExecutorProviderRefs::default()
                },
                local_refs: PaymentProviderRefs {
                    payment_capture_id: Some("00000000-0000-0000-0000-000000000003".to_string()),
                    reversal_ledger_entry_id: Some(
                        "00000000-0000-0000-0000-000000000005".to_string(),
                    ),
                    ..PaymentProviderRefs::default()
                },
                gate: ready_executor_gate(),
            });
        assert_eq!(chargeback_ack.status, "planned");
        assert_eq!(chargeback_ack.action_result, "chargeback_ack_planned");
        assert_eq!(
            chargeback_ack.status_mapping.normalized_status,
            "chargeback_reversal_candidate_ready"
        );
        assert!(chargeback_ack.ledger_handoff.reversal_handoff_required);
        assert!(!chargeback_ack.raw_webhook_body_echoed);
        assert!(!chargeback_ack.raw_invoice_metadata_echoed);

        let serialized = serde_json::to_string(&chargeback_ack).expect("serialize executor result");
        assert!(!serialized.contains("Authorization"));
        assert!(!serialized.contains("Bearer "));
        assert!(!serialized.contains("sk_live"));
        assert!(!serialized.contains("whsec"));
        assert!(!serialized.contains("raw invoice metadata"));
        assert!(!chargeback_ack.raw_idempotency_key_echoed);
        assert!(!serialized.contains("pi_"));
        assert!(!serialized.contains("evt_"));
    }

    #[test]
    fn payment_provider_executor_refuses_raw_refs_and_blocked_gate() {
        let result = plan_payment_provider_executor_contract(PaymentProviderExecutorRequest {
            provider: "stripe_like".to_string(),
            action: PaymentProviderExecutorAction::Refund,
            amount: "5.00000000".to_string(),
            currency: "USD".to_string(),
            reason: "refund".to_string(),
            idempotency: PaymentProviderExecutorIdempotency::fingerprint("raw-key:refund"),
            provider_refs: PaymentProviderExecutorProviderRefs {
                provider_object_ref: PaymentProviderSafeRef::fingerprint("pi_123"),
                ..PaymentProviderExecutorProviderRefs::default()
            },
            local_refs: PaymentProviderRefs::default(),
            gate: PaymentProviderExecutorGateInput {
                adapter_enabled: true,
                merchant_connected: false,
                credential_present: true,
                credential_fingerprint_present: false,
                signature_verified: false,
            },
        });

        assert_eq!(result.status, "refused");
        assert_eq!(result.action_result, "executor_refused");
        assert_eq!(result.gate_readback.status, "blocked");
        assert_eq!(result.status_mapping.normalized_status, "refused");
        assert_eq!(
            result.status_mapping.refusal_code,
            Some("idempotency_refused")
        );
        assert!(!result.ledger_handoff.ledger_write_performed);
        assert_eq!(
            result.ledger_handoff.handoff_status,
            "blocked_no_local_write_performed"
        );
        assert!(
            result
                .validation_errors
                .contains(&"idempotency_fingerprint_must_not_be_raw")
        );
        assert!(
            result
                .validation_errors
                .contains(&"provider_object_ref_fingerprint_must_not_be_raw")
        );
        assert!(
            result
                .validation_errors
                .contains(&"payment_capture_id_required_for_refund")
        );
        assert!(
            result
                .gate_readback
                .refusal_reasons
                .contains(&"merchant_not_connected")
        );
        assert!(
            result
                .gate_readback
                .refusal_reasons
                .contains(&"signature_not_verified")
        );
        assert!(result.secret_safe);
        assert!(!result.provider_ref_raw_echoed);
    }

    #[test]
    fn payment_provider_executor_request_rejects_raw_payload_fields() {
        let rejected =
            serde_json::from_value::<PaymentProviderExecutorRequest>(serde_json::json!({
                "provider": "stripe_like",
                "action": "capture",
                "amount": "12.99000000",
                "currency": "USD",
                "reason": "capture",
                "idempotency_key": "raw-idempotency-key",
                "authorization": "Bearer sk_live_secret",
                "raw_provider_payload": {"id": "evt_123"},
                "idempotency": {"present": true, "key_hash": "a".repeat(64)},
                "provider_refs": {"provider_object_ref": {"present": true}},
                "local_refs": {},
                "gate": {
                    "adapter_enabled": true,
                    "merchant_connected": true,
                    "credential_present": true,
                    "credential_fingerprint_present": true,
                    "signature_verified": true
                }
            }));

        assert!(rejected.is_err());
    }

    #[test]
    fn payment_provider_executor_contract_fixture_stays_secret_safe() {
        let fixture: serde_json::Value =
            serde_json::from_str(EXECUTOR_CONTRACT_FIXTURE).expect("fixture parses");
        assert_eq!(
            fixture.get("contract").and_then(|value| value.as_str()),
            Some(PAYMENT_PROVIDER_EXECUTOR_CONTRACT_SCHEMA)
        );
        assert_eq!(
            fixture
                .pointer("/secret_safety/raw_provider_payload_allowed")
                .and_then(|value| value.as_bool()),
            Some(false)
        );
        assert_eq!(
            fixture
                .pointer("/secret_safety/raw_idempotency_allowed")
                .and_then(|value| value.as_bool()),
            Some(false)
        );
        assert_eq!(
            fixture
                .pointer("/secret_safety/provider_refs_policy")
                .and_then(|value| value.as_str()),
            Some("presence_hash_or_fingerprint_only")
        );
        let actions = fixture
            .get("actions")
            .and_then(|value| value.as_array())
            .expect("actions array");
        assert!(actions.iter().any(|value| value == "capture"));
        assert!(actions.iter().any(|value| value == "callback"));
        assert!(actions.iter().any(|value| value == "refund"));
        assert!(actions.iter().any(|value| value == "chargeback_ack"));
        assert_eq!(
            fixture
                .pointer("/result_invariants/normalized_executor_result_readback")
                .and_then(|value| value.as_bool()),
            Some(true)
        );
        assert_eq!(
            fixture
                .pointer("/result_invariants/raw_invoice_metadata_echoed")
                .and_then(|value| value.as_bool()),
            Some(false)
        );
    }

    #[test]
    fn stripe_like_client_request_plans_all_supported_operations_without_network() {
        let hash = "b".repeat(64);
        let base_refs = PaymentProviderExecutorProviderRefs {
            provider_object_ref: PaymentProviderSafeRef::hashed(hash.clone()),
            charge_ref: PaymentProviderSafeRef::fingerprint("chargefp_1234"),
            refund_ref: PaymentProviderSafeRef::fingerprint("refundfp_1234"),
            dispute_ref: PaymentProviderSafeRef::fingerprint("disputefp_1234"),
            ..PaymentProviderExecutorProviderRefs::default()
        };

        let cases = [
            (
                StripeLikeClientOperation::RetrievePaymentIntent,
                "GET",
                "/v1/payment_intents/{payment_intent_ref}",
                false,
            ),
            (
                StripeLikeClientOperation::RetrieveCharge,
                "GET",
                "/v1/charges/{charge_ref}",
                false,
            ),
            (
                StripeLikeClientOperation::RetrieveRefund,
                "GET",
                "/v1/refunds/{refund_ref}",
                false,
            ),
            (
                StripeLikeClientOperation::RetrieveDispute,
                "GET",
                "/v1/disputes/{dispute_ref}",
                false,
            ),
            (
                StripeLikeClientOperation::CapturePaymentIntent,
                "POST",
                "/v1/payment_intents/{payment_intent_ref}/capture",
                true,
            ),
            (
                StripeLikeClientOperation::CreateRefund,
                "POST",
                "/v1/refunds",
                true,
            ),
            (
                StripeLikeClientOperation::ChargebackAck,
                "POST",
                "/v1/disputes/{dispute_ref}/close",
                true,
            ),
        ];

        for (operation, method, path_template, idempotency_required) in cases {
            let result = plan_stripe_like_client_request(StripeLikeClientRequest {
                provider: "stripe_like".to_string(),
                operation,
                credential_source: "merchant_secret_ref:primary".to_string(),
                credential_source_ready: true,
                merchant_account_ref_present: true,
                idempotency: if idempotency_required {
                    PaymentProviderExecutorIdempotency::hashed(hash.clone())
                } else {
                    PaymentProviderExecutorIdempotency::default()
                },
                provider_refs: base_refs.clone(),
                amount: Some("12.99000000".to_string()),
                currency: Some("USD".to_string()),
                reason: Some("requested_by_customer".to_string()),
                local_refs: PaymentProviderRefs {
                    payment_capture_id: Some("00000000-0000-0000-0000-000000000003".to_string()),
                    refund_id: Some("00000000-0000-0000-0000-000000000004".to_string()),
                    ..PaymentProviderRefs::default()
                },
            });

            assert_eq!(
                result.schema,
                PAYMENT_PROVIDER_STRIPE_LIKE_CLIENT_PLAN_SCHEMA
            );
            assert_eq!(result.status, "network_disabled_ready");
            assert_eq!(result.request.method, method);
            assert_eq!(result.request.path_template, path_template);
            assert_eq!(
                result.request.idempotency_header_required,
                idempotency_required
            );
            assert_eq!(
                result.request.idempotency_header_present,
                idempotency_required
            );
            assert!(result.request.credential_source_required);
            assert!(result.request.credential_source_ready);
            assert!(result.request.authorization_header_required);
            assert!(!result.request.authorization_header_value_echoed);
            assert!(!result.network_call_performed);
            assert_eq!(result.http_client, "request_plan_only");
            assert!(result.secret_safe);
        }
    }

    #[test]
    fn stripe_like_client_request_readback_is_secret_safe_and_rejects_raw_fields() {
        let result = plan_stripe_like_client_request(StripeLikeClientRequest {
            provider: "stripe_like".to_string(),
            operation: StripeLikeClientOperation::CreateRefund,
            credential_source: "merchant_secret_ref:primary".to_string(),
            credential_source_ready: false,
            merchant_account_ref_present: false,
            idempotency: PaymentProviderExecutorIdempotency::fingerprint("idemfp_1234"),
            provider_refs: PaymentProviderExecutorProviderRefs {
                charge_ref: PaymentProviderSafeRef::fingerprint("chargefp_1234"),
                ..PaymentProviderExecutorProviderRefs::default()
            },
            amount: Some("5.00000000".to_string()),
            currency: Some("USD".to_string()),
            reason: Some("duplicate".to_string()),
            local_refs: PaymentProviderRefs::default(),
        });

        assert_eq!(result.status, "blocked");
        assert!(
            result
                .blocked_reasons
                .contains(&"credential_source_not_ready")
        );
        assert!(
            result
                .blocked_reasons
                .contains(&"merchant_account_ref_missing")
        );
        assert!(!result.network_call_performed);
        assert!(!result.raw_secret_echoed);
        assert!(!result.authorization_echoed);
        assert!(!result.raw_idempotency_key_echoed);
        assert!(!result.raw_provider_payload_echoed);
        assert!(!result.raw_provider_ref_echoed);

        let serialized = serde_json::to_string(&result).expect("serialize client result");
        for forbidden in [
            "sk_live_secret",
            "Bearer sk_live",
            "raw-idempotency-secret",
            "{\"id\":\"pi_raw\"}",
            "pi_raw",
            "ch_raw",
        ] {
            assert!(!serialized.contains(forbidden), "leaked {forbidden}");
        }

        let rejected = serde_json::from_value::<StripeLikeClientRequest>(serde_json::json!({
            "provider": "stripe_like",
            "operation": "create_refund",
            "credential_source": "merchant_secret_ref:primary",
            "credential_source_ready": true,
            "merchant_account_ref_present": true,
            "authorization": "Bearer sk_live_secret",
            "raw_secret": "sk_live_secret",
            "raw_idempotency_key": "raw-idempotency-secret",
            "raw_provider_payload": {"id": "pi_raw"},
            "idempotency": {"present": true, "fingerprint": "idemfp_1234"},
            "provider_refs": {"charge_ref": {"present": true, "fingerprint": "chargefp_1234"}},
            "amount": "5.00000000",
            "currency": "USD",
            "reason": "duplicate",
            "local_refs": {}
        }));
        assert!(rejected.is_err());
    }

    #[test]
    fn stripe_like_client_plan_fixture_documents_secret_safe_contract() {
        let fixture: serde_json::Value =
            serde_json::from_str(STRIPE_LIKE_CLIENT_PLAN_FIXTURE).expect("fixture parses");
        assert_eq!(
            fixture.get("contract").and_then(|value| value.as_str()),
            Some(PAYMENT_PROVIDER_STRIPE_LIKE_CLIENT_PLAN_SCHEMA)
        );
        assert_eq!(
            fixture
                .pointer("/runtime/network_call_performed")
                .and_then(|value| value.as_bool()),
            Some(false)
        );
        assert_eq!(
            fixture
                .pointer("/secret_safety/raw_secret_allowed")
                .and_then(|value| value.as_bool()),
            Some(false)
        );
        assert_eq!(
            fixture
                .pointer("/secret_safety/authorization_value_allowed")
                .and_then(|value| value.as_bool()),
            Some(false)
        );
        let operations = fixture
            .get("operations")
            .and_then(|value| value.as_array())
            .expect("operations array");
        assert!(
            operations
                .iter()
                .any(|value| value == "retrieve_payment_intent")
        );
        assert!(operations.iter().any(|value| value == "retrieve_charge"));
        assert!(operations.iter().any(|value| value == "retrieve_refund"));
        assert!(operations.iter().any(|value| value == "retrieve_dispute"));
        assert!(
            operations
                .iter()
                .any(|value| value == "capture_payment_intent")
        );
        assert!(operations.iter().any(|value| value == "create_refund"));
        assert!(operations.iter().any(|value| value == "chargeback_ack"));
    }

    #[test]
    fn stripe_like_fetch_executor_defaults_to_no_network_and_parses_fixture_summary() {
        let hash = "b".repeat(64);
        let plan = plan_stripe_like_client_request(StripeLikeClientRequest {
            provider: "stripe_like".to_string(),
            operation: StripeLikeClientOperation::RetrievePaymentIntent,
            credential_source: "merchant_secret_ref:primary".to_string(),
            credential_source_ready: true,
            merchant_account_ref_present: true,
            idempotency: PaymentProviderExecutorIdempotency::default(),
            provider_refs: PaymentProviderExecutorProviderRefs {
                provider_object_ref: PaymentProviderSafeRef::hashed(hash),
                ..PaymentProviderExecutorProviderRefs::default()
            },
            amount: None,
            currency: None,
            reason: None,
            local_refs: PaymentProviderRefs::default(),
        });

        let not_loaded = execute_stripe_like_fetch_executor(StripeLikeFetchExecutorRequest {
            provider: plan.provider.clone(),
            request_plan: plan.request.clone(),
            network_enabled: false,
            fixture_response: None,
            response_header_summary: None,
        });
        assert_eq!(
            not_loaded.schema,
            PAYMENT_PROVIDER_STRIPE_LIKE_FETCH_EXECUTOR_SCHEMA
        );
        assert_eq!(not_loaded.status, "object_not_loaded");
        assert!(!not_loaded.network_call_enabled);
        assert!(!not_loaded.network_call_performed);
        assert_eq!(not_loaded.http_client, "not_configured");
        assert_eq!(not_loaded.object_found, None);
        assert!(not_loaded.provider_object_summary.is_none());
        assert!(not_loaded.blocked_reasons.contains(&"network_disabled"));
        assert!(not_loaded.secret_safe);
        assert!(!not_loaded.authorization_echoed);
        assert!(!not_loaded.raw_idempotency_key_echoed);
        assert!(!not_loaded.raw_provider_payload_echoed);

        let fixture = serde_json::json!({
            "id": "pi_fixture_secret_raw",
            "object": "payment_intent",
            "status": "succeeded",
            "amount": 1299,
            "amount_received": 1299,
            "currency": "usd",
            "customer": "cus_fixture_secret_raw",
            "metadata": {"tenant_id": "00000000-0000-0000-0000-000000000003"}
        });
        let parsed =
            NetworkDisabledStripeLikeFetchExecutor.execute(StripeLikeFetchExecutorRequest {
                provider: plan.provider,
                request_plan: plan.request,
                network_enabled: false,
                fixture_response: Some(fixture),
                response_header_summary: Some(StripeLikeResponseHeaderSummaryInput {
                    http_status: Some(429),
                    retry_after_present: true,
                    retry_after_seconds: Some(30),
                    stripe_request_id_present: true,
                    stripe_request_id_hash: Some("a".repeat(64)),
                    rate_limit_category: Some("global".to_string()),
                }),
            });
        assert_eq!(parsed.status, "fixture_parsed");
        assert!(!parsed.network_call_performed);
        assert_eq!(parsed.object_found, Some(true));
        assert!(parsed.fixture_response_parsed);
        assert!(parsed.parser_summary_available);
        let summary = parsed
            .provider_object_summary
            .as_ref()
            .expect("fixture summary");
        assert_eq!(
            summary.provider_object_type,
            Some(StripeApiObjectType::PaymentIntent)
        );
        assert_eq!(
            summary.provider_object_type_raw.as_deref(),
            Some("payment_intent")
        );
        assert_eq!(summary.amount.as_deref(), Some("12.99000000"));
        assert_eq!(summary.currency.as_deref(), Some("USD"));
        assert!(summary.provider_object_id_hash.is_some());
        assert_eq!(parsed.request_builder.method, "GET");
        assert_eq!(
            parsed.request_builder.path_template,
            "/v1/payment_intents/{payment_intent_ref}"
        );
        assert!(!parsed.request_builder.authorization_header_present);
        assert_eq!(parsed.request_builder.timeout.request_timeout_ms, 10_000);
        assert_eq!(parsed.request_builder.retry_policy.max_attempts, 2);
        assert!(parsed.response_header_summary.retry_after_present);
        assert_eq!(parsed.response_header_summary.retry_after_seconds, Some(30));
        assert!(parsed.response_header_summary.stripe_request_id_present);
        assert_eq!(
            parsed
                .response_header_summary
                .rate_limit_category
                .as_deref(),
            Some("global")
        );
        assert!(parsed.response_header_summary.should_retry);
        assert_eq!(
            parsed.response_header_summary.backoff_reason,
            "retry_after_header"
        );
        assert_eq!(parsed.rate_limit_readback, parsed.response_header_summary);

        let serialized = serde_json::to_string(&parsed).expect("serialize executor result");
        for forbidden in [
            "pi_fixture_secret_raw",
            "cus_fixture_secret_raw",
            "Bearer sk_live",
            "raw-idempotency-secret",
        ] {
            assert!(!serialized.contains(forbidden), "leaked {forbidden}");
        }
    }

    #[test]
    fn reqwest_stripe_like_fetch_executor_reports_config_boundary_without_network_send() {
        let hash = "c".repeat(64);
        let plan = plan_stripe_like_client_request(StripeLikeClientRequest {
            provider: "stripe_like".to_string(),
            operation: StripeLikeClientOperation::CapturePaymentIntent,
            credential_source: "merchant_secret_ref:primary".to_string(),
            credential_source_ready: true,
            merchant_account_ref_present: true,
            idempotency: PaymentProviderExecutorIdempotency::hashed("d".repeat(64)),
            provider_refs: PaymentProviderExecutorProviderRefs {
                provider_object_ref: PaymentProviderSafeRef::hashed(hash),
                ..PaymentProviderExecutorProviderRefs::default()
            },
            amount: Some("12.99000000".to_string()),
            currency: Some("USD".to_string()),
            reason: Some("capture_after_invoice".to_string()),
            local_refs: PaymentProviderRefs::default(),
        });

        let disabled = ReqwestStripeLikeFetchExecutor::not_configured(false).execute(
            StripeLikeFetchExecutorRequest {
                provider: plan.provider.clone(),
                request_plan: plan.request.clone(),
                network_enabled: true,
                fixture_response: None,
                response_header_summary: None,
            },
        );
        assert_eq!(disabled.status, "object_not_loaded");
        assert!(!disabled.network_call_enabled);
        assert!(disabled.blocked_reasons.contains(&"network_disabled"));

        let not_configured = ReqwestStripeLikeFetchExecutor::not_configured(true).execute(
            StripeLikeFetchExecutorRequest {
                provider: plan.provider.clone(),
                request_plan: plan.request.clone(),
                network_enabled: true,
                fixture_response: None,
                response_header_summary: None,
            },
        );
        assert_eq!(not_configured.status, "network_client_not_configured");
        assert_eq!(not_configured.http_client, "reqwest_not_configured");
        assert!(
            not_configured
                .blocked_reasons
                .contains(&"network_client_not_configured")
        );
        assert!(
            not_configured
                .blocked_reasons
                .contains(&"http_client_not_configured")
        );
        assert!(
            not_configured
                .blocked_reasons
                .contains(&"runtime_secret_not_configured")
        );
        assert_eq!(not_configured.request_builder.method, "POST");
        assert_eq!(
            not_configured.request_builder.path_template,
            "/v1/payment_intents/{payment_intent_ref}/capture"
        );
        assert!(not_configured.request_builder.idempotency_header_present);
        assert!(!not_configured.request_builder.authorization_header_present);
        assert!(
            not_configured
                .request_builder
                .body_fields
                .iter()
                .any(|field| field.name == "amount_to_capture" && field.value_present)
        );
        assert_eq!(
            not_configured.request_builder.timeout.connect_timeout_ms,
            2_000
        );
        assert!(not_configured.request_builder.retry_policy.retry_on_429);
        assert_eq!(not_configured.client_handoff.status, "blocked");
        assert!(!not_configured.client_handoff.runtime_secret_ref_resolved);
        assert!(!not_configured.client_handoff.reqwest_client_configured);
        assert!(!not_configured.client_handoff.object_fetch_would_be_sent);
        assert!(
            not_configured
                .client_handoff
                .object_fetch_blocked_reasons
                .contains(&"runtime_secret_not_configured")
        );
        assert_eq!(
            not_configured
                .client_handoff
                .source_of_truth_handoff
                .adapter,
            "stripe_api_source_of_truth.fetch_adapter"
        );
        assert!(!not_configured.network_call_performed);
        assert!(not_configured.secret_safe);
        assert!(!not_configured.authorization_echoed);
        assert!(!not_configured.raw_secret_echoed);
        assert!(!not_configured.raw_provider_payload_echoed);

        let configured_client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .expect("reqwest client should build");
        let configured = ReqwestStripeLikeFetchExecutor::from_reqwest_client(
            configured_client,
            ReqwestStripeLikeFetchExecutorConfig {
                network_enabled: true,
                runtime_secret_present: true,
                connect_timeout_ms: 1_500,
                request_timeout_ms: 8_000,
                response_body_timeout_ms: 7_000,
                max_retry_attempts: 3,
            },
        )
        .execute(StripeLikeFetchExecutorRequest {
            provider: plan.provider,
            request_plan: plan.request,
            network_enabled: true,
            fixture_response: None,
            response_header_summary: None,
        });
        assert_eq!(configured.status, "network_ready_not_executed");
        assert_eq!(configured.http_client, "reqwest_configured");
        assert!(configured.request_builder.authorization_header_present);
        assert_eq!(
            configured.client_handoff.status,
            "object_fetch_would_be_sent_but_network_suppressed"
        );
        assert!(configured.client_handoff.runtime_secret_ref_resolved);
        assert!(configured.client_handoff.reqwest_client_configured);
        assert!(configured.client_handoff.request_builder_configured);
        assert!(configured.client_handoff.object_fetch_would_be_sent);
        assert!(
            configured
                .client_handoff
                .object_fetch_blocked_reasons
                .is_empty()
        );
        assert_eq!(
            configured
                .client_handoff
                .source_of_truth_handoff
                .required_provider_object_summary_schema,
            PAYMENT_PROVIDER_STRIPE_LIKE_SOURCE_OF_TRUTH_SUMMARY_SCHEMA
        );
        assert!(!configured.client_handoff.network_call_performed);
        assert!(!configured.client_handoff.authorization_echoed);
        assert!(!configured.client_handoff.raw_secret_echoed);
        assert!(!configured.client_handoff.raw_provider_ref_echoed);
        assert!(!configured.client_handoff.raw_headers_echoed);
        assert!(!configured.client_handoff.raw_body_echoed);
        assert_eq!(configured.request_builder.timeout.request_timeout_ms, 8_000);
        assert_eq!(configured.request_builder.retry_policy.max_attempts, 3);
        assert!(!configured.network_call_performed);
    }

    #[test]
    fn stripe_like_client_handoff_fixture_documents_real_client_boundary_without_network() {
        let fixture: serde_json::Value =
            serde_json::from_str(STRIPE_LIKE_CLIENT_HANDOFF_FIXTURE).expect("fixture parses");
        assert_eq!(
            fixture.get("contract").and_then(|value| value.as_str()),
            Some(PAYMENT_PROVIDER_STRIPE_LIKE_CLIENT_HANDOFF_SCHEMA)
        );
        assert_eq!(
            fixture
                .pointer("/runtime/network_call_performed")
                .and_then(|value| value.as_bool()),
            Some(false)
        );
        assert_eq!(
            fixture
                .pointer("/handoff/object_fetch_would_be_sent")
                .and_then(|value| value.as_bool()),
            Some(true)
        );
        assert_eq!(
            fixture
                .pointer("/source_of_truth_handoff/fetch_adapter_schema")
                .and_then(|value| value.as_str()),
            Some(PAYMENT_PROVIDER_STRIPE_API_FETCH_ADAPTER_SCHEMA)
        );
        assert_eq!(
            fixture
                .pointer("/secret_safety/raw_headers_allowed")
                .and_then(|value| value.as_bool()),
            Some(false)
        );
    }

    #[test]
    fn stripe_like_response_object_reconciliation_maps_matched_mismatch_and_blocked_safely() {
        let payment_intent_id = "00000000-0000-0000-0000-000000000002";
        let capture_summary = summarize_stripe_like_provider_object(
            "stripe_like",
            &serde_json::json!({
                "id": "pi_fixture_secret_raw",
                "object": "payment_intent",
                "status": "succeeded",
                "amount": 1299,
                "amount_received": 1299,
                "currency": "usd",
                "metadata": {
                    "payment_intent_id": payment_intent_id
                }
            }),
        );
        let header = stripe_like_response_header_summary_readback(Some(
            &StripeLikeResponseHeaderSummaryInput {
                http_status: Some(200),
                retry_after_present: false,
                retry_after_seconds: None,
                stripe_request_id_present: true,
                stripe_request_id_hash: Some("a".repeat(64)),
                rate_limit_category: None,
            },
        ));
        let matched = map_stripe_like_response_object_reconciliation(
            "stripe_like",
            PaymentProviderExecutorAction::Capture,
            "12.99000000",
            "USD",
            &PaymentProviderExecutorIdempotency::hashed("c".repeat(64)),
            &PaymentProviderRefs {
                payment_intent_id: Some(payment_intent_id.to_string()),
                ..PaymentProviderRefs::default()
            },
            Some(&capture_summary),
            &header,
        );
        assert_eq!(
            matched.schema,
            PAYMENT_PROVIDER_STRIPE_LIKE_RESPONSE_OBJECT_RECONCILIATION_SCHEMA
        );
        assert_eq!(matched.status, "matched");
        assert!(matched.matched);
        assert_eq!(
            matched.source_of_truth_candidate,
            "capture_source_of_truth_candidate"
        );
        assert!(matched.idempotency_key_hash_present);
        assert!(matched.idempotency_safe_marker_present);
        assert!(matched.source_object_presence.payment_intent_object_present);
        assert_eq!(matched.amount_matches, Some(true));
        assert_eq!(matched.currency_matches, Some(true));
        assert_eq!(matched.local_refs_match, Some(true));
        assert!(!matched.retry_recommended);
        assert_eq!(
            matched.safe_next_action,
            "accept_reconciliation_candidate_then_apply_or_replay_local_action"
        );

        let mismatched = map_stripe_like_response_object_reconciliation(
            "stripe_like",
            PaymentProviderExecutorAction::Capture,
            "13.00000000",
            "EUR",
            &PaymentProviderExecutorIdempotency::fingerprint("idem_fp_capture"),
            &PaymentProviderRefs {
                payment_intent_id: Some("00000000-0000-0000-0000-000000000009".to_string()),
                ..PaymentProviderRefs::default()
            },
            Some(&capture_summary),
            &header,
        );
        assert_eq!(mismatched.status, "mismatch");
        assert!(!mismatched.matched);
        assert!(
            mismatched
                .mismatch_reasons
                .contains(&"provider_amount_mismatch")
        );
        assert!(
            mismatched
                .mismatch_reasons
                .contains(&"provider_currency_mismatch")
        );
        assert!(
            mismatched
                .mismatch_reasons
                .contains(&"provider_local_ref_mismatch")
        );
        assert!(!mismatched.retry_recommended);
        assert_eq!(
            mismatched.safe_next_action,
            "do_not_apply_local_action_review_mismatch_reasons"
        );

        let retry_header = stripe_like_response_header_summary_readback(Some(
            &StripeLikeResponseHeaderSummaryInput {
                http_status: Some(429),
                retry_after_present: true,
                retry_after_seconds: Some(30),
                stripe_request_id_present: true,
                stripe_request_id_hash: Some("b".repeat(64)),
                rate_limit_category: Some("global".to_string()),
            },
        ));
        let blocked = map_stripe_like_response_object_reconciliation(
            "stripe_like",
            PaymentProviderExecutorAction::Refund,
            "5.00000000",
            "USD",
            &PaymentProviderExecutorIdempotency::default(),
            &PaymentProviderRefs::default(),
            None,
            &retry_header,
        );
        assert_eq!(blocked.status, "blocked");
        assert!(blocked.retry_recommended);
        assert!(!blocked.idempotency_safe_marker_present);
        assert_eq!(blocked.retry_reason, "retry_after_header");
        assert_eq!(
            blocked.safe_next_action,
            "retry_provider_object_fetch_after_backoff_without_local_write"
        );

        let serialized =
            serde_json::to_string(&vec![matched, mismatched, blocked]).expect("serialize");
        for forbidden in [
            "pi_fixture_secret_raw",
            payment_intent_id,
            "Bearer sk_live",
            "raw-idempotency-secret",
        ] {
            assert!(!serialized.contains(forbidden), "leaked {forbidden}");
        }
    }

    #[test]
    fn stripe_like_provider_object_summary_reduces_source_of_truth_objects_without_secrets() {
        let fixture: serde_json::Value =
            serde_json::from_str(STRIPE_LIKE_SOURCE_OF_TRUTH_FIXTURE).expect("fixture parses");
        assert_eq!(
            fixture.get("contract").and_then(|value| value.as_str()),
            Some(PAYMENT_PROVIDER_STRIPE_LIKE_SOURCE_OF_TRUTH_SUMMARY_SCHEMA)
        );
        assert_eq!(
            fixture
                .pointer("/runtime/network_call_performed")
                .and_then(|value| value.as_bool()),
            Some(false)
        );

        let objects = fixture
            .get("objects")
            .and_then(|value| value.as_array())
            .expect("objects array");
        for case in objects {
            let provider = case
                .get("provider")
                .and_then(|value| value.as_str())
                .expect("provider");
            let object = case.get("object").expect("object");
            let expected = case.get("expected").expect("expected");
            let summary = summarize_stripe_like_provider_object(provider, object);
            let serialized = serde_json::to_string(&summary).expect("serialize summary");
            let summary_json = serde_json::to_value(&summary).expect("summary json");

            assert_eq!(
                summary_json.get("schema").and_then(|value| value.as_str()),
                Some(PAYMENT_PROVIDER_STRIPE_LIKE_SOURCE_OF_TRUTH_SUMMARY_SCHEMA)
            );
            assert_eq!(
                summary_json
                    .get("provider_object_type_raw")
                    .and_then(|value| value.as_str()),
                expected.get("type").and_then(|value| value.as_str())
            );
            assert_eq!(
                summary_json.get("status").and_then(|value| value.as_str()),
                expected.get("status").and_then(|value| value.as_str())
            );
            assert_eq!(
                summary_json.get("amount").and_then(|value| value.as_str()),
                expected.get("amount").and_then(|value| value.as_str())
            );
            assert_eq!(
                summary_json
                    .get("currency")
                    .and_then(|value| value.as_str()),
                expected.get("currency").and_then(|value| value.as_str())
            );
            assert_eq!(
                summary_json
                    .pointer("/local_refs/local_ref_count")
                    .and_then(|value| value.as_u64()),
                expected
                    .get("local_ref_count")
                    .and_then(|value| value.as_u64())
            );
            assert_eq!(
                summary_json
                    .pointer("/captured/present")
                    .and_then(|value| value.as_bool()),
                expected.get("captured").and_then(|value| value.as_bool())
            );
            assert_eq!(
                summary_json
                    .pointer("/refunded/present")
                    .and_then(|value| value.as_bool()),
                expected.get("refunded").and_then(|value| value.as_bool())
            );
            assert_eq!(
                summary_json
                    .pointer("/disputed/present")
                    .and_then(|value| value.as_bool()),
                expected.get("disputed").and_then(|value| value.as_bool())
            );
            assert!(summary.provider_object_id_present);
            assert!(summary.provider_object_id_hash.is_some());
            assert!(summary.missing_field_reasons.is_empty());
            assert!(summary.unsupported_field_reasons.is_empty());
            assert!(summary.secret_safe);
            assert!(!summary.raw_provider_payload_echoed);
            assert!(!summary.raw_customer_echoed);
            assert!(!summary.raw_email_echoed);
            assert!(!summary.raw_payment_method_echoed);
            assert!(!summary.raw_receipt_url_echoed);
            assert!(!summary.raw_billing_details_echoed);

            for forbidden in fixture
                .get("forbidden_terms")
                .and_then(|value| value.as_array())
                .expect("forbidden terms")
                .iter()
                .filter_map(|value| value.as_str())
            {
                assert!(
                    !serialized.contains(forbidden),
                    "summary leaked forbidden term {forbidden}"
                );
            }
        }
    }

    #[test]
    fn stripe_like_provider_object_summary_reports_missing_and_unsupported_reasons() {
        let fixture: serde_json::Value =
            serde_json::from_str(STRIPE_LIKE_SOURCE_OF_TRUTH_FIXTURE).expect("fixture parses");
        let negative_objects = fixture
            .get("negative_objects")
            .and_then(|value| value.as_array())
            .expect("negative objects array");

        for case in negative_objects {
            let provider = case
                .get("provider")
                .and_then(|value| value.as_str())
                .expect("provider");
            let summary = summarize_stripe_like_provider_object(
                provider,
                case.get("object").expect("object"),
            );
            for expected_missing in case
                .get("expected_missing")
                .and_then(|value| value.as_array())
                .expect("expected missing")
                .iter()
                .filter_map(|value| value.as_str())
            {
                assert!(
                    summary.missing_field_reasons.contains(&expected_missing),
                    "missing reasons should contain {expected_missing}"
                );
            }
            for expected_unsupported in case
                .get("expected_unsupported")
                .and_then(|value| value.as_array())
                .expect("expected unsupported")
                .iter()
                .filter_map(|value| value.as_str())
            {
                assert!(
                    summary
                        .unsupported_field_reasons
                        .contains(&expected_unsupported),
                    "unsupported reasons should contain {expected_unsupported}"
                );
            }
            assert!(summary.sensitive_field_presence_detected);
            assert!(summary.secret_safe);
        }
    }

    fn ready_executor_gate() -> PaymentProviderExecutorGateInput {
        PaymentProviderExecutorGateInput {
            adapter_enabled: true,
            merchant_connected: true,
            credential_present: true,
            credential_fingerprint_present: true,
            signature_verified: true,
        }
    }
}
