# 数据模型与数据库规划

版本：0.1-dev-start  
日期：2026-06-01

## 1. 数据库选择

P0 推荐 PostgreSQL。MySQL 可作为 P1 兼容目标，SQLite 仅用于本地 demo。

## 2. 命名规范

- 主键：`id uuid`。
- 多租户字段：所有业务表包含 `tenant_id`。
- 时间字段：`created_at`、`updated_at`、`deleted_at`，使用 UTC。
- 状态字段：枚举字符串，避免魔法数字。
- 敏感字段：加密或 hash，不可明文。
- 金额字段：使用整数最小单位或 decimal，不用 float。
- 价格版本：不覆盖历史，新增 version。

## 3. 核心表

### tenants

| 字段 | 类型 | 说明 |
|---|---|---|
| id | uuid | 主键 |
| name | text | 租户名 |
| status | text | active/suspended |
| default_timezone | text | 默认统计时区 |
| created_at | timestamptz | 创建时间 |

### teams / projects / users

团队和项目用于权限、预算和成本归属。用户登录信息与外部身份绑定分离。

### virtual_keys

| 字段 | 类型 | 说明 |
|---|---|---|
| id | uuid | 主键 |
| tenant_id/project_id | uuid | 归属 |
| name | text | 名称 |
| key_prefix | text | 前缀，用于快速识别 |
| secret_hash | text | secret hash，不保存明文 |
| status | text | active/disabled/expired |
| default_profile_id | uuid | 默认 profile |
| expires_at | timestamptz | 过期时间 |
| last_used_at | timestamptz | 最近使用 |
| ip_allowlist | jsonb | IP 限制 |
| metadata | jsonb | 业务扩展 |

索引：

- unique `(tenant_id, key_prefix)`
- `(project_id, status)`
- `(last_used_at)`

### api_key_profiles

| 字段 | 类型 | 说明 |
|---|---|---|
| id | uuid | 主键 |
| tenant_id/project_id | uuid | 归属 |
| name | text | profile 名 |
| inbound_protocol | text | openai/anthropic/gemini/auto |
| default_protocol_mode | text | compatible/native/adapter |
| model_aliases | jsonb | 客户端模型名到 canonical model 映射 |
| allowed_models | jsonb | 模型白名单 |
| allowed_channel_tags | jsonb | 渠道 tag 限制 |
| trace_header_rules | jsonb | trace/thread 读取规则 |
| payload_policy_id | uuid | payload 策略 |

### providers

供应商类型表，内置 provider 使用 code 标识。

### channels

| 字段 | 类型 | 说明 |
|---|---|---|
| id | uuid | 主键 |
| provider_id | uuid | Provider |
| name | text | 渠道名 |
| endpoint | text | 上游 endpoint |
| protocol_mode | text | openai_compatible/native_proxy/adapter_transform |
| status | text | enabled/disabled/degraded |
| priority | int | 默认优先级 |
| weight | int | 权重 |
| tags | jsonb | 标签 |
| model_mappings | jsonb | 上游模型映射 |
| request_overrides | jsonb | 请求改写规则 |
| timeout_policy | jsonb | 超时配置 |
| probe_policy | jsonb | 探测配置 |
| health_score | numeric | 健康分 |

索引：

- `(tenant_id, status)`
- GIN `(tags)`
- `(provider_id, status)`

### provider_keys

| 字段 | 类型 | 说明 |
|---|---|---|
| id | uuid | 主键 |
| channel_id | uuid | 归属渠道 |
| key_alias | text | 展示名 |
| encrypted_secret | bytea/text | 加密密钥 |
| status | text | enabled/cooldown/auth_failed/quota_exhausted/manual_disabled |
| health_score | numeric | 健康分 |
| cooldown_until | timestamptz | 冷却到期 |
| last_error_code | text | 最近错误 |
| rpm_limit/tpm_limit | int | 上游限制 |
| current_window_state | jsonb | 当前窗口统计，可也存在 Redis |

