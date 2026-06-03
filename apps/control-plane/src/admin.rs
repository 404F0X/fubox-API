use std::{
    collections::{BTreeMap, BTreeSet, HashMap},
    net::IpAddr,
    sync::Arc,
};

use ai_gateway_auth::{
    GeneratedVirtualKey, PROVIDER_KEY_ENCRYPTION_ALGORITHM, PROVIDER_KEY_MASTER_KEY_LEN,
    ProviderKeyContext, ProviderKeyCryptoError, ProviderKeySecret, SealedProviderKey,
    fingerprint_provider_key, generate_virtual_key, login_rate_limit_fingerprint,
    seal_provider_key,
};
use ai_gateway_db::{
    ApiKeyProfile, AuditLog, BillingReconciliationReportFilter, CanonicalModel, Channel, DbError,
    DbRepository, LedgerEntry, LedgerEntryListFilter, ModelAssociation, NewApiKeyProfile,
    NewAuditLog, NewCanonicalModel, NewChannel, NewModelAssociation, NewPriceVersionInput,
    NewProvider, NewProviderKey, NewVirtualKey, PriceVersion, PriceVersionListFilter, Provider,
    ProviderKey, RequestLogListFilter, RequestLogSummary, RequestTraceFilter,
    RouteCandidates as DbRouteCandidates, UpdateApiKeyProfile, UpdateCanonicalModel, UpdateChannel,
    UpdateModelAssociation, UpdateProvider, VirtualKey,
};
use ai_gateway_observability::redact_secrets;
use ai_gateway_routing::{
    ChannelHealth, ChannelStatus, ROUTE_DECISION_SNAPSHOT_VERSION,
    RouteCandidate as RoutingRouteCandidate, RouteDecisionSnapshot, RouteDecisionSnapshotCandidate,
    RouteRequest, RouteSelectionContext, select_route_with_context,
};
use axum::{
    Extension, Json, Router,
    extract::{Path, Query, State},
    http::{HeaderMap, StatusCode, header::USER_AGENT},
    response::{IntoResponse, Response},
    routing::get,
};
use serde::{Deserialize, Deserializer};
use serde_json::{Value, json};
use sqlx::{Row, postgres::PgRow};
use uuid::Uuid;

use crate::{
    ControlPlaneState, DEFAULT_TENANT_ID,
    alerts::{AlertWebhookDryRunRequest, dry_run_alert_webhook},
    auth::AdminSession,
    prompt_eval_shadow::{
        PromptEvalShadowDryRunRequest, dry_run_prompt_eval_shadow as plan_prompt_eval_shadow,
    },
};

const REQUEST_LOG_DEFAULT_LIMIT: i64 = 50;
const REQUEST_LOG_MAX_LIMIT: i64 = 500;
const AUDIT_LOG_DEFAULT_LIMIT: i64 = 50;
const AUDIT_LOG_MAX_LIMIT: i64 = 500;
const BILLING_READ_DEFAULT_LIMIT: i64 = 50;
const BILLING_READ_MAX_LIMIT: i64 = 500;
const RECONCILIATION_DEFAULT_DISCREPANCY_LIMIT: usize = 50;
const RECONCILIATION_MAX_DISCREPANCY_LIMIT: usize = 500;
const PRICE_VERSION_DEFAULT_MONEY_SCALE: u32 = 8;
const PRICE_VERSION_MAX_MONEY_SCALE: u32 = 18;
const PROVIDER_KEY_MASTER_KEY_ENV: &str = "AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_BASE64";
const PROVIDER_KEY_MASTER_KEY_ID_ENV: &str = "AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_ID";
const DEFAULT_PROVIDER_KEY_MASTER_KEY_ID: &str = "env-v1";
const ROUTE_POLICY_VERSION: &str = "gateway_db_route_v1";
const ROUTE_PRIORITY_ASSOCIATION_MULTIPLIER: i32 = 1_000_000;
const HEALTH_SUMMARY_RECENT_SAMPLE_LIMIT: i64 = REQUEST_LOG_MAX_LIMIT;
const HEALTH_SUMMARY_DEFAULT_WINDOW_MINUTES: i64 = 60;
const HEALTH_SUMMARY_MAX_WINDOW_MINUTES: i64 = 24 * 60;

pub(crate) fn router() -> Router<Arc<ControlPlaneState>> {
    Router::new()
        .route(
            "/admin/providers",
            get(list_providers).post(create_provider),
        )
        .route(
            "/admin/providers/health-summary",
            get(get_provider_health_summary),
        )
        .route(
            "/admin/providers/{id}",
            get(get_provider)
                .patch(patch_provider)
                .delete(delete_provider),
        )
        .route("/admin/channels", get(list_channels).post(create_channel))
        .route(
            "/admin/channels/{id}",
            get(get_channel).patch(patch_channel).delete(delete_channel),
        )
        .route(
            "/admin/channels/{id}/manual-test",
            axum::routing::post(dry_run_channel_manual_test),
        )
        .route(
            "/admin/provider-keys",
            get(list_provider_keys).post(create_provider_key),
        )
        .route(
            "/admin/provider-keys/{id}",
            get(get_provider_key)
                .patch(patch_provider_key)
                .delete(delete_provider_key),
        )
        .route(
            "/admin/provider-keys/{id}/recovery",
            axum::routing::post(request_provider_key_recovery),
        )
        .route(
            "/admin/api-key-profiles",
            get(list_api_key_profiles).post(create_api_key_profile),
        )
        .route(
            "/admin/api-key-profiles/{id}",
            get(get_api_key_profile)
                .patch(patch_api_key_profile)
                .delete(delete_api_key_profile),
        )
        .route(
            "/admin/virtual-keys",
            get(list_virtual_keys).post(create_virtual_key),
        )
        .route("/admin/virtual-keys/{id}", get(get_virtual_key))
        .route(
            "/admin/virtual-keys/{id}/disable",
            axum::routing::post(disable_virtual_key),
        )
        .route(
            "/admin/virtual-keys/{id}/expire",
            axum::routing::post(expire_virtual_key),
        )
        .route("/admin/models", get(list_models).post(create_model))
        .route(
            "/admin/models/{id}",
            get(get_model).patch(patch_model).delete(delete_model),
        )
        .route(
            "/admin/model-associations",
            get(list_model_associations).post(create_model_association),
        )
        .route(
            "/admin/model-associations/dry-run",
            axum::routing::post(dry_run_model_association),
        )
        .route(
            "/admin/prompt-eval-shadow/dry-run",
            axum::routing::post(dry_run_prompt_eval_shadow_admin),
        )
        .route(
            "/admin/model-associations/{id}",
            get(get_model_association)
                .patch(patch_model_association)
                .delete(delete_model_association),
        )
        .route("/admin/request-logs", get(list_request_logs))
        .route("/admin/request-logs/{id}", get(get_request_log_detail))
        .route("/admin/traces/{trace_id}", get(get_trace_request_summary))
        .route("/admin/audit-logs", get(list_audit_logs_admin))
        .route(
            "/admin/alerts/webhook/dry-run",
            axum::routing::post(dry_run_alert_webhook_admin),
        )
        .route(
            "/admin/price-versions",
            get(list_price_versions).post(create_price_version),
        )
        .route("/admin/ledger/entries", get(list_ledger_entries))
        .route(
            "/admin/billing/reconciliation",
            get(get_billing_reconciliation),
        )
}

#[derive(Debug, Deserialize)]
struct CreateProviderRequest {
    code: String,
    name: String,
    provider_type: Option<String>,
    base_url: Option<String>,
    status: Option<String>,
    metadata: Option<Value>,
}

#[derive(Debug, Deserialize)]
struct CreateChannelRequest {
    provider_id: Uuid,
    name: String,
    endpoint: Option<String>,
    base_url: Option<String>,
    protocol_mode: Option<String>,
    protocol: Option<String>,
    status: Option<String>,
    region: Option<String>,
    priority: Option<i32>,
    weight: Option<i32>,
    tags: Option<Value>,
    model_mappings: Option<Value>,
    request_overrides: Option<Value>,
    timeout_policy: Option<Value>,
    probe_policy: Option<Value>,
    health_score: Option<f64>,
}

#[derive(Deserialize)]
struct CreateProviderKeyRequest {
    channel_id: Uuid,
    key_alias: String,
    status: Option<String>,
    metadata: Option<Value>,
    secret: Option<String>,
    api_key: Option<String>,
    #[serde(
        default,
        rename = "encrypted_secret",
        deserialize_with = "deserialize_present_field"
    )]
    encrypted_secret_supplied: bool,
    #[serde(
        default,
        rename = "secret_fingerprint",
        deserialize_with = "deserialize_present_field"
    )]
    secret_fingerprint_supplied: bool,
}

#[derive(Debug, Deserialize)]
struct CreateModelRequest {
    model_key: Option<String>,
    name: Option<String>,
    display_name: Option<String>,
    family: Option<String>,
    capabilities: Option<Value>,
    context_length: Option<i32>,
    max_output_tokens: Option<i32>,
    supports_stream: Option<bool>,
    supports_tools: Option<bool>,
    supports_vision: Option<bool>,
    supports_audio: Option<bool>,
    supports_reasoning: Option<bool>,
    visibility: Option<String>,
    status: Option<String>,
    default_price_book_id: Option<Uuid>,
}

#[derive(Debug, Deserialize)]
struct CreateModelAssociationRequest {
    canonical_model_id: Uuid,
    association_type: String,
    channel_id: Option<Uuid>,
    channel_tag: Option<String>,
    model_pattern: Option<String>,
    upstream_model_name: Option<String>,
    priority: Option<i32>,
    conditions: Option<Value>,
    fallback_allowed: Option<bool>,
    canary_percent: Option<f64>,
    status: Option<String>,
}

#[derive(Debug, Deserialize)]
struct PatchProviderRequest {
    code: Option<String>,
    name: Option<String>,
    provider_type: Option<String>,
    base_url: Option<String>,
    status: Option<String>,
    metadata: Option<Value>,
}

#[derive(Debug, Deserialize)]
struct PatchChannelRequest {
    provider_id: Option<Uuid>,
    name: Option<String>,
    endpoint: Option<String>,
    base_url: Option<String>,
    protocol_mode: Option<String>,
    protocol: Option<String>,
    status: Option<String>,
    region: Option<String>,
    priority: Option<i32>,
    weight: Option<i32>,
    tags: Option<Value>,
    model_mappings: Option<Value>,
    request_overrides: Option<Value>,
    timeout_policy: Option<Value>,
    probe_policy: Option<Value>,
    health_score: Option<f64>,
}

#[derive(Deserialize)]
struct PatchProviderKeyRequest {
    status: Option<String>,
    metadata: Option<Value>,
    secret: Option<Value>,
    api_key: Option<Value>,
    encrypted_secret: Option<Value>,
    secret_fingerprint: Option<Value>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct ProviderKeyRecoveryRequest {
    target_status: Option<String>,
    reason: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CreateApiKeyProfileRequest {
    project_id: Uuid,
    name: String,
    inbound_protocol: Option<String>,
    default_protocol_mode: Option<String>,
    model_aliases: Option<Value>,
    allowed_models: Option<Value>,
    denied_models: Option<Value>,
    allowed_channel_tags: Option<Value>,
    blocked_provider_ids: Option<Value>,
    trace_header_rules: Option<Value>,
    ip_allowlist: Option<Value>,
    request_overrides: Option<Value>,
    payload_policy_id: Option<Uuid>,
    status: Option<String>,
}

#[derive(Debug, Deserialize)]
struct PatchApiKeyProfileRequest {
    name: Option<String>,
    inbound_protocol: Option<String>,
    default_protocol_mode: Option<String>,
    model_aliases: Option<Value>,
    allowed_models: Option<Value>,
    denied_models: Option<Value>,
    allowed_channel_tags: Option<Value>,
    blocked_provider_ids: Option<Value>,
    trace_header_rules: Option<Value>,
    ip_allowlist: Option<Value>,
    request_overrides: Option<Value>,
    payload_policy_id: Option<Uuid>,
    status: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ListApiKeyProfilesQuery {
    project_id: Option<Uuid>,
}

#[derive(Debug, Deserialize)]
struct CreateVirtualKeyRequest {
    project_id: Uuid,
    name: String,
    default_profile_id: Uuid,
    #[serde(default, alias = "profile_ids")]
    additional_profile_ids: Vec<Uuid>,
    status: Option<String>,
    ip_allowlist: Option<Value>,
    rate_limit_policy: Option<Value>,
    budget_policy: Option<Value>,
    metadata: Option<Value>,
    #[serde(
        default,
        rename = "secret",
        deserialize_with = "deserialize_present_field"
    )]
    secret_supplied: bool,
    #[serde(
        default,
        rename = "secret_hash",
        deserialize_with = "deserialize_present_field"
    )]
    secret_hash_supplied: bool,
    #[serde(
        default,
        rename = "key_prefix",
        deserialize_with = "deserialize_present_field"
    )]
    key_prefix_supplied: bool,
}

#[derive(Debug, Deserialize)]
struct ListVirtualKeysQuery {
    project_id: Option<Uuid>,
    status: Option<String>,
}

#[derive(Debug, Deserialize)]
struct PatchModelRequest {
    model_key: Option<String>,
    name: Option<String>,
    display_name: Option<String>,
    family: Option<String>,
    capabilities: Option<Value>,
    context_length: Option<i32>,
    max_output_tokens: Option<i32>,
    supports_stream: Option<bool>,
    supports_tools: Option<bool>,
    supports_vision: Option<bool>,
    supports_audio: Option<bool>,
    supports_reasoning: Option<bool>,
    visibility: Option<String>,
    status: Option<String>,
    default_price_book_id: Option<Uuid>,
}

