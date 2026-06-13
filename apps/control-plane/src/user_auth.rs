use std::{
    collections::BTreeSet,
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};

use ai_gateway_auth::{
    generate_session_token, generate_virtual_key, hash_admin_password, verify_admin_password,
};
use ai_gateway_db::{DbRepository, NewAuditLog, NewVirtualKey, VirtualKey};
use axum::{
    Json, Router,
    extract::{FromRequestParts, Path, Query, State},
    http::{
        HeaderMap, HeaderValue, StatusCode,
        header::{COOKIE, SET_COOKIE, USER_AGENT},
        request::Parts,
    },
    response::{IntoResponse, Response},
    routing::{get, post},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sqlx::Row;
use uuid::Uuid;

use crate::{
    ControlPlaneState, DEFAULT_TENANT_ID,
    admin::{self, AdminError, UserVoucherRedeemRuntimeRequest},
    auth::{
        AuthError, RemainingBalancePrincipal, RemainingBalancePrincipalSource, clear_session_cookie,
    },
    auth_login_rate_limit::admin_login_failure_rate_limit_key,
    auth_repo::AuthRepository,
};

const DEFAULT_PROJECT_ID: Uuid = Uuid::from_u128(0x00000000_0000_0000_0000_000000000020);
const USER_SESSION_COOKIE: &str = "ai_gateway_user_session";
const DEFAULT_USER_SESSION_TTL_SECONDS: i32 = 12 * 60 * 60;
const MAX_USER_AGENT_LEN: usize = 512;
const CURRENT_TERMS_VERSION: &str = "terms.user_portal.v1";
const CURRENT_PRIVACY_VERSION: &str = "privacy.user_portal.v1";

pub(crate) fn router() -> Router<Arc<ControlPlaneState>> {
    Router::new()
        .route("/auth/register", post(register))
        .route("/auth/login", post(login))
        .route("/auth/password-reset/request", post(request_password_reset))
        .route(
            "/auth/email-verification/request",
            post(request_email_verification),
        )
        .route("/auth/me", get(me))
        .route("/auth/logout", post(logout))
        .route("/user/balance", get(get_user_balance))
        .route(
            "/user/billing-history-readback",
            get(get_user_billing_history_readback),
        )
        .route("/user/home-summary", get(get_user_home_summary))
        .route(
            "/user/developer-quickstart-readback",
            get(get_user_developer_quickstart_readback),
        )
        .route(
            "/user/developer-distribution-packet-readback",
            get(get_user_developer_distribution_packet_readback),
        )
        .route(
            "/user/security-activity-summary",
            get(get_user_security_activity_summary),
        )
        .route("/user/team-summary", get(get_user_team_summary))
        .route("/user/models", get(list_user_models))
        .route("/user/readiness", get(get_user_readiness))
        .route(
            "/user/subscription-payment",
            get(get_user_subscription_payment_overview),
        )
        .route("/user/usage-summary", get(get_user_usage_summary))
        .route("/user/traces/{trace_id}", get(get_user_trace_summary))
        .route("/user/vouchers/redeem", post(redeem_user_voucher))
        .route("/user/request-logs", get(list_user_request_logs))
        .route(
            "/user/virtual-keys",
            get(list_user_virtual_keys).post(create_user_virtual_key),
        )
        .route(
            "/user/virtual-keys/{id}",
            get(get_user_virtual_key).delete(delete_user_virtual_key),
        )
        .route(
            "/user/virtual-keys/{id}/disable",
            post(disable_user_virtual_key),
        )
}

#[derive(Debug, Clone)]
pub(crate) struct UserSession {
    id: Uuid,
    user: UserAccount,
    expires_at: String,
}

impl UserSession {
    fn response(&self) -> UserMeResponse {
        UserMeResponse {
            user: UserResponse::from_account(&self.user),
            session: UserSessionResponse {
                id: self.id,
                expires_at: self.expires_at.clone(),
            },
            project: UserProjectResponse {
                id: self.user.project_id,
                role: self.user.project_role.clone(),
            },
        }
    }
}

impl FromRequestParts<Arc<ControlPlaneState>> for UserSession {
    type Rejection = AuthError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &Arc<ControlPlaneState>,
    ) -> Result<Self, Self::Rejection> {
        authenticate_user_headers(state.as_ref(), &parts.headers).await
    }
}

#[derive(Debug, Clone)]
struct UserAccount {
    id: Uuid,
    tenant_id: Uuid,
    email: String,
    display_name: String,
    password_hash: Option<String>,
    project_id: Uuid,
    project_role: String,
    policy: UserPolicyHandoff,
}

#[derive(Deserialize)]
struct RegisterRequest {
    email: String,
    password: String,
    display_name: Option<String>,
}

#[derive(Deserialize)]
struct LoginRequest {
    email: String,
    password: String,
}

#[derive(Deserialize)]
struct PasswordResetRequest {
    email: String,
}

#[derive(Deserialize)]
struct ListUserVirtualKeysQuery {
    status: Option<String>,
}

