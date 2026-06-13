import { FormEvent, useEffect, useMemo, useState } from "react";

import {
  getProviderHealthSummary,
  getNetworkSecuritySettings,
  listApiKeyProfiles,
  listSubscriptionPlans,
  listVirtualKeys,
  patchApiKeyProfile,
  patchNetworkSecuritySettings,
  type ApiKeyProfile,
  type HealthSummary,
  type JsonValue,
  type NetworkSecuritySettings,
  type ProbeResult,
  type SubscriptionPlan,
  type VirtualKey,
  probeServices,
} from "../../api/client";
import { errorMessage, safeFieldValue } from "../../components/adminUtils";
import { Copy, RefreshCw, Save, Shield } from "../../components/icons";
import { ActionButton } from "../../design/ActionButton";
import { DataTable } from "../../design/DataTable";
import { EmptyState } from "../../design/EmptyState";
import { Field } from "../../design/Field";
import { SectionHeader } from "../../design/SectionHeader";
import { StatusChip } from "../../design/StatusChip";

const DEFAULT_PROJECT_ID = "00000000-0000-0000-0000-000000000020";
const NETWORK_SECURITY_EXAMPLE_SCRIPT = "scripts/write_network_security_config_example.ps1";
const NETWORK_SECURITY_EXAMPLE_OUTPUT = ".tmp/network-security/network_security_config_example.yaml";
const TRUSTED_PROXY_CONFIG_KEYS = ["AI_GATEWAY_CONFIG", "server.trusted_proxy_allowlist"];
const SETUP_SEED_CONFIG_KEYS = ["scripts/setup_local_mvp.ps1", "dev_seed", "DEFAULT_PROJECT_ID"];
const PAYMENT_CONFIG_KEYS = ["payment_status", "merchant_connected", "scheduler_status"];
const PROVIDER_CONFIG_KEYS = ["provider", "channel", "provider_key", "model_association"];
const LOCAL_MVP_COMMANDS: LocalMvpCommand[] = [
  {
    command:
      "pwsh -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\write_network_security_config_example.ps1",
    envVars: ["AI_GATEWAY_CONFIG"],
    id: "network-security-example",
    purpose:
      "生成 trusted proxy、profile IP allowlist 和 virtual key IP allowlist 的文档示例；只使用 RFC 文档网段，不包含真实生产 IP 或 secret。",
    title: "write_network_security_config_example.ps1",
    usage:
      `默认写入 ${NETWORK_SECURITY_EXAMPLE_OUTPUT}；加 -PrintOnly 只输出到 stdout，不创建或覆盖文件。`,
  },
  {
    command:
      'pwsh -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\setup_local_mvp.ps1 -TimeoutSeconds $env:SETUP_TIMEOUT_SECONDS',
    envVars: ["SETUP_TIMEOUT_SECONDS"],
    id: "setup-local-mvp",
    purpose:
      "修复本地 dev seed：admin、mock provider、默认模型、provider key 占位和测试 key readback；脚本不会打印 raw password、provider secret 或测试 key。",
    title: "setup_local_mvp.ps1",
    usage: "先启动 compose Postgres 后运行；可加 -DryRun 只看将应用的本地 seed 文件。",
  },
  {
    command:
      'pwsh -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\dev_up.ps1 -ComposeTimeoutSeconds $env:COMPOSE_TIMEOUT_SECONDS -ReadyTimeoutSeconds $env:READY_TIMEOUT_SECONDS',
    envVars: [
      "POSTGRES_HOST_PORT",
      "REDIS_HOST_PORT",
      "GATEWAY_HOST_PORT",
      "CONTROL_PLANE_HOST_PORT",
      "ADMIN_UI_HOST_PORT",
      "MOCK_PROVIDER_HOST_PORT",
      "COMPOSE_TIMEOUT_SECONDS",
      "READY_TIMEOUT_SECONDS",
    ],
    id: "dev-up",
    purpose:
      "启动本地最小开发栈：Postgres、Redis、mock-provider、gateway、control-plane 和 admin-ui；默认会调用本地 seed repair。",
    title: "dev_up.ps1",
    usage: "端口冲突时只覆盖对应 *_HOST_PORT env var；这是本地预览入口，不是发布检查。",
  },
  {
    command:
      'pwsh -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\dev_login_check.ps1 -ControlPlaneBaseUrl $env:CONTROL_PLANE_BASE_URL -GatewayBaseUrl $env:GATEWAY_BASE_URL -AdminUiBaseUrl $env:ADMIN_UI_BASE_URL -AdminEmail $env:ADMIN_EMAIL -AdminPassword $env:ADMIN_PASSWORD -GatewayAuthToken $env:GATEWAY_AUTH_TOKEN -Model $env:SMOKE_MODEL',
    envVars: [
      "CONTROL_PLANE_BASE_URL",
      "GATEWAY_BASE_URL",
      "ADMIN_UI_BASE_URL",
      "ADMIN_EMAIL",
      "ADMIN_PASSWORD",
      "GATEWAY_AUTH_TOKEN",
      "SMOKE_MODEL",
      "GATEWAY_FORBIDDEN_MODELS",
    ],
    id: "dev-login-check",
    purpose:
      "跑本地 MVP smoke：admin login、用户注册、voucher、创建 key、/v1/models、mock chat、请求日志和 admin detail readback。",
    title: "dev_login_check.ps1",
    usage: "命令只引用 env var 名；secret 值只在本机 shell 设置，不要粘贴到截图、工单或页面。",
  },
];

