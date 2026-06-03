# 竞品调研吸收点汇总

版本：0.1-dev-start  
日期：2026-06-01

## 1. New API

吸收：

- 自托管、后台、多渠道、用户令牌、分组、计费、充值/额度生态。
- OpenAI-compatible、Claude、Gemini 等多协议适配。
- One API 兼容和迁移用户基础。

反超：

- typed error taxonomy。
- stream engine。
- ledger 账务。
- provider/key 自动恢复。
- 日志分区和 trace。

## 2. AxonHub

吸收：

- Any SDK -> Any Model。
- API Key Profile / Model Association / Channel Mapping 三层模型治理。
- Thread/Trace/Request。
- Adaptive Load Balancing。
- Request Override。
- Prompt Protection。
- Claude Code / Codex / OpenCode 入口。

反超：

- 流式 terminal event 保真。
- Responses/MCP 不压扁。
- 账务从 cost tracking 升级到 ledger。
- 日志/trace 存储分层。

## 3. LiteLLM

吸收：

- Virtual Key、Spend Tracking、Budget、Fallback、Load Balancing。
- 统一 OpenAI 风格接口。

警惕：

- 配置复杂度。
- 供应链安全必须纳入发布流程。

## 4. Portkey

吸收：

- Fallback graph。
- Conditional routing。
- Retry respecting Retry-After。
- Config ID / Trace ID 排障。
- MCP Gateway 方向。

## 5. GPT-Load / Bifrost

吸收：

- 高性能透明代理。
- Key 池健康、轮换、failover。
- Data Plane 轻量化。

## 6. Helicone / Langfuse / Braintrust

吸收：

- Cost registry。
- Trace-first observability。
- Prompt/version/eval 的未来方向。

## 7. Cloudflare / Vercel / OpenRouter / Requesty

吸收：

- Gateway dashboard：request、token、cost、error。
- Payload logging 可控。
- Provider fallback 和 header 透明。
- BYOK。
- Provider selection：按价格、延迟、吞吐、性能阈值。

## 8. Kong / APISIX / Higress / Envoy AI Gateway

吸收：

- 插件化。
- Prompt guard/decorator。
- Token-aware rate limiting。
- OpenTelemetry。
- K8s/Gateway API/IaC。
- Agent/MCP/A2A 流量治理。
