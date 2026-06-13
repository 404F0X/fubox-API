import { FormEvent, useEffect, useRef, useState } from "react";
import {
  listAdminWallets,
  listRequestLogs,
  type AdminWalletCreditSurface,
  getAdminSetupReadback,
  type AdminSetupReadback,
  getProviderHealthSummary,
  type HealthSummary,
  type HealthSummaryFilters,
  type HealthSummaryRecentStats,
  type ProbeResult,
  type RequestLogSummary,
} from "../../api/client";
import { ActionButton } from "../../design/ActionButton";
import { DataTable } from "../../design/DataTable";
import { EmptyState } from "../../design/EmptyState";
import { Field } from "../../design/Field";
import { SectionHeader } from "../../design/SectionHeader";
import { ProbeStatusChip, StatusChip } from "../../design/StatusChip";
import { Toolbar } from "../../design/Toolbar";
import { errorMessage, safeFieldValue } from "../../components/adminUtils";
import { formatCount, formatDateTime, formatMoney, formatTokenUsage } from "../../lib/format";
import { ArrowRight, RefreshCw, RotateCcw } from "../../components/icons";
import type { DashboardTarget } from "../../app/types";

type Props = {
  canRequestRecovery: boolean;
  healthSummary: HealthSummary | null;
  healthSummaryError: string | null;
  lastChecked: string | null;
  loading: boolean;
  onRecoveryRequest: (entityId: string) => void;
  onOpenRequestDetail: (requestId: string) => void;
  recoveryErrors: Record<string, string>;
  onSetupNavigate: (target: DashboardTarget) => void;
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
type SetupTarget = "providers" | "models" | "keys" | "requestLogs";

type DashboardOpsState = {
  error: string | null;
  loading: boolean;
  logs: RequestLogSummary[];
  setupReadback: AdminSetupReadback | null;
  wallets: AdminWalletCreditSurface[];
};

type ChannelTopRow = {
  detail: string;
  id: string;
  name: string;
  score: string;
  signal: string;
  status: ProbeResult["status"];
};

type SetupStep = {
  action: string;
  detail: string;
  evidence: string;
  label: string;
  status: ProbeResult["status"];
  target: SetupTarget;
};

const healthWindowOptions = [
  { label: "15m", value: 15 },
  { label: "1h", value: 60 },
  { label: "6h", value: 360 },
  { label: "24h", value: 1440 },
];

const sampleLimitOptions = [100, 500, 1000];

const matrixScopes: MatrixScope[] = ["all", "Provider", "Channel", "Provider key", "Model"];

const autoRefreshOptions: Array<{ label: string; value: AutoRefreshSeconds }> = [
  { label: "关闭", value: 0 },
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
  onOpenRequestDetail,
  onRecoveryRequest,
  onSetupNavigate,
  recoveryErrors,
  onRefresh,
  recoveryRequests,
  results,
}: Props) {
  const requestSeq = useRef(0);
  const opsRequestSeq = useRef(0);
  const [autoRefreshSeconds, setAutoRefreshSeconds] = useState<AutoRefreshSeconds>(0);
  const [filters, setFilters] = useState<HealthSummaryFilters>(defaultHealthSummaryFilters);
  const [matrixQuery, setMatrixQuery] = useState("");
  const [matrixScope, setMatrixScope] = useState<MatrixScope>("all");
  const [opsState, setOpsState] = useState<DashboardOpsState>({
    error: null,
    loading: true,
    logs: [],
    setupReadback: null,
    wallets: [],
  });
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
  const setupSteps = setupWizardSteps(effectiveHealthSummary, results, opsState.setupReadback);
  const requestStats = requestLogStats(opsState.logs);
  const failedRequests = recentFailedRequests(opsState.logs);
  const balanceAlert = balanceAlertText(opsState.wallets, opsState.loading, opsState.error);
  const channelTopRows = channelHealthTopRows(effectiveHealthSummary);

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

  async function loadDashboardOps() {
    const nextRequestSeq = opsRequestSeq.current + 1;
    opsRequestSeq.current = nextRequestSeq;
    setOpsState((current) => ({ ...current, error: null, loading: true }));

    const [logsResult, walletsResult, setupReadbackResult] = await Promise.allSettled([
      listRequestLogs({ limit: 50 }),
      listAdminWallets({ limit: 20 }),
      getAdminSetupReadback(),
    ]);

    if (opsRequestSeq.current !== nextRequestSeq) {
      return;
    }

    setOpsState({
      error:
        logsResult.status === "rejected"
          ? errorMessage(logsResult.reason)
          : walletsResult.status === "rejected"
            ? errorMessage(walletsResult.reason)
            : null,
      loading: false,
      logs: logsResult.status === "fulfilled" ? arrayValue<RequestLogSummary>(logsResult.value) : [],
      setupReadback: setupReadbackResult.status === "fulfilled" ? setupReadbackResult.value : null,
      wallets: walletsResult.status === "fulfilled" ? arrayValue<AdminWalletCreditSurface>(walletsResult.value) : [],
    });
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
    void loadDashboardOps();
  }, [lastChecked]);

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
      <section className="summary-grid" aria-label="Dashboard 聚合">
        <DashboardMetricButton
          label="请求数"
          value={opsState.loading ? "加载中" : formatCount(requestStats.total)}
          detail={requestStats.total > 0 ? `${failedRequests.length} 个近期失败` : opsState.error ?? "no-signal"}
          tone={failedRequests.length > 0 ? "warn" : requestStats.total > 0 ? "good" : "neutral"}
          targetLabel="打开 Requests"
          onClick={() => onSetupNavigate("requestLogs")}
        />
        <DashboardMetricButton
          label="成功率"
          value={opsState.loading ? "加载中" : requestStats.successRate}
          detail={requestStats.total > 0 ? "来自最近 50 条 request logs" : "no-signal"}
          tone={requestStats.successRatio === null ? "neutral" : requestStats.successRatio >= 0.95 ? "good" : "warn"}
          targetLabel="排查 Requests"
          onClick={() => onSetupNavigate("requestLogs")}
        />
        <DashboardMetricButton
          label="Token / 成本"
          value={requestStats.tokens}
          detail={requestStats.cost}
          tone={requestStats.total > 0 ? "neutral" : "neutral"}
          targetLabel="打开 Requests"
          onClick={() => onSetupNavigate("requestLogs")}
        />
        <DashboardMetricButton
          label="余额告警"
          value={balanceAlert.value}
          detail={balanceAlert.detail}
          tone={balanceAlert.tone}
          targetLabel="打开 Users"
          onClick={() => onSetupNavigate("users")}
        />
        <DashboardMetricButton
          label="路由健康度"
          value={routingHealthScore === null ? "无信号" : `${routingHealthScore}%`}
          detail={effectiveHealthSummary ? `${effectiveHealthSummary.recent_window.sample_count} 条近期请求` : "暂无汇总"}
          tone={routingHealthScore === null ? "neutral" : routingHealthScore >= 80 ? "good" : "warn"}
          targetLabel="打开 Routing"
          onClick={() => onSetupNavigate("routing")}
        />
        <DashboardMetricButton
          label="窗口成功率"
          value={windowSuccessRate}
          detail={
            effectiveHealthSummary
              ? `${effectiveHealthSummary.recent_window.sample_count} 条请求 / ${windowLabel}`
              : effectiveHealthSummaryError ?? "等待中"
          }
          tone={windowSuccessRate === "无信号" ? "neutral" : "good"}
          targetLabel="打开 Requests"
          onClick={() => onSetupNavigate("requestLogs")}
        />
        <DashboardMetricButton
          label="服务探针"
          value={serviceHealthScore === null ? "检查中" : `${serviceHealthScore}%`}
          detail={lastChecked ?? "未检查"}
          tone={serviceHealthScore === null ? "neutral" : serviceHealthScore >= 80 ? "good" : "warn"}
          targetLabel="刷新探针"
          onClick={onRefresh}
        />
        <DashboardMetricButton
          label="供应商"
          value={String(effectiveHealthSummary?.totals.providers ?? "-")}
          detail={
            effectiveHealthSummary
              ? `${effectiveHealthSummary.totals.channels} 个通道`
              : effectiveHealthSummaryError ?? "等待中"
          }
          tone="neutral"
          targetLabel="打开 Providers"
          onClick={() => onSetupNavigate("providers")}
        />
      </section>

      <section className="dashboard-overview-grid" aria-label="Dashboard 操作面板">
        <section className="admin-panel" aria-label="通道健康 TopN">
          <SectionHeader
            title="通道健康 TopN"
            description={channelTopRows.length > 0 ? `${channelTopRows.length} 个需关注通道` : "no-signal"}
          />
          <DataTable aria-label="通道健康 TopN" className="health-table">
            <thead>
              <tr>
                <th>通道</th>
                <th>状态</th>
                <th>分数</th>
                <th>信号</th>
              </tr>
            </thead>
            <tbody>
              {channelTopRows.length > 0 ? (
                channelTopRows.map((row) => (
                  <tr key={row.id}>
                    <td>
                      <strong>{row.name}</strong>
                      <span>{row.detail}</span>
                    </td>
                    <td>
                      <ProbeStatusChip status={row.status} />
                    </td>
                    <td>健康 {row.score}</td>
                    <td>{row.signal}</td>
                  </tr>
                ))
              ) : (
                <tr>
                  <td colSpan={4}>
                    <EmptyState title="no-signal" detail="没有通道健康样本；先配置 provider/channel/key 或运行一次 Gateway 请求。" />
                  </td>
                </tr>
              )}
            </tbody>
          </DataTable>
        </section>

        <section className="admin-panel" aria-label="最近失败请求">
          <SectionHeader
            title="最近失败请求"
            description={failedRequests.length > 0 ? "点击请求打开 detail drawer。" : opsState.error ?? "no-signal"}
          />
          <DataTable aria-label="最近失败请求" className="health-table">
            <thead>
              <tr>
                <th>请求</th>
                <th>状态</th>
                <th>模型</th>
                <th>成本</th>
                <th>时间</th>
              </tr>
            </thead>
            <tbody>
              {failedRequests.length > 0 ? (
                failedRequests.map((request) => (
                  <tr key={request.id}>
                    <td>
                      <div className="table-action-stack">
                        <ActionButton
                          aria-label={`打开请求 ${request.id}`}
                          icon={<ArrowRight aria-hidden="true" size={15} />}
                          onClick={() => onOpenRequestDetail(request.id)}
                          variant="table"
                        >
                          {shortId(request.id)}
                        </ActionButton>
                        <div className="action-row">
                          <ActionButton
                            aria-label={`查看请求 ${request.id} 的用户上下文`}
                            onClick={() => onSetupNavigate("users")}
                            variant="table"
                          >
                            Users
                          </ActionButton>
                          <ActionButton
                            aria-label={`查看请求 ${request.id} 的审计日志`}
                            onClick={() => onSetupNavigate("auditLogs")}
                            variant="table"
                          >
                            Audit
                          </ActionButton>
                        </div>
                      </div>
                      <span>{failureSummary(request)}</span>
                    </td>
                    <td>
                      <RequestStatusChip log={request} />
                    </td>
                    <td>{safeFieldValue(request.requested_model ?? request.upstream_model)}</td>
                    <td>{formatMoney(request.final_cost, request.currency)}</td>
                    <td>{formatDateTime(request.created_at)}</td>
                  </tr>
                ))
              ) : (
                <tr>
                  <td colSpan={5}>
                    <EmptyState
                      title={opsState.loading ? "正在加载 request logs" : requestStats.total > 0 ? "没有失败请求" : "no-signal"}
                      detail={requestStats.total > 0 ? "近期请求没有失败信号。" : "运行一次 Gateway 请求后刷新。"}
                    />
                  </td>
                </tr>
              )}
            </tbody>
          </DataTable>
        </section>
      </section>

      <section className="admin-panel" aria-label="Dashboard 安全操作">
        <SectionHeader
          title="安全操作"
          description="从 Dashboard 跳到用户、审计和请求排障页；只传 view target 或 request id，不携带 secret、raw payload 或 prompt。"
        />
        <div className="dashboard-action-grid">
          <DashboardAction
            detail={balanceAlert.value === "attention" ? balanceAlert.detail : "查看用户余额、API key 和 ledger 安全摘要。"}
            label="Users"
            status={balanceAlert.tone === "warn" ? "config-needed" : "ready"}
            onClick={() => onSetupNavigate("users")}
          />
          <DashboardAction
            detail={failedRequests.length > 0 ? "打开最近失败请求的 detail drawer。" : "没有失败请求时进入 Requests 列表查看筛选。"}
            label="Requests detail"
            status={failedRequests.length > 0 ? `${failedRequests.length} failed` : "no-signal"}
            onClick={() => {
              const firstFailedRequest = failedRequests[0];
              if (firstFailedRequest) {
                onOpenRequestDetail(firstFailedRequest.id);
              } else {
                onSetupNavigate("requestLogs");
              }
            }}
          />
          <DashboardAction
            detail="查看禁用、恢复、密钥和配置变更的审计记录；页面未就绪时由 AppRouter 安全降级。"
            label="Audit logs"
            status="safe target"
            onClick={() => onSetupNavigate("auditLogs")}
          />
        </div>
      </section>

      <section className="admin-panel" aria-label="Setup Wizard">
        <SectionHeader
          title="Setup Wizard"
          description="四步 readback：admin、mock provider/channel/model、test key、Gateway model/chat readiness；生产凭证不是本地完成 blocker。"
        />

        <div className="setup-sequence">
          {setupSteps.map((step, index) => (
            <article className={`setup-step setup-step--${step.status}`} key={step.label}>
              <div className="setup-step-index">{index + 1}</div>
              <div className="setup-step-body">
                <div className="setup-step-heading">
                  <div>
                    <h3>{step.label}</h3>
                    <p>{step.detail}</p>
                  </div>
                  <ProbeStatusChip status={step.status} />
                </div>
                <div className="setup-step-footer">
                  <span>{step.evidence}</span>
                  <ActionButton
                    aria-label={`Setup ${step.target}`}
                    icon={<ArrowRight aria-hidden="true" size={15} />}
                    onClick={() => onSetupNavigate(step.target)}
                    variant="table"
                  >
                    {step.action}
                  </ActionButton>
                </div>
              </div>
            </article>
          ))}
        </div>
      </section>

      <section className="admin-panel" aria-label="健康汇总控制">
        <SectionHeader
          title="健康控制"
          description={
            effectiveHealthSummary
              ? `${effectiveHealthSummary.recent_window.sample_count} / ${effectiveHealthSummary.recent_window.sample_limit} 个样本 / ${windowLabel}`
              : "选择汇总窗口和样本上限。"
          }
        />

        <form onSubmit={handleRefreshSubmit}>
          <Toolbar className="health-controls">
            <Field label="时间窗口">
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
            </Field>

            <Field label="样本上限">
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
            </Field>

            <Field label="范围">
              <select value={matrixScope} onChange={(event) => setMatrixScope(event.currentTarget.value as MatrixScope)}>
                {matrixScopes.map((scope) => (
                  <option key={scope} value={scope}>
                    {scope === "all" ? "全部范围" : scopeLabel(scope)}
                  </option>
                ))}
              </select>
            </Field>

            <Field label="自动刷新">
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
            </Field>

            <Field label="矩阵搜索">
              <input
                value={matrixQuery}
                onChange={(event) => setMatrixQuery(event.currentTarget.value)}
                placeholder="名称、状态、路由"
              />
            </Field>

            <ActionButton
              className="primary-button--inline"
              disabled={controlsLoading}
              icon={<RefreshCw aria-hidden="true" size={18} className={controlsLoading ? "spin" : undefined} />}
              type="submit"
            >
              刷新汇总
            </ActionButton>
          </Toolbar>
        </form>
      </section>

      <section aria-label="服务探针">
        <SectionHeader
          title="服务探针"
          description={lastChecked ? `上次检查 ${lastChecked}` : "no-signal"}
          actions={
            <ActionButton
              disabled={loading}
              icon={<RefreshCw aria-hidden="true" size={18} className={loading ? "spin" : undefined} />}
              onClick={onRefresh}
            >
              刷新
            </ActionButton>
          }
        />

        <DataTable aria-label="服务探针" className="health-table">
          <thead>
            <tr>
              <th>服务</th>
              <th>状态</th>
              <th>端点</th>
            </tr>
          </thead>
          <tbody>
            {results.length > 0 ? (
              results.map((result) => (
                <tr key={result.name}>
                  <td>
                    <strong>{result.name}</strong>
                  </td>
                  <td>
                    <ProbeStatusChip status={result.status} />
                  </td>
                  <td>{safeFieldValue(result.detail)}</td>
                </tr>
              ))
            ) : (
              <tr>
                <td colSpan={3}>
                  <EmptyState
                    title="服务探针"
                    detail={loading ? "正在检查已配置端点。" : "no-signal"}
                    action={<ProbeStatusChip status="pending" />}
                  />
                </td>
              </tr>
            )}
          </tbody>
        </DataTable>
      </section>

      <section className="health-matrix" aria-label="供应商通道密钥模型健康状态">
        <SectionHeader
          title="健康矩阵"
          description={
            effectiveHealthSummaryError
              ? effectiveHealthSummaryError
              : `显示 ${rows.length} / ${allRows.length} 行，覆盖供应商、通道、密钥和模型。`
          }
        />

        <DataTable aria-label="供应商通道密钥模型健康状态" className="health-table">
            <thead>
              <tr>
                <th>范围</th>
                <th>名称</th>
                <th>状态</th>
                <th>分数</th>
                <th>信号</th>
                <th>恢复</th>
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
                      <td>{scopeLabel(row.scope)}</td>
                      <td>
                        <strong>{row.name}</strong>
                        <span>{shortId(row.id)}</span>
                      </td>
                      <td>
                        <ProbeStatusChip status={row.status} />
                      </td>
                      <td>{row.score}</td>
                      <td>{row.signal}</td>
                      <td>
                        {showRecoveryAction ? (
                          <div className="table-action-stack">
                            <ActionButton
                              aria-label={`请求恢复 ${row.name}`}
                              disabled={recoveryDisabled}
                              icon={<RotateCcw aria-hidden="true" size={15} />}
                              onClick={() => onRecoveryRequest(row.id)}
                              variant="table"
                            >
                              {recoveryButtonLabel(recoveryState)}
                            </ActionButton>
                            {recoveryError ? <small>{recoveryError}</small> : null}
                          </div>
                        ) : (
                          <span className="muted-copy">{row.recoverable ? "无权限" : "-"}</span>
                        )}
                      </td>
                    </tr>
                  );
                })
              ) : (
                <tr>
                  <td colSpan={6}>
                    <EmptyState
                      title={
                        controlsLoading
                          ? "正在加载健康汇总"
                          : allRows.length > 0
                            ? "当前筛选没有匹配行"
                            : "没有返回健康汇总"
                      }
                      detail="调整筛选条件或刷新汇总后再查看健康矩阵。"
                    />
                  </td>
                </tr>
              )}
            </tbody>
        </DataTable>
      </section>
    </div>
  );
}

