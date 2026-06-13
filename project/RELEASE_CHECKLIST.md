# 发布清单

本清单由人工确认项和可执行 release gate 组成。可执行项以
`scripts/release_check.ps1` 的 JSON summary 为审计记录；人工项需要在
release review 中补充负责人、证据链接和豁免说明。

## TODO-20A Full Local Gate Preflight

同步日期：2026-06-05
权威 TODO：`TODO/`；本文件是 release gate 执行清单，不替代权威 TODO。
Paid beta operator runbook：`docs/PAID_BETA_RUNBOOK.md`。Evidence artifact index：`docs/PAID_BETA_EVIDENCE_INDEX.md`；machine-readable manifest：`project/paid_beta_evidence_index.json`。

Latest current API distribution artifact: `.tmp/launch/final_launch_gate_summary.json`; release summary: `artifacts/launch_voucher_api_distribution_release_check_20260606.json`.
Current scoped status: `ready_to_distribute_api=true`, `production_distribution_ready=true`, `production_distribution_full_ready=false`, `global_blockers=[]`, `qa_release_verdict=pass_with_productization_gaps`. For `internal-trusted-beta-001`, the packet is ready for operator review/API distribution after the 2026-06-07 packet, manifest, quota/rate/budget verifier, and secret scan passed after the latest distribution gate refresh. Post-gate refresh summary: `.tmp/launch/post_gate_target_handoff_refresh_summary.internal-beta-001.json`, `actual_key_handoff_blocked_by_stale_manifest=false`. Default/future-user packets still require external Release/Ops input and are not sendable until their real fields and quota record pass verification. This authorizes only trusted-user voucher-backed API Beta distribution; it does not claim public/self-serve commercial billing, payment/order/invoice runtime, subscription runtime, or Production RC.

E4 Admin UI default price selector browser evidence is now present: `.tmp/control-plane/model_default_price_admin_ui_browser_evidence.json` reports `status=pass` after a Chromium run against the rebuilt local Admin UI and live Control Plane path. It covers admin login, Models navigation, selector option selection, PATCH `/admin/models/{id}`, API readback after set, and restore/readback to the original value without echoing session, cookie, auth, provider-key, or virtual-key secrets.

Open-source Alpha is a separate release lane. Per `TODO/OPEN_SOURCE_ALPHA_PRIORITY_2026-06-06.md`, the current local code-first P0 gate is accepted in `.tmp/open-source-alpha/open_source_alpha_gate.json` with `status=pass`, `run_matrix=true`, and `ready_for_open_source_alpha=true`; it includes Control Plane management parity artifact `.tmp/control-plane/control_plane_management_parity_smoke.json` with `status=pass`, `strict_full_crud=true`, and `secret_safe=true`. Release reviewers must still not use the trusted-user voucher-backed Beta gate as Alpha evidence, and must not use the Alpha gate as full New API replacement/commercial readiness. The clean-clone readiness guard is wired and `status=warn` only because no real clean-clone/CI transcript exists; public tag/release review must rerun that real transcript. P1 parity and P2 commercial productization remain later lanes. Payment/order/invoice and subscription runtime stay `deferred_runtime_external_dependency`. Full wrapper/CI is now green locally: `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1` exit 0, evidence `.tmp/launch/full_wrapper_rerun_20260607_143200_pass.json`.

Historical delta preflight artifact `artifacts/beta_acceptance_preflight_20260605_paid_requested_refresh.json` is no longer the current API distribution source of truth. Its paid/full TODO-20 blockers remain useful historical/regression context, but must not be used to block the 2026-06-06 trusted-user voucher-backed API distribution lane.

### Beta Gate

