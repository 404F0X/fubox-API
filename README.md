# AI Gateway / New API 替代产品开发启动包

版本：0.1-dev-start  
日期：2026-06-01  
用途：交付开发组作为立项、架构设计、任务拆解、测试验收、上线运维的初始基线。

## 1. 产品目标

我们要建设一个兼容 New API / One API 迁移、同时吸收 AxonHub / LiteLLM / Portkey / GPT-Load / Helicone 等优点的生产级 AI Gateway。

核心定位：

> 面向团队、企业和 API 分发场景的生产级 LLM Gateway / AI Control Plane，提供多模型协议兼容、渠道与 Key 池治理、稳定流式转发、可解释路由、账务级 Ledger、Trace-first 观测、Guardrails、迁移工具和生产运维能力。

## 2. 资料包结构

| 路径 | 作用 |
|---|---|
| `README.md` | 开发包索引与启动说明 |
| `ARCHITECTURE.md` | 总体架构规划，开发必须先读 |
| `FEATURE_PLAN.md` | 功能规划、P0/P1/P2 版本边界 |
| `TODO.md` | 可执行任务清单，适合导入项目管理工具 |
| `TEST_AND_ACCEPTANCE.md` | 测试策略、验收流程、上线门禁 |
| `docs/17_RUST_IMPLEMENTATION_BASELINE.md` | Rust-first 实施基线：workspace、runtime、TLS、平台与性能约束 |
| `docs/` | 深度设计文档：数据模型、API、路由流式、账务、安全、运维、迁移等 |
| `examples/` | 示例配置、SQL 草案、OpenAPI 草案、CI、压测脚本 |
| `project/` | 任务看板 CSV、验收清单、发布清单、测试用例 CSV |
| `references/` | 前期调研文档和来源链接 |

## 3. 推荐开发阅读顺序

1. `ARCHITECTURE.md`：理解控制面、数据面、请求链路和模块边界。
2. `FEATURE_PLAN.md`：确认 P0/P1/P2 功能范围。
3. `TODO.md`：按 Epic 分配开发任务。
4. `TEST_AND_ACCEPTANCE.md`：确认 Definition of Done、CI 门禁和验收标准。
5. `docs/17_RUST_IMPLEMENTATION_BASELINE.md`：确认 Rust workspace、Tokio/Axum/Hyper/rustls 基线和平台约束。
6. `docs/04_DATA_MODEL.md`、`docs/05_API_AND_PROTOCOL_SPEC.md`、`docs/06_ROUTING_STREAMING_SPEC.md`、`docs/07_BILLING_LEDGER_SPEC.md`：进入详细设计。
7. `examples/`：作为初始化仓库的参考样例。

## 4. 开发原则

- 不做简单 New API clone；要做生产级 AI Gateway。
- 协议兼容和原生透传并存，避免强行统一导致字段丢失。
- 流式稳定性是一等能力，不是边缘功能。
- 账务必须是 Ledger，不允许只在日志里扣余额。
- 每次路由、重试、fallback、扣费、错误都必须可解释。
- 配置必须可校验、可 dry-run、可回滚。
- Data Plane 热路径必须轻量，日志和账务事件尽量异步化。
- P0 优先打通可靠主链路，不追求一开始支持所有 provider 和所有运营功能。

## 5. 本地开发命令

Windows 环境不需要安装 `make`，直接使用 PowerShell 脚本：

```powershell
.\scripts\fmt.ps1
.\scripts\lint.ps1
.\scripts\test.ps1
.\scripts\build.ps1
.\scripts\dev.ps1
.\scripts\compose_up.ps1
.\scripts\verify_compose_smoke.ps1
.\scripts\verify_db_schema.ps1
.\scripts\verify_sdk_smoke.ps1
.\scripts\compose_down.ps1
```

Docker Desktop 如果不在 `PATH` 中，脚本会自动使用默认安装路径 `C:\Program Files\Docker\Docker\resources\bin\docker.exe`。

Local compose notes:

- Compose publishes Postgres, Redis, mock-provider, Gateway, Control Plane, and Admin UI on `127.0.0.1` only. This keeps development services off the LAN; change host bindings deliberately if another machine must reach them.
- The Compose and Helm Admin UI image serves a production build with nginx. Browser API calls stay same-origin under `/api/gateway`, `/api/control-plane`, and `/api/mock-provider`; the container proxies those paths to internal service upstreams.
- Development seeds use fake local credentials, including `dev_test_key_123456789` and sealed provider keys with master key id `dev-seed-v1`. Compose sets matching dev-only provider-key master key environment variables so the seeded sealed keys can be opened locally. Do not reuse these values outside local development.
- Production migration pipelines should apply `db/migrations` without applying `db/dev-seeds`.
- `server.trusted_proxy_allowlist` defaults to empty. With the default, Gateway uses the TCP peer IP for API-key IP allowlist checks and ignores `X-Forwarded-For` and `X-Real-IP`. Add only trusted reverse proxy IPs or CIDRs; when the peer is trusted, Gateway uses the first valid `X-Forwarded-For` IP, or `X-Real-IP` if `X-Forwarded-For` is absent. Malformed forwarded IP headers are rejected during auth.

Additional strict contract checks:

```powershell
.\scripts\verify_compose_smoke.ps1 -StrictGatewayContracts
.\scripts\verify_gateway_routing_smoke.ps1 -StrictGatewayRouting
.\scripts\verify_control_plane_crud_smoke.ps1 -StrictFullCrud
```

Gateway smoke scripts default to `GATEWAY_AUTH_TOKEN=dev_test_key_123456789`. `verify_compose_smoke.ps1 -StrictGatewayContracts` hard-checks gateway `/readyz` `database_gateway_store=connected`, authenticated `GET /v1/models`, unauthenticated chat rejection, and strict streaming status expectations. `verify_gateway_routing_smoke.ps1 -StrictGatewayRouting` hard-checks persisted routing ids, route policy/upstream model log fields, and missing-route rejection. `verify_sdk_smoke.ps1` uses the local Node OpenAI SDK package under `tests/integration/sdk-smoke` for non-stream chat. `verify_control_plane_crud_smoke.ps1` verifies provider/channel/model/model-association create+get contracts, and `-StrictFullCrud` gates list/patch/delete behavior.

Security scan dry-runs:

```powershell
.\scripts\scan_secrets.ps1
.\scripts\scan_supply_chain.ps1 -SkipNetwork
.\scripts\generate_supply_chain_artifacts.ps1 -OutputDirectory .\artifacts\supply-chain
```

`scan_secrets.ps1` reports only file paths, line numbers, and match types; it does not print matched secret material. `scan_supply_chain.ps1 -SkipNetwork` validates Rust/npm lockfile structure plus Dockerfile/Compose container declarations without requiring network access, Docker, or container scanner tools. `generate_supply_chain_artifacts.ps1` emits a CycloneDX-style SBOM, an in-toto/SLSA provenance statement, a manifest, and SHA256 checksums for CI/release artifacts. When network-backed scanning is enabled, missing optional tools such as `cargo-audit`, `npm audit`, `trivy`, `grype`, or Docker are reported as warnings/skips instead of local dry-run failures.

The generated SBOM/provenance/checksum artifacts are offline build evidence; they do not replace network-backed dependency vulnerability scans, real container image scans, or Docker image digest pinning.

## 6. P0 成功定义

P0 版本不是 demo，而是可灰度上线的生产初版。达到 P0 必须满足：

- 支持 OpenAI Chat / Responses / Embeddings / Models 基础兼容。
- 支持 Anthropic Messages 和 Gemini GenerateContent 的常用请求转发或透传。
- 支持 OpenAI-compatible、Anthropic、Gemini、DeepSeek、Qwen/Doubao、OpenRouter、自定义上游。
- 支持 API Key Profile、Canonical Model、Model Association、Channel Mapping 四层模型治理。
- 支持权重、优先级、健康分、限流感知、retry-before-first-byte、fallback。
- 支持统一 SSE stream engine、partial_sent、stream_end_reason、terminal event 校验。
- 支持 Price Book、Price Version、Reserve/Settle/Refund 账本流水。
- 支持 Thread/Trace/Request 观测和 Route Trace。
- 支持 PostgreSQL + Redis 生产部署，SQLite 仅用于本地 demo。
- 支持 New API / One API 基础配置导入。
- 通过 `TEST_AND_ACCEPTANCE.md` 定义的 P0 验收门禁。

## 7. 不在 P0 的内容

以下能力重要，但不阻塞 P0：

- 完整支付、发票、工单、多货币运营后台。
- 完整 MCP Gateway / A2A Gateway。
- 复杂 Semantic Cache / Semantic Routing。
- Prompt Registry、Eval Dataset、Shadow Traffic 全链路平台化。
- 私有推理集群 inference-aware routing。

这些进入 P1/P2。
