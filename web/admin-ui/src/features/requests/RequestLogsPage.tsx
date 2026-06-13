import { FormEvent, useEffect, useRef, useState } from "react";
import {
  ApiClientError,
  adminRequestLogsExportCsvContract,
  type AdminRequestLogsExportCsvColumn,
  exportRequestLogsCsv as exportRequestLogsCsvFromApi,
  getRequestLogDetail,
  getRequestTraceSummary,
  type JsonValue,
  listRequestLogsPage,
  type RequestLogDetail,
  type RequestLedgerSummary,
  type RequestLogListFilters,
  type RequestLogSummary,
  type RequestTraceSummary,
} from "../../api/client";
import { ActionButton } from "../../design/ActionButton";
import { DataTable } from "../../design/DataTable";
import { Field } from "../../design/Field";
import { SectionHeader } from "../../design/SectionHeader";
import {
  adminTableServerPaginationContract,
  createSavedTableFilterStore,
  normalizeTableServerPage,
  type TableServerPaginationMeta,
  type TableServerSortDir,
} from "../../design/tableState";
import {
  StateChip,
  errorMessage,
  isJsonRecord,
} from "../../components/adminUtils";
import {
  formatDateTime,
  formatErrorParts,
  formatList,
  formatMilliseconds,
  formatTokenUsage,
} from "../../lib/format";
import { safeDisplayText, safeShortId, safeStatusValue, statusLabel } from "../../lib/safeText";
import { Download, Eye, RefreshCw, Save, Search, X } from "../../components/icons";
import { PromptProtectionSummary } from "../../components/PromptProtectionSummary";
import type { RequestLogsFocusTarget } from "../../app/types";
import { LedgerSummaryPanel, normalizeLedgerSummary, TraceSummaryPanel } from "./RequestLedgerPanels";
import { RequestPayloadPreviewPanel } from "./RequestPayloadPreviewPanel";
import { RequestProviderAttemptsPanel } from "./RequestProviderAttemptsPanel";

type FilterState = {
  apiKeyId: string;
  channelId: string;
  createdFrom: string;
  createdTo: string;
  errorType: string;
  limit: string;
  model: string;
  sortDir: TableServerSortDir;
  sortKey: string;
  status: string;
  stream: string;
  traceId: string;
};

const defaultFilters: FilterState = {
  apiKeyId: "",
  channelId: "",
  createdFrom: "",
  createdTo: "",
  errorType: "",
  limit: "25",
  model: "",
  sortDir: "desc",
  sortKey: "created_at",
  status: "",
  stream: "",
  traceId: "",
};

const requestLogStatuses = ["", "started", "succeeded", "failed", "rejected", "partial", "cancelled"];
const requestLogSortOptions = [
  { label: "创建时间", value: "created_at" },
  { label: "耗时", value: "latency_ms" },
  { label: "成本", value: "final_cost" },
  { label: "状态", value: "status" },
];
const savedRequestFiltersKey = "fubox.admin.requests.savedFilters.v1";
const requestFilterStore = createSavedTableFilterStore<FilterState>({
  defaults: defaultFilters,
  storageKey: savedRequestFiltersKey,
});
const streamFilterOptions = [
  { label: "全部", value: "" },
  { label: "流式", value: "true" },
  { label: "非流式", value: "false" },
];

