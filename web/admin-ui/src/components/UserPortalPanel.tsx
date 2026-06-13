import { FormEvent, useEffect, useMemo, useState } from "react";
import {
  createUserVirtualKey,
  deleteUserVirtualKey,
  disableUserVirtualKey,
  getUserBalance,
  getUserHomeSummary,
  getUserReadiness,
  getUserRequestTraceSummary,
  getUserSubscriptionPaymentOverview,
  getUserUsageSummary,
  listUserModels,
  listUserVirtualKeys,
  listUserRequestLogs,
  loginUser,
  logoutUser,
  redeemUserVoucher,
  registerUser,
  requestUserEmailVerification,
  requestUserPasswordReset,
  serviceBaseUrls,
  type UserBalance,
  type UserHomeSummary,
  type UserMeResponse,
  type UserModel,
  type UserProductizationStatusResponse,
  type UserReadiness,
  type UserReadinessCheck,
  type UserRequestLogSummary,
  type UserRequestTraceSummary,
  type UserSubscriptionPaymentOverview,
  type UserSubscriptionPlanSummary,
  type UserUsageSummary,
  type UserUsageTotals,
  type UserVirtualKey,
} from "../api/client";
import { errorMessage, safeFieldValue, shortId } from "./adminUtils";
import { Activity, Copy, CreditCard, Database, Key, LogIn, Network, Plus, RefreshCw, Route, Search, ScrollText, ShieldOff, Trash2, X } from "./icons";

export type UserPortalSession = {
  acceptedAt?: string | null;
  email: string;
  expiresAt: string;
  name: string;
  pendingAcceptance?: boolean;
  privacyVersion?: string;
  projectId: string;
  projectRole: string;
  tenantId: string;
  termsVersion?: string;
  userId: string;
};

type LoginProps = {
  onAdminMode: () => void;
  onLogin: (session: UserPortalSession) => void;
};

type DashboardProps = {
  onLogout: () => void;
  session: UserPortalSession;
};

type Mode = "login" | "register";

const USER_USAGE_WINDOWS = [1, 7, 30, 90] as const;
type UserUsageWindowDays = (typeof USER_USAGE_WINDOWS)[number];
type UserConsoleFailure = {
  detail: string;
  nextStep: string;
  status: number | "Network";
  title: string;
};
type UserConsoleMode = "non_stream" | "stream";
type UserConsoleChunk = {
  content: string;
  index: number;
};
type UserConsoleResult = {
  chunks: UserConsoleChunk[];
  finishReason: string | null;
  mode: UserConsoleMode;
  model: string;
  requestId: string | null;
  status: number;
  text: string;
  traceId: string;
};
type UserCostEstimateInput = {
  cacheTokens: number;
  inputTokens: number;
  outputTokens: number;
  reasoningTokens: number;
};
type UserCostEstimate = {
  balanceAfter: string | null;
  balanceEnough: boolean | null;
  balanceNumeric: number | null;
  configNeeded: boolean;
  currency: string;
  estimatedCost: string | null;
  explanation: string;
  priceDetail: string;
  status: "ready" | "insufficient" | "config-needed";
  tokenTotal: number;
};
type UserRequestHistoryFocus = {
  requestId?: string | null;
  traceId?: string | null;
};
type UserVoucherReceipt = {
  amount: string;
  codeLocator: string;
  creditGrantId: string | null;
  currency: string;
  expiresAt: string | null;
  ledgerEntryId: string | null;
  projectId: string | null;
  redemptionId: string | null;
  status: string;
  tenantId: string | null;
  validUntil: string | null;
  voucherId: string | null;
  walletId: string | null;
};
type LegalDocument = "terms" | "privacy";
const USER_API_KEY_PLACEHOLDER = "<user-api-key>";
const USER_AUTH_FAILURE_MESSAGE = "登录或注册失败。请检查邮箱和密码后重试。";

export function UserPortalLoginPanel({ onAdminMode, onLogin }: LoginProps) {
  const [displayName, setDisplayName] = useState("");
  const [email, setEmail] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [legalDocument, setLegalDocument] = useState<LegalDocument | null>(null);
  const [loading, setLoading] = useState(false);
  const [mode, setMode] = useState<Mode>("login");
  const [password, setPassword] = useState("");
  const [passwordResetError, setPasswordResetError] = useState<string | null>(null);
  const [passwordResetLoading, setPasswordResetLoading] = useState(false);
  const [passwordResetResult, setPasswordResetResult] = useState<UserProductizationStatusResponse | null>(null);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setLoading(true);

    try {
      const response =
        mode === "register"
          ? await registerUser({
              display_name: displayName.trim() || undefined,
              email: email.trim(),
              password,
            })
          : await loginUser({
              email: email.trim(),
              password,
            });
      onLogin(userSessionFromMe(response));
      setPassword("");
    } catch (requestError) {
      setError(userAuthFailureMessage(requestError));
    } finally {
      setLoading(false);
    }
  }

  async function requestPasswordReset() {
    setPasswordResetError(null);
    setPasswordResetResult(null);
    setPasswordResetLoading(true);
    try {
      setPasswordResetResult(await requestUserPasswordReset({ email: email.trim() }));
    } catch (requestError) {
      setPasswordResetError(errorMessage(requestError));
    } finally {
      setPasswordResetLoading(false);
    }
  }

  return (
    <main className="auth-shell">
      <section className="auth-panel" aria-labelledby="user-login-title">
        <div className="auth-brand">
          <span className="brand-mark">AG</span>
          <span>AI Gateway</span>
        </div>
        <p className="eyebrow">用户门户</p>
        <h1 id="user-login-title">{mode === "register" ? "创建账号" : "用户登录"}</h1>

        <form className="login-form" onSubmit={handleSubmit}>
          {mode === "register" ? (
            <label>
              显示名称
              <input
                autoComplete="name"
                name="display_name"
                onChange={(event) => setDisplayName(event.currentTarget.value)}
                type="text"
                value={displayName}
              />
            </label>
          ) : null}

          <label>
            邮箱
            <input
              autoComplete="username"
              name="email"
              onChange={(event) => setEmail(event.currentTarget.value)}
              required
              type="email"
              value={email}
            />
          </label>

          <label>
            密码
            <input
              autoComplete={mode === "register" ? "new-password" : "current-password"}
              minLength={8}
              name="password"
              onChange={(event) => setPassword(event.currentTarget.value)}
              required
              type="password"
              value={password}
            />
          </label>

          <button className="primary-button" type="submit" disabled={loading}>
            <LogIn aria-hidden="true" size={18} />
            {loading ? "正在提交" : mode === "register" ? "创建账号" : "登录"}
          </button>

          {error ? <p className="form-status form-status--error">{error}</p> : null}
        </form>

        {mode === "register" ? (
          <p className="legal-inline-copy">
            创建账号即表示同意
            <button type="button" onClick={() => setLegalDocument("terms")}>
              用户协议
            </button>
            和
            <button type="button" onClick={() => setLegalDocument("privacy")}>
              隐私政策
            </button>
            。
          </p>
        ) : null}

        {mode === "login" ? (
          <section className="auth-assist-panel" aria-label="密码重置">
            <div>
              <strong>忘记密码</strong>
              <span>输入邮箱后可请求重置链接。当前版本不会泄露账号是否存在。</span>
            </div>
            <button className="secondary-button" type="button" onClick={() => void requestPasswordReset()} disabled={passwordResetLoading || !email.trim()}>
              {passwordResetLoading ? "处理中" : "请求重置"}
            </button>
            {passwordResetError ? <p className="form-status form-status--error">{passwordResetError}</p> : null}
            {passwordResetResult ? (
              <p className="form-status">
                {passwordResetResult.message} 状态：{userProductizationStatusSummary(passwordResetResult)}
              </p>
            ) : null}
          </section>
        ) : null}

        <div className="action-row">
          <button className="secondary-button" type="button" onClick={() => setMode(mode === "login" ? "register" : "login")}>
            {mode === "login" ? "创建账号" : "使用已有账号"}
          </button>
          <button className="secondary-button" type="button" onClick={onAdminMode}>
            管理控制台
          </button>
        </div>

        <div className="legal-link-row" aria-label="产品法律文档">
          <button type="button" onClick={() => setLegalDocument("terms")}>
            用户协议
          </button>
          <button type="button" onClick={() => setLegalDocument("privacy")}>
            隐私政策
          </button>
        </div>
      </section>

      <section className="auth-context" aria-label="用户门户范围">
        <Key aria-hidden="true" size={26} />
        <div>
          <h2>API 访问</h2>
          <dl>
            <div>
              <dt>密钥</dt>
              <dd>用户自持有</dd>
            </div>
            <div>
              <dt>额度</dt>
              <dd>优先兑换券</dd>
            </div>
            <div>
              <dt>计费</dt>
              <dd>按量使用</dd>
            </div>
          </dl>
        </div>
      </section>

      {legalDocument ? <LegalDocumentDialog document={legalDocument} onClose={() => setLegalDocument(null)} /> : null}
    </main>
  );
}

function LegalDocumentDialog({ document, onClose }: { document: LegalDocument; onClose: () => void }) {
  const isTerms = document === "terms";
  const title = isTerms ? "用户协议" : "隐私政策";
  const items = isTerms
    ? [
        "用户负责保管自己的 API Key，不得共享、出售或用于违反适用法律的调用。",
        "平台按项目额度、价格表和请求日志计量 API 使用量；错误、限流和余额不足会以脱敏元数据展示。",
        "管理员可以基于安全、滥用、欠费或配置需要暂停账号、API Key 或模型访问。",
      ]
    : [
        "当前门户只展示账号邮箱、项目标识、钱包和请求计量摘要；不会展示 API Key secret、兑换码或原始 prompt。",
        "请求日志以脱敏元数据、hash、token、费用和 trace 引用为主，用于支持排障和账单复核。",
        "邮件验证和密码重置当前为 pending/config-needed skeleton；接入邮件服务前不会发送真实邮件。",
      ];

  return (
    <div className="wizard-overlay" role="presentation">
      <section className="legal-dialog" aria-modal="true" aria-labelledby="legal-dialog-title" role="dialog">
        <div className="wizard-header">
          <div>
            <span>用户门户</span>
            <h3 id="legal-dialog-title">{title}</h3>
            <p>{isTerms ? "第一版产品化条款摘要，供本地 MVP 注册和登录路径引用。" : "第一版隐私摘要，聚焦用户门户当前实际收集和展示的数据。"}</p>
          </div>
          <button className="secondary-button" type="button" onClick={onClose}>
            <X aria-hidden="true" size={17} />
            关闭
          </button>
        </div>
        <div className="legal-dialog-body">
          {items.map((item) => (
            <article key={item}>
              <strong>{item.split("；")[0]}</strong>
              <p>{item}</p>
            </article>
          ))}
        </div>
      </section>
    </div>
  );
}

