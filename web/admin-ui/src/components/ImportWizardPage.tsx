import { ChangeEvent, useEffect, useMemo, useState } from "react";
import { Copy } from "./icons";

type SourcePlan = {
  applyPlanCommand: string;
  command: string;
  description: string;
  handoff: string;
  label: string;
  manual: string[];
  migratable: string[];
  source: ImportSourceKind;
};

type ParsedArtifact = {
  applyCapability: ApplyCapability;
  applyBlocked: boolean | null;
  applyOperationItems: ArtifactListItem[];
  applyReview: ApplyReviewSummary;
  artifactKind: string;
  counts: Array<[string, number | string]>;
  diffItems: ArtifactListItem[];
  dryRun: boolean | null;
  handoffs: ArtifactListItem[];
  idempotencySummary: Array<[string, number | string]>;
  importer: string;
  journalSummary: Array<[string, number | string]>;
  mappingQualitySummary: Array<[string, number | string]>;
  migratableItems: ArtifactListItem[];
  manualReviewItems: ArtifactListItem[];
  nextSteps: string[];
  nonMigratableItems: ArtifactListItem[];
  preflightStatus: string | null;
  reviewChecklist: ReviewChecklistItem[];
  rollbackSummary: Array<[string, number | string]>;
  secretSafe: boolean;
  sourceSpecificPlan: SourceSpecificPlan;
  sourceBindingItems: ArtifactListItem[];
  status: string;
  transactionSummary: Array<[string, number | string]>;
};

type ArtifactListItem = {
  detail: string;
  label: string;
  tone: "neutral" | "warn";
};

type ReviewChecklistItem = {
  key: string;
  label: string;
  passed: boolean;
};

type WorkbenchStage = {
  detail: string;
  label: string;
  nextStep: string;
  status: string;
  tone: "good" | "neutral" | "warn";
};

type ApplyCapability = {
  applySupported: boolean | null;
  databaseWrites: boolean | null;
  executor: string | null;
  localDemoDb: boolean | null;
  liveDatabaseConnection: boolean | null;
  realApplyStatus: string | null;
  refusalReason: string | null;
  sqlPlanExecutorSupported: boolean | null;
};

type ApplyReviewSummary = {
  canConfirmPlan: boolean;
  configNeeded: boolean;
  status: "blocked" | "config-needed" | "ready-for-review";
  statusLabel: string;
};

type ImportSourceKind = "newapi" | "oneapi" | "sub2api" | "unknown";

type SourceSpecificPlan = {
  artifactBlockedItems: ArtifactListItem[];
  artifactCounts: Array<[string, number | string]>;
  artifactManualItems: ArtifactListItem[];
  artifactMigratableItems: ArtifactListItem[];
  artifactSchema: string | null;
  artifactSecretSafe: boolean | null;
  artifactSummaryItems: ArtifactListItem[];
  diffItems: ArtifactListItem[];
  identityBillingItems: ArtifactListItem[];
  manualItems: ArtifactListItem[];
  migratableItems: ArtifactListItem[];
  source: ImportSourceKind;
  sourceLabel: string;
};

const SOURCE_PLANS: SourcePlan[] = [
  {
    applyPlanCommand:
      "pwsh -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\importers\\import-newapi-oneapi-generic-bridge.ps1 -SourceKind NewApi -InputPath .\\examples\\importer_samples\\new_api_openai_compatible.sample.json -OutputKind ApplyPlan -ArtifactDir .\\artifacts\\importers\\newapi",
    command:
      "pwsh -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\importers\\import-newapi-dryrun.ps1 -InputPath .\\examples\\importer_samples\\new_api_openai_compatible.sample.json",
    description: "读取 NewAPI 的 channels、groups、models、tokens 与用户余额，生成 source dry-run。",
    handoff: "token 和 provider key 只输出 alias/fingerprint，真实 secret 由 operator 在 Provider Keys 或 User Keys 路径重发。",
    label: "New API",
    manual: ["raw provider key/token 不入库", "用户 token 需要重发", "余额单位和倍率需人工核对"],
    migratable: ["渠道和供应商外形", "分组到 profile/策略草案", "模型映射和倍率摘要", "opening balance ledger 草案"],
    source: "newapi",
  },
  {
    applyPlanCommand:
      "pwsh -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\importers\\import-newapi-oneapi-generic-bridge.ps1 -SourceKind OneApi -InputPath .\\examples\\importer_samples\\one_api_openai_compatible.sample.json -OutputKind ApplyPlan -ArtifactDir .\\artifacts\\importers\\oneapi",
    command:
      "pwsh -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\importers\\import-oneapi-dryrun.ps1 -InputPath .\\examples\\importer_samples\\one_api_openai_compatible.sample.json",
    description: "读取 OneAPI 的 Channels、Groups、Models、Tokens 与 quota 字段，输出差异和 apply-plan 输入。",
    handoff: "Key 字段只允许变成 fingerprint/alias/operator handoff，不作为 provider key 或 user key 明文写库。",
    label: "One API",
    manual: ["渠道 Key 需人工录入", "Token raw key 需要重发", "Type/BaseURL/Group 语义冲突需人工处理"],
    migratable: ["渠道配置", "分组和倍率", "模型映射", "quota 到 wallet/opening balance 草案"],
    source: "oneapi",
  },
  {
    applyPlanCommand:
      "pwsh -NoProfile -ExecutionPolicy Bypass -Command \"& { New-Item -ItemType Directory -Force .\\.tmp\\importers | Out-Null; .\\scripts\\importers\\import-sub2api-dryrun.ps1 -InputPath .\\examples\\importer_samples\\sub2api_data.sample.json | Set-Content -Encoding UTF8 .\\.tmp\\importers\\sub2api.source.json; .\\scripts\\importers\\import-sub2api-apply-plan.ps1 -InputPath .\\.tmp\\importers\\sub2api.source.json }\"",
    command:
      "pwsh -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\importers\\import-sub2api-dryrun.ps1 -InputPath .\\examples\\importer_samples\\sub2api_data.sample.json",
    description: "读取 Sub2API accounts、groups、users、api_keys、subscriptions，拆分路由与身份计费计划。",
    handoff: "identity/billing apply-live 只处理 user link、wallet、opening balance、key reissue 和 subscription mapping 的安全摘要。",
    label: "Sub2API",
    manual: ["proxy/password/payment secret 不迁移", "用户 key 必须重发", "订阅支付状态和续费 scheduler 需要人工确认"],
    migratable: ["account 到 provider/channel", "group 到 profile/subscription plan", "user link/wallet lookup", "opening balance ledger import"],
    source: "sub2api",
  },
];

const VERIFY_COMMAND =
  "pwsh -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\importers\\verify-import-source-dryrun-contract.ps1";
const HANDOFF_COMMAND =
  "pwsh -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\importers\\verify-sub2api-apply-plan-contract.ps1";
const APPLY_PLAN_COMMAND =
  "pwsh -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\importers\\verify-import-apply-plan-contract.ps1";
const PROVIDER_KEY_HANDOFF_PACKET_COMMAND =
  "pwsh -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\importers\\verify-import-provider-key-operator-handoff-packet.ps1";
const APPLY_PLAN_DRYRUN_COMMAND =
  "pwsh -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\importers\\import-apply-plan.ps1 -InputPath .\\artifacts\\importers\\internal-mapping.local.json -DryRun";
const APPLY_LIVE_DEMO_COMMAND =
  "pwsh -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\importers\\invoke-import-apply-live-demo.ps1 -InputPath .\\tests\\fixtures\\importers\\apply_plan_canonical_only.sample.json -ConfirmReviewedPlan -RollbackAfterApply -Force -DemoDbPath .\\.tmp\\importers\\import_apply_live_demo.local_db.json -ArtifactPath .\\.tmp\\importers\\import_apply_live_demo.local_runtime.json";
const APPLY_LIVE_VERIFY_COMMAND =
  "pwsh -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\importers\\verify-import-apply-live-demo.ps1";
const SUB2API_IDENTITY_BILLING_COMMAND =
  "pwsh -NoProfile -ExecutionPolicy Bypass -Command \"& { New-Item -ItemType Directory -Force .\\.tmp\\importers | Out-Null; .\\scripts\\importers\\import-sub2api-dryrun.ps1 -InputPath .\\examples\\importer_samples\\sub2api_data.sample.json | Set-Content -Encoding UTF8 .\\.tmp\\importers\\sub2api.source.json; .\\scripts\\importers\\import-sub2api-identity-billing-plan.ps1 -InputPath .\\.tmp\\importers\\sub2api.source.json }\"";
const SUB2API_IDENTITY_BILLING_VERIFY_COMMAND =
  "pwsh -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\importers\\verify-sub2api-identity-billing-plan-contract.ps1";

