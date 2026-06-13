# AI Gateway / New API 替代产品开发启动包

版本：0.1-dev-start  
日期：2026-06-01  
用途：交付开发组作为立项、架构设计、任务拆解、测试验收、上线运维的初始基线。

## Current Status / Launch Scope

当前工程状态以 `TODO/`、`docs/P0_BETA_STATUS.md`、`project/RELEASE_CHECKLIST.md` 为准；本 README 是开源/开发入口，不是 launch readiness 证明。

2026-06-07 当前口径：

- New API 风格用户自助：当前产品主线是站长后台 -> 用户门户 -> Gateway/上游的非商户三层 API 分发；用户注册/登录、用户控制台、自助 API Key、兑换码充值、余额/模型/用量视图和 Gateway 调用已通过 live E2E smoke。
- 开源 New API 替代品 Alpha：本地 code-first P0 gate 已通过；`.tmp/open-source-alpha/open_source_alpha_gate.json` 记录 `status=pass`、`run_matrix=true`、`ready_for_open_source_alpha=true`。公开 tag 前仍建议 clean-clone/CI 复跑。
- 真实上游接入：已提供 opt-in smoke；没有真实 provider base URL/API key/model 时留档绕过，不能宣称真实上游已验证。
- 可信用户 voucher-backed handoff：保留为 legacy/operator fallback，不能替代 New API 用户自助主线。
- 完整 public/self-serve commercial launch：尚未足够；payment/order/invoice runtime、subscription runtime、full CI/full wrapper、staging/load/security 仍是后续工作，且不阻塞当前 voucher-backed API 分发主线。

当前产品优先级文件：`TODO/NEW_API_MVP_PRIORITY_2026-06-07.md`。
开源 Alpha 优先级文件：`TODO/OPEN_SOURCE_ALPHA_PRIORITY_2026-06-06.md`。

## 1. 产品目标

我们要建设一个兼容 New API / One API 迁移、同时吸收 AxonHub / LiteLLM / Portkey / GPT-Load / Helicone 等优点的自托管 AI Gateway。

核心定位：

> 面向站长自托管和多用户 API 分发的 New API 风格平台，采用站长/管理员、用户/开发者、Gateway/上游供应商三层，而不是商户支付平台；当前提供用户门户、OpenAI-compatible API、兑换码额度、自助 API Key、多模型协议兼容、渠道与 Key 池治理、稳定流式转发、可解释路由、账务级 Ledger、Trace-first 观测和迁移工具。

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

## 5. Open-source Alpha Quickstart

Status on 2026-06-07: this Quickstart is the current code-first open-source Alpha entry point for New API-style API distribution. The local P0 gate artifact currently passes, including the route-level live proof and serial Gateway matrix. It is still not a full commercial/New API replacement claim: public self-serve billing, payment/order/invoice runtime, subscription runtime, full wrapper CI, staging, load, and production hardening remain later work and do not block voucher-backed API distribution.

Clone the repository and enter the workspace:

```powershell
git clone <repo-url> fubox_API
cd fubox_API
```

Prerequisites:

- Docker Desktop with Compose.
- PowerShell 7+ (`pwsh`) or Windows PowerShell for the repository scripts.
- Rust and Node/npm are required for contributor checks, but the first compose smoke builds and runs through Docker.

Default local endpoints:

| Service | URL |
|---|---|
| Admin UI | `http://127.0.0.1:5173` |
| Gateway | `http://127.0.0.1:8080` |
| Control Plane | `http://127.0.0.1:8081` |
| Mock provider | `http://127.0.0.1:18080` |

Default dev API token: `dev_test_key_123456789`. This is a local seed only; do not reuse it outside development.
Default local admin seed: `admin@example.com` with the local-only password documented in `db/README.md`. Use it only on the loopback Compose stack.

