# Fubox API 新 TODO 路线图

更新日期：2026-06-11

参考源：
- AxonHub：`references/axonhub`，用于 UI 风格参考。
- Sub2API：`references/sub2api`，当前参考提交 `e34ad2b1`。
- New API：`references/new-api`，当前参考提交 `6f415428`。

当前已落地：
- 本地脚本：`scripts/dev_up.ps1`、`scripts/dev_login_check.ps1`。
- `scripts/dev_login_check.ps1` 已补强为用户闭环 smoke：管理员登录、用户注册、余额、管理员发测试券、用户兑换、用户创建 API Key、用用户 Key 调 `/v1/models` 和 mock chat，并用管理员详情接口硬验收该 request 的 confirmed settle ledger。
- Sub2API source dry-run importer：`scripts/importers/import-sub2api-dryrun.ps1` 已落地，样例在 `examples/importer_samples/sub2api_data.sample.json`，契约 fixture 在 `tests/fixtures/importers/sub2api_non_migratable.sample.json`。
- 管理员登录：`admin@example.com / local-password`。
- 网关测试 Key：`dev_test_key_123456789`。
- 前端中文入口：登录页、侧边栏、Dashboard、健康面板、用户门户主流程已收口一轮；Providers、Provider Keys、Models、Routing、Request Logs、Audit Logs、Billing、API Keys/VirtualKeys/Profile、Distribution Readiness 的关键标题/按钮/状态断言已同步到中文测试。
- Provider Key 管理端闭环：供应商密钥页已支持恢复探针和凭据轮换，轮换 secret 只在提交表单中出现，不在响应/页面回显。
- 请求追踪 payload 预览接口：`GET /admin/request-logs/{id}/payload` 已补齐，当前只返回安全元数据，不泄漏原始 payload。
- 批量 voucher 发放第一版：`POST /admin/voucher-issuance-batches` 已补齐，Admin UI 代金券页支持单个/批量切换；批量一次最多 100 条，复用单券事务，批内重复 code/幂等键拒绝该 item，响应只回 redacted code 和状态，不回原始券码或原始幂等键。RBAC 已纳入 `voucher.issue_batch` / `BillingAdjust`，OpenAPI skeleton 已补 batch request/response schema。
- Voucher 管理补强：`GET /admin/voucher-issuances` 已提供 secret-safe 列表，`POST /admin/voucher-issuances/{id}/revoke` 已支持 `issued -> revoked` 并写 audit；Admin UI 代金券页已接入列表、筛选、刷新、撤销、CSV/JSON 导出，不显示原始券码或原始幂等键。
- 导入向导 artifact 解析/评审第一版：Admin UI 的“导入向导”已支持粘贴或选择 dry-run/handoff JSON，在浏览器本地解析 importer、dry-run 状态、counts、可迁移项、不可迁移项、provider-key handoff、manual review 和 next steps，并提供差异筛选、handoff 确认和 apply 前 checklist；不调用后端、不上传文件、不展示原始 JSON。

当前验证：
- `npm --prefix web/admin-ui run typecheck` 通过。
- `node web/admin-ui/node_modules/vitest/vitest.mjs run web/admin-ui/src/App.test.tsx` 通过，81/81。
- `cargo check -p ai-control-plane` 通过，仍有既有 unused/dead_code warning。
- `cargo test -p ai-control-plane voucher_issue_batch_response_counts_items_and_stays_secret_safe -- --nocapture` 通过。
- `cargo test -p ai-control-plane billing_adjust_writes_require_billing_adjust -- --nocapture` 通过。
- `scripts/dev_login_check.ps1`、`scripts/dev_up.ps1` 语法解析通过；`dev_up.ps1 -DryRun` 在覆盖端口环境通过；当前机器完整 live 运行仍需实际启动 compose 验证。
- `scripts/verify_readme_quickstart_contract.ps1` 通过，README 当前检查口径已收敛到 `dev_up.ps1` + `dev_login_check.ps1` 的本地用户闭环。
- `scripts/importers/verify-import-source-dryrun-contract.ps1` 通过，覆盖 New API、One API、Sub2API 三类 source dry-run，并校验 secret-safe 输出。
- `scripts/importers/verify-sub2api-apply-plan-contract.ps1` 通过，覆盖 Sub2API source dry-run -> operator handoff plan，两阶段都不写库、不输出明文密钥。
- 支付订单/发票链路审计：0013 schema、contract fixture、内部 Rust/sqlx bounded simulation helper 与 `verify_payment_order_invoice_runtime.ps1` 已存在；当前缺 `.tmp/credit-wallet/payment_order_invoice_runtime.json` pass artifact，因此仍是 runtime false/deferred，不能标成真实支付闭环完成。
- 覆盖端口 live compose 已尝试；当前失败点不是端口，而是 Docker build 阶段 Debian apt 源 `502 Bad Gateway`。`deploy/docker-compose/Dockerfile` 已加入 apt retry，仍需网络恢复后重跑。

