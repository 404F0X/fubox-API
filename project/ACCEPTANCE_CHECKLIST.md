# P0 验收清单

## 功能

- [ ] OpenAI Chat non-stream 通过。
- [ ] OpenAI Chat stream 通过。
- [ ] Responses 基础 stream terminal event 通过。
- [ ] Anthropic Messages 基础通过。
- [ ] Gemini GenerateContent 基础通过。
- [ ] `/v1/models` 按 Key/Profile 过滤。
- [ ] Provider/Channel/Key Pool 可配置。
- [ ] Model Association dry-run 可解释候选渠道。
- [ ] Retry/Fallback 矩阵测试通过。
- [ ] Unified SSE parser 大 chunk 测试通过。
- [ ] Ledger reserve/settle/refund 幂等测试通过。
- [ ] Thread/Trace/Request 可查询。
- [ ] New API/One API dry-run 导入通过。

## 安全

- [ ] Virtual Key 不明文存储。
- [ ] Provider Key 加密存储。
- [ ] 日志不泄漏 Authorization/API key/Cookie。
- [ ] RBAC 后端强校验。
- [ ] Audit log 覆盖关键管理操作。
- [ ] Payload policy 生效。

## 性能和稳定性

- [ ] 非流式额外 P95 延迟 < 50ms。
- [ ] 流式 TTFT 额外 P95 < 100ms。
- [ ] 1,000 并发 stream 压测内存稳定。
- [ ] provider 500/429/timeout/EOF 故障注入通过。
- [ ] billing worker crash/restart 后可恢复结算。

## 运维

- [ ] Docker Compose 可启动。
- [ ] Helm staging 部署通过。
- [ ] Metrics 可 scrape。
- [ ] Dashboard 可查看核心 SLO。
- [ ] Backup/restore 在 staging 演练通过。
