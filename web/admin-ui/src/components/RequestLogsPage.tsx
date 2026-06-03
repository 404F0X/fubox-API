import { FormEvent, useEffect, useRef, useState } from "react";
import {
  getRequestLogDetail,
  getRequestTraceSummary,
  type JsonValue,
  listRequestLogs,
  type RequestLogDetail,
  type RequestLogListFilters,
  type RequestLogSummary,
  type RequestLedgerSummary,
  type RequestTraceSummary,
} from "../api/client";
import { StateChip, errorMessage, isJsonRecord, safeFieldValue, shortId } from "./adminUtils";
import { Eye, RefreshCw, Search } from "./icons";

type FilterState = {
  channelId: string;
  limit: string;
  model: string;
  status: string;
  traceId: string;
};

const defaultFilters: FilterState = {
  channelId: "",
  limit: "25",
  model: "",
  status: "",
  traceId: "",
};

const requestLogStatuses = ["", "started", "succeeded", "failed", "rejected", "partial", "cancelled"];

export function RequestLogsPage() {
  const [detail, setDetail] = useState<RequestLogDetail | null>(null);
  const [detailLoading, setDetailLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [filters, setFilters] = useState<FilterState>(defaultFilters);
  const [loading, setLoading] = useState(true);
  const [logs, setLogs] = useState<RequestLogSummary[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [traceSummary, setTraceSummary] = useState<RequestTraceSummary | null>(null);
  const detailRequestSeq = useRef(0);
  const logsRequestSeq = useRef(0);

  async function loadLogs(nextFilters = filters) {
    const requestSeq = logsRequestSeq.current + 1;
    logsRequestSeq.current = requestSeq;
    setError(null);
    setLoading(true);
    setTraceSummary(null);

    try {
      const nextLogs = await listRequestLogs(toListFilters(nextFilters));
      if (logsRequestSeq.current === requestSeq) {
        setLogs(nextLogs);
      }
    } catch (requestError) {
      if (logsRequestSeq.current === requestSeq) {
        setError(errorMessage(requestError));
        setLogs([]);
      }
    } finally {
      if (logsRequestSeq.current === requestSeq) {
        setLoading(false);
      }
    }
  }

  async function loadTrace(nextFilters = filters) {
    const traceId = nextFilters.traceId.trim();

    if (!traceId) {
      await loadLogs(nextFilters);
      return;
    }

    const requestSeq = logsRequestSeq.current + 1;
    logsRequestSeq.current = requestSeq;
    setError(null);
    setLoading(true);
    setTraceSummary(null);

    try {
      const summary = await getRequestTraceSummary(traceId, toTraceFilters(nextFilters));
      if (logsRequestSeq.current === requestSeq) {
        setTraceSummary(summary);
        setLogs(summary.requests);
      }
    } catch (requestError) {
      if (logsRequestSeq.current === requestSeq) {
        setError(errorMessage(requestError));
        setLogs([]);
      }
    } finally {
      if (logsRequestSeq.current === requestSeq) {
        setLoading(false);
      }
    }
  }

  async function loadDetail(id: string) {
    const requestSeq = detailRequestSeq.current + 1;
    detailRequestSeq.current = requestSeq;
    setSelectedId(id);
    setDetail(null);
    setDetailLoading(true);
    setError(null);

    try {
      const nextDetail = await getRequestLogDetail(id);
      if (detailRequestSeq.current === requestSeq) {
        setDetail(nextDetail);
      }
    } catch (requestError) {
      if (detailRequestSeq.current === requestSeq) {
        setError(errorMessage(requestError));
      }
    } finally {
      if (detailRequestSeq.current === requestSeq) {
        setDetailLoading(false);
      }
    }
  }

  function handleFilterSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    void loadCurrent(filters);
  }

  function loadCurrent(nextFilters = filters) {
    return nextFilters.traceId.trim() ? loadTrace(nextFilters) : loadLogs(nextFilters);
  }

  useEffect(() => {
    void loadLogs(defaultFilters);
  }, []);

  return (
    <div className="admin-page" aria-label="Request logs">
      <section className="admin-panel" aria-label="Request log filters">
        <div className="section-heading">
          <div>
            <h2>Request Logs</h2>
            <p>Gateway request routing, status, cost, and timing without payload material.</p>
          </div>
          <button className="secondary-button" type="button" onClick={() => void loadCurrent()} disabled={loading}>
            <RefreshCw aria-hidden="true" size={18} className={loading ? "spin" : undefined} />
            Refresh
          </button>
        </div>

        <form className="filter-bar" onSubmit={handleFilterSubmit}>
          <label className="field">
            Status
            <select
              value={filters.status}
              onChange={(event) => {
                const value = event.currentTarget.value;
                setFilters((current) => ({ ...current, status: value }));
              }}
            >
              {requestLogStatuses.map((status) => (
                <option key={status || "all"} value={status}>
                  {status || "All"}
                </option>
              ))}
            </select>
          </label>

          <label className="field">
            Trace ID
            <input
              value={filters.traceId}
              onChange={(event) => {
                const value = event.currentTarget.value;
                setFilters((current) => ({ ...current, traceId: value }));
              }}
              placeholder="trace id"
            />
          </label>

          <label className="field">
            Model
            <input
              value={filters.model}
              onChange={(event) => {
                const value = event.currentTarget.value;
                setFilters((current) => ({ ...current, model: value }));
              }}
              placeholder="requested model"
            />
          </label>

          <label className="field">
            Channel ID
            <input
              value={filters.channelId}
              onChange={(event) => {
                const value = event.currentTarget.value;
                setFilters((current) => ({ ...current, channelId: value }));
              }}
              placeholder="resolved channel"
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

      {traceSummary ? <TraceSummaryPanel summary={traceSummary} /> : null}

      <section aria-label="Request log list">
        <div className="health-table-wrap">
          <table className="health-table admin-table">
            <thead>
              <tr>
                <th>Request</th>
                <th>Status</th>
                <th>Model</th>
                <th>Channel</th>
                <th>Cost</th>
                <th>Timing</th>
                <th>Detail</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr>
                  <td colSpan={7}>Loading request logs.</td>
                </tr>
              ) : logs.length > 0 ? (
                logs.map((log) => (
                  <tr key={log.id} className={selectedId === log.id ? "table-row--selected" : undefined}>
                    <td>
                      <strong>{safeShortId(log.id)}</strong>
                      <span>{formatDate(log.created_at)}</span>
                      {log.trace_id ? <span>Trace {safeShortId(log.trace_id)}</span> : null}
                    </td>
                    <td>
                      <StateChip status={safeStatus(log.status)} />
                      {log.http_status ? <span>HTTP {log.http_status}</span> : null}
                    </td>
                    <td>
                      <strong>{safeFieldValue(log.requested_model)}</strong>
                      <span>{safeFieldValue(log.upstream_model)}</span>
                    </td>
                    <td>
                      <strong>{safeShortId(log.resolved_channel_id)}</strong>
                      <span>{safeFieldValue(log.route_policy_version)}</span>
                    </td>
                    <td>
                      {safeFieldValue(log.final_cost)} {safeFieldValue(log.currency)}
                    </td>
                    <td>
                      <strong>{formatMs(log.latency_ms)}</strong>
                      <span>TTFT {formatMs(log.ttft_ms)}</span>
                    </td>
                    <td>
                      <button
                        className="table-action"
                        type="button"
                        onClick={() => void loadDetail(log.id)}
                        aria-label={`View request log ${safeFieldValue(log.id)}`}
                      >
                        <Eye aria-hidden="true" size={15} />
                        View
                      </button>
                    </td>
                  </tr>
                ))
              ) : (
                <tr>
                  <td colSpan={7}>No request logs matched the current filters.</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </section>

      <RequestLogDetailPanel detail={detail} loading={detailLoading} selectedId={selectedId} />
    </div>
  );
}

function RequestLogDetailPanel({
  detail,
  loading,
  selectedId,
}: {
  detail: RequestLogDetail | null;
  loading: boolean;
  selectedId: string | null;
}) {
  if (!selectedId) {
    return null;
  }

  if (loading) {
    return (
      <section className="admin-panel" aria-label="Request log detail">
        <h2>Request Detail</h2>
        <p className="muted-copy">Loading {safeShortId(selectedId)}.</p>
      </section>
    );
  }

  if (!detail) {
    return null;
  }

  const log = detail.request_log;
  const ledger = normalizeLedgerSummary(detail.ledger);

  return (
    <section className="detail-grid" aria-label="Request log detail">
      <article className="admin-panel">
        <div className="section-heading">
          <div>
            <h2>Request Detail</h2>
            <p>{safeFieldValue(log.id)}</p>
          </div>
          <StateChip status={safeStatus(log.status)} />
        </div>

        <dl className="detail-list">
          <div>
            <dt>HTTP</dt>
            <dd>{safeFieldValue(log.http_status)}</dd>
          </div>
          <div>
            <dt>Retryable</dt>
            <dd>{formatBoolean(log.retryable)}</dd>
          </div>
          <div>
            <dt>Requested model</dt>
            <dd>{safeFieldValue(log.requested_model)}</dd>
          </div>
          <div>
            <dt>Upstream model</dt>
            <dd>{safeFieldValue(log.upstream_model)}</dd>
          </div>
          <div>
            <dt>Provider key</dt>
            <dd>{safeShortId(log.provider_key_id)}</dd>
          </div>
          <div>
            <dt>Channel</dt>
            <dd>{safeShortId(log.resolved_channel_id)}</dd>
          </div>
          <div>
            <dt>Tokens</dt>
            <dd>
              {log.input_tokens} in / {log.output_tokens} out
            </dd>
          </div>
          <div>
            <dt>Latency</dt>
            <dd>{formatMs(log.latency_ms)}</dd>
          </div>
          <div>
            <dt>Error</dt>
            <dd>{formatErrorParts(log.error_owner, log.error_code)}</dd>
          </div>
          <div>
            <dt>Redaction</dt>
            <dd>{safeFieldValue(log.redaction_status)}</dd>
          </div>
        </dl>
      </article>

      <RouteTracePanel detail={detail} />

      <LedgerSummaryPanel
        emptyMessage="No ledger entries were linked to this request."
        summary={ledger}
        title="Ledger Entries"
      />

      <article className="admin-panel detail-panel--wide">
        <div className="section-heading">
          <div>
            <h2>Provider Attempts</h2>
            <p>{detail.provider_attempts.length} recorded attempts.</p>
          </div>
        </div>

        <div className="health-table-wrap">
          <table className="health-table admin-table admin-table--attempts">
            <thead>
              <tr>
                <th>No.</th>
                <th>Status</th>
                <th>Provider</th>
                <th>Channel</th>
                <th>Model</th>
                <th>Timing</th>
                <th>Error</th>
              </tr>
            </thead>
            <tbody>
              {detail.provider_attempts.length > 0 ? (
                detail.provider_attempts.map((attempt) => (
                  <tr key={attempt.id}>
                    <td>{attempt.attempt_no}</td>
                    <td>
                      <StateChip status={safeStatus(attempt.status)} />
                      {attempt.http_status ? <span>HTTP {attempt.http_status}</span> : null}
                    </td>
                    <td>{safeShortId(attempt.provider_id)}</td>
                    <td>{safeShortId(attempt.channel_id)}</td>
                    <td>{safeFieldValue(attempt.upstream_model)}</td>
                    <td>
                      <strong>{formatMs(attempt.latency_ms)}</strong>
                      <span>TTFT {formatMs(attempt.ttft_ms)}</span>
                    </td>
                    <td>{formatErrorParts(attempt.error_owner, attempt.error_code, attempt.fallback_reason)}</td>
                  </tr>
                ))
              ) : (
                <tr>
                  <td colSpan={7}>No provider attempts were recorded for this request.</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </article>
    </section>
  );
}

function RouteTracePanel({ detail }: { detail: RequestLogDetail }) {
  const summary = summarizeRouteDecisionSnapshot(detail.route_decision_snapshot);

  return (
    <article className="admin-panel">
      <div className="section-heading">
        <div>
          <h2>Route Trace</h2>
          <p>{safeFieldValue(detail.request_log.route_policy_version)}</p>
        </div>
      </div>

      <dl className="detail-list">
        <div>
          <dt>Strategy</dt>
          <dd>{summary.strategy}</dd>
        </div>
        <div>
          <dt>Selected channel</dt>
          <dd>{safeShortId(summary.selectedChannelId)}</dd>
        </div>
        <div>
          <dt>Candidates</dt>
          <dd>{summary.candidateCount}</dd>
        </div>
        <div>
          <dt>Filtered</dt>
          <dd>{summary.filteredCount}</dd>
        </div>
        <div>
          <dt>Snapshot version</dt>
          <dd>{summary.version}</dd>
        </div>
      </dl>
    </article>
  );
}

function summarizeRouteDecisionSnapshot(snapshot: JsonValue) {
  if (!isJsonRecord(snapshot)) {
    return {
      candidateCount: 0,
      filteredCount: 0,
      selectedChannelId: null,
      strategy: "-",
      version: "-",
    };
  }

  const candidates = Array.isArray(snapshot.candidates) ? snapshot.candidates : [];
  const filteredCount = candidates.filter(
    (candidate) =>
      isJsonRecord(candidate) &&
      candidate.filter_reason !== null &&
      candidate.filter_reason !== undefined &&
      candidate.filter_reason !== "",
  ).length;

  return {
    candidateCount: candidates.length,
    filteredCount,
    selectedChannelId: routeSnapshotSelectedChannelId(snapshot),
    strategy: safeFieldValue(snapshot.strategy),
    version: safeFieldValue(snapshot.version),
  };
}

function routeSnapshotSelectedChannelId(snapshot: Record<string, JsonValue>): string | null {
  if (typeof snapshot.selected_channel_id === "string") {
    return snapshot.selected_channel_id;
  }

  const selected = snapshot.selected ?? null;
  if (isJsonRecord(selected) && typeof selected.channel_id === "string") {
    return selected.channel_id;
  }

  const candidates = Array.isArray(snapshot.candidates) ? snapshot.candidates : [];
  const selectedCandidate = candidates.find(
    (candidate) => isJsonRecord(candidate) && candidate.selected === true,
  );

  const selectedCandidateValue = selectedCandidate ?? null;
  if (isJsonRecord(selectedCandidateValue) && typeof selectedCandidateValue.channel_id === "string") {
    return selectedCandidateValue.channel_id;
  }

  return null;
}

function toListFilters(filters: FilterState): RequestLogListFilters {
  const limit = Number.parseInt(filters.limit, 10);

  return {
    channel_id: filters.channelId.trim() || undefined,
    limit: Number.isFinite(limit) ? limit : undefined,
    model: filters.model.trim() || undefined,
    status: filters.status || undefined,
  };
}

function formatBoolean(value: boolean | null | undefined): string {
  if (value === null || value === undefined) {
    return "-";
  }

  return value ? "Yes" : "No";
}

function TraceSummaryPanel({ summary }: { summary: RequestTraceSummary }) {
  const ledger = normalizeLedgerSummary(summary.ledger);

  return (
    <>
      <section className="feature-stats" aria-label="Trace summary metrics">
        <MetricCard label="Request Count" tone="neutral" value={summary.request_count} />
        <MetricCard label="Errors" tone={summary.error_count > 0 ? "warn" : "good"} value={summary.error_count} />
        <MetricCard label="Input Tokens" tone="neutral" value={summary.total_input_tokens} />
        <MetricCard label="Output Tokens" tone="neutral" value={summary.total_output_tokens} />
      </section>

      <section className="admin-panel" aria-label="Trace summary">
        <div className="section-heading">
          <div>
            <h2>Trace Summary</h2>
            <p>{safeFieldValue(summary.trace_id)}</p>
          </div>
        </div>

        <dl className="detail-list">
          <div>
            <dt>Rows</dt>
            <dd>
              {summary.requests.length} returned
              {summary.limit_reached ? ` / limit ${summary.limit}` : ""}
            </dd>
          </div>
          <div>
            <dt>Currencies</dt>
            <dd>{formatList(summary.currencies)}</dd>
          </div>
          <div>
            <dt>First request</dt>
            <dd>{formatDateField(summary.first_request_at)}</dd>
          </div>
          <div>
            <dt>Last request</dt>
            <dd>{formatDateField(summary.last_request_at)}</dd>
          </div>
          <div>
            <dt>Last error</dt>
            <dd>{formatLastError(summary.last_error)}</dd>
          </div>
          <div>
            <dt>Ledger rows</dt>
            <dd>
              {ledger.returned_count} returned
              {ledger.limit_reached ? ` / limit ${ledger.limit}` : ""}
            </dd>
          </div>
          <div>
            <dt>Ledger currencies</dt>
            <dd>{formatList(ledger.currencies)}</dd>
          </div>
        </dl>

        <LedgerRowsTable emptyMessage="No ledger entries were linked to the returned trace rows." summary={ledger} />
      </section>
    </>
  );
}

function LedgerSummaryPanel({
  emptyMessage,
  summary,
  title,
}: {
  emptyMessage: string;
  summary: RequestLogDetail["ledger"];
  title: string;
}) {
  return (
    <article className="admin-panel detail-panel--wide">
      <div className="section-heading">
        <div>
          <h2>{title}</h2>
          <p>
            {summary.returned_count} returned across {summary.request_count} request
            {summary.request_count === 1 ? "" : "s"}.
          </p>
        </div>
      </div>
      <LedgerRowsTable emptyMessage={emptyMessage} summary={summary} />
    </article>
  );
}

function normalizeLedgerSummary(summary: RequestLedgerSummary | null | undefined): RequestLedgerSummary {
  if (!summary || !Array.isArray(summary.entries)) {
    return {
      currencies: [],
      entries: [],
      limit: 0,
      limit_reached: false,
      omitted_fields: ["idempotency_key", "usage_snapshot", "policy_snapshot", "metadata"],
      request_count: 0,
      returned_count: 0,
    };
  }

  return {
    currencies: Array.isArray(summary.currencies) ? summary.currencies : [],
    entries: summary.entries,
    limit: typeof summary.limit === "number" ? summary.limit : summary.entries.length,
    limit_reached: Boolean(summary.limit_reached),
    omitted_fields: Array.isArray(summary.omitted_fields) ? summary.omitted_fields : [],
    request_count: typeof summary.request_count === "number" ? summary.request_count : 0,
    returned_count: typeof summary.returned_count === "number" ? summary.returned_count : summary.entries.length,
  };
}

function LedgerRowsTable({
  emptyMessage,
  summary,
}: {
  emptyMessage: string;
  summary: RequestLogDetail["ledger"];
}) {
  return (
    <div className="health-table-wrap">
      <table className="health-table admin-table admin-table--ledger">
        <thead>
          <tr>
            <th>Type</th>
            <th>Status</th>
            <th>Amount</th>
            <th>Request</th>
            <th>Occurred</th>
          </tr>
        </thead>
        <tbody>
          {summary.entries.length > 0 ? (
            summary.entries.map((entry, index) => (
              <tr key={`${entry.request_id ?? "request"}-${entry.entry_type}-${entry.occurred_at}-${index}`}>
                <td>{formatLedgerStatus(entry.entry_type)}</td>
                <td>
                  <StateChip status={safeStatus(entry.status)} />
                </td>
                <td>
                  {safeFieldValue(entry.amount)} {safeFieldValue(entry.currency)}
                </td>
                <td>{safeShortId(entry.request_id)}</td>
                <td>{formatDate(entry.occurred_at)}</td>
              </tr>
            ))
          ) : (
            <tr>
              <td colSpan={5}>{emptyMessage}</td>
            </tr>
          )}
        </tbody>
      </table>
    </div>
  );
}

function MetricCard({
  label,
  tone,
  value,
}: {
  label: string;
  tone: "good" | "neutral" | "warn";
  value: number | string;
}) {
  return (
    <article className={`metric-card metric-card--${tone}`}>
      <span>{label}</span>
      <strong>{value}</strong>
    </article>
  );
}

function toTraceFilters(filters: FilterState): { limit?: number } {
  const limit = Number.parseInt(filters.limit, 10);

  return {
    limit: Number.isFinite(limit) ? limit : undefined,
  };
}

function formatLastError(error: RequestTraceSummary["last_error"]): string {
  if (!error) {
    return "-";
  }

  return formatErrorParts(
    error.owner,
    error.code,
    error.status,
    typeof error.http_status === "number" ? `HTTP ${error.http_status}` : null,
    error.observed_at,
  );
}

function formatErrorParts(...parts: Array<unknown>): string {
  const safeParts = parts
    .map((part) => safeFieldValue(part))
    .filter((part) => part !== "-");

  return safeParts.length > 0 ? safeParts.join(" / ") : "-";
}

function formatList(values: string[]): string {
  const safeValues = values.map(safeFieldValue).filter((value) => value !== "-");

  return safeValues.length > 0 ? safeValues.join(", ") : "-";
}

function safeShortId(value: string | null | undefined): string {
  const safeValue = safeFieldValue(value);

  if (safeValue === "-" || safeValue.includes("[redacted]")) {
    return safeValue;
  }

  return shortId(safeValue);
}

function safeStatus(value: string): string {
  const safeValue = safeFieldValue(value);

  return safeValue === "-" ? "unknown" : safeValue;
}

function formatLedgerStatus(value: string): string {
  return safeFieldValue(value).replace(/_/g, " ");
}

function formatDateField(value: string | null | undefined): string {
  return value ? formatDate(value) : "-";
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

function formatMs(value: number | null | undefined): string {
  return typeof value === "number" ? `${value} ms` : "-";
}
