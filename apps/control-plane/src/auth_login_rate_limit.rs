use std::{collections::HashMap, fmt, sync::Mutex};

use ai_gateway_auth::{
    LoginFailureRateLimitDecision, LoginFailureRateLimitPolicy, LoginFailureRateLimitState,
    evaluate_login_failure_rate_limit, login_rate_limit_fingerprint, record_login_failure,
};
use uuid::Uuid;

const LOGIN_IDENTIFIER_MAX_CHARS: usize = 256;

#[derive(Clone, PartialEq, Eq, Hash)]
pub(crate) struct AdminLoginFailureRateLimitKey {
    tenant_id: Uuid,
    login_identifier_fingerprint: String,
}

impl fmt::Debug for AdminLoginFailureRateLimitKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AdminLoginFailureRateLimitKey")
            .field("tenant_id", &self.tenant_id)
            .field(
                "login_identifier_fingerprint",
                &self.login_identifier_fingerprint,
            )
            .finish()
    }
}

pub(crate) trait LoginFailureRateLimitStore: fmt::Debug + Send + Sync {
    fn check(
        &self,
        key: &AdminLoginFailureRateLimitKey,
        now_epoch_seconds: u64,
        policy: LoginFailureRateLimitPolicy,
    ) -> LoginFailureRateLimitDecision;

    fn record_failure(
        &self,
        key: &AdminLoginFailureRateLimitKey,
        now_epoch_seconds: u64,
        policy: LoginFailureRateLimitPolicy,
    ) -> LoginFailureRateLimitDecision;

    fn clear(&self, key: &AdminLoginFailureRateLimitKey);
}

#[derive(Debug, Default)]
pub(crate) struct InMemoryLoginFailureRateLimitStore {
    failures: Mutex<HashMap<AdminLoginFailureRateLimitKey, LoginFailureRateLimitState>>,
}

impl LoginFailureRateLimitStore for InMemoryLoginFailureRateLimitStore {
    fn check(
        &self,
        key: &AdminLoginFailureRateLimitKey,
        now_epoch_seconds: u64,
        policy: LoginFailureRateLimitPolicy,
    ) -> LoginFailureRateLimitDecision {
        let mut failures = self
            .failures
            .lock()
            .expect("login failure rate-limit store lock should not be poisoned");
        let decision = evaluate_login_failure_rate_limit(
            failures.get(key).copied(),
            now_epoch_seconds,
            policy,
        );
        if decision.failure_count == 0 {
            failures.remove(key);
        }
        decision
    }

    fn record_failure(
        &self,
        key: &AdminLoginFailureRateLimitKey,
        now_epoch_seconds: u64,
        policy: LoginFailureRateLimitPolicy,
    ) -> LoginFailureRateLimitDecision {
        let mut failures = self
            .failures
            .lock()
            .expect("login failure rate-limit store lock should not be poisoned");
        let state = record_login_failure(failures.get(key).copied(), now_epoch_seconds, policy);
        failures.insert(key.clone(), state);
        evaluate_login_failure_rate_limit(Some(state), now_epoch_seconds, policy)
    }

    fn clear(&self, key: &AdminLoginFailureRateLimitKey) {
        self.failures
            .lock()
            .expect("login failure rate-limit store lock should not be poisoned")
            .remove(key);
    }
}

pub(crate) fn admin_login_failure_rate_limit_key(
    tenant_id: Uuid,
    username: &str,
) -> AdminLoginFailureRateLimitKey {
    let normalized_username = normalize_login_identifier(username);

    AdminLoginFailureRateLimitKey {
        tenant_id,
        login_identifier_fingerprint: login_rate_limit_fingerprint(&[normalized_username.as_str()]),
    }
}

fn normalize_login_identifier(username: &str) -> String {
    let normalized = username
        .trim()
        .chars()
        .take(LOGIN_IDENTIFIER_MAX_CHARS)
        .collect::<String>()
        .to_ascii_lowercase();
    if normalized.is_empty() {
        "<empty>".to_string()
    } else {
        normalized
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(tenant_id: Uuid, username: &str) -> AdminLoginFailureRateLimitKey {
        admin_login_failure_rate_limit_key(tenant_id, username)
    }

    #[test]
    fn consecutive_failures_trigger_rate_limit() {
        let store = InMemoryLoginFailureRateLimitStore::default();
        let policy = LoginFailureRateLimitPolicy::new(2, 60);
        let key = key(Uuid::nil(), "admin@example.com");

        assert!(!store.check(&key, 100, policy).is_limited);
        assert!(!store.record_failure(&key, 100, policy).is_limited);
        assert!(store.record_failure(&key, 101, policy).is_limited);

        let decision = store.check(&key, 102, policy);
        assert!(decision.is_limited);
        assert_eq!(decision.retry_after_seconds, Some(58));
    }

    #[test]
    fn success_clear_removes_previous_failures() {
        let store = InMemoryLoginFailureRateLimitStore::default();
        let policy = LoginFailureRateLimitPolicy::new(2, 60);
        let key = key(Uuid::nil(), "admin@example.com");

        store.record_failure(&key, 100, policy);
        store.clear(&key);

        assert!(!store.check(&key, 101, policy).is_limited);
        assert!(!store.record_failure(&key, 101, policy).is_limited);
    }

    #[test]
    fn same_tenant_and_normalized_username_share_failure_counts() {
        let store = InMemoryLoginFailureRateLimitStore::default();
        let policy = LoginFailureRateLimitPolicy::new(2, 60);
        let admin = key(Uuid::nil(), " Admin@Example.com ");
        let same_admin = key(Uuid::nil(), "admin@example.com");

        store.record_failure(&admin, 100, policy);
        store.record_failure(&same_admin, 101, policy);

        assert!(store.check(&admin, 102, policy).is_limited);
    }

    #[test]
    fn different_users_and_tenants_do_not_share_failure_counts() {
        let store = InMemoryLoginFailureRateLimitStore::default();
        let policy = LoginFailureRateLimitPolicy::new(2, 60);
        let tenant_a = Uuid::from_u128(1);
        let tenant_b = Uuid::from_u128(2);
        let admin_tenant_a = key(tenant_a, "admin@example.com");
        let operator_tenant_a = key(tenant_a, "operator@example.com");
        let admin_tenant_b = key(tenant_b, "admin@example.com");

        store.record_failure(&admin_tenant_a, 100, policy);
        store.record_failure(&admin_tenant_a, 101, policy);

        assert!(store.check(&admin_tenant_a, 102, policy).is_limited);
        assert!(!store.check(&operator_tenant_a, 102, policy).is_limited);
        assert!(!store.check(&admin_tenant_b, 102, policy).is_limited);
    }

    #[test]
    fn key_debug_output_excludes_raw_username() {
        let key = key(Uuid::nil(), "Admin@Example.com");
        let debug = format!("{key:?}");

        assert!(!debug.contains("Admin@Example.com"));
        assert!(!debug.contains("admin@example.com"));
        assert!(debug.contains("login_identifier_fingerprint"));
    }
}
