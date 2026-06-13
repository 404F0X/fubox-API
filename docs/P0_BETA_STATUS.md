# P0 / Beta 当前状态

同步日期：2026-06-07
权威 TODO 来源：`TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md`、`TODO/AI_GATEWAY_AGENT_EXECUTION_PACK_2026-06-05.md`、`TODO/AI_GATEWAY_TOD_TECH_DEBT_2026-06-05.md`

本文件只是状态摘要视图；若与 `TODO/` 目录冲突，以 `TODO/` 为准。

## 里程碑口径

| 里程碑 | 判断口径 | 当前状态 |
|---|---|---|
| Local P0 | 本地 compose、dev seed、mock provider、dev admin、local Postgres/Redis 可证明核心链路跑通 | 当前本机通过；Gateway/Control Plane/Admin UI/Postgres/Redis/mock-provider 已启动并完成 API 分发主路径自测 |
| Distribution-ready API Beta | 可信用户可拿 virtual key 调 Gateway；Admin 可配置和排障；日志、审计、usage/cost 可读；限流/预算有保护 | 当前主线：trusted-user voucher-backed API distribution `ready_with_productization_gaps`；`internal-trusted-beta-001` packet 已 ready，future-user 仍需填真实 per-user packet 和 quota/rate/budget record 后才能分发 API |
| Paid Beta | 支持真实余额、扣费、退款、幂等对账 | Main review accepted controlled paid beta evidence: `paid_controlled_beta_allowed=true` for the accepted evidence bundle. This is not full Production RC; the bounded smoke refund endpoint is dev evidence only, and partial refund policy/deeper reconciliation remain RC work. Operator/devrel guardrail: `docs/PAID_BETA_RUNBOOK.md`; evidence index: `docs/PAID_BETA_EVIDENCE_INDEX.md`; manifest: `project/paid_beta_evidence_index.json`. |
| Open-source Alpha / Preview | 外部开发者 clean clone 后可按 README/Compose 启动本地栈、创建或使用 virtual key、调用 OpenAI-compatible API、查看日志/余额/限流证据 | Local code-first Alpha gate pass：2026-06-07 `.tmp/open-source-alpha/open_source_alpha_gate.json` 为 `status=pass`、`ready_for_open_source_alpha=true`、`blockers=[]`。公开 release 前仍需 clean clone/CI 复验 |
| New API / One API replacement parity | import apply/rollback、model/channel/key 管理、trace/cost explainability、budget/rate-limit hardening 可由外部用户操作并验收 | P1 backlog；trusted-user Beta 证据不能替代这些 parity/runtime 证据 |
| Commercial productization | public/self-serve voucher UX、payment/order/invoice runtime、subscription lifecycle runtime | P2 backlog；TODO-32J/TODO-32K 继续保持 `deferred_runtime_external_dependency`，不因 voucher-backed Beta 通过而改口 |
| Production RC | staging/K8s、load/chaos/security、真实 tokenizer、ClickHouse、备份恢复演练 | 后置，不阻塞 Beta |

Current launch summary: `.tmp/launch/final_launch_gate_summary.json` records `ready_to_distribute_api=true`, `production_distribution_ready=true`, `production_distribution_full_ready=false`, and `global_blockers=[]`. Interpret this strictly as scoped trusted-user voucher-backed API Beta readiness. For `internal-trusted-beta-001`, the 2026-06-07 target-user packet is ready after packet review, manifest verification, quota/rate/budget verification, and secret scan passed. Default/future-user packets may still report missing real user fields or quota record as external input; that default state is intentional and does not regress the internal packet. Public voucher routes, payment/order/invoice runtime, and subscription runtime remain productization/deferred gaps and are not claimed complete.

TODO-14 live readback closure: `.tmp/launch/request_trace_usage_live_admin_api_readback.json` now reports `overall_status=pass`, `live_admin_readback_performed=true`, `request_id_count=11`, `trace_id_count=5`, `wallet_id_count=1`, `api_distribution_blocker=false`, and `blocker_classification=none`. The verifier reads `/admin/request-logs/{id}`, `/admin/traces/{trace_id}`, `/admin/ledger/entries?request_id=...`, `/admin/audit-logs?limit=500`, and `/billing/wallets/{wallet_id}/remaining-balance` with secret-safe metadata-only output. It explicitly does not call `/payload` and does not write session tokens, Authorization/Cookie headers, raw request/response bodies, provider secrets, or full virtual keys. `scripts/test.ps1 -FullDistributionGateOnly` now runs both `-LiveGapReadiness` and `-LiveApiReadback`; current gate status records `request_trace_live_admin_api_readback=pass`.

Post-gate target-user freshness: `scripts/test.ps1 -FullDistributionGateOnly` can refresh shared launch artifacts and therefore mark an already-created target-user handoff summary as stale at gate time. The required operational sequence is to run the gate, then regenerate/reverify the target-user handoff before actual key handoff. Current post-gate artifact `.tmp/launch/post_gate_target_handoff_refresh_summary.internal-beta-001.json` reports `actual_key_handoff_blocked_by_stale_manifest=false`, `target_handoff_ready_to_send=true`, `quota_ready_for_handoff=true`, and `final_gate_request_trace_live_admin_api_readback=pass` for `internal-trusted-beta-001`.

Open-source Alpha guard: do not describe the current trusted-user voucher-backed Beta as an open-source New API replacement or full public commercial release. Current status is local code-first Alpha pass, backed by `scripts/verify_open_source_alpha_gate.ps1 -RunMatrix`, `scripts/verify_route_level_live_http_proof.ps1`, provider-key runtime smoke, importer live apply/rollback, and secret scan. Public release still needs clean clone/CI rerun and caveats.

## 当前 API 分发 Gate

| Gate | Owner | 当前状态 | DoD / next action |
|---|---|---|---|
| Gateway key expiry / IP allowlist | Agent-E2 / Gateway | `Done` | Key 过期/禁用拒绝、virtual key allowlist、profile 独立 allowlist、trusted proxy header parsing 均有 Gateway 单测/fixture 覆盖；Settings 已有 secret-safe readback、profile allowlist 编辑、trusted proxy config-needed handoff 和 RFC 文档网段示例生成器；发行环境真实 LB/proxy CIDR、生产网络 live smoke、trusted proxy 热更新/无需重启 rollout 后置，不阻塞当前 MVP |
| Trusted-user packet | Agent-Release / DevRel Ops | `internal-trusted-beta-001` ready; future users external input | Internal packet is ready for operator review/API distribution. For any future target user, fill release owner、support contact、tenant/project/wallet ids、voucher quota、rate/budget guardrails、rollback owner、bounded evidence links；rerun `scripts/prepare_trusted_user_api_distribution_packet.ps1` without missing-field bypass |
| Evidence manifest | Agent-QA | verifier exists; default summary valid but not sendable | Against target-user summary, run `scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1`; require repo-bounded paths, SHA256 match, metadata-only fields, no raw secrets |
| Quota/rate/budget record | Agent-E9 | `internal-trusted-beta-001` pass; future users need real record | Internal record verification is pass and ready_for_handoff. For any future user, run `scripts/verify_trusted_user_quota_rate_budget_record.ps1` against real record; require fixed decimal money, currency/readback match, bounded refs, positive limits, expiry, rollback/audit, evidence hash match |
| Gateway distribution proof | Agent-E8 | current launch proof passed | Preserve `.tmp/launch/e8_gateway_paid_hot_path_launch_check.json` and `.tmp/launch/gateway_voucher_distribution_readiness.json` in manifest; insufficient-balance must remain 402/no-provider-call |
| Operator route / voucher path | Agent-E11 | operator-mediated path acceptable; public route polish remains productization | If using operator-only handoff, public self-serve voucher polish is not a global blocker; any implemented route must prove RBAC, hash/redaction, idempotency, audit/readback, refusal-no-write |
| Release/secret scan | Agent-QA / Security | must be rerun for target-user packet | `scripts/release_check.ps1 -Checks launch` may warn for productization gaps; target-user packet and secret scan must be fresh and secret-safe |

External-input rule: missing selected-user fields block that user's handoff only, not the global API distribution readiness. TODO-32J payment/order/invoice and TODO-32K subscription/package remain `deferred_runtime_external_dependency` until provider/callback/capture or scheduler/provider/invoice runtime is available.

## External Dependency Bypass Summary

These are documented blockers for later public/self-serve or full commercial scope, not blockers for the current scoped trusted-user voucher-backed API Beta. The current bypass is operator-mediated virtual-key distribution plus voucher/redeem-code quota, per-user packet verification, manifest verification, quota/rate/budget verification, and secret scan. Do not describe this as full commercial ready.

| blocker_id | Missing external input | Current bypass path | Resume condition / command |
|---|---|---|---|
| `auth_client_oidc_external_dependency` | Auth client/OIDC provider, redirect/callback URLs, public user-session lifecycle, tenant/user ownership mapping, support/security owner. | Use existing dev/admin or operator-mediated trusted-user flow; public Auth client absence only blocks self-serve/public UX. | Resume with provider/client policy, then run `scripts/verify_route_level_live_http_proof.ps1` or equivalent login/session/ownership probe with secret-safe artifact and `paid_gate_changed=false`. |
| `payment_order_invoice_external_runtime_deferred` | Payment provider/gateway, callback/capture runtime, invoice/receipt/refund/chargeback/reconciliation policy, or approved bounded simulation. | Use voucher-backed quota and accepted ledger/readback evidence; leave TODO-32J runtime false/deferred. | Resume with provider/callback/capture or approved simulation; run `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_payment_order_invoice_runtime.ps1`. |
| `subscription_package_runtime_external_dependency` | Scheduler/renewal trigger, provider/invoice/order linkage runtime, trial/proration/dunning/cancel/pause/resume policy, reconciliation owner. | Use one-off voucher-backed quota; leave TODO-32K runtime false/deferred. | Resume with scheduler/provider/invoice policy; run `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_subscription_package_lifecycle_runtime.ps1`. |
| `public_self_serve_ux_productization_external_dependency` | Product-approved self-serve screens/client flow, quota/rate budget selection, user-facing errors, handoff metadata capture, support/rollback owner. | Keep operator-mediated handoff; wired routes/live backend proof do not close public self-serve UX. | Resume with Product/Frontend/Ops flow and run UI/API E2E plus `scripts/verify_route_level_live_http_proof.ps1`; require ownership, idempotency, audit, ledger/credit readback, refusal no-write, secret safety, and `paid_gate_changed=false`. |

## Historical Beta Blockers / Regression Watch

