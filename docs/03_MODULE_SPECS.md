# 核心模块详细规格

版本：0.1-dev-start  
日期：2026-06-01

## 1. 模块清单

| 模块编号 | 模块 | P0/P1/P2 | Owner 建议 | 依赖 |
|---|---|---|---|---|
| M01 | Identity & Tenant | P0 | Backend | DB, RBAC |
| M02 | Virtual Key & Profile | P0 | Backend + UI | Identity, Model |
| M03 | Provider/Channel/Key Pool | P0 | Backend + UI | DB, Redis |
| M04 | Model Catalog & Association | P0 | Backend + UI | Provider |
| M05 | Data Plane Gateway | P0 | Backend | Auth, Routing, Adapter |
| M06 | Protocol Adapter | P0 | Backend | Stream Engine |
| M07 | Stream Engine | P0 | Backend | Adapter |
| M08 | Routing & Health Engine | P0 | Backend | Redis, Metrics |
| M09 | Billing Ledger | P0 | Backend | DB, Event Bus |
| M10 | Observability | P0 | Backend + UI | Event Bus, Log Store |
| M11 | Admin UI | P0 | Frontend | Control API |
| M12 | Migration Importer | P0 | Backend | Model, Provider, Billing |
| M13 | Guardrails | P1 | Backend + UI | Request pipeline |
| M14 | Cache | P1 | Backend | Redis, Billing |
| M15 | Enterprise SSO | P1 | Backend + UI | Identity |
| M16 | MCP/Agent Gateway | P2 | Backend | Tool registry, Auth |

## 2. Identity & Tenant

### 目标

提供租户、团队、项目、用户和角色体系。即使 P0 是单租户部署，也必须保留 tenant_id 字段，避免后续改造成本过高。

### 关键对象

- Tenant：部署内最高隔离单位。
- Team：租户内组织单元。
- Project：预算、Key、模型权限的核心归属。
- User：登录主体。
- Role：全局角色与项目角色。
- Service Account：CI/服务端调用主体。

### P0 权限模型

| 角色 | 权限 |
|---|---|
| SuperAdmin | 全部权限，包括系统设置和账务调账 |
| TenantAdmin | 租户内用户、项目、渠道、模型、价格管理 |
| Ops | 渠道、健康、日志、告警，不可调账 |
| Billing | 查看和调整账务，不可查看完整 payload |
| Developer | 创建项目 Key、查看自己项目日志和成本 |
| Viewer | 只读 |

### 验收

- 权限由后端强校验，不依赖前端隐藏按钮。
- 所有管理操作写审计日志。
- API token 和用户登录 session 权限一致进入 policy engine。

## 3. Virtual Key & API Key Profile

### 目标

把 API Key 设计成治理主体，而不是简单 token 字符串。

### 字段

- key_id、tenant_id、project_id、name、hashed_secret、prefix、status、expires_at。
- allowed_models、denied_models、allowed_channel_tags、blocked_provider_ids。
- default_profile_id、rate_limit_policy_id、budget_policy_id、payload_policy_id。
- ip_allowlist、user_agent_policy、created_by、last_used_at。

### API Key Profile

Profile 负责“客户端视角”的行为：

- 模型别名：`gpt-4` -> `canonical/claude-sonnet`。
- 默认协议模式：openai-compatible / native passthrough / adapter transform。
- 可见模型列表模板。
- 请求覆盖模板。
- Trace header 读取规则。
- Payload 存储策略。

### 验收

- 同一 API Key 可切换 Profile。
- `/v1/models` 结果按 Profile 过滤。
- Secret 只在创建时返回一次，DB 只存 hash。

## 4. Provider / Channel / Key Pool

### Provider

代表供应商类型，例如 OpenAI、Anthropic、Gemini、OpenRouter、自定义 OpenAI-compatible。

### Channel

代表一个可路由的上游 endpoint，包含：

- provider_id、endpoint、protocol_mode、region、tags。
- priority、weight、status。
- model mappings、request override、timeout policy。
- health policy、probe policy、quota policy。

### Provider Key

- encrypted_api_key、key_alias、status。
- current_rpm/current_tpm/concurrency。
- daily/monthly quota 或上游余额状态。
- health_score、last_error、cooldown_until。

### 状态机

```text
enabled -> degraded -> cooldown -> recovery_probe -> enabled
enabled -> manual_disabled
enabled -> auth_failed
enabled -> quota_exhausted
```

### 验收

- 429 后 key 进入 cooldown，并尊重 Retry-After。
- auth_failed 不自动快速重试，除非管理员触发或恢复探测策略允许。
- route decision 必须显示 key/channel 被过滤原因。

## 5. Model Catalog & Association

### Canonical Model

字段：model_id、display_name、family、capabilities、context_length、max_output、supports_stream、supports_tools、supports_vision、supports_audio、supports_reasoning、price_book_id、visibility。

### Association

描述 canonical model 可走哪些 channel：

- association_type：explicit channel model、channel tag、regex、global。
- priority：数值越小越优先。
- conditions：租户、项目、profile、region、capability。
- fallback_allowed、canary_percent。

### 验收

- 一个 canonical model 可关联多个渠道。
- association 冲突时有确定优先级。
- 管理后台提供 dry-run：输入 key + model + metadata，输出候选渠道。

## 6. Data Plane Gateway

### 接口

P0 必须支持：

- `/v1/chat/completions`
- `/v1/responses`
- `/v1/embeddings`
- `/v1/models`
- `/v1/messages` 或 Anthropic-compatible path
- Gemini-compatible generateContent path
- `/healthz`、`/readyz`、`/metrics`

### 热路径要求

- 不执行未索引 DB 查询。
- 配置缓存命中率目标 > 99%。
- 关键配置版本化，日志记录 config_version。
- 所有外部调用有 timeout、idle timeout、max body size。

## 7. Protocol Adapter

### Adapter 合同

每个 adapter 实现：

- identify inbound request。
- extract routing fields。
- validate minimum schema。
- build upstream request。
- parse non-stream response。
- parse stream events。
- map provider errors。
- extract usage。

### 禁止事项

- 不允许 adapter 自己实现一套不受控 stream scanner。
- 不允许吞掉 provider 原始错误。
- 不允许无记录地丢弃 request/response 字段。

## 8. Stream Engine

详见 `docs/06_ROUTING_STREAMING_SPEC.md`。

## 9. Routing & Health Engine

### 路由评分输入

- priority、weight。
- health_score。
- recent error rate。
- p50/p90/p99 latency。
- RPM/TPM/concurrency。
- cost。
- project/profile preference。
- session/trace affinity。

### 输出

- selected channel/key。
- candidate list。
- filtered reasons。
- scores。
- fallback chain。

## 10. Billing Ledger

详见 `docs/07_BILLING_LEDGER_SPEC.md`。

## 11. Observability

详见 `docs/08_OBSERVABILITY_SPEC.md`。