export function ImportWizardPage() {
  const [artifactText, setArtifactText] = useState("");
  const [artifactError, setArtifactError] = useState<string | null>(null);
  const parsedArtifact = useMemo(() => {
    if (!artifactText.trim()) {
      return null;
    }

    try {
      return parseImportArtifact(artifactText);
    } catch (error) {
      return {
        error: error instanceof Error ? error.message : "artifact JSON 解析失败。",
      };
    }
  }, [artifactText]);
  const artifact = parsedArtifact && "error" in parsedArtifact ? null : parsedArtifact;
  const parseError = parsedArtifact && "error" in parsedArtifact ? parsedArtifact.error : artifactError;

  async function handleArtifactFile(event: ChangeEvent<HTMLInputElement>) {
    const file = event.currentTarget.files?.[0];
    setArtifactError(null);
    if (!file) {
      return;
    }

    try {
      setArtifactText(await file.text());
    } catch {
      setArtifactError("读取 artifact 文件失败。");
    }
  }

  return (
    <div className="dashboard-stack" aria-label="导入向导">
      <section className="summary-grid" aria-label="导入向导摘要">
        <article className="metric-card metric-card--neutral">
          <span>页面模式</span>
          <strong>reviewed plan</strong>
          <small>本地确认，不写库</small>
        </article>
        <article className="metric-card metric-card--good">
          <span>支持来源</span>
          <strong>3</strong>
          <small>New API / One API / Sub2API</small>
        </article>
        <article className="metric-card metric-card--warn">
          <span>执行模式</span>
          <strong>apply-live demo</strong>
          <small>local JSON demo DB + rollback</small>
        </article>
        <article className="metric-card metric-card--neutral">
          <span>secret 边界</span>
          <strong>omit</strong>
          <small>只保留 alias 和状态</small>
        </article>
      </section>

      <section className="distribution-command-bar" aria-label="导入向导说明">
        <div>
          <span>Import wizard</span>
          <strong>从 dry-run 进入可审阅 apply-plan 工作台</strong>
          <p>本页解析 secret-safe artifact，展示 diff、rollback、journal 和 idempotency 摘要；确认动作只记录本地 review 状态，不提交 provider key 或数据库写入。</p>
        </div>
      </section>

      <section className="admin-panel" aria-label="导入 artifact 解析">
        <div className="section-heading section-heading--compact">
          <div>
            <h2>解析 artifact</h2>
            <p>粘贴或选择 dry-run / handoff JSON，本页只在浏览器本地解析，不上传服务器。</p>
          </div>
        </div>
        <div className="form-grid">
          <label className="field field--wide">
            artifact JSON
            <textarea
              rows={8}
              value={artifactText}
              onChange={(event) => {
                setArtifactText(event.currentTarget.value);
                setArtifactError(null);
              }}
              placeholder='{"importer":"sub2api-source-dryrun","dry_run":true,"counts":{...}}'
            />
          </label>
          <label className="field">
            选择 JSON 文件
            <input accept="application/json,.json" onChange={handleArtifactFile} type="file" />
          </label>
        </div>
        {parseError ? <p className="form-status form-status--error">{parseError}</p> : null}
      </section>

      {artifact ? <ArtifactPreview artifact={artifact} /> : null}

      <section className="operator-workflow-grid" aria-label="导入来源 dry-run">
        {SOURCE_PLANS.map((plan) => (
          <article className="admin-panel bootstrap-guide" key={plan.label}>
            <div className="section-heading section-heading--compact">
              <div>
                <h2>{plan.label} apply-plan</h2>
                <p>{plan.description}</p>
              </div>
            </div>
            <div className="bootstrap-command-row">
              <code>{plan.command}</code>
              <button className="secondary-button" type="button" onClick={() => void writeClipboard(plan.command)}>
                <Copy aria-hidden="true" size={15} />
                复制
              </button>
            </div>
            <div className="bootstrap-command-row">
              <code>{plan.applyPlanCommand}</code>
              <button className="secondary-button" type="button" onClick={() => void writeClipboard(plan.applyPlanCommand)}>
                <Copy aria-hidden="true" size={15} />
                复制
              </button>
            </div>
            <div className="policy-grid">
              <div>
                <strong>可迁移</strong>
                <span>{plan.migratable.join("；")}。</span>
              </div>
              <div>
                <strong>人工处理</strong>
                <span>{plan.manual.join("；")}。</span>
              </div>
            </div>
            <p className="muted-copy">{plan.handoff}</p>
          </article>
        ))}
      </section>

      <section className="operator-workflow-grid operator-workflow-grid--handoff" aria-label="导入安全交接">
        <article className="admin-panel">
          <div className="section-heading section-heading--compact">
            <div>
              <h2>Secret-safe 规则</h2>
              <p>导入计划只允许出现可审计标识，不允许出现可用凭据。</p>
            </div>
          </div>
          <div className="policy-grid">
            <div>
              <strong>保留</strong>
              <span>provider/channel alias、model key、key alias、fingerprint、handoff packet path、状态和冲突原因。</span>
            </div>
            <div>
              <strong>禁止</strong>
              <span>raw provider key、Authorization header、session cookie、voucher code、user API key secret。</span>
            </div>
            <div>
              <strong>录入</strong>
              <span>真实 provider secret 只在 Control Plane Provider Keys 表单中由 operator 一次性输入，不从导入 artifact 复制。</span>
            </div>
            <div>
              <strong>复核</strong>
              <span>base URL、模型别名、fallback 策略、价格表绑定和不可迁移字段。</span>
            </div>
          </div>
        </article>

        <article className="admin-panel">
          <div className="section-heading section-heading--compact">
            <div>
              <h2>下一步 handoff</h2>
              <p>dry-run artifact 通过后，生成 apply-plan，再由本页确认 review 状态。</p>
            </div>
          </div>
          <div className="setup-sequence">
            <div className="bootstrap-command-row">
              <code>{VERIFY_COMMAND}</code>
              <button className="secondary-button" type="button" onClick={() => void writeClipboard(VERIFY_COMMAND)}>
                <Copy aria-hidden="true" size={15} />
                复制
              </button>
            </div>
            <div className="bootstrap-command-row">
              <code>{HANDOFF_COMMAND}</code>
              <button className="secondary-button" type="button" onClick={() => void writeClipboard(HANDOFF_COMMAND)}>
                <Copy aria-hidden="true" size={15} />
                复制
              </button>
            </div>
            <div className="bootstrap-command-row">
              <code>{APPLY_PLAN_DRYRUN_COMMAND}</code>
              <button className="secondary-button" type="button" onClick={() => void writeClipboard(APPLY_PLAN_DRYRUN_COMMAND)}>
                <Copy aria-hidden="true" size={15} />
                复制
              </button>
            </div>
            <div className="bootstrap-command-row">
              <code>{APPLY_PLAN_COMMAND}</code>
              <button className="secondary-button" type="button" onClick={() => void writeClipboard(APPLY_PLAN_COMMAND)}>
                <Copy aria-hidden="true" size={15} />
                复制
              </button>
            </div>
            <div className="bootstrap-command-row">
              <code>{PROVIDER_KEY_HANDOFF_PACKET_COMMAND}</code>
              <button className="secondary-button" type="button" onClick={() => void writeClipboard(PROVIDER_KEY_HANDOFF_PACKET_COMMAND)}>
                <Copy aria-hidden="true" size={15} />
                复制
              </button>
            </div>
            <div className="bootstrap-command-row">
              <code>{SUB2API_IDENTITY_BILLING_COMMAND}</code>
              <button className="secondary-button" type="button" onClick={() => void writeClipboard(SUB2API_IDENTITY_BILLING_COMMAND)}>
                <Copy aria-hidden="true" size={15} />
                复制
              </button>
            </div>
            <div className="bootstrap-command-row">
              <code>{SUB2API_IDENTITY_BILLING_VERIFY_COMMAND}</code>
              <button className="secondary-button" type="button" onClick={() => void writeClipboard(SUB2API_IDENTITY_BILLING_VERIFY_COMMAND)}>
                <Copy aria-hidden="true" size={15} />
                复制
              </button>
            </div>
            <p className="muted-copy">
              apply-plan 通过 contract 后，可以在本页查看 rollback journal 和 idempotency 摘要；apply/live 脚本不在本页运行，本地 demo apply-live 由 operator 在终端执行。
            </p>
          </div>
        </article>
        <article className="admin-panel">
          <div className="section-heading section-heading--compact">
            <div>
              <h2>本地 demo apply-live</h2>
              <p>入口只面向本地 JSON demo DB，执行前必须确认 reviewed apply-plan；provider key 仍只走 fingerprint/alias/operator handoff。</p>
            </div>
          </div>
          <div className="setup-sequence">
            <div className="bootstrap-command-row">
              <code>{APPLY_LIVE_DEMO_COMMAND}</code>
              <button className="secondary-button" type="button" onClick={() => void writeClipboard(APPLY_LIVE_DEMO_COMMAND)}>
                <Copy aria-hidden="true" size={15} />
                复制
              </button>
            </div>
            <div className="bootstrap-command-row">
              <code>{APPLY_LIVE_VERIFY_COMMAND}</code>
              <button className="secondary-button" type="button" onClick={() => void writeClipboard(APPLY_LIVE_VERIFY_COMMAND)}>
                <Copy aria-hidden="true" size={15} />
                复制
              </button>
            </div>
            <p className="muted-copy">输出 artifact 包含 diff/readback、idempotency、rollback journal 摘要和 secret-safe 标记；如果 reviewed plan 或 demo DB 路径未准备好，会保留 config-needed/失败原因作为下一步。</p>
          </div>
        </article>
      </section>
    </div>
  );
}

