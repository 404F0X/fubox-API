use std::{
    collections::{BTreeMap, BTreeSet},
    fmt,
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
};

use ai_gateway_observability::redact_secrets;
use axum::http::Uri;
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct AlertWebhookDryRunRequest {
    #[serde(default)]
    enabled: bool,
    url: String,
    secret: Option<String>,
    secret_header: Option<String>,
    headers: Option<BTreeMap<String, String>>,
    #[serde(default, alias = "body", alias = "raw_body")]
    payload: Option<Value>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct AlertWebhookValidationError {
    message: String,
}

impl AlertWebhookValidationError {
    fn invalid(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl fmt::Display for AlertWebhookValidationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ValidatedWebhookUrl {
    scheme: String,
    host: String,
    port: Option<u16>,
    redacted_url: String,
    path_redacted: bool,
    query_redacted: bool,
}

pub(crate) fn dry_run_alert_webhook(
    request: AlertWebhookDryRunRequest,
) -> Result<Value, AlertWebhookValidationError> {
    let url = validate_alert_webhook_url(&request.url)?;
    let secret_configured = validate_optional_secret(request.secret.as_deref())?;
    let secret_header = validate_secret_header(request.secret_header.as_deref())?;
    let headers = validate_headers(request.headers.as_ref())?;

    Ok(json!({
        "valid": true,
        "dry_run": true,
        "mode": "validate_only",
        "outbound_call": false,
        "webhook": {
            "enabled": request.enabled,
            "url_redacted": url.redacted_url,
            "scheme": url.scheme,
            "host": url.host,
            "port": url.port,
            "path_redacted": url.path_redacted,
            "query_redacted": url.query_redacted,
            "secret_configured": secret_configured,
            "secret_redacted": secret_configured,
            "secret_header": secret_header,
            "headers_redacted": headers,
            "header_count": headers.len(),
        },
        "payload": payload_summary(request.payload.as_ref()),
        "delivery": {
            "implemented": false,
            "dry_run_only": true,
            "request_body_redacted": true,
            "note": "validation only; no webhook request was sent",
        },
        "ssrf_guard": {
            "https_required": true,
            "localhost_rejected": true,
            "private_literal_ip_rejected": true,
            "link_local_literal_ip_rejected": true,
            "dns_not_resolved": true,
            "dry_run_only": true,
        },
    }))
}

fn validate_alert_webhook_url(
    raw: &str,
) -> Result<ValidatedWebhookUrl, AlertWebhookValidationError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(AlertWebhookValidationError::invalid(
            "webhook url must not be empty",
        ));
    }
    if trimmed.len() > 2048 {
        return Err(AlertWebhookValidationError::invalid(
            "webhook url must be 2048 bytes or fewer",
        ));
    }

    let uri = trimmed.parse::<Uri>().map_err(|_| {
        AlertWebhookValidationError::invalid("webhook url must be an absolute https URL")
    })?;
    if uri.scheme_str() != Some("https") {
        return Err(AlertWebhookValidationError::invalid(
            "webhook url must use https",
        ));
    }

    let authority = uri
        .authority()
        .ok_or_else(|| AlertWebhookValidationError::invalid("webhook url must include a host"))?;
    if authority.as_str().contains('@') {
        return Err(AlertWebhookValidationError::invalid(
            "webhook url must not include userinfo",
        ));
    }

    let host = uri
        .host()
        .map(normalize_host)
        .ok_or_else(|| AlertWebhookValidationError::invalid("webhook url must include a host"))?;
    validate_webhook_host(&host)?;

    let path = uri.path();
    let path_redacted = !path.is_empty() && path != "/";
    let query_redacted = uri.query().is_some();

    Ok(ValidatedWebhookUrl {
        scheme: "https".to_string(),
        redacted_url: redacted_url(&host, uri.port_u16(), path_redacted, query_redacted),
        host,
        port: uri.port_u16(),
        path_redacted,
        query_redacted,
    })
}

fn normalize_host(host: &str) -> String {
    host.trim_matches(['[', ']'])
        .trim_end_matches('.')
        .to_ascii_lowercase()
}

fn validate_webhook_host(host: &str) -> Result<(), AlertWebhookValidationError> {
    if host.is_empty() {
        return Err(AlertWebhookValidationError::invalid(
            "webhook url host must not be empty",
        ));
    }
    if host == "localhost"
        || host.ends_with(".localhost")
        || host.ends_with(".local")
        || host.ends_with(".internal")
    {
        return Err(AlertWebhookValidationError::invalid(
            "webhook url host must be externally routable",
        ));
    }
    if let Ok(ip) = host.parse::<IpAddr>() {
        if is_forbidden_webhook_ip(ip) {
            return Err(AlertWebhookValidationError::invalid(
                "webhook url must not use localhost, private, link-local, multicast, or unspecified IPs",
            ));
        }
        return Ok(());
    }
    if !host.is_ascii() || host.len() > 253 {
        return Err(AlertWebhookValidationError::invalid(
            "webhook url host must be an ASCII DNS name",
        ));
    }

    for label in host.split('.') {
        if label.is_empty() || label.len() > 63 {
            return Err(AlertWebhookValidationError::invalid(
                "webhook url host must be a valid DNS name",
            ));
        }
        let bytes = label.as_bytes();
        if !bytes[0].is_ascii_alphanumeric()
            || !bytes[bytes.len() - 1].is_ascii_alphanumeric()
            || !bytes
                .iter()
                .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'-')
        {
            return Err(AlertWebhookValidationError::invalid(
                "webhook url host must be a valid DNS name",
            ));
        }
    }

    Ok(())
}