#[derive(Debug, Deserialize)]
struct PatchModelAssociationRequest {
    canonical_model_id: Option<Uuid>,
    association_type: Option<String>,
    channel_id: Option<Uuid>,
    channel_tag: Option<String>,
    model_pattern: Option<String>,
    upstream_model_name: Option<String>,
    priority: Option<i32>,
    conditions: Option<Value>,
    fallback_allowed: Option<bool>,
    canary_percent: Option<f64>,
    status: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RouteDryRunRequest {
    project_id: Uuid,
    #[serde(alias = "api_key_profile_id")]
    profile_id: Uuid,
    #[serde(alias = "model")]
    requested_model: Option<String>,
    #[serde(alias = "model_key", alias = "canonical_model")]
    canonical_model_key: Option<String>,
    canonical_model_id: Option<Uuid>,
    seed: Option<u64>,
    trace_id: Option<String>,
    #[serde(alias = "trace_affinity_channel_id")]
    previous_successful_channel_id: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ChannelManualTestRequest {
    #[serde(alias = "requested_model")]
    model: Option<String>,
    upstream_model_name: Option<String>,
    dry_run: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct ProviderHealthSummaryQuery {
    #[serde(alias = "minutes")]
    window_minutes: Option<i64>,
    sample_limit: Option<i64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct ProviderHealthSummaryFilter {
    window_minutes: i64,
    sample_limit: i64,
}

impl ProviderHealthSummaryQuery {
    fn into_filter(self) -> Result<ProviderHealthSummaryFilter, AdminError> {
        Ok(ProviderHealthSummaryFilter {
            window_minutes: health_summary_window_minutes(self.window_minutes)?,
            sample_limit: health_summary_sample_limit(self.sample_limit)?,
        })
    }
}

#[derive(Debug, Deserialize)]
struct ListRequestLogsQuery {
    limit: Option<i64>,
    status: Option<String>,
    model: Option<String>,
    canonical_model_id: Option<Uuid>,
    channel_id: Option<Uuid>,
    resolved_channel_id: Option<Uuid>,
}

impl ListRequestLogsQuery {
    fn into_filter(self) -> Result<RequestLogListFilter, AdminError> {
        Ok(RequestLogListFilter {
            limit: request_log_limit(self.limit)?,
            status: optional_non_empty(self.status),
            model: optional_non_empty(self.model),
            canonical_model_id: self.canonical_model_id,
            channel_id: self.channel_id.or(self.resolved_channel_id),
        })
    }
}

#[derive(Debug, Deserialize)]
struct TraceRequestSummaryQuery {
    limit: Option<i64>,
}

impl TraceRequestSummaryQuery {
    fn into_filter(self, trace_id: String) -> Result<RequestTraceFilter, AdminError> {
        let trace_id = optional_non_empty(Some(trace_id))
            .ok_or_else(|| AdminError::bad_request("trace_id must not be empty"))?;
        Ok(RequestTraceFilter {
            trace_id,
            limit: request_log_limit(self.limit)?,
        })
    }
}

#[derive(Debug, Deserialize)]
struct ListAuditLogsQuery {
    limit: Option<i64>,
    tenant_id: Option<Uuid>,
    actor_user_id: Option<Uuid>,
    actor_session_id: Option<Uuid>,
    action: Option<String>,
    resource_type: Option<String>,
    resource_id: Option<Uuid>,
    resource_tenant_id: Option<Uuid>,
    created_from: Option<String>,
    created_to: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
struct AuditLogListFilter {
    limit: i64,
    tenant_id: Uuid,
    actor_user_id: Option<Uuid>,
    actor_session_id: Option<Uuid>,
    action: Option<String>,
    resource_type: Option<String>,
    resource_id: Option<Uuid>,
    resource_tenant_id: Option<Uuid>,
    created_from: Option<String>,
    created_to: Option<String>,
}

impl ListAuditLogsQuery {
    fn into_filter(self) -> Result<AuditLogListFilter, AdminError> {
        Ok(AuditLogListFilter {
            limit: audit_log_limit(self.limit)?,
            tenant_id: audit_log_tenant_id(self.tenant_id)?,
            actor_user_id: self.actor_user_id,
            actor_session_id: self.actor_session_id,
            action: optional_non_empty(self.action),
            resource_type: optional_non_empty(self.resource_type),
            resource_id: self.resource_id,
            resource_tenant_id: self.resource_tenant_id,
            created_from: optional_rfc3339_timestamp(self.created_from, "created_from")?,
            created_to: optional_rfc3339_timestamp(self.created_to, "created_to")?,
        })
    }
}

#[derive(Debug, Deserialize)]
struct ListPriceVersionsQuery {
    limit: Option<i64>,
    price_book_id: Option<Uuid>,
    canonical_model_id: Option<Uuid>,
    status: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CreatePriceVersionRequest {
    price_book_id: Uuid,
    canonical_model_id: Option<Uuid>,
    version: String,
    pricing_rules: Value,
    effective_at: Option<String>,
    retired_at: Option<String>,
    status: Option<String>,
}

impl ListPriceVersionsQuery {
    fn into_filter(self) -> Result<PriceVersionListFilter, AdminError> {
        Ok(PriceVersionListFilter {
            limit: billing_read_limit(self.limit)?,
            price_book_id: self.price_book_id,
            canonical_model_id: self.canonical_model_id,
            status: normalize_price_version_status_query(self.status)?,
        })
    }
}

#[derive(Debug, Deserialize)]
struct ListLedgerEntriesQuery {
    limit: Option<i64>,
    project_id: Option<Uuid>,
    request_id: Option<Uuid>,
    wallet_id: Option<Uuid>,
}

impl ListLedgerEntriesQuery {
    fn into_filter(self) -> Result<LedgerEntryListFilter, AdminError> {
        Ok(LedgerEntryListFilter {
            limit: billing_read_limit(self.limit)?,
            project_id: self.project_id,
            request_id: self.request_id,
            wallet_id: self.wallet_id,
        })
    }
}

#[derive(Debug, Deserialize)]
struct BillingReconciliationQuery {
    day: Option<String>,
    limit: Option<i64>,
}

impl BillingReconciliationQuery {
    fn into_filter(self) -> Result<BillingReconciliationReportFilter, AdminError> {
        Ok(BillingReconciliationReportFilter {
            day: optional_iso_day(self.day)?,
            discrepancy_limit: reconciliation_discrepancy_limit(self.limit)?,
        })
    }
}

async fn create_provider(
    State(state): State<Arc<ControlPlaneState>>,
    Extension(session): Extension<AdminSession>,
    Json(request): Json<CreateProviderRequest>,
) -> Result<Response, AdminError> {
    let metadata = merge_provider_metadata(
        request.metadata.unwrap_or_else(|| json!({})),
        request.provider_type,
        request.base_url,
    )?;
    let repository = repo(&state);
    let provider = repository
        .upsert_provider(NewProvider {
            tenant_id: DEFAULT_TENANT_ID,
            code: non_empty(request.code, "code")?,
            name: non_empty(request.name, "name")?,
            status: normalize_provider_status(request.status.as_deref()),
            metadata,
        })
        .await?;

    record_admin_audit(
        &repository,
        &session,
        "provider.create",
        None,
        &provider,
        json!({ "upsert_semantics": true }),
    )
    .await?;

    Ok((StatusCode::CREATED, Json(json!({ "data": provider }))).into_response())
}

async fn get_provider(
    State(state): State<Arc<ControlPlaneState>>,
    Path(id): Path<Uuid>,
) -> Result<Response, AdminError> {
    let provider = repo(&state)
        .get_provider(DEFAULT_TENANT_ID, id)
        .await?
        .ok_or_else(|| AdminError::not_found("provider"))?;

    Ok(Json(json!({ "data": provider })).into_response())
}

async fn list_providers(
    State(state): State<Arc<ControlPlaneState>>,
) -> Result<Response, AdminError> {
    let providers = repo(&state).list_providers(DEFAULT_TENANT_ID).await?;

    Ok(Json(json!({ "data": providers })).into_response())
}

async fn get_provider_health_summary(
    Query(query): Query<ProviderHealthSummaryQuery>,
    State(state): State<Arc<ControlPlaneState>>,
) -> Result<Response, AdminError> {
    let filter = query.into_filter()?;
    let repository = repo(&state);
    let providers = repository.list_providers(DEFAULT_TENANT_ID).await?;
    let channels = repository.list_channels(DEFAULT_TENANT_ID).await?;
    let provider_keys = repository.list_provider_keys(DEFAULT_TENANT_ID).await?;
    let models = repository.list_canonical_models(DEFAULT_TENANT_ID).await?;
    let associations = repository
        .list_model_associations(DEFAULT_TENANT_ID)
        .await?;
    let request_logs = list_health_summary_request_logs(&state, DEFAULT_TENANT_ID, filter).await?;

    Ok(Json(json!({
        "data": health_summary_response(
            &providers,
            &channels,
            &provider_keys,
            &models,
            &associations,
            &request_logs,
            filter,
        )
    }))
    .into_response())
}

async fn patch_provider(
    State(state): State<Arc<ControlPlaneState>>,
    Extension(session): Extension<AdminSession>,
    Path(id): Path<Uuid>,
    Json(request): Json<PatchProviderRequest>,
) -> Result<Response, AdminError> {
    let repository = repo(&state);
    let current = repository
        .get_provider(DEFAULT_TENANT_ID, id)
        .await?
        .ok_or_else(|| AdminError::not_found("provider"))?;
    let before = current.clone();
    let metadata = merge_provider_metadata(
        request.metadata.unwrap_or(current.metadata),
        request.provider_type,
        request.base_url,
    )?;
    let provider = repository
        .update_provider(
            DEFAULT_TENANT_ID,
            id,
            UpdateProvider {
                code: request.code.unwrap_or(current.code),
                name: request.name.unwrap_or(current.name),
                status: request
                    .status
                    .map(|status| normalize_provider_status(Some(&status)))
                    .unwrap_or(current.status),
                metadata,
            },
        )
        .await?
        .ok_or_else(|| AdminError::not_found("provider"))?;

    record_admin_audit(
        &repository,
        &session,
        "provider.update",
        Some(&before),
        &provider,
        json!({}),
    )
    .await?;

    Ok(Json(json!({ "data": provider })).into_response())
}

async fn delete_provider(
    State(state): State<Arc<ControlPlaneState>>,
    Extension(session): Extension<AdminSession>,
    Path(id): Path<Uuid>,
) -> Result<Response, AdminError> {
    let repository = repo(&state);
    let before = repository
        .get_provider(DEFAULT_TENANT_ID, id)
        .await?
        .ok_or_else(|| AdminError::not_found("provider"))?;
    let provider = repository
        .soft_delete_provider(DEFAULT_TENANT_ID, id)
        .await?
        .ok_or_else(|| AdminError::not_found("provider"))?;

    record_admin_audit(
        &repository,
        &session,
        "provider.delete",
        Some(&before),
        &provider,
        json!({}),
    )
    .await?;

    Ok(Json(json!({ "data": provider })).into_response())
}

async fn create_channel(
    State(state): State<Arc<ControlPlaneState>>,
    Extension(session): Extension<AdminSession>,
    Json(request): Json<CreateChannelRequest>,
) -> Result<Response, AdminError> {
    let endpoint = request
        .endpoint
        .or(request.base_url)
        .ok_or_else(|| AdminError::bad_request("endpoint or base_url is required"))?;
    let protocol_mode = request
        .protocol_mode
        .or(request.protocol)
        .unwrap_or_else(|| "openai_compatible".to_string());
    let repository = repo(&state);
    let channel = repository
        .upsert_channel(NewChannel {
            tenant_id: DEFAULT_TENANT_ID,
            provider_id: request.provider_id,
            name: non_empty(request.name, "name")?,
            endpoint: non_empty(endpoint, "endpoint")?,
            protocol_mode: normalize_protocol_mode(&protocol_mode),
            status: normalize_enabled_status(request.status.as_deref()),
            region: request.region,
            priority: request.priority.unwrap_or(100),
            weight: request.weight.unwrap_or(100),
            tags: request.tags.unwrap_or_else(|| json!([])),
            model_mappings: request.model_mappings.unwrap_or_else(|| json!({})),
            request_overrides: request.request_overrides.unwrap_or_else(|| json!([])),
            timeout_policy: request.timeout_policy.unwrap_or_else(|| json!({})),
            probe_policy: request.probe_policy.unwrap_or_else(|| json!({})),
            health_score: request.health_score.unwrap_or(1.0),
        })
        .await?;

    record_admin_audit(
        &repository,
        &session,
        "channel.create",
        None,
        &channel,
        json!({ "upsert_semantics": true }),
    )
    .await?;

    Ok((StatusCode::CREATED, Json(json!({ "data": channel }))).into_response())
}

async fn get_channel(
    State(state): State<Arc<ControlPlaneState>>,
    Path(id): Path<Uuid>,
) -> Result<Response, AdminError> {
    let channel = repo(&state)
        .get_channel(DEFAULT_TENANT_ID, id)
        .await?
        .ok_or_else(|| AdminError::not_found("channel"))?;

    Ok(Json(json!({ "data": channel })).into_response())
}

async fn list_channels(
    State(state): State<Arc<ControlPlaneState>>,
) -> Result<Response, AdminError> {
    let channels = repo(&state).list_channels(DEFAULT_TENANT_ID).await?;

    Ok(Json(json!({ "data": channels })).into_response())
}

async fn patch_channel(
    State(state): State<Arc<ControlPlaneState>>,
    Extension(session): Extension<AdminSession>,
    Path(id): Path<Uuid>,
    Json(request): Json<PatchChannelRequest>,
) -> Result<Response, AdminError> {
    let repository = repo(&state);
    let current = repository
        .get_channel(DEFAULT_TENANT_ID, id)
        .await?
        .ok_or_else(|| AdminError::not_found("channel"))?;
    let before = current.clone();
    let endpoint = request
        .endpoint
        .or(request.base_url)
        .unwrap_or(current.endpoint);
    let protocol_mode = request
        .protocol_mode
        .or(request.protocol)
        .map(|protocol| normalize_protocol_mode(&protocol))
        .unwrap_or(current.protocol_mode);
    let channel = repository
        .update_channel(
            DEFAULT_TENANT_ID,
            id,
            UpdateChannel {
                provider_id: request.provider_id.unwrap_or(current.provider_id),
                name: request.name.unwrap_or(current.name),
                endpoint,
                protocol_mode,
                status: request
                    .status
                    .map(|status| normalize_enabled_status(Some(&status)))
                    .unwrap_or(current.status),
                region: request.region.or(current.region),
                priority: request.priority.unwrap_or(current.priority),
                weight: request.weight.unwrap_or(current.weight),
                tags: request.tags.unwrap_or(current.tags),
                model_mappings: request.model_mappings.unwrap_or(current.model_mappings),
                request_overrides: request
                    .request_overrides
                    .unwrap_or(current.request_overrides),
                timeout_policy: request.timeout_policy.unwrap_or(current.timeout_policy),
                probe_policy: request.probe_policy.unwrap_or(current.probe_policy),
                health_score: request.health_score.unwrap_or(current.health_score),
            },
        )
        .await?
        .ok_or_else(|| AdminError::not_found("channel"))?;

    record_admin_audit(
        &repository,
        &session,
        "channel.update",
        Some(&before),
        &channel,
        json!({}),
    )
    .await?;

    Ok(Json(json!({ "data": channel })).into_response())
}

async fn delete_channel(
    State(state): State<Arc<ControlPlaneState>>,
    Extension(session): Extension<AdminSession>,
    Path(id): Path<Uuid>,
) -> Result<Response, AdminError> {
    let repository = repo(&state);
    let before = repository
        .get_channel(DEFAULT_TENANT_ID, id)
        .await?
        .ok_or_else(|| AdminError::not_found("channel"))?;
    let channel = repository
        .soft_delete_channel(DEFAULT_TENANT_ID, id)
        .await?
        .ok_or_else(|| AdminError::not_found("channel"))?;

    record_admin_audit(
        &repository,
        &session,
        "channel.delete",
        Some(&before),
        &channel,
        json!({}),
    )
    .await?;

    Ok(Json(json!({ "data": channel })).into_response())
}

async fn dry_run_channel_manual_test(
    State(state): State<Arc<ControlPlaneState>>,
    Path(id): Path<Uuid>,
    Json(request): Json<ChannelManualTestRequest>,
) -> Result<Response, AdminError> {
    if matches!(request.dry_run, Some(false)) {
        return Err(AdminError::bad_request(
            "only dry-run channel manual tests are implemented",
        ));
    }

    let requested_model = optional_non_empty(request.model)
        .ok_or_else(|| AdminError::bad_request("model is required"))?;
    let repository = repo(&state);
    let channel = repository
        .get_channel(DEFAULT_TENANT_ID, id)
        .await?
        .ok_or_else(|| AdminError::not_found("channel"))?;
    let provider = repository
        .get_provider(DEFAULT_TENANT_ID, channel.provider_id)
        .await?
        .ok_or_else(|| AdminError::not_found("provider"))?;
    let upstream_model = optional_non_empty(request.upstream_model_name)
        .unwrap_or_else(|| channel_manual_test_upstream_model(&channel, &requested_model));

    Ok(Json(json!({
        "data": channel_manual_test_response(
            &channel,
            &provider,
            &requested_model,
            &upstream_model,
        )
    }))
    .into_response())
}

async fn create_provider_key(
    State(state): State<Arc<ControlPlaneState>>,
    Extension(session): Extension<AdminSession>,
    headers: HeaderMap,
    Json(request): Json<CreateProviderKeyRequest>,
) -> Result<Response, AdminError> {
    reject_provider_key_create_generated_fields(&request)?;

    let repository = repo(&state);
    let channel = repository
        .get_channel(DEFAULT_TENANT_ID, request.channel_id)
        .await?
        .ok_or_else(|| AdminError::not_found("channel"))?;
    let master_key = load_provider_key_master_key_config()?;
    let provider_key =
        build_new_provider_key(request, Uuid::new_v4(), channel.provider_id, &master_key)?;
    let request_context = admin_request_context_from_headers(&headers);
    let provider_key = repository
        .insert_provider_key_with_audit(provider_key, |after| {
            new_admin_audit_log(
                &session,
                "provider_key.create",
                None,
                after,
                json!({ "secret_material": "redacted" }),
                Some(request_context.clone()),
            )
        })
        .await?;

    Ok((
        StatusCode::CREATED,
        Json(json!({ "data": provider_key_response(provider_key) })),
    )
        .into_response())
}

async fn get_provider_key(
    State(state): State<Arc<ControlPlaneState>>,
    Path(id): Path<Uuid>,
) -> Result<Response, AdminError> {
    let provider_key = repo(&state)
        .get_provider_key(DEFAULT_TENANT_ID, id)
        .await?
        .ok_or_else(|| AdminError::not_found("provider key"))?;

    Ok(Json(json!({ "data": provider_key_response(provider_key) })).into_response())
}

async fn list_provider_keys(
    State(state): State<Arc<ControlPlaneState>>,
) -> Result<Response, AdminError> {
    let provider_keys = repo(&state).list_provider_keys(DEFAULT_TENANT_ID).await?;
    let provider_keys = provider_keys
        .into_iter()
        .map(provider_key_response)
        .collect::<Vec<_>>();

    Ok(Json(json!({ "data": provider_keys })).into_response())
}

async fn patch_provider_key(
    State(state): State<Arc<ControlPlaneState>>,
    Extension(session): Extension<AdminSession>,
    headers: HeaderMap,
    Path(id): Path<Uuid>,
    Json(request): Json<PatchProviderKeyRequest>,
) -> Result<Response, AdminError> {
    let repository = repo(&state);
    let current = repository
        .get_provider_key(DEFAULT_TENANT_ID, id)
        .await?
        .ok_or_else(|| AdminError::not_found("provider key"))?;

    reject_provider_key_secret_fields(&request)?;

    let status =
        normalize_provider_key_manual_patch_status(request.status.as_deref(), &current.status)?;
    let metadata = match request.metadata {
        Some(metadata) => validate_provider_key_metadata(metadata)?,
        None => current.metadata,
    };

    let request_context = admin_request_context_from_headers(&headers);
    let provider_key = repository
        .update_provider_key_admin_with_audit(
            DEFAULT_TENANT_ID,
            id,
            &status,
            metadata,
            |before, after| {
                new_admin_audit_log(
                    &session,
                    "provider_key.update",
                    Some(before),
                    after,
                    json!({}),
                    Some(request_context.clone()),
                )
            },
        )
        .await?
        .ok_or_else(|| AdminError::not_found("provider key"))?;

    Ok(Json(json!({ "data": provider_key_response(provider_key) })).into_response())
}

async fn request_provider_key_recovery(
    State(state): State<Arc<ControlPlaneState>>,
    Extension(session): Extension<AdminSession>,
    headers: HeaderMap,
    Path(id): Path<Uuid>,
    request: Option<Json<ProviderKeyRecoveryRequest>>,
) -> Result<Response, AdminError> {
    let request = request.map(|Json(request)| request).unwrap_or_default();
    let repository = repo(&state);
    let current = repository
        .get_provider_key(DEFAULT_TENANT_ID, id)
        .await?
        .ok_or_else(|| AdminError::not_found("provider key"))?;

    let target_status = normalize_provider_key_recovery_target(request.target_status.as_deref())?;
    validate_provider_key_recovery_transition(&current.status, &target_status)?;
    let previous_status = current.status.clone();
    let metadata = current.metadata.clone();
    let reason = normalize_provider_key_recovery_reason(request.reason)?;
    let request_context = admin_request_context_from_headers(&headers);

    let audit_previous_status = previous_status.clone();
    let audit_target_status = target_status.clone();
    let audit_reason = reason.clone();
    let provider_key = repository
        .update_provider_key_admin_with_audit(
            DEFAULT_TENANT_ID,
            id,
            &target_status,
            metadata,
            |before, after| {
                new_admin_audit_log(
                    &session,
                    "provider_key.recovery_request",
                    Some(before),
                    after,
                    json!({
                        "controlled_status_transition": true,
                        "previous_status": audit_previous_status,
                        "target_status": audit_target_status,
                        "reason": audit_reason,
                        "upstream_probe": {
                            "executed": false,
                            "mode": "not_implemented"
                        },
                        "credential_material": {
                            "omitted": true
                        }
                    }),
                    Some(request_context.clone()),
                )
            },
        )
        .await?
        .ok_or_else(|| AdminError::not_found("provider key"))?;

    Ok(Json(json!({
        "data": provider_key_recovery_response(
            &provider_key,
            &previous_status,
            &target_status,
            reason.as_deref(),
        )
    }))
    .into_response())
}

async fn delete_provider_key(
    State(state): State<Arc<ControlPlaneState>>,
    Extension(session): Extension<AdminSession>,
    headers: HeaderMap,
    Path(id): Path<Uuid>,
) -> Result<Response, AdminError> {
    let repository = repo(&state);
    let request_context = admin_request_context_from_headers(&headers);
    let provider_key = repository
        .soft_delete_provider_key_with_audit(DEFAULT_TENANT_ID, id, |before, after| {
            new_admin_audit_log(
                &session,
                "provider_key.delete",
                Some(before),
                after,
                json!({}),
                Some(request_context.clone()),
            )
        })
        .await?
        .ok_or_else(|| AdminError::not_found("provider key"))?;

    Ok(Json(json!({ "data": provider_key_response(provider_key) })).into_response())
}

async fn create_api_key_profile(
    State(state): State<Arc<ControlPlaneState>>,
    Extension(session): Extension<AdminSession>,
    Json(request): Json<CreateApiKeyProfileRequest>,
) -> Result<Response, AdminError> {
    let repository = repo(&state);
    let profile = repository
        .create_api_key_profile(build_new_api_key_profile(request)?)
        .await?;

    record_admin_audit(
        &repository,
        &session,
        "api_key_profile.create",
        None,
        &profile,
        json!({}),
    )
    .await?;

    Ok((StatusCode::CREATED, Json(json!({ "data": profile }))).into_response())
}

async fn get_api_key_profile(
    State(state): State<Arc<ControlPlaneState>>,
    Path(id): Path<Uuid>,
) -> Result<Response, AdminError> {
    let profile = repo(&state)
        .get_api_key_profile(DEFAULT_TENANT_ID, id)
        .await?
        .ok_or_else(|| AdminError::not_found("api key profile"))?;

    Ok(Json(json!({ "data": profile })).into_response())
}

async fn list_api_key_profiles(
    State(state): State<Arc<ControlPlaneState>>,
    Query(query): Query<ListApiKeyProfilesQuery>,
) -> Result<Response, AdminError> {
    let project_id = query.required_project_id()?;
    let profiles = repo(&state)
        .list_api_key_profiles(DEFAULT_TENANT_ID, Some(project_id))
        .await?;

    Ok(Json(json!({ "data": profiles })).into_response())
}

async fn patch_api_key_profile(
    State(state): State<Arc<ControlPlaneState>>,
    Extension(session): Extension<AdminSession>,
    Path(id): Path<Uuid>,
    Json(request): Json<PatchApiKeyProfileRequest>,
) -> Result<Response, AdminError> {
    let repository = repo(&state);
    let current = repository
        .get_api_key_profile(DEFAULT_TENANT_ID, id)
        .await?
        .ok_or_else(|| AdminError::not_found("api key profile"))?;
    let before = current.clone();
    let profile = repository
        .update_api_key_profile(
            DEFAULT_TENANT_ID,
            id,
            build_update_api_key_profile(current, request)?,
        )
        .await?
        .ok_or_else(|| AdminError::not_found("api key profile"))?;

    record_admin_audit(
        &repository,
        &session,
        "api_key_profile.update",
        Some(&before),
        &profile,
        json!({}),
    )
    .await?;

    Ok(Json(json!({ "data": profile })).into_response())
}

async fn delete_api_key_profile(
    State(state): State<Arc<ControlPlaneState>>,
    Extension(session): Extension<AdminSession>,
    Path(id): Path<Uuid>,
) -> Result<Response, AdminError> {
    let repository = repo(&state);
    let current = repository
        .get_api_key_profile(DEFAULT_TENANT_ID, id)
        .await?
        .ok_or_else(|| AdminError::not_found("api key profile"))?;
    let has_active_virtual_keys = repository
        .api_key_profile_has_active_virtual_keys(DEFAULT_TENANT_ID, id)
        .await?;
    ensure_profile_can_be_deleted(has_active_virtual_keys)?;
    let profile = repository
        .soft_delete_api_key_profile(DEFAULT_TENANT_ID, id)
        .await?
        .ok_or_else(|| AdminError::not_found("api key profile"))?;

    record_admin_audit(
        &repository,
        &session,
        "api_key_profile.delete",
        Some(&current),
        &profile,
        json!({}),
    )
    .await?;

    Ok(Json(json!({ "data": profile })).into_response())
}

async fn create_virtual_key(
    State(state): State<Arc<ControlPlaneState>>,
    Extension(session): Extension<AdminSession>,
    Json(request): Json<CreateVirtualKeyRequest>,
) -> Result<Response, AdminError> {
    reject_virtual_key_create_generated_fields(&request)?;
    if !request.additional_profile_ids.is_empty() {
        return Err(AdminError::bad_request(
            "additional_profile_ids are not supported in P0; provide only default_profile_id",
        ));
    }

    let repository = repo(&state);
    let default_profile = repository
        .get_api_key_profile(DEFAULT_TENANT_ID, request.default_profile_id)
        .await?
        .ok_or_else(|| AdminError::not_found("default api key profile"))?;
    if default_profile.project_id != request.project_id {
        return Err(AdminError::bad_request(
            "default_profile_id must belong to the requested project_id",
        ));
    }

    let generated = generate_virtual_key();
    let secret = generated.secret.clone();
    let virtual_key = repository
        .create_virtual_key_with_default_profile(build_new_virtual_key(request, generated)?)
        .await?;

    record_admin_audit(
        &repository,
        &session,
        "virtual_key.create",
        None,
        &virtual_key,
        json!({ "secret_once_returned": true }),
    )
    .await?;

    Ok((
        StatusCode::CREATED,
        Json(json!({ "data": virtual_key_response(virtual_key, Some(secret)) })),
    )
        .into_response())
}

async fn get_virtual_key(
    State(state): State<Arc<ControlPlaneState>>,
    Path(id): Path<Uuid>,
) -> Result<Response, AdminError> {
    let virtual_key = repo(&state)
        .get_virtual_key(DEFAULT_TENANT_ID, id)
        .await?
        .ok_or_else(|| AdminError::not_found("virtual key"))?;

    Ok(Json(json!({ "data": virtual_key_response(virtual_key, None) })).into_response())
}

async fn list_virtual_keys(
    State(state): State<Arc<ControlPlaneState>>,
    Query(query): Query<ListVirtualKeysQuery>,
) -> Result<Response, AdminError> {
    let filter = query.into_filter()?;
    let virtual_keys = repo(&state)
        .list_virtual_keys(
            DEFAULT_TENANT_ID,
            filter.project_id,
            filter.status.as_deref(),
        )
        .await?
        .into_iter()
        .map(|virtual_key| virtual_key_response(virtual_key, None))
        .collect::<Vec<_>>();

    Ok(Json(json!({ "data": virtual_keys })).into_response())
}

async fn disable_virtual_key(
    State(state): State<Arc<ControlPlaneState>>,
    Extension(session): Extension<AdminSession>,
    Path(id): Path<Uuid>,
) -> Result<Response, AdminError> {
    let repository = repo(&state);
    let before = repository
        .get_virtual_key(DEFAULT_TENANT_ID, id)
        .await?
        .ok_or_else(|| AdminError::not_found("virtual key"))?;
    let virtual_key = repository
        .update_virtual_key_status(DEFAULT_TENANT_ID, id, "disabled")
        .await?
        .ok_or_else(|| AdminError::not_found("virtual key"))?;

    record_admin_audit(
        &repository,
        &session,
        "virtual_key.disable",
        Some(&before),
        &virtual_key,
        json!({}),
    )
    .await?;

    Ok(Json(json!({ "data": virtual_key_response(virtual_key, None) })).into_response())
}

async fn expire_virtual_key(
    State(state): State<Arc<ControlPlaneState>>,
    Extension(session): Extension<AdminSession>,
    Path(id): Path<Uuid>,
) -> Result<Response, AdminError> {
    let repository = repo(&state);
    let before = repository
        .get_virtual_key(DEFAULT_TENANT_ID, id)
        .await?
        .ok_or_else(|| AdminError::not_found("virtual key"))?;
    let virtual_key = repository
        .update_virtual_key_status(DEFAULT_TENANT_ID, id, "expired")
        .await?
        .ok_or_else(|| AdminError::not_found("virtual key"))?;

    record_admin_audit(
        &repository,
        &session,
        "virtual_key.expire",
        Some(&before),
        &virtual_key,
        json!({}),
    )
    .await?;

    Ok(Json(json!({ "data": virtual_key_response(virtual_key, None) })).into_response())
}

async fn create_model(
    State(state): State<Arc<ControlPlaneState>>,
    Extension(session): Extension<AdminSession>,
    Json(request): Json<CreateModelRequest>,
) -> Result<Response, AdminError> {
    let default_price_book_id = request.default_price_book_id;
    let model_key = request
        .model_key
        .or(request.name)
        .ok_or_else(|| AdminError::bad_request("model_key or name is required"))?;
    let display_name = request
        .display_name
        .unwrap_or_else(|| model_key.replace(['/', '-'], " "));
    let repository = repo(&state);
    let default_price_selector =
        validate_model_default_price_book_selector(&repository, default_price_book_id).await?;
    let model = repository
        .upsert_canonical_model(NewCanonicalModel {
            tenant_id: DEFAULT_TENANT_ID,
            model_key: non_empty(model_key, "model_key")?,
            display_name: non_empty(display_name, "display_name")?,
            family: request.family,
            capabilities: request.capabilities.unwrap_or_else(|| json!({})),
            context_length: request.context_length,
            max_output_tokens: request.max_output_tokens,
            supports_stream: request.supports_stream.unwrap_or(true),
            supports_tools: request.supports_tools.unwrap_or(false),
            supports_vision: request.supports_vision.unwrap_or(false),
            supports_audio: request.supports_audio.unwrap_or(false),
            supports_reasoning: request.supports_reasoning.unwrap_or(false),
            visibility: request.visibility.unwrap_or_else(|| "internal".to_string()),
            status: normalize_model_status(request.status.as_deref()),
        })
        .await?;
    let persisted_default_price_book_id = if let Some(default_price_book_id) = default_price_book_id
    {
        Some(set_model_default_price_book_id(&repository, model.id, default_price_book_id).await?)
    } else {
        get_model_default_price_book_id(&repository, model.id).await?
    };

    record_admin_audit(
        &repository,
        &session,
        "model.create",
        None,
        &model,
        model_write_audit_metadata(true, default_price_selector),
    )
    .await?;

    Ok((
        StatusCode::CREATED,
        Json(json!({ "data": canonical_model_response(model, persisted_default_price_book_id) })),
    )
        .into_response())
}

async fn get_model(
    State(state): State<Arc<ControlPlaneState>>,
    Path(id): Path<Uuid>,
) -> Result<Response, AdminError> {
    let model = repo(&state)
        .get_canonical_model(DEFAULT_TENANT_ID, id)
        .await?
        .ok_or_else(|| AdminError::not_found("model"))?;
    let default_price_book_id = get_model_default_price_book_id(&repo(&state), model.id).await?;

    Ok(
        Json(json!({ "data": canonical_model_response(model, default_price_book_id) }))
            .into_response(),
    )
}

async fn list_models(State(state): State<Arc<ControlPlaneState>>) -> Result<Response, AdminError> {
    let repository = repo(&state);
    let models = repository.list_canonical_models(DEFAULT_TENANT_ID).await?;
    let default_price_book_ids = list_model_default_price_book_ids(&repository, &models).await?;
    let models = models
        .into_iter()
        .map(|model| {
            let default_price_book_id = default_price_book_ids.get(&model.id).copied().flatten();
            canonical_model_response(model, default_price_book_id)
        })
        .collect::<Vec<_>>();

    Ok(Json(json!({ "data": models })).into_response())
}

async fn patch_model(
    State(state): State<Arc<ControlPlaneState>>,
    Extension(session): Extension<AdminSession>,
    Path(id): Path<Uuid>,
    Json(request): Json<PatchModelRequest>,
) -> Result<Response, AdminError> {
    let repository = repo(&state);
    let current = repository
        .get_canonical_model(DEFAULT_TENANT_ID, id)
        .await?
        .ok_or_else(|| AdminError::not_found("model"))?;
    let current_default_price_book_id =
        get_model_default_price_book_id(&repository, current.id).await?;
    let requested_default_price_book_id = request.default_price_book_id;
    let default_price_selector =
        validate_model_default_price_book_selector(&repository, requested_default_price_book_id)
            .await?;
    let before = current.clone();
    let model_key = request
        .model_key
        .or(request.name)
        .unwrap_or(current.model_key);
    let model = repository
        .update_canonical_model(
            DEFAULT_TENANT_ID,
            id,
            UpdateCanonicalModel {
                model_key,
                display_name: request.display_name.unwrap_or(current.display_name),
                family: request.family.or(current.family),
                capabilities: request.capabilities.unwrap_or(current.capabilities),
                context_length: request.context_length.or(current.context_length),
                max_output_tokens: request.max_output_tokens.or(current.max_output_tokens),
                supports_stream: request.supports_stream.unwrap_or(current.supports_stream),
                supports_tools: request.supports_tools.unwrap_or(current.supports_tools),
                supports_vision: request.supports_vision.unwrap_or(current.supports_vision),
                supports_audio: request.supports_audio.unwrap_or(current.supports_audio),
                supports_reasoning: request
                    .supports_reasoning
                    .unwrap_or(current.supports_reasoning),
                visibility: request.visibility.unwrap_or(current.visibility),
                status: request
                    .status
                    .map(|status| normalize_model_status(Some(&status)))
                    .unwrap_or(current.status),
            },
        )
        .await?
        .ok_or_else(|| AdminError::not_found("model"))?;
    let default_price_book_id = if let Some(default_price_book_id) = requested_default_price_book_id
    {
        Some(set_model_default_price_book_id(&repository, model.id, default_price_book_id).await?)
    } else {
        current_default_price_book_id
    };

    record_admin_audit(
        &repository,
        &session,
        "model.update",
        Some(&before),
        &model,
        model_write_audit_metadata(false, default_price_selector),
    )
    .await?;

    Ok(
        Json(json!({ "data": canonical_model_response(model, default_price_book_id) }))
            .into_response(),
    )
}

async fn delete_model(
    State(state): State<Arc<ControlPlaneState>>,
    Extension(session): Extension<AdminSession>,
    Path(id): Path<Uuid>,
) -> Result<Response, AdminError> {
    let repository = repo(&state);
    let before = repository
        .get_canonical_model(DEFAULT_TENANT_ID, id)
        .await?
        .ok_or_else(|| AdminError::not_found("model"))?;
    let model = repository
        .soft_delete_canonical_model(DEFAULT_TENANT_ID, id)
        .await?
        .ok_or_else(|| AdminError::not_found("model"))?;

    record_admin_audit(
        &repository,
        &session,
        "model.delete",
        Some(&before),
        &model,
        json!({}),
    )
    .await?;

    Ok(Json(json!({ "data": model })).into_response())
}

async fn create_model_association(
    State(state): State<Arc<ControlPlaneState>>,
    Extension(session): Extension<AdminSession>,
    Json(request): Json<CreateModelAssociationRequest>,
) -> Result<Response, AdminError> {
    let repository = repo(&state);
    let association = repository
        .create_model_association(NewModelAssociation {
            tenant_id: DEFAULT_TENANT_ID,
            canonical_model_id: request.canonical_model_id,
            association_type: non_empty(request.association_type, "association_type")?,
            channel_id: request.channel_id,
            channel_tag: request.channel_tag,
            model_pattern: request.model_pattern,
            upstream_model_name: request.upstream_model_name,
            priority: request.priority.unwrap_or(100),
            conditions: request.conditions.unwrap_or_else(|| json!({})),
            fallback_allowed: request.fallback_allowed.unwrap_or(true),
            canary_percent: request.canary_percent.unwrap_or(100.0),
            status: normalize_enabled_status(request.status.as_deref()),
        })
        .await?;

    record_admin_audit(
        &repository,
        &session,
        "model_association.create",
        None,
        &association,
        json!({}),
    )
    .await?;

    Ok((StatusCode::CREATED, Json(json!({ "data": association }))).into_response())
}

async fn get_model_association(
    State(state): State<Arc<ControlPlaneState>>,
    Path(id): Path<Uuid>,
) -> Result<Response, AdminError> {
    let association = repo(&state)
        .get_model_association(DEFAULT_TENANT_ID, id)
        .await?
        .ok_or_else(|| AdminError::not_found("association"))?;

    Ok(Json(json!({ "data": association })).into_response())
}

async fn list_model_associations(
    State(state): State<Arc<ControlPlaneState>>,
) -> Result<Response, AdminError> {
    let associations = repo(&state)
        .list_model_associations(DEFAULT_TENANT_ID)
        .await?;

    Ok(Json(json!({ "data": associations })).into_response())
}

async fn patch_model_association(
    State(state): State<Arc<ControlPlaneState>>,
    Extension(session): Extension<AdminSession>,
    Path(id): Path<Uuid>,
    Json(request): Json<PatchModelAssociationRequest>,
) -> Result<Response, AdminError> {
    let repository = repo(&state);
    let current = repository
        .get_model_association(DEFAULT_TENANT_ID, id)
        .await?
        .ok_or_else(|| AdminError::not_found("association"))?;
    let before = current.clone();
    let association = repository
        .update_model_association(
            DEFAULT_TENANT_ID,
            id,
            UpdateModelAssociation {
                canonical_model_id: request
                    .canonical_model_id
                    .unwrap_or(current.canonical_model_id),
                association_type: request.association_type.unwrap_or(current.association_type),
                channel_id: request.channel_id.or(current.channel_id),
                channel_tag: request.channel_tag.or(current.channel_tag),
                model_pattern: request.model_pattern.or(current.model_pattern),
                upstream_model_name: request.upstream_model_name.or(current.upstream_model_name),
                priority: request.priority.unwrap_or(current.priority),
                conditions: request.conditions.unwrap_or(current.conditions),
                fallback_allowed: request.fallback_allowed.unwrap_or(current.fallback_allowed),
                canary_percent: request.canary_percent.unwrap_or(current.canary_percent),
                status: request
                    .status
                    .map(|status| normalize_enabled_status(Some(&status)))
                    .unwrap_or(current.status),
            },
        )
        .await?
        .ok_or_else(|| AdminError::not_found("association"))?;

    record_admin_audit(
        &repository,
        &session,
        "model_association.update",
        Some(&before),
        &association,
        json!({}),
    )
    .await?;

    Ok(Json(json!({ "data": association })).into_response())
}

async fn delete_model_association(
    State(state): State<Arc<ControlPlaneState>>,
    Extension(session): Extension<AdminSession>,
    Path(id): Path<Uuid>,
) -> Result<Response, AdminError> {
    let repository = repo(&state);
    let before = repository
        .get_model_association(DEFAULT_TENANT_ID, id)
        .await?
        .ok_or_else(|| AdminError::not_found("association"))?;
    let association = repository
        .soft_delete_model_association(DEFAULT_TENANT_ID, id)
        .await?
        .ok_or_else(|| AdminError::not_found("association"))?;

    record_admin_audit(
        &repository,
        &session,
        "model_association.delete",
        Some(&before),
        &association,
        json!({}),
    )
    .await?;

    Ok(Json(json!({ "data": association })).into_response())
}

async fn dry_run_model_association(
    State(state): State<Arc<ControlPlaneState>>,
    Json(request): Json<RouteDryRunRequest>,
) -> Result<Response, AdminError> {
    let RouteDryRunRequest {
        project_id,
        profile_id,
        requested_model,
        canonical_model_key,
        canonical_model_id,
        seed,
        trace_id,
        previous_successful_channel_id,
    } = request;

    let requested_model = optional_non_empty(requested_model);
    let canonical_model_key = optional_non_empty(canonical_model_key);
    let trace_id = optional_non_empty(trace_id);
    let previous_successful_channel_id = optional_non_empty(previous_successful_channel_id);

    if requested_model.is_none() && canonical_model_key.is_none() && canonical_model_id.is_none() {
        return Err(AdminError::bad_request(
            "requested_model, canonical_model_key, or canonical_model_id is required",
        ));
    }

    let repository = repo(&state);
    let profile = repository
        .get_api_key_profile(DEFAULT_TENANT_ID, profile_id)
        .await?
        .ok_or_else(|| AdminError::not_found("api key profile"))?;
    if profile.project_id != project_id {
        return Err(AdminError::bad_request(
            "profile_id must belong to the requested project_id",
        ));
    }

    let fallback_canonical_model = match canonical_model_id {
        Some(canonical_model_id) => {
            let model = repository
                .get_canonical_model(DEFAULT_TENANT_ID, canonical_model_id)
                .await?
                .ok_or_else(|| AdminError::not_found("model"))?;
            if let Some(canonical_model_key) = canonical_model_key.as_deref()
                && canonical_model_key != model.model_key
            {
                return Err(AdminError::bad_request(
                    "canonical_model_key must match canonical_model_id",
                ));
            }
            Some(model)
        }
        None => match canonical_model_key.as_deref() {
            Some(canonical_model_key) => Some(
                repository
                    .get_canonical_model_by_key(DEFAULT_TENANT_ID, canonical_model_key)
                    .await?
                    .ok_or_else(|| AdminError::not_found("model"))?,
            ),
            None => None,
        },
    };

    let candidate_model_key = fallback_canonical_model
        .as_ref()
        .map(|model| model.model_key.clone())
        .or_else(|| canonical_model_key.clone())
        .or_else(|| requested_model.clone())
        .expect("route dry-run model selector should be validated");
    let requested_model = requested_model
        .or_else(|| {
            fallback_canonical_model
                .as_ref()
                .map(|model| model.model_key.clone())
        })
        .or_else(|| canonical_model_key.clone())
        .expect("route dry-run requested model should be resolved");
    let context = route_selection_context(trace_id, previous_successful_channel_id);
    let route_candidates = repository
        .get_route_candidates_for_model(DEFAULT_TENANT_ID, profile_id, &candidate_model_key)
        .await?;

    Ok(Json(json!({
        "data": route_dry_run_response(
            project_id,
            profile_id,
            requested_model,
            seed.unwrap_or(0),
            context,
            route_candidates,
            fallback_canonical_model,
        )
    }))
    .into_response())
}

async fn dry_run_prompt_eval_shadow_admin(
    Json(request): Json<PromptEvalShadowDryRunRequest>,
) -> Result<Response, AdminError> {
    let response = plan_prompt_eval_shadow(request).map_err(AdminError::bad_request)?;

    Ok(Json(json!({ "data": response })).into_response())
}

async fn list_request_logs(
    State(state): State<Arc<ControlPlaneState>>,
    Query(query): Query<ListRequestLogsQuery>,
) -> Result<Response, AdminError> {
    let request_logs = repo(&state)
        .list_request_logs(DEFAULT_TENANT_ID, query.into_filter()?)
        .await?;

    Ok(Json(json!({ "data": request_logs })).into_response())
}

async fn get_request_log_detail(
    State(state): State<Arc<ControlPlaneState>>,
    Path(id): Path<Uuid>,
) -> Result<Response, AdminError> {
    let repository = repo(&state);
    let request_log = repository
        .get_request_log(DEFAULT_TENANT_ID, id)
        .await?
        .ok_or_else(|| AdminError::not_found("request log"))?;
    let provider_attempts = repository
        .list_provider_attempts_for_request(DEFAULT_TENANT_ID, id)
        .await?;
    let route_decision_snapshot = request_log.route_decision_snapshot.clone();
    let request_log = RequestLogSummary::from(&request_log);

    Ok(Json(json!({
        "data": {
            "request_log": request_log,
            "provider_attempts": provider_attempts,
            "route_decision_snapshot": route_decision_snapshot,
        }
    }))
    .into_response())
}

async fn get_trace_request_summary(
    State(state): State<Arc<ControlPlaneState>>,
    Path(trace_id): Path<String>,
    Query(query): Query<TraceRequestSummaryQuery>,
) -> Result<Response, AdminError> {
    let filter = query.into_filter(trace_id)?;
    let limit = filter.limit;
    let trace_id = filter.trace_id.clone();
    let request_logs = repo(&state)
        .list_request_logs_for_trace(DEFAULT_TENANT_ID, filter)
        .await?;

    if request_logs.is_empty() {
        return Err(AdminError::not_found("request trace"));
    }

    Ok(Json(json!({
        "data": trace_request_summary_response(&trace_id, &request_logs, limit)
    }))
    .into_response())
}

async fn dry_run_alert_webhook_admin(
    Json(request): Json<AlertWebhookDryRunRequest>,
) -> Result<Response, AdminError> {
    let response = dry_run_alert_webhook(request)
        .map_err(|error| AdminError::bad_request(error.to_string()))?;

    Ok(Json(json!({ "data": response })).into_response())
}

async fn list_audit_logs_admin(
    State(state): State<Arc<ControlPlaneState>>,
    Query(query): Query<ListAuditLogsQuery>,
) -> Result<Response, AdminError> {
    let audit_logs = list_audit_logs(state.as_ref(), query.into_filter()?)
        .await?
        .into_iter()
        .map(audit_log_response)
        .collect::<Vec<_>>();

    Ok(Json(json!({ "data": audit_logs })).into_response())
}

async fn list_price_versions(
    State(state): State<Arc<ControlPlaneState>>,
    Query(query): Query<ListPriceVersionsQuery>,
) -> Result<Response, AdminError> {
    let price_versions = repo(&state)
        .list_price_versions(DEFAULT_TENANT_ID, query.into_filter()?)
        .await?
        .into_iter()
        .map(price_version_response)
        .collect::<Vec<_>>();

    Ok(Json(json!({ "data": price_versions })).into_response())
}

async fn create_price_version(
    State(state): State<Arc<ControlPlaneState>>,
    Extension(session): Extension<AdminSession>,
    headers: HeaderMap,
    Json(request): Json<CreatePriceVersionRequest>,
) -> Result<Response, AdminError> {
    let CreatePriceVersionRequest {
        price_book_id,
        canonical_model_id,
        version,
        pricing_rules,
        effective_at,
        retired_at,
        status,
    } = request;
    let repository = repo(&state);
    let price_book_currency = repository
        .get_price_book_currency(DEFAULT_TENANT_ID, price_book_id)
        .await?
        .ok_or_else(|| AdminError::not_found("price book"))?;
    if let Some(canonical_model_id) = canonical_model_id {
        repository
            .get_canonical_model(DEFAULT_TENANT_ID, canonical_model_id)
            .await?
            .ok_or_else(|| AdminError::not_found("canonical model"))?;
    }

    let version = non_empty(version, "version")?;
    let pricing_rules = validate_price_version_pricing_rules(pricing_rules)?;
    let pricing_currency = pricing_rules_currency(&pricing_rules)?.to_string();
    if pricing_currency != price_book_currency {
        return Err(AdminError::bad_request(
            "pricing_rules.currency must match price book currency",
        ));
    }
    let effective_at = normalize_price_version_effective_at(effective_at)?;
    let retired_at = normalize_price_version_retired_at(retired_at)?;
    let status = normalize_price_version_status(status.as_deref())?;
    let request_context = admin_request_context_from_headers(&headers);
    let audit_metadata = price_version_create_audit_metadata(&pricing_rules, &price_book_currency);
    let price_version = repository
        .insert_price_version_with_audit(
            NewPriceVersionInput {
                tenant_id: DEFAULT_TENANT_ID,
                price_book_id,
                canonical_model_id,
                version,
                pricing_rules,
                effective_at,
                retired_at,
                status,
            },
            |after| {
                new_admin_audit_log(
                    &session,
                    "price_version.create",
                    None,
                    after,
                    audit_metadata.clone(),
                    Some(request_context.clone()),
                )
            },
        )
        .await?
        .ok_or_else(|| AdminError::not_found("price book or canonical model"))?;

    Ok((
        StatusCode::CREATED,
        Json(json!({ "data": price_version_response(price_version) })),
    )
        .into_response())
}

async fn list_ledger_entries(
    State(state): State<Arc<ControlPlaneState>>,
    Query(query): Query<ListLedgerEntriesQuery>,
) -> Result<Response, AdminError> {
    let ledger_entries = repo(&state)
        .list_ledger_entries(DEFAULT_TENANT_ID, query.into_filter()?)
        .await?
        .into_iter()
        .map(ledger_entry_response)
        .collect::<Vec<_>>();

    Ok(Json(json!({ "data": ledger_entries })).into_response())
}

async fn get_billing_reconciliation(
    State(state): State<Arc<ControlPlaneState>>,
    Query(query): Query<BillingReconciliationQuery>,
) -> Result<Response, AdminError> {
    let report = repo(&state)
        .billing_reconciliation_report(DEFAULT_TENANT_ID, query.into_filter()?)
        .await?;

    Ok(Json(json!({ "data": report })).into_response())
}

async fn list_health_summary_request_logs(
    state: &ControlPlaneState,
    tenant_id: Uuid,
    filter: ProviderHealthSummaryFilter,
) -> Result<Vec<RequestLogSummary>, AdminError> {
    let window_minutes = i32::try_from(filter.window_minutes)
        .map_err(|_| AdminError::bad_request("window_minutes is out of range"))?;
    let rows = sqlx::query(
        r#"
        select
          id, tenant_id, project_id, virtual_key_id, api_key_profile_id,
          trace_id, thread_id, client_request_id, inbound_protocol, outbound_protocol,
          protocol_mode, requested_model, canonical_model_id, upstream_model,
          resolved_provider_id, resolved_channel_id, provider_key_id, route_policy_version,
          status, http_status, error_owner, error_code, retryable, partial_sent,
          stream_end_reason, input_tokens, output_tokens, final_cost::text as final_cost,
          currency, latency_ms, ttft_ms, payload_policy_id, payload_stored,
          redaction_status, request_body_hash, response_body_hash,
          created_at::text as created_at, completed_at::text as completed_at
        from request_logs
        where tenant_id = $1
          and coalesce(completed_at, created_at) >= now() - make_interval(mins => $2::int)
        order by coalesce(completed_at, created_at) desc, created_at desc, id desc
        limit $3
        "#,
    )
    .bind(tenant_id)
    .bind(window_minutes)
    .bind(filter.sample_limit)
    .fetch_all(state.db())
    .await
    .map_err(|error| AdminError::from(DbError::Query(error)))?;

    rows.into_iter()
        .map(health_summary_request_log_from_row)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| AdminError::from(DbError::Query(error)))
}

fn health_summary_request_log_from_row(row: PgRow) -> Result<RequestLogSummary, sqlx::Error> {
    Ok(RequestLogSummary {
        id: row.try_get("id")?,
        tenant_id: row.try_get("tenant_id")?,
        project_id: row.try_get("project_id")?,
        virtual_key_id: row.try_get("virtual_key_id")?,
        api_key_profile_id: row.try_get("api_key_profile_id")?,
        trace_id: row.try_get("trace_id")?,
        thread_id: row.try_get("thread_id")?,
        client_request_id: row.try_get("client_request_id")?,
        inbound_protocol: row.try_get("inbound_protocol")?,
        outbound_protocol: row.try_get("outbound_protocol")?,
        protocol_mode: row.try_get("protocol_mode")?,
        requested_model: row.try_get("requested_model")?,
        canonical_model_id: row.try_get("canonical_model_id")?,
        upstream_model: row.try_get("upstream_model")?,
        resolved_provider_id: row.try_get("resolved_provider_id")?,
        resolved_channel_id: row.try_get("resolved_channel_id")?,
        provider_key_id: row.try_get("provider_key_id")?,
        route_policy_version: row.try_get("route_policy_version")?,
        status: row.try_get("status")?,
        http_status: row.try_get("http_status")?,
        error_owner: row.try_get("error_owner")?,
        error_code: row.try_get("error_code")?,
        retryable: row.try_get("retryable")?,
        partial_sent: row.try_get("partial_sent")?,
        stream_end_reason: row.try_get("stream_end_reason")?,
        input_tokens: row.try_get("input_tokens")?,
        output_tokens: row.try_get("output_tokens")?,
        final_cost: row.try_get("final_cost")?,
        currency: row.try_get("currency")?,
        latency_ms: row.try_get("latency_ms")?,
        ttft_ms: row.try_get("ttft_ms")?,
        payload_policy_id: row.try_get("payload_policy_id")?,
        payload_stored: row.try_get("payload_stored")?,
        redaction_status: row.try_get("redaction_status")?,
        request_body_hash: row.try_get("request_body_hash")?,
        response_body_hash: row.try_get("response_body_hash")?,
        created_at: row.try_get("created_at")?,
        completed_at: row.try_get("completed_at")?,
    })
}

async fn list_audit_logs(
    state: &ControlPlaneState,
    filter: AuditLogListFilter,
) -> Result<Vec<AuditLog>, AdminError> {
    let rows = sqlx::query(
        r#"
        select
          id, tenant_id, actor_user_id, request_id, action, resource_type, resource_id,
          resource_tenant_id, before_snapshot, after_snapshot, metadata,
          created_at::text as created_at
        from audit_logs
        where tenant_id = $1
          and ($2::uuid is null or actor_user_id = $2)
          and ($3::uuid is null or metadata->>'actor_session_id' = $3::text)
          and ($4::text is null or action = $4)
          and ($5::text is null or resource_type = $5)
          and ($6::uuid is null or resource_id = $6)
          and ($7::uuid is null or resource_tenant_id = $7)
          and ($8::timestamptz is null or created_at >= $8::timestamptz)
          and ($9::timestamptz is null or created_at <= $9::timestamptz)
        order by created_at desc, id desc
        limit $10
        "#,
    )
    .bind(filter.tenant_id)
    .bind(filter.actor_user_id)
    .bind(filter.actor_session_id)
    .bind(filter.action)
    .bind(filter.resource_type)
    .bind(filter.resource_id)
    .bind(filter.resource_tenant_id)
    .bind(filter.created_from)
    .bind(filter.created_to)
    .bind(filter.limit)
    .fetch_all(state.db())
    .await
    .map_err(|error| AdminError::from(DbError::Query(error)))?;

    rows.into_iter()
        .map(audit_log_from_row)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| AdminError::from(DbError::Query(error)))
}

fn audit_log_from_row(row: PgRow) -> Result<AuditLog, sqlx::Error> {
    Ok(AuditLog {
        id: row.try_get("id")?,
        tenant_id: row.try_get("tenant_id")?,
        actor_user_id: row.try_get("actor_user_id")?,
        request_id: row.try_get("request_id")?,
        action: row.try_get("action")?,
        resource_type: row.try_get("resource_type")?,
        resource_id: row.try_get("resource_id")?,
        resource_tenant_id: row.try_get("resource_tenant_id")?,
        before_snapshot: row.try_get("before_snapshot")?,
        after_snapshot: row.try_get("after_snapshot")?,
        metadata: row.try_get("metadata")?,
        created_at: row.try_get("created_at")?,
    })
}

fn audit_log_response(audit_log: AuditLog) -> Value {
    json!({
        "id": audit_log.id,
        "tenant_id": audit_log.tenant_id,
        "actor_user_id": audit_log.actor_user_id,
        "request_id": audit_log.request_id,
        "action": audit_log.action,
        "resource_type": audit_log.resource_type,
        "resource_id": audit_log.resource_id,
        "resource_tenant_id": audit_log.resource_tenant_id,
        "before_snapshot": audit_log.before_snapshot.map(audit_log_safe_json_value),
        "after_snapshot": audit_log.after_snapshot.map(audit_log_safe_json_value),
        "metadata": audit_log_safe_json_value(audit_log.metadata),
        "created_at": audit_log.created_at,
    })
}

fn audit_log_safe_json_value(value: Value) -> Value {
    match sanitize_audit_value(value) {
        Value::Object(object) => Value::Object(
            object
                .into_iter()
                .map(|(key, value)| {
                    if is_sensitive_audit_key(&key) {
                        (key, Value::String("[REDACTED]".to_string()))
                    } else {
                        (key, audit_log_safe_json_value(value))
                    }
                })
                .collect(),
        ),
        Value::Array(values) => {
            Value::Array(values.into_iter().map(audit_log_safe_json_value).collect())
        }
        Value::String(value) => Value::String(redact_secrets(&value)),
        value => value,
    }
}

fn canonical_model_response(model: CanonicalModel, default_price_book_id: Option<Uuid>) -> Value {
    let mut value = serde_json::to_value(model).expect("canonical model should serialize");
    if let Some(object) = value.as_object_mut() {
        object.insert(
            "default_price_book_id".to_string(),
            default_price_book_id
                .map(|id| json!(id))
                .unwrap_or(Value::Null),
        );
    }
    value
}

async fn get_model_default_price_book_id(
    repository: &DbRepository,
    model_id: Uuid,
) -> Result<Option<Uuid>, AdminError> {
    let row = sqlx::query(
        r#"
        select default_price_book_id
        from canonical_models
        where tenant_id = $1
          and id = $2
          and deleted_at is null
        "#,
    )
    .bind(DEFAULT_TENANT_ID)
    .bind(model_id)
    .fetch_optional(repository.pool())
    .await
    .map_err(|error| AdminError::from(DbError::Query(error)))?;

    row.map(|row| row.try_get("default_price_book_id"))
        .transpose()
        .map_err(|error| AdminError::from(DbError::Query(error)))
}

async fn list_model_default_price_book_ids(
    repository: &DbRepository,
    models: &[CanonicalModel],
) -> Result<HashMap<Uuid, Option<Uuid>>, AdminError> {
    if models.is_empty() {
        return Ok(HashMap::new());
    }

    let model_ids = models.iter().map(|model| model.id).collect::<Vec<_>>();
    let rows = sqlx::query(
        r#"
        select id, default_price_book_id
        from canonical_models
        where tenant_id = $1
          and id = any($2)
          and deleted_at is null
        "#,
    )
    .bind(DEFAULT_TENANT_ID)
    .bind(model_ids)
    .fetch_all(repository.pool())
    .await
    .map_err(|error| AdminError::from(DbError::Query(error)))?;

    rows.into_iter()
        .map(|row| Ok((row.try_get("id")?, row.try_get("default_price_book_id")?)))
        .collect::<Result<HashMap<_, _>, sqlx::Error>>()
        .map_err(|error| AdminError::from(DbError::Query(error)))
}

async fn validate_model_default_price_book_selector(
    repository: &DbRepository,
    default_price_book_id: Option<Uuid>,
) -> Result<Option<Value>, AdminError> {
    let Some(default_price_book_id) = default_price_book_id else {
        return Ok(None);
    };
    let price_book_currency = repository
        .get_price_book_currency(DEFAULT_TENANT_ID, default_price_book_id)
        .await?
        .ok_or_else(|| AdminError::not_found("price book"))?;

    Ok(Some(json!({
        "default_price_book_id": default_price_book_id,
        "price_book_currency": price_book_currency,
        "relationship_validated": "tenant_canonical_model_price_book",
        "price_version_selector": "active_effective_version_for_default_price_book",
        "sensitive_material_policy": "uuid_and_currency_only",
    })))
}

async fn set_model_default_price_book_id(
    repository: &DbRepository,
    model_id: Uuid,
    default_price_book_id: Uuid,
) -> Result<Uuid, AdminError> {
    let row = sqlx::query(
        r#"
        update canonical_models
        set default_price_book_id = $3,
            updated_at = now()
        where tenant_id = $1
          and id = $2
          and deleted_at is null
          and exists (
            select 1
            from price_books pb
            where pb.tenant_id = $1
              and pb.id = $3
              and pb.status <> 'archived'
          )
        returning default_price_book_id
        "#,
    )
    .bind(DEFAULT_TENANT_ID)
    .bind(model_id)
    .bind(default_price_book_id)
    .fetch_optional(repository.pool())
    .await
    .map_err(|error| AdminError::from(DbError::Query(error)))?
    .ok_or_else(|| AdminError::bad_request("default price book must belong to the model tenant"))?;

    row.try_get("default_price_book_id")
        .map_err(|error| AdminError::from(DbError::Query(error)))
}

fn model_write_audit_metadata(
    upsert_semantics: bool,
    default_price_selector: Option<Value>,
) -> Value {
    let mut metadata = json!({
        "upsert_semantics": upsert_semantics,
        "default_price_config_contract": {
            "tenant_price_book_relation_required": true,
            "canonical_model_relation_required": true,
            "write_audit_secret_safe": true,
        },
    });
    if let Some(default_price_selector) = default_price_selector {
        metadata
            .as_object_mut()
            .expect("metadata should be an object")
            .insert("default_price_selector".to_string(), default_price_selector);
    }
    metadata
}

fn price_version_response(price_version: PriceVersion) -> Value {
    json!({
        "id": price_version.id,
        "tenant_id": price_version.tenant_id,
        "price_book_id": price_version.price_book_id,
        "canonical_model_id": price_version.canonical_model_id,
        "version": price_version.version,
        "pricing_rules": billing_safe_json_value(price_version.pricing_rules),
        "effective_at": price_version.effective_at,
        "retired_at": price_version.retired_at,
        "status": price_version.status,
        "created_at": price_version.created_at,
    })
}

fn ledger_entry_response(entry: LedgerEntry) -> Value {
    json!({
        "id": entry.id,
        "tenant_id": entry.tenant_id,
        "project_id": entry.project_id,
        "wallet_id": entry.wallet_id,
        "request_id": entry.request_id,
        "virtual_key_id": entry.virtual_key_id,
        "trace_id": entry.trace_id.map(|trace_id| redact_secrets(&trace_id)),
        "related_ledger_entry_id": entry.related_ledger_entry_id,
        "entry_type": entry.entry_type,
        "amount": entry.amount,
        "currency": entry.currency,
        "status": entry.status,
        "idempotency_key": redact_secrets(&entry.idempotency_key),
        "price_version_id": entry.price_version_id,
        "usage_snapshot": billing_safe_json_value(entry.usage_snapshot),
        "policy_snapshot": billing_safe_json_value(entry.policy_snapshot),
        "metadata": billing_safe_json_value(entry.metadata),
        "occurred_at": entry.occurred_at,
        "created_at": entry.created_at,
    })
}

fn billing_safe_json_value(value: Value) -> Value {
    match value {
        Value::Object(object) => Value::Object(
            object
                .into_iter()
                .map(|(key, value)| {
                    if is_sensitive_billing_json_key(&key) {
                        (key, Value::String("[REDACTED]".to_string()))
                    } else {
                        (key, billing_safe_json_value(value))
                    }
                })
                .collect(),
        ),
        Value::Array(values) => {
            Value::Array(values.into_iter().map(billing_safe_json_value).collect())
        }
        Value::String(value) => Value::String(redact_secrets(&value)),
        value => value,
    }
}

fn is_sensitive_billing_json_key(key: &str) -> bool {
    let normalized = key.to_ascii_lowercase();
    normalized.contains("secret")
        || normalized.contains("credential")
        || normalized.contains("password")
        || normalized.contains("authorization")
        || normalized.contains("cookie")
        || normalized.contains("private_key")
        || normalized.contains("raw_key")
        || normalized.contains("secret_hash")
        || normalized.contains("encrypted_secret")
        || normalized.contains("fingerprint")
        || normalized.contains("payload")
        || normalized == "body"
        || normalized.ends_with("_body")
        || normalized == "api_key"
        || normalized.contains("apikey")
        || normalized.contains("access_token")
        || normalized.contains("refresh_token")
        || normalized.contains("session_token")
        || normalized.contains("bearer_token")
}

fn validate_price_version_pricing_rules(value: Value) -> Result<Value, AdminError> {
    let value = validate_json_object(value, "pricing_rules")?;
    if contains_sensitive_billing_json_key(&value) {
        return Err(AdminError::bad_request(
            "pricing_rules must not contain payload, secret, or raw key fields",
        ));
    }

    let object = value
        .as_object()
        .expect("validate_json_object ensures object");
    let scale = price_version_rules_scale(object.get("scale"))?;
    validate_price_version_currency(pricing_rules_currency(&value)?)?;

    let mut has_rate_field = false;
    for (key, field_value) in object {
        match price_version_pricing_rule_field(key) {
            PriceVersionPricingRuleField::Currency => {}
            PriceVersionPricingRuleField::Scale => {}
            PriceVersionPricingRuleField::Rate(field) => {
                if !field_value.is_null() {
                    has_rate_field = true;
                    validate_price_version_money_field(field, field_value, scale)?;
                }
            }
            PriceVersionPricingRuleField::Unknown => {
                return Err(AdminError::bad_request(format!(
                    "unsupported pricing_rules field `{key}`"
                )));
            }
        }
    }

    if !has_rate_field {
        return Err(AdminError::bad_request(
            "pricing_rules must include at least one rate field",
        ));
    }

    Ok(value)
}

fn contains_sensitive_billing_json_key(value: &Value) -> bool {
    match value {
        Value::Object(object) => object.iter().any(|(key, value)| {
            is_sensitive_billing_json_key(key) || contains_sensitive_billing_json_key(value)
        }),
        Value::Array(values) => values.iter().any(contains_sensitive_billing_json_key),
        _ => false,
    }
}

fn pricing_rules_currency(value: &Value) -> Result<&str, AdminError> {
    value
        .get("currency")
        .and_then(Value::as_str)
        .filter(|currency| !currency.is_empty())
        .ok_or_else(|| AdminError::bad_request("pricing_rules.currency is required"))
}

fn validate_price_version_currency(currency: &str) -> Result<(), AdminError> {
    let mut characters = currency.chars();
    let Some(first) = characters.next() else {
        return Err(AdminError::bad_request(
            "pricing_rules.currency is required",
        ));
    };
    let valid = first.is_ascii_uppercase()
        && currency.len() >= 3
        && currency.len() <= 32
        && characters.all(|character| {
            character.is_ascii_uppercase() || character.is_ascii_digit() || character == '_'
        });
    if valid {
        Ok(())
    } else {
        Err(AdminError::bad_request(
            "pricing_rules.currency must be an uppercase currency code",
        ))
    }
}

fn price_version_rules_scale(value: Option<&Value>) -> Result<u32, AdminError> {
    match value {
        None | Some(Value::Null) => Ok(PRICE_VERSION_DEFAULT_MONEY_SCALE),
        Some(Value::Number(number)) => {
            let Some(scale) = number.as_u64() else {
                return Err(AdminError::bad_request(
                    "pricing_rules.scale must be an integer",
                ));
            };
            if scale > u64::from(PRICE_VERSION_MAX_MONEY_SCALE) {
                return Err(AdminError::bad_request(
                    "pricing_rules.scale must be between 0 and 18",
                ));
            }
            Ok(scale as u32)
        }
        Some(_) => Err(AdminError::bad_request(
            "pricing_rules.scale must be an integer",
        )),
    }
}

enum PriceVersionPricingRuleField {
    Currency,
    Scale,
    Rate(&'static str),
    Unknown,
}

fn price_version_pricing_rule_field(key: &str) -> PriceVersionPricingRuleField {
    match key {
        "currency" => PriceVersionPricingRuleField::Currency,
        "scale" => PriceVersionPricingRuleField::Scale,
        "input_token_rate_per_1m" | "input_token_rate_per_million" | "input_tokens_per_1m" => {
            PriceVersionPricingRuleField::Rate("input_token_rate_per_1m")
        }
        "output_token_rate_per_1m" | "output_token_rate_per_million" | "output_tokens_per_1m" => {
            PriceVersionPricingRuleField::Rate("output_token_rate_per_1m")
        }
        "cache_token_rate_per_1m"
        | "cache_token_rate_per_million"
        | "cache_tokens_per_1m"
        | "cached_token_rate_per_1m"
        | "cached_token_rate_per_million"
        | "cached_input_token_rate_per_1m"
        | "cached_input_token_rate_per_million"
        | "input_cache_token_rate_per_1m"
        | "input_cache_token_rate_per_million" => {
            PriceVersionPricingRuleField::Rate("cache_token_rate_per_1m")
        }
        "reasoning_token_rate_per_1m"
        | "reasoning_token_rate_per_million"
        | "reasoning_tokens_per_1m" => {
            PriceVersionPricingRuleField::Rate("reasoning_token_rate_per_1m")
        }
        "fixed_request_cost" => PriceVersionPricingRuleField::Rate("fixed_request_cost"),
        _ => PriceVersionPricingRuleField::Unknown,
    }
}

fn validate_price_version_money_field(
    field: &'static str,
    value: &Value,
    scale: u32,
) -> Result<(), AdminError> {
    match value {
        Value::Null => Ok(()),
        Value::String(value) => validate_price_version_decimal_string(field, value, scale),
        Value::Number(number) => {
            if let Some(units) = number.as_i64() {
                if units < 0 {
                    return Err(AdminError::bad_request(format!(
                        "pricing_rules.{field} must not be negative"
                    )));
                }
                return Ok(());
            }
            if number.as_u64().is_some() {
                return Ok(());
            }
            Err(AdminError::bad_request(format!(
                "pricing_rules.{field} must be a decimal string or integer fixed-unit value"
            )))
        }
        _ => Err(AdminError::bad_request(format!(
            "pricing_rules.{field} must be a decimal string or integer fixed-unit value"
        ))),
    }
}

fn validate_price_version_decimal_string(
    field: &'static str,
    value: &str,
    scale: u32,
) -> Result<(), AdminError> {
    let value = value.trim();
    if value.is_empty() {
        return Err(AdminError::bad_request(format!(
            "pricing_rules.{field} must not be empty"
        )));
    }

    let unsigned = if let Some(unsigned) = value.strip_prefix('-') {
        let _ = unsigned;
        return Err(AdminError::bad_request(format!(
            "pricing_rules.{field} must not be negative"
        )));
    } else if let Some(unsigned) = value.strip_prefix('+') {
        unsigned
    } else {
        value
    };

    let mut parts = unsigned.split('.');
    let whole = parts.next().expect("split always yields one part");
    let fraction = parts.next();
    if parts.next().is_some()
        || whole.is_empty()
        || !whole.chars().all(|character| character.is_ascii_digit())
        || !fraction
            .unwrap_or_default()
            .chars()
            .all(|character| character.is_ascii_digit())
    {
        return Err(AdminError::bad_request(format!(
            "pricing_rules.{field} must be a valid decimal string"
        )));
    }
    if fraction.unwrap_or_default().len() > scale as usize {
        return Err(AdminError::bad_request(format!(
            "pricing_rules.{field} has more than {scale} fractional digits"
        )));
    }

    Ok(())
}

fn price_version_create_audit_metadata(pricing_rules: &Value, price_book_currency: &str) -> Value {
    json!({
        "price_book_currency": price_book_currency,
        "pricing_rule_keys": object_keys(pricing_rules),
        "pricing_currency": pricing_rules_currency(pricing_rules).unwrap_or(""),
        "transactional_audit": true,
        "sensitive_material_policy": "rejected_by_schema",
    })
}

fn repo(state: &ControlPlaneState) -> DbRepository {
    DbRepository::new(state.db().clone())
}

trait AuditResource {
    const RESOURCE_TYPE: &'static str;

    fn audit_resource_id(&self) -> Uuid;
    fn audit_tenant_id(&self) -> Uuid;
    fn audit_summary(&self) -> Value;
}

async fn record_admin_audit<R: AuditResource>(
    repository: &DbRepository,
    session: &AdminSession,
    action: &'static str,
    before: Option<&R>,
    after: &R,
    metadata: Value,
) -> Result<(), AdminError> {
    let resource_id = after.audit_resource_id();
    let tenant_id = after.audit_tenant_id();
    let insert = repository
        .insert_audit_log(new_admin_audit_log(
            session, action, before, after, metadata, None,
        ))
        .await;

    if let Err(error) = insert {
        tracing::warn!(
            action,
            resource_type = R::RESOURCE_TYPE,
            %resource_id,
            %tenant_id,
            error_kind = ?error,
            "admin audit insert failed; continuing after completed business write"
        );
    }

    Ok(())
}

fn new_admin_audit_log<R: AuditResource>(
    session: &AdminSession,
    action: &'static str,
    before: Option<&R>,
    after: &R,
    metadata: Value,
    request_context: Option<Value>,
) -> NewAuditLog {
    new_admin_audit_log_from_parts(
        session.session_id(),
        session.tenant_id(),
        action,
        before,
        after,
        metadata,
        request_context,
    )
}

fn new_admin_audit_log_from_parts<R: AuditResource>(
    session_id: Uuid,
    actor_tenant_id: Uuid,
    action: &'static str,
    before: Option<&R>,
    after: &R,
    metadata: Value,
    request_context: Option<Value>,
) -> NewAuditLog {
    let tenant_id = after.audit_tenant_id();
    NewAuditLog {
        tenant_id,
        actor_session_id: Some(session_id),
        request_id: None,
        action: action.to_string(),
        resource_type: R::RESOURCE_TYPE.to_string(),
        resource_id: Some(after.audit_resource_id()),
        resource_tenant_id: Some(tenant_id),
        before_snapshot: before.map(|resource| resource.audit_summary()),
        after_snapshot: Some(after.audit_summary()),
        metadata: admin_audit_metadata_from_parts(
            session_id,
            actor_tenant_id,
            metadata,
            request_context,
        ),
    }
}

fn admin_audit_metadata_from_parts(
    session_id: Uuid,
    tenant_id: Uuid,
    metadata: Value,
    request_context: Option<Value>,
) -> Value {
    let mut metadata = match sanitize_audit_value(metadata) {
        Value::Object(object) => object,
        value => {
            let mut object = serde_json::Map::new();
            object.insert("details".to_string(), value);
            object
        }
    };

    metadata.insert(
        "actor_session_id".to_string(),
        Value::String(session_id.to_string()),
    );
    metadata.insert(
        "actor_tenant_id".to_string(),
        Value::String(tenant_id.to_string()),
    );
    metadata.insert(
        "source".to_string(),
        Value::String("control_plane_admin".to_string()),
    );
    if let Some(Value::Object(context)) = request_context.map(sanitize_audit_value)
        && !context.is_empty()
    {
        metadata.insert("request_context".to_string(), Value::Object(context));
    }

    Value::Object(metadata)
}

fn admin_request_context_from_headers(headers: &HeaderMap) -> Value {
    let mut context = serde_json::Map::new();

    if let Some(user_agent) = safe_header_str(headers.get(USER_AGENT)) {
        context.insert(
            "user_agent_sha256".to_string(),
            Value::String(audit_fingerprint("user_agent", user_agent)),
        );
        context.insert(
            "user_agent_length".to_string(),
            json!(user_agent.chars().count()),
        );
    }

    if let Some((client_ip, source)) = safe_client_ip_from_headers(headers) {
        let normalized_ip = client_ip.to_string();
        context.insert(
            "client_ip_sha256".to_string(),
            Value::String(audit_fingerprint("client_ip", &normalized_ip)),
        );
        context.insert("client_ip_source".to_string(), json!(source));
        context.insert("client_ip_kind".to_string(), json!(ip_kind(client_ip)));
        context.insert("client_ip_scope".to_string(), json!(ip_scope(client_ip)));
    }

    Value::Object(context)
}

fn safe_header_str(value: Option<&axum::http::HeaderValue>) -> Option<&str> {
    value
        .and_then(|value| value.to_str().ok())
        .map(str::trim)
        .filter(|value| !value.is_empty())
}

fn safe_client_ip_from_headers(headers: &HeaderMap) -> Option<(IpAddr, &'static str)> {
    for (header_name, source) in [
        ("cf-connecting-ip", "cf-connecting-ip"),
        ("x-real-ip", "x-real-ip"),
        ("x-forwarded-for", "x-forwarded-for"),
        ("forwarded", "forwarded"),
    ] {
        let Some(raw) = safe_header_str(headers.get(header_name)) else {
            continue;
        };
        let ip = if header_name == "forwarded" {
            parse_forwarded_client_ip(raw)
        } else {
            parse_client_ip_list(raw)
        };
        if let Some(ip) = ip {
            return Some((ip, source));
        }
    }

    None
}

fn parse_client_ip_list(raw: &str) -> Option<IpAddr> {
    raw.split(',').find_map(parse_client_ip_token)
}

fn parse_forwarded_client_ip(raw: &str) -> Option<IpAddr> {
    raw.split(',').find_map(|entry| {
        entry.split(';').find_map(|part| {
            let (key, value) = part.split_once('=')?;
            if key.trim().eq_ignore_ascii_case("for") {
                parse_client_ip_token(value)
            } else {
                None
            }
        })
    })
}

fn parse_client_ip_token(raw: &str) -> Option<IpAddr> {
    let token = raw.trim().trim_matches('"');
    if token.is_empty() || token.eq_ignore_ascii_case("unknown") {
        return None;
    }
    if let Ok(ip) = token.parse::<IpAddr>() {
        return Some(ip);
    }
    if let Some(stripped) = token.strip_prefix('[')
        && let Some((host, _rest)) = stripped.split_once(']')
    {
        return host.parse::<IpAddr>().ok();
    }
    if let Some((host, port)) = token.rsplit_once(':')
        && host.contains('.')
        && port.chars().all(|value| value.is_ascii_digit())
    {
        return host.parse::<IpAddr>().ok();
    }

    None
}

fn audit_fingerprint(label: &str, value: &str) -> String {
    login_rate_limit_fingerprint(&["control_plane_admin_audit_v1", label, value])
}

fn ip_kind(ip: IpAddr) -> &'static str {
    match ip {
        IpAddr::V4(_) => "ipv4",
        IpAddr::V6(_) => "ipv6",
    }
}

fn ip_scope(ip: IpAddr) -> &'static str {
    match ip {
        IpAddr::V4(value) if value.is_loopback() => "loopback",
        IpAddr::V4(value) if value.is_private() => "private",
        IpAddr::V4(value) if value.is_link_local() => "link_local",
        IpAddr::V4(value) if value.is_multicast() => "multicast",
        IpAddr::V4(value) if value.is_unspecified() => "unspecified",
        IpAddr::V6(value) if value.is_loopback() => "loopback",
        IpAddr::V6(value) if value.is_unique_local() => "private",
        IpAddr::V6(value) if value.is_unicast_link_local() => "link_local",
        IpAddr::V6(value) if value.is_multicast() => "multicast",
        IpAddr::V6(value) if value.is_unspecified() => "unspecified",
        _ => "routable",
    }
}

fn sanitize_audit_value(value: Value) -> Value {
    match value {
        Value::Object(object) => Value::Object(
            object
                .into_iter()
                .map(|(key, value)| {
                    if is_sensitive_audit_key(&key) {
                        (key, Value::String("[REDACTED]".to_string()))
                    } else {
                        (key, sanitize_audit_value(value))
                    }
                })
                .collect(),
        ),
        Value::Array(values) => {
            Value::Array(values.into_iter().map(sanitize_audit_value).collect())
        }
        Value::String(value) if looks_like_secret_value(&value) => {
            Value::String("[REDACTED]".to_string())
        }
        value => value,
    }
}

fn is_sensitive_audit_key(key: &str) -> bool {
    let normalized = key.to_ascii_lowercase();
    is_sensitive_key(&normalized)
        || normalized.contains("password")
        || normalized.contains("authorization")
        || normalized.contains("cookie")
        || matches!(
            normalized.as_str(),
            "headers"
                | "request_headers"
                | "raw_headers"
                | "user-agent"
                | "user_agent"
                | "x-forwarded-for"
                | "x_forwarded_for"
                | "x-real-ip"
                | "x_real_ip"
                | "cf-connecting-ip"
                | "cf_connecting_ip"
                | "forwarded"
                | "ip_address"
                | "client_ip"
        )
        || normalized.contains("private_key")
        || normalized.contains("raw_key")
        || normalized.contains("key_hash")
        || normalized.contains("secret_hash")
        || normalized.contains("payload")
        || normalized.contains("body")
}

fn object_keys(value: &Value) -> Value {
    let mut keys = value
        .as_object()
        .map(|object| object.keys().cloned().collect::<Vec<_>>())
        .unwrap_or_default();
    keys.sort();

    json!(keys)
}

fn array_len(value: &Value) -> usize {
    value.as_array().map(Vec::len).unwrap_or(0)
}

impl AuditResource for Provider {
    const RESOURCE_TYPE: &'static str = "provider";

    fn audit_resource_id(&self) -> Uuid {
        self.id
    }

    fn audit_tenant_id(&self) -> Uuid {
        self.tenant_id
    }

    fn audit_summary(&self) -> Value {
        json!({
            "id": self.id,
            "tenant_id": self.tenant_id,
            "code": self.code,
            "name": self.name,
            "status": self.status,
            "metadata_keys": object_keys(&self.metadata),
        })
    }
}

impl AuditResource for Channel {
    const RESOURCE_TYPE: &'static str = "channel";

    fn audit_resource_id(&self) -> Uuid {
        self.id
    }

    fn audit_tenant_id(&self) -> Uuid {
        self.tenant_id
    }

    fn audit_summary(&self) -> Value {
        json!({
            "id": self.id,
            "tenant_id": self.tenant_id,
            "provider_id": self.provider_id,
            "name": self.name,
            "protocol_mode": self.protocol_mode,
            "status": self.status,
            "region": self.region,
            "priority": self.priority,
            "weight": self.weight,
            "tags_count": array_len(&self.tags),
            "model_mappings_keys": object_keys(&self.model_mappings),
            "request_overrides_count": array_len(&self.request_overrides),
            "timeout_policy_keys": object_keys(&self.timeout_policy),
            "probe_policy_keys": object_keys(&self.probe_policy),
            "health_score": self.health_score,
        })
    }
}

impl AuditResource for ProviderKey {
    const RESOURCE_TYPE: &'static str = "provider_key";

    fn audit_resource_id(&self) -> Uuid {
        self.id
    }

    fn audit_tenant_id(&self) -> Uuid {
        self.tenant_id
    }

    fn audit_summary(&self) -> Value {
        json!({
            "id": self.id,
            "tenant_id": self.tenant_id,
            "channel_id": self.channel_id,
            "key_alias": self.key_alias,
            "credential_configured": self.has_secret_fingerprint,
            "status": self.status,
            "health_score": self.health_score,
            "cooldown_until": self.cooldown_until,
            "last_error_code": self.last_error_code,
            "rpm_limit": self.rpm_limit,
            "tpm_limit": self.tpm_limit,
            "concurrency_limit": self.concurrency_limit,
            "metadata": sanitize_audit_value(self.metadata.clone()),
            "secret_redacted": true,
        })
    }
}

impl AuditResource for ApiKeyProfile {
    const RESOURCE_TYPE: &'static str = "api_key_profile";

    fn audit_resource_id(&self) -> Uuid {
        self.id
    }

    fn audit_tenant_id(&self) -> Uuid {
        self.tenant_id
    }

    fn audit_summary(&self) -> Value {
        json!({
            "id": self.id,
            "tenant_id": self.tenant_id,
            "project_id": self.project_id,
            "name": self.name,
            "inbound_protocol": self.inbound_protocol,
            "default_protocol_mode": self.default_protocol_mode,
            "model_aliases_keys": object_keys(&self.model_aliases),
            "allowed_models_count": array_len(&self.allowed_models),
            "denied_models_count": array_len(&self.denied_models),
            "allowed_channel_tags_count": array_len(&self.allowed_channel_tags),
            "blocked_provider_ids_count": array_len(&self.blocked_provider_ids),
            "trace_header_rules_keys": object_keys(&self.trace_header_rules),
            "ip_allowlist_count": array_len(&self.ip_allowlist),
            "request_overrides_count": array_len(&self.request_overrides),
            "payload_policy_id": self.payload_policy_id,
            "status": self.status,
        })
    }
}

impl AuditResource for VirtualKey {
    const RESOURCE_TYPE: &'static str = "virtual_key";

    fn audit_resource_id(&self) -> Uuid {
        self.id
    }

    fn audit_tenant_id(&self) -> Uuid {
        self.tenant_id
    }

    fn audit_summary(&self) -> Value {
        json!({
            "id": self.id,
            "tenant_id": self.tenant_id,
            "project_id": self.project_id,
            "name": self.name,
            "key_prefix": self.key_prefix,
            "status": normalize_virtual_key_status_for_response(&self.status),
            "default_profile_id": self.default_profile_id,
            "ip_allowlist_count": array_len(&self.ip_allowlist),
            "rate_limit_policy_keys": object_keys(&self.rate_limit_policy),
            "budget_policy_keys": object_keys(&self.budget_policy),
            "metadata": sanitize_audit_value(self.metadata.clone()),
            "secret_redacted": true,
        })
    }
}

impl AuditResource for CanonicalModel {
    const RESOURCE_TYPE: &'static str = "model";

    fn audit_resource_id(&self) -> Uuid {
        self.id
    }

    fn audit_tenant_id(&self) -> Uuid {
        self.tenant_id
    }

    fn audit_summary(&self) -> Value {
        json!({
            "id": self.id,
            "tenant_id": self.tenant_id,
            "model_key": self.model_key,
            "display_name": self.display_name,
            "family": self.family,
            "capabilities_keys": object_keys(&self.capabilities),
            "context_length": self.context_length,
            "max_output_tokens": self.max_output_tokens,
            "supports_stream": self.supports_stream,
            "supports_tools": self.supports_tools,
            "supports_vision": self.supports_vision,
            "supports_audio": self.supports_audio,
            "supports_reasoning": self.supports_reasoning,
            "visibility": self.visibility,
            "status": self.status,
        })
    }
}

impl AuditResource for ModelAssociation {
    const RESOURCE_TYPE: &'static str = "model_association";

    fn audit_resource_id(&self) -> Uuid {
        self.id
    }

    fn audit_tenant_id(&self) -> Uuid {
        self.tenant_id
    }

    fn audit_summary(&self) -> Value {
        json!({
            "id": self.id,
            "tenant_id": self.tenant_id,
            "canonical_model_id": self.canonical_model_id,
            "association_type": self.association_type,
            "channel_id": self.channel_id,
            "channel_tag": self.channel_tag,
            "model_pattern": self.model_pattern,
            "upstream_model_name": self.upstream_model_name,
            "priority": self.priority,
            "conditions_keys": object_keys(&self.conditions),
            "fallback_allowed": self.fallback_allowed,
            "canary_percent": self.canary_percent,
            "status": self.status,
        })
    }
}

impl AuditResource for PriceVersion {
    const RESOURCE_TYPE: &'static str = "price_version";

    fn audit_resource_id(&self) -> Uuid {
        self.id
    }

    fn audit_tenant_id(&self) -> Uuid {
        self.tenant_id
    }

    fn audit_summary(&self) -> Value {
        json!({
            "id": self.id,
            "tenant_id": self.tenant_id,
            "price_book_id": self.price_book_id,
            "canonical_model_id": self.canonical_model_id,
            "version": self.version,
            "pricing_rules": billing_safe_json_value(self.pricing_rules.clone()),
            "effective_at": self.effective_at,
            "retired_at": self.retired_at,
            "status": self.status,
        })
    }
}

fn deserialize_present_field<'de, D>(deserializer: D) -> Result<bool, D::Error>
where
    D: Deserializer<'de>,
{
    let _ = Value::deserialize(deserializer)?;
    Ok(true)
}

struct VirtualKeyListFilter {
    project_id: Uuid,
    status: Option<String>,
}

impl ListApiKeyProfilesQuery {
    fn required_project_id(self) -> Result<Uuid, AdminError> {
        self.project_id
            .ok_or_else(|| AdminError::bad_request("project_id query parameter is required"))
    }
}

impl ListVirtualKeysQuery {
    fn into_filter(self) -> Result<VirtualKeyListFilter, AdminError> {
        Ok(VirtualKeyListFilter {
            project_id: self
                .project_id
                .ok_or_else(|| AdminError::bad_request("project_id query parameter is required"))?,
            status: normalize_virtual_key_status_query(self.status)?,
        })
    }
}

fn build_new_api_key_profile(
    request: CreateApiKeyProfileRequest,
) -> Result<NewApiKeyProfile, AdminError> {
    Ok(NewApiKeyProfile {
        tenant_id: DEFAULT_TENANT_ID,
        project_id: request.project_id,
        name: non_empty(request.name, "name")?,
        inbound_protocol: normalize_inbound_protocol(request.inbound_protocol.as_deref())?,
        default_protocol_mode: normalize_api_key_profile_protocol_mode(
            request.default_protocol_mode.as_deref(),
        )?,
        model_aliases: json_object_or_default(request.model_aliases, json!({}), "model_aliases")?,
        allowed_models: json_array_or_default(request.allowed_models, json!([]), "allowed_models")?,
        denied_models: json_array_or_default(request.denied_models, json!([]), "denied_models")?,
        allowed_channel_tags: json_array_or_default(
            request.allowed_channel_tags,
            json!([]),
            "allowed_channel_tags",
        )?,
        blocked_provider_ids: json_array_or_default(
            request.blocked_provider_ids,
            json!([]),
            "blocked_provider_ids",
        )?,
        trace_header_rules: json_object_or_default(
            request.trace_header_rules,
            json!({}),
            "trace_header_rules",
        )?,
        ip_allowlist: json_array_or_default(request.ip_allowlist, json!([]), "ip_allowlist")?,
        request_overrides: json_array_or_default(
            request.request_overrides,
            json!([]),
            "request_overrides",
        )?,
        payload_policy_id: request.payload_policy_id,
        status: normalize_api_key_profile_status(request.status.as_deref())?,
    })
}

fn build_update_api_key_profile(
    current: ApiKeyProfile,
    request: PatchApiKeyProfileRequest,
) -> Result<UpdateApiKeyProfile, AdminError> {
    Ok(UpdateApiKeyProfile {
        name: match request.name {
            Some(name) => non_empty(name, "name")?,
            None => current.name,
        },
        inbound_protocol: match request.inbound_protocol {
            Some(inbound_protocol) => normalize_inbound_protocol(Some(&inbound_protocol))?,
            None => current.inbound_protocol,
        },
        default_protocol_mode: match request.default_protocol_mode {
            Some(default_protocol_mode) => {
                normalize_api_key_profile_protocol_mode(Some(&default_protocol_mode))?
            }
            None => current.default_protocol_mode,
        },
        model_aliases: match request.model_aliases {
            Some(model_aliases) => validate_json_object(model_aliases, "model_aliases")?,
            None => current.model_aliases,
        },
        allowed_models: match request.allowed_models {
            Some(allowed_models) => validate_json_array(allowed_models, "allowed_models")?,
            None => current.allowed_models,
        },
        denied_models: match request.denied_models {
            Some(denied_models) => validate_json_array(denied_models, "denied_models")?,
            None => current.denied_models,
        },
        allowed_channel_tags: match request.allowed_channel_tags {
            Some(allowed_channel_tags) => {
                validate_json_array(allowed_channel_tags, "allowed_channel_tags")?
            }
            None => current.allowed_channel_tags,
        },
        blocked_provider_ids: match request.blocked_provider_ids {
            Some(blocked_provider_ids) => {
                validate_json_array(blocked_provider_ids, "blocked_provider_ids")?
            }
            None => current.blocked_provider_ids,
        },
        trace_header_rules: match request.trace_header_rules {
            Some(trace_header_rules) => {
                validate_json_object(trace_header_rules, "trace_header_rules")?
            }
            None => current.trace_header_rules,
        },
        ip_allowlist: match request.ip_allowlist {
            Some(ip_allowlist) => validate_json_array(ip_allowlist, "ip_allowlist")?,
            None => current.ip_allowlist,
        },
        request_overrides: match request.request_overrides {
            Some(request_overrides) => validate_json_array(request_overrides, "request_overrides")?,
            None => current.request_overrides,
        },
        payload_policy_id: request.payload_policy_id.or(current.payload_policy_id),
        status: match request.status {
            Some(status) => normalize_api_key_profile_status(Some(&status))?,
            None => current.status,
        },
    })
}

fn reject_virtual_key_create_generated_fields(
    request: &CreateVirtualKeyRequest,
) -> Result<(), AdminError> {
    if request.secret_supplied || request.secret_hash_supplied || request.key_prefix_supplied {
        return Err(AdminError::bad_request(
            "virtual key secret, secret_hash, and key_prefix are generated by the server",
        ));
    }

    Ok(())
}

fn build_new_virtual_key(
    request: CreateVirtualKeyRequest,
    generated: GeneratedVirtualKey,
) -> Result<NewVirtualKey, AdminError> {
    Ok(NewVirtualKey {
        id: Uuid::new_v4(),
        tenant_id: DEFAULT_TENANT_ID,
        project_id: request.project_id,
        name: non_empty(request.name, "name")?,
        key_prefix: generated.prefix,
        secret_hash: generated.secret_hash,
        status: normalize_virtual_key_status(request.status.as_deref())?,
        default_profile_id: request.default_profile_id,
        ip_allowlist: json_array_or_default(request.ip_allowlist, json!([]), "ip_allowlist")?,
        rate_limit_policy: json_object_or_default(
            request.rate_limit_policy,
            json!({}),
            "rate_limit_policy",
        )?,
        budget_policy: json_object_or_default(request.budget_policy, json!({}), "budget_policy")?,
        metadata: validate_virtual_key_metadata(request.metadata.unwrap_or_else(|| json!({})))?,
    })
}

fn ensure_profile_can_be_deleted(has_active_virtual_keys: bool) -> Result<(), AdminError> {
    if has_active_virtual_keys {
        return Err(AdminError::bad_request(
            "api key profile has active virtual keys bound; disable or expire them before deleting",
        ));
    }

    Ok(())
}

#[derive(Clone)]
struct ProviderKeyMasterKeyConfig {
    key: [u8; PROVIDER_KEY_MASTER_KEY_LEN],
    key_id: String,
}

fn load_provider_key_master_key_config() -> Result<ProviderKeyMasterKeyConfig, AdminError> {
    let raw_key = std::env::var(PROVIDER_KEY_MASTER_KEY_ENV).ok();
    let key = decode_provider_key_master_key(raw_key.as_deref())?;
    let key_id = std::env::var(PROVIDER_KEY_MASTER_KEY_ID_ENV)
        .unwrap_or_else(|_| DEFAULT_PROVIDER_KEY_MASTER_KEY_ID.to_string());
    let key_id = non_empty_provider_key_master_key_id(&key_id)?;

    Ok(ProviderKeyMasterKeyConfig { key, key_id })
}

fn decode_provider_key_master_key(
    raw: Option<&str>,
) -> Result<[u8; PROVIDER_KEY_MASTER_KEY_LEN], AdminError> {
    let raw = raw
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            AdminError::configuration_error("provider key master key is not configured")
        })?;
    let decoded = decode_base64(raw).map_err(|_| {
        AdminError::configuration_error("provider key master key must be valid base64")
    })?;

    decoded.try_into().map_err(|bytes: Vec<u8>| {
        let _ = bytes;
        AdminError::configuration_error("provider key master key must decode to 32 bytes")
    })
}

fn non_empty_provider_key_master_key_id(raw: &str) -> Result<String, AdminError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(AdminError::configuration_error(
            "provider key master key id must not be empty",
        ));
    }

    Ok(trimmed.to_string())
}

