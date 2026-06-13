import { FormEvent } from "react";
import type { Channel, ProviderKey, ProviderKeyStatus } from "../../api/client";
import { formatStatus, shortId } from "../../components/adminUtils";
import { KeyRound, Plus, RotateCcw, Save, X } from "../../components/icons";

export type ProviderKeyCreateFormState = {
  channelId: string;
  keyAlias: string;
  metadata: string;
  secret: string;
  status: ProviderKeyStatus;
};

export type ProviderKeyEditFormState = {
  metadata: string;
  status: ProviderKeyStatus;
};

export type ProviderKeyRotateFormState = {
  keyAlias: string;
  keyId: string;
  reason: string;
  secret: string;
};

type ProviderKeyCreateDialogProps = {
  channels: Channel[];
  form: ProviderKeyCreateFormState;
  onChange: (nextForm: ProviderKeyCreateFormState) => void;
  onClose: () => void;
  onSubmit: (event: FormEvent<HTMLFormElement>) => void;
  statuses: ProviderKeyStatus[];
};

type ProviderKeyEditDialogProps = {
  busy: boolean;
  form: ProviderKeyEditFormState;
  keyId: string;
  onChange: (nextForm: ProviderKeyEditFormState) => void;
  onClose: () => void;
  onSubmit: (event: FormEvent<HTMLFormElement>) => void;
  statuses: ProviderKeyStatus[];
};

type ProviderKeyRotateDialogProps = {
  busy: boolean;
  form: ProviderKeyRotateFormState;
  onChange: (nextForm: ProviderKeyRotateFormState) => void;
  onClose: () => void;
  onSubmit: (event: FormEvent<HTMLFormElement>) => void;
};

type ProviderKeyRecoveryDialogProps = {
  busy: boolean;
  providerKey: ProviderKey;
  onClose: () => void;
  onSubmit: (event: FormEvent<HTMLFormElement>) => void;
};