#[derive(Deserialize)]
struct UserBalanceQuery {
    currency: Option<String>,
    ledger_window_days: Option<i64>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UserVoucherRedeemRequest {
    voucher_code: String,
    idempotency_key: Option<String>,
    currency: Option<String>,
}

#[derive(Deserialize)]
struct ListUserRequestLogsQuery {
    limit: Option<i64>,
    request_id: Option<String>,
    status: Option<String>,
    model: Option<String>,
    trace_id: Option<String>,
}

#[derive(Deserialize)]
struct UserUsageSummaryQuery {
    window_days: Option<i64>,
}

#[derive(Deserialize)]
struct UserTraceSummaryQuery {
    limit: Option<i64>,
    window_days: Option<i64>,
}

#[derive(Deserialize)]
struct CreateUserVirtualKeyRequest {
    name: String,
    default_profile_id: Option<Uuid>,
    ip_allowlist: Option<Value>,
    rate_limit_policy: Option<Value>,
    budget_policy: Option<Value>,
    metadata: Option<Value>,
}

#[derive(Debug, Serialize)]
struct UserAuthResponse {
    user: UserResponse,
    session: UserSessionResponse,
    project: UserProjectResponse,
    session_token_once: String,
}

#[derive(Debug, Serialize)]
struct UserMeResponse {
    user: UserResponse,
    session: UserSessionResponse,
    project: UserProjectResponse,
}

#[derive(Debug, Serialize)]
struct UserResponse {
    id: Uuid,
    tenant_id: Uuid,
    email: String,
    display_name: String,
    terms_version: String,
    privacy_version: String,
    accepted_at: Option<String>,
    pending_acceptance: bool,
}

impl UserResponse {
    fn from_account(account: &UserAccount) -> Self {
        Self {
            id: account.id,
            tenant_id: account.tenant_id,
            email: account.email.clone(),
            display_name: account.display_name.clone(),
            terms_version: account.policy.terms_version.clone(),
            privacy_version: account.policy.privacy_version.clone(),
            accepted_at: account.policy.accepted_at.clone(),
            pending_acceptance: account.policy.pending_acceptance,
        }
    }
}

#[derive(Debug, Clone)]
struct UserPolicyHandoff {
    terms_version: String,
    privacy_version: String,
    accepted_at: Option<String>,
    pending_acceptance: bool,
}

#[derive(Debug, Serialize)]
struct UserSessionResponse {
    id: Uuid,
    expires_at: String,
}

#[derive(Debug, Serialize)]
struct UserProjectResponse {
    id: Uuid,
    role: String,
}

#[derive(Debug, Serialize)]
struct UserProductizationStatusResponse {
    status: &'static str,
    code: &'static str,
    message: &'static str,
    next_action: &'static str,
    email_delivery: &'static str,
    email_configured: bool,
    delivery_mode: &'static str,
    expires_in_seconds: Option<i64>,
    request_id: String,
    audit: Value,
    account_disclosure: &'static str,
    secret_safe: bool,
}

#[derive(Debug, Serialize)]
struct UserVirtualKeyResponse {
    id: Uuid,
    tenant_id: Uuid,
    project_id: Uuid,
    name: String,
    key_prefix: String,
    status: String,
    default_profile_id: Option<Uuid>,
    ip_allowlist: Value,
    rate_limit_policy: Value,
    budget_policy: Value,
    policy_diagnostics: Value,
    metadata: Value,
    secret: Option<String>,
    secret_once: bool,
    secret_redacted: bool,
}

#[derive(Debug, Serialize)]
struct UserModelResponse {
    id: Uuid,
    model: String,
    display_name: String,
    family: Option<String>,
    visibility: String,
    status: String,
    context_length: Option<i32>,
    max_output_tokens: Option<i32>,
    supports_stream: bool,
    supports_tools: bool,
    supports_vision: bool,
    supports_audio: bool,
    supports_reasoning: bool,
    protocol_modes: Vec<String>,
    routable: bool,
    routable_channel_count: i64,
    unavailable_reasons: Vec<String>,
    default_profile_id: Option<Uuid>,
    price: Option<Value>,
}

#[derive(Debug, Serialize)]
struct UserReadinessResponse {
    schema: &'static str,
    state: &'static str,
    project_id: Uuid,
    checks: Vec<UserReadinessCheck>,
    counts: UserReadinessCounts,
    next_action: &'static str,
    secret_safe: bool,
}

#[derive(Debug, Serialize)]
struct UserReadinessCheck {
    code: &'static str,
    label: &'static str,
    status: &'static str,
    detail: String,
    next_action: &'static str,
}

#[derive(Debug, Serialize)]
struct UserReadinessCounts {
    active_profiles: i64,
    active_keys: i64,
    available_models: i64,
    routable_models: i64,
    recent_requests: i64,
}

#[derive(Debug, Serialize)]
struct UserSubscriptionPaymentOverviewResponse {
    schema: &'static str,
    project_id: Uuid,
    current_subscription: UserCurrentSubscriptionSummary,
    scheduler_demo: Value,
    plans: Vec<Value>,
    demo_payment: UserPaymentDemoSummary,
    local_only: bool,
    merchant_connected: bool,
    pending_scheduler: bool,
    scheduler_status: &'static str,
    secret_safe: bool,
    raw_payment_payload_returned: bool,
    raw_invoice_metadata_returned: bool,
    raw_idempotency_key_echoed: bool,
}

#[derive(Debug, Serialize)]
struct UserCurrentSubscriptionSummary {
    status: String,
    lifecycle_state: String,
    plan_id: Option<Uuid>,
    plan_code: Option<String>,
    current_period_start: Option<String>,
    current_period_end: Option<String>,
    next_renewal_at: Option<String>,
    renewal_status: String,
    grace_status: String,
    dunning_status: String,
    included_credit_remaining: Option<String>,
    next_action: &'static str,
}

#[derive(Debug, Serialize)]
struct UserPaymentDemoSummary {
    order_status: &'static str,
    invoice_status: &'static str,
    local_only: bool,
    merchant_connected: bool,
    production_payment_evidence: bool,
    next_action: &'static str,
}

#[derive(Debug, Serialize)]
struct UserUsageSummaryResponse {
    schema: &'static str,
    project_id: Uuid,
    window_days: i64,
    totals: UserUsageTotals,
    by_model: Vec<UserUsageModelSummary>,
    by_key: Vec<UserUsageKeySummary>,
    top_errors: Vec<UserUsageErrorSummary>,
    secret_safe: bool,
}

#[derive(Debug, Serialize)]
struct UserUsageTotals {
    request_count: i64,
    success_count: i64,
    failed_count: i64,
    retryable_failed_count: i64,
    input_tokens: i64,
    output_tokens: i64,
    total_tokens: i64,
    total_cost: String,
    currency: String,
    avg_latency_ms: Option<i64>,
}

#[derive(Debug, Serialize)]
struct UserUsageModelSummary {
    model: String,
    request_count: i64,
    success_count: i64,
    failed_count: i64,
    total_tokens: i64,
    total_cost: String,
    currency: String,
    avg_latency_ms: Option<i64>,
}

#[derive(Debug, Serialize)]
struct UserUsageKeySummary {
    virtual_key_id: Option<Uuid>,
    key_prefix: Option<String>,
    key_name: Option<String>,
    request_count: i64,
    failed_count: i64,
    total_tokens: i64,
    total_cost: String,
    currency: String,
    last_request_at: Option<String>,
}

#[derive(Debug, Serialize)]
struct UserUsageErrorSummary {
    error_code: String,
    error_owner: Option<String>,
    request_count: i64,
    retryable_count: i64,
    last_seen_at: Option<String>,
}

#[derive(Debug, Serialize)]
struct UserHomeSummaryResponse {
    schema: &'static str,
    project_id: Uuid,
    endpoint: UserHomeEndpointSummary,
    balance: Value,
    models: UserHomeModelsSummary,
    recent_usage: UserUsageTotals,
    recent_requests: UserHomeRecentRequestsSummary,
    handoff: UserHomeHandoffSummary,
    secret_safe: bool,
}

#[derive(Debug, Serialize)]
struct UserHomeEndpointSummary {
    base_url: String,
    models_url: String,
    chat_completions_url: String,
    openai_base_url: String,
    source: &'static str,
    config_needed: bool,
}

#[derive(Debug, Serialize)]
struct UserHomeModelsSummary {
    total_visible: i64,
    routable_count: i64,
    sample: Vec<UserHomeModelSummary>,
}

#[derive(Debug, Serialize)]
struct UserHomeModelSummary {
    id: Uuid,
    model: String,
    display_name: String,
    routable: bool,
    routable_channel_count: i64,
    primary_protocol: Option<String>,
    route_status: &'static str,
}

#[derive(Debug, Serialize)]
struct UserModelAvailabilityReadback {
    schema: &'static str,
    scope: UserModelAvailabilityScope,
    visible_models: UserHomeModelsSummary,
    blocked_models: UserModelAvailabilityBlockedSummary,
    protocol_capability_summary: Vec<UserModelProtocolCapabilitySummary>,
    quota_rate_budget_guardrails: UserModelAvailabilityGuardrails,
    safe_next_action: &'static str,
    handoff: UserModelAvailabilityHandoff,
    secret_safe: bool,
}

#[derive(Debug, Serialize)]
struct UserModelAvailabilityScope {
    project_id: Uuid,
    virtual_key_id: Option<Uuid>,
    api_key_profile_id: Option<Uuid>,
    profile_status: Option<String>,
    source: &'static str,
}

#[derive(Debug, Serialize)]
struct UserModelAvailabilityBlockedSummary {
    total_blocked: i64,
    explicit_denied_count: i64,
    allowed_filter_hidden_count: i64,
    unroutable_visible_count: i64,
    reasons: Vec<UserModelAvailabilityBlockedReason>,
}

#[derive(Debug, Serialize)]
struct UserModelAvailabilityBlockedReason {
    reason: &'static str,
    count: i64,
    sample_models: Vec<String>,
}

#[derive(Debug, Serialize)]
struct UserModelProtocolCapabilitySummary {
    protocol_mode: String,
    visible_model_count: i64,
    routable_model_count: i64,
    status: &'static str,
}

#[derive(Debug, Serialize)]
struct UserModelAvailabilityGuardrails {
    active_virtual_key_count: i64,
    active_profile_count: i64,
    rate_limit_policy_present: bool,
    rate_limit_policy_present_count: i64,
    budget_policy_present: bool,
    budget_policy_present_count: i64,
    pricing_guardrail_present: bool,
    active_price_version_count: i64,
    raw_policy_payload_returned: bool,
    provider_key_returned: bool,
}

#[derive(Debug, Serialize)]
struct UserModelAvailabilityHandoff {
    contract: &'static str,
    source: &'static str,
    omitted_fields: Vec<&'static str>,
    raw_api_key_returned: bool,
    api_key_secret_hash_returned: bool,
    authorization_returned: bool,
    provider_key_returned: bool,
    raw_route_policy_returned: bool,
    raw_payload_returned: bool,
}

#[derive(Debug, Serialize)]
struct UserHomeRecentRequestsSummary {
    count: i64,
    request_ids: Vec<Uuid>,
    requests: Vec<Value>,
}

#[derive(Debug, Serialize)]
struct UserHomeHandoffSummary {
    contract: &'static str,
    fallback: &'static str,
    omitted_fields: Vec<&'static str>,
}

#[derive(Debug, Serialize)]
struct UserDeveloperQuickstartReadbackResponse {
    schema: &'static str,
    project_id: Uuid,
    endpoint: UserHomeEndpointSummary,
    available_models: UserHomeModelsSummary,
    model_availability_readback: UserModelAvailabilityReadback,
    current_key_status: UserDeveloperQuickstartKeyStatus,
    recent_request_ids: Vec<Uuid>,
    mock_readiness: Vec<UserDeveloperQuickstartEndpointReadiness>,
    billing_balance_summary: Value,
    safe_next_actions: Vec<&'static str>,
    handoff: UserDeveloperQuickstartHandoff,
    secret_safe: bool,
}

#[derive(Debug, Serialize)]
struct UserDeveloperDistributionPacketReadbackResponse {
    schema: &'static str,
    project_id: Uuid,
    endpoint_readiness: Vec<UserDeveloperQuickstartEndpointReadiness>,
    model_availability: UserHomeModelsSummary,
    quota_rate_budget_guardrails: UserDeveloperDistributionGuardrails,
    voucher_key_handoff_refs: UserDeveloperDistributionHandoffRefs,
    safe_next_action: &'static str,
    handoff: UserDeveloperDistributionPacketHandoff,
    secret_safe: bool,
}

#[derive(Debug, Serialize)]
struct UserDeveloperDistributionGuardrails {
    schema: &'static str,
    status: &'static str,
    active_virtual_key_count: i64,
    active_profile_count: i64,
    rate_limit_policy_present_count: i64,
    budget_policy_present_count: i64,
    active_price_version_count: i64,
    provider_key_limit_guardrail_count: i64,
    guardrails_present: bool,
    raw_policy_payload_returned: bool,
    provider_key_returned: bool,
    safe_next_action: &'static str,
}

#[derive(Debug, Serialize)]
struct UserDeveloperDistributionHandoffRefs {
    schema: &'static str,
    user_voucher_redeem_route: &'static str,
    user_virtual_key_route: &'static str,
    user_models_route: &'static str,
    user_balance_route: &'static str,
    user_request_logs_route: &'static str,
    developer_quickstart_route: &'static str,
    operator_packet_artifact_ref: &'static str,
    raw_api_key_returned: bool,
    voucher_code_returned: bool,
    api_key_secret_returned: bool,
    provider_key_returned: bool,
    authorization_returned: bool,
}

#[derive(Debug, Serialize)]
struct UserDeveloperDistributionPacketHandoff {
    contract: &'static str,
    source: &'static str,
    fallback: &'static str,
    omitted_fields: Vec<&'static str>,
    raw_payload_returned: bool,
    authorization_returned: bool,
    token_returned: bool,
    raw_api_key_returned: bool,
    voucher_code_returned: bool,
    provider_key_returned: bool,
    api_key_secret_returned: bool,
}

#[derive(Debug, Serialize)]
struct UserDeveloperQuickstartKeyStatus {
    total_keys: i64,
    active_keys: i64,
    disabled_keys: i64,
    expired_keys: i64,
    deleted_keys: i64,
    current_status: &'static str,
    latest_key: Option<UserDeveloperQuickstartLatestKey>,
    raw_api_key_returned: bool,
    secret_hash_returned: bool,
}

#[derive(Debug, Serialize)]
struct UserDeveloperQuickstartLatestKey {
    id: Uuid,
    name: String,
    key_prefix: String,
    status: String,
    default_profile_id: Option<Uuid>,
    last_used_at: Option<String>,
    created_at: String,
}

#[derive(Debug, Serialize)]
struct UserDeveloperQuickstartEndpointReadiness {
    endpoint: &'static str,
    path: &'static str,
    status: &'static str,
    route_ready: bool,
    recent_success_count: i64,
    required: Vec<&'static str>,
    next_action: &'static str,
}

#[derive(Debug, Serialize)]
struct UserDeveloperQuickstartHandoff {
    contract: &'static str,
    source: &'static str,
    fallback: &'static str,
    omitted_fields: Vec<&'static str>,
    raw_payload_returned: bool,
    authorization_returned: bool,
    provider_key_returned: bool,
}

#[derive(Debug, Serialize)]
struct UserSecurityActivitySummaryResponse {
    schema: &'static str,
    project_id: Uuid,
    user_id: Uuid,
    window_days: i64,
    login_activity: Value,
    password_and_email_requests: Value,
    api_key_activity: Value,
    balance_and_ledger_activity: Value,
    safe_next_actions: Vec<&'static str>,
    handoff: UserSecurityActivityHandoff,
    secret_safe: bool,
}

#[derive(Debug, Serialize)]
struct UserTeamSummaryResponse {
    schema: &'static str,
    tenant_id: Uuid,
    project_id: Uuid,
    user_id: Uuid,
    role: String,
    status: &'static str,
    membership_source: &'static str,
    project_access: Value,
    recent_usage: Value,
    team_members: Vec<Value>,
    safe_next_action: &'static str,
    handoff: UserTeamSummaryHandoff,
    secret_safe: bool,
}

#[derive(Debug, Serialize)]
struct UserTeamSummaryHandoff {
    contract: &'static str,
    source: &'static str,
    fallback: &'static str,
    omitted_fields: Vec<&'static str>,
    raw_email_returned: bool,
    raw_metadata_returned: bool,
    secret_returned: bool,
    authorization_returned: bool,
}

#[derive(Debug, Serialize)]
struct UserSecurityActivityHandoff {
    contract: &'static str,
    source: &'static str,
    fallback: &'static str,
    omitted_fields: Vec<&'static str>,
    raw_payload_returned: bool,
    authorization_returned: bool,
    password_hash_returned: bool,
    session_token_returned: bool,
    api_key_secret_returned: bool,
    api_key_secret_hash_returned: bool,
}

#[derive(Debug, Serialize)]
struct UserBillingHistoryReadbackResponse {
    schema: &'static str,
    project_id: Uuid,
    user_id: Uuid,
    wallet_id: Uuid,
    window_days: i64,
    balance: Value,
    credit_grant_expiration_readback: Value,
    ledger_recent_entries: Value,
    request_usage_cost_rollup: UserUsageTotals,
    refs_presence: Value,
    safe_next_action: &'static str,
    omitted_fields: Vec<&'static str>,
    raw_api_key_returned: bool,
    authorization_returned: bool,
    provider_key_returned: bool,
    raw_payload_returned: bool,
    raw_ledger_metadata_returned: bool,
    raw_invoice_metadata_returned: bool,
    secret_safe: bool,
}

#[derive(Debug, Serialize)]
struct UserTraceSummaryResponse {
    schema: &'static str,
    project_id: Uuid,
    trace_id: String,
    limit: i64,
    limit_reached: bool,
    window_days: i64,
    request_count: i64,
    error_count: i64,
    last_error: Option<UserTraceLastError>,
    total_input_tokens: i64,
    total_output_tokens: i64,
    total_cost: String,
    currencies: Vec<String>,
    first_request_at: Option<String>,
    last_request_at: Option<String>,
    requests: Vec<Value>,
    secret_safe: bool,
}

#[derive(Debug, Serialize)]
struct UserTraceLastError {
    code: Option<String>,
    owner: Option<String>,
    http_status: Option<i32>,
    observed_at: String,
}

async fn register(
    State(state): State<Arc<ControlPlaneState>>,
    headers: HeaderMap,
    Json(request): Json<RegisterRequest>,
) -> Result<Response, AuthError> {
    let email = normalize_email(&request.email).ok_or_else(AuthError::bad_request)?;
    let password = normalize_password(&request.password).ok_or_else(AuthError::bad_request)?;
    let display_name = request
        .display_name
        .as_deref()
        .and_then(normalize_display_name)
        .unwrap_or_else(|| display_name_from_email(&email));
    let password_hash =
        hash_admin_password(&password).map_err(|_| AuthError::service_unavailable())?;

    let mut tx = state
        .db()
        .begin()
        .await
        .map_err(|_| AuthError::service_unavailable())?;
    ensure_default_project_exists(&mut tx).await?;

    let inserted = sqlx::query(
        r#"
        insert into users (tenant_id, email, display_name, password_hash, status, metadata)
        values (
          $1,
          $2,
          $3,
          $4,
          'active',
          jsonb_build_object(
            'created_by', 'new_api_mvp_self_serve',
            'terms_version', $5::text,
            'privacy_version', $6::text,
            'accepted_at', now()
          )
        )
        on conflict (tenant_id, (lower(email))) where deleted_at is null do nothing
        returning id, tenant_id, email, display_name, password_hash, metadata
        "#,
    )
    .bind(DEFAULT_TENANT_ID)
    .bind(&email)
    .bind(&display_name)
    .bind(&password_hash)
    .bind(CURRENT_TERMS_VERSION)
    .bind(CURRENT_PRIVACY_VERSION)
    .fetch_optional(&mut *tx)
    .await
    .map_err(|_| AuthError::service_unavailable())?;

    let Some(inserted) = inserted else {
        return Err(AuthError::conflict(
            "email_already_registered",
            "email is already registered",
        ));
    };

    let user_id: Uuid = inserted
        .try_get("id")
        .map_err(|_| AuthError::service_unavailable())?;
    sqlx::query(
        r#"
        insert into project_members (tenant_id, project_id, user_id, role)
        values ($1, $2, $3, 'developer')
        on conflict (tenant_id, project_id, user_id) do update set role = 'developer'
        "#,
    )
    .bind(DEFAULT_TENANT_ID)
    .bind(DEFAULT_PROJECT_ID)
    .bind(user_id)
    .execute(&mut *tx)
    .await
    .map_err(|_| AuthError::service_unavailable())?;

    tx.commit()
        .await
        .map_err(|_| AuthError::service_unavailable())?;

    let account = UserAccount {
        id: user_id,
        tenant_id: inserted
            .try_get("tenant_id")
            .map_err(|_| AuthError::service_unavailable())?,
        email: inserted
            .try_get("email")
            .map_err(|_| AuthError::service_unavailable())?,
        display_name: inserted
            .try_get("display_name")
            .map_err(|_| AuthError::service_unavailable())?,
        password_hash: inserted
            .try_get("password_hash")
            .map_err(|_| AuthError::service_unavailable())?,
        project_id: DEFAULT_PROJECT_ID,
        project_role: "developer".to_string(),
        policy: user_policy_handoff_from_metadata(
            inserted
                .try_get("metadata")
                .map_err(|_| AuthError::service_unavailable())?,
        ),
    };

    create_login_response(state.as_ref(), &headers, account).await
}

async fn login(
    State(state): State<Arc<ControlPlaneState>>,
    headers: HeaderMap,
    Json(request): Json<LoginRequest>,
) -> Result<Response, AuthError> {
    let email = normalize_email(&request.email).ok_or_else(AuthError::invalid_credentials)?;
    if request.password.is_empty() {
        return Err(AuthError::invalid_credentials());
    }

    let key = admin_login_failure_rate_limit_key(DEFAULT_TENANT_ID, &email);
    let now = current_epoch_seconds();
    let policy = crate::auth::login_failure_rate_limit_policy();
    let decision = state.login_failure_rate_limits().check(&key, now, policy);
    if decision.is_limited {
        return Err(AuthError::login_rate_limited(
            decision.retry_after_seconds.unwrap_or(1),
        ));
    }

    let Some(account) = find_user_account_by_email(state.as_ref(), &email).await? else {
        return Err(record_user_login_failure(state.as_ref(), &key, now, policy));
    };
    let Some(hash) = account.password_hash.as_deref() else {
        return Err(record_user_login_failure(state.as_ref(), &key, now, policy));
    };
    let matches = verify_admin_password(&request.password, hash)
        .map_err(|_| AuthError::invalid_credentials())?;
    if !matches {
        return Err(record_user_login_failure(state.as_ref(), &key, now, policy));
    }

    state.login_failure_rate_limits().clear(&key);
    create_login_response(state.as_ref(), &headers, account).await
}

async fn request_password_reset(
    Json(request): Json<PasswordResetRequest>,
) -> Result<Response, AuthError> {
    normalize_email(&request.email).ok_or_else(AuthError::bad_request)?;

    Ok(Json(json!({
        "data": productization_status_response(
            "password_reset_email_config_needed",
            "If the account can receive email, a reset link will be queued after mail delivery is configured.",
            "Configure the user mail sender and SMTP adapter, then retry this request.",
            "password_reset",
        )
    }))
    .into_response())
}

async fn request_email_verification(session: UserSession) -> Result<Response, AuthError> {
    let _email = &session.user.email;

    Ok(Json(json!({
        "data": productization_status_response(
            "email_verification_config_needed",
            "Email verification is pending because user mail delivery is not configured.",
            "Configure the user mail sender and SMTP adapter, then request verification again.",
            "email_verification",
        )
    }))
    .into_response())
}

async fn me(session: UserSession) -> Result<Response, AuthError> {
    Ok(Json(json!({ "data": session.response() })).into_response())
}

async fn logout(
    State(state): State<Arc<ControlPlaneState>>,
    session: UserSession,
) -> Result<Response, AuthError> {
    AuthRepository::new(state.db().clone())
        .revoke_session(session.user.tenant_id, session.id)
        .await?;

    let mut response = Json(json!({ "data": { "logged_out": true } })).into_response();
    response.headers_mut().insert(
        SET_COOKIE,
        HeaderValue::from_str(&clear_user_session_cookie())
            .expect("clear user session cookie contains only header-safe characters"),
    );
    Ok(response)
}

async fn get_user_balance(
    State(state): State<Arc<ControlPlaneState>>,
    session: UserSession,
    Query(query): Query<UserBalanceQuery>,
) -> Result<Response, AdminError> {
    let currency = normalize_user_currency(query.currency.as_deref())?;
    let wallet = ensure_user_wallet_exists(state.as_ref(), &session, &currency).await?;
    let principal = RemainingBalancePrincipal {
        source: RemainingBalancePrincipalSource::UserSession,
        tenant_id: session.user.tenant_id,
        project_id: session.user.project_id,
        user_id: Some(session.user.id),
        virtual_key_id: None,
        wallet_id: wallet.id,
        currency: wallet.currency.clone(),
    };
    let balance = admin::user_remaining_balance_runtime_response(
        state.as_ref(),
        wallet.id,
        principal,
        query.ledger_window_days,
    )
    .await?;

    Ok(Json(json!({ "data": balance })).into_response())
}

async fn get_user_billing_history_readback(
    State(state): State<Arc<ControlPlaneState>>,
    session: UserSession,
) -> Result<Response, AdminError> {
    let window_days = 30;
    let wallet = ensure_user_wallet_exists(state.as_ref(), &session, "USD").await?;
    let principal = RemainingBalancePrincipal {
        source: RemainingBalancePrincipalSource::UserSession,
        tenant_id: session.user.tenant_id,
        project_id: session.user.project_id,
        user_id: Some(session.user.id),
        virtual_key_id: None,
        wallet_id: wallet.id,
        currency: wallet.currency.clone(),
    };
    let balance = admin::user_remaining_balance_runtime_response(
        state.as_ref(),
        wallet.id,
        principal,
        Some(window_days),
    )
    .await?;
    let ledger_recent_entries =
        user_billing_history_recent_ledger_entries(state.as_ref(), &session, window_days).await?;
    let request_usage_cost_rollup =
        user_home_recent_usage(state.as_ref(), &session, window_days).await?;
    let refs_presence =
        user_billing_history_refs_presence(state.as_ref(), &session, wallet.id).await?;
    let safe_next_action = user_billing_history_safe_next_action(
        &ledger_recent_entries,
        &request_usage_cost_rollup,
        &refs_presence,
    );

    Ok(Json(json!({
        "data": UserBillingHistoryReadbackResponse {
            schema: "user_billing_history_readback.v1",
            project_id: session.user.project_id,
            user_id: session.user.id,
            wallet_id: wallet.id,
            window_days,
            credit_grant_expiration_readback: balance
                .get("credit_grant_expiration_readback")
                .cloned()
                .unwrap_or(Value::Null),
            balance,
            ledger_recent_entries,
            request_usage_cost_rollup,
            refs_presence,
            safe_next_action,
            omitted_fields: vec![
                "raw_api_key",
                "api_key_secret",
                "api_key_secret_hash",
                "Authorization",
                "provider_key",
                "provider_key_id",
                "raw_payload",
                "raw_request_payload",
                "raw_response_payload",
                "raw_provider_payload",
                "raw_ledger_metadata",
                "raw_invoice_metadata",
                "raw_voucher_code",
                "voucher_code_hash",
                "raw_idempotency_key",
            ],
            raw_api_key_returned: false,
            authorization_returned: false,
            provider_key_returned: false,
            raw_payload_returned: false,
            raw_ledger_metadata_returned: false,
            raw_invoice_metadata_returned: false,
            secret_safe: true,
        }
    }))
    .into_response())
}

async fn get_user_home_summary(
    State(state): State<Arc<ControlPlaneState>>,
    session: UserSession,
) -> Result<Response, AdminError> {
    let wallet = ensure_user_wallet_exists(state.as_ref(), &session, "USD").await?;
    let principal = RemainingBalancePrincipal {
        source: RemainingBalancePrincipalSource::UserSession,
        tenant_id: session.user.tenant_id,
        project_id: session.user.project_id,
        user_id: Some(session.user.id),
        virtual_key_id: None,
        wallet_id: wallet.id,
        currency: wallet.currency.clone(),
    };
    let balance = admin::user_remaining_balance_runtime_response(
        state.as_ref(),
        wallet.id,
        principal,
        Some(7),
    )
    .await?;
    let models = user_home_models_summary(state.as_ref(), &session).await?;
    let recent_usage = user_home_recent_usage(state.as_ref(), &session, 7).await?;
    let recent_requests = user_home_recent_requests(state.as_ref(), &session, 5).await?;
    let endpoint = user_home_endpoint_summary();

    Ok(Json(json!({
        "data": UserHomeSummaryResponse {
            schema: "user_home_summary.v1",
            project_id: session.user.project_id,
            endpoint,
            balance,
            models,
            recent_usage,
            recent_requests,
            handoff: UserHomeHandoffSummary {
                contract: "GET /user/home-summary",
                fallback: "If this endpoint is unavailable, use /user/balance, /user/models, /user/usage-summary, and /user/request-logs.",
                omitted_fields: vec![
                    "api_key_secret",
                    "provider_key",
                    "authorization",
                    "voucher_raw_code",
                    "raw_request_payload",
                    "prompt",
                    "upstream_payload",
                ],
            },
            secret_safe: true,
        }
    }))
    .into_response())
}

async fn get_user_developer_quickstart_readback(
    State(state): State<Arc<ControlPlaneState>>,
    session: UserSession,
) -> Result<Response, AdminError> {
    let wallet = ensure_user_wallet_exists(state.as_ref(), &session, "USD").await?;
    let principal = RemainingBalancePrincipal {
        source: RemainingBalancePrincipalSource::UserSession,
        tenant_id: session.user.tenant_id,
        project_id: session.user.project_id,
        user_id: Some(session.user.id),
        virtual_key_id: None,
        wallet_id: wallet.id,
        currency: wallet.currency.clone(),
    };
    let billing_balance_summary = admin::user_remaining_balance_runtime_response(
        state.as_ref(),
        wallet.id,
        principal,
        Some(7),
    )
    .await?;
    let endpoint = user_home_endpoint_summary();
    let available_models = user_home_models_summary(state.as_ref(), &session).await?;
    let model_availability_readback =
        user_model_availability_readback(state.as_ref(), &session).await?;
    let recent_requests = user_home_recent_requests(state.as_ref(), &session, 5).await?;
    let current_key_status = user_developer_quickstart_key_status(state.as_ref(), &session).await?;
    let mock_readiness = user_developer_quickstart_mock_readiness(
        state.as_ref(),
        &session,
        available_models.routable_count,
        current_key_status.active_keys,
    )
    .await?;
    let safe_next_actions =
        user_developer_quickstart_next_actions(&current_key_status, &available_models);

    Ok(Json(json!({
        "data": UserDeveloperQuickstartReadbackResponse {
            schema: "user_developer_quickstart_readback.v1",
            project_id: session.user.project_id,
            endpoint,
            available_models,
            model_availability_readback,
            current_key_status,
            recent_request_ids: recent_requests.request_ids,
            mock_readiness,
            billing_balance_summary,
            safe_next_actions,
            handoff: UserDeveloperQuickstartHandoff {
                contract: "GET /user/developer-quickstart-readback",
                source: "user_session_project_scoped_readback",
                fallback: "Use /user/home-summary, /user/models, /user/virtual-keys, /user/request-logs, and /user/balance if this aggregate endpoint is unavailable.",
                omitted_fields: vec![
                    "api_key_secret",
                    "api_key_secret_hash",
                    "Authorization",
                    "provider_key",
                    "provider_key_id",
                    "raw_request_payload",
                    "raw_response_payload",
                    "prompt",
                    "messages",
                    "embedding_input",
                    "upstream_payload",
                ],
                raw_payload_returned: false,
                authorization_returned: false,
                provider_key_returned: false,
            },
            secret_safe: true,
        }
    }))
    .into_response())
}

async fn get_user_developer_distribution_packet_readback(
    State(state): State<Arc<ControlPlaneState>>,
    session: UserSession,
) -> Result<Response, AdminError> {
    let model_availability = user_home_models_summary(state.as_ref(), &session).await?;
    let current_key_status = user_developer_quickstart_key_status(state.as_ref(), &session).await?;
    let endpoint_readiness = user_developer_quickstart_mock_readiness(
        state.as_ref(),
        &session,
        model_availability.routable_count,
        current_key_status.active_keys,
    )
    .await?;
    let quota_rate_budget_guardrails =
        user_developer_distribution_guardrails(state.as_ref(), &session).await?;
    let safe_next_action = user_developer_distribution_safe_next_action(
        &endpoint_readiness,
        &model_availability,
        &quota_rate_budget_guardrails,
        &current_key_status,
    );

    Ok(Json(json!({
        "data": UserDeveloperDistributionPacketReadbackResponse {
            schema: "developer_distribution_packet_readback.v1",
            project_id: session.user.project_id,
            endpoint_readiness,
            model_availability,
            quota_rate_budget_guardrails,
            voucher_key_handoff_refs: UserDeveloperDistributionHandoffRefs {
                schema: "developer_distribution_handoff_refs.v1",
                user_voucher_redeem_route: "POST /user/vouchers/redeem",
                user_virtual_key_route: "GET/POST /user/virtual-keys",
                user_models_route: "GET /user/models",
                user_balance_route: "GET /user/balance",
                user_request_logs_route: "GET /user/request-logs",
                developer_quickstart_route: "GET /user/developer-quickstart-readback",
                operator_packet_artifact_ref: ".tmp/launch/trusted_user_distribution_review_packet.json",
                raw_api_key_returned: false,
                voucher_code_returned: false,
                api_key_secret_returned: false,
                provider_key_returned: false,
                authorization_returned: false,
            },
            safe_next_action,
            handoff: UserDeveloperDistributionPacketHandoff {
                contract: "GET /user/developer-distribution-packet-readback",
                source: "user_session_project_scoped_distribution_packet_readback",
                fallback: "Use /user/developer-quickstart-readback, /user/models, /user/virtual-keys, /user/balance, and /user/request-logs if this packet endpoint is unavailable.",
                omitted_fields: vec![
                    "raw_api_key",
                    "api_key_secret",
                    "api_key_secret_hash",
                    "raw_voucher_code",
                    "voucher_code_hash",
                    "provider_key",
                    "provider_key_id",
                    "Authorization",
                    "token",
                    "session_token",
                    "raw_request_payload",
                    "raw_response_payload",
                    "upstream_payload",
                ],
                raw_payload_returned: false,
                authorization_returned: false,
                token_returned: false,
                raw_api_key_returned: false,
                voucher_code_returned: false,
                provider_key_returned: false,
                api_key_secret_returned: false,
            },
            secret_safe: true,
        }
    }))
    .into_response())
}

async fn get_user_security_activity_summary(
    State(state): State<Arc<ControlPlaneState>>,
    session: UserSession,
) -> Result<Response, AdminError> {
    let window_days = 30;
    let login_activity =
        user_security_login_activity(state.as_ref(), &session, window_days).await?;
    let password_and_email_requests = user_security_password_email_activity(&session);
    let api_key_activity =
        user_security_api_key_activity(state.as_ref(), &session, window_days).await?;
    let balance_and_ledger_activity =
        user_security_balance_ledger_activity(state.as_ref(), &session, window_days).await?;
    let safe_next_actions = user_security_activity_next_actions(
        &login_activity,
        &api_key_activity,
        &balance_and_ledger_activity,
    );

    Ok(Json(json!({
        "data": UserSecurityActivitySummaryResponse {
            schema: "user_security_activity_summary.v1",
            project_id: session.user.project_id,
            user_id: session.user.id,
            window_days,
            login_activity,
            password_and_email_requests,
            api_key_activity,
            balance_and_ledger_activity,
            safe_next_actions,
            handoff: UserSecurityActivityHandoff {
                contract: "GET /user/security-activity-summary",
                source: "user_session_project_scoped_readback",
                fallback: "Use /auth/me, /user/virtual-keys, /user/balance, /user/request-logs, and admin /admin/audit-logs for deeper operator review.",
                omitted_fields: vec![
                    "password_hash",
                    "session_token",
                    "token_hash",
                    "api_key_secret",
                    "api_key_secret_hash",
                    "secret_hash",
                    "Authorization",
                    "request_body",
                    "response_body",
                    "raw_payload",
                    "provider_key",
                    "provider_key_id",
                    "voucher_raw_code",
                ],
                raw_payload_returned: false,
                authorization_returned: false,
                password_hash_returned: false,
                session_token_returned: false,
                api_key_secret_returned: false,
                api_key_secret_hash_returned: false,
            },
            secret_safe: true,
        }
    }))
    .into_response())
}

async fn get_user_team_summary(
    State(state): State<Arc<ControlPlaneState>>,
    session: UserSession,
) -> Result<Response, AdminError> {
    let project_access = user_team_project_access_summary(state.as_ref(), &session).await?;
    let recent_usage = user_team_recent_usage_summary(state.as_ref(), &session).await?;
    let team_members = user_team_member_samples(state.as_ref(), &session).await?;
    let safe_next_action = user_team_safe_next_action(&project_access, &recent_usage);

    Ok(Json(json!({
        "data": UserTeamSummaryResponse {
            schema: "user_team_membership_compact_readback.v1",
            tenant_id: session.user.tenant_id,
            project_id: session.user.project_id,
            user_id: session.user.id,
            role: session.user.project_role.clone(),
            status: "active",
            membership_source: "user_session_project_members",
            project_access,
            recent_usage,
            team_members,
            safe_next_action,
            handoff: UserTeamSummaryHandoff {
                contract: "GET /user/team-summary",
                source: "user_session_project_scoped_membership_readback",
                fallback: "Use /auth/me, /user/virtual-keys, /user/models, /user/usage-summary, and /user/request-logs if this aggregate endpoint is unavailable.",
                omitted_fields: vec![
                    "raw_email",
                    "session_token",
                    "api_key_secret",
                    "api_key_secret_hash",
                    "Authorization",
                    "provider_key",
                    "provider_key_id",
                    "raw_request_payload",
                    "raw_response_payload",
                    "raw_metadata",
                    "upstream_payload",
                ],
                raw_email_returned: false,
                raw_metadata_returned: false,
                secret_returned: false,
                authorization_returned: false,
            },
            secret_safe: true,
        }
    }))
    .into_response())
}

async fn get_user_readiness(
    State(state): State<Arc<ControlPlaneState>>,
    session: UserSession,
) -> Result<Response, AuthError> {
    let row = sqlx::query(
        r#"
        with active_profiles as (
          select id, allowed_models, denied_models
          from api_key_profiles
          where tenant_id = $1
            and project_id = $2
            and status = 'active'
            and deleted_at is null
        ),
        first_profile as (
          select id, allowed_models, denied_models
          from active_profiles
          order by id asc
          limit 1
        ),
        available_models as (
          select
            m.id,
            count(distinct c.id) filter (
              where ma.status = 'enabled'
                and c.status = 'enabled'
                and p.status = 'enabled'
            ) as routable_channel_count
          from first_profile fp
          join canonical_models m on m.tenant_id = $1
            and m.status = 'active'
            and m.visibility in ('public', 'internal')
            and m.deleted_at is null
            and (
              jsonb_array_length(fp.allowed_models) = 0
              or fp.allowed_models ? m.model_key
            )
            and not (fp.denied_models ? m.model_key)
          left join model_associations ma on ma.tenant_id = m.tenant_id
            and ma.canonical_model_id = m.id
            and ma.status = 'enabled'
            and ma.deleted_at is null
          left join channels c on c.tenant_id = ma.tenant_id
            and c.id = ma.channel_id
            and c.deleted_at is null
          left join providers p on p.tenant_id = c.tenant_id
            and p.id = c.provider_id
            and p.deleted_at is null
          group by m.id
        )
        select
          (select count(*) from active_profiles) as active_profiles,
          (select count(*) from virtual_keys vk
            where vk.tenant_id = $1
              and vk.project_id = $2
              and vk.status = 'active'
              and exists (
                select 1 from virtual_key_profile_bindings vkb
                join api_key_profiles p on p.tenant_id = vkb.tenant_id and p.id = vkb.profile_id
                where vkb.tenant_id = vk.tenant_id
                  and vkb.virtual_key_id = vk.id
                  and p.project_id = $2
                  and p.status = 'active'
                  and p.deleted_at is null
              )
          ) as active_keys,
          (select count(*) from available_models) as available_models,
          (select count(*) from available_models where routable_channel_count > 0) as routable_models,
          (select count(*) from request_logs rl
            where rl.tenant_id = $1
              and rl.project_id = $2
          ) as recent_requests
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.project_id)
    .fetch_one(state.db())
    .await
    .map_err(|_| AuthError::service_unavailable())?;

    let counts = UserReadinessCounts {
        active_profiles: row
            .try_get("active_profiles")
            .map_err(|_| AuthError::service_unavailable())?,
        active_keys: row
            .try_get("active_keys")
            .map_err(|_| AuthError::service_unavailable())?,
        available_models: row
            .try_get("available_models")
            .map_err(|_| AuthError::service_unavailable())?,
        routable_models: row
            .try_get("routable_models")
            .map_err(|_| AuthError::service_unavailable())?,
        recent_requests: row
            .try_get("recent_requests")
            .map_err(|_| AuthError::service_unavailable())?,
    };
    let balance = ensure_user_wallet_exists(state.as_ref(), &session, "USD").await;
    let wallet_ready = balance.is_ok();
    let mut checks = vec![
        UserReadinessCheck {
            code: "account",
            label: "Account",
            status: "ready",
            detail: format!("Signed in as {}", session.user.email),
            next_action: "Continue to API setup",
        },
        UserReadinessCheck {
            code: "wallet",
            label: "Credit wallet",
            status: if wallet_ready { "ready" } else { "blocked" },
            detail: if wallet_ready {
                "Voucher-backed wallet is available.".to_string()
            } else {
                "Wallet could not be prepared for this project.".to_string()
            },
            next_action: if wallet_ready {
                "Redeem a voucher or continue with existing credit"
            } else {
                "Ask the operator to check project wallet provisioning"
            },
        },
        UserReadinessCheck {
            code: "profile",
            label: "API key profile",
            status: if counts.active_profiles > 0 {
                "ready"
            } else {
                "blocked"
            },
            detail: format!("{} active profile(s) available.", counts.active_profiles),
            next_action: if counts.active_profiles > 0 {
                "Create an API key"
            } else {
                "Ask the operator to create an active default project profile"
            },
        },
        UserReadinessCheck {
            code: "model",
            label: "Callable model",
            status: if counts.routable_models > 0 {
                "ready"
            } else if counts.available_models > 0 {
                "attention"
            } else {
                "blocked"
            },
            detail: format!(
                "{} model(s) visible, {} routable.",
                counts.available_models, counts.routable_models
            ),
            next_action: if counts.routable_models > 0 {
                "Use the recommended model in the quickstart"
            } else if counts.available_models > 0 {
                "Ask the operator to bind an upstream channel"
            } else {
                "Ask the operator to publish a model for your profile"
            },
        },
        UserReadinessCheck {
            code: "api_key",
            label: "API key",
            status: if counts.active_keys > 0 {
                "ready"
            } else if counts.active_profiles > 0 {
                "attention"
            } else {
                "blocked"
            },
            detail: format!("{} active key(s) for this project.", counts.active_keys),
            next_action: if counts.active_keys > 0 {
                "Use an existing key or create a new one"
            } else if counts.active_profiles > 0 {
                "Create your first API key"
            } else {
                "Wait for profile setup before creating a key"
            },
        },
        UserReadinessCheck {
            code: "usage",
            label: "First request",
            status: if counts.recent_requests > 0 {
                "ready"
            } else if counts.active_keys > 0 && counts.routable_models > 0 {
                "attention"
            } else {
                "blocked"
            },
            detail: format!("{} request log(s) recorded.", counts.recent_requests),
            next_action: if counts.recent_requests > 0 {
                "Review usage logs when debugging"
            } else if counts.active_keys > 0 && counts.routable_models > 0 {
                "Send the quickstart request"
            } else {
                "Complete the earlier setup steps first"
            },
        },
    ];

    let blocked = checks.iter().any(|check| check.status == "blocked");
    let attention = checks.iter().any(|check| check.status == "attention");
    let state_label = if blocked {
        "blocked"
    } else if attention {
        "attention"
    } else {
        "ready"
    };
    let next_action = checks
        .iter()
        .find(|check| check.status == "blocked" || check.status == "attention")
        .map(|check| check.next_action)
        .unwrap_or("Ready to call the Gateway");
    checks.shrink_to_fit();

    Ok(Json(json!({
        "data": UserReadinessResponse {
            schema: "user_readiness.v1",
            state: state_label,
            project_id: session.user.project_id,
            checks,
            counts,
            next_action,
            secret_safe: true,
        }
    }))
    .into_response())
}

async fn get_user_subscription_payment_overview(
    State(state): State<Arc<ControlPlaneState>>,
    session: UserSession,
) -> Result<Response, AdminError> {
    let plan_rows = sqlx::query(
        r#"
        select id, plan_code, display_name, status, currency, billing_interval,
               unit_price::text as unit_price,
               included_credit_amount::text as included_credit_amount,
               trial_days
        from subscription_plans
        where tenant_id = $1
          and status = 'active'
        order by unit_price asc, created_at desc, id desc
        limit 50
        "#,
    )
    .bind(session.user.tenant_id)
    .fetch_all(state.db())
    .await
    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;

    let plans = plan_rows
        .into_iter()
        .map(user_subscription_plan_summary)
        .collect::<Result<Vec<_>, _>>()?;

    let subscription_row = sqlx::query(
        r#"
        select s.status,
               s.plan_id,
               s.id as subscription_id,
               p.billing_interval,
               p.currency,
               p.unit_price::text as unit_price,
               p.plan_code,
               s.current_period_start::text as current_period_start,
               s.current_period_end::text as current_period_end,
               (s.current_period_end <= now()) as renewal_due,
               (s.current_period_end > now() and s.current_period_end <= now() + interval '7 days') as renewal_upcoming,
               (s.status = 'payment_failed' and now() <= s.current_period_end + interval '3 days') as in_grace,
               (s.status = 'payment_failed' and now() > s.current_period_end + interval '3 days') as in_dunning,
               (s.current_period_end + interval '3 days')::text as grace_ends_at,
               (s.current_period_end + interval '4 days')::text as next_dunning_attempt_at
        from subscriptions s
        join subscription_plans p on p.tenant_id = s.tenant_id and p.id = s.plan_id
        where s.tenant_id = $1
          and s.project_id = $2
        order by
          case
            when s.status in ('trialing', 'active', 'renewed', 'resumed') then 0
            when s.status in ('created', 'payment_failed') then 1
            else 2
          end,
          s.current_period_end desc,
          s.updated_at desc
        limit 1
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.project_id)
    .fetch_optional(state.db())
    .await
    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;

    let mut scheduler_demo = user_subscription_scheduler_demo_none();
    let current_subscription = match subscription_row {
        Some(row) => {
            let status = row
                .try_get::<String, _>("status")
                .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
            let subscription_id = row
                .try_get::<Uuid, _>("subscription_id")
                .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
            let current_period_end = row
                .try_get::<Option<String>, _>("current_period_end")
                .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
            let renewal_due = row
                .try_get::<bool, _>("renewal_due")
                .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
            let renewal_upcoming = row
                .try_get::<bool, _>("renewal_upcoming")
                .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
            let in_grace = row
                .try_get::<bool, _>("in_grace")
                .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
            let in_dunning = row
                .try_get::<bool, _>("in_dunning")
                .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
            let lifecycle_state = user_subscription_demo_lifecycle_state(
                &status,
                renewal_due,
                renewal_upcoming,
                in_grace,
                in_dunning,
            );
            let renewal_status =
                user_subscription_demo_renewal_status(&status, renewal_due, renewal_upcoming);
            let grace_status = if in_grace { "grace" } else { "not_in_grace" }.to_string();
            let dunning_status = if in_dunning {
                "dunning"
            } else {
                "not_in_dunning"
            }
            .to_string();
            scheduler_demo = user_subscription_scheduler_demo_for_row(
                state.as_ref(),
                session.user.tenant_id,
                subscription_id,
                &status,
                &lifecycle_state,
                &renewal_status,
                &grace_status,
                &dunning_status,
                current_period_end.clone(),
                &row,
            )
            .await?;
            UserCurrentSubscriptionSummary {
                next_action: user_subscription_next_action(&status),
                lifecycle_state,
                status,
                plan_id: row
                    .try_get("plan_id")
                    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
                plan_code: row
                    .try_get("plan_code")
                    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
                current_period_start: row
                    .try_get("current_period_start")
                    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
                current_period_end: current_period_end.clone(),
                next_renewal_at: current_period_end,
                renewal_status,
                grace_status,
                dunning_status,
                included_credit_remaining: None,
            }
        }
        None => UserCurrentSubscriptionSummary {
            status: "none".to_string(),
            lifecycle_state: "no_subscription".to_string(),
            plan_id: None,
            plan_code: None,
            current_period_start: None,
            current_period_end: None,
            next_renewal_at: None,
            renewal_status: "not_scheduled".to_string(),
            grace_status: "not_in_grace".to_string(),
            dunning_status: "not_in_dunning".to_string(),
            included_credit_remaining: None,
            next_action: "选择套餐后仍只进入本地支付 demo pending 状态；真实商户和 scheduler 尚未接入。",
        },
    };

    Ok(Json(json!({
        "data": UserSubscriptionPaymentOverviewResponse {
            schema: "user_subscription_payment_overview.v1",
            project_id: session.user.project_id,
            current_subscription,
            scheduler_demo,
            plans,
            demo_payment: UserPaymentDemoSummary {
                order_status: "not_created",
                invoice_status: "placeholder",
                local_only: true,
                merchant_connected: false,
                production_payment_evidence: false,
                next_action: "支付 demo 当前只展示 local-only pending 状态；不会连接真实商户、创建真实 invoice 或运行 scheduler。",
            },
            local_only: true,
            merchant_connected: false,
            pending_scheduler: true,
            scheduler_status: "pending_scheduler",
            secret_safe: true,
            raw_payment_payload_returned: false,
            raw_invoice_metadata_returned: false,
            raw_idempotency_key_echoed: false,
        }
    }))
    .into_response())
}

fn user_subscription_plan_summary(row: sqlx::postgres::PgRow) -> Result<Value, AdminError> {
    let billing_interval = row
        .try_get::<String, _>("billing_interval")
        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
    let trial_days = row
        .try_get::<i32, _>("trial_days")
        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
    let included_credit_amount = row
        .try_get::<String, _>("included_credit_amount")
        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
    let currency = row
        .try_get::<String, _>("currency")
        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;

    Ok(json!({
        "id": row.try_get::<Uuid, _>("id").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        "plan_code": row.try_get::<String, _>("plan_code").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        "display_name": row.try_get::<String, _>("display_name").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        "status": row.try_get::<String, _>("status").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        "currency": currency,
        "billing_interval": billing_interval,
        "unit_price": row.try_get::<String, _>("unit_price").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        "included_credit_amount": included_credit_amount,
        "trial_days": trial_days,
        "entitlement_summary": {
            "included_credit_amount": included_credit_amount,
            "currency": currency,
            "credit_unit": "wallet_credit_decimal",
            "money_decimal_strings": true,
            "trial_days": trial_days,
        },
        "expiration_policy": user_subscription_expiration_policy(&billing_interval, trial_days),
        "payment_status": "not_connected",
        "scheduler_status": "pending_scheduler",
        "secret_safe": true,
        "raw_payment_payload_returned": false,
    }))
}

async fn user_subscription_scheduler_demo_for_row(
    state: &ControlPlaneState,
    tenant_id: Uuid,
    subscription_id: Uuid,
    status: &str,
    lifecycle_state: &str,
    renewal_status: &str,
    grace_status: &str,
    dunning_status: &str,
    current_period_end: Option<String>,
    row: &sqlx::postgres::PgRow,
) -> Result<Value, AdminError> {
    let scheduled_rows = sqlx::query(
        r#"
        select event_type,
               event_status,
               effective_at::text as effective_at,
               refusal_code
        from subscription_events_or_schedules
        where tenant_id = $1
          and subscription_id = $2
          and event_status = 'scheduled'
          and event_type in ('renew', 'payment_failed', 'dunning', 'expire')
        order by effective_at asc, created_at asc, id asc
        limit 5
        "#,
    )
    .bind(tenant_id)
    .bind(subscription_id)
    .fetch_all(state.db())
    .await
    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
    let scheduled_events = scheduled_rows
        .into_iter()
        .map(|row| {
            Ok(json!({
                "event_type": row.try_get::<String, _>("event_type").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
                "event_status": row.try_get::<String, _>("event_status").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
                "effective_at": row.try_get::<String, _>("effective_at").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
                "refusal_code": row.try_get::<Option<String>, _>("refusal_code").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
            }))
        })
        .collect::<Result<Vec<_>, AdminError>>()?;

    let plan_code = row
        .try_get::<String, _>("plan_code")
        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
    let billing_interval = row
        .try_get::<String, _>("billing_interval")
        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
    let currency = row
        .try_get::<String, _>("currency")
        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
    let unit_price = row
        .try_get::<String, _>("unit_price")
        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
    let grace_ends_at = row
        .try_get::<Option<String>, _>("grace_ends_at")
        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
    let next_dunning_attempt_at = row
        .try_get::<Option<String>, _>("next_dunning_attempt_at")
        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;

    Ok(json!({
        "schema": "user_subscription_scheduler_demo.v1",
        "mode": "local_readback_demo",
        "local_only": true,
        "merchant_connected": false,
        "scheduler_status": "pending_scheduler",
        "runtime_scheduler_enabled": false,
        "subscription_id": subscription_id,
        "subscription_status": status,
        "lifecycle_state": lifecycle_state,
        "pending_scheduler": true,
        "upcoming_renewal": {
            "status": renewal_status,
            "due_at": current_period_end,
            "billing_interval": billing_interval,
            "plan_code": plan_code,
            "amount": unit_price,
            "currency": currency,
            "invoice_status": "placeholder",
            "order_status": "not_created",
            "ledger_write": false,
            "credit_grant_write": false,
        },
        "grace": {
            "status": grace_status,
            "grace_days": 3,
            "ends_at": grace_ends_at,
            "write_enabled": false,
        },
        "dunning": {
            "status": dunning_status,
            "attempt_count": 0,
            "next_attempt_at": next_dunning_attempt_at,
            "max_attempts": 3,
            "write_enabled": false,
        },
        "scheduled_events": scheduled_events,
        "readback_source": "subscriptions_and_subscription_events_or_schedules",
        "next_action": "本地 demo 只读展示续费周期、grace 和 dunning；不会连接真实商户、创建 invoice/order、写 ledger 或发放额度。",
        "secret_safe": true,
        "raw_payment_payload_returned": false,
        "raw_invoice_metadata_returned": false,
        "raw_idempotency_key_echoed": false,
        "raw_payload_returned": false,
    }))
}

fn user_subscription_scheduler_demo_none() -> Value {
    json!({
        "schema": "user_subscription_scheduler_demo.v1",
        "mode": "local_readback_demo",
        "local_only": true,
        "merchant_connected": false,
        "scheduler_status": "pending_scheduler",
        "runtime_scheduler_enabled": false,
        "subscription_id": null,
        "subscription_status": "none",
        "lifecycle_state": "no_subscription",
        "pending_scheduler": true,
        "upcoming_renewal": {
            "status": "not_scheduled",
            "due_at": null,
            "billing_interval": null,
            "plan_code": null,
            "amount": null,
            "currency": null,
            "invoice_status": "placeholder",
            "order_status": "not_created",
            "ledger_write": false,
            "credit_grant_write": false
        },
        "grace": {
            "status": "not_in_grace",
            "grace_days": 3,
            "ends_at": null,
            "write_enabled": false
        },
        "dunning": {
            "status": "not_in_dunning",
            "attempt_count": 0,
            "next_attempt_at": null,
            "max_attempts": 3,
            "write_enabled": false
        },
        "scheduled_events": [],
        "readback_source": "no_current_subscription",
        "next_action": "创建或导入本地订阅后，此区域会展示 upcoming renewal、grace 和 dunning readback。",
        "secret_safe": true,
        "raw_payment_payload_returned": false,
        "raw_invoice_metadata_returned": false,
        "raw_idempotency_key_echoed": false,
        "raw_payload_returned": false
    })
}

fn user_subscription_demo_lifecycle_state(
    status: &str,
    renewal_due: bool,
    renewal_upcoming: bool,
    in_grace: bool,
    in_dunning: bool,
) -> String {
    if in_dunning {
        "dunning".to_string()
    } else if in_grace {
        "grace".to_string()
    } else if renewal_due {
        "pending_renewal".to_string()
    } else if renewal_upcoming {
        "upcoming_renewal".to_string()
    } else {
        status.to_string()
    }
}

fn user_subscription_demo_renewal_status(
    status: &str,
    renewal_due: bool,
    renewal_upcoming: bool,
) -> String {
    if matches!(status, "cancelled" | "expired" | "terminated") {
        "not_scheduled".to_string()
    } else if renewal_due {
        "due_now_pending_scheduler".to_string()
    } else if renewal_upcoming {
        "upcoming".to_string()
    } else {
        "scheduled".to_string()
    }
}

fn user_subscription_expiration_policy(billing_interval: &str, trial_days: i32) -> Value {
    json!({
        "billing_interval": billing_interval,
        "trial_days": trial_days,
        "grant_expires_with_period": billing_interval != "one_time",
        "scheduler_status": "pending_scheduler",
    })
}

fn user_subscription_next_action(status: &str) -> &'static str {
    match status {
        "trialing" | "active" | "renewed" | "resumed" => {
            "当前订阅仅作为安全 readback 展示；续费和额度发放等待 scheduler 接入。"
        }
        "created" | "payment_failed" => {
            "订阅仍处于支付或确认阶段；真实商户未连接，只能展示 pending 状态。"
        }
        "cancelled" | "expired" | "terminated" => {
            "订阅已结束；可查看套餐，但本地 demo 不会自动重新扣费或发放额度。"
        }
        _ => "查看可用套餐；真实支付和 renewal scheduler 尚未接入。",
    }
}

