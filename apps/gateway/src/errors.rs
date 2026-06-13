use ai_gateway_adapters::{AnthropicAdapterError, GeminiAdapterError, OpenAiAdapterError};
#[cfg(test)]
use ai_gateway_observability::REDACTED_SECRET;
use ai_gateway_observability::{redact_payload_value, redact_secrets};
use axum::{
    Json,
    http::{HeaderMap, HeaderValue, StatusCode, header::RETRY_AFTER},
    response::{IntoResponse, Response},
};
use serde_json::{Value, json};

#[derive(Debug, Clone)]
pub struct GatewayApiError {
    pub status: StatusCode,
    pub error_type: &'static str,
    pub code: &'static str,
    pub message: String,
    pub param: Option<&'static str>,
    pub owner: &'static str,
    pub stage: &'static str,
    pub retryable: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ErrorLogSummary {
    pub http_status: i32,
    pub error_owner: String,
    pub error_code: String,
    pub retryable: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderErrorNormalization {
    pub http_status: u16,
    pub error_type: String,
    pub code: String,
    pub message: String,
    pub param: Option<&'static str>,
    pub owner: String,
    pub stage: String,
    pub retryable: Option<bool>,
    pub provider_status: Option<u16>,
    pub category: String,
    pub action: String,
}

impl GatewayApiError {
    pub fn missing_authorization() -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            error_type: "authentication_error",
            code: "missing_authorization",
            message: "Authorization Bearer token is required".to_string(),
            param: Some("authorization"),
            owner: "client",
            stage: "auth",
            retryable: Some(false),
        }
    }

