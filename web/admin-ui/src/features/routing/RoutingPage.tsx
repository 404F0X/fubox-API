import { useEffect, useMemo, useState } from "react";

import {
  type ApiKeyProfile,
  type CanonicalModel,
  type Channel,
  type JsonValue,
  listApiKeyProfiles,
  listCanonicalModels,
  listChannels,
  listModelAssociations,
  listPriceVersions,
  listProviderKeys,
  listVirtualKeys,
  type ModelAssociation,
  type ModelAssociationStatus,
  patchModelAssociation,
  type PriceVersion,
  type ProviderKey,
  type VirtualKey,
} from "../../api/client";
import { ActionButton } from "../../design/ActionButton";
import { DataTable } from "../../design/DataTable";
import { EmptyState } from "../../design/EmptyState";
import { MetricTile } from "../../design/MetricTile";
import { SectionHeader } from "../../design/SectionHeader";
import { StatusChip } from "../../design/StatusChip";
import { errorMessage } from "../../components/adminUtils";
import { Database, Key, RefreshCw, RotateCcw, Search, ShieldOff } from "../../components/icons";
import { safeDisplayText, safeShortId, statusLabel } from "../../lib/safeText";
import { ModelAssociationDryRun } from "../models/ModelAssociationDryRun";
import { ModelPriceSummary, selectedPriceVersionLabel } from "../models/ModelPriceSummary";
import { channelProtocolLabel, channelProtocolStatus } from "../providers/providerPolicyUtils";

const DEFAULT_PROJECT_ID = "00000000-0000-0000-0000-000000000020";

type RoutingPageProps = {
  onOpenKeys?: () => void;
  onOpenModels?: () => void;
};

type DryRunPreset = {
  canonicalModelId?: string;
  canonicalModelKey?: string;
  profileId?: string;
  projectId?: string;
  requestedModel?: string;
};

type RoutingData = {
  associations: ModelAssociation[];
  channels: Channel[];
  keys: VirtualKey[];
  models: CanonicalModel[];
  priceVersions: PriceVersion[];
  providerKeys: ProviderKey[];
  profiles: ApiKeyProfile[];
};

type MatrixScope = "profile" | "api_key";

type VisibilityMatrixRow = {
  alias: string;
  allowed: boolean;
  blockedProviders: string;
  candidateAssociation: ModelAssociation | null;
  channelTags: string;
  denied: boolean;
  model: CanonicalModel;
  protocolState: string;
  reasons: string[];
  requestedModel: string;
  routable: boolean;
};

