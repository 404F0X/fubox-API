use serde::{Deserialize, Serialize};
use std::cmp::Ordering;

pub const ROUTE_DECISION_SNAPSHOT_VERSION: u16 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ChannelStatus {
    Enabled,
    Degraded,
    Disabled,
    CoolingDown,
    RecoveryProbe,
    AuthFailed,
    QuotaExhausted,
    ManualDisabled,
    Deleted,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ChannelHealth {
    Healthy,
    Degraded,
    Unhealthy,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CandidateFilterReason {
    CanonicalModelDisabled,
    CanonicalModelDeleted,
    ModelVisibilityDenied,
    ProfileModelDenied,
    AssociationDisabled,
    AssociationDeleted,
    ProfileChannelTagDenied,
    ProfileProviderDenied,
    Disabled,
    CoolingDown,
    RecoveryProbe,
    AuthFailed,
    QuotaExhausted,
    ManualDisabled,
    Deleted,
    RateLimitExceeded,
    Unhealthy,
    ZeroWeight,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RouteCandidate {
    pub channel_id: String,
    pub provider_id: String,
    pub provider_model: String,
    pub priority: i32,
    pub weight: u32,
    pub status: ChannelStatus,
    pub health: ChannelHealth,
    pub rate_limit_available: bool,
}

impl RouteCandidate {
    pub fn new(
        channel_id: impl Into<String>,
        provider_id: impl Into<String>,
        provider_model: impl Into<String>,
        priority: i32,
        weight: u32,
    ) -> Self {
        Self {
            channel_id: channel_id.into(),
            provider_id: provider_id.into(),
            provider_model: provider_model.into(),
            priority,
            weight,
            status: ChannelStatus::Enabled,
            health: ChannelHealth::Healthy,
            rate_limit_available: true,
        }
    }

    pub fn with_status(mut self, status: ChannelStatus) -> Self {
        self.status = status;
        self
    }

    pub fn with_health(mut self, health: ChannelHealth) -> Self {
        self.health = health;
        self
    }

    pub fn with_rate_limit_available(mut self, available: bool) -> Self {
        self.rate_limit_available = available;
        self
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EvaluatedCandidate {
    pub candidate: RouteCandidate,
    pub filter_reason: Option<CandidateFilterReason>,
}

impl EvaluatedCandidate {
    pub fn is_selectable(&self) -> bool {
        self.filter_reason.is_none()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct SelectionPolicy {
    pub seed: u64,
}

impl SelectionPolicy {
    pub const fn deterministic(seed: u64) -> Self {
        Self { seed }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TraceAffinity {
    pub enabled: bool,
    pub previous_successful_channel_id: Option<String>,
}

impl TraceAffinity {
    pub const fn disabled() -> Self {
        Self {
            enabled: false,
            previous_successful_channel_id: None,
        }
    }

    pub fn prefer_channel(channel_id: impl Into<String>) -> Self {
        Self {
            enabled: true,
            previous_successful_channel_id: Some(channel_id.into()),
        }
    }
}

impl Default for TraceAffinity {
    fn default() -> Self {
        Self::disabled()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct RouteSelectionContext {
    pub trace_id: Option<String>,
    pub trace_affinity: TraceAffinity,
}

impl RouteSelectionContext {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn for_trace(trace_id: impl Into<String>) -> Self {
        Self {
            trace_id: Some(trace_id.into()),
            trace_affinity: TraceAffinity::disabled(),
        }
    }

    pub fn with_trace_id(mut self, trace_id: impl Into<String>) -> Self {
        self.trace_id = Some(trace_id.into());
        self
    }

    pub fn with_trace_affinity_channel(mut self, channel_id: impl Into<String>) -> Self {
        self.trace_affinity = TraceAffinity::prefer_channel(channel_id);
        self
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TraceAffinityStatus {
    Disabled,
    NoTraceId,
    NoPreviousSuccess,
    PreviousChannelNotCandidate,
    PreviousChannelFiltered,
    Applied,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TraceAffinityDecision {
    pub status: TraceAffinityStatus,
    pub trace_id: Option<String>,
    pub previous_successful_channel_id: Option<String>,
    pub applied_channel_id: Option<String>,
}

impl TraceAffinityDecision {
    pub fn disabled() -> Self {
        Self {
            status: TraceAffinityStatus::Disabled,
            trace_id: None,
            previous_successful_channel_id: None,
            applied_channel_id: None,
        }
    }
}

impl Default for TraceAffinityDecision {
    fn default() -> Self {
        Self::disabled()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RouteRequest {
    pub requested_model: String,
    pub canonical_model: Option<String>,
    pub policy: SelectionPolicy,
}

impl RouteRequest {
    pub fn new(requested_model: impl Into<String>, seed: u64) -> Self {
        Self {
            requested_model: requested_model.into(),
            canonical_model: None,
            policy: SelectionPolicy::deterministic(seed),
        }
    }

    pub fn with_canonical_model(mut self, canonical_model: impl Into<String>) -> Self {
        self.canonical_model = Some(canonical_model.into());
        self
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SelectedRoute {
    pub channel_id: String,
    pub provider_id: String,
    pub provider_model: String,
    pub priority: i32,
    pub weight: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RouteDecision {
    pub requested_model: String,
    pub canonical_model: Option<String>,
    pub policy: SelectionPolicy,
    pub trace_id: Option<String>,
    pub trace_affinity: TraceAffinityDecision,
    pub selected_channel_id: Option<String>,
    pub selected: Option<SelectedRoute>,
    pub candidates: Vec<EvaluatedCandidate>,
}

impl RouteDecision {
    pub fn empty(requested_model: impl Into<String>) -> Self {
        Self {
            requested_model: requested_model.into(),
            canonical_model: None,
            policy: SelectionPolicy::deterministic(0),
            trace_id: None,
            trace_affinity: TraceAffinityDecision::disabled(),
            selected_channel_id: None,
            selected: None,
            candidates: Vec::new(),
        }
    }

    pub fn snapshot(&self) -> RouteDecisionSnapshot {
        RouteDecisionSnapshot::from_decision(self)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct RouteCandidateScore {
    pub priority: i32,
    pub weight: u32,
    pub trace_affinity_bonus: u32,
    pub total: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RouteDecisionSnapshotCandidate {
    pub channel_id: String,
    pub provider_id: String,
    pub provider_model: String,
    pub priority: i32,
    pub weight: u32,
    pub status: ChannelStatus,
    pub health: ChannelHealth,
    pub rate_limit_available: bool,
    pub filtered: bool,
    pub filter_reason: Option<CandidateFilterReason>,
    pub score: Option<RouteCandidateScore>,
    pub selected: bool,
    pub trace_affinity_match: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RouteDecisionSnapshot {
    pub version: u16,
    pub requested_model: String,
    pub canonical_model: Option<String>,
    pub policy: SelectionPolicy,
    pub trace_id: Option<String>,
    pub trace_affinity: TraceAffinityDecision,
    pub selected_channel_id: Option<String>,
    pub selected: Option<SelectedRoute>,
    pub candidates: Vec<RouteDecisionSnapshotCandidate>,
}

impl RouteDecisionSnapshot {
    pub fn from_decision(decision: &RouteDecision) -> Self {
        let selected_channel_id = decision.selected_channel_id.as_deref();
        let affinity_channel_id = decision
            .trace_affinity
            .previous_successful_channel_id
            .as_deref();

        let candidates = decision
            .candidates
            .iter()
            .map(|evaluated| {
                let candidate = &evaluated.candidate;
                let trace_affinity_match = affinity_channel_id
                    .is_some_and(|channel_id| channel_id == candidate.channel_id.as_str());
                let score = evaluated
                    .is_selectable()
                    .then(|| score_candidate(candidate, trace_affinity_match));

                RouteDecisionSnapshotCandidate {
                    channel_id: candidate.channel_id.clone(),
                    provider_id: candidate.provider_id.clone(),
                    provider_model: candidate.provider_model.clone(),
                    priority: candidate.priority,
                    weight: candidate.weight,
                    status: candidate.status,
                    health: candidate.health,
                    rate_limit_available: candidate.rate_limit_available,
                    filtered: !evaluated.is_selectable(),
                    filter_reason: evaluated.filter_reason,
                    score,
                    selected: selected_channel_id
                        .is_some_and(|channel_id| channel_id == candidate.channel_id.as_str()),
                    trace_affinity_match,
                }
            })
            .collect();

        Self {
            version: ROUTE_DECISION_SNAPSHOT_VERSION,
            requested_model: decision.requested_model.clone(),
            canonical_model: decision.canonical_model.clone(),
            policy: decision.policy,
            trace_id: decision.trace_id.clone(),
            trace_affinity: decision.trace_affinity.clone(),
            selected_channel_id: decision.selected_channel_id.clone(),
            selected: decision.selected.clone(),
            candidates,
        }
    }
}

impl From<&RouteDecision> for RouteDecisionSnapshot {
    fn from(decision: &RouteDecision) -> Self {
        Self::from_decision(decision)
    }
}

pub fn select_route(
    request: RouteRequest,
    candidates: impl IntoIterator<Item = RouteCandidate>,
) -> RouteDecision {
    select_route_with_context(request, candidates, RouteSelectionContext::default())
}

pub fn select_route_with_context(
    request: RouteRequest,
    candidates: impl IntoIterator<Item = RouteCandidate>,
    context: RouteSelectionContext,
) -> RouteDecision {
    let evaluated = evaluate_candidates(candidates);
    select_from_evaluated_candidates(request, evaluated, context)
}

pub fn select_route_from_evaluated(
    request: RouteRequest,
    candidates: impl IntoIterator<Item = EvaluatedCandidate>,
    context: RouteSelectionContext,
) -> RouteDecision {
    let mut evaluated = candidates.into_iter().collect::<Vec<_>>();
    evaluated.sort_by(compare_evaluated_candidates);
    select_from_evaluated_candidates(request, evaluated, context)
}

fn select_from_evaluated_candidates(
    request: RouteRequest,
    evaluated: Vec<EvaluatedCandidate>,
    context: RouteSelectionContext,
) -> RouteDecision {
    let trace_affinity = evaluate_trace_affinity(&context, &evaluated);
    let selected = pick_by_trace_affinity(&evaluated, &trace_affinity)
        .or_else(|| pick_by_priority_then_weight(&evaluated, request.policy.seed));
    let selected_channel_id = selected
        .as_ref()
        .map(|selected| selected.channel_id.clone());

    RouteDecision {
        requested_model: request.requested_model,
        canonical_model: request.canonical_model,
        policy: request.policy,
        trace_id: context.trace_id,
        trace_affinity,
        selected_channel_id,
        selected,
        candidates: evaluated,
    }
}

pub fn evaluate_candidates(
    candidates: impl IntoIterator<Item = RouteCandidate>,
) -> Vec<EvaluatedCandidate> {
    let mut evaluated = candidates
        .into_iter()
        .map(|candidate| {
            let filter_reason = selection_filter_reason_for(&candidate);
            EvaluatedCandidate {
                candidate,
                filter_reason,
            }
        })
        .collect::<Vec<_>>();

    evaluated.sort_by(compare_evaluated_candidates);
    evaluated
}

fn pick_by_priority_then_weight(
    candidates: &[EvaluatedCandidate],
    seed: u64,
) -> Option<SelectedRoute> {
    let best_priority = candidates
        .iter()
        .filter(|candidate| candidate.is_selectable())
        .map(|candidate| candidate.candidate.priority)
        .min()?;

    let priority_group = candidates
        .iter()
        .filter(|candidate| {
            candidate.is_selectable() && candidate.candidate.priority == best_priority
        })
        .collect::<Vec<_>>();

    let total_weight = priority_group
        .iter()
        .map(|candidate| u64::from(candidate.candidate.weight))
        .sum::<u64>();

    if total_weight == 0 {
        return None;
    }

    let mut ticket = seed % total_weight;
    for evaluated in priority_group {
        let weight = u64::from(evaluated.candidate.weight);
        if ticket < weight {
            return Some(SelectedRoute {
                channel_id: evaluated.candidate.channel_id.clone(),
                provider_id: evaluated.candidate.provider_id.clone(),
                provider_model: evaluated.candidate.provider_model.clone(),
                priority: evaluated.candidate.priority,
                weight: evaluated.candidate.weight,
            });
        }
        ticket -= weight;
    }

    None
}

fn evaluate_trace_affinity(
    context: &RouteSelectionContext,
    candidates: &[EvaluatedCandidate],
) -> TraceAffinityDecision {
    let previous_successful_channel_id = context
        .trace_affinity
        .previous_successful_channel_id
        .clone();

    if !context.trace_affinity.enabled {
        return TraceAffinityDecision {
            status: TraceAffinityStatus::Disabled,
            trace_id: context.trace_id.clone(),
            previous_successful_channel_id,
            applied_channel_id: None,
        };
    }

    if context.trace_id.is_none() {
        return TraceAffinityDecision {
            status: TraceAffinityStatus::NoTraceId,
            trace_id: None,
            previous_successful_channel_id,
            applied_channel_id: None,
        };
    }

    let Some(previous_channel_id) = previous_successful_channel_id.clone() else {
        return TraceAffinityDecision {
            status: TraceAffinityStatus::NoPreviousSuccess,
            trace_id: context.trace_id.clone(),
            previous_successful_channel_id,
            applied_channel_id: None,
        };
    };

    let Some(previous_candidate) = candidates
        .iter()
        .find(|candidate| candidate.candidate.channel_id.as_str() == previous_channel_id.as_str())
    else {
        return TraceAffinityDecision {
            status: TraceAffinityStatus::PreviousChannelNotCandidate,
            trace_id: context.trace_id.clone(),
            previous_successful_channel_id,
            applied_channel_id: None,
        };
    };

    if !previous_candidate.is_selectable() {
        return TraceAffinityDecision {
            status: TraceAffinityStatus::PreviousChannelFiltered,
            trace_id: context.trace_id.clone(),
            previous_successful_channel_id,
            applied_channel_id: None,
        };
    }

    TraceAffinityDecision {
        status: TraceAffinityStatus::Applied,
        trace_id: context.trace_id.clone(),
        previous_successful_channel_id: Some(previous_channel_id.clone()),
        applied_channel_id: Some(previous_channel_id),
    }
}

fn pick_by_trace_affinity(
    candidates: &[EvaluatedCandidate],
    trace_affinity: &TraceAffinityDecision,
) -> Option<SelectedRoute> {
    let channel_id = trace_affinity.applied_channel_id.as_deref()?;
    candidates
        .iter()
        .find(|candidate| {
            candidate.is_selectable() && candidate.candidate.channel_id.as_str() == channel_id
        })
        .map(selected_route_from_candidate)
}

pub(crate) fn selection_filter_reason_for(
    candidate: &RouteCandidate,
) -> Option<CandidateFilterReason> {
    match candidate.status {
        ChannelStatus::Disabled => return Some(CandidateFilterReason::Disabled),
        ChannelStatus::CoolingDown => return Some(CandidateFilterReason::CoolingDown),
        ChannelStatus::RecoveryProbe => return Some(CandidateFilterReason::RecoveryProbe),
        ChannelStatus::AuthFailed => return Some(CandidateFilterReason::AuthFailed),
        ChannelStatus::QuotaExhausted => return Some(CandidateFilterReason::QuotaExhausted),
        ChannelStatus::ManualDisabled => return Some(CandidateFilterReason::ManualDisabled),
        ChannelStatus::Deleted => return Some(CandidateFilterReason::Deleted),
        ChannelStatus::Enabled | ChannelStatus::Degraded => {}
    }

    if !candidate.rate_limit_available {
        return Some(CandidateFilterReason::RateLimitExceeded);
    }

    if candidate.health == ChannelHealth::Unhealthy {
        return Some(CandidateFilterReason::Unhealthy);
    }

    if candidate.weight == 0 {
        return Some(CandidateFilterReason::ZeroWeight);
    }

    None
}

fn compare_evaluated_candidates(left: &EvaluatedCandidate, right: &EvaluatedCandidate) -> Ordering {
    left.candidate
        .priority
        .cmp(&right.candidate.priority)
        .then_with(|| right.candidate.weight.cmp(&left.candidate.weight))
        .then_with(|| left.candidate.channel_id.cmp(&right.candidate.channel_id))
}

fn selected_route_from_candidate(evaluated: &EvaluatedCandidate) -> SelectedRoute {
    SelectedRoute {
        channel_id: evaluated.candidate.channel_id.clone(),
        provider_id: evaluated.candidate.provider_id.clone(),
        provider_model: evaluated.candidate.provider_model.clone(),
        priority: evaluated.candidate.priority,
        weight: evaluated.candidate.weight,
    }
}

fn score_candidate(candidate: &RouteCandidate, trace_affinity_match: bool) -> RouteCandidateScore {
    let trace_affinity_bonus = u32::from(trace_affinity_match);
    let total = (i64::from(i32::MAX) - i64::from(candidate.priority))
        + i64::from(candidate.weight)
        + i64::from(trace_affinity_bonus);

    RouteCandidateScore {
        priority: candidate.priority,
        weight: candidate.weight,
        trace_affinity_bonus,
        total,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;
    use serde_json::{Value, json};

    fn candidate(id: &str, priority: i32, weight: u32) -> RouteCandidate {
        RouteCandidate::new(id, "provider", "model", priority, weight)
    }

    #[derive(Debug, Deserialize)]
    struct SnapshotContractFixture {
        #[allow(dead_code)]
        scenario: String,
        #[allow(dead_code)]
        #[serde(rename = "crate")]
        crate_name: String,
        #[allow(dead_code)]
        function: String,
        input: SnapshotContractInput,
        expected_snapshot: RouteDecisionSnapshot,
        expected_snapshot_summary: Value,
    }

    #[derive(Debug, Deserialize)]
    struct SnapshotContractInput {
        request: RouteRequest,
        context: RouteSelectionContext,
        evaluated_candidates: Vec<EvaluatedCandidate>,
    }

    #[test]
    fn lower_priority_value_wins_before_weight() {
        let decision = select_route(
            RouteRequest::new("gpt-test", 0),
            [
                candidate("high-weight-later-priority", 20, 10_000),
                candidate("low-weight-first-priority", 10, 1),
            ],
        );

        assert_eq!(
            decision.selected_channel_id.as_deref(),
            Some("low-weight-first-priority")
        );
    }

    #[test]
    fn candidates_are_sorted_by_priority_weight_then_channel_id() {
        let evaluated = evaluate_candidates([
            candidate("b", 10, 1),
            candidate("a", 10, 10),
            candidate("z", 5, 1),
        ]);

        let order = evaluated
            .iter()
            .map(|candidate| candidate.candidate.channel_id.as_str())
            .collect::<Vec<_>>();

        assert_eq!(order, ["z", "a", "b"]);
    }

    #[test]
    fn deterministic_weight_picker_uses_seed_inside_best_priority_group() {
        let request = RouteRequest::new("gpt-test", 3);
        let decision = select_route(
            request,
            [
                candidate("weight-three", 10, 3),
                candidate("weight-one", 10, 1),
                candidate("later-priority", 20, 10_000),
            ],
        );

        assert_eq!(decision.selected_channel_id.as_deref(), Some("weight-one"));

        let repeat = select_route(
            RouteRequest::new("gpt-test", 3),
            [
                candidate("weight-three", 10, 3),
                candidate("weight-one", 10, 1),
                candidate("later-priority", 20, 10_000),
            ],
        );

        assert_eq!(decision, repeat);
    }

    #[test]
    fn deterministic_weight_picker_matches_weight_boundaries() {
        let candidates = [
            candidate("weight-three", 10, 3),
            candidate("weight-two", 10, 2),
            candidate("weight-one", 10, 1),
            candidate("later-priority", 20, 100),
        ];

        let selected_by_seed = (0..6)
            .map(|seed| {
                select_route(RouteRequest::new("gpt-test", seed), candidates.clone())
                    .selected_channel_id
                    .expect("best priority group should select")
            })
            .collect::<Vec<_>>();

        assert_eq!(
            selected_by_seed,
            [
                "weight-three",
                "weight-three",
                "weight-three",
                "weight-two",
                "weight-two",
                "weight-one",
            ]
        );

        let repeat = select_route(RouteRequest::new("gpt-test", 4), candidates.clone());
        assert_eq!(
            repeat,
            select_route(RouteRequest::new("gpt-test", 4), candidates)
        );
    }

    #[test]
    fn disabled_and_zero_weight_candidates_do_not_absorb_weight_tickets() {
        let candidates = [
            candidate("disabled", 10, 100).with_status(ChannelStatus::Disabled),
            candidate("zero", 10, 0),
            candidate("weight-two", 10, 2),
            candidate("weight-one", 10, 1),
        ];

        let selected_by_seed = (0..3)
            .map(|seed| {
                select_route(RouteRequest::new("gpt-test", seed), candidates.clone())
                    .selected_channel_id
                    .expect("selectable weighted candidates should select")
            })
            .collect::<Vec<_>>();

        assert_eq!(selected_by_seed, ["weight-two", "weight-two", "weight-one"]);

        let decision = select_route(RouteRequest::new("gpt-test", 99), candidates);
        let reason_for = |id: &str| {
            decision
                .candidates
                .iter()
                .find(|candidate| candidate.candidate.channel_id == id)
                .and_then(|candidate| candidate.filter_reason)
        };

        assert_eq!(
            reason_for("disabled"),
            Some(CandidateFilterReason::Disabled)
        );
        assert_eq!(reason_for("zero"), Some(CandidateFilterReason::ZeroWeight));
    }

    #[test]
    fn filters_status_health_and_zero_weight_with_explanations() {
        let evaluated = evaluate_candidates([
            candidate("disabled", 10, 1).with_status(ChannelStatus::Disabled),
            candidate("cooldown", 10, 1).with_status(ChannelStatus::CoolingDown),
            candidate("recovery", 10, 1).with_status(ChannelStatus::RecoveryProbe),
            candidate("auth", 10, 1).with_status(ChannelStatus::AuthFailed),
            candidate("quota", 10, 1).with_status(ChannelStatus::QuotaExhausted),
            candidate("manual", 10, 1).with_status(ChannelStatus::ManualDisabled),
            candidate("deleted", 10, 1).with_status(ChannelStatus::Deleted),
            candidate("rate-limit", 10, 1).with_rate_limit_available(false),
            candidate("unhealthy", 10, 1).with_health(ChannelHealth::Unhealthy),
            candidate("zero", 10, 0),
            candidate("selectable", 10, 1),
        ]);

        let reason_for = |id: &str| {
            evaluated
                .iter()
                .find(|candidate| candidate.candidate.channel_id == id)
                .and_then(|candidate| candidate.filter_reason)
        };

        assert_eq!(
            reason_for("disabled"),
            Some(CandidateFilterReason::Disabled)
        );
        assert_eq!(
            reason_for("cooldown"),
            Some(CandidateFilterReason::CoolingDown)
        );
        assert_eq!(
            reason_for("recovery"),
            Some(CandidateFilterReason::RecoveryProbe)
        );
        assert_eq!(reason_for("auth"), Some(CandidateFilterReason::AuthFailed));
        assert_eq!(
            reason_for("quota"),
            Some(CandidateFilterReason::QuotaExhausted)
        );
        assert_eq!(
            reason_for("manual"),
            Some(CandidateFilterReason::ManualDisabled)
        );
        assert_eq!(reason_for("deleted"), Some(CandidateFilterReason::Deleted));
        assert_eq!(
            reason_for("rate-limit"),
            Some(CandidateFilterReason::RateLimitExceeded)
        );
        assert_eq!(
            reason_for("unhealthy"),
            Some(CandidateFilterReason::Unhealthy)
        );
        assert_eq!(reason_for("zero"), Some(CandidateFilterReason::ZeroWeight));
        assert_eq!(reason_for("selectable"), None);
    }

    #[test]
    fn returns_no_selection_when_candidate_list_is_empty() {
        let decision = select_route(RouteRequest::new("gpt-test", 0), []);

        assert_eq!(decision.selected_channel_id, None);
        assert_eq!(decision.selected, None);
        assert!(decision.candidates.is_empty());

        let snapshot = decision.snapshot();
        assert_eq!(snapshot.selected_channel_id, None);
        assert!(snapshot.candidates.is_empty());
    }

    #[test]
    fn returns_no_selection_when_every_candidate_is_filtered() {
        let decision = select_route(
            RouteRequest::new("gpt-test", 0),
            [
                candidate("disabled", 10, 1).with_status(ChannelStatus::Disabled),
                candidate("unhealthy", 20, 1).with_health(ChannelHealth::Unhealthy),
            ],
        );

        assert_eq!(decision.selected_channel_id, None);
        assert_eq!(decision.selected, None);
    }

    #[test]
    fn degraded_status_remains_selectable_for_health_aware_routing() {
        let decision = select_route(
            RouteRequest::new("gpt-test", 0),
            [candidate("degraded", 10, 1)
                .with_status(ChannelStatus::Degraded)
                .with_health(ChannelHealth::Degraded)],
        );

        assert_eq!(decision.selected_channel_id.as_deref(), Some("degraded"));
    }

    #[test]
    fn route_decision_snapshot_includes_scores_filters_and_selection() {
        let decision = select_route_with_context(
            RouteRequest::new("gpt-test", 11).with_canonical_model("canonical/test"),
            [
                candidate("selected", 10, 5),
                candidate("filtered", 5, 10).with_status(ChannelStatus::Disabled),
            ],
            RouteSelectionContext::default(),
        );

        let snapshot = decision.snapshot();

        assert_eq!(snapshot.version, ROUTE_DECISION_SNAPSHOT_VERSION);
        assert_eq!(snapshot.requested_model, "gpt-test");
        assert_eq!(snapshot.canonical_model.as_deref(), Some("canonical/test"));
        assert_eq!(snapshot.policy.seed, 11);
        assert_eq!(snapshot.selected_channel_id.as_deref(), Some("selected"));

        let selected = snapshot
            .candidates
            .iter()
            .find(|candidate| candidate.channel_id == "selected")
            .expect("selected candidate should be present in snapshot");
        assert!(selected.selected);
        assert!(!selected.filtered);
        assert_eq!(selected.filter_reason, None);
        assert_eq!(
            selected.score,
            Some(RouteCandidateScore {
                priority: 10,
                weight: 5,
                trace_affinity_bonus: 0,
                total: 2_147_483_642,
            })
        );

        let filtered = snapshot
            .candidates
            .iter()
            .find(|candidate| candidate.channel_id == "filtered")
            .expect("filtered candidate should be present in snapshot");
        assert!(!filtered.selected);
        assert!(filtered.filtered);
        assert_eq!(
            filtered.filter_reason,
            Some(CandidateFilterReason::Disabled)
        );
        assert_eq!(filtered.score, None);
    }

    #[test]
    fn rate_limit_filter_reason_is_stable_in_decision_snapshot() {
        let decision = select_route(
            RouteRequest::new("gpt-test", 0),
            [
                candidate("rpm-exceeded", 10, 100).with_rate_limit_available(false),
                candidate("fallback", 20, 1),
            ],
        );

        assert_eq!(decision.selected_channel_id.as_deref(), Some("fallback"));

        let rate_limited = decision
            .candidates
            .iter()
            .find(|candidate| candidate.candidate.channel_id == "rpm-exceeded")
            .expect("rate-limited candidate should be evaluated");
        assert_eq!(
            rate_limited.filter_reason,
            Some(CandidateFilterReason::RateLimitExceeded)
        );

        let snapshot = decision.snapshot();
        let snapshot_candidate = snapshot
            .candidates
            .iter()
            .find(|candidate| candidate.channel_id == "rpm-exceeded")
            .expect("rate-limited candidate should be present in snapshot");
        assert!(snapshot_candidate.filtered);
        assert!(!snapshot_candidate.rate_limit_available);
        assert_eq!(
            snapshot_candidate.filter_reason,
            Some(CandidateFilterReason::RateLimitExceeded)
        );
        assert_eq!(snapshot_candidate.score, None);
        assert!(!snapshot_candidate.selected);
    }

    #[test]
    fn trace_affinity_prefers_previous_successful_channel_for_same_trace() {
        let decision = select_route_with_context(
            RouteRequest::new("gpt-test", 0),
            [
                candidate("priority-winner", 10, 100),
                candidate("trace-success", 20, 1),
            ],
            RouteSelectionContext::for_trace("trace-1")
                .with_trace_affinity_channel("trace-success"),
        );

        assert_eq!(
            decision.selected_channel_id.as_deref(),
            Some("trace-success")
        );
        assert_eq!(decision.trace_id.as_deref(), Some("trace-1"));
        assert_eq!(decision.trace_affinity.status, TraceAffinityStatus::Applied);
        assert_eq!(
            decision.trace_affinity.applied_channel_id.as_deref(),
            Some("trace-success")
        );

        let snapshot = decision.snapshot();
        let affinity_candidate = snapshot
            .candidates
            .iter()
            .find(|candidate| candidate.channel_id == "trace-success")
            .expect("affinity candidate should be present in snapshot");
        assert!(affinity_candidate.selected);
        assert!(affinity_candidate.trace_affinity_match);
        assert_eq!(
            affinity_candidate
                .score
                .map(|score| score.trace_affinity_bonus),
            Some(1)
        );
    }

    #[test]
    fn trace_affinity_reports_previous_channel_not_candidate_for_empty_candidates() {
        let decision = select_route_with_context(
            RouteRequest::new("gpt-test", 0),
            [],
            RouteSelectionContext::for_trace("trace-1")
                .with_trace_affinity_channel("trace-success"),
        );

        assert_eq!(decision.selected_channel_id, None);
        assert_eq!(
            decision.trace_affinity.status,
            TraceAffinityStatus::PreviousChannelNotCandidate
        );
        assert_eq!(decision.trace_affinity.trace_id.as_deref(), Some("trace-1"));
        assert_eq!(
            decision
                .trace_affinity
                .previous_successful_channel_id
                .as_deref(),
            Some("trace-success")
        );
        assert_eq!(decision.trace_affinity.applied_channel_id, None);
    }

    #[test]
    fn trace_affinity_can_pin_different_traces_to_different_channels() {
        let candidates = [
            candidate("blue", 10, 100),
            candidate("green", 10, 100),
            candidate("red", 10, 100),
        ];

        let blue_trace = select_route_with_context(
            RouteRequest::new("gpt-test", 0),
            candidates.clone(),
            RouteSelectionContext::for_trace("trace-blue").with_trace_affinity_channel("blue"),
        );
        let green_trace = select_route_with_context(
            RouteRequest::new("gpt-test", 0),
            candidates,
            RouteSelectionContext::for_trace("trace-green").with_trace_affinity_channel("green"),
        );

        assert_eq!(blue_trace.selected_channel_id.as_deref(), Some("blue"));
        assert_eq!(green_trace.selected_channel_id.as_deref(), Some("green"));
        assert_ne!(
            blue_trace.selected_channel_id,
            green_trace.selected_channel_id
        );
        assert_eq!(
            blue_trace.trace_affinity.status,
            TraceAffinityStatus::Applied
        );
        assert_eq!(
            green_trace.trace_affinity.status,
            TraceAffinityStatus::Applied
        );
    }

    #[test]
    fn trace_affinity_falls_back_when_previous_successful_channel_is_filtered() {
        let decision = select_route_with_context(
            RouteRequest::new("gpt-test", 0),
            [
                candidate("trace-success", 10, 1).with_status(ChannelStatus::Disabled),
                candidate("fallback", 20, 1),
            ],
            RouteSelectionContext::for_trace("trace-1")
                .with_trace_affinity_channel("trace-success"),
        );

        assert_eq!(decision.selected_channel_id.as_deref(), Some("fallback"));
        assert_eq!(
            decision.trace_affinity.status,
            TraceAffinityStatus::PreviousChannelFiltered
        );

        let snapshot = decision.snapshot();
        let filtered_affinity_candidate = snapshot
            .candidates
            .iter()
            .find(|candidate| candidate.channel_id == "trace-success")
            .expect("affinity candidate should be present in snapshot");
        assert!(filtered_affinity_candidate.filtered);
        assert!(filtered_affinity_candidate.trace_affinity_match);
        assert_eq!(
            filtered_affinity_candidate.filter_reason,
            Some(CandidateFilterReason::Disabled)
        );
    }

    #[test]
    fn route_decision_snapshot_fixture_contract_is_stable() {
        let fixture: SnapshotContractFixture = serde_json::from_str(include_str!(
            "../../../tests/fixtures/routing/route_decision_snapshot_contract.json"
        ))
        .expect("route decision snapshot fixture should be valid");

        let decision = select_route_from_evaluated(
            fixture.input.request,
            fixture.input.evaluated_candidates,
            fixture.input.context,
        );
        let snapshot = decision.snapshot();

        assert_eq!(snapshot, fixture.expected_snapshot);
        assert_eq!(
            route_decision_snapshot_summary_value(&snapshot),
            fixture.expected_snapshot_summary
        );
    }

    #[test]
    fn route_decision_snapshot_fixture_omits_credential_and_payload_material() {
        let fixture =
            include_str!("../../../tests/fixtures/routing/route_decision_snapshot_contract.json");
        assert_no_routing_sensitive_material(fixture);

        let contract: SnapshotContractFixture =
            serde_json::from_str(fixture).expect("route decision snapshot fixture should be valid");
        let decision = select_route_from_evaluated(
            contract.input.request,
            contract.input.evaluated_candidates,
            contract.input.context,
        );
        let snapshot_json =
            serde_json::to_string(&decision.snapshot()).expect("snapshot should serialize");
        assert_no_routing_sensitive_material(&snapshot_json);
    }

    fn route_decision_snapshot_summary_value(snapshot: &RouteDecisionSnapshot) -> Value {
        let filter_reasons = snapshot
            .candidates
            .iter()
            .filter_map(|candidate| candidate.filter_reason)
            .map(|reason| json!(reason))
            .collect::<Vec<_>>();
        let selected_score_total = snapshot
            .candidates
            .iter()
            .find(|candidate| candidate.selected)
            .and_then(|candidate| candidate.score)
            .map(|score| score.total);

        json!({
            "version": snapshot.version,
            "requested_model": &snapshot.requested_model,
            "canonical_model": &snapshot.canonical_model,
            "selected_channel_id": &snapshot.selected_channel_id,
            "selected_provider_model": snapshot.selected.as_ref().map(|selected| selected.provider_model.clone()),
            "candidate_count": snapshot.candidates.len(),
            "filtered_count": snapshot.candidates.iter().filter(|candidate| candidate.filtered).count(),
            "filter_reasons": filter_reasons,
            "selected_score_total": selected_score_total,
            "trace_affinity_status": snapshot.trace_affinity.status,
        })
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
