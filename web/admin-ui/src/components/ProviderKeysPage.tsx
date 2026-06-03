import { FormEvent, useEffect, useState } from "react";
import {
  createProviderKey,
  deleteProviderKey,
  listProviderKeys,
  patchProviderKey,
  type ProviderKey,
  type ProviderKeyStatus,
} from "../api/client";
import { StateChip, errorMessage, fieldValue, formatStatus, parseSafeMetadata, sanitizeSecretJson, shortId } from "./adminUtils";
import { Edit3, Plus, RefreshCw, Save, ShieldOff, Trash2 } from "./icons";

type CreateFormState = {
  channelId: string;
  keyAlias: string;
  metadata: string;
  secret: string;
  status: ProviderKeyStatus;
};

type EditFormState = {
  metadata: string;
  status: ProviderKeyStatus;
};

const providerKeyStatuses = [
  "enabled",
  "manual_disabled",
  "degraded",
  "cooldown",
  "recovery_probe",
  "auth_failed",
  "quota_exhausted",
  "deleted",
];

const defaultCreateForm: CreateFormState = {
  channelId: "",
  keyAlias: "",
  metadata: "{}",
  secret: "",
  status: "enabled",
};

export function ProviderKeysPage() {
  const [busyId, setBusyId] = useState<string | null>(null);
  const [createForm, setCreateForm] = useState<CreateFormState>(defaultCreateForm);
  const [editForm, setEditForm] = useState<EditFormState>({ metadata: "{}", status: "enabled" });
  const [editingKeyId, setEditingKeyId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [keys, setKeys] = useState<ProviderKey[]>([]);
  const [loading, setLoading] = useState(true);
  const [success, setSuccess] = useState<string | null>(null);

  async function loadKeys() {
    setError(null);
    setLoading(true);

    try {
      setKeys(await listProviderKeys());
    } catch (requestError) {
      setError(errorMessage(requestError));
      setKeys([]);
    } finally {
      setLoading(false);
    }
  }

  async function handleCreate(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setSuccess(null);

    try {
      const metadata = parseSafeMetadata(createForm.metadata);
      await createProviderKey({
        channel_id: createForm.channelId.trim(),
        key_alias: createForm.keyAlias.trim(),
        metadata,
        secret: createForm.secret,
        status: createForm.status,
      });
      setCreateForm(defaultCreateForm);
      setSuccess("Provider key created. The submitted secret was cleared from the form.");
      await loadKeys();
    } catch (requestError) {
      setError(errorMessage(requestError));
    }
  }

  async function handlePatch(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();

    if (!editingKeyId) {
      return;
    }

    setBusyId(editingKeyId);
    setError(null);
    setSuccess(null);

    try {
      const metadata = parseSafeMetadata(editForm.metadata);
      const updated = await patchProviderKey(editingKeyId, {
        metadata,
        status: editForm.status,
      });
      setKeys((current) => current.map((key) => (key.id === updated.id ? updated : key)));
      setSuccess("Provider key state updated.");
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setBusyId(null);
    }
  }

  async function handleDisable(key: ProviderKey) {
    setBusyId(key.id);
    setError(null);
    setSuccess(null);

    try {
      const updated = await patchProviderKey(key.id, { status: "manual_disabled" });
      setKeys((current) => current.map((currentKey) => (currentKey.id === updated.id ? updated : currentKey)));
      if (editingKeyId === key.id) {
        setEditForm((current) => ({ ...current, status: "manual_disabled" }));
      }
      setSuccess(`${key.key_alias} disabled.`);
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setBusyId(null);
    }
  }

  async function handleDelete(key: ProviderKey) {
    setBusyId(key.id);
    setError(null);
    setSuccess(null);

    try {
      const deleted = await deleteProviderKey(key.id);
      setKeys((current) => current.map((currentKey) => (currentKey.id === deleted.id ? deleted : currentKey)));
      if (editingKeyId === key.id) {
        setEditingKeyId(null);
      }
      setSuccess(`${key.key_alias} deleted.`);
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setBusyId(null);
    }
  }

  function startEditing(key: ProviderKey) {
    setEditingKeyId(key.id);
    setEditForm({
      metadata: JSON.stringify(sanitizeSecretJson(key.metadata), null, 2),
      status: key.status,
    });
  }

  useEffect(() => {
    void loadKeys();
  }, []);

  return (
    <div className="admin-page" aria-label="Provider keys">
      <section className="admin-panel" aria-label="Create provider key">
        <div className="section-heading">
          <div>
            <h2>Provider Keys</h2>
            <p>Create upstream credentials once, then manage non-secret state and metadata.</p>
          </div>
          <button className="secondary-button" type="button" onClick={() => void loadKeys()} disabled={loading}>
            <RefreshCw aria-hidden="true" size={18} className={loading ? "spin" : undefined} />
            Refresh
          </button>
        </div>

        <form className="provider-form" onSubmit={handleCreate}>
          <div className="form-grid">
            <label className="field">
              Channel ID
              <input
                value={createForm.channelId}
                onChange={(event) => setCreateForm((current) => ({ ...current, channelId: event.currentTarget.value }))}
                required
                placeholder="channel uuid"
              />
            </label>

            <label className="field">
              Alias
              <input
                value={createForm.keyAlias}
                onChange={(event) => setCreateForm((current) => ({ ...current, keyAlias: event.currentTarget.value }))}
                required
                placeholder="openai primary"
              />
            </label>

            <label className="field">
              Status
              <select
                value={createForm.status}
                onChange={(event) =>
                  setCreateForm((current) => ({ ...current, status: event.currentTarget.value as ProviderKeyStatus }))
                }
              >
                {providerKeyStatuses.map((status) => (
                  <option key={status} value={status}>
                    {formatStatus(status)}
                  </option>
                ))}
              </select>
            </label>

            <label className="field">
              Secret / API key
              <input
                autoComplete="new-password"
                value={createForm.secret}
                onChange={(event) => setCreateForm((current) => ({ ...current, secret: event.currentTarget.value }))}
                required
                type="password"
              />
            </label>
          </div>

          <label className="field">
            Metadata JSON
            <textarea
              value={createForm.metadata}
              onChange={(event) => setCreateForm((current) => ({ ...current, metadata: event.currentTarget.value }))}
              spellCheck={false}
            />
          </label>

          <button className="primary-button primary-button--inline" type="submit">
            <Plus aria-hidden="true" size={17} />
            Create
          </button>
        </form>

        {error ? <p className="form-status form-status--error">{error}</p> : null}
        {success ? <p className="form-status form-status--success">{success}</p> : null}
      </section>

      <section aria-label="Provider key list">
        <div className="health-table-wrap">
          <table className="health-table admin-table admin-table--keys">
            <thead>
              <tr>
                <th>Alias</th>
                <th>Status</th>
                <th>Channel</th>
                <th>Health</th>
                <th>Limits</th>
                <th>Metadata</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr>
                  <td colSpan={7}>Loading provider keys.</td>
                </tr>
              ) : keys.length > 0 ? (
                keys.map((key) => (
                  <tr key={key.id} className={editingKeyId === key.id ? "table-row--selected" : undefined}>
                    <td>
                      <strong>{key.key_alias}</strong>
                      <span>{shortId(key.id)}</span>
                    </td>
                    <td>
                      <StateChip status={key.status} />
                      {key.last_error_code ? <span>{key.last_error_code}</span> : null}
                    </td>
                    <td>{shortId(key.channel_id)}</td>
                    <td>
                      <strong>{Math.round(key.health_score)}</strong>
                      {key.cooldown_until ? <span>Cooldown {formatDate(key.cooldown_until)}</span> : null}
                    </td>
                    <td>
                      <span>RPM {fieldValue(key.rpm_limit)}</span>
                      <span>TPM {fieldValue(key.tpm_limit)}</span>
                      <span>Concurrency {fieldValue(key.concurrency_limit)}</span>
                    </td>
                    <td>
                      <pre className="json-preview">{JSON.stringify(sanitizeSecretJson(key.metadata), null, 2)}</pre>
                    </td>
                    <td>
                      <div className="action-row">
                        <button
                          className="table-action"
                          type="button"
                          onClick={() => startEditing(key)}
                          aria-label={`Edit provider key ${key.key_alias}`}
                        >
                          <Edit3 aria-hidden="true" size={15} />
                          Edit
                        </button>
                        <button
                          className="table-action"
                          type="button"
                          onClick={() => void handleDisable(key)}
                          disabled={busyId === key.id || key.status === "manual_disabled"}
                          aria-label={`Disable provider key ${key.key_alias}`}
                        >
                          <ShieldOff aria-hidden="true" size={15} />
                          Disable
                        </button>
                        <button
                          className="table-action table-action--danger"
                          type="button"
                          onClick={() => void handleDelete(key)}
                          disabled={busyId === key.id || key.status === "deleted"}
                          aria-label={`Delete provider key ${key.key_alias}`}
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
                  <td colSpan={7}>No provider keys returned.</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </section>

      {editingKeyId ? (
        <section className="admin-panel" aria-label="Patch provider key">
          <div className="section-heading">
            <div>
              <h2>Patch State</h2>
              <p>{editingKeyId}</p>
            </div>
          </div>

          <form className="provider-form" onSubmit={handlePatch}>
            <label className="field field--compact">
              Status
              <select
                value={editForm.status}
                onChange={(event) =>
                  setEditForm((current) => ({ ...current, status: event.currentTarget.value as ProviderKeyStatus }))
                }
              >
                {providerKeyStatuses.map((status) => (
                  <option key={status} value={status}>
                    {formatStatus(status)}
                  </option>
                ))}
              </select>
            </label>

            <label className="field">
              Metadata JSON
              <textarea
                value={editForm.metadata}
                onChange={(event) => setEditForm((current) => ({ ...current, metadata: event.currentTarget.value }))}
                spellCheck={false}
              />
            </label>

            <div className="action-row">
              <button className="primary-button primary-button--inline" type="submit" disabled={busyId === editingKeyId}>
                <Save aria-hidden="true" size={17} />
                Save patch
              </button>
              <button className="secondary-button" type="button" onClick={() => setEditingKeyId(null)}>
                Cancel
              </button>
            </div>
          </form>
        </section>
      ) : null}
    </div>
  );
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
