# Fubox API TODO 实现清单

> 2026-06-12 更新：当前执行入口已切换到 [`TODO/CODE_FIRST_DESIGN_TODO_2026-06-12.md`](../TODO/CODE_FIRST_DESIGN_TODO_2026-06-12.md)。本文件保留为近期状态参考，不再作为 Agent 派发或生产验证 blocker 来源。文中“前端暂停”仅指不要继续在旧大页面上做无边界 polish；新的 code-first 设计/界面实现已重新进入 P0。

更新日期：2026-06-12

参考源：
- AxonHub：`references/axonhub`，当前提交 `a88c652a`，仅作为后续前端重做的信息架构/风格参考。
- Sub2API：`references/sub2api`，当前提交 `e34ad2b1`，重点借鉴用户充值、订阅、通道监控、账号/通道分离。
- New API：`references/new-api`，当前提交 `6f415428`，重点借鉴渠道 CRUD、模型同步、用量日志、钱包/配额信息架构。

## 已完成

- 本地开发脚本：`scripts/dev_up.ps1`、`scripts/dev_login_check.ps1`。
- 管理员账号：`admin@example.com / local-password`。
- 网关本地测试 Key：`dev_test_key_123456789`。
- 中文 UI 第一轮：登录、导航、Dashboard、用户门户、Providers、Provider Keys、Models、Routing、Request Logs、Audit Logs、Billing、Virtual Keys、Distribution Readiness。旧大页面暂停无边界 polish；新的 code-first 设计/界面实现以根目录 `TODO/CODE_FIRST_DESIGN_TODO_2026-06-12.md` 为准，重做资料统一放在 `docs/frontend/`。
- 用户门户 MVP：注册、登录、余额、兑换码、用户 API Key、模型列表、API Console、用量聚合、请求日志、CSV 导出。
- Provider Key 管理：创建、恢复探针、轮换；secret 只在提交表单中出现，不在响应或页面回显。
- Request Log payload preview：`GET /admin/request-logs/{id}/payload` 已补齐，当前只返回 metadata-only 安全预览，不返回原始 payload。
- Voucher 管理：单个发券、批量发券、列表、筛选、撤销、CSV/JSON 导出；响应只回 redacted code，不回原始券码或幂等键。
- 导入工具：
  - New API dry-run：`scripts/importers/import-newapi-dryrun.ps1`
  - One API dry-run：`scripts/importers/import-oneapi-dryrun.ps1`
  - Sub2API dry-run：`scripts/importers/import-sub2api-dryrun.ps1`
  - Sub2API handoff/apply-plan：`scripts/importers/import-sub2api-apply-plan.ps1`
  - Sub2API 身份/计费计划：`scripts/importers/import-sub2api-identity-billing-plan.ps1`
  - internal mapping/apply-plan bridge：`scripts/importers/import-internal-mapping-report.ps1`、`scripts/importers/import-apply-plan.ps1`
- 导入向导 UI：可本地解析 dry-run、handoff、internal mapping、apply-plan artifact；展示 counts、可迁移/不可迁移、provider-key sidecar、rollback/idempotency；不上传、不调后端、不展示原始 JSON。
- Billing ledger adjustment/runtime writer 前端 readback：`ledger_adjustment_execution_readback` 已接到 dry_run、execute_contract/refused、execute applied/idempotent 响应和 Admin UI，展示 ref presence、idempotency fingerprint、blocked reasons、safe next action；未做生产验证，且禁止 raw SQL、wallet secret、Authorization、provider key、raw metadata/idempotency。
- 用户控制台上游错误脱敏：provider key、Authorization、prompt、payload、messages 等敏感内容不再显示到页面。

## 当前验证

- `node web/admin-ui/node_modules/typescript/bin/tsc -b --pretty false` 通过。
- `node web/admin-ui/node_modules/vitest/vitest.mjs run src/App.test.tsx` 通过，81/81。
- `cargo test -p ai-control-plane request_log -- --nocapture` 通过，8/8。
- `cargo test -p ai-control-plane rbac_matrix_contract_fixture_matches_control_plane_policy -- --nocapture` 通过。
- `cargo check -p ai-control-plane` 已通过；仍有既有 warning。
- `scripts/importers/verify-sub2api-identity-billing-plan-contract.ps1` 通过。
- Docker/live smoke 未完成：当前阻塞在 Docker build 阶段 Debian apt 源 `502 Bad Gateway`，以及本机 C 盘/TEMP 空间不足风险。

