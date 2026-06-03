import { FormEvent, useState } from "react";
import {
  type ApiKeyProfile,
  type ApiKeyProfileStatus,
  createApiKeyProfile,
  createVirtualKey,
  deleteApiKeyProfile,
  disableVirtualKey,
  expireVirtualKey,
  getVirtualKey,
  type JsonValue,
  listApiKeyProfiles,
  listVirtualKeys,
  type PatchApiKeyProfileRequest,
  patchApiKeyProfile,
  type VirtualKey,
  type VirtualKeyStatus,
} from "../api/client";
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
} from "./adminUtils";
import { Clock, Edit3, Eye, Plus, RefreshCw, Save, Search, ShieldOff, Trash2, X } from "./icons";

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
  name: string;
  secret: string;
};

const profileStatuses: ApiKeyProfileStatus[] = ["active", "disabled", "deleted"];
const virtualKeyStatuses: VirtualKeyStatus[] = ["active", "disabled", "expired", "deleted"];
const virtualKeyStatusFilters = ["", ...virtualKeyStatuses];

const defaultVirtualKeyCreateForm: VirtualKeyCreateForm = {
  budgetPolicy: "{}",
  defaultProfileId: "",
  ipAllowlist: "[]",
  metadata: "{}",
  name: "",
  projectId: "",
  rateLimitPolicy: "{}",
  status: "active",
};

const defaultProfileCreateForm: ProfileCreateForm = {
  allowedModels: "[]",
  deniedModels: "[]",
  ipAllowlist: "[]",
  modelAliases: "{}",
  name: "",
  projectId: "",
  status: "active",
};

export function VirtualKeysPage() {
  const [activeTab, setActiveTab] = useState<Tab>("virtualKeys");

  return (
    <div className="admin-page" aria-label="Virtual keys and profiles">
      <div className="tab-list" role="tablist" aria-label="Key management sections">
        <button
          aria-selected={activeTab === "virtualKeys"}
          className={`tab-button${activeTab === "virtualKeys" ? " tab-button--active" : ""}`}
          onClick={() => setActiveTab("virtualKeys")}
          role="tab"
          type="button"
        >
          Virtual Keys
        </button>
        <button
          aria-selected={activeTab === "profiles"}
          className={`tab-button${activeTab === "profiles" ? " tab-button--active" : ""}`}
          onClick={() => setActiveTab("profiles")}
          role="tab"
          type="button"
        >
          Profiles
        </button>
      </div>

      {activeTab === "virtualKeys" ? <VirtualKeysSection /> : <ProfilesSection />}
    </div>
  );
}

export default VirtualKeysPage;