export function RequestLogsPage({
  focusRequestId,
  focusTarget,
}: {
  focusRequestId?: string | null;
  focusTarget?: RequestLogsFocusTarget | null;
} = {}) {
  const [detail, setDetail] = useState<RequestLogDetail | null>(null);
  const [detailLoading, setDetailLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [filterNotice, setFilterNotice] = useState<string | null>(null);
  const [filters, setFilters] = useState<FilterState>(() => requestFilterStore.read() ?? defaultFilters);
  const [loading, setLoading] = useState(true);
  const [logs, setLogs] = useState<RequestLogSummary[]>([]);
  const [pageMeta, setPageMeta] = useState<TableServerPaginationMeta>(() => defaultRequestLogPageMeta(defaultFilters));
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
      const requestFilters = toListFilters(nextFilters);
      const nextPage = normalizeTableServerPage(await listRequestLogsPage(requestFilters), {
        limit: requestFilters.limit ?? 25,
        sort_dir: requestFilters.sort_dir,
        sort_key: requestFilters.sort_key,
      });
      if (logsRequestSeq.current === requestSeq) {
        setLogs(nextPage.items);
        setPageMeta(nextPage.pagination);
      }
    } catch (requestError) {
      if (logsRequestSeq.current === requestSeq) {
        setError(errorMessage(requestError));
        setLogs([]);
        setPageMeta(defaultRequestLogPageMeta(nextFilters));
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
        setPageMeta({
          ...defaultRequestLogPageMeta(nextFilters),
          has_more: summary.limit_reached,
          total: summary.request_count,
          unsupported: false,
        });
      }
    } catch (requestError) {
      if (logsRequestSeq.current === requestSeq) {
        setError(errorMessage(requestError));
        setLogs([]);
        setPageMeta(defaultRequestLogPageMeta(nextFilters));
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
    setFilterNotice(null);
    void loadCurrent(filters);
  }

  function handleSaveFilters() {
    if (!requestFilterStore.write(filters)) {
      setFilterNotice("当前浏览器无法保存筛选。");
      return;
    }

    setFilterNotice("已保存当前筛选；下次进入请求日志会自动恢复。");
  }

  function handleClearSavedFilters() {
    requestFilterStore.clear();
    setFilters(defaultFilters);
    setFilterNotice("已清除保存筛选，并恢复默认条件。");
    void loadLogs(defaultFilters);
  }

  async function handleBackendExportCsv() {
    if (logs.length === 0) {
      setFilterNotice("当前筛选没有可导出的请求日志。");
      return;
    }

    setError(null);
    try {
      const csv = await exportRequestLogsCsvFromApi(toListFilters(filters));
      downloadTextFile(`ai-gateway-request-logs-${dateStamp()}.csv`, csv, "text/csv;charset=utf-8");
      setFilterNotice(
        `已从后端导出当前筛选结果；${adminRequestLogsExportCsvContract.schema_version} 只包含安全摘要字段，Audit Logs action=${adminRequestLogsExportCsvContract.audit_action}。`,
      );
    } catch (requestError) {
      if (isRequestLogExportUnavailable(requestError)) {
        downloadLocalRequestLogsCsv(logs);
        setFilterNotice(
          `后端导出 route 暂不可用（${requestLogExportUnavailableReason(requestError)}），已回退到本地安全 CSV。`,
        );
        return;
      }

      setError(errorMessage(requestError));
    }
  }

  function handleLocalExportCsv() {
    if (logs.length === 0) {
      setFilterNotice("当前筛选没有可导出的请求日志。");
      return;
    }

    setError(null);
    downloadLocalRequestLogsCsv(logs);
    setFilterNotice("已从当前列表本地导出 CSV；只包含安全摘要字段。");
  }

  function loadCurrent(nextFilters = filters) {
    return nextFilters.traceId.trim() ? loadTrace(nextFilters) : loadLogs(nextFilters);
  }

  useEffect(() => {
    void loadCurrent(filters);
  }, []);

  useEffect(() => {
    const requestId = focusTarget?.requestId?.trim() || focusRequestId?.trim();

    if (!requestId || requestId === selectedId) {
      return;
    }

    void loadDetail(requestId);
  }, [focusRequestId, focusTarget?.requestId]);

  useEffect(() => {
    const traceId = focusTarget?.traceId?.trim();

    if (!traceId || traceId === filters.traceId.trim()) {
      return;
    }

    const nextFilters = { ...filters, traceId };
    setFilters(nextFilters);
    setFilterNotice(`已按 trace ${safeShortId(traceId)} 加载请求摘要。`);
    void loadTrace(nextFilters);
  }, [focusTarget?.traceId]);

  function closeDetail() {
    detailRequestSeq.current += 1;
    setSelectedId(null);
    setDetail(null);
    setDetailLoading(false);
  }

  return (
    <div className="admin-page" aria-label="请求日志">
      <section className="admin-panel" aria-label="请求日志筛选">
        <SectionHeader
          title="请求日志"
          description="查看网关请求的路由、状态、成本和耗时，不展示载荷原文。"
          actions={
            <ActionButton
              icon={<RefreshCw aria-hidden="true" size={18} className={loading ? "spin" : undefined} />}
              onClick={() => void loadCurrent()}
              disabled={loading}
            >
            刷新
            </ActionButton>
          }
        />

        <form className="filter-bar" onSubmit={handleFilterSubmit}>
          <Field label="状态">
            <select
              value={filters.status}
              onChange={(event) => {
                const value = event.currentTarget.value;
                setFilters((current) => ({ ...current, status: value }));
              }}
            >
              {requestLogStatuses.map((status) => (
                <option key={status || "all"} value={status}>
                  {status ? statusLabel(status) : "全部"}
                </option>
              ))}
            </select>
          </Field>

          <Field label="Trace ID">
            <input
              value={filters.traceId}
              onChange={(event) => {
                const value = event.currentTarget.value;
                setFilters((current) => ({ ...current, traceId: value }));
              }}
              placeholder="trace id"
            />
          </Field>

          <Field label="起始时间">
            <input
              type="datetime-local"
              value={filters.createdFrom}
              onChange={(event) => {
                const value = event.currentTarget.value;
                setFilters((current) => ({ ...current, createdFrom: value }));
              }}
            />
          </Field>

          <Field label="结束时间">
            <input
              type="datetime-local"
              value={filters.createdTo}
              onChange={(event) => {
                const value = event.currentTarget.value;
                setFilters((current) => ({ ...current, createdTo: value }));
              }}
            />
          </Field>

          <Field label="模型">
            <input
              value={filters.model}
              onChange={(event) => {
                const value = event.currentTarget.value;
                setFilters((current) => ({ ...current, model: value }));
              }}
              placeholder="请求模型"
            />
          </Field>

          <Field label="API Key">
            <input
              value={filters.apiKeyId}
              onChange={(event) => {
                const value = event.currentTarget.value;
                setFilters((current) => ({ ...current, apiKeyId: value }));
              }}
              placeholder="virtual key 或 profile id"
            />
          </Field>

          <Field label="Channel ID">
            <input
              value={filters.channelId}
              onChange={(event) => {
                const value = event.currentTarget.value;
                setFilters((current) => ({ ...current, channelId: value }));
              }}
              placeholder="解析后的通道"
            />
          </Field>

          <Field label="Stream">
            <select
              value={filters.stream}
              onChange={(event) => {
                const value = event.currentTarget.value;
                setFilters((current) => ({ ...current, stream: value }));
              }}
            >
              {streamFilterOptions.map((option) => (
                <option key={option.value || "all"} value={option.value}>
                  {option.label}
                </option>
              ))}
            </select>
          </Field>

          <Field label="错误类型">
            <input
              value={filters.errorType}
              onChange={(event) => {
                const value = event.currentTarget.value;
                setFilters((current) => ({ ...current, errorType: value }));
              }}
              placeholder="error_code / owner"
            />
          </Field>

          <Field className="field--compact" label="数量上限">
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

          <Field label="排序字段">
            <select
              value={filters.sortKey}
              onChange={(event) => {
                const value = event.currentTarget.value;
                setFilters((current) => ({ ...current, sortKey: value }));
              }}
            >
              {requestLogSortOptions.map((option) => (
                <option key={option.value} value={option.value}>
                  {option.label}
                </option>
              ))}
            </select>
          </Field>

          <Field label="排序方向">
            <select
              value={filters.sortDir}
              onChange={(event) => {
                const value = event.currentTarget.value === "asc" ? "asc" : "desc";
                setFilters((current) => ({ ...current, sortDir: value }));
              }}
            >
              <option value="desc">降序</option>
              <option value="asc">升序</option>
            </select>
          </Field>

          <ActionButton
            className="primary-button--inline"
            icon={<Search aria-hidden="true" size={17} />}
            type="submit"
            variant="primary"
          >
            搜索
          </ActionButton>
          <ActionButton
            icon={<Save aria-hidden="true" size={16} />}
            type="button"
            onClick={handleSaveFilters}
          >
            保存筛选
          </ActionButton>
          <ActionButton
            disabled={loading || logs.length === 0}
            icon={<Download aria-hidden="true" size={16} />}
            type="button"
            title={`${adminRequestLogsExportCsvContract.schema_version}; audit=${adminRequestLogsExportCsvContract.audit_action}`}
            onClick={() => void handleBackendExportCsv()}
          >
            后端导出
          </ActionButton>
          <ActionButton
            disabled={loading || logs.length === 0}
            icon={<Download aria-hidden="true" size={16} />}
            type="button"
            title={`${adminRequestLogsExportCsvContract.schema_version}; local fallback uses allowed_columns only`}
            onClick={handleLocalExportCsv}
          >
            本地导出
          </ActionButton>
          <ActionButton
            icon={<X aria-hidden="true" size={16} />}
            type="button"
            variant="secondary"
            onClick={handleClearSavedFilters}
          >
            清除保存
          </ActionButton>
        </form>

        {filterNotice ? <p className="form-status">{filterNotice}</p> : null}
        {error ? <p className="form-status form-status--error">{error}</p> : null}
      </section>

      {traceSummary ? <TraceSummaryPanel summary={traceSummary} /> : null}

      <section aria-label="请求日志列表">
        <TableServerPaginationStatus meta={pageMeta} visibleCount={logs.length} />
        <DataTable aria-label="请求日志列表" className="admin-table">
            <thead>
              <tr>
                <th>请求</th>
                <th>状态</th>
                <th>模型</th>
                <th>通道</th>
                <th>成本</th>
                <th>耗时</th>
                <th>详情</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr>
                  <td colSpan={7}>正在加载请求日志。</td>
                </tr>
              ) : logs.length > 0 ? (
                logs.map((log) => (
                  <tr key={log.id} className={selectedId === log.id ? "table-row--selected" : undefined}>
                    <td>
                      <strong>{safeShortId(log.id)}</strong>
                      <span>{formatDateTime(log.created_at)}</span>
                      {log.trace_id ? <span>Trace {safeShortId(log.trace_id)}</span> : null}
                    </td>
                    <td>
                      <StateChip status={safeStatusValue(log.status)} />
                      {log.http_status ? <span>HTTP {log.http_status}</span> : null}
                    </td>
                    <td>
                      <strong>{safeDisplayText(log.requested_model)}</strong>
                      <span>{safeDisplayText(log.upstream_model)}</span>
                    </td>
                    <td>
                      <strong>{safeShortId(log.resolved_channel_id)}</strong>
                      <span>{safeDisplayText(log.route_policy_version)}</span>
                    </td>
                    <td>
                      {formatRequestMoney(log.final_cost, log.currency)}
                    </td>
                    <td>
                      <strong>{formatMilliseconds(log.latency_ms)}</strong>
                      <span>TTFT {formatMilliseconds(log.ttft_ms)}</span>
                    </td>
                    <td>
                      <ActionButton
                        variant="table"
                        icon={<Eye aria-hidden="true" size={15} />}
                        onClick={() => void loadDetail(log.id)}
                        aria-label={`查看请求日志 ${safeDisplayText(log.id)}`}
                      >
                        查看
                      </ActionButton>
                    </td>
                  </tr>
                ))
              ) : (
                <tr>
                  <td colSpan={7}>当前筛选条件下没有匹配的请求日志。</td>
                </tr>
              )}
            </tbody>
        </DataTable>
      </section>

      <RequestLogDetailPanel
        detail={detail}
        filterLimit={filters.limit}
        loading={detailLoading}
        onClose={closeDetail}
        selectedId={selectedId}
      />
    </div>
  );
}

