import type { HealthSummary, HealthSummaryRecentStats, ProbeResult } from "../api/client";
import { RefreshCw, RotateCcw } from "./icons";
import { StatusPill } from "./StatusPill";

type Props = {
  healthSummary: HealthSummary | null;
  healthSummaryError: string | null;
  lastChecked: string | null;
  loading: boolean;
  onRecoveryRequest: (entityId: string) => void;
  onRefresh: () => void;
  recoveryRequests: string[];
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

export function HealthDashboard({
  healthSummary,
  healthSummaryError,
  lastChecked,
  loading,
  onRecoveryRequest,
  onRefresh,
  recoveryRequests,
  results,
}: Props) {
  const online = results.filter((result) => result.status === "online").length;
  const serviceHealthScore = results.length > 0 ? Math.round((online / results.length) * 100) : null;
  const routingHealthScore = routeHealthScore(healthSummary);
  const rows = healthRows(healthSummary);

  return (
    <div className="dashboard-stack">
      <section className="summary-grid" aria-label="Health overview">
        <article className="metric-card">
          <span>Routing health</span>
          <strong>{routingHealthScore === null ? "No signal" : `${routingHealthScore}%`}</strong>
          <small>{healthSummary ? `${healthSummary.recent_window.sample_count} recent requests` : "Summary unavailable"}</small>
        </article>
        <article className="metric-card">
          <span>Service probes</span>
          <strong>{serviceHealthScore === null ? "Checking" : `${serviceHealthScore}%`}</strong>
          <small>{lastChecked ?? "Not checked"}</small>
        </article>
        <article className="metric-card">
          <span>Providers</span>
          <strong>{healthSummary?.totals.providers ?? "-"}</strong>
          <small>{healthSummary ? `${healthSummary.totals.channels} channels` : healthSummaryError ?? "Waiting"}</small>
        </article>
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
            {healthSummaryError ? <p>{healthSummaryError}</p> : null}
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
                  const recoveryRequested = recoveryRequests.includes(row.id);

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
                        {row.recoverable ? (
                          <button
                            aria-label={`Request recovery for ${row.name}`}
                            className="table-action"
                            disabled={recoveryRequested}
                            onClick={() => onRecoveryRequest(row.id)}
                            type="button"
                          >
                            <RotateCcw aria-hidden="true" size={15} />
                            {recoveryRequested ? "Requested" : "Request"}
                          </button>
                        ) : (
                          "-"
                        )}
                      </td>
                    </tr>
                  );
                })
              ) : (
                <tr>
                  <td colSpan={6}>{loading ? "Loading health summary." : "No health summary returned."}</td>
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
      name: provider.name,
      recoverable: false,
      scope: "Provider",
      score: scoreText(provider.health_score),
      signal: signalText(provider.status, provider.recent),
      status: pillStatus(provider.health_state),
    })),
    ...summary.channels.map((channel) => ({
      id: channel.id,
      name: channel.name,
      recoverable: isRecoverable(channel.status, channel.health_state),
      scope: "Channel",
      score: scoreText(channel.health_score),
      signal: signalText(channel.status, channel.recent),
      status: pillStatus(channel.health_state),
    })),
    ...summary.provider_keys.map((key) => ({
      id: key.id,
      name: key.key_alias,
      recoverable: isRecoverable(key.status, key.health_state),
      scope: "Provider key",
      score: scoreText(key.health_score),
      signal: signalText(key.status, key.recent, key.configured_last_error_code),
      status: pillStatus(key.health_state),
    })),
    ...summary.models.map((model) => ({
      id: model.id,
      name: model.display_name,
      recoverable: false,
      scope: "Model",
      score: `${model.routable_channel_count} routes`,
      signal: signalText(model.routing_state, model.recent),
      status: modelPillStatus(model.routing_state),
    })),
  ];
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
  const recentError = recent.last_error?.code ?? configuredError;

  if (recentError) {
    return `${status} / ${recentError}`;
  }
  if (recent.error_count > 0) {
    return `${status} / ${recent.error_count} errors`;
  }

  return status;
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

function isRecoverable(status: string, healthState: string): boolean {
  return (
    healthState === "degraded" ||
    healthState === "unhealthy" ||
    ["auth_failed", "cooldown", "degraded", "quota_exhausted", "recovery_probe"].includes(status)
  );
}

function shortId(id: string): string {
  return id.length > 12 ? id.slice(0, 8) : id;
}
