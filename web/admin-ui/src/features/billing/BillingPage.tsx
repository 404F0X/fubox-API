import { FormEvent, useEffect, useState } from "react";
import {
  type AdminVoucherIssueBatchRequest,
  type AdminVoucherIssueBatchResponse,
  type AdminVoucherIssueRequest,
  type AdminVoucherIssueResponse,
  type AdminVoucherIssuanceListFilters,
  type AdminVoucherIssuanceSummary,
  type AdminWalletCreditSurface,
  type AdminWalletListFilters,
  type BillingReconciliationCurrencyTotal,
  type BillingReconciliationDiscrepancy,
  type BillingReconciliationReport,
  type BillingReconciliationReportFilters,
  type CreatePriceVersionRequest,
  type JsonObject,
  type LedgerEntry,
  type LedgerAdjustmentDryRunRequest,
  type LedgerAdjustmentDryRunResponse,
  type LedgerAdjustmentExecutionReadback,
  type LedgerAdjustmentExecuteResult,
  type LedgerAdjustmentFutureExecuteResponse,
  type LedgerExecutorRefusalSummaryContract,
  type LedgerExecutorRollbackSummaryContract,
  type LedgerExecutorSummary,
  type LedgerExecutorSummaryContract,
  type LedgerEntryListFilters,
  type LocalPaymentDemoCreateOrderRequest,
  type LocalPaymentDemoMarkPaidRequest,
  type LocalPaymentDemoResponse,
  type PriceVersion,
  type PriceVersionListFilters,
  type PriceVersionStatus,
  type CreateSubscriptionPlanRequest,
  type PatchSubscriptionPlanRequest,
  type SubscriptionBillingInterval,
  type SubscriptionPlan,
  type SubscriptionPlanListFilters,
  type SubscriptionPlanStatus,
  createLocalPaymentDemoOrder,
  createPriceVersion,
  createSubscriptionPlan,
  dryRunLedgerAdjustment,
  executeLedgerAdjustment,
  getAdminWallet,
  getBillingReconciliationReport,
  issueAdminVoucher,
  issueAdminVoucherBatch,
  listAdminWallets,
  listAdminVoucherIssuances,
  listLedgerEntries,
  listPriceVersions,
  listSubscriptionPlans,
  markLocalPaymentDemoOrderPaid,
  patchSubscriptionPlan,
  requestLedgerAdjustmentExecuteContract,
  revokeAdminVoucherIssuance,
  type JsonValue,
} from "../../api/client";
import { ledgerAdjustmentExecuteLiveSmokeContract } from "../../billingExecuteSmokeContract";
import {
  StateChip,
  errorMessage,
  formatStatus,
  isSensitiveDisplayText,
  isJsonRecord,
  jsonSize,
  parseJsonObject,
  safeFieldValue,
  sanitizeSecretJson,
  shortId,
} from "../../components/adminUtils";
import { formatDateTime, formatMoney as formatSafeMoney } from "../../lib/format";
import { safeShortId as formatSafeShortId } from "../../lib/safeText";
import { Eye, Plus, RefreshCw, Save, Search, X } from "../../components/icons";
import type { AuditLogsFocusTarget, UsersFocusTarget } from "../../app/types";

const executeSmokeSelectors = ledgerAdjustmentExecuteLiveSmokeContract.selectors;

type BillingTab =
  | "wallets"
  | "priceVersions"
  | "subscriptionPlans"
  | "vouchers"
  | "ledger"
  | "paymentDemo"
  | "reconciliation";

type WalletFilterState = {
  currency: string;
  ledgerWindowDays: string;
  limit: string;
  projectId: string;
  status: string;
};

type PriceVersionFilterState = {
  canonicalModelId: string;
  limit: string;
  priceBookId: string;
  status: string;
};

type PriceVersionCreateForm = {
  cacheTokenRatePer1m: string;
  canonicalModelId: string;
  currency: string;
  effectiveAt: string;
  fixedRequestCost: string;
  inputTokenRatePer1m: string;
  outputTokenRatePer1m: string;
  priceBookId: string;
  pricingRules: string;
  reasoningTokenRatePer1m: string;
  retiredAt: string;
  scale: string;
  status: PriceVersionStatus;
  version: string;
};

type SubscriptionPlanFilterState = {
  billingInterval: string;
  limit: string;
  status: string;
};

type SubscriptionPlanForm = {
  billingInterval: SubscriptionBillingInterval;
  currency: string;
  displayName: string;
  includedCreditAmount: string;
  metadata: string;
  planCode: string;
  requestSummary: string;
  status: SubscriptionPlanStatus;
  trialDays: string;
  unitPrice: string;
};

type LedgerFilterState = {
  limit: string;
  projectId: string;
  requestId: string;
  walletId: string;
};

type LedgerAdjustmentDryRunForm = {
  amount: string;
  currency: string;
  operation: string;
  projectId: string;
  reason: string;
  relatedLedgerEntryId: string;
  requestId: string;
  walletId: string;
};

type LedgerAdjustmentDryRunState = {
  request: LedgerAdjustmentDryRunRequest;
  result: LedgerAdjustmentDryRunResponse;
};

type LedgerAdjustmentExecuteState = {
  request: LedgerAdjustmentDryRunRequest;
  result: LedgerAdjustmentExecuteResult;
};

type LedgerAdjustmentExecuteErrorState = {
  kind: "blocked" | "failed";
  message: string;
};

type LedgerAdjustmentExecuteRefreshState = {
  message?: string;
  status: "idle" | "pending" | "success" | "error";
};

type VoucherIssueForm = {
  amount: string;
  batchIdempotencyKey: string;
  currency: string;
  expiresAt: string;
  idempotencyKey: string;
  maxRedemptions: string;
  projectId: string;
  rawVoucherCode: string;
  tenantId: string;
  voucherCodesText: string;
  walletId: string;
};

type VoucherListFilterState = {
  batchIdempotencyKeyHash: string;
  campaignId: string;
  limit: string;
  projectId: string;
  status: string;
  walletId: string;
};

type LedgerEntriesLoadResult = {
  message?: string;
  ok: boolean;
};

type ReconciliationFilterState = {
  day: string;
  limit: string;
  requestId: string;
};

type LocalPaymentDemoForm = {
  amount: string;
  currency: string;
  idempotencyKey: string;
  markPaidIdempotencyKey: string;
  projectId: string;
  reason: string;
  tenantId: string;
  walletId: string;
};

type VoucherSecretDownload = {
  content: string;
  filename: string;
  label: string;
};

const defaultPriceVersionFilters: PriceVersionFilterState = {
  canonicalModelId: "",
  limit: "25",
  priceBookId: "",
  status: "",
};

const defaultWalletFilters: WalletFilterState = {
  currency: "",
  ledgerWindowDays: "30",
  limit: "25",
  projectId: "",
  status: "",
};

const defaultPricingRules = {
  cache_token_rate_per_1m: "0.05000000",
  currency: "USD",
  fixed_request_cost: "0.00000000",
  input_token_rate_per_1m: "0.15000000",
  output_token_rate_per_1m: "0.60000000",
  reasoning_token_rate_per_1m: "1.20000000",
  scale: 8,
} satisfies JsonObject;

const defaultPricingRulesJson = JSON.stringify(defaultPricingRules, null, 2);

const defaultPriceVersionCreateForm: PriceVersionCreateForm = {
  cacheTokenRatePer1m: defaultPricingRules.cache_token_rate_per_1m,
  canonicalModelId: "",
  currency: defaultPricingRules.currency,
  effectiveAt: "",
  fixedRequestCost: defaultPricingRules.fixed_request_cost,
  inputTokenRatePer1m: defaultPricingRules.input_token_rate_per_1m,
  outputTokenRatePer1m: defaultPricingRules.output_token_rate_per_1m,
  priceBookId: "",
  pricingRules: defaultPricingRulesJson,
  reasoningTokenRatePer1m: defaultPricingRules.reasoning_token_rate_per_1m,
  retiredAt: "",
  scale: String(defaultPricingRules.scale),
  status: "draft",
  version: "",
};

const defaultSubscriptionPlanFilters: SubscriptionPlanFilterState = {
  billingInterval: "",
  limit: "25",
  status: "",
};

const defaultSubscriptionPlanForm: SubscriptionPlanForm = {
  billingInterval: "month",
  currency: "USD",
  displayName: "",
  includedCreditAmount: "10.00000000",
  metadata: JSON.stringify(
    {
      catalog_only: true,
      payment_provider: "not_connected",
      renewal_scheduler: "pending_scheduler",
    },
    null,
    2,
  ),
  planCode: "",
  requestSummary: JSON.stringify(
    {
      credit_unit: "wallet_credit_decimal",
      renewal_scheduler: "pending_scheduler",
    },
    null,
    2,
  ),
  status: "draft",
  trialDays: "0",
  unitPrice: "10.00000000",
};

const defaultLedgerFilters: LedgerFilterState = {
  limit: "25",
  projectId: "",
  requestId: "",
  walletId: "",
};

const defaultLedgerAdjustmentDryRunForm: LedgerAdjustmentDryRunForm = {
  amount: "",
  currency: "USD",
  operation: "refund",
  projectId: "",
  reason: "",
  relatedLedgerEntryId: "",
  requestId: "",
  walletId: "",
};

const defaultVoucherIssueForm: VoucherIssueForm = {
  amount: "5.00000000",
  batchIdempotencyKey: "",
  currency: "USD",
  expiresAt: "",
  idempotencyKey: "",
  maxRedemptions: "1",
  projectId: "00000000-0000-0000-0000-000000000020",
  rawVoucherCode: "",
  tenantId: "00000000-0000-0000-0000-000000000001",
  voucherCodesText: "",
  walletId: "",
};

const defaultVoucherListFilters: VoucherListFilterState = {
  batchIdempotencyKeyHash: "",
  campaignId: "",
  limit: "25",
  projectId: "",
  status: "",
  walletId: "",
};

const defaultReconciliationFilters: ReconciliationFilterState = {
  day: "",
  limit: "50",
  requestId: "",
};

const defaultLocalPaymentDemoForm: LocalPaymentDemoForm = {
  amount: "5.00000000",
  currency: "USD",
  idempotencyKey: "",
  markPaidIdempotencyKey: "",
  projectId: "00000000-0000-0000-0000-000000000020",
  reason: "local demo top-up",
  tenantId: "00000000-0000-0000-0000-000000000001",
  walletId: "",
};

const priceVersionStatuses = ["", "draft", "active", "retired"];
const priceVersionCreateStatuses: PriceVersionStatus[] = ["draft", "active", "retired"];

type BillingPageProps = {
  initialTab?: BillingTab;
  onOpenAuditLog?: (target: AuditLogsFocusTarget) => void;
  onOpenRequestDetail?: (requestId: string) => void;
  onOpenTrace?: (traceId: string) => void;
  onOpenUser?: (target: UsersFocusTarget) => void;
};

type BillingNavigationProps = Pick<BillingPageProps, "onOpenAuditLog" | "onOpenRequestDetail" | "onOpenTrace" | "onOpenUser">;

export function BillingPage({
  initialTab,
  onOpenAuditLog,
  onOpenRequestDetail,
  onOpenTrace,
  onOpenUser,
}: BillingPageProps = {}) {
  const [activeTab, setActiveTab] = useState<BillingTab>("priceVersions");
  const navigation: BillingNavigationProps = {
    onOpenAuditLog,
    onOpenRequestDetail,
    onOpenTrace,
    onOpenUser,
  };

  useEffect(() => {
    if (initialTab) {
      setActiveTab(initialTab);
    }
  }, [initialTab]);

  return (
    <div className="admin-page" aria-label="计费与价格">
      <div className="tab-list" role="tablist" aria-label="计费分区">
        <button
          aria-selected={activeTab === "wallets"}
          className={`tab-button${activeTab === "wallets" ? " tab-button--active" : ""}`}
          onClick={() => setActiveTab("wallets")}
          role="tab"
          type="button"
        >
          钱包余额
        </button>
        <button
          aria-selected={activeTab === "priceVersions"}
          className={`tab-button${activeTab === "priceVersions" ? " tab-button--active" : ""}`}
          onClick={() => setActiveTab("priceVersions")}
          role="tab"
          type="button"
        >
          价格版本
        </button>
        <button
          aria-selected={activeTab === "subscriptionPlans"}
          className={`tab-button${activeTab === "subscriptionPlans" ? " tab-button--active" : ""}`}
          onClick={() => setActiveTab("subscriptionPlans")}
          role="tab"
          type="button"
        >
          订阅套餐
        </button>
        <button
          aria-selected={activeTab === "vouchers"}
          className={`tab-button${activeTab === "vouchers" ? " tab-button--active" : ""}`}
          onClick={() => setActiveTab("vouchers")}
          role="tab"
          type="button"
        >
          代金券
        </button>
        <button
          aria-selected={activeTab === "ledger"}
          className={`tab-button${activeTab === "ledger" ? " tab-button--active" : ""}`}
          onClick={() => setActiveTab("ledger")}
          role="tab"
          type="button"
        >
          账本概览
        </button>
        <button
          aria-selected={activeTab === "paymentDemo"}
          className={`tab-button${activeTab === "paymentDemo" ? " tab-button--active" : ""}`}
          onClick={() => setActiveTab("paymentDemo")}
          role="tab"
          type="button"
        >
          模拟支付
        </button>
        <button
          aria-selected={activeTab === "reconciliation"}
          className={`tab-button${activeTab === "reconciliation" ? " tab-button--active" : ""}`}
          onClick={() => setActiveTab("reconciliation")}
          role="tab"
          type="button"
        >
          对账
        </button>
      </div>

      {activeTab === "wallets" ? (
        <WalletsSection {...navigation} />
      ) : activeTab === "priceVersions" ? (
        <PriceVersionsSection />
      ) : activeTab === "subscriptionPlans" ? (
        <SubscriptionPlansSection />
      ) : activeTab === "vouchers" ? (
        <VoucherIssuanceSection {...navigation} />
      ) : activeTab === "ledger" ? (
        <LedgerOverviewSection {...navigation} />
      ) : activeTab === "paymentDemo" ? (
        <LocalPaymentDemoSection {...navigation} />
      ) : (
        <ReconciliationSection onOpenRequestDetail={onOpenRequestDetail} onOpenTrace={onOpenTrace} onOpenUser={onOpenUser} />
      )}
    </div>
  );
}

export default BillingPage;

function WalletsSection({ onOpenAuditLog, onOpenRequestDetail, onOpenTrace, onOpenUser }: BillingNavigationProps) {
  const [detailLoadingId, setDetailLoadingId] = useState<string | null>(null);
  const [filters, setFilters] = useState<WalletFilterState>(defaultWalletFilters);
  const [listError, setListError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [selectedWallet, setSelectedWallet] = useState<AdminWalletCreditSurface | null>(null);
  const [wallets, setWallets] = useState<AdminWalletCreditSurface[]>([]);

  async function loadWallets(nextFilters = filters) {
    setListError(null);
    setLoading(true);

    try {
      const response = await listAdminWallets(toWalletFilters(nextFilters));
      const nextWallets = Array.isArray(response) ? response : [];
      setWallets(nextWallets);
      setSelectedWallet((current) =>
        current ? nextWallets.find((surface) => surface.wallet.id === current.wallet.id) ?? null : nextWallets[0] ?? null,
      );
    } catch (requestError) {
      setListError(errorMessage(requestError));
      setSelectedWallet(null);
      setWallets([]);
    } finally {
      setLoading(false);
    }
  }

  async function openWalletDetail(surface: AdminWalletCreditSurface) {
    setListError(null);
    setDetailLoadingId(surface.wallet.id);

    try {
      const detail = await getAdminWallet(surface.wallet.id, {
        ledger_window_days: optionalPositiveInteger(filters.ledgerWindowDays, "Ledger window days"),
      });
      setSelectedWallet(detail);
    } catch (requestError) {
      setListError(errorMessage(requestError));
      setSelectedWallet(surface);
    } finally {
      setDetailLoadingId(null);
    }
  }

  function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    void loadWallets(filters);
  }

  function updateFilter(field: keyof WalletFilterState, value: string) {
    setFilters((current) => ({ ...current, [field]: value }));
  }

  useEffect(() => {
    void loadWallets(defaultWalletFilters);
  }, []);

  return (
    <>
      <section className="admin-panel" aria-label="钱包余额筛选">
        <div className="section-heading">
          <div>
            <h2>钱包余额</h2>
            <p>按钱包查看 active credit grants、confirmed ledger window、pending reserves 和可公开追踪引用。</p>
          </div>
          <button className="secondary-button" type="button" onClick={() => void loadWallets()} disabled={loading}>
            <RefreshCw aria-hidden="true" size={18} className={loading ? "spin" : undefined} />
            刷新
          </button>
        </div>

        <form className="filter-bar" onSubmit={handleSubmit}>
          <label className="field">
            Project ID
            <input value={filters.projectId} onChange={(event) => updateFilter("projectId", event.currentTarget.value)} />
          </label>
          <label className="field">
            状态
            <select value={filters.status} onChange={(event) => updateFilter("status", event.currentTarget.value)}>
              <option value="">全部</option>
              <option value="active">active</option>
              <option value="disabled">disabled</option>
              <option value="deleted">deleted</option>
            </select>
          </label>
          <label className="field field--compact">
            币种
            <input value={filters.currency} onChange={(event) => updateFilter("currency", event.currentTarget.value)} placeholder="USD" />
          </label>
          <label className="field field--compact">
            窗口天数
            <input
              min="1"
              type="number"
              value={filters.ledgerWindowDays}
              onChange={(event) => updateFilter("ledgerWindowDays", event.currentTarget.value)}
            />
          </label>
          <label className="field field--compact">
            数量
            <input min="1" type="number" value={filters.limit} onChange={(event) => updateFilter("limit", event.currentTarget.value)} />
          </label>
          <button className="primary-button primary-button--inline" type="submit">
            <Search aria-hidden="true" size={17} />
            搜索
          </button>
        </form>

        {listError ? <p className="form-status form-status--error">{listError}</p> : null}
      </section>

      <WalletStats wallets={wallets} />

      <section aria-label="钱包列表">
        <div className="health-table-wrap">
          <table className="health-table admin-table admin-table--wallets">
            <thead>
              <tr>
                <th>钱包</th>
                <th>状态</th>
                <th>可用余额</th>
                <th>额度来源</th>
                <th>账本去向</th>
                <th>Refs</th>
                <th>详情</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr>
                  <td colSpan={7}>正在加载钱包余额。</td>
                </tr>
              ) : wallets.length > 0 ? (
                wallets.map((surface) => (
                  <tr
                    key={surface.wallet.id}
                    className={selectedWallet?.wallet.id === surface.wallet.id ? "table-row--selected" : undefined}
                  >
                    <td>
                      <strong>{safeFieldValue(surface.wallet.name)}</strong>
                      <span>{shortId(surface.wallet.id)}</span>
                      <SafeBillingJump
                        kind="project"
                        label="Project"
                        onOpenUser={onOpenUser}
                        value={surface.wallet.project_id}
                      />
                    </td>
                    <td>
                      <StateChip status={surface.wallet.status} />
                    </td>
                    <td>
                      <strong>{walletAvailableMoney(surface)}</strong>
                      <span>floor {moneyValue(surface.wallet.balance_floor, surface.wallet.currency)}</span>
                    </td>
                    <td>
                      <span>active {moneyValue(surface.credit_grants.active_remaining_total, surface.wallet.currency)}</span>
                      <span>{surface.credit_grants.active_count.toLocaleString()} active grants</span>
                    </td>
                    <td>
                      <span>debit {moneyValue(surface.ledger_balance_window.confirmed_debit_total, surface.wallet.currency)}</span>
                      <span>credit {moneyValue(surface.ledger_balance_window.confirmed_credit_total, surface.wallet.currency)}</span>
                      <span>pending {moneyValue(surface.ledger_balance_window.pending_amount, surface.wallet.currency)}</span>
                    </td>
                    <td>
                      <span>Ledger {formatIdList(surface.last_ledger_entry_ids)}</span>
                      <SafeBillingJumpList
                        kind="request"
                        label="Request"
                        onOpenRequestDetail={onOpenRequestDetail}
                        values={surface.bounded_links.request_ids ?? []}
                      />
                      <SafeBillingJumpList
                        kind="trace"
                        label="Trace"
                        onOpenTrace={onOpenTrace}
                        values={surface.bounded_links.trace_ids ?? []}
                      />
                      <SafeBillingJumpList
                        kind="audit"
                        label="Audit"
                        onOpenAuditLog={onOpenAuditLog}
                        values={surface.bounded_links.audit_log_ids ?? []}
                      />
                    </td>
                    <td>
                      <button
                        aria-label={`查看钱包 ${surface.wallet.id}`}
                        className="table-action"
                        onClick={() => void openWalletDetail(surface)}
                        type="button"
                      >
                        <Eye aria-hidden="true" size={15} />
                        {detailLoadingId === surface.wallet.id ? "加载中" : "查看"}
                      </button>
                    </td>
                  </tr>
                ))
              ) : (
                <tr>
                  <td colSpan={7}>没有返回钱包。</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </section>

      {selectedWallet ? (
        <WalletDetail
          surface={selectedWallet}
          onOpenAuditLog={onOpenAuditLog}
          onOpenRequestDetail={onOpenRequestDetail}
          onOpenTrace={onOpenTrace}
          onOpenUser={onOpenUser}
        />
      ) : null}
    </>
  );
}

