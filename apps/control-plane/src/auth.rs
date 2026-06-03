use std::{
    collections::BTreeMap,
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};

use ai_gateway_auth::{
    DEFAULT_LOGIN_FAILURE_LIMIT, DEFAULT_LOGIN_FAILURE_WINDOW_SECONDS, LoginFailureRateLimitPolicy,
    Role, generate_session_token, require_permission, verify_admin_password,
};
use axum::{
    Json, Router,
    extract::{FromRequestParts, Query, State},
    http::{
        HeaderMap, HeaderValue, StatusCode,
        header::{AUTHORIZATION, COOKIE, RETRY_AFTER, SET_COOKIE, USER_AGENT},
        request::Parts,
    },
    response::{IntoResponse, Response},
    routing::{get, post},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use uuid::Uuid;

use crate::{
    ControlPlaneState, DEFAULT_TENANT_ID,
    auth_login_rate_limit::{AdminLoginFailureRateLimitKey, admin_login_failure_rate_limit_key},
    auth_repo::{AuthRepoError, AuthRepository, StoredAdminSession, StoredAdminUser},
    rbac::{ControlPlaneCapabilitySummary, capability_summary_for_roles},
};

pub(crate) const ADMIN_SESSION_COOKIE: &str = "ai_gateway_admin_session";
pub(crate) const ADMIN_SESSION_HEADER: &str = "x-admin-session";
const DEFAULT_SESSION_TTL_SECONDS: i32 = 12 * 60 * 60;
const MAX_USER_AGENT_LEN: usize = 512;
const ADMIN_COOKIE_SECURE_ENV: &str = "AI_GATEWAY_ADMIN_COOKIE_SECURE";
const ADMIN_LOGIN_FAILURE_LIMIT_ENV: &str = "AI_GATEWAY_ADMIN_LOGIN_FAILURE_LIMIT";
const ADMIN_LOGIN_FAILURE_WINDOW_SECONDS_ENV: &str =
    "AI_GATEWAY_ADMIN_LOGIN_FAILURE_WINDOW_SECONDS";

pub(crate) fn router() -> Router<Arc<ControlPlaneState>> {
    Router::new()
        .route("/admin/auth/login", post(login))
        .route("/admin/auth/oidc/authorize-url", get(oidc_authorize_url))
        .route("/admin/auth/oidc/callback", get(oidc_callback))
        .route("/admin/auth/me", get(me))
        .route("/admin/auth/logout", post(logout))
}

pub(crate) async fn authenticate_headers(
    state: &ControlPlaneState,
    headers: &HeaderMap,
) -> Result<AdminSession, AuthError> {
    let candidate = session_token_from_headers(headers)?.ok_or_else(AuthError::unauthorized)?;
    let repository = AuthRepository::new(state.db().clone());
    let session = repository
        .find_active_session_by_token(candidate.token.as_str())
        .await?
        .ok_or_else(AuthError::unauthorized)?;

    Ok(AdminSession { inner: session })
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct AdminSession {
    inner: StoredAdminSession,
}

impl AdminSession {
    pub(crate) fn session_id(&self) -> Uuid {
        self.inner.id
    }

    pub(crate) fn tenant_id(&self) -> Uuid {
        self.inner.user.tenant_id
    }

    pub(crate) fn roles(&self) -> &[Role] {
        &self.inner.user.roles
    }

    pub(crate) fn has_any_role(&self) -> bool {
        !self.inner.user.roles.is_empty()
    }

    pub(crate) fn require_permission(
        &self,
        permission: ai_gateway_auth::Permission,
    ) -> Result<(), ai_gateway_auth::AccessControlError> {
        require_permission(self.roles(), permission)
    }

    fn user_response(&self) -> AdminUserResponse {
        AdminUserResponse::from_user(&self.inner.user)
    }

    fn session_response(&self) -> AdminSessionResponse {
        AdminSessionResponse {
            id: self.inner.id,
            expires_at: self.inner.expires_at.clone(),
        }
    }

    fn me_response(&self) -> MeResponse {
        MeResponse {
            user: self.user_response(),
            session: self.session_response(),
            capability_summary: capability_summary_for_roles(self.roles()),
        }
    }
}

impl FromRequestParts<Arc<ControlPlaneState>> for AdminSession {
    type Rejection = AuthError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &Arc<ControlPlaneState>,
    ) -> Result<Self, Self::Rejection> {
        authenticate_headers(state.as_ref(), &parts.headers).await
    }
}

#[derive(Deserialize)]
struct LoginRequest {
    email: String,
    password: String,
}

#[derive(Debug, Serialize)]
struct LoginResponse {
    user: AdminUserResponse,
    session: AdminSessionResponse,
    session_token_once: String,
}

#[derive(Debug, Serialize)]
struct OidcAuthorizeResponse {
    provider: String,
    authorization_url: String,
    state: String,
    nonce: String,
    scopes: Vec<String>,
    response_type: &'static str,
    state_ttl_seconds: i32,
    server_state_persisted: bool,
    callback_implemented: bool,
}

#[derive(Debug, Serialize)]
struct MeResponse {
    user: AdminUserResponse,
    session: AdminSessionResponse,
    capability_summary: ControlPlaneCapabilitySummary,
}

#[derive(Debug, Serialize)]
struct AdminUserResponse {
    id: Uuid,
    tenant_id: Uuid,
    email: String,
    display_name: String,
    roles: Vec<&'static str>,
}

impl AdminUserResponse {
    fn from_user(user: &StoredAdminUser) -> Self {
        Self {
            id: user.id,
            tenant_id: user.tenant_id,
            email: user.email.clone(),
            display_name: user.display_name.clone(),
            roles: user.roles.iter().map(|role| role.as_str()).collect(),
        }
    }
}

#[derive(Debug, Serialize)]
struct AdminSessionResponse {
    id: Uuid,
    expires_at: String,
}

async fn login(
    State(state): State<Arc<ControlPlaneState>>,
    headers: HeaderMap,
    Json(request): Json<LoginRequest>,
) -> Result<Response, AuthError> {
    let email = request.email.trim();
    let rate_limit_key = admin_login_failure_rate_limit_key(DEFAULT_TENANT_ID, email);
    let rate_limit_policy = login_failure_rate_limit_policy();
    let now_epoch_seconds = current_epoch_seconds();
    let decision = state.login_failure_rate_limits().check(
        &rate_limit_key,
        now_epoch_seconds,
        rate_limit_policy,
    );
    if decision.is_limited {
        return Err(AuthError::login_rate_limited(
            decision.retry_after_seconds.unwrap_or(1),
        ));
    }

    if email.is_empty() || request.password.is_empty() {
        return Err(record_login_failure_error(
            state.as_ref(),
            &rate_limit_key,
            now_epoch_seconds,
            rate_limit_policy,
        ));
    }

    let repository = AuthRepository::new(state.db().clone());
    let Some(user) = repository
        .find_active_user_by_email(DEFAULT_TENANT_ID, email)
        .await?
    else {
        return Err(record_login_failure_error(
            state.as_ref(),
            &rate_limit_key,
            now_epoch_seconds,
            rate_limit_policy,
        ));
    };

    let Some(password_hash) = user.password_hash.as_deref() else {
        return Err(record_login_failure_error(
            state.as_ref(),
            &rate_limit_key,
            now_epoch_seconds,
            rate_limit_policy,
        ));
    };
    let password_matches = match verify_admin_password(&request.password, password_hash) {
        Ok(password_matches) => password_matches,
        Err(_) => {
            return Err(record_login_failure_error(
                state.as_ref(),
                &rate_limit_key,
                now_epoch_seconds,
                rate_limit_policy,
            ));
        }
    };
    if !password_matches {
        return Err(record_login_failure_error(
            state.as_ref(),
            &rate_limit_key,
            now_epoch_seconds,
            rate_limit_policy,
        ));
    }

    let generated = generate_session_token();
    let ttl_seconds = session_ttl_seconds();
    let created = repository
        .create_session(
            user.tenant_id,
            user.id,
            &generated.prefix,
            &generated.token_hash,
            user_agent(&headers).as_deref(),
            ttl_seconds,
        )
        .await?;
    state.login_failure_rate_limits().clear(&rate_limit_key);

    let response = LoginResponse {
        user: AdminUserResponse::from_user(&user),
        session: AdminSessionResponse {
            id: created.id,
            expires_at: created.expires_at,
        },
        session_token_once: generated.token.clone(),
    };

    let mut response = Json(json!({ "data": response })).into_response();
    response.headers_mut().insert(
        SET_COOKIE,
        HeaderValue::from_str(&session_cookie(&generated.token, ttl_seconds))
            .expect("admin session cookie contains only header-safe characters"),
    );

    Ok(response)
}

fn record_login_failure_error(
    state: &ControlPlaneState,
    key: &AdminLoginFailureRateLimitKey,
    now_epoch_seconds: u64,
    policy: LoginFailureRateLimitPolicy,
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

async fn oidc_authorize_url() -> Result<Response, AuthError> {
    let config = OidcAuthorizeConfig::from_env().map_err(|_| AuthError::oidc_unavailable())?;
    let response = oidc_authorize_response(&config);

    Ok(Json(json!({ "data": response })).into_response())
}

async fn oidc_callback(
    Query(query): Query<BTreeMap<String, String>>,
) -> Result<Response, AuthError> {
    let _config = OidcAuthorizeConfig::from_env().map_err(|_| AuthError::oidc_unavailable())?;

    Err(oidc_callback_error(&query))
}

async fn me(session: AdminSession) -> Result<Response, AuthError> {
    Ok(Json(json!({
        "data": session.me_response()
    }))
    .into_response())
}

async fn logout(
    State(state): State<Arc<ControlPlaneState>>,
    session: AdminSession,
) -> Result<Response, AuthError> {
    AuthRepository::new(state.db().clone())
        .revoke_session(session.tenant_id(), session.session_id())
        .await?;

    let mut response = Json(json!({ "data": { "logged_out": true } })).into_response();
    response.headers_mut().insert(
        SET_COOKIE,
        HeaderValue::from_str(&clear_session_cookie())
            .expect("clear session cookie contains only header-safe characters"),
    );
    Ok(response)
}

fn session_ttl_seconds() -> i32 {
    std::env::var("AI_GATEWAY_ADMIN_SESSION_TTL_SECONDS")
        .ok()
        .and_then(|value| value.parse::<i32>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(DEFAULT_SESSION_TTL_SECONDS)
}

fn login_failure_rate_limit_policy() -> LoginFailureRateLimitPolicy {
    LoginFailureRateLimitPolicy::new(
        env_u32(ADMIN_LOGIN_FAILURE_LIMIT_ENV, DEFAULT_LOGIN_FAILURE_LIMIT),
        env_u64(
            ADMIN_LOGIN_FAILURE_WINDOW_SECONDS_ENV,
            DEFAULT_LOGIN_FAILURE_WINDOW_SECONDS,
        ),
    )
    .sanitized()
}

fn env_u32(key: &str, default: u32) -> u32 {
    std::env::var(key)
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(default)
}

fn env_u64(key: &str, default: u64) -> u64 {
    std::env::var(key)
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(default)
}

fn current_epoch_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn user_agent(headers: &HeaderMap) -> Option<String> {
    let user_agent = headers.get(USER_AGENT)?.to_str().ok()?.trim();
    if user_agent.is_empty() {
        return None;
    }

    Some(user_agent.chars().take(MAX_USER_AGENT_LEN).collect())
}

pub(crate) fn session_cookie(token: &str, ttl_seconds: i32) -> String {
    session_cookie_with_secure(token, ttl_seconds, secure_admin_cookie_enabled())
}

fn session_cookie_with_secure(token: &str, ttl_seconds: i32, secure: bool) -> String {
    format!(
        "{ADMIN_SESSION_COOKIE}={token}; Path=/; HttpOnly; SameSite=Lax; Max-Age={ttl_seconds}{}",
        secure_cookie_suffix(secure)
    )
}

pub(crate) fn clear_session_cookie() -> String {
    clear_session_cookie_with_secure(secure_admin_cookie_enabled())
}

fn clear_session_cookie_with_secure(secure: bool) -> String {
    format!(
        "{ADMIN_SESSION_COOKIE}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT{}",
        secure_cookie_suffix(secure)
    )
}

fn secure_cookie_suffix(secure: bool) -> &'static str {
    if secure { "; Secure" } else { "" }
}

fn secure_admin_cookie_enabled() -> bool {
    match std::env::var(ADMIN_COOKIE_SECURE_ENV) {
        Ok(value) => truthy_env_value(&value),
        Err(_) => std::env::var("AI_GATEWAY_ENV")
            .map(|value| {
                matches!(
                    value.trim().to_ascii_lowercase().as_str(),
                    "prod" | "production"
                )
            })
            .unwrap_or(false),
    }
}

fn truthy_env_value(value: &str) -> bool {
    matches!(
        value.trim().to_ascii_lowercase().as_str(),
        "1" | "true" | "yes" | "on"
    )
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct OidcAuthorizeConfig {
    provider: String,
    authorization_endpoint: String,
    client_id: String,
    redirect_uri: String,
    scopes: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum OidcAuthorizeConfigError {
    Disabled,
    Missing,
    Invalid,
}

impl OidcAuthorizeConfig {
    fn from_env() -> Result<Self, OidcAuthorizeConfigError> {
        Self::from_vars(std::env::vars())
    }

    fn from_vars<I, K, V>(vars: I) -> Result<Self, OidcAuthorizeConfigError>
    where
        I: IntoIterator<Item = (K, V)>,
        K: Into<String>,
        V: Into<String>,
    {
        let vars = vars
            .into_iter()
            .map(|(key, value)| (key.into(), value.into()))
            .collect::<BTreeMap<_, _>>();

        if !truthy_env_value(
            get_env(&vars, "AI_GATEWAY_OIDC_ENABLED").ok_or(OidcAuthorizeConfigError::Disabled)?,
        ) {
            return Err(OidcAuthorizeConfigError::Disabled);
        }

        let provider = get_env(&vars, "AI_GATEWAY_OIDC_PROVIDER")
            .unwrap_or("default")
            .to_string();
        let authorization_endpoint =
            required_env(&vars, "AI_GATEWAY_OIDC_AUTHORIZATION_ENDPOINT")?.to_string();
        let client_id = required_env(&vars, "AI_GATEWAY_OIDC_CLIENT_ID")?.to_string();
        let redirect_uri = required_env(&vars, "AI_GATEWAY_OIDC_REDIRECT_URI")?.to_string();
        let scopes = oidc_scopes(
            get_env(&vars, "AI_GATEWAY_OIDC_SCOPES").unwrap_or("openid email profile"),
        )?;

        validate_oidc_provider_slug(&provider)?;
        validate_public_oauth_url(&authorization_endpoint, true)?;
        validate_public_oauth_url(&redirect_uri, false)?;
        validate_oauth_tokenish_value(&client_id)?;

        Ok(Self {
            provider,
            authorization_endpoint,
            client_id,
            redirect_uri,
            scopes,
        })
    }
}

fn oidc_authorize_response(config: &OidcAuthorizeConfig) -> OidcAuthorizeResponse {
    let state = oidc_random_value();
    let nonce = oidc_random_value();
    let scope = config.scopes.join(" ");
    let authorization_url = oauth_url_with_query(
        &config.authorization_endpoint,
        &[
            ("response_type", "code"),
            ("client_id", config.client_id.as_str()),
            ("redirect_uri", config.redirect_uri.as_str()),
            ("scope", scope.as_str()),
            ("state", state.as_str()),
            ("nonce", nonce.as_str()),
        ],
    );

    OidcAuthorizeResponse {
        provider: config.provider.clone(),
        authorization_url,
        state,
        nonce,
        scopes: config.scopes.clone(),
        response_type: "code",
        state_ttl_seconds: 300,
        server_state_persisted: false,
        callback_implemented: false,
    }
}

fn oidc_callback_error(query: &BTreeMap<String, String>) -> AuthError {
    if oidc_callback_contains_direct_claims(query) {
        AuthError::oidc_claims_not_accepted()
    } else {
        AuthError::oidc_state_not_persisted()
    }
}

fn oidc_callback_contains_direct_claims(query: &BTreeMap<String, String>) -> bool {
    callback_contains_direct_federated_credentials(query)
}

fn callback_contains_direct_federated_credentials(query: &BTreeMap<String, String>) -> bool {
    query.keys().any(|key| {
        matches!(
            key.trim().to_ascii_lowercase().as_str(),
            "access_token"
                | "assertion"
                | "authorization"
                | "claims"
                | "email"
                | "groups"
                | "id_token"
                | "name"
                | "preferred_username"
                | "refresh_token"
                | "roles"
                | "saml_assertion"
                | "saml_response"
                | "samlresponse"
                | "sub"
                | "token"
                | "userinfo"
                | "user_info"
        )
    })
}

#[cfg(test)]
const MAX_FEDERATED_CLAIM_NAME_LEN: usize = 64;
#[cfg(test)]
const MAX_FEDERATED_CLAIM_VALUE_LEN: usize = 256;
#[cfg(test)]
const MAX_FEDERATED_TRUST_VALUE_LEN: usize = 512;
#[cfg(test)]
const MAX_SAML_METADATA_XML_BYTES: usize = 128 * 1024;

#[cfg(test)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FederatedAuthProtocol {
    Oidc,
    Saml,
}

#[cfg(test)]
impl FederatedAuthProtocol {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Oidc => "oidc",
            Self::Saml => "saml",
        }
    }
}

#[cfg(test)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FederatedClaimSource {
    ServerVerifiedOidcIdToken,
    ServerVerifiedOidcUserInfo,
    ServerVerifiedSamlAssertion,
    ClientSubmittedCallback,
}