| Gate | Owner | Required command / artifact | Current status | Blocker |
|---|---|---|---|---|
| Full wrapper gate | Agent-QA | `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1` | `pass` | 2026-06-07 rerun passed end-to-end after fixing `admin::tests::ledger_adjustment_runtime_writer_cutover_blocks_local_execute_commit_until_runtime_branch_ready`. `cargo test --workspace --all-targets --all-features` also passed independently. Evidence: `.tmp/launch/full_wrapper_rerun_20260607_143200_pass.json`. |
| Compose smoke | Agent-QA | `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_compose_smoke.ps1`; full run after services are up | `preflight_pass` | Dry-run passed; runtime compose smoke still pending. |
| SDK smoke | Agent-QA | `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_sdk_smoke.ps1`; full run against Gateway | `preflight_pass` | Dry-run syntax check passed; runtime SDK smoke still pending. |
| E8 / Gateway API distribution proof | Agent-E8 | `.tmp/launch/e8_gateway_paid_hot_path_launch_check.json`; `.tmp/launch/gateway_voucher_distribution_readiness.json` | `current_launch_proof_passed` | Current launch evidence proves insufficient-balance 402/no-provider-call with zero provider attempts and Gateway voucher readiness. TODO-12 historical reservation work remains regression/RC context unless this launch proof regresses. |
| E11 billing mutation artifact readback | Agent-E11 / QA | `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1 -ControlPlaneLedgerAdjustmentExecuteBrowserReadbackOnly`; reads `artifacts/control_plane_ledger_execute_runtime_current_verified_beta.json` and `artifacts/billing_execute_browser_live_e2e_evidence.json` | `release_readback_pass` | Pass requires current commit, `runtime_current_verified`, `mutation_pass_artifact_passed`, `artifact_readback_passed`, API/DB/UI/audit readback markers, numeric durations, and secret-safe artifact output. Missing, stale, simulated, wrong-commit, or runtime-current-unverified artifacts block release. |
| E13 prompt protection | Agent-E13 | `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_prompt_protection_postgres_proof.ps1 -ContractOnly`; read `.tmp/prompt_protection_beta_closure_review_report.json` | `beta_pass_readback_pass` | Main thread accepted TODO-11 Beta pass; artifact readback shows status passed, 4 live request ids, provider attempts zero, runtime/current rows 4/4, provenance pass, secret-safe pass. |
| E9 billing / voucher accounting posture | Agent-E9 / Product | `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/release_check.ps1 -Checks launch`; `.tmp/launch/voucher_backed_api_distribution_accounting_gate.json`; `.tmp/launch/voucher_quota_pricing_guardrails.json` | `launch_ready_with_productization_gaps` | For current API distribution, voucher-backed accounting and quota guardrails are ready with productization gaps. Do not reclassify full paid/commercial payment/order/subscription runtime gaps as global blockers for trusted-user voucher-backed Beta. |
| Secret scan | Agent-QA / Security | `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/scan_secrets.ps1` | `pass` | MISC-Security-S1 fixed selftest marker false positives without relaxing scanner rules; latest scan hits=0, warnings=0. |
| Supply-chain scan | Agent-QA / Security | `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/scan_supply_chain.ps1 -SkipNetwork` | `preflight_pass_with_warnings` | Offline scan passed with warnings: missing `trivy`/`grype` and digest pinning gaps. |
| Admin UI dependency gate | Agent-QA / Frontend | `npm --prefix web/admin-ui ci`, `npm --prefix web/admin-ui test`, `npm --prefix web/admin-ui run build`, `npm --prefix web/admin-ui run check:bundle` | `regression_or_full_wrapper_pending` | Lockfile exists; full npm gate is still full-wrapper coverage, not a blocker for the scoped API handoff packet unless selected-user evidence requires Admin UI behavior that cannot be verified. |
| E4 Admin UI default price selector browser evidence | Agent-E4 / Frontend | `node web/admin-ui/scripts/model-default-price-browser-evidence.mjs`; `.tmp/control-plane/model_default_price_admin_ui_browser_evidence.json` | `pass` | Chromium evidence covers login, Models navigation, selector set, PATCH observation, API readback, restore, and secret-safe output. |
| API distribution summary | Agent-QA | `.tmp/launch/final_launch_gate_summary.json`; `artifacts/launch_voucher_api_distribution_release_check_20260606.json` | `ready_with_productization_gaps` | Current summary has `ready_to_distribute_api=true` and `global_blockers=[]`; fill per-user fields before actual key handoff. |

### Voucher-Backed API Beta Distribution

Current launch policy: trusted-user API distribution is the intended path through operator-issued virtual keys plus voucher/redeem-code quota evidence. Current QA verdict is `ready_with_productization_gaps` for that scoped trusted-user Beta path after the per-user packet is filled. This does not claim full payment/order/invoice runtime, full subscription/package runtime, or self-serve commercial billing. Missing provider/callback/capture capability and scheduler/provider/invoice runtime are deferred external dependencies with resume conditions, not active launch blockers for voucher-backed Beta.

Evidence posture:

- Recharge/voucher internal runtime is verified: `scripts/verify_credit_wallet_ledger_surface.ps1` reports `recharge_voucher_runtime_verified=true` from `.tmp/credit-wallet/recharge_voucher_runtime.json`.
- Public recharge/voucher routes are now wired behind `BillingAdjust`; route-level live invocation evidence has passed with request invocation, auth/RBAC or ownership scope, idempotency, redaction, audit, ledger/credit readbacks, refusal no-write, `secret_safe=true`, and `paid_gate_changed=false`. Public/self-serve Product UX remains a productization gap.
- User remaining-balance runtime is verified: `user_remaining_balance_runtime_verified=true`.
- Gateway current launch paid-hot-path evidence now passes: insufficient balance returns 402/no-provider-call with zero provider attempts, and reserve/settle/release/refund readbacks are present.
- Payment/order/invoice runtime is deferred and false: `payment_order_invoice_runtime_verified=false`.
- Subscription/package runtime is deferred and false: `subscription_package_lifecycle_runtime_verified=false`.