function RequestStatusChip({ log }: { log: RequestLogSummary }) {
  const isFailure = log.status !== "succeeded" || (typeof log.http_status === "number" && log.http_status >= 400);
  return <StatusChip tone={isFailure ? "danger" : "good"}>{safeFieldValue(log.status)}</StatusChip>;
}

function DashboardMetricButton({
  detail,
  label,
  onClick,
  targetLabel,
  tone = "default",
  value,
}: {
  detail: string;
  label: string;
  onClick: () => void;
  targetLabel: string;
  tone?: "default" | "good" | "neutral" | "warn";
  value: string;
}) {
  return (
    <button
      aria-label={`${label}: ${targetLabel}`}
      className={["metric-card", "dashboard-metric-button", tone === "default" ? "" : `metric-card--${tone}`]
        .filter(Boolean)
        .join(" ")}
      type="button"
      onClick={onClick}
    >
      <span>{label}</span>
      <strong>{value}</strong>
      <small>{detail}</small>
      <em>{targetLabel}</em>
    </button>
  );
}

function DashboardAction({
  detail,
  label,
  onClick,
  status,
}: {
  detail: string;
  label: string;
  onClick: () => void;
  status: string;
}) {
  return (
    <article className="dashboard-action-card">
      <div>
        <strong>{label}</strong>
        <span>{status}</span>
      </div>
      <p>{detail}</p>
      <ActionButton icon={<ArrowRight aria-hidden="true" size={15} />} onClick={onClick} variant="table">
        打开
      </ActionButton>
    </article>
  );
}

