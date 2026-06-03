use std::{collections::BTreeMap, env, error::Error, fmt};

use crate::{REDACTED_SECRET, redact_secrets};

pub const DEFAULT_OTEL_SERVICE_NAME: &str = "ai-gateway";

const MAX_SERVICE_NAME_LEN: usize = 64;
const MAX_ATTRIBUTE_KEY_LEN: usize = 128;
const MAX_ATTRIBUTE_VALUE_LEN: usize = 256;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OtelConfig {
    exporter: OtelExporter,
    service_name: String,
    resource_attributes: BTreeMap<String, String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OtelExporter {
    Disabled,
    Stdout,
    Otlp { endpoint: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OtelInit {
    config: OtelConfig,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OtelConfigError {
    InvalidExporter {
        value: String,
    },
    MissingOtlpEndpoint,
    InvalidEndpoint {
        endpoint: String,
        reason: &'static str,
    },
}

impl Default for OtelConfig {
    fn default() -> Self {
        Self::disabled()
    }
}

impl OtelConfig {
    pub fn new<I, K, V>(
        exporter: OtelExporter,
        service_name: &str,
        resource_attributes: I,
    ) -> Result<Self, OtelConfigError>
    where
        I: IntoIterator<Item = (K, V)>,
        K: AsRef<str>,
        V: AsRef<str>,
    {
        let exporter = validate_exporter(exporter)?;
        let mut resource_attributes = sanitize_otel_resource_attributes(resource_attributes);
        let service_name = resolve_service_name(service_name, &resource_attributes);

        resource_attributes.insert("service.name".to_string(), service_name.clone());

        Ok(Self {
            exporter,
            service_name,
            resource_attributes,
        })
    }

    pub fn disabled() -> Self {
        Self::new(
            OtelExporter::Disabled,
            DEFAULT_OTEL_SERVICE_NAME,
            std::iter::empty::<(&str, &str)>(),
        )
        .expect("disabled OTEL config is always valid")
    }

    pub fn stdout(service_name: &str) -> Self {
        Self::new(
            OtelExporter::Stdout,
            service_name,
            std::iter::empty::<(&str, &str)>(),
        )
        .expect("stdout OTEL config is always valid")
    }

    pub fn otlp(endpoint: &str, service_name: &str) -> Result<Self, OtelConfigError> {
        Self::new(
            OtelExporter::Otlp {
                endpoint: endpoint.to_string(),
            },
            service_name,
            std::iter::empty::<(&str, &str)>(),
        )
    }

    pub fn from_env() -> Result<Self, OtelConfigError> {
        Self::from_env_vars(env::vars())
    }

    pub fn from_env_vars<I, K, V>(vars: I) -> Result<Self, OtelConfigError>
    where
        I: IntoIterator<Item = (K, V)>,
        K: Into<String>,
        V: Into<String>,
    {
        let vars = vars
            .into_iter()
            .map(|(key, value)| (key.into(), value.into()))
            .collect::<BTreeMap<_, _>>();

        let raw_attributes = resource_attributes_from_env(&vars);
        let service_name = first_nonempty_env(
            &vars,
            &["AI_GATEWAY_OTEL_SERVICE_NAME", "OTEL_SERVICE_NAME"],
        )
        .unwrap_or_default();
        let endpoint = first_nonempty_env(
            &vars,
            &[
                "AI_GATEWAY_OTEL_ENDPOINT",
                "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
                "OTEL_EXPORTER_OTLP_ENDPOINT",
            ],
        );

        if env_truthy(get_env(&vars, "AI_GATEWAY_OTEL_DISABLED"))
            || env_truthy(get_env(&vars, "OTEL_SDK_DISABLED"))
        {
            return Self::new(OtelExporter::Disabled, service_name, raw_attributes);
        }

        let exporter = match first_nonempty_env(
            &vars,
            &[
                "AI_GATEWAY_OTEL_EXPORTER",
                "OTEL_TRACES_EXPORTER",
                "AI_GATEWAY_OTLP_ENABLED",
            ],
        ) {
            Some(raw) => exporter_from_env_value(raw, endpoint)?,
            None => match endpoint {
                Some(endpoint) => OtelExporter::Otlp {
                    endpoint: endpoint.to_string(),
                },
                None => OtelExporter::Disabled,
            },
        };

        Self::new(exporter, service_name, raw_attributes)
    }

    pub fn with_resource_attributes<I, K, V>(mut self, resource_attributes: I) -> Self
    where
        I: IntoIterator<Item = (K, V)>,
        K: AsRef<str>,
        V: AsRef<str>,
    {
        self.resource_attributes
            .extend(sanitize_otel_resource_attributes(resource_attributes));
        self.resource_attributes
            .insert("service.name".to_string(), self.service_name.clone());
        self
    }

    pub fn exporter(&self) -> &OtelExporter {
        &self.exporter
    }

    pub fn service_name(&self) -> &str {
        &self.service_name
    }

    pub fn resource_attributes(&self) -> &BTreeMap<String, String> {
        &self.resource_attributes
    }

    pub fn is_enabled(&self) -> bool {
        self.exporter.is_enabled()
    }
}

impl OtelExporter {
    pub fn is_enabled(&self) -> bool {
        !matches!(self, Self::Disabled)
    }
}

impl OtelInit {
    pub fn exporter(&self) -> &OtelExporter {
        self.config.exporter()
    }

    pub fn service_name(&self) -> &str {
        self.config.service_name()
    }

    pub fn resource_attributes(&self) -> &BTreeMap<String, String> {
        self.config.resource_attributes()
    }

    pub fn is_enabled(&self) -> bool {
        self.config.is_enabled()
    }

    pub fn sdk_pipeline_enabled(&self) -> bool {
        false
    }

    pub fn shutdown(self) {}
}

impl fmt::Display for OtelConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidExporter { value } => {
                write!(
                    f,
                    "invalid OTEL exporter `{value}`; expected disabled, stdout, or otlp"
                )
            }
            Self::MissingOtlpEndpoint => {
                write!(f, "OTEL exporter `otlp` requires an http or https endpoint")
            }
            Self::InvalidEndpoint { endpoint, reason } => {
                write!(f, "invalid OTLP endpoint `{endpoint}`: {reason}")
            }
        }
    }
}

impl Error for OtelConfigError {}

pub fn init_otel_exporter(config: OtelConfig) -> Result<OtelInit, OtelConfigError> {
    let config = OtelConfig::new(
        config.exporter,
        &config.service_name,
        config.resource_attributes,
    )?;

    Ok(OtelInit { config })
}

pub fn sanitize_otel_service_name(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed == REDACTED_SECRET || redact_secrets(trimmed) != trimmed {
        return DEFAULT_OTEL_SERVICE_NAME.to_string();
    }

    let mut output = String::with_capacity(trimmed.len().min(MAX_SERVICE_NAME_LEN));
    let mut last_was_separator = false;

    for character in trimmed.chars() {
        let mapped = if character.is_ascii_alphanumeric() || matches!(character, '-' | '_' | '.') {
            Some(character)
        } else if character.is_ascii_whitespace() || character.is_ascii_punctuation() {
            Some('-')
        } else {
            None
        };

        let Some(mapped) = mapped else {
            continue;
        };

        let is_separator = matches!(mapped, '-' | '_' | '.');
        if is_separator && last_was_separator {
            continue;
        }

        output.push(mapped);
        last_was_separator = is_separator;

        if output.len() >= MAX_SERVICE_NAME_LEN {
            break;
        }
    }

    let output = output.trim_matches(['-', '_', '.']);
    if output.is_empty() {
        DEFAULT_OTEL_SERVICE_NAME.to_string()
    } else {
        output.to_string()
    }
}

pub fn sanitize_otel_resource_attributes<I, K, V>(attributes: I) -> BTreeMap<String, String>
where
    I: IntoIterator<Item = (K, V)>,
    K: AsRef<str>,
    V: AsRef<str>,
{
    attributes
        .into_iter()
        .filter_map(|(key, value)| {
            let key = sanitize_attribute_key(key.as_ref())?;
            let value = sanitize_attribute_value(value.as_ref())?;
            Some((key, value))
        })
        .collect()
}

fn validate_exporter(exporter: OtelExporter) -> Result<OtelExporter, OtelConfigError> {
    match exporter {
        OtelExporter::Disabled | OtelExporter::Stdout => Ok(exporter),
        OtelExporter::Otlp { endpoint } => Ok(OtelExporter::Otlp {
            endpoint: validate_otlp_endpoint(&endpoint)?,
        }),
    }
}

fn validate_otlp_endpoint(raw: &str) -> Result<String, OtelConfigError> {
    let endpoint = raw.trim();
    if endpoint.is_empty() {
        return Err(OtelConfigError::MissingOtlpEndpoint);
    }

    if endpoint
        .chars()
        .any(|character| character.is_control() || character.is_ascii_whitespace())
    {
        return Err(invalid_endpoint(
            endpoint,
            "must not contain whitespace or control characters",
        ));
    }

    if endpoint.contains('?') || endpoint.contains('#') {
        return Err(invalid_endpoint(
            endpoint,
            "must not contain query strings or fragments",
        ));
    }

    let lower = endpoint.to_ascii_lowercase();
    let after_scheme = if lower.starts_with("http://") {
        &endpoint["http://".len()..]
    } else if lower.starts_with("https://") {
        &endpoint["https://".len()..]
    } else {
        return Err(invalid_endpoint(endpoint, "scheme must be http or https"));
    };

    let authority_end = after_scheme.find('/').unwrap_or(after_scheme.len());
    let authority = &after_scheme[..authority_end];
    if authority.is_empty() {
        return Err(invalid_endpoint(endpoint, "host is required"));
    }

    if authority.contains('@') {
        return Err(invalid_endpoint(
            endpoint,
            "must not contain user information",
        ));
    }

    validate_authority(endpoint, authority)?;
    Ok(endpoint.to_string())
}

fn validate_authority(endpoint: &str, authority: &str) -> Result<(), OtelConfigError> {
    if authority.starts_with('[') {
        let Some(close_index) = authority.find(']') else {
            return Err(invalid_endpoint(endpoint, "invalid IPv6 host"));
        };
        let host = &authority[1..close_index];
        if host.is_empty() || !host.chars().all(is_valid_ipv6_host_character) {
            return Err(invalid_endpoint(endpoint, "invalid IPv6 host"));
        }
        let rest = &authority[close_index + 1..];
        if let Some(port) = rest.strip_prefix(':') {
            validate_port(endpoint, port)?;
        } else if !rest.is_empty() {
            return Err(invalid_endpoint(endpoint, "invalid host or port"));
        }
        return Ok(());
    }

    let (host, port) = match authority.rsplit_once(':') {
        Some((host, port)) => (host, Some(port)),
        None => (authority, None),
    };

    if host.is_empty()
        || host.starts_with('.')
        || host.ends_with('.')
        || !host.chars().all(is_valid_hostname_character)
    {
        return Err(invalid_endpoint(endpoint, "invalid host"));
    }

    if let Some(port) = port {
        validate_port(endpoint, port)?;
    }

    Ok(())
}

fn validate_port(endpoint: &str, port: &str) -> Result<(), OtelConfigError> {
    let Ok(port) = port.parse::<u16>() else {
        return Err(invalid_endpoint(endpoint, "invalid port"));
    };

    if port == 0 {
        Err(invalid_endpoint(endpoint, "invalid port"))
    } else {
        Ok(())
    }
}

fn is_valid_hostname_character(character: char) -> bool {
    character.is_ascii_alphanumeric() || matches!(character, '.' | '-' | '_')
}

fn is_valid_ipv6_host_character(character: char) -> bool {
    character.is_ascii_hexdigit() || character == ':'
}

fn invalid_endpoint(endpoint: &str, reason: &'static str) -> OtelConfigError {
    OtelConfigError::InvalidEndpoint {
        endpoint: safe_endpoint_for_error(endpoint),
        reason,
    }
}

fn safe_endpoint_for_error(endpoint: &str) -> String {
    let endpoint = endpoint.split(['?', '#']).next().unwrap_or(endpoint).trim();
    let endpoint = redact_endpoint_userinfo(endpoint);
    let redacted = redact_secrets(&endpoint);
    truncate_for_error(&redacted, 96)
}

fn safe_config_value_for_error(value: &str) -> String {
    truncate_for_error(&redact_secrets(value.trim()), 96)
}

fn redact_endpoint_userinfo(endpoint: &str) -> String {
    let Some((scheme, after_scheme)) = endpoint.split_once("://") else {
        return endpoint.to_string();
    };
    let authority_end = after_scheme.find('/').unwrap_or(after_scheme.len());
    let authority = &after_scheme[..authority_end];
    let Some(at_index) = authority.rfind('@') else {
        return endpoint.to_string();
    };

    let after_authority = &after_scheme[authority_end..];
    let host = &authority[at_index + 1..];
    format!("{scheme}://{REDACTED_SECRET}@{host}{after_authority}")
}

fn truncate_for_error(value: &str, max_len: usize) -> String {
    let mut output = String::new();

    for character in value.chars() {
        if output.len() + character.len_utf8() > max_len {
            output.push_str("...");
            return output;
        }
        output.push(character);
    }

    output
}

fn exporter_from_env_value(
    raw: &str,
    endpoint: Option<&str>,
) -> Result<OtelExporter, OtelConfigError> {
    let value = raw.trim();
    let normalized = value.to_ascii_lowercase();

    match normalized.as_str() {
        "" | "0" | "false" | "no" | "off" | "none" | "disabled" => Ok(OtelExporter::Disabled),
        "1" | "true" | "yes" | "on" | "otlp" => {
            let endpoint = endpoint.ok_or(OtelConfigError::MissingOtlpEndpoint)?;
            Ok(OtelExporter::Otlp {
                endpoint: endpoint.to_string(),
            })
        }
        "stdout" | "console" => Ok(OtelExporter::Stdout),
        _ => Err(OtelConfigError::InvalidExporter {
            value: safe_config_value_for_error(value),
        }),
    }
}

fn resource_attributes_from_env(vars: &BTreeMap<String, String>) -> Vec<(String, String)> {
    let mut attributes = Vec::new();
    for key in [
        "OTEL_RESOURCE_ATTRIBUTES",
        "AI_GATEWAY_OTEL_RESOURCE_ATTRIBUTES",
    ] {
        if let Some(raw) = get_env(vars, key) {
            attributes.extend(parse_resource_attributes(raw));
        }
    }
    attributes
}

fn parse_resource_attributes(raw: &str) -> Vec<(String, String)> {
    raw.split(',')
        .filter_map(|pair| {
            let (key, value) = pair.split_once('=')?;
            Some((key.trim().to_string(), value.trim().to_string()))
        })
        .collect()
}

fn resolve_service_name(
    service_name: &str,
    resource_attributes: &BTreeMap<String, String>,
) -> String {
    if service_name.trim().is_empty() {
        resource_attributes
            .get("service.name")
            .map(|service_name| sanitize_otel_service_name(service_name))
            .unwrap_or_else(|| DEFAULT_OTEL_SERVICE_NAME.to_string())
    } else {
        sanitize_otel_service_name(service_name)
    }
}

fn sanitize_attribute_key(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() || redact_secrets(trimmed) != trimmed {
        return None;
    }

    let mut output = String::with_capacity(trimmed.len().min(MAX_ATTRIBUTE_KEY_LEN));
    let mut last_was_separator = false;

    for character in trimmed.chars() {
        let mapped = if character.is_ascii_alphanumeric() {
            Some(character.to_ascii_lowercase())
        } else if matches!(character, '.' | '_' | '-') {
            Some(character)
        } else if character.is_ascii_whitespace() || matches!(character, ':' | '/') {
            Some('.')
        } else {
            None
        };

        let Some(mapped) = mapped else {
            continue;
        };

        let is_separator = matches!(mapped, '.' | '_' | '-');
        if is_separator && last_was_separator {
            continue;
        }

        output.push(mapped);
        last_was_separator = is_separator;

        if output.len() >= MAX_ATTRIBUTE_KEY_LEN {
            break;
        }
    }

    let output = output.trim_matches(['.', '_', '-']);
    if output.is_empty() {
        None
    } else if output
        .chars()
        .next()
        .is_some_and(|character| character.is_ascii_alphabetic())
    {
        Some(output.to_string())
    } else {
        Some(format!("attr.{output}"))
    }
}

fn sanitize_attribute_value(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }

    if trimmed == REDACTED_SECRET || redact_secrets(trimmed) != trimmed {
        return Some(REDACTED_SECRET.to_string());
    }

    let mut output = String::with_capacity(trimmed.len().min(MAX_ATTRIBUTE_VALUE_LEN));
    let mut last_was_whitespace = false;

    for character in trimmed.chars() {
        let mapped = if character.is_control() {
            ' '
        } else {
            character
        };

        if mapped.is_whitespace() {
            if !last_was_whitespace && !output.is_empty() {
                output.push(' ');
            }
            last_was_whitespace = true;
        } else {
            output.push(mapped);
            last_was_whitespace = false;
        }

        if output.len() >= MAX_ATTRIBUTE_VALUE_LEN {
            break;
        }
    }

    let output = output.trim();
    if output.is_empty() {
        None
    } else {
        Some(output.to_string())
    }
}

