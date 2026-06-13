import type { Channel, ProviderKey } from "../../api/client";
import { StateChip, fieldValue, formatStatus, sanitizeSecretJson, shortId } from "../../components/adminUtils";
import { Edit3, KeyRound, RotateCcw, ShieldOff, Trash2 } from "../../components/icons";
import { ActionButton } from "../../design/ActionButton";
import { DataTable } from "../../design/DataTable";
import { formatDateTime } from "../../lib/format";
import { providerKeyProbeSummary } from "./providerPolicyUtils";

type ProviderKeysTableProps = {
  busyId: string | null;
  channels: Channel[];
  editingKeyId: string | null;
  keys: ProviderKey[];
  loading: boolean;
  onDelete: (key: ProviderKey) => void;
  onDisable: (key: ProviderKey) => void;
  onEdit: (key: ProviderKey) => void;
  onRecovery: (key: ProviderKey) => void;
  onRotate: (key: ProviderKey) => void;
};

export function ProviderKeysTable({
  busyId,
  channels,
  editingKeyId,
  keys,
  loading,
  onDelete,
  onDisable,
  onEdit,
  onRecovery,
  onRotate,
}: ProviderKeysTableProps) {
  return (
    <section aria-label="供应商密钥列表">
      <DataTable aria-label="供应商密钥列表" className="admin-table admin-table--keys">
        <thead>
          <tr>
            <th>Alias</th>
            <th>状态</th>
            <th>Lifecycle</th>
            <th>通道</th>
            <th>健康</th>
            <th>Recovery probe</th>
            <th>Rotation</th>
            <th>限额</th>
            <th>Metadata</th>
            <th>操作</th>
          </tr>
        </thead>
        <tbody>
          {loading ? (
            <tr>
              <td colSpan={10}>正在加载供应商密钥。</td>
            </tr>
          ) : keys.length > 0 ? (
            keys.map((key) => {
              const probe = providerKeyProbeSummary(key);

              return (
                <tr key={key.id} className={editingKeyId === key.id ? "table-row--selected" : undefined}>
                  <td>
                    <strong>{key.key_alias}</strong>
                    <span>{shortId(key.id)}</span>
                  </td>
                  <td>
                    <StateChip status={key.status} />
                    {key.last_error_code ? <span>{key.last_error_code}</span> : null}
                  </td>
                  <td>
                    <strong>{fieldValue(key.lifecycle_state)}</strong>
                    <span>generation {fieldValue(key.credential_generation?.value)}</span>
                    <span>source {fieldValue(key.credential_generation?.source)}</span>
                    <span>secret {key.omitted_secret_policy?.key_secret_returned === false ? "omitted" : "unknown"}</span>
                  </td>
                  <td>
                    <ProviderKeyChannelCell channel={channelById(channels, key.channel_id)} channelId={key.channel_id} />
                  </td>
                  <td>
                    <strong>{Math.round(key.health_score)}</strong>
                    {key.cooldown_until ? <span>冷却至 {formatDate(key.cooldown_until)}</span> : null}
                  </td>
                  <td>
                    <StateChip status={probe.status} />
                    <span>result {fieldValue(probe.result)}</span>
                    <span>error_code {fieldValue(probe.errorCode)}</span>
                    <span>last_checked_at {formatProbeDate(probe.lastCheckedAt)}</span>
                    <span>next_step {probe.nextStep}</span>
                  </td>
                  <td>
                    <StateChip status={key.rotation_needed?.needed ? "attention" : "ready"} />
                    <span>reason {fieldValue(key.rotation_needed?.reason)}</span>
                    <span>next {fieldValue(key.safe_next_action)}</span>
                  </td>
                  <td>
                    <span>RPM {fieldValue(key.rpm_limit)}</span>
                    <span>TPM {fieldValue(key.tpm_limit)}</span>
                    <span>并发 {fieldValue(key.concurrency_limit)}</span>
                  </td>
                  <td>
                    <pre className="json-preview">{JSON.stringify(sanitizeSecretJson(key.metadata ?? null), null, 2)}</pre>
                  </td>
                  <td>
                    <div className="action-row">
                    <ActionButton
                      variant="table"
                      icon={<Edit3 aria-hidden="true" size={15} />}
                      onClick={() => onEdit(key)}
                      aria-label={`编辑供应商密钥 ${key.key_alias}`}
                    >
                      编辑
                    </ActionButton>
                    <ActionButton
                      variant="table"
                      icon={<RotateCcw aria-hidden="true" size={15} />}
                      onClick={() => onRecovery(key)}
                      disabled={busyId === key.id || !canRecoverProviderKey(key)}
                      aria-label={`恢复供应商密钥 ${key.key_alias}`}
                    >
                      恢复
                    </ActionButton>
                    <ActionButton
                      variant="table"
                      icon={<KeyRound aria-hidden="true" size={15} />}
                      onClick={() => onRotate(key)}
                      disabled={busyId === key.id || key.status !== "enabled"}
                      aria-label={`轮换供应商密钥 ${key.key_alias}`}
                    >
                      轮换
                    </ActionButton>
                    <ActionButton
                      variant="table"
                      icon={<ShieldOff aria-hidden="true" size={15} />}
                      onClick={() => onDisable(key)}
                      disabled={busyId === key.id || key.status === "manual_disabled"}
                      aria-label={`禁用供应商密钥 ${key.key_alias}`}
                    >
                      禁用
                    </ActionButton>
                    <ActionButton
                      className="table-action--danger"
                      variant="table"
                      icon={<Trash2 aria-hidden="true" size={15} />}
                      onClick={() => onDelete(key)}
                      disabled={busyId === key.id || key.status === "deleted"}
                      aria-label={`删除供应商密钥 ${key.key_alias}`}
                    >
                      删除
                    </ActionButton>
                    </div>
                  </td>
                </tr>
              );
            })
          ) : (
            <tr>
              <td colSpan={10}>暂无供应商密钥。</td>
            </tr>
          )}
        </tbody>
      </DataTable>
    </section>
  );
}

function canRecoverProviderKey(key: ProviderKey): boolean {
  return key.status === "cooldown" || key.status === "degraded" || key.status === "recovery_probe";
}

function ProviderKeyChannelCell({ channel, channelId }: { channel?: Channel; channelId: string }) {
  if (!channel) {
    return (
      <>
        <strong>{shortId(channelId)}</strong>
        <span>未找到通道</span>
      </>
    );
  }

  return (
    <>
      <strong>{channel.name}</strong>
      <span>
        {formatStatus(channel.status)} · {shortId(channel.id)}
      </span>
    </>
  );
}

function channelById(channels: Channel[], channelId: string): Channel | undefined {
  return channels.find((channel) => channel.id === channelId);
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

function formatProbeDate(value: string): string {
  return value === "-" ? value : formatDateTime(value);
}