fn is_forbidden_webhook_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => {
            ip.is_loopback()
                || ip.is_private()
                || ip.is_link_local()
                || ip.is_unspecified()
                || ip.is_broadcast()
                || ip.is_multicast()
        }
        IpAddr::V6(ip) => {
            ip.is_loopback()
                || ip.is_unspecified()
                || ip.is_multicast()
                || is_unique_local_ipv6(ip)
                || is_link_local_ipv6(ip)
                || ipv4_mapped(ip).is_some_and(|mapped| is_forbidden_webhook_ip(IpAddr::V4(mapped)))
        }
    }
}

fn is_unique_local_ipv6(ip: Ipv6Addr) -> bool {
    ip.segments()[0] & 0xfe00 == 0xfc00
}

fn is_link_local_ipv6(ip: Ipv6Addr) -> bool {
    ip.segments()[0] & 0xffc0 == 0xfe80
}

fn ipv4_mapped(ip: Ipv6Addr) -> Option<Ipv4Addr> {
    let segments = ip.segments();
    if segments[..5] == [0, 0, 0, 0, 0] && segments[5] == 0xffff {
        return Some(Ipv4Addr::new(
            (segments[6] >> 8) as u8,
            segments[6] as u8,
            (segments[7] >> 8) as u8,
            segments[7] as u8,
        ));
    }

    None
}

fn redacted_url(
    host: &str,
    port: Option<u16>,
    path_redacted: bool,
    query_redacted: bool,
) -> String {
    let host = if host.contains(':') {
        format!("[{host}]")
    } else {
        host.to_string()
    };
    let mut redacted = format!("https://{host}");
    if let Some(port) = port {
        redacted.push(':');
        redacted.push_str(&port.to_string());
    }
    if path_redacted {
        redacted.push_str("/[REDACTED_PATH]");
    }
    if query_redacted {
        redacted.push_str("?[REDACTED_QUERY]");
    }
    redacted
}

fn validate_optional_secret(secret: Option<&str>) -> Result<bool, AlertWebhookValidationError> {
    let Some(secret) = secret else {
        return Ok(false);
    };
    if secret.trim().is_empty() {
        return Err(AlertWebhookValidationError::invalid(
            "webhook secret must not be empty when provided",
        ));
    }
    if secret.len() > 4096 || contains_crlf(secret) {
        return Err(AlertWebhookValidationError::invalid(
            "webhook secret must be header-safe and 4096 bytes or fewer",
        ));
    }

    Ok(true)
}

fn validate_secret_header(
    secret_header: Option<&str>,
) -> Result<Option<String>, AlertWebhookValidationError> {
    let Some(secret_header) = secret_header else {
        return Ok(None);
    };
    let secret_header = secret_header.trim();
    validate_header_name(secret_header)?;
    Ok(Some(secret_header.to_string()))
}