fn reject_provider_key_create_generated_fields(
    request: &CreateProviderKeyRequest,
) -> Result<(), AdminError> {
    if request.encrypted_secret_supplied || request.secret_fingerprint_supplied {
        return Err(AdminError::bad_request(
            "provider key encrypted_secret and secret_fingerprint are generated by the server",
        ));
    }

    Ok(())
}

fn build_new_provider_key(
    request: CreateProviderKeyRequest,
    provider_key_id: Uuid,
    provider_id: Uuid,
    master_key: &ProviderKeyMasterKeyConfig,
) -> Result<NewProviderKey, AdminError> {
    let key_alias = non_empty(request.key_alias, "key_alias")?;
    let status = normalize_provider_key_status(request.status.as_deref())?;
    let metadata = validate_provider_key_metadata(request.metadata.unwrap_or_else(|| json!({})))?;
    let secret = provider_key_secret_from_request(request.secret, request.api_key)?;
    let context = ProviderKeyContext::new(
        DEFAULT_TENANT_ID.to_string(),
        provider_id.to_string(),
        provider_key_id.to_string(),
    )
    .map_err(provider_key_crypto_error)?;
    let sealed = seal_provider_key(&master_key.key, &master_key.key_id, &context, &secret)
        .map_err(provider_key_crypto_error)?;
    let fingerprint = fingerprint_provider_key(&master_key.key, &secret)
        .map_err(provider_key_crypto_error)?
        .into_string();

    Ok(NewProviderKey {
        id: provider_key_id,
        tenant_id: DEFAULT_TENANT_ID,
        channel_id: request.channel_id,
        key_alias,
        encrypted_secret: sealed_provider_key_payload(&sealed)?,
        secret_fingerprint: fingerprint,
        status,
        metadata,
    })
}

