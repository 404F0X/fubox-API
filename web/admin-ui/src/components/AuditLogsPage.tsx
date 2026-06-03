import { FormEvent, useEffect, useRef, useState } from "react";
import {
  type AuditLog,
  type AuditLogListFilters,
  type JsonValue,
  listAuditLogs,
} from "../api/client";
import { errorMessage, isJsonRecord, jsonSize, safeFieldValue, sanitizeDisplayJson, shortId } from "./adminUtils";
import { Eye, RefreshCw, Search } from "./icons";

type FilterState = {
  action: string;
  actor: string;
  limit: string;
  resource: string;
};

const defaultFilters: FilterState = {
  action: "",
  actor: "",
  limit: "25",
  resource: "",
};

export function AuditLogsPage() {
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

  const selectedLog = auditLogs.find((log) => log.id === selectedId) ?? null;

  return (
    <div className="admin-page" aria-label="Audit logs">
      <section className="admin-panel" aria-label="Audit log filters">
        <div className="section-heading">
          <div>
            <h2>Audit Logs</h2>
            <p>Tenant-scoped admin changes with secret-safe snapshots and metadata.</p>
          </div>
          <button className="secondary-button" type="button" onClick={() => void loadLogs()} disabled={loading}>
            <RefreshCw aria-hidden="true" size={18} className={loading ? "spin" : undefined} />
            Refresh
          </button>
        </div>

        <form className="filter-bar" onSubmit={handleSubmit}>
          <label className="field">
            Action
            <input
              value={filters.action}
              onChange={(event) => {
                const value = event.currentTarget.value;
                setFilters((current) => ({ ...current, action: value }));
              }}
              placeholder="provider_key.update"
            />
          </label>

          <label className="field">
            Resource
            <input
              value={filters.resource}
              onChange={(event) => {
                const value = event.currentTarget.value;
                setFilters((current) => ({ ...current, resource: value }));
              }}
              placeholder="provider_key"
            />
          </label>

          <label className="field">
            Actor ID
            <input
              value={filters.actor}
              onChange={(event) => {
                const value = event.currentTarget.value;
                setFilters((current) => ({ ...current, actor: value }));
              }}
              placeholder="actor user id"
            />
          </label>

          <label className="field field--compact">
            Limit
            <input
              min="1"
              type="number"
              value={filters.limit}
              onChange={(event) => {
                const value = event.currentTarget.value;
                setFilters((current) => ({ ...current, limit: value }));
              }}
            />
          </label>

          <button className="primary-button primary-button--inline" type="submit">
            <Search aria-hidden="true" size={17} />
            Search
          </button>
        </form>

        {error ? <p className="form-status form-status--error">{error}</p> : null}
      </section>

      <section aria-label="Audit log list">
        <div className="health-table-wrap">
          <table className="health-table admin-table admin-table--audit-logs">
            <thead>
              <tr>
                <th>Audit</th>
                <th>Action</th>
                <th>Resource</th>
                <th>Actor</th>
                <th>Request</th>
                <th>Snapshots</th>
                <th>Detail</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr>
                  <td colSpan={7}>Loading audit logs.</td>
                </tr>
              ) : auditLogs.length > 0 ? (
                auditLogs.map((log) => (
                  <tr key={log.id} className={selectedId === log.id ? "table-row--selected" : undefined}>
                    <td>
                      <strong>{safeShortId(log.id)}</strong>
                      <span>{formatDate(log.created_at)}</span>
                    </td>
                    <td>
                      <strong>{safeFieldValue(log.action)}</strong>
                      <span>{safeFieldValue(log.tenant_id)}</span>
                    </td>
                    <td>
                      <strong>{safeFieldValue(log.resource_type)}</strong>
                      <span>{safeShortId(log.resource_id)}</span>
                    </td>
                    <td>
                      <strong>{safeShortId(log.actor_user_id)}</strong>
                      <span>{safeShortId(log.resource_tenant_id)}</span>
                    </td>
                    <td>{safeShortId(log.request_id)}</td>
                    <td>
                      <strong>Before {snapshotSize(log.before_snapshot)}</strong>
                      <span>After {snapshotSize(log.after_snapshot)}</span>
                    </td>
                    <td>
                      <button
                        className="table-action"
                        type="button"
                        onClick={() => setSelectedId(log.id)}
                        aria-label={`View audit log ${safeFieldValue(log.id)}`}
                      >
                        <Eye aria-hidden="true" size={15} />
                        View
                      </button>
                    </td>
                  </tr>
                ))
              ) : (
                <tr>
                  <td colSpan={7}>No audit logs matched the current filters.</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </section>

      <AuditLogDetailPanel auditLog={selectedLog} />
    </div>
  );
}

