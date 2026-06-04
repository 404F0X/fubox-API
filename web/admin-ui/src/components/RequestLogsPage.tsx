import { FormEvent, useEffect, useRef, useState } from "react";
import {
  getRequestLogDetail,
  getRequestPayloadPreview,
  getRequestTraceSummary,
  type JsonValue,
  listRequestLogs,
  type RequestLogDetail,
  type RequestLogListFilters,
  type RequestPayloadPreview,
  type RequestLogSummary,
  type RequestLedgerSummary,
  type RequestTraceSummary,
} from "../api/client";
import {
  StateChip,
  errorMessage,
  isJsonRecord,
  jsonSize,
  safeFieldValue,
  sanitizeDisplayJson,
  shortId,
} from "./adminUtils";
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
            <dt>Credential</dt>
            <dd>{log.provider_key_id ? "configured" : "-"}</dd>
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

      <PayloadPreviewPanel key={log.id} log={log} />

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
        </div>
      </div>

      <dl className="detail-list">
        <div>
          <dt>Selected channel</dt>
          <dd>{safeShortId(summary.selectedChannelId)}</dd>
        </div>
        <div>
          <dt>Provider model</dt>
          <dd>{summary.selectedProviderModel}</dd>
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
          <dt>Filter reasons</dt>
          <dd>{summary.filterReasons}</dd>
        </div>
        <div>
          <dt>Selected score</dt>
          <dd>{summary.selectedScoreTotal}</dd>
        </div>
        <div>
          <dt>Trace affinity</dt>
          <dd>{summary.traceAffinityStatus}</dd>
        </div>
      </dl>
    </article>
  );
}

type PayloadPreviewStatus = "idle" | "loading" | "loaded" | "forbidden" | "not_implemented" | "unavailable" | "error";

function PayloadPreviewPanel({ log }: { log: RequestLogSummary }) {
  const [message, setMessage] = useState<string | null>(null);
  const [preview, setPreview] = useState<RequestPayloadPreview | null>(null);
  const [status, setStatus] = useState<PayloadPreviewStatus>("idle");
  const canLoadPayload = Boolean(log.payload_stored);
  const previewSections = status === "loaded" && preview ? safePayloadPreviewSections(preview) : [];

  async function loadPayloadPreview() {
    if (!canLoadPayload) {
      return;
    }

    setMessage(null);
    setPreview(null);
    setStatus("loading");

    try {
      const nextPreview = await getRequestPayloadPreview(log.id);
      setPreview(nextPreview);
      setStatus(nextPreview.available === false ? "unavailable" : "loaded");
    } catch (requestError) {
      setPreview(null);

      const statusCode = apiStatusCode(requestError);
      if (statusCode === 403) {
        setStatus("forbidden");
      } else if (statusCode === 404) {
        setStatus("not_implemented");
      } else {
        setMessage(errorMessage(requestError));
        setStatus("error");
      }
    }
  }

  return (
    <article className="admin-panel" aria-label="Payload preview">
      <div className="section-heading">
        <div>
          <h2>Payload Preview</h2>
          <p>{payloadPreviewHeadline(log, status)}</p>
        </div>
        <button
          aria-label={`Load payload preview for ${safeFieldValue(log.id)}`}
          className="secondary-button"
          disabled={!canLoadPayload || status === "loading"}
          onClick={() => void loadPayloadPreview()}
          type="button"
        >
          <Eye aria-hidden="true" size={16} />
          {status === "loading" ? "Loading" : preview ? "Reload preview" : "Load preview"}
        </button>
      </div>

      <dl className="detail-list">
        {payloadMetadataRows(log, preview).map(([label, value]) => (
          <div key={label}>
            <dt>{label}</dt>
            <dd>{value}</dd>
          </div>
        ))}
      </dl>

      {status !== "idle" && status !== "loading" ? (
        <p className={`form-status ${status === "loaded" ? "form-status--success" : "form-status--error"}`}>
          {payloadPreviewStatusMessage(status, message)}
        </p>
      ) : null}

      {status === "loaded" ? (
        previewSections.length > 0 ? (
          <div className="payload-preview-grid">
            {previewSections.map((section) => (
              <div className="payload-preview-card" key={section.title}>
                <h3>
                  {section.title} ({jsonSize(section.value)} fields)
                </h3>
                <pre className="json-preview">{formatJsonPreview(section.value)}</pre>
              </div>
            ))}
          </div>
        ) : (
          <p className="muted-copy">No redacted preview fields were returned. Hash metadata is shown above.</p>
        )
      ) : null}
    </article>
  );
}