### canonical_models

| 字段 | 类型 | 说明 |
|---|---|---|
| id | uuid | 主键 |
| model_key | text | 内部唯一模型名 |
| display_name | text | 展示名 |
| family | text | 模型族 |
| capabilities | jsonb | text/tool/vision/audio/reasoning/responses |
| context_length | int | 上下文长度 |
| max_output_tokens | int | 最大输出 |
| default_price_book_id | uuid | 默认价格 |
| visibility | text | public/internal/hidden |
| status | text | active/deprecated |

### model_associations

| 字段 | 类型 | 说明 |
|---|---|---|
| id | uuid | 主键 |
| canonical_model_id | uuid | 内部模型 |
| channel_id | uuid nullable | 指定渠道 |
| channel_tag | text nullable | tag 关联 |
| model_pattern | text nullable | regex |
| upstream_model_name | text nullable | 上游模型 |
| priority | int | 优先级 |
| conditions | jsonb | 条件 |
| enabled | bool | 是否启用 |

### route_policies

保存路由策略 DSL 和版本。

### request_logs

P0 可使用 PostgreSQL 分区表，P1 建议 ClickHouse。

字段建议：

- id、tenant_id、project_id、virtual_key_id、trace_id、thread_id。
- requested_model、canonical_model_id、resolved_provider_id、resolved_channel_id、provider_key_id。
- status、http_status、error_owner、error_code、stream_end_reason。
- input_tokens、output_tokens、cache_read_tokens、cache_write_tokens、reasoning_tokens。
- estimated_cost、final_cost、currency、ledger_entry_id。
- latency_ms、ttft_ms、stream_duration_ms、tokens_per_second。
- payload_stored、payload_object_ref、redacted。
- route_decision_snapshot jsonb。
- created_at。

索引：

- `(tenant_id, created_at desc)`
- `(project_id, created_at desc)`
- `(virtual_key_id, created_at desc)`
- `(canonical_model_id, created_at desc)`
- `(resolved_channel_id, created_at desc)`
- `(error_code, created_at desc)`
- GIN `(route_decision_snapshot)` 可选。

### provider_attempts

每次上游尝试独立记录，避免 request log 只能看到最终结果。

### ledger_entries

账务事实表。

| 字段 | 类型 | 说明 |
|---|---|---|
| id | uuid | 主键 |
| tenant_id/project_id | uuid | 归属 |
| wallet_id | uuid | 钱包 |
| request_id | uuid nullable | 关联请求 |
| trace_id | text | trace |
| entry_type | text | reserve/settle/refund/adjust/expire |
| amount | decimal/int | 金额，正负明确 |
| currency | text | 币种或内部点数 |
| status | text | pending/confirmed/reversed |
| idempotency_key | text | 幂等键 |
| price_version_id | uuid | 使用价格版本 |
| usage_snapshot | jsonb | 结算用量快照 |
| policy_snapshot | jsonb | 计费策略快照 |
| created_at | timestamptz | 时间 |

唯一索引：`(tenant_id, idempotency_key)`。

### price_books / price_versions

价格版本不可覆盖。

### audit_logs

所有管理操作、密钥查看、配置变更、账务调账、导出操作写入 append-only audit log。

## 4. 分区和保留策略

| 表 | P0 策略 | P1 策略 |
|---|---|---|
| request_logs | 按月或按周分区 | ClickHouse |
| provider_attempts | 跟随 request_logs | ClickHouse |
| audit_logs | 按月分区，长期保留 | 独立审计库 |
| ledger_entries | 不删除，只归档 | 不删除，只归档 |
| raw_payload | 对象存储，按 policy TTL | 对象存储生命周期 |

## 5. 迁移原则

- 所有 schema migration 必须可重复执行。
- 破坏性字段变更必须两阶段：新增字段 -> 双写 -> 回填 -> 切读 -> 删除旧字段。
- 账务表禁止无审计修改。
- 配置表需要 `version` 或 `updated_at` 用于缓存失效。