function TableServerPaginationStatus({
  meta,
  visibleCount,
}: {
  meta: TableServerPaginationMeta;
  visibleCount: number;
}) {
  const totalLabel = typeof meta.total === "number" ? `${meta.total} total` : "total unavailable";
  const hasMoreLabel =
    typeof meta.has_more === "boolean" ? (meta.has_more ? "has_more=true" : "has_more=false") : "has_more unavailable";
  const fallbackLabel = meta.unsupported
    ? `unsupported fallback: ${safeDisplayText(meta.unsupported_reason)}`
    : adminTableServerPaginationContract.schema_version;

  return (
    <p className="table-pagination-status">
      <strong>{visibleCount} visible</strong>
      <span>{totalLabel}</span>
      <span>{hasMoreLabel}</span>
      <span>
        sort={safeDisplayText(meta.sort_key)} {meta.sort_dir ?? "desc"}
      </span>
      <span>{fallbackLabel}</span>
    </p>
  );
}

function RequestLogDetailPanel({
  detail,
  filterLimit,
  loading,
  onClose,
  selectedId,
}: {
  detail: RequestLogDetail | null;
  filterLimit: string;
  loading: boolean;
  onClose: () => void;
  selectedId: string | null;
}) {
  const [traceError, setTraceError] = useState<string | null>(null);
  const [traceLoading, setTraceLoading] = useState(false);
  const [traceSummary, setTraceSummary] = useState<RequestTraceSummary | null>(null);
  const traceRequestSeq = useRef(0);

  useEffect(() => {
    const traceId = detail?.request_log.trace_id?.trim();
    const limit = Number.parseInt(filterLimit, 10);
    const requestSeq = traceRequestSeq.current + 1;
    traceRequestSeq.current = requestSeq;
    setTraceSummary(null);
    setTraceError(null);

    if (!traceId) {
      setTraceLoading(false);
      return;
    }

    setTraceLoading(true);
    void getRequestTraceSummary(traceId, { limit: Number.isFinite(limit) ? limit : 25 })
      .then((summary) => {
        if (traceRequestSeq.current === requestSeq) {
          setTraceSummary(summary);
        }
      })
      .catch((requestError) => {
        if (traceRequestSeq.current === requestSeq) {
          setTraceError(errorMessage(requestError));
        }
      })
      .finally(() => {
        if (traceRequestSeq.current === requestSeq) {
          setTraceLoading(false);
        }
      });
  }, [detail?.request_log.id, detail?.request_log.trace_id, filterLimit]);

  if (!selectedId) {
    return null;
  }

  if (loading) {
    return (
      <aside className="request-detail-drawer" aria-label="请求日志详情">
        <div className="request-detail-drawer__header">
          <div>
            <h2>请求详情</h2>
            <p>正在加载 {safeShortId(selectedId)}。</p>
          </div>
          <ActionButton
            aria-label="关闭请求详情"
            icon={<X aria-hidden="true" size={16} />}
            onClick={onClose}
            variant="secondary"
          >
            关闭
          </ActionButton>
        </div>
      </aside>
    );
  }

  if (!detail) {
    return null;
  }

  const log = detail.request_log;
  const ledger = normalizeLedgerSummary(detail.ledger);
  const routeSummary = summarizeRouteDecisionSnapshot(detail.route_decision_snapshot);
  const failureSummary = summarizeFailureReasons(detail, traceSummary);

  return (
    <aside className="request-detail-drawer" aria-label="请求日志详情">
      <div className="request-detail-drawer__header">
        <div>
          <h2>请求详情</h2>
          <p>{safeDisplayText(log.id)}</p>
        </div>
        <div className="request-detail-drawer__actions">
          <StateChip status={safeStatusValue(log.status)} />
          <ActionButton
            aria-label="关闭请求详情"
            icon={<X aria-hidden="true" size={16} />}
            onClick={onClose}
            variant="secondary"
          >
            关闭
          </ActionButton>
        </div>
      </div>

      <section className="request-detail-summary" aria-label="请求排障摘要">
        <MetricCard label="状态" value={safeStatusValue(log.status)} />
        <MetricCard label="HTTP" value={formatHttpStatus(log.http_status)} />
        <MetricCard label="延迟" value={formatMilliseconds(log.latency_ms)} />
        <MetricCard label="TTFT" value={formatMilliseconds(log.ttft_ms)} />
        <MetricCard label="Token" value={formatTokenUsage(log.input_tokens, log.output_tokens)} />
        <MetricCard label="成本" value={formatRequestMoney(log.final_cost, log.currency)} />
      </section>

      <section className="detail-grid" aria-label="请求日志详情内容">
      <TraceFailureSummaryPanel
        detail={detail}
        failureSummary={failureSummary}
        loading={traceLoading}
        traceError={traceError}
        traceSummary={traceSummary}
      />

      <article className="admin-panel">
        <SectionHeader
          title="基础信息"
          description={formatDateTime(log.created_at)}
        />

        <dl className="detail-list detail-list--three">
          <div>
            <dt>Request ID</dt>
            <dd>{safeDisplayText(log.id)}</dd>
          </div>
          <div>
            <dt>Client Request</dt>
            <dd>{safeShortId(log.client_request_id)}</dd>
          </div>
          <div>
            <dt>Trace</dt>
            <dd>{safeShortId(log.trace_id)}</dd>
          </div>
          <div>
            <dt>HTTP</dt>
            <dd>{formatHttpStatus(log.http_status)}</dd>
          </div>
          <div>
            <dt>可重试</dt>
            <dd>{formatBoolean(log.retryable)}</dd>
          </div>
          <div>
            <dt>流式</dt>
            <dd>{formatStreamStatus(log)}</dd>
          </div>
          <div>
            <dt>开始</dt>
            <dd>{formatDateTime(log.created_at)}</dd>
          </div>
          <div>
            <dt>完成</dt>
            <dd>{formatDateField(log.completed_at)}</dd>
          </div>
          <div>
            <dt>协议</dt>
            <dd>{formatProtocol(log)}</dd>
          </div>
          <div>
            <dt>租户</dt>
            <dd>{safeShortId(log.tenant_id)}</dd>
          </div>
          <div>
            <dt>项目</dt>
            <dd>{safeShortId(log.project_id)}</dd>
          </div>
          <div>
            <dt>Virtual Key</dt>
            <dd>{safeShortId(log.virtual_key_id)}</dd>
          </div>
        </dl>
      </article>

      <OpenAiCompatPanel log={log} />

      <StreamFinalizerPanel log={log} />

      <article className="admin-panel">
        <SectionHeader
          title="模型与路由"
          description={supportRouteSummary(routeSummary, log.resolved_channel_id)}
        />

        <dl className="detail-list detail-list--three">
          <div>
            <dt>请求模型</dt>
            <dd>{safeDisplayText(log.requested_model)}</dd>
          </div>
          <div>
            <dt>上游模型</dt>
            <dd>{safeDisplayText(log.upstream_model)}</dd>
          </div>
          <div>
            <dt>Canonical Model</dt>
            <dd>{safeShortId(log.canonical_model_id)}</dd>
          </div>
          <div>
            <dt>通道</dt>
            <dd>{safeShortId(log.resolved_channel_id)}</dd>
          </div>
          <div>
            <dt>供应商</dt>
            <dd>{formatProviderSummary(routeSummary.selectedProviderId ?? log.resolved_provider_id)}</dd>
          </div>
          <div>
            <dt>Provider Key</dt>
            <dd>{log.provider_key_id ? "已配置" : "-"}</dd>
          </div>
          <div>
            <dt>策略版本</dt>
            <dd>{safeDisplayText(log.route_policy_version)}</dd>
          </div>
          <div>
            <dt>候选</dt>
            <dd>{routeSummary.candidateCount}</dd>
          </div>
          <div>
            <dt>已过滤</dt>
            <dd>{routeSummary.filteredCount}</dd>
          </div>
          <div>
            <dt>拒绝原因</dt>
            <dd>{routeSummary.rejectReason}</dd>
          </div>
          <div>
            <dt>回退</dt>
            <dd>{routeSummary.fallbackStatus}</dd>
          </div>
        </dl>
      </article>

      <article className="admin-panel">
        <SectionHeader title="耗时、错误与计费" description={supportHeadline(log.status, log.error_owner, log.error_code)} />

        <dl className="detail-list detail-list--three">
          <div>
            <dt>状态</dt>
            <dd>{safeStatusValue(log.status)}</dd>
          </div>
          <div>
            <dt>延迟</dt>
            <dd>{formatMilliseconds(log.latency_ms)}</dd>
          </div>
          <div>
            <dt>First Token</dt>
            <dd>{formatMilliseconds(log.ttft_ms)}</dd>
          </div>
          <div>
            <dt>Token</dt>
            <dd>{formatTokenUsage(log.input_tokens, log.output_tokens)}</dd>
          </div>
          <div>
            <dt>成本</dt>
            <dd>{formatRequestMoney(log.final_cost, log.currency)}</dd>
          </div>
          <div>
            <dt>账本行</dt>
            <dd>{ledger.entries.length > 0 ? `${ledger.returned_count} 条` : "-"}</dd>
          </div>
          <div>
            <dt>错误归属</dt>
            <dd>{safeDisplayText(log.error_owner)}</dd>
          </div>
          <div>
            <dt>错误码</dt>
            <dd>{safeDisplayText(log.error_code)}</dd>
          </div>
          <div>
            <dt>错误摘要</dt>
            <dd>{formatErrorParts(log.error_owner, log.error_code)}</dd>
          </div>
          <div>
            <dt>脱敏</dt>
            <dd>{safeDisplayText(log.redaction_status)}</dd>
          </div>
        </dl>
      </article>

      <OperatorSupportSummaryPanel detail={detail} ledger={ledger} />

      <PreauthorizeRateLimitExplainabilityPanel detail={detail} />

      <RouteTracePanel detail={detail} />

      <PromptProtectionSummary sourceLabel="路由快照脱敏信号" value={detail.route_decision_snapshot} />

      <RequestPayloadPreviewPanel key={log.id} log={log} />

      <LedgerSummaryPanel
        emptyMessage="此请求没有关联的账本条目。"
        summary={ledger}
        title="账本条目"
      />

      <RequestProviderAttemptsPanel
        attempts={detail.provider_attempts}
        explainability={detail.provider_attempts_explainability}
      />
      </section>
    </aside>
  );
}