目标：把项目从“工程化证明很多”收回到“用户能注册、充值、拿 key、调用模型、看账单；管理员能接供应商、管通道、看健康、处理问题”的主线。

## P0 必须做完

### 1. 本地可启动闭环

- [x] 固化本地启动脚本：一条命令启动 Postgres、Redis、control-plane、gateway、mock-provider、admin-ui。2026-06-11：已通过 `scripts/dev_up.ps1` 落地。
- [x] 解决端口冲突策略：默认端口被占用时输出明确提示，或提供端口覆盖。2026-06-11：`POSTGRES_HOST_PORT`、`REDIS_HOST_PORT`、`GATEWAY_HOST_PORT`、`CONTROL_PLANE_HOST_PORT`、`ADMIN_UI_HOST_PORT`、`MOCK_PROVIDER_HOST_PORT` 已支持；带覆盖端口的 `dev_up.ps1 -DryRun` 已通过。
- [x] seed 完整化到本地用户闭环：管理员、默认租户、默认项目、mock provider、mock channel、mock model、管理员发测试 voucher、测试用户路径全部可用。2026-06-11：`dev_up.ps1` 的 repair 会重放 0002/0011/0012 与 dev seeds，覆盖旧 compose volume 缺 voucher 表的问题；仍需在空闲端口机器跑完整 live smoke。
- [x] 写一个 `scripts/dev_up.ps1`，隐藏现在手动设置 `AI_GATEWAY_CONFIG`、DB/Redis 端口、control-plane 启动的复杂度。2026-06-11：最小闭环已落地，包装 compose 启动 Postgres、Redis、mock-provider、gateway、control-plane、admin-ui，预检端口并可重放幂等 dev seeds。
- [x] 写一个 `scripts/dev_login_check.ps1`，验证 `/admin/auth/login`、`/auth/register`、`/v1/models`、chat mock 调用。2026-06-11：已补强为用户闭环检查，覆盖 healthz/readyz、Admin UI 可达、管理员登录、用户注册、用户余额、管理员发测试 voucher、用户兑换、用户创建 API Key、用用户 Key 调 gateway models 与 mock chat，并检查该请求在 admin request detail 中有 confirmed negative USD settle ledger。
- [x] 把 `dev_up.ps1 -DryRun` 纳入 README/CI 轻量检查，避免端口和 env 说明再次漂移。2026-06-11：README 已列出 DryRun；`verify_readme_quickstart_contract.ps1` 已校验两命令闭环、端口覆盖变量和默认本地 endpoints。

验收：
- 新机器 clone 后，按 README 2 条命令能打开中文 Admin UI 并登录。
- `admin@example.com / local-password` 可用。
- 用户能自注册、兑换测试 voucher、生成 API Key，并用自己的 Key 调 `/v1/models` 和 chat mock。

### 2. 中文 UI 版本

- [x] 管理登录页、用户登录页、侧边栏、Dashboard 已开始汉化，需要收口。2026-06-11：入口、导航、Dashboard/Health/UserPortal 主壳已转中文，`StatusPill` 改为中文显示；用户门户余额、Key、API Console、模型、用量、请求详情和错误提示完成一轮中文化。
- [x] 所有主页面标题汉化：供应商、供应商密钥、模型、路由、计费、请求追踪、审计日志、API 密钥、分发就绪。
- [ ] 表格列名、按钮、空状态、错误提示汉化。2026-06-11：Providers、Provider Keys、Models、Routing、Request Logs、Audit Logs、Billing、API Keys/VirtualKeys/Profile、Distribution Readiness 和 UserPortal 已完成一轮关键文案同步，仍需 Billing 深层协议摘要标签和少量 API/protocol 边界文案扫尾。
- [ ] 保留英文 API 字段、模型名、状态码，不翻译协议字段。
- [ ] 加最小 i18n 层，避免以后硬编码中文/英文散落。
- [ ] 继续收口页面内部英文：Billing 深层协议摘要标签和少量 API/protocol 边界文案。已完成一轮：`BillingPage`、`ProvidersPage`、`ProviderKeysPage`、`ModelsPage`、`RoutingPage`、`RequestLogsPage`、`AuditLogsPage`、`VirtualKeysPage`、`DistributionReadinessPage`。