export function RoutingPage({ onOpenKeys, onOpenModels }: RoutingPageProps) {
  const [data, setData] = useState<RoutingData>({
    associations: [],
    channels: [],
    keys: [],
    models: [],
    priceVersions: [],
    providerKeys: [],
    profiles: [],
  });
  const [dryRunPreset, setDryRunPreset] = useState<DryRunPreset>({
    projectId: DEFAULT_PROJECT_ID,
  });
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [mappingBusyId, setMappingBusyId] = useState<string | null>(null);
  const [matrixScope, setMatrixScope] = useState<MatrixScope>("profile");
  const [selectedKeyId, setSelectedKeyId] = useState("");
  const [selectedProfileId, setSelectedProfileId] = useState("");
  const [success, setSuccess] = useState<string | null>(null);

  async function loadRoutingData() {
    setError(null);
    setSuccess(null);
    setLoading(true);

    try {
      const [models, associations, channels, profiles, keys, providerKeys, priceVersions] = await Promise.all([
        listCanonicalModels(),
        listModelAssociations(),
        listChannels(),
        listApiKeyProfiles({ project_id: DEFAULT_PROJECT_ID }),
        listVirtualKeys({ project_id: DEFAULT_PROJECT_ID }),
        listProviderKeys(),
        listPriceVersions({ status: "active", limit: 100 }),
      ]);
      setData({ associations, channels, keys, models, priceVersions, profiles, providerKeys });
      setDryRunPreset((current) => ({
        ...current,
        profileId: current.profileId || profiles.find((profile) => profile.status === "active")?.id,
        projectId: current.projectId || DEFAULT_PROJECT_ID,
      }));
      setSelectedProfileId((current) => current || profiles.find((profile) => profile.status === "active")?.id || profiles[0]?.id || "");
      setSelectedKeyId((current) => current || keys.find((key) => key.status === "active")?.id || keys[0]?.id || "");
    } catch (requestError) {
      setError(errorMessage(requestError));
      setData({
        associations: [],
        channels: [],
        keys: [],
        models: [],
        priceVersions: [],
        providerKeys: [],
        profiles: [],
      });
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    void loadRoutingData();
  }, []);

  const enabledAssociations = data.associations.filter((association) => association.status === "enabled");
  const activeModels = data.models.filter((model) => model.status === "active");
  const publicModels = activeModels.filter((model) => model.visibility === "public");
  const routableModelIds = new Set(enabledAssociations.map((association) => association.canonical_model_id));
  const routablePublicModels = publicModels.filter((model) => routableModelIds.has(model.id));
  const activeProfiles = data.profiles.filter((profile) => profile.status === "active");
  const selectedKey = data.keys.find((key) => key.id === selectedKeyId) ?? data.keys[0] ?? null;
  const keyProfileId = selectedKey?.default_profile_id ?? "";
  const selectedProfile =
    matrixScope === "api_key"
      ? data.profiles.find((profile) => profile.id === keyProfileId) ?? null
      : data.profiles.find((profile) => profile.id === selectedProfileId) ?? activeProfiles[0] ?? data.profiles[0] ?? null;
  const visibilityRows = useMemo(
    () => buildVisibilityMatrix({
      associations: enabledAssociations,
      channels: data.channels,
      key: matrixScope === "api_key" ? selectedKey : null,
      models: data.models,
      profile: selectedProfile,
      providerKeys: data.providerKeys,
    }),
    [data.channels, data.models, data.providerKeys, enabledAssociations, matrixScope, selectedKey, selectedProfile],
  );
  const visibleModels = visibilityRows.filter((row) => row.routable).map((row) => row.model);

  function presetForModel(model: CanonicalModel) {
    const matrixRow = visibilityRows.find((row) => row.model.id === model.id);

    setDryRunPreset({
      canonicalModelId: model.id,
      canonicalModelKey: model.model_key,
      profileId: selectedProfile?.id ?? "",
      projectId: selectedProfile?.project_id ?? DEFAULT_PROJECT_ID,
      requestedModel: matrixRow?.requestedModel ?? model.model_key,
    });
  }

  function presetForAssociation(association: ModelAssociation) {
    const model = data.models.find((item) => item.id === association.canonical_model_id);

    setDryRunPreset({
      canonicalModelId: association.canonical_model_id,
      canonicalModelKey: model?.model_key ?? "",
      profileId: selectedProfile?.id ?? "",
      projectId: selectedProfile?.project_id ?? DEFAULT_PROJECT_ID,
      requestedModel: model?.model_key ?? association.upstream_model_name ?? "",
    });
  }

  async function updateMappingStatus(association: ModelAssociation, status: ModelAssociationStatus) {
    setError(null);
    setSuccess(null);
    setMappingBusyId(association.id);

    try {
      const updated = await patchModelAssociation(association.id, { status });
      setData((current) => ({
        ...current,
        associations: current.associations.map((item) => (item.id === updated.id ? updated : item)),
      }));
      setSuccess(`映射 ${safeShortId(association.id)} 已${status === "enabled" ? "启用" : "停用"}。`);
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setMappingBusyId(null);
    }
  }

  return (
    <div className="admin-page" aria-label="路由工作台">
      <section className="admin-panel" aria-label="路由工作台摘要">
        <SectionHeader
          actions={
            <div className="action-row">
              <ActionButton icon={<Database aria-hidden="true" size={17} />} onClick={onOpenModels}>
                模型和映射
              </ActionButton>
              <ActionButton icon={<Key aria-hidden="true" size={17} />} onClick={onOpenKeys}>
                API Key 配置
              </ActionButton>
              <ActionButton disabled={loading} icon={<RefreshCw aria-hidden="true" className={loading ? "spin" : undefined} size={17} />} onClick={() => void loadRoutingData()}>
                刷新
              </ActionButton>
            </div>
          }
          description="查看用户可见模型、上游模型映射和 dry-run 选择结果。错误和快照只显示脱敏摘要。"
          title="路由工作台"
        />

        <div className="status-grid status-grid--compact" aria-label="路由摘要">
          <MetricTile detail="active + public" label="公开模型" tone="neutral" value={String(publicModels.length)} />
          <MetricTile detail="enabled mapping" label="启用映射" tone={enabledAssociations.length > 0 ? "good" : "warn"} value={String(enabledAssociations.length)} />
          <MetricTile detail="public + mapped" label="可路由模型" tone={routablePublicModels.length > 0 ? "good" : "warn"} value={String(routablePublicModels.length)} />
          <MetricTile detail={selectedProfile ? safeShortId(selectedProfile.id) : "需要 profile"} label="默认 Profile" tone={selectedProfile ? "good" : "warn"} value={String(activeProfiles.length)} />
        </div>

        {error ? <p className="form-status form-status--error">{error}</p> : null}
        {success ? <p className="form-status form-status--success">{success}</p> : null}
      </section>

      <section className="admin-panel" aria-label="用户可见模型">
        <SectionHeader
          actions={
            <ActionButton icon={<Database aria-hidden="true" size={17} />} onClick={onOpenModels}>
              维护模型
            </ActionButton>
          }
          description="按 profile/group 或 API key 维度解释 /v1/models 可见性和最终路由可用性。"
          title="用户可见模型矩阵"
        />
        <VisibilityMatrixControls
          keys={data.keys}
          loading={loading}
          matrixScope={matrixScope}
          onKeyChange={setSelectedKeyId}
          onProfileChange={setSelectedProfileId}
          onScopeChange={setMatrixScope}
          profiles={data.profiles}
          selectedKeyId={selectedKeyId}
          selectedProfile={selectedProfile}
          selectedProfileId={selectedProfileId}
        />
        <VisibleModelsTable loading={loading} onDryRun={presetForModel} priceVersions={data.priceVersions} rows={visibilityRows} />
      </section>

      <section className="admin-panel" aria-label="上游映射">
        <SectionHeader
          actions={
            <ActionButton icon={<Database aria-hidden="true" size={17} />} onClick={onOpenModels}>
              创建映射
            </ActionButton>
          }
          description="展示 canonical model 到 provider/channel/upstream model 的映射。"
          title="上游模型映射"
        />
        <AssociationMapTable
          associations={data.associations}
          busyId={mappingBusyId}
          channels={data.channels}
          loading={loading}
          models={data.models}
          onDryRun={presetForAssociation}
          onStatus={updateMappingStatus}
          priceVersions={data.priceVersions}
          providerKeys={data.providerKeys}
        />
      </section>

      <ModelAssociationDryRun initialForm={dryRunPreset} models={data.models} priceVersions={data.priceVersions} />
    </div>
  );
}