function setupWizardSteps(
  summary: HealthSummary | null,
  results: ProbeResult[],
  setupReadback: AdminSetupReadback | null,
): SetupStep[] {
  if (setupReadback) {
    return setupReadbackSteps(setupReadback);
  }

  const enabledProviders = summary?.providers.filter((provider) => provider.status === "enabled").length ?? 0;
  const enabledChannels = summary?.channels.filter((channel) => channel.status === "enabled").length ?? 0;
  const configuredKeys = summary?.provider_keys.filter((key) => key.credential_configured).length ?? 0;
  const routableModels = summary?.models.filter((model) => model.routing_state === "routable").length ?? 0;
  const gatewayProbe = results.find((result) => result.name.toLowerCase().includes("gateway"));
  const requestSamples = summary?.recent_window.sample_count ?? 0;

  return [
    {
      action: "接供应商",
      detail: "先创建 provider、channel 和 provider key。",
      evidence: `${enabledProviders} 个启用供应商 / ${enabledChannels} 个启用通道 / ${configuredKeys} 个已配置密钥`,
      label: "1. 接供应商",
      status: enabledProviders > 0 && enabledChannels > 0 && configuredKeys > 0 ? "online" : "pending",
      target: "providers",
    },
    {
      action: "建模型",
      detail: "创建公开模型，并绑定到已启用通道。",
      evidence: `${routableModels} 个可路由模型 / ${summary?.totals.model_associations ?? 0} 个关联`,
      label: "2. 建模型",
      status: routableModels > 0 ? "online" : summary ? "pending" : "pending",
      target: "models",
    },
    {
      action: "发 key",
      detail: "创建或复核用户 API key，再交给 User Portal 调用。",
      evidence: summary ? "API key 状态在密钥工作台维护" : "等待健康汇总",
      label: "3. 发 key",
      status: routableModels > 0 ? "pending" : "pending",
      target: "keys",
    },
    {
      action: "看调用",
      detail: "运行一次 Gateway 请求，再从请求与追踪确认路由和错误。",
      evidence:
        requestSamples > 0
          ? `${requestSamples} 条近期请求`
          : gatewayProbe
            ? `Gateway ${gatewayProbe.status}`
            : "等待 Gateway 请求",
      label: "4. 调用 Gateway",
      status: requestSamples > 0 ? "online" : gatewayProbe?.status ?? "pending",
      target: "requestLogs",
    },
  ];
}

