# Admin UI 重构/重做计划

更新日期：2026-06-12

结论：当前 `web/admin-ui` 不适合继续小修小补。后续 UI 以 AxonHub 的后台工作台风格为主，允许大重构，必要时重做主界面；业务 API、secret-safe 规则、现有合同测试继续保留。

## 当前问题

- `App.tsx` 同时承担会话恢复、权限判断、导航配置、页面调度、健康刷新和 recovery action，职责过重。
- `styles.css` 是全局样式大锅，按钮、表格、卡片、表单、状态 chip 没有稳定 design primitives。
- 页面组件过大，尤其 Billing、UserPortal、ImportWizard，混合了数据请求、业务状态、表格渲染、错误处理和证明型文案。
- UI 上有太多“工程证明/contract/debug”文本，像验收报告，不像管理员工作台。
- 中文化是在旧结构上补丁式推进，导致中英文、协议字段、操作文案混在一起。
- 导航是按已有代码模块组织，不是按用户工作流组织。

## 重构原则

- 业务能力保留，UI 壳可以重做。
- 不直接搬 AxonHub 源码，只借鉴信息架构和后台风格。
- 先做高密度工作台，不做营销页、解释页、证明页。
- 默认屏幕给操作员可执行的信息：状态、表格、筛选、动作、错误原因、下一步。
- 证明型 artifact 和 raw JSON 默认折叠到“调试/审计”区域，不占主界面。
- API 字段、UUID、模型名、状态码可保留英文；按钮、表头、空状态、错误提示要中文。
- 所有 provider/gateway/upstream 错误必须走 secret-safe formatter。

## 目标信息架构

一级导航建议：

1. 仪表盘
2. 分发
3. 供应商与通道
4. 模型
5. API 密钥
6. 请求与追踪
7. 计费
8. 用户
9. 导入
10. 审计

用户门户单独作为“开发者控制台”，不要塞进管理员工作台的同一信息层级。

## UI Shell 目标

- 新建 `src/app`：应用入口、路由、会话恢复、权限 guard。
- 新建 `src/layouts`：AdminShell、UserConsoleShell、AuthShell。
- 新建 `src/design`：Button、IconButton、Field、Select、Table、StatusChip、MetricTile、Toolbar、EmptyState、Drawer、Modal。
- 新建 `src/features/<domain>`：按业务域放页面、hooks、view model、局部组件。
- 新建 `src/lib/safeText.ts`：统一错误脱敏、字段展示、状态翻译。
- `App.tsx` 只保留 provider/router glue，不再承载业务页面逻辑。

建议目标结构：

```text
web/admin-ui/src/
  app/
    AppRouter.tsx
    session.ts
    permissions.ts
  layouts/
    AdminShell.tsx
    AuthShell.tsx
    UserConsoleShell.tsx
  design/
    Button.tsx
    Field.tsx
    Table.tsx
    StatusChip.tsx
    Toolbar.tsx
    EmptyState.tsx
  features/
    dashboard/
    distribution/
    providers/
    models/
    api-keys/
    requests/
    billing/
    users/
    imports/
    audit/
  lib/
    safeText.ts
    format.ts
    cn.ts
```

## 第一阶段：停止继续堆旧 UI

- 不再继续大规模修补 `BillingPage.tsx`、`UserPortalPanel.tsx`、`ImportWizardPage.tsx` 的展示层，除非是安全漏洞或测试阻塞。
- 新功能优先补 API/client 和 feature view model，避免直接塞进旧大组件。
- 旧页面只保留可用性和 secret-safe 修复，不再追求视觉 polish。
- TODO 中把“中文 UI 收口”改成“UI 重构/重做”，中文化作为新设计系统的一部分完成。

## 第二阶段：先重做 Shell 和 Dashboard

交付：

- AdminShell：左侧分组导航、顶部标题/操作区、内容区布局。
- 统一 design primitives：按钮、输入、表格、chip、metric tile。
- Dashboard 第一屏：
  - 请求数
  - 成功率
  - token/成本概览
  - 通道健康 TopN
  - 最近失败请求
- 所有卡片、表格、按钮使用同一套组件。

验收：

- 不改变后端 API。
- `App.test.tsx` 中登录和 dashboard 主路径通过。
- Playwright 或截图检查至少覆盖 1440px 和 390px 宽度。

## 第三阶段：迁移核心工作流

迁移顺序：