function ArtifactPreview({ artifact }: { artifact: ParsedArtifact }) {
  const [detailFilter, setDetailFilter] = useState<"all" | "migratable" | "blocked" | "handoff" | "review" | "apply">("all");
  const [reviewConfirmed, setReviewConfirmed] = useState(false);
  useEffect(() => {
    setDetailFilter("all");
    setReviewConfirmed(false);
  }, [artifact.importer, artifact.status]);
  const visiblePanels = artifactPanels(artifact, detailFilter);
  const readyForApplyReview =
    artifact.dryRun === true &&
    artifact.secretSafe &&
    artifact.reviewChecklist.every((item) => item.passed);
  const reviewState = reviewConfirmed ? "reviewed" : artifact.applyReview.statusLabel;
  const workbenchStages = buildMigrationWorkbenchStages(artifact, reviewConfirmed);
  const handoffNextSteps = buildHandoffNextSteps(artifact);

  return (
    <section className="dashboard-stack" aria-label="artifact 解析结果">
      <section className="summary-grid" aria-label="artifact 摘要">
        <article className="metric-card metric-card--neutral">
          <span>Importer</span>
          <strong>{artifact.importer}</strong>
          <small>{artifact.artifactKind}</small>
        </article>
        <article className={`metric-card ${artifact.secretSafe ? "metric-card--good" : "metric-card--warn"}`}>
          <span>secret-safe</span>
          <strong>{artifact.secretSafe ? "pass" : "review"}</strong>
          <small>页面不显示原始 JSON</small>
        </article>
        <article className="metric-card metric-card--warn">
          <span>不可迁移</span>
          <strong>{artifact.nonMigratableItems.length}</strong>
          <small>需要人工确认</small>
        </article>
        <article className="metric-card metric-card--neutral">
          <span>handoff</span>
          <strong>{artifact.handoffs.length}</strong>
          <small>密钥由 operator 录入</small>
        </article>
        <article className={`metric-card ${artifact.preflightStatus === "pass" ? "metric-card--good" : "metric-card--neutral"}`}>
          <span>preflight</span>
          <strong>{artifact.preflightStatus ?? "unknown"}</strong>
          <small>{artifact.applyBlocked === true ? "apply blocked" : artifact.applyBlocked === false ? "可进入评审" : "未提供"}</small>
        </article>
        <article className={`metric-card ${reviewConfirmed ? "metric-card--good" : artifact.applyReview.status === "blocked" ? "metric-card--warn" : "metric-card--neutral"}`}>
          <span>apply review</span>
          <strong>{reviewState}</strong>
          <small>{artifact.applyCapability.realApplyStatus ?? "dry-run only"}</small>
        </article>
      </section>

      <section className="admin-panel" aria-label="迁移工作台状态">
        <div className="section-heading section-heading--compact">
          <div>
            <h2>迁移工作台状态</h2>
            <p>按 dry-run diff、reviewed apply-plan、apply-live demo、rollback/idempotency 和 manual blockers 五段收口。</p>
          </div>
          <span className={reviewConfirmed ? "state-chip state-chip--good" : readyForApplyReview ? "state-chip state-chip--neutral" : "state-chip state-chip--warn"}>
            {reviewConfirmed ? "reviewed" : readyForApplyReview ? "ready" : "needs review"}
          </span>
        </div>
        <div className="policy-grid">
          {workbenchStages.map((stage) => (
            <div key={stage.label}>
              <strong>{stage.label}: {stage.status}</strong>
              <span>{stage.detail}</span>
              <small>{stage.nextStep}</small>
            </div>
          ))}
        </div>
      </section>

      <section className="admin-panel" aria-label="reviewed apply-plan 工作台">
        <div className="section-heading section-heading--compact">
          <div>
            <h2>reviewed apply-plan</h2>
            <p>确认前先核对 diff、preflight、rollback snapshot、journal 和 idempotency。确认不会触发 apply-live。</p>
          </div>
          <span className={reviewConfirmed ? "state-chip state-chip--good" : readyForApplyReview ? "state-chip state-chip--neutral" : "state-chip state-chip--warn"}>
            {reviewConfirmed ? "reviewed" : readyForApplyReview ? "ready" : "blocked"}
          </span>
        </div>
        <div className="policy-grid">
          <div>
            <strong>dry-run / diff</strong>
            <span>{artifact.diffItems.length > 0 ? `${artifact.diffItems.length} 项 diff 摘要可查看。` : "当前 artifact 未提供结构化 diff；请生成 apply-plan artifact。"}</span>
          </div>
          <div>
            <strong>apply-live</strong>
            <span>{applyCapabilityText(artifact.applyCapability)}</span>
          </div>
          <div>
            <strong>review gate</strong>
            <span>{artifact.applyReview.configNeeded ? "缺本地 demo runner/readback 或 live runner 配置时保持 config-needed，但可以复制下一步命令继续。" : "可先完成本地 reviewed 状态，再交给 operator 执行。"}</span>
          </div>
        </div>
        <div className="policy-grid">
          {handoffNextSteps.map((step) => (
            <div key={step.label}>
              <strong>{step.label}</strong>
              <span>{step.detail}</span>
            </div>
          ))}
        </div>
        <div className="form-actions">
          <button
            className="primary-button"
            disabled={!artifact.applyReview.canConfirmPlan}
            onClick={() => setReviewConfirmed(true)}
            type="button"
          >
            确认 apply-plan 已 review
          </button>
          <button className="secondary-button" type="button" onClick={() => void writeClipboard(APPLY_LIVE_DEMO_COMMAND)}>
            <Copy aria-hidden="true" size={15} />
            复制本地 demo apply-live 命令
          </button>
          <button className="secondary-button" type="button" onClick={() => void writeClipboard(APPLY_LIVE_VERIFY_COMMAND)}>
            <Copy aria-hidden="true" size={15} />
            复制 apply-live verifier
          </button>
        </div>
        {!artifact.applyReview.canConfirmPlan ? (
          <p className="form-status form-status--error">当前 artifact 还不能确认：必须是 dry-run、secret-safe、preflight 通过，并且 provider-key 写入只走 handoff。</p>
        ) : null}
        {reviewConfirmed ? (
          <p className="form-status form-status--success">已在本页标记 reviewed。下一步由 operator 使用 secret-safe artifact 和独立密钥录入路径执行。</p>
        ) : null}
      </section>

      <section className="admin-panel" aria-label="来源专属差异解释">
        <div className="section-heading section-heading--compact">
          <div>
            <h2>{artifact.sourceSpecificPlan.sourceLabel} 差异解释</h2>
            <p>按来源拆分渠道、token、分组、模型映射、身份计费和订阅项，明确哪些能进入 apply-plan，哪些必须人工处理。</p>
          </div>
          <span className={artifact.sourceSpecificPlan.manualItems.length > 0 ? "state-chip state-chip--warn" : "state-chip state-chip--neutral"}>
            {artifact.sourceSpecificPlan.source}
          </span>
        </div>
        <div className="policy-grid">
          {artifact.sourceSpecificPlan.artifactCounts.map(([key, value]) => (
            <div key={key}>
              <strong>{formatLabel(key)}</strong>
              <span>{String(value)}</span>
            </div>
          ))}
          <div>
            <strong>artifact schema</strong>
            <span>{artifact.sourceSpecificPlan.artifactSchema ?? "missing apply_plan_artifacts"}</span>
          </div>
          <div>
            <strong>source artifact secret-safe</strong>
            <span>{artifact.sourceSpecificPlan.artifactSecretSafe === null ? "unknown" : String(artifact.sourceSpecificPlan.artifactSecretSafe)}</span>
          </div>
        </div>
        <div className="operator-workflow-grid">
          <ArtifactItemPanel emptyText="apply_plan_artifacts 没有 migratable 分类。" items={artifact.sourceSpecificPlan.artifactMigratableItems} title="apply_plan_artifacts / migratable" />
          <ArtifactItemPanel emptyText="apply_plan_artifacts 没有 manual 分类。" items={artifact.sourceSpecificPlan.artifactManualItems} title="apply_plan_artifacts / manual" />
          <ArtifactItemPanel emptyText="apply_plan_artifacts 没有 blocked 分类。" items={artifact.sourceSpecificPlan.artifactBlockedItems} title="apply_plan_artifacts / blocked" />
        </div>
        <div className="operator-workflow-grid">
          <ArtifactItemPanel emptyText="当前 artifact 没有 source_key_fingerprint/operator handoff/user/wallet/subscription 摘要。" items={artifact.sourceSpecificPlan.artifactSummaryItems} title="source-specific handoff 摘要" />
          <ArtifactItemPanel emptyText="当前 artifact 没有来源专属可迁移项。" items={artifact.sourceSpecificPlan.migratableItems} title="来源可迁移" />
          <ArtifactItemPanel emptyText="当前 artifact 没有来源专属人工处理项。" items={artifact.sourceSpecificPlan.manualItems} title="来源人工处理" />
          <ArtifactItemPanel emptyText="当前 artifact 没有身份/计费迁移摘要。" items={artifact.sourceSpecificPlan.identityBillingItems} title="user link / wallet / subscription" />
          <ArtifactItemPanel emptyText="当前 artifact 没有来源差异摘要。" items={artifact.sourceSpecificPlan.diffItems} title="渠道 / token / 分组 / 模型映射" />
        </div>
      </section>

      <section className="admin-panel" aria-label="导入差异筛选">
        <div className="section-heading section-heading--compact">
          <div>
            <h2>差异筛选</h2>
            <p>先分开查看可迁移项、阻塞项、密钥交接和人工复核项，避免把 operator handoff 混进 apply plan。</p>
          </div>
          <span className={readyForApplyReview ? "state-chip state-chip--good" : "state-chip state-chip--warn"}>
            {readyForApplyReview ? "可进入 apply review" : "需要补齐 review"}
          </span>
        </div>
        <div className="segmented-control" aria-label="导入差异筛选" role="group">
          {[
            ["all", "全部"],
            ["migratable", "可迁移"],
            ["blocked", "不可迁移"],
            ["handoff", "密钥交接"],
            ["review", "人工复核"],
            ["apply", "apply 计划"],
          ].map(([value, label]) => (
            <button
              aria-pressed={detailFilter === value}
              className={`segmented-control__button ${detailFilter === value ? "segmented-control__button--active" : ""}`}
              key={value}
              onClick={() => setDetailFilter(value as typeof detailFilter)}
              type="button"
            >
              {label}
            </button>
          ))}
        </div>
      </section>

      <section className="operator-workflow-grid" aria-label="artifact 明细">
        <article className="admin-panel">
          <div className="section-heading section-heading--compact">
            <div>
              <h2>计数</h2>
              <p>{artifact.status}</p>
            </div>
          </div>
          <dl className="detail-list">
            {artifact.counts.map(([key, value]) => (
              <div key={key}>
                <dt>{formatLabel(key)}</dt>
                <dd>{String(value)}</dd>
              </div>
            ))}
            {artifact.transactionSummary.map(([key, value]) => (
              <div key={key}>
                <dt>{formatLabel(key)}</dt>
                <dd>{String(value)}</dd>
              </div>
            ))}
          </dl>
        </article>

        {artifact.diffItems.length > 0 ? (
          <ArtifactItemPanel emptyText="没有结构化 diff。" items={artifact.diffItems} title="dry-run diff" />
        ) : null}

        {visiblePanels.map((panel) => (
          <ArtifactItemPanel emptyText={panel.emptyText} items={panel.items} key={panel.title} title={panel.title} />
        ))}
      </section>

      <section className="operator-workflow-grid operator-workflow-grid--handoff" aria-label="rollback journal idempotency 摘要">
        <SummaryPanel emptyText="当前 artifact 没有 rollback snapshot 摘要。" rows={artifact.rollbackSummary} title="rollback" />
        <SummaryPanel emptyText="当前 artifact 没有 rollback journal 摘要。" rows={artifact.journalSummary} title="journal" />
        <SummaryPanel emptyText="当前 artifact 没有 idempotency manifest 摘要。" rows={artifact.idempotencySummary} title="idempotency" />
        <SummaryPanel emptyText="当前 artifact 没有 mapping_quality_readback 摘要。" rows={artifact.mappingQualitySummary} title="mapping quality" />
      </section>

      <section className="operator-workflow-grid operator-workflow-grid--handoff" aria-label="apply 前 review checklist">
        <article className="admin-panel">
          <div className="section-heading section-heading--compact">
            <div>
              <h2>apply 前 checklist</h2>
              <p>这些条件全部通过后，才允许把 artifact 交给 apply/live 执行者。</p>
            </div>
          </div>
          <div className="policy-grid">
            {artifact.reviewChecklist.map((item) => (
              <div key={item.key}>
                <strong>{item.passed ? "通过" : "待处理"}：{item.label}</strong>
                <span>{reviewChecklistDetail(item.key, item.passed)}</span>
              </div>
            ))}
          </div>
        </article>

        <article className="admin-panel">
          <div className="section-heading section-heading--compact">
            <div>
              <h2>handoff 确认</h2>
              <p>provider key 只走 operator 手工录入路径；本页不生成包含密钥的 apply payload。</p>
            </div>
          </div>
          {artifact.handoffs.length > 0 ? (
            <div className="policy-grid">
              <div>
                <strong>交接数量</strong>
                <span>{artifact.handoffs.length} 项 provider-key handoff 需要管理员确认。</span>
              </div>
              <div>
                <strong>执行路径</strong>
                <span>逐项使用 `POST /admin/provider-keys` 或现有 Provider Keys 页面录入真实凭据。</span>
              </div>
              <div>
                <strong>工作台下一步</strong>
                <span>先完成 source-specific executable handoff，再在 Provider Keys 工作流录入凭据并运行 recovery probe。</span>
              </div>
              <div>
                <strong>禁止项</strong>
                <span>apply plan 不得携带 raw provider key、Authorization header、session cookie 或 user API key secret。</span>
              </div>
            </div>
          ) : (
            <p className="muted-copy">当前 artifact 没有 provider-key handoff。</p>
          )}
        </article>
      </section>

      {artifact.nextSteps.length > 0 ? (
        <section className="admin-panel" aria-label="artifact 下一步">
          <div className="section-heading section-heading--compact">
            <div>
              <h2>下一步</h2>
              <p>按顺序处理，继续保持 provider key 和 user key 由人工密钥路径录入。</p>
            </div>
          </div>
          <ul className="setup-sequence">
            {artifact.nextSteps.map((step) => (
              <li key={step}>{safeText(step)}</li>
            ))}
          </ul>
        </section>
      ) : null}
    </section>
  );
}

function buildMigrationWorkbenchStages(artifact: ParsedArtifact, reviewConfirmed: boolean): WorkbenchStage[] {
  const dryRunReady = artifact.dryRun === true && artifact.diffItems.length > 0;
  const reviewReady = artifact.applyReview.canConfirmPlan;
  const applyLiveDone = artifact.applyCapability.databaseWrites === true && artifact.applyCapability.localDemoDb === true;
  const rollbackReady = artifact.rollbackSummary.length > 0 && artifact.idempotencySummary.length > 0;
  const blockerCount = artifact.nonMigratableItems.length + artifact.manualReviewItems.length + artifact.handoffs.length;

  return [
    {
      detail: dryRunReady
        ? `${artifact.diffItems.length} 项 dry-run diff 可审阅。`
        : "缺结构化 dry-run diff；先运行对应 source dry-run/apply-plan 脚本。",
      label: "dry-run diff",
      nextStep: dryRunReady ? "继续核对 source-specific 差异和 preflight。" : "复制来源 dry-run 命令生成 secret-safe artifact。",
      status: dryRunReady ? "ready" : "config-needed",
      tone: dryRunReady ? "good" : "warn",
    },
    {
      detail: reviewConfirmed
        ? "本页已标记 reviewed；该状态只作为 operator handoff，不触发写库。"
        : reviewReady
          ? "preflight、secret-safe 和 provider-key 隔离检查通过，可人工确认 reviewed。"
          : "review gate 未通过，不允许进入 apply-live。",
      label: "reviewed apply-plan",
      nextStep: reviewConfirmed ? "把 reviewed artifact 交给 demo apply-live runner。" : "完成 checklist 后点击确认 apply-plan 已 review。",
      status: reviewConfirmed ? "reviewed" : reviewReady ? "ready" : "blocked",
      tone: reviewConfirmed ? "good" : reviewReady ? "neutral" : "warn",
    },
    {
      detail: applyCapabilityText(artifact.applyCapability),
      label: "apply-live demo status",
      nextStep: applyLiveDone ? "核对 readback、rollback journal 和 verifier 输出。" : "复制本地 demo apply-live 命令；不要执行生产迁移。",
      status: applyLiveDone ? "demo-applied" : artifact.applyReview.configNeeded ? "config-needed" : "pending",
      tone: applyLiveDone ? "good" : "neutral",
    },
    {
      detail: rollbackReady
        ? `${artifact.rollbackSummary.length} 个 rollback 字段、${artifact.idempotencySummary.length} 个 idempotency 字段可读。`
        : "缺 rollback 或 idempotency 摘要；不得交给 live runner。",
      label: "rollback/idempotency",
      nextStep: rollbackReady ? "检查 rollback journal 与 replay/no-duplicate 摘要。" : "生成 apply-plan 或 apply-live demo artifact。",
      status: rollbackReady ? "ready" : "missing",
      tone: rollbackReady ? "good" : "warn",
    },
    {
      detail: blockerCount > 0
        ? `${blockerCount} 项 manual blocker/handoff 需要处理。`
        : "当前 artifact 没有 manual blocker 或 provider-key handoff。",
      label: "manual blockers",
      nextStep: blockerCount > 0
        ? "处理 source-specific handoff、provider-key handoff 和 user key reissue 后再继续。"
        : "可继续保持 reviewed handoff 或运行 demo verifier。",
      status: blockerCount > 0 ? "action-required" : "clear",
      tone: blockerCount > 0 ? "warn" : "good",
    },
  ];
}