function VisibleModelsTable({
  loading,
  rows,
  onDryRun,
  priceVersions,
}: {
  loading: boolean;
  rows: VisibilityMatrixRow[];
  onDryRun: (model: CanonicalModel) => void;
  priceVersions: PriceVersion[];
}) {
  if (!loading && rows.length === 0) {
    return (
      <EmptyState
        action={<span className="muted-copy">需要 active/public 模型、API key profile 和启用映射。</span>}
        title="暂无模型矩阵"
      />
    );
  }

  return (
    <DataTable aria-label="用户可见模型表">
      <thead>
        <tr>
          <th>模型</th>
          <th>Allowed / denied</th>
          <th>Alias</th>
          <th>Channel tag</th>
          <th>Blocked provider</th>
          <th>Protocol</th>
          <th>价格</th>
          <th>最终 routable</th>
          <th>原因 / 操作</th>
        </tr>
      </thead>
      <tbody>
        {loading ? (
          <tr>
            <td colSpan={9}>正在加载可见模型矩阵。</td>
          </tr>
        ) : (
          rows.map((row) => (
            <tr key={row.model.id}>
              <td>
                <strong>{safeDisplayText(row.model.display_name)}</strong>
                <span>{safeDisplayText(row.model.model_key)}</span>
              </td>
              <td>
                <StatusChip tone={row.allowed ? "good" : "warn"}>{row.allowed ? "allowed" : "not allowed"}</StatusChip>
                <span>{row.denied ? "denied by profile" : "not denied"}</span>
              </td>
              <td>{safeDisplayText(row.alias)}</td>
              <td>{safeDisplayText(row.channelTags)}</td>
              <td>{safeDisplayText(row.blockedProviders)}</td>
              <td>{safeDisplayText(row.protocolState)}</td>
              <td>
                <ModelPriceSummary model={row.model} priceVersions={priceVersions} />
              </td>
              <td>
                <StatusChip tone={row.routable ? "good" : "danger"}>{row.routable ? "routable" : "not routable"}</StatusChip>
              </td>
              <td>
                <span>{safeDisplayText(row.reasons.join("；"))}</span>
                <ActionButton
                  icon={<Search aria-hidden="true" size={15} />}
                  onClick={() => onDryRun(row.model)}
                  variant="table"
                >
                  Dry-run
                </ActionButton>
              </td>
            </tr>
          ))
        )}
      </tbody>
    </DataTable>
  );
}

