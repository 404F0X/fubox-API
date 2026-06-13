# AI Gateway Agent Execution Pack（可直接派发给 Agent）

生成日期：2026-06-05  
目标：让 Agent 像执行机器一样按明确输入、写入范围、命令、验收标准推进。

> 2026-06-07 单人模式更新：公司资金约束下不再调度 5 个子 Agent，当前由单人 CTO/Codex 队列维护。P0 已转为 code-first Open-source Alpha/API distribution 稳定：`scripts/verify_open_source_alpha_gate.ps1 -RunMatrix`、`scripts/verify_route_level_live_http_proof.ps1`、`scripts/verify_provider_key_runtime_smoke.ps1`、`scripts/importers/verify-import-apply-live-runtime.ps1`、`scripts/scan_secrets.ps1` 当前本机通过。下面 Dispatch 仍保留为历史/任务模板；新任务按 `TODO/OPEN_SOURCE_ALPHA_PRIORITY_2026-06-06.md` 的 Solo Next Queue 执行。
>
> 2026-06-06 当前主线：让产品可以分发 API。优先交付 trusted-user voucher-backed API distribution：operator-issued virtual key、voucher/redeem-code quota、quota/rate/budget record、handoff manifest、secret scan、Release/Ops target-user packet。下面早期 Dispatch 1-6 保留为历史/回归上下文；当前新派发必须优先使用 `Dispatch API-*`，不得按旧 `paid blocked`、`usage-only decision`、production tokenizer、ClickHouse production smoke、TODO-32J/TODO-32K external runtime 文案重开全局 blocker。
>
> `.tmp/launch/final_launch_gate_summary.json` 中的 `ready_to_distribute_api=true` 只表示 scoped trusted-user voucher-backed API Beta global readiness；缺 release owner、support contact、tenant/project/user/wallet 或 `trusted_user_id_or_owner_ref`、voucher quota、rate/budget guardrails、rollback owner、`real_user_values_present=true` 等 per-user 字段只阻止实际 key handoff，不阻止 global readiness。Voucher issue/redeem Control Plane routes 已接线并受 `BillingAdjust` 保护；live route invocation proof / public self-serve UX、payment/order/invoice、subscription runtime 仍是 productization/deferred gaps，不得写成 full public/commercial readiness。
>
> 开源 New API 替代品 Alpha 的当前优先级以 `TODO/OPEN_SOURCE_ALPHA_PRIORITY_2026-06-06.md` 为准。2026-06-07 本机 gate 已 pass，但这只代表 local code-first Alpha，可用于继续打磨；公开 release 仍需要 clean clone/CI 复验、Admin UI parity、真实 NewAPI/OneAPI 样本迁移、payment/subscription 外部 runtime。Trusted-user Beta 之后的第一优先级不是 payment/subscription，而是 clone-and-run Compose、live API distribution smoke、README/Quickstart、最小 Admin/API 操作链和 open-source Alpha gate。

---

## 全局 Agent 规则

每个 Agent 开始前必须执行：

```powershell
git rev-parse --short HEAD
git status --short
git diff --check
```

每个 Agent 结束必须返回：

```json
{
  "agent": "Agent-Name",
  "task_id": "TODO-xx",
  "status": "pass|blocked|fail",
  "changed_files": [],
  "commands_run": [],
  "artifacts_written": [],
  "acceptance_results": {},
  "blockers": [],
  "next_task": ""
}
```

禁止事项：

- 禁止输出 secret。
- 禁止伪造 live evidence。
- 禁止把 simulation/fixture 标 final。
- 禁止跨 lane 大改。
- 禁止把 UI 变化当作后端功能完成。
- 禁止默认联网、下载包、连接生产服务；必须 opt-in。

权威源规则：

- `TODO/` 是 TODO 权威入口。
- `docs/P0_BETA_STATUS.md` 是当前状态摘要。
- `docs/TODO.md` 不得重新成为权威源；如需要更新，只能写成指向 `TODO/` 和 `docs/P0_BETA_STATUS.md` 的索引。
- 旧 paid/global blocker 文案若与 2026-06-06 voucher-backed API distribution 口径冲突，以本文件顶部和 `TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md` 后续 DOC-LAUNCH 记录为准。

---

# Dispatch API-0：Current API Distribution Coordinator

