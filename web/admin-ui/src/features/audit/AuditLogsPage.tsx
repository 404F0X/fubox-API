import { FormEvent, useEffect, useMemo, useRef, useState } from "react";

import {
  type AuditLog,
  type AuditLogListFilters,
  type JsonValue,
  listAuditLogs,
} from "../../api/client";
import { ActionButton } from "../../design/ActionButton";
import { DataTable } from "../../design/DataTable";
import { EmptyState } from "../../design/EmptyState";
import { Field } from "../../design/Field";
import { SectionHeader } from "../../design/SectionHeader";
import { StatusChip } from "../../design/StatusChip";
import { Toolbar } from "../../design/Toolbar";
import {
  errorMessage,
  isJsonRecord,
  safeFieldValue,
  sanitizeDisplayJson,
  shortId,
} from "../../components/adminUtils";
import { Eye, RefreshCw, Search, X } from "../../components/icons";
import type { ApiKeysFocusTarget, AuditLogsFocusTarget, UsersFocusTarget } from "../../app/types";

type FilterState = {
  action: string;
  actor: string;
  createdFrom: string;
  createdTo: string;
  entity: string;
  limit: string;
  resourceId: string;
};

type AuditSummary = {
  action: string;
  actor: string;
  auditId: string;
  entity: string;
  metadataSummary: SummaryPair[];
  reason: string;
  requestId: string;
  status: string;
  time: string;
};

type SummaryPair = {
  label: string;
  value: string;
};

type AuditLogsPageProps = {
  focusTarget?: AuditLogsFocusTarget | null;
  onOpenApiKey?: (target: ApiKeysFocusTarget) => void;
  onOpenRequestDetail?: (requestId: string) => void;
  onOpenUser?: (target: UsersFocusTarget) => void;
};

type AuditNavigationTarget =
  | {
      kind: "api_key";
      label: string;
      target: ApiKeysFocusTarget;
    }
  | {
      kind: "request";
      label: string;
      requestId: string;
    }
  | {
      kind: "user";
      label: string;
      target: UsersFocusTarget;
    }
  | {
      kind: "placeholder";
      label: string;
      reason: string;
    };

const defaultFilters: FilterState = {
  action: "",
  actor: "",
  createdFrom: "",
  createdTo: "",
  entity: "",
  limit: "50",
  resourceId: "",
};

const metadataSummaryKeys = [
  "reason",
  "action_result",
  "format",
  "row_count",
  "filter_summary",
  "requested_action",
  "from_status",
  "to_status",
  "status",
  "status_changed",
  "bulk_leak_action",
  "restore_policy",
  "transactional_audit",
  "secret_safe",
  "secret_returned",
  "payload_omitted",
  "csv_content_logged",
  "raw_filters_logged",
  "omitted_material",
  "ledger_write",
  "audit_log_write",
  "operation",
  "local_only",
  "merchant_connected",
  "amount",
  "currency",
  "project_id",
  "wallet_id",
  "order_id",
  "request_id",
  "ledger_entry_id",
  "action_result_code",
];