fn user_home_endpoint_summary() -> UserHomeEndpointSummary {
    let configured = std::env::var("AI_GATEWAY_PUBLIC_BASE_URL")
        .or_else(|_| std::env::var("GATEWAY_PUBLIC_BASE_URL"))
        .or_else(|_| std::env::var("VITE_GATEWAY_BASE_URL"))
        .ok()
        .and_then(|value| {
            let trimmed = value.trim().trim_end_matches('/').to_string();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed)
            }
        });
    let base_url = configured
        .clone()
        .unwrap_or_else(|| "http://localhost:8080".to_string());

    UserHomeEndpointSummary {
        models_url: format!("{base_url}/v1/models"),
        chat_completions_url: format!("{base_url}/v1/chat/completions"),
        openai_base_url: format!("{base_url}/v1"),
        base_url,
        source: if configured.is_some() {
            "runtime_config"
        } else {
            "local_fallback"
        },
        config_needed: configured.is_none(),
    }
}

async fn user_developer_quickstart_key_status(
    state: &ControlPlaneState,
    session: &UserSession,
) -> Result<UserDeveloperQuickstartKeyStatus, AdminError> {
    let row = sqlx::query(
        r#"
        select
          count(*)::bigint as total_keys,
          count(*) filter (where status = 'active')::bigint as active_keys,
          count(*) filter (where status = 'disabled')::bigint as disabled_keys,
          count(*) filter (where status = 'expired')::bigint as expired_keys,
          count(*) filter (where status in ('deleted', 'revoked'))::bigint as deleted_keys
        from virtual_keys
        where tenant_id = $1
          and project_id = $2
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.project_id)
    .fetch_one(state.db())
    .await
    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
    let latest_row = sqlx::query(
        r#"
        select
          id,
          name,
          key_prefix,
          status,
          default_profile_id,
          last_used_at::text as last_used_at,
          created_at::text as created_at
        from virtual_keys
        where tenant_id = $1
          and project_id = $2
        order by created_at desc, id desc
        limit 1
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.project_id)
    .fetch_optional(state.db())
    .await
    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;

    let total_keys = row
        .try_get("total_keys")
        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
    let active_keys = row
        .try_get("active_keys")
        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
    let disabled_keys = row
        .try_get("disabled_keys")
        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
    let expired_keys = row
        .try_get("expired_keys")
        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
    let deleted_keys = row
        .try_get("deleted_keys")
        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
    let latest_key = latest_row
        .map(
            |row| -> Result<UserDeveloperQuickstartLatestKey, AdminError> {
                Ok(UserDeveloperQuickstartLatestKey {
                    id: row
                        .try_get("id")
                        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
                    name: row
                        .try_get("name")
                        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
                    key_prefix: row
                        .try_get("key_prefix")
                        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
                    status: row
                        .try_get("status")
                        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
                    default_profile_id: row
                        .try_get("default_profile_id")
                        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
                    last_used_at: row
                        .try_get("last_used_at")
                        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
                    created_at: row
                        .try_get("created_at")
                        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
                })
            },
        )
        .transpose()?;

    Ok(UserDeveloperQuickstartKeyStatus {
        total_keys,
        active_keys,
        disabled_keys,
        expired_keys,
        deleted_keys,
        current_status: if active_keys > 0 {
            "active"
        } else if total_keys > 0 {
            "attention"
        } else {
            "missing"
        },
        latest_key,
        raw_api_key_returned: false,
        secret_hash_returned: false,
    })
}

async fn user_developer_quickstart_mock_readiness(
    state: &ControlPlaneState,
    session: &UserSession,
    routable_model_count: i64,
    active_key_count: i64,
) -> Result<Vec<UserDeveloperQuickstartEndpointReadiness>, AdminError> {
    let rows = sqlx::query(
        r#"
        select
          case
            when coalesce(route_decision_snapshot->>'endpoint', '') in ('openai_responses', 'responses')
              or coalesce(inbound_protocol, '') = 'openai_responses'
              then 'openai_responses'
            when coalesce(route_decision_snapshot->>'endpoint', '') in ('openai_embeddings', 'embeddings')
              or coalesce(inbound_protocol, '') = 'openai_embeddings'
              then 'openai_embeddings'
            else 'openai_chat'
          end as endpoint,
          count(*) filter (where status in ('succeeded', 'success', 'completed') or coalesce(http_status between 200 and 299, false))::bigint as success_count
        from request_logs
        where tenant_id = $1
          and project_id = $2
          and created_at >= now() - interval '7 days'
        group by 1
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.project_id)
    .fetch_all(state.db())
    .await
    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
    let mut chat_success_count = 0;
    let mut responses_success_count = 0;
    let mut embeddings_success_count = 0;
    for row in rows {
        let endpoint: String = row
            .try_get("endpoint")
            .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
        let success_count: i64 = row
            .try_get("success_count")
            .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
        match endpoint.as_str() {
            "openai_responses" => responses_success_count = success_count,
            "openai_embeddings" => embeddings_success_count = success_count,
            _ => chat_success_count += success_count,
        }
    }

    let route_ready = routable_model_count > 0 && active_key_count > 0;
    Ok(vec![
        user_developer_quickstart_endpoint_readiness(
            "mock_chat",
            "POST /v1/chat/completions",
            route_ready,
            chat_success_count,
        ),
        user_developer_quickstart_endpoint_readiness(
            "mock_responses",
            "POST /v1/responses",
            route_ready,
            responses_success_count,
        ),
        user_developer_quickstart_endpoint_readiness(
            "mock_embeddings",
            "POST /v1/embeddings",
            route_ready,
            embeddings_success_count,
        ),
    ])
}

fn user_developer_quickstart_endpoint_readiness(
    endpoint: &'static str,
    path: &'static str,
    route_ready: bool,
    recent_success_count: i64,
) -> UserDeveloperQuickstartEndpointReadiness {
    UserDeveloperQuickstartEndpointReadiness {
        endpoint,
        path,
        status: if recent_success_count > 0 {
            "recent-success"
        } else if route_ready {
            "ready-to-try"
        } else {
            "config-needed"
        },
        route_ready,
        recent_success_count,
        required: vec!["active_user_key", "routable_model", "billing_balance"],
        next_action: if recent_success_count > 0 {
            "Open recent request logs and verify status, cost, and token metadata."
        } else if route_ready {
            "Run a mock request through the gateway with a user key, then refresh this readback."
        } else {
            "Create an active user key and make at least one model routable before calling the gateway."
        },
    }
}

fn user_developer_quickstart_next_actions(
    key_status: &UserDeveloperQuickstartKeyStatus,
    models: &UserHomeModelsSummary,
) -> Vec<&'static str> {
    let mut actions = Vec::new();
    if key_status.active_keys == 0 {
        actions.push("Create a user virtual key and store the one-time secret outside the UI.");
    }
    if models.routable_count == 0 {
        actions.push("Ask an admin to enable at least one model route for this project/profile.");
    }
    actions.push("Use the base URL and a routable model from this readback for chat, responses, or embeddings.");
    actions.push("After a request, check recent request ids and request logs for metadata-only usage/cost readback.");
    actions
}

async fn user_developer_distribution_guardrails(
    state: &ControlPlaneState,
    session: &UserSession,
) -> Result<UserDeveloperDistributionGuardrails, AdminError> {
    let row = sqlx::query(
        r#"
        select
          (select count(*)::bigint
             from virtual_keys vk
            where vk.tenant_id = $1
              and vk.project_id = $2
              and vk.status = 'active'
              and vk.deleted_at is null) as active_virtual_key_count,
          (select count(*)::bigint
             from api_key_profiles p
            where p.tenant_id = $1
              and p.project_id = $2
              and p.status = 'active'
              and p.deleted_at is null) as active_profile_count,
          (select count(*)::bigint
             from virtual_keys vk
            where vk.tenant_id = $1
              and vk.project_id = $2
              and vk.deleted_at is null
              and vk.rate_limit_policy is not null
              and vk.rate_limit_policy <> '{}'::jsonb) as rate_limit_policy_present_count,
          (select count(*)::bigint
             from virtual_keys vk
            where vk.tenant_id = $1
              and vk.project_id = $2
              and vk.deleted_at is null
              and vk.budget_policy is not null
              and vk.budget_policy <> '{}'::jsonb) as budget_policy_present_count,
          (select count(*)::bigint
             from price_versions pv
            where pv.tenant_id = $1
              and pv.status = 'active') as active_price_version_count,
          (select count(*)::bigint
             from provider_keys pk
            join channels c on c.tenant_id = pk.tenant_id
              and c.id = pk.channel_id
              and c.deleted_at is null
            where pk.tenant_id = $1
              and pk.deleted_at is null
              and (
                coalesce((pk.metadata->>'rpm_limit'), '') <> ''
                or coalesce((pk.metadata->>'tpm_limit'), '') <> ''
                or coalesce((pk.metadata->>'concurrency_limit'), '') <> ''
              )) as provider_key_limit_guardrail_count
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.project_id)
    .fetch_one(state.db())
    .await
    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;

    let active_virtual_key_count: i64 = row
        .try_get("active_virtual_key_count")
        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
    let active_profile_count: i64 = row
        .try_get("active_profile_count")
        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
    let rate_limit_policy_present_count: i64 = row
        .try_get("rate_limit_policy_present_count")
        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
    let budget_policy_present_count: i64 = row
        .try_get("budget_policy_present_count")
        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
    let active_price_version_count: i64 = row
        .try_get("active_price_version_count")
        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
    let provider_key_limit_guardrail_count: i64 = row
        .try_get("provider_key_limit_guardrail_count")
        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
    let guardrails_present = rate_limit_policy_present_count > 0
        || budget_policy_present_count > 0
        || active_price_version_count > 0
        || provider_key_limit_guardrail_count > 0;

    Ok(UserDeveloperDistributionGuardrails {
        schema: "developer_distribution_guardrails_readback.v1",
        status: if active_virtual_key_count > 0 && active_profile_count > 0 && guardrails_present {
            "ready"
        } else if guardrails_present {
            "attention"
        } else {
            "blocked"
        },
        active_virtual_key_count,
        active_profile_count,
        rate_limit_policy_present_count,
        budget_policy_present_count,
        active_price_version_count,
        provider_key_limit_guardrail_count,
        guardrails_present,
        raw_policy_payload_returned: false,
        provider_key_returned: false,
        safe_next_action: if guardrails_present {
            "Review quota, rate, budget, and pricing markers before increasing developer distribution scope."
        } else {
            "Add at least one quota, rate, budget, pricing, or provider-key limit guardrail before handoff."
        },
    })
}

