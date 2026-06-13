import { FormEvent, useEffect, useState } from "react";
import {
  type ApiKeyProfile,
  type ApiKeyProfileStatus,
  type BulkVirtualKeyLeakActionResult,
  bulkVirtualKeyLeakAction,
  createApiKeyProfile,
  createVirtualKey,
  deleteApiKeyProfile,
  disableVirtualKey,
  expireVirtualKey,
  getVirtualKey,
  type JsonValue,
  listApiKeyProfiles,
  listVirtualKeys,
  listVirtualKeyLeakCandidates,
  type PatchApiKeyProfileRequest,
  patchApiKeyProfile,
  type VirtualKey,
  type VirtualKeyLeakCandidate,
  type VirtualKeyLeakAction,
  type VirtualKeyStatus,
} from "../../api/client";
import {
  StateChip,
  errorMessage,
  formatStatus,
  isJsonRecord,
  jsonSize,
  parseSafeMetadata,
  parseSafeJsonObject,
  parseSafeJsonValue,
  safeFieldValue,
  sanitizeDisplayJson,
  shortId,
} from "../../components/adminUtils";
import { Clock, Edit3, Eye, Plus, RefreshCw, Save, Search, ShieldOff, Trash2, X } from "../../components/icons";
import { DataTable, type DataTableColumn } from "../../design/DataTable";
import { summarizeTableBulkAction } from "../../design/tableState";
import type { ApiKeysFocusTarget } from "../../app/types";

type Tab = "virtualKeys" | "profiles";

type VirtualKeyCreateForm = {
  budgetPolicy: string;
  defaultProfileId: string;
  ipAllowlist: string;
  metadata: string;
  name: string;
  projectId: string;
  rateLimitPolicy: string;
  status: VirtualKeyStatus;
};

type ProfileCreateForm = {
  allowedModels: string;
  deniedModels: string;
  ipAllowlist: string;
  modelAliases: string;
  name: string;
  projectId: string;
  status: ApiKeyProfileStatus;
};

type ProfileEditForm = {
  allowedModels: string;
  deniedModels: string;
  ipAllowlist: string;
  modelAliases: string;
  name: string;
  status: ApiKeyProfileStatus;
};

type CreatedKeyNotice = {
  keyId: string;
  keyPrefix: string;
  name: string;
  status: VirtualKeyStatus;
};

type FocusNotice = {
  tone: "info" | "warn";
  message: string;
};

const DEFAULT_PROJECT_ID = "00000000-0000-0000-0000-000000000020";
const leakActionLabels: Record<VirtualKeyLeakAction, string> = {
  disable: "停用",
  revoke: "吊销",
  suspected_leaked: "标记疑似泄露",
};
const profileStatuses: ApiKeyProfileStatus[] = ["active", "disabled", "deleted"];
const virtualKeyStatuses: VirtualKeyStatus[] = ["active", "disabled", "expired", "deleted"];
const virtualKeyStatusFilters = ["", ...virtualKeyStatuses];
const JSON_ERROR_SUFFIX = " must be valid JSON.";
const virtualKeyTableColumns: DataTableColumn[] = [
  { id: "selection", label: "选择", locked: true },
  { id: "name", label: "名称", locked: true },
  { id: "status", label: "状态" },
  { id: "project", label: "项目" },
  { id: "profile", label: "默认配置档案" },
  { id: "prefix", label: "前缀" },
  { id: "policy", label: "策略" },
  { id: "credential", label: "凭证" },
  { id: "actions", label: "操作", locked: true },
];
const defaultVisibleVirtualKeyColumns = virtualKeyTableColumns.map((column) => column.id);

const defaultVirtualKeyCreateForm: VirtualKeyCreateForm = {
  budgetPolicy: "{}",
  defaultProfileId: "",
  ipAllowlist: "[]",
  metadata: "{}",
  name: "",
  projectId: DEFAULT_PROJECT_ID,
  rateLimitPolicy: "{}",
  status: "active",
};

const defaultProfileCreateForm: ProfileCreateForm = {
  allowedModels: "[]",
  deniedModels: "[]",
  ipAllowlist: "[]",
  modelAliases: "{}",
  name: "",
  projectId: DEFAULT_PROJECT_ID,
  status: "active",
};

export function VirtualKeysPage({
  focusTarget,
  onClearFocus,
}: {
  focusTarget?: ApiKeysFocusTarget | null;
  onClearFocus?: () => void;
} = {}) {
  const [activeTab, setActiveTab] = useState<Tab>("virtualKeys");

  useEffect(() => {
    if (focusTarget?.keyId || focusTarget?.projectId || focusTarget?.status) {
      setActiveTab("virtualKeys");
    }
  }, [focusTarget]);

  return (
    <div className="admin-page" aria-label="API 密钥和配置档案">
      <div className="tab-list" role="tablist" aria-label="密钥管理分区">
        <button
          aria-selected={activeTab === "virtualKeys"}
          className={`tab-button${activeTab === "virtualKeys" ? " tab-button--active" : ""}`}
          onClick={() => setActiveTab("virtualKeys")}
          role="tab"
          type="button"
        >
          API 密钥
        </button>
        <button
          aria-selected={activeTab === "profiles"}
          className={`tab-button${activeTab === "profiles" ? " tab-button--active" : ""}`}
          onClick={() => setActiveTab("profiles")}
          role="tab"
          type="button"
        >
          配置档案
        </button>
      </div>

      {activeTab === "virtualKeys" ? (
        <VirtualKeysSection focusTarget={focusTarget} onClearFocus={onClearFocus} />
      ) : (
        <ProfilesSection />
      )}
    </div>
  );
}

export default VirtualKeysPage;