    pub fn invalid_authorization_scheme() -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            error_type: "authentication_error",
            code: "invalid_authorization_scheme",
            message: "Authorization header must use Bearer scheme".to_string(),
            param: Some("authorization"),
            owner: "client",
            stage: "auth",
            retryable: Some(false),
        }
    }

    pub fn invalid_api_key_format(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            error_type: "authentication_error",
            code: "invalid_api_key_format",
            message: message.into(),
            param: Some("authorization"),
            owner: "client",
            stage: "auth",
            retryable: Some(false),
        }
    }

    pub fn invalid_api_key() -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            error_type: "authentication_error",
            code: "invalid_api_key",
            message: "API key is invalid".to_string(),
            param: Some("authorization"),
            owner: "client",
            stage: "auth",
            retryable: Some(false),
        }
    }

    pub fn api_key_forbidden(status: &str) -> Self {
        let code = match status {
            "expired" => "api_key_expired",
            "disabled" => "api_key_disabled",
            "revoked" => "api_key_revoked",
            _ => "api_key_forbidden",
        };

        Self {
            status: StatusCode::FORBIDDEN,
            error_type: "permission_error",
            code,
            message: format!("API key status does not allow requests: {status}"),
            param: Some("authorization"),
            owner: "policy",
            stage: "auth",
            retryable: Some(false),
        }
    }

    pub fn api_key_ip_forbidden() -> Self {
        Self {
            status: StatusCode::FORBIDDEN,
            error_type: "permission_error",
            code: "api_key_ip_forbidden",
            message: "API key is not allowed from this IP address".to_string(),
            param: Some("authorization"),
            owner: "policy",
            stage: "auth",
            retryable: Some(false),
        }
    }

    pub fn api_key_rate_limited(dimension: &'static str) -> Self {
        Self {
            status: StatusCode::TOO_MANY_REQUESTS,
            error_type: "rate_limit_error",
            code: "api_key_rate_limited",
            message: format!("API key rate limit exceeded for {dimension}"),
            param: Some("authorization"),
            owner: "policy",
            stage: "rate_limit",
            retryable: Some(true),
        }
    }

    pub fn api_key_profile_forbidden(status: &str) -> Self {
        Self {
            status: StatusCode::FORBIDDEN,
            error_type: "permission_error",
            code: "api_key_profile_forbidden",
            message: format!("API key profile status does not allow requests: {status}"),
            param: Some("authorization"),
            owner: "policy",
            stage: "auth",
            retryable: Some(false),
        }
    }

    pub fn api_key_profile_missing_default() -> Self {
        Self {
            status: StatusCode::FORBIDDEN,
            error_type: "permission_error",
            code: "api_key_profile_missing_default",
            message: "API key has no active default profile binding".to_string(),
            param: Some("authorization"),
            owner: "policy",
            stage: "auth",
            retryable: Some(false),
        }
    }

    pub fn database_unavailable() -> Self {
        Self {
            status: StatusCode::SERVICE_UNAVAILABLE,
            error_type: "gateway_error",
            code: "database_unavailable",
            message: "database is not connected; authenticated gateway routes are unavailable"
                .to_string(),
            param: None,
            owner: "gateway",
            stage: "database",
            retryable: Some(true),
        }
    }

    pub fn database_query_failed(operation: &'static str, error: impl std::fmt::Display) -> Self {
        let redacted_error = redact_secrets(&error.to_string());
        tracing::warn!(
            operation,
            error = %redacted_error,
            "gateway database operation failed"
        );

        Self {
            status: StatusCode::SERVICE_UNAVAILABLE,
            error_type: "gateway_error",
            code: "database_query_failed",
            message: format!("database operation `{operation}` failed"),
            param: None,
            owner: "gateway",
            stage: "database",
            retryable: Some(true),
        }
    }

    pub fn request_body_too_large(max_bytes: u64) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            error_type: "invalid_request_error",
            code: "request_body_too_large",
            message: format!("request body exceeds max_request_body_bytes ({max_bytes})"),
            param: Some("body"),
            owner: "client",
            stage: "request_validate",
            retryable: Some(false),
        }
    }

    pub fn prompt_protection_rejected() -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            error_type: "invalid_request_error",
            code: "prompt_protection_rejected",
            message: "Request was rejected by the prompt protection policy".to_string(),
            param: Some("messages"),
            owner: "policy",
            stage: "request_preflight",
            retryable: Some(false),
        }
    }

    pub fn model_not_found(model: &str) -> Self {
        let _ = model;
        Self {
            status: StatusCode::NOT_FOUND,
            error_type: "invalid_request_error",
            code: "model_not_found",
            message: "The requested model does not exist or is not available for this API key"
                .to_string(),
            param: Some("model"),
            owner: "policy",
            stage: "route",
            retryable: Some(false),
        }
    }

    pub fn route_no_candidate(model: &str) -> Self {
        let _ = model;
        Self {
            status: StatusCode::NOT_FOUND,
            error_type: "invalid_request_error",
            code: "route_no_candidate",
            message: "No enabled OpenAI-compatible route is available for the requested model"
                .to_string(),
            param: Some("model"),
            owner: "gateway",
            stage: "route",
            retryable: Some(false),
        }
    }

    pub fn billing_insufficient_balance() -> Self {
        Self {
            status: StatusCode::PAYMENT_REQUIRED,
            error_type: "billing_error",
            code: "billing_insufficient_balance",
            message: "Billing balance or budget is insufficient for this request".to_string(),
            param: None,
            owner: "billing",
            stage: "preauth",
            retryable: Some(false),
        }
    }

    pub fn to_openai_error_body(&self) -> Value {
        sanitize_error_body(json!({
            "error": {
                "message": self.message,
                "type": self.error_type,
                "param": self.param,
                "code": self.code
            },
            "gateway": {
                "error_owner": self.owner,
                "error_stage": self.stage,
                "retryable": self.retryable
            }
        }))
    }

    pub fn log_summary(&self) -> ErrorLogSummary {
        ErrorLogSummary {
            http_status: i32::from(self.status.as_u16()),
            error_owner: self.owner.to_string(),
            error_code: self.code.to_string(),
            retryable: self.retryable,
        }
    }
}

impl IntoResponse for GatewayApiError {
    fn into_response(self) -> Response {
        (self.status, Json(self.to_openai_error_body())).into_response()
    }
}

pub fn adapter_error_response(error: OpenAiAdapterError) -> Response {
    let status =
        StatusCode::from_u16(error.http_status()).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    let headers = adapter_error_headers(&error);

    if let Some(normalized) = normalize_openai_provider_error(&error) {
        return (
            status,
            headers,
            Json(normalized_provider_error_body(normalized)),
        )
            .into_response();
    }

    (
        status,
        headers,
        Json(sanitize_error_body(error.to_openai_error_body())),
    )
        .into_response()
}