```text
你是当前 API 分发主线 Agent。你的任务不是重开 paid/full-production blocker，而是让 selected trusted user 可以拿到可用 API handoff packet。

当前产品目标：
1. trusted-user voucher-backed Beta API distribution。
2. operator-issued virtual key + voucher/redeem-code quota。
3. quota/rate/budget guardrails verified。
4. handoff summary + evidence manifest + secret scan pass。
5. 对目标用户实际发放前，per-user packet 全字段齐全。

blocked/external-input 规则：
- 缺 release owner/support contact/tenant/project/wallet/voucher quota/rate budget/rollback owner 是 per-user external input，默认 dry-run exit 2 合法，不是 global launch blocker。
- 缺 payment provider/callback/capture 或 subscription scheduler/provider/invoice runtime 是 deferred_runtime_external_dependency，不得空转实现。
- artifact regression、hash mismatch、secret scan fail、Gateway no-provider-call proof 丢失、真实 quota record verifier exit 2 是可执行 blocker，必须派 owner 修。

最终交付必须返回 changed_files、commands_run、artifacts_written、acceptance_results、blockers、next_task。
```

---

# Dispatch API-1：E11 Operator Voucher / Virtual-Key Handoff

```text
你是 Agent-E11。当前任务是支持 operator-mediated API 分发，不是追 full public self-serve commercial route。

目标：
1. Admin/operator issuance path behind BillingAdjust。
2. Voucher/code material只存 hash/redacted refs。
3. idempotency、audit、ledger/credit/readback、refusal-no-write 可验证。
4. 若 public voucher route 仍 partial，标 productization gap，不阻断 trusted-user operator path。

允许写入：
- apps/control-plane/src/admin.rs
- examples/openapi_admin_skeleton.yaml
- db/migrations/0012_recharge_voucher_boundary.sql only if route boundary needs schema alignment
- scripts/verify_voucher_public_route_and_virtual_key_evidence.ps1
- docs/todo/slices/E11-007.md

DoD：
- route/auth/RBAC proof。
- audit/readback/refusal-no-write proof。
- artifact secret_safe=true、paid_gate_changed=false。
- no raw voucher code, full virtual key, Authorization/Cookie, DB URL, provider key。
```

---

# Dispatch API-2：E9 Quota / Accounting Guardrails

```text
你是 Agent-E9。当前任务是让 Release/Ops 的目标用户 quota/rate/budget record 可验收。

目标：
1. `scripts/verify_trusted_user_quota_rate_budget_record.ps1` 对真实 record exit 0。
2. fixed-decimal money、uppercase currency、wallet/readback、voucher/credit/ledger refs、RPM/TPM/budget/expiry/rollback/audit 全部有界。
3. evidence manifest SHA256 与 quota/accounting/guardrail/remaining-balance/recharge-voucher artifacts 匹配。
4. TODO-32J payment/order/invoice 与 TODO-32K subscription/package 继续 deferred_runtime_external_dependency，除非 Product/Finance/Ops 提供 resume inputs。

允许写入：
- scripts/verify_trusted_user_quota_rate_budget_record.ps1
- scripts/write_trusted_user_quota_rate_budget_record_template.ps1
- scripts/verify_voucher_backed_api_distribution_accounting_gate.ps1
- scripts/verify_voucher_quota_pricing_guardrails.ps1
- crates/billing-ledger/**
- tests/fixtures/billing/**
- docs/todo/slices/E9-004.md

DoD：
- selftest pass。
- real target-user record mode pass or precise exit 2 blockers。
- output metadata-only artifact，secret_safe=true，paid_gate_changed=false。
```

---

# Dispatch API-3：E8 Gateway Distribution Proof

```text
你是 Agent-E8。当前任务是保护 Gateway 侧 API 分发证据，不是重开 production tokenizer/ClickHouse/paid full RC。

目标：
1. `.tmp/launch/e8_gateway_paid_hot_path_launch_check.json` remains passed。
2. insufficient-balance request returns 402 and creates zero provider_attempts。
3. Gateway voucher distribution readiness remains pass。
4. handoff manifest 包含 Gateway artifact path/schema/status/SHA。

允许写入：
- apps/gateway/src/**
- scripts/verify_gateway_paid_hot_path_smoke.ps1
- scripts/verify_voucher_api_distribution_readiness.ps1
- scripts/verify_gateway_voucher_distribution_readiness.ps1
- scripts/operator/gateway_paid_hot_path_readback.sql
- tests/fixtures/gateway/**
- docs/todo/slices/E8-004.md

DoD：
- targeted Gateway tests/smoke pass。
- no-provider-call proof visible in artifact/readback。
- secret_safe=true。
- production tokenizer/read-model remains TODO-40/RC only。
```