function setupReadbackSteps(readback: AdminSetupReadback): SetupStep[] {
  if (Array.isArray(readback.wizard_steps) && readback.wizard_steps.length > 0) {
    return readback.wizard_steps.slice(0, 4).map((step) => ({
      action: setupStepAction(step.code, step.status),
      detail: step.detail,
      evidence: `${step.evidence}; prod_credentials_required=${String(step.production_credentials_required)}`,
      label: step.label,
      status: readbackStatusToProbeStatus(step.status),
      target: setupStepTarget(step.code),
    }));
  }

  const seed = readback.local_seed;
  const gateway = readback.gateway;

  return [
    {
      action: seed.admin_exists ? "打开 Admin" : "修复 admin",
      detail: "确认本地 admin 已创建；raw password 不在 readback 或 UI 中返回。",
      evidence: `admin ${readyText(seed.admin_exists)} / prod_credentials_required=false`,
      label: "Admin",
      status: seed.admin_exists ? "online" : "offline",
      target: "providers",
    },
    {
      action: seed.default_model.association_enabled ? "查看 Models" : "修复 mock stack",
      detail: "确认 mock provider/channel/provider key placeholder/default model/model association 已就绪。",
      evidence: `provider ${readyText(seed.mock_provider.enabled)} / channel ${readyText(seed.mock_channel.enabled)} / model ${readyText(
        seed.default_model.active,
      )} / association ${readyText(seed.default_model.association_enabled)}`,
      label: "Mock provider/channel/model",
      status:
        seed.mock_provider.enabled &&
        seed.mock_channel.enabled &&
        seed.mock_provider_key.credential_configured &&
        seed.default_model.active &&
        seed.default_model.association_enabled
          ? "online"
          : "offline",
      target: "models",
    },
    {
      action: seed.test_key.active ? "查看 Keys" : "修复 key",
      detail: "确认本地测试 key 存在；secret 只由 dev smoke 使用，不在 UI readback 返回。",
      evidence: `${seed.test_key.key_prefix} / secret_returned=${String(seed.test_key.secret_returned)}`,
      label: "Test key",
      status: seed.test_key.active ? "online" : "offline",
      target: "keys",
    },
    {
      action: gateway.chat_readiness.status === "ready" ? "看调用" : "跑 smoke",
      detail:
        gateway.model_readiness.status === "ready"
          ? gateway.chat_readiness.next_action
          : "先修复本地模型/profile/key readiness，再运行本地 Gateway smoke。",
      evidence: `models ${gateway.model_readiness.status} / chat ${gateway.chat_readiness.status} / ${gateway.chat_readiness.recent_success_count} successful readback`,
      label: "Gateway model/chat readiness",
      status: readbackStatusToProbeStatus(
        gateway.chat_readiness.status === "ready" ? "ready" : gateway.model_readiness.status === "ready" ? "attention" : "blocked",
      ),
      target: "requestLogs",
    },
  ];
}