First run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\alpha_smoke.ps1 -StartCompose -ComposeTimeoutSeconds 600
```

The script starts Compose with `--build --force-recreate`, waits through bounded retries, verifies Gateway/Control Plane/Admin UI/mock-provider, runs the SDK smoke, runs the secret scan, and writes `.tmp/open-source-alpha/alpha_smoke.json`. If Docker is unavailable, Compose build/up exceeds `-ComposeTimeoutSeconds` (or `COMPOSE_TIMEOUT_SECONDS`), or stale exited Compose containers reference missing local images, the gate still writes a secret-safe artifact with `status`, `blockers`, `last_step`, diagnostics, and rerun commands; raw auth tokens are omitted. Use `-NoForceRecreate` only when intentionally testing container reuse.

If local PostgreSQL or Redis already owns host ports `5432` or `6379`, keep container-internal service ports unchanged and rerun with host-port overrides:

```powershell
$env:POSTGRES_HOST_PORT = "55432"
$env:REDIS_HOST_PORT = "56379"
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\alpha_smoke.ps1 -StartCompose -ComposeTimeoutSeconds 600
```

Basic health checks after startup:

```powershell
Invoke-RestMethod http://127.0.0.1:8080/readyz
Invoke-RestMethod http://127.0.0.1:8081/readyz
Invoke-WebRequest http://127.0.0.1:5173 -UseBasicParsing
```

Open the Admin UI at `http://127.0.0.1:5173`. The UI talks to the same local Compose services through `/api/gateway`, `/api/control-plane`, and `/api/mock-provider`.

`alpha_smoke.ps1` is the first-run smoke, not the full Alpha release gate. Before claiming Open-source Alpha readiness, also run the live route and Gateway matrix checks against the same Compose environment:

```powershell
.\scripts\verify_route_level_live_http_proof.ps1
.\scripts\verify_control_plane_crud_smoke.ps1 -IncludeFullCrud -StrictFullCrud
.\scripts\verify_gateway_routing_smoke.ps1
.\scripts\verify_gateway_profile_smoke.ps1
.\scripts\verify_gateway_retry_fallback_smoke.ps1 -StrictGatewayFallback
.\scripts\verify_gateway_rate_limit_reservation_smoke.ps1 -ArtifactPath .tmp\gateway-rate-limit\e8_rate_limit_live.json
.\scripts\verify_gateway_paid_hot_path_smoke.ps1
.\scripts\verify_sdk_smoke.ps1 -SkipInstall
```

Aggregate the current Alpha evidence without running the matrix:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_open_source_alpha_gate.ps1 -DryRun
```

Check the public quickstart, Docker build context, CI workflow surface, and clean-clone/CI transcript status without doing a network clone or running Docker:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_open_source_alpha_clean_clone_readiness.ps1
```

This writes `.tmp/open-source-alpha/clean_clone_readiness.json`. When a real clean-clone/CI transcript is not available, the artifact records `clean_clone_or_ci_required_before_public_release=true`, `local_alpha_pass_unaffected=true`, the public tag blocker list, and the exact transcript commands to run from `docs/OPEN_SOURCE_ALPHA_CLEAN_CLONE_TRANSCRIPT_TEMPLATE.md`; that release blocker must be cleared before a public tag, but it does not invalidate the current local code-first Alpha pass.

Run the serial Gateway matrix and write the release gate artifact:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_open_source_alpha_gate.ps1 -RunMatrix
```

The gate writes `.tmp/open-source-alpha/open_source_alpha_gate.json`. Exit `0` means `pass`; exit `2` means `warn` with unproven or missing matrix evidence listed in `blockers`; exit `1` means `fail`. The matrix includes Control Plane management parity through `.tmp/control-plane/control_plane_management_parity_smoke.json`; the gate also records the clean-clone/CI transcript guard through `.tmp/open-source-alpha/clean_clone_readiness.json`. The gate does not accept trusted-user voucher-backed Beta artifacts as Open-source Alpha evidence.

Manual equivalent:

```powershell
.\scripts\compose_up.ps1 -ForceRecreate
.\scripts\verify_compose_smoke.ps1
.\scripts\verify_sdk_smoke.ps1 -SkipInstall
.\scripts\scan_secrets.ps1
```

If `docker compose images` reports `No such image` for an exited old container, clean up and rerun:

```powershell
docker compose -f deploy/docker-compose/docker-compose.yml down
docker compose -f deploy/docker-compose/docker-compose.yml up --build --force-recreate -d
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\alpha_smoke.ps1 -StartCompose -ComposeTimeoutSeconds 600
```

If the cleanup rerun is blocked by `127.0.0.1:5432` or `127.0.0.1:6379`, use the same override variables:

```powershell
$env:POSTGRES_HOST_PORT = "55432"
$env:REDIS_HOST_PORT = "56379"
docker compose -f deploy/docker-compose/docker-compose.yml up --build --force-recreate -d
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\alpha_smoke.ps1 -StartCompose -ComposeTimeoutSeconds 600
```

Try the OpenAI-compatible API:

```powershell
$headers = @{ Authorization = "Bearer dev_test_key_123456789" }
Invoke-RestMethod -Headers $headers -Uri http://127.0.0.1:8080/v1/models
Invoke-RestMethod -Method Post -Headers $headers -ContentType "application/json" `
  -Uri http://127.0.0.1:8080/v1/chat/completions `
  -Body '{"model":"mock-gpt-4o-mini","messages":[{"role":"user","content":"ping"}]}'
