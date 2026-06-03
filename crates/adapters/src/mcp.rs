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

const MCP_PATH: &str = "/mcp";
const METHOD_INITIALIZE: &str = "initialize";
const METHOD_TOOLS_LIST: &str = "tools/list";
const METHOD_TOOLS_CALL: &str = "tools/call";
const GATEWAY_STREAM_PARAM: &str = "params._meta.gateway_stream";

#[derive(Debug, Clone, Default)]
pub struct McpAdapter;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct McpJsonRpcRequest {
    #[serde(default)]
    pub jsonrpc: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<Value>,
    #[serde(default)]
    pub method: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub params: Option<Value>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct McpJsonRpcResponse {
    pub jsonrpc: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<Value>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct McpRoutingFields {
    #[serde(default)]
    pub request_id: Option<Value>,
    pub method: String,
    #[serde(default)]
    pub tool_name: Option<String>,
    pub stream: bool,
}

#[derive(Debug, Error)]
pub enum McpAdapterError {
    #[error("invalid JSON request body: {0}")]
    InvalidJson(String),
    #[error("invalid MCP JSON-RPC request: {message}")]
    InvalidRequest {
        message: String,
        param: Option<&'static str>,
    },
    #[error("failed to serialize upstream request: {0}")]
    RequestSerialize(String),
    #[error("MCP streaming is not supported by this adapter contract")]
    StreamingUnsupported,
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
    #[error("upstream returned invalid MCP JSON-RPC response with HTTP {status}: {message}")]
    UpstreamInvalidResponse {
        status: u16,
        message: String,
        retry_after: Option<AdapterRetryAfter>,
    },
    #[error("upstream MCP server returned JSON-RPC error")]
    UpstreamJsonRpcError {
        status: u16,
        body: Value,
        retry_after: Option<AdapterRetryAfter>,
    },
}

impl McpAdapter {
    pub const fn new() -> Self {
        Self
    }

    pub fn routing_fields_from_slice(body: &[u8]) -> Result<McpRoutingFields, McpAdapterError> {
        McpJsonRpcRequest::routing_fields_from_slice(body)
    }

    pub fn build_json_rpc_request(
        &self,
        operation: AdapterOperation,
        request: &McpJsonRpcRequest,
    ) -> Result<AdapterUpstreamRequest, McpAdapterError> {
        request.to_upstream_request(operation)
    }

    pub fn parse_json_rpc_response(status: u16, body: &[u8]) -> Result<Value, McpAdapterError> {
        Self::parse_json_rpc_response_with_retry_after(status, body, None)
    }

    fn parse_json_rpc_response_with_retry_after(
        status: u16,
        body: &[u8],
        retry_after: Option<AdapterRetryAfter>,
    ) -> Result<Value, McpAdapterError> {
        let json = match serde_json::from_slice::<Value>(body) {
            Ok(json) => json,
            Err(error) => {
                return Err(McpAdapterError::UpstreamInvalidJson {
                    status,
                    message: error.to_string(),
                    retry_after,
                });
            }
        };

        if !(200..300).contains(&status) {
            return Err(McpAdapterError::UpstreamStatus {
                status,
                body: json,
                retry_after,
            });
        }

        validate_json_rpc_response(&json, status, retry_after.clone())?;

        if json.get("error").is_some_and(Value::is_object) {
            return Err(McpAdapterError::UpstreamJsonRpcError {
                status,
                body: json,
                retry_after,
            });
        }

        Ok(json)
    }
}

impl McpJsonRpcRequest {
    pub fn routing_fields_from_slice(body: &[u8]) -> Result<McpRoutingFields, McpAdapterError> {
        let value: Value = serde_json::from_slice(body)
            .map_err(|error| McpAdapterError::InvalidJson(error.to_string()))?;
        let object = value.as_object().ok_or_else(|| {
            McpAdapterError::invalid_request("request body must be a JSON object", Some("body"))
        })?;

        validate_jsonrpc_version(object)?;
        let method = string_field_required(object, "method", Some("method"))?;
        validate_supported_method(method)?;

        let request_id = object.get("id").cloned();
        let params = optional_object_value(object, "params")?;
        let tool_name = if method == METHOD_TOOLS_CALL {
            params
                .and_then(Value::as_object)
                .and_then(|params| params.get("name"))
                .and_then(Value::as_str)
                .map(str::to_string)
        } else {
            None
        };
        let stream = gateway_stream_requested(params)?;

        Ok(McpRoutingFields {
            request_id,
            method: method.to_string(),
            tool_name,
            stream,
        })
    }

    pub fn from_slice(body: &[u8]) -> Result<Self, McpAdapterError> {
        let request: Self = serde_json::from_slice(body)
            .map_err(|error| McpAdapterError::InvalidJson(error.to_string()))?;
        request.validate()?;
        Ok(request)
    }

    pub fn validate(&self) -> Result<(), McpAdapterError> {
        if self.jsonrpc != "2.0" {
            return Err(McpAdapterError::invalid_request(
                "jsonrpc must be exactly \"2.0\"",
                Some("jsonrpc"),
            ));
        }

        let method = self.method.trim();
        if method.is_empty() {
            return Err(McpAdapterError::invalid_request(
                "method must be a non-empty string",
                Some("method"),
            ));
        }
        validate_supported_method(method)?;
        validate_json_rpc_id(self.id.as_ref())?;

        if !self.extra.is_empty() {
            return Err(McpAdapterError::invalid_request(
                "top-level JSON-RPC fields beyond jsonrpc, id, method, and params are not supported",
                Some("body"),
            ));
        }

        if gateway_stream_requested(self.params.as_ref())? {
            return Err(McpAdapterError::StreamingUnsupported);
        }

        match self.method.as_str() {
            METHOD_INITIALIZE => validate_initialize_params(self.params.as_ref())?,
            METHOD_TOOLS_LIST => validate_optional_params_object(self.params.as_ref())?,
            METHOD_TOOLS_CALL => validate_tools_call_params(self.params.as_ref())?,
            _ => unreachable!("validate_supported_method checks method"),
        }

        Ok(())
    }

    pub fn to_upstream_request(
        &self,
        operation: AdapterOperation,
    ) -> Result<AdapterUpstreamRequest, McpAdapterError> {
        self.validate()?;
        validate_operation_method(operation, &self.method)?;

        Ok(AdapterUpstreamRequest {
            method: "POST".to_string(),
            path: MCP_PATH.to_string(),
            body: serde_json::to_value(self)
                .map_err(|error| McpAdapterError::RequestSerialize(error.to_string()))?,
            stream: false,
        })
    }
}

impl McpAdapterError {
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
            Self::StreamingUnsupported => 501,
            Self::UpstreamInvalidJson { .. }
            | Self::UpstreamInvalidResponse { .. }
            | Self::UpstreamJsonRpcError { .. } => 502,
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
            Self::StreamingUnsupported => error_body(
                "invalid_request_error",
                "mcp_streaming_unsupported",
                "MCP streaming is reserved for a future adapter contract",
                Some(GATEWAY_STREAM_PARAM),
                json!({
                    "error_owner": "gateway",
                    "error_stage": "request_validate"
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
            Self::UpstreamJsonRpcError { status, body, .. } => error_body(
                "provider_error",
                "provider_jsonrpc_error",
                "upstream MCP server returned JSON-RPC error",
                None,
                json!({
                    "error_owner": "provider",
                    "error_stage": "provider_call",
                    "provider_status": status,
                    "provider_error": body.get("error").cloned().unwrap_or(Value::Null)
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
            retryable: self.retryable(),
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
            | Self::UpstreamInvalidResponse { retry_after, .. }
            | Self::UpstreamJsonRpcError { retry_after, .. } => retry_after.as_ref(),
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

    fn retryable(&self) -> Option<bool> {
        match self {
            Self::StreamingUnsupported => Some(false),
            _ => AdapterErrorMapping::retryable_for_status(self.http_status()),
        }
    }

    fn attach_error_signal_metadata(&self, body: &mut Value) {
        let Some(gateway) = body.get_mut("gateway").and_then(Value::as_object_mut) else {
            return;
        };

        gateway.insert("retryable".to_string(), json!(self.retryable()));

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

impl Adapter for McpAdapter {
    fn protocol_mode(&self) -> ProtocolMode {
        ProtocolMode::Mcp
    }

    fn capabilities(&self) -> AdapterCapabilities {
        AdapterCapabilities {
            operations: vec![
                AdapterOperation::McpInitialize,
                AdapterOperation::McpToolsList,
                AdapterOperation::McpToolsCall,
            ],
            stream_policy: AdapterStreamPolicy::Reject,
        }
    }

    fn extract_model(&self, _body: &[u8]) -> Result<Option<String>, GatewayError> {
        Ok(None)
    }

    fn extract_routing_fields(&self, body: &[u8]) -> Result<AdapterRoutingFields, GatewayError> {
        let fields = McpJsonRpcRequest::routing_fields_from_slice(body)
            .map_err(|error| error.to_gateway_error())?;

        Ok(AdapterRoutingFields {
            model: None,
            stream: fields.stream,
        })
    }

    fn build_upstream_request(
        &self,
        operation: AdapterOperation,
        body: &[u8],
    ) -> Result<AdapterUpstreamRequest, GatewayError> {
        match operation {
            AdapterOperation::McpInitialize
            | AdapterOperation::McpToolsList
            | AdapterOperation::McpToolsCall => {
                let request = McpJsonRpcRequest::from_slice(body)
                    .map_err(|error| error.to_gateway_error())?;
                self.build_json_rpc_request(operation, &request)
                    .map_err(|error| error.to_gateway_error())
            }
            _ => Err(unsupported_mcp_operation(
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
            AdapterOperation::McpInitialize
            | AdapterOperation::McpToolsList
            | AdapterOperation::McpToolsCall => Self::parse_json_rpc_response(status, body)
                .map_err(|error| error.to_gateway_error()),
            _ => Err(unsupported_mcp_operation(operation, "parse_response")),
        }
    }

    fn parse_stream_event(
        &self,
        operation: AdapterOperation,
        _event: &[u8],
    ) -> Result<Value, GatewayError> {
        match operation {
            AdapterOperation::McpInitialize
            | AdapterOperation::McpToolsList
            | AdapterOperation::McpToolsCall => {
                Err(McpAdapterError::StreamingUnsupported.to_gateway_error())
            }
            _ => Err(unsupported_mcp_operation(operation, "parse_stream_event")),
        }
    }

    fn extract_usage(&self, _response: &Value) -> Option<AdapterUsage> {
        None
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

fn validate_jsonrpc_version(object: &Map<String, Value>) -> Result<(), McpAdapterError> {
    match object.get("jsonrpc") {
        Some(Value::String(version)) if version == "2.0" => Ok(()),
        Some(Value::String(_)) | Some(_) | None => Err(McpAdapterError::invalid_request(
            "jsonrpc must be exactly \"2.0\"",
            Some("jsonrpc"),
        )),
    }
}

fn string_field_required<'a>(
    object: &'a Map<String, Value>,
    field: &'static str,
    param: Option<&'static str>,
) -> Result<&'a str, McpAdapterError> {
    match object.get(field) {
        Some(Value::String(value)) if !value.trim().is_empty() => Ok(value.trim()),
        Some(Value::String(_)) | Some(_) | None => Err(McpAdapterError::invalid_request(
            format!("{field} must be a non-empty string"),
            param,
        )),
    }
}

fn optional_object_value<'a>(
    object: &'a Map<String, Value>,
    field: &'static str,
) -> Result<Option<&'a Value>, McpAdapterError> {
    match object.get(field) {
        Some(Value::Object(_)) => Ok(object.get(field)),
        Some(Value::Null) | None => Ok(None),
        Some(_) => Err(McpAdapterError::invalid_request(
            format!("{field} must be an object"),
            Some(field),
        )),
    }
}

fn validate_supported_method(method: &str) -> Result<(), McpAdapterError> {
    match method {
        METHOD_INITIALIZE | METHOD_TOOLS_LIST | METHOD_TOOLS_CALL => Ok(()),
        _ => Err(McpAdapterError::invalid_request(
            "method must be one of initialize, tools/list, or tools/call",
            Some("method"),
        )),
    }
}

fn validate_json_rpc_id(id: Option<&Value>) -> Result<(), McpAdapterError> {
    match id {
        Some(Value::String(value)) if !value.trim().is_empty() => Ok(()),
        Some(Value::Number(number)) if number.is_i64() || number.is_u64() => Ok(()),
        _ => Err(McpAdapterError::invalid_request(
            "id must be a string or integer for MCP requests",
            Some("id"),
        )),
    }
}

fn validate_initialize_params(params: Option<&Value>) -> Result<(), McpAdapterError> {
    let params = required_params_object(params)?;
    string_field_required(params, "protocolVersion", Some("params.protocolVersion"))?;

    match params.get("clientInfo") {
        Some(Value::Object(client_info)) => {
            string_field_required(client_info, "name", Some("params.clientInfo.name"))?;
            string_field_required(client_info, "version", Some("params.clientInfo.version"))?;
        }
        _ => {
            return Err(McpAdapterError::invalid_request(
                "params.clientInfo must be an object",
                Some("params.clientInfo"),
            ));
        }
    }

    if let Some(capabilities) = params.get("capabilities")
        && !capabilities.is_object()
    {
        return Err(McpAdapterError::invalid_request(
            "params.capabilities must be an object",
            Some("params.capabilities"),
        ));
    }

    Ok(())
}

fn validate_optional_params_object(params: Option<&Value>) -> Result<(), McpAdapterError> {
    if let Some(params) = params
        && !params.is_object()
    {
        return Err(McpAdapterError::invalid_request(
            "params must be an object",
            Some("params"),
        ));
    }

    Ok(())
}

fn validate_tools_call_params(params: Option<&Value>) -> Result<(), McpAdapterError> {
    let params = required_params_object(params)?;
    string_field_required(params, "name", Some("params.name"))?;

    if let Some(arguments) = params.get("arguments")
        && !arguments.is_object()
    {
        return Err(McpAdapterError::invalid_request(
            "params.arguments must be an object",
            Some("params.arguments"),
        ));
    }

    Ok(())
}

fn required_params_object(params: Option<&Value>) -> Result<&Map<String, Value>, McpAdapterError> {
    match params {
        Some(Value::Object(params)) => Ok(params),
        _ => Err(McpAdapterError::invalid_request(
            "params must be an object",
            Some("params"),
        )),
    }
}

fn gateway_stream_requested(params: Option<&Value>) -> Result<bool, McpAdapterError> {
    let Some(Value::Object(params)) = params else {
        return Ok(false);
    };
    let Some(meta) = params.get("_meta") else {
        return Ok(false);
    };
    let Some(meta) = meta.as_object() else {
        return Err(McpAdapterError::invalid_request(
            "params._meta must be an object",
            Some("params._meta"),
        ));
    };

    match meta.get("gateway_stream") {
        Some(Value::Bool(value)) => Ok(*value),
        Some(Value::Null) | None => Ok(false),
        Some(_) => Err(McpAdapterError::invalid_request(
            "params._meta.gateway_stream must be a boolean",
            Some(GATEWAY_STREAM_PARAM),
        )),
    }
}

fn validate_operation_method(
    operation: AdapterOperation,
    method: &str,
) -> Result<(), McpAdapterError> {
    let expected = match operation {
        AdapterOperation::McpInitialize => METHOD_INITIALIZE,
        AdapterOperation::McpToolsList => METHOD_TOOLS_LIST,
        AdapterOperation::McpToolsCall => METHOD_TOOLS_CALL,
        _ => {
            return Err(McpAdapterError::invalid_request(
                "adapter operation is not an MCP operation",
                Some("method"),
            ));
        }
    };

    if method == expected {
        Ok(())
    } else {
        Err(McpAdapterError::invalid_request(
            format!("method must be {expected} for {operation:?}"),
            Some("method"),
        ))
    }
}

fn validate_json_rpc_response(
    response: &Value,
    status: u16,
    retry_after: Option<AdapterRetryAfter>,
) -> Result<(), McpAdapterError> {
    let object = response
        .as_object()
        .ok_or_else(|| McpAdapterError::UpstreamInvalidResponse {
            status,
            message: "response body must be a JSON-RPC object".to_string(),
            retry_after: retry_after.clone(),
        })?;

    match object.get("jsonrpc") {
        Some(Value::String(version)) if version == "2.0" => {}
        _ => {
            return Err(McpAdapterError::UpstreamInvalidResponse {
                status,
                message: "response.jsonrpc must be exactly \"2.0\"".to_string(),
                retry_after: retry_after.clone(),
            });
        }
    }

    let has_result = object.contains_key("result");
    let has_error = object.get("error").is_some_and(Value::is_object);
    if has_result == has_error {
        return Err(McpAdapterError::UpstreamInvalidResponse {
            status,
            message: "response must include exactly one of result or error".to_string(),
            retry_after,
        });
    }

    Ok(())
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

fn unsupported_mcp_operation(operation: AdapterOperation, method: &str) -> GatewayError {
    GatewayError::new(
        GatewayErrorOwner::Gateway,
        "adapter_operation_unsupported",
        format!("MCP adapter does not implement {method} for {operation:?}"),
    )
}

#[cfg(test)]
mod tests {
    use std::{fs, path::PathBuf};

    use ai_gateway_shared::GatewayErrorOwner;

    use super::*;

    fn load_mcp_fixture(file_name: &str) -> Value {
        let path = mcp_fixture_path(file_name);
        let contents = fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("failed to read fixture {}: {error}", path.display()));

        serde_json::from_str(&contents)
            .unwrap_or_else(|error| panic!("failed to parse fixture {}: {error}", path.display()))
    }

    fn mcp_fixture_path(file_name: &str) -> PathBuf {
        let mut path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        path.pop();
        path.pop();
        path.push("tests");
        path.push("fixtures");
        path.push("adapters");
        path.push("mcp");
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

    fn mcp_fixture_texts() -> Vec<(String, String)> {
        let root = mcp_fixture_path("");
        let entries = fs::read_dir(&root)
            .unwrap_or_else(|error| panic!("failed to read fixture directory: {error}"));
        let mut fixtures = Vec::new();

        for entry in entries {
            let path = entry
                .unwrap_or_else(|error| panic!("failed to read fixture entry: {error}"))
                .path();
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

        fixtures
    }

    fn assert_fixture_text_is_secret_safe(label: &str, text: &str) {
        assert!(
            !text.contains("Authorization"),
            "{label}: fixture must not contain authorization headers"
        );
        assert!(
            !text.contains("Bearer "),
            "{label}: fixture must not contain bearer values"
        );
        assert!(
            !text.contains("raw_api_key"),
            "{label}: fixture must not contain raw key fields"
        );
        assert!(
            !text.contains("secret"),
            "{label}: fixture must not contain secret fields or values"
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
    fn adapter_contract_declares_mcp_surface_with_rejected_streaming() {
        let adapter = McpAdapter::new();
        let capabilities = adapter.capabilities();

        assert_eq!(adapter.protocol_mode(), ProtocolMode::Mcp);
        assert!(capabilities.supports(AdapterOperation::McpInitialize));
        assert!(capabilities.supports(AdapterOperation::McpToolsList));
        assert!(capabilities.supports(AdapterOperation::McpToolsCall));
        assert_eq!(capabilities.stream_policy, AdapterStreamPolicy::Reject);
    }

    #[test]
    fn extracts_mcp_routing_fields_without_full_method_validation() {
        let body = br#"{"jsonrpc":"2.0","id":"call-1","method":"tools/call","params":{"name":"weather_summary","arguments":{"city":"London"}}}"#;

        let fields =
            McpAdapter::routing_fields_from_slice(body).expect("MCP routing fields should parse");
        assert_eq!(fields.request_id, Some(Value::String("call-1".to_string())));
        assert_eq!(fields.method, METHOD_TOOLS_CALL);
        assert_eq!(fields.tool_name.as_deref(), Some("weather_summary"));
        assert!(!fields.stream);

        let adapter = McpAdapter::new();
        let trait_fields = adapter
            .extract_routing_fields(body)
            .expect("adapter trait routing fields should parse");
        assert_eq!(trait_fields.model, None);
        assert!(!trait_fields.stream);
    }

    #[test]
    fn validates_required_fields_operation_match_and_stream_rejection() {
        let mismatch = McpJsonRpcRequest::from_slice(
            br#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#,
        )
        .expect("tools/list request should validate")
        .to_upstream_request(AdapterOperation::McpToolsCall)
        .expect_err("operation/method mismatch should be rejected");
        assert_eq!(mismatch.http_status(), 400);
        assert_eq!(mismatch.to_adapter_error_body()["error"]["param"], "method");

        let missing_protocol = McpJsonRpcRequest::from_slice(
            br#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"fixture-client","version":"0.1.0"}}}"#,
        )
        .expect_err("initialize without protocolVersion should be rejected");
        assert_eq!(missing_protocol.http_status(), 400);
        assert_eq!(
            missing_protocol.to_adapter_error_body()["error"]["param"],
            "params.protocolVersion"
        );

        let streaming = McpJsonRpcRequest::from_slice(
            br#"{"jsonrpc":"2.0","id":"stream-1","method":"tools/list","params":{"_meta":{"gateway_stream":true}}}"#,
        )
        .expect_err("gateway_stream is reserved for future contract");
        assert_eq!(streaming.http_status(), 501);
        assert_eq!(
            streaming.to_adapter_error_body()["error"]["code"],
            "mcp_streaming_unsupported"
        );
        assert_eq!(streaming.to_adapter_error_mapping().retryable, Some(false));
    }

    #[test]
    fn conformance_fixtures_cover_initialize_tools_and_errors() {
        let adapter = McpAdapter::new();

        for (fixture_name, operation) in [
            ("initialize_valid.json", AdapterOperation::McpInitialize),
            ("tools_list_valid.json", AdapterOperation::McpToolsList),
            ("tools_call_valid.json", AdapterOperation::McpToolsCall),
        ] {
            let fixture = load_mcp_fixture(fixture_name);
            let request = serde_json::to_vec(&fixture["request"]).expect("fixture request");
            let upstream = adapter
                .build_upstream_request(operation, &request)
                .expect("valid fixture should build an upstream request");
            let expected_upstream = &fixture["expected_upstream"];

            assert_eq!(
                upstream.method,
                expected_upstream["method"].as_str().expect("method"),
                "{fixture_name}"
            );
            assert_eq!(
                upstream.path,
                expected_upstream["path"].as_str().expect("path"),
                "{fixture_name}"
            );
            assert_eq!(
                upstream.stream,
                expected_upstream["stream"].as_bool().expect("stream"),
                "{fixture_name}"
            );
            assert_eq!(&upstream.body, &expected_upstream["body"], "{fixture_name}");

            let routing = McpAdapter::routing_fields_from_slice(&request)
                .expect("fixture routing fields should parse");
            assert_eq!(
                serde_json::to_value(routing).expect("routing fields should serialize"),
                fixture["expected_routing"],
                "{fixture_name}"
            );

            let parsed = adapter
                .parse_response(
                    operation,
                    fixture_response_status(&fixture),
                    &fixture_response_body(&fixture),
                )
                .expect("valid fixture response should parse");
            assert_eq!(&parsed, &fixture["response"]["body"], "{fixture_name}");
            assert_eq!(adapter.extract_usage(&parsed), None);
        }

        for fixture_name in ["invalid_request.json", "streaming_unsupported.json"] {
            let fixture = load_mcp_fixture(fixture_name);
            let request = serde_json::to_vec(&fixture["request"]).expect("fixture request");
            let error = McpJsonRpcRequest::from_slice(&request)
                .expect_err("invalid request fixture should fail validation");
            assert_error_mapping_matches(
                &error.to_adapter_error_mapping(),
                &fixture["expected_error_mapping"],
            );
        }

        let invalid = load_mcp_fixture("invalid_request.json");
        let invalid_request = serde_json::to_vec(&invalid["request"]).expect("fixture request");
        let invalid_error = adapter
            .build_upstream_request(AdapterOperation::McpToolsList, &invalid_request)
            .expect_err("invalid request fixture should fail adapter build");
        assert_eq!(invalid_error.owner, GatewayErrorOwner::Client);

        for fixture_name in [
            "provider_429_retry_after.json",
            "provider_5xx.json",
            "provider_jsonrpc_error.json",
            "invalid_json_response.json",
            "invalid_jsonrpc_response.json",
        ] {
            let fixture = load_mcp_fixture(fixture_name);
            let headers = fixture_response_headers(&fixture);
            let retry_after = retry_after_from_headers(&headers);
            let error = McpAdapter::parse_json_rpc_response_with_retry_after(
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
    fn parse_stream_event_is_explicitly_unsupported() {
        let adapter = McpAdapter::new();
        let error = adapter
            .parse_stream_event(AdapterOperation::McpToolsCall, br#"{}"#)
            .expect_err("MCP streaming is not implemented in this contract");

        assert_eq!(error.owner, GatewayErrorOwner::Gateway);
        assert_eq!(error.code, "mcp_streaming_unsupported");
    }

    #[test]
    fn mcp_fixtures_are_secret_safe() {
        for (label, text) in mcp_fixture_texts() {
            assert_fixture_text_is_secret_safe(&label, &text);
        }
    }
}
