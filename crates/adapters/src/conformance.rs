use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::{Path, PathBuf},
};

use serde_json::{Value, json};

const ADAPTERS: [&str; 4] = ["openai", "anthropic", "gemini", "mcp"];

#[derive(Clone, Copy, Default)]
struct AdapterCounts {
    json: usize,
    valid: usize,
    error: usize,
    stream: usize,
    sse: usize,
}

#[test]
fn adapter_fixture_conformance_harness_covers_fixture_set() {
    let root = fixture_root();
    let mut failures = Vec::new();
    let mut seen_names = BTreeMap::<String, String>::new();
    let mut counts_by_adapter = BTreeMap::<&str, AdapterCounts>::new();

    for adapter in ADAPTERS {
        let adapter_dir = root.join(adapter);
        if !adapter_dir.is_dir() {
            failures.push(format!("{adapter}: fixture directory is missing"));
            continue;
        }

        let mut counts = AdapterCounts::default();

        for path in json_fixture_paths(&adapter_dir, &mut failures) {
            counts.json += 1;
            let label = fixture_label(&root, &path);
            let contents = match fs::read_to_string(&path) {
                Ok(contents) => contents,
                Err(error) => {
                    failures.push(format!("{label}: failed to read JSON fixture: {error}"));
                    continue;
                }
            };

            let fixture: Value = match serde_json::from_str(&contents) {
                Ok(fixture) => fixture,
                Err(error) => {
                    failures.push(format!("{label}: invalid JSON fixture: {error}"));
                    continue;
                }
            };

            assert_no_secret_like_strings(&fixture, &label, &mut failures);
            validate_json_fixture(
                adapter,
                &label,
                &fixture,
                &mut seen_names,
                &mut counts,
                &mut failures,
            );
        }

        for path in sse_fixture_paths(&adapter_dir, &mut failures) {
            counts.stream += 1;
            counts.sse += 1;
            let label = fixture_label(&root, &path);
            let contents = match fs::read_to_string(&path) {
                Ok(contents) => contents,
                Err(error) => {
                    failures.push(format!("{label}: failed to read SSE fixture: {error}"));
                    continue;
                }
            };

            if contents.trim().is_empty() {
                failures.push(format!("{label}: SSE fixture must not be empty"));
            }
            assert_no_secret_like_text(&contents, &label, &mut failures);
        }

        if counts.json == 0 {
            failures.push(format!("{adapter}: no JSON fixtures found"));
        }
        if counts.valid == 0 {
            failures.push(format!("{adapter}: missing valid fixture"));
        }
        if counts.error == 0 {
            failures.push(format!("{adapter}: missing error fixture"));
        }
        if counts.stream == 0 {
            failures.push(format!("{adapter}: missing stream fixture"));
        }

        counts_by_adapter.insert(adapter, counts);
    }

    if !failures.is_empty() {
        panic!("{}", format_failure_report(&failures, &counts_by_adapter));
    }

    assert_eq!(
        counts_by_adapter.len(),
        ADAPTERS.len(),
        "all adapter fixture directories should be checked"
    );
}

#[test]
fn adapter_fixture_conformance_contract_self_tests_cover_fixture_types_and_failures() {
    let mut failures = Vec::new();
    let mut seen_names = BTreeMap::<String, String>::new();
    let mut counts = AdapterCounts::default();

    let valid_fixture = json!({
        "name": "adapter_conformance_self_valid",
        "request": {},
        "expected_upstream": {
            "method": "POST",
            "path": "/v1/mock",
            "stream": false,
            "body": {}
        },
        "response": {
            "status": 200,
            "body": {}
        },
        "expected_usage": null
    });
    let error_fixture = json!({
        "name": "adapter_conformance_self_error",
        "response": {
            "status": 429,
            "body": {}
        },
        "expected_error_mapping": {
            "http_status": 429,
            "error_type": "provider_error",
            "code": "provider_429",
            "owner": "provider",
            "stage": "provider_call",
            "retryable": true
        }
    });
    let stream_fixture = json!({
        "name": "adapter_conformance_self_stream",
        "event": {
            "type": "chunk"
        },
        "expected_event": {
            "type": "chunk"
        }
    });

    validate_json_fixture(
        "openai",
        "self/valid.json",
        &valid_fixture,
        &mut seen_names,
        &mut counts,
        &mut failures,
    );
    validate_json_fixture(
        "openai",
        "self/error.json",
        &error_fixture,
        &mut seen_names,
        &mut counts,
        &mut failures,
    );
    validate_json_fixture(
        "openai",
        "self/stream.json",
        &stream_fixture,
        &mut seen_names,
        &mut counts,
        &mut failures,
    );

    assert!(
        failures.is_empty(),
        "valid/error/stream self-test fixtures should pass: {failures:?}"
    );
    assert_eq!(counts.valid, 1);
    assert_eq!(counts.error, 1);
    assert_eq!(counts.stream, 1);

    let mut secret_failures = Vec::new();
    assert_no_secret_like_strings(
        &json!({
            "name": "adapter_conformance_self_secret",
            "sample": "sk-abcdef1234567890"
        }),
        "self/secret.json",
        &mut secret_failures,
    );
    assert!(
        secret_failures
            .iter()
            .any(|failure| failure.contains("provider key prefix")),
        "secret-like provider key prefix should be detected: {secret_failures:?}"
    );

    let mut incomplete_failures = Vec::new();
    validate_json_fixture(
        "openai",
        "self/incomplete.json",
        &json!({
            "name": "adapter_conformance_self_incomplete",
            "request": {}
        }),
        &mut BTreeMap::new(),
        &mut AdapterCounts::default(),
        &mut incomplete_failures,
    );
    assert!(
        incomplete_failures
            .iter()
            .any(|failure| failure.contains("incomplete valid fixture contract fields")),
        "incomplete valid contract should be detected: {incomplete_failures:?}"
    );
}