```

New API-style user self-serve flow:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_new_api_mvp_e2e_smoke.ps1 -ContractOnly
```

The contract mode writes `.tmp/new-api-mvp/new_api_mvp_e2e_smoke.json` and checks that the user-facing path is wired: register/login, user balance, voucher redeem, self-serve API key, Gateway call, and user usage logs. After the local stack is running, execute the full live flow:

If a fresh local stack is missing the default project/profile/mock model route, run the local mock-distribution bootstrap first:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap_new_api_mock_distribution.ps1 -Apply
```

The bootstrap replays the repo-bounded dev seed reconciliation for the local Alpha mock-provider path, then writes `.tmp/new-api-mvp/mock_distribution_bootstrap.json`. It verifies the default tenant/project, `Default OpenAI Compatible` profile, metadata-only payload policy, mock provider/channel/provider key, `mock-gpt-4o-mini` canonical model, and model association. It does not create real provider credentials, user API keys, vouchers, credit, sessions, payment orders, or subscriptions, and the artifact omits raw secrets.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_new_api_mvp_e2e_smoke.ps1 -Live
```

The live mode performs register/login -> user balance wallet -> admin-issued voucher -> user redeem -> user API key -> Gateway `/v1/models` and `/v1/chat/completions` -> user request logs. Its artifact is secret-safe. The smoke verifies the current seeded/operator-prepared default profile path; generic post-registration tenant/project/profile/bootstrap automation is still a productization gap. Payment/order/invoice, subscription, and enterprise SSO remain deferred commercial/enterprise lanes, not New API MVP blockers.

Current local evidence on 2026-06-07: `scripts\verify_new_api_mvp_e2e_smoke.ps1 -Live` passed with `.tmp/new-api-mvp/new_api_mvp_e2e_smoke.json` showing `overall_status=pass`, `live.status=pass`, `secret_safe=true`, `blockers=[]`, and user-visible models/endpoints verified through `/user/models`.

Real upstream provider onboarding is opt-in because it requires real credentials:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_real_provider_onboarding_smoke.ps1
```

Without `REAL_PROVIDER_BASE_URL`, `REAL_PROVIDER_API_KEY`, and `REAL_PROVIDER_MODEL`, the script writes `.tmp/real-provider/real_provider_onboarding_smoke.json` with `blocked_missing_real_provider_credentials` and exits successfully so the missing external credentials are documented without blocking the mock/New API MVP path. To run live:

```powershell
$env:REAL_PROVIDER_BASE_URL = "https://provider.example/v1"
$env:REAL_PROVIDER_API_KEY = "<real-provider-key>"
$env:REAL_PROVIDER_MODEL = "provider-model-name"
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_real_provider_onboarding_smoke.ps1 -Live
```

The live mode creates provider/channel/provider-key/model/profile/model association/virtual key and calls Gateway `/v1/models` plus `/v1/chat/completions`. The artifact must not echo raw provider keys, admin sessions, virtual key secrets, voucher codes, or raw provider response bodies.

Admin fallback / operator path for creating a local virtual key:

```powershell
$login = Invoke-RestMethod -Method Post -ContentType "application/json" `
  -Uri http://127.0.0.1:8081/admin/auth/login `
  -Body '{"email":"admin@example.com","password":"<local-dev-admin-password-from-db-README>"}'