type SettingsTab = "overview" | "network" | "config";

type LoadState = {
  error: string | null;
  healthSummary: HealthSummary | null;
  loading: boolean;
  network: NetworkSecuritySettings | null;
  paymentPlans: SubscriptionPlan[];
  profiles: ApiKeyProfile[];
  serviceProbes: ProbeResult[];
  trustedProxyConfigNeeded: boolean;
  virtualKeys: VirtualKey[];
};

export function NetworkSecuritySettingsPage() {
  const [activeTab, setActiveTab] = useState<SettingsTab>("overview");
  const [projectId, setProjectId] = useState(DEFAULT_PROJECT_ID);
  const [selectedProfileId, setSelectedProfileId] = useState("");
  const [profileAllowlistText, setProfileAllowlistText] = useState("");
  const [trustedProxyText, setTrustedProxyText] = useState("");
  const [saveError, setSaveError] = useState<string | null>(null);
  const [saveSuccess, setSaveSuccess] = useState<string | null>(null);
  const [savingProfile, setSavingProfile] = useState(false);
  const [savingProxy, setSavingProxy] = useState(false);
  const [state, setState] = useState<LoadState>({
    error: null,
    healthSummary: null,
    loading: true,
    network: null,
    paymentPlans: [],
    profiles: [],
    serviceProbes: [],
    trustedProxyConfigNeeded: false,
    virtualKeys: [],
  });
  const selectedProfile = useMemo(
    () => state.profiles.find((profile) => profile.id === selectedProfileId) ?? null,
    [selectedProfileId, state.profiles],
  );
  const profileValidation = validateAllowlistText(profileAllowlistText);
  const proxyValidation = validateAllowlistText(trustedProxyText);

  async function loadSettings(nextProjectId = projectId) {
    const trimmedProjectId = nextProjectId.trim();

    if (!trimmedProjectId) {
      setState((current) => ({
        ...current,
        error: "需要填写项目 ID 才能读取 API key/profile allowlist。",
        loading: false,
      }));
      return;
    }

    setState((current) => ({ ...current, error: null, loading: true }));
    setSaveError(null);
    setSaveSuccess(null);

    const [profilesResult, keysResult, networkResult, healthResult, plansResult, probesResult] = await Promise.allSettled([
      listApiKeyProfiles({ project_id: trimmedProjectId }),
      listVirtualKeys({ project_id: trimmedProjectId }),
      getNetworkSecuritySettings(),
      getProviderHealthSummary(),
      listSubscriptionPlans({ limit: 20 }),
      probeServices(),
    ]);

    const profiles = profilesResult.status === "fulfilled" ? profilesResult.value : [];
    const virtualKeys = keysResult.status === "fulfilled" ? keysResult.value : [];
    const network = networkResult.status === "fulfilled" ? networkResult.value : null;
    const healthSummary = healthResult.status === "fulfilled" ? healthResult.value : null;
    const paymentPlans = plansResult.status === "fulfilled" ? plansResult.value : [];
    const serviceProbes = probesResult.status === "fulfilled" ? probesResult.value : [];
    const nextSelectedProfile = profiles.find((profile) => profile.id === selectedProfileId) ?? profiles[0] ?? null;

    setState({
      error: firstRejectedError([profilesResult, keysResult]) ?? null,
      healthSummary,
      loading: false,
      network,
      paymentPlans,
      profiles,
      serviceProbes,
      trustedProxyConfigNeeded: networkResult.status === "rejected",
      virtualKeys,
    });
    setSelectedProfileId(nextSelectedProfile?.id ?? "");
    setProfileAllowlistText(entriesToText(jsonStringArray(nextSelectedProfile?.ip_allowlist)));
    setTrustedProxyText(entriesToText(network?.effective_trusted_proxy_allowlist ?? []));

    if (networkResult.status === "rejected") {
      setSaveError(`trusted proxy 配置接口未开放：${errorMessage(networkResult.reason)}。请使用 ${TRUSTED_PROXY_CONFIG_KEYS.join(" / ")}。`);
    }
  }

  useEffect(() => {
    void loadSettings(DEFAULT_PROJECT_ID);
  }, []);

  function handleProjectSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    void loadSettings(projectId);
  }

  function selectProfile(profileId: string) {
    const nextProfile = state.profiles.find((profile) => profile.id === profileId) ?? null;
    setSelectedProfileId(profileId);
    setProfileAllowlistText(entriesToText(jsonStringArray(nextProfile?.ip_allowlist)));
    setSaveError(null);
    setSaveSuccess(null);
  }

  async function saveProfileAllowlist(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();

    if (!selectedProfile) {
      setSaveError("请选择一个配置档案后再保存 IP allowlist。");
      return;
    }
    if (!profileValidation.valid) {
      setSaveError(`配置档案 allowlist 无法保存：${profileValidation.errors.join("；")}`);
      return;
    }

    setSavingProfile(true);
    setSaveError(null);
    setSaveSuccess(null);

    try {
      const updated = await patchApiKeyProfile(selectedProfile.id, {
        ip_allowlist: profileValidation.entries,
      });
      setState((current) => ({
        ...current,
        profiles: current.profiles.map((profile) => (profile.id === updated.id ? updated : profile)),
      }));
      const readbackEntries = jsonStringArray(updated.ip_allowlist);
      setProfileAllowlistText(entriesToText(readbackEntries));
      setSaveSuccess(`配置档案 IP allowlist 已保存并读回 ${readbackEntries.length} 个条目；新请求鉴权立即按该 profile 收紧，已签发 key 不会回显 secret。`);
    } catch (requestError) {
      setSaveError(errorMessage(requestError));
    } finally {
      setSavingProfile(false);
    }
  }

  async function saveTrustedProxy(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();

    if (!proxyValidation.valid) {
      setSaveError(`trusted proxy allowlist 无法提交：${proxyValidation.errors.join("；")}`);
      return;
    }

    setSavingProxy(true);
    setSaveError(null);
    setSaveSuccess(null);

    try {
      const updated = await patchNetworkSecuritySettings({
        trusted_proxy_allowlist: proxyValidation.entries,
      });
      setState((current) => ({
        ...current,
        network: updated,
        trustedProxyConfigNeeded: updated.status === "config-needed",
      }));
      setSaveSuccess(updated.action_result ?? updated.next_action);
    } catch (requestError) {
      setSaveError(
        `trusted proxy 当前需要配置文件或环境接入后生效：${errorMessage(requestError)}。推荐键：${TRUSTED_PROXY_CONFIG_KEYS.join(" / ")}。`,
      );
    } finally {
      setSavingProxy(false);
    }
  }

  const profileRows = state.profiles.map((profile) => ({
    count: jsonStringArray(profile.ip_allowlist).length,
    id: profile.id,
    name: safeFieldValue(profile.name),
    status: profile.status,
  }));
  const keyRows = state.virtualKeys.map((key) => ({
    count: jsonStringArray(key.ip_allowlist).length,
    id: key.id,
    name: safeFieldValue(key.name),
    prefix: safeFieldValue(key.key_prefix),
    status: key.status,
  }));
  const statusRows = settingsStatusRows({
    healthSummary: state.healthSummary,
    keyRows,
    network: state.network,
    paymentPlans: state.paymentPlans,
    profileRows,
    serviceProbes: state.serviceProbes,
    trustedProxyConfigNeeded: state.trustedProxyConfigNeeded,
  });

  return (
    <div className="admin-page" aria-label="Admin Settings">
      <section className="admin-panel" aria-label="网络安全设置摘要">
        <SectionHeader
          title="Settings"
          description="集中查看 Network Security、本地 setup seed、provider config 和 payment config 的状态；页面只展示配置键、状态和下一步。"
        />
        <div className="metric-grid">
          {statusRows.slice(0, 4).map((row) => (
            <NetworkSecurityTile key={row.id} label={row.label} value={row.status} detail={row.detail} />
          ))}
        </div>
        <form className="toolbar-row" onSubmit={handleProjectSubmit}>
          <Field label="项目 ID">
            <input value={projectId} onChange={(event) => setProjectId(event.target.value)} />
          </Field>
          <ActionButton disabled={state.loading} icon={<RefreshCw size={16} />} type="submit">
            刷新
          </ActionButton>
        </form>
        {state.error ? <p className="error-text">{state.error}</p> : null}
        {saveError ? <p className="error-text">{saveError}</p> : null}
        {saveSuccess ? <p className="success-text">{saveSuccess}</p> : null}
      </section>

      <nav className="toolbar-row" aria-label="Settings tabs">
        <button
          type="button"
          className={`tab-button${activeTab === "overview" ? " tab-button--active" : ""}`}
          onClick={() => setActiveTab("overview")}
        >
          总览
        </button>
        <button
          type="button"
          className={`tab-button${activeTab === "network" ? " tab-button--active" : ""}`}
          onClick={() => setActiveTab("network")}
        >
          Network Security
        </button>
        <button
          type="button"
          className={`tab-button${activeTab === "config" ? " tab-button--active" : ""}`}
          onClick={() => setActiveTab("config")}
        >
          Config Status
        </button>
      </nav>

      {activeTab === "overview" ? (
        <SettingsOverview statusRows={statusRows} />
      ) : activeTab === "config" ? (
        <SettingsConfigStatus statusRows={statusRows} />
      ) : (
        <NetworkSecurityEditor
          keyRows={keyRows}
          profileAllowlistText={profileAllowlistText}
          profileRows={profileRows}
          profileValidation={profileValidation}
          proxyValidation={proxyValidation}
          savingProfile={savingProfile}
          savingProxy={savingProxy}
          selectedProfileId={selectedProfileId}
          state={state}
          trustedProxyText={trustedProxyText}
          onProfileAllowlistChange={setProfileAllowlistText}
          onProxyTextChange={setTrustedProxyText}
          onSaveProfileAllowlist={saveProfileAllowlist}
          onSaveTrustedProxy={saveTrustedProxy}
          onSelectProfile={selectProfile}
        />
      )}
    </div>
  );
}

