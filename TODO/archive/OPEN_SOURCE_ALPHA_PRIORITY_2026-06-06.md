# Open-source New API Replacement Alpha Priority Plan

同步日期：2026-06-07
统筹口径：公司资金约束下切换为单人代码先行模式；先保证可开源 clone-and-run、可分发 API、可用本地证据复现。不要把 trusted-user voucher-backed Beta 或本地 Alpha gate 误写成 full public/self-serve commercial readiness。

2026-06-07 单人实测更新：
- 当前本机 Compose 栈已启动并自测：Gateway `http://127.0.0.1:8080`、Control Plane `http://127.0.0.1:8081`、Admin UI `http://127.0.0.1:5173`、Postgres host port `15432`、Redis host port `16380`。
- `scripts/verify_open_source_alpha_gate.ps1 -RunMatrix` 已通过，`.tmp/open-source-alpha/open_source_alpha_gate.json` 为 `status=pass`、`ready_for_open_source_alpha=true`、`blockers=[]`。
- `scripts/verify_route_level_live_http_proof.ps1` 已通过，新建 virtual key 可真实调用 Gateway，voucher issue/redeem 和 DB readback artifact secret-safe。
- 已修复两个会拖慢进度的真实问题：expired `provider_keys.status='cooldown'` 到期后不能重新进入候选池导致新 key 404；importer live runner 在 rollback journal 复用时可能空 operation 假 `rolled_back`。
- 当前仍不等于 full New API replacement：公开 release 前还需要 clean clone/CI 复跑、Admin UI full parity、真实 NewAPI/OneAPI 样本迁移验收、payment/subscription 外部 runtime。

## CTO 判定

| Scope | 当前判定 | 说明 |
|---|---|---|
| Trusted-user voucher-backed API Beta | Enough for controlled handoff after real per-user packet fields are filled | 现有 gate 显示 `ready_to_distribute_api=true`，但只覆盖可信用户、operator-mediated virtual key、voucher quota、secret-safe handoff。 |
| Open-source Alpha / Preview | Local P0 gate pass for code-first preview | 2026-06-07 当前 `.tmp/open-source-alpha/open_source_alpha_gate.json` 为 `status=pass`、`run_matrix=true`、`ready_for_open_source_alpha=true`；route proof、Gateway matrix、Control Plane parity、provider-key runtime、importer live、TODO-14 metadata-only readback、secret scan 均已在本机通过。clean-clone readiness guard 已接入并因缺真实 transcript 记录 `status=warn`；公开打 tag 前仍必须跑 clean clone/CI rerun，并保持 caveats。 |
| Full New API replacement | Not enough | 还缺 public/self-serve UX、migration apply/rollback productization、payment/subscription runtime、clean-clone/hosted CI evidence、production deployment and hardening。 |

Packet/CI clarification: `internal-trusted-beta-001` now has a closed internal trusted Beta packet, but that packet is not Alpha evidence and not public launch evidence. Default/future-user packet generation remains external input until Release/Ops supplies real target-user fields and quota/rate/budget records. Rust `cargo fmt --check`, `cargo check --workspace --all-targets`, `cargo test --workspace --all-targets --all-features`, and the full local wrapper `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1` have passed locally on 2026-06-07. E0-002 is Done for local wrapper evidence. Evidence: `.tmp/launch/full_wrapper_rerun_20260607_143200_pass.json`. Public tag/release still needs clean-clone/hosted CI evidence and release review.

## Priority Queue

### P0：Open-source Alpha launch gate

目标：外部开发者 clone 仓库后，不依赖内部上下文，也能启动本地栈、创建或使用 virtual key、调用 OpenAI-compatible API、看到日志/余额/限流证据。

