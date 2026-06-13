import type { RequestLedgerSummary, RequestLogDetail, RequestTraceSummary } from "../../api/client";
import { StateChip, safeFieldValue, shortId } from "../../components/adminUtils";
import { DataTable } from "../../design/DataTable";
import { SectionHeader } from "../../design/SectionHeader";

export function TraceSummaryPanel({ summary }: { summary: RequestTraceSummary }) {
  const ledger = normalizeLedgerSummary(summary.ledger);

  return (
    <>
      <section className="feature-stats" aria-label="Trace 摘要指标">
        <MetricCard label="请求数" tone="neutral" value={summary.request_count} />
        <MetricCard label="错误数" tone={summary.error_count > 0 ? "warn" : "good"} value={summary.error_count} />
        <MetricCard label="输入 Token" tone="neutral" value={summary.total_input_tokens} />
        <MetricCard label="输出 Token" tone="neutral" value={summary.total_output_tokens} />
      </section>

      <section className="admin-panel" aria-label="Trace 摘要">
        <SectionHeader title="Trace 摘要" description={safeFieldValue(summary.trace_id)} />

        <dl className="detail-list">
          <div>
            <dt>行数</dt>
            <dd>
              返回 {summary.requests.length} 条
              {summary.limit_reached ? ` / 上限 ${summary.limit}` : ""}
            </dd>
          </div>
          <div>
            <dt>币种</dt>
            <dd>{formatList(summary.currencies)}</dd>
          </div>
          <div>
            <dt>首个请求</dt>
            <dd>{formatDateField(summary.first_request_at)}</dd>
          </div>
          <div>
            <dt>最后请求</dt>
            <dd>{formatDateField(summary.last_request_at)}</dd>
          </div>
          <div>
            <dt>最后错误</dt>
            <dd>{formatLastError(summary.last_error)}</dd>
          </div>
          <div>
            <dt>账本行</dt>
            <dd>
              返回 {ledger.returned_count} 条
              {ledger.limit_reached ? ` / 上限 ${ledger.limit}` : ""}
            </dd>
          </div>
          <div>
            <dt>账本币种</dt>
            <dd>{formatList(ledger.currencies)}</dd>
          </div>
        </dl>

        <LedgerRowsTable emptyMessage="返回的 Trace 行没有关联账本条目。" summary={ledger} />
      </section>
    </>
  );
}

export function LedgerSummaryPanel({
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
      <SectionHeader title={title} description={`返回 ${summary.returned_count} 条，覆盖 ${summary.request_count} 个请求。`} />
      <LedgerRowsTable emptyMessage={emptyMessage} summary={summary} />
    </article>
  );
}

export function normalizeLedgerSummary(summary: RequestLedgerSummary | null | undefined): RequestLedgerSummary {
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
    <DataTable aria-label="账本条目" className="admin-table admin-table--ledger">
      <thead>
        <tr>
          <th>Ledger</th>
          <th>Wallet</th>
          <th>类型</th>
          <th>状态</th>
          <th>费用</th>
          <th>余额前后</th>
          <th>Voucher / Order / Payment</th>
          <th>发生时间</th>
        </tr>
      </thead>
      <tbody>
        {summary.entries.length > 0 ? (
          summary.entries.map((entry, index) => (
            <tr key={`${entry.id ?? entry.request_id ?? "request"}-${entry.entry_type}-${entry.occurred_at}-${index}`}>
              <td>{safeShortId(entry.id ?? entry.refs?.ledger_entry_id)}</td>
              <td>{safeShortId(entry.wallet_id ?? entry.refs?.wallet_id)}</td>
              <td>{formatLedgerStatus(entry.entry_type)}</td>
              <td>
                <StateChip status={safeStatus(entry.status)} />
              </td>
              <td>
                {safeFieldValue(entry.amount)} {safeFieldValue(entry.currency)}
              </td>
              <td>{formatBalanceWindow(entry)}</td>
              <td>{formatLedgerRefs(entry)}</td>
              <td>{formatDate(entry.occurred_at)}</td>
            </tr>
          ))
        ) : (
          <tr>
            <td colSpan={8}>{emptyMessage || "no-ledger"}</td>
          </tr>
        )}
      </tbody>
    </DataTable>
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

function formatBalanceWindow(entry: RequestLedgerSummary["entries"][number]): string {
  const before = safeFieldValue(entry.balance?.before);
  const after = safeFieldValue(entry.balance?.after);

  if (before !== "-" || after !== "-") {
    return `${before} -> ${after} ${safeFieldValue(entry.balance?.currency ?? entry.currency)}`;
  }

  const status = safeFieldValue(entry.balance?.status ?? (entry.wallet_id || entry.refs?.wallet_id ? "config-needed" : "no-ledger"));
  const reason = safeFieldValue(entry.balance?.reason);

  return reason === "-" ? status : `${status}: ${reason}`;
}

function formatLedgerRefs(entry: RequestLedgerSummary["entries"][number]): string {
  const refs = entry.refs;

  if (!refs) {
    return "config-needed";
  }

  const parts = [
    refPart("voucher", refs.voucher_id),
    refPart("redeem", refs.voucher_redemption_id),
    refPart("order", refs.order_id),
    refPart("intent", refs.payment_intent_id),
    refPart("capture", refs.payment_capture_id),
    refPart("invoice", refs.invoice_id),
    refPart("refund", refs.refund_id),
    refPart("grant", refs.credit_grant_id),
    refPart("related", refs.related_ledger_entry_id ?? entry.related_ledger_entry_id),
    refPart("price", refs.price_version_id ?? entry.price_version_id),
  ].filter((part): part is string => Boolean(part));

  return parts.length > 0 ? parts.join(" / ") : "no-ledger";
}

function refPart(label: string, value: string | null | undefined): string | null {
  const safeValue = safeShortId(value);

  return safeValue === "-" ? null : `${label} ${safeValue}`;
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
