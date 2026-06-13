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

#[derive(Debug, Clone, PartialEq)]
pub struct RecoveryProbeSecretMaterial {
    pub tenant_id: Uuid,
    pub provider_id: Uuid,
    pub channel_id: Uuid,
    pub provider_key_id: Uuid,
    pub channel_endpoint: String,
    pub channel_protocol_mode: String,
    pub encrypted_secret: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RecoveryProbeProviderKeyUpdate {
    pub tenant_id: Uuid,
    pub provider_key_id: Uuid,
    pub status: String,
    pub health_score: f64,
    pub last_error_code: Option<String>,
    pub recovery_probe_summary: Value,
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
    pub stream_finalizer: Value,
    pub provider_protocol_summary: Value,
    pub rate_limit_metadata: Value,
    pub openai_compat: Value,
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
            stream_finalizer: request_log_stream_finalizer_projection(
                log.partial_sent,
                log.stream_end_reason.as_deref(),
                log.ttft_ms,
                &log.route_decision_snapshot,
            ),
            provider_protocol_summary: request_log_provider_protocol_summary_projection(
                log.partial_sent,
                log.stream_end_reason.as_deref(),
                &log.route_decision_snapshot,
            ),
            rate_limit_metadata: request_log_rate_limit_metadata_projection(
                &log.route_decision_snapshot,
            ),
            openai_compat: request_log_openai_compat_projection(
                log.partial_sent,
                log.stream_end_reason.as_deref(),
                log.ttft_ms,
                log.input_tokens,
                log.output_tokens,
                log.response_body_hash.as_deref(),
                &log.route_decision_snapshot,
            ),
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

pub fn request_log_openai_compat_projection(
    partial_sent: bool,
    stream_end_reason: Option<&str>,
    ttft_ms: Option<i32>,
    input_tokens: i64,
    output_tokens: i64,
    response_body_hash: Option<&str>,
    route_decision_snapshot: &Value,
) -> Value {
    let compat = route_decision_snapshot.get("openai_compat");
    let stream_finalizer = route_decision_snapshot.get("stream_finalizer");
    let stream_observed = partial_sent || stream_end_reason.is_some() || ttft_ms.is_some();
    let mode = compat
        .and_then(|value| value.get("mode"))
        .and_then(Value::as_str)
        .or_else(|| {
            if stream_finalizer.is_some() || stream_observed {
                Some("stream")
            } else {
                Some("non_stream")
            }
        });
    let status = if compat.is_some() {
        "recorded"
    } else if stream_finalizer.is_some() || stream_observed {
        "config-needed"
    } else {
        "not_recorded"
    };
    let source_schema = compat
        .and_then(|value| value.get("schema"))
        .and_then(Value::as_str);
    let usage = compat
        .and_then(|value| value.get("usage"))
        .unwrap_or(&Value::Null);
    let projected_response_hash = compat
        .and_then(|value| value.get("response_body_hash"))
        .and_then(Value::as_str)
        .or(response_body_hash);
    let x_request_id = compat
        .and_then(|value| value.get("x_request_id"))
        .and_then(Value::as_str);
    let x_request_id_present = compat
        .and_then(|value| value.get("x_request_id_present"))
        .and_then(Value::as_bool)
        .unwrap_or_else(|| x_request_id.is_some());
    let response_id = compat
        .and_then(|value| value.get("response_id"))
        .and_then(Value::as_str);
    let object = compat
        .and_then(|value| value.get("object"))
        .and_then(Value::as_str);
    let finish_reasons = compat
        .and_then(|value| value.get("finish_reasons"))
        .cloned()
        .unwrap_or(Value::Null);
    let finish_reason_present = compat
        .and_then(|value| value.get("finish_reason_present"))
        .and_then(Value::as_bool)
        .unwrap_or_else(|| {
            finish_reasons
                .as_array()
                .map(|reasons| {
                    reasons.iter().any(|reason| {
                        reason
                            .as_str()
                            .is_some_and(|value| !value.trim().is_empty())
                    })
                })
                .unwrap_or(false)
        });
    let usage_present = usage
        .get("observed")
        .and_then(Value::as_bool)
        .or_else(|| usage.get("provider_usage_present").and_then(Value::as_bool))
        .unwrap_or(input_tokens > 0 || output_tokens > 0);
    let usage_recorded = usage
        .get("recorded")
        .and_then(Value::as_bool)
        .unwrap_or(input_tokens > 0 || output_tokens > 0);
    let done_sent = compat
        .and_then(|value| value.get("done_sent"))
        .and_then(Value::as_bool)
        .or_else(|| {
            stream_finalizer
                .and_then(|value| value.get("done_sent"))
                .and_then(Value::as_bool)
        })
        .or_else(|| stream_end_reason.map(|reason| reason == "completed"));
    let final_chunk_seen = compat
        .and_then(|value| value.get("final_chunk_seen"))
        .and_then(Value::as_bool);
    let final_chunk_sent = compat
        .and_then(|value| value.get("final_chunk_sent"))
        .and_then(Value::as_bool);
    let final_chunk = stream_finalizer
        .and_then(|value| value.get("final_chunk"))
        .and_then(Value::as_str)
        .or(stream_end_reason);

    serde_json::json!({
        "schema": "gateway_openai_compat_projection_v1",
        "source_schema": source_schema,
        "status": status,
        "secret_safe": true,
        "mode": mode,
        "endpoint": compat
            .and_then(|value| value.get("endpoint"))
            .and_then(Value::as_str),
        "x_request_id": x_request_id,
        "x_request_id_present": x_request_id_present,
        "request_id_header_present": x_request_id_present,
        "response_id": response_id,
        "response_id_present": response_id.is_some(),
        "object": object,
        "type": object,
        "model": compat
            .and_then(|value| value.get("model"))
            .and_then(Value::as_str),
        "choices_count": compat
            .and_then(|value| value.get("choices_count"))
            .and_then(Value::as_u64),
        "finish_reasons": finish_reasons,
        "finish_reason_present": finish_reason_present,
        "response_body_hash": projected_response_hash,
        "provider_usage_present": usage
        .get("provider_usage_present")
            .and_then(Value::as_bool),
        "usage_present": usage_present,
        "usage_observed": usage_present,
        "usage_recorded": usage_recorded,
        "input_tokens_recorded": usage
            .get("input_tokens_recorded")
            .and_then(Value::as_bool)
            .unwrap_or(usage_recorded && input_tokens > 0),
        "output_tokens_recorded": usage
            .get("output_tokens_recorded")
            .and_then(Value::as_bool)
            .unwrap_or(usage_recorded && output_tokens > 0),
        "done_sent": done_sent,
        "final_chunk_seen": final_chunk_seen,
        "final_chunk_sent": final_chunk_sent,
        "final_chunk": final_chunk,
    })
}

pub fn request_log_rate_limit_metadata_projection(route_decision_snapshot: &Value) -> Value {
    let Some(runtime) = route_decision_snapshot.get("virtual_key_rate_limit") else {
        return empty_rate_limit_metadata_projection();
    };
    let status = runtime
        .get("status")
        .and_then(Value::as_str)
        .filter(|status| matches!(*status, "ok" | "limited" | "not_checked"))
        .unwrap_or_else(|| legacy_rate_limit_status(runtime));
    let retry_after_ms = runtime
        .get("retry_after_ms")
        .and_then(Value::as_u64)
        .or_else(|| find_retry_after_ms(runtime));
    let window_status = runtime
        .get("window_status")
        .and_then(Value::as_str)
        .filter(|status| matches!(*status, "summary_only" | "not_windowed" | "not_recorded"))
        .unwrap_or_else(|| {
            if runtime.get("window_material_in_output") == Some(&Value::Bool(false)) {
                "summary_only"
            } else {
                "not_recorded"
            }
        });

    serde_json::json!({
        "schema": "gateway_rate_limit_metadata_v1",
        "source_schema": runtime.get("schema").and_then(Value::as_str),
        "secret_safe": true,
        "scope": runtime
            .get("scope")
            .and_then(Value::as_str)
            .unwrap_or("virtual_key"),
        "status": status,
        "retry_after_ms": retry_after_ms,
        "window_status": window_status,
        "concurrency": rate_limit_dimension_projection(runtime, "concurrency"),
        "rpm": rate_limit_dimension_projection(runtime, "rpm"),
        "tpm": rate_limit_dimension_projection(runtime, "tpm"),
    })
}

fn empty_rate_limit_metadata_projection() -> Value {
    serde_json::json!({
        "schema": "gateway_rate_limit_metadata_v1",
        "source_schema": null,
        "secret_safe": true,
        "scope": "virtual_key",
        "status": "not_recorded",
        "retry_after_ms": null,
        "window_status": "not_recorded",
        "concurrency": empty_rate_limit_dimension_projection("concurrency"),
        "rpm": empty_rate_limit_dimension_projection("rpm"),
        "tpm": empty_rate_limit_dimension_projection("tpm"),
    })
}

fn rate_limit_dimension_projection(runtime: &Value, dimension: &str) -> Value {
    let dimensions = runtime.get("dimensions").unwrap_or(&Value::Null);
    let summary = dimensions.get(dimension).unwrap_or(&Value::Null);
    if summary.is_object() {
        return serde_json::json!({
            "scope": summary
                .get("scope")
                .and_then(Value::as_str)
                .unwrap_or("virtual_key"),
            "status": safe_rate_limit_dimension_status(summary),
            "limit": summary.get("limit").and_then(Value::as_i64),
            "used": summary.get("used").and_then(Value::as_i64),
            "remaining": summary.get("remaining").and_then(Value::as_i64),
            "required": summary.get("required").and_then(Value::as_i64),
            "retry_after_ms": summary.get("retry_after_ms").and_then(Value::as_u64),
            "window_seconds": summary.get("window_seconds").and_then(Value::as_u64),
            "window_status": summary
                .get("window_status")
                .and_then(Value::as_str)
                .unwrap_or("not_recorded"),
        });
    }

    let configured = string_set(runtime.get("configured_dimensions")).contains(dimension);
    let acquire = runtime.get("acquire").unwrap_or(&Value::Null);
    let attempted = string_set(acquire.get("attempted_dimensions")).contains(dimension);
    let applied = string_set(acquire.get("applied_dimensions")).contains(dimension);
    let refused = acquire.get("refused_dimension").and_then(Value::as_str) == Some(dimension);
    let status = if refused {
        "limited"
    } else if applied {
        "ok"
    } else if attempted {
        "not_applied"
    } else if configured {
        "configured"
    } else {
        "not_configured"
    };
    let window_status = if configured && matches!(dimension, "rpm" | "tpm") {
        "summary_only"
    } else if configured {
        "not_windowed"
    } else {
        "not_configured"
    };
    let window_seconds = if configured && matches!(dimension, "rpm" | "tpm") {
        Some(60)
    } else {
        None
    };

    serde_json::json!({
        "scope": "virtual_key",
        "status": status,
        "limit": null,
        "used": null,
        "remaining": null,
        "required": null,
        "retry_after_ms": if refused { find_retry_after_ms(runtime) } else { None },
        "window_seconds": window_seconds,
        "window_status": window_status,
    })
}

fn empty_rate_limit_dimension_projection(dimension: &str) -> Value {
    serde_json::json!({
        "scope": "virtual_key",
        "status": "not_recorded",
        "limit": null,
        "used": null,
        "remaining": null,
        "required": null,
        "retry_after_ms": null,
        "window_seconds": if matches!(dimension, "rpm" | "tpm") { Some(60) } else { None },
        "window_status": "not_recorded",
    })
}

fn safe_rate_limit_dimension_status(summary: &Value) -> &'static str {
    match summary.get("status").and_then(Value::as_str) {
        Some("ok") => "ok",
        Some("limited") => "limited",
        Some("not_applied") => "not_applied",
        Some("configured") => "configured",
        Some("not_configured") => "not_configured",
        _ => "not_recorded",
    }
}

fn legacy_rate_limit_status(runtime: &Value) -> &'static str {
    let acquire = runtime.get("acquire").unwrap_or(&Value::Null);
    if acquire
        .get("refused_dimension")
        .and_then(Value::as_str)
        .is_some()
    {
        "limited"
    } else if string_set(acquire.get("attempted_dimensions")).is_empty() {
        "not_checked"
    } else {
        "ok"
    }
}