| ID | Owner | 状态 | DoD | 当前 blocker / next action |
|---|---|---|---|---|
| TODO-00 Repository Truth Reset | Agent-Repo | 完成 / CI wrapper pass | CI workflow 存在；`git diff --check` 无 blocking whitespace；modified/untracked 分类已写入；文档状态统一 | `.github/workflows/ci.yml` 当前存在且包含 Rust fmt/check/clippy/test、PowerShell dry-run smoke、Admin UI `npm ci`/test/build/check:bundle、secret scan、supply-chain scan 与 SBOM/provenance artifact gate。2026-06-07 scoped reverify passed: `cargo fmt --check`, `cargo check --workspace --all-targets`, Gateway protocol contracts, secret scan, Admin UI test gate, and Admin UI bundle gate. The earlier 2026-06-07 full wrapper failure at `cargo test --workspace --all-targets --all-features` exit 101 is closed by the runtime writer cutover fixture fix. Current evidence: `cargo test --workspace --all-targets --all-features` exit 0 and `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1` exit 0 end-to-end; artifact `.tmp/launch/full_wrapper_rerun_20260607_143200_pass.json`. Board `E0-002` is `Done`. |
| TODO-01 Acceptance Docs Sync | Agent-PM | 完成 / 持续回填 | TODO、P0 status、Acceptance、Board 口径一致；不再依赖 99.x% 进度条 | 当前入口保持 `TODO/` 为权威源；Acceptance、Board、P0 status 已按 Beta/Paid Beta/Production RC 口径收束。后续每个 blocker 关闭后继续回写证据。 |
| TODO-10 E11 Billing / Price mutation | Agent-E11 | historical / not current API distribution gate | fresh runtime-current verified；browser mutation pass；API/DB/UI readback 指向同一对象；audit readback pass；secret-safe | Keep as regression/hardening unless it affects selected-user API handoff. Current E11 distribution task is operator-mediated voucher/virtual-key route evidence. |
| TODO-11 E13 Prompt Protection report/audit | Agent-E13 | Beta pass | 4 endpoint live reject proof；`provider_attempts_count=0`；runtime-owned audit row readback；report write/readback；secret-safe | S97 artifact `.tmp/prompt_protection_beta_closure_report.json` passed with `beta_closure_eligible=true`; browser detail moved to TODO-14/OBS or UI E2E, accepted redeploy artifact remains Production RC. |
| TODO-12 E8 Gateway rate-limit reservation | Agent-E8 | Beta live reservation evidence accepted in later TODO slices; watch current launch proof | live request acquire reservation；release/not_applied/fallback 状态可读；limit exceeded 不进 provider；estimated TPM 明确标记 | Current distribution proof is `.tmp/launch/e8_gateway_paid_hot_path_launch_check.json` plus Gateway voucher readiness. Production tokenizer/read-model remains TODO-40/RC. |
| TODO-13 E9 Beta billing mode | Agent-E9 / Product | controlled paid beta evidence accepted | Main review accepted the real paid evidence bundle, readiness gate, and QA paid aggregator for controlled paid beta. | Accepted paths: `.tmp/paid-beta/e8_gateway_paid_hot_path.json`, `.tmp/paid-beta/e11_control_plane_paid_readback_reconciliation.json`, `.tmp/paid-beta/real_paid_evidence_bundle.json`, `.tmp/paid-beta/e9_paid_readiness_gate.json`, `artifacts/beta_acceptance_paid_aggregator_20260605_main_final_review.json`. This is not full Production RC; bounded smoke refund endpoint is dev evidence only and partial refund policy/deeper reconciliation remain RC work. |
| TODO-14 Request / Trace / Usage explainability | Agent-OBS | pass / hardening watch | E8/E11/E13 smoke request ids 可在 Admin/API 读回 route、fallback/reject、usage/cost、ledger、guardrail/audit 核心字段；metadata-only/redacted；UI tests pass | Current live readback artifact `.tmp/launch/request_trace_usage_live_admin_api_readback.json` is pass. Remaining work is UI/browser polish and broader audit hardening, not a current API distribution blocker. |

2026-06-07 CTO Request/Trace UI update: Admin UI Request Detail now has an operator `Support Summary` built only from existing metadata-only detail fields. It summarizes route, provider attempt failures, fallback reasons, usage, cost, linked ledger rows, redaction, and trace id without loading payload preview or raw route snapshot material. Route Trace displays sanitized `summary.*` fields for strategy/fallback/reject and does not fall back to raw top-level route snapshot strategy. Verification: `npm --prefix web/admin-ui test -- --run src/App.test.tsx` passed 74 tests, and `npm --prefix web/admin-ui run build` passed. TODO-14 LiveGapReadiness acquired a safe dev admin session without echoing the token, then live Admin/API metadata-only readback passed for 11 E8/E11/E13 request ids, 5 traces, request-linked ledger entries, audit list, and 1 remaining-balance surface. Artifact: `.tmp/launch/request_trace_usage_live_admin_api_readback.json`.

2026-06-07 E4 model association update: `scripts/verify_control_plane_model_association_dry_run_contract.ps1` verifies dry-run selected/no-candidate fixtures, OpenAPI selector/fallback_allowed contract, Control Plane secret omission, and Admin UI entry points. `scripts/verify_control_plane_model_association_dry_run_live.ps1` also passed against the running compose stack: dev admin login, seeded DB preconditions, real `POST /admin/model-associations/dry-run`, selected candidate, `fallback_allowed=true`, default price config API live restore, and secret-safe response. Admin UI now has a minimal default price book selector on the Models table: options come from active `/admin/price-versions`, are deduped by `price_book_id`, and save through `PATCH /admin/models/{id}` with `default_price_book_id` or `null`. Verification from Agent-E4: `npm test -- --run src/App.test.tsx src/api/client.test.ts` passed 96 tests, `npm run typecheck` passed, and `npm run build` passed. Main-thread browser evidence also passed after rebuilding the Admin UI container from current source: `node web/admin-ui/scripts/model-default-price-browser-evidence.mjs` wrote `.tmp/control-plane/model_default_price_admin_ui_browser_evidence.json` with `status=pass`, covering Chromium login, Models navigation, selector visibility, active price book option selection, PATCH `/admin/models/{id}` observation, API readback after set, and restore/readback to the original value. E4 remains `InProgressPass`, not full Done, because broader Admin UI parity/trace polish remains later work.

2026-06-07 E3 provider-key audit/readback update: `scripts/verify_provider_key_audit_readback.ps1 -ExecuteMutation -RestoreStatus enabled` passed against local compose. It proves provider key GET readback omits credential material, bounded status mutation is credential-safe, `provider_key.update` audit readback is secret-safe, and the provider key is restored. Production rotation readiness is now explicitly blocked, not faked: `scripts/verify_provider_key_production_rotation_readiness.ps1` emits `status=production_ready_blocked`, `runtime_rotate_endpoint_implemented=false`, `final_rotation_closure_allowed=false`, `bounded_substitute_allowed=true`, and `secret_safe=true`. The runbook has resume steps for `create-new-key / verify-traffic / disable-old-key`; OpenAPI now documents a future-only rotation contract extension without claiming an implemented `/rotate` path. KMS/master-key custody, production live traffic readback, and old-key disable audit readback remain external/non-blocking for current API distribution.

2026-06-07 E12 importer parity update: `scripts/importers/verify-import-sample-apply-rollback-parity.ps1` passed. New API and One API samples both complete source dry-run -> internal mapping -> apply-plan parity with `planned_writes=17`, `planned_skips=0`, and `rollback_snapshot_entries=17`. Provider keys remain sidecar-only: `raw_provider_keys_written=false`, `provider_key_write_targets=0`, `provider_key_sql_operations=0`. Control Plane provider-key create audit/readback remains deferred until an operator secret is available; this is not an API distribution blocker.

2026-06-07 E12 provider-key handoff update: `scripts/importers/verify-import-provider-key-operator-handoff-packet.ps1` passed and wrote `.tmp/importers/provider_key_operator_handoff/summary.json` plus New API / One API handoff packet artifacts. Each sample has `operator_handoff_metadata_entries=3`; packets contain non-secret metadata only, including provider/channel ids, key alias, binding status, redacted locator, and locator hash evidence. Summary reports `raw_provider_keys_in_packets=false`, `raw_provider_keys_written=false`, `provider_key_sql_operations=0`, and `api_distribution_blocked=false`. Real Control Plane provider-key create audit/readback still waits for an operator-supplied real secret.

2026-06-07 open-source Alpha clean-clone guard update: `scripts/verify_open_source_alpha_clean_clone_readiness.ps1` is wired into `scripts/verify_open_source_alpha_gate.ps1`. Current readiness is `status=warn` because no real clean-clone/CI transcript was produced, but the guard itself passes README, `.dockerignore`, CI workflow, required commands, known limitations, and trusted-beta/full-commercial caveats. `docs/OPEN_SOURCE_ALPHA_CLEAN_CLONE_TRANSCRIPT_TEMPLATE.md` now records the exact transcript command template. This blocks public tag/release only, not local Alpha or API distribution.
| TODO-20 Full local gate | Agent-QA | full wrapper pass / launch handoff gate separate | `scripts/test.ps1`、compose smoke、SDK smoke、secret scan、supply-chain scan 通过；生成 secret-safe Beta acceptance summary | Full wrapper is now green: `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1` exit 0 on 2026-06-07 after the ledger adjustment runtime writer cutover test fix. Evidence: `.tmp/launch/full_wrapper_rerun_20260607_143200_pass.json`. API distribution still requires target-user handoff packet/quota verification after any gate that refreshes launch artifacts. |
| TODO-21 Trusted user Beta release prep | Agent-Release / DevRel Ops | current mainline | Beta 使用说明、Admin runbook、incident runbook、数据保留说明、known limitations 完成；virtual key 有预算/RPM/TPM/过期/IP 策略 | Next action is complete the target-user packet and quota/rate/budget record, rerun manifest verifier and secret scan, then distribute scoped API access. |

## 后置项

| Lane | 后置到 | 当前状态 |
|---|---|---|
| E8 production tokenizer/read-model runner | Production RC | 不再阻塞 Beta；真实 production runner provenance、Gateway live smoke scope、production DB readback artifact 仍需保留。 |
| E9 production source-of-truth cutover ceremony | Paid Beta / Production RC | Controlled paid beta evidence is accepted by main review. Full Production RC source-of-truth cutover, partial refund policy, and deeper reconciliation remain RC work. |
| E15 ClickHouse Log Store | Production RC | dev-only local compose/wire-up prototype 已有；真实 writer/cursor/WAL/dedup/load-retention 和 non-simulated production smoke 仍缺。 |
| Load/chaos/security/staging/backup restore | Production RC | 未作为当前 Beta blocker。 |

## Paid Beta / Hardening TODOs

| ID | Owner | 状态 | DoD / next action |
|---|---|---|---|
| TODO-30 E9 real reserve/settle/refund in Gateway hot path | Agent-E9 + Agent-Gateway | 未开始 | Gateway auth 后 provider call 前 reserve；success settle；pre-first-byte fail release/refund；partial/client cancel 按 policy 处理；reconciliation 可恢复；并发超卖与 crash/restart 测试通过。 |
| TODO-30A Paid Beta readiness refusal gate | Agent-E9 / Billing Ledger | controlled paid beta allowed after evidence | Release tooling 层可运行 gate；真实 evidence bundle accepted 后才允许 `paid_controlled_beta`；默认不联网不连 DB，不输出 secrets | Main review accepted readiness with `.tmp/paid-beta/real_paid_evidence_bundle.json`; current `.tmp/paid-beta/e9_paid_readiness_gate.json` has `paid_controlled_beta_allowed=true`. Contract-shape and synthetic bundles remain blocked. |
| DOC-PAID-03 Paid evidence artifact index | Agent-E13 / Release Docs | accepted evidence index current | Index every required E8/E11/E9/QA/secret/TODO-20 artifact with owner, expected path, schema, pass markers, blocked markers, release-artifact status | `docs/PAID_BETA_EVIDENCE_INDEX.md` exists and `project/paid_beta_evidence_index.json` mirrors accepted controlled paid beta evidence. |
| DOC-PAID-04 Machine-readable paid evidence index manifest | Agent-E13 / Release Docs | manifest accepted current | JSON manifest exposes `schema`, status date, requested/allowed/current state, and required artifact contract for QA/E9 readback | `project/paid_beta_evidence_index.json` parses with PowerShell `ConvertFrom-Json`; current state is `controlled_paid_beta_evidence_accepted_by_main_review`, `paid_controlled_beta_allowed=true`, with exact accepted artifact paths recorded. |
| TODO-31 Conservative budget/rate-limit/key-health protection | Agent-Routing / Agent-Security | 未开始 | virtual key 日/月/总预算 hard limit；RPM/TPM/concurrency 统一错误 shape；provider key 429 cooldown；auth_failed/balance_insufficient/quota_limited 状态分开；manual disable/recovery probe 有 audit。 |

## Credit / Balance Productization Gap

Docx product target includes Wallet, Credit Grant, Budget, Subscription, Recharge/Voucher, New API balance import, and ledger truth. Current status: this gap matrix does not overturn `paid_controlled_beta_allowed=true`; it separates accepted controlled paid beta evidence from the remaining Production/Beta productization backlog.

QA-CREDIT-01 verifier: `scripts/verify_credit_wallet_ledger_surface.ps1` is a read-only repo/artifact check. Current run exits 0 with `overall_status=pass_with_productization_gaps`, `underlying_credit_balance_capability=present_verified`, `user_recharge_redeem_package_invoice=not_productized`, and `new_api_one_api_balance_import=runtime_verified`.

QA-CREDIT-02 watcher update: E9-CREDIT-02 added the contract-only draft `docs/todo/slices/TODO-32-CREDIT-WALLET.md`; the verifier now checks the draft endpoints and safety requirements read-only. Current contract status is `draft_contract_verified`, `implemented_runtime_surface=false`; this does not change `paid_controlled_beta_allowed=true`.

QA-CREDIT-03 / TODO-32C verifier expansion: current verifier output now separates `draft_contract_verified=true`, `admin_readonly_openapi_contract_verified=true`, `admin_readonly_runtime_verified=false`, `billing_mutation_contract_verified=true`, and `product_commercial_flows_not_implemented=true`. No E11-CREDIT-02R runtime artifact or E9-CREDIT-03 mutation test artifact is present, so runtime remains not verified and paid final acceptance is unchanged.