function buildHandoffNextSteps(artifact: ParsedArtifact): ArtifactListItem[] {
  const sourceLabel = artifact.sourceSpecificPlan.sourceLabel;
  const executableCount = artifact.sourceSpecificPlan.artifactSummaryItems.filter((item) => item.label.toLowerCase().includes("executable")).length;
  const sourceHandoffCount =
    artifact.sourceSpecificPlan.artifactSummaryItems.length +
    artifact.sourceSpecificPlan.identityBillingItems.length +
    artifact.sourceSpecificPlan.manualItems.length;
  const steps: ArtifactListItem[] = [
    {
      detail:
        executableCount > 0
          ? `${sourceLabel} executable handoff 已提供 ${executableCount} 项 mode；下一步按 source-specific 命令生成或执行 reviewed apply-plan。`
          : `${sourceLabel} executable handoff 未出现在 artifact；下一步运行对应 apply-plan/identity-billing plan 命令。`,
      label: "source-specific executable handoff",
      tone: executableCount > 0 ? "neutral" : "warn",
    },
    {
      detail:
        artifact.handoffs.length > 0
          ? `${artifact.handoffs.length} 项 provider-key/user-key handoff 必须走 Provider Keys 或 User Keys 重发路径，完成后再 recovery probe。`
          : "当前 artifact 没有 provider-key handoff；继续保持 apply payload 不含 raw key。",
      label: "provider-key handoff",
      tone: artifact.handoffs.length > 0 ? "warn" : "neutral",
    },
    {
      detail:
        sourceHandoffCount > 0
          ? `${sourceHandoffCount} 项 source-specific 人工/身份计费摘要已关联到工作台下一步。`
          : "没有 source-specific handoff 摘要；先生成 source-specific apply-plan artifact。",
      label: "workbench next step link",
      tone: sourceHandoffCount > 0 ? "neutral" : "warn",
    },
  ];

  return steps;
}

function ArtifactItemPanel({
  emptyText,
  items,
  title,
}: {
  emptyText: string;
  items: ArtifactListItem[];
  title: string;
}) {
  return (
    <article className="admin-panel">
      <div className="section-heading section-heading--compact">
        <div>
          <h2>{title}</h2>
          <p>只显示安全摘要，不展示原始 payload。</p>
        </div>
      </div>
      {items.length > 0 ? (
        <div className="policy-grid">
          {items.slice(0, 8).map((item, index) => (
            <div key={`${item.label}-${index}`}>
              <strong>{item.label}</strong>
              <span>{item.detail}</span>
            </div>
          ))}
        </div>
      ) : (
        <p className="muted-copy">{emptyText}</p>
      )}
    </article>
  );
}

function SummaryPanel({
  emptyText,
  rows,
  title,
}: {
  emptyText: string;
  rows: Array<[string, number | string]>;
  title: string;
}) {
  return (
    <article className="admin-panel">
      <div className="section-heading section-heading--compact">
        <div>
          <h2>{title}</h2>
          <p>只显示 contract 摘要和值计数，不展示原始 payload。</p>
        </div>
      </div>
      {rows.length > 0 ? (
        <dl className="detail-list">
          {rows.map(([key, value]) => (
            <div key={key}>
              <dt>{formatLabel(key)}</dt>
              <dd>{String(value)}</dd>
            </div>
          ))}
        </dl>
      ) : (
        <p className="muted-copy">{emptyText}</p>
      )}
    </article>
  );
}

export default ImportWizardPage;

async function writeClipboard(value: string): Promise<void> {
  if (!navigator.clipboard?.writeText) {
    return;
  }

  try {
    await navigator.clipboard.writeText(value);
  } catch {
    // Clipboard is optional for this read-only page.
  }
}

function parseImportArtifact(raw: string): ParsedArtifact {
  const parsed = JSON.parse(raw) as unknown;
  if (!isRecord(parsed)) {
    throw new Error("artifact 必须是 JSON object。");
  }

  const serialized = JSON.stringify(parsed);
  const importer = stringValue(parsed.importer) ?? stringValue(parsed.schema) ?? "unknown";
  const artifactKind = artifactKindFor(parsed, importer);
  const counts = countsFromArtifact(parsed);
  const migratableItems = migratableItemsFromArtifact(parsed);
  const sourceArtifacts = sourceApplyPlanArtifactsRecord(parsed);
  const sourceArtifactItems = sourceApplyPlanArtifactItems(sourceArtifacts);
  const nonMigratableItems = [
    ...listItems(parsed.non_migratable_items, "type", "reason"),
    ...sourceArtifactItems.blocked,
  ].slice(0, 16);
  const handoffs = [
    ...listItems(parsed.provider_key_handoffs, "key_alias", "required_operator_path"),
    ...listItems(parsed.create_handoff_metadata, "key_alias", "required_operator_path"),
    ...sourceCategoryItems(sourceArtifacts, "manual", ["provider_key_operator_handoffs", "user_key_reissue_handoffs"]),
  ].slice(0, 16);
  const manualReviewItems = [
    ...listItems(parsed.manual_review_items, "type", "reason"),
    ...sourceArtifactItems.manual,
  ].slice(0, 16);
  const applyOperationItems = applyOperationItemsFromArtifact(parsed);
  const diffItems = diffItemsFromArtifact(parsed);
  const sourceBindingItems = sourceBindingItemsFromArtifact(parsed);
  const sourceSpecificPlan = sourceSpecificPlanFromArtifact(parsed, importer);
  const preflightStatus = preflightStatusFromArtifact(parsed);
  const applyBlocked = typeof parsed.apply_blocked === "boolean" ? parsed.apply_blocked : null;
  const nextSteps = stringArray(parsed.next_steps).map(safeText);
  const secretSafe = !containsSecretLikeArtifactText(serialized) && sourceArtifactSecretSafe(sourceArtifacts) !== false;
  const dryRun = typeof parsed.dry_run === "boolean" ? parsed.dry_run : isApplyLiveRuntimeArtifact(parsed) ? false : null;
  const providerKeyWrites = providerKeyWriteCount(parsed);
  const applyCapability = applyCapabilityFromArtifact(parsed);
  const reviewChecklist = buildReviewChecklist({
    applyOperationCount: applyOperationItems.length,
    dryRun,
    handoffCount: handoffs.length,
    manualReviewCount: manualReviewItems.length,
    nonMigratableCount: nonMigratableItems.length,
    preflightStatus,
    providerKeyWrites,
    secretSafe,
  });
  const applyReview = applyReviewFromArtifact({
    applyBlocked,
    applyCapability,
    dryRun,
    reviewChecklist,
    secretSafe,
  });

  return {
    applyCapability,
    applyBlocked,
    applyOperationItems,
    applyReview,
    artifactKind,
    counts,
    diffItems,
    dryRun,
    handoffs,
    idempotencySummary: idempotencySummaryFromArtifact(parsed),
    importer: safeText(importer),
    journalSummary: journalSummaryFromArtifact(parsed),
    mappingQualitySummary: mappingQualitySummaryFromArtifact(parsed),
    migratableItems,
    manualReviewItems,
    nextSteps,
    nonMigratableItems,
    preflightStatus,
    reviewChecklist,
    rollbackSummary: rollbackSummaryFromArtifact(parsed),
    secretSafe,
    sourceSpecificPlan,
    sourceBindingItems,
    status: statusForArtifact(parsed, nonMigratableItems.length, handoffs.length),
    transactionSummary: transactionSummaryFromArtifact(parsed),
  };
}

function inferImportSource(value: Record<string, unknown>, importer: string): ImportSourceKind {
  const source = `${importer} ${stringValue(value.source) ?? ""} ${stringValue(value.type) ?? ""}`.toLowerCase();
  if (source.includes("newapi") || source.includes("new-api")) {
    return "newapi";
  }
  if (source.includes("oneapi") || source.includes("one-api")) {
    return "oneapi";
  }
  if (source.includes("sub2api")) {
    return "sub2api";
  }

  const inputFiles = Array.isArray(value.input_files) ? value.input_files.map(String).join(" ").toLowerCase() : "";
  if (inputFiles.includes("newapi")) {
    return "newapi";
  }
  if (inputFiles.includes("oneapi")) {
    return "oneapi";
  }
  if (inputFiles.includes("sub2api")) {
    return "sub2api";
  }

  return "unknown";
}

function sourceLabelFor(source: ImportSourceKind): string {
  if (source === "newapi") {
    return "NewAPI";
  }
  if (source === "oneapi") {
    return "OneAPI";
  }
  if (source === "sub2api") {
    return "Sub2API";
  }
  return "Unknown source";
}

function sourceMigratableItemsFromArtifact(value: Record<string, unknown>, source: ImportSourceKind): ArtifactListItem[] {
  const items: ArtifactListItem[] = [];
  pushCountItem(items, value, ["providers", "source_providers", "accounts"], "providers/channels", "供应商和渠道进入 provider/channel apply-plan。");
  pushCountItem(items, value, ["channels", "source_channels", "channel_mappings"], "channels", "渠道配置进入 channel mapping review。");
  pushCountItem(items, value, ["models", "source_models", "canonical_models"], "models", "模型进入 canonical model apply-plan。");
  pushCountItem(items, value, ["associations", "model_associations"], "model associations", "模型映射进入 model association apply-plan。");
  pushCountItem(items, value, ["groups", "source_groups"], "groups", source === "sub2api" ? "分组映射到 profile 和 subscription plan 草案。" : "分组映射到 profile、倍率和可见模型草案。");
  return items;
}

function sourceManualItemsFromArtifact(value: Record<string, unknown>, source: ImportSourceKind): ArtifactListItem[] {
  const items: ArtifactListItem[] = [];
  pushCountItem(items, value, ["provider_keys", "source_provider_keys", "source_provider_key_handoffs"], "provider key handoff", "只迁移 alias/fingerprint，不迁移 raw provider key。", "warn");
  pushCountItem(items, value, ["tokens", "api_keys", "source_tokens", "source_api_keys"], "user key reissue", "旧 token/key 不能明文写库，必须通过一次性重发路径。", "warn");
  pushCountItem(items, value, ["unsupported_fields", "warnings", "conflicts"], "manual review", "不确定字段、冲突和来源特有策略必须人工处理。", "warn");
  if (source === "sub2api") {
    pushCountItem(items, value, ["proxies"], "proxy handoff", "proxy/password 字段不迁移，只保留人工配置提示。", "warn");
  }
  return items;
}

