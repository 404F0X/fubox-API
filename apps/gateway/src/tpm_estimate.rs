use ai_gateway_routing::{
    RateLimitTpmEstimateInput, RateLimitTpmEstimateSource, RateLimitTpmReservationEstimate,
    estimate_tpm_reservation,
};
use serde::Serialize;
use serde_json::Value;

pub(crate) const GATEWAY_TPM_ESTIMATE_MAPPER_SCHEMA: &str = "gateway_tpm_estimate_mapper_v1";
pub(crate) const GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_AVAILABILITY_SCHEMA: &str =
    "gateway_tpm_trusted_numeric_source_availability_v1";
pub(crate) const GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_READINESS_SCHEMA: &str =
    "gateway_tpm_trusted_numeric_source_readiness_v1";
pub(crate) const GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_CONFIG_PREFLIGHT_SCHEMA: &str =
    "gateway_tpm_trusted_numeric_source_config_preflight_v1";
pub(crate) const GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_RUNTIME_ADAPTER_SCHEMA: &str =
    "gateway_tpm_trusted_numeric_source_runtime_adapter_boundary_v1";
pub(crate) const GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_OPT_IN_EVIDENCE_SCHEMA: &str =
    "gateway_tpm_trusted_numeric_source_opt_in_evidence_v1";
pub(crate) const GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_RESERVATION_PROJECTION_SCHEMA: &str =
    "gateway_tpm_trusted_numeric_source_reservation_projection_v1";
pub(crate) const GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_AVAILABILITY_MARKER: &str =
    "gateway_tpm_trusted_numeric_source_available";
pub(crate) const GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_PREFLIGHT_DURATION_MARKER: &str =
    "gateway_tpm_trusted_numeric_source_preflight_duration_ms";
pub(crate) const GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_ESTIMATE_DURATION_MARKER: &str =
    "gateway_tpm_trusted_numeric_source_estimate_duration_ms";
pub(crate) const GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_TYPE_MARKER: &str =
    "gateway_tpm_trusted_numeric_source_type";
pub(crate) const GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_TOKEN_COUNT_MARKER: &str =
    "gateway_tpm_trusted_numeric_source_token_count";

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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum GatewayTrustedNumericSourceType {
    Tokenizer,
    ReadModel,
}