QA-CREDIT-04 artifact watcher: checked `.tmp/credit-wallet/admin_readonly_wallet_credit_runtime.json`, `artifacts/credit_wallet_admin_readonly_runtime.json`, `.tmp/credit-wallet/billing_mutation_contract_tests.json`, and `artifacts/credit_wallet_billing_mutation_contract_tests.json`; all are absent. E9-CREDIT-03 code test/fixture exists, but no QA-consumable mutation artifact is present, so `admin_readonly_runtime_verified=false` and `billing_mutation_artifact_verified=false`. Suggested future artifact fields: `overall_status=pass`, `secret_safe=true`, `read_only=true` for Admin runtime, `contract_only=true` for mutation contract, fixed-decimal money proof, omitted raw secret markers, and `paid_gate_changed=false`.

QA-CREDIT-05 artifact consume update: `.tmp/credit-wallet/billing_mutation_contract_tests.json` is now parsed and verified by `scripts/verify_credit_wallet_ledger_surface.ps1`. Current layered status: `billing_mutation_artifact_verified=true`, `admin_readonly_runtime_verified=false`, and `product_commercial_flows_not_implemented=true`; controlled paid beta remains accepted and unchanged.

QA-CREDIT-06 / TODO-32F planning update: verifier now exposes `opening_balance_import_contract_verified=true`, `opening_balance_import_runtime_verified=false`, and `opening_balance_import_artifact_verified=false`. Artifact paths `.tmp/credit-wallet/opening_balance_import_contract.json` and `artifacts/credit_wallet_opening_balance_import.json` are absent, so New API / One API opening-balance import remains designed/contracted but not runtime verified. SelfTest defines the future artifact shape and rejects secret-unsafe, paid-gate-changing, and direct-wallet-mutation artifacts.

QA-CREDIT-07 watcher update: E11 opening-balance import API/OpenAPI contract is present for `/billing/opening-balance-imports`, so verifier now reports `opening_balance_import_api_contract_present=true`. E9/E11 JSON artifacts `.tmp/credit-wallet/opening_balance_import_contract.json` and `artifacts/credit_wallet_opening_balance_import.json` are still absent, so `opening_balance_import_artifact_verified=false` and `opening_balance_import_runtime_verified=false`. Controlled paid beta remains unchanged.

QA-CREDIT-08 artifact consume update: `.tmp/credit-wallet/opening_balance_import_contract.json` is present and verified by the QA verifier. Current layered status: `opening_balance_import_artifact_verified=true`, `opening_balance_import_runtime_verified=false`, `opening_balance_import_api_contract_present=true`. This proves the opening-balance import contract/test artifact, not runtime implementation; New API / One API import apply/rollback remains unimplemented.

QA-CREDIT-09 / TODO-32F-S1 schema verifier watch: verifier now checks `opening_balance_imports` table/columns and the required unique constraints for tenant/idempotency and tenant/external-source/reference. Current layered status: `opening_balance_import_schema_verified=true` from `db/migrations/0011_opening_balance_imports.sql`, `opening_balance_import_artifact_verified=true`, and `opening_balance_import_runtime_verified=false`. Schema presence does not prove live import apply/replay/refusal/readback; controlled paid beta remains accepted and unchanged.

QA-CREDIT-10 / TODO-32F-S2 runtime verifier watch: no E11-CREDIT-06 runtime-live artifact is present beyond the existing contract artifact `.tmp/credit-wallet/opening_balance_import_contract.json`, which still has `runtime_implemented=false`. Verifier now requires runtime artifacts to prove `runtime_implemented=true`, `contract_only=false`, endpoint/id fields, live DB readback, opening import readback, ledger/admin-adjustment readback, audit readback, replay/refusal readback, and rollback readback before setting `opening_balance_import_runtime_verified=true`. Current result remains `opening_balance_import_schema_verified=true`, `opening_balance_import_artifact_verified=true`, `opening_balance_import_runtime_verified=false`.

QA-CREDIT-12 / TODO-32F-S3 runtime artifact verifier: no E11-CREDIT-07 runtime-live artifact was found. E11-CREDIT-06 is present only as a DB-free SQL contract/design-to-code slice, and `.tmp/credit-wallet/opening_balance_import_contract.json` remains `runtime_implemented=false`. Verifier output stays `opening_balance_import_schema_verified=true`, `opening_balance_import_artifact_verified=true`, `opening_balance_import_runtime_verified=false`; paid gate remains unchanged.

QA-CREDIT-13 / TODO-32F-S4 runtime verifier guard: no E11-CREDIT-08 runtime-live artifact was found. The observed E11-CREDIT-07 work is still DB-free internal transaction-shape partial and the public route remains contract-only; `.tmp/credit-wallet/opening_balance_import_contract.json` is still `runtime_implemented=false` with no live/internal DB readback booleans. Runtime stays unverified until an artifact proves `runtime_implemented=true`, `contract_only=false`, all required readbacks, `secret_safe=true`, and `paid_gate_changed=false`.

QA-CREDIT-15 / TODO-32F-S5 runtime artifact prep: verifier now watches `.tmp/credit-wallet/opening_balance_import_runtime.json` and `artifacts/credit_wallet_opening_balance_import_runtime.json` before contract-only artifacts. No S5 runtime artifact is currently present; the selected evidence remains `.tmp/credit-wallet/opening_balance_import_contract.json` with `runtime_implemented=false`. Runtime remains unverified until the runtime artifact has runtime schema/pass status, `runtime_implemented=true`, `contract_only=false`, required readback booleans and ids, `secret_safe=true`, and `paid_gate_changed=false`.

QA-CREDIT-16 / TODO-32F-S5 runtime artifact standby: `.tmp/credit-wallet/opening_balance_import_runtime.json` is now present but blocked. The artifact reports `schema=opening_balance_import_runtime.v1`, `overall_status=blocked`, `runtime_implemented=false`, `contract_only=true`, `db_integration_ran=false`, `secret_safe=true`, and `paid_gate_changed=false`; required DB/readback checks are still pending. Verifier correctly consumes this runtime path before contract fallback and keeps `opening_balance_import_runtime_verified=false`.

QA-CREDIT-17 / TODO-32F-S5 blocked runtime artifact consume: verifier consumed `.tmp/credit-wallet/opening_balance_import_runtime.json` and returned `overall_status=pass_with_productization_gaps`, `runtime_artifact_found=true`, selected status `opening_balance_import_artifact_present_but_not_verified`, and `opening_balance_import_runtime_verified=false`. The blocked artifact is secret-safe and paid-gate-neutral, but it has `runtime_implemented=false`, `contract_only=true`, no live DB readback, and no import/ledger/audit ids; controlled paid beta remains unchanged.

QA-CREDIT-19 / TODO-32F-S7 runtime-vs-plan strict verifier watcher: E11-CREDIT-10 adds a guarded rollback-contained `psql` DB plan and marks `db_runner_implemented=true`, but the current artifact remains blocked with `runtime_implemented=false`, `contract_only=true`, `db_integration_ran=false`, and no route/internal Rust invocation. QA verifier now explicitly requires `route_or_internal_rust_path_invoked=true` in addition to runtime true, contract-only false, ids, readback booleans, secret safety, and paid-gate neutrality; selftest rejects a psql-plan-only artifact even if its plan/readback markers are true. Runtime remains unverified.

Main-thread TODO-32F-S7 DB-plan readback: local compose Postgres was available and migration `0011_opening_balance_imports.sql` was applied. The opening-balance verifier now produces `.tmp/credit-wallet/opening_balance_import_runtime.json` with `overall_status=partial`, `db_integration_ran=true`, `db_runner_implemented=true`, and `executable_db_plan.passed=true`; apply/replay/conflict/refusal/ledger/audit/rollback DB-plan checks are true. This remains productization evidence only: `runtime_implemented=false`, `contract_only=true`, no public route or internal Rust invocation, and `opening_balance_import_runtime_verified=false`. Controlled paid beta remains unchanged.

QA-CREDIT-20 / TODO-32F-S7 partial DB-plan artifact consume: QA re-consumed the current `.tmp/credit-wallet/opening_balance_import_runtime.json` after the local compose DB-plan pass. The verifier keeps `opening_balance_import_runtime_verified=false`: `db_runner_implemented=true` and `executable_db_plan.passed=true` are partial DB-plan evidence only, while `runtime_implemented=false`, `contract_only=true`, `route_or_internal_rust_path_invoked=false`, and blockers remain `opening_balance_import_public_route_not_wired` plus `opening_balance_import_internal_rust_function_not_invoked_by_verifier`. SelfTest now includes `opening_balance_import_runtime_partial_db_plan_only_rejected` so a passing rollback-contained `psql` plan cannot be misaccepted as runtime implementation.

QA-CREDIT-20 update / live route matrix artifact consume: after the replay canonicalization fix and compose rebuild with `POSTGRES_HOST_PORT=55432` and `REDIS_HOST_PORT=56379`, `.tmp/credit-wallet/opening_balance_import_runtime.json` now records the live route matrix as QA-readable runtime evidence. The artifact is `overall_status=pass`, `runtime_implemented=true`, `contract_only=false`, `route_invoked=true`, `public_route_invoked=true`, `internal_sqlx_function_invoked=true`, and includes opening import / ledger / admin adjustment / audit ids plus live DB readback, replay, refusal, and rollback booleans. Verifier output is now `opening_balance_import_runtime_verified=true`; `secret_safe=true` and `paid_gate_changed=false`, so controlled paid beta remains unchanged.

QA-CREDIT-21 / TODO-32G verifier plan (superseded by main-thread TODO-32G live runtime acceptance): `scripts/verify_credit_wallet_ledger_surface.ps1` added a separate credit grant CRUD artifact lane. That planning state originally had only contract evidence; current state is stronger: `.tmp/credit-wallet/credit_grant_crud_runtime.json` is pass and `credit_grant_crud_runtime_verified=true`.

QA-CREDIT-22 / TODO-32G runtime acceptance + TODO-32H contract lane prep (superseded for TODO-32G by main-thread live runtime acceptance and for TODO-32H by QA-CREDIT-28): verifier runtime acceptance for credit grant CRUD requires `credit_grant_crud_runtime.v1` pass status, `runtime_implemented=true`, `contract_only=false`, route/internal invocation, grant/audit ids, create/list/read/lifecycle/status/replay readback, conflict/refusal no-write evidence, audit readback, decimal money, no direct wallet snapshot mutation, `secret_safe=true`, and `paid_gate_changed=false`. Current `.tmp/credit-wallet/credit_grant_crud_runtime.json` now satisfies those checks. Current TODO-32H state is Admin-readonly runtime verified / full user scope pending.

QA-CREDIT-23 / TODO-32G lifecycle runtime guard was superseded by QA-CREDIT-24: E11 now has `admin_credit_grant_create_rejects_non_positive_amounts()` with `negative.amount = "-1.00000000"` and the source still rejects `amount <= 0`. The stale blocker `credit_grant_negative_amount_minus_one_test_missing` is closed.

QA-CREDIT-24 / TODO-32G negative amount guard reconsume (superseded for runtime status): `cargo test -p ai-control-plane credit_grant -- --nocapture` passes 4 tests, including `admin_credit_grant_create_rejects_non_positive_amounts`. The stale runtime blocker from this entry is closed by the main-thread live artifact; TODO-32H has since advanced to Admin-readonly runtime verified / full user scope pending. Controlled paid beta remains unchanged.

Main-thread TODO-32G live runtime acceptance: after rebuilding the local Control Plane compose runtime with `POSTGRES_HOST_PORT=55432` and `REDIS_HOST_PORT=56379`, `scripts/verify_credit_grant_crud_runtime.ps1 -RunLiveRouteMatrix` regenerated `.tmp/credit-wallet/credit_grant_crud_runtime.json` with `overall_status=pass`, `runtime_implemented=true`, `contract_only=false`, `route_invoked=true`, `public_route_invoked=true`, `control_plane_runtime_current=true`, grant/audit ids present, create/list/read/expire/revoke/status/replay/conflict/refusal/audit readback all true, `secret_safe=true`, and `paid_gate_changed=false`. `scripts/verify_credit_wallet_ledger_surface.ps1` now reports `credit_grant_crud_runtime_verified=true`; the old `credit_grant_crud_api_and_audit` productization gap is closed without reopening controlled paid beta.

