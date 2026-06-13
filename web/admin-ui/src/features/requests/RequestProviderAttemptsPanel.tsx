import type { RequestLogDetail } from "../../api/client";
import { DataTable } from "../../design/DataTable";
import { SectionHeader } from "../../design/SectionHeader";
import { StateChip, safeFieldValue, shortId } from "../../components/adminUtils";

type ProviderAttempt = RequestLogDetail["provider_attempts"][number];

type RequestProviderAttemptsPanelProps = {
  attempts: ProviderAttempt[];
  explainability?: RequestLogDetail["provider_attempts_explainability"] | null;
};

export function RequestProviderAttemptsPanel({ attempts, explainability }: RequestProviderAttemptsPanelProps) {
  return (
    <article className="admin-panel detail-panel--wide">
      <SectionHeader
        title="供应商尝试"
        description={explainability?.safe_next_action ?? `已记录 ${attempts.length} 次尝试。`}
      />

      {explainability ? (
        <dl className="detail-list detail-list--three">
          <div>
            <dt>Attempt Count</dt>
            <dd>{explainability.attempt_count}</dd>
          </div>
          <div>
            <dt>Selected</dt>
            <dd>{formatAttemptNo(explainability.selected_attempt_no)}</dd>
          </div>
          <div>
            <dt>Fallbacks</dt>
            <dd>{explainability.fallback_attempt_count}</dd>
          </div>
          <div>
            <dt>Retryable</dt>
            <dd>{explainability.retryable_attempt_count}</dd>
          </div>
          <div>
            <dt>Terminal</dt>
            <dd>{safeFieldValue(explainability.provider_channel_status.terminal_status)}</dd>
          </div>
          <div>
            <dt>Provider</dt>
            <dd>{safeShortId(explainability.provider_channel_status.selected_provider_id)}</dd>
          </div>
          <div>
            <dt>Channel</dt>
            <dd>{safeShortId(explainability.provider_channel_status.selected_channel_id)}</dd>
          </div>
          <div>
            <dt>Latency</dt>
            <dd>{formatBoolean(explainability.latency_observed)}</dd>
          </div>
          <div>
            <dt>First Token</dt>
            <dd>{formatBoolean(explainability.first_token_observed)}</dd>
          </div>
        </dl>
      ) : null}

      <DataTable aria-label="供应商尝试" className="admin-table admin-table--attempts">
        <thead>
          <tr>
            <th>序号</th>
            <th>状态</th>
            <th>供应商</th>
            <th>通道</th>
            <th>模型</th>
            <th>耗时</th>
            <th>错误</th>
          </tr>
        </thead>
        <tbody>
          {attempts.length > 0 ? (
            attempts.map((attempt) => (
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
              <td colSpan={7}>此请求没有记录供应商尝试。</td>
            </tr>
          )}
        </tbody>
      </DataTable>
    </article>
  );
}

function formatAttemptNo(value: number | null | undefined): string {
  return typeof value === "number" ? `#${value}` : "-";
}

function formatBoolean(value: boolean | null | undefined): string {
  return value ? "是" : "否";
}

function formatErrorParts(...parts: Array<unknown>): string {
  const safeParts = parts
    .map((part) => safeFieldValue(part))
    .filter((part) => part !== "-");

  return safeParts.length > 0 ? safeParts.join(" / ") : "-";
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

function formatMs(value: number | null | undefined): string {
  return typeof value === "number" ? `${value} ms` : "-";
}