#[cfg(test)]
impl FederatedClaimSource {
    const fn is_server_verified_for(self, protocol: FederatedAuthProtocol) -> bool {
        matches!(
            (protocol, self),
            (
                FederatedAuthProtocol::Oidc,
                FederatedClaimSource::ServerVerifiedOidcIdToken
                    | FederatedClaimSource::ServerVerifiedOidcUserInfo
            ) | (
                FederatedAuthProtocol::Saml,
                FederatedClaimSource::ServerVerifiedSamlAssertion
            )
        )
    }
}

#[cfg(test)]
#[derive(Debug, Clone, PartialEq, Eq)]
struct FederatedAuthClaimInput<'a> {
    protocol: FederatedAuthProtocol,
    source: FederatedClaimSource,
    issuer: Option<&'a str>,
    audiences: &'a [&'a str],
    email: Option<&'a str>,
    role_claim_values: &'a [&'a str],
    group_claim_values: &'a [&'a str],
}

#[cfg(test)]
#[derive(Debug, Clone, PartialEq, Eq)]
struct FederatedAuthMappingConfig {
    role_claim_names: Vec<String>,
    group_claim_names: Vec<String>,
    allowed_issuers: Vec<String>,
    allowed_audiences: Vec<String>,
    allowed_email_domains: Vec<String>,
    role_value_mapping: BTreeMap<String, Role>,
    group_value_mapping: BTreeMap<String, Role>,
}