pub fn summarize_adapter_error(error: &OpenAiAdapterError) -> ErrorLogSummary {
    if let Some(mapping) = normalize_openai_provider_error(error) {
        return ErrorLogSummary {
            http_status: i32::from(mapping.http_status),
            error_owner: mapping.owner.to_string(),
            error_code: mapping.code.to_string(),
            retryable: mapping.retryable,
        };
    }

    let mapping = error.to_adapter_error_mapping();
    ErrorLogSummary {
        http_status: i32::from(mapping.http_status),
        error_owner: mapping.owner,
        error_code: mapping.code,
        retryable: mapping.retryable,
    }
}

pub fn anthropic_adapter_error_response(error: AnthropicAdapterError) -> Response {
    let status =
        StatusCode::from_u16(error.http_status()).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    let headers = anthropic_adapter_error_headers(&error);

    if let Some(normalized) = normalize_anthropic_provider_error(&error) {
        return (
            status,
            headers,
            Json(normalized_provider_error_body(normalized)),
        )
            .into_response();
    }

    (
        status,
        headers,
        Json(sanitize_error_body(error.to_adapter_error_body())),
    )
        .into_response()
}

pub fn summarize_anthropic_adapter_error(error: &AnthropicAdapterError) -> ErrorLogSummary {
    if let Some(mapping) = normalize_anthropic_provider_error(error) {
        return ErrorLogSummary {
            http_status: i32::from(mapping.http_status),
            error_owner: mapping.owner.to_string(),
            error_code: mapping.code.to_string(),
            retryable: mapping.retryable,
        };
    }

    let mapping = error.to_adapter_error_mapping();
    ErrorLogSummary {
        http_status: i32::from(mapping.http_status),
        error_owner: mapping.owner,
        error_code: mapping.code,
        retryable: mapping.retryable,
    }
}

pub fn gemini_adapter_error_response(error: GeminiAdapterError) -> Response {
    let status =
        StatusCode::from_u16(error.http_status()).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    let headers = gemini_adapter_error_headers(&error);

    if let Some(normalized) = normalize_gemini_provider_error(&error) {
        return (
            status,
            headers,
            Json(normalized_provider_error_body(normalized)),
        )
            .into_response();
    }

    (
        status,
        headers,
        Json(sanitize_error_body(error.to_adapter_error_body())),
    )
        .into_response()
}

pub fn summarize_gemini_adapter_error(error: &GeminiAdapterError) -> ErrorLogSummary {
    if let Some(mapping) = normalize_gemini_provider_error(error) {
        return ErrorLogSummary {
            http_status: i32::from(mapping.http_status),
            error_owner: mapping.owner.to_string(),
            error_code: mapping.code.to_string(),
            retryable: mapping.retryable,
        };
    }

    let mapping = error.to_adapter_error_mapping();
    ErrorLogSummary {
        http_status: i32::from(mapping.http_status),
        error_owner: mapping.owner,
        error_code: mapping.code,
        retryable: mapping.retryable,
    }
}

pub fn adapter_error_diagnostic_metadata(error: &OpenAiAdapterError) -> Value {
    normalized_provider_error_diagnostic_metadata(normalize_openai_adapter_error(error))
}

pub fn anthropic_adapter_error_diagnostic_metadata(error: &AnthropicAdapterError) -> Value {
    normalized_provider_error_diagnostic_metadata(normalize_anthropic_adapter_error(error))
}

pub fn gemini_adapter_error_diagnostic_metadata(error: &GeminiAdapterError) -> Value {
    normalized_provider_error_diagnostic_metadata(normalize_gemini_adapter_error(error))
}

pub fn normalize_openai_adapter_error(error: &OpenAiAdapterError) -> ProviderErrorNormalization {
    normalize_openai_provider_error(error)
        .unwrap_or_else(|| adapter_mapping_normalization(error.to_adapter_error_mapping()))
}