External dependency bypass register for release review:

| blocker_id | Missing external input | Current bypass path | Resume condition / command |
|---|---|---|---|
| `auth_client_oidc_external_dependency` | Hosted Auth client or OIDC provider, redirect/callback URLs, tenant/user ownership mapping, public session lifecycle/security policy, support owner. | Operator-mediated trusted-user virtual-key handoff; do not require public Auth client for scoped voucher-backed Beta API distribution. | Resume when Auth client/provider policy exists; run login/session/ownership live proof using `scripts/verify_route_level_live_http_proof.ps1` or equivalent and require secret-safe artifact plus `paid_gate_changed=false`. |
| `payment_order_invoice_external_runtime_deferred` | Payment gateway/provider, callback/capture runtime, invoice/receipt/refund/chargeback/reconciliation policy, or approved bounded internal simulation. | Voucher/redeem-code quota plus ledger/readback evidence; keep TODO-32J runtime false/deferred and do not claim public payment readiness. | Resume with provider/callback/capture or approved simulation; run `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_payment_order_invoice_runtime.ps1` and archive accepted runtime artifact. |
| `subscription_package_runtime_external_dependency` | Scheduler/renewal trigger, provider/invoice/order linkage runtime, trial/proration/dunning policy, cancel/pause/resume behavior, reconciliation/support owner. | One-off voucher-backed quota; keep TODO-32K runtime false/deferred and do not claim subscription readiness. | Resume with scheduler/provider/invoice policy; run `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_subscription_package_lifecycle_runtime.ps1` and archive accepted runtime artifact. |
| `public_self_serve_ux_productization_external_dependency` | Product-approved self-serve screens/client flow, quota/rate budget selection UX, user-facing errors, final handoff metadata capture, support/rollback owner and copy approval. | Operator-mediated virtual-key issue and voucher quota; backend route wiring/proof is not public self-serve UX. | Resume when Product/Frontend/Ops approve flow; run UI/API E2E plus route-level proof showing ownership, idempotency, audit, ledger/credit readback, refusal no-write, `secret_safe=true`, and `paid_gate_changed=false`. |

Operator flow:

1. Issue or assign the trusted user's virtual key; store only bounded identifiers in the release record.
2. Provide or redeem voucher quota through the accepted operator/internal voucher flow; record voucher/campaign ids and redacted code metadata only.
3. Verify the user's remaining balance through the accepted remaining-balance readback before sending traffic.
4. Run the Gateway call path with the assigned virtual key; capture bounded request ids, rate-limit state, provider-attempt summary, and ledger/readback status.
5. Confirm rate-limit and budget guardrails for the trusted user are configured and documented.
6. Record audit/support notes with owner, tenant/project/wallet ids, bounded request ids, voucher ids, and expected quota.
7. Rollback by disabling/revoking the virtual key, revoking or expiring the voucher/credit quota, and rechecking remaining balance and audit/readback.

Do not expose raw voucher/redeem codes after issuance, full virtual keys, `Authorization` or `Cookie` headers, provider keys, DB URLs, raw provider payloads, raw request bodies, raw idempotency keys, or unredacted secret material in logs, docs, tickets, screenshots, or release notes.

QA-LAUNCH-02 gate artifact: `.tmp/launch/voucher_api_distribution_readiness.json`; release summary: `artifacts/launch_voucher_api_distribution_release_check_20260606.json`.

Current launch verdict: `ready_with_productization_gaps`. Trusted-user voucher-backed Beta API distribution may proceed after the per-user handoff packet is filled for the target tenant/project/user/wallet/quota. Current artifacts: `.tmp/launch/voucher_api_distribution_readiness.json` is `pass_with_productization_gaps` with `production_distribution_ready=true`; `.tmp/launch/voucher_backed_api_distribution_accounting_gate.json` is `launch_ready_with_productization_gaps`; `.tmp/launch/e8_gateway_paid_hot_path_launch_check.json` is `passed`; `.tmp/launch/gateway_voucher_distribution_readiness.json` is `pass`; `.tmp/launch/voucher_public_route_and_virtual_key_evidence.json` is `pass` with route wiring present and live invocation verified; `.tmp/launch/voucher_quota_pricing_guardrails.json` is `pass`; release summary `artifacts/launch_voucher_api_distribution_release_check_20260606.json` is `overallStatus=warn` because productization gaps remain. Public/self-serve Product UX, full payment/order/invoice runtime, and subscription/package runtime are deferred/resume-condition items and are not blockers for this voucher-backed trusted-user Beta scope.

Request/trace/usage explainability evidence is now live, metadata-only, and secret-safe: `.tmp/launch/request_trace_usage_live_admin_api_readback.json` reports `overall_status=pass`, `request_id_count=11`, `trace_id_count=5`, `wallet_id_count=1`, and `api_distribution_blocker=false`. It reads request detail, trace summary, request-linked ledger entries, audit logs, and remaining balance without calling `/payload` or writing token/header/raw body/provider secret material.

