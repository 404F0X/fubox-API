use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fmt;
use uuid::Uuid;

#[derive(Clone, PartialEq, Serialize, Deserialize)]
pub struct VirtualKey {
    pub id: Uuid,
    pub tenant_id: Uuid,
    pub project_id: Uuid,
    pub name: String,
    pub key_prefix: String,
    #[serde(skip_serializing)]
    pub secret_hash: String,
    pub status: String,
    pub default_profile_id: Option<Uuid>,
    pub ip_allowlist: Value,
    pub rate_limit_policy: Value,
    pub budget_policy: Value,
    pub metadata: Value,
}

impl fmt::Debug for VirtualKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("VirtualKey")
            .field("id", &self.id)
            .field("tenant_id", &self.tenant_id)
            .field("project_id", &self.project_id)
            .field("name", &self.name)
            .field("key_prefix", &self.key_prefix)
            .field("secret_hash", &"[REDACTED]")
            .field("status", &self.status)
            .field("default_profile_id", &self.default_profile_id)
            .field("ip_allowlist", &self.ip_allowlist)
            .field("rate_limit_policy", &self.rate_limit_policy)
            .field("budget_policy", &self.budget_policy)
            .field("metadata", &self.metadata)
            .finish()
    }
}

#[derive(Clone, PartialEq, Serialize, Deserialize)]
pub struct NewVirtualKey {
    pub id: Uuid,
    pub tenant_id: Uuid,
    pub project_id: Uuid,
    pub name: String,
    pub key_prefix: String,
    #[serde(skip_serializing)]
    pub secret_hash: String,
    pub status: String,
    pub default_profile_id: Uuid,
    pub ip_allowlist: Value,
    pub rate_limit_policy: Value,
    pub budget_policy: Value,
    pub metadata: Value,
}