function PreauthorizeRateLimitExplainabilityPanel({ detail }: { detail: RequestLogDetail }) {
  const readback = detail.preauthorize_and_rate_limit_explainability;

  if (!readback) {
    return null;
  }

  const fallbackReasons = uniqueSafeValues([
    ...readback.fallback_or_reject.fallback_reasons,
    readback.fallback_or_reject.route_fallback_reason,
  ]);

  return (
    <article className="admin-panel detail-panel--wide" aria-label="Preauthorize and rate-limit explainability">
      <SectionHeader title="预授权与限流" description={safeDisplayText(readback.safe_next_action)} />

      <dl className="detail-list detail-list--three">
        <div>
          <dt>Preauth</dt>
          <dd>{safeDisplayText(readback.preauthorize.status)}</dd>
        </div>
        <div>
          <dt>余额</dt>
          <dd>{safeDisplayText(readback.preauthorize.balance.status)}</dd>
        </div>
        <div>
          <dt>预算</dt>
          <dd>{safeDisplayText(readback.preauthorize.budget.status)}</dd>
        </div>
        <div>
          <dt>Preauth 拒绝</dt>
          <dd>{safeDisplayText(readback.preauthorize.reject_reason)}</dd>
        </div>
        <div>
          <dt>Provider Blocked</dt>
          <dd>{formatBoolean(readback.preauthorize.provider_attempts_blocked)}</dd>
        </div>
        <div>
          <dt>Rate Limit</dt>
          <dd>{safeDisplayText(readback.rate_limit_reservation.status)}</dd>
        </div>
        <div>
          <dt>Concurrency</dt>
          <dd>{formatRateLimitDimension(readback.rate_limit_reservation.concurrency)}</dd>
        </div>
        <div>
          <dt>RPM</dt>
          <dd>{formatRateLimitDimension(readback.rate_limit_reservation.rpm)}</dd>
        </div>
        <div>
          <dt>TPM</dt>
          <dd>{formatRateLimitDimension(readback.rate_limit_reservation.tpm)}</dd>
        </div>
        <div>
          <dt>Fallback</dt>
          <dd>{fallbackReasons.length > 0 ? formatList(fallbackReasons) : "未记录回退"}</dd>
        </div>
        <div>
          <dt>Reject</dt>
          <dd>{safeDisplayText(readback.fallback_or_reject.reject_reason)}</dd>
        </div>
        <div>
          <dt>Billing Refusal</dt>
          <dd>{safeDisplayText(readback.fallback_or_reject.billing_refusal_reason)}</dd>
        </div>
        <div>
          <dt>Reserve Ref</dt>
          <dd>{formatBoolean(readback.ledger_refs.reservation_ref_present)}</dd>
        </div>
        <div>
          <dt>Settle Ref</dt>
          <dd>{formatBoolean(readback.ledger_refs.settle_ref_present)}</dd>
        </div>
        <div>
          <dt>Ledger Refs</dt>
          <dd>{readback.ledger_refs.any_ledger_ref_present ? `${readback.ledger_refs.entry_count} 条` : "未记录"}</dd>
        </div>
      </dl>
    </article>
  );
}

