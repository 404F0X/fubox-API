# Agent Coordination Log

同步日期：2026-06-05  
统筹者：主线程 Codex  
权威 TODO：`TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md`

> 当前调度口径（2026-06-06）：当下目标是让产品可以分发 API。权威入口是 `TODO/`，`docs/P0_BETA_STATUS.md` 只做摘要，`docs/TODO.md` 不得重新成为真相源。下方早期 paid follow-up / DOC-PAID-01 记录只保留为历史；不要再把旧 `paid blocked`、`usage-only decision`、或 TODO-32J/TODO-32K 外部 provider/scheduler runtime 当作当前 API 分发主线 blocker。当前主线是 trusted-user voucher-backed API distribution：operator-issued virtual key + voucher/redeem-code quota + per-user packet + manifest/secret scan。若主线程创建 `internal-trusted-beta-001`，它仅表示 CTO 指定的内部可信 Beta 用户，不是外部客户交付、public self-serve、或 full commercial launch。

> 2026-06-07 CTO update：`POST /admin/voucher-issuances` 和 `POST /billing/vouchers/redeem` 已在 Control Plane 接入真实 handler，并由 RBAC `BillingAdjust` 保护；`.tmp/launch/voucher_public_route_and_virtual_key_evidence.json` 当前为 `overall_status=pass`、`voucher_route_evidence.status=live_route_verified`、`route_invoked=true`、`route_verified=true`、`public_routes_wired=true`、`blockers=[]`。不得再把旧的 route-not-wired blocker 或 live route proof 待补口径当作当前事实。剩余缺口是 public self-serve UX/productization；否则仍不得声明 full public/self-serve readiness。

> 2026-06-07 CTO update：TODO-14 live Admin/API metadata-only readback 已通过。`.tmp/launch/request_trace_usage_live_admin_api_readback.json` 为 `overall_status=pass`、`request_id_count=11`、`trace_id_count=5`、`wallet_id_count=1`、`api_distribution_blocker=false`；脚本读取 request detail、trace summary、request-filtered ledger entries、audit logs、remaining balance，且不调用 `/payload`、不输出 token/header/raw body/provider secret。TODO-14 不再是当前 API 分发缺口；剩余是 UI/browser polish 与 Production RC 级观测 hardening。

## 2026-06-06 Current 5-Agent API Distribution Dispatch

| Lane | Agent | Owner | 当前任务 | 允许写入范围 | DoD / 不偷懒验收 |
|---|---|---|---|---|---|
| E11 Admin Billing / Operator Route | Popper | Agent-E11 | 实现或复核 operator-mediated voucher issuance / virtual-key handoff route，不把 public voucher route polish 当全局 blocker | `apps/control-plane/src/admin.rs`、OpenAPI/schema fixture、E11 runbook/slice；不得改 Gateway 或 E9 ledger core | `POST /admin/voucher-issuances` 或等价 operator path behind `BillingAdjust`；hash/redaction/idempotency/audit/readback/refusal-no-write；artifact secret-safe；若只缺 public self-serve UX，标 productization gap |
| E9 Billing Ledger / Quota Guardrails | Harvey | Agent-E9 | 维护 quota/rate/budget verifier、accounting gate、wallet/credit/voucher evidence manifest | `crates/billing-ledger/**`、`scripts/verify_trusted_user_quota_rate_budget_record.ps1`、billing fixtures、E9 slice/TODO；不得改 Gateway/Control Plane runtime | real per-user quota record 验证 fixed decimal、currency、wallet/readback、bounded refs、RPM/TPM/budget/expiry/rollback/audit；TODO-32J/K 只在外部 runtime 可用后恢复 |
| E8 Gateway Distribution Proof | Fermat | Agent-E8 | 保持 Gateway paid/balance/no-provider-call proof 与 voucher distribution readiness artifact 可被 handoff manifest 消费 | `apps/gateway/**`、Gateway smoke/readback scripts、Gateway fixtures、E8 slice/TODO；不得改 Control Plane/Admin UI | `.tmp/launch/e8_gateway_paid_hot_path_launch_check.json` passed；insufficient balance 402/no-provider-call；manifest 保留 Gateway SHA/status/schema；如 manifest 丢字段，修 manifest/script defect |
| QA / Security / Release Gate | Sagan | Agent-QA | 串行运行 handoff orchestrator、manifest verifier、quota verifier、launch release check、secret scan | `scripts/verify_*trusted_user*`、`project/ACCEPTANCE_CHECKLIST.md`、`project/RELEASE_CHECKLIST.md`、QA artifacts；不得修业务功能 | target-user handoff 全部命令 exit 0；默认 dry-run exit 2 只能表示 missing external fields；artifact repo-bounded、fresh、secret-safe；不得并行刷新/读取 `.tmp/launch` hashes |
| Docs / Product / Coordination | Copernicus | Agent-Docs / Product | 同步 TODO/P0/Board/Release 口径，防止旧 paid/global blocker 文案误导 | `TODO/**`、`docs/P0_BETA_STATUS.md`、`project/PROJECT_BOARD.csv`、release/acceptance docs；不得改代码 | `TODO/` 是权威入口；`P0_BETA_STATUS` 是摘要；`docs/TODO.md` 只指向权威源；当前 next action 是完成 per-user packet 并分发 API，不是重开 paid/global blocker |

### blocked / external-input 绕过规则

- 若缺 release owner、support contact、tenant/project/wallet ids、voucher quota、rate/budget limits、rollback owner、bounded evidence links：这是 per-user external input，允许默认包 `actual_exit_code=2`，不得升级为 global launch blocker。
- 若缺 payment provider/callback/capture、subscription scheduler/provider/invoice runtime：记录为 `deferred_runtime_external_dependency` 和 resume conditions；不得反复派实现 Agent 空转。
- 若 launch readiness artifact regression、secret scan fail、Gateway no-provider-call proof 缺失、manifest hash mismatch、quota verifier 对真实 record exit 2：这是可执行 blocker，必须派 owning Agent 修复。
- 任何 Agent 返回 blocked 时必须给出可验证的 blocker id、缺失 artifact/path、下一条可执行命令；只写 “needs external input” 不合格。

## 历史池子（2026-06-05 paid follow-up；superseded for current dispatch）

| Lane | Agent | Agent ID | 派发任务 | 写入范围摘要 | Review 后续 |
|---|---|---|---|---|---|
| QA / Security | Sagan | `019e9905-7e75-7b23-9e14-f24229090220` | QA-PAID-09 Paid contract + aggregator after E8 consumer fix | QA artifact contract verifier/docs only; no business logic | QA-PAID-08 accepted after verifier reads E8 `evidence[].operation_id`; current task verifies E8 consumer pass while E11/E9/bundle remain blocked |
| E11 Admin Billing / Paid Readback | Popper | `019e9905-e9fa-7443-9f71-fec880afcc41` | TODO-30C-S8 Consume E8 refund-after-settle evidence | E11 verifier/fixture/docs only; no Gateway/Admin UI React | S7 accepted: SQL runtime readable and tables present; current blocker is `control_plane_paid_readback_refund_rows_missing` |
| E13 Prompt Protection / Docs | Copernicus | `019e9906-5904-7100-a8c3-4dce98005b56` | DOC-PAID-11 Paid evidence index post-E8-accepted sync | Paid evidence manifest/docs only; no scripts/code | DOC-PAID-10 accepted; current task marks E8 bounded evidence accepted while paid overall remains blocked on E11/E9/QA |
| E8 Gateway Paid Hot Path | Fermat | `019e9906-c73b-7cf1-a871-ef315d122315` | TODO-30B-S5 Gateway paid refund-after-settle idempotency slice | Gateway paid smoke/readback/script/TODO; keep regressions passing | S4 accepted: stream/client cancel releases reserve and does not settle; current task targets refund-after-settle rows needed by E11 |
| E9 Billing Mode / Paid Gate | Harvey | `019e9907-4053-79e1-921e-f3cc98856ced` | E9-004-S125 Consume E11 precise refund blocker | E9 composer/fixtures/TODO only; no Gateway/Control Plane/Admin UI | S124 accepted: no bundle while E11 blocked; current task propagates `control_plane_paid_readback_refund_rows_missing` |

## TODO-30C-S2 E11 Historical Result（paid follow-up context）

- E11 release readback is pass again after fresh artifact regeneration: `scripts/test.ps1 -ControlPlaneLedgerAdjustmentExecuteBrowserReadbackOnly` exit 0.
- Fresh artifacts: `artifacts/control_plane_ledger_execute_runtime_current_verified_beta.json` and `artifacts/billing_execute_browser_live_e2e_evidence.json`; browser evidence `generated_at=2026-06-05T19:25:45.1113631Z`, mutation/readback/API/DB/UI/audit pass, secret-safe.
- Paid verifier blocked semantics: JSON contains `actual_exit_code=2` / `expected_shell_exit_code=2`; ordinary `cmd /v:on` shell observed `%ERRORLEVEL%=2`. If a runner UI normalizes non-zero to 1, QA must use JSON `actual_exit_code`.
- Paid readback remains blocked until TODO-30B real Gateway hot path artifact and Control Plane SQL readback pass.

## DOC-PAID-01 Historical Paid Product Posture（superseded by API distribution）

- Historical 2026-06-05 posture was `paid_controlled_beta_requested` with release `blocked_until_real_evidence`; this is superseded for current dispatch by accepted controlled paid beta evidence and the 2026-06-06 trusted-user voucher-backed API distribution path.
- Main review accepted E8 bounded paid hot path evidence after fresh smoke and independent SQL readback. This closes the previous E8 operation-id/readback mismatch, but does not open paid.
- Current critical blocker: E11 Control Plane paid readback remains `overall_status=blocked` / `actual_exit_code=2` with `control_plane_paid_readback_refund_rows_missing`; SQL runtime is now readable and tables are present.
- `usage_only_beta` is fallback/safe mode, not the final product choice after user authorization.
- Paid blockers remain: Gateway reserve/settle/refund hot path, insufficient balance prevents provider call, settle/refund idempotency, post-commit readback, rollback proof, reconciliation report, real evidence bundle accepted.
- E13/TODO-11 remains Beta pass; browser detail and accepted redeploy evidence stay out of the paid blocker list.

## 派发原则

- 子 Agent 不是独自在代码库里工作，不得 revert 其他人改动。
- 主线程 Review 后才更新权威 TODO 的完成状态。
- 若新任务与该 Agent 上下文强相关，使用 `send_input` 复用原 Agent。
- 若 Agent 返回 blocked，主线程必须判断是否是真 blocker；本地可实现的缺口继续派 implementation/evidence-producing slice。
- OBS / QA 暂不占池：OBS 依赖 E8/E11/E13 的 request ids；QA 依赖 E8/E11/E13 pass 与 E9 paid evidence status。

## 本轮 Review Checklist

每个 Agent 交付必须包含：

- `changed_files`
- `commands_run` with exit code
- `artifacts_written`
- `acceptance_results`
- `blockers`
- `next_task`

主线程 Review 必须确认：

- 代码改动在写入范围内。
- artifact fresh、repo-bounded、secret-safe；live pass 不得来自 fixture/simulation。
- 至少一个行为测试、contract gate 或 live smoke 支撑用户路径。
- 对应 `docs/todo/slices/*.md` 或权威 `TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md` 已回写进度。

## 2026-06-06 TODO-32 Credit/Wallet 调度同步

主线程当前结论：credit-like 底座存在，controlled paid beta 不回滚；TODO-32F opening balance import 已 runtime verified，TODO-32G Admin credit grant CRUD/Audit 已 runtime verified，TODO-32H Admin-readonly 与 user-session ownership remaining-balance runtime 已 verified，TODO-32I recharge/voucher internal Rust/sqlx runtime 已 verified。商业化 credit 产品剩余 runtime 缺口集中在 TODO-32J payment/order/invoice runtime、TODO-32K subscription/package lifecycle runtime；TODO-32I public route/product UX/payment-provider packaging 与 developer-token live matrix/UI/product polish 可作为后续硬化项。

