# New API / One API / AxonHub 迁移规划

版本：0.1-dev-start  
日期：2026-06-01

## 1. 迁移目标

降低用户替换成本。迁移工具必须支持 dry-run、差异报告、导入回滚和影子验证。

## 2. 迁移对象

| 来源 | P0 导入 | P1 导入 |
|---|---|---|
| New API | 渠道、模型映射、用户、令牌、余额、分组、倍率、价格 | 日志摘要、订阅、支付配置映射 |
| One API | 渠道、模型映射、用户、token、额度、分组 | 兑换码、公告等运营配置 |
| AxonHub | Provider/channel、model association 思路可兼容 | Profile、trace header rules、request override |
| LiteLLM | provider config、model list、virtual key | route policy |

## 3. 导入流程

```text
Upload source dump/config
  -> Parse
  -> Validate
  -> Map to internal model
  -> Dry-run report
  -> User confirms
  -> Apply in transaction or staged batches
  -> Verify counts
  -> Generate rollback snapshot
  -> Shadow traffic optional
```

## 4. 映射策略

### 模型映射

New API/One API 原模型映射转换为：

```text
原对外模型名 -> Canonical Model
原渠道模型名 -> Channel Mapping
原渠道组/分组 -> Channel Tags + Profile restrictions
原权重/优先级 -> Model Association priority/weight
```

### 额度和余额

- 用户余额导入为 Wallet balance。
- 赠送额度导入为 Credit Grant。
- 分组倍率导入为 Billing Policy 或 Price Modifier。
- 无法准确迁移的订阅规则进入人工确认列表。

### 令牌

- 若源系统无法导出明文 token，则保持 hash 导入或要求用户重新生成。
- 不允许把旧系统明文 token 写入日志。

## 5. Dry-run Report

报告必须包含：

- 成功解析数量。
- 将创建/更新/跳过的对象。
- 无法映射项。
- 需要人工确认项。
- 潜在风险，例如模型名冲突、价格缺失、重复用户。
- 回滚方案。

### 内部模型映射报告

`scripts/importers/import-internal-mapping-report.ps1` 接收 New API / One API importer 已生成的 JSON dry-run report，不直接读取源系统 dump，不写数据库，也不输出 secret material。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\importers\import-internal-mapping-report.ps1 -InputPath examples\importer_samples\internal_mapping_report_input.sample.json
```

输出结构化 JSON，核心字段：

- `counts`：输入 report、源对象、canonical model、model association、channel mapping、冲突和人工确认项数量。
- `canonical_models`：将导入或更新的内部 canonical model 预览，默认 `visibility=internal`，价格和限额需人工确认。
- `model_associations`：将源 requested model 绑定到 canonical model 和 source channel 的 association 预览。
- `channel_mappings`：按 source channel 聚合的 requested/upstream model mapping。
- `conflicts`：requested model 多 canonical、缺失 channel 引用、同 channel mapping 不一致等阻断或风险项。
- `manual_review_items`：可见性、价格、channel 绑定、源 report warnings/unsupported fields 等人工确认项。
- `next_steps`：进入 apply + rollback snapshot 前的处理建议。

### Apply plan / rollback snapshot

`scripts/importers/import-apply-plan.ps1` 接收 `import-internal-mapping-report.ps1` 生成的 internal mapping dry-run report，输出 apply plan 和 rollback snapshot contract。该脚本默认只读 dry-run，不连接数据库、不写入数据库、不接收或输出 provider secret material。真实 apply writer 尚未实现；传入 `-Apply` 必须同时显式传 `-Force`，但当前切片即使 `-Apply -Force` 也会拒绝执行并说明没有写库。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\importers\import-apply-plan.ps1 -InputPath examples\importer_samples\internal_mapping_report_output.sample.json
```

输出结构化 JSON，核心字段：

- `counts`：source object 数量、planned creates/updates/skips、conflicts、rollback snapshot entry 数量。
- `planned_creates` / `planned_updates` / `planned_skips`：每个 plan item 都包含 `operation_id`、`idempotency_key`、target natural key、原因和 rollback snapshot entry id。
- `conflicts`：从 mapping report 继承的阻断项；当前样例中 requested model 冲突和 missing channel 会把关联 operation 标为 skip。
- `rollback_snapshot`：只生成 `dry_run_shape_only` 形状，真实 before image 必须由未来 DB apply writer 在事务前采集并持久化。
- `apply_contract`：明确 `database_writes=false`、`real_apply_status=not_implemented`。

样例 contract 验证命令：

```powershell
$planJson = powershell -NoProfile -ExecutionPolicy Bypass -File scripts\importers\import-apply-plan.ps1 -InputPath examples\importer_samples\internal_mapping_report_output.sample.json
$plan = $planJson | ConvertFrom-Json
if (-not $plan.dry_run -or $plan.apply_supported -or $plan.apply_contract.database_writes) { throw "apply plan must stay dry-run/read-only" }
if ($plan.counts.planned_creates -ne 6 -or $plan.counts.planned_updates -ne 0 -or $plan.counts.planned_skips -ne 6 -or $plan.counts.conflicts -ne 2) { throw "unexpected apply plan counts" }
if (-not $plan.idempotency_key -or -not $plan.planned_creates[0].operation_id -or $plan.rollback_snapshot.entries.Count -ne $plan.counts.rollback_snapshot_entries) { throw "missing idempotency/rollback fields" }
if ($planJson -match 'sk-[A-Za-z0-9_-]+|(?i:bearer\s+[A-Za-z0-9._~+/=-]{8,})|[A-Za-z]:[\\/]') { throw "apply plan output leaked secret-like material or an absolute local path" }
```

## 6. 影子验证

P1 可支持：

- 新旧网关并行。
- 同请求只让旧系统返回，新系统 shadow 路由不扣费。
- 对比 route decision、上游 provider、估算成本、错误。

## 7. 验收

- 样例 New API dump dry-run 成功。
- 样例 One API dump dry-run 成功。
- 导入后对象数量和报告一致。
- 重复导入不会重复创建关键对象。
- 失败导入可回滚。
- 导入后的 `/v1/models` 与预期可见模型一致。
- 导入后的典型 API Key 可完成一次 chat stream 请求。