fn normalize_openai_provider_error(
    error: &OpenAiAdapterError,
) -> Option<ProviderErrorNormalization> {
    match error {
        OpenAiAdapterError::UpstreamTimeout => Some(upstream_timeout_normalization()),
        OpenAiAdapterError::UpstreamStatus {
            status,
            body,
            retry_after,
        } => Some(upstream_status_normalization(
            *status,
            body,
            retry_after.as_ref(),
        )),
        OpenAiAdapterError::UpstreamInvalidJson {
            status,
            retry_after,
            ..
        } if !(200..300).contains(status) => Some(upstream_status_normalization(
            *status,
            &Value::Null,
            retry_after.as_ref(),
        )),
        _ => None,
    }
}

pub fn normalize_anthropic_adapter_error(
    error: &AnthropicAdapterError,
) -> ProviderErrorNormalization {
    normalize_anthropic_provider_error(error)
        .unwrap_or_else(|| adapter_mapping_normalization(error.to_adapter_error_mapping()))
}

pub fn normalize_gemini_adapter_error(error: &GeminiAdapterError) -> ProviderErrorNormalization {
    normalize_gemini_provider_error(error)
        .unwrap_or_else(|| adapter_mapping_normalization(error.to_adapter_error_mapping()))
}

fn normalize_anthropic_provider_error(
    error: &AnthropicAdapterError,
) -> Option<ProviderErrorNormalization> {
    match error {
        AnthropicAdapterError::UpstreamStatus {
            status,
            body,
            retry_after,
        } => Some(upstream_status_normalization(
            *status,
            body,
            retry_after.as_ref(),
        )),
        AnthropicAdapterError::UpstreamInvalidJson {
            status,
            retry_after,
            ..
        } if !(200..300).contains(status) => Some(upstream_status_normalization(
            *status,
            &Value::Null,
            retry_after.as_ref(),
        )),
        _ => None,
    }
}

fn normalize_gemini_provider_error(
    error: &GeminiAdapterError,
) -> Option<ProviderErrorNormalization> {
    match error {
        GeminiAdapterError::UpstreamStatus {
            status,
            body,
            retry_after,
        } => Some(upstream_status_normalization(
            *status,
            body,
            retry_after.as_ref(),
        )),
        GeminiAdapterError::UpstreamInvalidJson {
            status,
            retry_after,
            ..
        }
        | GeminiAdapterError::UpstreamInvalidResponse {
            status,
            retry_after,
            ..
        } if !(200..300).contains(status) => Some(upstream_status_normalization(
            *status,
            &Value::Null,
            retry_after.as_ref(),
        )),
        _ => None,
    }
}

fn upstream_timeout_normalization() -> ProviderErrorNormalization {
    ProviderErrorNormalization {
        http_status: 504,
        error_type: "provider_error".to_string(),
        code: "upstream_timeout".to_string(),
        message: "The upstream provider did not respond before the gateway timeout.".to_string(),
        param: None,
        owner: "network".to_string(),
        stage: "provider_call".to_string(),
        retryable: Some(true),
        provider_status: None,
        category: "timeout".to_string(),
        action: "Retry later or ask the gateway operator to check provider latency and timeout settings.".to_string(),
    }
}

