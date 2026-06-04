use std::{
    env, fs,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    path::Path,
};

use ai_gateway_observability::{
    PROMPT_PROTECTION_RULE_SET_SCHEMA, PromptProtectionRuntimeConfig,
    parse_prompt_protection_runtime_config,
    prompt_protection::{
        MAX_PROMPT_PROTECTION_CONFIGURED_RULES, MAX_PROMPT_PROTECTION_RULE_NAME_BYTES,
        MAX_PROMPT_PROTECTION_RULE_PATTERN_BYTES, MAX_PROMPT_PROTECTION_RULE_SCOPE_BYTES,
    },
    prompt_protection_runtime_config_summary,
};
use reqwest::Url;
use serde::Deserialize;
use serde_json::{Value, json};
use thiserror::Error;

pub const CONFIG_ENV: &str = "AI_GATEWAY_CONFIG";
pub const DEFAULT_CONFIG_PATH: &str = "examples/config.example.yaml";
pub const APP_ENV_ENV: &str = "AI_GATEWAY_ENV";
pub const ALLOW_UNSAFE_PROVIDER_ENDPOINTS_ENV: &str = "AI_GATEWAY_ALLOW_UNSAFE_PROVIDER_ENDPOINTS";

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("failed to read config file `{path}`: {source}")]
    Read {
        path: String,
        #[source]
        source: std::io::Error,
    },
    #[error("failed to parse config yaml `{path}`: {source}")]
    Parse {
        path: String,
        #[source]
        source: serde_yaml::Error,
    },
    #[error("invalid config: {0}")]
    Invalid(String),
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct AppConfig {
    pub server: ServerConfig,
    pub database: DatabaseConfig,
    pub redis: RedisConfig,
    pub security: SecurityConfig,
    pub routing: RoutingConfig,
    pub observability: ObservabilityConfig,
    pub billing: BillingConfig,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ServerConfig {
    pub listen: String,
    pub public_base_url: String,
    pub max_request_body_bytes: u64,
    pub graceful_shutdown_seconds: u64,
    #[serde(default)]
    pub trusted_proxy_allowlist: Vec<String>,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct DatabaseConfig {
    pub driver: String,
    pub dsn: String,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct RedisConfig {
    pub addr: String,
    pub db: u32,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SecurityConfig {
    pub master_key_env: String,
    pub secret_masking: bool,
    pub default_payload_policy: String,
    #[serde(default)]
    pub prompt_protection: PromptProtectionConfig,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct PromptProtectionConfig {
    #[serde(default = "default_prompt_protection_mode")]
    pub mode: String,
    #[serde(default = "default_true")]
    pub default_rules: bool,
    #[serde(default)]
    pub custom_rules: Vec<Value>,
    #[serde(default)]
    pub limits: PromptProtectionLimitsConfig,
}

impl Default for PromptProtectionConfig {
    fn default() -> Self {
        Self {
            mode: default_prompt_protection_mode(),
            default_rules: true,
            custom_rules: Vec::new(),
            limits: PromptProtectionLimitsConfig::default(),
        }
    }
}

impl PromptProtectionConfig {
    pub fn to_runtime_config(&self) -> Result<PromptProtectionRuntimeConfig, ConfigError> {
        self.validate_limits()?;
        self.validate_custom_rules_against_limits()?;
        parse_prompt_protection_runtime_config(&self.runtime_config_value()).map_err(|error| {
            ConfigError::Invalid(format!(
                "security.prompt_protection failed validation: code={}, field={}",
                error.code,
                error.field.as_deref().unwrap_or("unknown")
            ))
        })
    }

    pub fn safe_summary(&self) -> Result<Value, ConfigError> {
        let runtime_config = self.to_runtime_config()?;
        Ok(prompt_protection_runtime_config_summary(&runtime_config))
    }

    fn runtime_config_value(&self) -> Value {
        json!({
            "schema": PROMPT_PROTECTION_RULE_SET_SCHEMA,
            "mode": self.mode,
            "default_rules": self.default_rules,
            "custom_rules": {
                "schema": PROMPT_PROTECTION_RULE_SET_SCHEMA,
                "rules": self.custom_rules,
            },
        })
    }

    fn validate_limits(&self) -> Result<(), ConfigError> {
        validate_optional_limit(
            "security.prompt_protection.limits.max_rules",
            self.limits.max_rules,
            MAX_PROMPT_PROTECTION_CONFIGURED_RULES,
        )?;
        validate_optional_limit(
            "security.prompt_protection.limits.max_rule_name_bytes",
            self.limits.max_rule_name_bytes,
            MAX_PROMPT_PROTECTION_RULE_NAME_BYTES,
        )?;
        validate_optional_limit(
            "security.prompt_protection.limits.max_pattern_bytes",
            self.limits.max_pattern_bytes,
            MAX_PROMPT_PROTECTION_RULE_PATTERN_BYTES,
        )?;
        validate_optional_limit(
            "security.prompt_protection.limits.max_scope_bytes",
            self.limits.max_scope_bytes,
            MAX_PROMPT_PROTECTION_RULE_SCOPE_BYTES,
        )
    }

    fn validate_custom_rules_against_limits(&self) -> Result<(), ConfigError> {
        if let Some(max_rules) = self.limits.max_rules {
            if self.custom_rules.len() > max_rules {
                return Err(ConfigError::Invalid(format!(
                    "security.prompt_protection.custom_rules exceeds configured max_rules ({max_rules})"
                )));
            }
        }

        for (index, rule) in self.custom_rules.iter().enumerate() {
            let Some(object) = rule.as_object() else {
                continue;
            };
            if let Some(value) = object.get("name").or_else(|| object.get("id")) {
                validate_optional_string_bytes_limit(
                    &format!("security.prompt_protection.custom_rules[{index}].name"),
                    value,
                    self.limits.max_rule_name_bytes,
                )?;
            }
            if let Some(value) = object.get("scope") {
                validate_optional_string_bytes_limit(
                    &format!("security.prompt_protection.custom_rules[{index}].scope"),
                    value,
                    self.limits.max_scope_bytes,
                )?;
            }
            if let Some(pattern) = object.get("pattern") {
                validate_prompt_protection_pattern_limit(
                    &format!("security.prompt_protection.custom_rules[{index}].pattern"),
                    pattern,
                    self.limits.max_pattern_bytes,
                )?;
            }
        }

        Ok(())
    }
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct PromptProtectionLimitsConfig {
    pub max_rules: Option<usize>,
    pub max_rule_name_bytes: Option<usize>,
    pub max_pattern_bytes: Option<usize>,
    pub max_scope_bytes: Option<usize>,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct RoutingConfig {
    pub default_max_attempts: u32,
    pub retry_before_first_byte_only_for_stream: bool,
    pub default_timeout_seconds: u64,
    pub stream_idle_timeout_seconds: u64,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ObservabilityConfig {
    pub metrics_enabled: bool,
    pub otlp_enabled: bool,
    pub log_payload_default: bool,
    pub raw_stream_sampling_rate: f64,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct BillingConfig {
    pub pre_authorize_enabled: bool,
    pub reserve_enabled: bool,
    pub default_currency: String,
    pub settlement_async: bool,
}

impl AppConfig {
    pub fn load_from_env() -> Result<Self, ConfigError> {
        let path = match env::var(CONFIG_ENV) {
            Ok(path) => path,
            Err(_) if is_production_env() => {
                return Err(ConfigError::Invalid(format!(
                    "{CONFIG_ENV} must be set when {APP_ENV_ENV}=production"
                )));
            }
            Err(_) => DEFAULT_CONFIG_PATH.to_string(),
        };
        Self::load_from_path(path)
    }

    pub fn load_from_path(path: impl AsRef<Path>) -> Result<Self, ConfigError> {
        let path = path.as_ref();
        let path_display = path.display().to_string();
        let body = fs::read_to_string(path).map_err(|source| ConfigError::Read {
            path: path_display.clone(),
            source,
        })?;
        serde_yaml::from_str(&body).map_err(|source| ConfigError::Parse {
            path: path_display,
            source,
        })
    }

    pub fn validate(&self) -> Result<(), ConfigError> {
        require_not_empty("server.listen", &self.server.listen)?;
        require_listen_addr("server.listen", &self.server.listen)?;
        require_not_empty("server.public_base_url", &self.server.public_base_url)?;
        require_http_base_url("server.public_base_url", &self.server.public_base_url)?;
        require_positive(
            "server.max_request_body_bytes",
            self.server.max_request_body_bytes,
        )?;
        require_positive(
            "server.graceful_shutdown_seconds",
            self.server.graceful_shutdown_seconds,
        )?;
        require_ip_allowlist_entries(
            "server.trusted_proxy_allowlist",
            &self.server.trusted_proxy_allowlist,
        )?;
        require_not_empty("database.driver", &self.database.driver)?;
        require_one_of("database.driver", &self.database.driver, &["postgres"])?;
        require_not_empty("database.dsn", &self.database.dsn)?;
        require_not_empty("redis.addr", &self.redis.addr)?;
        require_not_empty("security.master_key_env", &self.security.master_key_env)?;
        require_one_of(
            "security.default_payload_policy",
            &self.security.default_payload_policy,
            &["metadata_only", "hash", "redacted", "full"],
        )?;
        self.security.prompt_protection.to_runtime_config()?;
        require_positive(
            "routing.default_max_attempts",
            self.routing.default_max_attempts,
        )?;
        require_positive(
            "routing.default_timeout_seconds",
            self.routing.default_timeout_seconds,
        )?;
        require_positive(
            "routing.stream_idle_timeout_seconds",
            self.routing.stream_idle_timeout_seconds,
        )?;

        if !(0.0..=1.0).contains(&self.observability.raw_stream_sampling_rate) {
            return Err(ConfigError::Invalid(
                "observability.raw_stream_sampling_rate must be between 0 and 1".to_string(),
            ));
        }

        require_not_empty("billing.default_currency", &self.billing.default_currency)?;
        require_ascii_token("billing.default_currency", &self.billing.default_currency)?;
        Ok(())
    }
}

pub fn ip_allowlist_contains(entries: &[String], client_ip: IpAddr) -> bool {
    entries
        .iter()
        .any(|entry| parse_ip_allowlist_entry(entry).is_some_and(|entry| entry.matches(client_ip)))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProviderEndpointPolicy {
    pub allow_unsafe_local_endpoints: bool,
}

impl ProviderEndpointPolicy {
    pub fn from_env() -> Self {
        Self {
            allow_unsafe_local_endpoints: env_truthy(ALLOW_UNSAFE_PROVIDER_ENDPOINTS_ENV),
        }
    }

    pub const fn strict() -> Self {
        Self {
            allow_unsafe_local_endpoints: false,
        }
    }

    pub const fn allow_unsafe_for_dev() -> Self {
        Self {
            allow_unsafe_local_endpoints: true,
        }
    }
}

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum ProviderEndpointValidationError {
    #[error("endpoint URL is invalid")]
    InvalidUrl,
    #[error("endpoint must use http or https")]
    UnsupportedScheme,
    #[error("endpoint must use https unless unsafe provider endpoints are explicitly allowed")]
    InsecureScheme,
    #[error("endpoint must not include username or password")]
    UserInfo,
    #[error("endpoint host is required")]
    MissingHost,
    #[error("endpoint host is not allowed")]
    ForbiddenHost,
    #[error("endpoint must not include query string or fragment")]
    QueryOrFragment,
}

pub fn validate_provider_endpoint(
    endpoint: &str,
    policy: ProviderEndpointPolicy,
) -> Result<String, ProviderEndpointValidationError> {
    let trimmed = endpoint.trim().trim_end_matches('/');
    let url = Url::parse(trimmed).map_err(|_| ProviderEndpointValidationError::InvalidUrl)?;

    match url.scheme() {
        "http" | "https" => {}
        _ => return Err(ProviderEndpointValidationError::UnsupportedScheme),
    }

    if url.scheme() != "https" && !policy.allow_unsafe_local_endpoints {
        return Err(ProviderEndpointValidationError::InsecureScheme);
    }

    if !url.username().is_empty() || url.password().is_some() {
        return Err(ProviderEndpointValidationError::UserInfo);
    }

    let host = url
        .host_str()
        .ok_or(ProviderEndpointValidationError::MissingHost)?;
    if !policy.allow_unsafe_local_endpoints && forbidden_provider_host(host) {
        return Err(ProviderEndpointValidationError::ForbiddenHost);
    }

    if url.query().is_some() || url.fragment().is_some() {
        return Err(ProviderEndpointValidationError::QueryOrFragment);
    }

    Ok(trimmed.to_string())
}

pub fn provider_endpoint_resolved_ip_allowed(ip: IpAddr) -> bool {
    !forbidden_provider_ip(ip)
}

fn is_production_env() -> bool {
    env::var(APP_ENV_ENV)
        .map(|value| value.trim().eq_ignore_ascii_case("production"))
        .unwrap_or(false)
}

fn env_truthy(name: &str) -> bool {
    env::var(name)
        .map(|value| {
            matches!(
                value.trim().to_ascii_lowercase().as_str(),
                "1" | "true" | "yes" | "on"
            )
        })
        .unwrap_or(false)
}

fn default_true() -> bool {
    true
}

fn default_prompt_protection_mode() -> String {
    "enforce".to_string()
}

fn validate_optional_limit(
    name: &str,
    value: Option<usize>,
    maximum: usize,
) -> Result<(), ConfigError> {
    let Some(value) = value else {
        return Ok(());
    };
    if value == 0 || value > maximum {
        return Err(ConfigError::Invalid(format!(
            "{name} must be between 1 and {maximum}"
        )));
    }
    Ok(())
}

fn validate_optional_string_bytes_limit(
    name: &str,
    value: &Value,
    maximum: Option<usize>,
) -> Result<(), ConfigError> {
    let Some(maximum) = maximum else {
        return Ok(());
    };
    let Some(value) = value.as_str() else {
        return Ok(());
    };
    if value.trim().len() > maximum {
        return Err(ConfigError::Invalid(format!(
            "{name} exceeds configured byte limit ({maximum})"
        )));
    }
    Ok(())
}

fn validate_prompt_protection_pattern_limit(
    name: &str,
    value: &Value,
    maximum: Option<usize>,
) -> Result<(), ConfigError> {
    let Some(maximum) = maximum else {
        return Ok(());
    };

    match value {
        Value::String(_) => validate_optional_string_bytes_limit(name, value, Some(maximum)),
        Value::Object(object) => {
            if let Some(value) = object.get("value").or_else(|| object.get("literal")) {
                validate_optional_string_bytes_limit(
                    &format!("{name}.value"),
                    value,
                    Some(maximum),
                )?;
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

fn forbidden_provider_host(host: &str) -> bool {
    let normalized = host.trim().trim_end_matches('.').to_ascii_lowercase();
    if normalized == "localhost" || normalized.ends_with(".localhost") {
        return true;
    }

    normalized
        .parse::<IpAddr>()
        .map(forbidden_provider_ip)
        .unwrap_or(false)
}

fn forbidden_provider_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => {
            ip.is_loopback()
                || ip.is_private()
                || ip.is_link_local()
                || ip.is_unspecified()
                || ip.is_multicast()
                || ip == Ipv4Addr::BROADCAST
                || ip.octets() == [169, 254, 169, 254]
        }
        IpAddr::V6(ip) => {
            ip.is_loopback()
                || ip.is_unspecified()
                || ip.is_multicast()
                || ip.is_unique_local()
                || is_ipv6_unicast_link_local(ip)
        }
    }
}

fn is_ipv6_unicast_link_local(ip: Ipv6Addr) -> bool {
    (ip.segments()[0] & 0xffc0) == 0xfe80
}

fn require_not_empty(name: &str, value: &str) -> Result<(), ConfigError> {
    if value.trim().is_empty() {
        return Err(ConfigError::Invalid(format!("{name} must not be empty")));
    }
    Ok(())
}

fn require_positive<T>(name: &str, value: T) -> Result<(), ConfigError>
where
    T: PartialOrd + From<u8> + std::fmt::Display,
{
    if value <= T::from(0) {
        return Err(ConfigError::Invalid(format!("{name} must be positive")));
    }
    Ok(())
}

fn require_listen_addr(name: &str, value: &str) -> Result<(), ConfigError> {
    let normalized = if value.starts_with(':') {
        format!("0.0.0.0{value}")
    } else {
        value.to_string()
    };
    normalized
        .parse::<SocketAddr>()
        .map(|_| ())
        .map_err(|_| ConfigError::Invalid(format!("{name} must be a valid socket address")))
}

fn require_ip_allowlist_entries(name: &str, entries: &[String]) -> Result<(), ConfigError> {
    for entry in entries {
        if parse_ip_allowlist_entry(entry).is_none() {
            return Err(ConfigError::Invalid(format!(
                "{name} entries must be valid IP addresses or CIDR ranges"
            )));
        }
    }
    Ok(())
}

fn require_http_base_url(name: &str, value: &str) -> Result<(), ConfigError> {
    let trimmed = value.trim();
    if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        return Ok(());
    }
    Err(ConfigError::Invalid(format!(
        "{name} must start with http:// or https://"
    )))
}

fn require_one_of(name: &str, value: &str, allowed: &[&str]) -> Result<(), ConfigError> {
    if allowed.contains(&value) {
        return Ok(());
    }
    Err(ConfigError::Invalid(format!(
        "{name} must be one of: {}",
        allowed.join(", ")
    )))
}

fn require_ascii_token(name: &str, value: &str) -> Result<(), ConfigError> {
    if value
        .chars()
        .all(|character| character.is_ascii_uppercase() || character == '_' || character == '-')
    {
        return Ok(());
    }
    Err(ConfigError::Invalid(format!(
        "{name} must be an uppercase ASCII token"
    )))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum IpAllowlistEntry {
    Single(IpAddr),
    Cidr { network: IpAddr, prefix_len: u8 },
}

impl IpAllowlistEntry {
    fn matches(self, client_ip: IpAddr) -> bool {
        match self {
            Self::Single(allowed_ip) => allowed_ip == client_ip,
            Self::Cidr {
                network,
                prefix_len,
            } => cidr_matches(network, prefix_len, client_ip),
        }
    }
}

fn parse_ip_allowlist_entry(entry: &str) -> Option<IpAllowlistEntry> {
    let entry = entry.trim();
    if entry.is_empty() {
        return None;
    }

    if let Some((network, prefix_len)) = entry.split_once('/') {
        let network = network.trim().parse::<IpAddr>().ok()?;
        let prefix_len = prefix_len.trim().parse::<u8>().ok()?;
        return valid_prefix_len(network, prefix_len).then_some(IpAllowlistEntry::Cidr {
            network,
            prefix_len,
        });
    }

    entry.parse::<IpAddr>().ok().map(IpAllowlistEntry::Single)
}

fn valid_prefix_len(network: IpAddr, prefix_len: u8) -> bool {
    match network {
        IpAddr::V4(_) => prefix_len <= 32,
        IpAddr::V6(_) => prefix_len <= 128,
    }
}

fn cidr_matches(network: IpAddr, prefix_len: u8, client_ip: IpAddr) -> bool {
    match (network, client_ip) {
        (IpAddr::V4(network), IpAddr::V4(client)) => {
            prefix_matches(network.octets(), client.octets(), prefix_len)
        }
        (IpAddr::V6(network), IpAddr::V6(client)) => {
            prefix_matches(network.octets(), client.octets(), prefix_len)
        }
        _ => false,
    }
}

fn prefix_matches<const N: usize>(network: [u8; N], client: [u8; N], prefix_len: u8) -> bool {
    let full_bytes = usize::from(prefix_len / 8);
    if network[..full_bytes] != client[..full_bytes] {
        return false;
    }

    let remaining_bits = prefix_len % 8;
    if remaining_bits == 0 {
        return true;
    }

    let mask = u8::MAX << (8 - remaining_bits);
    (network[full_bytes] & mask) == (client[full_bytes] & mask)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ai_gateway_observability::apply_prompt_protection_runtime_config_to_json;
    use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

    #[test]
    fn loads_example_config() {
        let config = AppConfig::load_from_path("../../examples/config.example.yaml").unwrap();
        config.validate().unwrap();
        assert_eq!(config.database.driver, "postgres");
        assert!(config.server.trusted_proxy_allowlist.is_empty());
        assert_eq!(config.security.prompt_protection.mode, "enforce");
        assert!(config.security.prompt_protection.default_rules);
        assert!(config.security.prompt_protection.custom_rules.is_empty());
    }

    #[test]
    fn rejects_invalid_payload_policy() {
        let mut config = AppConfig::load_from_path("../../examples/config.example.yaml").unwrap();
        config.security.default_payload_policy = "raw".to_string();

        let error = config.validate().expect_err("invalid payload policy");

        assert!(error.to_string().contains("default_payload_policy"));
    }

    #[test]
    fn prompt_protection_schema_validates_modes_limits_and_custom_regex_rules() {
        for mode in ["enforce", "audit", "disabled"] {
            let mut config =
                AppConfig::load_from_path("../../examples/config.example.yaml").unwrap();
            config.security.prompt_protection = PromptProtectionConfig {
                mode: mode.to_string(),
                default_rules: true,
                custom_rules: vec![json!({
                    "name": "gateway_ticket_reject",
                    "action": "reject",
                    "scope": "messages",
                    "pattern": { "type": "regex", "value": "ticket-[0-9]{4}" }
                })],
                limits: PromptProtectionLimitsConfig {
                    max_rules: Some(MAX_PROMPT_PROTECTION_CONFIGURED_RULES),
                    max_rule_name_bytes: Some(MAX_PROMPT_PROTECTION_RULE_NAME_BYTES),
                    max_pattern_bytes: Some(MAX_PROMPT_PROTECTION_RULE_PATTERN_BYTES),
                    max_scope_bytes: Some(MAX_PROMPT_PROTECTION_RULE_SCOPE_BYTES),
                },
            };

            config.validate().expect("valid prompt protection config");
            let runtime = config
                .security
                .prompt_protection
                .to_runtime_config()
                .expect("runtime prompt protection config");
            let summary = config
                .security
                .prompt_protection
                .safe_summary()
                .expect("safe prompt protection summary");

            assert_eq!(summary["mode"], mode);
            assert_eq!(summary["custom_rule_count"], 1);
            assert_eq!(summary["raw_pattern_values_omitted"], true);
            assert!(!summary.to_string().contains("ticket-[0-9]{4}"));

            if mode == "enforce" {
                let result = apply_prompt_protection_runtime_config_to_json(
                    &json!({
                        "model": "mock-gpt",
                        "messages": [{ "role": "user", "content": "ticket-1234" }]
                    }),
                    &runtime,
                );
                assert_eq!(result.configured_result.hits.len(), 1);
            }
        }
    }

    #[test]
    fn prompt_protection_schema_deserializes_from_security_yaml() {
        let config: AppConfig = serde_yaml::from_str(&config_yaml_with_prompt_protection(
            r#"
  prompt_protection:
    mode: audit
    default_rules: true
    limits:
      max_rules: 32
      max_rule_name_bytes: 64
      max_pattern_bytes: 256
      max_scope_bytes: 128
    custom_rules:
      - name: gateway_mask_codename
        action: mask
        scope: messages
        pattern:
          type: contains
          value: project raven
          case_sensitive: false
"#,
        ))
        .expect("prompt protection yaml config");

        config.validate().expect("valid prompt protection yaml");
        assert_eq!(config.security.prompt_protection.mode, "audit");
        assert_eq!(config.security.prompt_protection.custom_rules.len(), 1);
        let summary = config
            .security
            .prompt_protection
            .safe_summary()
            .expect("safe summary");
        let summary_text = summary.to_string().to_ascii_lowercase();

        assert_eq!(summary["mode"], "audit");
        assert!(!summary_text.contains("project raven"));
    }

    #[test]
    fn prompt_protection_schema_rejects_invalid_rules_without_secret_echo() {
        let invalid_regex = prompt_protection_error_for_rules(vec![json!({
            "name": "gateway_invalid_regex",
            "action": "reject",
            "scope": "messages",
            "pattern": { "type": "regex", "value": "(" }
        })]);
        assert!(invalid_regex.contains("invalid_regex"));
        assert!(!invalid_regex.contains('('));

        let long_pattern = "a".repeat(MAX_PROMPT_PROTECTION_RULE_PATTERN_BYTES + 1);
        let pattern_too_long = prompt_protection_error_for_rules(vec![json!({
            "name": "gateway_long_pattern",
            "action": "mask",
            "scope": "messages",
            "pattern": { "type": "contains", "value": long_pattern }
        })]);
        assert!(pattern_too_long.contains("pattern_value_too_long"));
        assert!(!pattern_too_long.contains(&"a".repeat(64)));

        let too_many_rules = prompt_protection_error_for_rules(
            (0..=MAX_PROMPT_PROTECTION_CONFIGURED_RULES)
                .map(|index| {
                    json!({
                        "name": format!("gateway_rule_{index}"),
                        "action": "mask",
                        "scope": "messages",
                        "pattern": { "type": "contains", "value": "safe marker" }
                    })
                })
                .collect(),
        );
        assert!(too_many_rules.contains("too_many_rules"));

        let secret_name = prompt_protection_error_for_rules(vec![json!({
            "name": "sk-live-secret",
            "action": "mask",
            "scope": "messages",
            "pattern": { "type": "contains", "value": "safe marker" }
        })]);
        assert!(secret_name.contains("secret_like_rule_name"));
        assert!(!secret_name.contains("sk-live-secret"));

        let secret_pattern = prompt_protection_error_for_rules(vec![json!({
            "name": "gateway_header_marker",
            "action": "reject",
            "scope": "messages",
            "pattern": {
                "type": "contains",
                "value": "Authorization: Bearer sk-live-secret"
            }
        })]);
        assert!(secret_pattern.contains("secret_like_pattern_value"));
        assert!(!secret_pattern.contains("sk-live-secret"));
        assert!(!secret_pattern.contains("Authorization: Bearer"));
    }

    #[test]
    fn prompt_protection_schema_rejects_invalid_limits_and_modes_without_raw_value() {
        let mut config = PromptProtectionConfig {
            mode: "sk-live-secret".to_string(),
            ..PromptProtectionConfig::default()
        };
        let invalid_mode = config
            .to_runtime_config()
            .expect_err("invalid mode should fail")
            .to_string();
        assert!(invalid_mode.contains("invalid_mode"));
        assert!(!invalid_mode.contains("sk-live-secret"));

        config = PromptProtectionConfig {
            limits: PromptProtectionLimitsConfig {
                max_rules: Some(MAX_PROMPT_PROTECTION_CONFIGURED_RULES + 1),
                ..PromptProtectionLimitsConfig::default()
            },
            ..PromptProtectionConfig::default()
        };
        let invalid_limit = config
            .to_runtime_config()
            .expect_err("invalid limit should fail")
            .to_string();
        assert!(invalid_limit.contains("security.prompt_protection.limits.max_rules"));
        assert!(!invalid_limit.contains("sk-live-secret"));
    }

    #[test]
    fn prompt_protection_schema_applies_configured_custom_limits_without_raw_value() {
        let limited_rule_count = PromptProtectionConfig {
            custom_rules: vec![
                json!({
                    "name": "gateway_rule_one",
                    "action": "mask",
                    "scope": "messages",
                    "pattern": { "type": "contains", "value": "safe marker one" }
                }),
                json!({
                    "name": "gateway_rule_two",
                    "action": "mask",
                    "scope": "messages",
                    "pattern": { "type": "contains", "value": "safe marker two" }
                }),
            ],
            limits: PromptProtectionLimitsConfig {
                max_rules: Some(1),
                ..PromptProtectionLimitsConfig::default()
            },
            ..PromptProtectionConfig::default()
        };
        let rule_count_error = limited_rule_count
            .to_runtime_config()
            .expect_err("custom max_rules should apply")
            .to_string();
        assert!(rule_count_error.contains("max_rules"));
        assert!(!rule_count_error.contains("safe marker"));

        let limited_fields = PromptProtectionConfig {
            custom_rules: vec![json!({
                "name": "gateway_rule_long_name",
                "action": "reject",
                "scope": "$.messages[0].content",
                "pattern": {
                    "type": "contains",
                    "value": "safe marker too long for local limit"
                }
            })],
            limits: PromptProtectionLimitsConfig {
                max_rule_name_bytes: Some(8),
                max_pattern_bytes: Some(8),
                max_scope_bytes: Some(8),
                ..PromptProtectionLimitsConfig::default()
            },
            ..PromptProtectionConfig::default()
        };
        let name_error = limited_fields
            .to_runtime_config()
            .expect_err("custom max_rule_name_bytes should apply")
            .to_string();
        assert!(name_error.contains("custom_rules[0].name"));
        assert!(!name_error.contains("gateway_rule_long_name"));

        let mut pattern_limited = limited_fields.clone();
        pattern_limited.limits.max_rule_name_bytes = Some(MAX_PROMPT_PROTECTION_RULE_NAME_BYTES);
        pattern_limited.limits.max_scope_bytes = Some(MAX_PROMPT_PROTECTION_RULE_SCOPE_BYTES);
        let pattern_error = pattern_limited
            .to_runtime_config()
            .expect_err("custom max_pattern_bytes should apply")
            .to_string();
        assert!(pattern_error.contains("custom_rules[0].pattern.value"));
        assert!(!pattern_error.contains("safe marker too long"));

        let mut scope_limited = pattern_limited;
        scope_limited.limits.max_pattern_bytes = Some(MAX_PROMPT_PROTECTION_RULE_PATTERN_BYTES);
        scope_limited.limits.max_scope_bytes = Some(8);
        let scope_error = scope_limited
            .to_runtime_config()
            .expect_err("custom max_scope_bytes should apply")
            .to_string();
        assert!(scope_error.contains("custom_rules[0].scope"));
        assert!(!scope_error.contains("$.messages"));
    }

    #[test]
    fn prompt_protection_safe_summary_omits_raw_rule_values_and_payload_markers() {
        let config = PromptProtectionConfig {
            mode: "enforce".to_string(),
            default_rules: true,
            custom_rules: vec![json!({
                "name": "gateway_ticket_reject",
                "action": "reject",
                "scope": "messages",
                "pattern": { "type": "regex", "value": "ticket-[0-9]{4}" }
            })],
            limits: PromptProtectionLimitsConfig::default(),
        };

        let summary = config.safe_summary().expect("safe summary");
        let serialized = summary.to_string();

        assert_eq!(summary["raw_pattern_values_omitted"], true);
        assert!(!serialized.contains("ticket-[0-9]{4}"));
        assert!(!serialized.contains("ticket-1234"));
        assert!(!serialized.contains("Authorization: Bearer"));
        assert!(!serialized.contains("sk-live-secret"));
    }

    #[test]
    fn rejects_invalid_sampling_rate() {
        let mut config = AppConfig::load_from_path("../../examples/config.example.yaml").unwrap();
        config.observability.raw_stream_sampling_rate = 1.1;

        let error = config.validate().expect_err("invalid sampling rate");

        assert!(error.to_string().contains("raw_stream_sampling_rate"));
    }

    #[test]
    fn rejects_invalid_listen_addr() {
        let mut config = AppConfig::load_from_path("../../examples/config.example.yaml").unwrap();
        config.server.listen = "localhost".to_string();

        let error = config.validate().expect_err("invalid listen address");

        assert!(error.to_string().contains("server.listen"));
    }

    #[test]
    fn validates_trusted_proxy_allowlist_entries() {
        let mut config = AppConfig::load_from_path("../../examples/config.example.yaml").unwrap();
        config.server.trusted_proxy_allowlist = vec![
            "127.0.0.1".to_string(),
            "10.0.0.0/8".to_string(),
            "::1".to_string(),
            "2001:db8::/32".to_string(),
        ];

        config.validate().unwrap();
    }

    #[test]
    fn rejects_invalid_trusted_proxy_allowlist_entries() {
        let mut config = AppConfig::load_from_path("../../examples/config.example.yaml").unwrap();
        config.server.trusted_proxy_allowlist = vec!["2001:db8::/129".to_string()];

        let error = config
            .validate()
            .expect_err("invalid trusted proxy entry should be rejected");

        assert!(error.to_string().contains("trusted_proxy_allowlist"));
    }

    #[test]
    fn ip_allowlist_contains_matches_single_ips_and_cidrs() {
        let entries = vec![
            "192.0.2.10".to_string(),
            "203.0.113.0/24".to_string(),
            "2001:db8:abcd::/48".to_string(),
        ];

        assert!(ip_allowlist_contains(
            &entries,
            IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))
        ));
        assert!(ip_allowlist_contains(
            &entries,
            IpAddr::V4(Ipv4Addr::new(203, 0, 113, 99))
        ));
        assert!(ip_allowlist_contains(
            &entries,
            "2001:db8:abcd:1::1".parse().unwrap()
        ));
        assert!(!ip_allowlist_contains(
            &entries,
            IpAddr::V4(Ipv4Addr::new(198, 51, 100, 10))
        ));
        assert!(!ip_allowlist_contains(
            &entries,
            IpAddr::V6(Ipv6Addr::LOCALHOST)
        ));
    }

    #[test]
    fn provider_endpoint_policy_rejects_insecure_or_local_endpoints_by_default() {
        let policy = ProviderEndpointPolicy::strict();

        assert_eq!(
            validate_provider_endpoint("http://api.example.test", policy).unwrap_err(),
            ProviderEndpointValidationError::InsecureScheme
        );
        assert_eq!(
            validate_provider_endpoint("https://localhost:18080", policy).unwrap_err(),
            ProviderEndpointValidationError::ForbiddenHost
        );
        assert_eq!(
            validate_provider_endpoint("https://127.0.0.1:18080", policy).unwrap_err(),
            ProviderEndpointValidationError::ForbiddenHost
        );
        assert_eq!(
            validate_provider_endpoint("https://169.254.169.254/latest", policy).unwrap_err(),
            ProviderEndpointValidationError::ForbiddenHost
        );
    }

    #[test]
    fn provider_endpoint_policy_rejects_credential_or_query_material() {
        let policy = ProviderEndpointPolicy::strict();

        assert_eq!(
            validate_provider_endpoint("https://user:pass@api.example.test", policy).unwrap_err(),
            ProviderEndpointValidationError::UserInfo
        );
        assert_eq!(
            validate_provider_endpoint("https://api.example.test?token=abc", policy).unwrap_err(),
            ProviderEndpointValidationError::QueryOrFragment
        );
        assert_eq!(
            validate_provider_endpoint("https://api.example.test#fragment", policy).unwrap_err(),
            ProviderEndpointValidationError::QueryOrFragment
        );
    }

    #[test]
    fn provider_endpoint_policy_allows_https_public_endpoints() {
        let endpoint = validate_provider_endpoint(
            " https://api.example.test/v1/ ",
            ProviderEndpointPolicy::strict(),
        )
        .unwrap();

        assert_eq!(endpoint, "https://api.example.test/v1");
    }

    #[test]
    fn provider_endpoint_policy_can_allow_local_dev_endpoints() {
        let policy = ProviderEndpointPolicy::allow_unsafe_for_dev();

        assert_eq!(
            validate_provider_endpoint("http://127.0.0.1:18080/v1", policy).unwrap(),
            "http://127.0.0.1:18080/v1"
        );
    }

    #[test]
    fn provider_endpoint_resolved_ip_policy_rejects_internal_ranges() {
        assert!(provider_endpoint_resolved_ip_allowed(IpAddr::V4(
            Ipv4Addr::new(203, 0, 113, 10)
        )));
        assert!(!provider_endpoint_resolved_ip_allowed(IpAddr::V4(
            Ipv4Addr::new(10, 0, 0, 1)
        )));
        assert!(!provider_endpoint_resolved_ip_allowed(IpAddr::V4(
            Ipv4Addr::new(169, 254, 169, 254)
        )));
        assert!(!provider_endpoint_resolved_ip_allowed(IpAddr::V6(
            Ipv6Addr::LOCALHOST
        )));
        assert!(!provider_endpoint_resolved_ip_allowed(
            "fe80::1".parse().unwrap()
        ));
    }

    fn prompt_protection_error_for_rules(rules: Vec<Value>) -> String {
        PromptProtectionConfig {
            mode: "enforce".to_string(),
            default_rules: true,
            custom_rules: rules,
            limits: PromptProtectionLimitsConfig::default(),
        }
        .to_runtime_config()
        .expect_err("prompt protection config should fail")
        .to_string()
    }

    fn config_yaml_with_prompt_protection(prompt_protection_yaml: &str) -> String {
        format!(
            r#"server:
  listen: ":8080"
  public_base_url: "http://localhost:8080"
  max_request_body_bytes: 10485760
  graceful_shutdown_seconds: 30

database:
  driver: "postgres"
  dsn: "postgres://ai_gateway:ai_gateway@postgres:5432/ai_gateway?sslmode=disable"

redis:
  addr: "redis:6379"
  db: 0

security:
  master_key_env: "AI_GATEWAY_MASTER_KEY"
  secret_masking: true
  default_payload_policy: "metadata_only"
{prompt_protection_yaml}
routing:
  default_max_attempts: 2
  retry_before_first_byte_only_for_stream: true
  default_timeout_seconds: 120
  stream_idle_timeout_seconds: 60

observability:
  metrics_enabled: true
  otlp_enabled: false
  log_payload_default: false
  raw_stream_sampling_rate: 0.001

billing:
  pre_authorize_enabled: true
  reserve_enabled: true
  default_currency: "CREDIT"
  settlement_async: true
"#
        )
    }
}