E9-CREDIT-22 / TODO-32I recharge-voucher contract: `.tmp/credit-wallet/recharge_voucher_contract.json` is present and contract-ready with schema `recharge_voucher_contract.v1`, status `pass`, `runtime_implemented=false`, `contract_only=true`, `secret_safe=true`, and `paid_gate_changed=false`. Main thread verified `cargo test -p ai-gateway-billing-ledger recharge_voucher -- --nocapture` exit `0` (1 passed). This is contract-only guard evidence; Control Plane runtime, payment-provider handoff, voucher generation/storage, abuse persistence, order/invoice/payment lifecycle, and QA runtime acceptance remain pending.

QA-CREDIT-25 / TODO-32I recharge-voucher verifier lane (historical; superseded by DOC-CREDIT-56): `scripts/verify_credit_wallet_ledger_surface.ps1` added the contract-only recharge/voucher verifier lane. The current accepted state is stronger: DOC-CREDIT-56 reports `recharge_voucher_runtime_verified=true` from `.tmp/credit-wallet/recharge_voucher_runtime.json`.

E9-CREDIT-23 / TODO-32J payment-order-invoice contract: `.tmp/credit-wallet/payment_order_invoice_contract.json` is present and contract-ready with schema `payment_order_invoice_contract.v1`, status `pass`, `runtime_implemented=false`, `contract_only=true`, `secret_safe=true`, and `paid_gate_changed=false`. This is contract-only guard evidence; Control Plane payment-provider handoff/callbacks, order lifecycle persistence, invoice/receipt production policy, tax/finance reconciliation, refund/chargeback/retry handling, and QA runtime acceptance remain pending.

QA-CREDIT-26 / TODO-32J payment-order-invoice verifier lane: `scripts/verify_credit_wallet_ledger_surface.ps1` now consumes `.tmp/credit-wallet/payment_order_invoice_contract.json` and watches `artifacts/credit_wallet_payment_order_invoice_contract.json`, `.tmp/credit-wallet/payment_order_invoice.json`, and `artifacts/credit_wallet_payment_order_invoice.json`. Current verifier output is `payment_order_invoice_contract_verified=true` and `payment_order_invoice_runtime_verified=false`; contract evidence covers fixed decimal money, idempotency/replay, provider handoff redaction, invoice/receipt markers, refund/reversal, reconciliation, audit, no direct wallet snapshot mutation, `secret_safe=true`, and `paid_gate_changed=false`. The remaining gap is `payment_order_invoice_lifecycle_runtime`; controlled paid beta remains unchanged.

QA-CREDIT-27 / TODO-32K subscription-package verifier lane: `scripts/verify_credit_wallet_ledger_surface.ps1` now consumes `.tmp/credit-wallet/subscription_package_lifecycle_contract.json` and watches `artifacts/credit_wallet_subscription_package_lifecycle_contract.json`, `.tmp/credit-wallet/subscription_package_lifecycle.json`, and `artifacts/credit_wallet_subscription_package_lifecycle.json`. Current verifier output is `subscription_package_lifecycle_contract_verified=true` and `subscription_package_lifecycle_runtime_verified=false`; contract evidence covers fixed decimal money, idempotency/replay, plan/package lifecycle, subscription states, credit grant or ledger effect, invoice/order linkage, refusal no-write, audit, no direct wallet snapshot mutation, `secret_safe=true`, and `paid_gate_changed=false`. Current protected fields remain stable: `opening_balance_import_runtime_verified=true`, `credit_grant_crud_runtime_verified=true`, `user_remaining_balance_contract_verified=true`, `recharge_voucher_contract_verified=true`, and `payment_order_invoice_contract_verified=true`. The remaining gap is `subscription_plan_lifecycle_runtime`; controlled paid beta remains unchanged.

QA-CREDIT-28 / TODO-32H user remaining-balance runtime verifier lane: `scripts/verify_credit_wallet_ledger_surface.ps1` now prioritizes `.tmp/credit-wallet/user_remaining_balance_runtime.json` and `artifacts/credit_wallet_user_remaining_balance_runtime.json` while preserving contract paths. Runtime acceptance is split into `user_remaining_balance_admin_readonly_runtime_verified` / `user_remaining_balance_admin_runtime_verified` for Admin read-only partial evidence and `user_remaining_balance_runtime_verified` for full user-facing API evidence. Current `.tmp/credit-wallet/user_remaining_balance_runtime.json` exists and is accepted as Admin-readonly partial runtime: verifier output is `user_remaining_balance_contract_verified=true`, `user_remaining_balance_admin_readonly_runtime_verified=true`, `user_remaining_balance_admin_runtime_verified=true`, and `user_remaining_balance_runtime_verified=false`; the gap remains `user_facing_remaining_balance_api_runtime` until user/developer-token ownership scope is proven. Protected fields remain stable: `opening_balance_import_runtime_verified=true`, `credit_grant_crud_runtime_verified=true`, `payment_order_invoice_contract_verified=true`, and `subscription_package_lifecycle_contract_verified=true`.

QA-CREDIT-29 / TODO-32H admin-readonly runtime reconciliation: QA re-read `.tmp/credit-wallet/user_remaining_balance_runtime.json` and confirmed the verifier requires schema/status pass, `runtime_implemented=true`, `contract_only=false`, route/public-route invocation, read-only Admin runtime, tenant/wallet/currency ids, decimal-string `available_to_spend`, `active_credit_grant_total`, `pending_confirmed_ledger_window`, and `wallet_balance_floor`, wallet/credit-grants/ledger-window/refusal readbacks, `secret_safe=true`, and `paid_gate_changed=false`. Because the artifact has `user_api_runtime=false`, full `user_remaining_balance_runtime_verified=false` remains correct; this is not a user-facing ownership-scope pass.

QA-CREDIT-30 / TODO-32H-S2 full user runtime guard + TODO-32I runtime prep watch (historical; superseded by E11-CREDIT-20 for TODO-32H and DOC-CREDIT-56 for TODO-32I): verifier selftest added strict guards for user remaining-balance ownership and recharge/voucher runtime artifacts.

E11-CREDIT-19 / TODO-32H-S5 RemainingBalancePrincipal wiring attempt: Control Plane now has minimal principal wiring for user-session and developer-token ownership lookup, but the live ownership runtime artifact is blocked, not pass. `.tmp/credit-wallet/user_remaining_balance_ownership_runtime.json` reports `overall_status=blocked`, `runtime_implemented=false`, `contract_only=true`, `user_api_runtime=false`, `ownership_scope_verified=false`, `secret_safe=true`, and blocker `control_plane_remaining_balance_ownership_route_not_accepting_seeded_user_session`; full `user_remaining_balance_runtime_verified=false` remains correct.

E11-CREDIT-20 / QA-CREDIT-38 / TODO-32H-S6 current-runtime ownership route fix: the refreshed ownership artifact is now pass, not blocked. `.tmp/credit-wallet/user_remaining_balance_ownership_runtime.json` reports `overall_status=pass`, `runtime_implemented=true`, `contract_only=false`, `user_api_runtime=true`, `ownership_scope_verified=true`, `auth_source=control_plane_user_session`, `server_side_lookup=true`, route/public-route readback true, tenant/project/wallet/user/currency ids, decimal-string balance fields, wallet/project/session/credit-grant/ledger/refusal readback, `missing_session_rejected=true`, `secret_safe=true`, and `paid_gate_changed=false`; `scripts/verify_credit_wallet_ledger_surface.ps1` exits 0 and reports `user_remaining_balance_admin_readonly_runtime_verified=true` plus full `user_remaining_balance_runtime_verified=true`. This closes the TODO-32H minimal user-session runtime gap. DOC-CREDIT-56 later closes TODO-32I internal recharge/voucher runtime; payment/order/invoice and subscription/package runtime remain false.

QA-CREDIT-31 / TODO-32I recharge-voucher runtime verifier hardening (historical; superseded by DOC-CREDIT-56): verifier selftest explicitly rejects malformed `recharge_voucher_runtime.v1` artifacts. The current accepted state is stronger: `recharge_voucher_runtime_verified=true` after the verifier-compatible runtime artifact landed. Full `user_remaining_balance_runtime_verified=false` in this historical entry is superseded by E11-CREDIT-20 / QA-CREDIT-38, where the ownership runtime artifact is accepted. Controlled paid beta remains unchanged.

QA-CREDIT-32 / TODO-32J payment-order-invoice runtime verifier prep: verifier selftest now accepts a fully shaped `payment_order_invoice_runtime.v1` fixture and rejects runtime artifacts missing provider handoff/callback readback, invoice/receipt readback, reconciliation readback, or idempotency/no-duplicate-write readback. Current main verifier remains `payment_order_invoice_contract_verified=true` and `payment_order_invoice_runtime_verified=false`; no payment provider handoff/callback, order lifecycle persistence, invoice/receipt production, reconciliation, refund/chargeback, or QA runtime acceptance is claimed. Controlled paid beta remains unchanged.

QA-CREDIT-33 / TODO-32K subscription-package lifecycle runtime verifier prep: verifier selftest now accepts a fully shaped `subscription_package_lifecycle.v1` runtime fixture and rejects runtime artifacts missing plan/package lifecycle readback, subscription state readback, credit/ledger effect readback, invoice/order readback, refusal no-write readback, audit readback, or secret safety. Current main verifier remains `subscription_package_lifecycle_contract_verified=true` and `subscription_package_lifecycle_runtime_verified=false`; no subscription runtime/scheduler/provider/invoice/dunning lifecycle is claimed. Controlled paid beta remains unchanged.

E9-CREDIT-30 / TODO-32K-S1 subscription-package schema contract support: `.tmp/credit-wallet/subscription_package_lifecycle_contract.json` now includes contract-only schema support `subscription_package_lifecycle_schema_contract.v1` for `subscription_plans`, `subscription_packages`, `subscriptions`, and `subscription_events_or_schedules`. It remains `runtime_implemented=false`, `contract_only=true`, `secret_safe=true`, and `paid_gate_changed=false`; no Control Plane runtime, scheduler/provider integration, or subscription runtime verification is claimed. DOC-CREDIT-62 update: E11-CREDIT-33 has now added durable schema migration `db/migrations/0014_subscription_package_lifecycle_boundary.sql` for those tables, so the prior "migration missing" blocker is superseded by schema-present/runtime-deferred status.

DOC-CREDIT-61 / TODO-32K-S1 defer assessment: TODO-32K is now treated as contract/schema-ready but deferred for runtime until scheduler/provider/invoice/order linkage capability is available. `.tmp/credit-wallet/subscription_package_lifecycle_contract.json` remains the accepted contract guard (`status=pass`, `runtime_implemented=false`, `contract_only=true`, `secret_safe=true`, `paid_gate_changed=false`), and `.tmp/credit-wallet/subscription_package_lifecycle_runtime_deferred.json` records `overall_status=deferred_runtime_external_dependency`, `runtime_implemented=false`, `contract_only=true`, `secret_safe=true`, `paid_gate_changed=false`, and `production_distribution_ready=false`. There is no accepted `.tmp/credit-wallet/subscription_package_lifecycle_runtime.json` pass artifact. Resume checklist: scheduler/renewal trigger; trial/proration/dunning policy; invoice/order linkage runtime; credit/ledger effect readback; cancel/pause/resume readback; idempotency/conflict/no-write readback; audit and reconciliation readback; accepted non-contract `subscription_package_lifecycle_runtime.v1` pass artifact. This does not change controlled paid beta.

DOC-CREDIT-62 / TODO-32K-S2 subscription schema migration watcher: `db/migrations/0014_subscription_package_lifecycle_boundary.sql` is present and defines `subscription_plans`, `subscription_packages`, `subscriptions`, and `subscription_events_or_schedules` with tenant/currency/status/idempotency/audit metadata, fixed-decimal money, and links to wallet/credit/ledger/invoice/order/audit primitives. This promotes TODO-32K from schema-contract-only to schema-migration-present, but runtime remains `subscription_package_lifecycle_runtime_verified=false` because plan/package CRUD, subscription lifecycle execution, scheduler/provider/dunning, invoice/order linkage runtime, readbacks, and accepted runtime artifact are still missing.

