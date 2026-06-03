# TODO.md：AI Gateway / New API 替代产品开发任务清单

版本：0.1-dev-start  
日期：2026-06-01  
状态标记：`[ ] 未开始`、`[~] 进行中`、`[x] 完成`、`[!] 阻塞`  
优先级：P0 必须、P1 重要、P2 后续。

> 使用方式：开发组可以直接把本文件拆到 Jira/GitHub Issues。每个任务的完成必须满足 `TEST_AND_ACCEPTANCE.md` 中 Definition of Done。

---

## Epic E0：仓库、工程化和开发环境

- [x] **E0-001 初始化 monorepo/repo 结构**  
  优先级：P0  
  产出：`Cargo.toml`、`apps/`、`crates/`、`web/`、`db/migrations/`、`deploy/`、`tests/`、`docs/`。  
  验收：本地 `make dev` 或 `./scripts/dev.ps1` 可启动 gateway、control API、worker、mock provider。

- [x] **E0-002 建立基础 CI**  
  优先级：P0  
  内容：lint、unit test、frontend typecheck、container build、secret scan。  
  验收：PR 自动运行，失败阻断 merge。当前 CI/scripts/test smoke 串联已 fail-fast，`scripts/test.ps1` 已通过全套 cargo tests、smoke dry-run、npm ci/test，并已将 frontend `build` + `check:bundle` 纳入本地 wrapper 与 CI；wrapper 已修复 `$LASTEXITCODE` 为 null 时错误退出的问题，并使用 hashtable splat 传递 `DryRun`，不再被当位置参数；并补齐 control-plane CRUD 与 retry/fallback dry-run 覆盖。

- [x] **E0-003 建立本地 Docker Compose**  
  优先级：P0  
  内容：PostgreSQL、Redis、gateway、control-plane、worker、admin-ui、mock-provider。  
  验收：一条命令启动，健康检查通过。Docker Compose 已验证启动，gateway/control-plane/mock-provider 健康检查通过，admin-ui 返回 200；已配置 provider key master key 供 dev sealed key 解密；compose dev 暴露端口已收敛为仅绑定 `127.0.0.1`。

- [x] **E0-004 定义全局配置 schema**  
  优先级：P0  
  内容：env、DB config、Redis、timeouts、limits、log policy。  
  验收：非法配置启动失败并给出明确错误。当前 `AI_GATEWAY_ENV=production` 时必须显式设置 `AI_GATEWAY_CONFIG`，避免生产误读相对路径示例配置；routing timeout/attempt/body limit 均已有配置校验。

- [x] **E0-005 建立 provider mock framework**  
  优先级：P0  
  内容：模拟 200、429、5xx、timeout、EOF、invalid SSE、large chunk。  
  验收：集成测试可复现路由和 streaming 故障。

---

## Epic E1：身份、租户、RBAC、审计

- [x] **E1-001 设计并实现 tenant/team/project/user 表**  
  优先级：P0  
  验收：支持单租户默认初始化，所有业务表具备 tenant_id。当前迁移已通过 PostgreSQL 16 fresh init 和跨租户 FK 负向断言。

- [~] **E1-002 实现本地管理员登录**  
  优先级：P0  
  验收：密码 hash、安全 session、登录失败限速。当前 `ai-gateway-auth` 已实现 PBKDF2-HMAC-SHA256 密码 hash、session token 生成/lookup/hash，`db/migrations/0005_*` 已新增 `user_sessions`；Control Plane 已接入 `/admin/auth/login|me|logout`，Admin UI 已调用真实登录并默认依赖 HttpOnly Cookie，会话 header 仅保留为显式 fallback；`verify_control_plane_crud_smoke.ps1` 已覆盖登录取 token；登录失败限速已接入 Control Plane：按 tenant + 规范化用户名维度生成 fingerprint，不保存原始用户名，连续失败达到阈值返回 `429 login_rate_limited`，成功登录创建 session 后清理计数，错误响应不泄露凭据/session/token 或用户是否存在；默认仍使用单进程内存 store，并新增显式 `AI_GATEWAY_ADMIN_LOGIN_RATE_LIMIT_STORE=redis|distributed_redis` 的 Redis 分布式最小 runtime backend，使用 `config.redis.addr/db`、fingerprint-only key、Redis `EVAL` + `SET EX` 原子失败计数和 `DEL` 成功清理；Redis 不可用时 fail-closed 返回同样 secret-safe `429 login_rate_limited`，不回显用户名/凭据/session/token。Redis auth/TLS/连接池、分布式 live smoke 和更完整运维配置尚未完成。

- [~] **E1-003 实现 RBAC 后端中间件**  
  优先级：P0  
  验收：SuperAdmin/TenantAdmin/Ops/Billing/Developer/Viewer 权限测试通过。当前 `ai-gateway-auth` 已按 DB role（owner/admin/ops/billing/developer/viewer）实现权限矩阵纯函数并补单测；Control Plane admin router 已通过 `require_admin_rbac` 接入 session 认证，`rbac.rs` 已补 Control Plane 专用角色判定与 secret-safe capability summary，并已通过 `/admin/auth/me` 返回 `capability_summary.capabilities`/`denied_capabilities`，完整覆盖 provider/key/log/billing/price/manual-test/request-log/health/reconciliation/alert webhook/price version create/prompt eval shadow dry-run 矩阵；key manage 在 Control Plane 收紧为 owner/admin/ops，BillingAdjust 仅 owner/billing，Viewer 不拿 credential-sensitive read；OpenAPI extension 与 `tests/fixtures/control-plane/rbac_matrix_contract.json` 已同步。Admin UI 已按 capability summary 裁剪导航和 Providers 关键操作入口；Redis/分布式策略缓存尚未完成。

- [~] **E1-004 实现 Audit Log**  
  优先级：P0  
  验收：key、provider、price、route、billing 修改均写 audit。当前 Control Plane admin provider/channel/provider_key/api_key_profile/virtual_key/model/model_association 写操作已写入 `audit_logs`，并记录 before/after snapshot 与 session 元数据；audit metadata/snapshot 已接入敏感信息 sanitizer，避免 secret、Authorization、Cookie、payload/body、raw headers、raw UA/client IP 等原文落审计。provider_key create/update/delete、price_version create 与 virtual_key create/disable/expire 已进入事务化闭环：业务写入与 success audit 使用同一 DB transaction，缺失业务行不会构造 success audit，audit insert 失败会回滚对应写入；相关 audit metadata 已记录 `user_agent_sha256`、`client_ip_sha256`、IP 来源/类型/范围等安全摘要。Control Plane 已新增只读 `GET /admin/audit-logs` 查询契约/API，支持 tenant、actor、action/resource、时间范围与 limit 过滤，归 `AuditRead`，响应再次 secret-safe 清洗。provider/channel/profile/model/model_association 等其他写路径事务化、更多 billing 写操作覆盖和 audit UI 验收尚未完成。

- [~] **E1-005 OIDC 基础登录草案**  
  优先级：P1  
  验收：可通过一个 OIDC provider 登录，role mapping P1 后续完善。当前 Control Plane 已新增 `GET /admin/auth/oidc/authorize-url` 草案切片：从 `AI_GATEWAY_OIDC_*` env 读取 provider、authorization endpoint、client_id、redirect_uri、scopes，生成 OIDC authorization code URL，并强制 authorization endpoint 使用 HTTPS、redirect URI 使用 HTTPS 或本地 loopback HTTP、state/nonce 随机生成、scope 去重且补齐 `openid`；响应明确 `server_state_persisted=true`、`callback_implemented=false`。`GET /admin/auth/oidc/callback` 已校验并消费 server-side state/nonce，区分 missing/expired/invalid/replay/provider mismatch；valid state 后仍不做真实网络请求、不交换 code、不验签 ID token、不创建 session，但会返回 secret-safe exchange/JWKS/session plan-only refusal contract，锁定 token endpoint HTTPS、PKCE/server-side verifier、server-side client auth、JWKS kid/alg/aud/iss/exp/nonce 校验、`user_identities` lookup 与 role mapping 边界；继续拒绝调用方提交 id_token/access_token/email/roles/groups/client_secret/code_verifier 等 claims/token 直接登录，错误体不回显 provider config、code、state、nonce、token、secret 或 claims。OpenAPI skeleton 与 Control Plane auth fixture 已同步。真实 OIDC callback code exchange、ID token/JWKS 验签、`user_identities` 绑定查找后创建 session、role/group claim mapping 尚未完成。

---

## Epic E2：Virtual Key 与 API Key Profile

- [x] **E2-001 实现 Virtual Key 创建/禁用/过期**  
  优先级：P0  
  验收：secret 只显示一次，DB 只存 hash。当前 Control Plane 已实现 `/admin/virtual-keys` create/list/get 和 `/disable`/`/expire`，服务端生成 `vk_...` secret 并只在创建响应返回，DB 持久化 prefix/hash；Admin UI 已接入创建、查询、禁用、过期和一次性 secret 展示，相关单测覆盖 secret/hash 脱敏。

- [x] **E2-002 实现 API Key 鉴权中间件**  
  优先级：P0  
  验收：OpenAI-compatible Authorization Bearer 可用，无效 key 返回兼容错误。当前 Gateway 已强制 Bearer、按 prefix+hash 查 `virtual_keys`，strict compose smoke 已覆盖缺失/有效 key。

- [x] **E2-003 实现 API Key Profile 数据模型**  
  优先级：P0  
  验收：profile 可配置模型别名、可见模型、渠道 tag 限制。当前已落库 `api_key_profiles` 与 `virtual_key_profile_bindings`。