用户最新策略：项目缺失的外部 runtime/provider/scheduler 能力不得反复空转；先标记为 `deferred_runtime_external_dependency`，写清 resume conditions，当前上线分发主线切到 voucher/redeem-code 配额 + virtual key 的 API beta。

| Lane | Agent | Agent ID | 当前任务 | Review 状态 | 下一步 DoD 摘要 |
|---|---|---|---|---|---|
| E11 Admin Billing | Popper | `019e9905-e9fa-7443-9f71-fec880afcc41` | E11-LAUNCH-19 / post-quota-verifier route backlog watcher | Quota/rate/budget verifier does not change E11 route posture. Trusted-user beta remains operator-mediated; public voucher route remains productization. First code slice is still Admin issue route only: `POST /admin/voucher-issuances` behind `BillingAdjust` with hash/redaction/idempotency/audit/readback/refusal-no-write. | Keep route implementation scoped separately from quota verifier. Next E11 implementation task should wire admin issuance route before harder user/developer redeem ownership boundary. |
| E9 Billing Ledger | Harvey | `019e9907-4053-79e1-921e-f3cc98856ced` | E9-LAUNCH-19 / quota verifier implementation review | Main thread implemented `scripts/verify_trusted_user_quota_rate_budget_record.ps1`. Selftest passes; file-mode pass fixture exits 0, file-mode blocked fixture exits expected 2. Verifier checks fixed decimal, uppercase currency, bounded refs, positive rate/budget policy, future expiry/budget window, evidence-manifest SHA recomputation, and secret-like rejection. | Use this verifier in real Release/Ops handoff after target-user summary/manifest exists. Remaining E9 gap is only real per-user quota record values from Release/Ops. |
| QA / Security | Sagan | `019e9905-7e75-7b23-9e14-f24229090220` | QA-LAUNCH-19 / final handoff command chain QA review | Final sequential chain passed locally: orchestrator selftest, orchestrator dry-run `-AllowMissingUserFields` expected exit 2, evidence-manifest verifier selftest/default summary, quota record verifier selftest, secret scan, scoped diff check. | For actual user distribution, all target-user commands must exit 0; exit 2 remains dry-run/default-only. Do not parallelize commands that refresh/read `.tmp/launch` hashes. |
| Docs/Product | Copernicus | `019e9906-5904-7100-a8c3-4dce98005b56` | DOC-LAUNCH-19 / quota verifier docs sync review | Release/P0/Acceptance docs now include quota verifier in final handoff chain and explicitly say default `ready_to_send=false` artifacts are not sendable. Release checklist records sequential/no-parallel warning for `.tmp/launch` artifact refresh. | Remaining doc risk is external input only: Release/Ops must provide real per-user fields and quota record, then rerun orchestrator + manifest verifier + quota verifier + secret scan. |
| E8 Gateway | Fermat | `019e9906-c73b-7cf1-a871-ef315d122315` | E8-LAUNCH-19 / post-quota-verifier Gateway watcher | Quota verifier does not own Gateway source behavior. Provider-attempt proof remains in `.tmp/launch/e8_gateway_paid_hot_path_launch_check.json`; manifest/verifier only preserves artifact presence/hash/status. | Continue composing E8 source artifact with manifest/quota verifiers in release review. Non-Gateway gaps remain public route productization and deferred payment/subscription runtime. |

主线程本地验证：

- `cargo test -p ai-control-plane recharge_voucher -- --nocapture`：pass，6 tests。
- `cargo test -p ai-control-plane openapi -- --nocapture`：pass，8 tests。
- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_credit_wallet_ledger_surface.ps1 -SelfTest`：pass。
- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_credit_grant_crud_runtime.ps1 -RunLiveRouteMatrix`：exit 0，`.tmp/credit-wallet/credit_grant_crud_runtime.json` 为 pass。
- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_credit_wallet_ledger_surface.ps1`：exit 0，`opening_balance_import_runtime_verified=true`，`credit_grant_crud_contract_verified=true`，`credit_grant_crud_runtime_verified=true`，`user_remaining_balance_admin_readonly_runtime_verified=true`，`user_remaining_balance_runtime_verified=true`，`recharge_voucher_runtime_verified=true`，`payment_order_invoice_runtime_verified=false`，`subscription_package_lifecycle_runtime_verified=false`。
- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/scan_secrets.ps1`：OK no hits。
- Scoped `git diff --check`：OK，`docs/todo/slices/E9-004.md` 仅 CRLF warning。

## 2026-06-06 E9-LAUNCH-08 Accounting/Guardrails Recheck

E9 rechecked the refreshed launch artifacts after E8 current Gateway evidence changed to pass. The four E9-relevant launch artifacts are now consistent:

- `.tmp/launch/e8_gateway_paid_hot_path_launch_check.json` has `schema=gateway_paid_hot_path_smoke_v1`, `status=passed`, secret-safe omission markers present.
- `.tmp/launch/gateway_voucher_distribution_readiness.json` has `schema=gateway_voucher_distribution_readiness_v1`, `status=pass`, `paid_hot_path_verified.current_launch_live_verified=true`, and `blockers=[]`.
- `.tmp/launch/voucher_backed_api_distribution_accounting_gate.json` has `schema=voucher_backed_api_distribution_accounting_gate.v1`, `overall_status=launch_ready_with_productization_gaps`, `actual_exit_code=0`, `accounting_verdict=acceptable_with_productization_gaps`, `accounting_credit_acceptable=true`, `api_distribution_launch_ready=true`, `gateway_current_enforcement_verified=true`, `payment_order_invoice_deferred=true`, and `subscription_lifecycle_deferred=true`.
- `.tmp/launch/voucher_quota_pricing_guardrails.json` has `schema=voucher_quota_pricing_guardrails.v1`, `overall_status=pass`, `actual_exit_code=0`, `guardrail_verdict=launch_ready`, `launch_ready=true`, `accounting_credit_acceptable=true`, and `missing_guardrails=[]`.

E9 conclusion: voucher-backed API beta accounting and quota/pricing guardrails are acceptable for release review. The previous Gateway enforcement blocker has closed from the Billing Ledger perspective. TODO-32J payment/order/invoice and TODO-32K subscription/package remain deferred/runtime false and are not required for the voucher-backed beta scope. Public voucher route/operator-only exception remains a productization/ops gap, not an accounting blocker.

## 2026-06-06 E9-LAUNCH-10 Quota/Rate/Budget Template Watcher

E9 reviewed `.tmp/launch/trusted_user_quota_rate_budget_record_template.json` and found the post-QA refresh had a simpler shape that did not explicitly expose all E9 accounting fields. E9 patched `scripts/write_trusted_user_quota_rate_budget_record_template.ps1` without filling real user values. The generated template now includes both the compact operator `template` and the full `trusted_user_quota_and_rate_limit_record_template` with tenant/project/user/wallet/virtual-key refs, credit amount/currency/source, voucher/redemption/credit grant/ledger ids, remaining-balance readback, model/price policy refs, RPM/TPM/concurrency/budget/profile binding, expiry/revoke/rollback, and audit/support refs.

Validation now explicitly covers fixed decimal money, currency matching, positive RPM/TPM/budget limits, active price/model-cost policy evidence, bounded virtual-key and voucher references only, post-assignment remaining-balance readback, revoke/disable procedure, audit/support id, and no raw voucher code/token/DB URL/provider key/virtual-key secret. Template status remains `template_ready`, `real_user_values_populated=false`, `secret_safe=true`, and `paid_gate_changed=false`. TODO-32J and TODO-32K stay deferred/runtime false and are not current voucher-backed beta blockers.

## 2026-06-06 E9-LAUNCH-11 Quota Template Final Watcher

## 2026-06-06 CTO-API-DIST-01 / 5-Agent API 分发主线调度

主线程按“当下先满足可信用户 API 分发”重新调度 5 个子 Agent。产品目标对齐 `AI_Gateway_NewAPI_替代产品调研与开发交付文档.docx`，但本轮只声明 scoped trusted-user / operator-mediated / voucher-backed API Beta，不声明完整自助商业化上线。

### 当前 CTO 判定

- `voucher_api_distribution_readiness` 当前为 `pass_with_productization_gaps`，`production_distribution_ready=true`，`remaining_blockers=[]`。
- `release_check.ps1 -Checks launch` 当前 exit 0，`overallStatus=warn`；warn 原因是 productization gaps，不是失败 gate。
- 默认 trusted-user handoff summary 仍为 `ready_to_send=false`，但 `blockers=[]`，原因仅是缺真实 selected-user 字段：`release_owner`、`support_contact`、`tenant_id`、`project_id`、`wallet_id`、`rate_budget_guardrails`、`voucher_quota`、`rollback_owner`。
- filled selftest packet 为 `ready_to_send=true`，证明脚本路径可发；实际发 key 前必须由 Release/Ops 填真实字段并 rerun，不得伪造。
- 无 Auth 客户端、无支付网关、无 subscription scheduler/provider、无真实外部用户字段均按 external/deferred gap 留档绕过，不作为本轮 trusted-user API Beta blocker。

### 5-Agent 结果

| Lane | 结果 | 当前阻塞分类 | 主线程处理 |
|---|---|---|---|
| Gateway | targeted `ai-gateway` tests pass；paid hot path selftest pass；Docker daemon unavailable 导致 live/preflight compose 不能本机复跑 | 环境 blocker，不是 global blocker | 保留历史 live artifacts；修复 dry-run 不得覆盖 launch live rate-limit artifact |
| Control Plane / Distribution | virtual key、credit grant、remaining balance、RBAC targeted tests pass；packet default 只缺真实用户字段 | external input gap | 接受 RBAC fixture 补齐；actual handoff 前填 selected-user 字段 |
| QA / Release | launch release warn、readiness pass_with_productization_gaps、accounting pass、guardrails pass、secret scan pass、negative guards pass | 无 global blocker | 接受 negative guard 修复；release warn 保留为 productization gap |
| Product Audit | docx 要求对照后确认只支持窄范围 trusted-user API Beta；指出 stale/rate-limit artifact 冲突 | stale evidence risk | 主线程恢复 rate-limit live artifact，修复 readiness secret scan 默认行为 |
| OBS / Explainability | TODO-14 live Admin/API metadata-only readback pass；11 个 E8/E11/E13 request ids 可读 | none for API distribution | 接受 `.tmp/launch/request_trace_usage_live_admin_api_readback.json`；后续只做 UI/browser polish/RC hardening |

### 主线程修复

- `scripts/verify_voucher_api_distribution_readiness.ps1`：默认自动执行 `scripts/scan_secrets.ps1`；`-SecretScanPassed` 仅作为上游已验证的快速路径。避免直接运行脚本时误写 `secret_scan_passed=false` 并把 launch gate 错置为 blocked。
- `scripts/verify_gateway_rate_limit_reservation_smoke.ps1`：新增保护，`-DryRun` 不允许写 `.tmp/launch/e8_gateway_rate_limit_launch_check.json`；dry-run 只能写 sidecar，例如 `.tmp/launch/e8_gateway_rate_limit_launch_check.dry_run.json`。主线程已恢复 `.tmp/launch/e8_gateway_rate_limit_launch_check.json` 为历史 live evidence。
- 刷新 release / readiness / accounting / guardrails / handoff manifest 后，manifest verifier 对 default 和 filled selftest 均通过。

### 当前可执行 handoff 链

