# AI Gateway ToD / Technical Debt 清单（必须纳入开发流）

生成日期：2026-06-05  
口径：ToD = Technical Debt + Operational Debt + Definition-of-Done Debt。  
原则：ToD 不抢当前 API 分发主线的第一优先级；每个 ToD 必须有 owner、触发条件、验收方式，否则会继续拖慢后续开发。2026-06-07 公司资金约束下已切换为单人 CTO/Codex 模式；下文 `Agent-*` owner 仅保留为历史能力域标签，实际执行由 Solo Dev Queue 按优先级串行处理。当前主线是 code-first Open-source Alpha / API distribution 稳定，不是重开旧 paid/global blocker。

2026-06-07 当前事实：本机 Gateway、Control Plane、Admin UI、Postgres、Redis、mock-provider 已启动；`scripts/verify_open_source_alpha_gate.ps1 -RunMatrix`、route-level live proof、provider-key runtime smoke、importer live apply/rollback 和 secret scan 已通过。Provider key live strict smoke 已不再是当前 API 分发 blocker；剩余同 channel 多 key 轮换、密钥查看审计完整 readback 和 master key rotation runbook 归入 P1 security hardening。

权威源规则：`TODO/` 是权威入口，`docs/P0_BETA_STATUS.md` 是摘要视图，`docs/TODO.md` 不得重新成为 TODO 真相源。

---

## ToD-00：巨型 Rust 文件拆分

**Priority**：P0 after API distribution / P1 hardening  
**Owner**：Agent-Refactor-Rust

### 当前事实

- `apps/control-plane/src/admin.rs` 约 28,628 行。
- `apps/gateway/src/main.rs` 约 19,191 行。
- `apps/gateway/src/tpm_estimate.rs` 约 12,789 行。
- `apps/worker/src/clickhouse_log_store.rs` 约 3,575 行。
- `crates/observability/src/clickhouse_log_store.rs` 约 2,061 行。

### 风险

- Agent 修改容易冲突。
- Review 成本极高。
- 源码字符串断言测试锁死重构。
- 编译错误定位和逻辑回归越来越困难。

### 拆分目标

#### Control Plane

将 `admin.rs` 拆为：

```text
apps/control-plane/src/admin/
  mod.rs
  auth_handlers.rs
  provider_handlers.rs
  channel_handlers.rs
  model_handlers.rs
  billing_handlers.rs
  ledger_handlers.rs
  request_trace_handlers.rs
  audit_handlers.rs
  health_handlers.rs
  prompt_protection_handlers.rs
  import_handlers.rs
  response_types.rs
  extractors.rs
```

#### Gateway

将 `main.rs` 拆为：

```text
apps/gateway/src/
  main.rs
  state.rs
  auth_flow.rs
  model_profile.rs
  route_flow.rs
  provider_call.rs
  openai_handlers.rs
  responses_handlers.rs
  anthropic_handlers.rs
  gemini_handlers.rs
  stream_flow.rs
  billing_flow.rs
  audit_flow.rs
  request_log_flow.rs
```

#### TPM / tokenizer

将 `tpm_estimate.rs` 拆为：

```text
apps/gateway/src/tpm_estimate/
  mod.rs
  fallback.rs
  trusted_backend.rs
  read_model_backend.rs
  evidence.rs
  contract.rs
  fixtures.rs
```

### 验收标准

- 单次 PR 只拆一个大文件的一个 domain，不做行为变更。
- public API 不变。
- 行为测试全部通过。
- 删除或降低 `include_str!("main.rs")` 这类 brittle test 的比例。
- 每次拆分必须附带 before/after 文件行数。

---

## ToD-01：源码字符串断言测试债

**Priority**：P0 after API distribution  
**Owner**：Agent-Test-Architecture

### 问题

当前部分测试通过读取源码字符串来断言实现片段。这类测试能防止少量误删，但无法证明行为正确，还会阻碍重构。

### 改造规则

- 保留少量 security guard，例如禁止输出 secrets 的静态扫描。
- 对业务行为，改成 contract fixture、unit test、integration smoke、DB readback。
- 对 Admin UI，改成 component test 或 browser smoke。
- 对 scripts，保留 self-test exit semantics，但不把 self-test 当 live proof。

### 验收标准

- 每移除一个源码字符串断言，必须增加一个行为测试。
- 行为测试名称必须体现用户路径：`reject_prompt_does_not_call_provider`、`ledger_settle_is_idempotent` 等。