export function ProviderKeyCreateDialog({
  channels,
  form,
  onChange,
  onClose,
  onSubmit,
  statuses,
}: ProviderKeyCreateDialogProps) {
  return (
    <div className="wizard-overlay" role="dialog" aria-modal="true" aria-label="创建供应商密钥对话框">
      <div className="wizard-panel">
        <div className="wizard-header">
          <div>
            <span>上游凭据</span>
            <h3>添加供应商密钥</h3>
            <p>secret 只提交一次并在本地清除；后续编辑只能修改安全 metadata 和状态。</p>
          </div>
          <button className="icon-button" type="button" onClick={onClose} aria-label="关闭创建供应商密钥对话框">
            <X aria-hidden="true" size={18} />
          </button>
        </div>
        <form className="provider-form wizard-body" onSubmit={onSubmit}>
          <div className="form-grid">
            <label className="field">
              通道
              <select
                value={form.channelId}
                onChange={(event) => onChange({ ...form, channelId: event.currentTarget.value })}
                required
              >
                <option value="">选择通道</option>
                {channels.map((channel) => (
                  <option key={channel.id} value={channel.id}>
                    {channelOptionLabel(channel)}
                  </option>
                ))}
              </select>
            </label>
            {form.channelId ? (
              <ProviderKeySelectedChannel channel={channelById(channels, form.channelId)} channelId={form.channelId} />
            ) : null}

            <label className="field">
              Alias
              <input
                value={form.keyAlias}
                onChange={(event) => onChange({ ...form, keyAlias: event.currentTarget.value })}
                required
                placeholder="openai primary"
              />
            </label>

            <label className="field">
              状态
              <select
                value={form.status}
                onChange={(event) => onChange({ ...form, status: event.currentTarget.value as ProviderKeyStatus })}
              >
                {statuses.map((status) => (
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
                value={form.secret}
                onChange={(event) => onChange({ ...form, secret: event.currentTarget.value })}
                required
                type="password"
              />
            </label>
          </div>

          <label className="field">
            Metadata JSON
            <textarea
              value={form.metadata}
              onChange={(event) => onChange({ ...form, metadata: event.currentTarget.value })}
              spellCheck={false}
            />
          </label>

          <button className="primary-button primary-button--inline" type="submit">
            <Plus aria-hidden="true" size={17} />
            创建
          </button>
        </form>
      </div>
    </div>
  );
}

export function ProviderKeyEditDialog({
  busy,
  form,
  keyId,
  onChange,
  onClose,
  onSubmit,
  statuses,
}: ProviderKeyEditDialogProps) {
  return (
    <div className="wizard-overlay" role="dialog" aria-modal="true" aria-label="修补供应商密钥对话框">
      <div className="wizard-panel">
        <div className="wizard-header">
          <div>
            <span>安全密钥 metadata</span>
            <h3>修补状态</h3>
            <p>{keyId}</p>
          </div>
          <button className="icon-button" type="button" onClick={onClose} aria-label="关闭修补供应商密钥对话框">
            <X aria-hidden="true" size={18} />
          </button>
        </div>
        <form className="provider-form wizard-body" onSubmit={onSubmit}>
          <label className="field field--compact">
            状态
            <select
              value={form.status}
              onChange={(event) => onChange({ ...form, status: event.currentTarget.value as ProviderKeyStatus })}
            >
              {!statuses.includes(form.status) ? (
                <option value={form.status} disabled>
                  当前运行时状态：{formatStatus(form.status)}
                </option>
              ) : null}
              {statuses.map((status) => (
                <option key={status} value={status}>
                  {formatStatus(status)}
                </option>
              ))}
            </select>
          </label>

          <label className="field">
            Metadata JSON
            <textarea
              value={form.metadata}
              onChange={(event) => onChange({ ...form, metadata: event.currentTarget.value })}
              spellCheck={false}
            />
          </label>

          <div className="action-row">
            <button className="primary-button primary-button--inline" type="submit" disabled={busy}>
              <Save aria-hidden="true" size={17} />
              保存补丁
            </button>
            <button className="secondary-button" type="button" onClick={onClose}>
              取消
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

export function ProviderKeyRotateDialog({
  busy,
  form,
  onChange,
  onClose,
  onSubmit,
}: ProviderKeyRotateDialogProps) {
  return (
    <div className="wizard-overlay" role="dialog" aria-modal="true" aria-label="轮换供应商密钥对话框">
      <div className="wizard-panel">
        <div className="wizard-header">
          <div>
            <span>凭据轮换</span>
            <h3>轮换供应商密钥</h3>
            <p>{form.keyId}</p>
          </div>
          <button className="icon-button" type="button" onClick={onClose} aria-label="关闭轮换供应商密钥对话框">
            <X aria-hidden="true" size={18} />
          </button>
        </div>
        <form className="provider-form wizard-body" onSubmit={onSubmit}>
          <div className="form-grid">
            <label className="field">
              新 Alias
              <input
                value={form.keyAlias}
                onChange={(event) => onChange({ ...form, keyAlias: event.currentTarget.value })}
                required
              />
            </label>
            <label className="field">
              新 Secret / API key
              <input
                autoComplete="new-password"
                value={form.secret}
                onChange={(event) => onChange({ ...form, secret: event.currentTarget.value })}
                required
                type="password"
              />
            </label>
          </div>
          <label className="field">
            轮换原因
            <input
              value={form.reason}
              onChange={(event) => onChange({ ...form, reason: event.currentTarget.value })}
            />
          </label>
          <div className="action-row">
            <button className="primary-button primary-button--inline" type="submit" disabled={busy}>
              <KeyRound aria-hidden="true" size={17} />
              提交轮换
            </button>
            <button className="secondary-button" type="button" onClick={onClose}>
              取消
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

export function ProviderKeyRecoveryDialog({
  busy,
  providerKey,
  onClose,
  onSubmit,
}: ProviderKeyRecoveryDialogProps) {
  return (
    <div className="wizard-overlay" role="dialog" aria-modal="true" aria-label="恢复供应商密钥对话框">
      <div className="wizard-panel">
        <div className="wizard-header">
          <div>
            <span>恢复探针</span>
            <h3>请求恢复探针</h3>
            <p>{providerKey.key_alias}</p>
          </div>
          <button className="icon-button" type="button" onClick={onClose} aria-label="关闭恢复供应商密钥对话框">
            <X aria-hidden="true" size={18} />
          </button>
        </div>
        <form className="provider-form wizard-body" onSubmit={onSubmit}>
          <div className="detail-panel detail-panel--compact" aria-label="供应商密钥恢复安全状态">
            <h3>安全状态</h3>
            <dl className="detail-list">
              <div>
                <dt>Key</dt>
                <dd>{shortId(providerKey.id)}</dd>
              </div>
              <div>
                <dt>当前状态</dt>
                <dd>{formatStatus(providerKey.status)}</dd>
              </div>
              <div>
                <dt>凭据材料</dt>
                <dd>omitted</dd>
              </div>
              <div>
                <dt>下一步</dt>
                <dd>提交后进入 recovery_probe；如后端 live probe 未接入，页面仅显示安全占位。</dd>
              </div>
            </dl>
          </div>
          <div className="action-row">
            <button className="primary-button primary-button--inline" type="submit" disabled={busy}>
              <RotateCcw aria-hidden="true" size={17} />
              提交恢复探针
            </button>
            <button className="secondary-button" type="button" onClick={onClose}>
              取消
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

function ProviderKeySelectedChannel({ channel, channelId }: { channel?: Channel; channelId: string }) {
  return (
    <div className="detail-panel detail-panel--compact" aria-label="已选择的供应商密钥通道">
      <h3>已选择通道</h3>
      <dl className="detail-list">
        <div>
          <dt>名称</dt>
          <dd>{channel?.name ?? "未知通道"}</dd>
        </div>
        <div>
          <dt>状态</dt>
          <dd>{channel ? formatStatus(channel.status) : "-"}</dd>
        </div>
        <div>
          <dt>通道</dt>
          <dd>{shortId(channelId)}</dd>
        </div>
        <div>
          <dt>供应商</dt>
          <dd>{shortId(channel?.provider_id)}</dd>
        </div>
        <div>
          <dt>Endpoint</dt>
          <dd>{channel?.endpoint ?? "-"}</dd>
        </div>
      </dl>
    </div>
  );
}

function channelById(channels: Channel[], channelId: string): Channel | undefined {
  return channels.find((channel) => channel.id === channelId);
}

function channelOptionLabel(channel: Channel): string {
  return `${channel.name} · ${formatStatus(channel.status)} · 供应商 ${shortId(channel.provider_id)}`;
}