type NetworkSecurityEditorProps = {
  keyRows: CountRow[];
  profileAllowlistText: string;
  profileRows: CountRow[];
  profileValidation: AllowlistValidation;
  proxyValidation: AllowlistValidation;
  savingProfile: boolean;
  savingProxy: boolean;
  selectedProfileId: string;
  state: LoadState;
  trustedProxyText: string;
  onProfileAllowlistChange: (value: string) => void;
  onProxyTextChange: (value: string) => void;
  onSaveProfileAllowlist: (event: FormEvent<HTMLFormElement>) => void;
  onSaveTrustedProxy: (event: FormEvent<HTMLFormElement>) => void;
  onSelectProfile: (profileId: string) => void;
};

function NetworkSecurityEditor({
  keyRows,
  profileAllowlistText,
  profileRows,
  profileValidation,
  proxyValidation,
  savingProfile,
  savingProxy,
  selectedProfileId,
  state,
  trustedProxyText,
  onProfileAllowlistChange,
  onProxyTextChange,
  onSaveProfileAllowlist,
  onSaveTrustedProxy,
  onSelectProfile,
}: NetworkSecurityEditorProps) {
  return (
    <>
      <section className="admin-panel" aria-label="网络安全详情">
        <SectionHeader
          title="IP allowlist / trusted proxy"
          description="集中查看 API key/profile 的来源 IP 限制，并确认网关信任哪些反向代理传入的 X-Forwarded-For / X-Real-IP。"
        />
        <div className="metric-grid">
          <NetworkSecurityTile label="配置档案" value={`${profileRows.length}`} detail={`${configuredCount(profileRows)} 个已限制`} />
          <NetworkSecurityTile label="API key" value={`${keyRows.length}`} detail={`${configuredCount(keyRows)} 个已限制`} />
          <NetworkSecurityTile
            label="trusted proxy"
            value={state.network?.status ?? (state.trustedProxyConfigNeeded ? "config-needed" : "pending")}
            detail={trustedProxyDetail(state.network, state.trustedProxyConfigNeeded)}
          />
        </div>
      </section>

      <section className="admin-panel" aria-label="network security example handoff">
        <SectionHeader
          title="Network security example"
          description="给前端和本地部署使用的示例生成器；示例只含文档网段，不含真实生产 IP、provider key、Authorization 或其他 secret。"
        />
        <div className="detail-list">
          <div>
            <span>脚本</span>
            <strong>{state.network?.example_generator?.script_path ?? NETWORK_SECURITY_EXAMPLE_SCRIPT}</strong>
          </div>
          <div>
            <span>默认输出</span>
            <strong>{state.network?.example_generator?.default_output_path ?? NETWORK_SECURITY_EXAMPLE_OUTPUT}</strong>
          </div>
          <div>
            <span>PrintOnly</span>
            <strong>
              {state.network?.example_generator?.print_only_behavior ??
                "加 -PrintOnly 时只输出到 stdout，不创建或覆盖文件。"}
            </strong>
          </div>
          <div>
            <span>示例地址策略</span>
            <strong>
              {state.network?.example_generator?.example_address_policy ??
                "RFC5737 IPv4 and RFC3849 IPv6 documentation ranges only"}
            </strong>
          </div>
        </div>
      </section>

      <section className="admin-panel" aria-label="配置档案 IP allowlist 编辑">
        <SectionHeader
          title="配置档案 IP allowlist"
          description="Profile allowlist 会在 key allowlist 之后继续收紧，不能扩大单个 API key 的允许来源。"
        />
        {state.profiles.length === 0 ? (
          <EmptyState title="没有可编辑配置档案" detail="先在 API 密钥页创建 profile，再回到这里配置来源 IP 限制。" />
        ) : (
          <form className="settings-grid" onSubmit={onSaveProfileAllowlist}>
            <Field label="配置档案">
              <select value={selectedProfileId} onChange={(event) => onSelectProfile(event.target.value)}>
                {state.profiles.map((profile) => (
                  <option key={profile.id} value={profile.id}>
                    {profile.name} · {profile.status}
                  </option>
                ))}
              </select>
            </Field>
            <Field label="允许来源 IP / CIDR">
              <textarea
                rows={7}
                value={profileAllowlistText}
                onChange={(event) => onProfileAllowlistChange(event.target.value)}
                placeholder={"203.0.113.10\n198.51.100.0/24\n2001:db8::/64"}
              />
            </Field>
            <AllowlistHint validation={profileValidation} emptyText="空列表表示 profile 不额外收紧来源 IP。" />
            <ActionButton
              disabled={savingProfile || !profileValidation.valid}
              icon={<Save size={16} />}
              type="submit"
              variant="primary"
            >
              保存 profile allowlist
            </ActionButton>
          </form>
        )}
      </section>

      <section className="admin-panel" aria-label="trusted proxy 配置">
        <SectionHeader
          title="trusted proxy allowlist"
          description="只有来自这些代理 IP/CIDR 的转发头会参与真实 client IP 判定；该配置不包含 secret。"
        />
        <form className="settings-grid" onSubmit={onSaveTrustedProxy}>
          <Field label="当前 / 目标代理 IP 或 CIDR">
            <textarea
              rows={6}
              value={trustedProxyText}
              onChange={(event) => onProxyTextChange(event.target.value)}
              placeholder={"10.0.0.0/8\n192.168.0.0/16\n2001:db8:ffff::/64"}
            />
          </Field>
          <AllowlistHint validation={proxyValidation} emptyText="空列表表示不信任转发头，网关使用直连 peer IP。" />
          <div className="detail-list">
            <div>
              <span>生效范围</span>
              <strong>Gateway 运行时 client IP 解析；影响后续鉴权、日志和 profile/key allowlist 判断。</strong>
            </div>
            <div>
              <span>配置键</span>
              <strong>{state.network ? configKeyText(state.network) : TRUSTED_PROXY_CONFIG_KEYS.join(" / ")}</strong>
            </div>
          <div>
            <span>保存状态</span>
            <strong>{state.network?.hot_reload_supported ? "可热更新" : "config-needed：需要写入配置并重启/重载 gateway"}</strong>
          </div>
          {state.network?.requested_trusted_proxy_allowlist_count !== undefined ? (
            <div>
              <span>提交摘要</span>
              <strong>{state.network.requested_trusted_proxy_allowlist_count} 个 trusted proxy 条目已识别，等待配置文件应用。</strong>
            </div>
          ) : null}
        </div>
          <ActionButton disabled={savingProxy || !proxyValidation.valid} icon={<Shield size={16} />} type="submit">
            提交 trusted proxy 配置
          </ActionButton>
        </form>
      </section>

      <AllowlistHandoffPanel settings={state.network} />

      <section className="admin-panel" aria-label="allowlist 当前覆盖面">
        <SectionHeader
          title="当前 IP allowlist 覆盖"
          description="API key 级 allowlist 已安全只读展示；后端尚未提供 key 级 patch 时请通过新建或轮换 key 调整。"
        />
        <DataTable aria-label="配置档案 allowlist">
          <thead>
            <tr>
              <th>Profile</th>
              <th>状态</th>
              <th>条目数</th>
              <th>编辑</th>
            </tr>
          </thead>
          <tbody>
            {profileRows.map((row) => (
              <tr key={row.id}>
                <td>{row.name}</td>
                <td>
                  <StatusChip tone={row.status === "active" ? "good" : "warn"}>{row.status}</StatusChip>
                </td>
                <td>{row.count}</td>
                <td>
                  <ActionButton variant="table" onClick={() => onSelectProfile(row.id)}>
                    载入
                  </ActionButton>
                </td>
              </tr>
            ))}
          </tbody>
        </DataTable>
        <DataTable aria-label="API key allowlist">
          <thead>
            <tr>
              <th>API key</th>
              <th>前缀</th>
              <th>状态</th>
              <th>条目数</th>
              <th>下一步</th>
            </tr>
          </thead>
          <tbody>
            {keyRows.map((row) => (
              <tr key={row.id}>
                <td>{row.name}</td>
                <td>{row.prefix}</td>
                <td>
                  <StatusChip tone={row.status === "active" ? "good" : "warn"}>{row.status}</StatusChip>
                </td>
                <td>{row.count}</td>
                <td>key 级 patch 未开放；创建新 key 或使用 profile allowlist 收紧。</td>
              </tr>
            ))}
          </tbody>
        </DataTable>
      </section>
    </>
  );
}

