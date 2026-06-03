# fubox-API 项目进度报告

日期：2026-06-03  
仓库：404F0X/fubox-API  
当前阶段：P0 主干功能已形成可验证闭环，仍处于 staging RC 前收口阶段。

## 最近两轮收口

上一轮按外部审查先修高风险项，未继续扩展新功能：

- Gateway 请求体限制已前置到 Axum `DefaultBodyLimit`，不再等 `Bytes` extractor 读完整 body 后才检查大小。
- Gateway 上游 timeout、stream idle timeout 和最大 provider attempts 已接入 `routing.default_timeout_seconds`、`routing.stream_idle_timeout_seconds`、`routing.default_max_attempts`，移除关键硬编码路径。
- OpenAI-compatible 和 native passthrough HTTP client 已关闭 redirect，降低 provider key 被 30x 跳转带走的风险。
- Provider/Channel endpoint 新增统一校验：默认要求 HTTPS，拒绝 userinfo、query/fragment、localhost、private/link-local/multicast/unspecified IP 和 metadata IP；Gateway 出站前会在打开 provider key 前做静态 URL 复核和 DNS 解析 IP forbidden-range 复查，OpenAI-compatible 与 native/streaming 路径共用该 guard；本地 Compose/Helm mock 场景需显式 `AI_GATEWAY_ALLOW_UNSAFE_PROVIDER_ENDPOINTS=true`。
- Gateway CORS 从 permissive 改为 `AI_GATEWAY_CORS_ALLOWED_ORIGINS` allowlist；Control Plane 继续使用已有 allowlist。
- Gateway/Control Plane `readyz` 响应已收窄，不再暴露 database driver、Redis 地址、upstream base URL 或数据库错误原文。
- `AI_GATEWAY_ENV=production` 且未设置 `AI_GATEWAY_CONFIG` 时会启动失败，避免生产误读相对路径示例配置。
- Virtual Key create/disable/expire 已改为业务写入与 audit 同一 DB transaction；provider key 与 price version 事务化 audit 保持原有闭环。

本轮 5 个子 Agent 并行后由主线程 review 合并，重点补 P0 可追踪、安全和账务切片：

- Gateway `/v1/chat/completions` prompt protection 已覆盖 `stream=true`，在 canonical routing、request log started、pre_authorize、provider_attempt、provider key 解密和上游调用前拒绝恶意输入；拒绝日志仅写请求 hash 和 bounded hit summary。
- `ai-gateway-observability` prompt protection hit summary 已加上 64 条上限，并保留 late prompt-injection reject signal，避免恶意 payload 放大日志或去重成本。
- Gateway `route_decision_snapshot` 运行态新增 `summary`，稳定暴露 selected channel/provider model、候选数量、过滤原因、score 和 trace affinity status，方便 Request Detail 直接追踪路由决策。
- Provider create/update/delete 已进入业务写入与 success audit 同一 DB transaction；audit snapshot 只记录安全 metadata keys，不落 secret-like key 名和值。
- Billing ledger 新增 runtime usage extraction API/fixture，可从 OpenAI/Responses、Anthropic、Gemini usage JSON 提取 input/output/cache/reasoning token 并避免 cache/reasoning 双计费；部分非流式 Gateway rating helper 已接入，request log 明细字段仍待接入。
- Admin UI Audit Logs 增加 `created_from`/`created_to` 时间过滤，并走已有后端 RFC3339/limit 校验。

本轮追加派发后继续收口：