function identityBillingItemsFromArtifact(value: Record<string, unknown>, source: ImportSourceKind): ArtifactListItem[] {
  const items: ArtifactListItem[] = [];
  pushCountItem(items, value, ["users", "source_users"], "user create/link", "按 email/source id 做 user link 或 create plan，避免覆盖现有账户。");
  pushCountItem(items, value, ["wallets", "wallet_lookups"], "wallet lookup", "按 project/user 查找 wallet；缺失时进入人工确认或 create plan。");
  pushCountItem(items, value, ["opening_balances", "opening_balance_ledger_entries"], "opening balance", "余额只作为 opening balance ledger import 草案，需确认单位。");
  pushCountItem(items, value, ["subscriptions", "subscription_mappings"], "subscription mapping", "订阅只映射到 plan/status 草案，不接真实续费 scheduler。");
  pushCountItem(items, value, ["tokens", "api_keys", "source_api_keys"], "key reissue", "用户 key 只生成重发计划，不导入 raw key。", "warn");

  if (items.length === 0 && (source === "newapi" || source === "oneapi")) {
    items.push({
      detail: "NewAPI/OneAPI 的 user quota 可进入 wallet/opening balance 评审；token 仍只能重发。",
      label: "wallet/opening balance",
      tone: "neutral",
    });
  }

  return items;
}

function sourceDiffItemsFromArtifact(value: Record<string, unknown>, source: ImportSourceKind): ArtifactListItem[] {
  const items: ArtifactListItem[] = [];
  pushCountItem(items, value, ["channels", "source_channels", "channel_mappings", "accounts"], "渠道", "检查 provider、base URL、protocol、priority、weight、tags 和启停状态。");
  pushCountItem(items, value, ["tokens", "api_keys", "source_tokens", "source_api_keys"], "token/key", "只展示 key alias、prefix/fingerprint 和 reissue/handoff 状态。", "warn");
  pushCountItem(items, value, ["groups", "source_groups"], "分组", "检查 group 到 profile、模型可见性、倍率和限流策略的映射。");
  pushCountItem(items, value, ["model_mappings", "channel_mapping_entries", "model_associations", "associations"], "模型映射", "检查 requested model、canonical model 和 upstream model name。");

  if (items.length === 0) {
    items.push({
      detail: `${sourceLabelFor(source)} artifact 未提供结构化来源差异；请先运行对应 dry-run/apply-plan 脚本。`,
      label: "source diff",
      tone: "warn",
    });
  }

  return items;
}

function pushCountItem(
  rows: ArtifactListItem[],
  value: Record<string, unknown>,
  keys: string[],
  label: string,
  detail: string,
  tone: "neutral" | "warn" = "neutral",
) {
  const count = countByKeys(value, keys);
  if (count <= 0) {
    return;
  }

  rows.push({
    detail: `${count.toLocaleString()} 项。${detail}`,
    label,
    tone,
  });
}

function countByKeys(value: Record<string, unknown>, keys: string[]): number {
  const counts = isRecord(value.counts) ? value.counts : {};
  const summary = isRecord(value.summary) ? value.summary : {};
  let total = 0;

  for (const key of keys) {
    const direct = value[key] ?? value[toPascalCase(key)] ?? value[toTitleCase(key)];
    if (Array.isArray(direct)) {
      total += direct.length;
    } else if (typeof direct === "number") {
      total += direct;
    }

    const countValue = counts[key] ?? summary[key];
    if (typeof countValue === "number") {
      total += countValue;
    }
  }

  return total;
}

function toPascalCase(value: string): string {
  return value
    .split("_")
    .filter(Boolean)
    .map((part) => `${part.charAt(0).toUpperCase()}${part.slice(1)}`)
    .join("");
}

function toTitleCase(value: string): string {
  return value.charAt(0).toUpperCase() + value.slice(1);
}

function artifactKindFor(value: Record<string, unknown>, importer: string): string {
  if (isApplyLiveRuntimeArtifact(value)) {
    return "apply-live runtime";
  }
  if (importer === "importer-apply-plan-dryrun") {
    return "apply-plan";
  }
  if (importer === "internal-mapping-report-dryrun") {
    return "internal mapping";
  }
  if (stringValue(value.schema_version)?.includes("operator-handoff")) {
    return "operator handoff";
  }
  return value.dry_run === true ? "source dry-run" : "artifact";
}

function countsFromArtifact(value: Record<string, unknown>): Array<[string, number | string]> {
  const counts = isRecord(value.counts) ? value.counts : isRecord(value.summary) ? value.summary : {};
  const direct: Array<[string, number | string]> = Object.entries(counts)
    .filter((entry): entry is [string, number | string] => typeof entry[1] === "number" || typeof entry[1] === "string")
    .slice(0, 16)
    .map(([key, count]) => [key, typeof count === "number" ? count : safeText(count)]);
  if (direct.length > 0) {
    return direct;
  }

  if (isApplyLiveRuntimeArtifact(value)) {
    const plan = isRecord(value.plan) ? value.plan : {};
    const applyReadback = isRecord(value.apply_readback) ? value.apply_readback : {};
    const rollbackReadback = isRecord(value.rollback_readback) ? value.rollback_readback : {};
    return [
      ["operation_count", numberValue(plan.operation_count) ?? 0],
      ["target_after_apply", Array.isArray(value.target_after_apply) ? value.target_after_apply.length : 0],
      ["target_after_rollback", Array.isArray(value.target_after_rollback) ? value.target_after_rollback.length : 0],
      ["apply_journal_operations", Array.isArray(applyReadback.operations) ? applyReadback.operations.length : 0],
      ["rollback_journal_operations", Array.isArray(rollbackReadback.operations) ? rollbackReadback.operations.length : 0],
    ] satisfies Array<[string, number | string]>;
  }

  return direct;
}

function sourceApplyPlanArtifactsRecord(value: Record<string, unknown>): Record<string, unknown> | null {
  if (isRecord(value.apply_plan_artifacts)) {
    return value.apply_plan_artifacts;
  }
  if (Array.isArray(value.source_specific_apply_plan_artifacts)) {
    const wrapper = value.source_specific_apply_plan_artifacts.find(isRecord);
    if (wrapper && isRecord(wrapper.artifacts)) {
      return wrapper.artifacts;
    }
  }
  if (stringValue(value.schema_version) === "importer.source-specific-apply-plan-artifacts.v1") {
    return value;
  }
  return null;
}

function sourceArtifactSecretSafe(artifacts: Record<string, unknown> | null): boolean | null {
  if (!artifacts) {
    return null;
  }

  const explicitSecretSafe = booleanOrNull(artifacts.secret_safe);
  const rawProviderKeyIncluded = booleanOrNull(artifacts.raw_provider_key_material_included);
  const rawUserKeyIncluded = booleanOrNull(artifacts.raw_user_key_material_included);
  const rawEmailIncluded = booleanOrNull(artifacts.raw_email_included);

  if (rawProviderKeyIncluded === true || rawUserKeyIncluded === true || rawEmailIncluded === true) {
    return false;
  }

  return explicitSecretSafe;
}

function sourceApplyPlanArtifactCounts(artifacts: Record<string, unknown> | null): Array<[string, number | string]> {
  if (!artifacts) {
    return [];
  }

  const counts = isRecord(artifacts.classification_counts) ? artifacts.classification_counts : {};
  const rows = Object.entries(counts)
    .filter((entry): entry is [string, number | string] => typeof entry[1] === "number" || typeof entry[1] === "string")
    .map(([key, value]) => [`${key}_items`, typeof value === "number" ? value : safeText(value)] satisfies [string, number | string]);

  if (rows.length > 0) {
    return rows;
  }

  return [
    ["migratable_items", sourceCategoryItems(artifacts, "migratable").length],
    ["manual_items", sourceCategoryItems(artifacts, "manual").length],
    ["blocked_items", sourceCategoryItems(artifacts, "blocked").length],
  ];
}

function sourceApplyPlanArtifactItems(artifacts: Record<string, unknown> | null): {
  blocked: ArtifactListItem[];
  manual: ArtifactListItem[];
  migratable: ArtifactListItem[];
} {
  return {
    blocked: sourceCategoryItems(artifacts, "blocked").slice(0, 12),
    manual: sourceCategoryItems(artifacts, "manual").slice(0, 12),
    migratable: sourceCategoryItems(artifacts, "migratable").slice(0, 12),
  };
}

function sourceCategoryItems(
  artifacts: Record<string, unknown> | null,
  category: "blocked" | "manual" | "migratable",
  sectionFilter?: string[],
): ArtifactListItem[] {
  const categories = artifacts && isRecord(artifacts.categories) ? artifacts.categories : {};
  const bucket = isRecord(categories[category]) ? categories[category] : {};
  const rows: ArtifactListItem[] = [];

  for (const [section, sectionValue] of Object.entries(bucket)) {
    if (sectionFilter && !sectionFilter.includes(section)) {
      continue;
    }

    const entries = Array.isArray(sectionValue) ? sectionValue : [];
    for (const entry of entries) {
      rows.push(sourceCategoryItem(section, entry, category));
    }
  }

  return rows;
}

function sourceCategoryItem(section: string, entry: unknown, category: "blocked" | "manual" | "migratable"): ArtifactListItem {
  if (!isRecord(entry)) {
    return {
      detail: safeText(String(entry || "manual review required")),
      label: formatLabel(section),
      tone: category === "migratable" ? "neutral" : "warn",
    };
  }

  const label =
    stringValue(entry.channel_name) ??
    stringValue(entry.requested_model) ??
    stringValue(entry.alias) ??
    stringValue(entry.name) ??
    stringValue(entry.username) ??
    stringValue(entry.source_subscription_id) ??
    stringValue(entry.source_key_id) ??
    stringValue(entry.source_token_id) ??
    stringValue(entry.source_user_id) ??
    stringValue(entry.source_group_id) ??
    stringValue(entry.channel_source_id) ??
    stringValue(entry.provider_code) ??
    stringValue(entry.source_key) ??
    stringValue(entry.source_id) ??
    formatLabel(section);
  const detailParts = sourceCategoryDetailParts(section, entry);

  return {
    detail: safeText(detailParts.length > 0 ? detailParts.join(" / ") : (stringValue(entry.target_action) ?? category)),
    label: safeText(`${formatLabel(section)}: ${label}`),
    tone: category === "migratable" ? "neutral" : "warn",
  };
}

