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
    AdapterUpstreamRequest, AdapterUsage, ChatCompletionRequest, ChatMessage, ProtocolMode,
};

const GENERATE_CONTENT_PATH_PREFIX: &str = "/v1beta/models/";
const GENERATE_CONTENT_PATH_SUFFIX: &str = ":generateContent";
const STREAM_GENERATE_CONTENT_PATH_SUFFIX: &str = ":streamGenerateContent?alt=sse";

#[derive(Debug, Clone, Default)]
pub struct GeminiAdapter;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GeminiGenerateContentRequest {
    #[serde(default, skip_serializing)]
    pub model: String,
    #[serde(default)]
    pub contents: Vec<GeminiContent>,
    #[serde(
        default,
        rename = "systemInstruction",
        skip_serializing_if = "Option::is_none"
    )]
    pub system_instruction: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tools: Option<Value>,
    #[serde(
        default,
        rename = "toolConfig",
        skip_serializing_if = "Option::is_none"
    )]
    pub tool_config: Option<Value>,
    #[serde(
        default,
        rename = "safetySettings",
        skip_serializing_if = "Option::is_none"
    )]
    pub safety_settings: Option<Value>,
    #[serde(
        default,
        rename = "generationConfig",
        skip_serializing_if = "Option::is_none"
    )]
    pub generation_config: Option<Value>,
    #[serde(
        default,
        rename = "cachedContent",
        skip_serializing_if = "Option::is_none"
    )]
    pub cached_content: Option<Value>,
    #[serde(default, skip_serializing)]
    pub stream: Option<bool>,
    #[serde(default, rename = "streamGenerateContent", skip_serializing)]
    pub stream_generate_content: Option<bool>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GeminiContent {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    #[serde(default)]
    pub parts: Vec<Value>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GeminiStreamTerminalKind {
    None,
    FinishReason(String),
    Error,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GeminiGenerateContentStreamEvent {
    pub data: Value,
    pub terminal_kind: GeminiStreamTerminalKind,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GeminiGenerateContentTerminal {
    #[serde(rename = "finishReason")]
    pub finish_reason: String,
    pub mapped_finish_reason: String,
}

#[derive(Debug, Error)]
pub enum GeminiAdapterError {
    #[error("invalid JSON request body: {0}")]
    InvalidJson(String),
    #[error("invalid Gemini generateContent request: {message}")]
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
    #[error(
        "upstream returned invalid Gemini generateContent response with HTTP {status}: {message}"
    )]
    UpstreamInvalidResponse {
        status: u16,
        message: String,
        retry_after: Option<AdapterRetryAfter>,
    },
}

impl GeminiAdapter {
    pub const fn new() -> Self {
        Self
    }

    pub fn finish_reason_for_finish_reason(finish_reason: &str) -> Option<&'static str> {
        gemini_finish_reason(finish_reason)
    }

    pub fn generate_content_terminal(
        response: &Value,
    ) -> Result<GeminiGenerateContentTerminal, GeminiAdapterError> {
        gemini_generate_content_terminal(response, 200, None)
    }

    pub fn generate_content_protocol_metadata(response: &Value) -> Value {
        gemini_generate_content_protocol_metadata(response)
    }

    pub fn build_generate_content_request(
        &self,
        request: &GeminiGenerateContentRequest,
    ) -> Result<AdapterUpstreamRequest, GeminiAdapterError> {
        request.to_upstream_request()
    }

    pub fn parse_generate_content_response(
        status: u16,
        body: &[u8],
    ) -> Result<Value, GeminiAdapterError> {
        Self::parse_generate_content_response_with_retry_after(status, body, None)
    }

    pub fn parse_chat_completions_response(
        status: u16,
        body: &[u8],
    ) -> Result<Value, GeminiAdapterError> {
        Self::parse_chat_completions_response_with_retry_after(status, body, None)
    }

    fn parse_chat_completions_response_with_retry_after(
        status: u16,
        body: &[u8],
        retry_after: Option<AdapterRetryAfter>,
    ) -> Result<Value, GeminiAdapterError> {
        let json = parse_gemini_json_response(status, body, retry_after.clone())?;
        gemini_generate_content_to_openai_chat_completion(&json, status, retry_after)
    }

    pub fn parse_generate_content_stream_event(
        data: &[u8],
    ) -> Result<GeminiGenerateContentStreamEvent, GeminiAdapterError> {
        GeminiGenerateContentStreamEvent::from_data_slice(data)
    }

    pub fn parse_chat_completions_stream_event(data: &[u8]) -> Result<Value, GeminiAdapterError> {
        let event = GeminiGenerateContentStreamEvent::from_data_slice(data)?;
        gemini_stream_event_to_openai_chat_completion_chunk(&event.data, 200, None)
    }

    fn parse_generate_content_response_with_retry_after(
        status: u16,
        body: &[u8],
        retry_after: Option<AdapterRetryAfter>,
    ) -> Result<Value, GeminiAdapterError> {
        let json = parse_gemini_json_response(status, body, retry_after.clone())?;
        gemini_generate_content_terminal(&json, status, retry_after.clone())?;

        Ok(json)
    }
}

impl GeminiStreamTerminalKind {
    pub fn is_terminal(&self) -> bool {
        !matches!(self, Self::None)
    }

    pub fn is_error(&self) -> bool {
        matches!(self, Self::Error)
    }
}

impl GeminiGenerateContentStreamEvent {
    pub fn from_data_slice(data: &[u8]) -> Result<Self, GeminiAdapterError> {
        let data: Value = serde_json::from_slice(trim_ascii(data)).map_err(|error| {
            GeminiAdapterError::UpstreamInvalidJson {
                status: 200,
                message: error.to_string(),
                retry_after: None,
            }
        })?;
        let terminal_kind = gemini_stream_terminal_kind(&data);

        Ok(Self {
            data,
            terminal_kind,
        })
    }

    pub fn is_terminal(&self) -> bool {
        self.terminal_kind.is_terminal()
    }

    pub fn is_error(&self) -> bool {
        self.terminal_kind.is_error()
    }

    pub fn usage(&self) -> Option<AdapterUsage> {
        gemini_usage(&self.data)
    }
}

impl GeminiGenerateContentRequest {
    pub fn routing_fields_from_slice(
        body: &[u8],
    ) -> Result<AdapterRoutingFields, GeminiAdapterError> {
        let value: Value = serde_json::from_slice(body)
            .map_err(|error| GeminiAdapterError::InvalidJson(error.to_string()))?;
        let object = value.as_object().ok_or_else(|| {
            GeminiAdapterError::invalid_request("request body must be a JSON object", Some("body"))
        })?;

        let model = match object.get("model") {
            Some(Value::String(model)) => Some(model.clone()),
            Some(Value::Null) | None => None,
            Some(_) => {
                return Err(GeminiAdapterError::invalid_request(
                    "model must be a string",
                    Some("model"),
                ));
            }
        };

        let stream = optional_bool_field(object, "stream")?.unwrap_or(false)
            || optional_bool_field(object, "streamGenerateContent")?.unwrap_or(false);

        Ok(AdapterRoutingFields { model, stream })
    }

