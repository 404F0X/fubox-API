import { FormEvent, useEffect, useState } from "react";
import {
  type BillingReconciliationCurrencyTotal,
  type BillingReconciliationDiscrepancy,
  type BillingReconciliationReport,
  type BillingReconciliationReportFilters,
  type CreatePriceVersionRequest,
  type JsonObject,
  type LedgerEntry,
  type LedgerAdjustmentDryRunRequest,
  type LedgerAdjustmentDryRunResponse,
  type LedgerAdjustmentExecuteResult,
  type LedgerAdjustmentFutureExecuteResponse,
  type LedgerExecutorRefusalSummaryContract,
  type LedgerExecutorRollbackSummaryContract,
  type LedgerExecutorSummary,
  type LedgerExecutorSummaryContract,
  type LedgerEntryListFilters,
  type PriceVersion,
  type PriceVersionListFilters,
  type PriceVersionStatus,
  createPriceVersion,
  dryRunLedgerAdjustment,
  executeLedgerAdjustment,
  getBillingReconciliationReport,
  listLedgerEntries,
  listPriceVersions,
  requestLedgerAdjustmentExecuteContract,
  type JsonValue,
} from "../api/client";
import { ledgerAdjustmentExecuteLiveSmokeContract } from "../billingExecuteSmokeContract";
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
} from "./adminUtils";
import { Eye, Plus, RefreshCw, Search } from "./icons";

const executeSmokeSelectors = ledgerAdjustmentExecuteLiveSmokeContract.selectors;

type BillingTab = "priceVersions" | "ledger" | "reconciliation";

type PriceVersionFilterState = {
  canonicalModelId: string;
  limit: string;
  priceBookId: string;
  status: string;
};

