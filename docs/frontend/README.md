# Frontend Notes

本目录保存前端重做参考资料；当前执行入口以根目录 [`TODO/CODE_FIRST_DESIGN_TODO_2026-06-12.md`](../../TODO/CODE_FIRST_DESIGN_TODO_2026-06-12.md) 为准。

- `UI_REBUILD_PLAN_2026-06-12.md`：旧前端重构记录和后续重做参考。
- `DESIGN_PRIMITIVES_MIGRATION_HANDOFF.md`：design primitives 迁移完成口径、旧页面兼容边界和最小示范。
- `LEGACY_ADMIN_UI_HANDOFF.md`：旧 Admin shell、全局 CSS、证明型文案的兼容边界和迁移规则。
- `UI_STYLE_AXONHUB_NOTES.md`：AxonHub 风格观察笔记。
- `USER_PORTAL_STANDALONE_HANDOFF.md`：用户开发者控制台独立入口、文件边界和可消费 API 契约；新入口使用 `/?mode=developer-console`，兼容 `?mode=user`、`?mode=portal`、`?app=developer-console`、`?console=developer-console`、`/#/developer-console`、`/developer-console`、`/portal`。

当前设计实现口径：

1. 设计/界面工作重新进入 P0，但以代码和功能闭环为主，不再围绕生产证明推进。
2. 新 UI 优先做后台工作台：表格、筛选、状态 chip、drawer、批量动作、空状态、清晰下一步。
3. 旧页面只做安全和可运行修复；新增能力优先落到 `src/app`、`src/design`、`src/features/<domain>`。
4. 后端 API、DTO、错误码和 secret-safe 响应要服务于 UI 工作流，而不是服务于 release evidence。
5. 用户开发者控制台以 `/?mode=developer-console` 作为新的独立 app route handoff；`mode=user`、`mode=portal` 只作为兼容别名。
6. 新迁移页面必须默认使用 `src/design` primitives；旧页面不做全量视觉迁移，只保留兼容修复。
