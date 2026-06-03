use crate::model_mapping::{ChannelModelMappingPolicy, map_upstream_model_name};
use crate::selection::{
    CandidateFilterReason, ChannelHealth, ChannelStatus, EvaluatedCandidate, RouteCandidate,
    selection_filter_reason_for,
};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::cmp::Ordering;

pub const ROUTE_PRIORITY_ASSOCIATION_MULTIPLIER: i32 = 1_000_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CanonicalModelStatus {
    Active,
    Deprecated,
    Disabled,
    Deleted,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CanonicalModelVisibility {
    Public,
    Internal,
    Hidden,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CanonicalModelRouteInput {
    pub id: String,
    pub model_key: String,
    pub status: CanonicalModelStatus,
    pub visibility: CanonicalModelVisibility,
}

impl CanonicalModelRouteInput {
    pub fn new(id: impl Into<String>, model_key: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            model_key: model_key.into(),
            status: CanonicalModelStatus::Active,
            visibility: CanonicalModelVisibility::Internal,
        }
    }

    pub const fn with_status(mut self, status: CanonicalModelStatus) -> Self {
        self.status = status;
        self
    }

    pub const fn with_visibility(mut self, visibility: CanonicalModelVisibility) -> Self {
        self.visibility = visibility;
        self
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ModelAssociationStatus {
    Enabled,
    Disabled,
    Deleted,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ModelAssociationType {
    ExplicitChannel,
    ChannelTag,
    ModelPattern,
    Global,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ModelAssociationTarget {
    ExplicitChannel { channel_id: String },
    ChannelTag { tag: String },
    ModelPattern { pattern: String },
    Global,
}

impl ModelAssociationTarget {
    pub fn association_type(&self) -> ModelAssociationType {
        match self {
            Self::ExplicitChannel { .. } => ModelAssociationType::ExplicitChannel,
            Self::ChannelTag { .. } => ModelAssociationType::ChannelTag,
            Self::ModelPattern { .. } => ModelAssociationType::ModelPattern,
            Self::Global => ModelAssociationType::Global,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelAssociationRouteInput {
    pub id: String,
    pub canonical_model_id: String,
    pub target: ModelAssociationTarget,
    pub upstream_model_name: Option<String>,
    pub priority: i32,
    pub fallback_allowed: bool,
    pub status: ModelAssociationStatus,
}

impl ModelAssociationRouteInput {
    pub fn new(
        id: impl Into<String>,
        canonical_model_id: impl Into<String>,
        target: ModelAssociationTarget,
        priority: i32,
    ) -> Self {
        Self {
            id: id.into(),
            canonical_model_id: canonical_model_id.into(),
            target,
            upstream_model_name: None,
            priority,
            fallback_allowed: true,
            status: ModelAssociationStatus::Enabled,
        }
    }

    pub fn explicit_channel(
        id: impl Into<String>,
        canonical_model_id: impl Into<String>,
        channel_id: impl Into<String>,
        priority: i32,
    ) -> Self {
        Self::new(
            id,
            canonical_model_id,
            ModelAssociationTarget::ExplicitChannel {
                channel_id: channel_id.into(),
            },
            priority,
        )
    }

    pub fn channel_tag(
        id: impl Into<String>,
        canonical_model_id: impl Into<String>,
        tag: impl Into<String>,
        priority: i32,
    ) -> Self {
        Self::new(
            id,
            canonical_model_id,
            ModelAssociationTarget::ChannelTag { tag: tag.into() },
            priority,
        )
    }

    pub fn model_pattern(
        id: impl Into<String>,
        canonical_model_id: impl Into<String>,
        pattern: impl Into<String>,
        priority: i32,
    ) -> Self {
        Self::new(
            id,
            canonical_model_id,
            ModelAssociationTarget::ModelPattern {
                pattern: pattern.into(),
            },
            priority,
        )
    }

    pub fn global(
        id: impl Into<String>,
        canonical_model_id: impl Into<String>,
        priority: i32,
    ) -> Self {
        Self::new(
            id,
            canonical_model_id,
            ModelAssociationTarget::Global,
            priority,
        )
    }

    pub fn with_upstream_model_name(mut self, upstream_model_name: impl Into<String>) -> Self {
        self.upstream_model_name = Some(upstream_model_name.into());
        self
    }

    pub const fn with_fallback_allowed(mut self, fallback_allowed: bool) -> Self {
        self.fallback_allowed = fallback_allowed;
        self
    }

    pub const fn with_status(mut self, status: ModelAssociationStatus) -> Self {
        self.status = status;
        self
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChannelRouteInput {
    pub id: String,
    pub provider_id: String,
    pub tags: Vec<String>,
    pub model_mapping_policy: ChannelModelMappingPolicy,
    pub priority: i32,
    pub weight: u32,
    pub status: ChannelStatus,
    pub health: ChannelHealth,
    pub rate_limit_available: bool,
}

impl ChannelRouteInput {
    pub fn new(
        id: impl Into<String>,
        provider_id: impl Into<String>,
        priority: i32,
        weight: u32,
    ) -> Self {
        Self {
            id: id.into(),
            provider_id: provider_id.into(),
            tags: Vec::new(),
            model_mapping_policy: ChannelModelMappingPolicy::new(),
            priority,
            weight,
            status: ChannelStatus::Enabled,
            health: ChannelHealth::Healthy,
            rate_limit_available: true,
        }
    }

    pub fn with_tag(mut self, tag: impl Into<String>) -> Self {
        push_non_empty(&mut self.tags, tag.into());
        self
    }

    pub fn with_tags(mut self, tags: impl IntoIterator<Item = impl Into<String>>) -> Self {
        self.tags
            .extend(tags.into_iter().filter_map(non_empty_string));
        self
    }

    pub fn with_model_mapping_policy(
        mut self,
        model_mapping_policy: ChannelModelMappingPolicy,
    ) -> Self {
        self.model_mapping_policy = model_mapping_policy;
        self
    }

    pub const fn with_status(mut self, status: ChannelStatus) -> Self {
        self.status = status;
        self
    }

    pub const fn with_health(mut self, health: ChannelHealth) -> Self {
        self.health = health;
        self
    }

    pub const fn with_rate_limit_available(mut self, available: bool) -> Self {
        self.rate_limit_available = available;
        self
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct ProfileRouteConstraints {
    pub visible_model_visibilities: Vec<CanonicalModelVisibility>,
    pub allowed_models: Vec<String>,
    pub denied_models: Vec<String>,
    pub allowed_channel_tags: Vec<String>,
    pub denied_channel_tags: Vec<String>,
    pub blocked_provider_ids: Vec<String>,
}

impl ProfileRouteConstraints {
    pub fn unrestricted() -> Self {
        Self::default()
    }

    pub fn with_visible_model_visibility(mut self, visibility: CanonicalModelVisibility) -> Self {
        self.visible_model_visibilities.push(visibility);
        self
    }

    pub fn with_allowed_model(mut self, model: impl Into<String>) -> Self {
        push_non_empty(&mut self.allowed_models, model.into());
        self
    }

    pub fn with_denied_model(mut self, model: impl Into<String>) -> Self {
        push_non_empty(&mut self.denied_models, model.into());
        self
    }

    pub fn with_allowed_channel_tag(mut self, tag: impl Into<String>) -> Self {
        push_non_empty(&mut self.allowed_channel_tags, tag.into());
        self
    }

    pub fn with_denied_channel_tag(mut self, tag: impl Into<String>) -> Self {
        push_non_empty(&mut self.denied_channel_tags, tag.into());
        self
    }

    pub fn with_blocked_provider_id(mut self, provider_id: impl Into<String>) -> Self {
        push_non_empty(&mut self.blocked_provider_ids, provider_id.into());
        self
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RouteCandidateGenerationInput {
    pub requested_model: String,
    pub canonical_model: CanonicalModelRouteInput,
    pub associations: Vec<ModelAssociationRouteInput>,
    pub channels: Vec<ChannelRouteInput>,
    pub profile: ProfileRouteConstraints,
}

impl RouteCandidateGenerationInput {
    pub fn new(
        requested_model: impl Into<String>,
        canonical_model: CanonicalModelRouteInput,
    ) -> Self {
        Self {
            requested_model: requested_model.into(),
            canonical_model,
            associations: Vec::new(),
            channels: Vec::new(),
            profile: ProfileRouteConstraints::unrestricted(),
        }
    }

    pub fn with_association(mut self, association: ModelAssociationRouteInput) -> Self {
        self.associations.push(association);
        self
    }

    pub fn with_channel(mut self, channel: ChannelRouteInput) -> Self {
        self.channels.push(channel);
        self
    }

    pub fn with_profile(mut self, profile: ProfileRouteConstraints) -> Self {
        self.profile = profile;
        self
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GeneratedRouteCandidate {
    pub association_id: String,
    pub association_type: ModelAssociationType,
    pub association_priority: i32,
    pub channel_priority: i32,
    pub fallback_allowed: bool,
    pub candidate: RouteCandidate,
    pub filter_reason: Option<CandidateFilterReason>,
}

impl GeneratedRouteCandidate {
    pub fn is_selectable(&self) -> bool {
        self.filter_reason.is_none()
    }

    pub fn evaluated_candidate(&self) -> EvaluatedCandidate {
        EvaluatedCandidate {
            candidate: self.candidate.clone(),
            filter_reason: self.filter_reason,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RouteCandidateGenerationResult {
    pub requested_model: String,
    pub canonical_model: CanonicalModelRouteInput,
    pub candidates: Vec<GeneratedRouteCandidate>,
}

impl RouteCandidateGenerationResult {
    pub fn evaluated_candidates(&self) -> Vec<EvaluatedCandidate> {
        self.candidates
            .iter()
            .map(GeneratedRouteCandidate::evaluated_candidate)
            .collect()
    }

    pub fn selectable_route_candidates(&self) -> Vec<RouteCandidate> {
        self.candidates
            .iter()
            .filter(|candidate| candidate.is_selectable())
            .map(|candidate| candidate.candidate.clone())
            .collect()
    }
}

pub fn generate_route_candidates(
    input: RouteCandidateGenerationInput,
) -> RouteCandidateGenerationResult {
    let model_filter_reason = model_filter_reason(&input.canonical_model, &input.profile);
    let mut candidates = Vec::new();

    for association in input
        .associations
        .iter()
        .filter(|association| association.canonical_model_id == input.canonical_model.id)
    {
        let association_filter_reason = association_filter_reason(association);

        for channel in input.channels.iter().filter(|channel| {
            association_matches_channel(association, channel, &input.canonical_model.model_key)
        }) {
            let provider_model = upstream_model_name(association, channel, &input.canonical_model);
            let route_candidate = RouteCandidate::new(
                channel.id.clone(),
                channel.provider_id.clone(),
                provider_model,
                route_priority_for_generation(association.priority, channel.priority),
                channel.weight,
            )
            .with_status(channel.status)
            .with_health(channel.health)
            .with_rate_limit_available(channel.rate_limit_available);
            let filter_reason = model_filter_reason
                .or(association_filter_reason)
                .or_else(|| profile_channel_filter_reason(channel, &input.profile))
                .or_else(|| selection_filter_reason_for(&route_candidate));

            candidates.push(GeneratedRouteCandidate {
                association_id: association.id.clone(),
                association_type: association.target.association_type(),
                association_priority: association.priority,
                channel_priority: channel.priority,
                fallback_allowed: association.fallback_allowed,
                candidate: route_candidate,
                filter_reason,
            });
        }
    }

    candidates.sort_by(compare_generated_route_candidates);

    RouteCandidateGenerationResult {
        requested_model: input.requested_model,
        canonical_model: input.canonical_model,
        candidates,
    }
}

pub fn selectable_route_candidates(
    candidates: impl IntoIterator<Item = GeneratedRouteCandidate>,
) -> Vec<RouteCandidate> {
    candidates
        .into_iter()
        .filter(GeneratedRouteCandidate::is_selectable)
        .map(|candidate| candidate.candidate)
        .collect()
}

pub fn route_priority_for_generation(association_priority: i32, channel_priority: i32) -> i32 {
    association_priority
        .saturating_mul(ROUTE_PRIORITY_ASSOCIATION_MULTIPLIER)
        .saturating_add(channel_priority)
}

fn model_filter_reason(
    canonical_model: &CanonicalModelRouteInput,
    profile: &ProfileRouteConstraints,
) -> Option<CandidateFilterReason> {
    match canonical_model.status {
        CanonicalModelStatus::Disabled => {
            return Some(CandidateFilterReason::CanonicalModelDisabled);
        }
        CanonicalModelStatus::Deleted => {
            return Some(CandidateFilterReason::CanonicalModelDeleted);
        }
        CanonicalModelStatus::Active | CanonicalModelStatus::Deprecated => {}
    }

    if string_list_contains(&profile.denied_models, &canonical_model.model_key)
        || (!profile.allowed_models.is_empty()
            && !string_list_contains(&profile.allowed_models, &canonical_model.model_key))
    {
        return Some(CandidateFilterReason::ProfileModelDenied);
    }

    if !profile.visible_model_visibilities.is_empty()
        && !profile
            .visible_model_visibilities
            .contains(&canonical_model.visibility)
    {
        return Some(CandidateFilterReason::ModelVisibilityDenied);
    }

    None
}

fn association_filter_reason(
    association: &ModelAssociationRouteInput,
) -> Option<CandidateFilterReason> {
    match association.status {
        ModelAssociationStatus::Enabled => None,
        ModelAssociationStatus::Disabled => Some(CandidateFilterReason::AssociationDisabled),
        ModelAssociationStatus::Deleted => Some(CandidateFilterReason::AssociationDeleted),
    }
}

fn profile_channel_filter_reason(
    channel: &ChannelRouteInput,
    profile: &ProfileRouteConstraints,
) -> Option<CandidateFilterReason> {
    if has_any_tag(channel, &profile.denied_channel_tags)
        || (!profile.allowed_channel_tags.is_empty()
            && !has_any_tag(channel, &profile.allowed_channel_tags))
    {
        return Some(CandidateFilterReason::ProfileChannelTagDenied);
    }

    if string_list_contains(&profile.blocked_provider_ids, &channel.provider_id) {
        return Some(CandidateFilterReason::ProfileProviderDenied);
    }

    None
}

fn association_matches_channel(
    association: &ModelAssociationRouteInput,
    channel: &ChannelRouteInput,
    canonical_model_key: &str,
) -> bool {
    match &association.target {
        ModelAssociationTarget::ExplicitChannel { channel_id } => channel.id == *channel_id,
        ModelAssociationTarget::ChannelTag { tag } => channel_has_tag(channel, tag),
        ModelAssociationTarget::ModelPattern { pattern } => {
            model_pattern_matches(canonical_model_key, pattern)
        }
        ModelAssociationTarget::Global => true,
    }
}

fn upstream_model_name(
    association: &ModelAssociationRouteInput,
    channel: &ChannelRouteInput,
    canonical_model: &CanonicalModelRouteInput,
) -> String {
    association
        .upstream_model_name
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .unwrap_or_else(|| {
            map_upstream_model_name(&canonical_model.model_key, &channel.model_mapping_policy)
        })
}

fn compare_generated_route_candidates(
    left: &GeneratedRouteCandidate,
    right: &GeneratedRouteCandidate,
) -> Ordering {
    left.candidate
        .priority
        .cmp(&right.candidate.priority)
        .then_with(|| right.candidate.weight.cmp(&left.candidate.weight))
        .then_with(|| left.candidate.channel_id.cmp(&right.candidate.channel_id))
        .then_with(|| left.candidate.provider_id.cmp(&right.candidate.provider_id))
        .then_with(|| {
            left.candidate
                .provider_model
                .cmp(&right.candidate.provider_model)
        })
        .then_with(|| left.association_id.cmp(&right.association_id))
        .then_with(|| {
            association_type_rank(left.association_type)
                .cmp(&association_type_rank(right.association_type))
        })
}

fn association_type_rank(association_type: ModelAssociationType) -> u8 {
    match association_type {
        ModelAssociationType::ExplicitChannel => 0,
        ModelAssociationType::ChannelTag => 1,
        ModelAssociationType::ModelPattern => 2,
        ModelAssociationType::Global => 3,
    }
}

fn has_any_tag(channel: &ChannelRouteInput, tags: &[String]) -> bool {
    tags.iter().any(|tag| channel_has_tag(channel, tag))
}

fn channel_has_tag(channel: &ChannelRouteInput, tag: &str) -> bool {
    channel.tags.iter().any(|channel_tag| channel_tag == tag)
}

fn string_list_contains(values: &[String], expected: &str) -> bool {
    values.iter().any(|value| value == expected)
}

fn model_pattern_matches(model: &str, pattern: &str) -> bool {
    let pattern = pattern.trim();
    if pattern.is_empty() {
        return false;
    }

    Regex::new(pattern).is_ok_and(|regex| regex.is_match(model))
}

fn non_empty_string(value: impl Into<String>) -> Option<String> {
    let value = value.into();
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_owned())
    }
}

fn push_non_empty(values: &mut Vec<String>, value: String) {
    if let Some(value) = non_empty_string(value) {
        values.push(value);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;

    fn canonical_model() -> CanonicalModelRouteInput {
        CanonicalModelRouteInput::new("model-gpt", "gpt-visible")
            .with_visibility(CanonicalModelVisibility::Public)
    }

    fn global_association(id: &str, priority: i32) -> ModelAssociationRouteInput {
        ModelAssociationRouteInput::global(id, "model-gpt", priority)
    }

    fn channel(id: &str, provider_id: &str, priority: i32, weight: u32) -> ChannelRouteInput {
        ChannelRouteInput::new(id, provider_id, priority, weight)
    }

    fn reason_for(
        candidates: &[GeneratedRouteCandidate],
        channel_id: &str,
    ) -> Option<CandidateFilterReason> {
        candidates
            .iter()
            .find(|candidate| candidate.candidate.channel_id == channel_id)
            .and_then(|candidate| candidate.filter_reason)
    }

    #[derive(Debug, Deserialize)]
    struct CandidateGenerationContractFixture {
        #[allow(dead_code)]
        scenario: String,
        #[allow(dead_code)]
        #[serde(rename = "crate")]
        crate_name: String,
        #[allow(dead_code)]
        function: String,
        scenarios: Vec<CandidateGenerationContractScenario>,
    }

    #[derive(Debug, Deserialize)]
    struct CandidateGenerationContractScenario {
        #[allow(dead_code)]
        name: String,
        input: RouteCandidateGenerationInput,
        expected_candidates: Vec<GeneratedRouteCandidate>,
        expected_selectable_channel_ids: Vec<String>,
    }

    #[test]
    fn explicit_channel_generates_single_selectable_candidate() {
        let result = generate_route_candidates(
            RouteCandidateGenerationInput::new("gpt-visible", canonical_model())
                .with_association(
                    ModelAssociationRouteInput::explicit_channel(
                        "assoc-explicit",
                        "model-gpt",
                        "channel-primary",
                        2,
                    )
                    .with_upstream_model_name("upstream-gpt"),
                )
                .with_channel(channel("channel-primary", "provider-a", 10, 100))
                .with_channel(channel("channel-other", "provider-b", 1, 100)),
        );

        assert_eq!(result.candidates.len(), 1);
        let candidate = &result.candidates[0];
        assert_eq!(candidate.association_id, "assoc-explicit");
        assert_eq!(
            candidate.association_type,
            ModelAssociationType::ExplicitChannel
        );
        assert_eq!(candidate.candidate.channel_id, "channel-primary");
        assert_eq!(candidate.candidate.provider_model, "upstream-gpt");
        assert_eq!(candidate.candidate.priority, 2_000_010);
        assert!(candidate.is_selectable());
    }

    #[test]
    fn channel_tag_generates_tagged_channels_and_applies_channel_mapping() {
        let policy = ChannelModelMappingPolicy::new()
            .with_explicit_mapping("gpt-visible", "mapped-upstream-gpt");
        let result = generate_route_candidates(
            RouteCandidateGenerationInput::new("gpt-visible", canonical_model())
                .with_association(ModelAssociationRouteInput::channel_tag(
                    "assoc-fast",
                    "model-gpt",
                    "fast",
                    1,
                ))
                .with_channel(
                    channel("channel-fast", "provider-a", 5, 50)
                        .with_tag("fast")
                        .with_model_mapping_policy(policy),
                )
                .with_channel(channel("channel-slow", "provider-b", 1, 100).with_tag("slow")),
        );

        assert_eq!(result.candidates.len(), 1);
        assert_eq!(result.candidates[0].candidate.channel_id, "channel-fast");
        assert_eq!(
            result.candidates[0].candidate.provider_model,
            "mapped-upstream-gpt"
        );
        assert!(result.candidates[0].is_selectable());
    }

    #[test]
    fn model_pattern_and_global_fallback_generate_deterministic_order() {
        let result = generate_route_candidates(
            RouteCandidateGenerationInput::new("gpt-visible", canonical_model())
                .with_association(ModelAssociationRouteInput::global(
                    "assoc-global",
                    "model-gpt",
                    9,
                ))
                .with_association(ModelAssociationRouteInput::model_pattern(
                    "assoc-pattern",
                    "model-gpt",
                    "^gpt-.*",
                    2,
                ))
                .with_channel(channel("channel-b", "provider-b", 20, 10))
                .with_channel(channel("channel-a", "provider-a", 10, 100)),
        );

        let order = result
            .candidates
            .iter()
            .map(|candidate| {
                (
                    candidate.association_id.as_str(),
                    candidate.candidate.channel_id.as_str(),
                )
            })
            .collect::<Vec<_>>();

        assert_eq!(
            order,
            [
                ("assoc-pattern", "channel-a"),
                ("assoc-pattern", "channel-b"),
                ("assoc-global", "channel-a"),
                ("assoc-global", "channel-b"),
            ]
        );
    }

    #[test]
    fn model_pattern_uses_regex_semantics_and_anchors() {
        let result = generate_route_candidates(
            RouteCandidateGenerationInput::new(
                "gpt-4",
                CanonicalModelRouteInput::new("model-gpt-4", "gpt-4")
                    .with_visibility(CanonicalModelVisibility::Public),
            )
            .with_association(ModelAssociationRouteInput::model_pattern(
                "assoc-regex",
                "model-gpt-4",
                "^gpt-(4|5)$",
                1,
            ))
            .with_channel(channel("channel-a", "provider-a", 1, 100)),
        );

        assert_eq!(result.candidates.len(), 1);
        assert_eq!(result.candidates[0].association_id, "assoc-regex");

        let no_match = generate_route_candidates(
            RouteCandidateGenerationInput::new(
                "gpt-40",
                CanonicalModelRouteInput::new("model-gpt-40", "gpt-40")
                    .with_visibility(CanonicalModelVisibility::Public),
            )
            .with_association(ModelAssociationRouteInput::model_pattern(
                "assoc-regex",
                "model-gpt-40",
                "^gpt-(4|5)$",
                1,
            ))
            .with_channel(channel("channel-a", "provider-a", 1, 100)),
        );

        assert!(no_match.candidates.is_empty());
    }

    #[test]
    fn invalid_model_pattern_regex_does_not_generate_candidates() {
        let result = generate_route_candidates(
            RouteCandidateGenerationInput::new("gpt-visible", canonical_model())
                .with_association(ModelAssociationRouteInput::model_pattern(
                    "assoc-invalid-regex",
                    "model-gpt",
                    "[",
                    1,
                ))
                .with_channel(channel("channel-a", "provider-a", 1, 100)),
        );

        assert!(result.candidates.is_empty());
    }

    #[test]
    fn status_health_and_degraded_channels_get_clear_filter_reasons() {
        let result = generate_route_candidates(
            RouteCandidateGenerationInput::new("gpt-visible", canonical_model())
                .with_association(global_association("assoc-global", 1))
                .with_channel(channel("enabled", "provider-a", 1, 100))
                .with_channel(
                    channel("disabled", "provider-a", 2, 100).with_status(ChannelStatus::Disabled),
                )
                .with_channel(
                    channel("cooldown", "provider-a", 3, 100)
                        .with_status(ChannelStatus::CoolingDown),
                )
                .with_channel(
                    channel("degraded", "provider-a", 4, 100)
                        .with_status(ChannelStatus::Degraded)
                        .with_health(ChannelHealth::Degraded),
                )
                .with_channel(
                    channel("unhealthy", "provider-a", 5, 100)
                        .with_health(ChannelHealth::Unhealthy),
                ),
        );

        assert_eq!(reason_for(&result.candidates, "enabled"), None);
        assert_eq!(
            reason_for(&result.candidates, "disabled"),
            Some(CandidateFilterReason::Disabled)
        );
        assert_eq!(
            reason_for(&result.candidates, "cooldown"),
            Some(CandidateFilterReason::CoolingDown)
        );
        assert_eq!(reason_for(&result.candidates, "degraded"), None);
        assert_eq!(
            reason_for(&result.candidates, "unhealthy"),
            Some(CandidateFilterReason::Unhealthy)
        );
    }

    #[test]
    fn profile_channel_tag_allow_deny_and_provider_blocks_filter_candidates() {
        let profile = ProfileRouteConstraints::unrestricted()
            .with_allowed_channel_tag("fast")
            .with_denied_channel_tag("blocked")
            .with_blocked_provider_id("provider-blocked");

        let result = generate_route_candidates(
            RouteCandidateGenerationInput::new("gpt-visible", canonical_model())
                .with_profile(profile)
                .with_association(global_association("assoc-global", 1))
                .with_channel(channel("allowed", "provider-a", 1, 100).with_tag("fast"))
                .with_channel(channel("not-allowed", "provider-a", 2, 100).with_tag("slow"))
                .with_channel(
                    channel("denied", "provider-a", 3, 100)
                        .with_tag("fast")
                        .with_tag("blocked"),
                )
                .with_channel(
                    channel("provider-blocked", "provider-blocked", 4, 100).with_tag("fast"),
                ),
        );

        assert_eq!(reason_for(&result.candidates, "allowed"), None);
        assert_eq!(
            reason_for(&result.candidates, "not-allowed"),
            Some(CandidateFilterReason::ProfileChannelTagDenied)
        );
        assert_eq!(
            reason_for(&result.candidates, "denied"),
            Some(CandidateFilterReason::ProfileChannelTagDenied)
        );
        assert_eq!(
            reason_for(&result.candidates, "provider-blocked"),
            Some(CandidateFilterReason::ProfileProviderDenied)
        );
    }

    #[test]
    fn profile_visibility_restriction_filters_otherwise_matching_candidates() {
        let hidden_model = canonical_model().with_visibility(CanonicalModelVisibility::Hidden);
        let profile = ProfileRouteConstraints::unrestricted()
            .with_visible_model_visibility(CanonicalModelVisibility::Public)
            .with_visible_model_visibility(CanonicalModelVisibility::Internal);

        let result = generate_route_candidates(
            RouteCandidateGenerationInput::new("gpt-visible", hidden_model)
                .with_profile(profile)
                .with_association(global_association("assoc-global", 1))
                .with_channel(channel("channel-a", "provider-a", 1, 100)),
        );

        assert_eq!(
            reason_for(&result.candidates, "channel-a"),
            Some(CandidateFilterReason::ModelVisibilityDenied)
        );
        assert!(result.selectable_route_candidates().is_empty());
    }

    #[test]
    fn sorting_is_stable_for_duplicate_candidate_scores() {
        let result = generate_route_candidates(
            RouteCandidateGenerationInput::new("gpt-visible", canonical_model())
                .with_association(global_association("assoc-b", 1))
                .with_association(global_association("assoc-a", 1))
                .with_channel(channel("channel-a", "provider-a", 1, 100)),
        );

        let order = result
            .candidates
            .iter()
            .map(|candidate| candidate.association_id.as_str())
            .collect::<Vec<_>>();

        assert_eq!(order, ["assoc-a", "assoc-b"]);
    }

    #[test]
    fn selectable_route_candidates_omit_prefiltered_candidates() {
        let result = generate_route_candidates(
            RouteCandidateGenerationInput::new("gpt-visible", canonical_model())
                .with_association(global_association("assoc-global", 1))
                .with_channel(channel("selected", "provider-a", 1, 100))
                .with_channel(
                    channel("disabled", "provider-a", 2, 100).with_status(ChannelStatus::Disabled),
                ),
        );

        let selectable = result.selectable_route_candidates();

        assert_eq!(selectable.len(), 1);
        assert_eq!(selectable[0].channel_id, "selected");
    }

    #[test]
    fn routing_candidate_generation_fixture_contract_is_stable() {
        let fixture: CandidateGenerationContractFixture = serde_json::from_str(include_str!(
            "../../../tests/fixtures/routing/candidate_generation_contract.json"
        ))
        .expect("candidate generation fixture should be valid");

        for scenario in fixture.scenarios {
            let result = generate_route_candidates(scenario.input);
            let selectable_channel_ids = result
                .selectable_route_candidates()
                .into_iter()
                .map(|candidate| candidate.channel_id)
                .collect::<Vec<_>>();

            assert_eq!(result.candidates, scenario.expected_candidates);
            assert_eq!(
                selectable_channel_ids,
                scenario.expected_selectable_channel_ids
            );
        }
    }

    #[test]
    fn routing_candidate_generation_fixture_omits_credential_and_payload_material() {
        let fixture =
            include_str!("../../../tests/fixtures/routing/candidate_generation_contract.json");
        assert_no_routing_sensitive_material(fixture);

        let contract: CandidateGenerationContractFixture =
            serde_json::from_str(fixture).expect("candidate generation fixture should be valid");
        for scenario in contract.scenarios {
            let result = generate_route_candidates(scenario.input);
            let serialized =
                serde_json::to_string(&result).expect("candidate result should serialize");
            assert_no_routing_sensitive_material(&serialized);
        }
    }

    fn assert_no_routing_sensitive_material(value: &str) {
        let lower = value.to_ascii_lowercase();

        for forbidden in [
            "provider_key",
            "provider key",
            "api_key",
            "authorization",
            "bearer",
            "secret",
            "raw_payload",
            "raw payload",
            "payload",
        ] {
            assert!(
                !lower.contains(forbidden),
                "routing contract should omit sensitive material: {forbidden}"
            );
        }
    }
}
