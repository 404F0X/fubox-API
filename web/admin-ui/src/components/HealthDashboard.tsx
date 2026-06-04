import { FormEvent, useEffect, useRef, useState } from "react";
import {
  getProviderHealthSummary,
  type HealthSummary,
  type HealthSummaryFilters,
  type HealthSummaryRecentStats,
  type ProbeResult,
} from "../api/client";
import { errorMessage, safeFieldValue } from "./adminUtils";
import { RefreshCw, RotateCcw } from "./icons";
import { StatusPill } from "./StatusPill";

type Props = {
  canRequestRecovery: boolean;
  healthSummary: HealthSummary | null;
  healthSummaryError: string | null;
  lastChecked: string | null;
  loading: boolean;
  onRecoveryRequest: (entityId: string) => void;
  recoveryErrors: Record<string, string>;
  onRefresh: () => void;
  recoveryRequests: Record<string, "pending" | "succeeded" | "failed">;
  results: ProbeResult[];
};

type HealthRow = {
  id: string;
  name: string;
  recoverable: boolean;
  score: string;
  scope: string;
  signal: string;
  status: ProbeResult["status"];
};

type MatrixScope = "all" | "Provider" | "Channel" | "Provider key" | "Model";
type AutoRefreshSeconds = 0 | 30 | 60;
type SummaryMode = "parent" | "local";

const healthWindowOptions = [
  { label: "15m", value: 15 },
  { label: "1h", value: 60 },
  { label: "6h", value: 360 },
  { label: "24h", value: 1440 },
];

const sampleLimitOptions = [100, 500, 1000];

const matrixScopes: MatrixScope[] = ["all", "Provider", "Channel", "Provider key", "Model"];

const autoRefreshOptions: Array<{ label: string; value: AutoRefreshSeconds }> = [
  { label: "Off", value: 0 },
  { label: "30s", value: 30 },
  { label: "60s", value: 60 },
];

const defaultHealthSummaryFilters = {
  window_minutes: 60,
  sample_limit: 500,
} satisfies HealthSummaryFilters;