function setupStepAction(code: string, status: string): string {
  if (status === "ready") {
    if (code === "gateway_model_chat_readiness") {
      return "看调用";
    }
    return "查看";
  }
  if (code === "gateway_model_chat_readiness" && status === "attention") {
    return "跑 smoke";
  }
  return "修复";
}

function setupStepTarget(code: string): SetupTarget {
  if (code === "admin" || code === "mock_provider_channel_model") {
    return "providers";
  }
  if (code === "test_key") {
    return "keys";
  }
  return "requestLogs";
}

function readbackStatusToProbeStatus(status: string): ProbeResult["status"] {
  if (status === "ready") {
    return "online";
  }
  if (status === "blocked") {
    return "offline";
  }
  return "pending";
}

function readyText(value: boolean): string {
  return value ? "ready" : "missing";
}

function requestLogStats(logs: RequestLogSummary[]) {
  const total = logs.length;
  const succeeded = logs.filter(
    (log) => log.status === "succeeded" && (typeof log.http_status !== "number" || log.http_status < 400),
  ).length;
  const successRatio = total > 0 ? succeeded / total : null;
  const inputTokens = logs.reduce((totalTokens, log) => totalTokens + safeNumber(log.input_tokens), 0);
  const outputTokens = logs.reduce((totalTokens, log) => totalTokens + safeNumber(log.output_tokens), 0);
  const costs = new Map<string, number>();

  for (const log of logs) {
    const cost = decimalNumber(log.final_cost);
    if (cost !== null) {
      costs.set(log.currency, (costs.get(log.currency) ?? 0) + cost);
    }
  }

  return {
    cost: moneyTotals(costs),
    successRate: successRatio === null ? "无信号" : `${Math.round(successRatio * 100)}%`,
    successRatio,
    tokens: formatTokenUsage(inputTokens, outputTokens),
    total,
  };
}