---

## ToD-02：Evidence 脚本膨胀债

**Priority**：P0 after API distribution / P1  
**Owner**：Agent-Release-Tooling

### 问题

E8/E9/E11/E13/E15 各自都在维护复杂 artifact gate、watcher、handoff、classification 逻辑，重复且容易自相矛盾。

### 目标

建立统一 release evidence schema：

```json
{
  "schema": "ai_gateway_evidence_v1",
  "task_id": "...",
  "run_id": "...",
  "commit": "...",
  "created_at_utc": "...",
  "mode": "contract|live|production",
  "fresh": true,
  "secret_safe": true,
  "simulation": false,
  "runtime_current_verified": true,
  "readback": {"passed": true},
  "blockers": [],
  "results": {}
}
```

### 验收标准

- 新增 `scripts/release_evidence.ps1` 或共享 PowerShell module。
- 旧脚本逐步调用统一 writer/readback/secret-safe 函数。
- 不再每个 lane 自己发明 `fresh/current/simulated` 语义。

---

## ToD-03：Admin UI 依赖与测试可复现债

**Priority**：P0 distribution blocker only if handoff/Admin UI tests fail  
**Owner**：Agent-Frontend-Build

### 当前事实

当前环境中 `npm --prefix web/admin-ui test` 因 `node_modules/.bin/vitest` 权限问题失败：`vitest: Permission denied`。这说明随包的 `node_modules` 不是可信可复现依赖状态。

### 规则

- 不提交 `node_modules`。
- 不用 zip 中的 node_modules 作为验收依据。
- CI 必须执行 `npm ci`。
- Playwright/vitest 依赖由 lockfile 重建。

### 验收标准

- `.gitignore` 明确忽略 `web/admin-ui/node_modules`。
- CI 中 `npm ci`、`npm test`、`npm run build`、`npm run check:bundle` 通过。
- 本地 artifact 只保留测试输出，不保留依赖目录。

---

## ToD-04：CI 可信度债

**Priority**：P0 distribution gate hardening  
**Owner**：Agent-CI

### 当前问题

早期 working tree 曾显示 `.github/workflows/ci.yml` 删除；当前同步确认 workflow 文件存在。Board 中 E0-002 已调整为 `NeedsReverify`，剩余债务是完整 CI / full wrapper gate 尚未重跑，不能标为完全 Done。

### 验收标准

CI 至少包含：

1. Rust fmt/check/clippy/test。
2. PowerShell smoke contract scripts。
3. Adapter conformance。
4. Admin UI `npm ci/test/build/bundle`。
5. Secret scan。
6. Supply-chain scan/SBOM 至少 contract mode。
7. Docker/Compose dry-run 或 smoke。

---

## ToD-05：文档状态冲突债

**Priority**：P0 distribution documentation gate  
**Owner**：Agent-PM

### 问题

`docs/TODO.md`、`PROJECT_PROGRESS_REPORT.md`、`project/PROJECT_BOARD.csv`、`project/ACCEPTANCE_CHECKLIST.md` 容易重新分叉成独立真相源。

### 目标

- `TODO/` 作为权威入口，`docs/P0_BETA_STATUS.md` 作为当前状态摘要视图。
- `docs/TODO.md` 只能作为索引/转向页，不能重新承载权威 TODO。
- 其它文件只引用或同步 `TODO/` 与 `docs/P0_BETA_STATUS.md`，不得重新建立独立真相。
- Acceptance checklist 不得全空。

### 验收标准

- 每个 checklist item 有 `checked/unchecked`、owner、evidence path、blocker。
- Board 的 `Done` 必须可被当前 CI 或 artifact 支撑。

---

## ToD-06：账务强一致设计债

**Priority**：Paid hardening / Production RC blocker, not current API distribution blocker  
**Owner**：Agent-Billing-Architecture

### 风险

Controlled paid beta evidence 已被 main review 接受，但这不等于 full Production RC。当前 API 分发主线可走 voucher/redeem-code quota + virtual key；更深的账务强一致仍是 paid hardening / RC 债务。

### 必须补齐

- ledger unique key：`request_id + action + idempotency_key`。
- wallet/budget lock 顺序。
- reserve/settle/refund transaction boundary。
- crash recovery event outbox。
- reconciliation worker。
- dashboard 只读 ledger aggregate，不做真相。