export function AuditLogsPage({ focusTarget, onOpenApiKey, onOpenRequestDetail, onOpenUser }: AuditLogsPageProps = {}) {
  const [auditLogs, setAuditLogs] = useState<AuditLog[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [filters, setFilters] = useState<FilterState>(defaultFilters);
  const [loading, setLoading] = useState(true);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const requestSeq = useRef(0);

  async function loadLogs(nextFilters = filters) {
    const seq = requestSeq.current + 1;
    requestSeq.current = seq;
    setError(null);
    setLoading(true);

    try {
      const nextLogs = await listAuditLogs(toListFilters(nextFilters));
      if (requestSeq.current === seq) {
        setAuditLogs(nextLogs);
        setSelectedId((current) => (current && nextLogs.some((log) => log.id === current) ? current : null));
      }
    } catch (requestError) {
      if (requestSeq.current === seq) {
        setAuditLogs([]);
        setSelectedId(null);
        setError(errorMessage(requestError));
      }
    } finally {
      if (requestSeq.current === seq) {
        setLoading(false);
      }
    }
  }

  function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    void loadLogs(filters);
  }

  useEffect(() => {
    void loadLogs(defaultFilters);
  }, []);

  useEffect(() => {
    if (!focusTarget) {
      return;
    }

    const nextFilters = auditFocusFilters(focusTarget);
    setFilters(nextFilters);
    void loadLogs(nextFilters).then(() => {
      const auditLogId = focusTarget.auditLogId?.trim();
      if (auditLogId) {
        setSelectedId(auditLogId);
      }
    });
  }, [focusTarget?.auditLogId, focusTarget?.requestId, focusTarget?.resourceId, focusTarget?.resourceType]);

  const selectedLog = auditLogs.find((log) => log.id === selectedId) ?? null;
  const selectedSummary = selectedLog ? summarizeAuditLog(selectedLog) : null;
  const rows = useMemo(
    () => auditLogs.map((log) => ({ log, summary: summarizeAuditLog(log), target: auditNavigationTarget(log) })),
    [auditLogs],
  );

  return (
    <div className="admin-page" aria-label="Admin audit logs">
      <section className="admin-panel" aria-label="Audit log filters">
        <SectionHeader
          title="Admin audit logs"
          description="Recent admin operations, filtered by time, actor, action, and entity. Metadata raw, secrets, and idempotency material stay hidden."
          actions={
            <ActionButton
              disabled={loading}
              icon={<RefreshCw aria-hidden="true" className={loading ? "spin" : undefined} size={16} />}
              onClick={() => void loadLogs()}
            >
              Refresh
            </ActionButton>
          }
        />

        <form onSubmit={handleSubmit}>
          <Toolbar>
            <Field label="Time from">
              <input
                value={filters.createdFrom}
                onChange={(event) => {
                  const value = event.currentTarget.value;
                  setFilters((current) => ({ ...current, createdFrom: value }));
                }}
                placeholder="2026-06-12T00:00:00Z"
              />
            </Field>
            <Field label="Time to">
              <input
                value={filters.createdTo}
                onChange={(event) => {
                  const value = event.currentTarget.value;
                  setFilters((current) => ({ ...current, createdTo: value }));
                }}
                placeholder="2026-06-12T23:59:59Z"
              />
            </Field>
            <Field label="Actor">
              <input
                value={filters.actor}
                onChange={(event) => {
                  const value = event.currentTarget.value;
                  setFilters((current) => ({ ...current, actor: value }));
                }}
                placeholder="actor user id"
              />
            </Field>
            <Field label="Action">
              <input
                value={filters.action}
                onChange={(event) => {
                  const value = event.currentTarget.value;
                  setFilters((current) => ({ ...current, action: value }));
                }}
                placeholder="user.disable"
              />
            </Field>
            <Field label="Entity">
              <input
                value={filters.entity}
                onChange={(event) => {
                  const value = event.currentTarget.value;
                  setFilters((current) => ({ ...current, entity: value }));
                }}
                placeholder="user, virtual_key, ledger_entry"
              />
            </Field>
            <Field className="field--compact" label="Limit">
              <input
                min="1"
                type="number"
                value={filters.limit}
                onChange={(event) => {
                  const value = event.currentTarget.value;
                  setFilters((current) => ({ ...current, limit: value }));
                }}
              />
            </Field>
            <ActionButton icon={<Search aria-hidden="true" size={16} />} type="submit" variant="primary">
              Search
            </ActionButton>
          </Toolbar>
        </form>

        <QuickFilters
          disabled={loading}
          onSelect={(patch) => {
            const nextFilters = { ...filters, ...patch };
            setFilters(nextFilters);
            void loadLogs(nextFilters);
          }}
        />

        {error ? <p className="form-status form-status--error">{error}</p> : null}
      </section>

      <section className="admin-panel" aria-label="Audit log list">
        <SectionHeader
          title="Recent operations"
          description="Reason and status are derived from safe audit metadata; raw metadata and snapshots are not rendered by default."
        />

        <DataTable aria-label="Admin audit log list" className="admin-table admin-table--audit-logs" stickyFirstColumn>
          <thead>
            <tr>
              <th>Time</th>
              <th>Actor</th>
              <th>Action</th>
              <th>Entity</th>
              <th>Reason</th>
              <th>Status</th>
              <th>Audit ID</th>
              <th>Jump</th>
              <th>Details</th>
            </tr>
          </thead>
          <tbody>
            {loading ? (
              <tr>
                <td colSpan={9}>Loading audit logs.</td>
              </tr>
            ) : rows.length > 0 ? (
              rows.map(({ log, summary, target }) => (
                <tr key={log.id} className={selectedId === log.id ? "table-row--selected" : undefined}>
                  <td>
                    <strong>{summary.time}</strong>
                    <span>{safeShortId(log.request_id)}</span>
                  </td>
                  <td>{summary.actor}</td>
                  <td>
                    <strong>{summary.action}</strong>
                  </td>
                  <td>
                    <strong>{summary.entity}</strong>
                  </td>
                  <td>{summary.reason}</td>
                  <td>
                    <StatusChip tone={statusTone(summary.status)}>{summary.status}</StatusChip>
                  </td>
                  <td>{summary.auditId}</td>
                  <td>
                    <AuditNavigationAction
                      target={target}
                      onOpenApiKey={onOpenApiKey}
                      onOpenRequestDetail={onOpenRequestDetail}
                      onOpenUser={onOpenUser}
                    />
                  </td>
                  <td>
                    <ActionButton
                      aria-label={`查看审计日志 ${safeFieldValue(log.id)}`}
                      icon={<Eye aria-hidden="true" size={14} />}
                      onClick={() => setSelectedId(log.id)}
                      variant="table"
                    >
                      View
                    </ActionButton>
                  </td>
                </tr>
              ))
            ) : (
              <tr>
                <td colSpan={9}>
                  <EmptyState title="No audit logs found" detail="Try widening the time range or clearing actor/action/entity filters." />
                </td>
              </tr>
            )}
          </tbody>
        </DataTable>
      </section>

      <AuditLogDetailPanel
        auditLog={selectedLog}
        navigationTarget={selectedLog ? auditNavigationTarget(selectedLog) : null}
        onClose={() => setSelectedId(null)}
        onOpenApiKey={onOpenApiKey}
        onOpenRequestDetail={onOpenRequestDetail}
        onOpenUser={onOpenUser}
        summary={selectedSummary}
      />
    </div>
  );
}