function summarizeRouteDecisionSnapshot(snapshot: JsonValue) {
  const emptySummary = {
    candidateCount: "-",
    filterReasons: "-",
    filteredCount: "-",
    selectedChannelId: null,
    selectedProviderModel: "-",
    selectedScoreTotal: "-",
    traceAffinityStatus: "-",
  };

  if (!isJsonRecord(snapshot) || !isJsonRecord(snapshot.summary)) {
    return emptySummary;
  }

  const summary = snapshot.summary;

  return {
    candidateCount: safeNumberField(summary.candidate_count),
    filterReasons: formatFilterReasons(summary.filter_reasons),
    filteredCount: safeNumberField(summary.filtered_count),
    selectedChannelId: stringField(summary.selected_channel_id),
    selectedProviderModel: safeStringField(summary.selected_provider_model),
    selectedScoreTotal: safeNumberField(summary.selected_score_total),
    traceAffinityStatus: safeStringField(summary.trace_affinity_status),
  };
}

function stringField(value: JsonValue | undefined): string | null {
  return typeof value === "string" ? value : null;
}

function safeStringField(value: JsonValue | undefined): string {
  const stringValue = stringField(value);

  return stringValue ? safeFieldValue(stringValue) : "-";
}

function safeNumberField(value: JsonValue | undefined): string {
  if (typeof value === "number" && Number.isFinite(value)) {
    return safeFieldValue(value);
  }

  if (typeof value === "string") {
    return safeFieldValue(value);
  }

  return "-";
}

function formatFilterReasons(value: JsonValue | undefined): string {
  if (!Array.isArray(value)) {
    return "-";
  }

  const reasons = value
    .filter((item): item is string => typeof item === "string")
    .map(safeFieldValue)
    .filter((item) => item !== "-");

  return reasons.length > 0 ? reasons.join(", ") : "-";
}

function payloadPreviewHeadline(log: RequestLogSummary, status: PayloadPreviewStatus): string {
  if (!log.payload_stored) {
    return "No payload preview was stored for this request.";
  }

  if (status === "loading") {
    return "Loading redacted preview metadata.";
  }

  if (status === "loaded") {
    return "Redacted preview metadata loaded.";
  }

  return "Hash metadata is available without loading payload preview.";
}

function payloadMetadataRows(
  log: RequestLogSummary,
  preview: RequestPayloadPreview | null,
): Array<[string, string]> {
  return [
    ["Policy", safeFieldValue(preview?.payload_policy_id ?? log.payload_policy_id)],
    ["Stored", formatBoolean(preview?.payload_stored ?? log.payload_stored)],
    ["Redaction", safeFieldValue(preview?.redaction_status ?? log.redaction_status)],
    ["Request hash", safeFieldValue(preview?.request_body_hash ?? log.request_body_hash)],
    ["Response hash", safeFieldValue(preview?.response_body_hash ?? log.response_body_hash)],
  ];
}

function payloadPreviewStatusMessage(status: PayloadPreviewStatus, message: string | null): string {
  switch (status) {
    case "loaded":
      return "Payload preview loaded.";
    case "forbidden":
      return "You do not have permission to load payload previews.";
    case "not_implemented":
      return "Payload preview API is not implemented yet.";
    case "unavailable":
      return "Payload preview is not available for this request.";
    case "error":
      return message ?? "Payload preview request failed.";
    default:
      return "";
  }
}

function safePayloadPreviewSections(preview: RequestPayloadPreview): Array<{ title: string; value: JsonValue }> {
  const sections: Array<[string, JsonValue | null | undefined]> = [
    ["Request metadata", preview.request_metadata],
    ["Response metadata", preview.response_metadata],
    ["Request redacted preview", preview.redacted_request_preview],
    ["Response redacted preview", preview.redacted_response_preview],
    ["Metadata", preview.metadata],
  ];

  return sections.flatMap(([title, value]) => {
    if (value === null || value === undefined) {
      return [];
    }

    const safeValue = sanitizeDisplayJson(value);
    return isEmptyJsonValue(safeValue) ? [] : [{ title, value: safeValue }];
  });
}

function isEmptyJsonValue(value: JsonValue): boolean {
  if (Array.isArray(value)) {
    return value.length === 0;
  }

  if (isJsonRecord(value)) {
    return Object.keys(value).length === 0;
  }

  return value === null || value === "";
}

function formatJsonPreview(value: JsonValue): string {
  const serialized = JSON.stringify(value, null, 2);

  return serialized.length > 2000 ? `${serialized.slice(0, 2000)}\n...` : serialized;
}

function apiStatusCode(error: unknown): number | undefined {
  if (typeof error !== "object" || error === null || !("status" in error)) {
    return undefined;
  }

  const status = (error as { status?: unknown }).status;
  return typeof status === "number" ? status : undefined;
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