fn format_failure_report(
    failures: &[String],
    counts_by_adapter: &BTreeMap<&str, AdapterCounts>,
) -> String {
    let mut report = String::from("adapter fixture conformance failed");
    report.push_str("\ncoverage:");
    for adapter in ADAPTERS {
        if let Some(counts) = counts_by_adapter.get(adapter) {
            report.push_str(&format!(
                "\n- {adapter}: json={} valid={} error={} stream={} sse={}",
                counts.json, counts.valid, counts.error, counts.stream, counts.sse
            ));
        } else {
            report.push_str(&format!("\n- {adapter}: missing"));
        }
    }
    report.push_str("\nfailures:\n- ");
    report.push_str(&failures.join("\n- "));
    report
}

fn validate_json_fixture(
    adapter: &str,
    label: &str,
    fixture: &Value,
    seen_names: &mut BTreeMap<String, String>,
    counts: &mut AdapterCounts,
    failures: &mut Vec<String>,
) {
    let Some(object) = fixture.as_object() else {
        failures.push(format!("{label}: fixture root must be a JSON object"));
        return;
    };

    let Some(name) = object
        .get("name")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|name| !name.is_empty())
    else {
        failures.push(format!("{label}: fixture name must be a non-empty string"));
        return;
    };

    if !name
        .bytes()
        .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
    {
        failures.push(format!(
            "{label}: fixture name '{name}' must be a lowercase snake_case slug"
        ));
    }

    if let Some(previous) = seen_names.insert(name.to_string(), label.to_string()) {
        failures.push(format!(
            "{label}: fixture name '{name}' duplicates {previous}"
        ));
    }

    let has_valid_contract = ["request", "expected_upstream", "response", "expected_usage"]
        .iter()
        .all(|field| object.contains_key(*field));
    let has_error_mapping = object.contains_key("expected_error_mapping");
    let has_stream_event = object.contains_key("event") && object.contains_key("expected_event");

    if has_valid_contract {
        counts.valid += 1;
        require_object_field(object, "request", label, failures);
        validate_expected_upstream(object, label, failures);
        validate_response(object, label, failures);
        validate_expected_usage(object, label, failures);
    }

    if has_error_mapping {
        counts.error += 1;
        if !(object.contains_key("request") || object.contains_key("response")) {
            failures.push(format!(
                "{label}: error fixture must include request or response"
            ));
        }
        if object.contains_key("response") {
            validate_response(object, label, failures);
        }
        validate_expected_error_mapping(object, label, failures);
    }

    if has_stream_event || name.contains("stream") {
        counts.stream += 1;
    }
    if has_stream_event {
        if object.get("event").is_none_or(Value::is_null) {
            failures.push(format!("{label}: stream fixture event must not be null"));
        }
        if object.get("expected_event").is_none_or(Value::is_null) {
            failures.push(format!(
                "{label}: stream fixture expected_event must not be null"
            ));
        }
    }

    if !has_valid_contract && !has_error_mapping && !has_stream_event {
        failures.push(format!(
            "{label}: {adapter} fixture must declare either request/expected_upstream/response/expected_usage, expected_error_mapping, or event/expected_event"
        ));
    }

    if has_valid_contract && has_error_mapping {
        failures.push(format!(
            "{label}: fixture should not be both a valid response contract and an error mapping"
        ));
    }

    let partial_valid_fields = ["request", "expected_upstream", "response", "expected_usage"]
        .into_iter()
        .filter(|field| object.contains_key(*field))
        .collect::<BTreeSet<_>>();
    if !partial_valid_fields.is_empty()
        && !has_valid_contract
        && !has_error_mapping
        && !has_stream_event
    {
        failures.push(format!(
            "{label}: incomplete valid fixture contract fields: {partial_valid_fields:?}"
        ));
    }
}