export default AuditLogsPage;

function QuickFilters({
  disabled,
  onSelect,
}: {
  disabled: boolean;
  onSelect: (patch: Partial<FilterState>) => void;
}) {
  const items: Array<{ label: string; patch: Partial<FilterState> }> = [
    { label: "User disable/restore", patch: { action: "", entity: "user" } },
    { label: "Key restore", patch: { action: "virtual_key.restore", entity: "virtual_key" } },
    { label: "Bulk leak", patch: { action: "", entity: "virtual_key" } },
    { label: "Payment demo", patch: { action: "billing.local_payment_demo.mark_paid", entity: "local_payment_demo" } },
    { label: "Billing adjustment", patch: { action: "ledger.adjust", entity: "ledger_entry" } },
  ];

  return (
    <div className="toolbar-v2" aria-label="Common audit filters">
      {items.map((item) => (
        <ActionButton key={item.label} disabled={disabled} onClick={() => onSelect(item.patch)}>
          {item.label}
        </ActionButton>
      ))}
      <ActionButton disabled={disabled} icon={<X aria-hidden="true" size={15} />} onClick={() => onSelect(defaultFilters)}>
        Clear
      </ActionButton>
    </div>
  );
}

function AuditNavigationAction({
  onOpenApiKey,
  onOpenRequestDetail,
  onOpenUser,
  target,
}: {
  onOpenApiKey?: (target: ApiKeysFocusTarget) => void;
  onOpenRequestDetail?: (requestId: string) => void;
  onOpenUser?: (target: UsersFocusTarget) => void;
  target: AuditNavigationTarget;
}) {
  if (target.kind === "api_key") {
    const disabled = !onOpenApiKey || (!target.target.keyId && !target.target.projectId && !target.target.status);
    return (
      <ActionButton
        disabled={disabled}
        icon={<Search aria-hidden="true" size={14} />}
        onClick={() => onOpenApiKey?.(target.target)}
        variant="table"
      >
        {target.label}
      </ActionButton>
    );
  }

  if (target.kind === "request") {
    const disabled = !onOpenRequestDetail || !target.requestId;
    return (
      <ActionButton
        disabled={disabled}
        icon={<Eye aria-hidden="true" size={14} />}
        onClick={() => onOpenRequestDetail?.(target.requestId)}
        variant="table"
      >
        {target.label}
      </ActionButton>
    );
  }

  if (target.kind === "user") {
    const disabled = !onOpenUser || (!target.target.projectId && !target.target.userId && !target.target.status);
    return (
      <ActionButton
        disabled={disabled}
        icon={<Search aria-hidden="true" size={14} />}
        onClick={() => onOpenUser?.(target.target)}
        variant="table"
      >
        {target.label}
      </ActionButton>
    );
  }

  return <span className="muted-copy" title={target.reason}>{target.label}</span>;
}