type PriceVersionCreateForm = {
  canonicalModelId: string;
  effectiveAt: string;
  priceBookId: string;
  pricingRules: string;
  retiredAt: string;
  status: PriceVersionStatus;
  version: string;
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

type LedgerEntriesLoadResult = {
  message?: string;
  ok: boolean;
};

type ReconciliationFilterState = {
  day: string;
  limit: string;
};

const defaultPriceVersionFilters: PriceVersionFilterState = {
  canonicalModelId: "",
  limit: "25",
  priceBookId: "",
  status: "",
};

const defaultPricingRules = {
  currency: "USD",
  fixed_request_cost: "0.00000000",
  input_token_rate_per_1m: "0.15000000",
  output_token_rate_per_1m: "0.60000000",
  scale: 8,
} satisfies JsonObject;

const defaultPricingRulesJson = JSON.stringify(defaultPricingRules, null, 2);

const defaultPriceVersionCreateForm: PriceVersionCreateForm = {
  canonicalModelId: "",
  effectiveAt: "",
  priceBookId: "",
  pricingRules: defaultPricingRulesJson,
  retiredAt: "",
  status: "draft",
  version: "",
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

const defaultReconciliationFilters: ReconciliationFilterState = {
  day: "",
  limit: "50",
};

const priceVersionStatuses = ["", "draft", "active", "retired"];
const priceVersionCreateStatuses: PriceVersionStatus[] = ["draft", "active", "retired"];

export function BillingPage() {
  const [activeTab, setActiveTab] = useState<BillingTab>("priceVersions");

  return (
    <div className="admin-page" aria-label="Billing and prices">
      <div className="tab-list" role="tablist" aria-label="Billing sections">
        <button
          aria-selected={activeTab === "priceVersions"}
          className={`tab-button${activeTab === "priceVersions" ? " tab-button--active" : ""}`}
          onClick={() => setActiveTab("priceVersions")}
          role="tab"
          type="button"
        >
          Price Versions
        </button>
        <button
          aria-selected={activeTab === "ledger"}
          className={`tab-button${activeTab === "ledger" ? " tab-button--active" : ""}`}
          onClick={() => setActiveTab("ledger")}
          role="tab"
          type="button"
        >
          Ledger Overview
        </button>
        <button
          aria-selected={activeTab === "reconciliation"}
          className={`tab-button${activeTab === "reconciliation" ? " tab-button--active" : ""}`}
          onClick={() => setActiveTab("reconciliation")}
          role="tab"
          type="button"
        >
          Reconciliation
        </button>
      </div>

      {activeTab === "priceVersions" ? (
        <PriceVersionsSection />
      ) : activeTab === "ledger" ? (
        <LedgerOverviewSection />
      ) : (
        <ReconciliationSection />
      )}
    </div>
  );
}

export default BillingPage;

function PriceVersionsSection() {
  const [createError, setCreateError] = useState<string | null>(null);
  const [createForm, setCreateForm] = useState<PriceVersionCreateForm>(defaultPriceVersionCreateForm);
  const [creating, setCreating] = useState(false);
  const [filters, setFilters] = useState<PriceVersionFilterState>(defaultPriceVersionFilters);
  const [listError, setListError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
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
      setSuccess(`Price version ${safeFieldValue(created.version)} created.`);
      await loadVersions(filters);
      setSelectedVersion(created);
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
      <section className="admin-panel" aria-label="Create price version">
        <div className="section-heading">
          <div>
            <h2>Create Price Version</h2>
            <p>Write a new immutable price version and refresh the active list.</p>
          </div>
        </div>

        <form className="price-version-form" onSubmit={handleCreate}>
          <div className="form-grid price-version-form-grid">
            <label className="field">
              Price book ID
              <input
                value={createForm.priceBookId}
                onChange={(event) => updateCreateForm("priceBookId", event.currentTarget.value)}
                placeholder="price book uuid"
                required
              />
            </label>
            <label className="field">
              Model ID
              <input
                value={createForm.canonicalModelId}
                onChange={(event) => updateCreateForm("canonicalModelId", event.currentTarget.value)}
                placeholder="canonical model uuid"
              />
            </label>
            <label className="field">
              Version
              <input
                value={createForm.version}
                onChange={(event) => updateCreateForm("version", event.currentTarget.value)}
                placeholder="2026-06-03"
                required
              />
            </label>
            <label className="field">
              Status
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
              Effective at
              <input
                value={createForm.effectiveAt}
                onChange={(event) => updateCreateForm("effectiveAt", event.currentTarget.value)}
                placeholder="2026-06-03T00:00:00Z"
              />
            </label>
            <label className="field">
              Retired at
              <input
                value={createForm.retiredAt}
                onChange={(event) => updateCreateForm("retiredAt", event.currentTarget.value)}
                placeholder="2026-12-31T00:00:00Z"
              />
            </label>
          </div>

          <label className="field">
            Pricing rules JSON
            <textarea
              value={createForm.pricingRules}
              onChange={(event) => updateCreateForm("pricingRules", event.currentTarget.value)}
              required
              spellCheck={false}
            />
          </label>

          <button className="primary-button primary-button--inline" type="submit" disabled={creating}>
            <Plus aria-hidden="true" size={17} />
            {creating ? "Creating" : "Create"}
          </button>
        </form>

        {createError ? <p className="form-status form-status--error">{createError}</p> : null}
        {success ? <p className="form-status form-status--success">{success}</p> : null}
      </section>

      <section className="admin-panel" aria-label="Price version filters">
        <div className="section-heading">
          <div>
            <h2>Price Versions</h2>
            <p>Read price version status, scope, effective window, and pricing rule shape.</p>
          </div>
          <button className="secondary-button" type="button" onClick={() => void loadVersions()} disabled={loading}>
            <RefreshCw aria-hidden="true" size={18} className={loading ? "spin" : undefined} />
            Refresh
          </button>
        </div>

        <form className="filter-bar" onSubmit={handleSubmit}>
          <label className="field">
            Status
            <select
              value={filters.status}
              onChange={(event) => setFilters((current) => ({ ...current, status: event.currentTarget.value }))}
            >
              {priceVersionStatuses.map((status) => (
                <option key={status || "all"} value={status}>
                  {status ? formatStatus(status) : "All"}
                </option>
              ))}
            </select>
          </label>
          <label className="field">
            Price book ID
            <input
              value={filters.priceBookId}
              onChange={(event) => setFilters((current) => ({ ...current, priceBookId: event.currentTarget.value }))}
              placeholder="price book uuid"
            />
          </label>
          <label className="field">
            Model ID
            <input
              value={filters.canonicalModelId}
              onChange={(event) => setFilters((current) => ({ ...current, canonicalModelId: event.currentTarget.value }))}
              placeholder="canonical model uuid"
            />
          </label>
          <label className="field field--compact">
            Limit
            <input
              min="1"
              type="number"
              value={filters.limit}
              onChange={(event) => setFilters((current) => ({ ...current, limit: event.currentTarget.value }))}
            />
          </label>
          <button className="primary-button primary-button--inline" type="submit">
            <Search aria-hidden="true" size={17} />
            Search
          </button>
        </form>

        {listError ? <p className="form-status form-status--error">{listError}</p> : null}
      </section>

      <PriceVersionStats versions={versions} />

      <section aria-label="Price version list">
        <div className="health-table-wrap">
          <table className="health-table admin-table admin-table--price-versions">
            <thead>
              <tr>
                <th>Version</th>
                <th>Status</th>
                <th>Scope</th>
                <th>Effective</th>
                <th>Retired</th>
                <th>Rules</th>
                <th>Detail</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr>
                  <td colSpan={7}>Loading price versions.</td>
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
                      <span>{version.canonical_model_id ? `Model ${shortId(version.canonical_model_id)}` : "Default model scope"}</span>
                    </td>
                    <td>{formatDate(version.effective_at)}</td>
                    <td>{version.retired_at ? formatDate(version.retired_at) : "-"}</td>
                    <td>{jsonSize(sanitizeDisplayJson(version.pricing_rules))} rule fields</td>
                    <td>
                      <button
                        aria-label={`View price version ${version.version}`}
                        className="table-action"
                        onClick={() => setSelectedVersion(version)}
                        type="button"
                      >
                        <Eye aria-hidden="true" size={15} />
                        View
                      </button>
                    </td>
                  </tr>
                ))
              ) : (
                <tr>
                  <td colSpan={7}>No price versions returned.</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </section>

      {selectedVersion ? <PriceVersionDetail version={selectedVersion} /> : null}
    </>
  );
}