function VisibilityMatrixControls({
  keys,
  loading,
  matrixScope,
  onKeyChange,
  onProfileChange,
  onScopeChange,
  profiles,
  selectedKeyId,
  selectedProfile,
  selectedProfileId,
}: {
  keys: VirtualKey[];
  loading: boolean;
  matrixScope: MatrixScope;
  onKeyChange: (value: string) => void;
  onProfileChange: (value: string) => void;
  onScopeChange: (value: MatrixScope) => void;
  profiles: ApiKeyProfile[];
  selectedKeyId: string;
  selectedProfile: ApiKeyProfile | null;
  selectedProfileId: string;
}) {
  return (
    <div className="toolbar-row" aria-label="模型可见性矩阵筛选">
      <label className="field">
        维度
        <select
          disabled={loading}
          value={matrixScope}
          onChange={(event) => onScopeChange(event.currentTarget.value as MatrixScope)}
        >
          <option value="profile">Profile / group</option>
          <option value="api_key">API key</option>
        </select>
      </label>
      {matrixScope === "api_key" ? (
        <label className="field">
          API key
          <select disabled={loading || keys.length === 0} value={selectedKeyId} onChange={(event) => onKeyChange(event.currentTarget.value)}>
            {keys.map((key) => (
              <option key={key.id} value={key.id}>
                {key.name} / {key.key_prefix}
              </option>
            ))}
          </select>
        </label>
      ) : (
        <label className="field">
          Profile / group
          <select
            disabled={loading || profiles.length === 0}
            value={selectedProfileId}
            onChange={(event) => onProfileChange(event.currentTarget.value)}
          >
            {profiles.map((profile) => (
              <option key={profile.id} value={profile.id}>
                {profile.name} / {safeShortId(profile.id)}
              </option>
            ))}
          </select>
        </label>
      )}
      <div className="toolbar-summary">
        <Search aria-hidden="true" size={16} />
        <span>
          {selectedProfile
            ? `当前策略 ${safeDisplayText(selectedProfile.name)} / ${statusLabel(selectedProfile.status)}`
            : "缺少 profile，矩阵会全部标记为不可用。"}
        </span>
      </div>
    </div>
  );
}

