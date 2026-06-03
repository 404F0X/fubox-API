# 功能规划：P0 / P1 / P2 版本边界

版本：0.1-dev-start  
日期：2026-06-01

## 1. 功能规划总原则

P0 不是功能越多越好，而是要能支持真实团队灰度使用。优先级排序如下：

1. 请求链路稳定。
2. 流式不翻车。
3. 路由和失败可解释。
4. 账务可追溯。
5. 迁移 New API / One API 足够顺滑。
6. 后台可以完成必要配置和排障。
7. 运营、MCP、语义缓存、评测平台等进入 P1/P2。

## 2. 用户角色

| 角色 | 目标 | 关键功能 |
|---|---|---|
| 平台管理员 | 配置 provider、渠道、价格、用户、权限、审计 | Admin UI、RBAC、Channel、Model、Price、Logs |
| 运维工程师 | 保证服务稳定、告警、排障、扩容 | Health、Trace、Metrics、Runbook、Backup |
| 财务/运营 | 看成本、额度、扣费、账单 | Ledger、Wallet、Budget、Price Version、Reports |
| 开发者 | 用统一 endpoint 调模型，尽量少改代码 | OpenAI-compatible、Native passthrough、SDK examples |
| Agent/Coding 用户 | Claude Code/Codex/OpenCode 稳定工作 | Client profiles、SSE、Trace、model aliases |
| 企业安全管理员 | 控制数据、身份、审计和合规 | SSO、RBAC、Payload Policy、Guardrails、Audit |

## 3. P0：生产初版

P0 目标：可在内部团队或小规模客户中灰度上线，替代 New API 的核心链路，同时吸收 AxonHub 的协议网关体验。

### P0-01 协议和入口

| 功能 | 说明 | 验收标准 |
|---|---|---|
| OpenAI Chat Completions | `/v1/chat/completions` 非流式和流式 | OpenAI SDK 常见调用通过；stream `[DONE]` 正确 |
| OpenAI Responses 基础 | `/v1/responses` 文本、基础工具事件透传/兼容 | Codex-like 基础请求不丢 terminal event |
| Embeddings | `/v1/embeddings` | 可路由到 OpenAI-compatible/Jina/自定义 provider |
| Models | `/v1/models` | 按 API Key/Profile 返回可见模型 |
| Anthropic Messages | `/v1/messages` 或兼容路径 | Claude Code 基础文本/stream 可用 |
| Gemini GenerateContent | 常用文本/stream | Gemini SDK 或兼容调用可用 |
| Native passthrough | OpenAI/Anthropic/Gemini 保留原始 body | 请求字段不被无意义重建 |

### P0-02 模型治理

| 功能 | 说明 | 验收标准 |
|---|---|---|
| API Key Profile | 每个 Key 可挂多个 Profile，控制模型别名、渠道 tag、默认策略 | 同一客户端模型名可在不同 Profile 映射不同内部模型 |
| Canonical Model | 平台内部标准模型 ID 和能力标签 | 模型能力、上下文、价格、可见性可配置 |
| Model Association | Canonical Model 关联多个 Channel，带 priority/tag/regex | 同模型多渠道可 fallback |
| Channel Mapping | 上游真实模型名映射、prefix trim、大小写策略 | OpenRouter 前缀模型等场景可工作 |
| Model List Filtering | 按 Key/Profile/Project 返回模型列表 | 不泄漏无权限模型 |

### P0-03 Provider / Channel / Key 池

| 功能 | 说明 | 验收标准 |
|---|---|---|
| Provider 管理 | OpenAI、Anthropic、Gemini、DeepSeek、Qwen/Doubao、OpenRouter、OpenAI-compatible、自定义 | 每类至少一个 mock + 一个真实配置路径 |
| Channel 管理 | endpoint、protocol_mode、model mapping、tag、weight、priority | UI/API 均可配置，后端校验 |
| Provider Key Pool | 多 key、启停、冷却、恢复探测、RPM/TPM | 429/auth/quota 错误可影响 key 状态 |
| Health Score | provider/channel/key/model 四层健康 | dashboard 可见，路由会使用 |
| Manual Probe | 手动测试渠道和模型 | 不影响正式统计，可记录探测结果 |

### P0-04 路由和可靠性

| 功能 | 说明 | 验收标准 |
|---|---|---|
| Priority + Weight | 兼容 New API 用户习惯 | 同优先级内按权重分布 |
| Health-aware Routing | 过滤禁用、冷却、健康低的渠道 | 异常渠道不再被选择 |
| Rate-limit-aware | 避开 key/channel 的 RPM/TPM 冷却 | 429 后尊重 Retry-After |
| Retry-before-first-byte | 首 chunk 前失败可换渠道 | stream 未输出前 timeout/5xx 可 fallback |
| Fallback Trace | 记录每次 fallback 原因 | 请求详情展示完整链路 |
| Circuit Breaker | 高频失败短期熔断 | 防止坏上游拖垮系统 |

### P0-05 Streaming Engine

| 功能 | 说明 | 验收标准 |
|---|---|---|
| Unified SSE Parser | 所有 adapter 使用统一流式引擎 | 大 chunk 不触发 scanner buffer 问题 |
| Partial Sent Tracking | 记录是否已向客户端输出 | 已输出后不盲目 fallback |
| Terminal Event Validation | 检查协议结束事件 | OpenAI/Responses/Anthropic 均有 fixture |
| Stream End Reason | 结束原因字段化 | completed/client_cancel/upstream_eof/parser_error 可区分 |
| Backpressure | 下游慢时不无限堆内存 | 压测下内存稳定 |
| Usage Reconcile | 流式 usage 提取和账务结算 | usage 缺失时有估算/补偿策略 |