fn validate_headers(
    headers: Option<&BTreeMap<String, String>>,
) -> Result<BTreeMap<String, String>, AlertWebhookValidationError> {
    let Some(headers) = headers else {
        return Ok(BTreeMap::new());
    };
    if headers.len() > 32 {
        return Err(AlertWebhookValidationError::invalid(
            "webhook headers must contain 32 entries or fewer",
        ));
    }

    let mut redacted = BTreeMap::new();
    let mut seen = BTreeSet::new();
    for (name, value) in headers {
        let normalized_name = validate_header_name(name)?;
        if is_protected_header(&normalized_name) {
            return Err(AlertWebhookValidationError::invalid(format!(
                "webhook header `{name}` is managed by the server"
            )));
        }
        if !seen.insert(normalized_name.clone()) {
            return Err(AlertWebhookValidationError::invalid(
                "webhook headers must not contain duplicate names",
            ));
        }
        if value.len() > 4096 || contains_crlf(value) {
            return Err(AlertWebhookValidationError::invalid(format!(
                "webhook header `{name}` must be header-safe and 4096 bytes or fewer"
            )));
        }

        let redacted_value = if is_sensitive_header(&normalized_name) {
            "[REDACTED]"
        } else {
            "configured"
        };
        redacted.insert(name.trim().to_string(), redacted_value.to_string());
    }

    Ok(redacted)
}

fn validate_header_name(name: &str) -> Result<String, AlertWebhookValidationError> {
    let name = name.trim();
    if name.is_empty() || name.len() > 128 || !name.bytes().all(is_header_name_byte) {
        return Err(AlertWebhookValidationError::invalid(
            "webhook header names must be valid HTTP header tokens",
        ));
    }
    if redact_secrets(name) != name {
        return Err(AlertWebhookValidationError::invalid(
            "webhook header names must not contain secret material",
        ));
    }

    Ok(name.to_ascii_lowercase())
}

fn is_header_name_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&byte)
}

fn is_protected_header(name: &str) -> bool {
    matches!(
        name,
        "connection"
            | "content-length"
            | "expect"
            | "host"
            | "te"
            | "trailer"
            | "transfer-encoding"
            | "upgrade"
    )
}

fn is_sensitive_header(name: &str) -> bool {
    name == "authorization"
        || name == "cookie"
        || name == "set-cookie"
        || name == "proxy-authorization"
        || name.contains("api-key")
        || name.contains("apikey")
        || name.contains("secret")
        || name.contains("signature")
        || name.contains("token")
}

fn contains_crlf(value: &str) -> bool {
    value.contains('\r') || value.contains('\n')
}