## P0：必须实现

### 1. 可启动闭环

- [ ] 网络恢复后重跑 `scripts/dev_up.ps1` + `scripts/dev_login_check.ps1` 完整 live smoke。
- [x] `scripts/dev_login_check.ps1` 已支持稳定 artifact 输出，默认 `.tmp/dev_login_check_artifact.json`，失败路径也会写脱敏证据文件。
- [ ] 网络/运行环境恢复后重跑 `scripts/dev_login_check.ps1`，生成 pass artifact，证明管理员登录、用户注册、兑换、创建 Key、`/v1/models`、mock chat、request detail ledger readback 全链路。
- [x] 清理 C 盘/TEMP 依赖，`dev_up.ps1` / `dev_login_check.ps1` 默认使用项目内 `.tmp`、`.tool-cache/npm`、`target-codex`，README 已说明覆盖方式。

### 2. 前端暂停与归档

- [ ] 停止在旧大页面上继续堆无边界 UI polish；除安全漏洞和测试阻塞外，旧 `BillingPage`、`UserPortalPanel`、`ImportWizardPage` 只做必要修复，新增设计实现优先落到 `src/app`、`src/design`、`src/features/<domain>`。
- [x] 前端重做计划和 AxonHub 风格笔记已移入 `docs/frontend/`，不再占用主 TODO 篇幅。
- [ ] 后续前端设计实现以 [UI_REBUILD_PLAN_2026-06-12.md](./frontend/UI_REBUILD_PLAN_2026-06-12.md) 为参考，但执行优先级和验收口径以根目录 code-first TODO 为准。
- [ ] 后端 API、错误码、DTO 和文档服务于当前设计/界面工作流；前后端以功能闭环为优先。

### 3. 管理端主线

- [ ] 供应商管理：新增、编辑、禁用、删除。
- [ ] 通道管理：新增、编辑、复制、测试、禁用。
- [ ] 模型管理：canonical model、上游模型映射、用户可见模型。
- [ ] 路由策略：按模型、项目、通道、权重、健康状态选择。
- [ ] 请求追踪详情：一条请求能看到 key、模型、通道、成本、错误、trace；原始 payload 不进默认 MVP。
- [x] Provider Key recovery 接真实上游探针第一切片：worker `recovery-probe --execute` 已改为 execute-only 读取密钥材料、解密 provider key，并对 OpenAI-compatible 通道调用上游 `/v1/models`；成功恢复 `enabled`，失败保持 `cooldown/recovery_probe`。dry-run 仍不读取 secret。mock-provider 已支持 `MOCK_PROVIDER_REQUIRE_MODELS_AUTH=1` 验证 Bearer Authorization。
- [ ] Provider Key recovery 后续：补调度/CronJob、live artifact、更多协议探针、探针结果持久化和 operator-only probe log。

### 4. 网关兼容层

- [ ] OpenAI Chat Completions 完整兼容。
- [ ] `/v1/models` 严格返回当前用户可见模型。
- [ ] 流式响应稳定处理：断流、首 token、finish reason、usage。
- [ ] Provider 错误归一化并脱敏。
- [ ] 支持 Anthropic/Gemini/Claude-compatible 的最小适配矩阵。
- [x] 支持 key 级并发限制第一切片：Gateway 鉴权后读取 `virtual_keys.rate_limit_policy`，non-stream Chat Completions 在 provider route/upstream 前原子 acquire virtual-key concurrency slot，超限返回 429 且不创建 provider attempt；成功/错误/fallback 最终路径释放 slot。新增 `rate_limit_current_window_state` JSON 状态字段。
- [ ] key 级限流后续：接入 streaming finalizer release、RPM/TPM minute window、统一 key/provider rate-limit metadata、更多 endpoints。

## P1：尽快做

### 5. 计费、额度、支付