1. **OS-A0-01 Clone-and-run Compose**
   - Owner：QA/Ops
   - Current status：EvidencePass for the current code-first first-run path. `scripts/alpha_smoke.ps1 -StartCompose` now represents the accepted clone-and-run evidence path and writes a secret-safe artifact; local Docker daemon/build/host-port failures remain environment blockers, not product blockers.
   - DoD：`scripts/compose_up.ps1` 启动 Postgres、Redis、mock-provider、Gateway、Control Plane、Admin UI；`scripts/verify_compose_smoke.ps1` 和 `scripts/verify_sdk_smoke.ps1` 在同一环境通过。
   - Evidence：`.tmp/open-source-alpha/alpha_smoke.json` 或等价 release artifact。
   - Current command：`scripts/alpha_smoke.ps1 -StartCompose`；它会使用 bounded retry，失败也必须写出 secret-safe artifact。
   - Host-port conflict rerun：如果本机 `127.0.0.1:5432` 或 `127.0.0.1:6379` 被占用，使用 PowerShell 环境变量覆盖 host 端口后复跑，不改 container-internal service names/ports：`$env:POSTGRES_HOST_PORT="55432"; $env:REDIS_HOST_PORT="56379"; pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\alpha_smoke.ps1 -StartCompose -ComposeTimeoutSeconds 600`。
   - Blocker policy：Docker daemon missing、stale Compose container referencing a missing image、或本机 Docker build 超时是 local environment blocker；记录后清理/rebuild 或换可用机器/CI 复跑，不改成产品 blocker。

2. **OS-A0-02 Live API distribution smoke**
   - Owner：E8 + E11 + QA
   - Current status：EvidencePass in the current local Compose environment. 2026-06-07 `scripts/verify_route_level_live_http_proof.ps1` passed after rebuilding Gateway with expired-cooldown provider-key recovery; the Gateway matrix passes serially through `verify_open_source_alpha_gate.ps1 -RunMatrix`.
   - DoD：通过真实 HTTP 路径证明登录/Admin 权限或 dev admin、virtual key issue/read/disable、voucher issue/redeem 或 operator quota、`GET /v1/models`、`POST /v1/chat/completions`、余额不足 402/no-provider-call、request id/audit/readback。
   - Evidence：`.tmp/open-source-alpha/api_distribution_live_smoke.json`，必须 `route_invoked=true`、`runtime_implemented=true`、`secret_safe=true`、`simulation=false`。
   - 注意：不能用 fixture/selftest 代替 live smoke。
   - Minimum Gateway matrix：`verify_gateway_routing_smoke.ps1`、`verify_gateway_profile_smoke.ps1`、`verify_gateway_retry_fallback_smoke.ps1 -StrictGatewayFallback`、`verify_gateway_rate_limit_reservation_smoke.ps1`、`verify_gateway_paid_hot_path_smoke.ps1`、`verify_sdk_smoke.ps1 -SkipInstall` must pass serially against the same Compose environment.
   - Minimum Control Plane route proof：2026-06-07 `scripts/verify_route_level_live_http_proof.ps1` passed and proved admin login, virtual-key create/get/audit, Gateway call with the created key, voucher issue/redeem route invocation, DB readbacks, no raw key/code in artifact, `secret_safe=true`, and `paid_gate_changed=false`. Dry-run artifact `.tmp/route-live-http-proof/route_level_live_http_proof.dry_run.json` remains non-live evidence only.

3. **OS-A0-03 README / Quickstart rewrite**
   - Owner：Docs/Product
   - Current status：InProgressPass. README has an open-source Alpha Quickstart surface, caveats, route proof/matrix commands, Alpha gate command, and clean-clone readiness verifier command. The clean-clone guard checks README, `.dockerignore`, CI workflow, required commands, known limitations, and trusted-beta/full-commercial caveats; missing real clean-clone/CI transcript blocks public tag/release only.
   - DoD：README 首屏从“开发启动包”改成开源项目入口，包含 install prerequisites、compose up、health check、create/use key、call `/v1/models` and chat、Admin UI URL、known limitations、trusted-beta vs full commercial caveats。
   - Evidence：README + quickstart command transcript artifact。