type CountRow = {
  count: number;
  id: string;
  name: string;
  prefix?: string;
  status: string;
};

type SettingsStatusRow = {
  configKeys: string[];
  detail: string;
  id: string;
  label: string;
  nextStep: string;
  status: "configured" | "config-needed" | "pending" | "no-signal";
};

type LocalMvpCommand = {
  command: string;
  envVars: string[];
  id: string;
  purpose: string;
  title: string;
  usage: string;
};

function SettingsOverview({ statusRows }: { statusRows: SettingsStatusRow[] }) {
  return (
    <section className="admin-panel" aria-label="Settings overview">
      <SectionHeader
        title="Settings 总览"
        description="Admin 可以从这里先判断缺哪类配置，再进入对应工作台处理；敏感值不会在页面渲染。"
      />
      <DataTable aria-label="Settings status overview">
        <thead>
          <tr>
            <th>区域</th>
            <th>状态</th>
            <th>配置键</th>
            <th>当前信号</th>
            <th>下一步</th>
          </tr>
        </thead>
        <tbody>
          {statusRows.map((row) => (
            <tr key={row.id}>
              <td>{row.label}</td>
              <td>
                <StatusChip tone={settingsStatusTone(row.status)}>{row.status}</StatusChip>
              </td>
              <td>{row.configKeys.join(" / ")}</td>
              <td>{row.detail}</td>
              <td>{row.nextStep}</td>
            </tr>
          ))}
        </tbody>
      </DataTable>
    </section>
  );
}