- Channel create/update/delete 已进入业务写入与 success audit 同一 DB transaction，channel audit snapshot 不再记录 endpoint/base_url 原文。
- Trace affinity 增加 DB previous-success lookup contract 和最小 repository 方法，按 tenant + trace_id + TTL 查最近成功 channel/provider/model 摘要，尚未接 Gateway selection 前 lookup。
- Gateway 非流式 chat/responses/embeddings/Anthropic Messages 的 rating helper 已在 provider JSON usage totals 与 adapter totals 对齐时使用 cache/reasoning 拆分后的 `ExtendedTokenUsage` 计价；streaming/Gemini native 和 request log 明细持久化仍待接入。
- Request/Trace 页面 Route Trace 改为只展示 `route_decision_snapshot.summary` 稳定字段，避免解析或渲染 raw snapshot。
- Prompt protection 新增 `prompt_protection_rules_v1` 可配置规则纯函数/contract，支持 bounded literal/contains mask/reject 与 text/json path scope；regex 仍显式未启用，Gateway runtime 未接入。

## 本地验证

本轮已通过：

- `cargo fmt --all -- --check`
- `cargo check --workspace`
- `cargo clippy --workspace --all-targets --all-features -- -D warnings`
- `cargo test --workspace --all-targets --all-features`
- `npm test -- --run src/api/client.test.ts src/App.test.tsx`
- `npm run build`
- `npm run check:bundle`（Initial JS 240.6 KiB / 250.0 KiB）
- `cargo test -p ai-gateway-config -p ai-gateway --lib -p ai-control-plane --bin ai-control-plane`
- `cargo test -p ai-gateway --bin ai-gateway`
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test.ps1`
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\scan_secrets.ps1`
- `python deploy\helm\validate_chart.py --skip-helm --self-test`
- `git diff --check`

## 里程碑进度

| 里程碑 | 状态 | 说明 |
|---|---|---|
| M0 工程骨架 | 完成 | Monorepo、CI、本地 Compose、配置 schema、mock provider 已具备；本轮补了生产配置路径保护。 |
| M1 基础转发 | 基本完成 | OpenAI chat non-stream/stream 可用；Responses/Embeddings/Anthropic/Gemini 已有最小 runtime；live strict smoke 仍依赖 Docker/环境。 |
| M2 模型和渠道 | 进行中偏后段 | Profile、模型可见性、model association、channel mapping runtime 已有核心切片；本轮补 provider endpoint SSRF guard。 |
| M3 路由和流式稳定 | 进行中 | Retry/fallback、stream finalizer、terminal validation、TTFT、usage settle 已有核心路径；已接入配置化 attempts/timeout/stream idle timeout、运行态 route decision summary 和 trace affinity DB lookup contract。 |
| M4 账务和观测 | 进行中 | Price/preauth/settle/ledger summary/reconciliation/metrics 已有切片；runtime usage extraction 已能拆 cache/reasoning token，部分非流式 Gateway rating helper 已接入；reserve/refund runtime、强一致余额和 scheduler 待补。 |
| M5 管理后台 | 进行中 | 登录、导航/RBAC、Provider/Channel、Models、Virtual Keys、Request/Trace、Health、Billing 页面均有 MVP；Audit Logs 已支持时间过滤。 |
| M6 迁移和验收 | 进行中 | New API/One API parser、mapping、dry-run、SQL apply/rollback plan 已有；真实 DB apply/rollback runner 未完成。 |
| M7 Staging RC | 未完成 | 本地/CI dry-run 较充分；staging、K8s、live Docker smoke、load/chaos/security checklist 尚未完成。 |

## Epic 总览