function sourceCategoryDetailParts(section: string, entry: Record<string, unknown>): string[] {
  const parts: string[] = [];
  const targetAction = stringValue(entry.target_action);
  const requiredPath = stringValue(entry.required_operator_path);
  const providerCode = stringValue(entry.provider_code);
  const providerAlias = stringValue(entry.provider_alias);
  const channelAlias = stringValue(entry.channel_alias);
  const channelSourceId = stringValue(entry.channel_source_id);
  const fingerprint = stringValue(entry.fingerprint);
  const credentialFingerprint = stringValue(entry.credential_fingerprint);
  const sourceKeyFingerprint = stringValue(entry.source_key_fingerprint);
  const rotationNextStep = stringValue(entry.rotation_next_step);
  const recoveryNextStep = stringValue(entry.recovery_next_step);
  const sourceUserId = stringValue(entry.source_user_id);
  const sourceEmailHash = stringValue(entry.source_email_hash);
  const openingBalance = stringValue(entry.opening_balance) ?? numberStringValue(entry.opening_balance);
  const usedQuota = stringValue(entry.used_quota) ?? numberStringValue(entry.used_quota);
  const unit = stringValue(entry.unit);
  const plan = stringValue(entry.plan);
  const quota = stringValue(entry.quota) ?? numberStringValue(entry.quota);
  const canonicalModel = stringValue(entry.canonical_model_key);
  const upstreamModel = stringValue(entry.upstream_model_name);
  const ratio = stringValue(entry.ratio) ?? numberStringValue(entry.ratio);

  if (targetAction) {
    parts.push(targetAction);
  }
  if (requiredPath) {
    parts.push(`operator path: ${requiredPath}`);
  }
  if (providerCode) {
    parts.push(`provider: ${providerCode}`);
  }
  if (providerAlias) {
    parts.push(`provider alias: ${providerAlias}`);
  }
  if (channelAlias) {
    parts.push(`channel alias: ${channelAlias}`);
  }
  if (channelSourceId) {
    parts.push(`channel source: ${channelSourceId}`);
  }
  if (fingerprint) {
    parts.push(`fingerprint: ${fingerprint}`);
  }
  if (credentialFingerprint) {
    parts.push(`credential fingerprint: ${credentialFingerprint}`);
  }
  if (sourceKeyFingerprint) {
    parts.push(`source_key_fingerprint: ${sourceKeyFingerprint}`);
  }
  if (sourceUserId) {
    parts.push(`source user: ${sourceUserId}`);
  }
  if (sourceEmailHash) {
    parts.push(`email hash: ${sourceEmailHash}`);
  }
  if (openingBalance) {
    parts.push(`opening balance: ${openingBalance}${unit ? ` ${unit}` : ""}`);
  }
  if (usedQuota) {
    parts.push(`used quota: ${usedQuota}`);
  }
  if (plan || quota) {
    parts.push(`subscription: ${plan ?? "review"}${quota ? ` quota ${quota}` : ""}`);
  }
  if (canonicalModel || upstreamModel) {
    parts.push(`model: ${canonicalModel ?? "canonical review"} -> ${upstreamModel ?? "upstream review"}`);
  }
  if (ratio) {
    parts.push(`ratio: ${ratio}`);
  }
  if (section.includes("key") || section.includes("provider")) {
    parts.push(`raw exported: ${String(booleanOrNull(entry.raw_key_exported) ?? booleanOrNull(entry.raw_material_exported) ?? false)}`);
    parts.push(`secret included: ${String(booleanOrNull(entry.secret_material_included) ?? false)}`);
    parts.push(`manual entry required: ${String(booleanOrNull(entry.required_manual_secret_entry) ?? booleanOrNull(entry.requires_operator_entry) ?? true)}`);
  }
  if (rotationNextStep) {
    parts.push(`rotation: ${rotationNextStep}`);
  }
  if (recoveryNextStep) {
    parts.push(`recovery: ${recoveryNextStep}`);
  }
  if (booleanOrNull(entry.apply_supported) === false) {
    parts.push("apply supported: false");
  }

  return parts;
}

function sourceArtifactSummaryItems(artifacts: Record<string, unknown> | null): ArtifactListItem[] {
  if (!artifacts) {
    return [];
  }

  const executable = isRecord(artifacts.executable_handoff) ? artifacts.executable_handoff : {};
  const applyModes = isRecord(executable.apply_modes) ? executable.apply_modes : {};
  const executableRows = Object.entries(applyModes)
    .filter((entry): entry is [string, unknown] => typeof entry[1] === "string")
    .map(([key, value]) => ({
      detail: safeText(String(value)),
      label: safeText(`executable ${formatLabel(key)}`),
      tone: String(value).includes("automatic") ? ("neutral" as const) : ("warn" as const),
    }));

  const summarySections: Array<["manual" | "blocked" | "migratable", string[]]> = [
    ["manual", ["provider_key_operator_handoffs", "user_link_candidates", "wallet_opening_balance_candidates", "subscription_mappings", "user_key_reissue_handoffs"]],
    ["blocked", ["user_key_reissue_handoffs", "raw_user_key_import", "opening_balance_direct_apply", "opening_balance_direct_apply_without_unit_review", "subscription_direct_apply_without_package_mapping"]],
    ["migratable", ["channels", "model_mappings"]],
  ];

  return [
    ...executableRows,
    ...summarySections.flatMap(([category, sections]) => sourceCategoryItems(artifacts, category, sections)),
  ].slice(0, 12);
}

function sourceSpecificPlanFromArtifact(value: Record<string, unknown>, importer: string): SourceSpecificPlan {
  const sourceArtifacts = sourceApplyPlanArtifactsRecord(value);
  const source = inferImportSource(
    {
      ...value,
      source: `${stringValue(value.source) ?? ""} ${stringValue(value.source_kind) ?? ""} ${stringValue(value.input_path) ?? ""} ${stringValue(sourceArtifacts?.source_system) ?? ""}`,
    },
    importer,
  );
  const sourcePlan = SOURCE_PLANS.find((plan) => plan.source === source);
  const sourceLabel = sourcePlan?.label ?? sourceLabelFor(source);
  const sourceArtifactItems = sourceApplyPlanArtifactItems(sourceArtifacts);
  const migratableItems: ArtifactListItem[] = [
    ...sourceArtifactItems.migratable,
    ...listItems(value.source_migratable_items, "type", "recommended_path"),
    ...sourceMigratableItemsFromArtifact(value, source),
    ...(sourcePlan?.migratable.map((item) => ({
      detail: item,
      label: sourceLabel,
      tone: "neutral" as const,
    })) ?? []),
  ].slice(0, 8);
  const manualItems: ArtifactListItem[] = [
    ...sourceArtifactItems.manual,
    ...listItems(value.source_manual_items, "type", "reason"),
    ...listItems(value.manual_review_items, "type", "reason"),
    ...sourceManualItemsFromArtifact(value, source),
    ...(sourcePlan?.manual.map((item) => ({
      detail: item,
      label: sourceLabel,
      tone: "warn" as const,
    })) ?? []),
  ].slice(0, 8);
  const identityBillingItems: ArtifactListItem[] = [
    ...sourceCategoryItems(sourceArtifacts, "manual", ["user_link_candidates", "wallet_opening_balance_candidates", "user_key_reissue_handoffs", "subscription_mappings"]),
    ...sourceCategoryItems(sourceArtifacts, "blocked", ["raw_user_key_import", "opening_balance_direct_apply", "opening_balance_direct_apply_without_unit_review", "subscription_direct_apply_without_package_mapping"]),
    ...listItems(value.identity_billing_items, "type", "recommended_path"),
    ...listItems(value.user_key_reissue_plan, "user_alias", "recommended_path"),
    ...listItems(value.subscription_mapping_plan, "subscription_id", "recommended_path"),
    ...identityBillingItemsFromArtifact(value, source),
  ].slice(0, 8);

  return {
    artifactBlockedItems: sourceArtifactItems.blocked,
    artifactCounts: sourceApplyPlanArtifactCounts(sourceArtifacts),
    artifactManualItems: sourceArtifactItems.manual,
    artifactMigratableItems: sourceArtifactItems.migratable,
    artifactSchema: sourceArtifacts ? stringValue(sourceArtifacts.schema_version) ?? null : null,
    artifactSecretSafe: sourceArtifactSecretSafe(sourceArtifacts),
    artifactSummaryItems: sourceArtifactSummaryItems(sourceArtifacts),
    diffItems: sourceDiffItemsFromArtifact(value, source),
    identityBillingItems,
    manualItems,
    migratableItems,
    source,
    sourceLabel,
  };
}

function mappingQualitySummaryFromArtifact(value: Record<string, unknown>): Array<[string, number | string]> {
  const readback = isRecord(value.mapping_quality_readback) ? value.mapping_quality_readback : null;
  if (!readback) {
    return [];
  }

  const counts = isRecord(readback.mapping_counts) ? readback.mapping_counts : {};
  const conflicts = isRecord(readback.conflicts) ? readback.conflicts : {};
  const handoff = isRecord(readback.operator_handoff_refs_presence) ? readback.operator_handoff_refs_presence : {};
  const rows: Array<[string, number | string]> = [];

  pushSummaryRow(rows, "schema", stringValue(readback.schema_version));
  pushSummaryRow(rows, "status", stringValue(readback.status));
  pushSummaryRow(rows, "safe_next_action", stringValue(readback.safe_next_action));
  for (const key of [
    "provider_mappings",
    "channel_mappings",
    "model_mappings",
    "user_mappings",
    "key_mappings",
    "wallet_mappings",
    "subscription_mappings",
    "non_migratable_items",
  ]) {
    pushSummaryRow(rows, key, numberValue(counts[key]));
  }
  pushSummaryRow(rows, "conflicts", numberValue(conflicts.count));
  pushSummaryRow(rows, "blocking_conflicts", numberValue(conflicts.blocking_count));
  pushSummaryRow(rows, "provider_key_handoff_refs", booleanOrNull(handoff.provider_key_handoff_refs_present));
  pushSummaryRow(rows, "user_key_reissue_refs", booleanOrNull(handoff.user_key_reissue_refs_present));
  pushSummaryRow(rows, "wallet_refs", booleanOrNull(handoff.wallet_opening_balance_refs_present));
  pushSummaryRow(rows, "subscription_refs", booleanOrNull(handoff.subscription_mapping_refs_present));
  pushSummaryRow(rows, "raw_provider_key_returned", booleanOrNull(readback.raw_provider_key_returned));
  pushSummaryRow(rows, "raw_user_key_returned", booleanOrNull(readback.raw_user_key_returned));
  pushSummaryRow(rows, "token_returned", booleanOrNull(readback.token_returned));
  pushSummaryRow(rows, "db_url_returned", booleanOrNull(readback.db_url_returned));
  pushSummaryRow(rows, "raw_sql_returned", booleanOrNull(readback.raw_sql_returned));
  return rows.slice(0, 18);
}

function listItems(value: unknown, labelKey: string, detailKey: string): ArtifactListItem[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value
    .filter(isRecord)
    .map((item) => {
      const label =
        stringValue(item[labelKey]) ??
        stringValue(item.source_id) ??
        stringValue(item.handoff_id) ??
        stringValue(item.id) ??
        "item";
      const detail =
        providerKeyHandoffDetail(item) ??
        stringValue(item[detailKey]) ??
        stringValue(item.reason) ??
        stringValue(item.recommended_path) ??
        stringValue(item.status) ??
        "需要人工复核";
      return {
        detail: safeText(detail),
        label: safeText(label),
        tone: "warn" as const,
      };
    });
}

function providerKeyHandoffDetail(item: Record<string, unknown>): string | null {
  const schema = stringValue(item.schema_version);
  const hasManualEntry = typeof item.required_manual_secret_entry === "boolean" || typeof item.requires_operator_entry === "boolean";
  if (schema !== "importer.provider-key-operator-sidecar.v1" && !hasManualEntry) {
    return null;
  }

  const parts = [
    stringValue(item.provider_alias) ? `provider alias: ${stringValue(item.provider_alias)}` : null,
    stringValue(item.channel_alias) ? `channel alias: ${stringValue(item.channel_alias)}` : null,
    stringValue(item.fingerprint) ? `fingerprint: ${stringValue(item.fingerprint)}` : null,
    `manual entry required: ${String(booleanOrNull(item.required_manual_secret_entry) ?? booleanOrNull(item.requires_operator_entry) ?? true)}`,
    stringValue(item.required_operator_path) ? `path: ${stringValue(item.required_operator_path)}` : null,
    stringValue(item.rotation_next_step) ? `rotation: ${stringValue(item.rotation_next_step)}` : null,
    stringValue(item.recovery_next_step) ? `recovery: ${stringValue(item.recovery_next_step)}` : null,
  ].filter((part): part is string => Boolean(part));

  return parts.join(" / ");
}