function SettingsConfigStatus({ statusRows }: { statusRows: SettingsStatusRow[] }) {
  const [copiedCommandId, setCopiedCommandId] = useState<string | null>(null);

  async function copyCommand(command: LocalMvpCommand) {
    await writeClipboard(command.command);
    setCopiedCommandId(command.id);
  }

  return (
    <>
      <section className="admin-panel bootstrap-guide" aria-label="Local MVP command entrypoints">
        <SectionHeader
          title="本地 MVP 命令入口"
          description="这些命令只给本地开发者复制到 shell 执行；页面不会执行命令，也不是 production gate。"
        />
        <div className="setup-sequence">
          {LOCAL_MVP_COMMANDS.map((command, index) => (
            <article className="setup-step setup-step--pending" key={command.id}>
              <div className="setup-step-index">{index + 1}</div>
              <div className="setup-step-body">
                <div className="setup-step-heading">
                  <div>
                    <strong>{command.title}</strong>
                    <p>{command.purpose}</p>
                  </div>
                  <StatusChip tone="neutral">local-only</StatusChip>
                </div>
                <div className="env-hint-grid" aria-label={`${command.title} env vars`}>
                  {command.envVars.map((envVar) => (
                    <span key={envVar}>{envVar}</span>
                  ))}
                </div>
                <div className="bootstrap-command-row">
                  <code>{command.command}</code>
                  <button className="secondary-button" type="button" onClick={() => void copyCommand(command)}>
                    <Copy aria-hidden="true" size={16} />
                    {copiedCommandId === command.id ? "已复制" : "复制"}
                  </button>
                </div>
                <p className="muted-copy">{command.usage}</p>
              </div>
            </article>
          ))}
        </div>
        <p className="muted-copy">
          Secret 边界：不要在页面、截图或 artifact 中展示 <code>ADMIN_PASSWORD</code>、<code>GATEWAY_AUTH_TOKEN</code>、
          provider key、Authorization header、voucher raw code 或请求 payload。
        </p>
      </section>

      <section className="admin-panel" aria-label="Config needed status">
        <SectionHeader
          title="Config Status"
          description="仅列出 config key 名、状态和下一步；provider key、Authorization、payment secret、raw payload 均不展示。"
        />
        <div className="setup-sequence">
          {statusRows.map((row, index) => (
            <article className={`setup-step setup-step--${setupStepStatus(row.status)}`} key={row.id}>
              <div className="setup-step-index">{index + 1}</div>
              <div className="setup-step-body">
                <div className="setup-step-heading">
                  <div>
                    <strong>{row.label}</strong>
                    <p>{row.configKeys.join(" / ")}</p>
                  </div>
                  <StatusChip tone={settingsStatusTone(row.status)}>{row.status}</StatusChip>
                </div>
                <div className="setup-step-footer">
                  <span>{row.detail}</span>
                  <strong>{row.nextStep}</strong>
                </div>
              </div>
            </article>
          ))}
        </div>
      </section>
    </>
  );
}