export function HealthDashboard({
  canRequestRecovery,
  healthSummary,
  healthSummaryError,
  lastChecked,
  loading,
  onRecoveryRequest,
  recoveryErrors,
  onRefresh,
  recoveryRequests,
  results,
}: Props) {
  const requestSeq = useRef(0);
  const [autoRefreshSeconds, setAutoRefreshSeconds] = useState<AutoRefreshSeconds>(0);
  const [filters, setFilters] = useState<HealthSummaryFilters>(defaultHealthSummaryFilters);
  const [matrixQuery, setMatrixQuery] = useState("");
  const [matrixScope, setMatrixScope] = useState<MatrixScope>("all");
  const [summaryMode, setSummaryMode] = useState<SummaryMode>("parent");
  const [summaryErrorOverride, setSummaryErrorOverride] = useState<string | null>(null);
  const [summaryLoading, setSummaryLoading] = useState(false);
  const [summaryOverride, setSummaryOverride] = useState<HealthSummary | null>(null);
  const effectiveHealthSummary = summaryMode === "local" ? summaryOverride : healthSummary;
  const effectiveHealthSummaryError = summaryMode === "local" ? summaryErrorOverride : healthSummaryError;
  const controlsLoading = loading || summaryLoading;
  const online = results.filter((result) => result.status === "online").length;
  const serviceHealthScore = results.length > 0 ? Math.round((online / results.length) * 100) : null;
  const routingHealthScore = routeHealthScore(effectiveHealthSummary);
  const windowSuccessRate = successRateText(effectiveHealthSummary?.recent_window.success_rate);
  const windowLabel = healthWindowLabel(effectiveHealthSummary);
  const allRows = healthRows(effectiveHealthSummary);
  const rows = filterHealthRows(allRows, matrixScope, matrixQuery);

  function updateFilters(nextFilters: HealthSummaryFilters) {
    setFilters(nextFilters);
  }

  async function loadSummary(nextFilters: HealthSummaryFilters) {
    const nextRequestSeq = requestSeq.current + 1;
    requestSeq.current = nextRequestSeq;
    setSummaryMode("local");
    setSummaryErrorOverride(null);
    setSummaryOverride(null);
    setSummaryLoading(true);

    try {
      const nextSummary = await getProviderHealthSummary(nextFilters);

      if (requestSeq.current === nextRequestSeq) {
        setSummaryOverride(nextSummary);
        setSummaryErrorOverride(null);
      }
    } catch (requestError) {
      if (requestSeq.current === nextRequestSeq) {
        setSummaryErrorOverride(errorMessage(requestError));
        setSummaryOverride(null);
      }
    } finally {
      if (requestSeq.current === nextRequestSeq) {
        setSummaryLoading(false);
      }
    }
  }

  function handleRefreshSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    void loadSummary(filters);
  }

  useEffect(() => {
    requestSeq.current += 1;
    setSummaryMode("parent");
    setSummaryErrorOverride(null);
    setSummaryLoading(false);
    setSummaryOverride(null);
  }, [healthSummary, healthSummaryError]);

  useEffect(() => {
    if (autoRefreshSeconds === 0) {
      return undefined;
    }

    const intervalId = window.setInterval(() => {
      void loadSummary(filters);
    }, autoRefreshSeconds * 1000);

    return () => window.clearInterval(intervalId);
  }, [autoRefreshSeconds, filters.sample_limit, filters.window_minutes]);

  return (
    <div className="dashboard-stack">
      <section className="summary-grid" aria-label="Health overview">
        <article className="metric-card">
          <span>Routing health</span>
          <strong>{routingHealthScore === null ? "No signal" : `${routingHealthScore}%`}</strong>
          <small>
            {effectiveHealthSummary
              ? `${effectiveHealthSummary.recent_window.sample_count} recent requests`
              : "Summary unavailable"}
          </small>
        </article>
        <article className="metric-card">
          <span>Window success</span>
          <strong>{windowSuccessRate}</strong>
          <small>
            {effectiveHealthSummary
              ? `${effectiveHealthSummary.recent_window.sample_count} requests / ${windowLabel}`
              : effectiveHealthSummaryError ?? "Waiting"}
          </small>
        </article>
        <article className="metric-card">
          <span>Service probes</span>
          <strong>{serviceHealthScore === null ? "Checking" : `${serviceHealthScore}%`}</strong>
          <small>{lastChecked ?? "Not checked"}</small>
        </article>
        <article className="metric-card">
          <span>Providers</span>
          <strong>{effectiveHealthSummary?.totals.providers ?? "-"}</strong>
          <small>
            {effectiveHealthSummary
              ? `${effectiveHealthSummary.totals.channels} channels`
              : effectiveHealthSummaryError ?? "Waiting"}
          </small>
        </article>
      </section>

      <section className="admin-panel" aria-label="Health summary controls">
        <div className="section-heading">
          <div>
            <h2>Health controls</h2>
            <p>
              {effectiveHealthSummary
                ? `${effectiveHealthSummary.recent_window.sample_count} of ${effectiveHealthSummary.recent_window.sample_limit} samples / ${windowLabel}`
                : "Choose a summary window and sample limit."}
            </p>
          </div>
        </div>

        <form className="health-controls" onSubmit={handleRefreshSubmit}>
          <label className="field">
            Window
            <select
              value={String(filters.window_minutes ?? 60)}
              onChange={(event) =>
                updateFilters({ ...filters, window_minutes: Number.parseInt(event.currentTarget.value, 10) })
              }
            >
              {healthWindowOptions.map((option) => (
                <option key={option.value} value={option.value}>
                  {option.label}
                </option>
              ))}
            </select>
          </label>

          <label className="field">
            Sample limit
            <select
              value={String(filters.sample_limit ?? 500)}
              onChange={(event) =>
                updateFilters({ ...filters, sample_limit: Number.parseInt(event.currentTarget.value, 10) })
              }
            >
              {sampleLimitOptions.map((limit) => (
                <option key={limit} value={limit}>
                  {limit}
                </option>
              ))}
            </select>
          </label>

          <label className="field">
            Scope
            <select value={matrixScope} onChange={(event) => setMatrixScope(event.currentTarget.value as MatrixScope)}>
              {matrixScopes.map((scope) => (
                <option key={scope} value={scope}>
                  {scope === "all" ? "All scopes" : scope}
                </option>
              ))}
            </select>
          </label>

          <label className="field">
            Auto refresh
            <select
              value={String(autoRefreshSeconds)}
              onChange={(event) =>
                setAutoRefreshSeconds(Number.parseInt(event.currentTarget.value, 10) as AutoRefreshSeconds)
              }
            >
              {autoRefreshOptions.map((option) => (
                <option key={option.value} value={option.value}>
                  {option.label}
                </option>
              ))}
            </select>
          </label>

          <label className="field">
            Matrix search
            <input
              value={matrixQuery}
              onChange={(event) => setMatrixQuery(event.currentTarget.value)}
              placeholder="name, status, route"
            />
          </label>

          <button className="secondary-button primary-button--inline" type="submit" disabled={controlsLoading}>
            <RefreshCw aria-hidden="true" size={18} className={controlsLoading ? "spin" : undefined} />
            Refresh summary
          </button>
        </form>
      </section>

      <section aria-label="Service probes">
        <div className="section-heading">
          <div>
            <h2>Service probes</h2>
            <p>{lastChecked ? `Last checked ${lastChecked}` : "Checking gateway services"}</p>
          </div>
          <button className="secondary-button" type="button" onClick={onRefresh} disabled={loading}>
            <RefreshCw aria-hidden="true" size={18} className={loading ? "spin" : undefined} />
            Refresh
          </button>
        </div>

        <div className="status-grid">
          {results.length > 0 ? (
            results.map((result) => (
              <article className="status-card" key={result.name}>
                <div>
                  <h3>{result.name}</h3>
                  <p>{result.detail}</p>
                </div>
                <StatusPill status={result.status} />
              </article>
            ))
          ) : (
            <article className="status-card">
              <div>
                <h3>Service probes</h3>
                <p>{loading ? "Checking configured endpoints." : "No probes returned."}</p>
              </div>
              <StatusPill status="pending" />
            </article>
          )}
        </div>
      </section>

      <section className="health-matrix" aria-label="Provider channel key model health">
        <div className="section-heading">
          <div>
            <h2>Health matrix</h2>
            <p>
              {effectiveHealthSummaryError
                ? effectiveHealthSummaryError
                : `${rows.length} of ${allRows.length} rows shown across providers, channels, keys, and models.`}
            </p>
          </div>
        </div>

        <div className="health-table-wrap">
          <table className="health-table">
            <thead>
              <tr>
                <th>Scope</th>
                <th>Name</th>
                <th>Status</th>
                <th>Score</th>
                <th>Signal</th>
                <th>Recovery</th>
              </tr>
            </thead>
            <tbody>
              {rows.length > 0 ? (
                rows.map((row) => {
                  const recoveryState = recoveryRequests[row.id];
                  const recoveryError = recoveryErrors[row.id];
                  const recoveryDisabled = recoveryState === "pending" || recoveryState === "succeeded";
                  const showRecoveryAction = canRequestRecovery && row.recoverable;

                  return (
                    <tr key={`${row.scope}-${row.id}`}>
                      <td>{row.scope}</td>
                      <td>
                        <strong>{row.name}</strong>
                        <span>{shortId(row.id)}</span>
                      </td>
                      <td>
                        <StatusPill status={row.status} />
                      </td>
                      <td>{row.score}</td>
                      <td>{row.signal}</td>
                      <td>
                        {showRecoveryAction ? (
                          <div className="table-action-stack">
                            <button
                              aria-label={`Request recovery for ${row.name}`}
                              className="table-action"
                              disabled={recoveryDisabled}
                              onClick={() => onRecoveryRequest(row.id)}
                              type="button"
                            >
                              <RotateCcw aria-hidden="true" size={15} />
                              {recoveryButtonLabel(recoveryState)}
                            </button>
                            {recoveryError ? <small>{recoveryError}</small> : null}
                          </div>
                        ) : (
                          <span className="muted-copy">{row.recoverable ? "No permission" : "-"}</span>
                        )}
                      </td>
                    </tr>
                  );
                })
              ) : (
                <tr>
                  <td colSpan={6}>
                    {controlsLoading
                      ? "Loading health summary."
                      : allRows.length > 0
                        ? "No rows match the current scan."
                        : "No health summary returned."}
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </section>
    </div>
  );
}

function healthRows(summary: HealthSummary | null): HealthRow[] {
  if (!summary) {
    return [];
  }

  return [
    ...summary.providers.map((provider) => ({
      id: provider.id,
      name: safeFieldValue(provider.name),
      recoverable: false,
      scope: "Provider",
      score: scoreText(provider.health_score),
      signal: signalText(provider.status, provider.recent),
      status: pillStatus(provider.health_state),
    })),
    ...summary.channels.map((channel) => ({
      id: channel.id,
      name: safeFieldValue(channel.name),
      recoverable: false,
      scope: "Channel",
      score: scoreText(channel.health_score),
      signal: signalText(channel.status, channel.recent),
      status: pillStatus(channel.health_state),
    })),
    ...summary.provider_keys.map((key) => ({
      id: key.id,
      name: safeFieldValue(key.key_alias),
      recoverable: isProviderKeyRecoverable(key.status),
      scope: "Provider key",
      score: scoreText(key.health_score),
      signal: signalText(key.status, key.recent, key.configured_last_error_code),
      status: pillStatus(key.health_state),
    })),
    ...summary.models.map((model) => ({
      id: model.id,
      name: safeFieldValue(model.display_name),
      recoverable: false,
      scope: "Model",
      score: `${model.routable_channel_count} routes`,
      signal: signalText(model.routing_state, model.recent),
      status: modelPillStatus(model.routing_state),
    })),
  ];
}

function filterHealthRows(rows: HealthRow[], scope: MatrixScope, query: string): HealthRow[] {
  const normalizedQuery = query.trim().toLowerCase();

  return rows.filter((row) => {
    const scopeMatches = scope === "all" || row.scope === scope;
    if (!scopeMatches) {
      return false;
    }

    if (!normalizedQuery) {
      return true;
    }

    return [row.scope, row.name, row.signal, row.score, row.id].some((value) =>
      value.toLowerCase().includes(normalizedQuery),
    );
  });
}

function modelPillStatus(routingState: string): ProbeResult["status"] {
  if (routingState === "routable") {
    return "online";
  }
  if (routingState === "disabled") {
    return "offline";
  }

  return "pending";
}

function routeHealthScore(summary: HealthSummary | null): number | null {
  const scores = healthRows(summary)
    .map((row) => row.score)
    .filter((score) => score.endsWith("%"))
    .map((score) => Number(score.slice(0, -1)))
    .filter(Number.isFinite);

  if (scores.length === 0) {
    return null;
  }

  return Math.round(scores.reduce((total, score) => total + score, 0) / scores.length);
}

function scoreText(score: number | null | undefined): string {
  if (typeof score !== "number" || !Number.isFinite(score)) {
    return "-";
  }

  return `${Math.round(score * 100)}%`;
}

function signalText(status: string, recent: HealthSummaryRecentStats, configuredError?: string | null): string {
  const safeStatus = safeFieldValue(status);
  const recentError = safeFieldValue(recent.last_error?.code ?? configuredError);

  if (typeof recent.success_rate === "number" && Number.isFinite(recent.success_rate)) {
    return `${safeStatus} / ${successRateText(recent.success_rate)} success`;
  }
  if (recentError !== "-") {
    return `${safeStatus} / ${recentError}`;
  }
  if (recent.error_count > 0) {
    return `${safeStatus} / ${recent.error_count} errors`;
  }

  return safeStatus;
}

function successRateText(rate: number | null | undefined): string {
  if (typeof rate !== "number" || !Number.isFinite(rate)) {
    return "No signal";
  }

  return `${Math.round(rate * 100)}%`;
}

function healthWindowLabel(summary: HealthSummary | null): string {
  const minutes = summary?.recent_window.window?.minutes ?? summary?.recent_window.window_minutes;

  if (typeof minutes !== "number" || !Number.isFinite(minutes) || minutes <= 0) {
    return "configured window";
  }
  if (minutes % 60 === 0) {
    const hours = minutes / 60;
    return `${hours}h`;
  }

  return `${minutes}m`;
}

function pillStatus(healthState: string): ProbeResult["status"] {
  if (healthState === "healthy") {
    return "online";
  }
  if (healthState === "no_signal") {
    return "pending";
  }

  return "offline";
}

function isProviderKeyRecoverable(status: string): boolean {
  return ["cooldown", "degraded", "recovery_probe"].includes(status);
}

function recoveryButtonLabel(state: "pending" | "succeeded" | "failed" | undefined): string {
  if (state === "pending") {
    return "Pending";
  }
  if (state === "succeeded") {
    return "Requested";
  }
  if (state === "failed") {
    return "Retry";
  }

  return "Request";
}

function shortId(id: string): string {
  return id.length > 12 ? id.slice(0, 8) : id;
}
