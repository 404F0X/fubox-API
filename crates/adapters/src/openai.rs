use std::time::Duration;

use ai_gateway_shared::{GatewayError, GatewayErrorOwner};
use reqwest::{
    StatusCode,
    header::{AUTHORIZATION, CONTENT_TYPE, HeaderMap, HeaderValue, RETRY_AFTER},
};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use thiserror::Error;

use crate::{
    Adapter, AdapterCapabilities, AdapterErrorMapping, AdapterOperation,
    AdapterProviderErrorSignal, AdapterProviderTransportErrorKind, AdapterRetryAfter,
    AdapterRoutingFields, AdapterStreamPolicy, AdapterUpstreamRequest, AdapterUsage, ProtocolMode,
};

const DEFAULT_UPSTREAM_TIMEOUT_SECONDS: u64 = 30;
const CHAT_COMPLETIONS_PATH: &str = "/v1/chat/completions";
const RESPONSES_PATH: &str = "/v1/responses";
const EMBEDDINGS_PATH: &str = "/v1/embeddings";
const MODELS_PATH: &str = "/v1/models";
const REDACTED_PROVIDER_SECRET: &str = "[REDACTED]";

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChatCompletionRequest {
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub messages: Vec<ChatMessage>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stream: Option<bool>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChatMessage {
    #[serde(default)]
    pub role: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content: Option<Value>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OpenAiResponseRequest {
    #[serde(default)]
    pub model: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stream: Option<bool>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OpenAiEmbeddingRequest {
    #[serde(default)]
    pub model: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input: Option<Value>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct OpenAiModelsRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stream: Option<bool>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

#[derive(Debug, Clone)]
pub struct OpenAiCompatibleClient {
    base_url: String,
    http: reqwest::Client,
}

pub struct OpenAiChatStream {
    status: u16,
    content_type: Option<String>,
    response: reqwest::Response,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OpenAiResponsesStreamTerminalKind {
    None,
    Completed,
    Failed,
    Error,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OpenAiResponsesStreamEvent {
    pub data: Value,
    pub terminal_kind: OpenAiResponsesStreamTerminalKind,
}

#[derive(Debug, Error)]
pub enum OpenAiAdapterError {
    #[error("invalid JSON request body: {0}")]
    InvalidJson(String),
    #[error("invalid chat completion request: {message}")]
    InvalidRequest {
        message: String,
        param: Option<&'static str>,
    },
    #[error("failed to serialize upstream request: {0}")]
    RequestSerialize(String),
    #[error("streaming requests are not implemented")]
    StreamingNotImplemented,
    #[error("invalid upstream base URL: {0}")]
    InvalidUpstreamBaseUrl(String),
    #[error("failed to build upstream HTTP client: {0}")]
    HttpClient(String),
    #[error("provider authorization credential is invalid")]
    ProviderAuthorizationInvalid,
    #[error("upstream request timed out")]
    UpstreamTimeout,
    #[error("failed to connect to upstream: {0}")]
    UpstreamConnect(String),
    #[error("upstream request failed: {0}")]
    UpstreamRequest(String),
    #[error("failed to read upstream response: {0}")]
    UpstreamRead(String),
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

impl ChatCompletionRequest {
    pub fn routing_fields_from_slice(
        body: &[u8],
    ) -> Result<AdapterRoutingFields, OpenAiAdapterError> {
        let value: Value = serde_json::from_slice(body)
            .map_err(|error| OpenAiAdapterError::InvalidJson(error.to_string()))?;
        let object = value.as_object().ok_or_else(|| {
            OpenAiAdapterError::invalid_request("request body must be a JSON object", Some("body"))
        })?;

        let model = match object.get("model") {
            Some(Value::String(model)) => Some(model.clone()),
            Some(Value::Null) | None => None,
            Some(_) => {
                return Err(OpenAiAdapterError::invalid_request(
                    "model must be a string",
                    Some("model"),
                ));
            }
        };

        let stream = match object.get("stream") {
            Some(Value::Bool(stream)) => *stream,
            Some(Value::Null) | None => false,
            Some(_) => {
                return Err(OpenAiAdapterError::invalid_request(
                    "stream must be a boolean",
                    Some("stream"),
                ));
            }
        };

        Ok(AdapterRoutingFields { model, stream })
    }

    pub fn from_slice(body: &[u8]) -> Result<Self, OpenAiAdapterError> {
        let request: Self = serde_json::from_slice(body)
            .map_err(|error| OpenAiAdapterError::InvalidJson(error.to_string()))?;
        request.validate()?;
        Ok(request)
    }

    pub fn validate(&self) -> Result<(), OpenAiAdapterError> {
        if self.model.trim().is_empty() {
            return Err(OpenAiAdapterError::InvalidRequest {
                message: "model must be a non-empty string".to_string(),
                param: Some("model"),
            });
        }

        if self.messages.is_empty() {
            return Err(OpenAiAdapterError::InvalidRequest {
                message: "messages must contain at least one message".to_string(),
                param: Some("messages"),
            });
        }

        if let Some((index, _)) = self
            .messages
            .iter()
            .enumerate()
            .find(|(_, message)| message.role.trim().is_empty())
        {
            return Err(OpenAiAdapterError::InvalidRequest {
                message: format!("messages[{index}].role must be a non-empty string"),
                param: Some("messages"),
            });
        }

        Ok(())
    }

    pub fn is_streaming(&self) -> bool {
        self.stream.unwrap_or(false)
    }

    pub fn with_upstream_model(&self, upstream_model: impl Into<String>) -> Self {
        let mut request = self.clone();
        request.model = upstream_model.into();
        request
    }

    pub fn to_upstream_request(&self) -> Result<AdapterUpstreamRequest, OpenAiAdapterError> {
        self.validate()?;

        Ok(AdapterUpstreamRequest {
            method: "POST".to_string(),
            path: CHAT_COMPLETIONS_PATH.to_string(),
            body: serde_json::to_value(self)
                .map_err(|error| OpenAiAdapterError::RequestSerialize(error.to_string()))?,
            stream: self.is_streaming(),
        })
    }
}

impl OpenAiResponseRequest {
    pub fn routing_fields_from_slice(
        body: &[u8],
    ) -> Result<AdapterRoutingFields, OpenAiAdapterError> {
        let value: Value = serde_json::from_slice(body)
            .map_err(|error| OpenAiAdapterError::InvalidJson(error.to_string()))?;
        let object = value.as_object().ok_or_else(|| {
            OpenAiAdapterError::invalid_request("request body must be a JSON object", Some("body"))
        })?;

        let model = match object.get("model") {
            Some(Value::String(model)) => Some(model.clone()),
            Some(Value::Null) | None => None,
            Some(_) => {
                return Err(OpenAiAdapterError::invalid_request(
                    "model must be a string",
                    Some("model"),
                ));
            }
        };

        let stream = match object.get("stream") {
            Some(Value::Bool(stream)) => *stream,
            Some(Value::Null) | None => false,
            Some(_) => {
                return Err(OpenAiAdapterError::invalid_request(
                    "stream must be a boolean",
                    Some("stream"),
                ));
            }
        };

        Ok(AdapterRoutingFields { model, stream })
    }

    pub fn from_slice(body: &[u8]) -> Result<Self, OpenAiAdapterError> {
        let request: Self = serde_json::from_slice(body)
            .map_err(|error| OpenAiAdapterError::InvalidJson(error.to_string()))?;
        request.validate()?;
        Ok(request)
    }

    pub fn validate(&self) -> Result<(), OpenAiAdapterError> {
        if self.model.trim().is_empty() {
            return Err(OpenAiAdapterError::InvalidRequest {
                message: "model must be a non-empty string".to_string(),
                param: Some("model"),
            });
        }

        if self.input.as_ref().is_none_or(Value::is_null) {
            return Err(OpenAiAdapterError::InvalidRequest {
                message: "input is required".to_string(),
                param: Some("input"),
            });
        }

        Ok(())
    }

    pub fn is_streaming(&self) -> bool {
        self.stream.unwrap_or(false)
    }

    pub fn with_upstream_model(&self, upstream_model: impl Into<String>) -> Self {
        let mut request = self.clone();
        request.model = upstream_model.into();
        request
    }

    pub fn to_upstream_request(&self) -> Result<AdapterUpstreamRequest, OpenAiAdapterError> {
        self.validate()?;

        Ok(AdapterUpstreamRequest {
            method: "POST".to_string(),
            path: RESPONSES_PATH.to_string(),
            body: serde_json::to_value(self)
                .map_err(|error| OpenAiAdapterError::RequestSerialize(error.to_string()))?,
            stream: self.is_streaming(),
        })
    }
}

impl OpenAiEmbeddingRequest {
    pub fn routing_fields_from_slice(
        body: &[u8],
    ) -> Result<AdapterRoutingFields, OpenAiAdapterError> {
        let value: Value = serde_json::from_slice(body)
            .map_err(|error| OpenAiAdapterError::InvalidJson(error.to_string()))?;
        let object = value.as_object().ok_or_else(|| {
            OpenAiAdapterError::invalid_request("request body must be a JSON object", Some("body"))
        })?;

        let model = match object.get("model") {
            Some(Value::String(model)) => Some(model.clone()),
            Some(Value::Null) | None => None,
            Some(_) => {
                return Err(OpenAiAdapterError::invalid_request(
                    "model must be a string",
                    Some("model"),
                ));
            }
        };

        Ok(AdapterRoutingFields {
            model,
            stream: false,
        })
    }

    pub fn from_slice(body: &[u8]) -> Result<Self, OpenAiAdapterError> {
        let request: Self = serde_json::from_slice(body)
            .map_err(|error| OpenAiAdapterError::InvalidJson(error.to_string()))?;
        request.validate()?;
        Ok(request)
    }

    pub fn validate(&self) -> Result<(), OpenAiAdapterError> {
        if self.model.trim().is_empty() {
            return Err(OpenAiAdapterError::InvalidRequest {
                message: "model must be a non-empty string".to_string(),
                param: Some("model"),
            });
        }

        if self.input.as_ref().is_none_or(Value::is_null) {
            return Err(OpenAiAdapterError::InvalidRequest {
                message: "input is required".to_string(),
                param: Some("input"),
            });
        }

        Ok(())
    }

    pub fn with_upstream_model(&self, upstream_model: impl Into<String>) -> Self {
        let mut request = self.clone();
        request.model = upstream_model.into();
        request
    }

    pub fn to_upstream_request(&self) -> Result<AdapterUpstreamRequest, OpenAiAdapterError> {
        self.validate()?;

        Ok(AdapterUpstreamRequest {
            method: "POST".to_string(),
            path: EMBEDDINGS_PATH.to_string(),
            body: serde_json::to_value(self)
                .map_err(|error| OpenAiAdapterError::RequestSerialize(error.to_string()))?,
            stream: false,
        })
    }
}

impl OpenAiModelsRequest {
    pub fn routing_fields_from_slice(
        body: &[u8],
    ) -> Result<AdapterRoutingFields, OpenAiAdapterError> {
        let body = trim_ascii(body);
        if body.is_empty() {
            return Ok(AdapterRoutingFields {
                model: None,
                stream: false,
            });
        }

        let value: Value = serde_json::from_slice(body)
            .map_err(|error| OpenAiAdapterError::InvalidJson(error.to_string()))?;
        let object = value.as_object().ok_or_else(|| {
            OpenAiAdapterError::invalid_request("request body must be a JSON object", Some("body"))
        })?;

        let stream = match object.get("stream") {
            Some(Value::Bool(stream)) => *stream,
            Some(Value::Null) | None => false,
            Some(_) => {
                return Err(OpenAiAdapterError::invalid_request(
                    "stream must be a boolean",
                    Some("stream"),
                ));
            }
        };

        Ok(AdapterRoutingFields {
            model: None,
            stream,
        })
    }

    pub fn from_slice(body: &[u8]) -> Result<Self, OpenAiAdapterError> {
        let body = trim_ascii(body);
        let request = if body.is_empty() {
            Self::default()
        } else {
            serde_json::from_slice(body)
                .map_err(|error| OpenAiAdapterError::InvalidJson(error.to_string()))?
        };
        request.validate()?;
        Ok(request)
    }

    pub fn validate(&self) -> Result<(), OpenAiAdapterError> {
        if self.stream.unwrap_or(false) {
            return Err(OpenAiAdapterError::InvalidRequest {
                message: "stream is not supported for /v1/models; omit stream or set stream=false"
                    .to_string(),
                param: Some("stream"),
            });
        }

        if !self.extra.is_empty() {
            return Err(OpenAiAdapterError::InvalidRequest {
                message: "/v1/models does not accept a request body".to_string(),
                param: Some("body"),
            });
        }

        Ok(())
    }

    pub fn to_upstream_request(&self) -> Result<AdapterUpstreamRequest, OpenAiAdapterError> {
        self.validate()?;

        Ok(AdapterUpstreamRequest {
            method: "GET".to_string(),
            path: MODELS_PATH.to_string(),
            body: Value::Null,
            stream: false,
        })
    }
}

impl OpenAiCompatibleClient {
    pub fn new(base_url: impl Into<String>) -> Result<Self, OpenAiAdapterError> {
        Self::new_with_timeout(
            base_url,
            Duration::from_secs(DEFAULT_UPSTREAM_TIMEOUT_SECONDS),
        )
    }

    pub fn new_with_timeout(
        base_url: impl Into<String>,
        timeout: Duration,
    ) -> Result<Self, OpenAiAdapterError> {
        let base_url = base_url.into().trim().trim_end_matches('/').to_string();
        if base_url.is_empty() || reqwest::Url::parse(&base_url).is_err() {
            return Err(OpenAiAdapterError::InvalidUpstreamBaseUrl(base_url));
        }

        let http = reqwest::Client::builder()
            .timeout(timeout)
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|error| OpenAiAdapterError::HttpClient(error.to_string()))?;

        Ok(Self { base_url, http })
    }

    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    pub async fn chat_completions(
        &self,
        request: &ChatCompletionRequest,
    ) -> Result<Value, OpenAiAdapterError> {
        self.chat_completions_with_provider_key(request, None).await
    }

    pub async fn chat_completions_with_provider_key(
        &self,
        request: &ChatCompletionRequest,
        provider_key: Option<&str>,
    ) -> Result<Value, OpenAiAdapterError> {
        request.validate()?;

        let response = self
            .chat_completions_request_builder(request, provider_key)?
            .send()
            .await
            .map_err(map_reqwest_error)?;

        let status = response.status();
        let retry_after = retry_after_from_headers(response.headers());
        let body = response
            .bytes()
            .await
            .map_err(|error| OpenAiAdapterError::UpstreamRead(error.to_string()))?;

        Self::parse_chat_completions_response_with_context(
            status.as_u16(),
            &body,
            retry_after,
            provider_key,
        )
    }

    pub async fn responses(
        &self,
        request: &OpenAiResponseRequest,
    ) -> Result<Value, OpenAiAdapterError> {
        self.responses_with_provider_key(request, None).await
    }

    pub async fn responses_with_provider_key(
        &self,
        request: &OpenAiResponseRequest,
        provider_key: Option<&str>,
    ) -> Result<Value, OpenAiAdapterError> {
        request.validate()?;

        let response = self
            .responses_request_builder(request, provider_key)?
            .send()
            .await
            .map_err(map_reqwest_error)?;

        let status = response.status();
        let retry_after = retry_after_from_headers(response.headers());
        let body = response
            .bytes()
            .await
            .map_err(|error| OpenAiAdapterError::UpstreamRead(error.to_string()))?;

        Self::parse_responses_response_with_context(
            status.as_u16(),
            &body,
            retry_after,
            provider_key,
        )
    }

    pub async fn embeddings(
        &self,
        request: &OpenAiEmbeddingRequest,
    ) -> Result<Value, OpenAiAdapterError> {
        self.embeddings_with_provider_key(request, None).await
    }

    pub async fn embeddings_with_provider_key(
        &self,
        request: &OpenAiEmbeddingRequest,
        provider_key: Option<&str>,
    ) -> Result<Value, OpenAiAdapterError> {
        request.validate()?;

        let response = self
            .embeddings_request_builder(request, provider_key)?
            .send()
            .await
            .map_err(map_reqwest_error)?;

        let status = response.status();
        let retry_after = retry_after_from_headers(response.headers());
        let body = response
            .bytes()
            .await
            .map_err(|error| OpenAiAdapterError::UpstreamRead(error.to_string()))?;

        Self::parse_embeddings_response_with_context(
            status.as_u16(),
            &body,
            retry_after,
            provider_key,
        )
    }

    pub async fn models(&self) -> Result<Value, OpenAiAdapterError> {
        self.models_with_provider_key(None).await
    }

    pub async fn models_with_provider_key(
        &self,
        provider_key: Option<&str>,
    ) -> Result<Value, OpenAiAdapterError> {
        let response = self
            .models_request_builder(provider_key)?
            .send()
            .await
            .map_err(map_reqwest_error)?;

        let status = response.status();
        let retry_after = retry_after_from_headers(response.headers());
        let body = response
            .bytes()
            .await
            .map_err(|error| OpenAiAdapterError::UpstreamRead(error.to_string()))?;

        Self::parse_models_response_with_context(status.as_u16(), &body, retry_after, provider_key)
    }

    pub async fn chat_completions_stream(
        &self,
        request: &ChatCompletionRequest,
    ) -> Result<OpenAiChatStream, OpenAiAdapterError> {
        self.chat_completions_stream_with_provider_key(request, None)
            .await
    }

    pub async fn chat_completions_stream_with_provider_key(
        &self,
        request: &ChatCompletionRequest,
        provider_key: Option<&str>,
    ) -> Result<OpenAiChatStream, OpenAiAdapterError> {
        request.validate()?;

        let response = self
            .chat_completions_request_builder(request, provider_key)?
            .send()
            .await
            .map_err(map_reqwest_error)?;

        let status = response.status();
        let retry_after = retry_after_from_headers(response.headers());
        let content_type = response
            .headers()
            .get(CONTENT_TYPE)
            .and_then(header_to_str)
            .map(str::to_string);

        if !status.is_success() {
            let body = response
                .bytes()
                .await
                .map_err(|error| OpenAiAdapterError::UpstreamRead(error.to_string()))?;
            Self::parse_chat_completions_response_with_context(
                status.as_u16(),
                &body,
                retry_after,
                provider_key,
            )?;
            unreachable!("non-success upstream status must parse as an error");
        }

        Ok(OpenAiChatStream {
            status: status.as_u16(),
            content_type,
            response,
        })
    }

    pub async fn responses_stream(
        &self,
        request: &OpenAiResponseRequest,
    ) -> Result<OpenAiChatStream, OpenAiAdapterError> {
        self.responses_stream_with_provider_key(request, None).await
    }

    pub async fn responses_stream_with_provider_key(
        &self,
        request: &OpenAiResponseRequest,
        provider_key: Option<&str>,
    ) -> Result<OpenAiChatStream, OpenAiAdapterError> {
        request.validate()?;

        let response = self
            .responses_request_builder(request, provider_key)?
            .send()
            .await
            .map_err(map_reqwest_error)?;

        let status = response.status();
        let retry_after = retry_after_from_headers(response.headers());
        let content_type = response
            .headers()
            .get(CONTENT_TYPE)
            .and_then(header_to_str)
            .map(str::to_string);

        if !status.is_success() {
            let body = response
                .bytes()
                .await
                .map_err(|error| OpenAiAdapterError::UpstreamRead(error.to_string()))?;
            Self::parse_responses_response_with_context(
                status.as_u16(),
                &body,
                retry_after,
                provider_key,
            )?;
            unreachable!("non-success upstream status must parse as an error");
        }

        Ok(OpenAiChatStream {
            status: status.as_u16(),
            content_type,
            response,
        })
    }

    pub fn build_chat_completions_request(
        &self,
        request: &ChatCompletionRequest,
    ) -> Result<AdapterUpstreamRequest, OpenAiAdapterError> {
        request.to_upstream_request()
    }

    pub fn build_responses_request(
        &self,
        request: &OpenAiResponseRequest,
    ) -> Result<AdapterUpstreamRequest, OpenAiAdapterError> {
        request.to_upstream_request()
    }

    pub fn build_embeddings_request(
        &self,
        request: &OpenAiEmbeddingRequest,
    ) -> Result<AdapterUpstreamRequest, OpenAiAdapterError> {
        request.to_upstream_request()
    }

    pub fn build_models_request(
        &self,
        request: &OpenAiModelsRequest,
    ) -> Result<AdapterUpstreamRequest, OpenAiAdapterError> {
        request.to_upstream_request()
    }

    pub fn parse_chat_completions_response(
        status: u16,
        body: &[u8],
    ) -> Result<Value, OpenAiAdapterError> {
        Self::parse_chat_completions_response_with_retry_after(status, body, None)
    }

    fn parse_chat_completions_response_with_retry_after(
        status: u16,
        body: &[u8],
        retry_after: Option<AdapterRetryAfter>,
    ) -> Result<Value, OpenAiAdapterError> {
        Self::parse_chat_completions_response_with_context(status, body, retry_after, None)
    }

    fn parse_chat_completions_response_with_context(
        status: u16,
        body: &[u8],
        retry_after: Option<AdapterRetryAfter>,
        provider_key: Option<&str>,
    ) -> Result<Value, OpenAiAdapterError> {
        Self::parse_openai_json_response_with_context(status, body, retry_after, provider_key)
    }

    pub fn parse_responses_response(status: u16, body: &[u8]) -> Result<Value, OpenAiAdapterError> {
        Self::parse_responses_response_with_retry_after(status, body, None)
    }

    fn parse_responses_response_with_retry_after(
        status: u16,
        body: &[u8],
        retry_after: Option<AdapterRetryAfter>,
    ) -> Result<Value, OpenAiAdapterError> {
        Self::parse_responses_response_with_context(status, body, retry_after, None)
    }

    fn parse_responses_response_with_context(
        status: u16,
        body: &[u8],
        retry_after: Option<AdapterRetryAfter>,
        provider_key: Option<&str>,
    ) -> Result<Value, OpenAiAdapterError> {
        Self::parse_openai_json_response_with_context(status, body, retry_after, provider_key)
    }

    pub fn parse_embeddings_response(
        status: u16,
        body: &[u8],
    ) -> Result<Value, OpenAiAdapterError> {
        Self::parse_embeddings_response_with_retry_after(status, body, None)
    }

    fn parse_embeddings_response_with_retry_after(
        status: u16,
        body: &[u8],
        retry_after: Option<AdapterRetryAfter>,
    ) -> Result<Value, OpenAiAdapterError> {
        Self::parse_embeddings_response_with_context(status, body, retry_after, None)
    }

    fn parse_embeddings_response_with_context(
        status: u16,
        body: &[u8],
        retry_after: Option<AdapterRetryAfter>,
        provider_key: Option<&str>,
    ) -> Result<Value, OpenAiAdapterError> {
        Self::parse_openai_json_response_with_context(status, body, retry_after, provider_key)
    }

    pub fn parse_models_response(status: u16, body: &[u8]) -> Result<Value, OpenAiAdapterError> {
        Self::parse_models_response_with_retry_after(status, body, None)
    }

    pub fn parse_responses_stream_event(
        data: &[u8],
    ) -> Result<OpenAiResponsesStreamEvent, OpenAiAdapterError> {
        OpenAiResponsesStreamEvent::from_data_slice(data)
    }

    fn parse_models_response_with_retry_after(
        status: u16,
        body: &[u8],
        retry_after: Option<AdapterRetryAfter>,
    ) -> Result<Value, OpenAiAdapterError> {
        Self::parse_models_response_with_context(status, body, retry_after, None)
    }

    fn parse_models_response_with_context(
        status: u16,
        body: &[u8],
        retry_after: Option<AdapterRetryAfter>,
        provider_key: Option<&str>,
    ) -> Result<Value, OpenAiAdapterError> {
        Self::parse_openai_json_response_with_context(status, body, retry_after, provider_key)
    }

    fn parse_openai_json_response_with_context(
        status: u16,
        body: &[u8],
        retry_after: Option<AdapterRetryAfter>,
        provider_key: Option<&str>,
    ) -> Result<Value, OpenAiAdapterError> {
        let json = match serde_json::from_slice::<Value>(body) {
            Ok(json) => json,
            Err(error) => {
                return Err(OpenAiAdapterError::UpstreamInvalidJson {
                    status,
                    message: error.to_string(),
                    retry_after,
                });
            }
        };
        let json = redact_provider_secret_value(json, provider_key);

        if !(200..300).contains(&status) {
            return Err(OpenAiAdapterError::UpstreamStatus {
                status,
                body: json,
                retry_after,
            });
        }

        Ok(json)
    }

    fn chat_completions_request_builder(
        &self,
        request: &ChatCompletionRequest,
        provider_key: Option<&str>,
    ) -> Result<reqwest::RequestBuilder, OpenAiAdapterError> {
        let mut builder = self
            .http
            .post(format!("{}{}", self.base_url, CHAT_COMPLETIONS_PATH))
            .json(request);

        if let Some(provider_key) = provider_key {
            builder = builder.header(AUTHORIZATION, bearer_authorization(provider_key)?);
        }

        Ok(builder)
    }

    fn responses_request_builder(
        &self,
        request: &OpenAiResponseRequest,
        provider_key: Option<&str>,
    ) -> Result<reqwest::RequestBuilder, OpenAiAdapterError> {
        let mut builder = self
            .http
            .post(format!("{}{}", self.base_url, RESPONSES_PATH))
            .json(request);

        if let Some(provider_key) = provider_key {
            builder = builder.header(AUTHORIZATION, bearer_authorization(provider_key)?);
        }

        Ok(builder)
    }

    fn embeddings_request_builder(
        &self,
        request: &OpenAiEmbeddingRequest,
        provider_key: Option<&str>,
    ) -> Result<reqwest::RequestBuilder, OpenAiAdapterError> {
        let mut builder = self
            .http
            .post(format!("{}{}", self.base_url, EMBEDDINGS_PATH))
            .json(request);

        if let Some(provider_key) = provider_key {
            builder = builder.header(AUTHORIZATION, bearer_authorization(provider_key)?);
        }

        Ok(builder)
    }

    fn models_request_builder(
        &self,
        provider_key: Option<&str>,
    ) -> Result<reqwest::RequestBuilder, OpenAiAdapterError> {
        let mut builder = self.http.get(format!("{}{}", self.base_url, MODELS_PATH));

        if let Some(provider_key) = provider_key {
            builder = builder.header(AUTHORIZATION, bearer_authorization(provider_key)?);
        }

        Ok(builder)
    }
}

impl OpenAiChatStream {
    pub fn status(&self) -> u16 {
        self.status
    }

    pub fn content_type(&self) -> Option<&str> {
        self.content_type.as_deref()
    }

    pub async fn next_chunk(&mut self) -> Result<Option<Vec<u8>>, OpenAiAdapterError> {
        self.response
            .chunk()
            .await
            .map(|chunk| chunk.map(|chunk| chunk.to_vec()))
            .map_err(map_reqwest_error)
    }
}

impl OpenAiResponsesStreamTerminalKind {
    pub const fn is_terminal(&self) -> bool {
        !matches!(self, Self::None)
    }

    pub const fn is_error(&self) -> bool {
        matches!(self, Self::Failed | Self::Error)
    }
}

impl OpenAiResponsesStreamEvent {
    pub fn from_data_slice(data: &[u8]) -> Result<Self, OpenAiAdapterError> {
        let data: Value = serde_json::from_slice(trim_ascii(data)).map_err(|error| {
            OpenAiAdapterError::UpstreamInvalidJson {
                status: 200,
                message: error.to_string(),
                retry_after: None,
            }
        })?;
        let terminal_kind = openai_responses_stream_terminal_kind(&data);

        Ok(Self {
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
        if !self.is_terminal() {
            return None;
        }

        openai_usage(&self.data).or_else(|| self.data.get("response").and_then(openai_usage))
    }
}

impl OpenAiAdapterError {
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
            Self::StreamingNotImplemented => 501,
            Self::InvalidUpstreamBaseUrl(_)
            | Self::HttpClient(_)
            | Self::ProviderAuthorizationInvalid => 500,
            Self::UpstreamTimeout => 504,
            Self::UpstreamConnect(_)
            | Self::UpstreamRequest(_)
            | Self::UpstreamRead(_)
            | Self::UpstreamInvalidJson { .. } => 502,
            Self::UpstreamStatus { status, .. } => *status,
        }
    }

    pub fn to_openai_error_body(&self) -> Value {
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
            Self::StreamingNotImplemented => error_body(
                "invalid_request_error",
                "streaming_not_implemented",
                "stream=true is not implemented by this gateway slice",
                Some("stream"),
                json!({
                    "error_owner": "gateway",
                    "error_stage": "request_validate"
                }),
            ),
            Self::InvalidUpstreamBaseUrl(message) => error_body(
                "gateway_error",
                "invalid_upstream_base_url",
                &format!("invalid upstream base URL: {message}"),
                None,
                json!({
                    "error_owner": "gateway",
                    "error_stage": "provider_call"
                }),
            ),
            Self::HttpClient(message) => error_body(
                "gateway_error",
                "http_client_error",
                message,
                None,
                json!({
                    "error_owner": "gateway",
                    "error_stage": "provider_call"
                }),
            ),
            Self::ProviderAuthorizationInvalid => error_body(
                "gateway_error",
                "provider_authorization_invalid",
                "provider authorization credential is invalid",
                None,
                json!({
                    "error_owner": "gateway",
                    "error_stage": "provider_call"
                }),
            ),
            Self::UpstreamTimeout => error_body(
                "provider_error",
                "provider_timeout",
                "upstream provider request timed out",
                None,
                json!({
                    "error_owner": "network",
                    "error_stage": "provider_call"
                }),
            ),
            Self::UpstreamConnect(message) => error_body(
                "provider_error",
                "provider_connect_failed",
                message,
                None,
                json!({
                    "error_owner": "network",
                    "error_stage": "provider_call"
                }),
            ),
            Self::UpstreamRequest(message) => error_body(
                "provider_error",
                "provider_request_failed",
                message,
                None,
                json!({
                    "error_owner": "network",
                    "error_stage": "provider_call"
                }),
            ),
            Self::UpstreamRead(message) => error_body(
                "provider_error",
                "provider_response_read_failed",
                message,
                None,
                json!({
                    "error_owner": "network",
                    "error_stage": "provider_call"
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
        let body = self.to_openai_error_body();
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
            Self::UpstreamTimeout => Some(AdapterProviderErrorSignal::from_transport(
                AdapterProviderTransportErrorKind::Timeout,
            )),
            Self::UpstreamConnect(_) => Some(AdapterProviderErrorSignal::from_transport(
                AdapterProviderTransportErrorKind::Connect,
            )),
            Self::UpstreamRead(_) => Some(AdapterProviderErrorSignal::from_transport(
                AdapterProviderTransportErrorKind::Body,
            )),
            Self::UpstreamRequest(_) => Some(AdapterProviderErrorSignal::from_transport(
                AdapterProviderTransportErrorKind::Other,
            )),
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

impl Adapter for OpenAiCompatibleClient {
    fn protocol_mode(&self) -> ProtocolMode {
        ProtocolMode::OpenAiCompatible
    }

    fn capabilities(&self) -> AdapterCapabilities {
        AdapterCapabilities {
            operations: vec![
                AdapterOperation::ChatCompletions,
                AdapterOperation::Responses,
                AdapterOperation::Embeddings,
                AdapterOperation::Models,
            ],
            stream_policy: AdapterStreamPolicy::PassThrough,
        }
    }

    fn extract_model(&self, body: &[u8]) -> Result<Option<String>, GatewayError> {
        self.extract_routing_fields(body).map(|fields| fields.model)
    }

    fn extract_routing_fields(&self, body: &[u8]) -> Result<AdapterRoutingFields, GatewayError> {
        ChatCompletionRequest::routing_fields_from_slice(body)
            .map_err(|error| error.to_gateway_error())
    }

    fn build_upstream_request(
        &self,
        operation: AdapterOperation,
        body: &[u8],
    ) -> Result<AdapterUpstreamRequest, GatewayError> {
        match operation {
            AdapterOperation::ChatCompletions => {
                let request = ChatCompletionRequest::from_slice(body)
                    .map_err(|error| error.to_gateway_error())?;
                self.build_chat_completions_request(&request)
                    .map_err(|error| error.to_gateway_error())
            }
            AdapterOperation::Responses => {
                let request = OpenAiResponseRequest::from_slice(body)
                    .map_err(|error| error.to_gateway_error())?;
                self.build_responses_request(&request)
                    .map_err(|error| error.to_gateway_error())
            }
            AdapterOperation::Embeddings => {
                let request = OpenAiEmbeddingRequest::from_slice(body)
                    .map_err(|error| error.to_gateway_error())?;
                self.build_embeddings_request(&request)
                    .map_err(|error| error.to_gateway_error())
            }
            AdapterOperation::Models => {
                let request = OpenAiModelsRequest::from_slice(body)
                    .map_err(|error| error.to_gateway_error())?;
                self.build_models_request(&request)
                    .map_err(|error| error.to_gateway_error())
            }
            _ => Err(unsupported_openai_operation(
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
            AdapterOperation::ChatCompletions => {
                Self::parse_chat_completions_response(status, body)
                    .map_err(|error| error.to_gateway_error())
            }
            AdapterOperation::Responses => Self::parse_responses_response(status, body)
                .map_err(|error| error.to_gateway_error()),
            AdapterOperation::Embeddings => Self::parse_embeddings_response(status, body)
                .map_err(|error| error.to_gateway_error()),
            AdapterOperation::Models => {
                Self::parse_models_response(status, body).map_err(|error| error.to_gateway_error())
            }
            _ => Err(unsupported_openai_operation(operation, "parse_response")),
        }
    }

    fn parse_stream_event(
        &self,
        operation: AdapterOperation,
        event: &[u8],
    ) -> Result<Value, GatewayError> {
        let event = trim_ascii(event);

        match operation {
            AdapterOperation::ChatCompletions => {
                if event == b"[DONE]" {
                    return Ok(json!({"done": true}));
                }

                parse_json_stream_event(event)
            }
            AdapterOperation::Responses => Ok(Self::parse_responses_stream_event(event)
                .map_err(|error| error.to_gateway_error())?
                .data),
            _ => Err(unsupported_openai_operation(
                operation,
                "parse_stream_event",
            )),
        }
    }

    fn extract_usage(&self, response: &Value) -> Option<AdapterUsage> {
        openai_usage(response)
    }
}

fn parse_json_stream_event(event: &[u8]) -> Result<Value, GatewayError> {
    serde_json::from_slice(event).map_err(|error| {
        OpenAiAdapterError::UpstreamInvalidJson {
            status: 200,
            message: error.to_string(),
            retry_after: None,
        }
        .to_gateway_error()
    })
}

fn map_reqwest_error(error: reqwest::Error) -> OpenAiAdapterError {
    if error.is_timeout() {
        OpenAiAdapterError::UpstreamTimeout
    } else if error.is_connect() {
        OpenAiAdapterError::UpstreamConnect(error.to_string())
    } else if error.is_body() {
        OpenAiAdapterError::UpstreamRead(error.to_string())
    } else {
        OpenAiAdapterError::UpstreamRequest(error.to_string())
    }
}

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

fn parse_retry_after_ms(value: &str) -> Option<u64> {
    value.trim().parse::<u64>().ok()
}

fn parse_retry_after_seconds(value: &str) -> Option<u64> {
    value.trim().parse::<u64>().ok()?.checked_mul(1_000)
}

fn retry_after_ms_to_header_value(retry_after_ms: u64) -> String {
    let seconds = retry_after_ms / 1_000 + u64::from(!retry_after_ms.is_multiple_of(1_000));
    seconds.to_string()
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

fn unsupported_openai_operation(operation: AdapterOperation, method: &str) -> GatewayError {
    GatewayError::new(
        GatewayErrorOwner::Gateway,
        "adapter_operation_unsupported",
        format!("OpenAI-compatible adapter does not implement {method} for {operation:?}"),
    )
}

fn bearer_authorization(provider_key: &str) -> Result<HeaderValue, OpenAiAdapterError> {
    HeaderValue::from_str(&format!("Bearer {provider_key}"))
        .map_err(|_| OpenAiAdapterError::ProviderAuthorizationInvalid)
}

fn redact_provider_secret_value(value: Value, provider_key: Option<&str>) -> Value {
    let Some(provider_key) = provider_key
        .map(str::trim)
        .filter(|provider_key| !provider_key.is_empty())
    else {
        return value;
    };

    redact_provider_secret_in_value(value, provider_key)
}

fn redact_provider_secret_in_value(value: Value, provider_key: &str) -> Value {
    match value {
        Value::Object(map) => Value::Object(
            map.into_iter()
                .map(|(key, value)| {
                    if is_sensitive_json_key(&key)
                        && value_contains_provider_secret(&value, provider_key)
                    {
                        (key, Value::String(REDACTED_PROVIDER_SECRET.to_string()))
                    } else {
                        (key, redact_provider_secret_in_value(value, provider_key))
                    }
                })
                .collect(),
        ),
        Value::Array(values) => Value::Array(
            values
                .into_iter()
                .map(|value| redact_provider_secret_in_value(value, provider_key))
                .collect(),
        ),
        Value::String(value) => {
            Value::String(value.replace(provider_key, REDACTED_PROVIDER_SECRET))
        }
        value => value,
    }
}

fn value_contains_provider_secret(value: &Value, provider_key: &str) -> bool {
    match value {
        Value::String(value) => value.contains(provider_key),
        Value::Array(values) => values
            .iter()
            .any(|value| value_contains_provider_secret(value, provider_key)),
        Value::Object(map) => map
            .values()
            .any(|value| value_contains_provider_secret(value, provider_key)),
        _ => false,
    }
}

fn is_sensitive_json_key(key: &str) -> bool {
    let normalized = key
        .chars()
        .map(|character| {
            if character == '-' || character == ' ' {
                '_'
            } else {
                character.to_ascii_lowercase()
            }
        })
        .collect::<String>();

    normalized == "authorization"
        || normalized == "key"
        || normalized == "token"
        || normalized.ends_with("_key")
        || normalized.ends_with("_token")
        || normalized.contains("api_key")
        || normalized.contains("apikey")
        || normalized.contains("secret")
        || normalized.contains("credential")
}

fn openai_usage(response: &Value) -> Option<AdapterUsage> {
    let usage = response.get("usage")?;

    Some(AdapterUsage {
        prompt_tokens: usage
            .get("prompt_tokens")
            .or_else(|| usage.get("input_tokens"))
            .and_then(Value::as_u64),
        completion_tokens: usage
            .get("completion_tokens")
            .or_else(|| usage.get("output_tokens"))
            .and_then(Value::as_u64),
        total_tokens: usage.get("total_tokens").and_then(Value::as_u64),
    })
}

fn openai_responses_stream_terminal_kind(data: &Value) -> OpenAiResponsesStreamTerminalKind {
    match data.get("type").and_then(Value::as_str) {
        Some("response.completed") => return OpenAiResponsesStreamTerminalKind::Completed,
        Some("response.failed") => return OpenAiResponsesStreamTerminalKind::Failed,
        Some("error") => return OpenAiResponsesStreamTerminalKind::Error,
        _ => {}
    }

    match data
        .get("response")
        .and_then(|response| response.get("status"))
        .and_then(Value::as_str)
    {
        Some("completed") => OpenAiResponsesStreamTerminalKind::Completed,
        Some("failed") | Some("cancelled") | Some("incomplete") => {
            OpenAiResponsesStreamTerminalKind::Failed
        }
        _ => OpenAiResponsesStreamTerminalKind::None,
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

#[cfg(test)]
mod tests {
    use std::{fs, path::PathBuf};

    use ai_gateway_shared::GatewayErrorOwner;

    use super::*;

    fn load_openai_fixture(file_name: &str) -> Value {
        let path = openai_fixture_path(file_name);
        let contents = fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("failed to read fixture {}: {error}", path.display()));

        serde_json::from_str(&contents)
            .unwrap_or_else(|error| panic!("failed to parse fixture {}: {error}", path.display()))
    }

    fn openai_fixture_path(file_name: &str) -> PathBuf {
        let mut path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        path.pop();
        path.pop();
        path.push("tests");
        path.push("fixtures");
        path.push("adapters");
        path.push("openai");
        path.push(file_name);
        path
    }

    fn load_openai_stream_fixture(file_name: &str) -> String {
        let path = openai_fixture_path(&format!("streams/{file_name}"));
        fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("failed to read fixture {}: {error}", path.display()))
    }

    fn sse_fixture_events(file_name: &str) -> Vec<Vec<u8>> {
        load_openai_stream_fixture(file_name)
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

    #[test]
    fn validates_required_model() {
        let error = ChatCompletionRequest::from_slice(br#"{"messages":[{"role":"user"}]}"#)
            .expect_err("missing model should be rejected");

        assert_eq!(error.http_status(), 400);
        assert_eq!(
            error.to_openai_error_body()["error"]["code"],
            "invalid_request"
        );
        assert_eq!(error.to_openai_error_body()["error"]["param"], "model");
    }

    #[test]
    fn validates_required_messages() {
        let error = ChatCompletionRequest::from_slice(br#"{"model":"mock-gpt"}"#)
            .expect_err("missing messages should be rejected");

        assert_eq!(error.http_status(), 400);
        assert_eq!(error.to_openai_error_body()["error"]["param"], "messages");
    }

    #[test]
    fn accepts_streaming_request_without_faking_non_stream() {
        let request = ChatCompletionRequest::from_slice(
            br#"{"model":"mock-gpt","messages":[{"role":"user","content":"hi"}],"stream":true}"#,
        )
        .expect("stream=true should be accepted by the adapter");

        assert!(request.is_streaming());
    }

    #[test]
    fn extracts_routing_fields_without_full_request_validation() {
        let fields = ChatCompletionRequest::routing_fields_from_slice(
            br#"{"model":"mock-gpt","stream":true}"#,
        )
        .expect("routing fields do not require messages");

        assert_eq!(fields.model.as_deref(), Some("mock-gpt"));
        assert!(fields.stream);

        let error = ChatCompletionRequest::routing_fields_from_slice(
            br#"{"model":"mock-gpt","stream":"yes"}"#,
        )
        .expect_err("non-boolean stream should be explicit");
        let mapping = error.to_adapter_error_mapping();

        assert_eq!(mapping.http_status, 400);
        assert_eq!(mapping.code, "invalid_request");
        assert_eq!(mapping.param.as_deref(), Some("stream"));
    }

    #[test]
    fn adapter_contract_declares_openai_surface_and_stream_passthrough() {
        let client = OpenAiCompatibleClient::new("http://127.0.0.1:18080/")
            .expect("valid upstream base URL");
        let capabilities = client.capabilities();

        assert_eq!(client.base_url(), "http://127.0.0.1:18080");
        assert_eq!(client.protocol_mode(), ProtocolMode::OpenAiCompatible);
        assert!(capabilities.supports(AdapterOperation::ChatCompletions));
        assert!(capabilities.supports(AdapterOperation::Responses));
        assert!(capabilities.supports(AdapterOperation::Embeddings));
        assert!(capabilities.supports(AdapterOperation::Models));
        assert_eq!(capabilities.stream_policy, AdapterStreamPolicy::PassThrough);
    }

    #[test]
    fn preserves_extra_openai_compatible_fields() {
        let request = ChatCompletionRequest::from_slice(
            br#"{"model":"mock-gpt","messages":[{"role":"user","content":"hi"}],"temperature":0,"mock_scenario":"200"}"#,
        )
        .expect("valid request");

        assert_eq!(request.extra["temperature"], 0);
        assert_eq!(request.extra["mock_scenario"], "200");
    }

    #[test]
    fn builds_upstream_request_contract_and_preserves_payload() {
        let client =
            OpenAiCompatibleClient::new("http://127.0.0.1:18080").expect("valid upstream base URL");
        let request = ChatCompletionRequest::from_slice(
            br#"{"model":"mock-gpt","messages":[{"role":"user","content":"hi"}],"stream":false,"temperature":0,"mock_scenario":"200"}"#,
        )
        .expect("valid request")
        .with_upstream_model("upstream-gpt");

        let upstream = client
            .build_chat_completions_request(&request)
            .expect("upstream request");

        assert_eq!(upstream.method, "POST");
        assert_eq!(upstream.path, CHAT_COMPLETIONS_PATH);
        assert!(!upstream.stream);
        assert_eq!(upstream.body["model"], "upstream-gpt");
        assert_eq!(upstream.body["messages"][0]["content"], "hi");
        assert_eq!(upstream.body["stream"], false);
        assert_eq!(upstream.body["temperature"], 0);
        assert_eq!(upstream.body["mock_scenario"], "200");
    }

    #[test]
    fn builds_responses_upstream_request_contract_and_preserves_payload() {
        let client =
            OpenAiCompatibleClient::new("http://127.0.0.1:18080").expect("valid upstream base URL");
        let request = OpenAiResponseRequest::from_slice(
            br#"{"model":"mock-gpt","input":"hi","stream":false,"temperature":0,"metadata":{"trace":"fixture"}}"#,
        )
        .expect("valid request")
        .with_upstream_model("upstream-gpt");

        let upstream = client
            .build_responses_request(&request)
            .expect("upstream request");

        assert_eq!(upstream.method, "POST");
        assert_eq!(upstream.path, RESPONSES_PATH);
        assert!(!upstream.stream);
        assert_eq!(upstream.body["model"], "upstream-gpt");
        assert_eq!(upstream.body["input"], "hi");
        assert_eq!(upstream.body["stream"], false);
        assert_eq!(upstream.body["temperature"], 0);
        assert_eq!(upstream.body["metadata"]["trace"], "fixture");
    }

    #[test]
    fn builds_embeddings_upstream_request_contract_and_preserves_payload() {
        let client =
            OpenAiCompatibleClient::new("http://127.0.0.1:18080").expect("valid upstream base URL");
        let request = OpenAiEmbeddingRequest::from_slice(
            br#"{"model":"mock-embedding","input":["hi","bye"],"encoding_format":"float","dimensions":8}"#,
        )
        .expect("valid request")
        .with_upstream_model("upstream-embedding");

        let upstream = client
            .build_embeddings_request(&request)
            .expect("upstream request");

        assert_eq!(upstream.method, "POST");
        assert_eq!(upstream.path, EMBEDDINGS_PATH);
        assert!(!upstream.stream);
        assert_eq!(upstream.body["model"], "upstream-embedding");
        assert_eq!(upstream.body["input"][0], "hi");
        assert_eq!(upstream.body["input"][1], "bye");
        assert_eq!(upstream.body["encoding_format"], "float");
        assert_eq!(upstream.body["dimensions"], 8);
    }

    #[test]
    fn builds_models_upstream_request_contract_without_request_body() {
        let client =
            OpenAiCompatibleClient::new("http://127.0.0.1:18080").expect("valid upstream base URL");
        let request =
            OpenAiModelsRequest::from_slice(br#"{"stream":false}"#).expect("valid request");

        let routing_fields = OpenAiModelsRequest::routing_fields_from_slice(br#"{"stream":true}"#)
            .expect("routing should identify unsupported stream intent");
        let upstream = client
            .build_models_request(&request)
            .expect("upstream request");

        assert!(routing_fields.stream);
        assert_eq!(routing_fields.model, None);
        assert_eq!(upstream.method, "GET");
        assert_eq!(upstream.path, MODELS_PATH);
        assert!(!upstream.stream);
        assert_eq!(upstream.body, Value::Null);
    }

    #[test]
    fn validates_responses_required_model_and_input() {
        let missing_model =
            OpenAiResponseRequest::from_slice(br#"{"input":"hi"}"#).expect_err("missing model");
        let missing_input = OpenAiResponseRequest::from_slice(br#"{"model":"mock-gpt"}"#)
            .expect_err("missing input");

        assert_eq!(missing_model.http_status(), 400);
        assert_eq!(
            missing_model.to_openai_error_body()["error"]["param"],
            "model"
        );
        assert_eq!(missing_input.http_status(), 400);
        assert_eq!(
            missing_input.to_openai_error_body()["error"]["param"],
            "input"
        );
    }

    #[test]
    fn validates_models_stream_true_and_request_body_are_unsupported() {
        let stream_error = OpenAiModelsRequest::from_slice(br#"{"stream":true}"#)
            .expect_err("stream=true should be rejected for models");
        let body_error = OpenAiModelsRequest::from_slice(br#"{"model":"mock-gpt"}"#)
            .expect_err("models request body should be rejected");

        assert_eq!(stream_error.http_status(), 400);
        assert_eq!(
            stream_error.to_openai_error_body()["error"]["param"],
            "stream"
        );
        assert_eq!(body_error.http_status(), 400);
        assert_eq!(body_error.to_openai_error_body()["error"]["param"], "body");
    }

    #[test]
    fn validates_embeddings_required_model_and_input() {
        let missing_model =
            OpenAiEmbeddingRequest::from_slice(br#"{"input":"hi"}"#).expect_err("missing model");
        let missing_input = OpenAiEmbeddingRequest::from_slice(br#"{"model":"mock-embedding"}"#)
            .expect_err("missing input");

        assert_eq!(missing_model.http_status(), 400);
        assert_eq!(
            missing_model.to_openai_error_body()["error"]["param"],
            "model"
        );
        assert_eq!(missing_input.http_status(), 400);
        assert_eq!(
            missing_input.to_openai_error_body()["error"]["param"],
            "input"
        );
    }

    #[test]
    fn builds_provider_authorization_header_without_exposing_secret_debug() {
        let header = bearer_authorization("sk-provider-secret").expect("valid bearer header");

        assert_eq!(
            header.to_str().expect("header str"),
            "Bearer sk-provider-secret"
        );

        let error = bearer_authorization("bad\nsecret").expect_err("invalid header");
        assert_eq!(error.http_status(), 500);
        assert!(!error.to_string().contains("bad\nsecret"));
    }

    #[test]
    fn provider_key_context_redacts_secret_from_upstream_json() {
        let secret = "provider-secret-without-prefix";
        let payload = OpenAiCompatibleClient::parse_chat_completions_response_with_context(
            200,
            br#"{"id":"chatcmpl_1","choices":[{"message":{"content":"provider-secret-without-prefix"}}],"usage":{"prompt_tokens":1}}"#,
            None,
            Some(secret),
        )
        .expect("success response should parse");

        assert!(!payload.to_string().contains(secret));
        assert_eq!(
            payload["choices"][0]["message"]["content"],
            REDACTED_PROVIDER_SECRET
        );

        let error = OpenAiCompatibleClient::parse_chat_completions_response_with_context(
            401,
            br#"{"error":{"message":"bad provider-secret-without-prefix","api_key":"provider-secret-without-prefix"}}"#,
            None,
            Some(secret),
        )
        .expect_err("provider error should preserve status");

        assert!(!error.to_openai_error_body().to_string().contains(secret));
    }

    #[test]
    fn adapter_build_and_stream_parse_accept_streaming_explicitly() {
        let client =
            OpenAiCompatibleClient::new("http://127.0.0.1:18080").expect("valid upstream base URL");
        let body =
            br#"{"model":"mock-gpt","messages":[{"role":"user","content":"hi"}],"stream":true}"#;

        let upstream = client
            .build_upstream_request(AdapterOperation::ChatCompletions, body)
            .expect("streaming build should be accepted");
        assert!(upstream.stream);
        assert_eq!(upstream.body["stream"], true);

        let event = client
            .parse_stream_event(AdapterOperation::ChatCompletions, br#"{"id":"chatcmpl_1"}"#)
            .expect("JSON stream event should parse");
        let done = client
            .parse_stream_event(AdapterOperation::ChatCompletions, b" [DONE]\n")
            .expect("DONE stream event should parse");

        assert_eq!(event["id"], "chatcmpl_1");
        assert_eq!(done["done"], true);
    }

    #[test]
    fn adapter_build_and_stream_parse_accept_responses_explicitly() {
        let client =
            OpenAiCompatibleClient::new("http://127.0.0.1:18080").expect("valid upstream base URL");
        let body = br#"{"model":"mock-gpt","input":"hi","stream":true}"#;

        let routing_fields = OpenAiResponseRequest::routing_fields_from_slice(body)
            .expect("responses routing fields should extract");
        assert_eq!(routing_fields.model.as_deref(), Some("mock-gpt"));
        assert!(routing_fields.stream);

        let upstream = client
            .build_upstream_request(AdapterOperation::Responses, body)
            .expect("responses streaming build should be accepted");
        assert_eq!(upstream.path, RESPONSES_PATH);
        assert!(upstream.stream);
        assert_eq!(upstream.body["stream"], true);

        let event = client
            .parse_stream_event(
                AdapterOperation::Responses,
                br#"{"type":"response.completed","response":{"id":"resp_1"}}"#,
            )
            .expect("responses JSON stream event should parse");

        assert_eq!(event["type"], "response.completed");
        assert_eq!(event["response"]["id"], "resp_1");
    }

    #[test]
    fn responses_stream_sse_fixtures_parse_terminal_error_usage_and_invalid_json() {
        let client =
            OpenAiCompatibleClient::new("http://127.0.0.1:18080").expect("valid upstream base URL");
        let completed = sse_fixture_events("responses_stream_completed.sse")
            .into_iter()
            .map(|data| {
                OpenAiCompatibleClient::parse_responses_stream_event(&data)
                    .expect("completed responses stream fixture event should parse")
            })
            .collect::<Vec<_>>();

        assert_eq!(completed.len(), 3);
        assert_eq!(
            completed[0].terminal_kind,
            OpenAiResponsesStreamTerminalKind::None
        );
        assert_eq!(completed[1].data["type"], "response.output_text.delta");
        assert_eq!(completed[1].data["delta"], "Hello");
        let non_terminal_with_usage = OpenAiCompatibleClient::parse_responses_stream_event(
            br#"{"type":"response.output_text.delta","delta":"Hello","usage":{"input_tokens":99,"output_tokens":99,"total_tokens":198}}"#,
        )
        .expect("non-terminal response stream event should parse");
        assert!(non_terminal_with_usage.usage().is_none());
        assert_eq!(
            completed[2].terminal_kind,
            OpenAiResponsesStreamTerminalKind::Completed
        );
        assert!(completed[2].is_terminal());
        assert!(!completed[2].is_error());

        let usage = completed[2]
            .usage()
            .expect("completed responses terminal event should expose response usage");
        assert_eq!(usage.prompt_tokens, Some(3));
        assert_eq!(usage.completion_tokens, Some(2));
        assert_eq!(usage.total_tokens, Some(5));

        let failed = sse_fixture_events("responses_stream_failed.sse")
            .into_iter()
            .map(|data| {
                OpenAiCompatibleClient::parse_responses_stream_event(&data)
                    .expect("failed responses stream fixture event should parse")
            })
            .collect::<Vec<_>>();
        assert_eq!(failed.len(), 2);
        assert_eq!(
            failed[1].terminal_kind,
            OpenAiResponsesStreamTerminalKind::Failed
        );
        assert!(failed[1].is_terminal());
        assert!(failed[1].is_error());

        let error_events = sse_fixture_events("responses_stream_error.sse")
            .into_iter()
            .map(|data| {
                OpenAiCompatibleClient::parse_responses_stream_event(&data)
                    .expect("error responses stream fixture event should parse")
            })
            .collect::<Vec<_>>();
        assert_eq!(error_events.len(), 1);
        let error = &error_events[0];
        assert_eq!(
            error.terminal_kind,
            OpenAiResponsesStreamTerminalKind::Error
        );
        assert!(error.is_terminal());
        assert!(error.is_error());

        let missing_terminal = sse_fixture_events("responses_stream_missing_terminal.sse")
            .into_iter()
            .map(|data| {
                OpenAiCompatibleClient::parse_responses_stream_event(&data)
                    .expect("missing-terminal responses stream fixture event should parse")
            })
            .collect::<Vec<_>>();
        assert_eq!(missing_terminal.len(), 3);
        assert!(missing_terminal.iter().all(|event| !event.is_terminal()));
        assert!(
            missing_terminal.iter().all(|event| event.usage().is_none()),
            "responses stream events without usage must not synthesize usage"
        );

        let invalid = sse_fixture_events("responses_stream_invalid_json.sse");
        let error = OpenAiCompatibleClient::parse_responses_stream_event(
            invalid.first().expect("invalid JSON fixture event"),
        )
        .expect_err("invalid JSON responses stream fixture should map to parser error");
        let mapping = error.to_adapter_error_mapping();
        assert_eq!(mapping.http_status, 502);
        assert_eq!(mapping.code, "provider_invalid_json");
        assert_eq!(mapping.owner, "parser");
        assert_eq!(mapping.stage, "response_transform");

        let trait_event = client
            .parse_stream_event(
                AdapterOperation::Responses,
                br#"{"type":"response.failed","response":{"id":"resp_1","status":"failed"}}"#,
            )
            .expect("adapter trait should still return raw response stream JSON");
        assert_eq!(trait_event["type"], "response.failed");
        assert_eq!(trait_event["response"]["status"], "failed");
    }

    #[test]
    fn stream_request_fixture_is_accepted_by_adapter_contract() {
        let client =
            OpenAiCompatibleClient::new("http://127.0.0.1:18080").expect("valid upstream base URL");
        let fixture = load_openai_fixture("chat_stream_request_rejected.json");
        let request = serde_json::to_vec(&fixture["request"]).expect("fixture request");

        let routing_fields = client
            .extract_routing_fields(&request)
            .expect("stream request routing fields should still extract");
        assert_eq!(routing_fields.model.as_deref(), Some("mock-gpt"));
        assert!(routing_fields.stream);

        let chat_request =
            ChatCompletionRequest::from_slice(&request).expect("stream fixture should validate");
        assert!(chat_request.is_streaming());

        let upstream = client
            .build_upstream_request(AdapterOperation::ChatCompletions, &request)
            .expect("stream fixture should build an upstream request");
        assert!(upstream.stream);
        assert_eq!(upstream.body["stream"], true);
    }

    #[test]
    fn parses_success_response_and_extracts_usage() {
        let payload = OpenAiCompatibleClient::parse_chat_completions_response(
            200,
            br#"{"id":"chatcmpl_1","usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}"#,
        )
        .expect("valid provider JSON");
        let client =
            OpenAiCompatibleClient::new("http://127.0.0.1:18080").expect("valid upstream base URL");
        let usage = client.extract_usage(&payload).expect("usage");

        assert_eq!(payload["id"], "chatcmpl_1");
        assert_eq!(usage.prompt_tokens, Some(3));
        assert_eq!(usage.completion_tokens, Some(4));
        assert_eq!(usage.total_tokens, Some(7));
    }

    #[test]
    fn parses_responses_success_response_and_extracts_usage() {
        let payload = OpenAiCompatibleClient::parse_responses_response(
            200,
            br#"{"id":"resp_1","usage":{"input_tokens":3,"output_tokens":4,"total_tokens":7}}"#,
        )
        .expect("valid provider JSON");
        let client =
            OpenAiCompatibleClient::new("http://127.0.0.1:18080").expect("valid upstream base URL");
        let usage = client.extract_usage(&payload).expect("usage");

        assert_eq!(payload["id"], "resp_1");
        assert_eq!(usage.prompt_tokens, Some(3));
        assert_eq!(usage.completion_tokens, Some(4));
        assert_eq!(usage.total_tokens, Some(7));
    }

    #[test]
    fn parses_embeddings_success_response_and_extracts_usage() {
        let payload = OpenAiCompatibleClient::parse_embeddings_response(
            200,
            br#"{"object":"list","usage":{"prompt_tokens":3,"total_tokens":3}}"#,
        )
        .expect("valid provider JSON");
        let client =
            OpenAiCompatibleClient::new("http://127.0.0.1:18080").expect("valid upstream base URL");
        let usage = client.extract_usage(&payload).expect("usage");

        assert_eq!(payload["object"], "list");
        assert_eq!(usage.prompt_tokens, Some(3));
        assert_eq!(usage.completion_tokens, None);
        assert_eq!(usage.total_tokens, Some(3));
    }

    #[test]
    fn parses_models_success_response_without_usage() {
        let payload = OpenAiCompatibleClient::parse_models_response(
            200,
            br#"{"object":"list","data":[{"id":"mock-gpt","object":"model"}]}"#,
        )
        .expect("valid provider JSON");
        let client =
            OpenAiCompatibleClient::new("http://127.0.0.1:18080").expect("valid upstream base URL");

        assert_eq!(payload["object"], "list");
        assert_eq!(payload["data"][0]["id"], "mock-gpt");
        assert_eq!(client.extract_usage(&payload), None);
    }

    #[test]
    fn maps_provider_status_and_invalid_json_to_clear_error_mapping() {
        let provider_error = OpenAiCompatibleClient::parse_chat_completions_response(
            401,
            br#"{"error":{"message":"bad key","type":"authentication_error"}}"#,
        )
        .expect_err("provider 401 should map to provider error");
        let provider_mapping = provider_error.to_adapter_error_mapping();

        assert_eq!(provider_mapping.http_status, 401);
        assert_eq!(provider_mapping.code, "provider_auth_failed");
        assert_eq!(provider_mapping.owner, "provider");
        assert_eq!(provider_mapping.stage, "provider_call");
        assert_eq!(provider_mapping.retryable, Some(false));
        assert_eq!(
            provider_mapping
                .signal
                .as_ref()
                .and_then(|signal| signal.status_code),
            Some(401)
        );

        let parser_error =
            OpenAiCompatibleClient::parse_chat_completions_response(200, b"not-json")
                .expect_err("invalid provider JSON should be mapped");
        let parser_mapping = parser_error.to_adapter_error_mapping();

        assert_eq!(parser_mapping.http_status, 502);
        assert_eq!(parser_mapping.code, "provider_invalid_json");
        assert_eq!(parser_mapping.owner, "parser");
        assert_eq!(parser_mapping.stage, "response_transform");
        assert_eq!(parser_mapping.retryable, Some(true));
        assert!(parser_mapping.signal.is_none());
    }

    #[test]
    fn maps_provider_429_retry_after_to_signal_and_json_error() {
        let error = OpenAiAdapterError::UpstreamStatus {
            status: 429,
            body: json!({
                "error": {
                    "message": "mock 429",
                    "type": "rate_limit_error"
                }
            }),
            retry_after: Some(AdapterRetryAfter::new("2", Some(2_000))),
        };

        let body = error.to_openai_error_body();
        assert_eq!(error.http_status(), 429);
        assert_eq!(error.retry_after_header_value(), Some("2"));
        assert_eq!(body["error"]["code"], "provider_429");
        assert_eq!(body["gateway"]["provider_status"], 429);
        assert_eq!(body["gateway"]["retry_after"], "2");
        assert_eq!(body["gateway"]["retry_after_ms"], 2_000);
        assert_eq!(body["gateway"]["error_signal"]["status_code"], 429);
        assert_eq!(body["gateway"]["error_signal"]["retry_after_ms"], 2_000);
        assert_eq!(
            body["gateway"]["provider_error"]["error"]["type"],
            "rate_limit_error"
        );

        let mapping = error.to_adapter_error_mapping();
        assert_eq!(mapping.code, "provider_429");
        assert_eq!(mapping.owner, "provider");
        assert_eq!(mapping.retryable, Some(true));
        assert_eq!(mapping.retry_after_ms, Some(2_000));
        assert_eq!(
            mapping
                .signal
                .as_ref()
                .and_then(|signal| signal.status_code),
            Some(429)
        );
    }

    #[test]
    fn maps_transport_errors_to_provider_error_signals() {
        let timeout = OpenAiAdapterError::UpstreamTimeout
            .to_error_signal()
            .expect("timeout signal");
        let connect = OpenAiAdapterError::UpstreamConnect("connect failed".to_string())
            .to_error_signal()
            .expect("connect signal");
        let read = OpenAiAdapterError::UpstreamRead("read failed".to_string())
            .to_error_signal()
            .expect("read signal");

        assert_eq!(
            timeout.transport,
            Some(AdapterProviderTransportErrorKind::Timeout)
        );
        assert_eq!(
            connect.transport,
            Some(AdapterProviderTransportErrorKind::Connect)
        );
        assert_eq!(
            read.transport,
            Some(AdapterProviderTransportErrorKind::Body)
        );
    }

    #[test]
    fn maps_provider_5xx_to_status_error_signal() {
        let error = OpenAiCompatibleClient::parse_chat_completions_response(
            503,
            br#"{"error":{"message":"overloaded"}}"#,
        )
        .expect_err("provider 503 should map to provider error");
        let mapping = error.to_adapter_error_mapping();

        assert_eq!(mapping.code, "provider_5xx");
        assert_eq!(
            mapping
                .signal
                .as_ref()
                .and_then(|signal| signal.status_code),
            Some(503)
        );
    }

    #[test]
    fn conformance_fixtures_cover_non_stream_chat_and_error_mapping() {
        let client =
            OpenAiCompatibleClient::new("http://127.0.0.1:18080").expect("valid upstream base URL");

        let valid = load_openai_fixture("chat_non_stream_valid.json");
        let valid_request = serde_json::to_vec(&valid["request"]).expect("fixture request");
        let upstream = client
            .build_upstream_request(AdapterOperation::ChatCompletions, &valid_request)
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

        let parsed = client
            .parse_response(
                AdapterOperation::ChatCompletions,
                fixture_response_status(&valid),
                &fixture_response_body(&valid),
            )
            .expect("valid fixture response should parse");
        assert_eq!(&parsed, &valid["response"]["body"]);

        let usage = client
            .extract_usage(&parsed)
            .expect("valid fixture should include usage");
        let actual_usage = serde_json::to_value(usage).expect("usage should serialize");
        assert_eq!(&actual_usage, &valid["expected_usage"]);

        let invalid = load_openai_fixture("invalid_request.json");
        let invalid_request = serde_json::to_vec(&invalid["request"]).expect("fixture request");
        let invalid_error = ChatCompletionRequest::from_slice(&invalid_request)
            .expect_err("invalid request fixture should fail validation");
        let invalid_mapping = invalid_error.to_adapter_error_mapping();
        assert_error_mapping_matches(&invalid_mapping, &invalid["expected_error_mapping"]);

        let gateway_error = client
            .build_upstream_request(AdapterOperation::ChatCompletions, &invalid_request)
            .expect_err("invalid request fixture should fail adapter build");
        assert_eq!(gateway_error.owner, GatewayErrorOwner::Client);
        assert_eq!(gateway_error.code, invalid_mapping.code);

        for fixture_name in [
            "provider_429_retry_after.json",
            "provider_5xx.json",
            "invalid_json_response.json",
        ] {
            let fixture = load_openai_fixture(fixture_name);
            let headers = fixture_response_headers(&fixture);
            let retry_after = retry_after_from_headers(&headers);
            let error = OpenAiCompatibleClient::parse_chat_completions_response_with_retry_after(
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
    fn conformance_fixture_covers_non_stream_responses() {
        let client =
            OpenAiCompatibleClient::new("http://127.0.0.1:18080").expect("valid upstream base URL");

        let fixture = load_openai_fixture("responses_non_stream_valid.json");
        let request = serde_json::to_vec(&fixture["request"]).expect("fixture request");
        let upstream = client
            .build_upstream_request(AdapterOperation::Responses, &request)
            .expect("valid fixture should build an upstream request");
        let expected_upstream = &fixture["expected_upstream"];

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

        let parsed = client
            .parse_response(
                AdapterOperation::Responses,
                fixture_response_status(&fixture),
                &fixture_response_body(&fixture),
            )
            .expect("valid fixture response should parse");
        assert_eq!(&parsed, &fixture["response"]["body"]);

        let usage = client
            .extract_usage(&parsed)
            .expect("valid fixture should include usage");
        let actual_usage = serde_json::to_value(usage).expect("usage should serialize");
        assert_eq!(&actual_usage, &fixture["expected_usage"]);
    }

    #[test]
    fn conformance_fixture_covers_non_stream_embeddings() {
        let client =
            OpenAiCompatibleClient::new("http://127.0.0.1:18080").expect("valid upstream base URL");

        let fixture = load_openai_fixture("embeddings_non_stream_valid.json");
        let request = serde_json::to_vec(&fixture["request"]).expect("fixture request");
        let routing_fields = OpenAiEmbeddingRequest::routing_fields_from_slice(&request)
            .expect("valid fixture routing fields should extract");
        let upstream = client
            .build_upstream_request(AdapterOperation::Embeddings, &request)
            .expect("valid fixture should build an upstream request");
        let expected_upstream = &fixture["expected_upstream"];

        assert_eq!(routing_fields.model.as_deref(), Some("mock-embedding"));
        assert!(!routing_fields.stream);
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

        let parsed = client
            .parse_response(
                AdapterOperation::Embeddings,
                fixture_response_status(&fixture),
                &fixture_response_body(&fixture),
            )
            .expect("valid fixture response should parse");
        assert_eq!(&parsed, &fixture["response"]["body"]);

        let usage = client
            .extract_usage(&parsed)
            .expect("valid fixture should include usage");
        let actual_usage = serde_json::to_value(usage).expect("usage should serialize");
        assert_eq!(&actual_usage, &fixture["expected_usage"]);
    }

    #[test]
    fn conformance_fixture_covers_models_list() {
        let client =
            OpenAiCompatibleClient::new("http://127.0.0.1:18080").expect("valid upstream base URL");

        let fixture = load_openai_fixture("models_list_valid.json");
        let request = serde_json::to_vec(&fixture["request"]).expect("fixture request");
        let routing_fields = OpenAiModelsRequest::routing_fields_from_slice(&request)
            .expect("valid fixture routing fields should extract");
        let upstream = client
            .build_upstream_request(AdapterOperation::Models, &request)
            .expect("valid fixture should build an upstream request");
        let expected_upstream = &fixture["expected_upstream"];

        assert_eq!(routing_fields.model, None);
        assert!(!routing_fields.stream);
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

        let parsed = client
            .parse_response(
                AdapterOperation::Models,
                fixture_response_status(&fixture),
                &fixture_response_body(&fixture),
            )
            .expect("valid fixture response should parse");
        assert_eq!(&parsed, &fixture["response"]["body"]);
        assert_eq!(fixture["expected_usage"], Value::Null);
        assert!(
            client.extract_usage(&parsed).is_none(),
            "models list must not synthesize usage"
        );

        let invalid = load_openai_fixture("models_invalid_json_response.json");
        let invalid_error = OpenAiCompatibleClient::parse_models_response(
            fixture_response_status(&invalid),
            &fixture_response_body(&invalid),
        )
        .expect_err("models invalid JSON fixture should map to an adapter error");
        assert_error_mapping_matches(
            &invalid_error.to_adapter_error_mapping(),
            &invalid["expected_error_mapping"],
        );

        let unsupported = load_openai_fixture("models_stream_unsupported.json");
        let unsupported_request =
            serde_json::to_vec(&unsupported["request"]).expect("fixture request");
        let routing_fields = OpenAiModelsRequest::routing_fields_from_slice(&unsupported_request)
            .expect("stream intent should be extractable");
        let unsupported_error = OpenAiModelsRequest::from_slice(&unsupported_request)
            .expect_err("stream=true models fixture should fail validation");
        let unsupported_mapping = unsupported_error.to_adapter_error_mapping();
        assert!(routing_fields.stream);
        assert_error_mapping_matches(&unsupported_mapping, &unsupported["expected_error_mapping"]);

        let gateway_error = client
            .build_upstream_request(AdapterOperation::Models, &unsupported_request)
            .expect_err("stream=true models fixture should fail adapter build");
        assert_eq!(gateway_error.owner, GatewayErrorOwner::Client);
        assert_eq!(gateway_error.code, unsupported_mapping.code);

        let stream_parse_error = client
            .parse_stream_event(AdapterOperation::Models, br#"{}"#)
            .expect_err("models stream parsing is unsupported");
        assert_eq!(stream_parse_error.owner, GatewayErrorOwner::Gateway);
        assert_eq!(stream_parse_error.code, "adapter_operation_unsupported");
    }
}
