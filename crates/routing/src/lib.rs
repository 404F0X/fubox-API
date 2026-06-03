mod candidate_generation;
mod coding_agent_profiles;
mod errors;
mod model_mapping;
mod rate_limit;
mod selection;

pub use candidate_generation::{
    CanonicalModelRouteInput, CanonicalModelStatus, CanonicalModelVisibility, ChannelRouteInput,
    GeneratedRouteCandidate, ModelAssociationRouteInput, ModelAssociationStatus,
    ModelAssociationTarget, ModelAssociationType, ProfileRouteConstraints,
    ROUTE_PRIORITY_ASSOCIATION_MULTIPLIER, RouteCandidateGenerationInput,
    RouteCandidateGenerationResult, generate_route_candidates, route_priority_for_generation,
    selectable_route_candidates,
};
pub use coding_agent_profiles::{
    CodingAgentChannelTagPreference, CodingAgentFallbackPolicy, CodingAgentLargeContextPreference,
    CodingAgentModelAliasPurpose, CodingAgentModelAliasRecommendation,
    CodingAgentPayloadPolicyExpectation, CodingAgentPreference, CodingAgentProfileKind,
    CodingAgentProfilePlan, CodingAgentRoutePolicySummary, CodingAgentStreamingPreference,
    CodingAgentToolFunctionSupportExpectation, coding_agent_profile_plan,
    coding_agent_profile_plan_from_kind, coding_agent_profile_route_constraints,
    supported_coding_agent_profile_kinds,
};
pub use errors::{
    AdapterProviderErrorRoutingClassification, AdapterProviderErrorRoutingInput,
    AdapterProviderErrorTransportKind, HealthImpact, ProviderErrorClassification,
    ProviderErrorFallbackDecision, ProviderErrorKind, ProviderErrorSignal, ProviderStreamErrorKind,
    ProviderTransportErrorKind, adapter_provider_error_signal, classify_adapter_provider_error,
    classify_provider_error,
};
pub use model_mapping::{
    ChannelModelMappingPolicy, ExplicitModelMapping, ModelNameCasePolicy, map_upstream_model_name,
};
pub use rate_limit::{
    RateLimitAvailability, RateLimitAvailabilityInput, RateLimitDimension,
    RateLimitDimensionStatus, RateLimitDimensionSummary, RateLimitWindow,
    apply_rate_limit_availability_to_candidate, evaluate_rate_limit_availability,
    evaluate_rate_limit_dimension,
};
pub use selection::{
    CandidateFilterReason, ChannelHealth, ChannelStatus, EvaluatedCandidate,
    ROUTE_DECISION_SNAPSHOT_VERSION, RouteCandidate, RouteCandidateScore, RouteDecision,
    RouteDecisionSnapshot, RouteDecisionSnapshotCandidate, RouteRequest, RouteSelectionContext,
    SelectedRoute, SelectionPolicy, TraceAffinity, TraceAffinityDecision, TraceAffinityStatus,
    evaluate_candidates, select_route, select_route_from_evaluated, select_route_with_context,
};