The full distribution gate now runs that TODO-14 live readback directly. Current `.tmp/launch/final_launch_gate_summary.json` records `request_trace_live_gap_readiness=ready_for_live_readback` and `request_trace_live_admin_api_readback=pass`; `.tmp/launch/post_gate_target_handoff_refresh_summary.internal-beta-001.json` records the post-gate internal target refresh with `final_gate_request_trace_live_admin_api_readback=pass`, `target_handoff_ready_to_send=true`, `quota_ready_for_handoff=true`, and `actual_key_handoff_blocked_by_stale_manifest=false`.

Trusted-user packet orchestrator: use `scripts/prepare_trusted_user_api_distribution_packet.ps1` first for Release/Ops handoff. It regenerates the quota/rate/budget template, writes/verifies `.tmp/launch/trusted_user_distribution_review_packet.json` or a target-user packet path, runs launch release check, runs secret scan, and writes `.tmp/launch/trusted_user_api_distribution_handoff_summary.json`. The summary includes `evidence_manifest` with repo-bounded artifact paths, SHA256 hashes, sizes, schemas, statuses, and blocker/missing-field counts for packet, release, quota, accounting, Gateway, guardrail, voucher route, operator, remaining-balance, and voucher runtime evidence. The filled `internal-trusted-beta-001` packet uses target-user paths and is ready; if the default artifacts still report `ready_to_send=false`, treat it as future-user per-user packet incompleteness: fill release owner, support contact, bounded tenant/project/user/wallet ids or `trusted_user_id_or_owner_ref`, voucher quota, rate/budget guardrail record, rollback owner, bounded evidence links, and `real_user_values_present=true` before handing a specific key to another trusted user. If the selected user id is `internal-trusted-beta-001`, describe it only as a CTO-designated internal trusted Beta user, not as external customer delivery, public self-serve access, full commercial launch, or public payment/subscription readiness. `scripts/verify_trusted_user_distribution_review_packet.ps1 -WriteDefaultPacket` remains a focused QA verifier, not the primary operator handoff entry point.

QA-LAUNCH-08 reviewer handoff summary: `.tmp/launch/final_launch_gate_summary.json` is generated by `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1 -FullDistributionGateOnly`. It records `ready_to_distribute_api=true`, `production_distribution_ready=true`, `production_distribution_full_ready=false`, `global_blockers=[]`, per-user external handoff inputs, non-blocking deferred TODO-32J/TODO-32K items, synthetic handoff rehearsal status, manifest/quota verifier selftest status, default missing quota-record classification, and a manifest current-readback section that recalculates SHA256/size for every handoff evidence entry.

Operator handoff for trusted-user Beta:

- Evidence that exists: internal recharge/voucher runtime is verified; user remaining-balance runtime is verified; controlled paid beta accounting evidence exists; Gateway paid-balance launch evidence now passes; virtual-key bounded route contract evidence exists; QA launch gate passes with productization gaps.
- Before key handoff, run `scripts/prepare_trusted_user_api_distribution_packet.ps1` with real per-user values: release owner, support contact, tenant/project/wallet ids, voucher/quota amount, rate/budget limits, rollback owner, bounded request/audit ids, and secret-safe evidence links. Archive the target-user handoff summary because it carries the final verdict and evidence hash manifest.
- Before key handoff, verify the archived target-user summary manifest:
  `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1 -SummaryPath .tmp/launch/trusted_user_api_distribution_handoff_summary.<trusted-user-id>.json`
- Before key handoff, verify the real target-user quota/rate/budget record:
  `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_trusted_user_quota_rate_budget_record.ps1 -RecordPath .tmp/launch/trusted_user_quota_rate_budget_record.<trusted-user-id>.json -EvidenceManifestPath .tmp/launch/trusted_user_api_distribution_handoff_summary.<trusted-user-id>.json -OutputPath .tmp/launch/trusted_user_quota_rate_budget_record_verification.<trusted-user-id>.json`
  Run the orchestrator, manifest verifier, quota verifier, and final secret scan sequentially; do not parallelize commands that refresh or read `.tmp/launch` artifacts. In the default one-key gate, `.tmp/launch/trusted_user_quota_rate_budget_record_verification.json` may report `status=blocked_runtime_input_required` with blocker `real_per_user_quota_rate_budget_record_required`; that is a per-user handoff blocker only and must become exit 0 with a real `<trusted-user-id>` record before an actual key is sent.
