use ai_gateway_observability::{PayloadPolicy, payload_sha256_hex};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{collections::BTreeSet, fs};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PromptEvalShadowMode {
    DryRun,
    Execute,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum PromptEvalShadowInputSource {
    InputJson { path: String },
}

#[derive(Debug, Clone, Deserialize)]
pub(crate) struct PromptEvalShadowInput {
    #[serde(default)]
    tenant_id: Option<Uuid>,
    #[serde(default)]
    registry: PromptRegistryInput,
    #[serde(default)]
    dataset: EvalDatasetInput,
    #[serde(default)]
    payload_policy: PayloadPolicyInput,
    #[serde(default)]
    shadow_traffic: ShadowTrafficInput,
}

#[derive(Debug, Clone, Default, Deserialize)]
struct PromptRegistryInput {
    #[serde(default, alias = "id", alias = "registry_item_id", alias = "prompt_id")]
    item_id: Option<String>,
    #[serde(default, alias = "prompt_version")]
    version: Option<String>,
    #[serde(
        default,
        alias = "template",
        alias = "prompt_template",
        alias = "body",
        alias = "messages"
    )]
    prompt: Option<Value>,
    #[serde(default, alias = "hash", alias = "prompt_hash", alias = "hash_sha256")]
    content_hash: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
struct EvalDatasetInput {
    #[serde(default, alias = "id")]
    dataset_id: Option<String>,
    #[serde(default, alias = "dataset_version")]
    version: Option<String>,
    #[serde(default)]
    payload_policy: PayloadPolicyInput,
    #[serde(default, alias = "eval_samples")]
    samples: Vec<Value>,
}