1. 请求与追踪：筛选、状态、模型、通道、Key、延迟、错误、详情 drawer。
2. 供应商与通道：供应商、通道、密钥、健康探针放到同一工作流。
3. 模型：canonical model、上游映射、用户可见模型。
4. API 密钥：管理员 key 和用户 key 分清楚。
5. 计费：余额、voucher、ledger、价格版本、订单拆成 tabs，不再一页塞满。
6. 导入：保留 artifact 能力，但默认呈现为评审队列和差异表。
7. 用户控制台：独立开发者体验，聚焦 endpoint、key、余额、模型、usage、request detail。

## 第四阶段：删除旧壳

- 旧 `Navigation.tsx`、大块全局 CSS、证明型 UI 文案逐步删除。
- 大页面组件拆完后，`App.test.tsx` 按 feature 拆分，避免一个 90 秒大测试锁死重构。
- 保留 importer/backend 合同测试，不把 UI 测试当后端契约证明。

## 不做

- 不继续把 UI 当合同报告展示器。
- 不把 AxonHub 代码 vendored 进来。
- 不先做主题系统、暗色模式、复杂动画。
- 不为了保留现有测试文本而牺牲信息架构。
- 不把所有页面一次性推倒；按工作流迁移，保证每一步可运行。

## 下一步切片

优先做 `ui-shell-v2`：

- [x] 新增 AdminShell，先把旧页面通过兼容路由挂在新 shell 下。
- [x] 导航按工作流重新分组：工作区、运营、项目、治理。
- [x] 更新测试断言到新 shell 品牌和业务可达，不再锁死旧 `AI Gateway` shell 文案。
- [x] 新增第一组 design primitives：ActionButton、DataTable、MetricTile、SectionHeader。
- [x] Dashboard 首屏指标、section header、健康矩阵表格已开始使用 design primitives。
- [x] 补齐 Field、Toolbar、EmptyState，并接入 Dashboard 控制区、服务探针空状态和健康矩阵空状态。
- [x] 补齐 StatusChip，并替换 Dashboard 里的旧 StatusPill 依赖。
- [x] Dashboard 已迁移到 `features/dashboard/HealthDashboard.tsx`，开始脱离旧 `components` 目录。
- [x] Distribution Readiness 已迁移到 `features/distribution/DistributionReadinessPage.tsx`，并替换为 StatusChip。
- [x] Request Logs 已迁移到 `features/requests/RequestLogsPage.tsx`，筛选区、主列表、详情标题、账本表和 payload action 开始接入 ActionButton、Field、SectionHeader、DataTable。
- [x] Request Logs 的供应商尝试表已拆到 `features/requests/RequestProviderAttemptsPanel.tsx`。
- [x] Request Logs 的 payload preview 安全边界已拆到 `features/requests/RequestPayloadPreviewPanel.tsx`，保持显式点击后才请求 payload preview。
- [x] Request Logs 的 Trace 摘要、账本摘要、账本表和 ledger normalize 已拆到 `features/requests/RequestLedgerPanels.tsx`。
- [x] Providers 和 Provider Keys 已平移到 `features/providers`，先保持 secret-safe 逻辑和旧交互不变，后续再拆 helper/table/dialog。
- [x] Providers 的高级 JSON 安全策略、endpoint 脱敏和 model mapping options 已抽到 `features/providers/providerPolicyUtils.ts`，并新增单测。
- [x] Provider Keys 的列表表格已拆到 `features/providers/ProviderKeysTable.tsx`，secret-bearing create/edit/rotate dialogs 仍留在容器页。
- [x] Models 和 ModelAssociationDryRun 已平移到 `features/models`，Routing 页 dry-run 引用已切到新路径。
- [x] Virtual Keys 已平移到 `features/api-keys/VirtualKeysPage.tsx`，一次性 secret 展示和 JSON 脱敏逻辑保持不变。
- [x] Billing 已整页平移到 `features/billing/BillingPage.tsx`，账本 execute smoke selectors、voucher 脱敏和账务逻辑保持不变。
- [x] Audit Logs 已平移到 `features/audit/AuditLogsPage.tsx`，PromptProtectionSummary 和共享脱敏工具仍保留在 components 复用层。
- [ ] 逐步替换旧页面散落 DOM，并把更多页面迁入 `features/<domain>`。
- [ ] 旧页面逐步迁移，不再继续在旧大页面里做 UI polish。