export default AuditLogsPage;

function AuditLogDetailPanel({ auditLog }: { auditLog: AuditLog | null }) {
  if (!auditLog) {
    return null;
  }

  return (
    <section className="detail-grid" aria-label="Audit log detail">
      <article className="admin-panel">
        <div className="section-heading">
          <div>
            <h2>Audit Detail</h2>
            <p>{safeFieldValue(auditLog.id)}</p>
          </div>
        </div>

        <dl className="detail-list">
          <div>
            <dt>Action</dt>
            <dd>{safeFieldValue(auditLog.action)}</dd>
          </div>
          <div>
            <dt>Resource</dt>
            <dd>{formatResource(auditLog)}</dd>
          </div>
          <div>
            <dt>Actor</dt>
            <dd>{safeShortId(auditLog.actor_user_id)}</dd>
          </div>
          <div>
            <dt>Request</dt>
            <dd>{safeShortId(auditLog.request_id)}</dd>
          </div>
          <div>
            <dt>Tenant</dt>
            <dd>{safeShortId(auditLog.tenant_id)}</dd>
          </div>
          <div>
            <dt>Created</dt>
            <dd>{formatDate(auditLog.created_at)}</dd>
          </div>
        </dl>
      </article>

      <JsonSummaryPanel title="Metadata" value={auditLog.metadata} />
      <JsonSummaryPanel title="Before Snapshot" value={auditLog.before_snapshot ?? null} />
      <JsonSummaryPanel title="After Snapshot" value={auditLog.after_snapshot ?? null} />
    </section>
  );
}

function JsonSummaryPanel({ title, value }: { title: string; value: JsonValue | null | undefined }) {
  return (
    <article className="admin-panel">
      <div className="section-heading">
        <div>
          <h2>{title}</h2>
          <p>{snapshotSize(value)}</p>
        </div>
      </div>
      <pre className="json-block">{formatJsonSummary(value)}</pre>
    </article>
  );
}

function toListFilters(filters: FilterState): AuditLogListFilters {
  const limit = Number.parseInt(filters.limit, 10);

  return {
    action: filters.action.trim() || undefined,
    actor_user_id: filters.actor.trim() || undefined,
    limit: Number.isFinite(limit) ? limit : undefined,
    resource_type: filters.resource.trim() || undefined,
  };
}

function formatJsonSummary(value: JsonValue | null | undefined): string {
  return JSON.stringify(summarizeJsonValue(sanitizeDisplayJson(value ?? null)), null, 2);
}

function summarizeJsonValue(value: JsonValue, depth = 0): JsonValue {
  if (Array.isArray(value)) {
    const visible = value.slice(0, 8).map((item) => summarizeJsonValue(item, depth + 1));
    const remaining = value.length - visible.length;

    return remaining > 0 ? [...visible, `${remaining} more items`] : visible;
  }

  if (!isJsonRecord(value)) {
    return typeof value === "string" ? safeFieldValue(value) : value;
  }

  const entries = Object.entries(value);

  if (depth >= 3) {
    return {
      summary: "object",
      fields: entries.length,
    };
  }

  const visibleEntries = entries
    .slice(0, 14)
    .map(([key, child]) => [safeFieldValue(key), summarizeJsonValue(child, depth + 1)] as const);
  const remaining = entries.length - visibleEntries.length;
  const summary = Object.fromEntries(visibleEntries) as Record<string, JsonValue>;

  if (remaining > 0) {
    summary.more_fields = `${remaining} more fields`;
  }

  return summary;
}

function snapshotSize(value: JsonValue | null | undefined): string {
  if (value === null || value === undefined) {
    return "0 fields";
  }

  const size = jsonSize(sanitizeDisplayJson(value));

  return `${size} ${size === "1" ? "field" : "fields"}`;
}

function formatResource(auditLog: AuditLog): string {
  const resource = safeFieldValue(auditLog.resource_type);
  const resourceId = safeShortId(auditLog.resource_id);

  return resourceId === "-" ? resource : `${resource} / ${resourceId}`;
}

function safeShortId(value: string | null | undefined): string {
  const safeValue = safeFieldValue(value);

  if (safeValue === "-" || safeValue.includes("[redacted]")) {
    return safeValue;
  }

  return shortId(safeValue);
}

function formatDate(value: string): string {
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
