use ai_gateway_shared::{GatewayError, GatewayErrorOwner};
use reqwest::StatusCode;
#[cfg(test)]
use reqwest::header::{HeaderMap, HeaderValue, RETRY_AFTER};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use thiserror::Error;

use crate::{
    Adapter, AdapterCapabilities, AdapterErrorMapping, AdapterOperation,
    AdapterProviderErrorSignal, AdapterRetryAfter, AdapterRoutingFields, AdapterStreamPolicy,
    AdapterUpstreamRequest, AdapterUsage, ProtocolMode,
};

const MESSAGES_PATH: &str = "/v1/messages";

#[derive(Debug, Clone, Default)]
pub struct AnthropicAdapter;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AnthropicMessagesRequest {
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub messages: Vec<AnthropicMessage>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stream: Option<bool>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AnthropicMessage {
    #[serde(default)]
    pub role: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content: Option<Value>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AnthropicStreamTerminalKind {
    None,
    MessageStop,
    Error,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AnthropicMessagesStreamEvent {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub event: Option<String>,
    pub data: Value,
    pub terminal_kind: AnthropicStreamTerminalKind,
}

#[derive(Debug, Error)]
pub enum AnthropicAdapterError {
    #[error("invalid JSON request body: {0}")]
    InvalidJson(String),
    #[error("invalid Anthropic messages request: {message}")]
    InvalidRequest {
        message: String,
        param: Option<&'static str>,
    },
    #[error("failed to serialize upstream request: {0}")]
    RequestSerialize(String),
    #[error("upstream returned HTTP {status}")]
    UpstreamStatus {
        status: u16,
        body: Value,
        retry_after: Option<AdapterRetryAfter>,
    },
    #[error("upstream returned non-JSON response with HTTP {status}: {message}")]
    UpstreamInvalidJson {
        status: u16,
        message: String,
        retry_after: Option<AdapterRetryAfter>,
    },
}

impl AnthropicAdapter {
    pub const fn new() -> Self {
        Self
    }

    pub fn finish_reason_for_stop_reason(stop_reason: &str) -> Option<&'static str> {
        anthropic_finish_reason(stop_reason)
    }

    pub fn build_messages_request(
        &self,
        request: &AnthropicMessagesRequest,
    ) -> Result<AdapterUpstreamRequest, AnthropicAdapterError> {
        request.to_upstream_request()
    }

    pub fn parse_messages_response(
        status: u16,
        body: &[u8],
    ) -> Result<Value, AnthropicAdapterError> {
        Self::parse_messages_response_with_retry_after(status, body, None)
    }

    pub fn parse_messages_stream_event(
        event: Option<&str>,
        data: &[u8],
    ) -> Result<AnthropicMessagesStreamEvent, AnthropicAdapterError> {
        AnthropicMessagesStreamEvent::from_sse_parts(event, data)
    }

    fn parse_messages_response_with_retry_after(
        status: u16,
        body: &[u8],
        retry_after: Option<AdapterRetryAfter>,
    ) -> Result<Value, AnthropicAdapterError> {
        let json = match serde_json::from_slice::<Value>(body) {
            Ok(json) => json,
            Err(error) => {
                return Err(AnthropicAdapterError::UpstreamInvalidJson {
                    status,
                    message: error.to_string(),
                    retry_after,
                });
            }
        };

        if !(200..300).contains(&status) {
            return Err(AnthropicAdapterError::UpstreamStatus {
                status,
                body: json,
                retry_after,
            });
        }

        Ok(json)
    }
}

impl AnthropicStreamTerminalKind {
    pub const fn is_terminal(self) -> bool {
        !matches!(self, Self::None)
    }

    pub const fn is_error(self) -> bool {
        matches!(self, Self::Error)
    }
}

impl AnthropicMessagesStreamEvent {
    pub fn from_data_slice(data: &[u8]) -> Result<Self, AnthropicAdapterError> {
        Self::from_sse_parts(None, data)
    }

    pub fn from_sse_parts(event: Option<&str>, data: &[u8]) -> Result<Self, AnthropicAdapterError> {
        let data: Value = serde_json::from_slice(trim_ascii(data)).map_err(|error| {
            AnthropicAdapterError::UpstreamInvalidJson {
                status: 200,
                message: error.to_string(),
                retry_after: None,
            }
        })?;
        let terminal_kind = anthropic_stream_terminal_kind(event, &data);

        Ok(Self {
            event: event
                .map(str::trim)
                .filter(|event| !event.is_empty())
                .map(str::to_string),
            data,
            terminal_kind,
        })
    }

    pub const fn is_terminal(&self) -> bool {
        self.terminal_kind.is_terminal()
    }

    pub const fn is_error(&self) -> bool {
        self.terminal_kind.is_error()
    }

    pub fn usage(&self) -> Option<AdapterUsage> {
        anthropic_usage(&self.data)
    }
}

impl AnthropicMessagesRequest {
    pub fn routing_fields_from_slice(
        body: &[u8],
    ) -> Result<AdapterRoutingFields, AnthropicAdapterError> {
        let value: Value = serde_json::from_slice(body)
            .map_err(|error| AnthropicAdapterError::InvalidJson(error.to_string()))?;
        let object = value.as_object().ok_or_else(|| {
            AnthropicAdapterError::invalid_request(
                "request body must be a JSON object",
                Some("body"),
            )
        })?;

        let model = match object.get("model") {
            Some(Value::String(model)) => Some(model.clone()),
            Some(Value::Null) | None => None,
            Some(_) => {
                return Err(AnthropicAdapterError::invalid_request(
                    "model must be a string",
                    Some("model"),
                ));
            }
        };

        let stream = match object.get("stream") {
            Some(Value::Bool(stream)) => *stream,
            Some(Value::Null) | None => false,
            Some(_) => {
                return Err(AnthropicAdapterError::invalid_request(
                    "stream must be a boolean",
                    Some("stream"),
                ));
            }
        };

        Ok(AdapterRoutingFields { model, stream })
    }

    pub fn from_slice(body: &[u8]) -> Result<Self, AnthropicAdapterError> {
        let request: Self = serde_json::from_slice(body)
            .map_err(|error| AnthropicAdapterError::InvalidJson(error.to_string()))?;
        request.validate()?;
        Ok(request)
    }

    pub fn validate(&self) -> Result<(), AnthropicAdapterError> {
        if self.model.trim().is_empty() {
            return Err(AnthropicAdapterError::InvalidRequest {
                message: "model must be a non-empty string".to_string(),
                param: Some("model"),
            });
        }

        match self.max_tokens {
            Some(max_tokens) if max_tokens > 0 => {}
            Some(_) => {
                return Err(AnthropicAdapterError::InvalidRequest {
                    message: "max_tokens must be greater than 0".to_string(),
                    param: Some("max_tokens"),
                });
            }
            None => {
                return Err(AnthropicAdapterError::InvalidRequest {
                    message: "max_tokens is required".to_string(),
                    param: Some("max_tokens"),
                });
            }
        }

        if self.messages.is_empty() {
            return Err(AnthropicAdapterError::InvalidRequest {
                message: "messages must contain at least one message".to_string(),
                param: Some("messages"),
            });
        }

        for (index, message) in self.messages.iter().enumerate() {
            if message.role.trim().is_empty() {
                return Err(AnthropicAdapterError::InvalidRequest {
                    message: format!("messages[{index}].role must be a non-empty string"),
                    param: Some("messages"),
                });
            }

            if message.content.as_ref().is_none_or(Value::is_null) {
                return Err(AnthropicAdapterError::InvalidRequest {
                    message: format!("messages[{index}].content is required"),
                    param: Some("messages"),
                });
            }
        }

        Ok(())
    }

    pub fn is_streaming(&self) -> bool {
        self.stream.unwrap_or(false)
    }

    pub fn to_upstream_request(&self) -> Result<AdapterUpstreamRequest, AnthropicAdapterError> {
        self.validate()?;
        let stream = self.is_streaming();

        Ok(AdapterUpstreamRequest {
            method: "POST".to_string(),
            path: MESSAGES_PATH.to_string(),
            body: serde_json::to_value(self)
                .map_err(|error| AnthropicAdapterError::RequestSerialize(error.to_string()))?,
            stream,
        })
    }
}

impl AnthropicAdapterError {
    fn invalid_request(message: impl Into<String>, param: Option<&'static str>) -> Self {
        Self::InvalidRequest {
            message: message.into(),
            param,
        }
    }

    pub fn http_status(&self) -> u16 {
        match self {
            Self::InvalidJson(_) | Self::InvalidRequest { .. } => 400,
            Self::RequestSerialize(_) => 500,
            Self::UpstreamInvalidJson { .. } => 502,
            Self::UpstreamStatus { status, .. } => *status,
        }
    }

    pub fn to_adapter_error_body(&self) -> Value {
        let mut body = match self {
            Self::InvalidJson(message) => error_body(
                "invalid_request_error",
                "invalid_json",
                message,
                Some("body"),
                json!({
                    "error_owner": "client",
                    "error_stage": "request_parse"
                }),
            ),
            Self::InvalidRequest { message, param } => error_body(
                "invalid_request_error",
                "invalid_request",
                message,
                *param,
                json!({
                    "error_owner": "client",
                    "error_stage": "request_validate"
                }),
            ),
            Self::RequestSerialize(message) => error_body(
                "gateway_error",
                "request_serialize_failed",
                message,
                None,
                json!({
                    "error_owner": "gateway",
                    "error_stage": "request_transform"
                }),
            ),
            Self::UpstreamStatus { status, body, .. } => error_body(
                "provider_error",
                provider_error_code(*status),
                &format!("upstream provider returned HTTP {status}"),
                None,
                json!({
                    "error_owner": "provider",
                    "error_stage": "provider_call",
                    "provider_status": status,
                    "provider_error": body
                }),
            ),
            Self::UpstreamInvalidJson {
                status, message, ..
            } => error_body(
                "provider_error",
                "provider_invalid_json",
                message,
                None,
                json!({
                    "error_owner": "parser",
                    "error_stage": "response_transform",
                    "provider_status": status
                }),
            ),
        };

        self.attach_error_signal_metadata(&mut body);
        body
    }

    pub fn to_adapter_error_mapping(&self) -> AdapterErrorMapping {
        let status = self.http_status();
        let body = self.to_adapter_error_body();
        let error = &body["error"];
        let gateway = &body["gateway"];
        let signal = self.to_error_signal();

        AdapterErrorMapping {
            http_status: status,
            error_type: string_field(error, "type", "gateway_error"),
            code: string_field(error, "code", "gateway_error"),
            message: string_field(error, "message", "adapter error"),
            param: error
                .get("param")
                .and_then(Value::as_str)
                .map(str::to_string),
            owner: string_field(gateway, "error_owner", "gateway"),
            stage: string_field(gateway, "error_stage", "provider_call"),
            retryable: AdapterErrorMapping::retryable_for_status(status),
            retry_after_ms: signal.as_ref().and_then(|signal| signal.retry_after_ms),
            signal,
        }
    }

    pub fn to_gateway_error(&self) -> GatewayError {
        let mapping = self.to_adapter_error_mapping();
        let owner = gateway_error_owner(&mapping.owner);
        GatewayError::new(owner, mapping.code, mapping.message)
    }

    pub fn retry_after(&self) -> Option<&AdapterRetryAfter> {
        match self {
            Self::UpstreamStatus { retry_after, .. }
            | Self::UpstreamInvalidJson { retry_after, .. } => retry_after.as_ref(),
            _ => None,
        }
    }

    pub fn retry_after_header_value(&self) -> Option<&str> {
        self.retry_after()
            .map(|retry_after| retry_after.header_value.as_str())
    }

    pub fn to_error_signal(&self) -> Option<AdapterProviderErrorSignal> {
        match self {
            Self::UpstreamStatus {
                status,
                retry_after,
                ..
            } => Some(status_signal(*status, retry_after.as_ref())),
            Self::UpstreamInvalidJson {
                status,
                retry_after,
                ..
            } if !(200..300).contains(status) => Some(status_signal(*status, retry_after.as_ref())),
            _ => None,
        }
    }

    fn attach_error_signal_metadata(&self, body: &mut Value) {
        let Some(gateway) = body.get_mut("gateway").and_then(Value::as_object_mut) else {
            return;
        };

        gateway.insert(
            "retryable".to_string(),
            json!(AdapterErrorMapping::retryable_for_status(
                self.http_status()
            )),
        );

        if let Some(retry_after) = self.retry_after() {
            gateway.insert(
                "retry_after".to_string(),
                Value::String(retry_after.header_value.clone()),
            );

            if let Some(retry_after_ms) = retry_after.retry_after_ms {
                gateway.insert("retry_after_ms".to_string(), json!(retry_after_ms));
            }
        }

        if let Some(signal) = self.to_error_signal() {
            gateway.insert("error_signal".to_string(), json!(signal));
        }
    }
}

impl Adapter for AnthropicAdapter {
    fn protocol_mode(&self) -> ProtocolMode {
        ProtocolMode::Anthropic
    }

    fn capabilities(&self) -> AdapterCapabilities {
        AdapterCapabilities {
            operations: vec![AdapterOperation::Messages],
            stream_policy: AdapterStreamPolicy::Parse,
        }
    }

    fn extract_model(&self, body: &[u8]) -> Result<Option<String>, GatewayError> {
        self.extract_routing_fields(body).map(|fields| fields.model)
    }

    fn extract_routing_fields(&self, body: &[u8]) -> Result<AdapterRoutingFields, GatewayError> {
        AnthropicMessagesRequest::routing_fields_from_slice(body)
            .map_err(|error| error.to_gateway_error())
    }

    fn build_upstream_request(
        &self,
        operation: AdapterOperation,
        body: &[u8],
    ) -> Result<AdapterUpstreamRequest, GatewayError> {
        match operation {
            AdapterOperation::Messages => {
                let request = AnthropicMessagesRequest::from_slice(body)
                    .map_err(|error| error.to_gateway_error())?;
                self.build_messages_request(&request)
                    .map_err(|error| error.to_gateway_error())
            }
            _ => Err(unsupported_anthropic_operation(
                operation,
                "build_upstream_request",
            )),
        }
    }

    fn parse_response(
        &self,
        operation: AdapterOperation,
        status: u16,
        body: &[u8],
    ) -> Result<Value, GatewayError> {
        match operation {
            AdapterOperation::Messages => Self::parse_messages_response(status, body)
                .map_err(|error| error.to_gateway_error()),
            _ => Err(unsupported_anthropic_operation(operation, "parse_response")),
        }
    }

    fn parse_stream_event(
        &self,
        operation: AdapterOperation,
        event: &[u8],
    ) -> Result<Value, GatewayError> {
        match operation {
            AdapterOperation::Messages => AnthropicMessagesStreamEvent::from_data_slice(event)
                .map(|event| event.data)
                .map_err(|error| error.to_gateway_error()),
            _ => Err(unsupported_anthropic_operation(
                operation,
                "parse_stream_event",
            )),
        }
    }

    fn extract_usage(&self, response: &Value) -> Option<AdapterUsage> {
        anthropic_usage(response)
    }
}

#[cfg(test)]
fn retry_after_from_headers(headers: &HeaderMap) -> Option<AdapterRetryAfter> {
    let retry_after_ms = headers
        .get("retry-after-ms")
        .and_then(header_to_str)
        .and_then(parse_retry_after_ms);
    let retry_after = headers.get(RETRY_AFTER).and_then(header_to_str);

    if let Some(retry_after) = retry_after {
        return Some(AdapterRetryAfter::new(
            retry_after,
            retry_after_ms.or_else(|| parse_retry_after_seconds(retry_after)),
        ));
    }

    retry_after_ms.map(|retry_after_ms| {
        AdapterRetryAfter::new(
            retry_after_ms_to_header_value(retry_after_ms),
            Some(retry_after_ms),
        )
    })
}

#[cfg(test)]
fn header_to_str(header: &HeaderValue) -> Option<&str> {
    header
        .to_str()
        .ok()
        .map(str::trim)
        .filter(|value| !value.is_empty())
}

fn trim_ascii(value: &[u8]) -> &[u8] {
    let mut start = 0;
    let mut end = value.len();

    while start < end && value[start].is_ascii_whitespace() {
        start += 1;
    }

    while end > start && value[end - 1].is_ascii_whitespace() {
        end -= 1;
    }

    &value[start..end]
}

#[cfg(test)]
fn parse_retry_after_ms(value: &str) -> Option<u64> {
    value.trim().parse::<u64>().ok()
}

#[cfg(test)]
fn parse_retry_after_seconds(value: &str) -> Option<u64> {
    value.trim().parse::<u64>().ok()?.checked_mul(1_000)
}

#[cfg(test)]
fn retry_after_ms_to_header_value(retry_after_ms: u64) -> String {
    retry_after_ms
        .saturating_add(999)
        .checked_div(1_000)
        .unwrap_or(0)
        .to_string()
}

fn status_signal(
    status: u16,
    retry_after: Option<&AdapterRetryAfter>,
) -> AdapterProviderErrorSignal {
    let signal = AdapterProviderErrorSignal::from_status(status);

    if let Some(retry_after_ms) = retry_after.and_then(|retry_after| retry_after.retry_after_ms) {
        signal.with_retry_after_ms(retry_after_ms)
    } else {
        signal
    }
}

fn anthropic_stream_terminal_kind(
    event: Option<&str>,
    data: &Value,
) -> AnthropicStreamTerminalKind {
    match event.map(str::trim).filter(|event| !event.is_empty()) {
        Some("message_stop") => return AnthropicStreamTerminalKind::MessageStop,
        Some("error") => return AnthropicStreamTerminalKind::Error,
        _ => {}
    }

    match data.get("type").and_then(Value::as_str) {
        Some("message_stop") => AnthropicStreamTerminalKind::MessageStop,
        Some("error") => AnthropicStreamTerminalKind::Error,
        _ => AnthropicStreamTerminalKind::None,
    }
}

fn string_field(value: &Value, field: &str, fallback: &str) -> String {
    value
        .get(field)
        .and_then(Value::as_str)
        .unwrap_or(fallback)
        .to_string()
}

fn gateway_error_owner(owner: &str) -> GatewayErrorOwner {
    match owner {
        "client" => GatewayErrorOwner::Client,
        "policy" => GatewayErrorOwner::Policy,
        "provider" => GatewayErrorOwner::Provider,
        _ => GatewayErrorOwner::Gateway,
    }
}

fn provider_error_code(status: u16) -> &'static str {
    match StatusCode::from_u16(status) {
        Ok(StatusCode::TOO_MANY_REQUESTS) => "provider_429",
        Ok(status) if status.is_server_error() => "provider_5xx",
        Ok(StatusCode::UNAUTHORIZED) | Ok(StatusCode::FORBIDDEN) => "provider_auth_failed",
        _ => "provider_http_error",
    }
}

fn error_body(
    error_type: &str,
    code: &str,
    message: &str,
    param: Option<&str>,
    metadata: Value,
) -> Value {
    json!({
        "error": {
            "message": message,
            "type": error_type,
            "param": param,
            "code": code
        },
        "gateway": metadata
    })
}

fn unsupported_anthropic_operation(operation: AdapterOperation, method: &str) -> GatewayError {
    GatewayError::new(
        GatewayErrorOwner::Gateway,
        "adapter_operation_unsupported",
        format!("Anthropic adapter does not implement {method} for {operation:?}"),
    )
}

fn anthropic_finish_reason(stop_reason: &str) -> Option<&'static str> {
    match stop_reason.trim() {
        "end_turn" | "stop_sequence" => Some("stop"),
        "max_tokens" => Some("length"),
        "tool_use" => Some("tool_calls"),
        _ => None,
    }
}

