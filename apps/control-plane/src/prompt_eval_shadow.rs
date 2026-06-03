use std::collections::BTreeSet;

use ai_gateway_observability::{PayloadPolicy, payload_sha256_hex, redact_secrets};
use serde::Deserialize;
use serde_json::{Value, json};
use uuid::Uuid;

use crate::DEFAULT_TENANT_ID;

const SCHEMA_VERSION: &str = "prompt_eval_shadow_admin_dry_run.v1";

#[derive(Debug, Clone, Default, Deserialize)]
pub(crate) struct PromptEvalShadowDryRunRequest {
    #[serde(default)]
    tenant_id: Option<Uuid>,
    #[serde(default, alias = "prompt_registry")]
    registry: PromptRegistryInput,
    #[serde(default, alias = "eval_dataset")]
    dataset: EvalDatasetInput,
    #[serde(default)]
    payload_policy: PayloadPolicyInput,
    #[serde(default, alias = "shadow", alias = "shadow_traffic")]
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
    #[serde(default, alias = "hash", alias = "prompt_hash", alias = "content_hash")]
    hash_sha256: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
struct EvalDatasetInput {
    #[serde(default, alias = "id", alias = "eval_dataset_id")]
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
    #[serde(default, alias = "percent", alias = "shadow_percentage")]
    percentage: Option<f64>,
    #[serde(default, alias = "route_labels", alias = "labels")]
    candidate_route_labels: Vec<String>,
    #[serde(default, alias = "candidate_routes", alias = "routes")]
    routes: Vec<ShadowRouteInput>,
}

#[derive(Debug, Clone, Default, Deserialize)]
struct ShadowRouteInput {
    #[serde(default, alias = "route_label", alias = "name", alias = "id")]
    label: Option<String>,
}

struct RegistryPlan {
    item_id: String,
    version: String,
    hash_sha256: String,
}

struct DatasetPlan {
    dataset_id: String,
    version: String,
    sample_hashes: Vec<Value>,
}

struct StoragePolicyPlan {
    requested: String,
    policy_id: Option<String>,
    effective: &'static str,
    recognized: bool,
    unsafe_policy_downgraded: bool,
}

struct ShadowPlan {
    enabled: bool,
    percentage: f64,
    route_labels: Vec<String>,
}

pub(crate) fn dry_run_prompt_eval_shadow(
    request: PromptEvalShadowDryRunRequest,
) -> Result<Value, String> {
    let tenant_id = request.tenant_id.unwrap_or(DEFAULT_TENANT_ID);
    let registry = registry_plan(request.registry)?;
    let dataset = dataset_plan(request.dataset.clone())?;
    let storage_policy = storage_policy_plan(resolve_payload_policy(
        request.payload_policy,
        request.dataset.payload_policy,
    ));
    let shadow = shadow_plan(request.shadow_traffic)?;
    let dataset_sample_count = dataset.sample_hashes.len();
    let route_label_count = shadow.route_labels.len();

    Ok(json!({
        "schema_version": SCHEMA_VERSION,
        "dry_run": true,
        "mode": "validate_plan_only",
        "labels": {
            "tenant_id": tenant_id,
            "registry_item_id": registry.item_id,
            "registry_version": registry.version,
            "dataset_id": dataset.dataset_id,
            "dataset_version": dataset.version,
            "route_labels": shadow.route_labels,
        },
        "hashes": {
            "registry_template_sha256": registry.hash_sha256,
            "dataset_sample_hashes": dataset.sample_hashes,
        },
        "counts": {
            "dataset_samples": dataset_sample_count,
            "route_labels": route_label_count,
        },
        "storage_policy": {
            "policy_id": storage_policy.policy_id,
            "requested": storage_policy.requested,
            "effective": storage_policy.effective,
            "recognized": storage_policy.recognized,
            "unsafe_policy_downgraded": storage_policy.unsafe_policy_downgraded,
        },
        "shadow": {
            "enabled": shadow.enabled,
            "percentage": shadow.percentage,
        },
        "flags": {
            "valid": true,
            "dry_run": true,
            "plan_only": true,
            "business_db_read": false,
            "db_write": false,
            "object_storage_read": false,
            "object_storage_write": false,
            "gateway_call": false,
            "network_request": false,
            "raw_prompt_output": false,
            "raw_body_output": false,
            "sensitive_material_output": false,
            "hash_only": true,
            "labels_only": true,
        },
    }))
}

fn registry_plan(input: PromptRegistryInput) -> Result<RegistryPlan, String> {
    let item_id = required_label(input.item_id.as_deref(), "registry item_id")?;
    let version = required_label(input.version.as_deref(), "registry version")?;
    let hash_sha256 =
        match input.prompt.as_ref() {
            Some(prompt) => hash_value(prompt),
            None => normalize_sha256(input.hash_sha256.as_deref().ok_or_else(|| {
                "registry prompt template or hash_sha256 is required".to_string()
            })?)?,
        };

    Ok(RegistryPlan {
        item_id,
        version,
        hash_sha256,
    })
}

fn dataset_plan(input: EvalDatasetInput) -> Result<DatasetPlan, String> {
    let dataset_id = required_label(input.dataset_id.as_deref(), "dataset_id")?;
    let version = required_label(input.version.as_deref(), "dataset version")?;
    let sample_hashes = input
        .samples
        .iter()
        .map(|sample| {
            json!({
                "sample_label": sample_label(sample),
                "hash_sha256": hash_value(sample),
            })
        })
        .collect::<Vec<_>>();

    Ok(DatasetPlan {
        dataset_id,
        version,
        sample_hashes,
    })
}

fn storage_policy_plan(input: PayloadPolicyInput) -> StoragePolicyPlan {
    let requested_raw = input.policy.as_deref().unwrap_or("metadata_only");
    let parsed = PayloadPolicy::parse(requested_raw);
    let effective = match parsed {
        Some(PayloadPolicy::MetadataOnly) => "metadata_only",
        _ => "hash",
    };

    StoragePolicyPlan {
        requested: safe_label(requested_raw),
        policy_id: input.policy_id.as_deref().map(safe_label),
        effective,
        recognized: parsed.is_some(),
        unsafe_policy_downgraded: parsed.is_some_and(|policy| {
            !matches!(policy, PayloadPolicy::MetadataOnly | PayloadPolicy::Hash)
        }),
    }
}

fn shadow_plan(input: ShadowTrafficInput) -> Result<ShadowPlan, String> {
    let percentage = input.percentage.unwrap_or(0.0);
    if !percentage.is_finite() || !(0.0..=100.0).contains(&percentage) {
        return Err("shadow percentage must be between 0 and 100".to_string());
    }

    let mut seen = BTreeSet::new();
    let mut route_labels = Vec::new();
    for label in input
        .candidate_route_labels
        .into_iter()
        .chain(input.routes.into_iter().filter_map(|route| route.label))
    {
        let label = safe_label(&label);
        if !label.is_empty() && seen.insert(label.clone()) {
            route_labels.push(label);
        }
    }

    Ok(ShadowPlan {
        enabled: input.enabled.unwrap_or(percentage > 0.0),
        percentage,
        route_labels,
    })
}

fn resolve_payload_policy(
    top_level: PayloadPolicyInput,
    dataset_level: PayloadPolicyInput,
) -> PayloadPolicyInput {
    if dataset_level.policy.is_some() || dataset_level.policy_id.is_some() {
        dataset_level
    } else {
        top_level
    }
}

fn sample_label(sample: &Value) -> Option<String> {
    sample
        .get("sample_id")
        .or_else(|| sample.get("id"))
        .and_then(Value::as_str)
        .map(safe_label)
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

fn required_label(value: Option<&str>, label: &str) -> Result<String, String> {
    let Some(value) = value else {
        return Err(format!("{label} is required"));
    };
    let value = safe_label(value);
    if value.is_empty() {
        return Err(format!("{label} is required"));
    }

    Ok(value)
}

fn safe_label(value: &str) -> String {
    let redacted = redact_secrets(value.trim());
    if contains_forbidden_material(&redacted) {
        "[REDACTED]".to_string()
    } else {
        redacted
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
        || normalized.contains("cookie")
        || normalized.contains("password")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> Value {
        serde_json::from_str(include_str!(
            "../../../tests/fixtures/control-plane/prompt_eval_shadow_dry_run_contract.json"
        ))
        .expect("fixture should be valid json")
    }

    #[test]
    fn builds_hash_count_label_flag_plan_without_side_effects() {
        let fixture = fixture();
        let request: PromptEvalShadowDryRunRequest =
            serde_json::from_value(fixture["examples"]["valid"]["request"].clone())
                .expect("fixture request should deserialize");
        let response = dry_run_prompt_eval_shadow(request).expect("request should validate");

        assert_eq!(response["schema_version"], json!(SCHEMA_VERSION));
        assert_eq!(response["dry_run"], json!(true));
        assert_eq!(response["mode"], json!("validate_plan_only"));
        assert_eq!(
            response["labels"]["registry_item_id"],
            fixture["expected"]["labels"]["registry_item_id"]
        );
        assert_eq!(
            response["labels"]["dataset_id"],
            fixture["expected"]["labels"]["dataset_id"]
        );
        assert_eq!(response["counts"]["dataset_samples"], json!(2));
        assert_eq!(response["counts"]["route_labels"], json!(3));
        assert_eq!(
            response["hashes"]["registry_template_sha256"]
                .as_str()
                .unwrap()
                .len(),
            71
        );
        assert_eq!(
            response["hashes"]["dataset_sample_hashes"]
                .as_array()
                .expect("sample hashes should be an array")
                .len(),
            2
        );
        assert_eq!(response["storage_policy"]["requested"], json!("full"));
        assert_eq!(response["storage_policy"]["effective"], json!("hash"));
        assert_eq!(
            response["storage_policy"]["unsafe_policy_downgraded"],
            json!(true)
        );
        assert_eq!(response["shadow"]["enabled"], json!(true));
        assert_eq!(response["shadow"]["percentage"], json!(5.0));

        for flag in [
            "business_db_read",
            "db_write",
            "object_storage_read",
            "object_storage_write",
            "gateway_call",
            "network_request",
            "raw_prompt_output",
            "raw_body_output",
            "sensitive_material_output",
        ] {
            assert_eq!(response["flags"][flag], json!(false), "{flag}");
        }
    }

    #[test]
    fn serialization_omits_raw_material_and_sensitive_names() {
        let fixture = fixture();
        let request: PromptEvalShadowDryRunRequest =
            serde_json::from_value(fixture["examples"]["valid"]["request"].clone())
                .expect("fixture request should deserialize");
        let response = dry_run_prompt_eval_shadow(request).expect("request should validate");
        let serialized = serde_json::to_string(&response).expect("response should serialize");
        let lower = serialized.to_ascii_lowercase();

        for forbidden in fixture["expected"]["must_not_echo"]
            .as_array()
            .expect("must_not_echo should be an array")
        {
            let forbidden = forbidden.as_str().expect("must_not_echo string");
            assert!(
                !serialized.contains(forbidden),
                "response leaked `{forbidden}`"
            );
        }
        for forbidden_name in [
            "authorization",
            "token",
            "secret",
            "provider_key",
            "provider key",
        ] {
            assert!(
                !lower.contains(forbidden_name),
                "response included sensitive name `{forbidden_name}`"
            );
        }
    }

    #[test]
    fn accepts_precomputed_registry_hash_and_empty_dataset() {
        let request: PromptEvalShadowDryRunRequest = serde_json::from_value(json!({
            "registry": {
                "item_id": "prompt.safe",
                "version": "v1",
                "hash_sha256": "sha256:1111111111111111111111111111111111111111111111111111111111111111"
            },
            "dataset": {
                "dataset_id": "eval.safe",
                "version": "v1",
                "samples": []
            },
            "shadow_traffic": {
                "percentage": 0
            }
        }))
        .expect("request should deserialize");

        let response = dry_run_prompt_eval_shadow(request).expect("request should validate");

        assert_eq!(
            response["hashes"]["registry_template_sha256"],
            json!("sha256:1111111111111111111111111111111111111111111111111111111111111111")
        );
        assert_eq!(response["counts"]["dataset_samples"], json!(0));
        assert_eq!(response["shadow"]["enabled"], json!(false));
    }

    #[test]
    fn rejects_invalid_input_without_echoing_raw_values() {
        let request: PromptEvalShadowDryRunRequest = serde_json::from_value(json!({
            "registry": {
                "item_id": "prompt.safe",
                "version": "v1",
                "hash_sha256": "not-a-hash"
            },
            "dataset": {
                "dataset_id": "eval.safe",
                "version": "v1"
            },
            "shadow_traffic": {
                "percentage": 101,
                "route_labels": ["route-secret-marker"]
            }
        }))
        .expect("request should deserialize");

        let error = dry_run_prompt_eval_shadow(request).expect_err("invalid hash should fail");

        assert_eq!(error, "hash_sha256 must be a sha256 digest");
        assert!(!error.contains("route-secret-marker"));
    }

    #[test]
    fn contract_fixture_and_openapi_cover_admin_endpoint() {
        let fixture = fixture();
        let openapi = include_str!("../../../examples/openapi_admin_skeleton.yaml");

        assert_eq!(
            fixture["endpoint"]["path"],
            json!("/admin/prompt-eval-shadow/dry-run")
        );
        assert_eq!(
            fixture["rbac"]["required_permission"],
            json!("provider_manage")
        );
        assert!(openapi.contains("/admin/prompt-eval-shadow/dry-run:"));
        assert!(openapi.contains("PromptEvalShadowDryRunRequest"));
        assert!(openapi.contains("PromptEvalShadowDryRunEnvelope"));
    }
}
