# Paid Beta Operator Runbook

Status date: 2026-06-05

This runbook is the release/ops/devrel guardrail for paid beta. Current main-review evidence accepts a bounded controlled paid beta evidence bundle, but that does not authorize public payment/order/invoice runtime, subscription runtime, full commercial launch, or Production RC.

Artifact index: `docs/PAID_BETA_EVIDENCE_INDEX.md`. Machine-readable manifest: `project/paid_beta_evidence_index.json`.

## State Model

| State | Meaning | External messaging |
|---|---|---|
| `usage_only_beta fallback/safe mode` | Trusted beta may show usage/cost estimates while paid evidence is incomplete. No real balance debit is promised. | May describe as usage visibility only; do not call it paid. |
| `paid_controlled_beta_requested` | User has allowed implementation and evidence production for paid beta. | Internal implementation track only; blocked until real evidence. |
| `paid_controlled_beta_allowed` | Paid beta may be announced only after every hard gate passes and QA accepts the final evidence bundle. | May describe bounded paid beta only after release review records the accepted evidence bundle. |

Current state: `controlled_paid_beta_evidence_accepted_by_main_review`, `paid_controlled_beta_allowed=true for the accepted controlled evidence bundle only`.

This state is deliberately bounded:

- It supports controlled paid beta evidence and regression review.
- It does not prove public/self-serve commercial billing.
- It does not prove payment provider callback/capture, invoices/receipts, subscription renewal/dunning, or Production RC.
- The current API distribution mainline is trusted-user voucher-backed API Beta; use `project/RELEASE_CHECKLIST.md` and `TODO/OPEN_SOURCE_ALPHA_PRIORITY_2026-06-06.md` for the broader launch sequence.

## Hard Gates Before Paid Allowed

For any new paid-facing expansion beyond the accepted controlled evidence bundle, paid remains blocked until all of these are true in real, fresh, secret-safe evidence:

- Gateway reserve/settle/refund hot path is implemented and exercised.
- Insufficient balance prevents provider call.
- Settle idempotency passes.
- Refund idempotency passes.
- Post-commit readback passes across request log, ledger entry, wallet/balance, and audit/readback surfaces.
- Rollback proof passes and shows no half-write.
- Reconciliation report passes.
- Real evidence bundle is accepted; contract fixtures or templates are not enough.
- QA full gate passes and records the paid acceptance artifact.

## Prohibited Before Paid Allowed

For any scope not covered by the accepted controlled evidence bundle, release, ops, support, and devrel must not:

- Say paid beta is live, launched, enabled, generally available, or ready for users.
- Collect or settle real customer charges.
- Promise strong balance consistency or exact remaining balance.
- Treat dashboard estimates, usage previews, or aggregate charts as the accounting source of truth.
- Use a contract fixture, template, local-only simulation, or plan-only writer as real paid evidence.
- Use old cutover/source-of-truth artifacts as proof of Gateway paid hot path behavior.
- Hide blockers behind a green fallback check; fallback success only means paid did not leak early.

## Operator Verification Commands

These commands are the expected handoff shape. Commands marked pending may be created or finalized by parallel E8/E9/E11/QA lanes.

| Evidence | Owner | Command / artifact | Required result |
|---|---|---|---|
| E9 readiness refusal gate | E9 / Release | `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/release_check.ps1 -Checks billing` | Until paid evidence exists, pass means fallback is safe and paid is refused. After evidence exists, release review must also record the paid-allowed artifact. |
| E9 paid evidence bundle verifier | E9 | `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_billing_paid_evidence_bundle.ps1 -BundlePath <real-paid-evidence-bundle.json>` | `real_evidence_bundle_accepted`; fixture-only accepted shape is not enough. |
| E8 Gateway paid hot path smoke | E8 / Gateway | Pending: `pwsh -NoProfile -ExecutionPolicy Bypass -File <E8 paid hot path smoke script> -Live -EvidenceReportPath <artifact>` | Reserve/settle/refund pass; insufficient balance sends `provider_attempts_count=0`; secret-safe readback. |
| E11 paid readback and reconciliation | E11 / Control Plane | Pending: `pwsh -NoProfile -ExecutionPolicy Bypass -File <E11 paid readback/reconciliation script> -ArtifactPath <artifact>` | Post-commit readback, reconciliation report, rollback proof, and audit/readback markers pass. |
| QA paid acceptance aggregator | QA | Pending: `pwsh -NoProfile -ExecutionPolicy Bypass -File <QA paid acceptance aggregator> -PaidEvidenceBundlePath <artifact>` | Full QA gate pass with `paid_controlled_beta_allowed=true`; artifact is fresh, repo-bounded, non-simulated, and secret-safe. |

See `docs/PAID_BETA_EVIDENCE_INDEX.md` and `project/paid_beta_evidence_index.json` for expected paths, schemas, pass markers, blocked markers, and release-artifact status for each required artifact.

## Release Review Checklist

Before any paid-facing copy, release review must record:

- `paid_controlled_beta_requested=true`.
- `paid_controlled_beta_allowed=true`.
- Paths to E8, E9, E11, and QA artifacts.
- Confirmation that the evidence bundle is real, fresh, non-simulated, and not fixture/template-only.
- Confirmation that no raw prompt, token, Authorization header, Cookie, provider key, virtual key, or DSN appears in artifacts.
- Confirmation that E13/TODO-11 remains Beta pass and is not reopened for browser detail or accepted redeploy evidence.

## User-Facing Limitation Draft

Historical wording while paid was requested but blocked:

```text
Paid beta has been requested and is being implemented behind release gates. Until the paid evidence bundle is accepted, this beta operates in usage-only fallback mode: usage and cost may be shown as estimates, but real balance debits, refunds, and settled billing are not available or promised.
```

Use this wording only for approved controlled paid beta accounts covered by the accepted evidence bundle:

```text
Paid controlled beta is enabled for approved accounts only. Billing is bounded by the configured wallet, budget, and rate-limit policies, and every charge has request-level audit/readback evidence.
```

## Escalation

If any paid hard gate is missing, stale, simulated, fixture-only, or secret-unsafe for a new paid scope, classify that scope as `blocked_until_real_evidence` and keep users on `usage_only_beta fallback/safe mode` or voucher-backed operator-mediated distribution.