function LedgerOverviewSection() {
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
      setExecuteCheckError("Run a fresh dry-run before checking execute contract.");
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
        message: "Run a fresh dry-run before executing ledger adjustment.",
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
            : { message: refreshResult.message ?? "Ledger entries refresh failed.", status: "error" },
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
      <section className="admin-panel" aria-label="Ledger adjustment dry-run">
        <div className="section-heading">
          <div>
            <h2>Adjustment / Refund Dry-Run</h2>
            <p>Plan an adjustment or refund entry without executing ledger, request log, audit, or upstream writes.</p>
          </div>
        </div>

        <form className="price-version-form" onSubmit={handleDryRun}>
          <div className="form-grid">
            <label className="field">
              Operation
              <select
                value={dryRunForm.operation}
                onChange={(event) => updateDryRunForm("operation", event.currentTarget.value)}
              >
                <option value="refund">Refund</option>
                <option value="adjust">Adjust</option>
              </select>
            </label>
            <label className="field">
              Amount
              <input
                value={dryRunForm.amount}
                onChange={(event) => updateDryRunForm("amount", event.currentTarget.value)}
                placeholder="0.25000000"
                required
              />
            </label>
            <label className="field">
              Currency
              <input
                value={dryRunForm.currency}
                onChange={(event) => updateDryRunForm("currency", event.currentTarget.value)}
                placeholder="USD"
                required
              />
            </label>
            <label className="field">
              Related ledger entry
              <input
                value={dryRunForm.relatedLedgerEntryId}
                onChange={(event) => updateDryRunForm("relatedLedgerEntryId", event.currentTarget.value)}
                placeholder="ledger entry uuid"
              />
            </label>
            <label className="field">
              Project ID
              <input
                value={dryRunForm.projectId}
                onChange={(event) => updateDryRunForm("projectId", event.currentTarget.value)}
                placeholder="project uuid"
              />
            </label>
            <label className="field">
              Wallet ID
              <input
                value={dryRunForm.walletId}
                onChange={(event) => updateDryRunForm("walletId", event.currentTarget.value)}
                placeholder="wallet uuid"
              />
            </label>
            <label className="field">
              Request ID
              <input
                value={dryRunForm.requestId}
                onChange={(event) => updateDryRunForm("requestId", event.currentTarget.value)}
                placeholder="request uuid"
              />
            </label>
            <label className="field field--wide">
              Reason
              <input
                value={dryRunForm.reason}
                onChange={(event) => updateDryRunForm("reason", event.currentTarget.value)}
                placeholder="customer credit"
              />
            </label>
          </div>

          <button className="primary-button primary-button--inline" type="submit" disabled={dryRunLoading}>
            <Search aria-hidden="true" size={17} />
            {dryRunLoading ? "Planning" : "Plan dry-run"}
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

      <section className="admin-panel" aria-label="Ledger filters">
        <div className="section-heading">
          <div>
            <h2>Ledger Overview</h2>
            <p>Inspect append-only ledger entries by project, wallet, or request.</p>
          </div>
          <button className="secondary-button" type="button" onClick={() => void loadEntries()} disabled={loading}>
            <RefreshCw aria-hidden="true" size={18} className={loading ? "spin" : undefined} />
            Refresh
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
            Limit
            <input
              min="1"
              type="number"
              value={filters.limit}
              onChange={(event) => setFilters((current) => ({ ...current, limit: event.currentTarget.value }))}
            />
          </label>
          <button className="primary-button primary-button--inline" type="submit">
            <Search aria-hidden="true" size={17} />
            Search
          </button>
        </form>

        {error ? <p className="form-status form-status--error">{error}</p> : null}
      </section>

      <LedgerStats entries={entries} />

      <section aria-label="Ledger entry list">
        <div className="health-table-wrap">
          <table className="health-table admin-table admin-table--ledger">
            <thead>
              <tr>
                <th>Entry</th>
                <th>Status</th>
                <th>Amount</th>
                <th>Scope</th>
                <th>Links</th>
                <th>Occurred</th>
                <th>Detail</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr>
                  <td colSpan={7}>Loading ledger entries.</td>
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
                      <strong>{entry.amount}</strong>
                      <span>{entry.currency}</span>
                    </td>
                    <td>
                      <strong>Project {shortId(entry.project_id)}</strong>
                      <span>Wallet {shortId(entry.wallet_id)}</span>
                    </td>
                    <td>
                      <span>Request {shortId(entry.request_id)}</span>
                      <span>Price {shortId(entry.price_version_id)}</span>
                      <span>Trace {shortId(entry.trace_id)}</span>
                    </td>
                    <td>{formatDate(entry.occurred_at)}</td>
                    <td>
                      <button
                        aria-label={`View ledger entry ${entry.id}`}
                        className="table-action"
                        onClick={() => setSelectedEntry(entry)}
                        type="button"
                      >
                        <Eye aria-hidden="true" size={15} />
                        View
                      </button>
                    </td>
                  </tr>
                ))
              ) : (
                <tr>
                  <td colSpan={7}>No ledger entries returned.</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </section>

      {selectedEntry ? <LedgerEntryDetail entry={selectedEntry} /> : null}
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
    ? "Run a dry-run before execute can be considered."
    : dryRunFresh
      ? "Fresh dry-run result is available; execute contract preflight and ledger execute are both explicit actions."
      : "Form changed after dry-run. Run dry-run again before execute can be considered.";
  const flags = executeResult ? executeFlags(executeResult) : contractResult ? executeFlags(contractResult) : null;
  const activeResult = executeResult ?? contractResult;
  const activeFresh = executeResult ? executeFresh : contractFresh;
  const refreshText = executeResult && executeFresh ? executeRefreshStatusText(executeRefreshState) : null;

  return (
    <section
      className="admin-panel"
      aria-label="Ledger adjustment execute readiness"
      data-testid={executeSmokeSelectors.readiness}
    >
      <div className="section-heading">
        <div>
          <h2>Execute Readiness</h2>
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
      <div className="manual-test-flags" aria-label="Execute contract flags" data-testid={executeSmokeSelectors.executeFlags}>
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
          {checking ? "Checking execute contract" : "Check execute contract"}
        </button>
        <button
          className="primary-button primary-button--inline"
          data-testid={executeSmokeSelectors.executeButton}
          type="button"
          disabled={!dryRunFresh || executing}
          onClick={onExecute}
        >
          {executing ? "Executing" : "Execute ledger adjustment"}
        </button>
        <p className="muted-copy">Execution uses the fresh dry-run payload and returns only safe ledger/audit summaries.</p>
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
    <section aria-label={isExecuteResult ? "Ledger adjustment execute result" : "Ledger adjustment execute contract result"}>
      {reasons.length > 0 ? (
        <div className="issue-list" aria-label="Execute blocked reasons">
          {reasons.map((reason) => (
            <span className="issue-pill issue-pill--warn" key={reason}>
              {formatStatus(reason)}
            </span>
          ))}
        </div>
      ) : null}
      <Fields
        items={[
          ["Result", executeResultLabel(result)],
          ["Contract fresh", String(fresh)],
          ["Contract version", contract?.contract_version ?? "-"],
          ["Writer required", String(flags.futureWriterRequired)],
          ["Ledger write", String(flags.ledgerWrite)],
          ["Audit write", String(flags.auditLogWrite)],
          ["Request log write", String(flags.requestLogWrite)],
          ["Upstream call", String(flags.upstreamCall)],
          ["Server generated write marker", String(flags.serverGeneratedWriteMarker)],
          ["Write marker echoed", String(flags.writeMarkerEchoed)],
          ["Audit snapshot", snapshotPolicy],
        ]}
      />
      <LedgerExecutorSummaryPanel heading="Refusal Executor Summary" summary={refusalSummary} />
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
    <div className="detail-grid detail-grid--compact" aria-label="Ledger adjustment executed summary">
      <article>
        <h3>Execute Summary</h3>
        <Fields
          items={[
            ["Outcome", executeOutcome(response)],
            ["Mode", response.mode],
            ["Ledger write", String(response.ledger_write)],
            ["Audit write", String(response.audit_log_write)],
            ["Request log write", String(response.request_log_write)],
            ["Upstream call", String(response.upstream_call)],
            ["Audit log", shortId(response.audit_log_id)],
            ["Shared transaction", String(response.business_and_success_audit_share_transaction ?? "-")],
            ["Success audit after ledger", String(response.success_audit_only_after_ledger_write ?? "-")],
            ["Audit rollback", String(response.audit_insert_failure_rolls_back_ledger_write ?? "-")],
            ["Refusal audit", String(response.refusal_does_not_build_success_audit ?? "-")],
            ["Material echoed", String(response.dedupe_material_echoed ?? false)],
            ["Public output", safeFieldValue(response.dedupe_public_output)],
          ]}
        />
      </article>

      <article>
        <h3>Executed Ledger Entry</h3>
        {entry ? (
          <Fields
            items={[
              ["Entry", shortId(entry.id)],
              ["Tenant", shortId(entry.tenant_id)],
              ["Project", shortId(entry.project_id)],
              ["Wallet", shortId(entry.wallet_id)],
              ["Request", shortId(entry.request_id)],
              ["Related entry", shortId(entry.related_ledger_entry_id)],
              ["Type", formatStatus(entry.entry_type)],
              ["Amount", `${safeFieldValue(entry.amount)} ${safeFieldValue(entry.currency)}`],
              ["Status", safeFieldValue(entry.status)],
              ["Omitted material", entry.omitted_material ? `${entry.omitted_material.length} categories` : "-"],
            ]}
          />
        ) : (
          <p className="muted-copy">No safe ledger entry summary returned.</p>
        )}
      </article>

      <LedgerExecutorSummaryPanel summary={executorSummary} />
      <LedgerExecutorSummaryContractPanel contract={executorContract} />
      <LedgerExecutorRollbackContractPanel contract={rollbackExecutorContract} />

      <article>
        <h3>Transaction Summary</h3>
        <Fields
          items={[
            ["Writer", safeFieldValue(transaction?.writer)],
            ["Write performed", String(transaction?.write_performed ?? response.ledger_write)],
            ["Isolation", safeFieldValue(transaction?.isolation)],
            ["Begin before locks", String(transaction?.begin_before_locking ?? "-")],
            ["Commit after ledger/audit", String(transaction?.commit_only_after_ledger_and_success_audit ?? "-")],
            ["Rollback on ledger failure", String(transaction?.rollback_on_ledger_write_failure ?? "-")],
            ["Rollback on audit failure", String(transaction?.rollback_on_audit_insert_failure ?? "-")],
            ["Refund recompute rollback", String(transaction?.rollback_on_refund_remaining_change ?? "-")],
            ["Lock steps", String(transaction?.bounded_lock_order?.length ?? 0)],
            ["Bounds", String(transaction?.bounded_by?.length ?? 0)],
            ["Material echoed", String(transaction?.dedupe_material_echoed ?? response.dedupe_material_echoed ?? false)],
            ["Unbounded scan", String(transaction?.unbounded_scan_allowed ?? "-")],
          ]}
        />
      </article>

      {refund ? (
        <article>
          <h3>Refund Remaining</h3>
          <Fields
            items={[
              ["Remaining", `${refund.remaining_refundable_amount} ${refund.currency}`],
              ["Requested", `${refund.requested_refund_amount} ${refund.currency}`],
              ["Source debit", `${refund.source_debit_amount} ${refund.currency}`],
              ["Confirmed credits", `${refund.confirmed_credit_amount} ${refund.currency}`],
              ["Confirmed credit count", String(refund.confirmed_credit_count)],
              ["Tenant bounded", String(refund.tenant_bounded)],
              ["Source bounded", String(refund.source_entry_bounded)],
              ["Currency bounded", String(refund.currency_bounded)],
              ["Confirmed only", String(refund.confirmed_only)],
              ["Credit entry types", refund.credit_entry_types.join(", ")],
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
    <div className="detail-grid detail-grid--compact" aria-label="Execute contract v2 summary">
      <article>
        <h3>Dedupe Summary</h3>
        <Fields
          items={[
            ["Server generated", String(dedupe?.server_generated_dedupe_material ?? contract.server_generated_dedupe_material)],
            ["Client material rejected", String(dedupe?.client_supplied_dedupe_material_rejected ?? "-")],
            ["Material echoed", String(dedupe?.dedupe_material_echoed ?? contract.dedupe_material_echoed ?? false)],
            ["Public output", safeFieldValue(dedupe?.public_output)],
            ["Replay behavior", String(dedupe?.replay_same_digest_returns_prior_result_after_writer_exists ?? "-")],
            ["Duplicate conflict refused", String(dedupe?.conflicting_duplicate_refused_before_ledger_insert ?? "-")],
          ]}
        />
      </article>

      <article>
        <h3>Transaction Summary</h3>
        <Fields
          items={[
            ["Isolation", safeFieldValue(transaction?.future_isolation)],
            ["Begin before locks", String(transaction?.begin_before_locking ?? "-")],
            ["Commit after ledger/audit", String(transaction?.commit_only_after_ledger_and_success_audit ?? "-")],
            ["Rollback on ledger failure", String(transaction?.rollback_on_ledger_write_failure ?? "-")],
            ["Rollback on audit failure", String(transaction?.rollback_on_audit_insert_failure ?? "-")],
            ["Refund recompute rollback", String(transaction?.rollback_on_refund_remaining_change ?? "-")],
            ["Lock steps", String(transaction?.bounded_lock_order?.length ?? 0)],
            ["Bounds", String(transaction?.bounded_by?.length ?? 0)],
            ["Recompute checks", String(transaction?.recompute_after_locks?.length ?? 0)],
            ["Unbounded scan", String(transaction?.unbounded_scan_allowed ?? "-")],
          ]}
        />
      </article>

      <article>
        <h3>Writer / Audit Summary</h3>
        <Fields
          items={[
            ["Writer available", String(!(contract.future_writer_required ?? false))],
            ["Writer name", safeFieldValue(writer?.future_writer)],
            ["Write performed", String(writer?.write_performed ?? false)],
            ["Success status", safeFieldValue(writer?.insert_status_on_success)],
            ["Metadata policy", safeFieldValue(writer?.metadata_policy)],
            ["Audit write performed", String(audit?.write_performed ?? contract.audit_log_write)],
            ["Shared transaction", String(audit?.business_and_success_audit_share_transaction ?? contract.business_and_success_audit_share_transaction)],
            ["Audit rollback", String(audit?.audit_insert_failure_rolls_back_ledger_write ?? contract.audit_insert_failure_rolls_back_ledger_write)],
            ["Refusal audit", String(audit?.refusal_does_not_build_success_audit ?? contract.refusal_does_not_build_success_audit)],
            ["Snapshot policy", safeFieldValue(audit?.snapshot_policy ?? contract.audit_snapshot_policy)],
          ]}
        />
      </article>

      <article>
        <h3>Safe Output Summary</h3>
        <Fields
          items={[
            ["Request log write", String(requestLog?.write_performed ?? contract.request_log_write)],
            ["Request log mutation", String(requestLog?.request_log_mutation_allowed ?? "-")],
            ["Request material echoed", String(requestLog?.request_material_echoed ?? safeOutput?.request_material_echoed ?? false)],
            ["Sensitive material echoed", String(safeOutput?.credential_material_echoed ?? false)],
            ["Output marker echoed", String(safeOutput?.dedupe_material_echoed ?? contract.dedupe_material_echoed ?? false)],
            ["Constraints checked", String(contract.dry_run_constraints_enforced_before_refusal?.length ?? 0)],
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
    <article>
      <h3>Executor Summary Contract</h3>
      <Fields
        items={[
          ["Schema", safeExecutorField(contract.schema_version)],
          ["Response field", safeExecutorField(contract.response_field)],
          ["Private operation output", safeExecutorField(contract.operation_key_output)],
          ["Failure output", safeExecutorField(contract.error_detail_output)],
          ["Replay marker echoed", String(contract.dedupe_material_echoed ?? false)],
          ["Unsafe metadata echoed", String(contract.raw_metadata_echoed ?? false)],
          ["Sensitive material echoed", String(contract.credential_material_echoed ?? false)],
          ["Compatible fields", String(contract.compatible_fields?.length ?? 0)],
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
      <h3>Refusal Summary Contract</h3>
      <Fields
        items={[
          ["Schema", safeExecutorField(contract.schema_version)],
          ["Response field", safeExecutorField(contract.response_field)],
          ["Supported outcomes", safeExecutorList(contract.supported_outcomes)],
          ["Private operation output", safeExecutorField(contract.operation_key_output)],
          ["Failure output", safeExecutorField(contract.error_detail_output)],
          ["Executor failure echoed", String(contract.raw_executor_error_detail_echoed ?? false)],
          ["Replay marker echoed", String(contract.dedupe_material_echoed ?? false)],
          ["Unsafe metadata echoed", String(contract.raw_metadata_echoed ?? false)],
          ["Sensitive material echoed", String(contract.credential_material_echoed ?? false)],
          ["Preflight committed", String(preflight?.committed ?? "-")],
          ["Preflight rolled back", String(preflight?.rolled_back ?? "-")],
          ["Preflight refused statements", safeExecutorSummaryValue(preflight?.refused_statement_count)],
          ["Preflight row count mismatch", safeExecutorSummaryValue(preflight?.row_count_mismatch)],
          ["Rollback committed", String(rollback?.committed ?? "-")],
          ["Rollback rolled back", String(rollback?.rolled_back ?? "-")],
          ["Rollback refused statements", safeExecutorSummaryValue(rollback?.refused_statement_count)],
          ["Rollback row count mismatch", safeExecutorSummaryValue(rollback?.row_count_mismatch)],
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
      <h3>Rollback Executor Summary Contract</h3>
      <Fields
        items={[
          ["Schema", safeExecutorField(contract.schema_version)],
          ["Response field", safeExecutorField(contract.response_field)],
          ["Outcome", safeExecutorField(contract.outcome)],
          ["Committed", String(contract.committed ?? "-")],
          ["Rolled back", String(contract.rolled_back ?? "-")],
          ["Refused statements", safeExecutorSummaryValue(contract.refused_statement_count)],
          ["Row count mismatch", safeExecutorSummaryValue(contract.row_count_mismatch)],
          ["Private operation output", safeExecutorField(contract.operation_key_output)],
          ["Failure output", safeExecutorField(contract.error_detail_output)],
          ["Executor failure echoed", String(contract.raw_executor_error_detail_echoed ?? false)],
          ["Replay marker echoed", String(contract.dedupe_material_echoed ?? false)],
          ["Unsafe metadata echoed", String(contract.raw_metadata_echoed ?? false)],
          ["Sensitive material echoed", String(contract.credential_material_echoed ?? false)],
        ]}
      />
    </article>
  );
}

function LedgerExecutorSummaryPanel({
  heading = "Ledger Executor Summary",
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
          ["Schema", safeExecutorField(summary.schema_version)],
          ["Executor", safeExecutorField(summary.executor)],
          ["Operation", safeExecutorField(summary.operation)],
          ["Outcome", safeExecutorField(summary.outcome)],
          ["Private operation output", safeExecutorField(summary.operation_key_output)],
          ["Committed", String(summary.committed ?? "-")],
          ["Rolled back", String(summary.rolled_back ?? "-")],
          ["Statements", safeExecutorNumber(summary.statement_count)],
          ["Executed statements", safeExecutorNumber(summary.executed_statement_count)],
          ["Refused statements", safeExecutorNumber(summary.refused_statement_count)],
          ["Rows affected", safeExecutorNumber(summary.total_rows_affected)],
          ["Final statement order", safeExecutorNumber(summary.final_statement_order)],
          ["Final statement kind", safeExecutorField(summary.final_statement_kind)],
          ["Failure output", safeExecutorField(summary.error_detail_output)],
          ["Row count mismatch", String(summary.row_count_mismatch ?? "-")],
          ["Executor failure echoed", String(summary.raw_executor_error_detail_echoed ?? false)],
          ["Replay marker echoed", String(summary.dedupe_material_echoed ?? false)],
          ["Omitted categories", String(summary.omitted_material?.length ?? 0)],
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
    return "Execute contract check is stale. Run dry-run and contract check again before any execute step.";
  }

  if (result.kind === "writer_required") {
    return "future_writer_required: backend validated the plan but refused execution until the writer is available.";
  }

  if (result.kind === "future_execute") {
    const outcome = executeOutcome(result.response);

    if (outcome === "applied") {
      return "Ledger adjustment applied: ledger and audit writes were confirmed.";
    }

    if (outcome === "idempotent") {
      return "Idempotent replay: existing ledger entry returned without new ledger or audit writes.";
    }

    if (outcome === "blocked") {
      return "Ledger adjustment execute was blocked before applying writes.";
    }

    return "Ledger adjustment execute failed or returned an unrecognized outcome.";
  }

  return "Execute contract validated without ledger, request log, audit, or upstream writes.";
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
    return "Refreshing ledger entries after execute.";
  }

  if (state.status === "success") {
    return "Ledger entries refreshed after execute; this execute result matches the current dry-run payload.";
  }

  if (state.status === "error") {
    return `Execute result matches the current dry-run payload, but ledger entries refresh failed. ${safeFieldValue(
      state.message ?? "Request failed.",
    )}`;
  }

  return "Execute result matches the current dry-run payload.";
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
  const fallback = kind === "blocked" ? "Ledger adjustment execute was blocked." : "Ledger adjustment execute failed.";

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
    <section className="detail-grid" aria-label="Ledger adjustment dry-run result">
      <article className="admin-panel">
        <div className="section-heading">
          <div>
            <h2>Plan Flags</h2>
            <p>{formatStatus(result.operation)} dry-run returned a plan-only response.</p>
          </div>
          <StateChip status={plannedEntry.status} />
        </div>
        <div className="manual-test-flags" aria-label="Plan-only flags">
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
            ["Wallet", shortId(result.wallet_id)],
            ["Request", shortId(result.request_id)],
            ["Amount checked", String(result.validation.amount_checked)],
            ["Currency checked", String(result.validation.currency_checked)],
            ["Related checked", String(result.validation.related_ledger_entry_checked)],
            ["Refund remaining checked", String(result.validation.refund_remaining_checked)],
            ["Reason provided", String(result.validation.reason_provided)],
            ["Sensitive material", result.validation.sensitive_material_policy],
          ]}
        />
      </article>

      <article className="admin-panel">
        <div className="section-heading">
          <div>
            <h2>Planned Ledger Entry</h2>
            <p>No ledger entry is written from this screen.</p>
          </div>
          <StateChip status={plannedEntry.entry_type} />
        </div>
        <Fields
          items={[
            ["Type", formatStatus(plannedEntry.entry_type)],
            ["Amount", `${plannedEntry.amount} ${plannedEntry.currency}`],
            ["Status", plannedEntry.status],
            ["Project", shortId(plannedEntry.project_id)],
            ["Wallet", shortId(plannedEntry.wallet_id)],
            ["Request", shortId(plannedEntry.request_id)],
            ["Related entry", shortId(plannedEntry.related_ledger_entry_id)],
            ["Write marker policy", writeMarkerPolicy(plannedEntry.dedupe_policy)],
            ["Metadata policy", plannedEntry.metadata_policy],
          ]}
        />
      </article>

      <article className="admin-panel">
        <h2>Related Entry Summary</h2>
        {relatedEntry ? (
          <Fields
            items={[
              ["Entry", shortId(relatedEntry.id)],
              ["Type", formatStatus(relatedEntry.entry_type)],
              ["Amount", `${relatedEntry.amount} ${relatedEntry.currency}`],
              ["Status", relatedEntry.status],
              ["Project", shortId(relatedEntry.project_id)],
              ["Wallet", shortId(relatedEntry.wallet_id)],
              ["Request", shortId(relatedEntry.request_id)],
              ["Related entry", shortId(relatedEntry.related_ledger_entry_id)],
            ]}
          />
        ) : (
          <p className="muted-copy">No related entry summary returned for this adjustment plan.</p>
        )}
      </article>

      {result.refund_remaining_summary ? (
        <article className="admin-panel">
          <h2>Refund Remaining</h2>
          <Fields
            items={[
              [
                "Remaining",
                `${result.refund_remaining_summary.remaining_refundable_amount} ${result.refund_remaining_summary.currency}`,
              ],
              [
                "Requested",
                `${result.refund_remaining_summary.requested_refund_amount} ${result.refund_remaining_summary.currency}`,
              ],
              [
                "Source debit",
                `${result.refund_remaining_summary.source_debit_amount} ${result.refund_remaining_summary.currency}`,
              ],
              [
                "Confirmed credits",
                `${result.refund_remaining_summary.confirmed_credit_amount} ${result.refund_remaining_summary.currency}`,
              ],
              ["Confirmed credit count", String(result.refund_remaining_summary.confirmed_credit_count)],
              ["Tenant bounded", String(result.refund_remaining_summary.tenant_bounded)],
              ["Source bounded", String(result.refund_remaining_summary.source_entry_bounded)],
              ["Currency bounded", String(result.refund_remaining_summary.currency_bounded)],
              ["Confirmed only", String(result.refund_remaining_summary.confirmed_only)],
              ["Credit entry types", result.refund_remaining_summary.credit_entry_types.join(", ")],
            ]}
          />
        </article>
      ) : null}

      <article className="admin-panel">
        <h2>Future Audit / Write Contract</h2>
        <Fields
          items={[
            ["Audit action", futureContract.audit_action],
            ["Ledger write", String(futureContract.ledger_write)],
            ["Upstream call", String(futureContract.upstream_call)],
            ["Audit snapshot", futureContract.audit_snapshot_policy],
            ["Shared transaction", String(futureContract.business_and_success_audit_share_transaction)],
            ["Success audit timing", String(futureContract.success_audit_only_after_ledger_write)],
            ["Audit rollback", String(futureContract.audit_insert_failure_rolls_back_ledger_write)],
            ["Refusal audit", String(futureContract.refusal_does_not_build_success_audit)],
          ]}
        />
      </article>
    </section>
  );
}

function ReconciliationSection() {
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
      <section className="admin-panel" aria-label="Reconciliation filters">
        <div className="section-heading">
          <div>
            <h2>Reconciliation</h2>
            <p>Compare request final costs with settle and refund ledger entries for a UTC day.</p>
          </div>
          <button className="secondary-button" type="button" onClick={() => void loadReport()} disabled={loading}>
            <RefreshCw aria-hidden="true" size={18} className={loading ? "spin" : undefined} />
            Refresh
          </button>
        </div>

        <form className="filter-bar filter-bar--compact" onSubmit={handleSubmit}>
          <label className="field">
            Day
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
            Limit
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
          <button className="primary-button primary-button--inline" type="submit">
            <Search aria-hidden="true" size={17} />
            Search
          </button>
        </form>

        {report ? (
          <p className="muted-copy">
            Period {formatDate(report.period_start)} to {formatDate(report.period_end)}.
          </p>
        ) : null}
        {error ? <p className="form-status form-status--error">{error}</p> : null}
      </section>

      {report ? <ReconciliationStats report={report} /> : null}
      {report ? <ReconciliationSummaryJson report={report} /> : null}

      <ReconciliationCurrencyTotals loading={loading} totals={report?.summary.currency_totals ?? []} />
      <ReconciliationDiscrepancies discrepancies={report?.discrepancies ?? []} loading={loading} />
    </>
  );
}

function PriceVersionStats({ versions }: { versions: PriceVersion[] }) {
  return (
    <section className="feature-stats" aria-label="Price version summary">
      <MetricCard label="Versions" tone="neutral" value={versions.length} />
      <MetricCard label="Active" tone="good" value={countByStatus(versions, "active")} />
      <MetricCard label="Draft" tone="warn" value={countByStatus(versions, "draft")} />
      <MetricCard label="Model scoped" tone="neutral" value={versions.filter((version) => version.canonical_model_id).length} />
    </section>
  );
}

function LedgerStats({ entries }: { entries: LedgerEntry[] }) {
  return (
    <section className="feature-stats" aria-label="Ledger summary">
      <MetricCard label="Entries" tone="neutral" value={entries.length} />
      <MetricCard label="Confirmed" tone="good" value={entries.filter((entry) => entry.status === "confirmed").length} />
      <MetricCard label="Pending" tone="warn" value={entries.filter((entry) => entry.status === "pending").length} />
      <MetricCard label="Net amount" tone="neutral" value={ledgerTotals(entries)} />
    </section>
  );
}

function ReconciliationStats({ report }: { report: BillingReconciliationReport }) {
  const { summary } = report;

  return (
    <section className="feature-stats" aria-label="Reconciliation summary">
      <MetricCard label="Requests" tone="neutral" value={summary.request_count} />
      <MetricCard label="Matched" tone="good" value={summary.matched_request_count} />
      <MetricCard label="Discrepancies" tone="warn" value={summary.discrepancy_count} />
      <MetricCard label="Returned Rows" tone="neutral" value={summary.returned_discrepancy_count} />
    </section>
  );
}

function ReconciliationSummaryJson({ report }: { report: BillingReconciliationReport }) {
  return (
    <section className="admin-panel" aria-label="Reconciliation safe JSON summary">
      <h2>Summary JSON</h2>
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
    <section aria-label="Reconciliation currency totals">
      <div className="health-table-wrap">
        <table className="health-table admin-table admin-table--reconciliation-totals">
          <thead>
            <tr>
              <th>Currency</th>
              <th>Request Final Cost</th>
              <th>Expected Ledger</th>
              <th>Ledger Amount</th>
              <th>Difference</th>
            </tr>
          </thead>
          <tbody>
            {loading && totals.length === 0 ? (
              <tr>
                <td colSpan={5}>Loading reconciliation totals.</td>
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
                <td colSpan={5}>No currency totals returned.</td>
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
}: {
  discrepancies: BillingReconciliationDiscrepancy[];
  loading: boolean;
}) {
  return (
    <section aria-label="Reconciliation discrepancy rows">
      <div className="health-table-wrap">
        <table className="health-table admin-table admin-table--reconciliation">
          <thead>
            <tr>
              <th>Issues</th>
              <th>Request</th>
              <th>Ledger</th>
              <th>Money</th>
              <th>Scope</th>
              <th>Usage</th>
              <th>Route</th>
              <th>Models</th>
            </tr>
          </thead>
          <tbody>
            {loading && discrepancies.length === 0 ? (
              <tr>
                <td colSpan={8}>Loading reconciliation discrepancies.</td>
              </tr>
            ) : discrepancies.length > 0 ? (
              discrepancies.map((discrepancy, index) => (
                <tr key={(discrepancy.request_id ?? discrepancy.ledger_entry_ids.join(":")) || index}>
                  <td>
                    <IssueList issues={discrepancy.issues} />
                  </td>
                  <td>
                    <strong>{safeShortId(discrepancy.request_id)}</strong>
                    <span>Trace {safeFieldValue(discrepancy.trace_id)}</span>
                    <span>Status {safeFieldValue(discrepancy.request_status)}</span>
                  </td>
                  <td>
                    <strong>{formatIdList(discrepancy.ledger_entry_ids)}</strong>
                  </td>
                  <td>
                    <strong>{moneyValue(discrepancy.request_final_cost, discrepancy.request_currency)}</strong>
                    <span>Expected {moneyValue(discrepancy.expected_ledger_amount, discrepancy.request_currency)}</span>
                    <span>Ledger {moneyValue(discrepancy.ledger_amount, discrepancy.ledger_currency)}</span>
                    <span>Diff {safeFieldValue(discrepancy.difference_amount)}</span>
                  </td>
                  <td>
                    <span>Project {safeShortId(discrepancy.project_id)}</span>
                    <span>Virtual Key {safeShortId(discrepancy.virtual_key_id)}</span>
                  </td>
                  <td>
                    <span>Input {safeFieldValue(discrepancy.input_tokens)}</span>
                    <span>Output {safeFieldValue(discrepancy.output_tokens)}</span>
                  </td>
                  <td>
                    <span>Provider {safeShortId(discrepancy.resolved_provider_id)}</span>
                    <span>Channel {safeShortId(discrepancy.resolved_channel_id)}</span>
                    <span>Model {safeShortId(discrepancy.canonical_model_id)}</span>
                  </td>
                  <td>
                    <span>Requested {safeFieldValue(discrepancy.requested_model)}</span>
                    <span>Upstream {safeFieldValue(discrepancy.upstream_model)}</span>
                  </td>
                </tr>
              ))
            ) : (
              <tr>
                <td colSpan={8}>No reconciliation discrepancies returned.</td>
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
  return (
    <section className="detail-grid" aria-label="Price version detail">
      <article className="admin-panel">
        <div className="section-heading">
          <div>
            <h2>Price Version Detail</h2>
            <p>{version.id}</p>
          </div>
          <StateChip status={version.status} />
        </div>
        <Fields
          items={[
            ["Version", version.version],
            ["Price book", shortId(version.price_book_id)],
            ["Model", shortId(version.canonical_model_id)],
            ["Effective", formatDate(version.effective_at)],
            ["Retired", version.retired_at ? formatDate(version.retired_at) : "-"],
            ["Created", formatDate(version.created_at)],
          ]}
        />
      </article>

      <article className="admin-panel">
        <h2>Pricing Rules</h2>
        <JsonBlock value={sanitizeSecretJson(version.pricing_rules)} />
      </article>
    </section>
  );
}

function LedgerEntryDetail({ entry }: { entry: LedgerEntry }) {
  return (
    <section className="detail-grid" aria-label="Ledger entry detail">
      <article className="admin-panel">
        <div className="section-heading">
          <div>
            <h2>Ledger Entry Detail</h2>
            <p>{entry.id}</p>
          </div>
          <StateChip status={entry.status} />
        </div>
        <Fields
          items={[
            ["Type", formatStatus(entry.entry_type)],
            ["Amount", `${entry.amount} ${entry.currency}`],
            ["Project", shortId(entry.project_id)],
            ["Wallet", shortId(entry.wallet_id)],
            ["Request", shortId(entry.request_id)],
            ["Price version", shortId(entry.price_version_id)],
            ["Related entry", shortId(entry.related_ledger_entry_id)],
          ]}
        />
      </article>

      <article className="admin-panel">
        <h2>Usage Snapshot</h2>
        <JsonBlock value={sanitizeSecretJson(entry.usage_snapshot)} />
      </article>

      <article className="admin-panel">
        <h2>Policy Snapshot</h2>
        <JsonBlock value={sanitizeSecretJson(entry.policy_snapshot)} />
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

function parsePricingRulesJsonObject(value: string): JsonObject {
  const pricingRules = parseJsonObject(value, "Pricing rules");

  if (containsUnsafeBillingJson(pricingRules)) {
    throw new PriceVersionFormError(
      "Pricing rules cannot contain unsafe fields: payload, body, auth header, secret, token, API key, or raw key.",
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
    throw new LedgerAdjustmentFormError("Operation must be adjust or refund.");
  }

  if (reason && (isSensitiveDisplayText(reason) || containsUnsafeReasonText(reason))) {
    throw new LedgerAdjustmentFormError(
      "Reason cannot contain credentials, tokens, keys, payload, or body text.",
    );
  }

  if (reason && reason.length > 256) {
    throw new LedgerAdjustmentFormError("Reason must be 256 characters or fewer.");
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
  };
}

function optionalString(value: string): string | undefined {
  const trimmed = value.trim();

  return trimmed ? trimmed : undefined;
}

function requiredString(value: string, label: string): string {
  const trimmed = value.trim();

  if (!trimmed) {
    throw new PriceVersionFormError(`${label} is required.`);
  }

  return trimmed;
}

function requiredAdjustmentString(value: string, label: string): string {
  const trimmed = value.trim();

  if (!trimmed) {
    throw new LedgerAdjustmentFormError(`${label} is required.`);
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
    throw new Error("Day must use YYYY-MM-DD format.");
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
    throw new Error(`${label} must be a positive integer.`);
  }

  return parsed;
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

function formatIdList(values: string[]): string {
  if (values.length === 0) {
    return "-";
  }

  return values.map(safeShortId).join(", ");
}

function moneyValue(amount: string | null | undefined, currency: string | null | undefined): string {
  const safeAmount = safeFieldValue(amount);
  const safeCurrency = safeFieldValue(currency);

  if (safeAmount === "-" && safeCurrency === "-") {
    return "-";
  }

  if (safeCurrency === "-") {
    return safeAmount;
  }

  return `${safeCurrency} ${safeAmount}`;
}

function safeShortId(value: string | null | undefined): string {
  const safeValue = safeFieldValue(value);

  if (safeValue === "-" || safeValue.includes("[redacted]")) {
    return safeValue;
  }

  return shortId(safeValue);
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