fn payload_summary(payload: Option<&Value>) -> Value {
    let Some(payload) = payload else {
        return json!({
            "provided": false,
            "redacted": true,
        });
    };

    let (kind, top_level_item_count) = match payload {
        Value::Null => ("null", 0),
        Value::Bool(_) => ("boolean", 0),
        Value::Number(_) => ("number", 0),
        Value::String(_) => ("string", 1),
        Value::Array(values) => ("array", values.len()),
        Value::Object(object) => ("object", object.len()),
    };

    json!({
        "provided": true,
        "kind": kind,
        "top_level_item_count": top_level_item_count,
        "redacted": true,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_secure_webhook_config_without_outbound_call() {
        let request = serde_json::from_value(json!({
            "enabled": true,
            "url": "https://hooks.example.com/services/T000/B000/secret-path?token=query-secret",
            "secret": "fixture-webhook-secret",
            "secret_header": "X-Alert-Signature",
            "headers": {
                "Authorization": "Bearer fixture-token",
                "X-Alert-Source": "control-plane"
            },
            "payload": {
                "message": "raw-payload-secret",
                "severity": "critical"
            }
        }))
        .expect("request should deserialize");

        let response = dry_run_alert_webhook(request).expect("config should validate");

        assert_eq!(response["valid"], true);
        assert_eq!(response["dry_run"], true);
        assert_eq!(response["outbound_call"], false);
        assert_eq!(response["webhook"]["enabled"], true);
        assert_eq!(response["webhook"]["secret_configured"], true);
        assert_eq!(response["webhook"]["path_redacted"], true);
        assert_eq!(response["webhook"]["query_redacted"], true);
        assert_eq!(response["payload"]["provided"], true);
        assert_eq!(response["payload"]["redacted"], true);

        let serialized = serde_json::to_string(&response).expect("response should serialize");
        assert!(!serialized.contains("fixture-webhook-secret"));
        assert!(!serialized.contains("fixture-token"));
        assert!(!serialized.contains("raw-payload-secret"));
        assert!(!serialized.contains("secret-path"));
        assert!(!serialized.contains("query-secret"));
    }

    #[test]
    fn rejects_invalid_and_ssrf_prone_urls() {
        for url in [
            "http://hooks.example.com/alert",
            "https://user:pass@hooks.example.com/alert",
            "https://localhost/alert",
            "https://127.0.0.1/alert",
            "https://169.254.169.254/latest/meta-data",
            "https://[fd00::1]/alert",
            "https://[::ffff:127.0.0.1]/alert",
        ] {
            let request = AlertWebhookDryRunRequest {
                enabled: true,
                url: url.to_string(),
                secret: None,
                secret_header: None,
                headers: None,
                payload: None,
            };

            assert!(
                dry_run_alert_webhook(request).is_err(),
                "{url} should be rejected"
            );
        }
    }

    #[test]
    fn redacts_public_ipv6_hosts_as_url_authority() {
        let request = serde_json::from_value(json!({
            "url": "https://[2606:4700:4700::1111]/services/fixture-path-secret?token=fixture-query-secret"
        }))
        .expect("request should deserialize");

        let response = dry_run_alert_webhook(request).expect("public IPv6 URL should validate");

        assert_eq!(
            response["webhook"]["url_redacted"],
            "https://[2606:4700:4700::1111]/[REDACTED_PATH]?[REDACTED_QUERY]"
        );
        let serialized = serde_json::to_string(&response).expect("response should serialize");
        assert!(!serialized.contains("fixture-path-secret"));
        assert!(!serialized.contains("fixture-query-secret"));
    }

    #[test]
    fn redacts_secrets_headers_and_body_alias() {
        let request = serde_json::from_value(json!({
            "url": "https://alerts.example.com/webhook",
            "secret": "top-secret-value",
            "headers": {
                "X-Webhook-Secret": "header-secret-value",
                "X-Trace-Source": "safe-but-still-not-echoed"
            },
            "body": "raw-body-secret-value"
        }))
        .expect("request should deserialize");

        let response = dry_run_alert_webhook(request).expect("config should validate");

        assert_eq!(
            response["webhook"]["headers_redacted"]["X-Webhook-Secret"],
            "[REDACTED]"
        );
        assert_eq!(
            response["webhook"]["headers_redacted"]["X-Trace-Source"],
            "configured"
        );
        assert_eq!(response["payload"]["kind"], "string");

        let serialized = serde_json::to_string(&response).expect("response should serialize");
        assert!(!serialized.contains("top-secret-value"));
        assert!(!serialized.contains("header-secret-value"));
        assert!(!serialized.contains("safe-but-still-not-echoed"));
        assert!(!serialized.contains("raw-body-secret-value"));
    }

    #[test]
    fn rejects_secret_like_header_names_without_echoing_them() {
        let request = serde_json::from_value(json!({
            "url": "https://alerts.example.com/webhook",
            "headers": {
                "sk-live-header-secret": "configured"
            }
        }))
        .expect("request should deserialize");

        let error = dry_run_alert_webhook(request).unwrap_err().to_string();

        assert!(!error.contains("sk-live-header-secret"));
        assert!(error.contains("header names"));
        assert!(error.contains("secret material"));
    }

    #[test]
    fn contract_fixture_stays_secret_safe() {
        let fixture = serde_json::from_str::<Value>(include_str!(
            "../../../tests/fixtures/control-plane/alert_webhook_contract.json"
        ))
        .expect("fixture should parse");
        assert_eq!(fixture["endpoint"]["path"], "/admin/alerts/webhook/dry-run");
        assert_eq!(fixture["security"]["viewer_allowed"], false);

        let request = serde_json::from_value(fixture["examples"]["valid"]["request"].clone())
            .expect("fixture request should deserialize");
        let response = dry_run_alert_webhook(request).expect("fixture request should validate");

        assert_eq!(response["outbound_call"], false);
        let serialized = serde_json::to_string(&response).expect("response should serialize");
        assert!(!serialized.contains("fixture-webhook-secret"));
        assert!(!serialized.contains("fixture-authorization-token"));
        assert!(!serialized.contains("fixture-raw-body-secret"));
    }
}