fn provider_key_secret_from_request(
    secret: Option<String>,
    api_key: Option<String>,
) -> Result<ProviderKeySecret, AdminError> {
    let raw_secret = match (secret, api_key) {
        (Some(_), Some(_)) => {
            return Err(AdminError::bad_request(
                "provide either secret or api_key for provider key creation, not both",
            ));
        }
        (Some(secret), None) | (None, Some(secret)) => secret,
        (None, None) => {
            return Err(AdminError::bad_request(
                "secret or api_key is required for provider key creation",
            ));
        }
    };

    if raw_secret.trim().is_empty() {
        return Err(AdminError::bad_request(
            "provider key secret must not be empty",
        ));
    }

    ProviderKeySecret::new(raw_secret).map_err(provider_key_crypto_error)
}

fn sealed_provider_key_payload(sealed: &SealedProviderKey) -> Result<String, AdminError> {
    serde_json::to_string(&json!({
        "algorithm": PROVIDER_KEY_ENCRYPTION_ALGORITHM,
        "version": sealed.version,
        "master_key_id": &sealed.master_key_id,
        "nonce": hex_encode(&sealed.nonce),
        "ciphertext": hex_encode(&sealed.ciphertext),
    }))
    .map_err(|_| AdminError::configuration_error("provider key encryption payload failed"))
}

fn provider_key_crypto_error(error: ProviderKeyCryptoError) -> AdminError {
    match error {
        ProviderKeyCryptoError::EmptySecret => {
            AdminError::bad_request("provider key secret must not be empty")
        }
        ProviderKeyCryptoError::InvalidMasterKeyLength { .. } => {
            AdminError::configuration_error("provider key master key must decode to 32 bytes")
        }
        ProviderKeyCryptoError::EmptyMasterKeyId => {
            AdminError::configuration_error("provider key master key id must not be empty")
        }
        ProviderKeyCryptoError::EmptyFingerprintKey => {
            AdminError::configuration_error("provider key fingerprint key is not configured")
        }
        ProviderKeyCryptoError::EmptyContext
        | ProviderKeyCryptoError::EmptyContextField { .. }
        | ProviderKeyCryptoError::UnsupportedVersion(_)
        | ProviderKeyCryptoError::EncryptionFailed
        | ProviderKeyCryptoError::DecryptionFailed
        | ProviderKeyCryptoError::InvalidUtf8 => {
            AdminError::configuration_error("provider key encryption failed")
        }
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

fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(HEX[(byte >> 4) as usize] as char);
        output.push(HEX[(byte & 0x0f) as usize] as char);
    }
    output
}

fn non_empty(value: String, field: &'static str) -> Result<String, AdminError> {
    if value.trim().is_empty() {
        return Err(AdminError::bad_request(format!(
            "{field} must not be empty"
        )));
    }
    Ok(value)
}

fn request_log_limit(limit: Option<i64>) -> Result<i64, AdminError> {
    let limit = limit.unwrap_or(REQUEST_LOG_DEFAULT_LIMIT);
    if limit < 1 {
        return Err(AdminError::bad_request("limit must be at least 1"));
    }
    Ok(limit.min(REQUEST_LOG_MAX_LIMIT))
}

fn health_summary_sample_limit(limit: Option<i64>) -> Result<i64, AdminError> {
    let limit = limit.unwrap_or(HEALTH_SUMMARY_RECENT_SAMPLE_LIMIT);
    if limit < 1 {
        return Err(AdminError::bad_request("sample_limit must be at least 1"));
    }
    Ok(limit.min(HEALTH_SUMMARY_RECENT_SAMPLE_LIMIT))
}

fn health_summary_window_minutes(minutes: Option<i64>) -> Result<i64, AdminError> {
    let minutes = minutes.unwrap_or(HEALTH_SUMMARY_DEFAULT_WINDOW_MINUTES);
    if minutes < 1 {
        return Err(AdminError::bad_request("window_minutes must be at least 1"));
    }
    if minutes > HEALTH_SUMMARY_MAX_WINDOW_MINUTES {
        return Err(AdminError::bad_request(format!(
            "window_minutes must be at most {HEALTH_SUMMARY_MAX_WINDOW_MINUTES}"
        )));
    }
    Ok(minutes)
}

fn audit_log_limit(limit: Option<i64>) -> Result<i64, AdminError> {
    let limit = limit.unwrap_or(AUDIT_LOG_DEFAULT_LIMIT);
    if limit < 1 {
        return Err(AdminError::bad_request("limit must be at least 1"));
    }
    Ok(limit.min(AUDIT_LOG_MAX_LIMIT))
}

fn audit_log_tenant_id(tenant_id: Option<Uuid>) -> Result<Uuid, AdminError> {
    match tenant_id {
        Some(tenant_id) if tenant_id != DEFAULT_TENANT_ID => Err(AdminError::bad_request(
            "tenant_id must match the current control-plane tenant",
        )),
        Some(tenant_id) => Ok(tenant_id),
        None => Ok(DEFAULT_TENANT_ID),
    }
}

fn billing_read_limit(limit: Option<i64>) -> Result<i64, AdminError> {
    let limit = limit.unwrap_or(BILLING_READ_DEFAULT_LIMIT);
    if limit < 1 {
        return Err(AdminError::bad_request("limit must be at least 1"));
    }
    Ok(limit.min(BILLING_READ_MAX_LIMIT))
}

fn reconciliation_discrepancy_limit(limit: Option<i64>) -> Result<usize, AdminError> {
    let limit = limit.unwrap_or(RECONCILIATION_DEFAULT_DISCREPANCY_LIMIT as i64);
    if limit < 1 {
        return Err(AdminError::bad_request("limit must be at least 1"));
    }
    Ok((limit as usize).min(RECONCILIATION_MAX_DISCREPANCY_LIMIT))
}

fn optional_iso_day(day: Option<String>) -> Result<Option<String>, AdminError> {
    let Some(day) = optional_non_empty(day) else {
        return Ok(None);
    };

    if is_valid_iso_day(&day) {
        Ok(Some(day))
    } else {
        Err(AdminError::bad_request("day must use YYYY-MM-DD"))
    }
}

fn optional_rfc3339_timestamp(
    value: Option<String>,
    field: &'static str,
) -> Result<Option<String>, AdminError> {
    let Some(value) = optional_non_empty(value) else {
        return Ok(None);
    };

    if is_likely_rfc3339_timestamp(&value) {
        Ok(Some(value))
    } else {
        Err(AdminError::bad_request(format!(
            "{field} must use an RFC3339 timestamp"
        )))
    }
}

fn is_likely_rfc3339_timestamp(value: &str) -> bool {
    let bytes = value.as_bytes();
    if bytes.len() < 20
        || bytes[4] != b'-'
        || bytes[7] != b'-'
        || !matches!(bytes[10], b'T' | b't')
        || bytes[13] != b':'
        || bytes[16] != b':'
    {
        return false;
    }
    if !bytes[..4].iter().all(u8::is_ascii_digit)
        || !bytes[5..7].iter().all(u8::is_ascii_digit)
        || !bytes[8..10].iter().all(u8::is_ascii_digit)
        || !bytes[11..13].iter().all(u8::is_ascii_digit)
        || !bytes[14..16].iter().all(u8::is_ascii_digit)
        || !bytes[17..19].iter().all(u8::is_ascii_digit)
    {
        return false;
    }
    if !bytes.iter().all(|byte| {
        byte.is_ascii_digit()
            || matches!(byte, b'-' | b':' | b'.' | b'T' | b't' | b'Z' | b'z' | b'+')
    }) {
        return false;
    }

    value.ends_with('Z')
        || value.ends_with('z')
        || value[19..].contains('+')
        || value[19..].contains('-')
}

fn is_valid_iso_day(day: &str) -> bool {
    let bytes = day.as_bytes();
    if bytes.len() != 10 || bytes[4] != b'-' || bytes[7] != b'-' {
        return false;
    }
    if !bytes[..4].iter().all(u8::is_ascii_digit)
        || !bytes[5..7].iter().all(u8::is_ascii_digit)
        || !bytes[8..10].iter().all(u8::is_ascii_digit)
    {
        return false;
    }

    let Ok(year) = day[..4].parse::<u16>() else {
        return false;
    };
    let Ok(month) = day[5..7].parse::<u8>() else {
        return false;
    };
    let Ok(day_of_month) = day[8..10].parse::<u8>() else {
        return false;
    };
    if month == 0 || month > 12 || day_of_month == 0 {
        return false;
    }

    let max_day = match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if is_leap_year(year) => 29,
        2 => 28,
        _ => return false,
    };

    day_of_month <= max_day
}

fn is_leap_year(year: u16) -> bool {
    (year.is_multiple_of(4) && !year.is_multiple_of(100)) || year.is_multiple_of(400)
}

