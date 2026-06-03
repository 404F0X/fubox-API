use std::{
    collections::HashMap,
    fmt,
    io::{BufRead, BufReader, Write},
    net::{TcpStream, ToSocketAddrs},
    sync::{Arc, Mutex},
    time::Duration,
};

use ai_gateway_auth::{
    LoginFailureRateLimitDecision, LoginFailureRateLimitPolicy, LoginFailureRateLimitState,
    evaluate_login_failure_rate_limit, login_rate_limit_fingerprint, record_login_failure,
};
use uuid::Uuid;

const LOGIN_IDENTIFIER_MAX_CHARS: usize = 256;
const STORE_BACKEND_ENV: &str = "AI_GATEWAY_ADMIN_LOGIN_RATE_LIMIT_STORE";
const REDIS_TIMEOUT_MS_ENV: &str = "AI_GATEWAY_ADMIN_LOGIN_RATE_LIMIT_REDIS_TIMEOUT_MS";
const REDIS_KEY_PREFIX_ENV: &str = "AI_GATEWAY_ADMIN_LOGIN_RATE_LIMIT_REDIS_KEY_PREFIX";
const DEFAULT_REDIS_TIMEOUT_MS: u64 = 200;
const DEFAULT_REDIS_KEY_PREFIX: &str = "ai-gateway:control-plane:admin-login-failures";
const REDIS_CHECK_SCRIPT: &str = r#"
local raw = redis.call("GET", KEYS[1])
local now = tonumber(ARGV[1])
local max_failures = tonumber(ARGV[2])
local window_seconds = tonumber(ARGV[3])
if not raw then
  return {0, 0, 0}
end
local separator = string.find(raw, ":")
if not separator then
  redis.call("DEL", KEYS[1])
  return {0, 0, 0}
end
local failure_count = tonumber(string.sub(raw, 1, separator - 1))
local window_started_at = tonumber(string.sub(raw, separator + 1))
if not failure_count or not window_started_at then
  redis.call("DEL", KEYS[1])
  return {0, 0, 0}
end
if now - window_started_at >= window_seconds then
  redis.call("DEL", KEYS[1])
  return {0, 0, 0}
end
if failure_count >= max_failures then
  local retry_after = math.max((window_started_at + window_seconds) - now, 1)
  return {1, failure_count, retry_after}
end
return {0, failure_count, 0}
"#;
const REDIS_RECORD_FAILURE_SCRIPT: &str = r#"
local raw = redis.call("GET", KEYS[1])
local now = tonumber(ARGV[1])
local max_failures = tonumber(ARGV[2])
local window_seconds = tonumber(ARGV[3])
local failure_count = 1
local window_started_at = now
if raw then
  local separator = string.find(raw, ":")
  if separator then
    local stored_count = tonumber(string.sub(raw, 1, separator - 1))
    local stored_started_at = tonumber(string.sub(raw, separator + 1))
    if stored_count and stored_started_at and now - stored_started_at < window_seconds then
      failure_count = stored_count + 1
      window_started_at = stored_started_at
    end
  end
end
redis.call("SET", KEYS[1], tostring(failure_count) .. ":" .. tostring(window_started_at), "EX", window_seconds)
if failure_count >= max_failures then
  local retry_after = math.max((window_started_at + window_seconds) - now, 1)
  return {1, failure_count, retry_after}
end
return {0, failure_count, 0}
"#;

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

