# 路由、重试、Fallback 与 Streaming 规格

版本：0.1-dev-start  
日期：2026-06-01

## 1. 设计目标

- 每次路由都可解释。
- 每次失败都可归因。
- 每个 provider/key/channel 都有健康状态。
- 流式请求不因 fallback 造成协议损坏。
- 兼容 New API 的权重/优先级习惯，同时提供更生产化的健康、限流、延迟和成本策略。

## 2. Route Decision 数据结构

```json
{
  "route_id": "uuid",
  "policy_version": 12,
  "requested_model": "gpt-4",
  "canonical_model": "canonical/claude-sonnet",
  "candidates": [
    {
      "channel_id": "ch_1",
      "provider": "anthropic",
      "priority": 10,
      "weight": 100,
      "health_score": 0.97,
      "latency_p90_ms": 1800,
      "cost_score": 0.65,
      "rate_limit_available": true,
      "filtered": false,
      "score": 0.91
    }
  ],
  "filtered": [
    {"channel_id": "ch_2", "reason": "key_cooldown_until_2026-06-01T12:00:00Z"}
  ],
  "selected_channel_id": "ch_1",
  "selected_key_id": "pk_1",
  "fallback_count": 0
}
```

## 3. 路由阶段

1. Profile model alias：客户端模型名 -> canonical model。
2. Model Association：找候选 channel。
3. Capability filter：tools/vision/audio/reasoning/context。
4. Permission filter：project、key、profile、channel tag。
5. Health filter：manual disabled、cooldown、auth_failed、quota_exhausted。
6. Rate filter：RPM、TPM、concurrency、provider quota。
7. Policy sort：priority、weight、latency、cost、health、BYOK、region。
8. Key selection：在 channel 内选择 provider key。
9. Attempt execution。

## 4. P0 路由策略

| 策略 | P0 | 说明 |
|---|---|---|
| Priority | 是 | 数值越小越优先 |
| Weight | 是 | 同优先级内按权重分布 |
| Health-aware | 是 | 健康分和冷却过滤 |
| Rate-limit-aware | 是 | 避开 RPM/TPM 不足 key |
| Cost-aware | 基础 | P0 可做排序或展示，不强制复杂优化 |
| Latency-aware | 基础 | 使用滑动窗口 p90 |
| Trace affinity | 基础 | 同 trace 优先之前成功 channel |
| BYOK-first | P1 | 企业自有 key 优先 |
| Route DSL | P1 | 可组合策略图 |

## 5. Retry / Fallback 规则

### 5.1 是否重试矩阵

| 错误 | 非流式 | 流式未输出 | 流式已输出 | 健康影响 |
|---|---|---|---|---|
| provider_429 | retry/fallback | retry/fallback | 不 fallback，返回错误事件 | key/channel 降分，尊重 Retry-After |
| provider_5xx | retry/fallback | retry/fallback | 不 fallback | provider/channel 降分 |
| network_timeout | retry/fallback | retry/fallback | 不 fallback | 视阶段降分 |
| network_eof | retry/fallback | retry/fallback | 不 fallback | 上游降分 |
| stream_missing_terminal | 视情况 | 视情况 | 不 fallback | parser/provider 降分 |
| client_cancel | 不 retry | 不 retry | 不 retry | 不影响 provider |
| billing_insufficient_balance | 不 retry | 不 retry | 不 retry | 不影响 provider |
| policy_model_denied | 不 retry | 不 retry | 不 retry | 不影响 provider |
| provider_auth_failed | 不 retry该 key | 不 retry该 key | 不 fallback | key 标记 auth_failed |

### 5.2 Retry-After

- 若上游返回 `Retry-After` 或 `Retry-After-ms`，优先使用。
- 没有则指数退避：100ms、300ms、1s，P0 最大 2 次。
- 总等待不超过请求 timeout budget。

### 5.3 Retry Budget

P0 默认：

- 非流式最多 2 次 provider attempt。
- 流式 first byte 前最多 2 次。
- 已发 partial 后不再 fallback。

配置示例见 `examples/route_policy.example.yaml`。

## 6. Health Engine

### 6.1 维度

- Provider health。
- Channel health。
- Provider Key health。
- Model-on-channel health。

### 6.2 滑动窗口指标

| 指标 | 窗口 |
|---|---|
| success_rate | 1m/5m/1h |
| error_rate_by_code | 1m/5m/1h |
| p50/p90/p99 latency | 5m/1h |
| TTFT p50/p90 | 5m/1h |
| tokens_per_second | 5m |
| 429 count | 1m/5m |
| auth/quota errors | 1h/24h |

### 6.3 状态

```text
enabled
  -> degraded: 错误率升高但仍可用
  -> cooldown: 暂时不参与路由
  -> recovery_probe: 恢复探测中
  -> enabled: 恢复
  -> manual_disabled/auth_failed/quota_exhausted
```

## 7. Streaming Engine 规格

### 7.1 统一接口

```text
StreamEngine.Run(ctx, upstreamRequest, parser, writer) -> StreamResult

StreamResult:
  partial_sent: bool
  terminal_seen: bool
  stream_end_reason: enum
  usage: UsageSnapshot optional
  raw_event_count: int
  first_token_latency_ms: int
  output_tokens_estimated: int
  error: GatewayError optional
```

### 7.2 Buffer 和 backpressure

- 不使用默认 64KB scanner 限制。
- 支持大 SSE event，上限可配置，默认 4MB/event。
- 总请求体和响应体上限可配置。
- 下游写慢时应用 backpressure，不在内存无限堆积。
- 客户端断开必须尽快取消上游请求。

### 7.3 Terminal Event Conformance

每个 adapter 必须提供 fixtures：

| Fixture | 要求 |
|---|---|
| normal_stream | 正常文本流，terminal_seen=true |
| tool_stream | tool call 增量，terminal_seen=true |
| usage_in_stream | usage 出现在最后或中间 |
| upstream_eof_before_terminal | stream_end_reason=upstream_eof |
| invalid_json_event | stream_end_reason=parser_error |
| client_cancel | stream_end_reason=client_cancel，不影响 provider health |
| large_event | 超过 64KB event 正常处理 |

## 8. Request Mutation

P1 完整，P0 可做基础 model/header/body override。

规则：

- mutation 必须有版本。
- mutation 前后 snapshot 可在 dry-run 查看。
- 默认禁止覆盖 Authorization，除非 channel 配置明确允许。
- 改写后必须通过最小 schema validation。

## 9. 路由验收测试

- 单模型多渠道，主渠道 500，fallback 到备份成功。
- 主渠道首 chunk 前 timeout，stream fallback 成功。
- 主渠道已输出 chunk 后断开，不 fallback，返回协议兼容错误并记录 partial_sent。
- key 429 带 Retry-After，进入 cooldown，期间不再选择。
- client_cancel 不降低 provider health。
- 两个同权重渠道 10,000 次请求分布误差在可接受范围内。
- trace affinity 开启时，同 trace 后续请求优先成功过 channel。