#[cfg(test)]
impl FederatedAuthMappingConfig {
    fn validate(&self) -> Result<(), FederatedAuthMappingConfigError> {
        if self.allowed_issuers.is_empty()
            || self.allowed_audiences.is_empty()
            || self.allowed_email_domains.is_empty()
        {
            return Err(FederatedAuthMappingConfigError::MissingTrustBoundary);
        }
        if self.role_value_mapping.is_empty() && self.group_value_mapping.is_empty() {
            return Err(FederatedAuthMappingConfigError::MissingMapping);
        }

        for claim_name in self
            .role_claim_names
            .iter()
            .chain(self.group_claim_names.iter())
        {
            validate_federated_claim_name(claim_name)?;
        }
        for value in self
            .allowed_issuers
            .iter()
            .chain(self.allowed_audiences.iter())
        {
            validate_federated_trust_value(value)?;
        }
        for domain in &self.allowed_email_domains {
            validate_email_domain(domain)?;
        }
        for value in self
            .role_value_mapping
            .keys()
            .chain(self.group_value_mapping.keys())
        {
            normalize_federated_claim_value(value)?;
        }

        Ok(())
    }

    fn has_mapping(&self) -> bool {
        !self.role_value_mapping.is_empty() || !self.group_value_mapping.is_empty()
    }
}

#[cfg(test)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FederatedAuthMappingConfigError {
    MissingTrustBoundary,
    MissingMapping,
    InvalidClaimName,
    InvalidTrustValue,
    InvalidEmailDomain,
    InvalidClaimValue,
}

#[cfg(test)]
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct FederatedAuthMappingDecision {
    protocol: &'static str,
    accepted: bool,
    mapped_roles: Vec<&'static str>,
    denied_reasons: Vec<&'static str>,
    trust_checks: FederatedAuthTrustCheckSummary,
    ignored_unmapped_role_values: usize,
    ignored_unmapped_group_values: usize,
    secret_safe: bool,
    claim_values_returned: bool,
    token_values_returned: bool,
    authorization_header_returned: bool,
}

#[cfg(test)]
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct FederatedAuthTrustCheckSummary {
    requires_server_verified_claims: bool,
    source_server_verified: bool,
    issuer_allowlist_configured: bool,
    issuer_allowed: bool,
    audience_allowlist_configured: bool,
    audience_allowed: bool,
    email_domain_allowlist_configured: bool,
    email_domain_allowed: bool,
    mapping_configured: bool,
    default_deny: bool,
    direct_client_claims_allowed: bool,
    token_exchange_implemented: bool,
    oidc_jwks_validation_implemented: bool,
    saml_xml_signature_validation_implemented: bool,
    session_creation_implemented: bool,
}

#[cfg(test)]
fn federated_auth_mapping_decision(
    config: &FederatedAuthMappingConfig,
    input: &FederatedAuthClaimInput<'_>,
) -> FederatedAuthMappingDecision {
    let config_valid = config.validate().is_ok();
    let mapping_configured = config.has_mapping();
    let source_server_verified = input.source.is_server_verified_for(input.protocol);
    let issuer_allowed = input
        .issuer
        .is_some_and(|issuer| trust_value_allowed(&config.allowed_issuers, issuer));
    let audience_allowed = input
        .audiences
        .iter()
        .any(|audience| trust_value_allowed(&config.allowed_audiences, audience));
    let email_domain_allowed = input.email.is_some_and(|email| {
        email_domain_from_email(email)
            .is_some_and(|domain| domain_allowed(&config.allowed_email_domains, &domain))
    });

    let mut denied_reasons = Vec::new();
    if !config_valid {
        push_unique_reason(&mut denied_reasons, "mapping_config_invalid");
    }
    if !source_server_verified {
        push_unique_reason(&mut denied_reasons, "client_submitted_claims_not_accepted");
    }
    if !issuer_allowed {
        push_unique_reason(&mut denied_reasons, "issuer_not_allowed");
    }
    if !audience_allowed {
        push_unique_reason(&mut denied_reasons, "audience_not_allowed");
    }
    if !email_domain_allowed {
        push_unique_reason(&mut denied_reasons, "email_domain_not_allowed");
    }

    let mut mapped_roles = Vec::new();
    let mut ignored_unmapped_role_values = 0;
    let mut ignored_unmapped_group_values = 0;
    let mut claim_value_invalid = false;

    if config_valid {
        for value in input.role_claim_values {
            match normalize_federated_claim_value(value) {
                Ok(normalized) => match config.role_value_mapping.get(&normalized) {
                    Some(role) => push_unique_role(&mut mapped_roles, *role),
                    None => ignored_unmapped_role_values += 1,
                },
                Err(_) => claim_value_invalid = true,
            }
        }
        for value in input.group_claim_values {
            match normalize_federated_claim_value(value) {
                Ok(normalized) => match config.group_value_mapping.get(&normalized) {
                    Some(role) => push_unique_role(&mut mapped_roles, *role),
                    None => ignored_unmapped_group_values += 1,
                },
                Err(_) => claim_value_invalid = true,
            }
        }
    }

    if claim_value_invalid {
        push_unique_reason(&mut denied_reasons, "claim_value_invalid");
    }
    if mapped_roles.is_empty() {
        push_unique_reason(&mut denied_reasons, "no_mapped_roles");
    }

    let accepted = denied_reasons.is_empty();
    let mapped_roles = if accepted {
        ordered_role_names(mapped_roles)
    } else {
        Vec::new()
    };

    FederatedAuthMappingDecision {
        protocol: input.protocol.as_str(),
        accepted,
        mapped_roles,
        denied_reasons,
        trust_checks: FederatedAuthTrustCheckSummary {
            requires_server_verified_claims: true,
            source_server_verified,
            issuer_allowlist_configured: !config.allowed_issuers.is_empty(),
            issuer_allowed,
            audience_allowlist_configured: !config.allowed_audiences.is_empty(),
            audience_allowed,
            email_domain_allowlist_configured: !config.allowed_email_domains.is_empty(),
            email_domain_allowed,
            mapping_configured,
            default_deny: true,
            direct_client_claims_allowed: false,
            token_exchange_implemented: false,
            oidc_jwks_validation_implemented: false,
            saml_xml_signature_validation_implemented: false,
            session_creation_implemented: false,
        },
        ignored_unmapped_role_values,
        ignored_unmapped_group_values,
        secret_safe: true,
        claim_values_returned: false,
        token_values_returned: false,
        authorization_header_returned: false,
    }
}