fn optional_non_empty(value: Option<String>) -> Option<String> {
    value.and_then(|value| {
        let trimmed = value.trim();
        (!trimmed.is_empty()).then(|| trimmed.to_string())
    })
}

fn validate_json_object(value: Value, field: &'static str) -> Result<Value, AdminError> {
    if value.as_object().is_none() {
        return Err(AdminError::bad_request(format!(
            "{field} must be a JSON object"
        )));
    }

    Ok(value)
}

fn validate_json_array(value: Value, field: &'static str) -> Result<Value, AdminError> {
    if value.as_array().is_none() {
        return Err(AdminError::bad_request(format!(
            "{field} must be a JSON array"
        )));
    }

    Ok(value)
}

fn json_object_or_default(
    value: Option<Value>,
    default: Value,
    field: &'static str,
) -> Result<Value, AdminError> {
    validate_json_object(value.unwrap_or(default), field)
}

fn json_array_or_default(
    value: Option<Value>,
    default: Value,
    field: &'static str,
) -> Result<Value, AdminError> {
    validate_json_array(value.unwrap_or(default), field)
}

fn validate_virtual_key_metadata(metadata: Value) -> Result<Value, AdminError> {
    validate_json_object(metadata, "metadata").and_then(|metadata| {
        if contains_secret_metadata(&metadata) {
            return Err(AdminError::bad_request(
                "virtual key metadata must not contain secrets, credentials, tokens, keys, or fingerprints",
            ));
        }

        Ok(metadata)
    })
}

fn merge_provider_metadata(
    mut metadata: Value,
    provider_type: Option<String>,
    base_url: Option<String>,
) -> Result<Value, AdminError> {
    let Some(object) = metadata.as_object_mut() else {
        return Err(AdminError::bad_request("metadata must be a JSON object"));
    };

    if let Some(provider_type) = provider_type {
        object.insert("provider_type".to_string(), Value::String(provider_type));
    }
    if let Some(base_url) = base_url {
        object.insert("base_url".to_string(), Value::String(base_url));
    }

    Ok(metadata)
}

fn reject_provider_key_secret_fields(request: &PatchProviderKeyRequest) -> Result<(), AdminError> {
    if request.secret.is_some()
        || request.api_key.is_some()
        || request.encrypted_secret.is_some()
        || request.secret_fingerprint.is_some()
    {
        return Err(AdminError::bad_request(
            "provider key secrets and fingerprints cannot be updated through this API",
        ));
    }

    Ok(())
}

fn validate_provider_key_metadata(metadata: Value) -> Result<Value, AdminError> {
    if metadata.as_object().is_none() {
        return Err(AdminError::bad_request("metadata must be a JSON object"));
    }
    if contains_secret_metadata(&metadata) {
        return Err(AdminError::bad_request(
            "provider key metadata must not contain secrets, credentials, tokens, keys, or fingerprints",
        ));
    }

    Ok(metadata)
}

fn contains_secret_metadata(value: &Value) -> bool {
    match value {
        Value::Object(object) => object
            .iter()
            .any(|(key, value)| is_sensitive_key(key) || contains_secret_metadata(value)),
        Value::Array(values) => values.iter().any(contains_secret_metadata),
        Value::String(value) => looks_like_secret_value(value),
        _ => false,
    }
}

fn redact_provider_key_metadata(value: Value) -> Value {
    match value {
        Value::Object(object) => Value::Object(
            object
                .into_iter()
                .map(|(key, value)| {
                    if is_sensitive_key(&key) {
                        (key, Value::String("[REDACTED]".to_string()))
                    } else {
                        (key, redact_provider_key_metadata(value))
                    }
                })
                .collect(),
        ),
        Value::Array(values) => Value::Array(
            values
                .into_iter()
                .map(redact_provider_key_metadata)
                .collect(),
        ),
        Value::String(value) if looks_like_secret_value(&value) => {
            Value::String("[REDACTED]".to_string())
        }
        value => value,
    }
}

fn is_sensitive_key(key: &str) -> bool {
    let normalized = key.to_ascii_lowercase();
    normalized.contains("secret")
        || normalized.contains("credential")
        || normalized.contains("token")
        || normalized.contains("api_key")
        || normalized.contains("apikey")
        || normalized.contains("encrypted_secret")
        || normalized.contains("fingerprint")
}

fn looks_like_secret_value(value: &str) -> bool {
    let trimmed = value.trim();
    let private_key_marker = ["BEGIN", "PRIVATE", "KEY"].join(" ");
    trimmed.starts_with("sk-")
        || (trimmed.starts_with("vk_") && trimmed.len() > 16)
        || trimmed.starts_with("Bearer ")
        || trimmed.contains(&private_key_marker)
}

#[derive(Debug, Clone)]
struct RecentHealthError {
    code: Option<String>,
    owner: Option<String>,
    status: String,
    http_status: Option<i32>,
    observed_at: String,
}

#[derive(Debug, Clone, Default)]
struct RecentHealthStats {
    request_count: usize,
    success_count: usize,
    error_count: usize,
    last_error: Option<RecentHealthError>,
}

impl RecentHealthStats {
    fn observe(&mut self, log: &RequestLogSummary) {
        self.request_count += 1;

        if request_log_counts_as_success(log) {
            self.success_count += 1;
        }

        if request_log_counts_as_error(log) {
            self.error_count += 1;
            if self.last_error.is_none() {
                self.last_error = Some(RecentHealthError {
                    code: log.error_code.clone(),
                    owner: log.error_owner.clone(),
                    status: log.status.clone(),
                    http_status: log.http_status,
                    observed_at: log
                        .completed_at
                        .clone()
                        .unwrap_or_else(|| log.created_at.clone()),
                });
            }
        }
    }
}

#[derive(Debug, Default)]
struct RecentStatsByEntity {
    providers: HashMap<Uuid, RecentHealthStats>,
    channels: HashMap<Uuid, RecentHealthStats>,
    provider_keys: HashMap<Uuid, RecentHealthStats>,
    models: HashMap<Uuid, RecentHealthStats>,
}

fn overall_recent_stats(request_logs: &[RequestLogSummary]) -> RecentHealthStats {
    let mut stats = RecentHealthStats::default();
    for log in request_logs {
        stats.observe(log);
    }
    stats
}

fn health_summary_response(
    providers: &[Provider],
    channels: &[Channel],
    provider_keys: &[ProviderKey],
    models: &[CanonicalModel],
    associations: &[ModelAssociation],
    request_logs: &[RequestLogSummary],
    filter: ProviderHealthSummaryFilter,
) -> Value {
    let recent = recent_stats_by_entity(request_logs);
    let overall_recent = overall_recent_stats(request_logs);
    let association_counts = association_counts_by_model(associations, false);
    let enabled_association_counts = association_counts_by_model(associations, true);
    let model_channel_ids = model_channel_index(channels, associations);
    let channel_model_ids = channel_model_index(&model_channel_ids);

    let provider_summaries = providers
        .iter()
        .map(|provider| {
            let provider_channels = channels
                .iter()
                .filter(|channel| channel.provider_id == provider.id)
                .collect::<Vec<_>>();
            let provider_channel_ids = provider_channels
                .iter()
                .map(|channel| channel.id)
                .collect::<BTreeSet<_>>();
            let provider_provider_keys = provider_keys
                .iter()
                .filter(|provider_key| provider_channel_ids.contains(&provider_key.channel_id))
                .collect::<Vec<_>>();
            let health_score =
                average_health_score(provider_channels.iter().map(|channel| channel.health_score));

            json!({
                "id": provider.id,
                "code": health_summary_string(&provider.code),
                "name": health_summary_string(&provider.name),
                "status": health_summary_string(&provider.status),
                "health_score": health_score,
                "health_state": health_state_for_score(health_score),
                "channel_count": provider_channels.len(),
                "enabled_channel_count": provider_channels
                    .iter()
                    .filter(|channel| channel.status == "enabled")
                    .count(),
                "provider_key_count": provider_provider_keys.len(),
                "enabled_provider_key_count": provider_provider_keys
                    .iter()
                    .filter(|provider_key| provider_key.status == "enabled")
                    .count(),
                "recent": recent_stats_value(recent.providers.get(&provider.id)),
            })
        })
        .collect::<Vec<_>>();

    let channel_summaries = channels
        .iter()
        .map(|channel| {
            let channel_provider_keys = provider_keys
                .iter()
                .filter(|provider_key| provider_key.channel_id == channel.id)
                .collect::<Vec<_>>();
            let model_count = channel_model_ids
                .get(&channel.id)
                .map(BTreeSet::len)
                .unwrap_or_default();

            json!({
                "id": channel.id,
                "provider_id": channel.provider_id,
                "name": health_summary_string(&channel.name),
                "status": health_summary_string(&channel.status),
                "protocol_mode": health_summary_string(&channel.protocol_mode),
                "region": health_summary_optional_string(channel.region.as_deref()),
                "priority": channel.priority,
                "weight": channel.weight,
                "health_score": channel.health_score,
                "health_state": health_state_for_score(Some(channel.health_score)),
                "provider_key_count": channel_provider_keys.len(),
                "enabled_provider_key_count": channel_provider_keys
                    .iter()
                    .filter(|provider_key| provider_key.status == "enabled")
                    .count(),
                "model_count": model_count,
                "recent": recent_stats_value(recent.channels.get(&channel.id)),
            })
        })
        .collect::<Vec<_>>();

    let provider_key_summaries = provider_keys
        .iter()
        .map(|provider_key| {
            json!({
                "id": provider_key.id,
                "channel_id": provider_key.channel_id,
                "key_alias": health_summary_string(&provider_key.key_alias),
                "status": health_summary_string(&provider_key.status),
                "credential_configured": provider_key.has_secret_fingerprint,
                "health_score": provider_key.health_score,
                "health_state": health_state_for_score(Some(provider_key.health_score)),
                "cooldown_until": provider_key.cooldown_until,
                "configured_last_error_code": health_summary_optional_string(provider_key.last_error_code.as_deref()),
                "limits": {
                    "rpm": provider_key.rpm_limit,
                    "tpm": provider_key.tpm_limit,
                    "concurrency": provider_key.concurrency_limit,
                },
                "recent": recent_stats_value(recent.provider_keys.get(&provider_key.id)),
            })
        })
        .collect::<Vec<_>>();

    let model_summaries = models
        .iter()
        .map(|model| {
            let routable_channel_count = model_channel_ids
                .get(&model.id)
                .map(BTreeSet::len)
                .unwrap_or_default();
            let enabled_association_count = enabled_association_counts
                .get(&model.id)
                .copied()
                .unwrap_or_default();

            json!({
                "id": model.id,
                "model_key": health_summary_string(&model.model_key),
                "display_name": health_summary_string(&model.display_name),
                "family": health_summary_optional_string(model.family.as_deref()),
                "visibility": health_summary_string(&model.visibility),
                "status": health_summary_string(&model.status),
                "association_count": association_counts
                    .get(&model.id)
                    .copied()
                    .unwrap_or_default(),
                "enabled_association_count": enabled_association_count,
                "routable_channel_count": routable_channel_count,
                "routing_state": model_routing_state(
                    &model.status,
                    enabled_association_count,
                    routable_channel_count,
                ),
                "recent": recent_stats_value(recent.models.get(&model.id)),
            })
        })
        .collect::<Vec<_>>();

    json!({
        "summary_version": 1,
        "tenant_id": DEFAULT_TENANT_ID,
        "recent_window": {
            "source": "request_logs",
            "window": {
                "unit": "minutes",
                "minutes": filter.window_minutes,
            },
            "window_minutes": filter.window_minutes,
            "sample_limit": filter.sample_limit,
            "sample_count": overall_recent.request_count,
            "success_count": overall_recent.success_count,
            "error_count": overall_recent.error_count,
            "success_rate": success_rate_value(&overall_recent),
        },
        "totals": {
            "providers": providers.len(),
            "channels": channels.len(),
            "provider_keys": provider_keys.len(),
            "models": models.len(),
            "model_associations": associations.len(),
        },
        "status_counts": {
            "providers": status_counts_value(providers.iter().map(|provider| provider.status.as_str())),
            "channels": status_counts_value(channels.iter().map(|channel| channel.status.as_str())),
            "provider_keys": status_counts_value(provider_keys.iter().map(|provider_key| provider_key.status.as_str())),
            "models": status_counts_value(models.iter().map(|model| model.status.as_str())),
        },
        "providers": provider_summaries,
        "channels": channel_summaries,
        "provider_keys": provider_key_summaries,
        "models": model_summaries,
    })
}

fn recent_stats_by_entity(request_logs: &[RequestLogSummary]) -> RecentStatsByEntity {
    let mut recent = RecentStatsByEntity::default();

    for log in request_logs {
        if let Some(provider_id) = log.resolved_provider_id {
            recent
                .providers
                .entry(provider_id)
                .or_default()
                .observe(log);
        }
        if let Some(channel_id) = log.resolved_channel_id {
            recent.channels.entry(channel_id).or_default().observe(log);
        }
        if let Some(provider_key_id) = log.provider_key_id {
            recent
                .provider_keys
                .entry(provider_key_id)
                .or_default()
                .observe(log);
        }
        if let Some(model_id) = log.canonical_model_id {
            recent.models.entry(model_id).or_default().observe(log);
        }
    }

    recent
}

fn request_log_counts_as_error(log: &RequestLogSummary) -> bool {
    log.error_code.is_some()
        || matches!(
            log.status.as_str(),
            "failed" | "cancelled" | "partial" | "rejected"
        )
}

fn request_log_counts_as_success(log: &RequestLogSummary) -> bool {
    log.error_code.is_none() && matches!(log.status.as_str(), "succeeded")
}

fn success_rate_value(stats: &RecentHealthStats) -> Value {
    if stats.request_count == 0 {
        return Value::Null;
    }

    json!(stats.success_count as f64 / stats.request_count as f64)
}

fn recent_last_error_value(error: Option<&RecentHealthError>) -> Value {
    match error {
        Some(error) => json!({
            "code": health_summary_optional_string(error.code.as_deref()),
            "owner": health_summary_optional_string(error.owner.as_deref()),
            "status": health_summary_string(&error.status),
            "http_status": error.http_status,
            "observed_at": health_summary_string(&error.observed_at),
        }),
        None => Value::Null,
    }
}

fn recent_stats_value(stats: Option<&RecentHealthStats>) -> Value {
    json!({
        "request_count": stats.map(|stats| stats.request_count).unwrap_or_default(),
        "success_count": stats.map(|stats| stats.success_count).unwrap_or_default(),
        "error_count": stats.map(|stats| stats.error_count).unwrap_or_default(),
        "success_rate": stats.map(success_rate_value).unwrap_or(Value::Null),
        "last_error": recent_last_error_value(stats.and_then(|stats| stats.last_error.as_ref())),
    })
}

fn trace_request_summary_response(
    trace_id: &str,
    request_logs: &[RequestLogSummary],
    limit: i64,
) -> Value {
    let mut stats = RecentHealthStats::default();
    for log in request_logs {
        stats.observe(log);
    }

    let first_request_at = request_logs
        .iter()
        .map(|log| log.created_at.as_str())
        .min()
        .map(health_summary_string);
    let last_request_at = request_logs
        .iter()
        .map(request_log_observed_at)
        .max()
        .map(health_summary_string);
    let currencies = request_logs
        .iter()
        .map(|log| health_summary_string(&log.currency))
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect::<Vec<_>>();
    let tenant_id = request_logs
        .first()
        .map(|log| log.tenant_id)
        .unwrap_or(DEFAULT_TENANT_ID);

    json!({
        "tenant_id": tenant_id,
        "trace_id": health_summary_string(trace_id),
        "limit": limit,
        "limit_reached": request_logs.len() as i64 == limit,
        "request_count": stats.request_count,
        "error_count": stats.error_count,
        "last_error": recent_last_error_value(stats.last_error.as_ref()),
        "total_input_tokens": request_logs.iter().map(|log| log.input_tokens).sum::<i64>(),
        "total_output_tokens": request_logs.iter().map(|log| log.output_tokens).sum::<i64>(),
        "currencies": currencies,
        "first_request_at": first_request_at,
        "last_request_at": last_request_at,
        "requests": request_logs
            .iter()
            .map(request_log_summary_safe_value)
            .collect::<Vec<_>>(),
    })
}

fn request_log_observed_at(log: &RequestLogSummary) -> &str {
    log.completed_at.as_deref().unwrap_or(&log.created_at)
}

fn request_log_summary_safe_value(log: &RequestLogSummary) -> Value {
    let mut value =
        redact_json_string_values(serde_json::to_value(log).unwrap_or_else(|_| json!({})));
    if let Value::Object(object) = &mut value {
        for key in [
            "route_decision_snapshot",
            "payload_object_ref",
            "payload",
            "request_body",
            "response_body",
            "body",
        ] {
            object.remove(key);
        }
    }
    value
}

fn redact_json_string_values(value: Value) -> Value {
    match value {
        Value::String(value) => Value::String(redact_secrets(&value)),
        Value::Array(values) => Value::Array(
            values
                .into_iter()
                .map(redact_json_string_values)
                .collect::<Vec<_>>(),
        ),
        Value::Object(object) => Value::Object(
            object
                .into_iter()
                .map(|(key, value)| (key, redact_json_string_values(value)))
                .collect(),
        ),
        value => value,
    }
}

fn health_summary_string(value: &str) -> String {
    redact_secrets(value)
}

fn health_summary_optional_string(value: Option<&str>) -> Option<String> {
    value.map(health_summary_string)
}

fn status_counts_value<'a>(statuses: impl Iterator<Item = &'a str>) -> Value {
    let mut counts = BTreeMap::<String, usize>::new();
    for status in statuses {
        *counts.entry(status.to_string()).or_default() += 1;
    }

    json!(counts)
}

fn average_health_score(scores: impl Iterator<Item = f64>) -> Option<f64> {
    let mut total = 0.0;
    let mut count = 0_usize;

    for score in scores {
        if score.is_finite() {
            total += score;
            count += 1;
        }
    }

    (count > 0).then(|| total / count as f64)
}

fn health_state_for_score(score: Option<f64>) -> &'static str {
    match score {
        Some(score) if !score.is_finite() || score <= 0.0 => "unhealthy",
        Some(score) if score < 0.5 => "degraded",
        Some(_) => "healthy",
        None => "no_signal",
    }
}

fn model_routing_state(
    status: &str,
    enabled_association_count: usize,
    routable_channel_count: usize,
) -> &'static str {
    if status != "active" {
        "disabled"
    } else if enabled_association_count == 0 || routable_channel_count == 0 {
        "no_route"
    } else {
        "routable"
    }
}

fn association_counts_by_model(
    associations: &[ModelAssociation],
    enabled_only: bool,
) -> HashMap<Uuid, usize> {
    let mut counts = HashMap::<Uuid, usize>::new();

    for association in associations {
        if enabled_only && association.status != "enabled" {
            continue;
        }
        *counts.entry(association.canonical_model_id).or_default() += 1;
    }

    counts
}

fn model_channel_index(
    channels: &[Channel],
    associations: &[ModelAssociation],
) -> HashMap<Uuid, BTreeSet<Uuid>> {
    let mut index = HashMap::<Uuid, BTreeSet<Uuid>>::new();

    for association in associations
        .iter()
        .filter(|association| association.status == "enabled")
    {
        let channel_ids = channel_ids_for_association(association, channels);
        if channel_ids.is_empty() {
            continue;
        }
        index
            .entry(association.canonical_model_id)
            .or_default()
            .extend(channel_ids);
    }

    index
}

fn channel_model_index(
    model_channel_ids: &HashMap<Uuid, BTreeSet<Uuid>>,
) -> HashMap<Uuid, BTreeSet<Uuid>> {
    let mut index = HashMap::<Uuid, BTreeSet<Uuid>>::new();

    for (model_id, channel_ids) in model_channel_ids {
        for channel_id in channel_ids {
            index.entry(*channel_id).or_default().insert(*model_id);
        }
    }

    index
}

fn channel_ids_for_association(
    association: &ModelAssociation,
    channels: &[Channel],
) -> BTreeSet<Uuid> {
    match association.association_type.as_str() {
        "explicit_channel" => association
            .channel_id
            .into_iter()
            .filter(|channel_id| channels.iter().any(|channel| channel.id == *channel_id))
            .collect(),
        "channel_tag" => association
            .channel_tag
            .as_deref()
            .map(|tag| {
                channels
                    .iter()
                    .filter(|channel| channel_has_tag(channel, tag))
                    .map(|channel| channel.id)
                    .collect()
            })
            .unwrap_or_default(),
        "global" | "model_pattern" => channels.iter().map(|channel| channel.id).collect(),
        _ => BTreeSet::new(),
    }
}

fn channel_has_tag(channel: &Channel, tag: &str) -> bool {
    match &channel.tags {
        Value::Array(values) => values.iter().any(|value| value.as_str() == Some(tag)),
        Value::Object(object) => object.contains_key(tag),
        _ => false,
    }
}

fn provider_key_response(provider_key: ProviderKey) -> Value {
    json!({
        "id": provider_key.id,
        "tenant_id": provider_key.tenant_id,
        "channel_id": provider_key.channel_id,
        "key_alias": provider_key.key_alias,
        "credential_configured": provider_key.has_secret_fingerprint,
        "status": provider_key.status,
        "health_score": provider_key.health_score,
        "cooldown_until": provider_key.cooldown_until,
        "last_error_code": provider_key.last_error_code,
        "rpm_limit": provider_key.rpm_limit,
        "tpm_limit": provider_key.tpm_limit,
        "concurrency_limit": provider_key.concurrency_limit,
        "metadata": redact_provider_key_metadata(provider_key.metadata),
        "secret_redacted": provider_key.secret_redacted,
    })
}

fn provider_key_recovery_response(
    provider_key: &ProviderKey,
    previous_status: &str,
    target_status: &str,
    reason: Option<&str>,
) -> Value {
    json!({
        "dry_run": false,
        "controlled_status_transition": true,
        "target_status": target_status,
        "reason": reason,
        "transition": {
            "from_status": previous_status,
            "to_status": target_status,
            "allowed_source_statuses": ["cooldown", "degraded", "recovery_probe"],
            "allowed_target_statuses": ["recovery_probe", "enabled"],
        },
        "provider_key": provider_key_response(provider_key.clone()),
        "upstream_probe": {
            "executed": false,
            "mode": "not_implemented",
            "billable": false,
            "request_log_write": false,
        },
        "billing": {
            "billable": false,
            "ledger_write": false,
        },
        "credential_material": {
            "omitted": true,
        },
    })
}

fn channel_manual_test_response(
    channel: &Channel,
    provider: &Provider,
    requested_model: &str,
    upstream_model: &str,
) -> Value {
    json!({
        "dry_run": true,
        "test_mode": "channel_manual_test",
        "upstream_call": false,
        "requested_model": requested_model,
        "upstream_model": upstream_model,
        "channel": {
            "id": channel.id,
            "name": channel.name,
            "status": channel.status,
            "protocol_mode": channel.protocol_mode,
            "endpoint": redact_secrets(&channel.endpoint),
            "priority": channel.priority,
            "weight": channel.weight,
            "health_score": channel.health_score,
        },
        "provider": {
            "id": provider.id,
            "code": provider.code,
            "name": provider.name,
            "status": provider.status,
        },
        "billing": {
            "billable": false,
            "ledger_write": false,
            "request_log_write": false,
        },
        "credential_material": {
            "provider_key_secret": "omitted",
            "secret_fingerprint": "omitted",
        },
        "request_plan": {
            "method": "POST",
            "path": "/v1/chat/completions",
            "protocol_mode": channel.protocol_mode,
            "model": upstream_model,
        },
        "next_steps": [
            "Dry-run only: no upstream provider call was made.",
            "Run a live manual probe only after provider-key selection and non-billable request logging are implemented."
        ],
    })
}

fn channel_manual_test_upstream_model(channel: &Channel, requested_model: &str) -> String {
    channel
        .model_mappings
        .get(requested_model)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(requested_model)
        .to_string()
}

fn route_dry_run_response(
    project_id: Uuid,
    profile_id: Uuid,
    requested_model: String,
    seed: u64,
    context: RouteSelectionContext,
    route_candidates: Option<DbRouteCandidates>,
    fallback_canonical_model: Option<CanonicalModel>,
) -> Value {
    let (canonical_model, db_candidates) = match route_candidates {
        Some(route_candidates) => (
            Some(route_candidates.canonical_model),
            route_candidates.candidates,
        ),
        None => (fallback_canonical_model, Vec::new()),
    };
    let routing_candidates = db_candidates
        .iter()
        .map(routing_candidate_from_db_candidate)
        .collect::<Vec<_>>();
    let mut route_request = RouteRequest::new(requested_model.clone(), seed);
    if let Some(canonical_model) = canonical_model.as_ref() {
        route_request = route_request.with_canonical_model(canonical_model.model_key.clone());
    }
    let decision = select_route_with_context(route_request, routing_candidates, context);
    let snapshot = decision.snapshot();
    let candidates = db_candidates
        .iter()
        .map(|candidate| {
            route_dry_run_candidate_response(
                candidate,
                snapshot_candidate_for(&snapshot, candidate),
            )
        })
        .collect::<Vec<_>>();
    let selected_candidate = candidates
        .iter()
        .find(|candidate| {
            candidate
                .get("selected")
                .and_then(Value::as_bool)
                .unwrap_or(false)
        })
        .cloned();

    json!({
        "project_id": project_id,
        "profile_id": profile_id,
        "requested_model": requested_model,
        "canonical_model": canonical_model.as_ref().map(route_dry_run_canonical_model_response),
        "route_policy_version": ROUTE_POLICY_VERSION,
        "decision_snapshot_version": ROUTE_DECISION_SNAPSHOT_VERSION,
        "policy": snapshot.policy,
        "trace_id": snapshot.trace_id,
        "trace_affinity": snapshot.trace_affinity,
        "selection": {
            "status": route_dry_run_selection_status(canonical_model.as_ref(), &snapshot),
            "selected_channel_id": snapshot.selected_channel_id,
            "selected": snapshot.selected,
        },
        "selected_candidate": selected_candidate,
        "candidates": candidates,
        "route_decision_snapshot": route_decision_snapshot_value(&snapshot),
    })
}

fn route_dry_run_canonical_model_response(model: &CanonicalModel) -> Value {
    json!({
        "id": model.id,
        "model_key": model.model_key,
        "display_name": model.display_name,
        "family": model.family,
        "status": model.status,
    })
}

fn route_dry_run_candidate_response(
    candidate: &ai_gateway_db::RouteCandidate,
    snapshot: Option<&RouteDecisionSnapshotCandidate>,
) -> Value {
    let upstream_model = candidate.resolved_upstream_model_name.clone();

    json!({
        "association_id": candidate.association.id,
        "association_type": candidate.association.association_type,
        "association_priority": candidate.association.priority,
        "fallback_allowed": candidate.association.fallback_allowed,
        "canonical_model_id": candidate.association.canonical_model_id,
        "channel_id": candidate.channel.id,
        "channel_name": candidate.channel.name,
        "channel_status": candidate.channel.status,
        "channel_priority": candidate.channel.priority,
        "channel_weight": candidate.channel.weight,
        "channel_health_score": candidate.channel.health_score,
        "provider_id": candidate.provider.id,
        "provider_code": candidate.provider.code,
        "provider_name": candidate.provider.name,
        "provider_status": candidate.provider.status,
        "provider_model": upstream_model,
        "upstream_model": candidate.resolved_upstream_model_name,
        "protocol_mode": candidate.channel.protocol_mode,
        "priority": snapshot.map(|candidate| candidate.priority),
        "weight": snapshot.map(|candidate| candidate.weight),
        "routing_status": snapshot.map(|candidate| candidate.status),
        "routing_health": snapshot.map(|candidate| candidate.health),
        "rate_limit_available": snapshot.map(|candidate| candidate.rate_limit_available),
        "filtered": snapshot.map(|candidate| candidate.filtered).unwrap_or(true),
        "filter_reason": snapshot.and_then(|candidate| candidate.filter_reason),
        "score": snapshot.and_then(|candidate| candidate.score),
        "selected": snapshot.map(|candidate| candidate.selected).unwrap_or(false),
        "trace_affinity_match": snapshot
            .map(|candidate| candidate.trace_affinity_match)
            .unwrap_or(false),
    })
}

fn snapshot_candidate_for<'a>(
    snapshot: &'a RouteDecisionSnapshot,
    candidate: &ai_gateway_db::RouteCandidate,
) -> Option<&'a RouteDecisionSnapshotCandidate> {
    snapshot.candidates.iter().find(|snapshot_candidate| {
        snapshot_candidate.channel_id == candidate.channel.id.to_string()
            && snapshot_candidate.provider_id == candidate.provider.id.to_string()
            && snapshot_candidate.provider_model == candidate.resolved_upstream_model_name
    })
}

fn route_dry_run_selection_status(
    canonical_model: Option<&CanonicalModel>,
    snapshot: &RouteDecisionSnapshot,
) -> &'static str {
    if snapshot.selected.is_some() {
        "selected"
    } else if snapshot.candidates.is_empty() {
        if canonical_model.is_some() {
            "no_route_candidates"
        } else {
            "model_not_found_or_not_allowed"
        }
    } else {
        "all_candidates_filtered"
    }
}

fn route_selection_context(
    trace_id: Option<String>,
    previous_successful_channel_id: Option<String>,
) -> RouteSelectionContext {
    let mut context = RouteSelectionContext::new();
    if let Some(trace_id) = trace_id {
        context = context.with_trace_id(trace_id);
    }
    if let Some(channel_id) = previous_successful_channel_id {
        context = context.with_trace_affinity_channel(channel_id);
    }
    context
}

fn routing_candidate_from_db_candidate(
    candidate: &ai_gateway_db::RouteCandidate,
) -> RoutingRouteCandidate {
    RoutingRouteCandidate::new(
        candidate.channel.id.to_string(),
        candidate.provider.id.to_string(),
        candidate.resolved_upstream_model_name.clone(),
        route_priority_for_routing(&candidate.association, &candidate.channel),
        u32::try_from(candidate.channel.weight).unwrap_or(0),
    )
    .with_status(channel_status_for_routing(&candidate.channel.status))
    .with_health(channel_health_for_routing(candidate.channel.health_score))
}

