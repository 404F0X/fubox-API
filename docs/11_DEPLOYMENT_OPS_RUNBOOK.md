# 部署、运维与生产 Runbook

版本：0.1-dev-start  
日期：2026-06-01

## 1. 环境规划

| 环境 | 用途 | 数据 |
|---|---|---|
| local | 开发本地 | SQLite/本地 Postgres + mock provider |
| dev | 团队集成 | 非生产数据 |
| staging | 发布前验收 | 脱敏生产近似数据 |
| production | 生产 | 正式数据 |

## 2. P0 部署组件

- Data Plane Gateway。
- Control Plane API。
- Admin UI。
- PostgreSQL。
- Redis。
- Event worker：billing、logs、health、alerts。
- Provider mock service，供测试环境使用。
- Prometheus/Grafana 或 OTLP collector。

## 3. Docker Compose

示例见 `examples/docker-compose.example.yml`。该示例挂载 `db` 与 Postgres init script，启动时会加载本地 dev seed。

本地 Compose 的 host port 只绑定 `127.0.0.1`，避免 PostgreSQL、Redis、mock-provider、Gateway、Control Plane 和 Admin UI 默认暴露到局域网。需要跨主机访问时，应在部署配置中显式改 host binding，并同步评审防火墙、鉴权和 TLS。

Compose 开发栈加载 `db/dev-seeds` 中的本地 smoke 数据，包括 fake virtual key 和 provider key sealed payload。`AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_BASE64` 与 `AI_GATEWAY_PROVIDER_KEY_MASTER_KEY_ID=dev-seed-v1` 仅用于打开这些本地 dev seed，不得复用于 staging 或 production。生产迁移只应用 `db/migrations`，不要应用 `db/dev-seeds`。

最低生产不建议 SQLite。

## 3.1 Trusted proxy client IP

`server.trusted_proxy_allowlist` 默认是空列表。默认情况下，Gateway 使用 TCP peer IP 做 API key IP allowlist 校验，并忽略 `X-Forwarded-For` 和 `X-Real-IP`。

只有当 TCP peer IP 命中 `server.trusted_proxy_allowlist` 中的单 IP 或 CIDR 时，Gateway 才信任 forwarded client IP header。信任代理后，优先使用 `X-Forwarded-For` 的第一个 IP；没有 `X-Forwarded-For` 时才使用 `X-Real-IP`。header 中的 IP 格式不合法会在 auth 阶段返回错误。不要把普通客户端网段加入该 allowlist；只加入实际反向代理或负载均衡器地址。

## 4. Kubernetes / Helm

P0 Helm values 需要包含：

- replicas。
- resource requests/limits。
- HPA 指标。
- pod disruption budget。
- liveness/readiness probes。
- secret references。
- DB/Redis connection。
- ingress。
- network policy，P1。

## 5. 配置管理

- 环境变量只放启动和基础连接信息。
- 业务配置存在数据库，并版本化。
- 配置变更写 audit log。
- Data Plane 使用 Redis pub/sub 或配置版本轮询刷新本地缓存。
- 所有配置支持导出备份。

## 6. 健康检查

| Endpoint | 说明 |
|---|---|
| `/healthz` | 进程存活，不查外部依赖 |
| `/readyz` | readiness；Gateway 报告 `database_gateway_store` 是否可用，Control Plane 执行 DB `select 1`；Redis 当前仅回显配置地址，不作为 readiness gate |
| `/metrics` | Prometheus metrics |

## 7. 备份与恢复

| 数据 | 备份策略 |
|---|---|
| PostgreSQL | 每日全量 + WAL/PITR |
| Redis | 主要为缓存，但 rate/queue 需按实现考虑持久化 |
| Object Storage | 生命周期 + 版本化可选 |
| 配置导出 | 每日导出 JSON/YAML |
| Ledger | 不删除，归档前校验 |

恢复演练：每月至少一次 staging 恢复。

最小 PostgreSQL 备份/恢复脚本：

