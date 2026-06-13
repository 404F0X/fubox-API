use ai_gateway_shared::{GatewayError, GatewayErrorOwner};
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub mod anthropic;
pub mod gemini;
pub mod mcp;
pub mod openai;

#[cfg(test)]
mod conformance;

pub use anthropic::{
    AnthropicAdapter, AnthropicAdapterError, AnthropicMessage, AnthropicMessagesRequest,
    AnthropicMessagesStreamEvent, AnthropicStreamTerminalKind, ClaudeCompatibleAdapter,
};

pub use gemini::{
    GeminiAdapter, GeminiAdapterError, GeminiContent, GeminiGenerateContentRequest,
    GeminiGenerateContentStreamEvent, GeminiStreamTerminalKind,
};

pub use mcp::{
    McpAdapter, McpAdapterError, McpJsonRpcRequest, McpJsonRpcResponse, McpRoutingFields,
};

pub use openai::{
    ChatCompletionRequest, ChatMessage, OpenAiAdapterError, OpenAiChatStream,
    OpenAiCompatibleClient, OpenAiEmbeddingRequest, OpenAiResponseRequest,
    OpenAiResponsesStreamEvent, OpenAiResponsesStreamTerminalKind,
};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ProtocolMode {
    OpenAiCompatible,
    Anthropic,
    ClaudeCompatible,
    Gemini,
    Mcp,
    NativePassthrough,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AdapterOperation {
    ChatCompletions,
    Responses,
    Messages,
    Embeddings,
    GenerateContent,
    Models,
    McpInitialize,
    McpToolsList,
    McpToolsCall,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AdapterStreamPolicy {
    Reject,
    PassThrough,
    Parse,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdapterCapabilities {
    pub operations: Vec<AdapterOperation>,
    pub stream_policy: AdapterStreamPolicy,
}

impl AdapterCapabilities {
    pub fn supports(&self, operation: AdapterOperation) -> bool {
        self.operations.contains(&operation)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdapterRoutingFields {
    pub model: Option<String>,
    pub stream: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AdapterUpstreamRequest {
    pub method: String,
    pub path: String,
    pub body: Value,
    pub stream: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdapterUsage {
    pub prompt_tokens: Option<u64>,
    pub completion_tokens: Option<u64>,
    pub total_tokens: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AdapterProviderTransportErrorKind {
    Timeout,
    Connect,
    Body,
    Other,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdapterProviderErrorSignal {
    pub status_code: Option<u16>,
    pub transport: Option<AdapterProviderTransportErrorKind>,
    pub retry_after_ms: Option<u64>,
}

impl AdapterProviderErrorSignal {
    pub const fn from_status(status_code: u16) -> Self {
        Self {
            status_code: Some(status_code),
            transport: None,
            retry_after_ms: None,
        }
    }

    pub const fn from_transport(transport: AdapterProviderTransportErrorKind) -> Self {
        Self {
            status_code: None,
            transport: Some(transport),
            retry_after_ms: None,
        }
    }

    pub const fn with_retry_after_ms(mut self, retry_after_ms: u64) -> Self {
        self.retry_after_ms = Some(retry_after_ms);
        self
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdapterRetryAfter {
    pub header_value: String,
    pub retry_after_ms: Option<u64>,
}

impl AdapterRetryAfter {
    pub fn new(header_value: impl Into<String>, retry_after_ms: Option<u64>) -> Self {
        Self {
            header_value: header_value.into(),
            retry_after_ms,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdapterErrorMapping {
    pub http_status: u16,
    pub error_type: String,
    pub code: String,
    pub message: String,
    pub param: Option<String>,
    pub owner: String,
    pub stage: String,
    pub retryable: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retry_after_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub signal: Option<AdapterProviderErrorSignal>,
}

impl AdapterErrorMapping {
    pub fn retryable_for_status(status: u16) -> Option<bool> {
        match status {
            408 | 429 | 500..=599 => Some(true),
            400..=499 => Some(false),
            _ => None,
        }
    }
}

pub trait Adapter {
    fn protocol_mode(&self) -> ProtocolMode;

    fn capabilities(&self) -> AdapterCapabilities {
        AdapterCapabilities {
            operations: Vec::new(),
            stream_policy: AdapterStreamPolicy::Reject,
        }
    }

    fn extract_model(&self, body: &[u8]) -> Result<Option<String>, GatewayError>;

    fn extract_routing_fields(&self, body: &[u8]) -> Result<AdapterRoutingFields, GatewayError> {
        Ok(AdapterRoutingFields {
            model: self.extract_model(body)?,
            stream: false,
        })
    }

    fn build_upstream_request(
        &self,
        operation: AdapterOperation,
        _body: &[u8],
    ) -> Result<AdapterUpstreamRequest, GatewayError> {
        Err(unsupported_adapter_operation(
            self.protocol_mode(),
            operation,
            "build_upstream_request",
        ))
    }

    fn parse_response(
        &self,
        operation: AdapterOperation,
        _status: u16,
        _body: &[u8],
    ) -> Result<Value, GatewayError> {
        Err(unsupported_adapter_operation(
            self.protocol_mode(),
            operation,
            "parse_response",
        ))
    }

    fn parse_stream_event(
        &self,
        operation: AdapterOperation,
        _event: &[u8],
    ) -> Result<Value, GatewayError> {
        Err(unsupported_adapter_operation(
            self.protocol_mode(),
            operation,
            "parse_stream_event",
        ))
    }

    fn extract_usage(&self, _response: &Value) -> Option<AdapterUsage> {
        None
    }
}

fn unsupported_adapter_operation(
    protocol_mode: ProtocolMode,
    operation: AdapterOperation,
    method: &str,
) -> GatewayError {
    GatewayError::new(
        GatewayErrorOwner::Gateway,
        "adapter_operation_unsupported",
        format!("{protocol_mode:?} adapter does not implement {method} for {operation:?}"),
    )
}