fn user_developer_distribution_safe_next_action(
    endpoint_readiness: &[UserDeveloperQuickstartEndpointReadiness],
    models: &UserHomeModelsSummary,
    guardrails: &UserDeveloperDistributionGuardrails,
    key_status: &UserDeveloperQuickstartKeyStatus,
) -> &'static str {
    if key_status.active_keys == 0 {
        return "Create a user virtual key and hand off only the one-time API key secret out of band.";
    }
    if models.routable_count == 0 {
        return "Enable at least one model route that the developer profile can see.";
    }
    if !guardrails.guardrails_present {
        return "Add quota, rate, budget, or pricing guardrails before expanding developer distribution.";
    }
    if endpoint_readiness
        .iter()
        .any(|readiness| !readiness.route_ready)
    {
        return "Confirm chat, responses, and embeddings endpoint routes before developer handoff.";
    }
    "Hand off the base URL, visible model names, voucher/key route references, and guardrail status without raw secrets."
}

async fn user_security_login_activity(
    state: &ControlPlaneState,
    session: &UserSession,
    window_days: i64,
) -> Result<Value, AdminError> {
    let row = sqlx::query(
        r#"
        select
          count(*)::bigint as session_count,
          count(*) filter (where status = 'active' and revoked_at is null and expires_at > now())::bigint as active_session_count,
          max(created_at)::text as last_login_at,
          max(last_seen_at)::text as last_seen_at
        from user_sessions
        where tenant_id = $1
          and user_id = $2
          and created_at >= now() - ($3::int * interval '1 day')
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.id)
    .bind(window_days as i32)
    .fetch_one(state.db())
    .await
    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;

    let samples = sqlx::query(
        r#"
        select id, status, created_at::text as created_at, last_seen_at::text as last_seen_at, expires_at::text as expires_at
        from user_sessions
        where tenant_id = $1
          and user_id = $2
        order by created_at desc, id desc
        limit 3
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.id)
    .fetch_all(state.db())
    .await
    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?
    .into_iter()
    .map(|row| {
        Ok(json!({
            "session_id": row.try_get::<Uuid, _>("id")?,
            "status": row.try_get::<String, _>("status")?,
            "created_at": row.try_get::<String, _>("created_at")?,
            "last_seen_at": row.try_get::<Option<String>, _>("last_seen_at")?,
            "expires_at": row.try_get::<String, _>("expires_at")?,
            "session_token_returned": false,
            "token_hash_returned": false,
        }))
    })
    .collect::<Result<Vec<_>, sqlx::Error>>()
    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;

    Ok(json!({
        "source": "user_sessions",
        "status": "available",
        "session_count": row.try_get::<i64, _>("session_count").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        "active_session_count": row.try_get::<i64, _>("active_session_count").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        "last_login_at": row.try_get::<Option<String>, _>("last_login_at").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        "last_seen_at": row.try_get::<Option<String>, _>("last_seen_at").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        "samples": samples,
        "safe_count_only": true,
    }))
}

fn user_security_password_email_activity(session: &UserSession) -> Value {
    json!({
        "source": "auth_productization_placeholders",
        "status": "productization_placeholder",
        "password_reset_request_endpoint": "POST /auth/password-reset/request",
        "email_verification_request_endpoint": "POST /auth/email-verification/request",
        "counts_available": false,
        "safe_samples": [
            {
                "event": "password_reset.request",
                "status": "mail_delivery_config_needed",
                "account_disclosure": "none",
                "raw_email_token_returned": false
            },
            {
                "event": "email_verification.request",
                "status": "mail_delivery_config_needed",
                "user_id": session.user.id,
                "raw_email_token_returned": false
            }
        ],
        "next_action": "Wire mail delivery and a bounded audit/event marker before claiming request counts.",
        "password_hash_returned": false,
    })
}

async fn user_security_api_key_activity(
    state: &ControlPlaneState,
    session: &UserSession,
    window_days: i64,
) -> Result<Value, AdminError> {
    let row = sqlx::query(
        r#"
        select
          count(*)::bigint as audit_count,
          count(*) filter (where action = 'virtual_key.create')::bigint as created_count,
          count(*) filter (where action in ('virtual_key.disable', 'virtual_key.delete'))::bigint as disabled_or_deleted_count,
          max(created_at)::text as last_audit_at
        from audit_logs
        where tenant_id = $1
          and actor_user_id = $2
          and resource_type = 'virtual_key'
          and created_at >= now() - ($3::int * interval '1 day')
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.id)
    .bind(window_days as i32)
    .fetch_one(state.db())
    .await
    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;

    let key_status = user_developer_quickstart_key_status(state, session).await?;
    let samples = sqlx::query(
        r#"
        select id, action, resource_id, created_at::text as created_at
        from audit_logs
        where tenant_id = $1
          and actor_user_id = $2
          and resource_type = 'virtual_key'
        order by created_at desc, id desc
        limit 5
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.id)
    .fetch_all(state.db())
    .await
    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?
    .into_iter()
    .map(|row| {
        Ok(json!({
            "audit_log_id": row.try_get::<Uuid, _>("id")?,
            "action": row.try_get::<String, _>("action")?,
            "virtual_key_id": row.try_get::<Option<Uuid>, _>("resource_id")?,
            "created_at": row.try_get::<String, _>("created_at")?,
        }))
    })
    .collect::<Result<Vec<_>, sqlx::Error>>()
    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;

    Ok(json!({
        "source": "audit_logs_virtual_keys",
        "status": "available",
        "audit_count": row.try_get::<i64, _>("audit_count").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        "created_count": row.try_get::<i64, _>("created_count").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        "disabled_or_deleted_count": row.try_get::<i64, _>("disabled_or_deleted_count").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        "last_audit_at": row.try_get::<Option<String>, _>("last_audit_at").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        "key_counts": {
            "total_keys": key_status.total_keys,
            "active_keys": key_status.active_keys,
            "disabled_keys": key_status.disabled_keys,
            "expired_keys": key_status.expired_keys,
            "deleted_keys": key_status.deleted_keys,
        },
        "samples": samples,
        "api_key_secret_returned": false,
        "api_key_secret_hash_returned": false,
    }))
}

async fn user_security_balance_ledger_activity(
    state: &ControlPlaneState,
    session: &UserSession,
    window_days: i64,
) -> Result<Value, AdminError> {
    let row = sqlx::query(
        r#"
        select
          count(*)::bigint as ledger_entry_count,
          count(*) filter (where status = 'confirmed')::bigint as confirmed_count,
          count(*) filter (where entry_type in ('credit_grant', 'adjust'))::bigint as credit_or_adjust_count,
          count(*) filter (where entry_type in ('settle', 'reserve', 'refund'))::bigint as usage_or_refund_count,
          coalesce(sum(amount) filter (where status = 'confirmed'), 0)::text as confirmed_net_amount,
          coalesce(min(currency), 'USD') as currency,
          max(created_at)::text as last_ledger_at
        from ledger_entries
        where tenant_id = $1
          and project_id = $2
          and created_at >= now() - ($3::int * interval '1 day')
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.project_id)
    .bind(window_days as i32)
    .fetch_one(state.db())
    .await
    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;

    let samples = sqlx::query(
        r#"
        select id, wallet_id, request_id, virtual_key_id, entry_type, amount::text as amount, currency, status, created_at::text as created_at
        from ledger_entries
        where tenant_id = $1
          and project_id = $2
        order by created_at desc, id desc
        limit 5
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.project_id)
    .fetch_all(state.db())
    .await
    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?
    .into_iter()
    .map(|row| {
        Ok(json!({
            "ledger_entry_id": row.try_get::<Uuid, _>("id")?,
            "wallet_id": row.try_get::<Option<Uuid>, _>("wallet_id")?,
            "request_id": row.try_get::<Option<Uuid>, _>("request_id")?,
            "virtual_key_id": row.try_get::<Option<Uuid>, _>("virtual_key_id")?,
            "entry_type": row.try_get::<String, _>("entry_type")?,
            "amount": row.try_get::<String, _>("amount")?,
            "currency": row.try_get::<String, _>("currency")?,
            "status": row.try_get::<String, _>("status")?,
            "created_at": row.try_get::<String, _>("created_at")?,
        }))
    })
    .collect::<Result<Vec<_>, sqlx::Error>>()
    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;

    Ok(json!({
        "source": "ledger_entries_project_scope",
        "status": "available",
        "ledger_entry_count": row.try_get::<i64, _>("ledger_entry_count").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        "confirmed_count": row.try_get::<i64, _>("confirmed_count").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        "credit_or_adjust_count": row.try_get::<i64, _>("credit_or_adjust_count").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        "usage_or_refund_count": row.try_get::<i64, _>("usage_or_refund_count").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        "confirmed_net_amount": row.try_get::<String, _>("confirmed_net_amount").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        "currency": row.try_get::<String, _>("currency").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        "last_ledger_at": row.try_get::<Option<String>, _>("last_ledger_at").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        "samples": samples,
        "raw_ledger_metadata_returned": false,
        "raw_payload_returned": false,
    }))
}

async fn user_billing_history_recent_ledger_entries(
    state: &ControlPlaneState,
    session: &UserSession,
    window_days: i64,
) -> Result<Value, AdminError> {
    let row = sqlx::query(
        r#"
        select
          count(*)::bigint as entry_count,
          count(*) filter (where status = 'confirmed')::bigint as confirmed_count,
          coalesce(sum(amount) filter (where status = 'confirmed'), 0)::text as confirmed_net_amount,
          coalesce(min(currency), 'USD') as currency,
          max(created_at)::text as last_ledger_at
        from ledger_entries
        where tenant_id = $1
          and project_id = $2
          and created_at >= now() - ($3::int * interval '1 day')
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.project_id)
    .bind(window_days as i32)
    .fetch_one(state.db())
    .await
    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;

    let entries = sqlx::query(
        r#"
        select id, wallet_id, request_id, virtual_key_id, entry_type, amount::text as amount, currency, status, created_at::text as created_at
        from ledger_entries
        where tenant_id = $1
          and project_id = $2
        order by created_at desc, id desc
        limit 8
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.project_id)
    .fetch_all(state.db())
    .await
    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?
    .into_iter()
    .map(|row| {
        Ok(json!({
            "ledger_entry_id": row.try_get::<Uuid, _>("id")?,
            "wallet_id": row.try_get::<Option<Uuid>, _>("wallet_id")?,
            "request_id": row.try_get::<Option<Uuid>, _>("request_id")?,
            "virtual_key_id": row.try_get::<Option<Uuid>, _>("virtual_key_id")?,
            "entry_type": row.try_get::<String, _>("entry_type")?,
            "amount": row.try_get::<String, _>("amount")?,
            "currency": row.try_get::<String, _>("currency")?,
            "status": row.try_get::<String, _>("status")?,
            "created_at": row.try_get::<String, _>("created_at")?,
            "raw_metadata_returned": false,
        }))
    })
    .collect::<Result<Vec<_>, sqlx::Error>>()
    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;

    Ok(json!({
        "source": "ledger_entries_project_scope",
        "window_days": window_days,
        "entry_count": row.try_get::<i64, _>("entry_count").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        "confirmed_count": row.try_get::<i64, _>("confirmed_count").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        "confirmed_net_amount": row.try_get::<String, _>("confirmed_net_amount").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        "currency": row.try_get::<String, _>("currency").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        "last_ledger_at": row.try_get::<Option<String>, _>("last_ledger_at").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        "entries": entries,
        "raw_ledger_metadata_returned": false,
        "raw_payload_returned": false,
    }))
}

async fn user_billing_history_refs_presence(
    state: &ControlPlaneState,
    session: &UserSession,
    wallet_id: Uuid,
) -> Result<Value, AdminError> {
    let row = sqlx::query(
        r#"
        select
          (select count(*)::bigint from voucher_issuances where tenant_id = $1 and (project_id = $2 or wallet_id = $3)) as voucher_count,
          (select count(*)::bigint from voucher_redemptions where tenant_id = $1 and (project_id = $2 or wallet_id = $3)) as voucher_redemption_count,
          (select max(created_at)::text from voucher_redemptions where tenant_id = $1 and (project_id = $2 or wallet_id = $3)) as last_voucher_redemption_at,
          (select count(*)::bigint from payment_orders where tenant_id = $1 and (project_id = $2 or wallet_id = $3)) as order_count,
          (select count(*)::bigint from payment_orders where tenant_id = $1 and (project_id = $2 or wallet_id = $3) and status = 'paid') as paid_order_count,
          (select max(created_at)::text from payment_orders where tenant_id = $1 and (project_id = $2 or wallet_id = $3)) as last_order_at,
          (select count(*)::bigint from subscriptions where tenant_id = $1 and (project_id = $2 or wallet_id = $3)) as subscription_count,
          (select count(*)::bigint from subscriptions where tenant_id = $1 and (project_id = $2 or wallet_id = $3) and status in ('trialing', 'active', 'renewed', 'resumed')) as active_subscription_count,
          (select max(updated_at)::text from subscriptions where tenant_id = $1 and (project_id = $2 or wallet_id = $3)) as last_subscription_at
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.project_id)
    .bind(wallet_id)
    .fetch_one(state.db())
    .await
    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;

    let voucher_count: i64 = row
        .try_get("voucher_count")
        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
    let order_count: i64 = row
        .try_get("order_count")
        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
    let subscription_count: i64 = row
        .try_get("subscription_count")
        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;

    Ok(json!({
        "source": "voucher_order_subscription_project_or_wallet_scope",
        "voucher_refs_present": voucher_count > 0,
        "order_refs_present": order_count > 0,
        "subscription_refs_present": subscription_count > 0,
        "voucher": {
            "count": voucher_count,
            "redemption_count": row.try_get::<i64, _>("voucher_redemption_count").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
            "last_redemption_at": row.try_get::<Option<String>, _>("last_voucher_redemption_at").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
            "raw_voucher_code_returned": false,
            "voucher_code_hash_returned": false,
        },
        "order": {
            "count": order_count,
            "paid_count": row.try_get::<i64, _>("paid_order_count").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
            "last_order_at": row.try_get::<Option<String>, _>("last_order_at").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
            "raw_invoice_metadata_returned": false,
            "raw_payment_payload_returned": false,
        },
        "subscription": {
            "count": subscription_count,
            "active_count": row.try_get::<i64, _>("active_subscription_count").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
            "last_subscription_at": row.try_get::<Option<String>, _>("last_subscription_at").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
            "raw_invoice_metadata_returned": false,
        },
        "authorization_returned": false,
        "provider_key_returned": false,
        "raw_payload_returned": false,
    }))
}

fn user_billing_history_safe_next_action(
    ledger_recent_entries: &Value,
    request_usage_cost_rollup: &UserUsageTotals,
    refs_presence: &Value,
) -> &'static str {
    if request_usage_cost_rollup.request_count == 0 {
        return "Create or use an active virtual key, then make a bounded gateway request to populate usage and cost history.";
    }
    if ledger_recent_entries
        .get("entry_count")
        .and_then(Value::as_i64)
        .unwrap_or_default()
        == 0
    {
        return "Usage exists but no recent ledger entries were found; inspect billing settlement or run a small request after adding credit.";
    }
    if !refs_presence
        .get("voucher_refs_present")
        .and_then(Value::as_bool)
        .unwrap_or(false)
        && !refs_presence
            .get("order_refs_present")
            .and_then(Value::as_bool)
            .unwrap_or(false)
        && !refs_presence
            .get("subscription_refs_present")
            .and_then(Value::as_bool)
            .unwrap_or(false)
    {
        return "Ledger and usage history are present; redeem a voucher or create an order/subscription to show funding source refs.";
    }
    "Render balance, recent ledger entries, usage rollup, and funding refs from this compact readback."
}

fn user_security_activity_next_actions(
    login_activity: &Value,
    api_key_activity: &Value,
    balance_and_ledger_activity: &Value,
) -> Vec<&'static str> {
    let mut actions = Vec::new();
    if login_activity
        .get("active_session_count")
        .and_then(Value::as_i64)
        .unwrap_or_default()
        > 1
    {
        actions.push("Review active sessions and log out stale browser sessions.");
    }
    if api_key_activity
        .get("key_counts")
        .and_then(|value| value.get("active_keys"))
        .and_then(Value::as_i64)
        .unwrap_or_default()
        == 0
    {
        actions.push("Create an API key after confirming the project has a routable model.");
    }
    if balance_and_ledger_activity
        .get("ledger_entry_count")
        .and_then(Value::as_i64)
        .unwrap_or_default()
        == 0
    {
        actions.push(
            "Run a bounded request or apply credit so balance and ledger readback has activity.",
        );
    }
    actions.push("Configure mail delivery and bounded audit markers before claiming password reset or email verification counts.");
    actions
}

async fn user_team_project_access_summary(
    state: &ControlPlaneState,
    session: &UserSession,
) -> Result<Value, AdminError> {
    let row = sqlx::query(
        r#"
        select
          count(distinct vk.id) filter (where vk.deleted_at is null and vk.created_by_user_id = $3)::bigint as user_key_count,
          count(distinct vk.id) filter (where vk.status = 'active' and vk.deleted_at is null and vk.created_by_user_id = $3)::bigint as user_active_key_count,
          count(distinct akp.id) filter (where akp.status = 'active' and akp.deleted_at is null)::bigint as active_profile_count
        from projects p
        left join virtual_keys vk on vk.tenant_id = p.tenant_id and vk.project_id = p.id
        left join api_key_profiles akp on akp.tenant_id = p.tenant_id and akp.project_id = p.id
        where p.tenant_id = $1 and p.id = $2 and p.deleted_at is null
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.project_id)
    .bind(session.user.id)
    .fetch_one(state.db())
    .await
    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;

    let user_active_key_count: i64 = row
        .try_get("user_active_key_count")
        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
    let active_profile_count: i64 = row
        .try_get("active_profile_count")
        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
    Ok(json!({
        "user_key_count": row.try_get::<i64, _>("user_key_count").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        "user_active_key_count": user_active_key_count,
        "key_access_present": user_active_key_count > 0,
        "active_profile_count": active_profile_count,
        "profile_access_present": active_profile_count > 0,
        "source": "virtual_keys_created_by_user/api_key_profiles",
        "secret_returned": false,
        "raw_policy_returned": false
    }))
}

async fn user_team_recent_usage_summary(
    state: &ControlPlaneState,
    session: &UserSession,
) -> Result<Value, AdminError> {
    let row = sqlx::query(
        r#"
        select
          count(*)::bigint as request_count,
          count(*) filter (where status = 'succeeded')::bigint as succeeded_count,
          count(*) filter (where status in ('failed', 'rejected', 'cancelled'))::bigint as failed_count,
          coalesce(sum(final_cost), 0)::text as final_cost,
          bool_or(final_cost is not null) as cost_present,
          max(created_at)::text as last_request_at
        from request_logs
        where tenant_id = $1
          and project_id = $2
          and created_at >= now() - interval '30 days'
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.project_id)
    .fetch_one(state.db())
    .await
    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;

    Ok(json!({
        "window_days": 30,
        "request_count": row.try_get::<i64, _>("request_count").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        "succeeded_count": row.try_get::<i64, _>("succeeded_count").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        "failed_count": row.try_get::<i64, _>("failed_count").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        "cost_present": row.try_get::<Option<bool>, _>("cost_present").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?.unwrap_or(false),
        "final_cost": row.try_get::<String, _>("final_cost").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        "last_request_at": row.try_get::<Option<String>, _>("last_request_at").map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        "source": "request_logs_project_scope",
        "payload_returned": false
    }))
}

async fn user_team_member_samples(
    state: &ControlPlaneState,
    session: &UserSession,
) -> Result<Vec<Value>, AdminError> {
    let rows = sqlx::query(
        r#"
        select pm.user_id, pm.role, u.status, pm.created_at::text as membership_created_at
        from project_members pm
        join users u on u.tenant_id = pm.tenant_id and u.id = pm.user_id and u.deleted_at is null
        where pm.tenant_id = $1 and pm.project_id = $2
        order by
          case when pm.user_id = $3 then 0 else 1 end,
          case pm.role when 'owner' then 0 when 'admin' then 1 when 'ops' then 2 when 'billing' then 3 when 'developer' then 4 else 5 end,
          pm.created_at,
          pm.user_id
        limit 25
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.project_id)
    .bind(session.user.id)
    .fetch_all(state.db())
    .await
    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;

    rows.into_iter()
        .map(|row| {
            Ok(json!({
                "user_id": row.try_get::<Uuid, _>("user_id")?,
                "role": row.try_get::<String, _>("role")?,
                "status": row.try_get::<String, _>("status")?,
                "membership_source": "project_members",
                "membership_created_at": row.try_get::<String, _>("membership_created_at")?,
                "raw_email_returned": false,
                "secret_returned": false,
            }))
        })
        .collect::<Result<Vec<_>, sqlx::Error>>()
        .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))
}

fn user_team_safe_next_action(project_access: &Value, recent_usage: &Value) -> &'static str {
    let active_profile_count = project_access
        .get("active_profile_count")
        .and_then(Value::as_i64)
        .unwrap_or_default();
    let active_key_count = project_access
        .get("user_active_key_count")
        .and_then(Value::as_i64)
        .unwrap_or_default();
    let request_count = recent_usage
        .get("request_count")
        .and_then(Value::as_i64)
        .unwrap_or_default();

    if active_profile_count == 0 {
        "ask_admin_to_enable_project_profile"
    } else if active_key_count == 0 {
        "create_user_api_key"
    } else if request_count == 0 {
        "send_first_gateway_request"
    } else {
        "monitor_usage"
    }
}

async fn user_home_models_summary(
    state: &ControlPlaneState,
    session: &UserSession,
) -> Result<UserHomeModelsSummary, AdminError> {
    let rows = sqlx::query(
        r#"
        with user_profile as (
          select id, allowed_models, denied_models
          from api_key_profiles
          where tenant_id = $1
            and project_id = $2
            and status = 'active'
            and deleted_at is null
          order by created_at asc, id asc
          limit 1
        ),
        visible_models as (
          select
            m.id,
            m.model_key,
            m.display_name,
            count(distinct c.id) filter (
              where ma.status = 'enabled'
                and c.status = 'enabled'
                and p.status = 'enabled'
            ) as routable_channel_count,
            min(c.protocol_mode) filter (
              where ma.status = 'enabled'
                and c.status = 'enabled'
                and p.status = 'enabled'
            ) as primary_protocol
          from user_profile up
          join canonical_models m on m.tenant_id = $1
            and m.status = 'active'
            and m.visibility in ('public', 'internal')
            and m.deleted_at is null
            and (
              jsonb_array_length(up.allowed_models) = 0
              or up.allowed_models ? m.model_key
            )
            and not (up.denied_models ? m.model_key)
          left join model_associations ma on ma.tenant_id = m.tenant_id
            and ma.canonical_model_id = m.id
            and ma.status = 'enabled'
            and ma.deleted_at is null
          left join channels c on c.tenant_id = ma.tenant_id
            and c.id = ma.channel_id
            and c.deleted_at is null
          left join providers p on p.tenant_id = c.tenant_id
            and p.id = c.provider_id
            and p.deleted_at is null
          group by m.id, m.model_key, m.display_name
        )
        select
          id,
          model_key,
          display_name,
          routable_channel_count,
          primary_protocol,
          count(*) over() as total_visible,
          count(*) filter (where routable_channel_count > 0) over() as routable_count
        from visible_models
        order by routable_channel_count desc, model_key asc
        limit 8
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.project_id)
    .fetch_all(state.db())
    .await
    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;

    let mut total_visible = 0;
    let mut routable_count = 0;
    let mut sample = Vec::with_capacity(rows.len());
    for row in rows {
        total_visible = row
            .try_get("total_visible")
            .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
        routable_count = row
            .try_get("routable_count")
            .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
        let routable_channel_count: i64 = row
            .try_get("routable_channel_count")
            .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
        sample.push(UserHomeModelSummary {
            id: row
                .try_get("id")
                .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
            model: row
                .try_get("model_key")
                .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
            display_name: row
                .try_get("display_name")
                .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
            routable: routable_channel_count > 0,
            routable_channel_count,
            primary_protocol: row
                .try_get("primary_protocol")
                .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
            route_status: if routable_channel_count > 0 {
                "routable"
            } else {
                "config-needed"
            },
        });
    }

    Ok(UserHomeModelsSummary {
        total_visible,
        routable_count,
        sample,
    })
}