---

# Dispatch API-4：QA / Security Handoff Gate

```text
你是 Agent-QA。当前任务是验收 selected trusted-user API handoff，不修业务代码。

必须串行运行，不得并行刷新和读取 `.tmp/launch` hashes：
1. scripts/prepare_trusted_user_api_distribution_packet.ps1 with target-user fields。
2. scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1 against target-user summary。
3. scripts/verify_trusted_user_quota_rate_budget_record.ps1 against target-user record。
4. scripts/release_check.ps1 -Checks launch。
5. scripts/scan_secrets.ps1。

允许写入：
- project/ACCEPTANCE_CHECKLIST.md
- project/RELEASE_CHECKLIST.md
- docs/P0_BETA_STATUS.md
- QA output artifacts under .tmp/launch or artifacts

DoD：
- actual handoff commands exit 0。
- default/dry-run exit 2 only accepted for missing external user fields。
- artifacts fresh, repo-bounded, secret-safe, metadata-only。
```

---

# Dispatch API-5：Docs / Product Coordination

```text
你是 Agent-Docs/Product。当前任务是防止旧 paid/global blocker 文案误导分发主线。

允许写入：
- TODO/AGENT_COORDINATION_2026-06-05.md
- TODO/AI_GATEWAY_AGENT_EXECUTION_PACK_2026-06-05.md
- TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md
- TODO/AI_GATEWAY_TOD_TECH_DEBT_2026-06-05.md
- docs/P0_BETA_STATUS.md
- project/PROJECT_BOARD.csv

DoD：
- TODO/ remains authoritative。
- P0_BETA_STATUS summarizes current API distribution state。
- docs/TODO.md not authoritative。
- Board says next task is per-user packet + API distribution, not usage-only/paid blocker decision。
- deferred_runtime_external_dependency has resume conditions and owner。
```

---

# Dispatch 0：Repository Truth Reset

```text
你是 Agent-Repo。你的任务是恢复仓库可 Review 与 CI 真相，不修业务代码。

目标：
1. 恢复 .github/workflows/ci.yml 或创建真实 CI workflow。
2. 分类当前 modified/untracked 文件。
3. 维护 docs/P0_BETA_STATUS.md 作为当前状态摘要视图；权威 TODO 入口仍为 TODO/。
4. 将 E8 production tokenizer、E9 production cutover、E15 ClickHouse 移为 Production RC，不再挡 Beta。

写入范围：
- .github/workflows/ci.yml
- .gitignore
- docs/P0_BETA_STATUS.md
- docs/TODO.md（index-only；不得写成权威 TODO）
- project/ACCEPTANCE_CHECKLIST.md
- project/PROJECT_BOARD.csv

必须运行：
- git status --short
- git diff --stat
- git diff --check

验收：
- CI workflow 存在。
- 文档不再使用 99.x% 作为唯一完成判断。
- 每个 blocker 有 owner、DoD、next action。
- 不改业务代码。
```

---

# Historical Dispatch 1：E11 Billing/Price Browser Mutation Closure（not current API distribution task）

```text
你是 Agent-E11。历史任务是关闭 Billing/Price 页面 Beta blocker；当前 API 分发任务请优先使用 Dispatch API-1。

问题：
当前 Billing execute/browser evidence 不能 pass，因为 runtime-current Docker probe / permission / timestamp mismatch 导致 artifact 不可信。你必须先修 runtime-current probe，再跑真实 browser mutation/readback。

目标：
1. 修复 scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1 的 runtime-current detection。
2. 生成 fresh runtime_current artifact。
3. 使用真实 Admin UI/session 执行 Billing/Price mutation。
4. 证明 API/DB/UI readback 指向同一 ledger entry 或 price version。
5. 证明 audit log 写入。
6. 证明 artifact secret-safe。

允许写入：
- scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1
- web/admin-ui/src/billingExecuteSmokeContract.ts
- web/admin-ui/src/billingExecuteSmokeContract.serializable.json
- web/admin-ui/src/App.test.tsx
- apps/control-plane/src/admin.rs（仅 API/readback 必要修复）
- docs/E11-007_LEDGER_EXECUTE_OPENAPI_VALIDATION_RUNBOOK.md

禁止：
- 不得改 Gateway。
- 不得复用 stale artifact。
- 不得把 contract-only pass 当 browser pass。

必须运行：
1. Contract gate。
2. Runtime-current artifact write/readback。
3. Browser mutation artifact write/readback。
4. npm ci/test/build/bundle。

Pass 条件：
- runtime_current_verified=true
- mutation_pass_artifact_passed=true
- artifact_readback_passed=true
- audit_log_readback_passed=true
- secret_safe_scan=pass
```