- [~] **E2-004 实现 Profile 切换 Header**  
  优先级：P0  
  内容：`x-ai-profile`。  
  验收：同一 key 使用不同 profile，`/v1/models` 和路由结果不同。当前 Gateway 已读取并校验 `x-ai-profile`，按 key 绑定 profile 解析后用于 `/v1/models` 和 chat route；profile switching + model visibility smoke dry-run 已补，覆盖 profile header、默认/缺失 profile、非法 profile、public/internal 可见性契约，并已接入 `scripts/test.ps1`。

- [~] **E2-005 实现 IP allowlist 和过期检查**  
  优先级：P0  
  验收：被拒绝请求不进入上游调用。当前 Gateway 已做 key 过期/禁用拒绝；IP allowlist 第一切片已接入：使用 ConnectInfo TCP peer IP，不信任未授权的 `X-Forwarded-For`/`X-Real-IP`；读取 `virtual_keys.ip_allowlist`，空列表允许；支持单 IP/CIDR IPv4/IPv6；非法条目忽略且不放行；拒绝时返回 OpenAI-compatible 403 `api_key_ip_forbidden`，不创建 `request_logs`/`provider_attempts`，不进入上游。`server.trusted_proxy_allowlist` 已接入：默认空列表，仅当 TCP peer 命中受信代理单 IP/CIDR 时才使用 `X-Forwarded-For` 首个 IP 或 `X-Real-IP`，畸形 forwarded IP 在 auth 阶段拒绝；profile 独立 allowlist 已接入：`api_key_profiles.ip_allowlist` 专用 schema/API/Gateway 读取已落地，key allowlist 先放行、profile allowlist 再收紧，空 profile allowlist 不额外限制，畸形/非法条目不放行；旧版 `request_overrides` 中的 `type=profile_ip_allowlist` policy 仍保持兼容。Admin UI profile create/patch 专用 `ip_allowlist` JSON array 表单已接入，前端阻止 malformed JSON、非数组和非字符串条目提交，列表摘要只展示条目数且不渲染 raw payload/Authorization/secret；live smoke 尚未完成。

---

## Epic E3：Provider、Channel、Key Pool

- [x] **E3-001 实现 Provider/Channel CRUD**  
  优先级：P0  
  验收：支持 endpoint、protocol_mode、tags、priority、weight、timeout。当前 Control Plane 已支持 provider/channel create/list/get/patch/delete，`verify_control_plane_crud_smoke.ps1 -IncludeFullCrud -StrictFullCrud` 已通过；provider/channel endpoint 已新增统一安全校验，默认要求 HTTPS 并拒绝 userinfo、query/fragment、localhost、private/link-local/multicast/unspecified IP 和 metadata IP，Gateway 出站前也会复核；本地 Compose/Helm mock-provider 场景需显式 `AI_GATEWAY_ALLOW_UNSAFE_PROVIDER_ENDPOINTS=true`。

- [~] **E3-002 实现 Provider Key 加密存储**  
  优先级：P0  
  验收：数据库无明文 key，日志 mask。当前 `ai-gateway-auth` 已实现 provider key AES-256-GCM seal/open、HMAC fingerprint 和 redaction；Control Plane 创建接口已用 env master key 加密提交的 secret，拒绝调用方传入 `encrypted_secret`/fingerprint 和后续 secret patch，响应不回显密文或 fingerprint，Admin UI 已接入创建/状态管理；Gateway 已按路由选择 provider_key_id、读取 sealed provider key、用 env master key 解密并向上游注入 Authorization，`request_logs`/`provider_attempts` 已记录 `provider_key_id`；dev seed/Compose/env 已配置 dev sealed key，provider key runtime smoke 脚本与 fixture 已新增并接入 `scripts/test.ps1` 和 CI dry-run，dry-run 已校验 gateway/control-plane master key 一致、dev seed sealed payload 可由 Compose master key 打开，fixture fingerprint 不直接打印，seed payload parser 不再依赖固定字段顺序；retry/fallback strict live fixture/dev seed 已覆盖 429/5xx/timeout/EOF models/routes/provider keys，并已在子 Agent 环境通过。主线程本机无 Docker，仅复跑 dry-run；同 channel retry 多 key 策略、运行态错误后的 key 状态迁移/轮换和密钥查看审计尚未完成。

- [~] **E3-003 实现 Channel 手动测试**  
  优先级：P0  
  验收：可选择模型测试，不计入用户账务。当前 Control Plane 已新增 `POST /admin/channels/{id}/manual-test` dry-run 契约，可选择 requested/upstream model 并返回 channel/provider/request plan，明确 `upstream_call=false`、`billable=false`、`ledger_write=false`，OpenAPI 与 contract fixture 已补且单测验证不暴露 provider key secret/fingerprint；Admin UI Provider/Channel 管理页已接入 channel manual test dry-run 表单，可选择 requested/upstream model，经 same-origin API wrapper 调用并展示 channel/provider/request plan 与 non-billable flags，结果展示不展开 provider key secret/fingerprint/raw payload。真实非计费上游 probe 尚未完成。

- [~] **E3-004 实现 Key 状态机**  
  优先级：P0  
  状态：enabled/degraded/cooldown/recovery_probe/auth_failed/quota_exhausted/manual_disabled。  
  验收：429/auth/quota 错误正确改变状态。当前 DB 约束和 routing 过滤支持状态枚举；Gateway runtime 已接入 provider key 状态 best-effort 写回，覆盖非流式 chat/responses/embeddings、Gemini native passthrough 和 streaming pre-response adapter error，将 auth/rate-limit/quota-like/server retry-after/timeout 映射到 `auth_failed`、`cooldown`、`quota_exhausted`、`degraded`，并通过 tenant/channel/provider/key 限定更新、跳过 `manual_disabled`/`deleted`，metadata 仅记录结构化状态摘要且不含 provider secret、Authorization 或 payload body；Control Plane provider key read/patch contract 已锁定，PATCH 仅允许人工进入 `enabled`/`manual_disabled`/`degraded`/`recovery_probe`，禁止直接进入 runtime-managed `auth_failed`/`quota_exhausted`/`cooldown` 和 `deleted`，响应/audit 不返回 secret/fingerprint/current_window_state。真实恢复闭环、轮换策略、channel-level 状态和 live 验收矩阵尚未完成。

- [~] **E3-005 实现恢复探测 Worker**  
  优先级：P0  
  验收：cooldown 到期后探测成功自动恢复，失败继续冷却。当前 `ai-worker recovery-probe` 默认 dry-run，已能列出到期 `cooldown` 与 `recovery_probe` provider key 候选，输出不发起上游调用的 JSON probe plan；执行模式必须显式 `--execute`/`--live` 才启用，已抽出 probe/status-writer trait 与 mocked tests 覆盖成功恢复 `enabled`、失败继续 `cooldown` 或保留 `recovery_probe`、状态更新错误脱敏，并新增 `tests/fixtures/worker/recovery_probe_contract.json` 自测锁定 cooldown/recovery_probe 到期候选、success -> enabled、failure -> cooldown 保持、recovery_probe failure preserving status 和状态更新错误脱敏契约。plan/report 不读取/解密/输出 provider secret、fingerprint、raw metadata/current_window_state，不做账务写入；endpoint/alias/error 等展示字段会脱敏。真实上游 probe 上下文、非计费探测请求和 channel-level 恢复状态机尚未完成。

- [~] **E3-006 实现 provider/channel/key health dashboard API**  
  优先级：P0  
  验收：展示健康分、最近错误、冷却时间、成功率。当前 Control Plane 已新增 `GET /admin/providers/health-summary` 后端切片，汇总 provider/channel/provider_key/model 状态、health score/state、冷却时间、request log bounded sample 统计、最近错误和按 `window_minutes`/`sample_limit` 约束的窗口成功率；OpenAPI 与 contract fixture 已补，响应不返回 endpoint、provider metadata、provider key metadata/current_window_state、encrypted secret、fingerprint 或 raw key，并对展示字符串做 secret-like sanitizer；已新增 `POST /admin/provider-keys/{id}/recovery` 手动恢复最小 API，归 `KeyManage`，仅允许 `cooldown`/`degraded`/`recovery_probe` 安全来源进入 `recovery_probe` 或 `enabled`，写事务化 audit，不读取/返回 provider secret、fingerprint、current_window_state 或 raw metadata，且不执行真实上游 probe、request log 或账务写入；Admin UI Overview 已接入该 summary、窗口成功率摘要和 provider key recovery action。实时 probe/健康分刷新、真实非计费上游恢复 probe 和更完整时间窗口趋势图尚未完成。

---

## Epic E4：Model Catalog 与 Association

- [~] **E4-001 实现 Canonical Model 表和 CRUD**  
  优先级：P0  
  验收：能力标签、上下文、可见性、默认价格可配置。当前 schema 和 Control Plane 已支持 canonical model create/list/get/patch/delete，strict full CRUD smoke 已通过；默认 price book selector 已在 schema/Gateway rate path 中接入（profile > project > tenant > canonical model），并有 pricing fixture/单测覆盖生效版本选择；Control Plane backend dry-run 第一切片已支持 project/profile/requested_model/canonical_model 输入并返回候选、选择和 snapshot，dry-run OpenAPI/fixture 非 UI 契约已接入；Control Plane canonical model 默认 price book selector 已补 read/create/patch 字段、tenant/canonical model/price book 关系校验、secret-safe 写审计 metadata 和 OpenAPI/fixture 契约；clear-null、事务化合并审计、默认价格配置 UI、dry-run UI 和 live smoke 尚未完成。