- E0 工程化：已完成；配置 schema 已补生产环境显式 config 要求。
- E1 身份/RBAC/审计：登录、session、RBAC、audit read/write 多数切片完成；provider、channel、provider_key、price_version、virtual_key 关键写路径已进入事务化 audit；OIDC 仍是安全草案/plan-only。
- E2 Virtual Key/Profile：核心 key 创建、鉴权、profile header、key/profile IP allowlist 已完成或接近完成；预算和细粒度权限工作流仍待完善。
- E3 Provider/Channel/Key Pool：CRUD、密钥加密、runtime key 注入、状态写回、recovery dry-run/API/UI、health summary 已有；本轮补 endpoint static + DNS SSRF guard，且 guard 发生在 provider key 打开前；真实 probe、轮换、同 channel 多 key retry 待补。
- E4 Model Catalog/Association：canonical model CRUD、default price selector、association dry-run/UI、channel mapping runtime 已有；复杂候选、live smoke 和价格配置 UI 待补。
- E5 Data Plane：OpenAI chat/responses/embeddings、Anthropic messages、Gemini native generate/stream 已有核心 runtime；协议细节和 live matrix 待补。
- E6 Adapter：OpenAI/Anthropic/Gemini/MCP fixtures 与 conformance harness 已接 CI/wrapper；更深 trait replay 和真实网络 smoke 待补。
- E7 Streaming Engine：SSE parser、partial/no-late-fallback/end reason/backpressure/usage settle 已有核心实现；本轮接入 stream idle timeout；usage estimated 和 live cancel/backpressure matrix 待补。
- E8 Routing/Fallback/Health：routing core、priority/weight、health/rate-limit 纯函数、fallback engine、运行态 route decision summary、trace affinity previous-success DB lookup contract 已有；已接入 configured max attempts；Gateway DB 候选生成、rate counters、trace affinity runtime 接入待补。
- E9 Billing Ledger：钱包/预算模型完成，price/preauth/settle/reconciliation、runtime usage extraction 和部分非流式 Gateway cache/reasoning rating 接入已有；reserve/refund writer、余额强一致、并发防超卖、Gateway cache/reasoning usage 持久化和 scheduler 待补。
- E10 Observability：request/provider logs、trace summary、payload policy、metrics、alert webhook dry-run、OTEL config 已有；本轮收窄 readiness 输出；真实 exporter/webhook sender 和 payload object store 待补。
- E11 Admin UI：主要工作区均已 MVP 接入并保持 bundle budget；Audit Logs 已有时间过滤，Request/Trace 已展示 route summary 稳定字段；高级字段编辑、完整审计体验、payload 懒加载、实时图表待补。
- E12 Migration Importer：parser/mapping/dry-run/SQL apply plan/rollback plan 已有；真实 PostgreSQL apply 与 rollback runner 待补。
- E13 Security/Compliance：secret masking、payload redaction、provider encryption、offline supply-chain artifacts、chat prompt protection non-stream/stream preflight 和 configurable rule-set pure contract 已有；近期补 body-limit 前置、CORS allowlist、endpoint static + DNS SSRF guard、redirect 禁用、readiness 脱敏和 bounded hit summary；联网漏洞/镜像扫描、digest pinning、跨协议 prompt protection 与 configurable rules runtime 接入待补。
- E14 Deploy/Ops：Docker/Compose、本地 release gate、Helm static validation、backup/restore scripts、runbook 已有；staging/K8s/live restore 演练未完成。
- E15 P1/P2：request override 展示、exact cache billing、Coding Agent Profiles、ClickHouse plan、MCP/Prompt Eval/Shadow 等已有部分 pure/plan-only 切片；真实 runtime 多数未开始。

## 当前主要风险

- Live/staging 验收不足：Docker strict smoke、K8s staging、恢复演练、load/chaos/security release checklist 仍需具备工具和环境后补跑。
- 多个能力仍是 plan-only 或 pure function：OIDC exchange/JWKS、trace affinity Gateway runtime 接入、prompt protection configurable rules runtime 接入、billing DB scheduler、importer apply/rollback、ClickHouse writer、alert webhook sender 还未做真实 I/O。
- 路由运行态仍缺 rate-limit counter/concurrency、Gateway DB 候选生成、trace affinity runtime 调用和同 channel retry。
- Billing 仍缺 reserve/refund writer、余额强一致和并发防超卖。
- Audit 仍有 profile/model/model association 等写路径是业务写入后补 audit；已优先修 provider、channel、provider_key、price_version、virtual_key。
