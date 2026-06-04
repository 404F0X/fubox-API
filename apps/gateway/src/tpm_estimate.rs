use ai_gateway_routing::{
    RateLimitTpmEstimateInput, RateLimitTpmEstimateSource, RateLimitTpmReservationEstimate,
    estimate_tpm_reservation,
};
use serde::Serialize;
use serde_json::Value;

pub(crate) const GATEWAY_TPM_ESTIMATE_MAPPER_SCHEMA: &str = "gateway_tpm_estimate_mapper_v1";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub(crate) enum GatewayTpmEstimateEndpoint {
    OpenAiChat,
    OpenAiResponses,
    OpenAiEmbeddings,
    AnthropicMessages,
    GeminiNative,
}

impl GatewayTpmEstimateEndpoint {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::OpenAiChat => "openai_chat",
            Self::OpenAiResponses => "openai_responses",
            Self::OpenAiEmbeddings => "openai_embeddings",
            Self::AnthropicMessages => "anthropic_messages",
            Self::GeminiNative => "gemini_native",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct GatewayTpmEstimateSignals {
    pub(crate) prompt_tokens: Option<i64>,
    pub(crate) completion_tokens: Option<i64>,
    pub(crate) total_tokens: Option<i64>,
    pub(crate) conservative_fallback_tokens: i64,
}

impl GatewayTpmEstimateSignals {
    pub(crate) const fn new(
        prompt_tokens: Option<i64>,
        completion_tokens: Option<i64>,
        total_tokens: Option<i64>,
        conservative_fallback_tokens: i64,
    ) -> Self {
        Self {
            prompt_tokens,
            completion_tokens,
            total_tokens,
            conservative_fallback_tokens,
        }
    }

    pub(crate) const fn trusted_prompt_tokens(
        prompt_tokens: Option<i64>,
        conservative_fallback_tokens: i64,
    ) -> Self {
        Self {
            prompt_tokens,
            completion_tokens: None,
            total_tokens: None,
            conservative_fallback_tokens,
        }
    }

    pub(crate) const fn trusted_input_tokens(
        input_tokens: Option<i64>,
        conservative_fallback_tokens: i64,
    ) -> Self {
        Self {
            prompt_tokens: None,
            completion_tokens: None,
            total_tokens: input_tokens,
            conservative_fallback_tokens,
        }
    }