    pub fn from_slice(body: &[u8]) -> Result<Self, GeminiAdapterError> {
        let request: Self = serde_json::from_slice(body)
            .map_err(|error| GeminiAdapterError::InvalidJson(error.to_string()))?;
        request.validate()?;
        Ok(request)
    }

    pub fn validate(&self) -> Result<(), GeminiAdapterError> {
        if normalized_generate_content_model(&self.model).is_none() {
            return Err(GeminiAdapterError::InvalidRequest {
                message: "model must be a non-empty safe model path segment".to_string(),
                param: Some("model"),
            });
        }

        if self.contents.is_empty() {
            return Err(GeminiAdapterError::InvalidRequest {
                message: "contents must contain at least one content item".to_string(),
                param: Some("contents"),
            });
        }

        for (index, content) in self.contents.iter().enumerate() {
            if content.parts.is_empty() {
                return Err(GeminiAdapterError::InvalidRequest {
                    message: format!("contents[{index}].parts must contain at least one part"),
                    param: Some("contents"),
                });
            }
        }

        Ok(())
    }

    pub fn is_streaming(&self) -> bool {
        self.streaming_param().is_some()
    }

    pub fn streaming_param(&self) -> Option<&'static str> {
        if self.stream.unwrap_or(false) {
            Some("stream")
        } else if self.stream_generate_content.unwrap_or(false) {
            Some("streamGenerateContent")
        } else {
            None
        }
    }

    pub fn to_upstream_request(&self) -> Result<AdapterUpstreamRequest, GeminiAdapterError> {
        self.validate()?;
        let stream = self.is_streaming();

        Ok(AdapterUpstreamRequest {
            method: "POST".to_string(),
            path: if stream {
                stream_generate_content_path(&self.model)
            } else {
                generate_content_path(&self.model)
            },
            body: serde_json::to_value(self)
                .map_err(|error| GeminiAdapterError::RequestSerialize(error.to_string()))?,
            stream,
        })
    }

    pub fn from_openai_chat_request(
        request: &ChatCompletionRequest,
    ) -> Result<Self, GeminiAdapterError> {
        request.validate().map_err(|error| {
            GeminiAdapterError::invalid_request(error.to_string(), Some("body"))
        })?;

        let mut contents = Vec::new();
        let mut system_parts = Vec::new();

        for (index, message) in request.messages.iter().enumerate() {
            let parts = gemini_text_parts_from_openai_message(message, index)?;

            match message.role.as_str() {
                "system" | "developer" => system_parts.extend(parts),
                "assistant" => contents.push(GeminiContent {
                    role: Some("model".to_string()),
                    parts,
                    extra: Map::new(),
                }),
                "user" => contents.push(GeminiContent {
                    role: Some("user".to_string()),
                    parts,
                    extra: Map::new(),
                }),
                role if role.trim().is_empty() => {
                    return Err(GeminiAdapterError::invalid_request(
                        format!("messages[{index}].role must be a non-empty string"),
                        Some("messages"),
                    ));
                }
                role => {
                    return Err(GeminiAdapterError::invalid_request(
                        format!(
                            "messages[{index}].role '{role}' is not supported by Gemini text conversion"
                        ),
                        Some("messages"),
                    ));
                }
            }
        }

        if contents.is_empty() {
            return Err(GeminiAdapterError::invalid_request(
                "messages must contain at least one user or assistant message",
                Some("messages"),
            ));
        }

        Ok(Self {
            model: request.model.clone(),
            contents,
            system_instruction: if system_parts.is_empty() {
                None
            } else {
                Some(json!({ "parts": system_parts }))
            },
            tools: None,
            tool_config: None,
            safety_settings: None,
            generation_config: gemini_generation_config_from_openai_chat(request)?,
            cached_content: None,
            stream: request.stream,
            stream_generate_content: None,
            extra: Map::new(),
        })
    }
}