fn string_set(value: Option<&Value>) -> std::collections::BTreeSet<String> {
    value
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .filter(|dimension| matches!(*dimension, "concurrency" | "rpm" | "tpm"))
        .map(ToString::to_string)
        .collect()
}

fn find_retry_after_ms(value: &Value) -> Option<u64> {
    match value {
        Value::Object(object) => {
            if let Some(retry_after_ms) = object.get("retry_after_ms").and_then(Value::as_u64) {
                return Some(retry_after_ms);
            }
            object.values().find_map(find_retry_after_ms)
        }
        Value::Array(values) => values.iter().find_map(find_retry_after_ms),
        _ => None,
    }
}

pub fn request_log_stream_finalizer_projection(
    partial_sent: bool,
    stream_end_reason: Option<&str>,
    ttft_ms: Option<i32>,
    route_decision_snapshot: &Value,
) -> Value {
    let finalizer = route_decision_snapshot.get("stream_finalizer");
    let status = if finalizer.is_some() {
        "recorded"
    } else if partial_sent || stream_end_reason.is_some() || ttft_ms.is_some() {
        "config-needed"
    } else {
        "not_recorded"
    };

    let source_schema = finalizer
        .and_then(|value| value.get("schema"))
        .and_then(Value::as_str);
    let usage = finalizer
        .and_then(|value| value.get("usage"))
        .unwrap_or(&Value::Null);
    let billing = finalizer
        .and_then(|value| value.get("billing"))
        .unwrap_or(&Value::Null);
    let concurrency = finalizer
        .and_then(|value| value.get("concurrency"))
        .unwrap_or(&Value::Null);

    serde_json::json!({
        "schema": "gateway_stream_finalizer_projection_v1",
        "source_schema": source_schema,
        "status": status,
        "secret_safe": true,
        "partial_sent": finalizer
            .and_then(|value| value.get("partial_sent"))
            .and_then(Value::as_bool)
            .unwrap_or(partial_sent),
        "end_reason": finalizer
            .and_then(|value| value.get("end_reason"))
            .and_then(Value::as_str)
            .or(stream_end_reason),
        "ttft_ms": finalizer
            .and_then(|value| value.get("request_ttft_ms"))
            .and_then(Value::as_i64)
            .and_then(|value| i32::try_from(value).ok())
            .or(ttft_ms),
        "usage_observed": usage.get("observed").and_then(Value::as_bool),
        "usage_recorded": usage.get("recorded").and_then(Value::as_bool),
        "billing_eligible": billing
            .get("ledger_settle_eligible")
            .and_then(Value::as_bool),
        "reserve_release_reason": billing
            .get("reserve_release_reason")
            .and_then(Value::as_str),
        "concurrency_release": concurrency
            .get("virtual_key_slot_release")
            .and_then(Value::as_str),
    })
}