function AllowlistHandoffPanel({ settings }: { settings: NetworkSecuritySettings | null }) {
  const handoff = settings?.allowlist_handoff;

  if (!handoff) {
    return null;
  }

  return (
    <section className="admin-panel" aria-label="allowlist 字段能力 handoff">
      <SectionHeader
        title="Allowlist handoff"
        description="字段级能力边界：哪些可由 UI 直接保存，哪些只读展示，哪些必须进入配置文件并重启或重载。"
      />
      <DataTable aria-label="allowlist editable and config file fields">
        <thead>
          <tr>
            <th>字段</th>
            <th>能力</th>
            <th>路径</th>
            <th>生效说明</th>
          </tr>
        </thead>
        <tbody>
          {handoff.editable_fields.map((field) => (
            <tr key={`editable-${field.field}`}>
              <td>{field.field}</td>
              <td>
                <StatusChip tone="good">UI editable</StatusChip>
              </td>
              <td>{field.apply_path} / {field.readback_path}</td>
              <td>{field.effect}</td>
            </tr>
          ))}
          {handoff.read_only_fields.map((field) => (
            <tr key={`readonly-${field.field}`}>
              <td>{field.field}</td>
              <td>
                <StatusChip tone="neutral">readback only</StatusChip>
              </td>
              <td>{field.readback_path} / {field.change_path}</td>
              <td>{field.effect}</td>
            </tr>
          ))}
          {handoff.config_file_fields.map((field) => (
            <tr key={`config-${field.field}`}>
              <td>{field.field}</td>
              <td>
                <StatusChip tone="warn">{field.restart_required ? "config file + restart" : "config file"}</StatusChip>
              </td>
              <td>{field.config_path_env} / {field.patch_path}</td>
              <td>{field.patch_behavior}</td>
            </tr>
          ))}
        </tbody>
      </DataTable>
    </section>
  );
}

export default NetworkSecuritySettingsPage;

function NetworkSecurityTile({ detail, label, value }: { detail: string; label: string; value: string }) {
  return (
    <article className="metric-tile">
      <span>{label}</span>
      <strong>{value}</strong>
      <small>{detail}</small>
    </article>
  );
}

function AllowlistHint({ emptyText, validation }: { emptyText: string; validation: AllowlistValidation }) {
  if (validation.errors.length > 0) {
    return <p className="error-text">{validation.errors.join("；")}</p>;
  }

  return (
    <p className="muted-copy">
      {validation.entries.length > 0
        ? `将保存 ${validation.entries.length} 个条目。支持单 IP、IPv4 CIDR /0-/32、IPv6 CIDR /0-/128。`
        : emptyText}
    </p>
  );
}