impl GeminiAdapterError {
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
            Self::UpstreamInvalidResponse { .. } => 502,
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
            Self::UpstreamInvalidResponse {
                status, message, ..
            } => error_body(
                "provider_error",
                "provider_invalid_response",
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
            | Self::UpstreamInvalidJson { retry_after, .. }
            | Self::UpstreamInvalidResponse { retry_after, .. } => retry_after.as_ref(),
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
            }
            | Self::UpstreamInvalidResponse {
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

impl Adapter for GeminiAdapter {
    fn protocol_mode(&self) -> ProtocolMode {
        ProtocolMode::Gemini
    }

    fn capabilities(&self) -> AdapterCapabilities {
        AdapterCapabilities {
            operations: vec![
                AdapterOperation::GenerateContent,
                AdapterOperation::ChatCompletions,
            ],
            stream_policy: AdapterStreamPolicy::Parse,
        }
    }

    fn extract_model(&self, body: &[u8]) -> Result<Option<String>, GatewayError> {
        self.extract_routing_fields(body).map(|fields| fields.model)
    }

    fn extract_routing_fields(&self, body: &[u8]) -> Result<AdapterRoutingFields, GatewayError> {
        GeminiGenerateContentRequest::routing_fields_from_slice(body)
            .map_err(|error| error.to_gateway_error())
    }

    fn build_upstream_request(
        &self,
        operation: AdapterOperation,
        body: &[u8],
    ) -> Result<AdapterUpstreamRequest, GatewayError> {
        match operation {
            AdapterOperation::GenerateContent => {
                let request = GeminiGenerateContentRequest::from_slice(body)
                    .map_err(|error| error.to_gateway_error())?;
                self.build_generate_content_request(&request)
                    .map_err(|error| error.to_gateway_error())
            }
            AdapterOperation::ChatCompletions => {
                let request = ChatCompletionRequest::from_slice(body).map_err(|error| {
                    GatewayError::new(
                        GatewayErrorOwner::Client,
                        error.to_adapter_error_mapping().code,
                        error.to_string(),
                    )
                })?;
                let request = GeminiGenerateContentRequest::from_openai_chat_request(&request)
                    .map_err(|error| error.to_gateway_error())?;
                self.build_generate_content_request(&request)
                    .map_err(|error| error.to_gateway_error())
            }
            _ => Err(unsupported_gemini_operation(
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
            AdapterOperation::GenerateContent => {
                Self::parse_generate_content_response(status, body)
                    .map_err(|error| error.to_gateway_error())
            }
            AdapterOperation::ChatCompletions => {
                Self::parse_chat_completions_response(status, body)
                    .map_err(|error| error.to_gateway_error())
            }
            _ => Err(unsupported_gemini_operation(operation, "parse_response")),
        }
    }

    fn parse_stream_event(
        &self,
        operation: AdapterOperation,
        event: &[u8],
    ) -> Result<Value, GatewayError> {
        match operation {
            AdapterOperation::GenerateContent => Self::parse_generate_content_stream_event(event)
                .map(|event| event.data)
                .map_err(|error| error.to_gateway_error()),
            AdapterOperation::ChatCompletions => Self::parse_chat_completions_stream_event(event)
                .map_err(|error| error.to_gateway_error()),
            _ => Err(unsupported_gemini_operation(
                operation,
                "parse_stream_event",
            )),
        }
    }

    fn extract_usage(&self, response: &Value) -> Option<AdapterUsage> {
        gemini_usage(response).or_else(|| openai_chat_usage(response))
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

fn optional_bool_field(
    object: &Map<String, Value>,
    field: &'static str,
) -> Result<Option<bool>, GeminiAdapterError> {
    match object.get(field) {
        Some(Value::Bool(value)) => Ok(Some(*value)),
        Some(Value::Null) | None => Ok(None),
        Some(_) => Err(GeminiAdapterError::invalid_request(
            format!("{field} must be a boolean"),
            Some(field),
        )),
    }
}

fn gemini_text_parts_from_openai_message(
    message: &ChatMessage,
    index: usize,
) -> Result<Vec<Value>, GeminiAdapterError> {
    let Some(content) = message
        .content
        .as_ref()
        .filter(|content| !content.is_null())
    else {
        return Err(GeminiAdapterError::invalid_request(
            format!("messages[{index}].content is required for Gemini text conversion"),
            Some("messages"),
        ));
    };

    match content {
        Value::String(text) => gemini_text_part(text, index).map(|part| vec![part]),
        Value::Array(items) => {
            let mut parts = Vec::new();

            for item in items {
                let part_type = item.get("type").and_then(Value::as_str);
                if part_type.is_some_and(|kind| kind != "text") {
                    return Err(GeminiAdapterError::invalid_request(
                        format!("messages[{index}].content only supports text parts"),
                        Some("messages"),
                    ));
                }

                let text = item.get("text").and_then(Value::as_str).ok_or_else(|| {
                    GeminiAdapterError::invalid_request(
                        format!("messages[{index}].content text parts require text"),
                        Some("messages"),
                    )
                })?;
                parts.push(gemini_text_part(text, index)?);
            }

            if parts.is_empty() {
                return Err(GeminiAdapterError::invalid_request(
                    format!("messages[{index}].content must include at least one text part"),
                    Some("messages"),
                ));
            }

            Ok(parts)
        }
        _ => Err(GeminiAdapterError::invalid_request(
            format!("messages[{index}].content must be a string or text part array"),
            Some("messages"),
        )),
    }
}

fn gemini_text_part(text: &str, index: usize) -> Result<Value, GeminiAdapterError> {
    if text.trim().is_empty() {
        return Err(GeminiAdapterError::invalid_request(
            format!("messages[{index}].content text must be non-empty"),
            Some("messages"),
        ));
    }

    Ok(json!({ "text": text }))
}

fn gemini_generation_config_from_openai_chat(
    request: &ChatCompletionRequest,
) -> Result<Option<Value>, GeminiAdapterError> {
    let mut config = Map::new();

    if let Some(temperature) = request.extra.get("temperature") {
        if !temperature.is_number() {
            return Err(GeminiAdapterError::invalid_request(
                "temperature must be a number",
                Some("temperature"),
            ));
        }
        config.insert("temperature".to_string(), temperature.clone());
    }

    let max_tokens = request
        .extra
        .get("max_tokens")
        .or_else(|| request.extra.get("max_completion_tokens"));
    if let Some(max_tokens) = max_tokens {
        let Some(max_tokens) = max_tokens.as_u64().filter(|value| *value > 0) else {
            return Err(GeminiAdapterError::invalid_request(
                "max_tokens must be a positive integer",
                Some("max_tokens"),
            ));
        };
        config.insert("maxOutputTokens".to_string(), json!(max_tokens));
    }

    if config.is_empty() {
        Ok(None)
    } else {
        Ok(Some(Value::Object(config)))
    }
}

fn generate_content_path(model: &str) -> String {
    let model = normalized_generate_content_model(model)
        .expect("GeminiGenerateContentRequest::validate checks model path safety");

    format!("{GENERATE_CONTENT_PATH_PREFIX}{model}{GENERATE_CONTENT_PATH_SUFFIX}")
}

fn stream_generate_content_path(model: &str) -> String {
    let model = normalized_generate_content_model(model)
        .expect("GeminiGenerateContentRequest::validate checks model path safety");

    format!("{GENERATE_CONTENT_PATH_PREFIX}{model}{STREAM_GENERATE_CONTENT_PATH_SUFFIX}")
}

fn normalized_generate_content_model(model: &str) -> Option<&str> {
    let model = model.trim().trim_start_matches('/');
    let model = model.strip_prefix("models/").unwrap_or(model);

    if !model.is_empty()
        && model
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_'))
    {
        Some(model)
    } else {
        None
    }
}

fn gemini_stream_terminal_kind(data: &Value) -> GeminiStreamTerminalKind {
    if data.get("error").is_some_and(Value::is_object) {
        return GeminiStreamTerminalKind::Error;
    }

    data.get("candidates")
        .and_then(Value::as_array)
        .and_then(|candidates| {
            candidates.iter().find_map(|candidate| {
                candidate
                    .get("finishReason")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|finish_reason| !finish_reason.is_empty())
                    .map(|finish_reason| {
                        GeminiStreamTerminalKind::FinishReason(finish_reason.to_string())
                    })
            })
        })
        .unwrap_or(GeminiStreamTerminalKind::None)
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

fn parse_gemini_json_response(
    status: u16,
    body: &[u8],
    retry_after: Option<AdapterRetryAfter>,
) -> Result<Value, GeminiAdapterError> {
    let json = match serde_json::from_slice::<Value>(body) {
        Ok(json) => json,
        Err(error) => {
            return Err(GeminiAdapterError::UpstreamInvalidJson {
                status,
                message: error.to_string(),
                retry_after,
            });
        }
    };

    if !(200..300).contains(&status) {
        return Err(GeminiAdapterError::UpstreamStatus {
            status,
            body: json,
            retry_after,
        });
    }

    Ok(json)
}

fn gemini_generate_content_to_openai_chat_completion(
    response: &Value,
    status: u16,
    retry_after: Option<AdapterRetryAfter>,
) -> Result<Value, GeminiAdapterError> {
    let candidates = response
        .get("candidates")
        .and_then(Value::as_array)
        .ok_or_else(|| GeminiAdapterError::UpstreamInvalidResponse {
            status,
            message: "response.candidates must be an array".to_string(),
            retry_after: retry_after.clone(),
        })?;

    let choices = candidates
        .iter()
        .enumerate()
        .map(|(fallback_index, candidate)| {
            gemini_candidate_to_openai_chat_choice(
                candidate,
                fallback_index,
                status,
                retry_after.clone(),
            )
        })
        .collect::<Result<Vec<_>, _>>()?;

    let model = response
        .get("modelVersion")
        .and_then(Value::as_str)
        .map(str::to_string)
        .unwrap_or_else(|| "gemini".to_string());
    let id = response
        .get("responseId")
        .and_then(Value::as_str)
        .filter(|id| !id.trim().is_empty())
        .map(|id| format!("chatcmpl_{id}"))
        .unwrap_or_else(|| "chatcmpl_gemini".to_string());

    let mut completion = json!({
        "id": id,
        "object": "chat.completion",
        "created": 0,
        "model": model,
        "choices": choices,
    });

    if let Some(usage) = gemini_usage(response) {
        completion["usage"] = json!({
            "prompt_tokens": usage.prompt_tokens,
            "completion_tokens": usage.completion_tokens,
            "total_tokens": usage.total_tokens,
        });
    }

    Ok(completion)
}

fn gemini_stream_event_to_openai_chat_completion_chunk(
    event: &Value,
    status: u16,
    retry_after: Option<AdapterRetryAfter>,
) -> Result<Value, GeminiAdapterError> {
    if let Some(error) = event.get("error").filter(|error| error.is_object()) {
        let status = error
            .get("code")
            .and_then(Value::as_u64)
            .and_then(|code| u16::try_from(code).ok())
            .unwrap_or(502);
        return Err(GeminiAdapterError::UpstreamStatus {
            status,
            body: event.clone(),
            retry_after,
        });
    }

    if let Some(block_reason) = event
        .get("promptFeedback")
        .and_then(|feedback| feedback.get("blockReason"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|block_reason| !block_reason.is_empty())
    {
        return Err(GeminiAdapterError::UpstreamInvalidResponse {
            status,
            message: format!("Gemini stream prompt was blocked: {block_reason}"),
            retry_after,
        });
    }

    let candidates = event
        .get("candidates")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[]);
    let choices = candidates
        .iter()
        .enumerate()
        .map(|(fallback_index, candidate)| {
            gemini_stream_candidate_to_openai_chat_chunk_choice(
                candidate,
                fallback_index,
                status,
                retry_after.clone(),
            )
        })
        .collect::<Result<Vec<_>, _>>()?;
    let model = event
        .get("modelVersion")
        .and_then(Value::as_str)
        .map(str::to_string)
        .unwrap_or_else(|| "gemini".to_string());
    let id = event
        .get("responseId")
        .and_then(Value::as_str)
        .filter(|id| !id.trim().is_empty())
        .map(|id| format!("chatcmpl_{id}"))
        .unwrap_or_else(|| "chatcmpl_gemini".to_string());

    let mut chunk = json!({
        "id": id,
        "object": "chat.completion.chunk",
        "created": 0,
        "model": model,
        "choices": choices,
    });

    if let Some(usage) = gemini_usage(event) {
        chunk["usage"] = json!({
            "prompt_tokens": usage.prompt_tokens,
            "completion_tokens": usage.completion_tokens,
            "total_tokens": usage.total_tokens,
        });
    }

    Ok(chunk)
}

fn gemini_stream_candidate_to_openai_chat_chunk_choice(
    candidate: &Value,
    fallback_index: usize,
    status: u16,
    retry_after: Option<AdapterRetryAfter>,
) -> Result<Value, GeminiAdapterError> {
    if !candidate.is_object() {
        return Err(GeminiAdapterError::UpstreamInvalidResponse {
            status,
            message: "response.candidates entries must be objects".to_string(),
            retry_after,
        });
    }

    let index = candidate
        .get("index")
        .and_then(Value::as_u64)
        .unwrap_or(fallback_index as u64);
    let mut delta = Map::new();

    if candidate
        .get("content")
        .and_then(|content| content.get("role"))
        .and_then(Value::as_str)
        .is_some_and(|role| role == "model")
    {
        delta.insert("role".to_string(), Value::String("assistant".to_string()));
    }

    let content = gemini_candidate_text(candidate);
    if !content.is_empty() {
        delta.insert("content".to_string(), Value::String(content));
    }

    let finish_reason = match candidate
        .get("finishReason")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|finish_reason| !finish_reason.is_empty())
    {
        Some(raw_finish_reason) => {
            let mapped_finish_reason =
                gemini_finish_reason(raw_finish_reason).ok_or_else(|| {
                    GeminiAdapterError::UpstreamInvalidResponse {
                        status,
                        message: format!("unsupported Gemini finishReason '{raw_finish_reason}'"),
                        retry_after,
                    }
                })?;
            Value::String(mapped_finish_reason.to_string())
        }
        None => Value::Null,
    };

    Ok(json!({
        "index": index,
        "delta": Value::Object(delta),
        "finish_reason": finish_reason,
    }))
}

fn gemini_candidate_to_openai_chat_choice(
    candidate: &Value,
    fallback_index: usize,
    status: u16,
    retry_after: Option<AdapterRetryAfter>,
) -> Result<Value, GeminiAdapterError> {
    let raw_finish_reason = candidate
        .get("finishReason")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|finish_reason| !finish_reason.is_empty())
        .ok_or_else(|| GeminiAdapterError::UpstreamInvalidResponse {
            status,
            message: "response.candidates must include a terminal finishReason".to_string(),
            retry_after: retry_after.clone(),
        })?;
    let finish_reason = gemini_finish_reason(raw_finish_reason).ok_or_else(|| {
        GeminiAdapterError::UpstreamInvalidResponse {
            status,
            message: format!("unsupported Gemini finishReason '{raw_finish_reason}'"),
            retry_after: retry_after.clone(),
        }
    })?;
    let index = candidate
        .get("index")
        .and_then(Value::as_u64)
        .unwrap_or(fallback_index as u64);
    let content = gemini_candidate_text(candidate);

    Ok(json!({
        "index": index,
        "message": {
            "role": "assistant",
            "content": content,
        },
        "finish_reason": finish_reason,
    }))
}

fn gemini_candidate_text(candidate: &Value) -> String {
    candidate
        .get("content")
        .and_then(|content| content.get("parts"))
        .and_then(Value::as_array)
        .map(|parts| {
            parts
                .iter()
                .filter_map(|part| part.get("text").and_then(Value::as_str))
                .collect::<String>()
        })
        .unwrap_or_default()
}

fn gemini_generate_content_terminal(
    response: &Value,
    status: u16,
    retry_after: Option<AdapterRetryAfter>,
) -> Result<GeminiGenerateContentTerminal, GeminiAdapterError> {
    let candidates = response
        .get("candidates")
        .and_then(Value::as_array)
        .filter(|candidates| !candidates.is_empty())
        .ok_or_else(|| GeminiAdapterError::UpstreamInvalidResponse {
            status,
            message: "response.candidates must be a non-empty array".to_string(),
            retry_after: retry_after.clone(),
        })?;

    let raw_finish_reason = candidates
        .iter()
        .find_map(|candidate| {
            candidate
                .get("finishReason")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|finish_reason| !finish_reason.is_empty())
        })
        .ok_or_else(|| GeminiAdapterError::UpstreamInvalidResponse {
            status,
            message: "response.candidates must include a terminal finishReason".to_string(),
            retry_after: retry_after.clone(),
        })?;

    let mapped_finish_reason = gemini_finish_reason(raw_finish_reason).ok_or_else(|| {
        GeminiAdapterError::UpstreamInvalidResponse {
            status,
            message: format!("unsupported Gemini finishReason '{raw_finish_reason}'"),
            retry_after,
        }
    })?;

    Ok(GeminiGenerateContentTerminal {
        finish_reason: raw_finish_reason.to_string(),
        mapped_finish_reason: mapped_finish_reason.to_string(),
    })
}

fn gemini_finish_reason(finish_reason: &str) -> Option<&'static str> {
    match finish_reason.trim() {
        "STOP" => Some("stop"),
        "MAX_TOKENS" => Some("length"),
        "SAFETY" | "RECITATION" => Some("content_filter"),
        "OTHER" => Some("other"),
        _ => None,
    }
}

fn gemini_generate_content_protocol_metadata(response: &Value) -> Value {
    let raw_finish_reason = response
        .get("candidates")
        .and_then(Value::as_array)
        .and_then(|candidates| {
            candidates.iter().find_map(|candidate| {
                candidate
                    .get("finishReason")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|finish_reason| !finish_reason.is_empty())
            })
        });
    let mapped_finish_reason = raw_finish_reason.and_then(gemini_finish_reason);
    let error = response.get("error").filter(|error| error.is_object());
    let block_reason = response
        .get("promptFeedback")
        .and_then(|feedback| feedback.get("blockReason"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|reason| !reason.is_empty());
    let candidate_count = response
        .get("candidates")
        .and_then(Value::as_array)
        .map(Vec::len)
        .unwrap_or_default();
    let safety_rating_count = response
        .get("candidates")
        .and_then(Value::as_array)
        .map(|candidates| {
            candidates
                .iter()
                .filter_map(|candidate| candidate.get("safetyRatings").and_then(Value::as_array))
                .map(Vec::len)
                .sum::<usize>()
        })
        .unwrap_or_default();
    let terminal_status = if error.is_some() {
        "error"
    } else if block_reason.is_some() {
        "blocked"
    } else if raw_finish_reason.is_some() && mapped_finish_reason.is_some() {
        "completed"
    } else if raw_finish_reason.is_some() {
        "unsupported_finish_reason"
    } else {
        "missing_terminal"
    };
    let usage = gemini_usage(response);

    json!({
        "schema": "gemini_generate_content_protocol_metadata_v1",
        "protocol": "gemini_generate_content",
        "terminal_status": terminal_status,
        "candidate_count": candidate_count,
        "finish_reason": {
            "present": raw_finish_reason.is_some(),
            "raw": raw_finish_reason,
            "mapped": mapped_finish_reason,
        },
        "error": {
            "present": error.is_some(),
            "code": error.and_then(|error| error.get("code")).and_then(Value::as_u64),
            "status": error.and_then(|error| error.get("status")).and_then(Value::as_str),
        },
        "safety": {
            "prompt_block_reason": block_reason,
            "blocked": block_reason.is_some() || matches!(mapped_finish_reason, Some("content_filter")),
            "safety_rating_count": safety_rating_count,
        },
        "usage": {
            "usage_metadata_present": response.get("usageMetadata").is_some(),
            "prompt_tokens": usage.as_ref().and_then(|usage| usage.prompt_tokens),
            "completion_tokens": usage.as_ref().and_then(|usage| usage.completion_tokens),
            "total_tokens": usage.as_ref().and_then(|usage| usage.total_tokens),
        },
        "payload_body_omitted": true,
    })
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

fn unsupported_gemini_operation(operation: AdapterOperation, method: &str) -> GatewayError {
    GatewayError::new(
        GatewayErrorOwner::Gateway,
        "adapter_operation_unsupported",
        format!("Gemini adapter does not implement {method} for {operation:?}"),
    )
}

fn gemini_usage(response: &Value) -> Option<AdapterUsage> {
    let usage = response.get("usageMetadata")?;
    let prompt_tokens = usage.get("promptTokenCount").and_then(Value::as_u64);
    let raw_completion_tokens = usage.get("candidatesTokenCount").and_then(Value::as_u64);
    let raw_total_tokens = usage.get("totalTokenCount").and_then(Value::as_u64);
    let completion_tokens = raw_completion_tokens.or_else(|| {
        raw_total_tokens
            .zip(prompt_tokens)
            .and_then(|(total_tokens, prompt_tokens)| total_tokens.checked_sub(prompt_tokens))
    });
    let total_tokens = usage
        .get("totalTokenCount")
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

fn openai_chat_usage(response: &Value) -> Option<AdapterUsage> {
    let usage = response.get("usage")?;

    Some(AdapterUsage {
        prompt_tokens: usage.get("prompt_tokens").and_then(Value::as_u64),
        completion_tokens: usage.get("completion_tokens").and_then(Value::as_u64),
        total_tokens: usage.get("total_tokens").and_then(Value::as_u64),
    })
}

#[cfg(test)]
mod tests {
    use std::{fs, path::PathBuf};

    use ai_gateway_shared::GatewayErrorOwner;

    use super::*;

    fn load_gemini_fixture(file_name: &str) -> Value {
        let path = gemini_fixture_path(file_name);
        let contents = fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("failed to read fixture {}: {error}", path.display()));

        serde_json::from_str(&contents)
            .unwrap_or_else(|error| panic!("failed to parse fixture {}: {error}", path.display()))
    }

    fn gemini_fixture_path(file_name: &str) -> PathBuf {
        let mut path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        path.pop();
        path.pop();
        path.push("tests");
        path.push("fixtures");
        path.push("adapters");
        path.push("gemini");
        path.push(file_name);
        path
    }

    fn load_gemini_stream_fixture(file_name: &str) -> String {
        let path = gemini_fixture_path(&format!("streams/{file_name}"));
        fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("failed to read fixture {}: {error}", path.display()))
    }

    fn sse_fixture_events(file_name: &str) -> Vec<Vec<u8>> {
        load_gemini_stream_fixture(file_name)
            .split("\n\n")
            .filter_map(|block| {
                let data = block
                    .lines()
                    .filter_map(|line| {
                        let line = line.trim_end_matches('\r');
                        line.strip_prefix("data:")
                            .map(|value| value.strip_prefix(' ').unwrap_or(value).to_string())
                    })
                    .collect::<Vec<_>>();

                if data.is_empty() {
                    None
                } else {
                    Some(data.join("\n").into_bytes())
                }
            })
            .collect()
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

    fn assert_finish_reason_mapping_matches(parsed: &Value, expected: &Value) {
        let terminal = GeminiAdapter::generate_content_terminal(parsed)
            .expect("Gemini response should expose candidate terminal");

        assert_eq!(
            terminal.finish_reason,
            expected["finishReason"].as_str().expect("finishReason")
        );
        assert_eq!(
            terminal.mapped_finish_reason,
            expected["finish_reason"].as_str().expect("finish_reason")
        );
        assert_eq!(
            GeminiAdapter::finish_reason_for_finish_reason(&terminal.finish_reason),
            Some(terminal.mapped_finish_reason.as_str())
        );
    }

    #[test]
    fn adapter_contract_declares_generate_content_surface_with_parseable_streaming() {
        let adapter = GeminiAdapter::new();
        let capabilities = adapter.capabilities();

        assert_eq!(adapter.protocol_mode(), ProtocolMode::Gemini);
        assert!(capabilities.supports(AdapterOperation::GenerateContent));
        assert!(capabilities.supports(AdapterOperation::ChatCompletions));
        assert_eq!(capabilities.stream_policy, AdapterStreamPolicy::Parse);
    }

    #[test]
    fn extracts_routing_fields_from_body_stream_flags_and_defaults_false_without_them() {
        let adapter = GeminiAdapter::new();
        let fields = adapter
            .extract_routing_fields(br#"{"model":"gemini-fixture","streamGenerateContent":true}"#)
            .expect("routing fields should parse streamGenerateContent flag");

        assert_eq!(fields.model.as_deref(), Some("gemini-fixture"));
        assert!(fields.stream);

        let fields = adapter
            .extract_routing_fields(br#"{"model":"gemini-fixture"}"#)
            .expect("routing fields should parse without full request validation");

        assert_eq!(fields.model.as_deref(), Some("gemini-fixture"));
        assert!(
            !fields.stream,
            "body-only adapter cannot infer a streamGenerateContent path"
        );
    }

    #[test]
    fn validates_required_fields_and_builds_stream_requests() {
        let missing_contents = GeminiGenerateContentRequest::from_slice(
            br#"{"model":"gemini-fixture","contents":[]}"#,
        )
        .expect_err("empty contents should be rejected");
        assert_eq!(missing_contents.http_status(), 400);
        assert_eq!(
            missing_contents.to_adapter_error_body()["error"]["param"],
            "contents"
        );

        let streaming = GeminiGenerateContentRequest::from_slice(
            br#"{"model":"gemini-fixture","contents":[{"parts":[{"text":"hi"}]}],"streamGenerateContent":true}"#,
        )
        .expect("streaming request shape is valid");
        let upstream = streaming
            .to_upstream_request()
            .expect("streaming request should build");
        assert_eq!(
            upstream.path,
            "/v1beta/models/gemini-fixture:streamGenerateContent?alt=sse"
        );
        assert!(upstream.stream);
        assert_eq!(upstream.body["streamGenerateContent"], Value::Null);
    }

    #[test]
    fn normalizes_and_rejects_unsafe_generate_content_model_path_segments() {
        let prefixed = GeminiGenerateContentRequest::from_slice(
            br#"{"model":"models/gemini-fixture","contents":[{"parts":[{"text":"hi"}]}]}"#,
        )
        .expect("models/ prefix should be accepted");
        let upstream = prefixed
            .to_upstream_request()
            .expect("safe prefixed model should build");

        assert_eq!(
            upstream.path,
            "/v1beta/models/gemini-fixture:generateContent"
        );

        for body in [
            br#"{"model":"models/","contents":[{"parts":[{"text":"hi"}]}]}"#.as_slice(),
            br#"{"model":"gemini-fixture?alt=sse","contents":[{"parts":[{"text":"hi"}]}]}"#,
            br#"{"model":"publishers/google/models/gemini-fixture","contents":[{"parts":[{"text":"hi"}]}]}"#,
        ] {
            let error = GeminiGenerateContentRequest::from_slice(body)
                .expect_err("unsafe model path segment should fail validation");
            assert_eq!(error.http_status(), 400);
            assert_eq!(error.to_adapter_error_body()["error"]["param"], "model");
        }
    }

    #[test]
    fn conformance_fixtures_cover_generate_content_request_response_and_errors() {
        let adapter = GeminiAdapter::new();

        let valid = load_gemini_fixture("generate_content_non_stream_valid.json");
        let valid_request = serde_json::to_vec(&valid["request"]).expect("fixture request");
        let upstream = adapter
            .build_upstream_request(AdapterOperation::GenerateContent, &valid_request)
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

        let parsed = adapter
            .parse_response(
                AdapterOperation::GenerateContent,
                fixture_response_status(&valid),
                &fixture_response_body(&valid),
            )
            .expect("valid fixture response should parse");
        assert_eq!(&parsed, &valid["response"]["body"]);
        assert_finish_reason_mapping_matches(&parsed, &valid["expected_finish_reason_mapping"]);

        let usage = adapter
            .extract_usage(&parsed)
            .expect("valid fixture should include usage");
        let actual_usage = serde_json::to_value(usage).expect("usage should serialize");
        assert_eq!(&actual_usage, &valid["expected_usage"]);

        let fallback = load_gemini_fixture("generate_content_usage_total_fallback.json");
        let parsed_fallback = adapter
            .parse_response(
                AdapterOperation::GenerateContent,
                fixture_response_status(&fallback),
                &fixture_response_body(&fallback),
            )
            .expect("usage fallback fixture response should parse");
        assert_finish_reason_mapping_matches(
            &parsed_fallback,
            &fallback["expected_finish_reason_mapping"],
        );
        let fallback_usage = adapter
            .extract_usage(&parsed_fallback)
            .expect("usage fallback fixture should include usage");
        let actual_fallback_usage =
            serde_json::to_value(fallback_usage).expect("usage should serialize");
        assert_eq!(&actual_fallback_usage, &fallback["expected_usage"]);

        let invalid = load_gemini_fixture("invalid_request.json");
        let invalid_request = serde_json::to_vec(&invalid["request"]).expect("fixture request");
        let invalid_error = GeminiGenerateContentRequest::from_slice(&invalid_request)
            .expect_err("invalid request fixture should fail validation");
        let invalid_mapping = invalid_error.to_adapter_error_mapping();
        assert_error_mapping_matches(&invalid_mapping, &invalid["expected_error_mapping"]);

        let gateway_error = adapter
            .build_upstream_request(AdapterOperation::GenerateContent, &invalid_request)
            .expect_err("invalid request fixture should fail adapter build");
        assert_eq!(gateway_error.owner, GatewayErrorOwner::Client);
        assert_eq!(gateway_error.code, invalid_mapping.code);

        let stream = load_gemini_fixture("generate_content_stream_valid.json");
        let stream_request = serde_json::to_vec(&stream["request"]).expect("fixture request");
        let stream_upstream = adapter
            .build_upstream_request(AdapterOperation::GenerateContent, &stream_request)
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

        for fixture_name in [
            "provider_429_retry_after.json",
            "provider_5xx.json",
            "invalid_json_response.json",
        ] {
            let fixture = load_gemini_fixture(fixture_name);
            let headers = fixture_response_headers(&fixture);
            let retry_after = retry_after_from_headers(&headers);
            let error = GeminiAdapter::parse_generate_content_response_with_retry_after(
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

        for fixture_name in [
            "generate_content_missing_candidate_terminal.json",
            "generate_content_invalid_candidate_terminal.json",
        ] {
            let fixture = load_gemini_fixture(fixture_name);
            let error = GeminiAdapter::parse_generate_content_response(
                fixture_response_status(&fixture),
                &fixture_response_body(&fixture),
            )
            .expect_err(&format!(
                "{fixture_name} should fail response terminal validation"
            ));

            assert_error_mapping_matches(
                &error.to_adapter_error_mapping(),
                &fixture["expected_error_mapping"],
            );
        }
    }

    #[test]
    fn openai_chat_fixture_converts_to_gemini_generate_content_shape() {
        let adapter = GeminiAdapter::new();
        let fixture = load_gemini_fixture("openai_chat_to_generate_content_valid.json");
        let request = serde_json::to_vec(&fixture["request"]).expect("fixture request");

        let routing = adapter
            .extract_routing_fields(&request)
            .expect("OpenAI-compatible chat routing fields should parse");
        assert_eq!(routing.model.as_deref(), Some("gemini-1.5-flash"));
        assert!(routing.stream);

        let upstream = adapter
            .build_upstream_request(AdapterOperation::ChatCompletions, &request)
            .expect("OpenAI-compatible chat fixture should convert to Gemini upstream request");
        let expected = &fixture["expected_upstream"];

        assert_eq!(
            upstream.method,
            expected["method"].as_str().expect("method")
        );
        assert_eq!(upstream.path, expected["path"].as_str().expect("path"));
        assert_eq!(
            upstream.stream,
            expected["stream"].as_bool().expect("stream")
        );
        assert_eq!(&upstream.body, &expected["body"]);
    }

    #[test]
    fn gemini_generate_content_response_normalizes_to_openai_chat_completion_shape() {
        let adapter = GeminiAdapter::new();

        for fixture_name in [
            "openai_chat_response_from_generate_content_valid.json",
            "openai_chat_response_empty_candidates.json",
        ] {
            let fixture = load_gemini_fixture(fixture_name);
            let parsed = adapter
                .parse_response(
                    AdapterOperation::ChatCompletions,
                    fixture_response_status(&fixture),
                    &fixture_response_body(&fixture),
                )
                .expect("Gemini response should normalize to OpenAI chat response");

            assert_eq!(&parsed, &fixture["expected_response"]);

            let usage = adapter
                .extract_usage(&parsed)
                .expect("normalized OpenAI chat response should expose usage");
            let actual_usage = serde_json::to_value(usage).expect("usage should serialize");
            assert_eq!(&actual_usage, &fixture["expected_usage"]);
        }
    }

    #[test]
    fn gemini_chat_response_normalization_rejects_invalid_candidate_terminal() {
        let adapter = GeminiAdapter::new();

        for fixture_name in [
            "generate_content_missing_candidate_terminal.json",
            "generate_content_invalid_candidate_terminal.json",
        ] {
            let fixture = load_gemini_fixture(fixture_name);
            let error = adapter
                .parse_response(
                    AdapterOperation::ChatCompletions,
                    fixture_response_status(&fixture),
                    &fixture_response_body(&fixture),
                )
                .expect_err("invalid Gemini terminal should fail chat response normalization");

            assert_eq!(error.owner, GatewayErrorOwner::Gateway);
            assert_eq!(error.code, "provider_invalid_response");
        }
    }

    #[test]
    fn openai_chat_to_gemini_rejects_unsupported_non_text_shapes() {
        let adapter = GeminiAdapter::new();

        for (body, param) in [
            (
                br#"{"model":"gemini-fixture","messages":[{"role":"tool","content":"result"}]}"#
                    .as_slice(),
                "messages",
            ),
            (
                br#"{"model":"gemini-fixture","messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"https://example.invalid/image.png"}}]}]}"#,
                "messages",
            ),
            (
                br#"{"model":"gemini-fixture","messages":[{"role":"user","content":"hi"}],"temperature":"low"}"#,
                "temperature",
            ),
            (
                br#"{"model":"gemini-fixture","messages":[{"role":"user","content":"hi"}],"max_tokens":0}"#,
                "max_tokens",
            ),
        ] {
            let error = adapter
                .build_upstream_request(AdapterOperation::ChatCompletions, body)
                .expect_err("unsupported OpenAI-compatible chat shape should fail conversion");

            assert_eq!(error.owner, GatewayErrorOwner::Client);
            assert_eq!(error.code, "invalid_request");
            assert!(
                error.message.contains(param),
                "error message should name {param}: {}",
                error.message
            );
        }
    }

    #[test]
    fn stream_fixture_parses_generate_content_event_json_only() {
        let adapter = GeminiAdapter::new();
        let fixture = load_gemini_fixture("stream_generate_content_event.json");
        let event = json_body_bytes(&fixture["event"]);
        let parsed = adapter
            .parse_stream_event(AdapterOperation::GenerateContent, &event)
            .expect("stream event JSON should parse");

        assert_eq!(&parsed, &fixture["expected_event"]);
    }

    #[test]
    fn chat_completion_stream_fixtures_normalize_to_openai_chunks() {
        let adapter = GeminiAdapter::new();
        let events = sse_fixture_events("chat_completion_stream_normalized.sse");
        assert_eq!(events.len(), 2);

        let first = adapter
            .parse_stream_event(AdapterOperation::ChatCompletions, &events[0])
            .expect("first Gemini chat stream event should normalize");
        assert_eq!(
            first,
            json!({
                "id": "chatcmpl_stream-1",
                "object": "chat.completion.chunk",
                "created": 0,
                "model": "gemini-1.5-flash",
                "choices": [
                    {
                        "index": 0,
                        "delta": {
                            "role": "assistant",
                            "content": "Hel"
                        },
                        "finish_reason": null
                    }
                ]
            })
        );

        let second = adapter
            .parse_stream_event(AdapterOperation::ChatCompletions, &events[1])
            .expect("terminal Gemini chat stream event should normalize");
        assert_eq!(
            second,
            json!({
                "id": "chatcmpl_stream-1",
                "object": "chat.completion.chunk",
                "created": 0,
                "model": "gemini-1.5-flash",
                "choices": [
                    {
                        "index": 0,
                        "delta": {
                            "content": "lo"
                        },
                        "finish_reason": "stop"
                    }
                ],
                "usage": {
                    "prompt_tokens": 3,
                    "completion_tokens": 2,
                    "total_tokens": 5
                }
            })
        );
    }

    #[test]
    fn chat_completion_stream_empty_blocked_error_and_unsupported_finish_are_explicit() {
        let adapter = GeminiAdapter::new();

        let empty = adapter
            .parse_stream_event(AdapterOperation::ChatCompletions, br#"{}"#)
            .expect("empty Gemini stream event should normalize to an empty OpenAI chunk");
        assert_eq!(
            empty,
            json!({
                "id": "chatcmpl_gemini",
                "object": "chat.completion.chunk",
                "created": 0,
                "model": "gemini",
                "choices": []
            })
        );

        let blocked = sse_fixture_events("chat_completion_stream_blocked.sse");
        let error = adapter
            .parse_stream_event(AdapterOperation::ChatCompletions, &blocked[0])
            .expect_err("blocked Gemini prompt should map to a structured adapter error");
        assert_eq!(error.owner, GatewayErrorOwner::Gateway);
        assert_eq!(error.code, "provider_invalid_response");
        assert!(error.message.contains("blocked"));

        let error = adapter
            .parse_stream_event(
                AdapterOperation::ChatCompletions,
                br#"{"candidates":[{"index":0,"finishReason":"UNEXPECTED_REASON"}]}"#,
            )
            .expect_err("unsupported Gemini finish reason should map to an adapter error");
        assert_eq!(error.owner, GatewayErrorOwner::Gateway);
        assert_eq!(error.code, "provider_invalid_response");
        assert!(error.message.contains("unsupported Gemini finishReason"));

        let error = adapter
            .parse_stream_event(
                AdapterOperation::ChatCompletions,
                br#"{"error":{"code":429,"message":"quota exceeded","status":"RESOURCE_EXHAUSTED"}}"#,
            )
            .expect_err("Gemini stream error event should map to a provider error");
        assert_eq!(error.owner, GatewayErrorOwner::Provider);
        assert_eq!(error.code, "provider_429");
    }

    #[test]
    fn stream_fixtures_parse_finish_reason_error_usage_and_invalid_json() {
        let completed = sse_fixture_events("generate_content_stream_completed.sse")
            .into_iter()
            .map(|data| {
                GeminiAdapter::parse_generate_content_stream_event(&data)
                    .expect("completed stream fixture event should parse")
            })
            .collect::<Vec<_>>();

        assert_eq!(completed.len(), 1);
        assert_eq!(
            completed[0].data["candidates"][0]["content"]["parts"][0]["text"],
            "Hello"
        );
        assert_eq!(
            completed[0].terminal_kind,
            GeminiStreamTerminalKind::FinishReason("STOP".to_string())
        );
        assert!(completed[0].is_terminal());
        assert!(!completed[0].is_error());

        let missing_terminal = sse_fixture_events("generate_content_stream_missing_terminal.sse")
            .into_iter()
            .map(|data| {
                GeminiAdapter::parse_generate_content_stream_event(&data)
                    .expect("missing-terminal stream fixture event should parse")
            })
            .collect::<Vec<_>>();
        assert_eq!(missing_terminal.len(), 1);
        assert_eq!(
            missing_terminal[0].terminal_kind,
            GeminiStreamTerminalKind::None
        );
        assert!(!missing_terminal[0].is_terminal());

        let error = GeminiAdapter::parse_generate_content_stream_event(
            br#"{"error":{"code":429,"message":"quota exceeded","status":"RESOURCE_EXHAUSTED"}}"#,
        )
        .expect("Gemini stream error event should parse");
        assert_eq!(error.terminal_kind, GeminiStreamTerminalKind::Error);
        assert!(error.is_terminal());
        assert!(error.is_error());

        let invalid = sse_fixture_events("generate_content_stream_invalid_json.sse");
        let data = invalid.first().expect("invalid JSON fixture event");
        let error = GeminiAdapter::parse_generate_content_stream_event(data)
            .expect_err("invalid JSON stream fixture should map to parser error");
        let mapping = error.to_adapter_error_mapping();
        assert_eq!(mapping.http_status, 502);
        assert_eq!(mapping.code, "provider_invalid_json");
        assert_eq!(mapping.owner, "parser");
        assert_eq!(mapping.stage, "response_transform");
    }

    #[test]
    fn gemini_finish_reason_mapping_covers_stable_finish_reason_subset() {
        assert_eq!(
            GeminiAdapter::finish_reason_for_finish_reason("STOP"),
            Some("stop")
        );
        assert_eq!(
            GeminiAdapter::finish_reason_for_finish_reason("MAX_TOKENS"),
            Some("length")
        );
        assert_eq!(
            GeminiAdapter::finish_reason_for_finish_reason("SAFETY"),
            Some("content_filter")
        );
        assert_eq!(
            GeminiAdapter::finish_reason_for_finish_reason("RECITATION"),
            Some("content_filter")
        );
        assert_eq!(
            GeminiAdapter::finish_reason_for_finish_reason("OTHER"),
            Some("other")
        );
        assert_eq!(
            GeminiAdapter::finish_reason_for_finish_reason("UNEXPECTED_REASON"),
            None
        );
    }

    #[test]
    fn gemini_generate_content_protocol_metadata_reads_terminal_usage_safety_and_error() {
        let completed = GeminiAdapter::generate_content_protocol_metadata(&json!({
            "candidates": [{
                "index": 0,
                "finishReason": "SAFETY",
                "safetyRatings": [
                    {"category": "HARM_CATEGORY_DANGEROUS_CONTENT", "probability": "MEDIUM"}
                ]
            }],
            "usageMetadata": {
                "promptTokenCount": 7,
                "totalTokenCount": 11
            }
        }));
        assert_eq!(completed["terminal_status"], "completed");
        assert_eq!(completed["finish_reason"]["raw"], "SAFETY");
        assert_eq!(completed["finish_reason"]["mapped"], "content_filter");
        assert_eq!(completed["safety"]["blocked"], true);
        assert_eq!(completed["safety"]["safety_rating_count"], 1);
        assert_eq!(completed["usage"]["prompt_tokens"], 7);
        assert_eq!(completed["usage"]["completion_tokens"], 4);
        assert_eq!(completed["payload_body_omitted"], true);

        let blocked = GeminiAdapter::generate_content_protocol_metadata(&json!({
            "promptFeedback": {"blockReason": "SAFETY"}
        }));
        assert_eq!(blocked["terminal_status"], "blocked");
        assert_eq!(blocked["safety"]["prompt_block_reason"], "SAFETY");

        let error = GeminiAdapter::generate_content_protocol_metadata(&json!({
            "error": {"code": 429, "status": "RESOURCE_EXHAUSTED", "message": "quota"}
        }));
        assert_eq!(error["terminal_status"], "error");
        assert_eq!(error["error"]["present"], true);
        assert_eq!(error["error"]["code"], 429);
        assert_eq!(error["error"]["status"], "RESOURCE_EXHAUSTED");

        let serialized = completed.to_string() + &blocked.to_string() + &error.to_string();
        for forbidden in ["Authorization", "provider_key", "raw_payload", "secret"] {
            assert!(
                !serialized.contains(forbidden),
                "Gemini protocol metadata leaked forbidden marker: {forbidden}"
            );
        }
    }
}