fn anthropic_usage(response: &Value) -> Option<AdapterUsage> {
    let usage = response.get("usage")?;
    let prompt_tokens = usage.get("input_tokens").and_then(Value::as_u64);
    let completion_tokens = usage.get("output_tokens").and_then(Value::as_u64);
    let total_tokens = usage
        .get("total_tokens")
        .and_then(Value::as_u64)
        .or_else(|| {
            prompt_tokens
                .zip(completion_tokens)
                .and_then(|(prompt_tokens, completion_tokens)| {
                    prompt_tokens.checked_add(completion_tokens)
                })
        });

    Some(AdapterUsage {
        prompt_tokens,
        completion_tokens,
        total_tokens,
    })
}

#[cfg(test)]
mod tests {
    use std::{fs, path::PathBuf};

    use ai_gateway_shared::GatewayErrorOwner;

    use super::*;

    fn load_anthropic_fixture(file_name: &str) -> Value {
        let path = anthropic_fixture_path(file_name);
        let contents = fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("failed to read fixture {}: {error}", path.display()));

        serde_json::from_str(&contents)
            .unwrap_or_else(|error| panic!("failed to parse fixture {}: {error}", path.display()))
    }

    fn anthropic_fixture_path(file_name: &str) -> PathBuf {
        let mut path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        path.pop();
        path.pop();
        path.push("tests");
        path.push("fixtures");
        path.push("adapters");
        path.push("anthropic");
        path.push(file_name);
        path
    }

    fn json_body_bytes(body: &Value) -> Vec<u8> {
        if let Some(raw_body) = body.as_str() {
            raw_body.as_bytes().to_vec()
        } else {
            serde_json::to_vec(body).expect("fixture body should serialize")
        }
    }

    fn fixture_response_status(fixture: &Value) -> u16 {
        fixture["response"]["status"]
            .as_u64()
            .expect("fixture response status")
            .try_into()
            .expect("fixture response status should fit in u16")
    }

    fn fixture_response_body(fixture: &Value) -> Vec<u8> {
        json_body_bytes(&fixture["response"]["body"])
    }

    fn fixture_response_headers(fixture: &Value) -> HeaderMap {
        let mut headers = HeaderMap::new();

        let Some(header_object) = fixture["response"]
            .get("headers")
            .and_then(Value::as_object)
        else {
            return headers;
        };

        for (name, value) in header_object {
            headers.insert(
                reqwest::header::HeaderName::from_bytes(name.as_bytes())
                    .expect("fixture header name"),
                HeaderValue::from_str(value.as_str().expect("fixture header value"))
                    .expect("fixture header value"),
            );
        }

        headers
    }

    fn load_anthropic_stream_fixture(file_name: &str) -> String {
        let path = anthropic_fixture_path(&format!("streams/{file_name}"));
        fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("failed to read fixture {}: {error}", path.display()))
    }

    fn anthropic_fixture_texts() -> Vec<(String, String)> {
        let root = anthropic_fixture_path("");
        let mut stack = vec![root.clone()];
        let mut fixtures = Vec::new();

        while let Some(directory) = stack.pop() {
            let entries = fs::read_dir(&directory).unwrap_or_else(|error| {
                panic!(
                    "failed to read fixture directory {}: {error}",
                    directory.display()
                )
            });

            for entry in entries {
                let path = entry
                    .unwrap_or_else(|error| {
                        panic!(
                            "failed to read fixture directory entry {}: {error}",
                            directory.display()
                        )
                    })
                    .path();

                if path.is_dir() {
                    stack.push(path);
                    continue;
                }

                if !path
                    .extension()
                    .is_some_and(|extension| extension == "json" || extension == "sse")
                {
                    continue;
                }

                let label = path
                    .strip_prefix(&root)
                    .unwrap_or(&path)
                    .display()
                    .to_string()
                    .replace('\\', "/");
                let text = fs::read_to_string(&path).unwrap_or_else(|error| {
                    panic!("failed to read fixture {}: {error}", path.display())
                });
                fixtures.push((label, text));
            }
        }

        fixtures
    }

    fn assert_fixture_text_is_secret_safe(label: &str, text: &str) {
        assert!(
            !text.contains("-----BEGIN"),
            "{label}: fixture must not contain private key material"
        );
        assert!(
            !text.contains("Bearer "),
            "{label}: fixture must not contain bearer tokens"
        );

        for token in text.split(|byte: char| {
            byte.is_whitespace()
                || matches!(
                    byte,
                    '"' | '\'' | ',' | ':' | ';' | '{' | '}' | '[' | ']' | '(' | ')'
                )
        }) {
            let token = token.trim();
            assert!(
                !(token.starts_with("sk-") && token.len() >= 12),
                "{label}: fixture must not contain provider-key-like values"
            );
            assert!(
                !(token.starts_with("AIza") && token.len() >= 20),
                "{label}: fixture must not contain google-key-like values"
            );
        }
    }

    fn sse_fixture_events(file_name: &str) -> Vec<(Option<String>, Vec<u8>)> {
        load_anthropic_stream_fixture(file_name)
            .split("\n\n")
            .filter_map(|block| {
                let mut event = None;
                let mut data = Vec::<String>::new();

                for line in block.lines() {
                    let line = line.trim_end_matches('\r');
                    if let Some(value) = line.strip_prefix("event:") {
                        event = Some(value.trim().to_string());
                    } else if let Some(value) = line.strip_prefix("data:") {
                        data.push(value.strip_prefix(' ').unwrap_or(value).to_string());
                    }
                }

                if data.is_empty() {
                    None
                } else {
                    Some((event, data.join("\n").into_bytes()))
                }
            })
            .collect()
    }

    fn expected_terminal_kind(value: &Value) -> AnthropicStreamTerminalKind {
        match value
            .get("expected_terminal")
            .and_then(Value::as_str)
            .expect("expected_terminal")
        {
            "none" => AnthropicStreamTerminalKind::None,
            "message_stop" => AnthropicStreamTerminalKind::MessageStop,
            "error" => AnthropicStreamTerminalKind::Error,
            terminal => panic!("unknown expected Anthropic terminal kind: {terminal}"),
        }
    }

    fn assert_error_mapping_matches(mapping: &AdapterErrorMapping, expected: &Value) {
        if let Some(expected_status) = expected.get("http_status").and_then(Value::as_u64) {
            assert_eq!(mapping.http_status, expected_status as u16);
        }
        if let Some(expected_error_type) = expected.get("error_type").and_then(Value::as_str) {
            assert_eq!(mapping.error_type, expected_error_type);
        }
        if let Some(expected_code) = expected.get("code").and_then(Value::as_str) {
            assert_eq!(mapping.code, expected_code);
        }
        if let Some(expected_message) = expected.get("message").and_then(Value::as_str) {
            assert_eq!(mapping.message, expected_message);
        }
        if let Some(expected_param) = expected.get("param") {
            assert_eq!(mapping.param.as_deref(), expected_param.as_str());
        }
        if let Some(expected_owner) = expected.get("owner").and_then(Value::as_str) {
            assert_eq!(mapping.owner, expected_owner);
        }
        if let Some(expected_stage) = expected.get("stage").and_then(Value::as_str) {
            assert_eq!(mapping.stage, expected_stage);
        }
        if let Some(expected_retryable) = expected.get("retryable") {
            assert_eq!(mapping.retryable, expected_retryable.as_bool());
        }
        if let Some(expected_retry_after_ms) = expected.get("retry_after_ms") {
            assert_eq!(mapping.retry_after_ms, expected_retry_after_ms.as_u64());
        }

        match expected.get("signal") {
            Some(Value::Null) => assert!(mapping.signal.is_none()),
            Some(expected_signal) => assert_eq!(
                serde_json::to_value(mapping.signal.as_ref().expect("error signal"))
                    .expect("error signal should serialize"),
                *expected_signal
            ),
            None => {}
        }
    }

    #[test]
    fn adapter_contract_declares_messages_surface_with_parseable_streaming() {
        let adapter = AnthropicAdapter::new();
        let capabilities = adapter.capabilities();

        assert_eq!(adapter.protocol_mode(), ProtocolMode::Anthropic);
        assert!(capabilities.supports(AdapterOperation::Messages));
        assert_eq!(capabilities.stream_policy, AdapterStreamPolicy::Parse);
    }

    #[test]
    fn extracts_routing_fields_without_full_request_validation() {
        let adapter = AnthropicAdapter::new();
        let fields = adapter
            .extract_routing_fields(br#"{"model":"claude-fixture","stream":true}"#)
            .expect("routing fields should parse without full request validation");

        assert_eq!(fields.model.as_deref(), Some("claude-fixture"));
        assert!(fields.stream);
    }

    #[test]
    fn validates_required_fields_and_builds_stream_requests() {
        let missing_max_tokens = AnthropicMessagesRequest::from_slice(
            br#"{"model":"claude-fixture","messages":[{"role":"user","content":"hi"}]}"#,
        )
        .expect_err("missing max_tokens should be rejected");
        assert_eq!(missing_max_tokens.http_status(), 400);
        assert_eq!(
            missing_max_tokens.to_adapter_error_body()["error"]["param"],
            "max_tokens"
        );

        let streaming = AnthropicMessagesRequest::from_slice(
            br#"{"model":"claude-fixture","max_tokens":16,"messages":[{"role":"user","content":"hi"}],"stream":true}"#,
        )
        .expect("streaming request shape is valid");
        let upstream = streaming
            .to_upstream_request()
            .expect("streaming request should build");
        assert_eq!(upstream.method, "POST");
        assert_eq!(upstream.path, MESSAGES_PATH);
        assert!(upstream.stream);
        assert_eq!(upstream.body["stream"], true);
    }

    #[test]
    fn conformance_fixtures_cover_messages_request_response_and_errors() {
        let adapter = AnthropicAdapter::new();

        let valid = load_anthropic_fixture("messages_non_stream_valid.json");
        let valid_request = serde_json::to_vec(&valid["request"]).expect("fixture request");
        let upstream = adapter
            .build_upstream_request(AdapterOperation::Messages, &valid_request)
            .expect("valid fixture should build an upstream request");
        let expected_upstream = &valid["expected_upstream"];

        assert_eq!(
            upstream.method,
            expected_upstream["method"].as_str().expect("method")
        );
        assert_eq!(
            upstream.path,
            expected_upstream["path"].as_str().expect("path")
        );
        assert_eq!(
            upstream.stream,
            expected_upstream["stream"].as_bool().expect("stream")
        );
        assert_eq!(&upstream.body, &expected_upstream["body"]);
        assert_eq!(
            &upstream.body["messages"][0]["content"],
            &valid["expected_content_blocks"]["request_message_content"]
        );

        let parsed = adapter
            .parse_response(
                AdapterOperation::Messages,
                fixture_response_status(&valid),
                &fixture_response_body(&valid),
            )
            .expect("valid fixture response should parse");
        assert_eq!(&parsed, &valid["response"]["body"]);
        assert_eq!(
            &parsed["content"],
            &valid["expected_content_blocks"]["response_content"]
        );
        assert_eq!(
            parsed["stop_reason"].as_str(),
            valid["expected_finish_reason_mapping"]["stop_reason"].as_str()
        );
        assert_eq!(
            parsed["stop_sequence"],
            valid["expected_finish_reason_mapping"]["stop_sequence"]
        );
        assert_eq!(
            AnthropicAdapter::finish_reason_for_stop_reason(
                parsed["stop_reason"].as_str().expect("stop_reason")
            ),
            valid["expected_finish_reason_mapping"]["finish_reason"].as_str()
        );

        let usage = adapter
            .extract_usage(&parsed)
            .expect("valid fixture should include usage");
        let actual_usage = serde_json::to_value(usage).expect("usage should serialize");
        assert_eq!(&actual_usage, &valid["expected_usage"]);

        let stream = load_anthropic_fixture("messages_stream_valid.json");
        let stream_request = serde_json::to_vec(&stream["request"]).expect("fixture request");
        let stream_upstream = adapter
            .build_upstream_request(AdapterOperation::Messages, &stream_request)
            .expect("stream fixture should build an upstream request");
        let expected_stream_upstream = &stream["expected_upstream"];

        assert_eq!(
            stream_upstream.method,
            expected_stream_upstream["method"].as_str().expect("method")
        );
        assert_eq!(
            stream_upstream.path,
            expected_stream_upstream["path"].as_str().expect("path")
        );
        assert_eq!(
            stream_upstream.stream,
            expected_stream_upstream["stream"]
                .as_bool()
                .expect("stream")
        );
        assert_eq!(&stream_upstream.body, &expected_stream_upstream["body"]);

        let invalid = load_anthropic_fixture("invalid_request.json");
        let invalid_request = serde_json::to_vec(&invalid["request"]).expect("fixture request");
        let invalid_error = AnthropicMessagesRequest::from_slice(&invalid_request)
            .expect_err("invalid request fixture should fail validation");
        let invalid_mapping = invalid_error.to_adapter_error_mapping();
        assert_error_mapping_matches(&invalid_mapping, &invalid["expected_error_mapping"]);

        let gateway_error = adapter
            .build_upstream_request(AdapterOperation::Messages, &invalid_request)
            .expect_err("invalid request fixture should fail adapter build");
        assert_eq!(gateway_error.owner, GatewayErrorOwner::Client);
        assert_eq!(gateway_error.code, invalid_mapping.code);

        for fixture_name in [
            "provider_429_retry_after.json",
            "provider_5xx.json",
            "invalid_json_response.json",
        ] {
            let fixture = load_anthropic_fixture(fixture_name);
            let headers = fixture_response_headers(&fixture);
            let retry_after = retry_after_from_headers(&headers);
            let error = AnthropicAdapter::parse_messages_response_with_retry_after(
                fixture_response_status(&fixture),
                &fixture_response_body(&fixture),
                retry_after,
            )
            .expect_err(&format!("{fixture_name} should map to an adapter error"));

            if let Some(expected_retry_after) = fixture
                .get("expected_retry_after_header_value")
                .and_then(Value::as_str)
            {
                assert_eq!(error.retry_after_header_value(), Some(expected_retry_after));
            }

            assert_error_mapping_matches(
                &error.to_adapter_error_mapping(),
                &fixture["expected_error_mapping"],
            );
        }
    }

    #[test]
    fn stream_json_fixtures_parse_terminal_contract() {
        let adapter = AnthropicAdapter::new();

        for fixture_name in ["stream_message_stop_event.json", "stream_error_event.json"] {
            let fixture = load_anthropic_fixture(fixture_name);
            let event = json_body_bytes(&fixture["event"]);
            let parsed = adapter
                .parse_stream_event(AdapterOperation::Messages, &event)
                .expect("stream event JSON should parse through the adapter trait");
            let contract = AnthropicAdapter::parse_messages_stream_event(
                fixture.get("event_name").and_then(Value::as_str),
                &event,
            )
            .expect("stream event contract should parse");

            assert_eq!(&parsed, &fixture["expected_event"], "{fixture_name}");
            assert_eq!(
                contract.terminal_kind,
                expected_terminal_kind(&fixture),
                "{fixture_name}"
            );
            assert_eq!(
                contract.is_terminal(),
                contract.terminal_kind.is_terminal(),
                "{fixture_name}"
            );
        }
    }

    #[test]
    fn stream_sse_fixtures_parse_message_stop_error_and_usage_contract() {
        let completed = sse_fixture_events("messages_stream_completed.sse")
            .into_iter()
            .map(|(event, data)| {
                AnthropicAdapter::parse_messages_stream_event(event.as_deref(), &data)
                    .expect("completed stream fixture event should parse")
            })
            .collect::<Vec<_>>();

        assert_eq!(completed.len(), 3);
        assert_eq!(
            completed[0].terminal_kind,
            AnthropicStreamTerminalKind::None
        );
        assert_eq!(completed[1].data["type"], "content_block_delta");
        assert_eq!(completed[1].data["delta"]["type"], "text_delta");
        assert_eq!(completed[1].data["delta"]["text"], "Hello");
        assert_eq!(
            completed[2].event.as_deref(),
            Some("message_stop"),
            "message_stop fixture should carry the Anthropic SSE event name"
        );
        assert_eq!(
            completed[2].terminal_kind,
            AnthropicStreamTerminalKind::MessageStop
        );
        assert!(completed[2].is_terminal());
        assert!(!completed[2].is_error());

        let error_events = sse_fixture_events("messages_stream_error.sse")
            .into_iter()
            .map(|(event, data)| {
                AnthropicAdapter::parse_messages_stream_event(event.as_deref(), &data)
                    .expect("error stream fixture event should parse")
            })
            .collect::<Vec<_>>();

        assert_eq!(error_events.len(), 1);
        assert_eq!(
            error_events[0].terminal_kind,
            AnthropicStreamTerminalKind::Error
        );
        assert!(error_events[0].is_terminal());
        assert!(error_events[0].is_error());
        assert_eq!(error_events[0].data["error"]["type"], "overloaded_error");

        let missing_terminal = sse_fixture_events("messages_stream_missing_terminal.sse")
            .into_iter()
            .map(|(event, data)| {
                AnthropicAdapter::parse_messages_stream_event(event.as_deref(), &data)
                    .expect("missing-terminal stream fixture event should parse")
            })
            .collect::<Vec<_>>();

        assert_eq!(missing_terminal.len(), 3);
        assert!(
            missing_terminal
                .iter()
                .all(|event| event.terminal_kind == AnthropicStreamTerminalKind::None)
        );
        let delta_usage = missing_terminal[2]
            .usage()
            .expect("message_delta fixture should expose usage");
        assert_eq!(delta_usage.completion_tokens, Some(1));
        assert_eq!(delta_usage.total_tokens, None);

        let invalid = sse_fixture_events("messages_stream_invalid_json.sse");
        let (event, data) = invalid.first().expect("invalid JSON fixture event");
        let error = AnthropicAdapter::parse_messages_stream_event(event.as_deref(), data)
            .expect_err("invalid JSON stream fixture should map to parser error");
        let mapping = error.to_adapter_error_mapping();
        assert_eq!(mapping.http_status, 502);
        assert_eq!(mapping.code, "provider_invalid_json");
        assert_eq!(mapping.owner, "parser");
        assert_eq!(mapping.stage, "response_transform");
    }

    #[test]
    fn anthropic_finish_reason_mapping_covers_stable_stop_reason_subset() {
        assert_eq!(
            AnthropicAdapter::finish_reason_for_stop_reason("end_turn"),
            Some("stop")
        );
        assert_eq!(
            AnthropicAdapter::finish_reason_for_stop_reason("stop_sequence"),
            Some("stop")
        );
        assert_eq!(
            AnthropicAdapter::finish_reason_for_stop_reason("max_tokens"),
            Some("length")
        );
        assert_eq!(
            AnthropicAdapter::finish_reason_for_stop_reason("tool_use"),
            Some("tool_calls")
        );
        assert_eq!(
            AnthropicAdapter::finish_reason_for_stop_reason("pause_turn"),
            None
        );
    }

    #[test]
    fn anthropic_fixtures_are_secret_safe() {
        for (label, text) in anthropic_fixture_texts() {
            assert_fixture_text_is_secret_safe(&label, &text);
        }
    }
}