function applyOperationItemsFromArtifact(value: Record<string, unknown>): ArtifactListItem[] {
  const operations = [
    ...operationItems(value.planned_creates, "create"),
    ...operationItems(value.planned_updates, "update"),
    ...operationItems(value.planned_skips, "skip"),
  ];

  if (operations.length > 0) {
    return operations;
  }

  return [
    ...itemsFromCount(value.counts, "planned_creates"),
    ...itemsFromCount(value.counts, "planned_updates"),
    ...itemsFromCount(value.counts, "planned_skips"),
  ];
}

function diffItemsFromArtifact(value: Record<string, unknown>): ArtifactListItem[] {
  const direct = listItems(value.diff_items, "target", "summary");
  if (direct.length > 0) {
    return direct;
  }

  if (isApplyLiveRuntimeArtifact(value)) {
    const targets = [
      ...(Array.isArray(value.target_after_apply) ? value.target_after_apply : []),
      ...(Array.isArray(value.target_after_rollback) ? value.target_after_rollback : []),
    ];
    return targets.filter(isRecord).slice(0, 12).map((target) => {
      const kind = stringValue(target.kind) ?? "target";
      const operation = stringValue(target.operation_id) ?? "readback";
      const exists = booleanOrNull(target.exists);
      return {
        detail: `${safeText(operation)} / exists=${exists === null ? "unknown" : String(exists)}`,
        label: safeText(kind),
        tone: exists === false ? "warn" : "neutral",
      };
    });
  }

  const targetCounts = isRecord(value.target_counts) ? value.target_counts : null;
  if (targetCounts) {
    return Object.entries(targetCounts)
      .filter((entry): entry is [string, Record<string, unknown>] => isRecord(entry[1]))
      .map(([kind, counts]) => {
        const creates = numberValue(counts.creates) ?? 0;
        const updates = numberValue(counts.updates) ?? 0;
        const skips = numberValue(counts.skips) ?? 0;
        return {
          detail: `create ${creates} / update ${updates} / skip ${skips}`,
          label: safeText(kind),
          tone: skips > 0 ? "warn" : "neutral",
        };
      });
  }

  return [
    ...operationItems(value.planned_creates, "create"),
    ...operationItems(value.planned_updates, "update"),
    ...operationItems(value.planned_skips, "skip"),
  ].slice(0, 12);
}

function operationItems(value: unknown, fallbackAction: string): ArtifactListItem[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value.filter(isRecord).map((operation) => {
    const target = isRecord(operation.target) ? operation.target : {};
    const kind = stringValue(target.kind) ?? stringValue(operation.kind) ?? "operation";
    const action = stringValue(operation.action) ?? fallbackAction;
    const reason = stringValue(operation.reason) ?? stringValue(operation.operation_id) ?? "planned";
    return {
      detail: `${safeText(action)} / ${safeText(reason)}`,
      label: safeText(kind),
      tone: action === "skip" ? "warn" : "neutral",
    };
  });
}

function applyCapabilityFromArtifact(value: Record<string, unknown>): ApplyCapability {
  const contract = isRecord(value.apply_contract) ? value.apply_contract : {};
  const sqlPlan = isRecord(value.sql_executor_plan) ? value.sql_executor_plan : {};
  const transaction = isRecord(value.transaction_contract) ? value.transaction_contract : {};

  return {
    applySupported: booleanOrNull(value.apply_supported) ?? (isApplyLiveRuntimeArtifact(value) ? true : null),
    databaseWrites:
      booleanOrNull(contract.database_writes) ??
      booleanOrNull(value.database_writes) ??
      booleanOrNull(transaction.database_writes) ??
      booleanOrNull(sqlPlan.database_writes),
    executor: stringValue(contract.executor) ?? stringValue(sqlPlan.executor) ?? stringValue(transaction.executor) ?? null,
    localDemoDb: booleanOrNull(contract.local_demo_db) ?? booleanOrNull(value.local_demo_db),
    liveDatabaseConnection:
      booleanOrNull(contract.live_database_connection) ??
      booleanOrNull(value.live_database_connection) ??
      booleanOrNull(transaction.live_database_connection) ??
      booleanOrNull(sqlPlan.live_database_connection),
    realApplyStatus:
      stringValue(contract.real_apply_status) ??
      stringValue(contract.executor_status) ??
      stringValue(sqlPlan.executor_status) ??
      (isApplyLiveRuntimeArtifact(value) ? `apply-live ${stringValue(value.status) ?? "unknown"}` : null),
    refusalReason:
      stringValue(contract.refusal_reason) ??
      stringValue(contract.real_database_write_refusal_reason) ??
      stringValue(transaction.real_database_write_refusal_reason) ??
      null,
    sqlPlanExecutorSupported: booleanOrNull(value.sql_plan_executor_supported),
  };
}

function applyReviewFromArtifact(input: {
  applyBlocked: boolean | null;
  applyCapability: ApplyCapability;
  dryRun: boolean | null;
  reviewChecklist: ReviewChecklistItem[];
  secretSafe: boolean;
}): ApplyReviewSummary {
  const checklistPassed = input.reviewChecklist.every((item) => item.passed);
  const canConfirmPlan = input.dryRun === true && input.secretSafe && checklistPassed && input.applyBlocked !== true;
  const liveUnavailable =
    input.applyCapability.localDemoDb !== true &&
    input.applyCapability.applySupported === false ||
    (input.applyCapability.localDemoDb !== true && input.applyCapability.liveDatabaseConnection === false) ||
    (input.applyCapability.localDemoDb !== true && input.applyCapability.databaseWrites === false);

  if (!canConfirmPlan) {
    return {
      canConfirmPlan,
      configNeeded: liveUnavailable,
      status: "blocked",
      statusLabel: "blocked",
    };
  }

  if (liveUnavailable) {
    return {
      canConfirmPlan,
      configNeeded: true,
      status: "config-needed",
      statusLabel: "config-needed",
    };
  }

  return {
    canConfirmPlan,
    configNeeded: false,
    status: "ready-for-review",
    statusLabel: "ready",
  };
}

function applyCapabilityText(value: ApplyCapability): string {
  if (value.applySupported === true && value.localDemoDb === true) {
    return value.databaseWrites === true
      ? "本地 JSON demo DB apply-live 已完成写入；请核对 rollback journal、idempotency summary 和 secret-safe artifact。"
      : "本地 JSON demo DB apply-live runner 可用；等待 operator 执行 reviewed apply-plan。";
  }
  if (value.applySupported === false || value.liveDatabaseConnection === false || value.databaseWrites === false) {
    return "apply-live 尚未接入或未配置 live PostgreSQL runner；当前只允许 reviewed dry-run。";
  }
  if (value.applySupported === true && value.liveDatabaseConnection === true) {
    return value.databaseWrites === true
      ? "本地 demo apply-live 已连接 PostgreSQL 并完成写入；请核对 rollback journal 和 secret-safe artifact。"
      : "本地 demo apply-live runner 可用；等待 operator 执行 reviewed apply-plan。";
  }
  if (value.realApplyStatus) {
    return safeText(value.realApplyStatus);
  }
  return "未提供 apply-live 能力字段；按 pending/config-needed 处理。";
}

function sourceBindingItemsFromArtifact(value: Record<string, unknown>): ArtifactListItem[] {
  const contract = isRecord(value.source_binding_contract) ? value.source_binding_contract : {};
  const bindings = isRecord(contract) ? contract.bindings : null;
  if (!Array.isArray(bindings)) {
    return [];
  }

  return bindings.filter(isRecord).map((binding) => {
    const channel = stringValue(binding.channel_source_id) ?? "channel";
    const provider = stringValue(binding.provider_code) ?? stringValue(binding.internal_provider_id) ?? "provider";
    const status = binding.channel_present === false ? "source channel missing" : "bound";
    return {
      detail: `${safeText(provider)} / ${status}`,
      label: safeText(channel),
      tone: binding.channel_present === false ? "warn" : "neutral",
    };
  });
}

function preflightStatusFromArtifact(value: Record<string, unknown>): string | null {
  const preflight = isRecord(value.preflight) ? value.preflight : null;
  if (preflight) {
    return stringValue(preflight.status) ?? null;
  }
  const plan = isRecord(value.plan) ? value.plan : null;
  return plan ? stringValue(plan.preflight_status) ?? null : null;
}

function providerKeyWriteCount(value: Record<string, unknown>): number {
  const operations = [
    ...(Array.isArray(value.planned_creates) ? value.planned_creates : []),
    ...(Array.isArray(value.planned_updates) ? value.planned_updates : []),
  ];

  return operations.filter((operation) => {
    if (!isRecord(operation)) {
      return false;
    }
    const target = isRecord(operation.target) ? operation.target : {};
    const kind = stringValue(target.kind) ?? "";
    return /provider_key|secret/i.test(kind);
  }).length;
}

function transactionSummaryFromArtifact(value: Record<string, unknown>): Array<[string, number | string]> {
  const rows: Array<[string, number | string]> = [];
  const transaction = isRecord(value.transaction_contract) ? value.transaction_contract : {};
  const plan = isRecord(value.plan) ? value.plan : {};
  const rollback = isRecord(value.rollback_snapshot) ? value.rollback_snapshot : {};
  const idempotency = isRecord(value.idempotency_manifest) ? value.idempotency_manifest : {};
  const sqlPlan = isRecord(value.sql_executor_plan) ? value.sql_executor_plan : {};

  const transactionId = stringValue(transaction.transaction_id) ?? stringValue(plan.transaction_id);
  const executorStatus = stringValue(sqlPlan.executor_status) ?? stringValue(plan.executor_status) ?? stringValue(transaction.execution_status);
  const rollbackEntries = Array.isArray(rollback.entries) ? rollback.entries.length : null;
  const idempotencyEntries = Array.isArray(idempotency.entries) ? idempotency.entries.length : null;

  if (transactionId) {
    rows.push(["transaction_id", transactionId]);
  }
  if (executorStatus) {
    rows.push(["executor_status", executorStatus]);
  }
  if (rollbackEntries !== null) {
    rows.push(["rollback_entries", rollbackEntries]);
  }
  if (idempotencyEntries !== null) {
    rows.push(["idempotency_entries", idempotencyEntries]);
  }
  pushSummaryRow(rows, "reviewed_plan_confirmed", booleanOrNull(value.reviewed_plan_confirmed));
  pushSummaryRow(rows, "rollback_after_apply", booleanOrNull(value.rollback_after_apply));

  return rows;
}

function rollbackSummaryFromArtifact(value: Record<string, unknown>): Array<[string, number | string]> {
  const rollback = isRecord(value.rollback_snapshot) ? value.rollback_snapshot : {};
  const rollbackJournal = isRecord(value.rollback_journal_summary) ? value.rollback_journal_summary : {};
  const rollbackReadback = isRecord(value.rollback_readback) ? value.rollback_readback : {};
  const sqlPlan = isRecord(value.sql_executor_plan) ? value.sql_executor_plan : {};
  const rollbackContract = isRecord(sqlPlan.rollback_contract) ? sqlPlan.rollback_contract : {};
  const entries = Array.isArray(rollback.entries) ? rollback.entries.length : null;
  const rows: Array<[string, number | string]> = [];

  pushSummaryRow(rows, "schema", stringValue(rollback.schema_version) ?? stringValue(rollbackJournal.schema_version) ?? stringValue(rollbackContract.schema_version));
  pushSummaryRow(rows, "snapshot_mode", stringValue(rollback.snapshot_mode) ?? stringValue(rollbackJournal.storage));
  pushSummaryRow(rows, "captured_before_apply", booleanOrNull(rollback.captured_before_apply) ?? booleanOrNull(rollbackJournal.captured_before_apply));
  pushSummaryRow(rows, "entries", entries ?? numberValue(rollbackJournal.entries));
  pushSummaryRow(rows, "rolled_back_entries", numberValue(rollbackJournal.rolled_back_entries));
  pushSummaryRow(rows, "capture_before_apply", booleanOrNull(rollbackContract.capture_before_apply));
  pushSummaryRow(rows, "no_secret_material", booleanOrNull(rollbackContract.no_secret_material) ?? booleanOrNull(rollbackJournal.no_secret_material));
  pushSummaryRow(rows, "rollback_run_status", isRecord(rollbackReadback.run) ? stringValue(rollbackReadback.run.status) : null);
  pushSummaryRow(rows, "rollback_readback_operations", Array.isArray(rollbackReadback.operations) ? rollbackReadback.operations.length : null);
  return rows;
}

