# 测试策略、验收流程与上线门禁

版本：0.1-dev-start  
日期：2026-06-01

## 1. 测试目标

P0 必须达到可灰度上线标准，而不是仅本地可跑。测试要覆盖：

- 核心请求链路。
- 协议兼容。
- Streaming。
- 路由、retry、fallback。
- 账务 ledger。
- 权限和安全。
- 后台配置。
- 迁移导入。
- 性能、稳定性和故障注入。

## 2. 测试分层

| 层级 | 工具建议 | 门禁 |
|---|---|---|
| Unit Tests | cargo test / cargo nextest / vitest | 每 PR 必跑 |
| Contract Tests | provider mock + fixtures | adapter 必跑 |
| Integration Tests | Postgres + Redis + mock providers | 每 PR 必跑核心，夜间全量 |
| E2E Tests | Playwright + real gateway | 合并 main 前必跑 |
| Load Tests | k6/vegeta | release candidate 必跑 |
| Chaos Tests | toxiproxy/mock fault | release candidate 必跑 |
| Security Tests | SAST/DAST/dependency/secret scan | 每 PR/Release |
| Migration Tests | New API/One API sample dump | release candidate 必跑 |
| UAT | staging + 真实客户端 | P0 发布前必跑 |

## 3. 覆盖率目标

| 模块 | P0 覆盖率目标 |
|---|---|
| Billing Ledger | 90%+，所有状态机分支必须覆盖 |
| Routing Engine | 85%+，候选过滤和排序必须覆盖 |
| Stream Engine | 85%+，异常流必须覆盖 |
| Provider Adapters | 以 fixture contract 为准，关键路径 100% |
| Auth/RBAC | 85%+，拒绝路径必须覆盖 |
| Admin UI | 关键路径 E2E 覆盖 |

## 4. Definition of Done

每个功能完成必须满足：

- 有设计说明或在对应文档中更新。
- 有单元测试和必要集成测试。
- 有错误处理和日志/trace 字段。
- 有权限校验。
- 有配置校验。
- 有迁移脚本或说明。
- 有 UI 的功能必须有 E2E 或组件测试。
- 通过 CI。
- 更新 TODO 状态和验收说明。

## 5. P0 验收流程

```text
开发完成
  -> PR 自测 checklist
  -> CI: lint/unit/contract/integration/security
  -> Code Review
  -> Merge main
  -> Nightly full regression
  -> Staging deploy
  -> E2E + migration + chaos + load
  -> UAT with real SDK/clients
  -> Release checklist
  -> Canary deploy
  -> Production readiness review
```

## 6. 关键验收场景

### 6.1 协议兼容

- OpenAI Python SDK 调用 `/v1/chat/completions` 非流式成功。
- OpenAI Python SDK 调用 stream，收到完整增量和 `[DONE]`。
- OpenAI JS SDK stream 成功。
- `/v1/models` 按 API Key/Profile 返回不同模型列表。
- Anthropic Messages stream 成功并有 terminal。
- Gemini generateContent 基础文本成功。
- Responses stream 有 terminal event，客户端不反复重连。

### 6.2 路由和 Fallback

- 主渠道成功，选择主渠道。
- 主渠道 500，fallback 到备份渠道。
- 主渠道 429 且有 Retry-After，key 冷却，fallback 到其他 key。
- 主渠道首 chunk 前 timeout，stream fallback 成功。
- 主渠道已 partial_sent 后 EOF，不 fallback，记录 `partial_sent=true` 和 `upstream_eof`。
- client_cancel 不影响 provider health。
- 无可用渠道时返回清晰错误 `route_no_candidate`。

### 6.3 Streaming

- 单个 SSE event > 64KB 正常处理。
- 下游慢速消费时内存不持续增长。
- 上游发送 invalid JSON，错误归因为 parser。
- 上游缺 terminal event，记录 `stream_missing_terminal`。
- stream usage 缺失时触发估算，并标记 estimated。

### 6.4 账务

- 余额不足时不调用上游。
- 成功请求生成 settle ledger。
- 同 request_id 重复 settle 不重复扣费。
- 失败请求 refund reserve。
- 修改价格后历史请求价格版本不变。
- Dashboard 成本与 ledger 汇总可对账。

### 6.5 安全

- Virtual Key DB 不明文。
- Provider Key DB 加密。
- 低权限用户不能查看完整 payload。
- 修改路由、价格、key 都有 audit log。
- Secret scan 可检测误提交 key。
- payload policy 为 metadata_only 时不保存 prompt/response。

### 6.6 管理后台

- 创建 channel 时错误配置有明确提示。
- Model Association dry-run 可输出候选渠道和过滤原因。
- Request detail 大 payload 懒加载，不阻塞列表。
- Price version 创建后可回查。
- Health dashboard 可手动禁用/恢复 key。

### 6.7 迁移

- New API 样例配置 dry-run 生成报告。
- 导入后模型映射转换为 canonical model + association。
- 导入 token 只导入 hash/安全等价形式，不泄漏 secret。
- 导入失败可回滚或重复执行。

## 7. 性能验收

P0 建议基线：

| 指标 | 目标 |
|---|---|
| 非流式网关额外 P95 延迟 | < 50ms |
| 流式 TTFT 额外 P95 | < 100ms |
| 单实例并发 stream | 1,000 |
| 1,000 并发 stream 内存 | 稳定，无线性异常增长 |
| 日志 worker 停止 | 主请求仍可响应，事件 backlog 可恢复 |
| Admin request list p95 | < 1s，百万级日志样例 |
| route decision p95 | < 10ms，配置缓存命中时 |

## 8. 故障注入

必须模拟：

- Provider 500/502/503。
- Provider 429 with/without Retry-After。
- Provider EOF before terminal。
- Provider slow first byte。
- Provider slow streaming chunks。
- Invalid SSE JSON。
- Redis 短暂不可用。
- DB 慢查询。
- Billing worker crash/restart。
- Event queue backlog。
- Object storage 写入失败。

## 9. 发布门禁

Release Candidate 必须满足：

- 所有 P0 功能验收通过。
- 无 P0/P1 blocker bug。
- 高危安全漏洞为 0，或有 CTO/安全负责人书面豁免。
- 数据库迁移在 staging 通过，并有回滚/前向修复方案。
- Load/chaos 测试报告归档。
- Runbook 更新。
- 监控 dashboard 和告警已配置。
- Canary 方案和回滚方案确认。

## 10. 测试资产

本包提供：

- `examples/k6_load_test_skeleton.js`：压测脚本骨架。
- `project/QA_TEST_CASES.csv`：测试用例清单。
- `project/ACCEPTANCE_CHECKLIST.md`：验收清单。
- `project/RELEASE_CHECKLIST.md`：发布清单。
