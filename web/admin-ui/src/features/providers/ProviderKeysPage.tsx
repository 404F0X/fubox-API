import { FormEvent, useEffect, useState } from "react";
import {
  type Channel,
  createProviderKey,
  deleteProviderKey,
  listChannels,
  listProviderKeys,
  patchProviderKey,
  type ProviderKey,
  requestProviderKeyRecovery,
  rotateProviderKey,
  type ProviderKeyStatus,
} from "../../api/client";
import {
  errorMessage,
  parseSafeMetadata,
  sanitizeSecretJson,
} from "../../components/adminUtils";
import { Plus, RefreshCw } from "../../components/icons";
import {
  ProviderKeyCreateDialog,
  type ProviderKeyCreateFormState,
  ProviderKeyEditDialog,
  type ProviderKeyEditFormState,
  ProviderKeyRecoveryDialog,
  ProviderKeyRotateDialog,
  type ProviderKeyRotateFormState,
} from "./ProviderKeyDialogs";
import { ProviderKeysTable } from "./ProviderKeysTable";

const writableProviderKeyStatuses: ProviderKeyStatus[] = [
  "enabled",
  "manual_disabled",
  "degraded",
  "recovery_probe",
];

const defaultCreateForm: ProviderKeyCreateFormState = {
  channelId: "",
  keyAlias: "",
  metadata: "{}",
  secret: "",
  status: "enabled",
};

