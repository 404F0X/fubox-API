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

## 11. Ledger Adjustment Execute Live Smoke Runbook

This section is the acceptance runbook for TODO lane `E11-007-S9`. It covers the
Control Plane ledger adjustment/refund `mode=execute` smoke created in S6 and
wired into the test/release gates in S8.

### 11.1 Default Contract-Only Commands

These commands must not require Docker, Postgres, Redis, or a running Control
Plane. They verify the smoke fixture, S4 transaction contract markers, the
OpenAPI executor summary contract, and the test/release opt-in contract.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_contract.ps1

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_execute_smoke.ps1 -ContractOnly

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test.ps1 -ControlPlaneLedgerAdjustmentExecuteSmokeOnly

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\release_check.ps1 -Checks smoke
```

Expected result:

- Direct smoke and `scripts/test.ps1` smoke-only return exit code `0`.
- `release_check.ps1 -Checks smoke` reports `mode.smoke=dry-run+contract` and
  includes `scripts/verify_control_plane_ledger_adjustment_openapi_contract.ps1`
  and `scripts/verify_control_plane_ledger_adjustment_execute_smoke.ps1 -ContractOnly`.
- No live ledger rows or audit rows are written.

### 11.2 Live Opt-In Commands

Run live smoke only when the compose stack is intentionally available. Live mode
is opt-in; do not add it to default PR checks.

Direct live smoke:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_execute_smoke.ps1
```

Test wrapper opt-in:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test.ps1 -ControlPlaneLedgerAdjustmentExecuteSmokeOnly -ControlPlaneLedgerAdjustmentExecuteSmokeLive

$env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_SMOKE_ONLY = "1"
$env:CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_SMOKE_LIVE = "1"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test.ps1
```

Release gate opt-in:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\release_check.ps1 -Checks smoke -RunRuntimeSmoke

$env:RELEASE_RUN_RUNTIME_SMOKE = "1"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\release_check.ps1 -Checks smoke
```

`RUN_RUNTIME_SMOKE=1` is also accepted by `release_check.ps1`.

### 11.3 Live Environment Requirements

Before running live smoke, ensure all of the following are true:

- Docker Desktop or Docker daemon is running and `docker compose` can inspect
  `deploy/docker-compose/docker-compose.yml`.
- Compose services `postgres` and `control-plane` are running from the current
  repository revision. The default compose file is expected unless `COMPOSE_FILE`
  is set.
- Postgres is migrated and contains the dev seed data required by the Control
  Plane smoke:
  - tenant `00000000-0000-0000-0000-000000000001`
  - project `00000000-0000-0000-0000-000000000020`
  - wallet `00000000-0000-0000-0000-000000000040`
  - active admin user `admin@example.com`
- Control Plane is reachable at `http://127.0.0.1:8081`, or
  `CONTROL_PLANE_BASE_URL` points to the live endpoint.
- Admin credentials are available. Defaults are
  `CONTROL_PLANE_ADMIN_EMAIL=admin@example.com` and
  `CONTROL_PLANE_ADMIN_PASSWORD=local-password`; alternatively set
  `CONTROL_PLANE_ADMIN_SESSION_TOKEN`.

Optional live parameters:

- `COMPOSE_FILE`: override compose file path.
- `CONTROL_PLANE_BASE_URL`: override Control Plane base URL.
- `CONTROL_PLANE_ADMIN_EMAIL` / `CONTROL_PLANE_ADMIN_PASSWORD`: override login.
- `CONTROL_PLANE_ADMIN_SESSION_TOKEN`: skip login and use an existing session.
- `CONTROL_PLANE_LEDGER_ADJUSTMENT_EXECUTE_SMOKE_KEEP_ROWS=1` or `-KeepSmokeRows`:
  keep seeded smoke ledger/audit rows for manual inspection.

### 11.4 What Live Smoke Proves

The live smoke must produce all of this evidence on the migrated schema:

- Seeds a same-tenant confirmed debit ledger entry through compose Postgres.
- Calls `POST /admin/ledger/adjustments/dry-run` with `mode=execute`.
- Apply path returns HTTP `201`, `outcome=applied`, `ledger_write=true`, and
  `audit_log_write=true`.
- Apply path includes `ledger_executor_summary_contract` with
  `schema_version=billing_ledger_postgres_executor_summary.v1`,
  `response_field=ledger_executor_summary`, `operation_key_output=omitted`,
  `error_detail_output=omitted`, `dedupe_material_echoed=false`,
  `raw_metadata_echoed=false`, and `credential_material_echoed=false`.
- Apply path includes `ledger_executor_summary` with
  `executor=control_plane_transactional_admin_ledger_adjustment_writer`,
  `operation=adjust|refund`, `outcome=applied`, `committed=true`,
  `rolled_back=false`, `statement_count=1`, `executed_statement_count=1`,
  `refused_statement_count=0`, `total_rows_affected=1`,
  `final_statement_order=1`, `final_statement_kind=insert_ledger_entry`,
  `row_count_mismatch=false`, and omitted operation-key/error-detail output.