fn upstream_status_normalization(
    status: u16,
    body: &Value,
    retry_after: Option<&ai_gateway_adapters::AdapterRetryAfter>,
) -> ProviderErrorNormalization {
    if upstream_error_looks_like_invalid_model(status, body) {
        return ProviderErrorNormalization {
            http_status: status,
            error_type: "invalid_request_error".to_string(),
            code: "upstream_invalid_model".to_string(),
            message: "The upstream provider rejected the routed model.".to_string(),
            param: Some("model"),
            owner: "provider".to_string(),
            stage: "provider_call".to_string(),
            retryable: Some(false),
            provider_status: Some(status),
            category: "invalid_model".to_string(),
            action: "Ask the gateway operator to check the model mapping for this API key and provider channel.".to_string(),
        };
    }

    match status {
        401 | 403 => ProviderErrorNormalization {
            http_status: status,
            error_type: "provider_error".to_string(),
            code: "provider_auth_failed".to_string(),
            message: "The upstream provider rejected the configured provider credential.".to_string(),
            param: None,
            owner: "provider".to_string(),
            stage: "provider_call".to_string(),
            retryable: Some(false),
            provider_status: Some(status),
            category: "authentication".to_string(),
            action: "Ask the gateway operator to verify or rotate the provider key for this channel.".to_string(),
        },
        429 => ProviderErrorNormalization {
            http_status: status,
            error_type: "rate_limit_error".to_string(),
            code: "provider_429".to_string(),
            message: "The upstream provider rate limit or quota was reached.".to_string(),
            param: None,
            owner: "provider".to_string(),
            stage: "provider_call".to_string(),
            retryable: Some(true),
            provider_status: Some(status),
            category: "rate_limit".to_string(),
            action: if retry_after.is_some() {
                "Retry after the provider retry window, or ask the gateway operator to add capacity."
            } else {
                "Retry later, or ask the gateway operator to add capacity."
            }
            .to_string(),
        },
        500..=599 => ProviderErrorNormalization {
            http_status: status,
            error_type: "provider_error".to_string(),
            code: "provider_5xx".to_string(),
            message: "The upstream provider returned a server error.".to_string(),
            param: None,
            owner: "provider".to_string(),
            stage: "provider_call".to_string(),
            retryable: Some(true),
            provider_status: Some(status),
            category: "server_error".to_string(),
            action: "Retry later or ask the gateway operator to check provider health and fallback routing.".to_string(),
        },
        _ => ProviderErrorNormalization {
            http_status: status,
            error_type: "provider_error".to_string(),
            code: "provider_http_error".to_string(),
            message: "The upstream provider rejected the request.".to_string(),
            param: None,
            owner: "provider".to_string(),
            stage: "provider_call".to_string(),
            retryable: ai_gateway_adapters::AdapterErrorMapping::retryable_for_status(status),
            provider_status: Some(status),
            category: "http_error".to_string(),
            action: "Check the request parameters or ask the gateway operator to inspect the provider attempt.".to_string(),
        },
    }
}

fn adapter_mapping_normalization(
    mapping: ai_gateway_adapters::AdapterErrorMapping,
) -> ProviderErrorNormalization {
    let http_status = mapping.http_status;
    let retryable = mapping.retryable;
    ProviderErrorNormalization {
        http_status,
        error_type: mapping.error_type,
        code: mapping.code,
        message: "The gateway could not complete the upstream provider request.".to_string(),
        param: None,
        owner: mapping.owner,
        stage: "provider_call".to_string(),
        retryable,
        provider_status: None,
        category: "gateway_adapter".to_string(),
        action: "Retry later or ask the gateway operator to inspect the request trace.".to_string(),
    }
}

fn normalized_provider_error_body(normalized: ProviderErrorNormalization) -> Value {
    sanitize_error_body(json!({
        "error": {
            "message": normalized.message,
            "type": normalized.error_type,
            "param": normalized.param,
            "code": normalized.code
        },
        "gateway": {
            "error_owner": normalized.owner,
            "error_stage": normalized.stage,
            "retryable": normalized.retryable,
            "provider_status": normalized.provider_status,
            "provider_error_category": normalized.category,
            "action": normalized.action
        }
    }))
}

fn normalized_provider_error_diagnostic_metadata(normalized: ProviderErrorNormalization) -> Value {
    sanitize_error_body(json!({
        "provider_error": {
            "schema": "gateway_provider_error_normalized_v1",
            "http_status": normalized.http_status,
            "provider_status": normalized.provider_status,
            "error_owner": normalized.owner,
            "error_stage": normalized.stage,
            "error_code": normalized.code,
            "error_type": normalized.error_type,
            "category": normalized.category,
            "retryable": normalized.retryable,
            "action": normalized.action
        }
    }))
}

fn upstream_error_looks_like_invalid_model(status: u16, body: &Value) -> bool {
    if status == 404 {
        return true;
    }

    matches!(status, 400 | 422) && value_contains_invalid_model_text(body)
}

fn value_contains_invalid_model_text(value: &Value) -> bool {
    match value {
        Value::String(value) => is_invalid_model_text(value),
        Value::Array(values) => values.iter().any(value_contains_invalid_model_text),
        Value::Object(values) => values.iter().any(|(key, value)| {
            is_invalid_model_text(key) || value_contains_invalid_model_text(value)
        }),
        _ => false,
    }
}

