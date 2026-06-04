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
- API key profile create/update/delete 已进入业务写入与 success audit 同一 DB transaction；profile audit snapshot 仅记录 model_aliases/trace_header_rules 安全 key 与 request_overrides/ip_allowlist 等 count 摘要，不落 Authorization、secret、payload/body 或 raw headers 原文。
- Canonical model create/update/delete 已进入业务写入与 success audit 同一 DB transaction；model audit snapshot 仅记录 capabilities 安全 key，并对 display/capability 值做 secret-like sanitizer。
- Model association create/update/delete 已进入业务写入与 success audit 同一 DB transaction；association audit snapshot 只记录 conditions 安全 key，并对 model_pattern/upstream_model_name 做 secret-like sanitizer。
- Gateway rate-limit-aware key selection 第一切片已接入：route candidate read-model bounded 读取 selected runtime key 的 rpm/tpm/concurrency limit 与窗口 used 摘要，超限或有限额缺 counter 会过滤为 `RateLimitExceeded`，snapshot 只写安全聚合 metadata。
- Routing rate-limit 新增 `rate_limit_reservation_contract_v1` 纯函数计划层，固定 RPM/TPM/concurrency acquire/release 的 bounded counter update、missing-window conservative reject、saturating/idempotent release 和 secret-safe numeric summary。
- Trace affinity 增加 DB previous-success lookup contract 和 Gateway runtime 接入：有 `x-ai-trace-id` 时在 selection 前 best-effort 查询最近成功 channel/provider/model 摘要，命中则传入 routing context 影响同 trace 后续选择；miss/error/skipped 不阻塞，snapshot 仅记录安全 metadata。
- Gateway 非流式 chat/responses/embeddings/Anthropic Messages 的 rating helper 已在 provider JSON usage totals 与 adapter totals 对齐时使用 cache/reasoning 拆分后的 `ExtendedTokenUsage` 计价；streaming/Gemini native 和 request log 明细持久化仍待接入。
- Request/Trace 页面 Route Trace 改为只展示 `route_decision_snapshot.summary` 稳定字段，避免解析或渲染 raw snapshot。
- Request/Trace 页面新增 payload preview lazy-load UI contract：request detail 默认不调用 payload endpoint，只有用户点击后才走 same-origin `GET /admin/request-logs/{id}/payload`；403/404 显示无权限/未实现状态，展示仅限 hash/redacted metadata 白名单并移除 Authorization、secret、token、cookie、provider key、raw headers/raw key。
- Health Dashboard 新增 `window_minutes`/`sample_limit` operator controls 与手动 refresh contract，Overview 会用所选窗口查询 `GET /admin/providers/health-summary`，并支持按 scope/search 扫描 provider/channel/key/model health rows；provider key recovery action 保持 capability-gated 且 secret-safe。
- Admin UI Provider/Channel 页面已补 provider metadata 与 channel model_mappings/tags/request_overrides/probe_policy/timeout_policy 高级 JSON create/patch 表单，输入拒绝 malformed/unsafe JSON，列表只显示 secret-safe 摘要。
- Prompt protection `prompt_protection_rules_v1` 可配置规则纯函数/contract 已支持 bounded literal/contains/regex/regex_like mask/reject 与 text/json path scope；regex 在 config parse 阶段编译并限制 pattern/program size、拒绝 empty-match，执行时仍按每字段扫描/替换上限处理；observability 纯函数 runtime config boundary 可合并 default rules + custom rules，支持 `enforce`/`audit`/`disabled` mode，summary/error 继续保持 raw payload/pattern/secret-safe；Gateway 已新增 `AI_GATEWAY_PROMPT_PROTECTION_CONFIG_JSON` 启动期 bounded JSON 配置入口并缓存 precompiled custom rules，chat preflight 不做 per-request regex/config compilation，未提供 JSON 时保持旧 mode 行为。

## 本地验证

本轮已通过：

- `cargo fmt --all -- --check`
- `cargo check --workspace`
- `cargo clippy --workspace --all-targets --all-features -- -D warnings`
- `cargo test --workspace --all-targets --all-features`
- `npm test -- --run src/api/client.test.ts src/App.test.tsx`
- `npm run build`
- `npm run check:bundle`（Initial JS 222.8 KiB / 250.0 KiB，Total JS 343.0 KiB）
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
| M3 路由和流式稳定 | 进行中 | Retry/fallback、stream finalizer、terminal validation、TTFT、usage settle 已有核心路径；已接入配置化 attempts/timeout/stream idle timeout、运行态 route decision summary、trace affinity Gateway best-effort runtime、rate-limit-aware key selection 第一切片和 routing rate-limit reservation contract。 |
| M4 账务和观测 | 进行中 | Price/preauth/settle/ledger summary/reconciliation/metrics 已有切片；runtime usage extraction 已能拆 cache/reasoning token，部分非流式 Gateway rating helper 已接入；billing-ledger 已补强一致 reserve/settle/refund writer 纯函数 contract、mockable command executor/in-memory execution contract 与 Postgres execution SQL planner contract，runtime reserve/refund Postgres writer、真实 DB 强一致扣减和 scheduler 待补。 |
| M5 管理后台 | 进行中 | 登录、导航/RBAC、Provider/Channel、Models、Virtual Keys、Request/Trace、Health、Billing 页面均有 MVP；Provider/Channel 已支持高级 JSON policy 字段编辑，Audit Logs 已支持时间过滤，Request/Trace 已有 payload preview lazy-load UI contract，Health Dashboard 已支持窗口/样本手动刷新与矩阵扫描。 |
| M6 迁移和验收 | 进行中 | New API/One API parser、mapping、dry-run、SQL apply/rollback plan 已有；真实 DB apply/rollback runner 未完成。 |
| M7 Staging RC | 未完成 | 本地/CI dry-run 较充分；staging、K8s、live Docker smoke、load/chaos/security checklist 尚未完成。 |