fn first_nonempty_env<'a>(vars: &'a BTreeMap<String, String>, keys: &[&str]) -> Option<&'a str> {
    keys.iter().find_map(|key| get_env(vars, key))
}

fn get_env<'a>(vars: &'a BTreeMap<String, String>, key: &str) -> Option<&'a str> {
    vars.get(key)
        .map(String::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
}

fn env_truthy(value: Option<&str>) -> bool {
    value
        .map(|value| {
            matches!(
                value.to_ascii_lowercase().as_str(),
                "1" | "true" | "yes" | "on"
            )
        })
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    const OTEL_EXPORTER_CONTRACT: &str = include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../tests/fixtures/observability/otel_exporter_contract.json"
    ));

    #[test]
    fn default_and_explicit_disabled_are_noop() {
        let default_init = init_otel_exporter(OtelConfig::default()).expect("default config");
        assert_eq!(default_init.exporter(), &OtelExporter::Disabled);
        assert!(!default_init.is_enabled());

        let env_config = OtelConfig::from_env_vars([
            ("AI_GATEWAY_OTEL_EXPORTER", "disabled"),
            (
                "AI_GATEWAY_OTEL_ENDPOINT",
                "https://collector.example.com:4318/v1/traces",
            ),
        ])
        .expect("disabled env config");

        assert_eq!(env_config.exporter(), &OtelExporter::Disabled);
        assert!(!env_config.is_enabled());
    }

    #[test]
    fn unconfigured_env_defaults_to_disabled() {
        let config = OtelConfig::from_env_vars(std::iter::empty::<(&str, &str)>())
            .expect("empty env config");

        assert_eq!(config.exporter(), &OtelExporter::Disabled);
        assert_eq!(config.service_name(), DEFAULT_OTEL_SERVICE_NAME);
    }

    #[test]
    fn stdout_exporter_is_enabled_without_endpoint() {
        let config = OtelConfig::from_env_vars([
            ("OTEL_TRACES_EXPORTER", "console"),
            ("OTEL_SERVICE_NAME", "gateway"),
        ])
        .expect("stdout env config");

        let init = init_otel_exporter(config).expect("stdout init");

        assert_eq!(init.exporter(), &OtelExporter::Stdout);
        assert_eq!(init.service_name(), "gateway");
        assert!(init.is_enabled());
    }

    #[test]
    fn valid_otlp_endpoint_enables_otlp_exporter() {
        let endpoint = "https://collector.example.com:4318/v1/traces";
        let config = OtelConfig::from_env_vars([
            ("AI_GATEWAY_OTEL_EXPORTER", "otlp"),
            ("AI_GATEWAY_OTEL_ENDPOINT", endpoint),
            ("OTEL_SERVICE_NAME", "gateway"),
        ])
        .expect("valid otlp env config");

        assert_eq!(
            config.exporter(),
            &OtelExporter::Otlp {
                endpoint: endpoint.to_string()
            }
        );
        assert_eq!(config.service_name(), "gateway");
        assert!(init_otel_exporter(config).expect("otlp init").is_enabled());
    }

    #[test]
    fn endpoint_without_exporter_selects_otlp() {
        let config = OtelConfig::from_env_vars([(
            "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
            "http://localhost:4318/v1/traces",
        )])
        .expect("endpoint-only otlp config");

        assert_eq!(
            config.exporter(),
            &OtelExporter::Otlp {
                endpoint: "http://localhost:4318/v1/traces".to_string()
            }
        );
    }

    #[test]
    fn otlp_exporter_requires_endpoint() {
        let error = OtelConfig::from_env_vars([("AI_GATEWAY_OTEL_EXPORTER", "otlp")]).unwrap_err();

        assert_eq!(error, OtelConfigError::MissingOtlpEndpoint);
        assert!(error.to_string().contains("requires"));
    }

    #[test]
    fn invalid_otlp_endpoint_returns_clear_error() {
        let error = OtelConfig::from_env_vars([
            ("AI_GATEWAY_OTEL_EXPORTER", "otlp"),
            (
                "AI_GATEWAY_OTEL_ENDPOINT",
                "ftp://collector.example.com:4318",
            ),
        ])
        .unwrap_err();

        assert!(matches!(
            error,
            OtelConfigError::InvalidEndpoint { reason, .. }
                if reason == "scheme must be http or https"
        ));
        assert!(error.to_string().contains("scheme must be http or https"));
    }

    #[test]
    fn invalid_config_errors_do_not_echo_embedded_secret_material() {
        let endpoint_error = OtelConfig::from_env_vars([
            ("AI_GATEWAY_OTEL_EXPORTER", "otlp"),
            (
                "AI_GATEWAY_OTEL_ENDPOINT",
                "https://alice:plain-password@collector.example.com:4318/v1/traces",
            ),
        ])
        .unwrap_err()
        .to_string();

        assert!(!endpoint_error.contains("alice"));
        assert!(!endpoint_error.contains("plain-password"));
        assert!(endpoint_error.contains(REDACTED_SECRET));
        assert!(endpoint_error.contains("collector.example.com"));

        let exporter_error =
            OtelConfig::from_env_vars([("AI_GATEWAY_OTEL_EXPORTER", "sk-live-secret")])
                .unwrap_err()
                .to_string();
        assert!(!exporter_error.contains("sk-live-secret"));
        assert!(exporter_error.contains(REDACTED_SECRET));
    }

    #[test]
    fn service_name_and_resource_attributes_are_sanitized() {
        let config = OtelConfig::new(
            OtelExporter::Stdout,
            " gateway prod!!\n ",
            [
                ("Deployment Environment", "prod\nwest"),
                ("api.token", "sk-live-secret"),
                ("sk-live-secret", "value"),
                ("", "ignored"),
                ("empty.value", ""),
            ],
        )
        .expect("sanitized config");

        let attributes = config.resource_attributes();

        assert_eq!(config.service_name(), "gateway-prod");
        assert_eq!(
            attributes.get("service.name"),
            Some(&"gateway-prod".to_string())
        );
        assert_eq!(
            attributes.get("deployment.environment"),
            Some(&"prod west".to_string())
        );
        assert_eq!(
            attributes.get("api.token"),
            Some(&REDACTED_SECRET.to_string())
        );
        assert!(!attributes.contains_key("sk-live-secret"));
        assert!(!attributes.contains_key("empty.value"));
    }

    #[test]
    fn resource_attribute_service_name_can_set_default_service() {
        let config = OtelConfig::from_env_vars([(
            "OTEL_RESOURCE_ATTRIBUTES",
            "service.name=Gateway Prod, deployment.environment=staging",
        )])
        .expect("resource attributes config");

        assert_eq!(config.service_name(), "Gateway-Prod");
        assert_eq!(
            config.resource_attributes().get("service.name"),
            Some(&"Gateway-Prod".to_string())
        );
    }

    #[test]
    fn otel_exporter_contract_fixture_matches_noop_init_boundary() {
        let fixture: Value =
            serde_json::from_str(OTEL_EXPORTER_CONTRACT).expect("otel exporter contract fixture");

        assert_eq!(fixture["contract"], "otel_exporter_config_noop_v1");
        assert_eq!(fixture["sdk_pipeline_enabled"], false);
        assert_eq!(fixture["network_requests"], "never");

        let exporters = fixture["exporters"]
            .as_array()
            .expect("exporter contract cases");
        assert_eq!(exporters.len(), 3);

        for case in exporters {
            let env = env_pairs(case);
            let expected = &case["expected"];
            let config = OtelConfig::from_env_vars(env).expect("valid exporter config");
            let init = init_otel_exporter(config).expect("noop exporter init");

            assert_eq!(exporter_name(init.exporter()), expected["exporter"]);
            assert_eq!(init.is_enabled(), expected_bool(expected, "enabled"));
            assert_eq!(init.service_name(), expected_str(expected, "service_name"));
            assert_eq!(
                init.sdk_pipeline_enabled(),
                expected_bool(expected, "sdk_pipeline_enabled")
            );

            let expected_endpoint = expected.get("endpoint").and_then(Value::as_str);
            assert_eq!(exporter_endpoint(init.exporter()), expected_endpoint);

            if let Some(expected_attributes) = expected
                .get("resource_attributes")
                .and_then(Value::as_object)
            {
                let actual_attributes = init.resource_attributes();
                assert_eq!(actual_attributes.len(), expected_attributes.len());
                for (key, value) in expected_attributes {
                    assert_eq!(
                        actual_attributes.get(key).map(String::as_str),
                        value.as_str(),
                        "resource attribute {key}"
                    );
                }
            }
        }

        let errors = fixture["errors"].as_array().expect("error contract cases");
        assert_eq!(errors.len(), 3);

        for case in errors {
            let env = env_pairs(case);
            let error = OtelConfig::from_env_vars(env)
                .expect_err("invalid exporter config")
                .to_string();

            for expected in case["expected_error_contains"]
                .as_array()
                .expect("expected error contains")
            {
                let expected = expected.as_str().expect("expected contains string");
                assert!(
                    error.contains(expected),
                    "error `{error}` should contain `{expected}`"
                );
            }

            for excluded in case["expected_error_excludes"]
                .as_array()
                .expect("expected error excludes")
            {
                let excluded = excluded.as_str().expect("expected excludes string");
                assert!(
                    !error.contains(excluded),
                    "error `{error}` should not contain `{excluded}`"
                );
            }
        }

        let boundary = fixture["boundary"].as_array().expect("boundary notes");
        assert!(boundary.iter().any(|note| {
            note.as_str()
                .is_some_and(|note| note.contains("does not install an OpenTelemetry SDK provider"))
        }));
    }

    fn env_pairs(case: &Value) -> Vec<(String, String)> {
        case["env"]
            .as_object()
            .expect("env object")
            .iter()
            .map(|(key, value)| {
                (
                    key.clone(),
                    value.as_str().expect("env value string").to_string(),
                )
            })
            .collect()
    }

    fn expected_str<'a>(expected: &'a Value, key: &str) -> &'a str {
        expected[key].as_str().expect("expected string")
    }

    fn expected_bool(expected: &Value, key: &str) -> bool {
        expected[key].as_bool().expect("expected bool")
    }

    fn exporter_name(exporter: &OtelExporter) -> &'static str {
        match exporter {
            OtelExporter::Disabled => "disabled",
            OtelExporter::Stdout => "stdout",
            OtelExporter::Otlp { .. } => "otlp",
        }
    }

    fn exporter_endpoint(exporter: &OtelExporter) -> Option<&str> {
        match exporter {
            OtelExporter::Otlp { endpoint } => Some(endpoint.as_str()),
            OtelExporter::Disabled | OtelExporter::Stdout => None,
        }
    }
}
