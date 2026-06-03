# Rust 实施基线

版本：0.1-dev-start  
日期：2026-06-02

## 1. 目标

本项目选择 Rust 不是为了“换语言”，而是为了把 Data Plane 的单机上限、内存占用、streaming 稳定性和尾延迟做上去。P0/P1 默认后端统一 Rust，避免双栈带来的性能与维护分裂。

## 2. 默认技术组合

| 层 | 默认选型 | 备注 |
|---|---|---|
| Toolchain | Rust stable + Edition 2024 | 避免 nightly 依赖进入生产 |
| Async Runtime | Tokio | 统一任务调度、超时、取消、backpressure |
| HTTP Server | Axum + Hyper + Tower | 数据面和控制面共用中间件抽象 |
| HTTP Client | Reqwest/Hyper | 统一出站连接池、超时、重试前语义 |
| TLS | rustls | 统一跨平台行为，避免系统 TLS 差异 |
| Serialization | serde / serde_json | 协议兼容和配置序列化 |
| Buffer/Stream | bytes / futures / http-body-util | 优先复用 buffer，避免大块复制 |
| DB | SQLx + PostgreSQL | P0 优先显式 SQL、事务和迁移控制 |
| Redis | redis-rs | 限流、缓存、health、pub/sub |
| Observability | tracing + OpenTelemetry + Prometheus | span、metrics、structured logs |
| Error Model | thiserror + typed error enums | 热路径避免混乱字符串错误 |
| Config | serde + schema validation | 配置必须可校验、可 dry-run |

## 3. Workspace 建议

```text
ai-gateway/
  Cargo.toml
  apps/
    gateway/
    control-plane/
    worker/
  crates/
    app-core/
    adapters/
    auth/
    billing-ledger/
    config/
    gateway-protocol/
    observability/
    routing/
    security/
    shared/
    stream/
  web/admin-ui/
  db/migrations/
  tests/
  xtask/
```

说明：

- `apps/gateway` 只负责组装 Data Plane，禁止塞入账务和后台查询逻辑。
- `crates/stream` 负责统一 SSE/Responses/Anthropic/Gemini 流式解析。
- `crates/adapters` 只处理 provider 差异，不得污染核心路由。
- `xtask/` 用于本地开发、代码生成、fixture 校验、发布流程封装。

## 4. 平台策略

- 生产平台只承诺 Linux 容器目标：`x86_64-unknown-linux-gnu`、`aarch64-unknown-linux-gnu`。
- 本地开发允许 Windows/macOS/Linux。
- CI 应按目标平台分别构建，不依赖单一 runner 强行交叉打所有生产包。
- 非必要不引入平台绑定库；P0 禁止把 OpenSSL、系统证书接口、平台特有 socket 行为写死到主路径。

## 5. 性能约束

- 所有热路径队列必须有界。
- 不允许在 async 热路径执行阻塞文件 I/O、阻塞 DNS、阻塞数据库访问。
- 出站请求必须有连接池、超时、body 大小上限和 chunk 上限。
- streaming parser 必须记录 `partial_sent`、`terminal event`、`stream_end_reason`。
- 默认优先 `Bytes`、borrowed slice、增量解析，避免整包反序列化。
- 配置、价格、模型和路由策略应进入 Redis + 本地缓存，避免请求时慢 SQL。
- 账务、trace、审计事件异步化，但必须幂等且可恢复。

## 6. 开发与发布门槛

每个 PR 至少通过：

1. `cargo fmt --all -- --check`
2. `cargo clippy --workspace --all-targets --all-features -- -D warnings`
3. `cargo test --workspace --all-features`
4. Postgres/Redis/mock provider 集成测试
5. `web/admin-ui` typecheck/test/build
6. secret scan / dependency scan

Release Candidate 额外要求：

1. Linux x86_64 与 Linux arm64 镜像都能构建。
2. 1,000 并发 stream 下内存稳定，无线性异常增长。
3. Chaos/load 报告归档，且能解释 tail latency 变化来源。

## 7. 不建议的做法

- 不要为了“多平台方便”切回 `native-tls`。
- 不要在 P0 先引入重型 ORM，再试图靠调参抹平热路径开销。
- 不要把 control-plane 的低频复杂查询和 gateway 热路径放在同一个 crate 中耦合。
- 不要使用无界 channel、全量原始 payload 持久化、默认全量 chunk 采样。
