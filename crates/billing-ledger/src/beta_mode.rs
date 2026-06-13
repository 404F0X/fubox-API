use serde::{Deserialize, Serialize};

pub const BILLING_BETA_MODE_READINESS_SCHEMA: &str = "billing_beta_mode_readiness.v1";

pub const REQUIRED_PAID_BETA_EVIDENCE: [&str; 7] = [
    "gateway_hot_path_reserve_settle_refund",
    "insufficient_balance_prevents_provider_call",
    "settle_idempotency",
    "refund_idempotency",
    "post_commit_readback",
    "rollback_proof",
    "reconciliation_report",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BillingBetaModeRequested {
    UsageOnlyBeta,
    PaidControlledBeta,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BillingBetaModeDecision {
    UsageOnlyBetaAllowed,
    PaidControlledBetaAllowed,
    PaidControlledBetaRefusedMissingEvidence,
    PaidControlledBetaRequestedBlockedNotProductionReady,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct BillingBetaPaidEvidence {
    #[serde(default)]
    pub gateway_hot_path_reserve_settle_refund: bool,
    #[serde(default)]
    pub insufficient_balance_prevents_provider_call: bool,
    #[serde(default)]
    pub settle_idempotency: bool,
    #[serde(default)]
    pub refund_idempotency: bool,
    #[serde(default)]
    pub post_commit_readback: bool,
    #[serde(default)]
    pub rollback_proof: bool,
    #[serde(default)]
    pub reconciliation_report: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct BillingBetaModeReadinessInput {
    pub billing_mode_requested: BillingBetaModeRequested,
    #[serde(default)]
    pub evidence: BillingBetaPaidEvidence,
    #[serde(default)]
    pub paid_evidence_bundle_production_ready: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct BillingBetaModeReadinessSummary {
    pub schema_version: &'static str,
    pub billing_mode_requested: BillingBetaModeRequested,
    pub usage_only_beta_allowed: bool,
    pub paid_controlled_beta_allowed: bool,
    pub required_evidence: Vec<&'static str>,
    pub missing_evidence: Vec<&'static str>,
    pub decision: BillingBetaModeDecision,
    pub blockers: Vec<&'static str>,
    pub secret_safe: BillingBetaModeSecretSafe,
    pub exit_code_contract: BillingBetaModeExitCodeContract,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct BillingBetaModeSecretSafe {
    pub database_url_output: &'static str,
    pub env_value_output: &'static str,
    pub raw_secret_echoed: bool,
    pub credential_material_echoed: bool,
    pub network_or_db_io_performed: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct BillingBetaModeExitCodeContract {
    pub usage_only_allowed_exit_code: i32,
    pub paid_allowed_exit_code: i32,
    pub paid_refused_missing_evidence_exit_code: i32,
}

pub fn evaluate_billing_beta_mode_readiness(
    input: BillingBetaModeReadinessInput,
) -> BillingBetaModeReadinessSummary {
    let missing_evidence = missing_paid_evidence(input.evidence);

    let (usage_only_beta_allowed, paid_controlled_beta_allowed, decision, blockers) =
        match input.billing_mode_requested {
            BillingBetaModeRequested::UsageOnlyBeta => (
                true,
                false,
                BillingBetaModeDecision::UsageOnlyBetaAllowed,
                Vec::new(),
            ),
            BillingBetaModeRequested::PaidControlledBeta
                if missing_evidence.is_empty() && input.paid_evidence_bundle_production_ready =>
            {
                (
                    false,
                    true,
                    BillingBetaModeDecision::PaidControlledBetaAllowed,
                    Vec::new(),
                )
            }
            BillingBetaModeRequested::PaidControlledBeta if missing_evidence.is_empty() => (
                false,
                false,
                BillingBetaModeDecision::PaidControlledBetaRequestedBlockedNotProductionReady,
                Vec::new(),
            ),
            BillingBetaModeRequested::PaidControlledBeta => (
                false,
                false,
                BillingBetaModeDecision::PaidControlledBetaRefusedMissingEvidence,
                missing_evidence.clone(),
            ),
        };

    BillingBetaModeReadinessSummary {
        schema_version: BILLING_BETA_MODE_READINESS_SCHEMA,
        billing_mode_requested: input.billing_mode_requested,
        usage_only_beta_allowed,
        paid_controlled_beta_allowed,
        required_evidence: REQUIRED_PAID_BETA_EVIDENCE.to_vec(),
        missing_evidence,
        decision,
        blockers,
        secret_safe: BillingBetaModeSecretSafe {
            database_url_output: "omitted",
            env_value_output: "omitted",
            raw_secret_echoed: false,
            credential_material_echoed: false,
            network_or_db_io_performed: false,
        },
        exit_code_contract: BillingBetaModeExitCodeContract {
            usage_only_allowed_exit_code: 0,
            paid_allowed_exit_code: 0,
            paid_refused_missing_evidence_exit_code: 2,
        },
    }
}

fn missing_paid_evidence(evidence: BillingBetaPaidEvidence) -> Vec<&'static str> {
    let mut missing = Vec::new();

    if !evidence.gateway_hot_path_reserve_settle_refund {
        missing.push("gateway_hot_path_reserve_settle_refund");
    }
    if !evidence.insufficient_balance_prevents_provider_call {
        missing.push("insufficient_balance_prevents_provider_call");
    }
    if !evidence.settle_idempotency {
        missing.push("settle_idempotency");
    }
    if !evidence.refund_idempotency {
        missing.push("refund_idempotency");
    }
    if !evidence.post_commit_readback {
        missing.push("post_commit_readback");
    }
    if !evidence.rollback_proof {
        missing.push("rollback_proof");
    }
    if !evidence.reconciliation_report {
        missing.push("reconciliation_report");
    }

    missing
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;

    const READINESS_FIXTURE: &str =
        include_str!("../../../tests/fixtures/billing/billing_beta_mode_readiness_contract.json");

    #[derive(Debug, Deserialize)]
    struct ReadinessFixture {
        contract: String,
        required_evidence: Vec<String>,
        default_evidence: BillingBetaPaidEvidence,
        cases: Vec<ReadinessFixtureCase>,
    }

    #[derive(Debug, Deserialize)]
    struct ReadinessFixtureCase {
        billing_mode_requested: BillingBetaModeRequested,
        evidence: Option<BillingBetaPaidEvidence>,
        paid_evidence_bundle_production_ready: Option<bool>,
        expect: ReadinessFixtureExpected,
    }

    #[derive(Debug, Deserialize)]
    struct ReadinessFixtureExpected {
        usage_only_beta_allowed: bool,
        paid_controlled_beta_allowed: bool,
        decision: BillingBetaModeDecision,
        missing_evidence: Vec<String>,
        blockers: Vec<String>,
        exit_code: i32,
    }

    #[test]
    fn beta_billing_mode_usage_only_is_allowed_without_paid_evidence() {
        let summary = evaluate_billing_beta_mode_readiness(BillingBetaModeReadinessInput {
            billing_mode_requested: BillingBetaModeRequested::UsageOnlyBeta,
            evidence: BillingBetaPaidEvidence::default(),
            paid_evidence_bundle_production_ready: false,
        });

        assert!(summary.usage_only_beta_allowed);
        assert!(!summary.paid_controlled_beta_allowed);
        assert_eq!(
            summary.decision,
            BillingBetaModeDecision::UsageOnlyBetaAllowed
        );
        assert!(summary.blockers.is_empty());
        assert_eq!(summary.missing_evidence, REQUIRED_PAID_BETA_EVIDENCE);
        assert!(!summary.secret_safe.network_or_db_io_performed);
    }

    #[test]
    fn beta_billing_mode_paid_is_refused_when_required_evidence_is_missing() {
        let summary = evaluate_billing_beta_mode_readiness(BillingBetaModeReadinessInput {
            billing_mode_requested: BillingBetaModeRequested::PaidControlledBeta,
            evidence: BillingBetaPaidEvidence::default(),
            paid_evidence_bundle_production_ready: false,
        });

        assert!(!summary.usage_only_beta_allowed);
        assert!(!summary.paid_controlled_beta_allowed);
        assert_eq!(
            summary.decision,
            BillingBetaModeDecision::PaidControlledBetaRefusedMissingEvidence
        );
        assert_eq!(summary.missing_evidence, REQUIRED_PAID_BETA_EVIDENCE);
        assert_eq!(summary.blockers, REQUIRED_PAID_BETA_EVIDENCE);
        assert_eq!(
            summary
                .exit_code_contract
                .paid_refused_missing_evidence_exit_code,
            2
        );
    }

    #[test]
    fn beta_billing_mode_paid_is_refused_when_evidence_shape_is_present_but_not_production_ready() {
        let summary = evaluate_billing_beta_mode_readiness(BillingBetaModeReadinessInput {
            billing_mode_requested: BillingBetaModeRequested::PaidControlledBeta,
            evidence: BillingBetaPaidEvidence {
                gateway_hot_path_reserve_settle_refund: true,
                insufficient_balance_prevents_provider_call: true,
                settle_idempotency: true,
                refund_idempotency: true,
                post_commit_readback: true,
                rollback_proof: true,
                reconciliation_report: true,
            },
            paid_evidence_bundle_production_ready: false,
        });

        assert!(!summary.usage_only_beta_allowed);
        assert!(!summary.paid_controlled_beta_allowed);
        assert_eq!(
            summary.decision,
            BillingBetaModeDecision::PaidControlledBetaRequestedBlockedNotProductionReady
        );
        assert!(summary.missing_evidence.is_empty());
        assert!(summary.blockers.is_empty());
    }

    #[test]
    fn beta_billing_mode_paid_is_allowed_only_when_evidence_is_production_ready() {
        let summary = evaluate_billing_beta_mode_readiness(BillingBetaModeReadinessInput {
            billing_mode_requested: BillingBetaModeRequested::PaidControlledBeta,
            evidence: BillingBetaPaidEvidence {
                gateway_hot_path_reserve_settle_refund: true,
                insufficient_balance_prevents_provider_call: true,
                settle_idempotency: true,
                refund_idempotency: true,
                post_commit_readback: true,
                rollback_proof: true,
                reconciliation_report: true,
            },
            paid_evidence_bundle_production_ready: true,
        });

        assert!(!summary.usage_only_beta_allowed);
        assert!(summary.paid_controlled_beta_allowed);
        assert_eq!(
            summary.decision,
            BillingBetaModeDecision::PaidControlledBetaAllowed
        );
        assert!(summary.missing_evidence.is_empty());
        assert!(summary.blockers.is_empty());
    }

    #[test]
    fn beta_billing_mode_readiness_fixture_cases_match_evaluator() {
        let fixture: ReadinessFixture =
            serde_json::from_str(READINESS_FIXTURE).expect("fixture should parse");

        assert_eq!(fixture.contract, BILLING_BETA_MODE_READINESS_SCHEMA);
        assert_eq!(
            fixture.required_evidence,
            REQUIRED_PAID_BETA_EVIDENCE
                .iter()
                .map(|item| item.to_string())
                .collect::<Vec<_>>()
        );

        for case in fixture.cases {
            let summary = evaluate_billing_beta_mode_readiness(BillingBetaModeReadinessInput {
                billing_mode_requested: case.billing_mode_requested,
                evidence: case.evidence.unwrap_or(fixture.default_evidence),
                paid_evidence_bundle_production_ready: case
                    .paid_evidence_bundle_production_ready
                    .unwrap_or(false),
            });

            assert_eq!(
                summary.usage_only_beta_allowed,
                case.expect.usage_only_beta_allowed
            );
            assert_eq!(
                summary.paid_controlled_beta_allowed,
                case.expect.paid_controlled_beta_allowed
            );
            assert_eq!(summary.decision, case.expect.decision);
            assert_eq!(
                summary.missing_evidence,
                case.expect
                    .missing_evidence
                    .iter()
                    .map(String::as_str)
                    .collect::<Vec<_>>()
            );
            assert_eq!(
                summary.blockers,
                case.expect
                    .blockers
                    .iter()
                    .map(String::as_str)
                    .collect::<Vec<_>>()
            );
            let expected_exit_code = match summary.decision {
                BillingBetaModeDecision::PaidControlledBetaRefusedMissingEvidence => {
                    summary
                        .exit_code_contract
                        .paid_refused_missing_evidence_exit_code
                }
                BillingBetaModeDecision::PaidControlledBetaRequestedBlockedNotProductionReady => {
                    summary
                        .exit_code_contract
                        .paid_refused_missing_evidence_exit_code
                }
                BillingBetaModeDecision::UsageOnlyBetaAllowed => {
                    summary.exit_code_contract.usage_only_allowed_exit_code
                }
                BillingBetaModeDecision::PaidControlledBetaAllowed => {
                    summary.exit_code_contract.paid_allowed_exit_code
                }
            };
            assert_eq!(expected_exit_code, case.expect.exit_code);
            assert!(!summary.secret_safe.network_or_db_io_performed);
        }
    }
}