function recentFailedRequests(logs: RequestLogSummary[]): RequestLogSummary[] {
  return logs
    .filter((log) => log.status !== "succeeded" || (typeof log.http_status === "number" && log.http_status >= 400))
    .slice(0, 6);
}

function failureSummary(log: RequestLogSummary): string {
  const parts = [log.error_owner, log.error_code, typeof log.http_status === "number" ? `HTTP ${log.http_status}` : null]
    .filter((value): value is string => Boolean(value && value.trim()))
    .map(safeFieldValue);

  if (parts.length > 0) {
    return parts.join(" / ");
  }
  if (log.status === "rejected") {
    return "路由拒绝";
  }
  if (log.status === "failed") {
    return "请求失败";
  }

  return safeFieldValue(log.status);
}

function channelHealthTopRows(summary: HealthSummary | null): ChannelTopRow[] {
  const channels = summary?.channels ?? [];

  return channels
    .map((channel) => ({
      detail: channel.enabled_provider_key_count > 0 ? `${channel.enabled_provider_key_count} 个启用密钥` : "config-needed",
      id: channel.id,
      name: safeFieldValue(channel.name),
      score: scoreText(channel.health_score),
      signal: signalText(channel.status, channel.recent),
      status: pillStatus(channel.health_state),
    }))
    .sort((left, right) => channelRiskRank(left) - channelRiskRank(right))
    .slice(0, 5);
}