- [~] **E4-002 实现 Model Association**  
  优先级：P0  
  内容：explicit channel、channel tag、regex、priority。  
  验收：同一 canonical model 可对应多个渠道。当前 schema、Control Plane CRUD 和 Gateway DB routing 已支持 explicit/channel_tag/model_pattern/global 候选语义，strict routing smoke 已覆盖 explicit channel；多候选/fallback/dry-run 验收尚未完成。

- [~] **E4-003 实现 Channel Model Mapping**  
  优先级：P0  
  内容：upstream model name、prefix trim、大小写策略。  
  验收：OpenRouter 风格 provider/model 前缀可处理。当前 Gateway routing 已按 `model_associations.upstream_model_name` 或 `channels.model_mappings` 改写 upstream model，并由 strict routing smoke 验证日志落库；routing crate 已新增 channel mapping policy 纯函数切片，覆盖 explicit mapping 优先、prefix trim、preserve/lower/upper 大小写策略和空/非法 policy 稳定行为；Gateway runtime 已读取 `ma.upstream_model_name` 与 `channels.model_mappings`，复用 routing policy 解析/映射，兼容旧版 `{ "model": "upstream" }` 显式映射和 `explicit_mappings`/`trim_prefixes`/`case_policy`，映射后的 upstream model 会进入上游 request model、request log 和 provider attempt。live smoke 与更多 provider 风格 mapping 验收尚未完成。

- [~] **E4-004 实现 `/v1/models` 可见性过滤**  
  优先级：P0  
  验收：不同 key/profile 返回不同模型列表。当前 Gateway 已按默认 profile allow/deny 过滤并通过 strict smoke；profile switching + model visibility smoke dry-run 已补，覆盖 `x-ai-profile` 切换、默认/缺失 profile 行为、非法 profile 拒绝和 public/internal 可见性契约。

- [~] **E4-005 实现 Model Association Dry-run**  
  优先级：P0  
  验收：输入 key+model，输出候选渠道和过滤原因。当前 Control Plane backend 已新增 `POST /admin/model-associations/dry-run` 第一切片，支持 project/profile/requested_model/canonical_model dry-run，返回 route candidates、selection 和 snapshot；不发起上游请求、不暴露 provider key secret，也不评估真实 provider key 可用性或 rate-limit。`examples/openapi_admin_skeleton.yaml` 已补充 dry-run schema，`tests/fixtures/control-plane/model_association_dry_run_contract.json` 已补 selected/no-candidate fixture，control-plane 测试已检查 fixture 不含 secret material；dry-run response/OpenAPI/fixture 已暴露 `fallback_allowed`，targeted tests 已通过；Admin UI 已在 Routing 与 Models 页面复用 dry-run 表单/结果展示，显示 candidates、selected、`fallback_allowed`、过滤原因和 route snapshot 摘要，并通过 secret-safe sanitizer 避免渲染 Authorization、secret、payload/raw snapshot；live smoke 和更完整 key 输入验收尚未完成。

---

## Epic E5：Data Plane Gateway 与协议入口

- [x] **E5-001 实现 Gateway HTTP server**  
  优先级：P0  
  验收：`/healthz`、`/readyz`、`/metrics` 可用，Compose smoke 已覆盖；Gateway 请求体大小限制已前置到 Axum `DefaultBodyLimit`，不再在 `Bytes` extractor 后才检查；Gateway CORS 已从 permissive 改为 `AI_GATEWAY_CORS_ALLOWED_ORIGINS` allowlist；Gateway/Control Plane `readyz` 已收窄为可用性摘要，不暴露 database driver、Redis 地址、upstream URL 或数据库错误原文。

- [x] **E5-002 实现 OpenAI Chat Completions 非流式**  
  优先级：P0  
  验收：OpenAI SDK 基础请求成功。当前 Gateway 已支持强鉴权、非流式 mock-provider 转发、请求校验、provider 429 JSON 映射，并在上游请求中注入解密后的 provider key Authorization；`verify_sdk_smoke.ps1` 已通过，provider key live strict smoke 尚未完成。

- [~] **E5-003 实现 OpenAI Chat Completions 流式**  
  优先级：P0  
  验收：stream chunk 和 `[DONE]` 正确。当前 Gateway `stream=true` 已路由到 `streaming::chat_completions_streaming`，通过 OpenAI-compatible adapter 透传上游 SSE 并返回 `text/event-stream`，SDK smoke 已支持 `-IncludeStreaming`，`verify_compose_smoke.ps1` 已改为探测 SSE stream；client cancel/backpressure 第一切片已用 pull-based forwarding、bounded chunk/SSE buffer、downstream body drop=`client_cancel` 和 no-late-fallback contract 覆盖，stream usage/rating 已有 completed confirmed 写入；`routing.stream_idle_timeout_seconds` 已接入 stream forwarding，idle timeout 会记录为 `stream_end_reason=timeout` 且不做 late fallback；完整 streaming acceptance matrix、live cancel/backpressure smoke 和 usage 估算/estimated 仍未完成。

- [~] **E5-004 实现 OpenAI Responses 基础**  
  优先级：P0  
  验收：文本请求和 stream terminal event 正确。当前 Gateway 已新增 `POST /v1/responses` 非流式基础入口，复用认证、DB 路由、provider key 注入、fallback、request log、metrics、usage rating 和 ledger settle；OpenAI-compatible adapter 已支持 Responses upstream build/parse、usage 映射、非流式 fixture 与 `responses_stream_with_provider_key` 最小 stream 发送入口。`stream=true` 已路由到 `streaming::responses_streaming`，复用 provider key 注入、preauth、request/provider logs、pre-response fallback、Responses terminal usage/rating/settle 和 no-late-fallback stream finalizer；`tests/fixtures/gateway/responses_stream_runtime_contract.json` 已锁定无 501、secret-safe 与 terminal behavior。完整 schema/tool semantics、live smoke 和更深 runtime DB integration 验收尚未完成。

- [~] **E5-005 实现 Embeddings**  
  优先级：P0  
  验收：embedding 请求可路由和记账。当前 Gateway 已新增 `POST /v1/embeddings` 最小切片，复用认证、DB route selection、provider key 注入、request log、metrics、fallback、usage rating 和 ledger settle；已补 embeddings runtime contract fixture/self-test，固定 auth、request log、preauth 与 provider attempt/provider key/upstream 调用顺序，preauth 拒绝不触达上游；OpenAI-compatible adapter 已支持 embeddings upstream build/parse、usage 映射和 fixture，embedding usage 以 input tokens + 0 output tokens 参与定价。live smoke、专用 embedding route/capability 约束和更完整输入 schema 尚未完成。

- [~] **E5-006 实现 Anthropic Messages 基础**  
  优先级：P0  
  验收：非流式和流式可用。当前 `ai-gateway-adapters` 已新增 Anthropic Messages adapter-only 切片；Gateway 已新增 `POST /v1/messages` 非流式最小 runtime contract，复用认证、DB route selection、provider key `x-api-key` 注入、request/provider logs、fallback、usage rating 和 ledger settle，并补 fixture/self-test 固定 auth、request log、preauth、provider attempt/provider key/upstream、usage/rating/settle 顺序；Anthropic Messages streaming runtime 最小切片已接入，`stream=true` 进入 `streaming::anthropic_messages_streaming`，复用 preauth、provider attempt、provider key `x-api-key` 注入、pre-response fallback 和 no-late-fallback stream finalizer，`message_stop` terminal 结束为 completed，`error` terminal 映射 `upstream_error`，invalid JSON/parser 错误映射 `parser_error`，`tests/fixtures/gateway/anthropic_messages_stream_runtime_contract.json` 已锁定无 501 与 secret-safe contract。专用 Anthropic route/capability 约束、live smoke 和更完整 Messages tool/content-block semantics 尚未完成。

- [~] **E5-007 实现 Gemini GenerateContent 基础**  
  优先级：P0  
  验收：文本和基础 stream 可用。当前 `ai-gateway-adapters` 已新增 Gemini GenerateContent adapter-only 切片，支持非流式 `POST /v1beta/models/{model}:generateContent` build、body 字段保留、usageMetadata 映射、provider status/invalid JSON/retry-after error mapping 和 stream event JSON fixture；adapter 对 path model segment 做安全校验。Gateway 已接入 Gemini `streamGenerateContent` native streaming 最小 runtime，支持 path `:streamGenerateContent`、body `stream=true` 或 `streamGenerateContent=true` 进入 `streaming::gemini_generate_content_streaming`，复用认证、DB route selection、request log、preauth、provider attempt、provider key `x-goog-api-key` 注入、pre-response fallback 和 no-late-fallback finalizer；`finishReason` terminal 映射 completed，`error` terminal 映射 `upstream_error`，invalid JSON/parser 错误映射 `parser_error`，`usageMetadata` 完整时可进入 stream rating/settle。专用 Gemini route/capability 约束、live smoke 和完整 streaming/tool semantics 尚未完成。

- [~] **E5-008 实现 Native Passthrough 模式**  
  优先级：P0  
  验收：不重建 body，只做鉴权、路由、key 注入、模型名映射。当前 Gateway 已新增 Gemini `generateContent` native passthrough 最小切片：`/v1beta/models/{model}:generateContent` 复用鉴权、DB route selection、provider key 注入、fallback、request/provider logs、metrics、usage rating 和 ledger settle；body 无需改写时保留原始 bytes，需要模型映射时仅改写顶层 `model`，并记录 request/upstream body hash；上游错误会脱敏 provider key，非 JSON 错误只落 hash；Gemini `usageMetadata` 已进入计费，缺少 `candidatesTokenCount` 时可由 `totalTokenCount - promptTokenCount` 兜底。`streamGenerateContent`/`stream=true` 已从旧 501 改为 native streaming runtime，并继续保持不重建 body、仅在模型映射时改写顶层 `model`；通用 native protocol_mode 选择、非 Gemini provider 和 live smoke 尚未完成。