function AssociationMapTable({
  associations,
  busyId,
  channels,
  loading,
  models,
  onDryRun,
  onStatus,
  priceVersions,
  providerKeys,
}: {
  associations: ModelAssociation[];
  busyId: string | null;
  channels: Channel[];
  loading: boolean;
  models: CanonicalModel[];
  onDryRun: (association: ModelAssociation) => void;
  onStatus: (association: ModelAssociation, status: ModelAssociationStatus) => Promise<void>;
  priceVersions: PriceVersion[];
  providerKeys: ProviderKey[];
}) {
  const enabledProviderKeyChannelIds = new Set(
    providerKeys.filter((providerKey) => providerKey.status === "enabled").map((providerKey) => providerKey.channel_id),
  );

  if (!loading && associations.length === 0) {
    return <EmptyState title="暂无上游映射" detail="从模型页创建 provider/channel/model mapping 后，这里会显示 dry-run 入口。" />;
  }

  return (
    <DataTable aria-label="上游模型映射表">
      <thead>
        <tr>
          <th>Canonical model</th>
          <th>目标渠道</th>
          <th>上游模型</th>
          <th>价格版本</th>
          <th>协议状态</th>
          <th>路由策略</th>
          <th>操作</th>
        </tr>
      </thead>
      <tbody>
        {loading ? (
          <tr>
            <td colSpan={7}>正在加载映射。</td>
          </tr>
        ) : (
          associations.map((association) => {
            const model = models.find((item) => item.id === association.canonical_model_id);
            const channel = channels.find((item) => item.id === association.channel_id);
            const protocolStatus = channel ? channelProtocolStatus(channel, enabledProviderKeyChannelIds.has(channel.id)) : null;

            return (
              <tr key={association.id}>
                <td>
                  <strong>{safeDisplayText(model?.model_key ?? association.canonical_model_id)}</strong>
                  <span>{safeShortId(association.id)}</span>
                </td>
                <td>
                  <strong>{safeDisplayText(channel?.name ?? association.channel_tag ?? association.model_pattern ?? "-")}</strong>
                  <span>{association.channel_id ? safeShortId(association.channel_id) : statusLabel(association.association_type)}</span>
                </td>
                <td>{safeDisplayText(association.upstream_model_name ?? model?.model_key ?? "-")}</td>
                <td>{safeDisplayText(selectedPriceVersionLabel(model, priceVersions))}</td>
                <td>
                  {channel ? (
                    <>
                      <StatusChip tone={protocolStatus?.status === "config-needed" ? "warn" : "neutral"}>
                        {safeDisplayText(protocolStatus?.status ?? "unknown")}
                      </StatusChip>
                      <span>{channelProtocolLabel(channel.protocol_mode)}</span>
                      <span>{safeDisplayText(protocolStatus?.detail ?? "-")}</span>
                    </>
                  ) : (
                    <span>{association.channel_tag ? "按 tag 选择，等待 dry-run 解析协议" : "需要 channel 或 channel tag"}</span>
                  )}
                </td>
                <td>
                  <StatusChip tone={association.status === "enabled" ? "good" : "warn"}>{statusLabel(association.status)}</StatusChip>
                  <span>优先级 {association.priority}</span>
                  <span>回退 {yesNo(association.fallback_allowed)}</span>
                </td>
                <td>
                  <div className="action-row">
                    <ActionButton
                      disabled={busyId === association.id || association.status === "enabled" || association.status === "deleted"}
                      icon={<RotateCcw aria-hidden="true" size={15} />}
                      onClick={() => void onStatus(association, "enabled")}
                      variant="table"
                    >
                      启用
                    </ActionButton>
                    <ActionButton
                      disabled={busyId === association.id || association.status === "disabled" || association.status === "deleted"}
                      icon={<ShieldOff aria-hidden="true" size={15} />}
                      onClick={() => void onStatus(association, "disabled")}
                      variant="table"
                    >
                      停用
                    </ActionButton>
                    <ActionButton icon={<Search aria-hidden="true" size={15} />} onClick={() => onDryRun(association)} variant="table">
                      Dry-run
                    </ActionButton>
                  </div>
                </td>
              </tr>
            );
          })
        )}
      </tbody>
    </DataTable>
  );
}