function AuditLogDetailPanel({
  auditLog,
  navigationTarget,
  onClose,
  onOpenApiKey,
  onOpenRequestDetail,
  onOpenUser,
  summary,
}: {
  auditLog: AuditLog | null;
  navigationTarget: AuditNavigationTarget | null;
  onClose: () => void;
  onOpenApiKey?: (target: ApiKeysFocusTarget) => void;
  onOpenRequestDetail?: (requestId: string) => void;
  onOpenUser?: (target: UsersFocusTarget) => void;
  summary: AuditSummary | null;
}) {
  if (!auditLog || !summary) {
    return null;
  }

  const readback = auditLog.audit_log_detail_readback;
  const resourceRefs = readback?.resource_refs;
  const presence = readback?.actor_session_presence;
  const redaction = readback?.metadata_redaction_summary;

  return (
    <section className="detail-grid detail-grid--compact" aria-label="Audit log details">
      <article className="admin-panel">
        <SectionHeader
          title="Audit detail"
          description={safeFieldValue(auditLog.id)}
          actions={
            <ActionButton icon={<X aria-hidden="true" size={15} />} onClick={onClose}>
              Close
            </ActionButton>
          }
        />
        <dl className="detail-list">
          <div>
            <dt>Action</dt>
            <dd>{summary.action}</dd>
          </div>
          <div>
            <dt>Entity</dt>
            <dd>{summary.entity}</dd>
          </div>
          <div>
            <dt>Reason</dt>
            <dd>{summary.reason}</dd>
          </div>
          <div>
            <dt>Status</dt>
            <dd>{safeFieldValue(readback?.action_result ?? summary.status)}</dd>
          </div>
          <div>
            <dt>Actor</dt>
            <dd>{summary.actor}</dd>
          </div>
          <div>
            <dt>Request</dt>
            <dd>{summary.requestId}</dd>
          </div>
          <div>
            <dt>Created</dt>
            <dd>{formatFullDate(auditLog.created_at)}</dd>
          </div>
          <div>
            <dt>Safe jump</dt>
            <dd>
              {navigationTarget ? (
                <AuditNavigationAction
                  target={navigationTarget}
                  onOpenApiKey={onOpenApiKey}
                  onOpenRequestDetail={onOpenRequestDetail}
                  onOpenUser={onOpenUser}
                />
              ) : (
                "No safe target."
              )}
            </dd>
          </div>
        </dl>
      </article>

      {readback ? (
        <article className="admin-panel">
          <SectionHeader
            title="Detail readback"
            description={safeFieldValue(readback.schema)}
          />
          <dl className="detail-list">
            <div>
              <dt>Resource refs</dt>
              <dd>
                {safeFieldValue(resourceRefs?.resource_type)} / {safeShortId(resourceRefs?.resource_id)} / request{" "}
                {safeShortId(resourceRefs?.request_id)}
              </dd>
            </div>
            <div>
              <dt>Actor/session</dt>
              <dd>
                actor={String(presence?.actor_user_id_present === true)} session=
                {String(presence?.actor_session_id_present === true)}
              </dd>
            </div>
            <div>
              <dt>Redaction summary</dt>
              <dd>
                metadata={String(redaction?.redacted_field_count ?? 0)}, before=
                {String(redaction?.before_snapshot_redacted_field_count ?? 0)}, after=
                {String(redaction?.after_snapshot_redacted_field_count ?? 0)}
              </dd>
            </div>
            <div>
              <dt>Safe keys</dt>
              <dd>{redaction?.safe_summary_keys?.slice(0, 6).map(safeFieldValue).join(", ") || "No safe keys."}</dd>
            </div>
            <div>
              <dt>Safe next action</dt>
              <dd>{safeFieldValue(readback.safe_next_action)}</dd>
            </div>
          </dl>
        </article>
      ) : null}

      <article className="admin-panel">
        <SectionHeader
          title="Safe metadata summary"
          description="Only approved summary fields are shown. Metadata raw, secret, payload, fingerprint, and idempotency fields are omitted."
        />
        <dl className="detail-list">
          {summary.metadataSummary.length > 0 ? (
            summary.metadataSummary.map((item) => (
              <div key={item.label}>
                <dt>{item.label}</dt>
                <dd>{item.value}</dd>
              </div>
            ))
          ) : (
            <div>
              <dt>metadata</dt>
              <dd>No safe summary fields.</dd>
            </div>
          )}
        </dl>
      </article>
    </section>
  );
}