$adminHeaders = @{ "x-admin-session" = $login.data.session_token_once }
$key = Invoke-RestMethod -Method Post -Headers $adminHeaders -ContentType "application/json" `
  -Uri http://127.0.0.1:8081/admin/virtual-keys `
  -Body '{"project_id":"00000000-0000-0000-0000-000000000020","default_profile_id":"00000000-0000-0000-0000-000000000040","name":"quickstart-local-key","status":"active"}'
$headers = @{ Authorization = "Bearer $($key.data.secret)" }
Invoke-RestMethod -Headers $headers -Uri http://127.0.0.1:8080/v1/models
```

The virtual key secret is returned once by create. Later `GET /admin/virtual-keys/{id}` responses are redacted; store the one-time value outside README, logs, and release artifacts. For a secret-safe live proof of this same chain, run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_route_level_live_http_proof.ps1
```

The Admin Console includes a `Distribution` readiness view for station operators. It aggregates provider, channel, provider-key, model, profile, virtual-key, voucher-backed credit, User Portal, and recent usage signals without exposing raw provider secrets, voucher codes, API key secrets, or request payloads. The same page includes a local mock bootstrap guide for `scripts\bootstrap_new_api_mock_distribution.ps1 -Apply`; that guide is for the local/default mock-provider path only and is not production provider onboarding.

User-facing request logs are intentionally narrower than admin request logs: `/user/request-logs` omits provider/channel/provider-key routing internals and payload policy internals while preserving model, status, tokens, cost, latency, redaction hashes, and request timing.

Minimal Admin/API operation chain:

| Operation | Admin UI or API path |
|---|---|
| Login | `POST /admin/auth/login` |
| Provider/channel/provider-key setup | `POST /admin/providers`, `POST /admin/channels`, `POST /admin/provider-keys` |
| Canonical model and profile setup | `POST /admin/models`, `POST /admin/api-key-profiles`, `POST /admin/model-associations` |
| Issue/read/disable API key | `POST /admin/virtual-keys`, `GET /admin/virtual-keys/{id}`, `POST /admin/virtual-keys/{id}/disable` |
| Voucher quota path | `POST /admin/voucher-issuances`, `POST /billing/vouchers/redeem` |
| Request troubleshooting | `GET /admin/request-logs`, `GET /admin/request-logs/{id}`, `GET /admin/traces/{trace_id}` |

Stop the local stack:

```powershell
.\scripts\compose_down.ps1
```

If migrations or dev seeds changed and you need a clean database, remove the Compose volume deliberately:

```powershell
docker compose -f deploy/docker-compose/docker-compose.yml down -v
```

Troubleshooting:

- Docker daemon unavailable: start Docker Desktop and rerun `pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\alpha_smoke.ps1 -StartCompose -ComposeTimeoutSeconds 600`.
- Compose build exceeds the timeout: increase `-ComposeTimeoutSeconds` or set `$env:COMPOSE_TIMEOUT_SECONDS`.
- Host port conflicts on `5432` or `6379`: set `POSTGRES_HOST_PORT` and `REDIS_HOST_PORT` as shown above; do not change container-internal service names or ports.
- `docker compose images` reports `No such image`: run `docker compose -f deploy/docker-compose/docker-compose.yml down`, then rerun the first-run smoke with `-StartCompose`.
- Gateway API returns `401`: check the `Authorization` header and use either the seeded local token or the one-time virtual key secret returned by create.
- Gateway API returns `402`: the key has insufficient wallet/voucher-backed quota; the expected behavior is no provider call.
- Gateway API returns no route/model errors: verify provider/channel/model/profile/model-association state with `.\scripts\verify_control_plane_crud_smoke.ps1 -IncludeFullCrud -StrictFullCrud`.

Known limitations for this Alpha:

- Current pass evidence is local code-first Alpha evidence; public tag readiness still needs clean-clone or CI rerun.
- The clean-clone/CI transcript guard is intentionally lightweight. It verifies README, `.dockerignore`, CI workflow, required commands, known limitations, trusted-beta caveats, and full-commercial caveats; it does not perform an expensive clone, network install, Docker build, or hosted CI replay.
- Admin UI parity is not complete. Use the Control Plane API fallback above for provider/channel/model/profile/key/voucher operations.
- New users currently join a preconfigured default project/profile path. Local Alpha relies on dev seeds or station/operator setup for default profile, visible model, upstream channel, and voucher issuance; User Portal readiness explains missing setup, but does not auto-create provider/channel/profile/bootstrap or starter credit yet.
- Payment/order/invoice runtime and subscription runtime are deferred commercial lanes, not current API distribution blockers; public self-serve voucher UX, staging/load/security hardening, and full wrapper CI are also outside the current Alpha claim.
- Development seeds include local-only credentials and fake sealed provider keys. Production migration pipelines should apply `db/migrations` without `db/dev-seeds`.
- The mock provider is the default first-run upstream. Real provider onboarding requires real provider base URLs, provider API keys, model names, and fresh `scripts\verify_real_provider_onboarding_smoke.ps1 -Live` evidence.

## 6. 本地开发命令

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

Gateway smoke scripts default to `GATEWAY_AUTH_TOKEN=dev_test_key_123456789`. `verify_compose_smoke.ps1 -StrictGatewayContracts` hard-checks gateway `/readyz` `database_gateway_store=connected`, authenticated `GET /v1/models`, unauthenticated chat rejection, and strict streaming status expectations. `verify_gateway_routing_smoke.ps1 -StrictGatewayRouting` hard-checks persisted routing ids, route policy/upstream model log fields, and missing-route rejection. `verify_sdk_smoke.ps1` uses the local Node OpenAI SDK package under `tests/integration/sdk-smoke` for non-stream chat. `verify_control_plane_crud_smoke.ps1 -IncludeFullCrud -StrictFullCrud` verifies provider/channel/provider-key/canonical-model/profile/model-association create/get/list/patch/delete plus model-association dry-run without exposing provider key material.

Security scan dry-runs:

```powershell
.\scripts\scan_secrets.ps1
.\scripts\scan_supply_chain.ps1 -SkipNetwork
.\scripts\generate_supply_chain_artifacts.ps1 -OutputDirectory .\artifacts\supply-chain
```

`scan_secrets.ps1` reports only file paths, line numbers, and match types; it does not print matched secret material. `scan_supply_chain.ps1 -SkipNetwork` validates Rust/npm lockfile structure plus Dockerfile/Compose container declarations without requiring network access, Docker, or container scanner tools. `generate_supply_chain_artifacts.ps1` emits a CycloneDX-style SBOM, an in-toto/SLSA provenance statement, a manifest, and SHA256 checksums for CI/release artifacts. When network-backed scanning is enabled, missing optional tools such as `cargo-audit`, `npm audit`, `trivy`, `grype`, or Docker are reported as warnings/skips instead of local dry-run failures.

The generated SBOM/provenance/checksum artifacts are offline build evidence; they do not replace network-backed dependency vulnerability scans, real container image scans, or Docker image digest pinning.

## 7. P0 成功定义

P0 版本不是 demo，而是可灰度上线的生产初版。达到 P0 必须满足：

注意：下面是产品目标定义；当前实际验收状态以 `TODO/` 和 release artifacts 为准。当前 New API MVP 用户自助 live E2E 已通过，本地 code-first open-source Alpha P0 gate 已通过；trusted-user handoff 仅为 legacy/operator fallback 证据；不是 full commercial readiness。

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

## 8. 不在 P0 的内容

以下能力重要，但不阻塞 P0：

- 完整支付、发票、工单、多货币运营后台。
- 完整 MCP Gateway / A2A Gateway。
- 复杂 Semantic Cache / Semantic Routing。
- Prompt Registry、Eval Dataset、Shadow Traffic 全链路平台化。
- 私有推理集群 inference-aware routing。

这些进入 P1/P2。