#[cfg(test)]
fn push_unique_role(roles: &mut Vec<Role>, role: Role) {
    if !roles.contains(&role) {
        roles.push(role);
    }
}

#[cfg(test)]
fn ordered_role_names(roles: Vec<Role>) -> Vec<&'static str> {
    Role::ALL
        .iter()
        .copied()
        .filter(|role| roles.contains(role))
        .map(Role::as_str)
        .collect()
}

#[cfg(test)]
fn push_unique_reason(reasons: &mut Vec<&'static str>, reason: &'static str) {
    if !reasons.contains(&reason) {
        reasons.push(reason);
    }
}

#[cfg(test)]
fn trust_value_allowed(allowed: &[String], value: &str) -> bool {
    let trimmed = value.trim();
    !trimmed.is_empty() && allowed.iter().any(|allowed| allowed.trim() == trimmed)
}

#[cfg(test)]
fn domain_allowed(allowed_domains: &[String], domain: &str) -> bool {
    allowed_domains
        .iter()
        .any(|allowed| allowed.trim().eq_ignore_ascii_case(domain))
}

#[cfg(test)]
fn email_domain_from_email(email: &str) -> Option<String> {
    let trimmed = email.trim();
    let (local, domain) = trimmed.rsplit_once('@')?;
    if local.trim().is_empty() {
        return None;
    }
    validate_email_domain(domain).ok()?;

    Some(domain.trim().to_ascii_lowercase())
}

#[cfg(test)]
fn validate_federated_claim_name(claim_name: &str) -> Result<(), FederatedAuthMappingConfigError> {
    let trimmed = claim_name.trim();
    if trimmed.is_empty()
        || trimmed.len() > MAX_FEDERATED_CLAIM_NAME_LEN
        || trimmed.bytes().any(|byte| {
            !(byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.' | b':'))
        })
    {
        return Err(FederatedAuthMappingConfigError::InvalidClaimName);
    }

    Ok(())
}

#[cfg(test)]
fn validate_federated_trust_value(value: &str) -> Result<(), FederatedAuthMappingConfigError> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed.len() > MAX_FEDERATED_TRUST_VALUE_LEN
        || trimmed.contains('@')
        || trimmed
            .bytes()
            .any(|byte| byte.is_ascii_control() || byte.is_ascii_whitespace())
    {
        return Err(FederatedAuthMappingConfigError::InvalidTrustValue);
    }

    Ok(())
}

#[cfg(test)]
fn validate_email_domain(domain: &str) -> Result<(), FederatedAuthMappingConfigError> {
    let trimmed = domain.trim();
    if trimmed.is_empty()
        || trimmed.len() > 253
        || trimmed.starts_with('.')
        || trimmed.ends_with('.')
        || trimmed
            .bytes()
            .any(|byte| !(byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.')))
        || trimmed.split('.').any(|label| label.is_empty())
    {
        return Err(FederatedAuthMappingConfigError::InvalidEmailDomain);
    }

    Ok(())
}

#[cfg(test)]
fn normalize_federated_claim_value(value: &str) -> Result<String, FederatedAuthMappingConfigError> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed.len() > MAX_FEDERATED_CLAIM_VALUE_LEN
        || trimmed.bytes().any(|byte| byte.is_ascii_control())
        || looks_sensitive_claim_value(trimmed)
    {
        return Err(FederatedAuthMappingConfigError::InvalidClaimValue);
    }

    Ok(trimmed.to_ascii_lowercase())
}

#[cfg(test)]
fn looks_sensitive_claim_value(value: &str) -> bool {
    let lower = value.to_ascii_lowercase();
    lower.starts_with("bearer ")
        || lower.starts_with("eyj")
        || lower.starts_with("sk-")
        || lower.starts_with("ya29.")
        || lower.contains("-----begin")
}

#[cfg(test)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SamlMetadataSource<'a> {
    Url(&'a str),
    Xml(&'a str),
}

#[cfg(test)]
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct SamlMetadataSummary {
    source: &'static str,
    accepted: bool,
    metadata_url_origin: Option<String>,
    metadata_url_https: bool,
    entity_descriptor_present: bool,
    idp_sso_descriptor_present: bool,
    single_sign_on_service_count: usize,
    x509_certificate_count: usize,
    xml_size_bytes: Option<usize>,
    network_fetch_implemented: bool,
    xml_signature_validation_implemented: bool,
    xml_body_returned: bool,
    secret_safe: bool,
    denied_reasons: Vec<&'static str>,
}

#[cfg(test)]
fn saml_metadata_summary(source: SamlMetadataSource<'_>) -> SamlMetadataSummary {
    match source {
        SamlMetadataSource::Url(raw) => saml_metadata_url_summary(raw),
        SamlMetadataSource::Xml(raw) => saml_metadata_xml_summary(raw),
    }
}

#[cfg(test)]
fn saml_metadata_url_summary(raw: &str) -> SamlMetadataSummary {
    let origin = saml_metadata_url_origin(raw);
    let mut denied_reasons = Vec::new();
    if origin.is_none() {
        push_unique_reason(&mut denied_reasons, "metadata_url_invalid");
    }

    SamlMetadataSummary {
        source: "url",
        accepted: denied_reasons.is_empty(),
        metadata_url_origin: origin,
        metadata_url_https: raw.trim().starts_with("https://"),
        entity_descriptor_present: false,
        idp_sso_descriptor_present: false,
        single_sign_on_service_count: 0,
        x509_certificate_count: 0,
        xml_size_bytes: None,
        network_fetch_implemented: false,
        xml_signature_validation_implemented: false,
        xml_body_returned: false,
        secret_safe: true,
        denied_reasons,
    }
}

#[cfg(test)]
fn saml_metadata_url_origin(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty()
        || trimmed.len() > 2048
        || !trimmed.starts_with("https://")
        || trimmed.contains('@')
        || trimmed.contains('#')
        || trimmed.contains('?')
        || trimmed
            .bytes()
            .any(|byte| byte.is_ascii_control() || byte.is_ascii_whitespace())
    {
        return None;
    }

    let without_scheme = &trimmed["https://".len()..];
    let authority = without_scheme
        .split('/')
        .next()
        .filter(|authority| !authority.is_empty())?;
    if authority.bytes().any(|byte| {
        !(byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b':' | b'[' | b']'))
    }) {
        return None;
    }

    Some(format!("https://{authority}"))
}

#[cfg(test)]
fn saml_metadata_xml_summary(raw: &str) -> SamlMetadataSummary {
    let lower = raw.to_ascii_lowercase();
    let entity_descriptor_present = lower.contains("entitydescriptor");
    let idp_sso_descriptor_present = lower.contains("idpssodescriptor");
    let single_sign_on_service_count = count_xml_start_tag(&lower, "singlesignonservice");
    let x509_certificate_count = count_xml_start_tag(&lower, "x509certificate");

    let mut denied_reasons = Vec::new();
    if raw.trim().is_empty()
        || raw.len() > MAX_SAML_METADATA_XML_BYTES
        || raw
            .bytes()
            .any(|byte| byte.is_ascii_control() && !matches!(byte, b'\n' | b'\r' | b'\t'))
    {
        push_unique_reason(&mut denied_reasons, "metadata_xml_invalid");
    }
    if lower.contains("<!doctype")
        || lower.contains("<!entity")
        || lower.contains(" system ")
        || lower.contains(" public ")
    {
        push_unique_reason(&mut denied_reasons, "metadata_xml_external_entity_rejected");
    }
    if !entity_descriptor_present {
        push_unique_reason(
            &mut denied_reasons,
            "metadata_xml_entity_descriptor_missing",
        );
    }

    SamlMetadataSummary {
        source: "xml",
        accepted: denied_reasons.is_empty(),
        metadata_url_origin: None,
        metadata_url_https: false,
        entity_descriptor_present,
        idp_sso_descriptor_present,
        single_sign_on_service_count,
        x509_certificate_count,
        xml_size_bytes: Some(raw.len()),
        network_fetch_implemented: false,
        xml_signature_validation_implemented: false,
        xml_body_returned: false,
        secret_safe: true,
        denied_reasons,
    }
}

#[cfg(test)]
fn count_xml_start_tag(lower_xml: &str, lower_tag_name: &str) -> usize {
    let mut count = 0;
    let mut offset = 0;
    while let Some(relative_index) = lower_xml[offset..].find(lower_tag_name) {
        let index = offset + relative_index;
        let Some(before_tag) = index
            .checked_sub(1)
            .and_then(|previous| lower_xml.as_bytes().get(previous))
        else {
            offset = index + lower_tag_name.len();
            continue;
        };
        if matches!(before_tag, b'<' | b':')
            && lower_xml[..index]
                .rfind('<')
                .is_some_and(|tag_start| lower_xml.as_bytes().get(tag_start + 1) != Some(&b'/'))
        {
            count += 1;
        }
        offset = index + lower_tag_name.len();
    }

    count
}

fn oidc_random_value() -> String {
    Uuid::new_v4().simple().to_string()
}

fn required_env<'a>(
    vars: &'a BTreeMap<String, String>,
    key: &str,
) -> Result<&'a str, OidcAuthorizeConfigError> {
    get_env(vars, key).ok_or(OidcAuthorizeConfigError::Missing)
}

