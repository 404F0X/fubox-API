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
}