    pub(crate) const fn missing_tokenizer(conservative_fallback_tokens: i64) -> Self {
        Self {
            prompt_tokens: None,
            completion_tokens: None,
            total_tokens: None,
            conservative_fallback_tokens,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct GatewayTpmEstimatePlan {
    pub(crate) endpoint: GatewayTpmEstimateEndpoint,
    pub(crate) input: RateLimitTpmEstimateInput,
    pub(crate) estimate: RateLimitTpmReservationEstimate,
}

impl GatewayTpmEstimatePlan {
    pub(crate) fn safe_summary(&self) -> GatewayTpmEstimateSummary {
        GatewayTpmEstimateSummary {
            schema: GATEWAY_TPM_ESTIMATE_MAPPER_SCHEMA,
            endpoint: self.endpoint.as_str(),
            source: self.estimate.source,
            required_tokens: self.estimate.required_tokens,
            required_tokens_i64: self.estimate.required_tokens_i64(),
            prompt_tokens: self.estimate.prompt_tokens,
            completion_tokens: self.estimate.completion_tokens,
            max_completion_tokens: self.estimate.max_completion_tokens,
            completion_reservation_tokens: self.estimate.completion_reservation_tokens,
            fallback_tokens: self.estimate.fallback_tokens,
            used_conservative_fallback: self.estimate.used_conservative_fallback,
            sanitized_negative_estimate: self.estimate.sanitized_negative_estimate,
            clamped_to_i64_max: self.estimate.clamped_to_i64_max,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct GatewayTpmEstimateSummary {
    pub(crate) schema: &'static str,
    pub(crate) endpoint: &'static str,
    pub(crate) source: RateLimitTpmEstimateSource,
    pub(crate) required_tokens: u64,
    pub(crate) required_tokens_i64: i64,
    pub(crate) prompt_tokens: Option<u64>,
    pub(crate) completion_tokens: Option<u64>,
    pub(crate) max_completion_tokens: Option<u64>,
    pub(crate) completion_reservation_tokens: Option<u64>,
    pub(crate) fallback_tokens: u64,
    pub(crate) used_conservative_fallback: bool,
    pub(crate) sanitized_negative_estimate: bool,
    pub(crate) clamped_to_i64_max: bool,
}

pub(crate) fn gateway_tpm_estimate_for_request(
    endpoint: GatewayTpmEstimateEndpoint,
    request_body: &Value,
    signals: GatewayTpmEstimateSignals,
) -> GatewayTpmEstimatePlan {
    let max_completion_tokens = max_completion_tokens_for_endpoint(endpoint, request_body);
    let input = RateLimitTpmEstimateInput::new(
        signals.prompt_tokens,
        signals.completion_tokens,
        max_completion_tokens,
        signals.total_tokens,
        signals.conservative_fallback_tokens,
    );
    let estimate = estimate_tpm_reservation(input);

    GatewayTpmEstimatePlan {
        endpoint,
        input,
        estimate,
    }
}

pub(crate) fn gateway_tpm_estimate_for_request_body(
    endpoint: GatewayTpmEstimateEndpoint,
    request_body: &[u8],
    signals: GatewayTpmEstimateSignals,
) -> GatewayTpmEstimatePlan {
    let request_body = serde_json::from_slice::<Value>(request_body).unwrap_or(Value::Null);
    gateway_tpm_estimate_for_request(endpoint, &request_body, signals)
}

fn max_completion_tokens_for_endpoint(
    endpoint: GatewayTpmEstimateEndpoint,
    request_body: &Value,
) -> Option<i64> {
    match endpoint {
        GatewayTpmEstimateEndpoint::OpenAiChat => {
            first_present_integer_field(request_body, &["max_completion_tokens", "max_tokens"])
        }
        GatewayTpmEstimateEndpoint::OpenAiResponses => {
            first_present_integer_field(request_body, &["max_output_tokens"])
        }
        GatewayTpmEstimateEndpoint::OpenAiEmbeddings => None,
        GatewayTpmEstimateEndpoint::AnthropicMessages => {
            first_present_integer_field(request_body, &["max_tokens"])
        }
        GatewayTpmEstimateEndpoint::GeminiNative => request_body
            .get("generationConfig")
            .and_then(|config| first_present_integer_field(config, &["maxOutputTokens"])),
    }
}

fn first_present_integer_field(request_body: &Value, field_names: &[&str]) -> Option<i64> {
    for field_name in field_names {
        let Some(value) = request_body.get(*field_name) else {
            continue;
        };

        return json_integer_to_i64_saturating(value);
    }

    None
}

fn json_integer_to_i64_saturating(value: &Value) -> Option<i64> {
    let number = value.as_number()?;
    if let Some(value) = number.as_i64() {
        return Some(value);
    }

    number
        .as_u64()
        .map(|value| value.min(i64::MAX as u64) as i64)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn fixture() -> serde_json::Value {
        serde_json::from_str(include_str!(
            "../../../tests/fixtures/gateway/rate_limit_tpm_estimate_mapper_contract.json"
        ))
        .expect("gateway TPM estimate mapper fixture should be valid json")
    }

    fn signals(prompt_tokens: Option<i64>, fallback_tokens: i64) -> GatewayTpmEstimateSignals {
        GatewayTpmEstimateSignals::new(prompt_tokens, None, None, fallback_tokens)
    }

    #[test]
    fn tpm_estimate_mapper_accepts_only_trusted_numeric_token_signals() {
        let prompt = gateway_tpm_estimate_for_request(
            GatewayTpmEstimateEndpoint::OpenAiChat,
            &json!({
                "messages": [{ "content": "sk-live-provider-secret raw prompt" }],
                "max_completion_tokens": 400
            }),
            GatewayTpmEstimateSignals::trusted_prompt_tokens(Some(200), 256),
        );
        assert_eq!(
            prompt.estimate.source,
            RateLimitTpmEstimateSource::PromptAndMaxCompletion
        );
        assert_eq!(prompt.estimate.prompt_tokens, Some(200));
        assert_eq!(prompt.estimate.max_completion_tokens, Some(400));
        assert_eq!(prompt.estimate.required_tokens, 600);
        assert!(!prompt.estimate.used_conservative_fallback);

        let input = gateway_tpm_estimate_for_request(
            GatewayTpmEstimateEndpoint::OpenAiEmbeddings,
            &json!({ "input": "sk-live-provider-secret raw embedding input" }),
            GatewayTpmEstimateSignals::trusted_input_tokens(Some(222), 256),
        );
        assert_eq!(
            input.estimate.source,
            RateLimitTpmEstimateSource::TotalTokens
        );
        assert_eq!(input.estimate.required_tokens, 222);
        assert_eq!(input.estimate.required_tokens_i64(), 222);
        assert!(!input.estimate.used_conservative_fallback);

        let missing = gateway_tpm_estimate_for_request(
            GatewayTpmEstimateEndpoint::OpenAiEmbeddings,
            &json!({ "input": ["raw one", "raw two"] }),
            GatewayTpmEstimateSignals::trusted_input_tokens(None, 256),
        );
        assert_eq!(
            missing.estimate.source,
            RateLimitTpmEstimateSource::ConservativeFallback
        );
        assert_eq!(missing.estimate.required_tokens, 256);
        assert!(missing.estimate.used_conservative_fallback);

        let negative = gateway_tpm_estimate_for_request(
            GatewayTpmEstimateEndpoint::OpenAiEmbeddings,
            &json!({ "input": "raw negative input" }),
            GatewayTpmEstimateSignals::trusted_input_tokens(Some(-7), 256),
        );
        assert_eq!(
            negative.estimate.source,
            RateLimitTpmEstimateSource::ConservativeFallback
        );
        assert_eq!(negative.estimate.required_tokens, 256);
        assert!(negative.estimate.sanitized_negative_estimate);
        assert!(negative.estimate.used_conservative_fallback);

        let overflow = gateway_tpm_estimate_for_request(
            GatewayTpmEstimateEndpoint::OpenAiChat,
            &json!({ "max_completion_tokens": 256 }),
            GatewayTpmEstimateSignals::trusted_prompt_tokens(Some(i64::MAX), 256),
        );
        assert_eq!(
            overflow.estimate.source,
            RateLimitTpmEstimateSource::PromptAndMaxCompletion
        );
        assert!(overflow.estimate.required_tokens > i64::MAX as u64);
        assert_eq!(overflow.estimate.required_tokens_i64(), i64::MAX);
        assert!(overflow.estimate.clamped_to_i64_max);

        let invalid_fallback = gateway_tpm_estimate_for_request(
            GatewayTpmEstimateEndpoint::OpenAiEmbeddings,
            &json!({ "input": "raw fallback input" }),
            GatewayTpmEstimateSignals::trusted_input_tokens(None, -1),
        );
        assert_eq!(
            invalid_fallback.estimate.source,
            RateLimitTpmEstimateSource::ConservativeFallback
        );
        assert_eq!(invalid_fallback.estimate.required_tokens, 1_024);
        assert!(invalid_fallback.estimate.sanitized_negative_estimate);
        assert!(invalid_fallback.estimate.used_conservative_fallback);

        let serialized = serde_json::to_string(&vec![
            prompt.safe_summary(),
            input.safe_summary(),
            missing.safe_summary(),
            negative.safe_summary(),
            overflow.safe_summary(),
            invalid_fallback.safe_summary(),
        ])
        .expect("trusted token summaries should serialize")
        .to_ascii_lowercase();
        for forbidden in [
            "sk-live-provider-secret",
            "raw prompt",
            "raw embedding input",
            "raw one",
            "raw two",
            "raw negative input",
            "raw fallback input",
            "\"input\"",
            "\"messages\"",
            "\"content\"",
        ] {
            assert!(
                !serialized.contains(forbidden),
                "trusted token TPM summary leaked forbidden marker: {forbidden}"
            );
        }
    }

    #[test]
    fn tpm_estimate_mapper_maps_endpoint_max_output_signals() {
        let cases = [
            (
                "openai_chat_max_completion_tokens",
                GatewayTpmEstimateEndpoint::OpenAiChat,
                json!({ "max_completion_tokens": 400, "max_tokens": 64 }),
                signals(Some(200), 256),
                Some(400),
                RateLimitTpmEstimateSource::PromptAndMaxCompletion,
                600,
            ),
            (
                "openai_chat_legacy_max_tokens",
                GatewayTpmEstimateEndpoint::OpenAiChat,
                json!({ "max_tokens": 64 }),
                signals(Some(200), 256),
                Some(64),
                RateLimitTpmEstimateSource::PromptAndMaxCompletion,
                264,
            ),
            (
                "openai_responses_max_output_tokens",
                GatewayTpmEstimateEndpoint::OpenAiResponses,
                json!({ "max_output_tokens": 300 }),
                signals(Some(120), 256),
                Some(300),
                RateLimitTpmEstimateSource::PromptAndMaxCompletion,
                420,
            ),
            (
                "anthropic_messages_max_tokens",
                GatewayTpmEstimateEndpoint::AnthropicMessages,
                json!({ "max_tokens": 512 }),
                signals(Some(300), 256),
                Some(512),
                RateLimitTpmEstimateSource::PromptAndMaxCompletion,
                812,
            ),
            (
                "gemini_native_max_output_tokens",
                GatewayTpmEstimateEndpoint::GeminiNative,
                json!({ "generationConfig": { "maxOutputTokens": 256 } }),
                signals(Some(90), 256),
                Some(256),
                RateLimitTpmEstimateSource::PromptAndMaxCompletion,
                346,
            ),
        ];

        for (
            name,
            endpoint,
            body,
            signals,
            expected_max_completion,
            expected_source,
            expected_required_tokens,
        ) in cases
        {
            let plan = gateway_tpm_estimate_for_request(endpoint, &body, signals);
            let summary = plan.safe_summary();

            assert_eq!(
                plan.input.max_completion_tokens, expected_max_completion,
                "{name}"
            );
            assert_eq!(summary.source, expected_source, "{name}");
            assert_eq!(summary.required_tokens, expected_required_tokens, "{name}");
            assert_eq!(
                summary.required_tokens_i64, expected_required_tokens as i64,
                "{name}"
            );
            assert!(!summary.used_conservative_fallback, "{name}");
            assert!(!summary.sanitized_negative_estimate, "{name}");
        }
    }

    #[test]
    fn tpm_estimate_mapper_handles_missing_partial_negative_large_and_zero_signals() {
        let missing = gateway_tpm_estimate_for_request(
            GatewayTpmEstimateEndpoint::OpenAiChat,
            &json!({}),
            GatewayTpmEstimateSignals::missing_tokenizer(256),
        );
        assert_eq!(missing.input.max_completion_tokens, None);
        assert_eq!(
            missing.estimate.source,
            RateLimitTpmEstimateSource::ConservativeFallback
        );
        assert_eq!(missing.estimate.required_tokens, 256);
        assert!(missing.estimate.used_conservative_fallback);

        let partial = gateway_tpm_estimate_for_request(
            GatewayTpmEstimateEndpoint::OpenAiResponses,
            &json!({ "max_output_tokens": 128 }),
            GatewayTpmEstimateSignals::missing_tokenizer(256),
        );
        assert_eq!(partial.input.max_completion_tokens, Some(128));
        assert_eq!(
            partial.estimate.source,
            RateLimitTpmEstimateSource::PartialEstimateWithConservativeFallback
        );
        assert_eq!(partial.estimate.required_tokens, 384);
        assert!(partial.estimate.used_conservative_fallback);

        let embeddings = gateway_tpm_estimate_for_request(
            GatewayTpmEstimateEndpoint::OpenAiEmbeddings,
            &json!({ "input": "sk-live-provider-secret raw embedding input" }),
            GatewayTpmEstimateSignals::missing_tokenizer(256),
        );
        assert_eq!(embeddings.input.max_completion_tokens, None);
        assert_eq!(
            embeddings.estimate.source,
            RateLimitTpmEstimateSource::ConservativeFallback
        );
        assert_eq!(embeddings.estimate.required_tokens, 256);
        assert!(embeddings.estimate.used_conservative_fallback);
        let embeddings_summary = serde_json::to_string(&embeddings.safe_summary())
            .expect("embeddings summary should serialize");
        assert!(!embeddings_summary.contains("sk-live-provider-secret"));
        assert!(!embeddings_summary.contains("raw embedding input"));
        assert!(!embeddings_summary.contains("input"));

        let negative = gateway_tpm_estimate_for_request(
            GatewayTpmEstimateEndpoint::AnthropicMessages,
            &json!({ "max_tokens": -5 }),
            signals(Some(100), 300),
        );
        assert_eq!(negative.input.max_completion_tokens, Some(-5));
        assert_eq!(
            negative.estimate.source,
            RateLimitTpmEstimateSource::PartialEstimateWithConservativeFallback
        );
        assert_eq!(negative.estimate.required_tokens, 400);
        assert!(negative.estimate.used_conservative_fallback);
        assert!(negative.estimate.sanitized_negative_estimate);

        let large = gateway_tpm_estimate_for_request(
            GatewayTpmEstimateEndpoint::GeminiNative,
            &json!({
                "generationConfig": {
                    "maxOutputTokens": (i64::MAX as u64).saturating_add(7)
                }
            }),
            signals(Some(1), 256),
        );
        assert_eq!(large.input.max_completion_tokens, Some(i64::MAX));
        assert!(large.estimate.required_tokens > i64::MAX as u64);
        assert_eq!(large.estimate.required_tokens_i64(), i64::MAX);
        assert!(large.estimate.clamped_to_i64_max);

        let zero = gateway_tpm_estimate_for_request(
            GatewayTpmEstimateEndpoint::OpenAiChat,
            &json!({ "max_completion_tokens": 0 }),
            signals(Some(0), 256),
        );
        assert_eq!(zero.input.max_completion_tokens, Some(0));
        assert_eq!(zero.estimate.required_tokens, 1);
        assert_eq!(zero.estimate.required_tokens_i64(), 1);
        assert!(!zero.estimate.used_conservative_fallback);
    }

    #[test]
    fn tpm_estimate_mapper_fixture_and_safe_summary_are_secret_safe() {
        let fixture = fixture();
        assert_eq!(fixture["scenario"], "gateway_tpm_estimate_mapper_contract");
        assert_eq!(fixture["schema"], GATEWAY_TPM_ESTIMATE_MAPPER_SCHEMA);

        let plan = gateway_tpm_estimate_for_request_body(
            GatewayTpmEstimateEndpoint::OpenAiChat,
            br#"{
                "messages": [{ "content": "sk-live-provider-secret" }],
                "max_completion_tokens": 128
            }"#,
            signals(Some(64), 256),
        );
        let serialized = serde_json::to_string(&plan.safe_summary())
            .expect("TPM estimate summary should serialize")
            .to_ascii_lowercase();

        assert!(serialized.contains("gateway_tpm_estimate_mapper_v1"));
        assert!(!serialized.contains("messages"));
        for forbidden in fixture["forbidden_output_markers"]
            .as_array()
            .expect("forbidden markers should be an array")
            .iter()
            .filter_map(serde_json::Value::as_str)
        {
            assert!(
                !serialized.contains(forbidden),
                "TPM estimate mapper summary leaked forbidden marker: {forbidden}"
            );
        }
    }

    #[test]
    fn tpm_estimate_mapper_does_not_reference_provider_side_effects() {
        let source = include_str!("tpm_estimate.rs");
        for forbidden in [
            concat!("execute_provider_key_rate_limit_", "reservation"),
            concat!("create_provider_attempt_", "started"),
            concat!("open_provider_key_", "for_route"),
            concat!("with_provider_", "key("),
            concat!("send_anthropic_messages_", "request("),
            concat!("send_gemini_generate_content_", "request("),
        ] {
            assert!(
                !source.contains(forbidden),
                "TPM estimate mapper must remain DB-free and provider-side-effect-free: {forbidden}"
            );
        }
    }
}