function VirtualKeysSection({
  focusTarget,
  onClearFocus,
}: {
  focusTarget?: ApiKeysFocusTarget | null;
  onClearFocus?: () => void;
}) {
  const [activeFocus, setActiveFocus] = useState<ApiKeysFocusTarget | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [createForm, setCreateForm] = useState<VirtualKeyCreateForm>(defaultVirtualKeyCreateForm);
  const [createdKeyNotice, setCreatedKeyNotice] = useState<CreatedKeyNotice | null>(null);
  const [detail, setDetail] = useState<VirtualKey | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [focusNotice, setFocusNotice] = useState<FocusNotice | null>(null);
  const [keys, setKeys] = useState<VirtualKey[]>([]);
  const [leakCandidates, setLeakCandidates] = useState<VirtualKeyLeakCandidate[]>([]);
  const [loading, setLoading] = useState(false);
  const [openCreateDialog, setOpenCreateDialog] = useState(false);
  const [projectId, setProjectId] = useState(DEFAULT_PROJECT_ID);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [selectedKeyIds, setSelectedKeyIds] = useState<string[]>([]);
  const [statusFilter, setStatusFilter] = useState("");
  const [success, setSuccess] = useState<string | null>(null);
  const [visibleVirtualKeyColumns, setVisibleVirtualKeyColumns] = useState(defaultVisibleVirtualKeyColumns);
  const [bulkAction, setBulkAction] = useState<VirtualKeyLeakAction>("suspected_leaked");
  const [bulkBusy, setBulkBusy] = useState(false);
  const [bulkReason, setBulkReason] = useState("");
  const [bulkResults, setBulkResults] = useState<BulkVirtualKeyLeakActionResult[]>([]);

  async function loadKeys(nextProjectId = projectId, nextStatus = statusFilter): Promise<VirtualKey[]> {
    const trimmedProjectId = nextProjectId.trim();

    if (!trimmedProjectId) {
      setError("需要填写项目 ID 才能加载 API 密钥。");
      setKeys([]);
      return [];
    }

    setError(null);
    setLoading(true);

    try {
      const loadedKeys = await listVirtualKeys({
        project_id: trimmedProjectId,
        status: nextStatus || undefined,
      });
      const leakCandidateReadback = await listVirtualKeyLeakCandidates({
        project_id: trimmedProjectId,
        status: nextStatus || undefined,
      });
      setKeys(loadedKeys);
      setLeakCandidates(leakCandidateReadback.leak_candidates);
      setSelectedKeyIds((current) => current.filter((id) => loadedKeys.some((key) => key.id === id)));
      return loadedKeys;
    } catch (requestError) {
      setError(errorMessage(requestError));
      setKeys([]);
      setLeakCandidates([]);
      setSelectedKeyIds([]);
      return [];
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    void loadKeys(DEFAULT_PROJECT_ID, "");
  }, []);

  useEffect(() => {
    if (!focusTarget) {
      setActiveFocus(null);
      setFocusNotice(null);
      return;
    }

    const nextFocus = normalizeApiKeysFocusTarget(focusTarget);

    if (!hasApiKeysFocusTarget(nextFocus)) {
      setActiveFocus(null);
      setFocusNotice(null);
      return;
    }

    const nextProjectId = nextFocus.projectId?.trim();
    const nextStatus = nextFocus.status?.trim() ?? "";
    const nextKeyId = nextFocus.keyId?.trim();

    setActiveFocus(nextFocus);
    setFocusNotice({ tone: "info", message: "已接收安全跳转目标，列表会按 key id/prefix、项目或状态定位 API 密钥。" });

    if (nextProjectId) {
      setProjectId(nextProjectId);
      setStatusFilter(nextStatus);
      void loadKeys(nextProjectId, nextStatus);
    } else if (nextStatus) {
      setStatusFilter(nextStatus);
    }

    if (nextKeyId) {
      void focusKeyDetail(nextKeyId, nextProjectId, nextStatus);
    }
  }, [focusTarget]);

  function clearFocus() {
    setActiveFocus(null);
    setFocusNotice(null);
    onClearFocus?.();
  }

  function handleFilterSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    void loadKeys(projectId, statusFilter);
  }

  async function handleCreate(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setCreatedKeyNotice(null);
    setError(null);
    setSuccess(null);

    const nextProjectId = createForm.projectId.trim();

    try {
      const created = await createVirtualKey({
        budget_policy: parseSafeJsonObject(createForm.budgetPolicy, "预算策略"),
        default_profile_id: createForm.defaultProfileId.trim(),
        ip_allowlist: parseSafeJsonArrayField(createForm.ipAllowlist, "IP 白名单"),
        metadata: parseSafeMetadata(createForm.metadata),
        name: createForm.name.trim(),
        project_id: nextProjectId,
        rate_limit_policy: parseSafeJsonObject(createForm.rateLimitPolicy, "速率限制策略"),
        status: createForm.status,
      });

      setCreatedKeyNotice({
        keyId: created.id,
        keyPrefix: created.key_prefix,
        name: created.name,
        status: created.status,
      });

      setCreateForm({
        ...defaultVirtualKeyCreateForm,
        projectId: nextProjectId,
      });
      setProjectId(nextProjectId);
      setSuccess("API 密钥已创建。");
      setOpenCreateDialog(false);
      await loadKeys(nextProjectId, statusFilter);
    } catch (requestError) {
      setError(errorMessage(requestError));
    }
  }

  async function handleDisable(key: VirtualKey) {
    setBusyId(key.id);
    setError(null);
    setSuccess(null);

    try {
      const updated = await disableVirtualKey(key.id);
      upsertKey(updated);
      setSuccess(`${safeFieldValue(key.name)} 已停用。`);
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setBusyId(null);
    }
  }

  async function handleExpire(key: VirtualKey) {
    setBusyId(key.id);
    setError(null);
    setSuccess(null);

    try {
      const updated = await expireVirtualKey(key.id);
      upsertKey(updated);
      setSuccess(`${safeFieldValue(key.name)} 已过期。`);
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setBusyId(null);
    }
  }

  async function handleView(key: VirtualKey) {
    setBusyId(key.id);
    setError(null);
    setSelectedId(key.id);

    try {
      setDetail(await getVirtualKey(key.id));
    } catch (requestError) {
      setError(errorMessage(requestError));
      setDetail(null);
    } finally {
      setBusyId(null);
    }
  }

  async function focusKeyDetail(keyId: string, fallbackProjectId?: string, fallbackStatus?: string) {
    setBusyId(keyId);
    setError(null);
    setSelectedId(keyId);

    try {
      const loaded = await getVirtualKey(keyId);
      setDetail(loaded);
      setProjectId(loaded.project_id);
      const loadedKeys = await loadKeys(loaded.project_id, fallbackStatus ?? statusFilter);
      const visible = loadedKeys.some((key) => key.id === loaded.id);
      setFocusNotice(
        visible
          ? { tone: "info", message: `已定位 API key ${safeFocusId(loaded.id)}，前缀 ${safeFieldValue(loaded.key_prefix)}。` }
          : {
              tone: "warn",
              message:
                "目标 API key 可读取但不在当前列表页。它可能被当前状态筛选排除，或不属于当前项目筛选；详情面板只显示 key id、prefix、project 和 status。",
            },
      );
      if (visible) {
        setSelectedKeyIds((current) => (current.includes(loaded.id) ? current : [...current, loaded.id]));
      }
    } catch (requestError) {
      setDetail(null);
      setError(errorMessage(requestError));
      if (fallbackProjectId) {
        const loadedKeys = await loadKeys(fallbackProjectId, fallbackStatus ?? statusFilter);
        setFocusNotice(focusNotFoundNotice(keyId, loadedKeys));
      } else {
        setFocusNotice(focusNotFoundNotice(keyId, keys));
      }
    } finally {
      setBusyId(null);
    }
  }

  function selectFocusedKey() {
    const keyId = activeFocus?.keyId?.trim();

    if (!keyId) {
      return;
    }

    if (!keys.some((key) => key.id === keyId)) {
      setFocusNotice({
        tone: "warn",
        message: "目标 key 不在当前列表页，不能加入批量操作。请清除状态筛选或确认项目筛选后再选择。",
      });
      return;
    }

    setSelectedKeyIds((current) => (current.includes(keyId) ? current : [...current, keyId]));
    setFocusNotice({ tone: "info", message: `已将目标 API key ${safeFocusId(keyId)} 加入批量操作选择。` });
  }

  async function handleBulkLeakAction(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();

    const reason = bulkReason.trim();

    if (selectedKeyIds.length === 0) {
      setError("请先选择至少一个 API 密钥。");
      return;
    }

    if (!reason) {
      setError("批量泄露处理必须填写 reason。");
      return;
    }

    const label = leakActionLabels[bulkAction];
    const confirmed = window.confirm(`确认对 ${selectedKeyIds.length} 个 API 密钥执行“${label}”？`);

    if (!confirmed) {
      return;
    }

    setBulkBusy(true);
    setError(null);
    setSuccess(null);

    try {
      const results = await bulkVirtualKeyLeakAction({
        action: bulkAction,
        key_ids: selectedKeyIds,
        reason,
      });

      setBulkResults(results);
      setSelectedKeyIds([]);
      setKeys((current) => applyBulkResultStatuses(current, results));
      setDetail((current) => applyBulkResultStatus(current, results));
      await loadKeys(projectId, statusFilter);
      setSuccess(`已提交 ${results.length} 个 API 密钥的${label}处理。`);
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setBulkBusy(false);
    }
  }

  function toggleKeySelection(keyId: string, selected: boolean) {
    setSelectedKeyIds((current) => {
      if (selected) {
        return current.includes(keyId) ? current : [...current, keyId];
      }

      return current.filter((id) => id !== keyId);
    });
  }

  function toggleVisibleSelection(selected: boolean) {
    setSelectedKeyIds((current) => {
      const visibleIds = keys.map((key) => key.id);

      if (!selected) {
        return current.filter((id) => !visibleIds.includes(id));
      }

      return [...new Set([...current, ...visibleIds])];
    });
  }

  function upsertKey(updated: VirtualKey) {
    setKeys((current) => current.map((key) => (key.id === updated.id ? updated : key)));
    setDetail((current) => (current?.id === updated.id ? updated : current));
  }

  const visibleKeyIds = keys.map((key) => key.id);
  const selectedVisibleCount = visibleKeyIds.filter((id) => selectedKeyIds.includes(id)).length;
  const allVisibleSelected = visibleKeyIds.length > 0 && selectedVisibleCount === visibleKeyIds.length;
  const focusedKeyId = activeFocus?.keyId?.trim() || "";
  const focusedKeyVisible = focusedKeyId ? keys.some((key) => key.id === focusedKeyId) : false;
  const focusedKeySelected = focusedKeyId ? selectedKeyIds.includes(focusedKeyId) : false;
  const bulkHandoffSummary = summarizeTableBulkAction({
    action: leakActionLabels[bulkAction],
    disabled: bulkBusy,
    reasonRequired: true,
    scope: "selected_rows",
    selectedCount: selectedKeyIds.length,
    status: bulkBusy ? "running" : bulkResults.length > 0 ? "completed" : selectedKeyIds.length > 0 ? "ready" : "idle",
    totalCount: keys.length,
  });

  return (
    <>
      <section className="admin-panel" aria-label="API 密钥筛选">
        <div className="section-heading">
          <div>
            <h2>API 密钥</h2>
            <p>查看项目级密钥，创建一次性生成的凭证，并停用或过期活跃密钥。</p>
          </div>
          <div className="action-row">
            <button className="primary-button primary-button--inline" type="button" onClick={() => setOpenCreateDialog(true)}>
              <Plus aria-hidden="true" size={17} />
              创建 API 密钥
            </button>
            <button className="secondary-button" type="button" onClick={() => void loadKeys()} disabled={loading}>
              <RefreshCw aria-hidden="true" size={18} className={loading ? "spin" : undefined} />
              刷新
            </button>
          </div>
        </div>

        <form className="filter-bar filter-bar--compact" onSubmit={handleFilterSubmit}>
          <label className="field">
            API 密钥项目 ID
            <input
              value={projectId}
              onChange={(event) => setProjectId(event.currentTarget.value)}
              placeholder="project uuid"
              required
            />
          </label>

          <label className="field">
            状态
            <select value={statusFilter} onChange={(event) => setStatusFilter(event.currentTarget.value)}>
              {virtualKeyStatusFilters.map((status) => (
                <option key={status || "all"} value={status}>
                  {status ? formatStatus(status) : "全部"}
                </option>
              ))}
            </select>
          </label>

          <button className="primary-button primary-button--inline" type="submit">
            <Search aria-hidden="true" size={17} />
            搜索
          </button>
        </form>

        {activeFocus ? (
          <FocusTargetBanner
            focusTarget={activeFocus}
            focusedKeySelected={focusedKeySelected}
            focusedKeyVisible={focusedKeyVisible}
            notice={focusNotice}
            onClear={clearFocus}
            onSelectFocusedKey={selectFocusedKey}
          />
        ) : null}

        {createdKeyNotice ? (
          <div className="secret-once" aria-label="已创建的 API 密钥凭证">
            <div>
              <strong>{safeFieldValue(createdKeyNotice.name)} 已创建</strong>
              <span>{safeFocusId(createdKeyNotice.keyId)}</span>
            </div>
            <code>{safeFieldValue(createdKeyNotice.keyPrefix)}</code>
            <StateChip status={createdKeyNotice.status} />
            <button className="secondary-button" type="button" onClick={() => setCreatedKeyNotice(null)}>
              <X aria-hidden="true" size={17} />
              清除提示
            </button>
          </div>
        ) : null}

        {error ? <p className="form-status form-status--error">{error}</p> : null}
        {success ? <p className="form-status form-status--success">{success}</p> : null}
      </section>

      <section className="admin-panel" aria-label="API 密钥泄露候选">
        <div className="section-heading">
          <div>
            <h2>泄露候选 readback</h2>
            <p>候选只来自后端安全 handoff 标记；不会展示密钥、hash、原始 token、Authorization、原始泄露 payload 或请求体。</p>
          </div>
          <div className="action-row">
            <span className="status-pill">{leakCandidates.length} 候选</span>
            <span className="status-pill">需操作员确认</span>
          </div>
        </div>
        <LeakCandidatesTable
          candidates={leakCandidates}
          onSelect={(keyId) => setSelectedKeyIds((current) => (current.includes(keyId) ? current : [...current, keyId]))}
        />
      </section>

      <section className="admin-panel" aria-label="API 密钥泄露批量处理">
        <div className="section-heading">
          <div>
            <h2>泄露检测处理</h2>
            <p>
              选择列表中的 API 密钥后批量标记疑似泄露、停用或吊销；提交前会要求确认。
              {focusedKeyId
                ? ` 当前 focus key ${safeFocusId(focusedKeyId)}${focusedKeySelected ? " 已在批量选择中。" : " 尚未加入批量选择。"}`
                : ""}
            </p>
          </div>
          <div className="action-row">
            {focusedKeyId ? (
              <button
                className="secondary-button"
                type="button"
                onClick={selectFocusedKey}
                disabled={!focusedKeyVisible || focusedKeySelected}
              >
                <ShieldOff aria-hidden="true" size={17} />
                选择 focus key
              </button>
            ) : null}
            <span className="status-pill">{selectedKeyIds.length} 已选择</span>
            <span className="status-pill">{bulkHandoffSummary.label}</span>
          </div>
        </div>

        <form className="filter-bar filter-bar--compact" onSubmit={handleBulkLeakAction}>
          <label className="field">
            批量动作
            <select value={bulkAction} onChange={(event) => setBulkAction(event.currentTarget.value as VirtualKeyLeakAction)}>
              <option value="suspected_leaked">标记 suspected leaked</option>
              <option value="disable">停用 disable</option>
              <option value="revoke">吊销 revoke</option>
            </select>
          </label>

          <label className="field field--wide">
            Reason
            <input
              value={bulkReason}
              onChange={(event) => setBulkReason(event.currentTarget.value)}
              placeholder="例如：public paste report, ticket INC-1234"
              required
            />
          </label>

          <button className="primary-button primary-button--inline" type="submit" disabled={bulkBusy || selectedKeyIds.length === 0}>
            <ShieldOff aria-hidden="true" size={17} />
            提交批量处理
          </button>
        </form>

        {bulkResults.length > 0 ? <BulkLeakActionResults results={bulkResults} /> : null}
      </section>

      <section aria-label="API 密钥列表">
        <DataTable
          aria-label="API 密钥列表"
          className="admin-table admin-table--virtual-keys"
          columns={virtualKeyTableColumns}
          stickyFirstColumn
          visibleColumns={visibleVirtualKeyColumns}
          onVisibleColumnsChange={setVisibleVirtualKeyColumns}
        >
            <thead>
              <tr>
                <th>
                  <input
                    aria-label="选择当前可见 API 密钥"
                    checked={allVisibleSelected}
                    disabled={keys.length === 0 || loading}
                    onChange={(event) => toggleVisibleSelection(event.currentTarget.checked)}
                    type="checkbox"
                  />
                </th>
                <th>名称</th>
                <th>状态</th>
                <th>项目</th>
                <th>默认配置档案</th>
                <th>前缀</th>
                <th>策略</th>
                <th>凭证</th>
                <th>操作</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr>
                  <td colSpan={visibleVirtualKeyColumns.length}>正在加载 API 密钥。</td>
                </tr>
              ) : keys.length > 0 ? (
                keys.map((key) => (
                  <tr key={key.id} className={virtualKeyRowClassName(key, selectedId, activeFocus)}>
                    <td>
                      <input
                        aria-label={`选择 API 密钥 ${safeFieldValue(key.name)}`}
                        checked={selectedKeyIds.includes(key.id)}
                        onChange={(event) => toggleKeySelection(key.id, event.currentTarget.checked)}
                        type="checkbox"
                      />
                    </td>
                    <td>
                      <strong>{safeFieldValue(key.name)}</strong>
                      <span>{shortId(key.id)}</span>
                    </td>
                    <td>
                      <StateChip status={key.status} />
                    </td>
                    <td>{shortId(key.project_id)}</td>
                    <td>{shortId(key.default_profile_id)}</td>
                    <td>{safeFieldValue(key.key_prefix)}</td>
                    <td>
                      <PolicySummary label="IP" value={key.ip_allowlist} />
                      <PolicySummary label="速率限制" value={key.rate_limit_policy} />
                      <PolicySummary label="预算" value={key.budget_policy} />
                      <VirtualKeyPolicyDiagnosticsSummary keyData={key} />
                    </td>
                    <td>{key.secret_redacted ? "已隐藏" : "仅生成一次"}</td>
                    <td>
                      <div className="action-row">
                        <button
                          className="table-action"
                          type="button"
                          onClick={() => void handleView(key)}
                          disabled={busyId === key.id}
                          aria-label={`查看 API 密钥 ${safeFieldValue(key.name)}`}
                        >
                          <Eye aria-hidden="true" size={15} />
                          查看
                        </button>
                        <button
                          className="table-action"
                          type="button"
                          onClick={() => void handleDisable(key)}
                          disabled={busyId === key.id || key.status === "disabled"}
                          aria-label={`停用 API 密钥 ${safeFieldValue(key.name)}`}
                        >
                          <ShieldOff aria-hidden="true" size={15} />
                          停用
                        </button>
                        <button
                          className="table-action table-action--danger"
                          type="button"
                          onClick={() => void handleExpire(key)}
                          disabled={busyId === key.id || key.status === "expired"}
                          aria-label={`过期 API 密钥 ${safeFieldValue(key.name)}`}
                        >
                          <Clock aria-hidden="true" size={15} />
                          过期
                        </button>
                      </div>
                    </td>
                  </tr>
                ))
              ) : (
                <tr>
                  <td colSpan={visibleVirtualKeyColumns.length}>按项目 ID 搜索以加载 API 密钥。</td>
                </tr>
              )}
            </tbody>
        </DataTable>
      </section>

      <VirtualKeyDetailPanel detail={detail} selectedId={selectedId} />

      {openCreateDialog ? (
        <div className="wizard-overlay" role="dialog" aria-modal="true" aria-label="创建 API 密钥对话框">
          <div className="wizard-panel">
            <div className="wizard-header">
              <div>
                <span>用户 API 密钥</span>
                <h3>创建 API 密钥</h3>
                <p>服务端只生成一次凭证内容；列表和详情 API 不会再次返回。</p>
              </div>
              <button className="icon-button" type="button" onClick={() => setOpenCreateDialog(false)} aria-label="关闭创建 API 密钥对话框">
                <X aria-hidden="true" size={18} />
              </button>
            </div>
            <form className="provider-form wizard-body" onSubmit={handleCreate}>
              <div className="form-grid form-grid--three">
                <label className="field">
                  项目 ID
                  <input
                    value={createForm.projectId}
                    onFocus={(event) => event.currentTarget.select()}
                    onChange={(event) => {
                      const value = event.currentTarget.value;
                      setCreateForm((current) => ({ ...current, projectId: value }));
                    }}
                    placeholder="project uuid"
                    required
                  />
                </label>

                <label className="field">
                  API 密钥名称
                  <input
                    value={createForm.name}
                    onChange={(event) => {
                      const value = event.currentTarget.value;
                      setCreateForm((current) => ({ ...current, name: value }));
                    }}
                    placeholder="mobile app key"
                    required
                  />
                </label>

                <label className="field">
                  默认配置档案 ID
                  <input
                    value={createForm.defaultProfileId}
                    onChange={(event) => {
                      const value = event.currentTarget.value;
                      setCreateForm((current) => ({ ...current, defaultProfileId: value }));
                    }}
                    placeholder="profile uuid"
                    required
                  />
                </label>

                <label className="field">
                  状态
                  <select
                    value={createForm.status}
                    onChange={(event) => {
                      const value = event.currentTarget.value as VirtualKeyStatus;
                      setCreateForm((current) => ({ ...current, status: value }));
                    }}
                  >
                    {virtualKeyStatuses.map((status) => (
                      <option key={status} value={status}>
                        {formatStatus(status)}
                      </option>
                    ))}
                  </select>
                </label>
              </div>

              <div className="form-grid form-grid--three">
                <label className="field">
                  IP 白名单 JSON
                  <textarea
                    value={createForm.ipAllowlist}
                    onChange={(event) => {
                      const value = event.currentTarget.value;
                      setCreateForm((current) => ({ ...current, ipAllowlist: value }));
                    }}
                    placeholder={'["203.0.113.10", "2001:db8::/64"]'}
                    spellCheck={false}
                  />
                </label>

                <label className="field">
                  速率限制策略 JSON
                  <textarea
                    value={createForm.rateLimitPolicy}
                    onChange={(event) => {
                      const value = event.currentTarget.value;
                      setCreateForm((current) => ({ ...current, rateLimitPolicy: value }));
                    }}
                    placeholder={'{"rpm": 60, "tpm": 120000, "concurrency": 3}'}
                    spellCheck={false}
                  />
                </label>

                <label className="field">
                  预算策略 JSON
                  <textarea
                    value={createForm.budgetPolicy}
                    onChange={(event) => {
                      const value = event.currentTarget.value;
                      setCreateForm((current) => ({ ...current, budgetPolicy: value }));
                    }}
                    placeholder={'{"monthly_usd": 25, "daily_usd": 5}'}
                    spellCheck={false}
                  />
                </label>
              </div>

              <label className="field">
                元数据 JSON
                <textarea
                  value={createForm.metadata}
                  onChange={(event) => {
                    const value = event.currentTarget.value;
                    setCreateForm((current) => ({ ...current, metadata: value }));
                  }}
                  spellCheck={false}
                />
              </label>

              <button className="primary-button primary-button--inline" type="submit">
                <Plus aria-hidden="true" size={17} />
                创建 API 密钥
              </button>
            </form>
          </div>
        </div>
      ) : null}
    </>
  );
}

