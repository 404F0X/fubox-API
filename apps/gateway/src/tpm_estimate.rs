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
    fn tpm_estimate_mapper_fixture_defines_runtime_trusted_signal_wiring_checklist() {
        let fixture = fixture();
        let guard = &fixture["runtime_source_guard"];
        let endpoints = guard["endpoints"]
            .as_array()
            .expect("runtime source guard endpoints should be an array");
        let checklist = fixture["trusted_signal_runtime_wiring_checklist"]
            .as_array()
            .expect("trusted signal runtime wiring checklist should be an array");
        let current_signal = guard["current_runtime_signal"]
            .as_str()
            .expect("runtime source guard should define current signal");

        assert_eq!(checklist.len(), endpoints.len());

        for endpoint in endpoints.iter().filter_map(serde_json::Value::as_str) {
            let entry = checklist
                .iter()
                .find(|entry| entry["endpoint"].as_str() == Some(endpoint))
                .unwrap_or_else(|| panic!("missing trusted signal checklist endpoint: {endpoint}"));
            let allowed_sources = entry["allowed_trusted_sources"]
                .as_array()
                .expect("allowed trusted sources should be an array");
            let forbidden_sources = entry["forbidden_sources"]
                .as_array()
                .expect("forbidden sources should be an array");
            let exit_condition = entry["future_wiring_exit_condition"]
                .as_str()
                .expect("future wiring exit condition should be a string")
                .to_ascii_lowercase();

            assert_eq!(
                entry["current_runtime_signal"].as_str(),
                Some(current_signal)
            );
            assert_eq!(
                entry["current_missing_tokenizer_status"].as_bool(),
                Some(true)
            );
            assert_eq!(entry["raw_material_accepted"].as_bool(), Some(false));
            assert_eq!(entry["raw_material_emitted"].as_bool(), Some(false));
            assert_eq!(
                entry["provider_side_effect_required"].as_bool(),
                Some(false)
            );
            assert!(!allowed_sources.is_empty());
            for source in allowed_sources.iter().filter_map(serde_json::Value::as_str) {
                let source = source.to_ascii_lowercase();
                assert!(source.contains("trusted numeric"));
                assert!(!source.contains(" raw "));
                assert!(!source.contains("provider key"));
            }
            assert!(exit_condition.contains("trusted numeric"));
            assert!(exit_condition.contains("before reservation"));
            assert!(exit_condition.contains("without provider side effects"));

            for required_forbidden in [
                ".len()",
                ".chars()",
                ".bytes()",
                "split_whitespace",
                ".tokenize(",
                "tokenize_raw",
                "token_count",
                "header_material",
            ] {
                assert!(
                    forbidden_sources
                        .iter()
                        .any(|source| source.as_str() == Some(required_forbidden)),
                    "{endpoint} checklist should forbid {required_forbidden}"
                );
            }
        }

        let checklist_text = serde_json::to_string(checklist)
            .expect("trusted signal checklist should serialize")
            .to_ascii_lowercase();
        for forbidden in [
            "sk-live",
            "authorization",
            "bearer",
            "provider_key",
            "provider key",
            "api_key",
            "encrypted_secret",
            "payload",
            "request_body",
            "current_window_state",
        ] {
            assert!(
                !checklist_text.contains(forbidden),
                "trusted signal checklist leaked forbidden marker: {forbidden}"
            );
        }
    }

    #[test]
    fn tpm_estimate_mapper_fixture_defines_smoke_handoff_contract() {
        let fixture = fixture();
        let guard = &fixture["runtime_source_guard"];
        let guarded_endpoints = guard["endpoints"]
            .as_array()
            .expect("runtime source guard endpoints should be an array");
        let handoff = &fixture["trusted_signal_smoke_handoff_contract"];

        assert_eq!(
            handoff["schema"].as_str(),
            Some("gateway_tpm_trusted_signal_smoke_handoff_v1")
        );
        assert_eq!(
            handoff["current_default_status"].as_str(),
            Some("fallback_missing_tokenizer")
        );
        assert_eq!(
            handoff["evidence_material"].as_str(),
            Some("numeric/status/source fields only")
        );

        let common_required = handoff["common_required_evidence_fields"]
            .as_array()
            .expect("common required evidence fields should be an array");
        let common_forbidden = handoff["common_forbidden_evidence_fields"]
            .as_array()
            .expect("common forbidden evidence fields should be an array");
        let common_closure = handoff["common_live_smoke_closure_conditions"]
            .as_array()
            .expect("common live smoke closure conditions should be an array");
        let endpoint_handoffs = handoff["endpoints"]
            .as_array()
            .expect("handoff endpoints should be an array");

        assert_eq!(endpoint_handoffs.len(), guarded_endpoints.len());
        for required in [
            "endpoint",
            "handoff_status",
            "tpm_estimate.source",
            "tpm_estimate.required_tokens_i64",
            "required_capacity.tokens_per_minute",
            "acquire.dimensions.tpm.required",
            "db_required_capacity.tokens_per_minute",
            "trusted_signal.status",
            "trusted_signal.source_type",
            "trusted_signal.tokens",
            "trusted_signal.material_in_output",
        ] {
            assert!(
                common_required
                    .iter()
                    .any(|field| field.as_str() == Some(required)),
                "handoff common evidence should require {required}"
            );
        }
        for forbidden in [
            "raw_prompt",
            "raw_input",
            "request_body",
            "raw_headers",
            "authorization",
            "provider_key",
            "api_key",
            "current_window_state",
        ] {
            assert!(
                common_forbidden
                    .iter()
                    .any(|field| field.as_str() == Some(forbidden)),
                "handoff common evidence should forbid {forbidden}"
            );
        }
        for condition in [
            "trusted_signal.status is wired",
            "trusted_signal.tokens is a bounded non-negative integer",
            "trusted_signal.source_type is tokenizer or read_model",
            "trusted_signal.material_in_output is false",
            "required_capacity.tokens_per_minute equals tpm_estimate.required_tokens_i64",
            "db_required_capacity.tokens_per_minute equals required_capacity.tokens_per_minute",
        ] {
            assert!(
                common_closure
                    .iter()
                    .any(|field| field.as_str() == Some(condition)),
                "handoff common closure should require {condition}"
            );
        }

        for endpoint in guarded_endpoints
            .iter()
            .filter_map(serde_json::Value::as_str)
        {
            let entry = endpoint_handoffs
                .iter()
                .find(|entry| entry["endpoint"].as_str() == Some(endpoint))
                .unwrap_or_else(|| panic!("missing smoke handoff endpoint: {endpoint}"));
            let allowed_source_types = entry["allowed_source_types"]
                .as_array()
                .expect("allowed source types should be an array");
            let required_fields = entry["required_evidence_fields"]
                .as_array()
                .expect("required evidence fields should be an array");
            let forbidden_fields = entry["forbidden_evidence_fields"]
                .as_array()
                .expect("forbidden evidence fields should be an array");
            let closure_conditions = entry["live_smoke_closure_conditions"]
                .as_array()
                .expect("closure conditions should be an array");

            assert_eq!(
                entry["handoff_status"].as_str(),
                Some("fallback_missing_tokenizer")
            );
            assert_eq!(
                entry["current_missing_tokenizer_status"].as_bool(),
                Some(true)
            );
            assert!(
                allowed_source_types
                    .iter()
                    .any(|source| source.as_str() == Some("tokenizer"))
            );
            assert!(
                allowed_source_types
                    .iter()
                    .any(|source| source.as_str() == Some("read_model"))
            );
            assert!(!required_fields.is_empty());
            assert!(!forbidden_fields.is_empty());
            assert!(!closure_conditions.is_empty());
            assert!(
                required_fields.iter().any(|field| field
                    .as_str()
                    .is_some_and(|field| field.starts_with("trusted_signal."))),
                "{endpoint} handoff must include trusted signal evidence"
            );
            assert!(
                closure_conditions.iter().any(|condition| {
                    condition
                        .as_str()
                        .is_some_and(|condition| condition.contains("before reservation acquire"))
                }),
                "{endpoint} handoff must close only when evidence is available before reservation acquire"
            );
            assert!(
                forbidden_fields.iter().any(|field| {
                    field.as_str().is_some_and(|field| {
                        field.starts_with("raw_")
                            || field.ends_with("_text")
                            || field == "raw_headers"
                    })
                }),
                "{endpoint} handoff must forbid raw material evidence"
            );
        }

        let handoff_text = serde_json::to_string(handoff)
            .expect("smoke handoff contract should serialize")
            .to_ascii_lowercase();
        for forbidden in [
            "sk-live",
            "bearer ",
            "provider-secret",
            "encrypted_secret_value",
            "raw prompt text",
            "raw input text",
            "https://provider.example.test",
        ] {
            assert!(
                !handoff_text.contains(forbidden),
                "smoke handoff contract leaked forbidden marker: {forbidden}"
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