4. **OS-A0-04 Minimal Admin operation chain**
   - Owner：Frontend + E11
   - Current status：InProgressPass. The live route proof covers admin login, virtual-key create/get/audit/binding, Gateway call using the created secret, voucher issue/redeem route invocation, ledger/readback, and secret-safe artifact output. Control Plane API parity smoke now covers provider/channel/provider-key/canonical-model/profile/model-association create/get/list/patch/delete plus model-association dry-run and `fallback_allowed=false` route selection; Admin UI parity and trace UI remain follow-up.
   - DoD：Admin UI 或 documented Control Plane API 能完成 provider/channel/model/profile/key/credit or voucher/basic trace 的最小闭环；如果 UI 未完成，README 必须给 curl/PowerShell fallback。
   - Evidence：Admin UI tests or API smoke artifact；不得只写截图。

5. **OS-A0-05 Open-source Alpha gate script**
   - Owner：QA/Ops
   - Current status：EvidencePass. 2026-06-07 `scripts/verify_open_source_alpha_gate.ps1 -RunMatrix` passes in the current Compose environment and writes `.tmp/open-source-alpha/open_source_alpha_gate.json`; the matrix includes `verify_control_plane_crud_smoke.ps1 -IncludeFullCrud -StrictFullCrud` and accepts `.tmp/control-plane/control_plane_management_parity_smoke.json`、rate-limit live artifact、paid hot-path artifact。
   - DoD：新增或复用一个命令聚合 open-source Alpha 必需检查：compose smoke、SDK smoke、live distribution smoke、secret scan、README contract check。
   - Current command：`scripts/alpha_smoke.ps1 -StartCompose` runs compose startup, bounded-retry compose smoke, SDK smoke, secret scan, and writes `.tmp/open-source-alpha/alpha_smoke.json`。
   - Aggregator command：`pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_open_source_alpha_gate.ps1 -DryRun` reads `.tmp/open-source-alpha/alpha_smoke_current.json`, `.tmp/route-live-http-proof/route_level_live_http_proof.json`, matrix script/artifact availability, and writes secret-safe `.tmp/open-source-alpha/open_source_alpha_gate.json` with `status=pass|warn|fail` plus `blockers` for every non-pass item.
   - Matrix command：`pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_open_source_alpha_gate.ps1 -RunMatrix` runs the required Control Plane management parity and Gateway matrix serially and records command exit status without raw stdout/stderr.
   - Current limitation：`alpha_smoke.ps1` is the first-run smoke, not the full Alpha release gate. The aggregator may report Alpha pass only when the route proof and Gateway matrix are current/pass; trusted-user voucher-backed Beta artifacts, including `internal-trusted-beta-001`, are not Alpha evidence.

### P1：New API / One API replacement parity

1. **OS-A1-01 Import apply and rollback**
   - Owner：Importer + E11/E9
   - Current status：Expanded live slice passed. 2026-06-07 fixed rollback journal replay so reused `snapshot_entry_id` rows are rebound to the current transaction and operation readback cannot be empty. `scripts/importers/verify-import-apply-live-runtime.ps1` now passes and writes `.tmp/importers/import_apply_live_runtime_verification.json` with `status=pass`, `live_database_connection=true`, `database_writes=true`, `rollback_verified=true`, `secret_safe=true`, and `raw_sql_omitted=true`; it covers `canonical_model`、unbound `provider/channel`、bound `channel_mapping_entry`、bound explicit-channel `model_association`、and `conflict_blocked_no_write_refusal` no-write refusal.
   - DoD：New API / One API config dry-run 之后可 apply 到 DB，支持 rollback、conflict/refusal/no-write、audit/readback、secret-safe provider key handling。
   - Remaining：provider key secret-management path、Admin/API audit/readback integration、真实 New API/One API sample end-to-end migration、复杂 channel mapping policy。

2. **OS-A1-02 Model/channel/key management parity**
   - Owner：E3/E4/E13 + Frontend
   - Current status：First live API slice passed. `scripts/verify_control_plane_crud_smoke.ps1 -IncludeFullCrud -StrictFullCrud` creates/gets/lists/patches/deletes provider、channel、provider key、canonical model、api-key profile、model association through live Control Plane HTTP, verifies provider-key secret redaction, and proves dry-run selection with `fallback_allowed=false` and no upstream call. The artifact `.tmp/control-plane/control_plane_management_parity_smoke.json` is now required by the Open-source Alpha gate.
   - DoD：provider、channel、provider key、canonical model、association、profile、fallback policy 的 CRUD/dry-run/live smoke 完成，Admin UI 或 API docs 可操作。
   - Remaining：Admin UI full parity、operator docs polish、multi-candidate/fallback policy UI、真实用户排障 trace 联动。