- Freshness guard: after `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1 -FullDistributionGateOnly`, `scripts/release_check.ps1 -Checks launch`, or an Alpha dry-run/matrix run that rewrites default launch/alpha artifacts, rerun the target-user/internal-beta packet command and then rerun `scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1 -SummaryPath .tmp/launch/trusted_user_api_distribution_handoff_summary.<trusted-user-id>.json`. Do not reuse an older handoff summary: the verifier now rejects stale bytes/SHA256 and any manifest entry whose artifact was refreshed after the summary timestamp.
- Explicitly not full commercial: public voucher routes are wired and live route invocation proof has passed, but Product UX remains open; the scoped Beta may use the accepted operator-mediated handoff flow, but that does not close public/self-serve readiness. Payment/order/invoice runtime and subscription/package runtime remain deferred external dependencies with resume conditions.
- For final packet review, rerun `scripts/release_check.ps1 -Checks launch -SummaryPath artifacts/launch_voucher_api_distribution_release_check_20260606.json`, `scripts/verify_voucher_backed_api_distribution_accounting_gate.ps1`, `scripts/verify_credit_wallet_ledger_surface.ps1`, and `scripts/scan_secrets.ps1`; archive the launch, accounting, credit-wallet, and secret-scan artifacts.

Artifact map:

| Artifact | Owner lane | Current status | Use in handoff |
|---|---|---|---|
| `.tmp/launch/voucher_api_distribution_readiness.json` | QA-LAUNCH | `pass_with_productization_gaps`; `production_distribution_ready=true` | Reconciled launch gate for voucher-backed trusted-user Beta. |
| `.tmp/launch/voucher_backed_api_distribution_accounting_gate.json` | E9-LAUNCH | `launch_ready_with_productization_gaps` | Accounting map for voucher-backed credit. |
| `.tmp/launch/e8_gateway_paid_hot_path_launch_check.json` | E8-LAUNCH | `passed` | Current paid-balance enforcement proof, including insufficient-balance 402/no-provider-call. |
| `.tmp/launch/gateway_voucher_distribution_readiness.json` | E8-LAUNCH / E9-LAUNCH | `pass` | Gateway readiness rollup; current-runtime evidence precedence. |
| `.tmp/launch/voucher_public_route_and_virtual_key_evidence.json` | E11-LAUNCH | `pass`; voucher public routes wired; live route invocation verified; virtual-key bounded contract verified | Route and virtual-key evidence source; do not claim full public/self-serve readiness until Product UX and commercial runtime gaps close. |
| `.tmp/launch/voucher_operator_only_exception.json` | E11-LAUNCH / Product-Ops | `unapproved`; `route_substitution_allowed=false` | Possible route substitute only after explicit approval. |
| `.tmp/launch/api_distribution_operator_packet.json` | E11-LAUNCH / Ops | `blocked`; `ready_to_send=false` | Operator packet with bounded links; fill per user before handoff. |
| `.tmp/launch/trusted_user_distribution_review_packet.json` | QA-LAUNCH / Release-Ops | `ready_to_send=false` | Trusted-user packet checklist; fill per user before handoff. |
| `.tmp/launch/trusted_user_distribution_review_packet.internal-beta-001.json`; `.tmp/launch/trusted_user_api_distribution_handoff_summary.internal-beta-001.json`; `.tmp/launch/trusted_user_quota_rate_budget_record.internal-beta-001.json`; `.tmp/launch/trusted_user_quota_rate_budget_record_verification.internal-beta-001.json` | Release-Ops / E9 / QA | `ready_to_send=true`; manifest/quota verification pass; secret scan pass | CTO-designated internal trusted Beta packet only; not evidence of public/self-serve or external-customer launch. |
| `.tmp/launch/voucher_quota_pricing_guardrails.json` | E9-LAUNCH / Product-Ops | `pass` | Voucher quota/pricing/rate guardrail map. |
| `.tmp/launch/request_trace_usage_live_admin_api_readback.json` | OBS / E11 / QA | `pass`; 11 request ids, 5 traces, 1 remaining-balance wallet surface; metadata-only and no payload preview | Operator troubleshooting evidence for request/trace/usage/cost/ledger/audit/balance readback. |
| `.tmp/control-plane/model_default_price_admin_ui_browser_evidence.json` | E4 / Admin UI | `pass`; Chromium login, Models navigation, default price selector PATCH, API readback, restore/readback, secret-safe | Browser evidence for default price book selector operation against live compose Admin UI/Control Plane. |
| `.tmp/importers/provider_key_operator_handoff/summary.json` | E12 Importer | `pass`; New API and One API provider-key handoff packets metadata-only; raw provider keys not written | Importer provider-key handoff evidence for operator-created keys; real secret create/readback remains deferred until operator secret exists. |
| `artifacts/launch_voucher_api_distribution_release_check_20260606.json` | Release / QA-LAUNCH | `warn` | Release-check summary; warning documents productization gaps. |
| `scripts/scan_secrets.ps1` output | QA / Security | latest run `pass` | Secret-safety gate; rerun and archive with final packet. |

Docs index for trusted-user Beta:

| Entry | Path | Current status | Reviewer use |
|---|---|---|---|
| Developer quickstart contract | `.tmp/launch/developer_api_distribution_quickstart_contract.json` | reviewer material | Developer-facing API distribution instructions contract for trusted-user Beta; do not present as full commercial launch docs. |
| Operator packet | `.tmp/launch/api_distribution_operator_packet.json` | per-user completion required if `ready_to_send=false` | Operator handoff packet with bounded evidence links and rollback steps. |
| Trusted-user packet | `.tmp/launch/trusted_user_distribution_review_packet.json` | per-user completion required if `ready_to_send=false` | Release/Ops checklist for owner, quota, support, rollback, and evidence fields. |
| Waiver / operator-only policy | `.tmp/launch/voucher_operator_only_exception.json` | `unapproved`; `route_substitution_allowed=false` | Documents possible operator-only route substitute; cannot be used without explicit approval. |
| Gateway diagnostics | `.tmp/launch/gateway_distribution_diagnostics_bundle.json`; `.tmp/launch/gateway_distribution_operator_smoke_plan.json` | diagnostics retained; current E8 launch check passed | Gateway paid-balance diagnostics and rerun plan. |
| Launch gate summary | `.tmp/launch/voucher_api_distribution_readiness.json`; `artifacts/launch_voucher_api_distribution_release_check_20260606.json` | launch gate `pass_with_productization_gaps`; release check `warn` | Trusted-user Beta go/no-go artifacts with productization gaps. |

Entries above authorize only the trusted-user voucher-backed Beta scope. The `internal-trusted-beta-001` target-user packet is completed; default/future-user packets still require their own real per-user values and quota/rate/budget record. These entries do not authorize full commercial/public payment or subscription launch.