function journalSummaryFromArtifact(value: Record<string, unknown>): Array<[string, number | string]> {
  const sqlPlan = isRecord(value.sql_executor_plan) ? value.sql_executor_plan : {};
  const journal = isRecord(sqlPlan.journal_contract) ? sqlPlan.journal_contract : {};
  const rollbackJournal = isRecord(value.rollback_journal_summary) ? value.rollback_journal_summary : {};
  const sql = isRecord(journal.sql_plan) ? journal.sql_plan : {};
  const applyReadback = isRecord(value.apply_readback) ? value.apply_readback : {};
  const rows: Array<[string, number | string]> = [];

  pushSummaryRow(rows, "schema", stringValue(journal.schema_version) ?? stringValue(rollbackJournal.schema_version));
  pushSummaryRow(rows, "required_for_live_runner", booleanOrNull(journal.required_for_live_runner));
  pushSummaryRow(rows, "storage", stringValue(rollbackJournal.storage));
  pushSummaryRow(rows, "tables", Array.isArray(journal.proposed_tables) ? journal.proposed_tables.length : null);
  pushSummaryRow(rows, "minimum_fields", Array.isArray(journal.minimum_fields) ? journal.minimum_fields.length : null);
  pushSummaryRow(rows, "sql_plan_schema", stringValue(sql.schema_version));
  pushSummaryRow(rows, "operation_journal_statements", Array.isArray(sql.operation_insert_statements) ? sql.operation_insert_statements.length : null);
  pushSummaryRow(rows, "journal_entries", numberValue(rollbackJournal.entries));
  pushSummaryRow(rows, "apply_run_status", isRecord(applyReadback.run) ? stringValue(applyReadback.run.status) : null);
  pushSummaryRow(rows, "apply_readback_operations", Array.isArray(applyReadback.operations) ? applyReadback.operations.length : null);
  return rows;
}

function idempotencySummaryFromArtifact(value: Record<string, unknown>): Array<[string, number | string]> {
  const manifest = isRecord(value.idempotency_manifest) ? value.idempotency_manifest : {};
  const summary = isRecord(value.idempotency_summary) ? value.idempotency_summary : {};
  const sqlPlan = isRecord(value.sql_executor_plan) ? value.sql_executor_plan : {};
  const plan = isRecord(value.plan) ? value.plan : {};
  const contract = isRecord(sqlPlan.idempotency_contract) ? sqlPlan.idempotency_contract : {};
  const rows: Array<[string, number | string]> = [];

  pushSummaryRow(rows, "schema", stringValue(manifest.schema_version) ?? stringValue(summary.schema_version) ?? stringValue(contract.schema_version));
  pushSummaryRow(rows, "manifest_key", stringValue(manifest.manifest_key) ?? stringValue(summary.manifest_key_fingerprint) ?? stringValue(contract.replay_key));
  pushSummaryRow(rows, "plan_idempotency_key", stringValue(plan.plan_idempotency_key) ?? stringValue(plan.plan_idempotency_key_fingerprint) ?? stringValue(summary.plan_key_fingerprint));
  pushSummaryRow(rows, "rollback_snapshot_idempotency_key", stringValue(plan.rollback_snapshot_idempotency_key) ?? stringValue(plan.rollback_snapshot_idempotency_key_fingerprint));
  pushSummaryRow(rows, "entries", Array.isArray(manifest.entries) ? manifest.entries.length : numberValue(summary.operation_count));
  pushSummaryRow(rows, "applied", numberValue(summary.applied));
  pushSummaryRow(rows, "duplicate_same_after_hash", numberValue(summary.duplicate_same_after_hash));
  pushSummaryRow(rows, "operation_keys", Array.isArray(contract.operation_keys) ? contract.operation_keys.length : null);
  pushSummaryRow(rows, "raw_key_echoed", booleanOrNull(summary.raw_idempotency_keys_omitted) === true ? false : false);
  return rows;
}

function pushSummaryRow(rows: Array<[string, number | string]>, key: string, value: boolean | number | string | null | undefined) {
  if (value === null || typeof value === "undefined") {
    return;
  }

  rows.push([key, typeof value === "boolean" ? String(value) : value]);
}

function migratableItemsFromArtifact(value: Record<string, unknown>): ArtifactListItem[] {
  const direct = listItems(value.migratable_items, "type", "recommended_path");
  if (direct.length > 0) {
    return direct.map((item) => ({ ...item, tone: "neutral" }));
  }

  const candidates = [
    ...itemsFromCount(value.counts, "providers"),
    ...itemsFromCount(value.counts, "channels"),
    ...itemsFromCount(value.counts, "models"),
    ...itemsFromCount(value.counts, "api_keys"),
  ];

  return candidates;
}

function itemsFromCount(value: unknown, key: string): ArtifactListItem[] {
  if (!isRecord(value)) {
    return [];
  }
  const count = value[key];
  if (typeof count !== "number" || count <= 0) {
    return [];
  }

  return [
    {
      detail: `${count.toLocaleString()} 项将进入人工 review 后的映射/apply plan。`,
      label: formatLabel(key),
      tone: "neutral",
    },
  ];
}

function artifactPanels(artifact: ParsedArtifact, filter: "all" | "migratable" | "blocked" | "handoff" | "review" | "apply") {
  const panels = [
    {
      emptyText: "没有可迁移项。",
      filter: "migratable",
      items: artifact.migratableItems,
      title: "可迁移项",
    },
    {
      emptyText: "没有不可迁移项。",
      filter: "blocked",
      items: artifact.nonMigratableItems,
      title: "不可迁移项",
    },
    {
      emptyText: "没有 provider-key handoff。",
      filter: "handoff",
      items: artifact.handoffs,
      title: "密钥交接",
    },
    {
      emptyText: "没有人工复核项。",
      filter: "review",
      items: artifact.manualReviewItems,
      title: "人工复核",
    },
    {
      emptyText: "没有 apply 计划操作。",
      filter: "apply",
      items: artifact.applyOperationItems,
      title: "apply 计划",
    },
    {
      emptyText: "没有 source channel binding 摘要。",
      filter: "apply",
      items: artifact.sourceBindingItems,
      title: "source binding",
    },
  ] as const;

  return panels.filter((panel) => filter === "all" || panel.filter === filter);
}

function buildReviewChecklist(input: {
  applyOperationCount: number;
  dryRun: boolean | null;
  handoffCount: number;
  manualReviewCount: number;
  nonMigratableCount: number;
  preflightStatus: string | null;
  providerKeyWrites: number;
  secretSafe: boolean;
}): ReviewChecklistItem[] {
  const checklist: ReviewChecklistItem[] = [
    {
      key: "dry_run",
      label: "artifact 标记为 dry-run",
      passed: input.dryRun === true,
    },
    {
      key: "secret_safe",
      label: "未发现 secret-like 字段",
      passed: input.secretSafe,
    },
    {
      key: "blocked_reviewed",
      label: "不可迁移项已进入人工处理清单",
      passed: input.nonMigratableCount === 0 || input.manualReviewCount > 0,
    },
    {
      key: "handoff_isolated",
      label: "provider-key handoff 与 apply plan 隔离",
      passed: input.providerKeyWrites === 0,
    },
  ];

  if (input.preflightStatus !== null || input.applyOperationCount > 0) {
    checklist.push({
      key: "preflight_pass",
      label: "apply-plan preflight 可评审",
      passed: input.preflightStatus === "pass",
    });
  }

  return checklist;
}

function reviewChecklistDetail(key: string, passed: boolean): string {
  if (key === "dry_run") {
    return passed ? "可以继续从 dry-run artifact 进入 review。" : "请先运行 source dry-run，不要直接处理 live/export 原始数据。";
  }
  if (key === "secret_safe") {
    return passed ? "未在 artifact 中检测到明显密钥模式。" : "artifact 里疑似包含密钥或 header，必须重新生成脱敏输出。";
  }
  if (key === "blocked_reviewed") {
    return passed ? "不可迁移项已有人工处理路径。" : "不可迁移项不能静默丢弃，需要补 manual_review_items。";
  }
  if (key === "preflight_pass") {
    return passed ? "preflight 已通过，可以继续人工核对 SQL plan 和 rollback 摘要。" : "preflight 未通过时不得进入 live apply。";
  }
  return "密钥只允许通过 operator handoff 路径录入，不进入 apply payload。";
}

function statusForArtifact(value: Record<string, unknown>, nonMigratableCount: number, handoffCount: number): string {
  const status = stringValue(value.status) ?? stringValue(value.overall_status);
  if (status) {
    return isApplyLiveRuntimeArtifact(value) ? `apply-live ${safeText(status)}` : safeText(status);
  }

  if (handoffCount > 0) {
    return "需要 operator handoff";
  }

  if (nonMigratableCount > 0) {
    return "需要人工复核";
  }

  return "可继续评审";
}

function isApplyLiveRuntimeArtifact(value: Record<string, unknown>): boolean {
  return (
    stringValue(value.importer) === "importer-apply-live-runtime" ||
    stringValue(value.importer) === "importer-apply-live-demo-runtime" ||
    stringValue(value.schema) === "importer_apply_live_runtime.v1" ||
    stringValue(value.schema) === "importer_apply_live_demo_runtime.v1" ||
    stringValue(value.schema_version) === "importer.apply-live-runtime.v1" ||
    stringValue(value.schema_version) === "importer.apply-live-demo-runtime.v1"
  );
}

function containsSecretLikeArtifactText(value: string): boolean {
  const normalized = value.toLowerCase();
  return (
    /\bsk-[a-z0-9_-]{8,}/i.test(value) ||
    /\bBearer\s+[A-Za-z0-9._~+/=-]{8,}/i.test(value) ||
    /authorization\s*[:=]\s*"?Bearer\s+[A-Za-z0-9._~+/=-]{8,}/i.test(value) ||
    /cookie\s*[:=]\s*"?[A-Za-z0-9._~+/=-]{16,}/i.test(value) ||
    normalized.includes("-----begin private key-----") ||
    /"raw_provider_key"\s*:\s*"(?!<redacted>|false|null)/i.test(value) ||
    /"raw_virtual_key"\s*:\s*"(?!<redacted>|false|null)/i.test(value)
  );
}

function stringArray(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === "string") : [];
}

function booleanOrNull(value: unknown): boolean | null {
  return typeof value === "boolean" ? value : null;
}

function numberValue(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function numberStringValue(value: unknown): string | undefined {
  const parsed = numberValue(value);
  return parsed === null ? undefined : String(parsed);
}

function safeText(value: string): string {
  return value
    .replace(/\bsk-[A-Za-z0-9_-]{4,}\b/g, "[redacted-key]")
    .replace(/\bBearer\s+[A-Za-z0-9._-]+\b/gi, "Bearer [redacted]")
    .replace(/\bAuthorization\s*:\s*[^,\n}]+/gi, "Authorization: [redacted]");
}

function formatLabel(value: string): string {
  return value.replace(/_/g, " ");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}