function formatRateLimitDimension(dimension: { limit?: number | null; remaining?: number | null; reservation_status?: string | null; status?: string | null }) {
  const status = safeDisplayText(dimension.reservation_status ?? dimension.status);
  const limit = dimension.limit == null ? "-" : safeDisplayText(dimension.limit);
  const remaining = dimension.remaining == null ? "-" : safeDisplayText(dimension.remaining);

  return `${status} / limit ${limit} / remaining ${remaining}`;
}

function OperatorSupportSummaryPanel({
  detail,
  ledger,
}: {
  detail: RequestLogDetail;
  ledger: RequestLedgerSummary;
}) {
  const log = detail.request_log;
  const routeSummary = summarizeRouteDecisionSnapshot(detail.route_decision_snapshot);
  const providerAttempts = detail.provider_attempts;
  const failedAttempts = providerAttempts.filter((attempt) => attempt.status !== "succeeded");
  const fallbackReasons = providerAttempts
    .map((attempt) => attempt.fallback_reason)
    .filter((reason): reason is string => typeof reason === "string" && reason.trim().length > 0);
  const ledgerEffect = ledger.entries.length > 0
    ? `${ledger.returned_count} 条账本记录`
    : "没有关联账本记录";

  return (
    <article className="admin-panel" aria-label="运维支持摘要">
      <SectionHeader title="支持摘要" description={supportHeadline(log.status, log.error_owner, log.error_code)} />

      <dl className="detail-list">
        <div>
          <dt>路由</dt>
          <dd>{supportRouteSummary(routeSummary, log.resolved_channel_id)}</dd>
        </div>
        <div>
          <dt>尝试</dt>
          <dd>
            共 {providerAttempts.length} 次 / 失败 {failedAttempts.length} 次
          </dd>
        </div>
        <div>
          <dt>回退</dt>
          <dd>{fallbackReasons.length > 0 ? formatList(fallbackReasons) : "未记录回退"}</dd>
        </div>
        <div>
          <dt>用量</dt>
          <dd>{formatTokenUsage(log.input_tokens, log.output_tokens)}</dd>
        </div>
        <div>
          <dt>成本</dt>
          <dd>{formatRequestMoney(log.final_cost, log.currency)}</dd>
        </div>
        <div>
          <dt>账本</dt>
          <dd>{ledgerEffect}</dd>
        </div>
        <div>
          <dt>脱敏</dt>
          <dd>{safeDisplayText(log.redaction_status)}</dd>
        </div>
        <div>
          <dt>Trace</dt>
          <dd>{safeShortId(log.trace_id)}</dd>
        </div>
      </dl>
    </article>
  );
}

function TraceFailureSummaryPanel({
  detail,
  failureSummary,
  loading,
  traceError,
  traceSummary,
}: {
  detail: RequestLogDetail;
  failureSummary: ReturnType<typeof summarizeFailureReasons>;
  loading: boolean;
  traceError: string | null;
  traceSummary: RequestTraceSummary | null;
}) {
  const traceId = detail.request_log.trace_id;
  const traceDescription = traceId
    ? loading
      ? `正在合并 Trace ${safeShortId(traceId)}。`
      : traceError
        ? `Trace ${safeShortId(traceId)} 暂不可用。`
        : `Trace ${safeShortId(traceId)} / ${traceSummary?.request_count ?? 1} 个请求。`
    : "此请求没有 trace id。";

  return (
    <article className="admin-panel detail-panel--wide" aria-label="Trace 失败原因摘要">
      <SectionHeader title="Trace 失败原因" description={traceDescription} />

      <dl className="detail-list detail-list--three">
        <div>
          <dt>Fallback</dt>
          <dd>{failureSummary.fallbackReasons}</dd>
        </div>
        <div>
          <dt>Reject</dt>
          <dd>{failureSummary.rejectReasons}</dd>
        </div>
        <div>
          <dt>余额不足</dt>
          <dd>{failureSummary.insufficientBalance}</dd>
        </div>
        <div>
          <dt>Rate limit</dt>
          <dd>{failureSummary.rateLimit}</dd>
        </div>
        <div>
          <dt>最后错误</dt>
          <dd>{failureSummary.lastError}</dd>
        </div>
        <div>
          <dt>失败请求</dt>
          <dd>{failureSummary.failedRequests}</dd>
        </div>
        <div>
          <dt>同 Trace 请求</dt>
          <dd>{failureSummary.traceRequests}</dd>
        </div>
        <div>
          <dt>账本</dt>
          <dd>{failureSummary.ledger}</dd>
        </div>
        <div>
          <dt>读取状态</dt>
          <dd>{traceError ? safeDisplayText(traceError) : loading ? "加载中" : "已合并"}</dd>
        </div>
      </dl>
    </article>
  );
}

