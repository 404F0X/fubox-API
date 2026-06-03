# 风险清单与架构决策记录

版本：0.1-dev-start  
日期：2026-06-01

## 1. 高风险清单

| 风险 | 影响 | 缓解 |
|---|---|---|
| 协议转换丢字段 | Codex/Claude Code/工具调用失败 | Raw Layer + conformance tests + passthrough |
| Streaming 中途失败 | 客户端异常、重复输出、无法 fallback | partial_sent、terminal validation、stream_end_reason |
| 账务重复扣费 | 资金风险和信任损失 | idempotency key、ledger、对账 |
| 日志表过大 | 后台慢、数据库压力 | 分区、ClickHouse、对象存储、retention |
| Provider key 泄漏 | 安全事故 | 加密、mask、audit、secret scan |
| 配置错误 | 生产请求失败 | schema validation、dry-run、版本回滚 |
| Key 自动禁用不可恢复 | 可用性退化 | recovery_probe、cooldown、告警 |
| 过度功能膨胀 | P0 延期 | P0/P1/P2 边界严格执行 |
| AGPL/LGPL 许可证误用 | 法务风险 | clean-room、第三方 notices、法务审查 |

## 2. ADR-001：控制面和数据面分离

状态：Accepted。  
原因：后台配置、日志查询、迁移和账务都可能很重，不能影响请求热路径。

## 3. ADR-002：Ledger 是账务事实来源

状态：Accepted。  
原因：日志可清理、可采样、可迁移；账务必须长期可靠。

## 4. ADR-003：支持 Native Passthrough

状态：Accepted。  
原因：Responses、Claude、Gemini、MCP、Realtime 等协议复杂，强行转换容易丢字段。

## 5. ADR-004：P0 使用 PostgreSQL + Redis

状态：Accepted。  
原因：事务账务 + 缓存限流是最低生产要求。SQLite 仅 demo。

## 6. ADR-005：Adapter 必须契约测试

状态：Accepted。  
原因：provider 和客户端不断变化，人工测试不可持续。

## 7. 待决策

| 编号 | 问题 | 建议默认 |
|---|---|---|
| D-001 | 后端语言默认选型 | Rust，目标是极致优化、压低内存占用并稳定 streaming 尾延迟 |
| D-002 | Admin API REST 还是 GraphQL | REST 优先，GraphQL 若使用必须限制复杂查询 |
| D-003 | P0 是否引入 ClickHouse | 初期可不用，但表结构预留；高吞吐客户必须引入 |
| D-004 | 是否内置支付 | P0 不做，账务底座预留 |
| D-005 | 是否兼容 AxonHub 配置 | P1 评估 |
