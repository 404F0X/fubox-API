# 开发流程、代码规范与协作机制

版本：0.1-dev-start  
日期：2026-06-01

## 1. 仓库建议结构

```text
ai-gateway/
  Cargo.toml
  Cargo.lock
  apps/
    gateway/
    control-plane/
    worker/
  crates/
    app-core/
    auth/
    billing-ledger/
    billing/
    config/
    gateway-protocol/
    routing/
    stream/
    adapters/
    observability/
    migration/
    security/
    shared/
  web/
    admin-ui/
  db/
    migrations/
    queries/
  deploy/
    docker-compose/
    helm/
  tests/
    fixtures/
    integration/
    e2e/
    load/
  xtask/
  docs/
```

## 2. 分支策略

- `main`：始终可发布。
- `develop`：可选，若团队规模较大。
- `feature/<epic>-<short-name>`。
- `release/<version>`。
- `hotfix/<issue>`。

## 3. PR 要求

每个 PR 必须包含：

- 任务 ID。
- 功能说明。
- 测试说明。
- 风险和回滚方式。
- 配置/DB migration 说明。
- UI 截图或 API 示例，若涉及。
- 文档更新。

## 4. Code Review Checklist

- 模块边界是否清晰。
- 是否在热路径引入慢查询。
- 错误是否使用 taxonomy。
- 是否写入 trace/log/audit。
- 权限是否后端校验。
- provider key/virtual key 是否安全处理。
- 账务是否幂等。
- stream 是否处理 client cancel。
- 是否有测试。
- 是否考虑迁移和回滚。

## 5. CI Pipeline

每个 PR：

1. format check。
2. lint。
3. unit tests。
4. adapter contract tests。
5. integration tests with Postgres/Redis/mock provider。
6. frontend typecheck/test。
7. secret scan。
8. dependency scan。
9. build container。

release branch 额外：

- e2e。
- load smoke。
- chaos smoke。
- SBOM。
- image scan。

## 6. Coding Standards

- 上下文必须支持 cancellation。
- 外部请求必须设置 timeout。
- 任何异步事件必须有 idempotency key。
- 统一使用 Tokio runtime；热路径禁止同步阻塞 I/O。
- 所有跨任务队列默认有界，禁止无上限 channel。
- streaming 相关缓冲必须设上限，优先 `Bytes` / slice 复用，避免大对象复制。
- 默认使用 `rustls`；P0 禁止热路径依赖系统 TLS/OpenSSL 绑定。
- 错误类型分层：协议错误、路由错误、上游错误、账务错误必须显式枚举。
- 金额和 token 统计不能用 float。
- 所有配置必须有 schema validation。
- 所有枚举值必须集中定义。
- 不允许吞掉 provider 原始错误；内部可脱敏保存。
- 禁止在日志中输出 Authorization、API key、Cookie。

## 7. Adapter 开发流程

1. 定义 provider capability matrix。
2. 准备 fixtures：chat、stream、tool、usage、error、large event。
3. 实现 request builder。
4. 实现 response parser。
5. 实现 stream parser event mapping。
6. 实现 error mapper。
7. 跑 conformance tests。
8. 加入 compatibility matrix。

## 8. 数据库 Migration 流程

- migration 必须进入版本控制。
- migration 脚本在空库和旧库都要测试。
- 账务表变更必须单独评审。
- 大表 backfill 必须可分批。
- 不允许 release 当天直接对大表做锁表操作。

## 9. 版本发布

版本格式建议：

- `0.1.0-alpha`：内部开发。
- `0.2.0-beta`：staging 和少量用户试用。
- `1.0.0-rc.1`：功能冻结，修 bug。
- `1.0.0`：生产首版。

## 10. 文档更新要求

涉及以下变更必须更新文档：

- 新增 provider 或协议。
- 修改路由行为。
- 修改账务规则。
- 修改错误码。
- 修改配置 schema。
- 修改部署变量。
- 修改权限模型。