function RouteTracePanel({ detail }: { detail: RequestLogDetail }) {
  const summary = summarizeRouteDecisionSnapshot(detail.route_decision_snapshot);

  return (
    <article className="admin-panel">
      <SectionHeader title="路由 Trace" />

      <dl className="detail-list">
        <div>
          <dt>选中通道</dt>
          <dd>{safeShortId(summary.selectedChannelId)}</dd>
        </div>
        <div>
          <dt>策略</dt>
          <dd>{summary.strategy}</dd>
        </div>
        <div>
          <dt>供应商模型</dt>
          <dd>{summary.selectedProviderModel}</dd>
        </div>
        <div>
          <dt>回退</dt>
          <dd>{summary.fallbackStatus}</dd>
        </div>
        <div>
          <dt>拒绝原因</dt>
          <dd>{summary.rejectReason}</dd>
        </div>
        <div>
          <dt>候选数</dt>
          <dd>{summary.candidateCount}</dd>
        </div>
        <div>
          <dt>已过滤</dt>
          <dd>{summary.filteredCount}</dd>
        </div>
        <div>
          <dt>过滤原因</dt>
          <dd>{summary.filterReasons}</dd>
        </div>
        <div>
          <dt>选中评分</dt>
          <dd>{summary.selectedScoreTotal}</dd>
        </div>
        <div>
          <dt>Trace 亲和性</dt>
          <dd>{summary.traceAffinityStatus}</dd>
        </div>
      </dl>
    </article>
  );
}

function summarizeRouteDecisionSnapshot(snapshot: JsonValue) {
  const emptySummary = {
    candidateCount: "-",
    filterReasons: "-",
    filteredCount: "-",
    fallbackStatus: "-",
    rejectReason: "-",
    selectedChannelId: null,
    selectedProviderId: null,
    selectedProviderModel: "-",
    selectedScoreTotal: "-",
    strategy: "-",
    traceAffinityStatus: "-",
  };

  if (!isJsonRecord(snapshot)) {
    return emptySummary;
  }

  const summary = isJsonRecord(snapshot.summary) ? snapshot.summary : {};

  return {
    candidateCount: safeNumberField(summary.candidate_count),
    filterReasons: formatFilterReasons(summary.filter_reasons),
    filteredCount: safeNumberField(summary.filtered_count),
    fallbackStatus: firstSafeStringField(
      summary.fallback_status,
      summary.fallback_reason,
    ),
    rejectReason: firstSafeStringField(
      summary.reject_reason,
      summary.reject_code,
      summary.rejection_reason,
    ),
    selectedChannelId: stringField(summary.selected_channel_id),
    selectedProviderId: stringField(summary.selected_provider_id),
    selectedProviderModel: safeStringField(summary.selected_provider_model),
    selectedScoreTotal: safeNumberField(summary.selected_score_total),
    strategy: safeStringField(summary.strategy),
    traceAffinityStatus: safeStringField(summary.trace_affinity_status),
  };
}

function summarizeFailureReasons(detail: RequestLogDetail, traceSummary: RequestTraceSummary | null) {
  const routeSummary = summarizeRouteDecisionSnapshot(detail.route_decision_snapshot);
  const log = detail.request_log;
  const traceRequests = traceSummary?.requests ?? [log];
  const errorParts = traceRequests
    .flatMap((request) => [request.error_owner, request.error_code, request.status])
    .filter((value): value is string => typeof value === "string" && value.trim().length > 0);
  const providerFallbacks = detail.provider_attempts
    .map((attempt) => attempt.fallback_reason)
    .filter((value): value is string => typeof value === "string" && value.trim().length > 0);
  const fallbackReasons = uniqueSafeValues([...providerFallbacks, routeSummary.fallbackStatus]);
  const rejectReasons = uniqueSafeValues([
    routeSummary.rejectReason,
    ...errorParts.filter((value) => /reject|refused|denied|forbidden|invalid/i.test(value)),
  ]);
  const insufficientBalanceSignals = uniqueSafeValues(
    errorParts.filter((value) => /insufficient[_ -]?balance|wallet|credit|balance/i.test(value)),
  );
  const rateLimitSignals = uniqueSafeValues(
    errorParts.filter((value) => /rate[_ -]?limit|rpm|tpm|quota|too_many_requests|429/i.test(value)),
  );
  const failedRequests = traceRequests.filter((request) => request.status !== "succeeded");
  const ledger = normalizeLedgerSummary(traceSummary?.ledger ?? detail.ledger);

  return {
    failedRequests: `${failedRequests.length} / ${traceRequests.length}`,
    fallbackReasons: fallbackReasons.length > 0 ? formatList(fallbackReasons) : "未记录回退",
    insufficientBalance: insufficientBalanceSignals.length > 0 ? formatList(insufficientBalanceSignals) : "未命中",
    lastError: traceSummary?.last_error
      ? formatErrorParts(
        traceSummary.last_error.owner,
        traceSummary.last_error.code,
        traceSummary.last_error.status,
        traceSummary.last_error.http_status ? `HTTP ${traceSummary.last_error.http_status}` : null,
      )
      : formatErrorParts(log.error_owner, log.error_code),
    ledger: ledger.entries.length > 0 ? `${ledger.returned_count} 条` : "无账本行",
    rateLimit: rateLimitSignals.length > 0 ? formatList(rateLimitSignals) : "未命中",
    rejectReasons: rejectReasons.length > 0 ? formatList(rejectReasons) : "未记录拒绝",
    traceRequests: traceSummary ? `${traceSummary.request_count} 个` : "当前请求",
  };
}

function uniqueSafeValues(values: Array<string | null | undefined>): string[] {
  return Array.from(
    new Set(
      values
        .map((value) => safeDisplayText(value))
        .filter((value) => value !== "-" && value !== "none"),
    ),
  );
}

function stringField(value: JsonValue | undefined): string | null {
  return typeof value === "string" ? value : null;
}

function safeStringField(value: JsonValue | undefined): string {
  const stringValue = stringField(value);

  return stringValue ? safeDisplayText(stringValue) : "-";
}

function firstSafeStringField(...values: Array<JsonValue | undefined>): string {
  for (const value of values) {
    const safeValue = safeStringField(value);

    if (safeValue !== "-") {
      return safeValue;
    }
  }

  return "-";
}

function safeNumberField(value: JsonValue | undefined): string {
  if (typeof value === "number" && Number.isFinite(value)) {
    return safeDisplayText(value);
  }

  if (typeof value === "string") {
    return safeDisplayText(value);
  }

  return "-";
}

function formatFilterReasons(value: JsonValue | undefined): string {
  if (!Array.isArray(value)) {
    return "-";
  }

  const reasons = value
    .filter((item): item is string => typeof item === "string")
    .map(safeDisplayText)
    .filter((item) => item !== "-");

  return reasons.length > 0 ? reasons.join(", ") : "-";
}