实际发给某个 trusted user 前，Release/Ops 必须填真实字段并顺序执行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/prepare_trusted_user_api_distribution_packet.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1 -SummaryPath .tmp\launch\trusted_user_api_distribution_handoff_summary.json
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_trusted_user_quota_rate_budget_record.ps1 -RecordPath <real-filled-quota-record.json> -EvidenceManifestPath .tmp\launch\trusted_user_api_distribution_handoff_summary.json
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/scan_secrets.ps1
```

`-AllowMissingUserFields` 只用于 review/default dry-run，不得用于真实 key handoff。若严格模式仍缺字段，必须停止发 key；这不是工程 blocker，而是 Release/Ops 未提供真实用户数据。

### 后续不许空转的 deferred 项

- Public recharge/voucher route polish 或 operator-only exception approval：productization follow-up。
- TODO-32J payment/order/invoice provider callback/capture：deferred external runtime dependency。
- TODO-32K subscription/package lifecycle scheduler/provider/dunning：deferred external runtime dependency。
- Auth client / self-serve portal / OIDC：完整商业化后续，不阻塞 operator-mediated trusted-user Beta。

E9 re-read `.tmp/launch/trusted_user_quota_rate_budget_record_template.json` after E9-LAUNCH-10. No regression found: schema `trusted_user_quota_rate_budget_record_template.v1`, status `template_ready`, `actual_exit_code=0`, `real_user_values_populated=false`, all 30 required fields present, 12 detailed validation rules present, and rules cover fixed decimal money, currency matching, rate/budget limits, expiry, revoke/disable, audit/support id, and secret-safe key/voucher handling. No template/script change was needed. TODO-32J payment/order/invoice and TODO-32K subscription/package remain deferred runtime false and are not current voucher-backed beta blockers.

## 2026-06-06 MAIN-LAUNCH-12 Trusted-user handoff orchestrator

Main thread added `scripts/prepare_trusted_user_api_distribution_packet.ps1` so Release/Ops has one command that regenerates the quota/rate/budget template, writes/verifies the trusted-user distribution packet, runs launch release check, runs secret scan, and writes `.tmp/launch/trusted_user_api_distribution_handoff_summary.json`.

Verified paths:

- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts\prepare_trusted_user_api_distribution_packet.ps1 -SelfTest`: exit 0, `.tmp/launch/trusted_user_api_distribution_handoff_summary.selftest.json` has `overall_status=ready_to_send_trusted_user_beta`, `ready_to_send=true`, `missing_fields=[]`, `blockers=[]`, `release_check_overall_status=warn`, `secret_scan_passed=true`.
- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts\prepare_trusted_user_api_distribution_packet.ps1 -AllowMissingUserFields`: expected exit 2, accepted as `overall_status=blocked_by_missing_user_fields_only`, `blockers=[]`, and missing fields are release owner, support contact, tenant id, project id, wallet id, rate/budget guardrails, voucher quota, and rollback owner.
- `git diff --check -- scripts\prepare_trusted_user_api_distribution_packet.ps1`: exit 0.

Current distribution stance is unchanged: globally the trusted-user voucher-backed API beta path is ready with productization gaps, but a specific key/package must not be handed off until the real per-user packet values are supplied and the orchestrator is rerun without `-AllowMissingUserFields`. These missing real values are external inputs and should be documented/deferred rather than treated as a local engineering blocker.

## 2026-06-06 E9-LAUNCH-12 Quota/Rate/Budget Handoff Watcher

E9 audited `.tmp/launch/trusted_user_quota_rate_budget_record_template.json` for handoff readiness. Artifact state: schema `trusted_user_quota_rate_budget_record_template.v1`, task_id `E9-LAUNCH-10`, status `template_ready`, `actual_exit_code=0`, `real_user_values_populated=false`, all 30 required fields present, 12 detailed validation rules present, `secret_safe=true`, and `paid_gate_changed=false`. The template still has 26 placeholder fields; this is expected because real tenant/project/wallet/user/quota/rate/budget/expiry/revoke/audit values are external Release/Ops inputs, not an E9 engineering blocker.

Before distributing a real trusted-user API key, operator/QA must fill and validate: bounded tenant/project/user/wallet ids, bounded virtual-key ref without secret material, fixed-decimal voucher credit amount and currency, voucher/redemption/credit-grant/ledger refs, post-assignment remaining-balance readback, model/price policy refs, positive RPM/TPM/concurrency/budget limits, budget window/profile binding, credit/key expiry, revoke/disable procedure, rollback contact, and audit/support id. Later acceptance of a filled quota record requires no raw secrets, bounded voucher quota, rate and budget set, tenant/project/wallet ids matching the wallet/readback evidence, and TODO-32J/TODO-32K still treated as deferred non-blockers for voucher-backed beta.

## 2026-06-06 E9-LAUNCH-13 Handoff Orchestrator Accounting Fields Watcher

E9 reviewed `scripts/prepare_trusted_user_api_distribution_packet.ps1` and the two summary artifacts `.tmp/launch/trusted_user_api_distribution_handoff_summary.json` and `.tmp/launch/trusted_user_api_distribution_handoff_summary.selftest.json`. The orchestrator preserves the E9 handoff sequence: regenerate the quota/rate/budget template, run `verify_trusted_user_distribution_review_packet.ps1`, run launch release check, then run `scan_secrets.ps1`. Operator-provided fields are checked for secret-like material before use, and the summary records `secret_scan_passed`.

Default summary state is correct for no real user input: schema `trusted_user_api_distribution_handoff_summary.v1`, `overall_status=blocked_by_missing_user_fields_only`, `ready_to_send=false`, missing fields are release owner/support/tenant/project/wallet/quota/rate-budget/rollback owner, `blockers=[]`, `secret_scan_passed=true`, and `external_input_policy.missing_real_user_fields_are_deferred=true`. Filled selftest state is also correct: `overall_status=ready_to_send_trusted_user_beta`, `ready_to_send=true`, `missing_fields=[]`, `blockers=[]`, `secret_scan_passed=true`, and bounded refs/amounts only. No E9 script bug was found. TODO-32J payment/order/invoice and TODO-32K subscription/package remain deferred runtime false and non-blocking for voucher-backed beta.

## 2026-06-06 MAIN-LAUNCH-14 Trusted-user evidence manifest

Main thread extended `scripts/prepare_trusted_user_api_distribution_packet.ps1` so every handoff summary now includes `evidence_manifest` with repo-bounded paths, required/existing flags, byte size, SHA256, schema, status/overall status, `ready_to_send`, blocker count, missing-field count, and generated timestamp. The manifest intentionally stores artifact metadata only; it does not store command output, raw voucher codes, full virtual keys, Authorization/Cookie headers, provider keys, DB URLs, raw request bodies, or raw provider payloads.

Verified paths:

- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts\prepare_trusted_user_api_distribution_packet.ps1 -SelfTest`: exit 0; selftest summary remains `ready_to_send_trusted_user_beta`, manifest has 13 entries, no missing required entries, no missing hashes for existing artifacts, and the packet entry has `ready_to_send=true`.
- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts\prepare_trusted_user_api_distribution_packet.ps1 -AllowMissingUserFields`: expected exit 2; default summary remains `blocked_by_missing_user_fields_only`, manifest has 13 entries, no missing required entries, no missing hashes for existing artifacts, and the packet entry records 8 missing external user fields.
- Historical note: at this point the only manifest entry with `blockers_count>0` was `voucher_public_route_and_virtual_key_evidence` because its then-current `overall_status=partial`. This was later superseded by live voucher route proof; the current artifact is `overall_status=pass`, `route_invoked=true`, `route_verified=true`, `public_routes_wired=true`, and `blockers=[]`. Remaining gap is public self-serve UX/productization, not route wiring or live invocation.
- `git diff --check -- scripts\prepare_trusted_user_api_distribution_packet.ps1`: exit 0.

Release/Ops should archive `.tmp/launch/trusted_user_api_distribution_handoff_summary.<trusted-user-id>.json`; it now carries both the handoff verdict and the hash manifest for packet, release, quota, accounting, Gateway, guardrail, voucher route, operator, remaining-balance, and voucher runtime evidence.

## 2026-06-06 MAIN-LAUNCH-15 Evidence manifest verifier

Main thread added `scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1` as the standalone regression guard for handoff summary manifests. It verifies summary schema, manifest schema, SHA256 algorithm, required evidence entries, empty `missing_required_entries`, repo-bounded paths, positive byte sizes for existing artifacts, lowercase 64-hex SHA256 hashes, metadata-only entry fields, and secret-like value rejection. It does not require `ready_to_send=true`, so the default missing-fields summary remains valid for review while still not sendable to users.

Verified paths:

- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts\verify_trusted_user_api_distribution_evidence_manifest.ps1 -SelfTest`: exit 0; selftest accepts a good summary and rejects missing required entry, bad SHA256, unallowed manifest field, and secret-like manifest value.
- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts\verify_trusted_user_api_distribution_evidence_manifest.ps1 -SummaryPath .tmp\launch\trusted_user_api_distribution_handoff_summary.json`: exit 0; default summary manifest passes while summary remains `blocked_by_missing_user_fields_only`.
- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts\verify_trusted_user_api_distribution_evidence_manifest.ps1 -SummaryPath .tmp\launch\trusted_user_api_distribution_handoff_summary.selftest.json`: exit 0; filled selftest summary manifest passes.
- `git diff --check -- scripts\verify_trusted_user_api_distribution_evidence_manifest.ps1`: exit 0.

Release/Ops final packet review should run this verifier against the target-user handoff summary after the orchestrator completes and before key handoff.

## 2026-06-06 MAIN-LAUNCH-16 Quota/rate/budget record verifier

Main thread added `scripts/verify_trusted_user_quota_rate_budget_record.ps1` so Release/Ops can validate the real selected-user quota/rate/budget record before API key handoff. The script validates `trusted_user_quota_rate_budget_record.v1`, requires `real_user_values_present=true`, fixed-decimal money strings, uppercase currency, bounded tenant/project/user/wallet/key/voucher/ledger/audit refs, positive RPM/TPM/concurrency policy, future expiry timestamps, budget window, rollback/audit fields, repo-bounded evidence links, `secret_safe=true`, `paid_gate_changed=false`, and embedded evidence-manifest SHA256 checks for quota template, accounting gate, guardrails, remaining-balance runtime, and recharge-voucher runtime. It rejects raw voucher/key/provider/auth/cookie/DB/request-body/provider-payload/idempotency-like material.

Verified paths:

- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts\verify_trusted_user_quota_rate_budget_record.ps1 -SelfTest`: exit 0; synthetic bounded record passes and placeholder, bad money, invalid currency, and secret-like record cases block with exit-code semantics.
- File-mode pass fixture `.tmp/launch/trusted_user_quota_rate_budget_record.selftest.pass.json`: verifier exit 0 and writes `.tmp/launch/trusted_user_quota_rate_budget_record_verification.selftest.pass.json`.
- File-mode blocked fixture `.tmp/launch/trusted_user_quota_rate_budget_record.selftest.blocked.json`: verifier returns `actual_exit_code=2` as expected and writes `.tmp/launch/trusted_user_quota_rate_budget_record_verification.selftest.blocked.json`.
- Sequential handoff verification chain passed: orchestrator selftest, orchestrator `-AllowMissingUserFields` expected exit 2, evidence-manifest verifier selftest/default summary, and quota record verifier selftest. Do not run orchestrator and manifest/quota verifiers in parallel because they read/write the same `.tmp/launch` artifacts.

Real handoff rule: when Release/Ops supplies a real quota/rate/budget record, run this verifier after the orchestrator has generated the target-user handoff summary and after the evidence manifest verifier passes. For actual handoff, all commands must exit 0; exit 2 is allowed only for dry-run/default missing-field review paths.

## 2026-06-06 E9-LAUNCH-14 Accounting Evidence Manifest Review

E9 reviewed the current accounting/quota evidence required in the trusted-user handoff manifest. Minimum E9 manifest entries before handoff:

- `.tmp/launch/trusted_user_quota_rate_budget_record_template.json`: schema `trusted_user_quota_rate_budget_record_template.v1`, status `template_ready`, `secret_safe=true`, `paid_gate_changed=false`.
- `.tmp/launch/voucher_backed_api_distribution_accounting_gate.json`: schema `voucher_backed_api_distribution_accounting_gate.v1`, `overall_status=launch_ready_with_productization_gaps`, `actual_exit_code=0`, `accounting_credit_acceptable=true`, `secret_safe=true`.
- `.tmp/launch/voucher_quota_pricing_guardrails.json`: schema `voucher_quota_pricing_guardrails.v1`, `overall_status=pass`, `actual_exit_code=0`, no missing guardrails, `secret_safe=true`.
- `.tmp/credit-wallet/user_remaining_balance_ownership_runtime.json`: schema `user_remaining_balance_runtime.v1`, `overall_status=pass`, `secret_safe=true`, `paid_gate_changed=false`.
- `.tmp/credit-wallet/recharge_voucher_runtime.json`: schema `recharge_voucher_runtime.v1`, `overall_status=pass`, `secret_safe=true`, `paid_gate_changed=false`.

Manifest acceptance criteria: each required entry must be repo-bounded and include path, schema/schema_version, status or overall_status, SHA256, size, last-write/generated timestamp where available, `secret_safe`, and `paid_gate_changed` where applicable. Manifest content must remain metadata-only: no raw voucher code, no raw virtual-key secret, no Authorization/Cookie header, no DB URL, no provider key, no raw provider payload, and no raw request body. Optional handoff summary/selftest entries may be included, but selftest evidence must stay labeled as selftest and the default summary may remain `blocked_by_missing_user_fields_only` until Release/Ops supplies real per-user fields.

Main-thread review correction after E9 returned: the orchestrator was rerun after manifest support landed. Current `.tmp/launch/trusted_user_api_distribution_handoff_summary.json` and `.tmp/launch/trusted_user_api_distribution_handoff_summary.selftest.json` now contain `evidence_manifest` with 13 entries, no missing required entries, and no missing SHA256 for existing artifacts. TODO-32J payment/order/invoice and TODO-32K subscription/package remain deferred runtime false and non-blocking for the voucher-backed beta scope.

## 2026-06-06 E9-LAUNCH-15 Current Evidence Manifest Accounting Rereview

E9 re-read the current `.tmp/launch/trusted_user_api_distribution_handoff_summary.json` after the orchestrator rerun. Current state: summary schema `trusted_user_api_distribution_handoff_summary.v1`, summary status `blocked_by_missing_user_fields_only`, manifest schema `trusted_user_api_distribution_evidence_manifest.v1`, hash algorithm `SHA256`, 13 manifest entries, and `missing_required_entries=[]`.

E9 required entries are present and hashed:

- `trusted_user_quota_rate_budget_template`: path `.tmp/launch/trusted_user_quota_rate_budget_record_template.json`, schema `trusted_user_quota_rate_budget_record_template.v1`, status `template_ready`, SHA256 present.
- `voucher_backed_api_distribution_accounting_gate`: path `.tmp/launch/voucher_backed_api_distribution_accounting_gate.json`, schema `voucher_backed_api_distribution_accounting_gate.v1`, `overall_status=launch_ready_with_productization_gaps`, SHA256 present.
- `voucher_quota_pricing_guardrails`: path `.tmp/launch/voucher_quota_pricing_guardrails.json`, schema `voucher_quota_pricing_guardrails.v1`, `overall_status=pass`, SHA256 present.
- `user_remaining_balance_runtime`: path `.tmp/credit-wallet/user_remaining_balance_ownership_runtime.json`, schema `user_remaining_balance_runtime.v1`, `overall_status=pass`, SHA256 present.
- `recharge_voucher_runtime`: path `.tmp/credit-wallet/recharge_voucher_runtime.json`, schema `recharge_voucher_runtime.v1`, `overall_status=pass`, SHA256 present.

Manifest verdict: accepted for E9 accounting handoff. The manifest notes remain metadata-only: repo-bounded paths, hashes, sizes, schemas, statuses, and counts only. It must not include raw voucher codes, full virtual keys, Authorization/Cookie headers, provider keys, DB URLs, raw request bodies, raw provider payloads, or unbounded operator text. The default handoff summary still has missing external user fields; that is a Release/Ops input gap, not an accounting evidence gap. TODO-32J payment/order/invoice and TODO-32K subscription/package remain deferred runtime false and non-blocking for the voucher-backed beta scope.

## 2026-06-06 E9-LAUNCH-16 Operator Quota Record Acceptance Contract Scoping

E9 inspected the current quota/rate/budget template and orchestrator path. The template artifact `.tmp/launch/trusted_user_quota_rate_budget_record_template.json` exposes the expected structured record fields for tenant/project/user/wallet, bounded virtual-key ref, fixed-decimal credit amount, currency, voucher/redemption/credit-grant/ledger refs, remaining-balance readback, price/model policy, RPM/TPM/concurrency/budget, expiry, revoke/rollback, and audit/support refs. The orchestrator and `scripts/verify_trusted_user_distribution_review_packet.ps1` currently verify packet-level missing fields, productization evidence links, rollback checklist, and secret scan, but they do not parse a filled `trusted_user_quota_and_rate_limit_record` as a dedicated contract.

Recommended next small script: `scripts/verify_trusted_user_quota_rate_budget_record.ps1`, optional for dry-run now and required before handing off a real selected-user key. Proposed DoD:

- Inputs: `-RecordPath <json>`, optional expected evidence paths for quota template, accounting gate, guardrails, remaining-balance runtime, recharge-voucher runtime, and handoff manifest.
- Validate fixed decimal strings for credit amount, budget amount, and remaining balance; reject floats and non-positive credit/budget.
- Validate currency matches voucher quota evidence and remaining-balance wallet currency.
- Validate tenant/project/user/wallet/virtual-key/voucher/redemption/credit-grant/ledger/model/price-policy/audit ids are bounded references, not raw payloads or secrets.
- Validate positive RPM/TPM limits, explicit concurrency policy, budget window/profile binding, expiry timestamps, revoke/disable procedure, rollback owner/contact, and audit/support ticket.
- Validate evidence links are present and currently pass where required: accounting gate, guardrails, remaining-balance runtime, recharge-voucher runtime, and metadata-only handoff manifest.
- Reject raw voucher code, full virtual-key secret, Authorization/Cookie header, DB URL, provider key, provider payload, raw request body, raw idempotency secret, and unbounded operator prose.
- Output a secret-safe JSON artifact under `.tmp/launch/trusted_user_quota_rate_budget_record_verification.json` with `schema=trusted_user_quota_rate_budget_record_verification.v1`, `status=pass|blocked`, `ready_for_handoff`, blockers, missing fields, evidence hashes, and `real_user_values_present=true` only for a real filled record.

Decision: for a one-off trusted-user beta this could remain a checklist if Release/Ops manually reviews the record, but a small verifier is recommended before sending any real key because it closes the last E9-controlled ambiguity in the handoff packet without requiring external payment/subscription runtime. TODO-32J payment/order/invoice and TODO-32K subscription/package remain deferred runtime false and non-blocking for the voucher-backed beta scope.

## 2026-06-06 E9-LAUNCH-17 Quota-record Verifier Handoff to Main

E9 refined `scripts/verify_trusted_user_quota_rate_budget_record.ps1` into an implementation checklist. The verifier must stay independent of real user values: default mode validates a caller-supplied record, and `-SelfTest` uses synthetic bounded fixtures only.

Proposed parameters:

- `-RecordPath <json>`: required outside `-SelfTest`; path must be repo-bounded under `.tmp/**` or `artifacts/**`.
- `-OutputPath <json>`: default `.tmp/launch/trusted_user_quota_rate_budget_record_verification.json`; repo-bounded under `.tmp/**` or `artifacts/**`.
- `-EvidenceManifestPath <json>`: default `.tmp/launch/trusted_user_api_distribution_handoff_summary.json`; consume embedded `evidence_manifest` where present.
- Optional expected paths: `-QuotaTemplatePath`, `-AccountingGatePath`, `-GuardrailsPath`, `-RemainingBalanceRuntimePath`, `-RechargeVoucherRuntimePath`.
- `-SelfTest`: run fixture-free synthetic pass/blocked cases and write a selftest summary only.

Input record schema: `trusted_user_quota_rate_budget_record.v1` with `real_user_values_present=true`, tenant/project/user/wallet refs, bounded virtual-key id or prefix, fixed-decimal `credit_amount`, currency, voucher/redemption/credit-grant/ledger refs, `remaining_balance_available_to_spend`, model or canonical model id, price book/policy/version refs, positive RPM/TPM/concurrency policy, fixed-decimal budget limit, budget window/profile binding, credit/key expiry timestamps, revoke/disable procedure, rollback owner/contact, audit/support id, evidence links, and `secret_safe=true`.

Output schema: `trusted_user_quota_rate_budget_record_verification.v1` with `status=pass|blocked`, `ready_for_handoff`, `actual_exit_code`, `record_path`, `evidence_manifest_path`, `missing_fields[]`, `blockers[]`, `validation_results`, `evidence_hashes`, `hash_mismatches[]`, `real_user_values_present`, `secret_safe`, `paid_gate_changed=false`, and `no_raw_secret_material_expected=true`.

Expected exit codes:

- `0`: record is complete, secret-safe, evidence links pass, manifest hashes match when available, and `ready_for_handoff=true`.
- `2`: blocked acceptance: missing fields, placeholders, invalid money/currency/rate/budget/expiry/audit, missing evidence, hash mismatch, or secret-like material.
- `1`: script or JSON parse failure.

Selftest cases:

- synthetic bounded filled record passes with decimal money, positive RPM/TPM/budget, bounded refs, matching currency, rollback/audit present, and evidence hashes consumed.
- placeholder/default template record is blocked with missing or placeholder fields.
- float/non-positive money is blocked.
- currency mismatch is blocked.
- raw voucher code or virtual-key secret marker is blocked.
- missing evidence manifest or missing required evidence is blocked unless explicitly running a metadata-only dry-run selftest case.
- evidence manifest SHA256 mismatch is blocked.

Evidence manifest consumption: when `trusted_user_api_distribution_evidence_manifest.v1` is present, the verifier should locate the quota template, accounting gate, guardrails, remaining-balance runtime, and recharge-voucher runtime entries, verify each exists and has SHA256, recompute hashes for local paths, and record only hashes/statuses in the output. It must not embed artifact bodies or operator secrets.

Open questions for implementation: whether Release/Ops wants the real filled record as a standalone JSON file or embedded in the distribution packet; whether conservative estimated TPM is acceptable for the selected key or must be replaced by an exact TPM source; whether `concurrency_limit_positive_integer_or_not_applicable` may use an explicit `not_applicable` enum for this beta. TODO-32J payment/order/invoice and TODO-32K subscription/package remain deferred runtime false and non-blocking for voucher-backed beta.

## 2026-06-06 E9-LAUNCH-18 Quota-record Verifier Implementation Preflight

E9 prepared exact implementation inputs for `scripts/verify_trusted_user_quota_rate_budget_record.ps1`. The verifier must not require real values during implementation; `-SelfTest` can use synthetic bounded records.

Minimal accepted synthetic record:

```json
{
  "schema": "trusted_user_quota_rate_budget_record.v1",
  "real_user_values_present": true,
  "tenant_id": "tenant-trusted-001",
  "project_id": "project-trusted-001",
  "trusted_user_id_or_owner_ref": "trusted-user-001",
  "wallet_id": "wallet-trusted-001",
  "virtual_key_id_or_key_prefix": "vkref_trusted_001",
  "credit_amount_fixed_decimal_string": "100.00000000",
  "currency": "USD",
  "voucher_id_or_redemption_id": "redemption-trusted-001",
  "credit_grant_id": "credit-grant-trusted-001",
  "ledger_entry_id": "ledger-entry-trusted-001",
  "remaining_balance_available_to_spend_fixed_decimal_string": "100.00000000",
  "model_or_canonical_model_id": "model-policy-trusted",
  "price_book_id_or_policy_ref": "price-book-trusted-001",
  "price_version_id_or_model_cost_policy_ref": "price-version-trusted-001",
  "price_policy_evidence_path": ".tmp/launch/voucher_quota_pricing_guardrails.json",
  "rpm_limit_positive_integer": 60,
  "tpm_limit_positive_integer": 60000,
  "concurrency_limit_positive_integer_or_not_applicable": 1,
  "budget_limit_amount_fixed_decimal_string": "100.00000000",
  "budget_window": "2026-06-06T00:00:00Z/2026-07-06T00:00:00Z",
  "api_key_profile_id_or_profile_binding_id": "profile-trusted-001",
  "credit_valid_until_utc": "2026-07-06T00:00:00Z",
  "virtual_key_expires_at_utc": "2026-07-06T00:00:00Z",
  "revoke_or_disable_procedure": "disable_virtual_key_and_revoke_credit_grant",
  "rollback_contact": "ops-rollback-trusted",
  "operator_id": "operator-trusted-001",
  "support_owner": "support-trusted-001",
  "audit_id_or_support_ticket_id": "AUDIT-TRUSTED-001",
  "evidence_links": {
    "quota_template": ".tmp/launch/trusted_user_quota_rate_budget_record_template.json",
    "accounting_gate": ".tmp/launch/voucher_backed_api_distribution_accounting_gate.json",
    "guardrails": ".tmp/launch/voucher_quota_pricing_guardrails.json",
    "remaining_balance_runtime": ".tmp/credit-wallet/user_remaining_balance_ownership_runtime.json",
    "recharge_voucher_runtime": ".tmp/credit-wallet/recharge_voucher_runtime.json"
  },
  "secret_safe": true,
  "paid_gate_changed": false
}
```

Minimal blocked placeholder record:

```json
{
  "schema": "trusted_user_quota_rate_budget_record.v1",
  "real_user_values_present": false,
  "tenant_id": "REQUIRED_TENANT_REF",
  "wallet_id": "REQUIRED_WALLET_REF",
  "virtual_key_id_or_key_prefix": "REQUIRED_BOUNDED_KEY_REF_NO_SECRET",
  "credit_amount_fixed_decimal_string": "<decimal-string-scale-8>",
  "currency": "USD",
  "rpm_limit_positive_integer": "REQUIRED_POSITIVE_INTEGER",
  "tpm_limit_positive_integer": "REQUIRED_POSITIVE_INTEGER",
  "budget_limit_amount_fixed_decimal_string": "REQUIRED_DECIMAL_8",
  "secret_safe": true
}
```

Required fields and validation rules:

- `schema`: must equal `trusted_user_quota_rate_budget_record.v1`.
- `real_user_values_present`: must be boolean `true` for pass.
- Bounded ref fields: `tenant_id`, `project_id`, `trusted_user_id_or_owner_ref`, `wallet_id`, `virtual_key_id_or_key_prefix`, `voucher_id_or_redemption_id`, `credit_grant_id`, `ledger_entry_id`, `model_or_canonical_model_id`, `price_book_id_or_policy_ref`, `price_version_id_or_model_cost_policy_ref`, `api_key_profile_id_or_profile_binding_id`, `operator_id`, `support_owner`, `audit_id_or_support_ticket_id`; each must match `^[A-Za-z0-9][A-Za-z0-9._:-]{2,127}$`, must not start with `REQUIRED_`, must not contain `<` or `>`, and must not match secret patterns.
- Money fields: `credit_amount_fixed_decimal_string`, `budget_limit_amount_fixed_decimal_string`, `remaining_balance_available_to_spend_fixed_decimal_string`; each must be JSON string matching `^[0-9]+\\.[0-9]{8}$`; credit and budget must be greater than zero; remaining balance may be zero or positive for handoff but must not be negative.
- `currency`: must match `^[A-Z]{3}$` and equal the currency read from guardrails and remaining-balance evidence when available.
- `rpm_limit_positive_integer`, `tpm_limit_positive_integer`: JSON integer or integer string matching `^[1-9][0-9]*$`.
- `concurrency_limit_positive_integer_or_not_applicable`: JSON integer/string positive integer, or exact string `not_applicable` only if a separate policy note is present in the record.
- UTC timestamp fields `credit_valid_until_utc`, `virtual_key_expires_at_utc`: must parse as UTC ISO-8601 and be later than the verifier run time.
- `budget_window`: must match `<utc-start>/<utc-end>` where both sides parse as UTC ISO-8601 and end is after start.
- `price_policy_evidence_path` and every `evidence_links.*`: repo-bounded path under `.tmp/**` or `artifacts/**`; no absolute paths, `..`, URL schemes, or drive roots.
- `revoke_or_disable_procedure` and `rollback_contact`: non-empty bounded strings, max 128 chars, no raw secrets.
- `secret_safe`: boolean `true`; `paid_gate_changed`: absent or boolean `false`.

Secret pattern to reject in any string field, case-insensitive: `authorization`, `bearer `, `cookie`, `sk-`, `x-api-key`, `postgres://`, `postgresql://`, `mysql://`, `redis://`, `raw_voucher`, `raw key`, `raw_secret`, `provider_key`, `virtual_key_secret`, `dev_test_key`, or strings longer than 256 chars unless the field is an allowed evidence path.

Evidence manifest and SHA checks:

- Read `-EvidenceManifestPath`; if it is a handoff summary, use `.evidence_manifest`; otherwise accept a direct `trusted_user_api_distribution_evidence_manifest.v1`.
- Require manifest schema `trusted_user_api_distribution_evidence_manifest.v1`, `hash_algorithm=SHA256`, and `missing_required_entries=[]`.
- Locate entries by name: `trusted_user_quota_rate_budget_template`, `voucher_backed_api_distribution_accounting_gate`, `voucher_quota_pricing_guardrails`, `user_remaining_balance_runtime`, `recharge_voucher_runtime`.
- For each, require `exists=true`, non-empty 64-hex `sha256`, and repo-bounded `path`.
- Recompute `Get-FileHash -Algorithm SHA256` for each local path and block on mismatch.
- Cross-check record `evidence_links` paths, when present, match the manifest paths.
- Output only metadata: entry name, path, schema/status/overall_status, manifest hash, recomputed hash, and match boolean.

Implementation output should set blockers such as `record_placeholder_values_present`, `money_decimal_invalid:<field>`, `currency_mismatch`, `rate_limit_invalid:<field>`, `evidence_manifest_missing`, `evidence_manifest_required_entry_missing:<name>`, `evidence_hash_mismatch:<name>`, `secret_like_value:<field>`, or `repo_path_not_bounded:<field>`. Exit `0` only when `ready_for_handoff=true`; exit `2` for blocked validation; exit `1` for parser/script errors.

## 2026-06-07 E9-LAUNCH-20 Quota-record Evidence Body Gate Tightening

E9 rechecked the trusted-user quota/rate/budget handoff gate for the current voucher-backed API distribution scope. `scripts/verify_trusted_user_quota_rate_budget_record.ps1` now keeps the existing manifest SHA recomputation and also parses the linked evidence bodies for E9-owned accounting consistency before a real selected-user key handoff can pass.

New verifier coverage:

- RPM and TPM must be positive integers; only `concurrency_limit_positive_integer_or_not_applicable` may use the exact `not_applicable` enum.
- Accounting gate evidence must be `voucher_backed_api_distribution_accounting_gate.v1`, `overall_status=launch_ready_with_productization_gaps`, `accounting_credit_acceptable=true`, `api_distribution_launch_ready=true`, and must not require payment provider or subscription scheduler for this gate.
- TODO-32J payment/order/invoice and TODO-32K subscription/package lifecycle must remain represented as `deferred_runtime_external_dependency` with `blocks_voucher_backed_api_distribution=false`; absence of external provider/scheduler runtime is not a trusted-user voucher-backed API distribution blocker.
- Guardrails evidence must be `voucher_quota_pricing_guardrails.v1`, `overall_status=pass`, `launch_ready=true`, fixed-decimal money true, voucher credit effect verified, and remaining-balance readback verified.
- Remaining-balance evidence must be pass/runtime/read-only/secret-safe/paid-gate-neutral, and the record must match tenant/project/wallet/currency/available-to-spend/credit-grant/ledger-entry readback values.
- Recharge-voucher evidence must be pass/runtime/secret-safe/paid-gate-neutral, and the record voucher reference must match the bounded `voucher_id` or `redemption_id` with matching currency.

Selftest no longer depends on mutable default `.tmp/launch` manifest hashes. It copies current accepted evidence into `.tmp/launch/e9_quota_record_verifier_selftest/`, computes a synthetic manifest, and validates pass/blocked cases against those local fixtures. Commands run: `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_trusted_user_quota_rate_budget_record.ps1 -SelfTest` exit 0; `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/prepare_trusted_user_api_distribution_packet.ps1 -SyntheticHandoffSelfTest` exit 0. Default `prepare_trusted_user_api_distribution_packet.ps1 -AllowMissingUserFields` remains expected exit 2 with `blocked_by_missing_user_fields_only`, blockers empty, and external selected-user fields still required before handoff.

## 2026-06-06 CTO-API-DIST-02 5-Agent API Distribution Closeout

Objective: drive `/TODO` toward the delivery target in `AI_Gateway_NewAPI_替代产品调研与开发交付文档.docx`, with the immediate product goal of being able to distribute API access.

Decision: current release scope is `trusted_user_voucher_backed_api_distribution`. The product is ready to distribute API for a trusted-user, operator-mediated, voucher-backed Beta after the selected user's packet is filled. If the selected user is `internal-trusted-beta-001`, describe it as a CTO-designated internal trusted Beta user only; do not present it as external-customer availability, public self-serve access, or full commercial launch. This is not full commercial/self-serve readiness.

Final gate:

- One-key gate: `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1 -FullDistributionGateOnly`.
- Result: `.tmp/launch/final_launch_gate_summary.json` reports `final_status=trusted_user_voucher_backed_beta_ready_with_productization_gaps`, `ready_to_distribute_api=true`, `production_distribution_ready=true`, `production_distribution_full_ready=false`, `global_blockers=[]`.
- Release summary: `artifacts/launch_voucher_api_distribution_release_check_20260606.json` remains `warn` because productization gaps are intentionally documented, not because the scoped Beta is blocked.
- Secret scan: `scripts/scan_secrets.ps1` passed with `hits=0`, `warnings=0`.

5-Agent closeout:

- Agent-ReleaseDocs-StaleEvidence: added `scripts/write_api_distribution_quickstart_diagnostics_artifacts.ps1` and rewrote quickstart, diagnostics, and operator smoke-plan launch artifacts away from stale Gateway-blocked wording. Current quickstart/diagnostics now have no current blockers and derive from current launch evidence.
- Agent-Gateway-Protocols: added `tests/fixtures/gateway/api_distribution_protocol_contract.json`, `scripts/verify_sdk_smoke.ps1 -ContractOnly`, `scripts/test.ps1 -GatewayProtocolContractsOnly`, and a Gateway `/v1/models` source contract. `/v1/models` filtering is pass; OpenAI stream, Responses stream terminal, Anthropic, and Gemini remain `needs_live_compose` evidence items.
- Agent-ControlPlane-Models: added Gateway and Control Plane model/profile visibility fixtures and marked `/v1/models` key/profile filtering complete with source-backed dry-run evidence. Live multi-profile smoke still needs a preseeded multi-profile virtual key.
- Agent-Frontend-Repro: verified Admin UI dependency/distribution gate: `npm --prefix web/admin-ui ci`, `test`, `build`, and `check:bundle` all pass; bundle initial JS is under budget. Existing UI tests cover virtual keys, trace/audit detail, and billing remaining balance.
- Agent-QA-FullDistributionGate: added/updated the full distribution gate path and final launch summary. The gate classifies per-user missing fields as handoff-only external inputs, not global blockers.

Current accepted API distribution path:

- Operator issues or selects a bounded virtual key for a trusted user.
- Operator assigns or redeems voucher-backed quota and records remaining-balance/accounting evidence.
- Operator fills the per-user packet and evidence manifest.
- Operator runs the full distribution gate and handoff manifest verifier.
- API handoff can proceed only after target-user fields are real and secret-safe.

Per-user fields still required before actual key handoff:

- `release_owner`
- `support_contact`
- `tenant_id`
- `project_id`
- `wallet_id`
- `voucher_quota`
- `rate_budget_guardrails`
- `rollback_owner`

Productization gaps that remain non-blocking for this scoped Beta:

- `public_recharge_voucher_route_evidence_pending`
- `payment_order_invoice_external_runtime_deferred`
- `subscription_scheduler_provider_runtime_deferred`
- live compose/provider dispatch evidence for OpenAI stream, Responses stream terminal, Anthropic, and Gemini protocol paths

CTO instruction for next real user distribution:

1. Fill the real target-user packet values and quota/rate/budget record.
2. Run `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/prepare_trusted_user_api_distribution_packet.ps1` without `-AllowMissingUserFields`.
3. Run `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1 -SummaryPath .tmp/launch/trusted_user_api_distribution_handoff_summary.<trusted-user-id>.json`.
4. Run `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_trusted_user_quota_rate_budget_record.ps1 -RecordPath .tmp/launch/trusted_user_quota_rate_budget_record.<trusted-user-id>.json -EvidenceManifestPath .tmp/launch/trusted_user_api_distribution_handoff_summary.<trusted-user-id>.json -OutputPath .tmp/launch/trusted_user_quota_rate_budget_record_verification.<trusted-user-id>.json`.
5. Run `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1 -FullDistributionGateOnly` and archive `.tmp/launch/final_launch_gate_summary.json`.

## 2026-06-06 CTO-API-DIST-03 Handoff Rehearsal / Evidence Hardening Round

Objective: keep moving beyond the previous Beta-ready conclusion without redefining `/TODO` completion. This round focused on making the API distribution handoff repeatable, cleaning stale state sources, and isolating remaining live/prod gaps.

5-Agent dispatch:

- Agent-Docs-Truth: cleaned stale release/status wording that still implied old paid/TODO-12/Admin UI gates globally blocked current API distribution. Updated `project/RELEASE_CHECKLIST.md`, `docs/P0_BETA_STATUS.md`, and `TODO/AI_GATEWAY_AGENT_EXECUTION_PACK_2026-06-05.md` so `ready_to_distribute_api=true` is scoped to trusted-user voucher-backed Beta only.
- Agent-Handoff-Rehearsal: added `scripts/prepare_trusted_user_api_distribution_packet.ps1 -SyntheticHandoffSelfTest`. It generates synthetic packet/summary/quota-record artifacts, marks them `synthetic=true` and `not_real_user=true`, then proves manifest verifier exit 0 and quota verifier exit 0. Synthetic artifacts must not be sent to users.
- Agent-Gateway-LiveEvidence: improved SDK/protocol contract coverage for OpenAI chat stream, Responses stream terminal, Anthropic Messages, Gemini GenerateContent, and `/v1/models`. Gateway streaming smoke has since passed, and the invalid JSON parser blocker is closed; keep this as Gateway evidence, not as full wrapper/full CI completion.
- Agent-E11-OperatorRoute: clarified voucher route evidence. Operator-mediated handoff evidence is sufficient for the trusted-user path, secret-safe, and paid-gate-neutral. Public self-serve voucher routes remain unwired productization gap; operator-only route substitution remains unapproved.
- Agent-QA-CI-Gate: split QA evidence into full wrapper/full CI versus current API distribution gate. Added targeted Admin UI test/bundle gate parameters, refreshed `.tmp/launch/qa_ci_gate_summary_20260606.json`, and kept E0-002 open until full local wrapper/full CI runs.

Integrated verification run:

- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/prepare_trusted_user_api_distribution_packet.ps1 -SyntheticHandoffSelfTest` -> pass.
- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1 -SummaryPath .tmp/launch/trusted_user_api_distribution_handoff_summary.synthetic.json` -> pass.
- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_trusted_user_quota_rate_budget_record.ps1 -RecordPath .tmp/launch/trusted_user_quota_rate_budget_record.synthetic.json -EvidenceManifestPath .tmp/launch/trusted_user_api_distribution_handoff_summary.synthetic.json -OutputPath .tmp/launch/trusted_user_quota_rate_budget_record_verification.synthetic.json` -> pass.
- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1 -FullDistributionGateOnly` -> pass; `.tmp/launch/final_launch_gate_summary.json` reports `ready_to_distribute_api=true`, `production_distribution_ready=true`, `production_distribution_full_ready=false`, `global_blockers=[]`.
- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1 -GatewayProtocolContractsOnly` -> pass for contracts; live compose still pending external Docker runtime.
- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_voucher_public_route_and_virtual_key_evidence.ps1 -SelfTest` -> pass.
- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1 -AdminUiTestOnly` -> pass, 2 files / 96 tests.
- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1 -AdminUiBundleGateOnly` -> pass, initial JS 225.9 KiB / 250.0 KiB.
- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/scan_secrets.ps1` -> pass, hits 0, warnings 0.
- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/scan_supply_chain.ps1 -SkipNetwork` -> pass with warnings only: trivy/grype unavailable, network vulnerability scans skipped, container images not digest-pinned.

Current CTO decision:

- API distribution path is stronger than the previous round because it now has a synthetic end-to-end rehearsal, not just default missing-field review.
- Current trusted-user voucher-backed Beta remains distributable after real per-user fields are filled and verified.
- Actual key handoff is still blocked until real target-user values exist. This is external Release/Ops input, not a global engineering blocker.
- Full `/TODO` completion is not achieved. Remaining broad product requirements include full CI reverify, public self-serve voucher UX/productization, provider key rotation/health, request/trace query/UI completion, New API/One API migration productization, paid commercial runtimes, and Production RC.

Next owner actions:

1. Release/Ops: fill a real target-user handoff packet and quota/rate/budget record; rerun the non-synthetic handoff command chain.
2. Gateway/Ops: keep Gateway streaming smoke and invalid JSON parser regressions closed in the next full wrapper/full CI rerun.
3. E11/Product: continue public self-serve voucher UX/productization without treating route wiring or live invocation proof as pending.
4. QA/Repo: run the full local wrapper/full CI when moving E0-002 from `NeedsFullWrapperRerun` to `Done`.

## 2026-06-07 DOCS-PRODUCT-04 Current Distribution Copy Sync

Docs/Product review rechecked `TODO/AGENT_COORDINATION_2026-06-05.md`, `TODO/OPEN_SOURCE_ALPHA_PRIORITY_2026-06-06.md`, `docs/P0_BETA_STATUS.md`, `project/PROJECT_BOARD.csv`, `project/ACCEPTANCE_CHECKLIST.md`, `project/RELEASE_CHECKLIST.md`, and `README.md` for stale launch wording.

Current product posture remains unchanged: the next action for API distribution is to fill the selected user's per-user handoff packet and quota/rate/budget record, then rerun the manifest verifier, quota verifier, full distribution gate, and secret scan before sending API access. This is scoped trusted-user voucher-backed Beta distribution through operator-issued virtual key plus voucher/redeem-code quota. It is not public/self-serve commercial launch.

Copy fixes made in this pass:

- `project/ACCEPTANCE_CHECKLIST.md` no longer presents old `usage_only_beta` vs `paid_controlled_beta`, E11 Billing/Price mutation, E13 Prompt Protection, or E8 reservation items as current API distribution blockers. They are now classified as accepted bounded evidence or regression/RC watch for this scope.
- `docs/P0_BETA_STATUS.md` now states the immediate next action as real per-user packet plus quota/rate/budget record completion, and clarifies that public routes being wired does not close public/self-serve live invocation proof or Product UX.
- `README.md` current status and Quickstart dates are aligned to the 2026-06-07 local Open-source Alpha/API distribution posture.

Still external/deferred and intentionally not reopened as global blockers:

- `per_user_packet_external_input`: artifact path `.tmp/launch/trusted_user_api_distribution_handoff_summary.<trusted-user-id>.json`; next command `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/prepare_trusted_user_api_distribution_packet.ps1` with real selected-user fields.
- `quota_rate_budget_record_external_input`: artifact path `.tmp/launch/trusted_user_quota_rate_budget_record.<trusted-user-id>.json`; next command `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_trusted_user_quota_rate_budget_record.ps1 -RecordPath .tmp/launch/trusted_user_quota_rate_budget_record.<trusted-user-id>.json -EvidenceManifestPath .tmp/launch/trusted_user_api_distribution_handoff_summary.<trusted-user-id>.json -OutputPath .tmp/launch/trusted_user_quota_rate_budget_record_verification.<trusted-user-id>.json`.
- `public_self_serve_ux_productization`: route-level live HTTP proof has passed via `.tmp/route-live-http-proof/route_level_live_http_proof.json` and `.tmp/launch/voucher_public_route_and_virtual_key_evidence.json`; remaining work is operator-free UX/client flow, quota/rate-budget selection, user-facing errors, and keeping replay/refusal proof current for full public/commercial readiness.
- `payment_order_invoice_external_runtime_deferred`: artifact path `.tmp/credit-wallet/payment_order_invoice_runtime.json`; resume only when Product/Finance/Ops provide provider/callback/capture or approved bounded simulation policy, then run `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_payment_order_invoice_runtime.ps1`.
- `subscription_scheduler_provider_runtime_deferred`: artifact path `.tmp/credit-wallet/subscription_package_lifecycle_runtime.json`; resume only when scheduler/provider/invoice runtime policy exists, then run `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_subscription_package_lifecycle_runtime.ps1`.

## 2026-06-07 CTO-API-DIST-04 Internal Trusted Beta Packet Closed

Main thread continued from the 5-Agent closeout and converted the previous default missing-field state into a concrete CTO-designated internal trusted Beta handoff. This applies only to `internal-trusted-beta-001`; it is not external customer availability, not public self-serve, and not full commercial launch.

Artifacts refreshed:

- `.tmp/launch/trusted_user_distribution_review_packet.internal-beta-001.json`
- `.tmp/launch/trusted_user_api_distribution_handoff_summary.internal-beta-001.json`
- `.tmp/launch/trusted_user_quota_rate_budget_record.internal-beta-001.json`
- `.tmp/launch/trusted_user_quota_rate_budget_record_verification.internal-beta-001.json`

The old internal quota record was no longer acceptable after the stricter E9 verifier because it used stale manifest hashes and did not match current remaining-balance / voucher runtime readbacks. Main thread regenerated the internal handoff summary and rebound the quota/rate/budget record to the current bounded readback ids:

- tenant: `00000000-0000-0000-0000-000000000001`
- project: `14669b96-b32a-4523-be94-5d17f931bcc2`
- wallet: `7a390ba1-8b0b-4479-a42b-a7436ea10386`
- trusted user ref: `internal-trusted-beta-001`
- remaining balance: `4.50000000 USD`
- voucher/redemption ref: `4cda5523-7b71-4ecc-8ea9-dd77a7e1f426`
- credit grant ref: `04bf2af9-5622-49d5-b45d-dfa9f12f1ebf`
- ledger entry ref: `4bdb38d0-f0a3-4aef-9210-3dc0d25a8947`
- rate/budget: `rpm=60`, `tpm=60000`, `budget=4.50000000`

Verification:

- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/prepare_trusted_user_api_distribution_packet.ps1 -ReleaseOwner 'CTO internal beta owner' -SupportContact 'internal-beta-support@fubox.local' -TenantId '00000000-0000-0000-0000-000000000001' -ProjectId '14669b96-b32a-4523-be94-5d17f931bcc2' -WalletId '7a390ba1-8b0b-4479-a42b-a7436ea10386' -VoucherQuota 'voucher=1e975d93-cd54-4e4b-b162-dd1ee2037d7c;redemption=4cda5523-7b71-4ecc-8ea9-dd77a7e1f426;credit=9a3c246c-eb2c-4530-b30c-9a55992d0edf;amount=4.50000000 USD' -RateBudgetGuardrails 'rpm=60;tpm=60000;budget=4.50000000;record=.tmp/launch/trusted_user_quota_rate_budget_record.internal-beta-001.json;trusted_user_id_or_owner_ref=internal-trusted-beta-001' -RollbackOwner 'CTO internal beta rollback owner' -PacketPath '.tmp\launch\trusted_user_distribution_review_packet.internal-beta-001.json' -SummaryPath '.tmp\launch\trusted_user_api_distribution_handoff_summary.internal-beta-001.json'` -> exit 0, `ready_to_send=true`, `overall_status=ready_to_send_trusted_user_beta`.
- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_trusted_user_distribution_review_packet.ps1 -PacketPath .tmp/launch/trusted_user_distribution_review_packet.internal-beta-001.json` -> exit 0, `ready_to_send=true`, `blockers=[]`.
- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1 -SummaryPath .tmp/launch/trusted_user_api_distribution_handoff_summary.internal-beta-001.json` -> exit 0, `overall_status=pass`, `blockers=[]`.
- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_trusted_user_quota_rate_budget_record.ps1 -RecordPath .tmp/launch/trusted_user_quota_rate_budget_record.internal-beta-001.json -EvidenceManifestPath .tmp/launch/trusted_user_api_distribution_handoff_summary.internal-beta-001.json -OutputPath .tmp/launch/trusted_user_quota_rate_budget_record_verification.internal-beta-001.json` -> exit 0, `status=pass`, `ready_for_handoff=true`, `blockers=[]`, `record_matches_remaining_balance_readback=true`, `record_matches_voucher_runtime_currency_and_ref=true`.
- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/scan_secrets.ps1` -> exit 0, hits 0, warnings 0.

CTO decision:

- For `internal-trusted-beta-001`, the actual handoff packet and quota/rate/budget record are now ready for operator review and API distribution.
- Default `.tmp/launch/trusted_user_api_distribution_handoff_summary.json` may still classify missing real user fields and missing quota record as external input. That default dry-run state is retained intentionally for future selected users and must not be treated as a regression of the internal packet.
- Broader external/public users still require their own filled packet plus quota/rate/budget record. Payment/order/invoice runtime, subscription scheduler/provider runtime, and public/self-serve UX remain deferred productization items and are not blockers for this internal trusted Beta packet.

## 2026-06-07 DOCS-BOARD-PM-05 Status Collision Sync

Docs/Product checked the current TODO/Board/Release/P0 wording after the internal packet closeout and Open-source Alpha local pass. Current synchronized posture:

- `internal-trusted-beta-001` packet is closed for the scoped internal trusted Beta handoff: packet review, handoff manifest verifier, quota/rate/budget verifier, and secret scan all passed. This is only a CTO-designated internal trusted Beta target.
- Default/future-user packet state remains external input by design. `.tmp/launch/trusted_user_api_distribution_handoff_summary.json` may still be non-sendable until Release/Ops provides real selected-user fields and a real quota/rate/budget record; this must not be read as a regression of `internal-trusted-beta-001`.
- Open-source Alpha remains local code-first pass from `.tmp/open-source-alpha/open_source_alpha_gate.json` with `status=pass` and `ready_for_open_source_alpha=true`; it is not full New API replacement or public/commercial readiness.
- Superseded by CTO-PRODUCT-07: this scoped reverify state previously left E0-002 as `NeedsFullWrapperRerun`; the later 2026-06-07 full wrapper rerun passed end-to-end and E0-002 moved to `Done`.

## 2026-06-07 External Dependency Bypass Register

Purpose: keep the current API distribution lane unblocked while documenting external dependencies that are required only for future public/self-serve or full commercial scopes. These items must not be reassigned as active implementation slices until the listed missing inputs exist. Current allowed distribution remains scoped trusted-user voucher-backed Beta through operator-issued virtual key plus voucher/redeem-code quota; do not call this full commercial ready.

| blocker_id | Missing external input | Current bypass path | Resume condition / command |
|---|---|---|---|
| `auth_client_oidc_external_dependency` | Product/Auth decision for hosted auth client or OIDC provider, redirect/callback URLs, tenant/user identity mapping, session lifecycle policy, support owner, and security review for public user auth. | Use existing dev/admin or operator-mediated Control Plane path plus bounded virtual-key handoff for trusted users. Treat missing public Auth client as productization gap, not a blocker for `internal-trusted-beta-001` or future manually selected trusted-user packets. | Resume when Product/Ops provides Auth client/provider configuration and ownership policy; then run route-level HTTP proof for login/session/ownership plus `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_route_level_live_http_proof.ps1` or an equivalent QA probe that records `auth/RBAC_or_ownership_scope_verified=true`, `secret_safe=true`, and `paid_gate_changed=false`. |
| `payment_order_invoice_external_runtime_deferred` | Payment gateway/provider, callback/capture runtime, approved bounded simulation policy if no provider exists, invoice/receipt policy, refund/chargeback/reconciliation ownership, finance/support runbook. | Use voucher/redeem-code quota and existing ledger/readback evidence. Payment/order/invoice runtime remains `deferred_runtime_external_dependency` and `blocks_voucher_backed_api_distribution=false`. | Resume only after provider/callback/capture or approved bounded simulation policy exists; run `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_payment_order_invoice_runtime.ps1` and require accepted non-contract `.tmp/credit-wallet/payment_order_invoice_runtime.json` with runtime, idempotency, reconciliation, audit, `secret_safe=true`, and `paid_gate_changed=false`. |
| `subscription_package_runtime_external_dependency` | Scheduler/renewal trigger, provider or invoice/order linkage runtime, trial/proration/dunning policy, cancel/pause/resume policy, reconciliation and support ownership. | Keep plans/packages/subscriptions as schema/contract-ready only. Continue API distribution via one-off voucher-backed quota; do not claim subscription launch. | Resume when scheduler/provider/invoice runtime policy exists; run `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_subscription_package_lifecycle_runtime.ps1` and require accepted `.tmp/credit-wallet/subscription_package_lifecycle_runtime.json` with lifecycle/readback/refusal/audit/reconciliation proof. |
| `public_self_serve_ux_productization_external_dependency` | Product-approved public self-serve flow, screens/client, quota/rate budget selection UX, user-facing errors, final handoff metadata capture, support/rollback ownership, and public copy approval. | Use operator-mediated virtual-key issue plus voucher quota and the per-user packet/manifest/quota verifier chain. Wired public routes and live route proof do not by themselves close Product UX. | Resume when Product/Frontend/Ops supplies the self-serve flow; prove with UI/API E2E plus `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_route_level_live_http_proof.ps1`, then archive UX evidence showing ownership scope, idempotency, audit, ledger/credit readback, refusal no-write, `secret_safe=true`, and `paid_gate_changed=false`. |

## 2026-06-07 CTO-PRODUCT-05 TODO Productization Push

Objective: continue beyond the scoped API distribution gate without redefining `/TODO` completion. Current API distribution remains green for trusted-user voucher-backed Beta, so this round focused on product operability and open-source usability around the distribution path.

5-Agent dispatch and integration:

- Agent-E2-IP-Allowlist: moved E2 IP allowlist toward `InProgressPass`. `examples/config.example.yaml` now documents `trusted_proxy_allowlist: []`; Gateway tests for profile IP allowlist, client IP extraction, trusted proxy allowlist, and CIDR matching passed. Remaining blocker is real LB/proxy CIDR plus live request proof through that network path.
- Agent-E4-Model-Association: added `scripts/verify_control_plane_model_association_dry_run_contract.ps1`. It verifies selected/no-candidate dry-run fixtures, OpenAPI selector and `fallback_allowed`, secret omission in Control Plane source, and Admin UI entry points. Artifact: `.tmp/control-plane/model_association_dry_run_contract_verification.json`, `status=pass`. This is contract evidence, not a live API/UI chain.
- Agent-E0-FullWrapper: completed scoped reverify. `cargo fmt --check`, `cargo check --workspace --all-targets`, Gateway protocol contracts, secret scan, Admin UI tests, and Admin UI bundle gate passed. Superseded by CTO-PRODUCT-07: full wrapper later passed end-to-end and E0-002 is now `Done`.
- Agent-OpenSource-Quickstart: strengthened `README.md` and added `scripts/verify_readme_quickstart_contract.ps1`; Alpha gate now consumes that verifier. Main thread restored `.tmp/open-source-alpha/open_source_alpha_gate.json` by rerunning `scripts/verify_open_source_alpha_gate.ps1 -RunMatrix`, returning `status=pass`, `ready_for_open_source_alpha=true`, `blockers=[]`.
- Agent-E11-Request-Trace-UI plus main-thread review: Request Detail now exposes Cost, operator Support Summary, sanitized Route Trace strategy/fallback/reject, ledger rows, provider attempts, and payload hash metadata. Main thread rejected raw route snapshot fallback for Route Trace; only `summary.*` is displayed for strategy/fallback/reject. UI verification passed: `npm --prefix web/admin-ui test -- --run src/App.test.tsx` -> 74 tests, and `npm --prefix web/admin-ui run build` -> pass.

Current CTO status:

- API distribution gate remains green: `.tmp/launch/final_launch_gate_summary.json` reports `ready_to_distribute_api=true`, `production_distribution_ready=true`, `production_distribution_full_ready=false`, `global_blockers=[]`.
- Open-source Alpha gate artifact has been restored after the accidental dry-run overwrite: `.tmp/open-source-alpha/open_source_alpha_gate.json` is `status=pass` and `ready_for_open_source_alpha=true`.
- E2/E4/E11 moved forward as product operability evidence, but are not globally Done. Their live/external blockers remain explicit.
- Full `/TODO` completion is still not achieved. Superseded by CTO-PRODUCT-07 for E0: full wrapper/full CI end-to-end run is now pass. TODO-14 live Admin/API metadata-only readback with E8/E11/E13 request ids is now pass for API distribution; E4 default price selector browser operation evidence is now pass via `.tmp/control-plane/model_default_price_admin_ui_browser_evidence.json`; remaining high-value next work is production provider-key rotation endpoint/KMS policy, E12 operator-secret handoff, clean-clone public-tag transcript, broader Admin UI parity/trace polish, and deferred public/commercial external dependencies.

### Internal Beta Handoff Hash Refresh After FullDistributionGate

Main thread reran `scripts/test.ps1 -FullDistributionGateOnly` during this round. That refreshed shared launch artifacts and made the existing `internal-trusted-beta-001` quota/rate/budget verification stale on three evidence hashes. This was caught by re-running the target-user quota verifier; it returned blocked with hash mismatches for the quota template, accounting gate, and quota guardrails.

Corrective action completed:

- Regenerated `.tmp/launch/trusted_user_distribution_review_packet.internal-beta-001.json`.
- Regenerated `.tmp/launch/trusted_user_api_distribution_handoff_summary.internal-beta-001.json`.
- Regenerated `.tmp/launch/trusted_user_quota_rate_budget_record.internal-beta-001.json`.
- Regenerated `.tmp/launch/trusted_user_quota_rate_budget_record_verification.internal-beta-001.json`.

Verification after regeneration:

- `verify_trusted_user_distribution_review_packet.ps1 -PacketPath .tmp/launch/trusted_user_distribution_review_packet.internal-beta-001.json` -> pass, `ready_to_send=true`, `blockers=[]`.
- `verify_trusted_user_api_distribution_evidence_manifest.ps1 -SummaryPath .tmp/launch/trusted_user_api_distribution_handoff_summary.internal-beta-001.json` -> pass, `blockers=[]`.
- `verify_trusted_user_quota_rate_budget_record.ps1 -RecordPath .tmp/launch/trusted_user_quota_rate_budget_record.internal-beta-001.json -EvidenceManifestPath .tmp/launch/trusted_user_api_distribution_handoff_summary.internal-beta-001.json -OutputPath .tmp/launch/trusted_user_quota_rate_budget_record_verification.internal-beta-001.json` -> pass, `ready_for_handoff=true`, `blockers=[]`, all checked hashes match.
- `scripts/scan_secrets.ps1` -> pass, hits 0, warnings 0.

Operational rule: any future `FullDistributionGateOnly` or release artifact refresh must be followed by regenerating and re-verifying the target-user handoff summary and quota/rate/budget record before actual key handoff.

## 2026-06-07 CTO-PRODUCT-06 Agent Integration Round

Main thread continued the productization push while keeping the current API distribution gate unchanged: scoped trusted-user voucher-backed Beta remains ready, and full `/TODO` is still not complete.

Integrated agent outputs:

- Agent-E4 live chain added `scripts/verify_control_plane_model_association_dry_run_live.ps1`. Main thread reran `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_model_association_dry_run_live.ps1 -NoWrite` and it passed against the running compose stack: `postgres`, `control-plane`, and `admin-ui` were available; dev seed model-association data was present; `admin@example.com` / `local-password` login returned a usable session; real `POST /admin/model-associations/dry-run` selected a candidate; `fallback_allowed=true`; the response/artifact remained secret-safe and did not record the admin session token. Artifact: `.tmp/control-plane/model_association_dry_run_live_verification.json`.
- Agent-E12 added `scripts/importers/verify-import-provider-key-secret-path-artifacts.ps1` plus `docs/todo/slices/E12-006.md`. Main thread reran the verifier and it passed, writing `.tmp/importers/provider_key_secret_path/summary.json`. New API / One API source dry-run, internal mapping, and apply-plan artifacts do not carry raw provider key locators; provider-key material remains sidecar handoff metadata; `planned_provider_key_writes=0`; `sql_provider_key_operations=0`; operator path is `POST /admin/provider-keys`.
- Agent-E3 added `scripts/verify_provider_key_audit_readback.ps1` and `docs/E3_PROVIDER_KEY_AUDIT_READBACK_RUNBOOK.md`. Main thread reran `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_provider_key_audit_readback.ps1 -ExecuteMutation -RestoreStatus enabled`; it passed. Artifact `.tmp/control-plane/provider_key_audit_readback.json` reports `status=pass` and `secret_safe=true`, proving provider key GET readback omits credential material, bounded status mutation is safe, `provider_key.update` audit readback is available, and restore returns the key to `enabled`. This closes the view/audit readback slice but does not claim production rotation: `runtime_rotate_endpoint_implemented=false` and production rotation still requires KMS/master-key custody policy.
- Agent-E0 ran the default full wrapper `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1`. It initially failed at `cargo test --workspace --all-targets --all-features` exit 101, failing `admin::tests::ledger_adjustment_runtime_writer_cutover_blocks_local_execute_commit_until_runtime_branch_ready` at `apps/control-plane/src/admin.rs:20211`. Evidence: `.tmp/launch/full_wrapper_rerun_20260607_141608.json`, `.log`, and `.raw_exit.txt`. Superseded by CTO-PRODUCT-07: the test was fixed and the full wrapper later passed end-to-end.
- Main thread updated `scripts/verify_request_trace_usage_explainability.ps1` LiveGapReadiness to attempt a safe dev admin login handoff when no admin session token is provided. That intermediate run wrote `.tmp/launch/request_trace_usage_live_gap_readiness.json` and was blocked only by missing E11 current request ids. This is historical: the later live Admin/API metadata-only readback passed in `.tmp/launch/request_trace_usage_live_admin_api_readback.json`, so TODO-14 is no longer an API distribution blocker.

Board/status updates:

- `project/PROJECT_BOARD.csv`: E3-002/E13-002 now record provider-key audit/readback bounded mutation evidence; E4-005 records live Control Plane dry-run evidence; E11-005 records that the admin session handoff is no longer the active TODO-14 blocker.
- `docs/P0_BETA_STATUS.md`: TODO-14 and E4 status copy now matches the new artifacts.
- `project/ACCEPTANCE_CHECKLIST.md`: TODO-14 now records live Admin/API metadata-only readback pass and keeps only UI/browser polish plus deeper observability hardening as follow-up.

Remaining active productization work:

1. E3 provider-key multi-key routing/rotation strategy and production KMS/master-key custody runbook.
2. Release-state guard to prevent artifact refresh from invalidating target-user/internal-beta or Alpha pass artifacts.
3. TODO-14 is closed for current API distribution by live Admin/API metadata-only readback; keep only UI/browser polish and Production RC observability hardening.
4. E0 full wrapper is closed by CTO-PRODUCT-07; keep it as regression watch only.
5. Broader Admin UI parity/trace polish after E4 default price selector browser operation evidence pass.

## 2026-06-07 CTO-PRODUCT-07 Freshness Guard + E0 Closure

Main thread integrated the release-state guard, corrected its classification, refreshed the internal target-user handoff after the gate, and closed the E0 full wrapper blocker.

Release guard outcome:

- `scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1` now rejects stale manifest entries by re-reading current artifact bytes/SHA256 and refusing entries refreshed after the target handoff summary timestamp.
- `scripts/test.ps1 -FullDistributionGateOnly` now checks target-user handoff summaries under `.tmp/launch/trusted_user_api_distribution_handoff_summary.*.json` while excluding synthetic/selftest summaries.
- Main-thread classification fix: stale target-user handoff summaries are recorded under `per_user_external_inputs` as `target_user_handoff_manifest_stale_after_gate_refresh`, with `blocks_actual_key_handoff_until_refreshed=true` and `blocks_global_voucher_backed_beta_distribution_readiness=false`. This avoids making the platform-level API distribution gate impossible to keep green after it refreshes shared launch artifacts, while still preventing actual key handoff with stale target-user evidence.

Verification:

- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1 -FullDistributionGateOnly` -> exit 0.
- `.tmp/launch/final_launch_gate_summary.json` -> `ready_to_distribute_api=true`, `production_distribution_ready=true`, `global_blockers=[]`; it still records the target-specific stale handoff warning caused by the gate refresh.
- After the gate, main thread regenerated `internal-trusted-beta-001` target artifacts with `scripts/prepare_trusted_user_api_distribution_packet.ps1` and reran:
  - `verify_trusted_user_distribution_review_packet.ps1` -> pass, `ready_to_send=true`.
  - `verify_trusted_user_api_distribution_evidence_manifest.ps1` -> pass, `ready_to_send=true`.
  - `verify_trusted_user_quota_rate_budget_record.ps1` -> pass, `ready_for_handoff=true`.
  - `scripts/scan_secrets.ps1` -> pass, hits 0, warnings 0.
- Post-gate target refresh summary written: `.tmp/launch/post_gate_target_handoff_refresh_summary.internal-beta-001.json`, with `actual_key_handoff_blocked_by_stale_manifest=false`.

E0 closure:

- Fixed `admin::tests::ledger_adjustment_runtime_writer_cutover_blocks_local_execute_commit_until_runtime_branch_ready` by adding a dispatch-decision helper that can simulate `canonical_final_gate_passed=true` for the test branch while keeping the production dispatch function conservative with `canonical_final_gate_passed=false`.
- `cargo test -p ai-control-plane ledger_adjustment_runtime_writer_cutover_blocks_local_execute_commit_until_runtime_branch_ready -- --nocapture` -> pass.
- `cargo fmt --check` -> pass.
- `cargo test --workspace --all-targets --all-features` -> pass.
- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1` -> exit 0 end-to-end.
- Full wrapper pass artifact: `.tmp/launch/full_wrapper_rerun_20260607_143200_pass.json`.

Status changes:

- `project/PROJECT_BOARD.csv`: E0-002 moved to `Done`.
- `project/ACCEPTANCE_CHECKLIST.md`: Full local gate marked checked.
- `docs/P0_BETA_STATUS.md`, `project/RELEASE_CHECKLIST.md`, and `TODO/OPEN_SOURCE_ALPHA_PRIORITY_2026-06-06.md` updated from old failed-wrapper wording to current local wrapper pass.

Current CTO posture:

- API distribution is green for trusted-user voucher-backed Beta, and the internal trusted Beta handoff is refreshed after the latest gate.
- Full local wrapper is green.
- Full `/TODO` is still not complete: TODO-14 live Admin/API readback is now pass for API distribution, and E4 default price selector browser operation evidence is pass; E3 production rotation still needs a real rotate endpoint plus KMS/master-key custody policy; E12 Control Plane provider-key create audit/readback waits on operator secret; public/self-serve UX, payment/order/invoice runtime, subscription runtime, clean-clone/hosted CI transcript for public tag, broader Admin UI parity/trace polish, staging/Production RC remain later lanes.

## 2026-06-07 CTO-PRODUCT-08 / Remaining subagent integration

- Agent-TODO14 / Mencius: request-id extraction landed earlier; main thread completed the live Admin/API metadata-only readback. Commands: `scripts/verify_request_trace_usage_explainability.ps1 -SelfTest` exit 0 and `scripts/verify_request_trace_usage_explainability.ps1 -LiveApiReadback -OutputPath .tmp/launch/request_trace_usage_live_admin_api_readback.json` exit 0. Artifact is pass with 11 request ids, 5 traces, 1 wallet, no payload preview, no blockers.
- Agent-E4-UI / Volta: `scripts/verify_control_plane_model_association_dry_run_live.ps1` passed and now covers default price config API live restore plus secret-safe dry-run response. Main-thread browser evidence `.tmp/control-plane/model_default_price_admin_ui_browser_evidence.json` is pass after Admin UI rebuild from current source; remaining E4 work is broader parity/trace polish, not API distribution.
- Agent-E3-Rotation / Peirce: `scripts/verify_provider_key_production_rotation_readiness.ps1` and selftest pass, but correctly emit `status=production_ready_blocked`, `runtime_rotate_endpoint_implemented=false`, and `final_rotation_closure_allowed=false`. Bounded substitute/runbook is accepted for current API distribution; production rotation stays open until rotate endpoint and KMS/master-key custody exist.
- Agent-E12-Parity / Zeno: `scripts/importers/verify-import-sample-apply-rollback-parity.ps1` pass. New API and One API samples both have planned_writes=17, planned_skips=0, rollback_snapshot_entries=17; provider keys remain sidecar-only with no raw provider key writes. Control Plane provider-key create audit/readback is deferred until operator secret exists.
- Agent-OS-Release / Hume: `scripts/verify_open_source_alpha_clean_clone_readiness.ps1` and Open-source Alpha gate integration are in place. Missing real clean-clone/CI transcript is a public tag/release blocker only; it does not affect local Alpha/API distribution pass.