function toListFilters(filters: FilterState): AuditLogListFilters {
  const limit = Number.parseInt(filters.limit, 10);

  return {
    action: filters.action.trim() || undefined,
    actor_user_id: filters.actor.trim() || undefined,
    created_from: filters.createdFrom.trim() || undefined,
    created_to: filters.createdTo.trim() || undefined,
    limit: Number.isFinite(limit) ? limit : undefined,
    resource_id: filters.resourceId.trim() || undefined,
    resource_type: filters.entity.trim() || undefined,
  };
}

function auditFocusFilters(target: AuditLogsFocusTarget): FilterState {
  const resourceType = target.resourceType?.trim();
  const resourceId = target.resourceId?.trim() || target.requestId?.trim();

  return {
    ...defaultFilters,
    entity: resourceType ?? "",
    limit: target.auditLogId?.trim() ? "100" : defaultFilters.limit,
    resourceId: resourceId ?? "",
  };
}

function summarizeAuditLog(log: AuditLog): AuditSummary {
  const metadata = sanitizeMetadataRecord(log.metadata);
  const before = sanitizeMetadataRecord(log.before_snapshot ?? null);
  const after = sanitizeMetadataRecord(log.after_snapshot ?? null);
  const status = firstReadableValue([
    metadata.action_result,
    metadata.status,
    metadata.to_status,
    after.status,
    metadata.status_changed === true ? "changed" : null,
  ]);

  return {
    action: safeFieldValue(log.action),
    actor: safeShortId(log.actor_user_id),
    auditId: safeShortId(log.id),
    entity: formatEntity(log),
    metadataSummary: safeMetadataSummary(metadata, before, after),
    reason: readableReason(metadata),
    requestId: safeShortId(log.request_id),
    status: status === "-" ? "recorded" : status,
    time: formatShortDate(log.created_at),
  };
}