function VirtualKeysSection() {
  const [busyId, setBusyId] = useState<string | null>(null);
  const [createForm, setCreateForm] = useState<VirtualKeyCreateForm>(defaultVirtualKeyCreateForm);
  const [createdKeyNotice, setCreatedKeyNotice] = useState<CreatedKeyNotice | null>(null);
  const [detail, setDetail] = useState<VirtualKey | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [keys, setKeys] = useState<VirtualKey[]>([]);
  const [loading, setLoading] = useState(false);
  const [projectId, setProjectId] = useState("");
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [statusFilter, setStatusFilter] = useState("");
  const [success, setSuccess] = useState<string | null>(null);

  async function loadKeys(nextProjectId = projectId, nextStatus = statusFilter) {
    const trimmedProjectId = nextProjectId.trim();

    if (!trimmedProjectId) {
      setError("Project ID is required to list virtual keys.");
      setKeys([]);
      return;
    }

    setError(null);
    setLoading(true);

    try {
      setKeys(
        await listVirtualKeys({
          project_id: trimmedProjectId,
          status: nextStatus || undefined,
        }),
      );
    } catch (requestError) {
      setError(errorMessage(requestError));
      setKeys([]);
    } finally {
      setLoading(false);
    }
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
        budget_policy: parseSafeJsonObject(createForm.budgetPolicy, "Budget policy"),
        default_profile_id: createForm.defaultProfileId.trim(),
        ip_allowlist: parseSafeJsonArrayField(createForm.ipAllowlist, "IP allowlist"),
        metadata: parseSafeMetadata(createForm.metadata),
        name: createForm.name.trim(),
        project_id: nextProjectId,
        rate_limit_policy: parseSafeJsonObject(createForm.rateLimitPolicy, "Rate limit policy"),
        status: createForm.status,
      });

      if (created.secret && created.secret_once) {
        setCreatedKeyNotice({
          keyId: created.id,
          name: created.name,
          secret: created.secret,
        });
      }

      setCreateForm({
        ...defaultVirtualKeyCreateForm,
        projectId: nextProjectId,
      });
      setProjectId(nextProjectId);
      setSuccess("Virtual key created.");
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
      setSuccess(`${safeFieldValue(key.name)} disabled.`);
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
      setSuccess(`${safeFieldValue(key.name)} expired.`);
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

  function upsertKey(updated: VirtualKey) {
    setKeys((current) => current.map((key) => (key.id === updated.id ? updated : key)));
    setDetail((current) => (current?.id === updated.id ? updated : current));
  }

  return (
    <>
      <section className="admin-panel" aria-label="Virtual key filters">
        <div className="section-heading">
          <div>
            <h2>Virtual Keys</h2>
            <p>List project-scoped keys, create generated credentials, and disable or expire active keys.</p>
          </div>
          <button className="secondary-button" type="button" onClick={() => void loadKeys()} disabled={loading}>
            <RefreshCw aria-hidden="true" size={18} className={loading ? "spin" : undefined} />
            Refresh
          </button>
        </div>

        <form className="filter-bar filter-bar--compact" onSubmit={handleFilterSubmit}>
          <label className="field">
            Virtual key project ID
            <input
              value={projectId}
              onChange={(event) => setProjectId(event.currentTarget.value)}
              placeholder="project uuid"
              required
            />
          </label>

          <label className="field">
            Status
            <select value={statusFilter} onChange={(event) => setStatusFilter(event.currentTarget.value)}>
              {virtualKeyStatusFilters.map((status) => (
                <option key={status || "all"} value={status}>
                  {status ? formatStatus(status) : "All"}
                </option>
              ))}
            </select>
          </label>

          <button className="primary-button primary-button--inline" type="submit">
            <Search aria-hidden="true" size={17} />
            Search
          </button>
        </form>
      </section>

      <section className="admin-panel" aria-label="Create virtual key">
        <div className="section-heading">
          <div>
            <h2>Create Virtual Key</h2>
            <p>The server generates credential material once; list and detail APIs never return it.</p>
          </div>
        </div>

        <form className="provider-form" onSubmit={handleCreate}>
          <div className="form-grid form-grid--three">
            <label className="field">
              Project ID
              <input
                value={createForm.projectId}
                onChange={(event) => {
                  const value = event.currentTarget.value;
                  setCreateForm((current) => ({ ...current, projectId: value }));
                }}
                placeholder="project uuid"
                required
              />
            </label>

            <label className="field">
              Virtual key name
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
              Default profile ID
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
              Status
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
              IP allowlist JSON
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
              Rate limit policy JSON
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
              Budget policy JSON
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
            Metadata JSON
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
            Create virtual key
          </button>
        </form>

        {createdKeyNotice ? (
          <div className="secret-once" aria-label="Created virtual key credential">
            <div>
              <strong>Credential created for {safeFieldValue(createdKeyNotice.name)}</strong>
              <span>{createdKeyNotice.keyId}</span>
            </div>
            <code>{createdKeyNotice.secret}</code>
            <button className="secondary-button" type="button" onClick={() => setCreatedKeyNotice(null)}>
              <X aria-hidden="true" size={17} />
              Clear credential
            </button>
          </div>
        ) : null}

        {error ? <p className="form-status form-status--error">{error}</p> : null}
        {success ? <p className="form-status form-status--success">{success}</p> : null}
      </section>

      <section aria-label="Virtual key list">
        <div className="health-table-wrap">
          <table className="health-table admin-table admin-table--virtual-keys">
            <thead>
              <tr>
                <th>Name</th>
                <th>Status</th>
                <th>Project</th>
                <th>Default Profile</th>
                <th>Prefix</th>
                <th>Policies</th>
                <th>Credential</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr>
                  <td colSpan={8}>Loading virtual keys.</td>
                </tr>
              ) : keys.length > 0 ? (
                keys.map((key) => (
                  <tr key={key.id} className={selectedId === key.id ? "table-row--selected" : undefined}>
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
                      <PolicySummary label="Rate limit" value={key.rate_limit_policy} />
                      <PolicySummary label="Budget" value={key.budget_policy} />
                    </td>
                    <td>{key.secret_redacted ? "Redacted" : "Generated once"}</td>
                    <td>
                      <div className="action-row">
                        <button
                          className="table-action"
                          type="button"
                          onClick={() => void handleView(key)}
                          disabled={busyId === key.id}
                          aria-label={`View virtual key ${safeFieldValue(key.name)}`}
                        >
                          <Eye aria-hidden="true" size={15} />
                          View
                        </button>
                        <button
                          className="table-action"
                          type="button"
                          onClick={() => void handleDisable(key)}
                          disabled={busyId === key.id || key.status === "disabled"}
                          aria-label={`Disable virtual key ${safeFieldValue(key.name)}`}
                        >
                          <ShieldOff aria-hidden="true" size={15} />
                          Disable
                        </button>
                        <button
                          className="table-action table-action--danger"
                          type="button"
                          onClick={() => void handleExpire(key)}
                          disabled={busyId === key.id || key.status === "expired"}
                          aria-label={`Expire virtual key ${safeFieldValue(key.name)}`}
                        >
                          <Clock aria-hidden="true" size={15} />
                          Expire
                        </button>
                      </div>
                    </td>
                  </tr>
                ))
              ) : (
                <tr>
                  <td colSpan={8}>Search by project ID to load virtual keys.</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </section>

      <VirtualKeyDetailPanel detail={detail} selectedId={selectedId} />
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
  const [profiles, setProfiles] = useState<ApiKeyProfile[]>([]);
  const [projectId, setProjectId] = useState("");
  const [success, setSuccess] = useState<string | null>(null);

  async function loadProfiles(nextProjectId = projectId) {
    const trimmedProjectId = nextProjectId.trim();

    if (!trimmedProjectId) {
      setError("Project ID is required to list profiles.");
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
        allowed_models: parseSafeJsonArrayField(createForm.allowedModels, "Visible models"),
        denied_models: parseSafeJsonArrayField(createForm.deniedModels, "Denied models"),
        ip_allowlist: parseIpAllowlistJsonArrayField(createForm.ipAllowlist, "Profile IP allowlist"),
        model_aliases: parseSafeJsonObject(createForm.modelAliases, "Model aliases"),
        name: createForm.name.trim(),
        project_id: nextProjectId,
        status: createForm.status,
      });
      setCreateForm({
        ...defaultProfileCreateForm,
        projectId: nextProjectId,
      });
      setProjectId(nextProjectId);
      setSuccess("Profile created.");
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
        patch.allowed_models = parseSafeJsonArrayField(editForm.allowedModels, "Visible models");
      }

      if (!editBaseline || editForm.deniedModels !== editBaseline.deniedModels) {
        patch.denied_models = parseSafeJsonArrayField(editForm.deniedModels, "Denied models");
      }

      if (!editBaseline || editForm.ipAllowlist !== editBaseline.ipAllowlist) {
        patch.ip_allowlist = parseIpAllowlistJsonArrayField(editForm.ipAllowlist, "Profile IP allowlist");
      }

      if (!editBaseline || editForm.modelAliases !== editBaseline.modelAliases) {
        patch.model_aliases = parseSafeJsonObject(editForm.modelAliases, "Model aliases");
      }

      if (Object.keys(patch).length === 0) {
        setSuccess("No profile changes to save.");
        return;
      }

      const updated = await patchApiKeyProfile(editingId, patch);
      const nextEditForm = profileToEditForm(updated);
      setProfiles((current) => current.map((profile) => (profile.id === updated.id ? updated : profile)));
      setEditForm(nextEditForm);
      setEditBaseline(nextEditForm);
      setSuccess("Profile updated.");
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
      setSuccess(`${safeFieldValue(profile.name)} deleted.`);
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
      <section className="admin-panel" aria-label="Profile filters">
        <div className="section-heading">
          <div>
            <h2>API Key Profiles</h2>
            <p>List and manage project-scoped profile names and status.</p>
          </div>
          <button className="secondary-button" type="button" onClick={() => void loadProfiles()} disabled={loading}>
            <RefreshCw aria-hidden="true" size={18} className={loading ? "spin" : undefined} />
            Refresh
          </button>
        </div>

        <form className="filter-bar filter-bar--compact" onSubmit={handleFilterSubmit}>
          <label className="field">
            Profile project ID
            <input
              value={projectId}
              onChange={(event) => setProjectId(event.currentTarget.value)}
              placeholder="project uuid"
              required
            />
          </label>

          <button className="primary-button primary-button--inline" type="submit">
            <Search aria-hidden="true" size={17} />
            Search
          </button>
        </form>
      </section>

      <section className="admin-panel" aria-label="Create profile">
        <div className="section-heading">
          <div>
            <h2>Create Profile</h2>
            <p>Protocol defaults stay server-managed; model visibility can be configured here.</p>
          </div>
        </div>

        <form className="provider-form" onSubmit={handleCreate}>
          <div className="form-grid form-grid--three">
            <label className="field">
              New profile project ID
              <input
                value={createForm.projectId}
                onChange={(event) => {
                  const value = event.currentTarget.value;
                  setCreateForm((current) => ({ ...current, projectId: value }));
                }}
                placeholder="project uuid"
                required
              />
            </label>

            <label className="field">
              Profile name
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
              Status
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
              Visible models JSON
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
              Denied models JSON
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
              Model aliases JSON
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
              Profile IP allowlist JSON
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
            Create profile
          </button>
        </form>

        {error ? <p className="form-status form-status--error">{error}</p> : null}
        {success ? <p className="form-status form-status--success">{success}</p> : null}
      </section>

      <section aria-label="Profile list">
        <div className="health-table-wrap">
          <table className="health-table admin-table admin-table--profiles">
            <thead>
              <tr>
                <th>Name</th>
                <th>Status</th>
                <th>Project</th>
                <th>Protocol</th>
                <th>Model Rules</th>
                <th>Request Controls</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr>
                  <td colSpan={7}>Loading profiles.</td>
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
                      <PolicySummary label="Visible" value={profile.allowed_models} />
                      <PolicySummary label="Denied" value={profile.denied_models} />
                      <PolicySummary label="Aliases" value={profile.model_aliases} />
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
                          aria-label={`Edit profile ${safeFieldValue(profile.name)}`}
                        >
                          <Edit3 aria-hidden="true" size={15} />
                          Edit
                        </button>
                        <button
                          className="table-action table-action--danger"
                          type="button"
                          onClick={() => void handleDelete(profile)}
                          disabled={busyId === profile.id || profile.status === "deleted"}
                          aria-label={`Delete profile ${safeFieldValue(profile.name)}`}
                        >
                          <Trash2 aria-hidden="true" size={15} />
                          Delete
                        </button>
                      </div>
                    </td>
                  </tr>
                ))
              ) : (
                <tr>
                  <td colSpan={7}>Search by project ID to load profiles.</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </section>

      {editingId ? (
        <section className="admin-panel" aria-label="Patch profile">
          <div className="section-heading">
            <div>
              <h2>Patch Profile</h2>
              <p>{editingId}</p>
            </div>
          </div>

          <form className="provider-form" onSubmit={handlePatch}>
            <div className="form-grid form-grid--three">
              <label className="field">
                Edit profile name
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
                Status
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
                Visible models JSON
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
                Denied models JSON
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
                Model aliases JSON
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
                Profile IP allowlist JSON
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
                Save patch
              </button>
              <button className="secondary-button" type="button" onClick={cancelEditing}>
                Cancel
              </button>
            </div>
          </form>
        </section>
      ) : null}
    </>
  );
}