- 备份：`scripts/db/backup.ps1`。`-OutputPath` 是输出的 PostgreSQL custom-format dump 文件；未传时默认写入 `backups/db/postgres-<timestamp>.dump`，也可用 `BACKUP_ROOT` 改默认根目录。若目标文件已存在，必须显式传 `-Force` 才会覆盖。
- 恢复：`scripts/db/restore.ps1`。`-InputPath` 是 dump 文件，或是包含 `postgres.dump` 的备份目录。恢复默认只 dry-run；只有传 `-Force` 才执行 `pg_restore`。脚本不自动创建/删除数据库，也不传 `--clean`。
- 连接信息：优先使用 `-DatabaseUrl`，也支持 `DATABASE_URL` / `POSTGRES_URL`；未传 URL 时使用 `-DbHost`、`-DbPort`、`-DbName`、`-DbUser`、`-DbPassword` 或对应 `PG*` 环境变量。脚本日志会隐藏 URL 或连接串中的密码，实际密码通过 `PGPASSWORD` 传给 PostgreSQL 工具。
- 检查模式：`-DryRun` 只打印计划；`-Preflight` 做参数和路径校验，并提示 `pg_dump` / `pg_restore` 是否可用。检查模式不要求本机安装 Docker、`psql`、`pg_dump` 或 `pg_restore`，也不会创建目录或执行数据库命令。
- 离线契约自测：`scripts/db/verify_backup_restore_contract.ps1` 会验证 dry-run 不创建 dump、密码不回显、backup overwrite `-Force` 语义、restore 默认 dry-run、missing dump preflight 失败、`-Force`/`-DryRun` 冲突和目录输入解析；该自测不执行 `pg_dump` / `pg_restore`。

示例：

```powershell
# Set DATABASE_URL or PG* variables from a secret manager before running.
.\scripts\db\backup.ps1 -DryRun -OutputPath .\backups\db\postgres-dev.dump
.\scripts\db\backup.ps1 -OutputPath D:\backups\fubox\postgres-20260602.dump
.\scripts\db\restore.ps1 -InputPath D:\backups\fubox\postgres-20260602.dump
.\scripts\db\restore.ps1 -Force -InputPath D:\backups\fubox\postgres-20260602.dump
.\scripts\db\verify_backup_restore_contract.ps1
```

## 8. 监控和告警

核心 dashboard：

- Traffic overview。
- Provider/channel/key health。
- Error taxonomy。
- Streaming health。
- Billing/ledger lag。
- DB/Redis health。
- Cost by project/model/provider。
- Admin API latency。

告警见 `docs/08_OBSERVABILITY_SPEC.md`。

Current E14-003 template boundary:

- Active Grafana queries and Prometheus alert rules only use landed gateway
  metrics: requests, errors, latency histogram, TTFT histogram, fallback, cost,
  and service up.
- Ledger lag, event lag, provider key cooldown, and provider/channel/key/model
  dimensions are still pending runtime metrics. Treat matching dashboard panels
  as placeholders only; they intentionally return no series.
- Do not page from pending metrics. Add active alerts only after `/metrics`
  exposes the new series, the label cardinality contract is reviewed, and
  `examples/observability/validate_templates.py` is updated.

## 9. 事故处理 Runbook

### Provider 大量 5xx

1. 查看 provider/channel error dashboard。
2. 确认是否单 provider、单 region、单 channel。
3. 暂时降低优先级或 manual disable。
4. 检查 fallback 是否正常。
5. 发送客户/内部通知。
6. 事后复盘：是否需要调整健康阈值。

### 大量 429

1. 查看 provider key 维度。
2. 确认 Retry-After 是否被识别。
3. 扩充 key 池或降低该 key 权重。
4. 检查用户侧是否流量异常。
5. 检查 rate limit 配置。

### Ledger lag

1. 查看 event queue backlog。
2. 扩容 billing worker。
3. 确认 DB lock/slow query。
4. 暂时限制新请求或进入只读/保守模式。
5. lag 恢复后执行对账。

### 数据库慢

1. 查看 slow query。
2. 临时关闭重型 dashboard 查询。
3. 检查 request_logs 分区/索引。
4. 清理过期日志或转移到冷存储。
5. 对慢查询补索引并回归。

### Provider key 泄漏

1. 立即禁用相关 key。
2. 轮换上游 provider key。
3. 查询 audit log 和 request log 影响范围。
4. 通知受影响团队。
5. 检查日志是否泄漏 Authorization。
6. 发布 postmortem。

## 10. 发布流程

1. 合并 release branch。
2. CI 全量通过。
3. 构建镜像，生成 SBOM 和 checksum。
4. 部署 staging。
5. 运行 migration。
6. 跑 E2E/load/chaos。
7. 评审 release checklist。
8. 生产 canary 5%。
9. 观察 30-60 分钟关键指标。
10. 扩大到 50%。
11. 全量。
12. 归档 release notes。

## 11. 回滚策略