---

## Epic E6：Adapter 与协议转换

- [~] **E6-001 定义 Adapter interface**  
  优先级：P0  
  验收：extract routing fields、build upstream、parse response、parse stream、map errors、extract usage。当前 `crates/adapters` 已定义 adapter contract、routing fields、upstream request、usage、error mapping 与协议级 stream parse 合约；OpenAI/Anthropic/Gemini/MCP fixtures 已纳入 conformance harness。Gateway runtime 接线、更深 trait replay 和 live smoke 仍待完成。

- [~] **E6-002 实现 OpenAI-compatible adapter**  
  优先级：P0  
  验收：chat/responses/embeddings/models fixtures 通过。当前 OpenAI-compatible chat 非流式 adapter 已支持请求校验、upstream build、response parse、usage 提取和错误映射；`stream=true` 请求构建、stream event/`[DONE]` parse 和 `chat_completions_stream` passthrough 已接入；Responses/Embeddings 非流式 upstream/parse/usage fixture 已补；Responses stream adapter parse contract 已覆盖 `response.completed` terminal、`response.failed`/`error` error terminal、invalid JSON parser mapping、terminal usage extraction 和 missing usage 不合成；Models list adapter-level 第一切片已覆盖 `GET /v1/models` upstream build/parse、invalid JSON error mapping、`expected_usage=null` 无 usage 合约、`stream=false` 上游合约与 `stream=true` unsupported。Gateway runtime/live smoke 与更深 trait replay 仍待完成。

- [~] **E6-003 实现 Anthropic adapter**  
  优先级：P0  
  验收：messages、content block、message_stop fixtures 通过。当前 `AnthropicAdapter`/`AnthropicMessagesRequest` 已实现 messages 非流式与 `stream=true` adapter contract、routing fields、upstream build、response parse、usage 映射、provider status/invalid JSON/retry-after error mapping，以及 `end_turn`/`stop_sequence`/`max_tokens`/`tool_use` 的稳定 finish reason 映射；`stream=true` 已生成 `POST /v1/messages` 上游请求并保留 body `stream=true`，`AdapterCapabilities.stream_policy` 标记为 parseable streaming；`AnthropicMessagesStreamEvent` 与 `AnthropicStreamTerminalKind` 可解析 Anthropic SSE data 并分类 `message_stop`/`error` terminal，fixtures 覆盖 request/response content block、stop_reason、usage、secret-safe、valid stream request、stream `message_stop` 与 `error` contract。完整 content block/tool semantics、streaming runtime 和 gateway runtime 接线待完成。

- [~] **E6-004 实现 Gemini adapter**  
  优先级：P0  
  验收：generateContent、stream、finish reason fixtures 通过。当前 `GeminiAdapter`/`GeminiGenerateContentRequest` 已支持 generateContent 非流式 adapter contract、routing fields、upstream path/body build、response parse、usageMetadata 映射、provider status/invalid JSON/retry-after error mapping；第二切片已固定 `STOP`/`MAX_TOKENS`/`SAFETY`/`RECITATION`/`OTHER` finishReason 映射，2xx 非流式响应缺失或非法 candidate terminal 会映射为 parser-owned `provider_invalid_response`，`usageMetadata` 支持缺 `candidatesTokenCount` 时由 `totalTokenCount - promptTokenCount` 兜底，secret-safe fixtures 覆盖 valid、fallback 与 terminal error contract；`streamGenerateContent`/`stream=true` adapter build 已生成 `:streamGenerateContent?alt=sse` 上游请求并标记 stream，`GeminiGenerateContentStreamEvent` 可解析 SSE data、识别 `finishReason` terminal 和 error event。完整 schema/tool semantics 和 Gateway runtime 接线尚未完成。

- [~] **E6-005 实现 provider error mapper**  
  优先级：P0  
  验收：429/5xx/auth/quota/network/parser 归一化。当前 routing core 已实现基础分类，并新增 adapter provider error bridge，将 adapter status/transport/retry-after/owner/stage/code 输入归一化为 health impact、same-channel retry 与 fallback decision，fixture 覆盖 429、5xx、auth、quota、network、parser、client request 且输出不含 raw adapter/provider payload 或 credential material；Gateway runtime 接入仍待完成。

- [~] **E6-006 建立 Adapter Conformance Test Harness**  
  优先级：P0  
  验收：每个 adapter 必须跑 fixture，CI 阻断失败。当前 `ai-gateway-adapters` test-only conformance harness 已枚举 OpenAI/Anthropic/Gemini/MCP JSON 与 SSE fixtures，强制 fixture name 全局唯一、valid/error/stream 分类齐备、必要 contract 字段完整、示例不含 secret-like 字符串，并带 synthetic fixture contract self-test；`scripts/adapter_conformance.ps1` 已支持本地/CI 直接执行 focused adapters conformance test，输出逐 adapter 覆盖摘要，提供 `-DryRun` 计划模式与 `-Strict` 全 crate adapters 测试扩展。CI workflow 与 `scripts/test.ps1` 已强制接入 adapter conformance strict，并由 `scripts/test_adapter_conformance_ci_contract.ps1` 自检覆盖；真实网络调用和更深 adapter trait 行为回放尚未完成。

---

## Epic E7：Streaming Engine

- [x] **E7-001 实现统一 SSE parser**  
  优先级：P0  
  验收：大于 64KB event 正常处理，Rust 单测覆盖大 event 与超限拒绝。

- [~] **E7-002 实现 partial_sent tracking**  
  优先级：P0  
  验收：已输出后不 fallback。当前 Gateway `ForwardStreamState.partial_sent` 在首个非 terminal data event 后置位并记录 request/provider TTFT，stream 错误后写 partial 并关闭而不是 late fallback；live fallback/partial acceptance smoke 和 client cancel 场景尚未完成。

- [~] **E7-003 实现 terminal event validation**  
  优先级：P0  
  验收：OpenAI/Responses/Anthropic/Gemini terminal fixtures 通过。当前 `ai-gateway-stream` 已实现四类协议 terminal event 纯函数与单测，Gateway OpenAI Chat streaming runtime 已用 terminal event 判定区分 completed/upstream_eof；已补 Responses/Anthropic/Gemini cross-protocol SSE terminal fixtures，覆盖 completed、failed/error、invalid JSON、missing terminal、split chunk decode 和 EOF end reason 映射，adapter stream/harness focused tests 已通过。Gateway Responses streaming runtime 已接入 Responses terminal observation，completed terminal 进入 completed finalizer，failed/error terminal 映射 `upstream_error`，invalid JSON 映射 `parser_error`；Anthropic Messages streaming runtime 已接入 Anthropic terminal observation，`message_stop` 映射 completed，`error` 映射 `upstream_error`，adapter parser error 映射 `parser_error`；Gemini GenerateContent streaming runtime 已接入 Gemini terminal observation，`finishReason` 映射 completed，`error` 映射 `upstream_error`，adapter parser error 映射 `parser_error`。跨协议 live streaming acceptance matrix 仍待完成。

- [~] **E7-004 实现 stream_end_reason**  
  优先级：P0  
  验收：completed/client_cancel/upstream_eof/parser_error/timeout 可区分。当前 `StreamEndReason`/`StreamEndSignal` 核心判定和 DB `request_logs.stream_end_reason` 新约束已落地，Gateway streaming runtime 已写入 `request_logs.stream_end_reason`、`partial_sent`、`ttft_ms` 和 provider attempt 终态；client_cancel/backpressure focused contract 已覆盖，timeout live 验收、完整 streaming acceptance matrix 和跨协议 runtime 接入仍待完成。

- [~] **E7-005 实现 backpressure 和 client cancel 处理**  
  优先级：P0  
  验收：下游断开取消上游；慢客户端内存稳定。当前 Gateway OpenAI Chat streaming 已通过 `Body::from_stream` 按下游 poll 拉取 upstream，并新增 per-chunk/backing SSE buffer 上限；forward failure contract 明确 response start 后不 late fallback，upstream read error 记 `upstream_error`，decode/oversized chunk 记 `parser_error`；body drop/downstream write failure/client disconnect 会以 `client_cancel` finalization 写 request/provider attempt 终态。focused streaming tests 已覆盖 partial 后 upstream failure、preflight no partial、oversized chunk、bounded buffer failure、body drop=`client_cancel`；live cancel/backpressure smoke 仍缺。

- [~] **E7-006 实现 stream usage reconcile**  
  优先级：P0  
  验收：usage 缺失有估算和 estimated 标记。当前 OpenAI chat/Responses/Anthropic Messages/Gemini GenerateContent streaming completed finalization 已在 terminal 前观察到完整 usage 时写入 input/output tokens、rating、final_cost、currency、price_version_id，并在 completed+完整 usage+非零 cost 时写 confirmed settle ledger entry；缺 usage、不完整 usage、client_cancel、非 completed 或 zero cost 均不会扣费。usage 估算/estimated 标记和 live reconcile smoke 尚未完成。

---

## Epic E8：Routing、Fallback、Health

- [~] **E8-001 实现候选渠道生成**  
  优先级：P0  
  验收：按 model association 和 profile 权限过滤。当前 `ai-gateway-routing` 已新增 `generate_route_candidates` 纯函数切片，支持 explicit channel、channel tag、regex model_pattern、global association、association/channel priority 合成、upstream model override/channel mapping、profile model visibility/channel tag/provider deny 过滤，并复用 selection status/health/rate/zero-weight filter reason；routing fixture 已反序列化覆盖 profile model allow/deny、channel tag allow/deny、provider deny、association `fallback_allowed` 与 filter reasons，并校验候选输出不含凭据/请求体材料。Gateway DB 候选生成接入、真实 provider key/rate 窗口可用性和 request detail UI 展示仍待完成。