impl AdminLoginFailureRateLimitKey {
    fn redis_key(&self, prefix: &str) -> String {
        format!(
            "{}:tenant:{}:login:{}",
            sanitized_redis_key_prefix(prefix),
            self.tenant_id,
            self.login_identifier_fingerprint
        )
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

pub(crate) fn login_failure_rate_limit_store_from_env(
    redis_addr: &str,
    redis_db: u32,
) -> Arc<dyn LoginFailureRateLimitStore> {
    match std::env::var(STORE_BACKEND_ENV)
        .unwrap_or_else(|_| "memory".to_string())
        .trim()
        .to_ascii_lowercase()
        .as_str()
    {
        "redis" | "distributed_redis" => Arc::new(RedisLoginFailureRateLimitStore::new(
            RedisLoginFailureRateLimitConfig::from_env(redis_addr, redis_db),
        )),
        _ => Arc::new(InMemoryLoginFailureRateLimitStore::default()),
    }
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

#[derive(Clone)]
pub(crate) struct RedisLoginFailureRateLimitConfig {
    addr: String,
    db: u32,
    key_prefix: String,
    timeout: Duration,
}

impl fmt::Debug for RedisLoginFailureRateLimitConfig {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RedisLoginFailureRateLimitConfig")
            .field("addr_configured", &(!self.addr.trim().is_empty()))
            .field("db", &self.db)
            .field("key_prefix_configured", &(!self.key_prefix.is_empty()))
            .field("timeout_ms", &self.timeout.as_millis())
            .field("unavailable_policy", &"fail_closed")
            .finish()
    }
}

impl RedisLoginFailureRateLimitConfig {
    fn from_env(redis_addr: &str, redis_db: u32) -> Self {
        let timeout_ms = std::env::var(REDIS_TIMEOUT_MS_ENV)
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .filter(|value| *value > 0)
            .unwrap_or(DEFAULT_REDIS_TIMEOUT_MS);
        let key_prefix = std::env::var(REDIS_KEY_PREFIX_ENV)
            .ok()
            .map(|value| sanitized_redis_key_prefix(&value))
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| DEFAULT_REDIS_KEY_PREFIX.to_string());

        Self {
            addr: redis_addr.to_string(),
            db: redis_db,
            key_prefix,
            timeout: Duration::from_millis(timeout_ms),
        }
    }
}

#[derive(Debug)]
pub(crate) struct RedisLoginFailureRateLimitStore {
    config: RedisLoginFailureRateLimitConfig,
}

impl RedisLoginFailureRateLimitStore {
    fn new(config: RedisLoginFailureRateLimitConfig) -> Self {
        Self { config }
    }

    fn check_inner(
        &self,
        key: &AdminLoginFailureRateLimitKey,
        now_epoch_seconds: u64,
        policy: LoginFailureRateLimitPolicy,
    ) -> Result<LoginFailureRateLimitDecision, RedisRateLimitError> {
        self.eval_decision_script(REDIS_CHECK_SCRIPT, key, now_epoch_seconds, policy)
    }

    fn record_failure_inner(
        &self,
        key: &AdminLoginFailureRateLimitKey,
        now_epoch_seconds: u64,
        policy: LoginFailureRateLimitPolicy,
    ) -> Result<LoginFailureRateLimitDecision, RedisRateLimitError> {
        self.eval_decision_script(REDIS_RECORD_FAILURE_SCRIPT, key, now_epoch_seconds, policy)
    }

    fn eval_decision_script(
        &self,
        script: &str,
        key: &AdminLoginFailureRateLimitKey,
        now_epoch_seconds: u64,
        policy: LoginFailureRateLimitPolicy,
    ) -> Result<LoginFailureRateLimitDecision, RedisRateLimitError> {
        let policy = policy.sanitized();
        let redis_key = key.redis_key(&self.config.key_prefix);
        let now = now_epoch_seconds.to_string();
        let max_failures = policy.max_failures.to_string();
        let window_seconds = policy.window_seconds.to_string();
        let response = self.redis_command(&[
            b"EVAL".as_slice(),
            script.as_bytes(),
            b"1".as_slice(),
            redis_key.as_bytes(),
            now.as_bytes(),
            max_failures.as_bytes(),
            window_seconds.as_bytes(),
        ])?;

        redis_decision_from_response(response)
    }

    fn redis_command(&self, parts: &[&[u8]]) -> Result<RedisResponse, RedisRateLimitError> {
        let addr = redis_socket_addr(&self.config.addr)?;
        let mut stream = TcpStream::connect_timeout(&addr, self.config.timeout)
            .map_err(|_| RedisRateLimitError::Unavailable)?;
        stream
            .set_read_timeout(Some(self.config.timeout))
            .map_err(|_| RedisRateLimitError::Unavailable)?;
        stream
            .set_write_timeout(Some(self.config.timeout))
            .map_err(|_| RedisRateLimitError::Unavailable)?;

        if self.config.db > 0 {
            let db = self.config.db.to_string();
            stream
                .write_all(&encode_redis_command(&[
                    b"SELECT".as_slice(),
                    db.as_bytes(),
                ]))
                .map_err(|_| RedisRateLimitError::Unavailable)?;
            let mut reader = BufReader::new(stream);
            match read_redis_response(&mut reader)? {
                RedisResponse::Simple(value) if value == "OK" => {
                    stream = reader.into_inner();
                }
                _ => return Err(RedisRateLimitError::Unavailable),
            }
        }

        stream
            .write_all(&encode_redis_command(parts))
            .map_err(|_| RedisRateLimitError::Unavailable)?;
        let mut reader = BufReader::new(stream);
        read_redis_response(&mut reader)
    }