type AllowlistValidation = {
  entries: string[];
  errors: string[];
  valid: boolean;
};

function validateAllowlistText(value: string): AllowlistValidation {
  const entries = splitAllowlistText(value);
  const errors = entries
    .map((entry) => (isValidIpAllowlistEntry(entry) ? null : `${entry} 不是有效 IP 或 CIDR`))
    .filter((entry): entry is string => Boolean(entry));

  return {
    entries,
    errors,
    valid: errors.length === 0,
  };
}

function splitAllowlistText(value: string): string[] {
  return Array.from(
    new Set(
      value
        .split(/[\n,]/)
        .map((entry) => entry.trim())
        .filter(Boolean),
    ),
  );
}

function isValidIpAllowlistEntry(entry: string): boolean {
  const [address, prefix, extra] = entry.split("/");
  if (!address || extra !== undefined) {
    return false;
  }

  const isIpv4 = isValidIpv4(address);
  const isIpv6 = !isIpv4 && isLikelyIpv6(address);

  if (!isIpv4 && !isIpv6) {
    return false;
  }

  if (prefix === undefined) {
    return true;
  }

  if (!/^\d+$/.test(prefix)) {
    return false;
  }

  const prefixNumber = Number(prefix);
  return isIpv4 ? prefixNumber >= 0 && prefixNumber <= 32 : prefixNumber >= 0 && prefixNumber <= 128;
}

function isValidIpv4(value: string): boolean {
  const parts = value.split(".");
  return (
    parts.length === 4 &&
    parts.every((part) => /^\d{1,3}$/.test(part) && Number(part) >= 0 && Number(part) <= 255 && String(Number(part)) === part)
  );
}

function isLikelyIpv6(value: string): boolean {
  if (!value.includes(":") || value.includes(":::")) {
    return false;
  }

  const compressionCount = value.includes("::") ? 1 : 0;
  if (compressionCount > 1) {
    return false;
  }

  const groups = value.split(":").filter((group) => group.length > 0);
  if (groups.length > 8 || (!value.includes("::") && groups.length !== 8)) {
    return false;
  }

  return groups.every((group) => /^[0-9a-fA-F]{1,4}$/.test(group));
}

function jsonStringArray(value: JsonValue | undefined): string[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value.filter((entry): entry is string => typeof entry === "string").map((entry) => entry.trim()).filter(Boolean);
}

function entriesToText(entries: string[]): string {
  return entries.join("\n");
}

function configuredCount(rows: Array<{ count: number }>): number {
  return rows.filter((row) => row.count > 0).length;
}

function settingsStatusRows({
  healthSummary,
  keyRows,
  network,
  paymentPlans,
  profileRows,
  serviceProbes,
  trustedProxyConfigNeeded,
}: {
  healthSummary: HealthSummary | null;
  keyRows: CountRow[];
  network: NetworkSecuritySettings | null;
  paymentPlans: SubscriptionPlan[];
  profileRows: CountRow[];
  serviceProbes: ProbeResult[];
  trustedProxyConfigNeeded: boolean;
}): SettingsStatusRow[] {
  const trustedProxyStatus = network?.status === "configured" ? "configured" : trustedProxyConfigNeeded ? "config-needed" : "pending";
  const allowlistConfigured = configuredCount(profileRows) + configuredCount(keyRows);
  const setupOnline = serviceProbes.filter((probe) => probe.status === "online").length;
  const setupOffline = serviceProbes.filter((probe) => probe.status === "offline").length;
  const providerConfig = providerConfigStatus(healthSummary);
  const paymentConfig = paymentConfigStatus(paymentPlans);

  return [
    {
      configKeys: [...TRUSTED_PROXY_CONFIG_KEYS, NETWORK_SECURITY_EXAMPLE_SCRIPT, NETWORK_SECURITY_EXAMPLE_OUTPUT],
      detail: trustedProxyDetail(network, trustedProxyConfigNeeded),
      id: "trusted-proxy",
      label: "Trusted proxy",
      nextStep:
        trustedProxyStatus === "configured"
          ? "保持配置与反向代理出口一致；变更后确认 client IP readback。"
          : "写入 AI_GATEWAY_CONFIG 中的 server.trusted_proxy_allowlist，并重启或热更新 gateway。",
      status: trustedProxyStatus,
    },
    {
      configKeys: ["api_key.ip_allowlist", "api_key_profile.ip_allowlist"],
      detail: `${allowlistConfigured} 个 key/profile 已限制；${profileRows.length} 个 profile / ${keyRows.length} 个 API key 可见`,
      id: "ip-allowlist",
      label: "IP allowlist",
      nextStep:
        allowlistConfigured > 0
          ? "继续在 Network Security tab 复核 profile allowlist；key 级调整通过新建或轮换 key。"
          : "先为默认 profile 添加来源 IP/CIDR，再按需要创建更严格的 API key。",
      status: allowlistConfigured > 0 ? "configured" : profileRows.length + keyRows.length > 0 ? "config-needed" : "pending",
    },
    {
      configKeys: SETUP_SEED_CONFIG_KEYS,
      detail:
        serviceProbes.length > 0
          ? `${setupOnline} 个本地探针在线 / ${setupOffline} 个离线`
          : "没有本地探针信号；等待 control-plane/gateway readback",
      id: "local-setup",
      label: "Local setup seed",
      nextStep:
        setupOffline > 0 || serviceProbes.length === 0
          ? "运行 scripts/setup_local_mvp.ps1 或 dev_up.ps1，确认 admin/mock provider/default model/test key seed。"
          : "本地服务可读；继续检查 provider、model、key 和 gateway 调用路径。",
      status: setupOffline > 0 ? "config-needed" : serviceProbes.length > 0 ? "configured" : "pending",
    },
    {
      configKeys: PROVIDER_CONFIG_KEYS,
      detail: providerConfig.detail,
      id: "provider-config",
      label: "Provider config",
      nextStep: providerConfig.nextStep,
      status: providerConfig.status,
    },
    {
      configKeys: PAYMENT_CONFIG_KEYS,
      detail: paymentConfig.detail,
      id: "payment-config",
      label: "Payment/provider config",
      nextStep: paymentConfig.nextStep,
      status: paymentConfig.status,
    },
  ];
}