function VirtualKeyDetailPanel({ detail, selectedId }: { detail: VirtualKey | null; selectedId: string | null }) {
  if (!selectedId) {
    return null;
  }

  if (!detail) {
    return (
      <section className="admin-panel" aria-label="Virtual key detail">
        <h2>Virtual Key Detail</h2>
        <p className="muted-copy">Loading {shortId(selectedId)}.</p>
      </section>
    );
  }

  return (
    <section className="detail-grid" aria-label="Virtual key detail">
      <article className="admin-panel">
        <div className="section-heading">
          <div>
            <h2>Virtual Key Detail</h2>
            <p>{detail.id}</p>
          </div>
          <StateChip status={detail.status} />
        </div>

        <dl className="detail-list">
          <div>
            <dt>Project</dt>
            <dd>{shortId(detail.project_id)}</dd>
          </div>
          <div>
            <dt>Default profile</dt>
            <dd>{shortId(detail.default_profile_id)}</dd>
          </div>
          <div>
            <dt>Prefix</dt>
            <dd>{safeFieldValue(detail.key_prefix)}</dd>
          </div>
          <div>
            <dt>Credential</dt>
            <dd>{detail.secret_redacted ? "Redacted" : "Generated once"}</dd>
          </div>
        </dl>
      </article>

      <article className="admin-panel">
        <h2>Metadata</h2>
        <JsonBlock value={detail.metadata} />
      </article>

      <article className="admin-panel detail-panel--wide">
        <h2>Policies</h2>
        <div className="policy-grid">
          <JsonPreview label="IP allowlist" value={detail.ip_allowlist} />
          <JsonPreview label="Rate limit" value={detail.rate_limit_policy} />
          <JsonPreview label="Budget" value={detail.budget_policy} />
        </div>
      </article>
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

function ProfileRequestControlSummary({ profile }: { profile: ApiKeyProfile }) {
  return (
    <>
      <span>
        <strong>Payload</strong> {shortId(profile.payload_policy_id)}
      </span>
      <ProfileIpAllowlistCountSummary label="Profile IP" value={profile.ip_allowlist} />
      <PolicySummary label="Overrides" value={profile.request_overrides} />
      <ProfileOverrideTypeSummary value={profile.request_overrides} />
      <ProfileIpAllowlistCountSummary label="Legacy Profile IP" value={profileIpAllowlist(profile.request_overrides)} />
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
      <strong>Types</strong> {withOverflow(types.slice(0, 3).join(", "), types.length, Math.min(types.length, 3))}
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
      <strong>{label}</strong> {count === 1 ? "1 entry" : `${count} entries`}
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
  const parsed = parseSafeJsonValue(value, label);

  if (!Array.isArray(parsed)) {
    throw new Error(`${label} must be a JSON array.`);
  }

  return parsed;
}

function parseIpAllowlistJsonArrayField(value: string, label: string): string[] {
  const parsed = parseSafeJsonArrayField(value, label);
  const entries: string[] = [];

  for (const entry of parsed) {
    if (typeof entry !== "string" || entry.trim().length === 0) {
      throw new Error(`${label} entries must be non-empty strings.`);
    }

    entries.push(entry.trim());
  }

  return entries;
}

function summarizeJsonValue(value: JsonValue): string {
  if (Array.isArray(value)) {
    if (value.length === 0) {
      return "none";
    }

    const parts = value.slice(0, 3).map(summarizeJsonScalar).filter((part) => part !== undefined);

    if (parts.length === value.slice(0, 3).length) {
      return withOverflow(parts.join(", "), value.length, parts.length);
    }

    return `${value.length} entries`;
  }

  if (isJsonRecord(value)) {
    const entries = Object.entries(value);

    if (entries.length === 0) {
      return "none";
    }

    const parts = entries.slice(0, 3).map(([key, child]) => {
      const childSummary = summarizeJsonScalar(child) ?? jsonSize(child);
      return `${safeFieldValue(key)}=${childSummary}`;
    });

    return withOverflow(parts.join(", "), entries.length, parts.length);
  }

  return summarizeJsonScalar(value) ?? "none";
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