fn validate_expected_upstream(
    object: &serde_json::Map<String, Value>,
    label: &str,
    failures: &mut Vec<String>,
) {
    let Some(upstream) = object.get("expected_upstream").and_then(Value::as_object) else {
        failures.push(format!("{label}: expected_upstream must be an object"));
        return;
    };

    require_string(upstream, "method", label, "expected_upstream", failures);
    require_string(upstream, "path", label, "expected_upstream", failures);
    require_bool(upstream, "stream", label, "expected_upstream", failures);
    if !upstream.contains_key("body") {
        failures.push(format!("{label}: expected_upstream.body is required"));
    }
}

fn validate_response(
    object: &serde_json::Map<String, Value>,
    label: &str,
    failures: &mut Vec<String>,
) {
    let Some(response) = object.get("response").and_then(Value::as_object) else {
        failures.push(format!("{label}: response must be an object"));
        return;
    };

    let valid_status = response
        .get("status")
        .and_then(Value::as_u64)
        .is_some_and(|status| status <= u16::MAX as u64);
    if !valid_status {
        failures.push(format!("{label}: response.status must be a u16 number"));
    }
    if !response.contains_key("body") {
        failures.push(format!("{label}: response.body is required"));
    }
}

fn validate_expected_usage(
    object: &serde_json::Map<String, Value>,
    label: &str,
    failures: &mut Vec<String>,
) {
    if !object
        .get("expected_usage")
        .is_some_and(|usage| usage.is_object() || usage.is_null())
    {
        failures.push(format!("{label}: expected_usage must be an object or null"));
    }
}

fn validate_expected_error_mapping(
    object: &serde_json::Map<String, Value>,
    label: &str,
    failures: &mut Vec<String>,
) {
    let Some(mapping) = object
        .get("expected_error_mapping")
        .and_then(Value::as_object)
    else {
        failures.push(format!("{label}: expected_error_mapping must be an object"));
        return;
    };

    let valid_status = mapping
        .get("http_status")
        .and_then(Value::as_u64)
        .is_some_and(|status| status <= u16::MAX as u64);
    if !valid_status {
        failures.push(format!(
            "{label}: expected_error_mapping.http_status must be a u16 number"
        ));
    }

    for field in ["error_type", "code", "owner", "stage"] {
        require_string(mapping, field, label, "expected_error_mapping", failures);
    }

    if let Some(retryable) = mapping.get("retryable")
        && !retryable.is_boolean()
    {
        failures.push(format!(
            "{label}: expected_error_mapping.retryable must be a boolean"
        ));
    }
}

fn require_object_field(
    object: &serde_json::Map<String, Value>,
    field: &str,
    label: &str,
    failures: &mut Vec<String>,
) {
    if !object.get(field).is_some_and(Value::is_object) {
        failures.push(format!("{label}: {field} must be an object"));
    }
}

fn require_string(
    object: &serde_json::Map<String, Value>,
    field: &str,
    label: &str,
    parent: &str,
    failures: &mut Vec<String>,
) {
    if object
        .get(field)
        .and_then(Value::as_str)
        .is_none_or(|value| value.trim().is_empty())
    {
        failures.push(format!("{label}: {parent}.{field} must be a string"));
    }
}

fn require_bool(
    object: &serde_json::Map<String, Value>,
    field: &str,
    label: &str,
    parent: &str,
    failures: &mut Vec<String>,
) {
    if !object.get(field).is_some_and(Value::is_boolean) {
        failures.push(format!("{label}: {parent}.{field} must be a boolean"));
    }
}

fn assert_no_secret_like_strings(value: &Value, label: &str, failures: &mut Vec<String>) {
    match value {
        Value::String(text) => assert_no_secret_like_text(text, label, failures),
        Value::Array(values) => {
            for value in values {
                assert_no_secret_like_strings(value, label, failures);
            }
        }
        Value::Object(values) => {
            for value in values.values() {
                assert_no_secret_like_strings(value, label, failures);
            }
        }
        Value::Null | Value::Bool(_) | Value::Number(_) => {}
    }
}

fn assert_no_secret_like_text(text: &str, label: &str, failures: &mut Vec<String>) {
    if text.contains("-----BEGIN") && text.contains("PRIVATE KEY") {
        failures.push(format!("{label}: contains private key marker"));
    }
    if contains_bearer_token(text) {
        failures.push(format!(
            "{label}: contains secret-like value (bearer token)"
        ));
    }

    for token in text.split(|byte: char| {
        byte.is_whitespace()
            || matches!(
                byte,
                '"' | '\'' | ',' | ':' | ';' | '{' | '}' | '[' | ']' | '(' | ')'
            )
    }) {
        let token = token.trim();
        if token.is_empty() {
            continue;
        }

        if let Some(reason) = secret_like_reason(token) {
            failures.push(format!("{label}: contains secret-like value ({reason})"));
        }
    }
}