fn route_priority_for_routing(association: &ModelAssociation, channel: &Channel) -> i32 {
    association
        .priority
        .saturating_mul(ROUTE_PRIORITY_ASSOCIATION_MULTIPLIER)
        .saturating_add(channel.priority)
}

fn channel_status_for_routing(status: &str) -> ChannelStatus {
    match status {
        "enabled" => ChannelStatus::Enabled,
        "degraded" => ChannelStatus::Degraded,
        "disabled" => ChannelStatus::Disabled,
        "cooldown" | "cooling_down" => ChannelStatus::CoolingDown,
        "recovery_probe" => ChannelStatus::RecoveryProbe,
        "auth_failed" => ChannelStatus::AuthFailed,
        "quota_exhausted" => ChannelStatus::QuotaExhausted,
        "manual_disabled" => ChannelStatus::ManualDisabled,
        "deleted" => ChannelStatus::Deleted,
        _ => ChannelStatus::Disabled,
    }
}

fn channel_health_for_routing(health_score: f64) -> ChannelHealth {
    if !health_score.is_finite() || health_score <= 0.0 {
        ChannelHealth::Unhealthy
    } else if health_score < 0.5 {
        ChannelHealth::Degraded
    } else {
        ChannelHealth::Healthy
    }
}

fn route_decision_snapshot_value(snapshot: &RouteDecisionSnapshot) -> Value {
    serde_json::to_value(snapshot).unwrap_or_else(|_| json!({}))
}

fn virtual_key_response(virtual_key: VirtualKey, secret: Option<String>) -> Value {
    let mut response = json!({
        "id": virtual_key.id,
        "tenant_id": virtual_key.tenant_id,
        "project_id": virtual_key.project_id,
        "name": virtual_key.name,
        "key_prefix": virtual_key.key_prefix,
        "status": normalize_virtual_key_status_for_response(&virtual_key.status),
        "default_profile_id": virtual_key.default_profile_id,
        "ip_allowlist": virtual_key.ip_allowlist,
        "rate_limit_policy": virtual_key.rate_limit_policy,
        "budget_policy": virtual_key.budget_policy,
        "metadata": redact_provider_key_metadata(virtual_key.metadata),
        "secret_redacted": secret.is_none(),
    });

    if let Some(secret) = secret {
        let object = response
            .as_object_mut()
            .expect("virtual key response must be a JSON object");
        object.insert("secret".to_string(), Value::String(secret));
        object.insert("secret_once".to_string(), Value::Bool(true));
    }

    response
}

fn normalize_enabled_status(status: Option<&str>) -> String {
    match status {
        Some("active" | "enabled") | None => "enabled".to_string(),
        Some("disabled") => "disabled".to_string(),
        Some("degraded") => "degraded".to_string(),
        Some("cooldown") => "cooldown".to_string(),
        Some("deleted") => "deleted".to_string(),
        Some(value) => value.to_string(),
    }
}

fn normalize_api_key_profile_status(status: Option<&str>) -> Result<String, AdminError> {
    let normalized = normalize_optional_token(status);
    match normalized.as_deref() {
        Some("active" | "enabled") | None => Ok("active".to_string()),
        Some("disabled" | "manual_disabled") => Ok("disabled".to_string()),
        Some("deleted") => Ok("deleted".to_string()),
        Some("") => Err(AdminError::bad_request("status must not be empty")),
        Some(value) => Err(AdminError::bad_request(format!(
            "unsupported api key profile status `{value}`"
        ))),
    }
}

fn normalize_virtual_key_status(status: Option<&str>) -> Result<String, AdminError> {
    let normalized = normalize_optional_token(status);
    match normalized.as_deref() {
        Some("active" | "enabled") | None => Ok("active".to_string()),
        Some("disabled" | "manual_disabled") => Ok("disabled".to_string()),
        Some("expired") => Ok("expired".to_string()),
        Some("deleted") => Ok("deleted".to_string()),
        Some("") => Err(AdminError::bad_request("status must not be empty")),
        Some(value) => Err(AdminError::bad_request(format!(
            "unsupported virtual key status `{value}`"
        ))),
    }
}

fn normalize_virtual_key_status_query(
    status: Option<String>,
) -> Result<Option<String>, AdminError> {
    match optional_non_empty(status) {
        Some(status) => normalize_virtual_key_status(Some(&status)).map(Some),
        None => Ok(None),
    }
}

fn normalize_price_version_status_query(
    status: Option<String>,
) -> Result<Option<String>, AdminError> {
    match optional_non_empty(status) {
        Some(status) => {
            let normalized = status.trim().to_ascii_lowercase();
            match normalized.as_str() {
                "draft" | "active" | "retired" => Ok(Some(normalized)),
                value => Err(AdminError::bad_request(format!(
                    "unsupported price version status `{value}`"
                ))),
            }
        }
        None => Ok(None),
    }
}

fn normalize_price_version_status(status: Option<&str>) -> Result<String, AdminError> {
    match normalize_optional_token(status).as_deref() {
        None => Ok("draft".to_string()),
        Some("draft" | "active" | "retired") => {
            Ok(normalize_optional_token(status).expect("status is present"))
        }
        Some("") => Err(AdminError::bad_request("status must not be empty")),
        Some(value) => Err(AdminError::bad_request(format!(
            "unsupported price version status `{value}`"
        ))),
    }
}

fn normalize_price_version_effective_at(
    effective_at: Option<String>,
) -> Result<Option<String>, AdminError> {
    normalize_optional_price_version_timestamp(effective_at, "effective_at")
}

fn normalize_price_version_retired_at(
    retired_at: Option<String>,
) -> Result<Option<String>, AdminError> {
    normalize_optional_price_version_timestamp(retired_at, "retired_at")
}

fn normalize_optional_price_version_timestamp(
    value: Option<String>,
    field: &'static str,
) -> Result<Option<String>, AdminError> {
    let Some(value) = value else {
        return Ok(None);
    };
    let value = value.trim();
    if value.is_empty() {
        return Err(AdminError::bad_request(format!(
            "{field} must not be empty"
        )));
    }
    if value.len() > 64 || !value.is_ascii() {
        return Err(AdminError::bad_request(format!(
            "{field} must be an ASCII timestamp"
        )));
    }

    Ok(Some(value.to_string()))
}

fn normalize_virtual_key_status_for_response(status: &str) -> String {
    normalize_virtual_key_status(Some(status)).unwrap_or_else(|_| status.to_string())
}

fn normalize_inbound_protocol(protocol: Option<&str>) -> Result<String, AdminError> {
    let normalized = normalize_optional_token(protocol);
    match normalized.as_deref() {
        Some("auto") | None => Ok("auto".to_string()),
        Some("openai") => Ok("openai".to_string()),
        Some("anthropic") => Ok("anthropic".to_string()),
        Some("gemini") => Ok("gemini".to_string()),
        Some("") => Err(AdminError::bad_request(
            "inbound_protocol must not be empty",
        )),
        Some(value) => Err(AdminError::bad_request(format!(
            "unsupported inbound_protocol `{value}`"
        ))),
    }
}

fn normalize_api_key_profile_protocol_mode(protocol: Option<&str>) -> Result<String, AdminError> {
    let normalized = normalize_optional_token(protocol);
    let protocol = match normalized.as_deref() {
        None => return Ok("openai_compatible".to_string()),
        Some("") => {
            return Err(AdminError::bad_request(
                "default_protocol_mode must not be empty",
            ));
        }
        Some(value) => normalize_protocol_mode(value),
    };

    match protocol.as_str() {
        "openai_compatible" | "native_proxy" | "adapter_transform" => Ok(protocol),
        value => Err(AdminError::bad_request(format!(
            "unsupported default_protocol_mode `{value}`"
        ))),
    }
}

fn normalize_optional_token(value: Option<&str>) -> Option<String> {
    value.map(|value| value.trim().to_ascii_lowercase())
}

fn normalize_provider_key_status(status: Option<&str>) -> Result<String, AdminError> {
    let status = normalize_optional_token(status);
    match status.as_deref() {
        Some("active" | "enabled") | None => Ok("enabled".to_string()),
        Some("disabled" | "manual_disabled") => Ok("manual_disabled".to_string()),
        Some("degraded") => Ok("degraded".to_string()),
        Some("cooldown") => Ok("cooldown".to_string()),
        Some("recovery_probe") => Ok("recovery_probe".to_string()),
        Some("auth_failed") => Ok("auth_failed".to_string()),
        Some("quota_exhausted") => Ok("quota_exhausted".to_string()),
        Some("deleted") => Ok("deleted".to_string()),
        Some(value) => Err(AdminError::bad_request(format!(
            "unsupported provider key status `{value}`"
        ))),
    }
}

fn normalize_provider_key_manual_patch_status(
    status: Option<&str>,
    current_status: &str,
) -> Result<String, AdminError> {
    let Some(status) = status else {
        return Ok(current_status.to_string());
    };
    let status = normalize_provider_key_status(Some(status))?;
    validate_provider_key_manual_patch_status(&status)?;
    Ok(status)
}

fn validate_provider_key_manual_patch_status(status: &str) -> Result<(), AdminError> {
    match status {
        "enabled" | "manual_disabled" | "degraded" | "recovery_probe" => Ok(()),
        "auth_failed" | "quota_exhausted" | "cooldown" => Err(AdminError::bad_request(format!(
            "provider key status `{status}` is runtime-managed and cannot be entered through admin patch"
        ))),
        "deleted" => Err(AdminError::bad_request(
            "provider key status `deleted` must be reached through DELETE /admin/provider-keys/{id}",
        )),
        value => Err(AdminError::bad_request(format!(
            "unsupported provider key status `{value}`"
        ))),
    }
}

fn normalize_provider_key_recovery_target(
    target_status: Option<&str>,
) -> Result<String, AdminError> {
    let normalized = match target_status {
        Some(value) if value.trim().is_empty() => {
            return Err(AdminError::bad_request(
                "provider key recovery target_status must not be empty",
            ));
        }
        Some(value) => match normalize_optional_token(Some(value)).as_deref() {
            Some("active" | "enabled") => "enabled".to_string(),
            Some("recovery_probe") => "recovery_probe".to_string(),
            Some(
                "auth_failed" | "quota_exhausted" | "cooldown" | "manual_disabled" | "disabled"
                | "degraded" | "deleted",
            ) => normalize_provider_key_status(Some(value))?,
            Some(_) | None => {
                return Err(AdminError::bad_request(
                    "unsupported provider key recovery target",
                ));
            }
        },
        None => "recovery_probe".to_string(),
    };

    match normalized.as_str() {
        "recovery_probe" | "enabled" => Ok(normalized),
        "auth_failed" | "quota_exhausted" | "cooldown" | "manual_disabled" | "degraded"
        | "deleted" => Err(AdminError::bad_request(format!(
            "provider key recovery target `{normalized}` is not allowed"
        ))),
        _ => Err(AdminError::bad_request(
            "unsupported provider key recovery target",
        )),
    }
}

fn validate_provider_key_recovery_transition(
    current_status: &str,
    target_status: &str,
) -> Result<(), AdminError> {
    match current_status {
        "cooldown" | "degraded" | "recovery_probe" => {}
        "auth_failed" | "quota_exhausted" | "manual_disabled" | "enabled" | "deleted" => {
            return Err(AdminError::bad_request(format!(
                "provider key status `{current_status}` cannot be recovered through this endpoint"
            )));
        }
        value => {
            return Err(AdminError::bad_request(format!(
                "unsupported provider key current status `{value}`"
            )));
        }
    }

    match target_status {
        "recovery_probe" | "enabled" => Ok(()),
        value => Err(AdminError::bad_request(format!(
            "provider key recovery target `{value}` is not allowed"
        ))),
    }
}

fn normalize_provider_key_recovery_reason(
    reason: Option<String>,
) -> Result<Option<String>, AdminError> {
    let Some(reason) = reason else {
        return Ok(None);
    };
    let reason = reason.trim();
    if reason.is_empty() {
        return Ok(None);
    }
    if reason.len() > 256 {
        return Err(AdminError::bad_request(
            "provider key recovery reason must be at most 256 bytes",
        ));
    }

    Ok(Some(redact_secrets(reason)))
}

fn normalize_provider_status(status: Option<&str>) -> String {
    match status {
        Some("active" | "enabled") | None => "enabled".to_string(),
        Some("disabled") => "disabled".to_string(),
        Some("deleted") => "deleted".to_string(),
        Some(value) => value.to_string(),
    }
}

fn normalize_model_status(status: Option<&str>) -> String {
    match status {
        Some(value) => value.to_string(),
        None => "active".to_string(),
    }
}

fn normalize_protocol_mode(protocol: &str) -> String {
    match protocol {
        "openai" | "openai_compatible" => "openai_compatible".to_string(),
        "native" | "native_proxy" => "native_proxy".to_string(),
        "adapter" | "adapter_transform" => "adapter_transform".to_string(),
        value => value.to_string(),
    }
}

#[derive(Debug)]
struct AdminError {
    status: StatusCode,
    code: &'static str,
    message: String,
}

impl AdminError {
    fn bad_request(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            code: "bad_request",
            message: message.into(),
        }
    }

    fn not_found(resource: &'static str) -> Self {
        Self {
            status: StatusCode::NOT_FOUND,
            code: "not_found",
            message: format!("{resource} not found"),
        }
    }

    fn configuration_error(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            code: "configuration_error",
            message: message.into(),
        }
    }
}

impl From<DbError> for AdminError {
    fn from(_error: DbError) -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            code: "database_error",
            message: "database operation failed".to_string(),
        }
    }
}

