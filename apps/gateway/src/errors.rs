use ai_gateway_adapters::{AnthropicAdapterError, OpenAiAdapterError};
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
        Self {
            status: StatusCode::NOT_FOUND,
            error_type: "invalid_request_error",
            code: "model_not_found",
            message: format!(
                "The model `{model}` does not exist or is not available for this API key"
            ),
            param: Some("model"),
            owner: "policy",
            stage: "route",
            retryable: Some(false),
        }
    }

    pub fn route_no_candidate(model: &str) -> Self {
        Self {
            status: StatusCode::NOT_FOUND,
            error_type: "invalid_request_error",
            code: "route_no_candidate",
            message: format!("No enabled OpenAI-compatible route is available for model `{model}`"),
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

    (
        status,
        headers,
        Json(sanitize_error_body(error.to_openai_error_body())),
    )
        .into_response()
}

pub fn summarize_adapter_error(error: &OpenAiAdapterError) -> ErrorLogSummary {
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

    (
        status,
        headers,
        Json(sanitize_error_body(error.to_adapter_error_body())),
    )
        .into_response()
}

pub fn summarize_anthropic_adapter_error(error: &AnthropicAdapterError) -> ErrorLogSummary {
    let mapping = error.to_adapter_error_mapping();
    ErrorLogSummary {
        http_status: i32::from(mapping.http_status),
        error_owner: mapping.owner,
        error_code: mapping.code,
        retryable: mapping.retryable,
    }
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
}