3. **OS-A1-03 Request trace and cost explainability**
   - Current status：API distribution pass. `.tmp/launch/request_trace_usage_live_admin_api_readback.json` has `overall_status=pass`, 11 E8/E11/E13 request ids, 5 traces, 1 remaining-balance wallet surface, and metadata-only secret-safe readback over request detail、trace summary、ledger entries、audit logs、remaining balance. It does not call `/payload`.
   - Remaining：Admin UI/browser polish、richer operator docs、Production RC observability hardening。
   - Owner：OBS/E10/E14
   - DoD：每个请求能读回 route decision、provider attempts、fallback/reject reason、usage/cost/ledger refs、budget/rate-limit status；Admin UI 或 API 可排障。

4. **OS-A1-04 Budget/rate limit hardening**
   - Owner：E8/E9
   - DoD：virtual key 日/月/总预算、RPM/TPM/concurrency、provider key cooldown、manual disable/recovery probe 全部有 runtime/readback evidence。

### P2：Commercial productization

External-dependency bypass policy for P2: the rows below document missing outside inputs and the allowed current bypass. They do not block the current local Open-source Alpha gate or trusted-user voucher-backed API Beta. They also do not make the product full public/self-serve or full commercial ready.

| blocker_id | 缺失外部输入 | 当前可绕过路径 | 恢复条件/命令 |
|---|---|---|---|
| `auth_client_oidc_external_dependency` | Hosted Auth client or OIDC provider choice, redirect/callback URLs, tenant/user identity mapping, public session lifecycle/security policy, support owner. | For Alpha/Beta, use local dev admin or operator-mediated trusted-user handoff with bounded virtual keys; do not require public auth client before API distribution. | Resume after Auth provider/client policy exists; run `scripts/verify_route_level_live_http_proof.ps1` or equivalent login/session/ownership probe and require auth/RBAC or ownership scope, secret-safe artifact, and `paid_gate_changed=false`. |
| `payment_order_invoice_external_runtime_deferred` | Payment gateway/provider, callback/capture runtime, invoice/receipt/refund/chargeback/reconciliation policy, or an approved bounded simulation policy. | Keep voucher/redeem-code quota as the paid/credit bypass for trusted users; do not spend solo capacity fabricating payment runtime evidence. | Resume only with provider/callback/capture or approved bounded simulation; run `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_payment_order_invoice_runtime.ps1`. |
| `subscription_package_runtime_external_dependency` | Scheduler/renewal trigger, provider/invoice/order linkage runtime, trial/proration/dunning policy, cancel/pause/resume behavior, reconciliation ownership. | Keep subscription/package as schema/contract-ready P2 backlog; distribute API through one-off voucher quota. | Resume only after scheduler/provider/invoice runtime policy exists; run `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_subscription_package_lifecycle_runtime.ps1`. |
| `public_self_serve_ux_productization_external_dependency` | Product-approved public self-serve screens/client flow, quota/rate-budget selection UX, user-facing errors, final handoff metadata capture, support/rollback owner and copy approval. | Use operator-mediated virtual key plus voucher quota; route proof may support the backend path but does not equal public self-serve UX. | Resume after Product/Frontend/Ops define the flow; run live UI/API E2E plus `scripts/verify_route_level_live_http_proof.ps1` and archive secret-safe ownership/idempotency/audit/readback/refusal evidence. |