function buildVisibilityMatrix({
  associations,
  channels,
  key,
  models,
  profile,
  providerKeys,
}: {
  associations: ModelAssociation[];
  channels: Channel[];
  key: VirtualKey | null;
  models: CanonicalModel[];
  profile: ApiKeyProfile | null;
  providerKeys: ProviderKey[];
}): VisibilityMatrixRow[] {
  const allowedModels = stringSet(profile?.allowed_models);
  const deniedModels = stringSet(profile?.denied_models);
  const allowedChannelTags = stringSet(profile?.allowed_channel_tags);
  const blockedProviderIds = stringSet(profile?.blocked_provider_ids);
  const aliasesByTarget = aliasesForTargets(profile?.model_aliases);
  const enabledProviderKeyChannelIds = new Set(
    providerKeys.filter((providerKey) => providerKey.status === "enabled").map((providerKey) => providerKey.channel_id),
  );

  return models.map((model) => {
    const aliases = aliasesByTarget.get(model.model_key) ?? [];
    const requestedModel = aliases[0] ?? model.model_key;
    const denied = deniedModels.has(model.model_key) || aliases.some((alias) => deniedModels.has(alias));
    const profileAllowed = allowedModels.size === 0 || allowedModels.has(model.model_key) || aliases.some((alias) => allowedModels.has(alias));
    const keyAllowed = !key || key.status === "active";
    const modelAvailable = model.status === "active" && model.visibility === "public";
    const allowed = Boolean(profile && profile.status === "active" && keyAllowed && profileAllowed && !denied);
    const matchingAssociations = associations.filter((association) => association.canonical_model_id === model.id);
    const associationDetails = matchingAssociations.map((association) =>
      associationRouteDetail({ allowedChannelTags, association, blockedProviderIds, channels, enabledProviderKeyChannelIds }),
    );
    const candidate = associationDetails.find((detail) => detail.routable)?.association ?? null;
    const reasons = modelVisibilityReasons({
      allowed,
      associationDetails,
      denied,
      key,
      model,
      profile,
      profileAllowed,
    });

    return {
      alias: aliases.length > 0 ? aliases.slice(0, 3).join(", ") : "-",
      allowed,
      blockedProviders:
        blockedProviderIds.size > 0
          ? summarizeList(
              associationDetails
                .filter((detail) => detail.blockedProviderId)
                .map((detail) => detail.blockedProviderId)
                .filter((providerId): providerId is string => Boolean(providerId)),
            )
          : "-",
      candidateAssociation: candidate,
      channelTags: summarizeList(associationDetails.flatMap((detail) => detail.tags)),
      denied,
      model,
      protocolState: summarizeList(associationDetails.map((detail) => detail.protocolState)),
      reasons,
      requestedModel,
      routable: allowed && modelAvailable && candidate !== null,
    };
  });
}

function associationRouteDetail({
  allowedChannelTags,
  association,
  blockedProviderIds,
  channels,
  enabledProviderKeyChannelIds,
}: {
  allowedChannelTags: Set<string>;
  association: ModelAssociation;
  blockedProviderIds: Set<string>;
  channels: Channel[];
  enabledProviderKeyChannelIds: Set<string>;
}): {
  association: ModelAssociation;
  blockedProviderId: string | null;
  channel: Channel | null;
  protocolState: string;
  routable: boolean;
  tags: string[];
} {
  const channel = association.channel_id ? channels.find((item) => item.id === association.channel_id) ?? null : null;
  const tags = uniqueValues([association.channel_tag, ...jsonStringArray(channel?.tags)].filter((tag): tag is string => Boolean(tag)));
  const tagAllowed = allowedChannelTags.size === 0 || tags.some((tag) => allowedChannelTags.has(tag));
  const providerBlocked = channel ? blockedProviderIds.has(channel.provider_id) : false;
  const channelEnabled = !channel || channel.status === "enabled";
  const providerKeyAvailable = !channel || enabledProviderKeyChannelIds.has(channel.id);
  const protocolStatus = channel
    ? channelProtocolStatus(channel, providerKeyAvailable)
    : { detail: "按 tag 选择，等待 dry-run 解析协议", status: "unknown" };

  return {
    association,
    blockedProviderId: providerBlocked ? channel?.provider_id ?? null : null,
    channel,
    protocolState: channel
      ? `${channelProtocolLabel(channel.protocol_mode)} / ${protocolStatus.status}`
      : protocolStatus.detail,
    routable: tagAllowed && !providerBlocked && channelEnabled && providerKeyAvailable,
    tags,
  };
}