- 应用回滚：保留上一版本镜像。
- 配置回滚：Route policy、price、channel 配置版本化。
- 数据库回滚：优先前向修复；破坏性 migration 禁止无回退方案。
- Provider key 回滚：保留 key 历史状态，但不泄漏 secret。

## 12. 生产 readiness checklist

详见 `project/RELEASE_CHECKLIST.md`。

### 12.1 可执行 release gate

最小可执行门禁脚本：

```powershell
.\scripts\release_check.ps1
```

默认模式是 check/dry-run，不执行破坏性操作：

- 备份 gate 总会先运行 `scripts/db/verify_backup_restore_contract.ps1`；若 DB 参数和 `pg_dump` 可用，再调用 `scripts/db/backup.ps1 -Preflight`。这两步都不会创建目录，也不会执行真实 dump/restore。
- Helm 总是先做静态 chart 校验；安装 Helm 时额外运行 `helm lint` 和 `helm template`。
- Smoke 默认只做 compose/SDK smoke 脚本自检；需要请求本机运行中的服务时，显式加 `-RunRuntimeSmoke`。
- 安全扫描默认跳过网络型漏洞审计；每次 `security` gate 都会生成 SBOM/provenance/manifest/SHA256SUMS artifacts 到 `artifacts/supply-chain`；发布候选需要补跑网络审计时，显式加 `-OnlineSecurity`。
- 输出为 JSON summary，子命令输出会做脱敏，不应包含 secret/env 原文。

建议归档命令：

```powershell
.\scripts\release_check.ps1 -SummaryPath .\artifacts\release-gate-summary.json
```

局部预检可用于缺少外部依赖的本机环境：

```powershell
.\scripts\release_check.ps1 -Checks backup,helm,smoke
```

GitHub 首次 push 前的本地收口流程：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/release_check.ps1 -Checks security
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/release_check.ps1 -Checks backup,helm,smoke
.\scripts\scan_secrets.ps1
```

首推前记录要求：

- `security` gate 会运行 secret scan、supply-chain structural scan，并生成 `artifacts/supply-chain` 下的 SBOM、provenance、manifest 和 checksum。默认不做联网漏洞审计；需要 RC 级联网审计时补跑 `-OnlineSecurity` 并归档新的 summary。
- `backup` 的缺 DB 参数或缺 `pg_dump`、`helm` 的缺 Helm、`smoke` 的缺 Docker 或 SDK 工具，在默认 dry-run/preflight 下只表示本机能力不足。保留 `local warning:` 原文摘要、补跑环境和负责人；不要把这些 warning 写成 staging 通过。
- `-RunRuntimeSmoke` 是显式 runtime 请求；此模式缺 Docker、`node` 或 `npm` 会 fail。只有在 compose stack 已启动且目标环境允许 runtime 请求时使用。
- `scripts\scan_secrets.ps1` 失败时阻断首次 push。不要把 secret/env 原文放入 issue、release note、summary 注释或聊天记录。

判定规则：

- `overallStatus=pass`：可执行门禁通过。
- `overallStatus=warn`：没有失败，但存在 warning/skip。常见原因是本机缺少 Docker、Helm、`pg_dump`、`node` 或 `npm`，未配置 DB，或默认跳过网络/runtime 检查；release review 必须记录是否接受，或在具备工具的环境补跑。
- `overallStatus=fail`：至少一个 check 失败，或 `-TreatWarningsAsFailures` 将 warning/skip 提升为失败；阻断发布。如需继续，必须记录负责人、风险、补偿措施和豁免有效期。

CI 或正式 RC 可以使用 `-TreatWarningsAsFailures` 将 warning/skip 也作为阻断项。

本机缺工具 warning 约定：

- Backup：`scripts/db/verify_backup_restore_contract.ps1` 必须先通过；缺 DB 参数或 `pg_dump` 时只跳过 backup execution preflight，并以 `local warning:` 记录。该 warning 不代表 staging 恢复演练完成。
- Helm：有 Python 时仍运行 `python deploy/helm/validate_chart.py --skip-helm`；缺 Helm 时跳过 `helm lint/template`，并以 `local warning:` 记录。该 warning 不代表 K8s staging 已部署。
- Smoke：默认只要求 compose dry-run；缺 `node/npm` 时 SDK smoke dry-run 以 `local warning:` 记录为跳过。缺 Docker 时 runtime compose smoke 在默认模式下是 warning；如果显式传 `-RunRuntimeSmoke`，缺 Docker 或 SDK runtime 依赖会变为 `fail`。