Executable gate:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1 -FullDistributionGateOnly
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/release_check.ps1 -Checks launch -SummaryPath artifacts/launch_voucher_api_distribution_release_check_20260606.json
```

### Paid Beta Gate

Paid release review must use `docs/PAID_BETA_RUNBOOK.md`, `docs/PAID_BETA_EVIDENCE_INDEX.md`, and `project/paid_beta_evidence_index.json`. Paid Beta is not the source of truth for the current trusted-user voucher-backed API distribution gate. Main review accepted controlled paid beta evidence for the bounded paid evidence bundle, but this does not claim full commercial credit-product readiness, payment/order/invoice productization, subscription runtime, or Production RC. Historical blocked-until-real-evidence artifacts from 2026-06-05 are superseded for current launch coordination and should not be used as API distribution global blockers.

| Gate | Owner | Required command / artifact | Current status | Blocker |
|---|---|---|---|---|
| Billing mode decision | Agent-E9 / Product | `docs/P0_BETA_STATUS.md`; paid evidence index artifacts | `controlled_paid_beta_evidence_accepted_by_main_review` | Accepted controlled paid beta evidence remains bounded evidence, not full commercial/public payment readiness and not a current API distribution blocker. |
| Paid readiness gate | Agent-E9 / Release | `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_billing_beta_mode_readiness.ps1 -BillingMode paid_controlled_beta -PaidEvidenceBundlePath .tmp/paid-beta/real_paid_evidence_bundle.json` | `accepted_for_controlled_paid_beta_evidence` | Keep contract-shape/synthetic bundles blocked; do not extrapolate the accepted bundle to public payment/order/invoice or subscription runtime completion. |
| Paid acceptance aggregator | Agent-QA / Release | `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_acceptance.ps1 -OutputPath artifacts/beta_acceptance_paid_aggregator_<run_id>.json` | `accepted_by_main_review` | Final accepted aggregator exists for controlled paid beta evidence; older qapaid02/qapaid03 blocked artifacts are historical. |
| Paid artifact consumer contract | Agent-QA / Release | `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_artifact_contracts.ps1` | `pass_for_accepted_artifacts` | Consumer contract is a paid-evidence regression guard. It is separate from voucher-backed trusted-user API distribution readiness. |
| Paid stale-copy guard | Agent-QA / Release | `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_status_copy_guard.ps1` | `pass` | Guards current TODO/P0/release docs/scripts against stale copy that says paid was not requested or usage-only is the sole posture; historical slice records are not in the default scan scope. |
| Paid evidence artifact index | Release / QA | `docs/PAID_BETA_EVIDENCE_INDEX.md`; `project/paid_beta_evidence_index.json` | `accepted_evidence_index_current` | Lists accepted controlled paid beta evidence and caveats; use it for paid regression review, not as the current API distribution global gate. |
| Public payment/order/invoice runtime | Agent-E9 + Product/Ops | TODO-32J / provider callback/capture evidence | `deferred_productization_gap` | Not complete and not claimed. Required before public/full commercial payment flows, not before trusted-user voucher-backed API Beta. |
| Subscription/package runtime | Agent-E9 + Product/Ops | TODO-32K / scheduler-provider-invoice evidence | `deferred_productization_gap` | Not complete and not claimed. Required before subscription launch, not before trusted-user voucher-backed API Beta. |
| User-facing limitations | Release / DevRel Ops | `docs/PAID_BETA_RUNBOOK.md` limitation draft | `bounded_caveats_required` | Materials must distinguish accepted controlled paid evidence from full commercial/payment/subscription productization. |
| Paid Beta summary | Agent-QA | Paid Beta acceptance artifact | `accepted_for_controlled_paid_beta_evidence` | Keep as regression artifact; current API distribution next step is per-user packet completion. |

### Production RC Gate

| Gate | Owner | Required command / artifact | Current status | Blocker |
|---|---|---|---|---|
| Production tokenizer/read-model | Agent-E8 | TODO-40 runner + Gateway live smoke + DB readback artifact | `rc_backlog` | Not a Beta blocker. |
| ClickHouse production smoke | Agent-E15 | TODO-41 same-session ClickHouse smoke artifact | `rc_backlog` | Not a Beta blocker. |
| Staging/Helm/load/chaos/security | Agent-Ops / Security | TODO-42 staging deploy, 1,000 stream load, chaos, SBOM/image/dependency/secret scans | `rc_backlog` | Requires staging/RC environment and final Beta closure first. |
| Production RC summary | Agent-QA / Release | RC readiness summary artifact | `not_generated` | Blocked until RC backlog gates pass. |

## 可执行 release gate

默认命令：

```powershell
.\scripts\release_check.ps1
```

默认模式只执行安全的 check/dry-run：

- `format`：`cargo fmt --check`。
- `test`：Rust workspace tests。
- `frontend`：Admin UI typecheck 和 test。
- `build`：Rust workspace build、Admin UI build、bundle budget。
- `security`：secret scan、supply-chain structural scan，并生成 SBOM/provenance/manifest/SHA256SUMS artifacts；网络审计默认关闭，发布候选可加 `-OnlineSecurity`。
- `billing`：Paid Beta evidence regression gate；当前受控 paid evidence 已由 main review 接受，但它不替代 voucher-backed API distribution gate，也不声明 public payment/order/invoice、subscription runtime 或 Production RC 完成。
- E11 ledger execute artifact readback：`scripts/test.ps1 -ControlPlaneLedgerAdjustmentExecuteBrowserReadbackOnly` 只读读取 runtime-current 和 browser mutation artifacts；不启动 live mutation，不读取或打印 Admin session secret。
- `backup`：PostgreSQL backup preflight；只检查计划，不创建目录，不执行 `pg_dump`。
- `helm`：静态 Helm chart 校验；安装 Helm 时额外运行 `helm lint` 和 `helm template`。
- `smoke`：compose smoke 与 SDK smoke 的 dry-run 自检；只有显式 `-RunRuntimeSmoke` 才请求本机运行中的服务。

机器可读 summary 写到 stdout；需要归档时：

```powershell
.\scripts\release_check.ps1 -SummaryPath .\artifacts\release-gate-summary.json
```

本机缺少 `Docker`、`Helm`、`pg_dump`、`node` 或 `npm` 时，默认 dry-run/preflight
会把对应 runtime/chart/backup/SDK smoke 缺口记录为 `warn` 或 `skip`，并以
`local warning:` 开头，不打印 secret/env 原文。显式请求 runtime 操作时，缺少必需工具
仍是 `fail`。CI 或 release review 如需把 warning 当作阻断项，使用：

```powershell
.\scripts\release_check.ps1 -TreatWarningsAsFailures
```

局部验证示例：

```powershell
.\scripts\release_check.ps1 -Checks backup,helm,smoke
.\scripts\release_check.ps1 -Checks billing
.\scripts\test.ps1 -BillingBetaModeReadinessOnly
.\scripts\verify_paid_beta_acceptance.ps1
.\scripts\verify_paid_beta_acceptance.ps1 -SelfTest
.\scripts\verify_paid_beta_status_copy_guard.ps1
.\scripts\test.ps1 -ControlPlaneLedgerAdjustmentExecuteBrowserReadbackOnly
```

GitHub 首次 push 前本地收口必须至少执行并归档：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/release_check.ps1 -Checks security
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/release_check.ps1 -Checks billing
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/release_check.ps1 -Checks backup,helm,smoke
.\scripts\scan_secrets.ps1
```

首推前判定：