async fn user_model_availability_readback(
    state: &ControlPlaneState,
    session: &UserSession,
) -> Result<UserModelAvailabilityReadback, AdminError> {
    let visible_models = user_home_models_summary(state, session).await?;
    let profile_row = sqlx::query(
        r#"
        with selected_profile as (
          select id, status, allowed_models, denied_models
          from api_key_profiles
          where tenant_id = $1
            and project_id = $2
            and status = 'active'
            and deleted_at is null
          order by created_at asc, id asc
          limit 1
        ),
        model_scope as (
          select m.model_key
          from canonical_models m
          where m.tenant_id = $1
            and m.status = 'active'
            and m.visibility in ('public', 'internal')
            and m.deleted_at is null
        ),
        blocked_explicit as (
          select ms.model_key
          from selected_profile sp
          join model_scope ms on coalesce(sp.denied_models, '[]'::jsonb) ? ms.model_key
          order by ms.model_key
          limit 8
        ),
        blocked_allowed_filter as (
          select ms.model_key
          from selected_profile sp
          join model_scope ms on true
          where jsonb_array_length(coalesce(sp.allowed_models, '[]'::jsonb)) > 0
            and not (coalesce(sp.allowed_models, '[]'::jsonb) ? ms.model_key)
            and not (coalesce(sp.denied_models, '[]'::jsonb) ? ms.model_key)
          order by ms.model_key
          limit 8
        )
        select
          sp.id as profile_id,
          sp.status as profile_status,
          (select count(*)::bigint
             from model_scope ms
            where coalesce(sp.denied_models, '[]'::jsonb) ? ms.model_key) as explicit_denied_count,
          (select count(*)::bigint
             from model_scope ms
            where jsonb_array_length(coalesce(sp.allowed_models, '[]'::jsonb)) > 0
              and not (coalesce(sp.allowed_models, '[]'::jsonb) ? ms.model_key)
              and not (coalesce(sp.denied_models, '[]'::jsonb) ? ms.model_key)) as allowed_filter_hidden_count,
          coalesce((select array_agg(model_key) from blocked_explicit), array[]::text[]) as explicit_denied_sample,
          coalesce((select array_agg(model_key) from blocked_allowed_filter), array[]::text[]) as allowed_filter_hidden_sample
        from selected_profile sp
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.project_id)
    .fetch_optional(state.db())
    .await
    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;

    let (
        profile_id,
        profile_status,
        explicit_denied_count,
        allowed_filter_hidden_count,
        explicit_denied_sample,
        allowed_filter_hidden_sample,
    ) = if let Some(row) = profile_row {
        (
            row.try_get::<Option<Uuid>, _>("profile_id")
                .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
            row.try_get::<Option<String>, _>("profile_status")
                .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
            row.try_get::<i64, _>("explicit_denied_count")
                .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
            row.try_get::<i64, _>("allowed_filter_hidden_count")
                .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
            row.try_get::<Vec<String>, _>("explicit_denied_sample")
                .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
            row.try_get::<Vec<String>, _>("allowed_filter_hidden_sample")
                .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        )
    } else {
        (None, None, 0, 0, Vec::new(), Vec::new())
    };

    let unroutable_visible_sample = visible_models
        .sample
        .iter()
        .filter(|model| !model.routable)
        .map(|model| model.model.clone())
        .collect::<Vec<_>>();
    let unroutable_visible_count = visible_models.total_visible - visible_models.routable_count;
    let mut reasons = Vec::new();
    if explicit_denied_count > 0 {
        reasons.push(UserModelAvailabilityBlockedReason {
            reason: "profile_denied_model",
            count: explicit_denied_count,
            sample_models: explicit_denied_sample,
        });
    }
    if allowed_filter_hidden_count > 0 {
        reasons.push(UserModelAvailabilityBlockedReason {
            reason: "profile_allowed_models_filter",
            count: allowed_filter_hidden_count,
            sample_models: allowed_filter_hidden_sample,
        });
    }
    if unroutable_visible_count > 0 {
        reasons.push(UserModelAvailabilityBlockedReason {
            reason: "visible_but_no_enabled_route",
            count: unroutable_visible_count,
            sample_models: unroutable_visible_sample,
        });
    }

    let protocol_capability_summary =
        user_model_protocol_capability_summary(state, session).await?;
    let guardrails = user_model_availability_guardrails(state, session).await?;
    let safe_next_action = user_model_availability_safe_next_action(
        &visible_models,
        &guardrails,
        profile_id.is_some(),
    );
    let virtual_key_id = user_latest_virtual_key_id(state, session).await?;

    Ok(UserModelAvailabilityReadback {
        schema: "model_availability_readback.v1",
        scope: UserModelAvailabilityScope {
            project_id: session.user.project_id,
            virtual_key_id,
            api_key_profile_id: profile_id,
            profile_status,
            source: "user_session_project_profile_virtual_key_scope",
        },
        visible_models,
        blocked_models: UserModelAvailabilityBlockedSummary {
            total_blocked: explicit_denied_count
                + allowed_filter_hidden_count
                + unroutable_visible_count,
            explicit_denied_count,
            allowed_filter_hidden_count,
            unroutable_visible_count,
            reasons,
        },
        protocol_capability_summary,
        quota_rate_budget_guardrails: guardrails,
        safe_next_action,
        handoff: UserModelAvailabilityHandoff {
            contract: "GET /user/developer-quickstart-readback or GET /user/models meta.model_availability_readback",
            source: "profile_filtered_model_and_guardrail_counts",
            omitted_fields: vec![
                "raw_api_key_secret",
                "api_key_secret_hash",
                "Authorization",
                "provider_key",
                "provider_key_id",
                "raw_route_policy",
                "raw_rate_limit_policy",
                "raw_budget_policy",
                "raw_request_payload",
                "raw_response_payload",
            ],
            raw_api_key_returned: false,
            api_key_secret_hash_returned: false,
            authorization_returned: false,
            provider_key_returned: false,
            raw_route_policy_returned: false,
            raw_payload_returned: false,
        },
        secret_safe: true,
    })
}

async fn user_model_protocol_capability_summary(
    state: &ControlPlaneState,
    session: &UserSession,
) -> Result<Vec<UserModelProtocolCapabilitySummary>, AdminError> {
    let rows = sqlx::query(
        r#"
        with user_profile as (
          select id, allowed_models, denied_models
          from api_key_profiles
          where tenant_id = $1
            and project_id = $2
            and status = 'active'
            and deleted_at is null
          order by created_at asc, id asc
          limit 1
        ),
        visible_models as (
          select m.id
          from user_profile up
          join canonical_models m on m.tenant_id = $1
            and m.status = 'active'
            and m.visibility in ('public', 'internal')
            and m.deleted_at is null
            and (
              jsonb_array_length(coalesce(up.allowed_models, '[]'::jsonb)) = 0
              or coalesce(up.allowed_models, '[]'::jsonb) ? m.model_key
            )
            and not (coalesce(up.denied_models, '[]'::jsonb) ? m.model_key)
        )
        select
          coalesce(c.protocol_mode, 'unknown') as protocol_mode,
          count(distinct vm.id)::bigint as visible_model_count,
          count(distinct vm.id) filter (
            where ma.status = 'enabled'
              and c.status = 'enabled'
              and p.status = 'enabled'
          )::bigint as routable_model_count
        from visible_models vm
        left join model_associations ma on ma.tenant_id = $1
          and ma.canonical_model_id = vm.id
          and ma.deleted_at is null
        left join channels c on c.tenant_id = ma.tenant_id
          and c.id = ma.channel_id
          and c.deleted_at is null
        left join providers p on p.tenant_id = c.tenant_id
          and p.id = c.provider_id
          and p.deleted_at is null
        group by coalesce(c.protocol_mode, 'unknown')
        order by protocol_mode
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.project_id)
    .fetch_all(state.db())
    .await
    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;

    rows.into_iter()
        .map(|row| {
            let routable_model_count = row
                .try_get::<i64, _>("routable_model_count")
                .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;
            Ok(UserModelProtocolCapabilitySummary {
                protocol_mode: row
                    .try_get("protocol_mode")
                    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
                visible_model_count: row
                    .try_get("visible_model_count")
                    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
                routable_model_count,
                status: if routable_model_count > 0 {
                    "routable"
                } else {
                    "config-needed"
                },
            })
        })
        .collect()
}

async fn user_model_availability_guardrails(
    state: &ControlPlaneState,
    session: &UserSession,
) -> Result<UserModelAvailabilityGuardrails, AdminError> {
    let guardrails = user_developer_distribution_guardrails(state, session).await?;
    Ok(UserModelAvailabilityGuardrails {
        active_virtual_key_count: guardrails.active_virtual_key_count,
        active_profile_count: guardrails.active_profile_count,
        rate_limit_policy_present: guardrails.rate_limit_policy_present_count > 0,
        rate_limit_policy_present_count: guardrails.rate_limit_policy_present_count,
        budget_policy_present: guardrails.budget_policy_present_count > 0,
        budget_policy_present_count: guardrails.budget_policy_present_count,
        pricing_guardrail_present: guardrails.active_price_version_count > 0,
        active_price_version_count: guardrails.active_price_version_count,
        raw_policy_payload_returned: false,
        provider_key_returned: false,
    })
}

async fn user_latest_virtual_key_id(
    state: &ControlPlaneState,
    session: &UserSession,
) -> Result<Option<Uuid>, AdminError> {
    let row = sqlx::query(
        r#"
        select id
        from virtual_keys
        where tenant_id = $1
          and project_id = $2
          and deleted_at is null
        order by
          case when status = 'active' then 0 else 1 end,
          created_at desc,
          id desc
        limit 1
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.project_id)
    .fetch_optional(state.db())
    .await
    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;

    row.map(|row| {
        row.try_get("id")
            .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))
    })
    .transpose()
}

fn user_model_availability_safe_next_action(
    visible_models: &UserHomeModelsSummary,
    guardrails: &UserModelAvailabilityGuardrails,
    profile_present: bool,
) -> &'static str {
    if !profile_present {
        "Ask an admin to create an active API key profile for this project."
    } else if guardrails.active_virtual_key_count == 0 {
        "Create a user virtual key before calling the gateway."
    } else if visible_models.total_visible == 0 {
        "Ask an admin to allow at least one model for this profile."
    } else if visible_models.routable_count == 0 {
        "Enable a provider/channel/model association for at least one visible model."
    } else if !guardrails.rate_limit_policy_present || !guardrails.budget_policy_present {
        "Add rate and budget guardrails before wider developer handoff."
    } else {
        "Use a routable visible model from this readback and inspect request logs after the next call."
    }
}

async fn user_home_recent_usage(
    state: &ControlPlaneState,
    session: &UserSession,
    window_days: i64,
) -> Result<UserUsageTotals, AdminError> {
    let row = sqlx::query(
        r#"
        select
          count(*)::bigint as request_count,
          count(*) filter (where status in ('succeeded', 'success', 'completed') or coalesce(http_status between 200 and 299, false))::bigint as success_count,
          count(*) filter (where not (status in ('succeeded', 'success', 'completed') or coalesce(http_status between 200 and 299, false)))::bigint as failed_count,
          count(*) filter (where retryable is true and not (status in ('succeeded', 'success', 'completed') or coalesce(http_status between 200 and 299, false)))::bigint as retryable_failed_count,
          coalesce(sum(input_tokens), 0)::bigint as input_tokens,
          coalesce(sum(output_tokens), 0)::bigint as output_tokens,
          coalesce(sum(input_tokens + output_tokens), 0)::bigint as total_tokens,
          coalesce(sum(final_cost), 0)::text as total_cost,
          coalesce(min(currency), 'USD') as currency,
          round(avg(latency_ms))::bigint as avg_latency_ms
        from request_logs
        where tenant_id = $1
          and project_id = $2
          and created_at >= now() - ($3::int * interval '1 day')
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.project_id)
    .bind(window_days as i32)
    .fetch_one(state.db())
    .await
    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;

    user_usage_totals(row).map_err(|_| AdminError::bad_request("usage summary unavailable"))
}

async fn user_home_recent_requests(
    state: &ControlPlaneState,
    session: &UserSession,
    limit: i64,
) -> Result<UserHomeRecentRequestsSummary, AdminError> {
    let rows = sqlx::query(
        r#"
        select
          id, tenant_id, project_id, virtual_key_id,
          trace_id, thread_id, client_request_id, inbound_protocol, outbound_protocol,
          protocol_mode, requested_model, upstream_model,
          status, http_status, error_owner, error_code, retryable, partial_sent,
          stream_end_reason, input_tokens, output_tokens, final_cost::text as final_cost,
          currency, latency_ms, ttft_ms,
          redaction_status, request_body_hash, response_body_hash,
          route_decision_snapshot,
          created_at::text as created_at, completed_at::text as completed_at
        from request_logs
        where tenant_id = $1
          and project_id = $2
        order by created_at desc, id desc
        limit $3
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.project_id)
    .bind(limit)
    .fetch_all(state.db())
    .await
    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;

    let mut request_ids = Vec::with_capacity(rows.len());
    let mut requests = Vec::with_capacity(rows.len());
    for row in rows {
        request_ids.push(
            row.try_get("id")
                .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        );
        requests.push(
            user_request_log_response(row)
                .map_err(|_| AdminError::bad_request("request summary unavailable"))?,
        );
    }

    Ok(UserHomeRecentRequestsSummary {
        count: request_ids.len() as i64,
        request_ids,
        requests,
    })
}

async fn list_user_models(
    State(state): State<Arc<ControlPlaneState>>,
    session: UserSession,
) -> Result<Response, AuthError> {
    let rows = sqlx::query(
        r#"
        with user_profile as (
          select
            id,
            allowed_models,
            denied_models,
            default_price_book_id
          from api_key_profiles
          where tenant_id = $1
            and project_id = $2
            and status = 'active'
            and deleted_at is null
          order by created_at asc, id asc
          limit 1
        )
        select
          m.id,
          m.model_key,
          m.display_name,
          m.family,
          m.visibility,
          m.status,
          m.context_length,
          m.max_output_tokens,
          m.supports_stream,
          m.supports_tools,
          m.supports_vision,
          m.supports_audio,
          m.supports_reasoning,
          up.id as default_profile_id,
          count(distinct c.id) filter (
            where ma.status = 'enabled'
              and c.status = 'enabled'
              and p.status = 'enabled'
          ) as routable_channel_count,
          array_remove(array_agg(distinct c.protocol_mode) filter (
            where ma.status = 'enabled'
              and c.status = 'enabled'
              and p.status = 'enabled'
          ), null) as protocol_modes,
          count(distinct ma.id) filter (
            where ma.status = 'enabled'
          ) as enabled_association_count,
          count(distinct c.id) filter (
            where ma.status = 'enabled'
              and c.status = 'enabled'
          ) as enabled_channel_count,
          count(distinct p.id) filter (
            where ma.status = 'enabled'
              and c.status = 'enabled'
              and p.status = 'enabled'
          ) as enabled_provider_count,
          pv.id as price_version_id,
          pv.price_book_id,
          pv.version as price_version,
          pv.pricing_rules,
          pv.effective_at::text as price_effective_at,
          pv.retired_at::text as price_retired_at,
          pb.currency as price_currency
        from user_profile up
        join canonical_models m on m.tenant_id = $1
          and m.status = 'active'
          and m.visibility in ('public', 'internal')
          and m.deleted_at is null
          and (
            jsonb_array_length(up.allowed_models) = 0
            or up.allowed_models ? m.model_key
          )
          and not (up.denied_models ? m.model_key)
        left join model_associations ma on ma.tenant_id = m.tenant_id
          and ma.canonical_model_id = m.id
          and ma.status = 'enabled'
          and ma.deleted_at is null
        left join channels c on c.tenant_id = ma.tenant_id
          and c.id = ma.channel_id
          and c.deleted_at is null
        left join providers p on p.tenant_id = c.tenant_id
          and p.id = c.provider_id
          and p.deleted_at is null
        left join projects project on project.tenant_id = $1
          and project.id = $2
          and project.deleted_at is null
        left join lateral (
          select
            pv.id,
            pv.price_book_id,
            pv.version,
            pv.pricing_rules,
            pv.effective_at,
            pv.retired_at
          from price_versions pv
          where pv.tenant_id = m.tenant_id
            and pv.status = 'active'
            and pv.effective_at <= now()
            and (pv.retired_at is null or pv.retired_at > now())
            and (
              pv.price_book_id = up.default_price_book_id
              or pv.price_book_id = project.default_price_book_id
              or pv.price_book_id = m.default_price_book_id
            )
            and (pv.canonical_model_id is null or pv.canonical_model_id = m.id)
          order by
            case when pv.canonical_model_id = m.id then 0 else 1 end,
            pv.effective_at desc,
            pv.created_at desc,
            pv.id
          limit 1
        ) pv on true
        left join price_books pb on pb.tenant_id = $1
          and pb.id = pv.price_book_id
        group by
          m.id,
          m.model_key,
          m.display_name,
          m.family,
          m.visibility,
          m.status,
          m.context_length,
          m.max_output_tokens,
          m.supports_stream,
          m.supports_tools,
          m.supports_vision,
          m.supports_audio,
          m.supports_reasoning,
          up.id,
          pv.id,
          pv.price_book_id,
          pv.version,
          pv.pricing_rules,
          pv.effective_at,
          pv.retired_at,
          pb.currency
        order by m.model_key
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.project_id)
    .fetch_all(state.db())
    .await
    .map_err(|_| AuthError::service_unavailable())?;

    let models = rows
        .into_iter()
        .map(user_model_response)
        .collect::<Result<Vec<_>, _>>()?;
    let model_availability_readback = user_model_availability_readback(state.as_ref(), &session)
        .await
        .map_err(|_| AuthError::service_unavailable())?;

    Ok(Json(json!({
        "data": models,
        "meta": {
            "schema": "user_models.v1",
            "project_id": session.user.project_id,
            "source": "active_user_profile",
            "model_availability_readback": model_availability_readback,
            "secret_safe": true
        }
    }))
    .into_response())
}

async fn redeem_user_voucher(
    State(state): State<Arc<ControlPlaneState>>,
    headers: HeaderMap,
    session: UserSession,
    Json(request): Json<UserVoucherRedeemRequest>,
) -> Result<Response, AdminError> {
    let currency = normalize_user_currency(request.currency.as_deref())?;
    let voucher_code = non_empty_user_field(&request.voucher_code, "voucher_code")?;
    let idempotency_key = request
        .idempotency_key
        .as_deref()
        .and_then(|value| {
            let trimmed = value.trim();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed.to_string())
            }
        })
        .unwrap_or_else(|| Uuid::new_v4().to_string());
    let wallet = ensure_user_wallet_exists(state.as_ref(), &session, &currency).await?;
    let outcome = admin::redeem_user_voucher_runtime(
        state.as_ref(),
        session.id,
        session.user.id,
        headers,
        UserVoucherRedeemRuntimeRequest {
            tenant_id: session.user.tenant_id,
            project_id: session.user.project_id,
            wallet_id: wallet.id,
            currency,
            voucher_code,
            idempotency_key,
        },
    )
    .await?;
    let status = outcome.get("status").and_then(Value::as_str);
    let status_code = if matches!(status, Some("redeemed" | "replayed")) {
        StatusCode::OK
    } else {
        StatusCode::BAD_REQUEST
    };
    let receipt = user_voucher_redeem_receipt(&outcome, &session, wallet.id);
    let mut response = outcome;
    if let Value::Object(object) = &mut response {
        object.insert("receipt".to_string(), receipt);
    }

    Ok((status_code, Json(json!({ "data": response }))).into_response())
}

fn user_voucher_redeem_receipt(outcome: &Value, session: &UserSession, wallet_id: Uuid) -> Value {
    let status = outcome
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let code_redacted = outcome
        .get("code_redacted")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(|value| json!(value))
        .unwrap_or(Value::Null);
    let code_locator = if code_redacted.is_null() {
        json!("omitted")
    } else {
        code_redacted.clone()
    };
    let expires_at = outcome.get("expires_at").cloned().unwrap_or(Value::Null);

    json!({
        "schema": "user_voucher_redeem_receipt.v1",
        "status": status,
        "amount": outcome.get("amount").cloned().unwrap_or(Value::Null),
        "currency": outcome.get("currency").cloned().unwrap_or(Value::Null),
        "credit_grant_id": outcome.get("credit_grant_id").cloned().unwrap_or(Value::Null),
        "ledger_entry_id": outcome.get("ledger_entry_id").cloned().unwrap_or(Value::Null),
        "redemption_id": outcome.get("redemption_id").cloned().unwrap_or(Value::Null),
        "voucher_id": outcome.get("voucher_id").cloned().unwrap_or(Value::Null),
        "tenant_id": session.user.tenant_id,
        "project_id": session.user.project_id,
        "wallet_id": outcome.get("wallet_id").cloned().unwrap_or_else(|| json!(wallet_id)),
        "expires_at": expires_at,
        "valid_until": outcome.get("expires_at").cloned().unwrap_or(Value::Null),
        "code_locator": code_locator,
        "code_redacted": code_redacted,
        "voucher_code": "omitted",
        "idempotency_key": "omitted",
        "raw_voucher_code_echoed": false,
        "raw_idempotency_key_echoed": false,
        "secret_safe": true,
        "refs": {
            "tenant_id": session.user.tenant_id,
            "project_id": session.user.project_id,
            "wallet_id": outcome.get("wallet_id").cloned().unwrap_or_else(|| json!(wallet_id)),
            "voucher_id": outcome.get("voucher_id").cloned().unwrap_or(Value::Null),
            "voucher_redemption_id": outcome.get("redemption_id").cloned().unwrap_or(Value::Null),
            "credit_grant_id": outcome.get("credit_grant_id").cloned().unwrap_or(Value::Null),
            "ledger_entry_id": outcome.get("ledger_entry_id").cloned().unwrap_or(Value::Null)
        }
    })
}

async fn list_user_request_logs(
    State(state): State<Arc<ControlPlaneState>>,
    session: UserSession,
    Query(query): Query<ListUserRequestLogsQuery>,
) -> Result<Response, AuthError> {
    let limit = user_request_log_limit(query.limit)?;
    let request_id = optional_user_request_id(query.request_id)?;
    let status = optional_user_filter(query.status, "status")?;
    let model = optional_user_filter(query.model, "model")?;
    let trace_id = optional_user_trace_id(query.trace_id)?;
    let rows = sqlx::query(
        r#"
        select
          id, tenant_id, project_id, virtual_key_id,
          trace_id, thread_id, client_request_id, inbound_protocol, outbound_protocol,
          protocol_mode, requested_model, upstream_model,
          status, http_status, error_owner, error_code, retryable, partial_sent,
          stream_end_reason, input_tokens, output_tokens, final_cost::text as final_cost,
          currency, latency_ms, ttft_ms,
          redaction_status, request_body_hash, response_body_hash,
          route_decision_snapshot,
          created_at::text as created_at, completed_at::text as completed_at
        from request_logs
        where tenant_id = $1
          and project_id = $2
          and ($3::text is null or status = $3)
          and ($4::text is null or requested_model = $4 or upstream_model = $4)
          and ($5::uuid is null or id = $5)
          and ($6::text is null or trace_id = $6)
        order by created_at desc, id desc
        limit $7
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.project_id)
    .bind(status)
    .bind(model)
    .bind(request_id)
    .bind(trace_id)
    .bind(limit)
    .fetch_all(state.db())
    .await
    .map_err(|_| AuthError::service_unavailable())?;

    let logs = rows
        .into_iter()
        .map(user_request_log_response)
        .collect::<Result<Vec<_>, _>>()?;
    Ok(Json(json!({
        "data": logs,
        "meta": {
            "schema": "user_request_logs.v1",
            "project_id": session.user.project_id,
            "read_only": true,
            "payload_preview_available": false,
            "omitted_internal_fields": [
                "api_key_profile_id",
                "canonical_model_id",
                "resolved_provider_id",
                "resolved_channel_id",
                "provider_key_id",
                "route_policy_version",
                "payload_policy_id",
                "payload_stored"
            ],
            "secret_safe": true
        }
    }))
    .into_response())
}