---

# Historical Dispatch 2：E13 Prompt Protection Report + Audit Closure（not current API distribution task）

```text
你是 Agent-E13。历史任务是关闭 Prompt Protection Beta blocker；当前 API 分发仅在 prompt protection artifact regression 时重开。

问题：
live proof 接近完成，但 EvidenceReportPath 写入失败，contract 与 secret-safe 分类混在一起。Beta 需要稳定 report 落盘和 runtime-owned audit row readback。

目标：
1. 拆分 Assert-EvidenceReportContract 与 secret-safe 诊断。
2. 修复 Write-EvidenceReportIfRequested。
3. 运行 self-tests。
4. 用显式 live env 跑 4 endpoint proof。
5. 生成 .tmp/prompt_protection_beta_live_report.json。
6. 证明 provider_attempts_count=0。
7. 证明 runtime-owned Audit Logs row readback。
8. accepted redeploy artifact 只列为 RC 后置。

允许写入：
- scripts/verify_prompt_protection_postgres_proof.ps1
- docs/E13-005_PROMPT_PROTECTION_POSTGRES_PROOF_RUNBOOK.md
- apps/gateway/src/main.rs / apps/gateway/src/db.rs（仅 runtime-owned audit writer 必要修复）
- Admin UI audit/readback tests（仅必要）

禁止：
- 不得让 reject path 调 provider。
- 不得生成 provider_attempts。
- 不得输出 prompt 明文或 token。
- 不得用 proof-owned row 代替 runtime-owned row。

必须运行：
- -SelfTestEvidenceReportContract
- -SelfTestEvidenceReportPathSafety
- -Live -BrowserAuditDetailAttempt -EvidenceReportPath .tmp/prompt_protection_beta_live_report.json

Pass 条件：
- live_request_id_count=4
- 每个 case provider_attempts_count=0
- current_runtime_owned_row_count>=1
- gateway_runtime_provenance_status=pass
- secret_safe_scan=pass
- report readback pass
```

---

# Dispatch 3：E8 Gateway Runtime Rate-Limit Reservation

```text
你是 Agent-E8。你的任务是把 E8 从 production tokenizer 空转拉回 Beta 必需能力：真实 Gateway 请求路径必须有 DB reservation/readback。

目标：
1. 证明 Gateway live request 会 acquire reservation。
2. 成功/失败/client cancel 后 release 或有明确状态。
3. limit exceeded 时不进入 provider_attempts。
4. 缺真实 tokenizer 时使用 conservative estimated TPM，并在日志中标记 estimated。
5. production tokenizer/read-model runner 移入 RC，不作为 Beta pass 条件。

允许写入：
- apps/gateway/src/main.rs
- apps/gateway/src/db.rs
- apps/gateway/src/tpm_estimate.rs
- crates/db/src/rate_limit_reservation.rs
- scripts/verify_gateway_rate_limit_reservation_smoke.ps1
- scripts/operator/e8_rate_limit_db_acquire_readback.sql
- tests/fixtures/gateway/rate_limit_*.json

禁止：
- 不得把 no-op reservation 当 applied。
- 不得要求 production tokenizer 才能 Beta pass。
- 不得读取 raw prompt 到外部 tokenizer。

必须运行：
- verify_gateway_rate_limit_reservation_smoke.ps1 -PreflightOnly
- verify_gateway_rate_limit_reservation_smoke.ps1 live/default
- targeted cargo tests

Pass 条件：
- acquire_count > 0
- release_count 或明确 not_applied/refund/release 状态可读回
- limit exceeded provider_attempts=0
- estimated_tpm=true 在 request/route evidence 中可见
- secret-safe
```

---

# Dispatch 4：E9 Billing Ledger / Paid Evidence Follow-up

