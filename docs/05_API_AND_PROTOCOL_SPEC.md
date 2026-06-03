# API 与协议兼容规格

版本：0.1-dev-start  
日期：2026-06-01

## 1. API 设计原则

- Client-facing API 优先兼容 OpenAI SDK，同时支持 Anthropic / Gemini native path。
- Admin API 与 Data Plane API 分离。
- 所有响应包含 `x-request-id`。
- 路由和 fallback 信息通过可选 header 返回，不泄漏敏感 key。
- Error response 必须符合目标协议的错误格式，同时内部记录统一 error taxonomy。

## 2. Client-facing API

### OpenAI-compatible

| Endpoint | P0 | 说明 |
|---|---|---|
| `GET /v1/models` | 是 | 按 Key/Profile 返回可见模型 |
| `POST /v1/chat/completions` | 是 | stream/non-stream |
| `POST /v1/responses` | 是 | 基础文本、基础 tool event、terminal event |
| `POST /v1/embeddings` | 是 | embedding provider |
| `POST /v1/images/generations` | P1 | 图像生成 |
| `POST /v1/audio/transcriptions` | P1 | 音频 |
| Realtime | P2 | WebSocket/WebRTC |

### Anthropic-compatible

| Endpoint | P0 | 说明 |
|---|---|---|
| `POST /v1/messages` | 是 | messages + stream |
| `GET /v1/models` | P1 | Anthropic 风格模型列表 |
| Admin beta headers | P1 | 按兼容矩阵支持 |

### Gemini-compatible

| Endpoint | P0 | 说明 |
|---|---|---|
| `POST /v1beta/models/:model:generateContent` | 是 | 常用文本 |
| `POST /v1beta/models/:model:streamGenerateContent` | 是 | 常用流式 |
| Files API | P1 | 视用户需求 |

## 3. 内部 Admin API

P0 可用 REST 或 GraphQL。若用 GraphQL，列表页必须分页、字段选择必须限制，避免 AxonHub 中类似后台 GraphQL 慢查询风险。

### 资源

| Resource | 操作 |
|---|---|
| Tenants/Teams/Projects | CRUD |
| Users/Roles | CRUD、邀请、禁用 |
| Virtual Keys | 创建、禁用、轮换、设置预算、Profile |
| Profiles | 模型别名、渠道 tag、payload policy |
| Providers/Channels | CRUD、测试、启停、导入导出 |
| Provider Keys | 添加、禁用、轮换、恢复探测 |
| Canonical Models | CRUD、能力标签、可见性 |
| Model Associations | CRUD、dry-run |
| Route Policies | CRUD、版本、dry-run |
| Price Books | CRUD、版本、生效时间 |
| Ledger | 查询、调账、对账 |
| Request Logs/Traces | 查询、详情、导出 |
| Audit Logs | 查询 |
| Alerts | webhook、阈值 |
| Migration | upload、dry-run、apply、rollback report |

## 4. 标准 Header

### 请求 Header

| Header | 说明 |
|---|---|
| `Authorization` | Bearer virtual key 或 provider-compatible token |
| `x-ai-profile` | 可选，指定 API Key Profile |
| `x-ai-trace-id` | 可选，外部 trace id |
| `x-ai-thread-id` | 可选，会话 id |
| `x-ai-routing-policy` | P1，可选请求级路由策略 |
| `x-ai-log-payload` | 可选，覆盖 payload 存储策略，受权限限制 |
| `x-ai-cache-control` | P1，cache bypass/ttl |

### 响应 Header

| Header | 说明 |
|---|---|
| `x-request-id` | 网关请求 ID |
| `x-ai-trace-id` | Trace ID |
| `x-ai-provider` | 最终 provider code，按配置可隐藏 |
| `x-ai-channel-id` | 最终 channel，可脱敏 |
| `x-ai-fallback-count` | fallback 次数 |
| `x-ai-route-policy-version` | 路由策略版本 |
| `x-ai-cache-status` | hit/miss/bypass，P1 |
| `x-ai-cost` | 可选，估算或最终成本 |

## 5. Error Taxonomy

内部错误字段：

```json
{
  "error_owner": "client|gateway|provider|network|parser|billing|policy|task",
  "error_stage": "auth|preauth|route|request_mutation|provider_call|stream_parse|response_transform|settle",
  "error_code": "provider_429",
  "retryable": true,
  "fallback_allowed": true,
  "partial_sent": false,
  "provider_status": 429,
  "provider_error_code": "rate_limit_exceeded"
}
```

P0 错误码：

| Code | Owner | 说明 | Retry/Fallback |
|---|---|---|---|
| `auth_invalid_key` | policy | Virtual Key 无效 | 否 |
| `auth_expired_key` | policy | Key 过期 | 否 |
| `policy_model_denied` | policy | 模型无权限 | 否 |
| `billing_insufficient_balance` | billing | 余额/预算不足 | 否 |
| `route_no_candidate` | gateway | 无可用渠道 | 否 |
| `provider_429` | provider | 上游限流 | 是，尊重 Retry-After |
| `provider_5xx` | provider | 上游服务错误 | 是 |
| `provider_auth_failed` | provider | 上游 key 认证失败 | 否，key 降级 |
| `provider_quota_exhausted` | provider | 上游 quota 耗尽 | key 禁用/恢复探测 |
| `network_timeout` | network | 连接或读取超时 | 是，视 partial_sent |
| `network_reset` | network | connection reset/EOF | 是，视 partial_sent |
| `stream_missing_terminal` | parser | stream 缺结束事件 | 视 partial_sent |
| `stream_invalid_event` | parser | stream event 无法解析 | 视 partial_sent |
| `client_cancel` | client | 客户端断开 | 否，不影响 provider 健康 |
| `gateway_internal` | gateway | 未分类内部错误 | 否/人工排查 |

## 6. 协议转换原则

### 6.1 不压扁复杂协议

系统必须保留 Raw Request / Raw Event。Normalized Layer 只作为路由、usage、语义抽取使用，不作为唯一事实。

### 6.2 Terminal Event 必须保真

| 协议 | Terminal |
|---|---|
| OpenAI Chat SSE | `data: [DONE]` |
| OpenAI Responses SSE | `response.completed` 或等价完整结束事件 |
| Anthropic SSE | `message_stop` |
| Gemini stream | 最后 candidate/finish reason |

### 6.3 Provider-specific 字段

默认策略：

- Native passthrough 不改 body，只做认证、路由、model name rewrite。
- Adapter transform 必须声明可能不支持的字段。
- Request detail 里显示被删除/改名字段。

## 7. API 兼容测试矩阵

| 客户端 | P0 测试 |
|---|---|
| OpenAI Python SDK | chat stream/non-stream、responses、embeddings、models |
| OpenAI JS SDK | chat stream/non-stream |
| Anthropic SDK | messages stream/non-stream |
| Gemini SDK | generateContent stream/non-stream |
| Claude Code | 基础文本、stream、模型列表/profile |
| Codex-like client | responses terminal event、stream 重连行为 |
| OpenCode/Cline/Continue | OpenAI-compatible 基础 stream |
