# 发布清单

本清单由人工确认项和可执行 release gate 组成。可执行项以
`scripts/release_check.ps1` 的 JSON summary 为审计记录；人工项需要在
release review 中补充负责人、证据链接和豁免说明。

## 可执行 release gate

默认命令：

```powershell
.\scripts\release_check.ps1
```

默认模式只执行安全的 check/dry-run：

- `format`：`cargo fmt --check`。
- `test`：Rust workspace tests。
- `frontend`：Admin UI typecheck 和 test。
- `build`：Rust workspace build、Admin UI build、bundle budget。
- `security`：secret scan、supply-chain structural scan，并生成 SBOM/provenance/manifest/SHA256SUMS artifacts；网络审计默认关闭，发布候选可加 `-OnlineSecurity`。
- `backup`：PostgreSQL backup preflight；只检查计划，不创建目录，不执行 `pg_dump`。
- `helm`：静态 Helm chart 校验；安装 Helm 时额外运行 `helm lint` 和 `helm template`。
- `smoke`：compose smoke 与 SDK smoke 的 dry-run 自检；只有显式 `-RunRuntimeSmoke` 才请求本机运行中的服务。

机器可读 summary 写到 stdout；需要归档时：

```powershell
.\scripts\release_check.ps1 -SummaryPath .\artifacts\release-gate-summary.json
```

本机缺少 `Docker`、`Helm`、`pg_dump`、`node` 或 `npm` 时，默认 dry-run/preflight
会把对应 runtime/chart/backup/SDK smoke 缺口记录为 `warn` 或 `skip`，并以
`local warning:` 开头，不打印 secret/env 原文。显式请求 runtime 操作时，缺少必需工具
仍是 `fail`。CI 或 release review 如需把 warning 当作阻断项，使用：

```powershell
.\scripts\release_check.ps1 -TreatWarningsAsFailures
```

局部验证示例：

```powershell
.\scripts\release_check.ps1 -Checks backup,helm,smoke
```

GitHub 首次 push 前本地收口必须至少执行并归档：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/release_check.ps1 -Checks security
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/release_check.ps1 -Checks backup,helm,smoke
.\scripts\scan_secrets.ps1
```

首推前判定：

- `security` gate 必须通过，且 `artifacts/supply-chain` 中的 SBOM、provenance、manifest 和 checksum 输出需要作为本地证据保留；默认 `security` 不做联网漏洞审计，RC 或正式发布评审需要联网审计时补跑 `-OnlineSecurity`。
- `backup,helm,smoke` 可以在缺本机工具时返回 `overallStatus=warn`，但每条 `local warning:` 都必须登记补跑环境和负责人；这些 warning 只说明本机 dry-run/preflight 没有完整覆盖，不代表 staging 已通过。
- `scripts\scan_secrets.ps1` 是首推前额外安全回归，不能用 release gate 中某条 warning 抵消；失败时阻断 push。
- 首推前不要记录或粘贴任何 secret/env 原文；命令输出和归档 summary 如出现疑似 secret，应先修复脚本脱敏或删除证据后重跑。

JSON 判定：

- `overallStatus=pass`：可执行门禁通过。
- `overallStatus=warn`：没有失败，但存在 skip/warning；常见原因是本机缺工具、未配置 DB 或默认跳过网络/runtime 扫描。release review 必须记录是否接受，并说明补跑环境。
- `overallStatus=fail`：至少一个 check 失败，或使用 `-TreatWarningsAsFailures` 后 warning/skip 被提升为失败；阻断发布，除非有明确负责人签字豁免。

## Release Candidate 前

- [ ] 所有 P0 issue 关闭或有明确豁免。
- [ ] `scripts/release_check.ps1` 全量 summary 已归档，且 `overallStatus` 为 `pass` 或有已批准豁免。
- [ ] CI 全量通过，并与 release gate summary 对齐。
- [ ] E2E 全量通过。
- [ ] Load test 报告归档。
- [ ] Chaos test 报告归档。
- [ ] 安全扫描无高危；`security` gate 已生成并归档 SBOM/provenance/manifest/SHA256SUMS artifacts；如 `security` gate 为 `warn`，需记录原因和补跑计划。
- [ ] 数据库 migration 在 staging 验证。
- [ ] `backup` gate 已在具备 `pg_dump` 和数据库连接配置的环境执行 preflight。
- [ ] `helm` gate 已在具备 Helm 的环境执行 lint/template。
- [ ] `smoke` gate 已完成 dry-run；上线前 staging/runtime smoke 已按需执行并归档结果。dry-run warning 不能替代 staging 验收。
- [ ] GitHub 首次 push 前，本地 `security`、`backup,helm,smoke` 和 `scripts\scan_secrets.ps1` 已执行；如存在本机缺工具 warning，已记录补跑计划，且没有声称 staging 已完成。
- [ ] 监控 dashboard 准备完成。
- [ ] 告警 webhook 配置完成。
- [ ] Runbook 更新。

## Staging

- [ ] 部署新版本。
- [ ] 执行 migration。
- [ ] 使用真实 SDK smoke test。
- [ ] 验证账务 ledger。
- [ ] 验证日志和 trace。
- [ ] 验证回滚脚本。

## Production Canary

- [ ] 5% 流量 canary。
- [ ] 观察错误率、fallback rate、ledger lag、latency。
- [ ] 无异常扩大到 50%。
- [ ] 无异常全量。
- [ ] 发布 release notes。

## 回滚

- [ ] 上一版本镜像可用。
- [ ] 配置版本可回滚。
- [ ] 数据库变更有前向修复方案。
- [ ] 回滚责任人和沟通渠道明确。