    fn clear_inner(&self, key: &AdminLoginFailureRateLimitKey) -> Result<(), RedisRateLimitError> {
        let redis_key = key.redis_key(&self.config.key_prefix);
        let response = self.redis_command(&[b"DEL".as_slice(), redis_key.as_bytes()])?;
        match response {
            RedisResponse::Integer(_) => Ok(()),
            _ => Err(RedisRateLimitError::Unavailable),
        }
    }

    fn fail_closed_decision(policy: LoginFailureRateLimitPolicy) -> LoginFailureRateLimitDecision {
        let policy = policy.sanitized();
        LoginFailureRateLimitDecision {
            is_limited: true,
            retry_after_seconds: Some(policy.window_seconds.max(1)),
            failure_count: policy.max_failures.max(1),
        }
    }
}

impl LoginFailureRateLimitStore for RedisLoginFailureRateLimitStore {
    fn check(
        &self,
        key: &AdminLoginFailureRateLimitKey,
        now_epoch_seconds: u64,
        policy: LoginFailureRateLimitPolicy,
    ) -> LoginFailureRateLimitDecision {
        match self.check_inner(key, now_epoch_seconds, policy) {
            Ok(decision) => decision,
            Err(error) => {
                tracing::warn!(
                    error = error.as_str(),
                    "redis login failure rate-limit check failed; failing closed"
                );
                Self::fail_closed_decision(policy)
            }
        }
    }

    fn record_failure(
        &self,
        key: &AdminLoginFailureRateLimitKey,
        now_epoch_seconds: u64,
        policy: LoginFailureRateLimitPolicy,
    ) -> LoginFailureRateLimitDecision {
        match self.record_failure_inner(key, now_epoch_seconds, policy) {
            Ok(decision) => decision,
            Err(error) => {
                tracing::warn!(
                    error = error.as_str(),
                    "redis login failure rate-limit record failed; failing closed"
                );
                Self::fail_closed_decision(policy)
            }
        }
    }

