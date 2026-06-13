# AI Gateway 项目重排 TODO（面向 Agent 执行版）

生成日期：2026-06-05  
口径：Distribution-ready API Beta 优先，Paid Beta 次之，Production RC 后置  
当前仓库快照：`main @ 8e3318d`，工作区存在未提交修改与未跟踪文件；`.github/workflows/ci.yml` 当前存在。完整 CI / full wrapper gate 尚未在本次同步中重跑，E0-002 保持 `NeedsReverify`。

> 2026-06-06 Open-source CTO priority：当前 trusted-user voucher-backed API Beta 只说明“可对可信目标用户分发 API”，不等于开源 New API 替代品已经足够。开源 Alpha 的权威优先级见 `TODO/OPEN_SOURCE_ALPHA_PRIORITY_2026-06-06.md`：P0 先补 clone-and-run Compose、live API distribution smoke、README/Quickstart、最小 Admin/API 操作链、open-source Alpha gate；P1 做 New API/One API apply/rollback、model/channel/key parity、trace/cost explainability、budget/rate-limit hardening；P2 才推进 public/self-serve voucher UX、payment/order/invoice runtime、subscription runtime；P3 是 full CI/RC/staging/load/security/refactor。

---

## 0. 统一判断

本项目当前不再按单一 `99.x%` 进度推进。后续所有 Agent 只按四个里程碑判断任务归属：

| 里程碑 | 目标 | 是否当前主线 |
|---|---|---:|
| Local P0 | 本地 compose/dev seed/mock provider 可证明核心链路跑通 | 是，但已接近尾声 |
| Distribution-ready API Beta | 能给可信用户发 virtual key，用户可调用 Gateway，Admin 可配置和排障 | **当前主线** |
| Paid / controlled beta | 支持真实余额、扣费、退款、幂等对账 | 紧随其后 |
| Production RC | staging/K8s、load/chaos/security、真实 provider/tokenizer、ClickHouse、备份恢复演练 | 后置，不阻塞 Beta |

**当前主目标：Distribution-ready API Beta。** 任何与 Beta 无直接关系的 production-only evidence 不再占用主线 Agent。

### 2026-06-06 当前 API 分发口径（Agent 必读）

当前目标已经从“继续找 paid/global blocker”切到“让产品可以分发 API”。可分发范围是 scoped trusted-user voucher-backed API Beta：Release/Ops 为目标可信用户准备 operator-issued virtual key、voucher/redeem-code quota、quota/rate/budget record、handoff summary、evidence manifest、secret scan，并在目标用户字段齐全后交付 API 使用包。

2026-06-07 OS-A2-01 route proof update：`POST /admin/voucher-issuances` 与 `POST /billing/vouchers/redeem` 已接入 Control Plane 真实 handler，并由 RBAC `BillingAdjust` 保护；`.tmp/route-live-http-proof/route_level_live_http_proof.json` 当前为 `overall_status=pass`，证明 live HTTP route invocation、voucher issue/redeem/attempt/credit-grant/ledger/audit readback、secret-safe、无 raw voucher code artifact、`paid_gate_changed=false`。`.tmp/launch/voucher_public_route_and_virtual_key_evidence.json` 当前消费该 proof 并报告 `overall_status=pass`、`voucher_route_evidence.status=live_route_verified`、`route_invoked=true`、`route_verified=true`、`public_routes_wired=true`、`blockers=[]`。本文后续历史段落若仍写 `voucher_public_control_plane_routes_not_wired`、`overall_status=partial`、`public_routes_wired=false` 或 live proof pending，仅作为旧快照记录，不得作为当前事实。剩余产品化缺口是 public self-serve UX/productization：operator-free screens/client flow、quota/rate budget selection、user-facing errors、final handoff metadata capture，以及保持 replay/refusal/no-write 等 live proof 证据不过期；这不依赖外部支付/订阅完成。

权威源顺序：

1. `TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md` 与 `TODO/AGENT_COORDINATION_2026-06-05.md` 是调度权威。
2. `TODO/AI_GATEWAY_AGENT_EXECUTION_PACK_2026-06-05.md` 是派发模板。
3. `docs/P0_BETA_STATUS.md` 是摘要视图。
4. `docs/TODO.md` 不是权威源，不得被新 Agent 当作 TODO 入口。

当前 5-Agent 分工：

| Agent | Owner | 当前职责 | DoD |
|---|---|---|---|
| Agent-E11 | Admin Billing / Operator Route | operator-mediated voucher issuance / virtual-key handoff；public voucher route polish 不做全局 blocker | RBAC `BillingAdjust`、hash/redaction、idempotency、audit/readback、refusal-no-write、secret-safe artifact |
| Agent-E9 | Billing Ledger / Quota Guardrails | quota/rate/budget record verifier、accounting gate、wallet/credit/voucher evidence | fixed-decimal money、currency/readback、bounded refs、RPM/TPM/budget/expiry/rollback/audit、manifest SHA match |
| Agent-E8 | Gateway Distribution Proof | Gateway paid/balance/no-provider-call proof 与 voucher readiness manifest 字段 | `e8_gateway_paid_hot_path_launch_check` passed、402/no-provider-call、secret-safe、production tokenizer only RC |
| Agent-QA | Security / Release Gate | 串行 handoff orchestrator、manifest verifier、quota verifier、release check、secret scan | target-user handoff exit 0；default dry-run exit 2 只表示 missing external fields；fresh repo-bounded artifacts |
| Agent-Docs/Product | Coordination | 同步 TODO/P0/Board，清理旧 paid/global blocker 误导 | `TODO/` 权威、P0 摘要、Board next task 指向 per-user packet/API distribution |

blocked/external-input rules：

- `ready_to_send=false` 且只缺 release owner、support contact、tenant/project/user/wallet ids 或 `trusted_user_id_or_owner_ref`、voucher quota、rate/budget guardrails、rollback owner、bounded evidence links、`real_user_values_present=true` 时，标为 per-user external input；它阻止某个用户的 key handoff，但不是 global launch blocker。若目标是 `internal-trusted-beta-001`，只能称为 CTO 指定内部可信 Beta 用户，不得称为外部客户、public self-serve 或 full commercial launch。
- TODO-32J payment/order/invoice runtime 与 TODO-32K subscription/package lifecycle runtime 在 provider/callback/capture 或 scheduler/provider/invoice runtime 不可用时保持 `deferred_runtime_external_dependency`；写 resume conditions，不反复派 Agent 空转。
- Artifact regression、manifest hash mismatch、secret scan fail、Gateway insufficient-balance no-provider-call proof 缺失、真实 quota record verifier exit 2 是当前主线 blocker，派 owning Agent 修复。

---

## 1. 当前必须冻结的事情

以下任务不得再作为 Beta blocker 继续空转：

1. **E15 ClickHouse production smoke**：移入 Production RC。Beta 可先用 Postgres request log / trace / dashboard 基础能力。
2. **E8 production tokenizer/read-model runner**：移入 Production RC。Beta 先用保守 TPM fallback，但必须证明 Gateway live path 的 DB reservation/readback 生效。
3. **E9 production source-of-truth cutover**：移入 Paid Beta / Production RC。用户已允许 paid；main review 已接受 controlled paid beta evidence，当前 `paid_controlled_beta_allowed=true` for controlled paid beta。Full Production RC source-of-truth cutover、partial refund policy、deeper reconciliation 仍为后置 RC work。
4. **E13 accepted redeploy artifact/operator marker**：移入 RC closure。Beta blocker 是 report write/readback + runtime-owned audit row，不是完整 operator redeploy ceremony。
5. **缺失的外部 provider/scheduler runtime**：不得再反复派 Agent 空转。TODO-32J payment/order/invoice 与 TODO-32K subscription/package lifecycle 当前按 `deferred_runtime_external_dependency` 处理，保留 contract/schema/defer artifact 和 resume conditions；Distribution-ready API Beta 先走 voucher/redeem-code 配额 + virtual key 分发闭环。

---

## 2. 总执行顺序

```text
P0-00 Repository Truth Reset
  -> P0-01 CI / reproducible test gate 恢复
  -> P0-02 文档状态统一
  -> 并行修 Beta blockers：E11、E13、E8、E9
  -> P0-03 Full Local Gate
  -> P0-04 Beta Acceptance Checklist
  -> 可信用户 API Beta
  -> Paid Beta hardening
  -> Production RC closure
```

所有 Agent 必须遵守：

- 不准把 fixture/simulation/handoff/watcher 标为 final pass。
- 不准把 stale artifact 标为 pass。
- 不准输出 provider key、virtual key、session token、password、Authorization、Cookie。
- 不准扩大任务写入范围；必须在交付报告中列出 changed files。
- 不准绕开后端 RBAC/audit/ledger，只修 UI 假象。
- 每个 Agent 必须提交：`changed_files`、`commands_run`、`artifacts_written`、`acceptance_results`、`blockers`、`next_task`。

---

# PHASE 0：仓库真相与协作口径重置

## TODO-00：恢复 CI 与可 Review 状态

**Owner**：Agent-Repo / Build Captain  
**Priority**：P0 Beta blocker  
**状态**：完成 / CI NeedsReverify（Sagan `019e9905-7e75-7b23-9e14-f24229090220`）

### 背景

早期 working tree 曾显示 `.github/workflows/ci.yml` 被删除；当前同步确认该文件已存在。仍存在大量 modified/untracked 文件，且完整 CI / full wrapper gate 未重跑，因此 “通过 CI” 的 Done 定义尚不能恢复。

### 写入范围

允许：

- `.github/workflows/ci.yml`
- `.gitignore`
- `docs/P0_BETA_STATUS.md`
- `docs/TODO.md` 或新建 `docs/todo/*.md`
- 仅必要的 `scripts/test.ps1` / release gate 文档注释

禁止：

- 不得顺手改业务代码。
- 不得删除 artifacts 前不列清单。
- 不得把 node_modules、pycache、.tmp 作为正式证据提交。

### 执行步骤

1. 记录当前状态：

```powershell
git rev-parse --short HEAD
git status --short
git diff --stat
git diff --check
```

2. 恢复 CI workflow：

```powershell
git checkout -- .github/workflows/ci.yml
```

如 CI 文件是故意迁移到 `examples/ci_github_actions_example.yml`，必须新建真实 `.github/workflows/ci.yml`，并让它调用现有脚本，而不是只保留 example。

3. 清理忽略项：

```powershell
git status --short
# 只预览，不直接清理
git clean -ndX
git clean -nd
```

4. 建立当前状态摘要视图：`docs/P0_BETA_STATUS.md`，权威入口仍为 `TODO/`，至少包含：

- 当前 Beta blockers：E11/E13/E8/E9。
- Production closure 后置项：E8 production tokenizer、E9 production cutover、E15 ClickHouse。
- 验收清单对应 owner。
- 当前可运行命令与不可运行环境说明。

### 验收标准

- `.github/workflows/ci.yml` 存在，且包含 Rust、PowerShell smoke、Admin UI test/build、secret scan、supply-chain scan。
- `git diff --check` 无 whitespace error；CRLF warning 可记录但不能隐藏。
- `docs/P0_BETA_STATUS.md` 成为当前状态摘要，`TODO/` 仍为权威入口，`docs/TODO.md` 不再混写 Local P0 与 Production RC。
- 未跟踪文件清单被分类：`commit`、`ignore`、`delete`、`operator-only artifact`。

### 交付报告格式

```json
{
  "task_id": "TODO-00",
  "status": "pass|blocked|fail",
  "commit": "<short sha>",
  "ci_restored": true,
  "git_diff_check": "pass|warn|fail",
  "untracked_classification_written": true,
  "changed_files": [],
  "commands_run": [],
  "blockers": []
}
```

### Agent-Repo 交付结果（2026-06-05）

```json
{
  "task_id": "TODO-00",
  "status": "pass",
  "commit": "8e3318d",
  "ci_restored": true,
  "git_diff_check": "warn",
  "untracked_classification_written": true,
  "changed_files": [
    ".gitignore",
    "docs/P0_BETA_STATUS.md",
    "project/ACCEPTANCE_CHECKLIST.md",
    "project/PROJECT_BOARD.csv",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "commands_run": [
    {"command": "git rev-parse --short HEAD", "exit_code": 0, "classification": "pass"},
    {"command": "git status --short", "exit_code": 0, "classification": "pass"},
    {"command": "git diff --stat", "exit_code": 0, "classification": "pass"},
    {"command": "git diff --check", "exit_code": 0, "classification": "warn_crlf_only"},
    {"command": "git clean -ndX", "exit_code": 0, "classification": "preview_only"},
    {"command": "git clean -nd", "exit_code": 0, "classification": "preview_only"},
    {"command": "git status --short --untracked-files=all", "exit_code": 0, "classification": "pass"},
    {"command": "git check-ignore -v TODO/... docs/todo/... scripts/operator/... tests/fixtures/... web/admin-ui/node_modules/... .tmp/...", "exit_code": 0, "classification": "pass"}
  ],
  "artifacts_written": [
    {"path": "docs/P0_BETA_STATUS.md", "schema": "repo_truth_status_markdown_v1", "secret_safe": true, "fresh": true, "simulation": false}
  ],
  "acceptance_results": {
    "ci_workflow_present": true,
    "ci_workflow_contains_rust_fmt_check_clippy_test": true,
    "ci_workflow_contains_powershell_smoke": true,
    "ci_workflow_contains_admin_ui_npm_ci_test_build_bundle": true,
    "ci_workflow_contains_secret_scan": true,
    "ci_workflow_contains_supply_chain_or_sbom_gate": true,
    "gitignore_excludes_local_dependencies_and_caches": true,
    "gitignore_keeps_todo_docs_operator_fixtures_committable": true,
    "modified_untracked_classification_written": true,
    "project_board_e0_002_status": "Done",
    "full_ci_gate_run": true,
    "superseded_by": "2026-06-07 full wrapper pass",
    "full_wrapper_pass_artifact": ".tmp/launch/full_wrapper_rerun_20260607_143200_pass.json"
  },
  "blockers": [],
  "next_task": "E0-002 is closed for local wrapper evidence; TODO-14 live Admin/API metadata-only readback is pass for API distribution; E4 default-price Admin UI browser evidence is pass; continue E3 production rotate endpoint/KMS work, E12 operator-secret handoff, clean-clone public-tag transcript, broader Admin UI parity/trace polish, and public/commercial productization."
}
```

## TODO-01：统一验收文档，不再使用失真百分比

**Owner**：Agent-PM / Documentation Captain  
**Priority**：P0 Beta blocker  
**状态**：完成 / 持续回填（Sagan `019e9905-7e75-7b23-9e14-f24229090220`）

### 写入范围

- `docs/P0_BETA_STATUS.md`
- `project/ACCEPTANCE_CHECKLIST.md`
- `project/PROJECT_BOARD.csv`
- `docs/TODO.md`

### 执行步骤

1. 将所有任务状态改为四类：`Local P0`、`Beta`、`Paid Beta`、`Production RC`。
2. 删除或降级 `99.x%` 数字，改为明确 checklist。
3. `project/ACCEPTANCE_CHECKLIST.md` 必须把已验证项勾上，把未验证项写 owner 和 blocker。
4. `project/PROJECT_BOARD.csv` 中 `Status=Done` 的项必须有当前证据；CI 缺失时 `E0-002` 不能继续标完全 Done，至少改为 `NeedsReverify`。

### 验收标准

- 文档之间不再冲突：Acceptance、Board、TODO、Status 四者一致。
- 每个未完成项都至少有：owner、next action、DoD、blocked reason。
- Production-only 项不会显示为 Beta blocker。

### Agent-Repo 交付结果（2026-06-05）

```json
{
  "task_id": "TODO-01",
  "status": "pass",
  "commit": "8e3318d",
  "changed_files": [
    "docs/P0_BETA_STATUS.md",
    "project/ACCEPTANCE_CHECKLIST.md",
    "project/PROJECT_BOARD.csv",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "commands_run": [
    {"command": "rg -n \"E0-002|Repository truth|TODO-00|TODO-01|99\\\\.|TODO/\" project docs TODO.md TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md", "exit_code": 0, "classification": "pass"}
  ],
  "artifacts_written": [
    {"path": "docs/P0_BETA_STATUS.md", "schema": "beta_status_markdown_v1", "secret_safe": true, "fresh": true, "simulation": false}
  ],
  "acceptance_results": {
    "todo_directory_is_authoritative": true,
    "docs_todo_not_entrypoint": true,
    "acceptance_board_status_aligned": true,
    "production_only_items_not_beta_blockers": true,
    "e0_002_kept_needs_reverify": true
  },
  "blockers": [
    "Future blocker closures still need evidence-specific backfill by the owning Agent."
  ],
  "next_task": "Keep TODO/ authoritative and update Acceptance/Board/P0 status only with fresh pass evidence."
}
```

---

# PHASE 1：Beta blocker 并行收口

## TODO-10：E11 Billing / Price 页面真实 mutation + readback

**Owner**：Agent-E11 / Admin Billing  
**Priority**：P0 Beta blocker  
**状态**：Beta pass；S97 release artifact readback gate 已接入（`scripts/test.ps1 -ControlPlaneLedgerAdjustmentExecuteBrowserReadbackOnly`）  
**依赖**：TODO-00 至少恢复 CI；本地 Control Plane/Admin UI/Postgres 可运行。

### 当前问题

Billing/Price 页面和 smoke contract 已经很多，但最终 blocker 是 Docker probe / runtime-current mismatch，导致 browser mutation artifact 不能被信任。Beta 运维必须能在 Admin UI 做价格或 ledger adjustment，并真实写入后端，再读回确认。

### 写入范围

允许：

- `scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1`
- `web/admin-ui/src/billingExecuteSmokeContract.ts`
- `web/admin-ui/src/billingExecuteSmokeContract.serializable.json`
- `web/admin-ui/src/App.test.tsx`
- 必要时 `apps/control-plane/src/admin.rs` 中 ledger adjustment / price API 的最小修复
- `docs/E11-007_LEDGER_EXECUTE_OPENAPI_VALIDATION_RUNBOOK.md`

禁止：

- 不得改 Gateway。
- 不得把 stale browser artifact 标 pass。
- 不得只修 UI，不修 API/readback。
- 不得绕过 Admin session/RBAC。

### 任务拆解

#### E11-10A：runtime-current probe 修复

目标：让脚本能证明正在跑的 Control Plane 与当前源码/commit 对齐。

必须检查：

- container created timestamp / image id / git commit marker / source timestamp 对齐规则。
- no-build recreate 和 rebuild handoff 两条路径输出不同 classification。
- stale image 必须返回 blocker，不得 pass。

推荐命令：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1 `
  -ContractOnly

pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1 `
  -RuntimeCurrentNoBuildRecreateOptIn `
  -RuntimeCurrentEvidenceArtifactWriteOptIn `
  -RuntimeCurrentEvidenceArtifactReadbackOptIn `
  -RuntimeCurrentEvidenceArtifactPath artifacts/control_plane_ledger_execute_runtime_current_verified_beta.json
```

#### E11-10B：browser mutation pass

目标：用真实 Admin UI 操作完成 mutation，后端写入，页面/API/DB 至少两种路径读回。

必须覆盖：

- 登录/session handoff 通过。
- Billing/Price 页面可执行 mutation。
- mutation 后有 ledger entry 或 price version row。
- audit log 有对应管理操作。
- artifact 包含 request id / ledger id / price version id，但不含 secret。
- stale artifact、contract-only artifact、simulation artifact 一律不能关闭。

推荐命令：

```powershell
$env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_RUNNER='1'
$env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_ARTIFACT_WRITE='1'
$env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_ARTIFACT_READBACK='1'
$env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_BROWSER_ARTIFACT_PATH='artifacts/billing_execute_browser_live_e2e_beta.json'

pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1 `
  -BrowserLiveRunnerExecutionOptIn `
  -BrowserMutationOptIn `
  -BrowserEvidenceArtifactWriteOptIn `
  -BrowserEvidenceArtifactReadbackOptIn `
  -BrowserEvidenceArtifactPath artifacts/billing_execute_browser_live_e2e_beta.json
```

### Done 定义

- `runtime_current_verified=true`。
- `mutation_pass_artifact_passed=true`。
- `artifact_readback_passed=true`。
- Admin UI mutation 与 API/DB readback 对同一对象 ID 成功。
- audit log readback 成功。
- secret-safe scan 通过。
- `npm --prefix web/admin-ui ci && npm --prefix web/admin-ui test && npm --prefix web/admin-ui run build && npm --prefix web/admin-ui run check:bundle` 通过。
- S97 release/RC readback pack：只读 gate 读取 `artifacts/control_plane_ledger_execute_runtime_current_verified_beta.json` 与 `artifacts/billing_execute_browser_live_e2e_evidence.json`，要求 current commit、`runtime_current_verified`、`mutation_pass_artifact_passed`、`artifact_readback_passed`、API/DB/UI/audit readback marker、numeric durations 与 secret-safe；missing/stale/simulated/wrong-commit artifact 均阻断 release。

### Blocked 定义

- Docker/Compose/Control Plane 不可用：blocked，不是 fail。
- Playwright 不可用或 Admin UI dev server 不可用：blocked。
- API 返回 4xx/5xx 或 readback mismatch：fail。

---

## TODO-11：E13 Prompt Protection report write/readback + runtime-owned audit

**Owner**：Agent-E13 / Security Runtime  
**Priority**：P0 Beta blocker  
**状态**：Beta pass（S97 closure audit：`.tmp/prompt_protection_beta_closure_report.json`）  
**依赖**：Gateway + Postgres + mock provider 可运行。

### 当前问题

S97 已拆分 Beta 必需证据与 browser/accepted-redeploy/RC 证据。Beta closure artifact `.tmp/prompt_protection_beta_closure_report.json` 为 fresh live report，`status=passed`、`exit_code=0`、`beta_closure_eligible=true`，4 endpoint live proof、zero provider attempts、runtime-owned Audit Logs API readback、report write/readback 和 secret-safe scan 均通过。

### 写入范围

允许：

- `scripts/verify_prompt_protection_postgres_proof.ps1`
- `docs/E13-005_PROMPT_PROTECTION_POSTGRES_PROOF_RUNBOOK.md`
- 必要时 `apps/gateway/src/main.rs`、`apps/gateway/src/db.rs` 中 prompt-protection audit writer 最小修复
- Admin UI audit/request detail 的测试，仅限 readback 展示

禁止：

- 不得让 reject path 打开 provider key。
- 不得生成 provider_attempts。
- 不得把 proof-owned audit row 当 runtime-owned row。
- 不得把 accepted redeploy operator artifact 作为 Beta 必选项。

### 任务拆解

#### E13-11A：拆分 report contract 与 secret-safe 诊断

目标：`Assert-EvidenceReportContract` 不再吞掉 secret-safe 分类；写入失败要明确是 path safety、contract mismatch、secret-safe violation、serialization error，还是 live blocker。

必须新增/修复 self-test：

- contract pass + secret-safe pass -> exit 0。
- contract pass + secret-safe fail -> exit 1，classification=`secret_safe_failure`。
- contract fail -> exit 1，classification=`contract_failure`。
- unsafe path -> exit 1，classification=`path_safety_failure`。
- live env missing -> exit 2，classification=`external_blocker`。

#### E13-11B：live report write/readback

推荐命令：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_prompt_protection_postgres_proof.ps1 `
  -SelfTestEvidenceReportContract

pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_prompt_protection_postgres_proof.ps1 `
  -SelfTestEvidenceReportPathSafety

pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_prompt_protection_postgres_proof.ps1 `
  -Live `
  -EvidenceReportPath .tmp/prompt_protection_beta_closure_report.json
```

Report 必须包含：

- `schema` / `run_id` / `commit` / `created_at_utc`。
- 4 个 endpoint case：chat_completions、responses、anthropic_messages、gemini_native_generate_content。
- 每个 case 的 opaque `request_id`。
- `live_request_id_count=4`。
- 每个 case：`provider_attempts_count=0`。
- `runtime_owned_row_count>=1` 或 `current_runtime_owned_row_count>=1`。
- `gateway_runtime_provenance_status=pass`。
- `admin_ui_api_readback_status=pass`。
- `secret_safe_scan=pass`。
- `beta_closure_audit.schema=prompt_protection_beta_closure_audit_v1`。
- `beta_closure_eligible=true`。
- Browser detail: `required_for_beta=false`，移交 TODO-14/OBS 或 UI E2E。
- Accepted redeploy artifact: `required_for_beta=false`、`required_for_rc=true`。

### Done 定义

- 4 endpoint live reject proof pass。
- request logs 是 hash-only/redacted，不保存明文 prompt。
- `provider_attempts_count=0`。
- runtime-owned Audit Logs row 可读回。
- Evidence report 落盘并读回。
- report secret-safe scan 通过。
- accepted redeploy artifact 被明确标记为 RC 后置，不挡 Beta。
- Browser detail 不作为 TODO-11 Beta blocker；若需要 UI/browser detail，移交 TODO-14/OBS 或 RC/UI E2E。

---

## TODO-12：E8 Gateway live path rate-limit reservation/readback

**Owner**：Agent-E8 / Gateway Runtime  
**Priority**：P0 Beta blocker  
**状态**：Beta live closure passed（S118 local bounded Gateway rebuild/rerun）；Production tokenizer/read-model final closure 后移 TODO-40/RC。  
**依赖**：Gateway + Postgres + mock provider 可运行。

### 当前问题

E8 已经堆了很多 production tokenizer/read-model evidence，但 Beta 真正需要的是：发出去的 virtual key 不会绕过 Gateway runtime 的 reservation/release，缺真实 tokenizer 时采用保守 fallback，不会无限放行。

### 写入范围

允许：

- `apps/gateway/src/main.rs`
- `apps/gateway/src/db.rs`
- `apps/gateway/src/tpm_estimate.rs` 的最小修复
- `crates/db/src/rate_limit_reservation.rs`
- `scripts/verify_gateway_rate_limit_reservation_smoke.ps1`
- `scripts/operator/e8_rate_limit_db_acquire_readback.sql`
- `tests/fixtures/gateway/rate_limit_reservation_live_smoke.json`
- `tests/fixtures/gateway/rate_limit_tpm_estimate_mapper_contract.json`

禁止：

- 不得要求 production tokenizer 才能 pass Beta。
- 不得读取 raw prompt 到不受控外部服务。
- 不得将 no-op reservation 伪装为 applied。

### 任务拆解

#### E8-12A：Gateway acquire/release runtime 证明

必须证明：

- Gateway 真实请求进入 reservation acquire。
- 成功/失败/client cancel 后 release 或 settle 状态正确。
- DB readback 能看到 acquire/release/not_applied/fallback 计数。
- 无可用 reservation 时返回清晰错误，不进入 provider。
- secret-safe。

推荐命令：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_gateway_rate_limit_reservation_smoke.ps1 -PreflightOnly

pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_gateway_rate_limit_reservation_smoke.ps1
```

#### E8-12B：保守 TPM fallback 策略

必须实现/证明：

- tokenizer missing 时采用 configurable conservative estimate。
- estimate 标记为 `estimated=true`。
- read-model/trusted tokenizer 只作为 Production RC enhancement。
- route decision / request log 中能看出本次 reservation 使用 estimated TPM。

### Done 定义

- [x] live smoke 通过，observed acquire/release row count > 0。S118 artifact：`.tmp/gateway-rate-limit-reservation/e8-s118-beta-live-smoke.json`。
- [x] forced limit exceeded 时 provider_attempts 不增加。S118 live artifact/readback 均显示 forced-limit provider_attempt rows = `0`。
- [x] fallback candidate 选择仍遵守 health/cooldown/fallback_allowed；S118 未改 route selection，仅重建 Gateway 并 rerun bounded smoke。
- [x] targeted tests 通过：`cargo test -p ai-gateway rate_limit_reservation --all-targets`、`cargo test -p ai-gateway rate_limit_tpm_estimate --all-targets`。
- [x] `scripts/operator/e8_rate_limit_db_acquire_readback.sql` 可读回同一 smoke run。S118 SQL readback artifact：`.tmp/gateway-rate-limit-reservation/e8-s118-beta-sql-readback.json`，`smoke_run_id=1780685446332`、request rows `3`、provider_attempt rows `3`、acquire `3`、release `1`、not_applied `1`、fallback `1`、`estimated_seen=true`。

### S118 Beta closure result

Gateway was rebuilt locally with `docker compose -f deploy/docker-compose/docker-compose.yml build gateway`. Default host ports `5432`/`6379` were blocked by Windows socket reservation during `up -d gateway`, so the compose stack was recovered with temporary host-port overrides `POSTGRES_HOST_PORT=55432` and `REDIS_HOST_PORT=56379`; container-internal service names/ports stayed unchanged. Fresh bounded live smoke and same-run SQL readback passed. This closes TODO-12 for Beta runtime reservation/readback. Do not mark production tokenizer/read-model final pass from this result; move that work to TODO-40/RC.

---

## TODO-13：E9 Billing Ledger minimal real writer commit / Beta billing mode

**Owner**：Agent-E9 / Billing Ledger  
**Priority**：P0 for Paid Beta；P1 for Free Trusted Beta  
**状态**：controlled paid beta evidence accepted by main review；`paid_controlled_beta_allowed=true` for accepted evidence  
**依赖**：用户已允许 paid；TODO-30A evidence gate、真实 paid evidence bundle、readiness gate、QA paid aggregator 已由主线程最终复核接受。`usage_only_beta` 仅保留为 fallback/safe mode。Operator/devrel 口径见 `docs/PAID_BETA_RUNBOOK.md`；required artifact index 见 `docs/PAID_BETA_EVIDENCE_INDEX.md`。

### 当前决策

用户已请求 paid，且 controlled paid beta evidence 已由 main review 接受；以下三态仍用于解释 fallback、implementation track 和 accepted controlled beta：

| 模式 | 允许行为 | 禁止行为 | 是否需要 E9 real writer commit |
|---|---|---|---:|
| `usage_only_beta` | fallback/safe mode：给可信用户免费试用，展示 usage/cost estimate，不做余额扣减 | 禁止当成最终 paid 选择；禁止销售按量计费；禁止承诺余额准确 | 否，但必须写明限制 |
| `paid_controlled_beta_requested` | active implementation track：小范围付费/余额试用目标 | 禁止 plan-only writer；禁止 dashboard 当账务真相；证据门禁未过前禁止上线/放行 | **是** |
| `paid_controlled_beta_allowed` | real evidence bundle accepted 后的小范围收费 Beta | 禁止把 controlled beta evidence 说成 full Production RC | 已完成且已验收 |

### 写入范围

允许：

- `crates/billing-ledger/src/*`
- `apps/control-plane/src/admin.rs` 中 ledger adjustment / writer 调用最小部分
- `apps/worker/src/billing_reconciliation.rs`
- `scripts/verify_control_plane_billing_ledger_runtime_writer_readiness.ps1`
- `scripts/verify_billing_ledger_sqlx_live_smoke.ps1`
- `tests/fixtures/billing/*`

禁止：

- 不得双写两个 source-of-truth。
- 不得把 dashboard 聚合当余额真相。
- 不得用 float 表示金额。
- 不得无幂等键写 ledger。

### 任务拆解 A：usage_only_beta fallback/safe mode

交付：

- `docs/P0_BETA_STATUS.md` 明确：`usage_only_beta` 是 paid 证据通过前的 fallback/safe mode，不承诺余额扣减。
- Admin UI 显示 `usage-only beta` badge。
- request log / trace 显示 estimated cost，但 ledger status 不标 settled。
- 预算/硬限额若未强一致，只允许 conservative deny，不允许超卖。

Done：

- 文档、UI、API response 都不会误导用户以为真实余额已扣减。
- 安全评审通过。

### 任务拆解 B：paid_controlled_beta

交付：minimal real writer commit。

必须覆盖：

- reserve：余额/预算不足时不调用上游。
- settle：成功请求按 price_version 结算。
- refund：上游失败、client cancel、partial policy 触发退款或明确扣费策略。
- idempotency：同 `request_id + ledger action` 重复执行不重复扣费/退款。
- readback：ledger_entries、wallet/balance、request log cost snapshot 可对账。
- rollback：失败时事务回滚，无半写。

推荐命令：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_billing_ledger_runtime_writer_readiness.ps1 `
  -PlanRuntimeWriterCommitRunner

pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_billing_ledger_sqlx_live_smoke.ps1
```

### Done 定义

Paid Beta 只有满足以下条件才可开：

- real commit artifact pass。
- post-commit readback pass。
- duplicate settle/refund idempotency pass。
- reserve insufficient balance prevents provider call。
- reconciliation report pass。
- rollback proof pass。
- cutover/source-of-truth 未完成时，文档明确仍非 Production Billing。

### S113/S114 派生结果（2026-06-05）

- S113 历史结果为 `usage_only_beta`：usage/cost 仅可视估算，ledger 不标 settled source-of-truth；DOC-PAID-01 后该模式降为 fallback/safe mode，不再代表最终 paid 决策。
- S114 新增 paid readiness refusal gate：`scripts/verify_billing_beta_mode_readiness.ps1` 默认不联网、不连 DB、不输出 secrets；`-BillingMode usage_only_beta` exit 0；`-BillingMode paid_controlled_beta` 在证据缺失时输出 JSON blocker 并 exit 2。
- S115 已把 gate 接入 release/checklist：`scripts/release_check.ps1 -Checks billing` 默认离线运行 usage-only pass + paid expected-refusal probe；`scripts/test.ps1 -BillingBetaModeReadinessOnly` 提供局部 QA 快捷入口。
- S116 / ToD-06A 已新增 Billing strong consistency evidence bundle contract：`crates/billing-ledger/src/paid_evidence_bundle.rs`、`tests/fixtures/billing/paid_evidence_bundle.*.json`、`scripts/verify_billing_paid_evidence_bundle.ps1`。该 contract 只证明 paid evidence bundle 的机器可校验形状，不等同 TODO-30 Gateway hot path 已完成。
- S117R 已把 S116 bundle 作为可选输入接入 readiness gate：`scripts/verify_billing_beta_mode_readiness.ps1 -BillingMode paid_controlled_beta -PaidEvidenceBundlePath <bundle>`。gate 现在明确输出三态：`usage_only_beta` fallback pass、`paid_controlled_beta_requested` blocked、`paid_controlled_beta_allowed` only when real production bundle passes。accepted contract-shape fixture 会识别七项 evidence present，但因 `contract_shape_only=true` / `paid_controlled_beta_production_ready=false` 继续 JSON `actual_exit_code=2` blocked。
- S118 已新增 E9-side real paid evidence bundle composer：`scripts/compose_billing_paid_evidence_bundle.ps1 -GatewayPaidHotPathArtifactPath <e8-artifact> -ControlPlanePaidReadbackArtifactPath <e11-artifact> -OutputBundlePath <bundle>`。普通模式只接受 repo-bounded `.tmp/**` 或 `artifacts/**` 输入/输出；缺 E8/E11 artifact 时 JSON blocked exit 2 且不写 production-ready bundle。`-SelfTest` 使用 synthetic fixture 产出 `.tmp/billing-ledger/composer-selftest/paid-evidence-bundle.synthetic.json`，仅证明 composer shape，不是 release artifact，readiness gate 仍 blocked。
- S119 已新增 paid readiness default artifact writer：`scripts/verify_billing_beta_mode_readiness.ps1 -BillingMode paid_controlled_beta -OutputPath .tmp/paid-beta/e9_paid_readiness_gate.json`。即使 readiness blocked，脚本仍写同一份 secret-safe JSON artifact；当前 artifact `paid_controlled_beta_requested=true`、`paid_controlled_beta_allowed=false`、JSON `actual_exit_code=2`、missing seven evidence plus `paid_evidence_bundle_missing`。QA aggregator 默认路径现在可读 E9 gate as blocked，而不是 missing；这不放行 paid。
- S120 consume attempt：检查 `.tmp/paid-beta/e8_gateway_paid_hot_path.json=false`、`.tmp/paid-beta/e11_control_plane_paid_readback_reconciliation.json=true`。E11 artifact 当前仍 `overall_status=blocked` / `actual_exit_code=2`，blocker=`gateway_paid_hot_path_artifact_missing`；composer 因 E8 default artifact missing JSON blocked exit 2，未写 `.tmp/paid-beta/real_paid_evidence_bundle.json`。E9 readiness artifact 已刷新为 blocked，paid 仍 `paid_controlled_beta_allowed=false`。
- S122 固化 E9 composer input shape contract：`tests/fixtures/billing/paid_evidence_composer.required_shape_contract.json` 记录 E8/E11 artifacts 到七项 bundle evidence 的最低 mapping；`tests/fixtures/billing/paid_evidence_composer.gateway_passed_missing_required_shape.json` 覆盖 `status=passed` 但缺 `evidence[]`/request-operation evidence mapping 的 E8 输入。Composer selftest 现在要求这类输入 blocked with `gateway_paid_hot_path_evidence_mapping_missing` and `gateway_paid_hot_path_request_or_operation_ids_missing`，避免生成 all-missing incomplete bundle。当前 E8 artifact 已包含 gateway `evidence[]` mapping；当前 blocker 转为 E11 readback artifact 缺 composer-required evidence mapping / SQL readback unavailable，composer blocked and removes stale real bundle output.
- S123 已消费 E11 refreshed mapping shape without opening paid：composer 接受 E11 `readiness_evidence`/`accepted_evidence` mapping 和 `gateway_artifact.request_ids_present`/`operation_ids_present` handoff；当 E11 shape present 但 SQL/readback blocked 时，不再输出 `control_plane_paid_readback_evidence_mapping_missing` / `control_plane_paid_readback_request_or_operation_ids_missing`，而是精确 blocked with `control_plane_paid_readback_not_passed` + `control_plane_paid_readback_sql_unavailable`。当前 real composer 未写 `.tmp/paid-beta/real_paid_evidence_bundle.json`；readiness artifact `.tmp/paid-beta/e9_paid_readiness_gate.json` 仍 `paid_controlled_beta_allowed=false`；QA paid acceptance 仍 blocked。
- S124 wait check：E11 SQL runtime fix 尚未在 `.tmp/paid-beta/e11_control_plane_paid_readback_reconciliation.json` 落成，artifact 仍 `overall_status=blocked` / `actual_exit_code=2` / blocker `control_plane_paid_readback_sql_unavailable`。E9 reran composer/readiness/QA only：composer JSON `actual_exit_code=2` with `control_plane_paid_readback_not_passed` + `control_plane_paid_readback_sql_unavailable`，未写 `.tmp/paid-beta/real_paid_evidence_bundle.json`；readiness artifact remains `paid_controlled_beta_allowed=false`；QA paid acceptance remains blocked。No Gateway/E11/QA implementation changes and no E9 consumer code change required.
- S125 non-no-op branch：E11-S7 artifact blocker changed to `control_plane_paid_readback_refund_rows_missing` with SQL diagnostics present and `counts.refund_count=0`。E9 reran composer/readiness/QA：composer JSON `actual_exit_code=2` with precise blockers `control_plane_paid_readback_not_passed` + `control_plane_paid_readback_refund_rows_missing`，未写 `.tmp/paid-beta/real_paid_evidence_bundle.json`；readiness artifact remains `paid_controlled_beta_allowed=false`；QA paid acceptance remains blocked。No Gateway/E11/QA implementation changes and no E9 consumer code change required.
- S128 fixed E9 composer to include passed Gateway evidence from E8-S6 artifact：`Get-ReadinessEvidenceMap` no longer lets top-level same-name object fields overwrite passed `evidence[]` entries; bundle evidence now preserves operation/source/scenario/refund tracking fields. Real composer writes `.tmp/paid-beta/real_paid_evidence_bundle.json` with all seven evidence keys and production-ready metadata `overall_status=accepted_contract_shape`、`accepted_contract_shape=true`、`real_paid_evidence_bundle_accepted=true`、`real_provenance=true`、`non_synthetic=true` only when real inputs pass. `verify_billing_paid_evidence_bundle.ps1` exit 0; `verify_billing_beta_mode_readiness.ps1 -BillingMode paid_controlled_beta -PaidEvidenceBundlePath .tmp/paid-beta/real_paid_evidence_bundle.json -OutputPath .tmp/paid-beta/e9_paid_readiness_gate.json` exit 0 and writes `paid_controlled_beta_allowed=true`。QA paid acceptance smoke still JSON `actual_exit_code=2`: E9 readiness and real bundle pass, but aggregator still blocks E8/E11 artifacts as `artifact_reported_passed` and keeps release aggregate false; no Gateway/E11/QA implementation changed.
- TODO-30C / E11 Control Plane paid readback verifier 已新增：`scripts/verify_control_plane_paid_ledger_readback.ps1`、`scripts/operator/control_plane_paid_ledger_reconciliation_readback.sql`、`tests/fixtures/billing/control_plane_paid_*`。`-SelfTest` 通过 accepted-shape/missing gateway artifact/raw secret/mismatched operation id/refund idempotency refusal；默认无 Gateway TODO-30B artifact 时输出 `gateway_paid_hot_path_artifact_missing` 并 blocked exit 2。该 verifier 只提供 Control Plane/Admin API/SQL readback evidence mapping，不声明 paid 已开放。
- TODO-30C-S2 已收束 exit/readback evidence：paid verifier JSON 输出 `actual_exit_code`、`expected_shell_exit_code` 和 `exit_code_contract`；blocked JSON 为 `actual_exit_code=2`，普通 `cmd /v:on` shell 验证 `%ERRORLEVEL%=2`，若某 runner UI 把非零归一为 1，QA 以 JSON 为准。E11 release readback artifact 已真实刷新并恢复 pass：`scripts/test.ps1 -ControlPlaneLedgerAdjustmentExecuteBrowserReadbackOnly` exit 0；stale gate 未放宽，若后续过期会写 bounded stale blocker report 和再生命令。
- TODO-30C-S3 已新增 E11 paid readback output handoff：`scripts/verify_control_plane_paid_ledger_readback.ps1 -OutputPath <path>`，默认写 `.tmp/paid-beta/e11_control_plane_paid_readback_reconciliation.json`；output path 必须 repo-bounded 且位于 `.tmp/**` 或 `artifacts/**`。缺 Gateway artifact 时也写 blocked artifact，`actual_exit_code=2`、`blockers=[gateway_paid_hot_path_artifact_missing]`、`paid_controlled_beta_opened_by_this_check=false`，供 Sagan aggregator / Harvey composer 读取。
- TODO-30C-S4 已将 E11 默认 Gateway artifact 输入切到 `.tmp/paid-beta/e8_gateway_paid_hot_path.json`。当前该 artifact 存在且 status/schema 读到 passed-looking shape，但缺 E11 SQL/readback 所需 request_id/operation_id evidence items；E11 output `.tmp/paid-beta/e11_control_plane_paid_readback_reconciliation.json` 因 `gateway_paid_hot_path_request_or_operation_ids_missing` blocked，`actual_exit_code=2`，未写 raw Gateway artifact，paid 仍未开放。
- TODO-30C-S5 已新增 required Gateway artifact shape contract：`tests/fixtures/billing/control_plane_paid_gateway_hot_path_artifact.required_shape.json`。E11 verifier selftest 现在覆盖 required-shape accepted-for-input-parsing，以及 missing request ids / missing operation ids / missing evidence mapping 三类机器码 refusal。当前 E8 artifact 已更新到可解析 evidence shape，E11 output 改为 SQL/readback blocker `control_plane_paid_readback_sql_unavailable`，仍 `actual_exit_code=2`，未开放 paid。
- TODO-30C-S6 已让 E11 output artifact 写出 composer-required top-level `evidence[]` mapping：`post_commit_readback`、`rollback_proof`、`reconciliation_report` 均包含 `evidence_key`、`status`/`passed`、`evidence_id`、request/operation id 和来源标记。当前 SQL/readback 仍 unavailable，因此 E11 artifact 仍 `overall_status=blocked` / JSON `actual_exit_code=2` / `paid_controlled_beta_opened_by_this_check=false`，但 Harvey composer blocker 已从 `control_plane_paid_readback_evidence_mapping_missing` 转为 `control_plane_paid_readback_not_passed` + `control_plane_paid_readback_sql_unavailable`。
- TODO-30C-S7 已收敛 Control Plane SQL runtime readback：generic `control_plane_paid_readback_sql_unavailable` 根因为容器内 `psql -f` 无法读取宿主机 SQL file；verifier 改为 stdin 执行 repo-bounded SQL，并输出 secret-safe `diagnostics`。当前 compose Postgres/database/tables 均可读，row counts 为 ledger `3`、request_logs `3`、provider_attempts `2`、reserve `2`、settle `1`、refund `0`、reversed `2`、insufficient provider attempts `0`。E11 artifact 仍 blocked，但 blocker 精确为 `control_plane_paid_readback_refund_rows_missing`；composer blocker 同步为 `control_plane_paid_readback_not_passed` + `control_plane_paid_readback_refund_rows_missing`。paid 仍未开放。
- TODO-30C-S8 consume attempt：当前 `.tmp/paid-beta/e8_gateway_paid_hot_path.json` 仍是 `e8-paid-1780689186388`，七项 evidence/request ids/operation ids shape 存在但 SQL readback `refund_count=0`。E11 output `.tmp/paid-beta/e11_control_plane_paid_readback_reconciliation.json` 继续 `overall_status=blocked` / `actual_exit_code=2` / blocker `control_plane_paid_readback_refund_rows_missing`，post-commit/rollback/reconciliation 三项 Control Plane evidence pass；composer 继续 blocked by `control_plane_paid_readback_not_passed` + `control_plane_paid_readback_refund_rows_missing`，未写 real paid bundle。paid 仍未开放。
- TODO-30C-S10 pass handoff：E8-S6 refund-after-settle artifact 已刷新，E11 verifier 复跑 `.tmp/paid-beta/e11_control_plane_paid_readback_reconciliation.json` 为 `overall_status=passed` / `actual_exit_code=0` / blockers empty。Counts：ledger `3`、request_logs `2`、provider_attempts `1`、reserve `1`、settle `1`、refund `1`、reversed `1`、insufficient provider attempts `0`；Control Plane `post_commit_readback`、`rollback_proof`、`reconciliation_report` evidence 均 pass；artifact secret-safe 且 `paid_controlled_beta_opened_by_this_check=false`。E11 lane pass handoff ready for E9/QA, but paid overall still waits for E9 real bundle/readiness and QA acceptance.
- Gate contract：`tests/fixtures/billing/billing_beta_mode_readiness_contract.json`，Rust evaluator：`crates/billing-ledger/src/beta_mode.rs`。
- DOC-PAID-01 historical guardrail established the `paid_controlled_beta_requested` / evidence-required track. DOC-PAID-16 supersedes the current status after main review accepted controlled paid beta evidence and set `paid_controlled_beta_allowed=true` for the accepted artifact set.
- DOC-PAID-02 新增 operator/devrel runbook：`docs/PAID_BETA_RUNBOOK.md`。该文档固定三态、paid allowed 前硬门槛、禁止发布/对外承诺清单，以及 E9/E8/E11/QA 验证命令占位。
- DOC-PAID-03/04/05/06/08/09/10/11/13 paid evidence index/manifest watcher：`docs/PAID_BETA_EVIDENCE_INDEX.md` 和 `project/paid_beta_evidence_index.json` 列出 E8 Gateway paid hot path、E11 Control Plane paid readback/reconciliation、E9 real paid evidence bundle、E9 paid readiness gate JSON、QA paid acceptance aggregator、secret scan、full TODO-20 summary 的 owner、expected path、schema、pass markers、blocked markers、release-artifact status。
- DOC-PAID-16 main review acceptance：controlled paid beta evidence 已被主线程最终复核接受；`project/paid_beta_evidence_index.json` 当前为 `paid_controlled_beta_allowed=true` / `controlled_paid_beta_evidence_accepted_by_main_review`。Accepted artifacts: `.tmp/paid-beta/e8_gateway_paid_hot_path.json`, `.tmp/paid-beta/e11_control_plane_paid_readback_reconciliation.json`, `.tmp/paid-beta/real_paid_evidence_bundle.json`, `.tmp/paid-beta/e9_paid_readiness_gate.json`, `artifacts/beta_acceptance_paid_aggregator_20260605_main_final_review.json`。这不是 full Production RC；bounded smoke refund endpoint 是 dev evidence only，partial refund policy 与 deeper reconciliation 仍是 RC work。

### DOC-CREDIT-01：Credit / Balance Productization Gap

Docx product target covers Wallet, Credit Grant, Budget, Subscription, Recharge/Voucher, New API balance import, and ledger truth. This matrix does not roll back `paid_controlled_beta_allowed=true`; it records the gap between accepted controlled paid beta evidence and the remaining productized credit/balance ecosystem.

| Capability | Docx priority | Current capability | Verdict | Backlog owner / next work |
|---|---|---|---|---|
| Wallet | P0 | Wallet/balance schema and controlled paid beta reserve/settle/refund evidence are present. | Done for controlled beta evidence; product UX incomplete. | E9/E11/Admin UI: wallet views, lifecycle operations, alerts, operator runbook. |
| Credit Grant | P0 | `credit_grants`/credit fixtures and ledger-backed bounded smoke evidence exist. | Schema + evidence done; CRUD/product UX missing. | E9/E11/Admin UI: grant create/list/expire/revoke, audit, policy, tests. |
| Budget | P0 | Insufficient-balance no-provider-call and paid preauth/reserve ordering are proven; TODO-31 remains open for broader hard limits. | Partial. | Routing/Security/Admin UI: day/month/total budgets, conservative deny, readback, alerts. |
| Subscription | P1 | E9 contract-only artifact `.tmp/credit-wallet/subscription_package_lifecycle_contract.json` is verified as `status=pass`, `runtime_implemented=false`, `contract_only=true`, `secret_safe=true`, and `paid_gate_changed=false`; E9-CREDIT-28 prepared the future runtime artifact contract for `.tmp/credit-wallet/subscription_package_lifecycle_runtime.json`; E9-CREDIT-30 prepared contract-only schema support for subscription plans/packages/subscriptions/events, but no runtime subscription/package lifecycle is proven. | deferred_runtime_external_dependency; contract/schema ready, runtime false. | Resume when Product/E11/QA provide durable schema migration, plan/package APIs, subscription lifecycle runtime, scheduler/provider/dunning integration, invoice/order linkage, entitlement enforcement, and a verified non-contract runtime artifact with accounting readbacks. |
| Recharge / Voucher | P1 | E9 contract-only artifact `.tmp/credit-wallet/recharge_voucher_contract.json` is verified as `status=pass`, `runtime_implemented=false`, `contract_only=true`, `secret_safe=true`, and `paid_gate_changed=false`; E9/E11 feasibility plans are prepared; E11 schema/OpenAPI boundary is present; no runtime/payment-provider flow is proven. | Contract-ready + feasibility/schema boundary prepared / runtime-payment-provider pending. | Product/E11/Security/QA: recharge/payment/voucher runtime, payment-provider handoff, voucher issue/redeem transaction, hash/redaction and abuse persistence, invoice linkage, reconciliation, and support runbook. |
| Payment / Order / Invoice | P1 | E9 contract-only artifact `.tmp/credit-wallet/payment_order_invoice_contract.json` is verified as `status=pass`, `runtime_implemented=false`, `contract_only=true`, `secret_safe=true`, and `paid_gate_changed=false`; 0013 schema boundary is present; runtime/provider/callback and invoice/reversal/reconciliation readbacks are not available. | deferred_runtime_external_dependency; contract/schema ready, runtime false. | Resume when Product/Finance/Ops approve provider/callback runtime or bounded internal policy and QA can verify `.tmp/credit-wallet/payment_order_invoice_runtime.json` with invoice/receipt, ledger/credit effect, refund/chargeback/reversal, idempotency/conflict, audit, reconciliation, money, secret-safe, and paid-gate-neutral readbacks. |
| New API balance import | P0/P1 | No accepted import/migration workflow from external New API balances. | Missing. | Data/E9/Release: dry-run import, idempotent migration, reconciliation, rollback, approval. |
| Ledger truth | P0 | Ledger entries, idempotency, readback, reconciliation, and secret-safe paid bundle are accepted for controlled beta. | Done for controlled beta evidence; RC deeper reconciliation remains. | E9/E11/QA: source-of-truth cutover, long-run reconciliation, partial refund policy, production audit. |

### E11-CREDIT-01 Admin Credit-Wallet Surface Audit（2026-06-05）

Admin/API audit verdict: wallet and credit grant schema are present, and Admin has ledger-centric billing surfaces (`/admin/ledger/entries`, `/admin/ledger/adjustments/dry-run` with execute mode, `/admin/billing/reconciliation`, `/admin/audit-logs`). This supports listing ledger entries, admin adjustment/refund execution, and audit readback for ledger adjustment/refund. It does not yet provide a productized wallet snapshot endpoint/view, credit grant CRUD/list/expire/revoke, or recharge/voucher/payment/order/invoice surfaces. Admin UI Billing / Prices exposes ledger overview, wallet_id filter/input, adjustment/refund dry-run/execute and reconciliation, but no dedicated wallet balance or credit-grant user-facing view.

Recommended next slice: `E11-CREDIT-02` read-only Admin wallet/credit surface: add OpenAPI/Admin contract for wallet list/detail with computed ledger balance, active/expired credit grants, last ledger entry, and audit/readback links. Follow with `E11-CREDIT-03` credit grant create/expire/revoke with transactional audit only after product policy is agreed. This audit does not roll back `paid_controlled_beta_allowed=true`; it records product surface gaps beyond accepted controlled paid beta evidence.

### E11-CREDIT-02 Read-only Admin Wallet-Credit Surface Contract（2026-06-05）

Contract status: OpenAPI skeleton now defines read-only `GET /admin/wallets` and `GET /admin/wallets/{wallet_id}`. These are contract-only Admin Ledger endpoints, not runtime implementation. Required response shape includes wallet metadata, active/consumed/expired/voided credit grant summary, bounded grant rows, ledger balance window, pending reserve summary, budget remaining marker, last ledger ids, bounded ledger/request/trace/audit links, consistency/staleness marker, and explicit secret-safe marker. Money fields are fixed-decimal strings. Links are public ids only. The contract explicitly forbids exposing raw metadata, raw request payloads, credential material, Authorization/Cookie headers, provider keys, virtual keys, DB URLs, operation keys, or raw Gateway artifacts.

Still not implemented by this slice: create/expire/void/revoke credit grants, recharge/voucher/payment/order/invoice flows, runtime Control Plane handlers, and Admin UI React views. Next implementation slice can be `E11-CREDIT-02B` for fixture/UI contract skeleton or `E11-CREDIT-02R` for read-only Control Plane runtime implementation. `E11-CREDIT-03` remains the mutation/audit policy slice for credit grant lifecycle.

### E11-CREDIT-02R / TODO-32A Admin Read-only Wallet-Credit Runtime（2026-06-05）

Runtime status: Control Plane Admin now registers read-only `GET /admin/wallets` and `GET /admin/wallets/{wallet_id}` handlers matching the E11-CREDIT-02 contract spirit. The implementation is select-only and returns wallet metadata, credit grant summary and bounded rows, ledger balance window, pending reserves, budget remaining marker, last ledger ids, bounded public-id ledger/request/trace/audit links, consistency/staleness marker, `secret_safe=true`, and `read_only=true`. Money is normalized through `FixedDecimal` string output. Secret-safe guardrails explicitly avoid raw metadata, raw request payloads, credentials, Authorization/Cookie headers, provider keys, virtual keys, DB URLs, operation keys, and Gateway artifacts.

Still not implemented by this runtime slice: credit grant create/expire/void/revoke, recharge/voucher/payment/order/invoice flows, Admin UI React views, and live QA endpoint readback artifact. Paid controlled beta evidence remains accepted and unchanged; this is credit productization surface work.

### E11-CREDIT-02R-live Admin Read-only Wallet-Credit Runtime Artifact（2026-06-05）

Artifact status: `.tmp/credit-wallet/admin_readonly_wallet_credit_runtime.json` now exists with schema `admin_readonly_wallet_credit_runtime.v1`, `overall_status=blocked`, `runtime_surface=true`, `read_only=true`, `secret_safe=true`, `money_decimal_strings=true`, `raw_secret_markers_present=false`, `paid_gate_changed=false`, `unit_verified=true`, and `live_verified=false`. This is intentionally not a live pass artifact: current local Control Plane health is reachable, but no Admin session/credential handoff is configured and `GET /admin/wallets` without a session returns `404`, so the artifact blocks on `admin_session_missing` plus `live_control_plane_wallet_route_not_current_or_unavailable`.

QA consumption: `scripts/verify_credit_wallet_ledger_surface.ps1` reads the artifact and classifies Admin runtime as `runtime_artifact_present_but_not_verified`; `admin_readonly_runtime_verified=false` remains correct until a valid Admin session and current Control Plane runtime can call both read-only endpoints and record bounded ids/counts. Paid controlled beta remains unchanged.

---

## TODO-14：Request / Trace / Usage 可解释性 Beta cut

**Owner**：Agent-OBS / Admin Observability  
**Priority**：P0 Beta blocker  
**状态**：部分完成：E13 explainability bridge ready；E8/E11/OBS/UI 仍未关闭  
**依赖**：E8/E11/E13 至少有可读 request ids。

### 目标

Beta 用户出问题时，管理员必须能回答三件事：

1. 为什么选这个 provider/channel/key？
2. 为什么失败/fallback/reject？
3. 花了多少 usage/cost，账务口径是什么？

### 写入范围

- `apps/control-plane/src/admin.rs` 中 request/trace 查询 API
- `web/admin-ui/src/components/RequestLogsPage.tsx`
- `web/admin-ui/src/components/HealthDashboard.tsx`
- `web/admin-ui/src/components/PromptProtectionSummary.tsx`
- `tests/fixtures/control-plane/request_log_detail_ledger_contract.json`
- `tests/fixtures/control-plane/trace_request_summary_contract.json`

### 必须展示字段

Request detail：

- `request_id`、`trace_id`、`tenant/project/key`。
- requested model、resolved canonical model、upstream model。
- provider/channel/provider_key fingerprint。
- route candidates、filter reasons、selected reason、fallback chain。
- usage input/output/cache/reasoning estimated marker。
- cost snapshot、ledger ids、price_version。
- error taxonomy：owner/stage/provider_status/retryable/support_hint。
- stream meta：partial_sent、first_byte_at、chunk_count、terminal_event、stream_end_reason。
- guardrail hits / audit log ids。

### Done 定义

- 至少用 E8/E11/E13 smoke 产生的 request ids 能在 Admin UI 找到并展示核心字段。
- payload lazy-load，不阻塞列表。
- metadata-only/redacted policy 下不展示明文 prompt。
- UI tests pass。

### TODO-14A / E13 Prompt Protection bridge result（2026-06-05）

- Verifier: `scripts/verify_request_trace_usage_explainability.ps1 -E13PromptProtectionOnly`.
- Source artifact: `.tmp/prompt_protection_beta_closure_report.json`.
- Bridge artifact: `.tmp/request_trace_usage_e13_bridge_report.json`.
- Fixture/contract: `tests/fixtures/request_trace_usage/e13_prompt_protection_explainability_bridge_contract.json`.
- Result: E13 subclosure ready. The bridge reads 4 E13 prompt-protection request ids, preserves endpoint/name mapping, expected prompt rejection fields, zero provider attempts, hash-only/redacted request-log expectations, runtime-owned/Admin API audit readback expectations, secret-safe omission flags, and usage/cost policy as metadata-only/no provider attempt.
- Optional live API readback: `.tmp/request_trace_usage_e13_bridge_live_readback.json` was blocked when no admin session handoff was configured; this does not close or fake live UI readback.
- Historical note: this 2026-06-05 bridge did not close TODO-14 by itself. It was superseded for current API distribution by TODO-14B live Admin/API metadata-only readback, which joined E8/E11/E13 request ids and passed.

### TODO-14B / Live Admin/API metadata-only readback result（2026-06-07）

- Verifier: `scripts/verify_request_trace_usage_explainability.ps1 -LiveApiReadback -OutputPath .tmp/launch/request_trace_usage_live_admin_api_readback.json`.
- Artifact: `.tmp/launch/request_trace_usage_live_admin_api_readback.json`.
- Result: `overall_status=pass`, `live_admin_readback_performed=true`, `request_id_count=11`, `trace_id_count=5`, `wallet_id_count=1`, `api_distribution_blocker=false`, `blocker_classification=none`.
- Surfaces read: `GET /admin/request-logs/{id}`, `GET /admin/traces/{trace_id}`, `GET /admin/ledger/entries?request_id=...`, `GET /admin/audit-logs?limit=500`, and `GET /billing/wallets/{wallet_id}/remaining-balance`.
- Secret-safety: the verifier does not call `/admin/request-logs/{id}/payload`; output records only bounded metadata, counts, ids, booleans, and status codes. It does not write session tokens, Authorization/Cookie headers, raw request/response bodies, provider secrets, or full virtual keys.
- Closure: TODO-14 is pass for the current trusted-user voucher-backed API distribution troubleshooting requirement. Remaining work is UI/browser polish and broader Production RC observability hardening, not a global API distribution blocker.

---

# PHASE 2：Full Local Gate 与 Beta 验收

## TODO-20：Full local gate 一键跑通

**Owner**：Agent-QA / Release Captain  
**Priority**：P0 Beta blocker  
**状态**：Paid-requested preflight blocked（TODO-20B-R，不是 TODO-20 pass）  
**依赖**：TODO-10/11/12 至少 pass；TODO-13 已选择 billing mode。

### 必跑命令

```powershell
# Rust / adapter / smoke / frontend / security 综合门禁
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1

# Compose smoke
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_compose_smoke.ps1

# SDK smoke
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_sdk_smoke.ps1

# Secret scan
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/scan_secrets.ps1

# Supply chain
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/scan_supply_chain.ps1
```

Linux runner 可用 `pwsh` 同样执行。没有 `pwsh` 的环境不能作为最终验收环境。

### 必须覆盖的 smoke matrix

| 场景 | 命令/证据 | Pass 标准 |
|---|---|---|
| OpenAI Chat non-stream | Gateway SDK smoke | 200，request log 可查 |
| OpenAI Chat stream | streaming smoke | terminal event + usage reconcile |
| Responses stream | responses fixture | completed/done 语义保留 |
| Anthropic Messages | adapter fixture | message_stop / content_block 正确 |
| Gemini GenerateContent | native/hybrid fixture | candidates/parts 不丢 |
| `/v1/models` | profile smoke | 按 key/profile 返回可见模型 |
| Retry/Fallback | retry smoke | first byte 前 fallback，partial 后不 fallback |
| Rate limit | E8 live smoke | acquire/readback pass |
| Prompt protection | E13 live report | 4 endpoint reject, no provider_attempts |
| Billing mutation | E11 browser artifact | mutation/readback pass |
| Ledger | E9 mode-specific | usage-only badge 或 paid writer commit pass |
| Migration dry-run | import script | 报告成功/失败/人工确认项 |
| Backup/restore preflight | db scripts | dry-run/preflight pass |

### Done 定义

- 所有 P0 Beta blocker pass 或被明确降级为 non-blocking。
- `project/ACCEPTANCE_CHECKLIST.md` 更新。
- `project/RELEASE_CHECKLIST.md` 有 Beta 条目。
- 生成 `artifacts/beta_acceptance_summary_<run_id>.json`，不含 secret。

### TODO-20A Full Local Gate Preflight（2026-06-05）

本节只记录 preflight 派生结果，不关闭 TODO-20，不生成 Beta pass summary。完整 TODO-20 仍依赖 TODO-10/TODO-11/TODO-12 pass；TODO-13 当前口径为 `paid_controlled_beta_requested` / `blocked_until_real_evidence`，`usage_only_beta` 仅作 fallback/safe mode。

```json
{
  "task_id": "TODO-20A",
  "parent_task_id": "TODO-20",
  "lane": "QA",
  "status": "blocked_until_beta_blockers_pass",
  "commit": "8e3318d",
  "preflight_only": true,
  "pass": false,
  "changed_files": [
    "project/RELEASE_CHECKLIST.md",
    "project/ACCEPTANCE_CHECKLIST.md",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md",
    "TODO/AGENT_COORDINATION_2026-06-05.md",
    "artifacts/beta_acceptance_preflight_20260605_qa_preflight.json"
  ],
  "commands_run": [
    {"command": "git rev-parse --short HEAD", "exit_code": 0, "classification": "pass"},
    {"command": "git status --short", "exit_code": 0, "classification": "pass"},
    {"command": "git diff --check", "exit_code": 0, "classification": "warn_crlf_only"},
    {"command": "Test-Path scripts/test.ps1", "exit_code": 0, "classification": "present"},
    {"command": "Test-Path scripts/verify_compose_smoke.ps1", "exit_code": 0, "classification": "present"},
    {"command": "Test-Path scripts/verify_sdk_smoke.ps1", "exit_code": 0, "classification": "present"},
    {"command": "Test-Path scripts/scan_secrets.ps1", "exit_code": 0, "classification": "present"},
    {"command": "Test-Path scripts/scan_supply_chain.ps1", "exit_code": 0, "classification": "present"},
    {"command": "Test-Path web/admin-ui/package-lock.json", "exit_code": 0, "classification": "present"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_compose_smoke.ps1 -DryRun", "exit_code": 0, "classification": "preflight_pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_sdk_smoke.ps1 -DryRun", "exit_code": 0, "classification": "preflight_pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1 -GatewayRateLimitReservationSmokeOnly", "exit_code": 1, "classification": "preflight_fail"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1 -ControlPlaneLedgerAdjustmentExecuteSmokeOnly", "exit_code": 0, "classification": "contract_preflight_pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1 -PromptProtectionPostgresProofOnly", "exit_code": 0, "classification": "contract_preflight_pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/scan_secrets.ps1", "exit_code": 0, "classification": "pass_after_misc_security_s1"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -SelfTest", "exit_code": 0, "classification": "pass_after_misc_security_s1"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/scan_supply_chain.ps1 -SkipNetwork", "exit_code": 0, "classification": "preflight_pass_with_warnings"}
  ],
  "artifacts_written": [
    {"path": "artifacts/beta_acceptance_preflight_20260605_qa_preflight.json", "schema": "beta_acceptance_preflight_v1", "secret_safe": true, "fresh": true, "simulation": false}
  ],
  "acceptance_results": {
    "script_availability": "pass",
    "compose_dry_run": "pass",
    "sdk_dry_run": "pass",
    "e8_wrapper_dry_run": "fail_forbidden_marker_request_body",
    "e11_contract_preflight": "pass",
    "e13_contract_preflight": "pass",
    "secret_scan": "pass_after_misc_security_s1",
    "supply_chain_skip_network": "pass_with_warnings",
    "admin_ui_lockfile_present": true,
    "full_scripts_test_run": false,
    "beta_acceptance_summary_generated": false
  },
  "blockers": [
    "TODO-10/TODO-11/TODO-12 are not all pass.",
    "E8 wrapper dry-run failed: rate-limit performance evidence leaked forbidden marker request_body.",
    "Full scripts/test.ps1 has no global dry-run and was not run in preflight."
  ],
  "next_task": "Owning agents close TODO-10/TODO-11/TODO-12, then Agent-QA reruns full TODO-20 gate and generates beta_acceptance_summary_<run_id>.json only on pass."
}
```

### MISC-Security-S1 Secret Scan Selftest Marker Remediation（2026-06-05）

```json
{
  "task_id": "MISC-Security-S1",
  "parent_task_id": "TODO-20A",
  "lane": "QA/Security",
  "status": "pass",
  "commit": "8e3318d",
  "changed_files": [
    "scripts/verify_control_plane_ledger_adjustment_openapi_semantic.ps1",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md",
    "TODO/AGENT_COORDINATION_2026-06-05.md"
  ],
  "commands_run": [
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/scan_secrets.ps1", "exit_code": 0, "classification": "pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -SelfTest", "exit_code": 0, "classification": "pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -SimulateSensitiveOutputTail", "exit_code": 0, "classification": "redacted_output_pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -SimulateSensitiveCommandFailure", "exit_code": 1, "classification": "expected_sensitive_failure_redacted"},
    {"command": "git diff --check -- scripts/verify_control_plane_ledger_adjustment_openapi_semantic.ps1 scripts/scan_secrets.ps1 docs/P0_BETA_STATUS.md TODO/AGENT_COORDINATION_2026-06-05.md TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md", "exit_code": 0, "classification": "warn_crlf_only"}
  ],
  "artifacts_written": [],
  "acceptance_results": {
    "secret_scan": "pass",
    "scanner_rules_relaxed": false,
    "selftest_marker_static_bearer_literal_removed": true,
    "semantic_wrapper_selftest": "pass",
    "secret_echo_rejection_semantics_preserved": true
  },
  "blockers": [],
  "next_task": "TODO-20 remains blocked on E8/TODO-10/TODO-11/TODO-12 full closure; rerun full QA gate after owning lanes pass."
}
```

### TODO-20B Beta Acceptance Delta Preflight Refresh（2026-06-05）

本节刷新 TODO-20 preflight 状态，不关闭 TODO-20，不生成 Beta acceptance pass summary。

```json
{
  "task_id": "TODO-20B",
  "parent_task_id": "TODO-20",
  "lane": "QA/Security",
  "status": "blocked",
  "commit": "8e3318d",
  "not_final_beta_acceptance": true,
  "changed_files": [
    "artifacts/beta_acceptance_preflight_20260605_delta_refresh.json",
    "project/RELEASE_CHECKLIST.md",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md",
    "TODO/AGENT_COORDINATION_2026-06-05.md"
  ],
  "commands_run": [
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/scan_secrets.ps1", "exit_code": 0, "classification": "pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/release_check.ps1 -Checks billing", "exit_code": 0, "classification": "pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_prompt_protection_postgres_proof.ps1 -ContractOnly", "exit_code": 0, "classification": "pass"},
    {"command": "read .tmp/prompt_protection_beta_closure_review_report.json", "exit_code": 0, "classification": "pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1 -ArtifactReadbackOnly", "exit_code": 0, "classification": "pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1 -GatewayRateLimitReservationSmokeOnly", "exit_code": 0, "classification": "preflight_pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1 -GatewayRateLimitReservationSmokeOnly -GatewayRateLimitReservationSmokePreflight", "exit_code": 0, "classification": "preflight_pass"}
  ],
  "artifacts_written": [
    {"path": "artifacts/beta_acceptance_preflight_20260605_delta_refresh.json", "schema": "beta_acceptance_delta_preflight_v1", "secret_safe": true, "fresh": true, "simulation": false}
  ],
  "acceptance_results": {
    "overall_status": "blocked",
    "secret_scan_status": "pass",
    "billing_gate_status": "pass_usage_only_beta_paid_refusal_integrated",
    "e13_status": "pass_contract_and_accepted_artifact_readback",
    "e11_status": "pass_release_artifact_readback",
    "e8_status": "preflight_pass_live_closure_pending",
    "not_final_beta_acceptance": true
  },
  "blockers": [
    "TODO-12/E8 still needs owner-reviewed live Gateway rate-limit reservation acquire/release/readback closure.",
    "Full TODO-20 wrapper/runtime/Admin UI gate and beta_acceptance_summary_<run_id>.json were not run/generated in this preflight refresh."
  ],
  "next_task": "E8 owner closes TODO-12 live evidence; then Agent-QA runs full TODO-20 gate and generates final beta_acceptance_summary only on pass."
}
```

### TODO-20B-R Paid Requested Beta Acceptance Preflight Refresh（2026-06-05）

用户已明确允许开启 paid；本节刷新 QA/release 状态，但不关闭 TODO-20，也不允许 paid，直到真实 paid evidence 全部通过。

```json
{
  "task_id": "TODO-20B-R",
  "parent_task_id": "TODO-20",
  "lane": "QA/Security",
  "status": "blocked",
  "commit": "8e3318d",
  "not_final_beta_acceptance": true,
  "paid_requested_by_user": true,
  "paid_controlled_beta_requested": true,
  "paid_controlled_beta_allowed": false,
  "changed_files": [
    "artifacts/beta_acceptance_preflight_20260605_paid_requested_refresh.json",
    "project/RELEASE_CHECKLIST.md",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md",
    "TODO/AGENT_COORDINATION_2026-06-05.md"
  ],
  "commands_run": [
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/scan_secrets.ps1", "exit_code": 0, "classification": "pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/release_check.ps1 -Checks billing", "exit_code": 0, "classification": "pass_for_paid_refusal_until_real_evidence"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_prompt_protection_postgres_proof.ps1 -ContractOnly", "exit_code": 0, "classification": "pass"},
    {"command": "read .tmp/prompt_protection_beta_closure_review_report.json", "exit_code": 0, "classification": "pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1 -ArtifactReadbackOnly", "exit_code": 0, "classification": "pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1 -GatewayRateLimitReservationSmokeOnly -GatewayRateLimitReservationSmokePreflight", "exit_code": 0, "classification": "preflight_pass"}
  ],
  "artifacts_written": [
    {"path": "artifacts/beta_acceptance_preflight_20260605_paid_requested_refresh.json", "schema": "beta_acceptance_paid_requested_preflight_v1", "secret_safe": true, "fresh": true, "simulation": false}
  ],
  "acceptance_results": {
    "overall_status": "blocked",
    "secret_scan_status": "pass",
    "billing_gate_status": "pass_for_usage_only_and_paid_refusal_until_real_evidence",
    "paid_requested_by_user": true,
    "paid_controlled_beta_requested": true,
    "paid_controlled_beta_allowed": false,
    "e13_status": "pass_contract_and_accepted_artifact_readback",
    "e11_status": "pass_release_artifact_readback",
    "e8_status": "preflight_pass_live_or_paid_hot_path_evidence_pending",
    "not_final_beta_acceptance": true
  },
  "blockers": [
    "Gateway paid hot path reserve/settle/refund.",
    "Insufficient-balance no-provider-call.",
    "Control Plane paid readback/reconciliation.",
    "Real paid evidence bundle accepted.",
    "Release gate paid allowed.",
    "Full TODO-20 wrapper/runtime/Admin UI gate and beta_acceptance_summary_<run_id>.json were not run/generated in this preflight refresh."
  ],
  "next_task": "E9/Gateway/Control Plane owners produce real paid evidence; then QA reruns paid release gate and full TODO-20."
}
```

### QA-PAID-02 Paid Beta Acceptance Aggregator and Stale-Copy Guard（2026-06-05）

本节为 TODO-20/TODO-30 的 QA 聚合入口和文案守卫，不关闭 TODO-20，不允许 paid；当前 paid 仍 `blocked_until_real_evidence`。

```json
{
  "task_id": "QA-PAID-02",
  "parent_task_id": "TODO-20",
  "lane": "QA/Security",
  "status": "blocked_expected",
  "commit": "8e3318d",
  "paid_controlled_beta_requested": true,
  "paid_controlled_beta_allowed": false,
  "not_final_if_blocked": true,
  "changed_files": [
    "scripts/verify_paid_beta_acceptance.ps1",
    "scripts/verify_paid_beta_status_copy_guard.ps1",
    "scripts/release_check.ps1",
    "project/RELEASE_CHECKLIST.md",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md",
    "TODO/AGENT_COORDINATION_2026-06-05.md"
  ],
  "commands_run": [
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_acceptance.ps1", "exit_code": 2, "classification": "blocked_expected"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_status_copy_guard.ps1", "exit_code": 0, "classification": "pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/scan_secrets.ps1", "exit_code": 0, "classification": "pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/release_check.ps1 -Checks billing", "exit_code": 0, "classification": "pass_for_paid_refusal_until_real_evidence"}
  ],
  "artifacts_written": [
    {"path": "artifacts/beta_acceptance_paid_aggregator_20260605_qapaid02.json", "schema": "paid_beta_acceptance_aggregator_v1", "secret_safe": true, "fresh": true, "simulation": false}
  ],
  "acceptance_results": {
    "aggregator_status": "blocked",
    "copy_guard_status": "pass",
    "secret_scan_status": "pass",
    "billing_gate_status": "pass_for_fallback_usage_only_and_paid_refusal_until_real_evidence"
  },
  "blockers": [
    "E9 paid readiness gate JSON missing or not passed.",
    "Gateway paid hot path reserve/settle/refund artifact missing or not passed.",
    "Insufficient-balance no-provider-call evidence missing or not passed.",
    "Control Plane paid readback/reconciliation artifact missing or not passed.",
    "Real paid evidence bundle accepted artifact missing or not passed.",
    "Release gate paid allowed remains blocked until all real paid evidence inputs pass."
  ],
  "next_task": "E9/Gateway/Control Plane owners produce real paid evidence artifacts, then QA reruns scripts/verify_paid_beta_acceptance.ps1 and full TODO-20."
}
```

### QA-PAID-03 Parameterized Paid Aggregator + Exit Semantics Alignment（2026-06-05）

本节为 TODO-20/TODO-30 的 QA aggregator hardening，不关闭 TODO-20，不允许 paid；当前 paid 仍 `blocked_until_real_evidence`。

```json
{
  "task_id": "QA-PAID-03",
  "parent_task_id": "TODO-20",
  "lane": "QA/Security",
  "status": "blocked_expected",
  "commit": "8e3318d",
  "paid_controlled_beta_requested": true,
  "paid_controlled_beta_allowed": false,
  "changed_files": [
    "scripts/verify_paid_beta_acceptance.ps1",
    "project/RELEASE_CHECKLIST.md",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md",
    "TODO/AGENT_COORDINATION_2026-06-05.md"
  ],
  "commands_run": [
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_acceptance.ps1", "exit_code": 2, "classification": "blocked_expected"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_acceptance.ps1 -E9ReadinessPath ..\\unsafe.json -SkipSecretScan", "exit_code": 1, "classification": "unsafe_path_refused"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_acceptance.ps1 -SelfTest", "exit_code": 0, "classification": "pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_status_copy_guard.ps1", "exit_code": 0, "classification": "pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/scan_secrets.ps1", "exit_code": 0, "classification": "pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/release_check.ps1 -Checks billing", "exit_code": 0, "classification": "pass_for_paid_refusal_until_real_evidence"}
  ],
  "artifacts_written": [
    {"path": "artifacts/beta_acceptance_paid_aggregator_20260605_qapaid03.json", "schema": "paid_beta_acceptance_aggregator_v2", "secret_safe": true, "fresh": true, "simulation": false}
  ],
  "acceptance_results": {
    "aggregator_parameters": [
      "-E9ReadinessPath",
      "-GatewayPaidHotPathArtifactPath",
      "-ControlPlanePaidReadbackArtifactPath",
      "-RealPaidEvidenceBundlePath",
      "-OutputPath"
    ],
    "default_paths_preserved": true,
    "repo_bounded_paths": ".tmp/** or artifacts/** only",
    "exit_code_contract": {"pass": 0, "unsafe_or_tool_failure": 1, "blocked_until_real_evidence": 2},
    "default_status": "blocked",
    "default_actual_exit_code": 2,
    "selftest_status": "pass",
    "copy_guard_status": "pass"
  },
  "blockers": [
    "E9 paid readiness gate JSON missing or not passed.",
    "Gateway paid hot path reserve/settle/refund artifact missing or not passed.",
    "Insufficient-balance no-provider-call evidence missing or not passed.",
    "Control Plane paid readback/reconciliation artifact missing or not passed.",
    "Real paid evidence bundle accepted artifact missing or not passed.",
    "Release gate paid allowed remains blocked until all real paid evidence inputs pass."
  ],
  "next_task": "E9/Gateway/Control Plane owners produce bounded real paid evidence artifacts, then QA reruns parameterized aggregator and full TODO-20."
}
```

### QA-PAID-05 Post-E8 Paid Aggregator Rerun Handoff（2026-06-05）

本节为等待 E8 paid hot path artifact 的 QA handoff rerun，不关闭 TODO-20，不允许 paid；当前 paid 仍 `blocked_until_real_evidence`。

```json
{
  "task_id": "QA-PAID-05",
  "parent_task_id": "TODO-20",
  "lane": "QA/Security",
  "status": "waiting_for_e8_gateway_paid_hot_path",
  "commit": "8e3318d",
  "paid_controlled_beta_requested": true,
  "paid_controlled_beta_allowed": false,
  "changed_files": [
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "commands_run": [
    {"command": "Test-Path .tmp/paid-beta/e8_gateway_paid_hot_path.json", "exit_code": 0, "classification": "missing_false"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_acceptance.ps1 -OutputPath artifacts/beta_acceptance_paid_aggregator_20260605_qapaid05_post_e8_handoff.json", "exit_code": 2, "classification": "blocked_expected"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_status_copy_guard.ps1", "exit_code": 0, "classification": "pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/scan_secrets.ps1", "exit_code": 0, "classification": "pass"},
    {"command": "git diff --check -- docs/P0_BETA_STATUS.md TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md", "exit_code": 0, "classification": "pass"}
  ],
  "artifacts_written": [
    {"path": "artifacts/beta_acceptance_paid_aggregator_20260605_qapaid05_post_e8_handoff.json", "schema": "paid_beta_acceptance_aggregator_v2", "secret_safe": true, "fresh": true, "simulation": false}
  ],
  "acceptance_results": {
    "e8_gateway_paid_hot_path_artifact": "missing",
    "e11_status": "blocked_gateway_paid_hot_path_artifact_missing",
    "e9_status": "blocked_paid_controlled_beta_refused_missing_evidence",
    "real_paid_evidence_bundle": "missing",
    "overall_status": "blocked",
    "actual_exit_code": 2
  },
  "blockers": [
    ".tmp/paid-beta/e8_gateway_paid_hot_path.json missing.",
    "E11 readback artifact blocked on gateway_paid_hot_path_artifact_missing.",
    "E9 readiness artifact blocked on paid_controlled_beta_refused_missing_evidence.",
    ".tmp/paid-beta/real_paid_evidence_bundle.json missing.",
    "Release gate paid allowed remains blocked until all real paid evidence inputs pass."
  ],
  "next_task": "E8 owner produces .tmp/paid-beta/e8_gateway_paid_hot_path.json; then rerun E11 readback if needed and rerun parameterized aggregator."
}
```

### QA-PAID-08 Paid Artifact Consumer Contract Check（2026-06-05）

本节为 QA artifact consumer contract check，不关闭 TODO-20，不允许 paid；当前 paid 仍 `blocked_until_real_evidence`。

```json
{
  "task_id": "QA-PAID-08",
  "parent_task_id": "TODO-20",
  "lane": "QA/Security",
  "status": "blocked_expected",
  "commit": "8e3318d",
  "paid_controlled_beta_requested": true,
  "paid_controlled_beta_allowed": false,
  "changed_files": [
    "scripts/verify_paid_beta_artifact_contracts.ps1",
    "project/RELEASE_CHECKLIST.md",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "commands_run": [
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_artifact_contracts.ps1 -SelfTest", "exit_code": 0, "classification": "pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_artifact_contracts.ps1", "exit_code": 2, "classification": "blocked_expected"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_status_copy_guard.ps1", "exit_code": 0, "classification": "pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/scan_secrets.ps1", "exit_code": 0, "classification": "pass"},
    {"command": "git diff --check -- scoped files", "exit_code": 0, "classification": "pass"}
  ],
  "artifacts_written": [],
  "acceptance_results": {
    "schema": "paid_beta_artifact_consumer_contracts_v1",
    "overall_status": "blocked",
    "actual_exit_code": 2,
    "e8_consumer_status": "blocked_gateway_paid_hot_path_consumer_shape_missing",
    "e8_request_ids_present": true,
    "e8_operation_ids_present": false,
    "e11_blockers_propagated": true,
    "e9_blockers_propagated": true
  },
  "blockers": [
    "E8 artifact exists and reports status=passed, but consumer contract blocks on gateway_paid_hot_path_consumer_shape_missing.",
    "E8 consumer shape currently missing operation ids.",
    "E11 artifact remains blocked and its blockers are propagated.",
    "E9 readiness remains blocked and its missing-evidence blockers are propagated.",
    "Real paid evidence bundle is not accepted for release."
  ],
  "next_task": "E8/E11 owners align consumer-visible operation/request id shape; then rerun scripts/verify_paid_beta_artifact_contracts.ps1 and paid aggregator."
}
```

### QA-PAID-09 Wait for E8 Consumer Shape Fix Then Contract+Aggregator（2026-06-05）

本节为 E8 consumer shape 更新后的 QA rerun，不关闭 TODO-20，不允许 paid；当前 paid 仍 `blocked_until_real_evidence`。

```json
{
  "task_id": "QA-PAID-09",
  "parent_task_id": "TODO-20",
  "lane": "QA/Security",
  "status": "blocked_expected",
  "commit": "8e3318d",
  "paid_controlled_beta_requested": true,
  "paid_controlled_beta_allowed": false,
  "changed_files": [
    "scripts/verify_paid_beta_artifact_contracts.ps1",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "commands_run": [
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_artifact_contracts.ps1", "exit_code": 2, "classification": "blocked_expected"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_control_plane_paid_ledger_readback.ps1 -GatewayArtifactPath .tmp/paid-beta/e8_gateway_paid_hot_path.json -OutputPath .tmp/paid-beta/e11_control_plane_paid_readback_reconciliation.json", "exit_code": 2, "classification": "blocked_expected"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_acceptance.ps1 -OutputPath artifacts/beta_acceptance_paid_aggregator_20260605_qapaid09.json", "exit_code": 2, "classification": "blocked_expected"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_status_copy_guard.ps1", "exit_code": 0, "classification": "pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/scan_secrets.ps1", "exit_code": 0, "classification": "pass"},
    {"command": "git diff --check -- scoped files", "exit_code": 0, "classification": "pass"}
  ],
  "artifacts_written": [
    {"path": "artifacts/beta_acceptance_paid_aggregator_20260605_qapaid09.json", "schema": "paid_beta_acceptance_aggregator_v2", "secret_safe": true, "fresh": true, "simulation": false}
  ],
  "acceptance_results": {
    "e8_consumer_status": "pass",
    "e8_request_id_count": 3,
    "e8_operation_id_count": 7,
    "e8_evidence_array_operation_id_compat": "pass",
    "e8_missing_operation_id_negative_selftest": "pass",
    "e8_consumer_shape_blocker_closed": true,
    "e11_status": "blocked_control_plane_paid_readback_sql_unavailable",
    "aggregator_overall_status": "blocked",
    "aggregator_actual_exit_code": 2,
    "paid_controlled_beta_allowed": false
  },
  "blockers": [
    "E11 readback remains blocked on control_plane_paid_readback_sql_unavailable.",
    "E9 readiness remains blocked on paid_controlled_beta_refused_missing_evidence.",
    "Real paid evidence bundle is missing.",
    "Release gate paid allowed remains blocked until all real paid evidence inputs pass."
  ],
  "next_task": "E11 owner resolves SQL/readback availability, E9 composes accepted real paid evidence bundle, then QA reruns consumer contract and paid aggregator. Main-thread Review is still required before any paid release."
}
```

### QA-PAID-10 Wait for E11 Mapping Refresh and Re-Aggregate（2026-06-05）

本节为 E11/E9 artifacts 更新后的 QA rerun，不关闭 TODO-20，不允许 paid；当前 paid 仍 `blocked_until_real_evidence`。

```json
{
  "task_id": "QA-PAID-10",
  "parent_task_id": "TODO-20",
  "lane": "QA/Security",
  "status": "blocked_expected",
  "commit": "8e3318d",
  "paid_controlled_beta_requested": true,
  "paid_controlled_beta_allowed": false,
  "changed_files": [
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "commands_run": [
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_artifact_contracts.ps1 -SelfTest", "exit_code": 0, "classification": "pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_artifact_contracts.ps1", "exit_code": 2, "classification": "blocked_expected"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_acceptance.ps1 -OutputPath artifacts/beta_acceptance_paid_aggregator_20260605_qapaid10.json", "exit_code": 2, "classification": "blocked_expected"}
  ],
  "artifacts_written": [
    {"path": "artifacts/beta_acceptance_paid_aggregator_20260605_qapaid10.json", "schema": "paid_beta_acceptance_aggregator_v2", "secret_safe": true, "fresh": true, "simulation": false}
  ],
  "acceptance_results": {
    "e8_consumer_status": "pass",
    "e8_request_id_count": 3,
    "e8_operation_id_count": 7,
    "e11_status": "blocked_control_plane_paid_readback_sql_unavailable",
    "e9_status": "blocked_paid_controlled_beta_refused_missing_evidence",
    "real_paid_evidence_bundle": "missing",
    "aggregator_overall_status": "blocked",
    "aggregator_actual_exit_code": 2,
    "paid_controlled_beta_allowed": false
  },
  "blockers": [
    "E11 readback remains blocked on control_plane_paid_readback_sql_unavailable.",
    "E9 readiness remains blocked on paid_controlled_beta_refused_missing_evidence.",
    "Real paid evidence bundle is missing.",
    "Release gate paid allowed remains blocked until all real paid evidence inputs pass."
  ],
  "next_task": "E11 owner resolves SQL/readback availability and E9/Harvey produces accepted real paid evidence bundle/readiness, then QA reruns consumer contract and paid aggregator."
}
```

### QA-PAID-11 Watch E11-S7 and E9-S124 Outputs（2026-06-05）

本节为 E11-S7/E9-S124 输出后的 QA rerun，不关闭 TODO-20，不允许 paid；当前 paid 仍 `blocked_until_real_evidence`。

```json
{
  "task_id": "QA-PAID-11",
  "parent_task_id": "TODO-20",
  "lane": "QA/Security",
  "status": "blocked_expected",
  "commit": "8e3318d",
  "paid_controlled_beta_requested": true,
  "paid_controlled_beta_allowed": false,
  "changed_files": [
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "commands_run": [
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_artifact_contracts.ps1", "exit_code": 2, "classification": "blocked_expected"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_acceptance.ps1 -OutputPath artifacts/beta_acceptance_paid_aggregator_20260605_qapaid11.json", "exit_code": 2, "classification": "blocked_expected"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_status_copy_guard.ps1", "exit_code": 0, "classification": "pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/scan_secrets.ps1", "exit_code": 0, "classification": "pass"},
    {"command": "git diff --check -- scoped files", "exit_code": 0, "classification": "pass"}
  ],
  "artifacts_written": [
    {"path": "artifacts/beta_acceptance_paid_aggregator_20260605_qapaid11.json", "schema": "paid_beta_acceptance_aggregator_v2", "secret_safe": true, "fresh": true, "simulation": false}
  ],
  "acceptance_results": {
    "e8_consumer_status": "pass",
    "e8_request_id_count": 3,
    "e8_operation_id_count": 7,
    "e11_status": "blocked_control_plane_paid_readback_refund_rows_missing",
    "e9_status": "blocked_paid_controlled_beta_refused_missing_evidence",
    "real_paid_evidence_bundle": "missing",
    "bundle_verifier": "not_run_bundle_missing",
    "aggregator_overall_status": "blocked",
    "aggregator_actual_exit_code": 2,
    "paid_controlled_beta_allowed": false
  },
  "blockers": [
    "E11 readback remains blocked on control_plane_paid_readback_refund_rows_missing.",
    "E9 readiness remains blocked on paid_controlled_beta_refused_missing_evidence.",
    "Real paid evidence bundle is missing.",
    "Release gate paid allowed remains blocked until all real paid evidence inputs pass."
  ],
  "next_task": "E8/E11/E9 decide whether reserve reversal satisfies refund evidence or produce real refund rows; Harvey produces accepted bundle/readiness; then QA reruns consumer contract, bundle verifier, and paid aggregator."
}
```

### QA-PAID-14 Fix Aggregator Pass Classification for E8/E11 Passed Artifacts（2026-06-05）

本节为 QA aggregator classification fix。Aggregator 当前已能识别 E8/E11 passed artifacts、E9 readiness allowed 和 real bundle accepted，并输出 pass；controlled paid beta 仍需主线程 Review 后才算接受。

```json
{
  "task_id": "QA-PAID-14",
  "parent_task_id": "TODO-20",
  "lane": "QA/Security",
  "status": "qa_pass_pending_main_thread_review",
  "commit": "8e3318d",
  "paid_controlled_beta_requested": true,
  "paid_controlled_beta_allowed": true,
  "changed_files": [
    "scripts/verify_paid_beta_acceptance.ps1",
    "scripts/verify_paid_beta_artifact_contracts.ps1",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "commands_run": [
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_acceptance.ps1 -SelfTest", "exit_code": 0, "classification": "pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_artifact_contracts.ps1 -SelfTest", "exit_code": 0, "classification": "pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_artifact_contracts.ps1", "exit_code": 0, "classification": "pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_billing_paid_evidence_bundle.ps1 -BundlePath .tmp/paid-beta/real_paid_evidence_bundle.json", "exit_code": 0, "classification": "pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_billing_beta_mode_readiness.ps1 -BillingMode paid_controlled_beta -PaidEvidenceBundlePath .tmp/paid-beta/real_paid_evidence_bundle.json", "exit_code": 0, "classification": "pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_acceptance.ps1 -OutputPath artifacts/beta_acceptance_paid_aggregator_20260605_qapaid14.json", "exit_code": 0, "classification": "pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_paid_beta_status_copy_guard.ps1", "exit_code": 0, "classification": "pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/scan_secrets.ps1", "exit_code": 0, "classification": "pass"},
    {"command": "git diff --check -- scoped files", "exit_code": 0, "classification": "pass"}
  ],
  "artifacts_written": [
    {"path": "artifacts/beta_acceptance_paid_aggregator_20260605_qapaid14.json", "schema": "paid_beta_acceptance_aggregator_v2", "secret_safe": true, "fresh": true, "simulation": false}
  ],
  "acceptance_results": {
    "artifact_consumer_contract_status": "pass",
    "bundle_verifier_status": "accepted_contract_shape",
    "readiness_decision": "paid_controlled_beta_allowed",
    "aggregator_overall_status": "pass",
    "aggregator_actual_exit_code": 0,
    "paid_controlled_beta_allowed": true,
    "pass_checks": [
      "secret_scan",
      "e9_paid_readiness_gate_json",
      "gateway_paid_hot_path_reserve_settle_refund",
      "control_plane_paid_readback_reconciliation",
      "real_paid_evidence_bundle_accepted"
    ],
    "blocked_checks": []
  },
  "blockers": [
    "Main-thread Review must accept the final controlled paid beta release decision before external paid enablement."
  ],
  "next_task": "Main thread reviews qapaid14 aggregator, bundle verifier, readiness gate, and paid release posture before marking controlled paid beta accepted."
}
```

---

## TODO-21：可信用户 Beta 发放准备

**Owner**：Agent-Release / DevRel Ops  
**Priority**：P0 Beta  
**状态**：paid limitations draft ready；overall release prep 仍未关闭  
**依赖**：TODO-20 pass；paid 对外文案必须遵循 `docs/PAID_BETA_RUNBOOK.md`。

### 交付物

- Beta 使用说明：base URL、virtual key、支持 endpoint、限制、错误码、支持渠道。
- Admin runbook：如何查 request_id、如何禁用 provider key、如何改模型映射、如何查 guardrail hit。
- Incident runbook：429、5xx、stream EOF、ledger lag、prompt reject、provider key auth failed。
- 数据保留说明：默认 metadata-only/redacted。
- Known limitations：controlled paid beta evidence accepted but not full Production RC；bounded smoke refund endpoint is dev evidence only；partial refund policy/deeper reconciliation、ClickHouse、production tokenizer、multi-region 仍为后置限制。
- Paid beta operator/user-facing limitation draft：`docs/PAID_BETA_RUNBOOK.md`；artifact index：`docs/PAID_BETA_EVIDENCE_INDEX.md`。DOC-PAID-16 后 controlled paid beta evidence 已被 main review 接受；对外材料仍必须说明这不是 full Production RC，bounded smoke refund endpoint 是 dev evidence only，partial refund policy/deeper reconciliation 仍为 RC work。

### Done 定义

- 任何 Beta 用户收到的文档不承诺未完成能力。
- 内部 on-call 可按 request_id 排障。
- 所有发出的 virtual key 有预算/RPM/TPM/过期/IP 策略。

---

# PHASE 3：Paid / controlled beta hardening

## TODO-30：E9 真实 reserve / settle / refund 接入 Gateway 热路径

**Owner**：Agent-E9 + Agent-Gateway  
**Priority**：Paid Beta blocker

### 必须完成

- Gateway auth 后、provider call 前执行 budget pre_authorize/reserve。
- provider success 后 settle。
- provider pre-first-byte fail 后 refund/release。
- partial_sent 后按显式 billing policy settle/refund。
- client cancel 按显式 billing policy settle/refund。
- worker crash/restart 后 reconciliation 可恢复。
- request_id 幂等键贯穿 Gateway、worker、Control Plane。

### Done

- 并发超卖测试通过。
- crash/restart 恢复测试通过。
- reconciliation report 与 ledger 汇总一致。
- Admin UI 账务解释可追溯 price_version/billing_policy_version。

### TODO-30A：Paid Beta readiness refusal gate（E9 派生，已完成）

- Gate 脚本：`scripts/verify_billing_beta_mode_readiness.ps1`。
- 默认无 DB/无网络，只读取 fixture/default contract 并输出机器可读 JSON summary。
- `usage_only_beta` 允许作为 fallback/safe mode；用户已请求 `paid_controlled_beta`，但只有 TODO-30 evidence 全齐且 real evidence bundle accepted 才允许。
- 当前 paid 请求必须拒绝，blockers：`gateway_hot_path_reserve_settle_refund`、`insufficient_balance_prevents_provider_call`、`settle_idempotency`、`refund_idempotency`、`post_commit_readback`、`rollback_proof`、`reconciliation_report`、`real_evidence_bundle_accepted`。
- S117R optional bundle input：`-PaidEvidenceBundlePath` 可消费 ToD-06A bundle validation。无 bundle -> `paid_controlled_beta_requested=true` / `paid_controlled_beta_allowed=false` / JSON `actual_exit_code=2`；accepted contract-shape bundle -> evidence present but `contract_shape_only=true`，继续 blocked；incomplete bundle -> missing/invalid evidence blocked。只有 non-synthetic real production bundle 同时满足 `contract_shape_only=false`、`production_hot_path_claim=true`、`paid_controlled_beta_production_ready=true`、七项 evidence pass、secret-safe pass 时才允许 `paid_controlled_beta_allowed=true`。
- S118 composer：`scripts/compose_billing_paid_evidence_bundle.ps1 -GatewayPaidHotPathArtifactPath <e8-artifact> -ControlPlanePaidReadbackArtifactPath <e11-artifact> -OutputBundlePath <bundle>`。普通模式只允许 `.tmp/**` 或 `artifacts/**` path；E8 TODO-30B-S2 Gateway artifact 已刷新为 `.tmp/paid-beta/e8_gateway_paid_hot_path.json`，但 paid overall 仍需 E11/E9 bundle/QA 聚合通过。
- S119 default artifact writer：`scripts/verify_billing_beta_mode_readiness.ps1 -BillingMode paid_controlled_beta -OutputPath .tmp/paid-beta/e9_paid_readiness_gate.json` writes blocked JSON for QA. `-OutputPath` is repo-bounded to `.tmp/**` or `artifacts/**` and does not print raw paths/env/secrets.
- Operator/devrel runbook：`docs/PAID_BETA_RUNBOOK.md`；不得把 fixture/template/local-only artifact 当作 paid allowed evidence。
- Evidence artifact index：`docs/PAID_BETA_EVIDENCE_INDEX.md`；任何 missing/blocked/pending/stale/synthetic row 都阻断 paid。
- S115 release integration：`scripts/release_check.ps1 -Checks billing` 作为 Beta/release gate 的离线 billing check；`scripts/test.ps1 -BillingBetaModeReadinessOnly` 作为局部验证。release gate pass 只表示 fallback 口径安全且 paid 未误放行，不表示 TODO-30 Gateway 热路径已实现。
- 下一步仍是 E11/E9/QA 组合验收；不得把 TODO-30A gate 或单 lane artifact 当作 paid overall allowed。

### TODO-30B：Gateway Paid Hot Path Reserve-Settle-Refund Beta Implementation Slice（E8/Gateway，已完成 / bounded beta，S2 readback consistency fixed）

- Gateway paid hot path opt-in：默认 usage-only/free path 不变；paid beta 仅在 `GATEWAY_PAID_HOT_PATH_BETA` truthy 或 dev virtual key metadata `billing_mode=paid_controlled_beta`/`paid_hot_path_beta=true` 时启用。
- Gateway runtime ordering：request log 后、rate-limit reservation/provider_attempt/provider_key/upstream 前执行 paid preauth/reserve；insufficient balance 或 paid price/wallet/reserve 不可用时返回 billing 402，provider_attempt rows 保持 0。
- Ledger evidence：success path writes pending reserve before provider side effect, then confirmed settle and reverses the reserve using `settle:{request_id}` idempotency; provider 429 failure path releases/reverses pending reserve with `release:{request_id}` marker. S5 adds bounded full refund-after-settle idempotency helper/contract; live refund readback and partial refund product policy remain Production RC.
- Verifier：`scripts/verify_gateway_paid_hot_path_smoke.ps1`；operator SQL：`scripts/operator/gateway_paid_hot_path_readback.sql`。The verifier prepares local pricing selector schema if an old dev DB is missing migration `0007`, seeds bounded local wallet/credit/price fixtures, restores virtual key/channel state, and writes secret-safe JSON.
- Fresh S2 artifact：`.tmp/paid-beta/e8_gateway_paid_hot_path.json` with `schema=gateway_paid_hot_path_smoke_v1`, `status=passed`, `smoke_run_id=e8-paid-1780688349296`; paired independent readback artifact: `.tmp/paid-beta/e8_gateway_paid_hot_path_readback.json`.
- Same-run S2 readback：request rows `3`; provider_attempt rows `2`; reserve rows `2`; reserve reversed `2`; settle confirmed `1`; failure release `1`; insufficient-balance provider_attempt rows `0`; insufficient-balance reserve rows `0`; `reserve_before_provider_side_effect=true`; `successful_request_settled=true`; `failure_request_released=true`; `post_commit_readback=true`; `secret_safe.raw_or_secret_marker_present=false`.
- S2 consistency fix：main-review blocker was reproduced as a handoff parameter mismatch, where independent SQL using only ordered `request_ids` could not know success/failure/insufficient roles. `scripts/operator/gateway_paid_hot_path_readback.sql` now infers roles from same-run ledger/request evidence when named role ids are omitted, emits `resolved_request_roles`, and outputs real ledger operation evidence ids for E11 handoff. `scripts/verify_gateway_paid_hot_path_smoke.ps1` now writes explicit role ids, per-role request trace entries, `operator_readback.parameters`, top-level E11-consumable `evidence` items, and a copyable secret-safe operator command. The smoke cannot return `status=passed` unless same-run operator readback has `successful_request_settled=true`, `failure_request_released=true`, `post_commit_readback=true`, `insufficient_balance_provider_attempt_rows=0`, no raw/secret marker, and E11 input shape request/operation ids are present.
- S2 E11 shape closure：fresh `.tmp/paid-beta/e8_gateway_paid_hot_path.json` has seven required evidence items, request id count `3`, operation id count `3`, and maps reserve/settle/release/readback/rollback/reconciliation evidence to request ids plus real ledger operation evidence. `scripts/verify_control_plane_paid_ledger_readback.ps1 -GatewayArtifactPath .tmp/paid-beta/e8_gateway_paid_hot_path.json -OutputPath .tmp/paid-beta/e11_control_plane_paid_readback_reconciliation.json` now accepts all seven E8 evidence keys and reports `request_ids_present=true`, `operation_ids_present=true`; it remains blocked only by `control_plane_paid_readback_sql_unavailable`, not by `gateway_paid_hot_path_request_or_operation_ids_missing`.
- S2 selftest：`scripts/verify_gateway_paid_hot_path_smoke.ps1 -SelfTest` covers complete pass, missing failure release rejected, missing settle rejected, insufficient-balance provider attempt rejected, raw/Auth marker rejected, E11 shape projection accepted, and mismatched operation id projection rejected.
- S3 alias hardening：`scripts/verify_gateway_paid_hot_path_smoke.ps1` now writes top-level `request_ids`, `operation_ids`, and `ledger_operation_ids` aliases without removing existing `request_trace`、`operator_readback.parameters`、`evidence[]` fields. The aliases are derived from the same request/evidence/readback data: top-level `request_ids` equals unique `request_trace.request_ids`; top-level `operation_ids` equals unique `evidence[].operation_id`; `ledger_operation_ids` contains real ledger operation ids from operator SQL. Fresh `.tmp/paid-beta/e8_gateway_paid_hot_path.json` has `request_ids=3`, `request_trace.request_ids=3`, `operation_ids=3`, unique evidence operation ids `3`, ledger operation ids `3`, evidence count `7`. `scripts/verify_paid_beta_artifact_contracts.ps1` remains overall blocked with JSON `actual_exit_code=2`, but E8 `consumer_status=pass` and `paid_controlled_beta_allowed=false`.
- S4 Production RC negative guard：E8 hardened the streaming paid hot-path negative path for client cancel/provider stream error. `apps/gateway/src/streaming.rs` now maps `StreamEndReason::ClientCancel` to stable paid release reason `stream_client_cancel`, maps other non-completed stream endings to `stream_not_completed`, and leaves `Completed` as the only settle-eligible streaming finalization path. Regression `paid_hot_path_stream_negative_guard_releases_cancel_and_never_settles` proves cancel/upstream-error streams do not create settle entries while completed streams with complete usage and nonzero rating remain settle-eligible. Commands passed: `scripts/verify_gateway_paid_hot_path_smoke.ps1 -SelfTest` exit 0; `scripts/verify_gateway_paid_hot_path_smoke.ps1 -PreflightOnly` exit 0; `cargo test -p ai-gateway paid_hot_path_stream_negative_guard --all-targets` exit 0; `cargo test -p ai-gateway paid_hot_path --all-targets` exit 0. This is Production RC hardening only; `paid_controlled_beta_allowed=false` remains unchanged.
- S5 refund-after-settle idempotency：E8 added a bounded Gateway DB adapter contract for full refund after confirmed settle. `apps/gateway/src/db.rs` now has `PaidSettledRefundEntry` / `PaidSettledRefundOutcome`, stable refund key helper `refund:{settle_ledger_entry_id}`, and `insert_full_paid_refund_after_settle_ledger_entry` guarded by confirmed settle debit lookup plus related refund/idempotency locks. The helper inserts one confirmed positive `refund` with schema `gateway_paid_hot_path_refund_after_settle_v1`, returns `Idempotent` on duplicate key replay, and returns `SourceNotSettled` when the source is not a confirmed settle debit. Regression `paid_refund_after_settle_replay_is_idempotent_and_requires_settle_source` proves duplicate full refund idempotency and that unsettled reserve remains release/rollback path, not refund-after-settle. Commands passed: `scripts/verify_gateway_paid_hot_path_smoke.ps1 -SelfTest` exit 0; `scripts/verify_gateway_paid_hot_path_smoke.ps1 -PreflightOnly` exit 0; `cargo test -p ai-gateway paid_refund_after_settle --all-targets` exit 0; `cargo test -p ai-gateway paid_hot_path --all-targets` exit 0. This helper is not wired into default hot path and does not change paid opt-in defaults or `paid_controlled_beta_allowed=false`.
- S6 bounded smoke refund row：E8 added a smoke-only Gateway endpoint `POST /__e8/paid-hot-path/refund-after-settle` that reuses the S5 helper. It requires normal Gateway auth, paid beta virtual-key/env opt-in, and explicit `X-E8-Paid-Hot-Path-Smoke-Refund: true`; without the smoke header it returns 404 and it is not part of the default production request path. Paid smoke now reads the success settle ledger entry id, calls the endpoint twice, requires first outcome `applied` and replay `idempotent`, then final readback must show `refund_rows > 0`, `refund_idempotency_key`, related settle ledger id, and `duplicate_refund_idempotent=true`. Fresh `.tmp/paid-beta/e8_gateway_paid_hot_path.json` passed; independent `scripts/operator/gateway_paid_hot_path_readback.sql` with artifact params returned request rows `3`, provider attempts `2`, refund rows `1`, refund status `passed`, duplicate refund idempotent `true`, post commit readback `true`. E11 verifier with the refreshed E8 artifact wrote `.tmp/paid-beta/e11_control_plane_paid_readback_reconciliation.json` and exited 0 with overall `passed`, reserve `1`, settle `1`, refund `1`, insufficient provider attempts `0`, blockers `[]`. This closes the local `control_plane_paid_readback_refund_rows_missing` path, but `paid_controlled_beta_allowed=false` remains until E9/QA/main review accepts the full bundle.
- E8-CREDIT-01 credit grant balance audit：Gateway pre-authorize/reserve can use already-created active credit grants for the selected wallet and currency, with `status='active'`, `valid_from <= now()`, and `valid_until is null or valid_until > now()` guards. Available balance remains conservative: active credit grant remaining amount plus pending/confirmed ledger window minus `wallet.balance_floor`; reserve transaction lock order is wallet -> active credit grants -> ledger rows -> insert. Regression coverage added in Gateway SQL-shape tests. User recharge, credit grant CRUD/issuance, and lifecycle policy are not Gateway scope and remain Control Plane/billing product work.
- Commands: S119 build/redeploy kept valid: `docker compose -f deploy/docker-compose/docker-compose.yml build gateway` exit 0; `POSTGRES_HOST_PORT=55432 REDIS_HOST_PORT=56379 docker compose -f deploy/docker-compose/docker-compose.yml up -d postgres redis mock-provider gateway` exit 0; Gateway `/healthz` 200. S2 rerun: `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_gateway_paid_hot_path_smoke.ps1 -SelfTest` exit 0; `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_gateway_paid_hot_path_smoke.ps1 -PreflightOnly` exit 0; live verifier with `-ArtifactPath .tmp/paid-beta/e8_gateway_paid_hot_path.json` exit 0; same-run SQL readback via artifact parameters exit 0; SQL readback with only `request_ids` exit 0 through role inference; E11 verifier command wrote `.tmp/paid-beta/e11_control_plane_paid_readback_reconciliation.json` with JSON `actual_exit_code=2` and blocker `control_plane_paid_readback_sql_unavailable`; `cargo test -p ai-gateway paid_hot_path --all-targets` exit 0; `cargo test -p ai-gateway rate_limit_reservation --all-targets` exit 0; scoped `git diff --check` exit 0.
- Remaining blockers：paid overall is not allowed yet; still requires E9 real paid evidence bundle composition/readiness pass, QA paid aggregator/release gate pass, main review acceptance, partial refund product policy/operation ids, deeper partial stream accounting, and production reconciliation. E11 local readback is now pass with refund rows, but that does not by itself open paid.

### ToD-06A：Billing strong consistency evidence bundle contract（E9 派生，已完成）

- Bundle schema：`billing_paid_strong_consistency_evidence_bundle.v1`。
- Rust validator：`crates/billing-ledger/src/paid_evidence_bundle.rs`，输出 `overall_status`、`accepted_contract_shape`、`required_evidence`、`missing_evidence`、`invalid_evidence`、`refusal_reasons`、`readiness_evidence`、`secret_safe`。
- Verifier：`scripts/verify_billing_paid_evidence_bundle.ps1 -BundlePath <bundle.json>`；离线、DB-free、无网络，不输出 raw bundle/path/secret/env 原值。
- Fixtures：`tests/fixtures/billing/paid_evidence_bundle.accepted_contract_shape.json` 和 `tests/fixtures/billing/paid_evidence_bundle.incomplete_contract_shape.json`。
- S117R synthetic selftest fixture：`tests/fixtures/billing/paid_evidence_bundle.synthetic_production_ready_selftest.json` 只用于 validator 自测，不是 release artifact；即使声明 production-looking shape，也因 `synthetic_selftest=true` 不允许开启 paid。
- S118 composer selftest fixtures：`tests/fixtures/billing/paid_evidence_composer.gateway_real_shape_selftest.json`、`tests/fixtures/billing/paid_evidence_composer.control_plane_real_shape_selftest.json`。`compose_billing_paid_evidence_bundle.ps1 -SelfTest` 只写 synthetic selftest bundle under `.tmp/billing-ledger/composer-selftest/`，not release artifact。
- Required evidence 七项：`gateway_hot_path_reserve_settle_refund`、`insufficient_balance_prevents_provider_call`、`settle_idempotency`、`refund_idempotency`、`post_commit_readback`、`rollback_proof`、`reconciliation_report`。
- Accepted-shape bundle 仅可作为后续 readiness gate 输入形状，不声明 `paid_controlled_beta` 生产可用；TODO-30B Gateway hot path bounded beta artifact 已完成，但整体 paid allowed 仍等待 E11/E9/QA 组合验收。

### TODO-30C：Control Plane paid ledger readback + reconciliation evidence（E11 派生，ready / blocked by Gateway artifact）

- Verifier：`scripts/verify_control_plane_paid_ledger_readback.ps1`，默认只读 `artifacts/gateway_paid_hot_path_evidence.json`；artifact 缺失时输出 `overall_status=blocked`、`gateway_paid_hot_path_artifact_missing`、`paid_controlled_beta_opened_by_this_check=false`，不得 pass。
- Contract/fixtures：`tests/fixtures/billing/control_plane_paid_ledger_readback_contract.json`、`tests/fixtures/billing/control_plane_paid_gateway_hot_path_artifact.accepted_shape.json`。selftest 覆盖完整 accepted-shape、Gateway artifact missing、raw secret/Auth marker、operation id mismatch、refund idempotency mismatch refusal。
- SQL readback：`scripts/operator/control_plane_paid_ledger_reconciliation_readback.sql` 聚合 ledger/request/provider_attempts/audit counts，映射 E9 七项 evidence：reserve/settle/refund、readback、rollback、reconciliation、insufficient-balance no-provider-call。
- 当前本机结果：`-SelfTest` exit 0；E8 Gateway TODO-30B artifact 已存在于 `.tmp/gateway-paid-hot-path/e8-paid-hot-path-live-smoke.json`；accepted-shape fixture 可通过 artifact contract，但 real SQL readback 当前因本机 Control Plane paid readback SQL 不可用 blocked exit 2。paid 仍保持 `paid_controlled_beta_requested` / `blocked_until_real_evidence`，等待 E11 paid readback artifact、E9 bundle 和 QA 聚合。
- S2 当前本机结果：E11 runtime-current artifact 与 browser mutation artifact 已 fresh/readback pass，`scripts/test.ps1 -ControlPlaneLedgerAdjustmentExecuteBrowserReadbackOnly` exit 0；paid verifier blocked 输出包含 `actual_exit_code=2`，普通 shell `%ERRORLEVEL%=2`，Codex tool UI 如显示 exit 1 属 runner 非零归一化，不改变 JSON contract。
- S3 当前本机结果：default handoff artifact `.tmp/paid-beta/e11_control_plane_paid_readback_reconciliation.json` 已写出，状态 `blocked`、`actual_exit_code=2`、blocker `gateway_paid_hot_path_artifact_missing`；fixture handoff `.tmp/paid-beta/e11_control_plane_paid_readback_reconciliation.fixture.json` 状态 `blocked`、blocker `control_plane_paid_readback_sql_unavailable`；optional E8 artifact `.tmp/gateway-paid-hot-path/e8-paid-hot-path-live-smoke.json` 因缺 request/operation ids 被 E11 verifier `refused`，未进入 SQL pass。output secret-safe，未写 raw Gateway artifact、session/auth/DB URL/provider key/virtual key/raw request。
- S4 当前本机结果：`.tmp/paid-beta/e8_gateway_paid_hot_path.json` 已存在，但缺 request/operation ids；E11 verifier default output `.tmp/paid-beta/e11_control_plane_paid_readback_reconciliation.json` 为 `blocked`、`actual_exit_code=2`、blocker `gateway_paid_hot_path_request_or_operation_ids_missing`。E8 需补 request/operation-id-bearing evidence array 或 agreed equivalent，E11 才能执行 Control Plane SQL/readback。
- S5 当前本机结果：required-shape contract 已固化；并行 E8 artifact 当前可解析七项 evidence，E11 已进入 Control Plane SQL/readback，default output `.tmp/paid-beta/e11_control_plane_paid_readback_reconciliation.json` 为 `blocked`、`actual_exit_code=2`、blocker `control_plane_paid_readback_sql_unavailable`。下一步是可用 Control Plane paid SQL/readback 后复跑，不得把 input-shape pass 当 paid pass。
- S6 当前本机结果：E11 artifact `.tmp/paid-beta/e11_control_plane_paid_readback_reconciliation.json` 现在包含 top-level `evidence[]` mapping，keys 为 `post_commit_readback`、`rollback_proof`、`reconciliation_report`，三项均因 `control_plane_paid_readback_sql_unavailable` 标记 `blocked` / `passed=false`。Harvey composer 不再报 `control_plane_paid_readback_evidence_mapping_missing`，而是 blocked by `control_plane_paid_readback_not_passed` + `control_plane_paid_readback_sql_unavailable`；paid 仍未开放。E11 browser release readback regression 本轮因 stale browser artifact blocked，需重新生成 fresh browser evidence 后再作为 release gate pass。
- S7 当前本机结果：E11 verifier 已能在当前 compose runtime 通过 stdin SQL 读到 Control Plane tables，`post_commit_readback`、`rollback_proof`、`reconciliation_report` evidence pass；但 Gateway/E8 paid hot path rows 中 `refund_count=0`，因此 `.tmp/paid-beta/e11_control_plane_paid_readback_reconciliation.json` 仍 `overall_status=blocked`、`actual_exit_code=2`、blocker `control_plane_paid_readback_refund_rows_missing`，paid 仍未开放。若 reserve reversal 是预期 refund representation，需要 E8/E11/E9/QA 显式更新 contract；否则下一步是生成真实 refund ledger row 后复跑。
- S8 当前本机结果：尚未消费到新的 E8 refund-after-settle row；E11 保持 S7 精确 blocker `control_plane_paid_readback_refund_rows_missing`，readback counts 不变，composer 未写 real bundle。E11 browser release readback stale blocker 仍独立存在，不影响 paid SQL blocker 分类但也不得当 pass。
- S10 当前本机结果：E8 artifact `smoke_run_id=e8-paid-1780691021962` 已被 E11 消费；E11 readback artifact `.tmp/paid-beta/e11_control_plane_paid_readback_reconciliation.json` 为 pass，`actual_exit_code=0`，refund row 已读到。E11 paid readback lane is ready for E9/QA handoff；paid controlled beta remains not allowed until E9 bundle/readiness and QA aggregator pass and main-thread Review accepts.

---

## TODO-31：预算、限流、密钥健康的保守保护

**Owner**：Agent-Routing / Agent-Security  
**Priority**：Paid Beta / Beta hardening

### 必须完成

- virtual key 日/月/总预算 hard limit。
- RPM/TPM/concurrency 限制统一返回错误 shape。
- provider key 429 进入 cooldown，尊重 Retry-After。
- auth_failed / balance_insufficient / quota_limited 状态分开。
- manual disable / recovery probe 有 audit log。

---

## TODO-32：Credit / Wallet Productization

**Owner**：Agent-E9 / Billing Ledger + Product/API owner
**Priority**：P1 for broader commercial distribution；不阻塞 controlled paid beta evidence acceptance  
**状态**：credit/wallet contract + key runtime slices partially verified；TODO-32F opening-balance import runtime verified，TODO-32G Admin credit grant CRUD/Audit runtime verified，TODO-32H Admin-readonly 与 user-session ownership remaining-balance runtime verified；recharge/voucher、payment/order/invoice、subscription/package runtime 仍 pending  
**依赖**：TODO-13/TODO-30 controlled paid beta evidence 已接受；full commercial rollout 需要本 TODO 收敛。
**Contract draft**：`docs/todo/slices/TODO-32-CREDIT-WALLET.md`

### TODO-32B：Billing credit grant contract tests（E9，2026-06-05）

新增 crate-level contract fixture/test：`tests/fixtures/billing/credit_wallet_productization_contract.json` 与 `crates/billing-ledger/tests/credit_wallet_productization_contract.rs`。当前状态为 `contract_enforced_not_runtime_wired`：不实现外部 payment/order/invoice，不改 runtime writer，不改 paid gate，但用 fixture validator 固定 credit grant create/list/expire/revoke、remaining balance summary、opening balance import、admin adjustment 的账务不变量。

E9-CREDIT-04 added QA-readable artifact writer `scripts/write_credit_wallet_billing_mutation_contract_artifact.ps1`。默认生成 `.tmp/credit-wallet/billing_mutation_contract_tests.json`，schema=`billing_mutation_contract_tests.v1`，status=`pass`，并输出 `money_decimal_strings=true`、`idempotency_contract=true`、`direct_wallet_snapshot_mutation_forbidden=true`、`secret_safe=true`、`runtime_writer_changed=false`、`paid_gate_changed=false`。QA verifier 可读取该 path 判断 `billing_mutation_artifact_verified=true`，无需触碰 paid artifacts。

已 enforce：

- write endpoint 必须有 idempotency key、audit fields，并覆盖 replay/conflict refusal。
- money 必须是 decimal string + currency，禁止 float shape。
- response 必须 `secret_safe=true` 且不含 authorization/bearer/provider key/virtual key/database URL/raw secret markers。
- wallet snapshot 只能是 read model，禁止 direct wallet snapshot mutation 作为账务事实。
- create/expire/revoke/import/adjustment 必须产生 credit grant row、ledger entry、admin adjustment entry、opening entry 或 grant consumption marker 之一。

Remaining gap：API/schema/runtime 仍未实现；TODO-32B 只防止 contract 退化，不代表 broader commercial distribution ready。

### TODO-32F：Opening Balance Import Ledger Entry（runtime verified / complete）

E9-CREDIT-05 selected `POST /billing/opening-balance-imports` as the next smallest runtime implementation ticket, before general credit grant persistence/API. Reason: it directly supports New API / One API migration and can reuse `AdminAdjustmentLedgerRequest` / admin adjustment or opening ledger entry primitives without opening payment/order/invoice/subscription scope.

E9-CREDIT-06 completed the opening-balance import contract fixture and writer mapping: `tests/fixtures/billing/opening_balance_import_contract.json` and `crates/billing-ledger/tests/opening_balance_import_contract.rs` enforce apply, idempotent replay, same-key conflict, duplicate external reference conflict, wallet currency mismatch, non-positive amount refusal, direct wallet snapshot mutation refusal, decimal-string money, and secret-safe response/audit output. Accepted imports map to existing `AdminAdjustmentLedgerRequest` / `LedgerAdminAdjustmentKind::Credit` with confirmed adjust ledger entry semantics and canonical admin adjustment idempotency.

E9-CREDIT-07 added QA-readable artifact writer `scripts/write_opening_balance_import_contract_artifact.ps1`。默认生成 `.tmp/credit-wallet/opening_balance_import_contract.json`，schema=`opening_balance_import_contract.v1`，status=`pass`，并输出 `secret_safe=true`、`money_decimal_strings=true`、`idempotency_contract=true`、`opening_ledger_entry_required=true`、`direct_wallet_snapshot_mutation_forbidden=true`、`paid_gate_changed=false`、`runtime_implemented=false`、`runtime_writer_changed=false`、`controlled_paid_beta_blocker=false`、`broader_migration_blocker=true`。Artifact 只包含 case/test/writer mapping summary，不输出 raw idempotency key、raw import payload、token、DB URL、provider key、virtual key 或 env value。

E9-CREDIT-08 ledger-side schema/runtime compatibility review：E9 consumed E11 `db/migrations/0011_opening_balance_imports.sql` and found it compatible with the E9 writer mapping contract. It provides stable import id, tenant/project/wallet/currency/opening amount/source/reference/idempotency/status fields, `ledger_entry_id`/`admin_adjustment_entry_id`, `audit_id`, `request_summary`, timestamps, uniqueness for `(tenant_id,idempotency_key)` and `(tenant_id,external_source,external_reference_id)`, and status values `imported|replayed|refused`. E9 fixture includes `runtime_schema_contract` and artifact emits `requires_schema=true`, `opening_balance_imports_schema_required=true`, `schema_contract_compatible=true`, `e11_schema_landed=true`, `runtime_implemented=false`。E9 did not modify DB schema/runtime.

E9-CREDIT-09 supports E11 runtime S2 with a ledger command contract, without changing billing-ledger runtime: opening import accepted apply maps to the existing `AdminAdjustmentLedgerRequest` credit command and requires bounded command metadata `operation=opening_balance_import`, `external_source`, `external_reference_id`, and `reason`; raw idempotency key and raw import payload output are forbidden. The QA artifact now includes `ledger_command_contract.compatible=true` and keeps `runtime_implemented=false` until live mutation/readback exists.

E9-CREDIT-17 reviewed E11-CREDIT-10/TODO-32F-S7 rollback-contained psql plan and internal SQLx transaction shape against the Billing Ledger opening import contract. Verdict: contract still matches; no direct wallet snapshot mutation was found in the opening import plan; positive apply maps to confirmed `adjust`/admin credit ledger entry with `operation=opening_balance_import`; replay, idempotency conflict, external-reference conflict, wallet currency refusal, audit/link ids, fixed decimal money, and secret-safe output remain aligned. E9 added `runtime_acceptance_contract` to the fixture/artifact: rollback-contained psql plan is allowed only as blocked evidence and is not runtime acceptance; `runtime_implemented=true` requires route/internal runtime invocation plus live readback fields, including ledger/admin adjustment, audit, replay/refusal, rollback, and `wallet_snapshot_mutated=false`.

E9-CREDIT-18 consumed the current TODO-32F-S7 partial runtime artifact after DB-plan readback passed. Current `.tmp/credit-wallet/opening_balance_import_runtime.json` is `overall_status=partial`, `db_integration_ran=true`, `db_runner_implemented=true`, `executable_db_plan.passed=true`; DB plan checks for apply, replay, idempotency conflict, external-reference conflict, confirmed adjust ledger, audit, wallet-currency refusal/no ledger write, rollback, and secret safety are true. Billing Ledger verdict remains contract-match/non-acceptance: `runtime_implemented=false`, `contract_only=true`, `route_invoked=false`, and blockers are public route not wired plus internal Rust function not invoked by verifier.

QA-CREDIT-08 verified the E9 opening-balance import artifact at `.tmp/credit-wallet/opening_balance_import_contract.json`: `opening_balance_import_artifact_verified=true`, schema `opening_balance_import_contract.v1`, status `pass`, `secret_safe=true`, `money_decimal_strings=true`, `idempotency_contract=true`, `opening_ledger_entry_required=true`, `direct_wallet_snapshot_mutation_forbidden=true`, `paid_gate_changed=false`, and `runtime_implemented=false`. This is accepted contract/artifact evidence only; it does not claim runtime mutation, live DB import, or rollback/readback acceptance.

E11-CREDIT-03 added the Control Plane Admin/API boundary for `POST /billing/opening-balance-imports`: OpenAPI skeleton, Admin session + `billing_adjust` RBAC path mapping, and a 501 contract-only route skeleton. Request contract includes tenant/project/wallet/currency/opening amount/source/reference/effective_at/reason/actor/idempotency; response contract includes opening import, ledger/admin adjustment, audit ids, imported/replayed/refused status, idempotency result, guardrails, and `secret_safe=true`. Current runtime status is `contract_only_route_present_runtime_mutation_pending`: it does not write ledger entries, opening import rows, or audit rows, and it does not create a live QA artifact.

E11-CREDIT-04 feasibility review: `apps/control-plane/src/admin.rs` already has reusable ledger adjustment runtime pieces: DB transaction, wallet lock/read, ledger idempotency dedupe, confirmed `ledger_entries` insert, `audit_logs` insert, and rollback on ledger/audit failure. The accepted TODO-32F runtime should still add an `opening_balance_imports` table rather than relying only on ledger metadata, because QA needs a stable `opening_import_id`, exact replay/conflict readback, and concurrency-safe uniqueness for `(tenant_id, external_source, external_reference_id)`. Therefore `requires_schema=true` for the next accepted runtime patch. A ledger/audit-only marker is allowed only as `runtime_partial_not_QA_accepted`.

E11-CREDIT-05 landed TODO-32F-S1 schema and runtime skeleton plan: `db/migrations/0011_opening_balance_imports.sql` and `examples/sql_schema_draft.sql` define `opening_balance_imports` with tenant/project/wallet/currency/positive opening amount, external source/reference, effective/reason/actor/idempotency, status, nullable ledger/admin-adjustment/audit ids, safe `request_summary`/`metadata`, unique `(tenant_id,idempotency_key)`, unique `(tenant_id,external_source,external_reference_id)`, and tenant/wallet/status/created indexes. The Control Plane 501 response now includes a DB-free `runtime_plan` and `readback_marker` naming the schema/migration, transaction boundary, wallet lock, opening import read/write sequence, apply/replay/conflict/refusal outcomes, and future QA artifact shape. This remains `runtime_skeleton_plan_only`: no live mutation, ledger write, audit write, or runtime artifact is claimed.

E11-CREDIT-06 landed TODO-32F-S2 design-to-code first patch as `runtime_sql_contract_partial`: `runtime_plan.sql_contract` now defines DB-free statement contracts for wallet lock, opening import read by idempotency, opening import read by external reference, import insert, confirmed `adjust` ledger insert, `billing.opening_balance_import` audit insert, and import link update. Outcome contract covers apply/imported, replay/replayed without new ledger/audit success write, idempotency conflict/refused, external reference conflict/refused, and wallet/currency refusal without ledger write. This is not live runtime mutation: the route still returns contract-only 501 and `runtime_implemented=false`; no DB write/readback artifact is claimed.

E11-CREDIT-07 landed TODO-32F-S3 bounded runtime transaction attempt as `internal_transaction_shape_partial`: `opening_balance_import_runtime_attempt_contract_shape` now validates request + wallet/import snapshots and produces secret-safe internal shapes for apply/imported, same-key replay/replayed with original ids and no new ledger/audit, same-key different-body `idempotency_conflict`, duplicate external-reference/different-key `external_reference_conflict`, and wallet/currency refusal with no ledger write. This still performs no DB I/O and does not change the public route from contract-only 501; `runtime_implemented=false` and no live artifact is claimed.

E11-CREDIT-08 landed TODO-32F-S4 as `compiled_internal_sqlx_transaction_partial`: `execute_opening_balance_import_internal_tx` now compiles and uses `sqlx::Transaction<'_, Postgres>` for the intended order: validate request, lock wallet, read `opening_balance_imports` by idempotency, read by external reference, decide replay/conflict/refusal/apply, insert opening import, insert confirmed adjust ledger entry, insert audit log, link import with ledger/audit ids, and return secret-safe applied shape. The public route still returns contract-only 501 and does not call this internal function. No live DB readback or runtime artifact is claimed; `runtime_implemented=false` remains the externally accepted state until opt-in DB tests/artifact prove it.

E11-CREDIT-09 added TODO-32F-S5 opt-in runtime verifier scaffold: `scripts/verify_opening_balance_import_runtime.ps1`. Default run writes `.tmp/credit-wallet/opening_balance_import_runtime.json` as `overall_status=blocked`, `runtime_implemented=false`, `contract_only=true`, `db_integration_ran=false`, `route_live_changed=false`, `paid_gate_changed=false`, `secret_safe=true`, blocker `opening_balance_import_db_integration_not_requested`. Explicit `-RunDbIntegration` without `OPENING_BALANCE_IMPORT_DB_OPT_IN=1` writes a blocked artifact with blocker `opening_balance_import_db_opt_in_env_missing`. The script selftest passes and does not echo raw DB/env/token/idempotency/import/provider/virtual-key material. This still does not prove live apply/replay/conflict/refusal readback.

E11-CREDIT-10 landed TODO-32F-S6 as `opening_balance_import_executable_db_plan_guarded`: `scripts/verify_opening_balance_import_runtime.ps1` now has an opt-in DB runner guard and a rollback-contained `psql` plan. It only attempts a DB connection when `-RunDbIntegration` is passed, `OPENING_BALANCE_IMPORT_DB_OPT_IN=1` is set, and `CONTROL_PLANE_DATABASE_URL` or `DATABASE_URL` exists. The plan is secret-safe and exercises bounded seed/find wallet, import apply, replay, idempotency conflict, external reference conflict, wallet currency refusal marker, ledger readback, audit readback, and rollback. Current default artifact remains `.tmp/credit-wallet/opening_balance_import_runtime.json` with `overall_status=blocked`, `runtime_implemented=false`, `contract_only=true`, `db_integration_ran=false`, blocker `opening_balance_import_db_integration_not_requested`; opt-in without env writes `.tmp/credit-wallet/opening_balance_import_runtime.optin_blocked.json` with missing env blockers. No DB connection was attempted in the current environment, and the public route still returns contract-only 501.

Main-thread TODO-32F-S7 progress: local compose was available (`postgres` running on localhost) and `db/migrations/0011_opening_balance_imports.sql` was applied to the compose DB. `scripts/verify_opening_balance_import_runtime.ps1` was corrected so the rollback-contained `psql` plan uses statement-separated insert/link/readback instead of same-statement data-modifying CTE readback. Opt-in run now writes `.tmp/credit-wallet/opening_balance_import_runtime.json` as `overall_status=partial`, `db_integration_ran=true`, `db_runner_implemented=true`, `executable_db_plan.passed=true`, with apply/replay/idempotency-conflict/external-reference-conflict/ledger/audit/wallet-refusal/rollback DB plan checks true. It still keeps `runtime_implemented=false`, `contract_only=true`, `route_invoked=false`, and blockers `opening_balance_import_public_route_not_wired` plus `opening_balance_import_internal_rust_function_not_invoked_by_verifier`; this is DB-plan evidence only, not public route or Rust runtime acceptance.

E11-CREDIT-11 landed TODO-32F-S8 as `opening_balance_import_live_route_runtime_verified`: `POST /billing/opening-balance-imports` now invokes `execute_opening_balance_import_internal_tx` behind existing Admin/RBAC and returns `runtime_implemented=true`, `contract_only=false`, `route_invoked=true`, `internal_sqlx_function_invoked=true` only for real route/runtime execution. Critical replay bug fixed: DB-read `effective_at` is canonicalized against RFC3339 request input, so same idempotency key + same logical body replays original `opening_import_id`, `ledger_entry_id` / `admin_adjustment_entry_id`, and `audit_id` without new ledger/audit writes; same key different body still refuses `idempotency_conflict`, duplicate external reference different key refuses `external_reference_conflict`, and wallet currency mismatch refuses without import. `scripts/verify_opening_balance_import_runtime.ps1` now requires a live route probe with `CONTROL_PLANE_ADMIN_SESSION_TOKEN` for runtime pass; DB/Rust-only evidence remains partial. Current `.tmp/credit-wallet/opening_balance_import_runtime.json` is `overall_status=pass`, `runtime_implemented=true`, `contract_only=false`, `route_invoked=true`, `internal_sqlx_function_invoked=true`, live route matrix/readback pass, and `secret_safe=true`; `scripts/verify_credit_wallet_ledger_surface.ps1` reports `opening_balance_import_runtime_verified=true`. Paid gate unchanged.

Main-thread TODO-32F-S8 runtime acceptance: current Control Plane source wires `POST /billing/opening-balance-imports` to `execute_opening_balance_import_internal_tx`. A live compose probe initially found same-key/same-body replay returned `idempotency_conflict` because DB `effective_at::text` and request RFC3339 strings were compared directly; `apps/control-plane/src/admin.rs` now canonicalizes opening-import effective_at before matching. After rebuilding compose control-plane with `POSTGRES_HOST_PORT=55432` and `REDIS_HOST_PORT=56379`, live route matrix passed: apply HTTP 201 `runtime_implemented=true`, `contract_only=false`, `route_invoked=true`, `internal_sqlx_function_invoked=true`; same-key/same-body replay returned `replayed` with original import/ledger ids; same-key different amount refused `idempotency_conflict`; duplicate external reference refused `external_reference_conflict`; wallet/currency mismatch refused without import row; opening import, ledger entry, and audit DB readback passed. `.tmp/credit-wallet/opening_balance_import_runtime.json` now has `overall_status=pass`, required ids/readback booleans, `secret_safe=true`, and `paid_gate_changed=false`. `scripts/verify_credit_wallet_ledger_surface.ps1` reports `opening_balance_import_runtime_verified=true`, `opening_balance_import_artifact_verified=true`, and verdict `new_api_one_api_balance_import=runtime_verified`; remaining gaps no longer include `new_api_one_api_balance_import_apply_rollback_runner`.

E9-CREDIT-19 consumed the current TODO-32F-S8 runtime artifact from the Billing Ledger contract view. Verdict: `contract_match=true` and `runtime_acceptance_true=true`. The artifact is `overall_status=pass`, `runtime_implemented=true`, `contract_only=false`, `route_invoked=true`, `internal_sqlx_function_invoked=true`, has opening import / ledger / admin adjustment / audit ids, passes apply/replay/idempotency-conflict/external-reference-conflict/wallet-refusal/readback/rollback checks, keeps `secret_safe=true`, and preserves `paid_gate_changed=false`. This satisfies the E9 `runtime_acceptance_contract`: confirmed admin adjustment / adjust ledger entry, original-id replay without new ledger/audit success write, no ledger write on refusal, and no direct wallet snapshot mutation. E9 changed only docs plus refreshed the contract artifact; Gateway/Control Plane/Admin UI and paid artifacts were not modified by E9.

E9-CREDIT-20 added the TODO-32G credit grant CRUD ledger/accounting contract and QA-readable contract artifact. New files: `tests/fixtures/billing/credit_grant_crud_contract.json`, `crates/billing-ledger/tests/credit_grant_crud_contract.rs`, and `scripts/write_credit_grant_crud_contract_artifact.ps1`; generated artifact `.tmp/credit-wallet/credit_grant_crud_contract.json` has schema `credit_grant_crud_contract.v1`, status `pass`, `runtime_implemented=false`, and `paid_gate_changed=false`. Contract scope covers create grant, list/read grants, expire, revoke, idempotent replay, same-key conflict refusal, invalid currency/amount/time-window refusal, no direct wallet snapshot mutation, audit metadata required, fixed decimal money strings, and secret-safe output. This is contract/artifact-ready evidence only; E11-CREDIT-12 still owns Admin API/runtime implementation and QA must verify live create/list/read/expire/revoke readback before clearing `credit_grant_crud_api_and_audit`.

E9-CREDIT-21 added the TODO-32H user-facing remaining balance read-model contract and QA-readable contract artifact. New files: `tests/fixtures/billing/user_remaining_balance_contract.json`, `crates/billing-ledger/tests/user_remaining_balance_contract.rs`, and `scripts/write_user_remaining_balance_contract_artifact.ps1`; generated artifact `.tmp/credit-wallet/user_remaining_balance_contract.json` has schema `user_remaining_balance_contract.v1`, status `pass`, `runtime_implemented=false`, `contract_only=true`, `control_plane_endpoint_present=false`, `read_only=true`, `paid_gate_changed=false`, and `secret_safe=true`. Contract scope covers tenant/project/user or developer-token ownership scope, wallet scope check, currency check, formula `active_credit_grant_total + pending_confirmed_ledger_window - wallet_balance_floor`, decimal-string `available_to_spend`, active grant totals, expired/revoked grant exclusion, pending/confirmed ledger window, budget remaining, strong/stale/estimated consistency markers, bounded ledger/grant ids, read-only/no mutation behavior, currency/missing-wallet/ownership refusal, and secret-safe output. Main thread verified `cargo test -p ai-gateway-billing-ledger user_remaining_balance -- --nocapture` exit `0` (1 passed), regenerated the writer artifact exit `0`, and verifier reports `user_remaining_balance_contract_verified=true` / `user_remaining_balance_runtime_verified=false`. This is contract/artifact-ready evidence only; E11 still owns Control Plane User/API or Admin/API runtime before clearing `user_facing_remaining_balance_api_runtime`.

E9-CREDIT-22 added the TODO-32I recharge/voucher ledger/product contract and QA-readable contract artifact. New files: `tests/fixtures/billing/recharge_voucher_contract.json`, `crates/billing-ledger/tests/recharge_voucher_contract.rs`, and `scripts/write_recharge_voucher_contract_artifact.ps1`; generated artifact `.tmp/credit-wallet/recharge_voucher_contract.json` has schema `recharge_voucher_contract.v1`, status `pass`, `runtime_implemented=false`, `contract_only=true`, `paid_gate_changed=false`, and `secret_safe=true`. Main thread verified `cargo test -p ai-gateway-billing-ledger recharge_voucher -- --nocapture` exit `0` (1 passed). Contract scope covers recharge/top-up intent states created/pending/paid/cancelled/refunded, voucher issuance with hashed/redacted code and campaign/scope/currency/amount/valid-window/max-redemption fields, redeem success with credit grant or ledger/admin-adjustment marker plus audit, same-redeemer/idempotency replay without duplicate credit, same-code different-user and over-max-redemption refusals, expired/revoked/currency/non-positive/ownership refusals, bounded abuse/rate-limit attempts without raw code echo, refund/cancel mapping to grant revoke or ledger reversal marker, fixed decimal money strings, and secret-safe output. This is contract/artifact-ready evidence only; Product/E11/Security/QA still own runtime/payment-provider/voucher-storage/abuse-persistence implementation and QA runtime acceptance before clearing `user_recharge_voucher_redemption_flow`.

E9-CREDIT-26 prepared TODO-32I runtime acceptance without implementing provider/runtime paths. Future runtime acceptance must use `.tmp/credit-wallet/recharge_voucher_runtime.json` or `artifacts/credit_wallet_recharge_voucher_runtime.json` with schema `recharge_voucher_runtime.v1`, `runtime_implemented=true`, `contract_only=false`, route/internal invocation proof, voucher storage readback, voucher code hash readback plus redacted output, redeem readback, redeem idempotency readback, abuse/refusal no-write readback, ledger or credit effect readback, refund/cancel reversal readback, audit readback, `direct_wallet_snapshot_mutation_forbidden=true`, `secret_safe=true`, `paid_gate_changed=false`, and no raw voucher code/provider/payment secret output. The verifier now keeps contract-only TODO-32I as runtime false and will not let synthetic or contract-only artifacts satisfy runtime verification.

E9-CREDIT-31 added Billing Ledger feasibility support for TODO-32I without implementing recharge/voucher runtime, provider integration, Gateway changes, or paid-gate changes. The recharge/voucher fixture, Rust contract test, and writer artifact now include `runtime_feasibility_plan` with `runtime_implemented=false`, `contract_only=true`, and `paid_gate_changed=false`. Reusable primitives are wallets, `credit_grants`, `ledger_entries` / admin adjustment markers, `audit_logs`, the opening-balance import idempotent transaction/refusal pattern, verified credit-grant CRUD runtime, and the remaining-balance read model. Missing runtime primitives are recharge intent schema, voucher campaign schema, voucher issuance schema, voucher redemption schema, voucher redeem-attempt or abuse-event schema, payment-provider handoff/callback state, and a live route matrix artifact. Proposed slices are TODO-32I-S1 schema/OpenAPI boundary, TODO-32I-S2 voucher issue/redeem transaction, TODO-32I-S3 hash/redaction and abuse persistence, TODO-32I-S4 provider handoff/callback/refund mapping, and TODO-32I-S5 QA runtime artifact.

E9-CREDIT-33 ran the TODO-32I-S2 accounting support watcher against the current E11 schema/OpenAPI boundary while waiting for the voucher issue/redeem internal transaction skeleton. No E9 contract adjustment was needed: `db/migrations/0012_recharge_voucher_boundary.sql` and the OpenAPI boundary align with fixed-decimal positive money, hashed idempotency and voucher code storage, redacted output, `credit_grant_id` / `ledger_entry_id` / `audit_id` linkage, voucher redeem attempts for abuse/refusal persistence, no direct wallet snapshot mutation, and paid-gate neutrality. No non-contract voucher issue/redeem runtime transaction is present yet, so `.tmp/credit-wallet/recharge_voucher_runtime.json` remains absent and `recharge_voucher_runtime_verified=false`.

E9-CREDIT-34 reviewed the E11-CREDIT-23 voucher issue/redeem contract skeleton from the Billing Ledger accounting view. `voucher_issue_contract_plan` and `voucher_redeem_contract_plan` are contract-only (`runtime_implemented=false`) and align with E9 invariants: hashed voucher/idempotency material, code redaction, fixed-decimal money parsing, same-key replay without duplicate credit or ledger writes, same-key changed-body conflict refusal, expired/revoked/currency/ownership/non-positive refusals with no credit/ledger write, voucher redeem attempt markers, success `credit_grant_id` / `ledger_entry_id` / `audit_id` linkage, secret-safe output, no direct wallet snapshot mutation, and `paid_gate_changed=false`. No E9 fixture/test/writer change was required. TODO-32I runtime remains pending until non-contract route/internal DB readback and refund/cancel reversal evidence land.

E9-CREDIT-35 reviewed E11-CREDIT-24 SQLx statement contracts from the Billing Ledger accounting view. The statement contracts align with E9 invariants: issue locks wallet, reads idempotency by hash, checks duplicate `code_hash`, inserts `voucher_issuances` with `code_hash` / `code_lookup_prefix` / `code_redacted` / hashed idempotency / audit metadata, and inserts audit; redeem inserts `voucher_redeem_attempts`, locks voucher by `code_hash`, reads redemption idempotency by hash, inserts `voucher_redemptions` with `credit_grant_id` / `ledger_entry_id` / `audit_id` / `refusal_code`, inserts credit-grant effect, inserts audit, and updates redemption count. SQL remains secret-safe and paid-gate neutral. No E9 fixture/test/writer adjustment was required. This is statement-contract evidence only: `recharge_voucher_runtime_verified=false` remains correct until opt-in SQLx/runtime readback and refund/cancel reversal evidence land.

E9-CREDIT-36 watched for E11-CREDIT-25 opt-in DB/internal SQLx evidence before the E11 DB-plan verifier landed. No E9 contract adjustment was required. TODO-32I runtime remains blocked until `recharge_voucher_runtime.v1` proves route/internal DB invocation, hashed code/idempotency readback, replay/conflict/refusal no-write, attempt persistence, credit/ledger/audit readback, refund/cancel reversal, secret safety, and `paid_gate_changed=false`.

E11-CREDIT-25 added a TODO-32I-S4 opt-in DB-plan verifier for voucher issue/redeem. Its initial DB-attempt artifact was blocked and contract-only with `runtime_implemented=false`, `contract_only=true`, `secret_safe=true`, and `paid_gate_changed=false`; the old blocker was `recharge_voucher_schema_0012_not_applied` because the compose DB lacked migration 0012 recharge/voucher tables such as `voucher_issuances`. That S4 blocked state is historical and superseded by the E11-CREDIT-26 / E9-CREDIT-39 migration-applied partial DB-plan state below. `.tmp/credit-wallet/recharge_voucher_runtime.json` remains absent and `recharge_voucher_runtime_verified=false` remains correct.

E11-CREDIT-22 completed TODO-32I-S1 schema/OpenAPI boundary without implementing recharge/voucher runtime. Control Plane now has `db/migrations/0012_recharge_voucher_boundary.sql`, synced `examples/sql_schema_draft.sql`, and OpenAPI skeleton coverage in `examples/openapi_admin_skeleton.yaml` for `POST /billing/recharge-intents`, `POST /admin/voucher-campaigns`, `POST /admin/voucher-issuances`, and `POST /billing/vouchers/redeem`. The boundary covers `recharge_intents`, `voucher_campaigns`, `voucher_issuances`, `voucher_redemptions`, and `voucher_redeem_attempts`, with fixed-decimal amounts, hashed idempotency, voucher `code_hash` / `code_lookup_prefix` / redacted output, provider reference redaction, credit/ledger/audit links, and abuse attempt markers. Control Plane tests cover migration/OpenAPI boundary strings and forbidden raw voucher/payment/provider secret persistence. This remains schema/OpenAPI/contract-only boundary evidence: `recharge_voucher_runtime_verified=false`, no payment-provider handoff or route runtime is claimed, Gateway is unchanged, and paid gate is unchanged.

E11-CREDIT-23 completed TODO-32I-S2 as a DB-free internal voucher issue/redeem transaction skeleton without implementing recharge/voucher runtime. Control Plane tests now cover issue success with `code_hash`, `code_lookup_prefix`, `code_redacted`, hashed idempotency, and audit marker; redeem success with voucher redemption, abuse attempt, credit grant or ledger effect, and audit links; same-key replay without duplicate credit/ledger writes; same-key conflict refusal; expired/revoked/currency/non-positive/ownership refusals; and refusal no-write markers. The skeleton remains `runtime_implemented=false` / `contract_only=true`, does not write `.tmp/credit-wallet/recharge_voucher_runtime.json`, does not change Gateway or paid gate, and keeps `recharge_voucher_runtime_verified=false`.

E11-CREDIT-24 completed TODO-32I-S3 as SQLx statement contract progress without implementing recharge/voucher runtime. Control Plane tests now pin issue statement order and fields for wallet lock, idempotency lookup, duplicate code-hash lookup, `voucher_issuances` insert, and issue audit; redeem statement order and fields for `voucher_redeem_attempts`, voucher lock by `code_hash`, `voucher_redemptions` idempotency lookup, redemption insert with credit/ledger/audit/refusal links, credit-grant effect insert, redeem audit, and redemption-count update. The SQL contract forbids raw voucher code, provider payload, auth/cookie, DB URL, provider key, virtual key, and raw idempotency material. No live route or `.tmp/credit-wallet/recharge_voucher_runtime.json` is claimed, and `recharge_voucher_runtime_verified=false` remains correct.

E11-CREDIT-25 completed TODO-32I-S4 as an opt-in DB verifier without claiming recharge/voucher runtime. New script `scripts/verify_recharge_voucher_runtime.ps1` writes blocked/partial contract-only DB-plan evidence; default mode blocks without DB, and opt-in mode requires `RECHARGE_VOUCHER_DB_OPT_IN=1`, a DB URL env, psql, and migration `0012_recharge_voucher_boundary.sql`. QA-CREDIT-49 evidence-management fix: default blocked mode now preserves an existing `.tmp/credit-wallet/recharge_voucher_runtime_db_plan.json` DB-attempt artifact and writes `.tmp/credit-wallet/recharge_voucher_runtime_db_plan.default_blocked.json` unless `-Overwrite` is supplied, so missing-env evidence does not erase more specific DB blockers. The SQL plan is rollback-contained and covers `voucher_issuances`, `voucher_redemptions`, `voucher_redeem_attempts`, idempotency replay/conflict, refusal no-write, credit grant/ledger effect, and audit readback. Current local compose opt-in attempt is blocked by `recharge_voucher_schema_0012_not_applied`; the preserved DB-attempt artifact remains `runtime_implemented=false`, `contract_only=true`, `secret_safe=true`, and `paid_gate_changed=false`. `.tmp/credit-wallet/recharge_voucher_runtime.json` remains absent and `recharge_voucher_runtime_verified=false` remains correct.

E9-CREDIT-37 consumed the current TODO-32I-S4 blocked DB-plan artifact from the Billing Ledger accounting view. Verdict: blocked artifact is safe and contract-compatible. It does not claim runtime (`runtime_implemented=false`, `contract_only=true`, `route_invoked=false`, `internal_sqlx_function_invoked=false`), is secret-safe, and does not change paid gate. The rollback-contained SQL plan matches E9 invariants for voucher issuance hash/redaction, redeem attempt persistence, redemption idempotency, conflict/refusal no-write, credit-grant/ledger/audit linkage, and readback shape. The blocker is environmental/schema setup (`recharge_voucher_schema_0012_not_applied`, relation `voucher_issuances` missing in the opt-in DB), not an E9 accounting contract mismatch. No E9 fixture/test/writer adjustment was required; TODO-32I runtime remains pending until migration 0012 is applied and non-contract runtime/readback plus refund/cancel reversal evidence lands.

E9-CREDIT-38 rechecked TODO-32I-S4 before migration-applied partial evidence was available. That historical watcher saw only the blocked `.tmp/credit-wallet/recharge_voucher_runtime_db_plan.json` with `recharge_voucher_schema_0012_not_applied`; this is superseded by E11-CREDIT-26 / E9-CREDIT-39. Current TODO-32I state is DB-plan partial, not runtime acceptance.

E11-CREDIT-26 applied `db/migrations/0012_recharge_voucher_boundary.sql` to the bounded local compose DB and reran `scripts/verify_recharge_voucher_runtime.ps1 -RunDbIntegration -OutputPath .tmp/credit-wallet/recharge_voucher_runtime_db_plan.json`. The DB-plan artifact is now migration-applied partial evidence, not runtime acceptance: `overall_status=partial`, `db_integration_ran=true`, `runtime_implemented=false`, `contract_only=true`, `route_invoked=false`, `internal_sqlx_function_invoked=false`, `secret_safe=true`, and `paid_gate_changed=false`. DB-plan readback booleans are true for voucher issuance, redemption, redeem attempts, issue/redeem idempotency replay lookup, conflict/refusal no-write, credit-grant link, ledger link, and audit link. Remaining blockers are `route_runtime_not_invoked` and `qa_runtime_artifact_missing`; `.tmp/credit-wallet/recharge_voucher_runtime.json` remains absent and `recharge_voucher_runtime_verified=false` remains correct.

E9-CREDIT-39 consumed the migration-applied TODO-32I DB-plan artifact from the Billing Ledger accounting view. Current `.tmp/credit-wallet/recharge_voucher_runtime_db_plan.json` is `overall_status=partial`, `db_integration_ran=true`, and `db_plan.passed=true`. E9 accepted the DB-plan accounting shape: voucher issuance hash/redaction readback, issue/redeem idempotency lookup, redemption readback, redeem attempt readback, idempotency-conflict refusal attempt, refusal no-write, credit grant link, ledger link, and audit link are true; raw voucher/idempotency/provider payload echo flags remain false; `secret_safe=true` and `paid_gate_changed=false`. This is still not runtime acceptance: `runtime_implemented=false`, `contract_only=true`, `route_invoked=false`, `internal_sqlx_function_invoked=false`, blockers are `route_runtime_not_invoked` and `qa_runtime_artifact_missing`, and `.tmp/credit-wallet/recharge_voucher_runtime.json` remains absent. No E9 fixture/test/writer adjustment was required.

E9-CREDIT-40 rechecked TODO-32I-S6 accounting evidence and consumed E11-CREDIT-27 `.tmp/credit-wallet/recharge_voucher_runtime_s6_blocked.json`. The pass runtime artifact `.tmp/credit-wallet/recharge_voucher_runtime.json` is still absent. The DB-plan remains partial/contract-only with `db_plan.passed=true`; the S6 blocked artifact is schema `recharge_voucher_runtime_s6_blocked.v1`, `overall_status=blocked`, `runtime_implemented=false`, `contract_only=true`, `route_invoked=false`, `internal_runtime_function_invoked=false`, `secret_safe=true`, `paid_gate_changed=false`, blockers `route_runtime_not_invoked`, `internal_runtime_function_not_invoked`, `refund_cancel_reversal_not_implemented`, and `qa_runtime_artifact_missing`. Billing Ledger accepts the accounting shape for issuance storage/hash/redaction, redeem attempts, replay/conflict, refusal no-write, credit-grant/ledger/audit readback, and secret safety, but this cannot clear TODO-32I runtime because route/internal runtime invocation, pass `recharge_voucher_runtime.v1`, QA runtime artifact acceptance, and refund/cancel reversal readback are still missing.

E9-CREDIT-41 watched E11-CREDIT-28 / TODO-32I-S8 from the Billing Ledger accounting lane. No pass `.tmp/credit-wallet/recharge_voucher_runtime.json` artifact exists, and the current evidence remains DB-plan partial plus S6 blocked progress. The main verifier still reports `recharge_voucher_contract_verified=true` and `recharge_voucher_runtime_verified=false`. E9 made no contract changes: DB readbacks for issue/redeem/idempotency/conflict/refusal no-write/credit-grant/ledger/audit stay contract-compatible, but runtime acceptance is still blocked until route/internal business invocation, `recharge_voucher_runtime.v1`, refund/cancel reversal readback, fixed-decimal/secret-safe output, paid-gate neutrality, and QA runtime acceptance are present.

E9-CREDIT-43 consumed the first pass-shaped TODO-32I runtime artifact from the Billing Ledger accounting lane. `.tmp/credit-wallet/recharge_voucher_runtime.json` is schema `recharge_voucher_runtime.v1`, `overall_status=pass`, `runtime_implemented=true`, `contract_only=false`, `internal_runtime_function_invoked=true`, `internal_sqlx_function_invoked=true`, `secret_safe=true`, and `paid_gate_changed=false`. E9 accounting accepts the artifact fields: credit grant, ledger, audit, redemption, and reversal ids are present; nested `checks`/`evidence` prove voucher issue storage, code hash/redaction, redeem readback, idempotent replay, conflict/refusal no duplicate write, attempt persistence, credit/ledger/audit readbacks, refund/cancel reversal readback, no wallet snapshot mutation, decimal money, and secret safety. The earlier QA verifier/schema mismatch is superseded by DOC-CREDIT-56: the main verifier now reports `recharge_voucher_runtime_verified=true`.

E9-CREDIT-44 completed final TODO-32I accounting confirmation after the runtime artifact became verifier-compatible. `.tmp/credit-wallet/recharge_voucher_runtime.json` is schema `recharge_voucher_runtime.v1`, `overall_status=pass`, `runtime_implemented=true`, `contract_only=false`, `internal_runtime_function_invoked=true`, `internal_sqlx_function_invoked=true`, `secret_safe=true`, and `paid_gate_changed=false`. E9 confirms credit-grant, ledger, audit, redemption, and reversal ids; idempotent replay/no duplicate effect; conflict/refusal no duplicate write; refund/cancel reversal readback; fixed-decimal money; no direct wallet snapshot mutation; and no raw voucher/idempotency/provider material echo. `scripts/verify_credit_wallet_ledger_surface.ps1` now reports `recharge_voucher_runtime_verified=true`. This satisfies TODO-32I runtime verifier by internal Rust/SQLx business path; `route_invoked=false` means public route/product UX remains polish, not an accounting blocker. TODO-32J payment/order/invoice runtime and TODO-32K subscription/package runtime remain false.

E9-CREDIT-45 moved the Billing Ledger watcher to TODO-32J payment/order/invoice. Current runtime state is contract-only: `.tmp/credit-wallet/payment_order_invoice_contract.json` is schema `payment_order_invoice_contract.v1`, status `pass`, `runtime_implemented=false`, `contract_only=true`, `secret_safe=true`, and `paid_gate_changed=false`; no `.tmp/credit-wallet/payment_order_invoice_runtime.json` or `artifacts/credit_wallet_payment_order_invoice_runtime.json` exists. E9 accounting acceptance matrix for a future runtime artifact requires order lifecycle readback, payment capture/confirm readback, provider handoff/callback redacted readback, invoice/receipt markers, ledger-or-credit effect, refund/cancel/chargeback reversal, idempotency replay no duplicate effect, conflict/refusal no duplicate write, audit, reconciliation, fixed-decimal money, secret safety, no direct wallet snapshot mutation, and paid-gate neutrality. Provider boundary is explicit: no real provider/callback means no production provider flow claim; bounded internal runtime can only be accepted if honestly labeled, all accounting readbacks pass, and the main verifier reports `payment_order_invoice_runtime_verified=true`. Current verifier reports `payment_order_invoice_contract_verified=true`, `payment_order_invoice_runtime_verified=false`, `recharge_voucher_runtime_verified=true`, and `subscription_package_lifecycle_runtime_verified=false`.

E11-CREDIT-27 completed TODO-32I-S6 as a strict runtime blocked handoff, not runtime acceptance. E11 reviewed the Control Plane router and confirmed recharge/voucher endpoints remain contract-only/future-runtime; no public route or verifier-callable internal Rust/sqlx business transaction exists yet. `scripts/verify_recharge_voucher_runtime.ps1` now supports `-WriteRuntimeBlockedArtifact` and writes `.tmp/credit-wallet/recharge_voucher_runtime_s6_blocked.json` after the opt-in DB-plan pass. The S6 artifact is distinct from the pass artifact path: `schema=recharge_voucher_runtime_s6_blocked.v1`, `overall_status=blocked`, `runtime_implemented=false`, `contract_only=true`, `route_invoked=false`, `internal_runtime_function_invoked=false`, `db_integration_ran=true`, `db_plan_passed=true`, `secret_safe=true`, and `paid_gate_changed=false`. It records true evidence for voucher issue storage/readback, voucher code hash readback, no raw voucher code echo, redeem readback, issue/redeem idempotency lookup, conflict/refusal no duplicate write, refusal/redeem attempt persistence, credit grant effect, ledger effect, and audit readback. Remaining blockers are `route_runtime_not_invoked`, `internal_runtime_function_not_invoked`, `refund_cancel_reversal_not_implemented`, and `qa_runtime_artifact_missing`; `.tmp/credit-wallet/recharge_voucher_runtime.json` remains absent and `recharge_voucher_runtime_verified=false` remains correct.

E11-CREDIT-28 completed TODO-32I-S7 as verifier-callable internal Rust/sqlx runtime evidence. `apps/control-plane/src/admin.rs` now includes `recharge_voucher_internal_runtime_db_integration` and `execute_recharge_voucher_internal_runtime_tx`, which execute voucher issue/redeem/refusal/reversal in an opt-in rollback-contained DB transaction rather than a bare psql plan. `scripts/verify_recharge_voucher_runtime.ps1 -RunInternalRuntime` invokes that Rust path and writes `.tmp/credit-wallet/recharge_voucher_runtime.json` only after artifact acceptance. Current artifact: `schema=recharge_voucher_runtime.v1`, `overall_status=pass`, `runtime_implemented=true`, `contract_only=false`, `internal_runtime_function_invoked=true`, `internal_sqlx_function_invoked=true`, `db_integration_ran=true`, `secret_safe=true`, and `paid_gate_changed=false`. Readbacks are true for voucher issue storage, voucher code hash/redacted output, raw voucher code not echoed, redeem, redeem idempotency replay, conflict/refusal no duplicate write, refusal/redeem attempt persistence, credit grant effect, ledger effect, audit, and refund/cancel reversal. `scripts/verify_credit_wallet_ledger_surface.ps1` reports `recharge_voucher_runtime_verified=true`. Public route wiring remains future polish; TODO-32J payment/order/invoice and TODO-32K subscription/package runtime remain pending.

E11-CREDIT-29 completed TODO-32J-S1 as a strict payment/order/invoice runtime planning verifier. New script `scripts/verify_payment_order_invoice_runtime.ps1` reads `.tmp/credit-wallet/payment_order_invoice_contract.json`, verifies the E9 contract artifact is accepted and secret-safe, and writes `.tmp/credit-wallet/payment_order_invoice_runtime_s1_blocked.json` instead of the pass path. The S1 artifact is `schema=payment_order_invoice_runtime.v1`, `overall_status=blocked`, `actual_exit_code=2`, `runtime_implemented=false`, `contract_only=true`, `route_invoked=false`, `internal_runtime_function_invoked=false`, `secret_safe=true`, and `paid_gate_changed=false`. Initial S1 blockers included `payment_order_invoice_schema_missing`; QA-CREDIT-63 supersedes that schema blocker after `0013_payment_order_invoice_boundary.sql` landed the required tables. Current blockers are `payment_order_invoice_runtime_not_invoked`, `payment_provider_handoff_runtime_missing`, `provider_callback_or_capture_readback_missing`, `invoice_receipt_runtime_missing`, `refund_cancel_chargeback_reversal_runtime_missing`, and `payment_order_invoice_reconciliation_readback_missing`. This keeps `payment_order_invoice_contract_verified=true` and `payment_order_invoice_runtime_verified=false`; it does not change Gateway, Admin UI, or the paid gate.

E9-CREDIT-46 consumed E11-CREDIT-29 output from the Billing Ledger accounting lane. `.tmp/credit-wallet/payment_order_invoice_runtime_s1_blocked.json` is a blocked sidecar, not runtime acceptance: `actual_exit_code=2`, `runtime_implemented=false`, `contract_only=true`, no route/internal runtime invocation, `secret_safe=true`, `paid_gate_changed=false`, and contract readback accepted. Initial blocker taxonomy included schema/tables; E9-CREDIT-47 supersedes that schema blocker after current diagnostics show all required payment/order/invoice tables present. Remaining blockers are runtime invocation, provider handoff/callback or bounded internal simulation policy, invoice/receipt readback, refund/cancel/chargeback reversal, and reconciliation. No runtime pass artifact exists at `.tmp/credit-wallet/payment_order_invoice_runtime.json`, so `payment_order_invoice_runtime_verified=false` remains correct. TODO-32I stays runtime verified; TODO-32K stays runtime false.

E9-CREDIT-47 refined TODO-32J-S3 from the Billing Ledger accounting lane after schema progress. `db/migrations/0013_payment_order_invoice_boundary.sql` and `examples/sql_schema_draft.sql` contain `payment_orders`, `payment_intents`, `payment_captures`, `payment_refunds`, `invoices`, `invoice_receipts`, and `payment_reconciliations`; `.tmp/credit-wallet/payment_order_invoice_runtime_s1_blocked.json` diagnostics report `schema.all_required_tables_present=true` and `missing_tables=[]`. E9 does not accept runtime because no pass `.tmp/credit-wallet/payment_order_invoice_runtime.json` exists and runtime/provider callback or bounded internal policy, invoice/receipt readback, refund/cancel/chargeback reversal readback, reconciliation readback, idempotency/conflict no-duplicate proof, audit, fixed-decimal money, secret safety, and paid-gate neutrality are still not proven by a non-contract artifact.

E9-CREDIT-48 consumed the TODO-32J S2 blocked sidecar from the Billing Ledger accounting lane. `.tmp/credit-wallet/payment_order_invoice_runtime_s2_blocked.json` is present and safe but not runtime acceptance: schema `payment_order_invoice_runtime.v1`, `overall_status=blocked`, `actual_exit_code=2`, `runtime_implemented=false`, `contract_only=true`, no route/internal runtime invocation, `secret_safe=true`, `paid_gate_changed=false`, and schema diagnostics still show all required tables present with `missing_tables=[]`. No `.tmp/credit-wallet/payment_order_invoice_runtime.json`, S3, or S4 artifact exists. `payment_order_invoice_runtime_verified=false` remains correct; remaining blockers are runtime/provider callback or bounded internal policy, callback/capture readback, invoice/receipt readback, refund/cancel/chargeback reversal readback, reconciliation readback, and lack of a non-contract pass artifact.

E9-CREDIT-49 watched for E11-CREDIT-31 TODO-32J-S5 output. No pass `.tmp/credit-wallet/payment_order_invoice_runtime.json` and no S3 blocked/partial artifact exists; current evidence remains S2 blocked sidecar only. The S2 sidecar is `runtime_implemented=false`, `contract_only=true`, no route/internal runtime invocation, `secret_safe=true`, `paid_gate_changed=false`, and schema-present. E9 keeps `payment_order_invoice_runtime_verified=false`; pass acceptance still requires real runtime invocation plus provider callback/capture or bounded internal policy, invoice/receipt, ledger/credit effect, refund/cancel/chargeback reversal, idempotency/conflict no duplicate, audit, reconciliation, fixed-decimal money, secret safety, and paid-gate neutrality readbacks.

E9-CREDIT-50 sets TODO-32J to `deferred_runtime_external_dependency` by user direction. This is not failure and not runtime completion: E9 contract/schema evidence remains accepted, S1/S2 blocked sidecars remain non-runtime, and `payment_order_invoice_runtime_verified=false` is preserved. Resume conditions are provider/callback runtime availability or an approved bounded internal policy, plus a non-contract runtime artifact proving invocation, provider/capture, invoice/receipt, ledger/credit effect, refund/cancel/chargeback reversal, idempotency/conflict no duplicate, audit, reconciliation, fixed-decimal money, secret safety, and paid-gate neutrality. TODO-32I remains runtime verified; TODO-32K remains runtime false. Recommended E9 next lane is TODO-32K subscription/package lifecycle contract/schema/defer assessment or local ledger accounting work that does not require unavailable external runtime.

E9-CREDIT-23 added the TODO-32J payment/order/invoice ledger/product contract and QA-readable contract artifact. New files: `tests/fixtures/billing/payment_order_invoice_contract.json`, `crates/billing-ledger/tests/payment_order_invoice_contract.rs`, and `scripts/write_payment_order_invoice_contract_artifact.ps1`; generated artifact `.tmp/credit-wallet/payment_order_invoice_contract.json` has schema `payment_order_invoice_contract.v1`, status `pass`, `runtime_implemented=false`, `contract_only=true`, `paid_gate_changed=false`, and `secret_safe=true`. Contract scope covers order states created/pending_payment/paid/cancelled/expired/refunded/failed, payment intent/provider handoff with bounded redacted provider reference and no client credential/provider payload echo, capture/confirm success with credit grant or ledger/admin-adjustment marker plus invoice/receipt/audit/reconciliation markers, idempotent order create/payment confirm/refund replay without duplicate credit/invoice/refund, amount/currency/provider-status/duplicate-provider-reference/non-positive/ownership/refund-exceeds-captured/invoice-duplicate refusals, invoice/receipt ids and fixed-decimal line items with tax/currency markers, refund/cancel mapping to grant revoke or ledger reversal marker, reconciliation between payment amount/issued credit/invoice line total/ledger effect, and secret-safe output. This is contract/artifact-ready evidence only; Product/Finance/Ops/E11/QA still own runtime provider handoff/callbacks, order lifecycle persistence, invoice/receipt production policy, tax/finance reconciliation, failure retry/chargeback handling, and QA runtime acceptance before clearing `payment_order_invoice_lifecycle_runtime`. QA-CREDIT-26 now verifies this contract lane as `payment_order_invoice_contract_verified=true` while keeping runtime false.

E9-CREDIT-27 prepared TODO-32J runtime acceptance without implementing payment provider/runtime paths. Future runtime acceptance must use `.tmp/credit-wallet/payment_order_invoice_runtime.json` or `artifacts/credit_wallet_payment_order_invoice_runtime.json` with schema `payment_order_invoice_runtime.v1`, `runtime_implemented=true`, `contract_only=false`, route/internal invocation proof, order lifecycle persistence readback, provider handoff/callback redacted readback, payment confirm/capture readback, invoice/receipt production readback, refund/cancel/chargeback reversal readback, reconciliation readback, idempotency replay and conflict/no-duplicate-write readback, audit readback, fixed-decimal money, `direct_wallet_snapshot_mutation_forbidden=true`, `secret_safe=true`, and `paid_gate_changed=false`. The verifier keeps contract-only TODO-32J as runtime false and will not let synthetic or contract-only artifacts satisfy runtime verification.

E9-CREDIT-24 added the TODO-32K subscription/package lifecycle ledger/product contract and QA-readable contract artifact. New files: `tests/fixtures/billing/subscription_package_lifecycle_contract.json`, `crates/billing-ledger/tests/subscription_package_lifecycle_contract.rs`, and `scripts/write_subscription_package_lifecycle_contract_artifact.ps1`; generated artifact `.tmp/credit-wallet/subscription_package_lifecycle_contract.json` has schema `subscription_package_lifecycle_contract.v1`, status `pass`, `runtime_implemented=false`, `contract_only=true`, `paid_gate_changed=false`, and `secret_safe=true`. Contract scope covers plan/package create/update, subscription create/trial/active/renew/cancel/pause/resume/end-of-trial/proration/payment-failed-dunning/expired/terminated states, subscription credit effects backed by credit grant or ledger/admin-adjustment markers, invoice/order linkage for activation and renewal, idempotent replay without duplicate subscription/credit/invoice writes, same-key conflict and ownership/currency/non-positive/invalid-plan refusals without accounting writes, cancel/terminate reversal through grant revoke or ledger reversal markers, fixed-decimal money strings, no direct wallet snapshot mutation, audit metadata, and secret-safe output. This is contract/artifact-ready evidence only; Product/E11/QA still own runtime plan/package APIs, recurring billing scheduler, provider retry/callback integration, invoice production, dunning execution, entitlement enforcement, and QA runtime acceptance before clearing `subscription_plan_lifecycle`.

E9-CREDIT-28 prepared TODO-32K runtime acceptance without implementing subscription/package runtime paths. Future runtime acceptance must use `.tmp/credit-wallet/subscription_package_lifecycle_runtime.json` or `artifacts/credit_wallet_subscription_package_lifecycle_runtime.json` with schema `subscription_package_lifecycle_runtime.v1`, `runtime_implemented=true`, `contract_only=false`, route/internal runtime invocation or scheduler proof, plan/package CRUD readback, subscription create/activate/renew/cancel/pause/resume/trial/proration/dunning state-transition readback, credit grant or ledger effect readback, invoice/order linkage readback, idempotent replay and conflict/refusal no-duplicate/no-write readback, audit readback, fixed-decimal money, `direct_wallet_snapshot_mutation_forbidden=true`, `secret_safe=true`, and `paid_gate_changed=false`. The verifier keeps contract-only TODO-32K as runtime false and will not let synthetic or contract-only artifacts satisfy runtime verification.

E9-CREDIT-29 reviewed TODO-32K runtime implementation feasibility. The runtime is feasible but needs new Control Plane schema/runtime: no durable subscription plan/package/subscription/event tables or invoice/order linkage runtime were found. Reusable primitives are `credit_grants`, `ledger_entries` / admin adjustment markers, `audit_logs`, verified Admin credit-grant CRUD runtime, opening-balance import idempotent transaction/refusal pattern, and the remaining-balance read model. Missing primitives are plan/package schema, subscription state schema, subscription event/schedule rows, invoice/order linkage schema or bounded references, and scheduler/provider callback/dunning hook. The subscription contract artifact now emits `runtime_feasibility_plan` with `runtime_implemented=false`, `contract_only=true`, `new_schema_required=true`, `control_plane_runtime_required=true`, `gateway_change_required=false`, and proposed slices TODO-32K-S1 through S5. This is a plan artifact only, not runtime acceptance.

E9-CREDIT-30 added TODO-32K-S1 Billing Ledger schema contract support without writing a DB migration or implementing runtime. The subscription/package fixture and QA-readable artifact now emit `schema_contract` with schema `subscription_package_lifecycle_schema_contract.v1`, `runtime_implemented=false`, `contract_only=true`, and `paid_gate_changed=false`. It requires `subscription_plans`, `subscription_packages`, `subscriptions`, and `subscription_events_or_schedules` tables with tenant/currency/status/idempotency/audit fields, fixed-decimal money columns, hashed/non-raw idempotency fingerprints, secret-safe metadata/request summaries, and bounded relations to wallets, `credit_grants`, `ledger_entries`, invoice/order ids, and audit rows. It also pins replay, same-key conflict, refusal/no-write, no direct wallet snapshot mutation, and secret-safe invariants. E11/Product still own the actual migration, Control Plane plan/package CRUD, subscription lifecycle runtime, scheduler/provider callback/dunning hook, invoice/order linkage runtime, and QA runtime artifact.

E9-CREDIT-51 assessed TODO-32K-S1 from the Billing Ledger accounting lane after TODO-32J was deferred. `.tmp/credit-wallet/subscription_package_lifecycle_contract.json` remains accepted contract-only evidence, and no `.tmp/credit-wallet/subscription_package_lifecycle_runtime.json` or `artifacts/credit_wallet_subscription_package_lifecycle_runtime.json` exists. Current classification is `deferred_runtime_external_dependency`: contract/schema guardrails are ready and E11-CREDIT-33 now supplies the durable schema migration, but runtime remains false until scheduler/provider/dunning runtime, invoice/order linkage runtime, plan/package and subscription lifecycle readbacks, credit/ledger effect readbacks, idempotency/conflict/refusal no-write readbacks, audit, fixed-decimal money, secret safety, and paid-gate neutrality are proven by a non-contract runtime artifact. TODO-32I remains runtime verified; TODO-32J remains deferred/runtime false.

E9-CREDIT-52 consumed the E11 TODO-32K-S2 schema/defer output from the Billing Ledger accounting lane. Durable migration `db/migrations/0014_subscription_package_lifecycle_boundary.sql` is present and defines `subscription_plans`, `subscription_packages`, `subscriptions`, and `subscription_events_or_schedules` with tenant/currency/status/idempotency/audit metadata, fixed-decimal money, request/metadata summaries, and bounded wallet/credit/ledger/invoice/order/audit links. The E11-side verifier/defer sidecar `.tmp/credit-wallet/subscription_package_lifecycle_runtime_deferred.json` remains safe non-runtime evidence: schema `subscription_package_lifecycle_runtime_deferred.v1`, `overall_status=deferred_runtime_external_dependency`, `actual_exit_code=2`, `runtime_implemented=false`, `contract_only=true`, no route/internal runtime invocation, no scheduler invocation, `secret_safe=true`, and `paid_gate_changed=false`; refreshed schema diagnostics report the required schema present. E9 accounting matrix remains unchanged: runtime cannot be accepted until lifecycle states, plan/package CRUD and subscription readbacks, credit/ledger effect, invoice/order linkage, idempotency/conflict/refusal no-write, audit/reconciliation, fixed-decimal money, secret safety, and paid-gate neutrality are proven by a non-contract `subscription_package_lifecycle_runtime.v1` pass artifact and the main verifier reports `subscription_package_lifecycle_runtime_verified=true`.

E9-LAUNCH-01 added the voucher-backed API distribution accounting gate. New offline verifier `scripts/verify_voucher_backed_api_distribution_accounting_gate.ps1` writes `.tmp/launch/voucher_backed_api_distribution_accounting_gate.json` with schema `voucher_backed_api_distribution_accounting_gate.v1`. Current verdict is `acceptable_with_productization_gaps`: `voucher_runtime_verified=true`, `ledger_or_credit_effect_verified=true`, `remaining_balance_runtime_verified=true`, `credit_grant_crud_runtime_verified=true`, `opening_balance_import_runtime_verified=true`, `gateway_paid_hot_path_present=true`, `real_paid_evidence_bundle_accepted=true`, `direct_wallet_snapshot_mutation_forbidden=true`, `secret_safe=true`, `payment_order_invoice_deferred=true`, and `subscription_lifecycle_deferred=true`. This means voucher/redeem-code quota can be treated as distributable beta credit for API access under the accepted accounting evidence chain. It does not mark payment/order/invoice runtime or subscription/package runtime complete, does not require payment provider/subscription scheduler for this launch target, and does not reopen the paid gate or Gateway implementation.

E9-LAUNCH-02 consumed E8's current Gateway launch blocker into the voucher-backed API distribution decision. `.tmp/launch/gateway_voucher_distribution_readiness.json` and `.tmp/launch/e8_gateway_paid_hot_path_launch_check.json` show the fresh current Gateway paid hot-path launch smoke is blocked: insufficient balance was expected to return HTTP 402/no-provider-call, but current runtime returned provider HTTP 200. E9 did not invalidate accounting evidence; refreshed `.tmp/launch/voucher_backed_api_distribution_accounting_gate.json` now reports `overall_status=blocked_by_gateway_enforcement`, `accounting_verdict=acceptable_with_productization_gaps`, `accounting_credit_acceptable=true`, `api_distribution_launch_ready=false`, `gateway_enforcement_required_for_launch=true`, `gateway_current_enforcement_verified=false`, and `blocks_api_distribution_until_gateway_pass=true`. Remaining launch blocker is `current_paid_live_smoke_insufficient_balance_gate_not_proven`. Resume condition: E8/Gateway must rebuild/restart/fix paid opt-in or balance seed/runtime and rerun the launch paid smoke until insufficient balance returns 402 with provider_attempt_rows=0. TODO-32J and TODO-32K remain deferred/runtime false and are not the blocker for this voucher-backed launch target.

E9-LAUNCH-04 added the launch quota/pricing sanity gate for voucher-backed API distribution. New offline verifier `scripts/verify_voucher_quota_pricing_guardrails.ps1` writes `.tmp/launch/voucher_quota_pricing_guardrails.json` with schema `voucher_quota_pricing_guardrails.v1`. Current artifact reports `overall_status=blocked`, `guardrail_verdict=accounting_credit_acceptable_but_launch_guardrails_or_gateway_blocked`, `launch_ready=false`, and `accounting_credit_acceptable=true`. Guardrail evidence is present for USD fixed-decimal voucher credit effect, user remaining-balance readback, virtual-key profile/binding guardrails via `api_key_profiles` and `virtual_key_profile_bindings`, RPM/TPM rate-limit launch evidence with conservative estimated TPM beta gap, and price-version/model-cost policy selector guards. The only current launch-blocking missing guardrail is `gateway_current_enforcement_not_passed`, passed through from the E8 current paid hot-path smoke. This does not downgrade the accepted accounting credit verdict, does not mark TODO-32J or TODO-32K runtime true, and does not change Gateway code or paid gate state.

E9-CREDIT-25 reviewed TODO-32H runtime contract compatibility for the E11 remaining-balance runtime lane. No fixture/test/writer changes were required: the existing `user_remaining_balance` contract already requires `wallet_id`, tenant/project scope, authenticated user or developer-token ownership proof, wallet scope check, `currency`, decimal-string `available_to_spend`, `wallet_balance_floor`, `active_credit_grant_total`, pending/confirmed ledger window, budget remaining, bounded ledger/grant ids, consistency/staleness/readback marker, read-only/no-write refusal behavior, `secret_safe=true`, and `paid_gate_changed=false`. Admin-readonly runtime evidence is acceptable only as partial/admin-only read-model evidence; full TODO-32H user-facing runtime remains pending until E11/QA prove a user/API endpoint or equivalent user/developer-token scope with endpoint readback. E9 changed docs only and did not modify Gateway, Control Plane runtime, Admin UI, or paid gate.

E11-CREDIT-12 landed TODO-32G-S1 Admin credit grant CRUD first slice: `GET /admin/credit-grants` and `POST /admin/credit-grants` create are implemented in Control Plane/Admin behind existing Admin session/RBAC (`BillingRead` for GET, `BillingAdjust` for POST). Create validates fixed-decimal positive amount, currency, wallet, source, reason, actor fields, optional RFC3339 validity window, and required idempotency key; it uses a secret-safe SHA-256 idempotency fingerprint plus transaction advisory lock, inserts `credit_grants`, writes `credit_grant.create` audit in the same transaction, replays same-key/same-body without a new audit, refuses same-key/different-body as `idempotency_conflict`, refuses wallet/currency mismatch without grant/audit, and never directly mutates wallet balance snapshots. OpenAPI now includes the create/list endpoints and `credit_grant_crud_runtime.v1` response shape. `.tmp/credit-wallet/credit_grant_crud_contract.json` was refreshed as a contract/pass artifact with `control_plane_endpoints_present=true`; no live runtime artifact is claimed yet, and expire/revoke/read-by-id remain TODO-32G-S2/S3. Paid gate unchanged.

Main-thread TODO-32G-S3 live runtime acceptance（2026-06-06）：after rebuilding local Control Plane compose with `POSTGRES_HOST_PORT=55432` and `REDIS_HOST_PORT=56379`, `scripts/verify_credit_grant_crud_runtime.ps1 -RunLiveRouteMatrix` regenerated `.tmp/credit-wallet/credit_grant_crud_runtime.json` as `overall_status=pass`, `runtime_implemented=true`, `contract_only=false`, `route_invoked=true`, `public_route_invoked=true`, `control_plane_runtime_current=true`, and `admin_session_present=true` without echoing the session. The artifact includes grant/audit ids and proves create/list/read/expire/revoke/status/replay/conflict/refusal/audit readback, fixed-decimal money, no direct wallet snapshot mutation, `secret_safe=true`, and `paid_gate_changed=false`. Main verifier selftest and main run pass; `scripts/verify_credit_wallet_ledger_surface.ps1` now reports `credit_grant_crud_runtime_verified=true`, so the old `credit_grant_crud_api_and_audit` gap is closed.

DOC-CREDIT-19 watcher sync (superseded by Main-thread TODO-32F-S8): at that earlier point `.tmp/credit-wallet/opening_balance_import_runtime.json` was blocked and `opening_balance_import_runtime_verified=false`. Current authoritative state is the S8 runtime acceptance above: the artifact is now pass and runtime verified.

QA-CREDIT-09 verified TODO-32F-S1 schema state earlier: `opening_balance_import_schema_verified=true` from `db/migrations/0011_opening_balance_imports.sql`, with required table/columns and unique constraints for `(tenant_id,idempotency_key)` and `(tenant_id,external_source,external_reference_id)`. That schema/contract-only state is superseded by TODO-32F-S8 runtime acceptance: current layered state is `opening_balance_import_artifact_verified=true`, `schema_contract_compatible=true`, `runtime_verified=true`, and `opening_balance_import_runtime_verified=true`.

TODO-32F-runtime minimal DoD：Admin/RBAC before transaction；validate tenant/wallet/project/currency/positive decimal/effective_at/reason/actor/idempotency；lock wallet; read or insert `opening_balance_imports` with unique `(tenant_id,idempotency_key)` and `(tenant_id,external_source,external_reference_id)`；same key + same body returns `replayed` with original ids and no new ledger/audit success row；same key + different body refuses `idempotency_conflict`；duplicate external reference with different key refuses `external_reference_conflict`；new apply writes import row + confirmed admin adjustment/opening ledger entry + audit in one transaction；audit or ledger failure rolls back import/ledger；responses/artifact omit raw import payload, Auth/Cookie material, DB URL, provider key, virtual key, and raw idempotency material. QA artifact must include schema, endpoint, `runtime_implemented=true`, `contract_only=false`, import/ledger-or-admin-adjustment/audit ids, replay/conflict/rollback/readback booleans, fixed-decimal money marker, `secret_safe=true`, and `paid_gate_changed=false`.

Owner：E9 / Billing Ledger for ledger contract and writer mapping；E11 / Control Plane API owner for route/auth/RBAC；Release/Ops for migration artifact review。

Scope：opening balance import apply/replay/refusal only；no Gateway hot-path change；no paid gate change；no external payment/order/invoice implementation。

DOC-CREDIT-11 watcher sync is superseded by TODO-32F-S8: E8 Gateway status remains no dependency for TODO-32F, because Gateway only needs resulting active `credit_grants` and pending/confirmed `ledger_entries` rows in the existing balance window; no `apps/gateway/src/db.rs` change, paid reserve/settle/refund change, Gateway artifact change, or balance formula change is required. Runtime mutation/live DB import/readback is now accepted for TODO-32F via `.tmp/credit-wallet/opening_balance_import_runtime.json`.

Required assumptions：`ledger_entries` supports unique `(tenant_id,idempotency_key)` and adjust/opening metadata；`wallets` is read/locked but not directly mutated as accounting fact；`audit_logs` stores actor/action/resource/reason/import id；optional `opening_balance_imports` table should uniquely bind `(tenant_id,idempotency_key)` and `(tenant_id,external_source,external_reference_id)`。

Policy：positive opening amount maps to admin adjustment/opening ledger entry; same idempotency key/body replays; same key different amount/currency/wallet/source/reference refuses; duplicate external reference with different key refuses unless replaying same accepted import; every outcome is audit-safe. Refusal taxonomy includes `idempotency_conflict`, `external_reference_conflict`, `wallet_not_found`, `wallet_currency_mismatch`, `non_positive_opening_amount`, `direct_wallet_snapshot_mutation_forbidden`, `audit_write_failed_rolled_back`, `ledger_write_failed_rolled_back`, `opening_import_schema_unavailable`。

### DOC-CREDIT-03：DOCX 对齐与商业产品缺口

中文状态：当前系统有 credit-like 底座，包括 wallet/credit_grants/ledger primitives、Admin adjustment/readback 方向、已被主线程接受的 controlled paid beta evidence、已 runtime verified 的 New API/One API opening-balance import、已 runtime verified 的 Admin credit grant CRUD/audit、已 verified 的 Admin-readonly remaining-balance read model、已 verified 的 user-session ownership scoped remaining-balance runtime，以及已 verified 的 TODO-32I recharge/voucher internal Rust/sqlx runtime。仍未形成完整可销售 credit 产品闭环：recharge/voucher public route/product UX/payment-provider packaging、payment/order/invoice、subscription/package lifecycle 仍未完成；developer-token live matrix/UI/product polish 可作为后续硬化项。

DOCX alignment：`.tmp/docx_ai_gateway_text.txt` 将产品目标定位为兼容 New API/One API 迁移的生产级 LLM Gateway / AI Control Plane，并把用户额度、余额、运营后台、充值/兑换码/发票、迁移导入报告和 opening ledger 作为产品目标信号。TODO-32 方向与该目标一致，但 DOC-CREDIT-03 明确这些商业闭环仍是 P1/backlog，不得夸大为已完成。

TODO-32D backlog split lives in `docs/todo/slices/TODO-32-CREDIT-WALLET.md`. After TODO-32F/G/H runtime verification and DOC-CREDIT-56 TODO-32I internal Rust/sqlx runtime verification, the remaining explicit productization runtime slices are TODO-32J payment/order/invoice runtime and TODO-32K subscription/package lifecycle runtime. TODO-32I public route/product UX/payment-provider packaging remains follow-up polish, not a verifier blocker. These are not controlled paid beta blockers and do not roll back `paid_controlled_beta_allowed=true`.

### QA-CREDIT-01：Credit-Wallet-Ledger Evidence Contract Audit（2026-06-05）

本节只审计 QA 证据，不改变 Gateway/E9/E11 业务实现，也不回退 `paid_controlled_beta_allowed=true`。

```json
{
  "task_id": "QA-CREDIT-01",
  "lane": "QA",
  "status": "pass_with_productization_gaps",
  "changed_files": [
    "scripts/verify_credit_wallet_ledger_surface.ps1",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "commands_run": [
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_credit_wallet_ledger_surface.ps1 -SelfTest", "exit_code": 0, "classification": "pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_credit_wallet_ledger_surface.ps1", "exit_code": 0, "classification": "pass_with_productization_gaps"}
  ],
  "acceptance_results": {
    "schema_checks": "wallets/credit_grants/ledger_entries/balance_floor/remaining_amount/valid_from/valid_until/status/source present",
    "runtime_checks": "Gateway balance window reads wallets + active credit_grants + ledger_entries; paid smoke seeds wallet/credit fixture",
    "paid_artifact_checks": "E8 passed; E11 passed; real paid evidence bundle production_ready=true",
    "underlying_credit_balance_capability": "present_verified",
    "user_recharge_redeem_package_invoice": "not_productized",
    "new_api_one_api_balance_import": "runtime_verified",
    "controlled_paid_beta_status_preserved": true
  },
  "blockers": [],
  "remaining_gaps": [
    "user_facing_remaining_balance_api_runtime",
    "payment_order_invoice_lifecycle_runtime",
    "subscription_plan_lifecycle_runtime"
  ],
  "next_task": "Product/API owner scopes TODO-32J payment/order/invoice and TODO-32K subscription/package lifecycle runtime, plus TODO-32I public route/product UX polish, without reopening controlled paid beta evidence."
}
```

### DOC-CREDIT-24：TODO-32F verified 后 backlog re-prioritization

TODO-32F opening-balance import is complete / runtime verified and is no longer a remaining blocker. Current accepted evidence: `.tmp/credit-wallet/opening_balance_import_runtime.json` has `overall_status=pass`, `runtime_implemented=true`, `contract_only=false`, `route_invoked=true`, `internal_sqlx_function_invoked=true`, live DB readback, replay/refusal/rollback readback, `secret_safe=true`, and `paid_gate_changed=false`; `scripts/verify_credit_wallet_ledger_surface.ps1` reports `opening_balance_import_runtime_verified=true` and `new_api_one_api_balance_import=runtime_verified`.

| Slice | Owner | Blocking level | Acceptance artifact / DoD | Current status |
| --- | --- | --- | --- | --- |
| TODO-32G Credit Grant CRUD/Audit | E11 Control Plane + E9 Billing Ledger + QA | runtime verified; not a controlled paid beta blocker | `.tmp/credit-wallet/credit_grant_crud_runtime.json` or `artifacts/credit_wallet_credit_grant_crud_runtime.json`, schema `credit_grant_crud_runtime.v1`, create/list/expire/revoke cases, idempotent replay/conflict, ledger/grant readback, audit ids, `secret_safe=true`, `paid_gate_changed=false`, QA accepted. Contract guard path: `.tmp/credit-wallet/credit_grant_crud_contract.json`. | Main-thread S3 live route matrix artifact is `overall_status=pass`, `runtime_implemented=true`, `contract_only=false`, route/current/Admin session verified, grant/audit ids present, create/list/read/expire/revoke/status/replay/conflict/refusal/audit readback true; verifier reports `credit_grant_crud_runtime_verified=true`. Remaining work is product polish/UI/runbook, not runtime acceptance. |
| TODO-32H User-facing Remaining Balance API | E11 Control Plane User API + E9 read model contract + QA | P1 product UX blocker; full user-session ownership runtime verified; not a controlled paid beta blocker | `.tmp/credit-wallet/user_remaining_balance_runtime.json`, schema `user_remaining_balance_runtime.v1`, Admin/BillingRead route readback, decimal-string `available_to_spend`, active grant totals, pending/confirmed ledger window, staleness/readback marker, bounded ledger/grant ids, `read_only=true`, `secret_safe=true`, `paid_gate_changed=false`, QA accepted as admin-readonly runtime. Full user-session guard path artifact: `.tmp/credit-wallet/user_remaining_balance_ownership_runtime.json`, schema `user_remaining_balance_runtime.v1`, `runtime_implemented=true`, `contract_only=false`, `route_invoked=true`, `user_api_runtime=true`, `ownership_scope_verified=true`, `auth_source=control_plane_user_session`, `secret_safe=true`, and `paid_gate_changed=false`. Ownership-plan guard path: `.tmp/credit-wallet/user_remaining_balance_ownership_plan.json`. Contract guard path: `.tmp/credit-wallet/user_remaining_balance_contract.json`. | E11-CREDIT-15 added `GET /billing/wallets/{wallet_id}/remaining-balance` behind existing Admin/BillingRead session boundary and generated `.tmp/credit-wallet/user_remaining_balance_runtime.json` with `overall_status=pass`, `runtime_implemented=true`, `contract_only=false`, `admin_readonly_runtime=true`, `user_api_runtime=false`, wallet/credit-grant/ledger/refusal readback true, `secret_safe=true`, and `paid_gate_changed=false`; verifier reports `user_remaining_balance_admin_readonly_runtime_verified=true`. E11-CREDIT-16 reviewed Control Plane auth, E11-CREDIT-17 added the bounded auth contract, E11-CREDIT-18 confirmed resolver feasibility without a new migration, and E11-CREDIT-19 added minimal `RemainingBalancePrincipal` code wiring through `user_sessions -> users -> project_members -> wallets` plus developer-token SQL skeletons. E11-CREDIT-20 rebuilt current Control Plane runtime after stale-image rejection and generated `.tmp/credit-wallet/user_remaining_balance_ownership_runtime.json` with server-side session/project-membership/wallet/credit/ledger/refusal readback true and `missing_session_rejected=true`; verifier reports full `user_remaining_balance_runtime_verified=true`. |
| TODO-32I Recharge/Voucher | Product + E11 Control Plane + E9 Billing Ledger + Security/Abuse + QA | Runtime verified by internal Rust/sqlx business path; public route/product UX still follow-up; not a controlled paid beta blocker | `.tmp/credit-wallet/recharge_voucher_runtime.json`, schema `recharge_voucher_runtime.v1`, `overall_status=pass`, runtime invocation, recharge/top-up intent, voucher issuance/redeem/replay/expiry/revoke, hashed/redacted code readback, abuse/refusal no-write readback, ledger/credit effect, refund/cancel reversal, audit ids, secret-safe code handling, `paid_gate_changed=false`, QA/main verifier accepted. Contract guard path: `.tmp/credit-wallet/recharge_voucher_contract.json`, schema `recharge_voucher_contract.v1`, with `runtime_feasibility_plan`. Plan guard path: `.tmp/credit-wallet/recharge_voucher_runtime_plan.json`, schema `recharge_voucher_runtime_plan.v1`. Schema/OpenAPI boundary: `db/migrations/0012_recharge_voucher_boundary.sql` and `examples/openapi_admin_skeleton.yaml`. | DOC-CREDIT-56: main verifier reports `recharge_voucher_runtime_verified=true`; artifact has `runtime_implemented=true`, `contract_only=false`, internal Rust/sqlx business path invocation true, voucher storage/code-hash/redaction, redeem/idempotency, abuse/refusal no-write, ledger-or-credit effect, refund/cancel reversal, and audit readbacks accepted, `secret_safe=true`, `paid_gate_changed=false`. Public route/product UX and broader commercial polish remain follow-up. |
| TODO-32J Payment/Order/Invoice | Product + Finance/Ops + E11 Control Plane + E9 Billing Ledger + QA | P1 commercial launch blocker; deferred_runtime_external_dependency; E9 contract-ready + schema boundary present; not complete and not a release pass | Resume only when provider/callback/capture capability or an approved bounded internal simulation policy is available, then produce `.tmp/credit-wallet/payment_order_invoice_runtime.json` or `artifacts/credit_wallet_payment_order_invoice_runtime.json`, schema `payment_order_invoice_runtime.v1`, with runtime invocation, order/payment lifecycle persistence, provider handoff/callback redaction, capture/refund/cancel/chargeback readback, invoice/receipt ids, tax/currency policy, reconciliation, failure retry/chargeback handling, operator readback, `secret_safe=true`, `paid_gate_changed=false`, and QA/main verifier acceptance. Contract guard path: `.tmp/credit-wallet/payment_order_invoice_contract.json`, schema `payment_order_invoice_contract.v1`. | E9-CREDIT-23 contract artifact ready (`status=pass`, `runtime_implemented=false`, `contract_only=true`, `paid_gate_changed=false`, `secret_safe=true`) and schema boundary is present. E9-CREDIT-50 / E11-CREDIT-31-DEFER records runtime defer because the external payment runtime/provider callback/capture capability, or approved bounded internal simulation policy, is not available. Current verifier remains `payment_order_invoice_contract_verified=true` and `payment_order_invoice_runtime_verified=false`; this is not controlled paid beta expansion. |
| TODO-32K Subscription/Package Lifecycle | Product + E11 Control Plane + E9 Billing Ledger + QA | P1/P2 recurring package blocker; schema migration present; `deferred_runtime_external_dependency`; runtime false; not complete and not a release pass | Resume only when scheduler/renewal trigger, trial/proration/dunning policy, invoice/order linkage runtime, credit/ledger effect readback, cancel/pause/resume readback, idempotency/conflict/no-write readback, audit/reconciliation readback, and QA/main accepted `.tmp/credit-wallet/subscription_package_lifecycle_runtime.json` or `artifacts/credit_wallet_subscription_package_lifecycle_runtime.json` pass artifact exist. Contract guard path: `.tmp/credit-wallet/subscription_package_lifecycle_contract.json`, schema `subscription_package_lifecycle_contract.v1`, with schema contract `subscription_package_lifecycle_schema_contract.v1`. | E9-CREDIT-24 contract artifact ready (`status=pass`, `runtime_implemented=false`, `contract_only=true`, `paid_gate_changed=false`, `secret_safe=true`); E9-CREDIT-30 prepared schema contract support; E11-CREDIT-33 adds durable schema migration `db/migrations/0014_subscription_package_lifecycle_boundary.sql`. E9-CREDIT-51 / QA-CREDIT-67 / DOC-CREDIT-61 classify the lane as `deferred_runtime_external_dependency`; `.tmp/credit-wallet/subscription_package_lifecycle_runtime_deferred.json` is non-runtime defer evidence. Current verifier remains `subscription_package_lifecycle_contract_verified=true` and `subscription_package_lifecycle_runtime_verified=false`; paid gate unchanged. |

### 当前已有 primitives

Billing-ledger crate 已有底层账务与强一致写入 primitive，但它们还不是完整 credit 产品：

- Wallet snapshot：`ConsistentWalletSnapshot { wallet_id, currency, available_balance }` 作为 writer state 输入；余额窗口按 fixed decimal 计算，不使用 float。
- Credit grants snapshot：`ConsistentCreditGrantSnapshot { grant_id, currency, remaining_amount, active }`，writer balance window 会把 active grants 纳入 `wallet_available_balance + active_credit_grants + active_pending_or_confirmed_ledger`。
- Budget lock/check：`ConsistentBudgetSnapshot` 覆盖 tenant/project/virtual_key dimensions；writer lock order 固定为 wallets -> credit_grants -> budgets -> ledger_entries，预算不足保守拒绝。
- Ledger adjustments/refunds：`AdminAdjustmentLedgerRequest` 支持 confirmed credit/debit adjustment；`RefundLedgerRequest::{Full, Partial}` 支持 against settled debit 的 confirmed credit，并有 canonical idempotency key。
- Consistent writer：`ConsistentLedgerWriteRequest::{Reserve, Settle, RefundFull, RefundPartial, AdminAdjustment}` 通过 wallet/grant/budget/ledger state 生成 lock plan、balance window、budget checks、ledger plan、Postgres command contract 与 secret-safe summary。

### QA-CREDIT-02：Credit Surface Gate Watcher（2026-06-05）

E9-CREDIT-02 已产出 contract-only draft，QA verifier 已补只读 contract surface checks；E11-CREDIT-02 已补 Admin OpenAPI read-only wallet/credit contract，E11-CREDIT-02R 已落地 Control Plane runtime handlers，但尚未产生 live Admin endpoint readback artifact，未改变 paid gate。

```json
{
  "task_id": "QA-CREDIT-02",
  "lane": "QA",
  "status": "pass_with_productization_gaps",
  "changed_files": [
    "scripts/verify_credit_wallet_ledger_surface.ps1",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "commands_run": [
    {"command": "rg -n \"E11-CREDIT-02|E9-CREDIT-02|QA-CREDIT-02|credit.*endpoint|credit.*contract|credit_grant.*contract|remaining balance|remaining_balance|recharge|voucher|redeem\" TODO docs project artifacts .tmp scripts tests apps crates -S", "exit_code": 0, "classification": "contract_draft_found"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_credit_wallet_ledger_surface.ps1 -SelfTest", "exit_code": 0, "classification": "pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_credit_wallet_ledger_surface.ps1", "exit_code": 0, "classification": "pass_with_productization_gaps"}
  ],
  "acceptance_results": {
    "e9_credit_02_contract_path": "docs/todo/slices/TODO-32-CREDIT-WALLET.md",
    "credit_wallet_contract_status": "draft_contract_verified",
    "checked_contract_endpoints": [
      "POST /billing/credit-grants",
      "GET /billing/credit-grants",
      "POST /billing/credit-grants/{credit_grant_id}/expire",
      "POST /billing/credit-grants/{credit_grant_id}/revoke",
      "GET /billing/wallets/{wallet_id}/remaining-balance",
      "POST /billing/opening-balance-imports",
      "POST /billing/admin-adjustments"
    ],
    "implemented_runtime_surface": false,
    "paid_gate_changed": false
  },
  "blockers": [],
  "remaining_gaps": [
    "E11-CREDIT-02R read-only Admin wallet/credit runtime handlers present; live endpoint/readback artifact not found",
    "credit wallet contract remains draft/spec only",
    "Admin UI/API live readback and commercial mutation flows remain TODO-32 work"
  ],
  "next_task": "When E11-CREDIT-02R live Admin endpoint/readback artifact lands, extend the same verifier with endpoint readback checks."
}
```

### QA-CREDIT-03 / TODO-32C：Verifier expansion（2026-06-05）

本节扩展 QA verifier 的分层状态输出，不改 Gateway/E9/E11 business implementation，不改变 paid final acceptance。

```json
{
  "task_id": "QA-CREDIT-03",
  "parent_task_id": "TODO-32C",
  "lane": "QA",
  "status": "pass_with_productization_gaps",
  "changed_files": [
    "scripts/verify_credit_wallet_ledger_surface.ps1",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "commands_run": [
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_credit_wallet_ledger_surface.ps1 -SelfTest", "exit_code": 0, "classification": "pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_credit_wallet_ledger_surface.ps1", "exit_code": 0, "classification": "pass_with_productization_gaps"}
  ],
  "new_output_fields": {
    "draft_contract_verified": true,
    "admin_readonly_openapi_contract_verified": true,
    "admin_readonly_runtime_verified": false,
    "admin_readonly_runtime_handlers_present": true,
    "billing_mutation_contract_verified": true,
    "billing_mutation_artifact_verified": false,
    "product_commercial_flows_not_implemented": true
  },
  "watcher_results": {
    "e11_credit_02r_runtime_artifact": "blocked_unit_only_artifact_present_live_readback_absent",
    "e9_credit_03_mutation_test_artifact": "absent_noop"
  },
  "paid_gate_changed": false,
  "remaining_gaps": [
    "Admin read-only OpenAPI contract and Control Plane runtime handlers are present; unit-only artifact exists but live endpoint/readback remains blocked.",
    "Billing mutation contract is verified from TODO-32 draft, but E9-CREDIT-03 mutation tests/artifact are absent.",
    "Recharge/voucher/payment/order/invoice/subscription and New API balance import apply/rollback remain not implemented."
  ],
  "next_task": "Regenerate E11-CREDIT-02R artifact from a valid Admin session and current Control Plane runtime so QA can mark live endpoint readback verified without reopening paid gate."
}
```

### TODO-32E：Gateway impact watch（2026-06-05）

E8 复核 `docs/todo/slices/TODO-32-CREDIT-WALLET.md` 与 Gateway paid hot path 后，结论为 `status=no_runtime_change_needed`。Gateway 当前已经在 pre-authorize 和 paid reserve balance window 中消费现有 active `credit_grants` rows：要求 tenant/wallet/currency scope、`status='active'`、`valid_from <= now()`、`valid_until is null or valid_until > now()`，并把 active grant amount + pending/confirmed ledger window - `wallet.balance_floor` 作为保守可用余额；reserve transaction lock order 已固定为 wallet -> active credit_grants -> ledger rows -> insert。

Gateway 不需要知道 recharge、voucher、payment、order、invoice、credit grant CRUD、opening-balance import 或 user-facing remaining-balance API；这些属于 TODO-32A/B/D 的 Control Plane/Admin/Billing productization。Gateway paid reserve/settle/refund hot path 本轮无需修改，accepted paid artifacts 保持不变。若后续 TODO-32 runtime contract 明确要求 Gateway 额外输出 balance summary/readback alias，应作为单独 bounded Gateway contract patch 处理，不应扩大到商业充值或 credit lifecycle 实现。

E8-CREDIT-04 watcher after TODO-32A/B：扫描 `TODO-32A|TODO-32B|E11-CREDIT-02R|E9-CREDIT-03|remaining-balance|credit_grants` 后，未发现新的 Gateway-facing mismatch。现有 E11/E9 记录仍是 Control Plane/Admin/Billing productization 或 runtime writer/read-only surface；Gateway 仍只依赖有效 active `credit_grants` rows being present/valid，不需要改 paid reserve/settle/refund hot path，也不需要新增 Gateway artifact/balance summary alias。

E8-CREDIT-05 final no-regression watcher：扫描 `billing_mutation_contract_tests|admin_readonly_runtime|remaining_balance|credit_grants|Gateway` 后，未发现 Gateway hot path requirement。E9-CREDIT-04 artifact `.tmp/credit-wallet/billing_mutation_contract_tests.json` is `schema=billing_mutation_contract_tests.v1` / `status=pass` with `runtime_writer_changed=false`、`paid_gate_changed=false`、`secret_safe=true`；QA verifier changes remain credit productization/readback classification；E11-CREDIT-02R remains Control Plane read-only wallet/credit runtime surface. Gateway balance formula、`credit_grants` status semantics、paid reserve/settle/refund hot path、and accepted paid artifacts remain unchanged.

E8-CREDIT-06 TODO-32F impact watch：扫描 `TODO-32F|opening-balance|opening_balance_import|credit_grants|ledger_entries|balance window` 后，未发现 Gateway-facing requirement。TODO-32F/E9-CREDIT-05 opening-balance import is scoped to writing ledger/admin adjustment/opening-entry rows and optional import idempotency/audit records; Gateway only needs those resulting rows to exist. Current Gateway pre-authorize/reserve continues to read active `credit_grants` plus pending/confirmed `ledger_entries` and subtract `wallet.balance_floor`; no `apps/gateway/src/db.rs` change, no paid reserve/settle/refund change, no Gateway artifact change, and no balance formula change is needed.

E8-CREDIT-25 TODO-32H user-facing remaining balance impact plan：Gateway review concluded `gateway_impact=false` and `implemented_scope_or_plan=control_plane_user_api_plan`. User-facing remaining balance should be implemented as a Control Plane User/API or Admin/API read-only surface with explicit tenant/project/user or developer-token ownership scope, not as a Gateway endpoint. Gateway has only model data-plane routing/virtual-key auth and should not disclose wallet balances without a separate auth contract. The minimal TODO-32H slice should reuse the Control Plane wallet/credit/ledger read model and return decimal-string `available_to_spend`, active credit grant totals, pending/confirmed ledger window, `wallet.balance_floor`, staleness/readback marker, bounded ledger/grant ids, and `secret_safe=true`. TODO-32F runtime acceptance requires no Gateway change: opening imports materialize ledger rows; future credit grant CRUD should materialize `credit_grants` and/or `ledger_entries`; Gateway continues to consume `credit_balance.amount + ledger_balance.amount - w.balance_floor`.

E8-CREDIT-28 Gateway credit-balance diff impact audit：current dirty Gateway files (`apps/gateway/src/db.rs`, `apps/gateway/src/main.rs`, `apps/gateway/src/streaming.rs`, `apps/gateway/src/tpm_estimate.rs`) were audited for TODO-32 credit/wallet and paid hot-path impact. Result：`gateway_impact=false`, `paid_hot_path_changed=false` for this audit, `paid_gate_changed=false`, and `TODO-32H remains control-plane-owned`. Evidence：pre-authorize still gates before provider attempts/provider-key opening/upstream calls; insufficient balance still returns `billing_insufficient_balance` before provider side effects; Gateway balance SQL remains active `credit_grants` plus pending/confirmed `ledger_entries` minus `wallet.balance_floor`; reserve/settle/refund idempotency tests pass; Gateway still does not read `opening_balance_imports`.

### DOC-CREDIT-04：TODO-32 sync watcher（2026-06-05）

Watcher result: status synced, no code or paid-gate changes. Inputs observed:

- `QA-CREDIT-03` / TODO-32C verifier expansion is accepted in `docs/P0_BETA_STATUS.md`: verifier now separates `draft_contract_verified=true`, `admin_readonly_openapi_contract_verified=true`, `admin_readonly_runtime_verified=false`, `billing_mutation_contract_verified=true`, and `product_commercial_flows_not_implemented=true`. E11-CREDIT-02R now adds runtime handlers, but live verifier status remains false until an endpoint/readback artifact is produced.
- `E11-CREDIT-02R` unit-only blocked artifact is present, but no live runtime endpoint/readback pass artifact is present; TODO-32A is runtime implemented / live readback pending.
- No `E9-CREDIT-03` mutation test artifact is present; TODO-32B remains mutation-test pending despite contract verification.
- `E8-CREDIT-04` is accepted in `docs/todo/slices/E8-004.md` as `no_gateway_mismatch_found`; TODO-32E is complete/no-op for Gateway and does not require paid hot-path changes.

Synchronized slice status in `docs/todo/slices/TODO-32-CREDIT-WALLET.md`: TODO-32A runtime implemented/live readback pending; TODO-32B mutation contract verified/E9-CREDIT-03 artifact pending; TODO-32C accepted verifier expansion/pass_with_productization_gaps; TODO-32D refined backlog complete/implementation pending; TODO-32E completed no-op/no_gateway_mismatch_found. `paid_controlled_beta_allowed=true` remains unchanged.

### QA-CREDIT-04：Artifact watcher after E11-CREDIT-02R and E9-CREDIT-03（2026-06-05）

Default watcher result: no verifier code expansion required because the strict QA artifact paths are absent. E9-CREDIT-03 code test/fixture is present, but without a QA-consumable artifact it remains `billing_mutation_artifact_verified=false`.

```json
{
  "task_id": "QA-CREDIT-04",
  "lane": "QA",
  "status": "no_artifact_noop",
  "changed_files": [
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "artifact_found": {
    ".tmp/credit-wallet/admin_readonly_wallet_credit_runtime.json": false,
    "artifacts/credit_wallet_admin_readonly_runtime.json": false,
    ".tmp/credit-wallet/billing_mutation_contract_tests.json": false,
    "artifacts/credit_wallet_billing_mutation_contract_tests.json": false
  },
  "observed_non_artifact_evidence": {
    "e9_credit_03_code_test": "tests/fixtures/billing/credit_wallet_productization_contract.json and crates/billing-ledger/tests/credit_wallet_productization_contract.rs present",
    "artifact_verified": false
  },
  "verifier_state": {
    "admin_readonly_runtime_verified": false,
    "billing_mutation_artifact_verified": false,
    "paid_gate_changed": false
  },
  "suggested_future_artifact_shape": {
    "admin_runtime": ["overall_status=pass", "secret_safe=true", "read_only=true", "money_decimal_strings=true", "raw_secret_markers_present=false", "paid_gate_changed=false"],
    "billing_mutation": ["overall_status=pass", "secret_safe=true", "contract_only=true", "money_decimal_strings=true", "direct_wallet_snapshot_mutation_allowed=false", "raw_secret_markers_present=false", "paid_gate_changed=false"]
  },
  "next_task": "E11-CREDIT-02R or E9-CREDIT-03 should write one of the four QA-consumable JSON artifacts, then QA can extend strict verifier checks if needed."
}
```

### QA-CREDIT-05：Consume E9 billing mutation artifact（2026-06-05）

E9-CREDIT-04 has written `.tmp/credit-wallet/billing_mutation_contract_tests.json`; QA verifier now consumes and validates it as a machine-readable mutation contract artifact. Admin read-only runtime remains unverified until E11-CREDIT-02R writes a runtime/readback artifact.

```json
{
  "task_id": "QA-CREDIT-05",
  "lane": "QA",
  "status": "pass_with_productization_gaps",
  "changed_files": [
    "scripts/verify_credit_wallet_ledger_surface.ps1",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "artifact_path": ".tmp/credit-wallet/billing_mutation_contract_tests.json",
  "artifact_checks": {
    "schema": "billing_mutation_contract_tests.v1",
    "status": "pass",
    "money_decimal_strings": true,
    "idempotency_contract": true,
    "direct_wallet_snapshot_mutation_forbidden": true,
    "secret_safe": true,
    "runtime_writer_changed": false,
    "paid_gate_changed": false,
    "invariants_enforced": ["accounting", "idempotency", "secret_safe", "direct_wallet_snapshot_mutation_forbidden"]
  },
  "verifier_state": {
    "billing_mutation_artifact_verified": true,
    "admin_readonly_runtime_verified": false,
    "product_commercial_flows_not_implemented": true,
    "paid_gate_changed": false
  },
  "commands_run": [
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_credit_wallet_ledger_surface.ps1 -SelfTest", "exit_code": 0, "classification": "pass"},
    {"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_credit_wallet_ledger_surface.ps1", "exit_code": 0, "classification": "pass_with_productization_gaps"}
  ],
  "remaining_gaps": [
    "E11-CREDIT-02R Admin read-only runtime/readback artifact absent.",
    "Credit product runtime/API implementation remains pending.",
    "Recharge/voucher/payment/order/invoice/subscription and New API balance import apply/rollback remain not implemented."
  ],
  "next_task": "Wait for E11-CREDIT-02R live Admin endpoint/readback pass artifact, then verify read_only runtime markers without changing paid final acceptance."
}
```

### DOC-CREDIT-05：TODO-32 sync watcher after QA-CREDIT-05（2026-06-05）

Watcher result: synced QA artifact status, no code or paid-gate changes.

- TODO-32B now has QA-consumed billing mutation artifact evidence: `.tmp/credit-wallet/billing_mutation_contract_tests.json`, schema `billing_mutation_contract_tests.v1`, `status=pass`, fixed-decimal/idempotency/direct-wallet-mutation-forbidden/secret-safe checks true, `runtime_writer_changed=false`, `paid_gate_changed=false`.
- TODO-32C verifier status now includes `billing_mutation_artifact_verified=true`; `admin_readonly_runtime_verified=false` remains unchanged.
- TODO-32A remains runtime implemented / live readback pending. `.tmp/credit-wallet/admin_readonly_wallet_credit_runtime.json` is present but blocked/unit-only with `admin_readonly_runtime_verified=false`; `artifacts/credit_wallet_admin_readonly_runtime.json` is still absent.

Synchronized slice status in `docs/todo/slices/TODO-32-CREDIT-WALLET.md`: TODO-32B `mutation artifact verified by QA-CREDIT-05 / runtime API pending`; TODO-32C `accepted verifier expansion / billing mutation artifact verified`; TODO-32A unchanged as live readback pending. `paid_controlled_beta_allowed=true` remains unchanged.

### QA-CREDIT-06 / TODO-32F：Verifier planning and artifact contract（2026-06-05）

QA verifier now has explicit opening-balance import layering. This is a planning/artifact-contract update only; it does not implement runtime import and does not change controlled paid beta.

```json
{
  "task_id": "QA-CREDIT-06",
  "parent_task_id": "TODO-32F",
  "lane": "QA",
  "status": "pass_with_productization_gaps",
  "changed_files": [
    "scripts/verify_credit_wallet_ledger_surface.ps1",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "new_fields": {
    "opening_balance_import_contract_verified": true,
    "opening_balance_import_runtime_verified": false,
    "opening_balance_import_artifact_verified": false
  },
  "artifact_contract_paths": [
    ".tmp/credit-wallet/opening_balance_import_contract.json",
    "artifacts/credit_wallet_opening_balance_import.json"
  ],
  "artifact_contract_shape": {
    "schema": "opening_balance_import_contract.v1",
    "status": "pass",
    "secret_safe": true,
    "money_decimal_strings": true,
    "idempotency_contract": true,
    "opening_ledger_entry_required": true,
    "direct_wallet_snapshot_mutation_forbidden": true,
    "paid_gate_changed": false,
    "runtime_implemented": "boolean marker; true only for real runtime/readback evidence"
  },
  "current_result": {
    "contract_verified": true,
    "runtime_verified": false,
    "artifact_verified": false,
    "paid_gate_changed": false
  },
  "selftest_coverage": [
    "positive opening-balance artifact accepted",
    "missing artifact not verified",
    "secret unsafe rejected",
    "paid_gate_changed rejected",
    "direct wallet mutation allowed rejected",
    "runtime false when runtime_implemented=false"
  ],
  "remaining_gaps": [
    "No opening-balance import runtime/readback artifact is present.",
    "New API / One API balance import apply/rollback runner remains unimplemented.",
    "Commercial recharge/voucher/payment/order/invoice/subscription flows remain unimplemented."
  ],
  "next_task": "E9/E11 TODO-32F implementation should write one of the two opening-balance import artifacts, then QA can consume it without reopening paid gate."
}
```

### QA-CREDIT-07：Consume TODO-32F E9/E11 artifacts when available（2026-06-05）

Watcher result: E11 OpenAPI/API skeleton for opening-balance import is present, but the required E9/E11 JSON artifacts are still absent. QA verifier now distinguishes API contract presence from artifact/runtime verification.

```json
{
  "task_id": "QA-CREDIT-07",
  "parent_task_id": "TODO-32F",
  "lane": "QA",
  "status": "api_contract_present_artifact_absent",
  "changed_files": [
    "scripts/verify_credit_wallet_ledger_surface.ps1",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "artifact_found": {
    ".tmp/credit-wallet/opening_balance_import_contract.json": false,
    "artifacts/credit_wallet_opening_balance_import.json": false
  },
  "verifier_state": {
    "opening_balance_import_contract_verified": true,
    "opening_balance_import_api_contract_present": true,
    "opening_balance_import_artifact_verified": false,
    "opening_balance_import_runtime_verified": false,
    "paid_gate_changed": false
  },
  "api_contract_evidence": {
    "path": "examples/openapi_admin_skeleton.yaml",
    "endpoint": "/billing/opening-balance-imports",
    "operation_id": "createOpeningBalanceImport",
    "contract_only_runtime": true,
    "requires_opening_ledger_or_admin_adjustment": true,
    "direct_wallet_snapshot_mutation_forbidden": true
  },
  "next_task": "TODO-32F-runtime should implement the live opening-balance import mutation/readback, then write .tmp/credit-wallet/opening_balance_import_contract.json or artifacts/credit_wallet_opening_balance_import.json only after ledger/admin-adjustment/audit/idempotency readback succeeds."
}
```

### QA-CREDIT-08：Consume verified opening-balance import artifact（2026-06-05）

E9-CREDIT-07 artifact is now QA-consumed. This verifies the opening-balance import contract artifact only; runtime implementation remains false.

```json
{
  "task_id": "QA-CREDIT-08",
  "parent_task_id": "TODO-32F",
  "lane": "QA",
  "status": "artifact_verified_runtime_pending",
  "changed_files": [
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "artifact_path": ".tmp/credit-wallet/opening_balance_import_contract.json",
  "verifier_state": {
    "opening_balance_import_artifact_verified": true,
    "opening_balance_import_runtime_verified": false,
    "opening_balance_import_api_contract_present": true,
    "paid_gate_changed": false
  },
  "artifact_summary": {
    "schema": "opening_balance_import_contract.v1",
    "status": "pass",
    "secret_safe": true,
    "money_decimal_strings": true,
    "idempotency_contract": true,
    "opening_ledger_entry_required": true,
    "direct_wallet_snapshot_mutation_forbidden": true,
    "runtime_implemented": false
  },
  "remaining_gaps": [
    "Opening-balance import runtime/API apply path is not implemented.",
    "No live DB/readback artifact proves import apply/replay/refusal.",
    "New API / One API balance import apply/rollback runner remains unimplemented."
  ],
  "next_task": "E11/E9 TODO-32F runtime implementation should produce a runtime_implemented=true readback artifact before QA marks runtime verified."
}
```

### QA-CREDIT-09 / TODO-32F-S1：Opening-balance import schema verifier watch（2026-06-05）

QA verifier now checks the `opening_balance_imports` schema surface independently from contract artifact and runtime implementation. Current schema verification is true because `db/migrations/0011_opening_balance_imports.sql` is present and contains the required table, columns, and uniqueness constraints; runtime verification remains false until live apply/replay/refusal/readback evidence is produced.

```json
{
  "task_id": "QA-CREDIT-09",
  "parent_task_id": "TODO-32F-S1",
  "lane": "QA",
  "status": "schema_verified_runtime_pending",
  "changed_files": [
    "scripts/verify_credit_wallet_ledger_surface.ps1",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "schema_checks": {
    "table": "opening_balance_imports",
    "required_columns": [
      "tenant_id",
      "wallet_id",
      "currency",
      "opening_amount",
      "external_source",
      "external_reference_id",
      "idempotency_key",
      "status",
      "ledger_entry_id",
      "audit_id",
      "created_at",
      "updated_at"
    ],
    "required_unique_constraints": [
      "tenant_id + idempotency_key",
      "tenant_id + external_source + external_reference_id"
    ]
  },
  "verifier_state": {
    "opening_balance_import_schema_verified": true,
    "opening_balance_import_artifact_verified": true,
    "opening_balance_import_api_contract_present": true,
    "opening_balance_import_runtime_verified": false,
    "paid_gate_changed": false
  },
  "selftest_coverage": [
    "opening_balance_import_schema_positive_verified",
    "opening_balance_import_schema_missing_external_unique_rejected"
  ],
  "remaining_gaps": [
    "Opening-balance import runtime/API apply path is not implemented.",
    "No live DB/readback artifact proves import apply/replay/refusal.",
    "New API / One API balance import apply/rollback runner remains unimplemented."
  ],
  "next_task": "E11/E9 TODO-32F runtime implementation should produce a runtime_implemented=true readback artifact before QA marks runtime verified."
}
```

### QA-CREDIT-10 / TODO-32F-S2：Opening-balance import runtime verifier watch（2026-06-05）

QA watcher found no E11-CREDIT-06 runtime-live evidence beyond the existing contract artifact `.tmp/credit-wallet/opening_balance_import_contract.json`, which still reports `runtime_implemented=false`. The verifier now refuses to treat `runtime_implemented=true` alone as runtime acceptance; future runtime artifacts must also be `contract_only=false` and prove live/readback fields.

```json
{
  "task_id": "QA-CREDIT-10",
  "parent_task_id": "TODO-32F-S2",
  "lane": "QA",
  "status": "runtime_artifact_pending",
  "changed_files": [
    "scripts/verify_credit_wallet_ledger_surface.ps1",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "verifier_state": {
    "opening_balance_import_schema_verified": true,
    "opening_balance_import_artifact_verified": true,
    "opening_balance_import_runtime_verified": false,
    "paid_gate_changed": false
  },
  "runtime_acceptance_requires": [
    "runtime_implemented=true",
    "contract_only=false",
    "endpoint=/billing/opening-balance-imports",
    "opening_import_id present",
    "ledger_entry_id or admin_adjustment_entry_id present",
    "audit_id present",
    "live_db_readback_passed=true",
    "opening_import_readback_passed=true",
    "ledger_entry_readback_passed or admin_adjustment_entry_readback_passed=true",
    "audit_readback_passed=true",
    "replay_readback_passed=true",
    "refusal_readback_passed=true",
    "rollback_readback_passed=true"
  ],
  "selftest_coverage": [
    "opening_balance_import_runtime_positive_live_readback_accepted",
    "opening_balance_import_runtime_missing_live_readback_rejected"
  ],
  "remaining_gaps": [
    "No live DB/readback artifact proves opening-balance import apply/replay/refusal/rollback.",
    "Current artifact remains contract-only with runtime_implemented=false.",
    "New API / One API balance import apply/rollback runner remains unimplemented."
  ],
  "next_task": "E11-CREDIT-06/TODO-32F-S2 should produce a runtime_implemented=true, contract_only=false, secret-safe live readback artifact before QA marks runtime verified."
}
```

### QA-CREDIT-12 / TODO-32F-S3：Runtime artifact verifier watcher（2026-06-05）

QA watcher found no E11-CREDIT-07 runtime-live artifact and no accepted route runtime implementation artifact. E11-CREDIT-06 is visible as a DB-free SQL contract/design-to-code slice only; it does not execute the route, write `opening_balance_imports`, write ledger/audit rows, or produce live readback evidence. Existing `.tmp/credit-wallet/opening_balance_import_contract.json` remains contract/artifact evidence with `runtime_implemented=false`.

```json
{
  "task_id": "QA-CREDIT-12",
  "parent_task_id": "TODO-32F-S3",
  "lane": "QA",
  "status": "no_runtime_artifact_noop",
  "changed_files": [
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "runtime_artifact_found": false,
  "contract_artifact_found": true,
  "verifier_state": {
    "opening_balance_import_schema_verified": true,
    "opening_balance_import_artifact_verified": true,
    "opening_balance_import_runtime_verified": false,
    "paid_gate_changed": false
  },
  "current_artifact": {
    "path": ".tmp/credit-wallet/opening_balance_import_contract.json",
    "schema": "opening_balance_import_contract.v1",
    "runtime_implemented": false
  },
  "remaining_gaps": [
    "No runtime_implemented=true artifact exists.",
    "No contract_only=false live/internal DB readback evidence exists.",
    "No live opening_import_id, ledger/admin-adjustment id, audit id, replay/conflict/refusal/rollback marker bundle exists."
  ],
  "next_task": "E11-CREDIT-07/TODO-32F-S3 should produce a secret-safe runtime artifact with contract_only=false and live/internal DB readback before QA can set runtime_verified=true."
}
```

### QA-CREDIT-13 / TODO-32F-S4：Runtime verifier guard watcher（2026-06-05）

QA watcher found no E11-CREDIT-08 runtime-live artifact. Current implementation evidence is still the E11-CREDIT-07 DB-free internal transaction-shape partial: it validates apply/replay/conflict/refusal shapes, but does not run SQL, does not mutate the route, does not write `opening_balance_imports`, ledger, or audit rows, and does not produce live/internal DB readback evidence.

```json
{
  "task_id": "QA-CREDIT-13",
  "parent_task_id": "TODO-32F-S4",
  "lane": "QA",
  "status": "no_runtime_artifact_noop",
  "changed_files": [
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "artifact_status": {
    "runtime_artifact_found": false,
    "contract_artifact_path": ".tmp/credit-wallet/opening_balance_import_contract.json",
    "contract_artifact_runtime_implemented": false
  },
  "verifier_state": {
    "opening_balance_import_schema_verified": true,
    "opening_balance_import_artifact_verified": true,
    "opening_balance_import_runtime_verified": false,
    "paid_gate_changed": false
  },
  "runtime_acceptance_guard": [
    "runtime_implemented=true",
    "contract_only=false",
    "live or internal DB readback booleans all pass",
    "opening_import_id present",
    "ledger_entry_id or admin_adjustment_entry_id present",
    "audit_id present",
    "replay/conflict/refusal/rollback markers pass",
    "secret_safe=true",
    "paid_gate_changed=false"
  ],
  "next_task": "E11-CREDIT-08/TODO-32F-S4 should produce a runtime artifact that satisfies the guard before QA can mark runtime_verified=true."
}
```

### QA-CREDIT-15 / TODO-32F-S5：Prepare/consume runtime artifact paths（2026-06-05）

QA verifier now watches the S5 runtime artifact paths before the older contract-only paths, so a future runtime JSON will not be masked by `.tmp/credit-wallet/opening_balance_import_contract.json`. No runtime artifact is currently present; E11-CREDIT-08 remains a partial compiled internal `sqlx` function without route/live DB readback artifact.

```json
{
  "task_id": "QA-CREDIT-15",
  "parent_task_id": "TODO-32F-S5",
  "lane": "QA",
  "status": "runtime_artifact_paths_prepared_no_runtime_artifact",
  "changed_files": [
    "scripts/verify_credit_wallet_ledger_surface.ps1",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "runtime_artifact_paths": [
    ".tmp/credit-wallet/opening_balance_import_runtime.json",
    "artifacts/credit_wallet_opening_balance_import_runtime.json"
  ],
  "fallback_contract_artifact_paths": [
    ".tmp/credit-wallet/opening_balance_import_contract.json",
    "artifacts/credit_wallet_opening_balance_import.json"
  ],
  "runtime_artifact_found": false,
  "verifier_state": {
    "opening_balance_import_schema_verified": true,
    "opening_balance_import_artifact_verified": true,
    "opening_balance_import_runtime_verified": false,
    "paid_gate_changed": false
  },
  "runtime_acceptance_requires": [
    "schema indicates runtime",
    "overall_status=pass or status=pass",
    "runtime_implemented=true",
    "contract_only=false",
    "live_db_readback_passed=true",
    "opening_import_readback_passed=true",
    "ledger_entry_readback_passed or admin_adjustment_entry_readback_passed=true",
    "audit_readback_passed=true",
    "replay_readback_passed=true",
    "refusal_readback_passed=true",
    "rollback_readback_passed=true",
    "opening_import_id present",
    "ledger_entry_id or admin_adjustment_entry_id present",
    "audit_id present",
    "secret_safe=true",
    "paid_gate_changed=false"
  ],
  "next_task": "E11-CREDIT-09/TODO-32F-S5 should write one of the runtime artifact paths after live/internal DB readback passes; QA will then consume it before the contract fallback."
}
```

### QA-CREDIT-16 / TODO-32F-S5：Standby consume blocked runtime artifact（2026-06-05）

QA verifier consumed the new runtime-path artifact before the older contract fallback. The artifact is intentionally blocked and does not prove runtime implementation or DB readback.

```json
{
  "task_id": "QA-CREDIT-16",
  "parent_task_id": "TODO-32F-S5",
  "lane": "QA",
  "status": "runtime_artifact_found_blocked",
  "changed_files": [
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "runtime_artifact": {
    "path": ".tmp/credit-wallet/opening_balance_import_runtime.json",
    "schema": "opening_balance_import_runtime.v1",
    "overall_status": "blocked",
    "runtime_implemented": false,
    "contract_only": true,
    "db_integration_ran": false,
    "secret_safe": true,
    "paid_gate_changed": false,
    "blockers": [
      "opening_balance_import_db_integration_not_requested"
    ]
  },
  "verifier_state": {
    "selected_status": "opening_balance_import_artifact_present_but_not_verified",
    "opening_balance_import_schema_verified": true,
    "opening_balance_import_artifact_verified": false,
    "opening_balance_import_runtime_verified": false,
    "paid_gate_changed": false
  },
  "remaining_gaps": [
    "No live/internal DB integration readback has run.",
    "No opening_import_id, ledger/admin-adjustment id, or audit id is present.",
    "Replay/conflict/refusal/rollback readback booleans remain pending."
  ],
  "next_task": "E11-CREDIT-09 should run the opt-in DB integration and rewrite the runtime artifact only after all readback fields pass."
}
```

### QA-CREDIT-17 / TODO-32F-S5：Consume blocked runtime artifact without failing productization gap verifier（2026-06-05）

QA verifier consumed `.tmp/credit-wallet/opening_balance_import_runtime.json` as the selected opening-balance artifact because runtime paths are checked before contract fallback. The artifact is blocked/partial, so runtime remains false; however this is a productization gap, not a paid-gate regression or verifier fail.

```json
{
  "task_id": "QA-CREDIT-17",
  "parent_task_id": "TODO-32F-S5",
  "lane": "QA",
  "status": "blocked_runtime_artifact_consumed_runtime_false",
  "changed_files": [
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "runtime_artifact_found": true,
  "artifact_status": {
    "path": ".tmp/credit-wallet/opening_balance_import_runtime.json",
    "schema": "opening_balance_import_runtime.v1",
    "overall_status": "blocked",
    "runtime_implemented": false,
    "contract_only": true,
    "db_integration_ran": false,
    "secret_safe": true,
    "paid_gate_changed": false,
    "blockers": [
      "opening_balance_import_db_integration_not_requested"
    ]
  },
  "verifier_state": {
    "overall_status": "pass_with_productization_gaps",
    "selected_status": "opening_balance_import_artifact_present_but_not_verified",
    "opening_balance_import_runtime_verified": false,
    "opening_balance_import_artifact_verified": false,
    "paid_gate_changed": false
  },
  "next_task": "E11-CREDIT-09 should rerun with DB integration/readback and rewrite the runtime artifact only when runtime_implemented=true, contract_only=false, ids and all readback booleans pass."
}
```

### QA-CREDIT-19 / TODO-32F-S7：Runtime-vs-plan strict verifier watcher（2026-06-05）

QA reviewed E11-CREDIT-10's guarded rollback-contained `psql` DB plan and tightened the credit verifier so plan execution cannot be confused with runtime implementation acceptance. `db_runner_implemented=true` and executable/readback plan markers are diagnostic only; they do not satisfy `opening_balance_import_runtime_verified=true` unless the artifact also proves a public route or Rust internal transaction path was invoked.

```json
{
  "task_id": "QA-CREDIT-19",
  "parent_task_id": "TODO-32F-S7",
  "lane": "QA",
  "status": "strictness_fixed_runtime_still_false",
  "changed_files": [
    "scripts/verify_credit_wallet_ledger_surface.ps1",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "strictness": {
    "db_runner_implemented_can_mark_runtime_verified": false,
    "psql_plan_only_can_mark_runtime_verified": false,
    "requires_route_or_internal_rust_path_invoked": true,
    "requires_runtime_implemented": true,
    "requires_contract_only_false": true,
    "requires_ids_and_readback_booleans": true,
    "requires_secret_safe": true,
    "requires_paid_gate_unchanged": true
  },
  "current_artifact": {
    "path": ".tmp/credit-wallet/opening_balance_import_runtime.json",
    "schema": "opening_balance_import_runtime.v1",
    "overall_status": "blocked",
    "runtime_implemented": false,
    "contract_only": true,
    "db_runner_implemented": true,
    "route_or_internal_rust_path_invoked": false,
    "paid_gate_changed": false
  },
  "verifier_state": {
    "overall_status": "pass_with_productization_gaps",
    "selected_status": "opening_balance_import_artifact_present_but_not_verified",
    "opening_balance_import_runtime_verified": false
  },
  "selftest_coverage_added": [
    "opening_balance_import_runtime_psql_plan_only_rejected"
  ],
  "next_task": "E11-CREDIT-10/S7 can run the guarded DB plan, but QA should only accept runtime after the artifact proves route_invoked or internal_rust_function_invoked plus all readback fields."
}
```

### QA-CREDIT-20 / TODO-32F-S7：Consume partial DB-plan artifact（2026-06-05）

QA re-consumed the current local compose DB-plan artifact after E11/main-thread S7 updated `.tmp/credit-wallet/opening_balance_import_runtime.json` to `overall_status=partial`. The DB plan now passes, but this is still partial verifier evidence, not runtime implementation acceptance.

```json
{
  "task_id": "QA-CREDIT-20",
  "parent_task_id": "TODO-32F-S7",
  "lane": "QA",
  "status": "partial_artifact_consumed_runtime_still_false",
  "changed_files": [
    "scripts/verify_credit_wallet_ledger_surface.ps1",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "partial_artifact_consumed": true,
  "current_artifact": {
    "path": ".tmp/credit-wallet/opening_balance_import_runtime.json",
    "schema": "opening_balance_import_runtime.v1",
    "overall_status": "partial",
    "db_integration_ran": true,
    "db_runner_implemented": true,
    "executable_db_plan_passed": true,
    "runtime_implemented": false,
    "contract_only": true,
    "route_or_internal_rust_path_invoked": false,
    "paid_gate_changed": false,
    "blockers": [
      "opening_balance_import_public_route_not_wired",
      "opening_balance_import_internal_rust_function_not_invoked_by_verifier"
    ]
  },
  "verifier_state": {
    "overall_status": "pass_with_productization_gaps",
    "selected_status": "opening_balance_import_artifact_present_but_not_verified",
    "opening_balance_import_runtime_verified": false
  },
  "selftest_coverage_added": [
    "opening_balance_import_runtime_partial_db_plan_only_rejected"
  ],
  "acceptance_rule": "A passing rollback-contained psql plan is partial DB-plan evidence only. Runtime acceptance still requires runtime_implemented=true, contract_only=false, route/public route/internal Rust transaction invocation proof, live/readback ids and booleans, secret_safe=true, and paid_gate_changed=false.",
  "next_task": "E11 should wire or verifier-invoke the public route or Rust internal transaction and emit runtime_implemented=true only after live/readback evidence is real."
}
```

### QA-CREDIT-20 update / TODO-32F-S7：Live route matrix artifact consumed（2026-06-05）

Main thread reports the replay canonicalization bug was fixed and the rebuilt compose live route matrix now passes. QA re-consumed the updated runtime artifact and the credit verifier now accepts opening-balance import runtime evidence.

```json
{
  "task_id": "QA-CREDIT-20-update",
  "parent_task_id": "TODO-32F-S7",
  "lane": "QA",
  "status": "runtime_artifact_consumed_verified",
  "changed_files": [
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "reported_manual_live_matrix": {
    "cargo_test_ai_control_plane_opening_balance_import": "7 passed, 1 ignored",
    "compose_rebuilt": true,
    "apply_http": 201,
    "runtime_implemented": true,
    "contract_only": false,
    "route_invoked": true,
    "internal_sqlx_function_invoked": true,
    "replay_http": 200,
    "replay_same_opening_and_ledger_ids": true,
    "same_key_different_amount_refused": true,
    "duplicate_external_reference_refused": true,
    "currency_mismatch_refused_without_import": true,
    "opening_readback_passed": true,
    "ledger_readback_passed": true,
    "audit_readback_passed": true,
    "same_key_import_count": 1,
    "currency_refusal_import_count": 0,
    "secret_safe": true,
    "paid_gate_changed": false
  },
  "current_artifact_consumed_by_qa": {
    "path": ".tmp/credit-wallet/opening_balance_import_runtime.json",
    "schema": "opening_balance_import_runtime.v1",
    "overall_status": "pass",
    "runtime_implemented": true,
    "contract_only": false,
    "route_invoked": true,
    "public_route_invoked": true,
    "internal_sqlx_function_invoked": true,
    "db_runner_implemented": true,
    "db_integration_ran": true,
    "live_route_probe_ran": true,
    "opening_import_id_present": true,
    "ledger_entry_id_present": true,
    "admin_adjustment_entry_id_present": true,
    "audit_id_present": true,
    "live_db_readback_passed": true,
    "opening_import_readback_passed": true,
    "ledger_entry_readback_passed": true,
    "admin_adjustment_entry_readback_passed": true,
    "audit_readback_passed": true,
    "replay_readback_passed": true,
    "refusal_readback_passed": true,
    "rollback_readback_passed": true,
    "secret_safe": true,
    "paid_gate_changed": false
  },
  "qa_verifier_result": {
    "overall_status": "pass_with_productization_gaps",
    "opening_balance_import_runtime_verified": true,
    "reason": "runtime artifact is QA-readable and satisfies route/internal Rust invocation plus live readback gates"
  },
  "next_task": "Main review can decide whether TODO-32F-S7 runtime evidence is accepted; broader credit productization gaps such as credit grant CRUD, top-up/redeem, invoices, subscriptions, and user-facing remaining balance API remain separate TODO-32 work."
}
```

### QA-CREDIT-21 / TODO-32G：Credit grant CRUD verifier plan and 32F regression guard（2026-06-05）

QA locked the TODO-32F regression first: the credit verifier still reports `opening_balance_import_runtime_verified=true`, `new_api_one_api_balance_import=runtime_verified`, and `remaining_gaps` no longer contains `new_api_one_api_balance_import_apply_rollback_runner`. The next productization gap is credit grant CRUD/API/audit.

```json
{
  "task_id": "QA-CREDIT-21",
  "parent_task_id": "TODO-32G",
  "lane": "QA",
  "status": "verifier_extended_artifact_present_not_verified",
  "changed_files": [
    "scripts/verify_credit_wallet_ledger_surface.ps1",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "opening_import_regression": {
    "opening_balance_import_runtime_verified": true,
    "new_api_one_api_balance_import": "runtime_verified",
    "opening_balance_import_gap_present": false
  },
  "credit_grant_crud_verifier": {
    "artifact_paths": [
      ".tmp/credit-wallet/credit_grant_crud_runtime.json",
      "artifacts/credit_wallet_credit_grant_crud_runtime.json",
      ".tmp/credit-wallet/credit_grant_crud_contract.json",
      "artifacts/credit_wallet_credit_grant_crud_contract.json"
    ],
    "contract_required_fields": [
      "schema=credit_grant_crud_contract.v1|credit_grant_crud_runtime.v1",
      "status=pass|passed|verified",
      "money_decimal_strings=true",
      "idempotency_contract=true",
      "audit_required=true",
      "direct_wallet_snapshot_mutation_forbidden=true",
      "secret_safe=true",
      "paid_gate_changed=false"
    ],
    "runtime_additional_required_fields": [
      "runtime_implemented=true",
      "contract_only=false",
      "route_invoked|public_route_invoked|internal_rust_function_invoked|internal_sqlx_function_invoked|rust_internal_transaction_invoked=true",
      "endpoint=/billing/credit-grants or /admin/credit-grants or credit_grant_crud_endpoints_present=true",
      "credit_grant_id|grant_id present",
      "audit_id present",
      "create_readback_passed=true",
      "list_readback_passed=true",
      "expire_readback_passed|revoke_readback_passed|lifecycle_readback_passed=true",
      "status_readback_passed=true",
      "replay_readback_passed=true",
      "refusal_readback_passed=true",
      "audit_readback_passed=true"
    ],
    "current_artifact": {
      "path": ".tmp/credit-wallet/credit_grant_crud_contract.json",
      "found": true,
      "status": "credit_grant_crud_contract_verified",
      "contract_verified": true,
      "runtime_verified": false,
      "passed_contract_checks": [
        "status_pass=true",
        "money_decimal_strings=true",
        "idempotency_contract=true",
        "audit_required=true",
        "direct_wallet_snapshot_mutation_forbidden=true",
        "secret_safe=true",
        "paid_gate_unchanged=true"
      ],
      "remaining_runtime_checks": [
        "runtime_implemented=false",
        "route_or_internal_rust_path_invoked=false",
        "runtime_artifact_absent"
      ]
    },
    "selftest_coverage_added": [
      "credit_grant_crud_contract_positive_accepted",
      "credit_grant_crud_contract_not_runtime_verified",
      "credit_grant_crud_runtime_positive_accepted",
      "credit_grant_crud_secret_unsafe_rejected",
      "credit_grant_crud_paid_gate_changed_rejected",
      "credit_grant_crud_runtime_missing_audit_rejected"
    ]
  },
  "remaining_gaps": [
    "credit_grant_crud_api_and_audit",
    "user_recharge_voucher_redemption_flow",
    "payment_order_invoice_lifecycle",
    "subscription_plan_lifecycle",
    "user_facing_remaining_balance_api"
  ],
  "next_task": "E11-CREDIT-12 should emit a credit grant CRUD runtime artifact with route/internal invocation, grant/audit ids, create/list/lifecycle/replay/refusal/audit readback, secret safety, and paid-gate neutrality; QA should then verify runtime acceptance."
}
```

### QA-CREDIT-22 / TODO-32G + TODO-32H：Runtime acceptance guard and remaining-balance contract lane（2026-06-06）

QA re-consumed the current credit-wallet artifacts after E11-CREDIT-12/E9-CREDIT-21 activity. TODO-32F remains runtime verified. TODO-32G has a verified contract artifact but no runtime artifact. TODO-32H has a verified contract-only artifact; runtime is intentionally false.

```json
{
  "task_id": "QA-CREDIT-22",
  "lane": "QA",
  "status": "credit_grant_contract_verified_runtime_missing_user_balance_contract_verified",
  "changed_files": [
    "scripts/verify_credit_wallet_ledger_surface.ps1",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "watched_artifacts": {
    "credit_grant_crud_contract": {
      "path": ".tmp/credit-wallet/credit_grant_crud_contract.json",
      "found": true,
      "schema": "credit_grant_crud_contract.v1",
      "status": "pass",
      "contract_verified": true,
      "runtime_verified": false,
      "runtime_implemented": false,
      "secret_safe": true,
      "paid_gate_changed": false
    },
    "credit_grant_crud_runtime": {
      "path": ".tmp/credit-wallet/credit_grant_crud_runtime.json",
      "found": false,
      "status": "runtime_missing",
      "runtime_verified": false
    },
    "user_remaining_balance_contract": {
      "path": ".tmp/credit-wallet/user_remaining_balance_contract.json",
      "found": true,
      "schema": "user_remaining_balance_contract.v1",
      "status": "pass",
      "contract_verified": true,
      "runtime_verified": false,
      "runtime_implemented": false,
      "read_only": true,
      "secret_safe": true,
      "paid_gate_changed": false
    }
  },
  "verifier_fields": {
    "opening_balance_import_runtime_verified": true,
    "new_api_one_api_balance_import": "runtime_verified",
    "credit_grant_crud_contract_verified": true,
    "credit_grant_crud_runtime_verified": false,
    "user_remaining_balance_contract_verified": true,
    "user_remaining_balance_runtime_verified": false
  },
  "strict_runtime_acceptance_for_todo_32g": [
    "schema=credit_grant_crud_runtime.v1",
    "status pass",
    "runtime_implemented=true",
    "contract_only=false",
    "route/internal invocation true",
    "grant id and audit id present",
    "create/list/read/lifecycle/status/replay readback true",
    "conflict/refusal no-write evidence true",
    "audit_readback_passed=true",
    "money_decimal_strings=true",
    "direct_wallet_snapshot_mutation_forbidden=true",
    "secret_safe=true",
    "paid_gate_changed=false"
  ],
  "remaining_gaps": [
    "credit_grant_crud_api_and_audit",
    "user_recharge_voucher_redemption_flow",
    "payment_order_invoice_lifecycle",
    "subscription_plan_lifecycle",
    "user_facing_remaining_balance_api_runtime"
  ],
  "controlled_paid_beta_status": "paid_controlled_beta_allowed_true_not_reopened",
  "next_task": "E11 should emit credit_grant_crud_runtime.v1 after live route/readback coverage; E11/E9 should later emit a user remaining-balance runtime artifact without changing paid beta status."
}
```

### QA-CREDIT-23 / TODO-32G：Lifecycle runtime guard and negative-amount regression watch（2026-06-06）

QA re-read E11 source/RBAC/OpenAPI and current credit-wallet artifacts. This QA-CREDIT-23 finding was later superseded by QA-CREDIT-24: E11 now includes the targeted `-1.00000000` credit grant create refusal test, and the verifier reports the negative amount guard as pass. The runtime artifact is still absent, so TODO-32G remains contract-verified but runtime-unverified.

```json
{
  "task_id": "QA-CREDIT-23",
  "lane": "QA",
  "status": "superseded_by_qacredit24_negative_amount_guard_pass_runtime_missing",
  "changed_files": [
    "scripts/verify_credit_wallet_ledger_surface.ps1",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "watched_artifacts": {
    "credit_grant_crud_contract": {
      "path": ".tmp/credit-wallet/credit_grant_crud_contract.json",
      "found": true,
      "contract_verified": true
    },
    "credit_grant_crud_runtime": {
      "path": ".tmp/credit-wallet/credit_grant_crud_runtime.json",
      "found": false,
      "status": "runtime_missing"
    },
    "user_remaining_balance_contract": {
      "path": ".tmp/credit-wallet/user_remaining_balance_contract.json",
      "found": true,
      "contract_verified": true,
      "runtime_verified": false
    }
  },
  "negative_amount_guard": {
    "source_guard_present": true,
    "minus_one_fixed_decimal_test_present": true,
    "status": "pass",
    "blocker": null
  },
  "verifier_fields": {
    "opening_balance_import_runtime_verified": true,
    "credit_grant_crud_contract_verified": true,
    "credit_grant_crud_runtime_verified": false,
    "user_remaining_balance_contract_verified": true,
    "user_remaining_balance_runtime_verified": false
  },
  "remaining_gaps": [
    "credit_grant_crud_api_and_audit",
    "user_recharge_voucher_redemption_flow",
    "payment_order_invoice_lifecycle",
    "subscription_plan_lifecycle",
    "user_facing_remaining_balance_api_runtime"
  ],
  "controlled_paid_beta_status": "paid_controlled_beta_allowed_true_not_reopened",
  "next_task": "E11 should emit credit_grant_crud_runtime.v1 with lifecycle/readback evidence before QA clears TODO-32G runtime."
}
```

### QA-CREDIT-24 / TODO-32G：Reconsume negative amount guard after E11-CREDIT-13（2026-06-06）

QA reconsumed current E11 source and verifier output. `apps/control-plane/src/admin.rs` now contains `admin_credit_grant_create_rejects_non_positive_amounts()` and sets `negative.amount = "-1.00000000"`, while `normalize_create_admin_credit_grant_request` rejects `amount <= 0`. Main verifier reports `negative_amount_guard.status=pass` and no negative amount blocker.

```json
{
  "task_id": "QA-CREDIT-24",
  "lane": "QA",
  "status": "negative_amount_guard_pass_runtime_still_pending",
  "changed_files": [
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "negative_amount_guard": {
    "source_guard_present": true,
    "minus_one_fixed_decimal_test_present": true,
    "status": "pass",
    "blocker": null
  },
  "verifier_fields": {
    "credit_grant_crud_contract_verified": true,
    "credit_grant_crud_runtime_verified": false,
    "user_remaining_balance_contract_verified": true,
    "user_remaining_balance_runtime_verified": false
  },
  "remaining_gaps": [
    "credit_grant_crud_api_and_audit",
    "user_recharge_voucher_redemption_flow",
    "payment_order_invoice_lifecycle",
    "subscription_plan_lifecycle",
    "user_facing_remaining_balance_api_runtime"
  ],
  "next_task": "Wait for E11-CREDIT-14 credit_grant_crud_runtime.v1 live route/readback artifact."
}
```

### QA-CREDIT-25 / TODO-32I：Recharge-voucher contract verifier lane（2026-06-06）

QA added a contract-only verifier lane for TODO-32I. The verifier watches `.tmp/credit-wallet/recharge_voucher_contract.json`, `artifacts/credit_wallet_recharge_voucher_contract.json`, `.tmp/credit-wallet/recharge_voucher.json`, and `artifacts/credit_wallet_recharge_voucher.json`. Current `.tmp/credit-wallet/recharge_voucher_contract.json` is accepted as contract evidence only; no Control Plane/payment/voucher runtime is claimed.

```json
{
  "task_id": "QA-CREDIT-25",
  "lane": "QA",
  "status": "recharge_voucher_contract_verified_runtime_false",
  "changed_files": [
    "scripts/verify_credit_wallet_ledger_surface.ps1",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "watched_artifacts": {
    "recharge_voucher_contract": {
      "path": ".tmp/credit-wallet/recharge_voucher_contract.json",
      "found": true,
      "schema": "recharge_voucher_contract.v1",
      "status": "pass",
      "contract_verified": true,
      "runtime_verified": false,
      "runtime_implemented": false,
      "contract_only": true,
      "voucher_code_hashed_or_redacted": true,
      "redeem_idempotency_contract": true,
      "abuse_guard_contract": true,
      "ledger_or_credit_effect_contract": true,
      "refund_cancel_reversal_required": true,
      "secret_safe": true,
      "paid_gate_changed": false
    },
    "recharge_voucher_runtime": {
      "paths": [
        ".tmp/credit-wallet/recharge_voucher.json",
        "artifacts/credit_wallet_recharge_voucher.json"
      ],
      "runtime_verified": false,
      "status": "runtime_not_proven"
    }
  },
  "verifier_fields": {
    "opening_balance_import_runtime_verified": true,
    "credit_grant_crud_contract_verified": true,
    "credit_grant_crud_runtime_verified": false,
    "user_remaining_balance_contract_verified": true,
    "user_remaining_balance_runtime_verified": false,
    "recharge_voucher_contract_verified": true,
    "recharge_voucher_runtime_verified": false
  },
  "remaining_gaps": [
    "credit_grant_crud_api_and_audit",
    "user_recharge_voucher_redemption_flow_runtime",
    "payment_order_invoice_lifecycle",
    "subscription_plan_lifecycle",
    "user_facing_remaining_balance_api_runtime"
  ],
  "controlled_paid_beta_status": "paid_controlled_beta_allowed_true_not_reopened",
  "next_task": "Wait for E11/Product/Security runtime artifact proving recharge/voucher Control Plane/payment handoff, voucher storage/readback, redeem replay/refusal, abuse persistence, ledger/credit effect, audit, secret safety, and paid-gate neutrality."
}
```

### QA-CREDIT-26 / TODO-32J：Payment-order-invoice contract verifier lane（2026-06-06）

QA added a contract-only verifier lane for TODO-32J. E9-CREDIT-27 extends the watcher to the future runtime paths `.tmp/credit-wallet/payment_order_invoice_runtime.json` and `artifacts/credit_wallet_payment_order_invoice_runtime.json` while preserving the contract guard paths `.tmp/credit-wallet/payment_order_invoice_contract.json` and `artifacts/credit_wallet_payment_order_invoice_contract.json`. Current `.tmp/credit-wallet/payment_order_invoice_contract.json` is accepted as contract evidence only; no Control Plane provider handoff/callback, order/invoice runtime, ledger credit runtime, audit readback, reconciliation, or refund runtime is claimed.

```json
{
  "task_id": "QA-CREDIT-26",
  "lane": "QA",
  "status": "payment_order_invoice_contract_verified_runtime_false",
  "changed_files": [
    "scripts/verify_credit_wallet_ledger_surface.ps1",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "watched_artifacts": {
    "payment_order_invoice_contract": {
      "path": ".tmp/credit-wallet/payment_order_invoice_contract.json",
      "found": true,
      "schema": "payment_order_invoice_contract.v1",
      "status": "pass",
      "contract_verified": true,
      "runtime_verified": false,
      "runtime_implemented": false,
      "contract_only": true,
      "money_decimal_strings": true,
      "provider_handoff_secret_safe": true,
      "capture_ledger_or_credit_effect_contract": true,
      "replay_idempotency_contract": true,
      "invoice_receipt_contract": true,
      "refund_cancel_reversal_required": true,
      "reconciliation_contract": true,
      "audit_required": true,
      "direct_wallet_snapshot_mutation_forbidden": true,
      "secret_safe": true,
      "paid_gate_changed": false
    },
    "payment_order_invoice_runtime": {
      "paths": [
        ".tmp/credit-wallet/payment_order_invoice_runtime.json",
        "artifacts/credit_wallet_payment_order_invoice_runtime.json"
      ],
      "runtime_verified": false,
      "status": "runtime_not_proven"
    }
  },
  "verifier_fields": {
    "opening_balance_import_runtime_verified": true,
    "credit_grant_crud_contract_verified": true,
    "credit_grant_crud_runtime_verified": false,
    "user_remaining_balance_contract_verified": true,
    "recharge_voucher_contract_verified": true,
    "payment_order_invoice_contract_verified": true,
    "payment_order_invoice_runtime_verified": false
  },
  "remaining_gaps": [
    "credit_grant_crud_api_and_audit",
    "user_recharge_voucher_redemption_flow_runtime",
    "payment_order_invoice_lifecycle_runtime",
    "subscription_plan_lifecycle",
    "user_facing_remaining_balance_api_runtime"
  ],
  "controlled_paid_beta_status": "paid_controlled_beta_allowed_true_not_reopened",
  "next_task": "Wait for E11/Product/Finance/Ops runtime artifact proving Control Plane route/provider handoff/callback, order/invoice persistence, ledger or credit effect, audit, reconciliation, refund/cancel readback, secret safety, and paid-gate neutrality."
}
```

### QA-CREDIT-27 / TODO-32K：Subscription-package contract verifier lane（2026-06-06）

QA added a contract-only verifier lane for TODO-32K. E9-CREDIT-28 extends the watcher to the future runtime paths `.tmp/credit-wallet/subscription_package_lifecycle_runtime.json` and `artifacts/credit_wallet_subscription_package_lifecycle_runtime.json` while preserving the contract guard paths `.tmp/credit-wallet/subscription_package_lifecycle_contract.json` and `artifacts/credit_wallet_subscription_package_lifecycle_contract.json`. Current `.tmp/credit-wallet/subscription_package_lifecycle_contract.json` is accepted as contract evidence only; no Control Plane subscription/package runtime, recurring scheduler, provider retry/callback, invoice production, dunning execution, entitlement enforcement, or runtime readback is claimed.

```json
{
  "task_id": "QA-CREDIT-27",
  "lane": "QA",
  "status": "subscription_package_lifecycle_contract_verified_runtime_false",
  "changed_files": [
    "scripts/verify_credit_wallet_ledger_surface.ps1",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "watched_artifacts": {
    "subscription_package_lifecycle_contract": {
      "path": ".tmp/credit-wallet/subscription_package_lifecycle_contract.json",
      "found": true,
      "schema": "subscription_package_lifecycle_contract.v1",
      "status": "pass",
      "contract_verified": true,
      "runtime_verified": false,
      "runtime_implemented": false,
      "contract_only": true,
      "money_decimal_strings": true,
      "replay_idempotency_contract": true,
      "plan_package_lifecycle": true,
      "subscription_states": true,
      "subscription_credit_effect_contract": true,
      "invoice_order_linkage_contract": true,
      "refusal_no_subscription_ledger_credit_invoice_writes": true,
      "audit_required": true,
      "direct_wallet_snapshot_mutation_forbidden": true,
      "secret_safe": true,
      "paid_gate_changed": false
    },
    "subscription_package_lifecycle_runtime": {
      "paths": [
        ".tmp/credit-wallet/subscription_package_lifecycle_runtime.json",
        "artifacts/credit_wallet_subscription_package_lifecycle_runtime.json"
      ],
      "runtime_verified": false,
      "status": "runtime_not_proven"
    }
  },
  "verifier_fields": {
    "opening_balance_import_runtime_verified": true,
    "credit_grant_crud_runtime_verified": true,
    "user_remaining_balance_contract_verified": true,
    "recharge_voucher_contract_verified": true,
    "payment_order_invoice_contract_verified": true,
    "subscription_package_lifecycle_contract_verified": true,
    "subscription_package_lifecycle_runtime_verified": false
  },
  "remaining_gaps": [
    "user_recharge_voucher_redemption_flow_runtime",
    "payment_order_invoice_lifecycle_runtime",
    "subscription_plan_lifecycle_runtime",
    "user_facing_remaining_balance_api_runtime"
  ],
  "controlled_paid_beta_status": "paid_controlled_beta_allowed_true_not_reopened",
  "next_task": "Wait for Product/E11/runtime artifact proving subscription/package APIs, scheduler/provider retry/callback integration, invoice production, dunning execution, entitlement/readback, audit, secret safety, and paid-gate neutrality."
}
```

### QA-CREDIT-28 / TODO-32H：User remaining-balance runtime verifier lane（2026-06-06）

QA extended the TODO-32H verifier lane so runtime paths are checked before contract paths while preserving contract-only evidence. Admin read-only runtime is accepted only as partial evidence; full user-facing runtime remains false unless a runtime artifact proves `user_api_runtime=true` plus authenticated tenant/project/user or developer-token ownership scope.

```json
{
  "task_id": "QA-CREDIT-28",
  "lane": "QA",
  "status": "user_remaining_balance_admin_readonly_runtime_verified_full_user_runtime_pending",
  "changed_files": [
    "scripts/verify_credit_wallet_ledger_surface.ps1",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "watched_artifacts": {
    "user_remaining_balance_runtime": {
      "paths": [
        ".tmp/credit-wallet/user_remaining_balance_runtime.json",
        "artifacts/credit_wallet_user_remaining_balance_runtime.json",
        ".tmp/credit-wallet/user_remaining_balance_api.json",
        "artifacts/credit_wallet_user_remaining_balance_api.json"
      ],
      "found": true,
      "admin_runtime_verified": true,
      "full_user_runtime_verified": false
    },
    "user_remaining_balance_contract": {
      "path": ".tmp/credit-wallet/user_remaining_balance_contract.json",
      "found": true,
      "contract_verified": true,
      "runtime_verified": false
    }
  },
  "admin_partial_runtime_acceptance": [
    "schema=user_remaining_balance_runtime.v1",
    "status pass",
    "runtime_implemented=true",
    "contract_only=false",
    "route_invoked/public_route_invoked=true",
    "read_only=true",
    "admin_readonly_runtime=true",
    "user_api_runtime=false",
    "tenant_id/wallet_id/currency present",
    "available_to_spend/active_credit_grant_total/pending_confirmed_ledger_window/wallet_balance_floor decimal strings",
    "wallet/credit_grants/ledger_window/refusal readback true",
    "secret_safe=true",
    "paid_gate_changed=false"
  ],
  "full_user_runtime_acceptance_extra": [
    "user_api_runtime=true",
    "authenticated tenant/project/user or developer-token ownership scope"
  ],
  "verifier_fields": {
    "opening_balance_import_runtime_verified": true,
    "credit_grant_crud_runtime_verified": true,
    "user_remaining_balance_contract_verified": true,
    "user_remaining_balance_admin_runtime_verified": true,
    "user_remaining_balance_runtime_verified": false,
    "payment_order_invoice_contract_verified": true,
    "subscription_package_lifecycle_contract_verified": true
  },
  "remaining_gaps": [
    "user_recharge_voucher_redemption_flow_runtime",
    "payment_order_invoice_lifecycle_runtime",
    "subscription_plan_lifecycle_runtime",
    "user_facing_remaining_balance_api_runtime"
  ],
  "controlled_paid_beta_status": "paid_controlled_beta_allowed_true_not_reopened",
  "next_task": "Wait for a full user-facing runtime artifact; accept current Admin read-only runtime only as partial and keep user_facing_remaining_balance_api_runtime until user_api_runtime plus ownership scope is proven."
}
```

### QA-CREDIT-29 / TODO-32H：Admin-readonly runtime reconciliation（2026-06-06）

QA reconsumed the current Admin-readonly runtime artifact and confirmed the verifier keeps the full user-facing API gate strict.

```json
{
  "task_id": "QA-CREDIT-29",
  "lane": "QA",
  "status": "admin_readonly_runtime_verified_full_user_runtime_false",
  "changed_files": [
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "artifact": {
    "path": ".tmp/credit-wallet/user_remaining_balance_runtime.json",
    "schema": "user_remaining_balance_runtime.v1",
    "overall_status": "pass",
    "runtime_implemented": true,
    "contract_only": false,
    "route_invoked": true,
    "public_route_invoked": true,
    "read_only": true,
    "admin_readonly_runtime": true,
    "user_api_runtime": false,
    "available_to_spend": "4.50000000",
    "active_credit_grant_total": "7.50000000",
    "pending_confirmed_ledger_window": "-1.50000000",
    "wallet_balance_floor": "1.50000000",
    "wallet_readback_passed": true,
    "credit_grants_readback_passed": true,
    "ledger_window_readback_passed": true,
    "refusal_readback_passed": true,
    "secret_safe": true,
    "paid_gate_changed": false
  },
  "verifier_fields": {
    "user_remaining_balance_contract_verified": true,
    "user_remaining_balance_admin_runtime_verified": true,
    "user_remaining_balance_admin_readonly_runtime_verified": true,
    "user_remaining_balance_runtime_verified": false,
    "opening_balance_import_runtime_verified": true,
    "credit_grant_crud_runtime_verified": true,
    "payment_order_invoice_contract_verified": true,
    "subscription_package_lifecycle_contract_verified": true
  },
  "remaining_gaps": [
    "user_recharge_voucher_redemption_flow_runtime",
    "payment_order_invoice_lifecycle_runtime",
    "subscription_plan_lifecycle_runtime",
    "user_facing_remaining_balance_api_runtime"
  ],
  "controlled_paid_beta_status": "paid_controlled_beta_allowed_true_not_reopened",
  "next_task": "Full TODO-32H user-facing runtime still requires user_api_runtime=true plus authenticated tenant/project/user or developer-token ownership scope."
}
```

### QA-CREDIT-30 / TODO-32H-S2：Full user runtime guard + TODO-32I runtime prep watch（2026-06-06）

QA added a negative selftest for the next TODO-32H full user/developer-token scoped runtime artifact: an artifact with `user_api_runtime=true` but no ownership-scope marker must not pass full runtime. Recharge/voucher runtime prep was checked; current verifier already has runtime-positive and missing-readback selftests, while the current repo artifact remains contract-only.

```json
{
  "task_id": "QA-CREDIT-30",
  "lane": "QA",
  "status": "full_user_runtime_ownership_guard_added_recharge_runtime_contract_only",
  "changed_files": [
    "scripts/verify_credit_wallet_ledger_surface.ps1",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "new_selftest_cases": [
    "user_remaining_balance_user_runtime_missing_ownership_scope_rejected"
  ],
  "verifier_fields": {
    "user_remaining_balance_contract_verified": true,
    "user_remaining_balance_admin_runtime_verified": true,
    "user_remaining_balance_admin_readonly_runtime_verified": true,
    "user_remaining_balance_runtime_verified": false,
    "recharge_voucher_contract_verified": true,
    "recharge_voucher_runtime_verified": false,
    "payment_order_invoice_contract_verified": true,
    "subscription_package_lifecycle_contract_verified": true
  },
  "recharge_voucher_runtime_prep": {
    "runtime_positive_selftest": true,
    "runtime_missing_readback_rejected": true,
    "current_artifact_contract_only": true,
    "current_runtime_verified": false
  },
  "remaining_gaps": [
    "user_recharge_voucher_redemption_flow_runtime",
    "payment_order_invoice_lifecycle_runtime",
    "subscription_plan_lifecycle_runtime",
    "user_facing_remaining_balance_api_runtime"
  ],
  "controlled_paid_beta_status": "paid_controlled_beta_allowed_true_not_reopened",
  "next_task": "Wait for E11-CREDIT-16 full user/developer-token scoped remaining-balance runtime artifact with ownership scope, or TODO-32I recharge/voucher runtime artifact; do not promote contract-only artifacts to runtime."
}
```

### QA-CREDIT-31 / TODO-32I：Recharge-voucher runtime verifier hardening（2026-06-06）

QA hardened the TODO-32I runtime verifier so recharge/voucher runtime artifacts with `runtime_implemented=true` still fail when route/internal invocation proof is missing or voucher code hash readback is absent. Current repo evidence remains contract-only for recharge/voucher runtime; no Control Plane/payment-provider/voucher runtime implementation is claimed.

```json
{
  "task_id": "QA-CREDIT-31",
  "lane": "QA",
  "status": "recharge_voucher_runtime_guard_hardened_contract_only_remains_false",
  "changed_files": [
    "scripts/verify_credit_wallet_ledger_surface.ps1",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "new_selftest_cases": [
    "recharge_voucher_runtime_missing_route_rejected",
    "recharge_voucher_runtime_missing_voucher_hash_rejected"
  ],
  "verifier_fields": {
    "opening_balance_import_runtime_verified": true,
    "credit_grant_crud_runtime_verified": true,
    "user_remaining_balance_admin_readonly_runtime_verified": true,
    "user_remaining_balance_runtime_verified": false,
    "recharge_voucher_contract_verified": true,
    "recharge_voucher_runtime_verified": false,
    "payment_order_invoice_contract_verified": true,
    "subscription_package_lifecycle_contract_verified": true
  },
  "remaining_gaps": [
    "user_recharge_voucher_redemption_flow_runtime",
    "payment_order_invoice_lifecycle_runtime",
    "subscription_plan_lifecycle_runtime",
    "user_facing_remaining_balance_api_runtime"
  ],
  "controlled_paid_beta_status": "paid_controlled_beta_allowed_true_not_reopened",
  "next_task": "Wait for a real TODO-32I runtime artifact proving route/internal invocation, voucher storage/hash/redaction, redeem/idempotency/abuse/refund/audit readbacks, secret safety, and paid-gate neutrality."
}
```

### QA-CREDIT-32 / TODO-32J：Payment-order-invoice runtime verifier prep（2026-06-06）

QA hardened the TODO-32J runtime verifier path without implementing payment provider/runtime behavior. The verifier now has a runtime-positive fixture and negative selftests for missing provider handoff/callback readback, invoice/receipt readback, reconciliation readback, and idempotency/no-duplicate-write readback. Current repo evidence remains contract-only for payment/order/invoice runtime.

```json
{
  "task_id": "QA-CREDIT-32",
  "lane": "QA",
  "status": "payment_order_invoice_runtime_guard_prepared_contract_only_remains_false",
  "changed_files": [
    "scripts/verify_credit_wallet_ledger_surface.ps1",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "new_selftest_cases": [
    "payment_order_invoice_runtime_positive_accepted",
    "payment_order_invoice_runtime_missing_provider_callback_rejected",
    "payment_order_invoice_runtime_missing_invoice_receipt_rejected",
    "payment_order_invoice_runtime_missing_reconciliation_rejected",
    "payment_order_invoice_runtime_missing_idempotency_no_duplicate_rejected"
  ],
  "verifier_fields": {
    "opening_balance_import_runtime_verified": true,
    "credit_grant_crud_runtime_verified": true,
    "user_remaining_balance_admin_readonly_runtime_verified": true,
    "user_remaining_balance_runtime_verified": false,
    "recharge_voucher_contract_verified": true,
    "recharge_voucher_runtime_verified": false,
    "payment_order_invoice_contract_verified": true,
    "payment_order_invoice_runtime_verified": false,
    "subscription_package_lifecycle_contract_verified": true
  },
  "remaining_gaps": [
    "user_recharge_voucher_redemption_flow_runtime",
    "payment_order_invoice_lifecycle_runtime",
    "subscription_plan_lifecycle_runtime",
    "user_facing_remaining_balance_api_runtime"
  ],
  "controlled_paid_beta_status": "paid_controlled_beta_allowed_true_not_reopened",
  "next_task": "Wait for a real TODO-32J runtime artifact proving Control Plane route/runtime invocation, provider handoff and callback readback, order/capture/invoice/receipt/ledger/reconciliation/refund/audit readbacks, idempotency/no-duplicate-write behavior, secret safety, and paid-gate neutrality."
}
```

### QA-CREDIT-33 / TODO-32K：Subscription-package lifecycle runtime verifier prep（2026-06-06）

QA hardened the TODO-32K runtime verifier path without implementing subscription/package runtime behavior. E9-CREDIT-28 aligns that path on schema `subscription_package_lifecycle_runtime.v1`. The verifier now has a runtime-positive fixture and negative selftests for missing plan/package lifecycle readback, subscription state transition readback, trial/proration/dunning readback, credit/ledger effect readback, invoice/order linkage readback, idempotency/conflict/refusal no-write readback, audit readback, and secret safety. Current repo evidence remains contract-only for subscription/package lifecycle runtime.

```json
{
  "task_id": "QA-CREDIT-33",
  "lane": "QA",
  "status": "subscription_package_lifecycle_runtime_guard_prepared_contract_only_remains_false",
  "changed_files": [
    "scripts/verify_credit_wallet_ledger_surface.ps1",
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "new_selftest_cases": [
    "subscription_package_runtime_positive_accepted",
    "subscription_package_runtime_missing_plan_package_rejected",
    "subscription_package_runtime_missing_subscription_state_rejected",
    "subscription_package_runtime_missing_credit_ledger_effect_rejected",
    "subscription_package_runtime_missing_invoice_order_rejected",
    "subscription_package_runtime_missing_refusal_rejected",
    "subscription_package_runtime_missing_audit_rejected",
    "subscription_package_runtime_secret_unsafe_rejected"
  ],
  "verifier_fields": {
    "opening_balance_import_runtime_verified": true,
    "credit_grant_crud_runtime_verified": true,
    "user_remaining_balance_admin_readonly_runtime_verified": true,
    "user_remaining_balance_runtime_verified": false,
    "recharge_voucher_contract_verified": true,
    "recharge_voucher_runtime_verified": false,
    "payment_order_invoice_contract_verified": true,
    "payment_order_invoice_runtime_verified": false,
    "subscription_package_lifecycle_contract_verified": true,
    "subscription_package_lifecycle_runtime_verified": false
  },
  "remaining_gaps": [
    "user_recharge_voucher_redemption_flow_runtime",
    "payment_order_invoice_lifecycle_runtime",
    "subscription_plan_lifecycle_runtime",
    "user_facing_remaining_balance_api_runtime"
  ],
  "controlled_paid_beta_status": "paid_controlled_beta_allowed_true_not_reopened",
  "next_task": "Wait for a real TODO-32K runtime artifact proving Control Plane route/scheduler/runtime invocation, provider handoff, plan/package and subscription lifecycle readbacks, invoice/order and credit/ledger effects, renewal/dunning/refusal/audit readbacks, secret safety, and paid-gate neutrality."
}
```

### QA-CREDIT-38 / TODO-32H：Focused E11-CREDIT-20 acceptance watcher（2026-06-06）

QA consumed the refreshed E11-CREDIT-20 ownership runtime artifact and confirmed TODO-32H is now full user-session runtime verified. `.tmp/credit-wallet/user_remaining_balance_ownership_runtime.json` is `overall_status=pass` with `runtime_implemented=true`, `contract_only=false`, `user_api_runtime=true`, `ownership_scope_verified=true`, `auth_source=control_plane_user_session`, `server_side_lookup=true`, route/public-route invocation, tenant/project/wallet/user/currency ids, decimal-string balance fields, wallet/project/session/credit-grant/ledger/refusal readback, `missing_session_rejected=true`, `secret_safe=true`, and `paid_gate_changed=false`. The credit-wallet verifier exits 0 and reports full `user_remaining_balance_runtime_verified=true`; TODO-32I/J/K runtime lanes remain false and controlled paid beta is not reopened.

```json
{
  "task_id": "QA-CREDIT-38",
  "lane": "QA",
  "status": "todo_32h_full_user_remaining_balance_runtime_verified",
  "changed_files": [
    "docs/P0_BETA_STATUS.md",
    "TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md"
  ],
  "ownership_artifact_status": {
    "path": ".tmp/credit-wallet/user_remaining_balance_ownership_runtime.json",
    "overall_status": "pass",
    "runtime_implemented": true,
    "contract_only": false,
    "user_api_runtime": true,
    "ownership_scope_verified": true,
    "auth_source": "control_plane_user_session",
    "server_side_lookup": true,
    "secret_safe": true,
    "paid_gate_changed": false
  },
  "verifier_fields": {
    "user_remaining_balance_admin_readonly_runtime_verified": true,
    "user_remaining_balance_runtime_verified": true,
    "recharge_voucher_runtime_verified": false,
    "payment_order_invoice_runtime_verified": false,
    "subscription_package_lifecycle_runtime_verified": false
  },
  "remaining_gaps": [
    "user_recharge_voucher_redemption_flow_runtime",
    "payment_order_invoice_lifecycle_runtime",
    "subscription_plan_lifecycle_runtime"
  ],
  "controlled_paid_beta_status": "paid_controlled_beta_allowed_true_not_reopened",
  "next_task": "Continue watcher for TODO-32I/J/K runtime artifacts; do not treat contract-only artifacts as runtime acceptance."
}
```

### E11-CREDIT-13 / TODO-32G-S2：Admin credit grant lifecycle runtime shape（2026-06-05）

E11 completed the second Control Plane slice for TODO-32G without Gateway/Admin UI React changes. Control Plane now registers `GET /admin/credit-grants/{credit_grant_id}`, `POST /admin/credit-grants/{credit_grant_id}/expire`, and `POST /admin/credit-grants/{credit_grant_id}/revoke` alongside the existing create/list routes. RBAC maps list/read to `billing_read` and create/expire/revoke to `billing_adjust`; the RBAC fixture includes the new read/detail/lifecycle capabilities.

Runtime shape: expire/revoke run behind existing Admin/RBAC in a transaction, lock the grant row, lock idempotency by SHA-256 fingerprint, replay same key/body to the original lifecycle audit id, refuse same key/different body as `idempotency_conflict`, refuse wallet/currency/status guard failures, update status to `expired` or `voided`, and write success audit in the same transaction. Create replay now attempts original create audit lookup when available. Create validation rejects `FixedDecimal.units() <= 0`, including the QA-watched `-1.00000000` regression.

Artifact state at E11-CREDIT-13 time: `.tmp/credit-wallet/credit_grant_crud_contract.json` was refreshed with lifecycle implemented scope, `secret_safe=true`, `paid_gate_changed=false`, `runtime_implemented=false`, and `contract_only=true`. That contract-only state is superseded by main-thread TODO-32G-S3: `.tmp/credit-wallet/credit_grant_crud_runtime.json` is now a live runtime pass with Admin session + DB route matrix readback for create/list/read/expire/revoke/replay/conflict/refusal/audit.

```json
{
  "task_id": "E11-CREDIT-13",
  "parent_task_id": "TODO-32G",
  "status": "lifecycle_code_and_contract_pass_runtime_artifact_pending",
  "credit_grant_negative_amount_minus_one_test": "added",
  "credit_grant_crud_contract_verified": true,
  "credit_grant_crud_runtime_verified": false,
  "paid_gate_changed": false,
  "next_task": "E11-CREDIT-14 / TODO-32G-S3 live credit grant CRUD route matrix artifact with create/list/read/expire/revoke/replay/conflict/refusal/audit readback."
}
```

### 产品化缺口

以下缺口不应回退 controlled paid beta gate，但必须阻塞更广泛商业分发或自助商业化：

- Credit grant CRUD/API：创建、查询、暂停/过期、消费归因、remaining balance readback、grant source/provenance、audit。
- 充值/兑换码：top-up flow、redeem code issuance/redemption、幂等兑换、防刷/限速、退款/撤销策略。
- Payment/order/invoice：支付订单、provider payment intent/capture/refund、invoice/receipt、税务/币种/失败重试、账务对账。
- Subscription：plan、billing period、renewal、proration、trial、cancel/pause、quota/credit rollover policy。
- New API balance import opening ledger entry：从外部旧余额或首次充值导入时必须写 opening balance / credit grant / adjustment ledger entry，不能只改 wallet snapshot。
- User-facing remaining balance API：用户/项目/key 级剩余额度、pending reserve、active grants、budget remaining、last ledger ids、staleness marker、currency/scale、strong-consistency caveat。

### DoD

- [x] API contract reviewed from `docs/todo/slices/TODO-32-CREDIT-WALLET.md` and converted into implementation tickets: TODO-32A Admin read-only wallet/credit runtime, TODO-32B Billing credit grant contract tests, TODO-32C verifier expansion, TODO-32D commercial backlog split, TODO-32E Gateway impact watch.
- [ ] 设计并实现 credit grant CRUD/API contract，所有 money 字段使用 fixed decimal/string，不使用 float；写入必须有 idempotency key 和 audit。
- [ ] 充值/兑换码 flow 有 DB schema、API contract、幂等兑换、secret-safe artifact、abuse/rate-limit guard。
- [x] Payment/order/invoice 最小 contract：E9-CREDIT-23 已提供 contract fixture/test/artifact guard；runtime provider handoff、invoice/receipt production policy、tax/finance reconciliation 与 QA runtime artifact 仍 pending。
- [x] Subscription 最小 contract：E9-CREDIT-24 已提供 contract fixture/test/artifact guard；runtime plan/package APIs、recurring billing scheduler、provider retry/callback integration、invoice production、dunning execution、entitlement enforcement 与 QA runtime artifact 仍 pending。
- [ ] Opening balance/import path 写入明确 opening ledger entry 或 admin adjustment，禁止直接修改 wallet snapshot 作为账务事实。
- [ ] User-facing remaining balance API 返回 wallet + active grants + pending/confirmed ledger window + budgets 的可解释 summary，含 stale/estimated/strong-consistency markers。
- [ ] Contract tests 覆盖 grant CRUD、redeem idempotency、opening import、remaining balance readback、refund/adjustment interaction、secret-safe output。
- [ ] Live/DB smoke opt-in 验证 create grant -> reserve/settle/refund -> remaining balance readback -> reconciliation。

### MAIN-CREDIT-REVIEW-2026-06-06：TODO-32G/H agent pool sync

主线程复核当前 artifact/code/TODO 后确认：TODO-32F opening balance import 仍为 runtime verified；TODO-32G credit grant CRUD 已被后续 S3 live route matrix 接受为 runtime verified。当前 `.tmp/credit-wallet/credit_grant_crud_runtime.json` 为 `schema=credit_grant_crud_runtime.v1`、`overall_status=pass`、`runtime_implemented=true`、`contract_only=false`、`route_invoked=true`、`public_route_invoked=true`、`control_plane_runtime_current=true`、`secret_safe=true`、`paid_gate_changed=false`；`scripts/verify_credit_wallet_ledger_surface.ps1` 报告 `credit_grant_crud_runtime_verified=true`。

当前 5-agent 池子已重新派发：

- E11-CREDIT-13 / Popper：补 TODO-32G read-by-id、expire、revoke、RBAC、transaction audit、idempotency、OpenAPI/tests。主线程 Review 已追加一个必须修复点：`normalize_create_admin_credit_grant_request` 不能只拒绝 zero，必须拒绝 `amount <= 0`，否则 `non_positive_amount_refusal` contract 不成立。Replay 也不得在没有原 audit/readback 证据时声称 `audit_readback_passed=true`。
- E9-CREDIT-21 / Harvey：为 TODO-32H user-facing remaining balance 做 billing-ledger read-model contract/artifact，不实现 runtime，不改 Gateway/paid gate。
- QA-CREDIT-22 / Sagan：继续守 verifier；TODO-32G runtime pass 必须要求 route/internal invocation、grant/audit ids、create/list/read/expire/revoke/replay/refusal/audit readback、secret-safe、paid-gate neutral；同时预留 TODO-32H contract lane。
- DOC-CREDIT-27 / Copernicus：低频 watcher，只在 TODO-32G runtime artifact 或 TODO-32H artifact 出现时同步文档。
- E8-CREDIT-28 / Fermat：审当前 Gateway diff 是否影响 credit/balance paid hot path；TODO-32H 仍默认 Control Plane User/Admin API owner。

主线程验证：

```json
{
  "verify_credit_wallet_ledger_surface_selftest": "pass",
  "verify_credit_wallet_ledger_surface": {
    "exit_code": 0,
    "opening_balance_import_runtime_verified": true,
    "credit_grant_crud_contract_verified": true,
    "credit_grant_crud_runtime_verified": true,
    "remaining_gaps_include": [
      "user_facing_remaining_balance_api_runtime",
      "user_recharge_voucher_redemption_flow_runtime",
      "payment_order_invoice_lifecycle_runtime",
      "subscription_plan_lifecycle_runtime"
    ]
  },
  "scan_secrets": "pass_no_hits",
  "scoped_diff_check": "pass_with_e9_crlf_warning_only"
}
```

### QA-CREDIT-55 / TODO-32I-S6 strict runtime gate（2026-06-06，historical; superseded by DOC-CREDIT-56）

QA consumed the current recharge/voucher evidence after E11-CREDIT-26. The DB-plan artifact is useful partial evidence, but it is not runtime acceptance: `.tmp/credit-wallet/recharge_voucher_runtime_db_plan.json` is `schema=recharge_voucher_runtime_db_plan.v1`, `overall_status=partial`, `runtime_implemented=false`, `contract_only=true`, `db_plan.passed=true`, `secret_safe=true`, and `paid_gate_changed=false`. It still blocks on `route_runtime_not_invoked` and `qa_runtime_artifact_missing`.

No full `.tmp/credit-wallet/recharge_voucher_runtime.json` or `artifacts/credit_wallet_recharge_voucher_runtime.json` exists. `scripts/verify_credit_wallet_ledger_surface.ps1` exits 0 and keeps `recharge_voucher_runtime_verified=false`; TODO-32J/K runtime lanes also remain false. Runtime pass for TODO-32I still requires schema `recharge_voucher_runtime.v1`, `overall_status=pass`, `runtime_implemented=true`, `contract_only=false`, route/internal invocation proof, voucher storage/code-hash/redaction, redeem replay/refusal no-write, ledger or credit effect, refund/cancel reversal, audit readbacks, `secret_safe=true`, and `paid_gate_changed=false`.

```json
{
  "task_id": "QA-CREDIT-55",
  "status": "partial_db_plan_verified_runtime_pending",
  "runtime_mispromotion": false,
  "artifact_scan": {
    "db_plan_artifact": ".tmp/credit-wallet/recharge_voucher_runtime_db_plan.json",
    "db_plan_overall_status": "partial",
    "db_plan_passed": true,
    "runtime_artifact_exists": false
  },
  "verifier_fields": {
    "recharge_voucher_contract_verified": true,
    "recharge_voucher_runtime_verified": false,
    "payment_order_invoice_runtime_verified": false,
    "subscription_package_lifecycle_runtime_verified": false
  },
  "blockers": [
    "route_runtime_not_invoked",
    "qa_runtime_artifact_missing"
  ],
  "next_task": "E11-CREDIT-27 should emit full recharge_voucher_runtime.v1 route/internal runtime evidence before QA can mark TODO-32I runtime verified."
}
```

### QA-CREDIT-56 / TODO-32I-S7 E11-CREDIT-27 blocked runtime output consume（2026-06-06，historical; superseded by DOC-CREDIT-56）

QA consumed the E11-CREDIT-27 blocked output. `.tmp/credit-wallet/recharge_voucher_runtime_s6_blocked.json` exists with schema `recharge_voucher_runtime_s6_blocked.v1`, `overall_status=blocked`, `runtime_implemented=false`, `contract_only=true`, `route_invoked=false`, `internal_runtime_function_invoked=false`, `secret_safe=true`, and `paid_gate_changed=false`. This is not a runtime pass artifact and must not satisfy TODO-32I runtime acceptance.

The current DB-plan artifact remains partial evidence only: `.tmp/credit-wallet/recharge_voucher_runtime_db_plan.json` is `overall_status=partial`, `db_plan.passed=true`, `runtime_implemented=false`, and `contract_only=true`. No `.tmp/credit-wallet/recharge_voucher_runtime.json` or `artifacts/credit_wallet_recharge_voucher_runtime.json` exists. `scripts/verify_credit_wallet_ledger_surface.ps1` exits 0 and keeps `recharge_voucher_runtime_verified=false`; TODO-32J/K runtime lanes also remain false.

```json
{
  "task_id": "QA-CREDIT-56",
  "status": "blocked_runtime_output_consumed_runtime_pending",
  "runtime_mispromotion": false,
  "blocked_artifact": {
    "path": ".tmp/credit-wallet/recharge_voucher_runtime_s6_blocked.json",
    "schema": "recharge_voucher_runtime_s6_blocked.v1",
    "overall_status": "blocked",
    "runtime_implemented": false,
    "contract_only": true,
    "secret_safe": true,
    "paid_gate_changed": false
  },
  "verifier_fields": {
    "recharge_voucher_contract_verified": true,
    "recharge_voucher_runtime_verified": false,
    "payment_order_invoice_runtime_verified": false,
    "subscription_package_lifecycle_runtime_verified": false
  },
  "blockers": [
    "route_runtime_not_invoked",
    "internal_runtime_function_not_invoked",
    "refund_cancel_reversal_not_implemented",
    "qa_runtime_artifact_missing"
  ],
  "next_task": "E11-CREDIT-28 should emit full recharge_voucher_runtime.v1 evidence with route/internal invocation and refund/cancel reversal readback before QA can mark TODO-32I runtime verified."
}
```

### QA-CREDIT-57 / TODO-32I-S8 E11-CREDIT-28 runtime evidence watcher（2026-06-06，historical; superseded by DOC-CREDIT-56）

QA scanned E11-CREDIT-28 outputs and found no full runtime pass artifact. `.tmp/credit-wallet/recharge_voucher_runtime.json` and `artifacts/credit_wallet_recharge_voucher_runtime.json` are still missing. The existing `.tmp/credit-wallet/recharge_voucher_runtime_s6_blocked.json` remains blocked, and `.tmp/credit-wallet/recharge_voucher_runtime_db_plan.json` remains partial DB-plan evidence only. Both keep `runtime_implemented=false` / `contract_only=true` and cannot satisfy TODO-32I runtime acceptance.

`scripts/verify_credit_wallet_ledger_surface.ps1` exits 0 and still reports `recharge_voucher_contract_verified=true`, `recharge_voucher_runtime_verified=false`, `payment_order_invoice_runtime_verified=false`, and `subscription_package_lifecycle_runtime_verified=false`. `scripts/verify_recharge_voucher_runtime.ps1 -SelfTest` keeps the S6 blocked guard cases passing.

```json
{
  "task_id": "QA-CREDIT-57",
  "status": "no_full_runtime_artifact_runtime_pending",
  "runtime_mispromotion": false,
  "artifact_scan": {
    "runtime_artifact_exists": false,
    "blocked_artifact_exists": true,
    "db_plan_partial_exists": true
  },
  "verifier_fields": {
    "recharge_voucher_contract_verified": true,
    "recharge_voucher_runtime_verified": false,
    "payment_order_invoice_runtime_verified": false,
    "subscription_package_lifecycle_runtime_verified": false
  },
  "blockers": [
    "route_runtime_not_invoked",
    "internal_runtime_function_not_invoked",
    "refund_cancel_reversal_not_implemented",
    "qa_runtime_artifact_missing"
  ],
  "next_task": "E11-CREDIT-28/29 should emit full recharge_voucher_runtime.v1 evidence before QA can mark TODO-32I runtime verified."
}
```

### QA-CREDIT-58 / TODO-32I-S9 E11-CREDIT-28/29 runtime evidence watcher（2026-06-06，historical; superseded by DOC-CREDIT-56）

QA rescanned E11-CREDIT-28/29 outputs. No full runtime pass artifact exists at `.tmp/credit-wallet/recharge_voucher_runtime.json` or `artifacts/credit_wallet_recharge_voucher_runtime.json`. Current evidence remains the partial DB-plan artifact plus the S6 blocked artifact, both with `runtime_implemented=false` and `contract_only=true`.

The focused Control Plane recharge/voucher test run now reports `6 passed, 1 ignored`; the ignored test is the opt-in DB integration path and does not count as default runtime acceptance. `scripts/verify_credit_wallet_ledger_surface.ps1` exits 0 and still reports `recharge_voucher_runtime_verified=false`; TODO-32J/K runtime lanes also remain false.

```json
{
  "task_id": "QA-CREDIT-58",
  "status": "no_full_runtime_artifact_runtime_pending",
  "runtime_mispromotion": false,
  "artifact_scan": {
    "runtime_artifact_exists": false,
    "blocked_artifact_exists": true,
    "db_plan_partial_exists": true
  },
  "focused_tests": {
    "cargo_test_ai_control_plane_recharge_voucher": "6_passed_1_ignored"
  },
  "verifier_fields": {
    "recharge_voucher_contract_verified": true,
    "recharge_voucher_runtime_verified": false,
    "payment_order_invoice_runtime_verified": false,
    "subscription_package_lifecycle_runtime_verified": false
  },
  "blockers": [
    "route_runtime_not_invoked",
    "internal_runtime_function_not_invoked",
    "refund_cancel_reversal_not_implemented",
    "qa_runtime_artifact_missing"
  ],
  "next_task": "E11-CREDIT-29 should emit full recharge_voucher_runtime.v1 pass evidence or a new blocked artifact after opt-in runtime verification."
}
```

### QA-CREDIT-59 / TODO-32I-S10 runtime-or-blocked watcher（2026-06-06，historical; superseded by DOC-CREDIT-56）

QA rescanned E11-CREDIT-28/29 outputs and found no newer full runtime or blocked artifact beyond the existing partial DB-plan and S6 blocked artifacts. `.tmp/credit-wallet/recharge_voucher_runtime.json` and `artifacts/credit_wallet_recharge_voucher_runtime.json` remain missing.

The recharge runtime selftest now includes stricter pass guards: `runtime_pass_requires_reversal_and_internal_invocation` and `runtime_pass_rejects_missing_reversal` both pass. Main verifier remains `overall_status=pass_with_productization_gaps` with `recharge_voucher_runtime_verified=false`; default focused tests are `6 passed, 1 ignored`.

```json
{
  "task_id": "QA-CREDIT-59",
  "status": "no_new_runtime_or_blocked_artifact_runtime_pending",
  "runtime_mispromotion": false,
  "artifact_scan": {
    "runtime_artifact_exists": false,
    "blocked_artifact_exists": true,
    "db_plan_partial_exists": true
  },
  "verifier_fields": {
    "recharge_voucher_contract_verified": true,
    "recharge_voucher_runtime_verified": false,
    "payment_order_invoice_runtime_verified": false,
    "subscription_package_lifecycle_runtime_verified": false
  },
  "blockers": [
    "route_runtime_not_invoked",
    "internal_runtime_function_not_invoked",
    "refund_cancel_reversal_not_implemented",
    "qa_runtime_artifact_missing"
  ],
  "next_task": "QA-CREDIT-60 should consume the next E11-CREDIT-29 artifact only if it is a full recharge_voucher_runtime.v1 pass or a new blocked artifact."
}
```

### DOC-CREDIT-55 / TODO-32I-S10 docs watcher（2026-06-06，historical; superseded by DOC-CREDIT-56）

Docs rechecked the TODO-32I evidence after a new `.tmp/credit-wallet/recharge_voucher_runtime.json` appeared. At that time the artifact was not accepted as TODO-32I runtime evidence. This note is superseded by DOC-CREDIT-56, where the main verifier accepts the same runtime lane.

The missing verifier fields include voucher storage/code-hash/redaction readback, redeem/idempotency readback, abuse/refusal no-write readback, ledger-or-credit effect readback, refund/cancel reversal readback, and audit readback. TODO-32I therefore remains runtime false; TODO-32J/K runtime remain false; TODO-32F/G/H runtime true are preserved; controlled paid beta remains unchanged.

```json
{
  "task_id": "DOC-CREDIT-55",
  "status": "historical_runtime_artifact_present_but_not_verified_superseded",
  "artifact_path": ".tmp/credit-wallet/recharge_voucher_runtime.json",
  "artifact_schema": "recharge_voucher_runtime.v1",
  "artifact_overall_status": "pass",
  "recharge_voucher_runtime_verified": false,
  "payment_order_invoice_runtime_verified": false,
  "subscription_package_lifecycle_runtime_verified": false,
  "paid_gate_changed": false,
  "next_task": "QA/main should accept TODO-32I only after the recharge_voucher_runtime.v1 artifact includes all required readbacks and the main verifier reports recharge_voucher_runtime_verified=true."
}
```

### DOC-CREDIT-56 / TODO-32I-S11 accepted runtime sync（2026-06-06）

Docs re-read `.tmp/credit-wallet/recharge_voucher_runtime.json` and reran `scripts/verify_credit_wallet_ledger_surface.ps1`. The artifact is now accepted as TODO-32I runtime evidence: schema `recharge_voucher_runtime.v1`, `overall_status=pass`, `runtime_implemented=true`, `contract_only=false`, internal Rust/sqlx business path invocation true, `internal_sqlx_function_invoked=true`, `internal_runtime_function_invoked=true`, `secret_safe=true`, and `paid_gate_changed=false`.

Main verifier result: `overall_status=pass_with_productization_gaps`, `recharge_voucher_runtime_verified=true`, `payment_order_invoice_runtime_verified=false`, and `subscription_package_lifecycle_runtime_verified=false`. Accepted readbacks include voucher storage, voucher code hash/redacted output, redeem, redeem idempotency, abuse/refusal no-write, ledger-or-credit effect, refund/cancel reversal, and audit. This verifies TODO-32I through the internal Rust/sqlx business path; public route/product UX remains follow-up polish, not a blocker to this verifier acceptance. TODO-32F/G/H runtime verified remain true, TODO-32J/K runtime remain false, and controlled paid beta is unchanged.

```json
{
  "task_id": "DOC-CREDIT-56",
  "status": "todo_32i_runtime_verified",
  "artifact_path": ".tmp/credit-wallet/recharge_voucher_runtime.json",
  "artifact_schema": "recharge_voucher_runtime.v1",
  "artifact_overall_status": "pass",
  "recharge_voucher_runtime_verified": true,
  "payment_order_invoice_runtime_verified": false,
  "subscription_package_lifecycle_runtime_verified": false,
  "paid_gate_changed": false,
  "next_task": "Keep TODO-32J payment/order/invoice and TODO-32K subscription/package lifecycle runtime lanes pending until their runtime artifacts verify."
}
```

### QA-CREDIT-60 / TODO-32I-S11 runtime acceptance（2026-06-06）

QA re-read `.tmp/credit-wallet/recharge_voucher_runtime.json` directly after the race-window update and accepted it as TODO-32I runtime evidence. The artifact is `schema=recharge_voucher_runtime.v1`, `overall_status=pass`, `runtime_implemented=true`, `contract_only=false`, `internal_runtime_function_invoked=true`, `internal_sqlx_function_invoked=true`, `db_integration_ran=true`, `secret_safe=true`, and `paid_gate_changed=false`. `route_invoked=false` is acceptable for this QA acceptance because the internal runtime business path is proven; this does not claim public route or commercial payment-provider readiness.

QA checked voucher storage/code-hash/redaction, raw code not echoed, redeem readback, idempotency replay, abuse/refusal no-write, ledger-or-credit effect, refund/cancel reversal, and audit readbacks. `scripts/verify_credit_wallet_ledger_surface.ps1` exits 0 and reports `recharge_voucher_runtime_verified=true`; TODO-32J/K runtime lanes remain false.

```json
{
  "task_id": "QA-CREDIT-60",
  "status": "accepted_internal_runtime_verified",
  "artifact_path": ".tmp/credit-wallet/recharge_voucher_runtime.json",
  "artifact_schema": "recharge_voucher_runtime.v1",
  "artifact_overall_status": "pass",
  "runtime_path": "internal_rust_sqlx_business_path",
  "public_route_verified": false,
  "recharge_voucher_runtime_verified": true,
  "payment_order_invoice_runtime_verified": false,
  "subscription_package_lifecycle_runtime_verified": false,
  "secret_safe": true,
  "paid_gate_changed": false,
  "next_task": "Continue with TODO-32J payment/order/invoice runtime or public route/product UX polish as separate follow-up."
}
```

### QA-CREDIT-61 / TODO-32J-S1 payment-order-invoice runtime gate（2026-06-06）

QA moved from TODO-32I to TODO-32J and rechecked payment/order/invoice runtime acceptance. Current scan found `.tmp/credit-wallet/payment_order_invoice_contract.json` only; `.tmp/credit-wallet/payment_order_invoice_runtime.json` and `artifacts/credit_wallet_payment_order_invoice_runtime.json` are absent. The contract artifact remains accepted as contract-only evidence (`schema=payment_order_invoice_contract.v1`, `status=pass`, `runtime_implemented=false`, `contract_only=true`, `secret_safe=true`, `paid_gate_changed=false`).

`scripts/verify_payment_order_invoice_runtime.ps1` default run writes `.tmp/credit-wallet/payment_order_invoice_runtime_s1_blocked.json` as a blocked sidecar, not a runtime pass artifact. It reports `overall_status=blocked`, `actual_exit_code=2`, `runtime_implemented=false`, `contract_only=true`, `route_invoked=false`, `internal_runtime_function_invoked=false`, `internal_sqlx_function_invoked=false`, `secret_safe=true`, and `paid_gate_changed=false`. Blockers remain payment/order/invoice runtime invocation, provider handoff/callback or capture readback, invoice/receipt readback, refund/cancel/chargeback reversal readback, and reconciliation readback.

```json
{
  "task_id": "QA-CREDIT-61",
  "qa_acceptance_verdict": "blocked_runtime_pending",
  "payment_order_invoice_contract_verified": true,
  "payment_order_invoice_runtime_verified": false,
  "payment_runtime_sidecar": ".tmp/credit-wallet/payment_order_invoice_runtime_s1_blocked.json",
  "runtime_mispromotion": false,
  "secret_scan": "pass",
  "paid_gate_changed": false,
  "next_task": "Wait for a real payment_order_invoice_runtime.v1 pass artifact with route/internal runtime invocation, provider/callback or bounded internal policy evidence, invoice/receipt, ledger-or-credit, reversal, idempotency, audit, reconciliation, secret safety, and paid-gate neutrality."
}
```

### QA-CREDIT-62 / TODO-32J-S2 payment-order-invoice current-tree recheck（2026-06-06）

QA rechecked for E11-CREDIT-30/S2 payment-order-invoice output. At that point, scan found no `.tmp/credit-wallet/payment_order_invoice_runtime.json`, no `.tmp/credit-wallet/payment_order_invoice_runtime_s2_blocked.json`, and no `artifacts/credit_wallet_payment_order_invoice_runtime.json`. Schema/OpenAPI grep found the required payment/order/invoice table names only in `scripts/verify_payment_order_invoice_runtime.ps1`; QA-CREDIT-63 supersedes this schema observation after `0013_payment_order_invoice_boundary.sql` landed.

`scripts/verify_payment_order_invoice_runtime.ps1` default run still wrote the S1 blocked sidecar. That earlier run exited 2 and reported `overall_status=blocked`, `actual_exit_code=2`, `runtime_implemented=false`, `contract_only=true`, `route_invoked=false`, `internal_runtime_function_invoked=false`, `internal_sqlx_function_invoked=false`, `db_integration_ran=false`, `secret_safe=true`, `paid_gate_changed=false`, and `schema_all_required_tables_present=false`. QA-CREDIT-63 updates the current schema result to `schema_all_required_tables_present=true`; runtime blockers remain runtime invocation, provider handoff/callback or capture readback, invoice/receipt readback, refund/cancel/chargeback reversal readback, and reconciliation readback.

```json
{
  "task_id": "QA-CREDIT-62",
  "qa_acceptance_verdict": "blocked_runtime_pending",
  "payment_order_invoice_contract_verified": true,
  "payment_order_invoice_runtime_verified": false,
  "runtime_pass_artifact_found": false,
  "s2_blocked_artifact_found": false,
  "runtime_mispromotion": false,
  "recharge_voucher_runtime_verified": true,
  "secret_scan": "pass",
  "paid_gate_changed": false,
  "next_task": "Wait for E11/Product/Finance to produce a payment_order_invoice_runtime.v1 pass artifact or a new S2 blocked artifact after schema/runtime progress."
}
```

### QA-CREDIT-63 / TODO-32J-S3 schema-progress correction（2026-06-06）

QA rechecked current tree after the main-thread schema update. `db/migrations/0013_payment_order_invoice_boundary.sql` and `examples/sql_schema_draft.sql` now contain the verifier-required payment/order/invoice tables: `payment_orders`, `payment_intents`, `payment_captures`, `payment_refunds`, `invoices`, `invoice_receipts`, and `payment_reconciliations`. `scripts/verify_payment_order_invoice_runtime.ps1` default run now reports `diagnostics.schema.all_required_tables_present=true` and `missing_tables=[]`, so QA no longer treats `payment_order_invoice_schema_missing` as a current blocker.

Runtime remains blocked and must not be promoted. No `.tmp/credit-wallet/payment_order_invoice_runtime.json` or `artifacts/credit_wallet_payment_order_invoice_runtime.json` pass artifact exists. The blocked sidecars are `.tmp/credit-wallet/payment_order_invoice_runtime_s1_blocked.json` and `.tmp/credit-wallet/payment_order_invoice_runtime_s2_blocked.json`; both report `overall_status=blocked`, `runtime_implemented=false`, `contract_only=true`, no route/internal runtime invocation, `secret_safe=true`, and `paid_gate_changed=false`.

```json
{
  "task_id": "QA-CREDIT-63",
  "schema_blocker_current": false,
  "payment_order_invoice_contract_verified": true,
  "payment_order_invoice_runtime_verified": false,
  "runtime_pass_artifact_found": false,
  "active_blockers": [
    "payment_order_invoice_runtime_not_invoked",
    "payment_provider_handoff_runtime_missing",
    "provider_callback_or_capture_readback_missing",
    "invoice_receipt_runtime_missing",
    "refund_cancel_chargeback_reversal_runtime_missing",
    "payment_order_invoice_reconciliation_readback_missing"
  ],
  "regression_blocker": "cargo test -p ai-control-plane recharge_voucher currently fails to compile in apps/control-plane/src/admin.rs due serde_json::json! recursion limit in new payment_order_invoice_runtime artifact construction; QA did not modify E11-owned code.",
  "paid_gate_changed": false,
  "next_task": "E11 should fix the compile blocker and then produce either a precise S2 blocked artifact or a full payment_order_invoice_runtime.v1 pass artifact."
}
```

### QA-CREDIT-64 / TODO-32J-S3 E11-CREDIT-30A compile blocker verification（2026-06-06）

QA rechecked the E11-CREDIT-30A current tree after the `serde_json::json!` recursion-limit blocker reported by QA-CREDIT-63. The exact recharge/voucher regression command now compiles and passes, and payment/order/invoice focused tests also compile and pass. This clears the compile blocker as current QA status; QA did not modify E11-owned implementation code.

Payment/order/invoice runtime is still not accepted. Artifact scan still finds no `.tmp/credit-wallet/payment_order_invoice_runtime.json` and no `artifacts/credit_wallet_payment_order_invoice_runtime.json`. The blocked sidecars `.tmp/credit-wallet/payment_order_invoice_runtime_s1_blocked.json` and `.tmp/credit-wallet/payment_order_invoice_runtime_s2_blocked.json` remain blocked evidence only. The S2 sidecar reports `overall_status=blocked`, `actual_exit_code=2`, `runtime_implemented=false`, `contract_only=true`, `route_invoked=false`, `internal_runtime_function_invoked=false`, `internal_sqlx_function_invoked=false`, `secret_safe=true`, and `paid_gate_changed=false`.

```json
{
  "task_id": "QA-CREDIT-64",
  "compile_blocker_status": "cleared",
  "payment_order_invoice_contract_verified": true,
  "payment_order_invoice_runtime_verified": false,
  "schema_blocker_current": false,
  "runtime_pass_artifact_found": false,
  "s2_blocked_artifact_found": true,
  "runtime_mispromotion": false,
  "secret_scan": "pass",
  "paid_gate_changed": false,
  "next_task": "Wait for a real payment_order_invoice_runtime.v1 pass artifact after runtime/provider/invoice/reversal/reconciliation readback progress."
}
```

### E11-CREDIT-30A / TODO-32J compile blocker fix（2026-06-06）

E11 fixed the transient compile blocker reported by QA-CREDIT-63. The new `payment_order_invoice_runtime.v1` artifact builder in `apps/control-plane/src/admin.rs` no longer uses one large nested `serde_json::json!` expansion; it builds the base object with `serde_json::Map` / `Value::Object` and inserts dynamic evidence fields incrementally. Artifact field names and verifier expectations are preserved.

Verification after the fix: `cargo test -p ai-control-plane recharge_voucher -- --nocapture` passes, `cargo test -p ai-control-plane payment_order_invoice -- --nocapture` passes, `scripts/verify_payment_order_invoice_runtime.ps1 -SelfTest` passes, `scripts/verify_credit_wallet_ledger_surface.ps1` exits 0, and secret scan passes. TODO-32J remains runtime false: no accepted `.tmp/credit-wallet/payment_order_invoice_runtime.json` pass artifact exists yet.

```json
{
  "task_id": "E11-CREDIT-30A",
  "compile_blocker_fixed": true,
  "artifact_shape_changed": false,
  "payment_order_invoice_contract_verified": true,
  "payment_order_invoice_runtime_verified": false,
  "paid_gate_changed": false
}
```

### DOC-CREDIT-57 / TODO-32J-S2 docs sync watcher（2026-06-06）

Docs rechecked E11-CREDIT-30 / E9-CREDIT-46 / QA-CREDIT-62 / E8-CREDIT-87 status for payment/order/invoice. Current scan still finds no accepted `.tmp/credit-wallet/payment_order_invoice_runtime.json` and no `artifacts/credit_wallet_payment_order_invoice_runtime.json`. `.tmp/credit-wallet/payment_order_invoice_contract.json` remains accepted contract-only evidence, while `.tmp/credit-wallet/payment_order_invoice_runtime_s1_blocked.json` and `.tmp/credit-wallet/payment_order_invoice_runtime_s2_blocked.json` remain blocked sidecars with `overall_status=blocked`, `runtime_implemented=false`, `contract_only=true`, no route/internal runtime invocation, `secret_safe=true`, and `paid_gate_changed=false`.

Current TODO-32J status is contract verified / runtime false. QA-CREDIT-63 supersedes the earlier schema blocker: `payment_order_invoice_schema_missing` is no longer current after `db/migrations/0013_payment_order_invoice_boundary.sql` and `examples/sql_schema_draft.sql` landed the required tables. Remaining blockers are `payment_order_invoice_runtime_not_invoked`, `payment_provider_handoff_runtime_missing`, `provider_callback_or_capture_readback_missing`, `invoice_receipt_runtime_missing`, `refund_cancel_chargeback_reversal_runtime_missing`, and `payment_order_invoice_reconciliation_readback_missing`. TODO-32I recharge/voucher remains runtime verified; TODO-32K subscription/package runtime remains false; controlled paid beta is unchanged.

```json
{
  "task_id": "DOC-CREDIT-57",
  "payment_order_invoice_contract_verified": true,
  "payment_order_invoice_runtime_verified": false,
  "runtime_pass_artifact_found": false,
  "s2_blocked_artifact_found": true,
  "s1_blocked_sidecar_is_runtime": false,
  "recharge_voucher_runtime_verified": true,
  "subscription_package_lifecycle_runtime_verified": false,
  "paid_gate_changed": false
}
```

### DOC-CREDIT-58 / TODO-32J-S4 docs watcher after schema closure（2026-06-06）

Docs rechecked E11-CREDIT-30A / QA-CREDIT-64 / E9-CREDIT-48 / E8-CREDIT-90 after the TODO-32J schema blocker closed. Current evidence remains runtime false: `.tmp/credit-wallet/payment_order_invoice_runtime.json` and `artifacts/credit_wallet_payment_order_invoice_runtime.json` are absent. `.tmp/credit-wallet/payment_order_invoice_runtime_s1_blocked.json` and `.tmp/credit-wallet/payment_order_invoice_runtime_s2_blocked.json` both have schema `payment_order_invoice_runtime.v1`, `overall_status=blocked`, `runtime_implemented=false`, `contract_only=true`, no route/internal runtime invocation, `schema.all_required_tables_present=true`, `missing_tables=[]`, `secret_safe=true`, and `paid_gate_changed=false`.

E11-CREDIT-30A / QA-CREDIT-64 clear the transient `serde_json::json!` recursion-limit compile blocker, but that is not runtime acceptance. `scripts/verify_credit_wallet_ledger_surface.ps1` still exits 0 with `payment_order_invoice_contract_verified=true` and `payment_order_invoice_runtime_verified=false`. Remaining blockers are runtime invocation, provider callback/capture or bounded internal policy, invoice/receipt runtime/readback, refund/cancel/chargeback reversal readback, reconciliation/readbacks, and lack of a non-contract pass artifact. TODO-32I remains runtime verified, TODO-32K remains runtime false, and controlled paid beta is unchanged.

```json
{
  "task_id": "DOC-CREDIT-58",
  "payment_order_invoice_contract_verified": true,
  "payment_order_invoice_schema_present": true,
  "payment_order_invoice_runtime_verified": false,
  "runtime_pass_artifact_found": false,
  "s2_blocked_artifact_found": true,
  "recharge_voucher_runtime_verified": true,
  "subscription_package_lifecycle_runtime_verified": false,
  "paid_gate_changed": false
}
```

### DOC-CREDIT-59 / TODO-32J-S5 docs watcher for E11-CREDIT-31 output（2026-06-06）

Docs rechecked E11-CREDIT-31 / E9-CREDIT-49 / QA-CREDIT-65 / E8-CREDIT-91. No accepted `payment_order_invoice_runtime.v1` pass artifact is present: `.tmp/credit-wallet/payment_order_invoice_runtime.json` and `artifacts/credit_wallet_payment_order_invoice_runtime.json` are absent. No S3 blocked/partial artifact is present yet. Existing S1/S2 blocked sidecars remain non-runtime evidence only; both keep schema-present diagnostics (`schema.all_required_tables_present=true`, `missing_tables=[]`) and `runtime_implemented=false`.

Current TODO-32J state remains contract true / schema present / runtime false. `scripts/verify_credit_wallet_ledger_surface.ps1` still exits 0 with `payment_order_invoice_contract_verified=true` and `payment_order_invoice_runtime_verified=false`. Remaining blockers are runtime invocation, provider callback/capture or bounded internal policy, invoice/receipt runtime/readback, refund/cancel/chargeback reversal readback, reconciliation/readbacks, and lack of a non-contract pass artifact. TODO-32I remains runtime verified, TODO-32K remains runtime false, and controlled paid beta is unchanged.

```json
{
  "task_id": "DOC-CREDIT-59",
  "payment_order_invoice_contract_verified": true,
  "payment_order_invoice_schema_present": true,
  "payment_order_invoice_runtime_verified": false,
  "runtime_pass_artifact_found": false,
  "s3_blocked_or_partial_artifact_found": false,
  "s1_s2_blocked_sidecars_are_runtime": false,
  "recharge_voucher_runtime_verified": true,
  "subscription_package_lifecycle_runtime_verified": false,
  "paid_gate_changed": false
}
```

### E11-CREDIT-31-DEFER / TODO-32J deferred runtime handoff（2026-06-06）

User clarified that when the runtime/provider/callback capability is genuinely unavailable, the lane should be deferred with clear resume conditions instead of keeping agents spinning. E11 preserved the current evidence and wrote `.tmp/credit-wallet/payment_order_invoice_runtime_deferred.json` with `schema=payment_order_invoice_runtime_deferred.v1`, `overall_status=deferred_runtime_external_dependency`, `runtime_implemented=false`, `contract_only=true`, `route_invoked=false`, `internal_runtime_function_invoked=false`, `secret_safe=true`, `paid_gate_changed=false`, and `production_distribution_ready=false`.

Current facts remain unchanged: TODO-32I recharge/voucher runtime is verified; TODO-32J payment/order/invoice contract is verified and schema is present; TODO-32J runtime is false; TODO-32K runtime is false. Resume TODO-32J only when provider callback/capture or an approved bounded internal simulation policy is available, invoice/receipt runtime readback is available, refund/cancel/chargeback reversal readback is available, reconciliation readback is available, and `.tmp/credit-wallet/payment_order_invoice_runtime.json` can pass the verifier and main credit-wallet surface check. Controlled paid beta is unchanged.

```json
{
  "task_id": "E11-CREDIT-31-DEFER",
  "defer_status": "deferred_runtime_external_dependency",
  "payment_order_invoice_contract_verified": true,
  "payment_order_invoice_schema_present": true,
  "payment_order_invoice_runtime_verified": false,
  "production_distribution_ready": false,
  "paid_gate_changed": false,
  "recommended_next_task": "Move E11 to TODO-32K contract/schema/defer assessment or public recharge/voucher route polish if prerequisites are available."
}
```

### QA-CREDIT-66 / TODO-32J defer guard（2026-06-06）

QA consumed the defer posture and verified it is a non-runtime state, not a QA failure and not a runtime pass. Current artifacts remain safe: `.tmp/credit-wallet/payment_order_invoice_contract.json` is contract `status=pass`, `runtime_implemented=false`, `contract_only=true`, `secret_safe=true`, `paid_gate_changed=false`; `.tmp/credit-wallet/payment_order_invoice_runtime_s1_blocked.json` and `.tmp/credit-wallet/payment_order_invoice_runtime_s2_blocked.json` are blocked sidecars with `runtime_implemented=false`, `contract_only=true`, no route/internal runtime invocation, `secret_safe=true`, `paid_gate_changed=false`, and schema diagnostics `all_required_tables_present=true`; `.tmp/credit-wallet/payment_order_invoice_runtime_deferred.json` is `overall_status=deferred_runtime_external_dependency`, `runtime_implemented=false`, `contract_only=true`, `secret_safe=true`, `paid_gate_changed=false`, and `production_distribution_ready=false`.

The main verifier still exits 0 with `payment_order_invoice_contract_verified=true` and `payment_order_invoice_runtime_verified=false`; it preserves `recharge_voucher_runtime_verified=true` and `subscription_package_lifecycle_runtime_verified=false`. TODO-32J should not be actively watched for runtime pass until a new provider/callback capability, approved bounded internal policy, invoice/receipt readback, refund/cancel/chargeback reversal readback, reconciliation readback, and accepted `payment_order_invoice_runtime.v1` artifact are available.

```json
{
  "task_id": "QA-CREDIT-66",
  "qa_defer_verdict": "deferred_runtime_external_dependency",
  "payment_order_invoice_contract_verified": true,
  "payment_order_invoice_runtime_verified": false,
  "recharge_voucher_runtime_verified": true,
  "subscription_package_lifecycle_runtime_verified": false,
  "runtime_mispromotion": false,
  "paid_gate_changed": false,
  "recommended_next_task": "Move QA to TODO-32K contract/runtime defer gate or TODO-32I public recharge/voucher route polish gate."
}
```

### DOC-CREDIT-60 / TODO-32J defer documentation and next focus（2026-06-06）

Docs/Product accepts the TODO-32J defer posture. TODO-32J is not complete and is not a release pass: current status is `payment_order_invoice_contract_verified=true`, schema present, `payment_order_invoice_runtime_verified=false`, and `.tmp/credit-wallet/payment_order_invoice_runtime_deferred.json` records `overall_status=deferred_runtime_external_dependency`. The defer is caused by unavailable external payment runtime/provider callback/capture capability, or unavailable approved bounded internal simulation policy, not by a schema blocker.

Resume checklist for TODO-32J:
- provider/callback/capture or approved bounded internal simulation policy;
- invoice/receipt runtime readback;
- refund/cancel/chargeback reversal readback;
- reconciliation readback;
- idempotency/conflict no-duplicate readback;
- audit, fixed-decimal, and secret-safe proof;
- accepted non-contract `payment_order_invoice_runtime.v1` pass artifact;
- main verifier `payment_order_invoice_runtime_verified=true`.

Preserved facts: TODO-32I recharge/voucher runtime remains verified; TODO-32J contract and schema remain verified but runtime remains false; TODO-32K runtime remains false; controlled paid beta is unchanged. Recommended next locally actionable focus: TODO-32K contract/schema/defer assessment, or public recharge/voucher route/product polish if the route/product owner has prerequisites available.

```json
{
  "task_id": "DOC-CREDIT-60",
  "todo_32j_status": "deferred_runtime_external_dependency",
  "payment_order_invoice_contract_verified": true,
  "payment_order_invoice_schema_present": true,
  "payment_order_invoice_runtime_verified": false,
  "release_pass": false,
  "paid_gate_changed": false,
  "recommended_next_focus": [
    "TODO-32K contract/schema/defer assessment",
    "public recharge/voucher route/product polish"
  ]
}
```

### QA-CREDIT-67 / TODO-32K-S1 subscription-package defer guard（2026-06-06）

QA moved from TODO-32J defer to TODO-32K and verified the subscription/package lifecycle gate. Current artifact scan finds `.tmp/credit-wallet/subscription_package_lifecycle_contract.json` only as contract evidence; no accepted `.tmp/credit-wallet/subscription_package_lifecycle_runtime.json` or `artifacts/credit_wallet_subscription_package_lifecycle_runtime.json` exists. QA wrote `.tmp/credit-wallet/subscription_package_lifecycle_runtime_deferred.json` as explicit defer evidence with `schema=subscription_package_lifecycle_runtime_deferred.v1`, `overall_status=deferred_runtime_external_dependency`, `runtime_implemented=false`, `contract_only=true`, `scheduler_runtime_invoked=false`, `provider_callback_runtime_available=false`, `invoice_order_runtime_available=false`, `secret_safe=true`, `paid_gate_changed=false`, and `production_distribution_ready=false`.

The main verifier exits 0 with `subscription_package_lifecycle_contract_verified=true` and `subscription_package_lifecycle_runtime_verified=false`; it also preserves `recharge_voucher_runtime_verified=true` and `payment_order_invoice_runtime_verified=false`. Contract/defer artifacts must not be promoted to runtime. Runtime pass acceptance remains: plan/package CRUD readback, subscription lifecycle state transitions, trial/proration/dunning readback, credit/ledger effect readback, invoice/order linkage, idempotency/conflict/refusal no-write, audit, renewal/cancel/pause/resume, fixed-decimal money, secret safety, paid-gate neutrality, and an accepted non-contract `subscription_package_lifecycle_runtime.v1` artifact.

```json
{
  "task_id": "QA-CREDIT-67",
  "qa_verdict": "deferred_runtime_external_dependency",
  "subscription_package_lifecycle_contract_verified": true,
  "subscription_package_lifecycle_runtime_verified": false,
  "runtime_mispromotion": false,
  "recharge_voucher_runtime_verified": true,
  "payment_order_invoice_runtime_verified": false,
  "paid_gate_changed": false,
  "recommended_next_task": "Continue TODO-32K only if runtime/scheduler/provider/invoice prerequisites appear; otherwise move to TODO-32I public route polish or another available QA lane."
}
```

### DOC-CREDIT-61 / TODO-32K-S1 docs sync and defer assessment（2026-06-06）

Docs/Product consumed the TODO-32K contract/schema/defer state. Current posture: TODO-32I recharge/voucher runtime remains verified; TODO-32J payment/order/invoice remains `deferred_runtime_external_dependency` with runtime false; TODO-32K subscription/package lifecycle is contract/schema-ready but runtime-deferred, not complete and not a release pass.

Artifact scan: `.tmp/credit-wallet/subscription_package_lifecycle_contract.json` exists with schema `subscription_package_lifecycle_contract.v1`, `status=pass`, `runtime_implemented=false`, `contract_only=true`, `secret_safe=true`, and `paid_gate_changed=false`; `.tmp/credit-wallet/subscription_package_lifecycle_runtime_deferred.json` exists with schema `subscription_package_lifecycle_runtime_deferred.v1`, `overall_status=deferred_runtime_external_dependency`, `runtime_implemented=false`, `contract_only=true`, `secret_safe=true`, `paid_gate_changed=false`, and `production_distribution_ready=false`; no `.tmp/credit-wallet/subscription_package_lifecycle_runtime.json` or `artifacts/credit_wallet_subscription_package_lifecycle_runtime.json` pass artifact exists.

TODO-32K resume checklist: scheduler/renewal trigger; trial/proration/dunning policy; invoice/order linkage runtime; credit/ledger effect readback; cancel/pause/resume readback; idempotency/conflict/no-write readback; audit and reconciliation readback; accepted non-contract `subscription_package_lifecycle_runtime.v1` pass artifact with main verifier `subscription_package_lifecycle_runtime_verified=true`. Controlled paid beta remains unchanged.

```json
{
  "task_id": "DOC-CREDIT-61",
  "todo_32i_runtime_verified": true,
  "todo_32j_status": "deferred_runtime_external_dependency",
  "todo_32j_runtime_verified": false,
  "todo_32k_status": "deferred_runtime_external_dependency",
  "todo_32k_contract_verified": true,
  "todo_32k_runtime_verified": false,
  "release_pass": false,
  "paid_gate_changed": false,
  "recommended_next_focus": [
    "TODO-32K scheduler/provider/invoice prerequisite decision",
    "public recharge/voucher route/product polish"
  ]
}
```

### QA-CREDIT-68 / TODO-32I public recharge-voucher route polish gate（2026-06-06）

QA moved to the locally actionable TODO-32I polish lane and explicitly separated accepted internal runtime from public route readiness. Current OpenAPI/admin skeleton documents contract-only `POST /billing/recharge-intents`, `POST /admin/voucher-campaigns`, `POST /admin/voucher-issuances`, and `POST /billing/vouchers/redeem`; focused Control Plane tests cover schema/OpenAPI boundaries, hash/redaction, idempotency/refusal no-write, and secret-safe contract behavior. The accepted runtime artifact remains `.tmp/credit-wallet/recharge_voucher_runtime.json` with `schema=recharge_voucher_runtime.v1`, `overall_status=pass`, `runtime_implemented=true`, `contract_only=false`, `internal_runtime_function_invoked=true`, `internal_sqlx_function_invoked=true`, `route_invoked=false`, voucher storage/hash/redaction, redeem/idempotency, abuse/refusal no-write, ledger-or-credit effect, refund/cancel reversal, audit readbacks, `secret_safe=true`, and `paid_gate_changed=false`.

QA verdict: keep `recharge_voucher_runtime_verified=true` for the internal Rust/sqlx business path, but mark public route/product polish as `public_route_polish_pending`. Public route pass requires route invocation, auth/RBAC or ownership scope, idempotency, redaction, audit, ledger/credit readbacks, refusal no-write, `secret_safe=true`, and `paid_gate_changed=false`. This does not reopen TODO-32I runtime acceptance and does not change controlled paid beta.

```json
{
  "task_id": "QA-CREDIT-68",
  "recharge_voucher_runtime_verified": true,
  "public_route_verified": false,
  "public_route_polish_status": "public_route_polish_pending",
  "route_invoked": false,
  "internal_runtime_function_invoked": true,
  "internal_sqlx_function_invoked": true,
  "secret_safe": true,
  "paid_gate_changed": false,
  "recommended_next_task": "Product/E11 can wire public/admin route invocation evidence for recharge/voucher, or QA can move to another available product-polish lane."
}
```

### 非目标

- 不改变 TODO-13/TODO-30 controlled paid beta acceptance。
- 不把 credit productization 当作 Gateway hot-path evidence blocker。
- 不在没有 payment/order/invoice/reconciliation 前对外承诺完整商业自助充值或 subscription billing。

### E11-CREDIT-32 / TODO-32K subscription-package lifecycle defer assessment（2026-06-06）

E11 consumed the existing TODO-32K contract artifact and moved the lane into a clean deferred runtime handoff. `.tmp/credit-wallet/subscription_package_lifecycle_contract.json` remains accepted as contract evidence only: `schema=subscription_package_lifecycle_contract.v1`, `status=pass`, `runtime_implemented=false`, `contract_only=true`, `secret_safe=true`, and `paid_gate_changed=false`. It contains `subscription_package_lifecycle_schema_contract.v1`; E11-CREDIT-33 later adds the durable schema migration, but no runtime route/scheduler evidence is claimed.

E11 added `scripts/verify_subscription_package_lifecycle_runtime.ps1`. `-SelfTest` verifies contract-only evidence cannot promote runtime, raw secret markers are rejected, and runtime acceptance requires route/internal runtime or scheduler proof. Default mode writes `.tmp/credit-wallet/subscription_package_lifecycle_runtime_deferred.json` with `schema=subscription_package_lifecycle_runtime_deferred.v1`, `overall_status=deferred_runtime_external_dependency`, `actual_exit_code=2`, `runtime_implemented=false`, `contract_only=true`, `route_invoked=false`, `internal_runtime_function_invoked=false`, `scheduler_invoked=false`, `secret_safe=true`, `paid_gate_changed=false`, and `production_distribution_ready=false`.

Current diagnostics after E11-CREDIT-33: durable schema migration `db/migrations/0014_subscription_package_lifecycle_boundary.sql` is present for `subscription_plans`, `subscription_packages`, `subscriptions`, and `subscription_events_or_schedules`, superseding the earlier schema-migration-missing blocker. Runtime remains false because plan/package CRUD, subscription lifecycle/state transitions, trial/proration/dunning scheduler or callback, credit/ledger effects, invoice/order linkage, renewal/cancel/pause/resume readback, idempotency/conflict/refusal no-write, audit, and reconciliation are not proven.

```json
{
  "task_id": "E11-CREDIT-32",
  "todo_32k_status": "deferred_runtime_external_dependency",
  "subscription_package_lifecycle_contract_verified": true,
  "subscription_package_lifecycle_schema_contract_present": true,
  "subscription_package_lifecycle_schema_migration_present": true,
  "subscription_package_lifecycle_runtime_verified": false,
  "production_distribution_ready": false,
  "paid_gate_changed": false,
  "recommended_next_task": "TODO-32K-S3/S4 implement plan/package CRUD and scheduler/provider/invoice runtime prerequisites, or TODO-32I public recharge/voucher route polish if product prerequisites are ready."
}
```

### DOC-CREDIT-62 / TODO-32K-S2 docs watcher（2026-06-06）

Docs/Product consumed the E11-CREDIT-33 schema migration result. `db/migrations/0014_subscription_package_lifecycle_boundary.sql` is present and defines `subscription_plans`, `subscription_packages`, `subscriptions`, and `subscription_events_or_schedules` with tenant/currency/status/idempotency/audit metadata, fixed-decimal money, and wallet/credit/ledger/invoice/order/audit links. This moves TODO-32K from schema-contract-only to schema-migration-present.

Runtime remains deferred and false: no `.tmp/credit-wallet/subscription_package_lifecycle_runtime.json` or `artifacts/credit_wallet_subscription_package_lifecycle_runtime.json` pass artifact exists, and `scripts/verify_credit_wallet_ledger_surface.ps1` still reports `subscription_package_lifecycle_runtime_verified=false`. TODO-32I remains runtime verified, TODO-32J remains deferred/runtime false, and controlled paid beta is unchanged.

```json
{
  "task_id": "DOC-CREDIT-62",
  "todo_32k_schema_migration_present": true,
  "todo_32k_runtime_verified": false,
  "todo_32k_status": "schema_migration_present_runtime_deferred",
  "todo_32i_runtime_verified": true,
  "todo_32j_status": "deferred_runtime_external_dependency",
  "paid_gate_changed": false,
  "recommended_next_task": "TODO-32K plan/package CRUD and scheduler/provider/invoice runtime prerequisites, or TODO-32I public recharge/voucher route polish."
}
```

### DOC-LAUNCH-01 / API distribution runbook with voucher quota（2026-06-06）

Coordinator policy: unavailable external runtime/provider/scheduler capability should be documented and deferred with resume conditions instead of repeatedly assigned as blocking work. TODO-32J payment/order/invoice remains `deferred_runtime_external_dependency` with `payment_order_invoice_runtime_verified=false`; TODO-32K subscription/package remains schema-migration-present but `subscription_package_lifecycle_runtime_verified=false`. These are not launch blockers for trusted-user voucher-backed API Beta when the release scope is explicitly operator-mediated and voucher/quota backed.

Voucher-backed API Beta distribution path: operator issues or assigns a virtual key for a trusted user; operator provides or redeems bounded voucher quota through the accepted internal voucher flow; operator verifies remaining balance through the accepted user/API remaining-balance readback; Gateway request path is exercised with the assigned virtual key; rate and budget guardrails are configured and recorded; audit/support records include bounded tenant/project/wallet/voucher/request ids and owner; rollback disables or revokes the virtual key, revokes/expires voucher or credit quota, and verifies remaining balance plus audit/readback state.

Current evidence summary: `recharge_voucher_runtime_verified=true` through `.tmp/credit-wallet/recharge_voucher_runtime.json` internal Rust/sqlx business evidence; public recharge/voucher route remains `public_route_polish_pending` unless a later QA launch artifact accepts route invocation; `user_remaining_balance_runtime_verified=true`; Gateway controlled paid hot-path evidence is accepted by main review; `payment_order_invoice_runtime_verified=false`; `subscription_package_lifecycle_runtime_verified=false`; controlled paid beta gate is not expanded to full commercial credit readiness.

Secret-safe operator rule: logs, docs, tickets, screenshots, release notes, and support records must not expose raw voucher/redeem codes after issuance, full virtual keys, `Authorization` or `Cookie` headers, provider keys, DB URLs, raw provider payloads, raw request bodies, raw idempotency keys, or unredacted secret material.

Recommended launch pivot: E11/E9/QA/E8 should focus on voucher-backed API distribution readiness artifacts for virtual-key assignment, voucher/quota issuance or redemption, remaining-balance readback, Gateway call-path readback, rate/budget guardrails, audit/support, and rollback/revoke verification. TODO-32J/K external runtime should resume only when provider/callback/capture or scheduler/provider/invoice prerequisites are available.

```json
{
  "task_id": "DOC-LAUNCH-01",
  "launch_path": "trusted_user_voucher_backed_api_beta",
  "recharge_voucher_runtime_verified": true,
  "public_recharge_voucher_route_verified": false,
  "user_remaining_balance_runtime_verified": true,
  "gateway_paid_hot_path_evidence_present": true,
  "payment_order_invoice_runtime_verified": false,
  "subscription_package_lifecycle_runtime_verified": false,
  "deferred_items": [
    "TODO-32J payment/order/invoice provider/callback/runtime",
    "TODO-32K subscription/package scheduler/provider/invoice runtime"
  ],
  "paid_gate_changed": false,
  "docs_todo_md_authoritative": false,
  "recommended_next_task": "LAUNCH-02 produce voucher-backed API distribution readiness artifact and QA gate."
}
```

### E11-LAUNCH-01 / Voucher-backed API distribution readiness（2026-06-06）

User launch focus is API distribution through voucher/redeem-code quota, not full external payment or subscription runtime. E11 added `scripts/verify_voucher_api_distribution_readiness.ps1`, which writes `.tmp/launch/voucher_api_distribution_readiness.json` with `schema=voucher_api_distribution_readiness.v1`, `overall_status=partial_ready_with_route_gaps`, `production_distribution_ready=false`, `secret_safe=true`, and `paid_gate_changed=false`.

Current route/readback map: Admin virtual-key management routes are present in Control Plane (`GET/POST /admin/virtual-keys`, read/disable/expire detail routes) and create uses audited `create_virtual_key_with_default_profile_and_audit`; user/developer-token remaining balance route `GET /billing/wallets/{wallet_id}/remaining-balance` is runtime verified with server-side ownership scope; audit readback route `GET /admin/audit-logs` is present. Voucher OpenAPI boundaries exist for recharge intent, campaign, issuance, and redeem, and TODO-32I internal Rust/sqlx voucher runtime is verified, but public voucher Control Plane routes are not wired. No live virtual-key issue route artifact exists yet.

```json
{
  "task_id": "E11-LAUNCH-01",
  "launch_target": "voucher_backed_api_distribution",
  "voucher_internal_runtime_verified": true,
  "voucher_redeem_route_verified": false,
  "virtual_key_issue_route_found": true,
  "virtual_key_issue_route_verified": false,
  "user_balance_route_verified": true,
  "gateway_paid_hot_path_artifact_present": true,
  "production_distribution_ready": false,
  "paid_gate_changed": false,
  "deferred_external_runtime_items": [
    "payment_order_invoice_provider_callback_capture",
    "payment_order_invoice_runtime",
    "subscription_scheduler_provider_dunning_runtime",
    "subscription_package_lifecycle_runtime"
  ],
  "recommended_next_task": "Wire public voucher issuance/redeem routes to the verified internal voucher runtime, or generate a live Admin virtual-key issue/readback/audit artifact with safe fixture data."
}
```

### QA-LAUNCH-01 / Voucher-backed API distribution release gate（2026-06-06）

QA added a release-checkable voucher-backed API distribution gate and consumed the current artifacts. This gate is narrower than full commercial payment/subscription readiness: it verifies trusted-user API distribution with operator-issued virtual keys plus voucher/redeem-code quota evidence, while explicitly deferring unavailable payment/provider/callback and subscription/scheduler runtime with resume conditions.

Historical gate result, superseded by DOC-LAUNCH-02 current-run blocker: QA-LAUNCH-01 originally reported `.tmp/launch/voucher_api_distribution_readiness.json` as `pass_with_productization_gaps`. Current launch status must now be treated as blocked until fresh Gateway paid-balance enforcement and voucher/virtual-key route evidence pass.

```json
{
  "task_id": "QA-LAUNCH-01",
  "qa_verdict": "pass_with_productization_gaps",
  "artifact_paths": [
    ".tmp/launch/voucher_api_distribution_readiness.json",
    "artifacts/launch_voucher_api_distribution_release_check_20260606.json"
  ],
  "virtual_key_auth_or_seed_available": true,
  "gateway_live_paid_hot_path_verified": true,
  "voucher_redeem_runtime_verified": true,
  "user_remaining_balance_runtime_verified": true,
  "public_route_voucher_evidence_present": false,
  "secret_scan_passed": true,
  "payment_subscription_external_runtime_deferred": true,
  "docs_runbook_present": true,
  "remaining_blockers": [],
  "productization_gaps": [
    "public_recharge_voucher_route_evidence_pending",
    "payment_order_invoice_external_runtime_deferred",
    "subscription_scheduler_provider_runtime_deferred"
  ],
  "paid_gate_changed": false,
  "recommended_next_task": "LAUNCH-02 run a trusted-user dry-run/review packet with virtual key assignment, voucher quota, Gateway request ids, balance readback, rate/budget guardrails, and rollback owner evidence."
}
```

### DOC-LAUNCH-02 / Gateway paid-balance blocker and voucher route gap sync（2026-06-06）

Superseded historical split: this DOC-LAUNCH-02 state was replaced by LAUNCH-08 / DOC-LAUNCH-08 after the current Gateway paid-balance launch check passed and the launch gate moved to `pass_with_productization_gaps`. At that time, E9/accounting accepted voucher-backed credit with documented productization gaps, TODO-32I internal recharge/voucher runtime was verified, and distribution launch was still blocked by insufficient-balance enforcement plus voucher/virtual-key route evidence gaps.

Resume conditions for voucher-backed API distribution:

- E8 current-run paid hot-path launch artifact passes, including insufficient balance returning 402 and zero provider attempt.
- Public/admin voucher route evidence exists, or Product/Ops records an accepted internal operator-only exception with bounded issue/redeem/readback and support ownership.
- Live virtual-key issue route artifact/readback/audit evidence exists.
- `scripts/scan_secrets.ps1` passes and launch artifacts omit raw voucher/redeem code, full virtual key, Authorization/Cookie, provider key, DB URL, raw provider payload, raw request body, raw idempotency key, and unredacted secret material.

TODO-32J payment/order/invoice external runtime and TODO-32K subscription/package scheduler/provider runtime remain deferred external dependencies with resume conditions. They are not reintroduced as current voucher-backed launch blockers, and `docs/TODO.md` remains non-authoritative.

```json
{
  "task_id": "DOC-LAUNCH-02",
  "superseded_launch_status": "blocked_current_run",
  "accounting_gate": "acceptable_with_gaps",
  "gateway_paid_balance_enforcement": "blocked_insufficient_balance_returned_provider_200_expected_402_no_provider_call",
  "voucher_distribution_ready": false,
  "voucher_route_blocker": "voucher_public_control_plane_routes_not_wired",
  "virtual_key_blocker": "virtual_key_issue_live_route_artifact_missing",
  "payment_order_invoice_runtime_verified": false,
  "subscription_package_lifecycle_runtime_verified": false,
  "paid_gate_changed": false,
  "docs_todo_md_authoritative": false,
  "recommended_next_task": "LAUNCH-03 refresh E8 paid-balance launch smoke and voucher/virtual-key route readiness artifacts."
}
```

### DOC-LAUNCH-03 / Low-noise launch blocker watcher（2026-06-06）

Superseded watcher result: this DOC-LAUNCH-03 state was replaced by LAUNCH-08 / DOC-LAUNCH-08. Before that closure, there was no accepted closure artifact; `.tmp/launch/e8_gateway_paid_hot_path_launch_check.json` was `status=blocked` by the known insufficient-balance enforcement mismatch that LAUNCH-08 later closed.

Wording rule: `production_distribution_ready=true` is only a launch exit condition after current-run E8 paid-balance enforcement, voucher public/admin route evidence or accepted internal operator-only exception, live virtual-key issue/readback/audit evidence, and secret scan all pass. It is not the current launch status while E8-LAUNCH-02 / QA-LAUNCH-02 / E11-LAUNCH-02 remain open.

```json
{
  "task_id": "DOC-LAUNCH-03",
  "superseded_launch_status": "blocked_current_run",
  "e8_launch_artifact": ".tmp/launch/e8_gateway_paid_hot_path_launch_check.json",
  "e8_status": "blocked_expected_402_no_provider_call_got_provider_200",
  "gateway_readiness_artifact": ".tmp/launch/gateway_voucher_distribution_readiness.json",
  "superseded_gateway_readiness_status": "pre_launch_08_blocked_status_replaced_by_current_pass",
  "accounting_gate": "acceptable_with_productization_gaps",
  "api_distribution_launch_ready": false,
  "production_distribution_ready_true_is_current": false,
  "paid_gate_changed": false,
  "docs_todo_md_authoritative": false,
  "recommended_next_task": "Wait for E8-LAUNCH-02, QA-LAUNCH-02, and E11-LAUNCH-02 closure artifacts before promoting launch readiness."
}
```

### LAUNCH-08 / Gateway paid gate closed; voucher-backed API beta gate now warning-only（2026-06-06）

主线程修复并刷新了当前 Gateway paid hot-path launch evidence。修复范围：

- `apps/gateway/src/db.rs`：wallet selection 的项目匹配排序补齐 `DESC NULLS LAST`，避免 null-project wallet 在项目 wallet 之前被选中。
- `scripts/verify_gateway_paid_hot_path_smoke.ps1`：paid smoke 改为独立 smoke project/profile/wallet/price-book，并在退出时恢复 virtual key/profile binding/channel/canonical price selector，避免 dev seed 历史 project ledger 污染 0 credit 场景。

当前验证结果：

- `pwsh scripts/verify_gateway_paid_hot_path_smoke.ps1 -ArtifactPath .tmp/launch/e8_gateway_paid_hot_path_launch_check.json`：exit 0，artifact `status=passed`；insufficient balance request 返回 402，`provider_attempt_rows=0`。
- `cargo test -p ai-gateway pre_authorize --all-targets`：pass，9 tests。
- `cargo test -p ai-gateway paid_reserve --all-targets`：pass，2 tests。
- `docker compose -f deploy/docker-compose/docker-compose.yml build gateway`：pass；`POSTGRES_HOST_PORT=15432` / `REDIS_HOST_PORT=16379` 下 Gateway 已重启并完成 live smoke。
- `pwsh scripts/scan_secrets.ps1`：pass。
- `git diff --check -- apps\gateway\src\db.rs scripts\verify_gateway_paid_hot_path_smoke.ps1`：pass。

Launch artifacts 已刷新：

- `.tmp/launch/e8_gateway_paid_hot_path_launch_check.json`：`status=passed`。
- `.tmp/launch/gateway_voucher_distribution_readiness.json`：`status=pass`。
- `.tmp/launch/voucher_backed_api_distribution_accounting_gate.json`：`overall_status=launch_ready_with_productization_gaps`，`api_distribution_launch_ready=true`，`gateway_current_enforcement_verified=true`。
- `.tmp/launch/voucher_quota_pricing_guardrails.json`：`overall_status=pass`，`launch_ready=true`，`missing_guardrails=[]`。
- `.tmp/launch/voucher_api_distribution_readiness.json`：`overall_status=pass_with_productization_gaps`，`production_distribution_ready=true`，`production_distribution_full_ready=false`，`remaining_blockers=[]`。
- `artifacts/launch_voucher_api_distribution_release_check_20260606.json`：`overallStatus=warn`，not fail；warning 是产品化缺口，而不是当前 beta gate blocker。

当前结论：trusted-user voucher-backed API beta 可以分发；完整商业上线仍未完成。剩余 resume conditions 保持：

- public recharge/voucher route invocation evidence，或 release-owner/Product/Ops 明确批准 operator-only exception。
- payment/order/invoice provider callback/capture 或 approved bounded internal policy，之后才能把 TODO-32J runtime 置 true。
- subscription scheduler/provider/dunning lifecycle runtime，之后才能把 TODO-32K runtime 置 true。
- trusted TPM numeric source 仍是 beta gap，目前使用 conservative estimated TPM fallback。

```json
{
  "task_id": "LAUNCH-08",
  "trusted_user_voucher_backed_api_beta_distribution_ready": true,
  "full_commercial_launch_ready": false,
  "gateway_current_launch_hot_path_verified": true,
  "release_check_overall_status": "warn",
  "remaining_blockers": [],
  "productization_gaps": [
    "public_recharge_voucher_route_evidence_pending",
    "payment_order_invoice_external_runtime_deferred",
    "subscription_scheduler_provider_runtime_deferred",
    "trusted_numeric_tpm_source_missing_conservative_fallback_only"
  ],
  "docs_todo_md_authoritative": false,
  "paid_gate_changed": true
}
```

### QA-LAUNCH-02 / Reconcile launch gate with current E8 Gateway blocker（2026-06-06）

QA reconciled the launch gate with E8-LAUNCH-01 current runtime evidence. Historical `.tmp/paid-beta/e8_gateway_paid_hot_path.json` remains useful controlled-beta evidence, but current launch evidence takes precedence for API distribution. The launch verifier now consumes `.tmp/launch/gateway_voucher_distribution_readiness.json` and `.tmp/launch/e8_gateway_paid_hot_path_launch_check.json`; if current Gateway insufficient-balance enforcement is blocked, the voucher-backed API distribution gate is blocked even when historical paid evidence passed.

Superseded QA-LAUNCH-02 output: this blocked launch-gate state was replaced by LAUNCH-08 / DOC-LAUNCH-08 after current Gateway launch evidence passed and the release check moved to `overallStatus=warn`. Before that closure, `.tmp/launch/voucher_api_distribution_readiness.json` reported a blocked gate because current Gateway launch hot-path evidence was false.

```json
{
  "task_id": "QA-LAUNCH-02",
  "qa_verdict": "blocked",
  "artifact_paths": [
    ".tmp/launch/voucher_api_distribution_readiness.json",
    "artifacts/launch_voucher_api_distribution_release_check_20260606.json"
  ],
  "gateway_historical_paid_hot_path_verified": true,
  "superseded_launch_hot_path_was_verified": false,
  "current_runtime_evidence_precedence": true,
  "superseded_distribution_was_ready": false,
  "remaining_blockers": [
    "gateway_current_launch_hot_path_not_verified"
  ],
  "accounting_gate_changed": false,
  "recommended_next_task": "E8-LAUNCH-02 must prove insufficient balance returns billing 402 with provider_attempt_rows=0, or release owner must document an explicit waiver before launch."
}
```

### E11-LAUNCH-02 / Voucher public route blocker + virtual-key route evidence（2026-06-06）

E11 added `scripts/verify_voucher_public_route_and_virtual_key_evidence.ps1` and `.tmp/launch/voucher_public_route_and_virtual_key_evidence.json`. The artifact is secret-safe and paid-gate-neutral: `schema=voucher_public_route_virtual_key_evidence.v1`, `overall_status=partial`, `voucher_route_evidence.public_routes_wired=false`, `voucher_route_evidence.route_verified=false`, and blocker `voucher_public_control_plane_routes_not_wired`.

Feasibility decision: do not promote the accepted internal TODO-32I voucher runtime to public route evidence without dedicated handlers. Public `POST /admin/voucher-issuances` and `POST /billing/vouchers/redeem` still need route-level auth/RBAC or ownership scope, request parsing, server-side voucher code hash/redaction, idempotency replay/conflict, refusal no-write, audit/readback response shape, and secret-safe artifact proof. OpenAPI-only evidence and the internal Rust/sqlx verifier path are not route invocation.

Virtual-key evidence improved from pending-only to bounded route contract evidence. Admin virtual-key routes are present; create generates secret material server-side, rejects client-supplied secret/secret_hash/key_prefix, returns the secret only once, list/get omit the secret, create writes `virtual_key.create` audit, and RBAC maps virtual-key routes to `KeyManage`. This is not a live route smoke and keeps `virtual_key_issue_route_verified=false`; readiness now records `virtual_key_issue_bounded_contract_verified=true`.

Superseded E11-LAUNCH-02 status: before LAUNCH-08, `scripts/verify_voucher_api_distribution_readiness.ps1` consumed route evidence but remained blocked because current Gateway launch hot-path evidence was false. LAUNCH-08 / DOC-LAUNCH-08 later replaced this with `pass_with_productization_gaps` after the current Gateway launch check passed. TODO-32J payment/order/invoice and TODO-32K subscription/package remain deferred external runtime dependencies and are not reopened.

```json
{
  "task_id": "E11-LAUNCH-02",
  "voucher_public_route_verified": false,
  "virtual_key_issue_bounded_contract_verified": true,
  "virtual_key_issue_route_verified": false,
  "superseded_launch_hot_path_was_verified": false,
  "superseded_distribution_was_ready": false,
  "payment_order_invoice_runtime_verified": false,
  "subscription_package_lifecycle_runtime_verified": false,
  "paid_gate_changed": false,
  "recommended_next_task": "Superseded for Gateway launch evidence by LAUNCH-08; keep voucher public route or operator-only exception approval as productization follow-up."
}
```

### E11-LAUNCH-03 / Voucher route implementation decision and operator-only exception（2026-06-06）

E11 inspected the voucher implementation path and did not wire public voucher routes in this slice. The accepted TODO-32I runtime proof is `execute_recharge_voucher_internal_runtime_tx`, which currently lives in the Rust test module as an opt-in verifier path. Moving that into production HTTP handlers would require new runtime request structs, auth/RBAC or ownership scope, route response semantics, idempotency replay/conflict behavior, refusal no-write behavior, audit/readback response shape, and safe redaction policy. E11 therefore did not claim route invocation from OpenAPI or internal verifier evidence.

`scripts/verify_voucher_public_route_and_virtual_key_evidence.ps1` now writes `.tmp/launch/voucher_operator_only_exception.json` alongside the route evidence artifact. The exception artifact is deliberately unapproved: `schema=voucher_operator_only_exception.v1`, `overall_status=unapproved`, `approved=false`, `route_substitution_allowed=false`, `production_distribution_ready=false`, `secret_safe=true`, and `paid_gate_changed=false`. It documents a manual operator flow, risks, and resume conditions, but it cannot satisfy production distribution readiness without explicit release-owner/Product/Ops approval.

`scripts/verify_voucher_api_distribution_readiness.ps1` consumes the operator exception artifact and only treats it as a substitute for voucher public route evidence when `approved=true` and `route_substitution_allowed=true`. Superseded pre-LAUNCH-08 readiness remained blocked while Gateway current launch evidence was false; current DOC-LAUNCH-08 readiness is `pass_with_productization_gaps`, with public voucher route polish / operator-only policy finalization kept as a productization follow-up rather than a blocker for trusted-user Beta.

```json
{
  "task_id": "E11-LAUNCH-03",
  "routes_added": [],
  "implementation_decision": "formal_operator_only_exception_unapproved",
  "voucher_public_route_verified": false,
  "operator_only_exception_approved": false,
  "virtual_key_issue_bounded_contract_verified": true,
  "production_distribution_full_ready": false,
  "payment_order_invoice_runtime_verified": false,
  "subscription_package_lifecycle_runtime_verified": false,
  "paid_gate_changed": false,
  "recommended_next_task": "Either implement real voucher issuance/redeem handlers from the internal runtime semantics, or attach explicit release-owner/Product/Ops approval for operator-only distribution; Gateway current launch hot-path already passed in LAUNCH-08."
}
```

### DOC-LAUNCH-04 / Operator handoff for blocked-but-near distribution（2026-06-06）

Superseded operator handoff posture: this DOC-LAUNCH-04 packet-preparation-only state was replaced by LAUNCH-08 / DOC-LAUNCH-08. Current global gate is trusted-user voucher-backed Beta distribution `ready_with_productization_gaps`; the packet artifacts may still report `ready_to_send=false` until per-user owner/support/contact/tenant/project/wallet/quota fields are filled.

Current per-user handoff requirements before sending a specific key:

- E8 current Gateway paid-balance launch smoke remains passed and proves insufficient balance returns 402 with provider attempts zero.
- Public/admin voucher route evidence or release owner/Product/Ops operator-only exception policy finalization remains a productization follow-up, not a global blocker for the scoped trusted-user Beta.
- Live or bounded virtual-key issue/readback/audit artifact exists.
- Trusted-user packet is ready: owner, tenant/project/wallet ids, voucher/quota amount, rate and budget limits, support contact, rollback owner, bounded request/audit/evidence links, and no raw secrets.
- Secret scan passes.

Explicitly not full commercial/public launch: public voucher routes are not polished, operator-only exception is documented but unapproved, virtual-key evidence is bounded contract evidence rather than full live public route smoke, and TODO-32J payment/order/invoice plus TODO-32K subscription/package runtime remain deferred external dependencies. These do not block the current voucher-backed trusted-user Beta scope.

Before sending a selected trusted-user key: run `scripts/prepare_trusted_user_api_distribution_packet.ps1` first with real per-user values so it writes/verifies the packet, runs launch release check, runs secret scan, and writes `.tmp/launch/trusted_user_api_distribution_handoff_summary.json`. Archive launch/accounting/credit-wallet/secret-scan artifacts from that orchestrated run; use direct release-check / packet-verifier commands only for focused QA or debugging. Update `TODO/AI_GATEWAY_REBASED_TODO_2026-06-05.md`, `docs/P0_BETA_STATUS.md`, `project/RELEASE_CHECKLIST.md`, and `project/ACCEPTANCE_CHECKLIST.md` only if artifact state changes. `docs/TODO.md` remains non-authoritative.

```json
{
  "task_id": "DOC-LAUNCH-04",
  "operator_handoff_status": "ready_with_productization_gaps_per_user_packet_required",
  "send_virtual_key_allowed_after_per_user_packet": true,
  "evidence_exists": [
    "recharge_voucher_internal_runtime_verified",
    "user_remaining_balance_runtime_verified",
    "voucher_accounting_gate_acceptable_with_gaps",
    "virtual_key_bounded_contract_evidence",
    "qa_launch_gate_pass_with_productization_gaps"
  ],
  "must_collect_before_key": [
    "e8_current_gateway_paid_balance_402_no_provider_call_already_passed",
    "voucher_public_route_evidence_or_approved_operator_only_exception",
    "virtual_key_issue_readback_audit_artifact",
    "trusted_user_packet",
    "secret_scan_pass"
  ],
  "explicitly_not_ready": [
    "voucher_public_routes",
    "operator_only_exception_approval",
    "virtual_key_live_smoke",
    "payment_order_invoice_runtime",
    "subscription_package_lifecycle_runtime"
  ],
  "paid_gate_changed": false,
  "docs_todo_md_authoritative": false,
  "recommended_next_task": "Complete selected trusted-user packet fields, rerun final release/secret checks, and keep public route/payment/subscription work as productization follow-up."
}
```

### E11-LAUNCH-04 / Virtual-key launch artifact and operator packet（2026-06-06）

E11 stopped spinning on voucher public route wiring after E11-LAUNCH-03 documented the blocker and unapproved operator-only exception. This slice strengthened the launch path that can be completed now: virtual-key distribution safety plus a QA/operator packet.

`scripts/verify_voucher_public_route_and_virtual_key_evidence.ps1` now writes `.tmp/launch/api_distribution_operator_packet.json` in addition to the route evidence and unapproved exception sidecars. The virtual-key evidence verifies create/list/get/disable/expire route presence, server-side generated virtual-key secret, caller-supplied secret/secret_hash/key_prefix refusal, one-time secret return on create only, list/get redacted output, `virtual_key.create` audit marker, RBAC `KeyManage` scope, and no raw virtual-key secret in artifact. It is DB-free/bounded and does not claim `route_invoked=true`.

The operator packet has `schema=api_distribution_operator_packet.v1`, `overall_status=blocked`, `ready_to_send=false`, `secret_safe=true`, and `paid_gate_changed=false`. In the current DOC-LAUNCH-08 posture this means per-user packet fields / public-route-polish evidence are incomplete, not that the global Gateway launch gate is blocked. Current Gateway launch hot-path evidence is passed; trusted-user voucher-backed Beta can proceed after selected-user owner/support/contact/tenant/project/wallet/quota fields are filled and final checks are rerun.

```json
{
  "task_id": "E11-LAUNCH-04",
  "virtual_key_evidence_status": "bounded_contract_verified_live_invocation_pending",
  "operator_packet_status": "per_user_fields_required",
  "ready_to_send": false,
  "voucher_public_route_verified": false,
  "operator_only_exception_approved": false,
  "gateway_current_launch_hot_path_verified": true,
  "production_distribution_ready": true,
  "payment_order_invoice_runtime_verified": false,
  "subscription_package_lifecycle_runtime_verified": false,
  "paid_gate_changed": false,
  "recommended_next_task": "Fill per-user packet fields and keep public voucher route/operator-only policy as productization follow-up."
}
```

### E11-LAUNCH-05 / Admin distribution packet rollback/revoke verifier（2026-06-06）

E11 strengthened `.tmp/launch/api_distribution_operator_packet.json` with rollback/revoke contract evidence. The packet remains blocked and not sendable, but now records the Admin surfaces needed after distribution if rollback is required.

Current packet: `schema=api_distribution_operator_packet.v1`, `overall_status=blocked`, `ready_to_send=false`, `rollback_revoke_verification.status=bounded_contract_ready_live_invocation_pending`, `secret_safe=true`, and `paid_gate_changed=false`. In DOC-LAUNCH-08 this is a per-user packet completion state, not a global Gateway blocker. It verifies `rollback_virtual_key_disable_route_present=true`, `rollback_virtual_key_expire_route_present=true`, `credit_revoke_or_expire_route_present=true`, `remaining_balance_recheck_present=true`, and `audit_readback_route_present=true`. These are bounded contract/source checks only; `live_invocation=false` remains explicit.

Support/escalation metadata is present as placeholders for support owner, audit owner, launch approver, escalation contact, and rollback owner. Current global gate is ready with productization gaps: Gateway current launch hot-path evidence is passed; voucher public route evidence or an approved operator-only exception is still productization follow-up, and selected-user packet fields must be filled before key handoff.

```json
{
  "task_id": "E11-LAUNCH-05",
  "operator_packet_status": "per_user_fields_required",
  "ready_to_send": false,
  "ready_to_rollback_after_send": "bounded_contract_ready_live_invocation_pending",
  "rollback_virtual_key_disable_route_present": true,
  "rollback_virtual_key_expire_route_present": true,
  "credit_revoke_or_expire_route_present": true,
  "remaining_balance_recheck_present": true,
  "audit_readback_route_present": true,
  "live_invocation_claimed": false,
  "paid_gate_changed": false,
  "recommended_next_task": "Fill per-user packet fields, rerun final checks for the selected trusted user, and keep public voucher route/operator-only exception as productization follow-up."
}
```

### DOC-LAUNCH-05 / Blocked-launch artifact map（2026-06-06）

Superseded reviewer map for voucher-backed API distribution packet. This DOC-LAUNCH-05 blocked artifact map was replaced by LAUNCH-08 / DOC-LAUNCH-08; current status is trusted-user voucher-backed Beta distribution `ready_with_productization_gaps`, with per-user packet fields still required before sending a specific key.

| Artifact | Owner lane | Current status | Notes |
|---|---|---|---|
| `.tmp/launch/voucher_api_distribution_readiness.json` | QA-LAUNCH | `pass_with_productization_gaps`; `production_distribution_ready=true` | Reconciled launch gate; trusted-user Beta can proceed with documented gaps. |
| `.tmp/launch/voucher_backed_api_distribution_accounting_gate.json` | E9-LAUNCH | `launch_ready_with_productization_gaps` | Accounting acceptable for voucher-backed trusted-user Beta. |
| `.tmp/launch/e8_gateway_paid_hot_path_launch_check.json` | E8-LAUNCH | `passed` | Current paid-balance blocker closed: insufficient balance returns 402/no-provider-call. |
| `.tmp/launch/gateway_voucher_distribution_readiness.json` | E8-LAUNCH / E9-LAUNCH | `pass` | Gateway/current-runtime readiness rollup. |
| `.tmp/launch/voucher_public_route_and_virtual_key_evidence.json` | E11-LAUNCH | `partial` | Public voucher route polish remains a productization follow-up; virtual-key bounded contract evidence exists. |
| `.tmp/launch/voucher_operator_only_exception.json` | E11-LAUNCH / Product-Ops | `unapproved`; `route_substitution_allowed=false` | Operator-only exception policy remains a follow-up, not current trusted-user Beta blocker. |
| `.tmp/launch/api_distribution_operator_packet.json` | E11-LAUNCH / Ops | `ready_to_send=false` | Fill per-user operator fields before handing a specific key to a trusted user. |
| `.tmp/launch/trusted_user_distribution_review_packet.json` | QA-LAUNCH / Release-Ops | `ready_to_send=false` | Per-user trusted-user packet checklist; not a global launch blocker after gate pass-with-gaps. |
| `.tmp/launch/voucher_quota_pricing_guardrails.json` | E9-LAUNCH / Product-Ops | `pass` | Quota/pricing/rate guardrails map. |
| `artifacts/launch_voucher_api_distribution_release_check_20260606.json` | Release / QA-LAUNCH | `warn` | Release-check summary; warnings are documented productization gaps. |
| `scripts/scan_secrets.ps1` output | QA / Security | latest run `pass` | Rerun and archive with final packet. |

Superseded conclusion: this packet was not ready to send keys at DOC-LAUNCH-05 time. Current DOC-LAUNCH-08 conclusion is that trusted-user voucher-backed Beta API distribution may proceed after per-user packet fields are completed and reviewed. TODO-32J payment/order/invoice and TODO-32K subscription/package external runtime remain deferred and non-blocking for the voucher-backed Beta scope; they are not launch artifact requirements.

```json
{
  "task_id": "DOC-LAUNCH-05",
  "superseded_launch_status": "blocked_not_ready_to_send_keys",
  "artifact_map_indexed": true,
  "ready_to_send": false,
  "payment_order_invoice_runtime_verified": false,
  "subscription_package_lifecycle_runtime_verified": false,
  "paid_gate_changed": false,
  "docs_todo_md_authoritative": false,
  "recommended_next_task": "Use the artifact map for review; only update readiness after E8/E11/QA launch artifacts change to pass or explicit waiver/approval."
}
```

### E11-LAUNCH-06 / Developer API distribution quickstart contract（2026-06-06）

E11 added `.tmp/launch/developer_api_distribution_quickstart_contract.json` as a DB-free trusted-user API distribution quickstart contract. It is not a published public quickstart and does not claim distribution readiness.

The artifact has `schema=developer_api_distribution_quickstart_contract.v1`, `overall_status=blocked`, `ready_to_publish=false`, `secret_safe=true`, and `paid_gate_changed=false`. It includes a base URL placeholder, bearer auth header shape with raw key omitted, supported endpoint examples, model placeholder, expected `billing_insufficient_balance` / rate limit / auth failure / scope failure errors, request id capture fields, support escalation placeholders, and links to the operator packet/readiness/route evidence artifacts.

Superseded quickstart blocker wording: before LAUNCH-08, Gateway current launch hot-path evidence was false. Current Gateway launch evidence is passed and the global gate is `ready_with_productization_gaps`; the quickstart remains preparatory until per-user packet fields are filled and release/ops chooses the trusted-user handoff.

```json
{
  "task_id": "E11-LAUNCH-06",
  "quickstart_artifact": ".tmp/launch/developer_api_distribution_quickstart_contract.json",
  "ready_to_publish": false,
  "secret_safe": true,
  "gateway_current_launch_hot_path_verified": true,
  "voucher_route_or_approved_operator_exception_present": false,
  "paid_gate_changed": false,
  "recommended_next_task": "Use quickstart wording for the selected trusted-user packet after final per-user metadata and secret-scan checks."
}
```

### E11-LAUNCH-08 / Voucher-backed distribution route-gap reconciliation（2026-06-06）

E11 re-reviewed the current launch artifacts after Gateway recovery. `.tmp/launch/voucher_api_distribution_readiness.json` now reports `schema=voucher_api_distribution_launch_gate.v1`, `overall_status=pass_with_productization_gaps`, `qa_verdict=pass_with_productization_gaps`, `production_distribution_ready=true`, `production_distribution_full_ready=false`, `gateway_current_launch_hot_path_verified=true`, `voucher_redeem_runtime_verified=true`, `user_remaining_balance_runtime_verified=true`, `secret_safe=true`, and `paid_gate_changed=false`.

The route evidence and exception artifacts remain unchanged: `.tmp/launch/voucher_public_route_and_virtual_key_evidence.json` is still `overall_status=partial` with `voucher_route_evidence.public_routes_wired=false`, `route_invoked=false`, `route_verified=false`, and blocker `voucher_public_control_plane_routes_not_wired`; `.tmp/launch/voucher_operator_only_exception.json` remains `overall_status=unapproved`, `approved=false`, and `route_substitution_allowed=false`.

E11 classification: for the current voucher-backed trusted-user beta, the unwired public Control Plane voucher routes are a productization gap / resume condition, not the current hard blocker, because Gateway current launch evidence, internal voucher redeem runtime, remaining-balance runtime, and virtual-key bounded contract evidence are present. Do not claim full self-serve/public voucher route readiness: `production_distribution_full_ready=false` remains correct until public route evidence or an approved Product/Ops operator-only exception exists.

Virtual-key bounded contract remains valid and secret-safe: Admin create/list/get/disable/expire routes are present, create generates secret material server-side, caller-supplied secret material is refused, the secret is returned only once on create, list/get omit raw secret material, audit marker and `KeyManage` RBAC are present, and artifacts do not include raw virtual keys. This is still bounded contract evidence, not live route invocation.

```json
{
  "task_id": "E11-LAUNCH-08",
  "readiness_status": "pass_with_productization_gaps",
  "production_distribution_ready": true,
  "production_distribution_full_ready": false,
  "public_control_plane_routes_wired": false,
  "voucher_public_route_verified": false,
  "operator_only_exception_approved": false,
  "virtual_key_bounded_contract_secret_one_time_only": true,
  "classification": "public_voucher_route_is_productization_gap_for_trusted_user_beta",
  "resume_conditions": [
    "wire POST /admin/voucher-issuances and POST /billing/vouchers/redeem with route-level evidence",
    "or attach explicit Product/Ops approval for operator-only route substitution",
    "keep production_distribution_full_ready=false until one of those conditions is met"
  ],
  "paid_gate_changed": false
}
```

### E11-LAUNCH-09 / API distribution operator packet refresh（2026-06-06）

E11 fixed and reran the operator-packet generator instead of hand-editing the artifact. `scripts/verify_voucher_public_route_and_virtual_key_evidence.ps1 -SelfTest` now includes a recovered-Gateway case proving the operator packet does not retain `gateway_current_launch_hot_path_not_verified` or `expected_402_got_200` after readiness reports `gateway_current_launch_hot_path_verified=true`.

Regenerated `.tmp/launch/api_distribution_operator_packet.json` now reflects the current launch state: `schema=api_distribution_operator_packet.v1`, `overall_status=per_user_metadata_required`, `ready_to_send=false`, `gateway.status=verified`, `gateway.blocker=""`, `blockers=[]`, `secret_safe=true`, and `paid_gate_changed=false`. The remaining packet reasons are explicit productization/send-prep items: `productization_gaps=["public_voucher_route_or_operator_exception_policy_pending","per_user_operator_metadata_required"]`.

This does not claim full commercial/public readiness. The trusted-user voucher-backed beta gate remains `pass_with_productization_gaps`; the packet must still be filled for the target user before key handoff, and public voucher HTTP routes or an approved operator-only exception remain resume conditions for full productization.

```json
{
  "task_id": "E11-LAUNCH-09",
  "operator_packet": ".tmp/launch/api_distribution_operator_packet.json",
  "operator_packet_status": "per_user_metadata_required",
  "ready_to_send": false,
  "gateway_status": "verified",
  "gateway_blocker": "",
  "global_blockers": [],
  "productization_gaps": [
    "public_voucher_route_or_operator_exception_policy_pending",
    "per_user_operator_metadata_required"
  ],
  "secret_safe": true,
  "paid_gate_changed": false
}
```

### E11-LAUNCH-10 / Operator packet watcher + public voucher route backlog（2026-06-06）

E11 ran a low-noise watcher over `.tmp/launch/api_distribution_operator_packet.json`. No packet regression was found, so no code or launch artifact was changed in this slice. Current packet fields remain: `schema=api_distribution_operator_packet.v1`, `overall_status=per_user_metadata_required`, `ready_to_send=false`, `gateway.status=verified`, `gateway.blocker=""`, `blockers=[]`, `productization_gaps=["public_voucher_route_or_operator_exception_policy_pending","per_user_operator_metadata_required"]`, `secret_safe=true`, and `paid_gate_changed=false`.

Interpretation is unchanged from LAUNCH-09: `ready_to_send=false` is selected-user packet incompleteness plus public-route productization scope, not a recovered Gateway blocker. The current trusted-user voucher-backed beta may proceed only after target-user metadata and final checks are filled for the actual handoff. Full public/self-serve voucher route readiness remains false.

Public voucher route productization backlog minimal DoD:

- Auth/RBAC or ownership scope for `POST /admin/voucher-issuances` and `POST /billing/vouchers/redeem`.
- Request parsing and validation including fixed-decimal positive amount, wallet/tenant/project/currency checks, and no client-trusted wallet claims.
- Server-side voucher-code hash/redaction; no raw voucher code, raw virtual key, Authorization/Cookie, provider key, DB URL, or raw secret material in responses/artifacts.
- Idempotency replay and same-key conflict semantics for issuance/redeem.
- Audit write/readback, ledger-or-credit effect readback, and refusal no-write proof.
- Secret-safe route-level runtime artifact with `route_invoked=true`, `paid_gate_changed=false`, and no direct wallet snapshot mutation.

```json
{
  "task_id": "E11-LAUNCH-10",
  "watcher_result": "no_packet_regression",
  "operator_packet_status": "per_user_metadata_required",
  "gateway_status": "verified",
  "global_blockers": [],
  "ready_to_send": false,
  "public_voucher_route_backlog": "productization_resume_condition",
  "paid_gate_changed": false
}
```

### E11-LAUNCH-11 / Public voucher route productization implementation brief（2026-06-06）

E11 added a docs-only implementation brief for public voucher route productization. No runtime code was changed and no public route wiring is claimed. The current trusted-user voucher-backed beta remains governed by `pass_with_productization_gaps`; public voucher HTTP routes remain a productization resume condition, not a current beta blocker.

Current basis: accepted internal Rust/sqlx voucher runtime proof exists through `execute_recharge_voucher_internal_runtime_tx`; OpenAPI contract-only paths exist for `POST /admin/voucher-issuances` and `POST /billing/vouchers/redeem`; Admin virtual-key route/RBAC evidence, user/developer remaining-balance ownership runtime, and audit readback exist. OpenAPI-only evidence or internal verifier evidence must not be reclassified as public route invocation.

Future `POST /admin/voucher-issuances` route DoD: Admin session plus billing-adjust/voucher-issue permission; request schema with tenant/project/wallet/currency, campaign or issue source, fixed-decimal positive amount/quota, validity window, reason, actor metadata, and idempotency key; server-side voucher code hash/redaction using `code_hash`, `code_lookup_prefix`, and `code_redacted`; same-key replay and same-key conflict handling; duplicate code/external reference refusal; atomic issuance/audit/optional ledger-or-credit effect readback; no direct wallet snapshot mutation; invalid input refusal no-write proof.

Future `POST /billing/vouchers/redeem` route DoD: user/developer-token ownership scope or approved trusted-user server-side principal; no client-trusted wallet claims; request schema with wallet/project/currency, raw redeem code only at boundary, idempotency key, and bounded request trace; lookup by server-side hash/prefix; redacted response only; same-key replay and conflict semantics; redemption/attempt/credit-grant-or-ledger/audit/remaining-balance readback; expired/revoked/currency/ownership/already-redeemed refusal no-write proof with safe attempt markers.

Future route artifact acceptance: schema `voucher_public_route_runtime.v1` or equivalent, `route_invoked=true`, `runtime_implemented=true`, `contract_only=false`, admin issue and billing redeem route verification, idempotency replay, conflict no duplicate write, audit readback, ledger-or-credit effect readback, refusal no-write, voucher hash/redaction, `raw_voucher_code_echoed=false`, `secret_safe=true`, and `paid_gate_changed=false`.

```json
{
  "task_id": "E11-LAUNCH-11",
  "scope": "docs_only_public_voucher_route_productization_brief",
  "runtime_code_changed": false,
  "routes_wired": false,
  "trusted_user_beta_blocker": false,
  "productization_routes": [
    "POST /admin/voucher-issuances",
    "POST /billing/vouchers/redeem"
  ],
  "paid_gate_changed": false
}
```

### E11-LAUNCH-12 / Public voucher route productization watcher（2026-06-06）

E11 performed a lightweight watcher scan only; no runtime code or launch artifacts were changed. Current artifacts remain consistent:

- `.tmp/launch/voucher_public_route_and_virtual_key_evidence.json`: `schema=voucher_public_route_virtual_key_evidence.v1`, `overall_status=partial`, `voucher_route_evidence.public_routes_wired=false`, `voucher_route_evidence.route_verified=false`, blocker `voucher_public_control_plane_routes_not_wired`, `secret_safe=true`, `paid_gate_changed=false`.
- `.tmp/launch/voucher_public_route_and_virtual_key_evidence.json` virtual-key section: bounded contract remains verified; server-generated key material is returned only once on create, list/get never return raw secret material, create audit marker and `KeyManage` RBAC are present.
- `.tmp/launch/api_distribution_operator_packet.json`: `overall_status=per_user_metadata_required`, `ready_to_send=false`, `gateway.status=verified`, `gateway.blocker=""`, `blockers=[]`, productization gaps are public voucher route/operator-exception policy plus per-user metadata, `secret_safe=true`, `paid_gate_changed=false`.
- `.tmp/launch/voucher_api_distribution_readiness.json`: `overall_status=pass_with_productization_gaps`, `production_distribution_ready=true`, `production_distribution_full_ready=false`, and public route evidence remains absent.

Classification: missing public voucher HTTP routes are not a trusted-user beta blocker only because operator-mediated trusted-user handoff is the accepted current path. Full self-serve/public distribution still requires public route evidence or an explicitly approved operator-only substitution.

Backlog implementation DoD remains: route auth/RBAC or ownership scope; request parsing and fixed-decimal validation; server-side voucher-code hash/redaction; idempotency replay/conflict; audit write/readback; ledger-or-credit effect readback; refusal no-write proof; no direct wallet snapshot mutation; and a secret-safe route-level artifact proving `route_invoked=true`, `runtime_implemented=true`, `contract_only=false`, and `paid_gate_changed=false`.

```json
{
  "task_id": "E11-LAUNCH-12",
  "watcher_status": "no_runtime_change",
  "public_routes_wired": false,
  "virtual_key_bounded_contract_verified": true,
  "operator_packet_status": "per_user_metadata_required",
  "gateway_status": "verified",
  "trusted_user_beta_blocker": false,
  "productization_gap": "public_voucher_route_or_operator_exception_policy_pending",
  "paid_gate_changed": false
}
```

### DOC-LAUNCH-06 / Developer-operator docs index for blocked packet（2026-06-06）

Reviewer docs index has been added to `project/RELEASE_CHECKLIST.md`. Current DOC-LAUNCH-08 posture: global trusted-user voucher-backed Beta gate is ready with productization gaps; entries with `ready_to_send=false` require selected-user packet fields before handing out a specific key.

| Index entry | Path | Current status |
|---|---|---|
| Developer quickstart contract | `.tmp/launch/developer_api_distribution_quickstart_contract.json` | preparatory for trusted-user packet |
| Operator packet | `.tmp/launch/api_distribution_operator_packet.json` | per-user completion required; `ready_to_send=false` |
| Trusted-user packet | `.tmp/launch/trusted_user_distribution_review_packet.json` | per-user completion required; `ready_to_send=false` |
| Waiver / operator-only policy | `.tmp/launch/voucher_operator_only_exception.json` | `unapproved`; `route_substitution_allowed=false` |
| Gateway diagnostics | `.tmp/launch/gateway_distribution_diagnostics_bundle.json`; `.tmp/launch/gateway_distribution_operator_smoke_plan.json` | diagnostics retained; current E8 launch check passed |
| Launch gate summary | `.tmp/launch/voucher_api_distribution_readiness.json`; `artifacts/launch_voucher_api_distribution_release_check_20260606.json` | `pass_with_productization_gaps`; release check `warn` |

Superseded DOC-LAUNCH-07 watcher conclusion: this was the blocked state before LAUNCH-08 / DOC-LAUNCH-08. Current conclusion is trusted-user voucher-backed Beta distribution `ready_with_productization_gaps`; complete per-user packet fields and rerun final checks before sending a specific key. TODO-32J payment/order/invoice and TODO-32K subscription/package external runtime remain deferred and non-blocking for the voucher-backed Beta scope. `docs/TODO.md` remains non-authoritative.

```json
{
  "task_id": "DOC-LAUNCH-06",
  "docs_index_status": "indexed_ready_with_productization_gaps_packet",
  "ready_to_send": false,
  "developer_quickstart_contract": "blocked",
  "operator_packet": "per_user_completion_required",
  "trusted_user_packet_ready_to_send": false,
  "operator_only_exception": "unapproved",
  "gateway_diagnostics": "present_current_e8_launch_check_passed",
  "launch_gate_summary": "pass_with_productization_gaps_warn",
  "paid_gate_changed": false,
  "docs_todo_md_authoritative": false,
  "recommended_next_task": "Keep index stable; update only when launch artifacts or explicit waiver/approval change readiness."
}
```

### E9-LAUNCH-08 / Gateway pass artifact accounting + guardrails recheck（2026-06-06）

E9 rechecked the Billing Ledger/accounting launch inputs after the current Gateway evidence was refreshed. The prior Gateway enforcement blocker is closed from the E9 accounting lane: `.tmp/launch/e8_gateway_paid_hot_path_launch_check.json` is `status=passed`, and `.tmp/launch/gateway_voucher_distribution_readiness.json` is `status=pass` with `paid_hot_path_verified.current_launch_live_verified=true` and no blockers.

The E9-owned gates are consistent with that change. `.tmp/launch/voucher_backed_api_distribution_accounting_gate.json` now reports `overall_status=launch_ready_with_productization_gaps`, `actual_exit_code=0`, `accounting_verdict=acceptable_with_productization_gaps`, `accounting_credit_acceptable=true`, `voucher_backed_quota_distributable_beta_credit=true`, `api_distribution_launch_ready=true`, and `gateway_current_enforcement_verified=true`. `.tmp/launch/voucher_quota_pricing_guardrails.json` now reports `overall_status=pass`, `actual_exit_code=0`, `guardrail_verdict=launch_ready`, `launch_ready=true`, and `missing_guardrails=[]`.

E9 conclusion: voucher-backed API beta accounting credit and quota/pricing guardrails are acceptable for release review. TODO-32J payment/order/invoice and TODO-32K subscription/package remain deferred/runtime false and are not launch blockers for this voucher-backed scope. The remaining public voucher route/operator-only exception item is productization/ops scope, not an accounting blocker, and must not be reclassified as a Billing Ledger regression.

### E9-LAUNCH-09 / Trusted-user quota/rate/budget record template（2026-06-06）

E9 added `scripts/write_trusted_user_quota_rate_budget_record_template.ps1` and generated `.tmp/launch/trusted_user_quota_rate_budget_record_template.json` with schema `trusted_user_quota_rate_budget_record_template.v1`. The artifact is a machine-readable template for the QA/operator packet field `trusted_user_quota_and_rate_limit_record`; it does not populate real trusted-user values and does not expose raw virtual keys, voucher codes, tokens, DB URLs, provider keys, or provider payloads.

The template requires bounded ownership and quota fields before API key distribution: tenant/project/trusted-user/wallet/virtual-key refs, operator/support owner, credit amount fixed-decimal string, currency, voucher/redemption/credit-grant/ledger refs, remaining-balance readback amount, model or canonical model id, price book/policy and price version/model-cost reference, RPM/TPM/concurrency limits, budget amount/window, API key profile or binding ref, credit/key expiry, revoke procedure, rollback contact, and audit/support id. Validation rules require fixed-decimal money, matching voucher/wallet currency, positive RPM/TPM/budget limits, active price/version policy evidence, bounded key refs only, and post-assignment remaining-balance readback.

Current evidence links are `.tmp/launch/voucher_quota_pricing_guardrails.json`, `.tmp/launch/voucher_backed_api_distribution_accounting_gate.json`, `.tmp/credit-wallet/user_remaining_balance_ownership_runtime.json`, `.tmp/credit-wallet/recharge_voucher_runtime.json`, and `.tmp/launch/e8_gateway_rate_limit_launch_check.json`. The template status is `template_ready`, `actual_exit_code=0`, `accounting_credit_acceptable=true`, and `quota_pricing_guardrails_pass=true`. TODO-32J payment/order/invoice and TODO-32K subscription/package remain deferred external runtimes and are not current voucher-backed beta blockers.

### E9-LAUNCH-12 / Quota-rate-budget handoff watcher（2026-06-06）

E9 re-audited `.tmp/launch/trusted_user_quota_rate_budget_record_template.json` as the current handoff contract. The artifact is present with schema `trusted_user_quota_rate_budget_record_template.v1`, status `template_ready`, `actual_exit_code=0`, `real_user_values_populated=false`, all 30 required fields present, 12 detailed validation rules present, `secret_safe=true`, and `paid_gate_changed=false`.

The absence of real tenant/project/wallet/user/quota values is now classified as external Release/Ops input required, not an engineering blocker. Before distributing a real trusted-user API key, operator/QA must fill bounded tenant/project/user/wallet ids, bounded virtual-key ref without secret material, fixed-decimal voucher credit amount and currency, voucher/redemption/credit-grant/ledger refs, post-assignment remaining-balance readback, model/price policy refs, positive RPM/TPM/concurrency/budget limits, budget window/profile binding, credit/key expiry, revoke/disable procedure, rollback contact, and audit/support id.

Acceptance DoD for a future filled quota record: no raw voucher code, virtual key secret, auth token, DB URL, provider key, or provider payload; voucher quota is bounded; rate and budget are set; tenant/project/wallet ids match the wallet/readback evidence; remaining balance is read back after assignment; expiry/revoke/audit fields are present. TODO-32J payment/order/invoice and TODO-32K subscription/package remain deferred external runtimes and are not blockers for the voucher-backed beta handoff.

### E9-LAUNCH-13 / Handoff orchestrator accounting fields watcher（2026-06-06）

E9 reviewed `scripts/prepare_trusted_user_api_distribution_packet.ps1` and the handoff summaries `.tmp/launch/trusted_user_api_distribution_handoff_summary.json` and `.tmp/launch/trusted_user_api_distribution_handoff_summary.selftest.json`. The orchestrator preserves E9 quota/rate/budget requirements by invoking the quota template writer, packet verifier, launch release check, and secret scan. It rejects obvious secret-like operator inputs before use and still records `secret_scan_passed` in the summary.

Default path state is correct while no real trusted-user values are supplied: `overall_status=blocked_by_missing_user_fields_only`, `ready_to_send=false`, `missing_fields=[release_owner,support_contact,tenant_id,project_id,wallet_id,rate_budget_guardrails,voucher_quota,rollback_owner]`, `blockers=[]`, `secret_scan_passed=true`, and `external_input_policy.missing_real_user_fields_are_deferred=true`. Filled selftest state is also correct: `overall_status=ready_to_send_trusted_user_beta`, `ready_to_send=true`, `missing_fields=[]`, `blockers=[]`, `secret_scan_passed=true`, and bounded refs/amounts only.

No E9 script bug was found. A future real handoff still requires operator-provided bounded values for the quota record; TODO-32J payment/order/invoice and TODO-32K subscription/package remain deferred external runtimes and are not blockers for voucher-backed beta.

### E9-LAUNCH-14 / Accounting evidence manifest review（2026-06-06）

E9 reviewed the accounting/quota artifacts that must be represented in the trusted-user handoff `evidence_manifest`. Minimum required E9 entries before handoff:

- `.tmp/launch/trusted_user_quota_rate_budget_record_template.json`: schema `trusted_user_quota_rate_budget_record_template.v1`, status `template_ready`, real user values not populated, `secret_safe=true`, `paid_gate_changed=false`.
- `.tmp/launch/voucher_backed_api_distribution_accounting_gate.json`: schema `voucher_backed_api_distribution_accounting_gate.v1`, `overall_status=launch_ready_with_productization_gaps`, `actual_exit_code=0`, `accounting_credit_acceptable=true`, `secret_safe=true`.
- `.tmp/launch/voucher_quota_pricing_guardrails.json`: schema `voucher_quota_pricing_guardrails.v1`, `overall_status=pass`, `actual_exit_code=0`, guardrails accepted, `secret_safe=true`.
- `.tmp/credit-wallet/user_remaining_balance_ownership_runtime.json`: schema `user_remaining_balance_runtime.v1`, `overall_status=pass`, `secret_safe=true`, `paid_gate_changed=false`.
- `.tmp/credit-wallet/recharge_voucher_runtime.json`: schema `recharge_voucher_runtime.v1`, `overall_status=pass`, `secret_safe=true`, `paid_gate_changed=false`.

Manifest acceptance criteria: entries must be repo-bounded and metadata-only, with path, schema/schema_version, status or overall_status, SHA256, size, last-write/generated timestamp where available, `secret_safe`, and `paid_gate_changed` where applicable. The manifest must not include raw voucher codes, virtual-key secrets, Authorization/Cookie headers, DB URLs, provider keys, raw provider payloads, raw request bodies, or unbounded operator text. Optional packet/summary/selftest artifacts may be listed, but selftest evidence must stay labeled as selftest and default handoff summary state may remain `blocked_by_missing_user_fields_only` until Release/Ops fills real per-user fields.

Main-thread review correction after E9 returned: the orchestrator was rerun after manifest support landed. Current `.tmp/launch/trusted_user_api_distribution_handoff_summary.json` and `.tmp/launch/trusted_user_api_distribution_handoff_summary.selftest.json` now contain `evidence_manifest` with 13 entries, no missing required entries, and no missing SHA256 for existing artifacts. TODO-32J payment/order/invoice and TODO-32K subscription/package stay deferred runtime false and are not current voucher-backed beta blockers.

### E9-LAUNCH-15 / Current evidence_manifest accounting rereview（2026-06-06）

E9 re-read the current `.tmp/launch/trusted_user_api_distribution_handoff_summary.json` rather than the earlier stale summary. The summary is schema `trusted_user_api_distribution_handoff_summary.v1` with `overall_status=blocked_by_missing_user_fields_only` because real per-user values are still external inputs. The embedded manifest is now present: schema `trusted_user_api_distribution_evidence_manifest.v1`, hash algorithm `SHA256`, 13 entries, and `missing_required_entries=[]`.

The five E9-required accounting/quota entries exist and have SHA256 hashes:

- `trusted_user_quota_rate_budget_template`: `.tmp/launch/trusted_user_quota_rate_budget_record_template.json`, schema `trusted_user_quota_rate_budget_record_template.v1`, status `template_ready`.
- `voucher_backed_api_distribution_accounting_gate`: `.tmp/launch/voucher_backed_api_distribution_accounting_gate.json`, schema `voucher_backed_api_distribution_accounting_gate.v1`, `overall_status=launch_ready_with_productization_gaps`.
- `voucher_quota_pricing_guardrails`: `.tmp/launch/voucher_quota_pricing_guardrails.json`, schema `voucher_quota_pricing_guardrails.v1`, `overall_status=pass`.
- `user_remaining_balance_runtime`: `.tmp/credit-wallet/user_remaining_balance_ownership_runtime.json`, schema `user_remaining_balance_runtime.v1`, `overall_status=pass`.
- `recharge_voucher_runtime`: `.tmp/credit-wallet/recharge_voucher_runtime.json`, schema `recharge_voucher_runtime.v1`, `overall_status=pass`.

E9 manifest verdict: accepted for accounting handoff. The manifest is metadata-only per its notes: repo-bounded paths, hashes, sizes, schemas, statuses, and counts only. It must not include raw voucher codes, full virtual keys, Authorization/Cookie headers, provider keys, DB URLs, raw request bodies, raw provider payloads, or unbounded operator text. Remaining gap is not accounting evidence; it is Release/Ops filling real trusted-user packet fields before distribution. TODO-32J payment/order/invoice and TODO-32K subscription/package remain deferred runtime false and non-blocking for the voucher-backed beta scope.

### E9-LAUNCH-16 / Operator quota record acceptance contract scoping（2026-06-06）

E9 reviewed the quota/rate/budget template and handoff orchestrator to scope validation for a future real filled `trusted_user_quota_and_rate_limit_record`. Current state: `.tmp/launch/trusted_user_quota_rate_budget_record_template.json` provides the expected structured fields for tenant/project/user/wallet refs, bounded virtual-key ref, fixed-decimal credit and budget amounts, currency, voucher/redemption/credit-grant/ledger refs, remaining-balance readback, model/price policy refs, RPM/TPM/concurrency/budget/profile binding, expiry/revoke/rollback, and audit/support refs. `scripts/prepare_trusted_user_api_distribution_packet.ps1` and `scripts/verify_trusted_user_distribution_review_packet.ps1` cover packet-level missing fields, evidence links, rollback checklist, and secret scan, but they do not yet parse a filled quota/rate/budget record as its own contract.

Recommended next verifier: `scripts/verify_trusted_user_quota_rate_budget_record.ps1`. Proposed acceptance DoD:

- Input `-RecordPath <json>` plus expected evidence paths for quota template, accounting gate, guardrails, remaining-balance runtime, recharge-voucher runtime, and handoff manifest.
- Money fields are fixed decimal strings; credit and budget are positive; floats are rejected.
- Currency matches voucher quota evidence and remaining-balance wallet currency.
- Tenant/project/user/wallet/virtual-key/voucher/redemption/credit-grant/ledger/model/price-policy/audit fields are bounded references only.
- RPM/TPM are positive integers, concurrency is positive or explicitly not applicable, budget window/profile binding is present, expiry/revoke/disable procedure is present, rollback owner/contact is present, and audit/support id is present.
- Evidence links still pass where required: accounting gate, guardrails, remaining-balance runtime, recharge-voucher runtime, and metadata-only handoff manifest.
- Raw voucher code, full virtual-key secret, Authorization/Cookie header, DB URL, provider key, provider payload, raw request body, raw idempotency secret, and unbounded operator prose are rejected.
- Output is secret-safe JSON under `.tmp/launch/trusted_user_quota_rate_budget_record_verification.json` with schema `trusted_user_quota_rate_budget_record_verification.v1`, `status=pass|blocked`, `ready_for_handoff`, blockers, missing fields, evidence hashes, and `real_user_values_present=true` only for a real filled record.

Decision: checklist-only can suffice for a narrow manual trusted-user beta if Release/Ops performs explicit review, but E9 recommends the verifier before any real key is sent because it converts the last E9-owned handoff ambiguity into a machine gate. This does not require Gateway, payment/order, or subscription runtime work. TODO-32J payment/order/invoice and TODO-32K subscription/package remain deferred runtime false and non-blocking for voucher-backed beta.

### E9-LAUNCH-17 / Quota-record verifier handoff to main（2026-06-06）

E9 converted the proposed filled-record verifier into an implementation checklist for `scripts/verify_trusted_user_quota_rate_budget_record.ps1`. This verifier should not require real user values to exist now; it should support `-SelfTest` with synthetic bounded fixtures, and validate a real record only when Release/Ops supplies one.

Parameters:

- `-RecordPath <json>` required outside `-SelfTest`, repo-bounded under `.tmp/**` or `artifacts/**`.
- `-OutputPath <json>` default `.tmp/launch/trusted_user_quota_rate_budget_record_verification.json`, repo-bounded under `.tmp/**` or `artifacts/**`.
- `-EvidenceManifestPath <json>` default `.tmp/launch/trusted_user_api_distribution_handoff_summary.json`; consume embedded `evidence_manifest` where present.
- Optional expected paths for quota template, accounting gate, guardrails, remaining-balance runtime, and recharge-voucher runtime.
- `-SelfTest` for synthetic pass/blocked cases.

Input schema: `trusted_user_quota_rate_budget_record.v1` with `real_user_values_present=true`, tenant/project/user/wallet refs, bounded virtual-key id or prefix, fixed-decimal credit amount, currency, voucher/redemption/credit-grant/ledger refs, remaining-balance readback, model/canonical model id, price book/policy/version refs, positive RPM/TPM/concurrency policy, fixed-decimal budget limit, budget window/profile binding, credit/key expiry timestamps, revoke/disable procedure, rollback owner/contact, audit/support id, evidence links, and `secret_safe=true`.

Output schema: `trusted_user_quota_rate_budget_record_verification.v1` with `status=pass|blocked`, `ready_for_handoff`, `actual_exit_code`, `record_path`, `evidence_manifest_path`, `missing_fields[]`, `blockers[]`, `validation_results`, `evidence_hashes`, `hash_mismatches[]`, `real_user_values_present`, `secret_safe`, `paid_gate_changed=false`, and `no_raw_secret_material_expected=true`.

Exit-code contract:

- `0`: complete filled record, secret-safe, evidence links pass, manifest hashes match when present, `ready_for_handoff=true`.
- `2`: acceptance blocked for missing/placeholders, invalid money/currency/rate/budget/expiry/audit, missing evidence, hash mismatch, or secret-like material.
- `1`: script or JSON parse failure.

Selftest matrix:

- synthetic bounded filled record passes.
- placeholder/template record blocks.
- float or non-positive money blocks.
- currency mismatch blocks.
- raw voucher code or virtual-key secret marker blocks.
- missing required evidence or manifest blocks unless explicitly testing a metadata-only dry-run case.
- manifest SHA256 mismatch blocks.

Evidence manifest handling: consume `trusted_user_api_distribution_evidence_manifest.v1` when available, locate quota template/accounting gate/guardrails/remaining-balance runtime/recharge-voucher runtime entries, require each to exist and have SHA256, recompute hashes for local paths, and write only paths/statuses/hashes to the verifier output. Do not embed artifact bodies, raw operator text, voucher codes, virtual-key secrets, Authorization/Cookie headers, DB URLs, provider keys, raw provider payloads, or raw request bodies.

Open implementation questions: whether the real filled quota record lives as a standalone JSON file or inside the distribution packet; whether conservative estimated TPM remains acceptable for the selected key or must be replaced by exact TPM evidence; whether `concurrency_limit_positive_integer_or_not_applicable` may use an explicit `not_applicable` enum for this beta. TODO-32J payment/order/invoice and TODO-32K subscription/package remain deferred runtime false and non-blocking for voucher-backed beta.

### E9-LAUNCH-18 / Quota-record verifier implementation preflight（2026-06-06）

E9 prepared exact implementation inputs for `scripts/verify_trusted_user_quota_rate_budget_record.ps1`. This section is historical pre-implementation scoping; MAIN-LAUNCH-16 below supersedes it with the implemented verifier and verification evidence. No real user values are required now.

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

- `schema` must equal `trusted_user_quota_rate_budget_record.v1`; `real_user_values_present` must be boolean `true` for pass.
- Bounded refs `tenant_id`, `project_id`, `trusted_user_id_or_owner_ref`, `wallet_id`, `virtual_key_id_or_key_prefix`, `voucher_id_or_redemption_id`, `credit_grant_id`, `ledger_entry_id`, `model_or_canonical_model_id`, `price_book_id_or_policy_ref`, `price_version_id_or_model_cost_policy_ref`, `api_key_profile_id_or_profile_binding_id`, `operator_id`, `support_owner`, and `audit_id_or_support_ticket_id` must match `^[A-Za-z0-9][A-Za-z0-9._:-]{2,127}$`, must not start with `REQUIRED_`, must not contain `<` or `>`, and must not match secret patterns.
- Money fields `credit_amount_fixed_decimal_string`, `budget_limit_amount_fixed_decimal_string`, and `remaining_balance_available_to_spend_fixed_decimal_string` must be JSON strings matching `^[0-9]+\\.[0-9]{8}$`; credit and budget must be greater than zero; remaining balance must be zero or positive.
- `currency` must match `^[A-Z]{3}$` and equal the currency read from guardrails and remaining-balance evidence when available.
- `rpm_limit_positive_integer` and `tpm_limit_positive_integer` must be JSON integers or integer strings matching `^[1-9][0-9]*$`.
- `concurrency_limit_positive_integer_or_not_applicable` must be a positive integer or exact string `not_applicable` only if a separate policy note is present.
- `credit_valid_until_utc` and `virtual_key_expires_at_utc` must parse as UTC ISO-8601 and be later than the verifier run time.
- `budget_window` must be `<utc-start>/<utc-end>` where both parse as UTC ISO-8601 and end is after start.
- `price_policy_evidence_path` and all `evidence_links.*` values must be repo-bounded paths under `.tmp/**` or `artifacts/**`; no absolute paths, `..`, URL schemes, or drive roots.
- `revoke_or_disable_procedure` and `rollback_contact` must be non-empty bounded strings, max 128 chars, with no raw secrets.
- `secret_safe` must be boolean `true`; `paid_gate_changed` must be absent or boolean `false`.

Reject this case-insensitive secret pattern in any string field: `authorization`, `bearer `, `cookie`, `sk-`, `x-api-key`, `postgres://`, `postgresql://`, `mysql://`, `redis://`, `raw_voucher`, `raw key`, `raw_secret`, `provider_key`, `virtual_key_secret`, `dev_test_key`, or any string longer than 256 chars unless the field is an allowed evidence path.

Evidence manifest and SHA checks:

- Read `-EvidenceManifestPath`; if it is a handoff summary, use `.evidence_manifest`; otherwise accept a direct `trusted_user_api_distribution_evidence_manifest.v1`.
- Require manifest schema `trusted_user_api_distribution_evidence_manifest.v1`, `hash_algorithm=SHA256`, and `missing_required_entries=[]`.
- Locate entries `trusted_user_quota_rate_budget_template`, `voucher_backed_api_distribution_accounting_gate`, `voucher_quota_pricing_guardrails`, `user_remaining_balance_runtime`, and `recharge_voucher_runtime`.
- For each entry, require `exists=true`, non-empty 64-hex `sha256`, and repo-bounded `path`.
- Recompute `Get-FileHash -Algorithm SHA256` for each local path and block on mismatch.
- Cross-check record `evidence_links` paths, when present, match manifest paths.
- Output only metadata: entry name, path, schema/status/overall_status, manifest hash, recomputed hash, and match boolean.

Verifier blockers should use stable machine codes such as `record_placeholder_values_present`, `money_decimal_invalid:<field>`, `currency_mismatch`, `rate_limit_invalid:<field>`, `evidence_manifest_missing`, `evidence_manifest_required_entry_missing:<name>`, `evidence_hash_mismatch:<name>`, `secret_like_value:<field>`, and `repo_path_not_bounded:<field>`. Exit `0` only when `ready_for_handoff=true`; exit `2` for blocked validation; exit `1` for parser/script errors.

### QA-LAUNCH-08 / Voucher-backed API Beta release verdict recheck（2026-06-06）

QA consumed the current Gateway closure and refreshed launch artifacts. `.tmp/launch/e8_gateway_paid_hot_path_launch_check.json` is `status=passed`; `.tmp/launch/gateway_voucher_distribution_readiness.json` is `status=pass`; `.tmp/launch/voucher_api_distribution_readiness.json` reports `overall_status=pass_with_productization_gaps`, `production_distribution_ready=true`, `production_distribution_full_ready=false`, `gateway_current_launch_hot_path_verified=true`, `secret_scan_passed=true`, and `remaining_blockers=[]`. `scripts/release_check.ps1 -Checks launch -SummaryPath artifacts/launch_voucher_api_distribution_release_check_20260606.json` exits 0 with `overallStatus=warn`; the warning is the expected productization-gap warning, not a failing launch blocker.

QA release verdict: trusted-user voucher-backed API beta distribution is releasable after normal release packet metadata is filled and secrets remain omitted. This does not claim full commercial readiness: public recharge/voucher route evidence is still a productization follow-up unless the operator-only path is approved, TODO-32J payment/order/invoice external provider runtime remains deferred, and TODO-32K subscription scheduler/provider runtime remains deferred. Updated `.tmp/launch/final_launch_gate_summary.json` records `ready_to_distribute_api=true`, `production_distribution_ready=true`, `production_distribution_full_ready=false`, `remaining_blockers=[]`, and productization gaps only.

```json
{
  "task_id": "QA-LAUNCH-08",
  "qa_release_verdict": "pass_with_productization_gaps",
  "trusted_user_voucher_backed_beta_distribution": "releasable_after_packet_metadata_is_filled",
  "production_distribution_ready": true,
  "production_distribution_full_ready": false,
  "remaining_blockers": [],
  "productization_gaps": [
    "public_recharge_voucher_route_evidence_pending",
    "payment_order_invoice_external_runtime_deferred",
    "subscription_scheduler_provider_runtime_deferred"
  ],
  "release_check_overall_status": "warn",
  "secret_scan": "pass"
}
```

### QA-LAUNCH-09 / Trusted-user distribution packet refresh（2026-06-06）

QA refreshed `scripts/verify_trusted_user_distribution_review_packet.ps1` and `.tmp/launch/trusted_user_distribution_review_packet.json` to consume current LAUNCH-08 evidence instead of the superseded Gateway-blocked state. The packet now records `global_launch_evidence.readiness_overall_status=pass_with_productization_gaps`, `production_distribution_ready=true`, `production_distribution_full_ready=false`, `gateway_status=passed`, `gateway_current_launch_hot_path_verified=true`, `secret_scan_passed=true`, and `current_blockers=[]`.

Default packet status remains `ready_to_send=false`, but only because per-user handoff fields are still placeholders: release owner, support contact, tenant/project/wallet ids, voucher quota, rate/budget guardrail record, and rollback owner. This is no longer a global launch blocker. The verifier supports a parameterized generation path; a filled selftest packet at `.tmp/launch/trusted_user_distribution_review_packet.filled_selftest.json` verifies `ready_to_send=true`, `overall_status=pass`, and no blockers without writing raw voucher codes or virtual-key secrets.

```json
{
  "task_id": "QA-LAUNCH-09",
  "packet_artifact": ".tmp/launch/trusted_user_distribution_review_packet.json",
  "packet_status": "blocked_by_per_user_packet_fields_only",
  "ready_to_send": false,
  "global_launch_blockers": [],
  "parameterized_filled_packet_verified": true,
  "productization_gaps_not_blockers": [
    "public_recharge_voucher_route_evidence_pending_or_operator_only_policy_cleanup",
    "payment_order_invoice_external_runtime_deferred",
    "subscription_scheduler_provider_runtime_deferred"
  ]
}
```

### QA-LAUNCH-10 / Per-user packet final handoff watcher（2026-06-06）

QA rechecked the trusted-user packet after QA-LAUNCH-09. Default `.tmp/launch/trusted_user_distribution_review_packet.json` remains `ready_to_send=false`, but `readiness_status=blocked_by_per_user_packet_fields_only`, `current_blockers=[]`, and the only missing fields are release owner, support contact, tenant/project/wallet ids, voucher quota, rate/budget guardrail record, and rollback owner. This is not a global launch regression.

Parameterized `.tmp/launch/trusted_user_distribution_review_packet.filled_selftest.json` remains a secret-safe synthetic filled-path proof: `ready_to_send=true`, `current_blockers=[]`, `missing_fields=[]`, and no raw voucher code, Authorization/Cookie, DB URL, provider key, or virtual-key secret output. No real user values were written.

Launch readiness did not regress: `.tmp/launch/voucher_api_distribution_readiness.json` remains `overall_status=pass_with_productization_gaps`, `production_distribution_ready=true`, `production_distribution_full_ready=false`, `gateway_current_launch_hot_path_verified=true`, `secret_scan_passed=true`, and `remaining_blockers=[]`. TODO-32J/TODO-32K and public route polish remain productization/deferred gaps, not blockers for the scoped trusted-user voucher-backed Beta gate.

```json
{
  "task_id": "QA-LAUNCH-10",
  "default_packet_ready_to_send": false,
  "default_packet_blockers": [],
  "default_packet_missing_fields": [
    "release_owner",
    "support_contact",
    "tenant_id",
    "project_id",
    "wallet_id",
    "voucher_quota",
    "rate_budget_guardrails",
    "rollback_owner"
  ],
  "filled_selftest_ready_to_send": true,
  "real_user_values_written": false,
  "launch_readiness_regressed": false
}
```

### QA-LAUNCH-11 / Release handoff checklist verifier brief（2026-06-06）

QA reviewed `scripts/verify_trusted_user_distribution_review_packet.ps1` for Release/Ops handoff. The parameterized path is sufficient to generate a `ready_to_send=true` packet without writing raw voucher codes, full virtual keys, Authorization/Cookie headers, DB URLs, provider keys, or other secret material. No real user values were written in this QA slice.

Release/Ops command template:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/prepare_trusted_user_api_distribution_packet.ps1 `
  -PacketPath .tmp/launch/trusted_user_distribution_review_packet.<trusted-user-id>.json `
  -SummaryPath .tmp/launch/trusted_user_api_distribution_handoff_summary.<trusted-user-id>.json `
  -ReleaseOwner "<release-owner-name-or-handle>" `
  -SupportContact "<support-contact-or-channel>" `
  -TenantId "<tenant-id>" `
  -ProjectId "<project-id>" `
  -WalletId "<wallet-id>" `
  -VoucherQuota "<voucher-or-campaign-id-and-fixed-decimal-quota>" `
  -RateBudgetGuardrails "<bounded-rate-budget-record-or-template-ref>" `
  -RollbackOwner "<rollback-owner-name-or-handle>"
```

The legacy direct packet-verifier command remains valid for focused QA:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_trusted_user_distribution_review_packet.ps1 `
  -WriteDefaultPacket `
  -PacketPath .tmp/launch/trusted_user_distribution_review_packet.<trusted-user-id>.json `
  -ReleaseOwner "<release-owner-name-or-handle>" `
  -SupportContact "<support-contact-or-channel>" `
  -TenantId "<tenant-id>" `
  -ProjectId "<project-id>" `
  -WalletId "<wallet-id>" `
  -VoucherQuota "<voucher-or-campaign-id-and-fixed-decimal-quota>" `
  -RateBudgetGuardrails "<bounded-rate-budget-record-or-template-ref>" `
  -RollbackOwner "<rollback-owner-name-or-handle>"
```

Required fields before handoff: release owner, support contact, tenant id, project id, wallet id, voucher quota or campaign id plus fixed-decimal amount, rate/budget guardrail record, and rollback owner. After generating the target-user packet, rerun:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_trusted_user_distribution_review_packet.ps1 -PacketPath .tmp/launch/trusted_user_distribution_review_packet.<trusted-user-id>.json
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/release_check.ps1 -Checks launch -SummaryPath artifacts/launch_voucher_api_distribution_release_check_20260606.json
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/scan_secrets.ps1
```

Default `.tmp/launch/trusted_user_distribution_review_packet.json` returning JSON `actual_exit_code=2` is expected while those per-user fields are missing. It is not a launch failure when `blockers=[]` and `.tmp/launch/voucher_api_distribution_readiness.json` remains `pass_with_productization_gaps` with `remaining_blockers=[]`.

Main-thread orchestrator verification:

- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/prepare_trusted_user_api_distribution_packet.ps1 -SelfTest`: exit 0, generated `.tmp/launch/trusted_user_api_distribution_handoff_summary.selftest.json` with `overall_status=ready_to_send_trusted_user_beta`.
- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/prepare_trusted_user_api_distribution_packet.ps1 -AllowMissingUserFields`: expected exit 2, generated `.tmp/launch/trusted_user_api_distribution_handoff_summary.json` with `overall_status=blocked_by_missing_user_fields_only`, `blockers=[]`, and only real per-user fields missing.
- Real missing per-user values are external inputs and must be documented/deferred when unavailable; do not fabricate them locally.

MAIN-LAUNCH-14 update: the orchestrator summary now includes `evidence_manifest` for release archive and review. It records repo-bounded artifact paths, required/existing flags, byte size, SHA256, schema, status/overall status, `ready_to_send`, blocker count, missing-field count, and generated timestamp for the trusted-user packet, release check, quota/rate/budget template, launch readiness, accounting gate, Gateway paid launch check, Gateway voucher readiness, quota/pricing guardrails, voucher route/virtual-key evidence, operator packet, operator-only exception, remaining-balance runtime, and recharge-voucher runtime. It stores metadata only; do not add raw voucher codes, full virtual keys, Authorization/Cookie headers, provider keys, DB URLs, raw request bodies, or raw provider payloads.

Manifest verification:

- Selftest summary remains `ready_to_send_trusted_user_beta`; manifest has 13 entries, no missing required entries, no missing SHA256 for existing artifacts, and packet entry `ready_to_send=true`.
- Default missing-fields summary remains `blocked_by_missing_user_fields_only`; manifest has 13 entries, no missing required entries, no missing SHA256 for existing artifacts, and packet entry records 8 missing external user fields.
- The only manifest artifact currently reporting `blockers_count>0` is `.tmp/launch/voucher_public_route_and_virtual_key_evidence.json` with `overall_status=partial`; this stays a public-route productization gap under the operator-mediated trusted-user beta path.

MAIN-LAUNCH-15 update: `scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1` is now the standalone manifest regression guard. It checks the handoff summary schema, manifest schema, SHA256 algorithm, required evidence entries, empty `missing_required_entries`, repo-bounded paths, positive bytes for existing artifacts, lowercase 64-hex hashes, metadata-only entry fields, and secret-like value rejection. It intentionally does not require `ready_to_send=true`, so `.tmp/launch/trusted_user_api_distribution_handoff_summary.json` can pass manifest verification while still being blocked for actual user handoff by missing external per-user fields.

Manifest verifier commands:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1 -SelfTest
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1 -SummaryPath .tmp/launch/trusted_user_api_distribution_handoff_summary.<trusted-user-id>.json
```

MAIN-LAUNCH-16 update: `scripts/verify_trusted_user_quota_rate_budget_record.ps1` now validates the real selected-user quota/rate/budget record that Release/Ops must provide before handoff. It validates schema `trusted_user_quota_rate_budget_record.v1`, `real_user_values_present=true`, fixed-decimal money strings, uppercase currency, bounded refs, positive rate/budget policy, future expiry timestamps, rollback/audit fields, repo-bounded evidence links, `secret_safe=true`, `paid_gate_changed=false`, and evidence-manifest SHA256 matches for quota template, accounting gate, guardrails, remaining-balance runtime, and recharge-voucher runtime. It rejects raw voucher/key/provider/auth/cookie/DB/request-body/provider-payload/idempotency-like material.

Quota record verifier commands:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_trusted_user_quota_rate_budget_record.ps1 -SelfTest
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_trusted_user_quota_rate_budget_record.ps1 `
  -RecordPath .tmp/launch/trusted_user_quota_rate_budget_record.<trusted-user-id>.json `
  -EvidenceManifestPath .tmp/launch/trusted_user_api_distribution_handoff_summary.<trusted-user-id>.json `
  -OutputPath .tmp/launch/trusted_user_quota_rate_budget_record_verification.<trusted-user-id>.json
```

Sequential execution requirement: do not run the orchestrator and manifest/quota verifiers in parallel because the orchestrator refreshes `.tmp/launch` artifacts and hashes. Real handoff requires all target-user commands to exit 0; exit 2 is accepted only for dry-run/default missing-field review paths.

Verified quota verifier evidence:

- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_trusted_user_quota_rate_budget_record.ps1 -SelfTest`: exit 0; synthetic bounded filled record passes, while placeholder/default, bad money, invalid currency, and secret-like record cases block.
- `.tmp/launch/trusted_user_quota_rate_budget_record.selftest.pass.json` verified with exit 0 and wrote `.tmp/launch/trusted_user_quota_rate_budget_record_verification.selftest.pass.json` with `status=pass`, `ready_for_handoff=true`, and `actual_exit_code=0`.
- `.tmp/launch/trusted_user_quota_rate_budget_record.selftest.blocked.json` verified with expected exit 2 and wrote `.tmp/launch/trusted_user_quota_rate_budget_record_verification.selftest.blocked.json` with `status=blocked`, `ready_for_handoff=false`, missing `tenant_id`, and blockers `real_user_values_present_not_true` plus `record_placeholder_values_present`.
- Sequential chain passed: orchestrator selftest, orchestrator default `-AllowMissingUserFields` expected exit 2, evidence manifest verifier selftest/default summary, quota record verifier selftest, secret scan, and scoped `git diff --check`.

```json
{
  "task_id": "QA-LAUNCH-11",
  "handoff_template_ready": true,
  "real_user_values_written": false,
  "default_packet_exit_2_expected": true,
  "default_packet_failure_classification": "per_user_missing_fields_not_launch_failure",
  "required_fields": [
    "release_owner",
    "support_contact",
    "tenant_id",
    "project_id",
    "wallet_id",
    "voucher_quota",
    "rate_budget_guardrails",
    "rollback_owner"
  ]
}
```

### QA-LAUNCH-12 / Trusted-user distribution packet watcher（2026-06-06）

QA rechecked the current trusted-user distribution packet behavior without writing real user values. Running `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_trusted_user_distribution_review_packet.ps1` against the default packet returns shell nonzero with JSON `actual_exit_code=2`, `overall_status=blocked`, `ready_to_send=false`, and `blockers=[]`. This is the expected external-input state: the only missing fields are release owner, support contact, tenant id, project id, wallet id, rate/budget guardrails, voucher quota, and rollback owner.

The default packet `.tmp/launch/trusted_user_distribution_review_packet.json` continues to show `readiness_status=blocked_by_per_user_packet_fields_only`, `global_launch_evidence.readiness_overall_status=pass_with_productization_gaps`, `production_distribution_ready=true`, `production_distribution_full_ready=false`, `gateway_status=passed`, `gateway_current_launch_hot_path_verified=true`, `secret_scan_passed=true`, and `current_blockers=[]`.

The parameterized filled-path artifact `.tmp/launch/trusted_user_distribution_review_packet.filled_selftest.json` remains `ready_to_send=true`, `readiness_status=ready_to_send_trusted_user_beta`, `current_blockers=[]`, `missing_fields=[]`, and secret-safe: no raw voucher code, Authorization/Cookie, DB URL, provider key, or virtual-key secret output. The filled artifact uses QA placeholder values only; no real user values were written.

Remaining gap is entirely Release/Ops-provided per-user metadata. It is documented/deferred until a real trusted user is selected and the packet fields are filled. Do not broaden the launch blocker list unless a current artifact regresses beyond these missing fields.

```json
{
  "task_id": "QA-LAUNCH-12",
  "default_packet_exit_code": 2,
  "default_packet_exit_semantics": "expected_per_user_missing_fields",
  "default_packet_blockers": [],
  "filled_selftest_ready_to_send": true,
  "real_user_values_written": false,
  "remaining_operator_fields": [
    "release_owner",
    "support_contact",
    "tenant_id",
    "project_id",
    "wallet_id",
    "voucher_quota",
    "rate_budget_guardrails",
    "rollback_owner"
  ]
}
```

### QA-LAUNCH-13 / Orchestrator QA watcher（2026-06-06）

QA reviewed `scripts/prepare_trusted_user_api_distribution_packet.ps1` semantics and current artifacts. No script defect was found. The orchestrator correctly composes quota/rate template generation, trusted-user packet verification, launch release check, and secret scan into `.tmp/launch/trusted_user_api_distribution_handoff_summary.json`.

Ready path: `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/prepare_trusted_user_api_distribution_packet.ps1 -SelfTest` exits 0 and writes `.tmp/launch/trusted_user_api_distribution_handoff_summary.selftest.json` with `overall_status=ready_to_send_trusted_user_beta`, `ready_to_send=true`, `missing_fields=[]`, `blockers=[]`, `release_check_overall_status=warn`, `secret_scan_passed=true`, and `no_raw_secret_material_expected=true`.

Default missing-fields path: running with `-AllowMissingUserFields` writes `.tmp/launch/trusted_user_api_distribution_handoff_summary.json` with `overall_status=blocked_by_missing_user_fields_only`, `ready_to_send=false`, `blockers=[]`, `release_check_overall_status=warn`, `secret_scan_passed=true`, and `no_raw_secret_material_expected=true`. Explicit `$LASTEXITCODE` capture shows exit code 2 for this accepted missing-fields path. This is expected and is not a launch failure.

The only remaining gap is external Release/Ops input: release owner, support contact, tenant id, project id, wallet id, voucher quota, rate/budget guardrails, and rollback owner. No current blocker exists beyond those fields; do not broaden the blocker list unless launch readiness, release check, packet verifier, or secret scan regresses.

```json
{
  "task_id": "QA-LAUNCH-13",
  "orchestrator_script": "scripts/prepare_trusted_user_api_distribution_packet.ps1",
  "selftest_status": "ready_to_send_trusted_user_beta",
  "selftest_exit_code": 0,
  "default_allow_missing_status": "blocked_by_missing_user_fields_only",
  "default_allow_missing_exit_code": 2,
  "blockers": [],
  "secret_safe": true,
  "script_defects": []
}
```

### QA-LAUNCH-14 / Handoff manifest QA review（2026-06-06）

QA reviewed the evidence manifest behavior for `scripts/prepare_trusted_user_api_distribution_packet.ps1`. The first QA read happened before the final orchestrator rerun; main-thread review correction confirms the current worktree and regenerated summaries now expose `evidence_manifest` with SHA256 hash fields. No critical script defect was found in the visible behavior.

Exit semantics remain correct. `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/prepare_trusted_user_api_distribution_packet.ps1 -SelfTest` exits 0 and writes `.tmp/launch/trusted_user_api_distribution_handoff_summary.selftest.json` with `overall_status=ready_to_send_trusted_user_beta`, `ready_to_send=true`, `blockers=[]`, `secret_scan_passed=true`, and `no_raw_secret_material_expected=true`. Strict mode without real user fields still fails before handoff with `missing_required_user_fields`. The accepted missing-fields path `-AllowMissingUserFields` writes `.tmp/launch/trusted_user_api_distribution_handoff_summary.json` with `overall_status=blocked_by_missing_user_fields_only`, `ready_to_send=false`, `blockers=[]`, `secret_scan_passed=true`, and `no_raw_secret_material_expected=true`; explicit `$LASTEXITCODE` capture confirms exit code 2.

Secret-safety verdict: current summaries include paths/statuses/steps, evidence-manifest metadata, and secret-safety flags, and do not include raw voucher code, virtual-key secret, provider key, Authorization/Cookie header, DB URL, or provider payload. Manifest entries contain bounded artifact paths, hashes, and status/schema/count metadata only; raw secret material must remain excluded.

```json
{
  "task_id": "QA-LAUNCH-14",
  "orchestrator_script": "scripts/prepare_trusted_user_api_distribution_packet.ps1",
  "evidence_manifest_visible": true,
  "manifest_review_status": "landed_after_main_thread_rerun_current_summary_secret_safe",
  "selftest_exit_code": 0,
  "allow_missing_exit_code": 2,
  "strict_missing_fields_fails": true,
  "allow_missing_blockers": [],
  "secret_safe": true,
  "script_defects": []
}
```

### QA-LAUNCH-15 / Current evidence_manifest QA rereview（2026-06-06）

QA reran the current orchestrator after the main-thread correction that `evidence_manifest` is now present. Both `.tmp/launch/trusted_user_api_distribution_handoff_summary.json` and `.tmp/launch/trusted_user_api_distribution_handoff_summary.selftest.json` contain `evidence_manifest` with schema `trusted_user_api_distribution_evidence_manifest.v1`, `hash_algorithm=SHA256`, 13 entries, and `missing_required_entries=[]`. For required existing artifacts, every entry has a 64-character lowercase SHA256; structured checks found `bad_required_sha_count=0` for both the default and selftest summaries.

Current exit semantics remain correct: `prepare_trusted_user_api_distribution_packet.ps1 -SelfTest` exits 0 and produces `overall_status=ready_to_send_trusted_user_beta`; strict mode without real per-user fields still fails with `missing_required_user_fields`; `-AllowMissingUserFields` exits 2 and produces `overall_status=blocked_by_missing_user_fields_only`, `ready_to_send=false`, `blockers=[]`, and the expected missing Release/Ops fields only.

Secret-safety verdict: manifest entries contain repo-bounded paths, bytes, SHA256, schema, status/overall status, ready-to-send flag, blocker count, missing-field count, and generated timestamp. They do not include raw voucher code, full virtual key, Authorization/Cookie headers, provider key, DB URL, raw request body, or raw provider payload. `scripts/scan_secrets.ps1` reports hits=0 and warnings=0. `rg` matches only the manifest policy note that prohibits storing those secret categories, not raw material.

```json
{
  "task_id": "QA-LAUNCH-15",
  "evidence_manifest_visible": true,
  "manifest_entries_count": 13,
  "missing_required_entries_count": 0,
  "bad_required_sha_count": 0,
  "selftest_exit_code": 0,
  "allow_missing_exit_code": 2,
  "strict_missing_fields_fails": true,
  "allow_missing_blockers": [],
  "secret_scan": "pass",
  "script_defects": []
}
```

### QA-LAUNCH-16 / Manifest regression guard scoping（2026-06-06）

QA scoped whether the trusted-user handoff `evidence_manifest` needs its own regression guard. Current summaries are valid, but relying only on orchestrator selftest is weak: the orchestrator generates the manifest and proves the happy/missing-field paths, but it does not independently assert the full required entry set, SHA256 shape, field allowlist, or secret-like string rejection. Recommendation: add a tiny standalone read-only verifier rather than folding more assertions into the orchestrator selftest.

Recommended next implementation: `scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1`.

Verifier contract:

- Input parameters: `-SummaryPath .tmp/launch/trusted_user_api_distribution_handoff_summary.json`, optional `-SelfTest`.
- Require summary schema `trusted_user_api_distribution_handoff_summary.v1`.
- Require `evidence_manifest.schema=trusted_user_api_distribution_evidence_manifest.v1` and `hash_algorithm=SHA256`.
- Require at least these manifest entry names: `trusted_user_distribution_packet`, `launch_release_check_summary`, `trusted_user_quota_rate_budget_template`, `voucher_api_distribution_readiness`, `voucher_backed_api_distribution_accounting_gate`, `e8_gateway_paid_hot_path_launch_check`, `gateway_voucher_distribution_readiness`, `voucher_quota_pricing_guardrails`, `voucher_public_route_and_virtual_key_evidence`, `user_remaining_balance_runtime`, and `recharge_voucher_runtime`; optional entries may include `api_distribution_operator_packet` and `voucher_operator_only_exception`.
- Require `missing_required_entries=[]`.
- For every required existing entry, require repo-bounded `path`, `exists=true`, positive `bytes`, and lowercase 64-hex `sha256`.
- Enforce metadata-only entry fields: name/path/required/exists/bytes/sha256/schema/status/overall_status/ready_to_send/blockers_count/missing_fields_count/generated_at_utc. Reject raw artifact body fields or unbounded operator text.
- Reject secret-like strings in manifest values: raw voucher code, full virtual key, Authorization/Cookie header material, provider key, DB URL, raw request body, raw provider payload, bearer token, API key, and raw idempotency key. Policy-note strings that name prohibited categories may be allowed only in `notes`.
- Exit semantics: pass exit 0; manifest/data unsafe or malformed exit 1; missing summary path exit 1. It should not use exit 2 because this verifier checks manifest integrity, not per-user missing-field readiness.
- SelfTest cases: current valid default summary accepted, current valid selftest summary accepted, missing required entry rejected, bad/missing SHA256 rejected, secret-like manifest value rejected, unallowed field rejected.

Risk decision: no script change was made in QA-LAUNCH-16 because this is a scoping slice and current manifest remains valid. Next QA slice should implement the standalone verifier if Release wants hard regression protection.

```json
{
  "task_id": "QA-LAUNCH-16",
  "current_manifest_valid": true,
  "standalone_verifier_recommended": true,
  "recommended_script": "scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1",
  "fold_into_orchestrator_selftest": false,
  "current_risk": "future manifest edits could silently drop required entries, hashes, or metadata-only discipline without a dedicated verifier",
  "next_implementation": "add read-only verifier with selftest and wire it into release review"
}
```

### QA-LAUNCH-17 / Standalone evidence_manifest verifier review（2026-06-06）

QA's first check happened before the main-thread verifier script landed. Main-thread correction: `scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1` now exists and has been verified against selftest fixtures, the default handoff summary, and the filled selftest summary.

Verified review DoD:

- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1 -SelfTest`: exit 0; accepts a good synthetic summary and rejects missing required entry, bad SHA256, unallowed manifest field, and secret-like manifest value.
- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1 -SummaryPath .tmp/launch/trusted_user_api_distribution_handoff_summary.json`: exit 0; default missing-fields summary passes manifest integrity without requiring `ready_to_send=true`.
- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1 -SummaryPath .tmp/launch/trusted_user_api_distribution_handoff_summary.selftest.json`: exit 0.
- Required entry set is enforced, including trusted-user packet, release check summary, quota/rate/budget template, launch readiness, accounting gate, E8 paid launch check, Gateway voucher readiness, guardrails, route/virtual-key evidence, user remaining-balance runtime, and recharge-voucher runtime.
- `missing_required_entries=[]`, repo-bounded paths, SHA256 for existing required artifacts, metadata-only entry fields, and secret-like string rejection are enforced.
- Exit semantics: verifier pass exits 0; malformed/unsafe/missing summary exits 1; no exit 2 for manifest integrity.

```json
{
  "task_id": "QA-LAUNCH-17",
  "standalone_verifier_visible": true,
  "commands_run": [
    "scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1 -SelfTest",
    "scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1 -SummaryPath .tmp/launch/trusted_user_api_distribution_handoff_summary.json",
    "scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1 -SummaryPath .tmp/launch/trusted_user_api_distribution_handoff_summary.selftest.json"
  ],
  "review_status": "verified_by_main_thread_after_script_landed",
  "critical_defects_found": [],
  "expected_default_summary_ready_to_send_required": false,
  "next_task": "Keep standalone verifier in final Release/Ops packet review."
}
```

### QA-LAUNCH-18 / Verifier command chain review（2026-06-06）

QA reviewed the final command chain for a real target-user API handoff now that the standalone evidence-manifest verifier exists. The real handoff path must not use `-AllowMissingUserFields`; all selected-user fields must be supplied as bounded, secret-safe values by Release/Ops before handing a key to a trusted user.

Real handoff command order:

1. Generate the target-user packet and summary with real per-user values:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/prepare_trusted_user_api_distribution_packet.ps1 `
  -PacketPath .tmp/launch/trusted_user_distribution_review_packet.<trusted-user-id>.json `
  -SummaryPath .tmp/launch/trusted_user_api_distribution_handoff_summary.<trusted-user-id>.json `
  -ReleaseOwner "<release-owner-name-or-handle>" `
  -SupportContact "<support-contact-or-channel>" `
  -TenantId "<tenant-id>" `
  -ProjectId "<project-id>" `
  -WalletId "<wallet-id>" `
  -VoucherQuota "<voucher-or-campaign-id-and-fixed-decimal-quota>" `
  -RateBudgetGuardrails "<bounded-rate-budget-record-or-template-ref>" `
  -RollbackOwner "<rollback-owner-name-or-handle>"
```

Expected real-handoff result: exit 0, `ready_to_send=true`, `blockers=[]`, `missing_fields=[]`, launch release check evidence current, secret scan passed, and `evidence_manifest` written with SHA256 metadata for required artifacts.

2. Verify the generated evidence manifest:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1 `
  -SummaryPath .tmp/launch/trusted_user_api_distribution_handoff_summary.<trusted-user-id>.json
```

Expected real-handoff result: exit 0. The verifier checks required entry names, repo-bounded paths, SHA256 shape, metadata-only entry fields, and secret-like string rejection; it does not require `ready_to_send=true` for default dry-run summaries, but the real handoff summary must already be ready from step 1.

3. Run the final repo secret scan immediately before handoff:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/scan_secrets.ps1
```

Expected real-handoff result: exit 0, no hits, no warnings.

Independent release-check note: `scripts/prepare_trusted_user_api_distribution_packet.ps1` is the authoritative packet-generation command because it refreshes launch release-check evidence and writes the manifest. If Release/Ops independently reruns `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/release_check.ps1 -Checks launch -SummaryPath artifacts/launch_voucher_api_distribution_release_check_20260606.json` after the packet was generated, rerun the packet command and manifest verifier afterward so manifest hashes reflect the final release summary.

Exit semantics:

- Real target-user handoff: acceptable exits are orchestrator exit 0, manifest verifier exit 0, final secret scan exit 0. Any nonzero exit blocks handoff until corrected.
- Dry-run/default missing-fields review only: orchestrator or packet-verifier exit 2 is acceptable when caused solely by missing external per-user fields and `-AllowMissingUserFields`/default placeholder mode is intentionally used.
- Strict missing-field run without `-AllowMissingUserFields`: nonzero exit is expected but means real handoff is blocked until Release/Ops supplies release owner, support contact, tenant/project/wallet ids, voucher quota, rate/budget guardrails, and rollback owner.
- Manifest verifier malformed/unsafe/missing-summary failures exit 1 and are never acceptable for real handoff.

Verification rerun for QA-LAUNCH-18:

- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1 -SelfTest`: exit 0.
- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1 -SummaryPath .tmp/launch/trusted_user_api_distribution_handoff_summary.json`: exit 0; default summary remains `ready_to_send=false` / `blocked_by_missing_user_fields_only`, which is acceptable only for review.
- `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1 -SummaryPath .tmp/launch/trusted_user_api_distribution_handoff_summary.selftest.json`: exit 0; filled selftest summary is `ready_to_send=true`.

```json
{
  "task_id": "QA-LAUNCH-18",
  "real_handoff_requires_allow_missing_user_fields": false,
  "real_handoff_allowed_nonzero_exits": [],
  "dry_run_allowed_nonzero_exits": [
    {
      "exit_code": 2,
      "scope": "default_or_AllowMissingUserFields_missing_per_user_fields_only"
    }
  ],
  "command_chain": [
    "scripts/prepare_trusted_user_api_distribution_packet.ps1 with real per-user fields and no -AllowMissingUserFields",
    "scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1 -SummaryPath .tmp/launch/trusted_user_api_distribution_handoff_summary.<trusted-user-id>.json",
    "scripts/scan_secrets.ps1"
  ],
  "independent_release_check_rerun_rule": "If release_check.ps1 -Checks launch is rerun after packet generation, regenerate the packet summary and rerun the manifest verifier so SHA256 manifest entries are current.",
  "remaining_release_risk": "External Release/Ops fields must be supplied for each target user; public voucher route polish and payment/subscription runtimes remain productization/deferred gaps, not blockers for scoped voucher-backed trusted-user Beta handoff."
}
```

### DOC-LAUNCH-08 / Current voucher-backed Beta distribution state（2026-06-06）

Current artifact review changed the launch posture from blocked packet preparation to scoped trusted-user voucher-backed Beta distribution ready with productization gaps. `docs/TODO.md` remains non-authoritative; use this TODO file plus `project/RELEASE_CHECKLIST.md`, `project/ACCEPTANCE_CHECKLIST.md`, and `docs/P0_BETA_STATUS.md` for current launch status.

Current artifacts:

- `artifacts/launch_voucher_api_distribution_release_check_20260606.json`: `overallStatus=warn`.
- `.tmp/launch/voucher_api_distribution_readiness.json`: `overall_status=pass_with_productization_gaps`, `production_distribution_ready=true`, `gateway_current_launch_hot_path_verified=true`, `secret_safe=true`, `paid_gate_changed=false`.
- `.tmp/launch/voucher_backed_api_distribution_accounting_gate.json`: `overall_status=launch_ready_with_productization_gaps`, `api_distribution_launch_ready=true`, `secret_safe=true`.
- `.tmp/launch/e8_gateway_paid_hot_path_launch_check.json`: `status=passed`; current insufficient-balance path is proven as 402/no-provider-call.
- `.tmp/launch/gateway_voucher_distribution_readiness.json`: `status=pass`.
- `.tmp/launch/voucher_quota_pricing_guardrails.json`: `overall_status=pass`, `launch_ready=true`, `secret_safe=true`.

Decision: trusted-user voucher-backed Beta API distribution may proceed after the target user's packet fields are completed and reviewed through `scripts/prepare_trusted_user_api_distribution_packet.ps1`. If `.tmp/launch/api_distribution_operator_packet.json`, `.tmp/launch/trusted_user_distribution_review_packet.json`, or `.tmp/launch/trusted_user_api_distribution_handoff_summary.json` still reports `ready_to_send=false`, treat that as per-user packet incompleteness, not a global launch blocker: fill release owner, support contact, tenant/project/wallet ids, voucher/quota amount, rate/budget limits, rollback owner, bounded evidence links, and secret-scan record before handing a specific key to a trusted user.

Still deferred / not full commercial readiness:

- Public voucher route polish or explicit operator-only exception policy finalization remains a follow-up.
- TODO-32J payment/order/invoice runtime remains `payment_order_invoice_runtime_verified=false`.
- TODO-32K subscription/package runtime remains `subscription_package_lifecycle_runtime_verified=false`.
- These are deferred/resume-condition items per user direction when external provider/scheduler/runtime capability is unavailable; they do not block this voucher-backed trusted-user Beta distribution scope.

```json
{
  "task_id": "DOC-LAUNCH-08",
  "trusted_user_voucher_backed_beta_distribution": "ready_with_productization_gaps",
  "release_check_overall_status": "warn",
  "readiness_status": "pass_with_productization_gaps",
  "accounting_status": "launch_ready_with_productization_gaps",
  "guardrails_status": "pass",
  "e8_gateway_launch_check": "passed",
  "public_voucher_route_polish": "deferred_resume_condition",
  "payment_order_invoice_runtime_verified": false,
  "subscription_package_lifecycle_runtime_verified": false,
  "docs_todo_md_authoritative": false,
  "recommended_next_task": "Complete per-user packet fields, rerun secret scan/release check for the selected trusted user, and proceed with voucher-backed Beta distribution; keep public route/payment/subscription runtime as deferred productization work."
}
```

### E8-LAUNCH-12 / Gateway paid hot-path watcher（2026-06-06）

E8 performed an artifact-inspection-only regression check to avoid requiring fresh external runtime values. Current Gateway paid launch evidence remains accepted:

- `.tmp/launch/e8_gateway_paid_hot_path_launch_check.json` has `schema=gateway_paid_hot_path_smoke_v1`, `status=passed`, and insufficient-balance `provider_attempt_rows=0`.
- `.tmp/launch/gateway_voucher_distribution_readiness.json` has `schema=gateway_voucher_distribution_readiness_v1`, `status=pass`, and `paid_hot_path_verified.current_launch_live_verified=true`.
- `.tmp/launch/voucher_api_distribution_readiness.json` has `schema=voucher_api_distribution_launch_gate.v1`, `overall_status=pass_with_productization_gaps`, `production_distribution_ready=true`, and `gateway_current_launch_hot_path_verified=true`.

No Gateway paid hot-path regression was observed. Remaining non-Gateway gaps stay unchanged: public voucher route/productization and TODO-32J/TODO-32K payment/subscription external runtimes remain deferred/productization follow-up, not current Gateway blockers for the voucher-backed trusted-user Beta scope.

### E8-LAUNCH-13 / Orchestrator Gateway evidence watcher（2026-06-06）

E8 rechecked the trusted-user handoff orchestrator outputs against current Gateway launch evidence. No Gateway regression or proof weakening was observed:

- `.tmp/launch/trusted_user_api_distribution_handoff_summary.selftest.json` has `schema=trusted_user_api_distribution_handoff_summary.v1`, `overall_status=ready_to_send_trusted_user_beta`, `ready_to_send=true`, `missing_fields=[]`, `blockers=[]`, `release_check_overall_status=warn`, and `secret_scan_passed=true`.
- `.tmp/launch/trusted_user_api_distribution_handoff_summary.json` remains blocked only by missing selected-user packet fields (`release_owner`, `support_contact`, `tenant_id`, `project_id`, `wallet_id`, `rate_budget_guardrails`, `voucher_quota`, `rollback_owner`); `blockers=[]`, release check is still `warn`, and secret scan is passed.
- `.tmp/launch/e8_gateway_paid_hot_path_launch_check.json` remains `schema=gateway_paid_hot_path_smoke_v1`, `status=passed`, and insufficient-balance `provider_attempt_rows=0`.

The orchestrator does not weaken the Gateway insufficient-balance/no-provider-call proof. Remaining gaps are non-Gateway release/Ops inputs and productization follow-ups: fill selected-user packet fields before handoff, keep public voucher route/productization as follow-up, and keep TODO-32J/TODO-32K payment/subscription external runtimes deferred for the scoped voucher-backed trusted-user Beta.

### E8-LAUNCH-14 / Gateway artifact manifest review（2026-06-06）

E8 reviewed the Gateway artifacts that must be retained in the trusted-user handoff evidence manifest. No live smoke was required because the current artifacts had not regressed. The manifest/handoff metadata must preserve these Gateway acceptance fields:

- `.tmp/launch/e8_gateway_paid_hot_path_launch_check.json`: `schema=gateway_paid_hot_path_smoke_v1`, `status=passed`, and insufficient-balance `provider_attempt_rows=0`.
- `.tmp/launch/gateway_voucher_distribution_readiness.json`: `schema=gateway_voucher_distribution_readiness_v1`, `status=pass`, `gateway_verdict=current_running_gateway_live_paid_check_passed_for_voucher_backed_distribution`, and `paid_hot_path_verified.current_launch_live_verified=true`.
- `.tmp/launch/trusted_user_api_distribution_handoff_summary.selftest.json`: `overall_status=ready_to_send_trusted_user_beta`, `release_check_overall_status=warn`, `secret_scan_passed=true`, and `blockers=[]`.
- `.tmp/launch/trusted_user_api_distribution_handoff_summary.json`: default run remains blocked only by missing real selected-user fields, with `blockers=[]`, `release_check_overall_status=warn`, and `secret_scan_passed=true`.

If future manifest/hash work drops any of the Gateway paid proof, readiness pass, release-check warning, or secret-scan pass fields, reopen E8 for a manifest/script defect review. Remaining gaps are non-Gateway: selected-user packet values, public voucher route/productization, and TODO-32J/TODO-32K external payment/subscription runtimes.

### E8-LAUNCH-15 / Current evidence_manifest Gateway rereview（2026-06-06）

E8 reread the current handoff summary `evidence_manifest` after the orchestrator rerun. Gateway manifest entries are present and preserve the current launch evidence:

- In both `.tmp/launch/trusted_user_api_distribution_handoff_summary.json` and `.tmp/launch/trusted_user_api_distribution_handoff_summary.selftest.json`, manifest entry `e8_gateway_paid_hot_path_launch_check` exists, points to `.tmp/launch/e8_gateway_paid_hot_path_launch_check.json`, has `schema=gateway_paid_hot_path_smoke_v1`, `status=passed`, `blockers_count=0`, and SHA256 `279ae8e5ca4d3c1c56474a46dfbaff42916aa7958a385a91a1767007e5ab57a9`.
- In both summaries, manifest entry `gateway_voucher_distribution_readiness` exists, points to `.tmp/launch/gateway_voucher_distribution_readiness.json`, has `schema=gateway_voucher_distribution_readiness_v1`, `status=pass`, `blockers_count=0`, and SHA256 `6ac7ec35b5f78f73e7962ca96b70d29cbcc0e9785e12a208754648e8f627ff2e`.
- Source artifact `.tmp/launch/e8_gateway_paid_hot_path_launch_check.json` still has `status=passed` and insufficient-balance `provider_attempt_rows=0`.

The current route partial blocker belongs to the public voucher route/productization lane, not Gateway paid hot-path evidence, and does not weaken the Gateway insufficient-balance/no-provider-call proof.

### E8-LAUNCH-16 / Gateway manifest regression guard scoping（2026-06-06）

E8 scoped the future regression guard for preserving Gateway evidence in `evidence_manifest`. Current manifest/source artifacts still satisfy the intended criteria:

- Manifest entry `e8_gateway_paid_hot_path_launch_check` must exist in the handoff summary, include a SHA256 hash, point to `.tmp/launch/e8_gateway_paid_hot_path_launch_check.json`, and report `status=passed`.
- Manifest entry `gateway_voucher_distribution_readiness` must exist in the handoff summary, include a SHA256 hash, point to `.tmp/launch/gateway_voucher_distribution_readiness.json`, and report `status=pass`.
- Source artifact `.tmp/launch/e8_gateway_paid_hot_path_launch_check.json` must continue proving insufficient-balance `provider_attempt_rows=0`.

Recommended guard location: the QA/orchestrator manifest verifier or selftest, because it owns manifest completeness and hash/status preservation across the handoff packet. E8 smoke should remain the source-proof producer for reserve/settle/refund and insufficient-balance no-provider-call behavior; duplicating manifest assertions inside the E8 smoke script would couple source proof generation to release-packet manifest packaging.

### E8-LAUNCH-17 / Evidence_manifest verifier Gateway criteria review（2026-06-06）

E8's first verifier lookup happened before the main-thread script landed. Main-thread correction: `scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1` now exists and passes `-SelfTest`, the default handoff summary, and the filled selftest summary. Current generated summaries still preserve Gateway evidence:

- `.tmp/launch/trusted_user_api_distribution_handoff_summary.json` has manifest schema `trusted_user_api_distribution_evidence_manifest.v1`, 13 entries, and Gateway entries:
  - `e8_gateway_paid_hot_path_launch_check=passed` with SHA256 `279ae8e5ca4d3c1c56474a46dfbaff42916aa7958a385a91a1767007e5ab57a9`.
  - `gateway_voucher_distribution_readiness=pass` with SHA256 `6ac7ec35b5f78f73e7962ca96b70d29cbcc0e9785e12a208754648e8f627ff2e`.
- Source artifact `.tmp/launch/e8_gateway_paid_hot_path_launch_check.json` remains `status=passed` and independently proves insufficient-balance `provider_attempt_rows=0`.

Verdict: current generated manifest is acceptable for Gateway evidence, and the standalone manifest verifier now guards manifest schema, required entries, repo-bounded paths, SHA256, metadata-only fields, and secret-like values. E8 smoke remains the source behavior proof and should not own release manifest completeness; the source paid artifact still independently confirms insufficient-balance `provider_attempt_rows=0`.

### E8-LAUNCH-18 / Manifest verifier Gateway gap audit（2026-06-06）

E8 inspected `scripts/verify_trusted_user_api_distribution_evidence_manifest.ps1` after the standalone verifier landed. The verifier is correctly scoped as a handoff manifest integrity guard: it requires `e8_gateway_paid_hot_path_launch_check` and `gateway_voucher_distribution_readiness`, enforces repo-bounded `.tmp`/`artifacts` paths, positive byte counts for existing artifacts, lowercase SHA256 hashes, a metadata-only field allowlist, and secret-like value rejection.

Recommendation: do not add Gateway source semantic checks such as insufficient-balance `provider_attempt_rows=0` to this manifest verifier. That behavior belongs to the E8 paid hot-path smoke/source artifact and its readback checks, because it is a Gateway runtime invariant rather than release-packet metadata integrity. Release review should compose both gates: run the manifest verifier for required artifact/hash/status preservation, and consume the E8 source artifact or E8 smoke verifier for no-provider-call proof.

Remaining risk: the manifest verifier can prove the Gateway evidence files are present and hashed, but it intentionally does not re-parse their bodies. A final release checklist must keep the source artifact check in scope when validating Gateway paid behavior. Public route productization, TODO-32J payment/order/invoice runtime, and TODO-32K subscription/package runtime remain non-Gateway/deferred gaps for this launch lane.

---

# PHASE 4：Production RC closure

以下不阻塞 Beta，但必须保留为 RC TODO。

## TODO-40：E8 production tokenizer/read-model backend runner

- 真实 tokenizer/read-model 服务或持久 read-model backend。
- opt-in env gate。
- live Gateway smoke command。
- token evidence -> reservation DB readback。
- 不能读取/泄露 raw prompt。

## TODO-41：E15 ClickHouse Log Store production smoke

- same-session ClickHouse env/live opt-in。
- real smoke artifact。
- final closure audit readback。
- writer/readback counts、cursor/WAL/dedup/load-retention/fresh/non-simulated/secret-safe。

## TODO-42：Staging / Helm / load / chaos / security gate

- Helm staging deploy。
- backup/restore staging 演练。
- 1,000 concurrent stream load smoke。
- provider 5xx/429/EOF/slow first byte/client cancel chaos。
- SBOM、image scan、dependency scan、secret scan。
- production readiness review。

---

# 附录 A：Agent 通用交付报告模板

每个 Agent 最终必须返回以下结构，不得只说“已完成”：

```json
{
  "task_id": "TODO-xx",
  "lane": "E11|E13|E8|E9|QA|DOC|RC",
  "status": "pass|blocked|fail",
  "commit": "<short sha>",
  "changed_files": ["path"],
  "commands_run": [
    {"command": "...", "exit_code": 0, "classification": "pass|blocked|fail"}
  ],
  "artifacts_written": [
    {"path": "...", "schema": "...", "secret_safe": true, "fresh": true, "simulation": false}
  ],
  "acceptance_results": {
    "runtime_current_verified": true,
    "readback_passed": true,
    "secret_safe_scan": "pass"
  },
  "blockers": [],
  "remaining_risks": [],
  "next_task": "..."
}
```

---

# 附录 B：主线程 Review 规则

主线程只能按以下规则勾选 `[x]`：

1. Agent 报告必须列出实际命令和 exit code。
2. artifact 必须 fresh、repo-bounded、secret-safe、non-simulated。
3. 代码改动必须在写入范围内。
4. 至少一个行为测试或 live smoke 证明用户路径，不接受纯源码字符串断言作为唯一证据。
5. 文档状态必须同步。
6. 对 Beta 不需要的 production closure，只能标为 `RC backlog`，不能占用 Beta pass/fail。