function SubscriptionPlansSection() {
  const [createError, setCreateError] = useState<string | null>(null);
  const [editingPlan, setEditingPlan] = useState<SubscriptionPlan | null>(null);
  const [filters, setFilters] = useState<SubscriptionPlanFilterState>(defaultSubscriptionPlanFilters);
  const [form, setForm] = useState<SubscriptionPlanForm>(defaultSubscriptionPlanForm);
  const [listError, setListError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [openDialog, setOpenDialog] = useState(false);
  const [plans, setPlans] = useState<SubscriptionPlan[]>([]);
  const [saving, setSaving] = useState(false);
  const [selectedPlan, setSelectedPlan] = useState<SubscriptionPlan | null>(null);
  const [success, setSuccess] = useState<string | null>(null);

  async function loadPlans(nextFilters = filters) {
    setListError(null);
    setLoading(true);
    try {
      const nextPlans = await listSubscriptionPlans(toSubscriptionPlanFilters(nextFilters));
      setPlans(nextPlans);
      setSelectedPlan((current) => (current ? nextPlans.find((plan) => plan.id === current.id) ?? null : nextPlans[0] ?? null));
    } catch (requestError) {
      setListError(errorMessage(requestError));
      setPlans([]);
      setSelectedPlan(null);
    } finally {
      setLoading(false);
    }
  }

  function openCreateDialog() {
    setCreateError(null);
    setEditingPlan(null);
    setForm({ ...defaultSubscriptionPlanForm, planCode: `plan_${Date.now()}` });
    setOpenDialog(true);
  }

  function openEditDialog(plan: SubscriptionPlan) {
    setCreateError(null);
    setEditingPlan(plan);
    setForm(subscriptionPlanFormFromPlan(plan));
    setOpenDialog(true);
  }

  function updateForm(field: keyof SubscriptionPlanForm, value: string) {
    setForm((current) => ({ ...current, [field]: value }));
    setCreateError(null);
    setSuccess(null);
  }

  async function handleSave(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setCreateError(null);
    setSuccess(null);
    setSaving(true);

    try {
      const saved = editingPlan
        ? await patchSubscriptionPlan(editingPlan.id, toPatchSubscriptionPlanRequest(form))
        : await createSubscriptionPlan(toCreateSubscriptionPlanRequest(form));
      setSuccess(`${safeFieldValue(saved.display_name)} 已保存。此操作只更新套餐目录，不触发扣费、续费或额度发放。`);
      await loadPlans(filters);
      setSelectedPlan(saved);
      setOpenDialog(false);
    } catch (requestError) {
      setCreateError(errorMessage(requestError));
    } finally {
      setSaving(false);
    }
  }

  async function disablePlan(plan: SubscriptionPlan) {
    setListError(null);
    setSuccess(null);
    setSaving(true);
    try {
      const saved = await patchSubscriptionPlan(plan.id, { status: "archived" });
      setSuccess(`${safeFieldValue(saved.display_name)} 已禁用。已有订阅续期仍等待 scheduler 接入后处理。`);
      await loadPlans(filters);
      setSelectedPlan(saved);
    } catch (requestError) {
      setListError(errorMessage(requestError));
    } finally {
      setSaving(false);
    }
  }

  useEffect(() => {
    void loadPlans(defaultSubscriptionPlanFilters);
  }, []);

  return (
    <>
      <section className="admin-panel" aria-label="订阅套餐筛选">
        <div className="section-heading">
          <div>
            <h2>订阅套餐</h2>
            <p>套餐目录 skeleton：周期、价格、包含额度和过期策略。真实支付、续费、dunning scheduler 仍为 pending。</p>
          </div>
          <div className="action-row">
            <button className="primary-button primary-button--inline" type="button" onClick={openCreateDialog}>
              <Plus aria-hidden="true" size={17} />
              新增套餐
            </button>
            <button className="secondary-button" type="button" onClick={() => void loadPlans()} disabled={loading}>
              <RefreshCw aria-hidden="true" size={18} className={loading ? "spin" : undefined} />
              刷新
            </button>
          </div>
        </div>

        <form
          className="filter-bar"
          onSubmit={(event) => {
            event.preventDefault();
            void loadPlans(filters);
          }}
        >
          <label className="field">
            状态
            <select value={filters.status} onChange={(event) => setFilters((current) => ({ ...current, status: event.currentTarget.value }))}>
              <option value="">全部</option>
              <option value="draft">draft</option>
              <option value="active">active</option>
              <option value="archived">archived</option>
            </select>
          </label>
          <label className="field">
            周期
            <select value={filters.billingInterval} onChange={(event) => setFilters((current) => ({ ...current, billingInterval: event.currentTarget.value }))}>
              <option value="">全部</option>
              <option value="month">month</option>
              <option value="year">year</option>
              <option value="one_time">one_time</option>
            </select>
          </label>
          <label className="field field--compact">
            数量
            <input min="1" type="number" value={filters.limit} onChange={(event) => setFilters((current) => ({ ...current, limit: event.currentTarget.value }))} />
          </label>
          <button className="primary-button primary-button--inline" type="submit">
            <Search aria-hidden="true" size={17} />
            搜索
          </button>
        </form>

        {listError ? <p className="form-status form-status--error">{listError}</p> : null}
        {success ? <p className="form-status form-status--success">{success}</p> : null}
      </section>

      <SubscriptionPlanStats plans={plans} />

      <section aria-label="订阅套餐列表">
        <div className="health-table-wrap">
          <table className="health-table admin-table admin-table--subscription-plans">
            <thead>
              <tr>
                <th>套餐</th>
                <th>状态</th>
                <th>周期</th>
                <th>价格</th>
                <th>包含额度</th>
                <th>过期 / scheduler</th>
                <th>操作</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr>
                  <td colSpan={7}>正在加载订阅套餐。</td>
                </tr>
              ) : plans.length > 0 ? (
                plans.map((plan) => (
                  <tr key={plan.id} className={selectedPlan?.id === plan.id ? "table-row--selected" : undefined}>
                    <td>
                      <strong>{safeFieldValue(plan.display_name)}</strong>
                      <span>{safeFieldValue(plan.plan_code)}</span>
                      <span>{shortId(plan.id)}</span>
                    </td>
                    <td>
                      <StateChip status={plan.status} />
                    </td>
                    <td>{formatStatus(plan.billing_interval)}</td>
                    <td>{moneyValue(plan.unit_price, plan.currency)}</td>
                    <td>
                      <span>{moneyValue(plan.included_credit_amount, plan.currency)}</span>
                      <span>trial {plan.trial_days} days</span>
                    </td>
                    <td>
                      <span>{formatStatus(plan.scheduler_status)}</span>
                      <span>{formatStatus(plan.payment_status)}</span>
                    </td>
                    <td>
                      <div className="action-row action-row--compact">
                        <button className="table-action" type="button" onClick={() => setSelectedPlan(plan)}>
                          <Eye aria-hidden="true" size={15} />
                          查看
                        </button>
                        <button className="table-action" type="button" onClick={() => openEditDialog(plan)}>
                          编辑
                        </button>
                        <button className="table-action" type="button" disabled={plan.status === "archived" || saving} onClick={() => void disablePlan(plan)}>
                          禁用
                        </button>
                      </div>
                    </td>
                  </tr>
                ))
              ) : (
                <tr>
                  <td colSpan={7}>没有返回订阅套餐。可以先新增 catalog-only 套餐。</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </section>

      {selectedPlan ? <SubscriptionPlanDetail plan={selectedPlan} /> : <SubscriptionPlanUserPlaceholder />}

      {openDialog ? (
        <div className="wizard-overlay" role="dialog" aria-modal="true" aria-label={editingPlan ? "编辑订阅套餐" : "新增订阅套餐"}>
          <div className="wizard-panel">
            <div className="wizard-header">
              <div>
                <span>订阅套餐</span>
                <h3>{editingPlan ? "编辑套餐" : "新增套餐"}</h3>
                <p>安全操作：保存后只影响套餐目录，不接真实支付，不执行 renewal scheduler。</p>
              </div>
              <button className="icon-button" type="button" onClick={() => setOpenDialog(false)} aria-label="关闭订阅套餐对话框">
                <X aria-hidden="true" size={18} />
              </button>
            </div>

            <form className="price-version-form wizard-body" onSubmit={handleSave}>
              <div className="form-grid price-version-form-grid">
                <label className="field">
                  套餐代码
                  <input value={form.planCode} onChange={(event) => updateForm("planCode", event.currentTarget.value)} disabled={Boolean(editingPlan)} required />
                </label>
                <label className="field">
                  展示名称
                  <input value={form.displayName} onChange={(event) => updateForm("displayName", event.currentTarget.value)} required />
                </label>
                <label className="field">
                  状态
                  <select value={form.status} onChange={(event) => updateForm("status", event.currentTarget.value)}>
                    <option value="draft">draft</option>
                    <option value="active">active</option>
                    <option value="archived">archived</option>
                  </select>
                </label>
                <label className="field">
                  周期
                  <select value={form.billingInterval} onChange={(event) => updateForm("billingInterval", event.currentTarget.value)}>
                    <option value="month">month</option>
                    <option value="year">year</option>
                    <option value="one_time">one_time</option>
                  </select>
                </label>
                <label className="field">
                  币种
                  <input value={form.currency} onChange={(event) => updateForm("currency", event.currentTarget.value)} required />
                </label>
                <label className="field">
                  套餐价格
                  <input value={form.unitPrice} onChange={(event) => updateForm("unitPrice", event.currentTarget.value)} required />
                </label>
                <label className="field">
                  包含额度
                  <input value={form.includedCreditAmount} onChange={(event) => updateForm("includedCreditAmount", event.currentTarget.value)} required />
                </label>
                <label className="field">
                  试用天数
                  <input min="0" type="number" value={form.trialDays} onChange={(event) => updateForm("trialDays", event.currentTarget.value)} required />
                </label>
              </div>

              <div className="form-grid price-version-form-grid">
                <label className="field field--wide">
                  请求摘要 JSON
                  <textarea rows={5} value={form.requestSummary} onChange={(event) => updateForm("requestSummary", event.currentTarget.value)} />
                </label>
                <label className="field field--wide">
                  Metadata JSON
                  <textarea rows={5} value={form.metadata} onChange={(event) => updateForm("metadata", event.currentTarget.value)} />
                </label>
              </div>

              <p className="muted-copy">金额和额度统一使用钱包 decimal string；套餐保存不会写 ledger、不会创建 order、不会给用户发放额度。</p>
              {createError ? <p className="form-status form-status--error">{createError}</p> : null}
              <div className="wizard-actions">
                <button className="secondary-button" type="button" onClick={() => setOpenDialog(false)}>
                  取消
                </button>
                <button className="primary-button primary-button--inline" type="submit" disabled={saving}>
                  <Save aria-hidden="true" size={17} />
                  {saving ? "保存中" : "保存套餐"}
                </button>
              </div>
            </form>
          </div>
        </div>
      ) : null}
    </>
  );
}

function VoucherIssuanceSection({ onOpenAuditLog, onOpenUser }: BillingNavigationProps) {
  const [form, setForm] = useState<VoucherIssueForm>(() => ({
    ...defaultVoucherIssueForm,
    batchIdempotencyKey: `voucher-batch-${Date.now()}`,
    idempotencyKey: `voucher-${Date.now()}`,
    rawVoucherCode: "",
    voucherCodesText: "",
  }));
  const [issueMode, setIssueMode] = useState<"single" | "batch">("single");
  const [billingReferencesText, setBillingReferencesText] = useState("");
  const [billingReferencesStatus, setBillingReferencesStatus] = useState<string | null>(null);
  const [issuing, setIssuing] = useState(false);
  const [issueError, setIssueError] = useState<string | null>(null);
  const [issueResult, setIssueResult] = useState<AdminVoucherIssueResponse | null>(null);
  const [batchResult, setBatchResult] = useState<AdminVoucherIssueBatchResponse | null>(null);
  const [openGrantDialog, setOpenGrantDialog] = useState(false);
  const [voucherFilters, setVoucherFilters] = useState<VoucherListFilterState>(defaultVoucherListFilters);
  const [voucherList, setVoucherList] = useState<AdminVoucherIssuanceSummary[]>([]);
  const [voucherListError, setVoucherListError] = useState<string | null>(null);
  const [voucherListLoading, setVoucherListLoading] = useState(true);
  const [voucherListStatus, setVoucherListStatus] = useState<string | null>(null);
  const [revokingVoucherId, setRevokingVoucherId] = useState<string | null>(null);
  const [revokingBatch, setRevokingBatch] = useState(false);
  const [secretDownload, setSecretDownload] = useState<VoucherSecretDownload | null>(null);

  function updateForm(field: keyof VoucherIssueForm, value: string) {
    setForm((current) => ({ ...current, [field]: value }));
    setIssueError(null);
    setIssueResult(null);
    setBatchResult(null);
    setSecretDownload(null);
  }

  function applyBillingReferences() {
    setIssueError(null);
    setIssueResult(null);
    setBatchResult(null);
    setSecretDownload(null);
    try {
      const references = parseUserBillingReferences(billingReferencesText);
      setForm((current) => ({
        ...current,
        currency: references.currency ?? current.currency,
        projectId: references.projectId ?? current.projectId,
        tenantId: references.tenantId ?? current.tenantId,
        walletId: references.walletId ?? current.walletId,
      }));
      setBillingReferencesStatus("计费引用已应用。");
    } catch (parseError) {
      setBillingReferencesStatus(null);
      setIssueError(parseError instanceof VoucherIssueFormError ? parseError.message : errorMessage(parseError));
    }
  }

  async function loadVouchers(nextFilters = voucherFilters) {
    setVoucherListError(null);
    setVoucherListLoading(true);
    try {
      const response = await listAdminVoucherIssuances(toVoucherListFilters(nextFilters));
      setVoucherList(response.items);
    } catch (requestError) {
      setVoucherListError(errorMessage(requestError));
      setVoucherList([]);
    } finally {
      setVoucherListLoading(false);
    }
  }

  function handleVoucherFilterSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    void loadVouchers(voucherFilters);
  }

  function updateVoucherFilter(field: keyof VoucherListFilterState, value: string) {
    setVoucherFilters((current) => ({ ...current, [field]: value }));
    setVoucherListStatus(null);
  }

  async function revokeVoucher(voucher: AdminVoucherIssuanceSummary) {
    setVoucherListError(null);
    setVoucherListStatus(null);
    setRevokingVoucherId(voucher.voucher_id);
    try {
      await revokeAdminVoucherIssuance(voucher.voucher_id);
      setVoucherListStatus(`代金券 ${shortId(voucher.voucher_id)} 已撤销。`);
      await loadVouchers(voucherFilters);
    } catch (requestError) {
      setVoucherListError(errorMessage(requestError));
    } finally {
      setRevokingVoucherId(null);
    }
  }

  async function revokeFilteredBatch() {
    const issuedVouchers = voucherList.filter((voucher) => (voucher.effective_status ?? voucher.status) === "issued");
    if (issuedVouchers.length === 0) {
      setVoucherListStatus("当前筛选结果没有可撤销的 issued 代金券。");
      return;
    }

    setVoucherListError(null);
    setVoucherListStatus(null);
    setRevokingBatch(true);
    try {
      let revoked = 0;
      for (const voucher of issuedVouchers) {
        await revokeAdminVoucherIssuance(voucher.voucher_id);
        revoked += 1;
      }
      setVoucherListStatus(`已撤销当前筛选结果中的 ${revoked.toLocaleString()} 张 issued 代金券。`);
      await loadVouchers(voucherFilters);
    } catch (requestError) {
      setVoucherListError(errorMessage(requestError));
    } finally {
      setRevokingBatch(false);
    }
  }

  function downloadSecretOnce() {
    if (!secretDownload) {
      return;
    }

    downloadTextFile(secretDownload.filename, secretDownload.content, "text/plain;charset=utf-8");
    setSecretDownload(null);
    setVoucherListStatus(`${secretDownload.label} 已下载一次，页面不再保留原始券码。`);
  }

  useEffect(() => {
    void loadVouchers(defaultVoucherListFilters);
  }, []);

  async function handleIssue(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setIssueError(null);
    setIssueResult(null);
    setBatchResult(null);
    setIssuing(true);

    try {
      if (issueMode === "batch") {
        const request = toVoucherIssueBatchRequest(form);
        const result = await issueAdminVoucherBatch(request);
        setBatchResult(result);
        setSecretDownload(voucherBatchSecretDownload(request, result.batch_idempotency_key_hash ?? undefined));
        setVoucherFilters((current) => ({
          ...current,
          batchIdempotencyKeyHash: result.batch_idempotency_key_hash ?? current.batchIdempotencyKeyHash,
        }));
      } else {
        const request = toVoucherIssueRequest(form);
        const result = await issueAdminVoucher(request);
        setIssueResult(result);
        setSecretDownload(voucherSingleSecretDownload(request, result.voucher_id ?? result.id ?? undefined));
      }
      await loadVouchers(voucherFilters);
      setOpenGrantDialog(false);
    } catch (requestError) {
      setIssueError(requestError instanceof VoucherIssueFormError ? requestError.message : errorMessage(requestError));
    } finally {
      setIssuing(false);
    }
  }

  return (
    <section className="admin-panel" aria-label="管理员代金券发放">
      <div className="section-heading">
        <div>
          <h2>发放用户额度</h2>
          <p>为用户钱包发放由代金券承载的额度，用户随后可在用户门户兑换。</p>
        </div>
        <button className="primary-button primary-button--inline" type="button" onClick={() => setOpenGrantDialog(true)}>
          <Plus aria-hidden="true" size={17} />
          发放用户额度
        </button>
      </div>

      <section className="reference-paste-panel" aria-label="粘贴代金券计费引用">
        <div className="section-heading">
          <div>
            <h3>用户计费引用</h3>
            <p>粘贴从用户门户复制的安全引用，用于填写发放目标。</p>
          </div>
          <button className="secondary-button" type="button" onClick={applyBillingReferences}>
            <Search aria-hidden="true" size={17} />
            应用计费引用
          </button>
        </div>
        <label className="field">
          计费引用文本
          <textarea
            rows={5}
            value={billingReferencesText}
            onChange={(event) => {
              setBillingReferencesText(event.currentTarget.value);
              setBillingReferencesStatus(null);
            }}
            placeholder={"AI Gateway billing references\nTenant ID: ...\nProject ID: ...\nWallet ID: ...\nCurrency: USD"}
          />
        </label>
        <p className="muted-copy">不要粘贴 API key 密钥、代金券码、Authorization headers、provider keys 或请求 payload。</p>
        {billingReferencesStatus ? <p className="form-status form-status--success">{billingReferencesStatus}</p> : null}
      </section>

      {issueError ? <p className="form-status form-status--error">{issueError}</p> : null}
      {issueResult ? (
        <section className="detail-grid" aria-label="代金券发放结果">
          <div className="detail-panel">
            <h3>已发放代金券</h3>
            <Fields
              items={[
                ["状态", issueResult.status],
                ["金额", moneyValue(issueResult.amount, issueResult.currency)],
                ["代金券", shortId(issueResult.voucher_id ?? issueResult.id ?? "")],
                ["钱包", shortId(issueResult.wallet_id ?? "")],
                ["敏感信息安全", String(issueResult.secret_safe !== false && issueResult.raw_voucher_code_echoed !== true)],
              ]}
            />
          </div>
        </section>
      ) : null}
      {secretDownload ? (
        <section className="admin-panel" aria-label="代金券原始码一次性下载">
          <div className="section-heading section-heading--compact">
            <div>
              <h3>原始券码一次性下载</h3>
              <p>原始券码只保存在当前浏览器状态中，下载一次后页面立即清除；API 响应和导出不会回显。</p>
            </div>
            <button className="secondary-button" type="button" onClick={downloadSecretOnce}>
              <Save aria-hidden="true" size={17} />
              下载原始券码
            </button>
          </div>
        </section>
      ) : null}
      {batchResult ? (
        <section className="admin-panel" aria-label="批量代金券发放结果">
          <div className="section-heading section-heading--compact">
            <div>
              <h3>批量发放结果</h3>
              <p>
                共 {batchResult.total} 条，发放 {batchResult.issued} 条，重放 {batchResult.replayed} 条，拒绝{" "}
                {batchResult.refused} 条。
              </p>
              {batchResult.batch_idempotency_key_hash ? (
                <p>Batch hash {safeShortId(batchResult.batch_idempotency_key_hash)}</p>
              ) : null}
            </div>
            <StateChip status={batchResult.status} />
          </div>
          <div className="table-scroll">
            <table className="admin-table">
              <thead>
                <tr>
                  <th>#</th>
                  <th>状态</th>
                  <th>代金券</th>
                  <th>金额</th>
                  <th>券码</th>
                  <th>拒绝原因</th>
                </tr>
              </thead>
              <tbody>
                {batchResult.items.map((item) => (
                  <tr key={`${item.index}-${item.voucher_id ?? item.refusal_code ?? item.status}`}>
                    <td>{item.index + 1}</td>
                    <td>
                      <StateChip status={item.status} />
                    </td>
                    <td>{shortId(item.voucher_id ?? "")}</td>
                    <td>{moneyValue(item.amount, item.currency)}</td>
                    <td>{safeFieldValue(item.code_redacted)}</td>
                    <td>{safeFieldValue(item.refusal_code ?? item.message)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <p className="muted-copy">
            secret-safe: {String(batchResult.secret_safe !== false && batchResult.raw_voucher_code_echoed !== true)}
          </p>
        </section>
      ) : null}

      <section className="admin-panel" aria-label="已发放代金券">
        <div className="section-heading section-heading--compact">
          <div>
            <h3>已发放代金券</h3>
            <p>只展示 redacted code、状态和金额，不显示原始券码或幂等键。</p>
          </div>
          <div className="action-row">
            <button className="secondary-button" type="button" onClick={() => exportVoucherIssuancesCsv(voucherList)} disabled={voucherList.length === 0}>
              导出 CSV
            </button>
            <button className="secondary-button" type="button" onClick={() => exportVoucherIssuancesJson(voucherList)} disabled={voucherList.length === 0}>
              导出 JSON
            </button>
            <button
              className="secondary-button"
              type="button"
              onClick={() => void revokeFilteredBatch()}
              disabled={revokingBatch || voucherList.every((voucher) => (voucher.effective_status ?? voucher.status) !== "issued")}
            >
              {revokingBatch ? "批次撤销中" : "撤销当前筛选 issued"}
            </button>
            <button className="secondary-button" type="button" onClick={() => void loadVouchers()} disabled={voucherListLoading}>
              <RefreshCw aria-hidden="true" size={17} className={voucherListLoading ? "spin" : undefined} />
              刷新
            </button>
          </div>
        </div>

        <form className="filter-grid" onSubmit={handleVoucherFilterSubmit}>
          <label className="field">
            Wallet ID
            <input value={voucherFilters.walletId} onChange={(event) => updateVoucherFilter("walletId", event.currentTarget.value)} />
          </label>
          <label className="field">
            Project ID
            <input value={voucherFilters.projectId} onChange={(event) => updateVoucherFilter("projectId", event.currentTarget.value)} />
          </label>
          <label className="field">
            Campaign ID
            <input value={voucherFilters.campaignId} onChange={(event) => updateVoucherFilter("campaignId", event.currentTarget.value)} />
          </label>
          <label className="field">
            Batch hash
            <input
              value={voucherFilters.batchIdempotencyKeyHash}
              onChange={(event) => updateVoucherFilter("batchIdempotencyKeyHash", event.currentTarget.value)}
              placeholder="batch idempotency key hash"
            />
          </label>
          <label className="field">
            状态
            <select value={voucherFilters.status} onChange={(event) => updateVoucherFilter("status", event.currentTarget.value)}>
              <option value="">全部</option>
              <option value="issued">issued</option>
              <option value="redeemed">redeemed</option>
              <option value="expired">expired</option>
              <option value="revoked">revoked</option>
            </select>
          </label>
          <label className="field">
            数量
            <input value={voucherFilters.limit} onChange={(event) => updateVoucherFilter("limit", event.currentTarget.value)} />
          </label>
          <button className="secondary-button primary-button--inline" type="submit" disabled={voucherListLoading}>
            <Search aria-hidden="true" size={17} />
            查询
          </button>
        </form>

        {voucherListError ? <p className="form-status form-status--error">{voucherListError}</p> : null}
        {voucherListStatus ? <p className="form-status form-status--success">{voucherListStatus}</p> : null}

        <div className="table-scroll">
          <table className="admin-table">
            <thead>
              <tr>
                <th>券码</th>
                <th>状态</th>
                <th>金额</th>
                <th>兑换</th>
                <th>过期时间</th>
                <th>钱包</th>
                <th>安全跳转</th>
                <th>操作</th>
              </tr>
            </thead>
            <tbody>
              {voucherListLoading ? (
                <tr>
                  <td colSpan={8}>正在加载代金券。</td>
                </tr>
              ) : voucherList.length > 0 ? (
                voucherList.map((voucher) => (
                  <tr key={voucher.voucher_id}>
                    <td>
                      <strong>{safeFieldValue(voucher.code_redacted)}</strong>
                      <span>{shortId(voucher.voucher_id)}</span>
                    </td>
                    <td>
                      <StateChip status={voucher.effective_status ?? voucher.status} />
                    </td>
                    <td>{moneyValue(voucher.amount, voucher.currency)}</td>
                    <td>
                      {voucher.redemption_count.toLocaleString()} / {voucher.max_redemptions.toLocaleString()}
                    </td>
                    <td>{safeFieldValue(voucher.expires_at)}</td>
                    <td>{shortId(voucher.wallet_id ?? "")}</td>
                    <td>
                      <SafeBillingJump
                        kind="project"
                        label="Project"
                        onOpenUser={onOpenUser}
                        value={voucher.project_id}
                      />
                      <SafeBillingJump
                        kind="audit"
                        label="Issued audit"
                        onOpenAuditLog={onOpenAuditLog}
                        value={voucher.audit_id}
                      />
                      <SafeBillingJump
                        kind="audit"
                        label="Revoke audit"
                        onOpenAuditLog={onOpenAuditLog}
                        value={voucher.revoke_audit_id}
                      />
                    </td>
                    <td>
                      <button
                        className="table-action table-action--danger"
                        type="button"
                        onClick={() => void revokeVoucher(voucher)}
                        disabled={voucher.status !== "issued" || revokingVoucherId === voucher.voucher_id}
                      >
                        {revokingVoucherId === voucher.voucher_id ? "撤销中" : "撤销"}
                      </button>
                    </td>
                  </tr>
                ))
              ) : (
                <tr>
                  <td colSpan={8}>暂无代金券。可以先发放用户额度。</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </section>

      {openGrantDialog ? (
        <div className="wizard-overlay" role="dialog" aria-modal="true" aria-label="发放用户额度对话框">
          <div className="wizard-panel">
            <div className="wizard-header">
              <div>
                <span>代金券额度</span>
                <h3>发放用户额度</h3>
                <p>使用安全的用户计费引用发放代金券，并让用户在用户门户兑换。</p>
              </div>
              <button className="icon-button" type="button" onClick={() => setOpenGrantDialog(false)} aria-label="关闭发放用户额度对话框">
                <X aria-hidden="true" size={18} />
              </button>
            </div>
            <form className="form-grid wizard-body" onSubmit={handleIssue}>
              <div className="segmented-control" role="tablist" aria-label="代金券发放模式">
                <button
                  aria-selected={issueMode === "single"}
                  className={`segmented-control__button ${issueMode === "single" ? "segmented-control__button--active" : ""}`}
                  onClick={() => setIssueMode("single")}
                  role="tab"
                  type="button"
                >
                  单个
                </button>
                <button
                  aria-selected={issueMode === "batch"}
                  className={`segmented-control__button ${issueMode === "batch" ? "segmented-control__button--active" : ""}`}
                  onClick={() => setIssueMode("batch")}
                  role="tab"
                  type="button"
                >
                  批量
                </button>
              </div>
              <label className="field">
                Tenant ID
                <input value={form.tenantId} onChange={(event) => updateForm("tenantId", event.currentTarget.value)} required />
              </label>
              <label className="field">
                Project ID
                <input value={form.projectId} onChange={(event) => updateForm("projectId", event.currentTarget.value)} />
              </label>
              <label className="field">
                Wallet ID
                <input
                  value={form.walletId}
                  onChange={(event) => updateForm("walletId", event.currentTarget.value)}
                  placeholder="wallet uuid"
                  required
                />
              </label>
              <label className="field">
                币种
                <input value={form.currency} onChange={(event) => updateForm("currency", event.currentTarget.value)} required />
              </label>
              <label className="field">
                金额
                <input value={form.amount} onChange={(event) => updateForm("amount", event.currentTarget.value)} required />
              </label>
              {issueMode === "single" ? (
                <>
                  <label className="field">
                    代金券码
                    <input
                      autoComplete="off"
                      value={form.rawVoucherCode}
                      onChange={(event) => updateForm("rawVoucherCode", event.currentTarget.value)}
                      placeholder="customer code"
                      required
                    />
                  </label>
                  <label className="field">
                    幂等键
                    <input
                      value={form.idempotencyKey}
                      onChange={(event) => updateForm("idempotencyKey", event.currentTarget.value)}
                      required
                    />
                  </label>
                </>
              ) : (
                <>
                  <label className="field">
                    批次幂等键
                    <input
                      value={form.batchIdempotencyKey}
                      onChange={(event) => updateForm("batchIdempotencyKey", event.currentTarget.value)}
                      required
                    />
                  </label>
                  <label className="field field--wide">
                    代金券码列表
                    <textarea
                      rows={7}
                      value={form.voucherCodesText}
                      onChange={(event) => updateForm("voucherCodesText", event.currentTarget.value)}
                      placeholder={"CODE-001\nCODE-002\nCODE-003,custom-idempotency-key"}
                      required
                    />
                  </label>
                </>
              )}
              <label className="field">
                最大兑换次数
                <input value={form.maxRedemptions} onChange={(event) => updateForm("maxRedemptions", event.currentTarget.value)} />
              </label>
              <label className="field">
                过期时间
                <input
                  value={form.expiresAt}
                  onChange={(event) => updateForm("expiresAt", event.currentTarget.value)}
                  placeholder="2026-06-30T00:00:00Z"
                />
              </label>
              <button className="primary-button primary-button--inline" type="submit" disabled={issuing}>
                <Plus aria-hidden="true" size={17} />
                {issuing ? "发放中" : issueMode === "batch" ? "批量发放" : "发放代金券"}
              </button>
            </form>
          </div>
        </div>
      ) : null}
    </section>
  );
}

function PriceVersionsSection() {
  const [createError, setCreateError] = useState<string | null>(null);
  const [createForm, setCreateForm] = useState<PriceVersionCreateForm>(defaultPriceVersionCreateForm);
  const [creating, setCreating] = useState(false);
  const [filters, setFilters] = useState<PriceVersionFilterState>(defaultPriceVersionFilters);
  const [listError, setListError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [openCreateDialog, setOpenCreateDialog] = useState(false);
  const [selectedVersion, setSelectedVersion] = useState<PriceVersion | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [versions, setVersions] = useState<PriceVersion[]>([]);

  async function loadVersions(nextFilters = filters) {
    setListError(null);
    setLoading(true);

    try {
      const nextVersions = await listPriceVersions(toPriceVersionFilters(nextFilters));
      setVersions(nextVersions);
      setSelectedVersion((current) =>
        current ? nextVersions.find((version) => version.id === current.id) ?? null : null,
      );
    } catch (requestError) {
      setListError(errorMessage(requestError));
      setVersions([]);
      setSelectedVersion(null);
    } finally {
      setLoading(false);
    }
  }

  function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    void loadVersions(filters);
  }

  function updateCreateForm(field: keyof PriceVersionCreateForm, value: string) {
    setCreateForm((current) => ({ ...current, [field]: value }));
  }

  function updatePricingRuleBuilder(field: keyof PriceVersionCreateForm, value: string) {
    setCreateForm((current) => {
      const next = { ...current, [field]: value };
      return { ...next, pricingRules: pricingRulesJsonFromBuilder(next) };
    });
  }

  async function handleCreate(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setCreateError(null);
    setSuccess(null);
    setCreating(true);

    try {
      const request = toCreatePriceVersionRequest(createForm);
      const created = await createPriceVersion(request);
      setCreateForm({
        ...defaultPriceVersionCreateForm,
        canonicalModelId: createForm.canonicalModelId.trim(),
        priceBookId: createForm.priceBookId.trim(),
      });
      setSuccess(`价格版本 ${safeFieldValue(created.version)} 已创建。`);
      await loadVersions(filters);
      setSelectedVersion(created);
      setOpenCreateDialog(false);
    } catch (requestError) {
      if (requestError instanceof PriceVersionFormError) {
        setCreateError(requestError.message);
        if (requestError.clearPricingRules) {
          setCreateForm((current) => ({ ...current, pricingRules: defaultPricingRulesJson }));
        }
      } else {
        setCreateError(errorMessage(requestError));
      }
    } finally {
      setCreating(false);
    }
  }

  useEffect(() => {
    void loadVersions(defaultPriceVersionFilters);
  }, []);

  return (
    <>
      <section className="admin-panel" aria-label="价格版本筛选">
        <div className="section-heading">
          <div>
            <h2>价格版本</h2>
            <p>查看价格版本状态、作用范围、生效窗口和计费规则结构。</p>
          </div>
          <div className="action-row">
            <button
              className="primary-button primary-button--inline"
              type="button"
              onClick={() => {
                setCreateError(null);
                setSuccess(null);
                setOpenCreateDialog(true);
              }}
            >
              <Plus aria-hidden="true" size={17} />
              创建价格版本
            </button>
            <button className="secondary-button" type="button" onClick={() => void loadVersions()} disabled={loading}>
              <RefreshCw aria-hidden="true" size={18} className={loading ? "spin" : undefined} />
              刷新
            </button>
          </div>
        </div>

        <form className="filter-bar" onSubmit={handleSubmit}>
          <label className="field">
            状态
            <select
              value={filters.status}
              onChange={(event) => setFilters((current) => ({ ...current, status: event.currentTarget.value }))}
            >
              {priceVersionStatuses.map((status) => (
                <option key={status || "all"} value={status}>
                  {status ? formatStatus(status) : "全部"}
                </option>
              ))}
            </select>
          </label>
          <label className="field">
            价格簿 ID
            <input
              value={filters.priceBookId}
              onChange={(event) => setFilters((current) => ({ ...current, priceBookId: event.currentTarget.value }))}
              placeholder="price book uuid"
            />
          </label>
          <label className="field">
            模型 ID
            <input
              value={filters.canonicalModelId}
              onChange={(event) => setFilters((current) => ({ ...current, canonicalModelId: event.currentTarget.value }))}
              placeholder="canonical model uuid"
            />
          </label>
          <label className="field field--compact">
            限制
            <input
              min="1"
              type="number"
              value={filters.limit}
              onChange={(event) => setFilters((current) => ({ ...current, limit: event.currentTarget.value }))}
            />
          </label>
          <button className="primary-button primary-button--inline" type="submit">
            <Search aria-hidden="true" size={17} />
            搜索
          </button>
        </form>

        {listError ? <p className="form-status form-status--error">{listError}</p> : null}
        {success ? <p className="form-status form-status--success">{success}</p> : null}
      </section>

      <PriceVersionStats versions={versions} />

      <section aria-label="价格版本列表">
        <div className="health-table-wrap">
          <table className="health-table admin-table admin-table--price-versions">
            <thead>
              <tr>
                <th>版本</th>
                <th>状态</th>
                <th>范围</th>
                <th>生效时间</th>
                <th>退役时间</th>
                <th>Token 费率 / 1M</th>
                <th>详情</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr>
                  <td colSpan={7}>正在加载价格版本。</td>
                </tr>
              ) : versions.length > 0 ? (
                versions.map((version) => (
                  <tr key={version.id} className={selectedVersion?.id === version.id ? "table-row--selected" : undefined}>
                    <td>
                      <strong>{version.version}</strong>
                      <span>{shortId(version.id)}</span>
                    </td>
                    <td>
                      <StateChip status={version.status} />
                    </td>
                    <td>
                      <strong>{shortId(version.price_book_id)}</strong>
                      <span>{version.canonical_model_id ? `模型 ${shortId(version.canonical_model_id)}` : "默认模型范围"}</span>
                    </td>
                    <td>{formatDate(version.effective_at)}</td>
                    <td>{version.retired_at ? formatDate(version.retired_at) : "-"}</td>
                    <td>
                      <PriceRuleRateSummary rules={version.pricing_rules} />
                    </td>
                    <td>
                      <button
                        aria-label={`查看价格版本 ${version.version}`}
                        className="table-action"
                        onClick={() => setSelectedVersion(version)}
                        type="button"
                      >
                        <Eye aria-hidden="true" size={15} />
                        查看
                      </button>
                    </td>
                  </tr>
                ))
              ) : (
                <tr>
                  <td colSpan={7}>没有返回价格版本。</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </section>

      {selectedVersion ? <PriceVersionDetail version={selectedVersion} /> : null}

      {openCreateDialog ? (
        <div className="wizard-overlay" role="dialog" aria-modal="true" aria-label="创建价格版本对话框">
          <div className="wizard-panel">
            <div className="wizard-header">
              <div>
                <span>模型计费</span>
                <h3>创建价格版本</h3>
                <p>定义模型路由面向用户的成本规则。高级规则仍可通过 JSON 字段配置。</p>
              </div>
              <button className="icon-button" type="button" onClick={() => setOpenCreateDialog(false)} aria-label="关闭创建价格版本对话框">
                <X aria-hidden="true" size={18} />
              </button>
            </div>

            <form className="price-version-form wizard-body" aria-label="创建价格版本" onSubmit={handleCreate}>
              <div className="form-grid price-version-form-grid">
                <label className="field">
                  价格簿 ID
                  <input
                    value={createForm.priceBookId}
                    onChange={(event) => updateCreateForm("priceBookId", event.currentTarget.value)}
                    placeholder="price book uuid"
                    required
                  />
                </label>
                <label className="field">
                  模型 ID
                  <input
                    value={createForm.canonicalModelId}
                    onChange={(event) => updateCreateForm("canonicalModelId", event.currentTarget.value)}
                    placeholder="canonical model uuid"
                  />
                </label>
                <label className="field">
                  版本
                  <input
                    value={createForm.version}
                    onChange={(event) => updateCreateForm("version", event.currentTarget.value)}
                    placeholder="2026-06-03"
                    required
                  />
                </label>
                <label className="field">
                  状态
                  <select
                    value={createForm.status}
                    onChange={(event) => updateCreateForm("status", event.currentTarget.value)}
                  >
                    {priceVersionCreateStatuses.map((status) => (
                      <option key={status} value={status}>
                        {formatStatus(status)}
                      </option>
                    ))}
                  </select>
                </label>
                <label className="field">
                  生效时间
                  <input
                    value={createForm.effectiveAt}
                    onChange={(event) => updateCreateForm("effectiveAt", event.currentTarget.value)}
                    placeholder="2026-06-03T00:00:00Z"
                  />
                </label>
                <label className="field">
                  退役时间
                  <input
                    value={createForm.retiredAt}
                    onChange={(event) => updateCreateForm("retiredAt", event.currentTarget.value)}
                    placeholder="2026-12-31T00:00:00Z"
                  />
                </label>
              </div>

              <div className="form-grid price-version-form-grid">
                <label className="field">
                  币种
                  <input
                    value={createForm.currency}
                    onChange={(event) => updatePricingRuleBuilder("currency", event.currentTarget.value)}
                    required
                  />
                </label>
                <label className="field">
                  固定请求成本
                  <input
                    value={createForm.fixedRequestCost}
                    onChange={(event) => updatePricingRuleBuilder("fixedRequestCost", event.currentTarget.value)}
                    required
                  />
                </label>
                <label className="field">
                  输入 token 费率 / 1M
                  <input
                    value={createForm.inputTokenRatePer1m}
                    onChange={(event) => updatePricingRuleBuilder("inputTokenRatePer1m", event.currentTarget.value)}
                    required
                  />
                </label>
                <label className="field">
                  输出 token 费率 / 1M
                  <input
                    value={createForm.outputTokenRatePer1m}
                    onChange={(event) => updatePricingRuleBuilder("outputTokenRatePer1m", event.currentTarget.value)}
                    required
                  />
                </label>
                <label className="field">
                  Cache token 费率 / 1M
                  <input
                    value={createForm.cacheTokenRatePer1m}
                    onChange={(event) => updatePricingRuleBuilder("cacheTokenRatePer1m", event.currentTarget.value)}
                    required
                  />
                </label>
                <label className="field">
                  Reasoning token 费率 / 1M
                  <input
                    value={createForm.reasoningTokenRatePer1m}
                    onChange={(event) => updatePricingRuleBuilder("reasoningTokenRatePer1m", event.currentTarget.value)}
                    required
                  />
                </label>
                <label className="field field--compact">
                  精度
                  <input
                    min="0"
                    type="number"
                    value={createForm.scale}
                    onChange={(event) => updatePricingRuleBuilder("scale", event.currentTarget.value)}
                    required
                  />
                </label>
              </div>

              <label className="field">
                计费规则 JSON
                <textarea
                  value={createForm.pricingRules}
                  onChange={(event) => updateCreateForm("pricingRules", event.currentTarget.value)}
                  required
                  spellCheck={false}
                />
              </label>

              <button className="primary-button primary-button--inline" type="submit" disabled={creating}>
                <Plus aria-hidden="true" size={17} />
                {creating ? "创建中" : "创建"}
              </button>
              {createError ? <p className="form-status form-status--error">{createError}</p> : null}
            </form>
          </div>
        </div>
      ) : null}
    </>
  );
}

function LedgerOverviewSection({ onOpenRequestDetail, onOpenTrace, onOpenUser }: BillingNavigationProps) {
  const [dryRunError, setDryRunError] = useState<string | null>(null);
  const [dryRunForm, setDryRunForm] = useState<LedgerAdjustmentDryRunForm>(defaultLedgerAdjustmentDryRunForm);
  const [dryRunLoading, setDryRunLoading] = useState(false);
  const [dryRunPlan, setDryRunPlan] = useState<LedgerAdjustmentDryRunState | null>(null);
  const [executeCheckError, setExecuteCheckError] = useState<string | null>(null);
  const [executeCheckLoading, setExecuteCheckLoading] = useState(false);
  const [executeCheckResult, setExecuteCheckResult] = useState<LedgerAdjustmentExecuteState | null>(null);
  const [executeError, setExecuteError] = useState<LedgerAdjustmentExecuteErrorState | null>(null);
  const [executeLoading, setExecuteLoading] = useState(false);
  const [executeRefreshState, setExecuteRefreshState] = useState<LedgerAdjustmentExecuteRefreshState>({ status: "idle" });
  const [executeResult, setExecuteResult] = useState<LedgerAdjustmentExecuteState | null>(null);
  const [entries, setEntries] = useState<LedgerEntry[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [filters, setFilters] = useState<LedgerFilterState>(defaultLedgerFilters);
  const [loading, setLoading] = useState(true);
  const [selectedEntry, setSelectedEntry] = useState<LedgerEntry | null>(null);

  async function loadEntries(nextFilters = filters): Promise<LedgerEntriesLoadResult> {
    setError(null);
    setLoading(true);

    try {
      const nextEntries = await listLedgerEntries(toLedgerFilters(nextFilters));
      setEntries(nextEntries);
      setSelectedEntry((current) => (current ? nextEntries.find((entry) => entry.id === current.id) ?? null : null));
      return { ok: true };
    } catch (requestError) {
      const message = errorMessage(requestError);
      setEntries([]);
      setError(message);
      setSelectedEntry(null);
      return { message, ok: false };
    } finally {
      setLoading(false);
    }
  }

  function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    void loadEntries(filters);
  }

  function updateDryRunForm(field: keyof LedgerAdjustmentDryRunForm, value: string) {
    setDryRunForm((current) => ({ ...current, [field]: value }));
    setExecuteCheckError(null);
    setExecuteCheckResult(null);
    setExecuteError(null);
    setExecuteRefreshState({ status: "idle" });
    setExecuteResult(null);
  }

  async function handleDryRun(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setDryRunError(null);
    setDryRunPlan(null);
    setExecuteCheckError(null);
    setExecuteCheckResult(null);
    setExecuteError(null);
    setExecuteRefreshState({ status: "idle" });
    setExecuteResult(null);
    setDryRunLoading(true);

    try {
      const request = toLedgerAdjustmentDryRunRequest(dryRunForm);
      const result = await dryRunLedgerAdjustment(request);
      setDryRunPlan({ request, result });
    } catch (requestError) {
      setDryRunError(requestError instanceof LedgerAdjustmentFormError ? requestError.message : errorMessage(requestError));
    } finally {
      setDryRunLoading(false);
    }
  }

  async function handleExecuteContractCheck() {
    setExecuteCheckError(null);
    setExecuteError(null);
    setExecuteRefreshState({ status: "idle" });
    setExecuteResult(null);

    if (!dryRunPlan || !isLedgerAdjustmentDryRunFresh(dryRunPlan.request, dryRunForm)) {
      setExecuteCheckResult(null);
      setExecuteCheckError("检查执行契约前，请先运行一次新的 dry-run。");
      return;
    }

    setExecuteCheckLoading(true);

    try {
      const result = await requestLedgerAdjustmentExecuteContract(dryRunPlan.request);
      setExecuteCheckResult({ request: dryRunPlan.request, result });
    } catch (requestError) {
      setExecuteCheckResult(null);
      setExecuteCheckError(errorMessage(requestError));
    } finally {
      setExecuteCheckLoading(false);
    }
  }

  async function handleExecuteLedgerAdjustment() {
    setExecuteError(null);
    setExecuteCheckResult(null);
    setExecuteRefreshState({ status: "idle" });
    setExecuteResult(null);

    if (!dryRunPlan || !isLedgerAdjustmentDryRunFresh(dryRunPlan.request, dryRunForm)) {
      setExecuteResult(null);
      setExecuteError({
        kind: "blocked",
        message: "执行账本调整前，请先运行一次新的 dry-run。",
      });
      return;
    }

    setExecuteLoading(true);

    try {
      const result = await executeLedgerAdjustment(dryRunPlan.request);
      setExecuteResult({ request: dryRunPlan.request, result });
      if (shouldRefreshLedgerEntriesAfterExecute(result)) {
        setExecuteRefreshState({ status: "pending" });
        const refreshResult = await loadEntries(filters);
        setExecuteRefreshState(
          refreshResult.ok
            ? { status: "success" }
            : { message: refreshResult.message ?? "账本条目刷新失败。", status: "error" },
        );
      }
    } catch (requestError) {
      setExecuteResult(null);
      setExecuteRefreshState({ status: "idle" });
      setExecuteError(executeErrorState(requestError));
    } finally {
      setExecuteLoading(false);
    }
  }

  useEffect(() => {
    void loadEntries(defaultLedgerFilters);
  }, []);

  return (
    <>
      <section className="admin-panel" aria-label="账本调整 dry-run">
        <div className="section-heading">
          <div>
            <h2>调整 / 退款 Dry-Run</h2>
            <p>必须填写原因；dry-run 仅规划条目，执行步骤会生成安全的账本和审计摘要，或返回后端缺口占位。</p>
          </div>
        </div>

        <form className="price-version-form" data-testid={executeSmokeSelectors.dryRunForm} onSubmit={handleDryRun}>
          <div className="form-grid">
            <label className="field">
              操作
              <select
                data-testid={executeSmokeSelectors.operationInput}
                value={dryRunForm.operation}
                onChange={(event) => updateDryRunForm("operation", event.currentTarget.value)}
              >
                <option value="refund">退款</option>
                <option value="adjust">调整</option>
              </select>
            </label>
            <label className="field">
              金额
              <input
                data-testid={executeSmokeSelectors.amountInput}
                value={dryRunForm.amount}
                onChange={(event) => updateDryRunForm("amount", event.currentTarget.value)}
                placeholder="0.25000000"
                required
              />
            </label>
            <label className="field">
              币种
              <input
                data-testid={executeSmokeSelectors.currencyInput}
                value={dryRunForm.currency}
                onChange={(event) => updateDryRunForm("currency", event.currentTarget.value)}
                placeholder="USD"
                required
              />
            </label>
            <label className="field">
              关联账本条目
              <input
                data-testid={executeSmokeSelectors.relatedLedgerEntryInput}
                value={dryRunForm.relatedLedgerEntryId}
                onChange={(event) => updateDryRunForm("relatedLedgerEntryId", event.currentTarget.value)}
                placeholder="ledger entry uuid"
              />
            </label>
            <label className="field">
              Project ID
              <input
                data-testid={executeSmokeSelectors.projectInput}
                value={dryRunForm.projectId}
                onChange={(event) => updateDryRunForm("projectId", event.currentTarget.value)}
                placeholder="project uuid"
              />
            </label>
            <label className="field">
              Wallet ID
              <input
                data-testid={executeSmokeSelectors.walletInput}
                value={dryRunForm.walletId}
                onChange={(event) => updateDryRunForm("walletId", event.currentTarget.value)}
                placeholder="wallet uuid"
              />
            </label>
            <label className="field">
              Request ID
              <input
                data-testid={executeSmokeSelectors.requestInput}
                value={dryRunForm.requestId}
                onChange={(event) => updateDryRunForm("requestId", event.currentTarget.value)}
                placeholder="request uuid"
              />
            </label>
            <label className="field field--wide">
              原因（必填）
              <input
                aria-label="原因"
                data-testid={executeSmokeSelectors.reasonInput}
                value={dryRunForm.reason}
                onChange={(event) => updateDryRunForm("reason", event.currentTarget.value)}
                placeholder="customer credit"
                required
              />
            </label>
          </div>

          <button
            className="primary-button primary-button--inline"
            data-testid={executeSmokeSelectors.dryRunButton}
            type="submit"
            disabled={dryRunLoading}
          >
            <Search aria-hidden="true" size={17} />
            {dryRunLoading ? "规划中" : "规划 dry-run"}
          </button>
        </form>

        {dryRunError ? <p className="form-status form-status--error">{dryRunError}</p> : null}
      </section>

      <LedgerAdjustmentExecuteAffordance
        checking={executeCheckLoading}
        contractFresh={isLedgerAdjustmentDryRunFresh(executeCheckResult?.request, dryRunForm)}
        contractResult={executeCheckResult?.result ?? null}
        error={executeCheckError}
        executeError={executeError}
        executeFresh={isLedgerAdjustmentDryRunFresh(executeResult?.request, dryRunForm)}
        executeRefreshState={executeRefreshState}
        executeResult={executeResult?.result ?? null}
        executing={executeLoading}
        hasDryRun={Boolean(dryRunPlan)}
        dryRunFresh={isLedgerAdjustmentDryRunFresh(dryRunPlan?.request, dryRunForm)}
        onCheckExecuteContract={() => void handleExecuteContractCheck()}
        onExecute={() => void handleExecuteLedgerAdjustment()}
      />

      {dryRunPlan ? (
        <LedgerAdjustmentDryRunResult
          result={dryRunPlan.result}
          dryRunFresh={isLedgerAdjustmentDryRunFresh(dryRunPlan.request, dryRunForm)}
        />
      ) : null}

      <section className="admin-panel" aria-label="账本筛选">
        <div className="section-heading">
          <div>
            <h2>账本概览</h2>
            <p>按项目、钱包或请求查看只追加的账本条目。</p>
          </div>
          <button className="secondary-button" type="button" onClick={() => void loadEntries()} disabled={loading}>
            <RefreshCw aria-hidden="true" size={18} className={loading ? "spin" : undefined} />
            刷新
          </button>
        </div>

        <form className="filter-bar" onSubmit={handleSubmit}>
          <label className="field">
            Project ID
            <input
              value={filters.projectId}
              onChange={(event) => setFilters((current) => ({ ...current, projectId: event.currentTarget.value }))}
              placeholder="project uuid"
            />
          </label>
          <label className="field">
            Request ID
            <input
              value={filters.requestId}
              onChange={(event) => setFilters((current) => ({ ...current, requestId: event.currentTarget.value }))}
              placeholder="request uuid"
            />
          </label>
          <label className="field">
            Wallet ID
            <input
              value={filters.walletId}
              onChange={(event) => setFilters((current) => ({ ...current, walletId: event.currentTarget.value }))}
              placeholder="wallet uuid"
            />
          </label>
          <label className="field field--compact">
            限制
            <input
              min="1"
              type="number"
              value={filters.limit}
              onChange={(event) => setFilters((current) => ({ ...current, limit: event.currentTarget.value }))}
            />
          </label>
          <button className="primary-button primary-button--inline" type="submit">
            <Search aria-hidden="true" size={17} />
            搜索
          </button>
        </form>

        {error ? <p className="form-status form-status--error">{error}</p> : null}
      </section>

      <LedgerStats entries={entries} />

      <section aria-label="账本条目列表">
        <div className="health-table-wrap">
          <table className="health-table admin-table admin-table--ledger">
            <thead>
              <tr>
                <th>条目</th>
                <th>状态</th>
                <th>金额</th>
                <th>范围</th>
                <th>链接</th>
                <th>发生时间</th>
                <th>详情</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr>
                  <td colSpan={7}>正在加载账本条目。</td>
                </tr>
              ) : entries.length > 0 ? (
                entries.map((entry) => (
                  <tr key={entry.id} className={selectedEntry?.id === entry.id ? "table-row--selected" : undefined}>
                    <td>
                      <strong>{formatStatus(entry.entry_type)}</strong>
                      <span>{shortId(entry.id)}</span>
                    </td>
                    <td>
                      <StateChip status={entry.status} />
                    </td>
                    <td>
                      <strong>{moneyValue(entry.amount, entry.currency)}</strong>
                      <span>{safeFieldValue(entry.amount)}</span>
                    </td>
                    <td>
                      <SafeBillingJump
                        kind="project"
                        label="项目"
                        onOpenUser={onOpenUser}
                        value={entry.project_id}
                      />
                      <span>钱包 {shortId(entry.wallet_id)}</span>
                    </td>
                    <td>
                      <SafeBillingJump
                        kind="request"
                        label="请求"
                        onOpenRequestDetail={onOpenRequestDetail}
                        value={entry.request_id}
                      />
                      <span>价格 {shortId(entry.price_version_id)}</span>
                      <SafeBillingJump
                        kind="trace"
                        label="Trace"
                        onOpenTrace={onOpenTrace}
                        value={entry.trace_id}
                      />
                      <span>Voucher {ledgerMetadataRef(entry.metadata, ["voucher_id", "voucherId"])}</span>
                      <span>Order {ledgerMetadataRef(entry.metadata, ["order_id", "orderId", "payment_order_id"])}</span>
                    </td>
                    <td>{formatDate(entry.occurred_at)}</td>
                    <td>
                      <button
                        aria-label={`查看账本条目 ${entry.id}`}
                        className="table-action"
                        onClick={() => setSelectedEntry(entry)}
                        type="button"
                      >
                        <Eye aria-hidden="true" size={15} />
                        查看
                      </button>
                    </td>
                  </tr>
                ))
              ) : (
                <tr>
                  <td colSpan={7}>没有返回账本条目。</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </section>

      {selectedEntry ? (
        <LedgerEntryDetail
          entry={selectedEntry}
          onOpenRequestDetail={onOpenRequestDetail}
          onOpenTrace={onOpenTrace}
          onOpenUser={onOpenUser}
        />
      ) : null}
    </>
  );
}

function LedgerAdjustmentExecuteAffordance({
  checking,
  contractFresh,
  contractResult,
  dryRunFresh,
  error,
  executeError,
  executeFresh,
  executeRefreshState,
  executeResult,
  executing,
  hasDryRun,
  onCheckExecuteContract,
  onExecute,
}: {
  checking: boolean;
  contractFresh: boolean;
  contractResult: LedgerAdjustmentExecuteResult | null;
  dryRunFresh: boolean;
  error: string | null;
  executeError: LedgerAdjustmentExecuteErrorState | null;
  executeFresh: boolean;
  executeRefreshState: LedgerAdjustmentExecuteRefreshState;
  executeResult: LedgerAdjustmentExecuteResult | null;
  executing: boolean;
  hasDryRun: boolean;
  onCheckExecuteContract: () => void;
  onExecute: () => void;
}) {
  const statusText = executeResult
    ? executeReadinessStatus(executeResult, executeFresh)
    : executeError
    ? executeError.message
    : contractResult
    ? executeReadinessStatus(contractResult, contractFresh)
    : !hasDryRun
    ? "请先运行 dry-run，再评估是否可执行。"
    : dryRunFresh
      ? "已有最新 dry-run 结果；执行契约预检和账本执行都需要显式触发。"
      : "表单在 dry-run 后已变更。请重新运行 dry-run 后再评估执行。";
  const flags = executeResult ? executeFlags(executeResult) : contractResult ? executeFlags(contractResult) : null;
  const activeResult = executeResult ?? contractResult;
  const activeFresh = executeResult ? executeFresh : contractFresh;
  const refreshText = executeResult && executeFresh ? executeRefreshStatusText(executeRefreshState) : null;

  return (
    <section
      className="admin-panel"
      aria-label="账本调整执行准备"
      data-testid={executeSmokeSelectors.readiness}
    >
      <div className="section-heading">
        <div>
          <h2>执行准备</h2>
          <p>{statusText}</p>
          {refreshText ? <p className="muted-copy">{refreshText}</p> : null}
        </div>
        <StateChip
          status={executeStatus(activeResult, {
            dryRunFresh,
            errorKind: executeError?.kind,
            executeFresh: activeFresh,
            executing,
            hasDryRun,
          })}
        />
      </div>
      <div className="manual-test-flags" aria-label="执行契约标记" data-testid={executeSmokeSelectors.executeFlags}>
        <span data-testid={executeSmokeSelectors.executeContractMode}>execute_contract_mode=true</span>
        <span data-testid={executeSmokeSelectors.executeEndpoint}>execute_endpoint=true</span>
        <span data-testid={executeSmokeSelectors.dryRunFresh}>fresh_dry_run={String(dryRunFresh)}</span>
        <span data-testid={executeSmokeSelectors.contractCheckFresh}>contract_check_fresh={String(contractFresh)}</span>
        <span data-testid={executeSmokeSelectors.contractCheckNetworkCall}>
          contract_check_network_call={String(Boolean(contractResult))}
        </span>
        <span data-testid={executeSmokeSelectors.executeWriteNetworkCall}>
          execute_write_network_call={String(Boolean(executeResult || executeError))}
        </span>
        {executeResult && executeResult.kind === "future_execute" ? (
          <>
            <span data-testid={executeSmokeSelectors.executeResultFresh}>execute_result_fresh={String(executeFresh)}</span>
            <span data-testid={executeSmokeSelectors.executeOutcome}>
              execute_outcome={safeFieldValue(executeOutcome(executeResult.response))}
            </span>
            <span data-testid={executeSmokeSelectors.ledgerRefreshStatus}>
              ledger_entries_refresh_after_execute={executeRefreshState.status}
            </span>
          </>
        ) : null}
        {flags ? (
          <>
            <span>future_writer_required={String(flags.futureWriterRequired)}</span>
            <span>ledger_write={String(flags.ledgerWrite)}</span>
            <span>audit_log_write={String(flags.auditLogWrite)}</span>
            <span>request_log_write={String(flags.requestLogWrite)}</span>
            <span>upstream_call={String(flags.upstreamCall)}</span>
            <span>server_generated_write_marker={String(flags.serverGeneratedWriteMarker)}</span>
            <span>write_marker_echoed={String(flags.writeMarkerEchoed)}</span>
          </>
        ) : null}
      </div>
      <div className="action-row">
        <button
          className="secondary-button"
          data-testid={executeSmokeSelectors.executeContractButton}
          type="button"
          disabled={!dryRunFresh || checking}
          onClick={onCheckExecuteContract}
        >
          {checking ? "正在检查执行契约" : "检查执行契约"}
        </button>
        <button
          className="primary-button primary-button--inline"
          data-testid={executeSmokeSelectors.executeButton}
          type="button"
          disabled={!dryRunFresh || executing}
          onClick={onExecute}
        >
          {executing ? "执行中" : "执行账本调整"}
        </button>
        <p className="muted-copy">执行会使用最新 dry-run payload，并且只返回安全的账本/审计摘要。</p>
      </div>
      {contractResult ? <LedgerAdjustmentExecuteContractResult result={contractResult} fresh={contractFresh} /> : null}
      {executeResult ? <LedgerAdjustmentExecuteContractResult result={executeResult} fresh={executeFresh} /> : null}
      {executeError ? <p className="form-status form-status--error">{executeError.message}</p> : null}
      {error ? <p className="form-status form-status--error">{error}</p> : null}
    </section>
  );
}

function LedgerAdjustmentExecuteContractResult({
  fresh,
  result,
}: {
  fresh: boolean;
  result: LedgerAdjustmentExecuteResult;
}) {
  const flags = executeFlags(result);
  const snapshotPolicy = executeAuditSnapshotPolicy(result);
  const contract = result.kind === "future_execute" ? undefined : result.response.execute_contract;
  const refusalSummary = result.kind === "future_execute" ? undefined : result.response.ledger_executor_summary;
  const reasons = executeBlockedReasons(result, fresh);
  const isExecuteResult = result.kind === "future_execute";

  return (
    <section aria-label={isExecuteResult ? "账本调整执行结果" : "账本调整执行契约结果"}>
      {reasons.length > 0 ? (
        <div className="issue-list" aria-label="执行阻止原因">
          {reasons.map((reason) => (
            <span className="issue-pill issue-pill--warn" key={reason}>
              {formatStatus(reason)}
            </span>
          ))}
        </div>
      ) : null}
      <Fields
        items={[
          ["结果", executeResultLabel(result)],
          ["契约是否最新", String(fresh)],
          ["契约版本", contract?.contract_version ?? "-"],
          ["需要 writer", String(flags.futureWriterRequired)],
          ["账本写入", String(flags.ledgerWrite)],
          ["审计写入", String(flags.auditLogWrite)],
          ["请求日志写入", String(flags.requestLogWrite)],
          ["上游调用", String(flags.upstreamCall)],
          ["服务端生成写入标记", String(flags.serverGeneratedWriteMarker)],
          ["写入标记已回显", String(flags.writeMarkerEchoed)],
          ["审计快照", snapshotPolicy],
        ]}
      />
      <LedgerAdjustmentExecutionReadbackPanel readback={result.response.ledger_adjustment_execution_readback} />
      <LedgerExecutorSummaryPanel heading="拒绝执行器摘要" summary={refusalSummary} />
      {contract ? <LedgerAdjustmentExecuteV2Summary contract={contract} /> : null}
      {result.kind === "future_execute" ? <LedgerAdjustmentExecutedSummary response={result.response} /> : null}
    </section>
  );
}

function LedgerAdjustmentExecutedSummary({ response }: { response: LedgerAdjustmentFutureExecuteResponse }) {
  const entry = response.ledger_entry;
  const executorContract = response.ledger_executor_summary_contract;
  const executorSummary = response.ledger_executor_summary;
  const transaction = response.transaction_contract;
  const rollbackExecutorContract = transaction?.rollback_executor_summary_contract;
  const refund = response.refund_remaining_summary;

  return (
    <div className="detail-grid detail-grid--compact" aria-label="账本调整执行摘要">
      <article>
        <h3>执行摘要</h3>
        <Fields
          items={[
            ["结果", executeOutcome(response)],
            ["模式", response.mode],
            ["账本写入", String(response.ledger_write)],
            ["审计写入", String(response.audit_log_write)],
            ["请求日志写入", String(response.request_log_write)],
            ["上游调用", String(response.upstream_call)],
            ["审计日志", shortId(response.audit_log_id)],
            ["共享事务", String(response.business_and_success_audit_share_transaction ?? "-")],
            ["账本后成功审计", String(response.success_audit_only_after_ledger_write ?? "-")],
            ["审计回滚", String(response.audit_insert_failure_rolls_back_ledger_write ?? "-")],
            ["拒绝审计", String(response.refusal_does_not_build_success_audit ?? "-")],
            ["材料已回显", String(response.dedupe_material_echoed ?? false)],
            ["公开输出", safeFieldValue(response.dedupe_public_output)],
          ]}
        />
      </article>

      <article>
        <h3>已执行账本条目</h3>
        {entry ? (
          <Fields
            items={[
              ["条目", shortId(entry.id)],
              ["租户", shortId(entry.tenant_id)],
              ["项目", shortId(entry.project_id)],
              ["钱包", shortId(entry.wallet_id)],
              ["请求", shortId(entry.request_id)],
              ["关联条目", shortId(entry.related_ledger_entry_id)],
              ["类型", formatStatus(entry.entry_type)],
              ["金额", moneyValue(entry.amount, entry.currency)],
              ["状态", safeFieldValue(entry.status)],
              ["已省略材料", entry.omitted_material ? `${entry.omitted_material.length} 类` : "-"],
            ]}
          />
        ) : (
          <p className="muted-copy">没有返回安全账本条目摘要。</p>
        )}
      </article>

      <LedgerExecutorSummaryPanel summary={executorSummary} />
      <LedgerExecutorSummaryContractPanel contract={executorContract} />
      <LedgerExecutorRollbackContractPanel contract={rollbackExecutorContract} />

      <article>
        <h3>事务摘要</h3>
        <Fields
          items={[
            ["写入器", safeFieldValue(transaction?.writer)],
            ["已执行写入", String(transaction?.write_performed ?? response.ledger_write)],
            ["隔离级别", safeFieldValue(transaction?.isolation)],
            ["锁前开始", String(transaction?.begin_before_locking ?? "-")],
            ["账本/审计后提交", String(transaction?.commit_only_after_ledger_and_success_audit ?? "-")],
            ["账本失败回滚", String(transaction?.rollback_on_ledger_write_failure ?? "-")],
            ["审计失败回滚", String(transaction?.rollback_on_audit_insert_failure ?? "-")],
            ["退款重算回滚", String(transaction?.rollback_on_refund_remaining_change ?? "-")],
            ["锁步骤", String(transaction?.bounded_lock_order?.length ?? 0)],
            ["边界", String(transaction?.bounded_by?.length ?? 0)],
            ["材料已回显", String(transaction?.dedupe_material_echoed ?? response.dedupe_material_echoed ?? false)],
            ["允许无界扫描", String(transaction?.unbounded_scan_allowed ?? "-")],
          ]}
        />
      </article>

      {refund ? (
        <article>
          <h3>剩余可退款</h3>
          <Fields
            items={[
              ["剩余", moneyValue(refund.remaining_refundable_amount, refund.currency)],
              ["请求", moneyValue(refund.requested_refund_amount, refund.currency)],
              ["来源借记", moneyValue(refund.source_debit_amount, refund.currency)],
              ["已确认贷记", moneyValue(refund.confirmed_credit_amount, refund.currency)],
              ["已确认贷记数", String(refund.confirmed_credit_count)],
              ["租户有界", String(refund.tenant_bounded)],
              ["来源有界", String(refund.source_entry_bounded)],
              ["币种有界", String(refund.currency_bounded)],
              ["仅确认项", String(refund.confirmed_only)],
              ["贷记条目类型", refund.credit_entry_types.join(", ")],
            ]}
          />
        </article>
      ) : null}
    </div>
  );
}

function LedgerAdjustmentExecuteV2Summary({
  contract,
}: {
  contract: Extract<LedgerAdjustmentExecuteResult, { kind: "writer_required" | "contract_ready" }>["response"]["execute_contract"];
}) {
  const transaction = contract.transaction_contract;
  const dedupe = contract.dedupe_contract;
  const writer = contract.ledger_writer_contract;
  const audit = contract.audit_contract;
  const executorContract = contract.ledger_executor_summary_contract;
  const refusalExecutorContract = contract.ledger_executor_refusal_summary_contract;
  const rollbackExecutorContract = transaction?.rollback_executor_summary_contract;
  const requestLog = contract.request_log_contract;
  const safeOutput = contract.safe_output_contract;

  return (
    <div className="detail-grid detail-grid--compact" aria-label="执行契约 v2 摘要">
      <article>
        <h3>去重摘要</h3>
        <Fields
          items={[
            ["服务端生成", String(dedupe?.server_generated_dedupe_material ?? contract.server_generated_dedupe_material)],
            ["已拒绝客户端材料", String(dedupe?.client_supplied_dedupe_material_rejected ?? "-")],
            ["材料已回显", String(dedupe?.dedupe_material_echoed ?? contract.dedupe_material_echoed ?? false)],
            ["公开输出", safeFieldValue(dedupe?.public_output)],
            ["重放行为", String(dedupe?.replay_same_digest_returns_prior_result_after_writer_exists ?? "-")],
            ["重复冲突已拒绝", String(dedupe?.conflicting_duplicate_refused_before_ledger_insert ?? "-")],
          ]}
        />
      </article>

      <article>
        <h3>事务摘要</h3>
        <Fields
          items={[
            ["隔离级别", safeFieldValue(transaction?.future_isolation)],
            ["锁前开始", String(transaction?.begin_before_locking ?? "-")],
            ["账本/审计后提交", String(transaction?.commit_only_after_ledger_and_success_audit ?? "-")],
            ["账本失败回滚", String(transaction?.rollback_on_ledger_write_failure ?? "-")],
            ["审计失败回滚", String(transaction?.rollback_on_audit_insert_failure ?? "-")],
            ["退款重算回滚", String(transaction?.rollback_on_refund_remaining_change ?? "-")],
            ["锁步骤", String(transaction?.bounded_lock_order?.length ?? 0)],
            ["边界", String(transaction?.bounded_by?.length ?? 0)],
            ["重算检查", String(transaction?.recompute_after_locks?.length ?? 0)],
            ["允许无界扫描", String(transaction?.unbounded_scan_allowed ?? "-")],
          ]}
        />
      </article>

      <article>
        <h3>写入器 / 审计摘要</h3>
        <Fields
          items={[
            ["写入器可用", String(!(contract.future_writer_required ?? false))],
            ["写入器名称", safeFieldValue(writer?.future_writer)],
            ["已执行写入", String(writer?.write_performed ?? false)],
            ["成功状态", safeFieldValue(writer?.insert_status_on_success)],
            ["元数据策略", safeFieldValue(writer?.metadata_policy)],
            ["审计写入已执行", String(audit?.write_performed ?? contract.audit_log_write)],
            ["共享事务", String(audit?.business_and_success_audit_share_transaction ?? contract.business_and_success_audit_share_transaction)],
            ["审计回滚", String(audit?.audit_insert_failure_rolls_back_ledger_write ?? contract.audit_insert_failure_rolls_back_ledger_write)],
            ["拒绝审计", String(audit?.refusal_does_not_build_success_audit ?? contract.refusal_does_not_build_success_audit)],
            ["快照策略", safeFieldValue(audit?.snapshot_policy ?? contract.audit_snapshot_policy)],
          ]}
        />
      </article>

      <article>
        <h3>安全输出摘要</h3>
        <Fields
          items={[
            ["请求日志写入", String(requestLog?.write_performed ?? contract.request_log_write)],
            ["请求日志变更", String(requestLog?.request_log_mutation_allowed ?? "-")],
            ["请求材料已回显", String(requestLog?.request_material_echoed ?? safeOutput?.request_material_echoed ?? false)],
            ["敏感材料已回显", String(safeOutput?.credential_material_echoed ?? false)],
            ["输出标记已回显", String(safeOutput?.dedupe_material_echoed ?? contract.dedupe_material_echoed ?? false)],
            ["已检查约束", String(contract.dry_run_constraints_enforced_before_refusal?.length ?? 0)],
          ]}
        />
      </article>

      <LedgerExecutorSummaryContractPanel contract={executorContract} />
      <LedgerExecutorRefusalSummaryContractPanel contract={refusalExecutorContract} />
      <LedgerExecutorRollbackContractPanel contract={rollbackExecutorContract} />
    </div>
  );
}

function LedgerExecutorSummaryContractPanel({ contract }: { contract: LedgerExecutorSummaryContract | null | undefined }) {
  if (!contract) {
    return null;
  }

  return (
    <article className="admin-panel">
      <h3>执行器摘要契约</h3>
      <Fields
        items={[
          ["模式版本", safeExecutorField(contract.schema_version)],
          ["响应字段", safeExecutorField(contract.response_field)],
          ["私有操作输出", safeExecutorField(contract.operation_key_output)],
          ["失败输出", safeExecutorField(contract.error_detail_output)],
          ["重放标记已回显", String(contract.dedupe_material_echoed ?? false)],
          ["不安全元数据已回显", String(contract.raw_metadata_echoed ?? false)],
          ["敏感材料已回显", String(contract.credential_material_echoed ?? false)],
          ["兼容字段", String(contract.compatible_fields?.length ?? 0)],
        ]}
      />
    </article>
  );
}

function LedgerAdjustmentExecutionReadbackPanel({
  readback,
}: {
  readback: LedgerAdjustmentExecutionReadback | null | undefined;
}) {
  if (!readback) {
    return null;
  }

  const refs = readback.refs_presence;
  const safety = readback.secret_safety;

  return (
    <article>
      <h3>前端 readback</h3>
      <Fields
        items={[
          ["模式", safeExecutorField(readback.mode)],
          ["结果", safeExecutorField(readback.outcome)],
          ["状态", safeExecutorField(readback.status)],
          ["钱包 ref", String(refs.wallet_ref_present)],
          ["Credit grant ref", String(refs.credit_grant_ref_present)],
          ["Budget ref", String(refs.budget_ref_present)],
          ["Ledger ref", String(refs.ledger_entry_ref_present)],
          ["Request ref", String(refs.request_ref_present)],
          ["关联 ref", String(refs.related_ledger_entry_ref_present)],
          ["幂等指纹", safeExecutorField(readback.idempotency.fingerprint)],
          ["阻止原因", readback.blocked_reasons.length ? readback.blocked_reasons.map(formatStatus).join(", ") : "-"],
          ["下一步", safeExecutorField(readback.safe_next_action)],
          ["raw SQL", String(safety.raw_sql_returned)],
          ["wallet secret", String(safety.wallet_secret_returned)],
          ["Authorization", String(safety.authorization_returned)],
          ["provider key", String(safety.provider_key_returned)],
          ["raw metadata", String(safety.raw_metadata_returned)],
          ["raw idempotency", String(safety.raw_idempotency_returned || readback.idempotency.raw_idempotency_returned)],
        ]}
      />
    </article>
  );
}

function LedgerExecutorRefusalSummaryContractPanel({
  contract,
}: {
  contract: LedgerExecutorRefusalSummaryContract | null | undefined;
}) {
  if (!contract) {
    return null;
  }

  const preflight = contract.preflight_refusal;
  const rollback = contract.rollback_refusal;

  return (
    <article>
      <h3>拒绝摘要契约</h3>
      <Fields
        items={[
          ["模式版本", safeExecutorField(contract.schema_version)],
          ["响应字段", safeExecutorField(contract.response_field)],
          ["支持的结果", safeExecutorList(contract.supported_outcomes)],
          ["私有操作输出", safeExecutorField(contract.operation_key_output)],
          ["失败输出", safeExecutorField(contract.error_detail_output)],
          ["执行器失败已回显", String(contract.raw_executor_error_detail_echoed ?? false)],
          ["重放标记已回显", String(contract.dedupe_material_echoed ?? false)],
          ["不安全元数据已回显", String(contract.raw_metadata_echoed ?? false)],
          ["敏感材料已回显", String(contract.credential_material_echoed ?? false)],
          ["预检已提交", String(preflight?.committed ?? "-")],
          ["预检已回滚", String(preflight?.rolled_back ?? "-")],
          ["预检拒绝语句数", safeExecutorSummaryValue(preflight?.refused_statement_count)],
          ["预检行数不匹配", safeExecutorSummaryValue(preflight?.row_count_mismatch)],
          ["回滚已提交", String(rollback?.committed ?? "-")],
          ["回滚已回滚", String(rollback?.rolled_back ?? "-")],
          ["回滚拒绝语句数", safeExecutorSummaryValue(rollback?.refused_statement_count)],
          ["回滚行数不匹配", safeExecutorSummaryValue(rollback?.row_count_mismatch)],
        ]}
      />
    </article>
  );
}

function LedgerExecutorRollbackContractPanel({ contract }: { contract: LedgerExecutorRollbackSummaryContract | null | undefined }) {
  if (!contract) {
    return null;
  }

  return (
    <article>
      <h3>回滚执行器摘要契约</h3>
      <Fields
        items={[
          ["模式版本", safeExecutorField(contract.schema_version)],
          ["响应字段", safeExecutorField(contract.response_field)],
          ["结果", safeExecutorField(contract.outcome)],
          ["已提交", String(contract.committed ?? "-")],
          ["已回滚", String(contract.rolled_back ?? "-")],
          ["拒绝语句数", safeExecutorSummaryValue(contract.refused_statement_count)],
          ["行数不匹配", safeExecutorSummaryValue(contract.row_count_mismatch)],
          ["私有操作输出", safeExecutorField(contract.operation_key_output)],
          ["失败输出", safeExecutorField(contract.error_detail_output)],
          ["执行器失败已回显", String(contract.raw_executor_error_detail_echoed ?? false)],
          ["重放标记已回显", String(contract.dedupe_material_echoed ?? false)],
          ["不安全元数据已回显", String(contract.raw_metadata_echoed ?? false)],
          ["敏感材料已回显", String(contract.credential_material_echoed ?? false)],
        ]}
      />
    </article>
  );
}

function LedgerExecutorSummaryPanel({
  heading = "账本执行器摘要",
  summary,
}: {
  heading?: string;
  summary: LedgerExecutorSummary | null | undefined;
}) {
  if (!summary) {
    return null;
  }

  return (
    <article>
      <h3>{heading}</h3>
      <Fields
        items={[
          ["模式版本", safeExecutorField(summary.schema_version)],
          ["执行器", safeExecutorField(summary.executor)],
          ["操作", safeExecutorField(summary.operation)],
          ["结果", safeExecutorField(summary.outcome)],
          ["私有操作输出", safeExecutorField(summary.operation_key_output)],
          ["已提交", String(summary.committed ?? "-")],
          ["已回滚", String(summary.rolled_back ?? "-")],
          ["语句数", safeExecutorNumber(summary.statement_count)],
          ["已执行语句数", safeExecutorNumber(summary.executed_statement_count)],
          ["拒绝语句数", safeExecutorNumber(summary.refused_statement_count)],
          ["影响行数", safeExecutorNumber(summary.total_rows_affected)],
          ["最终语句顺序", safeExecutorNumber(summary.final_statement_order)],
          ["最终语句类型", safeExecutorField(summary.final_statement_kind)],
          ["失败输出", safeExecutorField(summary.error_detail_output)],
          ["行数不匹配", String(summary.row_count_mismatch ?? "-")],
          ["执行器失败已回显", String(summary.raw_executor_error_detail_echoed ?? false)],
          ["重放标记已回显", String(summary.dedupe_material_echoed ?? false)],
          ["已省略类别", String(summary.omitted_material?.length ?? 0)],
        ]}
      />
    </article>
  );
}

function safeExecutorField(value: unknown): string {
  if (value === null || value === undefined || value === "") {
    return "-";
  }

  if (typeof value !== "string") {
    return safeFieldValue(value);
  }

  const safeValue = safeFieldValue(value.trim());

  if (
    safeValue === "-" ||
    safeValue === "[redacted]" ||
    containsUnsafeReasonText(safeValue) ||
    /\b(?:operation[_\s-]?key|error[_\s-]?detail|dedupe[_\s-]?material|credential|authorization|cookie|token)\b/i.test(
      safeValue,
    )
  ) {
    return "[redacted]";
  }

  return /^[a-z0-9_.:-]{1,160}$/i.test(safeValue) ? safeValue : "[redacted]";
}

function safeExecutorList(value: string[] | null | undefined): string {
  if (!value?.length) {
    return "-";
  }

  return value.map((entry) => safeExecutorField(entry)).join(", ");
}

function safeExecutorNumber(value: number | null | undefined): string {
  return typeof value === "number" && Number.isFinite(value) ? safeFieldValue(value) : "-";
}

function safeExecutorSummaryValue(value: boolean | number | string | null | undefined): string {
  if (typeof value === "number") {
    return safeExecutorNumber(value);
  }

  return safeExecutorField(value);
}

function LocalPaymentDemoSection({ onOpenAuditLog, onOpenUser }: BillingNavigationProps) {
  const [form, setForm] = useState<LocalPaymentDemoForm>(() => {
    const stamp = Date.now();
    return {
      ...defaultLocalPaymentDemoForm,
      idempotencyKey: `local-payment-order-${stamp}`,
      markPaidIdempotencyKey: `local-payment-paid-${stamp}`,
    };
  });
  const [createLoading, setCreateLoading] = useState(false);
  const [markPaidLoading, setMarkPaidLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<LocalPaymentDemoResponse | null>(null);

  function updateForm(field: keyof LocalPaymentDemoForm, value: string) {
    setForm((current) => ({ ...current, [field]: value }));
    setError(null);
  }

  async function handleCreate(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setCreateLoading(true);

    try {
      setResult(await createLocalPaymentDemoOrder(toLocalPaymentDemoCreateRequest(form)));
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setCreateLoading(false);
    }
  }

  async function handleMarkPaid() {
    const orderId = result?.refs.order_id ?? result?.order.id;
    if (!orderId) {
      setError("先创建本地 demo 订单。");
      return;
    }

    setError(null);
    setMarkPaidLoading(true);

    try {
      setResult(await markLocalPaymentDemoOrderPaid(orderId, toLocalPaymentDemoMarkPaidRequest(form)));
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setMarkPaidLoading(false);
    }
  }

  return (
    <>
      <section className="admin-panel" aria-label="模拟支付订单">
        <div className="section-heading">
          <div>
            <h2>模拟支付订单</h2>
            <p>本地 runtime/demo path：创建订单、标记支付、写入额度和账本、生成发票占位。不接真实商户。</p>
          </div>
          <StateChip status="local-only" />
        </div>

        <form className="filter-bar" onSubmit={handleCreate}>
          <label className="field">
            Tenant ID
            <input value={form.tenantId} onChange={(event) => updateForm("tenantId", event.currentTarget.value)} required />
          </label>
          <label className="field">
            Project ID
            <input value={form.projectId} onChange={(event) => updateForm("projectId", event.currentTarget.value)} />
          </label>
          <label className="field">
            Wallet ID
            <input
              value={form.walletId}
              onChange={(event) => updateForm("walletId", event.currentTarget.value)}
              placeholder="wallet uuid"
              required
            />
          </label>
          <label className="field field--compact">
            币种
            <input value={form.currency} onChange={(event) => updateForm("currency", event.currentTarget.value)} required />
          </label>
          <label className="field field--compact">
            金额
            <input value={form.amount} onChange={(event) => updateForm("amount", event.currentTarget.value)} required />
          </label>
          <label className="field">
            原因
            <input value={form.reason} onChange={(event) => updateForm("reason", event.currentTarget.value)} required />
          </label>
          <label className="field">
            订单幂等键
            <input value={form.idempotencyKey} onChange={(event) => updateForm("idempotencyKey", event.currentTarget.value)} required />
          </label>
          <label className="field">
            支付幂等键
            <input
              value={form.markPaidIdempotencyKey}
              onChange={(event) => updateForm("markPaidIdempotencyKey", event.currentTarget.value)}
              required
            />
          </label>
          <button className="primary-button primary-button--inline" type="submit" disabled={createLoading}>
            <Plus aria-hidden="true" size={17} />
            {createLoading ? "创建中" : "创建订单"}
          </button>
          <button
            className="secondary-button"
            type="button"
            onClick={() => void handleMarkPaid()}
            disabled={markPaidLoading || !result?.refs.order_id}
          >
            <Save aria-hidden="true" size={17} />
            {markPaidLoading ? "入账中" : "标记支付并入账"}
          </button>
        </form>

        {error ? <p className="form-status form-status--error">{error}</p> : null}
      </section>

      <section className="metric-grid" aria-label="模拟支付状态">
        <article className="metric-tile">
          <span>模式</span>
          <strong>local demo</strong>
          <small>merchant_connected=false</small>
        </article>
        <article className="metric-tile">
          <span>金额单位</span>
          <strong>decimal string</strong>
          <small>scale 8</small>
        </article>
        <article className="metric-tile">
          <span>账本</span>
          <strong>confirmed adjust</strong>
          <small>可按 wallet 查看</small>
        </article>
        <article className="metric-tile">
          <span>发票</span>
          <strong>runtime skeleton</strong>
          <small>not legal invoice</small>
        </article>
      </section>

      {result ? <LocalPaymentDemoResult result={result} onOpenAuditLog={onOpenAuditLog} onOpenUser={onOpenUser} /> : null}
    </>
  );
}

function LocalPaymentDemoResult({
  onOpenAuditLog,
  onOpenUser,
  result,
}: {
  onOpenAuditLog?: (target: AuditLogsFocusTarget) => void;
  onOpenUser?: (target: UsersFocusTarget) => void;
  result: LocalPaymentDemoResponse;
}) {
  return (
    <section className="detail-grid" aria-label="模拟支付结果">
      <article className="admin-panel">
        <div className="section-heading">
          <div>
            <h2>订单</h2>
            <p>{safeShortId(result.order.id)}</p>
          </div>
          <StateChip status={result.order.status} />
        </div>
        <Fields
          items={[
            ["结果", result.outcome],
            ["金额", moneyValue(result.order.amount, result.order.currency)],
            ["钱包", shortId(result.order.wallet_id)],
            ["Project", shortId(result.order.project_id)],
            ["来源", result.order.source],
            ["本地限定", String(result.local_only)],
          ]}
        />
        <div className="action-row">
          <SafeBillingJump kind="project" label="打开用户/项目" onOpenUser={onOpenUser} value={result.order.project_id} />
          <SafeBillingJump kind="audit" label="打开审计" onOpenAuditLog={onOpenAuditLog} value={result.refs.audit_id} />
        </div>
      </article>

      <article className="admin-panel">
        <h2>入账路径</h2>
        <Fields
          items={[
            ["Credit grant", shortId(result.refs.credit_grant_id)],
            ["Ledger entry", shortId(result.refs.ledger_entry_id)],
            ["账本类型", result.accounting.ledger_entry_type],
            ["账本状态", result.accounting.ledger_status],
            ["账本说明", result.accounting.ledger_operation],
            ["金额单位", `scale ${result.accounting.money_scale}`],
          ]}
        />
      </article>

      <article className="admin-panel">
        <h2>发票/收据</h2>
        <Fields
          items={[
            ["Invoice", shortId(result.invoice?.invoice_id ?? result.refs.invoice_id)],
            ["Invoice status", result.invoice?.status ?? "-"],
            ["Receipt", shortId(result.receipt?.receipt_id ?? result.refs.receipt_id)],
            ["Receipt status", result.receipt?.status ?? "-"],
            ["金额", moneyValue(result.invoice?.amount ?? result.order.amount, result.invoice?.currency ?? result.order.currency)],
            ["下一步", result.invoice?.next_step ?? "mark order paid to create runtime invoice skeleton"],
            ["策略", result.accounting.invoice_policy],
            ["真实商户", String(result.merchant_connected)],
            ["生产支付证据", String(result.production_payment_evidence)],
          ]}
        />
      </article>

      <article className="admin-panel">
        <h2>对账 marker</h2>
        <Fields
          items={[
            ["Marker", shortId(result.reconciliation?.marker_id ?? result.refs.reconciliation_id)],
            ["状态", result.reconciliation?.status ?? "-"],
            ["Matched", String(result.reconciliation?.matched ?? false)],
            ["Payment capture", shortId(result.reconciliation?.payment_capture_id ?? result.refs.payment_capture_id)],
            ["Ledger entry", shortId(result.reconciliation?.ledger_entry_id ?? result.refs.ledger_entry_id)],
            ["下一步", result.reconciliation?.next_step ?? "mark order paid to create reconciliation marker"],
          ]}
        />
      </article>

      <article className="admin-panel">
        <h2>发票收据对账 readback</h2>
        <Fields
          items={[
            ["状态", result.invoice_receipt_reconciliation_readback?.status ?? "-"],
            ["Invoice status", result.invoice_receipt_reconciliation_readback?.invoice_status ?? result.invoice?.status ?? "-"],
            ["Receipt status", result.invoice_receipt_reconciliation_readback?.receipt_status ?? result.receipt?.status ?? "-"],
            ["Payment refs", String(result.invoice_receipt_reconciliation_readback?.payment_refs_presence.present ?? false)],
            ["Ledger refs", String(result.invoice_receipt_reconciliation_readback?.ledger_refs_presence.present ?? false)],
            [
              "Reconciliation status",
              result.invoice_receipt_reconciliation_readback?.reconciliation_status ?? result.reconciliation?.status ?? "-",
            ],
            ["下一步", result.invoice_receipt_reconciliation_readback?.safe_next_action ?? "-"],
            ["真实商户", String(result.invoice_receipt_reconciliation_readback?.merchant_connected ?? result.merchant_connected)],
            [
              "生产支付证据",
              String(result.invoice_receipt_reconciliation_readback?.production_payment_evidence ?? result.production_payment_evidence),
            ],
          ]}
        />
      </article>

      <article className="admin-panel">
        <h2>安全响应</h2>
        <Fields
          items={[
            ["secret_safe", String(result.secret_safe)],
            ["idempotency echo disabled", String(!result.raw_idempotency_key_echoed)],
            ["metadata echo disabled", String(!result.raw_metadata_echoed)],
            ["provider payload echo disabled", String(!result.raw_provider_payload_echoed)],
            [
              "Authorization echo disabled",
              String(!(result.invoice_receipt_reconciliation_readback?.authorization_echoed ?? false)),
            ],
          ]}
        />
      </article>

      <article className="admin-panel admin-panel--wide">
        <h2>本地 demo readback</h2>
        <JsonBlock value={result} />
      </article>
    </section>
  );
}

type LedgerAdjustmentExecuteDisplayFlags = {
  auditLogWrite: boolean;
  futureWriterRequired: boolean;
  ledgerWrite: boolean;
  requestLogWrite: boolean;
  serverGeneratedWriteMarker: boolean;
  upstreamCall: boolean;
  writeMarkerEchoed: boolean;
};

function executeReadinessStatus(result: LedgerAdjustmentExecuteResult, fresh: boolean): string {
  if (!fresh) {
    return "执行契约检查已过期。任何执行步骤前都需要重新运行 dry-run 和契约检查。";
  }

  if (result.kind === "writer_required") {
    return "future_writer_required：后端已验证计划，但在 writer 可用前拒绝执行。";
  }

  if (result.kind === "future_execute") {
    const outcome = executeOutcome(result.response);

    if (outcome === "applied") {
      return "账本调整已应用：账本和审计写入已确认。";
    }

    if (outcome === "idempotent") {
      return "幂等重放：返回既有账本条目，没有新的账本或审计写入。";
    }

    if (outcome === "blocked") {
      return "账本调整执行在写入前被阻止。";
    }

    return "账本调整执行失败或返回了无法识别的结果。";
  }

  return "执行契约已验证，未进行账本、请求日志、审计或上游写入。";
}

function executeStatus(
  result: LedgerAdjustmentExecuteResult | null,
  state: {
    dryRunFresh: boolean;
    errorKind?: "blocked" | "failed";
    executeFresh: boolean;
    executing?: boolean;
    hasDryRun: boolean;
  },
): string {
  if (state.executing) {
    return "pending";
  }

  if (state.errorKind) {
    return state.errorKind;
  }

  if (!state.hasDryRun) {
    return "dry_run_required";
  }

  if (!state.dryRunFresh) {
    return "stale_plan";
  }

  if (!result) {
    return "execute_preflight";
  }

  if (!state.executeFresh) {
    return "blocked";
  }

  if (result.kind === "writer_required") {
    return "blocked";
  }

  if (result.kind === "future_execute") {
    const outcome = executeOutcome(result.response);

    if (outcome === "applied" || outcome === "idempotent" || (outcome === "unknown" && result.response.executed)) {
      return outcome === "unknown" ? "applied" : outcome;
    }

    if (outcome === "blocked") {
      return "blocked";
    }

    return "failed";
  }

  return "execute_preflight";
}

function shouldRefreshLedgerEntriesAfterExecute(result: LedgerAdjustmentExecuteResult): boolean {
  if (result.kind !== "future_execute") {
    return false;
  }

  const outcome = executeOutcome(result.response);

  return (
    outcome === "applied" ||
    outcome === "idempotent" ||
    Boolean(result.response.ledger_write || result.response.audit_log_write)
  );
}

function executeRefreshStatusText(state: LedgerAdjustmentExecuteRefreshState): string {
  if (state.status === "pending") {
    return "执行后正在刷新账本条目。";
  }

  if (state.status === "success") {
    return "执行后账本条目已刷新；本次执行结果匹配当前 dry-run payload。";
  }

  if (state.status === "error") {
    return `执行结果匹配当前 dry-run payload，但账本条目刷新失败。${safeFieldValue(
      state.message ?? "请求失败。",
    )}`;
  }

  return "执行结果匹配当前 dry-run payload。";
}

function executeBlockedReasons(result: LedgerAdjustmentExecuteResult, fresh: boolean): string[] {
  if (!fresh) {
    return ["stale_contract_check"];
  }

  if (result.kind === "writer_required") {
    const contract = result.response.execute_contract;
    const reasons = ["future_writer_required"];

    if (contract.validated_before_refusal) {
      reasons.push("validated_before_refusal");
    }

    if (contract.refusal_does_not_build_success_audit) {
      reasons.push("success_audit_not_built");
    }

    if (contract.ledger_writer_contract?.future_writer) {
      reasons.push("transactional_writer_pending");
    }

    return reasons;
  }

  if (result.kind === "future_execute") {
    const outcome = executeOutcome(result.response);

    if (outcome === "blocked") {
      return ["execute_blocked"];
    }

    if (outcome !== "applied" && outcome !== "idempotent" && !result.response.executed) {
      return ["execute_failed"];
    }
  }

  return [];
}

function executeResultLabel(result: LedgerAdjustmentExecuteResult): string {
  if (result.kind === "writer_required") {
    return "future_writer_required";
  }

  if (result.kind === "future_execute") {
    return executeOutcome(result.response);
  }

  return "execute contract";
}

function executeFlags(result: LedgerAdjustmentExecuteResult): LedgerAdjustmentExecuteDisplayFlags {
  if (result.kind === "future_execute") {
    return {
      auditLogWrite: result.response.audit_log_write,
      futureWriterRequired: false,
      ledgerWrite: result.response.ledger_write,
      requestLogWrite: result.response.request_log_write,
      serverGeneratedWriteMarker: false,
      upstreamCall: result.response.upstream_call,
      writeMarkerEchoed: Boolean(result.response.dedupe_material_echoed),
    };
  }

  return {
    auditLogWrite: result.response.execute_contract.audit_log_write,
    futureWriterRequired: Boolean(result.response.execute_contract.future_writer_required),
    ledgerWrite: result.response.execute_contract.ledger_write,
    requestLogWrite: result.response.execute_contract.request_log_write,
    serverGeneratedWriteMarker: Boolean(result.response.execute_contract.server_generated_dedupe_material),
    upstreamCall: result.response.execute_contract.upstream_call,
    writeMarkerEchoed: Boolean(result.response.execute_contract.dedupe_material_echoed),
  };
}

function executeAuditSnapshotPolicy(result: LedgerAdjustmentExecuteResult): string {
  if (result.kind === "future_execute") {
    return "-";
  }

  return result.response.execute_contract.audit_snapshot_policy ?? "-";
}

function executeOutcome(response: LedgerAdjustmentFutureExecuteResponse): string {
  if (response.outcome) {
    return safeFieldValue(response.outcome);
  }

  return response.executed ? "applied" : "unknown";
}

function executeErrorState(error: unknown): LedgerAdjustmentExecuteErrorState {
  const status = apiStatusCode(error);
  const kind = status && status >= 400 && status < 500 ? "blocked" : "failed";
  const safeMessage = errorMessage(error);
  const fallback = kind === "blocked" ? "账本调整执行被阻止。" : "账本调整执行失败。";

  return {
    kind,
    message: safeMessage === "Request failed." ? fallback : `${fallback} ${safeMessage}`,
  };
}

function apiStatusCode(error: unknown): number | undefined {
  if (typeof error !== "object" || error === null || !("status" in error)) {
    return undefined;
  }

  const status = (error as { status?: unknown }).status;
  return typeof status === "number" ? status : undefined;
}

function writeMarkerPolicy(policy: string): string {
  if (policy === "server_generated_on_execute") {
    return "server generated on execute";
  }

  return safeFieldValue(policy);
}

function LedgerAdjustmentDryRunResult({
  dryRunFresh,
  result,
}: {
  dryRunFresh: boolean;
  result: LedgerAdjustmentDryRunResponse;
}) {
  const plannedEntry = result.planned_ledger_entry;
  const relatedEntry = result.related_ledger_entry;
  const futureContract = result.future_write_contract;

  return (
    <section className="detail-grid" aria-label="账本调整 dry-run 结果">
      <article className="admin-panel">
        <div className="section-heading">
          <div>
            <h2>计划标记</h2>
            <p>{formatStatus(result.operation)} dry-run 返回了仅规划响应。</p>
          </div>
          <StateChip status={plannedEntry.status} />
        </div>
        <div className="manual-test-flags" aria-label="仅规划标记">
          <span>plan_only={String(result.plan_only)}</span>
          <span>fresh_dry_run={String(dryRunFresh)}</span>
          <span>ledger_write={String(result.ledger_write)}</span>
          <span>request_log_write={String(result.request_log_write)}</span>
          <span>audit_log_write={String(result.audit_log_write)}</span>
          <span>upstream_call={String(result.upstream_call)}</span>
        </div>
        <Fields
          items={[
            ["Tenant", shortId(result.tenant_id)],
            ["Project", shortId(result.project_id)],
            ["钱包", shortId(result.wallet_id)],
            ["Request", shortId(result.request_id)],
            ["金额已检查", String(result.validation.amount_checked)],
            ["币种已检查", String(result.validation.currency_checked)],
            ["关联条目已检查", String(result.validation.related_ledger_entry_checked)],
            ["剩余退款已检查", String(result.validation.refund_remaining_checked)],
            ["已提供原因", String(result.validation.reason_provided)],
            ["敏感材料", result.validation.sensitive_material_policy],
          ]}
        />
      </article>

      <LedgerAdjustmentExecutionReadbackPanel readback={result.ledger_adjustment_execution_readback} />

      <article className="admin-panel">
        <div className="section-heading">
          <div>
            <h2>计划账本条目</h2>
            <p>此页面不会写入账本条目。</p>
          </div>
          <StateChip status={plannedEntry.entry_type} />
        </div>
        <Fields
          items={[
            ["类型", formatStatus(plannedEntry.entry_type)],
            ["金额", moneyValue(plannedEntry.amount, plannedEntry.currency)],
            ["状态", plannedEntry.status],
            ["Project", shortId(plannedEntry.project_id)],
            ["钱包", shortId(plannedEntry.wallet_id)],
            ["Request", shortId(plannedEntry.request_id)],
            ["关联条目", shortId(plannedEntry.related_ledger_entry_id)],
            ["写入标记策略", writeMarkerPolicy(plannedEntry.dedupe_policy)],
            ["元数据策略", plannedEntry.metadata_policy],
          ]}
        />
      </article>

      <article className="admin-panel">
        <h2>关联条目摘要</h2>
        {relatedEntry ? (
          <Fields
            items={[
              ["条目", shortId(relatedEntry.id)],
              ["类型", formatStatus(relatedEntry.entry_type)],
              ["金额", moneyValue(relatedEntry.amount, relatedEntry.currency)],
              ["状态", relatedEntry.status],
              ["Project", shortId(relatedEntry.project_id)],
              ["钱包", shortId(relatedEntry.wallet_id)],
              ["Request", shortId(relatedEntry.request_id)],
              ["关联条目", shortId(relatedEntry.related_ledger_entry_id)],
            ]}
          />
        ) : (
          <p className="muted-copy">此调整计划没有返回关联条目摘要。</p>
        )}
      </article>

      {result.refund_remaining_summary ? (
        <article className="admin-panel">
          <h2>剩余可退款</h2>
          <Fields
            items={[
              [
                "剩余",
                moneyValue(result.refund_remaining_summary.remaining_refundable_amount, result.refund_remaining_summary.currency),
              ],
              [
                "请求",
                moneyValue(result.refund_remaining_summary.requested_refund_amount, result.refund_remaining_summary.currency),
              ],
              [
                "来源借记",
                moneyValue(result.refund_remaining_summary.source_debit_amount, result.refund_remaining_summary.currency),
              ],
              [
                "已确认贷记",
                moneyValue(result.refund_remaining_summary.confirmed_credit_amount, result.refund_remaining_summary.currency),
              ],
              ["已确认贷记数", String(result.refund_remaining_summary.confirmed_credit_count)],
              ["租户有界", String(result.refund_remaining_summary.tenant_bounded)],
              ["来源有界", String(result.refund_remaining_summary.source_entry_bounded)],
              ["币种有界", String(result.refund_remaining_summary.currency_bounded)],
              ["仅确认项", String(result.refund_remaining_summary.confirmed_only)],
              ["贷记条目类型", result.refund_remaining_summary.credit_entry_types.join(", ")],
            ]}
          />
        </article>
      ) : null}

      <article className="admin-panel">
        <h2>未来审计 / 写入契约</h2>
        <Fields
          items={[
            ["审计动作", futureContract.audit_action],
            ["账本写入", String(futureContract.ledger_write)],
            ["上游调用", String(futureContract.upstream_call)],
            ["审计快照", futureContract.audit_snapshot_policy],
            ["共享事务", String(futureContract.business_and_success_audit_share_transaction)],
            ["成功审计时机", String(futureContract.success_audit_only_after_ledger_write)],
            ["审计回滚", String(futureContract.audit_insert_failure_rolls_back_ledger_write)],
            ["拒绝审计", String(futureContract.refusal_does_not_build_success_audit)],
          ]}
        />
      </article>
    </section>
  );
}

function ReconciliationSection({
  onOpenRequestDetail,
  onOpenTrace,
  onOpenUser,
}: Pick<BillingNavigationProps, "onOpenRequestDetail" | "onOpenTrace" | "onOpenUser">) {
  const [error, setError] = useState<string | null>(null);
  const [filters, setFilters] = useState<ReconciliationFilterState>(defaultReconciliationFilters);
  const [loading, setLoading] = useState(true);
  const [report, setReport] = useState<BillingReconciliationReport | null>(null);

  async function loadReport(nextFilters = filters) {
    setError(null);
    setLoading(true);

    try {
      setReport(await getBillingReconciliationReport(toReconciliationFilters(nextFilters)));
    } catch (requestError) {
      setError(errorMessage(requestError));
      setReport(null);
    } finally {
      setLoading(false);
    }
  }

  function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    void loadReport(filters);
  }

  useEffect(() => {
    void loadReport(defaultReconciliationFilters);
  }, []);

  return (
    <>
      <section className="admin-panel" aria-label="对账筛选">
        <div className="section-heading">
          <div>
            <h2>对账</h2>
            <p>按 UTC 日对比请求最终成本与结算、退款账本条目。</p>
          </div>
          <button className="secondary-button" type="button" onClick={() => void loadReport()} disabled={loading}>
            <RefreshCw aria-hidden="true" size={18} className={loading ? "spin" : undefined} />
            刷新
          </button>
        </div>

        <form className="filter-bar filter-bar--compact" onSubmit={handleSubmit}>
          <label className="field">
            日期
            <input
              type="date"
              value={filters.day}
              onChange={(event) => {
                const day = event.currentTarget.value;
                setFilters((current) => ({ ...current, day }));
              }}
            />
          </label>
          <label className="field field--compact">
            限制
            <input
              min="1"
              max="500"
              type="number"
              value={filters.limit}
              onChange={(event) => {
                const limit = event.currentTarget.value;
                setFilters((current) => ({ ...current, limit }));
              }}
            />
          </label>
          <label className="field">
            Request ID
            <input
              value={filters.requestId}
              onChange={(event) => {
                const requestId = event.currentTarget.value;
                setFilters((current) => ({ ...current, requestId }));
              }}
              placeholder="request uuid"
            />
          </label>
          <button className="primary-button primary-button--inline" type="submit">
            <Search aria-hidden="true" size={17} />
            搜索
          </button>
        </form>

        {report ? (
          <p className="muted-copy">
            周期 {formatDate(report.period_start)} 至 {formatDate(report.period_end)}。
          </p>
        ) : null}
        {error ? <p className="form-status form-status--error">{error}</p> : null}
      </section>

      {report ? <ReconciliationStats report={report} /> : null}
      {report ? <ReconciliationSummaryJson report={report} /> : null}

      <ReconciliationCurrencyTotals loading={loading} totals={report?.summary.currency_totals ?? []} />
      <ReconciliationDiscrepancies
        discrepancies={report?.discrepancies ?? []}
        loading={loading}
        onOpenRequestDetail={onOpenRequestDetail}
        onOpenTrace={onOpenTrace}
        onOpenUser={onOpenUser}
      />
    </>
  );
}

function PriceVersionStats({ versions }: { versions: PriceVersion[] }) {
  return (
    <section className="feature-stats" aria-label="价格版本摘要">
      <MetricCard label="版本数" tone="neutral" value={versions.length} />
      <MetricCard label="活跃" tone="good" value={countByStatus(versions, "active")} />
      <MetricCard label="草稿" tone="warn" value={countByStatus(versions, "draft")} />
      <MetricCard label="模型限定" tone="neutral" value={versions.filter((version) => version.canonical_model_id).length} />
    </section>
  );
}

function SubscriptionPlanStats({ plans }: { plans: SubscriptionPlan[] }) {
  return (
    <section className="feature-stats" aria-label="订阅套餐摘要">
      <MetricCard label="套餐数" tone="neutral" value={plans.length} />
      <MetricCard label="启用" tone="good" value={plans.filter((plan) => plan.status === "active").length} />
      <MetricCard label="草稿" tone="warn" value={plans.filter((plan) => plan.status === "draft").length} />
      <MetricCard label="scheduler" tone="warn" value="pending" />
    </section>
  );
}

function PriceRuleRateSummary({ rules }: { rules: JsonValue }) {
  const summary = priceRuleSummary(rules);

  return (
    <>
      <span>input {moneyValue(summary.inputTokenRatePer1m, summary.currency)}</span>
      <span>output {moneyValue(summary.outputTokenRatePer1m, summary.currency)}</span>
      <span>cache {moneyValue(summary.cacheTokenRatePer1m, summary.currency)}</span>
      <span>reasoning {moneyValue(summary.reasoningTokenRatePer1m, summary.currency)}</span>
    </>
  );
}

function WalletStats({ wallets }: { wallets: AdminWalletCreditSurface[] }) {
  return (
    <section className="feature-stats" aria-label="钱包摘要">
      <MetricCard label="钱包数" tone="neutral" value={wallets.length} />
      <MetricCard label="启用" tone="good" value={wallets.filter((surface) => surface.wallet.status === "active").length} />
      <MetricCard label="active grants" tone="neutral" value={walletCreditGrantTotal(wallets)} />
      <MetricCard label="可用余额" tone="neutral" value={walletAvailableTotals(wallets)} />
    </section>
  );
}

function LedgerStats({ entries }: { entries: LedgerEntry[] }) {
  return (
    <section className="feature-stats" aria-label="账本摘要">
      <MetricCard label="条目数" tone="neutral" value={entries.length} />
      <MetricCard label="已确认" tone="good" value={entries.filter((entry) => entry.status === "confirmed").length} />
      <MetricCard label="待处理" tone="warn" value={entries.filter((entry) => entry.status === "pending").length} />
      <MetricCard label="净额" tone="neutral" value={ledgerTotals(entries)} />
    </section>
  );
}

function WalletDetail({
  onOpenAuditLog,
  onOpenRequestDetail,
  onOpenTrace,
  onOpenUser,
  surface,
}: BillingNavigationProps & { surface: AdminWalletCreditSurface }) {
  const wallet = surface.wallet;
  const grants = surface.credit_grants.grants;

  return (
    <section className="detail-grid" aria-label="钱包余额详情">
      <article className="admin-panel">
        <div className="section-heading">
          <div>
            <h2>余额公式</h2>
            <p>{wallet.id}</p>
          </div>
          <StateChip status={wallet.status} />
        </div>
        <Fields
          items={[
            ["可用余额", walletAvailableMoney(surface)],
            ["active credit grants", moneyValue(surface.credit_grants.active_remaining_total, wallet.currency)],
            ["confirmed ledger", moneyValue(surface.ledger_balance_window.confirmed_net_amount, wallet.currency)],
            ["pending ledger", moneyValue(surface.ledger_balance_window.pending_amount, wallet.currency)],
            ["balance floor", moneyValue(wallet.balance_floor, wallet.currency)],
            ["公式", "active grants + confirmed/pending ledger - balance floor"],
            ["只读", String(surface.read_only)],
            ["敏感信息安全", String(adminWalletSecretSafe(surface.secret_safe))],
          ]}
        />
        <div className="action-row">
          <SafeBillingJump kind="project" label="打开用户/项目" onOpenUser={onOpenUser} value={wallet.project_id} />
        </div>
      </article>

      <article className="admin-panel">
        <h2>账本窗口</h2>
        <Fields
          items={[
            ["窗口", `${formatDate(surface.ledger_balance_window.window_start)} - ${formatDate(surface.ledger_balance_window.window_end)}`],
            ["confirmed debit", moneyValue(surface.ledger_balance_window.confirmed_debit_total, wallet.currency)],
            ["confirmed credit", moneyValue(surface.ledger_balance_window.confirmed_credit_total, wallet.currency)],
            ["confirmed net", moneyValue(surface.ledger_balance_window.confirmed_net_amount, wallet.currency)],
            ["pending", moneyValue(surface.ledger_balance_window.pending_amount, wallet.currency)],
            ["reversed", moneyValue(surface.ledger_balance_window.reversed_amount, wallet.currency)],
            ["条目数", surface.ledger_balance_window.ledger_entry_count],
            ["最近确认条目", shortId(surface.ledger_balance_window.last_confirmed_ledger_entry_id)],
          ]}
        />
      </article>

      <article className="admin-panel">
        <h2>Pending reserves</h2>
        <Fields
          items={[
            ["数量", surface.pending_reserves.reserve_count],
            ["金额", moneyValue(surface.pending_reserves.reserve_amount_total, wallet.currency)],
            ["最早", formatDate(surface.pending_reserves.oldest_pending_reserve_at)],
            ["最新", formatDate(surface.pending_reserves.newest_pending_reserve_at)],
          ]}
        />
      </article>

      <article className="admin-panel">
        <h2>Refs</h2>
        <dl className="detail-list">
          <div>
            <dt>Ledger entries</dt>
            <dd>{formatIdList(surface.bounded_links.ledger_entry_ids ?? surface.last_ledger_entry_ids)}</dd>
          </div>
          <div>
            <dt>Requests</dt>
            <dd>
              <SafeBillingJumpList
                kind="request"
                label="Request"
                onOpenRequestDetail={onOpenRequestDetail}
                values={surface.bounded_links.request_ids ?? []}
              />
            </dd>
          </div>
          <div>
            <dt>Traces</dt>
            <dd>
              <SafeBillingJumpList kind="trace" label="Trace" onOpenTrace={onOpenTrace} values={surface.bounded_links.trace_ids ?? []} />
            </dd>
          </div>
          <div>
            <dt>Audit logs</dt>
            <dd>
              <SafeBillingJumpList
                kind="audit"
                label="Audit"
                onOpenAuditLog={onOpenAuditLog}
                values={surface.bounded_links.audit_log_ids ?? []}
              />
            </dd>
          </div>
          <div>
            <dt>Link policy</dt>
            <dd>{safeFieldValue(surface.bounded_links.link_policy)}</dd>
          </div>
        </dl>
      </article>

      <article className="admin-panel">
        <h2>Credit grants</h2>
        <div className="health-table-wrap">
          <table className="health-table admin-table admin-table--credit-grants">
            <thead>
              <tr>
                <th>Grant</th>
                <th>状态</th>
                <th>来源</th>
                <th>金额</th>
                <th>剩余</th>
                <th>有效期</th>
              </tr>
            </thead>
            <tbody>
              {grants.length > 0 ? (
                grants.map((grant) => (
                  <tr key={grant.id}>
                    <td>{shortId(grant.id)}</td>
                    <td>
                      <StateChip status={grant.status} />
                    </td>
                    <td>{safeFieldValue(grant.source)}</td>
                    <td>{moneyValue(grant.amount, grant.currency)}</td>
                    <td>{moneyValue(grant.remaining_amount, grant.currency)}</td>
                    <td>
                      <span>{formatDate(grant.valid_from)}</span>
                      <span>{formatDate(grant.valid_until)}</span>
                    </td>
                  </tr>
                ))
              ) : (
                <tr>
                  <td colSpan={6}>没有返回 credit grants。</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </article>

      <article className="admin-panel">
        <h2>一致性快照</h2>
        <JsonBlock value={surface.consistency} />
      </article>
    </section>
  );
}

function ReconciliationStats({ report }: { report: BillingReconciliationReport }) {
  const { summary } = report;

  return (
    <section className="feature-stats" aria-label="对账摘要">
      <MetricCard label="请求数" tone="neutral" value={summary.request_count} />
      <MetricCard label="已匹配" tone="good" value={summary.matched_request_count} />
      <MetricCard label="差异数" tone="warn" value={summary.discrepancy_count} />
      <MetricCard label="返回行数" tone="neutral" value={summary.returned_discrepancy_count} />
    </section>
  );
}

function ReconciliationSummaryJson({ report }: { report: BillingReconciliationReport }) {
  return (
    <section className="admin-panel" aria-label="对账安全 JSON 摘要">
      <h2>摘要 JSON</h2>
      <JsonBlock
        value={{
          period_end: report.period_end,
          period_start: report.period_start,
          report_version: report.report_version,
          summary: report.summary as unknown as JsonValue,
        }}
      />
    </section>
  );
}

function ReconciliationCurrencyTotals({
  loading,
  totals,
}: {
  loading: boolean;
  totals: BillingReconciliationCurrencyTotal[];
}) {
  return (
    <section aria-label="对账币种汇总">
      <div className="health-table-wrap">
        <table className="health-table admin-table admin-table--reconciliation-totals">
          <thead>
            <tr>
              <th>币种</th>
              <th>请求最终成本</th>
              <th>预期账本金额</th>
              <th>账本金额</th>
              <th>差异</th>
            </tr>
          </thead>
          <tbody>
            {loading && totals.length === 0 ? (
              <tr>
                <td colSpan={5}>正在加载对账汇总。</td>
              </tr>
            ) : totals.length > 0 ? (
              totals.map((total) => (
                <tr key={total.currency}>
                  <td>
                    <strong>{safeFieldValue(total.currency)}</strong>
                  </td>
                  <td>{safeFieldValue(total.request_final_cost_total)}</td>
                  <td>{safeFieldValue(total.expected_ledger_amount_total)}</td>
                  <td>{safeFieldValue(total.ledger_amount_total)}</td>
                  <td>{safeFieldValue(total.difference_amount)}</td>
                </tr>
              ))
            ) : (
              <tr>
                <td colSpan={5}>没有返回币种汇总。</td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </section>
  );
}

function ReconciliationDiscrepancies({
  discrepancies,
  loading,
  onOpenRequestDetail,
  onOpenTrace,
  onOpenUser,
}: {
  discrepancies: BillingReconciliationDiscrepancy[];
  loading: boolean;
  onOpenRequestDetail?: (requestId: string) => void;
  onOpenTrace?: (traceId: string) => void;
  onOpenUser?: (target: UsersFocusTarget) => void;
}) {
  return (
    <section aria-label="对账差异行">
      <div className="health-table-wrap">
        <table className="health-table admin-table admin-table--reconciliation">
          <thead>
            <tr>
              <th>问题</th>
              <th>请求</th>
              <th>账本</th>
              <th>金额</th>
              <th>范围</th>
              <th>用量</th>
              <th>路由</th>
              <th>Models</th>
            </tr>
          </thead>
          <tbody>
            {loading && discrepancies.length === 0 ? (
              <tr>
                <td colSpan={8}>正在加载对账差异。</td>
              </tr>
            ) : discrepancies.length > 0 ? (
              discrepancies.map((discrepancy, index) => (
                <tr key={(discrepancy.request_id ?? discrepancy.ledger_entry_ids.join(":")) || index}>
                  <td>
                    <IssueList issues={discrepancy.issues} />
                  </td>
                  <td>
                    <SafeBillingJump
                      kind="request"
                      label="Request"
                      onOpenRequestDetail={onOpenRequestDetail}
                      value={discrepancy.request_id}
                    />
                    <SafeBillingJump kind="trace" label="Trace" onOpenTrace={onOpenTrace} value={discrepancy.trace_id} />
                    <span>状态 {safeFieldValue(discrepancy.request_status)}</span>
                  </td>
                  <td>
                    <strong>{formatIdList(discrepancy.ledger_entry_ids)}</strong>
                  </td>
                  <td>
                    <strong>{moneyValue(discrepancy.request_final_cost, discrepancy.request_currency)}</strong>
                    <span>{legacyCurrencyAmount(discrepancy.request_final_cost, discrepancy.request_currency)}</span>
                    <span>预期 {moneyValue(discrepancy.expected_ledger_amount, discrepancy.request_currency)}</span>
                    <span>账本 {moneyValue(discrepancy.ledger_amount, discrepancy.ledger_currency)}</span>
                    <span>差异 {safeFieldValue(discrepancy.difference_amount)}</span>
                  </td>
                  <td>
                    <SafeBillingJump
                      kind="project"
                      label="项目"
                      onOpenUser={onOpenUser}
                      value={discrepancy.project_id}
                    />
                    <span>Virtual Key {safeShortId(discrepancy.virtual_key_id)}</span>
                  </td>
                  <td>
                    <span>输入 {safeFieldValue(discrepancy.input_tokens)}</span>
                    <span>输出 {safeFieldValue(discrepancy.output_tokens)}</span>
                  </td>
                  <td>
                    <span>Provider {safeShortId(discrepancy.resolved_provider_id)}</span>
                    <span>Channel {safeShortId(discrepancy.resolved_channel_id)}</span>
                    <span>模型 {safeShortId(discrepancy.canonical_model_id)}</span>
                  </td>
                  <td>
                    <span>请求模型 {safeFieldValue(discrepancy.requested_model)}</span>
                    <span>上游模型 {safeFieldValue(discrepancy.upstream_model)}</span>
                  </td>
                </tr>
              ))
            ) : (
              <tr>
                <td colSpan={8}>没有返回对账差异。</td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </section>
  );
}

function IssueList({ issues }: { issues: string[] }) {
  return (
    <div className="issue-list">
      {issues.length > 0 ? (
        issues.map((issue) => (
          <span className={`issue-pill issue-pill--${issueTone(issue)}`} key={issue}>
            {formatStatus(issue)}
          </span>
        ))
      ) : (
        <span className="issue-pill issue-pill--neutral">-</span>
      )}
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

function PriceVersionDetail({ version }: { version: PriceVersion }) {
  const summary = priceRuleSummary(version.pricing_rules);

  return (
    <section className="detail-grid" aria-label="价格版本详情">
      <article className="admin-panel">
        <div className="section-heading">
          <div>
            <h2>价格版本详情</h2>
            <p>{version.id}</p>
          </div>
          <StateChip status={version.status} />
        </div>
        <Fields
          items={[
            ["版本", version.version],
            ["价格簿", shortId(version.price_book_id)],
            ["模型", shortId(version.canonical_model_id)],
            ["生效时间", formatDate(version.effective_at)],
            ["退役时间", version.retired_at ? formatDate(version.retired_at) : "-"],
            ["创建时间", formatDate(version.created_at)],
          ]}
        />
      </article>

      <article className="admin-panel">
        <h2>计费规则</h2>
        <Fields
          items={[
            ["币种", summary.currency],
            ["input / 1M", moneyValue(summary.inputTokenRatePer1m, summary.currency)],
            ["output / 1M", moneyValue(summary.outputTokenRatePer1m, summary.currency)],
            ["cache / 1M", moneyValue(summary.cacheTokenRatePer1m, summary.currency)],
            ["reasoning / 1M", moneyValue(summary.reasoningTokenRatePer1m, summary.currency)],
            ["固定请求成本", moneyValue(summary.fixedRequestCost, summary.currency)],
            ["金额精度", summary.scale],
          ]}
        />
      </article>

      <article className="admin-panel">
        <h2>安全跳转</h2>
        <p className="muted-copy">
          Price version 当前只暴露 price book、canonical model、status 和费率摘要；没有 request_id、trace_id、user/project 或 audit_log_id
          时显示占位，不读取敏感 metadata、幂等材料或 secret。
        </p>
        <div className="action-row">
          <SafeBillingJump kind="request" label="Request" value={undefined} />
          <SafeBillingJump kind="trace" label="Trace" value={undefined} />
          <SafeBillingJump kind="project" label="Project" value={undefined} />
          <SafeBillingJump kind="audit" label="Audit" value={undefined} />
        </div>
      </article>

      <article className="admin-panel">
        <h2>计费规则 JSON</h2>
        <JsonBlock value={sanitizeSecretJson(version.pricing_rules)} />
      </article>
    </section>
  );
}

function SubscriptionPlanDetail({ plan }: { plan: SubscriptionPlan }) {
  return (
    <section className="detail-grid" aria-label="订阅套餐详情">
      <article className="admin-panel">
        <div className="section-heading">
          <div>
            <h2>套餐详情</h2>
            <p>{plan.id}</p>
          </div>
          <StateChip status={plan.status} />
        </div>
        <Fields
          items={[
            ["套餐代码", plan.plan_code],
            ["展示名称", plan.display_name],
            ["周期", formatStatus(plan.billing_interval)],
            ["价格", moneyValue(plan.unit_price, plan.currency)],
            ["包含额度", moneyValue(plan.included_credit_amount, plan.currency)],
            ["试用天数", plan.trial_days],
            ["创建时间", formatDate(plan.created_at)],
            ["更新时间", formatDate(plan.updated_at)],
          ]}
        />
      </article>

      <article className="admin-panel">
        <h2>安全边界</h2>
        <Fields
          items={[
            ["支付接入", formatStatus(plan.payment_status)],
            ["续费调度", formatStatus(plan.scheduler_status)],
            ["保存套餐会扣费", "false"],
            ["保存套餐会发放额度", "false"],
            ["raw payment payload", String(plan.raw_payment_payload_returned)],
            ["Secret safe", String(plan.secret_safe)],
          ]}
        />
      </article>

      {plan.subscription_lifecycle_readback ? (
        <SubscriptionLifecycleReadbackPanel readback={plan.subscription_lifecycle_readback} />
      ) : null}

      <article className="admin-panel">
        <h2>额度 / 过期策略</h2>
        <JsonBlock value={sanitizeSecretJson(plan.expiration_policy)} />
      </article>

      <article className="admin-panel">
        <h2>套餐 Metadata</h2>
        <JsonBlock value={sanitizeSecretJson(plan.metadata)} />
      </article>
    </section>
  );
}

function SubscriptionLifecycleReadbackPanel({
  readback,
}: {
  readback: SubscriptionPlan["subscription_lifecycle_readback"];
}) {
  if (!readback) {
    return null;
  }

  return (
    <article className="admin-panel">
      <h2>Lifecycle readback</h2>
      <Fields
        items={[
          ["Plan", readback.current_plan?.plan_code ?? shortId(readback.current_plan?.plan_id)],
          ["Plan status", readback.current_plan?.subscription_status ?? readback.current_plan?.status],
          ["Period", lifecycleReadbackStatus(readback.period_status)],
          ["Credit ref", String(readback.quota_or_credit_grant_refs_presence?.credit_grant_ref_present ?? false)],
          ["Ledger ref", String(readback.quota_or_credit_grant_refs_presence?.ledger_entry_ref_present ?? false)],
          ["Scheduler ref", String(readback.scheduler_event_refs_presence?.subscription_event_ref_present ?? false)],
          ["Payment handoff", formatStatus(readback.payment_handoff_status?.status ?? "unknown")],
          ["Provider fetch/capture", String(readback.payment_handoff_status?.network_call_performed ?? false)],
          ["Secret safe", String(readback.secret_safe)],
        ]}
      />
      <p className="muted-copy">{safeFieldValue(readback.safe_next_action)}</p>
    </article>
  );
}

function lifecycleReadbackStatus(value: JsonValue): string {
  if (isJsonRecord(value)) {
    return safeFieldValue(value.status ?? value.event_status ?? value.current_period_end ?? "readback_present");
  }
  return safeFieldValue(value);
}

function SubscriptionPlanUserPlaceholder() {
  return (
    <section className="admin-panel" aria-label="用户侧套餐占位">
      <h2>用户侧套餐入口占位</h2>
      <p className="muted-copy">用户门户可以安全展示套餐入口；在支付和 renewal scheduler 接入前，只展示套餐说明和 pending 状态，不创建订单、不自动续费、不发放额度。</p>
    </section>
  );
}

function LedgerEntryDetail({
  entry,
  onOpenRequestDetail,
  onOpenTrace,
  onOpenUser,
}: Pick<BillingNavigationProps, "onOpenRequestDetail" | "onOpenTrace" | "onOpenUser"> & { entry: LedgerEntry }) {
  return (
    <section className="detail-grid" aria-label="账本条目详情">
      <article className="admin-panel">
        <div className="section-heading">
          <div>
            <h2>账本条目详情</h2>
            <p>{entry.id}</p>
          </div>
          <StateChip status={entry.status} />
        </div>
        <Fields
          items={[
            ["类型", formatStatus(entry.entry_type)],
            ["金额", moneyValue(entry.amount, entry.currency)],
            ["钱包", shortId(entry.wallet_id)],
            ["价格版本", shortId(entry.price_version_id)],
            ["关联条目", shortId(entry.related_ledger_entry_id)],
            ["Voucher", ledgerMetadataRef(entry.metadata, ["voucher_id", "voucherId"])],
            ["Order", ledgerMetadataRef(entry.metadata, ["order_id", "orderId", "payment_order_id"])],
          ]}
        />
        <div className="action-row">
          <SafeBillingJump kind="project" label="Project" onOpenUser={onOpenUser} value={entry.project_id} />
          <SafeBillingJump kind="request" label="Request" onOpenRequestDetail={onOpenRequestDetail} value={entry.request_id} />
          <SafeBillingJump kind="trace" label="Trace" onOpenTrace={onOpenTrace} value={entry.trace_id} />
          <SafeBillingJump
            kind="user"
            label="User"
            onOpenUser={onOpenUser}
            value={ledgerMetadataRefValue(entry.metadata, ["user_id", "userId", "actor_user_id"])}
          />
        </div>
      </article>

      <article className="admin-panel">
        <h2>余额窗口</h2>
        <Fields
          items={[
            ["余额前", ledgerMetadataMoney(entry.metadata, ["balance_before", "wallet_balance_before", "available_before"], entry.currency)],
            ["余额后", ledgerMetadataMoney(entry.metadata, ["balance_after", "wallet_balance_after", "available_after"], entry.currency)],
            ["费用", ledgerMetadataMoney(entry.metadata, ["cost", "final_cost", "request_cost", "fee_amount"], entry.currency)],
            ["Wallet", shortId(entry.wallet_id)],
            ["Voucher", ledgerMetadataRef(entry.metadata, ["voucher_id", "voucherId"])],
            ["Order", ledgerMetadataRef(entry.metadata, ["order_id", "orderId", "payment_order_id"])],
          ]}
        />
      </article>

      <article className="admin-panel">
        <h2>用量快照</h2>
        <JsonBlock value={sanitizeSecretJson(entry.usage_snapshot ?? null)} />
      </article>

      <article className="admin-panel">
        <h2>策略快照</h2>
        <JsonBlock value={sanitizeSecretJson(entry.policy_snapshot ?? null)} />
      </article>
    </section>
  );
}

function Fields({ items }: { items: Array<[string, unknown]> }) {
  return (
    <dl className="detail-list">
      {items.map(([label, value]) => (
        <div key={label}>
          <dt>{label}</dt>
          <dd>{safeFieldValue(value)}</dd>
        </div>
      ))}
    </dl>
  );
}

type SafeBillingJumpKind = "audit" | "project" | "request" | "trace" | "user";

function SafeBillingJump({
  kind,
  label,
  onOpenAuditLog,
  onOpenRequestDetail,
  onOpenTrace,
  onOpenUser,
  value,
}: BillingNavigationProps & {
  kind: SafeBillingJumpKind;
  label: string;
  value?: string | null;
}) {
  const target = safeNavigationId(value);

  if (!target) {
    return <span className="muted-copy">{label} config-needed</span>;
  }

  if (kind === "request") {
    return (
      <button
        className="table-action table-action--inline"
        disabled={!onOpenRequestDetail}
        onClick={() => onOpenRequestDetail?.(target)}
        type="button"
      >
        {label} {safeShortId(target)}
      </button>
    );
  }

  if (kind === "trace") {
    return (
      <button
        className="table-action table-action--inline"
        disabled={!onOpenTrace}
        onClick={() => onOpenTrace?.(target)}
        type="button"
      >
        {label} {safeShortId(target)}
      </button>
    );
  }

  if (kind === "audit") {
    return (
      <button
        className="table-action table-action--inline"
        disabled={!onOpenAuditLog}
        onClick={() => onOpenAuditLog?.({ auditLogId: target })}
        type="button"
      >
        {label} {safeShortId(target)}
      </button>
    );
  }

  const usersTarget = kind === "user" ? { userId: target } : { projectId: target };
  return (
    <button
      className="table-action table-action--inline"
      disabled={!onOpenUser}
      onClick={() => onOpenUser?.(usersTarget)}
      type="button"
    >
      {label} {safeShortId(target)}
    </button>
  );
}

function SafeBillingJumpList({
  values,
  ...props
}: BillingNavigationProps & {
  kind: SafeBillingJumpKind;
  label: string;
  values: string[];
}) {
  const targets = values.map(safeNavigationId).filter((value): value is string => Boolean(value));

  if (targets.length === 0) {
    return <span className="muted-copy">{props.label} config-needed</span>;
  }

  return (
    <>
      {targets.slice(0, 3).map((value) => (
        <SafeBillingJump key={`${props.kind}:${value}`} {...props} value={value} />
      ))}
      {targets.length > 3 ? <span className="muted-copy">+{targets.length - 3} more</span> : null}
    </>
  );
}

function safeNavigationId(value: string | null | undefined): string | undefined {
  const safe = safeFieldValue(value).trim();

  if (!safe || safe === "-" || safe.includes("[redacted]")) {
    return undefined;
  }

  return safe;
}

function JsonBlock({ value }: { value: JsonValue }) {
  return <pre className="json-block">{JSON.stringify(sanitizeDisplayJson(value), null, 2)}</pre>;
}

class PriceVersionFormError extends Error {
  constructor(
    message: string,
    readonly clearPricingRules = false,
  ) {
    super(message);
    this.name = "PriceVersionFormError";
  }
}

class LedgerAdjustmentFormError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "LedgerAdjustmentFormError";
  }
}

class VoucherIssueFormError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "VoucherIssueFormError";
  }
}

function parseUserBillingReferences(value: string): {
  currency?: string;
  projectId?: string;
  tenantId?: string;
  walletId?: string;
} {
  const text = value.trim();
  if (!text) {
    throw new VoucherIssueFormError("请先粘贴来自用户门户的计费引用。");
  }

  const references = {
    currency: referenceValue(text, "Currency"),
    projectId: referenceValue(text, "Project ID"),
    tenantId: referenceValue(text, "Tenant ID"),
    walletId: referenceValue(text, "Wallet ID"),
  };

  if (!references.tenantId || !references.walletId) {
    throw new VoucherIssueFormError("计费引用必须包含 Tenant ID 和 Wallet ID。");
  }

  return references;
}

function referenceValue(text: string, label: string): string | undefined {
  const escapedLabel = label.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = text.match(new RegExp(`^\\s*${escapedLabel}\\s*:\\s*(.+?)\\s*$`, "im"));
  const value = match?.[1]?.trim();
  if (!value || value === "not_loaded") {
    return undefined;
  }

  return value;
}

function toVoucherIssueRequest(form: VoucherIssueForm): AdminVoucherIssueRequest {
  const tenantId = form.tenantId.trim();
  const walletId = form.walletId.trim();
  const currency = form.currency.trim().toUpperCase();
  const amount = form.amount.trim();
  const rawVoucherCode = form.rawVoucherCode.trim();
  const idempotencyKey = form.idempotencyKey.trim();
  const maxRedemptionsText = form.maxRedemptions.trim();

  if (!tenantId) {
    throw new VoucherIssueFormError("Tenant ID 必填。");
  }
  if (!walletId) {
    throw new VoucherIssueFormError("Wallet ID 必填。");
  }
  if (!currency) {
    throw new VoucherIssueFormError("Currency 必填。");
  }
  if (!amount) {
    throw new VoucherIssueFormError("Amount 必填。");
  }
  if (!rawVoucherCode) {
    throw new VoucherIssueFormError("代金券码必填。");
  }
  if (!idempotencyKey) {
    throw new VoucherIssueFormError("幂等键必填。");
  }

  const maxRedemptions = maxRedemptionsText ? Number(maxRedemptionsText) : null;
  if (maxRedemptions !== null && (!Number.isInteger(maxRedemptions) || maxRedemptions < 1)) {
    throw new VoucherIssueFormError("最大兑换次数必须是正整数。");
  }

  return {
    amount,
    currency,
    expires_at: form.expiresAt.trim() || null,
    idempotency_key: idempotencyKey,
    max_redemptions: maxRedemptions,
    project_id: form.projectId.trim() || null,
    raw_voucher_code: rawVoucherCode,
    tenant_id: tenantId,
    wallet_id: walletId,
  };
}

function toVoucherIssueBatchRequest(form: VoucherIssueForm): AdminVoucherIssueBatchRequest {
  const single = toVoucherIssueRequest({
    ...form,
    idempotencyKey: form.batchIdempotencyKey.trim() || "batch-validation-placeholder",
    rawVoucherCode: "batch-validation-placeholder",
  });
  const batchIdempotencyKey = form.batchIdempotencyKey.trim();

  if (!batchIdempotencyKey) {
    throw new VoucherIssueFormError("批次幂等键必填。");
  }

  const lines = form.voucherCodesText
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);

  if (lines.length === 0) {
    throw new VoucherIssueFormError("请至少输入一个代金券码。");
  }
  if (lines.length > 100) {
    throw new VoucherIssueFormError("批量发放一次最多 100 条。");
  }

  const seenCodes = new Set<string>();
  const seenIdempotencyKeys = new Set<string>();
  const items = lines.map((line, index) => {
    const [rawCodePart, idempotencyPart] = line.split(",", 2);
    const rawVoucherCode = rawCodePart.trim();
    const idempotencyKey = (idempotencyPart?.trim() || `${batchIdempotencyKey}:${index + 1}`).trim();

    if (!rawVoucherCode) {
      throw new VoucherIssueFormError(`第 ${index + 1} 行缺少代金券码。`);
    }
    if (seenCodes.has(rawVoucherCode)) {
      throw new VoucherIssueFormError(`第 ${index + 1} 行代金券码重复。`);
    }
    if (seenIdempotencyKeys.has(idempotencyKey)) {
      throw new VoucherIssueFormError(`第 ${index + 1} 行幂等键重复。`);
    }

    seenCodes.add(rawVoucherCode);
    seenIdempotencyKeys.add(idempotencyKey);

    return {
      idempotency_key: idempotencyKey,
      raw_voucher_code: rawVoucherCode,
    };
  });

  return {
    batch_idempotency_key: batchIdempotencyKey,
    defaults: {
      amount: single.amount,
      campaign_id: single.campaign_id ?? null,
      currency: single.currency,
      expires_at: single.expires_at ?? null,
      max_redemptions: single.max_redemptions ?? null,
      project_id: single.project_id ?? null,
      tenant_id: single.tenant_id,
      wallet_id: single.wallet_id,
    },
    items,
  };
}

function toVoucherListFilters(filters: VoucherListFilterState): AdminVoucherIssuanceListFilters {
  const parsedLimit = Number(filters.limit.trim() || defaultVoucherListFilters.limit);
  return {
    batch_idempotency_key_hash: optionalString(filters.batchIdempotencyKeyHash),
    campaign_id: optionalString(filters.campaignId),
    limit: Number.isFinite(parsedLimit) && parsedLimit > 0 ? Math.floor(parsedLimit) : Number(defaultVoucherListFilters.limit),
    project_id: optionalString(filters.projectId),
    status: optionalString(filters.status),
    wallet_id: optionalString(filters.walletId),
  };
}

function exportVoucherIssuancesCsv(vouchers: AdminVoucherIssuanceSummary[]) {
  const headers = [
    "voucher_id",
    "code_redacted",
    "status",
    "effective_status",
    "amount",
    "currency",
    "wallet_id",
    "project_id",
    "campaign_id",
    "batch_idempotency_key_hash",
    "redemption_count",
    "max_redemptions",
    "expires_at",
    "audit_id",
    "revoke_audit_id",
  ];
  const rows = vouchers.map((voucher) => [
    voucher.voucher_id,
    voucher.code_redacted,
    voucher.status,
    voucher.effective_status ?? "",
    voucher.amount,
    voucher.currency,
    voucher.wallet_id ?? "",
    voucher.project_id ?? "",
    voucher.campaign_id ?? "",
    voucher.batch_idempotency_key_hash ?? "",
    voucher.redemption_count,
    voucher.max_redemptions,
    voucher.expires_at ?? "",
    voucher.audit_id ?? "",
    voucher.revoke_audit_id ?? "",
  ]);
  const csv = [headers, ...rows].map((row) => row.map(csvCell).join(",")).join("\n");
  downloadTextFile(`ai-gateway-vouchers-${dateStamp()}.csv`, `${csv}\n`, "text/csv;charset=utf-8");
}

function exportVoucherIssuancesJson(vouchers: AdminVoucherIssuanceSummary[]) {
  const payload = {
    exported_at: new Date().toISOString(),
    raw_idempotency_key_echoed: false,
    raw_voucher_code_echoed: false,
    schema: "admin_voucher_issuance_export.v1",
    secret_safe: true,
    vouchers: vouchers.map((voucher) => ({
      amount: voucher.amount,
      audit_id: voucher.audit_id ?? null,
      batch_idempotency_key_hash: voucher.batch_idempotency_key_hash ?? null,
      campaign_id: voucher.campaign_id ?? null,
      code_redacted: voucher.code_redacted,
      currency: voucher.currency,
      effective_status: voucher.effective_status ?? voucher.status,
      expires_at: voucher.expires_at ?? null,
      max_redemptions: voucher.max_redemptions,
      project_id: voucher.project_id ?? null,
      redemption_count: voucher.redemption_count,
      revoke_audit_id: voucher.revoke_audit_id ?? null,
      status: voucher.status,
      voucher_id: voucher.voucher_id,
      wallet_id: voucher.wallet_id ?? null,
    })),
  };
  downloadTextFile(
    `ai-gateway-vouchers-${dateStamp()}.json`,
    `${JSON.stringify(payload, null, 2)}\n`,
    "application/json;charset=utf-8",
  );
}

function voucherSingleSecretDownload(
  request: AdminVoucherIssueRequest,
  voucherId: string | undefined,
): VoucherSecretDownload {
  return {
    content: [
      "# AI Gateway voucher raw code export",
      "# Keep this file secure. The admin API response and voucher exports do not echo raw codes.",
      `voucher_id=${voucherId ?? ""}`,
      `code=${request.raw_voucher_code}`,
      "",
    ].join("\n"),
    filename: `ai-gateway-voucher-code-${safeFilenamePart(voucherId ?? "single")}.txt`,
    label: "单张原始券码",
  };
}

function voucherBatchSecretDownload(
  request: AdminVoucherIssueBatchRequest,
  batchIdempotencyKeyHash: string | undefined,
): VoucherSecretDownload {
  const rows = request.items.map((item, index) => `${index + 1},${csvCell(item.raw_voucher_code)},${csvCell(item.idempotency_key)}`);
  return {
    content: [
      "# AI Gateway voucher batch raw code export",
      "# Keep this file secure. The admin API response and voucher exports do not echo raw codes or raw idempotency keys.",
      `batch_idempotency_key_hash=${batchIdempotencyKeyHash ?? ""}`,
      "index,raw_voucher_code,idempotency_key",
      ...rows,
      "",
    ].join("\n"),
    filename: `ai-gateway-voucher-batch-codes-${safeFilenamePart(batchIdempotencyKeyHash ?? dateStamp())}.csv`,
    label: "批量原始券码",
  };
}

function safeFilenamePart(value: string): string {
  const normalized = value.replace(/[^a-z0-9_-]/gi, "").slice(0, 24);
  return normalized || dateStamp();
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

function csvCell(value: unknown): string {
  const text = value === null || value === undefined ? "" : String(value);
  return `"${text.replaceAll('"', '""')}"`;
}

function dateStamp(): string {
  return new Date().toISOString().slice(0, 10);
}

function toCreatePriceVersionRequest(form: PriceVersionCreateForm): CreatePriceVersionRequest {
  return {
    canonical_model_id: optionalString(form.canonicalModelId),
    effective_at: optionalString(form.effectiveAt),
    price_book_id: requiredString(form.priceBookId, "Price book ID"),
    pricing_rules: parsePricingRulesJsonObject(form.pricingRules),
    retired_at: optionalString(form.retiredAt),
    status: optionalString(form.status),
    version: requiredString(form.version, "Version"),
  };
}

function toCreateSubscriptionPlanRequest(form: SubscriptionPlanForm): CreateSubscriptionPlanRequest {
  return {
    billing_interval: requiredString(form.billingInterval, "Billing interval"),
    currency: requiredString(form.currency, "Currency").toUpperCase(),
    display_name: requiredString(form.displayName, "Display name"),
    included_credit_amount: requiredString(form.includedCreditAmount, "Included credit amount"),
    metadata: parseSubscriptionPlanJsonObject(form.metadata, "Metadata"),
    plan_code: requiredString(form.planCode, "Plan code"),
    request_summary: parseSubscriptionPlanJsonObject(form.requestSummary, "Request summary"),
    status: optionalString(form.status),
    trial_days: requiredNonNegativeInteger(form.trialDays, "Trial days"),
    unit_price: requiredString(form.unitPrice, "Unit price"),
  };
}

function toPatchSubscriptionPlanRequest(form: SubscriptionPlanForm): PatchSubscriptionPlanRequest {
  const request = toCreateSubscriptionPlanRequest(form);
  const { plan_code: _planCode, ...patch } = request;
  return patch;
}

function subscriptionPlanFormFromPlan(plan: SubscriptionPlan): SubscriptionPlanForm {
  return {
    billingInterval: plan.billing_interval,
    currency: plan.currency,
    displayName: plan.display_name,
    includedCreditAmount: plan.included_credit_amount,
    metadata: JSON.stringify(sanitizeDisplayJson(plan.metadata), null, 2),
    planCode: plan.plan_code,
    requestSummary: JSON.stringify(sanitizeDisplayJson(plan.request_summary), null, 2),
    status: plan.status,
    trialDays: String(plan.trial_days),
    unitPrice: plan.unit_price,
  };
}

function parseSubscriptionPlanJsonObject(value: string, label: string): JsonObject {
  const parsed = parseJsonObject(value.trim() || "{}", label);
  if (containsUnsafeBillingJson(parsed)) {
    throw new PriceVersionFormError(`${label} 不能包含 payload、body、auth header、secret、token、API key 或 raw key。`);
  }
  return parsed;
}

function pricingRulesJsonFromBuilder(form: PriceVersionCreateForm): string {
  const scale = Number(form.scale);

  return JSON.stringify(
    {
      cache_token_rate_per_1m: form.cacheTokenRatePer1m.trim(),
      currency: form.currency.trim().toUpperCase(),
      fixed_request_cost: form.fixedRequestCost.trim(),
      input_token_rate_per_1m: form.inputTokenRatePer1m.trim(),
      output_token_rate_per_1m: form.outputTokenRatePer1m.trim(),
      reasoning_token_rate_per_1m: form.reasoningTokenRatePer1m.trim(),
      scale: Number.isFinite(scale) ? scale : defaultPricingRules.scale,
    },
    null,
    2,
  );
}

function parsePricingRulesJsonObject(value: string): JsonObject {
  const pricingRules = parseJsonObject(value, "Pricing rules");

  if (containsUnsafeBillingJson(pricingRules)) {
    throw new PriceVersionFormError(
      "计费规则不能包含不安全字段：payload、body、auth header、secret、token、API key 或 raw key。",
      true,
    );
  }

  return pricingRules;
}

function toPriceVersionFilters(filters: PriceVersionFilterState): PriceVersionListFilters {
  return {
    canonical_model_id: optionalString(filters.canonicalModelId),
    limit: optionalPositiveInteger(filters.limit, "Limit"),
    price_book_id: optionalString(filters.priceBookId),
    status: optionalString(filters.status),
  };
}

function toSubscriptionPlanFilters(filters: SubscriptionPlanFilterState): SubscriptionPlanListFilters {
  return {
    billing_interval: optionalString(filters.billingInterval),
    limit: optionalPositiveInteger(filters.limit, "Limit"),
    status: optionalString(filters.status),
  };
}

function toWalletFilters(filters: WalletFilterState): AdminWalletListFilters {
  return {
    currency: optionalString(filters.currency)?.toUpperCase(),
    limit: optionalPositiveInteger(filters.limit, "Limit"),
    project_id: optionalString(filters.projectId),
    status: optionalString(filters.status),
  };
}

function toLedgerFilters(filters: LedgerFilterState): LedgerEntryListFilters {
  return {
    limit: optionalPositiveInteger(filters.limit, "Limit"),
    project_id: optionalString(filters.projectId),
    request_id: optionalString(filters.requestId),
    wallet_id: optionalString(filters.walletId),
  };
}

function toLedgerAdjustmentDryRunRequest(form: LedgerAdjustmentDryRunForm): LedgerAdjustmentDryRunRequest {
  const operation = form.operation === "adjust" || form.operation === "refund" ? form.operation : null;
  const reason = optionalString(form.reason);

  if (!operation) {
    throw new LedgerAdjustmentFormError("操作必须是 adjust 或 refund。");
  }

  if (!reason) {
    throw new LedgerAdjustmentFormError("手工加减额度必须填写原因。");
  }

  if (reason && (isSensitiveDisplayText(reason) || containsUnsafeReasonText(reason))) {
    throw new LedgerAdjustmentFormError(
      "原因不能包含凭证、tokens、keys、payload 或 body 文本。",
    );
  }

  if (reason && reason.length > 256) {
    throw new LedgerAdjustmentFormError("原因最多 256 个字符。");
  }

  return {
    amount: requiredAdjustmentString(form.amount, "Amount"),
    currency: requiredAdjustmentString(form.currency, "Currency").toUpperCase(),
    mode: "dry_run",
    operation,
    project_id: optionalString(form.projectId),
    reason,
    related_ledger_entry_id: optionalString(form.relatedLedgerEntryId),
    request_id: optionalString(form.requestId),
    wallet_id: optionalString(form.walletId),
  };
}

function isLedgerAdjustmentDryRunFresh(
  previousRequest: LedgerAdjustmentDryRunRequest | undefined,
  form: LedgerAdjustmentDryRunForm,
): boolean {
  if (!previousRequest) {
    return false;
  }

  try {
    return ledgerAdjustmentRequestKey(previousRequest) === ledgerAdjustmentRequestKey(toLedgerAdjustmentDryRunRequest(form));
  } catch {
    return false;
  }
}

function ledgerAdjustmentRequestKey(request: LedgerAdjustmentDryRunRequest): string {
  return JSON.stringify({
    amount: request.amount,
    currency: request.currency,
    mode: request.mode ?? null,
    operation: request.operation,
    project_id: request.project_id ?? null,
    reason: request.reason ?? null,
    related_ledger_entry_id: request.related_ledger_entry_id ?? null,
    request_id: request.request_id ?? null,
    wallet_id: request.wallet_id ?? null,
  });
}

function toReconciliationFilters(filters: ReconciliationFilterState): BillingReconciliationReportFilters {
  return {
    day: optionalIsoDay(filters.day),
    limit: optionalPositiveInteger(filters.limit, "Limit"),
    request_id: optionalUuid(filters.requestId, "Request ID"),
  };
}

function toLocalPaymentDemoCreateRequest(form: LocalPaymentDemoForm): LocalPaymentDemoCreateOrderRequest {
  const reason = requiredAdjustmentString(form.reason, "Reason");
  if (containsUnsafeReasonText(reason) || isSensitiveDisplayText(reason)) {
    throw new LedgerAdjustmentFormError("原因不能包含凭证、tokens、keys、payload 或 body 文本。");
  }

  return {
    amount: requiredAdjustmentString(form.amount, "Amount"),
    currency: requiredAdjustmentString(form.currency, "Currency").toUpperCase(),
    idempotency_key: requiredAdjustmentString(form.idempotencyKey, "Order idempotency key"),
    project_id: optionalString(form.projectId),
    reason,
    tenant_id: requiredAdjustmentString(form.tenantId, "Tenant ID"),
    wallet_id: requiredAdjustmentString(form.walletId, "Wallet ID"),
  };
}

function toLocalPaymentDemoMarkPaidRequest(form: LocalPaymentDemoForm): LocalPaymentDemoMarkPaidRequest {
  const reason = requiredAdjustmentString(form.reason, "Reason");
  if (containsUnsafeReasonText(reason) || isSensitiveDisplayText(reason)) {
    throw new LedgerAdjustmentFormError("原因不能包含凭证、tokens、keys、payload 或 body 文本。");
  }

  return {
    payment_idempotency_key: requiredAdjustmentString(form.markPaidIdempotencyKey, "Payment idempotency key"),
    reason,
    tenant_id: requiredAdjustmentString(form.tenantId, "Tenant ID"),
  };
}

function optionalString(value: string): string | undefined {
  const trimmed = value.trim();

  return trimmed ? trimmed : undefined;
}

function requiredString(value: string, label: string): string {
  const trimmed = value.trim();

  if (!trimmed) {
    throw new PriceVersionFormError(`${label} 必填。`);
  }

  return trimmed;
}

function requiredNonNegativeInteger(value: string, label: string): number {
  const trimmed = requiredString(value, label);
  const parsed = Number(trimmed);
  if (!Number.isInteger(parsed) || parsed < 0) {
    throw new PriceVersionFormError(`${label} 必须是非负整数。`);
  }
  return parsed;
}

function requiredAdjustmentString(value: string, label: string): string {
  const trimmed = value.trim();

  if (!trimmed) {
    throw new LedgerAdjustmentFormError(`${label} 必填。`);
  }

  return trimmed;
}

function containsUnsafeReasonText(value: string): boolean {
  return /\b(?:payload|body|raw[_\s-]?(?:headers|metadata|request|payload)|authorization|cookie|provider[_\s-]?key)\b/i.test(
    value,
  );
}

function optionalIsoDay(value: string): string | undefined {
  const trimmed = value.trim();

  if (!trimmed) {
    return undefined;
  }

  if (!/^\d{4}-\d{2}-\d{2}$/.test(trimmed)) {
    throw new Error("日期必须使用 YYYY-MM-DD 格式。");
  }

  return trimmed;
}

function optionalPositiveInteger(value: string, label: string): number | undefined {
  const trimmed = value.trim();

  if (!trimmed) {
    return undefined;
  }

  const parsed = Number(trimmed);

  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw new Error(`${label} 必须是正整数。`);
  }

  return parsed;
}

function optionalUuid(value: string, label: string): string | undefined {
  const trimmed = value.trim();

  if (!trimmed) {
    return undefined;
  }

  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(trimmed)) {
    throw new Error(`${label} 必须是 UUID。`);
  }

  return trimmed;
}

function countByStatus(versions: PriceVersion[], status: string): number {
  return versions.filter((version) => version.status === status).length;
}

function ledgerTotals(entries: LedgerEntry[]): string {
  const totals = new Map<string, number>();

  for (const entry of entries) {
    const amount = Number(entry.amount);

    if (Number.isFinite(amount)) {
      totals.set(entry.currency, (totals.get(entry.currency) ?? 0) + amount);
    }
  }

  if (totals.size === 0) {
    return "-";
  }

  return Array.from(totals.entries())
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([currency, amount]) => `${currency} ${formatDecimal(amount)}`)
    .join(" / ");
}

function walletCreditGrantTotal(wallets: AdminWalletCreditSurface[]): string {
  return moneyTotals(
    wallets.map((surface) => ({
      amount: surface.credit_grants.active_remaining_total,
      currency: surface.wallet.currency,
    })),
  );
}

function walletAvailableTotals(wallets: AdminWalletCreditSurface[]): string {
  return moneyTotals(
    wallets.map((surface) => ({
      amount: walletAvailableAmount(surface),
      currency: surface.wallet.currency,
    })),
  );
}

function walletAvailableMoney(surface: AdminWalletCreditSurface): string {
  return moneyValue(walletAvailableAmount(surface), surface.wallet.currency);
}

function walletAvailableAmount(surface: AdminWalletCreditSurface): string {
  const activeCredit = decimalNumber(surface.credit_grants.active_remaining_total);
  const confirmedLedger = decimalNumber(surface.ledger_balance_window.confirmed_net_amount);
  const pendingLedger = decimalNumber(surface.ledger_balance_window.pending_amount);
  const balanceFloor = decimalNumber(surface.wallet.balance_floor);

  if (activeCredit === null || confirmedLedger === null || pendingLedger === null || balanceFloor === null) {
    return "-";
  }

  return formatDecimal(activeCredit + confirmedLedger + pendingLedger - balanceFloor);
}

function moneyTotals(values: Array<{ amount: string; currency: string }>): string {
  const totals = new Map<string, number>();

  for (const value of values) {
    const amount = decimalNumber(value.amount);

    if (amount !== null) {
      totals.set(value.currency, (totals.get(value.currency) ?? 0) + amount);
    }
  }

  if (totals.size === 0) {
    return "-";
  }

  return Array.from(totals.entries())
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([currency, amount]) => moneyValue(formatDecimal(amount), currency))
    .join(" / ");
}

type PriceRuleSummary = {
  cacheTokenRatePer1m: string;
  currency: string;
  fixedRequestCost: string;
  inputTokenRatePer1m: string;
  outputTokenRatePer1m: string;
  reasoningTokenRatePer1m: string;
  scale: string;
};

function priceRuleSummary(rules: JsonValue): PriceRuleSummary {
  return {
    cacheTokenRatePer1m: priceRuleValue(rules, [
      "cache_token_rate_per_1m",
      "cache_token_rate_per_million",
      "cache_tokens_per_1m",
      "cached_token_rate_per_1m",
      "cached_token_rate_per_million",
      "cached_input_token_rate_per_1m",
      "cached_input_token_rate_per_million",
      "input_cache_token_rate_per_1m",
      "input_cache_token_rate_per_million",
    ]),
    currency: priceRuleValue(rules, ["currency"], "USD"),
    fixedRequestCost: priceRuleValue(rules, ["fixed_request_cost"]),
    inputTokenRatePer1m: priceRuleValue(rules, [
      "input_token_rate_per_1m",
      "input_token_rate_per_million",
      "input_tokens_per_1m",
    ]),
    outputTokenRatePer1m: priceRuleValue(rules, [
      "output_token_rate_per_1m",
      "output_token_rate_per_million",
      "output_tokens_per_1m",
    ]),
    reasoningTokenRatePer1m: priceRuleValue(rules, [
      "reasoning_token_rate_per_1m",
      "reasoning_token_rate_per_million",
      "reasoning_tokens_per_1m",
    ]),
    scale: priceRuleValue(rules, ["scale"], String(defaultPricingRules.scale)),
  };
}

function priceRuleValue(rules: JsonValue, keys: string[], fallback = "0"): string {
  if (!isJsonRecord(rules)) {
    return fallback;
  }

  for (const key of keys) {
    const value = rules[key];

    if (typeof value === "string" && value.trim()) {
      return safeFieldValue(value.trim());
    }

    if (typeof value === "number" && Number.isFinite(value)) {
      return safeFieldValue(value);
    }
  }

  return fallback;
}

function decimalNumber(value: string | null | undefined): number | null {
  const parsed = Number(value);

  return Number.isFinite(parsed) ? parsed : null;
}

function formatIdList(values: string[]): string {
  if (values.length === 0) {
    return "-";
  }

  return values.map(safeShortId).join(", ");
}

function moneyValue(amount: string | null | undefined, currency: string | null | undefined): string {
  return formatSafeMoney(amount, currency);
}

function legacyCurrencyAmount(amount: string | null | undefined, currency: string | null | undefined): string {
  const safeAmount = safeFieldValue(amount);
  const safeCurrency = safeFieldValue(currency);

  if (safeAmount === "-" || safeCurrency === "-") {
    return "-";
  }

  return `${safeCurrency} ${safeAmount}`;
}

function ledgerMetadataRef(metadata: JsonValue | null | undefined, keys: string[]): string {
  const value = findJsonPrimitive(metadata, keys);

  return typeof value === "string" ? safeShortId(value) : "-";
}

function ledgerMetadataRefValue(metadata: JsonValue | null | undefined, keys: string[]): string | undefined {
  const value = findJsonPrimitive(metadata, keys);

  return typeof value === "string" ? safeNavigationId(value) : undefined;
}

function ledgerMetadataMoney(metadata: JsonValue | null | undefined, keys: string[], currency: string): string {
  const value = findJsonPrimitive(metadata, keys);

  if (typeof value !== "string" && typeof value !== "number") {
    return "-";
  }

  return moneyValue(String(value), currency);
}

function findJsonPrimitive(value: JsonValue | null | undefined, keys: string[]): string | number | null {
  if (value === null || value === undefined || !isJsonRecord(value)) {
    return null;
  }

  for (const key of keys) {
    const direct = value[key];

    if (typeof direct === "string" || typeof direct === "number") {
      return direct;
    }
  }

  for (const child of Object.values(value) as Array<JsonValue | undefined>) {
    if (child !== undefined && isJsonRecord(child)) {
      const nested = findJsonPrimitive(child, keys);

      if (nested !== null) {
        return nested;
      }
    }
  }

  return null;
}

function adminWalletSecretSafe(value: JsonValue): boolean {
  return isJsonRecord(value) ? value.secret_safe === true : value === true;
}

function safeShortId(value: string | null | undefined): string {
  return formatSafeShortId(value);
}

function containsUnsafeBillingJson(value: JsonValue): boolean {
  if (Array.isArray(value)) {
    return value.some(containsUnsafeBillingJson);
  }

  if (isJsonRecord(value)) {
    return Object.entries(value).some(([key, child]) => isUnsafeJsonDisplayKey(key) || containsUnsafeBillingJson(child));
  }

  return typeof value === "string" && isSensitiveDisplayText(value);
}

function sanitizeDisplayJson(value: JsonValue): JsonValue {
  return omitUnsafeJsonFields(sanitizeSecretJson(value));
}

function omitUnsafeJsonFields(value: JsonValue): JsonValue {
  if (Array.isArray(value)) {
    return value.map(omitUnsafeJsonFields);
  }

  if (isJsonRecord(value)) {
    return Object.fromEntries(
      Object.entries(value)
        .filter(([key]) => !isUnsafeJsonDisplayKey(key))
        .map(([key, child]) => [key, omitUnsafeJsonFields(child)]),
    );
  }

  if (typeof value === "string") {
    return safeFieldValue(value);
  }

  return value;
}

function isUnsafeJsonDisplayKey(key: string): boolean {
  const normalized = key.toLowerCase().replace(/[^a-z0-9]/g, "");

  return (
    normalized.includes("accesstoken") ||
    normalized.includes("authorization") ||
    normalized.includes("apikey") ||
    normalized.includes("bearertoken") ||
    normalized.includes("cookie") ||
    normalized.includes("credential") ||
    normalized.includes("encryptedsecret") ||
    normalized.includes("fingerprint") ||
    normalized.includes("payload") ||
    normalized.includes("password") ||
    normalized.includes("privatekey") ||
    normalized.includes("rawkey") ||
    normalized.includes("refreshtoken") ||
    normalized.includes("secret") ||
    normalized.includes("secrethash") ||
    normalized.includes("sessiontoken") ||
    normalized === "token" ||
    normalized === "body" ||
    normalized === "apikey" ||
    normalized.endsWith("body") ||
    normalized.endsWith("token") ||
    normalized.startsWith("raw") ||
    normalized.includes("rawpolicysnapshot")
  );
}

function issueTone(issue: string): "danger" | "neutral" | "warn" {
  if (issue === "missing_ledger" || issue === "unexpected_ledger") {
    return "danger";
  }

  if (issue === "amount_mismatch" || issue === "currency_mismatch") {
    return "warn";
  }

  return "neutral";
}

function formatDecimal(value: number): string {
  return value.toFixed(8).replace(/\.?0+$/, "");
}

function formatDate(value: string | null | undefined): string {
  return formatDateTime(value);
}