pub fn request_log_provider_protocol_summary_projection(
    partial_sent: bool,
    stream_end_reason: Option<&str>,
    route_decision_snapshot: &Value,
) -> Value {
    let finalizer = route_decision_snapshot.get("stream_finalizer");
    let status = if finalizer.is_some() {
        "recorded"
    } else if partial_sent || stream_end_reason.is_some() {
        "config-needed"
    } else {
        "not_recorded"
    };
    let usage = finalizer
        .and_then(|value| value.get("usage"))
        .unwrap_or(&Value::Null);
    let prompt_tokens = usage
        .get("prompt_tokens")
        .and_then(Value::as_i64)
        .or_else(|| usage.get("input_tokens").and_then(Value::as_i64));
    let completion_tokens = usage
        .get("completion_tokens")
        .and_then(Value::as_i64)
        .or_else(|| usage.get("output_tokens").and_then(Value::as_i64));
    let total_tokens = usage
        .get("total_tokens")
        .and_then(Value::as_i64)
        .or_else(|| {
            prompt_tokens
                .zip(completion_tokens)
                .and_then(|(prompt, completion)| prompt.checked_add(completion))
        });
    let openai_compat = finalizer
        .and_then(|value| value.get("openai_compat"))
        .or_else(|| route_decision_snapshot.get("openai_compat"));
    let finish_reason_present = openai_compat
        .and_then(|value| value.get("finish_reason_present"))
        .and_then(Value::as_bool);
    let end_reason = finalizer
        .and_then(|value| value.get("end_reason"))
        .and_then(Value::as_str)
        .or(stream_end_reason);

    serde_json::json!({
        "schema": "gateway_provider_protocol_summary_v1",
        "source_schema": finalizer
            .and_then(|value| value.get("schema"))
            .and_then(Value::as_str),
        "status": status,
        "secret_safe": true,
        "downstream_protocol": finalizer
            .and_then(|value| value.get("downstream_protocol"))
            .and_then(Value::as_str)
            .or_else(|| finalizer
                .and_then(|value| value.get("protocol"))
                .and_then(Value::as_str)),
        "provider_protocol": finalizer
            .and_then(|value| value.get("provider_protocol"))
            .and_then(Value::as_str),
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "total_tokens": total_tokens,
        "usage_observed": usage.get("observed").and_then(Value::as_bool),
        "usage_recorded": usage.get("recorded").and_then(Value::as_bool),
        "end_reason": end_reason,
        "end_reason_present": end_reason.is_some(),
        "finish_reason_present": finish_reason_present,
    })
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RequestLogListFilter {
    pub limit: i64,
    pub status: Option<String>,
    pub model: Option<String>,
    pub canonical_model_id: Option<Uuid>,
    pub channel_id: Option<Uuid>,
    pub virtual_key_id: Option<Uuid>,
    pub api_key_profile_id: Option<Uuid>,
    pub created_from: Option<String>,
    pub created_to: Option<String>,
    pub stream: Option<bool>,
    pub error_type: Option<String>,
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
    pub request_id: Option<Uuid>,
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn openai_compat_projection_records_non_stream_safe_shape() {
        let projection = request_log_openai_compat_projection(
            false,
            None,
            None,
            12,
            34,
            Some("sha256:resp"),
            &json!({
                "openai_compat": {
                    "schema": "gateway_openai_chat_completion_compat_v1",
                    "mode": "non_stream",
                    "endpoint": "chat_completions",
                    "x_request_id": "req-1",
                    "response_id": "chatcmpl-1",
                    "object": "chat.completion",
                    "model": "gpt-test",
                    "choices_count": 1,
                    "finish_reasons": ["stop"],
                    "response_body_hash": "sha256:resp",
                    "usage": {
                        "provider_usage_present": true,
                        "input_tokens_recorded": true,
                        "output_tokens_recorded": true
                    },
                    "raw_payload_omitted": true
                }
            }),
        );

        assert_eq!(projection["schema"], "gateway_openai_compat_projection_v1");
        assert_eq!(
            projection["source_schema"],
            "gateway_openai_chat_completion_compat_v1"
        );
        assert_eq!(projection["status"], "recorded");
        assert_eq!(projection["mode"], "non_stream");
        assert_eq!(projection["request_id_header_present"], true);
        assert_eq!(projection["response_id_present"], true);
        assert_eq!(projection["object"], "chat.completion");
        assert_eq!(projection["type"], "chat.completion");
        assert_eq!(projection["finish_reason_present"], true);
        assert_eq!(projection["usage_present"], true);
        assert_eq!(projection["usage_recorded"], true);
        assert!(projection.get("raw_payload_omitted").is_none());
    }

    #[test]
    fn openai_compat_projection_marks_stream_missing_metadata_config_needed() {
        let projection = request_log_openai_compat_projection(
            true,
            Some("completed"),
            Some(15),
            3,
            5,
            Some("sha256:stream-resp"),
            &json!({}),
        );

        assert_eq!(projection["status"], "config-needed");
        assert_eq!(projection["mode"], "stream");
        assert_eq!(projection["done_sent"], true);
        assert_eq!(projection["final_chunk"], "completed");
        assert_eq!(projection["response_body_hash"], "sha256:stream-resp");
        assert_eq!(projection["request_id_header_present"], false);
        assert_eq!(projection["usage_present"], true);
    }
}