function channelRiskRank(row: ChannelTopRow): number {
  const statusRank = row.status === "offline" ? 0 : row.status === "pending" ? 1 : 2;
  const score = row.score.endsWith("%") ? Number(row.score.slice(0, -1)) : 0;
  return statusRank * 1000 + score;
}

function balanceAlertText(
  wallets: AdminWalletCreditSurface[],
  loading: boolean,
  error: string | null,
): { detail: string; tone: "good" | "neutral" | "warn"; value: string } {
  const walletRows = arrayValue<AdminWalletCreditSurface>(wallets);

  if (loading) {
    return { detail: "读取 wallet 摘要", tone: "neutral", value: "加载中" };
  }
  if (error && walletRows.length === 0) {
    return { detail: error, tone: "warn", value: "config-needed" };
  }
  if (walletRows.length === 0) {
    return { detail: "没有 wallet 信号", tone: "neutral", value: "no-signal" };
  }

  const lowWallets = walletRows.filter((wallet) => {
    const amount = walletAvailableNumber(wallet);
    return amount !== null && amount <= 0;
  });

  if (lowWallets.length > 0) {
    return { detail: `${lowWallets.length} 个 wallet 可用余额 <= 0`, tone: "warn", value: "attention" };
  }

  return { detail: walletAvailableTotals(walletRows), tone: "good", value: "正常" };
}

function walletAvailableTotals(wallets: AdminWalletCreditSurface[]): string {
  const totals = new Map<string, number>();

  for (const wallet of wallets) {
    const amount = walletAvailableNumber(wallet);

    if (amount !== null) {
      totals.set(wallet.wallet.currency, (totals.get(wallet.wallet.currency) ?? 0) + amount);
    }
  }

  return moneyTotals(totals);
}

function walletAvailableNumber(surface: AdminWalletCreditSurface): number | null {
  const activeCredit = decimalNumber(surface.credit_grants.active_remaining_total);
  const confirmedLedger = decimalNumber(surface.ledger_balance_window.confirmed_net_amount);
  const pendingLedger = decimalNumber(surface.ledger_balance_window.pending_amount);
  const balanceFloor = decimalNumber(surface.wallet.balance_floor);

  if (activeCredit === null || confirmedLedger === null || pendingLedger === null || balanceFloor === null) {
    return null;
  }

  return activeCredit + confirmedLedger + pendingLedger - balanceFloor;
}

function moneyTotals(totals: Map<string, number>): string {
  if (totals.size === 0) {
    return "-";
  }

  return Array.from(totals.entries())
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([currency, amount]) => formatMoney(formatDecimal(amount), currency))
    .join(" / ");
}

