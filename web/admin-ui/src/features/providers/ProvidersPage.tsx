import { FormEvent, useEffect, useState } from "react";
import {
  type Channel,
  type ChannelManualTestRequest,
  type ChannelManualTestResponse,
  type ChannelStatus,
  createChannel,
  createProvider,
  deleteChannel,
  deleteProvider,
  dryRunChannelManualTest,
  getProviderHealthSummary,
  type HealthSummary,
  type HealthSummaryChannel,
  type HealthSummaryRecentStats,
  type JsonObject,
  type JsonValue,
  listChannels,
  listRequestLogs,
  listProviderKeys,
  listProviders,
  patchChannel,
  patchProvider,
  patchProviderKey,
  type ProviderKey,
  requestProviderKeyRecovery,
  type Provider,
  type ProviderStatus,
  type RequestLogSummary,
} from "../../api/client";
import {
  StateChip,
  errorMessage,
  fieldValue,
  formatStatus,
  jsonSize,
  safeFieldValue,
  sanitizeDisplayJson,
} from "../../components/adminUtils";
import { Copy, Edit3, Plus, RefreshCw, Save, Search, ShieldOff, Trash2 } from "../../components/icons";
import { formatDateTime } from "../../lib/format";
import {
  CHANNEL_PROTOCOL_OPTIONS,
  channelReadiness,
  channelProtocolLabel,
  channelProtocolStatus,
  channelProtocolValue,
  isUnsafeJsonValidationError,
  jsonSummaryKeys,
  modelMappingOptions,
  optionalString,
  parseAdvancedJsonArray,
  parseAdvancedJsonObject,
  providerMetadata,
  providerKeyProbeSummary,
  providerName,
  safeEndpoint,
  safeShortId,
} from "./providerPolicyUtils";

type ProviderForm = {
  baseUrl: string;
  code: string;
  metadata: string;
  name: string;
  providerType: string;
};

type ChannelForm = {
  endpoint: string;
  modelMappings: string;
  name: string;
  probePolicy: string;
  protocolMode: string;
  providerId: string;
  requestOverrides: string;
  tags: string;
  timeoutPolicy: string;
};

type ChannelManualTestForm = {
  requestedModel: string;
  upstreamModel: string;
};

type ProviderJsonPatchForm = {
  metadata: string;
  providerId: string;
};

type ChannelJsonPatchForm = {
  channelId: string;
  modelMappings: string;
  probePolicy: string;
  requestOverrides: string;
  tags: string;
  timeoutPolicy: string;
};

type ChannelHealthMonitorState = {
  error: string | null;
  loading: boolean;
  requestLogs: RequestLogSummary[];
  summary: HealthSummary | null;
};

type ChannelHealthRow = {
  avgLatency: string;
  channelId: string;
  channelName: string;
  errorCode: string;
  failures: number;
  healthScore: string;
  keyId: string | null;
  keyLabel: string;
  model: string;
  nextAction: string;
  nextProbe: string;
  probeSource: string;
  providerId: string;
  providerName: string;
  status: string;
  successRate: string;
};

type FailureTopRow = {
  count: number;
  label: string;
  scope: string;
};

type RecoverySuggestionAction =
  | "channel_enable"
  | "channel_test"
  | "key_disable"
  | "key_enable"
  | "key_recovery_probe"
  | "provider_enable";

type RecoverySuggestion = {
  action: RecoverySuggestionAction | null;
  actionLabel: string;
  channelId: string;
  keyId?: string;
  nextStep: string;
  providerId: string;
  reason: string;
  status: string;
  title: string;
};

const defaultProviderForm: ProviderForm = {
  baseUrl: "",
  code: "",
  metadata: "{}",
  name: "",
  providerType: "",
};
const defaultChannelForm: ChannelForm = {
  endpoint: "",
  modelMappings: "{}",
  name: "",
  probePolicy: "{}",
  protocolMode: "openai",
  providerId: "",
  requestOverrides: "[]",
  tags: "[]",
  timeoutPolicy: "{}",
};
const defaultChannelManualTestForm: ChannelManualTestForm = {
  requestedModel: "",
  upstreamModel: "",
};
const defaultProviderJsonPatchForm: ProviderJsonPatchForm = {
  metadata: "",
  providerId: "",
};
const defaultChannelJsonPatchForm: ChannelJsonPatchForm = {
  channelId: "",
  modelMappings: "",
  probePolicy: "",
  requestOverrides: "",
  tags: "",
  timeoutPolicy: "",
};

type ProvidersPageProps = {
  canManageProviders: boolean;
  canRequestProviderKeyRecovery: boolean;
  canRunManualTest: boolean;
  createProviderRequestId?: number;
};

