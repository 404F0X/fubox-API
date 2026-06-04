use crate::selection::{CandidateFilterReason, RouteCandidate};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum RateLimitDimension {
    RequestsPerMinute,
    TokensPerMinute,
    Concurrency,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum RateLimitDimensionStatus {
    Unlimited,
    WindowMissing,
    Available,
    Exceeded,
    InvalidLimit,
    InvalidRequired,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct RateLimitWindow {
    pub limit: Option<i64>,
    pub used: Option<i64>,
    pub required: i64,
}

impl RateLimitWindow {
    pub const fn unlimited() -> Self {
        Self {
            limit: None,
            used: None,
            required: 0,
        }
    }

    pub const fn limited(limit: i64, used: i64, required: i64) -> Self {
        Self {
            limit: Some(limit),
            used: Some(used),
            required,
        }
    }

    pub const fn missing(limit: i64, required: i64) -> Self {
        Self {
            limit: Some(limit),
            used: None,
            required,
        }
    }
}

impl Default for RateLimitWindow {
    fn default() -> Self {
        Self::unlimited()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct RateLimitAvailabilityInput {
    pub requests_per_minute: RateLimitWindow,
    pub tokens_per_minute: RateLimitWindow,
    pub concurrency: RateLimitWindow,
}

impl RateLimitAvailabilityInput {
    pub const fn new(
        requests_per_minute: RateLimitWindow,
        tokens_per_minute: RateLimitWindow,
        concurrency: RateLimitWindow,
    ) -> Self {
        Self {
            requests_per_minute,
            tokens_per_minute,
            concurrency,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RateLimitDimensionSummary {
    pub dimension: RateLimitDimension,
    pub status: RateLimitDimensionStatus,
    pub selectable: bool,
    pub limit: Option<u64>,
    pub used: u64,
    pub required: u64,
    pub remaining: Option<u64>,
    pub window_present: bool,
    pub sanitized_negative_used: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RateLimitAvailability {
    pub selectable: bool,
    pub filter_reason: Option<CandidateFilterReason>,
    pub blocking_dimensions: Vec<RateLimitDimension>,
    pub dimensions: Vec<RateLimitDimensionSummary>,
}

pub const RATE_LIMIT_RESERVATION_CONTRACT_SCHEMA: &str = "rate_limit_reservation_contract_v1";
pub const RATE_LIMIT_TPM_ESTIMATE_CONTRACT_SCHEMA: &str = "rate_limit_tpm_estimate_contract_v1";
pub const RATE_LIMIT_DEFAULT_TPM_FALLBACK_TOKENS: i64 = 1_024;
pub const RATE_LIMIT_MIN_TPM_RESERVATION_TOKENS: u64 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum RateLimitTpmEstimateSource {
    TotalTokens,
    PromptAndCompletion,
    PromptAndMaxCompletion,
    PartialEstimateWithConservativeFallback,
    ConservativeFallback,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct RateLimitTpmEstimateInput {
    pub prompt_tokens: Option<i64>,
    pub completion_tokens: Option<i64>,
    pub max_completion_tokens: Option<i64>,
    pub total_tokens: Option<i64>,
    pub conservative_fallback_tokens: i64,
}

impl RateLimitTpmEstimateInput {
    pub const fn new(
        prompt_tokens: Option<i64>,
        completion_tokens: Option<i64>,
        max_completion_tokens: Option<i64>,
        total_tokens: Option<i64>,
        conservative_fallback_tokens: i64,
    ) -> Self {
        Self {
            prompt_tokens,
            completion_tokens,
            max_completion_tokens,
            total_tokens,
            conservative_fallback_tokens,
        }
    }
}

impl Default for RateLimitTpmEstimateInput {
    fn default() -> Self {
        Self {
            prompt_tokens: None,
            completion_tokens: None,
            max_completion_tokens: None,
            total_tokens: None,
            conservative_fallback_tokens: RATE_LIMIT_DEFAULT_TPM_FALLBACK_TOKENS,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RateLimitTpmReservationEstimate {
    pub required_tokens: u64,
    pub source: RateLimitTpmEstimateSource,
    pub prompt_tokens: Option<u64>,
    pub completion_tokens: Option<u64>,
    pub max_completion_tokens: Option<u64>,
    pub completion_reservation_tokens: Option<u64>,
    pub fallback_tokens: u64,
    pub used_conservative_fallback: bool,
    pub sanitized_negative_estimate: bool,
    pub clamped_to_i64_max: bool,
    pub body_material_in_output: bool,
}

impl RateLimitTpmReservationEstimate {
    pub fn required_tokens_i64(&self) -> i64 {
        self.required_tokens.min(i64::MAX as u64) as i64
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum RateLimitReservationOperation {
    Acquire,
    Release,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum RateLimitReservationStatus {
    Acquired,
    Rejected,
    Released,
    ReleaseNoop,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum RateLimitCounterUpdate {
    None,
    Increment,
    Decrement,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct RateLimitCounterWindow {
    pub limit: Option<i64>,
    pub used: Option<i64>,
}

impl RateLimitCounterWindow {
    pub const fn unlimited() -> Self {
        Self {
            limit: None,
            used: None,
        }
    }

    pub const fn limited(limit: i64, used: i64) -> Self {
        Self {
            limit: Some(limit),
            used: Some(used),
        }
    }

    pub const fn missing(limit: i64) -> Self {
        Self {
            limit: Some(limit),
            used: None,
        }
    }
}

impl Default for RateLimitCounterWindow {
    fn default() -> Self {
        Self::unlimited()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct RateLimitRequiredCapacity {
    pub requests_per_minute: i64,
    pub tokens_per_minute: i64,
    pub concurrency: i64,
}

impl RateLimitRequiredCapacity {
    pub const fn new(requests_per_minute: i64, tokens_per_minute: i64, concurrency: i64) -> Self {
        Self {
            requests_per_minute,
            tokens_per_minute,
            concurrency,
        }
    }

    pub fn from_tpm_estimate(
        requests_per_minute: i64,
        tpm_estimate: &RateLimitTpmReservationEstimate,
        concurrency: i64,
    ) -> Self {
        Self {
            requests_per_minute,
            tokens_per_minute: tpm_estimate.required_tokens_i64(),
            concurrency,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct RateLimitReservationInput {
    pub requests_per_minute: RateLimitCounterWindow,
    pub tokens_per_minute: RateLimitCounterWindow,
    pub concurrency: RateLimitCounterWindow,
    pub required: RateLimitRequiredCapacity,
    pub operation: RateLimitReservationOperation,
    pub reservation_acquired: bool,
}

impl RateLimitReservationInput {
    pub const fn acquire(
        requests_per_minute: RateLimitCounterWindow,
        tokens_per_minute: RateLimitCounterWindow,
        concurrency: RateLimitCounterWindow,
        required: RateLimitRequiredCapacity,
    ) -> Self {
        Self {
            requests_per_minute,
            tokens_per_minute,
            concurrency,
            required,
            operation: RateLimitReservationOperation::Acquire,
            reservation_acquired: false,
        }
    }

    pub const fn release(
        requests_per_minute: RateLimitCounterWindow,
        tokens_per_minute: RateLimitCounterWindow,
        concurrency: RateLimitCounterWindow,
        required: RateLimitRequiredCapacity,
        reservation_acquired: bool,
    ) -> Self {
        Self {
            requests_per_minute,
            tokens_per_minute,
            concurrency,
            required,
            operation: RateLimitReservationOperation::Release,
            reservation_acquired,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RateLimitReservationDimensionPlan {
    pub dimension: RateLimitDimension,
    pub status: RateLimitDimensionStatus,
    pub selectable_for_acquire: bool,
    pub limit: Option<u64>,
    pub used_before: u64,
    pub required: u64,
    pub used_after: u64,
    pub remaining_before: Option<u64>,
    pub remaining_after: Option<u64>,
    pub window_present: bool,
    pub sanitized_negative_used: bool,
    pub counter_update: RateLimitCounterUpdate,
    pub saturated_release: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RateLimitReservationPlan {
    pub operation: RateLimitReservationOperation,
    pub status: RateLimitReservationStatus,
    pub filter_reason: Option<CandidateFilterReason>,
    pub blocking_dimensions: Vec<RateLimitDimension>,
    pub dimensions: Vec<RateLimitReservationDimensionPlan>,
    pub conservative_reject: bool,
    pub counter_updates_planned: usize,
    pub window_material_in_output: bool,
}

pub fn evaluate_rate_limit_availability(
    input: RateLimitAvailabilityInput,
) -> RateLimitAvailability {
    let dimensions = [
        evaluate_rate_limit_dimension(
            RateLimitDimension::RequestsPerMinute,
            input.requests_per_minute,
        ),
        evaluate_rate_limit_dimension(RateLimitDimension::TokensPerMinute, input.tokens_per_minute),
        evaluate_rate_limit_dimension(RateLimitDimension::Concurrency, input.concurrency),
    ];

    let blocking_dimensions = dimensions
        .iter()
        .filter(|dimension| !dimension.selectable)
        .map(|dimension| dimension.dimension)
        .collect::<Vec<_>>();
    let selectable = blocking_dimensions.is_empty();

    RateLimitAvailability {
        selectable,
        filter_reason: (!selectable).then_some(CandidateFilterReason::RateLimitExceeded),
        blocking_dimensions,
        dimensions: dimensions.to_vec(),
    }
}

pub fn apply_rate_limit_availability_to_candidate(
    candidate: RouteCandidate,
    availability: &RateLimitAvailability,
) -> RouteCandidate {
    candidate.with_rate_limit_available(availability.selectable)
}

pub fn estimate_tpm_reservation(
    input: RateLimitTpmEstimateInput,
) -> RateLimitTpmReservationEstimate {
    let (prompt_tokens, prompt_negative) = sanitize_optional_token_estimate(input.prompt_tokens);
    let (completion_tokens, completion_negative) =
        sanitize_optional_token_estimate(input.completion_tokens);
    let (max_completion_tokens, max_completion_negative) =
        sanitize_optional_token_estimate(input.max_completion_tokens);
    let (total_tokens, total_negative) = sanitize_optional_token_estimate(input.total_tokens);
    let (fallback_tokens, fallback_sanitized) =
        sanitize_conservative_fallback_tokens(input.conservative_fallback_tokens);
    let completion_reservation_tokens =
        completion_reservation_tokens(completion_tokens, max_completion_tokens);

    let (required_tokens, source, used_conservative_fallback) = if let Some(total_tokens) =
        total_tokens
    {
        (
            total_tokens.max(RATE_LIMIT_MIN_TPM_RESERVATION_TOKENS),
            RateLimitTpmEstimateSource::TotalTokens,
            false,
        )
    } else if let (Some(prompt_tokens), Some(completion_reservation_tokens)) =
        (prompt_tokens, completion_reservation_tokens)
    {
        let max_completion_drives_reservation = match (completion_tokens, max_completion_tokens) {
            (Some(completion_tokens), Some(max_completion_tokens)) => {
                max_completion_tokens > completion_tokens
            }
            (None, Some(_)) => true,
            _ => false,
        };
        let source = if max_completion_drives_reservation {
            RateLimitTpmEstimateSource::PromptAndMaxCompletion
        } else {
            RateLimitTpmEstimateSource::PromptAndCompletion
        };

        (
            prompt_tokens
                .saturating_add(completion_reservation_tokens)
                .max(RATE_LIMIT_MIN_TPM_RESERVATION_TOKENS),
            source,
            false,
        )
    } else if prompt_tokens.is_some() || completion_reservation_tokens.is_some() {
        let required_tokens = prompt_tokens
            .unwrap_or(fallback_tokens)
            .saturating_add(completion_reservation_tokens.unwrap_or(fallback_tokens))
            .max(RATE_LIMIT_MIN_TPM_RESERVATION_TOKENS);
        (
            required_tokens,
            RateLimitTpmEstimateSource::PartialEstimateWithConservativeFallback,
            true,
        )
    } else {
        (
            fallback_tokens.max(RATE_LIMIT_MIN_TPM_RESERVATION_TOKENS),
            RateLimitTpmEstimateSource::ConservativeFallback,
            true,
        )
    };

    RateLimitTpmReservationEstimate {
        required_tokens,
        source,
        prompt_tokens,
        completion_tokens,
        max_completion_tokens,
        completion_reservation_tokens,
        fallback_tokens,
        used_conservative_fallback,
        sanitized_negative_estimate: prompt_negative
            || completion_negative
            || max_completion_negative
            || total_negative
            || fallback_sanitized,
        clamped_to_i64_max: required_tokens > i64::MAX as u64,
        body_material_in_output: false,
    }
}

pub fn plan_rate_limit_reservation(input: RateLimitReservationInput) -> RateLimitReservationPlan {
    let availability_input = reservation_availability_input(&input);
    let availability = evaluate_rate_limit_availability(availability_input);
    let invalid_required = availability
        .dimensions
        .iter()
        .any(|dimension| dimension.status == RateLimitDimensionStatus::InvalidRequired);

    let status = match input.operation {
        RateLimitReservationOperation::Acquire if availability.selectable => {
            RateLimitReservationStatus::Acquired
        }
        RateLimitReservationOperation::Acquire => RateLimitReservationStatus::Rejected,
        RateLimitReservationOperation::Release if !input.reservation_acquired => {
            RateLimitReservationStatus::ReleaseNoop
        }
        RateLimitReservationOperation::Release if invalid_required => {
            RateLimitReservationStatus::Rejected
        }
        RateLimitReservationOperation::Release => RateLimitReservationStatus::Released,
    };

    let blocking_dimensions = match status {
        RateLimitReservationStatus::Rejected => availability
            .dimensions
            .iter()
            .filter(|dimension| !dimension.selectable)
            .map(|dimension| dimension.dimension)
            .collect::<Vec<_>>(),
        RateLimitReservationStatus::Acquired
        | RateLimitReservationStatus::Released
        | RateLimitReservationStatus::ReleaseNoop => Vec::new(),
    };
    let conservative_reject = status == RateLimitReservationStatus::Rejected
        && availability
            .dimensions
            .iter()
            .any(|dimension| dimension.status == RateLimitDimensionStatus::WindowMissing);
    let dimensions = availability
        .dimensions
        .iter()
        .map(|dimension| reservation_dimension_plan(input.operation, status, dimension))
        .collect::<Vec<_>>();
    let counter_updates_planned = dimensions
        .iter()
        .filter(|dimension| dimension.counter_update != RateLimitCounterUpdate::None)
        .count();

    RateLimitReservationPlan {
        operation: input.operation,
        status,
        filter_reason: (status == RateLimitReservationStatus::Rejected)
            .then_some(CandidateFilterReason::RateLimitExceeded),
        blocking_dimensions,
        dimensions,
        conservative_reject,
        counter_updates_planned,
        window_material_in_output: false,
    }
}

pub fn evaluate_rate_limit_dimension(
    dimension: RateLimitDimension,
    window: RateLimitWindow,
) -> RateLimitDimensionSummary {
    let required = window.required.max(0) as u64;

    if window.required < 0 {
        return RateLimitDimensionSummary {
            dimension,
            status: RateLimitDimensionStatus::InvalidRequired,
            selectable: false,
            limit: window.limit.and_then(non_negative_u64),
            used: window.used.unwrap_or_default().max(0) as u64,
            required,
            remaining: None,
            window_present: window.used.is_some(),
            sanitized_negative_used: window.used.is_some_and(|used| used < 0),
        };
    }

    let Some(raw_limit) = window.limit else {
        return RateLimitDimensionSummary {
            dimension,
            status: RateLimitDimensionStatus::Unlimited,
            selectable: true,
            limit: None,
            used: window.used.unwrap_or_default().max(0) as u64,
            required,
            remaining: None,
            window_present: window.used.is_some(),
            sanitized_negative_used: window.used.is_some_and(|used| used < 0),
        };
    };

    if raw_limit < 0 {
        return RateLimitDimensionSummary {
            dimension,
            status: RateLimitDimensionStatus::InvalidLimit,
            selectable: false,
            limit: None,
            used: window.used.unwrap_or_default().max(0) as u64,
            required,
            remaining: None,
            window_present: window.used.is_some(),
            sanitized_negative_used: window.used.is_some_and(|used| used < 0),
        };
    }

    let limit = raw_limit as u64;
    let Some(raw_used) = window.used else {
        return RateLimitDimensionSummary {
            dimension,
            status: RateLimitDimensionStatus::WindowMissing,
            selectable: false,
            limit: Some(limit),
            used: 0,
            required,
            remaining: Some(limit),
            window_present: false,
            sanitized_negative_used: false,
        };
    };

    let used = raw_used.max(0) as u64;
    let remaining = limit.saturating_sub(used);
    let selectable = used <= limit && required <= remaining;
    let status = if selectable {
        RateLimitDimensionStatus::Available
    } else {
        RateLimitDimensionStatus::Exceeded
    };

    RateLimitDimensionSummary {
        dimension,
        status,
        selectable,
        limit: Some(limit),
        used,
        required,
        remaining: Some(remaining),
        window_present: true,
        sanitized_negative_used: raw_used < 0,
    }
}

fn non_negative_u64(value: i64) -> Option<u64> {
    (value >= 0).then_some(value as u64)
}

fn sanitize_optional_token_estimate(value: Option<i64>) -> (Option<u64>, bool) {
    match value {
        Some(value) if value >= 0 => (Some(value as u64), false),
        Some(_) => (None, true),
        None => (None, false),
    }
}

fn sanitize_conservative_fallback_tokens(value: i64) -> (u64, bool) {
    if value > 0 {
        (value as u64, false)
    } else {
        (RATE_LIMIT_DEFAULT_TPM_FALLBACK_TOKENS as u64, true)
    }
}

fn completion_reservation_tokens(
    completion_tokens: Option<u64>,
    max_completion_tokens: Option<u64>,
) -> Option<u64> {
    match (completion_tokens, max_completion_tokens) {
        (Some(completion_tokens), Some(max_completion_tokens)) => {
            Some(completion_tokens.max(max_completion_tokens))
        }
        (Some(completion_tokens), None) => Some(completion_tokens),
        (None, Some(max_completion_tokens)) => Some(max_completion_tokens),
        (None, None) => None,
    }
}

fn reservation_availability_input(input: &RateLimitReservationInput) -> RateLimitAvailabilityInput {
    RateLimitAvailabilityInput::new(
        reservation_window(
            input.requests_per_minute,
            input.required.requests_per_minute,
        ),
        reservation_window(input.tokens_per_minute, input.required.tokens_per_minute),
        reservation_window(input.concurrency, input.required.concurrency),
    )
}

fn reservation_window(window: RateLimitCounterWindow, required: i64) -> RateLimitWindow {
    RateLimitWindow {
        limit: window.limit,
        used: window.used,
        required,
    }
}

fn reservation_dimension_plan(
    operation: RateLimitReservationOperation,
    reservation_status: RateLimitReservationStatus,
    summary: &RateLimitDimensionSummary,
) -> RateLimitReservationDimensionPlan {
    let counter_update = counter_update_for_dimension(operation, reservation_status, summary);
    let used_after = match counter_update {
        RateLimitCounterUpdate::Increment => summary.used.saturating_add(summary.required),
        RateLimitCounterUpdate::Decrement => summary.used.saturating_sub(summary.required),
        RateLimitCounterUpdate::None => summary.used,
    };
    let remaining_after = summary.limit.map(|limit| limit.saturating_sub(used_after));
    let saturated_release =
        counter_update == RateLimitCounterUpdate::Decrement && summary.required > summary.used;

    RateLimitReservationDimensionPlan {
        dimension: summary.dimension,
        status: summary.status,
        selectable_for_acquire: summary.selectable,
        limit: summary.limit,
        used_before: summary.used,
        required: summary.required,
        used_after,
        remaining_before: summary.remaining,
        remaining_after,
        window_present: summary.window_present,
        sanitized_negative_used: summary.sanitized_negative_used,
        counter_update,
        saturated_release,
    }
}

fn counter_update_for_dimension(
    operation: RateLimitReservationOperation,
    reservation_status: RateLimitReservationStatus,
    summary: &RateLimitDimensionSummary,
) -> RateLimitCounterUpdate {
    if summary.limit.is_none() || !summary.window_present || summary.required == 0 {
        return RateLimitCounterUpdate::None;
    }

    match (operation, reservation_status) {
        (RateLimitReservationOperation::Acquire, RateLimitReservationStatus::Acquired) => {
            RateLimitCounterUpdate::Increment
        }
        (RateLimitReservationOperation::Release, RateLimitReservationStatus::Released) => {
            RateLimitCounterUpdate::Decrement
        }
        _ => RateLimitCounterUpdate::None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn summary_for(
        availability: &RateLimitAvailability,
        dimension: RateLimitDimension,
    ) -> &RateLimitDimensionSummary {
        availability
            .dimensions
            .iter()
            .find(|summary| summary.dimension == dimension)
            .expect("dimension summary should be present")
    }

    fn reservation_dimension_for(
        plan: &RateLimitReservationPlan,
        dimension: RateLimitDimension,
    ) -> &RateLimitReservationDimensionPlan {
        plan.dimensions
            .iter()
            .find(|summary| summary.dimension == dimension)
            .expect("reservation dimension plan should be present")
    }

    #[test]
    fn unlimited_windows_are_selectable_without_counters() {
        let availability = evaluate_rate_limit_availability(RateLimitAvailabilityInput::new(
            RateLimitWindow::unlimited(),
            RateLimitWindow::unlimited(),
            RateLimitWindow::unlimited(),
        ));

        assert!(availability.selectable);
        assert_eq!(availability.filter_reason, None);
        assert!(availability.blocking_dimensions.is_empty());

        let rpm = summary_for(&availability, RateLimitDimension::RequestsPerMinute);
        assert_eq!(rpm.status, RateLimitDimensionStatus::Unlimited);
        assert!(!rpm.window_present);
        assert_eq!(rpm.limit, None);
        assert_eq!(rpm.used, 0);
        assert_eq!(rpm.remaining, None);

        let tpm = summary_for(&availability, RateLimitDimension::TokensPerMinute);
        assert_eq!(tpm.status, RateLimitDimensionStatus::Unlimited);
        assert_eq!(tpm.limit, None);
        assert_eq!(tpm.remaining, None);
    }

    #[test]
    fn missing_limited_counters_block_selection_conservatively() {
        let availability = evaluate_rate_limit_availability(RateLimitAvailabilityInput::new(
            RateLimitWindow::missing(60, 1),
            RateLimitWindow::unlimited(),
            RateLimitWindow::missing(10, 1),
        ));

        assert!(!availability.selectable);
        assert_eq!(
            availability.filter_reason,
            Some(CandidateFilterReason::RateLimitExceeded)
        );
        assert_eq!(
            availability.blocking_dimensions,
            [
                RateLimitDimension::RequestsPerMinute,
                RateLimitDimension::Concurrency
            ]
        );

        let rpm = summary_for(&availability, RateLimitDimension::RequestsPerMinute);
        assert_eq!(rpm.status, RateLimitDimensionStatus::WindowMissing);
        assert!(!rpm.selectable);
        assert!(!rpm.window_present);
        assert_eq!(rpm.limit, Some(60));
        assert_eq!(rpm.used, 0);
        assert_eq!(rpm.remaining, Some(60));

        let tpm = summary_for(&availability, RateLimitDimension::TokensPerMinute);
        assert_eq!(tpm.status, RateLimitDimensionStatus::Unlimited);
        assert!(tpm.selectable);
    }

    #[test]
    fn under_limits_remain_selectable() {
        let availability = evaluate_rate_limit_availability(RateLimitAvailabilityInput::new(
            RateLimitWindow::limited(60, 58, 1),
            RateLimitWindow::limited(1_000, 800, 100),
            RateLimitWindow::limited(4, 3, 1),
        ));

        assert!(availability.selectable);
        assert_eq!(availability.filter_reason, None);
        assert!(availability.blocking_dimensions.is_empty());

        let rpm = summary_for(&availability, RateLimitDimension::RequestsPerMinute);
        assert_eq!(rpm.status, RateLimitDimensionStatus::Available);
        assert_eq!(rpm.remaining, Some(2));

        let tpm = summary_for(&availability, RateLimitDimension::TokensPerMinute);
        assert_eq!(tpm.status, RateLimitDimensionStatus::Available);
        assert_eq!(tpm.remaining, Some(200));

        let concurrency = summary_for(&availability, RateLimitDimension::Concurrency);
        assert_eq!(concurrency.status, RateLimitDimensionStatus::Available);
        assert_eq!(concurrency.remaining, Some(1));
    }

    #[test]
    fn rpm_limit_blocks_selection_with_rate_limit_reason() {
        let availability = evaluate_rate_limit_availability(RateLimitAvailabilityInput::new(
            RateLimitWindow::limited(60, 60, 1),
            RateLimitWindow::unlimited(),
            RateLimitWindow::unlimited(),
        ));

        assert!(!availability.selectable);
        assert_eq!(
            availability.filter_reason,
            Some(CandidateFilterReason::RateLimitExceeded)
        );
        assert_eq!(
            availability.blocking_dimensions,
            [RateLimitDimension::RequestsPerMinute]
        );

        let rpm = summary_for(&availability, RateLimitDimension::RequestsPerMinute);
        assert_eq!(rpm.status, RateLimitDimensionStatus::Exceeded);
        assert_eq!(rpm.remaining, Some(0));
    }

    #[test]
    fn tpm_limit_blocks_selection_with_rate_limit_reason() {
        let availability = evaluate_rate_limit_availability(RateLimitAvailabilityInput::new(
            RateLimitWindow::unlimited(),
            RateLimitWindow::limited(1_000, 950, 100),
            RateLimitWindow::unlimited(),
        ));

        assert!(!availability.selectable);
        assert_eq!(
            availability.filter_reason,
            Some(CandidateFilterReason::RateLimitExceeded)
        );
        assert_eq!(
            availability.blocking_dimensions,
            [RateLimitDimension::TokensPerMinute]
        );

        let tpm = summary_for(&availability, RateLimitDimension::TokensPerMinute);
        assert_eq!(tpm.status, RateLimitDimensionStatus::Exceeded);
        assert_eq!(tpm.remaining, Some(50));
        assert_eq!(tpm.required, 100);
    }

    #[test]
    fn concurrency_limit_blocks_selection_with_rate_limit_reason() {
        let availability = evaluate_rate_limit_availability(RateLimitAvailabilityInput::new(
            RateLimitWindow::unlimited(),
            RateLimitWindow::unlimited(),
            RateLimitWindow::limited(4, 4, 1),
        ));

        assert!(!availability.selectable);
        assert_eq!(
            availability.filter_reason,
            Some(CandidateFilterReason::RateLimitExceeded)
        );
        assert_eq!(
            availability.blocking_dimensions,
            [RateLimitDimension::Concurrency]
        );

        let concurrency = summary_for(&availability, RateLimitDimension::Concurrency);
        assert_eq!(concurrency.status, RateLimitDimensionStatus::Exceeded);
        assert_eq!(concurrency.remaining, Some(0));
    }

    #[test]
    fn zero_limits_and_missing_limits_have_stable_behavior() {
        let no_limits = evaluate_rate_limit_availability(RateLimitAvailabilityInput::new(
            RateLimitWindow::unlimited(),
            RateLimitWindow::unlimited(),
            RateLimitWindow::unlimited(),
        ));
        assert!(no_limits.selectable);

        let zero_capacity_needed = evaluate_rate_limit_dimension(
            RateLimitDimension::RequestsPerMinute,
            RateLimitWindow::limited(0, 0, 0),
        );
        assert!(zero_capacity_needed.selectable);
        assert_eq!(
            zero_capacity_needed.status,
            RateLimitDimensionStatus::Available
        );
        assert_eq!(zero_capacity_needed.remaining, Some(0));

        let positive_capacity_needed = evaluate_rate_limit_dimension(
            RateLimitDimension::RequestsPerMinute,
            RateLimitWindow::limited(0, 0, 1),
        );
        assert!(!positive_capacity_needed.selectable);
        assert_eq!(
            positive_capacity_needed.status,
            RateLimitDimensionStatus::Exceeded
        );
    }

    #[test]
    fn negative_and_invalid_values_are_stable() {
        let availability = evaluate_rate_limit_availability(RateLimitAvailabilityInput::new(
            RateLimitWindow::limited(10, -3, 1),
            RateLimitWindow::limited(-1, 0, 1),
            RateLimitWindow::limited(10, 0, -1),
        ));

        assert!(!availability.selectable);
        assert_eq!(
            availability.filter_reason,
            Some(CandidateFilterReason::RateLimitExceeded)
        );
        assert_eq!(
            availability.blocking_dimensions,
            [
                RateLimitDimension::TokensPerMinute,
                RateLimitDimension::Concurrency
            ]
        );

        let rpm = summary_for(&availability, RateLimitDimension::RequestsPerMinute);
        assert!(rpm.selectable);
        assert_eq!(rpm.status, RateLimitDimensionStatus::Available);
        assert_eq!(rpm.used, 0);
        assert!(rpm.sanitized_negative_used);

        let tpm = summary_for(&availability, RateLimitDimension::TokensPerMinute);
        assert!(!tpm.selectable);
        assert_eq!(tpm.status, RateLimitDimensionStatus::InvalidLimit);

        let concurrency = summary_for(&availability, RateLimitDimension::Concurrency);
        assert!(!concurrency.selectable);
        assert_eq!(
            concurrency.status,
            RateLimitDimensionStatus::InvalidRequired
        );
    }

    #[test]
    fn summary_does_not_carry_provider_auth_material() {
        let secret = "sk-live-provider-secret";
        let availability = evaluate_rate_limit_availability(RateLimitAvailabilityInput::new(
            RateLimitWindow::limited(1, 1, 1),
            RateLimitWindow::unlimited(),
            RateLimitWindow::unlimited(),
        ));

        let debug = format!("{availability:?}").to_ascii_lowercase();
        for forbidden in [
            secret,
            "provider_key",
            "api_key",
            "encrypted_secret",
            "authorization",
            "bearer",
        ] {
            assert!(
                !debug.contains(forbidden),
                "rate-limit summary should omit sensitive provider auth material: {forbidden}"
            );
        }
    }

    #[test]
    fn tpm_estimate_prefers_total_tokens_when_available() {
        let estimate = estimate_tpm_reservation(RateLimitTpmEstimateInput::new(
            Some(300),
            Some(128),
            Some(512),
            Some(700),
            1_024,
        ));

        assert_eq!(estimate.required_tokens, 700);
        assert_eq!(estimate.source, RateLimitTpmEstimateSource::TotalTokens);
        assert!(!estimate.used_conservative_fallback);
        assert!(!estimate.sanitized_negative_estimate);
        assert_eq!(estimate.prompt_tokens, Some(300));
        assert_eq!(estimate.completion_reservation_tokens, Some(512));
        assert_eq!(estimate.fallback_tokens, 1_024);
        assert!(!estimate.body_material_in_output);
    }

    #[test]
    fn tpm_estimate_uses_prompt_and_completion_without_fallback() {
        let estimate = estimate_tpm_reservation(RateLimitTpmEstimateInput::new(
            Some(220),
            Some(180),
            None,
            None,
            1_024,
        ));

        assert_eq!(estimate.required_tokens, 400);
        assert_eq!(
            estimate.source,
            RateLimitTpmEstimateSource::PromptAndCompletion
        );
        assert_eq!(estimate.completion_reservation_tokens, Some(180));
        assert!(!estimate.used_conservative_fallback);
    }

    #[test]
    fn tpm_estimate_uses_max_completion_bound_when_it_is_larger() {
        let estimate = estimate_tpm_reservation(RateLimitTpmEstimateInput::new(
            Some(220),
            Some(180),
            Some(512),
            None,
            1_024,
        ));

        assert_eq!(estimate.required_tokens, 732);
        assert_eq!(
            estimate.source,
            RateLimitTpmEstimateSource::PromptAndMaxCompletion
        );
        assert_eq!(estimate.completion_tokens, Some(180));
        assert_eq!(estimate.max_completion_tokens, Some(512));
        assert_eq!(estimate.completion_reservation_tokens, Some(512));
        assert!(!estimate.used_conservative_fallback);
    }

    #[test]
    fn tpm_estimate_uses_conservative_fallback_for_missing_or_invalid_data() {
        let missing =
            estimate_tpm_reservation(RateLimitTpmEstimateInput::new(None, None, None, None, 256));

        assert_eq!(missing.required_tokens, 256);
        assert_eq!(
            missing.source,
            RateLimitTpmEstimateSource::ConservativeFallback
        );
        assert!(missing.used_conservative_fallback);
        assert!(!missing.sanitized_negative_estimate);

        let partial = estimate_tpm_reservation(RateLimitTpmEstimateInput::new(
            Some(120),
            None,
            None,
            None,
            256,
        ));

        assert_eq!(partial.required_tokens, 376);
        assert_eq!(
            partial.source,
            RateLimitTpmEstimateSource::PartialEstimateWithConservativeFallback
        );
        assert!(partial.used_conservative_fallback);

        let invalid = estimate_tpm_reservation(RateLimitTpmEstimateInput::new(
            Some(-5),
            None,
            None,
            Some(-10),
            -1,
        ));

        assert_eq!(
            invalid.required_tokens,
            RATE_LIMIT_DEFAULT_TPM_FALLBACK_TOKENS as u64
        );
        assert_eq!(
            invalid.source,
            RateLimitTpmEstimateSource::ConservativeFallback
        );
        assert!(invalid.used_conservative_fallback);
        assert!(invalid.sanitized_negative_estimate);
    }

    #[test]
    fn tpm_estimate_clamps_zero_estimates_to_minimum_one_token() {
        let total_zero = estimate_tpm_reservation(RateLimitTpmEstimateInput::new(
            Some(300),
            Some(128),
            Some(512),
            Some(0),
            256,
        ));

        assert_eq!(
            total_zero.required_tokens,
            RATE_LIMIT_MIN_TPM_RESERVATION_TOKENS
        );
        assert_eq!(total_zero.required_tokens_i64(), 1);
        assert_eq!(total_zero.source, RateLimitTpmEstimateSource::TotalTokens);
        assert!(!total_zero.used_conservative_fallback);
        assert!(!total_zero.sanitized_negative_estimate);

        let prompt_completion_zero = estimate_tpm_reservation(RateLimitTpmEstimateInput::new(
            Some(0),
            Some(0),
            None,
            None,
            256,
        ));

        assert_eq!(
            prompt_completion_zero.required_tokens,
            RATE_LIMIT_MIN_TPM_RESERVATION_TOKENS
        );
        assert_eq!(
            prompt_completion_zero.source,
            RateLimitTpmEstimateSource::PromptAndCompletion
        );
        assert!(!prompt_completion_zero.used_conservative_fallback);
    }

    #[test]
    fn tpm_estimate_extreme_values_do_not_overflow_i64_capacity() {
        let estimate = estimate_tpm_reservation(RateLimitTpmEstimateInput::new(
            Some(i64::MAX),
            Some(i64::MAX),
            Some(i64::MAX),
            None,
            i64::MAX,
        ));
        let expected_tokens = (i64::MAX as u64).saturating_add(i64::MAX as u64);

        assert_eq!(estimate.required_tokens, expected_tokens);
        assert_eq!(
            estimate.source,
            RateLimitTpmEstimateSource::PromptAndCompletion
        );
        assert!(estimate.clamped_to_i64_max);
        assert_eq!(estimate.required_tokens_i64(), i64::MAX);

        let required = RateLimitRequiredCapacity::from_tpm_estimate(1, &estimate, 1);
        assert_eq!(required.tokens_per_minute, i64::MAX);

        let plan = plan_rate_limit_reservation(RateLimitReservationInput::acquire(
            RateLimitCounterWindow::unlimited(),
            RateLimitCounterWindow::limited(i64::MAX, 0),
            RateLimitCounterWindow::unlimited(),
            required,
        ));

        assert_eq!(plan.status, RateLimitReservationStatus::Acquired);
        let tpm = reservation_dimension_for(&plan, RateLimitDimension::TokensPerMinute);
        assert_eq!(tpm.required, i64::MAX as u64);
        assert_eq!(tpm.used_after, i64::MAX as u64);
    }

    #[test]
    fn tpm_estimate_negative_partial_data_keeps_conservative_reservation() {
        let partial = estimate_tpm_reservation(RateLimitTpmEstimateInput::new(
            Some(100),
            Some(-5),
            Some(-10),
            Some(-15),
            300,
        ));

        assert_eq!(partial.required_tokens, 400);
        assert_eq!(
            partial.source,
            RateLimitTpmEstimateSource::PartialEstimateWithConservativeFallback
        );
        assert_eq!(partial.prompt_tokens, Some(100));
        assert_eq!(partial.completion_tokens, None);
        assert_eq!(partial.max_completion_tokens, None);
        assert!(partial.used_conservative_fallback);
        assert!(partial.sanitized_negative_estimate);

        let fallback = estimate_tpm_reservation(RateLimitTpmEstimateInput::new(
            Some(-100),
            Some(-50),
            Some(-25),
            Some(-10),
            0,
        ));

        assert_eq!(
            fallback.required_tokens,
            RATE_LIMIT_DEFAULT_TPM_FALLBACK_TOKENS as u64
        );
        assert_eq!(
            fallback.source,
            RateLimitTpmEstimateSource::ConservativeFallback
        );
        assert_eq!(
            fallback.fallback_tokens,
            RATE_LIMIT_DEFAULT_TPM_FALLBACK_TOKENS as u64
        );
        assert!(fallback.used_conservative_fallback);
        assert!(fallback.sanitized_negative_estimate);
    }

    #[test]
    fn tpm_estimate_to_required_capacity_bridge_preserves_source_semantics() {
        let cases = [
            (
                "total_tokens_to_capacity",
                RateLimitTpmEstimateInput::new(Some(300), Some(128), Some(512), Some(700), 1_024),
                RateLimitTpmEstimateSource::TotalTokens,
                700,
                false,
            ),
            (
                "prompt_and_completion_to_capacity",
                RateLimitTpmEstimateInput::new(Some(220), Some(180), None, None, 1_024),
                RateLimitTpmEstimateSource::PromptAndCompletion,
                400,
                false,
            ),
            (
                "prompt_and_max_completion_to_capacity",
                RateLimitTpmEstimateInput::new(Some(220), Some(180), Some(512), None, 1_024),
                RateLimitTpmEstimateSource::PromptAndMaxCompletion,
                732,
                false,
            ),
            (
                "conservative_fallback_to_capacity",
                RateLimitTpmEstimateInput::new(None, None, None, None, 256),
                RateLimitTpmEstimateSource::ConservativeFallback,
                256,
                true,
            ),
            (
                "partial_estimate_with_fallback_to_capacity",
                RateLimitTpmEstimateInput::new(Some(120), None, None, None, 256),
                RateLimitTpmEstimateSource::PartialEstimateWithConservativeFallback,
                376,
                true,
            ),
        ];

        for (name, input, expected_source, expected_tokens, expected_fallback) in cases {
            let estimate = estimate_tpm_reservation(input);
            let required = RateLimitRequiredCapacity::from_tpm_estimate(1, &estimate, 1);
            let plan = plan_rate_limit_reservation(RateLimitReservationInput::acquire(
                RateLimitCounterWindow::unlimited(),
                RateLimitCounterWindow::limited(10_000, 100),
                RateLimitCounterWindow::unlimited(),
                required,
            ));
            let tpm = reservation_dimension_for(&plan, RateLimitDimension::TokensPerMinute);

            assert_eq!(estimate.source, expected_source, "{name}");
            assert_eq!(estimate.required_tokens, expected_tokens, "{name}");
            assert_eq!(
                estimate.used_conservative_fallback, expected_fallback,
                "{name}"
            );
            assert_eq!(required.tokens_per_minute, expected_tokens as i64, "{name}");
            assert_eq!(tpm.required, expected_tokens, "{name}");
            assert_eq!(tpm.used_after, 100 + expected_tokens, "{name}");
            assert_eq!(plan.status, RateLimitReservationStatus::Acquired, "{name}");
        }
    }

    #[test]
    fn tpm_estimate_to_required_capacity_bridge_clamps_i64_before_reservation() {
        let estimate = estimate_tpm_reservation(RateLimitTpmEstimateInput::new(
            Some(i64::MAX),
            Some(i64::MAX),
            Some(i64::MAX),
            None,
            i64::MAX,
        ));
        let required = RateLimitRequiredCapacity::from_tpm_estimate(1, &estimate, 1);
        let plan = plan_rate_limit_reservation(RateLimitReservationInput::acquire(
            RateLimitCounterWindow::unlimited(),
            RateLimitCounterWindow::limited(i64::MAX, 0),
            RateLimitCounterWindow::unlimited(),
            required,
        ));
        let tpm = reservation_dimension_for(&plan, RateLimitDimension::TokensPerMinute);

        assert!(estimate.clamped_to_i64_max);
        assert!(estimate.required_tokens > i64::MAX as u64);
        assert_eq!(estimate.required_tokens_i64(), i64::MAX);
        assert_eq!(required.tokens_per_minute, i64::MAX);
        assert_eq!(tpm.required, i64::MAX as u64);
        assert_eq!(tpm.used_after, i64::MAX as u64);
        assert_eq!(plan.status, RateLimitReservationStatus::Acquired);
    }

    #[test]
    fn tpm_estimate_bridge_serialized_outputs_are_secret_safe() {
        let estimate =
            estimate_tpm_reservation(RateLimitTpmEstimateInput::new(None, None, None, None, 256));
        let required = RateLimitRequiredCapacity::from_tpm_estimate(1, &estimate, 1);
        let plan = plan_rate_limit_reservation(RateLimitReservationInput::acquire(
            RateLimitCounterWindow::unlimited(),
            RateLimitCounterWindow::limited(1_000, 900),
            RateLimitCounterWindow::unlimited(),
            required,
        ));
        let serialized = serde_json::json!({
            "estimate": estimate,
            "required_capacity": required,
            "reservation_plan": plan,
        })
        .to_string()
        .to_ascii_lowercase();

        for forbidden in [
            "sk-live",
            "authorization",
            "bearer",
            "provider_key",
            "api_key",
            "encrypted_secret",
            "payload",
            "request_body",
            "raw_prompt",
            "raw_completion",
            "raw_window",
            "current_window_state",
        ] {
            assert!(
                !serialized.contains(forbidden),
                "rate-limit TPM bridge output leaked forbidden marker: {forbidden}"
            );
        }
    }

    #[test]
    fn tpm_estimate_feeds_reservation_selection_conservatively() {
        let precise = estimate_tpm_reservation(RateLimitTpmEstimateInput::new(
            Some(40),
            Some(50),
            None,
            None,
            256,
        ));
        let precise_plan = plan_rate_limit_reservation(RateLimitReservationInput::acquire(
            RateLimitCounterWindow::unlimited(),
            RateLimitCounterWindow::limited(1_000, 900),
            RateLimitCounterWindow::unlimited(),
            RateLimitRequiredCapacity::from_tpm_estimate(1, &precise, 1),
        ));

        assert_eq!(precise.required_tokens, 90);
        assert_eq!(precise_plan.status, RateLimitReservationStatus::Acquired);
        let precise_tpm =
            reservation_dimension_for(&precise_plan, RateLimitDimension::TokensPerMinute);
        assert_eq!(precise_tpm.required, 90);
        assert_eq!(precise_tpm.used_after, 990);

        let fallback =
            estimate_tpm_reservation(RateLimitTpmEstimateInput::new(None, None, None, None, 256));
        let fallback_plan = plan_rate_limit_reservation(RateLimitReservationInput::acquire(
            RateLimitCounterWindow::unlimited(),
            RateLimitCounterWindow::limited(1_000, 900),
            RateLimitCounterWindow::unlimited(),
            RateLimitRequiredCapacity::from_tpm_estimate(1, &fallback, 1),
        ));

        assert_eq!(fallback.required_tokens, 256);
        assert_eq!(fallback_plan.status, RateLimitReservationStatus::Rejected);
        assert_eq!(
            fallback_plan.blocking_dimensions,
            [RateLimitDimension::TokensPerMinute]
        );
        assert_eq!(fallback_plan.counter_updates_planned, 0);
    }

    #[test]
    fn tpm_estimate_contract_fixture_is_stable_and_secret_safe() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../tests/fixtures/routing/rate_limit_tpm_estimate_contract.json"
        ))
        .expect("rate-limit TPM estimate contract fixture should be valid json");
        let fallback =
            estimate_tpm_reservation(RateLimitTpmEstimateInput::new(None, None, None, None, 256));

        assert_eq!(fixture["scenario"], "rate_limit_tpm_estimate_contract");
        assert_eq!(fixture["schema"], RATE_LIMIT_TPM_ESTIMATE_CONTRACT_SCHEMA);
        assert_eq!(
            fallback.required_tokens,
            fixture["stable_behaviors"][3]["required_tokens"]
                .as_u64()
                .expect("fallback required tokens should be numeric")
        );
        assert_eq!(
            fallback.source,
            RateLimitTpmEstimateSource::ConservativeFallback
        );
        let edge_behaviors = fixture["edge_behaviors"]
            .as_array()
            .expect("edge behavior array should exist");
        assert!(edge_behaviors.iter().any(|behavior| {
            behavior["name"] == "zero_total_tokens_minimum_clamp"
                && behavior["required_tokens"] == RATE_LIMIT_MIN_TPM_RESERVATION_TOKENS
        }));
        assert!(edge_behaviors.iter().any(|behavior| {
            behavior["name"] == "negative_partial_estimate_adds_fallback"
                && behavior["required_tokens"] == 400
                && behavior["sanitized_negative_estimate"] == true
        }));
        assert!(edge_behaviors.iter().any(|behavior| {
            behavior["name"] == "i64_capacity_clamp"
                && behavior["required_tokens_i64"] == i64::MAX
                && behavior["clamped_to_i64_max"] == true
        }));
        let bridge_behaviors = fixture["capacity_bridge_behaviors"]
            .as_array()
            .expect("capacity bridge behavior array should exist");
        assert!(bridge_behaviors.iter().any(|behavior| {
            behavior["name"] == "conservative_fallback_to_required_capacity"
                && behavior["estimate_source"] == "ConservativeFallback"
                && behavior["used_conservative_fallback"] == true
                && behavior["required_capacity"]["tokens_per_minute"] == 256
                && behavior["reservation_dimension"]["required"] == 256
        }));
        assert!(bridge_behaviors.iter().any(|behavior| {
            behavior["name"] == "i64_clamped_estimate_to_required_capacity"
                && behavior["estimate_clamped_to_i64_max"] == true
                && behavior["required_capacity"]["tokens_per_minute"] == i64::MAX
                && behavior["reservation_dimension"]["required"] == i64::MAX
        }));

        let serialized = serde_json::to_string(&fallback)
            .expect("rate-limit TPM estimate should serialize")
            .to_ascii_lowercase();
        for forbidden in fixture["forbidden_output_markers"]
            .as_array()
            .expect("forbidden marker array")
            .iter()
            .filter_map(serde_json::Value::as_str)
        {
            assert!(
                !serialized.contains(forbidden),
                "rate-limit TPM estimate leaked forbidden marker: {forbidden}"
            );
        }
    }

    #[test]
    fn availability_can_be_applied_to_route_candidate_selection() {
        let candidate = RouteCandidate::new("rate-limited", "provider", "model", 10, 100);
        let availability = evaluate_rate_limit_availability(RateLimitAvailabilityInput::new(
            RateLimitWindow::limited(60, 60, 1),
            RateLimitWindow::unlimited(),
            RateLimitWindow::unlimited(),
        ));

        let candidate = apply_rate_limit_availability_to_candidate(candidate, &availability);

        assert!(!candidate.rate_limit_available);
    }

    #[test]
    fn reservation_acquire_under_limits_plans_counter_increments() {
        let plan = plan_rate_limit_reservation(RateLimitReservationInput::acquire(
            RateLimitCounterWindow::limited(60, 58),
            RateLimitCounterWindow::limited(1_000, 800),
            RateLimitCounterWindow::limited(4, 3),
            RateLimitRequiredCapacity::new(1, 100, 1),
        ));

        assert_eq!(plan.status, RateLimitReservationStatus::Acquired);
        assert_eq!(plan.filter_reason, None);
        assert!(plan.blocking_dimensions.is_empty());
        assert_eq!(plan.counter_updates_planned, 3);
        assert!(!plan.window_material_in_output);

        let rpm = reservation_dimension_for(&plan, RateLimitDimension::RequestsPerMinute);
        assert_eq!(rpm.counter_update, RateLimitCounterUpdate::Increment);
        assert_eq!(rpm.used_before, 58);
        assert_eq!(rpm.required, 1);
        assert_eq!(rpm.used_after, 59);
        assert_eq!(rpm.remaining_after, Some(1));

        let tpm = reservation_dimension_for(&plan, RateLimitDimension::TokensPerMinute);
        assert_eq!(tpm.used_after, 900);
        assert_eq!(tpm.remaining_after, Some(100));

        let concurrency = reservation_dimension_for(&plan, RateLimitDimension::Concurrency);
        assert_eq!(concurrency.used_after, 4);
        assert_eq!(concurrency.remaining_after, Some(0));
    }

    #[test]
    fn reservation_acquire_over_limit_rejects_without_counter_updates() {
        let plan = plan_rate_limit_reservation(RateLimitReservationInput::acquire(
            RateLimitCounterWindow::limited(60, 60),
            RateLimitCounterWindow::limited(1_000, 950),
            RateLimitCounterWindow::limited(4, 4),
            RateLimitRequiredCapacity::new(1, 100, 1),
        ));

        assert_eq!(plan.status, RateLimitReservationStatus::Rejected);
        assert_eq!(
            plan.filter_reason,
            Some(CandidateFilterReason::RateLimitExceeded)
        );
        assert_eq!(
            plan.blocking_dimensions,
            [
                RateLimitDimension::RequestsPerMinute,
                RateLimitDimension::TokensPerMinute,
                RateLimitDimension::Concurrency
            ]
        );
        assert_eq!(plan.counter_updates_planned, 0);

        for dimension in [
            RateLimitDimension::RequestsPerMinute,
            RateLimitDimension::TokensPerMinute,
            RateLimitDimension::Concurrency,
        ] {
            let summary = reservation_dimension_for(&plan, dimension);
            assert_eq!(summary.counter_update, RateLimitCounterUpdate::None);
            assert_eq!(summary.used_before, summary.used_after);
        }
    }

    #[test]
    fn reservation_acquire_missing_limited_windows_rejects_conservatively() {
        let plan = plan_rate_limit_reservation(RateLimitReservationInput::acquire(
            RateLimitCounterWindow::missing(60),
            RateLimitCounterWindow::unlimited(),
            RateLimitCounterWindow::missing(4),
            RateLimitRequiredCapacity::new(1, 100, 1),
        ));

        assert_eq!(plan.status, RateLimitReservationStatus::Rejected);
        assert!(plan.conservative_reject);
        assert_eq!(
            plan.blocking_dimensions,
            [
                RateLimitDimension::RequestsPerMinute,
                RateLimitDimension::Concurrency
            ]
        );
        assert_eq!(plan.counter_updates_planned, 0);

        let rpm = reservation_dimension_for(&plan, RateLimitDimension::RequestsPerMinute);
        assert_eq!(rpm.status, RateLimitDimensionStatus::WindowMissing);
        assert!(!rpm.window_present);
        assert_eq!(rpm.used_after, 0);
    }

    #[test]
    fn reservation_acquire_negative_and_invalid_counters_are_stable() {
        let plan = plan_rate_limit_reservation(RateLimitReservationInput::acquire(
            RateLimitCounterWindow::limited(10, -3),
            RateLimitCounterWindow::limited(-1, 0),
            RateLimitCounterWindow::limited(10, 0),
            RateLimitRequiredCapacity::new(1, 1, -1),
        ));

        assert_eq!(plan.status, RateLimitReservationStatus::Rejected);
        assert_eq!(
            plan.blocking_dimensions,
            [
                RateLimitDimension::TokensPerMinute,
                RateLimitDimension::Concurrency
            ]
        );
        assert_eq!(plan.counter_updates_planned, 0);

        let rpm = reservation_dimension_for(&plan, RateLimitDimension::RequestsPerMinute);
        assert_eq!(rpm.status, RateLimitDimensionStatus::Available);
        assert_eq!(rpm.used_before, 0);
        assert_eq!(rpm.used_after, 0);
        assert!(rpm.sanitized_negative_used);

        let tpm = reservation_dimension_for(&plan, RateLimitDimension::TokensPerMinute);
        assert_eq!(tpm.status, RateLimitDimensionStatus::InvalidLimit);
        assert_eq!(tpm.limit, None);

        let concurrency = reservation_dimension_for(&plan, RateLimitDimension::Concurrency);
        assert_eq!(
            concurrency.status,
            RateLimitDimensionStatus::InvalidRequired
        );
    }

    #[test]
    fn reservation_release_decrements_counters_saturating_at_zero() {
        let plan = plan_rate_limit_reservation(RateLimitReservationInput::release(
            RateLimitCounterWindow::limited(60, 59),
            RateLimitCounterWindow::limited(1_000, 50),
            RateLimitCounterWindow::limited(4, 1),
            RateLimitRequiredCapacity::new(1, 100, 1),
            true,
        ));

        assert_eq!(plan.status, RateLimitReservationStatus::Released);
        assert_eq!(plan.filter_reason, None);
        assert!(plan.blocking_dimensions.is_empty());
        assert_eq!(plan.counter_updates_planned, 3);

        let rpm = reservation_dimension_for(&plan, RateLimitDimension::RequestsPerMinute);
        assert_eq!(rpm.counter_update, RateLimitCounterUpdate::Decrement);
        assert_eq!(rpm.used_after, 58);
        assert!(!rpm.saturated_release);

        let tpm = reservation_dimension_for(&plan, RateLimitDimension::TokensPerMinute);
        assert_eq!(tpm.counter_update, RateLimitCounterUpdate::Decrement);
        assert_eq!(tpm.used_after, 0);
        assert!(tpm.saturated_release);

        let concurrency = reservation_dimension_for(&plan, RateLimitDimension::Concurrency);
        assert_eq!(concurrency.used_after, 0);
    }

    #[test]
    fn reservation_release_without_acquired_marker_is_idempotent_noop() {
        let plan = plan_rate_limit_reservation(RateLimitReservationInput::release(
            RateLimitCounterWindow::limited(60, 59),
            RateLimitCounterWindow::limited(1_000, 900),
            RateLimitCounterWindow::limited(4, 1),
            RateLimitRequiredCapacity::new(1, 100, 1),
            false,
        ));

        assert_eq!(plan.status, RateLimitReservationStatus::ReleaseNoop);
        assert_eq!(plan.filter_reason, None);
        assert!(plan.blocking_dimensions.is_empty());
        assert_eq!(plan.counter_updates_planned, 0);

        for dimension in [
            RateLimitDimension::RequestsPerMinute,
            RateLimitDimension::TokensPerMinute,
            RateLimitDimension::Concurrency,
        ] {
            let summary = reservation_dimension_for(&plan, dimension);
            assert_eq!(summary.counter_update, RateLimitCounterUpdate::None);
            assert_eq!(summary.used_before, summary.used_after);
        }

        let invalid_required = plan_rate_limit_reservation(RateLimitReservationInput::release(
            RateLimitCounterWindow::limited(60, 59),
            RateLimitCounterWindow::limited(1_000, 900),
            RateLimitCounterWindow::limited(4, 1),
            RateLimitRequiredCapacity::new(1, 100, -1),
            false,
        ));
        assert_eq!(
            invalid_required.status,
            RateLimitReservationStatus::ReleaseNoop
        );
        assert_eq!(invalid_required.counter_updates_planned, 0);
    }

    #[test]
    fn reservation_contract_fixture_is_stable_and_secret_safe() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../tests/fixtures/routing/rate_limit_reservation_contract.json"
        ))
        .expect("rate-limit reservation contract fixture should be valid json");
        let plan = plan_rate_limit_reservation(RateLimitReservationInput::acquire(
            RateLimitCounterWindow::limited(60, 58),
            RateLimitCounterWindow::limited(1_000, 800),
            RateLimitCounterWindow::limited(4, 3),
            RateLimitRequiredCapacity::new(1, 100, 1),
        ));

        assert_eq!(fixture["scenario"], "rate_limit_reservation_contract");
        assert_eq!(fixture["schema"], RATE_LIMIT_RESERVATION_CONTRACT_SCHEMA);
        assert_eq!(
            plan.status,
            RateLimitReservationStatus::Acquired,
            "fixture acquire_under_limits status should match the implementation"
        );
        assert_eq!(
            plan.counter_updates_planned,
            fixture["stable_behaviors"][0]["counter_updates_planned"]
                .as_u64()
                .expect("counter update count") as usize
        );

        let serialized = serde_json::to_string(&plan)
            .expect("rate-limit reservation plan should serialize")
            .to_ascii_lowercase();
        for forbidden in fixture["forbidden_output_markers"]
            .as_array()
            .expect("forbidden marker array")
            .iter()
            .filter_map(serde_json::Value::as_str)
        {
            assert!(
                !serialized.contains(forbidden),
                "rate-limit reservation plan leaked forbidden marker: {forbidden}"
            );
        }
    }
}
