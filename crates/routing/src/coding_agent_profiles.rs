use crate::candidate_generation::{CanonicalModelVisibility, ProfileRouteConstraints};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum CodingAgentProfileKind {
    Codex,
    ClaudeCode,
    Opencode,
}

impl CodingAgentProfileKind {
    pub fn parse(value: impl AsRef<str>) -> Option<Self> {
        let normalized = value
            .as_ref()
            .trim()
            .to_ascii_lowercase()
            .replace(['_', ' '], "-");

        match normalized.as_str() {
            "codex" | "openai-codex" => Some(Self::Codex),
            "claude-code" | "claudecode" | "anthropic-claude-code" => Some(Self::ClaudeCode),
            "opencode" | "open-code" => Some(Self::Opencode),
            _ => None,
        }
    }

    pub const fn stable_key(self) -> &'static str {
        match self {
            Self::Codex => "codex",
            Self::ClaudeCode => "claude-code",
            Self::Opencode => "opencode",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CodingAgentModelAliasPurpose {
    Balanced,
    LowLatency,
    LargeContext,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CodingAgentModelAliasRecommendation {
    pub alias: String,
    pub canonical_model: String,
    pub purpose: CodingAgentModelAliasPurpose,
}

impl CodingAgentModelAliasRecommendation {
    pub fn new(
        alias: impl Into<String>,
        canonical_model: impl Into<String>,
        purpose: CodingAgentModelAliasPurpose,
    ) -> Self {
        Self {
            alias: alias.into(),
            canonical_model: canonical_model.into(),
            purpose,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CodingAgentPreference {
    Required,
    Preferred,
    Optional,
    Unsupported,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CodingAgentStreamingPreference {
    Required,
    Preferred,
    Optional,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CodingAgentLargeContextPreference {
    Required,
    Preferred,
    Optional,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct CodingAgentToolFunctionSupportExpectation {
    pub tool_calls: CodingAgentPreference,
    pub function_calling: CodingAgentPreference,
    pub parallel_tool_calls: CodingAgentPreference,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CodingAgentPayloadPolicyExpectation {
    MetadataOnly,
    HashOnly,
    RedactedPreview,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CodingAgentFallbackPolicy {
    pub allowed: bool,
    pub same_provider_first: bool,
    pub cross_provider_allowed: bool,
    pub preserve_streaming_preference: bool,
    pub preserve_tool_support: bool,
    pub max_attempts: u8,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CodingAgentChannelTagPreference {
    pub required_any: Vec<String>,
    pub preferred: Vec<String>,
    pub denied: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CodingAgentProfilePlan {
    pub kind: CodingAgentProfileKind,
    pub recommended_model_aliases: Vec<CodingAgentModelAliasRecommendation>,
    pub streaming_preference: CodingAgentStreamingPreference,
    pub tool_support_expectation: CodingAgentToolFunctionSupportExpectation,
    pub large_context_preference: CodingAgentLargeContextPreference,
    pub fallback_policy: CodingAgentFallbackPolicy,
    pub channel_tag_preference: CodingAgentChannelTagPreference,
    pub payload_policy_expectation: CodingAgentPayloadPolicyExpectation,
}

impl CodingAgentProfilePlan {
    pub fn to_profile_route_constraints(&self) -> ProfileRouteConstraints {
        let mut constraints = ProfileRouteConstraints::unrestricted()
            .with_visible_model_visibility(CanonicalModelVisibility::Public)
            .with_visible_model_visibility(CanonicalModelVisibility::Internal);

        for alias in &self.recommended_model_aliases {
            push_unique_non_empty(&mut constraints.allowed_models, &alias.canonical_model);
        }

        for tag in &self.channel_tag_preference.required_any {
            push_unique_non_empty(&mut constraints.allowed_channel_tags, tag);
        }

        for tag in &self.channel_tag_preference.denied {
            push_unique_non_empty(&mut constraints.denied_channel_tags, tag);
        }

        constraints
    }

    pub fn route_policy_summary(&self) -> CodingAgentRoutePolicySummary {
        let constraints = self.to_profile_route_constraints();

        CodingAgentRoutePolicySummary {
            kind: self.kind,
            recommended_aliases: self
                .recommended_model_aliases
                .iter()
                .map(|alias| alias.alias.clone())
                .collect(),
            allowed_models: constraints.allowed_models,
            visible_model_visibilities: constraints.visible_model_visibilities,
            allowed_channel_tags: constraints.allowed_channel_tags,
            preferred_channel_tags: self.channel_tag_preference.preferred.clone(),
            denied_channel_tags: constraints.denied_channel_tags,
            streaming_preference: self.streaming_preference,
            tool_support_expectation: self.tool_support_expectation,
            large_context_preference: self.large_context_preference,
            fallback_policy: self.fallback_policy.clone(),
            payload_policy_expectation: self.payload_policy_expectation,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CodingAgentRoutePolicySummary {
    pub kind: CodingAgentProfileKind,
    pub recommended_aliases: Vec<String>,
    pub allowed_models: Vec<String>,
    pub visible_model_visibilities: Vec<CanonicalModelVisibility>,
    pub allowed_channel_tags: Vec<String>,
    pub preferred_channel_tags: Vec<String>,
    pub denied_channel_tags: Vec<String>,
    pub streaming_preference: CodingAgentStreamingPreference,
    pub tool_support_expectation: CodingAgentToolFunctionSupportExpectation,
    pub large_context_preference: CodingAgentLargeContextPreference,
    pub fallback_policy: CodingAgentFallbackPolicy,
    pub payload_policy_expectation: CodingAgentPayloadPolicyExpectation,
}

pub fn coding_agent_profile_plan(kind: CodingAgentProfileKind) -> CodingAgentProfilePlan {
    match kind {
        CodingAgentProfileKind::Codex => CodingAgentProfilePlan {
            kind,
            recommended_model_aliases: vec![
                CodingAgentModelAliasRecommendation::new(
                    "codex/default",
                    "coding-agent/codex-balanced",
                    CodingAgentModelAliasPurpose::Balanced,
                ),
                CodingAgentModelAliasRecommendation::new(
                    "codex/fast",
                    "coding-agent/codex-fast",
                    CodingAgentModelAliasPurpose::LowLatency,
                ),
                CodingAgentModelAliasRecommendation::new(
                    "codex/large-context",
                    "coding-agent/codex-large-context",
                    CodingAgentModelAliasPurpose::LargeContext,
                ),
            ],
            streaming_preference: CodingAgentStreamingPreference::Preferred,
            tool_support_expectation: CodingAgentToolFunctionSupportExpectation {
                tool_calls: CodingAgentPreference::Required,
                function_calling: CodingAgentPreference::Preferred,
                parallel_tool_calls: CodingAgentPreference::Preferred,
            },
            large_context_preference: CodingAgentLargeContextPreference::Preferred,
            fallback_policy: fallback_policy(3, true, true, true),
            channel_tag_preference: CodingAgentChannelTagPreference {
                required_any: strings(["coding-agent", "codex"]),
                preferred: strings(["streaming", "tool-calls", "large-context"]),
                denied: strings(["batch-only", "no-tools"]),
            },
            payload_policy_expectation: CodingAgentPayloadPolicyExpectation::RedactedPreview,
        },
        CodingAgentProfileKind::ClaudeCode => CodingAgentProfilePlan {
            kind,
            recommended_model_aliases: vec![
                CodingAgentModelAliasRecommendation::new(
                    "claude-code/default",
                    "coding-agent/claude-code-balanced",
                    CodingAgentModelAliasPurpose::Balanced,
                ),
                CodingAgentModelAliasRecommendation::new(
                    "claude-code/fast",
                    "coding-agent/claude-code-fast",
                    CodingAgentModelAliasPurpose::LowLatency,
                ),
                CodingAgentModelAliasRecommendation::new(
                    "claude-code/large-context",
                    "coding-agent/claude-code-large-context",
                    CodingAgentModelAliasPurpose::LargeContext,
                ),
            ],
            streaming_preference: CodingAgentStreamingPreference::Required,
            tool_support_expectation: CodingAgentToolFunctionSupportExpectation {
                tool_calls: CodingAgentPreference::Required,
                function_calling: CodingAgentPreference::Optional,
                parallel_tool_calls: CodingAgentPreference::Preferred,
            },
            large_context_preference: CodingAgentLargeContextPreference::Required,
            fallback_policy: fallback_policy(2, true, false, true),
            channel_tag_preference: CodingAgentChannelTagPreference {
                required_any: strings(["coding-agent", "claude-code"]),
                preferred: strings(["anthropic-tools", "streaming", "large-context"]),
                denied: strings(["no-tools", "non-streaming"]),
            },
            payload_policy_expectation: CodingAgentPayloadPolicyExpectation::RedactedPreview,
        },
        CodingAgentProfileKind::Opencode => CodingAgentProfilePlan {
            kind,
            recommended_model_aliases: vec![
                CodingAgentModelAliasRecommendation::new(
                    "opencode/default",
                    "coding-agent/opencode-balanced",
                    CodingAgentModelAliasPurpose::Balanced,
                ),
                CodingAgentModelAliasRecommendation::new(
                    "opencode/fast",
                    "coding-agent/opencode-fast",
                    CodingAgentModelAliasPurpose::LowLatency,
                ),
                CodingAgentModelAliasRecommendation::new(
                    "opencode/large-context",
                    "coding-agent/opencode-large-context",
                    CodingAgentModelAliasPurpose::LargeContext,
                ),
            ],
            streaming_preference: CodingAgentStreamingPreference::Preferred,
            tool_support_expectation: CodingAgentToolFunctionSupportExpectation {
                tool_calls: CodingAgentPreference::Preferred,
                function_calling: CodingAgentPreference::Required,
                parallel_tool_calls: CodingAgentPreference::Optional,
            },
            large_context_preference: CodingAgentLargeContextPreference::Preferred,
            fallback_policy: fallback_policy(3, false, true, true),
            channel_tag_preference: CodingAgentChannelTagPreference {
                required_any: strings(["coding-agent", "opencode"]),
                preferred: strings(["function-calling", "openai-compatible", "large-context"]),
                denied: strings(["batch-only", "no-functions"]),
            },
            payload_policy_expectation: CodingAgentPayloadPolicyExpectation::HashOnly,
        },
    }
}

pub fn coding_agent_profile_plan_from_kind(
    kind: impl AsRef<str>,
) -> Option<CodingAgentProfilePlan> {
    CodingAgentProfileKind::parse(kind).map(coding_agent_profile_plan)
}

pub fn coding_agent_profile_route_constraints(
    kind: CodingAgentProfileKind,
) -> ProfileRouteConstraints {
    coding_agent_profile_plan(kind).to_profile_route_constraints()
}

pub fn supported_coding_agent_profile_kinds() -> [CodingAgentProfileKind; 3] {
    [
        CodingAgentProfileKind::Codex,
        CodingAgentProfileKind::ClaudeCode,
        CodingAgentProfileKind::Opencode,
    ]
}

fn fallback_policy(
    max_attempts: u8,
    same_provider_first: bool,
    cross_provider_allowed: bool,
    preserve_streaming_preference: bool,
) -> CodingAgentFallbackPolicy {
    CodingAgentFallbackPolicy {
        allowed: max_attempts > 1,
        same_provider_first,
        cross_provider_allowed,
        preserve_streaming_preference,
        preserve_tool_support: true,
        max_attempts,
    }
}

fn strings<const N: usize>(values: [&str; N]) -> Vec<String> {
    values.iter().map(|value| (*value).to_owned()).collect()
}

fn push_unique_non_empty(values: &mut Vec<String>, value: &str) {
    let value = value.trim();
    if !value.is_empty() && !values.iter().any(|existing| existing == value) {
        values.push(value.to_owned());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;

    #[derive(Debug, Deserialize)]
    struct CodingAgentProfilesContractFixture {
        #[allow(dead_code)]
        scenario: String,
        #[allow(dead_code)]
        #[serde(rename = "crate")]
        crate_name: String,
        #[allow(dead_code)]
        function: String,
        scenarios: Vec<CodingAgentProfileContractScenario>,
    }

    #[derive(Debug, Deserialize)]
    struct CodingAgentProfileContractScenario {
        kind: CodingAgentProfileKind,
        expected_plan: CodingAgentProfilePlan,
        expected_route_constraints: ProfileRouteConstraints,
        expected_route_policy_summary: CodingAgentRoutePolicySummary,
    }

    #[test]
    fn parses_stable_profile_kind_aliases() {
        assert_eq!(
            CodingAgentProfileKind::parse("codex"),
            Some(CodingAgentProfileKind::Codex)
        );
        assert_eq!(
            CodingAgentProfileKind::parse("claude_code"),
            Some(CodingAgentProfileKind::ClaudeCode)
        );
        assert_eq!(
            CodingAgentProfileKind::parse("open-code"),
            Some(CodingAgentProfileKind::Opencode)
        );
        assert_eq!(CodingAgentProfileKind::parse("unknown"), None);
    }

    #[test]
    fn plan_converts_to_route_constraints_without_runtime_state() {
        let plan = coding_agent_profile_plan(CodingAgentProfileKind::Codex);
        let constraints = plan.to_profile_route_constraints();

        assert_eq!(
            constraints.visible_model_visibilities,
            [
                CanonicalModelVisibility::Public,
                CanonicalModelVisibility::Internal
            ]
        );
        assert_eq!(
            constraints.allowed_models,
            [
                "coding-agent/codex-balanced",
                "coding-agent/codex-fast",
                "coding-agent/codex-large-context"
            ]
        );
        assert_eq!(constraints.allowed_channel_tags, ["coding-agent", "codex"]);
        assert_eq!(constraints.denied_channel_tags, ["batch-only", "no-tools"]);
        assert!(constraints.blocked_provider_ids.is_empty());
    }

    #[test]
    fn route_policy_summary_retains_profile_expectations() {
        let summary =
            coding_agent_profile_plan(CodingAgentProfileKind::ClaudeCode).route_policy_summary();

        assert_eq!(summary.kind, CodingAgentProfileKind::ClaudeCode);
        assert_eq!(
            summary.streaming_preference,
            CodingAgentStreamingPreference::Required
        );
        assert_eq!(
            summary.large_context_preference,
            CodingAgentLargeContextPreference::Required
        );
        assert_eq!(
            summary.tool_support_expectation.tool_calls,
            CodingAgentPreference::Required
        );
        assert!(!summary.fallback_policy.cross_provider_allowed);
        assert_eq!(summary.fallback_policy.max_attempts, 2);
    }

    #[test]
    fn coding_agent_profile_fixture_contract_is_stable() {
        let fixture: CodingAgentProfilesContractFixture = serde_json::from_str(include_str!(
            "../../../tests/fixtures/routing/coding_agent_profiles_contract.json"
        ))
        .expect("coding agent profile fixture should be valid");

        for scenario in fixture.scenarios {
            let plan = coding_agent_profile_plan(scenario.kind);

            assert_eq!(plan, scenario.expected_plan);
            assert_eq!(
                plan.to_profile_route_constraints(),
                scenario.expected_route_constraints
            );
            assert_eq!(
                plan.route_policy_summary(),
                scenario.expected_route_policy_summary
            );
        }
    }

    #[test]
    fn coding_agent_profile_fixture_and_outputs_omit_sensitive_material() {
        let fixture =
            include_str!("../../../tests/fixtures/routing/coding_agent_profiles_contract.json");
        assert_no_sensitive_material(fixture);

        for kind in supported_coding_agent_profile_kinds() {
            let plan = coding_agent_profile_plan(kind);
            let serialized = serde_json::to_string(&plan).expect("plan should serialize");
            assert_no_sensitive_material(&serialized);

            let summary = plan.route_policy_summary();
            let serialized = serde_json::to_string(&summary).expect("summary should serialize");
            assert_no_sensitive_material(&serialized);
        }
    }

    fn assert_no_sensitive_material(value: &str) {
        let lower = value.to_ascii_lowercase();

        for forbidden in [
            "authorization",
            "bearer",
            "secret",
            "api_key",
            "api key",
            "provider_key",
            "provider key",
            "raw_prompt",
            "raw prompt",
            "raw_payload",
            "raw payload",
        ] {
            assert!(
                !lower.contains(forbidden),
                "coding agent profile contract should omit sensitive material: {forbidden}"
            );
        }
    }
}
