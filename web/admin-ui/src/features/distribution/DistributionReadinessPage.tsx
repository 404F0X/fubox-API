import { useEffect, useMemo, useState } from "react";
import {
  createApiKeyProfile,
  createCanonicalModel,
  createChannel,
  createModelAssociation,
  createProvider,
  createProviderKey,
  dryRunModelAssociation,
  getAdminDistributionReadiness,
  getProviderHealthSummary,
  listApiKeyProfiles,
  listCanonicalModels,
  listChannels,
  listModelAssociations,
  listProviderKeys,
  listProviders,
  listRequestLogs,
  listVirtualKeys,
  patchApiKeyProfile,
  type AdminDistributionReadiness,
  type ApiKeyProfile,
  type CanonicalModel,
  type Channel,
  type HealthSummary,
  type ModelAssociation,
  type ModelAssociationDryRunResponse,
  type Provider,
  type ProviderKey,
  type RequestLogSummary,
  type VirtualKey,
} from "../../api/client";
import { ActionButton } from "../../design/ActionButton";
import { DataTable } from "../../design/DataTable";
import { MetricTile } from "../../design/MetricTile";
import { SectionHeader } from "../../design/SectionHeader";
import { ProbeStatusChip } from "../../design/StatusChip";
import { errorMessage, safeFieldValue, shortId } from "../../components/adminUtils";
import { ArrowRight, Copy, Eye, RefreshCw } from "../../components/icons";

const DEFAULT_PROJECT_ID = "00000000-0000-0000-0000-000000000020";
const LOCAL_BOOTSTRAP_COMMAND =
  "pwsh -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\bootstrap_new_api_mock_distribution.ps1 -Apply";
const REAL_PROVIDER_SMOKE_COMMAND =
  "pwsh -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\verify_real_provider_onboarding_smoke.ps1 -Live";
const USER_HANDOFF_CHECKLIST = [
  "AI Gateway 用户交接清单",
  "1. 打开 User Portal，创建或登录用户账号。",
  "2. 兑换运营方提供的券码额度。",
  "3. 创建项目级 API key，并在本地保存一次性 secret。",
  "4. 使用 Gateway Base URL 和 OpenAI-compatible SDK。",
  "5. 检查 /v1/models，再发送 /v1/chat/completions 请求。",
  "6. 在 User Portal 查看 Usage、Request detail 和 Trace summary。",
  "密钥边界：不要交接 raw provider key、raw voucher code、admin session、Authorization header 或已保存的 API key secret。",
].join("\n");

type RealProviderPlanForm = {
  baseUrl: string;
  channelName: string;
  providerKeyAlias: string;
  providerKeySecret: string;
  profileName: string;
  providerCode: string;
  providerName: string;
  publicModel: string;
  upstreamModel: string;
};

type DistributionTarget = "providers" | "providerKeys" | "models" | "routing" | "keys" | "requestLogs" | "billing";

type ReadinessStatus = "online" | "offline" | "pending";

type ReadinessRow = {
  detail: string;
  evidence: string;
  label: string;
  next: string;
  status: ReadinessStatus;
};

type CompactReadinessBlock = {
  detail: string;
  label: string;
  next: string;
  status: ReadinessStatus;
  target: DistributionTarget | null;
};

type PublicDistributionReadbackBlock = {
  detail: string;
  label: string;
  next: string;
  status: ReadinessStatus;
};

type OnboardingApplyStep = {
  action: "created" | "reused" | "skipped";
  detail: string;
  label: string;
};

type SetupStep = {
  detail: string;
  evidence: string;
  label: string;
  status: ReadinessStatus;
  target: DistributionTarget | null;
  targetLabel: string;
};

type RouteTopologyRow = {
  channelName: string;
  credential: string;
  lastRequest: string;
  modelName: string;
  profile: string;
  providerName: string;
  route: string;
  status: ReadinessStatus;
  upstreamModel: string;
};

type DistributionState = {
  authority: AdminDistributionReadiness | null;
  channels: Channel[];
  healthSummary: HealthSummary | null;
  keys: VirtualKey[];
  logs: RequestLogSummary[];
  modelAssociations: ModelAssociation[];
  models: Array<CanonicalModel & { route?: HealthSummary["models"][number] }>;
  profiles: ApiKeyProfile[];
  providerKeys: ProviderKey[];
  providers: Provider[];
};

type DistributionReadinessPageProps = {
  onNavigate?: (target: DistributionTarget) => void;
  onOpenRequestDetail?: (requestId: string) => void;
  onOpenUserPortal?: () => void;
};