- `security` gate 必须通过，且 `artifacts/supply-chain` 中的 SBOM、provenance、manifest 和 checksum 输出需要作为本地证据保留；默认 `security` 不做联网漏洞审计，RC 或正式发布评审需要联网审计时补跑 `-OnlineSecurity`。
- `billing` gate 如纳入评审，必须按 paid evidence index 解释；pass 只说明受控 paid evidence 或其回归守卫符合当前索引，不表示 public payment/order/invoice、subscription runtime、full commercial credit productization 或 Production RC 已完成。
- E11 artifact readback gate 必须通过；stdout 需要包含 `e11_release_artifact_readback_status=pass`、`e11_release_runtime_current_verified=true`、`e11_release_mutation_pass_artifact_passed=true`、`e11_release_artifact_readback_passed=true`、`e11_release_secret_safe=true`。缺失 runtime-current artifact、错 commit、stale/simulated marker、`artifact_readback_failed`、raw `Authorization`/session/Cookie/provider key/virtual key material 都阻断发布。
- `backup,helm,smoke` 可以在缺本机工具时返回 `overallStatus=warn`，但每条 `local warning:` 都必须登记补跑环境和负责人；这些 warning 只说明本机 dry-run/preflight 没有完整覆盖，不代表 staging 已通过。
- `scripts\scan_secrets.ps1` 是首推前额外安全回归，不能用 release gate 中某条 warning 抵消；失败时阻断 push。
- 首推前不要记录或粘贴任何 secret/env 原文；命令输出和归档 summary 如出现疑似 secret，应先修复脚本脱敏或删除证据后重跑。

JSON 判定：

- `overallStatus=pass`：可执行门禁通过。
- `overallStatus=warn`：没有失败，但存在 skip/warning；常见原因是本机缺工具、未配置 DB 或默认跳过网络/runtime 扫描。release review 必须记录是否接受，并说明补跑环境。
- `overallStatus=fail`：至少一个 check 失败，或使用 `-TreatWarningsAsFailures` 后 warning/skip 被提升为失败；阻断发布，除非有明确负责人签字豁免。

## Release Candidate 前

- [ ] 所有 P0 issue 关闭或有明确豁免。
- [ ] `scripts/release_check.ps1` 全量 summary 已归档，且 `overallStatus` 为 `pass` 或有已批准豁免。
- [ ] `scripts/release_check.ps1 -Checks launch`、`.tmp/launch/final_launch_gate_summary.json` 和 `artifacts/launch_voucher_api_distribution_release_check_20260606.json` 已归档；`ready_to_distribute_api=true` 仅解释为 trusted-user voucher-backed Beta，且 per-user 字段缺失只阻止实际 handoff。
- [ ] `docs/PAID_BETA_RUNBOOK.md` 已在 release review 中确认；对外材料必须区分受控 paid evidence、trusted-user voucher-backed API Beta、full commercial payment/order/invoice、subscription runtime 和 Production RC。
- [ ] `docs/PAID_BETA_EVIDENCE_INDEX.md` 中每个 paid evidence artifact 都有 current-run artifact path、schema/pass marker 和 owner sign-off；blocked/pending 行只阻断其对应 paid/commercial scope，不自动阻断当前 voucher-backed API distribution。
- [ ] `project/paid_beta_evidence_index.json` 已通过 JSON parse/readback，并与 Markdown index 的 required artifact list 对齐。
- [ ] `scripts/test.ps1 -ControlPlaneLedgerAdjustmentExecuteBrowserReadbackOnly` 已归档；E11 runtime-current/browser mutation artifacts current/readback pass，且无 secret material 输出。
- [ ] CI 全量通过，并与 release gate summary 对齐。
- [ ] E2E 全量通过。
- [ ] Load test 报告归档。
- [ ] Chaos test 报告归档。
- [ ] 安全扫描无高危；`security` gate 已生成并归档 SBOM/provenance/manifest/SHA256SUMS artifacts；如 `security` gate 为 `warn`，需记录原因和补跑计划。
- [ ] 数据库 migration 在 staging 验证。
- [ ] `backup` gate 已在具备 `pg_dump` 和数据库连接配置的环境执行 preflight。
- [ ] `helm` gate 已在具备 Helm 的环境执行 lint/template。
- [ ] `smoke` gate 已完成 dry-run；上线前 staging/runtime smoke 已按需执行并归档结果。dry-run warning 不能替代 staging 验收。
- [ ] GitHub 首次 push 前，本地 `security`、`backup,helm,smoke` 和 `scripts\scan_secrets.ps1` 已执行；如存在本机缺工具 warning，已记录补跑计划，且没有声称 staging 已完成。
- [ ] 监控 dashboard 准备完成。
- [ ] 告警 webhook 配置完成。
- [ ] Runbook 更新。

## Staging

- [ ] 部署新版本。
- [ ] 执行 migration。
- [ ] 使用真实 SDK smoke test。
- [ ] 验证账务 ledger。
- [ ] 验证日志和 trace。
- [ ] 验证回滚脚本。

## Production Canary

- [ ] 5% 流量 canary。
- [ ] 观察错误率、fallback rate、ledger lag、latency。
- [ ] 无异常扩大到 50%。
- [ ] 无异常全量。
- [ ] 发布 release notes。

## 回滚

- [ ] 上一版本镜像可用。
- [ ] 配置版本可回滚。
- [ ] 数据库变更有前向修复方案。
- [ ] 回滚责任人和沟通渠道明确。