验收：
- `npm --prefix web/admin-ui run typecheck` 通过。
- `npm --prefix web/admin-ui test -- --run App.test.tsx` 通过。
- 浏览器首屏、登录后 Dashboard、用户门户主路径无明显中英文混乱。

### 3. 用户门户 MVP

- [x] 用户注册 / 登录 / 退出。现有 `UserPortalPanel` 已有真实接口路径。
- [x] 余额展示。现有 UI 已接余额接口，但默认 seed/演示数据仍需补齐。
- [x] 兑换码充值。已有 redeem 入口，当前 MVP 口径是“管理员发 voucher，用户兑换”。
- [x] 创建、复制、禁用 API Key。已有用户 API Key 管理入口。
- [x] 可用模型列表。已有 models 列表和 callable 过滤。
- [x] 近 7/30 天使用量。2026-06-11：UserPortal 已提供 1/7/30/90 天窗口、聚合卡片、按模型/按 Key/失败摘要、请求日志、CSV 导出和中文空状态；仍需 live smoke 在 Docker 恢复后复跑。
- [x] 请求日志与失败原因。已有日志面板，E2E 需要把日志轮询设为硬验收。
- [x] 给用户一个 OpenAI-compatible 调用示例。2026-06-11：curl、OpenAI SDK 示例和 API Console 文案已按中文收口，真实 base URL 从当前 service base URL 生成。
- [x] 默认项目、profile、模型、通道、provider key 的 readiness gate：用户注册后必须能看到可调用模型，否则给明确修复指引。2026-06-11：`dev_login_check.ps1` 已断言 wallet/profile/model readiness 未阻塞，并轮询用户请求日志确认 mock chat 落日志；仍需 live 端口空闲环境复跑。
- [x] 本地 smoke 覆盖用户闭环。2026-06-11：`scripts/dev_login_check.ps1` 已覆盖用户注册、余额、voucher 兑换、用户 Key 创建、用户 Key 调 gateway、用户请求日志、管理员 request detail ledger readback；live 运行仍需 Docker build 网络恢复。

参考：
- Sub2API：`frontend/src/views/user/KeysView.vue`、`PaymentView.vue`、`RedeemView.vue`、`UsageView.vue`、`SubscriptionsView.vue`。
- New API：`web/default/src/routes/_authenticated/keys`、`wallet`、`usage-logs`、`models`。

### 4. 管理端核心闭环

- [ ] 供应商管理：新增、编辑、禁用、删除。
- [ ] 通道管理：新增、编辑、测试、禁用、复制。
- [x] Provider Key 管理：创建、轮换、健康状态、恢复探针。2026-06-11：后端 rotate/recovery 已接到 `ProviderKeysPage`，并补了前端回归测试；后续可加真实上游恢复探针。
- [ ] 模型管理：canonical model、上游模型映射、用户可见模型。
- [ ] 路由策略：按模型、项目、通道、权重、健康状态选择。
- [x] 请求追踪 payload 预览路由补齐。2026-06-11：`/admin/request-logs/{id}/payload` 已返回安全 metadata-only 响应。
- [ ] 请求追踪：一条请求能看到 key、模型、通道、成本、错误、trace。payload 原文是否可读需要单独权限和脱敏策略，不进入默认 MVP。

参考：
- Sub2API：账号/通道/监控分离做得清晰，重点看 `AccountsView.vue`、`ChannelsView.vue`、`ChannelMonitorView.vue`。
- New API：渠道 CRUD、批量测试、余额更新、模型抓取功能完整，重点看 `router/api-router.go` 的 `/channel` 路由。

### 5. 网关兼容层

- [ ] OpenAI Chat Completions 完整兼容。
- [ ] `/v1/models` 返回用户可见模型，而不是内部全部模型。
- [ ] 流式响应稳定：断流、首 token、finish reason、usage 处理。
- [ ] Provider 错误归一化。
- [ ] 支持 Anthropic/Gemini/Claude-compatible 的最小适配矩阵。
- [ ] 支持 key 级别 RPM/TPM/并发限制。