function toListFilters(filters: FilterState): RequestLogListFilters {
  const limit = Number.parseInt(filters.limit, 10);

  return {
    api_key_profile_id: filters.apiKeyId.trim() || undefined,
    channel_id: filters.channelId.trim() || undefined,
    created_from: localDateTimeFilter(filters.createdFrom),
    created_to: localDateTimeFilter(filters.createdTo),
    error_type: filters.errorType.trim() || undefined,
    limit: Number.isFinite(limit) ? limit : undefined,
    model: filters.model.trim() || undefined,
    sort_dir: filters.sortDir,
    sort_key: filters.sortKey.trim() || undefined,
    status: filters.status || undefined,
    stream: filters.stream || undefined,
    trace_id: filters.traceId.trim() || undefined,
    virtual_key_id: filters.apiKeyId.trim() || undefined,
  };
}

function defaultRequestLogPageMeta(filters: FilterState): TableServerPaginationMeta {
  const limit = Number.parseInt(filters.limit, 10);

  return {
    has_more: null,
    limit: Number.isFinite(limit) ? limit : 25,
    sort_dir: filters.sortDir,
    sort_key: filters.sortKey || "created_at",
    total: null,
    unsupported: true,
    unsupported_reason: "not_loaded",
  };
}

function localDateTimeFilter(value: string): string | undefined {
  return value.trim() ? value.trim() : undefined;
}

function formatBoolean(value: boolean | null | undefined): string {
  if (value === null || value === undefined) {
    return "-";
  }

  return value ? "是" : "否";
}

function formatDateField(value: string | null | undefined): string {
  return value ? formatDateTime(value) : "-";
}

function toTraceFilters(filters: FilterState): { limit?: number } {
  const limit = Number.parseInt(filters.limit, 10);

  return {
    limit: Number.isFinite(limit) ? limit : undefined,
  };
}

function supportHeadline(
  status: string,
  errorOwner: string | null | undefined,
  errorCode: string | null | undefined,
): string {
  const error = formatErrorParts(errorOwner, errorCode);
  const safeRequestStatus = safeStatusValue(status);

  return error === "-"
    ? `请求 ${safeRequestStatus}；路由、用量、账本和脱敏信息可供查看。`
    : `请求 ${safeRequestStatus}；${error}。`;
}

function supportRouteSummary(
  summary: ReturnType<typeof summarizeRouteDecisionSnapshot>,
  resolvedChannelId: string | null | undefined,
): string {
  const channel = safeShortId(summary.selectedChannelId ?? resolvedChannelId);
  const candidateSummary = summary.candidateCount === "-"
    ? "候选不可用"
    : `${summary.candidateCount} 个候选`;

  return `${channel} / ${candidateSummary}`;
}

function formatHttpStatus(value: number | null | undefined): string {
  return typeof value === "number" ? `HTTP ${value}` : "-";
}

function formatProtocol(log: RequestLogSummary): string {
  return formatErrorParts(log.inbound_protocol, log.protocol_mode, log.outbound_protocol);
}

function formatProviderSummary(providerId: string | null | undefined): string {
  const provider = safeShortId(providerId);

  return provider === "-" ? "-" : `Provider ${provider}`;
}

function formatRequestMoney(amount: string | number | null | undefined, currency: string | null | undefined): string {
  const safeAmount = safeDisplayText(amount);
  const safeCurrency = safeDisplayText(currency);

  if (safeAmount === "-" && safeCurrency === "-") {
    return "-";
  }

  return safeCurrency === "-" ? safeAmount : `${safeAmount} ${safeCurrency}`;
}

function formatStreamStatus(log: RequestLogSummary): string {
  if (log.partial_sent) {
    return `partial${log.stream_end_reason ? ` / ${safeDisplayText(log.stream_end_reason)}` : ""}`;
  }

  return log.stream_end_reason ? `stream / ${safeDisplayText(log.stream_end_reason)}` : "非流式";
}

function OpenAiCompatPanel({ log }: { log: RequestLogSummary }) {
  const compat = openAiCompatProjection(log);

  return (
    <article className="admin-panel">
      <SectionHeader
        title="OpenAI 兼容读回"
        description={compat.status === "not_recorded" ? "未记录兼容补形" : safeDisplayText(compat.status)}
      />

      <dl className="detail-list detail-list--three">
        <div>
          <dt>Mode</dt>
          <dd>{safeDisplayText(compat.mode)}</dd>
        </div>
        <div>
          <dt>Endpoint</dt>
          <dd>{safeDisplayText(compat.endpoint)}</dd>
        </div>
        <div>
          <dt>Object / Type</dt>
          <dd>{formatErrorParts(compat.object, compat.type)}</dd>
        </div>
        <div>
          <dt>Request ID Header</dt>
          <dd>{formatBoolean(compat.requestIdHeaderPresent)}</dd>
        </div>
        <div>
          <dt>Response ID</dt>
          <dd>{formatBoolean(compat.responseIdPresent)}</dd>
        </div>
        <div>
          <dt>Finish Reason</dt>
          <dd>{formatBoolean(compat.finishReasonPresent)}</dd>
        </div>
        <div>
          <dt>Usage Present</dt>
          <dd>{formatBoolean(compat.usagePresent)}</dd>
        </div>
        <div>
          <dt>Usage Recorded</dt>
          <dd>{formatBoolean(compat.usageRecorded)}</dd>
        </div>
        <div>
          <dt>Choices</dt>
          <dd>{compat.choicesCount ?? "-"}</dd>
        </div>
        <div>
          <dt>Finish Reasons</dt>
          <dd>{compat.finishReasons.length > 0 ? formatList(compat.finishReasons) : "-"}</dd>
        </div>
        <div>
          <dt>Stream Done</dt>
          <dd>{formatBoolean(compat.doneSent)}</dd>
        </div>
        <div>
          <dt>Final Chunk</dt>
          <dd>{safeDisplayText(compat.finalChunk)}</dd>
        </div>
        <div>
          <dt>Response Hash</dt>
          <dd>{safeDisplayText(compat.responseBodyHash)}</dd>
        </div>
        <div>
          <dt>Contract</dt>
          <dd>{safeDisplayText(compat.schema)}</dd>
        </div>
      </dl>
    </article>
  );
}