impl GatewayTrustedNumericSourceType {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Tokenizer => "tokenizer",
            Self::ReadModel => "read_model",
        }
    }

    pub(crate) fn from_str(source_type: &str) -> Option<Self> {
        match source_type {
            "tokenizer" => Some(Self::Tokenizer),
            "read_model" => Some(Self::ReadModel),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum GatewayTrustedNumericTokenKind {
    PromptTokens,
    InputTokens,
}

impl GatewayTrustedNumericTokenKind {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::PromptTokens => "prompt_tokens",
            Self::InputTokens => "input_tokens",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct GatewayTrustedNumericSourceCandidate<'a> {
    pub(crate) source_type: &'a str,
    pub(crate) token_kind: GatewayTrustedNumericTokenKind,
    pub(crate) tokens: Option<i64>,
}

impl<'a> GatewayTrustedNumericSourceCandidate<'a> {
    pub(crate) const fn new(
        source_type: &'a str,
        token_kind: GatewayTrustedNumericTokenKind,
        tokens: Option<i64>,
    ) -> Self {
        Self {
            source_type,
            token_kind,
            tokens,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct GatewayTrustedNumericSourceAdapterOutput {
    pub(crate) source_type: GatewayTrustedNumericSourceType,
    pub(crate) token_kind: GatewayTrustedNumericTokenKind,
    pub(crate) tokens: Option<i64>,
}

impl GatewayTrustedNumericSourceAdapterOutput {
    pub(crate) const fn new(
        source_type: GatewayTrustedNumericSourceType,
        token_kind: GatewayTrustedNumericTokenKind,
        tokens: Option<i64>,
    ) -> Self {
        Self {
            source_type,
            token_kind,
            tokens,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct GatewayTrustedNumericSourceReadinessInput {
    pub(crate) tokenizer_enabled: bool,
    pub(crate) tokenizer_available: bool,
    pub(crate) read_model_enabled: bool,
    pub(crate) read_model_available: bool,
}

impl GatewayTrustedNumericSourceReadinessInput {
    pub(crate) const fn new(
        tokenizer_enabled: bool,
        tokenizer_available: bool,
        read_model_enabled: bool,
        read_model_available: bool,
    ) -> Self {
        Self {
            tokenizer_enabled,
            tokenizer_available,
            read_model_enabled,
            read_model_available,
        }
    }

    pub(crate) const fn disabled_by_default() -> Self {
        Self {
            tokenizer_enabled: false,
            tokenizer_available: false,
            read_model_enabled: false,
            read_model_available: false,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct GatewayTrustedNumericSourceConfigPreflightInput {
    pub(crate) tokenizer_config_enabled: bool,
    pub(crate) tokenizer_provider_available: bool,
    pub(crate) read_model_config_enabled: bool,
    pub(crate) read_model_provider_available: bool,
}

impl GatewayTrustedNumericSourceConfigPreflightInput {
    pub(crate) const fn new(
        tokenizer_config_enabled: bool,
        tokenizer_provider_available: bool,
        read_model_config_enabled: bool,
        read_model_provider_available: bool,
    ) -> Self {
        Self {
            tokenizer_config_enabled,
            tokenizer_provider_available,
            read_model_config_enabled,
            read_model_provider_available,
        }
    }

    pub(crate) const fn disabled_by_default() -> Self {
        Self {
            tokenizer_config_enabled: false,
            tokenizer_provider_available: false,
            read_model_config_enabled: false,
            read_model_provider_available: false,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum GatewayTrustedNumericSourceReadinessStatus {
    Unavailable,
    Available,
}

impl GatewayTrustedNumericSourceReadinessStatus {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Unavailable => "unavailable",
            Self::Available => "available",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum GatewayTrustedNumericSourceConfigPreflightStatus {
    Disabled,
    Blocked,
    Ready,
}

impl GatewayTrustedNumericSourceConfigPreflightStatus {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Disabled => "disabled",
            Self::Blocked => "blocked",
            Self::Ready => "ready",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum GatewayTrustedNumericSourceConfigPreflightBlocker {
    ConfigDisabled,
    ProviderUnavailable,
}

impl GatewayTrustedNumericSourceConfigPreflightBlocker {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::ConfigDisabled => "config_disabled",
            Self::ProviderUnavailable => "provider_unavailable",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum GatewayTrustedNumericSourceProviderReadinessStatus {
    Disabled,
    Unavailable,
    Available,
}

impl GatewayTrustedNumericSourceProviderReadinessStatus {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Disabled => "disabled",
            Self::Unavailable => "unavailable",
            Self::Available => "available",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct GatewayTrustedNumericSourceReadiness {
    pub(crate) status: GatewayTrustedNumericSourceReadinessStatus,
    pub(crate) tokenizer_status: GatewayTrustedNumericSourceProviderReadinessStatus,
    pub(crate) read_model_status: GatewayTrustedNumericSourceProviderReadinessStatus,
    pub(crate) tokenizer_enabled: bool,
    pub(crate) read_model_enabled: bool,
    pub(crate) feature_available: bool,
    pub(crate) fallback_required: bool,
    pub(crate) material_in_output: bool,
}

impl GatewayTrustedNumericSourceReadiness {
    pub(crate) fn safe_summary(&self) -> GatewayTrustedNumericSourceReadinessSummary {
        GatewayTrustedNumericSourceReadinessSummary {
            schema: GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_READINESS_SCHEMA,
            status: self.status.as_str(),
            tokenizer_status: self.tokenizer_status.as_str(),
            read_model_status: self.read_model_status.as_str(),
            tokenizer_enabled: self.tokenizer_enabled,
            read_model_enabled: self.read_model_enabled,
            feature_available: self.feature_available,
            fallback_required: self.fallback_required,
            material_in_output: self.material_in_output,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct GatewayTrustedNumericSourceReadinessSummary {
    pub(crate) schema: &'static str,
    pub(crate) status: &'static str,
    pub(crate) tokenizer_status: &'static str,
    pub(crate) read_model_status: &'static str,
    pub(crate) tokenizer_enabled: bool,
    pub(crate) read_model_enabled: bool,
    pub(crate) feature_available: bool,
    pub(crate) fallback_required: bool,
    pub(crate) material_in_output: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct GatewayTrustedNumericSourceConfigPreflight {
    pub(crate) status: GatewayTrustedNumericSourceConfigPreflightStatus,
    pub(crate) blocker: Option<GatewayTrustedNumericSourceConfigPreflightBlocker>,
    pub(crate) tokenizer_config_enabled: bool,
    pub(crate) read_model_config_enabled: bool,
    pub(crate) tokenizer_provider_available: bool,
    pub(crate) read_model_provider_available: bool,
    pub(crate) feature_enabled: bool,
    pub(crate) feature_available: bool,
    pub(crate) fallback_required: bool,
    pub(crate) readiness: GatewayTrustedNumericSourceReadiness,
    pub(crate) material_in_output: bool,
}

impl GatewayTrustedNumericSourceConfigPreflight {
    pub(crate) fn safe_summary(&self) -> GatewayTrustedNumericSourceConfigPreflightSummary {
        GatewayTrustedNumericSourceConfigPreflightSummary {
            schema: GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_CONFIG_PREFLIGHT_SCHEMA,
            status: self.status.as_str(),
            blocker: self
                .blocker
                .map(GatewayTrustedNumericSourceConfigPreflightBlocker::as_str),
            tokenizer_config_enabled: self.tokenizer_config_enabled,
            read_model_config_enabled: self.read_model_config_enabled,
            tokenizer_provider_available: self.tokenizer_provider_available,
            read_model_provider_available: self.read_model_provider_available,
            feature_enabled: self.feature_enabled,
            feature_available: self.feature_available,
            fallback_required: self.fallback_required,
            availability_marker: GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_AVAILABILITY_MARKER,
            duration_marker: GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_PREFLIGHT_DURATION_MARKER,
            readiness_status: self.readiness.status.as_str(),
            tokenizer_status: self.readiness.tokenizer_status.as_str(),
            read_model_status: self.readiness.read_model_status.as_str(),
            material_in_output: self.material_in_output,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct GatewayTrustedNumericSourceConfigPreflightSummary {
    pub(crate) schema: &'static str,
    pub(crate) status: &'static str,
    pub(crate) blocker: Option<&'static str>,
    pub(crate) tokenizer_config_enabled: bool,
    pub(crate) read_model_config_enabled: bool,
    pub(crate) tokenizer_provider_available: bool,
    pub(crate) read_model_provider_available: bool,
    pub(crate) feature_enabled: bool,
    pub(crate) feature_available: bool,
    pub(crate) fallback_required: bool,
    pub(crate) availability_marker: &'static str,
    pub(crate) duration_marker: &'static str,
    pub(crate) readiness_status: &'static str,
    pub(crate) tokenizer_status: &'static str,
    pub(crate) read_model_status: &'static str,
    pub(crate) material_in_output: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct GatewayTrustedNumericSourceRuntimeAdapterInput<'a> {
    pub(crate) endpoint: GatewayTpmEstimateEndpoint,
    pub(crate) preflight: &'a GatewayTrustedNumericSourceConfigPreflight,
    pub(crate) conservative_fallback_tokens: i64,
}

impl<'a> GatewayTrustedNumericSourceRuntimeAdapterInput<'a> {
    pub(crate) const fn new(
        endpoint: GatewayTpmEstimateEndpoint,
        preflight: &'a GatewayTrustedNumericSourceConfigPreflight,
        conservative_fallback_tokens: i64,
    ) -> Self {
        Self {
            endpoint,
            preflight,
            conservative_fallback_tokens,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct GatewayTrustedNumericSourceRuntimeAdapterOutput {
    pub(crate) availability: GatewayTrustedNumericSourceAvailability,
    pub(crate) material_in_output: bool,
    pub(crate) provider_side_effect_required: bool,
}

impl GatewayTrustedNumericSourceRuntimeAdapterOutput {
    pub(crate) const fn new(availability: GatewayTrustedNumericSourceAvailability) -> Self {
        Self {
            availability,
            material_in_output: false,
            provider_side_effect_required: false,
        }
    }
}

pub(crate) trait GatewayTrustedNumericSourceRuntimeAdapter {
    fn lookup_trusted_numeric_source(
        &self,
        input: GatewayTrustedNumericSourceRuntimeAdapterInput<'_>,
    ) -> GatewayTrustedNumericSourceRuntimeAdapterOutput;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum GatewayTrustedNumericSourceRuntimeAdapterStatus {
    Disabled,
    Blocked,
    Ready,
}

impl GatewayTrustedNumericSourceRuntimeAdapterStatus {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Disabled => "disabled",
            Self::Blocked => "blocked",
            Self::Ready => "ready",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct GatewayTrustedNumericSourceRuntimeAdapterEvidence {
    pub(crate) status: GatewayTrustedNumericSourceRuntimeAdapterStatus,
    pub(crate) endpoint: GatewayTpmEstimateEndpoint,
    pub(crate) preflight_status: GatewayTrustedNumericSourceConfigPreflightStatus,
    pub(crate) availability: GatewayTrustedNumericSourceAvailability,
    pub(crate) adapter_invoked: bool,
    pub(crate) fallback_required: bool,
    pub(crate) conservative_fallback_tokens: i64,
    pub(crate) material_in_output: bool,
    pub(crate) provider_side_effect_required: bool,
}

impl GatewayTrustedNumericSourceRuntimeAdapterEvidence {
    pub(crate) fn safe_summary(&self) -> GatewayTrustedNumericSourceRuntimeAdapterSummary {
        GatewayTrustedNumericSourceRuntimeAdapterSummary {
            schema: GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_RUNTIME_ADAPTER_SCHEMA,
            status: self.status.as_str(),
            endpoint: self.endpoint.as_str(),
            preflight_status: self.preflight_status.as_str(),
            availability_status: self.availability.status.as_str(),
            source_type: self
                .availability
                .source_type
                .map(GatewayTrustedNumericSourceType::as_str),
            token_kind: self
                .availability
                .token_kind
                .map(GatewayTrustedNumericTokenKind::as_str),
            token_count: self.availability.tokens,
            adapter_invoked: self.adapter_invoked,
            fallback_required: self.fallback_required,
            conservative_fallback_tokens: self.conservative_fallback_tokens,
            availability_marker: GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_AVAILABILITY_MARKER,
            preflight_duration_marker: GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_PREFLIGHT_DURATION_MARKER,
            estimate_duration_marker: GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_ESTIMATE_DURATION_MARKER,
            source_marker: GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_TYPE_MARKER,
            token_count_marker: GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_TOKEN_COUNT_MARKER,
            material_in_output: self.material_in_output,
            provider_side_effect_required: self.provider_side_effect_required,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct GatewayTrustedNumericSourceRuntimeAdapterSummary {
    pub(crate) schema: &'static str,
    pub(crate) status: &'static str,
    pub(crate) endpoint: &'static str,
    pub(crate) preflight_status: &'static str,
    pub(crate) availability_status: &'static str,
    pub(crate) source_type: Option<&'static str>,
    pub(crate) token_kind: Option<&'static str>,
    pub(crate) token_count: Option<u64>,
    pub(crate) adapter_invoked: bool,
    pub(crate) fallback_required: bool,
    pub(crate) conservative_fallback_tokens: i64,
    pub(crate) availability_marker: &'static str,
    pub(crate) preflight_duration_marker: &'static str,
    pub(crate) estimate_duration_marker: &'static str,
    pub(crate) source_marker: &'static str,
    pub(crate) token_count_marker: &'static str,
    pub(crate) material_in_output: bool,
    pub(crate) provider_side_effect_required: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct GatewayTrustedNumericSourceOptInEvidenceInput<'a> {
    pub(crate) preflight: &'a GatewayTrustedNumericSourceConfigPreflight,
    pub(crate) availability: &'a GatewayTrustedNumericSourceAvailability,
    pub(crate) tpm_estimate_required_tokens: i64,
    pub(crate) required_capacity_tokens_per_minute: i64,
    pub(crate) acquire_tpm_required_tokens: i64,
    pub(crate) db_required_capacity_tokens_per_minute: i64,
}

impl<'a> GatewayTrustedNumericSourceOptInEvidenceInput<'a> {
    pub(crate) const fn new(
        preflight: &'a GatewayTrustedNumericSourceConfigPreflight,
        availability: &'a GatewayTrustedNumericSourceAvailability,
        tpm_estimate_required_tokens: i64,
        required_capacity_tokens_per_minute: i64,
        acquire_tpm_required_tokens: i64,
        db_required_capacity_tokens_per_minute: i64,
    ) -> Self {
        Self {
            preflight,
            availability,
            tpm_estimate_required_tokens,
            required_capacity_tokens_per_minute,
            acquire_tpm_required_tokens,
            db_required_capacity_tokens_per_minute,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum GatewayTrustedNumericSourceOptInEvidenceStatus {
    Disabled,
    Blocked,
    Ready,
}

impl GatewayTrustedNumericSourceOptInEvidenceStatus {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Disabled => "disabled",
            Self::Blocked => "blocked",
            Self::Ready => "ready",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct GatewayTrustedNumericSourceOptInEvidence {
    pub(crate) status: GatewayTrustedNumericSourceOptInEvidenceStatus,
    pub(crate) preflight_status: GatewayTrustedNumericSourceConfigPreflightStatus,
    pub(crate) availability_status: GatewayTrustedNumericSourceAvailabilityStatus,
    pub(crate) source_type: Option<GatewayTrustedNumericSourceType>,
    pub(crate) token_kind: Option<GatewayTrustedNumericTokenKind>,
    pub(crate) token_count: Option<u64>,
    pub(crate) feature_enabled: bool,
    pub(crate) feature_available: bool,
    pub(crate) fallback_required: bool,
    pub(crate) tpm_estimate_required_tokens: i64,
    pub(crate) required_capacity_tokens_per_minute: i64,
    pub(crate) acquire_tpm_required_tokens: i64,
    pub(crate) db_required_capacity_tokens_per_minute: i64,
    pub(crate) capacity_evidence_aligned: bool,
    pub(crate) reservation_evidence_ready: bool,
    pub(crate) live_gap_closure_ready: bool,
    pub(crate) material_in_output: bool,
}

impl GatewayTrustedNumericSourceOptInEvidence {
    pub(crate) fn safe_summary(&self) -> GatewayTrustedNumericSourceOptInEvidenceSummary {
        GatewayTrustedNumericSourceOptInEvidenceSummary {
            schema: GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_OPT_IN_EVIDENCE_SCHEMA,
            status: self.status.as_str(),
            preflight_status: self.preflight_status.as_str(),
            availability_status: self.availability_status.as_str(),
            source_type: self
                .source_type
                .map(GatewayTrustedNumericSourceType::as_str),
            token_kind: self.token_kind.map(GatewayTrustedNumericTokenKind::as_str),
            token_count: self.token_count,
            feature_enabled: self.feature_enabled,
            feature_available: self.feature_available,
            fallback_required: self.fallback_required,
            availability_marker: GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_AVAILABILITY_MARKER,
            preflight_duration_marker: GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_PREFLIGHT_DURATION_MARKER,
            estimate_duration_marker: GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_ESTIMATE_DURATION_MARKER,
            source_marker: GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_TYPE_MARKER,
            token_count_marker: GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_TOKEN_COUNT_MARKER,
            tpm_estimate_required_tokens: self.tpm_estimate_required_tokens,
            required_capacity_tokens_per_minute: self.required_capacity_tokens_per_minute,
            acquire_tpm_required_tokens: self.acquire_tpm_required_tokens,
            db_required_capacity_tokens_per_minute: self.db_required_capacity_tokens_per_minute,
            capacity_evidence_aligned: self.capacity_evidence_aligned,
            reservation_evidence_ready: self.reservation_evidence_ready,
            live_gap_closure_ready: self.live_gap_closure_ready,
            material_in_output: self.material_in_output,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct GatewayTrustedNumericSourceOptInEvidenceSummary {
    pub(crate) schema: &'static str,
    pub(crate) status: &'static str,
    pub(crate) preflight_status: &'static str,
    pub(crate) availability_status: &'static str,
    pub(crate) source_type: Option<&'static str>,
    pub(crate) token_kind: Option<&'static str>,
    pub(crate) token_count: Option<u64>,
    pub(crate) feature_enabled: bool,
    pub(crate) feature_available: bool,
    pub(crate) fallback_required: bool,
    pub(crate) availability_marker: &'static str,
    pub(crate) preflight_duration_marker: &'static str,
    pub(crate) estimate_duration_marker: &'static str,
    pub(crate) source_marker: &'static str,
    pub(crate) token_count_marker: &'static str,
    pub(crate) tpm_estimate_required_tokens: i64,
    pub(crate) required_capacity_tokens_per_minute: i64,
    pub(crate) acquire_tpm_required_tokens: i64,
    pub(crate) db_required_capacity_tokens_per_minute: i64,
    pub(crate) capacity_evidence_aligned: bool,
    pub(crate) reservation_evidence_ready: bool,
    pub(crate) live_gap_closure_ready: bool,
    pub(crate) material_in_output: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum GatewayTrustedNumericSourceReservationProjectionStatus {
    Unavailable,
    Blocked,
    Ready,
}

impl GatewayTrustedNumericSourceReservationProjectionStatus {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Unavailable => "unavailable",
            Self::Blocked => "blocked",
            Self::Ready => "ready",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct GatewayTrustedNumericSourceReservationProjection {
    pub(crate) status: GatewayTrustedNumericSourceReservationProjectionStatus,
    pub(crate) rate_limit_metadata_path: &'static str,
    pub(crate) smoke_evidence_path: &'static str,
    pub(crate) trusted_source_evidence: GatewayTrustedNumericSourceOptInEvidenceSummary,
    pub(crate) projection_ready: bool,
    pub(crate) performance_markers_present: bool,
    pub(crate) capacity_evidence_aligned: bool,
    pub(crate) material_in_output: bool,
}

impl GatewayTrustedNumericSourceReservationProjection {
    pub(crate) fn safe_summary(&self) -> GatewayTrustedNumericSourceReservationProjectionSummary {
        GatewayTrustedNumericSourceReservationProjectionSummary {
            schema: GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_RESERVATION_PROJECTION_SCHEMA,
            status: self.status.as_str(),
            rate_limit_metadata_path: self.rate_limit_metadata_path,
            smoke_evidence_path: self.smoke_evidence_path,
            trusted_source_evidence: self.trusted_source_evidence.clone(),
            availability_marker: GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_AVAILABILITY_MARKER,
            preflight_duration_marker: GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_PREFLIGHT_DURATION_MARKER,
            estimate_duration_marker: GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_ESTIMATE_DURATION_MARKER,
            source_marker: GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_TYPE_MARKER,
            token_count_marker: GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_TOKEN_COUNT_MARKER,
            projection_ready: self.projection_ready,
            performance_markers_present: self.performance_markers_present,
            capacity_evidence_aligned: self.capacity_evidence_aligned,
            material_in_output: self.material_in_output,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct GatewayTrustedNumericSourceReservationProjectionSummary {
    pub(crate) schema: &'static str,
    pub(crate) status: &'static str,
    pub(crate) rate_limit_metadata_path: &'static str,
    pub(crate) smoke_evidence_path: &'static str,
    pub(crate) trusted_source_evidence: GatewayTrustedNumericSourceOptInEvidenceSummary,
    pub(crate) availability_marker: &'static str,
    pub(crate) preflight_duration_marker: &'static str,
    pub(crate) estimate_duration_marker: &'static str,
    pub(crate) source_marker: &'static str,
    pub(crate) token_count_marker: &'static str,
    pub(crate) projection_ready: bool,
    pub(crate) performance_markers_present: bool,
    pub(crate) capacity_evidence_aligned: bool,
    pub(crate) material_in_output: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum GatewayTrustedNumericSourceAvailabilityStatus {
    Available,
    Unavailable,
    Invalid,
}

impl GatewayTrustedNumericSourceAvailabilityStatus {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Available => "available",
            Self::Unavailable => "unavailable",
            Self::Invalid => "invalid",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum GatewayTrustedNumericSourceInvalidReason {
    SourceTypeNotAllowed,
    NegativeTokens,
}

impl GatewayTrustedNumericSourceInvalidReason {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::SourceTypeNotAllowed => "source_type_not_allowed",
            Self::NegativeTokens => "negative_tokens",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct GatewayTrustedNumericSourceAvailability {
    pub(crate) status: GatewayTrustedNumericSourceAvailabilityStatus,
    pub(crate) source_type: Option<GatewayTrustedNumericSourceType>,
    pub(crate) token_kind: Option<GatewayTrustedNumericTokenKind>,
    pub(crate) tokens: Option<u64>,
    pub(crate) token_lower_bound: u64,
    pub(crate) token_upper_bound: u64,
    pub(crate) fallback_required: bool,
    pub(crate) material_in_output: bool,
    pub(crate) invalid_reason: Option<GatewayTrustedNumericSourceInvalidReason>,
}

impl GatewayTrustedNumericSourceAvailability {
    pub(crate) fn safe_summary(&self) -> GatewayTrustedNumericSourceAvailabilitySummary {
        GatewayTrustedNumericSourceAvailabilitySummary {
            schema: GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_AVAILABILITY_SCHEMA,
            status: self.status.as_str(),
            source_type: self
                .source_type
                .map(GatewayTrustedNumericSourceType::as_str),
            token_kind: self.token_kind.map(GatewayTrustedNumericTokenKind::as_str),
            tokens: self.tokens,
            token_lower_bound: self.token_lower_bound,
            token_upper_bound: self.token_upper_bound,
            fallback_required: self.fallback_required,
            material_in_output: self.material_in_output,
            invalid_reason: self
                .invalid_reason
                .map(GatewayTrustedNumericSourceInvalidReason::as_str),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct GatewayTrustedNumericSourceAvailabilitySummary {
    pub(crate) schema: &'static str,
    pub(crate) status: &'static str,
    pub(crate) source_type: Option<&'static str>,
    pub(crate) token_kind: Option<&'static str>,
    pub(crate) tokens: Option<u64>,
    pub(crate) token_lower_bound: u64,
    pub(crate) token_upper_bound: u64,
    pub(crate) fallback_required: bool,
    pub(crate) material_in_output: bool,
    pub(crate) invalid_reason: Option<&'static str>,
}

pub(crate) fn gateway_trusted_numeric_source_availability(
    candidate: Option<GatewayTrustedNumericSourceCandidate<'_>>,
) -> GatewayTrustedNumericSourceAvailability {
    const TOKEN_LOWER_BOUND: u64 = 0;
    const TOKEN_UPPER_BOUND: u64 = i64::MAX as u64;

    let Some(candidate) = candidate else {
        return GatewayTrustedNumericSourceAvailability {
            status: GatewayTrustedNumericSourceAvailabilityStatus::Unavailable,
            source_type: None,
            token_kind: None,
            tokens: None,
            token_lower_bound: TOKEN_LOWER_BOUND,
            token_upper_bound: TOKEN_UPPER_BOUND,
            fallback_required: true,
            material_in_output: false,
            invalid_reason: None,
        };
    };
    let Some(source_type) = GatewayTrustedNumericSourceType::from_str(candidate.source_type) else {
        return GatewayTrustedNumericSourceAvailability {
            status: GatewayTrustedNumericSourceAvailabilityStatus::Invalid,
            source_type: None,
            token_kind: None,
            tokens: None,
            token_lower_bound: TOKEN_LOWER_BOUND,
            token_upper_bound: TOKEN_UPPER_BOUND,
            fallback_required: true,
            material_in_output: false,
            invalid_reason: Some(GatewayTrustedNumericSourceInvalidReason::SourceTypeNotAllowed),
        };
    };
    let Some(tokens) = candidate.tokens else {
        return GatewayTrustedNumericSourceAvailability {
            status: GatewayTrustedNumericSourceAvailabilityStatus::Unavailable,
            source_type: Some(source_type),
            token_kind: Some(candidate.token_kind),
            tokens: None,
            token_lower_bound: TOKEN_LOWER_BOUND,
            token_upper_bound: TOKEN_UPPER_BOUND,
            fallback_required: true,
            material_in_output: false,
            invalid_reason: None,
        };
    };
    if tokens < 0 {
        return GatewayTrustedNumericSourceAvailability {
            status: GatewayTrustedNumericSourceAvailabilityStatus::Invalid,
            source_type: Some(source_type),
            token_kind: Some(candidate.token_kind),
            tokens: None,
            token_lower_bound: TOKEN_LOWER_BOUND,
            token_upper_bound: TOKEN_UPPER_BOUND,
            fallback_required: true,
            material_in_output: false,
            invalid_reason: Some(GatewayTrustedNumericSourceInvalidReason::NegativeTokens),
        };
    }

    GatewayTrustedNumericSourceAvailability {
        status: GatewayTrustedNumericSourceAvailabilityStatus::Available,
        source_type: Some(source_type),
        token_kind: Some(candidate.token_kind),
        tokens: Some(tokens as u64),
        token_lower_bound: TOKEN_LOWER_BOUND,
        token_upper_bound: TOKEN_UPPER_BOUND,
        fallback_required: false,
        material_in_output: false,
        invalid_reason: None,
    }
}

pub(crate) fn gateway_trusted_numeric_source_availability_from_adapter(
    output: Option<GatewayTrustedNumericSourceAdapterOutput>,
) -> GatewayTrustedNumericSourceAvailability {
    gateway_trusted_numeric_source_availability(output.map(|output| {
        GatewayTrustedNumericSourceCandidate::new(
            output.source_type.as_str(),
            output.token_kind,
            output.tokens,
        )
    }))
}

pub(crate) fn gateway_trusted_numeric_source_readiness(
    input: GatewayTrustedNumericSourceReadinessInput,
) -> GatewayTrustedNumericSourceReadiness {
    let tokenizer_status =
        provider_readiness_status(input.tokenizer_enabled, input.tokenizer_available);
    let read_model_status =
        provider_readiness_status(input.read_model_enabled, input.read_model_available);
    let feature_available = tokenizer_status
        == GatewayTrustedNumericSourceProviderReadinessStatus::Available
        || read_model_status == GatewayTrustedNumericSourceProviderReadinessStatus::Available;

    GatewayTrustedNumericSourceReadiness {
        status: if feature_available {
            GatewayTrustedNumericSourceReadinessStatus::Available
        } else {
            GatewayTrustedNumericSourceReadinessStatus::Unavailable
        },
        tokenizer_status,
        read_model_status,
        tokenizer_enabled: input.tokenizer_enabled,
        read_model_enabled: input.read_model_enabled,
        feature_available,
        fallback_required: !feature_available,
        material_in_output: false,
    }
}

pub(crate) fn gateway_trusted_numeric_source_config_preflight(
    input: GatewayTrustedNumericSourceConfigPreflightInput,
) -> GatewayTrustedNumericSourceConfigPreflight {
    let readiness =
        gateway_trusted_numeric_source_readiness(GatewayTrustedNumericSourceReadinessInput::new(
            input.tokenizer_config_enabled,
            input.tokenizer_provider_available,
            input.read_model_config_enabled,
            input.read_model_provider_available,
        ));
    let feature_enabled = input.tokenizer_config_enabled || input.read_model_config_enabled;
    let status = match (feature_enabled, readiness.feature_available) {
        (false, _) => GatewayTrustedNumericSourceConfigPreflightStatus::Disabled,
        (true, true) => GatewayTrustedNumericSourceConfigPreflightStatus::Ready,
        (true, false) => GatewayTrustedNumericSourceConfigPreflightStatus::Blocked,
    };
    let blocker = match status {
        GatewayTrustedNumericSourceConfigPreflightStatus::Disabled => {
            Some(GatewayTrustedNumericSourceConfigPreflightBlocker::ConfigDisabled)
        }
        GatewayTrustedNumericSourceConfigPreflightStatus::Blocked => {
            Some(GatewayTrustedNumericSourceConfigPreflightBlocker::ProviderUnavailable)
        }
        GatewayTrustedNumericSourceConfigPreflightStatus::Ready => None,
    };

    GatewayTrustedNumericSourceConfigPreflight {
        status,
        blocker,
        tokenizer_config_enabled: input.tokenizer_config_enabled,
        read_model_config_enabled: input.read_model_config_enabled,
        tokenizer_provider_available: input.tokenizer_provider_available,
        read_model_provider_available: input.read_model_provider_available,
        feature_enabled,
        feature_available: readiness.feature_available,
        fallback_required: !readiness.feature_available,
        readiness,
        material_in_output: false,
    }
}

pub(crate) fn gateway_trusted_numeric_source_runtime_adapter_boundary(
    input: GatewayTrustedNumericSourceRuntimeAdapterInput<'_>,
    adapter: Option<&dyn GatewayTrustedNumericSourceRuntimeAdapter>,
) -> GatewayTrustedNumericSourceRuntimeAdapterEvidence {
    if input.preflight.status == GatewayTrustedNumericSourceConfigPreflightStatus::Disabled {
        return gateway_trusted_numeric_source_runtime_adapter_fallback_evidence(
            GatewayTrustedNumericSourceRuntimeAdapterStatus::Disabled,
            input,
            false,
        );
    }
    if input.preflight.status == GatewayTrustedNumericSourceConfigPreflightStatus::Blocked {
        return gateway_trusted_numeric_source_runtime_adapter_fallback_evidence(
            GatewayTrustedNumericSourceRuntimeAdapterStatus::Blocked,
            input,
            false,
        );
    }

    let Some(adapter) = adapter else {
        return gateway_trusted_numeric_source_runtime_adapter_fallback_evidence(
            GatewayTrustedNumericSourceRuntimeAdapterStatus::Blocked,
            input,
            false,
        );
    };
    let output = adapter.lookup_trusted_numeric_source(input);
    let available = output.availability.status
        == GatewayTrustedNumericSourceAvailabilityStatus::Available
        && !output.material_in_output
        && !output.provider_side_effect_required;

    GatewayTrustedNumericSourceRuntimeAdapterEvidence {
        status: if available {
            GatewayTrustedNumericSourceRuntimeAdapterStatus::Ready
        } else {
            GatewayTrustedNumericSourceRuntimeAdapterStatus::Blocked
        },
        endpoint: input.endpoint,
        preflight_status: input.preflight.status,
        fallback_required: !available || output.availability.fallback_required,
        availability: output.availability,
        adapter_invoked: true,
        conservative_fallback_tokens: input.conservative_fallback_tokens,
        material_in_output: output.material_in_output,
        provider_side_effect_required: output.provider_side_effect_required,
    }
}

fn gateway_trusted_numeric_source_runtime_adapter_fallback_evidence(
    status: GatewayTrustedNumericSourceRuntimeAdapterStatus,
    input: GatewayTrustedNumericSourceRuntimeAdapterInput<'_>,
    adapter_invoked: bool,
) -> GatewayTrustedNumericSourceRuntimeAdapterEvidence {
    GatewayTrustedNumericSourceRuntimeAdapterEvidence {
        status,
        endpoint: input.endpoint,
        preflight_status: input.preflight.status,
        availability: gateway_trusted_numeric_source_availability_from_adapter(None),
        adapter_invoked,
        fallback_required: true,
        conservative_fallback_tokens: input.conservative_fallback_tokens,
        material_in_output: false,
        provider_side_effect_required: false,
    }
}

pub(crate) fn gateway_trusted_numeric_source_opt_in_evidence(
    input: GatewayTrustedNumericSourceOptInEvidenceInput<'_>,
) -> GatewayTrustedNumericSourceOptInEvidence {
    let status = match input.preflight.status {
        GatewayTrustedNumericSourceConfigPreflightStatus::Disabled => {
            GatewayTrustedNumericSourceOptInEvidenceStatus::Disabled
        }
        GatewayTrustedNumericSourceConfigPreflightStatus::Blocked => {
            GatewayTrustedNumericSourceOptInEvidenceStatus::Blocked
        }
        GatewayTrustedNumericSourceConfigPreflightStatus::Ready => {
            GatewayTrustedNumericSourceOptInEvidenceStatus::Ready
        }
    };
    let capacity_evidence_aligned = input.tpm_estimate_required_tokens
        == input.required_capacity_tokens_per_minute
        && input.required_capacity_tokens_per_minute == input.acquire_tpm_required_tokens
        && input.acquire_tpm_required_tokens == input.db_required_capacity_tokens_per_minute;
    let availability_ready =
        input.availability.status == GatewayTrustedNumericSourceAvailabilityStatus::Available;
    let reservation_evidence_ready = input.preflight.status
        == GatewayTrustedNumericSourceConfigPreflightStatus::Ready
        && availability_ready
        && capacity_evidence_aligned
        && input.tpm_estimate_required_tokens > 0;

    GatewayTrustedNumericSourceOptInEvidence {
        status,
        preflight_status: input.preflight.status,
        availability_status: input.availability.status,
        source_type: input.availability.source_type,
        token_kind: input.availability.token_kind,
        token_count: input.availability.tokens,
        feature_enabled: input.preflight.feature_enabled,
        feature_available: input.preflight.feature_available,
        fallback_required: input.preflight.fallback_required
            || input.availability.fallback_required,
        tpm_estimate_required_tokens: input.tpm_estimate_required_tokens,
        required_capacity_tokens_per_minute: input.required_capacity_tokens_per_minute,
        acquire_tpm_required_tokens: input.acquire_tpm_required_tokens,
        db_required_capacity_tokens_per_minute: input.db_required_capacity_tokens_per_minute,
        capacity_evidence_aligned,
        reservation_evidence_ready,
        live_gap_closure_ready: reservation_evidence_ready,
        material_in_output: false,
    }
}

pub(crate) fn gateway_trusted_numeric_source_reservation_projection(
    evidence: &GatewayTrustedNumericSourceOptInEvidence,
) -> GatewayTrustedNumericSourceReservationProjection {
    let status = match evidence.status {
        GatewayTrustedNumericSourceOptInEvidenceStatus::Disabled => {
            GatewayTrustedNumericSourceReservationProjectionStatus::Unavailable
        }
        GatewayTrustedNumericSourceOptInEvidenceStatus::Blocked => {
            GatewayTrustedNumericSourceReservationProjectionStatus::Blocked
        }
        GatewayTrustedNumericSourceOptInEvidenceStatus::Ready => {
            if evidence.reservation_evidence_ready {
                GatewayTrustedNumericSourceReservationProjectionStatus::Ready
            } else {
                GatewayTrustedNumericSourceReservationProjectionStatus::Unavailable
            }
        }
    };
    let performance_markers_present = !GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_AVAILABILITY_MARKER
        .is_empty()
        && !GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_PREFLIGHT_DURATION_MARKER.is_empty()
        && !GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_ESTIMATE_DURATION_MARKER.is_empty()
        && !GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_TYPE_MARKER.is_empty()
        && !GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_TOKEN_COUNT_MARKER.is_empty();

    GatewayTrustedNumericSourceReservationProjection {
        status,
        rate_limit_metadata_path: "rate_limit_reservation.trusted_source_evidence",
        smoke_evidence_path: "smoke.rate_limit_reservation.trusted_source_evidence",
        trusted_source_evidence: evidence.safe_summary(),
        projection_ready: evidence.reservation_evidence_ready && performance_markers_present,
        performance_markers_present,
        capacity_evidence_aligned: evidence.capacity_evidence_aligned,
        material_in_output: false,
    }
}

fn provider_readiness_status(
    enabled: bool,
    available: bool,
) -> GatewayTrustedNumericSourceProviderReadinessStatus {
    match (enabled, available) {
        (false, _) => GatewayTrustedNumericSourceProviderReadinessStatus::Disabled,
        (true, true) => GatewayTrustedNumericSourceProviderReadinessStatus::Available,
        (true, false) => GatewayTrustedNumericSourceProviderReadinessStatus::Unavailable,
    }
}

pub(crate) fn gateway_tpm_signals_for_readiness(
    readiness: &GatewayTrustedNumericSourceReadiness,
    availability: &GatewayTrustedNumericSourceAvailability,
    conservative_fallback_tokens: i64,
) -> GatewayTpmEstimateSignals {
    if !readiness.feature_available {
        return GatewayTpmEstimateSignals::missing_tokenizer(conservative_fallback_tokens);
    }

    gateway_tpm_signals_from_trusted_numeric_source(availability, conservative_fallback_tokens)
}

pub(crate) fn gateway_tpm_signals_from_trusted_numeric_source(
    availability: &GatewayTrustedNumericSourceAvailability,
    conservative_fallback_tokens: i64,
) -> GatewayTpmEstimateSignals {
    if availability.status != GatewayTrustedNumericSourceAvailabilityStatus::Available {
        return GatewayTpmEstimateSignals::missing_tokenizer(conservative_fallback_tokens);
    }

    match (availability.token_kind, availability.tokens) {
        (Some(GatewayTrustedNumericTokenKind::InputTokens), Some(tokens)) => {
            GatewayTpmEstimateSignals::trusted_input_tokens(
                Some(tokens.min(i64::MAX as u64) as i64),
                conservative_fallback_tokens,
            )
        }
        (Some(GatewayTrustedNumericTokenKind::PromptTokens), Some(tokens)) => {
            GatewayTpmEstimateSignals::trusted_prompt_tokens(
                Some(tokens.min(i64::MAX as u64) as i64),
                conservative_fallback_tokens,
            )
        }
        _ => GatewayTpmEstimateSignals::missing_tokenizer(conservative_fallback_tokens),
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
    fn tpm_estimate_mapper_fixture_defines_trusted_numeric_source_availability_contract() {
        let fixture = fixture();
        let contract = &fixture["trusted_numeric_source_availability_contract"];

        assert_eq!(
            contract["schema"].as_str(),
            Some(GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_AVAILABILITY_SCHEMA)
        );
        assert_eq!(
            contract["runtime_wiring_status"].as_str(),
            Some(
                "not wired; runtime remains missing-tokenizer fallback until a trusted numeric tokenizer/read-model source exists"
            )
        );
        assert_eq!(
            contract["accepted_material"].as_str(),
            Some("numeric token counts from whitelisted trusted sources only")
        );

        let allowed_source_types = contract["allowed_source_types"]
            .as_array()
            .expect("allowed source types should be an array");
        assert_eq!(allowed_source_types.len(), 2);
        for source_type in ["tokenizer", "read_model"] {
            assert!(
                allowed_source_types
                    .iter()
                    .any(|source| source.as_str() == Some(source_type)),
                "trusted source availability should allow {source_type}"
            );
            assert!(
                GatewayTrustedNumericSourceType::from_str(source_type).is_some(),
                "trusted source helper should accept {source_type}"
            );
        }

        for source_type in contract["forbidden_source_types"]
            .as_array()
            .expect("forbidden source types should be an array")
            .iter()
            .filter_map(serde_json::Value::as_str)
        {
            assert!(
                GatewayTrustedNumericSourceType::from_str(source_type).is_none(),
                "trusted source helper must reject raw or untrusted source type: {source_type}"
            );
        }

        let numeric_fields = contract["numeric_only_output_fields"]
            .as_array()
            .expect("numeric-only output fields should be an array");
        for field in [
            "schema",
            "status",
            "source_type",
            "token_kind",
            "tokens",
            "token_lower_bound",
            "token_upper_bound",
            "fallback_required",
            "material_in_output",
            "invalid_reason",
        ] {
            assert!(
                numeric_fields
                    .iter()
                    .any(|entry| entry.as_str() == Some(field)),
                "trusted source availability output should include {field}"
            );
        }
        assert_eq!(contract["token_bounds"]["lower"], 0);
        assert_eq!(contract["token_bounds"]["upper"], i64::MAX);

        let states = contract["states"]
            .as_array()
            .expect("availability states should be an array");
        for required_state in [
            "available_tokenizer_prompt_tokens",
            "available_read_model_input_tokens",
            "unavailable_missing_source",
            "unavailable_missing_tokens",
            "invalid_raw_source_type",
            "invalid_negative_tokens",
        ] {
            assert!(
                states
                    .iter()
                    .any(|state| state["name"].as_str() == Some(required_state)),
                "trusted source availability contract missing state: {required_state}"
            );
        }
        for side_effect in [
            "reservation_acquire",
            "provider_attempt",
            "provider_key_open",
            "upstream_call",
            "billing_side_effect",
        ] {
            assert_eq!(
                contract["side_effect_contract"][side_effect].as_bool(),
                Some(false),
                "trusted source availability contract should not require {side_effect}"
            );
        }
    }

    #[test]
    fn tpm_estimate_mapper_trusted_numeric_source_availability_controls_fallback() {
        let fixture = fixture();
        let contract = &fixture["trusted_numeric_source_availability_contract"];

        let available_prompt = gateway_trusted_numeric_source_availability(Some(
            GatewayTrustedNumericSourceCandidate::new(
                "tokenizer",
                GatewayTrustedNumericTokenKind::PromptTokens,
                Some(321),
            ),
        ));
        let available_prompt_summary = available_prompt.safe_summary();
        assert_eq!(
            available_prompt.status,
            GatewayTrustedNumericSourceAvailabilityStatus::Available
        );
        assert_eq!(available_prompt_summary.status, "available");
        assert_eq!(available_prompt_summary.source_type, Some("tokenizer"));
        assert_eq!(available_prompt_summary.token_kind, Some("prompt_tokens"));
        assert_eq!(available_prompt_summary.tokens, Some(321));
        assert_eq!(available_prompt_summary.token_lower_bound, 0);
        assert_eq!(available_prompt_summary.token_upper_bound, i64::MAX as u64);
        assert!(!available_prompt_summary.fallback_required);
        assert!(!available_prompt_summary.material_in_output);

        let prompt_plan = gateway_tpm_estimate_for_request(
            GatewayTpmEstimateEndpoint::OpenAiChat,
            &json!({
                "messages": [{ "content": "sk-live-provider-secret raw prompt" }],
                "max_completion_tokens": 79
            }),
            gateway_tpm_signals_from_trusted_numeric_source(&available_prompt, 256),
        );
        assert_eq!(
            prompt_plan.estimate.source,
            RateLimitTpmEstimateSource::PromptAndMaxCompletion
        );
        assert_eq!(prompt_plan.estimate.required_tokens, 400);
        assert!(!prompt_plan.estimate.used_conservative_fallback);

        let available_input = gateway_trusted_numeric_source_availability(Some(
            GatewayTrustedNumericSourceCandidate::new(
                "read_model",
                GatewayTrustedNumericTokenKind::InputTokens,
                Some(222),
            ),
        ));
        let input_plan = gateway_tpm_estimate_for_request(
            GatewayTpmEstimateEndpoint::OpenAiEmbeddings,
            &json!({ "input": "sk-live-provider-secret raw embedding input" }),
            gateway_tpm_signals_from_trusted_numeric_source(&available_input, 256),
        );
        assert_eq!(
            input_plan.estimate.source,
            RateLimitTpmEstimateSource::TotalTokens
        );
        assert_eq!(input_plan.estimate.required_tokens, 222);
        assert!(!input_plan.estimate.used_conservative_fallback);

        let unavailable_missing_source = gateway_trusted_numeric_source_availability(None);
        let unavailable_plan = gateway_tpm_estimate_for_request(
            GatewayTpmEstimateEndpoint::OpenAiResponses,
            &json!({
                "input": "raw response input must not be counted",
                "max_output_tokens": 128
            }),
            gateway_tpm_signals_from_trusted_numeric_source(&unavailable_missing_source, 256),
        );
        assert_eq!(
            unavailable_missing_source.status,
            GatewayTrustedNumericSourceAvailabilityStatus::Unavailable
        );
        assert_eq!(
            unavailable_plan.estimate.source,
            RateLimitTpmEstimateSource::PartialEstimateWithConservativeFallback
        );
        assert_eq!(unavailable_plan.estimate.required_tokens, 384);
        assert!(unavailable_plan.estimate.used_conservative_fallback);

        let unavailable_missing_tokens = gateway_trusted_numeric_source_availability(Some(
            GatewayTrustedNumericSourceCandidate::new(
                "tokenizer",
                GatewayTrustedNumericTokenKind::PromptTokens,
                None,
            ),
        ));
        assert_eq!(
            unavailable_missing_tokens.status,
            GatewayTrustedNumericSourceAvailabilityStatus::Unavailable
        );
        assert_eq!(
            unavailable_missing_tokens.safe_summary().source_type,
            Some("tokenizer")
        );
        assert_eq!(unavailable_missing_tokens.safe_summary().tokens, None);
        assert!(unavailable_missing_tokens.safe_summary().fallback_required);

        let invalid_raw_source = gateway_trusted_numeric_source_availability(Some(
            GatewayTrustedNumericSourceCandidate::new(
                "request_body",
                GatewayTrustedNumericTokenKind::PromptTokens,
                Some(9_999),
            ),
        ));
        let invalid_raw_plan = gateway_tpm_estimate_for_request(
            GatewayTpmEstimateEndpoint::OpenAiChat,
            &json!({
                "messages": [{ "content": "raw prompt length must not be counted" }],
                "max_completion_tokens": 128
            }),
            gateway_tpm_signals_from_trusted_numeric_source(&invalid_raw_source, 256),
        );
        assert_eq!(
            invalid_raw_source.status,
            GatewayTrustedNumericSourceAvailabilityStatus::Invalid
        );
        assert_eq!(
            invalid_raw_source.invalid_reason,
            Some(GatewayTrustedNumericSourceInvalidReason::SourceTypeNotAllowed)
        );
        assert_eq!(invalid_raw_source.safe_summary().source_type, None);
        assert_eq!(
            invalid_raw_plan.estimate.source,
            RateLimitTpmEstimateSource::PartialEstimateWithConservativeFallback
        );
        assert_eq!(invalid_raw_plan.estimate.required_tokens, 384);
        assert!(invalid_raw_plan.estimate.used_conservative_fallback);

        let invalid_negative = gateway_trusted_numeric_source_availability(Some(
            GatewayTrustedNumericSourceCandidate::new(
                "read_model",
                GatewayTrustedNumericTokenKind::InputTokens,
                Some(-7),
            ),
        ));
        let invalid_negative_plan = gateway_tpm_estimate_for_request(
            GatewayTpmEstimateEndpoint::OpenAiEmbeddings,
            &json!({ "input": "raw embedding input must not be counted" }),
            gateway_tpm_signals_from_trusted_numeric_source(&invalid_negative, 256),
        );
        assert_eq!(
            invalid_negative.status,
            GatewayTrustedNumericSourceAvailabilityStatus::Invalid
        );
        assert_eq!(
            invalid_negative.invalid_reason,
            Some(GatewayTrustedNumericSourceInvalidReason::NegativeTokens)
        );
        assert_eq!(
            invalid_negative_plan.estimate.source,
            RateLimitTpmEstimateSource::ConservativeFallback
        );
        assert_eq!(invalid_negative_plan.estimate.required_tokens, 256);
        assert!(invalid_negative_plan.estimate.used_conservative_fallback);

        let serialized = serde_json::to_string(&json!({
            "availability": [
                available_prompt.safe_summary(),
                available_input.safe_summary(),
                unavailable_missing_source.safe_summary(),
                unavailable_missing_tokens.safe_summary(),
                invalid_raw_source.safe_summary(),
                invalid_negative.safe_summary()
            ],
            "plans": [
                prompt_plan.safe_summary(),
                input_plan.safe_summary(),
                unavailable_plan.safe_summary(),
                invalid_raw_plan.safe_summary(),
                invalid_negative_plan.safe_summary()
            ]
        }))
        .expect("trusted numeric availability summaries should serialize")
        .to_ascii_lowercase();
        for forbidden in contract["forbidden_output_markers"]
            .as_array()
            .expect("forbidden markers should be an array")
            .iter()
            .filter_map(serde_json::Value::as_str)
        {
            assert!(
                !serialized.contains(&forbidden.to_ascii_lowercase()),
                "trusted numeric source availability output leaked forbidden marker: {forbidden}"
            );
        }
        for raw_marker in [
            "raw prompt",
            "raw response input",
            "raw embedding input",
            "request_body",
            "body_length",
            "string_length",
            "\"messages\"",
            "\"content\"",
        ] {
            assert!(
                !serialized.contains(raw_marker),
                "trusted numeric source availability output leaked raw marker: {raw_marker}"
            );
        }
    }

    #[test]
    fn tpm_estimate_mapper_fixture_defines_trusted_numeric_source_readiness_guard() {
        let fixture = fixture();
        let contract = &fixture["trusted_numeric_source_readiness_guard_contract"];

        assert_eq!(
            contract["schema"].as_str(),
            Some(GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_READINESS_SCHEMA)
        );
        assert_eq!(
            contract["implementation_status"].as_str(),
            Some("readiness guard only; tokenizer/read-model adapters are not wired into runtime")
        );
        assert_eq!(
            contract["runtime_config_default"].as_str(),
            Some("disabled")
        );
        assert_eq!(contract["runtime_wiring_changed"].as_bool(), Some(false));
        assert_eq!(
            contract["feature_availability_marker"].as_str(),
            Some("feature_available")
        );

        let provider_status_fields = contract["provider_status_fields"]
            .as_array()
            .expect("provider status fields should be an array");
        for field in ["tokenizer_status", "read_model_status"] {
            assert!(
                provider_status_fields
                    .iter()
                    .any(|entry| entry.as_str() == Some(field)),
                "readiness evidence should include provider status field: {field}"
            );
        }

        let allowed_statuses = contract["allowed_provider_statuses"]
            .as_array()
            .expect("allowed provider statuses should be an array");
        for status in ["disabled", "unavailable", "available"] {
            assert!(
                allowed_statuses
                    .iter()
                    .any(|entry| entry.as_str() == Some(status)),
                "readiness evidence should allow provider status: {status}"
            );
        }

        let states = contract["states"]
            .as_array()
            .expect("readiness states should be an array");
        for required_state in [
            "disabled_by_default",
            "tokenizer_enabled_unavailable",
            "read_model_enabled_unavailable",
            "tokenizer_available",
            "read_model_available",
        ] {
            assert!(
                states
                    .iter()
                    .any(|state| state["name"].as_str() == Some(required_state)),
                "readiness guard contract missing state: {required_state}"
            );
        }

        let evidence_fields = contract["smoke_evidence_projection_fields"]
            .as_array()
            .expect("smoke evidence projection fields should be an array");
        for field in [
            "trusted_source_readiness.schema",
            "trusted_source_readiness.status",
            "trusted_source_readiness.tokenizer_status",
            "trusted_source_readiness.read_model_status",
            "trusted_source_readiness.feature_available",
            "trusted_source_readiness.fallback_required",
            "trusted_source_readiness.material_in_output",
        ] {
            assert!(
                evidence_fields
                    .iter()
                    .any(|entry| entry.as_str() == Some(field)),
                "smoke readiness evidence should include {field}"
            );
        }

        for side_effect in [
            "reservation_acquire",
            "provider_attempt",
            "provider_key_open",
            "upstream_call",
            "billing_side_effect",
        ] {
            assert_eq!(
                contract["side_effect_contract"][side_effect].as_bool(),
                Some(false),
                "readiness guard contract should not require {side_effect}"
            );
        }
    }

    #[test]
    fn tpm_estimate_mapper_trusted_numeric_source_readiness_controls_fallback() {
        fn state<'a>(contract: &'a serde_json::Value, name: &str) -> &'a serde_json::Value {
            contract["states"]
                .as_array()
                .expect("readiness states should be an array")
                .iter()
                .find(|state| state["name"].as_str() == Some(name))
                .unwrap_or_else(|| panic!("missing readiness state: {name}"))
        }

        fn assert_readiness_summary(
            summary: &GatewayTrustedNumericSourceReadinessSummary,
            expected: &serde_json::Value,
        ) {
            assert_eq!(
                summary.schema,
                GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_READINESS_SCHEMA
            );
            assert_eq!(summary.status, expected["status"].as_str().unwrap());
            assert_eq!(
                summary.tokenizer_status,
                expected["tokenizer_status"].as_str().unwrap()
            );
            assert_eq!(
                summary.read_model_status,
                expected["read_model_status"].as_str().unwrap()
            );
            assert_eq!(
                summary.tokenizer_enabled,
                expected["tokenizer_enabled"].as_bool().unwrap()
            );
            assert_eq!(
                summary.read_model_enabled,
                expected["read_model_enabled"].as_bool().unwrap()
            );
            assert_eq!(
                summary.feature_available,
                expected["feature_available"].as_bool().unwrap()
            );
            assert_eq!(
                summary.fallback_required,
                expected["fallback_required"].as_bool().unwrap()
            );
            assert!(!summary.material_in_output);
        }

        let fixture = fixture();
        let contract = &fixture["trusted_numeric_source_readiness_guard_contract"];
        let available_prompt = gateway_trusted_numeric_source_availability_from_adapter(Some(
            GatewayTrustedNumericSourceAdapterOutput::new(
                GatewayTrustedNumericSourceType::Tokenizer,
                GatewayTrustedNumericTokenKind::PromptTokens,
                Some(321),
            ),
        ));
        let available_input = gateway_trusted_numeric_source_availability_from_adapter(Some(
            GatewayTrustedNumericSourceAdapterOutput::new(
                GatewayTrustedNumericSourceType::ReadModel,
                GatewayTrustedNumericTokenKind::InputTokens,
                Some(222),
            ),
        ));

        let disabled = gateway_trusted_numeric_source_readiness(
            GatewayTrustedNumericSourceReadinessInput::disabled_by_default(),
        );
        assert_eq!(
            disabled.status,
            GatewayTrustedNumericSourceReadinessStatus::Unavailable
        );
        assert_eq!(
            disabled.tokenizer_status,
            GatewayTrustedNumericSourceProviderReadinessStatus::Disabled
        );
        assert_eq!(
            disabled.read_model_status,
            GatewayTrustedNumericSourceProviderReadinessStatus::Disabled
        );
        assert!(!disabled.feature_available);
        assert!(disabled.fallback_required);
        assert_readiness_summary(
            &disabled.safe_summary(),
            state(contract, "disabled_by_default"),
        );
        let disabled_plan = gateway_tpm_estimate_for_request(
            GatewayTpmEstimateEndpoint::OpenAiChat,
            &json!({
                "messages": [{ "content": "sk-live raw prompt must not influence tokens" }],
                "max_completion_tokens": 79
            }),
            gateway_tpm_signals_for_readiness(&disabled, &available_prompt, 256),
        );
        assert_eq!(
            disabled_plan.estimate.source,
            RateLimitTpmEstimateSource::PartialEstimateWithConservativeFallback
        );
        assert_eq!(disabled_plan.estimate.required_tokens, 335);
        assert!(disabled_plan.estimate.used_conservative_fallback);

        let tokenizer_unavailable = gateway_trusted_numeric_source_readiness(
            GatewayTrustedNumericSourceReadinessInput::new(true, false, false, false),
        );
        assert_eq!(
            tokenizer_unavailable.status,
            GatewayTrustedNumericSourceReadinessStatus::Unavailable
        );
        assert_eq!(
            tokenizer_unavailable.tokenizer_status,
            GatewayTrustedNumericSourceProviderReadinessStatus::Unavailable
        );
        assert!(!tokenizer_unavailable.feature_available);
        assert_readiness_summary(
            &tokenizer_unavailable.safe_summary(),
            state(contract, "tokenizer_enabled_unavailable"),
        );
        let tokenizer_unavailable_plan = gateway_tpm_estimate_for_request(
            GatewayTpmEstimateEndpoint::OpenAiResponses,
            &json!({
                "input": "raw response input must not influence tokens",
                "max_output_tokens": 128
            }),
            gateway_tpm_signals_for_readiness(&tokenizer_unavailable, &available_prompt, 256),
        );
        assert_eq!(
            tokenizer_unavailable_plan.estimate.source,
            RateLimitTpmEstimateSource::PartialEstimateWithConservativeFallback
        );
        assert_eq!(tokenizer_unavailable_plan.estimate.required_tokens, 384);
        assert!(
            tokenizer_unavailable_plan
                .estimate
                .used_conservative_fallback
        );

        let read_model_unavailable = gateway_trusted_numeric_source_readiness(
            GatewayTrustedNumericSourceReadinessInput::new(false, false, true, false),
        );
        assert_eq!(
            read_model_unavailable.status,
            GatewayTrustedNumericSourceReadinessStatus::Unavailable
        );
        assert_eq!(
            read_model_unavailable.read_model_status,
            GatewayTrustedNumericSourceProviderReadinessStatus::Unavailable
        );
        assert!(!read_model_unavailable.feature_available);
        assert_readiness_summary(
            &read_model_unavailable.safe_summary(),
            state(contract, "read_model_enabled_unavailable"),
        );

        let tokenizer_available = gateway_trusted_numeric_source_readiness(
            GatewayTrustedNumericSourceReadinessInput::new(true, true, false, false),
        );
        assert_eq!(
            tokenizer_available.status,
            GatewayTrustedNumericSourceReadinessStatus::Available
        );
        assert_eq!(
            tokenizer_available.tokenizer_status,
            GatewayTrustedNumericSourceProviderReadinessStatus::Available
        );
        assert!(tokenizer_available.feature_available);
        assert!(!tokenizer_available.fallback_required);
        assert_readiness_summary(
            &tokenizer_available.safe_summary(),
            state(contract, "tokenizer_available"),
        );
        let tokenizer_available_plan = gateway_tpm_estimate_for_request(
            GatewayTpmEstimateEndpoint::OpenAiChat,
            &json!({
                "messages": [{ "content": "raw prompt must not appear in summary" }],
                "max_completion_tokens": 79
            }),
            gateway_tpm_signals_for_readiness(&tokenizer_available, &available_prompt, 256),
        );
        assert_eq!(
            tokenizer_available_plan.estimate.source,
            RateLimitTpmEstimateSource::PromptAndMaxCompletion
        );
        assert_eq!(tokenizer_available_plan.estimate.required_tokens, 400);
        assert!(!tokenizer_available_plan.estimate.used_conservative_fallback);

        let read_model_available = gateway_trusted_numeric_source_readiness(
            GatewayTrustedNumericSourceReadinessInput::new(false, false, true, true),
        );
        assert_eq!(
            read_model_available.status,
            GatewayTrustedNumericSourceReadinessStatus::Available
        );
        assert_eq!(
            read_model_available.read_model_status,
            GatewayTrustedNumericSourceProviderReadinessStatus::Available
        );
        assert!(read_model_available.feature_available);
        assert!(!read_model_available.fallback_required);
        assert_readiness_summary(
            &read_model_available.safe_summary(),
            state(contract, "read_model_available"),
        );
        let read_model_available_plan = gateway_tpm_estimate_for_request(
            GatewayTpmEstimateEndpoint::OpenAiEmbeddings,
            &json!({ "input": "raw embedding input must not appear in summary" }),
            gateway_tpm_signals_for_readiness(&read_model_available, &available_input, 256),
        );
        assert_eq!(
            read_model_available_plan.estimate.source,
            RateLimitTpmEstimateSource::TotalTokens
        );
        assert_eq!(read_model_available_plan.estimate.required_tokens, 222);
        assert!(
            !read_model_available_plan
                .estimate
                .used_conservative_fallback
        );

        let serialized = serde_json::to_string(&json!({
            "readiness": [
                disabled.safe_summary(),
                tokenizer_unavailable.safe_summary(),
                read_model_unavailable.safe_summary(),
                tokenizer_available.safe_summary(),
                read_model_available.safe_summary()
            ],
            "availability": [
                available_prompt.safe_summary(),
                available_input.safe_summary()
            ],
            "plans": [
                disabled_plan.safe_summary(),
                tokenizer_unavailable_plan.safe_summary(),
                tokenizer_available_plan.safe_summary(),
                read_model_available_plan.safe_summary()
            ]
        }))
        .expect("trusted numeric readiness summaries should serialize")
        .to_ascii_lowercase();
        for forbidden in contract["forbidden_output_markers"]
            .as_array()
            .expect("forbidden markers should be an array")
            .iter()
            .filter_map(serde_json::Value::as_str)
        {
            assert!(
                !serialized.contains(&forbidden.to_ascii_lowercase()),
                "trusted numeric source readiness output leaked forbidden marker: {forbidden}"
            );
        }
        for raw_marker in [
            "raw prompt",
            "raw response input",
            "raw embedding input",
            "request_body",
            "body_length",
            "string_length",
            "\"messages\"",
            "\"content\"",
            "\"input\"",
        ] {
            assert!(
                !serialized.contains(raw_marker),
                "trusted numeric source readiness output leaked raw marker: {raw_marker}"
            );
        }
    }

    #[test]
    fn tpm_estimate_mapper_fixture_defines_trusted_numeric_source_config_preflight_gate() {
        let fixture = fixture();
        let contract = &fixture["trusted_numeric_source_config_preflight_gate_contract"];

        assert_eq!(
            contract["schema"].as_str(),
            Some(GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_CONFIG_PREFLIGHT_SCHEMA)
        );
        assert_eq!(
            contract["implementation_status"].as_str(),
            Some(
                "config/preflight gate only; tokenizer/read-model implementations are not wired into runtime"
            )
        );
        assert_eq!(contract["runtime_wiring_changed"].as_bool(), Some(false));
        assert_eq!(contract["default_status"].as_str(), Some("disabled"));
        assert_eq!(
            contract["availability_marker"].as_str(),
            Some(GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_AVAILABILITY_MARKER)
        );
        assert_eq!(
            contract["duration_marker"].as_str(),
            Some(GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_PREFLIGHT_DURATION_MARKER)
        );

        let config_flags = contract["config_flags"]
            .as_array()
            .expect("preflight config flags should be an array");
        for flag in [
            "GATEWAY_TPM_TRUSTED_TOKENIZER_ENABLED",
            "GATEWAY_TPM_TRUSTED_READ_MODEL_ENABLED",
        ] {
            assert!(
                config_flags
                    .iter()
                    .any(|entry| entry.as_str() == Some(flag)),
                "preflight config contract should define flag: {flag}"
            );
        }

        let states = contract["states"]
            .as_array()
            .expect("preflight states should be an array");
        for required_state in [
            "default_disabled",
            "tokenizer_enabled_provider_unavailable",
            "read_model_enabled_provider_unavailable",
            "tokenizer_available_ready",
            "read_model_available_ready",
        ] {
            assert!(
                states
                    .iter()
                    .any(|state| state["name"].as_str() == Some(required_state)),
                "preflight gate contract missing state: {required_state}"
            );
        }

        let evidence_fields = contract["smoke_evidence_projection_fields"]
            .as_array()
            .expect("preflight smoke evidence projection fields should be an array");
        for field in [
            "trusted_source_preflight.schema",
            "trusted_source_preflight.status",
            "trusted_source_preflight.blocker",
            "trusted_source_preflight.feature_enabled",
            "trusted_source_preflight.feature_available",
            "trusted_source_preflight.fallback_required",
            "trusted_source_preflight.availability_marker",
            "trusted_source_preflight.duration_marker",
            "trusted_source_preflight.material_in_output",
        ] {
            assert!(
                evidence_fields
                    .iter()
                    .any(|entry| entry.as_str() == Some(field)),
                "preflight smoke evidence should include {field}"
            );
        }

        for side_effect in [
            "reservation_acquire",
            "provider_attempt",
            "provider_key_open",
            "upstream_call",
            "billing_side_effect",
        ] {
            assert_eq!(
                contract["side_effect_contract"][side_effect].as_bool(),
                Some(false),
                "preflight gate contract should not require {side_effect}"
            );
        }
    }

    #[test]
    fn tpm_estimate_mapper_trusted_numeric_source_config_preflight_controls_fallback() {
        fn state<'a>(contract: &'a serde_json::Value, name: &str) -> &'a serde_json::Value {
            contract["states"]
                .as_array()
                .expect("preflight states should be an array")
                .iter()
                .find(|state| state["name"].as_str() == Some(name))
                .unwrap_or_else(|| panic!("missing preflight state: {name}"))
        }

        fn assert_preflight_summary(
            summary: &GatewayTrustedNumericSourceConfigPreflightSummary,
            expected: &serde_json::Value,
        ) {
            assert_eq!(
                summary.schema,
                GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_CONFIG_PREFLIGHT_SCHEMA
            );
            assert_eq!(summary.status, expected["status"].as_str().unwrap());
            assert_eq!(
                summary.blocker,
                expected["blocker"].as_str().map(|blocker| match blocker {
                    "config_disabled" => "config_disabled",
                    "provider_unavailable" => "provider_unavailable",
                    other => panic!("unexpected blocker in fixture: {other}"),
                })
            );
            assert_eq!(
                summary.tokenizer_config_enabled,
                expected["tokenizer_config_enabled"].as_bool().unwrap()
            );
            assert_eq!(
                summary.read_model_config_enabled,
                expected["read_model_config_enabled"].as_bool().unwrap()
            );
            assert_eq!(
                summary.tokenizer_provider_available,
                expected["tokenizer_provider_available"].as_bool().unwrap()
            );
            assert_eq!(
                summary.read_model_provider_available,
                expected["read_model_provider_available"].as_bool().unwrap()
            );
            assert_eq!(
                summary.feature_enabled,
                expected["feature_enabled"].as_bool().unwrap()
            );
            assert_eq!(
                summary.feature_available,
                expected["feature_available"].as_bool().unwrap()
            );
            assert_eq!(
                summary.fallback_required,
                expected["fallback_required"].as_bool().unwrap()
            );
            assert_eq!(
                summary.availability_marker,
                GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_AVAILABILITY_MARKER
            );
            assert_eq!(
                summary.duration_marker,
                GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_PREFLIGHT_DURATION_MARKER
            );
            assert_eq!(
                summary.readiness_status,
                expected["readiness_status"].as_str().unwrap()
            );
            assert_eq!(
                summary.tokenizer_status,
                expected["tokenizer_status"].as_str().unwrap()
            );
            assert_eq!(
                summary.read_model_status,
                expected["read_model_status"].as_str().unwrap()
            );
            assert!(!summary.material_in_output);
        }

        let fixture = fixture();
        let contract = &fixture["trusted_numeric_source_config_preflight_gate_contract"];
        let available_prompt = gateway_trusted_numeric_source_availability_from_adapter(Some(
            GatewayTrustedNumericSourceAdapterOutput::new(
                GatewayTrustedNumericSourceType::Tokenizer,
                GatewayTrustedNumericTokenKind::PromptTokens,
                Some(321),
            ),
        ));
        let available_input = gateway_trusted_numeric_source_availability_from_adapter(Some(
            GatewayTrustedNumericSourceAdapterOutput::new(
                GatewayTrustedNumericSourceType::ReadModel,
                GatewayTrustedNumericTokenKind::InputTokens,
                Some(222),
            ),
        ));

        let disabled = gateway_trusted_numeric_source_config_preflight(
            GatewayTrustedNumericSourceConfigPreflightInput::disabled_by_default(),
        );
        assert_eq!(
            disabled.status,
            GatewayTrustedNumericSourceConfigPreflightStatus::Disabled
        );
        assert_eq!(
            disabled.blocker,
            Some(GatewayTrustedNumericSourceConfigPreflightBlocker::ConfigDisabled)
        );
        assert!(!disabled.feature_enabled);
        assert!(!disabled.feature_available);
        assert!(disabled.fallback_required);
        assert_preflight_summary(
            &disabled.safe_summary(),
            state(contract, "default_disabled"),
        );
        let disabled_plan = gateway_tpm_estimate_for_request(
            GatewayTpmEstimateEndpoint::OpenAiChat,
            &json!({
                "messages": [{ "content": "sk-live raw prompt must not influence preflight" }],
                "max_completion_tokens": 79
            }),
            gateway_tpm_signals_for_readiness(&disabled.readiness, &available_prompt, 256),
        );
        assert_eq!(
            disabled_plan.estimate.source,
            RateLimitTpmEstimateSource::PartialEstimateWithConservativeFallback
        );
        assert_eq!(disabled_plan.estimate.required_tokens, 335);
        assert!(disabled_plan.estimate.used_conservative_fallback);

        let tokenizer_blocked = gateway_trusted_numeric_source_config_preflight(
            GatewayTrustedNumericSourceConfigPreflightInput::new(true, false, false, false),
        );
        assert_eq!(
            tokenizer_blocked.status,
            GatewayTrustedNumericSourceConfigPreflightStatus::Blocked
        );
        assert_eq!(
            tokenizer_blocked.blocker,
            Some(GatewayTrustedNumericSourceConfigPreflightBlocker::ProviderUnavailable)
        );
        assert!(tokenizer_blocked.feature_enabled);
        assert!(!tokenizer_blocked.feature_available);
        assert!(tokenizer_blocked.fallback_required);
        assert_preflight_summary(
            &tokenizer_blocked.safe_summary(),
            state(contract, "tokenizer_enabled_provider_unavailable"),
        );
        let tokenizer_blocked_plan = gateway_tpm_estimate_for_request(
            GatewayTpmEstimateEndpoint::OpenAiResponses,
            &json!({
                "input": "raw response input must not influence preflight",
                "max_output_tokens": 128
            }),
            gateway_tpm_signals_for_readiness(&tokenizer_blocked.readiness, &available_prompt, 256),
        );
        assert_eq!(
            tokenizer_blocked_plan.estimate.source,
            RateLimitTpmEstimateSource::PartialEstimateWithConservativeFallback
        );
        assert_eq!(tokenizer_blocked_plan.estimate.required_tokens, 384);
        assert!(tokenizer_blocked_plan.estimate.used_conservative_fallback);

        let read_model_blocked = gateway_trusted_numeric_source_config_preflight(
            GatewayTrustedNumericSourceConfigPreflightInput::new(false, false, true, false),
        );
        assert_eq!(
            read_model_blocked.status,
            GatewayTrustedNumericSourceConfigPreflightStatus::Blocked
        );
        assert_eq!(
            read_model_blocked.blocker,
            Some(GatewayTrustedNumericSourceConfigPreflightBlocker::ProviderUnavailable)
        );
        assert_preflight_summary(
            &read_model_blocked.safe_summary(),
            state(contract, "read_model_enabled_provider_unavailable"),
        );

        let tokenizer_ready = gateway_trusted_numeric_source_config_preflight(
            GatewayTrustedNumericSourceConfigPreflightInput::new(true, true, false, false),
        );
        assert_eq!(
            tokenizer_ready.status,
            GatewayTrustedNumericSourceConfigPreflightStatus::Ready
        );
        assert_eq!(tokenizer_ready.blocker, None);
        assert!(tokenizer_ready.feature_enabled);
        assert!(tokenizer_ready.feature_available);
        assert!(!tokenizer_ready.fallback_required);
        assert_preflight_summary(
            &tokenizer_ready.safe_summary(),
            state(contract, "tokenizer_available_ready"),
        );
        let tokenizer_ready_plan = gateway_tpm_estimate_for_request(
            GatewayTpmEstimateEndpoint::OpenAiChat,
            &json!({
                "messages": [{ "content": "raw prompt must not appear in preflight summary" }],
                "max_completion_tokens": 79
            }),
            gateway_tpm_signals_for_readiness(&tokenizer_ready.readiness, &available_prompt, 256),
        );
        assert_eq!(
            tokenizer_ready_plan.estimate.source,
            RateLimitTpmEstimateSource::PromptAndMaxCompletion
        );
        assert_eq!(tokenizer_ready_plan.estimate.required_tokens, 400);
        assert!(!tokenizer_ready_plan.estimate.used_conservative_fallback);

        let read_model_ready = gateway_trusted_numeric_source_config_preflight(
            GatewayTrustedNumericSourceConfigPreflightInput::new(false, false, true, true),
        );
        assert_eq!(
            read_model_ready.status,
            GatewayTrustedNumericSourceConfigPreflightStatus::Ready
        );
        assert_eq!(read_model_ready.blocker, None);
        assert!(read_model_ready.feature_available);
        assert!(!read_model_ready.fallback_required);
        assert_preflight_summary(
            &read_model_ready.safe_summary(),
            state(contract, "read_model_available_ready"),
        );
        let read_model_ready_plan = gateway_tpm_estimate_for_request(
            GatewayTpmEstimateEndpoint::OpenAiEmbeddings,
            &json!({ "input": "raw embedding input must not appear in preflight summary" }),
            gateway_tpm_signals_for_readiness(&read_model_ready.readiness, &available_input, 256),
        );
        assert_eq!(
            read_model_ready_plan.estimate.source,
            RateLimitTpmEstimateSource::TotalTokens
        );
        assert_eq!(read_model_ready_plan.estimate.required_tokens, 222);
        assert!(!read_model_ready_plan.estimate.used_conservative_fallback);

        let serialized = serde_json::to_string(&json!({
            "preflight": [
                disabled.safe_summary(),
                tokenizer_blocked.safe_summary(),
                read_model_blocked.safe_summary(),
                tokenizer_ready.safe_summary(),
                read_model_ready.safe_summary()
            ],
            "plans": [
                disabled_plan.safe_summary(),
                tokenizer_blocked_plan.safe_summary(),
                tokenizer_ready_plan.safe_summary(),
                read_model_ready_plan.safe_summary()
            ]
        }))
        .expect("trusted numeric config preflight summaries should serialize")
        .to_ascii_lowercase();
        for forbidden in contract["forbidden_output_markers"]
            .as_array()
            .expect("forbidden markers should be an array")
            .iter()
            .filter_map(serde_json::Value::as_str)
        {
            assert!(
                !serialized.contains(&forbidden.to_ascii_lowercase()),
                "trusted numeric source config preflight output leaked forbidden marker: {forbidden}"
            );
        }
        for raw_marker in [
            "raw prompt",
            "raw response input",
            "raw embedding input",
            "request_body",
            "body_length",
            "string_length",
            "\"messages\"",
            "\"content\"",
            "\"input\"",
        ] {
            assert!(
                !serialized.contains(raw_marker),
                "trusted numeric source config preflight output leaked raw marker: {raw_marker}"
            );
        }
    }

    #[test]
    fn tpm_estimate_mapper_fixture_defines_trusted_numeric_source_runtime_adapter_boundary() {
        let fixture = fixture();
        let contract = &fixture["trusted_numeric_source_runtime_adapter_boundary_contract"];

        assert_eq!(
            contract["schema"].as_str(),
            Some(GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_RUNTIME_ADAPTER_SCHEMA)
        );
        assert_eq!(
            contract["adapter_trait"].as_str(),
            Some("GatewayTrustedNumericSourceRuntimeAdapter")
        );
        assert_eq!(
            contract["adapter_method"].as_str(),
            Some("lookup_trusted_numeric_source")
        );
        assert_eq!(
            contract["input_type"].as_str(),
            Some("GatewayTrustedNumericSourceRuntimeAdapterInput")
        );
        assert_eq!(
            contract["output_type"].as_str(),
            Some("GatewayTrustedNumericSourceRuntimeAdapterOutput")
        );

        let input_fields = contract["input_fields"]
            .as_array()
            .expect("runtime adapter input fields should be an array");
        for field in ["endpoint", "preflight", "conservative_fallback_tokens"] {
            assert!(
                input_fields
                    .iter()
                    .any(|entry| entry.as_str() == Some(field)),
                "runtime adapter input should include {field}"
            );
        }
        for field in contract["forbidden_input_fields"]
            .as_array()
            .expect("forbidden input fields should be an array")
            .iter()
            .filter_map(serde_json::Value::as_str)
        {
            assert!(
                !input_fields
                    .iter()
                    .any(|entry| entry.as_str() == Some(field)),
                "runtime adapter input must not accept raw field: {field}"
            );
        }

        for (marker_name, marker_value) in [
            (
                "availability",
                GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_AVAILABILITY_MARKER,
            ),
            (
                "preflight_duration",
                GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_PREFLIGHT_DURATION_MARKER,
            ),
            (
                "estimate_duration",
                GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_ESTIMATE_DURATION_MARKER,
            ),
            ("source", GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_TYPE_MARKER),
            (
                "token_count",
                GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_TOKEN_COUNT_MARKER,
            ),
        ] {
            assert_eq!(
                contract["marker_names"][marker_name].as_str(),
                Some(marker_value),
                "runtime adapter boundary should define marker {marker_name}"
            );
        }

        let evidence_fields = contract["evidence_fields"]
            .as_array()
            .expect("runtime adapter evidence fields should be an array");
        for field in [
            "trusted_source_adapter.status",
            "trusted_source_adapter.preflight_status",
            "trusted_source_adapter.availability_status",
            "trusted_source_adapter.source_type",
            "trusted_source_adapter.token_count",
            "trusted_source_adapter.adapter_invoked",
            "trusted_source_adapter.availability_marker",
            "trusted_source_adapter.preflight_duration_marker",
            "trusted_source_adapter.estimate_duration_marker",
            "trusted_source_adapter.source_marker",
            "trusted_source_adapter.token_count_marker",
            "trusted_source_adapter.material_in_output",
            "trusted_source_adapter.provider_side_effect_required",
        ] {
            assert!(
                evidence_fields
                    .iter()
                    .any(|entry| entry.as_str() == Some(field)),
                "runtime adapter evidence should include {field}"
            );
        }

        let states = contract["states"]
            .as_array()
            .expect("runtime adapter states should be an array");
        for required_state in [
            "disabled_skips_adapter",
            "blocked_skips_adapter",
            "ready_invokes_adapter_available",
            "ready_adapter_unavailable_blocks",
        ] {
            assert!(
                states
                    .iter()
                    .any(|state| state["name"].as_str() == Some(required_state)),
                "runtime adapter boundary missing state: {required_state}"
            );
        }

        for side_effect in [
            "reservation_acquire",
            "provider_attempt",
            "provider_key_open",
            "upstream_call",
            "billing_side_effect",
        ] {
            assert_eq!(
                contract["side_effect_contract"][side_effect].as_bool(),
                Some(false),
                "runtime adapter boundary should not require {side_effect}"
            );
        }
    }

    #[test]
    fn tpm_estimate_mapper_trusted_numeric_source_runtime_adapter_boundary_controls_invocation() {
        use std::cell::Cell;

        struct SpyAdapter {
            calls: Cell<usize>,
            availability: GatewayTrustedNumericSourceAvailability,
        }

        impl GatewayTrustedNumericSourceRuntimeAdapter for SpyAdapter {
            fn lookup_trusted_numeric_source(
                &self,
                input: GatewayTrustedNumericSourceRuntimeAdapterInput<'_>,
            ) -> GatewayTrustedNumericSourceRuntimeAdapterOutput {
                self.calls.set(self.calls.get().saturating_add(1));
                assert_eq!(input.endpoint, GatewayTpmEstimateEndpoint::OpenAiChat);
                assert_eq!(input.conservative_fallback_tokens, 256);
                GatewayTrustedNumericSourceRuntimeAdapterOutput::new(self.availability)
            }
        }

        fn state<'a>(contract: &'a serde_json::Value, name: &str) -> &'a serde_json::Value {
            contract["states"]
                .as_array()
                .expect("runtime adapter states should be an array")
                .iter()
                .find(|state| state["name"].as_str() == Some(name))
                .unwrap_or_else(|| panic!("missing runtime adapter state: {name}"))
        }

        fn assert_adapter_summary(
            summary: &GatewayTrustedNumericSourceRuntimeAdapterSummary,
            expected: &serde_json::Value,
        ) {
            assert_eq!(
                summary.schema,
                GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_RUNTIME_ADAPTER_SCHEMA
            );
            assert_eq!(summary.status, expected["status"].as_str().unwrap());
            assert_eq!(
                summary.preflight_status,
                expected["preflight_status"].as_str().unwrap()
            );
            assert_eq!(
                summary.availability_status,
                expected["availability_status"].as_str().unwrap()
            );
            assert_eq!(summary.source_type, expected["source_type"].as_str());
            assert_eq!(summary.token_kind, expected["token_kind"].as_str());
            assert_eq!(summary.token_count, expected["token_count"].as_u64());
            assert_eq!(
                summary.adapter_invoked,
                expected["adapter_invoked"].as_bool().unwrap()
            );
            assert_eq!(
                summary.fallback_required,
                expected["fallback_required"].as_bool().unwrap()
            );
            assert_eq!(
                summary.availability_marker,
                GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_AVAILABILITY_MARKER
            );
            assert_eq!(
                summary.preflight_duration_marker,
                GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_PREFLIGHT_DURATION_MARKER
            );
            assert_eq!(
                summary.estimate_duration_marker,
                GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_ESTIMATE_DURATION_MARKER
            );
            assert_eq!(
                summary.source_marker,
                GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_TYPE_MARKER
            );
            assert_eq!(
                summary.token_count_marker,
                GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_TOKEN_COUNT_MARKER
            );
            assert_eq!(
                summary.material_in_output,
                expected["material_in_output"].as_bool().unwrap()
            );
            assert_eq!(
                summary.provider_side_effect_required,
                expected["provider_side_effect_required"].as_bool().unwrap()
            );
            assert!(!summary.material_in_output);
            assert!(!summary.provider_side_effect_required);
        }

        let fixture = fixture();
        let contract = &fixture["trusted_numeric_source_runtime_adapter_boundary_contract"];
        let available_prompt = gateway_trusted_numeric_source_availability_from_adapter(Some(
            GatewayTrustedNumericSourceAdapterOutput::new(
                GatewayTrustedNumericSourceType::Tokenizer,
                GatewayTrustedNumericTokenKind::PromptTokens,
                Some(321),
            ),
        ));
        let unavailable = gateway_trusted_numeric_source_availability_from_adapter(None);
        let adapter = SpyAdapter {
            calls: Cell::new(0),
            availability: available_prompt,
        };
        let unavailable_adapter = SpyAdapter {
            calls: Cell::new(0),
            availability: unavailable,
        };

        let disabled_preflight = gateway_trusted_numeric_source_config_preflight(
            GatewayTrustedNumericSourceConfigPreflightInput::disabled_by_default(),
        );
        let disabled = gateway_trusted_numeric_source_runtime_adapter_boundary(
            GatewayTrustedNumericSourceRuntimeAdapterInput::new(
                GatewayTpmEstimateEndpoint::OpenAiChat,
                &disabled_preflight,
                256,
            ),
            Some(&adapter),
        );
        assert_eq!(
            disabled.status,
            GatewayTrustedNumericSourceRuntimeAdapterStatus::Disabled
        );
        assert_eq!(adapter.calls.get(), 0);
        assert_adapter_summary(
            &disabled.safe_summary(),
            state(contract, "disabled_skips_adapter"),
        );

        let blocked_preflight = gateway_trusted_numeric_source_config_preflight(
            GatewayTrustedNumericSourceConfigPreflightInput::new(true, false, false, false),
        );
        let blocked = gateway_trusted_numeric_source_runtime_adapter_boundary(
            GatewayTrustedNumericSourceRuntimeAdapterInput::new(
                GatewayTpmEstimateEndpoint::OpenAiChat,
                &blocked_preflight,
                256,
            ),
            Some(&adapter),
        );
        assert_eq!(
            blocked.status,
            GatewayTrustedNumericSourceRuntimeAdapterStatus::Blocked
        );
        assert_eq!(adapter.calls.get(), 0);
        assert_adapter_summary(
            &blocked.safe_summary(),
            state(contract, "blocked_skips_adapter"),
        );

        let ready_preflight = gateway_trusted_numeric_source_config_preflight(
            GatewayTrustedNumericSourceConfigPreflightInput::new(true, true, false, false),
        );
        let ready = gateway_trusted_numeric_source_runtime_adapter_boundary(
            GatewayTrustedNumericSourceRuntimeAdapterInput::new(
                GatewayTpmEstimateEndpoint::OpenAiChat,
                &ready_preflight,
                256,
            ),
            Some(&adapter),
        );
        assert_eq!(
            ready.status,
            GatewayTrustedNumericSourceRuntimeAdapterStatus::Ready
        );
        assert_eq!(adapter.calls.get(), 1);
        assert_adapter_summary(
            &ready.safe_summary(),
            state(contract, "ready_invokes_adapter_available"),
        );

        let ready_unavailable = gateway_trusted_numeric_source_runtime_adapter_boundary(
            GatewayTrustedNumericSourceRuntimeAdapterInput::new(
                GatewayTpmEstimateEndpoint::OpenAiChat,
                &ready_preflight,
                256,
            ),
            Some(&unavailable_adapter),
        );
        assert_eq!(
            ready_unavailable.status,
            GatewayTrustedNumericSourceRuntimeAdapterStatus::Blocked
        );
        assert_eq!(unavailable_adapter.calls.get(), 1);
        assert_adapter_summary(
            &ready_unavailable.safe_summary(),
            state(contract, "ready_adapter_unavailable_blocks"),
        );

        let ready_without_adapter = gateway_trusted_numeric_source_runtime_adapter_boundary(
            GatewayTrustedNumericSourceRuntimeAdapterInput::new(
                GatewayTpmEstimateEndpoint::OpenAiChat,
                &ready_preflight,
                256,
            ),
            None,
        );
        assert_eq!(
            ready_without_adapter.status,
            GatewayTrustedNumericSourceRuntimeAdapterStatus::Blocked
        );
        assert!(!ready_without_adapter.adapter_invoked);
        assert!(ready_without_adapter.fallback_required);

        let serialized = serde_json::to_string(&json!({
            "trusted_source_adapter": [
                disabled.safe_summary(),
                blocked.safe_summary(),
                ready.safe_summary(),
                ready_unavailable.safe_summary(),
                ready_without_adapter.safe_summary()
            ]
        }))
        .expect("trusted numeric runtime adapter summaries should serialize")
        .to_ascii_lowercase();
        for forbidden in contract["forbidden_output_markers"]
            .as_array()
            .expect("forbidden markers should be an array")
            .iter()
            .filter_map(serde_json::Value::as_str)
        {
            assert!(
                !serialized.contains(&forbidden.to_ascii_lowercase()),
                "trusted numeric source runtime adapter evidence leaked forbidden marker: {forbidden}"
            );
        }
    }

    #[test]
    fn tpm_estimate_mapper_fixture_defines_trusted_numeric_source_opt_in_evidence_gate() {
        let fixture = fixture();
        let contract = &fixture["trusted_numeric_source_opt_in_runtime_evidence_gate_contract"];

        assert_eq!(
            contract["schema"].as_str(),
            Some(GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_OPT_IN_EVIDENCE_SCHEMA)
        );
        assert_eq!(
            contract["implementation_status"].as_str(),
            Some(
                "opt-in evidence gate only; tokenizer/read-model implementations and live DB/provider smoke are not wired"
            )
        );
        assert_eq!(contract["runtime_wiring_changed"].as_bool(), Some(false));
        assert_eq!(
            contract["marker_names"]["availability"].as_str(),
            Some(GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_AVAILABILITY_MARKER)
        );
        assert_eq!(
            contract["marker_names"]["preflight_duration"].as_str(),
            Some(GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_PREFLIGHT_DURATION_MARKER)
        );
        assert_eq!(
            contract["marker_names"]["estimate_duration"].as_str(),
            Some(GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_ESTIMATE_DURATION_MARKER)
        );
        assert_eq!(
            contract["marker_names"]["source"].as_str(),
            Some(GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_TYPE_MARKER)
        );
        assert_eq!(
            contract["marker_names"]["token_count"].as_str(),
            Some(GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_TOKEN_COUNT_MARKER)
        );

        let fields = contract["reservation_evidence_fields"]
            .as_array()
            .expect("reservation evidence fields should be an array");
        for field in [
            "trusted_source_evidence.status",
            "trusted_source_evidence.preflight_status",
            "trusted_source_evidence.availability_status",
            "trusted_source_evidence.source_type",
            "trusted_source_evidence.token_count",
            "trusted_source_evidence.tpm_estimate_required_tokens",
            "trusted_source_evidence.required_capacity_tokens_per_minute",
            "trusted_source_evidence.acquire_tpm_required_tokens",
            "trusted_source_evidence.db_required_capacity_tokens_per_minute",
            "trusted_source_evidence.live_gap_closure_ready",
            "trusted_source_evidence.material_in_output",
        ] {
            assert!(
                fields.iter().any(|entry| entry.as_str() == Some(field)),
                "opt-in evidence contract should include {field}"
            );
        }

        let states = contract["states"]
            .as_array()
            .expect("opt-in evidence states should be an array");
        for required_state in [
            "disabled_maps_to_fallback_evidence",
            "blocked_maps_to_fallback_evidence",
            "ready_requires_available_source_and_aligned_capacities",
            "ready_with_misaligned_capacity_does_not_close_gap",
        ] {
            assert!(
                states
                    .iter()
                    .any(|state| state["name"].as_str() == Some(required_state)),
                "opt-in evidence contract missing state: {required_state}"
            );
        }

        let closure_conditions = contract["live_gap_closure_conditions"]
            .as_array()
            .expect("live gap closure conditions should be an array");
        for condition in [
            "trusted_source_evidence.status is ready",
            "trusted_source_evidence.availability_status is available",
            "trusted_source_evidence.token_count is a bounded non-negative integer",
            "trusted_source_evidence.material_in_output is false",
            "evidence is recorded after prompt-protection allow and before reservation acquire/provider side effect",
        ] {
            assert!(
                closure_conditions
                    .iter()
                    .any(|entry| entry.as_str() == Some(condition)),
                "opt-in evidence closure should require {condition}"
            );
        }

        for side_effect in [
            "reservation_acquire",
            "provider_attempt",
            "provider_key_open",
            "upstream_call",
            "billing_side_effect",
        ] {
            assert_eq!(
                contract["side_effect_contract"][side_effect].as_bool(),
                Some(false),
                "opt-in evidence gate contract should not require {side_effect}"
            );
        }
    }

    #[test]
    fn tpm_estimate_mapper_trusted_numeric_source_opt_in_evidence_maps_reservation_gap() {
        fn state<'a>(contract: &'a serde_json::Value, name: &str) -> &'a serde_json::Value {
            contract["states"]
                .as_array()
                .expect("opt-in evidence states should be an array")
                .iter()
                .find(|state| state["name"].as_str() == Some(name))
                .unwrap_or_else(|| panic!("missing opt-in evidence state: {name}"))
        }

        fn assert_evidence_summary(
            summary: &GatewayTrustedNumericSourceOptInEvidenceSummary,
            expected: &serde_json::Value,
        ) {
            assert_eq!(
                summary.schema,
                GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_OPT_IN_EVIDENCE_SCHEMA
            );
            assert_eq!(summary.status, expected["status"].as_str().unwrap());
            assert_eq!(
                summary.availability_status,
                expected["availability_status"].as_str().unwrap()
            );
            assert_eq!(
                summary.feature_enabled,
                expected["feature_enabled"].as_bool().unwrap()
            );
            assert_eq!(
                summary.feature_available,
                expected["feature_available"].as_bool().unwrap()
            );
            assert_eq!(
                summary.fallback_required,
                expected["fallback_required"].as_bool().unwrap()
            );
            assert_eq!(
                summary.capacity_evidence_aligned,
                expected["capacity_evidence_aligned"].as_bool().unwrap()
            );
            assert_eq!(
                summary.reservation_evidence_ready,
                expected["reservation_evidence_ready"].as_bool().unwrap()
            );
            assert_eq!(
                summary.live_gap_closure_ready,
                expected["live_gap_closure_ready"].as_bool().unwrap()
            );
            assert_eq!(
                summary.source_type,
                expected["source_type"]
                    .as_str()
                    .map(|source_type| match source_type {
                        "tokenizer" => "tokenizer",
                        "read_model" => "read_model",
                        other => panic!("unexpected source type in fixture: {other}"),
                    })
            );
            assert_eq!(
                summary.token_kind,
                expected["token_kind"]
                    .as_str()
                    .map(|token_kind| match token_kind {
                        "prompt_tokens" => "prompt_tokens",
                        "input_tokens" => "input_tokens",
                        other => panic!("unexpected token kind in fixture: {other}"),
                    })
            );
            assert_eq!(summary.token_count, expected["token_count"].as_u64());
            if let Some(required) = expected["tpm_estimate_required_tokens"].as_i64() {
                assert_eq!(summary.tpm_estimate_required_tokens, required);
            }
            if let Some(required) = expected["required_capacity_tokens_per_minute"].as_i64() {
                assert_eq!(summary.required_capacity_tokens_per_minute, required);
            }
            if let Some(required) = expected["acquire_tpm_required_tokens"].as_i64() {
                assert_eq!(summary.acquire_tpm_required_tokens, required);
            }
            if let Some(required) = expected["db_required_capacity_tokens_per_minute"].as_i64() {
                assert_eq!(summary.db_required_capacity_tokens_per_minute, required);
            }
            assert_eq!(
                summary.availability_marker,
                GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_AVAILABILITY_MARKER
            );
            assert_eq!(
                summary.preflight_duration_marker,
                GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_PREFLIGHT_DURATION_MARKER
            );
            assert_eq!(
                summary.estimate_duration_marker,
                GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_ESTIMATE_DURATION_MARKER
            );
            assert_eq!(
                summary.source_marker,
                GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_TYPE_MARKER
            );
            assert_eq!(
                summary.token_count_marker,
                GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_TOKEN_COUNT_MARKER
            );
            assert!(!summary.material_in_output);
        }

        let fixture = fixture();
        let contract = &fixture["trusted_numeric_source_opt_in_runtime_evidence_gate_contract"];
        let unavailable = gateway_trusted_numeric_source_availability_from_adapter(None);
        let available_prompt = gateway_trusted_numeric_source_availability_from_adapter(Some(
            GatewayTrustedNumericSourceAdapterOutput::new(
                GatewayTrustedNumericSourceType::Tokenizer,
                GatewayTrustedNumericTokenKind::PromptTokens,
                Some(321),
            ),
        ));

        let disabled_preflight = gateway_trusted_numeric_source_config_preflight(
            GatewayTrustedNumericSourceConfigPreflightInput::disabled_by_default(),
        );
        let disabled = gateway_trusted_numeric_source_opt_in_evidence(
            GatewayTrustedNumericSourceOptInEvidenceInput::new(
                &disabled_preflight,
                &unavailable,
                335,
                335,
                335,
                335,
            ),
        );
        assert_eq!(
            disabled.status,
            GatewayTrustedNumericSourceOptInEvidenceStatus::Disabled
        );
        assert!(!disabled.live_gap_closure_ready);
        assert_evidence_summary(
            &disabled.safe_summary(),
            state(contract, "disabled_maps_to_fallback_evidence"),
        );

        let blocked_preflight = gateway_trusted_numeric_source_config_preflight(
            GatewayTrustedNumericSourceConfigPreflightInput::new(true, false, false, false),
        );
        let blocked = gateway_trusted_numeric_source_opt_in_evidence(
            GatewayTrustedNumericSourceOptInEvidenceInput::new(
                &blocked_preflight,
                &unavailable,
                384,
                384,
                384,
                384,
            ),
        );
        assert_eq!(
            blocked.status,
            GatewayTrustedNumericSourceOptInEvidenceStatus::Blocked
        );
        assert!(blocked.fallback_required);
        assert!(!blocked.live_gap_closure_ready);
        assert_evidence_summary(
            &blocked.safe_summary(),
            state(contract, "blocked_maps_to_fallback_evidence"),
        );

        let ready_preflight = gateway_trusted_numeric_source_config_preflight(
            GatewayTrustedNumericSourceConfigPreflightInput::new(true, true, false, false),
        );
        let ready = gateway_trusted_numeric_source_opt_in_evidence(
            GatewayTrustedNumericSourceOptInEvidenceInput::new(
                &ready_preflight,
                &available_prompt,
                400,
                400,
                400,
                400,
            ),
        );
        assert_eq!(
            ready.status,
            GatewayTrustedNumericSourceOptInEvidenceStatus::Ready
        );
        assert!(ready.capacity_evidence_aligned);
        assert!(ready.reservation_evidence_ready);
        assert!(ready.live_gap_closure_ready);
        assert_evidence_summary(
            &ready.safe_summary(),
            state(
                contract,
                "ready_requires_available_source_and_aligned_capacities",
            ),
        );

        let misaligned = gateway_trusted_numeric_source_opt_in_evidence(
            GatewayTrustedNumericSourceOptInEvidenceInput::new(
                &ready_preflight,
                &available_prompt,
                400,
                400,
                399,
                400,
            ),
        );
        assert_eq!(
            misaligned.status,
            GatewayTrustedNumericSourceOptInEvidenceStatus::Ready
        );
        assert!(!misaligned.capacity_evidence_aligned);
        assert!(!misaligned.reservation_evidence_ready);
        assert!(!misaligned.live_gap_closure_ready);
        assert_evidence_summary(
            &misaligned.safe_summary(),
            state(
                contract,
                "ready_with_misaligned_capacity_does_not_close_gap",
            ),
        );

        let serialized = serde_json::to_string(&json!({
            "evidence": [
                disabled.safe_summary(),
                blocked.safe_summary(),
                ready.safe_summary(),
                misaligned.safe_summary()
            ]
        }))
        .expect("trusted numeric opt-in evidence summaries should serialize")
        .to_ascii_lowercase();
        for forbidden in contract["forbidden_output_markers"]
            .as_array()
            .expect("forbidden markers should be an array")
            .iter()
            .filter_map(serde_json::Value::as_str)
        {
            assert!(
                !serialized.contains(&forbidden.to_ascii_lowercase()),
                "trusted numeric source opt-in evidence output leaked forbidden marker: {forbidden}"
            );
        }
        for raw_marker in [
            "raw prompt",
            "raw response input",
            "raw embedding input",
            "request_body",
            "body_length",
            "string_length",
            "\"messages\"",
            "\"contents\"",
            "\"input\"",
        ] {
            assert!(
                !serialized.contains(raw_marker),
                "trusted numeric source opt-in evidence output leaked raw marker: {raw_marker}"
            );
        }
    }

    #[test]
    fn tpm_estimate_mapper_fixture_defines_trusted_numeric_source_reservation_projection_handoff() {
        let fixture = fixture();
        let contract = &fixture["trusted_numeric_source_reservation_projection_handoff_contract"];

        assert_eq!(
            contract["schema"].as_str(),
            Some(GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_RESERVATION_PROJECTION_SCHEMA)
        );
        assert_eq!(
            contract["implementation_status"].as_str(),
            Some(
                "projection handoff only; runtime tokenizer/read-model implementation and live DB/provider smoke are not wired"
            )
        );
        assert_eq!(contract["runtime_wiring_changed"].as_bool(), Some(false));
        assert_eq!(
            contract["metadata_path"].as_str(),
            Some("rate_limit_reservation.trusted_source_evidence")
        );
        assert_eq!(
            contract["smoke_evidence_path"].as_str(),
            Some("smoke.rate_limit_reservation.trusted_source_evidence")
        );

        let statuses = contract["projected_statuses"]
            .as_array()
            .expect("projected statuses should be an array");
        for status in ["unavailable", "blocked", "ready"] {
            assert!(
                statuses.iter().any(|entry| entry.as_str() == Some(status)),
                "projection handoff should include status: {status}"
            );
        }

        let fields = contract["required_projection_fields"]
            .as_array()
            .expect("required projection fields should be an array");
        for field in [
            "trusted_source_projection.trusted_source_evidence.availability_marker",
            "trusted_source_projection.trusted_source_evidence.preflight_duration_marker",
            "trusted_source_projection.trusted_source_evidence.estimate_duration_marker",
            "trusted_source_projection.trusted_source_evidence.source_marker",
            "trusted_source_projection.trusted_source_evidence.token_count_marker",
            "trusted_source_projection.trusted_source_evidence.required_capacity_tokens_per_minute",
            "trusted_source_projection.trusted_source_evidence.acquire_tpm_required_tokens",
            "trusted_source_projection.trusted_source_evidence.db_required_capacity_tokens_per_minute",
            "trusted_source_projection.performance_markers_present",
            "trusted_source_projection.capacity_evidence_aligned",
            "trusted_source_projection.material_in_output",
        ] {
            assert!(
                fields.iter().any(|entry| entry.as_str() == Some(field)),
                "projection handoff should require field: {field}"
            );
        }

        let states = contract["states"]
            .as_array()
            .expect("projection states should be an array");
        for required_state in [
            "disabled_projects_unavailable_fallback",
            "blocked_projects_blocker_fallback",
            "ready_projects_reservation_evidence",
            "ready_misaligned_projects_unavailable",
        ] {
            assert!(
                states
                    .iter()
                    .any(|state| state["name"].as_str() == Some(required_state)),
                "projection handoff contract missing state: {required_state}"
            );
        }

        let closure_conditions = contract["live_gap_closure_conditions"]
            .as_array()
            .expect("projection closure conditions should be an array");
        for condition in [
            "trusted_source_projection.status is ready",
            "trusted_source_projection.trusted_source_evidence.availability_status is available",
            "trusted_source_projection.trusted_source_evidence.token_count is a bounded non-negative integer",
            "trusted_source_projection.performance_markers_present is true",
            "trusted_source_projection.material_in_output is false",
            "projection is recorded after prompt-protection allow and before reservation acquire/provider side effect",
        ] {
            assert!(
                closure_conditions
                    .iter()
                    .any(|entry| entry.as_str() == Some(condition)),
                "projection closure should require {condition}"
            );
        }

        for side_effect in [
            "reservation_acquire",
            "provider_attempt",
            "provider_key_open",
            "upstream_call",
            "billing_side_effect",
        ] {
            assert_eq!(
                contract["side_effect_contract"][side_effect].as_bool(),
                Some(false),
                "projection handoff contract should not require {side_effect}"
            );
        }
    }

    #[test]
    fn tpm_estimate_mapper_trusted_numeric_source_reservation_projection_maps_smoke_evidence() {
        fn state<'a>(contract: &'a serde_json::Value, name: &str) -> &'a serde_json::Value {
            contract["states"]
                .as_array()
                .expect("projection states should be an array")
                .iter()
                .find(|state| state["name"].as_str() == Some(name))
                .unwrap_or_else(|| panic!("missing projection state: {name}"))
        }

        fn assert_projection_summary(
            summary: &GatewayTrustedNumericSourceReservationProjectionSummary,
            expected: &serde_json::Value,
        ) {
            assert_eq!(
                summary.schema,
                GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_RESERVATION_PROJECTION_SCHEMA
            );
            assert_eq!(summary.status, expected["status"].as_str().unwrap());
            assert_eq!(
                summary.rate_limit_metadata_path,
                "rate_limit_reservation.trusted_source_evidence"
            );
            assert_eq!(
                summary.smoke_evidence_path,
                "smoke.rate_limit_reservation.trusted_source_evidence"
            );
            assert_eq!(
                summary.availability_marker,
                GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_AVAILABILITY_MARKER
            );
            assert_eq!(
                summary.preflight_duration_marker,
                GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_PREFLIGHT_DURATION_MARKER
            );
            assert_eq!(
                summary.estimate_duration_marker,
                GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_ESTIMATE_DURATION_MARKER
            );
            assert_eq!(
                summary.source_marker,
                GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_TYPE_MARKER
            );
            assert_eq!(
                summary.token_count_marker,
                GATEWAY_TPM_TRUSTED_NUMERIC_SOURCE_TOKEN_COUNT_MARKER
            );
            assert_eq!(
                summary.projection_ready,
                expected["projection_ready"].as_bool().unwrap()
            );
            assert_eq!(
                summary.performance_markers_present,
                expected["performance_markers_present"].as_bool().unwrap()
            );
            assert_eq!(
                summary.capacity_evidence_aligned,
                expected["capacity_evidence_aligned"].as_bool().unwrap()
            );
            assert_eq!(
                summary.trusted_source_evidence.live_gap_closure_ready,
                expected["live_gap_closure_ready"].as_bool().unwrap()
            );
            assert!(!summary.material_in_output);
            assert!(!summary.trusted_source_evidence.material_in_output);
        }

        let fixture = fixture();
        let contract = &fixture["trusted_numeric_source_reservation_projection_handoff_contract"];
        let unavailable = gateway_trusted_numeric_source_availability_from_adapter(None);
        let available_prompt = gateway_trusted_numeric_source_availability_from_adapter(Some(
            GatewayTrustedNumericSourceAdapterOutput::new(
                GatewayTrustedNumericSourceType::Tokenizer,
                GatewayTrustedNumericTokenKind::PromptTokens,
                Some(321),
            ),
        ));

        let disabled_preflight = gateway_trusted_numeric_source_config_preflight(
            GatewayTrustedNumericSourceConfigPreflightInput::disabled_by_default(),
        );
        let disabled_evidence = gateway_trusted_numeric_source_opt_in_evidence(
            GatewayTrustedNumericSourceOptInEvidenceInput::new(
                &disabled_preflight,
                &unavailable,
                335,
                335,
                335,
                335,
            ),
        );
        let disabled_projection =
            gateway_trusted_numeric_source_reservation_projection(&disabled_evidence);
        assert_eq!(
            disabled_projection.status,
            GatewayTrustedNumericSourceReservationProjectionStatus::Unavailable
        );
        assert!(!disabled_projection.projection_ready);
        assert_projection_summary(
            &disabled_projection.safe_summary(),
            state(contract, "disabled_projects_unavailable_fallback"),
        );

        let blocked_preflight = gateway_trusted_numeric_source_config_preflight(
            GatewayTrustedNumericSourceConfigPreflightInput::new(true, false, false, false),
        );
        let blocked_evidence = gateway_trusted_numeric_source_opt_in_evidence(
            GatewayTrustedNumericSourceOptInEvidenceInput::new(
                &blocked_preflight,
                &unavailable,
                384,
                384,
                384,
                384,
            ),
        );
        let blocked_projection =
            gateway_trusted_numeric_source_reservation_projection(&blocked_evidence);
        assert_eq!(
            blocked_projection.status,
            GatewayTrustedNumericSourceReservationProjectionStatus::Blocked
        );
        assert!(!blocked_projection.projection_ready);
        assert_projection_summary(
            &blocked_projection.safe_summary(),
            state(contract, "blocked_projects_blocker_fallback"),
        );

        let ready_preflight = gateway_trusted_numeric_source_config_preflight(
            GatewayTrustedNumericSourceConfigPreflightInput::new(true, true, false, false),
        );
        let ready_evidence = gateway_trusted_numeric_source_opt_in_evidence(
            GatewayTrustedNumericSourceOptInEvidenceInput::new(
                &ready_preflight,
                &available_prompt,
                400,
                400,
                400,
                400,
            ),
        );
        let ready_projection =
            gateway_trusted_numeric_source_reservation_projection(&ready_evidence);
        assert_eq!(
            ready_projection.status,
            GatewayTrustedNumericSourceReservationProjectionStatus::Ready
        );
        assert!(ready_projection.projection_ready);
        assert!(ready_projection.performance_markers_present);
        assert!(ready_projection.capacity_evidence_aligned);
        assert_projection_summary(
            &ready_projection.safe_summary(),
            state(contract, "ready_projects_reservation_evidence"),
        );

        let misaligned_evidence = gateway_trusted_numeric_source_opt_in_evidence(
            GatewayTrustedNumericSourceOptInEvidenceInput::new(
                &ready_preflight,
                &available_prompt,
                400,
                400,
                399,
                400,
            ),
        );
        let misaligned_projection =
            gateway_trusted_numeric_source_reservation_projection(&misaligned_evidence);
        assert_eq!(
            misaligned_projection.status,
            GatewayTrustedNumericSourceReservationProjectionStatus::Unavailable
        );
        assert!(!misaligned_projection.projection_ready);
        assert!(!misaligned_projection.capacity_evidence_aligned);
        assert_projection_summary(
            &misaligned_projection.safe_summary(),
            state(contract, "ready_misaligned_projects_unavailable"),
        );

        let serialized = serde_json::to_string(&json!({
            "trusted_source_projection": [
                disabled_projection.safe_summary(),
                blocked_projection.safe_summary(),
                ready_projection.safe_summary(),
                misaligned_projection.safe_summary()
            ]
        }))
        .expect("trusted numeric reservation projection summaries should serialize")
        .to_ascii_lowercase();
        for forbidden in contract["forbidden_output_markers"]
            .as_array()
            .expect("forbidden markers should be an array")
            .iter()
            .filter_map(serde_json::Value::as_str)
        {
            assert!(
                !serialized.contains(&forbidden.to_ascii_lowercase()),
                "trusted numeric source reservation projection leaked forbidden marker: {forbidden}"
            );
        }
        for raw_marker in [
            "raw prompt",
            "raw response input",
            "raw embedding input",
            "request_body",
            "body_length",
            "string_length",
            "\"messages\"",
            "\"contents\"",
            "\"input\"",
        ] {
            assert!(
                !serialized.contains(raw_marker),
                "trusted numeric source reservation projection leaked raw marker: {raw_marker}"
            );
        }
    }

    #[test]
    fn tpm_estimate_mapper_fixture_defines_trusted_numeric_source_adapter_boundary() {
        let fixture = fixture();
        let contract = &fixture["trusted_numeric_source_adapter_boundary_contract"];

        assert_eq!(
            contract["schema"].as_str(),
            Some("gateway_tpm_trusted_numeric_source_adapter_boundary_v1")
        );
        assert_eq!(
            contract["implementation_status"].as_str(),
            Some("adapter boundary only; tokenizer/read-model adapters are not wired into runtime")
        );
        assert_eq!(
            contract["adapter_output_type"].as_str(),
            Some("GatewayTrustedNumericSourceAdapterOutput")
        );
        assert_eq!(
            contract["adapter_to_availability_helper"].as_str(),
            Some("gateway_trusted_numeric_source_availability_from_adapter(")
        );
        assert_eq!(contract["raw_material_accepted"].as_bool(), Some(false));
        assert_eq!(contract["raw_material_emitted"].as_bool(), Some(false));
        assert_eq!(
            contract["provider_side_effect_required"].as_bool(),
            Some(false)
        );
        assert_eq!(contract["runtime_wiring_changed"].as_bool(), Some(false));

        let source = include_str!("tpm_estimate.rs");
        for helper in contract["required_helper_pipeline"]
            .as_array()
            .expect("required helper pipeline should be an array")
            .iter()
            .filter_map(serde_json::Value::as_str)
        {
            assert!(
                source.contains(helper),
                "adapter boundary should expose required helper pipeline marker: {helper}"
            );
        }

        for source_type in contract["allowed_source_types"]
            .as_array()
            .expect("allowed source types should be an array")
            .iter()
            .filter_map(serde_json::Value::as_str)
        {
            assert!(
                GatewayTrustedNumericSourceType::from_str(source_type).is_some(),
                "adapter boundary should allow trusted source type: {source_type}"
            );
        }
        for source_type in contract["forbidden_source_types"]
            .as_array()
            .expect("forbidden source types should be an array")
            .iter()
            .filter_map(serde_json::Value::as_str)
        {
            assert!(
                GatewayTrustedNumericSourceType::from_str(source_type).is_none(),
                "adapter boundary must reject raw source type: {source_type}"
            );
        }

        let states = contract["states"]
            .as_array()
            .expect("adapter states should be an array");
        for required_state in [
            "adapter_unavailable",
            "adapter_available_tokenizer_prompt",
            "adapter_available_read_model_input",
            "adapter_invalid_negative_tokens",
            "raw_source_rejected_before_adapter_boundary",
        ] {
            assert!(
                states
                    .iter()
                    .any(|state| state["name"].as_str() == Some(required_state)),
                "adapter boundary contract missing state: {required_state}"
            );
        }
    }

    #[test]
    fn tpm_estimate_mapper_trusted_numeric_source_adapter_boundary_controls_signals() {
        let fixture = fixture();
        let contract = &fixture["trusted_numeric_source_adapter_boundary_contract"];

        let unavailable = gateway_trusted_numeric_source_availability_from_adapter(None);
        assert_eq!(
            unavailable.status,
            GatewayTrustedNumericSourceAvailabilityStatus::Unavailable
        );
        assert!(unavailable.fallback_required);
        let unavailable_plan = gateway_tpm_estimate_for_request(
            GatewayTpmEstimateEndpoint::OpenAiChat,
            &json!({
                "messages": [{ "content": "sk-live-secret raw prompt" }],
                "max_completion_tokens": 128
            }),
            gateway_tpm_signals_from_trusted_numeric_source(&unavailable, 256),
        );
        assert_eq!(
            unavailable_plan.estimate.source,
            RateLimitTpmEstimateSource::PartialEstimateWithConservativeFallback
        );
        assert_eq!(unavailable_plan.estimate.required_tokens, 384);
        assert!(unavailable_plan.estimate.used_conservative_fallback);

        let tokenizer_prompt = gateway_trusted_numeric_source_availability_from_adapter(Some(
            GatewayTrustedNumericSourceAdapterOutput::new(
                GatewayTrustedNumericSourceType::Tokenizer,
                GatewayTrustedNumericTokenKind::PromptTokens,
                Some(321),
            ),
        ));
        let tokenizer_prompt_plan = gateway_tpm_estimate_for_request(
            GatewayTpmEstimateEndpoint::OpenAiChat,
            &json!({
                "messages": [{ "content": "raw prompt must not appear" }],
                "headers": { "Authorization": "Bearer sk-live-secret" },
                "max_completion_tokens": 79
            }),
            gateway_tpm_signals_from_trusted_numeric_source(&tokenizer_prompt, 256),
        );
        assert_eq!(
            tokenizer_prompt.status,
            GatewayTrustedNumericSourceAvailabilityStatus::Available
        );
        assert_eq!(
            tokenizer_prompt.source_type,
            Some(GatewayTrustedNumericSourceType::Tokenizer)
        );
        assert_eq!(tokenizer_prompt.tokens, Some(321));
        assert!(!tokenizer_prompt.fallback_required);
        assert_eq!(
            tokenizer_prompt_plan.estimate.source,
            RateLimitTpmEstimateSource::PromptAndMaxCompletion
        );
        assert_eq!(tokenizer_prompt_plan.estimate.required_tokens, 400);
        assert!(!tokenizer_prompt_plan.estimate.used_conservative_fallback);

        let read_model_input = gateway_trusted_numeric_source_availability_from_adapter(Some(
            GatewayTrustedNumericSourceAdapterOutput::new(
                GatewayTrustedNumericSourceType::ReadModel,
                GatewayTrustedNumericTokenKind::InputTokens,
                Some(222),
            ),
        ));
        let read_model_input_plan = gateway_tpm_estimate_for_request(
            GatewayTpmEstimateEndpoint::OpenAiEmbeddings,
            &json!({ "input": "sk-live-secret raw embedding input" }),
            gateway_tpm_signals_from_trusted_numeric_source(&read_model_input, 256),
        );
        assert_eq!(
            read_model_input.status,
            GatewayTrustedNumericSourceAvailabilityStatus::Available
        );
        assert_eq!(
            read_model_input.source_type,
            Some(GatewayTrustedNumericSourceType::ReadModel)
        );
        assert_eq!(
            read_model_input_plan.estimate.source,
            RateLimitTpmEstimateSource::TotalTokens
        );
        assert_eq!(read_model_input_plan.estimate.required_tokens, 222);
        assert!(!read_model_input_plan.estimate.used_conservative_fallback);

        let invalid_negative = gateway_trusted_numeric_source_availability_from_adapter(Some(
            GatewayTrustedNumericSourceAdapterOutput::new(
                GatewayTrustedNumericSourceType::ReadModel,
                GatewayTrustedNumericTokenKind::InputTokens,
                Some(-7),
            ),
        ));
        let invalid_negative_plan = gateway_tpm_estimate_for_request(
            GatewayTpmEstimateEndpoint::OpenAiEmbeddings,
            &json!({ "input": "raw negative input must not appear" }),
            gateway_tpm_signals_from_trusted_numeric_source(&invalid_negative, 256),
        );
        assert_eq!(
            invalid_negative.status,
            GatewayTrustedNumericSourceAvailabilityStatus::Invalid
        );
        assert_eq!(
            invalid_negative.invalid_reason,
            Some(GatewayTrustedNumericSourceInvalidReason::NegativeTokens)
        );
        assert!(invalid_negative.fallback_required);
        assert_eq!(
            invalid_negative_plan.estimate.source,
            RateLimitTpmEstimateSource::ConservativeFallback
        );
        assert_eq!(invalid_negative_plan.estimate.required_tokens, 256);
        assert!(invalid_negative_plan.estimate.used_conservative_fallback);

        let raw_source_candidate = gateway_trusted_numeric_source_availability(Some(
            GatewayTrustedNumericSourceCandidate::new(
                "request_body",
                GatewayTrustedNumericTokenKind::PromptTokens,
                Some(9_999),
            ),
        ));
        assert_eq!(
            raw_source_candidate.status,
            GatewayTrustedNumericSourceAvailabilityStatus::Invalid
        );
        assert_eq!(
            raw_source_candidate.invalid_reason,
            Some(GatewayTrustedNumericSourceInvalidReason::SourceTypeNotAllowed)
        );
        assert!(raw_source_candidate.fallback_required);

        let serialized = serde_json::to_string(&json!({
            "availability": [
                unavailable.safe_summary(),
                tokenizer_prompt.safe_summary(),
                read_model_input.safe_summary(),
                invalid_negative.safe_summary(),
                raw_source_candidate.safe_summary()
            ],
            "plans": [
                unavailable_plan.safe_summary(),
                tokenizer_prompt_plan.safe_summary(),
                read_model_input_plan.safe_summary(),
                invalid_negative_plan.safe_summary()
            ]
        }))
        .expect("adapter boundary summaries should serialize")
        .to_ascii_lowercase();
        for forbidden in contract["forbidden_output_markers"]
            .as_array()
            .expect("forbidden output markers should be an array")
            .iter()
            .filter_map(serde_json::Value::as_str)
        {
            assert!(
                !serialized.contains(&forbidden.to_ascii_lowercase()),
                "adapter boundary output leaked forbidden marker: {forbidden}"
            );
        }
        for raw_marker in [
            "raw prompt",
            "raw embedding input",
            "raw negative input",
            "\"headers\"",
            "\"messages\"",
            "\"content\"",
        ] {
            assert!(
                !serialized.contains(raw_marker),
                "adapter boundary output leaked raw marker: {raw_marker}"
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