async fn get_user_usage_summary(
    State(state): State<Arc<ControlPlaneState>>,
    session: UserSession,
    Query(query): Query<UserUsageSummaryQuery>,
) -> Result<Response, AuthError> {
    let window_days = user_usage_window_days(query.window_days)?;
    let totals_row = sqlx::query(
        r#"
        select
          count(*)::bigint as request_count,
          count(*) filter (where status in ('succeeded', 'success', 'completed') or coalesce(http_status between 200 and 299, false))::bigint as success_count,
          count(*) filter (where not (status in ('succeeded', 'success', 'completed') or coalesce(http_status between 200 and 299, false)))::bigint as failed_count,
          count(*) filter (where retryable is true and not (status in ('succeeded', 'success', 'completed') or coalesce(http_status between 200 and 299, false)))::bigint as retryable_failed_count,
          coalesce(sum(input_tokens), 0)::bigint as input_tokens,
          coalesce(sum(output_tokens), 0)::bigint as output_tokens,
          coalesce(sum(input_tokens + output_tokens), 0)::bigint as total_tokens,
          coalesce(sum(final_cost), 0)::text as total_cost,
          coalesce(min(currency), 'USD') as currency,
          round(avg(latency_ms))::bigint as avg_latency_ms
        from request_logs
        where tenant_id = $1
          and project_id = $2
          and created_at >= now() - ($3::int * interval '1 day')
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.project_id)
    .bind(window_days as i32)
    .fetch_one(state.db())
    .await
    .map_err(|_| AuthError::service_unavailable())?;

    let model_rows = sqlx::query(
        r#"
        select
          coalesce(nullif(requested_model, ''), nullif(upstream_model, ''), 'unknown') as model,
          count(*)::bigint as request_count,
          count(*) filter (where status in ('succeeded', 'success', 'completed') or coalesce(http_status between 200 and 299, false))::bigint as success_count,
          count(*) filter (where not (status in ('succeeded', 'success', 'completed') or coalesce(http_status between 200 and 299, false)))::bigint as failed_count,
          coalesce(sum(input_tokens + output_tokens), 0)::bigint as total_tokens,
          coalesce(sum(final_cost), 0)::text as total_cost,
          coalesce(min(currency), 'USD') as currency,
          round(avg(latency_ms))::bigint as avg_latency_ms
        from request_logs
        where tenant_id = $1
          and project_id = $2
          and created_at >= now() - ($3::int * interval '1 day')
        group by coalesce(nullif(requested_model, ''), nullif(upstream_model, ''), 'unknown')
        order by request_count desc, total_tokens desc, model asc
        limit 10
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.project_id)
    .bind(window_days as i32)
    .fetch_all(state.db())
    .await
    .map_err(|_| AuthError::service_unavailable())?;

    let key_rows = sqlx::query(
        r#"
        select
          rl.virtual_key_id,
          vk.key_prefix,
          vk.name as key_name,
          count(*)::bigint as request_count,
          count(*) filter (where not (rl.status in ('succeeded', 'success', 'completed') or coalesce(rl.http_status between 200 and 299, false)))::bigint as failed_count,
          coalesce(sum(rl.input_tokens + rl.output_tokens), 0)::bigint as total_tokens,
          coalesce(sum(rl.final_cost), 0)::text as total_cost,
          coalesce(min(rl.currency), 'USD') as currency,
          max(rl.created_at)::text as last_request_at
        from request_logs rl
        left join virtual_keys vk on vk.tenant_id = rl.tenant_id
          and vk.id = rl.virtual_key_id
          and vk.project_id = $2
        where rl.tenant_id = $1
          and rl.project_id = $2
          and rl.created_at >= now() - ($3::int * interval '1 day')
        group by rl.virtual_key_id, vk.key_prefix, vk.name
        order by request_count desc, total_tokens desc, last_request_at desc
        limit 10
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.project_id)
    .bind(window_days as i32)
    .fetch_all(state.db())
    .await
    .map_err(|_| AuthError::service_unavailable())?;

    let error_rows = sqlx::query(
        r#"
        select
          coalesce(nullif(error_code, ''), 'unknown_error') as error_code,
          nullif(error_owner, '') as error_owner,
          count(*)::bigint as request_count,
          count(*) filter (where retryable is true)::bigint as retryable_count,
          max(created_at)::text as last_seen_at
        from request_logs
        where tenant_id = $1
          and project_id = $2
          and created_at >= now() - ($3::int * interval '1 day')
          and not (status in ('succeeded', 'success', 'completed') or coalesce(http_status between 200 and 299, false))
        group by coalesce(nullif(error_code, ''), 'unknown_error'), nullif(error_owner, '')
        order by request_count desc, last_seen_at desc
        limit 5
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.project_id)
    .bind(window_days as i32)
    .fetch_all(state.db())
    .await
    .map_err(|_| AuthError::service_unavailable())?;

    Ok(Json(json!({
        "data": UserUsageSummaryResponse {
            schema: "user_usage_summary.v1",
            project_id: session.user.project_id,
            window_days,
            totals: user_usage_totals(totals_row)?,
            by_model: model_rows
                .into_iter()
                .map(user_usage_model_summary)
                .collect::<Result<Vec<_>, _>>()?,
            by_key: key_rows
                .into_iter()
                .map(user_usage_key_summary)
                .collect::<Result<Vec<_>, _>>()?,
            top_errors: error_rows
                .into_iter()
                .map(user_usage_error_summary)
                .collect::<Result<Vec<_>, _>>()?,
            secret_safe: true,
        }
    }))
    .into_response())
}

async fn get_user_trace_summary(
    State(state): State<Arc<ControlPlaneState>>,
    session: UserSession,
    Path(trace_id): Path<String>,
    Query(query): Query<UserTraceSummaryQuery>,
) -> Result<Response, AuthError> {
    let trace_id = normalize_user_trace_id(&trace_id)?;
    let limit = user_request_log_limit(query.limit)?;
    let window_days = user_trace_window_days(query.window_days)?;
    let rows = sqlx::query(
        r#"
        select
          id, tenant_id, project_id, virtual_key_id,
          trace_id, thread_id, client_request_id, inbound_protocol, outbound_protocol,
          protocol_mode, requested_model, upstream_model,
          status, http_status, error_owner, error_code, retryable, partial_sent,
          stream_end_reason, input_tokens, output_tokens, final_cost::text as final_cost,
          currency, latency_ms, ttft_ms,
          redaction_status, request_body_hash, response_body_hash,
          route_decision_snapshot,
          created_at::text as created_at, completed_at::text as completed_at
        from request_logs
        where tenant_id = $1
          and project_id = $2
          and trace_id = $3
          and created_at >= now() - ($4::int * interval '1 day')
        order by created_at asc, id asc
        limit $5
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.project_id)
    .bind(&trace_id)
    .bind(window_days as i32)
    .bind(limit)
    .fetch_all(state.db())
    .await
    .map_err(|_| AuthError::service_unavailable())?;

    if rows.is_empty() {
        return Err(AuthError::not_found("request trace"));
    }

    let requests = rows
        .into_iter()
        .map(user_request_log_response)
        .collect::<Result<Vec<_>, _>>()?;

    Ok(Json(json!({
        "data": user_trace_summary_response(
            session.user.project_id,
            trace_id,
            limit,
            window_days,
            requests,
        )?
    }))
    .into_response())
}

async fn list_user_virtual_keys(
    State(state): State<Arc<ControlPlaneState>>,
    session: UserSession,
    Query(query): Query<ListUserVirtualKeysQuery>,
) -> Result<Response, AuthError> {
    let status = query
        .status
        .as_deref()
        .map(normalize_virtual_key_status)
        .transpose()?;
    let keys = DbRepository::new(state.db().clone())
        .list_virtual_keys(
            session.user.tenant_id,
            session.user.project_id,
            status.as_deref(),
        )
        .await
        .map_err(|_| AuthError::service_unavailable())?
        .into_iter()
        .map(|key| user_virtual_key_response(key, None))
        .collect::<Vec<_>>();

    Ok(Json(json!({ "data": keys })).into_response())
}

async fn create_user_virtual_key(
    State(state): State<Arc<ControlPlaneState>>,
    session: UserSession,
    Json(request): Json<CreateUserVirtualKeyRequest>,
) -> Result<Response, AuthError> {
    let name = normalize_key_name(&request.name)?;
    let default_profile_id = match request.default_profile_id {
        Some(profile_id) => {
            ensure_user_profile_scope(state.as_ref(), &session, profile_id).await?;
            profile_id
        }
        None => find_default_user_profile_id(state.as_ref(), &session)
            .await?
            .ok_or_else(|| {
                AuthError::bad_request_with_message(
                    "user_profile_required",
                    "no active api key profile is available for this user project",
                )
            })?,
    };
    let generated = generate_virtual_key();
    let secret = generated.secret.clone();
    let new_key = NewVirtualKey {
        id: Uuid::new_v4(),
        tenant_id: session.user.tenant_id,
        project_id: session.user.project_id,
        name,
        key_prefix: generated.prefix,
        secret_hash: generated.secret_hash,
        status: "active".to_string(),
        default_profile_id,
        ip_allowlist: user_server_owned_policy_or_default(
            request.ip_allowlist,
            json!([]),
            "ip_allowlist",
        )?,
        rate_limit_policy: user_server_owned_policy_or_default(
            request.rate_limit_policy,
            json!({}),
            "rate_limit_policy",
        )?,
        budget_policy: user_server_owned_policy_or_default(
            request.budget_policy,
            json!({}),
            "budget_policy",
        )?,
        metadata: user_virtual_key_metadata(request.metadata)?,
    };

    let key = DbRepository::new(state.db().clone())
        .create_virtual_key_with_default_profile_and_audit(new_key, |after| {
            new_user_virtual_key_audit_log(&session, "virtual_key.create", None, after)
        })
        .await
        .map_err(|_| AuthError::service_unavailable())?;

    Ok((
        axum::http::StatusCode::CREATED,
        Json(json!({ "data": user_virtual_key_response(key, Some(secret)) })),
    )
        .into_response())
}

async fn get_user_virtual_key(
    State(state): State<Arc<ControlPlaneState>>,
    session: UserSession,
    Path(id): Path<Uuid>,
) -> Result<Response, AuthError> {
    let key = get_scoped_user_virtual_key(state.as_ref(), &session, id).await?;
    Ok(Json(json!({ "data": user_virtual_key_response(key, None) })).into_response())
}

async fn disable_user_virtual_key(
    State(state): State<Arc<ControlPlaneState>>,
    session: UserSession,
    Path(id): Path<Uuid>,
) -> Result<Response, AuthError> {
    let current = get_scoped_user_virtual_key(state.as_ref(), &session, id).await?;
    let (key, _audit_log_id) = DbRepository::new(state.db().clone())
        .update_virtual_key_status_with_audit(
            current.tenant_id,
            current.id,
            "disabled",
            |before, after| {
                new_user_virtual_key_audit_log(&session, "virtual_key.disable", Some(before), after)
            },
        )
        .await
        .map_err(|_| AuthError::service_unavailable())?
        .ok_or_else(AuthError::unauthorized)?;

    Ok(Json(json!({ "data": user_virtual_key_response(key, None) })).into_response())
}

async fn delete_user_virtual_key(
    State(state): State<Arc<ControlPlaneState>>,
    session: UserSession,
    Path(id): Path<Uuid>,
) -> Result<Response, AuthError> {
    let current = get_scoped_user_virtual_key(state.as_ref(), &session, id).await?;
    let (key, _audit_log_id) = DbRepository::new(state.db().clone())
        .update_virtual_key_status_with_audit(
            current.tenant_id,
            current.id,
            "deleted",
            |before, after| {
                new_user_virtual_key_audit_log(&session, "virtual_key.delete", Some(before), after)
            },
        )
        .await
        .map_err(|_| AuthError::service_unavailable())?
        .ok_or_else(AuthError::unauthorized)?;

    Ok(Json(json!({ "data": user_virtual_key_response(key, None) })).into_response())
}

async fn create_login_response(
    state: &ControlPlaneState,
    headers: &HeaderMap,
    account: UserAccount,
) -> Result<Response, AuthError> {
    let generated = generate_session_token();
    let ttl_seconds = user_session_ttl_seconds();
    let created = AuthRepository::new(state.db().clone())
        .create_session(
            account.tenant_id,
            account.id,
            &generated.prefix,
            &generated.token_hash,
            user_agent(headers).as_deref(),
            ttl_seconds,
        )
        .await?;

    let response = UserAuthResponse {
        user: UserResponse::from_account(&account),
        session: UserSessionResponse {
            id: created.id,
            expires_at: created.expires_at,
        },
        project: UserProjectResponse {
            id: account.project_id,
            role: account.project_role,
        },
        session_token_once: generated.token.clone(),
    };

    let mut response = Json(json!({ "data": response })).into_response();
    response.headers_mut().insert(
        SET_COOKIE,
        HeaderValue::from_str(&user_session_cookie(&generated.token, ttl_seconds))
            .expect("user session cookie contains only header-safe characters"),
    );
    Ok(response)
}

fn productization_status_response(
    code: &'static str,
    message: &'static str,
    next_action: &'static str,
    purpose: &'static str,
) -> UserProductizationStatusResponse {
    UserProductizationStatusResponse {
        status: "config-needed",
        code,
        message,
        next_action,
        email_delivery: "config_needed",
        email_configured: false,
        delivery_mode: "config-needed",
        expires_in_seconds: None,
        request_id: format!("{}_{}", purpose, Uuid::new_v4()),
        audit: json!({
            "event": purpose,
            "status": "config-needed",
            "account_disclosure": "none",
            "token_returned": false,
            "email_attempted": false,
        }),
        account_disclosure: "none",
        secret_safe: true,
    }
}

#[derive(Debug, Clone)]
struct UserWallet {
    id: Uuid,
    currency: String,
}

async fn ensure_user_wallet_exists(
    state: &ControlPlaneState,
    session: &UserSession,
    currency: &str,
) -> Result<UserWallet, AdminError> {
    if let Some(wallet) = find_user_wallet(state, session, currency).await? {
        return Ok(wallet);
    }

    let row = sqlx::query(
        r#"
        insert into wallets (tenant_id, project_id, name, currency, status, balance_floor, metadata)
        values ($1, $2, $3, $4, 'active', 0, '{"created_by":"user_portal"}'::jsonb)
        returning id, currency
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.project_id)
    .bind(format!("{} wallet", currency))
    .bind(currency)
    .fetch_one(state.db())
    .await
    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;

    Ok(UserWallet {
        id: row
            .try_get("id")
            .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        currency: row
            .try_get("currency")
            .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
    })
}

async fn find_user_wallet(
    state: &ControlPlaneState,
    session: &UserSession,
    currency: &str,
) -> Result<Option<UserWallet>, AdminError> {
    let row = sqlx::query(
        r#"
        select id, currency
        from wallets
        where tenant_id = $1
          and project_id = $2
          and currency = $3
          and status in ('active', 'suspended')
          and deleted_at is null
        order by case when status = 'active' then 0 else 1 end, created_at, id
        limit 1
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.project_id)
    .bind(currency)
    .fetch_optional(state.db())
    .await
    .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?;

    row.map(|row| {
        Ok(UserWallet {
            id: row
                .try_get("id")
                .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
            currency: row
                .try_get("currency")
                .map_err(|error| AdminError::from(ai_gateway_db::DbError::Query(error)))?,
        })
    })
    .transpose()
}

pub(crate) async fn authenticate_user_headers(
    state: &ControlPlaneState,
    headers: &HeaderMap,
) -> Result<UserSession, AuthError> {
    let token = user_session_token_from_headers(headers)?.ok_or_else(AuthError::unauthorized)?;
    let session = AuthRepository::new(state.db().clone())
        .find_active_session_by_token(&token)
        .await?
        .ok_or_else(AuthError::unauthorized)?;
    let account = find_user_account_by_id(state, session.user.tenant_id, session.user.id)
        .await?
        .ok_or_else(AuthError::unauthorized)?;

    Ok(UserSession {
        id: session.id,
        user: account,
        expires_at: session.expires_at,
    })
}

fn user_session_token_from_headers(headers: &HeaderMap) -> Result<Option<String>, AuthError> {
    if let Some(cookie) = headers.get(COOKIE).and_then(|value| value.to_str().ok())
        && let Some(token) = cookie_value(cookie, USER_SESSION_COOKIE)
    {
        return Ok(Some(token.to_string()));
    }

    Ok(None)
}

async fn get_scoped_user_virtual_key(
    state: &ControlPlaneState,
    session: &UserSession,
    id: Uuid,
) -> Result<VirtualKey, AuthError> {
    let key = DbRepository::new(state.db().clone())
        .get_virtual_key(session.user.tenant_id, id)
        .await
        .map_err(|_| AuthError::service_unavailable())?
        .ok_or_else(AuthError::unauthorized)?;
    if key.project_id != session.user.project_id {
        return Err(AuthError::forbidden());
    }
    Ok(key)
}

async fn ensure_user_profile_scope(
    state: &ControlPlaneState,
    session: &UserSession,
    profile_id: Uuid,
) -> Result<(), AuthError> {
    let profile = DbRepository::new(state.db().clone())
        .get_api_key_profile(session.user.tenant_id, profile_id)
        .await
        .map_err(|_| AuthError::service_unavailable())?
        .ok_or_else(AuthError::bad_request)?;
    if profile.project_id != session.user.project_id || profile.status != "active" {
        return Err(AuthError::bad_request_with_message(
            "user_profile_not_available",
            "api key profile is not available for this user project",
        ));
    }
    Ok(())
}

async fn find_default_user_profile_id(
    state: &ControlPlaneState,
    session: &UserSession,
) -> Result<Option<Uuid>, AuthError> {
    let row = sqlx::query(
        r#"
        select id
        from api_key_profiles
        where tenant_id = $1
          and project_id = $2
          and status = 'active'
          and deleted_at is null
        order by case when name = 'default' then 0 else 1 end, created_at, id
        limit 1
        "#,
    )
    .bind(session.user.tenant_id)
    .bind(session.user.project_id)
    .fetch_optional(state.db())
    .await
    .map_err(|_| AuthError::service_unavailable())?;

    row.map(|row| row.try_get("id"))
        .transpose()
        .map_err(|_| AuthError::service_unavailable())
}

async fn find_user_account_by_email(
    state: &ControlPlaneState,
    email: &str,
) -> Result<Option<UserAccount>, AuthError> {
    let row = sqlx::query(USER_ACCOUNT_BY_EMAIL_SQL)
        .bind(DEFAULT_TENANT_ID)
        .bind(email)
        .fetch_optional(state.db())
        .await
        .map_err(|_| AuthError::service_unavailable())?;
    row.map(user_account_from_row).transpose()
}

async fn find_user_account_by_id(
    state: &ControlPlaneState,
    tenant_id: Uuid,
    user_id: Uuid,
) -> Result<Option<UserAccount>, AuthError> {
    let row = sqlx::query(USER_ACCOUNT_BY_ID_SQL)
        .bind(tenant_id)
        .bind(user_id)
        .fetch_optional(state.db())
        .await
        .map_err(|_| AuthError::service_unavailable())?;
    row.map(user_account_from_row).transpose()
}

fn user_account_from_row(row: sqlx::postgres::PgRow) -> Result<UserAccount, AuthError> {
    Ok(UserAccount {
        id: row
            .try_get("id")
            .map_err(|_| AuthError::service_unavailable())?,
        tenant_id: row
            .try_get("tenant_id")
            .map_err(|_| AuthError::service_unavailable())?,
        email: row
            .try_get("email")
            .map_err(|_| AuthError::service_unavailable())?,
        display_name: row
            .try_get("display_name")
            .map_err(|_| AuthError::service_unavailable())?,
        password_hash: row
            .try_get("password_hash")
            .map_err(|_| AuthError::service_unavailable())?,
        project_id: row
            .try_get("project_id")
            .map_err(|_| AuthError::service_unavailable())?,
        project_role: row
            .try_get("project_role")
            .map_err(|_| AuthError::service_unavailable())?,
        policy: user_policy_handoff_from_metadata(
            row.try_get("metadata")
                .map_err(|_| AuthError::service_unavailable())?,
        ),
    })
}

fn user_policy_handoff_from_metadata(metadata: Value) -> UserPolicyHandoff {
    let terms_version = metadata
        .get("terms_version")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .unwrap_or(CURRENT_TERMS_VERSION)
        .to_string();
    let privacy_version = metadata
        .get("privacy_version")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .unwrap_or(CURRENT_PRIVACY_VERSION)
        .to_string();
    let accepted_at = metadata
        .get("accepted_at")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string);
    let pending_acceptance = accepted_at.is_none()
        || terms_version != CURRENT_TERMS_VERSION
        || privacy_version != CURRENT_PRIVACY_VERSION;

    UserPolicyHandoff {
        terms_version,
        privacy_version,
        accepted_at,
        pending_acceptance,
    }
}

async fn ensure_default_project_exists(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
) -> Result<(), AuthError> {
    let exists: bool = sqlx::query_scalar(
        "select exists(select 1 from projects where tenant_id = $1 and id = $2 and status = 'active' and deleted_at is null)",
    )
    .bind(DEFAULT_TENANT_ID)
    .bind(DEFAULT_PROJECT_ID)
    .fetch_one(&mut **tx)
    .await
    .map_err(|_| AuthError::service_unavailable())?;
    if exists {
        Ok(())
    } else {
        Err(AuthError::service_unavailable())
    }
}

fn record_user_login_failure(
    state: &ControlPlaneState,
    key: &crate::auth_login_rate_limit::AdminLoginFailureRateLimitKey,
    now_epoch_seconds: u64,
    policy: ai_gateway_auth::LoginFailureRateLimitPolicy,
) -> AuthError {
    let decision = state
        .login_failure_rate_limits()
        .record_failure(key, now_epoch_seconds, policy);
    if decision.is_limited {
        AuthError::login_rate_limited(decision.retry_after_seconds.unwrap_or(1))
    } else {
        AuthError::invalid_credentials()
    }
}

fn normalize_email(email: &str) -> Option<String> {
    let email = email.trim().to_ascii_lowercase();
    if email.len() > 254
        || email.split('@').count() != 2
        || email.starts_with('@')
        || email.ends_with('@')
    {
        return None;
    }
    Some(email)
}

fn normalize_password(password: &str) -> Option<String> {
    if password.len() < 8 || password.len() > 256 {
        return None;
    }
    Some(password.to_string())
}

fn normalize_display_name(name: &str) -> Option<String> {
    let name = name.trim();
    if name.is_empty() || name.len() > 120 {
        return None;
    }
    Some(name.to_string())
}

fn normalize_key_name(name: &str) -> Result<String, AuthError> {
    let name = name.trim();
    if name.is_empty() || name.len() > 120 {
        return Err(AuthError::bad_request_with_message(
            "invalid_virtual_key_name",
            "virtual key name must be between 1 and 120 characters",
        ));
    }
    Ok(name.to_string())
}

fn normalize_virtual_key_status(status: &str) -> Result<String, AuthError> {
    let status = status.trim();
    match status {
        "" => Err(AuthError::bad_request()),
        "active" | "disabled" | "expired" | "deleted" => Ok(status.to_string()),
        _ => Err(AuthError::bad_request_with_message(
            "invalid_virtual_key_status",
            "virtual key status is invalid",
        )),
    }
}

fn user_server_owned_policy_or_default(
    value: Option<Value>,
    default: Value,
    field: &'static str,
) -> Result<Value, AuthError> {
    let Some(value) = value else {
        return Ok(default);
    };
    let empty_object = value.as_object().is_some_and(|object| object.is_empty());
    let empty_array = value.as_array().is_some_and(|array| array.is_empty());
    if empty_object || empty_array {
        Ok(default)
    } else if value.is_object() || value.is_array() {
        Err(AuthError::bad_request_with_message(
            "user_key_policy_server_owned",
            field,
        ))
    } else {
        Err(AuthError::bad_request_with_message(
            "invalid_json_field",
            field,
        ))
    }
}

fn user_virtual_key_metadata(value: Option<Value>) -> Result<Value, AuthError> {
    if let Some(value) = value
        && value.as_object().is_none_or(|object| !object.is_empty())
    {
        return Err(AuthError::bad_request_with_message(
            "user_key_metadata_server_owned",
            "metadata is controlled by the user portal",
        ));
    }
    let mut metadata = json!({});

    if let Some(object) = metadata.as_object_mut() {
        object.insert("created_by".to_string(), json!("user_portal"));
    }
    Ok(metadata)
}