function openAiCompatProjection(log: RequestLogSummary) {
  const raw = log.openai_compat;
  const mode = raw?.mode ?? (log.stream_end_reason || log.partial_sent ? "stream" : "non_stream");

  return {
    choicesCount: raw?.choices_count ?? null,
    doneSent: raw?.done_sent ?? (mode === "stream" && log.stream_end_reason ? log.stream_end_reason === "completed" : null),
    endpoint: raw?.endpoint ?? null,
    finalChunk: raw?.final_chunk ?? log.stream_end_reason ?? null,
    finishReasonPresent: raw?.finish_reason_present ?? false,
    finishReasons: Array.isArray(raw?.finish_reasons)
      ? raw.finish_reasons.filter((value): value is string => typeof value === "string" && value.trim().length > 0)
      : [],
    mode,
    object: raw?.object ?? null,
    requestIdHeaderPresent: raw?.request_id_header_present ?? Boolean(raw?.x_request_id),
    responseBodyHash: raw?.response_body_hash ?? log.response_body_hash ?? null,
    responseIdPresent: raw?.response_id_present ?? Boolean(raw?.response_id),
    schema: raw?.schema ?? "gateway_openai_compat_projection_v1",
    status: raw?.status ?? (mode === "stream" ? "config-needed" : "not_recorded"),
    type: raw?.type ?? null,
    usagePresent: raw?.usage_present ?? raw?.provider_usage_present ?? null,
    usageRecorded: raw?.usage_recorded ?? (log.input_tokens > 0 || log.output_tokens > 0),
  };
}

function StreamFinalizerPanel({ log }: { log: RequestLogSummary }) {
  const finalizer = streamFinalizerProjection(log);

  return (
    <article className="admin-panel">
      <SectionHeader
        title="流式收尾"
        description={finalizer.status === "not_recorded" ? "非流式或未记录" : safeDisplayText(finalizer.status)}
      />

      <dl className="detail-list detail-list--three">
        <div>
          <dt>Partial Sent</dt>
          <dd>{formatBoolean(finalizer.partialSent)}</dd>
        </div>
        <div>
          <dt>End Reason</dt>
          <dd>{safeDisplayText(finalizer.endReason)}</dd>
        </div>
        <div>
          <dt>TTFT</dt>
          <dd>{formatMilliseconds(finalizer.ttftMs)}</dd>
        </div>
        <div>
          <dt>Usage Observed</dt>
          <dd>{formatBoolean(finalizer.usageObserved)}</dd>
        </div>
        <div>
          <dt>Usage Recorded</dt>
          <dd>{formatBoolean(finalizer.usageRecorded)}</dd>
        </div>
        <div>
          <dt>Billing Eligible</dt>
          <dd>{formatBoolean(finalizer.billingEligible)}</dd>
        </div>
        <div>
          <dt>Reserve Release</dt>
          <dd>{safeDisplayText(finalizer.reserveReleaseReason)}</dd>
        </div>
        <div>
          <dt>Concurrency Release</dt>
          <dd>{safeDisplayText(finalizer.concurrencyRelease)}</dd>
        </div>
        <div>
          <dt>Contract</dt>
          <dd>{safeDisplayText(finalizer.schema)}</dd>
        </div>
      </dl>
    </article>
  );
}

function streamFinalizerProjection(log: RequestLogSummary) {
  const raw = log.stream_finalizer;

  return {
    billingEligible: raw?.billing_eligible ?? null,
    concurrencyRelease: raw?.concurrency_release ?? null,
    endReason: raw?.end_reason ?? log.stream_end_reason ?? null,
    partialSent: raw?.partial_sent ?? log.partial_sent,
    reserveReleaseReason: raw?.reserve_release_reason ?? null,
    schema: raw?.schema ?? "gateway_stream_finalizer_projection_v1",
    status: raw?.status ?? (log.stream_end_reason || log.partial_sent ? "config-needed" : "not_recorded"),
    ttftMs: raw?.ttft_ms ?? log.ttft_ms ?? null,
    usageObserved: raw?.usage_observed ?? null,
    usageRecorded: raw?.usage_recorded ?? null,
  };
}

function downloadTextFile(filename: string, content: string, type: string) {
  const blob = new Blob([content], { type });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = filename;
  document.body.appendChild(anchor);
  anchor.click();
  document.body.removeChild(anchor);
  URL.revokeObjectURL(url);
}

function dateStamp(): string {
  return new Date().toISOString().slice(0, 10);
}

function downloadLocalRequestLogsCsv(logs: RequestLogSummary[]) {
  downloadTextFile(
    `ai-gateway-request-logs-local-${dateStamp()}.csv`,
    requestLogsToSafeCsv(logs),
    "text/csv;charset=utf-8",
  );
}

function requestLogsToSafeCsv(logs: RequestLogSummary[]): string {
  const getters: Record<
    AdminRequestLogsExportCsvColumn,
    (log: RequestLogSummary) => string | number | boolean | null | undefined
  > = {
    api_key_profile_id: (log) => log.api_key_profile_id,
    canonical_model_id: (log) => log.canonical_model_id,
    channel_id: (log) => log.resolved_channel_id,
    client_request_id: (log) => log.client_request_id,
    completed_at: (log) => log.completed_at,
    created_at: (log) => log.created_at,
    currency: (log) => log.currency,
    error_code: (log) => log.error_code,
    error_owner: (log) => log.error_owner,
    final_cost: (log) => log.final_cost,
    http_status: (log) => log.http_status,
    input_tokens: (log) => log.input_tokens,
    latency_ms: (log) => log.latency_ms,
    output_tokens: (log) => log.output_tokens,
    redaction_status: (log) => log.redaction_status,
    request_id: (log) => log.id,
    requested_model: (log) => log.requested_model,
    status: (log) => log.status,
    stream: formatStreamStatus,
    trace_id: (log) => log.trace_id,
    ttft_ms: (log) => log.ttft_ms,
    virtual_key_id: (log) => log.virtual_key_id,
  };
  const columns = adminRequestLogsExportCsvContract.allowed_columns.map((column) => [column, getters[column]] as const);
  const rows = logs.map((log) => columns.map(([, getter]) => csvCell(getter(log))).join(","));

  return [columns.map(([header]) => header).join(","), ...rows].join("\n");
}

function csvCell(value: string | number | boolean | null | undefined): string {
  const safeValue = safeDisplayText(value);
  const escaped = safeValue.replace(/"/g, "\"\"");

  return /[",\n\r]/.test(escaped) ? `"${escaped}"` : escaped;
}

function isRequestLogExportUnavailable(error: unknown): boolean {
  if (!(error instanceof ApiClientError)) {
    return false;
  }

  return (
    error.status === 404 ||
    error.status === 405 ||
    error.status === 501 ||
    error.code === "network_error" ||
    error.code === "request_timeout" ||
    error.code === "not_found" ||
    error.code === "not_implemented" ||
    error.code === "route_not_found"
  );
}

function requestLogExportUnavailableReason(error: unknown): string {
  if (!(error instanceof ApiClientError)) {
    return "unavailable";
  }

  return error.code ?? (error.status ? `http_${error.status}` : "unavailable");
}

function MetricCard({ label, value }: { label: string; value: string }) {
  return (
    <article className="request-detail-summary__item">
      <span>{label}</span>
      <strong>{value}</strong>
    </article>
  );
}