fn get_env<'a>(vars: &'a BTreeMap<String, String>, key: &str) -> Option<&'a str> {
    vars.get(key)
        .map(String::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
}

fn oidc_scopes(raw: &str) -> Result<Vec<String>, OidcAuthorizeConfigError> {
    let mut scopes = Vec::new();
    for scope in raw.split_whitespace() {
        validate_oauth_tokenish_value(scope)?;
        if !scopes.iter().any(|existing| existing == scope) {
            scopes.push(scope.to_string());
        }
    }

    if !scopes.iter().any(|scope| scope == "openid") {
        scopes.insert(0, "openid".to_string());
    }

    Ok(scopes)
}

fn validate_oidc_provider_slug(provider: &str) -> Result<(), OidcAuthorizeConfigError> {
    if provider.is_empty()
        || provider.len() > 64
        || !provider
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return Err(OidcAuthorizeConfigError::Invalid);
    }

    Ok(())
}

fn validate_oauth_tokenish_value(value: &str) -> Result<(), OidcAuthorizeConfigError> {
    if value.is_empty()
        || value.len() > 256
        || value
            .bytes()
            .any(|byte| byte.is_ascii_control() || byte.is_ascii_whitespace())
    {
        return Err(OidcAuthorizeConfigError::Invalid);
    }

    Ok(())
}

fn validate_public_oauth_url(
    raw: &str,
    require_https: bool,
) -> Result<(), OidcAuthorizeConfigError> {
    let trimmed = raw.trim();
    if trimmed.is_empty()
        || trimmed.len() > 2048
        || trimmed
            .bytes()
            .any(|byte| byte.is_ascii_control() || byte.is_ascii_whitespace())
    {
        return Err(OidcAuthorizeConfigError::Invalid);
    }
    if trimmed.contains('@') {
        return Err(OidcAuthorizeConfigError::Invalid);
    }
    if require_https && !trimmed.starts_with("https://") {
        return Err(OidcAuthorizeConfigError::Invalid);
    }
    if !require_https && !trimmed.starts_with("https://") && !is_loopback_http_url(trimmed) {
        return Err(OidcAuthorizeConfigError::Invalid);
    }
    if trimmed.contains('#') {
        return Err(OidcAuthorizeConfigError::Invalid);
    }

    Ok(())
}

fn is_loopback_http_url(raw: &str) -> bool {
    raw.starts_with("http://localhost:")
        || raw.starts_with("http://127.0.0.1:")
        || raw.starts_with("http://[::1]:")
}

fn oauth_url_with_query(base: &str, params: &[(&str, &str)]) -> String {
    let separator = if base.contains('?') { '&' } else { '?' };
    let query = params
        .iter()
        .map(|(key, value)| format!("{key}={}", percent_encode_query_value(value)))
        .collect::<Vec<_>>()
        .join("&");
    format!("{base}{separator}{query}")
}

fn percent_encode_query_value(value: &str) -> String {
    let mut output = String::new();
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            output.push(byte as char);
        } else {
            output.push('%');
            output.push_str(&format!("{byte:02X}"));
        }
    }
    output
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SessionTokenCandidate {
    pub(crate) token: String,
    pub(crate) source: SessionTokenSource,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SessionTokenSource {
    AuthorizationBearer,
    AdminHeader,
    Cookie,
}

pub(crate) fn session_token_from_headers(
    headers: &HeaderMap,
) -> Result<Option<SessionTokenCandidate>, AuthError> {
    if let Some(token) = bearer_token(headers)? {
        return Ok(Some(SessionTokenCandidate {
            token,
            source: SessionTokenSource::AuthorizationBearer,
        }));
    }

    if let Some(token) = admin_session_header(headers)? {
        return Ok(Some(SessionTokenCandidate {
            token,
            source: SessionTokenSource::AdminHeader,
        }));
    }

    Ok(
        session_token_from_cookie(headers).map(|token| SessionTokenCandidate {
            token,
            source: SessionTokenSource::Cookie,
        }),
    )
}

fn bearer_token(headers: &HeaderMap) -> Result<Option<String>, AuthError> {
    let Some(header) = headers.get(AUTHORIZATION) else {
        return Ok(None);
    };
    let header = header
        .to_str()
        .map_err(|_| AuthError::unauthorized())?
        .trim();
    if header.is_empty() {
        return Ok(None);
    }

    let mut parts = header.split_whitespace();
    let Some(scheme) = parts.next() else {
        return Ok(None);
    };
    if !scheme.eq_ignore_ascii_case("bearer") {
        return Ok(None);
    }

    let token = parts.next().ok_or_else(AuthError::unauthorized)?;
    if parts.next().is_some() {
        return Err(AuthError::unauthorized());
    }
    Ok(Some(token.to_string()))
}

fn admin_session_header(headers: &HeaderMap) -> Result<Option<String>, AuthError> {
    let Some(header) = headers.get(ADMIN_SESSION_HEADER) else {
        return Ok(None);
    };
    let token = header
        .to_str()
        .map_err(|_| AuthError::unauthorized())?
        .trim();
    if token.is_empty() {
        return Ok(None);
    }

    Ok(Some(token.to_string()))
}

fn session_token_from_cookie(headers: &HeaderMap) -> Option<String> {
    let cookie = headers.get(COOKIE)?.to_str().ok()?;
    cookie_value(cookie, ADMIN_SESSION_COOKIE).map(str::to_string)
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

#[derive(Debug)]
pub(crate) struct AuthError {
    status: StatusCode,
    code: &'static str,
    message: &'static str,
    retry_after_seconds: Option<u64>,
}

impl AuthError {
    pub(crate) fn unauthorized() -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            code: "unauthorized",
            message: "admin session required",
            retry_after_seconds: None,
        }
    }

    pub(crate) fn forbidden() -> Self {
        Self {
            status: StatusCode::FORBIDDEN,
            code: "forbidden",
            message: "admin permission denied",
            retry_after_seconds: None,
        }
    }

    fn invalid_credentials() -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            code: "invalid_credentials",
            message: "invalid credentials",
            retry_after_seconds: None,
        }
    }

    fn login_rate_limited(retry_after_seconds: u64) -> Self {
        Self {
            status: StatusCode::TOO_MANY_REQUESTS,
            code: "login_rate_limited",
            message: "too many login attempts",
            retry_after_seconds: Some(retry_after_seconds.max(1)),
        }
    }

    fn oidc_unavailable() -> Self {
        Self {
            status: StatusCode::SERVICE_UNAVAILABLE,
            code: "oidc_unavailable",
            message: "oidc login is not configured",
            retry_after_seconds: None,
        }
    }

    fn oidc_state_not_persisted() -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            code: "oidc_state_not_persisted",
            message: "oidc callback requires server-side state and nonce validation",
            retry_after_seconds: None,
        }
    }

    fn oidc_claims_not_accepted() -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            code: "oidc_claims_not_accepted",
            message: "oidc callback does not accept caller-supplied claims",
            retry_after_seconds: None,
        }
    }

    fn service_unavailable() -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            code: "auth_service_error",
            message: "authentication service unavailable",
            retry_after_seconds: None,
        }
    }

    fn body(&self) -> Value {
        auth_error_body(self.code, self.message)
    }
}