DOC-LAUNCH-01 / Voucher-backed API Beta distribution: launch posture is trusted-user API distribution backed by operator-issued virtual keys and voucher/redeem-code quota, not full commercial self-serve payment or subscription billing. Missing provider/callback/capture runtime for TODO-32J and scheduler/provider/invoice runtime for TODO-32K are `deferred_runtime_external_dependency` with documented resume conditions; they should not be repeatedly reassigned as launch blockers unless Product/Finance/Ops provide those external capabilities. Current accounting evidence supports this narrower path: `recharge_voucher_runtime_verified=true` for the internal Rust/sqlx business path, `user_remaining_balance_runtime_verified=true`, `payment_order_invoice_runtime_verified=false`, and `subscription_package_lifecycle_runtime_verified=false`.

Voucher-backed API Beta operator checklist: issue or assign the trusted user's virtual key; provide or redeem a bounded voucher quota through the accepted operator/internal flow; verify remaining balance through the user/API remaining-balance readback; run the Gateway request path with the assigned virtual key; confirm rate-limit and budget guardrails are configured for the user; record audit/support metadata and bounded request ids; for rollback, revoke or disable the virtual key, revoke/expire the credit grant or voucher quota, and verify remaining balance/readback returns to the expected state. Logs, docs, tickets, and screenshots must not expose raw voucher/redeem codes after issuance, full virtual keys, Authorization/Cookie headers, provider keys, DB URLs, raw provider payloads, raw request bodies, raw idempotency keys, or unredacted secret material.

DOC-LAUNCH-08 / Voucher-backed API distribution current state: current artifacts now allow trusted-user voucher-backed Beta API distribution with productization gaps. Release check `artifacts/launch_voucher_api_distribution_release_check_20260606.json` is `overallStatus=warn`; `.tmp/launch/voucher_api_distribution_readiness.json` is `pass_with_productization_gaps` with `production_distribution_ready=true` and current Gateway launch hot path verified; `.tmp/launch/voucher_backed_api_distribution_accounting_gate.json` is `launch_ready_with_productization_gaps`; `.tmp/launch/e8_gateway_paid_hot_path_launch_check.json` is `passed`; `.tmp/launch/gateway_voucher_distribution_readiness.json` is `pass`; `.tmp/launch/voucher_quota_pricing_guardrails.json` is `pass`. This authorizes the scoped trusted-user voucher-backed Beta path after the per-user packet fields are completed. It does not authorize full commercial/public launch.

QA-LAUNCH current gate: `scripts/verify_voucher_api_distribution_readiness.ps1` consumes `.tmp/launch/gateway_voucher_distribution_readiness.json` and `.tmp/launch/e8_gateway_paid_hot_path_launch_check.json`. Current artifact `.tmp/launch/voucher_api_distribution_readiness.json` reports `overall_status=pass_with_productization_gaps`, `gateway_current_launch_hot_path_verified=true`, and `production_distribution_ready=true`. `scripts/release_check.ps1 -Checks launch -SummaryPath artifacts/launch_voucher_api_distribution_release_check_20260606.json` now reports `overallStatus=warn`, because public voucher route polish plus TODO-32J/TODO-32K commercial runtime items remain deferred.

DOC-LAUNCH-15 handoff update: Release/Ops should use `scripts/prepare_trusted_user_api_distribution_packet.ps1` as the primary trusted-user packet orchestrator before key handoff. It regenerates quota/rate/budget material, writes/verifies the trusted-user packet, runs launch release check and secret scan, and writes `.tmp/launch/trusted_user_api_distribution_handoff_summary.json`. Current summaries include `evidence_manifest` with repo-bounded paths and SHA256 hashes for packet, release, quota, accounting, Gateway, guardrail, voucher route, operator, remaining-balance, and voucher runtime evidence; archive the target-user summary and its manifest with the release packet, then run `scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1` against that target-user summary and require exit 0. Also run `scripts/verify_trusted_user_quota_rate_budget_record.ps1` against the real target-user quota/rate/budget record and require exit 0 before handoff. If `.tmp/launch/trusted_user_distribution_review_packet.json`, `.tmp/launch/api_distribution_operator_packet.json`, or `.tmp/launch/trusted_user_api_distribution_handoff_summary.json` still reports `ready_to_send=false`, treat that as missing per-user packet fields, not as a global launch blocker: fill release owner, support contact, tenant/project/wallet ids, voucher/quota amount, rate/budget limits, rollback owner, and bounded evidence links before giving a specific key to a trusted user. Continue to omit raw voucher/redeem code, full virtual key, Authorization/Cookie headers, provider keys, DB URLs, raw provider payloads, raw request bodies, raw idempotency keys, and unredacted secret material. Direct `scripts/verify_trusted_user_distribution_review_packet.ps1` use remains a focused QA verifier, not the primary operator handoff entry point.

DOC-LAUNCH-05 / Current artifact map: reviewer packet locations are indexed in `project/RELEASE_CHECKLIST.md`. Current map: QA launch gate `.tmp/launch/voucher_api_distribution_readiness.json` is `pass_with_productization_gaps` / `production_distribution_ready=true`; E9 accounting gate `.tmp/launch/voucher_backed_api_distribution_accounting_gate.json` is `launch_ready_with_productization_gaps`; E8 current launch check `.tmp/launch/e8_gateway_paid_hot_path_launch_check.json` is `passed`; Gateway rollup `.tmp/launch/gateway_voucher_distribution_readiness.json` is `pass`; route-level proof `.tmp/route-live-http-proof/route_level_live_http_proof.json` is `pass`; E11 route/virtual-key evidence `.tmp/launch/voucher_public_route_and_virtual_key_evidence.json` is `pass` with `voucher_route_evidence.status=live_route_verified`, `route_invoked=true`, `route_verified=true`, public routes wired, and blockers cleared; operator-only exception `.tmp/launch/voucher_operator_only_exception.json` remains governed by its own `approved` / `route_substitution_allowed` fields and is not needed for route substitution while public route proof exists; guardrails `.tmp/launch/voucher_quota_pricing_guardrails.json` are `pass`; release summary `artifacts/launch_voucher_api_distribution_release_check_20260606.json` is `warn`; latest secret scan is pass but should be rerun with the final per-user packet.

DOC-LAUNCH-06 / Developer-operator docs index: `project/RELEASE_CHECKLIST.md` now indexes the current distribution packet structure for reviewers. Entries: developer quickstart contract `.tmp/launch/developer_api_distribution_quickstart_contract.json`, operator packet `.tmp/launch/api_distribution_operator_packet.json`, trusted-user packet `.tmp/launch/trusted_user_distribution_review_packet.json`, waiver/operator-only policy `.tmp/launch/voucher_operator_only_exception.json`, Gateway diagnostics `.tmp/launch/gateway_distribution_diagnostics_bundle.json` and `.tmp/launch/gateway_distribution_operator_smoke_plan.json`, and launch summary `.tmp/launch/voucher_api_distribution_readiness.json` plus `artifacts/launch_voucher_api_distribution_release_check_20260606.json`. These support scoped trusted-user Beta distribution, not full commercial/public launch.

Deferred/resume conditions: public/self-serve Product UX remains follow-up even though public voucher routes are wired and live route proof is passed; TODO-32J payment/order/invoice runtime and TODO-32K subscription/package runtime remain `deferred_runtime_external_dependency`. Do not treat those as blockers for trusted-user voucher-backed Beta, and do not claim full commercial readiness until UX/productization plus the deferred runtime artifacts pass.

E11-CREDIT-21 / TODO-32I recharge-voucher runtime feasibility (historical; superseded by DOC-CREDIT-56 for runtime status): `.tmp/credit-wallet/recharge_voucher_runtime_plan.json` is plan-only evidence with schema `recharge_voucher_runtime_plan.v1`, `overall_status=contract_ready_runtime_pending`, `runtime_implemented=false`, `contract_only=true`, `secret_safe=true`, and `paid_gate_changed=false`. It maps reusable primitives and missing persistence/provider/runtime slices but does not claim payment-provider handoff or public route runtime.

E9-CREDIT-31 / TODO-32I Billing Ledger feasibility support: `.tmp/credit-wallet/recharge_voucher_contract.json` now includes `runtime_feasibility_plan` while remaining contract-only: schema `recharge_voucher_contract.v1`, status `pass`, `runtime_implemented=false`, `contract_only=true`, `secret_safe=true`, and `paid_gate_changed=false`. It maps reusable ledger/accounting primitives and missing recharge/voucher schemas, provider handoff/callback state, and live route matrix work; no recharge/voucher runtime verification is claimed.

E11-CREDIT-22 / TODO-32I-S1 recharge-voucher schema/OpenAPI boundary (historical; superseded by DOC-CREDIT-56 for runtime status): Control Plane added contract-only boundary coverage through `db/migrations/0012_recharge_voucher_boundary.sql`, synced `examples/sql_schema_draft.sql`, and `examples/openapi_admin_skeleton.yaml` endpoints for `POST /billing/recharge-intents`, `POST /admin/voucher-campaigns`, `POST /admin/voucher-issuances`, and `POST /billing/vouchers/redeem`. Unit checks cover required tables, hashed/redacted voucher-code fields, provider-reference redaction, fixed-decimal amounts, audit/ledger/credit links, and forbidden raw voucher/payment/provider secret persistence.

E9-CREDIT-33 / TODO-32I-S2 accounting support watcher (historical; superseded by DOC-CREDIT-56 for runtime status): Billing Ledger reviewed the E11 schema/OpenAPI boundary and found it aligned with fixed-decimal positive money, hashed idempotency and voucher code storage, redacted output, `credit_grant_id` / `ledger_entry_id` / `audit_id` linkage, redeem-attempt abuse/refusal persistence, no direct wallet snapshot mutation, and paid-gate neutrality.

E11-CREDIT-23 / TODO-32I-S2 voucher issue/redeem internal transaction skeleton (historical; superseded by DOC-CREDIT-56 for runtime status): Control Plane added DB-free contract helpers and focused tests for the intended voucher issue/redeem transaction order in `apps/control-plane/src/admin.rs`. The skeleton covers validation, wallet/voucher/idempotency read order, voucher code hash/redaction fields, issuance/redemption/attempt/audit link shapes, success credit grant or ledger effect linkage, replay/conflict/refusal no-write behavior, and secret-safe output.

E9-CREDIT-34 / TODO-32I-S2 post-skeleton accounting review (historical; superseded by DOC-CREDIT-56 for runtime status): Billing Ledger reviewed the E11-CREDIT-23 voucher issue/redeem contract skeleton and found it aligned with accounting invariants for hashed voucher/idempotency material, code redaction, fixed-decimal money parsing, same-key replay without duplicate credit/ledger writes, same-key changed-body conflict refusal, refusal no-write cases, redeem attempt markers, success credit grant or ledger effect plus audit linkage, secret-safe output, no direct wallet snapshot mutation, and `paid_gate_changed=false`. No E9 fixture/test/writer change was needed. This was contract-only skeleton evidence at that time; accepted internal runtime evidence is recorded in DOC-CREDIT-56.

E11-CREDIT-24 / TODO-32I-S3 SQLx statement contract (historical; superseded by DOC-CREDIT-56 for runtime status): Control Plane pinned voucher issue/redeem SQLx statement order and required fields for wallet/voucher locks, hashed idempotency and code lookup, issuance/redemption rows, redeem-attempt markers, credit-grant effect linkage, audit linkage, and redemption-count updates. This remains useful contract evidence; accepted internal runtime evidence is recorded in DOC-CREDIT-56.

E9-CREDIT-35 / TODO-32I-S3 SQLx/statement accounting watcher: Billing Ledger reviewed the E11-CREDIT-24 statement contract and found it aligned with E9 invariants for hashed voucher/idempotency material, redacted code fields, replay lookup, duplicate-code guard, redeem-attempt marker, redemption rows with credit/ledger/audit/refusal links, credit-grant effect insertion, audit insertion, secret-safe SQL, and `paid_gate_changed=false`. No E9 fixture/test/writer change was needed. This remains statement-contract evidence only; opt-in runtime execution/readback and refund/cancel reversal proof are still required before TODO-32I runtime acceptance.

E9-CREDIT-36 / TODO-32I-S4 opt-in DB/internal SQLx watcher: Billing Ledger checked for E11-CREDIT-25 runtime evidence before the E11 DB-plan verifier landed. At that point there was no recharge/voucher opt-in DB verifier script, no non-contract voucher SQLx execution function, and no `.tmp/credit-wallet/recharge_voucher_runtime.json`. No E9 contract adjustment was needed. TODO-32I runtime acceptance remains blocked until `recharge_voucher_runtime.v1` proves DB/internal invocation, replay/conflict/refusal no-write, attempt persistence, credit/ledger/audit readback, refund/cancel reversal, secret safety, and `paid_gate_changed=false`.

