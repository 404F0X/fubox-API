use sha2::{Digest, Sha256};

pub const DEFAULT_LOGIN_FAILURE_LIMIT: u32 = 5;
pub const DEFAULT_LOGIN_FAILURE_WINDOW_SECONDS: u64 = 300;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LoginFailureRateLimitPolicy {
    pub max_failures: u32,
    pub window_seconds: u64,
}

impl LoginFailureRateLimitPolicy {
    pub const fn new(max_failures: u32, window_seconds: u64) -> Self {
        Self {
            max_failures,
            window_seconds,
        }
    }

    pub fn sanitized(self) -> Self {
        Self {
            max_failures: self.max_failures.max(1),
            window_seconds: self.window_seconds.max(1),
        }
    }
}

impl Default for LoginFailureRateLimitPolicy {
    fn default() -> Self {
        Self {
            max_failures: DEFAULT_LOGIN_FAILURE_LIMIT,
            window_seconds: DEFAULT_LOGIN_FAILURE_WINDOW_SECONDS,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LoginFailureRateLimitState {
    pub failure_count: u32,
    pub window_started_at_epoch_seconds: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LoginFailureRateLimitDecision {
    pub is_limited: bool,
    pub retry_after_seconds: Option<u64>,
    pub failure_count: u32,
}

pub fn evaluate_login_failure_rate_limit(
    state: Option<LoginFailureRateLimitState>,
    now_epoch_seconds: u64,
    policy: LoginFailureRateLimitPolicy,
) -> LoginFailureRateLimitDecision {
    let policy = policy.sanitized();
    let Some(state) = active_login_failure_state(state, now_epoch_seconds, policy) else {
        return LoginFailureRateLimitDecision {
            is_limited: false,
            retry_after_seconds: None,
            failure_count: 0,
        };
    };

    if state.failure_count >= policy.max_failures {
        return LoginFailureRateLimitDecision {
            is_limited: true,
            retry_after_seconds: Some(
                state
                    .window_started_at_epoch_seconds
                    .saturating_add(policy.window_seconds)
                    .saturating_sub(now_epoch_seconds)
                    .max(1),
            ),
            failure_count: state.failure_count,
        };
    }

    LoginFailureRateLimitDecision {
        is_limited: false,
        retry_after_seconds: None,
        failure_count: state.failure_count,
    }
}

pub fn record_login_failure(
    state: Option<LoginFailureRateLimitState>,
    now_epoch_seconds: u64,
    policy: LoginFailureRateLimitPolicy,
) -> LoginFailureRateLimitState {
    let policy = policy.sanitized();
    match active_login_failure_state(state, now_epoch_seconds, policy) {
        Some(state) => LoginFailureRateLimitState {
            failure_count: state.failure_count.saturating_add(1),
            window_started_at_epoch_seconds: state.window_started_at_epoch_seconds,
        },
        None => LoginFailureRateLimitState {
            failure_count: 1,
            window_started_at_epoch_seconds: now_epoch_seconds,
        },
    }
}

pub fn login_rate_limit_fingerprint(parts: &[&str]) -> String {
    let mut hasher = Sha256::new();
    for part in parts {
        hasher.update((part.len() as u64).to_be_bytes());
        hasher.update(part.as_bytes());
    }
    hex::encode(hasher.finalize())
}

fn active_login_failure_state(
    state: Option<LoginFailureRateLimitState>,
    now_epoch_seconds: u64,
    policy: LoginFailureRateLimitPolicy,
) -> Option<LoginFailureRateLimitState> {
    let state = state?;
    if now_epoch_seconds.saturating_sub(state.window_started_at_epoch_seconds)
        >= policy.window_seconds
    {
        None
    } else {
        Some(state)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repeated_login_failures_limit_after_threshold_until_window_expires() {
        let policy = LoginFailureRateLimitPolicy::new(2, 60);
        let mut state = None;

        assert!(!evaluate_login_failure_rate_limit(state, 100, policy).is_limited);

        state = Some(record_login_failure(state, 100, policy));
        assert_eq!(
            evaluate_login_failure_rate_limit(state, 100, policy),
            LoginFailureRateLimitDecision {
                is_limited: false,
                retry_after_seconds: None,
                failure_count: 1,
            }
        );

        state = Some(record_login_failure(state, 101, policy));
        assert_eq!(
            evaluate_login_failure_rate_limit(state, 101, policy),
            LoginFailureRateLimitDecision {
                is_limited: true,
                retry_after_seconds: Some(59),
                failure_count: 2,
            }
        );

        assert!(!evaluate_login_failure_rate_limit(state, 160, policy).is_limited);
    }

    #[test]
    fn expired_failure_window_starts_a_new_count() {
        let policy = LoginFailureRateLimitPolicy::new(3, 10);
        let state = Some(LoginFailureRateLimitState {
            failure_count: 3,
            window_started_at_epoch_seconds: 10,
        });

        let next = record_login_failure(state, 20, policy);

        assert_eq!(
            next,
            LoginFailureRateLimitState {
                failure_count: 1,
                window_started_at_epoch_seconds: 20,
            }
        );
    }

    #[test]
    fn fingerprints_are_deterministic_and_length_delimited() {
        let left = login_rate_limit_fingerprint(&["ab", "c"]);
        let right = login_rate_limit_fingerprint(&["ab", "c"]);
        let ambiguous = login_rate_limit_fingerprint(&["a", "bc"]);

        assert_eq!(left, right);
        assert_ne!(left, ambiguous);
        assert_eq!(left.len(), 64);
    }
}