function providerConfigStatus(summary: HealthSummary | null): Pick<SettingsStatusRow, "detail" | "nextStep" | "status"> {
  if (!summary) {
    return {
      detail: "provider health summary 未返回",
      nextStep: "打开 Providers 工作台或检查 control-plane /admin/providers/health-summary。",
      status: "pending",
    };
  }

  const enabledProviders = summary.providers.filter((provider) => provider.status === "enabled").length;
  const enabledChannels = summary.channels.filter((channel) => channel.status === "enabled").length;
  const configuredKeys = summary.provider_keys.filter((key) => key.credential_configured).length;
  const routableModels = summary.models.filter((model) => model.routing_state === "routable").length;
  const detail = `${enabledProviders} provider / ${enabledChannels} channel / ${configuredKeys} key / ${routableModels} routable model`;

  if (enabledProviders > 0 && enabledChannels > 0 && configuredKeys > 0 && routableModels > 0) {
    return {
      detail,
      nextStep: "运行 Routing dry-run 或 Gateway smoke，确认请求能进入目标通道。",
      status: "configured",
    };
  }

  return {
    detail,
    nextStep: "按 provider -> channel -> provider key -> model mapping 补齐；密钥只在一次性输入框提交。",
    status: summary.totals.providers > 0 || summary.totals.channels > 0 ? "config-needed" : "pending",
  };
}

function paymentConfigStatus(plans: SubscriptionPlan[]): Pick<SettingsStatusRow, "detail" | "nextStep" | "status"> {
  if (plans.length === 0) {
    return {
      detail: "没有 subscription plan/payment demo 信号",
      nextStep: "在 Billing 创建本地 demo plan 或保持 not_connected，占位不需要真实商户 secret。",
      status: "pending",
    };
  }

  const activePlans = plans.filter((plan) => plan.status === "active").length;
  const notConnected = plans.filter((plan) => plan.payment_status === "not_connected").length;
  const pendingSchedulers = plans.filter((plan) => plan.scheduler_status === "pending_scheduler").length;

  return {
    detail: `${activePlans} active plan；${notConnected} payment not_connected；${pendingSchedulers} pending scheduler`,
    nextStep:
      notConnected > 0 || pendingSchedulers > 0
        ? "本地 demo 可继续；接真实支付前补 merchant provider、callback 和 scheduler。"
        : "保持 payment readback secret-safe，并用 Billing 请求详情核对 ledger refs。",
    status: activePlans > 0 && notConnected === 0 && pendingSchedulers === 0 ? "configured" : "config-needed",
  };
}

function settingsStatusTone(status: SettingsStatusRow["status"]): "good" | "neutral" | "warn" | "danger" {
  if (status === "configured") {
    return "good";
  }
  if (status === "config-needed") {
    return "warn";
  }
  if (status === "no-signal") {
    return "neutral";
  }
  return "neutral";
}

function setupStepStatus(status: SettingsStatusRow["status"]): ProbeResult["status"] {
  if (status === "configured") {
    return "online";
  }
  if (status === "config-needed") {
    return "offline";
  }
  return "pending";
}

function trustedProxyDetail(settings: NetworkSecuritySettings | null, configNeeded: boolean): string {
  if (settings) {
    return `${settings.effective_trusted_proxy_allowlist.length} 个代理条目；${settings.hot_reload_supported ? "可热更新" : "需配置重载"}`;
  }

  return configNeeded ? "config-needed：后端 settings/readback 未开放" : "等待读取";
}

function configKeyText(settings: NetworkSecuritySettings): string {
  return `${settings.config_keys.config_path_env} / ${settings.config_keys.trusted_proxy_allowlist}`;
}

function firstRejectedError(results: PromiseSettledResult<unknown>[]): string | undefined {
  const rejected = results.find((result): result is PromiseRejectedResult => result.status === "rejected");
  return rejected ? errorMessage(rejected.reason) : undefined;
}

async function writeClipboard(value: string): Promise<void> {
  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(value);
    } catch {
      // Clipboard is a convenience on this read-only page.
    }
  }
}
