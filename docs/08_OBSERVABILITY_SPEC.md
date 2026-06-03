# 可观测性、Trace、日志与告警规格

版本：0.1-dev-start  
日期：2026-06-01

## 1. 设计目标

系统必须能回答：

- 谁在什么时候调用了哪个模型？
- 请求为什么路由到这个 provider/channel/key？
- 为什么 fallback？失败归因是客户端、网关、上游、网络、解析还是账务？
- 每次请求花了多少钱？价格版本是什么？
- 哪个 key 最近频繁 429？哪个 provider p95 变差？
- Agent 一次任务触发了多少请求、多少成本、哪里失败？

## 2. 观测模型

```text
Thread: 一次会话
  Trace: 一次用户任务 / agent loop / workflow
    Span: auth / route / provider_attempt / stream / billing / guardrail
      Request: 单次 LLM HTTP 请求
        ProviderAttempt: 一次上游尝试
        LedgerEntry: 账务流水
```

## 3. Trace ID 规则

- 若请求带 `x-ai-trace-id`，优先使用。
- 若带兼容 header，例如 `sentry-trace`，按 Profile 规则提取。
- 若无，网关生成。
- thread_id 同理，可由 `x-ai-thread-id`、metadata、profile 规则提取。

## 4. Request Log 字段

必填字段：

- request_id、trace_id、thread_id。
- tenant_id、project_id、virtual_key_id。
- inbound_protocol、outbound_protocol、protocol_mode。
- requested_model、canonical_model、upstream_model。
- provider、channel、provider_key_alias/hash。
- route_policy_version、route_decision_snapshot。
- status、http_status、error_owner、error_code、retryable、partial_sent、stream_end_reason。
- input/output/cache/reasoning tokens。
- estimated_cost、final_cost、price_version、ledger_entry_id。
- latency_ms、ttft_ms、stream_duration_ms、tokens_per_second。
- payload_policy、payload_stored、redaction_status、object_ref。

## 5. Metrics

### Gateway Metrics

| Metric | 类型 | 标签 |
|---|---|---|
| `ai_gateway_requests_total` | counter | tenant, project, model, provider, status |
| `ai_gateway_request_duration_ms` | histogram | model, provider, protocol |
| `ai_gateway_ttft_ms` | histogram | model, provider |
| `ai_gateway_stream_duration_ms` | histogram | model, provider |
| `ai_gateway_tokens_total` | counter | type, model, provider |
| `ai_gateway_cost_total` | counter | project, model, provider |
| `ai_gateway_errors_total` | counter | error_owner, error_code |
| `ai_gateway_fallbacks_total` | counter | reason, from_provider, to_provider |
| `ai_gateway_key_cooldowns_total` | counter | provider, reason |
| `ai_gateway_ledger_events_total` | counter | type, status |

### Current Runtime Metrics Slice

The E14-003 dashboard template currently treats the implemented gateway metrics
as the only active Prometheus contract:

- `ai_gateway_requests_total`
- `ai_gateway_errors_total`
- `ai_gateway_request_latency_ms_bucket` / `_sum` / `_count`
- `ai_gateway_request_ttft_ms_bucket` / `_sum` / `_count`
- `ai_gateway_fallbacks_total`
- `ai_gateway_request_cost_total`
- `ai_gateway_service_up`

Provider/channel/key/model/project/tenant dimensions, ledger lag, event lag, and
key cooldown metrics remain pending in this spec. Dashboard panels for those
areas must be visibly marked `(pending)` and use a no-series placeholder query;
Prometheus alert rules must not reference those metrics until the runtime emits
them and the template validator is updated with the landed label set.

### OpenTelemetry Exporter Contract

当前实现切片位于 `ai-gateway-observability`，只覆盖 exporter 配置解析和 no-op 初始化边界，contract fixture 为 `tests/fixtures/observability/otel_exporter_contract.json`。

- `disabled`：默认或显式关闭，初始化返回 no-op handle，不安装 SDK provider。
- `stdout`：接受 `stdout`/`console` exporter 形态，配置层视为 enabled，但当前不会创建 stdout SDK pipeline，也不会输出 trace/metrics/log records。
- `otlp`：接受项目变量 `AI_GATEWAY_OTEL_ENDPOINT` 和标准 `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`/`OTEL_EXPORTER_OTLP_ENDPOINT`，只校验 http/https endpoint 形态，不连接 collector，不发送网络请求。
- sanitizer：service name/resource attributes 会裁剪并规范化；secret-like resource attribute value 会写为 `[REDACTED]`；embedded userinfo、query/fragment secret 和 secret-like exporter 值不会进入错误文本。

尚未启用真实 OpenTelemetry SDK pipeline；Gateway/Control Plane runtime 入口、trace/metrics/logs 实际导出和 collector smoke 仍属后续切片。

### SLO Dashboards

P0 dashboard：

- Requests / errors / latency。
- TTFT 和 stream completion rate。
- Provider/channel/key health。
- Model availability。
- Fallback rate。
- Cost by project/model/provider/key。
- Ledger settlement lag。
- Event queue lag。

## 6. 日志存储策略

| 数据 | P0 | P1 |
|---|---|---|
| request metadata | PostgreSQL 分区 | ClickHouse |
| provider attempts | PostgreSQL 分区 | ClickHouse |
| raw payload | 可选对象存储 | 对象存储生命周期 |
| SSE raw chunks | 默认不存，采样 | 采样 + 对象存储 |
| audit logs | PostgreSQL append-only | 独立审计存储 |
| metrics | Prometheus endpoint | OTLP/Prometheus |

## 7. Payload Policy

| 策略 | 说明 |
|---|---|
| metadata_only | 只存 metadata，不存 prompt/response |
| hash_only | prompt/response hash，用于去重和审计 |
| redacted | 脱敏后存储 |
| full | 完整存储，需高权限和保留期 |
| sampled | 按比例采样 |

默认生产策略建议：metadata_only 或 redacted。

## 8. 告警

P0 告警：

| 告警 | 条件 |
|---|---|
| Provider 错误率高 | 5m provider_5xx > 阈值 |
| Key 大量 429 | 5m 429 > 阈值 |
| Fallback rate 异常 | fallback rate 超过基线 |
| Ledger lag | 结算队列延迟 > 60s |
| Event queue lag | 队列 backlog 持续增长 |
| DB slow query | 管理接口 p95 > 2s |
| Cost spike | 项目小时成本超过历史均值 N 倍 |
| No available route | route_no_candidate 增长 |
| Stream missing terminal | stream_missing_terminal 增长 |

## 9. 验收

- 任意 request_id 可查看完整 route decision、provider attempts、usage、ledger entry。
- 任意 trace_id 可聚合同一任务下所有请求。
- client_cancel 与 upstream_error 可在 dashboard 区分。
- payload 存储策略生效，低权限用户无法查看完整 payload。
- Prometheus metrics 可被 scrape。
- 关闭日志 worker 时，主请求不应明显变慢；恢复后事件可补写。