function auditNavigationTarget(log: AuditLog): AuditNavigationTarget {
  const metadata = sanitizeMetadataRecord(log.metadata);
  const after = sanitizeMetadataRecord(log.after_snapshot ?? null);
  const resourceType = normalizeEntityType(log.resource_type);
  const resourceId = safeTargetId(log.resource_id);
  const status = firstTargetValue([metadata.status, metadata.to_status, after.status]);
  const reason = firstTargetValue([metadata.reason, metadata.safety_reason, metadata.action_result]);

  if (resourceType === "request") {
    const requestId = firstTargetValue([log.request_id, resourceId, metadata.request_id]);
    if (!requestId) {
      return missingNavigationTarget("Request detail unavailable", "Audit log has no safe request id.");
    }
    return { kind: "request", label: `Request ${safeShortId(requestId)}`, requestId };
  }

  if (resourceType === "virtual_key") {
    const keyId = firstTargetValue([resourceId, metadata.virtual_key_id, metadata.key_id]);
    const projectId = firstTargetValue([metadata.project_id, after.project_id]);
    const keyPrefix = firstTargetValue([metadata.key_prefix, after.key_prefix]);

    if (!keyId && !projectId && !status) {
      return missingNavigationTarget("API key target unavailable", "Audit log has no safe key id, project id, or status.");
    }

    return {
      kind: "api_key",
      label: keyPrefix ? `API key ${keyPrefix}` : keyId ? `API key ${safeShortId(keyId)}` : "Filter API keys",
      target: {
        keyId,
        keyPrefix,
        projectId,
        status,
      },
    };
  }

  if (resourceType === "project") {
    const projectId = firstTargetValue([resourceId, metadata.project_id, after.project_id]);

    if (!projectId && !status) {
      return missingNavigationTarget("Users filter unavailable", "Audit log has no safe project id or status.");
    }

    return {
      kind: "user",
      label: projectId ? `Project ${safeShortId(projectId)}` : "Filter users",
      target: {
        projectId,
        status,
      },
    };
  }

  if (resourceType === "user") {
    const userId = firstTargetValue([resourceId, metadata.user_id]);
    const projectId = firstTargetValue([metadata.project_id, after.primary_project_id, after.project_id]);

    if (!userId && !projectId && !status) {
      return missingNavigationTarget("User target unavailable", "Audit log has no safe user id, project id, or status.");
    }

    return {
      kind: "user",
      label: userId ? `User ${safeShortId(userId)}` : projectId ? `Project ${safeShortId(projectId)}` : "Filter users",
      target: {
        projectId,
        status,
        userId,
      },
    };
  }

  return missingNavigationTarget("No safe jump", reason ? `Unsupported entity for jump. Reason: ${reason}` : "Unsupported entity for jump.");
}

function normalizeEntityType(value: string | null | undefined): string {
  const normalized = safeFieldValue(value).toLowerCase().replaceAll("-", "_");

  if (["api_key", "key", "virtual_key", "virtualkey"].includes(normalized)) {
    return "virtual_key";
  }

  if (["request", "request_log", "requestlog"].includes(normalized)) {
    return "request";
  }

  if (["project", "tenant"].includes(normalized)) {
    return "project";
  }

  if (["user", "admin_user"].includes(normalized)) {
    return "user";
  }

  return normalized;
}

function firstTargetValue(values: Array<JsonValue | string | undefined | null>): string | undefined {
  for (const value of values) {
    const target = safeTargetId(value);
    if (target) {
      return target;
    }
  }

  return undefined;
}

function safeTargetId(value: JsonValue | string | undefined | null): string | undefined {
  if (typeof value !== "string") {
    return undefined;
  }

  const safe = safeFieldValue(value).trim();
  if (!safe || safe === "-" || safe.includes("[redacted]")) {
    return undefined;
  }

  return safe;
}

function missingNavigationTarget(label: string, reason: string): AuditNavigationTarget {
  return { kind: "placeholder", label, reason };
}