参考：
- Sub2API：`backend/internal/pkg/apicompat` 和多平台账号调度。
- New API：`router/relay-router.go`、`middleware/distributor.go`、`dto/openai_request.go`。

## P1 应该尽快做

### 6. 计费、额度、支付

- [ ] 统一额度单位：用户余额、voucher、订单、ledger、request cost 使用同一口径。
- [ ] 模型价格表：按 input/output/cache/reasoning tokens 拆。
- [ ] 价格版本管理：旧请求按旧价格结算。
- [ ] 管理员手工加减额度。
- [x] 兑换码批量发放第一版。2026-06-11：`POST /admin/voucher-issuance-batches` + Billing UI 批量模式已落地，secret-safe 响应，不新增 batch 表。
- [ ] 兑换码导出、禁用、批次查询。2026-06-12：secret-safe list、CSV/JSON 导出和 `issued -> revoked` revoke 已落地；批次查询需要先决定是给 voucher rows 写 `batch_idempotency_key_hash`，还是新增 `voucher_issuance_batches` 表，不能在当前无持久化 batch 语义下假装可查。
- [ ] 支付订单框架：先做模拟支付，再接真实支付。当前代码/schema/helper 已存在；下一步是在可用 Postgres/Docker 环境显式跑 `PAYMENT_ORDER_INVOICE_DB_OPT_IN=1` runtime verifier，生成并验收 `.tmp/credit-wallet/payment_order_invoice_runtime.json`，但不能宣称真实外部支付 provider 完成。
- [ ] 订阅套餐框架：月包、额度包、过期/暂停/续费。

参考：
- Sub2API 内置支付、订阅配额、推广返利更贴近“分发平台”。
- New API 的 subscription/admin、topup、quota log 结构可借鉴。
- 可直接借鉴 Sub2API 的支付订单生命周期：创建订单、provider callback、幂等履约、provider snapshot 留证；先做模拟支付，再接真实支付。
- 兑换码建议借鉴 Sub2API 的 code lifecycle：生成、使用次数、过期、禁用、余额入账。

### 7. 健康监控与自动恢复

- [ ] 通道健康探测定时任务。
- [ ] 按模型维度记录可用率、延迟、错误码。
- [ ] 自动禁用连续失败通道。
- [ ] 恢复探针成功后自动恢复。
- [ ] Dashboard 显示健康矩阵、失败 TopN、通道趋势。

参考：
- Sub2API：`ChannelMonitorView.vue`、`channel_monitor_repo.go` 的 rollup 思路。
- New API：自动测试通道、批量启停、响应时间阈值。
- 借鉴点：Sub2API 把“账号/通道/监控”分清楚，健康页给用户可见状态；New API 的批量测试适合管理端快速排障。
- 风险：不要照搬 New API 的激进自动禁用策略；先做只读建议和手动确认。

### 8. 导入迁移

- [ ] New API 导入：渠道、模型、分组、倍率、用户 key。
- [ ] One API 导入：渠道、token、分组。
- [x] Sub2API 导入 dry-run：账号、代理、组、绑定、用户、订阅、用户 key evidence。2026-06-11：`import-sub2api-dryrun.ps1` 已落地，只解析/归一/脱敏/计数，不落库。
- [x] 导入 dry-run 先展示差异，再应用。2026-06-11：New API、One API、Sub2API source dry-run 均纳入 `verify-import-source-dryrun-contract.ps1`；apply 仍只允许后续明确计划。
- [x] Sub2API operator handoff 第一版：account -> provider/channel/provider-key handoff。2026-06-11：`import-sub2api-apply-plan.ps1` 已落地，输入必须是 Sub2API source dry-run 输出，输出 provider/channel 计划和 provider-key operator sidecar，不写库、不携带 raw secret。
- [x] Sub2API provider/channel 接入 internal mapping/apply-plan。2026-06-12：`import-internal-mapping-report.ps1` 已支持读取 `sub2api-operator-handoff-plan-dryrun`，把 channel plans 转成通用 `channel_mappings`，再由 `import-apply-plan.ps1` 派生 provider/channel SQL plan；provider key 继续只作为 sidecar/operator handoff，不生成 provider key 写操作。
- [x] 密钥永不明文写入报告。2026-06-11：Sub2API source dry-run 与 handoff plan 均由合同脚本校验 secret-safe；provider key 只给 `POST /admin/provider-keys` 操作路径、hash/redacted locator 和人工录入指引。

已有基础：
- `scripts/importers/import-newapi-dryrun.ps1`
- `scripts/importers/import-oneapi-dryrun.ps1`