E11-CREDIT-25 / TODO-32I-S4 opt-in DB-plan verifier (historical; superseded by E11-CREDIT-26 and DOC-CREDIT-56): Control Plane added the DB-plan verifier and initially produced blocked DB-plan evidence with `runtime_implemented=false`, `contract_only=true`, `secret_safe=true`, and `paid_gate_changed=false`. The old blocker was `recharge_voucher_schema_0012_not_applied` because the bounded DB lacked the 0012 recharge/voucher tables such as `voucher_issuances`.

E11-CREDIT-26 / E9-CREDIT-39 / TODO-32I-S5 DB-plan progress (historical; superseded by DOC-CREDIT-56 for runtime status): E11 applied `db/migrations/0012_recharge_voucher_boundary.sql` to the bounded local compose DB and reran the opt-in DB-plan verifier. `.tmp/credit-wallet/recharge_voucher_runtime_db_plan.json` reported `overall_status=partial`, `db_integration_ran=true`, `db_plan.passed=true`, `runtime_implemented=false`, `contract_only=true`, `route_invoked=false`, `internal_sqlx_function_invoked=false`, `secret_safe=true`, and `paid_gate_changed=false`; DB-plan readback booleans were true for voucher issuance, redemption, redeem attempts, idempotency replay lookup, conflict/refusal no-write, credit grant link, ledger link, and audit link.

E11-CREDIT-27 / QA-CREDIT-55 / TODO-32I-S6 runtime gate (historical; superseded by DOC-CREDIT-56): Control Plane wrote a distinct blocked handoff artifact `.tmp/credit-wallet/recharge_voucher_runtime_s6_blocked.json` instead of misusing the runtime pass path. It reported schema `recharge_voucher_runtime_s6_blocked.v1`, `overall_status=blocked`, `runtime_implemented=false`, `contract_only=true`, `route_invoked=false`, `internal_runtime_function_invoked=false`, `db_integration_ran=true`, `secret_safe=true`, and `paid_gate_changed=false`; blockers were `route_runtime_not_invoked`, `internal_runtime_function_not_invoked`, `refund_cancel_reversal_not_implemented`, and `qa_runtime_artifact_missing`.

DOC-CREDIT-55 / TODO-32I-S10 docs watcher (historical; superseded by DOC-CREDIT-56): `.tmp/credit-wallet/recharge_voucher_runtime.json` appeared but the verifier had not yet accepted it in that run.

DOC-CREDIT-56 / TODO-32I-S11 accepted runtime sync: `.tmp/credit-wallet/recharge_voucher_runtime.json` is now accepted by `scripts/verify_credit_wallet_ledger_surface.ps1` as `recharge_voucher_runtime_verified=true`. The artifact has schema `recharge_voucher_runtime.v1`, `overall_status=pass`, `runtime_implemented=true`, `contract_only=false`, internal Rust/sqlx business path invocation true, `secret_safe=true`, and `paid_gate_changed=false`. Required readbacks are now verifier-accepted, including voucher storage/code-hash/redaction, redeem/idempotency, abuse/refusal no-write, ledger-or-credit effect, refund/cancel reversal, and audit readback. TODO-32I recharge/voucher runtime is verified through the internal business path; public route/product UX remains follow-up product polish. TODO-32F/G/H stay runtime verified, TODO-32J/K runtime remain false, and controlled paid beta is unchanged.

DOC-CREDIT-57/58/59 / TODO-32J watcher summary: payment/order/invoice remains contract verified and schema-present but runtime false. `.tmp/credit-wallet/payment_order_invoice_contract.json` is `payment_order_invoice_contract.v1` / `status=pass` / `runtime_implemented=false` / `contract_only=true`; `.tmp/credit-wallet/payment_order_invoice_runtime_s1_blocked.json` and `.tmp/credit-wallet/payment_order_invoice_runtime_s2_blocked.json` are blocked sidecars (`overall_status=blocked`, `runtime_implemented=false`, `contract_only=true`, `secret_safe=true`, `paid_gate_changed=false`) and must not be treated as runtime evidence. The earlier `payment_order_invoice_schema_missing` blocker is superseded/closed by `db/migrations/0013_payment_order_invoice_boundary.sql` and `examples/sql_schema_draft.sql`. No accepted `.tmp/credit-wallet/payment_order_invoice_runtime.json` pass artifact is present. DOC-CREDIT-60 status: TODO-32J runtime is temporarily deferred because the external payment provider/callback/capture runtime or an approved bounded internal simulation policy is not currently available; this is not complete, not a release pass, and does not expand paid controlled beta.

TODO-32J resume checklist: provider/callback/capture or approved bounded internal simulation policy; invoice/receipt runtime readback; refund/cancel/chargeback reversal readback; reconciliation readback; idempotency/conflict no-duplicate readback; audit/fixed-decimal/secret-safe proof; accepted non-contract `payment_order_invoice_runtime.v1` pass artifact; main verifier flips payment/order/invoice runtime verification to true only after that evidence exists.

| Product capability | Docx priority | Current capability | Verdict | Next backlog |
|---|---|---|---|---|
| Wallet | P0 | Wallet/balance schema, `balance_floor`, Gateway balance readback, and paid hot-path reserve/settle/refund evidence exist in controlled beta artifacts. | Present / verified for controlled paid beta evidence; not full product UX. | Productized wallet admin/user views, lifecycle operations, alerts, and runbook coverage. |
| Credit Grant | P0 | `credit_grants.remaining_amount`, `valid_from/valid_until/status/source`, Gateway balance window, paid smoke wallet/credit fixtures, and Admin create/list/read/expire/revoke live route matrix are verified. | Runtime verified for Admin CRUD/audit API; broader product UI/policy polish still pending. | Admin UI polish, operator runbook, policy controls, and long-run audit/reconciliation coverage. |
| Budget | P0 | Historical controlled paid beta artifacts and the current launch smoke now include insufficient-balance 402/no-provider-call proof; `.tmp/launch/e8_gateway_paid_hot_path_launch_check.json` is `passed` and `.tmp/launch/gateway_voucher_distribution_readiness.json` is `pass`. TODO-31 remains open for broader hard limits. | Present for controlled paid / trusted-user voucher-backed Beta evidence; broader budget productization pending. | Budget UI/API, day/month/total limits, conservative deny semantics, Admin readback, alerts, and long-run policy coverage. |
| Subscription | P1 | E9 contract-only artifact `.tmp/credit-wallet/subscription_package_lifecycle_contract.json` is verified as `status=pass`, `runtime_implemented=false`, `contract_only=true`, `secret_safe=true`, and `paid_gate_changed=false`; durable schema migration `db/migrations/0014_subscription_package_lifecycle_boundary.sql` is present; defer artifact `.tmp/credit-wallet/subscription_package_lifecycle_runtime_deferred.json` is `deferred_runtime_external_dependency`; no runtime subscription/package lifecycle is proven. | Schema migration present / runtime deferred, not complete. | Resume only when scheduler/renewal trigger, trial/proration/dunning policy, invoice/order linkage, credit/ledger effect, cancel/pause/resume, idempotency/conflict/audit/reconciliation readbacks, and QA/main accepted `subscription_package_lifecycle_runtime.v1` pass artifact are available. |
| Recharge / Voucher | P1 | `.tmp/credit-wallet/recharge_voucher_runtime.json` is accepted as `recharge_voucher_runtime_verified=true` through the internal Rust/sqlx business path. It proves voucher issue/redeem, hash/redaction, idempotency/refusal, credit/ledger/audit, and refund/cancel reversal readbacks. Public route/product UX/payment-provider packaging remains follow-up. | Runtime verified for internal business path; public product flow polish pending. | Public route/API UX if needed, payment-provider packaging, site-operator workflows, support runbook, and broader commercial polish. |
| Payment / Order / Invoice | P1 | E9 contract-only artifact `.tmp/credit-wallet/payment_order_invoice_contract.json` is verified as `status=pass`, `runtime_implemented=false`, `contract_only=true`, `secret_safe=true`, and `paid_gate_changed=false`. Schema boundary is present; S1/S2 blocked sidecars are not runtime. | Contract-ready + schema present / runtime deferred, not complete. | Resume only when provider/callback/capture or approved bounded internal simulation policy is available, then prove invoice/receipt, reversal, reconciliation, idempotency/audit readbacks, QA runtime artifact, and finance/support runbook. |
| New API balance import | P0/P1 | `POST /billing/opening-balance-imports` runtime evidence is accepted: live route invokes the internal SQLx transaction, writes opening import / ledger / audit rows, proves replay/refusal/rollback readback, and remains secret-safe. | Runtime verified for opening-balance import. | Broader migration productization: operator approval workflow, bulk import reports, UI/runbook polish, and long-run reconciliation. |
| Ledger truth | P0 | Ledger entries, idempotency, readback, reconciliation evidence, and secret-safe paid bundle are accepted for controlled beta. | Done for controlled beta evidence; RC deeper reconciliation remains. | Production source-of-truth cutover, deeper reconciliation, partial refund policy, and long-run audit. |

## Production RC TODOs

| ID | Owner | 状态 | DoD / next action |
|---|---|---|---|
| TODO-40 E8 production tokenizer/read-model backend runner | Agent-E8 | 未开始 | 真实 tokenizer/read-model 服务或持久 backend；opt-in env gate；live Gateway smoke；token evidence 到 reservation DB readback；不读取/泄露 raw prompt。 |
| TODO-41 E15 ClickHouse production smoke | Agent-E15 | 未开始 | same-session ClickHouse env/live opt-in；real smoke artifact；final closure audit readback；writer/readback counts、cursor/WAL/dedup/load-retention/fresh/non-simulated/secret-safe。 |
| TODO-42 Staging / Helm / load / chaos / security gate | Agent-Ops / Agent-Security | 未开始 | Helm staging deploy、backup/restore staging、1,000 concurrent stream load smoke、provider chaos、SBOM/image/dependency/secret scan、production readiness review。 |

## 当前可引用证据

| Lane | Evidence | 结论 |
|---|---|---|
| E8 | `.tmp/gateway_tpm_production_backend/e8-s116-live-smoke.json` | dev live smoke prototype；`local_prototype=true`，不可当 production final。 |
| E9 | `.tmp/paid-beta/real_paid_evidence_bundle.json`、`.tmp/paid-beta/e9_paid_readiness_gate.json` | Main review accepted controlled paid beta bundle/readiness evidence. Older cutover/local artifacts remain historical and are not the release basis. |
| E11 | `artifacts/control_plane_ledger_execute_runtime_current_handoff.json`、`artifacts/billing_execute_browser_live_e2e_evidence.json` | 旧 closure 证据存在；`TODO/` 新口径要求 fresh beta artifact。 |
| E13 | `.tmp/prompt_protection_beta_closure_report.json` | Beta pass: `status=passed`, `exit_code=0`, `beta_closure_eligible=true`, 4 endpoint cases passed, `provider_attempts_count=0`, runtime/current rows `4/4`, API readback pass, secret-safe scan pass. RC-only accepted redeploy evidence remains separate. |
| E15 | `.tmp/clickhouse-log-store/local-smoke/tenant-00000000-0000-0000-0000-000000000001.json` | local prototype；不可当 production final。 |

## Repository Truth Reset Classification

同步时间：2026-06-05；基线 commit：`8e3318d`。

### Commit

- CI / governance：`.github/workflows/ci.yml`、`.gitignore`、`TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md`、`TODO/AI_GATEWAY_AGENT_EXECUTION_PACK_2026-06-05.md`、`TODO/AI_GATEWAY_TOD_TECH_DEBT_2026-06-05.md`、`TODO.md`、`docs/TODO.md`、`docs/P0_BETA_STATUS.md`、`project/ACCEPTANCE_CHECKLIST.md`、`project/PROJECT_BOARD.csv`。
- TODO documentation tree：`docs/todo/epics/**`、`docs/todo/slices/**` should remain commit candidates; do not route `docs/TODO.md` back to being the entry point.

### Needs Review By Owning Agent Before Commit