- [~] **E8-002 实现 priority + weight 路由**  
  优先级：P0  
  验收：权重分布测试通过。当前 routing core 已实现 priority + deterministic weight 选择；routing crate 纯函数单测已补空候选、禁用/0 权重不吸票、seed 边界分布与重复稳定；待接 DB/Gateway 后补策略验收。

- [~] **E8-003 实现 health-aware filtering**  
  优先级：P0  
  验收：cooldown/manual_disabled/auth_failed 不被选择。当前 routing core 已覆盖 cooldown/recovery_probe/auth_failed/quota_exhausted/manual_disabled/unhealthy 过滤；待接运行链路。

- [~] **E8-004 实现 rate-limit-aware key selection**  
  优先级：P0  
  验收：RPM/TPM/concurrency 超限不被选择。当前 DB schema 与 routing core 具备基础字段/过滤位；routing crate 已新增 rate-limit availability 纯函数，统一评估 RPM/TPM/concurrency 窗口、limit/used/required、有限额缺失 counter、0/缺失 limit、非法限额和负数占用，超限或有限额缺失 counter 候选返回 `RateLimitExceeded` 并保留阻断维度摘要，可将 availability 纯函数结果落到 route candidate/filter/snapshot；单测覆盖未超限可选、RPM/TPM/concurrency 超限、并发占用、0/缺失 limit、有限额缺失 counter 保守阻断、负数 used 归零、非法 limit/required 阻断和 snapshot/filter reason 稳定。运行态窗口计数、并发占用和 Gateway/provider key selection 接入尚未完成。

- [~] **E8-005 实现 retry/fallback engine**  
  优先级：P0  
  验收：500/429/timeout/EOF 按矩阵处理。当前非流式 chat 已对 provider 429/5xx/timeout/EOF/transport 和首字节前错误 fallback 到下一 route candidate，attempt 上限已由 `routing.default_max_attempts` 控制；OpenAI-compatible 与 native passthrough 上游 timeout 已由 `routing.default_timeout_seconds` 控制，HTTP client 已关闭 redirect；非流式 UpstreamRead/body-read 失败已禁止 fallback，避免上游已返回 headers/部分响应后的重复调用/计费；streaming 已支持 pre-response fallback，首个响应输出后不 late fallback；最终成功 route 会回写 `request_logs`，`provider_attempts` 已记录 `fallback_reason` 和 metadata。Gateway `ResolvedChatRoute` 已读取 `model_associations.fallback_allowed`；attempt list 只在追加失败后的 fallback 目标时过滤 `fallback_allowed=false`，初始 selected route 即使 `fallback_allowed=false` 仍可作为首选；streaming 复用同一 `attempt_routes`，因此同步继承限制；测试已覆盖 `chat_attempt_routes_excludes_fallback_disallowed_candidates_but_keeps_selected` 与配置化 attempt cap。`scripts/verify_gateway_retry_fallback_smoke.ps1` 已支持 `-StrictGatewayFallback` 和 `-PreflightOnly`，fixture/dev seed 已新增 429/5xx/timeout/EOF strict live models/routes/provider keys；strict fallback models 已改为 `internal`，默认 profile 不再暴露 strict models，strict preflight 已校验 `public`/`internal` 可见性；retry/fallback smoke 已校验 `request_logs.upstream_model` 与最终 provider attempt 一致，`connection_closed` direct mock-provider 检查已拒绝 DNS/refused 类失败混入。Darwin/Mendel review 项已在主线程修复；Darwin 已在子 Agent 环境跑通 strict live smoke，主线程本机无 Docker，仅复跑 dry-run。同 channel retry、backoff、健康分/cooldown 写回和完整验收矩阵尚未完成。

- [~] **E8-006 实现 route decision snapshot**  
  优先级：P0  
  验收：Request detail 可显示候选、分数、过滤原因。当前 routing core 已有 `RouteDecisionSnapshot`、候选 score/filter/selected 和 trace affinity 决策；已新增 `select_route_from_evaluated` 纯函数入口，routing fixture 已锁定 selected candidate、snapshot summary、score/filter/selected 标记和凭据/请求体安全输出；Control Plane dry-run 第一切片可返回 route candidates、selection 和 snapshot；Gateway DB 候选集、request detail API/UI 接入和真实 provider key 可用性/rate-limit 评估待完成。

- [~] **E8-007 实现 trace affinity**  
  优先级：P0  
  验收：同 trace 优先之前成功渠道。当前 routing core 已支持 previous successful channel affinity，纯函数单测覆盖同 trace 稳定命中、前序渠道不可选 fallback、空候选 not-candidate 和不同 trace pin 到不同渠道；待接 Gateway/DB trace 成功渠道记忆。

---

## Epic E9：Billing Ledger

- [x] **E9-001 实现 Wallet/Credit/Budget 数据模型**  
  优先级：P0  
  验收：项目/Key 预算可配置。当前迁移已包含 `wallets`、`credit_grants`、`budgets` 和约束。

- [~] **E9-002 实现 Price Book / Price Version**  
  优先级：P0  
  验收：修改价格产生新版本，历史不变。当前已落库 `price_books`、`price_versions`；Gateway 已按 profile/project/tenant/canonical model selector 解析 active/effective price version，并对非流式 usage 写入 `final_cost`、`currency`、`price_version_id`；Control Plane 已新增最小 `POST /admin/price-versions` create 切片，归 `BillingAdjust`，校验 price book currency、canonical model、rate schema 和可选 `retired_at`，拒绝 payload/secret/raw key 字段，并与 success audit 同事务写入。Admin UI 已接入 price version 创建表单和列表刷新；supersede/retire 工作流、账本调整/退款体验和 stream usage rating 待实现。

- [~] **E9-003 实现 pre_authorize**  
  优先级：P0  
  验收：余额不足不调用上游。当前 Gateway 已在非流式 chat/responses/embeddings、streaming chat 和 Gemini native passthrough 的 provider attempt/provider key/upstream 调用前执行 pre_authorize；余额或预算明确不足时返回 OpenAI-compatible `402 billing_insufficient_balance`，回写 request log 失败状态，不创建 provider_attempt、不打开 provider key、不调用上游，错误响应不包含 wallet/budget/id/金额/secret 细节；已新增 dry-run runtime contract fixture/self-test，固定 request_logs rejected-only、provider_attempts 不创建和 provider key/upstream 不触达顺序。pre_authorize 使用 active price version 估算 fixed request cost 和 billable usage rate，读取 project/tenant wallet、active credit grants、pending/confirmed ledger debit/credit 与 tenant/project/virtual_key budgets；缺价格、缺 wallet/budget 或读取异常时 best-effort 放行，避免破坏现有成功路径。reserve、强一致余额扣减、并发防超卖和真实 DB integration 验收尚未完成。

- [~] **E9-004 实现 reserve/settle/refund ledger**  
  优先级：P0  
  验收：幂等 key 生效，重复 settle 不重复扣。当前 DB 已验证重复 settle 被拒绝；非流式 chat 成功链路已在 usage/rating 完整且 `final_cost` 非 0 时 best-effort 写入 confirmed settle ledger entry，幂等 key 为 `settle:{request_id}`；billing-ledger 已新增 reserve/settle/refund contract plan 纯函数，固定 `reserve:{request_id}`、`settle:{request_id}`、`refund:{related_ledger_entry_id}`、`refund_partial:{related_ledger_entry_id}:{refund_operation_id}` 幂等 key，reserve 生成 pending debit，settle 生成 confirmed debit 并计划反转同 request pending reserve，重复 reserve/settle/full refund/partial refund 幂等返回，非幂等重复 settle 与同 refund key 不同金额被拒绝；第二切片已新增 `tests/fixtures/billing/reserve_settle_refund_ledger_contract.json` fixture 回放，覆盖 reserve pending -> settle confirmed -> partial/full refund、重复请求幂等、非法重复 settle/refund 拒绝和 metadata secret-safe。runtime reserve/refund writer、余额扣减和真实 DB integration 验收仍待完成。

- [~] **E9-005 实现 usage rating engine**  
  优先级：P0  
  验收：input/output/cache/reasoning token 可计价。当前非流式 chat rating 已写入 request `final_cost` 并供 settle ledger metadata 使用；stream request-log rating 已接入 completed+usage 完整路径；billing-ledger 纯函数已支持 cache/reasoning token rate 计价，runtime usage 提取/调用点未接入。

- [~] **E9-006 实现 daily reconciliation job**  
  优先级：P0  
  验收：ledger 和 request usage 差异报告。当前已新增只读 daily reconciliation report 基础：billing-ledger 纯函数按 request `final_cost` 推导期望 settle debit，对比 `ledger_entries` 中 settle/refund 的 pending/confirmed 汇总，输出缺失、意外、金额不匹配、币种不匹配摘要和差异明细；Control Plane 已挂载 `GET /admin/billing/reconciliation` 并用 `BillingRead` RBAC，fixture/OpenAPI 已补，report 展示字段会脱敏且不含 payload/secret。Worker 已新增 `ai-worker billing-reconciliation --dry-run --input ...` plan-only 切片，生成 daily scheduler/window/scope/report contract，并补 daily scheduler/window 第二切片：可按 `scheduler.now_utc` 推导上一个完整 UTC day，输出 closed-open UTC window、last-run/watermark contract，默认不写 DB、不发 webhook；DB scheduler/read plan contract 已扩展为 mockable repository 契约，固定 `read_scheduler_state`/`read_reconciliation_batch`、last-run/watermark state read query、cursor closed-open bounds、Postgres `request_logs`/`ledger_entries` 只读查询 skeleton、project filter 参数、bounded batch/has-more/resume cursor 和 payload/header/provider/wallet/DB URL omission，仍不连接 DB、不写 DB、不发送告警，`--execute`/`--send` 当前需 `--force` 且明确拒绝 future live DB reader/writer 与 alert sender；plan serialization 会去除 request/header/provider/wallet/scheduler/DB URL credential material。真实 live DB scheduler 读取、Postgres integration test、真实 alert send 和自动调度尚未完成。

