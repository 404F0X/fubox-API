# 执行摘要

版本：0.1-dev-start  
日期：2026-06-01

## 产品判断

我们不应开发一个简单的 New API clone。最佳方向是：

> New API 的自托管后台、用户额度和多渠道生态 + AxonHub 的 Any SDK -> Any Model、模型映射和 Trace + GPT-Load/Bifrost 的高性能透明代理 + LiteLLM/Portkey/OpenRouter 的策略路由 + Helicone/Langfuse 的观测和成本核算。

## 必须反超的痛点

1. 流式稳定性：统一 SSE parser、terminal event、partial_sent、stream_end_reason。
2. 协议转换保真：Raw Layer、native passthrough、conformance tests。
3. 账务可信：Ledger、price version、幂等、对账。
4. 路由可解释：candidate、filter reason、score、fallback trace。
5. Key 池健康：cooldown、recovery probe、quota/auth/429 分类。
6. 日志和 Trace 分层：避免日志体量拖慢后台。
7. 企业治理：RBAC、SSO、审计、payload policy。

## P0 建设范围

P0 是可灰度上线的生产初版，包含：

- OpenAI Chat/Responses/Embeddings/Models。
- Anthropic Messages、Gemini GenerateContent 基础兼容。
- Native passthrough + adapter transform。
- API Key Profile、Canonical Model、Model Association、Channel Mapping。
- Provider/Channel/Key Pool。
- Health-aware routing、retry-before-first-byte、fallback。
- Unified streaming engine。
- Billing ledger。
- Thread/Trace/Request observability。
- Admin UI。
- New API/One API importer。
- Docker Compose + Helm。

## 开工建议

开发组优先按照 `TODO.md` 的 M0-M7 里程碑推进。任何功能进入 Done 前必须过 `TEST_AND_ACCEPTANCE.md` 的 Definition of Done。