export function UserPortalDashboard({ onLogout, session }: DashboardProps) {
  const gatewayBaseUrl = serviceBaseUrls.gateway;
  const [copiedTarget, setCopiedTarget] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [createdSecret, setCreatedSecret] = useState<{ name: string; secret: string } | null>(null);
  const [consoleApiKey, setConsoleApiKey] = useState("");
  const [consoleError, setConsoleError] = useState<UserConsoleFailure | null>(null);
  const [consoleLoading, setConsoleLoading] = useState(false);
  const [consoleMode, setConsoleMode] = useState<UserConsoleMode>("non_stream");
  const [consoleModel, setConsoleModel] = useState("");
  const [consoleModelsResult, setConsoleModelsResult] = useState<{ count: number; status: number } | null>(null);
  const [consolePrompt, setConsolePrompt] = useState("请只返回 ok。");
  const [consoleResult, setConsoleResult] = useState<UserConsoleResult | null>(null);
  const [estimateCacheTokens, setEstimateCacheTokens] = useState("0");
  const [estimateInputTokens, setEstimateInputTokens] = useState("32");
  const [estimateOutputTokens, setEstimateOutputTokens] = useState("128");
  const [estimateReasoningTokens, setEstimateReasoningTokens] = useState("0");
  const [balance, setBalance] = useState<UserBalance | null>(null);
  const [balanceError, setBalanceError] = useState<string | null>(null);
  const [balanceLoading, setBalanceLoading] = useState(false);
  const [homeSummary, setHomeSummary] = useState<UserHomeSummary | null>(null);
  const [homeSummaryError, setHomeSummaryError] = useState<string | null>(null);
  const [homeSummaryLoading, setHomeSummaryLoading] = useState(false);
  const [keyError, setKeyError] = useState<string | null>(null);
  const [keyName, setKeyName] = useState("");
  const [keys, setKeys] = useState<UserVirtualKey[]>([]);
  const [keysLoading, setKeysLoading] = useState(false);
  const [logs, setLogs] = useState<UserRequestLogSummary[]>([]);
  const [logsError, setLogsError] = useState<string | null>(null);
  const [logsLoading, setLogsLoading] = useState(false);
  const [recentLogs, setRecentLogs] = useState<UserRequestLogSummary[]>([]);
  const [requestSearchLoading, setRequestSearchLoading] = useState(false);
  const [requestSearch, setRequestSearch] = useState("");
  const [selectedLogId, setSelectedLogId] = useState<string | null>(null);
  const [emailVerificationError, setEmailVerificationError] = useState<string | null>(null);
  const [emailVerificationLoading, setEmailVerificationLoading] = useState(false);
  const [emailVerificationResult, setEmailVerificationResult] = useState<UserProductizationStatusResponse | null>(null);
  const [traceSummary, setTraceSummary] = useState<UserRequestTraceSummary | null>(null);
  const [traceSummaryError, setTraceSummaryError] = useState<string | null>(null);
  const [traceSummaryLoading, setTraceSummaryLoading] = useState(false);
  const [subscriptionOverview, setSubscriptionOverview] = useState<UserSubscriptionPaymentOverview | null>(null);
  const [subscriptionOverviewError, setSubscriptionOverviewError] = useState<string | null>(null);
  const [subscriptionOverviewLoading, setSubscriptionOverviewLoading] = useState(false);
  const [usageSummary, setUsageSummary] = useState<UserUsageSummary | null>(null);
  const [usageSummaryError, setUsageSummaryError] = useState<string | null>(null);
  const [usageSummaryLoading, setUsageSummaryLoading] = useState(false);
  const [usageWindowDays, setUsageWindowDays] = useState<UserUsageWindowDays>(7);
  const [models, setModels] = useState<UserModel[]>([]);
  const [modelsError, setModelsError] = useState<string | null>(null);
  const [modelsLoading, setModelsLoading] = useState(false);
  const [modelSearch, setModelSearch] = useState("");
  const [modelsCallableOnly, setModelsCallableOnly] = useState(false);
  const [readiness, setReadiness] = useState<UserReadiness | null>(null);
  const [readinessError, setReadinessError] = useState<string | null>(null);
  const [readinessLoading, setReadinessLoading] = useState(false);
  const [redeemCode, setRedeemCode] = useState("");
  const [redeemError, setRedeemError] = useState<string | null>(null);
  const [redeemReceipt, setRedeemReceipt] = useState<UserVoucherReceipt | null>(null);
  const [redeeming, setRedeeming] = useState(false);
  const endpointBaseUrl = homeSummary?.endpoint?.base_url ?? gatewayBaseUrl;
  const chatEndpoint = homeSummary?.endpoint?.chat_completions_url ?? joinEndpoint(gatewayBaseUrl, "/v1/chat/completions");
  const modelsEndpoint = homeSummary?.endpoint?.models_url ?? joinEndpoint(gatewayBaseUrl, "/v1/models");
  const exampleModel = useMemo(() => preferredExampleModel(models), [models]);
  const consoleModelOptions = useMemo(() => models.filter((model) => model.routable), [models]);
  const selectedConsoleModel = consoleModel || exampleModel;
  const selectedConsoleModelDetail = useMemo(
    () => models.find((model) => model.model === selectedConsoleModel) ?? null,
    [models, selectedConsoleModel],
  );
  const consoleCostEstimateInput = useMemo(
    () => ({
      cacheTokens: nonNegativeIntegerValue(estimateCacheTokens),
      inputTokens: nonNegativeIntegerValue(estimateInputTokens),
      outputTokens: nonNegativeIntegerValue(estimateOutputTokens),
      reasoningTokens: nonNegativeIntegerValue(estimateReasoningTokens),
    }),
    [estimateCacheTokens, estimateInputTokens, estimateOutputTokens, estimateReasoningTokens],
  );
  const consoleCostEstimate = useMemo(
    () =>
      userCostEstimate({
        balance,
        estimate: consoleCostEstimateInput,
        model: selectedConsoleModelDetail,
      }),
    [balance, consoleCostEstimateInput, selectedConsoleModelDetail],
  );
  const filteredModels = useMemo(
    () => filterUserModels(models, modelSearch, modelsCallableOnly),
    [modelSearch, models, modelsCallableOnly],
  );
  const reusableKeyPrefix = useMemo(() => keys.find((key) => key.status === "active")?.key_prefix ?? null, [keys]);
  const curlExample = userCurlExample(chatEndpoint, USER_API_KEY_PLACEHOLDER, selectedConsoleModel);
  const smokeEnvironmentExample = userSmokeEnvironmentExample(endpointBaseUrl, selectedConsoleModel);
  const smokeNodeCommand = "node .\\tests\\integration\\sdk-smoke\\gateway_user_smoke.mjs";
  const smokePythonCommand = "python .\\tests\\integration\\sdk-smoke\\gateway_user_smoke.py";
  const selectedLog = useMemo(
    () => logs.find((log) => log.id === selectedLogId) ?? null,
    [logs, selectedLogId],
  );
  const filteredLogs = useMemo(
    () => filterUserRequestLogs(logs, requestSearch),
    [logs, requestSearch],
  );
  const requestSearchSummary = useMemo(
    () => userRequestSearchSummary(requestSearch, logs, filteredLogs),
    [filteredLogs, logs, requestSearch],
  );
  const sdkExample = userOpenAiSdkExample(endpointBaseUrl, USER_API_KEY_PLACEHOLDER, selectedConsoleModel);
  const activeKeyCount = keys.filter((key) => key.status === "active").length;
  const routableModelCount = models.filter((model) => model.routable).length;
  const requestCount = usageSummary?.totals.request_count ?? homeSummary?.recent_usage?.request_count ?? 0;
  const successRate = usageSummary ? userSuccessRate(usageSummary) : homeSummary?.recent_usage ? userUsageTotalsSuccessRate(homeSummary.recent_usage) : "暂无请求";
  const billingExplanation = useMemo(
    () =>
      usageSummary
        ? userBillingExplanation({
            logs,
            summary: usageSummary,
          })
        : null,
    [logs, usageSummary],
  );
  const operatorSetupGaps = useMemo(() => userOperatorSetupGaps(readiness), [readiness]);
  const connectionSummary = useMemo(
    () =>
      userConnectionSummary({
        activeKeyCount,
        balance,
        gatewayBaseUrl: endpointBaseUrl,
        model: selectedConsoleModel,
        projectId: session.projectId,
        readiness,
        requestCount,
        reusableKeyPrefix,
        routableModelCount,
      }),
    [
      activeKeyCount,
      balance,
      endpointBaseUrl,
      readiness,
      requestCount,
      reusableKeyPrefix,
      routableModelCount,
      selectedConsoleModel,
      session.projectId,
    ],
  );
  const billingReferenceSummary = useMemo(
    () =>
      userBillingReferenceSummary({
        currency: balance?.currency ?? null,
        projectId: session.projectId,
        tenantId: session.tenantId,
        userId: session.userId,
        walletId: balance?.wallet_id ?? null,
      }),
    [balance?.currency, balance?.wallet_id, session.projectId, session.tenantId, session.userId],
  );

  useEffect(() => {
    void refreshHomeSummary();
    void refreshReadiness();
    void refreshBalance();
    void refreshKeys();
    void refreshLogs();
    void refreshModels();
    void refreshSubscriptionOverview();
    void refreshUsageSummary();
  }, []);

  useEffect(() => {
    if (!selectedLog?.trace_id) {
      setTraceSummary(null);
      setTraceSummaryError(null);
      setTraceSummaryLoading(false);
      return;
    }

    void refreshTraceSummary(selectedLog.trace_id);
  }, [selectedLog?.trace_id]);

  useEffect(() => {
    const nextModel = preferredExampleModel(models);
    setConsoleModel((current) =>
      current && models.some((model) => model.model === current && model.routable) ? current : nextModel,
    );
  }, [models]);

  useEffect(() => {
    setEstimateInputTokens((current) => {
      const currentValue = nonNegativeIntegerValue(current);
      const nextValue = estimateTokensFromMessage(consolePrompt);
      return currentValue <= 0 || currentValue === estimateTokensFromMessage("请只返回 ok。") ? String(nextValue) : current;
    });
  }, [consolePrompt]);

  async function signOut() {
    setLoading(true);
    try {
      await logoutUser();
    } finally {
      setLoading(false);
      onLogout();
    }
  }

  async function refreshKeys() {
    setKeyError(null);
    setKeysLoading(true);
    try {
      setKeys(await listUserVirtualKeys());
      void refreshReadiness();
    } catch (requestError) {
      setKeyError(errorMessage(requestError));
    } finally {
      setKeysLoading(false);
    }
  }

  async function refreshBalance() {
    setBalanceError(null);
    setBalanceLoading(true);
    try {
      setBalance(await getUserBalance());
      void refreshReadiness();
    } catch (requestError) {
      setBalanceError(errorMessage(requestError));
    } finally {
      setBalanceLoading(false);
    }
  }

  async function refreshHomeSummary() {
    setHomeSummaryError(null);
    setHomeSummaryLoading(true);
    try {
      const summary = await getUserHomeSummary();
      setHomeSummary(summary);
      if (summary.balance) {
        setBalance(summary.balance);
      }
      if (summary.recent_requests?.requests) {
        setLogs(summary.recent_requests.requests);
        setRecentLogs(summary.recent_requests.requests);
      }
      if (summary.recent_usage) {
        setUsageSummary((current) =>
          current ?? {
            by_key: [],
            by_model: [],
            project_id: summary.project_id,
            schema: "user_usage_summary.local_home_fallback",
            secret_safe: summary.secret_safe,
            top_errors: [],
            totals: summary.recent_usage,
            window_days: 7,
          },
        );
      }
    } catch (requestError) {
      setHomeSummaryError(`home-summary 暂不可用，已使用分散接口 fallback：${safeFieldValue(errorMessage(requestError))}`);
    } finally {
      setHomeSummaryLoading(false);
    }
  }

  async function refreshModels() {
    setModelsError(null);
    setModelsLoading(true);
    try {
      setModels(await listUserModels());
      void refreshReadiness();
    } catch (requestError) {
      setModelsError(errorMessage(requestError));
    } finally {
      setModelsLoading(false);
    }
  }

  async function refreshReadiness() {
    setReadinessError(null);
    setReadinessLoading(true);
    try {
      setReadiness(await getUserReadiness());
    } catch (requestError) {
      setReadinessError(errorMessage(requestError));
    } finally {
      setReadinessLoading(false);
    }
  }

  async function redeemVoucher(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setRedeemError(null);
    setRedeemReceipt(null);
    setRedeeming(true);
    const voucherCode = redeemCode.trim();
    setRedeemCode("");
    try {
      const response = await redeemUserVoucher({
        idempotency_key: crypto.randomUUID(),
        voucher_code: voucherCode,
      });
      if (response.status === "redeemed" || response.status === "replayed") {
        const receipt = response.receipt ?? response;
        setRedeemReceipt({
          amount: receipt.amount ?? "额度",
          codeLocator: receipt.code_locator ?? receipt.code_redacted ?? "omitted",
          creditGrantId: receipt.credit_grant_id ?? null,
          currency: receipt.currency ?? "",
          expiresAt: receipt.expires_at ?? null,
          ledgerEntryId: receipt.ledger_entry_id ?? null,
          projectId: receipt.project_id ?? null,
          redemptionId: receipt.redemption_id ?? null,
          status: receipt.status,
          tenantId: receipt.tenant_id ?? null,
          validUntil: receipt.valid_until ?? receipt.expires_at ?? null,
          voucherId: receipt.voucher_id ?? null,
          walletId: receipt.wallet_id ?? null,
        });
      } else {
        setRedeemError(userVoucherRefusalMessage(response.refusal_code ?? response.status));
      }
      await refreshBalance();
      await refreshReadiness();
    } catch (requestError) {
      setRedeemError(userVoucherRequestErrorMessage(requestError));
    } finally {
      setRedeeming(false);
    }
  }

  async function refreshLogs(focus?: UserRequestHistoryFocus): Promise<UserRequestLogSummary[]> {
    setLogsError(null);
    setLogsLoading(true);
    try {
      let nextLogs = await listUserRequestLogs(userRequestLogFiltersForFocus(focus));
      if (focus && findUserRequestLog(nextLogs, focus) === null && focus.requestId && focus.traceId) {
        nextLogs = await listUserRequestLogs(userRequestLogFiltersForFocus({ traceId: focus.traceId }));
      }
      if (focus) {
        const fallbackLogs = localUserRequestLogFallback({
          currentLogs: logs,
          focus,
          recentLogs,
          remoteLogs: nextLogs,
        });
        if (fallbackLogs) {
          nextLogs = fallbackLogs;
        }
      } else {
        setRecentLogs(nextLogs);
      }
      setLogs(nextLogs);
      if (focus) {
        const focusedLog = findUserRequestLog(nextLogs, focus);
        setSelectedLogId(focusedLog?.id ?? null);
      }
      void refreshReadiness();
      return nextLogs;
    } catch (requestError) {
      if (focus) {
        const fallbackLogs =
          localUserRequestLogFallback({
            currentLogs: logs,
            focus,
            recentLogs,
            remoteLogs: [],
          }) ?? [];
        setLogs(fallbackLogs);
        const focusedLog = findUserRequestLog(fallbackLogs, focus);
        setSelectedLogId(focusedLog?.id ?? null);
        setLogsError(`后端 request query 暂不可用，已使用本地安全字段筛选：${safeFieldValue(errorMessage(requestError))}`);
        return fallbackLogs;
      }
      setLogsError(errorMessage(requestError));
      return [];
    } finally {
      setLogsLoading(false);
    }
  }

  async function refreshUsageSummary(windowDays = usageWindowDays) {
    setUsageSummaryError(null);
    setUsageSummaryLoading(true);
    try {
      setUsageSummary(await getUserUsageSummary({ window_days: windowDays }));
    } catch (requestError) {
      setUsageSummaryError(errorMessage(requestError));
    } finally {
      setUsageSummaryLoading(false);
    }
  }

  async function refreshSubscriptionOverview() {
    setSubscriptionOverviewError(null);
    setSubscriptionOverviewLoading(true);
    try {
      setSubscriptionOverview(await getUserSubscriptionPaymentOverview());
    } catch (requestError) {
      setSubscriptionOverviewError(errorMessage(requestError));
    } finally {
      setSubscriptionOverviewLoading(false);
    }
  }

  async function changeUsageWindow(windowDays: UserUsageWindowDays) {
    setUsageWindowDays(windowDays);
    await refreshUsageSummary(windowDays);
  }

  async function refreshTraceSummary(traceId: string) {
    setTraceSummaryError(null);
    setTraceSummaryLoading(true);
    try {
      setTraceSummary(await getUserRequestTraceSummary(traceId, { limit: 20, window_days: 30 }));
    } catch (requestError) {
      setTraceSummary(null);
      setTraceSummaryError(errorMessage(requestError));
    } finally {
      setTraceSummaryLoading(false);
    }
  }

  async function createKey(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setCreatedSecret(null);
    setConsoleError(null);
    setConsoleModelsResult(null);
    setConsoleResult(null);
    setKeyError(null);

    try {
      const created = await createUserVirtualKey({ name: keyName.trim() });
      if (created.secret && created.secret_once) {
        setCreatedSecret({ name: created.name, secret: created.secret });
      }
      setKeyName("");
      await refreshKeys();
      await refreshReadiness();
    } catch (requestError) {
      setKeyError(errorMessage(requestError));
    }
  }

  async function disableKey(key: UserVirtualKey) {
    setKeyError(null);
    const confirmed = window.confirm(`停用 API Key「${key.name}」？已保存的 secret 将无法继续调用 Gateway。`);
    if (!confirmed) {
      return;
    }
    try {
      const updated = await disableUserVirtualKey(key.id);
      setKeys((current) => current.map((candidate) => (candidate.id === updated.id ? updated : candidate)));
      await refreshReadiness();
      await refreshUsageSummary();
    } catch (requestError) {
      setKeyError(errorMessage(requestError));
    }
  }

  async function deleteKey(key: UserVirtualKey) {
    setKeyError(null);
    const confirmed = window.confirm(`删除 API Key「${key.name}」？这是安全软删除，占用此 key 的客户端需要换用新 key。`);
    if (!confirmed) {
      return;
    }
    try {
      const deleted = await deleteUserVirtualKey(key.id);
      setKeys((current) => current.filter((candidate) => candidate.id !== deleted.id));
      await refreshReadiness();
      await refreshUsageSummary();
    } catch (requestError) {
      setKeyError(errorMessage(requestError));
    }
  }

  async function requestEmailVerification() {
    setEmailVerificationError(null);
    setEmailVerificationResult(null);
    setEmailVerificationLoading(true);
    try {
      setEmailVerificationResult(await requestUserEmailVerification());
    } catch (requestError) {
      setEmailVerificationError(errorMessage(requestError));
    } finally {
      setEmailVerificationLoading(false);
    }
  }

  async function copyText(target: string, value: string) {
    try {
      await writeClipboard(value);
      setCopiedTarget(target);
      window.setTimeout(() => setCopiedTarget((current) => (current === target ? null : current)), 1400);
    } catch {
      setCopiedTarget(null);
    }
  }

  async function focusUserRequestHistory(focus: UserRequestHistoryFocus) {
    const searchValue = (focus.requestId ?? focus.traceId ?? "").trim();
    if (!searchValue) {
      return;
    }

    setRequestSearch(searchValue);
    await refreshLogs(focus);

    document.getElementById("monitoring")?.scrollIntoView?.({ block: "start", behavior: "smooth" });
  }

  async function searchUserRequestHistory() {
    const searchValue = requestSearch.trim();
    if (!searchValue) {
      await refreshLogs();
      return;
    }

    setRequestSearchLoading(true);
    try {
      await focusUserRequestHistory({
        requestId: searchValue,
        traceId: searchValue,
      });
    } finally {
      setRequestSearchLoading(false);
    }
  }

  async function runApiConsole(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setConsoleError(null);
    setConsoleResult(null);
    setConsoleModelsResult(null);
    setConsoleLoading(true);

    const apiKey = createdSecret?.secret ?? consoleApiKey.trim();
    if (!apiKey) {
      setConsoleError({
        detail: "本次测试请求没有提供用户 API Key。",
        nextStep: "先在上方创建 Key，或粘贴已保存的 Key，然后重新运行测试。",
        status: "Network",
        title: "需要 API Key",
      });
      setConsoleLoading(false);
      return;
    }
    if (!consoleModelOptions.some((model) => model.model === selectedConsoleModel)) {
      setConsoleError({
        detail: "此账号当前没有可由 Gateway 路由的模型。",
        nextStep: "请管理员启用模型/channel，或在配置变更后刷新模型列表。",
        status: "Network",
        title: "没有可路由模型",
      });
      setConsoleLoading(false);
      return;
    }

    try {
      const traceId = userConsoleTraceId();
      const response = await fetch(chatEndpoint, {
        body: JSON.stringify({
          model: selectedConsoleModel,
          messages: [{ role: "user", content: consolePrompt.trim() || "ping" }],
          stream: consoleMode === "stream",
        }),
        headers: {
          Accept: consoleMode === "stream" ? "text/event-stream" : "application/json",
          Authorization: `Bearer ${apiKey}`,
          "Content-Type": "application/json",
          "x-ai-trace-id": traceId,
        },
        method: "POST",
      });

      if (consoleMode === "stream") {
        const streamResult = await readUserConsoleStream(response);
        if (!response.ok || streamResult.errorPayload) {
          setConsoleError(userConsoleFailure(response.status, streamResult.errorPayload));
          return;
        }

        const nextResult = {
          chunks: streamResult.chunks,
          finishReason: streamResult.finishReason,
          mode: "stream",
          model: streamResult.model ?? selectedConsoleModel,
          requestId: response.headers.get("x-request-id") ?? streamResult.requestId,
          status: response.status,
          text: streamResult.text || "流式响应已完成，但没有返回文本 chunk。",
          traceId,
        } satisfies UserConsoleResult;
        setConsoleResult(nextResult);
        await refreshUsageSummary();
        await focusUserRequestHistory({
          requestId: nextResult.requestId,
          traceId: nextResult.traceId,
        });
        return;
      }

      const payload = await response.json().catch(() => null);
      if (!response.ok) {
        setConsoleError(userConsoleFailure(response.status, payload));
        return;
      }

      const nextResult = {
        chunks: [],
        finishReason: userConsoleFinishReason(payload),
        mode: "non_stream",
        model: safeFieldValue(isRecord(payload) ? payload.model : null),
        requestId: response.headers.get("x-request-id"),
        status: response.status,
        text: userConsoleAssistantText(payload),
        traceId,
      } satisfies UserConsoleResult;
      setConsoleResult(nextResult);
      await refreshUsageSummary();
      await focusUserRequestHistory({
        requestId: nextResult.requestId,
        traceId: nextResult.traceId,
      });
    } catch (requestError) {
      setConsoleError({
        detail: errorMessage(requestError),
        nextStep: "检查 Gateway 服务是否正在运行，以及浏览器是否能访问配置的网关地址。",
        status: "Network",
        title: "Gateway 无法访问",
      });
    } finally {
      setConsoleLoading(false);
    }
  }

  async function runModelsConsole() {
    setConsoleError(null);
    setConsoleModelsResult(null);
    setConsoleResult(null);
    setConsoleLoading(true);

    const apiKey = createdSecret?.secret ?? consoleApiKey.trim();
    if (!apiKey) {
      setConsoleError({
        detail: "本次模型列表请求没有提供用户 API Key。",
        nextStep: "先在上方创建 Key，或粘贴已保存的 Key，然后重新检查模型。",
        status: "Network",
        title: "需要 API Key",
      });
      setConsoleLoading(false);
      return;
    }

    try {
      const response = await fetch(modelsEndpoint, {
        headers: {
          Accept: "application/json",
          Authorization: `Bearer ${apiKey}`,
        },
        method: "GET",
      });
      const payload = await response.json().catch(() => null);
      if (!response.ok) {
        setConsoleError(userConsoleFailure(response.status, payload));
        return;
      }

      setConsoleModelsResult({
        count: userGatewayModelCount(payload),
        status: response.status,
      });
    } catch (requestError) {
      setConsoleError({
        detail: errorMessage(requestError),
        nextStep: "检查 Gateway 服务是否正在运行，以及浏览器是否能访问配置的网关地址。",
        status: "Network",
        title: "Gateway 无法访问",
      });
    } finally {
      setConsoleLoading(false);
    }
  }

  function fillConsoleModel(model: UserModel) {
    if (!model.routable) {
      setConsoleError({
        detail: userModelUnavailableSummary(model),
        nextStep: "请管理员启用此模型的映射、通道或供应商后再运行控制台测试。",
        status: "Network",
        title: "模型当前不可调用",
      });
      setConsoleResult(null);
      setConsoleModelsResult(null);
      return;
    }

    setConsoleModel(model.model);
    setConsoleError(null);
    setConsoleResult(null);
    setConsoleModelsResult(null);
    document.getElementById("developer-access")?.scrollIntoView({ block: "start", behavior: "smooth" });
  }

  return (
    <main className="user-console-shell">
      <aside className="user-console-sidebar" aria-label="用户门户导航">
        <div className="auth-brand">
          <span className="brand-mark">AG</span>
          <span>AI Gateway</span>
        </div>
        <nav className="user-console-nav">
          <a href="#overview">
            <Activity aria-hidden="true" size={17} />
            概览
          </a>
          <a href="#developer-access">
            <Key aria-hidden="true" size={17} />
            开发者访问
          </a>
          <a href="#subscription-payment">
            <CreditCard aria-hidden="true" size={17} />
            套餐支付
          </a>
          <a href="#models">
            <Route aria-hidden="true" size={17} />
            模型
          </a>
          <a href="#monitoring">
            <ScrollText aria-hidden="true" size={17} />
            监控
          </a>
          <a href="#account-security">
            <ShieldOff aria-hidden="true" size={17} />
            账号
          </a>
        </nav>
        <div className="user-console-session">
          <strong>{session.name}</strong>
          <span>{session.email}</span>
          <span>{session.projectRole}</span>
        </div>
      </aside>

      <section className="user-console-workspace">
        <header className="user-console-topbar" id="overview">
          <div>
            <p className="eyebrow">用户门户</p>
            <h1>API 分发控制台</h1>
            <p>{readiness ? userReadinessSummary(readiness) : "OpenAI-compatible 模型、额度、API Key、用量和请求 trace 详情。"}</p>
          </div>
          <div className="action-row">
            <button
              className="secondary-button"
              type="button"
              onClick={() => {
                void refreshHomeSummary();
                void refreshReadiness();
              }}
              disabled={readinessLoading || homeSummaryLoading}
            >
              <RefreshCw aria-hidden="true" size={17} className={readinessLoading || homeSummaryLoading ? "spin" : undefined} />
              刷新
            </button>
            <button className="secondary-button" type="button" onClick={() => void signOut()} disabled={loading}>
              <RefreshCw aria-hidden="true" size={17} className={loading ? "spin" : undefined} />
              退出
            </button>
          </div>
        </header>

        <section className="user-console-band">
          <article className="user-overview-card user-overview-card--wide">
            <div className="quickstart-heading">
              <div>
                <h2>网关地址</h2>
                <p className="muted-copy">
                  在任何 OpenAI-compatible SDK 中使用这个地址。
                  {homeSummary?.endpoint?.config_needed ? " 当前为 local fallback，请配置 Gateway public base URL。" : ""}
                </p>
              </div>
              <span className={routableModelCount > 0 ? "state-chip state-chip--good" : "state-chip state-chip--warn"}>
                {routableModelCount > 0 ? "可调用" : "需要路由"}
              </span>
            </div>
            <dl className="user-endpoint-list">
              <div>
                <dt>基础地址</dt>
                <dd>
                  <span>{endpointBaseUrl}</span>
                  <button className="inline-copy-button" type="button" onClick={() => void copyText("gateway-base-url", endpointBaseUrl)}>
                    <Copy aria-hidden="true" size={14} />
                    {copiedTarget === "gateway-base-url" ? "已复制" : "复制"}
                  </button>
                </dd>
              </div>
              <div>
                <dt>契约</dt>
                <dd>
                  <span>{homeSummary?.endpoint ? `${homeSummary.schema} / ${homeSummary.endpoint.source}` : homeSummaryLoading ? "加载 home-summary" : "local fallback/config-needed"}</span>
                </dd>
              </div>
              <div>
                <dt>模型接口</dt>
                <dd>
                  <span>{modelsEndpoint}</span>
                  <button className="inline-copy-button" type="button" onClick={() => void copyText("models-endpoint", modelsEndpoint)}>
                    <Copy aria-hidden="true" size={14} />
                    {copiedTarget === "models-endpoint" ? "已复制" : "复制"}
                  </button>
                </dd>
              </div>
              <div>
                <dt>对话接口</dt>
                <dd>
                  <span>{chatEndpoint}</span>
                  <button className="inline-copy-button" type="button" onClick={() => void copyText("chat-endpoint", chatEndpoint)}>
                    <Copy aria-hidden="true" size={14} />
                    {copiedTarget === "chat-endpoint" ? "已复制" : "复制"}
                  </button>
                </dd>
              </div>
            </dl>
          </article>

          <article className="user-overview-card">
            <Database aria-hidden="true" size={20} />
            <span>余额</span>
            <strong>{balance ? balance.available_to_spend : balanceLoading ? "检查中..." : "暂无额度"}</strong>
            <small>{balance ? `${balance.currency} 钱包 ${shortId(balance.wallet_id)}` : "兑换 voucher 额度"}</small>
          </article>
          <article className="user-overview-card">
            <CreditCard aria-hidden="true" size={20} />
            <span>套餐</span>
            <strong>{subscriptionOverview ? userSubscriptionStatusLabel(subscriptionOverview.current_subscription.status) : subscriptionOverviewLoading ? "检查中..." : "本地 demo"}</strong>
            <small>
              {subscriptionOverview
                ? `${subscriptionOverview.plans.length.toLocaleString()} 个可见套餐 / ${subscriptionOverview.scheduler_status}`
                : "local_only 支付入口"}
            </small>
          </article>
          <article className="user-overview-card">
            <Key aria-hidden="true" size={20} />
            <span>API 密钥</span>
            <strong>{activeKeyCount.toLocaleString()}</strong>
            <small>共 {keys.length.toLocaleString()} 个 key</small>
          </article>
          <article className="user-overview-card">
            <Route aria-hidden="true" size={20} />
            <span>模型</span>
            <strong>{(homeSummary?.models?.routable_count ?? routableModelCount).toLocaleString()}</strong>
            <small>{(homeSummary?.models?.total_visible ?? models.length).toLocaleString()} 个可见模型</small>
          </article>
          <article className="user-overview-card">
            <Network aria-hidden="true" size={20} />
            <span>请求</span>
            <strong>{requestCount.toLocaleString()}</strong>
            <small>成功率 {successRate}</small>
          </article>
        </section>

        {homeSummaryError ? <p className="form-status">{homeSummaryError}</p> : null}
        {homeSummary?.recent_requests?.request_ids?.length ? (
          <section className="user-flow-strip" aria-label="最近请求引用">
            {homeSummary.recent_requests.request_ids.slice(0, 5).map((requestId, index) => (
              <article className="user-flow-step user-flow-step--attention" key={requestId}>
                <span>Recent #{index + 1}</span>
                <strong>{shortId(requestId)}</strong>
              </article>
            ))}
          </section>
        ) : null}

        <section className="user-flow-strip" aria-label="User Portal 产品流">
          {[
            {
              label: "1. 注册/登录",
              state: "ready",
              value: session.email,
            },
            {
              label: "2. Home summary",
              state: homeSummary ? "ready" : homeSummaryLoading ? "attention" : "blocked",
              value: homeSummary ? homeSummary.schema : homeSummaryLoading ? "加载中" : "fallback",
            },
            {
              label: "3. Voucher",
              state: balance && balance.available_to_spend !== "0" ? "ready" : "attention",
              value: balance ? `${balance.available_to_spend} ${balance.currency}` : balanceLoading ? "检查额度中" : "兑换 voucher",
            },
            {
              label: "4. API Key",
              state: activeKeyCount > 0 || createdSecret ? "ready" : "blocked",
              value: createdSecret ? "新 key 已就绪" : activeKeyCount > 0 ? `${activeKeyCount} 个活跃` : "创建 key",
            },
            {
              label: "5. API Console",
              state: consoleResult ? "ready" : routableModelCount > 0 ? "attention" : "blocked",
              value: consoleResult ? `HTTP ${consoleResult.status}` : routableModelCount > 0 ? "运行测试" : "需要模型",
            },
            {
              label: "6. Request readback",
              state: selectedLog || requestCount > 0 ? "ready" : "blocked",
              value: selectedLog ? shortId(selectedLog.id) : requestCount > 0 ? "查看请求" : "等待调用",
            },
          ].map((step) => (
            <article className={`user-flow-step user-flow-step--${step.state}`} key={step.label}>
              <span>{step.label}</span>
              <strong>{step.value}</strong>
            </article>
          ))}
        </section>

        <section className="admin-panel" aria-label="用户 API 就绪状态">
          <div className="section-heading">
            <div>
              <h2>API 就绪</h2>
              <p>{readiness ? readiness.next_action : "正在检查账号是否已有额度、可调用模型、API Key 和首个请求。"}</p>
            </div>
          </div>

          {readinessError ? <p className="form-status form-status--error">{readinessError}</p> : null}

          <div className="user-readiness-grid">
            {readiness?.checks.length ? (
              readiness.checks.map((check) => (
                <article className={`user-readiness-step user-readiness-step--${userReadinessStatusClass(check.status)}`} key={check.code}>
                  <div>
                    <h3>{check.label}</h3>
                    <p>{check.detail}</p>
                  </div>
                  <span>{check.next_action}</span>
                </article>
              ))
            ) : (
              <article className="user-readiness-step user-readiness-step--attention">
                <div>
                  <h3>正在加载配置</h3>
                  <p>就绪状态会显示此账号是否能创建 Key，并调用可路由模型。</p>
                </div>
                <span>刷新就绪状态</span>
              </article>
            )}
          </div>

          {operatorSetupGaps.length ? (
            <section className="operator-setup-gaps" aria-label="管理员待处理配置">
              <div>
                <h3>需要管理员补齐配置</h3>
                <p>账号本身可用，但还需要工作区管理员补齐模型路由、Profile 或额度配置。</p>
              </div>
              <ul>
                {operatorSetupGaps.map((gap) => (
                  <li key={gap.code}>
                    <strong>{gap.label}</strong>
                    <span>{gap.nextAction}</span>
                  </li>
                ))}
              </ul>
            </section>
          ) : null}
        </section>

        <section className="user-console-grid" id="developer-access">
          <section className="admin-panel" aria-label="用户余额和兑换券">
            <div className="section-heading">
              <div>
                <h2>额度</h2>
                <p>{balance ? `${balance.currency} 钱包 ${shortId(balance.wallet_id)}` : "通过兑换券充值的 API 额度"}</p>
              </div>
              <button className="secondary-button" type="button" onClick={() => void refreshBalance()} disabled={balanceLoading}>
                <RefreshCw aria-hidden="true" size={17} className={balanceLoading ? "spin" : undefined} />
                刷新
              </button>
            </div>

            <dl className="metric-grid">
              <div>
                <dt>可用额度</dt>
                <dd>{balance ? balance.available_to_spend : balanceLoading ? "检查中..." : "暂无额度"}</dd>
              </div>
              <div>
                <dt>兑换额度</dt>
                <dd>{balance ? balance.active_credit_grant_total : balanceLoading ? "检查中..." : "暂无兑换额度"}</dd>
              </div>
              <div>
                <dt>账本窗口</dt>
                <dd>{balance ? balance.pending_confirmed_ledger_window : balanceLoading ? "检查中..." : "暂无账本记录"}</dd>
              </div>
            </dl>

            <form className="user-inline-form" onSubmit={redeemVoucher}>
              <label className="field">
                兑换码
                <input
                  value={redeemCode}
                  onChange={(event) => setRedeemCode(event.currentTarget.value)}
                  placeholder="输入兑换码"
                  required
                />
              </label>
              <button className="primary-button primary-button--inline" type="submit" disabled={redeeming}>
                <Plus aria-hidden="true" size={17} />
                兑换
              </button>
            </form>

            {balanceError ? <p className="form-status form-status--error">{balanceError}</p> : null}
            {redeemError ? <p className="form-status form-status--error">{redeemError}</p> : null}
            {redeemReceipt ? (
              <section className="voucher-receipt" aria-label="兑换到账收据">
                <div className="quickstart-heading">
                  <div>
                    <h3>{redeemReceipt.status === "replayed" ? "兑换已应用" : "兑换成功"}</h3>
                    <p className="muted-copy">只显示到账结果和安全引用，不回显兑换码。</p>
                  </div>
                  <span className="state-chip state-chip--good">{safeFieldValue(redeemReceipt.status)}</span>
                </div>
                <dl className="detail-list detail-list--three">
                  <div>
                    <dt>到账额度</dt>
                    <dd>{userMoney(redeemReceipt.amount, redeemReceipt.currency)}</dd>
                  </div>
                  <div>
                    <dt>过期时间</dt>
                    <dd>{safeFieldValue(redeemReceipt.validUntil ?? redeemReceipt.expiresAt ?? "未返回过期信息")}</dd>
                  </div>
                  <div>
                    <dt>Credit grant</dt>
                    <dd>{shortId(redeemReceipt.creditGrantId)}</dd>
                  </div>
                  <div>
                    <dt>账本引用</dt>
                    <dd>{shortId(redeemReceipt.ledgerEntryId)}</dd>
                  </div>
                  <div>
                    <dt>Redemption</dt>
                    <dd>{shortId(redeemReceipt.redemptionId)}</dd>
                  </div>
                  <div>
                    <dt>Voucher</dt>
                    <dd>{shortId(redeemReceipt.voucherId)}</dd>
                  </div>
                  <div>
                    <dt>钱包</dt>
                    <dd>{shortId(redeemReceipt.walletId)}</dd>
                  </div>
                  <div>
                    <dt>项目</dt>
                    <dd>{shortId(redeemReceipt.projectId)}</dd>
                  </div>
                  <div>
                    <dt>租户</dt>
                    <dd>{shortId(redeemReceipt.tenantId)}</dd>
                  </div>
                  <div>
                    <dt>Code locator</dt>
                    <dd>{safeFieldValue(redeemReceipt.codeLocator)}</dd>
                  </div>
                </dl>
              </section>
            ) : null}
          </section>

          <section className="admin-panel" aria-label="用户 API 密钥">
            <div className="section-heading">
              <div>
                <h2>开发者访问</h2>
                <p>项目范围内的 API Key。密钥只在创建后允许复制一次。</p>
              </div>
              <button className="secondary-button" type="button" onClick={() => void refreshKeys()} disabled={keysLoading}>
                <RefreshCw aria-hidden="true" size={17} className={keysLoading ? "spin" : undefined} />
                刷新
              </button>
            </div>

            <form className="user-inline-form" onSubmit={createKey}>
              <label className="field">
                Key 名称
                <input
                  value={keyName}
                  onChange={(event) => setKeyName(event.currentTarget.value)}
                  placeholder="生产应用"
                  required
                />
              </label>
              <button className="primary-button primary-button--inline" type="submit">
                <Plus aria-hidden="true" size={17} />
                创建 Key
              </button>
            </form>

            {createdSecret ? (
              <div className="secret-once" aria-label="新建用户 API Key 凭证">
                <div>
                  <strong>{safeFieldValue(createdSecret.name)}</strong>
                  <span>创建成功。页面不会直接渲染原始密钥。</span>
                </div>
                <code aria-label="Masked API key">************************</code>
                <button className="secondary-button" type="button" onClick={() => void copyText("api-key-secret", createdSecret.secret)}>
                  <Copy aria-hidden="true" size={17} />
                  {copiedTarget === "api-key-secret" ? "已复制一次" : "复制 Key 一次"}
                </button>
                <button className="secondary-button" type="button" onClick={() => setCreatedSecret(null)}>
                  <X aria-hidden="true" size={17} />
                  清除
                </button>
              </div>
            ) : null}

            {keyError ? <p className="form-status form-status--error">{keyError}</p> : null}

            <div className="health-table-wrap">
              <table className="health-table admin-table">
                <thead>
                  <tr>
                    <th>名称</th>
                    <th>状态</th>
                    <th>前缀</th>
                    <th>Profile</th>
                    <th>限制</th>
                    <th>操作</th>
                  </tr>
                </thead>
                <tbody>
                  {keysLoading ? (
                    <tr>
                      <td colSpan={6}>正在加载 Key。</td>
                    </tr>
                  ) : keys.length > 0 ? (
                    keys.map((key) => (
                      <tr key={key.id}>
                        <td>
                          <strong>{safeFieldValue(key.name)}</strong>
                          <span>{shortId(key.id)}</span>
                        </td>
                        <td>{safeFieldValue(key.status)}</td>
                        <td>{safeFieldValue(key.key_prefix)}</td>
                        <td>{shortId(key.default_profile_id)}</td>
                        <td>
                          <strong>{userVirtualKeyLimitSummary(key.rate_limit_policy)}</strong>
                          <span>{userVirtualKeyBudgetSummary(key.budget_policy)}</span>
                        </td>
                        <td>
                          <button
                            className="table-action table-action--danger"
                            type="button"
                            onClick={() => void disableKey(key)}
                            disabled={key.status === "disabled" || key.status === "deleted"}
                          >
                            <ShieldOff aria-hidden="true" size={15} />
                            停用
                          </button>
                          <button
                            className="table-action table-action--danger"
                            onClick={() => void deleteKey(key)}
                            disabled={key.status === "deleted"}
                            title="安全软删除此 Key；不会回显 secret。"
                            type="button"
                          >
                            <Trash2 aria-hidden="true" size={15} />
                            删除
                          </button>
                        </td>
                      </tr>
                    ))
                  ) : (
                    <tr>
                      <td colSpan={6}>暂无 API Key。创建 Key 后即可调用 Gateway。</td>
                    </tr>
                  )}
                </tbody>
              </table>
            </div>
          </section>
        </section>

        <section className="admin-panel" aria-label="用户套餐和本地支付 Demo" id="subscription-payment">
          <div className="section-heading">
            <div>
              <h2>套餐和支付 Demo</h2>
              <p>用户可查看套餐目录、当前订阅状态和本地支付 demo 边界；此入口不连接真实商户，不运行续费 scheduler。</p>
            </div>
            <button className="secondary-button" type="button" onClick={() => void refreshSubscriptionOverview()} disabled={subscriptionOverviewLoading}>
              <RefreshCw aria-hidden="true" size={17} className={subscriptionOverviewLoading ? "spin" : undefined} />
              刷新
            </button>
          </div>

          {subscriptionOverviewError ? <p className="form-status form-status--error">{subscriptionOverviewError}</p> : null}

          <dl className="metric-grid metric-grid--four">
            <div>
              <dt>当前订阅</dt>
              <dd>
                {subscriptionOverview
                  ? userSubscriptionStatusLabel(subscriptionOverview.current_subscription.status)
                  : subscriptionOverviewLoading
                    ? "检查中..."
                    : "未加载"}
              </dd>
            </div>
            <div>
              <dt>支付 Demo</dt>
              <dd>{subscriptionOverview?.demo_payment.order_status ?? (subscriptionOverviewLoading ? "检查中..." : "not_created")}</dd>
            </div>
            <div>
              <dt>真实商户</dt>
              <dd>{subscriptionOverview ? String(subscriptionOverview.merchant_connected) : "false"}</dd>
            </div>
            <div>
              <dt>Scheduler</dt>
              <dd>{subscriptionOverview?.scheduler_status ?? "pending_scheduler"}</dd>
            </div>
          </dl>

          <section className="usage-summary-grid" aria-label="用户订阅支付状态">
            <article className="usage-summary-card">
              <div className="quickstart-heading">
                <h3>当前状态</h3>
                <span className={subscriptionOverview?.current_subscription.status === "active" ? "state-chip state-chip--good" : "state-chip state-chip--neutral"}>
                  {subscriptionOverview ? userSubscriptionStatusLabel(subscriptionOverview.current_subscription.status) : "未加载"}
                </span>
              </div>
              <dl className="detail-list">
                <div>
                  <dt>套餐</dt>
                  <dd>{safeFieldValue(subscriptionOverview?.current_subscription.plan_code ?? "未订阅")}</dd>
                </div>
                <div>
                  <dt>订阅额度</dt>
                  <dd>{safeFieldValue(subscriptionOverview?.current_subscription.included_credit_remaining ?? "无订阅额度")}</dd>
                </div>
                <div>
                  <dt>续费状态</dt>
                  <dd>{safeFieldValue(subscriptionOverview?.current_subscription.renewal_status ?? "not_scheduled")}</dd>
                </div>
                <div>
                  <dt>下次续费</dt>
                  <dd>{safeFieldValue(subscriptionOverview?.current_subscription.next_renewal_at ?? "无")}</dd>
                </div>
                <div>
                  <dt>账号余额</dt>
                  <dd>{balance ? userMoney(balance.available_to_spend, balance.currency) : "未加载"}</dd>
                </div>
                <div>
                  <dt>下一步</dt>
                  <dd>{subscriptionOverview?.current_subscription.next_action ?? "刷新套餐支付状态。"}</dd>
                </div>
              </dl>
            </article>

            <article className="usage-summary-card">
              <div className="quickstart-heading">
                <h3>Scheduler Readback</h3>
                <span className="state-chip state-chip--warn">
                  {safeFieldValue(subscriptionOverview?.scheduler_demo?.scheduler_status ?? "pending_scheduler")}
                </span>
              </div>
              <dl className="detail-list">
                <div>
                  <dt>lifecycle</dt>
                  <dd>{safeFieldValue(subscriptionOverview?.scheduler_demo?.lifecycle_state ?? "no_subscription")}</dd>
                </div>
                <div>
                  <dt>upcoming renewal</dt>
                  <dd>
                    {safeFieldValue(subscriptionOverview?.scheduler_demo?.upcoming_renewal?.status ?? "not_scheduled")}
                    {subscriptionOverview?.scheduler_demo?.upcoming_renewal?.due_at
                      ? ` / ${safeFieldValue(subscriptionOverview.scheduler_demo.upcoming_renewal.due_at)}`
                      : ""}
                  </dd>
                </div>
                <div>
                  <dt>grace</dt>
                  <dd>
                    {safeFieldValue(subscriptionOverview?.scheduler_demo?.grace?.status ?? "not_in_grace")}
                    {subscriptionOverview?.scheduler_demo?.grace?.ends_at
                      ? ` / ends ${safeFieldValue(subscriptionOverview.scheduler_demo.grace.ends_at)}`
                      : ""}
                  </dd>
                </div>
                <div>
                  <dt>dunning</dt>
                  <dd>
                    {safeFieldValue(subscriptionOverview?.scheduler_demo?.dunning?.status ?? "not_in_dunning")}
                    {subscriptionOverview?.scheduler_demo?.dunning?.next_attempt_at
                      ? ` / next ${safeFieldValue(subscriptionOverview.scheduler_demo.dunning.next_attempt_at)}`
                      : ""}
                  </dd>
                </div>
                <div>
                  <dt>scheduled events</dt>
                  <dd>{(subscriptionOverview?.scheduler_demo?.scheduled_events.length ?? 0).toLocaleString()} pending</dd>
                </div>
              </dl>
            </article>

            <article className="usage-summary-card">
              <div className="quickstart-heading">
                <h3>本地支付 Demo</h3>
                <span className="state-chip state-chip--warn">local_only</span>
              </div>
              <dl className="detail-list">
                <div>
                  <dt>local_only</dt>
                  <dd>{String(subscriptionOverview?.local_only ?? true)}</dd>
                </div>
                <div>
                  <dt>merchant_connected</dt>
                  <dd>{String(subscriptionOverview?.merchant_connected ?? false)}</dd>
                </div>
                <div>
                  <dt>pending_scheduler</dt>
                  <dd>{String(subscriptionOverview?.pending_scheduler ?? true)}</dd>
                </div>
                <div>
                  <dt>Invoice</dt>
                  <dd>{subscriptionOverview?.demo_payment.invoice_status ?? "placeholder"}</dd>
                </div>
              </dl>
            </article>

            <article className="usage-summary-card">
              <div className="quickstart-heading">
                <h3>安全边界</h3>
                <span className="state-chip state-chip--good">secret_safe</span>
              </div>
              <dl className="detail-list">
                <div>
                  <dt>raw payment payload</dt>
                  <dd>{String(subscriptionOverview?.raw_payment_payload_returned ?? false)}</dd>
                </div>
                <div>
                  <dt>raw invoice metadata</dt>
                  <dd>{String(subscriptionOverview?.raw_invoice_metadata_returned ?? false)}</dd>
                </div>
                <div>
                  <dt>raw idempotency key</dt>
                  <dd>{String(subscriptionOverview?.raw_idempotency_key_echoed ?? false)}</dd>
                </div>
                <div>
                  <dt>真实扣费</dt>
                  <dd>false</dd>
                </div>
              </dl>
            </article>
          </section>

          <div className="health-table-wrap">
            <table className="health-table admin-table">
              <thead>
                <tr>
                  <th>套餐</th>
                  <th>周期</th>
                  <th>价格</th>
                  <th>包含额度</th>
                  <th>支付 / Scheduler</th>
                  <th>状态</th>
                </tr>
              </thead>
              <tbody>
                {subscriptionOverviewLoading ? (
                  <tr>
                    <td colSpan={6}>正在加载套餐。</td>
                  </tr>
                ) : subscriptionOverview?.plans.length ? (
                  subscriptionOverview.plans.map((plan) => (
                    <tr key={plan.id}>
                      <td>
                        <strong>{safeFieldValue(plan.display_name)}</strong>
                        <span>{safeFieldValue(plan.plan_code)}</span>
                      </td>
                      <td>
                        <strong>{userBillingIntervalLabel(plan.billing_interval)}</strong>
                        <span>{plan.trial_days > 0 ? `${plan.trial_days} 天试用` : "无试用期"}</span>
                      </td>
                      <td>{userMoney(plan.unit_price, plan.currency)}</td>
                      <td>{userMoney(plan.included_credit_amount, plan.currency)}</td>
                      <td>
                        <strong>{safeFieldValue(plan.payment_status)}</strong>
                        <span>{safeFieldValue(plan.scheduler_status)}</span>
                      </td>
                      <td>
                        <span className={plan.status === "active" ? "state-chip state-chip--good" : "state-chip state-chip--neutral"}>
                          {safeFieldValue(plan.status)}
                        </span>
                      </td>
                    </tr>
                  ))
                ) : (
                  <tr>
                    <td colSpan={6}>暂无可用套餐。管理员创建 active 套餐或用户侧套餐 API 接入后会在这里显示。</td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>

          <p className="muted-copy">
            用户侧不会显示 invoice raw metadata、idempotency key、支付 provider secret 或 provider payload；当前只展示套餐说明和本地 pending 状态。
          </p>
        </section>

        {(createdSecret || reusableKeyPrefix) ? (
          <section className="quickstart-grid quickstart-grid--sdk" aria-label={createdSecret ? "用户 API 快速开始示例" : "可复用 API 快速开始示例"}>
            <article className="quickstart-card">
              <div className="quickstart-heading">
                <h3>curl</h3>
                <button
                  className="inline-copy-button"
                  type="button"
                  onClick={() => void copyText("curl-example", curlExample)}
                >
                  <Copy aria-hidden="true" size={14} />
                  {copiedTarget === "curl-example" ? "已复制" : "复制"}
                </button>
              </div>
              <p className="muted-copy">
                在本地替换 <code>{USER_API_KEY_PLACEHOLDER}</code>。页面不会打印真实密钥。
                {!createdSecret && reusableKeyPrefix ? ` 当前前缀：${safeFieldValue(reusableKeyPrefix)}。` : ""}
              </p>
              <pre className="json-preview">{curlExample}</pre>
            </article>
            <article className="quickstart-card">
              <div className="quickstart-heading">
                <h3>Node SDK</h3>
                <button
                  className="inline-copy-button"
                  type="button"
                  onClick={() => void copyText("sdk-example", sdkExample)}
                >
                  <Copy aria-hidden="true" size={14} />
                  {copiedTarget === "sdk-example" ? "已复制" : "复制"}
                </button>
              </div>
              <p className="muted-copy">
                Base URL 指向 Gateway 的 <code>/v1</code>；API Key 使用占位符并发送 <code>x-ai-trace-id</code>。
              </p>
              <pre className="json-preview">{sdkExample}</pre>
            </article>
            <article className="quickstart-card">
              <div className="quickstart-heading">
                <h3>Node / Python smoke</h3>
                <button className="inline-copy-button" type="button" onClick={() => void copyText("smoke-node-command", smokeNodeCommand)}>
                  <Copy aria-hidden="true" size={14} />
                  {copiedTarget === "smoke-node-command" ? "已复制" : "复制 Node"}
                </button>
              </div>
              <p className="muted-copy">
                示例路径：<code>tests/integration/sdk-smoke/gateway_user_smoke.mjs</code> 和{" "}
                <code>tests/integration/sdk-smoke/gateway_user_smoke.py</code>。
              </p>
              <dl className="detail-list">
                <div>
                  <dt>环境变量</dt>
                  <dd>
                    <code>GATEWAY_BASE_URL</code> / <code>GATEWAY_API_KEY</code> / <code>SMOKE_MODEL</code>
                  </dd>
                </div>
                <div>
                  <dt>Python 命令</dt>
                  <dd>
                    <button className="inline-copy-button" type="button" onClick={() => void copyText("smoke-python-command", smokePythonCommand)}>
                      <Copy aria-hidden="true" size={14} />
                      {copiedTarget === "smoke-python-command" ? "已复制" : "复制 Python"}
                    </button>
                  </dd>
                </div>
              </dl>
              <pre className="json-preview">{`${smokeEnvironmentExample}\n${smokeNodeCommand}\n${smokePythonCommand}`}</pre>
              <p className="muted-copy">
                smoke 输出会打印 Gateway <code>x-request-id</code> 和客户端 <code>x-ai-trace-id</code>，可在下方请求日志按 request id 或 trace id 回查。
              </p>
            </article>
          </section>
        ) : null}

        <section className="admin-panel" aria-label="用户连接摘要">
          <div className="section-heading">
            <div>
              <h2>连接摘要</h2>
              <p>可用于 SDK 配置和支持排查的安全摘要，不包含密钥。</p>
            </div>
            <button className="secondary-button" type="button" onClick={() => void copyText("connection-summary", connectionSummary)}>
              <Copy aria-hidden="true" size={17} />
              {copiedTarget === "connection-summary" ? "已复制" : "复制摘要"}
            </button>
          </div>
          <dl className="detail-list detail-list--three">
            <div>
              <dt>Gateway</dt>
              <dd>{endpointBaseUrl}</dd>
            </div>
            <div>
              <dt>默认模型</dt>
              <dd>{safeFieldValue(selectedConsoleModel)}</dd>
            </div>
            <div>
              <dt>Key 前缀</dt>
              <dd>{safeFieldValue(reusableKeyPrefix)}</dd>
            </div>
            <div>
              <dt>就绪状态</dt>
              <dd>{readiness ? readiness.state : readinessLoading ? "检查中..." : "刷新就绪状态"}</dd>
            </div>
            <div>
              <dt>余额</dt>
              <dd>{balance ? `${balance.available_to_spend} ${balance.currency}` : balanceLoading ? "检查中..." : "兑换额度"}</dd>
            </div>
            <div>
              <dt>近期请求</dt>
              <dd>{requestCount.toLocaleString()}</dd>
            </div>
          </dl>
          <pre className="json-preview">{connectionSummary}</pre>
        </section>

        <section className="admin-panel" aria-label="账号安全和邮箱验证" id="account-security">
          <div className="section-heading">
            <div>
              <h2>账号安全</h2>
              <p>邮箱验证和账号恢复入口。当前邮件服务未配置时显示 pending，不展示任何 secret。</p>
            </div>
            <span className={emailVerificationResult ? "state-chip state-chip--warn" : "state-chip state-chip--neutral"}>
              {emailVerificationResult ? emailVerificationResult.status : "未请求"}
            </span>
          </div>
          <div className="account-security-grid">
            <article>
              <strong>邮箱验证</strong>
              <span>{session.email}</span>
              <p>{emailVerificationResult ? emailVerificationResult.message : "可请求发送验证邮件；未接入真实邮件服务前保持配置待补齐状态。"}</p>
              <button className="secondary-button" type="button" onClick={() => void requestEmailVerification()} disabled={emailVerificationLoading}>
                {emailVerificationLoading ? "处理中" : "发送验证邮件"}
              </button>
              {emailVerificationError ? <p className="form-status form-status--error">{emailVerificationError}</p> : null}
            </article>
            <article>
              <strong>密码重置</strong>
              <span>登录页可请求</span>
              <p>重置请求统一返回受理状态，不判断或展示账号是否存在；真实邮件 adapter 后续接入。</p>
              <a className="inline-doc-link" href="#overview">
                返回概览
              </a>
            </article>
          </div>
          {emailVerificationResult ? (
            <dl className="detail-list detail-list--three">
              <div>
                <dt>投递状态</dt>
                <dd>{userProductizationStatusSummary(emailVerificationResult)}</dd>
              </div>
              <div>
                <dt>邮件配置</dt>
                <dd>{emailVerificationResult.email_configured ? "已配置" : "config-needed"}</dd>
              </div>
              <div>
                <dt>过期秒数</dt>
                <dd>{emailVerificationResult.expires_in_seconds ?? "未生成 token"}</dd>
              </div>
              <div>
                <dt>代码</dt>
                <dd>{safeFieldValue(emailVerificationResult.code)}</dd>
              </div>
              <div>
                <dt>请求引用</dt>
                <dd>{safeFieldValue(emailVerificationResult.request_id)}</dd>
              </div>
              <div>
                <dt>下一步</dt>
                <dd>{safeFieldValue(emailVerificationResult.next_action)}</dd>
              </div>
            </dl>
          ) : null}
          <dl className="detail-list detail-list--three">
            <div>
              <dt>用户协议版本</dt>
              <dd>{safeFieldValue(session.termsVersion ?? "terms.user_portal.v1")}</dd>
            </div>
            <div>
              <dt>隐私政策版本</dt>
              <dd>{safeFieldValue(session.privacyVersion ?? "privacy.user_portal.v1")}</dd>
            </div>
            <div>
              <dt>接受时间</dt>
              <dd>{safeFieldValue(session.acceptedAt ?? "pending")}</dd>
            </div>
            <div>
              <dt>待确认</dt>
              <dd>{session.pendingAcceptance ? "pending_acceptance" : "current"}</dd>
            </div>
          </dl>
        </section>

        <section className="admin-panel" aria-label="用户计费引用">
          <div className="section-heading">
            <div>
              <h2>计费引用</h2>
              <p>用户可发给管理员用于发放兑换券的安全标识。</p>
            </div>
            <button className="secondary-button" type="button" onClick={() => void copyText("billing-references", billingReferenceSummary)}>
              <Copy aria-hidden="true" size={17} />
              {copiedTarget === "billing-references" ? "已复制" : "复制计费引用"}
            </button>
          </div>
          <dl className="detail-list detail-list--three">
            <div>
              <dt>租户 ID</dt>
              <dd>{session.tenantId}</dd>
            </div>
            <div>
              <dt>项目 ID</dt>
              <dd>{session.projectId}</dd>
            </div>
            <div>
              <dt>钱包 ID</dt>
              <dd>{balance ? balance.wallet_id : "未加载"}</dd>
            </div>
          </dl>
          <p className="muted-copy">这些标识不是 API 密钥。发送支持信息时不要包含 API Key secret 或兑换码。</p>
        </section>

        <section className="admin-panel" aria-label="用户 API 控制台">
          <div className="section-heading">
            <div>
              <h2>API 控制台</h2>
              <p>通过 OpenAI-compatible Gateway 发起 non-stream 或 stream chat 请求。</p>
            </div>
            <span className={createdSecret ? "state-chip state-chip--good" : "state-chip state-chip--neutral"}>
              {createdSecret ? "使用刚创建的 Key" : "粘贴已保存 Key"}
            </span>
          </div>

          <form className="api-console-form" onSubmit={runApiConsole}>
            <label className="field">
              模型
              <select
                aria-label="控制台模型"
                disabled={consoleModelOptions.length === 0 || consoleLoading}
                onChange={(event) => {
                  setConsoleModel(event.currentTarget.value);
                  setConsoleResult(null);
                  setConsoleError(null);
                }}
                value={selectedConsoleModel}
              >
                {consoleModelOptions.length > 0 ? (
                  consoleModelOptions.map((model) => (
                    <option key={model.id} value={model.model}>
                      {model.model}
                    </option>
                  ))
                ) : (
                  <option>{exampleModel}</option>
                )}
              </select>
            </label>
            <label className="field">
              模式
              <select
                aria-label="控制台调用模式"
                disabled={consoleLoading}
                onChange={(event) => {
                  setConsoleMode(event.currentTarget.value as UserConsoleMode);
                  setConsoleResult(null);
                  setConsoleError(null);
                }}
                value={consoleMode}
              >
                <option value="non_stream">non-stream</option>
                <option value="stream">stream</option>
              </select>
            </label>
            {!createdSecret ? (
              <label className="field">
                API 密钥
                <input
                  autoComplete="off"
                  onChange={(event) => setConsoleApiKey(event.currentTarget.value)}
                  placeholder="sk-... 或 vk-..."
                  type="password"
                  value={consoleApiKey}
                />
              </label>
            ) : null}
            <label className="field field--wide">
              提示词
              <textarea
                aria-label="控制台提示词"
                onChange={(event) => setConsolePrompt(event.currentTarget.value)}
                value={consolePrompt}
              />
            </label>
            <label className="field">
              输入 tokens
              <input
                aria-label="估算输入 tokens"
                inputMode="numeric"
                min={0}
                onChange={(event) => setEstimateInputTokens(event.currentTarget.value)}
                type="number"
                value={estimateInputTokens}
              />
            </label>
            <label className="field">
              输出 tokens
              <input
                aria-label="估算输出 tokens"
                inputMode="numeric"
                min={0}
                onChange={(event) => setEstimateOutputTokens(event.currentTarget.value)}
                type="number"
                value={estimateOutputTokens}
              />
            </label>
            <label className="field">
              缓存 tokens
              <input
                aria-label="估算缓存 tokens"
                inputMode="numeric"
                min={0}
                onChange={(event) => setEstimateCacheTokens(event.currentTarget.value)}
                type="number"
                value={estimateCacheTokens}
              />
            </label>
            <label className="field">
              推理 tokens
              <input
                aria-label="估算推理 tokens"
                inputMode="numeric"
                min={0}
                onChange={(event) => setEstimateReasoningTokens(event.currentTarget.value)}
                type="number"
                value={estimateReasoningTokens}
              />
            </label>
            <button className="primary-button primary-button--inline" disabled={consoleLoading || consoleModelOptions.length === 0} type="submit">
              <Network aria-hidden="true" size={17} />
              {consoleLoading ? "运行中" : "运行测试"}
            </button>
            <button className="secondary-button primary-button--inline" disabled={consoleLoading} type="button" onClick={() => void runModelsConsole()}>
              <Route aria-hidden="true" size={17} />
              检查模型
            </button>
          </form>

          {selectedConsoleModelDetail ? (
            <section className="model-detail-card" aria-label="已选控制台模型详情">
              <div className="quickstart-heading">
                <div>
                  <h3>{safeFieldValue(selectedConsoleModelDetail.model)}</h3>
                  <p className="muted-copy">{safeFieldValue(selectedConsoleModelDetail.display_name)}</p>
                </div>
                <span className={selectedConsoleModelDetail.routable ? "state-chip state-chip--good" : "state-chip state-chip--warn"}>
                  {userModelRouteLabel(selectedConsoleModelDetail)}
                </span>
              </div>
              <dl className="detail-list detail-list--three">
                <div>
                  <dt>协议</dt>
                  <dd>
                    <span>{userModelProtocolLabel(selectedConsoleModelDetail)}</span>
                    <span>{selectedConsoleModelDetail.routable ? "按当前用户配置可路由。" : userModelUnavailableSummary(selectedConsoleModelDetail)}</span>
                  </dd>
                </div>
                <div>
                  <dt>上下文</dt>
                  <dd>
                    <span>
                      {selectedConsoleModelDetail.context_length
                        ? `${selectedConsoleModelDetail.context_length.toLocaleString()} tokens`
                        : "未配置上下文"}
                    </span>
                    <span>
                      {selectedConsoleModelDetail.max_output_tokens
                        ? `最大输出 ${selectedConsoleModelDetail.max_output_tokens.toLocaleString()}`
                        : "未配置输出上限"}
                    </span>
                  </dd>
                </div>
                <div>
                  <dt>能力</dt>
                  <dd>
                    <span className="capability-list">
                      {userModelCapabilityLabels(selectedConsoleModelDetail).map((label) => (
                        <span className="capability-chip" key={label}>
                          {label}
                        </span>
                      ))}
                    </span>
                  </dd>
                </div>
                <div>
                  <dt>价格</dt>
                  <dd>
                    <span>{userModelPriceLabel(selectedConsoleModelDetail)}</span>
                    <span>{userModelPriceDetail(selectedConsoleModelDetail)}</span>
                  </dd>
                </div>
              </dl>
              <UserCostEstimatePanel estimate={consoleCostEstimate} />
            </section>
          ) : null}

          {consoleError ? (
            <section className="api-console-result api-console-result--error" aria-label="用户 API 控制台错误">
              <div className="quickstart-heading">
                <h3>{consoleError.title}</h3>
                <span className="state-chip state-chip--danger">
                  {typeof consoleError.status === "number" ? `HTTP ${consoleError.status}` : consoleError.status}
                </span>
              </div>
              <dl className="detail-list">
                <div>
                  <dt>原因</dt>
                  <dd>{consoleError.detail}</dd>
                </div>
                <div>
                  <dt>下一步</dt>
                  <dd>{consoleError.nextStep}</dd>
                </div>
              </dl>
            </section>
          ) : null}
          {consoleResult ? (
            <section className="api-console-result" aria-label="用户 API 控制台结果">
              <div className="quickstart-heading">
                <h3>控制台调用成功</h3>
                <span className="state-chip state-chip--good">HTTP {consoleResult.status}</span>
              </div>
              <dl className="detail-list">
                <div>
                  <dt>模式</dt>
                  <dd>{consoleResult.mode === "stream" ? "stream" : "non-stream"}</dd>
                </div>
                <div>
                  <dt>模型</dt>
                  <dd>{consoleResult.model}</dd>
                </div>
                <div>
                  <dt>Request ID</dt>
                  <dd>
                    <span>{safeFieldValue(consoleResult.requestId)}</span>
                    {consoleResult.requestId ? (
                      <button className="inline-copy-button" type="button" onClick={() => void copyText("console-request-id", consoleResult.requestId ?? "")}>
                        <Copy aria-hidden="true" size={14} />
                        {copiedTarget === "console-request-id" ? "已复制" : "复制"}
                      </button>
                    ) : null}
                  </dd>
                </div>
                <div>
                  <dt>Trace ID</dt>
                  <dd>
                    <span>{safeFieldValue(consoleResult.traceId)}</span>
                    <button className="inline-copy-button" type="button" onClick={() => void copyText("console-trace-id", consoleResult.traceId)}>
                      <Copy aria-hidden="true" size={14} />
                      {copiedTarget === "console-trace-id" ? "已复制" : "复制"}
                    </button>
                  </dd>
                </div>
                <div>
                  <dt>Finish</dt>
                  <dd>{safeFieldValue(consoleResult.finishReason)}</dd>
                </div>
                <div>
                  <dt>响应</dt>
                  <dd>{consoleResult.text}</dd>
                </div>
              </dl>
              {consoleResult.mode === "stream" ? (
                <div className="safe-json-block" aria-label="stream chunk 列表">
                  {consoleResult.chunks.length > 0 ? (
                    consoleResult.chunks.map((chunk) => (
                      <div key={`${chunk.index}-${chunk.content}`}>
                        chunk {chunk.index + 1}: {chunk.content}
                      </div>
                    ))
                  ) : (
                    <div>没有文本 chunk。</div>
                  )}
                </div>
              ) : null}
              <div className="result-next-actions">
                <span>已用 request id/trace id 刷新并定位请求历史；列表只读取当前用户项目的脱敏日志。</span>
                <a href="#monitoring">打开用量</a>
                {consoleResult.requestId ? (
                  <button
                    className="inline-copy-button"
                    type="button"
                    onClick={() =>
                      void focusUserRequestHistory({
                        requestId: consoleResult.requestId,
                        traceId: consoleResult.traceId,
                      })
                    }
                  >
                    按 Request ID 定位
                  </button>
                ) : null}
                <button
                  className="inline-copy-button"
                  type="button"
                  onClick={() =>
                    void focusUserRequestHistory({
                      traceId: consoleResult.traceId,
                    })
                  }
                >
                  按 Trace ID 筛选
                </button>
              </div>
            </section>
          ) : null}
          {consoleModelsResult ? (
            <section className="api-console-result" aria-label="用户 API 模型检查结果">
              <div className="quickstart-heading">
                <h3>模型接口检查成功</h3>
                <span className="state-chip state-chip--good">HTTP {consoleModelsResult.status}</span>
              </div>
              <dl className="detail-list">
                <div>
                  <dt>接口</dt>
                  <dd>/v1/models</dd>
                </div>
                <div>
                  <dt>模型</dt>
                  <dd>返回 {consoleModelsResult.count.toLocaleString()} 个</dd>
                </div>
              </dl>
            </section>
          ) : null}
        </section>

        <section className="admin-panel" aria-label="用户模型和 API 端点" id="models">
          <div className="section-heading">
            <div>
              <h2>模型和端点</h2>
              <p>使用你的 API 密钥调用这些 OpenAI-compatible 端点。</p>
            </div>
            <button className="secondary-button" type="button" onClick={() => void refreshModels()} disabled={modelsLoading}>
              <RefreshCw aria-hidden="true" size={17} className={modelsLoading ? "spin" : undefined} />
              刷新
            </button>
          </div>

          <dl className="detail-list">
            <div>
              <dt>模型接口</dt>
              <dd>
                <span>{modelsEndpoint}</span>
                <button className="inline-copy-button" type="button" onClick={() => void copyText("models-endpoint", modelsEndpoint)}>
                  <Copy aria-hidden="true" size={14} />
                  {copiedTarget === "models-endpoint" ? "已复制" : "复制"}
                </button>
              </dd>
            </div>
            <div>
              <dt>Chat</dt>
              <dd>
                <span>{chatEndpoint}</span>
                <button className="inline-copy-button" type="button" onClick={() => void copyText("chat-endpoint", chatEndpoint)}>
                  <Copy aria-hidden="true" size={14} />
                  {copiedTarget === "chat-endpoint" ? "已复制" : "复制"}
                </button>
              </dd>
            </div>
          </dl>

          {modelsError ? <p className="form-status form-status--error">{modelsError}</p> : null}

          <div className="model-catalog-controls" aria-label="用户模型目录控制">
            <label className="field">
              搜索模型
              <span className="input-with-icon">
                <Search aria-hidden="true" size={16} />
                <input
                  aria-label="搜索模型"
                  onChange={(event) => setModelSearch(event.currentTarget.value)}
                  placeholder="搜索模型、展示名或能力"
                  type="search"
                  value={modelSearch}
                />
              </span>
            </label>
            <label className="field field--checkbox">
              <input
                checked={modelsCallableOnly}
                onChange={(event) => setModelsCallableOnly(event.currentTarget.checked)}
                type="checkbox"
              />
              只看可调用
            </label>
            <span className="state-chip state-chip--neutral">
              显示 {filteredModels.length.toLocaleString()} / {models.length.toLocaleString()}
            </span>
          </div>

          <div className="health-table-wrap">
            <table className="health-table admin-table">
              <thead>
                <tr>
                  <th>模型</th>
                  <th>协议</th>
                  <th>路由</th>
                  <th>限制</th>
                  <th>能力</th>
                  <th>价格</th>
                  <th>操作</th>
                </tr>
              </thead>
              <tbody>
                {modelsLoading ? (
                  <tr>
                    <td colSpan={7}>正在加载模型。</td>
                  </tr>
                ) : filteredModels.length > 0 ? (
                  filteredModels.map((model) => (
                    <tr key={model.id}>
                      <td>
                        <strong>{safeFieldValue(model.model)}</strong>
                        <span>{safeFieldValue(model.display_name)}</span>
                      </td>
                      <td>
                        <strong>{userModelProtocolLabel(model)}</strong>
                        <span>{userModelProtocolDetail(model)}</span>
                      </td>
                      <td>
                        <span className={model.routable ? "state-chip state-chip--good" : "state-chip state-chip--warn"}>
                          {userModelRouteLabel(model)}
                        </span>
                        {!model.routable ? <span>{userModelUnavailableSummary(model)}</span> : null}
                      </td>
                      <td>
                        <strong>{model.context_length ? `${model.context_length.toLocaleString()} 上下文` : "未配置上下文"}</strong>
                        <span>{model.max_output_tokens ? `最大输出 ${model.max_output_tokens.toLocaleString()}` : "未配置输出上限"}</span>
                      </td>
                      <td>
                        <span className="capability-list">
                          {userModelCapabilityLabels(model).map((label) => (
                            <span className="capability-chip" key={label}>
                              {label}
                            </span>
                          ))}
                        </span>
                      </td>
                      <td>
                        <strong>{userModelPriceLabel(model)}</strong>
                        <span>{userModelPriceDetail(model)}</span>
                      </td>
                      <td>
                        <button className="table-action" disabled={!model.routable} type="button" onClick={() => fillConsoleModel(model)}>
                          <Route aria-hidden="true" size={14} />
                          填入控制台
                        </button>
                        <button className="table-action" type="button" onClick={() => void copyText(`model-${model.model}`, model.model)}>
                          <Copy aria-hidden="true" size={14} />
                          {copiedTarget === `model-${model.model}` ? "已复制" : "复制模型"}
                        </button>
                      </td>
                    </tr>
                  ))
                ) : (
                  <tr>
                    <td colSpan={7}>{models.length > 0 ? "当前筛选条件下没有模型。" : "暂无可调用模型。请工作区管理员启用模型路由。"}</td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        </section>

        <section className="admin-panel" aria-label="用户请求日志" id="monitoring">
          <div className="section-heading">
            <div>
              <h2>用量</h2>
              <p>{usageSummary ? `最近 ${usageSummary.window_days} 天用量和请求明细。` : "本项目最近 20 条 OpenAI-compatible API 请求。"}</p>
            </div>
            <button
              className="secondary-button"
              type="button"
              onClick={() => {
                void refreshUsageSummary();
                void refreshLogs();
              }}
              disabled={logsLoading || usageSummaryLoading}
            >
              <RefreshCw aria-hidden="true" size={17} className={logsLoading || usageSummaryLoading ? "spin" : undefined} />
              刷新
            </button>
          </div>

          <div className="segmented-control" aria-label="用量窗口" role="group">
            {USER_USAGE_WINDOWS.map((windowDays) => (
              <button
                aria-pressed={usageWindowDays === windowDays}
                className={`segmented-control__button ${usageWindowDays === windowDays ? "segmented-control__button--active" : ""}`}
                disabled={usageSummaryLoading}
                key={windowDays}
                onClick={() => void changeUsageWindow(windowDays)}
                type="button"
              >
                {windowDays} 天
              </button>
            ))}
          </div>

          {usageSummaryError ? <p className="form-status form-status--error">{usageSummaryError}</p> : null}
          {logsError ? <p className="form-status form-status--error">{logsError}</p> : null}

          <dl className="metric-grid metric-grid--four">
            <div>
              <dt>请求数</dt>
              <dd>{usageSummary ? usageSummary.totals.request_count.toLocaleString() : usageSummaryLoading ? "检查中..." : "暂无请求"}</dd>
            </div>
            <div>
              <dt>成功率</dt>
              <dd>{usageSummary ? userSuccessRate(usageSummary) : usageSummaryLoading ? "检查中..." : "暂无请求"}</dd>
            </div>
            <div>
              <dt>Token 用量</dt>
              <dd>{usageSummary ? usageSummary.totals.total_tokens.toLocaleString() : usageSummaryLoading ? "检查中..." : "暂无 tokens"}</dd>
            </div>
            <div>
              <dt>费用</dt>
              <dd>{usageSummary ? userMoney(usageSummary.totals.total_cost, usageSummary.totals.currency) : usageSummaryLoading ? "检查中..." : "暂无费用"}</dd>
            </div>
          </dl>

          {usageSummary ? (
            <section className="usage-summary-grid" aria-label="用户用量摘要">
              <article className="usage-summary-card">
                <div className="quickstart-heading">
                  <h3>失败</h3>
                  <span className={usageSummary.totals.failed_count > 0 ? "state-chip state-chip--warn" : "state-chip state-chip--good"}>
                    {usageSummary.totals.failed_count.toLocaleString()} 次失败
                  </span>
                </div>
                {usageSummary.top_errors.length > 0 ? (
                  <div className="summary-list">
                    {usageSummary.top_errors.map((error) => (
                      <div key={`${error.error_code}-${error.error_owner ?? "owner"}`}>
                        <strong>{safeFieldValue(error.error_code)}</strong>
                        <span>
                          {error.request_count.toLocaleString()} 次请求
                          {error.retryable_count > 0 ? ` / ${error.retryable_count.toLocaleString()} 次可重试` : ""}
                          {error.error_owner ? ` / ${error.error_owner}` : ""}
                        </span>
                      </div>
                    ))}
                  </div>
                ) : (
                  <p className="muted-copy">当前窗口没有失败。</p>
                )}
              </article>

              <article className="usage-summary-card">
                <div className="quickstart-heading">
                  <h3>按模型</h3>
                  <span className="state-chip state-chip--neutral">显示 {usageSummary.by_model.length} 项</span>
                </div>
                <div className="summary-list">
                  {usageSummary.by_model.length > 0 ? (
                    usageSummary.by_model.slice(0, 5).map((model) => (
                      <div key={model.model}>
                        <strong>{safeFieldValue(model.model)}</strong>
                        <span>
                          {model.request_count.toLocaleString()} 次请求 / {model.total_tokens.toLocaleString()} token / {userMoney(model.total_cost, model.currency)}
                        </span>
                      </div>
                    ))
                  ) : (
                    <p className="muted-copy">当前窗口没有模型用量。</p>
                  )}
                </div>
              </article>

              <article className="usage-summary-card">
                <div className="quickstart-heading">
                  <h3>按 Key</h3>
                  <span className="state-chip state-chip--neutral">显示 {usageSummary.by_key.length} 项</span>
                </div>
                <div className="summary-list">
                  {usageSummary.by_key.length > 0 ? (
                    usageSummary.by_key.slice(0, 5).map((key) => (
                      <div key={key.virtual_key_id ?? key.key_prefix ?? "unknown-key"}>
                        <strong>{safeFieldValue(key.key_name ?? key.key_prefix)}</strong>
                        <span>
                          {key.request_count.toLocaleString()} 次请求 / {key.failed_count.toLocaleString()} 次失败 / {safeFieldValue(key.last_request_at)}
                        </span>
                      </div>
                    ))
                  ) : (
                    <p className="muted-copy">当前窗口没有 Key 用量。</p>
                  )}
                </div>
              </article>
            </section>
          ) : null}

          {usageSummary && billingExplanation ? (
            <section className="billing-explanation-card" aria-label="用户账单说明">
              <div className="section-heading">
                <div>
                  <h3>账单说明</h3>
                  <p>给支持排查使用的费用和用量摘要，不包含原始 prompt 或密钥。</p>
                </div>
                <div className="action-row">
                  <button className="secondary-button" type="button" onClick={() => void copyText("billing-explanation", billingExplanation)}>
                    <Copy aria-hidden="true" size={17} />
                    {copiedTarget === "billing-explanation" ? "已复制" : "复制说明"}
                  </button>
                  <button className="secondary-button" type="button" onClick={() => downloadUserUsageCsv(logs, usageSummary.window_days)}>
                    <ScrollText aria-hidden="true" size={17} />
                    导出 CSV
                  </button>
                </div>
              </div>
              <pre className="json-preview">{billingExplanation}</pre>
            </section>
          ) : null}

          <div className="request-history-toolbar" aria-label="请求历史搜索">
            <label className="field">
              定位请求
              <span className="input-with-icon">
                <Search aria-hidden="true" size={16} />
                <input
                  aria-label="按 request id 或 trace id 搜索请求"
                  onChange={(event) => setRequestSearch(event.currentTarget.value)}
                  placeholder="request id / trace id / client request id"
                  type="search"
                  value={requestSearch}
                />
              </span>
            </label>
            <span className="state-chip state-chip--neutral">{requestSearchSummary}</span>
            <button
              className="secondary-button"
              type="button"
              onClick={() => void searchUserRequestHistory()}
              disabled={logsLoading || requestSearchLoading}
            >
              <Search aria-hidden="true" size={17} />
              {requestSearchLoading ? "搜索中" : "搜索"}
            </button>
            {requestSearch.trim() ? (
              <button
                className="secondary-button"
                type="button"
                onClick={() => {
                  setRequestSearch("");
                  setSelectedLogId(null);
                  void refreshLogs();
                }}
              >
                <X aria-hidden="true" size={17} />
                清除
              </button>
            ) : null}
          </div>

          <div className="health-table-wrap">
            <table className="health-table admin-table">
              <thead>
                <tr>
                  <th>模型</th>
                  <th>状态</th>
                  <th>Request / Trace</th>
                  <th>Usage / Ledger</th>
                  <th>时间</th>
                  <th>操作</th>
                </tr>
              </thead>
              <tbody>
                {logsLoading ? (
                  <tr>
                    <td colSpan={6}>正在加载用量。</td>
                  </tr>
                ) : filteredLogs.length > 0 ? (
                  filteredLogs.map((log) => (
                    <tr className={log.id === selectedLogId ? "request-history-row--active" : undefined} key={log.id}>
                      <td>
                        <strong>{safeFieldValue(log.requested_model ?? log.upstream_model)}</strong>
                        <span>{shortId(log.id)}</span>
                      </td>
                      <td>
                        <span className={requestStatusClass(log.status)}>{safeFieldValue(log.status)}</span>
                        <span>{log.http_status ? `HTTP ${log.http_status}` : "无 HTTP 状态"}</span>
                      </td>
                      <td>
                        <strong>{shortId(log.id)}</strong>
                        <span>Trace {safeFieldValue(shortId(log.trace_id))}</span>
                        {log.client_request_id ? <span>Client {safeFieldValue(shortId(log.client_request_id))}</span> : null}
                      </td>
                      <td>
                        <strong>{userRequestUsageSummary(log)}</strong>
                        <span>{userRequestLedgerSummary(log)}</span>
                      </td>
                      <td>{safeFieldValue(log.completed_at ?? log.created_at)}</td>
                      <td>
                        <button className="table-action" type="button" onClick={() => setSelectedLogId(log.id)}>
                          详情
                        </button>
                      </td>
                    </tr>
                  ))
                ) : (
                  <tr>
                    <td colSpan={6}>{logs.length > 0 ? "当前 request id / trace id 搜索没有命中。" : "暂无请求。可以先运行控制台测试，或用你的 API Key 调用 Gateway。"}</td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>

          {selectedLog ? (
            <section className="request-detail-panel" aria-label="用户请求详情">
              <div className="section-heading">
                <div>
                  <h3>请求详情</h3>
                  <p>用于支持和计费复核的脱敏元数据。</p>
                </div>
                <button className="secondary-button" type="button" onClick={() => setSelectedLogId(null)}>
                  <X aria-hidden="true" size={17} />
                  关闭
                </button>
              </div>

              <section className="trace-summary-card" aria-label="用户 Trace 摘要">
                <div className="quickstart-heading">
                  <h3>Trace 摘要</h3>
                  {traceSummaryLoading ? <span className="state-chip state-chip--neutral">加载中</span> : null}
                  {traceSummary ? (
                    <button className="inline-copy-button" type="button" onClick={() => void copyText("trace-summary-id", traceSummary.trace_id)}>
                      <Copy aria-hidden="true" size={14} />
                      {copiedTarget === "trace-summary-id" ? "已复制" : "复制 trace"}
                    </button>
                  ) : null}
                </div>
                {traceSummaryError ? <p className="form-status form-status--error">{traceSummaryError}</p> : null}
                {traceSummary ? (
                  <>
                    <dl className="metric-grid metric-grid--four">
                      <div>
                        <dt>请求数</dt>
                        <dd>{traceSummary.request_count.toLocaleString()}</dd>
                      </div>
                      <div>
                        <dt>错误数</dt>
                        <dd>{traceSummary.error_count.toLocaleString()}</dd>
                      </div>
                      <div>
                        <dt>Token 用量</dt>
                        <dd>{(traceSummary.total_input_tokens + traceSummary.total_output_tokens).toLocaleString()}</dd>
                      </div>
                      <div>
                        <dt>费用</dt>
                        <dd>{userMoney(traceSummary.total_cost, traceSummary.currencies.join("/") || selectedLog.currency)}</dd>
                      </div>
                    </dl>
                    <div className="trace-request-strip">
                      {traceSummary.requests.slice(0, 6).map((request) => (
                        <button
                          className={`trace-request-node ${request.id === selectedLog.id ? "trace-request-node--active" : ""}`}
                          key={request.id}
                          type="button"
                          onClick={() => setSelectedLogId(request.id)}
                        >
                          <strong>{safeFieldValue(request.requested_model ?? request.upstream_model)}</strong>
                          <span className={requestStatusClass(request.status)}>{safeFieldValue(request.status)}</span>
                        </button>
                      ))}
                    </div>
                    {traceSummary.last_error ? (
                      <p className="muted-copy">
                        最后错误：{safeFieldValue(traceSummary.last_error.code)} / {safeFieldValue(traceSummary.last_error.owner)} / {safeFieldValue(traceSummary.last_error.observed_at)}
                      </p>
                    ) : (
                      <p className="muted-copy">当前窗口没有 trace 错误。</p>
                    )}
                  </>
                ) : !traceSummaryLoading && !traceSummaryError ? (
                  <p className="muted-copy">请求包含 trace id 时会显示 Trace 摘要。</p>
                ) : null}
              </section>

              <section className="trace-summary-card" aria-label="用户请求 usage 和 ledger 摘要">
                <div className="quickstart-heading">
                  <h3>Usage / Ledger 摘要</h3>
                  <span className="state-chip state-chip--neutral">secret-safe</span>
                </div>
                <dl className="metric-grid metric-grid--four">
                  <div>
                    <dt>请求 Token</dt>
                    <dd>{(selectedLog.input_tokens + selectedLog.output_tokens).toLocaleString()}</dd>
                  </div>
                  <div>
                    <dt>请求费用</dt>
                    <dd>{userMoney(selectedLog.final_cost, selectedLog.currency)}</dd>
                  </div>
                  <div>
                    <dt>Trace 费用</dt>
                    <dd>{traceSummary ? userMoney(traceSummary.total_cost, traceSummary.currencies.join("/") || selectedLog.currency) : "未加载"}</dd>
                  </div>
                  <div>
                    <dt>Ledger</dt>
                    <dd>{userRequestLedgerSummary(selectedLog)}</dd>
                  </div>
                </dl>
                <p className="muted-copy">
                  用户侧只展示自己的请求计量、费用和账本结算摘要；不展示 prompt、raw payload、Authorization、API key secret、provider key 或内部 provider payload。
                </p>
              </section>

              <dl className="detail-list detail-list--three">
                <div>
                  <dt>请求</dt>
                  <dd>
                    <span>{selectedLog.id}</span>
                    <button className="inline-copy-button" type="button" onClick={() => void copyText("request-id", selectedLog.id)}>
                      <Copy aria-hidden="true" size={14} />
                      {copiedTarget === "request-id" ? "已复制" : "复制"}
                    </button>
                  </dd>
                </div>
                <div>
                  <dt>Trace</dt>
                  <dd>
                    <span>{safeFieldValue(selectedLog.trace_id)}</span>
                    {selectedLog.trace_id ? (
                      <button className="inline-copy-button" type="button" onClick={() => void copyText("trace-id", selectedLog.trace_id ?? "")}>
                      <Copy aria-hidden="true" size={14} />
                      {copiedTarget === "trace-id" ? "已复制" : "复制"}
                      </button>
                    ) : null}
                  </dd>
                </div>
                <div>
                  <dt>客户端请求</dt>
                  <dd>{safeFieldValue(selectedLog.client_request_id)}</dd>
                </div>
                <div>
                  <dt>状态</dt>
                  <dd>
                    <span className={requestStatusClass(selectedLog.status)}>{safeFieldValue(selectedLog.status)}</span>
                    <span>{selectedLog.http_status ? `HTTP ${selectedLog.http_status}` : "无 HTTP 状态"}</span>
                  </dd>
                </div>
                <div>
                  <dt>错误</dt>
                  <dd>
                    <span>{safeFieldValue(selectedLog.error_code)}</span>
                    <span>{safeFieldValue(selectedLog.error_owner)}</span>
                  </dd>
                </div>
                <div>
                  <dt>重试</dt>
                  <dd>{selectedLog.retryable === null || selectedLog.retryable === undefined ? "未设置" : selectedLog.retryable ? "可重试" : "不可重试"}</dd>
                </div>
                <div>
                  <dt>模型</dt>
                  <dd>
                    <span>{safeFieldValue(selectedLog.requested_model)}</span>
                    <span>{safeFieldValue(selectedLog.upstream_model)}</span>
                  </dd>
                </div>
                <div>
                        <dt>Token 用量</dt>
                  <dd>输入 {selectedLog.input_tokens.toLocaleString()} / 输出 {selectedLog.output_tokens.toLocaleString()}</dd>
                </div>
                <div>
                  <dt>费用</dt>
                  <dd>{safeFieldValue(selectedLog.final_cost)} {safeFieldValue(selectedLog.currency)}</dd>
                </div>
                <div>
                  <dt>延迟</dt>
                  <dd>
                    <span>{selectedLog.latency_ms === null || selectedLog.latency_ms === undefined ? "未记录延迟" : `总计 ${selectedLog.latency_ms} ms`}</span>
                    <span>{selectedLog.ttft_ms === null || selectedLog.ttft_ms === undefined ? "未记录 TTFT" : `TTFT ${selectedLog.ttft_ms} ms`}</span>
                  </dd>
                </div>
                <div>
                  <dt>流式</dt>
                  <dd>
                    <span>{selectedLog.partial_sent ? "已发送部分响应" : "无部分响应"}</span>
                    <span>{safeFieldValue(selectedLog.stream_end_reason)}</span>
                  </dd>
                </div>
                <div>
                  <dt>脱敏</dt>
                  <dd>{safeFieldValue(selectedLog.redaction_status)}</dd>
                </div>
                <div>
                  <dt>请求 Hash</dt>
                  <dd>{safeFieldValue(selectedLog.request_body_hash)}</dd>
                </div>
                <div>
                  <dt>响应 Hash</dt>
                  <dd>{safeFieldValue(selectedLog.response_body_hash)}</dd>
                </div>
                <div>
                  <dt>时间</dt>
                  <dd>
                    <span>{safeFieldValue(selectedLog.created_at)}</span>
                    <span>{safeFieldValue(selectedLog.completed_at)}</span>
                  </dd>
                </div>
              </dl>
            </section>
          ) : null}
        </section>
      </section>
    </main>
  );
}

export function userSessionFromMe(me: UserMeResponse): UserPortalSession {
  return {
    acceptedAt: me.user.accepted_at ?? null,
    email: me.user.email,
    expiresAt: me.session.expires_at,
    name: me.user.display_name || me.user.email.split("@")[0] || "开发者",
    pendingAcceptance: me.user.pending_acceptance ?? false,
    privacyVersion: me.user.privacy_version,
    projectId: me.project.id,
    projectRole: me.project.role,
    tenantId: me.user.tenant_id,
    termsVersion: me.user.terms_version,
    userId: me.user.id,
  };
}

function userAuthFailureMessage(error: unknown): string {
  const code = typeof error === "object" && error !== null && "code" in error ? String((error as { code?: unknown }).code ?? "") : "";
  if (code === "login_rate_limited") {
    return "登录尝试过于频繁。请稍后再试。";
  }

  return USER_AUTH_FAILURE_MESSAGE;
}

function userProductizationStatusSummary(status: UserProductizationStatusResponse): string {
  const mode = status.delivery_mode ?? status.email_delivery;
  const expiry = status.expires_in_seconds === null || status.expires_in_seconds === undefined ? "no-token" : `${status.expires_in_seconds}s`;
  return `${status.status} / ${mode} / ${expiry}`;
}

function joinEndpoint(baseUrl: string, path: string): string {
  return `${baseUrl.replace(/\/+$/, "")}${path}`;
}

function userModelPriceLabel(model: UserModel): string {
  const price = model.price;
  if (!price) {
    return "config-needed";
  }
  if (price.price_summary) {
    return safeFieldValue(price.price_summary);
  }
  const currency = price.currency ? `${price.currency} ` : "";
  const version = price.version ? `v${price.version}` : shortId(price.price_version_id);

  return `当前配置估算 ${currency}${version}`;
}

function userModelPriceDetail(model: UserModel): string {
  const price = model.price;
  if (!price) {
    return "此模型未绑定 active price version；价格不可作为最终账单。";
  }
  if (price.estimate_notice) {
    return safeFieldValue(price.estimate_notice);
  }

  const parts = userPricingRuleSummary(price.pricing_rules);
  if (parts.length === 0) {
    return "Price version 已启用；暂未摘要详细 token 规则。估算，非最终账单。";
  }

  return `${parts.join(" / ")}。估算，非最终账单。`;
}

function UserCostEstimatePanel({ estimate }: { estimate: UserCostEstimate }) {
  const label =
    estimate.status === "ready" ? "余额足够" : estimate.status === "insufficient" ? "余额不足" : "config-needed";
  const chipClass =
    estimate.status === "ready"
      ? "state-chip state-chip--good"
      : estimate.status === "insufficient"
        ? "state-chip state-chip--danger"
        : "state-chip state-chip--warn";

  return (
    <section className="trace-summary-card" aria-label="控制台费用估算">
      <div className="quickstart-heading">
        <div>
          <h3>余额 / 成本预估</h3>
          <p className="muted-copy">按当前 messages/token 输入估算；非最终账单。</p>
        </div>
        <span className={chipClass}>{label}</span>
      </div>
      <dl className="metric-grid metric-grid--four">
        <div>
          <dt>估算 Token</dt>
          <dd>{estimate.tokenTotal.toLocaleString()}</dd>
        </div>
        <div>
          <dt>估算费用</dt>
          <dd>{estimate.estimatedCost ? userMoney(estimate.estimatedCost, estimate.currency) : "config-needed"}</dd>
        </div>
        <div>
          <dt>当前余额</dt>
          <dd>{estimate.balanceNumeric === null ? "未加载" : userMoney(formatUserDecimal(estimate.balanceNumeric), estimate.currency)}</dd>
        </div>
        <div>
          <dt>估算后余额</dt>
          <dd>{estimate.balanceAfter === null ? "未估算" : userMoney(estimate.balanceAfter, estimate.currency)}</dd>
        </div>
      </dl>
      <p className="muted-copy">{estimate.explanation}</p>
      <p className="muted-copy">{estimate.priceDetail}</p>
      <p className="muted-copy">不展示 provider raw、Authorization、API key secret 或 upstream payload。</p>
    </section>
  );
}

function userCostEstimate(input: {
  balance: UserBalance | null;
  estimate: UserCostEstimateInput;
  model: UserModel | null;
}): UserCostEstimate {
  const currency = input.model?.price?.currency?.trim() || input.balance?.currency || "USD";
  const tokenTotal =
    input.estimate.inputTokens +
    input.estimate.outputTokens +
    input.estimate.cacheTokens +
    input.estimate.reasoningTokens;
  const rules = userPriceRules(input.model?.price?.pricing_rules ?? null);
  const priceDetail = input.model ? userModelPriceDetail(input.model) : "请选择模型。";
  const balanceNumeric = numericAmount(input.balance?.available_to_spend);

  if (!input.model?.price || !rules.hasAnyPrice) {
    return {
      balanceAfter: null,
      balanceEnough: null,
      balanceNumeric,
      configNeeded: true,
      currency,
      estimatedCost: null,
      explanation: "config-needed: 此模型缺少 active price version 或可计算 token rate。",
      priceDetail,
      status: "config-needed",
      tokenTotal,
    };
  }

  if (input.balance && input.balance.currency.trim() && currency.trim() && input.balance.currency.trim() !== currency.trim()) {
    return {
      balanceAfter: null,
      balanceEnough: null,
      balanceNumeric,
      configNeeded: true,
      currency,
      estimatedCost: null,
      explanation: `config-needed: 余额单位 ${input.balance.currency} 与价格单位 ${currency} 不一致。`,
      priceDetail,
      status: "config-needed",
      tokenTotal,
    };
  }

  const estimatedCostNumber =
    rules.fixedRequestCost +
    userTokenCost(input.estimate.inputTokens, rules.inputTokenRatePer1m) +
    userTokenCost(input.estimate.outputTokens, rules.outputTokenRatePer1m) +
    userTokenCost(input.estimate.cacheTokens, rules.cacheTokenRatePer1m) +
    userTokenCost(input.estimate.reasoningTokens, rules.reasoningTokenRatePer1m);
  const balanceAfter = balanceNumeric === null ? null : balanceNumeric - estimatedCostNumber;
  const balanceEnough = balanceAfter === null ? null : balanceAfter >= 0;

  return {
    balanceAfter: balanceAfter === null ? null : formatUserDecimal(balanceAfter),
    balanceEnough,
    balanceNumeric,
    configNeeded: balanceEnough === null,
    currency,
    estimatedCost: formatUserDecimal(estimatedCostNumber),
    explanation:
      balanceEnough === null
        ? "config-needed: 余额尚未加载或格式不可解析。"
        : balanceEnough
          ? "估算扣减后仍有可用额度。估算非最终账单，最终费用以请求日志和 ledger 为准。"
          : "估算费用超过当前可用余额，Gateway 可能返回余额不足。",
    priceDetail,
    status: balanceEnough === null ? "config-needed" : balanceEnough ? "ready" : "insufficient",
    tokenTotal,
  };
}

function userTokenCost(tokens: number, ratePer1m: number): number {
  if (!Number.isFinite(tokens) || tokens <= 0 || !Number.isFinite(ratePer1m) || ratePer1m <= 0) {
    return 0;
  }

  return (tokens / 1_000_000) * ratePer1m;
}

function formatUserDecimal(value: number): string {
  if (!Number.isFinite(value)) {
    return "0";
  }

  const fixed = value.toFixed(8).replace(/\.?0+$/, "");
  return fixed === "-0" ? "0" : fixed;
}

function nonNegativeIntegerValue(value: string): number {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 0;
}

function estimateTokensFromMessage(value: string): number {
  const trimmed = value.trim();
  if (!trimmed) {
    return 0;
  }

  return Math.max(1, Math.ceil(trimmed.length / 4));
}

function userPricingRuleSummary(value: unknown): string[] {
  if (!isRecord(value)) {
    return [];
  }

  const rules = userPriceRules(value);
  const parts: string[] = [];
  const currency = rules.currency || stringFromJson(value.currency);
  if (currency) {
    parts.push(currency);
  }

  if (rules.fixedRequestCost > 0) {
    parts.push(`固定 ${formatUserDecimal(rules.fixedRequestCost)}`);
  }
  if (rules.inputTokenRatePer1m > 0) {
    parts.push(`输入 ${formatUserDecimal(rules.inputTokenRatePer1m)}/1M`);
  }
  if (rules.outputTokenRatePer1m > 0) {
    parts.push(`输出 ${formatUserDecimal(rules.outputTokenRatePer1m)}/1M`);
  }
  if (rules.cacheTokenRatePer1m > 0) {
    parts.push(`缓存 ${formatUserDecimal(rules.cacheTokenRatePer1m)}/1M`);
  }
  if (rules.reasoningTokenRatePer1m > 0) {
    parts.push(`推理 ${formatUserDecimal(rules.reasoningTokenRatePer1m)}/1M`);
  }

  return parts.slice(0, 5);
}

function userPriceRules(value: unknown): {
  cacheTokenRatePer1m: number;
  currency: string | null;
  fixedRequestCost: number;
  hasAnyPrice: boolean;
  inputTokenRatePer1m: number;
  outputTokenRatePer1m: number;
  reasoningTokenRatePer1m: number;
} {
  if (!isRecord(value)) {
    return {
      cacheTokenRatePer1m: 0,
      currency: null,
      fixedRequestCost: 0,
      hasAnyPrice: false,
      inputTokenRatePer1m: 0,
      outputTokenRatePer1m: 0,
      reasoningTokenRatePer1m: 0,
    };
  }

  const scale = pricingRulesScale(value);
  const fixedRequestCost = firstNumericField(value, ["fixed_request_cost"], scale);
  const inputTokenRatePer1m = ratePerMillion(value, [
    "input_token_rate_per_1m",
    "input_token_rate_per_million",
    "input_tokens_per_1m",
  ], scale);
  const outputTokenRatePer1m = ratePerMillion(value, [
    "output_token_rate_per_1m",
    "output_token_rate_per_million",
    "output_tokens_per_1m",
  ], scale);
  const cacheTokenRatePer1m = ratePerMillion(value, [
    "cache_token_rate_per_1m",
    "cache_token_rate_per_million",
    "cache_tokens_per_1m",
    "cached_token_rate_per_1m",
    "cached_token_rate_per_million",
    "cached_input_token_rate_per_1m",
    "cached_input_token_rate_per_million",
    "input_cache_token_rate_per_1m",
    "input_cache_token_rate_per_million",
  ], scale);
  const reasoningTokenRatePer1m = ratePerMillion(value, [
    "reasoning_token_rate_per_1m",
    "reasoning_token_rate_per_million",
    "reasoning_tokens_per_1m",
  ], scale);

  return {
    cacheTokenRatePer1m,
    currency: stringFromJson(value.currency),
    fixedRequestCost,
    hasAnyPrice:
      fixedRequestCost > 0 ||
      inputTokenRatePer1m > 0 ||
      outputTokenRatePer1m > 0 ||
      cacheTokenRatePer1m > 0 ||
      reasoningTokenRatePer1m > 0,
    inputTokenRatePer1m,
    outputTokenRatePer1m,
    reasoningTokenRatePer1m,
  };
}

function ratePerMillion(record: Record<string, unknown>, keys: readonly string[], scale: number): number {
  for (const key of keys) {
    const direct = pricingMoneyAmount(record[key], scale);
    if (direct !== null) {
      return direct;
    }
  }

  return 0;
}

function firstNumericField(record: Record<string, unknown>, keys: readonly string[], scale: number): number {
  for (const key of keys) {
    const value = pricingMoneyAmount(record[key], scale);
    if (value !== null) {
      return value;
    }
  }

  return 0;
}

function pricingRulesScale(record: Record<string, unknown>): number {
  const scale = numericAmount(record.scale);
  return scale !== null && Number.isInteger(scale) && scale >= 0 && scale <= 18 ? scale : 8;
}

function pricingMoneyAmount(value: unknown, scale: number): number | null {
  if (typeof value === "number" && Number.isFinite(value) && Number.isInteger(value)) {
    return value / 10 ** scale;
  }

  return numericAmount(value);
}

function numericAmount(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  if (typeof value !== "string") {
    return null;
  }

  const parsed = Number(value.trim());
  return Number.isFinite(parsed) ? parsed : null;
}

function userModelProtocolLabel(model: UserModel): string {
  const modes = userModelProtocolModes(model);
  if (modes.length === 0) {
    return "协议未返回";
  }

  return modes.map(userProtocolLabel).join(" / ");
}

function userModelProtocolDetail(model: UserModel): string {
  if (model.routable) {
    return "用户侧安全聚合，不含 provider key 或上游 raw details。";
  }

  return userModelUnavailableSummary(model);
}

function userModelProtocolModes(model: UserModel): string[] {
  const modes = Array.isArray(model.protocol_modes) ? model.protocol_modes : [];
  const values = [model.primary_protocol, ...modes]
    .filter((value): value is string => typeof value === "string" && value.trim().length > 0)
    .map((value) => value.trim());

  return [...new Set(values)];
}

function userProtocolLabel(value: string): string {
  const normalized = value.trim().toLowerCase().replace(/_/g, "-");
  const labels: Record<string, string> = {
    anthropic: "Anthropic Messages",
    "anthropic-messages": "Anthropic Messages",
    "claude-compatible": "Claude-compatible",
    gemini: "Gemini generateContent",
    "gemini-generate-content": "Gemini generateContent",
    "openai-compatible": "OpenAI-compatible",
    openai: "OpenAI-compatible",
  };

  return labels[normalized] ?? safeFieldValue(value);
}

function userModelUnavailableSummary(model: UserModel): string {
  if (model.routable) {
    return "可调用。";
  }

  const reasons = userModelUnavailableReasons(model);
  if (reasons.length === 0) {
    return "请工作区管理员启用此模型路由。";
  }

  return reasons.map(userModelUnavailableReasonLabel).join(" / ");
}

function userModelUnavailableReasons(model: UserModel): string[] {
  const values = [
    ...(Array.isArray(model.unavailable_reasons) ? model.unavailable_reasons : []),
    model.unavailable_reason,
    model.route_status && model.route_status !== "routable" ? model.route_status : null,
  ];

  return values.filter((value): value is string => typeof value === "string" && value.trim().length > 0);
}

function userModelUnavailableReasonLabel(value: string): string {
  const normalized = value.trim().toLowerCase();
  const labels: Record<string, string> = {
    disabled: "模型已停用",
    no_enabled_channel: "没有启用的上游通道",
    no_enabled_model_mapping: "没有启用的模型映射",
    no_enabled_provider: "供应商未启用",
    no_routable_route: "没有可用路由",
    not_routable: "没有可用路由",
    price_config_needed: "价格未配置",
    profile_denied: "当前 Profile 拒绝此模型",
    route_config_needed: "路由需要配置",
  };

  return labels[normalized] ?? safeFieldValue(value.replace(/_/g, " "));
}

function userModelCapabilityLabels(model: UserModel): string[] {
  const labels = [
    model.supports_stream ? "流式" : null,
    model.supports_tools ? "工具" : null,
    model.supports_vision ? "视觉" : null,
    model.supports_audio ? "音频" : null,
    model.supports_reasoning ? "推理" : null,
  ].filter((label): label is string => Boolean(label));

  return labels.length > 0 ? labels : ["对话"];
}

function userVirtualKeyLimitSummary(value: unknown): string {
  if (!isRecord(value) || Object.keys(value).length === 0) {
    return "默认限流";
  }

  const parts = [
    jsonLimitPart(value, ["rpm", "requests_per_minute", "request_per_minute"], "RPM"),
    jsonLimitPart(value, ["tpm", "tokens_per_minute", "token_per_minute"], "TPM"),
    jsonLimitPart(value, ["concurrency", "concurrent_requests", "max_concurrency"], "并发"),
  ].filter((part): part is string => Boolean(part));

  return parts.length > 0 ? parts.join(" / ") : "自定义限流";
}

function userVirtualKeyBudgetSummary(value: unknown): string {
  if (!isRecord(value) || Object.keys(value).length === 0) {
    return "默认预算";
  }

  const amount = jsonLimitPart(value, ["max_cost", "monthly_budget", "budget"], "预算");
  const reset = stringFromJson(value.reset) ?? stringFromJson(value.window) ?? stringFromJson(value.period);

  return [amount, reset].filter((part): part is string => Boolean(part)).join(" / ") || "自定义预算";
}

function jsonLimitPart(record: Record<string, unknown>, keys: readonly string[], label: string): string | null {
  for (const key of keys) {
    const value = stringFromJson(record[key]);
    if (value) {
      return `${label} ${safeFieldValue(value)}`;
    }
  }

  return null;
}

function filterUserModels(models: UserModel[], search: string, callableOnly: boolean): UserModel[] {
  const terms = search
    .trim()
    .toLowerCase()
    .split(/\s+/)
    .filter(Boolean);

  return models.filter((model) => {
    if (callableOnly && !model.routable) {
      return false;
    }
    if (terms.length === 0) {
      return true;
    }

    const haystack = [
      model.model,
      model.display_name,
      model.family,
      userModelProtocolLabel(model),
      userModelRouteLabel(model),
      userModelUnavailableSummary(model),
      userModelPriceLabel(model),
      userModelPriceDetail(model),
      userModelCapabilityLabels(model).join(" "),
    ]
      .filter(Boolean)
      .join(" ")
      .toLowerCase();

    return terms.every((term) => haystack.includes(term));
  });
}

function preferredExampleModel(models: UserModel[]): string {
  return models.find((model) => model.routable)?.model ?? models[0]?.model ?? "model-name";
}

function userModelRouteLabel(model: UserModel): string {
  if (model.routable) {
    return `${model.routable_channel_count} 条路由`;
  }

  return "不可调用";
}

function userReadinessSummary(readiness: UserReadiness): string {
  const parts = [
    `${readiness.counts.routable_models}/${readiness.counts.available_models} 个可调用模型`,
    `${readiness.counts.active_keys} 个可用密钥`,
    `${readiness.counts.recent_requests} 次请求`,
  ];

  return `${readiness.next_action}. ${parts.join(" / ")}.`;
}

function userConnectionSummary(input: {
  activeKeyCount: number;
  balance: UserBalance | null;
  gatewayBaseUrl: string;
  model: string;
  projectId: string;
  readiness: UserReadiness | null;
  requestCount: number;
  reusableKeyPrefix: string | null;
  routableModelCount: number;
}): string {
  return [
    "AI Gateway 连接摘要",
    `网关地址：${input.gatewayBaseUrl}`,
    `默认模型：${safeFieldValue(input.model)}`,
    `项目：${shortId(input.projectId)}`,
    `就绪状态：${input.readiness?.state ?? "未加载"}`,
    `可调用模型：${input.routableModelCount.toLocaleString()}`,
    `可用 API 密钥：${input.activeKeyCount.toLocaleString()}`,
    `API 密钥前缀：${safeFieldValue(input.reusableKeyPrefix)}`,
    `余额：${input.balance ? `${input.balance.available_to_spend} ${input.balance.currency}` : "未加载"}`,
    `近期请求：${input.requestCount.toLocaleString()}`,
    "密钥策略：不包含原始 API 密钥、Authorization header、provider key 或 payload body。",
  ].join("\n");
}

function userBillingReferenceSummary(input: {
  currency: string | null;
  projectId: string;
  tenantId: string;
  userId: string;
  walletId: string | null;
}): string {
  return [
    "AI Gateway 计费引用",
    `Tenant ID: ${input.tenantId}`,
    `Project ID: ${input.projectId}`,
    `Wallet ID: ${input.walletId ?? "未加载"}`,
    `User ID: ${input.userId}`,
    `Currency: ${input.currency ?? "未加载"}`,
    "密钥策略：不要包含 API 密钥、voucher code、Authorization header、provider key 或请求 payload。",
  ].join("\n");
}

function userBillingExplanation(input: { logs: UserRequestLogSummary[]; summary: UserUsageSummary }): string {
  const { logs, summary } = input;
  const topModel = summary.by_model[0] ?? null;
  const topKey = summary.by_key[0] ?? null;
  const topError = summary.top_errors[0] ?? null;
  const costPerRequest = decimalDivide(summary.totals.total_cost, summary.totals.request_count);
  const latestRequest = logs[0] ?? null;

  return [
    "AI Gateway 账单说明",
    `窗口：最近 ${summary.window_days} 天`,
    `请求：共 ${summary.totals.request_count.toLocaleString()} 次 / 成功 ${summary.totals.success_count.toLocaleString()} 次 / 失败 ${summary.totals.failed_count.toLocaleString()} 次`,
    `Token 用量：输入 ${summary.totals.input_tokens.toLocaleString()} / 输出 ${summary.totals.output_tokens.toLocaleString()} / 合计 ${summary.totals.total_tokens.toLocaleString()}`,
    `费用：${userMoney(summary.totals.total_cost, summary.totals.currency)}`,
    `单次平均费用：${costPerRequest ? userMoney(costPerRequest, summary.totals.currency) : "暂无"}`,
    `最高用量模型：${topModel ? `${safeFieldValue(topModel.model)}（${topModel.request_count.toLocaleString()} 次请求，${userMoney(topModel.total_cost, topModel.currency)}）` : "暂无"}`,
    `最高用量 API Key：${topKey ? `${safeFieldValue(topKey.key_name ?? topKey.key_prefix)}（${topKey.request_count.toLocaleString()} 次请求，${userMoney(topKey.total_cost, topKey.currency)}）` : "暂无"}`,
    `最高频失败：${topError ? `${safeFieldValue(topError.error_code)}（${topError.request_count.toLocaleString()} 次请求${topError.error_owner ? `，${topError.error_owner}` : ""}）` : "无"}`,
    `最新请求：${latestRequest ? `${shortId(latestRequest.id)} / ${safeFieldValue(latestRequest.status)} / ${safeFieldValue(latestRequest.completed_at ?? latestRequest.created_at)}` : "暂无"}`,
    "密钥策略：此说明不包含原始 prompt、响应正文、Authorization header、API key secret、voucher code、provider key 或内部 provider routing 字段。",
  ].join("\n");
}

function decimalDivide(amount: string, divisor: number): string | null {
  if (divisor <= 0) {
    return null;
  }

  const parsed = Number(amount);
  if (!Number.isFinite(parsed)) {
    return null;
  }

  return (parsed / divisor).toFixed(8);
}

function downloadUserUsageCsv(logs: UserRequestLogSummary[], windowDays: number) {
  const headers = ["request_id", "trace_id", "model", "status", "http_status", "input_tokens", "output_tokens", "cost", "currency", "created_at", "completed_at"];
  const rows = logs.map((log) => [
    log.id,
    log.trace_id ?? "",
    log.requested_model ?? log.upstream_model ?? "",
    log.status,
    log.http_status ?? "",
    log.input_tokens,
    log.output_tokens,
    log.final_cost,
    log.currency,
    log.created_at,
    log.completed_at ?? "",
  ]);
  const csv = [headers, ...rows].map((row) => row.map(csvCell).join(",")).join("\n");
  const blob = new Blob([`${csv}\n`], { type: "text/csv;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = `ai-gateway-usage-${windowDays}d.csv`;
  document.body.appendChild(anchor);
  anchor.click();
  document.body.removeChild(anchor);
  URL.revokeObjectURL(url);
}

function userRequestLogFiltersForFocus(focus?: UserRequestHistoryFocus) {
  const requestId = normalizeRequestQueryValue(focus?.requestId ?? "");
  const traceId = normalizeRequestQueryValue(focus?.traceId ?? "");
  if (requestId) {
    return {
      limit: 20,
      request_id: requestId,
    };
  }
  if (traceId) {
    return {
      limit: 20,
      trace_id: traceId,
    };
  }

  return { limit: 20 };
}

function localUserRequestLogFallback({
  currentLogs,
  focus,
  recentLogs,
  remoteLogs,
}: {
  currentLogs: UserRequestLogSummary[];
  focus: UserRequestHistoryFocus;
  recentLogs: UserRequestLogSummary[];
  remoteLogs: UserRequestLogSummary[];
}): UserRequestLogSummary[] | null {
  if (findUserRequestLog(remoteLogs, focus)) {
    return null;
  }

  const requestId = normalizeRequestQueryValue(focus.requestId ?? "");
  const traceId = normalizeRequestQueryValue(focus.traceId ?? "");
  if (!requestId && !traceId) {
    return null;
  }

  const fallbackSource = recentLogs.length > 0 ? recentLogs : currentLogs;
  const localMatches = fallbackSource.filter((log) => userRequestLogMatchesFocus(log, { requestId, traceId }));
  return localMatches;
}

function filterUserRequestLogs(logs: UserRequestLogSummary[], search: string): UserRequestLogSummary[] {
  const normalizedSearch = normalizeRequestSearch(search);
  if (!normalizedSearch) {
    return logs;
  }

  return logs.filter((log) => userRequestSearchValues(log).some((value) => normalizeRequestSearch(value).includes(normalizedSearch)));
}

function findUserRequestLog(logs: UserRequestLogSummary[], focus: UserRequestHistoryFocus): UserRequestLogSummary | null {
  return logs.find((log) => userRequestLogMatchesFocus(log, focus)) ?? null;
}

function userRequestLogMatchesFocus(log: UserRequestLogSummary, focus: UserRequestHistoryFocus): boolean {
  const requestId = normalizeRequestSearch(focus.requestId ?? "");
  const traceId = normalizeRequestSearch(focus.traceId ?? "");
  const logRequestId = normalizeRequestSearch(log.id);
  const logClientRequestId = normalizeRequestSearch(log.client_request_id ?? "");
  const logTraceId = normalizeRequestSearch(log.trace_id ?? "");

  if (requestId && (logRequestId === requestId || logClientRequestId === requestId)) {
    return true;
  }

  return Boolean(traceId && logTraceId === traceId);
}

function userRequestSearchValues(log: UserRequestLogSummary): string[] {
  return [
    log.id,
    log.trace_id ?? "",
    log.client_request_id ?? "",
    log.requested_model ?? "",
    log.upstream_model ?? "",
    log.status,
    log.error_code ?? "",
  ];
}

function normalizeRequestSearch(value: string): string {
  return value.trim().toLowerCase();
}

function normalizeRequestQueryValue(value: string): string {
  return value.trim();
}

function userRequestSearchSummary(
  search: string,
  logs: UserRequestLogSummary[],
  filteredLogs: UserRequestLogSummary[],
): string {
  if (!search.trim()) {
    return `最近 ${logs.length.toLocaleString()} 条`;
  }

  return `命中 ${filteredLogs.length.toLocaleString()} / ${logs.length.toLocaleString()} 条`;
}

function userRequestUsageSummary(log: UserRequestLogSummary): string {
  const totalTokens = log.input_tokens + log.output_tokens;
  return `${totalTokens.toLocaleString()} token / ${userMoney(log.final_cost, log.currency)}`;
}

function userRequestLedgerSummary(log: UserRequestLogSummary): string {
  const status = log.status.trim().toLowerCase();
  if (status === "succeeded" || status === "success" || status === "completed") {
    return `settled ${userMoney(log.final_cost, log.currency)}`;
  }
  if (status === "failed" || status === "error" || status === "rejected") {
    return log.final_cost === "0" || log.final_cost === "0.00" || log.final_cost === "0.00000000"
      ? "无最终扣费"
      : `异常结算 ${userMoney(log.final_cost, log.currency)}`;
  }

  return `计费状态 ${safeFieldValue(log.status)}`;
}

function csvCell(value: unknown): string {
  const text = value === null || value === undefined ? "" : String(value);
  return `"${text.replaceAll('"', '""')}"`;
}

function userReadinessStatusClass(status: UserReadinessCheck["status"]): "ready" | "attention" | "blocked" {
  if (status === "ready" || status === "attention" || status === "blocked") {
    return status;
  }

  return "attention";
}

function userSubscriptionStatusLabel(status: UserSubscriptionPaymentOverview["current_subscription"]["status"]): string {
  const normalized = status.trim().toLowerCase();
  const labels: Record<string, string> = {
    active: "已订阅",
    cancelled: "已取消",
    expired: "已过期",
    none: "未订阅",
    pending: "待处理",
  };

  return labels[normalized] ?? safeFieldValue(status);
}

function userBillingIntervalLabel(interval: UserSubscriptionPlanSummary["billing_interval"]): string {
  const normalized = interval.trim().toLowerCase();
  const labels: Record<string, string> = {
    month: "月付",
    one_time: "一次性",
    year: "年付",
  };

  return labels[normalized] ?? safeFieldValue(interval);
}

function userOperatorSetupGaps(readiness: UserReadiness | null): Array<{ code: string; label: string; nextAction: string }> {
  if (!readiness) {
    return [];
  }

  return readiness.checks
    .filter((check) => {
      if (check.status !== "blocked" && check.status !== "attention") {
        return false;
      }
      return check.code === "wallet" || check.code === "profile" || check.code === "model";
    })
    .map((check) => ({
      code: check.code,
      label: check.label,
      nextAction: operatorSetupNextAction(check),
    }));
}

function operatorSetupNextAction(check: UserReadinessCheck): string {
  if (check.code === "profile") {
    return "为此项目创建或启用默认 API Key Profile。";
  }
  if (check.code === "model") {
    return check.status === "attention"
      ? "把可见模型绑定到已启用的 upstream channel。"
      : "通过默认 Profile 发布模型，并绑定到已启用的 channel。";
  }
  if (check.code === "wallet") {
    return "用户兑换 voucher 前，先检查项目钱包是否已 provision。";
  }
  return check.next_action;
}

function userSuccessRate(summary: UserUsageSummary): string {
  if (summary.totals.request_count <= 0) {
    return "暂无请求";
  }

  return `${Math.round((summary.totals.success_count / summary.totals.request_count) * 100)}%`;
}

function userUsageTotalsSuccessRate(totals: UserUsageTotals): string {
  if (totals.request_count <= 0) {
    return "暂无请求";
  }

  return `${Math.round((totals.success_count / totals.request_count) * 100)}%`;
}

function userMoney(amount: string, currency: string): string {
  const trimmed = amount.trim();
  const normalized = trimmed && trimmed !== "0" ? trimmed : "0";

  return `${normalized} ${currency}`.trim();
}

function requestStatusClass(status: string): string {
  const normalized = status.trim().toLowerCase();
  if (["succeeded", "success", "completed"].includes(normalized)) {
    return "state-chip state-chip--good";
  }
  if (["failed", "error", "rejected"].includes(normalized)) {
    return "state-chip state-chip--danger";
  }
  if (["pending", "running", "started"].includes(normalized)) {
    return "state-chip state-chip--warn";
  }

  return "state-chip state-chip--neutral";
}

function userVoucherRefusalMessage(code: string | null | undefined): string {
  const normalized = (code ?? "").trim().toLowerCase();
  if (!normalized) {
    return "兑换券无法兑换。";
  }

  const messages: Record<string, string> = {
    already_redeemed: "此兑换券已被兑换。",
    currency_mismatch: "此兑换券的钱包币种不匹配。",
    expired: "此兑换券已过期。",
    invalid_code: "兑换码无效。",
    max_redemptions_exceeded: "此兑换券已达到兑换上限。",
    project_mismatch: "此兑换券未分配给当前项目。",
    replayed: "此兑换请求已应用过。",
    revoked: "此兑换券已停用。",
    voucher_not_found: "兑换码无效。",
    wallet_mismatch: "此兑换券未分配给当前钱包。",
  };

  return messages[normalized] ?? `兑换券无法兑换：${normalized.replace(/_/g, " ")}。`;
}

function userVoucherRequestErrorMessage(error: unknown): string {
  const code = typeof error === "object" && error !== null && "code" in error ? String((error as { code?: unknown }).code ?? "") : "";
  return code ? userVoucherRefusalMessage(code) : errorMessage(error);
}

function userConsoleAssistantText(payload: unknown): string {
  if (!isRecord(payload)) {
    return "响应不是 JSON 对象。";
  }

  const choices = Array.isArray(payload.choices) ? payload.choices : [];
  const firstChoice = choices.find(isRecord);
  const message = isRecord(firstChoice?.message) ? firstChoice.message : null;
  const content = stringFromJson(message?.content);
  if (content) {
    return content;
  }

  const text = stringFromJson(firstChoice?.text);
  if (text) {
    return text;
  }

  return "已收到响应，但没有返回 assistant 文本。";
}

type UserConsoleStreamReadResult = {
  chunks: UserConsoleChunk[];
  errorPayload: unknown;
  finishReason: string | null;
  model: string | null;
  requestId: string | null;
  text: string;
};

async function readUserConsoleStream(response: Response): Promise<UserConsoleStreamReadResult> {
  if (!response.body) {
    const payload = await response.json().catch(() => null);
    return {
      chunks: [],
      errorPayload: response.ok ? null : payload,
      finishReason: null,
      model: null,
      requestId: null,
      text: "",
    };
  }

  const decoder = new TextDecoder();
  const reader = response.body.getReader();
  const chunks: UserConsoleChunk[] = [];
  const rawParts: string[] = [];
  let buffer = "";
  let errorPayload: unknown = null;
  let finishReason: string | null = null;
  let model: string | null = null;
  let requestId: string | null = null;

  function consumeBlock(block: string) {
    const dataLines = block
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line) => line.startsWith("data:"))
      .map((line) => line.slice("data:".length).trim());

    for (const dataLine of dataLines) {
      if (!dataLine || dataLine === "[DONE]") {
        continue;
      }
      rawParts.push(dataLine);
      const payload = parseJsonLine(dataLine);
      if (!payload) {
        continue;
      }
      if (isRecord(payload) && isRecord(payload.error)) {
        errorPayload = payload;
        continue;
      }

      model = stringFromJson(isRecord(payload) ? payload.model : null) ?? model;
      requestId = stringFromJson(isRecord(payload) ? payload.id : null) ?? requestId;
      finishReason = userConsoleFinishReason(payload) ?? finishReason;
      const content = userConsoleStreamChunkText(payload);
      if (content) {
        chunks.push({
          content,
          index: chunks.length,
        });
      }
    }
  }

  while (true) {
    const { done, value } = await reader.read();
    if (done) {
      break;
    }

    buffer += decoder.decode(value, { stream: true });
    const blocks = buffer.split(/\r?\n\r?\n/);
    buffer = blocks.pop() ?? "";
    blocks.forEach(consumeBlock);
  }

  buffer += decoder.decode();
  if (buffer.trim()) {
    consumeBlock(buffer);
  }

  if (!response.ok && !errorPayload) {
    errorPayload = parseJsonLine(rawParts.join("\n")) ?? { error: { message: "Gateway stream request failed." } };
  }

  return {
    chunks,
    errorPayload,
    finishReason,
    model,
    requestId,
    text: chunks.map((chunk) => chunk.content).join(""),
  };
}

function parseJsonLine(value: string): unknown | null {
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

function userConsoleStreamChunkText(payload: unknown): string | null {
  if (!isRecord(payload)) {
    return null;
  }

  const choices = Array.isArray(payload.choices) ? payload.choices : [];
  const firstChoice = choices.find(isRecord);
  const delta = isRecord(firstChoice?.delta) ? firstChoice.delta : null;
  const content = stringFromJson(delta?.content) ?? stringFromJson(firstChoice?.text);

  return content ? redactUserConsoleStreamText(content) : null;
}

function userConsoleFinishReason(payload: unknown): string | null {
  if (!isRecord(payload)) {
    return null;
  }

  const choices = Array.isArray(payload.choices) ? payload.choices : [];
  const firstChoice = choices.find(isRecord);
  return stringFromJson(firstChoice?.finish_reason);
}

function redactUserConsoleStreamText(value: string): string {
  const redacted = safeFieldValue(value)
    .replace(/\b(prompt|payload|request_body|response_body|messages?)\b\s*[:=]\s*[^,;}\n]+/gi, "$1=[redacted]")
    .replace(/\b(provider[_\s-]?key|upstream[_\s-]?key|raw[_\s-]?key|authorization)\b\s*[:=]\s*[^,;}\n]+/gi, "$1=[redacted]");

  if (/\b(?:bearer\s+[a-z0-9._-]+|sk-[a-z0-9._-]+|vk-[a-z0-9._-]+)\b/i.test(redacted)) {
    return "[redacted]";
  }

  return redacted;
}

function userGatewayModelCount(payload: unknown): number {
  if (!isRecord(payload)) {
    return 0;
  }
  const data = Array.isArray(payload.data) ? payload.data : [];

  return data.length;
}

function userConsoleFailure(status: number, payload: unknown): UserConsoleFailure {
  const message =
    isRecord(payload) && isRecord(payload.error)
      ? stringFromJson(payload.error.message)
      : null;
  const code =
    isRecord(payload) && isRecord(payload.error)
      ? stringFromJson(payload.error.code)
      : null;
  const suffix = redactUserConsoleErrorText([code, message].filter(Boolean).join(": "));

  if (status === 401 || status === 403) {
    return {
      detail: suffix || "Gateway 拒绝了这个 API Key。",
      nextStep: "创建新的用户 API Key，或粘贴此账号有效的已保存 Key。",
      status,
      title: "API Key 被拒绝",
    };
  }

  if (status === 402) {
    return {
      detail: suffix || "Gateway 因为此账号没有可用额度而拒绝请求。",
      nextStep: "先兑换 voucher，再刷新余额并重新运行测试。",
      status,
      title: "余额不足",
    };
  }

  if (status === 404) {
    return {
      detail: suffix || "当前路由配置下无法使用所选模型。",
      nextStep: "选择其他可路由模型，或请管理员启用此模型/channel。",
      status,
      title: "模型不可用",
    };
  }

  if (status === 429) {
    return {
      detail: suffix || "账号或路由当前触发限流。",
      nextStep: "等待限流窗口重置，或请管理员调整 API Key Profile。",
      status,
      title: "已触发限流",
    };
  }

  if (status >= 500) {
    return {
      detail: suffix || "Gateway 或 upstream provider 返回内部错误。",
      nextStep: "可重试一次；如果持续失败，请在管理控制台检查 provider/channel 健康状态。",
      status,
      title: "Gateway 或 provider 错误",
    };
  }

  return {
    detail: suffix || "Gateway 对此请求返回错误。",
    nextStep: "检查所选模型、prompt 和账号状态，然后重新运行测试。",
    status,
    title: "控制台调用失败",
  };
}

function redactUserConsoleErrorText(value: string): string {
  if (!value.trim()) {
    return "";
  }

  const redacted = safeFieldValue(value)
    .replace(/\b(prompt|payload|request_body|response_body|messages?)\b\s*[:=]\s*[^,;}\n]+/gi, "$1=[redacted]")
    .replace(/\b(provider[_\s-]?key|upstream[_\s-]?key|raw[_\s-]?key)\b\s*[:=]\s*[^,;}\n]+/gi, "$1=[redacted]")
    .replace(/\b(channel|provider)\s+secret\s*[:=]\s*[^,;}\n]+/gi, "$1 secret=[redacted]");

  if (
    redacted === "[redacted]" ||
    /\b(?:authorization|cookie|password|secret|token|prompt|payload|messages?|provider[_\s-]?key|upstream[_\s-]?key|raw[_\s-]?payload|raw[_\s-]?key)\b/i.test(redacted)
  ) {
    return "上游返回了已隐藏的敏感错误详情。";
  }

  return redacted;
}

function userCurlExample(chatEndpoint: string, secret: string, model: string): string {
  return [
    `curl ${quoteShell(chatEndpoint)} \\`,
    `  -H ${quoteShell(`Authorization: Bearer ${secret}`)} \\`,
    `  -H ${quoteShell("Content-Type: application/json")} \\`,
    `  -H ${quoteShell("x-ai-trace-id: user-console-smoke")} \\`,
    `  -d ${quoteShell(JSON.stringify({ model, messages: [{ role: "user", content: "ping" }], stream: false }))}`,
  ].join("\n");
}

function userOpenAiSdkExample(gatewayBaseUrl: string, secret: string, model: string): string {
  return [
    `import OpenAI from "openai";`,
    ``,
    `const client = new OpenAI({`,
    `  apiKey: ${JSON.stringify(secret)},`,
    `  baseURL: ${JSON.stringify(joinEndpoint(gatewayBaseUrl, "/v1"))},`,
    `  defaultHeaders: { "x-ai-trace-id": "user-console-sdk" },`,
    `});`,
    ``,
    `const response = await client.chat.completions.create({`,
    `  model: ${JSON.stringify(model)},`,
    `  messages: [{ role: "user", content: "ping" }],`,
    `});`,
    ``,
    `console.log(response.id);`,
  ].join("\n");
}

function userSmokeEnvironmentExample(gatewayBaseUrl: string, model: string): string {
  return [
    `$env:GATEWAY_BASE_URL = ${JSON.stringify(gatewayBaseUrl)}`,
    `$env:GATEWAY_API_KEY = ${JSON.stringify(USER_API_KEY_PLACEHOLDER)}`,
    `$env:SMOKE_MODEL = ${JSON.stringify(model)}`,
  ].join("\n");
}

function userConsoleTraceId(): string {
  const randomPart =
    typeof crypto !== "undefined" && "randomUUID" in crypto
      ? crypto.randomUUID()
      : `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;

  return `user-console-${randomPart}`;
}

function quoteShell(value: string): string {
  return `'${value.replace(/'/g, "'\"'\"'")}'`;
}