fn new_user_virtual_key_audit_log(
    session: &UserSession,
    action: &'static str,
    before: Option<&VirtualKey>,
    after: &VirtualKey,
) -> NewAuditLog {
    NewAuditLog {
        tenant_id: after.tenant_id,
        actor_session_id: Some(session.id),
        request_id: None,
        action: action.to_string(),
        resource_type: "virtual_key".to_string(),
        resource_id: Some(after.id),
        resource_tenant_id: Some(after.tenant_id),
        before_snapshot: before.map(user_virtual_key_audit_summary),
        after_snapshot: Some(user_virtual_key_audit_summary(after)),
        metadata: json!({
            "actor_surface": "user_portal",
            "actor_user_id": session.user.id,
            "actor_project_id": session.user.project_id,
            "secret_material": "omitted",
            "raw_virtual_key_secret_echoed": false,
            "secret_hash_echoed": false,
            "server_owned_policy": true,
            "secret_safe": true,
        }),
    }
}

fn user_virtual_key_audit_summary(key: &VirtualKey) -> Value {
    json!({
        "id": key.id,
        "tenant_id": key.tenant_id,
        "project_id": key.project_id,
        "name": key.name,
        "key_prefix": key.key_prefix,
        "status": key.status,
        "default_profile_id": key.default_profile_id,
        "secret_material": "omitted",
        "secret_hash_echoed": false,
        "secret_safe": true,
    })
}

fn normalize_user_currency(value: Option<&str>) -> Result<String, AdminError> {
    let currency = value.unwrap_or("USD").trim().to_ascii_uppercase();
    if currency.len() < 3
        || currency.len() > 32
        || !currency.chars().all(|character| {
            character.is_ascii_uppercase() || character.is_ascii_digit() || character == '_'
        })
    {
        return Err(AdminError::bad_request("currency is invalid"));
    }
    Ok(currency)
}

fn non_empty_user_field(value: &str, field: &'static str) -> Result<String, AdminError> {
    let value = value.trim();
    if value.is_empty() {
        return Err(AdminError::bad_request(format!("{field} is required")));
    }
    Ok(value.to_string())
}

fn optional_user_filter(
    value: Option<String>,
    field: &'static str,
) -> Result<Option<String>, AuthError> {
    match value.map(|value| value.trim().to_string()) {
        Some(value) if value.is_empty() => Err(AuthError::bad_request_with_message(
            "invalid_user_request_log_filter",
            field,
        )),
        Some(value) => Ok(Some(value)),
        None => Ok(None),
    }
}

fn optional_user_request_id(value: Option<String>) -> Result<Option<Uuid>, AuthError> {
    let Some(value) = optional_user_filter(value, "request_id")? else {
        return Ok(None);
    };
    Uuid::parse_str(&value).map(Some).map_err(|_| {
        AuthError::bad_request_with_message(
            "invalid_user_request_id",
            "request_id must be a valid UUID",
        )
    })
}

fn optional_user_trace_id(value: Option<String>) -> Result<Option<String>, AuthError> {
    value
        .map(|value| normalize_user_trace_id(&value))
        .transpose()
}

fn user_request_log_limit(value: Option<i64>) -> Result<i64, AuthError> {
    let limit = value.unwrap_or(25);
    if !(1..=100).contains(&limit) {
        return Err(AuthError::bad_request_with_message(
            "invalid_user_request_log_limit",
            "limit must be between 1 and 100",
        ));
    }
    Ok(limit)
}

fn user_usage_window_days(value: Option<i64>) -> Result<i64, AuthError> {
    let window_days = value.unwrap_or(7);
    if !(1..=90).contains(&window_days) {
        return Err(AuthError::bad_request_with_message(
            "invalid_user_usage_window",
            "window_days must be between 1 and 90",
        ));
    }
    Ok(window_days)
}

fn user_trace_window_days(value: Option<i64>) -> Result<i64, AuthError> {
    let window_days = value.unwrap_or(30);
    if !(1..=90).contains(&window_days) {
        return Err(AuthError::bad_request_with_message(
            "invalid_user_trace_window",
            "window_days must be between 1 and 90",
        ));
    }
    Ok(window_days)
}

fn normalize_user_trace_id(value: &str) -> Result<String, AuthError> {
    let trace_id = value.trim();
    if trace_id.is_empty() || trace_id.len() > 160 {
        return Err(AuthError::bad_request_with_message(
            "invalid_user_trace_id",
            "trace_id must be between 1 and 160 characters",
        ));
    }
    if !trace_id.chars().all(|character| {
        character.is_ascii_alphanumeric() || matches!(character, '-' | '_' | ':' | '.')
    }) {
        return Err(AuthError::bad_request_with_message(
            "invalid_user_trace_id",
            "trace_id contains unsupported characters",
        ));
    }
    Ok(trace_id.to_string())
}

fn user_trace_summary_response(
    project_id: Uuid,
    trace_id: String,
    limit: i64,
    window_days: i64,
    mut requests: Vec<Value>,
) -> Result<UserTraceSummaryResponse, AuthError> {
    for request in &mut requests {
        if let Value::Object(object) = request {
            object.remove("request_body_hash");
            object.remove("response_body_hash");
        }
    }

    let request_count = requests.len() as i64;
    let limit_reached = request_count == limit;
    let mut error_count = 0_i64;
    let mut total_input_tokens = 0_i64;
    let mut total_output_tokens = 0_i64;
    let mut total_cost = 0_f64;
    let mut currencies = BTreeSet::new();
    let mut first_request_at: Option<String> = None;
    let mut last_request_at: Option<String> = None;
    let mut last_error: Option<UserTraceLastError> = None;

    for request in &requests {
        let status = request
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let http_status = request
            .get("http_status")
            .and_then(Value::as_i64)
            .and_then(|value| i32::try_from(value).ok());
        let succeeded = matches!(status, "succeeded" | "success" | "completed")
            || http_status.is_some_and(|value| (200..=299).contains(&value));
        if !succeeded {
            error_count += 1;
        }

        total_input_tokens += request
            .get("input_tokens")
            .and_then(Value::as_i64)
            .unwrap_or_default();
        total_output_tokens += request
            .get("output_tokens")
            .and_then(Value::as_i64)
            .unwrap_or_default();
        total_cost += request
            .get("final_cost")
            .and_then(Value::as_str)
            .and_then(|value| value.parse::<f64>().ok())
            .unwrap_or_default();
        if let Some(currency) = request.get("currency").and_then(Value::as_str)
            && !currency.trim().is_empty()
        {
            currencies.insert(currency.to_string());
        }
        if let Some(created_at) = request.get("created_at").and_then(Value::as_str) {
            first_request_at = Some(match first_request_at {
                Some(current) if current.as_str() <= created_at => current,
                _ => created_at.to_string(),
            });
        }
        let observed_at = request
            .get("completed_at")
            .and_then(Value::as_str)
            .or_else(|| request.get("created_at").and_then(Value::as_str));
        if let Some(observed_at) = observed_at {
            last_request_at = Some(match last_request_at {
                Some(current) if current.as_str() >= observed_at => current,
                _ => observed_at.to_string(),
            });
            if !succeeded {
                last_error = Some(UserTraceLastError {
                    code: request
                        .get("error_code")
                        .and_then(Value::as_str)
                        .map(str::to_string),
                    owner: request
                        .get("error_owner")
                        .and_then(Value::as_str)
                        .map(str::to_string),
                    http_status,
                    observed_at: observed_at.to_string(),
                });
            }
        }
    }

    Ok(UserTraceSummaryResponse {
        schema: "user_trace_summary.v1",
        project_id,
        trace_id,
        limit,
        limit_reached,
        window_days,
        request_count,
        error_count,
        last_error,
        total_input_tokens,
        total_output_tokens,
        total_cost: format!("{total_cost:.8}"),
        currencies: currencies.into_iter().collect(),
        first_request_at,
        last_request_at,
        requests,
        secret_safe: true,
    })
}

fn user_usage_totals(row: sqlx::postgres::PgRow) -> Result<UserUsageTotals, AuthError> {
    let input_tokens = row
        .try_get::<i64, _>("input_tokens")
        .map_err(|_| AuthError::service_unavailable())?;
    let output_tokens = row
        .try_get::<i64, _>("output_tokens")
        .map_err(|_| AuthError::service_unavailable())?;

    Ok(UserUsageTotals {
        request_count: row
            .try_get("request_count")
            .map_err(|_| AuthError::service_unavailable())?,
        success_count: row
            .try_get("success_count")
            .map_err(|_| AuthError::service_unavailable())?,
        failed_count: row
            .try_get("failed_count")
            .map_err(|_| AuthError::service_unavailable())?,
        retryable_failed_count: row
            .try_get("retryable_failed_count")
            .map_err(|_| AuthError::service_unavailable())?,
        input_tokens,
        output_tokens,
        total_tokens: row
            .try_get("total_tokens")
            .map_err(|_| AuthError::service_unavailable())?,
        total_cost: row
            .try_get("total_cost")
            .map_err(|_| AuthError::service_unavailable())?,
        currency: row
            .try_get("currency")
            .map_err(|_| AuthError::service_unavailable())?,
        avg_latency_ms: row
            .try_get("avg_latency_ms")
            .map_err(|_| AuthError::service_unavailable())?,
    })
}

fn user_usage_model_summary(
    row: sqlx::postgres::PgRow,
) -> Result<UserUsageModelSummary, AuthError> {
    Ok(UserUsageModelSummary {
        model: row
            .try_get("model")
            .map_err(|_| AuthError::service_unavailable())?,
        request_count: row
            .try_get("request_count")
            .map_err(|_| AuthError::service_unavailable())?,
        success_count: row
            .try_get("success_count")
            .map_err(|_| AuthError::service_unavailable())?,
        failed_count: row
            .try_get("failed_count")
            .map_err(|_| AuthError::service_unavailable())?,
        total_tokens: row
            .try_get("total_tokens")
            .map_err(|_| AuthError::service_unavailable())?,
        total_cost: row
            .try_get("total_cost")
            .map_err(|_| AuthError::service_unavailable())?,
        currency: row
            .try_get("currency")
            .map_err(|_| AuthError::service_unavailable())?,
        avg_latency_ms: row
            .try_get("avg_latency_ms")
            .map_err(|_| AuthError::service_unavailable())?,
    })
}

fn user_usage_key_summary(row: sqlx::postgres::PgRow) -> Result<UserUsageKeySummary, AuthError> {
    Ok(UserUsageKeySummary {
        virtual_key_id: row
            .try_get("virtual_key_id")
            .map_err(|_| AuthError::service_unavailable())?,
        key_prefix: row
            .try_get("key_prefix")
            .map_err(|_| AuthError::service_unavailable())?,
        key_name: row
            .try_get("key_name")
            .map_err(|_| AuthError::service_unavailable())?,
        request_count: row
            .try_get("request_count")
            .map_err(|_| AuthError::service_unavailable())?,
        failed_count: row
            .try_get("failed_count")
            .map_err(|_| AuthError::service_unavailable())?,
        total_tokens: row
            .try_get("total_tokens")
            .map_err(|_| AuthError::service_unavailable())?,
        total_cost: row
            .try_get("total_cost")
            .map_err(|_| AuthError::service_unavailable())?,
        currency: row
            .try_get("currency")
            .map_err(|_| AuthError::service_unavailable())?,
        last_request_at: row
            .try_get("last_request_at")
            .map_err(|_| AuthError::service_unavailable())?,
    })
}

fn user_usage_error_summary(
    row: sqlx::postgres::PgRow,
) -> Result<UserUsageErrorSummary, AuthError> {
    Ok(UserUsageErrorSummary {
        error_code: row
            .try_get("error_code")
            .map_err(|_| AuthError::service_unavailable())?,
        error_owner: row
            .try_get("error_owner")
            .map_err(|_| AuthError::service_unavailable())?,
        request_count: row
            .try_get("request_count")
            .map_err(|_| AuthError::service_unavailable())?,
        retryable_count: row
            .try_get("retryable_count")
            .map_err(|_| AuthError::service_unavailable())?,
        last_seen_at: row
            .try_get("last_seen_at")
            .map_err(|_| AuthError::service_unavailable())?,
    })
}

fn user_request_log_response(row: sqlx::postgres::PgRow) -> Result<Value, AuthError> {
    let partial_sent = row
        .try_get::<bool, _>("partial_sent")
        .map_err(|_| AuthError::service_unavailable())?;
    let stream_end_reason = row
        .try_get::<Option<String>, _>("stream_end_reason")
        .map_err(|_| AuthError::service_unavailable())?;
    let ttft_ms = row
        .try_get::<Option<i32>, _>("ttft_ms")
        .map_err(|_| AuthError::service_unavailable())?;
    let route_decision_snapshot = row
        .try_get::<Value, _>("route_decision_snapshot")
        .map_err(|_| AuthError::service_unavailable())?;
    Ok(json!({
        "id": row.try_get::<Uuid, _>("id").map_err(|_| AuthError::service_unavailable())?,
        "tenant_id": row.try_get::<Uuid, _>("tenant_id").map_err(|_| AuthError::service_unavailable())?,
        "project_id": row.try_get::<Option<Uuid>, _>("project_id").map_err(|_| AuthError::service_unavailable())?,
        "virtual_key_id": row.try_get::<Option<Uuid>, _>("virtual_key_id").map_err(|_| AuthError::service_unavailable())?,
        "trace_id": row.try_get::<Option<String>, _>("trace_id").map_err(|_| AuthError::service_unavailable())?,
        "thread_id": row.try_get::<Option<String>, _>("thread_id").map_err(|_| AuthError::service_unavailable())?,
        "client_request_id": row.try_get::<Option<String>, _>("client_request_id").map_err(|_| AuthError::service_unavailable())?,
        "inbound_protocol": row.try_get::<Option<String>, _>("inbound_protocol").map_err(|_| AuthError::service_unavailable())?,
        "outbound_protocol": row.try_get::<Option<String>, _>("outbound_protocol").map_err(|_| AuthError::service_unavailable())?,
        "protocol_mode": row.try_get::<Option<String>, _>("protocol_mode").map_err(|_| AuthError::service_unavailable())?,
        "requested_model": row.try_get::<Option<String>, _>("requested_model").map_err(|_| AuthError::service_unavailable())?,
        "upstream_model": row.try_get::<Option<String>, _>("upstream_model").map_err(|_| AuthError::service_unavailable())?,
        "status": row.try_get::<String, _>("status").map_err(|_| AuthError::service_unavailable())?,
        "http_status": row.try_get::<Option<i32>, _>("http_status").map_err(|_| AuthError::service_unavailable())?,
        "error_owner": row.try_get::<Option<String>, _>("error_owner").map_err(|_| AuthError::service_unavailable())?,
        "error_code": row.try_get::<Option<String>, _>("error_code").map_err(|_| AuthError::service_unavailable())?,
        "retryable": row.try_get::<Option<bool>, _>("retryable").map_err(|_| AuthError::service_unavailable())?,
        "partial_sent": partial_sent,
        "stream_end_reason": stream_end_reason.clone(),
        "stream_finalizer": ai_gateway_db::request_log_stream_finalizer_projection(
            partial_sent,
            stream_end_reason.as_deref(),
            ttft_ms,
            &route_decision_snapshot,
        ),
        "provider_protocol_summary": ai_gateway_db::request_log_provider_protocol_summary_projection(
            partial_sent,
            stream_end_reason.as_deref(),
            &route_decision_snapshot,
        ),
        "input_tokens": row.try_get::<i64, _>("input_tokens").map_err(|_| AuthError::service_unavailable())?,
        "output_tokens": row.try_get::<i64, _>("output_tokens").map_err(|_| AuthError::service_unavailable())?,
        "final_cost": row.try_get::<String, _>("final_cost").map_err(|_| AuthError::service_unavailable())?,
        "currency": row.try_get::<String, _>("currency").map_err(|_| AuthError::service_unavailable())?,
        "latency_ms": row.try_get::<Option<i32>, _>("latency_ms").map_err(|_| AuthError::service_unavailable())?,
        "ttft_ms": ttft_ms,
        "redaction_status": row.try_get::<String, _>("redaction_status").map_err(|_| AuthError::service_unavailable())?,
        "request_body_hash": row.try_get::<Option<String>, _>("request_body_hash").map_err(|_| AuthError::service_unavailable())?,
        "response_body_hash": row.try_get::<Option<String>, _>("response_body_hash").map_err(|_| AuthError::service_unavailable())?,
        "created_at": row.try_get::<String, _>("created_at").map_err(|_| AuthError::service_unavailable())?,
        "completed_at": row.try_get::<Option<String>, _>("completed_at").map_err(|_| AuthError::service_unavailable())?,
        "rate_limit_metadata": ai_gateway_db::request_log_rate_limit_metadata_projection(
            &route_decision_snapshot,
        ),
    }))
}

fn user_model_response(row: sqlx::postgres::PgRow) -> Result<UserModelResponse, AuthError> {
    let price_version_id = row
        .try_get::<Option<Uuid>, _>("price_version_id")
        .map_err(|_| AuthError::service_unavailable())?;
    let price = if let Some(price_version_id) = price_version_id {
        Some(json!({
            "price_version_id": price_version_id,
            "price_book_id": row.try_get::<Option<Uuid>, _>("price_book_id").map_err(|_| AuthError::service_unavailable())?,
            "version": row.try_get::<Option<String>, _>("price_version").map_err(|_| AuthError::service_unavailable())?,
            "currency": row.try_get::<Option<String>, _>("price_currency").map_err(|_| AuthError::service_unavailable())?,
            "pricing_rules": row.try_get::<Option<Value>, _>("pricing_rules").map_err(|_| AuthError::service_unavailable())?,
            "effective_at": row.try_get::<Option<String>, _>("price_effective_at").map_err(|_| AuthError::service_unavailable())?,
            "retired_at": row.try_get::<Option<String>, _>("price_retired_at").map_err(|_| AuthError::service_unavailable())?,
            "secret_safe": true,
        }))
    } else {
        None
    };
    let routable_channel_count = row
        .try_get::<i64, _>("routable_channel_count")
        .map_err(|_| AuthError::service_unavailable())?;
    let enabled_association_count = row
        .try_get::<i64, _>("enabled_association_count")
        .map_err(|_| AuthError::service_unavailable())?;
    let enabled_channel_count = row
        .try_get::<i64, _>("enabled_channel_count")
        .map_err(|_| AuthError::service_unavailable())?;
    let enabled_provider_count = row
        .try_get::<i64, _>("enabled_provider_count")
        .map_err(|_| AuthError::service_unavailable())?;
    let protocol_modes = row
        .try_get::<Option<Vec<String>>, _>("protocol_modes")
        .map_err(|_| AuthError::service_unavailable())?
        .unwrap_or_default();
    let unavailable_reasons = user_model_unavailable_reasons(
        routable_channel_count,
        enabled_association_count,
        enabled_channel_count,
        enabled_provider_count,
    );

    Ok(UserModelResponse {
        id: row
            .try_get("id")
            .map_err(|_| AuthError::service_unavailable())?,
        model: row
            .try_get("model_key")
            .map_err(|_| AuthError::service_unavailable())?,
        display_name: row
            .try_get("display_name")
            .map_err(|_| AuthError::service_unavailable())?,
        family: row
            .try_get("family")
            .map_err(|_| AuthError::service_unavailable())?,
        visibility: row
            .try_get("visibility")
            .map_err(|_| AuthError::service_unavailable())?,
        status: row
            .try_get("status")
            .map_err(|_| AuthError::service_unavailable())?,
        context_length: row
            .try_get("context_length")
            .map_err(|_| AuthError::service_unavailable())?,
        max_output_tokens: row
            .try_get("max_output_tokens")
            .map_err(|_| AuthError::service_unavailable())?,
        supports_stream: row
            .try_get("supports_stream")
            .map_err(|_| AuthError::service_unavailable())?,
        supports_tools: row
            .try_get("supports_tools")
            .map_err(|_| AuthError::service_unavailable())?,
        supports_vision: row
            .try_get("supports_vision")
            .map_err(|_| AuthError::service_unavailable())?,
        supports_audio: row
            .try_get("supports_audio")
            .map_err(|_| AuthError::service_unavailable())?,
        supports_reasoning: row
            .try_get("supports_reasoning")
            .map_err(|_| AuthError::service_unavailable())?,
        protocol_modes,
        routable: routable_channel_count > 0,
        routable_channel_count,
        unavailable_reasons,
        default_profile_id: row
            .try_get("default_profile_id")
            .map_err(|_| AuthError::service_unavailable())?,
        price,
    })
}

fn user_model_unavailable_reasons(
    routable_channel_count: i64,
    enabled_association_count: i64,
    enabled_channel_count: i64,
    enabled_provider_count: i64,
) -> Vec<String> {
    if routable_channel_count > 0 {
        return Vec::new();
    }

    let reason = if enabled_association_count <= 0 {
        "no_enabled_model_mapping"
    } else if enabled_channel_count <= 0 {
        "no_enabled_channel"
    } else if enabled_provider_count <= 0 {
        "no_enabled_provider"
    } else {
        "no_routable_route"
    };

    vec![reason.to_string()]
}

fn user_virtual_key_response(key: VirtualKey, secret: Option<String>) -> UserVirtualKeyResponse {
    let policy_diagnostics = user_virtual_key_policy_diagnostics(&key);
    UserVirtualKeyResponse {
        id: key.id,
        tenant_id: key.tenant_id,
        project_id: key.project_id,
        name: key.name,
        key_prefix: key.key_prefix,
        status: key.status,
        default_profile_id: key.default_profile_id,
        ip_allowlist: key.ip_allowlist,
        rate_limit_policy: key.rate_limit_policy,
        budget_policy: key.budget_policy,
        policy_diagnostics,
        metadata: key.metadata,
        secret_once: secret.is_some(),
        secret_redacted: secret.is_none(),
        secret,
    }
}

fn user_virtual_key_policy_diagnostics(key: &VirtualKey) -> Value {
    let rate_limit = user_virtual_key_rate_limit_diagnostics(&key.rate_limit_policy);
    let budget = user_virtual_key_budget_diagnostics(&key.budget_policy);
    let active = key.status == "active";
    let blocked_reasons = if active {
        Vec::<&str>::new()
    } else {
        vec!["virtual_key_not_active"]
    };

    json!({
        "schema": "virtual_key_project_budget_policy_diagnostics_readback.v1",
        "budget": budget,
        "rate_limit": rate_limit,
        "profile": {
            "default_profile_present": key.default_profile_id.is_some(),
            "blocked_reason": if key.default_profile_id.is_some() { Value::Null } else { Value::String("default_profile_missing".to_string()) },
        },
        "current_usage_summary": {
            "status": "not_loaded_for_virtual_key_readback",
            "source": "request_log_and_ledger_diagnostics_required",
            "raw_window_state_returned": false,
            "raw_payload_returned": false,
        },
        "blocked_reasons": blocked_reasons,
        "reject_reason": if active { Value::Null } else { Value::String("virtual_key_not_active".to_string()) },
        "safe_next_action": if active { "inspect_request_log_preauthorize_and_rate_limit_explainability_for_runtime_rejects" } else { "restore_or_create_active_virtual_key" },
        "refs_presence": {
            "ledger_ref_present": false,
            "preauth_ref_present": false,
            "request_log_ref_present": false,
            "source": "user_virtual_key_readback_does_not_load_runtime_refs",
        },
        "omitted_fields": [
            "raw_api_key_secret",
            "secret_hash",
            "authorization",
            "provider_key",
            "raw_payload",
            "raw_rate_limit_current_window_state",
            "raw_ledger_metadata"
        ],
        "secret_safe": true,
    })
}

