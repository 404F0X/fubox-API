# 安全、隐私、合规与许可证规划

版本：0.1-dev-start  
日期：2026-06-01

## 1. 安全目标

AI Gateway 是所有上游 provider key、用户数据、prompt、账务和权限的集中点，因此安全不能后补。

P0 必须做到：

- Provider key 不明文存储。
- Virtual key 只存 hash。
- 管理后台 RBAC 后端强校验。
- 审计日志覆盖关键操作。
- Payload 存储可控、可脱敏、可禁用。
- 依赖和镜像有基础供应链扫描。

## 2. Secret 管理

| Secret | 存储方式 |
|---|---|
| Virtual Key | hash，创建后只显示一次 |
| Provider API Key | envelope encryption，KMS 或主密钥 |
| OAuth client secret | 加密存储 |
| Webhook secret | 加密存储 |
| DB/Redis credentials | 环境变量或 Secret Manager |

要求：

- 密钥展示需要高权限，并写 audit log。
- Provider key 解密只发生在 Data Plane 调用前。
- 日志中自动 mask API key、Authorization、Cookie。

Request payload preview readback is metadata-only. `GET /admin/request-logs/{id}/payload` returns `payload_preview_policy_readback.v1` with stored/not-stored status, redaction status, click-to-load requirement, forbidden raw fields policy, safe next action, and audit ref presence. It must not return raw prompts, raw bodies, raw provider responses, Authorization headers, provider keys/provider key ids, payload object refs, or raw request/response payloads.

## 3. RBAC

权限域：

- tenant_admin。
- project_admin。
- provider_manage。
- key_manage。
- billing_read / billing_adjust。
- log_read_metadata / log_read_payload。
- audit_read。
- system_config。

P0 必须做后端权限中间件和单元测试。

## 3A. Virtual Key Leak Scanner Adapter

`GET /admin/virtual-keys/leak-candidates` 暴露 external scanner adapter 的 config/readback seam：`provider`、`status`、`endpoint_ref_present`、`secret_ref_present`、`webhook_ref_present`、`sync_direction`、`last_scan_marker`、`marker_counts`、`readiness`、`blocked_reason`。

`POST /admin/virtual-keys/external-scanner/handoff` 是 control-plane 本地 handoff seam，只接受 bounded finding summary：`provider`、`finding_count`、`key_prefix_present`、`key_hash_present`、`repo_ref_hash`、`severity`、`detected_at`、`signature_validated`，以及可选 `virtual_key_id`。带 `virtual_key_id` 且命中时写入 `virtual_keys.metadata.leak_detection` 的 `external_scanner_handoff` marker；不带 id 时只返回 planned marker。该 endpoint 拒绝 raw finding/raw findings、raw token/key、raw secret/hash 值、Authorization、scanner secret、webhook body、request body 或 raw payload。

当前实现只做本地 presence-only readback 和 `virtual_keys.metadata.leak_detection` marker 汇总；不连接真实 scanner、不跑 repo scan、不输出 endpoint/secret/webhook ref 值、Authorization、raw findings、raw leak payload、virtual key secret 或 secret hash。真实 provider、vault/ref resolution、webhook 验签、provider finding parser 和 live evidence 仍是 `[!]` 外部环境缺口。

## 4. SSO

P0 可先本地账号 + OIDC 草案；P1 做完整 OIDC/SAML。

企业 SSO 需求：

- OIDC discovery。
- role/group claim mapping。
- auto-provision user。
- domain allowlist。
- session timeout。
- SCIM P2。

## 5. Payload 隐私

默认不存完整 prompt/response。管理员可以按租户/项目/Profile 设置：

- metadata_only。
- hash_only。
- redacted。
- full with retention。

脱敏规则 P0：

- API key。
- Bearer token。
- 邮箱。
- 手机号。
- 常见身份证/银行卡模式，可按地区扩展。

## 6. Guardrails

P1 默认提供：

- Prompt regex mask/reject。
- Role scope：system/developer/user/assistant/tool。
- Response filter。
- 规则测试工具。
- 命中日志。

P0 可只预留 pipeline hook。

## 7. 审计日志

必须审计：

- 登录、登出、失败登录。
- 创建/删除/禁用 Virtual Key。
- 查看或导出 secret。
- 添加/修改 provider key。
- 修改价格和账务策略。
- 调账、退款、额度变更。
- 修改路由策略、模型权限。
- 导出日志或 payload。
- 修改 payload policy。

审计日志不允许普通管理员删除。

## 8. 供应链安全

CI 必须包含：

- Dependency vulnerability scan。
- Secret scan。
- SAST。
- Container image scan。
- SBOM 生成。
- Build provenance / image digest。
- Release checksum。

当前离线 dry-run 切片：

- `scripts/scan_supply_chain.ps1 -SkipNetwork` 默认不访问网络，可在本地和 CI dry-run 中运行。
- Rust 检查覆盖 `Cargo.lock` 存在性、结构、registry package checksum、git source revision pin，以及 `cargo metadata --locked`。
- npm 检查覆盖 `package.json` 邻接 lockfile、`package-lock.json` / `npm-shrinkwrap.json` 结构、registry package `resolved` 与 `integrity` 覆盖。
- Docker/Compose 检查覆盖 Dockerfile `FROM`、Compose `services`、image/build 声明、显式 tag、`latest`、sha256 digest pinning；未 digest-pinned 先作为 provenance warning。
- CI 检查覆盖 `scan_supply_chain.ps1 -SkipNetwork` 调用，以及 `generate_supply_chain_artifacts.ps1` 生成 SBOM/provenance/checksum artifacts 后上传。
- Artifact 生成命令：`scripts/generate_supply_chain_artifacts.ps1 -OutputDirectory artifacts/supply-chain`，输出 `sbom.cyclonedx.json`、`provenance.intoto.json`、`manifest.json` 和 `SHA256SUMS`。
- 当前 SBOM/provenance/checksum artifacts 是离线生成的构建证据，不代表已完成联网漏洞扫描、真实容器镜像扫描或 digest pinning。
- 缺少 Docker、trivy、grype、cargo-audit 或 npm audit 时仅 warning/skip；联网漏洞扫描只在未传 `-SkipNetwork` / `-Offline` 时执行。
- 自检命令：`scripts/test_supply_chain_scan.ps1`、`scripts/test_supply_chain_artifacts.ps1`。

## 9. 许可证边界

前期调研项目包括 AGPL、Apache、LGPL 等。开发策略：

- 不复制 New API AGPL 代码。
- 不复制 AxonHub `llm/` 等可能 LGPL 代码到闭源核心，除非法务确认。
- 可做 clean-room：借鉴产品概念、公开 API 行为和配置迁移，不复制实现。
- 第三方依赖进入 `THIRD_PARTY_NOTICES.md`。

## 10. 验收

- DB 中搜索不到明文 Virtual Key 和 Provider Key。
- 低权限用户不能查看 payload 和账务调账入口。
- 修改价格、Provider Key、路由策略都会产生 audit log。
- Secret scan 在 CI 中启用并阻断。
- Dependency scan 高危漏洞必须修复或有批准豁免。