### P0-06 账务 Ledger

| 功能 | 说明 | 验收标准 |
|---|---|---|
| Price Book | 模型价格、token 类型、cache、reasoning | 价格变更生成版本 |
| Pre-authorize | 请求前检查预算/余额 | 无余额请求被拒绝，不调用上游 |
| Reserve | 可选冻结额度 | 幂等，不重复冻结 |
| Settle | 根据实际 usage 结算 | 每笔请求生成 ledger entry |
| Refund | 失败/部分失败退款 | 与 request_id 关联可追踪 |
| Reconciliation | ledger、usage、dashboard 对账 | 日报可对齐 |

### P0-07 可观测性

| 功能 | 说明 | 验收标准 |
|---|---|---|
| Thread/Trace/Request | 会话、任务、请求三级 | 同一 Agent 任务请求能聚合 |
| Route Trace | 候选、过滤、排序、fallback | 每次选择可解释 |
| Metrics | RPS、latency、TTFT、tokens/s、errors、cost | Prometheus 或内置 exporter |
| Logs | request metadata、error、usage、payload policy | payload 可禁存/脱敏/采样 |
| Dashboard | 成本、模型、provider、key、错误、健康 | 管理员能排障 |
| Alert Webhook | key 禁用、错误率、成本异常 | 可配置阈值 |

### P0-08 管理后台

| 功能 | 说明 | 验收标准 |
|---|---|---|
| Provider/Channel UI | 增删改查、测试、启停 | 表单后端校验，错误定位 |
| Model UI | Canonical model、association、mapping | 支持批量导入 |
| API Key UI | 创建、过期、模型权限、profile、预算 | Secret 只显示一次 |
| Price UI | 价格表、版本、生效时间 | 历史账单不受新价格影响 |
| Request/Trace UI | 查询、详情、链路、payload 查看策略 | 大 payload 懒加载 |
| Health UI | provider/channel/key/model 状态 | 可手动恢复/禁用 |

### P0-09 迁移

| 功能 | 说明 | 验收标准 |
|---|---|---|
| New API 导入器 | 渠道、模型映射、分组、令牌、余额、倍率 | 生成导入报告和不可迁移项 |
| One API 导入器 | 同上 | 可 dry-run，不修改生产数据 |
| 兼容 endpoint | OpenAI SDK 改 base_url 即可 | 典型客户端样例通过 |

## 4. P1：明显领先版本

| 模块 | P1 功能 |
|---|---|
| Route DSL | 成本优先、延迟优先、质量优先、BYOK 优先、region-aware、canary |
| Request Override | JSON Patch、条件表达式、dry-run、schema validation、版本回滚 |
| Guardrails | Regex mask/reject、PII、response filter、规则测试 |
| Exact Cache | cache key builder、cache billing、节省金额 dashboard |
| 企业认证 | OIDC/SAML、role/group claim mapping、RBAC、审计 |
| OpenTelemetry | Trace/Metrics/Logs exporter |
| Coding Agent Profiles | Claude Code、Codex、OpenCode、Cline、Cursor、Continue 配置模板 |
| Log Store | ClickHouse、对象存储、冷热分层 |
| IaC | YAML 导入导出、Helm values、Terraform provider 草案 |
| Adapter Conformance | 每个 provider 完整 fixtures 和回归套件 |

## 5. P2：AI Control Plane

| 模块 | P2 功能 |
|---|---|
| MCP Gateway | MCP registry、tool-level RBAC、credential injection、OAuth token vault |
| A2A Gateway | Agent-to-Agent 代理、task trace、SSE event metrics |
| Prompt Registry | Prompt 版本、发布、回滚、A/B test |
| Eval Dataset | 从生产 trace 沉淀评测集 |
| Shadow Traffic | 不影响用户响应的候选模型对比 |
| Semantic Cache | 租户隔离，相似度阈值，安全策略 |
| Semantic Routing | 按任务类型、意图、成本/质量路由 |
| Inference-aware Routing | vLLM/KServe/Triton，按队列、KV cache、LoRA 路由 |
| Developer Portal | 模型申请、额度申请、服务目录、审批 |
| 商业运营 | 支付、订阅、发票、多币种、工单、公告、兑换码 |

## 6. 功能优先级判定规则

进入 P0 的功能必须同时满足：

- 会阻塞核心请求链路、账务准确性或迁移使用。
- 不做会导致生产排障困难。
- 不做会让 New API/AxonHub 用户没有迁移动机。

进入 P1/P2 的功能：

- 对企业销售重要但不阻塞基础灰度。
- 对商业运营重要但可在账务底座后迭代。
- 需要真实用户数据验证，例如 semantic cache、eval、shadow traffic。

## 7. P0 不允许牺牲的质量红线

- 账务不能因为日志清理而丢失。
- 流式请求不能在已输出后盲目 fallback。
- 请求错误不能只存字符串，必须使用 error taxonomy。
- Provider key 不能明文存储。
- 配置错误不能只靠前端校验。
- 导入器必须支持 dry-run 和回滚。
- 所有数据库迁移必须可回滚或有前向修复方案。
