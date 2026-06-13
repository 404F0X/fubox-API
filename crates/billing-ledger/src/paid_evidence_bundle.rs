use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::{BillingBetaPaidEvidence, REQUIRED_PAID_BETA_EVIDENCE};

pub const BILLING_PAID_EVIDENCE_BUNDLE_SCHEMA: &str =
    "billing_paid_strong_consistency_evidence_bundle.v1";

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct BillingPaidEvidenceBundle {
    pub schema_version: String,
    pub bundle_id: String,
    pub generated_at_utc: String,
    pub generated_by: String,
    #[serde(default)]
    pub environment_scope: String,
    #[serde(default)]
    pub production_hot_path_claim: bool,
    #[serde(default = "default_contract_shape_only")]
    pub contract_shape_only: bool,
    #[serde(default)]
    pub synthetic_selftest: bool,
    #[serde(default)]
    pub paid_controlled_beta_production_ready: bool,
    #[serde(default)]
    pub evidence: Vec<BillingPaidEvidenceItem>,
    #[serde(default)]
    pub secret_safe: BillingPaidEvidenceSecretSafeInput,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct BillingPaidEvidenceItem {
    pub evidence_key: String,
    pub status: BillingPaidEvidenceStatus,
    #[serde(default)]
    pub passed: bool,
    #[serde(default)]
    pub evidence_id: Option<String>,
    #[serde(default)]
    pub request_id: Option<String>,
    pub operation: String,
    pub scenario: String,
    pub generated_at_utc: String,
    pub source: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BillingPaidEvidenceStatus {
    Passed,
    Failed,
    Missing,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Deserialize)]
pub struct BillingPaidEvidenceSecretSafeInput {
    #[serde(default)]
    pub raw_secret_present: bool,
    #[serde(default)]
    pub credential_material_echoed: bool,
    #[serde(default)]
    pub database_url_echoed: bool,
    #[serde(default)]
    pub env_value_echoed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct BillingPaidEvidenceBundleValidation {
    pub schema_version: &'static str,
    pub bundle_schema_version: String,
    pub overall_status: BillingPaidEvidenceBundleOverallStatus,
    pub accepted_contract_shape: bool,
    pub production_hot_path_claim: bool,
    pub contract_shape_only: bool,
    pub synthetic_selftest: bool,
    pub paid_controlled_beta_production_ready: bool,
    pub required_evidence: Vec<&'static str>,
    pub accepted_evidence: Vec<String>,
    pub missing_evidence: Vec<String>,
    pub invalid_evidence: Vec<BillingPaidEvidenceInvalidItem>,
    pub refusal_reasons: Vec<String>,
    pub readiness_evidence: BillingBetaPaidEvidence,
    pub secret_safe: BillingPaidEvidenceSecretSafeValidation,
    pub side_effects: BillingPaidEvidenceBundleSideEffects,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BillingPaidEvidenceBundleOverallStatus {
    AcceptedContractShape,
    Refused,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct BillingPaidEvidenceInvalidItem {
    pub evidence_key: String,
    pub reasons: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct BillingPaidEvidenceSecretSafeValidation {
    pub raw_secret_present: bool,
    pub credential_material_echoed: bool,
    pub database_url_echoed: bool,
    pub env_value_echoed: bool,
    pub secret_safe: bool,
    pub output_contains_raw_bundle: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct BillingPaidEvidenceBundleSideEffects {
    pub network_io_performed: bool,
    pub db_io_performed: bool,
    pub gateway_hot_path_modified: bool,
    pub paid_mode_selected: bool,
}

pub fn validate_billing_paid_evidence_bundle(
    bundle: &BillingPaidEvidenceBundle,
) -> BillingPaidEvidenceBundleValidation {
    let mut accepted_evidence = BTreeSet::new();
    let mut invalid_by_key = BTreeMap::<String, Vec<String>>::new();
    let mut seen = BTreeSet::new();
    let mut refusal_reasons = Vec::new();

    if bundle.schema_version != BILLING_PAID_EVIDENCE_BUNDLE_SCHEMA {
        refusal_reasons.push("schema_version_mismatch".to_string());
    }
    if is_blank(&bundle.bundle_id) {
        refusal_reasons.push("bundle_id_missing".to_string());
    }
    if is_blank(&bundle.generated_at_utc) {
        refusal_reasons.push("bundle_generated_at_missing".to_string());
    }
    if is_blank(&bundle.generated_by) {
        refusal_reasons.push("bundle_generated_by_missing".to_string());
    }

    let required = REQUIRED_PAID_BETA_EVIDENCE
        .iter()
        .copied()
        .collect::<BTreeSet<_>>();

    for item in &bundle.evidence {
        let mut reasons = Vec::new();
        let evidence_key = item.evidence_key.trim();
        if !required.contains(evidence_key) {
            reasons.push("unknown_evidence_key".to_string());
        }
        if !seen.insert(evidence_key.to_string()) {
            reasons.push("duplicate_evidence_key".to_string());
        }
        if item.status != BillingPaidEvidenceStatus::Passed {
            reasons.push("evidence_status_not_passed".to_string());
        }
        if !item.passed {
            reasons.push("evidence_passed_false".to_string());
        }
        if item
            .evidence_id
            .as_ref()
            .is_none_or(|value| is_blank(value))
            && item.request_id.as_ref().is_none_or(|value| is_blank(value))
        {
            reasons.push("evidence_id_or_request_id_missing".to_string());
        }
        if is_blank(&item.operation) {
            reasons.push("operation_missing".to_string());
        }
        if is_blank(&item.scenario) {
            reasons.push("scenario_missing".to_string());
        }
        if is_blank(&item.generated_at_utc) {
            reasons.push("evidence_generated_at_missing".to_string());
        }
        if is_blank(&item.source) {
            reasons.push("source_missing".to_string());
        }

        if reasons.is_empty() {
            accepted_evidence.insert(evidence_key.to_string());
        } else {
            invalid_by_key
                .entry(if evidence_key.is_empty() {
                    "<blank>".to_string()
                } else {
                    evidence_key.to_string()
                })
                .or_default()
                .extend(reasons);
        }
    }

    let missing_evidence = REQUIRED_PAID_BETA_EVIDENCE
        .iter()
        .filter(|name| !accepted_evidence.contains(**name))
        .map(|name| (*name).to_string())
        .collect::<Vec<_>>();

    if !missing_evidence.is_empty() {
        refusal_reasons.push("required_evidence_missing_or_invalid".to_string());
    }
    if !invalid_by_key.is_empty() {
        refusal_reasons.push("evidence_shape_invalid".to_string());
    }

    let secret_safe = BillingPaidEvidenceSecretSafeValidation {
        raw_secret_present: bundle.secret_safe.raw_secret_present,
        credential_material_echoed: bundle.secret_safe.credential_material_echoed,
        database_url_echoed: bundle.secret_safe.database_url_echoed,
        env_value_echoed: bundle.secret_safe.env_value_echoed,
        secret_safe: !bundle.secret_safe.raw_secret_present
            && !bundle.secret_safe.credential_material_echoed
            && !bundle.secret_safe.database_url_echoed
            && !bundle.secret_safe.env_value_echoed,
        output_contains_raw_bundle: false,
    };
    if !secret_safe.secret_safe {
        refusal_reasons.push("secret_safe_contract_failed".to_string());
    }

    let accepted_contract_shape = refusal_reasons.is_empty() && missing_evidence.is_empty();
    let paid_controlled_beta_production_ready = accepted_contract_shape
        && !bundle.contract_shape_only
        && !bundle.synthetic_selftest
        && bundle.production_hot_path_claim
        && bundle.paid_controlled_beta_production_ready
        && secret_safe.secret_safe;
    let readiness_evidence = BillingBetaPaidEvidence {
        gateway_hot_path_reserve_settle_refund: accepted_evidence
            .contains("gateway_hot_path_reserve_settle_refund"),
        insufficient_balance_prevents_provider_call: accepted_evidence
            .contains("insufficient_balance_prevents_provider_call"),
        settle_idempotency: accepted_evidence.contains("settle_idempotency"),
        refund_idempotency: accepted_evidence.contains("refund_idempotency"),
        post_commit_readback: accepted_evidence.contains("post_commit_readback"),
        rollback_proof: accepted_evidence.contains("rollback_proof"),
        reconciliation_report: accepted_evidence.contains("reconciliation_report"),
    };

    BillingPaidEvidenceBundleValidation {
        schema_version: "billing_paid_strong_consistency_evidence_bundle_validation.v1",
        bundle_schema_version: bundle.schema_version.clone(),
        overall_status: if accepted_contract_shape {
            BillingPaidEvidenceBundleOverallStatus::AcceptedContractShape
        } else {
            BillingPaidEvidenceBundleOverallStatus::Refused
        },
        accepted_contract_shape,
        production_hot_path_claim: bundle.production_hot_path_claim,
        contract_shape_only: bundle.contract_shape_only,
        synthetic_selftest: bundle.synthetic_selftest,
        paid_controlled_beta_production_ready,
        required_evidence: REQUIRED_PAID_BETA_EVIDENCE.to_vec(),
        accepted_evidence: accepted_evidence.into_iter().collect(),
        missing_evidence,
        invalid_evidence: invalid_by_key
            .into_iter()
            .map(|(evidence_key, reasons)| BillingPaidEvidenceInvalidItem {
                evidence_key,
                reasons,
            })
            .collect(),
        refusal_reasons,
        readiness_evidence,
        secret_safe,
        side_effects: BillingPaidEvidenceBundleSideEffects {
            network_io_performed: false,
            db_io_performed: false,
            gateway_hot_path_modified: false,
            paid_mode_selected: false,
        },
    }
}

fn is_blank(value: &str) -> bool {
    value.trim().is_empty()
}

const fn default_contract_shape_only() -> bool {
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    const ACCEPTED_FIXTURE: &str = include_str!(
        "../../../tests/fixtures/billing/paid_evidence_bundle.accepted_contract_shape.json"
    );
    const INCOMPLETE_FIXTURE: &str = include_str!(
        "../../../tests/fixtures/billing/paid_evidence_bundle.incomplete_contract_shape.json"
    );
    const SYNTHETIC_PRODUCTION_READY_SELFTEST_FIXTURE: &str = include_str!(
        "../../../tests/fixtures/billing/paid_evidence_bundle.synthetic_production_ready_selftest.json"
    );

    #[test]
    fn paid_evidence_bundle_complete_fixture_is_accepted_contract_shape() {
        let bundle: BillingPaidEvidenceBundle =
            serde_json::from_str(ACCEPTED_FIXTURE).expect("accepted fixture should parse");
        let validation = validate_billing_paid_evidence_bundle(&bundle);

        assert_eq!(
            validation.overall_status,
            BillingPaidEvidenceBundleOverallStatus::AcceptedContractShape
        );
        assert!(validation.accepted_contract_shape);
        assert_eq!(validation.accepted_evidence.len(), 7);
        assert!(validation.missing_evidence.is_empty());
        assert!(validation.invalid_evidence.is_empty());
        assert!(validation.refusal_reasons.is_empty());
        assert!(
            validation
                .readiness_evidence
                .gateway_hot_path_reserve_settle_refund
        );
        assert!(
            validation
                .readiness_evidence
                .insufficient_balance_prevents_provider_call
        );
        assert!(validation.readiness_evidence.settle_idempotency);
        assert!(validation.readiness_evidence.refund_idempotency);
        assert!(validation.readiness_evidence.post_commit_readback);
        assert!(validation.readiness_evidence.rollback_proof);
        assert!(validation.readiness_evidence.reconciliation_report);
        assert!(validation.secret_safe.secret_safe);
        assert!(!validation.production_hot_path_claim);
        assert!(validation.contract_shape_only);
        assert!(!validation.synthetic_selftest);
        assert!(!validation.paid_controlled_beta_production_ready);
        assert!(!validation.side_effects.network_io_performed);
        assert!(!validation.side_effects.db_io_performed);
    }

    #[test]
    fn paid_evidence_bundle_incomplete_fixture_is_refused() {
        let bundle: BillingPaidEvidenceBundle =
            serde_json::from_str(INCOMPLETE_FIXTURE).expect("incomplete fixture should parse");
        let validation = validate_billing_paid_evidence_bundle(&bundle);

        assert_eq!(
            validation.overall_status,
            BillingPaidEvidenceBundleOverallStatus::Refused
        );
        assert!(!validation.accepted_contract_shape);
        assert!(
            validation
                .missing_evidence
                .contains(&"refund_idempotency".to_string())
        );
        assert!(
            validation
                .missing_evidence
                .contains(&"reconciliation_report".to_string())
        );
        assert!(
            validation
                .refusal_reasons
                .contains(&"required_evidence_missing_or_invalid".to_string())
        );
    }

    #[test]
    fn paid_evidence_bundle_rejects_invalid_required_field_shape() {
        let mut bundle: BillingPaidEvidenceBundle =
            serde_json::from_str(ACCEPTED_FIXTURE).expect("accepted fixture should parse");
        let item = bundle
            .evidence
            .iter_mut()
            .find(|item| item.evidence_key == "settle_idempotency")
            .expect("settle evidence");
        item.evidence_id = None;
        item.request_id = None;
        item.operation.clear();

        let validation = validate_billing_paid_evidence_bundle(&bundle);

        assert_eq!(
            validation.overall_status,
            BillingPaidEvidenceBundleOverallStatus::Refused
        );
        assert!(
            validation
                .missing_evidence
                .contains(&"settle_idempotency".to_string())
        );
        let invalid = validation
            .invalid_evidence
            .iter()
            .find(|item| item.evidence_key == "settle_idempotency")
            .expect("invalid settle evidence");
        assert!(
            invalid
                .reasons
                .contains(&"evidence_id_or_request_id_missing".to_string())
        );
        assert!(invalid.reasons.contains(&"operation_missing".to_string()));
    }

    #[test]
    fn paid_evidence_bundle_rejects_secret_safe_failure_without_echoing_raw_bundle() {
        let mut bundle: BillingPaidEvidenceBundle =
            serde_json::from_str(ACCEPTED_FIXTURE).expect("accepted fixture should parse");
        bundle.secret_safe.raw_secret_present = true;
        bundle.secret_safe.credential_material_echoed = true;

        let validation = validate_billing_paid_evidence_bundle(&bundle);
        let output = serde_json::to_string(&validation).expect("validation should serialize");

        assert_eq!(
            validation.overall_status,
            BillingPaidEvidenceBundleOverallStatus::Refused
        );
        assert!(!validation.secret_safe.secret_safe);
        assert!(
            validation
                .refusal_reasons
                .contains(&"secret_safe_contract_failed".to_string())
        );
        assert!(!validation.secret_safe.output_contains_raw_bundle);
        assert!(!output.contains("Bearer "));
        assert!(!output.contains("sk-"));
        assert!(!output.contains("provider_key"));
    }

    #[test]
    fn paid_evidence_bundle_marks_real_production_shape_ready_only_when_not_synthetic() {
        let mut bundle: BillingPaidEvidenceBundle =
            serde_json::from_str(ACCEPTED_FIXTURE).expect("accepted fixture should parse");
        bundle.contract_shape_only = false;
        bundle.production_hot_path_claim = true;
        bundle.paid_controlled_beta_production_ready = true;
        bundle.synthetic_selftest = false;

        let validation = validate_billing_paid_evidence_bundle(&bundle);

        assert!(validation.accepted_contract_shape);
        assert!(!validation.contract_shape_only);
        assert!(validation.production_hot_path_claim);
        assert!(!validation.synthetic_selftest);
        assert!(validation.paid_controlled_beta_production_ready);
    }

    #[test]
    fn paid_evidence_bundle_synthetic_production_ready_selftest_cannot_open_paid() {
        let bundle: BillingPaidEvidenceBundle =
            serde_json::from_str(SYNTHETIC_PRODUCTION_READY_SELFTEST_FIXTURE)
                .expect("synthetic selftest fixture should parse");
        let validation = validate_billing_paid_evidence_bundle(&bundle);

        assert!(validation.accepted_contract_shape);
        assert!(!validation.contract_shape_only);
        assert!(validation.production_hot_path_claim);
        assert!(validation.synthetic_selftest);
        assert!(!validation.paid_controlled_beta_production_ready);
    }
}