### 验收标准

- 并发超卖测试。
- 重复 settle/refund 测试。
- worker crash/restart 测试。
- price_version 历史不变测试。

---

## ToD-07：Provider key 与 secret 生命周期债

**Priority**：P0/P1 security  
**Owner**：Agent-Security

### 必须补齐

- provider key 查看/轮换/禁用/恢复全有 audit。
- master key rotation runbook。
- provider key 解密只发生在 Data Plane 必要位置。
- logs/trace/artifacts 全路径 secret scan。
- dev seed master key 明确只能 local 使用。

### 验收标准

- provider key live strict smoke。
- audit row readback。
- secret scan 能检测误提交。

---

## ToD-08：Observability active vs placeholder 债

**Priority**：P1 / Beta hardening  
**Owner**：Agent-Observability

### 问题

部分 Grafana/Prometheus panels 是 placeholder，不能作为告警依据。

### 规则

- Dashboard panel 必须标 `active` 或 `placeholder`。
- placeholder 不允许 page。
- 新 metric 必须有 label cardinality review。

### 验收标准

- `/metrics` 暴露的 series 与 dashboard active panels 一致。
- alert rule 不引用 pending metric。

---

## ToD-09：Importer apply/rollback 债

**Priority**：P1 / Migration Beta  
**Owner**：Agent-Migration

### 当前状态

New API/One API parser、mapping、dry-run、SQL apply plan/rollback plan 已有；真实 DB apply/rollback runner 已扩展覆盖 `provider`、`channel`、`canonical_model`、已绑定 `channel_mapping_entry` 与已绑定 explicit-channel `model_association`，并新增 unbound source channel 自动创建 provider/channel 和 blocking conflict no-write refusal 证据；证据为 `.tmp/importers/import_apply_live_runtime_verification.json` `status=pass` / `rollback_verified=true`，其中 `provider_channel_unbound` 确认 `provider_key_material_allowed=false`、apply 后 provider/channel/channel mapping 存在、rollback 后移除，`conflict_blocked_no_write_refusal` 为预期拒绝且 `database_writes=false`。剩余债务是完整样本/密钥/审计覆盖面不足，不再是完全没有 live runner。

### 必须补齐

- 导入权限默认收紧。
- opening ledger entry 体现余额。
- 无法映射项进入人工确认。
- provider key secret-management path 的 live apply/rollback。
- apply 幂等扩大到完整 New API/One API sample。
- rollback 可重复执行扩大到完整 New API/One API sample。

### 验收标准

- 样例 New API 导入 dry-run 报告。
- staging DB apply + rollback live smoke 覆盖完整 New API/One API sample；当前 Compose focused smoke 已覆盖 unbound provider/channel creation、canonical model、bound channel mapping entry、bound explicit-channel model association 与 blocking conflict no-write refusal。
- 导入后 API key 权限不扩大。

---

## ToD-10：Release / staging / backup restore 债

**Priority**：Production RC blocker  
**Owner**：Agent-Ops

### 必须补齐

- Helm staging deploy。
- Postgres backup/restore staging 演练。
- Redis/event bus degraded behavior。
- object storage unavailable behavior。
- provider chaos matrix。
- load smoke：non-stream、stream、large chunk、client cancel。

### 验收标准

- `project/RELEASE_CHECKLIST.md` 全部 RC 项有 artifact。
- staging restore report pass。
- load/chaos/security reports pass。

---

## ToD 优先级总表

| ID | 标题 | 阻塞哪个里程碑 | 先后顺序 |
|---|---|---|---:|
| ToD-04 | CI 可信度 | Beta | 1 |
| ToD-05 | 文档状态冲突 | Beta | 2 |
| ToD-03 | Admin UI 依赖可复现 | Beta UI gate | 3 |
| ToD-06 | 账务强一致 | Paid Beta | 4 |
| ToD-00 | 巨型 Rust 文件拆分 | Hardening/RC | 5 |
| ToD-01 | 测试债 | Hardening/RC | 6 |
| ToD-02 | Evidence 脚本统一 | Hardening/RC | 7 |
| ToD-07 | Secret 生命周期 | Beta/RC | 8 |
| ToD-08 | Observability placeholder | P1/RC | 9 |
| ToD-09 | Importer apply/rollback | Migration Beta | 10 |
| ToD-10 | Staging/Ops | Production RC | 11 |