function modelVisibilityReasons({
  allowed,
  associationDetails,
  denied,
  key,
  model,
  profile,
  profileAllowed,
}: {
  allowed: boolean;
  associationDetails: ReturnType<typeof associationRouteDetail>[];
  denied: boolean;
  key: VirtualKey | null;
  model: CanonicalModel;
  profile: ApiKeyProfile | null;
  profileAllowed: boolean;
}): string[] {
  const reasons: string[] = [];

  if (!profile) {
    reasons.push("选择 profile 或带默认 profile 的 API key");
  } else if (profile.status !== "active") {
    reasons.push("profile 未启用");
  }

  if (key && key.status !== "active") {
    reasons.push("API key 未启用");
  }

  if (model.status !== "active") {
    reasons.push("模型未启用");
  }

  if (model.visibility !== "public") {
    reasons.push("模型不是 public");
  }

  if (!profileAllowed) {
    reasons.push("allowed_models 未包含该模型或别名");
  }

  if (denied) {
    reasons.push("denied_models 阻止该模型或别名");
  }

  if (associationDetails.length === 0) {
    reasons.push("没有启用模型映射");
  }

  if (associationDetails.some((detail) => detail.blockedProviderId)) {
    reasons.push("provider 被 profile 阻止");
  }

  if (associationDetails.some((detail) => detail.channel && detail.channel.status !== "enabled")) {
    reasons.push("通道未启用");
  }

  if (associationDetails.some((detail) => detail.channel && !detail.routable && !detail.blockedProviderId)) {
    reasons.push("channel tag 或 provider key 不满足路由条件");
  }

  if (associationDetails.some((detail) => detail.protocolState.includes("config-needed"))) {
    reasons.push("OpenAI-compatible 通道缺少 enabled provider key");
  }

  if (associationDetails.some((detail) => detail.protocolState.includes("mockable"))) {
    reasons.push("非 OpenAI 协议当前为 mockable/contract-ready");
  }

  if (allowed && reasons.length === 0) {
    reasons.push("可见且存在可路由候选");
  }

  return reasons;
}

function aliasesForTargets(value: JsonValue | undefined): Map<string, string[]> {
  const aliases = new Map<string, string[]>();

  if (!isJsonObject(value)) {
    return aliases;
  }

  for (const [alias, target] of Object.entries(value)) {
    if (typeof target !== "string" || target.trim().length === 0) {
      continue;
    }

    const group = aliases.get(target) ?? [];
    group.push(alias);
    aliases.set(target, group);
  }

  return aliases;
}

function jsonStringArray(value: JsonValue | undefined): string[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value.filter((item): item is string => typeof item === "string" && item.trim().length > 0);
}

function isJsonObject(value: JsonValue | undefined): value is Record<string, JsonValue> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function summarizeList(values: string[]): string {
  const unique = uniqueValues(values.filter((value) => value.trim().length > 0));

  if (unique.length === 0) {
    return "-";
  }

  return unique.length > 3 ? `${unique.slice(0, 3).join(", ")} +${unique.length - 3}` : unique.join(", ");
}

function uniqueValues(values: string[]): string[] {
  return [...new Set(values)];
}

function stringSet(value: JsonValue | undefined): Set<string> {
  if (!Array.isArray(value)) {
    return new Set();
  }

  return new Set(value.filter((item): item is string => typeof item === "string" && item.trim().length > 0));
}

function yesNo(value: boolean): string {
  return value ? "是" : "否";
}

export default RoutingPage;
