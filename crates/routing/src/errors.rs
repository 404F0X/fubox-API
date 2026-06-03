use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ProviderTransportErrorKind {
    Timeout,
    Connect,
    Dns,
    Tls,
    ConnectionClosed,
    Body,
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ProviderStreamErrorKind {
    InvalidSse,
    IncompleteEvent,
    UnexpectedEof,
    DecodeError,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ProviderErrorKind {
    Authentication,
    RateLimited,
    Timeout,
    Transport,
    ClientRequest,
    NotFound,
    ProviderServer,
    ProviderOverloaded,
    ProviderProtocol,
    StreamProtocol,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum HealthImpact {
    None,
    Degrade,
    Cooldown,
    MarkAuthFailed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderErrorSignal {
    pub status_code: Option<u16>,
    pub transport: Option<ProviderTransportErrorKind>,
    pub stream: Option<ProviderStreamErrorKind>,
    pub retry_after_ms: Option<u64>,
}

impl ProviderErrorSignal {
    pub const fn from_status(status_code: u16) -> Self {
        Self {
            status_code: Some(status_code),
            transport: None,
            stream: None,
            retry_after_ms: None,
        }
    }

    pub const fn from_transport(transport: ProviderTransportErrorKind) -> Self {
        Self {
            status_code: None,
            transport: Some(transport),
            stream: None,
            retry_after_ms: None,
        }
    }

    pub const fn from_stream(stream: ProviderStreamErrorKind) -> Self {
        Self {
            status_code: None,
            transport: None,
            stream: Some(stream),
            retry_after_ms: None,
        }
    }

    pub const fn with_retry_after_ms(mut self, retry_after_ms: u64) -> Self {
        self.retry_after_ms = Some(retry_after_ms);
        self
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderErrorClassification {
    pub kind: ProviderErrorKind,
    pub retryable_same_channel: bool,
    pub can_fallback: bool,
    pub health_impact: HealthImpact,
    pub status_code: Option<u16>,
    pub retry_after_ms: Option<u64>,
    pub reason_code: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AdapterProviderErrorTransportKind {
    Timeout,
    Connect,
    Body,
    Other,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct AdapterProviderErrorRoutingInput {
    pub status_code: Option<u16>,
    pub transport: Option<AdapterProviderErrorTransportKind>,
    pub retry_after_ms: Option<u64>,
    pub owner: Option<String>,
    pub stage: Option<String>,
    pub code: Option<String>,
}

impl AdapterProviderErrorRoutingInput {
    pub const fn from_status(status_code: u16) -> Self {
        Self {
            status_code: Some(status_code),
            transport: None,
            retry_after_ms: None,
            owner: None,
            stage: None,
            code: None,
        }
    }

    pub const fn from_transport(transport: AdapterProviderErrorTransportKind) -> Self {
        Self {
            status_code: None,
            transport: Some(transport),
            retry_after_ms: None,
            owner: None,
            stage: None,
            code: None,
        }
    }

    pub const fn with_retry_after_ms(mut self, retry_after_ms: u64) -> Self {
        self.retry_after_ms = Some(retry_after_ms);
        self
    }

    pub fn with_error_metadata(
        mut self,
        owner: impl Into<String>,
        stage: impl Into<String>,
        code: impl Into<String>,
    ) -> Self {
        self.owner = Some(owner.into());
        self.stage = Some(stage.into());
        self.code = Some(code.into());
        self
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderErrorFallbackDecision {
    pub retry_same_channel: bool,
    pub fallback_to_next_channel: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdapterProviderErrorRoutingClassification {
    pub classification: ProviderErrorClassification,
    pub health_impact: HealthImpact,
    pub fallback: ProviderErrorFallbackDecision,
}

pub fn adapter_provider_error_signal(
    input: &AdapterProviderErrorRoutingInput,
) -> ProviderErrorSignal {
    ProviderErrorSignal {
        status_code: input.status_code,
        transport: input
            .transport
            .or_else(|| adapter_transport_from_metadata(input))
            .map(ProviderTransportErrorKind::from),
        stream: None,
        retry_after_ms: input.retry_after_ms,
    }
}

pub fn classify_adapter_provider_error(
    input: &AdapterProviderErrorRoutingInput,
) -> AdapterProviderErrorRoutingClassification {
    let signal = adapter_provider_error_signal(input);
    let classification =
        classify_adapter_error_metadata(input).unwrap_or_else(|| classify_provider_error(&signal));
    let health_impact = classification.health_impact;
    let fallback = ProviderErrorFallbackDecision {
        retry_same_channel: classification.retryable_same_channel,
        fallback_to_next_channel: classification.can_fallback,
    };

    AdapterProviderErrorRoutingClassification {
        classification,
        health_impact,
        fallback,
    }
}

impl From<AdapterProviderErrorTransportKind> for ProviderTransportErrorKind {
    fn from(transport: AdapterProviderErrorTransportKind) -> Self {
        match transport {
            AdapterProviderErrorTransportKind::Timeout => Self::Timeout,
            AdapterProviderErrorTransportKind::Connect => Self::Connect,
            AdapterProviderErrorTransportKind::Body => Self::Body,
            AdapterProviderErrorTransportKind::Other => Self::Other,
        }
    }
}

pub fn classify_provider_error(signal: &ProviderErrorSignal) -> ProviderErrorClassification {
    if let Some(stream) = signal.stream {
        return classify_stream_error(signal, stream);
    }

    if let Some(transport) = signal.transport {
        return classify_transport_error(signal, transport);
    }

    if let Some(status_code) = signal.status_code {
        return classify_status_code(signal, status_code);
    }

    ProviderErrorClassification {
        kind: ProviderErrorKind::Unknown,
        retryable_same_channel: false,
        can_fallback: true,
        health_impact: HealthImpact::Degrade,
        status_code: None,
        retry_after_ms: signal.retry_after_ms,
        reason_code: "provider_error_unknown".to_owned(),
    }
}

fn classify_adapter_error_metadata(
    input: &AdapterProviderErrorRoutingInput,
) -> Option<ProviderErrorClassification> {
    let owner = input.owner.as_deref().unwrap_or_default();
    let stage = input.stage.as_deref().unwrap_or_default();
    let code = input.code.as_deref().unwrap_or_default();

    if is_quota_like_code(code) {
        return Some(ProviderErrorClassification {
            kind: ProviderErrorKind::RateLimited,
            retryable_same_channel: false,
            can_fallback: true,
            health_impact: HealthImpact::Cooldown,
            status_code: input.status_code,
            retry_after_ms: input.retry_after_ms,
            reason_code: quota_reason_code(input.status_code, code).to_owned(),
        });
    }

    if is_auth_code(code) {
        return Some(ProviderErrorClassification {
            kind: ProviderErrorKind::Authentication,
            retryable_same_channel: false,
            can_fallback: true,
            health_impact: HealthImpact::MarkAuthFailed,
            status_code: input.status_code,
            retry_after_ms: input.retry_after_ms,
            reason_code: "provider_auth_failed".to_owned(),
        });
    }

    if is_client_request_metadata(owner, stage, code) {
        return Some(ProviderErrorClassification {
            kind: ProviderErrorKind::ClientRequest,
            retryable_same_channel: false,
            can_fallback: false,
            health_impact: HealthImpact::None,
            status_code: input.status_code,
            retry_after_ms: input.retry_after_ms,
            reason_code: "adapter_rejected_client_request".to_owned(),
        });
    }

    if is_parser_response_metadata(owner, stage) {
        let reason_code = if normalized_contains(code, "invalid_json") {
            "provider_response_invalid_json"
        } else if normalized_contains(code, "invalid_response") {
            "provider_response_invalid"
        } else {
            "provider_response_parse_error"
        };

        return Some(ProviderErrorClassification {
            kind: ProviderErrorKind::ProviderProtocol,
            retryable_same_channel: true,
            can_fallback: true,
            health_impact: HealthImpact::Degrade,
            status_code: input.status_code,
            retry_after_ms: input.retry_after_ms,
            reason_code: reason_code.to_owned(),
        });
    }

    None
}

fn adapter_transport_from_metadata(
    input: &AdapterProviderErrorRoutingInput,
) -> Option<AdapterProviderErrorTransportKind> {
    let owner = input.owner.as_deref().unwrap_or_default();
    let stage = input.stage.as_deref().unwrap_or_default();
    let code = input.code.as_deref().unwrap_or_default();

    if !owner.eq_ignore_ascii_case("network") || !stage.eq_ignore_ascii_case("provider_call") {
        return None;
    }

    if normalized_contains(code, "timeout") {
        Some(AdapterProviderErrorTransportKind::Timeout)
    } else if normalized_contains(code, "connect") {
        Some(AdapterProviderErrorTransportKind::Connect)
    } else if normalized_contains(code, "body")
        || normalized_contains(code, "read")
        || normalized_contains(code, "response")
    {
        Some(AdapterProviderErrorTransportKind::Body)
    } else if normalized_contains(code, "request") {
        Some(AdapterProviderErrorTransportKind::Other)
    } else {
        None
    }
}

fn is_auth_code(code: &str) -> bool {
    normalized_eq(code, "provider_auth_failed")
        || normalized_contains(code, "invalid_api_key")
        || normalized_contains(code, "invalid_auth")
        || normalized_contains(code, "unauthorized")
}

fn is_quota_like_code(code: &str) -> bool {
    normalized_eq(code, "provider_429")
        || normalized_contains(code, "quota")
        || normalized_contains(code, "rate_limit")
        || normalized_contains(code, "rate-limit")
        || normalized_contains(code, "rate_limited")
        || normalized_contains(code, "resource_exhausted")
        || normalized_contains(code, "too_many_requests")
        || normalized_contains(code, "limit_exceeded")
}

fn quota_reason_code(status_code: Option<u16>, code: &str) -> &'static str {
    if status_code == Some(429)
        || normalized_eq(code, "provider_429")
        || normalized_contains(code, "rate_limit")
        || normalized_contains(code, "rate-limit")
        || normalized_contains(code, "rate_limited")
        || normalized_contains(code, "too_many_requests")
    {
        "provider_rate_limited"
    } else {
        "provider_quota_exhausted"
    }
}

fn is_client_request_metadata(owner: &str, stage: &str, code: &str) -> bool {
    owner.eq_ignore_ascii_case("client")
        || ((stage.eq_ignore_ascii_case("request_parse")
            || stage.eq_ignore_ascii_case("request_validate"))
            && (normalized_contains(code, "invalid_request")
                || normalized_contains(code, "invalid_json")
                || normalized_contains(code, "streaming_unsupported")
                || normalized_contains(code, "streaming_not_implemented")))
}

fn is_parser_response_metadata(owner: &str, stage: &str) -> bool {
    owner.eq_ignore_ascii_case("parser") && stage.eq_ignore_ascii_case("response_transform")
}

fn normalized_eq(actual: &str, expected: &str) -> bool {
    actual.eq_ignore_ascii_case(expected)
}

fn normalized_contains(actual: &str, needle: &str) -> bool {
    actual
        .to_ascii_lowercase()
        .contains(&needle.to_ascii_lowercase())
}

fn classify_stream_error(
    signal: &ProviderErrorSignal,
    stream: ProviderStreamErrorKind,
) -> ProviderErrorClassification {
    let reason_code = match stream {
        ProviderStreamErrorKind::InvalidSse => "provider_stream_invalid_sse",
        ProviderStreamErrorKind::IncompleteEvent => "provider_stream_incomplete_event",
        ProviderStreamErrorKind::UnexpectedEof => "provider_stream_unexpected_eof",
        ProviderStreamErrorKind::DecodeError => "provider_stream_decode_error",
    };

    ProviderErrorClassification {
        kind: ProviderErrorKind::StreamProtocol,
        retryable_same_channel: true,
        can_fallback: true,
        health_impact: HealthImpact::Degrade,
        status_code: signal.status_code,
        retry_after_ms: signal.retry_after_ms,
        reason_code: reason_code.to_owned(),
    }
}

fn classify_transport_error(
    signal: &ProviderErrorSignal,
    transport: ProviderTransportErrorKind,
) -> ProviderErrorClassification {
    let (kind, reason_code) = match transport {
        ProviderTransportErrorKind::Timeout => {
            (ProviderErrorKind::Timeout, "provider_transport_timeout")
        }
        ProviderTransportErrorKind::Connect => {
            (ProviderErrorKind::Transport, "provider_transport_connect")
        }
        ProviderTransportErrorKind::Dns => (ProviderErrorKind::Transport, "provider_transport_dns"),
        ProviderTransportErrorKind::Tls => (ProviderErrorKind::Transport, "provider_transport_tls"),
        ProviderTransportErrorKind::ConnectionClosed => (
            ProviderErrorKind::Transport,
            "provider_transport_connection_closed",
        ),
        ProviderTransportErrorKind::Body => {
            (ProviderErrorKind::Transport, "provider_transport_body")
        }
        ProviderTransportErrorKind::Other => {
            (ProviderErrorKind::Transport, "provider_transport_other")
        }
    };

    ProviderErrorClassification {
        kind,
        retryable_same_channel: true,
        can_fallback: true,
        health_impact: HealthImpact::Degrade,
        status_code: signal.status_code,
        retry_after_ms: signal.retry_after_ms,
        reason_code: reason_code.to_owned(),
    }
}

fn classify_status_code(
    signal: &ProviderErrorSignal,
    status_code: u16,
) -> ProviderErrorClassification {
    match status_code {
        401 | 403 => ProviderErrorClassification {
            kind: ProviderErrorKind::Authentication,
            retryable_same_channel: false,
            can_fallback: true,
            health_impact: HealthImpact::MarkAuthFailed,
            status_code: Some(status_code),
            retry_after_ms: signal.retry_after_ms,
            reason_code: "provider_auth_failed".to_owned(),
        },
        408 => ProviderErrorClassification {
            kind: ProviderErrorKind::Timeout,
            retryable_same_channel: true,
            can_fallback: true,
            health_impact: HealthImpact::Degrade,
            status_code: Some(status_code),
            retry_after_ms: signal.retry_after_ms,
            reason_code: "provider_http_timeout".to_owned(),
        },
        429 => ProviderErrorClassification {
            kind: ProviderErrorKind::RateLimited,
            retryable_same_channel: false,
            can_fallback: true,
            health_impact: HealthImpact::Cooldown,
            status_code: Some(status_code),
            retry_after_ms: signal.retry_after_ms,
            reason_code: "provider_rate_limited".to_owned(),
        },
        400 | 422 => ProviderErrorClassification {
            kind: ProviderErrorKind::ClientRequest,
            retryable_same_channel: false,
            can_fallback: false,
            health_impact: HealthImpact::None,
            status_code: Some(status_code),
            retry_after_ms: signal.retry_after_ms,
            reason_code: "provider_rejected_client_request".to_owned(),
        },
        404 => ProviderErrorClassification {
            kind: ProviderErrorKind::NotFound,
            retryable_same_channel: false,
            can_fallback: true,
            health_impact: HealthImpact::None,
            status_code: Some(status_code),
            retry_after_ms: signal.retry_after_ms,
            reason_code: "provider_model_or_route_not_found".to_owned(),
        },
        502 | 503 | 504 | 529 => ProviderErrorClassification {
            kind: ProviderErrorKind::ProviderOverloaded,
            retryable_same_channel: true,
            can_fallback: true,
            health_impact: HealthImpact::Degrade,
            status_code: Some(status_code),
            retry_after_ms: signal.retry_after_ms,
            reason_code: "provider_overloaded".to_owned(),
        },
        500 | 501 | 505..=599 => ProviderErrorClassification {
            kind: ProviderErrorKind::ProviderServer,
            retryable_same_channel: true,
            can_fallback: true,
            health_impact: HealthImpact::Degrade,
            status_code: Some(status_code),
            retry_after_ms: signal.retry_after_ms,
            reason_code: "provider_server_error".to_owned(),
        },
        402 | 409 | 410 | 423 | 424 | 425 | 426 | 428 | 431 | 451 => ProviderErrorClassification {
            kind: ProviderErrorKind::ClientRequest,
            retryable_same_channel: false,
            can_fallback: false,
            health_impact: HealthImpact::None,
            status_code: Some(status_code),
            retry_after_ms: signal.retry_after_ms,
            reason_code: "provider_client_error".to_owned(),
        },
        405..=499 => ProviderErrorClassification {
            kind: ProviderErrorKind::ClientRequest,
            retryable_same_channel: false,
            can_fallback: false,
            health_impact: HealthImpact::None,
            status_code: Some(status_code),
            retry_after_ms: signal.retry_after_ms,
            reason_code: "provider_client_error".to_owned(),
        },
        _ => ProviderErrorClassification {
            kind: ProviderErrorKind::Unknown,
            retryable_same_channel: false,
            can_fallback: true,
            health_impact: HealthImpact::Degrade,
            status_code: Some(status_code),
            retry_after_ms: signal.retry_after_ms,
            reason_code: "provider_status_unknown".to_owned(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;
    use serde_json::Value;

    #[derive(Debug, Deserialize)]
    struct AdapterBridgeContractFixture {
        cases: Vec<AdapterBridgeContractCase>,
    }

    #[derive(Debug, Deserialize)]
    struct AdapterBridgeContractCase {
        name: String,
        input: AdapterProviderErrorRoutingInput,
        expected: AdapterProviderErrorRoutingClassification,
    }

    #[test]
    fn classifies_auth_failed_as_non_retryable_channel_failure() {
        let classification = classify_provider_error(&ProviderErrorSignal::from_status(401));

        assert_eq!(classification.kind, ProviderErrorKind::Authentication);
        assert!(!classification.retryable_same_channel);
        assert!(classification.can_fallback);
        assert_eq!(classification.health_impact, HealthImpact::MarkAuthFailed);
    }

    #[test]
    fn classifies_rate_limit_as_cooldown_with_retry_after() {
        let signal = ProviderErrorSignal::from_status(429).with_retry_after_ms(1_500);
        let classification = classify_provider_error(&signal);

        assert_eq!(classification.kind, ProviderErrorKind::RateLimited);
        assert!(!classification.retryable_same_channel);
        assert!(classification.can_fallback);
        assert_eq!(classification.health_impact, HealthImpact::Cooldown);
        assert_eq!(classification.retry_after_ms, Some(1_500));
    }

    #[test]
    fn classifies_provider_overload_before_generic_server_error() {
        let overloaded = classify_provider_error(&ProviderErrorSignal::from_status(503));
        let server = classify_provider_error(&ProviderErrorSignal::from_status(500));

        assert_eq!(overloaded.kind, ProviderErrorKind::ProviderOverloaded);
        assert_eq!(server.kind, ProviderErrorKind::ProviderServer);
        assert!(overloaded.retryable_same_channel);
        assert!(server.can_fallback);
    }

    #[test]
    fn classifies_transport_timeout() {
        let classification = classify_provider_error(&ProviderErrorSignal::from_transport(
            ProviderTransportErrorKind::Timeout,
        ));

        assert_eq!(classification.kind, ProviderErrorKind::Timeout);
        assert!(classification.retryable_same_channel);
        assert_eq!(classification.health_impact, HealthImpact::Degrade);
    }

    #[test]
    fn classifies_stream_protocol_error_even_when_status_was_successful() {
        let signal = ProviderErrorSignal {
            status_code: Some(200),
            transport: None,
            stream: Some(ProviderStreamErrorKind::InvalidSse),
            retry_after_ms: None,
        };
        let classification = classify_provider_error(&signal);

        assert_eq!(classification.kind, ProviderErrorKind::StreamProtocol);
        assert_eq!(classification.reason_code, "provider_stream_invalid_sse");
        assert!(classification.can_fallback);
    }

    #[test]
    fn classifies_client_request_error_as_not_fallbackable() {
        let classification = classify_provider_error(&ProviderErrorSignal::from_status(400));

        assert_eq!(classification.kind, ProviderErrorKind::ClientRequest);
        assert!(!classification.retryable_same_channel);
        assert!(!classification.can_fallback);
        assert_eq!(classification.health_impact, HealthImpact::None);
    }

    #[test]
    fn adapter_provider_error_bridge_fixture_contract_is_stable() {
        let fixture: AdapterBridgeContractFixture = serde_json::from_str(include_str!(
            "../../../tests/fixtures/routing/provider_error_adapter_bridge_contract.json"
        ))
        .expect("provider error adapter bridge fixture should be valid");

        for case in fixture.cases {
            let actual = classify_adapter_provider_error(&case.input);
            assert_eq!(actual, case.expected, "case {} should match", case.name);
        }
    }

    #[test]
    fn adapter_provider_error_bridge_derives_network_transport_from_metadata() {
        let input = AdapterProviderErrorRoutingInput::from_status(504).with_error_metadata(
            "network",
            "provider_call",
            "provider_timeout",
        );
        let signal = adapter_provider_error_signal(&input);
        let classification = classify_adapter_provider_error(&input);

        assert_eq!(signal.transport, Some(ProviderTransportErrorKind::Timeout));
        assert_eq!(
            classification.classification.kind,
            ProviderErrorKind::Timeout
        );
        assert_eq!(
            classification.classification.reason_code,
            "provider_transport_timeout"
        );
        assert!(classification.fallback.retry_same_channel);
        assert!(classification.fallback.fallback_to_next_channel);
    }

    #[test]
    fn adapter_provider_error_bridge_output_omits_sensitive_adapter_material() {
        let input = AdapterProviderErrorRoutingInput {
            status_code: Some(500),
            transport: None,
            retry_after_ms: None,
            owner: Some("provider".to_owned()),
            stage: Some("provider_call".to_owned()),
            code: Some("provider_5xx Authorization header provider_secret raw_payload".to_owned()),
        };

        let output = classify_adapter_provider_error(&input);
        let output_json = serde_json::to_string(&output).expect("output should serialize");

        assert_no_adapter_bridge_sensitive_material(&output_json);
    }

    #[test]
    fn adapter_provider_error_bridge_fixture_output_omits_sensitive_material() {
        let fixture: AdapterBridgeContractFixture = serde_json::from_str(include_str!(
            "../../../tests/fixtures/routing/provider_error_adapter_bridge_contract.json"
        ))
        .expect("provider error adapter bridge fixture should be valid");

        for case in fixture.cases {
            let actual = classify_adapter_provider_error(&case.input);
            let output = serde_json::to_value(actual).expect("output should serialize");
            assert_no_adapter_bridge_sensitive_material(&output.to_string());
            assert_no_raw_adapter_fields(&output);
        }
    }

    fn assert_no_adapter_bridge_sensitive_material(output: &str) {
        let normalized = output.to_ascii_lowercase();
        for marker in [
            "authorization",
            "bearer",
            "provider_secret",
            "raw_payload",
            "api_key",
        ] {
            assert!(
                !normalized.contains(marker),
                "output should not contain sensitive marker {marker}: {output}"
            );
        }
    }

    fn assert_no_raw_adapter_fields(output: &Value) {
        let object = output
            .as_object()
            .expect("adapter bridge output should be an object");

        for field in ["owner", "stage", "code", "message", "param", "raw_payload"] {
            assert!(
                !object.contains_key(field),
                "adapter bridge output should not expose raw adapter field {field}"
            );
        }
    }
}