---

## Epic E10：Observability、Logs、Metrics

- [~] **E10-001 实现 request log 和 provider attempts**  
  优先级：P0  
  验收：每次上游尝试独立记录。当前 Gateway 调用链已写入 `request_logs` started/final 和 `provider_attempts` started/final，并落库 canonical/upstream/provider/channel/provider_key_id/route policy；`verify_gateway_routing_smoke.ps1 -StrictGatewayRouting` 覆盖了 mock-provider 非流式成功链路，streaming runtime 已写入 partial/end reason/TTFT 终态；retry/fallback 第一切片已在 fallback 到下一 route candidate 时记录每次 provider attempt、`fallback_reason` 和 metadata，并在最终成功时回写 request log route。同 channel retry、backoff、健康分/cooldown 写回和完整失败链路验收尚未完成。

- [~] **E10-002 实现 Thread/Trace/Request 模型**  
  优先级：P0  
  验收：同 trace 请求可聚合。当前 request/trace/thread 字段和索引已落库；Control Plane 已新增 `GET /admin/traces/{trace_id}` 只读 trace summary API，按 tenant+trace 查询 bounded request summaries，默认 limit=50/最大 500，走 `LogReadMetadata` RBAC，响应只返回请求元数据、hash、token/cost 汇总和错误摘要，不返回 payload body/object ref 或 route snapshot，并对字符串做 secret redaction；request detail 与 trace summary 已新增 bounded ledger summary：按 tenant/request_id 读取 ledger rows，只返回 entry type/status/amount/currency/request/time 等摘要，省略 idempotency_key、usage_snapshot、policy_snapshot、metadata、payload/body/raw metadata；OpenAPI 与 contract fixture 已补。Admin UI 已接入 Trace ID 查询与 summary 展示；payload 懒加载和更完整 trace drilldown 仍待完成。

- [~] **E10-003 实现 payload policy**  
  优先级：P0  
  验收：metadata_only/hash/redacted/full 策略生效。当前 schema 有 payload policy 字段，Gateway 已写请求/响应 body hash；`ai-gateway-observability` 已新增 payload policy 纯函数切片，支持 bytes/JSON 输入和 `metadata_only`、`hash/hash_only`、`redacted`、`full`、`sampled` 决策，未知/空策略默认退回 hash，不泄露 raw payload，redacted/sample preview 复用现有 payload redaction，只有显式 `full` 才返回 raw payload。Gateway runtime 第一切片已按 active profile payload policy/default policy 选择策略，并在 `request_logs` 写入 `payload_policy_id`、`redaction_status`、hash/redacted preview 安全 metadata；默认仍不存 raw payload，显式 `full` 在未接对象存储前降级为 hash marker 并记录 fallback reason，避免 secret-like 内容进入日志/fixture。payload 对象存储、懒加载 API/UI 和 sampled runtime 仍待完成。

- [~] **E10-004 实现 Prometheus metrics**  
  优先级：P0  
  验收：requests/errors/latency/ttft/cost/fallback 可 scrape。当前 `/metrics` 保留 service gauge，并已接入 Gateway runtime requests/errors/latency histogram/fallback/cost 指标；label 低基数且会拒绝 secret-like/unbounded label 值，非流式、stream finalizer 和 fallback 路径已有单测覆盖；已新增 `ai_gateway_request_ttft_ms` Prometheus histogram，streaming finalizer 仅在存在 request TTFT 时记录 `_bucket/_sum/_count`，labels 限定为 `endpoint/method/status/status_class/outcome/error_owner/error_code` 并复用 bounded label sanitizer，非流式路径不记录 TTFT。provider/channel/key 维度、更多 endpoint 和外部 metrics backend 尚未完成。

- [~] **E10-005 实现 alert webhook**  
  优先级：P0  
  验收：错误率、key cooldown、ledger lag 告警。当前 Control Plane 已新增 `POST /admin/alerts/webhook/dry-run` 最小 validate-only 切片，使用 `ProviderManage` RBAC，校验 HTTPS URL、拒绝 userinfo/localhost/private/link-local/multicast/unspecified literal IP 和可疑内部域名，响应只返回 URL path/query、headers、secret 与 payload 的脱敏摘要且不发送出站请求；header secret-like 名称也会拒绝且错误不回显。Worker 已新增 `ai-worker alert-webhook` plan-only dry-run 切片，可从 input JSON 或 `AI_GATEWAY_ALERT_WEBHOOK_*` env 读取 webhook 目的地并生成错误率、provider key cooldown、ledger lag 三类稳定 alert contract，同时输出真实发送前 preflight contract：URL SSRF guard 顺序、DNS 解析后 SSRF 复查 contract、managed/custom header redaction、metadata-only payload body redaction、timeout/retry bounds、would-send transaction shape 和 sender/error sanitization；默认不发送网络请求，`--send/--execute` 在当前切片仍需 `--force` 且明确拒绝，模块内 sender trait 会拒绝 network-capable sender，DNS resolver 只接收 host 且任一解析 IP 为 localhost/private/link-local/multicast/unspecified 都拒绝，force 也不能绕过 DNS 复查或触发 live network；输出会脱敏 URL path/query、secret/header 值、provider key-like 输入和 payload/body 原文，模块内 mock sender 已覆盖成功、失败重试、SSRF validation-before-send、DNS resolved-IP recheck、secret-safe transaction serialization 和 force/network-disabled gate。OpenAPI skeleton、Control Plane contract fixture 与 Worker contract fixture 已补。配置持久化、真实 HTTP webhook sender、真实 timeout/retry 执行、真实数据源驱动的告警规则触发尚未完成。

- [~] **E10-006 实现 OpenTelemetry exporter**  
  优先级：P1  
  验收：trace/metrics/logs 可导出。当前 `ai-gateway-observability` 已新增 OTEL 配置解析与 no-op 初始化切片，并由 `tests/fixtures/observability/otel_exporter_contract.json` contract 锁定 disabled/stdout/otlp endpoint 形态、标准/项目 env 变量、service/resource attributes sanitizer、OTLP endpoint 校验、endpoint/userinfo/query secret 脱敏和 `sdk_pipeline_enabled=false` 边界；配置错误会脱敏 embedded userinfo、secret-like exporter 值和 endpoint secret，初始化仍不接 runtime、不安装 SDK provider、不发网络请求。真实 OpenTelemetry SDK pipeline、Gateway/Control Plane 入口接入、trace/metrics/logs 实际导出和 collector smoke 尚未完成。

---

## Epic E11：Admin UI

- [~] **E11-001 初始化 Admin UI**  
  优先级：P0  
  验收：登录、导航、权限菜单。当前 Admin UI 已接入真实 `/admin/auth/login`/logout，默认通过 HttpOnly Cookie 保持会话，并已在登录后读取 `/admin/auth/me` 的 secret-safe `capability_summary.capabilities`/`denied_capabilities` 裁剪导航与 Providers 关键操作入口，覆盖 Viewer/Billing/Ops 菜单差异；会话持久化/刷新和更完整配置页面仍待完成。

- [~] **E11-002 Provider/Channel 管理页面**  
  优先级：P0  
  验收：CRUD、测试、启停、错误提示。当前 Provider/Channel 管理页第一切片已完成并进入后续打磨：UI 支持 list/create/disable/delete providers/channels 与核心字段表单，并已为 channels 接入 manual test dry-run 表单/结果摘要（requested/upstream model、same-origin wrapper、channel/provider/request plan、non-billable flags，secret-safe 不显示 provider key secret/fingerprint/raw payload），API client/test/App tests 已覆盖；Admin UI 已对 ModelsPage、RoutingPage、RequestLogsPage、BillingPage 和 VirtualKeysPage 做 lazy-load，bundle check 以 initial JS 为预算口径，当前 Initial JS 240.6 KiB/250.0 KiB、Lazy JS 86.0 KiB、Total JS 326.6 KiB，`check:bundle` 通过。provider metadata/channel advanced JSON policy fields、full CRUD polish 尚未完成。

- [~] **E11-003 Model Catalog/Association 页面**  
  优先级：P0  
  验收：模型、关联、mapping、dry-run。当前 lazy-loaded ModelsPage MVP 已支持 canonical model 与 model association list/create/disable/delete，并在模型页接入 model association dry-run 联动，可使用现有 catalog 作为 canonical model key/id 选择来源展示 candidates、selected、fallback 和过滤原因；API wrapper 和 App tests 已覆盖 secret-safe dry-run 展示；advanced association 条件、mapping polish 和 live smoke 尚未完成。