需要补：
- [x] UI 导入向导接 internal mapping/apply plan artifact 展示。2026-06-12：导入向导已能解析 `internal-mapping-report-dryrun` / `importer-apply-plan-dryrun`，展示 preflight、planned create/update/skip、source binding、rollback/idempotency 和 provider-key sidecar 摘要；仍然只在浏览器本地解析，不调用后端、不展示原始 JSON。
- Sub2API 身份/计费迁移：users、user keys、subscriptions、balances 仍只作为 evidence/manual review，不自动写库；需要单独设计钱包、ledger、用户 key 和订阅履约迁移计划。
- 导入安全规则：报告里永不输出明文 key，只输出 fingerprint、alias、可迁移/不可迁移原因。

## 参考项目可借鉴清单

### Sub2API 优先借鉴

- 用户 Key 细粒度控制：允许模型、限制模型、额度、过期、启停。
- Key 热路径缓存与 last_used 降写放大：不要每次请求都打数据库写更新时间。
- 支付订单生命周期：订单、回调、幂等、履约、provider snapshot。
- 兑换码、订阅套餐、配额窗口：适合我们的用户侧充值与套餐。
- 通道监控独立页：按通道/模型维度做 latency、error、availability rollup。

### New API 优先借鉴

- Token/Key 安全查看：只在创建时展示一次，后续只显示 masked key 和复制约束。
- 渠道 CRUD、批量测试、余额更新、模型抓取。
- 用户钱包、用量日志、模型列表的成熟信息架构。
- 模型映射和上游模型同步入口。

### 明确不照搬

- 不导出明文凭据。
- 不把支付 provider 复杂度一次性搬进来，先做模拟支付闭环。
- 不照搬 New API 的全局 option 大杂烩，保持配置边界清楚。
- 不默认激进自动禁用通道，先人工确认。
- 不先做复杂订阅预扣，先把余额、ledger、voucher 口径统一。

## P2 可以后做

### 9. 风控与合规

- [ ] 管理员首次使用合规确认。
- [ ] 用户协议 / 隐私政策页面。
- [ ] 注册开关、邮箱验证、密码重置。
- [ ] 登录频率限制、关键操作二次确认。
- [ ] API Key 泄露检测和批量吊销。
- [ ] IP allowlist / trusted proxy 配置 UI。

参考：
- Sub2API 有 admin compliance acknowledgement。
- New API 有 user agreement、Turnstile、Passkey、OAuth/OIDC 入口。

### 10. 产品体验

- [ ] 首次安装 Setup Wizard。
- [ ] 空状态引导：先接供应商、再建模型、再发 Key。
- [ ] 用户侧复制 curl / OpenAI SDK 示例。
- [ ] 管理端命令菜单。
- [ ] 表格支持固定列、列显隐、批量操作。
- [ ] 移动端基础适配。

参考：
- AxonHub：整体 UI 风格。
- New API：表格、命令菜单、布局组件。
- Sub2API：用户/管理员分区和支付体验。

## 暂不做

- [ ] 不先做复杂多租户销售后台。
- [ ] 不先做完整真实支付商户接入，先模拟支付闭环。
- [ ] 不继续堆大而全证明脚本，优先保留能证明用户闭环的 smoke。
- [ ] 不把 Sub2API/New API 代码直接搬进来，只借鉴功能边界和交互。

## 当前优先顺序

1. 网络恢复、Docker Desktop 恢复响应、C 盘释放空间后，重跑覆盖端口 `scripts/dev_up.ps1` + `scripts/dev_login_check.ps1` 完整 live smoke；上次已过端口预检，阻塞在 Docker build apt 源 502，当前机器还存在 C 盘/TEMP 0 空间问题。
2. 在 Docker/Postgres 可用后跑模拟支付订单 runtime verifier，生成 accepted `.tmp/credit-wallet/payment_order_invoice_runtime.json`；voucher 批次查询等 batch 持久化设计确定后再做。
3. 清理 Billing 深层协议摘要标签和少量 API/protocol 边界文案。2026-06-12 已收口用户门户高可见英文标签、代金券表头/结果字段；`Tenant ID/Wallet ID/Request ID` 等协议字段仍需统一别名解析后再全量中文化。
4. 用户门户后续只做 live smoke 复验和少量视觉细节，不再作为中文化主阻塞项。
5. 评估真实上游恢复探针，避免 Provider Key recovery 长期只是状态迁移。