fn is_invalid_model_text(value: &str) -> bool {
    let value = value.to_ascii_lowercase();
    value.contains("invalid_model")
        || value.contains("model_not_found")
        || value.contains("model not found")
        || value.contains("model does not exist")
        || value.contains("does not exist")
}

fn adapter_error_headers(error: &OpenAiAdapterError) -> HeaderMap {
    let mut headers = HeaderMap::new();

    if let Some(header_value) = error
        .retry_after_header_value()
        .and_then(|value| HeaderValue::from_str(value).ok())
    {
        headers.insert(RETRY_AFTER, header_value);
    }

    headers
}

fn anthropic_adapter_error_headers(error: &AnthropicAdapterError) -> HeaderMap {
    let mut headers = HeaderMap::new();

    if let Some(header_value) = error
        .retry_after_header_value()
        .and_then(|value| HeaderValue::from_str(value).ok())
    {
        headers.insert(RETRY_AFTER, header_value);
    }

    headers
}

fn gemini_adapter_error_headers(error: &GeminiAdapterError) -> HeaderMap {
    let mut headers = HeaderMap::new();

    if let Some(header_value) = error
        .retry_after_header_value()
        .and_then(|value| HeaderValue::from_str(value).ok())
    {
        headers.insert(RETRY_AFTER, header_value);
    }

    headers
}