impl From<AuthRepoError> for AuthError {
    fn from(error: AuthRepoError) -> Self {
        match error {
            AuthRepoError::Query => Self::service_unavailable(),
        }
    }
}

impl IntoResponse for AuthError {
    fn into_response(self) -> Response {
        let retry_after_seconds = self.retry_after_seconds;
        let mut response = (self.status, Json(self.body())).into_response();
        if let Some(retry_after_seconds) = retry_after_seconds {
            response.headers_mut().insert(
                RETRY_AFTER,
                HeaderValue::from_str(&retry_after_seconds.to_string())
                    .expect("retry-after seconds are header-safe digits"),
            );
        }
        response
    }
}

fn auth_error_body(code: &'static str, message: &'static str) -> Value {
    json!({
        "error": {
            "code": code,
            "message": message
        }
    })
}

#[cfg(test)]
mod tests {
    use std::str::FromStr;

    use axum::http::header::HeaderName;

    use super::*;

    fn fixed_token(byte: char) -> String {
        format!("sess_{}", byte.to_string().repeat(64))
    }

    fn admin_session_with_roles(roles: Vec<Role>) -> AdminSession {
        AdminSession {
            inner: StoredAdminSession {
                id: Uuid::from_u128(10),
                expires_at: "2026-06-03T12:00:00Z".to_string(),
                user: StoredAdminUser {
                    id: Uuid::from_u128(20),
                    tenant_id: DEFAULT_TENANT_ID,
                    email: "admin@example.local".to_string(),
                    display_name: "Admin".to_string(),
                    password_hash: Some("pbkdf2-sha256-never-return".to_string()),
                    roles,
                },
            },
        }
    }

    fn fixture_string_array(value: &Value) -> Vec<String> {
        value
            .as_array()
            .expect("fixture value should be an array")
            .iter()
            .map(|value| {
                value
                    .as_str()
                    .expect("fixture array value should be a string")
                    .to_string()
            })
            .collect()
    }

    fn fixture_role_mapping(value: &Value) -> BTreeMap<String, Role> {
        value
            .as_object()
            .expect("fixture mapping should be an object")
            .iter()
            .map(|(claim_value, role)| {
                (
                    claim_value.clone(),
                    Role::from_str(role.as_str().expect("fixture role should be a string"))
                        .expect("fixture role should be supported"),
                )
            })
            .collect()
    }

    fn fixture_mapping_config(value: &Value) -> FederatedAuthMappingConfig {
        FederatedAuthMappingConfig {
            role_claim_names: fixture_string_array(&value["role_claim_names"]),
            group_claim_names: fixture_string_array(&value["group_claim_names"]),
            allowed_issuers: fixture_string_array(&value["allowed_issuers"]),
            allowed_audiences: fixture_string_array(&value["allowed_audiences"]),
            allowed_email_domains: fixture_string_array(&value["allowed_email_domains"]),
            role_value_mapping: fixture_role_mapping(&value["role_value_mapping"]),
            group_value_mapping: fixture_role_mapping(&value["group_value_mapping"]),
        }
    }

    fn auth_contract_fixture() -> Value {
        serde_json::from_str(include_str!(
            "../../../tests/fixtures/control-plane/oidc_saml_auth_contract.json"
        ))
        .expect("fixture should be valid json")
    }

    #[test]
    fn session_token_source_prefers_authorization_then_admin_header_then_cookie() {
        let bearer = fixed_token('a');
        let header = fixed_token('b');
        let cookie = fixed_token('c');
        let mut headers = HeaderMap::new();
        headers.insert(
            COOKIE,
            format!("{ADMIN_SESSION_COOKIE}={cookie}").parse().unwrap(),
        );
        headers.insert(
            HeaderName::from_static(ADMIN_SESSION_HEADER),
            header.parse().unwrap(),
        );
        headers.insert(AUTHORIZATION, format!("Bearer {bearer}").parse().unwrap());

        let candidate = session_token_from_headers(&headers)
            .expect("headers should parse")
            .expect("session token should be present");

        assert_eq!(candidate.token, bearer);
        assert_eq!(candidate.source, SessionTokenSource::AuthorizationBearer);

        headers.remove(AUTHORIZATION);
        let candidate = session_token_from_headers(&headers)
            .expect("headers should parse")
            .expect("session token should be present");

        assert_eq!(candidate.token, header);
        assert_eq!(candidate.source, SessionTokenSource::AdminHeader);

        headers.remove(HeaderName::from_static(ADMIN_SESSION_HEADER));
        let candidate = session_token_from_headers(&headers)
            .expect("headers should parse")
            .expect("session token should be present");

        assert_eq!(candidate.token, cookie);
        assert_eq!(candidate.source, SessionTokenSource::Cookie);
    }

    #[test]
    fn parses_session_cookie_from_multi_cookie_header() {
        let token = fixed_token('d');
        let mut headers = HeaderMap::new();
        headers.insert(
            COOKIE,
            format!("theme=dark; {ADMIN_SESSION_COOKIE}={token}; csrftoken=ignored")
                .parse()
                .unwrap(),
        );

        let candidate = session_token_from_headers(&headers)
            .expect("headers should parse")
            .expect("session token should be present");

        assert_eq!(candidate.token, token);
        assert_eq!(candidate.source, SessionTokenSource::Cookie);
    }

    #[test]
    fn login_failure_error_body_redacts_credentials_and_tokens() {
        let body = AuthError::invalid_credentials().body().to_string();

        assert!(!body.contains("admin@example.com"));
        assert!(!body.contains("correct horse battery staple"));
        assert!(!body.contains("sess_aaaaaaaa"));
        assert!(!body.contains("pbkdf2-sha256"));
        assert!(body.contains("invalid_credentials"));
    }

    #[test]
    fn me_response_includes_secret_safe_capability_summary() {
        let response = admin_session_with_roles(vec![Role::Viewer]).me_response();
        let payload = serde_json::to_value(response).expect("me response should serialize");

        assert_eq!(payload["user"]["roles"], json!(["viewer"]));
        assert_eq!(payload["capability_summary"]["personas"], json!(["Viewer"]));
        assert_eq!(payload["capability_summary"]["secret_safe"], json!(true));
        assert!(
            payload["capability_summary"]["capabilities"]
                .as_array()
                .expect("capabilities should be an array")
                .iter()
                .any(|capability| capability.as_str() == Some("request_log.read"))
        );
        assert!(
            payload["capability_summary"]["denied_capabilities"]
                .as_array()
                .expect("denied capabilities should be an array")
                .iter()
                .any(|capability| capability.as_str() == Some("key.read"))
        );

        let serialized = payload.to_string();
        for forbidden in [
            "session_token_once",
            "pbkdf2-sha256",
            "provider_manage",
            "key_manage",
            "billing_adjust",
            "log_read_metadata",
            "permissions",
            "sess_",
        ] {
            assert!(
                !serialized.contains(forbidden),
                "/admin/auth/me response must not expose {forbidden}"
            );
        }
    }