- Gateway / E8 lane: `apps/gateway/src/db.rs`, `apps/gateway/src/main.rs`, `apps/gateway/src/tpm_estimate.rs`, `scripts/run_gateway_tpm_production_backend_evidence.ps1`, `scripts/verify_gateway_tpm_production_backend_evidence.ps1`, `scripts/operator/e8_rate_limit_db_acquire_readback.sql`, `tests/fixtures/gateway/rate_limit_tpm_estimate_mapper_contract.json`, `tests/fixtures/gateway/production_backend_*.json`, `tests/fixtures/gateway/trusted_read_model_backend_harness_ready.json`, `docs/E8-004_PRODUCTION_BACKEND_EVIDENCE_RUNBOOK.md`.
- E11 / Admin UI billing lane: `scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1`, `web/admin-ui/src/App.test.tsx`, `web/admin-ui/src/billingExecuteSmokeContract.ts`, `web/admin-ui/src/billingExecuteSmokeContract.serializable.json`.
- E13 / prompt protection lane: `scripts/verify_prompt_protection_postgres_proof.ps1`, `docs/E13-005_PROMPT_PROTECTION_POSTGRES_PROOF_RUNBOOK.md`.
- E15 / ClickHouse lane: `apps/worker/src/clickhouse_log_store.rs`, `apps/worker/src/main.rs`, `crates/observability/src/clickhouse_log_store.rs`, `deploy/docker-compose/docker-compose.clickhouse.local.yml`, `tests/fixtures/observability/clickhouse_log_store_contract.json`, `tests/fixtures/worker/clickhouse_log_store_plan_contract.json`, `tests/fixtures/worker/clickhouse_log_store_local_compose_contract.json`, `tests/fixtures/worker/clickhouse_production_smoke_artifact_accepted_simulation.json`.
- Release / QA lane: `scripts/release_check.ps1`, `scripts/test.ps1`, `scripts/verify_release_negative_guards.ps1`.

### Ignore

- Dependency/build/cache outputs: `node_modules/`, `web/admin-ui/node_modules/`, `tests/integration/sdk-smoke/node_modules/`, `target/`, `target-codex*/`, `web/admin-ui/dist/`, `web/admin-ui/tsconfig.tsbuildinfo`, `.tool-cache/`, `__pycache__/`, `.pytest_cache/`, `coverage/`, `.nyc_output/`, `playwright-report/`, `test-results/`.
- Imported/local-only binary references: `*.zip`, `*.docx`, unpacked `.docx_unpacked/` and `dev_starter_unpacked/`.
- Local screenshots and UI captures: `admin-ui-*.png`.

### Operator-Only Artifact

- Runtime/evidence outputs under `artifacts/`, `.tmp/`, `apps/gateway/.tmp/`, `apps/worker/.tmp/`, and `.tmp/**` should not be deleted during review. They may be cited as operator evidence only when fresh, secret-safe, repo-bounded, and non-simulated according to the relevant TODO gate.

### Current Checks

- `git diff --check` returned no whitespace errors; only line-ending normalization warnings for existing modified files.
- `.github/workflows/ci.yml` was inspected and is present. The later 2026-06-07 full wrapper rerun passed end-to-end; `E0-002` is `Done`. Evidence: `.tmp/launch/full_wrapper_rerun_20260607_143200_pass.json`.

## Historical Preflight Records

The 2026-06-05 TODO-20 and QA-PAID records below are retained as audit history. They are superseded for current API distribution coordination by the 2026-06-06 launch summary above: `ready_to_distribute_api=true` for trusted-user voucher-backed Beta, `global_blockers=[]`, and per-user fields blocking only actual handoff. Do not use older `paid_controlled_beta_allowed=false`, TODO-12 live-pending, Admin UI full-wrapper, or final Beta summary blockers in this historical section as current global blockers for scoped API distribution.

## TODO-20A Full Local Gate Preflight

同步时间：2026-06-05；基线 commit：`8e3318d`。本节是 preflight 摘要；若与 `TODO/` 冲突，以 `TODO/` 为准。

| Check | Command | Exit | Result |
|---|---|---:|---|
| Script availability | `Test-Path scripts/test.ps1` | 0 | present |
| Script availability | `Test-Path scripts/verify_compose_smoke.ps1` | 0 | present |
| Script availability | `Test-Path scripts/verify_sdk_smoke.ps1` | 0 | present |
| Script availability | `Test-Path scripts/scan_secrets.ps1` | 0 | present |
| Script availability | `Test-Path scripts/scan_supply_chain.ps1` | 0 | present |
| Admin UI lockfile | `Test-Path web/admin-ui/package-lock.json` | 0 | present |
| Compose smoke dry-run | `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_compose_smoke.ps1 -DryRun` | 0 | pass |
| SDK smoke dry-run | `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_sdk_smoke.ps1 -DryRun` | 0 | pass |
| E8 wrapper dry-run | `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1 -GatewayRateLimitReservationSmokeOnly` | 0 | pass after current E8 script refresh; still not live closure |
| E11 wrapper contract | `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1 -ControlPlaneLedgerAdjustmentExecuteSmokeOnly` | 0 | pass; live runtime-current/browser mutation still pending |
| E13 wrapper contract | `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1 -PromptProtectionPostgresProofOnly` | 0 | pass; live Beta closure report now passed in `.tmp/prompt_protection_beta_closure_report.json` |
| Secret scan | `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/scan_secrets.ps1` | 0 | pass after MISC-Security-S1 marker remediation; scanner rules were not relaxed |
| Supply-chain offline scan | `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/scan_supply_chain.ps1 -SkipNetwork` | 0 | pass with warnings: missing `trivy`/`grype`, digest pinning gaps |
| Full wrapper gate | `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1` | 0 | Superseded pass: 2026-06-07 rerun passed end-to-end after fixing `admin::tests::ledger_adjustment_runtime_writer_cutover_blocks_local_execute_commit_until_runtime_branch_ready`. Evidence: `.tmp/launch/full_wrapper_rerun_20260607_143200_pass.json`. |

Preflight artifact: `artifacts/beta_acceptance_preflight_20260605_qa_preflight.json`, with `preflight_only=true`, `simulation=false`, and `pass=false`.

## TODO-20B Beta Acceptance Delta Preflight Refresh

同步时间：2026-06-05；基线 commit：`8e3318d`。Artifact: `artifacts/beta_acceptance_preflight_20260605_delta_refresh.json`.

Overall status: `blocked`; `not_final_beta_acceptance=true`.

| Check | Status | Evidence |
|---|---|---|
| Secret scan | pass | `scripts/scan_secrets.ps1` exit 0, hits=0/warnings=0 |
| Billing release gate | pass | Historical `scripts/release_check.ps1 -Checks billing` pass covered fallback/refusal semantics; main review now accepted controlled paid beta evidence with real bundle/readiness/QA artifacts. |
| E13 prompt protection | pass | `verify_prompt_protection_postgres_proof.ps1 -ContractOnly` exit 0; `.tmp/prompt_protection_beta_closure_review_report.json` readback passed with 4 live request ids, provider attempts zero, runtime/current rows 4/4, provenance pass, secret-safe pass |
| E11 billing mutation | pass | `verify_control_plane_ledger_adjustment_execute_smoke.ps1 -ArtifactReadbackOnly` exit 0; runtime-current/browser artifact readback passed, API/DB/UI/audit readback markers passed, secret-safe true |
| E8 rate-limit reservation | preflight pass / live pending | `scripts/test.ps1 -GatewayRateLimitReservationSmokeOnly` exit 0 and `-GatewayRateLimitReservationSmokePreflight` exit 0; both sent no live requests, so TODO-12 still needs owner-reviewed live acquire/release/readback closure |
| Full TODO-20 gate | blocked | Full `scripts/test.ps1`, runtime compose/SDK smoke, full Admin UI npm gate, and `beta_acceptance_summary_<run_id>.json` not run/generated in this preflight refresh |

Current paid QA evidence: real paid evidence bundle accepted, E8/Gateway paid hot path evidence accepted, E11 paid readback/reconciliation evidence accepted, and final paid aggregator accepted by main review. E13/TODO-11 is no longer a QA blocker for Beta acceptance; browser detail and accepted redeploy evidence remain outside paid blockers.

## TODO-20B-R Paid Requested Beta Acceptance Preflight Refresh

同步时间：2026-06-05；基线 commit：`8e3318d`。Artifact: `artifacts/beta_acceptance_preflight_20260605_paid_requested_refresh.json`.

Overall status: `blocked`; `not_final_beta_acceptance=true`; `paid_requested_by_user=true`; `paid_controlled_beta_requested=true`; `paid_controlled_beta_allowed=false`.

Pass/green checks: secret scan, billing release check, E13 contract + accepted artifact readback, E11 release artifact readback, E8 preflight.

Paid remaining blockers:

- Gateway paid hot path reserve/settle/refund.
- Insufficient-balance no-provider-call.
- Control Plane paid readback/reconciliation.
- Real paid evidence bundle accepted.
- Release gate paid allowed.
- Full TODO-20 wrapper/runtime/Admin UI gate and final `beta_acceptance_summary_<run_id>.json`.

## QA-PAID-02 Paid Beta Acceptance Aggregator and Copy Guard

同步时间：2026-06-05；本节只记录 QA/release preflight hygiene。`TODO/` remains authoritative.

Artifact: `artifacts/beta_acceptance_paid_aggregator_20260605_qapaid02.json`.

Current result: `blocked_expected`; `paid_controlled_beta_requested=true`; `paid_controlled_beta_allowed=false`; `not_final_if_blocked=true`.

| Check | Command | Exit | Result |
|---|---|---:|---|
| Paid acceptance aggregator | `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_acceptance.ps1` | 2 | Expected blocked; missing E9 paid readiness JSON, E8 Gateway paid hot path artifact, E11 Control Plane paid readback/reconciliation artifact, and real paid evidence bundle. Secret scan subcheck passed. |
| Paid stale-copy guard | `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_status_copy_guard.ps1` | 0 | Current TODO/P0/release docs/scripts have no high-risk stale copy saying paid is unselected or usage-only is the only target. |
| Secret scan | `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/scan_secrets.ps1` | 0 | hits=0, warnings=0 |
| Billing release regression | `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/release_check.ps1 -Checks billing` | 0 | Pass means fallback usage-only remains safe and paid is refused until TODO-30 real evidence exists; it does not allow paid. |

Remaining paid blockers for QA aggregation: Gateway paid hot path reserve/settle/refund, insufficient-balance no-provider-call, Control Plane paid readback/reconciliation, real paid evidence bundle accepted, and release gate paid allowed.

## QA-PAID-03 Parameterized Paid Aggregator + Exit Semantics

同步时间：2026-06-05；本节只记录 QA/release aggregator hardening。`TODO/` remains authoritative.

Artifact: `artifacts/beta_acceptance_paid_aggregator_20260605_qapaid03.json`.

Current result: `blocked_expected`; JSON `schema=paid_beta_acceptance_aggregator_v2`; `actual_exit_code=2`; `paid_controlled_beta_requested=true`; `paid_controlled_beta_allowed=false`.

Aggregator parameters now supported: `-E9ReadinessPath`, `-GatewayPaidHotPathArtifactPath`, `-ControlPlanePaidReadbackArtifactPath`, `-RealPaidEvidenceBundlePath`, and `-OutputPath`. Default paths remain `.tmp/paid-beta/e9_paid_readiness_gate.json`, `.tmp/paid-beta/e8_gateway_paid_hot_path.json`, `.tmp/paid-beta/e11_control_plane_paid_readback_reconciliation.json`, and `.tmp/paid-beta/real_paid_evidence_bundle.json`. Input and output paths are repo-bounded to `.tmp/**` or `artifacts/**`.

Exit semantics: pass exits 0; unsafe path, secret scan/tool failure, or other tool failure exits 1; blocked-until-real-evidence exits 2 and emits JSON `actual_exit_code=2`. Current shell wrapper preserved child `$LASTEXITCODE=2` for the default blocked path.

Validation:

- Default blocked: `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_acceptance.ps1` -> child `$LASTEXITCODE=2`, JSON `overall_status=blocked`.
- Unsafe path: `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_acceptance.ps1 -E9ReadinessPath ..\unsafe.json -SkipSecretScan` -> child `$LASTEXITCODE=1`, JSON `overall_status=fail`.
- Selftest: `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_acceptance.ps1 -SelfTest` -> exit 0; covers missing inputs blocked, unsafe path refused, synthetic/contract-only release blocked, accepted fixture release blocked, accepted fixture test mode pass.