export function ProvidersPage({
  canManageProviders,
  canRequestProviderKeyRecovery,
  canRunManualTest,
  createProviderRequestId,
}: ProvidersPageProps) {
  const [busyId, setBusyId] = useState<string | null>(null);
  const [channelForm, setChannelForm] = useState<ChannelForm>(defaultChannelForm);
  const [channels, setChannels] = useState<Channel[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [keyInventoryNote, setKeyInventoryNote] = useState<string | null>(null);
  const [keyRecoveryBusyId, setKeyRecoveryBusyId] = useState<string | null>(null);
  const [healthMonitor, setHealthMonitor] = useState<ChannelHealthMonitorState>({
    error: null,
    loading: true,
    requestLogs: [],
    summary: null,
  });
  const [loading, setLoading] = useState(true);
  const [manualBusyId, setManualBusyId] = useState<string | null>(null);
  const [manualError, setManualError] = useState<string | null>(null);
  const [manualForms, setManualForms] = useState<Record<string, ChannelManualTestForm>>({});
  const [manualResult, setManualResult] = useState<{
    channelId: string;
    result: ChannelManualTestResponse;
  } | null>(null);
  const [editingChannelId, setEditingChannelId] = useState<string | null>(null);
  const [editingProviderId, setEditingProviderId] = useState<string | null>(null);
  const [openAdvancedJsonDialog, setOpenAdvancedJsonDialog] = useState(false);
  const [openChannelDialog, setOpenChannelDialog] = useState(false);
  const [openProviderDialog, setOpenProviderDialog] = useState(false);
  const [channelJsonPatchForm, setChannelJsonPatchForm] = useState<ChannelJsonPatchForm>(defaultChannelJsonPatchForm);
  const [providerJsonPatchForm, setProviderJsonPatchForm] =
    useState<ProviderJsonPatchForm>(defaultProviderJsonPatchForm);
  const [providerForm, setProviderForm] = useState<ProviderForm>(defaultProviderForm);
  const [providerKeys, setProviderKeys] = useState<ProviderKey[]>([]);
  const [providers, setProviders] = useState<Provider[]>([]);
  const [recoverySuggestion, setRecoverySuggestion] = useState<RecoverySuggestion | null>(null);
  const [success, setSuccess] = useState<string | null>(null);

  useEffect(() => {
    if (!createProviderRequestId || !canManageProviders) {
      return;
    }
    setEditingProviderId(null);
    setProviderForm(defaultProviderForm);
    setOpenProviderDialog(true);
  }, [canManageProviders, createProviderRequestId]);

  async function loadInventory() {
    setError(null);
    setLoading(true);

    try {
      const [nextProviders, nextChannels, nextProviderKeys] = await Promise.allSettled([
        listProviders(),
        listChannels(),
        listProviderKeys(),
      ]);

      if (nextProviders.status === "rejected") {
        throw nextProviders.reason;
      }

      if (nextChannels.status === "rejected") {
        throw nextChannels.reason;
      }

      setProviders(nextProviders.value);
      setChannels(nextChannels.value);

      if (nextProviderKeys.status === "fulfilled") {
        setProviderKeys(nextProviderKeys.value);
        setKeyInventoryNote(null);
      } else {
        setProviderKeys([]);
        setKeyInventoryNote("供应商密钥读取不可用，工作流已降级为配置占位。");
      }
    } catch (requestError) {
      setError(errorMessage(requestError));
      setProviders([]);
      setChannels([]);
      setProviderKeys([]);
    } finally {
      setLoading(false);
    }
  }

  async function loadHealthMonitor() {
    setHealthMonitor((current) => ({ ...current, error: null, loading: true }));

    try {
      const [summaryResult, requestLogResult] = await Promise.allSettled([
        getProviderHealthSummary({ sample_limit: 500, window_minutes: 60 }),
        listRequestLogs({ limit: 200 }),
      ]);

      if (summaryResult.status === "rejected") {
        throw summaryResult.reason;
      }

      setHealthMonitor({
        error: requestLogResult.status === "rejected" ? "近期请求日志不可用，延迟和失败 TopN 使用占位。" : null,
        loading: false,
        requestLogs: requestLogResult.status === "fulfilled" ? requestLogResult.value : [],
        summary: summaryResult.value,
      });
    } catch (requestError) {
      setHealthMonitor({
        error: errorMessage(requestError),
        loading: false,
        requestLogs: [],
        summary: null,
      });
    }
  }

  useEffect(() => {
    void loadInventory();
    void loadHealthMonitor();
  }, []);

  function updateProvider(field: keyof ProviderForm, value: string) {
    setProviderForm((current) => ({ ...current, [field]: value }));
  }

  function updateChannel(field: keyof ChannelForm, value: string) {
    setChannelForm((current) => ({ ...current, [field]: value }));
  }

  function updateManualTestForm(channelId: string, field: keyof ChannelManualTestForm, value: string) {
    setManualForms((current) => ({
      ...current,
      [channelId]: {
        ...(current[channelId] ?? defaultChannelManualTestForm),
        [field]: value,
      },
    }));
  }

  function updateProviderJsonPatch(field: keyof ProviderJsonPatchForm, value: string) {
    setProviderJsonPatchForm((current) => ({ ...current, [field]: value }));
  }

  function updateChannelJsonPatch(field: keyof ChannelJsonPatchForm, value: string) {
    setChannelJsonPatchForm((current) => ({ ...current, [field]: value }));
  }

  async function handleSubmitProvider(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setSuccess(null);

    try {
      const metadata = parseAdvancedJsonObject(providerForm.metadata, "供应商 metadata JSON");
      const request = {
        base_url: optionalString(providerForm.baseUrl),
        code: providerForm.code.trim(),
        metadata,
        name: providerForm.name.trim(),
        provider_type: optionalString(providerForm.providerType),
      };

      const saved = editingProviderId ? await patchProvider(editingProviderId, request) : await createProvider(request);
      setProviderForm(defaultProviderForm);
      setEditingProviderId(null);
      setSuccess(editingProviderId ? `${saved.name} 已保存。` : "供应商已创建。");
      setOpenProviderDialog(false);
      await loadInventory();
    } catch (requestError) {
      if (isUnsafeJsonValidationError(requestError)) {
        setProviderForm((current) => ({ ...current, metadata: "{}" }));
      }
      setError(`${errorMessage(requestError)} 下一步：检查 code 是否唯一、URL 是否允许，以及 metadata 是否为对象。`);
    }
  }

  async function handleProviderStatus(provider: Provider, status: ProviderStatus) {
    setBusyId(provider.id);
    setError(null);
    setSuccess(null);

    try {
      const updated = status === "deleted" ? await deleteProvider(provider.id) : await patchProvider(provider.id, { status });
      setProviders((current) => current.map((item) => (item.id === updated.id ? updated : item)));
      setSuccess(`${provider.name} 已${statusActionLabel(status)}。`);
    } catch (requestError) {
      setError(`${errorMessage(requestError)} 下一步：确认当前账号有 provider 管理权限，且该 provider 没有后端限制。`);
    } finally {
      setBusyId(null);
    }
  }

  async function handleSubmitChannel(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setSuccess(null);

    const providerId = channelForm.providerId.trim();

    try {
      const modelMappings = parseAdvancedJsonObject(channelForm.modelMappings, "通道 model_mappings JSON");
      const tags = parseAdvancedJsonArray(channelForm.tags, "通道 tags JSON");
      const requestOverrides = parseAdvancedJsonArray(
        channelForm.requestOverrides,
        "通道 request_overrides JSON",
      );
      const probePolicy = parseAdvancedJsonObject(channelForm.probePolicy, "通道 probe_policy JSON");
      const timeoutPolicy = parseAdvancedJsonObject(channelForm.timeoutPolicy, "通道 timeout_policy JSON");

      const request = {
        endpoint: channelForm.endpoint.trim(),
        model_mappings: modelMappings,
        name: channelForm.name.trim(),
        probe_policy: probePolicy,
        protocol: channelProtocolValue(channelForm.protocolMode),
        protocol_mode: channelProtocolValue(channelForm.protocolMode),
        provider_id: providerId,
        request_overrides: requestOverrides,
        tags,
        timeout_policy: timeoutPolicy,
      };
      const saved = editingChannelId ? await patchChannel(editingChannelId, request) : await createChannel(request);
      setChannelForm({ ...defaultChannelForm, providerId });
      setEditingChannelId(null);
      setSuccess(editingChannelId ? `${saved.name} 已保存。` : "通道已创建。");
      setOpenChannelDialog(false);
      await loadInventory();
    } catch (requestError) {
      if (isUnsafeJsonValidationError(requestError)) {
        setChannelForm((current) => ({
          ...current,
          modelMappings: "{}",
          probePolicy: "{}",
          requestOverrides: "[]",
          tags: "[]",
          timeoutPolicy: "{}",
        }));
      }
      setError(`${errorMessage(requestError)} 下一步：确认 provider ID 存在、endpoint 是允许的 HTTP(S) URL，JSON 字段类型正确。`);
    }
  }

  async function handlePatchProviderJson(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setSuccess(null);

    const providerId = providerJsonPatchForm.providerId.trim();

    if (!providerId) {
      setError("供应商 ID 为必填项。");
      return;
    }

    if (!providerJsonPatchForm.metadata.trim()) {
      setError("供应商 metadata JSON 为必填项。");
      return;
    }

    try {
      const metadata = parseAdvancedJsonObject(providerJsonPatchForm.metadata, "供应商补丁 metadata JSON");
      const updated = await patchProvider(providerId, { metadata });
      setProviders((current) => current.map((item) => (item.id === updated.id ? updated : item)));
      setSuccess(`${updated.name} JSON 策略已保存。`);
      setOpenAdvancedJsonDialog(false);
    } catch (requestError) {
      if (isUnsafeJsonValidationError(requestError)) {
        setProviderJsonPatchForm((current) => ({ ...current, metadata: "" }));
      }
      setError(errorMessage(requestError));
    }
  }

  async function handlePatchChannelJson(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setSuccess(null);

    const channelId = channelJsonPatchForm.channelId.trim();

    if (!channelId) {
      setError("通道 ID 为必填项。");
      return;
    }

    try {
      const request: {
        model_mappings?: JsonObject;
        probe_policy?: JsonObject;
        request_overrides?: JsonValue[];
        tags?: JsonValue[];
        timeout_policy?: JsonObject;
      } = {};

      if (channelJsonPatchForm.modelMappings.trim()) {
        request.model_mappings = parseAdvancedJsonObject(
          channelJsonPatchForm.modelMappings,
          "补丁 model_mappings JSON",
        );
      }
      if (channelJsonPatchForm.tags.trim()) {
        request.tags = parseAdvancedJsonArray(channelJsonPatchForm.tags, "补丁 tags JSON");
      }
      if (channelJsonPatchForm.requestOverrides.trim()) {
        request.request_overrides = parseAdvancedJsonArray(
          channelJsonPatchForm.requestOverrides,
          "补丁 request_overrides JSON",
        );
      }
      if (channelJsonPatchForm.probePolicy.trim()) {
        request.probe_policy = parseAdvancedJsonObject(
          channelJsonPatchForm.probePolicy,
          "补丁 probe_policy JSON",
        );
      }
      if (channelJsonPatchForm.timeoutPolicy.trim()) {
        request.timeout_policy = parseAdvancedJsonObject(
          channelJsonPatchForm.timeoutPolicy,
          "补丁 timeout_policy JSON",
        );
      }

      if (Object.keys(request).length === 0) {
        setError("至少需要填写一个通道 JSON 字段。");
        return;
      }

      const updated = await patchChannel(channelId, request);
      setChannels((current) => current.map((item) => (item.id === updated.id ? updated : item)));
      setSuccess(`${updated.name} JSON 策略已保存。`);
      setOpenAdvancedJsonDialog(false);
    } catch (requestError) {
      if (isUnsafeJsonValidationError(requestError)) {
        setChannelJsonPatchForm((current) => ({
          ...current,
          modelMappings: "",
          probePolicy: "",
          requestOverrides: "",
          tags: "",
          timeoutPolicy: "",
        }));
      }
      setError(errorMessage(requestError));
    }
  }

  async function handleChannelStatus(channel: Channel, status: ChannelStatus) {
    setBusyId(channel.id);
    setError(null);
    setSuccess(null);

    try {
      const updated = status === "deleted" ? await deleteChannel(channel.id) : await patchChannel(channel.id, { status });
      setChannels((current) => current.map((item) => (item.id === updated.id ? updated : item)));
      setSuccess(`${channel.name} 已${statusActionLabel(status)}。`);
    } catch (requestError) {
      setError(`${errorMessage(requestError)} 下一步：确认当前账号有 channel 管理权限，并检查该通道是否仍存在。`);
    } finally {
      setBusyId(null);
    }
  }

  async function handleChannelManualTest(channel: Channel, event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setManualBusyId(channel.id);
    setManualError(null);
    setSuccess(null);

    const form = manualForms[channel.id] ?? defaultChannelManualTestForm;
    const requestedModel = form.requestedModel.trim();
    const upstreamModel = form.upstreamModel.trim();

    if (!requestedModel) {
      setManualError("请求模型为必填项。");
      setManualBusyId(null);
      return;
    }

    const request: ChannelManualTestRequest = {
      dry_run: true,
      model: requestedModel,
      upstream_model_name: upstreamModel || undefined,
    };

    try {
      const result = await dryRunChannelManualTest(channel.id, request);
      setManualResult({ channelId: channel.id, result });
      setSuccess(`${channel.name} 手动测试 dry-run 已就绪；未调用上游、未使用 provider key secret。`);
    } catch (requestError) {
      setManualError(`${errorMessage(requestError)} 下一步：选择已配置映射的请求模型，或先保存 channel 的 model_mappings。`);
      setManualResult(null);
    } finally {
      setManualBusyId(null);
    }
  }

  async function handleSuggestedChannelTest(channel: Channel) {
    setManualBusyId(channel.id);
    setManualError(null);
    setSuccess(null);

    const modelOptions = modelMappingOptions(channel);
    const requestedModel = modelOptions.requested[0];

    if (!requestedModel) {
      setManualError("建议测试需要至少一个 model mapping。下一步：保存 channel 的 model_mappings 后再确认测试。");
      setManualBusyId(null);
      return;
    }

    try {
      const result = await dryRunChannelManualTest(channel.id, {
        dry_run: true,
        model: requestedModel,
        upstream_model_name: modelOptions.upstream[0],
      });
      setManualResult({ channelId: channel.id, result });
      setSuccess(`${channel.name} 建议测试 dry-run 已就绪；未调用上游、未使用 provider key secret。`);
    } catch (requestError) {
      setManualError(`${errorMessage(requestError)} 下一步：检查 model mapping 或改用通道表格手动测试。`);
      setManualResult(null);
    } finally {
      setManualBusyId(null);
    }
  }

  function openProviderCreateDialog() {
    setProviderForm(defaultProviderForm);
    setEditingProviderId(null);
    setOpenProviderDialog(true);
  }

  function openProviderEditDialog(provider: Provider) {
    setProviderForm(providerToForm(provider));
    setEditingProviderId(provider.id);
    setOpenProviderDialog(true);
  }

  function closeProviderDialog() {
    setOpenProviderDialog(false);
    setEditingProviderId(null);
    setProviderForm(defaultProviderForm);
  }

  function openChannelCreateDialog(providerId = "") {
    setChannelForm({ ...defaultChannelForm, providerId });
    setEditingChannelId(null);
    setOpenChannelDialog(true);
  }

  function openChannelEditDialog(channel: Channel) {
    setChannelForm(channelToForm(channel));
    setEditingChannelId(channel.id);
    setOpenChannelDialog(true);
  }

  function openChannelCopyDialog(channel: Channel) {
    setChannelForm({
      ...channelToForm(channel),
      name: `${channel.name} copy`,
    });
    setEditingChannelId(null);
    setOpenChannelDialog(true);
  }

  function closeChannelDialog() {
    setOpenChannelDialog(false);
    setEditingChannelId(null);
    setChannelForm(defaultChannelForm);
  }

  async function handleProviderKeyRecovery(key: ProviderKey) {
    setKeyRecoveryBusyId(key.id);
    setError(null);
    setSuccess(null);

    try {
      const response = await requestProviderKeyRecovery(key.id, {
        reason: "operator requested recovery from provider workflow",
        target_status: "recovery_probe",
      });
      setProviderKeys((current) =>
        current.map((currentKey) =>
          currentKey.id === response.provider_key.id ? response.provider_key : currentKey,
        ),
      );
      setSuccess(`${key.key_alias} 已进入恢复探针。`);
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setKeyRecoveryBusyId(null);
    }
  }

  async function handleProviderKeyStatus(key: ProviderKey, status: ProviderKey["status"]) {
    setKeyRecoveryBusyId(key.id);
    setError(null);
    setSuccess(null);

    try {
      const updated = await patchProviderKey(key.id, { status });
      setProviderKeys((current) => current.map((item) => (item.id === updated.id ? updated : item)));
      setSuccess(`${key.key_alias} 已${status === "enabled" ? "启用" : "禁用"}。`);
    } catch (requestError) {
      setError(`${errorMessage(requestError)} 下一步：确认当前账号有 provider key 管理权限。`);
    } finally {
      setKeyRecoveryBusyId(null);
    }
  }

  async function executeRecoverySuggestion(suggestion: RecoverySuggestion) {
    const provider = providers.find((item) => item.id === suggestion.providerId);
    const channel = channels.find((item) => item.id === suggestion.channelId);
    const key = suggestion.keyId ? providerKeys.find((item) => item.id === suggestion.keyId) : undefined;

    setRecoverySuggestion(null);

    if (!suggestion.action) {
      return;
    }

    if (suggestion.action === "provider_enable" && provider) {
      await handleProviderStatus(provider, "enabled");
      return;
    }

    if (suggestion.action === "channel_enable" && channel) {
      await handleChannelStatus(channel, "enabled");
      return;
    }

    if (suggestion.action === "channel_test" && channel) {
      await handleSuggestedChannelTest(channel);
      return;
    }

    if (suggestion.action === "key_disable" && key) {
      await handleProviderKeyStatus(key, "manual_disabled");
      return;
    }

    if (suggestion.action === "key_enable" && key) {
      await handleProviderKeyStatus(key, "enabled");
      return;
    }

    if (suggestion.action === "key_recovery_probe" && key) {
      await handleProviderKeyRecovery(key);
    }
  }

  return (
    <div className="admin-page" aria-label="供应商与通道">
      <section className="admin-panel" aria-label="供应商库存控制">
        <div className="section-heading">
          <div>
            <h2>供应商库存</h2>
            <p>
              面向 New API 分发的上游通道管理。可调用路由需要已启用的供应商、通道、供应商密钥、模型关联和用户档案。
            </p>
          </div>
          <div className="action-row">
            {canManageProviders ? (
              <>
                <button className="secondary-button" type="button" onClick={() => openChannelCreateDialog()}>
                  <Plus aria-hidden="true" size={17} />
                  创建通道
                </button>
                <button className="secondary-button" type="button" onClick={openProviderCreateDialog}>
                  <Plus aria-hidden="true" size={17} />
                  创建供应商
                </button>
                <button className="secondary-button" type="button" onClick={() => setOpenAdvancedJsonDialog(true)}>
                  高级 JSON
                </button>
              </>
            ) : null}
            <button className="secondary-button" type="button" onClick={() => void loadInventory()} disabled={loading}>
              <RefreshCw aria-hidden="true" size={18} className={loading ? "spin" : undefined} />
              刷新
            </button>
          </div>
        </div>

        <div className="status-grid status-grid--compact" aria-label="供应商通道摘要">
          <article className="status-card">
            <div>
              <h3>通道</h3>
              <p>{channels.filter((channel) => channel.status === "enabled").length}/{channels.length} 已启用</p>
            </div>
          </article>
          <article className="status-card">
            <div>
              <h3>供应商</h3>
              <p>{providers.filter((provider) => provider.status === "enabled").length}/{providers.length} 已启用</p>
            </div>
          </article>
          <article className="status-card">
            <div>
              <h3>手动测试</h3>
              <p>{canRunManualTest ? "可执行 dry-run；不会调用上游或写入计费" : "当前角色不可用"}</p>
            </div>
          </article>
        </div>

        {error ? <p className="form-status form-status--error">{error}</p> : null}
        {manualError ? <p className="form-status form-status--error">{manualError}</p> : null}
        {keyInventoryNote ? <p className="form-status">{keyInventoryNote}</p> : null}
        {success ? <p className="form-status form-status--success">{success}</p> : null}
      </section>

      <ChannelHealthMonitor
        channels={channels}
        healthMonitor={healthMonitor}
        providerKeys={providerKeys}
        providers={providers}
        onRefresh={() => void loadHealthMonitor()}
      />

      <ProviderChannelWorkflow
        canManageProviders={canManageProviders}
        canRequestProviderKeyRecovery={canRequestProviderKeyRecovery}
        canRunManualTest={canRunManualTest}
        channels={channels}
        keyRecoveryBusyId={keyRecoveryBusyId}
        loading={loading}
        providerKeys={providerKeys}
        providers={providers}
        onReviewRecoverySuggestion={setRecoverySuggestion}
      />

      <ChannelTable
        busyId={busyId}
        canManageProviders={canManageProviders}
        canRunManualTest={canRunManualTest}
        channels={channels}
        loading={loading}
        manualBusyId={manualBusyId}
        manualForms={manualForms}
        providerKeys={providerKeys}
        providers={providers}
        onCopyChannel={openChannelCopyDialog}
        onEditChannel={openChannelEditDialog}
        onManualFormChange={updateManualTestForm}
        onManualTest={handleChannelManualTest}
        onStatus={handleChannelStatus}
      />

      <ProviderTable
        busyId={busyId}
        canManageProviders={canManageProviders}
        channels={channels}
        loading={loading}
        providers={providers}
        onCreateChannel={openChannelCreateDialog}
        onEditProvider={openProviderEditDialog}
        onStatus={handleProviderStatus}
      />

      {canManageProviders && openProviderDialog ? (
        <div className="wizard-overlay" role="dialog" aria-modal="true" aria-label={editingProviderId ? "编辑供应商对话框" : "创建供应商对话框"}>
          <div className="wizard-panel">
            <div className="wizard-header">
              <div>
                <span>上游供应商</span>
                <h3>{editingProviderId ? "编辑供应商" : "创建供应商"}</h3>
                <p>添加或更新上游账号 metadata。供应商凭据在供应商密钥中单独创建，表单不会接收 secret。</p>
              </div>
              <button className="secondary-button" type="button" onClick={closeProviderDialog}>
                关闭
              </button>
            </div>

            <form className="provider-form wizard-body" id="create-provider" onSubmit={handleSubmitProvider}>
              <div className="form-grid form-grid--three">
                <label className="field">
                  供应商 code
                  <input
                    value={providerForm.code}
                    onChange={(event) => updateProvider("code", event.currentTarget.value)}
                    placeholder="openai"
                    required
                  />
                </label>
                <label className="field">
                  供应商名称
                  <input
                    value={providerForm.name}
                    onChange={(event) => updateProvider("name", event.currentTarget.value)}
                    placeholder="OpenAI"
                    required
                  />
                </label>
                <label className="field">
                  供应商类型
                  <input
                    value={providerForm.providerType}
                    onChange={(event) => updateProvider("providerType", event.currentTarget.value)}
                    placeholder="openai"
                  />
                </label>
                <label className="field">
                  供应商 base URL
                  <input
                    value={providerForm.baseUrl}
                    onChange={(event) => updateProvider("baseUrl", event.currentTarget.value)}
                    placeholder="https://api.openai.com/v1"
                    type="url"
                  />
                </label>
                <label className="field field--wide">
                  供应商 metadata JSON
                  <textarea
                    value={providerForm.metadata}
                    onChange={(event) => updateProvider("metadata", event.currentTarget.value)}
                    spellCheck={false}
                  />
                </label>
              </div>

              <button className="primary-button primary-button--inline" type="submit">
                {editingProviderId ? <Save aria-hidden="true" size={17} /> : <Plus aria-hidden="true" size={17} />}
                {editingProviderId ? "保存供应商" : "创建供应商"}
              </button>
            </form>
          </div>
        </div>
      ) : null}

      {canManageProviders && openChannelDialog ? (
        <div className="wizard-overlay" role="dialog" aria-modal="true" aria-label={editingChannelId ? "编辑通道对话框" : "创建通道对话框"}>
          <div className="wizard-panel">
            <div className="wizard-header">
              <div>
                <span>分发通道</span>
                <h3>{editingChannelId ? "编辑通道" : "创建通道"}</h3>
                <p>创建或更新可调用的上游路由。复制通道会带入非密钥配置；provider key secret 不会复制或回显。</p>
              </div>
              <button className="secondary-button" type="button" onClick={closeChannelDialog}>
                关闭
              </button>
            </div>

            <form className="provider-form wizard-body" id="create-channel" onSubmit={handleSubmitChannel}>
              <div className="form-grid form-grid--three">
                <label className="field">
                  通道 provider ID
                  <input
                    list="provider-id-options"
                    value={channelForm.providerId}
                    onChange={(event) => updateChannel("providerId", event.currentTarget.value)}
                    placeholder="provider uuid"
                    required
                  />
                </label>
                <datalist id="provider-id-options">
                  {providers.map((provider) => (
                    <option key={provider.id} value={provider.id}>
                      {provider.name}
                    </option>
                  ))}
                </datalist>
                <label className="field">
                  通道名称
                  <input
                    value={channelForm.name}
                    onChange={(event) => updateChannel("name", event.currentTarget.value)}
                    placeholder="primary us-east"
                    required
                  />
                </label>
                <label className="field">
                  Protocol
                  <select
                    value={channelForm.protocolMode}
                    onChange={(event) => updateChannel("protocolMode", event.currentTarget.value)}
                    required
                  >
                    {CHANNEL_PROTOCOL_OPTIONS.map((option) => (
                      <option key={option.value} value={option.value}>
                        {option.label}
                      </option>
                    ))}
                  </select>
                  <span>{channelProtocolStatus({ protocol_mode: channelForm.protocolMode }, false).detail}</span>
                </label>
                <label className="field">
                  Endpoint / base URL
                  <input
                    value={channelForm.endpoint}
                    onChange={(event) => updateChannel("endpoint", event.currentTarget.value)}
                    placeholder="https://api.openai.com/v1"
                    required
                    type="url"
                  />
                </label>
                <label className="field field--wide">
                  通道 model_mappings JSON
                  <textarea
                    value={channelForm.modelMappings}
                    onChange={(event) => updateChannel("modelMappings", event.currentTarget.value)}
                    spellCheck={false}
                  />
                </label>
                <label className="field">
                  通道 tags JSON
                  <textarea
                    value={channelForm.tags}
                    onChange={(event) => updateChannel("tags", event.currentTarget.value)}
                    spellCheck={false}
                  />
                </label>
                <label className="field">
                  通道 request_overrides JSON
                  <textarea
                    value={channelForm.requestOverrides}
                    onChange={(event) => updateChannel("requestOverrides", event.currentTarget.value)}
                    spellCheck={false}
                  />
                </label>
                <label className="field">
                  通道 probe_policy JSON
                  <textarea
                    value={channelForm.probePolicy}
                    onChange={(event) => updateChannel("probePolicy", event.currentTarget.value)}
                    spellCheck={false}
                  />
                </label>
                <label className="field">
                  通道 timeout_policy JSON
                  <textarea
                    value={channelForm.timeoutPolicy}
                    onChange={(event) => updateChannel("timeoutPolicy", event.currentTarget.value)}
                    spellCheck={false}
                  />
                </label>
              </div>

              <button className="primary-button primary-button--inline" type="submit">
                {editingChannelId ? <Save aria-hidden="true" size={17} /> : <Plus aria-hidden="true" size={17} />}
                {editingChannelId ? "保存通道" : "创建通道"}
              </button>
            </form>
          </div>
        </div>
      ) : null}

      {canManageProviders && openAdvancedJsonDialog ? (
        <div className="wizard-overlay" role="dialog" aria-modal="true" aria-label="高级 JSON 策略对话框">
          <div className="wizard-panel">
            <div className="wizard-header">
              <div>
                <span>不含密钥的高级配置</span>
                <h3>高级 JSON 策略</h3>
                <p>在不包含密钥字段的前提下修补 metadata、映射、标签、覆盖、探测策略和超时策略。</p>
              </div>
              <button className="secondary-button" type="button" onClick={() => setOpenAdvancedJsonDialog(false)}>
                关闭
              </button>
            </div>
            <div className="wizard-body">
              <AdvancedJsonPolicyPanel
                channelForm={channelJsonPatchForm}
                channels={channels}
                providerForm={providerJsonPatchForm}
                providers={providers}
                onChannelChange={updateChannelJsonPatch}
                onChannelSubmit={handlePatchChannelJson}
                onProviderChange={updateProviderJsonPatch}
                onProviderSubmit={handlePatchProviderJson}
              />
            </div>
          </div>
        </div>
      ) : null}

      {manualResult ? (
        <ChannelManualTestResult
          hasUsableProviderKey={providerKeys.some(
            (key) => key.channel_id === manualResult.channelId && key.status === "enabled",
          )}
          result={manualResult.result}
        />
      ) : null}

      {recoverySuggestion ? (
        <RecoverySuggestionDialog
          busy={
            busyId === recoverySuggestion.providerId ||
            busyId === recoverySuggestion.channelId ||
            manualBusyId === recoverySuggestion.channelId ||
            (recoverySuggestion.keyId ? keyRecoveryBusyId === recoverySuggestion.keyId : false)
          }
          suggestion={recoverySuggestion}
          onClose={() => setRecoverySuggestion(null)}
          onConfirm={(suggestion) => void executeRecoverySuggestion(suggestion)}
        />
      ) : null}
    </div>
  );
}

function ChannelHealthMonitor({
  channels,
  healthMonitor,
  providerKeys,
  providers,
  onRefresh,
}: {
  channels: Channel[];
  healthMonitor: ChannelHealthMonitorState;
  providerKeys: ProviderKey[];
  providers: Provider[];
  onRefresh: () => void;
}) {
  const rows = channelHealthRows({
    channels,
    providerKeys,
    providers,
    requestLogs: healthMonitor.requestLogs,
    summary: healthMonitor.summary,
  });
  const failureRows = failureTopRows(healthMonitor.summary, healthMonitor.requestLogs);
  const windowLabel = healthMonitor.summary ? healthSummaryWindowLabel(healthMonitor.summary) : "60m";
  const probeStatus = healthSummaryProbeStatus(healthMonitor.summary);

  return (
    <section className="admin-panel channel-health-monitor" aria-label="通道健康监控">
      <div className="section-heading">
        <div>
          <h2>通道健康监控</h2>
          <p>按 provider / channel / model 汇总探针状态、近期延迟、错误码和下一步动作。</p>
        </div>
        <button className="secondary-button" type="button" onClick={onRefresh} disabled={healthMonitor.loading}>
          <RefreshCw aria-hidden="true" size={18} className={healthMonitor.loading ? "spin" : undefined} />
          刷新健康
        </button>
      </div>

      <div className="channel-health-summary">
        <article>
          <strong>{healthMonitor.summary?.recent_window.sample_count ?? "-"}</strong>
          <span>{windowLabel} 样本</span>
        </article>
        <article>
          <strong>{successRateText(healthMonitor.summary?.recent_window.success_rate)}</strong>
          <span>窗口成功率</span>
        </article>
        <article>
          <strong>{rows.filter((row) => row.status === "healthy").length}/{rows.length}</strong>
          <span>健康行</span>
        </article>
        <article>
          <strong>{probeStatus.statusLabel}</strong>
          <span>{probeStatus.detail}</span>
        </article>
      </div>

      {healthMonitor.error ? <p className="form-status form-status--error">{healthMonitor.error}</p> : null}

      <div className="channel-health-grid">
        <div className="health-table-wrap">
          <table className="health-table channel-health-table">
            <thead>
              <tr>
                <th>Provider / Channel</th>
                <th>Model</th>
                <th>探针状态</th>
                <th>延迟</th>
                <th>错误码</th>
                <th>失败</th>
                <th>下一步</th>
              </tr>
            </thead>
            <tbody>
              {healthMonitor.loading ? (
                <tr>
                  <td colSpan={7}>正在加载通道健康监控。</td>
                </tr>
              ) : rows.length > 0 ? (
                rows.map((row) => (
                  <tr key={`${row.channelId}:${row.model}:${row.keyId ?? "no-key"}`}>
                    <td>
                      <strong>{row.providerName}</strong>
                      <span>
                        {row.channelName} / {safeShortId(row.channelId)}
                      </span>
                    </td>
                    <td>
                      <strong>{row.model}</strong>
                      <span>{row.keyLabel}</span>
                    </td>
                    <td>
                      <StateChip status={row.status} />
                      <span>健康分 {row.healthScore}</span>
                      <span>{row.probeSource} / {row.nextProbe}</span>
                    </td>
                    <td>{row.avgLatency}</td>
                    <td>{row.errorCode}</td>
                    <td>{row.failures}</td>
                    <td>
                      <div className="channel-health-actions">
                        <span>{row.nextAction}</span>
                        <a className="table-action" href={`#provider-workflow-provider-${row.providerId}`}>
                          provider
                        </a>
                        <a className="table-action" href={`#provider-workflow-channel-${row.channelId}`}>
                          channel
                        </a>
                        {row.keyId ? (
                          <a className="table-action" href={`#provider-workflow-key-${row.keyId}`}>
                            key/probe
                          </a>
                        ) : null}
                      </div>
                    </td>
                  </tr>
                ))
              ) : (
                <tr>
                  <td colSpan={7}>
                    没有通道健康数据。下一步：创建 provider、channel 和 provider key 后再刷新。
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>

        <aside className="channel-health-failures" aria-label="失败 TopN">
          <h3>失败 TopN</h3>
          {failureRows.length > 0 ? (
            <ol>
              {failureRows.map((row) => (
                <li key={`${row.scope}:${row.label}`}>
                  <strong>{row.label}</strong>
                  <span>{row.scope} / {row.count} 次</span>
                </li>
              ))}
            </ol>
          ) : (
            <p>近期没有失败请求，或请求日志暂不可用。</p>
          )}
        </aside>
      </div>
    </section>
  );
}

function channelHealthRows({
  channels,
  providerKeys,
  providers,
  requestLogs,
  summary,
}: {
  channels: Channel[];
  providerKeys: ProviderKey[];
  providers: Provider[];
  requestLogs: RequestLogSummary[];
  summary: HealthSummary | null;
}): ChannelHealthRow[] {
  const summaryChannels = new Map((summary?.channels ?? []).map((channel) => [channel.id, channel]));
  const logsByChannelModel = groupLogsByChannelModel(requestLogs);
  const rows: ChannelHealthRow[] = [];

  for (const channel of channels) {
    const provider = providers.find((item) => item.id === channel.provider_id);
    const summaryChannel = summaryChannels.get(channel.id);
    const channelKeys = providerKeys.filter((key) => key.channel_id === channel.id && key.status !== "deleted");
    const configuredModels = modelMappingOptions(channel).requested;
    const logModels = [...logsByChannelModel.keys()]
      .filter((key) => key.startsWith(`${channel.id}::`))
      .map((key) => key.slice(channel.id.length + 2));
    const models = uniqueValues([...logModels, ...configuredModels]);
    const effectiveModels = models.length > 0 ? models : ["config-needed"];

    for (const model of effectiveModels) {
      const logs = logsByChannelModel.get(`${channel.id}::${model}`) ?? [];
      const selectedKey = selectProviderKey(channelKeys, logs);
      const lastError = latestError(logs) ?? summaryChannel?.recent.last_error?.code ?? selectedKey?.last_error_code;
      const failureCount = logs.filter((log) => log.status !== "succeeded" || log.error_code).length;
    const status = channelHealthStatus(channel, summaryChannel, selectedKey);
      const readiness = channelReadiness(channel, channelKeys);

      rows.push({
        avgLatency: latencyText(logs, summaryChannel?.recent),
        channelId: channel.id,
        channelName: safeFieldValue(channel.name),
        errorCode: safeFieldValue(lastError),
        failures: failureCount || summaryChannel?.recent.error_count || 0,
        healthScore: scoreText(summaryChannel?.health_score ?? channel.health_score),
        keyId: selectedKey?.id ?? null,
        keyLabel: readiness.keyId ? `key ${safeFieldValue(readiness.keyAlias)}` : readiness.keyAlias,
        model,
        nextAction: model === "config-needed" ? channelNextAction(status, selectedKey, model) : readiness.nextStep,
        nextProbe: channelNextProbeLabel(summary),
        probeSource: healthSummaryProbeSourceLabel(summary),
        providerId: channel.provider_id,
        providerName: safeFieldValue(provider?.name ?? providerName(channel.provider_id, providers)),
        status: readiness.status,
        successRate: successRateText(summaryChannel?.recent.success_rate),
      });
    }
  }

  return rows.sort((left, right) => right.failures - left.failures || left.providerName.localeCompare(right.providerName));
}

function groupLogsByChannelModel(requestLogs: RequestLogSummary[]): Map<string, RequestLogSummary[]> {
  const groups = new Map<string, RequestLogSummary[]>();

  for (const log of requestLogs) {
    const channelId = log.resolved_channel_id;

    if (!channelId) {
      continue;
    }

    const model = safeFieldValue(log.requested_model ?? log.upstream_model ?? "unknown-model");
    const key = `${channelId}::${model}`;
    groups.set(key, [...(groups.get(key) ?? []), log]);
  }

  return groups;
}

function failureTopRows(summary: HealthSummary | null, requestLogs: RequestLogSummary[]): FailureTopRow[] {
  const summaryRows = summary?.recent_window.error_top ?? [];

  if (summaryRows.length > 0) {
    return summaryRows.slice(0, 5).map((row) => ({
      count: row.count,
      label: safeFieldValue(row.code),
      scope: "window",
    }));
  }

  const counts = new Map<string, FailureTopRow>();

  for (const log of requestLogs) {
    if (log.status === "succeeded" && !log.error_code) {
      continue;
    }

    const label = safeFieldValue(log.error_code ?? (log.http_status ? `http_${log.http_status}` : "failed"));
    const model = safeFieldValue(log.requested_model ?? log.upstream_model ?? "unknown-model");
    const key = `${model}:${label}`;
    const current = counts.get(key);
    counts.set(key, {
      count: (current?.count ?? 0) + 1,
      label,
      scope: model,
    });
  }

  return [...counts.values()].sort((left, right) => right.count - left.count).slice(0, 5);
}

function selectProviderKey(keys: ProviderKey[], logs: RequestLogSummary[]): ProviderKey | undefined {
  const logKeyId = logs.find((log) => log.provider_key_id)?.provider_key_id;
  return keys.find((key) => key.id === logKeyId) ?? keys.find((key) => key.status === "enabled") ?? keys[0];
}

function latestError(logs: RequestLogSummary[]): string | null {
  return logs.find((log) => log.error_code)?.error_code ?? null;
}

function latencyText(logs: RequestLogSummary[], recent?: HealthSummaryRecentStats): string {
  if (typeof recent?.avg_latency_ms === "number") {
    const average = `${Math.round(recent.avg_latency_ms)} ms avg`;
    return typeof recent.p95_latency_ms === "number" ? `${average} / ${Math.round(recent.p95_latency_ms)} ms p95` : average;
  }

  const latencies = logs
    .map((log) => log.latency_ms)
    .filter((value): value is number => typeof value === "number" && Number.isFinite(value));

  if (latencies.length === 0) {
    return "无延迟样本";
  }

  const average = latencies.reduce((sum, value) => sum + value, 0) / latencies.length;
  return `${Math.round(average)} ms`;
}

function channelHealthStatus(
  channel: Channel,
  summaryChannel: HealthSummaryChannel | undefined,
  key: ProviderKey | undefined,
): string {
  if (!key) {
    return "config-needed";
  }

  if (key.status === "auth_failed" || key.status === "quota_exhausted") {
    return key.status;
  }

  if (key.status === "cooldown" || key.status === "recovery_probe" || key.status === "degraded") {
    return key.status;
  }

  if (summaryChannel?.health_state && summaryChannel.health_state !== "no_signal") {
    return summaryChannel.health_state;
  }

  if (channel.status !== "enabled") {
    return channel.status;
  }

  return summaryChannel?.health_state ?? "no_signal";
}

function channelNextAction(status: string, key: ProviderKey | undefined, model: string): string {
  if (model === "config-needed") {
    return "绑定模型映射后运行通道测试。";
  }

  if (!key) {
    return "创建 provider key，再运行恢复探针。";
  }

  if (status === "auth_failed") {
    return "轮换 provider key 凭据后请求恢复探针。";
  }

  if (status === "quota_exhausted") {
    return "补充上游额度或切换通道。";
  }

  if (status === "cooldown" || status === "degraded" || status === "recovery_probe") {
    return "跳到 key/probe，确认恢复探针。";
  }

  if (status === "healthy") {
    return "可继续观察延迟和失败 TopN。";
  }

  return "检查 provider、channel、key 和 probe 工作流。";
}

function uniqueValues(values: string[]): string[] {
  return [...new Set(values.map((value) => safeFieldValue(value)).filter((value) => value !== "-"))].sort();
}

function successRateText(value: number | null | undefined): string {
  if (typeof value !== "number" || Number.isNaN(value)) {
    return "无信号";
  }

  return `${Math.round(value * 100)}%`;
}

function scoreText(value: number | null | undefined): string {
  if (typeof value !== "number" || Number.isNaN(value)) {
    return "-";
  }

  return value <= 1 ? String(Math.round(value * 100)) : String(Math.round(value));
}

function healthSummaryWindowLabel(summary: HealthSummary): string {
  const minutes = summary.recent_window.window_minutes ?? summary.recent_window.window?.minutes;

  if (!minutes) {
    return "近期";
  }

  if (minutes >= 60 && minutes % 60 === 0) {
    return `${minutes / 60}h`;
  }

  return `${minutes}m`;
}

function healthSummaryProbeStatus(summary: HealthSummary | null): {
  detail: string;
  statusLabel: string;
} {
  const probeStatus = summary?.probe_status;
  const source = healthSummaryProbeSourceLabel(summary);
  const nextProbe = channelNextProbeLabel(summary);

  if (!probeStatus || probeStatus.scheduler_pending) {
    return {
      detail: `${source} / ${nextProbe}`,
      statusLabel: "scheduler pending",
    };
  }

  return {
    detail: `${source} / ${nextProbe}`,
    statusLabel: safeFieldValue(probeStatus.status),
  };
}

function healthSummaryProbeSourceLabel(summary: HealthSummary | null): string {
  const source = summary?.probe_status?.probe_source ?? summary?.recent_window.source ?? "request_logs";
  return source === "request_logs" ? "request logs" : safeFieldValue(source);
}

function channelNextProbeLabel(summary: HealthSummary | null): string {
  const nextProbe = summary?.probe_status?.next_probe;

  if (typeof nextProbe === "string" && nextProbe.trim().length > 0) {
    return `next ${formatDateTime(nextProbe)}`;
  }

  return summary?.probe_status?.scheduler_pending === false ? "next probe unset" : "next probe pending";
}

function ProviderChannelWorkflow({
  canManageProviders,
  canRequestProviderKeyRecovery,
  canRunManualTest,
  channels,
  keyRecoveryBusyId,
  loading,
  providerKeys,
  providers,
  onReviewRecoverySuggestion,
}: {
  canManageProviders: boolean;
  canRequestProviderKeyRecovery: boolean;
  canRunManualTest: boolean;
  channels: Channel[];
  keyRecoveryBusyId: string | null;
  loading: boolean;
  providerKeys: ProviderKey[];
  providers: Provider[];
  onReviewRecoverySuggestion: (suggestion: RecoverySuggestion) => void;
}) {
  return (
    <section className="admin-panel provider-workflow" aria-label="供应商到探针工作流">
      <div className="section-heading">
        <div>
          <h2>供应商工作流</h2>
          <p>按 provider → channel → provider key → probe 状态阅读上游配置链路。</p>
        </div>
      </div>

      {loading ? (
        <p className="muted-copy">正在加载供应商工作流。</p>
      ) : providers.length > 0 ? (
        <div className="provider-workflow-list">
          {providers.map((provider) => {
            const providerChannels = channels.filter((channel) => channel.provider_id === provider.id);

            return (
              <article className="provider-workflow-provider" id={`provider-workflow-provider-${provider.id}`} key={provider.id}>
                <div className="provider-workflow-provider__header">
                  <div>
                    <strong>{provider.name}</strong>
                    <span>
                      {provider.code} · {safeShortId(provider.id)}
                    </span>
                  </div>
                  <StateChip status={provider.status} />
                </div>

                {providerChannels.length > 0 ? (
                  <div className="provider-workflow-channels">
                    {providerChannels.map((channel) => (
                      <ProviderWorkflowChannel
                        canManageProviders={canManageProviders}
                        canRequestProviderKeyRecovery={canRequestProviderKeyRecovery}
                        canRunManualTest={canRunManualTest}
                        channel={channel}
                        keyRecoveryBusyId={keyRecoveryBusyId}
                        key={channel.id}
                        provider={provider}
                        providerKeys={providerKeys.filter((providerKey) => providerKey.channel_id === channel.id)}
                        onReviewRecoverySuggestion={onReviewRecoverySuggestion}
                      />
                    ))}
                  </div>
                ) : (
                  <div className="provider-workflow-empty">
                    <strong>没有通道</strong>
                    <span>下一步：为该 provider 创建 channel，再添加 provider key。</span>
                  </div>
                )}
              </article>
            );
          })}
        </div>
      ) : (
        <div className="provider-workflow-empty">
          <strong>没有供应商</strong>
          <span>下一步：创建 provider，然后创建 channel 和 provider key。</span>
        </div>
      )}
    </section>
  );
}

function ProviderWorkflowChannel({
  canManageProviders,
  canRequestProviderKeyRecovery,
  canRunManualTest,
  channel,
  keyRecoveryBusyId,
  provider,
  providerKeys,
  onReviewRecoverySuggestion,
}: {
  canManageProviders: boolean;
  canRequestProviderKeyRecovery: boolean;
  canRunManualTest: boolean;
  channel: Channel;
  keyRecoveryBusyId: string | null;
  provider: Provider;
  providerKeys: ProviderKey[];
  onReviewRecoverySuggestion: (suggestion: RecoverySuggestion) => void;
}) {
  const channelSuggestion = providerKeys.length === 0 ? recoverySuggestionFor({ channel, provider }) : null;
  const readiness = channelReadiness(channel, providerKeys);

  return (
    <div className="provider-workflow-channel" id={`provider-workflow-channel-${channel.id}`}>
      <div className="provider-workflow-channel__summary">
        <div>
          <strong>{channel.name}</strong>
          <span>
            {safeEndpoint(channel.endpoint)} · {channelProtocolLabel(channel.protocol_mode)}
          </span>
        </div>
        <div className="action-row">
          <StateChip status={channel.status} />
          <StateChip status={readiness.status} />
        </div>
      </div>

      <div className="provider-workflow-probe-policy">
        <JsonSummary label="探针策略" value={channel.probe_policy} />
        <span>
          Channel readiness：{formatStatus(readiness.status)}。{readiness.detail}
        </span>
        <span>下一步：{readiness.nextStep}</span>
      </div>

      {providerKeys.length > 0 ? (
        <div className="provider-workflow-keys">
          {providerKeys.map((providerKey) => {
            const probe = providerKeyProbeState(providerKey);
            const suggestion = recoverySuggestionFor({ channel, key: providerKey, provider });

            return (
              <div className="provider-workflow-key" id={`provider-workflow-key-${providerKey.id}`} key={providerKey.id}>
                <div className="provider-workflow-key__main">
                  <div>
                    <strong>{providerKey.key_alias}</strong>
                    <span>{safeShortId(providerKey.id)}</span>
                  </div>
                  <StateChip status={probe.status} />
                </div>
                <dl className="provider-workflow-key__probe">
                  <div>
                    <dt>result</dt>
                    <dd>{probe.recent}</dd>
                  </div>
                  <div>
                    <dt>error_code</dt>
                    <dd>{probe.failure}</dd>
                  </div>
                  <div>
                    <dt>last_checked_at</dt>
                    <dd>{probe.lastCheckedAt}</dd>
                  </div>
                  <div>
                    <dt>next_step</dt>
                    <dd>{probe.nextAction}</dd>
                  </div>
                </dl>
                <div className="action-row">
                  <button
                    className="table-action"
                    type="button"
                    disabled={
                      !canExecuteRecoverySuggestion(suggestion, {
                        canManageProviders,
                        canRequestProviderKeyRecovery,
                        canRunManualTest,
                      }) ||
                      keyRecoveryBusyId === providerKey.id ||
                      !suggestion.action
                    }
                    onClick={() => onReviewRecoverySuggestion(suggestion)}
                    aria-label={`查看恢复建议 ${providerKey.key_alias}`}
                  >
                    {keyRecoveryBusyId === providerKey.id ? "请求中" : "查看建议"}
                  </button>
                </div>
              </div>
            );
          })}
        </div>
      ) : (
        <div className="provider-workflow-empty">
          <strong>没有 provider key</strong>
          <span>下一步：在供应商密钥页面为该通道添加一次性凭据材料；页面不会回显凭据。</span>
          <button
            className="table-action"
            type="button"
            disabled={
              !channelSuggestion?.action ||
              !canExecuteRecoverySuggestion(channelSuggestion, {
                canManageProviders,
                canRequestProviderKeyRecovery,
                canRunManualTest,
              })
            }
            onClick={() => channelSuggestion ? onReviewRecoverySuggestion(channelSuggestion) : undefined}
          >
            查看建议
          </button>
        </div>
      )}
    </div>
  );
}

function RecoverySuggestionDialog({
  busy,
  suggestion,
  onClose,
  onConfirm,
}: {
  busy: boolean;
  suggestion: RecoverySuggestion;
  onClose: () => void;
  onConfirm: (suggestion: RecoverySuggestion) => void;
}) {
  return (
    <div className="wizard-overlay" role="dialog" aria-modal="true" aria-label="恢复建议确认对话框">
      <div className="wizard-panel">
        <div className="wizard-header">
          <div>
            <span>自动恢复建议</span>
            <h3>{suggestion.title}</h3>
            <p>建议只基于状态、健康摘要和最近恢复探针；确认后执行现有动作，不会自动启用恢复结果。</p>
          </div>
          <button className="secondary-button" type="button" onClick={onClose} disabled={busy}>
            关闭
          </button>
        </div>

        <div className="wizard-body">
          <dl className="provider-workflow-key__probe" aria-label="恢复建议摘要">
            <div>
              <dt>状态</dt>
              <dd>{suggestion.status}</dd>
            </div>
            <div>
              <dt>原因</dt>
              <dd>{suggestion.reason}</dd>
            </div>
            <div>
              <dt>下一步</dt>
              <dd>{suggestion.nextStep}</dd>
            </div>
          </dl>
          <div className="action-row">
            <button className="secondary-button" type="button" onClick={onClose} disabled={busy}>
              取消
            </button>
            <button
              className="primary-button primary-button--inline"
              type="button"
              disabled={busy || !suggestion.action}
              onClick={() => onConfirm(suggestion)}
            >
              {busy ? "执行中" : suggestion.actionLabel}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

function recoverySuggestionFor({
  channel,
  key,
  provider,
}: {
  channel: Channel;
  key?: ProviderKey;
  provider: Provider;
}): RecoverySuggestion {
  const title = key ? `${safeFieldValue(key.key_alias)} 恢复建议` : `${safeFieldValue(channel.name)} 恢复建议`;

  if (provider.status === "disabled") {
    return {
      action: "provider_enable",
      actionLabel: "确认启用供应商",
      channelId: channel.id,
      keyId: key?.id,
      nextStep: "确认后只启用 provider，再观察 channel/key 状态；不会自动启用 provider key。",
      providerId: provider.id,
      reason: "provider 当前停用，路由不会选择其下通道。",
      status: formatStatus(provider.status),
      title,
    };
  }

  if (channel.status === "disabled") {
    return {
      action: "channel_enable",
      actionLabel: "确认启用通道",
      channelId: channel.id,
      keyId: key?.id,
      nextStep: "确认后只启用 channel，再运行通道测试或恢复探针。",
      providerId: provider.id,
      reason: "channel 当前停用，健康探针和路由都需要先恢复通道状态。",
      status: formatStatus(channel.status),
      title,
    };
  }

  if (!key) {
    return {
      action: null,
      actionLabel: "没有可执行动作",
      channelId: channel.id,
      nextStep: "创建 provider key 并录入一次性 secret 后再运行恢复探针。",
      providerId: provider.id,
      reason: "该通道没有 provider key。",
      status: "config-needed",
      title,
    };
  }

  const probe = key.recovery_probe;
  const recoveryReadback = key.recovery_action_readback;
  const probeResult = safeFieldValue(recoveryReadback?.last_probe_status ?? probe?.result);
  const probeError = safeFieldValue(probe?.error_code ?? key.last_error_code);
  const probeCheckedAt = probe?.last_checked_at ? formatDateTime(probe.last_checked_at) : "-";
  const readbackNextAction = safeFieldValue(recoveryReadback?.safe_next_action);
  const refusalReason = safeFieldValue(recoveryReadback?.cooldown_or_refusal_reason);

  if (key.status === "manual_disabled") {
    return {
      action: "key_enable",
      actionLabel: "确认启用密钥",
      channelId: channel.id,
      keyId: key.id,
      nextStep: "确认后只把 provider key 标记为 enabled；建议随后运行通道 dry-run。",
      providerId: provider.id,
      reason: `密钥被管理员停用；最近探针 ${probeResult} / ${probeCheckedAt}。`,
      status: formatStatus(key.status),
      title,
    };
  }

  if (key.status === "quota_exhausted" || key.status === "auth_failed") {
    return {
      action: "key_disable",
      actionLabel: "确认停用密钥",
      channelId: channel.id,
      keyId: key.id,
      nextStep: "先停用异常 key，轮换凭据或补充上游额度后再请求恢复探针。",
      providerId: provider.id,
      reason: `密钥状态为 ${formatStatus(key.status)}；最近错误 ${probeError}。`,
      status: formatStatus(key.status),
      title,
    };
  }

  if (canRecoverProviderKey(key)) {
    return {
      action: "key_recovery_probe",
      actionLabel: "确认恢复探针",
      channelId: channel.id,
      keyId: key.id,
      nextStep:
        readbackNextAction !== "-"
          ? `${readbackNextAction}；需要管理员确认：${recoveryReadback?.operator_confirmation_required ? "yes" : "no"}。`
          : "确认后进入 recovery_probe；后端探针或人工检查完成前不会自动启用。",
      providerId: provider.id,
      reason: `密钥可恢复；最近错误 ${probeError}，最近探针 ${probeResult} / ${probeCheckedAt}，冷却/拒绝原因 ${refusalReason}。`,
      status: formatStatus(key.status),
      title,
    };
  }

  if (key.status === "enabled") {
    return {
      action: "channel_test",
      actionLabel: "确认通道测试",
      channelId: channel.id,
      keyId: key.id,
      nextStep: "确认后运行 channel dry-run；不会调用上游，不会使用 provider key secret。",
      providerId: provider.id,
      reason: key.last_error_code ? `密钥启用但有最近错误 ${probeError}。` : "密钥启用且没有最近错误。",
      status: `enabled / health ${Math.round(key.health_score)}`,
      title,
    };
  }

  return {
    action: null,
    actionLabel: "没有可执行动作",
    channelId: channel.id,
    keyId: key.id,
    nextStep: "检查 provider、channel、provider key 和最近 request log 后手动处理。",
    providerId: provider.id,
    reason: `当前状态 ${formatStatus(key.status)} 没有匹配的安全建议动作。`,
    status: formatStatus(key.status),
    title,
  };
}

function canExecuteRecoverySuggestion(
  suggestion: RecoverySuggestion,
  capabilities: {
    canManageProviders: boolean;
    canRequestProviderKeyRecovery: boolean;
    canRunManualTest: boolean;
  },
): boolean {
  if (!suggestion.action) {
    return false;
  }

  if (suggestion.action === "channel_test") {
    return capabilities.canRunManualTest;
  }

  if (suggestion.action === "key_recovery_probe") {
    return capabilities.canRequestProviderKeyRecovery;
  }

  return capabilities.canManageProviders;
}

function providerKeyProbeState(key: ProviderKey): {
  failure: string;
  lastCheckedAt: string;
  nextAction: string;
  recent: string;
  status: string;
} {
  const probe = providerKeyProbeSummary(key);
  const status = key.status;
  const cooldown = key.cooldown_until ? `，冷却至 ${formatDateTime(key.cooldown_until)}` : "";
  const error = safeFieldValue(key.recovery_probe?.error_code ?? key.last_error_code);
  const lastCheckedAt = key.recovery_probe?.last_checked_at ? formatDateTime(key.recovery_probe.last_checked_at) : "-";
  const actionReadback = key.recovery_action_readback;
  const readbackProbeStatus = safeFieldValue(actionReadback?.last_probe_status);
  const readbackNextAction = safeFieldValue(actionReadback?.safe_next_action);
  const recentProbeResult = readbackProbeStatus !== "-" ? readbackProbeStatus : safeFieldValue(key.recovery_probe?.result);
  const nextAction = readbackNextAction !== "-" ? readbackNextAction : probe.nextStep;

  if (status === "enabled" && !key.last_error_code) {
    return {
      failure: "-",
      lastCheckedAt,
      nextAction,
      recent: recentProbeResult !== "-" ? recentProbeResult : `健康分 ${Math.round(key.health_score)}`,
      status: probe.status === "ready" ? "online" : probe.status,
    };
  }

  if (status === "cooldown") {
    return {
      failure: error,
      lastCheckedAt,
      nextAction,
      recent: recentProbeResult !== "-" ? recentProbeResult : `冷却中${cooldown}`,
      status: probe.status,
    };
  }

  if (status === "degraded" || status === "recovery_probe") {
    return {
      failure: error,
      lastCheckedAt,
      nextAction,
      recent: recentProbeResult !== "-" ? recentProbeResult : formatStatus(status),
      status: probe.status,
    };
  }

  if (status === "auth_failed" || status === "quota_exhausted") {
    return {
      failure: error,
      lastCheckedAt,
      nextAction,
      recent: recentProbeResult !== "-" ? recentProbeResult : formatStatus(status),
      status: probe.status,
    };
  }

  if (status === "manual_disabled" || status === "deleted") {
    return {
      failure: "-",
      lastCheckedAt,
      nextAction,
      recent: formatStatus(status),
      status: probe.status,
    };
  }

  return {
    failure: error,
    lastCheckedAt,
    nextAction,
    recent: recentProbeResult !== "-" ? recentProbeResult : `${formatStatus(status)}${cooldown}`,
    status: probe.status,
  };
}

function canRecoverProviderKey(key: ProviderKey): boolean {
  return key.status === "cooldown" || key.status === "degraded" || key.status === "recovery_probe";
}

function statusActionLabel(status: string): string {
  if (status === "deleted") {
    return "删除";
  }

  if (status === "enabled") {
    return "启用";
  }

  if (status === "disabled" || status === "manual_disabled") {
    return "禁用";
  }

  return formatStatus(status);
}

function formatDate(value: string): string {
  const date = new Date(value);

  if (Number.isNaN(date.getTime())) {
    return value;
  }

  return date.toLocaleString([], {
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    month: "short",
  });
}

function providerToForm(provider: Provider): ProviderForm {
  return {
    baseUrl: providerMetadata(provider, "base_url") ?? "",
    code: provider.code,
    metadata: jsonFormValue(provider.metadata, "{}"),
    name: provider.name,
    providerType: providerMetadata(provider, "provider_type") ?? "",
  };
}

function channelToForm(channel: Channel): ChannelForm {
  return {
    endpoint: channel.endpoint,
    modelMappings: jsonFormValue(channel.model_mappings, "{}"),
    name: channel.name,
    probePolicy: jsonFormValue(channel.probe_policy, "{}"),
    protocolMode: channelProtocolValue(channel.protocol_mode),
    providerId: channel.provider_id,
    requestOverrides: jsonFormValue(channel.request_overrides, "[]"),
    tags: jsonFormValue(channel.tags, "[]"),
    timeoutPolicy: jsonFormValue(channel.timeout_policy, "{}"),
  };
}

function jsonFormValue(value: JsonValue, fallback: string): string {
  if (value === null || value === undefined) {
    return fallback;
  }

  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return fallback;
  }
}

function AdvancedJsonPolicyPanel({
  channelForm,
  channels,
  providerForm,
  providers,
  onChannelChange,
  onChannelSubmit,
  onProviderChange,
  onProviderSubmit,
}: {
  channelForm: ChannelJsonPatchForm;
  channels: Channel[];
  providerForm: ProviderJsonPatchForm;
  providers: Provider[];
  onChannelChange: (field: keyof ChannelJsonPatchForm, value: string) => void;
  onChannelSubmit: (event: FormEvent<HTMLFormElement>) => Promise<void>;
  onProviderChange: (field: keyof ProviderJsonPatchForm, value: string) => void;
  onProviderSubmit: (event: FormEvent<HTMLFormElement>) => Promise<void>;
}) {
  return (
    <section className="admin-panel" id="advanced-json-policies" aria-label="高级 JSON 策略">
      <div className="section-heading">
        <div>
          <h2>高级 JSON 策略</h2>
        </div>
      </div>

      <div className="advanced-json-grid">
        <form className="advanced-json-form" onSubmit={(event) => void onProviderSubmit(event)}>
          <h3>供应商</h3>
          <label className="field">
            供应商补丁 ID
            <input
              list="provider-json-patch-options"
              value={providerForm.providerId}
              onChange={(event) => onProviderChange("providerId", event.currentTarget.value)}
              placeholder="provider uuid"
              required
            />
          </label>
          <datalist id="provider-json-patch-options">
            {providers.map((provider) => (
              <option key={provider.id} value={provider.id}>
                {provider.name}
              </option>
            ))}
          </datalist>
          <label className="field">
            供应商补丁 metadata JSON
            <textarea
              value={providerForm.metadata}
              onChange={(event) => onProviderChange("metadata", event.currentTarget.value)}
              placeholder='{"owner":"platform"}'
              spellCheck={false}
            />
          </label>
          <button className="primary-button primary-button--inline" type="submit">
            保存供应商 JSON
          </button>
        </form>

        <form className="advanced-json-form" onSubmit={(event) => void onChannelSubmit(event)}>
          <h3>通道</h3>
          <label className="field">
            通道补丁 ID
            <input
              list="channel-json-patch-options"
              value={channelForm.channelId}
              onChange={(event) => onChannelChange("channelId", event.currentTarget.value)}
              placeholder="channel uuid"
              required
            />
          </label>
          <datalist id="channel-json-patch-options">
            {channels.map((channel) => (
              <option key={channel.id} value={channel.id}>
                {channel.name}
              </option>
            ))}
          </datalist>
          <div className="advanced-json-form-grid">
            <label className="field">
              补丁 model_mappings JSON
              <textarea
                value={channelForm.modelMappings}
                onChange={(event) => onChannelChange("modelMappings", event.currentTarget.value)}
                placeholder='{"gpt-4o-mini":"gpt-4o-mini"}'
                spellCheck={false}
              />
            </label>
            <label className="field">
              补丁 tags JSON
              <textarea
                value={channelForm.tags}
                onChange={(event) => onChannelChange("tags", event.currentTarget.value)}
                placeholder='["primary"]'
                spellCheck={false}
              />
            </label>
            <label className="field">
              补丁 request_overrides JSON
              <textarea
                value={channelForm.requestOverrides}
                onChange={(event) => onChannelChange("requestOverrides", event.currentTarget.value)}
                placeholder="[]"
                spellCheck={false}
              />
            </label>
            <label className="field">
              补丁 probe_policy JSON
              <textarea
                value={channelForm.probePolicy}
                onChange={(event) => onChannelChange("probePolicy", event.currentTarget.value)}
                placeholder='{"path":"/health"}'
                spellCheck={false}
              />
            </label>
            <label className="field">
              补丁 timeout_policy JSON
              <textarea
                value={channelForm.timeoutPolicy}
                onChange={(event) => onChannelChange("timeoutPolicy", event.currentTarget.value)}
                placeholder='{"connect_ms":2000}'
                spellCheck={false}
              />
            </label>
          </div>
          <button className="primary-button primary-button--inline" type="submit">
            保存通道 JSON
          </button>
        </form>
      </div>
    </section>
  );
}

function ProviderTable({
  busyId,
  canManageProviders,
  channels,
  loading,
  onCreateChannel,
  onEditProvider,
  providers,
  onStatus,
}: {
  busyId: string | null;
  canManageProviders: boolean;
  channels: Channel[];
  loading: boolean;
  onCreateChannel: (providerId: string) => void;
  onEditProvider: (provider: Provider) => void;
  providers: Provider[];
  onStatus: (provider: Provider, status: ProviderStatus) => Promise<void>;
}) {
  return (
    <section aria-label="供应商列表">
      <div className="health-table-wrap">
        <table className="health-table admin-table admin-table--providers">
          <thead>
            <tr>
              <th>供应商</th>
              <th>状态</th>
              <th>类型 / Base URL</th>
              <th>Metadata</th>
              <th>通道</th>
              <th>操作</th>
            </tr>
          </thead>
          <tbody>
            {loading ? (
              <tr>
                <td colSpan={6}>正在加载供应商。</td>
              </tr>
            ) : providers.length > 0 ? (
              providers.map((provider) => (
                <tr key={provider.id}>
                  <td>
                    <strong>{provider.name}</strong>
                    <span>
                      {provider.code} / {safeShortId(provider.id)}
                    </span>
                  </td>
                  <td>
                    <StateChip status={provider.status} />
                  </td>
                  <td>
                    <strong>{fieldValue(providerMetadata(provider, "provider_type"))}</strong>
                    <span>{safeEndpoint(providerMetadata(provider, "base_url"))}</span>
                  </td>
                  <td>
                    <JsonSummary value={provider.metadata} />
                  </td>
                  <td>
                    <strong>{channels.filter((channel) => channel.provider_id === provider.id).length}</strong>
                    <span>已绑定通道</span>
                  </td>
                  <td>
                    <div className="action-row">
                      <button
                        className="table-action"
                        type="button"
                        onClick={() => onEditProvider(provider)}
                        disabled={!canManageProviders || busyId === provider.id || provider.status === "deleted"}
                        aria-label={`编辑供应商 ${provider.name}`}
                      >
                        <Edit3 aria-hidden="true" size={15} />
                        编辑
                      </button>
                      <button
                        className="table-action"
                        type="button"
                        onClick={() => onCreateChannel(provider.id)}
                        disabled={!canManageProviders || provider.status === "deleted"}
                        aria-label={`为供应商 ${provider.name} 创建通道`}
                      >
                        <Plus aria-hidden="true" size={15} />
                        通道
                      </button>
                      <button
                        className="table-action"
                        type="button"
                        onClick={() => void onStatus(provider, "disabled")}
                        disabled={
                          !canManageProviders ||
                          busyId === provider.id ||
                          provider.status === "disabled" ||
                          provider.status === "deleted"
                        }
                        aria-label={`禁用供应商 ${provider.name}`}
                      >
                        <ShieldOff aria-hidden="true" size={15} />
                        禁用
                      </button>
                      <button
                        className="table-action table-action--danger"
                        type="button"
                        onClick={() => void onStatus(provider, "deleted")}
                        disabled={!canManageProviders || busyId === provider.id || provider.status === "deleted"}
                        aria-label={`删除供应商 ${provider.name}`}
                      >
                        <Trash2 aria-hidden="true" size={15} />
                        删除
                      </button>
                    </div>
                  </td>
                </tr>
              ))
            ) : (
              <tr>
                <td colSpan={6}>暂无供应商。</td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </section>
  );
}

function ChannelTable({
  busyId,
  canManageProviders,
  canRunManualTest,
  channels,
  loading,
  manualBusyId,
  manualForms,
  onCopyChannel,
  onEditChannel,
  providerKeys,
  providers,
  onManualFormChange,
  onManualTest,
  onStatus,
}: {
  busyId: string | null;
  canManageProviders: boolean;
  canRunManualTest: boolean;
  channels: Channel[];
  loading: boolean;
  manualBusyId: string | null;
  manualForms: Record<string, ChannelManualTestForm>;
  onCopyChannel: (channel: Channel) => void;
  onEditChannel: (channel: Channel) => void;
  providerKeys: ProviderKey[];
  providers: Provider[];
  onManualFormChange: (channelId: string, field: keyof ChannelManualTestForm, value: string) => void;
  onManualTest: (channel: Channel, event: FormEvent<HTMLFormElement>) => Promise<void>;
  onStatus: (channel: Channel, status: ChannelStatus) => Promise<void>;
}) {
  return (
    <section aria-label="通道列表">
      <div className="health-table-wrap">
        <table className="health-table admin-table admin-table--channels">
          <thead>
            <tr>
              <th>通道</th>
              <th>状态</th>
              <th>供应商</th>
              <th>Endpoint</th>
              <th>高级 JSON</th>
              <th>手动测试</th>
              <th>操作</th>
            </tr>
          </thead>
          <tbody>
            {loading ? (
              <tr>
                <td colSpan={7}>正在加载通道。</td>
              </tr>
            ) : channels.length > 0 ? (
              channels.map((channel) => {
                const manualForm = manualForms[channel.id] ?? defaultChannelManualTestForm;
                const modelOptions = modelMappingOptions(channel);
                const requestedListId = `manual-test-requested-${channel.id}`;
                const upstreamListId = `manual-test-upstream-${channel.id}`;
                const readiness = channelReadiness(
                  channel,
                  providerKeys.filter((key) => key.channel_id === channel.id),
                );

                return (
                  <tr key={channel.id}>
                    <td>
                      <strong>{channel.name}</strong>
                      <span>{safeShortId(channel.id)}</span>
                    </td>
                    <td>
                      <StateChip status={channel.status} />
                      <span>{channelProtocolLabel(channel.protocol_mode)}</span>
                      <span>
                        readiness {formatStatus(readiness.status)} · {readiness.nextStep}
                      </span>
                      {readiness.probe ? (
                        <span>
                          probe {safeFieldValue(readiness.probe.result)} / {safeFieldValue(readiness.probe.errorCode)}
                        </span>
                      ) : null}
                    </td>
                    <td>
                      <strong>{providerName(channel.provider_id, providers)}</strong>
                      <span>{safeShortId(channel.provider_id)}</span>
                    </td>
                    <td>
                      <strong>{fieldValue(channel.region)}</strong>
                      <span>{safeEndpoint(channel.endpoint)}</span>
                    </td>
                    <td>
                      <div className="json-summary-stack">
                        <JsonSummary label="映射" value={channel.model_mappings} />
                        <JsonSummary label="标签" value={channel.tags} />
                        <JsonSummary label="覆盖" value={channel.request_overrides} />
                        <JsonSummary label="探测" value={channel.probe_policy} />
                        <JsonSummary label="超时" value={channel.timeout_policy} />
                      </div>
                    </td>
                    <td>
                      {canRunManualTest ? (
                        <form className="manual-test-form" onSubmit={(event) => void onManualTest(channel, event)}>
                          <label className="manual-test-field">
                            请求模型
                            <input
                              list={requestedListId}
                              onChange={(event) =>
                                onManualFormChange(channel.id, "requestedModel", event.currentTarget.value)
                              }
                              required
                              value={manualForm.requestedModel}
                            />
                          </label>
                          <datalist id={requestedListId}>
                            {modelOptions.requested.map((model) => (
                              <option key={model} value={model} />
                            ))}
                          </datalist>
                          <label className="manual-test-field">
                            上游模型
                            <input
                              list={upstreamListId}
                              onChange={(event) =>
                                onManualFormChange(channel.id, "upstreamModel", event.currentTarget.value)
                              }
                              value={manualForm.upstreamModel}
                            />
                          </label>
                          <datalist id={upstreamListId}>
                            {modelOptions.upstream.map((model) => (
                              <option key={model} value={model} />
                            ))}
                          </datalist>
                          <button
                            className="table-action"
                            type="submit"
                            disabled={manualBusyId === channel.id || channel.status === "deleted"}
                            aria-label={`为 ${channel.name} 运行手动测试`}
                          >
                            <Search aria-hidden="true" size={15} />
                            {manualBusyId === channel.id ? "运行中" : "测试"}
                          </button>
                        </form>
                      ) : (
                        <span className="muted-copy">不可用</span>
                      )}
                    </td>
                    <td>
                      <div className="action-row">
                        <button
                          className="table-action"
                          type="button"
                          onClick={() => onEditChannel(channel)}
                          disabled={!canManageProviders || busyId === channel.id || channel.status === "deleted"}
                          aria-label={`编辑通道 ${channel.name}`}
                        >
                          <Edit3 aria-hidden="true" size={15} />
                          编辑
                        </button>
                        <button
                          className="table-action"
                          type="button"
                          onClick={() => onCopyChannel(channel)}
                          disabled={!canManageProviders || busyId === channel.id || channel.status === "deleted"}
                          aria-label={`复制通道 ${channel.name}`}
                        >
                          <Copy aria-hidden="true" size={15} />
                          复制
                        </button>
                        <button
                          className="table-action"
                          type="button"
                          onClick={() => void onStatus(channel, "disabled")}
                          disabled={
                            !canManageProviders ||
                            busyId === channel.id ||
                            channel.status === "disabled" ||
                            channel.status === "deleted"
                          }
                          aria-label={`禁用通道 ${channel.name}`}
                        >
                          <ShieldOff aria-hidden="true" size={15} />
                          禁用
                        </button>
                        <button
                          className="table-action table-action--danger"
                          type="button"
                          onClick={() => void onStatus(channel, "deleted")}
                          disabled={!canManageProviders || busyId === channel.id || channel.status === "deleted"}
                          aria-label={`删除通道 ${channel.name}`}
                        >
                          <Trash2 aria-hidden="true" size={15} />
                          删除
                        </button>
                      </div>
                    </td>
                  </tr>
                );
              })
            ) : (
              <tr>
                <td colSpan={7}>暂无通道。</td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </section>
  );
}

function ChannelManualTestResult({
  hasUsableProviderKey,
  result,
}: {
  hasUsableProviderKey: boolean;
  result: ChannelManualTestResponse;
}) {
  const protocolStatus = channelProtocolStatus(result.channel, hasUsableProviderKey);
  const readinessStatus = result.status ?? (hasUsableProviderKey ? "contract-ready" : protocolStatus.status);
  const readinessNextStep = result.next_step ?? protocolStatus.detail;
  const protocolLabel = channelProtocolLabel(result.protocol ?? result.channel.protocol_mode);
  const explainability = result.manual_test_explainability;
  const explainabilityKeySummary = explainability?.provider_key_lifecycle_summary;
  const explainabilityEndpoint = explainability?.endpoint_capability;
  const omittedSecretPolicy = explainability?.omitted_secret_policy;

  return (
    <section className="detail-grid" aria-label="通道手动测试结果">
      <article className="admin-panel">
        <div className="section-heading">
          <div>
            <h2>通道手动测试</h2>
            <p>{safeFieldValue(result.test_mode)}</p>
          </div>
          <StateChip status={readinessStatus} />
        </div>
        <div className="manual-test-flags" aria-label="手动测试安全标志">
          <span>upstream_call={String(result.upstream_call)}</span>
          <span>billable={String(result.billing.billable)}</span>
          <span>ledger_write={String(result.billing.ledger_write)}</span>
        </div>
        <DetailFields
          items={[
            ["请求模型", result.requested_model],
            ["上游模型", result.upstream_model],
            ["协议", protocolLabel],
            ["请求日志写入", String(result.billing.request_log_write)],
            ["凭据材料", "omitted"],
            ["Authorization", result.credential_material.authorization_header ?? "omitted"],
            ["当前状态", readinessStatus],
            ["下一步", readinessNextStep],
          ]}
        />
      </article>

      {explainability ? (
        <article className="admin-panel">
          <h2>Manual test explainability</h2>
          <DetailFields
            items={[
              ["Protocol", channelProtocolLabel(explainability.protocol)],
              ["Status", explainability.status],
              ["Mode", explainability.execution_mode],
              ["Mock", explainability.mock_status],
              ["Live", explainability.live_status],
              ["Config needed", explainability.config_needed.join(", ") || "-"],
              ["Key lifecycle", explainabilityKeySummary?.summary ?? "-"],
              ["Key present", explainabilityKeySummary?.enabled_provider_key_present ? "present" : "missing"],
              ["Endpoint capability", `${explainabilityEndpoint?.method ?? "POST"} ${explainabilityEndpoint?.path_template ?? "-"}`],
              ["Operation", explainabilityEndpoint?.operation ?? "-"],
              ["Mock contract", explainabilityEndpoint?.mock_contract ?? "-"],
              ["Safe next action", explainability.safe_next_action],
              ["Omitted policy", omittedSecretPolicy?.policy ?? "-"],
              ["Omitted fields", omittedSecretPolicy?.omitted_fields.join(", ") ?? "-"],
            ]}
          />
        </article>
      ) : null}

      <article className="admin-panel">
        <h2>通道</h2>
        <DetailFields
          items={[
            ["名称", result.channel.name],
            ["ID", safeShortId(result.channel.id)],
            ["状态", result.channel.status],
            ["协议", protocolLabel],
            ["协议状态", protocolStatus.status],
            ["Endpoint", safeEndpoint(result.channel.endpoint)],
            ["优先级 / 权重", `${result.channel.priority} / ${result.channel.weight}`],
            ["健康分", result.channel.health_score],
          ]}
        />
      </article>

      <article className="admin-panel">
        <h2>供应商</h2>
        <DetailFields
          items={[
            ["名称", result.provider.name],
            ["Code", result.provider.code],
            ["ID", safeShortId(result.provider.id)],
            ["状态", result.provider.status],
          ]}
        />
      </article>

      <article className="admin-panel">
        <h2>请求计划</h2>
        <DetailFields
          items={[
            ["方法", result.request_plan.method],
            ["路径", result.request_plan.path],
            ["操作", result.request_plan.operation ?? "-"],
            ["协议", channelProtocolLabel(result.request_plan.protocol_mode)],
            ["Model", result.request_plan.model],
            ["Mock contract", result.request_plan.mock_contract ?? "-"],
          ]}
        />
      </article>

      {result.endpoint_capabilities ? (
        <article className="admin-panel">
          <h2>协议能力</h2>
          <DetailFields
            items={[
              ["Readiness", result.protocol_readiness?.status ?? "-"],
              ["Provider key", result.protocol_readiness?.provider_key_present ? "present" : "missing"],
              ["Live config", result.protocol_readiness?.live_config_status ?? "-"],
              ["缺口", (result.protocol_readiness?.known_missing_pieces ?? []).join(", ") || "-"],
              ["下一步", result.protocol_readiness?.safe_next_action ?? "-"],
            ]}
          />
          <div className="manual-test-flags" aria-label="协议 endpoint 能力">
            {result.endpoint_capabilities.endpoints
              .filter((endpoint) => endpoint.supported)
              .map((endpoint) => (
                <span key={endpoint.endpoint}>
                  {endpoint.endpoint}: {endpoint.live_config_status ?? endpoint.mockable_config_status}
                </span>
              ))}
          </div>
        </article>
      ) : null}
    </section>
  );
}

function DetailFields({ items }: { items: Array<[string, unknown]> }) {
  return (
    <dl className="detail-list">
      {items.map(([label, value]) => (
        <div key={label}>
          <dt>{label}</dt>
          <dd>{safeFieldValue(value)}</dd>
        </div>
      ))}
    </dl>
  );
}

function JsonSummary({ label, value }: { label?: string; value: JsonValue }) {
  const safeValue = sanitizeDisplayJson(value);
  const fieldCount = jsonSize(safeValue);
  const keys = jsonSummaryKeys(safeValue);

  return (
    <span className="json-summary">
      <strong>
        {label ? `${label} ` : ""}
        {fieldCount} 个字段
      </strong>
      <span>{keys}</span>
    </span>
  );
}