function readableReason(metadata: Record<string, JsonValue>): string {
  const reason = firstReadableValue([
    metadata.reason,
    metadata.safety_reason,
    metadata.refusal_reason,
    metadata.error_code,
    metadata.action_result,
  ]);

  if (reason !== "-") {
    return reason;
  }

  if (metadata.reason_provided === true) {
    return "reason provided";
  }

  return "not provided";
}

function safeMetadataSummary(
  metadata: Record<string, JsonValue>,
  before: Record<string, JsonValue>,
  after: Record<string, JsonValue>,
): SummaryPair[] {
  const pairs: SummaryPair[] = [];

  for (const key of metadataSummaryKeys) {
    const value = firstReadableValue([metadata[key]]);
    if (value !== "-") {
      pairs.push({ label: key, value });
    }
  }

  const beforeStatus = firstReadableValue([before.status]);
  const afterStatus = firstReadableValue([after.status]);
  if (beforeStatus !== "-" || afterStatus !== "-") {
    pairs.push({ label: "status_change", value: `${beforeStatus} -> ${afterStatus}` });
  }

  const omittedCount = countOmittedMetadataFields(metadata);
  if (omittedCount > 0) {
    pairs.push({ label: "hidden_metadata_fields", value: String(omittedCount) });
  }

  return pairs;
}

function sanitizeMetadataRecord(value: JsonValue | null | undefined): Record<string, JsonValue> {
  const safe = sanitizeDisplayJson(value ?? null);
  return isJsonRecord(safe) ? safe : {};
}

function firstReadableValue(values: Array<JsonValue | undefined | null>): string {
  for (const value of values) {
    const formatted = formatSummaryValue(value);
    if (formatted !== "-") {
      return formatted;
    }
  }

  return "-";
}

function formatSummaryValue(value: JsonValue | undefined | null): string {
  if (value === null || value === undefined || value === "") {
    return "-";
  }

  if (typeof value === "boolean") {
    return String(value);
  }

  if (typeof value === "number") {
    return String(value);
  }

  if (typeof value === "string") {
    return safeFieldValue(value);
  }

  if (Array.isArray(value)) {
    const visible = value.slice(0, 3).map((item) => formatSummaryValue(item)).filter((item) => item !== "-");
    return visible.length > 0 ? visible.join(", ") : `${value.length} items`;
  }

  const keys = Object.keys(value);
  return keys.length > 0 ? `${keys.length} fields` : "-";
}

function countOmittedMetadataFields(metadata: Record<string, JsonValue>): number {
  const visibleKeys = new Set(metadataSummaryKeys);
  return Object.keys(metadata).filter((key) => !visibleKeys.has(key)).length;
}

function formatEntity(log: AuditLog): string {
  const type = safeFieldValue(log.resource_type);
  const id = safeShortId(log.resource_id);
  return id === "-" ? type : `${type} / ${id}`;
}

function safeShortId(value: string | null | undefined): string {
  const safeValue = safeFieldValue(value);

  if (safeValue === "-" || safeValue.includes("[redacted]")) {
    return safeValue;
  }

  return shortId(safeValue);
}

function formatShortDate(value: string): string {
  const date = new Date(value);

  if (Number.isNaN(date.getTime())) {
    return safeFieldValue(value);
  }

  return date.toLocaleString([], {
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    month: "short",
  });
}

function formatFullDate(value: string): string {
  const date = new Date(value);

  if (Number.isNaN(date.getTime())) {
    return safeFieldValue(value);
  }

  return date.toLocaleString();
}

function statusTone(status: string): "danger" | "good" | "neutral" | "warn" {
  const normalized = status.toLowerCase();

  if (["changed", "created", "disabled", "paid", "recorded", "restored", "succeeded", "success"].includes(normalized)) {
    return "good";
  }

  if (["failed", "refused", "rejected", "restore_refused_deleted", "restore_refused_expired", "restore_refused_unsupported_status", "revoked_disabled", "not_found"].includes(normalized)) {
    return "danger";
  }

  if (["pending", "pending_payment", "planned", "suspected_leaked_marked", "unchanged_active"].includes(normalized)) {
    return "warn";
  }

  return "neutral";
}