impl fmt::Debug for NewVirtualKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("NewVirtualKey")
            .field("id", &self.id)
            .field("tenant_id", &self.tenant_id)
            .field("project_id", &self.project_id)
            .field("name", &self.name)
            .field("key_prefix", &self.key_prefix)
            .field("secret_hash", &"[REDACTED]")
            .field("status", &self.status)
            .field("default_profile_id", &self.default_profile_id)
            .field("ip_allowlist", &self.ip_allowlist)
            .field("rate_limit_policy", &self.rate_limit_policy)
            .field("budget_policy", &self.budget_policy)
            .field("metadata", &self.metadata)
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ApiKeyProfile {
    pub id: Uuid,
    pub tenant_id: Uuid,
    pub project_id: Uuid,
    pub name: String,
    pub inbound_protocol: String,
    pub default_protocol_mode: String,
    pub model_aliases: Value,
    pub allowed_models: Value,
    pub denied_models: Value,
    pub allowed_channel_tags: Value,
    pub blocked_provider_ids: Value,
    pub trace_header_rules: Value,
    pub ip_allowlist: Value,
    pub request_overrides: Value,
    pub payload_policy_id: Option<Uuid>,
    pub status: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NewApiKeyProfile {
    pub tenant_id: Uuid,
    pub project_id: Uuid,
    pub name: String,
    pub inbound_protocol: String,
    pub default_protocol_mode: String,
    pub model_aliases: Value,
    pub allowed_models: Value,
    pub denied_models: Value,
    pub allowed_channel_tags: Value,
    pub blocked_provider_ids: Value,
    pub trace_header_rules: Value,
    pub ip_allowlist: Value,
    pub request_overrides: Value,
    pub payload_policy_id: Option<Uuid>,
    pub status: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UpdateApiKeyProfile {
    pub name: String,
    pub inbound_protocol: String,
    pub default_protocol_mode: String,
    pub model_aliases: Value,
    pub allowed_models: Value,
    pub denied_models: Value,
    pub allowed_channel_tags: Value,
    pub blocked_provider_ids: Value,
    pub trace_header_rules: Value,
    pub ip_allowlist: Value,
    pub request_overrides: Value,
    pub payload_policy_id: Option<Uuid>,
    pub status: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Provider {
    pub id: Uuid,
    pub tenant_id: Uuid,
    pub code: String,
    pub name: String,
    pub status: String,
    pub metadata: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NewProvider {
    pub tenant_id: Uuid,
    pub code: String,
    pub name: String,
    pub status: String,
    pub metadata: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UpdateProvider {
    pub code: String,
    pub name: String,
    pub status: String,
    pub metadata: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Channel {
    pub id: Uuid,
    pub tenant_id: Uuid,
    pub provider_id: Uuid,
    pub name: String,
    pub endpoint: String,
    pub protocol_mode: String,
    pub status: String,
    pub region: Option<String>,
    pub priority: i32,
    pub weight: i32,
    pub tags: Value,
    pub model_mappings: Value,
    pub request_overrides: Value,
    pub timeout_policy: Value,
    pub probe_policy: Value,
    pub health_score: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NewChannel {
    pub tenant_id: Uuid,
    pub provider_id: Uuid,
    pub name: String,
    pub endpoint: String,
    pub protocol_mode: String,
    pub status: String,
    pub region: Option<String>,
    pub priority: i32,
    pub weight: i32,
    pub tags: Value,
    pub model_mappings: Value,
    pub request_overrides: Value,
    pub timeout_policy: Value,
    pub probe_policy: Value,
    pub health_score: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UpdateChannel {
    pub provider_id: Uuid,
    pub name: String,
    pub endpoint: String,
    pub protocol_mode: String,
    pub status: String,
    pub region: Option<String>,
    pub priority: i32,
    pub weight: i32,
    pub tags: Value,
    pub model_mappings: Value,
    pub request_overrides: Value,
    pub timeout_policy: Value,
    pub probe_policy: Value,
    pub health_score: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProviderKey {
    pub id: Uuid,
    pub tenant_id: Uuid,
    pub channel_id: Uuid,
    pub key_alias: String,
    pub has_secret_fingerprint: bool,
    pub status: String,
    pub health_score: f64,
    pub cooldown_until: Option<String>,
    pub last_error_code: Option<String>,
    pub rpm_limit: Option<i32>,
    pub tpm_limit: Option<i32>,
    pub concurrency_limit: Option<i32>,
    pub current_window_state: Value,
    pub metadata: Value,
    pub secret_redacted: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RecoveryProbeCandidate {
    pub tenant_id: Uuid,
    pub provider_id: Uuid,
    pub provider_code: String,
    pub provider_name: String,
    pub channel_id: Uuid,
    pub channel_name: String,
    pub channel_endpoint: String,
    pub channel_protocol_mode: String,
    pub channel_status: String,
    pub provider_key_id: Uuid,
    pub key_alias: String,
    pub provider_key_status: String,
    pub provider_key_health_score: f64,
    pub cooldown_until: Option<String>,
    pub last_error_code: Option<String>,
    pub has_secret_fingerprint: bool,
    pub secret_redacted: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NewProviderKey {
    pub id: Uuid,
    pub tenant_id: Uuid,
    pub channel_id: Uuid,
    pub key_alias: String,
    pub encrypted_secret: String,
    pub secret_fingerprint: String,
    pub status: String,
    pub metadata: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CanonicalModel {
    pub id: Uuid,
    pub tenant_id: Uuid,
    pub model_key: String,
    pub display_name: String,
    pub family: Option<String>,
    pub capabilities: Value,
    pub context_length: Option<i32>,
    pub max_output_tokens: Option<i32>,
    pub supports_stream: bool,
    pub supports_tools: bool,
    pub supports_vision: bool,
    pub supports_audio: bool,
    pub supports_reasoning: bool,
    pub visibility: String,
    pub status: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NewCanonicalModel {
    pub tenant_id: Uuid,
    pub model_key: String,
    pub display_name: String,
    pub family: Option<String>,
    pub capabilities: Value,
    pub context_length: Option<i32>,
    pub max_output_tokens: Option<i32>,
    pub supports_stream: bool,
    pub supports_tools: bool,
    pub supports_vision: bool,
    pub supports_audio: bool,
    pub supports_reasoning: bool,
    pub visibility: String,
    pub status: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UpdateCanonicalModel {
    pub model_key: String,
    pub display_name: String,
    pub family: Option<String>,
    pub capabilities: Value,
    pub context_length: Option<i32>,
    pub max_output_tokens: Option<i32>,
    pub supports_stream: bool,
    pub supports_tools: bool,
    pub supports_vision: bool,
    pub supports_audio: bool,
    pub supports_reasoning: bool,
    pub visibility: String,
    pub status: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ModelAssociation {
    pub id: Uuid,
    pub tenant_id: Uuid,
    pub canonical_model_id: Uuid,
    pub association_type: String,
    pub channel_id: Option<Uuid>,
    pub channel_tag: Option<String>,
    pub model_pattern: Option<String>,
    pub upstream_model_name: Option<String>,
    pub priority: i32,
    pub conditions: Value,
    pub fallback_allowed: bool,
    pub canary_percent: f64,
    pub status: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NewModelAssociation {
    pub tenant_id: Uuid,
    pub canonical_model_id: Uuid,
    pub association_type: String,
    pub channel_id: Option<Uuid>,
    pub channel_tag: Option<String>,
    pub model_pattern: Option<String>,
    pub upstream_model_name: Option<String>,
    pub priority: i32,
    pub conditions: Value,
    pub fallback_allowed: bool,
    pub canary_percent: f64,
    pub status: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UpdateModelAssociation {
    pub canonical_model_id: Uuid,
    pub association_type: String,
    pub channel_id: Option<Uuid>,
    pub channel_tag: Option<String>,
    pub model_pattern: Option<String>,
    pub upstream_model_name: Option<String>,
    pub priority: i32,
    pub conditions: Value,
    pub fallback_allowed: bool,
    pub canary_percent: f64,
    pub status: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AuditLog {
    pub id: Uuid,
    pub tenant_id: Uuid,
    pub actor_user_id: Option<Uuid>,
    pub request_id: Option<Uuid>,
    pub action: String,
    pub resource_type: String,
    pub resource_id: Option<Uuid>,
    pub resource_tenant_id: Option<Uuid>,
    pub before_snapshot: Option<Value>,
    pub after_snapshot: Option<Value>,
    pub metadata: Value,
    pub created_at: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NewAuditLog {
    pub tenant_id: Uuid,
    pub actor_session_id: Option<Uuid>,
    pub request_id: Option<Uuid>,
    pub action: String,
    pub resource_type: String,
    pub resource_id: Option<Uuid>,
    pub resource_tenant_id: Option<Uuid>,
    pub before_snapshot: Option<Value>,
    pub after_snapshot: Option<Value>,
    pub metadata: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RouteCandidate {
    pub association: ModelAssociation,
    pub channel: Channel,
    pub provider: Provider,
    pub resolved_upstream_model_name: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RouteCandidates {
    pub canonical_model: CanonicalModel,
    pub candidates: Vec<RouteCandidate>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RequestLog {
    pub id: Uuid,
    pub tenant_id: Uuid,
    pub project_id: Option<Uuid>,
    pub virtual_key_id: Option<Uuid>,
    pub api_key_profile_id: Option<Uuid>,
    pub trace_id: Option<String>,
    pub thread_id: Option<String>,
    pub client_request_id: Option<String>,
    pub inbound_protocol: Option<String>,
    pub outbound_protocol: Option<String>,
    pub protocol_mode: Option<String>,
    pub requested_model: Option<String>,
    pub canonical_model_id: Option<Uuid>,
    pub upstream_model: Option<String>,
    pub resolved_provider_id: Option<Uuid>,
    pub resolved_channel_id: Option<Uuid>,
    pub provider_key_id: Option<Uuid>,
    pub route_policy_version: Option<String>,
    pub status: String,
    pub http_status: Option<i32>,
    pub error_owner: Option<String>,
    pub error_code: Option<String>,
    pub retryable: Option<bool>,
    pub partial_sent: bool,
    pub stream_end_reason: Option<String>,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub final_cost: String,
    pub currency: String,
    pub latency_ms: Option<i32>,
    pub ttft_ms: Option<i32>,
    pub payload_policy_id: Option<Uuid>,
    pub payload_stored: bool,
    pub redaction_status: String,
    pub request_body_hash: Option<String>,
    pub response_body_hash: Option<String>,
    pub created_at: String,
    pub completed_at: Option<String>,
    pub route_decision_snapshot: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RequestLogSummary {
    pub id: Uuid,
    pub tenant_id: Uuid,
    pub project_id: Option<Uuid>,
    pub virtual_key_id: Option<Uuid>,
    pub api_key_profile_id: Option<Uuid>,
    pub trace_id: Option<String>,
    pub thread_id: Option<String>,
    pub client_request_id: Option<String>,
    pub inbound_protocol: Option<String>,
    pub outbound_protocol: Option<String>,
    pub protocol_mode: Option<String>,
    pub requested_model: Option<String>,
    pub canonical_model_id: Option<Uuid>,
    pub upstream_model: Option<String>,
    pub resolved_provider_id: Option<Uuid>,
    pub resolved_channel_id: Option<Uuid>,
    pub provider_key_id: Option<Uuid>,
    pub route_policy_version: Option<String>,
    pub status: String,
    pub http_status: Option<i32>,
    pub error_owner: Option<String>,
    pub error_code: Option<String>,
    pub retryable: Option<bool>,
    pub partial_sent: bool,
    pub stream_end_reason: Option<String>,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub final_cost: String,
    pub currency: String,
    pub latency_ms: Option<i32>,
    pub ttft_ms: Option<i32>,
    pub payload_policy_id: Option<Uuid>,
    pub payload_stored: bool,
    pub redaction_status: String,
    pub request_body_hash: Option<String>,
    pub response_body_hash: Option<String>,
    pub created_at: String,
    pub completed_at: Option<String>,
}

impl From<&RequestLog> for RequestLogSummary {
    fn from(log: &RequestLog) -> Self {
        Self {
            id: log.id,
            tenant_id: log.tenant_id,
            project_id: log.project_id,
            virtual_key_id: log.virtual_key_id,
            api_key_profile_id: log.api_key_profile_id,
            trace_id: log.trace_id.clone(),
            thread_id: log.thread_id.clone(),
            client_request_id: log.client_request_id.clone(),
            inbound_protocol: log.inbound_protocol.clone(),
            outbound_protocol: log.outbound_protocol.clone(),
            protocol_mode: log.protocol_mode.clone(),
            requested_model: log.requested_model.clone(),
            canonical_model_id: log.canonical_model_id,
            upstream_model: log.upstream_model.clone(),
            resolved_provider_id: log.resolved_provider_id,
            resolved_channel_id: log.resolved_channel_id,
            provider_key_id: log.provider_key_id,
            route_policy_version: log.route_policy_version.clone(),
            status: log.status.clone(),
            http_status: log.http_status,
            error_owner: log.error_owner.clone(),
            error_code: log.error_code.clone(),
            retryable: log.retryable,
            partial_sent: log.partial_sent,
            stream_end_reason: log.stream_end_reason.clone(),
            input_tokens: log.input_tokens,
            output_tokens: log.output_tokens,
            final_cost: log.final_cost.clone(),
            currency: log.currency.clone(),
            latency_ms: log.latency_ms,
            ttft_ms: log.ttft_ms,
            payload_policy_id: log.payload_policy_id,
            payload_stored: log.payload_stored,
            redaction_status: log.redaction_status.clone(),
            request_body_hash: log.request_body_hash.clone(),
            response_body_hash: log.response_body_hash.clone(),
            created_at: log.created_at.clone(),
            completed_at: log.completed_at.clone(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RequestLogListFilter {
    pub limit: i64,
    pub status: Option<String>,
    pub model: Option<String>,
    pub canonical_model_id: Option<Uuid>,
    pub channel_id: Option<Uuid>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RequestTraceFilter {
    pub trace_id: String,
    pub limit: i64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PriceVersion {
    pub id: Uuid,
    pub tenant_id: Uuid,
    pub price_book_id: Uuid,
    pub canonical_model_id: Option<Uuid>,
    pub version: String,
    pub pricing_rules: Value,
    pub effective_at: String,
    pub retired_at: Option<String>,
    pub status: String,
    pub created_at: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PriceVersionListFilter {
    pub limit: i64,
    pub price_book_id: Option<Uuid>,
    pub canonical_model_id: Option<Uuid>,
    pub status: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LedgerEntry {
    pub id: Uuid,
    pub tenant_id: Uuid,
    pub project_id: Option<Uuid>,
    pub wallet_id: Option<Uuid>,
    pub request_id: Option<Uuid>,
    pub virtual_key_id: Option<Uuid>,
    pub trace_id: Option<String>,
    pub related_ledger_entry_id: Option<Uuid>,
    pub entry_type: String,
    pub amount: String,
    pub currency: String,
    pub status: String,
    pub idempotency_key: String,
    pub price_version_id: Option<Uuid>,
    pub usage_snapshot: Value,
    pub policy_snapshot: Value,
    pub metadata: Value,
    pub occurred_at: String,
    pub created_at: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LedgerEntryListFilter {
    pub limit: i64,
    pub project_id: Option<Uuid>,
    pub request_id: Option<Uuid>,
    pub wallet_id: Option<Uuid>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BillingReconciliationReportFilter {
    pub day: Option<String>,
    pub discrepancy_limit: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NewRequestLogStarted {
    pub id: Option<Uuid>,
    pub tenant_id: Uuid,
    pub project_id: Option<Uuid>,
    pub virtual_key_id: Option<Uuid>,
    pub api_key_profile_id: Option<Uuid>,
    pub trace_id: Option<String>,
    pub thread_id: Option<String>,
    pub client_request_id: Option<String>,
    pub inbound_protocol: String,
    pub outbound_protocol: String,
    pub protocol_mode: String,
    pub requested_model: Option<String>,
    pub canonical_model_id: Option<Uuid>,
    pub upstream_model: Option<String>,
    pub resolved_provider_id: Option<Uuid>,
    pub resolved_channel_id: Option<Uuid>,
    pub provider_key_id: Option<Uuid>,
    pub route_decision_snapshot: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RequestLogFinalUpdate {
    pub status: String,
    pub http_status: Option<i32>,
    pub error_owner: Option<String>,
    pub error_code: Option<String>,
    pub retryable: Option<bool>,
    pub partial_sent: bool,
    pub stream_end_reason: Option<String>,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub latency_ms: Option<i32>,
    pub ttft_ms: Option<i32>,
    pub final_cost: Option<String>,
    pub currency: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProviderAttempt {
    pub id: Uuid,
    pub tenant_id: Uuid,
    pub request_id: Uuid,
    pub provider_id: Option<Uuid>,
    pub channel_id: Option<Uuid>,
    pub provider_key_id: Option<Uuid>,
    pub attempt_no: i32,
    pub upstream_model: Option<String>,
    pub status: String,
    pub http_status: Option<i32>,
    pub error_owner: Option<String>,
    pub error_code: Option<String>,
    pub retryable: Option<bool>,
    pub fallback_reason: Option<String>,
    pub latency_ms: Option<i32>,
    pub ttft_ms: Option<i32>,
    pub provider_request_id: Option<String>,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub metadata: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NewProviderAttempt {
    pub tenant_id: Uuid,
    pub request_id: Uuid,
    pub provider_id: Option<Uuid>,
    pub channel_id: Option<Uuid>,
    pub provider_key_id: Option<Uuid>,
    pub attempt_no: i32,
    pub upstream_model: Option<String>,
    pub status: String,
    pub http_status: Option<i32>,
    pub error_owner: Option<String>,
    pub error_code: Option<String>,
    pub retryable: Option<bool>,
    pub fallback_reason: Option<String>,
    pub latency_ms: Option<i32>,
    pub ttft_ms: Option<i32>,
    pub provider_request_id: Option<String>,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub metadata: Value,
    pub completed: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProviderAttemptRead {
    pub id: Uuid,
    pub tenant_id: Uuid,
    pub request_id: Uuid,
    pub provider_id: Option<Uuid>,
    pub channel_id: Option<Uuid>,
    pub provider_key_id: Option<Uuid>,
    pub attempt_no: i32,
    pub upstream_model: Option<String>,
    pub status: String,
    pub http_status: Option<i32>,
    pub error_owner: Option<String>,
    pub error_code: Option<String>,
    pub retryable: Option<bool>,
    pub fallback_reason: Option<String>,
    pub latency_ms: Option<i32>,
    pub ttft_ms: Option<i32>,
    pub provider_request_id: Option<String>,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub started_at: String,
    pub completed_at: Option<String>,
}