#[derive(Debug, Clone, Default, Deserialize)]
struct PayloadPolicyInput {
    #[serde(default, alias = "id")]
    policy_id: Option<String>,
    #[serde(default, alias = "mode", alias = "storage_mode")]
    policy: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
struct ShadowTrafficInput {
    #[serde(default)]
    enabled: Option<bool>,
    #[serde(default, alias = "percent")]
    percentage: Option<f64>,
    #[serde(default)]
    candidate_route_labels: Vec<String>,
    #[serde(default, alias = "candidate_routes", alias = "routes")]
    routes: Vec<ShadowRouteInput>,
}

#[derive(Debug, Clone, Default, Deserialize)]
struct ShadowRouteInput {
    #[serde(default, alias = "route_label", alias = "name", alias = "id")]
    label: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub(crate) struct PromptEvalShadowPlan {
    schema_version: &'static str,
    dry_run: bool,
    mode: &'static str,
    read_only: bool,
    gateway_runtime_connected: bool,
    db_writes: bool,
    object_store_writes: bool,
    outbound_calls: bool,
    would_write: bool,
    would_send: bool,
    tenant_id: Uuid,
    source: PromptEvalShadowSourceReport,
    registry: PromptRegistryPlan,
    dataset: EvalDatasetPlan,
    payload_policy: SafePayloadPolicyPlan,
    shadow_traffic: ShadowTrafficPlan,
    contract: PromptEvalShadowContractReport,
    remaining_gaps: Vec<&'static str>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct PromptEvalShadowSourceReport {
    kind: &'static str,
    input_path: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct PromptRegistryPlan {
    item_id: String,
    version: String,
    hash_sha256: String,
    would_write: bool,
    source_material_output: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct EvalDatasetPlan {
    dataset_id: String,
    version: String,
    sample_count: usize,
    sample_hashes: Vec<EvalSampleHashPlan>,
    would_write: bool,
    object_store_write: bool,
    source_material_output: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct EvalSampleHashPlan {
    sample_id: Option<String>,
    hash_sha256: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct SafePayloadPolicyPlan {
    policy_id: Option<String>,
    requested_policy: String,
    requested_policy_recognized: bool,
    effective_policy: &'static str,
    unsafe_policy_downgraded: bool,
    raw_payload_storage: bool,
    raw_payload_output: bool,
    hash_only_when_material_needed: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct ShadowTrafficPlan {
    enabled: bool,
    percentage: f64,
    candidate_route_count: usize,
    candidate_route_labels: Vec<String>,
    gateway_dispatch_supported: bool,
    would_dispatch: bool,
    would_send: bool,
    outbound_call: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct PromptEvalShadowContractReport {
    stable_fields: Vec<&'static str>,
    source_material_omitted: bool,
    payload_body_omitted: bool,
    credential_material_omitted: bool,
    header_material_omitted: bool,
    registry_hash_only: bool,
    dataset_hash_or_count_only: bool,
}

pub(crate) fn read_prompt_eval_shadow_input(
    input_path: Option<&str>,
) -> Result<(PromptEvalShadowInputSource, PromptEvalShadowInput), String> {
    let Some(path) = input_path else {
        return Err(
            "prompt-eval-shadow dry-run requires --input <json>; DB/object-store/Gateway reads are future work"
                .to_string(),
        );
    };

    let body = fs::read_to_string(path).map_err(|error| {
        format!(
            "failed to read prompt eval shadow input `{}`: {}",
            super::safe_plan_text(path),
            super::safe_error_text(&error.to_string())
        )
    })?;
    let input = prompt_eval_shadow_input_from_json_str(&body)?;

    Ok((
        PromptEvalShadowInputSource::InputJson {
            path: path.to_string(),
        },
        input,
    ))
}

pub(crate) fn prompt_eval_shadow_input_from_json_str(
    body: &str,
) -> Result<PromptEvalShadowInput, String> {
    let value = serde_json::from_str::<Value>(body).map_err(|error| {
        format!(
            "prompt eval shadow input must be valid JSON: {}",
            super::safe_error_text(&error.to_string())
        )
    })?;
    let input = value.get("input").cloned().unwrap_or(value);
    serde_json::from_value::<PromptEvalShadowInput>(input).map_err(|error| {
        format!(
            "prompt eval shadow input shape is invalid: {}",
            super::safe_error_text(&error.to_string())
        )
    })
}

pub(crate) fn prompt_eval_shadow_plan(
    tenant_id_override: Option<Uuid>,
    source: PromptEvalShadowInputSource,
    input: PromptEvalShadowInput,
) -> Result<PromptEvalShadowPlan, String> {
    let tenant_id = tenant_id_override
        .or(input.tenant_id)
        .unwrap_or(super::DEFAULT_TENANT_ID);
    let registry = registry_plan(input.registry)?;
    let payload_policy = payload_policy_plan(resolve_payload_policy_input(
        input.payload_policy,
        input.dataset.payload_policy.clone(),
    ));
    let dataset = dataset_plan(input.dataset)?;
    let shadow_traffic = shadow_traffic_plan(input.shadow_traffic)?;
    let source = match source {
        PromptEvalShadowInputSource::InputJson { path } => PromptEvalShadowSourceReport {
            kind: "input_json",
            input_path: super::safe_plan_text(&path),
        },
    };

    Ok(PromptEvalShadowPlan {
        schema_version: "prompt_eval_shadow_plan.v1",
        dry_run: true,
        mode: "plan_only",
        read_only: true,
        gateway_runtime_connected: false,
        db_writes: false,
        object_store_writes: false,
        outbound_calls: false,
        would_write: false,
        would_send: false,
        tenant_id,
        source,
        registry,
        dataset,
        payload_policy,
        shadow_traffic,
        contract: PromptEvalShadowContractReport {
            stable_fields: vec![
                "schema_version",
                "dry_run",
                "mode",
                "registry.item_id",
                "registry.version",
                "registry.hash_sha256",
                "dataset.dataset_id",
                "dataset.version",
                "dataset.sample_count",
                "payload_policy.effective_policy",
                "shadow_traffic.percentage",
                "shadow_traffic.candidate_route_labels",
                "would_write",
                "would_send",
            ],
            source_material_omitted: true,
            payload_body_omitted: true,
            credential_material_omitted: true,
            header_material_omitted: true,
            registry_hash_only: true,
            dataset_hash_or_count_only: true,
        },
        remaining_gaps: vec![
            "real_prompt_registry_db",
            "eval_dataset_object_store",
            "gateway_runtime_shadow_dispatch",
            "shadow_result_persistence",
        ],
    })
}

fn registry_plan(input: PromptRegistryInput) -> Result<PromptRegistryPlan, String> {
    let item_id = required_public_text(input.item_id.as_deref(), "registry item_id")?;
    let version = required_public_text(input.version.as_deref(), "registry version")?;
    let hash_sha256 = match input.prompt.as_ref() {
        Some(value) => hash_value(value),
        None => normalize_sha256(input.content_hash.as_deref().ok_or_else(|| {
            "prompt registry input requires prompt/template material or hash_sha256".to_string()
        })?)?,
    };

    Ok(PromptRegistryPlan {
        item_id,
        version,
        hash_sha256,
        would_write: false,
        source_material_output: false,
    })
}

fn dataset_plan(input: EvalDatasetInput) -> Result<EvalDatasetPlan, String> {
    let dataset_id = required_public_text(input.dataset_id.as_deref(), "dataset_id")?;
    let version = required_public_text(input.version.as_deref(), "dataset version")?;
    let sample_hashes = input
        .samples
        .iter()
        .map(|sample| EvalSampleHashPlan {
            sample_id: sample_id(sample),
            hash_sha256: hash_value(sample),
        })
        .collect::<Vec<_>>();

    Ok(EvalDatasetPlan {
        dataset_id,
        version,
        sample_count: sample_hashes.len(),
        sample_hashes,
        would_write: false,
        object_store_write: false,
        source_material_output: false,
    })
}

fn payload_policy_plan(input: PayloadPolicyInput) -> SafePayloadPolicyPlan {
    let requested_raw = input.policy.as_deref().unwrap_or("metadata_only");
    let requested_policy = safe_public_text(requested_raw);
    let parsed = PayloadPolicy::parse(requested_raw);
    let effective_policy = match parsed {
        Some(PayloadPolicy::MetadataOnly) => "metadata_only",
        _ => "hash",
    };

    SafePayloadPolicyPlan {
        policy_id: input.policy_id.as_deref().map(safe_public_text),
        requested_policy,
        requested_policy_recognized: parsed.is_some(),
        effective_policy,
        unsafe_policy_downgraded: parsed.is_some_and(|policy| {
            !matches!(policy, PayloadPolicy::MetadataOnly | PayloadPolicy::Hash)
        }),
        raw_payload_storage: false,
        raw_payload_output: false,
        hash_only_when_material_needed: true,
    }
}

fn shadow_traffic_plan(input: ShadowTrafficInput) -> Result<ShadowTrafficPlan, String> {
    let percentage = input.percentage.unwrap_or(0.0);
    if !percentage.is_finite() || !(0.0..=100.0).contains(&percentage) {
        return Err("shadow traffic percentage must be between 0 and 100".to_string());
    }

    let mut seen = BTreeSet::new();
    let mut candidate_route_labels = Vec::new();
    for label in input
        .candidate_route_labels
        .into_iter()
        .chain(input.routes.into_iter().filter_map(|route| route.label))
    {
        let label = safe_public_text(&label);
        if seen.insert(label.clone()) {
            candidate_route_labels.push(label);
        }
    }
    let enabled = input.enabled.unwrap_or(percentage > 0.0);

    Ok(ShadowTrafficPlan {
        enabled,
        percentage,
        candidate_route_count: candidate_route_labels.len(),
        candidate_route_labels,
        gateway_dispatch_supported: false,
        would_dispatch: false,
        would_send: false,
        outbound_call: false,
    })
}

fn resolve_payload_policy_input(
    top_level: PayloadPolicyInput,
    dataset_level: PayloadPolicyInput,
) -> PayloadPolicyInput {
    if dataset_level.policy.is_some() || dataset_level.policy_id.is_some() {
        dataset_level
    } else {
        top_level
    }
}

fn sample_id(sample: &Value) -> Option<String> {
    sample
        .get("sample_id")
        .or_else(|| sample.get("id"))
        .and_then(Value::as_str)
        .map(safe_public_text)
}

fn hash_value(value: &Value) -> String {
    let bytes = match value {
        Value::String(value) => value.as_bytes().to_vec(),
        _ => serde_json::to_vec(value).unwrap_or_else(|_| value.to_string().into_bytes()),
    };

    format!("sha256:{}", payload_sha256_hex(&bytes))
}

fn normalize_sha256(value: &str) -> Result<String, String> {
    let digest = value.trim().strip_prefix("sha256:").unwrap_or(value.trim());
    if digest.len() == 64
        && digest
            .chars()
            .all(|character| character.is_ascii_hexdigit())
    {
        Ok(format!("sha256:{}", digest.to_ascii_lowercase()))
    } else {
        Err("hash_sha256 must be a sha256 digest".to_string())
    }
}

fn required_public_text(value: Option<&str>, label: &str) -> Result<String, String> {
    let Some(value) = value else {
        return Err(format!("prompt eval shadow input requires {label}"));
    };
    let value = safe_public_text(value);
    if value.is_empty() {
        return Err(format!("prompt eval shadow input requires {label}"));
    }

    Ok(value)
}

fn safe_public_text(value: &str) -> String {
    let sanitized = super::safe_plan_text(value);
    if contains_forbidden_material(&sanitized) {
        "[REDACTED]".to_string()
    } else {
        sanitized
    }
}

fn contains_forbidden_material(value: &str) -> bool {
    let normalized = value.to_ascii_lowercase();
    normalized.contains("authorization")
        || normalized.contains("bearer")
        || normalized.contains("provider_key")
        || normalized.contains("provider key")
        || normalized.contains("api_key")
        || normalized.contains("apikey")
        || normalized.contains("token")
        || normalized.contains("secret")
        || normalized.contains("credential")
}

pub(crate) fn prompt_eval_shadow_execute_error(force: bool) -> String {
    if force {
        return "prompt-eval-shadow execute/send is not implemented in this dry-run slice; no DB write, object-store write, Gateway dispatch, or shadow request was sent"
            .to_string();
    }

    "prompt-eval-shadow execute/send requires --force and is not implemented in this dry-run slice; no DB write, object-store write, Gateway dispatch, or shadow request was sent"
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    const TENANT_ID: Uuid = Uuid::from_u128(0x00000000_0000_0000_0000_000000000001);

    #[test]
    fn fixture_builds_plan_only_registry_dataset_shadow_contract() {
        let fixture = fixture();
        let input = prompt_eval_shadow_input_from_json_str(include_str!(
            "../../../tests/fixtures/worker/prompt_eval_shadow_plan_contract.json"
        ))
        .expect("fixture should parse");

        let plan = prompt_eval_shadow_plan(
            None,
            PromptEvalShadowInputSource::InputJson {
                path: "tests/fixtures/worker/prompt_eval_shadow_plan_contract.json".to_string(),
            },
            input,
        )
        .expect("plan should build");

        assert_eq!(plan.schema_version, "prompt_eval_shadow_plan.v1");
        assert!(plan.dry_run);
        assert!(plan.read_only);
        assert!(!plan.gateway_runtime_connected);
        assert!(!plan.db_writes);
        assert!(!plan.object_store_writes);
        assert!(!plan.outbound_calls);
        assert!(!plan.would_write);
        assert!(!plan.would_send);
        assert_eq!(plan.tenant_id, TENANT_ID);
        assert_eq!(
            plan.registry.item_id,
            fixture["expected_output_contract"]["registry"]["item_id"]
                .as_str()
                .unwrap()
        );
        assert_eq!(plan.registry.version, "2026-06-03.1");
        assert!(plan.registry.hash_sha256.starts_with("sha256:"));
        assert_eq!(plan.registry.hash_sha256.len(), 71);
        assert!(!plan.registry.would_write);
        assert!(!plan.registry.source_material_output);
        assert_eq!(plan.dataset.dataset_id, "eval.customer_support.summary");
        assert_eq!(plan.dataset.version, "2026-06-03.1");
        assert_eq!(plan.dataset.sample_count, 2);
        assert_eq!(plan.dataset.sample_hashes.len(), 2);
        assert!(
            plan.dataset.sample_hashes[0]
                .hash_sha256
                .starts_with("sha256:")
        );
        assert!(!plan.dataset.would_write);
        assert!(!plan.dataset.object_store_write);
        assert!(!plan.dataset.source_material_output);
        assert_eq!(
            plan.payload_policy.policy_id.as_deref(),
            Some("payload-policy.eval.full-requested")
        );
        assert_eq!(plan.payload_policy.requested_policy, "full");
        assert!(plan.payload_policy.requested_policy_recognized);
        assert_eq!(plan.payload_policy.effective_policy, "hash");
        assert!(plan.payload_policy.unsafe_policy_downgraded);
        assert!(!plan.payload_policy.raw_payload_storage);
        assert!(!plan.payload_policy.raw_payload_output);
        assert!(plan.payload_policy.hash_only_when_material_needed);
        assert!(plan.shadow_traffic.enabled);
        assert_eq!(plan.shadow_traffic.percentage, 5.0);
        assert_eq!(plan.shadow_traffic.candidate_route_count, 3);
        assert_eq!(
            plan.shadow_traffic.candidate_route_labels,
            vec![
                "control-openai-primary",
                "candidate-anthropic-canary",
                "candidate-gemini-safe"
            ]
        );
        assert!(!plan.shadow_traffic.gateway_dispatch_supported);
        assert!(!plan.shadow_traffic.would_dispatch);
        assert!(!plan.shadow_traffic.would_send);
        assert!(!plan.shadow_traffic.outbound_call);
        assert!(plan.contract.source_material_omitted);
        assert!(plan.contract.payload_body_omitted);
        assert!(plan.contract.credential_material_omitted);
        assert!(plan.contract.header_material_omitted);
        assert!(plan.contract.registry_hash_only);
        assert!(plan.contract.dataset_hash_or_count_only);
    }

    #[test]
    fn plan_serialization_omits_raw_material_and_sensitive_markers() {
        let fixture = fixture();
        let input = prompt_eval_shadow_input_from_json_str(include_str!(
            "../../../tests/fixtures/worker/prompt_eval_shadow_plan_contract.json"
        ))
        .expect("fixture should parse");
        let plan = prompt_eval_shadow_plan(
            None,
            PromptEvalShadowInputSource::InputJson {
                path: "tests/fixtures/worker/prompt_eval_shadow_plan_contract.json".to_string(),
            },
            input,
        )
        .expect("plan should build");
        let serialized = serde_json::to_string(&plan).expect("plan should serialize");

        for forbidden in fixture["expected_output_contract"]["must_not_echo"]
            .as_array()
            .expect("must_not_echo should be an array")
        {
            let forbidden = forbidden.as_str().expect("must_not_echo entry");
            assert!(
                !serialized.contains(forbidden),
                "serialized prompt eval shadow plan leaked `{forbidden}`"
            );
        }
    }

    #[test]
    fn accepts_precomputed_registry_hash_without_prompt_material() {
        let input = prompt_eval_shadow_input_from_json_str(
            r#"{"input":{"registry":{"item_id":"prompt.safe","version":"v1","hash_sha256":"sha256:1111111111111111111111111111111111111111111111111111111111111111"},"dataset":{"dataset_id":"eval.safe","version":"v1","samples":[]},"shadow_traffic":{"percentage":0}}}"#,
        )
        .expect("shape should parse");

        let plan = prompt_eval_shadow_plan(
            Some(TENANT_ID),
            PromptEvalShadowInputSource::InputJson {
                path: "fixture.json".to_string(),
            },
            input,
        )
        .expect("plan should build");

        assert_eq!(
            plan.registry.hash_sha256,
            "sha256:1111111111111111111111111111111111111111111111111111111111111111"
        );
        assert_eq!(plan.dataset.sample_count, 0);
        assert!(!plan.shadow_traffic.enabled);
    }

    #[test]
    fn rejects_invalid_shadow_percentage() {
        let input = prompt_eval_shadow_input_from_json_str(
            r#"{"input":{"registry":{"item_id":"prompt.safe","version":"v1","prompt":"hello"},"dataset":{"dataset_id":"eval.safe","version":"v1","samples":[]},"shadow_traffic":{"percentage":101}}}"#,
        )
        .expect("shape should parse");

        let error = prompt_eval_shadow_plan(
            None,
            PromptEvalShadowInputSource::InputJson {
                path: "fixture.json".to_string(),
            },
            input,
        )
        .expect_err("invalid shadow percentage should fail");

        assert!(error.contains("between 0 and 100"));
    }

    #[test]
    fn execute_error_documents_refused_writes_and_dispatch() {
        assert!(prompt_eval_shadow_execute_error(false).contains("requires --force"));
        assert!(prompt_eval_shadow_execute_error(true).contains("Gateway dispatch"));
    }

    fn fixture() -> Value {
        serde_json::from_str(include_str!(
            "../../../tests/fixtures/worker/prompt_eval_shadow_plan_contract.json"
        ))
        .expect("prompt eval shadow contract fixture should be valid json")
    }
}