    #[test]
    fn rate_limited_login_error_is_429_and_redacts_credentials_and_tokens() {
        let error = AuthError::login_rate_limited(42);
        let body = error.body().to_string();

        assert_eq!(error.status, StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(error.retry_after_seconds, Some(42));
        assert!(!body.contains("admin@example.com"));
        assert!(!body.contains("correct horse battery staple"));
        assert!(!body.contains("sess_aaaaaaaa"));
        assert!(!body.contains("pbkdf2-sha256"));
        assert!(!body.contains("password"));
        assert!(body.contains("login_rate_limited"));

        let response = error.into_response();
        assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(response.headers().get(RETRY_AFTER).unwrap(), "42");
    }

    #[test]
    fn oidc_authorize_url_contains_required_oauth_parameters() {
        let config = OidcAuthorizeConfig::from_vars([
            ("AI_GATEWAY_OIDC_ENABLED", "true"),
            ("AI_GATEWAY_OIDC_PROVIDER", "acme"),
            (
                "AI_GATEWAY_OIDC_AUTHORIZATION_ENDPOINT",
                "https://issuer.example.com/oauth2/v1/authorize",
            ),
            ("AI_GATEWAY_OIDC_CLIENT_ID", "ai-gateway-admin"),
            (
                "AI_GATEWAY_OIDC_REDIRECT_URI",
                "http://localhost:5173/admin/auth/oidc/callback",
            ),
            ("AI_GATEWAY_OIDC_SCOPES", "openid email profile email"),
        ])
        .expect("oidc config should parse");

        let response = oidc_authorize_response(&config);

        assert_eq!(response.provider, "acme");
        assert_eq!(response.scopes, vec!["openid", "email", "profile"]);
        assert_eq!(response.response_type, "code");
        assert!(!response.server_state_persisted);
        assert!(!response.callback_implemented);
        assert_eq!(response.state.len(), 32);
        assert_eq!(response.nonce.len(), 32);
        assert!(
            response
                .authorization_url
                .starts_with("https://issuer.example.com/oauth2/v1/authorize?response_type=code")
        );
        assert!(
            response
                .authorization_url
                .contains("client_id=ai-gateway-admin")
        );
        assert!(response.authorization_url.contains(
            "redirect_uri=http%3A%2F%2Flocalhost%3A5173%2Fadmin%2Fauth%2Foidc%2Fcallback"
        ));
        assert!(
            response
                .authorization_url
                .contains("scope=openid%20email%20profile")
        );
        assert!(
            response
                .authorization_url
                .contains(&format!("state={}", response.state))
        );
        assert!(
            response
                .authorization_url
                .contains(&format!("nonce={}", response.nonce))
        );
    }

    #[test]
    fn oidc_authorize_config_rejects_unsafe_urls_and_missing_enabled_flag() {
        assert_eq!(
            OidcAuthorizeConfig::from_vars(std::iter::empty::<(&str, &str)>()).unwrap_err(),
            OidcAuthorizeConfigError::Disabled
        );

        let insecure_authorization = OidcAuthorizeConfig::from_vars([
            ("AI_GATEWAY_OIDC_ENABLED", "true"),
            (
                "AI_GATEWAY_OIDC_AUTHORIZATION_ENDPOINT",
                "http://issuer.example.com/authorize",
            ),
            ("AI_GATEWAY_OIDC_CLIENT_ID", "client"),
            (
                "AI_GATEWAY_OIDC_REDIRECT_URI",
                "https://admin.example.com/callback",
            ),
        ]);
        assert_eq!(
            insecure_authorization.unwrap_err(),
            OidcAuthorizeConfigError::Invalid
        );

        let remote_http_redirect = OidcAuthorizeConfig::from_vars([
            ("AI_GATEWAY_OIDC_ENABLED", "true"),
            (
                "AI_GATEWAY_OIDC_AUTHORIZATION_ENDPOINT",
                "https://issuer.example.com/authorize",
            ),
            ("AI_GATEWAY_OIDC_CLIENT_ID", "client"),
            (
                "AI_GATEWAY_OIDC_REDIRECT_URI",
                "http://admin.example.com/callback",
            ),
        ]);
        assert_eq!(
            remote_http_redirect.unwrap_err(),
            OidcAuthorizeConfigError::Invalid
        );
    }

    #[test]
    fn oidc_error_body_does_not_echo_provider_config() {
        let body = AuthError::oidc_unavailable().body().to_string();

        assert!(!body.contains("client-secret"));
        assert!(!body.contains("issuer.example.com"));
        assert!(body.contains("oidc_unavailable"));
    }

    #[test]
    fn oidc_callback_rejects_without_server_side_state_and_redacts_code() {
        let query = BTreeMap::from([
            ("code".to_string(), "provider-code-never-return".to_string()),
            (
                "state".to_string(),
                "browser-state-never-return".to_string(),
            ),
        ]);

        let error = oidc_callback_error(&query);
        let body = error.body().to_string();

        assert_eq!(error.status, StatusCode::BAD_REQUEST);
        assert_eq!(error.code, "oidc_state_not_persisted");
        assert!(!body.contains("provider-code-never-return"));
        assert!(!body.contains("browser-state-never-return"));
        assert!(!body.contains("client-secret"));
        assert!(!body.contains("issuer.example.com"));
    }

    #[test]
    fn oidc_callback_rejects_direct_claims_login_and_redacts_tokens() {
        let query = BTreeMap::from([
            (
                "id_token".to_string(),
                "eyJhbGciOi-never-return".to_string(),
            ),
            ("email".to_string(), "admin@example.local".to_string()),
            ("roles".to_string(), "owner".to_string()),
            ("access_token".to_string(), "ya29.never-return".to_string()),
        ]);

        let error = oidc_callback_error(&query);
        let body = error.body().to_string();

        assert_eq!(error.status, StatusCode::BAD_REQUEST);
        assert_eq!(error.code, "oidc_claims_not_accepted");
        assert!(!body.contains("eyJhbGciOi-never-return"));
        assert!(!body.contains("admin@example.local"));
        assert!(!body.contains("owner"));
        assert!(!body.contains("ya29.never-return"));
        assert!(body.contains("oidc_claims_not_accepted"));
    }

    #[test]
    fn oidc_auth_role_group_mapping_accepts_only_verified_claims_with_trust_checks() {
        let fixture = auth_contract_fixture();
        let config = fixture_mapping_config(&fixture["oidc"]["mapping"]);
        let case = &fixture["oidc"]["accepted_server_verified_claims"];
        let audiences = fixture_string_array(&case["audiences"]);
        let audience_refs = audiences.iter().map(String::as_str).collect::<Vec<_>>();
        let role_claim_values = fixture_string_array(&case["role_claim_values"]);
        let role_refs = role_claim_values
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>();
        let group_claim_values = fixture_string_array(&case["group_claim_values"]);
        let group_refs = group_claim_values
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>();

        let input = FederatedAuthClaimInput {
            protocol: FederatedAuthProtocol::Oidc,
            source: FederatedClaimSource::ServerVerifiedOidcIdToken,
            issuer: case["issuer"].as_str(),
            audiences: &audience_refs,
            email: case["email"].as_str(),
            role_claim_values: &role_refs,
            group_claim_values: &group_refs,
        };

        let decision = federated_auth_mapping_decision(&config, &input);
        let mapped_roles = decision
            .mapped_roles
            .iter()
            .map(|role| role.to_string())
            .collect::<Vec<_>>();
        let serialized = serde_json::to_string(&decision).expect("decision should serialize");

        assert!(decision.accepted);
        assert_eq!(
            mapped_roles,
            fixture_string_array(&case["expected_mapped_roles"])
        );
        assert!(decision.trust_checks.requires_server_verified_claims);
        assert!(decision.trust_checks.source_server_verified);
        assert!(decision.trust_checks.issuer_allowed);
        assert!(decision.trust_checks.audience_allowed);
        assert!(decision.trust_checks.email_domain_allowed);
        assert!(decision.trust_checks.default_deny);
        assert!(!decision.trust_checks.direct_client_claims_allowed);
        assert!(!decision.trust_checks.token_exchange_implemented);
        assert!(!decision.trust_checks.oidc_jwks_validation_implemented);
        assert!(!decision.trust_checks.session_creation_implemented);
        assert!(decision.secret_safe);
        assert!(!decision.claim_values_returned);
        assert!(!decision.token_values_returned);
        assert!(!decision.authorization_header_returned);

        for forbidden in [
            "admin@example.com",
            "control-plane-ops",
            "ai-gateway-viewers",
            "provider-code-never-return",
            "eyJ-never-return",
            "ya29.never-return",
        ] {
            assert!(
                !serialized.contains(forbidden),
                "mapping decision must not echo {forbidden}"
            );
        }
    }

    #[test]
    fn oidc_auth_role_group_mapping_defaults_deny_for_client_claims_and_unknown_values() {
        let fixture = auth_contract_fixture();
        let config = fixture_mapping_config(&fixture["oidc"]["mapping"]);
        let audiences = ["ai-gateway-admin"];
        let direct_roles = ["control-plane-admin"];
        let direct_groups = ["ai-gateway-viewers"];
        let direct_input = FederatedAuthClaimInput {
            protocol: FederatedAuthProtocol::Oidc,
            source: FederatedClaimSource::ClientSubmittedCallback,
            issuer: Some("https://issuer.example.com"),
            audiences: &audiences,
            email: Some("admin@example.com"),
            role_claim_values: &direct_roles,
            group_claim_values: &direct_groups,
        };

        let direct_decision = federated_auth_mapping_decision(&config, &direct_input);
        assert!(!direct_decision.accepted);
        assert!(direct_decision.mapped_roles.is_empty());
        assert!(
            direct_decision
                .denied_reasons
                .contains(&"client_submitted_claims_not_accepted")
        );
        assert!(!direct_decision.trust_checks.source_server_verified);
        assert!(!direct_decision.trust_checks.direct_client_claims_allowed);

        let unknown_roles = ["unknown-admin"];
        let unknown_groups = ["unknown-group"];
        let unknown_input = FederatedAuthClaimInput {
            protocol: FederatedAuthProtocol::Oidc,
            source: FederatedClaimSource::ServerVerifiedOidcUserInfo,
            issuer: Some("https://issuer.example.com"),
            audiences: &audiences,
            email: Some("admin@example.com"),
            role_claim_values: &unknown_roles,
            group_claim_values: &unknown_groups,
        };

        let unknown_decision = federated_auth_mapping_decision(&config, &unknown_input);
        assert!(!unknown_decision.accepted);
        assert!(unknown_decision.mapped_roles.is_empty());
        assert!(unknown_decision.denied_reasons.contains(&"no_mapped_roles"));
        assert_eq!(unknown_decision.ignored_unmapped_role_values, 1);
        assert_eq!(unknown_decision.ignored_unmapped_group_values, 1);
    }

    #[test]
    fn auth_callback_rejects_saml_assertion_authorization_and_redacts_values() {
        let query = BTreeMap::from([
            (
                "SAMLResponse".to_string(),
                "base64-saml-response-never-return".to_string(),
            ),
            (
                "Authorization".to_string(),
                "Bearer callback-token-never-return".to_string(),
            ),
            (
                "assertion".to_string(),
                "<Assertion>never-return</Assertion>".to_string(),
            ),
        ]);

        let error = oidc_callback_error(&query);
        let body = error.body().to_string();

        assert_eq!(error.status, StatusCode::BAD_REQUEST);
        assert_eq!(error.code, "oidc_claims_not_accepted");
        assert!(!body.contains("base64-saml-response-never-return"));
        assert!(!body.contains("callback-token-never-return"));
        assert!(!body.contains("<Assertion>never-return</Assertion>"));
        assert!(!body.contains("Bearer"));
    }

    #[test]
    fn auth_saml_role_group_mapping_and_metadata_summary_are_secret_safe() {
        let fixture = auth_contract_fixture();
        let config = fixture_mapping_config(&fixture["saml"]["mapping"]);
        let case = &fixture["saml"]["accepted_server_verified_claims"];
        let audiences = fixture_string_array(&case["audiences"]);
        let audience_refs = audiences.iter().map(String::as_str).collect::<Vec<_>>();
        let role_claim_values = fixture_string_array(&case["role_claim_values"]);
        let role_refs = role_claim_values
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>();
        let group_claim_values = fixture_string_array(&case["group_claim_values"]);
        let group_refs = group_claim_values
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>();

        let input = FederatedAuthClaimInput {
            protocol: FederatedAuthProtocol::Saml,
            source: FederatedClaimSource::ServerVerifiedSamlAssertion,
            issuer: case["issuer"].as_str(),
            audiences: &audience_refs,
            email: case["email"].as_str(),
            role_claim_values: &role_refs,
            group_claim_values: &group_refs,
        };

        let decision = federated_auth_mapping_decision(&config, &input);
        let mapped_roles = decision
            .mapped_roles
            .iter()
            .map(|role| role.to_string())
            .collect::<Vec<_>>();
        assert!(decision.accepted);
        assert_eq!(
            mapped_roles,
            fixture_string_array(&case["expected_mapped_roles"])
        );
        assert!(
            !decision
                .trust_checks
                .saml_xml_signature_validation_implemented
        );

        let metadata_url = fixture["saml"]["metadata_url"]["input"]
            .as_str()
            .expect("metadata URL fixture should be a string");
        let url_summary = saml_metadata_summary(SamlMetadataSource::Url(metadata_url));
        assert!(url_summary.accepted);
        assert_eq!(
            url_summary.metadata_url_origin.as_deref(),
            Some("https://idp.example.com")
        );
        assert!(url_summary.metadata_url_https);
        assert!(!url_summary.network_fetch_implemented);
        assert!(!url_summary.xml_signature_validation_implemented);
        assert!(!url_summary.xml_body_returned);

        let metadata_xml = fixture["saml"]["metadata_xml"]["input"]
            .as_str()
            .expect("metadata XML fixture should be a string");
        let xml_summary = saml_metadata_summary(SamlMetadataSource::Xml(metadata_xml));
        let serialized_xml_summary =
            serde_json::to_string(&xml_summary).expect("summary should serialize");
        assert!(xml_summary.accepted);
        assert!(xml_summary.entity_descriptor_present);
        assert!(xml_summary.idp_sso_descriptor_present);
        assert_eq!(xml_summary.single_sign_on_service_count, 1);
        assert_eq!(xml_summary.x509_certificate_count, 1);
        assert!(!serialized_xml_summary.contains(metadata_xml));
        assert!(!serialized_xml_summary.contains("MIID-public-cert-placeholder"));

        let bad_url = saml_metadata_summary(SamlMetadataSource::Url(
            "https://idp.example.com/metadata?token=never-return",
        ));
        assert!(!bad_url.accepted);
        assert!(bad_url.denied_reasons.contains(&"metadata_url_invalid"));
        assert!(bad_url.metadata_url_origin.is_none());

        let bad_xml = saml_metadata_summary(SamlMetadataSource::Xml(
            r#"<!DOCTYPE foo [ <!ENTITY xxe SYSTEM "file:///etc/passwd"> ]><foo/>"#,
        ));
        assert!(!bad_xml.accepted);
        assert!(
            bad_xml
                .denied_reasons
                .contains(&"metadata_xml_external_entity_rejected")
        );
        assert!(
            bad_xml
                .denied_reasons
                .contains(&"metadata_xml_entity_descriptor_missing")
        );
    }

    #[test]
    fn auth_oidc_saml_contract_fixture_matches_openapi_extension() {
        let fixture = auth_contract_fixture();
        let openapi = include_str!("../../../examples/openapi_admin_skeleton.yaml");

        assert_eq!(
            fixture["scenario"],
            json!("control_plane_oidc_saml_auth_contract")
        );
        assert_eq!(fixture["default_deny"], json!(true));
        assert_eq!(fixture["secret_safe"], json!(true));
        assert_eq!(
            fixture["oidc"]["remaining_gaps"][0],
            json!("server_side_state_nonce_persistence")
        );
        assert_eq!(
            fixture["saml"]["remaining_gaps"][0],
            json!("saml_xml_signature_validation")
        );
        assert!(openapi.contains("x-federated-auth-contract:"));
        assert!(
            openapi.contains("fixture: tests/fixtures/control-plane/oidc_saml_auth_contract.json")
        );
        assert!(openapi.contains("default_deny: true"));
        assert!(openapi.contains("direct_client_claims_allowed: false"));
        assert!(openapi.contains("FederatedAuthMappingDecision"));
        assert!(openapi.contains("SamlMetadataSummary"));
        assert!(openapi.contains("server_side_state_nonce_persistence"));
        assert!(openapi.contains("saml_xml_signature_validation"));
    }

    #[test]
    fn session_cookie_sets_browser_safety_attributes() {
        let cookie = session_cookie_with_secure(&fixed_token('e'), 3600, false);

        assert!(cookie.starts_with(ADMIN_SESSION_COOKIE));
        assert!(cookie.contains("; Path=/"));
        assert!(cookie.contains("; HttpOnly"));
        assert!(cookie.contains("; SameSite=Lax"));
        assert!(cookie.contains("; Max-Age=3600"));
        assert!(!cookie.contains("; Secure"));
    }

    #[test]
    fn clear_cookie_uses_matching_path_and_expires_immediately() {
        let cookie = clear_session_cookie_with_secure(false);

        assert!(cookie.starts_with(&format!("{ADMIN_SESSION_COOKIE}=;")));
        assert!(cookie.contains("; Path=/"));
        assert!(cookie.contains("; HttpOnly"));
        assert!(cookie.contains("; SameSite=Lax"));
        assert!(cookie.contains("; Max-Age=0"));
        assert!(!cookie.contains("; Secure"));
    }

    #[test]
    fn admin_cookie_secure_can_be_enabled_for_https_deployments() {
        let cookie = session_cookie_with_secure(&fixed_token('f'), 3600, true);
        let clear_cookie = clear_session_cookie_with_secure(true);

        assert!(cookie.ends_with("; Secure"));
        assert!(clear_cookie.ends_with("; Secure"));
    }
}
