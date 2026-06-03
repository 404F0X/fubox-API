# fubox-API Project Progress Report

日期：2026-06-03  
仓库：404F0X/fubox-API  
当前阶段：P0 主干功能已形成可验证闭环，仍处于 staging RC 前的收口阶段。

## 本轮收尾状态

本轮已停止继续开发，当前改动仅做审查修复、验证、报告和推送收口。

本轮新增/收口的主要能力：

- 管理员登录失败限速新增显式 Redis/分布式 Redis 后端，默认仍为单进程内存 store；Redis 后端使用 fingerprint-only key、原子失败计数和成功清理，Redis 不可用时 fail-closed。
- API Key Profile 独立 `ip_allowlist` 已从 schema/API/Gateway/UI 接入，旧 `request_overrides` 兼容保留。
- Provider health summary 增加窗口成功率；Provider Key manual recovery API/UI 已接入安全状态边界和事务化 audit。
- OpenAI Responses、Anthropic Messages、Gemini GenerateContent streaming runtime 最小切片已接入，覆盖 provider key 注入、pre-response fallback、terminal validation、usage/rating/settle 和 no-late-fallback finalizer。
- Request/Trace detail 已接入 bounded ledger summary；本轮审查后已收紧为只展示 request、entry/status、amount/currency 和时间摘要，不暴露 idempotency key、usage/policy snapshot、metadata、payload 或 wallet/key/price version 内部关联。
- Billing reconciliation Worker 增加 DB scheduler/read plan contract，仍为 plan-only，不连接或写入数据库。
- Importer apply plan 增加 rollback journal 与 rollback execution dry-run contract，仍不执行 live PostgreSQL mutation。
- Exact cache billing、ClickHouse log store WAL、prompt eval/shadow 等 P1/P2 能力已进入纯函数或 plan-only 合约阶段。

## 本地验证

本轮收口已通过：

- `cargo fmt --all --check`
- `cargo clippy -p ai-gateway -p ai-control-plane -p ai-worker -p ai-gateway-adapters --all-targets --all-features -- -D warnings`
- `cargo test --workspace --all-targets --all-features`
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test.ps1`
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\scan_secrets.ps1`
- Admin UI `typecheck`、`test -- --run`、`build`、`check:bundle`
- Importer apply-plan contract verification
- Worker billing reconciliation dry-run fixture
- `TODO.md` 与 `docs/TODO.md` 镜像一致性检查
- `git diff --check`

当前 Admin UI bundle：Initial JS 240.6 KiB / 250.0 KiB，Total JS 326.6 KiB，预算通过。

## 里程碑进度

| 里程碑 | 状态 | 说明 |
|---|---|---|
| M0 工程骨架 | 完成 | Monorepo、CI、本地 Compose、配置 schema、mock provider 已具备。 |
| M1 基础转发 | 基本完成 | OpenAI chat non-stream/stream 可用，provider key runtime 与基础 SDK/smoke dry-run 已覆盖；live strict provider key smoke 仍依赖 Docker/环境。 |
| M2 模型和渠道 | 进行中偏后段 | Profile、模型可见性、model association、channel mapping runtime 已有核心切片；DB 候选生成、rate window 和 live smoke 仍待补齐。 |
| M3 路由和流式稳定 | 进行中 | Retry/fallback、stream finalizer、terminal validation、TTFT、usage settle 已形成核心路径；同 channel retry、backoff、完整 live streaming matrix 仍待完成。 |
| M4 账务和观测 | 进行中 | Price version、pre-authorize、settle、ledger summary、reconciliation report、metrics 已有可测切片；reserve/refund runtime、强一致余额和 scheduler 仍待实现。 |
| M5 管理后台 | 进行中 | 登录、导航/RBAC 裁剪、Provider/Channel、Models、Virtual Keys、Request/Trace、Health、Billing 页面均有 MVP；高级配置、完整 CRUD polish、payload 懒加载仍待完成。 |
| M6 迁移和验收 | 进行中 | New API/One API parser、internal mapping、dry-run、SQL apply/rollback plan 已有；真实 DB apply runner 和 rollback mutation runner 未完成。 |
| M7 Staging RC | 未完成 | 本地/CI dry-run 充分，staging、K8s、live Docker smoke、load/chaos/security release checklist 尚未完成。 |