- [ ] 统一额度单位：余额、voucher、订单、ledger、request cost 使用同一口径。
- [ ] 模型价格表：input/output/cache/reasoning tokens 分开计价。
- [ ] 价格版本管理：旧请求按旧价格结算。
- [ ] 管理员手工加减额度。
- [ ] Voucher 批次持久化：决定新增 `voucher_issuance_batches` 表，或给 voucher rows 写 `batch_idempotency_key_hash`。
- [ ] 模拟支付订单 runtime verifier：在可用 Postgres/Docker 环境跑 `PAYMENT_ORDER_INVOICE_DB_OPT_IN=1`，生成 `.tmp/credit-wallet/payment_order_invoice_runtime.json`。
- [ ] 订阅套餐框架：月包、额度包、过期、暂停、续费。

### 6. 健康监控与自动恢复

- [ ] 通道健康探测定时任务。
- [ ] 按模型维度记录可用率、延迟、错误码。
- [ ] Dashboard 显示健康矩阵、失败 TopN、通道趋势。
- [ ] 自动禁用先做“建议 + 手动确认”，不要直接照搬 New API 的激进自动禁用。
- [ ] 恢复探针成功后允许人工恢复，后续再评估自动恢复。
- [ ] Provider Key recovery 不能长期停留在 `upstream_probe.executed=false`；worker `recovery-probe --execute` 需要接真实 mockable HTTP probe，并验证成功/失败状态迁移和 secret-safe audit。

### 7. 导入迁移

- [x] Sub2API 身份/计费迁移计划：`import-sub2api-identity-billing-plan.ps1` 已把 users、user keys、subscriptions、balances 收束成 plan-only artifact；用户 key 只给 reissue handoff，余额只给 opening-balance plan，订阅仍需人工 package mapping，不自动写库。
- [ ] Sub2API 身份/计费 apply-live：必须先设计用户 create/link、wallet lookup、opening balance ledger import、用户 key 重发、订阅套餐映射的 reviewed apply。
- [ ] New API 导入 apply-plan：渠道、模型、分组、倍率、用户 key。
- [ ] One API 导入 apply-plan：渠道、token、分组。
- [ ] 导入 apply-live runtime：必须有 dry-run、diff、rollback/idempotency、secret-safe artifact 后才允许执行。
- [ ] Provider key 永远不从报告明文写入，只走 fingerprint、alias、operator sidecar 和人工录入。

## P2：后做

- [ ] 首次安装 Setup Wizard。
- [ ] 空状态引导：先接供应商、再建模型、再发 Key。
- [ ] 管理端命令菜单。
- [ ] 表格固定列、列显隐、批量操作。
- [ ] 移动端基础适配。
- [ ] 用户协议、隐私政策、邮箱验证、密码重置。
- [ ] 登录频率限制、关键操作二次确认。
- [ ] API Key 泄露检测和批量吊销。
- [ ] IP allowlist / trusted proxy 配置 UI。

## 借鉴清单

### AxonHub

- UI 以功能面板和高密度信息为主，减少大段解释文案。
- 管理界面要更像工作台：表格、筛选、状态、操作清晰，不做营销页式布局。
- 视觉上避免过重渐变和花哨卡片，优先做稳定、可扫描的后台体验。

### Sub2API

- 用户充值、兑换码、订阅套餐、推广/返利的业务边界值得借鉴。
- 通道监控独立页值得借鉴：通道、模型、延迟、错误、可用率分开看。
- 账号/通道/监控分层清楚，适合我们重构管理端信息架构。
- 用户 key 细粒度限制值得借鉴：允许模型、禁止模型、额度、过期、启停。

### New API

- 渠道 CRUD、批量测试、余额更新、模型抓取成熟，可以借鉴管理端操作流。
- masked key 和“一次性显示 secret”的安全交互值得保留。
- 钱包、用量日志、模型列表的信息架构适合用户门户。
- 模型映射和上游模型同步入口可以作为后续模型管理主线。

## 明确不做

- 不直接搬 Sub2API/New API 代码。
- 不输出或持久化明文 provider key。
- 不先接真实支付商户，先把模拟支付和 ledger 闭环跑通。
- 不继续堆大而全证明脚本，优先保留能证明用户闭环的 smoke。
- 不做复杂多租户销售后台，先把单租户本地闭环和分发主线做顺。