function firstStringField(record: Record<string, unknown>, keys: readonly string[]): string | null {
  for (const key of keys) {
    const direct = stringFromJson(record[key]);
    if (direct) {
      return direct;
    }
    const nested = record[key];
    if (isRecord(nested)) {
      const nestedAmount =
        stringFromJson(nested.price) ??
        stringFromJson(nested.amount) ??
        stringFromJson(nested.unit_price) ??
        stringFromJson(nested.per_token);
      if (nestedAmount) {
        return nestedAmount;
      }
    }
  }

  return null;
}

function stringFromJson(value: unknown): string | null {
  if (typeof value === "string" && value.trim()) {
    return value.trim();
  }
  if (typeof value === "number" && Number.isFinite(value)) {
    return String(value);
  }

  return null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function writeClipboard(value: string): Promise<void> {
  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(value);
      return;
    } catch {
      // Fall through to the legacy textarea path for browsers that deny clipboard access in tests.
    }
  }

  const textarea = document.createElement("textarea");
  textarea.value = value;
  textarea.setAttribute("readonly", "true");
  textarea.style.position = "fixed";
  textarea.style.left = "-9999px";
  document.body.appendChild(textarea);
  textarea.select();
  try {
    document.execCommand("copy");
  } finally {
    document.body.removeChild(textarea);
  }
}