## Epic 总览

- E0 工程化：已完成；配置 schema 已补生产环境显式 config 要求。
- E1 身份/RBAC/审计：登录、session、RBAC、audit read/write 多数切片完成；provider、channel、api_key_profile、canonical model、model_association、provider_key、price_version、virtual_key 关键写路径已进入事务化 audit；OIDC 仍是安全草案/plan-only。
- E2 Virtual Key/Profile：核心 key 创建、鉴权、profile header、key/profile IP allowlist 已完成或接近完成；预算和细粒度权限工作流仍待完善。
- E3 Provider/Channel/Key Pool：CRUD、密钥加密、runtime key 注入、状态写回、recovery dry-run/API/UI、health summary 已有；本轮补 endpoint static + DNS SSRF guard，且 guard 发生在 provider key 打开前；真实 probe、轮换、同 channel 多 key retry 待补。
- E4 Model Catalog/Association：canonical model CRUD、default price selector、association dry-run/UI、channel mapping runtime 已有；复杂候选、live smoke 和价格配置 UI 待补。
- E5 Data Plane：OpenAI chat/responses/embeddings、Anthropic messages、Gemini native generate/stream 已有核心 runtime；协议细节和 live matrix 待补。
- E6 Adapter：OpenAI/Anthropic/Gemini/MCP fixtures 与 conformance harness 已接 CI/wrapper；更深 trait replay 和真实网络 smoke 待补。
- E7 Streaming Engine：SSE parser、partial/no-late-fallback/end reason/backpressure/usage settle 已有核心实现；本轮接入 stream idle timeout；usage estimated 和 live cancel/backpressure matrix 待补。
- E8 Routing/Fallback/Health：routing core、priority/weight、health/rate-limit availability 与 reservation 纯函数、fallback engine、运行态 route decision summary、trace affinity previous-success DB lookup contract、Gateway best-effort runtime 和 rate-limit-aware key selection 第一切片已有；已接入 configured max attempts；真实 rate counters/Gateway acquire-release wiring、精确 TPM、trace affinity live smoke 和同 channel retry 待补。
- E9 Billing Ledger：钱包/预算模型完成，price/preauth/settle/reconciliation、runtime usage extraction 和部分非流式 Gateway cache/reasoning rating 接入已有；reserve/settle/refund 强一致 writer 纯函数 contract 已固定锁顺序、余额窗口、预算维度和并发拒绝语义，并新增 mockable command executor/in-memory execution contract 固定 bounded write command 与执行结果语义；Postgres execution planner contract 已把 bounded commands 转为 ordered lock SQL、bounded assertion/insert/update statement shapes 和 transaction steps，真实 DB I/O 仍未实现；runtime reserve/refund Postgres writer、真实 DB 强一致扣减、Gateway cache/reasoning usage 持久化和 scheduler 待补。
- E10 Observability：request/provider logs、trace summary、payload policy、metrics、alert webhook dry-run、OTEL config 已有；本轮收窄 readiness 输出；真实 exporter/webhook sender 和 payload object store 待补。
- E11 Admin UI：主要工作区均已 MVP 接入并保持 bundle budget；Provider/Channel 已支持高级 JSON policy 字段编辑，Audit Logs 已有时间过滤，Request/Trace 已展示 route summary 稳定字段并补 payload preview lazy-load UI contract，Health Dashboard 已支持窗口/样本手动刷新与矩阵扫描；完整审计体验、真实 payload 读取后端/对象存储、实时图表待补。
- E12 Migration Importer：parser/mapping/dry-run/SQL apply plan/rollback plan 已有；真实 PostgreSQL apply 与 rollback runner 待补。
- E13 Security/Compliance：secret masking、payload redaction、provider encryption、offline supply-chain artifacts、chat prompt protection non-stream/stream preflight 和 configurable rule-set pure contract 已有，且 configurable rules 已支持安全 bounded regex；近期补 body-limit 前置、CORS allowlist、endpoint static + DNS SSRF guard、redirect 禁用、readiness 脱敏和 bounded hit summary；联网漏洞/镜像扫描、digest pinning、跨协议 prompt protection 与 configurable rules runtime 接入待补。
- E14 Deploy/Ops：Docker/Compose、本地 release gate、Helm static validation、backup/restore scripts、runbook 已有；staging/K8s/live restore 演练未完成。
- E15 P1/P2：request override 展示、exact cache billing、Coding Agent Profiles、ClickHouse plan、MCP/Prompt Eval/Shadow 等已有部分 pure/plan-only 切片；真实 runtime 多数未开始。

## 当前主要风险

- Live/staging 验收不足：Docker strict smoke、K8s staging、恢复演练、load/chaos/security release checklist 仍需具备工具和环境后补跑。
- 多个能力仍是 plan-only 或 pure function：OIDC exchange/JWKS、prompt protection configurable rules runtime 接入、billing DB scheduler、importer apply/rollback、ClickHouse writer、alert webhook sender 还未做真实 I/O。
- 路由运行态仍缺真实 rate-limit counter 写入/Gateway acquire-release wiring、精确 TPM 估算、trace affinity live smoke 和同 channel retry；routing reservation contract 已固定纯函数语义。
- Billing 仍缺 reserve/refund Postgres writer runtime、真实余额强一致扣减和并发防超卖 integration；纯函数 writer contract 与 mockable executor contract 已有，尚未连接 DB。
- Audit 剩余主要是更多 billing 写操作覆盖、完整 audit UI 验收和更广泛端到端事务回滚 smoke；provider、channel、api_key_profile、canonical model、model_association、provider_key、price_version、virtual_key 已优先进入事务化 audit。