## Epic 总览

- E0 工程化：已完成。
- E1 身份/RBAC/审计：本地管理员登录、session、RBAC、audit read/write 多数切片完成；OIDC 仍是安全草案/plan-only，Redis auth/TLS/pool 和 audit UI/更多事务化写路径待补。
- E2 Virtual Key/Profile：核心 key 创建、鉴权、profile header、key/profile IP allowlist 已完成或接近完成；预算/模型权限专用工作流仍待完善。
- E3 Provider/Channel/Key Pool：CRUD、密钥加密、runtime key 注入、状态写回、recovery dry-run/API/UI、health summary 已有；真实 probe、轮换、同 channel 多 key retry 待补。
- E4 Model Catalog/Association：canonical model CRUD、default price selector、association dry-run/UI、channel mapping runtime 已有；live smoke、复杂候选/fallback 和价格配置 UI 待补。
- E5 Data Plane：OpenAI chat/responses/embeddings、Anthropic messages、Gemini native generate/stream 已有核心 runtime；更完整协议 schema/tool semantics 和 live matrix 待补。
- E6 Adapter：OpenAI/Anthropic/Gemini/MCP fixtures 与 conformance harness 已接 CI/wrapper；更深 trait replay 和真实网络 smoke 待补。
- E7 Streaming Engine：SSE parser 完成，partial/no-late-fallback/end reason/backpressure/usage settle 已有核心实现；usage estimated 和 live cancel/backpressure matrix 待补。
- E8 Routing/Fallback/Health：routing core、priority/weight、health/rate-limit 纯函数、fallback engine 已有；Gateway DB 候选生成、rate counters、trace affinity DB 记忆待补。
- E9 Billing Ledger：钱包/预算模型完成，price/preauth/settle/reconciliation 已有；reserve/refund writer、余额强一致、并发防超卖和 scheduler 待补。
- E10 Observability：request/provider logs、trace summary、payload policy、metrics、alert webhook dry-run、OTEL config 已有；真实 exporter/webhook sender、payload object store、更多维度 metrics 待补。
- E11 Admin UI：主要工作区均已 MVP 接入并保持 bundle budget；高级字段编辑、完整审计体验、payload 懒加载、实时图表待补。
- E12 Migration Importer：parser/mapping/dry-run/SQL apply plan/rollback plan 已有；真实 PostgreSQL apply 与 rollback runner 待补。
- E13 Security/Compliance：secret masking、payload redaction、provider encryption、offline supply-chain artifacts、prompt protection non-stream preflight 已有；联网漏洞/镜像扫描、digest pinning、stream prompt protection 待补。
- E14 Deploy/Ops：Docker/Compose、本地 release gate、Helm static validation、backup/restore scripts、runbook 已有；staging/K8s/live restore 演练仍未完成。
- E15 P1/P2：request override 展示、exact cache billing、Coding Agent Profiles、ClickHouse plan、MCP/Prompt Eval/Shadow 等已有部分 pure/plan-only 切片；真实 runtime 多数未开始。

## 当前主要风险

- Live/staging 验收还不足：Docker strict smoke、K8s staging、恢复演练、load/chaos/security release checklist 仍需具备工具和环境后补跑。
- 多个能力仍是 plan-only 或 pure function：OIDC exchange/JWKS、billing DB scheduler、importer apply/rollback、ClickHouse writer、alert webhook sender 还未做真实 I/O。
- 路由运行态仍缺 rate-limit counter/concurrency、Gateway DB 候选生成、trace affinity DB 记忆和同 channel retry。
- Billing 仍缺 reserve/refund writer、余额强一致和并发防超卖。
- Payload full/sampled 策略仍缺对象存储和懒加载 API/UI。