fn sanitize_error_body(value: Value) -> Value {
    redact_payload_value(&value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn auth_errors_do_not_echo_key_material() {
        let error = GatewayApiError::invalid_api_key();
        let body = error.to_openai_error_body().to_string();

        assert!(!body.contains("sk-"));
        assert_eq!(error.status, StatusCode::UNAUTHORIZED);
        assert_eq!(error.log_summary().error_code, "invalid_api_key");
    }

    #[test]
    fn missing_default_profile_binding_is_fail_closed_and_secret_safe() {
        let error = GatewayApiError::api_key_profile_missing_default();
        let body = error.to_openai_error_body().to_string();

        assert_eq!(error.status, StatusCode::FORBIDDEN);
        assert_eq!(error.code, "api_key_profile_missing_default");
        assert_eq!(error.owner, "policy");
        assert_eq!(error.stage, "auth");
        assert_eq!(error.retryable, Some(false));
        assert!(!body.contains("Bearer "));
        assert!(!body.contains("Authorization"));
        assert!(!body.contains("dev_test_key"));
    }

    #[test]
    fn database_unavailable_is_retryable_service_error() {
        let error = GatewayApiError::database_unavailable();

        assert_eq!(error.status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(error.log_summary().retryable, Some(true));
    }

    #[test]
    fn database_query_failed_does_not_echo_backend_details() {
        let error = GatewayApiError::database_query_failed(
            "virtual_key_lookup",
            "dsn postgres://user:dev_test_key_123456789@db/table virtual_keys",
        );
        let body = error.to_openai_error_body().to_string();

        assert!(body.contains("virtual_key_lookup"));
        assert!(!body.contains("dev_test_key_123456789"));
        assert!(!body.contains("postgres://"));
        assert!(!body.contains("virtual_keys"));
    }

    #[test]
    fn route_errors_are_openai_compatible_client_errors() {
        let missing = GatewayApiError::model_not_found("missing-model");
        let no_candidate = GatewayApiError::route_no_candidate("mock-gpt");

        assert_eq!(missing.status, StatusCode::NOT_FOUND);
        assert_eq!(
            missing.to_openai_error_body()["error"]["code"],
            "model_not_found"
        );
        assert_eq!(no_candidate.status, StatusCode::NOT_FOUND);
        assert_eq!(
            no_candidate.to_openai_error_body()["error"]["code"],
            "route_no_candidate"
        );
    }

    #[test]
    fn billing_insufficient_balance_error_is_generic_and_non_retryable() {
        let error = GatewayApiError::billing_insufficient_balance();
        let body = error.to_openai_error_body().to_string();

        assert_eq!(error.status, StatusCode::PAYMENT_REQUIRED);
        assert_eq!(error.code, "billing_insufficient_balance");
        assert_eq!(error.owner, "billing");
        assert_eq!(error.stage, "preauth");
        assert_eq!(error.retryable, Some(false));
        assert!(!body.contains("wallet_id"));
        assert!(!body.contains("budget_id"));
        assert!(!body.contains("sk-live-secret"));
    }

    #[test]
    fn prompt_protection_rejection_is_openai_compatible_and_generic() {
        let error = GatewayApiError::prompt_protection_rejected();
        let body = error.to_openai_error_body().to_string();

        assert_eq!(error.status, StatusCode::BAD_REQUEST);
        assert_eq!(error.code, "prompt_protection_rejected");
        assert_eq!(error.owner, "policy");
        assert_eq!(error.stage, "request_preflight");
        assert_eq!(error.retryable, Some(false));
        assert_eq!(
            error.to_openai_error_body()["error"]["code"],
            "prompt_protection_rejected"
        );
        assert!(!body.contains("ignore previous instructions"));
        assert!(!body.contains("sk-live-secret"));
    }

    #[test]
    fn gateway_errors_redact_secret_like_message_tokens() {
        let error = GatewayApiError::invalid_api_key_format(
            "invalid key dev_test_key_123456789 should not be echoed",
        );
        let body = error.to_openai_error_body().to_string();

        assert!(!body.contains("dev_test_key_123456789"));
        assert!(body.contains(REDACTED_SECRET));
    }

    #[test]
    fn adapter_errors_redact_provider_secret_payload() {
        let error = OpenAiAdapterError::UpstreamStatus {
            status: 401,
            body: json!({
                "error": {
                    "message": "provider rejected sk-live-secret",
                    "api_key": "sk-live-secret"
                },
                "authorization": "Bearer dev_test_key_123456789"
            }),
            retry_after: None,
        };

        let body = sanitize_error_body(error.to_openai_error_body()).to_string();

        assert!(!body.contains("sk-live-secret"));
        assert!(!body.contains("dev_test_key_123456789"));
        assert!(body.contains(REDACTED_SECRET));
    }

    #[test]
    fn gateway_error_sanitizer_preserves_non_secret_identifiers() {
        let body = sanitize_error_body(json!({
            "model_key": "openai:gpt-4.1-mini",
            "cache_key": "tenant-cache-entry",
            "public_key_id": "pk_public_identifier",
            "api_key": "sk-live-secret",
            "token": "session-token",
            "password": "p4ssw0rd",
            "cookie": "session=abc"
        }));

        assert_eq!(body["model_key"], "openai:gpt-4.1-mini");
        assert_eq!(body["cache_key"], "tenant-cache-entry");
        assert_eq!(body["public_key_id"], "pk_public_identifier");
        assert_eq!(body["api_key"], REDACTED_SECRET);
        assert_eq!(body["token"], REDACTED_SECRET);
        assert_eq!(body["password"], REDACTED_SECRET);
        assert_eq!(body["cookie"], REDACTED_SECRET);
    }

    #[test]
    fn adapter_error_response_preserves_retry_after_header() {
        let response = adapter_error_response(OpenAiAdapterError::UpstreamStatus {
            status: 429,
            body: json!({"error":{"message":"rate limited"}}),
            retry_after: Some(ai_gateway_adapters::AdapterRetryAfter::new(
                "3",
                Some(3_000),
            )),
        });

        assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(
            response
                .headers()
                .get(RETRY_AFTER)
                .and_then(|value| value.to_str().ok()),
            Some("3")
        );
    }

    #[test]
    fn provider_errors_are_normalized_without_raw_upstream_payload() {
        let cases = [
            (
                OpenAiAdapterError::UpstreamStatus {
                    status: 401,
                    body: json!({
                        "error": {
                            "message": "bad key sk-live-provider-secret",
                            "authorization": "Bearer dev_test_key_123456789"
                        }
                    }),
                    retry_after: None,
                },
                401,
                "provider_auth_failed",
                "authentication",
            ),
            (
                OpenAiAdapterError::UpstreamStatus {
                    status: 429,
                    body: json!({"error":{"code":"rate_limit_exceeded","message":"too many"}}),
                    retry_after: Some(ai_gateway_adapters::AdapterRetryAfter::new(
                        "5",
                        Some(5_000),
                    )),
                },
                429,
                "provider_429",
                "rate_limit",
            ),
            (
                OpenAiAdapterError::UpstreamStatus {
                    status: 503,
                    body: json!({"html":"provider outage sk-live-provider-secret"}),
                    retry_after: None,
                },
                503,
                "provider_5xx",
                "server_error",
            ),
            (
                OpenAiAdapterError::UpstreamTimeout,
                504,
                "upstream_timeout",
                "timeout",
            ),
            (
                OpenAiAdapterError::UpstreamStatus {
                    status: 404,
                    body: json!({"error":{"code":"model_not_found","message":"model does not exist"}}),
                    retry_after: None,
                },
                404,
                "upstream_invalid_model",
                "invalid_model",
            ),
        ];

        for (error, status, code, category) in cases {
            let normalized = normalize_openai_adapter_error(&error);
            let body = normalized_provider_error_body(normalized.clone());
            let body_text = body.to_string();
            let diagnostic = adapter_error_diagnostic_metadata(&error);
            let diagnostic_text = diagnostic.to_string();

            assert_eq!(normalized.http_status, status);
            assert_eq!(normalized.code, code);
            assert_eq!(normalized.category, category);
            assert_eq!(body["error"]["code"], code);
            assert_eq!(body["gateway"]["provider_error_category"], category);
            assert_eq!(diagnostic["provider_error"]["error_code"], code);
            assert_eq!(diagnostic["provider_error"]["category"], category);
            assert!(!body_text.contains("sk-live-provider-secret"));
            assert!(!body_text.contains("dev_test_key_123456789"));
            assert!(!body_text.contains("provider_error_body"));
            assert!(!diagnostic_text.contains("sk-live-provider-secret"));
            assert!(!diagnostic_text.contains("dev_test_key_123456789"));
        }
    }

    #[test]
    fn anthropic_provider_errors_use_same_normalized_surface() {
        let error = AnthropicAdapterError::UpstreamStatus {
            status: 400,
            body: json!({
                "type": "error",
                "error": {
                    "type": "invalid_request_error",
                    "message": "model does not exist: sk-live-provider-secret"
                }
            }),
            retry_after: None,
        };

        let normalized = normalize_anthropic_adapter_error(&error);
        let body = normalized_provider_error_body(normalized.clone()).to_string();

        assert_eq!(normalized.http_status, 400);
        assert_eq!(normalized.code, "upstream_invalid_model");
        assert_eq!(normalized.category, "invalid_model");
        assert!(!body.contains("sk-live-provider-secret"));
        assert!(body.contains("model mapping"));
    }

    #[test]
    fn gemini_provider_errors_use_same_normalized_surface() {
        let error = GeminiAdapterError::UpstreamStatus {
            status: 429,
            body: json!({
                "error": {
                    "code": 429,
                    "message": "quota exceeded for sk-live-provider-secret",
                    "status": "RESOURCE_EXHAUSTED"
                },
                "request": {
                    "authorization": "Bearer dev_test_key_123456789",
                    "raw_payload": "hidden"
                }
            }),
            retry_after: Some(ai_gateway_adapters::AdapterRetryAfter::new(
                "4",
                Some(4_000),
            )),
        };

        let normalized = normalize_gemini_adapter_error(&error);
        let summary = summarize_gemini_adapter_error(&error);
        let body = normalized_provider_error_body(normalized.clone()).to_string();
        let diagnostic = gemini_adapter_error_diagnostic_metadata(&error).to_string();
        let response = gemini_adapter_error_response(error);

        assert_eq!(normalized.http_status, 429);
        assert_eq!(normalized.code, "provider_429");
        assert_eq!(normalized.category, "rate_limit");
        assert_eq!(summary.http_status, 429);
        assert_eq!(summary.error_owner, "provider");
        assert_eq!(summary.error_code, "provider_429");
        assert_eq!(summary.retryable, Some(true));
        assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(
            response
                .headers()
                .get(RETRY_AFTER)
                .and_then(|value| value.to_str().ok()),
            Some("4")
        );
        for text in [&body, &diagnostic] {
            assert!(!text.contains("sk-live-provider-secret"));
            assert!(!text.contains("dev_test_key_123456789"));
            assert!(!text.contains("raw_payload"));
        }
    }
}