- [~] **E11-004 Virtual Key/Profile 页面**  
  优先级：P0  
  验收：创建 key、profile、预算、模型权限。当前 Admin UI 已有 Virtual Keys/Profile 页，支持 profile list/create/patch/delete、virtual key list/create/get/disable/expire；本切片已新增 profile visible/denied model、model alias 与专用 IP allowlist JSON create/patch 表单、列表摘要展示，virtual key rate-limit/budget policy 安全 JSON 占位与摘要/详情展示，并统一剔除 secret/Authorization/raw payload/body 等 unsafe JSON 字段；创建 key 后仅在创建结果区域一次性展示服务端返回 secret，列表/详情/JSON 摘要不再渲染一次性 credential 原文。更完整预算工作流、专用 budget schema 表单和 profile 其他策略字段编辑仍待完成。

- [~] **E11-005 Request/Trace 页面**  
  优先级：P0  
  验收：查询、详情、route trace、ledger、payload 懒加载。当前 Admin UI 已将 Request/Trace workspace 接入导航并改为 lazy-loaded `RequestLogsPage`，复用 same-origin request log list/detail API wrapper；页面已新增 Trace ID 查询，调用 `GET /admin/traces/{trace_id}` 展示 trace summary metrics、last error、时间范围、currency 和 bounded request rows；request detail 保留 provider attempts，并新增 secret-safe Route Trace 摘要，仅展示 route policy、strategy、selected channel、candidate/filter 数和 snapshot version，不渲染 raw snapshot/payload/secret；request detail 与 trace summary 已展示 ledger summary rows（entry/status/amount/request/time），不渲染 idempotency key、usage/policy snapshot、metadata、payload、secret 或 Authorization；前端测试覆盖 route/trace/ledger 字段脱敏。payload 懒加载和更完整 trace drilldown 仍待完成。

- [~] **E11-006 Health Dashboard**  
  优先级：P0  
  验收：provider/channel/key/model 状态、手动恢复。当前 Overview 保留服务探针，并已接入 `GET /admin/providers/health-summary` 渲染 provider/channel/key/model 健康矩阵、recent error、score、route count 和窗口成功率摘要；provider key recovery action 已调用 same-origin `POST /admin/provider-keys/{id}/recovery`，展示 pending/success/error 状态，并保持 secret-safe 不渲染 provider secret、fingerprint、current_window_state 或 raw metadata。真实非计费上游恢复 probe、实时 probe 刷新和更完整成功率时间窗口图仍待完成。

- [~] **E11-007 Billing/Price 页面**  
  优先级：P0  
  验收：价格版本、账务流水、对账报告。当前后端已新增只读 `GET /admin/price-versions`、`GET /admin/ledger/entries` 和 `GET /admin/billing/reconciliation`，均归 `BillingRead`、带 limit/filter 校验和 secret/payload-safe JSON 输出；Request/Trace detail 侧也已复用 ledger 只读摘要能力串联 request_id 关联账本行，但仍不暴露 Billing 页完整 usage/policy/metadata；并新增最小 `POST /admin/price-versions` create 写 API，归 `BillingAdjust`、可持久化 `effective_at` 与可选 `retired_at`，写入事务化 audit；Admin UI reconciliation report API/client/UI 已接入 lazy-loaded Billing/Prices workspace，支持 Price Versions、Ledger Overview、Reconciliation 三个 tab 的 list/filter/detail/report 展示，并保持 bundle budget；Admin UI price write 第一切片已接入，支持创建 price version 表单（price_book_id/canonical_model_id/version/effective_at/retired_at/status/pricing_rules JSON）、same-origin `POST /admin/price-versions`、成功后刷新列表，并对 pricing_rules 输入/展示拒绝或移除 payload/secret/Authorization/raw key 等 unsafe JSON 字段。账本调整/退款工作流和更完整财务审计体验仍待完成。

---

## Epic E12：Migration Importer

- [x] **E12-001 New API 配置解析器**  
  优先级：P0  
  验收：样例 dump 可解析；当前最小切片已支持 New API 风格 provider/channel/model/key dry-run 解析。

- [x] **E12-002 One API 配置解析器**  
  优先级：P0  
  验收：样例 dump 可解析；当前最小切片已支持 One API 风格 channel/provider/model/key/model mapping dry-run 解析。

- [x] **E12-003 映射为内部模型**  
  优先级：P0  
  验收：模型映射转 canonical + association + channel mapping；当前已新增内部模型映射 dry-run report，可读取 New API/One API importer JSON report，输出 canonical model、model association、channel mapping、conflicts、manual review 和 next steps，不落库、不输出 secret material。

- [x] **E12-004 Dry-run report**  
  优先级：P0  
  验收：列出创建/更新/跳过/冲突/人工确认项；当前最小切片输出结构化 JSON report，包含 counts/providers/channels/models/warnings/unsupported_fields，且不落库、不调用服务。

- [~] **E12-005 Apply + rollback snapshot**  
  优先级：P0  
  验收：导入失败可回滚，可重复执行。当前 `scripts/importers/import-apply-plan.ps1` 已在 read-only plan 基础上新增 PostgreSQL SQL-plan executor 与 rollback journal contract：默认仍为 dry-run，不连接 live DB、不写库；`-Apply` 必须配合 `-Force`，无冲突、source provider/channel 绑定通过且 adapter 支持时只进入 `prepared_sql_plan`，并明确 live PostgreSQL runner 未实现、不会真实写库；输出事务边界、operation id/idempotency manifest、rollback snapshot entry/before-image schema、refusal contract、JSON/SQL operation bundle、`SELECT ... FOR UPDATE` before-image 捕获 SQL、canonical model `ON CONFLICT` upsert SQL、simple channel `model_mappings` JSONB merge SQL、`importer_apply_runs`/`importer_apply_operation_journal` DDL、apply run/operation journal insert SQL plan 和 rollback operation skeleton；rollback execution dry-run plan 已锁定 reverse apply order、operation/run `rolled_back` status SQL skeleton、replay/idempotency contract 与 stale target hash refusal。`tests/fixtures/importers/apply_plan_canonical_only.sample.json` 与 `postgresql_sql_executor_contract.expected.json` 已覆盖无冲突 canonical adapter、rollback journal DDL/insert、rollback execution refusal/replay contract；`tests/fixtures/importers/apply_plan_channel_mapping_bound.sample.json` 已覆盖 source channel binding 给定、无 alias conflict 的 `channel_mapping_entry` SQL plan，包含 before-image `FOR UPDATE`、`channels.model_mappings` patch SQL、rollback journal row 和 channel mapping rollback skeleton；`model_association` 以及复杂 channel mapping policy 仍会因 alias conflict、source channel 到内部 channel/provider 绑定缺失或 adapter 未覆盖被 preflight 阻断；真实 live PostgreSQL runner、事务内 journal 持久化执行和 rollback compensating mutation runner 尚未完成。

---

## Epic E13：安全和合规

- [~] **E13-001 Secret masking middleware**  
  优先级：P0  
  验收：日志不出现 Authorization/API key/Cookie。当前 `ai-gateway-observability` 统一 sanitizer 已被 Gateway 错误路径接入，database error log、adapter error body 和 OpenAI-compatible error body 会脱敏 Authorization/API key/Cookie/token/password/secret，同时保留 `model_key`/`cache_key`/`public_key_id` 等非敏感标识；本轮审查修复已补 Gateway body limit 前置、CORS allowlist、provider endpoint SSRF guard、HTTP redirect 禁用、`readyz` 脱敏和生产配置路径显式化；完整 HTTP middleware 层与更多入口接入仍待完成。

- [~] **E13-002 Provider key encryption**  
  优先级：P0  
  验收：密钥加密，密钥查看审计。当前 `ai-gateway-auth` AES-256-GCM provider key 加密/fingerprint 已实现，Control Plane 创建接口使用 env master key 加密并拒绝明文回显，Gateway 已完成 provider key runtime 第一切片（选择 provider_key_id、解密 sealed key、上游 Authorization 注入、日志关联），provider key runtime smoke 脚本/fixture 已新增并接入 `scripts/test.ps1` 和 CI dry-run，dry-run 已校验 gateway/control-plane master key 一致、dev seed sealed payload 可由 Compose master key 打开，fixture fingerprint 不直接打印，seed payload parser 不再依赖固定字段顺序，provider key 管理写操作已进入 admin audit 第一切片；retry/fallback strict live fixture/dev seed 已覆盖 429/5xx/timeout/EOF models/routes/provider keys，并已在子 Agent 环境通过。主线程本机无 Docker，仅复跑 dry-run；密钥查看审计、轮换流程和运行态状态迁移尚未完成。

- [x] **E13-003 Payload redaction 基础规则**  
  优先级：P0  
  验收：邮箱、token、常见 key 自动脱敏。当前 `ai-gateway-observability` 已提供 payload/json redaction 纯函数切片，覆盖 `serde_json::Value` 递归脱敏、字符串 payload 基础扫描、email、Bearer/API token-like value 和 password/secret/token/authorization/cookie/api_key 等常见敏感 key，并通过单测覆盖 `model_key`、`cache_key`、`public_key_id` 不过度脱敏；Gateway payload policy runtime 已复用该 redaction 生成 request/response redacted preview 安全 metadata，并由 gateway runtime fixture/contract 锁定 email、token、common key redaction 与不存 raw payload。更完整审计查询/UI 懒加载仍待完成。

- [~] **E13-004 供应链扫描**  
  优先级：P0  
  验收：CI 含 secret/dependency/container scan。当前 CI 已运行安全输出 `scan_secrets.ps1`；`.github/workflows/ci.yml` 已加入 `scan_supply_chain.ps1 -SkipNetwork`、`generate_supply_chain_artifacts.ps1`、SHA256 checksum 和 `actions/upload-artifact` 上传；`scan_supply_chain.ps1 -SkipNetwork` 可校验 Cargo.lock source/checksum、npm lock integrity、Dockerfile/Compose image pinning 与 artifact generator/CI 上传 contract（OutputDirectory、upload path、artifact name、`if-no-files-found:error`），缺 Docker/trivy/grype 时 warning/skip；artifact generator 已输出 SBOM/provenance/manifest/checksum，`manifest.json` 已记录离线 dry-run contract、覆盖输入、缺工具策略和剩余缺口，本地 `scripts/test_supply_chain_scan.ps1` 与 `scripts/test_supply_chain_artifacts.ps1` 自检通过。联网漏洞扫描、真实镜像扫描和 digest pinning 尚未完成。