impl IntoResponse for AdminError {
    fn into_response(self) -> Response {
        (
            self.status,
            Json(json!({
                "error": {
                    "code": self.code,
                    "message": self.message
                }
            })),
        )
            .into_response()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn provider_key_master_key_config() -> ProviderKeyMasterKeyConfig {
        ProviderKeyMasterKeyConfig {
            key: [7_u8; PROVIDER_KEY_MASTER_KEY_LEN],
            key_id: "test-key-v1".to_string(),
        }
    }

    fn create_provider_key_request() -> CreateProviderKeyRequest {
        CreateProviderKeyRequest {
            channel_id: Uuid::from_u128(3),
            key_alias: "primary".to_string(),
            status: None,
            metadata: Some(json!({ "owner": "ops" })),
            secret: Some("sk-live-create-secret".to_string()),
            api_key: None,
            encrypted_secret_supplied: false,
            secret_fingerprint_supplied: false,
        }
    }

    fn virtual_key_fixture() -> VirtualKey {
        VirtualKey {
            id: Uuid::from_u128(10),
            tenant_id: DEFAULT_TENANT_ID,
            project_id: Uuid::from_u128(11),
            name: "default client key".to_string(),
            key_prefix: "vk_test_pref".to_string(),
            secret_hash: "secret-hash-never-return".to_string(),
            status: "enabled".to_string(),
            default_profile_id: Some(Uuid::from_u128(12)),
            ip_allowlist: json!([]),
            rate_limit_policy: json!({}),
            budget_policy: json!({}),
            metadata: json!({ "owner": "ops" }),
        }
    }

    fn canonical_model_fixture() -> CanonicalModel {
        CanonicalModel {
            id: Uuid::from_u128(101),
            tenant_id: DEFAULT_TENANT_ID,
            model_key: "gpt-visible".to_string(),
            display_name: "GPT Visible".to_string(),
            family: Some("gpt".to_string()),
            capabilities: json!({}),
            context_length: Some(128_000),
            max_output_tokens: Some(16_384),
            supports_stream: true,
            supports_tools: true,
            supports_vision: false,
            supports_audio: false,
            supports_reasoning: false,
            visibility: "public".to_string(),
            status: "active".to_string(),
        }
    }

    fn price_version_fixture() -> PriceVersion {
        PriceVersion {
            id: Uuid::from_u128(61),
            tenant_id: DEFAULT_TENANT_ID,
            price_book_id: Uuid::from_u128(60),
            canonical_model_id: Some(Uuid::from_u128(101)),
            version: "2026-06-03".to_string(),
            pricing_rules: json!({
                "currency": "USD",
                "scale": 8,
                "input_token_rate_per_1m": "0.15000000",
                "output_token_rate_per_1m": "0.60000000",
                "cache_token_rate_per_1m": "0.03000000",
                "fixed_request_cost": "0.00000000"
            }),
            effective_at: "2026-06-03 00:00:00+00".to_string(),
            retired_at: None,
            status: "active".to_string(),
            created_at: "2026-06-03 00:00:01+00".to_string(),
        }
    }

    fn route_candidate_fixture(
        channel_id: u128,
        channel_status: &str,
        channel_weight: i32,
        health_score: f64,
    ) -> ai_gateway_db::RouteCandidate {
        let provider_id = Uuid::from_u128(201);
        ai_gateway_db::RouteCandidate {
            association: ModelAssociation {
                id: Uuid::from_u128(301),
                tenant_id: DEFAULT_TENANT_ID,
                canonical_model_id: Uuid::from_u128(101),
                association_type: "explicit_channel".to_string(),
                channel_id: Some(Uuid::from_u128(channel_id)),
                channel_tag: None,
                model_pattern: None,
                upstream_model_name: Some("upstream-gpt".to_string()),
                priority: 2,
                conditions: json!({}),
                fallback_allowed: true,
                canary_percent: 100.0,
                status: "enabled".to_string(),
            },
            channel: Channel {
                id: Uuid::from_u128(channel_id),
                tenant_id: DEFAULT_TENANT_ID,
                provider_id,
                name: "primary channel".to_string(),
                endpoint: "https://provider.example/v1".to_string(),
                protocol_mode: "openai_compatible".to_string(),
                status: channel_status.to_string(),
                region: Some("us".to_string()),
                priority: 10,
                weight: channel_weight,
                tags: json!(["primary"]),
                model_mappings: json!({ "gpt-visible": "upstream-gpt" }),
                request_overrides: json!([]),
                timeout_policy: json!({}),
                probe_policy: json!({}),
                health_score,
            },
            provider: Provider {
                id: provider_id,
                tenant_id: DEFAULT_TENANT_ID,
                code: "provider-a".to_string(),
                name: "Provider A".to_string(),
                status: "enabled".to_string(),
                metadata: json!({
                    "encrypted_secret": "encrypted-secret-never-return",
                    "secret_fingerprint": "fingerprint-never-return"
                }),
            },
            resolved_upstream_model_name: "upstream-gpt".to_string(),
        }
    }

    fn provider_key_fixture(channel_id: Uuid) -> ProviderKey {
        ProviderKey {
            id: Uuid::from_u128(501),
            tenant_id: DEFAULT_TENANT_ID,
            channel_id,
            key_alias: "primary".to_string(),
            has_secret_fingerprint: true,
            status: "auth_failed".to_string(),
            health_score: 0.25,
            cooldown_until: Some("2026-06-02 12:05:00+00".to_string()),
            last_error_code: Some("provider_auth_failed".to_string()),
            rpm_limit: Some(60),
            tpm_limit: Some(100_000),
            concurrency_limit: Some(8),
            current_window_state: json!({
                "token": "sk-live-window-state-never-return"
            }),
            metadata: json!({
                "owner": "ops",
                "api_key": "sk-live-provider-key-metadata-never-return"
            }),
            secret_redacted: true,
        }
    }

    fn request_log_summary_fixture(
        id: u128,
        status: &str,
        error_code: Option<&str>,
        provider_id: Uuid,
        channel_id: Uuid,
        provider_key_id: Uuid,
        model_id: Uuid,
    ) -> RequestLogSummary {
        RequestLogSummary {
            id: Uuid::from_u128(id),
            tenant_id: DEFAULT_TENANT_ID,
            project_id: None,
            virtual_key_id: None,
            api_key_profile_id: None,
            trace_id: Some(format!("trace-{id}")),
            thread_id: None,
            client_request_id: None,
            inbound_protocol: Some("openai".to_string()),
            outbound_protocol: Some("openai".to_string()),
            protocol_mode: Some("openai_compatible".to_string()),
            requested_model: Some("gpt-visible".to_string()),
            canonical_model_id: Some(model_id),
            upstream_model: Some("upstream-gpt".to_string()),
            resolved_provider_id: Some(provider_id),
            resolved_channel_id: Some(channel_id),
            provider_key_id: Some(provider_key_id),
            route_policy_version: Some(ROUTE_POLICY_VERSION.to_string()),
            status: status.to_string(),
            http_status: error_code.map(|_| 401),
            error_owner: error_code.map(|_| "provider".to_string()),
            error_code: error_code.map(str::to_string),
            retryable: error_code.map(|_| false),
            partial_sent: false,
            stream_end_reason: Some("completed".to_string()),
            input_tokens: 1,
            output_tokens: 2,
            final_cost: "0".to_string(),
            currency: "USD".to_string(),
            latency_ms: Some(12),
            ttft_ms: Some(4),
            payload_policy_id: None,
            payload_stored: true,
            redaction_status: "hash_only".to_string(),
            request_body_hash: Some("req-hash".to_string()),
            response_body_hash: Some("resp-hash".to_string()),
            created_at: format!("2026-06-02 12:00:0{id}+00"),
            completed_at: Some(format!("2026-06-02 12:00:0{id}+00")),
        }
    }

    #[test]
    fn admin_router_builds_with_health_summary_route() {
        let _ = router();
    }

    #[test]
    fn route_dry_run_response_selects_candidate_and_omits_secret_material() {
        let mut candidate = route_candidate_fixture(401, "enabled", 100, 1.0);
        candidate.association.fallback_allowed = false;
        let response = route_dry_run_response(
            Uuid::from_u128(11),
            Uuid::from_u128(12),
            "gpt-visible".to_string(),
            0,
            RouteSelectionContext::new(),
            Some(DbRouteCandidates {
                canonical_model: canonical_model_fixture(),
                candidates: vec![candidate],
            }),
            None,
        );
        let serialized = serde_json::to_string(&response).expect("response should serialize");

        assert_eq!(
            response["route_policy_version"],
            json!(ROUTE_POLICY_VERSION)
        );
        assert_eq!(response["selection"]["status"], json!("selected"));
        assert_eq!(
            response["selected_candidate"]["upstream_model"],
            json!("upstream-gpt")
        );
        assert_eq!(
            response["selected_candidate"]["fallback_allowed"],
            json!(false)
        );
        assert_eq!(response["candidates"][0]["fallback_allowed"], json!(false));
        assert_eq!(response["selected_candidate"]["filter_reason"], Value::Null);
        assert!(!serialized.contains("encrypted-secret-never-return"));
        assert!(!serialized.contains("fingerprint-never-return"));
        assert!(!serialized.contains("encrypted_secret"));
        assert!(!serialized.contains("secret_fingerprint"));
        assert!(!serialized.contains("api_key"));
    }

    #[test]
    fn channel_manual_test_response_is_dry_run_and_omits_secret_material() {
        let candidate = route_candidate_fixture(401, "enabled", 100, 1.0);
        let mut channel = candidate.channel;
        channel.endpoint =
            "https://provider.example/v1?api_key=sk-live-endpoint-secret".to_string();
        let provider = candidate.provider;
        let upstream_model = channel_manual_test_upstream_model(&channel, "gpt-visible");
        let response =
            channel_manual_test_response(&channel, &provider, "gpt-visible", &upstream_model);
        let serialized = serde_json::to_string(&response).expect("response should serialize");

        assert_eq!(upstream_model, "upstream-gpt");
        assert_eq!(response["dry_run"], json!(true));
        assert_eq!(response["upstream_call"], json!(false));
        assert_eq!(response["billing"]["billable"], json!(false));
        assert_eq!(response["billing"]["ledger_write"], json!(false));
        assert_eq!(response["billing"]["request_log_write"], json!(false));
        assert_eq!(
            response["credential_material"]["provider_key_secret"],
            json!("omitted")
        );
        assert_eq!(
            response["credential_material"]["secret_fingerprint"],
            json!("omitted")
        );
        assert_eq!(response["request_plan"]["model"], json!("upstream-gpt"));
        assert!(!serialized.contains("sk-live-endpoint-secret"));
        assert!(!serialized.contains("encrypted-secret-never-return"));
        assert!(!serialized.contains("fingerprint-never-return"));
        assert!(!serialized.contains("encrypted_secret"));
    }

    #[test]
    fn channel_manual_test_contract_fixture_omits_provider_credentials() {
        let fixture = serde_json::from_str::<Value>(include_str!(
            "../../../tests/fixtures/control-plane/channel_manual_test_contract.json"
        ))
        .expect("fixture should be valid json");
        let serialized = serde_json::to_string(&fixture).expect("fixture should serialize");

        assert_eq!(
            fixture["endpoint"]["path"],
            json!("/admin/channels/{id}/manual-test")
        );
        assert_eq!(
            fixture["examples"]["dry_run"]["response"]["data"]["upstream_call"],
            json!(false)
        );
        assert_eq!(
            fixture["examples"]["dry_run"]["response"]["data"]["billing"]["ledger_write"],
            json!(false)
        );
        assert_eq!(
            fixture["response_contract"]["credential_material_omitted"],
            json!(true)
        );
        assert!(!serialized.contains("sk-"));
        assert!(!serialized.contains("encrypted_secret"));
    }

    #[test]
    fn health_summary_response_counts_entities_and_omits_secret_material() {
        let candidate = route_candidate_fixture(401, "enabled", 100, 1.0);
        let provider = Provider {
            name: "Provider sk-live-provider-name-never-return".to_string(),
            metadata: json!({
                "secret": "sk-live-provider-metadata-never-return",
                "secret_fingerprint": "fingerprint-never-return"
            }),
            ..candidate.provider
        };
        let mut channel = candidate.channel;
        channel.endpoint = "https://provider.example/v1?api_key=sk-live-endpoint".to_string();
        let mut provider_key = provider_key_fixture(channel.id);
        provider_key.key_alias = "sk-live-provider-key-alias-never-return".to_string();
        let model = canonical_model_fixture();
        let association = ModelAssociation {
            id: Uuid::from_u128(301),
            tenant_id: DEFAULT_TENANT_ID,
            canonical_model_id: model.id,
            association_type: "explicit_channel".to_string(),
            channel_id: Some(channel.id),
            channel_tag: None,
            model_pattern: None,
            upstream_model_name: Some("upstream-gpt".to_string()),
            priority: 1,
            conditions: json!({}),
            fallback_allowed: true,
            canary_percent: 100.0,
            status: "enabled".to_string(),
        };
        let logs = vec![
            request_log_summary_fixture(
                2,
                "failed",
                Some("provider_auth_failed"),
                provider.id,
                channel.id,
                provider_key.id,
                model.id,
            ),
            request_log_summary_fixture(
                1,
                "succeeded",
                None,
                provider.id,
                channel.id,
                provider_key.id,
                model.id,
            ),
        ];

        let response = health_summary_response(
            &[provider],
            &[channel],
            &[provider_key],
            &[model],
            &[association],
            &logs,
            ProviderHealthSummaryFilter {
                window_minutes: 15,
                sample_limit: 500,
            },
        );
        let serialized = serde_json::to_string(&response).expect("response should serialize");

        assert_eq!(response["summary_version"], json!(1));
        assert_eq!(response["recent_window"]["window_minutes"], json!(15));
        assert_eq!(
            response["recent_window"]["window"],
            json!({ "unit": "minutes", "minutes": 15 })
        );
        assert_eq!(response["recent_window"]["sample_count"], json!(2));
        assert_eq!(response["recent_window"]["success_count"], json!(1));
        assert_eq!(response["recent_window"]["error_count"], json!(1));
        assert_eq!(response["recent_window"]["success_rate"], json!(0.5));
        assert_eq!(response["status_counts"]["providers"]["enabled"], json!(1));
        assert_eq!(response["status_counts"]["channels"]["enabled"], json!(1));
        assert_eq!(
            response["status_counts"]["provider_keys"]["auth_failed"],
            json!(1)
        );
        assert_eq!(response["status_counts"]["models"]["active"], json!(1));
        assert_eq!(
            response["providers"][0]["recent"]["request_count"],
            json!(2)
        );
        assert_eq!(
            response["providers"][0]["recent"]["success_count"],
            json!(1)
        );
        assert_eq!(response["providers"][0]["recent"]["error_count"], json!(1));
        assert_eq!(
            response["providers"][0]["recent"]["success_rate"],
            json!(0.5)
        );
        assert_eq!(
            response["provider_keys"][0]["credential_configured"],
            json!(true)
        );
        assert_eq!(
            response["provider_keys"][0]["configured_last_error_code"],
            json!("provider_auth_failed")
        );
        assert_eq!(
            response["provider_keys"][0]["recent"]["last_error"]["code"],
            json!("provider_auth_failed")
        );
        assert_eq!(response["channels"][0]["model_count"], json!(1));
        assert_eq!(response["models"][0]["routing_state"], json!("routable"));

        for forbidden in [
            "sk-live",
            "encrypted_secret",
            "secret_fingerprint",
            "has_secret_fingerprint",
            "api_key",
            "fingerprint-never-return",
            "current_window_state",
        ] {
            assert!(
                !serialized.contains(forbidden),
                "health summary response must not contain {forbidden}"
            );
        }
    }

    #[test]
    fn health_summary_contract_fixture_omits_provider_credentials() {
        let fixture = serde_json::from_str::<Value>(include_str!(
            "../../../tests/fixtures/control-plane/health_summary_contract.json"
        ))
        .expect("fixture should be valid json");
        let serialized = serde_json::to_string(&fixture).expect("fixture should serialize");

        assert_eq!(
            fixture["endpoint"]["path"],
            json!("/admin/providers/health-summary")
        );
        assert_eq!(fixture["response_contract"]["envelope"], json!("data"));
        assert_eq!(
            fixture["response_contract"]["credential_material_omitted"],
            json!(true)
        );
        assert_eq!(
            fixture["examples"]["summary"]["response"]["data"]["provider_keys"][0]["credential_configured"],
            json!(true)
        );
        assert_eq!(
            fixture["examples"]["summary"]["response"]["data"]["recent_window"]["window_minutes"],
            json!(60)
        );
        assert_eq!(
            fixture["examples"]["summary"]["response"]["data"]["recent_window"]["success_rate"],
            json!(0.5)
        );
        assert_eq!(
            fixture["examples"]["summary"]["response"]["data"]["provider_keys"][0]["recent"]["last_error"]
                ["code"],
            json!("provider_auth_failed")
        );
        assert_eq!(
            fixture["examples"]["summary"]["response"]["data"]["provider_keys"][0]["recent"]["success_rate"],
            json!(0.5)
        );

        for forbidden in [
            "sk-",
            "encrypted_secret",
            "secret_fingerprint",
            "has_secret_fingerprint",
            "api_key",
            "current_window_state",
        ] {
            assert!(
                !serialized.contains(forbidden),
                "health summary fixture must not contain {forbidden}"
            );
        }
    }

    #[test]
    fn billing_reconciliation_contract_fixture_omits_payload_and_secrets() {
        let fixture = serde_json::from_str::<Value>(include_str!(
            "../../../tests/fixtures/control-plane/billing_reconciliation_contract.json"
        ))
        .expect("fixture should be valid json");
        let serialized = serde_json::to_string(&fixture).expect("fixture should serialize");

        assert_eq!(
            fixture["endpoint"]["path"],
            json!("/admin/billing/reconciliation")
        );
        assert_eq!(fixture["response_contract"]["envelope"], json!("data"));
        assert_eq!(
            fixture["response_contract"]["payload_material_omitted"],
            json!(true)
        );
        assert_eq!(
            fixture["examples"]["report"]["response"]["data"]["summary"]["missing_ledger_count"],
            json!(1)
        );
        assert_eq!(
            fixture["examples"]["report"]["response"]["data"]["discrepancies"][0]["issues"][0],
            json!("missing_ledger")
        );

        for forbidden in [
            "payload_object_ref",
            "request_body",
            "response_body",
            "sk-",
            "api_key",
            "encrypted_secret",
            "secret_fingerprint",
            "secret_hash",
        ] {
            assert!(
                !serialized.contains(forbidden),
                "billing reconciliation fixture must not contain {forbidden}"
            );
        }
    }

    #[test]
    fn billing_read_contract_fixture_omits_payload_and_secrets() {
        let fixture = serde_json::from_str::<Value>(include_str!(
            "../../../tests/fixtures/control-plane/billing_read_contract.json"
        ))
        .expect("fixture should be valid json");
        let serialized = serde_json::to_string(&fixture).expect("fixture should serialize");

        assert_eq!(
            fixture["endpoints"]["price_versions"]["path"],
            json!("/admin/price-versions")
        );
        assert_eq!(
            fixture["endpoints"]["ledger_entries"]["path"],
            json!("/admin/ledger/entries")
        );
        assert_eq!(fixture["response_contract"]["envelope"], json!("data"));
        assert_eq!(
            fixture["response_contract"]["billing_read_permission"],
            json!(true)
        );
        assert_eq!(
            fixture["examples"]["price_versions"]["response"]["data"][0]["pricing_rules"]["currency"],
            json!("USD")
        );
        assert_eq!(
            fixture["examples"]["ledger_entries"]["response"]["data"][0]["usage_snapshot"]["input_tokens"],
            json!(12)
        );
        assert_eq!(
            fixture["examples"]["ledger_entries"]["response"]["data"][0]["policy_snapshot"]["rating_mode"],
            json!("per_token")
        );

        for forbidden in [
            "payload_object_ref",
            "request_body",
            "response_body",
            "sk-",
            "api_key",
            "encrypted_secret",
            "secret_fingerprint",
            "secret_hash",
            "private_key",
        ] {
            assert!(
                !serialized.contains(forbidden),
                "billing read fixture must not contain {forbidden}"
            );
        }
    }

    #[test]
    fn route_dry_run_response_expresses_no_candidate_without_error_shape() {
        let response = route_dry_run_response(
            Uuid::from_u128(11),
            Uuid::from_u128(12),
            "missing-model".to_string(),
            0,
            RouteSelectionContext::new(),
            None,
            None,
        );

        assert_eq!(
            response["selection"]["status"],
            json!("model_not_found_or_not_allowed")
        );
        assert_eq!(response["selection"]["selected"], Value::Null);
        assert_eq!(response["selected_candidate"], Value::Null);
        assert_eq!(response["candidates"], json!([]));
        assert_eq!(response["canonical_model"], Value::Null);
    }

    #[test]
    fn route_dry_run_response_includes_filter_reason_when_candidate_is_not_selectable() {
        let response = route_dry_run_response(
            Uuid::from_u128(11),
            Uuid::from_u128(12),
            "gpt-visible".to_string(),
            0,
            RouteSelectionContext::new(),
            Some(DbRouteCandidates {
                canonical_model: canonical_model_fixture(),
                candidates: vec![route_candidate_fixture(401, "disabled", 100, 1.0)],
            }),
            None,
        );

        assert_eq!(
            response["selection"]["status"],
            json!("all_candidates_filtered")
        );
        assert_eq!(response["selection"]["selected"], Value::Null);
        assert_eq!(response["candidates"][0]["filtered"], json!(true));
        assert_eq!(
            response["candidates"][0]["filter_reason"],
            json!("Disabled")
        );
    }

    #[test]
    fn route_dry_run_contract_fixture_omits_provider_credentials() {
        let fixture_raw = include_str!(
            "../../../tests/fixtures/control-plane/model_association_dry_run_contract.json"
        );
        let fixture: Value =
            serde_json::from_str(fixture_raw).expect("dry-run fixture should be valid json");
        let serialized = serde_json::to_string(&fixture).expect("fixture should serialize");

        for forbidden in [
            "encrypted_secret",
            "secret_fingerprint",
            "provider_secret",
            "api_key",
            "raw_key",
            "sk-",
        ] {
            assert!(
                !serialized.contains(forbidden),
                "dry-run fixture must not contain {forbidden}"
            );
        }
        assert_eq!(
            fixture["response_contract"]["credential_material_omitted"],
            json!(true)
        );
        assert_eq!(
            fixture["examples"]["selected"]["response"]["data"]["route_policy_version"],
            json!(ROUTE_POLICY_VERSION)
        );
        assert_eq!(
            fixture["examples"]["selected"]["response"]["data"]["selection"]["status"],
            json!("selected")
        );
        let candidate_required_fields = fixture["response_contract"]["candidate_required_fields"]
            .as_array()
            .expect("candidate required fields should be an array");
        assert!(
            candidate_required_fields
                .iter()
                .any(|field| field.as_str() == Some("fallback_allowed")),
            "dry-run candidate contract must require fallback_allowed"
        );
        assert_eq!(
            fixture["examples"]["selected"]["response"]["data"]["selected_candidate"]["fallback_allowed"],
            json!(true)
        );
        assert_eq!(
            fixture["examples"]["selected"]["response"]["data"]["candidates"][0]["fallback_allowed"],
            json!(true)
        );
        assert_eq!(
            fixture["examples"]["no_candidate"]["response"]["data"]["selection"]["status"],
            json!("model_not_found_or_not_allowed")
        );
    }

    #[test]
    fn provider_key_create_rejects_caller_encrypted_secret_or_fingerprint() {
        let request: CreateProviderKeyRequest = serde_json::from_value(json!({
            "channel_id": Uuid::from_u128(3),
            "key_alias": "primary",
            "secret": "sk-live-secret",
            "encrypted_secret": null
        }))
        .expect("request should deserialize");
        let error = reject_provider_key_create_generated_fields(&request)
            .expect_err("caller encrypted_secret must be rejected");

        assert_eq!(error.code, "bad_request");

        let request: CreateProviderKeyRequest = serde_json::from_value(json!({
            "channel_id": Uuid::from_u128(3),
            "key_alias": "primary",
            "api_key": "sk-live-secret",
            "secret_fingerprint": "hmac-sha256-v1:caller"
        }))
        .expect("request should deserialize");
        let error = reject_provider_key_create_generated_fields(&request)
            .expect_err("caller secret_fingerprint must be rejected");

        assert_eq!(error.code, "bad_request");
    }

    #[test]
    fn provider_key_master_key_rejects_missing_or_invalid_config() {
        let missing =
            decode_provider_key_master_key(None).expect_err("missing master key should fail");
        assert_eq!(missing.status, StatusCode::INTERNAL_SERVER_ERROR);
        assert_eq!(missing.code, "configuration_error");

        let invalid_base64 = decode_provider_key_master_key(Some("sk-live-secret"))
            .expect_err("invalid base64 should fail");
        assert_eq!(invalid_base64.code, "configuration_error");
        assert!(!invalid_base64.message.contains("sk-live-secret"));

        let short_key =
            decode_provider_key_master_key(Some("AA==")).expect_err("short key should fail");
        assert_eq!(short_key.code, "configuration_error");
        assert_eq!(
            short_key.message,
            "provider key master key must decode to 32 bytes"
        );

        let valid_key =
            decode_provider_key_master_key(Some("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="))
                .expect("32-byte base64 master key should decode");
        assert_eq!(valid_key.len(), PROVIDER_KEY_MASTER_KEY_LEN);
    }

    #[test]
    fn provider_key_create_safe_response_omits_secret_material() {
        let provider_key = build_new_provider_key(
            create_provider_key_request(),
            Uuid::from_u128(4),
            Uuid::from_u128(5),
            &provider_key_master_key_config(),
        )
        .expect("provider key should build");
        let encrypted_secret = provider_key.encrypted_secret.clone();
        let secret_fingerprint = provider_key.secret_fingerprint.clone();
        let response = provider_key_response(ProviderKey {
            id: provider_key.id,
            tenant_id: provider_key.tenant_id,
            channel_id: provider_key.channel_id,
            key_alias: provider_key.key_alias,
            has_secret_fingerprint: true,
            status: provider_key.status,
            health_score: 1.0,
            cooldown_until: None,
            last_error_code: None,
            rpm_limit: None,
            tpm_limit: None,
            concurrency_limit: None,
            current_window_state: json!({}),
            metadata: provider_key.metadata,
            secret_redacted: true,
        });
        let serialized = serde_json::to_string(&response).expect("response should serialize");

        assert_eq!(response.get("secret"), None);
        assert_eq!(response.get("api_key"), None);
        assert_eq!(response.get("encrypted_secret"), None);
        assert_eq!(response.get("secret_fingerprint"), None);
        assert_eq!(response.get("has_secret_fingerprint"), None);
        assert_eq!(response.get("current_window_state"), None);
        assert_eq!(response["credential_configured"], json!(true));
        assert!(!serialized.contains("sk-live-create-secret"));
        assert!(!serialized.contains(&encrypted_secret));
        assert!(!serialized.contains(&secret_fingerprint));
    }

    #[test]
    fn provider_key_create_rejects_secret_metadata() {
        let mut request = create_provider_key_request();
        request.metadata = Some(json!({
            "owner": "ops",
            "nested": { "token": "sk-live-secret-never-persist" }
        }));
        let error = build_new_provider_key(
            request,
            Uuid::from_u128(4),
            Uuid::from_u128(5),
            &provider_key_master_key_config(),
        )
        .expect_err("secret metadata must be rejected");

        assert_eq!(error.code, "bad_request");
    }

    #[test]
    fn provider_key_metadata_rejects_secret_fields() {
        let error = validate_provider_key_metadata(json!({
            "owner": "ops",
            "api_key": "sk-live-secret-never-persist"
        }))
        .expect_err("provider key metadata must not accept secrets");

        assert_eq!(error.code, "bad_request");
    }

    #[test]
    fn provider_key_patch_rejects_secret_update_fields() {
        let request = PatchProviderKeyRequest {
            status: None,
            metadata: None,
            secret: Some(json!("sk-live-secret")),
            api_key: None,
            encrypted_secret: None,
            secret_fingerprint: None,
        };
        let error =
            reject_provider_key_secret_fields(&request).expect_err("secret update must fail");

        assert_eq!(error.code, "bad_request");
    }

    #[test]
    fn provider_key_status_normalizes_disabled_alias() {
        assert_eq!(
            normalize_provider_key_status(Some("disabled")).expect("status should normalize"),
            "manual_disabled"
        );
        assert_eq!(
            normalize_provider_key_status(Some(" Active ")).expect("status should normalize"),
            "enabled"
        );
        assert_eq!(
            normalize_provider_key_status(None).expect("default status should normalize"),
            "enabled"
        );
    }

    #[test]
    fn provider_key_patch_status_allows_only_manual_targets() {
        for (raw, expected) in [
            ("enabled", "enabled"),
            ("active", "enabled"),
            ("disabled", "manual_disabled"),
            ("manual_disabled", "manual_disabled"),
            ("degraded", "degraded"),
            ("recovery_probe", "recovery_probe"),
        ] {
            assert_eq!(
                normalize_provider_key_manual_patch_status(Some(raw), "auth_failed")
                    .expect("manual status should be accepted"),
                expected
            );
        }

        assert_eq!(
            normalize_provider_key_manual_patch_status(None, "auth_failed")
                .expect("missing status should preserve current"),
            "auth_failed"
        );

        for forbidden in ["auth_failed", "quota_exhausted", "cooldown", "deleted"] {
            let error = normalize_provider_key_manual_patch_status(Some(forbidden), "enabled")
                .expect_err("runtime-managed status should be rejected");
            assert_eq!(error.code, "bad_request");
            assert!(
                !error.message.contains("sk-"),
                "status validation error must not contain secret-like material"
            );
        }
    }

    #[test]
    fn provider_key_recovery_target_and_transition_boundaries() {
        for (raw, expected) in [
            (None, "recovery_probe"),
            (Some("recovery_probe"), "recovery_probe"),
            (Some("enabled"), "enabled"),
            (Some("active"), "enabled"),
        ] {
            assert_eq!(
                normalize_provider_key_recovery_target(raw)
                    .expect("safe recovery target should be accepted"),
                expected
            );
        }

        for forbidden in [
            "manual_disabled",
            "degraded",
            "cooldown",
            "auth_failed",
            "quota_exhausted",
            "deleted",
        ] {
            let error = normalize_provider_key_recovery_target(Some(forbidden))
                .expect_err("unsafe recovery target should be rejected");
            assert_eq!(error.code, "bad_request");
            assert!(
                !error.message.contains("sk-"),
                "target error must not contain secret-like material"
            );
        }

        let secret_like_unknown =
            normalize_provider_key_recovery_target(Some("sk-live-recovery-target-never-echo"))
                .expect_err("unsupported recovery target should be rejected");
        assert_eq!(secret_like_unknown.code, "bad_request");
        assert_eq!(
            secret_like_unknown.message,
            "unsupported provider key recovery target"
        );
        assert!(!secret_like_unknown.message.contains("sk-live"));

        for current in ["cooldown", "degraded", "recovery_probe"] {
            validate_provider_key_recovery_transition(current, "recovery_probe")
                .expect("safe source should enter recovery_probe");
            validate_provider_key_recovery_transition(current, "enabled")
                .expect("safe source should enter enabled");
        }

        for current in [
            "auth_failed",
            "quota_exhausted",
            "manual_disabled",
            "enabled",
            "deleted",
        ] {
            let error = validate_provider_key_recovery_transition(current, "recovery_probe")
                .expect_err("unsafe source should be rejected");
            assert_eq!(error.code, "bad_request");
            assert!(
                !error.message.contains("sk-"),
                "source error must not contain secret-like material"
            );
        }
    }

    #[test]
    fn provider_key_recovery_request_rejects_unknown_secret_fields() {
        let default_request = serde_json::from_value::<ProviderKeyRecoveryRequest>(json!({}))
            .expect("empty recovery body should be valid");
        assert_eq!(
            normalize_provider_key_recovery_target(default_request.target_status.as_deref())
                .expect("empty target should default"),
            "recovery_probe"
        );

        let error = serde_json::from_value::<ProviderKeyRecoveryRequest>(json!({
            "target_status": "recovery_probe",
            "secret": "sk-live-recovery-secret-never-read"
        }))
        .expect_err("unknown secret fields must be rejected by deserialization");
        let message = error.to_string();

        assert!(message.contains("secret"));
        assert!(!message.contains("sk-live-recovery-secret-never-read"));
    }

    #[test]
    fn provider_key_recovery_response_is_secret_safe() {
        let mut provider_key = provider_key_fixture(Uuid::from_u128(3));
        provider_key.status = "recovery_probe".to_string();
        provider_key.metadata = json!({
            "owner": "ops",
            "nested": {
                "api_key": "sk-live-recovery-metadata-never-return"
            }
        });

        let response = provider_key_recovery_response(
            &provider_key,
            "cooldown",
            "recovery_probe",
            Some("rotate after [REDACTED]"),
        );
        let serialized = serde_json::to_string(&response).expect("response should serialize");

        assert_eq!(response["dry_run"], json!(false));
        assert_eq!(response["controlled_status_transition"], json!(true));
        assert_eq!(response["transition"]["from_status"], json!("cooldown"));
        assert_eq!(response["transition"]["to_status"], json!("recovery_probe"));
        assert_eq!(response["upstream_probe"]["executed"], json!(false));
        assert_eq!(response["credential_material"]["omitted"], json!(true));
        assert_eq!(
            response["provider_key"]["metadata"]["nested"]["api_key"],
            json!("[REDACTED]")
        );

        for forbidden in [
            "sk-live-recovery-metadata-never-return",
            "encrypted_secret",
            "secret_fingerprint",
            "has_secret_fingerprint",
            "current_window_state",
        ] {
            assert!(
                !serialized.contains(forbidden),
                "recovery response must not contain {forbidden}"
            );
        }
    }

    #[test]
    fn provider_key_status_contract_fixture_locks_manual_boundaries() {
        let fixture = serde_json::from_str::<Value>(include_str!(
            "../../../tests/fixtures/control-plane/provider_key_status_contract.json"
        ))
        .expect("fixture should be valid json");

        assert_eq!(fixture["todo"], json!("E3-004"));
        assert_eq!(
            fixture["patch_contract"]["path"],
            json!("PATCH /admin/provider-keys/{id}")
        );
        assert_eq!(
            fixture["read_contract"]["path"],
            json!("GET /admin/provider-keys/{id}")
        );

        let allowed = fixture["patch_contract"]["allowed_target_statuses"]
            .as_array()
            .expect("allowed statuses should be an array");
        for expected in ["enabled", "manual_disabled", "degraded", "recovery_probe"] {
            assert!(
                allowed.iter().any(|value| value.as_str() == Some(expected)),
                "fixture should allow manual target {expected}"
            );
        }

        let forbidden = fixture["patch_contract"]["forbidden_direct_target_statuses"]
            .as_array()
            .expect("forbidden statuses should be an array");
        for expected in ["auth_failed", "quota_exhausted", "cooldown", "deleted"] {
            assert!(
                forbidden
                    .iter()
                    .any(|value| value.as_str() == Some(expected)),
                "fixture should reject direct target {expected}"
            );
        }

        let response = &fixture["examples"]["manual_disable"]["response"]["data"];
        assert_eq!(response["credential_configured"], json!(true));
        assert_eq!(
            fixture["recovery_contract"]["path"],
            json!("POST /admin/provider-keys/{id}/recovery")
        );
        assert_eq!(
            fixture["recovery_contract"]["allowed_source_statuses"],
            json!(["cooldown", "degraded", "recovery_probe"])
        );
        assert_eq!(
            fixture["recovery_contract"]["allowed_target_statuses"],
            json!(["recovery_probe", "enabled"])
        );
        assert_eq!(
            fixture["examples"]["manual_recovery"]["response"]["data"]["upstream_probe"]["executed"],
            json!(false)
        );
        for forbidden in [
            "secret",
            "api_key",
            "encrypted_secret",
            "secret_fingerprint",
            "has_secret_fingerprint",
            "current_window_state",
        ] {
            assert!(
                response.get(forbidden).is_none(),
                "example response must omit {forbidden}"
            );
        }
    }

    #[test]
    fn provider_key_response_redacts_sensitive_metadata_values() {
        let response = provider_key_response(ProviderKey {
            id: Uuid::from_u128(1),
            tenant_id: Uuid::from_u128(2),
            channel_id: Uuid::from_u128(3),
            key_alias: "primary".to_string(),
            has_secret_fingerprint: true,
            status: "enabled".to_string(),
            health_score: 1.0,
            cooldown_until: None,
            last_error_code: None,
            rpm_limit: None,
            tpm_limit: None,
            concurrency_limit: None,
            current_window_state: json!({}),
            metadata: json!({
                "owner": "ops",
                "nested": { "token": "sk-live-secret-never-return" }
            }),
            secret_redacted: true,
        });
        let serialized = serde_json::to_string(&response).expect("response should serialize");

        assert!(!serialized.contains("sk-live-secret-never-return"));
        assert_eq!(response["metadata"]["nested"]["token"], json!("[REDACTED]"));
        assert_eq!(response["credential_configured"], json!(true));
        assert_eq!(response.get("has_secret_fingerprint"), None);
        assert_eq!(response.get("current_window_state"), None);
    }

    #[test]
    fn audit_metadata_sanitizer_redacts_secret_key_payload_and_auth_values() {
        let raw_virtual_key = format!("vk_{}", "a".repeat(64));
        let sanitized = sanitize_audit_value(json!({
            "owner": "ops",
            "secret": "sk-live-never-audit",
            "payload": { "prompt": "raw user payload never audit" },
            "headers": {
                "user-agent": "RawBrowser/1.0 never audit",
                "cookie": "sid=never-audit"
            },
            "user_agent": "RawBrowser/2.0 never audit",
            "client_ip": "203.0.113.42",
            "nested": {
                "authorization": "Bearer never-audit",
                "raw_key": raw_virtual_key,
                "public_note": "safe"
            },
            "items": [
                { "body": "raw body never audit" },
                { "label": "safe" }
            ]
        }));
        let serialized = serde_json::to_string(&sanitized).expect("metadata should serialize");

        assert!(!serialized.contains("sk-live-never-audit"));
        assert!(!serialized.contains("raw user payload never audit"));
        assert!(!serialized.contains("RawBrowser/1.0 never audit"));
        assert!(!serialized.contains("RawBrowser/2.0 never audit"));
        assert!(!serialized.contains("sid=never-audit"));
        assert!(!serialized.contains("203.0.113.42"));
        assert!(!serialized.contains("Bearer never-audit"));
        assert!(!serialized.contains("raw body never audit"));
        assert_eq!(sanitized["secret"], json!("[REDACTED]"));
        assert_eq!(sanitized["payload"], json!("[REDACTED]"));
        assert_eq!(sanitized["headers"], json!("[REDACTED]"));
        assert_eq!(sanitized["user_agent"], json!("[REDACTED]"));
        assert_eq!(sanitized["client_ip"], json!("[REDACTED]"));
        assert_eq!(sanitized["nested"]["authorization"], json!("[REDACTED]"));
        assert_eq!(sanitized["nested"]["raw_key"], json!("[REDACTED]"));
        assert_eq!(sanitized["nested"]["public_note"], json!("safe"));
        assert_eq!(sanitized["items"][0]["body"], json!("[REDACTED]"));
    }

    #[test]
    fn audit_request_context_hashes_user_agent_and_client_ip_without_raw_values() {
        let mut headers = HeaderMap::new();
        headers.insert(
            USER_AGENT,
            axum::http::HeaderValue::from_static("AdminBrowser/9.1"),
        );
        headers.insert(
            "x-forwarded-for",
            axum::http::HeaderValue::from_static("203.0.113.42, 10.0.0.8"),
        );
        headers.insert(
            "authorization",
            axum::http::HeaderValue::from_static("Bearer never-audit"),
        );
        headers.insert(
            "cookie",
            axum::http::HeaderValue::from_static("session=never-audit"),
        );

        let context = admin_request_context_from_headers(&headers);
        let metadata = admin_audit_metadata_from_parts(
            Uuid::from_u128(701),
            DEFAULT_TENANT_ID,
            json!({}),
            Some(context),
        );
        let serialized = serde_json::to_string(&metadata).expect("metadata should serialize");
        let request_context = &metadata["request_context"];

        assert_eq!(
            request_context["user_agent_sha256"],
            json!(audit_fingerprint("user_agent", "AdminBrowser/9.1"))
        );
        assert_eq!(
            request_context["client_ip_sha256"],
            json!(audit_fingerprint("client_ip", "203.0.113.42"))
        );
        assert_eq!(request_context["user_agent_length"], json!(16));
        assert_eq!(
            request_context["client_ip_source"],
            json!("x-forwarded-for")
        );
        assert_eq!(request_context["client_ip_kind"], json!("ipv4"));
        assert_eq!(request_context["client_ip_scope"], json!("routable"));
        assert!(!serialized.contains("AdminBrowser/9.1"));
        assert!(!serialized.contains("203.0.113.42"));
        assert!(!serialized.contains("10.0.0.8"));
        assert!(!serialized.contains("Bearer never-audit"));
        assert!(!serialized.contains("session=never-audit"));
    }

    #[test]
    fn forwarded_header_client_ip_parser_accepts_bracketed_ipv6_without_port() {
        let mut headers = HeaderMap::new();
        headers.insert(
            "forwarded",
            axum::http::HeaderValue::from_static("for=\"[2001:db8:cafe::17]:4711\";proto=https"),
        );

        let context = admin_request_context_from_headers(&headers);

        assert_eq!(context["client_ip_source"], json!("forwarded"));
        assert_eq!(context["client_ip_kind"], json!("ipv6"));
        assert_eq!(
            context["client_ip_sha256"],
            json!(audit_fingerprint("client_ip", "2001:db8:cafe::17"))
        );
    }

    #[test]
    fn provider_key_success_audit_shape_is_stable_and_secret_safe() {
        let before = provider_key_fixture(Uuid::from_u128(3));
        let mut after = before.clone();
        after.status = "manual_disabled".to_string();
        after.metadata = json!({
            "owner": "ops",
            "token": "sk-live-never-audit"
        });
        let request_context = json!({
            "user_agent_sha256": audit_fingerprint("user_agent", "AdminBrowser/9.1"),
            "client_ip_sha256": audit_fingerprint("client_ip", "203.0.113.42"),
            "client_ip_source": "x-forwarded-for"
        });

        let audit = new_admin_audit_log_from_parts(
            Uuid::from_u128(701),
            DEFAULT_TENANT_ID,
            "provider_key.update",
            Some(&before),
            &after,
            json!({
                "request_body": "raw body never audit",
                "authorization": "Bearer never-audit"
            }),
            Some(request_context),
        );
        let serialized = serde_json::to_string(&audit).expect("audit should serialize");

        assert_eq!(audit.action, "provider_key.update");
        assert_eq!(audit.resource_type, "provider_key");
        assert_eq!(audit.resource_id, Some(after.id));
        assert_eq!(audit.resource_tenant_id, Some(DEFAULT_TENANT_ID));
        assert_eq!(
            audit.before_snapshot.as_ref().unwrap()["status"],
            json!("auth_failed")
        );
        assert_eq!(
            audit.after_snapshot.as_ref().unwrap()["status"],
            json!("manual_disabled")
        );
        assert_eq!(
            audit.after_snapshot.as_ref().unwrap()["metadata"]["token"],
            json!("[REDACTED]")
        );
        assert_eq!(audit.metadata["request_body"], json!("[REDACTED]"));
        assert_eq!(audit.metadata["authorization"], json!("[REDACTED]"));
        assert_eq!(
            audit.metadata["request_context"]["client_ip_source"],
            json!("x-forwarded-for")
        );
        assert!(!serialized.contains("sk-live-never-audit"));
        assert!(!serialized.contains("raw body never audit"));
        assert!(!serialized.contains("Bearer never-audit"));
        assert!(!serialized.contains("encrypted_secret"));
        assert!(!serialized.contains("\"secret_fingerprint\""));
        assert!(!serialized.contains("\"has_secret_fingerprint\""));
        assert!(!serialized.contains("current_window_state"));
        assert!(!serialized.contains("fingerprint-never-return"));
    }

    #[test]
    fn provider_key_missing_business_result_does_not_build_success_audit() {
        fn build_success_audit_for_optional_provider_key(
            provider_key: Option<&ProviderKey>,
        ) -> Option<NewAuditLog> {
            provider_key.map(|after| {
                new_admin_audit_log_from_parts(
                    Uuid::from_u128(701),
                    DEFAULT_TENANT_ID,
                    "provider_key.update",
                    None,
                    after,
                    json!({}),
                    None,
                )
            })
        }

        let missing = build_success_audit_for_optional_provider_key(None);
        let present_provider_key = provider_key_fixture(Uuid::from_u128(3));
        let present = build_success_audit_for_optional_provider_key(Some(&present_provider_key));

        assert!(missing.is_none());
        assert_eq!(
            present.expect("audit should build").action,
            "provider_key.update"
        );
    }

    #[test]
    fn audit_log_contract_fixture_captures_transaction_and_safe_metadata() {
        let fixture = serde_json::from_str::<Value>(include_str!(
            "../../../tests/fixtures/control-plane/audit_log_contract.json"
        ))
        .expect("fixture should be valid json");
        let serialized = serde_json::to_string(&fixture).expect("fixture should serialize");

        assert_eq!(fixture["todo"], json!("E1-004"));
        assert_eq!(
            fixture["transaction_contract"]["business_and_audit_share_transaction"],
            json!(true)
        );
        assert_eq!(
            fixture["metadata_contract"]["raw_headers_omitted"],
            json!(true)
        );
        let fields = fixture["metadata_contract"]["request_context_fields"]
            .as_array()
            .expect("request context fields should be an array");
        for expected in ["user_agent_sha256", "client_ip_sha256", "client_ip_scope"] {
            assert!(
                fields.iter().any(|field| field.as_str() == Some(expected)),
                "fixture should require {expected}"
            );
        }
        let paths = fixture["transaction_contract"]["paths"]
            .as_array()
            .expect("transaction paths should be an array");
        assert!(
            paths
                .iter()
                .any(|path| path.as_str() == Some("POST /admin/price-versions")),
            "audit fixture should include price version create"
        );
        assert_eq!(
            fixture["query_contract"]["path"],
            json!("GET /admin/audit-logs")
        );
        assert_eq!(
            fixture["query_contract"]["required_permission"],
            json!("audit_read")
        );
        assert_eq!(fixture["query_contract"]["max_limit"], json!(500));
        let filters = fixture["query_contract"]["filters"]
            .as_array()
            .expect("query filters should be an array");
        for expected in ["tenant_id", "actor_user_id", "action", "created_from"] {
            assert!(
                filters.iter().any(|field| field.as_str() == Some(expected)),
                "fixture should include audit query filter {expected}"
            );
        }
        let request_context = &fixture["examples"]["provider_key_update_success_audit"]["metadata"]
            ["request_context"];
        assert_eq!(
            request_context["user_agent_sha256"]
                .as_str()
                .expect("user agent digest should be string")
                .len(),
            64
        );
        assert_eq!(
            request_context["client_ip_sha256"]
                .as_str()
                .expect("client ip digest should be string")
                .len(),
            64
        );

        for forbidden in [
            "AdminBrowser/9.1",
            "203.0.113.42",
            "10.0.0.8",
            "Bearer",
            "Cookie",
            "Authorization",
            "sk-",
            "encrypted_secret",
            "raw body never audit",
        ] {
            assert!(
                !serialized.contains(forbidden),
                "audit fixture must not contain {forbidden}"
            );
        }
    }

    #[test]
    fn virtual_key_audit_summary_omits_secret_hash_and_raw_secret() {
        let summary = virtual_key_fixture().audit_summary();
        let serialized = serde_json::to_string(&summary).expect("summary should serialize");

        assert_eq!(summary["key_prefix"], json!("vk_test_pref"));
        assert_eq!(summary["secret_redacted"], json!(true));
        assert!(!serialized.contains("secret-hash-never-return"));
        assert!(!serialized.contains("vk_test_secret_once"));
        assert!(summary.get("secret_hash").is_none());
        assert!(summary.get("secret").is_none());
    }

    #[test]
    fn virtual_key_create_response_returns_secret_once_only() {
        let response = virtual_key_response(
            virtual_key_fixture(),
            Some("vk_test_secret_once".to_string()),
        );
        let serialized = serde_json::to_string(&response).expect("response should serialize");

        assert_eq!(response["secret"], json!("vk_test_secret_once"));
        assert_eq!(response["secret_once"], json!(true));
        assert_eq!(response["secret_redacted"], json!(false));
        assert!(!serialized.contains("secret-hash-never-return"));
    }

    #[test]
    fn virtual_key_redacted_response_omits_secret_and_secret_hash() {
        let response = virtual_key_response(virtual_key_fixture(), None);
        let serialized = serde_json::to_string(&response).expect("response should serialize");

        assert_eq!(response.get("secret"), None);
        assert_eq!(response.get("secret_hash"), None);
        assert_eq!(response["secret_redacted"], json!(true));
        assert_eq!(response["status"], json!("active"));
        assert!(!serialized.contains("secret-hash-never-return"));
    }

    #[test]
    fn virtual_key_db_model_debug_and_serialize_redact_secret_hash() {
        let virtual_key = virtual_key_fixture();
        let debug = format!("{virtual_key:?}");
        let serialized = serde_json::to_string(&virtual_key).expect("model should serialize");

        assert!(!debug.contains("secret-hash-never-return"));
        assert!(!serialized.contains("secret-hash-never-return"));
        assert_eq!(
            serde_json::from_str::<Value>(&serialized)
                .unwrap()
                .get("secret_hash"),
            None
        );
    }

    #[test]
    fn virtual_key_create_rejects_caller_secret_material() {
        let request: CreateVirtualKeyRequest = serde_json::from_value(json!({
            "project_id": Uuid::from_u128(11),
            "name": "default client key",
            "default_profile_id": Uuid::from_u128(12),
            "secret": "vk_caller_secret"
        }))
        .expect("request should deserialize");
        let error = reject_virtual_key_create_generated_fields(&request)
            .expect_err("caller supplied secret must be rejected");

        assert_eq!(error.code, "bad_request");

        let request: CreateVirtualKeyRequest = serde_json::from_value(json!({
            "project_id": Uuid::from_u128(11),
            "name": "default client key",
            "default_profile_id": Uuid::from_u128(12),
            "secret_hash": null,
            "key_prefix": "vk_caller"
        }))
        .expect("request should deserialize");
        let error = reject_virtual_key_create_generated_fields(&request)
            .expect_err("caller supplied generated fields must be rejected");

        assert_eq!(error.code, "bad_request");
    }

    #[test]
    fn api_key_profile_delete_rejects_active_virtual_key_bindings() {
        let error = ensure_profile_can_be_deleted(true)
            .expect_err("active virtual key binding should block profile deletion");

        assert_eq!(error.code, "bad_request");
        assert!(ensure_profile_can_be_deleted(false).is_ok());
    }

    #[test]
    fn virtual_key_query_normalizes_status_aliases() {
        let project_id = Uuid::from_u128(11);
        let filter = ListVirtualKeysQuery {
            project_id: Some(project_id),
            status: Some(" enabled ".to_string()),
        }
        .into_filter()
        .expect("enabled status should normalize");

        assert_eq!(filter.project_id, project_id);
        assert_eq!(filter.status.as_deref(), Some("active"));

        let filter = ListVirtualKeysQuery {
            project_id: Some(project_id),
            status: Some("manual_disabled".to_string()),
        }
        .into_filter()
        .expect("manual disabled status should normalize");

        assert_eq!(filter.status.as_deref(), Some("disabled"));
    }

    #[test]
    fn request_log_query_caps_limit_and_normalizes_filters() {
        let channel_id = Uuid::from_u128(42);
        let filter = ListRequestLogsQuery {
            limit: Some(10_000),
            status: Some(" succeeded ".to_string()),
            model: Some("  ".to_string()),
            canonical_model_id: None,
            channel_id: None,
            resolved_channel_id: Some(channel_id),
        }
        .into_filter()
        .expect("query should normalize");

        assert_eq!(filter.limit, REQUEST_LOG_MAX_LIMIT);
        assert_eq!(filter.status.as_deref(), Some("succeeded"));
        assert_eq!(filter.model, None);
        assert_eq!(filter.channel_id, Some(channel_id));
    }

    #[test]
    fn trace_request_query_caps_limit_and_rejects_empty_trace() {
        let filter = TraceRequestSummaryQuery {
            limit: Some(10_000),
        }
        .into_filter(" trace-contract-1 ".to_string())
        .expect("trace query should normalize");

        assert_eq!(filter.trace_id, "trace-contract-1");
        assert_eq!(filter.limit, REQUEST_LOG_MAX_LIMIT);

        let error = TraceRequestSummaryQuery { limit: Some(10) }
            .into_filter("   ".to_string())
            .expect_err("empty trace id should be rejected");
        assert_eq!(error.code, "bad_request");
    }

    #[test]
    fn audit_log_query_caps_limit_and_normalizes_filters() {
        let actor_user_id = Uuid::from_u128(71);
        let actor_session_id = Uuid::from_u128(72);
        let resource_id = Uuid::from_u128(501);
        let filter = ListAuditLogsQuery {
            limit: Some(10_000),
            tenant_id: Some(DEFAULT_TENANT_ID),
            actor_user_id: Some(actor_user_id),
            actor_session_id: Some(actor_session_id),
            action: Some(" provider_key.update ".to_string()),
            resource_type: Some(" provider_key ".to_string()),
            resource_id: Some(resource_id),
            resource_tenant_id: Some(DEFAULT_TENANT_ID),
            created_from: Some(" 2026-06-03T00:00:00Z ".to_string()),
            created_to: Some("2026-06-03T23:59:59+00:00".to_string()),
        }
        .into_filter()
        .expect("audit query should normalize");

        assert_eq!(filter.limit, AUDIT_LOG_MAX_LIMIT);
        assert_eq!(filter.tenant_id, DEFAULT_TENANT_ID);
        assert_eq!(filter.actor_user_id, Some(actor_user_id));
        assert_eq!(filter.actor_session_id, Some(actor_session_id));
        assert_eq!(filter.action.as_deref(), Some("provider_key.update"));
        assert_eq!(filter.resource_type.as_deref(), Some("provider_key"));
        assert_eq!(filter.resource_id, Some(resource_id));
        assert_eq!(filter.resource_tenant_id, Some(DEFAULT_TENANT_ID));
        assert_eq!(filter.created_from.as_deref(), Some("2026-06-03T00:00:00Z"));
        assert_eq!(
            filter.created_to.as_deref(),
            Some("2026-06-03T23:59:59+00:00")
        );
    }

    #[test]
    fn audit_log_query_rejects_unsupported_tenant_time_and_limit() {
        let error = ListAuditLogsQuery {
            limit: Some(50),
            tenant_id: Some(Uuid::from_u128(2)),
            actor_user_id: None,
            actor_session_id: None,
            action: None,
            resource_type: None,
            resource_id: None,
            resource_tenant_id: None,
            created_from: None,
            created_to: None,
        }
        .into_filter()
        .expect_err("foreign tenant should be rejected");
        assert_eq!(error.code, "bad_request");

        let error = ListAuditLogsQuery {
            limit: Some(50),
            tenant_id: None,
            actor_user_id: None,
            actor_session_id: None,
            action: None,
            resource_type: None,
            resource_id: None,
            resource_tenant_id: None,
            created_from: Some("2026-06-03".to_string()),
            created_to: None,
        }
        .into_filter()
        .expect_err("non timestamp should be rejected");
        assert_eq!(error.code, "bad_request");

        let error = ListAuditLogsQuery {
            limit: Some(0),
            tenant_id: None,
            actor_user_id: None,
            actor_session_id: None,
            action: None,
            resource_type: None,
            resource_id: None,
            resource_tenant_id: None,
            created_from: None,
            created_to: None,
        }
        .into_filter()
        .expect_err("zero limit should be rejected");
        assert_eq!(error.code, "bad_request");
    }

    #[test]
    fn audit_log_response_is_secret_safe() {
        let audit_log = AuditLog {
            id: Uuid::from_u128(801),
            tenant_id: DEFAULT_TENANT_ID,
            actor_user_id: Some(Uuid::from_u128(70)),
            request_id: Some(Uuid::from_u128(90)),
            action: "provider_key.update".to_string(),
            resource_type: "provider_key".to_string(),
            resource_id: Some(Uuid::from_u128(501)),
            resource_tenant_id: Some(DEFAULT_TENANT_ID),
            before_snapshot: Some(json!({
                "status": "enabled",
                "headers": {
                    "authorization": "Bearer never-audit",
                    "cookie": "sid=never-audit"
                },
                "metadata": {
                    "owner": "ops"
                }
            })),
            after_snapshot: Some(json!({
                "status": "manual_disabled",
                "metadata": {
                    "api_key": "sk-live-never-audit",
                    "note": "rotated by ops"
                },
                "secret_fingerprint": "fp-never-audit"
            })),
            metadata: json!({
                "actor_session_id": Uuid::from_u128(71),
                "request_body": "raw body never audit",
                "raw_headers": {
                    "cookie": "sid=never-audit"
                },
                "provider_key_material": "sk-live-never-audit",
                "request_context": {
                    "user_agent_sha256": audit_fingerprint("user_agent", "AdminBrowser/9.1"),
                    "client_ip_sha256": audit_fingerprint("client_ip", "203.0.113.42")
                }
            }),
            created_at: "2026-06-03 12:34:56+00".to_string(),
        };

        let response = audit_log_response(audit_log);
        let serialized = serde_json::to_string(&response).expect("response should serialize");

        assert_eq!(response["action"], json!("provider_key.update"));
        assert_eq!(response["resource_type"], json!("provider_key"));
        assert_eq!(response["before_snapshot"]["status"], json!("enabled"));
        assert_eq!(response["before_snapshot"]["headers"], json!("[REDACTED]"));
        assert_eq!(
            response["after_snapshot"]["metadata"]["api_key"],
            json!("[REDACTED]")
        );
        assert_eq!(response["metadata"]["request_body"], json!("[REDACTED]"));
        assert_eq!(response["metadata"]["raw_headers"], json!("[REDACTED]"));
        assert_eq!(
            response["metadata"]["provider_key_material"],
            json!("[REDACTED]")
        );
        for forbidden in [
            "Bearer never-audit",
            "sid=never-audit",
            "sk-live-never-audit",
            "fp-never-audit",
            "raw body never audit",
        ] {
            assert!(
                !serialized.contains(forbidden),
                "audit log response must not contain {forbidden}"
            );
        }
    }

    #[test]
    fn billing_read_queries_cap_limit_and_normalize_filters() {
        let price_book_id = Uuid::from_u128(60);
        let canonical_model_id = Uuid::from_u128(70);
        let price_filter = ListPriceVersionsQuery {
            limit: Some(10_000),
            price_book_id: Some(price_book_id),
            canonical_model_id: Some(canonical_model_id),
            status: Some(" Retired ".to_string()),
        }
        .into_filter()
        .expect("price version query should normalize");

        assert_eq!(price_filter.limit, BILLING_READ_MAX_LIMIT);
        assert_eq!(price_filter.price_book_id, Some(price_book_id));
        assert_eq!(price_filter.canonical_model_id, Some(canonical_model_id));
        assert_eq!(price_filter.status.as_deref(), Some("retired"));

        let ledger_filter = ListLedgerEntriesQuery {
            limit: Some(25),
            project_id: Some(Uuid::from_u128(20)),
            request_id: Some(Uuid::from_u128(11)),
            wallet_id: Some(Uuid::from_u128(40)),
        }
        .into_filter()
        .expect("ledger query should normalize");

        assert_eq!(ledger_filter.limit, 25);
        assert_eq!(ledger_filter.project_id, Some(Uuid::from_u128(20)));
        assert_eq!(ledger_filter.request_id, Some(Uuid::from_u128(11)));
        assert_eq!(ledger_filter.wallet_id, Some(Uuid::from_u128(40)));

        let error = ListPriceVersionsQuery {
            limit: Some(50),
            price_book_id: None,
            canonical_model_id: None,
            status: Some("published".to_string()),
        }
        .into_filter()
        .expect_err("unsupported price version status should be rejected");
        assert_eq!(error.code, "bad_request");

        let error = ListLedgerEntriesQuery {
            limit: Some(0),
            project_id: None,
            request_id: None,
            wallet_id: None,
        }
        .into_filter()
        .expect_err("zero limit should be rejected");
        assert_eq!(error.code, "bad_request");
    }

    #[test]
    fn request_log_limit_rejects_zero() {
        let error = request_log_limit(Some(0)).expect_err("zero limit should be rejected");

        assert_eq!(error.code, "bad_request");
    }

    #[test]
    fn health_summary_query_defaults_caps_sample_limit_and_rejects_invalid_window() {
        let filter = ProviderHealthSummaryQuery {
            window_minutes: None,
            sample_limit: None,
        }
        .into_filter()
        .expect("default health summary query should be valid");
        assert_eq!(
            filter,
            ProviderHealthSummaryFilter {
                window_minutes: HEALTH_SUMMARY_DEFAULT_WINDOW_MINUTES,
                sample_limit: HEALTH_SUMMARY_RECENT_SAMPLE_LIMIT,
            }
        );

        let filter = ProviderHealthSummaryQuery {
            window_minutes: Some(15),
            sample_limit: Some(10_000),
        }
        .into_filter()
        .expect("large sample limit should be capped");
        assert_eq!(filter.window_minutes, 15);
        assert_eq!(filter.sample_limit, HEALTH_SUMMARY_RECENT_SAMPLE_LIMIT);

        for query in [
            ProviderHealthSummaryQuery {
                window_minutes: Some(0),
                sample_limit: Some(10),
            },
            ProviderHealthSummaryQuery {
                window_minutes: Some(HEALTH_SUMMARY_MAX_WINDOW_MINUTES + 1),
                sample_limit: Some(10),
            },
            ProviderHealthSummaryQuery {
                window_minutes: Some(15),
                sample_limit: Some(0),
            },
        ] {
            let error = query
                .into_filter()
                .expect_err("invalid health summary query should be rejected");
            assert_eq!(error.code, "bad_request");
        }
    }

    #[test]
    fn billing_reconciliation_query_normalizes_day_and_caps_limit() {
        let filter = BillingReconciliationQuery {
            day: Some(" 2026-06-02 ".to_string()),
            limit: Some(10_000),
        }
        .into_filter()
        .expect("query should normalize");

        assert_eq!(filter.day.as_deref(), Some("2026-06-02"));
        assert_eq!(
            filter.discrepancy_limit,
            RECONCILIATION_MAX_DISCREPANCY_LIMIT
        );
    }

    #[test]
    fn billing_reconciliation_query_rejects_invalid_day_and_limit() {
        let error = BillingReconciliationQuery {
            day: Some("2026-02-29".to_string()),
            limit: Some(50),
        }
        .into_filter()
        .expect_err("invalid calendar day should be rejected");
        assert_eq!(error.code, "bad_request");

        let error = BillingReconciliationQuery {
            day: Some("2024-02-29".to_string()),
            limit: Some(0),
        }
        .into_filter()
        .expect_err("zero limit should be rejected");
        assert_eq!(error.code, "bad_request");
    }

    #[test]
    fn billing_safe_json_preserves_usage_counts_and_redacts_sensitive_fields() {
        let value = billing_safe_json_value(json!({
            "input_tokens": 12,
            "output_tokens": 34,
            "access_token": "Bearer never-return",
            "nested": {
                "request_body": "raw prompt text",
                "note": "provider returned sk-live-secret"
            }
        }));
        let serialized = serde_json::to_string(&value).expect("value should serialize");

        assert_eq!(value["input_tokens"], json!(12));
        assert_eq!(value["output_tokens"], json!(34));
        assert_eq!(value["access_token"], json!("[REDACTED]"));
        assert_eq!(value["nested"]["request_body"], json!("[REDACTED]"));
        assert!(!serialized.contains("Bearer never-return"));
        assert!(!serialized.contains("raw prompt text"));
        assert!(!serialized.contains("sk-live-secret"));
    }

    #[test]
    fn billing_price_version_create_validation_accepts_rating_schema() {
        let pricing_rules = validate_price_version_pricing_rules(json!({
            "currency": "USD",
            "scale": 8,
            "input_token_rate_per_1m": "0.15000000",
            "output_token_rate_per_million": "0.60000000",
            "cache_tokens_per_1m": 3000000,
            "reasoning_tokens_per_1m": null,
            "fixed_request_cost": "0.00010000"
        }))
        .expect("pricing rules should validate");

        assert_eq!(pricing_rules_currency(&pricing_rules).unwrap(), "USD");
        assert_eq!(
            normalize_price_version_status(Some(" Active ")).unwrap(),
            "active"
        );
        assert_eq!(normalize_price_version_status(None).unwrap(), "draft");
        assert_eq!(
            normalize_price_version_effective_at(Some(" 2026-06-03T00:00:00Z ".to_string()))
                .unwrap(),
            Some("2026-06-03T00:00:00Z".to_string())
        );
        assert_eq!(
            normalize_price_version_retired_at(Some(" 2026-09-01T00:00:00Z ".to_string())).unwrap(),
            Some("2026-09-01T00:00:00Z".to_string())
        );
    }

    #[test]
    fn billing_price_version_create_rejects_invalid_or_sensitive_pricing_rules() {
        for pricing_rules in [
            json!({
                "currency": "usd",
                "input_token_rate_per_1m": "0.15000000"
            }),
            json!({
                "currency": "USD",
                "input_token_rate_per_1m": 0.15
            }),
            json!({
                "currency": "USD",
                "input_token_rate_per_1m": "-0.15000000"
            }),
            json!({
                "currency": "USD",
                "payload": { "prompt": "raw user payload" },
                "input_token_rate_per_1m": "0.15000000"
            }),
            json!({
                "currency": "USD",
                "raw_key": "sk-live-never-accept",
                "input_token_rate_per_1m": "0.15000000"
            }),
            json!({
                "currency": "USD"
            }),
        ] {
            let error = validate_price_version_pricing_rules(pricing_rules)
                .expect_err("invalid pricing rules should fail");
            assert_eq!(error.code, "bad_request");
        }
    }

    #[test]
    fn audit_price_version_create_shape_is_transactional_and_secret_safe() {
        let price_version = price_version_fixture();
        let request_context = json!({
            "user_agent_sha256": audit_fingerprint("user_agent", "AdminBrowser/9.1"),
            "client_ip_sha256": audit_fingerprint("client_ip", "203.0.113.42"),
            "client_ip_source": "x-forwarded-for"
        });

        let audit = new_admin_audit_log_from_parts(
            Uuid::from_u128(701),
            DEFAULT_TENANT_ID,
            "price_version.create",
            None,
            &price_version,
            price_version_create_audit_metadata(&price_version.pricing_rules, "USD"),
            Some(request_context),
        );
        let serialized = serde_json::to_string(&audit).expect("audit should serialize");

        assert_eq!(audit.action, "price_version.create");
        assert_eq!(audit.resource_type, "price_version");
        assert_eq!(audit.resource_id, Some(price_version.id));
        assert_eq!(
            audit.after_snapshot.as_ref().unwrap()["pricing_rules"]["currency"],
            json!("USD")
        );
        assert_eq!(audit.metadata["transactional_audit"], json!(true));
        assert_eq!(audit.metadata["pricing_currency"], json!("USD"));
        assert_eq!(
            audit.metadata["request_context"]["client_ip_source"],
            json!("x-forwarded-for")
        );

        for forbidden in [
            "AdminBrowser/9.1",
            "203.0.113.42",
            "payload",
            "raw_key",
            "sk-",
            "api_key",
            "encrypted_secret",
            "secret_fingerprint",
        ] {
            assert!(
                !serialized.contains(forbidden),
                "price version audit must not contain {forbidden}"
            );
        }
    }

    #[test]
    fn canonical_model_default_price_response_and_audit_are_secret_safe() {
        let default_price_book_id =
            Uuid::parse_str("00000000-0000-0000-0000-000000000060").unwrap();
        let response =
            canonical_model_response(canonical_model_fixture(), Some(default_price_book_id));
        let audit_metadata = model_write_audit_metadata(
            false,
            Some(json!({
                "default_price_book_id": default_price_book_id,
                "price_book_currency": "USD",
                "relationship_validated": "tenant_canonical_model_price_book",
                "price_version_selector": "active_effective_version_for_default_price_book",
                "sensitive_material_policy": "uuid_and_currency_only"
            })),
        );
        let serialized = serde_json::to_string(&json!({
            "response": response.clone(),
            "audit_metadata": audit_metadata.clone()
        }))
        .expect("contract should serialize");

        assert_eq!(
            response["default_price_book_id"],
            json!("00000000-0000-0000-0000-000000000060")
        );
        assert_eq!(
            audit_metadata["default_price_config_contract"]["tenant_price_book_relation_required"],
            json!(true)
        );
        assert_eq!(
            audit_metadata["default_price_selector"]["price_version_selector"],
            json!("active_effective_version_for_default_price_book")
        );

        for forbidden in [
            "payload",
            "request_body",
            "response_body",
            "sk-",
            "api_key",
            "encrypted_secret",
            "secret_fingerprint",
            "secret_hash",
            "raw_key",
        ] {
            assert!(
                !serialized.contains(forbidden),
                "canonical model default price audit must not contain {forbidden}"
            );
        }
    }

    #[test]
    fn canonical_model_create_reloads_default_price_selector_after_upsert() {
        let source = include_str!("admin.rs");
        let create_section = source
            .split("async fn create_model")
            .nth(1)
            .and_then(|tail| tail.split("async fn get_model").next())
            .expect("create_model section should be present");
        let upsert_position = create_section
            .find(".upsert_canonical_model(")
            .expect("create_model should upsert canonical model");
        let reload_position = create_section
            .find("get_model_default_price_book_id(&repository, model.id).await?")
            .expect("create_model should reload selector when request omits it");
        let response_position = create_section
            .find("canonical_model_response(model, persisted_default_price_book_id)")
            .expect("create_model response should use persisted selector");

        assert!(
            reload_position > upsert_position,
            "selector reload must happen after upsert so existing upserted models do not report null"
        );
        assert!(
            response_position > reload_position,
            "create response must use the persisted selector value"
        );
    }

    #[test]
    fn canonical_model_default_price_contract_fixture_covers_validation_and_audit() {
        let fixture = serde_json::from_str::<Value>(include_str!(
            "../../../tests/fixtures/control-plane/canonical_model_default_price_contract.json"
        ))
        .expect("fixture should be valid json");
        let serialized = serde_json::to_string(&fixture).expect("fixture should serialize");

        assert_eq!(fixture["todo"], json!("E4-001"));
        assert_eq!(
            fixture["write_contract"]["field"],
            json!("default_price_book_id")
        );
        assert_eq!(
            fixture["validation_contract"]["price_book_must_belong_to_tenant"],
            json!(true)
        );
        assert_eq!(
            fixture["validation_contract"]["canonical_model_must_belong_to_tenant"],
            json!(true)
        );
        assert_eq!(
            fixture["audit_contract"]["metadata_and_snapshot_safe"],
            json!(true)
        );

        for forbidden in [
            "payload",
            "request_body",
            "response_body",
            "sk-",
            "api_key",
            "encrypted_secret",
            "secret_fingerprint",
            "secret_hash",
            "raw_key",
        ] {
            assert!(
                !serialized.contains(forbidden),
                "canonical model default price fixture must not contain {forbidden}"
            );
        }
    }

    #[test]
    fn billing_price_version_write_contract_fixture_covers_create_and_audit() {
        let fixture = serde_json::from_str::<Value>(include_str!(
            "../../../tests/fixtures/control-plane/billing_price_version_write_contract.json"
        ))
        .expect("fixture should be valid json");
        let serialized = serde_json::to_string(&fixture).expect("fixture should serialize");

        assert_eq!(fixture["endpoint"]["method"], json!("POST"));
        assert_eq!(fixture["endpoint"]["path"], json!("/admin/price-versions"));
        assert_eq!(
            fixture["request_contract"]["billing_adjust_permission"],
            json!(true)
        );
        assert_eq!(
            fixture["audit_contract"]["business_and_audit_share_transaction"],
            json!(true)
        );
        assert_eq!(
            fixture["examples"]["create"]["response"]["data"]["pricing_rules"]["currency"],
            json!("USD")
        );
        assert_eq!(
            fixture["examples"]["success_audit"]["resource_type"],
            json!("price_version")
        );

        for forbidden in [
            "payload_object_ref",
            "request_body",
            "response_body",
            "sk-",
            "api_key",
            "encrypted_secret",
            "secret_fingerprint",
            "secret_hash",
            "raw_key",
        ] {
            assert!(
                !serialized.contains(forbidden),
                "billing price version write fixture must not contain {forbidden}"
            );
        }
    }

    #[test]
    fn request_log_summary_exposes_hash_metadata_without_payload_refs_or_snapshot() {
        let request_log = ai_gateway_db::RequestLog {
            id: Uuid::from_u128(1),
            tenant_id: DEFAULT_TENANT_ID,
            project_id: None,
            virtual_key_id: None,
            api_key_profile_id: None,
            trace_id: Some("trace-1".to_string()),
            thread_id: None,
            client_request_id: None,
            inbound_protocol: Some("openai".to_string()),
            outbound_protocol: Some("openai".to_string()),
            protocol_mode: Some("openai_compatible".to_string()),
            requested_model: Some("gpt-test".to_string()),
            canonical_model_id: None,
            upstream_model: Some("upstream-test".to_string()),
            resolved_provider_id: None,
            resolved_channel_id: None,
            provider_key_id: None,
            route_policy_version: Some("v1".to_string()),
            status: "succeeded".to_string(),
            http_status: Some(200),
            error_owner: None,
            error_code: None,
            retryable: None,
            partial_sent: false,
            stream_end_reason: Some("completed".to_string()),
            input_tokens: 1,
            output_tokens: 2,
            final_cost: "0".to_string(),
            currency: "USD".to_string(),
            latency_ms: Some(12),
            ttft_ms: Some(4),
            payload_policy_id: None,
            payload_stored: true,
            redaction_status: "hash_only".to_string(),
            request_body_hash: Some("req-hash".to_string()),
            response_body_hash: Some("resp-hash".to_string()),
            created_at: "2026-06-02 12:00:00+00".to_string(),
            completed_at: Some("2026-06-02 12:00:01+00".to_string()),
            route_decision_snapshot: json!({ "candidate": "internal" }),
        };

        let value = serde_json::to_value(RequestLogSummary::from(&request_log))
            .expect("summary serializes");

        assert_eq!(value["request_body_hash"], json!("req-hash"));
        assert_eq!(value["response_body_hash"], json!("resp-hash"));
        assert_eq!(value["redaction_status"], json!("hash_only"));
        assert!(value.get("payload_object_ref").is_none());
        assert!(value.get("route_decision_snapshot").is_none());
    }

    #[test]
    fn trace_request_summary_redacts_secrets_and_omits_payload_material() {
        let provider_id = Uuid::from_u128(201);
        let channel_id = Uuid::from_u128(401);
        let provider_key_id = Uuid::from_u128(501);
        let model_id = Uuid::from_u128(101);
        let mut succeeded = request_log_summary_fixture(
            1,
            "succeeded",
            None,
            provider_id,
            channel_id,
            provider_key_id,
            model_id,
        );
        succeeded.trace_id = Some("trace Bearer never-return".to_string());
        succeeded.thread_id = Some("thread sk-live-thread-never-return".to_string());
        succeeded.client_request_id = Some("client vk_neverreturn0000000000000000".to_string());

        let mut failed = request_log_summary_fixture(
            2,
            "failed",
            Some("provider_auth_failed sk-live-error-never-return"),
            provider_id,
            channel_id,
            provider_key_id,
            model_id,
        );
        failed.trace_id = succeeded.trace_id.clone();
        failed.thread_id = succeeded.thread_id.clone();
        failed.client_request_id = succeeded.client_request_id.clone();

        let response =
            trace_request_summary_response("trace Bearer never-return", &[failed, succeeded], 2);
        let serialized = serde_json::to_string(&response).expect("response should serialize");

        assert_eq!(response["limit"], json!(2));
        assert_eq!(response["limit_reached"], json!(true));
        assert_eq!(response["request_count"], json!(2));
        assert_eq!(response["error_count"], json!(1));
        assert_eq!(response["total_input_tokens"], json!(2));
        assert_eq!(response["total_output_tokens"], json!(4));
        assert_eq!(
            response["requests"][0]["request_body_hash"],
            json!("req-hash")
        );
        assert_eq!(
            response["requests"][0]["response_body_hash"],
            json!("resp-hash")
        );
        assert!(
            response["requests"][0]
                .get("route_decision_snapshot")
                .is_none()
        );
        assert!(response["requests"][0].get("payload_object_ref").is_none());
        assert!(response["requests"][0].get("request_body").is_none());
        assert!(response["requests"][0].get("response_body").is_none());
        assert!(serialized.contains("[REDACTED]"));
        assert!(!serialized.contains("never-return"));
        assert!(!serialized.contains("sk-live-error-never-return"));
        assert!(!serialized.contains("raw prompt"));
    }
}