    fn clear(&self, key: &AdminLoginFailureRateLimitKey) {
        if let Err(error) = self.clear_inner(key) {
            tracing::warn!(
                error = error.as_str(),
                "redis login failure rate-limit clear failed"
            );
        }
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

fn sanitized_redis_key_prefix(prefix: &str) -> String {
    let sanitized = prefix
        .trim()
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, ':' | '-' | '_' | '.') {
                character
            } else {
                '_'
            }
        })
        .take(160)
        .collect::<String>();
    if sanitized.is_empty() {
        DEFAULT_REDIS_KEY_PREFIX.to_string()
    } else {
        sanitized
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum RedisRateLimitError {
    Unavailable,
    InvalidResponse,
}

impl RedisRateLimitError {
    const fn as_str(&self) -> &'static str {
        match self {
            Self::Unavailable => "redis_unavailable",
            Self::InvalidResponse => "redis_invalid_response",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum RedisResponse {
    Simple(String),
    Error,
    Integer(i64),
    Bulk(Option<Vec<u8>>),
    Array(Vec<RedisResponse>),
}

fn redis_socket_addr(addr: &str) -> Result<std::net::SocketAddr, RedisRateLimitError> {
    redis_host_port(addr)
        .to_socket_addrs()
        .map_err(|_| RedisRateLimitError::Unavailable)?
        .next()
        .ok_or(RedisRateLimitError::Unavailable)
}

fn redis_host_port(addr: &str) -> String {
    let mut value = addr.trim();
    if let Some(stripped) = value.strip_prefix("redis://") {
        value = stripped;
    }
    if let Some((_, after_userinfo)) = value.rsplit_once('@') {
        value = after_userinfo;
    }
    if let Some((host_port, _path)) = value.split_once('/') {
        value = host_port;
    }
    if value.contains(':') {
        value.to_string()
    } else {
        format!("{value}:6379")
    }
}

fn encode_redis_command(parts: &[&[u8]]) -> Vec<u8> {
    let mut body = Vec::new();
    body.extend_from_slice(format!("*{}\r\n", parts.len()).as_bytes());
    for part in parts {
        body.extend_from_slice(format!("${}\r\n", part.len()).as_bytes());
        body.extend_from_slice(part);
        body.extend_from_slice(b"\r\n");
    }
    body
}

fn read_redis_response<R: BufRead>(reader: &mut R) -> Result<RedisResponse, RedisRateLimitError> {
    let mut prefix = [0_u8; 1];
    reader
        .read_exact(&mut prefix)
        .map_err(|_| RedisRateLimitError::Unavailable)?;
    match prefix[0] {
        b'+' => Ok(RedisResponse::Simple(read_redis_line(reader)?)),
        b'-' => {
            let _ = read_redis_line(reader)?;
            Ok(RedisResponse::Error)
        }
        b':' => read_redis_line(reader)?
            .parse::<i64>()
            .map(RedisResponse::Integer)
            .map_err(|_| RedisRateLimitError::InvalidResponse),
        b'$' => {
            let len = read_redis_line(reader)?
                .parse::<isize>()
                .map_err(|_| RedisRateLimitError::InvalidResponse)?;
            if len < 0 {
                return Ok(RedisResponse::Bulk(None));
            }
            let len = usize::try_from(len).map_err(|_| RedisRateLimitError::InvalidResponse)?;
            let mut body = vec![0_u8; len + 2];
            reader
                .read_exact(&mut body)
                .map_err(|_| RedisRateLimitError::Unavailable)?;
            if !body.ends_with(b"\r\n") {
                return Err(RedisRateLimitError::InvalidResponse);
            }
            body.truncate(len);
            Ok(RedisResponse::Bulk(Some(body)))
        }
        b'*' => {
            let len = read_redis_line(reader)?
                .parse::<isize>()
                .map_err(|_| RedisRateLimitError::InvalidResponse)?;
            if len < 0 {
                return Ok(RedisResponse::Array(Vec::new()));
            }
            let len = usize::try_from(len).map_err(|_| RedisRateLimitError::InvalidResponse)?;
            let mut items = Vec::with_capacity(len);
            for _ in 0..len {
                items.push(read_redis_response(reader)?);
            }
            Ok(RedisResponse::Array(items))
        }
        _ => Err(RedisRateLimitError::InvalidResponse),
    }
}

fn read_redis_line<R: BufRead>(reader: &mut R) -> Result<String, RedisRateLimitError> {
    let mut line = String::new();
    reader
        .read_line(&mut line)
        .map_err(|_| RedisRateLimitError::Unavailable)?;
    if !line.ends_with("\r\n") {
        return Err(RedisRateLimitError::InvalidResponse);
    }
    line.truncate(line.len() - 2);
    Ok(line)
}

fn redis_decision_from_response(
    response: RedisResponse,
) -> Result<LoginFailureRateLimitDecision, RedisRateLimitError> {
    let RedisResponse::Array(items) = response else {
        return Err(RedisRateLimitError::InvalidResponse);
    };
    if items.len() != 3 {
        return Err(RedisRateLimitError::InvalidResponse);
    }
    let limited = redis_integer(&items[0])? == 1;
    let failure_count = u32::try_from(redis_integer(&items[1])?)
        .map_err(|_| RedisRateLimitError::InvalidResponse)?;
    let retry_after = u64::try_from(redis_integer(&items[2])?)
        .map_err(|_| RedisRateLimitError::InvalidResponse)?;
    Ok(LoginFailureRateLimitDecision {
        is_limited: limited,
        retry_after_seconds: if limited {
            Some(retry_after.max(1))
        } else {
            None
        },
        failure_count,
    })
}

fn redis_integer(response: &RedisResponse) -> Result<i64, RedisRateLimitError> {
    match response {
        RedisResponse::Integer(value) => Ok(*value),
        _ => Err(RedisRateLimitError::InvalidResponse),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

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

    #[test]
    fn redis_key_uses_tenant_and_fingerprint_without_raw_username() {
        let key = key(Uuid::nil(), "Admin@Example.com");
        let redis_key = key.redis_key("auth failures/raw");

        assert!(redis_key.contains("tenant:00000000-0000-0000-0000-000000000000"));
        assert!(redis_key.contains("login:"));
        assert!(!redis_key.contains("Admin@Example.com"));
        assert!(!redis_key.contains("admin@example.com"));
        assert!(!redis_key.contains(' '));
        assert!(!redis_key.contains('/'));
    }

    #[test]
    fn redis_backend_unavailable_fails_closed_without_credential_material() {
        let store = RedisLoginFailureRateLimitStore::new(RedisLoginFailureRateLimitConfig {
            addr: "127.0.0.1:0".to_string(),
            db: 0,
            key_prefix: DEFAULT_REDIS_KEY_PREFIX.to_string(),
            timeout: Duration::from_millis(1),
        });
        let policy = LoginFailureRateLimitPolicy::new(2, 60);
        let key = key(Uuid::nil(), "admin@example.com");

        let check = store.check(&key, 100, policy);
        let record = store.record_failure(&key, 100, policy);
        let debug = format!("{store:?}");

        assert!(check.is_limited);
        assert_eq!(check.retry_after_seconds, Some(60));
        assert!(record.is_limited);
        assert!(!debug.contains("admin@example.com"));
        assert!(!debug.contains("127.0.0.1:0"));
        assert!(!debug.contains("password"));
    }

    #[test]
    fn redis_decision_parser_accepts_script_array_response() {
        let response = redis_decision_from_response(RedisResponse::Array(vec![
            RedisResponse::Integer(1),
            RedisResponse::Integer(5),
            RedisResponse::Integer(42),
        ]))
        .expect("valid redis script response should parse");

        assert!(response.is_limited);
        assert_eq!(response.failure_count, 5);
        assert_eq!(response.retry_after_seconds, Some(42));
    }

    #[test]
    fn redis_resp_parser_reads_arrays_and_bulk_values() {
        let mut reader = Cursor::new(b"*3\r\n:1\r\n$3\r\nabc\r\n+OK\r\n".as_slice());
        let response = read_redis_response(&mut reader).expect("RESP should parse");

        assert_eq!(
            response,
            RedisResponse::Array(vec![
                RedisResponse::Integer(1),
                RedisResponse::Bulk(Some(b"abc".to_vec())),
                RedisResponse::Simple("OK".to_string()),
            ])
        );
    }

    #[test]
    fn redis_scripts_are_atomic_and_expiring() {
        assert!(REDIS_CHECK_SCRIPT.contains("redis.call(\"GET\""));
        assert!(REDIS_CHECK_SCRIPT.contains("redis.call(\"DEL\""));
        assert!(REDIS_RECORD_FAILURE_SCRIPT.contains("redis.call(\"SET\""));
        assert!(REDIS_RECORD_FAILURE_SCRIPT.contains("\"EX\""));
        assert!(!REDIS_RECORD_FAILURE_SCRIPT.contains("username"));
        assert!(!REDIS_RECORD_FAILURE_SCRIPT.contains("email"));
    }

    #[test]
    fn admin_auth_fixture_tracks_redis_distributed_rate_limit_contract() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../tests/fixtures/control-plane/admin_auth_smoke.json"
        ))
        .expect("auth smoke fixture should parse");
        let contract = &fixture["auth_endpoints"]["login"]["failure_rate_limit"];
        let redis = &contract["redis_distributed_store"];

        assert_eq!(contract["key"], "tenant_id + normalized_email_fingerprint");
        assert_eq!(contract["default_store"], "memory");
        assert_eq!(redis["status"], "minimal_runtime_backend");
        assert_eq!(redis["unavailable_policy"], "fail_closed");
        assert_eq!(redis["unavailable_status"], 429);
        assert_eq!(redis["unavailable_error_code"], "login_rate_limited");
        assert_eq!(redis["raw_username_stored"], false);
        assert_eq!(
            redis["unavailable_response_echoes_username_or_credentials"],
            false
        );
    }
}