function decimalNumber(value: string | number | null | undefined): number | null {
  if (typeof value === "number") {
    return Number.isFinite(value) ? value : null;
  }
  if (typeof value !== "string" || value.trim() === "") {
    return null;
  }

  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function formatDecimal(value: number): string {
  return value.toLocaleString(undefined, {
    maximumFractionDigits: 6,
    minimumFractionDigits: 0,
  });
}

function safeNumber(value: number | null | undefined): number {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

function arrayValue<T>(value: T[] | unknown): T[] {
  return Array.isArray(value) ? value : [];
}

function healthRows(summary: HealthSummary | null): HealthRow[] {
  if (!summary) {
    return [];
  }

  const providers = Array.isArray(summary.providers) ? summary.providers : [];
  const channels = Array.isArray(summary.channels) ? summary.channels : [];
  const providerKeys = Array.isArray(summary.provider_keys) ? summary.provider_keys : [];
  const models = Array.isArray(summary.models) ? summary.models : [];

  return [
    ...providers.map((provider) => ({
      id: provider.id,
      name: safeFieldValue(provider.name),
      recoverable: false,
      scope: "Provider",
      score: scoreText(provider.health_score),
      signal: signalText(provider.status, provider.recent),
      status: pillStatus(provider.health_state),
    })),
    ...channels.map((channel) => ({
      id: channel.id,
      name: safeFieldValue(channel.name),
      recoverable: false,
      scope: "Channel",
      score: scoreText(channel.health_score),
      signal: signalText(channel.status, channel.recent),
      status: pillStatus(channel.health_state),
    })),
    ...providerKeys.map((key) => ({
      id: key.id,
      name: safeFieldValue(key.key_alias),
      recoverable: isProviderKeyRecoverable(key.status),
      scope: "Provider key",
      score: scoreText(key.health_score),
      signal: signalText(key.status, key.recent, key.configured_last_error_code),
      status: pillStatus(key.health_state),
    })),
    ...models.map((model) => ({
      id: model.id,
      name: safeFieldValue(model.display_name),
      recoverable: false,
      scope: "Model",
      score: `${model.routable_channel_count} 条路由`,
      signal: signalText(model.routing_state, model.recent),
      status: modelPillStatus(model.routing_state),
    })),
  ];
}

function scopeLabel(scope: string): string {
  if (scope === "Provider") {
    return "供应商";
  }
  if (scope === "Channel") {
    return "通道";
  }
  if (scope === "Provider key") {
    return "供应商密钥";
  }
  if (scope === "Model") {
    return "模型";
  }

  return scope;
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

  const normalizedScore = score > 1 ? score : score * 100;
  return `${Math.round(Math.min(Math.max(normalizedScore, 0), 100))}%`;
}

function signalText(status: string, recent: HealthSummaryRecentStats, configuredError?: string | null): string {
  const safeStatus = healthStatusText(status);
  const recentError = safeFieldValue(recent.last_error?.code ?? configuredError);

  if (typeof recent.success_rate === "number" && Number.isFinite(recent.success_rate)) {
    return `${safeStatus} / ${successRateText(recent.success_rate)} 成功`;
  }
  if (recentError !== "-") {
    return `${safeStatus} / ${recentError}`;
  }
  if (recent.error_count > 0) {
    return `${safeStatus} / ${recent.error_count} 个错误`;
  }

  return safeStatus;
}

function healthStatusText(status: string): string {
  const normalized = status.toLowerCase();
  const labels: Record<string, string> = {
    active: "启用",
    auth_failed: "认证失败",
    cooldown: "冷却中",
    degraded: "降级",
    disabled: "停用",
    enabled: "启用",
    healthy: "健康",
    manual_disabled: "手动停用",
    no_route: "无路由",
    no_signal: "无信号",
    offline: "离线",
    online: "在线",
    pending: "等待中",
    quota_exhausted: "配额耗尽",
    recovery_probe: "恢复探测中",
    routable: "可路由",
    unhealthy: "异常",
  };

  return labels[normalized] ?? safeFieldValue(status);
}

function successRateText(rate: number | null | undefined): string {
  if (typeof rate !== "number" || !Number.isFinite(rate)) {
    return "无信号";
  }

  return `${Math.round(rate * 100)}%`;
}

function healthWindowLabel(summary: HealthSummary | null): string {
  const minutes = summary?.recent_window.window?.minutes ?? summary?.recent_window.window_minutes;

  if (typeof minutes !== "number" || !Number.isFinite(minutes) || minutes <= 0) {
    return "已配置窗口";
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
    return "处理中";
  }
  if (state === "succeeded") {
    return "已请求";
  }
  if (state === "failed") {
    return "重试";
  }

  return "请求";
}

function shortId(id: string): string {
  return id.length > 12 ? id.slice(0, 8) : id;
}