```text
你是 Agent-E9。用户已允许 paid；不要再把 usage-only 当作最终选择。当前同步口径：controlled paid beta evidence 已由 main review 接受，`paid_controlled_beta_allowed=true` 仅适用于受控 Paid Beta evidence，不等于 full Production RC。

目标 A：usage_only_beta fallback/safe mode
- 文档/UI/API 明确这是 paid 证据通过前的 fallback，不承诺余额强一致扣减。
- usage/cost 可以展示，但 ledger 不标 settled source-of-truth。
- 不允许把 fallback 口径包装成 paid beta 已放行。

目标 B：paid_controlled_beta_allowed follow-up
- 保留 accepted artifacts 的回归守卫：E8 Gateway paid hot path、E11 readback/reconciliation、E9 readiness gate、real evidence bundle、QA paid aggregator。
- 不把 controlled paid beta evidence 扩大解释成 full Production RC。
- partial refund policy、deeper reconciliation、source-of-truth cutover ceremony、production incident/runbook hardening 后置到 RC/paid hardening。
- 若 accepted artifacts 缺失、hash/shape 回退、secret scan 失败，立即回退为 blocked，并写明具体 artifact。

允许写入：
- crates/billing-ledger/src/*
- apps/control-plane/src/admin.rs（ledger writer 调用必要部分）
- apps/worker/src/billing_reconciliation.rs
- scripts/verify_control_plane_billing_ledger_runtime_writer_readiness.ps1
- scripts/verify_billing_ledger_sqlx_live_smoke.ps1
- tests/fixtures/billing/*
- docs/P0_BETA_STATUS.md

禁止：
- 不得双写 source-of-truth。
- 不得用 dashboard aggregate 当账务真相。
- 不得使用 float 金额。
- 不得缺少幂等键。

必须先输出：
- billing_mode_requested=paid_controlled_beta_allowed
- paid_controlled_beta_status=controlled_paid_beta_evidence_accepted_by_main_review
- usage_only_beta 仅作为 fallback/safe mode 的限制文案
- production_rc_status=not_claimed

Paid pass 条件：
- reserve insufficient balance prevents provider call
- settle idempotent
- refund idempotent
- post-commit readback pass
- rollback proof pass
- reconciliation pass
- Gateway reserve/settle/refund hot path pass
- accepted real evidence bundle remains present and passes verification
- production RC caveats remain explicit
```

---

# Dispatch 5：OBS/Admin Request Explainability

```text
你是 Agent-OBS。你的任务是让 Beta 运维能解释请求、错误和扣费。

目标：
1. Request detail 能展示 route decision、provider/channel/key、usage/cost/error/stream/ledger/guardrail。
2. E8/E11/E13 产生的 request_id 都能查到。
3. payload lazy-load，不泄漏 prompt/response 明文。
4. error shape 包含 request_id、error_code、provider_status、retryable、support_hint。

允许写入：
- apps/control-plane/src/admin.rs request/trace 查询 API
- web/admin-ui/src/components/RequestLogsPage.tsx
- web/admin-ui/src/components/HealthDashboard.tsx
- web/admin-ui/src/components/PromptProtectionSummary.tsx
- tests/fixtures/control-plane/request_log_detail_ledger_contract.json
- tests/fixtures/control-plane/trace_request_summary_contract.json

Pass 条件：
- 用 E8/E11/E13 smoke request id 可从 Admin UI/API 读回核心字段。
- metadata-only/redacted policy 下无明文 prompt。
- UI tests pass。
```

---

# Historical Dispatch 6：QA Beta Gate（use Dispatch API-4 for current handoff）

```text
你是 Agent-QA。你的任务是最终 Beta gate，不修业务功能，只验收和回填 checklist。

前置：E11/E13/E8 pass；E9 已明确 billing mode。

必须运行：
- scripts/test.ps1
- verify_compose_smoke.ps1
- verify_sdk_smoke.ps1
- scan_secrets.ps1
- scan_supply_chain.ps1
- Admin UI npm ci/test/build/bundle

必须更新：
- project/ACCEPTANCE_CHECKLIST.md
- project/RELEASE_CHECKLIST.md
- docs/P0_BETA_STATUS.md

Pass 条件：
- 所有当前 API distribution gates pass；历史 Beta blockers 只做 regression watch。
- 未完成项均为 Paid Beta 或 Production RC。
- beta_acceptance_summary_<run_id>.json 生成且 secret-safe。
```

---

# Dispatch 7：ToD Refactor Captain

```text
你是 Agent-ToD。你的任务不是抢当前 API 分发主线，而是在 distribution gate 关闭后降低技术债。

首批 ToD：
1. 恢复 CI 可信度。
2. Admin UI 依赖可复现。
3. 巨型 Rust 文件按 domain 拆分。
4. 源码字符串断言迁移为行为测试。
5. evidence scripts 共用 schema。

规则：
- 每个 PR 只做一个 domain 的无行为变更拆分。
- 必须附 before/after line count。
- 必须通过原有行为测试。
```