export function DistributionReadinessPage({
  onNavigate,
  onOpenRequestDetail,
  onOpenUserPortal,
}: DistributionReadinessPageProps) {
  const [copiedBootstrap, setCopiedBootstrap] = useState(false);
  const [copiedOnboardingPlan, setCopiedOnboardingPlan] = useState(false);
  const [copiedRealProvider, setCopiedRealProvider] = useState(false);
  const [copiedUserChecklist, setCopiedUserChecklist] = useState(false);
  const [data, setData] = useState<DistributionState | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [onboardingApplyError, setOnboardingApplyError] = useState<string | null>(null);
  const [onboardingApplyLoading, setOnboardingApplyLoading] = useState(false);
  const [onboardingApplySteps, setOnboardingApplySteps] = useState<OnboardingApplyStep[]>([]);
  const [onboardingDryRun, setOnboardingDryRun] = useState<ModelAssociationDryRunResponse | null>(null);
  const [showOnboardingWizard, setShowOnboardingWizard] = useState(false);
  const [lastLoaded, setLastLoaded] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [realProviderPlan, setRealProviderPlan] = useState<RealProviderPlanForm>({
    baseUrl: "https://api.openai.com/v1",
    channelName: "primary-openai",
    providerKeyAlias: "primary-openai-key",
    providerKeySecret: "",
    profileName: "default-user-profile",
    providerCode: "openai",
    providerName: "OpenAI",
    publicModel: "gpt-4o-mini",
    upstreamModel: "gpt-4o-mini",
  });

  async function loadReadiness() {
    setError(null);
    setLoading(true);

    try {
      const [
        healthSummaryResult,
        authorityResult,
        providersResult,
        channelsResult,
        providerKeysResult,
        canonicalModelsResult,
        modelAssociationsResult,
        profilesResult,
        keysResult,
        logsResult,
      ] = await Promise.allSettled([
        getProviderHealthSummary(),
        getAdminDistributionReadiness(),
        listProviders(),
        listChannels(),
        listProviderKeys(),
        listCanonicalModels(),
        listModelAssociations(),
        listApiKeyProfiles({ project_id: DEFAULT_PROJECT_ID }),
        listVirtualKeys({ project_id: DEFAULT_PROJECT_ID }),
        listRequestLogs({ limit: 20 }),
      ]);
      const authority =
        authorityResult.status === "fulfilled" && Array.isArray(authorityResult.value.checks)
          ? authorityResult.value
          : null;
      const healthSummary =
        healthSummaryResult.status === "fulfilled" ? healthSummaryResult.value : authority?.health_summary ?? null;
      const canonicalModels = settledValue(canonicalModelsResult, []);
      const partialErrors = [
        providersResult,
        channelsResult,
        providerKeysResult,
        canonicalModelsResult,
        modelAssociationsResult,
        profilesResult,
        keysResult,
        logsResult,
      ].filter((result) => result.status === "rejected").length;

      setData({
        authority,
        channels: settledValue(channelsResult, []),
        healthSummary,
        keys: settledValue(keysResult, []),
        logs: settledValue(logsResult, []),
        modelAssociations: settledValue(modelAssociationsResult, []),
        models: activeModelsFromHealth(healthSummary, canonicalModels),
        profiles: settledValue(profilesResult, []),
        providerKeys: settledValue(providerKeysResult, []),
        providers: settledValue(providersResult, []),
      });
      setError(
        partialErrors > 0
          ? `当前 admin session 有 ${partialErrors} 个数据源不可用。`
          : authorityResult.status === "rejected"
            ? "权威 readiness API 不可用，已使用本页本地聚合。"
            : null,
      );
      setLastLoaded(
        new Date().toLocaleTimeString([], {
          hour: "2-digit",
          minute: "2-digit",
        }),
      );
    } catch (requestError) {
      setData(null);
      setError(errorMessage(requestError));
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    void loadReadiness();
  }, []);

  const rows = useMemo(() => readinessRows(data), [data]);
  const failedRequests = useMemo(() => recentFailedRequests(data), [data]);
  const routeRows = useMemo(() => routeTopologyRows(data), [data]);
  const setupSteps = useMemo(() => setupSequence(data), [data]);
  const readyCount = rows.filter((row) => row.status === "online").length;
  const blockedCount = rows.filter((row) => row.status === "offline").length;
  const attentionCount = rows.filter((row) => row.status === "pending").length;
  const readyToDistribute = data?.authority?.ready_to_distribute_api ?? (rows.length > 0 && blockedCount === 0 && attentionCount <= 1);
  const compactBlocks = useMemo(() => compactReadinessBlocks(data, readyToDistribute), [data, readyToDistribute]);
  const publicReadbackBlocks = useMemo(() => publicDistributionReadbackBlocks(data), [data]);
  const realProviderOnboardingPlan = useMemo(() => buildRealProviderOnboardingPlan(realProviderPlan), [realProviderPlan]);

  function updateRealProviderPlan(field: keyof RealProviderPlanForm, value: string) {
    setRealProviderPlan((current) => ({
      ...current,
      [field]: value,
    }));
  }

  async function copyBootstrapCommand() {
    try {
      await writeClipboard(LOCAL_BOOTSTRAP_COMMAND);
      setCopiedBootstrap(true);
      window.setTimeout(() => setCopiedBootstrap(false), 1400);
    } catch {
      setCopiedBootstrap(false);
    }
  }

  async function copyRealProviderSmokeCommand() {
    try {
      await writeClipboard(REAL_PROVIDER_SMOKE_COMMAND);
      setCopiedRealProvider(true);
      window.setTimeout(() => setCopiedRealProvider(false), 1400);
    } catch {
      setCopiedRealProvider(false);
    }
  }

  async function copyRealProviderOnboardingPlan() {
    try {
      await writeClipboard(realProviderOnboardingPlan);
      setCopiedOnboardingPlan(true);
      window.setTimeout(() => setCopiedOnboardingPlan(false), 1400);
    } catch {
      setCopiedOnboardingPlan(false);
    }
  }

  async function applyRealProviderOnboardingPlan() {
    if (!data || onboardingApplyLoading) {
      return;
    }

    setOnboardingApplyError(null);
    setOnboardingApplyLoading(true);
    setOnboardingDryRun(null);

    const steps: OnboardingApplyStep[] = [];
    const providerCode = slugPlanValue(realProviderPlan.providerCode, "provider");
    const providerName = safePlanValue(realProviderPlan.providerName, providerCode);
    const baseUrl = safePlanValue(realProviderPlan.baseUrl, "https://api.example.test/v1");
    const channelName = safePlanValue(realProviderPlan.channelName, `${providerCode}-primary`);
    const providerKeyAlias = safePlanValue(realProviderPlan.providerKeyAlias, `${channelName}-key`);
    const providerKeySecret = realProviderPlan.providerKeySecret;
    const publicModel = safePlanValue(realProviderPlan.publicModel, "gpt-4o-mini");
    const upstreamModel = safePlanValue(realProviderPlan.upstreamModel, publicModel);
    const profileName = safePlanValue(realProviderPlan.profileName, `${providerCode}-user-profile`);

    try {
      let provider = data.providers.find((item) => item.code === providerCode);

      if (provider) {
        steps.push({ action: "reused", detail: `${provider.code} / ${shortId(provider.id)}`, label: "供应商" });
      } else {
        provider = await createProvider({
          base_url: baseUrl,
          code: providerCode,
          metadata: {
            source: "distribution_plan_builder",
            material: "omitted",
          },
          name: providerName,
          provider_type: "openai-compatible",
          status: "enabled",
        });
        steps.push({ action: "created", detail: `${provider.code} / ${shortId(provider.id)}`, label: "供应商" });
      }

      let channel = data.channels.find((item) => item.provider_id === provider!.id && item.name === channelName);

      if (channel) {
        steps.push({ action: "reused", detail: `${channel.name} / ${shortId(channel.id)}`, label: "通道" });
      } else {
        channel = await createChannel({
          endpoint: baseUrl,
          model_mappings: {
            [publicModel]: upstreamModel,
          },
          name: channelName,
          probe_policy: {
            mode: "manual",
            material: "omitted",
          },
          protocol_mode: "openai",
          provider_id: provider.id,
          request_overrides: {},
          status: "enabled",
          tags: ["real-provider-onboarding"],
          timeout_policy: {
            connect_ms: 5000,
            request_ms: 60000,
          },
        });
        steps.push({ action: "created", detail: `${channel.name} / ${shortId(channel.id)}`, label: "通道" });
      }

      let model = data.models.find((item) => item.model_key === publicModel);

      if (model) {
        steps.push({ action: "reused", detail: `${model.model_key} / ${shortId(model.id)}`, label: "模型" });
      } else {
        model = await createCanonicalModel({
          capabilities: {
            onboarding_source: "distribution_plan_builder",
          },
          display_name: publicModel,
          model_key: publicModel,
          status: "active",
          visibility: "public",
        });
        steps.push({ action: "created", detail: `${model.model_key} / ${shortId(model.id)}`, label: "模型" });
      }

      const association = data.modelAssociations.find(
        (item) =>
          item.canonical_model_id === model!.id &&
          item.channel_id === channel!.id &&
          item.upstream_model_name === upstreamModel &&
          item.status !== "deleted",
      );

      if (association) {
        steps.push({ action: "reused", detail: shortId(association.id), label: "模型路由" });
      } else {
        const createdAssociation = await createModelAssociation({
          association_type: "explicit_channel",
          canonical_model_id: model.id,
          channel_id: channel.id,
          conditions: {
            onboarding_source: "distribution_plan_builder",
          },
          fallback_allowed: true,
          priority: 100,
          status: "enabled",
          upstream_model_name: upstreamModel,
        });
        steps.push({ action: "created", detail: shortId(createdAssociation.id), label: "模型路由" });
      }

      let profile = data.profiles.find((item) => item.project_id === DEFAULT_PROJECT_ID && item.name === profileName);

      if (profile) {
        profile = await patchApiKeyProfile(profile.id, {
          allowed_models: [publicModel],
          status: "active",
        });
        steps.push({ action: "reused", detail: `${profile.name} / ${shortId(profile.id)}`, label: "用户配置" });
      } else {
        profile = await createApiKeyProfile({
          allowed_models: [publicModel],
          denied_models: [],
          model_aliases: {},
          name: profileName,
          project_id: DEFAULT_PROJECT_ID,
          status: "active",
        });
        steps.push({
          action: "created",
          detail: `${profile.name} / ${shortId(profile.id)}`,
          label: "用户配置",
        });
      }

      if (providerKeySecret.trim()) {
        const existingProviderKey = data.providerKeys.find(
          (item) => item.channel_id === channel!.id && item.key_alias === providerKeyAlias && item.status !== "deleted",
        );

        if (existingProviderKey) {
          steps.push({
            action: "reused",
            detail: `${existingProviderKey.key_alias} / ${shortId(existingProviderKey.id)}`,
            label: "供应商密钥",
          });
        } else {
          const createdProviderKey = await createProviderKey({
            channel_id: channel.id,
            key_alias: providerKeyAlias,
            metadata: {
              source: "distribution_plan_builder",
              material: "omitted_after_submit",
            },
            secret: providerKeySecret,
            status: "enabled",
          });
          steps.push({
            action: "created",
            detail: `${createdProviderKey.key_alias} / ${shortId(createdProviderKey.id)} / 已清除提交的 secret`,
            label: "供应商密钥",
          });
        }
      } else {
        steps.push({
          action: "skipped",
          detail: "未输入 secret。请在 Provider Keys 单独创建 raw provider key，或带一次性 secret 重新运行。",
          label: "供应商密钥",
        });
      }
      setRealProviderPlan((current) => ({ ...current, providerKeySecret: "" }));
      const dryRun = await dryRunModelAssociation({
        canonical_model_id: model.id,
        canonical_model_key: model.model_key,
        profile_id: profile.id,
        project_id: DEFAULT_PROJECT_ID,
        requested_model: publicModel,
      });
      setOnboardingDryRun(dryRun);
      steps.push({
        action: dryRun.selected_candidate ? "created" : "skipped",
        detail: dryRun.selected_candidate
          ? `${dryRun.selection.status} / ${dryRun.selected_candidate.channel_name} / ${safeFieldValue(dryRun.selected_candidate.provider_name)}`
          : `${dryRun.selection.status} / 未选中候选项`,
        label: "路由 dry-run",
      });
      setOnboardingApplySteps(steps);
      await loadReadiness();
    } catch (requestError) {
      setOnboardingApplyError(errorMessage(requestError));
      setOnboardingApplySteps(steps);
    } finally {
      setRealProviderPlan((current) => ({ ...current, providerKeySecret: "" }));
      setOnboardingApplyLoading(false);
    }
  }

  async function copyUserHandoffChecklist() {
    try {
      await writeClipboard(USER_HANDOFF_CHECKLIST);
      setCopiedUserChecklist(true);
      window.setTimeout(() => setCopiedUserChecklist(false), 1400);
    } catch {
      setCopiedUserChecklist(false);
    }
  }

  return (
    <div className="dashboard-stack" aria-label="API 分发就绪">
      <section className="summary-grid" aria-label="分发就绪摘要">
        <MetricTile
          label="API 分发"
          value={readyToDistribute ? "可发放" : loading ? "加载中" : "需处理"}
          detail={lastLoaded ? `已检查 ${lastLoaded}` : "等待 admin 数据"}
          tone={readyToDistribute ? "good" : "warn"}
        />
        <MetricTile label="可路由" value={String(routableModelCount(data?.healthSummary))} detail="活跃模型路由" tone={routableModelCount(data?.healthSummary) > 0 ? "good" : "warn"} />
        <MetricTile label="失败请求" value={String(failedRequests.length)} detail={`近 ${data?.logs.length ?? 0} 条请求`} tone={failedRequests.length > 0 ? "warn" : "neutral"} />
        <MetricTile label="阻塞项" value={String(blockedCount)} detail={`${readyCount}/${rows.length} 项通过，${attentionCount} 项关注`} tone={blockedCount > 0 ? "warn" : "neutral"} />
      </section>

      <section className="distribution-command-bar" aria-label="分发操作栏">
        <div>
          <span>操作面板</span>
          <strong>{readyToDistribute ? "现在可以发 key 并调用 Gateway" : "先处理阻塞项，再发 key"}</strong>
          <p>{firstBlockingReason(rows) ?? "上游、模型、额度、key 和 trace 均有可用信号。"}</p>
        </div>
        <div className="action-row">
          <ActionButton className="primary-button--inline" icon={<ArrowRight aria-hidden="true" size={15} />} onClick={() => setShowOnboardingWizard(true)} variant="primary">
            接入供应商
          </ActionButton>
          {onNavigate ? (
            <>
              <ActionButton icon={<ArrowRight aria-hidden="true" size={15} />} onClick={() => onNavigate("providers")}>
                通道
              </ActionButton>
              <ActionButton icon={<ArrowRight aria-hidden="true" size={15} />} onClick={() => onNavigate("models")}>
                模型
              </ActionButton>
              <ActionButton icon={<ArrowRight aria-hidden="true" size={15} />} onClick={() => onNavigate("billing")}>
                券码
              </ActionButton>
            </>
          ) : null}
          {onOpenUserPortal ? (
            <ActionButton icon={<ArrowRight aria-hidden="true" size={15} />} onClick={onOpenUserPortal}>
              User Portal
            </ActionButton>
          ) : null}
        </div>
      </section>

      <section className="admin-panel" aria-label="紧凑分发状态">
        <SectionHeader
          title="Compact readiness"
          description={error ?? "管理员第一屏判断：能不能发 key、能不能路由、失败在哪里。"}
          actions={
            <ActionButton
              disabled={loading}
              icon={<RefreshCw aria-hidden="true" size={17} className={loading ? "spin" : undefined} />}
              onClick={() => void loadReadiness()}
            >
              刷新
            </ActionButton>
          }
        />
        <div className="status-grid">
          {compactBlocks.map((block) => (
            <article className="status-card" key={block.label}>
              <div>
                <h3>{block.label}</h3>
                <p>{block.detail}</p>
                <small>{block.next}</small>
              </div>
              <div className="table-action-stack">
                <ProbeStatusChip status={block.status} />
                {block.target && onNavigate ? (
                  <ActionButton icon={<ArrowRight aria-hidden="true" size={15} />} onClick={() => onNavigate(block.target!)} variant="table">
                    处理
                  </ActionButton>
                ) : null}
              </div>
            </article>
          ))}
        </div>
      </section>

      <section className="admin-panel" aria-label="分发就绪控制">
        <SectionHeader title="下一步动作" description="按阻塞和关注项排序，直接进入对应工作区。" />

        <DataTable aria-label="分发下一步动作" className="admin-table">
            <thead>
              <tr>
                <th>检查项</th>
                <th>状态</th>
                <th>证据</th>
                <th>下一步</th>
              </tr>
            </thead>
            <tbody>
              {loading && !data ? (
                <tr>
                  <td colSpan={4}>正在加载分发就绪状态。</td>
                </tr>
              ) : rows.length > 0 ? (
                actionRows(rows).map((row) => (
                  <tr key={row.label}>
                    <td>
                      <strong>{row.label}</strong>
                      <span>{row.detail}</span>
                    </td>
                    <td>
                      <ProbeStatusChip status={row.status} />
                    </td>
                    <td>{row.evidence}</td>
                    <td>{row.next}</td>
                  </tr>
                ))
              ) : (
                <tr>
                  <td colSpan={4}>尚未加载就绪数据。</td>
                </tr>
              )}
            </tbody>
        </DataTable>
      </section>

      <section className="admin-panel" aria-label="公开分发 readback">
        <SectionHeader
          title="Public distribution readback"
          description={data?.authority?.safe_next_action ?? "券码、兑换、用户 key 和 quota/pricing guardrails 的安全摘要。"}
        />
        <div className="status-grid">
          {publicReadbackBlocks.map((block) => (
            <article className="status-card" key={block.label}>
              <div>
                <h3>{block.label}</h3>
                <p>{block.detail}</p>
                <small>{block.next}</small>
              </div>
              <ProbeStatusChip status={block.status} />
            </article>
          ))}
        </div>
      </section>

      <section className="admin-panel" aria-label="最近失败请求">
        <SectionHeader
          title="最近失败请求"
          description={failedRequests.length > 0 ? "从近期 request logs 中提取失败、拒绝或 HTTP 4xx/5xx 请求。" : "近期请求没有失败信号。"}
          actions={onNavigate ? <ActionButton icon={<ArrowRight aria-hidden="true" size={15} />} onClick={() => onNavigate("requestLogs")}>打开 Request/Trace</ActionButton> : null}
        />

        <DataTable aria-label="最近失败请求" className="admin-table">
          <thead>
            <tr>
              <th>请求</th>
              <th>失败原因</th>
              <th>路由</th>
              <th>模型</th>
              <th>动作</th>
            </tr>
          </thead>
          <tbody>
            {loading && !data ? (
              <tr>
                <td colSpan={5}>正在加载失败请求。</td>
              </tr>
            ) : failedRequests.length > 0 ? (
              failedRequests.map((log) => (
                <tr key={log.id}>
                  <td>
                    <strong>{shortId(log.id)}</strong>
                    <span>{formatShortDate(log.created_at)}</span>
                    {log.trace_id ? <span>Trace {shortId(log.trace_id)}</span> : null}
                  </td>
                  <td>
                    <strong>{failureSummary(log)}</strong>
                    <span>{log.http_status ? `HTTP ${log.http_status}` : safeFieldValue(log.status)}</span>
                  </td>
                  <td>
                    <strong>{shortId(log.resolved_channel_id ?? "")}</strong>
                    <span>{safeFieldValue(log.route_policy_version)}</span>
                  </td>
                  <td>
                    <strong>{safeFieldValue(log.requested_model)}</strong>
                    <span>{safeFieldValue(log.upstream_model)}</span>
                  </td>
                  <td>
                    {onOpenRequestDetail ? (
                      <ActionButton
                        aria-label={`打开请求详情 ${log.id}`}
                        icon={<Eye aria-hidden="true" size={15} />}
                        onClick={() => onOpenRequestDetail(log.id)}
                        variant="table"
                      >
                        详情
                      </ActionButton>
                    ) : onNavigate ? (
                      <ActionButton icon={<ArrowRight aria-hidden="true" size={15} />} onClick={() => onNavigate("requestLogs")} variant="table">
                        查看
                      </ActionButton>
                    ) : (
                      "-"
                    )}
                  </td>
                </tr>
              ))
            ) : (
              <tr>
                <td colSpan={5}>没有失败请求；如仍无法调用，请运行一次 Gateway 请求后刷新。</td>
              </tr>
            )}
          </tbody>
        </DataTable>
      </section>

      <section className="admin-panel" aria-label="分发路由">
        <div className="section-heading">
          <div>
            <h2>分发路由</h2>
            <p>
              以通道为核心查看活跃 API 交付链：上游、凭证状态、公开模型、用户配置可见性和最近脱敏请求信号。
            </p>
          </div>
          <ProbeStatusChip status={routeRows.some((row) => row.status === "online") ? "online" : "pending"} />
        </div>

        <div className="health-table-wrap">
          <table className="health-table admin-table route-topology-table">
            <thead>
              <tr>
                <th>路由</th>
                <th>状态</th>
                <th>凭证</th>
                <th>模型</th>
                <th>用户配置</th>
                <th>最近信号</th>
              </tr>
            </thead>
            <tbody>
              {loading && !data ? (
                <tr>
                  <td colSpan={6}>正在加载分发路由。</td>
                </tr>
              ) : routeRows.length > 0 ? (
                routeRows.map((row) => (
                  <tr key={`${row.route}-${row.modelName}-${row.upstreamModel}`}>
                    <td>
                      <strong>{row.route}</strong>
                      <span>
                        {row.providerName} / {row.channelName}
                      </span>
                    </td>
                    <td>
                      <ProbeStatusChip status={row.status} />
                    </td>
                    <td>{row.credential}</td>
                    <td>
                      <strong>{row.modelName}</strong>
                      <span>{row.upstreamModel}</span>
                    </td>
                    <td>{row.profile}</td>
                    <td>{row.lastRequest}</td>
                  </tr>
                ))
              ) : (
                <tr>
                  <td colSpan={6}>未找到启用的通道路由。请添加供应商、通道、凭证和模型关联。</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </section>

      <div className="operator-workflow-grid" aria-label="运营分发流程">
      <section className="admin-panel bootstrap-guide" aria-label="本地 mock 启动指南">
        <div className="section-heading">
          <div>
            <h2>本地 mock 启动</h2>
            <p>
              仅用于本地 Alpha 和预览。该操作修复默认 mock-provider 分发路径，不会创建真实供应商凭证、
              用户 API key、券码、付款或订阅。
            </p>
          </div>
          <ProbeStatusChip status="pending" />
        </div>
        <div className="bootstrap-command-row">
          <code>{LOCAL_BOOTSTRAP_COMMAND}</code>
          <button className="secondary-button" type="button" onClick={() => void copyBootstrapCommand()}>
            <Copy aria-hidden="true" size={16} />
            {copiedBootstrap ? "已复制" : "复制"}
          </button>
        </div>
        <p className="muted-copy">
          脚本会写入 `.tmp/new-api-mvp/mock_distribution_bootstrap.json`，并检查默认 tenant/project/profile、
          payload policy、mock provider/channel/provider key、模型和模型关联。外部凭证可用时再运行真实供应商接入 smoke。
        </p>
      </section>

      <section className="admin-panel bootstrap-guide" aria-label="真实供应商接入指南">
        <div className="section-heading">
          <div>
            <h2>真实供应商接入</h2>
            <p>
              运营方持有真实上游凭证时使用。缺失凭证会记录为外部输入阻塞项，但不会阻塞本地
              mock-provider API 分发路径。
            </p>
          </div>
          <ProbeStatusChip status="pending" />
        </div>
        <div className="env-hint-grid" aria-label="真实供应商接入环境输入">
          <span>REAL_PROVIDER_BASE_URL</span>
          <span>REAL_PROVIDER_API_KEY</span>
          <span>REAL_PROVIDER_MODEL</span>
        </div>
        <div className="bootstrap-command-row">
          <code>{REAL_PROVIDER_SMOKE_COMMAND}</code>
          <button className="secondary-button" type="button" onClick={() => void copyRealProviderSmokeCommand()}>
            <Copy aria-hidden="true" size={16} />
            {copiedRealProvider ? "已复制" : "复制"}
          </button>
        </div>
        <p className="muted-copy">
          smoke 会写入 `.tmp/real-provider/real_provider_onboarding_smoke.json`。凭证缺失时可不带 `-Live`
          运行，以记录 credential-pending artifact。只有设置环境输入后才运行 `-Live` 命令；它会创建
          provider/channel/provider key/model/profile 路由并调用 Gateway。raw provider key 和 virtual key secret
          不得出现在截图或 artifact 中。
        </p>
        <div className="action-row onboarding-quick-actions" aria-label="真实供应商接入快捷操作">
          <button className="primary-button primary-button--inline" type="button" onClick={() => setShowOnboardingWizard(true)}>
            打开接入向导
            <ArrowRight aria-hidden="true" size={15} />
          </button>
          {onNavigate ? (
            <>
              <button className="secondary-button" type="button" onClick={() => onNavigate("providers")}>
                供应商
                <ArrowRight aria-hidden="true" size={15} />
              </button>
              <button className="secondary-button" type="button" onClick={() => onNavigate("models")}>
                模型
                <ArrowRight aria-hidden="true" size={15} />
              </button>
            </>
          ) : null}
        </div>

        {showOnboardingWizard ? (
          <div className="wizard-overlay" role="dialog" aria-modal="true" aria-label="真实供应商接入向导">
            <div className="wizard-panel">
              <div className="wizard-header">
                <div>
                  <span>供应商路由配置</span>
                  <h3>真实供应商接入</h3>
                  <p>
                    创建不含密钥的供应商、通道、模型和用户配置路由。一次性 provider key 会在提交后清除，
                    且不会出现在计划预览中。
                  </p>
                </div>
                <button className="secondary-button" type="button" onClick={() => setShowOnboardingWizard(false)}>
                  关闭
                </button>
              </div>
              <div className="onboarding-plan" aria-label="真实供应商接入计划构建器">
          <div className="form-grid form-grid--three">
            <label className="field">
              供应商名称
              <input
                value={realProviderPlan.providerName}
                onChange={(event) => updateRealProviderPlan("providerName", event.target.value)}
                placeholder="OpenAI"
              />
            </label>
            <label className="field">
              供应商 code
              <input
                value={realProviderPlan.providerCode}
                onChange={(event) => updateRealProviderPlan("providerCode", event.target.value)}
                placeholder="openai"
              />
            </label>
            <label className="field">
              Base URL
              <input
                value={realProviderPlan.baseUrl}
                onChange={(event) => updateRealProviderPlan("baseUrl", event.target.value)}
                placeholder="https://api.openai.com/v1"
              />
            </label>
            <label className="field">
              通道名称
              <input
                value={realProviderPlan.channelName}
                onChange={(event) => updateRealProviderPlan("channelName", event.target.value)}
                placeholder="primary-openai"
              />
            </label>
            <label className="field">
              公开模型
              <input
                value={realProviderPlan.publicModel}
                onChange={(event) => updateRealProviderPlan("publicModel", event.target.value)}
                placeholder="gpt-4o-mini"
              />
            </label>
            <label className="field">
              上游模型
              <input
                value={realProviderPlan.upstreamModel}
                onChange={(event) => updateRealProviderPlan("upstreamModel", event.target.value)}
                placeholder="gpt-4o-mini"
              />
            </label>
            <label className="field">
              供应商密钥别名
              <input
                value={realProviderPlan.providerKeyAlias}
                onChange={(event) => updateRealProviderPlan("providerKeyAlias", event.target.value)}
                placeholder="primary-openai-key"
              />
            </label>
            <label className="field">
              一次性 provider API key
              <input
                autoComplete="new-password"
                value={realProviderPlan.providerKeySecret}
                onChange={(event) => updateRealProviderPlan("providerKeySecret", event.target.value)}
                placeholder="可选；提交后清除"
                type="password"
              />
            </label>
            <label className="field field--wide">
              用户配置
              <input
                value={realProviderPlan.profileName}
                onChange={(event) => updateRealProviderPlan("profileName", event.target.value)}
                placeholder="default-user-profile"
              />
            </label>
          </div>
          <pre className="json-preview onboarding-plan-preview">{realProviderOnboardingPlan}</pre>
          <div className="action-row" aria-label="真实供应商接入计划操作">
            <button className="secondary-button" type="button" onClick={() => void copyRealProviderOnboardingPlan()}>
              <Copy aria-hidden="true" size={15} />
              {copiedOnboardingPlan ? "计划已复制" : "复制接入计划"}
            </button>
            <button
              className="primary-button primary-button--inline"
              type="button"
              onClick={() => void applyRealProviderOnboardingPlan()}
              disabled={!data || onboardingApplyLoading}
            >
              {onboardingApplyLoading ? "正在创建配置" : "创建非密钥配置"}
            </button>
            {onNavigate ? (
              <>
                <button className="secondary-button" type="button" onClick={() => onNavigate("providers")}>
                  打开供应商
                  <ArrowRight aria-hidden="true" size={15} />
                </button>
                <button className="secondary-button" type="button" onClick={() => onNavigate("providerKeys")}>
                  打开供应商密钥
                  <ArrowRight aria-hidden="true" size={15} />
                </button>
                <button className="secondary-button" type="button" onClick={() => onNavigate("models")}>
                  打开模型
                  <ArrowRight aria-hidden="true" size={15} />
                </button>
              </>
            ) : null}
          </div>
          {onboardingApplyError ? <p className="form-status form-status--error">{onboardingApplyError}</p> : null}
          {onboardingApplySteps.length > 0 ? (
            <div className="onboarding-apply-result" aria-label="真实供应商接入应用结果">
              {onboardingApplySteps.map((step) => (
                <article key={`${step.label}-${step.action}`}>
                  <span>{onboardingActionLabel(step.action)}</span>
                  <strong>{step.label}</strong>
                  <p>{step.detail}</p>
                </article>
              ))}
            </div>
          ) : null}
          {onboardingDryRun ? (
            <dl className="detail-list detail-list--three" aria-label="真实供应商接入路由 dry-run">
              <div>
                <dt>Dry-run 状态</dt>
                <dd>{safeFieldValue(onboardingDryRun.selection.status)}</dd>
              </div>
              <div>
                <dt>选中通道</dt>
                <dd>{safeFieldValue(onboardingDryRun.selected_candidate?.channel_name)}</dd>
              </div>
              <div>
                <dt>选中供应商</dt>
                <dd>{safeFieldValue(onboardingDryRun.selected_candidate?.provider_name)}</dd>
              </div>
              <div>
                <dt>上游模型</dt>
                <dd>
                  {safeFieldValue(
                    onboardingDryRun.selected_candidate?.upstream_model ??
                      onboardingDryRun.selected_candidate?.provider_model,
                  )}
                </dd>
              </div>
              <div>
                <dt>候选项</dt>
                <dd>{onboardingDryRun.candidates.length}</dd>
              </div>
              <div>
                <dt>密钥边界</dt>
                <dd>Dry-run 不会调用上游，也不会返回 provider key material。</dd>
              </div>
            </dl>
          ) : null}
              </div>
            </div>
          </div>
        ) : null}
      </section>
      </div>

      <div className="operator-workflow-grid operator-workflow-grid--handoff" aria-label="运营配置和用户交接">
      <section className="admin-panel" aria-label="站点配置顺序">
        <div className="section-heading">
          <div>
            <h2>站点配置顺序</h2>
            <p>用户自助注册、兑换额度、创建 API key 并调用 Gateway 前，运营方需要完成的最小路径。</p>
          </div>
        </div>

        <div className="setup-sequence">
          {loading && !data ? (
            <div className="setup-step setup-step--pending">
              <div className="setup-step-index">1</div>
              <div>
                <h3>正在加载配置状态</h3>
                <p>正在读取供应商、凭证、模型、配置、密钥和用量库存。</p>
              </div>
            </div>
          ) : (
            setupSteps.map((step, index) => (
              <article className={`setup-step setup-step--${step.status}`} key={step.label}>
                <div className="setup-step-index">{index + 1}</div>
                <div className="setup-step-body">
                  <div className="setup-step-heading">
                    <div>
                      <h3>{step.label}</h3>
                      <p>{step.detail}</p>
                    </div>
                    <ProbeStatusChip status={step.status} />
                  </div>
                  <div className="setup-step-footer">
                    <span>{step.evidence}</span>
                    {step.target && onNavigate ? (
                      <button className="table-action" type="button" onClick={() => onNavigate(step.target!)}>
                        {step.targetLabel}
                        <ArrowRight aria-hidden="true" size={15} />
                      </button>
                    ) : (
                      <strong>{step.targetLabel}</strong>
                    )}
                  </div>
                </div>
              </article>
            ))
          )}
        </div>
      </section>

      <section className="admin-panel" aria-label="用户自助交接指南">
        <div className="section-heading">
          <div>
            <h2>用户自助交接</h2>
            <p>站点配置检查通过后的 New API 风格交付路径。</p>
          </div>
          <ProbeStatusChip status={readyToDistribute ? "online" : "pending"} />
        </div>
        <div className="handoff-flow" aria-label="用户自助交接步骤">
          <article>
            <span>1</span>
            <strong>User Portal</strong>
            <p>用户切换到 User Portal，创建账号并进入 API Gateway Console。</p>
          </article>
          <article>
            <span>2</span>
            <strong>券码额度</strong>
            <p>运营方从 Billing 发放券码；用户兑换到自己的项目钱包。</p>
          </article>
          <article>
            <span>3</span>
            <strong>API key</strong>
            <p>用户创建项目级 key。raw secret 只显示一次，不保存在截图中。</p>
          </article>
          <article>
            <span>4</span>
            <strong>Gateway 调用</strong>
            <p>用户调用 `/v1/models` 和 `/v1/chat/completions`，然后查看 Usage 和 Trace 详情。</p>
          </article>
        </div>
        <dl className="detail-list detail-list--three">
          <div>
            <dt>入口</dt>
            <dd>退出 Admin，选择 User Portal，然后创建或登录用户账号。</dd>
          </div>
          <div>
            <dt>当前证据</dt>
            <dd>Chromium preview E2E 覆盖注册、券码兑换、key 创建、`/v1/models`、chat、usage 和 trace。</dd>
          </div>
          <div>
            <dt>密钥边界</dt>
            <dd>不要交接 raw provider key、raw voucher code、admin session 或已保存的用户 API key secret。</dd>
          </div>
        </dl>
        {onNavigate ? (
          <div className="action-row">
            {onOpenUserPortal ? (
              <button className="secondary-button" type="button" onClick={onOpenUserPortal}>
                退出并打开 User Portal
                <ArrowRight aria-hidden="true" size={15} />
              </button>
            ) : null}
            <button className="secondary-button" type="button" onClick={() => onNavigate("billing")}>
              打开 Billing 券码
              <ArrowRight aria-hidden="true" size={15} />
            </button>
            <button className="secondary-button" type="button" onClick={() => onNavigate("requestLogs")}>
              打开 Request/Trace
              <ArrowRight aria-hidden="true" size={15} />
            </button>
            <button className="secondary-button" type="button" onClick={() => void copyUserHandoffChecklist()}>
              <Copy aria-hidden="true" size={15} />
              {copiedUserChecklist ? "清单已复制" : "复制用户清单"}
            </button>
          </div>
        ) : null}
      </section>
      </div>

      <section className="status-grid" aria-label="分发库存">
        <article className="status-card">
          <div>
            <h3>上游</h3>
            <p>{inventoryText(data?.providers.length, "个供应商")} / {inventoryText(data?.channels.length, "个通道")}</p>
          </div>
          <ProbeStatusChip status={data && enabledProviders(data.providers) > 0 && enabledChannels(data.channels) > 0 ? "online" : "pending"} />
        </article>
        <article className="status-card">
          <div>
            <h3>模型</h3>
            <p>{inventoryText(data?.models.length, "个模型")} / {routableModelCount(data?.healthSummary)} 个可路由</p>
          </div>
          <ProbeStatusChip status={routableModelCount(data?.healthSummary) > 0 ? "online" : "pending"} />
        </article>
        <article className="status-card">
          <div>
            <h3>用户密钥</h3>
            <p>{activeKeyCount(data?.keys)} 个活跃 key / {activeProfileCount(data?.profiles)} 个活跃配置</p>
          </div>
          <ProbeStatusChip status={activeProfileCount(data?.profiles) > 0 ? "online" : "pending"} />
        </article>
        <article className="status-card">
          <div>
            <h3>近期用量</h3>
            <p>已从 admin request logs 加载 {inventoryText(data?.logs.length, "个请求")}</p>
          </div>
          <ProbeStatusChip status={data && data.logs.length > 0 ? "online" : "pending"} />
        </article>
      </section>

      <section className="admin-panel" aria-label="分发实时提示">
        <div className="section-heading">
          <div>
            <h2>活跃分发表面</h2>
            <p>仅展示密钥安全标识；raw provider key、raw voucher code 和请求 payload 不进入该视图。</p>
          </div>
        </div>

        <div className="health-table-wrap">
          <table className="health-table admin-table">
            <thead>
              <tr>
                <th>表面</th>
                <th>主项</th>
                <th>信号</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td>供应商密钥</td>
                <td>{safeFieldValue(firstEnabledProviderKey(data?.providerKeys)?.key_alias)}</td>
                <td>{firstEnabledProviderKey(data?.providerKeys) ? "已配置启用凭证" : "未找到启用 key"}</td>
              </tr>
              <tr>
                <td>模型</td>
                <td>{safeFieldValue(data?.models[0]?.model_key)}</td>
                <td>{data?.models[0] ? `${safeFieldValue(data.models[0].display_name)} / ${shortId(data.models[0].id)}` : "无活跃模型"}</td>
              </tr>
              <tr>
                <td>配置</td>
                <td>{safeFieldValue(firstActiveProfile(data?.profiles)?.name)}</td>
                <td>{firstActiveProfile(data?.profiles) ? shortId(firstActiveProfile(data?.profiles)?.id) : "无活跃配置"}</td>
              </tr>
              <tr>
                <td>Virtual key</td>
                <td>{safeFieldValue(firstActiveKey(data?.keys)?.name)}</td>
                <td>{firstActiveKey(data?.keys) ? safeFieldValue(firstActiveKey(data?.keys)?.key_prefix) : "无活跃 key"}</td>
              </tr>
              <tr>
                <td>券码额度</td>
                <td>用户兑换路径</td>
                <td>admin 发放 + 用户兑换已由 New API MVP live smoke 覆盖</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </div>
  );
}

export default DistributionReadinessPage;

function compactReadinessBlocks(
  data: DistributionState | null,
  readyToDistribute: boolean,
): CompactReadinessBlock[] {
  const activeProfiles = activeProfileCount(data?.profiles);
  const activeKeys = activeKeyCount(data?.keys);
  const routableModels = routableModelCount(data?.healthSummary);
  const activeProviders = enabledProviders(data?.providers ?? []);
  const activeChannels = enabledChannels(data?.channels ?? []);
  const enabledProviderKeys = data?.providerKeys.filter((key) => key.status === "enabled").length ?? 0;
  const failedRequests = recentFailedRequests(data);
  const hasTraceSignal = (data?.logs.length ?? 0) > 0;

  return [
    {
      detail: readyToDistribute ? "上游、模型、用户配置和 key 有可用信号。" : firstBlockingReason(readinessRows(data)) ?? "等待分发状态。",
      label: "API 分发",
      next: readyToDistribute ? "可发 key；继续观察失败请求。" : "先处理阻塞项，再发 key。",
      status: readyToDistribute ? "online" : data ? "offline" : "pending",
      target: readyToDistribute ? "keys" : "providers",
    },
    {
      detail: "用户额度入口需要 Billing 发券和 User Portal 兑换。",
      label: "Voucher",
      next: "余额不足或用户无法调用时先查 Billing 和账本。",
      status: "online",
      target: "billing",
    },
    {
      detail: `${activeKeys} 个活跃 key，${activeProfiles} 个活跃 profile。`,
      label: "Virtual key",
      next: activeProfiles > 0 ? "用户可创建或复核 key 限制。" : "先创建 API key profile。",
      status: activeProfiles > 0 ? "online" : data ? "offline" : "pending",
      target: "keys",
    },
    {
      detail: `${routableModels} 个可路由模型；${activeProviders} 个供应商、${activeChannels} 个通道、${enabledProviderKeys} 个凭证启用。`,
      label: "Gateway route",
      next: routableModels > 0 ? "调用失败时查看路由 dry-run 和通道健康。" : "绑定模型到启用通道。",
      status: routableModels > 0 ? "online" : data ? "offline" : "pending",
      target: routableModels > 0 ? "routing" : "models",
    },
    {
      detail: hasTraceSignal ? `${failedRequests.length} 个近期失败请求。` : "还没有近期请求日志。",
      label: "Request trace",
      next: failedRequests.length > 0 ? "打开失败请求详情定位错误归属。" : "运行一次 Gateway 请求后刷新。",
      status: failedRequests.length > 0 ? "offline" : hasTraceSignal ? "online" : "pending",
      target: "requestLogs",
    },
  ];
}

function publicDistributionReadbackBlocks(data: DistributionState | null): PublicDistributionReadbackBlock[] {
  const authority = data?.authority;

  if (!authority) {
    return [
      {
        detail: "等待后端权威 readiness。",
        label: "Voucher batch",
        next: "刷新分发就绪状态。",
        status: "pending",
      },
      {
        detail: "等待后端权威 readiness。",
        label: "Redeem",
        next: "刷新分发就绪状态。",
        status: "pending",
      },
      {
        detail: "等待后端权威 readiness。",
        label: "Virtual key",
        next: "刷新分发就绪状态。",
        status: "pending",
      },
      {
        detail: "等待后端权威 readiness。",
        label: "Quota/pricing",
        next: "刷新分发就绪状态。",
        status: "pending",
      },
    ];
  }

  const voucherBatch = authority.voucher_batch_status;
  const redeem = authority.redeem_readiness;
  const virtualKey = authority.virtual_key_issuance_readiness;
  const guardrails = authority.quota_pricing_guardrails;

  return [
    {
      detail: voucherBatch
        ? `${voucherBatch.batch_count} 个 batch，${voucherBatch.voucher_count} 张券，${voucherBatch.revocable_count} 张可撤销。`
        : "后端未返回 batch readback。",
      label: "Voucher batch",
      next: voucherBatch?.safe_next_action ?? "查询或创建券码 batch。",
      status: readinessStatus(voucherBatch?.status ?? "pending"),
    },
    {
      detail: redeem
        ? `${redeem.issued_count} 张待兑换，${redeem.successful_redemption_count ?? 0} 次成功兑换，${redeem.credit_or_ledger_effect_count} 个额度效果。`
        : "后端未返回兑换 readback。",
      label: "Redeem",
      next: redeem?.safe_next_action ?? "通过 User Portal 兑换一张测试券。",
      status: readinessStatus(redeem?.status ?? "pending"),
    },
    {
      detail: virtualKey
        ? `${virtualKey.active_profile_count} 个活跃 profile，${virtualKey.active_virtual_key_count} 个活跃 key。`
        : "后端未返回 key issuance readback。",
      label: "Virtual key",
      next: virtualKey?.safe_next_action ?? "创建默认项目 API key profile。",
      status: readinessStatus(virtualKey?.status ?? "pending"),
    },
    {
      detail: guardrails
        ? `${guardrails.active_price_version_count} 个价格版本，${guardrails.configured_virtual_key_rate_limit_policy_count} 个 rate policy，${guardrails.configured_virtual_key_budget_policy_count} 个 budget policy。`
        : "后端未返回 guardrail readback。",
      label: "Quota/pricing",
      next: guardrails?.safe_next_action ?? "补 pricing 或 quota/rate/budget guardrail。",
      status: readinessStatus(guardrails?.status ?? "pending"),
    },
  ];
}

function recentFailedRequests(data: DistributionState | null): RequestLogSummary[] {
  return (data?.logs ?? [])
    .filter((log) => log.status !== "succeeded" || (typeof log.http_status === "number" && log.http_status >= 400))
    .slice(0, 6);
}

function failureSummary(log: RequestLogSummary): string {
  const parts = [log.error_owner, log.error_code].filter((value): value is string => Boolean(value?.trim()));

  if (parts.length > 0) {
    return parts.map(safeFieldValue).join(" / ");
  }

  if (log.status === "rejected") {
    return "路由拒绝";
  }
  if (log.status === "failed") {
    return "请求失败";
  }

  return safeFieldValue(log.status);
}

function actionRows(rows: ReadinessRow[]): ReadinessRow[] {
  const order: Record<ReadinessStatus, number> = {
    offline: 0,
    pending: 1,
    online: 2,
  };

  return rows.slice().sort((left, right) => order[left.status] - order[right.status]);
}

function firstBlockingReason(rows: ReadinessRow[]): string | null {
  const blockingRow = rows.find((row) => row.status === "offline") ?? rows.find((row) => row.status === "pending");

  return blockingRow ? `${blockingRow.label}: ${blockingRow.next}` : null;
}

function readinessRows(data: DistributionState | null): ReadinessRow[] {
  if (!data) {
    return [];
  }

  if (data.authority) {
    return data.authority.checks.map((check) => ({
      detail: check.detail,
      evidence: check.evidence,
      label: check.label,
      next: check.next_action,
      status: readinessStatus(check.status),
    }));
  }

  const activeProviders = enabledProviders(data.providers);
  const activeChannels = enabledChannels(data.channels);
  const enabledProviderKeys = data.providerKeys.filter((key) => key.status === "enabled").length;
  const activeModels = data.models.length;
  const routableModels = routableModelCount(data.healthSummary);
  const enabledAssociations = data.modelAssociations.filter((association) => association.status === "enabled").length;
  const activeProfiles = activeProfileCount(data.profiles);
  const activeKeys = activeKeyCount(data.keys);
  const successfulLogs = data.logs.filter((log) => log.status === "succeeded" || log.http_status === 200).length;

  return [
    {
      detail: "至少有一个启用的上游供应商和通道。",
      evidence: `${activeProviders}/${data.providers.length} 个供应商、${activeChannels}/${data.channels.length} 个通道已启用`,
      label: "上游路由基础",
      next: activeProviders > 0 && activeChannels > 0 ? "保持健康探测正常" : "配置供应商和通道",
      status: activeProviders > 0 && activeChannels > 0 ? "online" : "offline",
    },
    {
      detail: "供应商密钥已存在，且不暴露 secret material。",
      evidence: `${enabledProviderKeys}/${data.providerKeys.length} 个凭证已启用`,
      label: "供应商凭证",
      next: enabledProviderKeys > 0 ? "需要时通过 Provider Keys 轮换" : "添加或恢复 provider key",
      status: enabledProviderKeys > 0 ? "online" : "offline",
    },
    {
      detail: "活跃模型有启用的路由候选项。",
      evidence: `${routableModels}/${activeModels} 个活跃模型可路由，${enabledAssociations} 个关联已启用`,
      label: "模型路由",
      next: routableModels > 0 ? "变更前使用 Routing dry-run" : "将模型关联绑定到通道",
      status: routableModels > 0 ? "online" : "offline",
    },
    {
      detail: "默认项目有活跃的 API key profile。",
      evidence: `默认项目有 ${activeProfiles}/${data.profiles.length} 个活跃配置`,
      label: "API key profile",
      next: activeProfiles > 0 ? "保持 allowed models 与公开目录一致" : "创建活跃配置",
      status: activeProfiles > 0 ? "online" : "offline",
    },
    {
      detail: "至少有一个项目 virtual key 可用于 API 调用。",
      evidence: `${activeKeys}/${data.keys.length} 个 virtual key 活跃`,
      label: "Virtual key 分发",
      next: activeKeys > 0 ? "用户可在 User Portal 创建自己的 key" : "创建 key 或请用户创建 key",
      status: activeKeys > 0 ? "online" : "pending",
    },
    {
      detail: "券码支持的额度路径仍是 MVP 充值模式。",
      evidence: "Admin 发放路径 + 用户兑换路径已由 USER-006 live smoke 验证",
      label: "券码额度",
      next: "Payment/order/invoice 继续延后",
      status: "online",
    },
    {
      detail: "近期 request logs 证明运行路径可观测。",
      evidence: `已加载 ${successfulLogs}/${data.logs.length} 个近期成功请求`,
      label: "用量可观测性",
      next: data.logs.length > 0 ? "打开 Request/Trace 查看失败" : "运行一个 Gateway 请求",
      status: data.logs.length > 0 ? "online" : "pending",
    },
    {
      detail: "用户自助表面是 New API 风格交付路径。",
      evidence: "注册/登录、余额、用户模型、券码兑换、自助 API key、用量日志",
      label: "User Portal",
      next: "继续优化 UX；enterprise SSO 保持延后",
      status: "online",
    },
  ];
}

function readinessStatus(status: string): ReadinessStatus {
  if (status === "online" || status === "offline" || status === "pending") {
    return status;
  }
  if (status === "ready") {
    return "online";
  }
  if (status === "blocked") {
    return "offline";
  }
  if (status === "attention") {
    return "pending";
  }

  return "pending";
}

function setupSequence(data: DistributionState | null): SetupStep[] {
  if (!data) {
    return [];
  }

  const activeProviders = enabledProviders(data.providers);
  const activeChannels = enabledChannels(data.channels);
  const enabledProviderKeys = data.providerKeys.filter((key) => key.status === "enabled").length;
  const routableModels = routableModelCount(data.healthSummary);
  const enabledAssociations = data.modelAssociations.filter((association) => association.status === "enabled").length;
  const activeProfiles = activeProfileCount(data.profiles);
  const activeKeys = activeKeyCount(data.keys);
  const successfulLogs = data.logs.filter((log) => log.status === "succeeded" || log.http_status === 200).length;

  return [
    {
      detail: "创建至少一个启用的供应商和通道。这是所有用户 API 调用的上游基础。",
      evidence: `${activeProviders}/${data.providers.length} 个供应商、${activeChannels}/${data.channels.length} 个通道已启用`,
      label: "配置供应商和通道",
      status: activeProviders > 0 && activeChannels > 0 ? "online" : "offline",
      target: "providers",
      targetLabel: "打开供应商",
    },
    {
      detail: "为通道挂载上游凭证，并在创建后不暴露 raw key。",
      evidence: `${enabledProviderKeys}/${data.providerKeys.length} 个 provider key 已启用`,
      label: "添加供应商凭证",
      status: enabledProviderKeys > 0 ? "online" : "offline",
      target: "providerKeys",
      targetLabel: "打开 Provider Keys",
    },
    {
      detail: "创建公开模型名，并绑定到启用的通道路由。",
      evidence: `${routableModels} 个可路由模型，${enabledAssociations} 个关联已启用`,
      label: "发布可路由模型",
      status: routableModels > 0 ? "online" : "offline",
      target: "models",
      targetLabel: "打开模型",
    },
    {
      detail: "为默认项目创建活跃的 API key profile。用户自助 key 依赖该配置。",
      evidence: `默认项目有 ${activeProfiles}/${data.profiles.length} 个活跃配置`,
      label: "启用用户 API key profile",
      status: activeProfiles > 0 ? "online" : "offline",
      target: "keys",
      targetLabel: "打开 Virtual Keys",
    },
    {
      detail: "之后用户可在 User Portal 注册、兑换券码额度并创建自己的 API key。",
      evidence: `admin 当前可见 ${activeKeys}/${data.keys.length} 个活跃项目 virtual key`,
      label: "交接到 User Portal",
      status: activeKeys > 0 ? "online" : "pending",
      target: "keys",
      targetLabel: "复核 Keys",
    },
    {
      detail: "运行一个 Gateway 请求，并确认脱敏 request logs 可用于支持和用户自助排查。",
      evidence: `已加载 ${successfulLogs}/${data.logs.length} 个近期成功请求`,
      label: "验证 live 调用和日志",
      status: data.logs.length > 0 ? "online" : "pending",
      target: "requestLogs",
      targetLabel: "打开 Request/Trace",
    },
  ];
}

function routeTopologyRows(data: DistributionState | null): RouteTopologyRow[] {
  if (!data) {
    return [];
  }

  const providerById = new Map(data.providers.map((provider) => [provider.id, provider]));
  const channelById = new Map(data.channels.map((channel) => [channel.id, channel]));
  const modelById = new Map(data.models.map((model) => [model.id, model]));
  const keysByChannelId = groupBy(data.providerKeys, (key) => key.channel_id);
  const logsByChannelId = groupBy(
    data.logs.filter((log) => log.resolved_channel_id),
    (log) => log.resolved_channel_id ?? "",
  );
  const activeProfiles = data.profiles.filter((profile) => profile.status === "active");
  const associations = data.modelAssociations
    .filter((association) => association.status === "enabled" && association.channel_id)
    .slice()
    .sort((left, right) => left.priority - right.priority);

  const rows = associations.map((association) => {
    const channel = channelById.get(association.channel_id ?? "");
    const provider = channel ? providerById.get(channel.provider_id) : undefined;
    const model = modelById.get(association.canonical_model_id);
    const providerKeys = channel ? keysByChannelId.get(channel.id) ?? [] : [];
    const enabledProviderKey = providerKeys.find((key) => key.status === "enabled");
    const profileNames = model
      ? activeProfiles
          .filter((profile) => profileAllowsModel(profile, model.model_key))
          .map((profile) => profile.name)
      : [];
    const recentLog = channel ? logsByChannelId.get(channel.id)?.[0] : undefined;
    const isOnline =
      provider?.status === "enabled" &&
      channel?.status === "enabled" &&
      Boolean(enabledProviderKey) &&
      Boolean(model) &&
      profileNames.length > 0;

    return {
      channelName: safeFieldValue(channel?.name),
      credential: enabledProviderKey
        ? `${enabledProviderKey.key_alias} / enabled`
        : providerKeys.length > 0
          ? `${providerKeys.length} 个 key，未启用`
          : "无 provider key",
      lastRequest: recentLog
        ? `${safeFieldValue(recentLog.status)} / ${safeFieldValue(recentLog.http_status)} / ${formatShortDate(recentLog.created_at)}`
        : "该通道暂无近期请求",
      modelName: safeFieldValue(model?.model_key),
      profile: profileNames.length > 0 ? profileNames.slice(0, 2).join(", ") : "无活跃配置允许该模型",
      providerName: provider ? `${provider.name} (${provider.code})` : "缺少供应商",
      route: association.fallback_allowed ? "主路由 + fallback" : "仅主路由",
      status: isOnline ? "online" : channel?.status === "disabled" || provider?.status === "disabled" ? "offline" : "pending",
      upstreamModel: safeFieldValue(association.upstream_model_name ?? model?.model_key),
    } satisfies RouteTopologyRow;
  });

  if (rows.length > 0) {
    return rows.slice(0, 8);
  }

  return data.channels
    .filter((channel) => channel.status !== "deleted")
    .slice(0, 8)
    .map((channel) => {
      const provider = providerById.get(channel.provider_id);
      const providerKeys = keysByChannelId.get(channel.id) ?? [];
      const enabledProviderKey = providerKeys.find((key) => key.status === "enabled");

      return {
        channelName: channel.name,
        credential: enabledProviderKey ? `${enabledProviderKey.key_alias} / enabled` : "无 provider key",
        lastRequest: "尚无模型关联",
        modelName: "无公开模型",
        profile: "无活跃模型配置",
        providerName: provider ? `${provider.name} (${provider.code})` : "缺少供应商",
        route: "仅通道",
        status: provider?.status === "enabled" && channel.status === "enabled" && enabledProviderKey ? "pending" : "offline",
        upstreamModel: "无上游模型",
      };
    });
}

function groupBy<T>(items: T[], keyForItem: (item: T) => string): Map<string, T[]> {
  const result = new Map<string, T[]>();

  for (const item of items) {
    const key = keyForItem(item);
    const group = result.get(key);

    if (group) {
      group.push(item);
    } else {
      result.set(key, [item]);
    }
  }

  return result;
}

function profileAllowsModel(profile: ApiKeyProfile, modelKey: string): boolean {
  if (!Array.isArray(profile.allowed_models)) {
    return false;
  }

  return profile.allowed_models.some((value) => value === "*" || value === modelKey);
}

function formatShortDate(value: string | null | undefined): string {
  if (!value) {
    return "无时间";
  }

  const parsed = new Date(value);

  if (Number.isNaN(parsed.getTime())) {
    return value;
  }

  return parsed.toLocaleString([], {
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    month: "short",
  });
}

function buildRealProviderOnboardingPlan(form: RealProviderPlanForm): string {
  const providerName = safePlanValue(form.providerName, "OpenAI");
  const providerCode = safePlanValue(form.providerCode, "openai");
  const baseUrl = safePlanValue(form.baseUrl, "https://api.openai.com/v1");
  const channelName = safePlanValue(form.channelName, "primary-openai");
  const providerKeyAlias = safePlanValue(form.providerKeyAlias, `${channelName}-key`);
  const publicModel = safePlanValue(form.publicModel, "gpt-4o-mini");
  const upstreamModel = safePlanValue(form.upstreamModel, publicModel);
  const profileName = safePlanValue(form.profileName, "default-user-profile");

  return [
    "真实供应商接入计划",
    `供应商: ${providerName} (${providerCode})`,
    `Base URL: ${baseUrl}`,
    `通道: ${channelName}`,
    `Provider key alias: ${providerKeyAlias}`,
    `公开模型: ${publicModel}`,
    `上游模型: ${upstreamModel}`,
    `用户配置: ${profileName}`,
    "步骤:",
    "1. Providers: 创建或确认供应商和启用通道。",
    "2. Provider Keys: 为该通道创建一个启用的 provider key。raw API key 只输入到一次性 secret 字段或 Provider Keys 创建表单。",
    "3. Models: 创建公开模型，并绑定到通道/上游模型。",
    "4. Virtual Keys: 确认默认用户配置允许该公开模型。",
    "5. Distribution: 设置 REAL_PROVIDER_BASE_URL、REAL_PROVIDER_API_KEY 和 REAL_PROVIDER_MODEL 后运行真实供应商接入 smoke。",
    "6. User Portal: 用户兑换券码额度、创建 API key、调用 /v1/models 和 /v1/chat/completions，然后查看 Usage。",
    "密钥边界：该计划刻意排除 raw provider key、raw user API key secret、raw voucher code、Authorization header、session cookie 和请求 payload。一次性 provider API key 输入永远不会进入复制的计划。",
  ].join("\n");
}

function safePlanValue(value: string, fallback: string): string {
  const trimmed = value.trim();

  return trimmed.length > 0 ? trimmed : fallback;
}

function slugPlanValue(value: string, fallback: string): string {
  const slug = value
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, "-")
    .replace(/^-+|-+$/g, "");

  return slug.length > 0 ? slug : fallback;
}

function activeModelsFromHealth(
  healthSummary: HealthSummary | null,
  canonicalModels: CanonicalModel[],
) {
  const modelRouteById = new Map((healthSummary?.models ?? []).map((model) => [model.id, model]));

  return canonicalModels
    .filter((model) => model.status === "active")
    .map((model) => ({
      ...model,
      route: modelRouteById.get(model.id),
    }));
}

function settledValue<T>(result: PromiseSettledResult<T>, fallback: T): T {
  return result.status === "fulfilled" ? result.value : fallback;
}

function enabledProviders(providers: Provider[]): number {
  return providers.filter((provider) => provider.status === "enabled").length;
}

function enabledChannels(channels: Channel[]): number {
  return channels.filter((channel) => channel.status === "enabled").length;
}

function routableModelCount(summary: HealthSummary | null | undefined): number {
  return summary?.models.filter((model) => model.routing_state === "routable").length ?? 0;
}

function activeProfileCount(profiles: ApiKeyProfile[] | null | undefined): number {
  return profiles?.filter((profile) => profile.status === "active").length ?? 0;
}

function activeKeyCount(keys: VirtualKey[] | null | undefined): number {
  return keys?.filter((key) => key.status === "active").length ?? 0;
}

function firstEnabledProviderKey(keys: ProviderKey[] | null | undefined): ProviderKey | undefined {
  return keys?.find((key) => key.status === "enabled");
}

function firstActiveProfile(profiles: ApiKeyProfile[] | null | undefined): ApiKeyProfile | undefined {
  return profiles?.find((profile) => profile.status === "active");
}

function firstActiveKey(keys: VirtualKey[] | null | undefined): VirtualKey | undefined {
  return keys?.find((key) => key.status === "active");
}

function inventoryText(value: number | null | undefined, label: string): string {
  const count = value ?? 0;

  return `${count} ${label}`;
}

function onboardingActionLabel(action: OnboardingApplyStep["action"]): string {
  if (action === "created") {
    return "已创建";
  }

  if (action === "reused") {
    return "已复用";
  }

  return "已跳过";
}

async function writeClipboard(value: string): Promise<void> {
  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(value);
      return;
    } catch {
      // Fall through to the legacy textarea path for browsers that deny clipboard access in tests.
    }
  }

  const textarea = document.createElement("textarea");
  textarea.value = value;
  textarea.setAttribute("readonly", "true");
  textarea.style.position = "fixed";
  textarea.style.left = "-9999px";
  document.body.appendChild(textarea);
  textarea.select();
  document.execCommand("copy");
  document.body.removeChild(textarea);
}