fn user_virtual_key_rate_limit_diagnostics(policy: &Value) -> Value {
    let policy_present = user_json_object_has_entries(policy);
    let rpm_limit_present =
        user_json_number_or_string_present(policy, &["rpm", "rpm_limit", "requests_per_minute"]);
    let tpm_limit_present =
        user_json_number_or_string_present(policy, &["tpm", "tpm_limit", "tokens_per_minute"]);
    let concurrency_limit_present = user_json_number_or_string_present(
        policy,
        &[
            "concurrency",
            "concurrency_limit",
            "concurrent_requests",
            "max_concurrency",
        ],
    );
    let limit_present = rpm_limit_present || tpm_limit_present || concurrency_limit_present;
    let window_present = user_json_number_or_string_present(
        policy,
        &[
            "window_seconds",
            "window",
            "rpm_window_seconds",
            "tpm_window_seconds",
        ],
    );

    json!({
        "status": if limit_present { "configured" } else if policy_present { "policy_present_limit_missing" } else { "not_configured" },
        "policy_present": policy_present,
        "limit_present": limit_present,
        "window_present": window_present,
        "limits": {
            "rpm_limit_present": rpm_limit_present,
            "tpm_limit_present": tpm_limit_present,
            "concurrency_limit_present": concurrency_limit_present,
        },
        "current_usage_summary": {
            "status": "not_loaded_for_virtual_key_readback",
            "raw_window_state_returned": false,
        },
        "blocked_reason": if policy_present && !limit_present { Value::String("rate_limit_policy_has_no_known_limits".to_string()) } else { Value::Null },
        "reject_reason": Value::Null,
        "safe_next_action": if limit_present { "monitor_request_log_rate_limit_diagnostics" } else { "set_rpm_tpm_or_concurrency_limit" },
    })
}

fn user_virtual_key_budget_diagnostics(policy: &Value) -> Value {
    let policy_present = user_json_object_has_entries(policy);
    let limit_present = user_json_number_or_string_present(
        policy,
        &[
            "max_cost",
            "monthly_budget",
            "budget",
            "limit",
            "amount",
            "daily_budget",
        ],
    );
    let window_present = user_json_number_or_string_present(
        policy,
        &["window", "window_seconds", "period", "interval"],
    );

    json!({
        "status": if limit_present { "configured" } else if policy_present { "policy_present_limit_missing" } else { "not_configured" },
        "policy_present": policy_present,
        "limit_present": limit_present,
        "window_present": window_present,
        "current_usage_summary": {
            "status": "not_loaded_for_virtual_key_readback",
            "source": "ledger_window_not_loaded",
        },
        "blocked_reason": if policy_present && !limit_present { Value::String("budget_policy_has_no_known_limit".to_string()) } else { Value::Null },
        "reject_reason": Value::Null,
        "safe_next_action": if limit_present { "inspect_request_log_preauthorize_diagnostics_for_runtime_budget_status" } else { "set_budget_limit_and_window" },
    })
}

fn user_json_object_has_entries(value: &Value) -> bool {
    value.as_object().is_some_and(|object| !object.is_empty())
}

fn user_json_number_or_string_present(value: &Value, fields: &[&str]) -> bool {
    fields.iter().any(|field| {
        value.get(*field).is_some_and(|candidate| {
            candidate.is_number()
                || candidate
                    .as_str()
                    .is_some_and(|text| !text.trim().is_empty())
        })
    })
}

fn display_name_from_email(email: &str) -> String {
    email
        .split('@')
        .next()
        .unwrap_or("developer")
        .replace(['.', '_', '-'], " ")
}

fn user_agent(headers: &HeaderMap) -> Option<String> {
    let user_agent = headers.get(USER_AGENT)?.to_str().ok()?.trim();
    if user_agent.is_empty() {
        return None;
    }
    Some(user_agent.chars().take(MAX_USER_AGENT_LEN).collect())
}

fn user_session_ttl_seconds() -> i32 {
    std::env::var("AI_GATEWAY_USER_SESSION_TTL_SECONDS")
        .ok()
        .and_then(|value| value.parse::<i32>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(DEFAULT_USER_SESSION_TTL_SECONDS)
}

fn user_session_cookie(token: &str, ttl_seconds: i32) -> String {
    format!(
        "{USER_SESSION_COOKIE}={token}; Path=/; HttpOnly; SameSite=Lax; Max-Age={ttl_seconds}{}",
        if secure_user_cookie_enabled() {
            "; Secure"
        } else {
            ""
        }
    )
}

fn clear_user_session_cookie() -> String {
    let mut cookie = clear_session_cookie();
    cookie = cookie.replacen(crate::auth::ADMIN_SESSION_COOKIE, USER_SESSION_COOKIE, 1);
    cookie
}

fn secure_user_cookie_enabled() -> bool {
    std::env::var("AI_GATEWAY_USER_COOKIE_SECURE")
        .ok()
        .map(|value| {
            matches!(
                value.trim().to_ascii_lowercase().as_str(),
                "1" | "true" | "yes" | "on"
            )
        })
        .unwrap_or_else(|| {
            std::env::var("AI_GATEWAY_ENV")
                .map(|value| {
                    matches!(
                        value.trim().to_ascii_lowercase().as_str(),
                        "prod" | "production"
                    )
                })
                .unwrap_or(false)
        })
}

fn cookie_value<'a>(cookie_header: &'a str, name: &str) -> Option<&'a str> {
    cookie_header.split(';').find_map(|pair| {
        let (candidate_name, value) = pair.trim().split_once('=')?;
        if candidate_name.trim() == name {
            Some(value.trim())
        } else {
            None
        }
    })
}

fn current_epoch_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

const USER_ACCOUNT_BY_EMAIL_SQL: &str = r#"
select
  u.id,
  u.tenant_id,
  u.email,
  u.display_name,
  u.password_hash,
  u.metadata,
  pm.project_id,
  pm.role as project_role
from users u
join project_members pm on pm.tenant_id = u.tenant_id and pm.user_id = u.id
join projects p on p.tenant_id = pm.tenant_id and p.id = pm.project_id
where u.tenant_id = $1
  and lower(u.email) = lower($2)
  and u.status = 'active'
  and u.deleted_at is null
  and pm.role in ('owner', 'admin', 'developer')
  and p.status = 'active'
  and p.deleted_at is null
order by case when pm.project_id = '00000000-0000-0000-0000-000000000020' then 0 else 1 end, pm.created_at
limit 1
"#;

const USER_ACCOUNT_BY_ID_SQL: &str = r#"
select
  u.id,
  u.tenant_id,
  u.email,
  u.display_name,
  u.password_hash,
  u.metadata,
  pm.project_id,
  pm.role as project_role
from users u
join project_members pm on pm.tenant_id = u.tenant_id and pm.user_id = u.id
join projects p on p.tenant_id = pm.tenant_id and p.id = pm.project_id
where u.tenant_id = $1
  and u.id = $2
  and u.status = 'active'
  and u.deleted_at is null
  and pm.role in ('owner', 'admin', 'developer')
  and p.status = 'active'
  and p.deleted_at is null
order by case when pm.project_id = '00000000-0000-0000-0000-000000000020' then 0 else 1 end, pm.created_at
limit 1
"#;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn user_session_cookie_uses_distinct_cookie_name() {
        let cookie = user_session_cookie("sess_0123456789abcdef0123456789abcdef", 3600);

        assert!(cookie.starts_with("ai_gateway_user_session="));
        assert!(cookie.contains("; HttpOnly"));
        assert!(cookie.contains("; SameSite=Lax"));
        assert!(!cookie.contains("ai_gateway_admin_session"));
    }

    #[test]
    fn user_session_lookup_only_accepts_user_cookie() {
        let mut headers = HeaderMap::new();
        headers.insert(
            axum::http::header::AUTHORIZATION,
            HeaderValue::from_static("Bearer sess_admin_like_token"),
        );
        headers.insert(
            COOKIE,
            HeaderValue::from_static("ai_gateway_admin_session=sess_admin_cookie"),
        );

        assert_eq!(
            user_session_token_from_headers(&headers)
                .expect("header parse should not fail")
                .as_deref(),
            None
        );

        headers.insert(
            COOKIE,
            HeaderValue::from_static(
                "ai_gateway_admin_session=sess_admin_cookie; ai_gateway_user_session=sess_user_cookie",
            ),
        );
        assert_eq!(
            user_session_token_from_headers(&headers)
                .expect("user cookie should parse")
                .as_deref(),
            Some("sess_user_cookie")
        );
    }

    #[test]
    fn user_account_lookup_requires_api_distributing_project_role() {
        assert!(USER_ACCOUNT_BY_EMAIL_SQL.contains("pm.role in ('owner', 'admin', 'developer')"));
        assert!(USER_ACCOUNT_BY_ID_SQL.contains("pm.role in ('owner', 'admin', 'developer')"));
    }

    #[test]
    fn normalizes_user_registration_inputs() {
        assert_eq!(
            normalize_email(" User@Example.COM "),
            Some("user@example.com".to_string())
        );
        assert_eq!(normalize_email("@example.com"), None);
        assert!(normalize_password("12345678").is_some());
        assert!(normalize_password("short").is_none());
        assert_eq!(
            display_name_from_email("new.api-user@example.com"),
            "new api user"
        );
    }

    #[test]
    fn user_virtual_key_response_redacts_secret_after_create() {
        let key = VirtualKey {
            id: Uuid::from_u128(1),
            tenant_id: DEFAULT_TENANT_ID,
            project_id: DEFAULT_PROJECT_ID,
            name: "Portal key".to_string(),
            key_prefix: "vk_prefix_01".to_string(),
            secret_hash: "secret-hash-never-return".to_string(),
            status: "active".to_string(),
            default_profile_id: Some(Uuid::from_u128(2)),
            ip_allowlist: json!([]),
            rate_limit_policy: json!({}),
            budget_policy: json!({}),
            metadata: json!({}),
        };

        let created = user_virtual_key_response(key.clone(), Some("vk_secret_once".to_string()));
        assert_eq!(created.secret.as_deref(), Some("vk_secret_once"));
        assert!(created.secret_once);
        assert!(!created.secret_redacted);

        let readback = user_virtual_key_response(key, None);
        let serialized = serde_json::to_string(&readback).expect("serializes");
        assert!(readback.secret.is_none());
        assert!(!readback.secret_once);
        assert!(readback.secret_redacted);
        assert_eq!(
            readback.policy_diagnostics["schema"],
            json!("virtual_key_project_budget_policy_diagnostics_readback.v1")
        );
        assert_eq!(readback.policy_diagnostics["secret_safe"], json!(true));
        assert!(!serialized.contains("secret-hash-never-return"));
    }

    #[test]
    fn user_virtual_key_policy_is_server_owned() {
        assert_eq!(
            user_server_owned_policy_or_default(None, json!({}), "rate_limit_policy")
                .expect("default policy"),
            json!({})
        );
        assert_eq!(
            user_server_owned_policy_or_default(Some(json!({})), json!({}), "budget_policy")
                .expect("empty object uses default"),
            json!({})
        );
        assert!(
            user_server_owned_policy_or_default(
                Some(json!({"rpm": 999999})),
                json!({}),
                "rate_limit_policy"
            )
            .is_err()
        );
        assert!(user_virtual_key_metadata(Some(json!({"tier": "admin"}))).is_err());
    }

    #[test]
    fn user_virtual_key_audit_summary_is_secret_safe() {
        let session = UserSession {
            id: Uuid::from_u128(11),
            expires_at: "2026-06-07T00:00:00Z".to_string(),
            user: UserAccount {
                id: Uuid::from_u128(12),
                tenant_id: DEFAULT_TENANT_ID,
                email: "developer@example.test".to_string(),
                display_name: "Developer".to_string(),
                password_hash: Some("password-hash-never-return".to_string()),
                project_id: DEFAULT_PROJECT_ID,
                project_role: "developer".to_string(),
                policy: UserPolicyHandoff {
                    terms_version: CURRENT_TERMS_VERSION.to_string(),
                    privacy_version: CURRENT_PRIVACY_VERSION.to_string(),
                    accepted_at: Some("2026-06-07T00:00:00Z".to_string()),
                    pending_acceptance: false,
                },
            },
        };
        let key = VirtualKey {
            id: Uuid::from_u128(13),
            tenant_id: DEFAULT_TENANT_ID,
            project_id: DEFAULT_PROJECT_ID,
            name: "Portal key".to_string(),
            key_prefix: "vk_prefix_01".to_string(),
            secret_hash: "secret-hash-never-return".to_string(),
            status: "active".to_string(),
            default_profile_id: Some(Uuid::from_u128(14)),
            ip_allowlist: json!([]),
            rate_limit_policy: json!({}),
            budget_policy: json!({}),
            metadata: json!({}),
        };

        let audit = new_user_virtual_key_audit_log(&session, "virtual_key.create", None, &key);
        let serialized = serde_json::to_string(&audit).expect("audit serializes");

        assert!(serialized.contains("user_portal"));
        assert!(!serialized.contains("secret-hash-never-return"));
        assert!(!serialized.contains("password-hash-never-return"));
        assert!(!serialized.contains("\"secret\""));
    }

    #[test]
    fn user_virtual_key_delete_route_is_scoped_and_secret_safe() {
        let source = include_str!("user_auth.rs");
        let route_section = source
            .split(".route(\n            \"/user/virtual-keys/{id}\"")
            .nth(1)
            .and_then(|tail| {
                tail.split(".route(\n            \"/user/virtual-keys/{id}/disable\"")
                    .next()
            })
            .expect("user virtual key route section should be present");
        let delete_section = source
            .split("async fn delete_user_virtual_key")
            .nth(1)
            .and_then(|tail| tail.split("async fn create_login_response").next())
            .expect("delete_user_virtual_key section should be present");

        assert!(route_section.contains(".delete(delete_user_virtual_key)"));
        assert!(delete_section.contains("get_scoped_user_virtual_key"));
        assert!(delete_section.contains("update_virtual_key_status_with_audit"));
        assert!(delete_section.contains("\"deleted\""));
        assert!(delete_section.contains("\"virtual_key.delete\""));
        assert!(delete_section.contains("user_virtual_key_response(key, None)"));
    }

    #[test]
    fn user_models_route_is_session_scoped_and_profile_filtered() {
        let routes = include_str!("user_auth.rs");
        assert!(routes.contains(".route(\"/user/models\", get(list_user_models))"));
        assert!(routes.contains("jsonb_array_length(up.allowed_models) = 0"));
        assert!(routes.contains("not (up.denied_models ? m.model_key)"));
        assert!(routes.contains("and p.status = 'enabled'"));
        assert!(routes.contains("\"secret_safe\": true"));
    }

    #[test]
    fn user_home_summary_route_and_contract_are_secret_safe() {
        let source = include_str!("user_auth.rs");
        let route_section = source
            .split(".route(\"/user/home-summary\", get(get_user_home_summary))")
            .nth(1)
            .expect("home summary route should be wired");
        let handler_section = source
            .split("async fn get_user_home_summary")
            .nth(1)
            .and_then(|tail| tail.split("async fn get_user_readiness").next())
            .expect("home summary handler should be present");

        assert!(route_section.contains(".route(\"/user/models\", get(list_user_models))"));
        assert!(handler_section.contains("schema: \"user_home_summary.v1\""));
        assert!(handler_section.contains("user_home_endpoint_summary()"));
        assert!(handler_section.contains("user_home_models_summary"));
        assert!(handler_section.contains("user_home_recent_usage"));
        assert!(handler_section.contains("user_home_recent_requests"));
        assert!(handler_section.contains("\"api_key_secret\""));
        assert!(handler_section.contains("\"provider_key\""));
        assert!(handler_section.contains("\"authorization\""));
        assert!(handler_section.contains("\"voucher_raw_code\""));
        assert!(handler_section.contains("\"raw_request_payload\""));
        assert!(handler_section.contains("\"prompt\""));
        assert!(handler_section.contains("secret_safe: true"));
        assert!(!handler_section.contains("secret_hash:"));
        assert!(!handler_section.contains("request_body"));
        assert!(!handler_section.contains("response_body"));
    }

    #[test]
    fn user_billing_history_readback_is_compact_and_secret_safe() {
        let source = include_str!("user_auth.rs");
        let route_section = source
            .split("\"/user/billing-history-readback\"")
            .nth(1)
            .expect("billing history route should be wired");
        let handler_section = source
            .split("async fn get_user_billing_history_readback")
            .nth(1)
            .and_then(|tail| tail.split("async fn get_user_home_summary").next())
            .expect("billing history handler should be present");
        let helper_section = source
            .split("async fn user_billing_history_recent_ledger_entries")
            .nth(1)
            .and_then(|tail| tail.split("fn user_security_activity_next_actions").next())
            .expect("billing history helpers should be present");

        assert!(route_section.contains("get(get_user_billing_history_readback)"));
        assert!(handler_section.contains("schema: \"user_billing_history_readback.v1\""));
        assert!(handler_section.contains("user_remaining_balance_runtime_response"));
        assert!(handler_section.contains("credit_grant_expiration_readback"));
        assert!(handler_section.contains("user_billing_history_recent_ledger_entries"));
        assert!(handler_section.contains("user_home_recent_usage"));
        assert!(handler_section.contains("user_billing_history_refs_presence"));
        assert!(handler_section.contains("\"raw_api_key\""));
        assert!(handler_section.contains("\"Authorization\""));
        assert!(handler_section.contains("\"provider_key\""));
        assert!(handler_section.contains("\"raw_payload\""));
        assert!(handler_section.contains("\"raw_ledger_metadata\""));
        assert!(handler_section.contains("\"raw_invoice_metadata\""));
        assert!(handler_section.contains("raw_api_key_returned: false"));
        assert!(handler_section.contains("authorization_returned: false"));
        assert!(handler_section.contains("provider_key_returned: false"));
        assert!(handler_section.contains("raw_payload_returned: false"));
        assert!(handler_section.contains("raw_ledger_metadata_returned: false"));
        assert!(handler_section.contains("raw_invoice_metadata_returned: false"));
        assert!(helper_section.contains("from ledger_entries"));
        assert!(helper_section.contains("from voucher_issuances"));
        assert!(helper_section.contains("from payment_orders"));
        assert!(helper_section.contains("from subscriptions"));
        assert!(helper_section.contains("\"raw_metadata_returned\": false"));
        assert!(!handler_section.contains("request_body"));
        assert!(!handler_section.contains("response_body"));
    }

    #[test]
    fn user_developer_quickstart_readback_is_secret_safe() {
        let source = include_str!("user_auth.rs");
        let route_section = source
            .split("\"/user/developer-quickstart-readback\"")
            .nth(1)
            .expect("developer quickstart route should be wired");
        let handler_section = source
            .split("async fn get_user_developer_quickstart_readback")
            .nth(1)
            .and_then(|tail| {
                tail.split("async fn get_user_developer_distribution_packet_readback")
                    .next()
            })
            .expect("developer quickstart handler should be present");

        assert!(route_section.contains("get(get_user_developer_quickstart_readback)"));
        assert!(handler_section.contains("schema: \"user_developer_quickstart_readback.v1\""));
        assert!(handler_section.contains("user_home_endpoint_summary()"));
        assert!(handler_section.contains("user_home_models_summary"));
        assert!(handler_section.contains("model_availability_readback"));
        assert!(handler_section.contains("user_developer_quickstart_key_status"));
        assert!(handler_section.contains("user_developer_quickstart_mock_readiness"));
        assert!(handler_section.contains("\"api_key_secret\""));
        assert!(handler_section.contains("\"api_key_secret_hash\""));
        assert!(handler_section.contains("\"Authorization\""));
        assert!(handler_section.contains("\"provider_key\""));
        assert!(handler_section.contains("\"raw_request_payload\""));
        assert!(handler_section.contains("raw_payload_returned: false"));
        assert!(handler_section.contains("authorization_returned: false"));
        assert!(handler_section.contains("provider_key_returned: false"));
        assert!(handler_section.contains("secret_safe: true"));
        assert!(!handler_section.contains("secret_hash:"));
        assert!(!handler_section.contains("request_body"));
        assert!(!handler_section.contains("response_body"));
    }

    #[test]
    fn user_developer_distribution_packet_readback_is_secret_safe() {
        let source = include_str!("user_auth.rs");
        let route_section = source
            .split("\"/user/developer-distribution-packet-readback\"")
            .nth(1)
            .expect("developer distribution packet route should be wired");
        let handler_section = source
            .split("async fn get_user_developer_distribution_packet_readback")
            .nth(1)
            .and_then(|tail| {
                tail.split("async fn get_user_security_activity_summary")
                    .next()
            })
            .expect("developer distribution packet handler should be present");

        assert!(route_section.contains("get(get_user_developer_distribution_packet_readback)"));
        assert!(handler_section.contains("schema: \"developer_distribution_packet_readback.v1\""));
        assert!(handler_section.contains("user_developer_quickstart_mock_readiness"));
        assert!(handler_section.contains("user_home_models_summary"));
        assert!(handler_section.contains("user_developer_distribution_guardrails"));
        assert!(handler_section.contains("voucher_key_handoff_refs"));
        assert!(handler_section.contains("\"raw_api_key\""));
        assert!(handler_section.contains("\"api_key_secret\""));
        assert!(handler_section.contains("\"raw_voucher_code\""));
        assert!(handler_section.contains("\"provider_key\""));
        assert!(handler_section.contains("\"Authorization\""));
        assert!(handler_section.contains("\"token\""));
        assert!(handler_section.contains("raw_payload_returned: false"));
        assert!(handler_section.contains("authorization_returned: false"));
        assert!(handler_section.contains("token_returned: false"));
        assert!(handler_section.contains("raw_api_key_returned: false"));
        assert!(handler_section.contains("voucher_code_returned: false"));
        assert!(handler_section.contains("provider_key_returned: false"));
        assert!(handler_section.contains("api_key_secret_returned: false"));
        assert!(handler_section.contains("secret_safe: true"));
        assert!(!handler_section.contains("secret_hash:"));
        assert!(!handler_section.contains("request_body"));
        assert!(!handler_section.contains("response_body"));
    }

    #[test]
    fn user_security_activity_summary_is_secret_safe() {
        let source = include_str!("user_auth.rs");
        let route_section = source
            .split("\"/user/security-activity-summary\"")
            .nth(1)
            .expect("security activity route should be wired");
        let handler_section = source
            .split("async fn get_user_security_activity_summary")
            .nth(1)
            .and_then(|tail| tail.split("async fn get_user_readiness").next())
            .expect("security activity handler should be present");

        assert!(route_section.contains("get(get_user_security_activity_summary)"));
        assert!(handler_section.contains("schema: \"user_security_activity_summary.v1\""));
        assert!(handler_section.contains("user_security_login_activity"));
        assert!(handler_section.contains("user_security_password_email_activity"));
        assert!(handler_section.contains("user_security_api_key_activity"));
        assert!(handler_section.contains("user_security_balance_ledger_activity"));
        assert!(handler_section.contains("\"password_hash\""));
        assert!(handler_section.contains("\"session_token\""));
        assert!(handler_section.contains("\"token_hash\""));
        assert!(handler_section.contains("\"api_key_secret\""));
        assert!(handler_section.contains("\"api_key_secret_hash\""));
        assert!(handler_section.contains("\"Authorization\""));
        assert!(handler_section.contains("\"raw_payload\""));
        assert!(handler_section.contains("password_hash_returned: false"));
        assert!(handler_section.contains("session_token_returned: false"));
        assert!(handler_section.contains("api_key_secret_returned: false"));
        assert!(handler_section.contains("api_key_secret_hash_returned: false"));
        assert!(handler_section.contains("secret_safe: true"));
        assert!(!handler_section.contains("secret_hash:"));
        assert!(!handler_section.contains("request_body_hash"));
        assert!(!handler_section.contains("response_body_hash"));
    }

    #[test]
    fn user_request_logs_omit_internal_routing_fields() {
        let source = include_str!("user_auth.rs");
        let list_section = source
            .split("async fn list_user_request_logs")
            .nth(1)
            .and_then(|tail| tail.split("async fn list_user_virtual_keys").next())
            .expect("list_user_request_logs section should be present");
        let response_section = source
            .split("fn user_request_log_response")
            .nth(1)
            .and_then(|tail| tail.split("fn user_model_response").next())
            .expect("user_request_log_response section should be present");

        for forbidden in [
            "api_key_profile_id",
            "canonical_model_id",
            "resolved_provider_id",
            "resolved_channel_id",
            "provider_key_id",
            "route_policy_version",
            "payload_policy_id",
            "payload_stored",
        ] {
            assert!(
                !response_section.contains(&format!("\"{forbidden}\"")),
                "user log response must not expose {forbidden}"
            );
        }

        assert!(list_section.contains("\"omitted_internal_fields\""));
        assert!(list_section.contains("\"provider_key_id\""));
        assert!(list_section.contains("and project_id = $2"));
        assert!(list_section.contains("and ($5::uuid is null or id = $5)"));
        assert!(list_section.contains("and ($6::text is null or trace_id = $6)"));
        assert!(list_section.contains("optional_user_request_id(query.request_id)"));
        assert!(list_section.contains("optional_user_trace_id(query.trace_id)"));
        assert!(response_section.contains("\"virtual_key_id\""));
        assert!(response_section.contains("\"request_body_hash\""));
        assert!(response_section.contains("\"response_body_hash\""));
    }
}