export function ProviderKeysPage() {
  const [busyId, setBusyId] = useState<string | null>(null);
  const [channels, setChannels] = useState<Channel[]>([]);
  const [createForm, setCreateForm] = useState<ProviderKeyCreateFormState>(defaultCreateForm);
  const [editForm, setEditForm] = useState<ProviderKeyEditFormState>({ metadata: "{}", status: "enabled" });
  const [editingKeyId, setEditingKeyId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [keys, setKeys] = useState<ProviderKey[]>([]);
  const [loading, setLoading] = useState(true);
  const [openCreateDialog, setOpenCreateDialog] = useState(false);
  const [recoveryKey, setRecoveryKey] = useState<ProviderKey | null>(null);
  const [rotateForm, setRotateForm] = useState<ProviderKeyRotateFormState | null>(null);
  const [success, setSuccess] = useState<string | null>(null);

  async function loadKeys() {
    setError(null);
    setLoading(true);

    try {
      const [nextKeys, nextChannels] = await Promise.all([listProviderKeys(), listChannels()]);
      setKeys(nextKeys);
      setChannels(nextChannels);
    } catch (requestError) {
      setError(errorMessage(requestError));
      setKeys([]);
      setChannels([]);
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
      setSuccess("供应商密钥已创建。提交的 secret 已从表单清除。");
      setOpenCreateDialog(false);
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
      if (!isWritableProviderKeyStatus(editForm.status)) {
        throw new Error("请选择可由管理员写入的状态。运行时失败状态只能通过恢复流程处理。");
      }
      const metadata = parseSafeMetadata(editForm.metadata);
      const updated = await patchProviderKey(editingKeyId, {
        metadata,
        status: editForm.status,
      });
      setKeys((current) => current.map((key) => (key.id === updated.id ? updated : key)));
      setSuccess("供应商密钥状态已更新。");
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
      setSuccess(`${key.key_alias} 已禁用。`);
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setBusyId(null);
    }
  }

  async function handleRecovery(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();

    if (!recoveryKey) {
      return;
    }

    const key = recoveryKey;
    setBusyId(key.id);
    setError(null);
    setSuccess(null);

    try {
      const response = await requestProviderKeyRecovery(key.id, {
        reason: "operator requested recovery from provider key page",
        target_status: "recovery_probe",
      });
      setKeys((current) => current.map((currentKey) => (currentKey.id === response.provider_key.id ? response.provider_key : currentKey)));
      if (editingKeyId === key.id) {
        setEditForm((current) => ({ ...current, status: response.provider_key.status }));
      }
      setSuccess(`${key.key_alias} 已进入恢复探针。`);
      setRecoveryKey(null);
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setBusyId(null);
    }
  }

  async function handleRotate(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();

    if (!rotateForm) {
      return;
    }

    const keyId = rotateForm.keyId;
    setBusyId(keyId);
    setError(null);
    setSuccess(null);

    try {
      const response = await rotateProviderKey(keyId, {
        key_alias: rotateForm.keyAlias.trim() || undefined,
        reason: rotateForm.reason.trim() || undefined,
        secret: rotateForm.secret,
      });
      setKeys((current) => {
        const replaced = current.map((currentKey) => {
          if (currentKey.id === response.old_provider_key.id) {
            return response.old_provider_key;
          }
          if (currentKey.id === response.new_provider_key.id) {
            return response.new_provider_key;
          }
          return currentKey;
        });
        if (replaced.some((currentKey) => currentKey.id === response.new_provider_key.id)) {
          return replaced;
        }
        return [response.new_provider_key, ...replaced];
      });
      if (editingKeyId === response.old_provider_key.id) {
        setEditingKeyId(null);
      }
      setRotateForm(null);
      setSuccess("供应商密钥轮换已提交。下一步：运行恢复探针或刷新通道健康；提交的 secret 已从表单清除。");
    } catch (requestError) {
      setError(errorMessage(requestError));
      setRotateForm((current) => (current ? { ...current, secret: "" } : current));
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
      setSuccess(`${key.key_alias} 已删除。`);
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setBusyId(null);
    }
  }

  function startEditing(key: ProviderKey) {
    setEditingKeyId(key.id);
    setEditForm({
      metadata: JSON.stringify(sanitizeSecretJson(key.metadata ?? null), null, 2),
      status: key.status,
    });
  }

  function startRotate(key: ProviderKey) {
    setRotateForm({
      keyAlias: `${key.key_alias}-rotated`,
      keyId: key.id,
      reason: "operator credential rotation",
      secret: "",
    });
    setError(null);
    setSuccess(null);
  }

  function closeCreateDialog() {
    setOpenCreateDialog(false);
    setCreateForm(defaultCreateForm);
  }

  function startRecovery(key: ProviderKey) {
    setRecoveryKey(key);
    setError(null);
    setSuccess(null);
  }

  useEffect(() => {
    void loadKeys();
  }, []);

  return (
    <div className="admin-page" aria-label="供应商密钥">
      <section className="admin-panel" aria-label="供应商密钥控制">
        <div className="section-heading">
          <div>
            <h2>供应商密钥</h2>
            <p>一次性创建上游凭据，之后只管理非密钥状态和 metadata。</p>
          </div>
          <div className="action-row">
            <button className="primary-button primary-button--inline" type="button" onClick={() => setOpenCreateDialog(true)}>
              <Plus aria-hidden="true" size={17} />
              添加密钥
            </button>
            <button className="secondary-button" type="button" onClick={() => void loadKeys()} disabled={loading}>
              <RefreshCw aria-hidden="true" size={18} className={loading ? "spin" : undefined} />
              刷新
            </button>
          </div>
        </div>

        <div className="status-grid status-grid--compact" aria-label="供应商密钥摘要">
          <article>
            <span>密钥</span>
            <strong>{keys.length}</strong>
            <p>{keys.filter((key) => key.status === "enabled").length} 已启用</p>
          </article>
          <article>
            <span>通道</span>
            <strong>{channels.length}</strong>
            <p>凭据目标</p>
          </article>
          <article>
            <span>健康</span>
            <strong>{averageHealth(keys)}</strong>
            <p>平均分</p>
          </article>
        </div>

        {error ? <p className="form-status form-status--error">{error}</p> : null}
        {success ? <p className="form-status form-status--success">{success}</p> : null}
      </section>

      <ProviderKeysTable
        busyId={busyId}
        channels={channels}
        editingKeyId={editingKeyId}
        keys={keys}
        loading={loading}
        onDelete={(key) => void handleDelete(key)}
        onDisable={(key) => void handleDisable(key)}
        onEdit={startEditing}
        onRecovery={startRecovery}
        onRotate={startRotate}
      />

      {openCreateDialog ? (
        <ProviderKeyCreateDialog
          channels={channels}
          form={createForm}
          onChange={setCreateForm}
          onClose={closeCreateDialog}
          onSubmit={(event) => void handleCreate(event)}
          statuses={writableProviderKeyStatuses}
        />
      ) : null}

      {editingKeyId ? (
        <ProviderKeyEditDialog
          busy={busyId === editingKeyId}
          form={editForm}
          keyId={editingKeyId}
          onChange={setEditForm}
          onClose={() => setEditingKeyId(null)}
          onSubmit={(event) => void handlePatch(event)}
          statuses={writableProviderKeyStatuses}
        />
      ) : null}

      {rotateForm ? (
        <ProviderKeyRotateDialog
          busy={busyId === rotateForm.keyId}
          form={rotateForm}
          onChange={setRotateForm}
          onClose={() => setRotateForm(null)}
          onSubmit={(event) => void handleRotate(event)}
        />
      ) : null}

      {recoveryKey ? (
        <ProviderKeyRecoveryDialog
          busy={busyId === recoveryKey.id}
          providerKey={recoveryKey}
          onClose={() => setRecoveryKey(null)}
          onSubmit={(event) => void handleRecovery(event)}
        />
      ) : null}
    </div>
  );
}

function averageHealth(keys: ProviderKey[]): string {
  if (keys.length === 0) {
    return "-";
  }

  const average = keys.reduce((total, key) => total + key.health_score, 0) / keys.length;
  return String(Math.round(average));
}

function isWritableProviderKeyStatus(status: ProviderKeyStatus): boolean {
  return writableProviderKeyStatuses.includes(status);
}
