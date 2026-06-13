# Design Primitives Migration Handoff

更新日期：2026-06-12

## 完成口径

Design primitives migration 不再表示把旧 Admin UI 全量翻新一遍。当前结论是：

- 新前端和后续重做页面必须使用 `web/admin-ui/src/design` primitives 作为默认 UI 构件。
- 旧页面只保留兼容、安全和可运行修复；不再为了视觉统一做大规模迁移。
- 每个新迁移的页面或组件必须优先组合 `ActionButton`、`DataTable`、`EmptyState`、`Field`、`MetricTile`、`SectionHeader`、`StatusChip`、`Toolbar`，避免继续新增散落 DOM、一次性 class 和证明型主界面文案。
- 证明型 artifact、freshness、contract、raw JSON 只能进入 debug/audit 折叠区或 `docs/debug/handoff`，不能作为新页面主体验。

## 新页面检查项

迁移或重写页面时，至少检查：

1. 页面入口位于 `src/features/<domain>`，路由和权限 glue 位于 `src/app`。
2. 页面标题、工具栏、表格、状态、空状态、指标卡优先使用 `src/design`。
3. Secret、provider key、voucher raw code、Authorization、raw payload 和 idempotency key 不进入可见 UI。
4. 只有无法由现有 primitive 表达的布局才新增局部 class，并在后续设计系统补齐时回收。
5. 最小检查为 `npm run typecheck` 或等价的 `tsc -b --pretty false`。

## 最小示范

本 handoff 不做旧前端大迁移，仅补一个低风险示范：

- `web/admin-ui/src/components/FeaturePanel.tsx` 的统计卡片从散落 `<article className="metric-card ...">` 改为 `MetricTile`。
- `MetricTile` 的 `detail` 改为可选，兼容紧凑型旧组件，同时保留已有带说明指标卡的显示。

后续重做前端时，应把这个模式扩大到每个新迁移页面：先替换重复 DOM，再决定是否需要新的 primitive，而不是继续在页面内堆临时 class。