1. **OS-A2-01 Public voucher route proof and self-serve UX**
   - Owner：E11 + Frontend + QA
   - Current evidence：2026-06-07 `.tmp/route-live-http-proof/route_level_live_http_proof.json` is `overall_status=pass` and proves live Control Plane invocation for `POST /admin/voucher-issuances` plus `POST /billing/vouchers/redeem`, voucher issue/redeem/attempt/credit-grant/ledger/audit readback, redaction/no raw voucher code in artifact, `secret_safe=true`, and `paid_gate_changed=false`. `.tmp/launch/voucher_public_route_and_virtual_key_evidence.json` now consumes that proof and reports `voucher_route_evidence.status=live_route_verified`, `route_invoked=true`, `route_verified=true`, `public_routes_wired=true`, `blockers=[]`.
   - Remaining P2 gap：public self-serve UX/productization, including operator-free screens/client flow, quota/rate budget selection, user-facing errors, final handoff metadata capture, and keeping live replay/refusal proof current for full public/commercial readiness.

2. **OS-A2-02 Payment/order/invoice runtime**
   - Owner：E9 + Product/Finance/Ops
   - DoD：provider/callback/capture or approved bounded internal simulation policy, invoice/receipt/refund/chargeback/reconciliation readback, idempotency/audit proof。
   - Blocker policy：缺支付网关时保持 `deferred_runtime_external_dependency`，不让 Agent 空转。

3. **OS-A2-03 Subscription lifecycle runtime**
   - Owner：E9 + Worker + Product/Ops
   - DoD：scheduler/renewal trigger、trial/proration/dunning、invoice/order linkage、credit/ledger effect、cancel/pause/resume、reconciliation readback。
   - Blocker policy：缺 scheduler/provider/invoice runtime 时保持 deferred。

### P3：Production RC / hardening

1. Full CI/full local wrapper green, including Rust workspace, Admin UI npm ci/test/build/bundle, PowerShell gates, secret scan, supply-chain/SBOM。
2. Helm/staging deployment, backup/restore rehearsal, load/chaos/security review。
3. Production tokenizer/read-model backend and ClickHouse non-simulated production smoke。
4. Evidence schema consolidation and large-file refactor to reduce future Agent conflict risk。

## Solo Developer Dispatch / No-Cash Mode

| Lane | Immediate task | Write scope | Acceptance |
|---|---|---|---|
| P0 Stabilize Alpha | Keep Compose/API distribution/gateway matrix green; fix only regressions that block local first-run or API calls | `scripts/**`, `apps/gateway/**`, `apps/control-plane/**`, smoke fixtures | `verify_open_source_alpha_gate.ps1 -RunMatrix` stays pass; route proof remains secret-safe。 |
| P1 Replacement Parity | Implement New API/One API import apply/rollback, provider/channel/model/profile/key operation parity, trace/cost explainability | importers, control-plane/admin-ui/gateway/docs | A user can migrate config and operate core model/channel/key routing without reading internal seed history。 |
| P2 Productization Deferred | Keep payment/order/invoice and subscription lifecycle as deferred external-runtime work until provider/scheduler inputs exist | billing ledger/worker/docs | No fake payment/subscription pass; resume only with real provider/scheduler policy。 |
| P3 Release Hardening | Run full wrapper/CI, clean-clone rerun, staging/security/load only when P0/P1 code movement settles | `scripts/test.ps1`, CI, deploy/docs | Public release tag has reproducible evidence beyond the local Alpha artifact。 |

## 2026-06-07 Solo Next Queue

1. Keep P0 green: rerun route proof and Alpha gate after any Gateway/Control Plane/importer change.
2. Clean-clone/CI rerun: prove the current local pass is reproducible outside this dirty workspace.
3. P1 importer productization: add real NewAPI/OneAPI sample end-to-end migration evidence and operator provider-key handoff docs.
4. P1 Admin/API parity: close Admin UI gaps or document Control Plane API fallback for every core operation.
5. P2 remains deferred until payment gateway/subscription scheduler/provider policy exists; do not spend solo capacity fabricating commercial runtime evidence.

## Stop Conditions

- Do not claim more than code-first Open-source Alpha until P0 artifacts pass on a clean clone/CI or clean local environment.
- Do not claim full New API replacement until P1 parity and P2 commercial/self-serve items have runtime evidence.
- Do not use `internal-trusted-beta-001` as evidence of public launch; it is only an internal trusted Beta target.