## QA-PAID-04 Aggregator Blocked Artifact Reason Propagation

同步时间：2026-06-05；本节只记录 QA aggregator precision improvement。`TODO/` remains authoritative.

Artifact: `artifacts/beta_acceptance_paid_aggregator_20260605_qapaid04.json`.

Current result: `blocked_expected`; JSON `actual_exit_code=2`. Aggregator blocked checks now propagate artifact-reported state instead of collapsing existing blocked artifacts to `not_accepted_shape`.

Observed current blockers:

- E9 readiness artifact `.tmp/paid-beta/e9_paid_readiness_gate.json`: `artifact_overall_status=blocked`, `artifact_actual_exit_code=2`, `artifact_decision=paid_controlled_beta_refused_missing_evidence`, blockers include `gateway_hot_path_reserve_settle_refund`, `insufficient_balance_prevents_provider_call`, and `paid_evidence_bundle_missing`.
- E11 readback artifact `.tmp/paid-beta/e11_control_plane_paid_readback_reconciliation.json`: `artifact_overall_status=blocked`, `artifact_actual_exit_code=2`, blockers include `gateway_paid_hot_path_artifact_missing`.

Validation: default blocked child exit 2; unsafe path child exit 1; `-SelfTest` exit 0; copy guard exit 0; scoped `git diff --check` exit 0.

## QA-PAID-05 Post-E8 Paid Aggregator Rerun Handoff

同步时间：2026-06-05；本节只记录 QA handoff rerun。`TODO/` remains authoritative.

Artifact: `artifacts/beta_acceptance_paid_aggregator_20260605_qapaid05_post_e8_handoff.json`.

Current result: `waiting_for_e8_gateway_paid_hot_path`; JSON `overall_status=blocked`, `actual_exit_code=2`, `paid_controlled_beta_allowed=false`.

Observed inputs:

- `.tmp/paid-beta/e8_gateway_paid_hot_path.json`: missing.
- `.tmp/paid-beta/e11_control_plane_paid_readback_reconciliation.json`: present but `overall_status=blocked`, blocker `gateway_paid_hot_path_artifact_missing`.
- `.tmp/paid-beta/e9_paid_readiness_gate.json`: present but `classification=blocked`, decision `paid_controlled_beta_refused_missing_evidence`.
- `.tmp/paid-beta/real_paid_evidence_bundle.json`: missing.

Validation: aggregator child exit 2; copy guard exit 0; secret scan exit 0; scoped `git diff --check` exit 0. Paid remains blocked; no business logic changed.

## QA-PAID-08 Paid Artifact Consumer Contract Check

同步时间：2026-06-05；本节只记录 QA artifact consumer contract。`TODO/` remains authoritative.

Command: `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_artifact_contracts.ps1`.

Current result: `blocked_expected`; JSON `schema=paid_beta_artifact_consumer_contracts_v1`, `overall_status=blocked`, `actual_exit_code=2`.

Observed consumer statuses:

- E8 `.tmp/paid-beta/e8_gateway_paid_hot_path.json`: exists and reports `status=passed`, but QA consumer contract is blocked with `gateway_paid_hot_path_consumer_shape_missing` because `operation_ids_missing`. Request ids are present.
- E11 `.tmp/paid-beta/e11_control_plane_paid_readback_reconciliation.json`: blocked and its artifact blockers are propagated.
- E9 `.tmp/paid-beta/e9_paid_readiness_gate.json`: blocked and its missing-evidence blockers are propagated.
- Bundle `.tmp/paid-beta/real_paid_evidence_bundle.json`: blocked until accepted real paid evidence bundle is consumable.

Validation: consumer contract child exit 2; copy guard exit 0; secret scan exit 0; scoped `git diff --check` exit 0. Paid remains blocked; no business logic changed.

## QA-PAID-09 Wait for E8 Consumer Shape Fix Then Contract+Aggregator

同步时间：2026-06-05；本节只记录 QA post-E8-shape rerun。`TODO/` remains authoritative.

Artifacts:

- E8: `.tmp/paid-beta/e8_gateway_paid_hot_path.json`, `status=passed`, `request_id_count=3`, `operation_id_count=7`.
- E11: `.tmp/paid-beta/e11_control_plane_paid_readback_reconciliation.json`, `overall_status=blocked`, `actual_exit_code=2`.
- QA aggregator: `artifacts/beta_acceptance_paid_aggregator_20260605_qapaid09.json`, `overall_status=blocked`, `actual_exit_code=2`, `paid_controlled_beta_allowed=false`.

Current result: `blocked_expected`. E8 consumer shape now passes QA contract, but E11 readback remains blocked on `control_plane_paid_readback_sql_unavailable`; E9 readiness remains blocked and the real paid evidence bundle is still missing.

Validation: consumer contract child exit 2; consumer contract `-SelfTest` exit 0 and proves `evidence[].operation_id` is consumed while missing operation ids do not pass; E11 readback child exit 2; aggregator child exit 2; copy guard exit 0; secret scan exit 0; scoped `git diff --check` exit 0. Paid remains blocked; no business logic changed.

## QA-PAID-10 Wait for E11 Mapping Refresh and Re-Aggregate

同步时间：2026-06-05；本节只记录 QA post-E11/E9 artifact rerun。`TODO/` remains authoritative.

Artifacts:

- E8 `.tmp/paid-beta/e8_gateway_paid_hot_path.json`: updated, `status=passed`, `request_id_count=3`, `operation_id_count=7`, QA consumer status `pass`.
- E11 `.tmp/paid-beta/e11_control_plane_paid_readback_reconciliation.json`: updated, `overall_status=blocked`, `actual_exit_code=2`, blocker `control_plane_paid_readback_refund_rows_missing`.
- E9 `.tmp/paid-beta/e9_paid_readiness_gate.json`: present, still blocked with decision `paid_controlled_beta_refused_missing_evidence`.
- Bundle `.tmp/paid-beta/real_paid_evidence_bundle.json`: missing.
- QA aggregator `artifacts/beta_acceptance_paid_aggregator_20260605_qapaid10.json`: `overall_status=blocked`, `actual_exit_code=2`, `paid_controlled_beta_allowed=false`.

Current result: `blocked_expected`. E8 consumer-shape blocker remains closed; remaining blockers are E11 refund rows evidence, E9 readiness/evidence, real paid evidence bundle, and final release-paid-allowed gate.

## QA-PAID-11 Watch E11-S7 and E9-S124 Outputs

同步时间：2026-06-05；本节只记录 QA rerun after E11-S7 blocker precision. `TODO/` remains authoritative.

Artifact: `artifacts/beta_acceptance_paid_aggregator_20260605_qapaid11.json`.

Current result: `blocked_expected`; aggregator JSON `overall_status=blocked`, `actual_exit_code=2`, `paid_controlled_beta_allowed=false`.

Observed inputs:

- E8 `.tmp/paid-beta/e8_gateway_paid_hot_path.json`: consumer contract pass, `request_id_count=3`, `operation_id_count=7`.
- E11 `.tmp/paid-beta/e11_control_plane_paid_readback_reconciliation.json`: `overall_status=blocked`, `actual_exit_code=2`, blockers include `control_plane_paid_readback_refund_rows_missing`.
- E9 `.tmp/paid-beta/e9_paid_readiness_gate.json`: `classification=blocked`, decision `paid_controlled_beta_refused_missing_evidence`, `paid_controlled_beta_allowed=false`.
- Bundle `.tmp/paid-beta/real_paid_evidence_bundle.json`: missing; bundle verifier not run.

Validation: consumer contract child exit 2; aggregator child exit 2; copy guard exit 0; secret scan exit 0; scoped `git diff --check` exit 0. Paid remains blocked; no business logic changed.

## QA-PAID-14 Fix Aggregator Pass Classification for E8/E11 Passed Artifacts

同步时间：2026-06-05；本节只记录 QA aggregator classification fix。`TODO/` remains authoritative.

Artifact: `artifacts/beta_acceptance_paid_aggregator_20260605_qapaid14.json`.

Current QA result: `pass`; aggregator JSON `overall_status=pass`, `actual_exit_code=0`, `paid_controlled_beta_allowed=true`. Main-thread Review has accepted the final controlled paid beta evidence decision.

Validation:

- `scripts/verify_paid_beta_acceptance.ps1 -SelfTest` exit 0; includes `e8_e11_passed_release_artifacts_pass` and `e8_missing_operation_ids_release_blocked`.
- `scripts/verify_paid_beta_artifact_contracts.ps1 -SelfTest` exit 0.
- `scripts/verify_paid_beta_artifact_contracts.ps1` exit 0; E8/E11/E9/bundle consumer statuses all pass.
- `scripts/verify_billing_paid_evidence_bundle.ps1 -BundlePath .tmp/paid-beta/real_paid_evidence_bundle.json` exit 0; accepted contract shape, controlled paid beta production-ready marker true, non-synthetic. This is not full Production RC or full commercial credit-product readiness.
- `scripts/verify_billing_beta_mode_readiness.ps1 -BillingMode paid_controlled_beta -PaidEvidenceBundlePath .tmp/paid-beta/real_paid_evidence_bundle.json` exit 0; `paid_controlled_beta_allowed=true`.
- `scripts/verify_paid_beta_acceptance.ps1 -OutputPath artifacts/beta_acceptance_paid_aggregator_20260605_qapaid14.json` exit 0; pass checks: secret scan, E9 readiness, E8 Gateway paid hot path, E11 readback/reconciliation, real paid evidence bundle.
- copy guard exit 0; secret scan exit 0; scoped `git diff --check` exit 0.

## DOC-PAID-16 Controlled Paid Beta Main Review Acceptance

同步时间：2026-06-05；本节只记录 main review acceptance。`TODO/` remains authoritative.

Current result: controlled paid beta evidence accepted by main review; `paid_controlled_beta_allowed=true`.

Accepted artifacts:

- `.tmp/paid-beta/e8_gateway_paid_hot_path.json`
- `.tmp/paid-beta/e11_control_plane_paid_readback_reconciliation.json`
- `.tmp/paid-beta/real_paid_evidence_bundle.json`
- `.tmp/paid-beta/e9_paid_readiness_gate.json`
- `artifacts/beta_acceptance_paid_aggregator_20260605_main_final_review.json`

Main review commands reported pass: artifact contracts overall pass; billing paid evidence bundle accepted contract shape with `production_hot_path_claim=true`, `contract_shape_only=false`, `synthetic_selftest=false`, `paid_controlled_beta_production_ready=true`; readiness with real bundle exit 0 and `paid_controlled_beta_allowed=true`; final QA paid aggregator exit 0 with no blocked/failed checks; secret scan exit 0.

Caveat: this is controlled paid beta evidence, not full Production RC. The bounded smoke refund endpoint is dev evidence only; partial refund policy and deeper reconciliation remain RC work.

### MISC-Security-S1 Secret Scan Selftest Marker Remediation

Result: `pass`. The five preflight findings in `scripts/verify_control_plane_ledger_adjustment_openapi_semantic.ps1` were self-test simulated bearer headers, not real credentials. They now use runtime string composition via `New-SelfTestBearerHeader`, so repository secret scan no longer sees a static bearer-token literal. The semantic wrapper self-test still emits secret-like material at runtime and verifies redaction/rejection behavior.

Validation:

- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/scan_secrets.ps1` -> exit 0.
- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -SelfTest` -> exit 0.
- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -SimulateSensitiveOutputTail` -> exit 0, redacted output.
- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -SimulateSensitiveCommandFailure` -> exit 1 by design, with redacted failure output.

## ToD Priority

| ID | 标题 | 阻塞哪个里程碑 | 顺序 |
|---|---|---|---:|
| ToD-04 | CI 可信度 | Beta | 1 |
| ToD-05 | 文档状态冲突 | Beta | 2 |
| ToD-03 | Admin UI 依赖可复现 | Beta UI gate | 3 |
| ToD-06 | 账务强一致 | Paid Beta | 4 |
| ToD-00 | 巨型 Rust 文件拆分 | Hardening / RC | 5 |
| ToD-01 | 测试债 | Hardening / RC | 6 |
| ToD-02 | Evidence 脚本统一 | Hardening / RC | 7 |
| ToD-07 | Secret 生命周期 | Beta / RC | 8 |
| ToD-08 | Observability placeholder | P1 / RC | 9 |
| ToD-09 | Importer apply/rollback | Migration Beta | 10 |
| ToD-10 | Staging/Ops | Production RC | 11 |