- The inserted success audit has `resource_type=ledger_entry`, `action=ledger.refund`,
  `resource_id` equal to the inserted ledger entry id, and transaction metadata
  markers including `transactional_audit=true` and `ledger_adjustment_execute=true`.
- Idempotent replay returns HTTP `200`, `outcome=idempotent`, and does not
  increase ledger or audit counts.
- Idempotent replay includes the same executor summary contract and a
  `ledger_executor_summary` with `outcome=idempotent`, `ledger_write=false`,
  `audit_log_write=false`, `committed=true`, `rolled_back=false`,
  `statement_count=0`, `executed_statement_count=0`, `total_rows_affected=0`,
  `final_statement_order=null`, `final_statement_kind=null`, and
  `row_count_mismatch=false`.
- Refund over remaining returns HTTP `400` with `bad_request` and does not
  increase ledger or audit counts.
- Concurrent refund race leaves one applied refund and one refusal, with exactly
  one confirmed credit row and one success audit for that source debit.
- Response and audit snapshot checks remain secret-safe: no raw idempotency key,
  dedupe material, raw metadata, ledger snapshots, Authorization, Cookie,
  credentials, provider key material, payload/body, operation key, raw executor
  error detail, or secret material is echoed.

### 11.5 Blocker Semantics

The direct live smoke uses exit code `2` for external blockers. A blocker is not
a pass and must not be used to close the live acceptance gap.

Expected blocker output contains `[BLOCKED]`, for example:

```text
[BLOCKED] live Docker compose control-plane/postgres availability - docker compose is unavailable ...
Control Plane ledger adjustment execute smoke is externally blocked:
```

Common blockers:

- Docker daemon is not running.
- Compose `postgres` or `control-plane` service is not running.
- Postgres is not migrated or dev seed rows are missing.
- Control Plane is unreachable.
- Admin login/session is unavailable.

Wrapper behavior:

- `scripts/test.ps1` propagates the direct live smoke non-zero exit.
- `scripts/release_check.ps1 -RunRuntimeSmoke` records the live smoke command
  with exit code `2` and the overall smoke check fails because runtime smoke was
  explicitly requested.
- Default contract-only gates continue to pass or fail based only on contract
  checks, not live environment availability.

### 11.6 Closing TODO Gaps After a Passing Live Run

After a clean live run, record the exact command, timestamp, repo commit, compose
file, and output summary in the TODO update. A passing live run is enough to
close these E11-007 backend live gaps:

- `E11-007-S4`: live verification for FK behavior, success audit actor/resource
  linkage, idempotent replay, and concurrent refund race.
- `E11-007-S6`: live Postgres/concurrency smoke no longer externally blocked.
- `E11-007-S8`: opt-in live gate verified in an environment with Docker/Postgres
  and running Control Plane.

Do not close unrelated gaps from this smoke alone. In particular, Admin UI real
execute submit flow, broader billing-ledger executor integration, staging release
approval, and any Gateway/routing live smokes remain separate acceptance items.

### 11.7 OpenAPI Semantic Validator And Client Generation

The default OpenAPI drift gate is lightweight and contract-only. Full semantic
validation and generated-client inspection are a separate E11 acceptance item;
use `docs/E11-007_LEDGER_EXECUTE_OPENAPI_VALIDATION_RUNBOOK.md`.

Default wrapper command:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1
```

Semantic/client generation opt-in commands:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -Semantic

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -ClientGeneration

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_control_plane_ledger_adjustment_openapi_semantic.ps1 -Semantic -ClientGeneration
```

The wrapper exits `0` when all requested checks pass, `1` for OpenAPI schema or
generated-client contract mismatch, and `2` for external blockers such as
missing Node/npm/Java or an offline npm package cache. Generated artifacts stay
under `.tmp\ledger-adjustment-openapi-semantic` and can be removed with
`-Clean`. Env opt-ins are also accepted, including
`CONTROL_PLANE_LEDGER_OPENAPI_SEMANTIC=1` and
`CONTROL_PLANE_LEDGER_OPENAPI_CLIENT_GENERATION=1`.

That runbook records recommended Redocly/OpenAPI Generator validator commands,
client generation commands, missing-tool/offline blocker semantics, and the
generated ledger execute/executor summary fields that must remain secret-safe.
A clean semantic/client-generation run can close the E11 OpenAPI
semantic/client-generation gap only. It does not close live Postgres, success
audit live evidence, Admin UI E2E, or billing-ledger runtime writer gaps.

## 12. Prompt Protection Provider Attempts Postgres Proof Runbook And Script

This section is the acceptance entry for TODO lanes `E13-005-S10` through
`E13-005-S16`. The detailed live proof is documented in
`docs/E13-005_PROMPT_PROTECTION_POSTGRES_PROOF_RUNBOOK.md`.

The proof covers prompt-protection reject no-side-effect evidence for:

- `POST /v1/chat/completions`
- `POST /v1/responses`
- `POST /v1/messages`
- `POST /v1beta/models/{model}:generateContent`

Expected live evidence:

- HTTP response is `400 prompt_protection_rejected` at `request_preflight`.
- `request_logs` has one latest row per unique `request_body_hash`.
- The row is `status=rejected`, `http_status=400`, `error_code=prompt_protection_rejected`.
- Payload logging is hash-only: `redaction_status=hash_only`,
  `payload_stored=false`, and no payload object reference.
- Route/provider side-effect fields remain unset before routing:
  `canonical_model_id`, `resolved_provider_id`, `resolved_channel_id`,
  `provider_key_id`, and `route_policy_version` are null.
- A left join to `provider_attempts` returns count `0`.
- The response and DB metadata do not contain raw prompt text, raw configured
  pattern values, Authorization, Cookie, bearer tokens, or provider secrets.

This live proof is opt-in. Docker/Postgres/Gateway/mock-provider unavailability
is an external blocker, not a pass. If wrapped in automation, use exit `0` only
when every endpoint and DB assertion passes, exit `1` for evidence mismatch, and
exit `2` for external blockers.

Every `-Live` or `-Live -PreflightOnly` run prints a bounded
`prompt_protection_postgres_proof_evidence_envelope.v1` before live checks. The
envelope lists required env names, endpoint catalog, SQL evidence fields,
request log hash-only fields, provider key/upstream not-called fields, and
secret-safe omission fields. It must not print URL values, tokens, DSNs,
Authorization, Cookie, raw prompt text, regex pattern values, request bodies, or
provider secrets.

Live evidence reports are opt-in with `-EvidenceReportPath` or
`PROMPT_PROTECTION_POSTGRES_PROOF_REPORT_PATH`; default contract-only gates must
not write one. The report schema is
`prompt_protection_postgres_proof_evidence_report.v1` and records per-endpoint
request hash, expected/observed response status, hash-only request-log fields,
provider_attempts/not-called fields, prompt-protection safe reason/scope,
secret-safe omission markers, bounded blocker/failure arrays, and exit `0/1/2`
status.

Report paths must resolve under `.tmp/**` or
`artifacts/prompt-protection-postgres-proof/**` with a `.json` file extension.
Repo-outside paths, `.git` paths, source/script/docs paths, and unrelated worker
locations are refused before write, and refusal output must not echo supplied
path segments or secret-like values.

Default script contract/preflight command:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_prompt_protection_postgres_proof.ps1
```

This default command must not require Docker, Gateway, Postgres, mock-provider,
or live credentials. It also verifies that `scripts\test.ps1` and
`scripts\release_check.ps1` keep the proof contract-only by default and reserve
`-Live` for explicit runtime opt-in.

Exit semantics self-test command:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_prompt_protection_postgres_proof.ps1 -SelfTestExitSemantics
```

This self-test does not connect to live services. It child-runs the default
contract path and requires exit `0`, child-runs
`-SimulateLivePreflightBlocker` and requires exit `2`, and child-runs
`-SimulateEvidenceMismatch` and requires exit `1`.

Evidence report contract self-test:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_prompt_protection_postgres_proof.ps1 -SelfTestEvidenceReportContract
```

This self-test does not connect to live services or write a live report. It
validates simulated pass, evidence mismatch, and external blocker reports for
the four endpoint catalog entries and verifies the report JSON is secret-safe.

Evidence report path-safety self-test:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_prompt_protection_postgres_proof.ps1 -SelfTestEvidenceReportPathSafety
```

This self-test validates safe report paths and unsafe path refusal without
connecting to live services or writing a live report.

Live opt-in commands:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_prompt_protection_postgres_proof.ps1 -Live

$env:PROMPT_PROTECTION_POSTGRES_PROOF_LIVE = "1"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_prompt_protection_postgres_proof.ps1
```

Live preflight without sending evidence requests:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_prompt_protection_postgres_proof.ps1 -Live -PreflightOnly
```

Unified test wrapper commands:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test.ps1 -PromptProtectionPostgresProofOnly

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test.ps1 -PromptProtectionPostgresProofOnly -PromptProtectionPostgresProofLive
```

The first command is contract-only and must not require live services. The
second command is the explicit live opt-in and preserves script exit semantics:
`0` pass, `1` evidence mismatch, and `2` external blocker.

Release smoke gate commands:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\release_check.ps1 -Checks smoke

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\release_check.ps1 -Checks smoke -RunRuntimeSmoke
```

The default release smoke gate runs Prompt Protection Postgres proof
`-ContractOnly`. `-RunRuntimeSmoke` is the only release path that invokes
`-Live`; blocker exit `2` then fails the explicit runtime smoke instead of being
reported as a default-gate failure.

A passing run can close the E13 Postgres `provider_attempts` no-side-effect gap
for the four Gateway surfaces above. It cannot close Admin UI or audit
visualization gaps; those require separate UI/audit evidence.