- [~] **E13-005 Prompt Protection**  
  优先级：P1  
  验收：regex mask/reject、scope、命中日志。当前 `ai-gateway-observability` 已新增 prompt protection 纯函数切片，支持 text/json/payload 输入，输出 action、scoped hits、safe_text/safe_json；覆盖 secret-like token、Bearer、password/API key/sensitive fields mask，以及明显 prompt-injection phrase reject，并保留 `model_key`、`cache_key`、`public_key_id` 等公开标识。Gateway 非流式 `/v1/chat/completions` 已接入 runtime preflight，默认 `AI_GATEWAY_PROMPT_PROTECTION=enforce`，支持 `audit`/`disabled`，命中后在 canonical routing、pre_authorize、provider_attempt 和 provider key 解密前返回 OpenAI-compatible `prompt_protection_rejected`，request log 只写 hash 与 action/mode/reason/hit_count/scopes/hit_kinds 安全摘要。Streaming runtime、审计查询/UI 和可配置规则仍待完成。

---

## Epic E14：部署、运维和发布

- [~] **E14-001 Dockerfile 和 Compose**  
  优先级：P0  
  验收：本地和 staging 可启动。当前本地 Compose、Docker release build、smoke 已通过，compose dev 暴露端口已收敛为仅绑定 `127.0.0.1`；Admin UI 镜像已切为生产 build + nginx same-origin `/api/*` 代理，示例 Compose 已挂载 dev seed；staging 未验证。

- [~] **E14-002 Helm Chart**  
  优先级：P0  
  验收：K8s staging 部署成功。当前 Admin UI Helm 默认值已移除浏览器 `VITE_*` cluster DNS，改用容器内 `*_UPSTREAM` 反代；Chart 已补 values schema、资源/探针/Secret/ConfigMap/Ingress/service 引用校验、backend ConfigMap 挂载约束、默认 ServiceAccount token 关闭、RuntimeDefault seccomp、drop ALL 和 `allowPrivilegeEscalation=false`；`python deploy/helm/validate_chart.py --skip-helm --self-test` 静态校验和 contract self-test 通过，缺 Helm 时 lint/template 只 warning。K8s staging 尚未验收。

- [~] **E14-003 Metrics dashboard 模板**  
  优先级：P0  
  验收：Grafana/Prometheus 可导入。当前 `examples/observability` dashboard/rules 已对齐真实 E10-004 runtime metrics：requests/errors/latency histogram/TTFT histogram/fallback/cost 及实际 labels；TTFT 面板已接入 `ai_gateway_request_ttft_ms_bucket/_sum/_count`，TTFT p95 alert 仅引用已落地指标；ledger/event lag、key cooldown、provider/channel/key/model 维度均保持 clearly marked pending placeholder，未重新引入未落地查询或 active alert；`validate_templates.py` 可在无 `promtool` 环境下校验 JSON/YAML、metric/label 引用和 pending panel 契约。

- [~] **E14-004 Backup/restore 脚本**  
  优先级：P0  
  验收：staging 恢复演练成功。当前已新增最小 PostgreSQL `scripts/db/backup.ps1` 与 `scripts/db/restore.ps1`，支持 `DATABASE_URL`/显式参数、dry-run/preflight、URL 密码打码、backup overwrite `-Force` 和 restore 默认 dry-run/执行需 `-Force`；`scripts/db/test_backup_restore_scripts.ps1` 已覆盖 `DATABASE_URL` 解析与 URL 编码密码透传、密码打码、缺 `pg_dump`/`pg_restore` warning、restore 默认 dry-run、restore 执行需 `-Force`、backup 路径覆盖需 `-Force`、检查模式不创建 dump 且输出不泄露 secret；既有 release backup gate 仍会跑 `scripts/db/verify_backup_restore_contract.ps1`，缺 DB 参数或 `pg_dump` 时仅 warning，不执行数据库命令。staging 恢复演练尚未完成。

- [~] **E14-005 Release checklist 和 runbook**  
  优先级：P0  
  验收：按 `project/RELEASE_CHECKLIST.md` 发布。当前已有 JSON release gate、release checklist 和 deployment ops runbook；gate 覆盖 format/test/frontend/build/security/backup/helm/smoke，默认只做安全 check/dry-run，支持逗号列表 `-Checks backup,helm,smoke`；JSON summary 已补 `statusPolicy` 区分 pass/warn/fail 与本机缺工具 warning，security gate 已包含 SBOM/provenance/manifest/checksum artifact generation；release checklist/runbook 已补 GitHub 首次 push 前本地收口流程，要求跑 `-Checks security`、`-Checks backup,helm,smoke` 和 `scripts/scan_secrets.ps1`，并明确 backup/helm/smoke dry-run 缺 DB 参数、`pg_dump`、Helm、Docker、`node` 或 `npm` 时使用 `local warning:` 文案、必须在具备工具的环境补跑，显式 runtime smoke 缺必需工具仍 fail。尚未按清单完成 staging 发布验收。

---

## Epic E15：P1/P2 增强

- [~] **E15-001 Request Override 可视化和 dry-run**  
  优先级：P1。当前 Admin UI 已在现有 Routing/Models model-association dry-run 结果中展示 request override 摘要，覆盖 profile request_overrides、payload policy 与 profile IP allowlist 派生信息；Profiles 列表同步展示 request controls 摘要。展示路径复用 secret-safe JSON sanitization，不新增后端 dry-run 参数，不渲染 Authorization、secret、raw payload。真实配置 dry-run/后端 override 模拟执行仍待完成。

- [~] **E15-002 Exact Cache 和 cache billing**  
  优先级：P1
  当前 `ai-gateway-billing-ledger` 已新增 exact cache billing 纯函数合约切片：支持由 matched input tokens 推导 request cache `hit`/`miss`/`partial_hit`，partial hit 会把 cached input tokens 与 billable input tokens 分离，cached input 可按 read policy 免费、折扣 token rate 或固定成本计价，uncached input/output/fixed request 仍按正常请求计价；plan 同时输出 read/write cache operation idempotency keys 与 settle key，ledger metadata 只序列化 cache key hash、cache entry id、策略和 token 摘要，不携带 raw key/payload/secret/idempotency key；`tests/fixtures/billing/exact_cache_billing_contract.json` 已覆盖 hit/miss/partial-hit、免费/折扣/固定读写、幂等 replay、非法 token split 和非幂等重复 settle。Gateway runtime exact cache lookup/store、cache hit response path、对象存储/Redis 后端、pre_authorize/reserve 集成和 live smoke 尚未完成。

- [~] **E15-003 OIDC/SAML 完整集成**  
  优先级：P1

- [~] **E15-004 Coding Agent Profiles**  
  优先级：P1

- [~] **E15-005 ClickHouse Log Store**  
  优先级：P1
  当前 Worker 已新增 `ai-worker clickhouse-log-store --dry-run --input ...` plan-only 切片，复用 `ai-gateway-observability` ClickHouse config/contract 校验并输出 secret-safe ingestion plan，覆盖 bounded queue、backpressure、dedup keys、request_logs/provider_attempts/event_log table mapping、payload policy 和 credential presence；本切片已补 durable queue/WAL contract，输出 WAL directory/segment/record shape、bounded disk budget、enqueue/dequeue/ack/retry idempotency、retention/load safety 和 dedup journal linkage。默认不读写 DB、不写队列、不创建目录/文件、不连接 ClickHouse、不发网络请求，`--execute`/`--send` 需 `--force` 且当前切片仍明确拒绝。真实 ClickHouse writer、DB changefeed/export cursor、durable WAL writer、dedup journal runtime persistence、load/retention smoke 尚未完成。

- [~] **E15-006 MCP Gateway**  
  优先级：P2

- [~] **E15-007 Prompt Registry / Eval Dataset / Shadow Traffic**  
  优先级：P2
  当前 Worker 已新增 `ai-worker prompt-eval-shadow --dry-run` plan-only 切片，输出 prompt registry、eval dataset、payload policy 与 shadow traffic 的 hash/count/label/flag 合约，不读写 DB/对象存储、不调用 Gateway、不发网络请求；Control Plane 已新增 `POST /admin/prompt-eval-shadow/dry-run` validate-only API，归 `ProviderManage`，OpenAPI 与 fixture 覆盖 secret-safe envelope、RBAC 和无副作用 flags。真实 registry/dataset 持久化、UI 配置、Gateway shadow 执行和评测结果写入仍待完成。

---

## P0 里程碑建议

| 里程碑 | 目标 | 完成条件 |
|---|---|---|
| M0 | 工程骨架 | local compose + CI + mock provider |
| M1 | 基础转发 | OpenAI chat non-stream/stream 通过 |
| M2 | 模型和渠道 | Profile + Model Association + Channel Mapping |
| M3 | 路由和流式稳定 | fallback、health、stream engine 通过核心测试 |
| M4 | 账务和观测 | ledger、trace、metrics、request detail |
| M5 | 管理后台 | P0 UI 完成，配置 dry-run |
| M6 | 迁移和验收 | New API/One API importer + P0 验收测试 |
| M7 | Staging RC | load/chaos/security/release checklist 通过 |