function ProfilesSection() {
  const [busyId, setBusyId] = useState<string | null>(null);
  const [createForm, setCreateForm] = useState<ProfileCreateForm>(defaultProfileCreateForm);
  const [editBaseline, setEditBaseline] = useState<ProfileEditForm | null>(null);
  const [editForm, setEditForm] = useState<ProfileEditForm>({
    allowedModels: "[]",
    deniedModels: "[]",
    ipAllowlist: "[]",
    modelAliases: "{}",
    name: "",
    status: "active",
  });
  const [editingId, setEditingId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [openCreateDialog, setOpenCreateDialog] = useState(false);
  const [profiles, setProfiles] = useState<ApiKeyProfile[]>([]);
  const [projectId, setProjectId] = useState(DEFAULT_PROJECT_ID);
  const [success, setSuccess] = useState<string | null>(null);

  async function loadProfiles(nextProjectId = projectId) {
    const trimmedProjectId = nextProjectId.trim();

    if (!trimmedProjectId) {
      setError("需要填写项目 ID 才能加载配置档案。");
      setProfiles([]);
      return;
    }

    setError(null);
    setLoading(true);

    try {
      setProfiles(await listApiKeyProfiles({ project_id: trimmedProjectId }));
    } catch (requestError) {
      setError(errorMessage(requestError));
      setProfiles([]);
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    void loadProfiles(DEFAULT_PROJECT_ID);
  }, []);

  function handleFilterSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    void loadProfiles(projectId);
  }

  async function handleCreate(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setSuccess(null);

    const nextProjectId = createForm.projectId.trim();

    try {
      await createApiKeyProfile({
        allowed_models: parseSafeJsonArrayField(createForm.allowedModels, "可见模型"),
        denied_models: parseSafeJsonArrayField(createForm.deniedModels, "拒绝模型"),
        ip_allowlist: parseIpAllowlistJsonArrayField(createForm.ipAllowlist, "配置档案 IP 白名单"),
        model_aliases: parseSafeJsonObject(createForm.modelAliases, "模型别名"),
        name: createForm.name.trim(),
        project_id: nextProjectId,
        status: createForm.status,
      });
      setCreateForm({
        ...defaultProfileCreateForm,
        projectId: nextProjectId,
      });
      setProjectId(nextProjectId);
      setSuccess("配置档案已创建。");
      setOpenCreateDialog(false);
      await loadProfiles(nextProjectId);
    } catch (requestError) {
      setError(errorMessage(requestError));
    }
  }

  async function handlePatch(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();

    if (!editingId) {
      return;
    }

    setBusyId(editingId);
    setError(null);
    setSuccess(null);

    try {
      const patch: PatchApiKeyProfileRequest = {};

      if (!editBaseline || editForm.name !== editBaseline.name) {
        patch.name = editForm.name.trim();
      }

      if (!editBaseline || editForm.status !== editBaseline.status) {
        patch.status = editForm.status;
      }

      if (!editBaseline || editForm.allowedModels !== editBaseline.allowedModels) {
        patch.allowed_models = parseSafeJsonArrayField(editForm.allowedModels, "可见模型");
      }

      if (!editBaseline || editForm.deniedModels !== editBaseline.deniedModels) {
        patch.denied_models = parseSafeJsonArrayField(editForm.deniedModels, "拒绝模型");
      }

      if (!editBaseline || editForm.ipAllowlist !== editBaseline.ipAllowlist) {
        patch.ip_allowlist = parseIpAllowlistJsonArrayField(editForm.ipAllowlist, "配置档案 IP 白名单");
      }

      if (!editBaseline || editForm.modelAliases !== editBaseline.modelAliases) {
        patch.model_aliases = parseSafeJsonObject(editForm.modelAliases, "模型别名");
      }

      if (Object.keys(patch).length === 0) {
        setSuccess("没有需要保存的配置档案变更。");
        return;
      }

      const updated = await patchApiKeyProfile(editingId, patch);
      const nextEditForm = profileToEditForm(updated);
      setProfiles((current) => current.map((profile) => (profile.id === updated.id ? updated : profile)));
      setEditForm(nextEditForm);
      setEditBaseline(nextEditForm);
      setSuccess("配置档案已更新。");
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setBusyId(null);
    }
  }

  async function handleDelete(profile: ApiKeyProfile) {
    setBusyId(profile.id);
    setError(null);
    setSuccess(null);

    try {
      const deleted = await deleteApiKeyProfile(profile.id);
      setProfiles((current) => current.map((currentProfile) => (currentProfile.id === deleted.id ? deleted : currentProfile)));
      if (editingId === profile.id) {
        setEditingId(null);
        setEditBaseline(null);
      }
      setSuccess(`${safeFieldValue(profile.name)} 已删除。`);
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setBusyId(null);
    }
  }

  function startEditing(profile: ApiKeyProfile) {
    const nextEditForm = profileToEditForm(profile);
    setEditingId(profile.id);
    setEditForm(nextEditForm);
    setEditBaseline(nextEditForm);
  }

  function cancelEditing() {
    setEditingId(null);
    setEditBaseline(null);
  }

  return (
    <>
      <section className="admin-panel" aria-label="配置档案筛选">
        <div className="section-heading">
          <div>
            <h2>API 密钥配置档案</h2>
            <p>查看并管理项目级配置档案名称和状态。</p>
          </div>
          <div className="action-row">
            <button className="primary-button primary-button--inline" type="button" onClick={() => setOpenCreateDialog(true)}>
              <Plus aria-hidden="true" size={17} />
              创建配置档案
            </button>
            <button className="secondary-button" type="button" onClick={() => void loadProfiles()} disabled={loading}>
              <RefreshCw aria-hidden="true" size={18} className={loading ? "spin" : undefined} />
              刷新
            </button>
          </div>
        </div>

        <form className="filter-bar filter-bar--compact" onSubmit={handleFilterSubmit}>
          <label className="field">
            配置档案项目 ID
            <input
              value={projectId}
              onChange={(event) => setProjectId(event.currentTarget.value)}
              placeholder="project uuid"
              required
            />
          </label>

          <button className="primary-button primary-button--inline" type="submit">
            <Search aria-hidden="true" size={17} />
            搜索
          </button>
        </form>

        {error ? <p className="form-status form-status--error">{error}</p> : null}
        {success ? <p className="form-status form-status--success">{success}</p> : null}
      </section>

      <section aria-label="配置档案列表">
        <div className="health-table-wrap">
          <table className="health-table admin-table admin-table--profiles">
            <thead>
              <tr>
                <th>名称</th>
                <th>状态</th>
                <th>项目</th>
                <th>协议</th>
                <th>模型规则</th>
                <th>请求控制</th>
                <th>操作</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr>
                  <td colSpan={7}>正在加载配置档案。</td>
                </tr>
              ) : profiles.length > 0 ? (
                profiles.map((profile) => (
                  <tr key={profile.id} className={editingId === profile.id ? "table-row--selected" : undefined}>
                    <td>
                      <strong>{safeFieldValue(profile.name)}</strong>
                      <span>{shortId(profile.id)}</span>
                    </td>
                    <td>
                      <StateChip status={profile.status} />
                    </td>
                    <td>{shortId(profile.project_id)}</td>
                    <td>
                      <strong>{formatStatus(profile.inbound_protocol)}</strong>
                      <span>{formatStatus(profile.default_protocol_mode)}</span>
                    </td>
                    <td>
                      <PolicySummary label="可见" value={profile.allowed_models} />
                      <PolicySummary label="拒绝" value={profile.denied_models} />
                      <PolicySummary label="别名" value={profile.model_aliases} />
                    </td>
                    <td>
                      <ProfileRequestControlSummary profile={profile} />
                    </td>
                    <td>
                      <div className="action-row">
                        <button
                          className="table-action"
                          type="button"
                          onClick={() => startEditing(profile)}
                          aria-label={`编辑配置档案 ${safeFieldValue(profile.name)}`}
                        >
                          <Edit3 aria-hidden="true" size={15} />
                          编辑
                        </button>
                        <button
                          className="table-action table-action--danger"
                          type="button"
                          onClick={() => void handleDelete(profile)}
                          disabled={busyId === profile.id || profile.status === "deleted"}
                          aria-label={`删除配置档案 ${safeFieldValue(profile.name)}`}
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
                  <td colSpan={7}>按项目 ID 搜索以加载配置档案。</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </section>

      {editingId ? (
        <div className="wizard-overlay" role="dialog" aria-modal="true" aria-label="编辑配置档案对话框">
          <div className="wizard-panel">
            <div className="wizard-header">
              <div>
                <span>模型可见性</span>
                <h3>编辑配置档案</h3>
                <p>{editingId}</p>
              </div>
              <button className="icon-button" type="button" onClick={cancelEditing} aria-label="关闭编辑配置档案对话框">
                <X aria-hidden="true" size={18} />
              </button>
            </div>

          <form className="provider-form wizard-body" onSubmit={handlePatch}>
            <div className="form-grid form-grid--three">
              <label className="field">
                配置档案名称
                <input
                  value={editForm.name}
                  onChange={(event) => {
                    const value = event.currentTarget.value;
                    setEditForm((current) => ({ ...current, name: value }));
                  }}
                  required
                />
              </label>

              <label className="field">
                状态
                <select
                  value={editForm.status}
                  onChange={(event) => {
                    const value = event.currentTarget.value as ApiKeyProfileStatus;
                    setEditForm((current) => ({ ...current, status: value }));
                  }}
                >
                  {profileStatuses.map((status) => (
                    <option key={status} value={status}>
                      {formatStatus(status)}
                    </option>
                  ))}
                </select>
              </label>
            </div>

            <div className="form-grid form-grid--three">
              <label className="field">
                可见模型 JSON
                <textarea
                  value={editForm.allowedModels}
                  onChange={(event) => {
                    const value = event.currentTarget.value;
                    setEditForm((current) => ({ ...current, allowedModels: value }));
                  }}
                  spellCheck={false}
                />
              </label>

              <label className="field">
                拒绝模型 JSON
                <textarea
                  value={editForm.deniedModels}
                  onChange={(event) => {
                    const value = event.currentTarget.value;
                    setEditForm((current) => ({ ...current, deniedModels: value }));
                  }}
                  spellCheck={false}
                />
              </label>

              <label className="field">
                模型别名 JSON
                <textarea
                  value={editForm.modelAliases}
                  onChange={(event) => {
                    const value = event.currentTarget.value;
                    setEditForm((current) => ({ ...current, modelAliases: value }));
                  }}
                  spellCheck={false}
                />
              </label>

              <label className="field">
                配置档案 IP 白名单 JSON
                <textarea
                  value={editForm.ipAllowlist}
                  onChange={(event) => {
                    const value = event.currentTarget.value;
                    setEditForm((current) => ({ ...current, ipAllowlist: value }));
                  }}
                  spellCheck={false}
                />
              </label>
            </div>

            <div className="action-row">
              <button className="primary-button primary-button--inline" type="submit" disabled={busyId === editingId}>
                <Save aria-hidden="true" size={17} />
                保存变更
              </button>
              <button className="secondary-button" type="button" onClick={cancelEditing}>
                取消
              </button>
            </div>
          </form>
          </div>
        </div>
      ) : null}

      {openCreateDialog ? (
        <div className="wizard-overlay" role="dialog" aria-modal="true" aria-label="创建配置档案对话框">
          <div className="wizard-panel">
            <div className="wizard-header">
              <div>
                <span>用户访问配置档案</span>
                <h3>创建配置档案</h3>
                <p>协议默认值由服务端管理；这里配置模型可见性。</p>
              </div>
              <button className="icon-button" type="button" onClick={() => setOpenCreateDialog(false)} aria-label="关闭创建配置档案对话框">
                <X aria-hidden="true" size={18} />
              </button>
            </div>
            <form className="provider-form wizard-body" onSubmit={handleCreate}>
              <div className="form-grid form-grid--three">
                <label className="field">
                  新配置档案项目 ID
                  <input
                    value={createForm.projectId}
                    onFocus={(event) => event.currentTarget.select()}
                    onChange={(event) => {
                      const value = event.currentTarget.value;
                      setCreateForm((current) => ({ ...current, projectId: value }));
                    }}
                    placeholder="project uuid"
                    required
                  />
                </label>

                <label className="field">
                  配置档案名称
                  <input
                    value={createForm.name}
                    onChange={(event) => {
                      const value = event.currentTarget.value;
                      setCreateForm((current) => ({ ...current, name: value }));
                    }}
                    placeholder="default mobile"
                    required
                  />
                </label>

                <label className="field">
                  状态
                  <select
                    value={createForm.status}
                    onChange={(event) => {
                      const value = event.currentTarget.value as ApiKeyProfileStatus;
                      setCreateForm((current) => ({ ...current, status: value }));
                    }}
                  >
                    {profileStatuses.map((status) => (
                      <option key={status} value={status}>
                        {formatStatus(status)}
                      </option>
                    ))}
                  </select>
                </label>
              </div>

              <div className="form-grid form-grid--three">
                <label className="field">
                  可见模型 JSON
                  <textarea
                    value={createForm.allowedModels}
                    onChange={(event) => {
                      const value = event.currentTarget.value;
                      setCreateForm((current) => ({ ...current, allowedModels: value }));
                    }}
                    placeholder={'["gpt-4o-mini", "claude-3-haiku"]'}
                    spellCheck={false}
                  />
                </label>

                <label className="field">
                  拒绝模型 JSON
                  <textarea
                    value={createForm.deniedModels}
                    onChange={(event) => {
                      const value = event.currentTarget.value;
                      setCreateForm((current) => ({ ...current, deniedModels: value }));
                    }}
                    placeholder={'["internal-only-model"]'}
                    spellCheck={false}
                  />
                </label>

                <label className="field">
                  模型别名 JSON
                  <textarea
                    value={createForm.modelAliases}
                    onChange={(event) => {
                      const value = event.currentTarget.value;
                      setCreateForm((current) => ({ ...current, modelAliases: value }));
                    }}
                    placeholder={'{"chat-fast": "gpt-4o-mini"}'}
                    spellCheck={false}
                  />
                </label>

                <label className="field">
                  配置档案 IP 白名单 JSON
                  <textarea
                    value={createForm.ipAllowlist}
                    onChange={(event) => {
                      const value = event.currentTarget.value;
                      setCreateForm((current) => ({ ...current, ipAllowlist: value }));
                    }}
                    placeholder={'["203.0.113.10", "2001:db8::/64"]'}
                    spellCheck={false}
                  />
                </label>
              </div>

              <button className="primary-button primary-button--inline" type="submit">
                <Plus aria-hidden="true" size={17} />
                创建配置档案
              </button>
            </form>
          </div>
        </div>
      ) : null}
    </>
  );
}

function LeakCandidatesTable({
  candidates,
  onSelect,
}: {
  candidates: VirtualKeyLeakCandidate[];
  onSelect: (keyId: string) => void;
}) {
  if (candidates.length === 0) {
    return <p className="muted">当前筛选下没有疑似泄露候选。</p>;
  }

  return (
    <div className="health-table-wrap" aria-label="API 密钥泄露候选列表">
      <table className="health-table admin-table">
        <thead>
          <tr>
            <th>Key ID</th>
            <th>前缀</th>
            <th>状态</th>
            <th>来源</th>
            <th>原因</th>
            <th>首次/最近</th>
            <th>置信度</th>
            <th>建议</th>
            <th>操作</th>
          </tr>
        </thead>
        <tbody>
          {candidates.map((candidate) => (
            <tr key={candidate.key_id}>
              <td>{shortId(candidate.key_id)}</td>
              <td>{safeFieldValue(candidate.key_prefix)}</td>
              <td><StateChip status={candidate.status} /></td>
              <td>{safeFieldValue(candidate.source)}</td>
              <td>{safeFieldValue(candidate.reason)}</td>
              <td>
                <span>{safeFieldValue(candidate.first_seen)}</span>
                <span>{safeFieldValue(candidate.last_seen)}</span>
              </td>
              <td>{Math.round(candidate.confidence * 100)}%</td>
              <td>{safeFieldValue(candidate.action_recommendation)}</td>
              <td>
                <button className="table-action" type="button" onClick={() => onSelect(candidate.key_id)}>
                  <ShieldOff aria-hidden="true" size={15} />
                  加入批量选择
                </button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function BulkLeakActionResults({ results }: { results: BulkVirtualKeyLeakActionResult[] }) {
  return (
    <div className="health-table-wrap" aria-label="API 密钥泄露批量处理结果">
      <table className="health-table admin-table">
        <thead>
          <tr>
            <th>Key ID</th>
            <th>前缀</th>
            <th>状态</th>
            <th>Action result</th>
          </tr>
        </thead>
        <tbody>
          {results.map((result) => (
            <tr key={result.key_id}>
              <td>{shortId(result.key_id)}</td>
              <td>{safeFieldValue(result.key_prefix)}</td>
              <td>{result.status ? <StateChip status={result.status} /> : "无状态"}</td>
              <td>{safeFieldValue(result.action_result)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function FocusTargetBanner({
  focusTarget,
  focusedKeySelected,
  focusedKeyVisible,
  notice,
  onClear,
  onSelectFocusedKey,
}: {
  focusTarget: ApiKeysFocusTarget;
  focusedKeySelected: boolean;
  focusedKeyVisible: boolean;
  notice: FocusNotice | null;
  onClear: () => void;
  onSelectFocusedKey: () => void;
}) {
  const keyId = focusTarget.keyId?.trim();

  return (
    <div className={`api-keys-focus-banner api-keys-focus-banner--${notice?.tone ?? "info"}`} aria-label="API 密钥 focus 目标">
      <div>
        <strong>安全跳转 focus</strong>
        <span>
          Key {safeFocusId(keyId)} · Prefix {safeFieldValue(focusTarget.keyPrefix)} · Project{" "}
          {safeFocusId(focusTarget.projectId)} · Status {safeFieldValue(focusTarget.status)}
        </span>
        {notice ? <p>{notice.message}</p> : null}
      </div>
      <div className="action-row">
        {keyId ? (
          <button
            className="secondary-button"
            type="button"
            onClick={onSelectFocusedKey}
            disabled={!focusedKeyVisible || focusedKeySelected}
          >
            <ShieldOff aria-hidden="true" size={17} />
            加入批量选择
          </button>
        ) : null}
        <button className="secondary-button" type="button" onClick={onClear}>
          <X aria-hidden="true" size={17} />
          清除 focus
        </button>
      </div>
    </div>
  );
}

function applyBulkResultStatuses(keys: VirtualKey[], results: BulkVirtualKeyLeakActionResult[]): VirtualKey[] {
  return keys.map((key) => applyBulkResultStatus(key, results));
}

function applyBulkResultStatus<T extends VirtualKey | null>(key: T, results: BulkVirtualKeyLeakActionResult[]): T {
  if (!key) {
    return key;
  }

  const result = results.find((item) => item.key_id === key.id);

  if (!result?.status) {
    return key;
  }

  return {
    ...key,
    status: result.status,
    key_prefix: result.key_prefix ?? key.key_prefix,
  };
}

function normalizeApiKeysFocusTarget(target: ApiKeysFocusTarget): ApiKeysFocusTarget {
  return {
    keyId: trimFocusValue(target.keyId),
    keyPrefix: trimFocusValue(target.keyPrefix),
    projectId: trimFocusValue(target.projectId),
    status: trimFocusValue(target.status),
  };
}

function hasApiKeysFocusTarget(target: ApiKeysFocusTarget): boolean {
  return Boolean(target.keyId || target.keyPrefix || target.projectId || target.status);
}

function trimFocusValue(value: string | null | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
}

function focusNotFoundNotice(keyId: string, visibleKeys: VirtualKey[]): FocusNotice {
  const safeId = safeFocusId(keyId);
  const visibleSummary =
    visibleKeys.length > 0
      ? `当前页可见 ${visibleKeys.length} 个 key，但没有匹配 ${safeId}。`
      : "当前页没有可见 key。";

  return {
    tone: "warn",
    message: `${visibleSummary} 目标可能不在当前项目/状态筛选内，或当前管理员无权读取；不会展示 key secret。`,
  };
}

function safeFocusId(value: string | null | undefined): string {
  return shortId(safeFieldValue(value));
}

function virtualKeyRowClassName(key: VirtualKey, selectedId: string | null, focusTarget: ApiKeysFocusTarget | null): string | undefined {
  const classes: string[] = [];

  if (selectedId === key.id) {
    classes.push("table-row--selected");
  }

  if (matchesFocusedKey(key, focusTarget)) {
    classes.push("table-row--focus-key");
  } else if (matchesFocusedProjectOrStatus(key, focusTarget)) {
    classes.push("table-row--focus-related");
  }

  return classes.length > 0 ? classes.join(" ") : undefined;
}

function matchesFocusedKey(key: VirtualKey, focusTarget: ApiKeysFocusTarget | null): boolean {
  const focusKeyId = focusTarget?.keyId?.trim();
  const focusPrefix = focusTarget?.keyPrefix?.trim();

  return Boolean((focusKeyId && key.id === focusKeyId) || (focusPrefix && key.key_prefix === focusPrefix));
}

function matchesFocusedProjectOrStatus(key: VirtualKey, focusTarget: ApiKeysFocusTarget | null): boolean {
  const focusProjectId = focusTarget?.projectId?.trim();
  const focusStatus = focusTarget?.status?.trim();

  return Boolean((focusProjectId && key.project_id === focusProjectId) || (focusStatus && key.status === focusStatus));
}

function VirtualKeyDetailPanel({ detail, selectedId }: { detail: VirtualKey | null; selectedId: string | null }) {
  if (!selectedId) {
    return null;
  }

  if (!detail) {
    return (
      <section className="admin-panel" aria-label="API 密钥详情">
        <h2>API 密钥详情</h2>
        <p className="muted-copy">正在加载 {shortId(selectedId)}。</p>
      </section>
    );
  }

  return (
    <section className="detail-grid" aria-label="API 密钥详情">
      <article className="admin-panel">
        <div className="section-heading">
          <div>
            <h2>API 密钥详情</h2>
            <p>{detail.id}</p>
          </div>
          <StateChip status={detail.status} />
        </div>

        <dl className="detail-list">
          <div>
            <dt>项目</dt>
            <dd>{shortId(detail.project_id)}</dd>
          </div>
          <div>
            <dt>默认配置档案</dt>
            <dd>{shortId(detail.default_profile_id)}</dd>
          </div>
          <div>
            <dt>前缀</dt>
            <dd>{safeFieldValue(detail.key_prefix)}</dd>
          </div>
          <div>
            <dt>凭证</dt>
            <dd>{detail.secret_redacted ? "已隐藏" : "仅生成一次"}</dd>
          </div>
        </dl>
      </article>

      <article className="admin-panel">
        <h2>元数据</h2>
        <JsonBlock value={detail.metadata} />
      </article>

      <article className="admin-panel detail-panel--wide">
        <h2>策略</h2>
        <div className="policy-grid">
          <JsonPreview label="IP 白名单" value={detail.ip_allowlist} />
          <JsonPreview label="速率限制" value={detail.rate_limit_policy} />
          <JsonPreview label="预算" value={detail.budget_policy} />
        </div>
      </article>

      <VirtualKeyPolicyDiagnosticsPanel detail={detail} />
    </section>
  );
}

function JsonBlock({ value }: { value: JsonValue }) {
  return <pre className="json-block">{safeJsonText(value)}</pre>;
}

function JsonPreview({ label, value }: { label: string; value: JsonValue }) {
  return (
    <div>
      <strong>{label}</strong>
      <pre className="json-preview">{safeJsonText(value)}</pre>
    </div>
  );
}

function PolicySummary({ label, value }: { label: string; value: JsonValue }) {
  return (
    <span>
      <strong>{label}</strong> {summarizeJsonValue(sanitizeDisplayJson(value))}
    </span>
  );
}

function VirtualKeyPolicyDiagnosticsSummary({ keyData }: { keyData: VirtualKey }) {
  const diagnostics = keyData.policy_diagnostics;

  if (!diagnostics) {
    return null;
  }

  const rateLimitBits = [
    diagnostics.rate_limit.limits.rpm_limit_present ? "RPM" : null,
    diagnostics.rate_limit.limits.tpm_limit_present ? "TPM" : null,
    diagnostics.rate_limit.limits.concurrency_limit_present ? "并发" : null,
  ].filter(Boolean);

  return (
    <span>
      <strong>诊断</strong> 预算 {formatStatus(diagnostics.budget.status)} · 限制{" "}
      {rateLimitBits.length > 0 ? rateLimitBits.join("/") : "未配置"} · Ledger{" "}
      {diagnostics.refs_presence.ledger_ref_present ? "有引用" : "无引用"}
    </span>
  );
}

function VirtualKeyPolicyDiagnosticsPanel({ detail }: { detail: VirtualKey }) {
  const diagnostics = detail.policy_diagnostics;

  if (!diagnostics) {
    return null;
  }

  return (
    <article className="admin-panel detail-panel--wide">
      <h2>预算与限流诊断</h2>
      <dl className="detail-list detail-list--dense">
        <div>
          <dt>预算状态</dt>
          <dd>{formatStatus(diagnostics.budget.status)}</dd>
        </div>
        <div>
          <dt>预算配置</dt>
          <dd>{presenceLabel(diagnostics.budget.limit_present)} / 窗口 {presenceLabel(diagnostics.budget.window_present)}</dd>
        </div>
        <div>
          <dt>限流状态</dt>
          <dd>{formatStatus(diagnostics.rate_limit.status)}</dd>
        </div>
        <div>
          <dt>限流配置</dt>
          <dd>
            RPM {presenceLabel(diagnostics.rate_limit.limits.rpm_limit_present)} · TPM{" "}
            {presenceLabel(diagnostics.rate_limit.limits.tpm_limit_present)} · 并发{" "}
            {presenceLabel(diagnostics.rate_limit.limits.concurrency_limit_present)}
          </dd>
        </div>
        <div>
          <dt>当前用量</dt>
          <dd>{safeFieldValue(String(diagnostics.current_usage_summary.status ?? "未加载"))}</dd>
        </div>
        <div>
          <dt>阻止原因</dt>
          <dd>{diagnostics.blocked_reasons.length > 0 ? diagnostics.blocked_reasons.map(safeFieldValue).join(", ") : "无"}</dd>
        </div>
        <div>
          <dt>拒绝原因</dt>
          <dd>{diagnostics.reject_reason ? safeFieldValue(diagnostics.reject_reason) : "无"}</dd>
        </div>
        <div>
          <dt>安全下一步</dt>
          <dd>{safeFieldValue(diagnostics.safe_next_action)}</dd>
        </div>
        <div>
          <dt>Ledger / Preauth 引用</dt>
          <dd>
            Ledger {presenceLabel(diagnostics.refs_presence.ledger_ref_present)} · Preauth{" "}
            {presenceLabel(diagnostics.refs_presence.preauth_ref_present)}
          </dd>
        </div>
      </dl>
    </article>
  );
}

function presenceLabel(value: boolean) {
  return value ? "存在" : "不存在";
}

function ProfileRequestControlSummary({ profile }: { profile: ApiKeyProfile }) {
  return (
    <>
      <span>
        <strong>载荷策略</strong> {shortId(profile.payload_policy_id)}
      </span>
      <ProfileIpAllowlistCountSummary label="配置档案 IP" value={profile.ip_allowlist} />
      <PolicySummary label="覆盖规则" value={profile.request_overrides} />
      <ProfileOverrideTypeSummary value={profile.request_overrides} />
      <ProfileIpAllowlistCountSummary label="旧版配置档案 IP" value={profileIpAllowlist(profile.request_overrides)} />
    </>
  );
}

function ProfileOverrideTypeSummary({ value }: { value: JsonValue }) {
  const types = profileOverrideTypes(value);

  if (types.length === 0) {
    return null;
  }

  return (
    <span>
      <strong>类型</strong> {withOverflow(types.slice(0, 3).join(", "), types.length, Math.min(types.length, 3))}
    </span>
  );
}

function ProfileIpAllowlistCountSummary({ label, value }: { label: string; value: JsonValue }) {
  const count = Array.isArray(value) ? value.length : 0;

  if (count === 0) {
    return null;
  }

  return (
    <span>
      <strong>{label}</strong> {count === 1 ? "1 项" : `${count} 项`}
    </span>
  );
}

function profileOverrideTypes(value: JsonValue): string[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return [
    ...new Set(
      value
        .map((override) => (isJsonRecord(override) ? override.type : undefined))
        .filter((type): type is string => typeof type === "string" && type.trim().length > 0)
        .map(safeFieldValue),
    ),
  ];
}

function profileToEditForm(profile: ApiKeyProfile): ProfileEditForm {
  return {
    allowedModels: safeJsonText(profile.allowed_models),
    deniedModels: safeJsonText(profile.denied_models),
    ipAllowlist: safeJsonText(profile.ip_allowlist),
    modelAliases: safeJsonText(profile.model_aliases),
    name: safeFieldValue(profile.name),
    status: profile.status,
  };
}

function profileIpAllowlist(value: JsonValue): JsonValue[] {
  if (!Array.isArray(value)) {
    return [];
  }

  for (const override of value) {
    if (!isJsonRecord(override)) {
      continue;
    }

    if (override.type === "profile_ip_allowlist" && Array.isArray(override.allowlist)) {
      return sanitizeDisplayJson(override.allowlist) as JsonValue[];
    }
  }

  return [];
}

function safeJsonText(value: JsonValue): string {
  return JSON.stringify(sanitizeDisplayJson(value), null, 2);
}

function parseSafeJsonArrayField(value: string, label: string): JsonValue[] {
  let parsed: JsonValue;

  try {
    parsed = parseSafeJsonValue(value, label);
  } catch (error) {
    if (error instanceof Error && error.message === `${label}${JSON_ERROR_SUFFIX}`) {
      throw new Error(`${label}必须是有效 JSON。`);
    }

    throw error;
  }

  if (!Array.isArray(parsed)) {
    throw new Error(`${label}必须是 JSON 数组。`);
  }

  return parsed;
}

function parseIpAllowlistJsonArrayField(value: string, label: string): string[] {
  const parsed = parseSafeJsonArrayField(value, label);
  const entries: string[] = [];

  for (const entry of parsed) {
    if (typeof entry !== "string" || entry.trim().length === 0) {
      throw new Error(`${label}条目必须是非空字符串。`);
    }

    entries.push(entry.trim());
  }

  return entries;
}

function summarizeJsonValue(value: JsonValue): string {
  if (Array.isArray(value)) {
    if (value.length === 0) {
      return "无";
    }

    const parts = value.slice(0, 3).map(summarizeJsonScalar).filter((part) => part !== undefined);

    if (parts.length === value.slice(0, 3).length) {
      return withOverflow(parts.join(", "), value.length, parts.length);
    }

    return `${value.length} 项`;
  }

  if (isJsonRecord(value)) {
    const entries = Object.entries(value);

    if (entries.length === 0) {
      return "无";
    }

    const parts = entries.slice(0, 3).map(([key, child]) => {
      const childSummary = summarizeJsonScalar(child) ?? jsonSize(child);
      return `${safeFieldValue(key)}=${childSummary}`;
    });

    return withOverflow(parts.join(", "), entries.length, parts.length);
  }

  return summarizeJsonScalar(value) ?? "无";
}

function summarizeJsonScalar(value: JsonValue): string | undefined {
  if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
    return safeFieldValue(value);
  }

  return undefined;
}

function withOverflow(summary: string, total: number, shown: number): string {
  const extra = total - shown;

  return extra > 0 ? `${summary} +${extra}` : summary;
}