fn secret_like_reason(token: &str) -> Option<&'static str> {
    if token.starts_with("sk-") && token.len() >= 12 {
        return Some("provider key prefix");
    }
    if token.starts_with("AIza") && token.len() >= 20 {
        return Some("google api key prefix");
    }
    if ["ghp_", "gho_", "ghu_", "ghs_", "ghr_"]
        .iter()
        .any(|prefix| token.starts_with(prefix))
        && token.len() >= 20
    {
        return Some("github token prefix");
    }
    if ["xoxb-", "xoxa-", "xoxp-", "xoxr-", "xoxs-"]
        .iter()
        .any(|prefix| token.starts_with(prefix))
        && token.len() >= 20
    {
        return Some("slack token prefix");
    }
    if token.starts_with("Bearer") && token.len() >= 20 {
        return Some("bearer token");
    }
    if looks_like_jwt(token) {
        return Some("jwt");
    }

    None
}

fn contains_bearer_token(text: &str) -> bool {
    let mut remaining = text;
    while let Some(index) = remaining.find("Bearer ") {
        let token_start = index + "Bearer ".len();
        let after_bearer = &remaining[token_start..];
        let token = after_bearer
            .split(|byte: char| byte.is_whitespace() || matches!(byte, '"' | '\'' | ',' | ';'))
            .next()
            .unwrap_or_default();

        if token.len() >= 16 && token.bytes().all(is_bearer_token_byte) {
            return true;
        }

        remaining = after_bearer;
    }

    false
}

fn is_bearer_token_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'~' | b'+' | b'/' | b'=' | b'-')
}

fn looks_like_jwt(token: &str) -> bool {
    let mut parts = token.split('.');
    let Some(header) = parts.next() else {
        return false;
    };
    let Some(payload) = parts.next() else {
        return false;
    };
    let Some(signature) = parts.next() else {
        return false;
    };
    parts.next().is_none()
        && header.len() >= 10
        && payload.len() >= 10
        && signature.len() >= 10
        && [header, payload, signature]
            .iter()
            .all(|part| part.bytes().all(is_base64_url_byte))
}

fn is_base64_url_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_')
}

fn fixture_root() -> PathBuf {
    let mut path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    path.pop();
    path.pop();
    path.push("tests");
    path.push("fixtures");
    path.push("adapters");
    path
}

fn json_fixture_paths(adapter_dir: &Path, failures: &mut Vec<String>) -> Vec<PathBuf> {
    let mut paths = Vec::new();
    let entries = match fs::read_dir(adapter_dir) {
        Ok(entries) => entries,
        Err(error) => {
            failures.push(format!(
                "{}: failed to read fixture directory: {error}",
                adapter_dir.display()
            ));
            return paths;
        }
    };

    for entry in entries {
        let entry = match entry {
            Ok(entry) => entry,
            Err(error) => {
                failures.push(format!(
                    "{}: failed to read fixture directory entry: {error}",
                    adapter_dir.display()
                ));
                continue;
            }
        };
        let path = entry.path();
        if path.is_file()
            && path
                .extension()
                .is_some_and(|extension| extension == "json")
        {
            paths.push(path);
        }
    }

    paths.sort();
    paths
}

fn sse_fixture_paths(adapter_dir: &Path, failures: &mut Vec<String>) -> Vec<PathBuf> {
    let mut paths = Vec::new();
    collect_sse_fixture_paths(adapter_dir, &mut paths, failures);
    paths.sort();
    paths
}

fn collect_sse_fixture_paths(
    directory: &Path,
    paths: &mut Vec<PathBuf>,
    failures: &mut Vec<String>,
) {
    let entries = match fs::read_dir(directory) {
        Ok(entries) => entries,
        Err(error) => {
            failures.push(format!(
                "{}: failed to read fixture directory: {error}",
                directory.display()
            ));
            return;
        }
    };

    for entry in entries {
        let entry = match entry {
            Ok(entry) => entry,
            Err(error) => {
                failures.push(format!(
                    "{}: failed to read fixture directory entry: {error}",
                    directory.display()
                ));
                continue;
            }
        };
        let path = entry.path();
        if path.is_dir() {
            collect_sse_fixture_paths(&path, paths, failures);
        } else if path.extension().is_some_and(|extension| extension == "sse") {
            paths.push(path);
        }
    }
}

fn fixture_label(root: &Path, path: &Path) -> String {
    path.strip_prefix(root)
        .unwrap_or(path)
        .display()
        .to_string()
        .replace('\\', "/")
}
