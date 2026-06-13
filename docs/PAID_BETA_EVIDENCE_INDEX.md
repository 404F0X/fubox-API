# Paid Beta Evidence Artifact Index

Status date: 2026-06-05

This index is the machine-readable evidence map for `paid_controlled_beta_requested`. It complements `docs/PAID_BETA_RUNBOOK.md`; the runbook defines the operator policy, and this file tracks the artifacts required before `paid_controlled_beta_allowed=true`.

Machine-readable manifest: `project/paid_beta_evidence_index.json`.

Current release state: `controlled_paid_beta_evidence_accepted_by_main_review`; `paid_controlled_beta_allowed=true` for controlled paid beta evidence accepted by main review.

This is not full Production RC. The bounded smoke refund endpoint is dev evidence only; partial refund policy and deeper reconciliation remain Production RC work.

Accepted evidence paths:

- `.tmp/paid-beta/e8_gateway_paid_hot_path.json`
- `.tmp/paid-beta/e11_control_plane_paid_readback_reconciliation.json`
- `.tmp/paid-beta/real_paid_evidence_bundle.json`
- `.tmp/paid-beta/e9_paid_readiness_gate.json`
- `artifacts/beta_acceptance_paid_aggregator_20260605_main_final_review.json`

## Required Artifacts

| Artifact | Owner | Expected path | Schema | Pass markers | Blocked markers | Release artifact | Current status |
|---|---|---|---|---|---|---:|---|
| E8 Gateway paid hot path | E8 / Gateway | `.tmp/paid-beta/e8_gateway_paid_hot_path.json` | `gateway_paid_hot_path_evidence_v1` | `overall_status=pass`; `gateway_hot_path_reserve_settle_refund=pass`; `insufficient_balance_prevents_provider_call=pass`; settle/refund idempotency pass; `provider_attempts_count=0` for insufficient-balance case; `secret_safe=true` | missing artifact; stale commit; simulation/fixture; reserve/settle/refund not all passed; insufficient balance still calls provider; provider attempts generated; secret-safe fail | yes | accepted by main review for controlled paid beta evidence; independent SQL readback pass |
| E11 Control Plane paid readback/reconciliation | E11 / Control Plane | `.tmp/paid-beta/e11_control_plane_paid_readback_reconciliation.json` | `control_plane_paid_ledger_readback_verification.v1` | `overall_status=pass`; `post_commit_readback=pass`; `rollback_proof=pass`; `reconciliation_report=pass`; audit/Admin API/SQL readback pass; `secret_safe=true` | missing Gateway handoff; `gateway_paid_hot_path_artifact_missing`; readback mismatch; rollback missing; reconciliation missing; raw secret/body marker; stale/simulated artifact | yes | accepted by main review; `overall_status=passed`, `actual_exit_code=0`, refund row readback pass |
| E9 real paid evidence bundle | E9 / Billing Ledger | `.tmp/paid-beta/real_paid_evidence_bundle.json` | `billing_paid_strong_consistency_evidence_bundle.v1` | `contract_shape_only=false`; `synthetic_selftest=false`; `production_hot_path_claim=true`; `paid_controlled_beta_production_ready=true`; all seven required evidence items pass; `secret_safe.raw_secret_present=false` | missing E8/E11 source artifact; contract-shape-only; synthetic selftest; production ready false; missing/invalid evidence; secret-safe fail | yes | accepted by main review; accepted contract shape, production ready, non-synthetic real bundle |
| E9 paid readiness gate JSON | E9 / Release | `.tmp/paid-beta/e9_paid_readiness_gate.json` | `billing_beta_mode_readiness.v1` | `paid_controlled_beta_requested=true`; `paid_controlled_beta_allowed=true`; `paid_evidence_bundle_status=pass`; no missing evidence; actual exit 0 | `paid_evidence_bundle_missing`; `paid_evidence_bundle_contract_shape_only_not_production_ready`; `paid_evidence_bundle_refused`; `actual_exit_code=2`; `paid_controlled_beta_allowed=false` | yes | accepted by main review; `paid_controlled_beta_allowed=true` |
| QA paid acceptance aggregator | QA / Release | `artifacts/beta_acceptance_paid_aggregator_20260605_main_final_review.json` | `paid_beta_acceptance_aggregator_v2` | `overall_status=pass`; `paid_controlled_beta_allowed=true`; E8/E11/E9 artifacts all pass; secret scan pass; no missing artifacts; `not_final_if_blocked=false` | `overall_status=blocked`; missing E9 readiness JSON; missing E8 artifact; missing E11 artifact; missing real bundle; `release_gate_paid_allowed` blocked; secret scan fail | yes | accepted by main review; `overall_status=pass`, no blocked/failed checks |
| Secret scan | QA / Security | `artifacts/paid_beta_secret_scan_<run_id>.json` or archived `scripts/scan_secrets.ps1` output | `secret_scan_summary_v1` | exit 0; hits=0; warnings accepted by security; no prompt/token/Authorization/Cookie/DSN/provider key/virtual key leakage | nonzero exit; hits>0; untriaged warnings; raw secret material in any paid artifact | yes | accepted by main review; secret scan exit 0 |
| Full TODO-20 summary | QA | `artifacts/beta_acceptance_summary_<run_id>.json` | `beta_acceptance_summary_v1` | full wrapper/runtime/Admin UI/npm gates pass; paid evidence accepted; `paid_controlled_beta_allowed=true`; `not_final_beta_acceptance=false`; secret-safe | missing summary; full gate not run; any P0/Paid blocker open; `paid_controlled_beta_allowed=false`; stale or simulated evidence | yes | controlled paid beta evidence accepted; not full Production RC |

## Evidence Dependency Order

1. E8 writes the Gateway paid hot path artifact.
2. E11 consumes the E8 artifact and writes Control Plane paid readback/reconciliation.
3. E9 composes the real paid evidence bundle from E8 and E11 artifacts.
4. E9 writes paid readiness gate JSON with `paid_controlled_beta_allowed=true` only if the real bundle passes.
5. QA runs the paid acceptance aggregator, secret scan, and full TODO-20 gate.
6. Release review has moved the controlled paid beta evidence state to `paid_controlled_beta_allowed=true` for the accepted artifacts above.

## Non-Release Inputs

The following may be useful for development but must not satisfy this index:

- Contract fixtures under `tests/fixtures/billing/*`.
- Synthetic selftest bundles.
- Local-only or staging-only cutover artifacts.
- Old production source-of-truth cutover evidence that does not prove Gateway paid hot path behavior.
- Dashboard estimates or request usage previews without ledger/readback evidence.

## Review Rule

For this accepted run, keep the controlled paid beta state tied to the exact accepted artifact paths above. Future runs that are missing, blocked, stale, fixture-only, synthetic, secret-unsafe, or not linked to current evidence must not inherit this pass.
