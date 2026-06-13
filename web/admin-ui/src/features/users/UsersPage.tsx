import { FormEvent, useEffect, useMemo, useState } from "react";

import {
  type AdminManagedUser,
  type AdminManagedUserBulkOperationPlan,
  type AdminManagedUserBulkStatusResponse,
  type AdminManagedUserDetail,
  type AdminManagedUserStatusActionResult,
  type AdminWalletCreditSurface,
  type ApiClientError,
  bulkAdminManagedUserStatus,
  disableVirtualKey,
  getAdminManagedUserDetail,
  type LedgerEntry,
  listAdminManagedUsers,
  listAdminWallets,
  listLedgerEntries,
  listRequestLogs,
  listVirtualKeys,
  patchAdminManagedUserStatus,
  planAdminManagedUserBulkOperation,
  restoreVirtualKey,
  type RestoreVirtualKeyResponse,
  type RequestLogSummary,
  type VirtualKey,
} from "../../api/client";
import { errorMessage } from "../../components/adminUtils";
import { Eye, Key, RefreshCw, RotateCcw, ScrollText, Search, ShieldOff } from "../../components/icons";
import { ActionButton } from "../../design/ActionButton";
import { DataTable, type DataTableColumn } from "../../design/DataTable";
import { EmptyState } from "../../design/EmptyState";
import { MetricTile } from "../../design/MetricTile";
import { SectionHeader } from "../../design/SectionHeader";
import { StatusChip } from "../../design/StatusChip";
import { formatCount, formatDateTime, formatMoney, formatTokenUsage } from "../../lib/format";
import { safeDisplayText, safeShortId, safeStatusValue, statusLabel } from "../../lib/safeText";
import type { UsersFocusTarget } from "../../app/types";

type UsersPageProps = {
  focusTarget?: UsersFocusTarget | null;
  onOpenKeys?: () => void;
  onOpenRequestDetail?: (requestId: string) => void;
  onOpenRequests?: () => void;
};

type UserFilterState = {
  limit: string;
  projectId: string;
  search: string;
  status: string;
};

type UserWorkRow = {
  activeKeyCount: number;
  disabledKeyCount: number;
  displayName: string;
  failedRequestCount: number;
  keys: VirtualKey[];
  lastRequestAt?: string | null;
  logs: RequestLogSummary[];
  projectId?: string | null;
  requestCount: number;
  source: "admin_users" | "project_rollup";
  status: string;
  totalCostByCurrency: Map<string, number>;
  user?: AdminManagedUser;
  wallet?: AdminWalletCreditSurface;
};

const DEFAULT_PROJECT_ID = "00000000-0000-0000-0000-000000000020";

const defaultFilters: UserFilterState = {
  limit: "50",
  projectId: DEFAULT_PROJECT_ID,
  search: "",
  status: "",
};

const userTableColumns: DataTableColumn[] = [
  { id: "user", label: "用户", locked: true },
  { id: "balance", label: "余额" },
  { id: "keys", label: "API key" },
  { id: "requests", label: "请求" },
  { id: "ledger", label: "Ledger" },
  { id: "status", label: "状态" },
  { id: "actions", label: "操作", locked: true },
];

const defaultVisibleUserColumns = userTableColumns.map((column) => column.id);

export function UsersPage({ focusTarget, onOpenKeys, onOpenRequestDetail, onOpenRequests }: UsersPageProps) {
  const [actionNotice, setActionNotice] = useState<string | null>(null);
  const [busyKeyId, setBusyKeyId] = useState<string | null>(null);
  const [busyUserId, setBusyUserId] = useState<string | null>(null);
  const [directoryUnavailable, setDirectoryUnavailable] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [filters, setFilters] = useState<UserFilterState>(defaultFilters);
  const [keys, setKeys] = useState<VirtualKey[]>([]);
  const [userDetail, setUserDetail] = useState<AdminManagedUserDetail | null>(null);
  const [userDetailError, setUserDetailError] = useState<string | null>(null);
  const [userDetailLoading, setUserDetailLoading] = useState(false);
  const [ledgerEntries, setLedgerEntries] = useState<LedgerEntry[]>([]);
  const [ledgerLoading, setLedgerLoading] = useState(false);
  const [loading, setLoading] = useState(true);
  const [logs, setLogs] = useState<RequestLogSummary[]>([]);
  const [bulkOperationPlan, setBulkOperationPlan] = useState<AdminManagedUserBulkOperationPlan | null>(null);
  const [bulkOperationPlanAction, setBulkOperationPlanAction] = useState<"disable" | "restore" | "audit_export" | null>(null);
  const [bulkResult, setBulkResult] = useState<AdminManagedUserBulkStatusResponse | null>(null);
  const [bulkStatusAction, setBulkStatusAction] = useState<"active" | "disabled" | null>(null);
  const [selectedUserIds, setSelectedUserIds] = useState<string[]>([]);
  const [selectedProjectId, setSelectedProjectId] = useState<string | null>(DEFAULT_PROJECT_ID);
  const [keyRestoreAction, setKeyRestoreAction] = useState<VirtualKey | null>(null);
  const [userStatusAction, setUserStatusAction] = useState<{ row: UserWorkRow; status: "active" | "disabled" } | null>(null);
  const [users, setUsers] = useState<AdminManagedUser[]>([]);
  const [visibleUserColumns, setVisibleUserColumns] = useState(defaultVisibleUserColumns);
  const [wallets, setWallets] = useState<AdminWalletCreditSurface[]>([]);

  const rows = useMemo(
    () => buildUserWorkRows({ filters, keys, logs, users, wallets }),
    [filters, keys, logs, users, wallets],
  );
  const selectedRow = rows.find((row) => row.projectId === selectedProjectId) ?? rows[0] ?? null;
  const selectedUserCount = selectedUserIds.length;

  async function load(nextFilters = filters) {
    setActionNotice(null);
    setDirectoryUnavailable(null);
    setError(null);
    setLoading(true);

    const projectId = optionalString(nextFilters.projectId);
    const limit = optionalPositiveInteger(nextFilters.limit) ?? 50;

    try {
      const [userResult, walletResult, logResult, keyResult] = await Promise.allSettled([
        listAdminManagedUsers({
          limit,
          project_id: projectId,
          search: optionalString(nextFilters.search),
          status: optionalString(nextFilters.status),
        }),
        listAdminWallets({ limit, project_id: projectId, status: nextFilters.status || undefined }),
        listRequestLogs({ limit: 100 }),
        projectId ? listVirtualKeys({ project_id: projectId }) : Promise.resolve([]),
      ]);

      if (userResult.status === "fulfilled") {
        setUsers(userResult.value);
      } else {
        setUsers([]);
        setDirectoryUnavailable(adminUsersFallbackMessage(userResult.reason));
      }

      if (walletResult.status === "fulfilled") {
        setWallets(walletResult.value);
      } else {
        setWallets([]);
        setError(errorMessage(walletResult.reason));
      }

      setLogs(logResult.status === "fulfilled" ? logResult.value : []);
      setKeys(keyResult.status === "fulfilled" ? keyResult.value : []);
      setSelectedProjectId((current) => current ?? projectId ?? null);
    } finally {
      setLoading(false);
    }
  }

  async function loadLedger(row: UserWorkRow | null) {
    if (!row?.projectId && !row?.wallet?.wallet.id) {
      setLedgerEntries([]);
      return;
    }

    setLedgerLoading(true);
    setError(null);

    try {
      setLedgerEntries(
        await listLedgerEntries({
          limit: 20,
          project_id: row.projectId ?? undefined,
          wallet_id: row.wallet?.wallet.id,
        }),
      );
    } catch (requestError) {
      setLedgerEntries([]);
      setError(errorMessage(requestError));
    } finally {
      setLedgerLoading(false);
    }
  }

  useEffect(() => {
    void load(defaultFilters);
  }, []);

  useEffect(() => {
    if (!focusTarget) {
      return;
    }

    const nextFilters: UserFilterState = {
      ...defaultFilters,
      projectId: focusTarget.projectId?.trim() ?? "",
      search: focusTarget.userId?.trim() ?? "",
      status: focusTarget.status?.trim() ?? "",
    };
    setFilters(nextFilters);
    setSelectedProjectId(focusTarget.projectId?.trim() || null);
    void load(nextFilters);
  }, [focusTarget]);

  useEffect(() => {
    void loadLedger(selectedRow);
  }, [selectedRow?.projectId, selectedRow?.wallet?.wallet.id]);

  useEffect(() => {
    const userId = selectedRow?.user?.id;
    if (!userId) {
      setUserDetail(null);
      setUserDetailError(null);
      setUserDetailLoading(false);
      return;
    }

    let cancelled = false;
    setUserDetailLoading(true);
    setUserDetailError(null);

    getAdminManagedUserDetail(userId)
      .then((detail) => {
        if (!cancelled) {
          setUserDetail(detail);
        }
      })
      .catch((requestError) => {
        if (!cancelled) {
          setUserDetail(null);
          setUserDetailError(errorMessage(requestError));
        }
      })
      .finally(() => {
        if (!cancelled) {
          setUserDetailLoading(false);
        }
      });

    return () => {
      cancelled = true;
    };
  }, [selectedRow?.user?.id]);

  useEffect(() => {
    const visibleUserIds = new Set(rows.map((row) => row.user?.id).filter((id): id is string => Boolean(id)));
    setSelectedUserIds((current) => current.filter((id) => visibleUserIds.has(id)));
  }, [rows]);

  function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    void load(filters);
  }

  function updateFilter(field: keyof UserFilterState, value: string) {
    setFilters((current) => ({ ...current, [field]: value }));
  }

  async function handleDisableKey(key: VirtualKey) {
    setBusyKeyId(key.id);
    setActionNotice(null);
    setError(null);

    try {
      const updated = await disableVirtualKey(key.id);
      setKeys((current) => current.map((item) => (item.id === updated.id ? updated : item)));
      setActionNotice(`已禁用 API key ${safeKeyLabel(updated)}。`);
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setBusyKeyId(null);
    }
  }

  async function handleUserStatusChange(row: UserWorkRow, status: "active" | "disabled", reason: string) {
    const user = row.user;
    if (!user) {
      setActionNotice("当前行来自 project 聚合，没有用户目录 id；请先确认 /admin/users 返回该 project 的用户后再执行用户禁用/恢复。");
      setUserStatusAction(null);
      return;
    }

    setBusyUserId(user.id);
    setActionNotice(null);
    setError(null);

    try {
      const result = await patchAdminManagedUserStatus(user.id, { reason, status });
      setUsers((current) =>
        current.map((item) =>
          item.id === result.user_id
            ? {
                ...item,
                primary_project_id: result.primary_project_id ?? item.primary_project_id,
                project_ids: result.project_ids ?? item.project_ids,
                status: result.status,
              }
            : item,
        ),
      );
      setActionNotice(userStatusNotice(result));
      setUserStatusAction(null);
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setBusyUserId(null);
    }
  }

  function toggleUserSelection(row: UserWorkRow, checked: boolean) {
    const userId = row.user?.id;
    if (!userId) {
      return;
    }
    setSelectedUserIds((current) => {
      if (checked) {
        return current.includes(userId) ? current : [...current, userId];
      }
      return current.filter((id) => id !== userId);
    });
  }

  function selectUserDetail(userId: string, projectId?: string | null) {
    const matchingRow = rows.find((row) => row.user?.id === userId && (!projectId || row.projectId === projectId))
      ?? rows.find((row) => row.user?.id === userId);
    setSelectedProjectId(matchingRow?.projectId ?? projectId ?? null);
  }

  async function handleBulkUserStatusChange(status: "active" | "disabled", reason: string) {
    if (selectedUserIds.length === 0) {
      setActionNotice("请先选择至少一个真实用户目录行；project rollup fallback 不允许用户状态写入。");
      setBulkStatusAction(null);
      return;
    }

    setBusyUserId("bulk");
    setBulkResult(null);
    setActionNotice(null);
    setError(null);

    try {
      const result = await bulkAdminManagedUserStatus({
        reason,
        status,
        user_ids: selectedUserIds,
      });
      setBulkResult(result);
      setUsers((current) => applyBulkUserStatuses(current, result));
      setActionNotice(bulkUserStatusNotice(result));
      setBulkStatusAction(null);
      setSelectedUserIds([]);
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setBusyUserId(null);
    }
  }

  async function handleBulkOperationPlan(action: "disable" | "restore" | "audit_export", reason: string) {
    setBusyUserId("bulk-plan");
    setBulkOperationPlan(null);
    setActionNotice(null);
    setError(null);

    try {
      const result = await planAdminManagedUserBulkOperation({
        action,
        filters: {
          limit: optionalPositiveInteger(filters.limit) ?? 50,
          project_id: optionalString(filters.projectId),
          search: optionalString(filters.search),
          status: optionalString(filters.status),
        },
        mode: "dry_run",
        reason,
        selected_user_ids: selectedUserIds,
      });
      setBulkOperationPlan(result);
      setActionNotice(`已生成 ${statusLabel(action)} dry-run plan：预计 ${result.affected_estimate.estimated_user_count} 个用户。`);
      setBulkOperationPlanAction(null);
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setBusyUserId(null);
    }
  }

  async function handleRestoreKey(key: VirtualKey, reason: string) {
    setBusyKeyId(key.id);
    setActionNotice(null);
    setError(null);

    try {
      const result = await restoreVirtualKey(key.id, { reason });
      setKeys((current) => current.map((item) => (item.id === result.key_id ? keyFromRestoreResult(item, result) : item)));
      setActionNotice(restoreKeyNotice(result));
      setKeyRestoreAction(null);
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setBusyKeyId(null);
    }
  }

  return (
    <div className="admin-page" aria-label="用户管理">
      <section className="admin-panel" aria-label="用户筛选">
        <SectionHeader
          title="Users 管理"
          description="按用户或项目聚合余额、API key、请求和 ledger 摘要；所有凭证、voucher code 和 payload 均只显示安全摘要。"
          actions={
            <ActionButton icon={<RefreshCw aria-hidden="true" className={loading ? "spin" : undefined} size={16} />} onClick={() => void load()} disabled={loading}>
              刷新
            </ActionButton>
          }
        />

        <form className="filter-bar" onSubmit={handleSubmit}>
          <label className="field">
            Project ID
            <input value={filters.projectId} onChange={(event) => updateFilter("projectId", event.currentTarget.value)} />
          </label>
          <label className="field field--compact">
            状态
            <select value={filters.status} onChange={(event) => updateFilter("status", event.currentTarget.value)}>
              <option value="">全部</option>
              <option value="active">active</option>
              <option value="disabled">disabled</option>
              <option value="deleted">deleted</option>
            </select>
          </label>
          <label className="field">
            搜索
            <input value={filters.search} onChange={(event) => updateFilter("search", event.currentTarget.value)} placeholder="display name / masked email / id" />
          </label>
          <label className="field field--compact">
            Limit
            <input min="1" type="number" value={filters.limit} onChange={(event) => updateFilter("limit", event.currentTarget.value)} />
          </label>
          <ActionButton icon={<Search aria-hidden="true" size={16} />} type="submit" variant="primary">
            查询
          </ActionButton>
        </form>

        {directoryUnavailable ? <p className="users-safe-note">{directoryUnavailable}</p> : null}
        {actionNotice ? <p className="success-message">{actionNotice}</p> : null}
        {error ? <p className="error-message">{error}</p> : null}
      </section>

      <section className="users-workspace" aria-label="用户排障工作区">
        <section className="admin-panel" aria-label="用户列表">
          <SectionHeader
            title="用户列表"
            description={loading ? "正在加载用户视图。" : `${rows.length} 个用户/项目视图。`}
            actions={
              <div className="action-row">
                <ActionButton disabled={busyUserId === "bulk-plan"} icon={<ScrollText aria-hidden="true" size={14} />} onClick={() => setBulkOperationPlanAction("audit_export")}>
                  审计计划
                </ActionButton>
                <ActionButton disabled={busyUserId === "bulk-plan"} icon={<ScrollText aria-hidden="true" size={14} />} onClick={() => setBulkOperationPlanAction("disable")}>
                  禁用计划
                </ActionButton>
                <ActionButton disabled={busyUserId === "bulk-plan"} icon={<ScrollText aria-hidden="true" size={14} />} onClick={() => setBulkOperationPlanAction("restore")}>
                  恢复计划
                </ActionButton>
                <ActionButton disabled={selectedUserCount === 0 || busyUserId === "bulk"} icon={<ShieldOff aria-hidden="true" size={14} />} onClick={() => setBulkStatusAction("disabled")}>
                  批量禁用
                </ActionButton>
                <ActionButton disabled={selectedUserCount === 0 || busyUserId === "bulk"} icon={<RotateCcw aria-hidden="true" size={14} />} onClick={() => setBulkStatusAction("active")}>
                  批量恢复
                </ActionButton>
              </div>
            }
          />
          <p className="users-safe-note">
            已选择 {selectedUserCount} 个真实用户目录行；project rollup fallback 为只读，write_allowed=false。
          </p>
          {bulkOperationPlan ? <BulkUserOperationPlanResult plan={bulkOperationPlan} onOpenUserDetail={selectUserDetail} /> : null}
          {bulkResult ? <BulkUserStatusResults result={bulkResult} onOpenUserDetail={selectUserDetail} /> : null}

          {rows.length === 0 ? (
            <EmptyState title="没有用户数据" detail="先让用户注册、兑换额度并创建 API key；或输入 project ID 查看对应钱包、key 和请求摘要。" />
          ) : (
            <DataTable
              aria-label="用户列表"
              columns={userTableColumns}
              stickyFirstColumn
              visibleColumns={visibleUserColumns}
              onVisibleColumnsChange={setVisibleUserColumns}
            >
              <thead>
                <tr>
                  <th>用户</th>
                  <th>余额</th>
                  <th>API key</th>
                  <th>请求</th>
                  <th>Ledger</th>
                  <th>状态</th>
                  <th>操作</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((row) => (
                  <tr key={rowKey(row)} className={selectedRow && rowKey(row) === rowKey(selectedRow) ? "table-row--selected" : undefined}>
                    <td>
                      <input
                        aria-label={`选择用户 ${row.displayName}`}
                        checked={Boolean(row.user?.id && selectedUserIds.includes(row.user.id))}
                        disabled={!row.user}
                        type="checkbox"
                        onChange={(event) => toggleUserSelection(row, event.currentTarget.checked)}
                      />
                      <strong>{row.displayName}</strong>
                      <span className="table-subtext">{safeShortId(row.projectId)}</span>
                    </td>
                    <td>{walletBalanceLabel(row.wallet)}</td>
                    <td>{row.activeKeyCount} active / {row.disabledKeyCount} disabled</td>
                    <td>{row.requestCount} total / {row.failedRequestCount} failed</td>
                    <td>{ledgerRowLabel(row.wallet)}</td>
                    <td><StatusChip tone={statusTone(row.status)}>{statusLabel(row.status)}</StatusChip></td>
                    <td>
                      <div className="action-row">
                        <ActionButton icon={<Eye aria-hidden="true" size={14} />} variant="table" onClick={() => setSelectedProjectId(row.projectId ?? null)}>
                          查看
                        </ActionButton>
                        <ActionButton
                          disabled={!row.user || busyUserId === row.user?.id}
                          icon={row.status === "disabled" ? <RotateCcw aria-hidden="true" size={14} /> : <ShieldOff aria-hidden="true" size={14} />}
                          variant="table"
                          onClick={() => setUserStatusAction({ row, status: row.status === "disabled" ? "active" : "disabled" })}
                        >
                          {row.status === "disabled" ? "恢复" : "禁用"}
                        </ActionButton>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </DataTable>
          )}
        </section>

        <UserDetailPanel
          busyKeyId={busyKeyId}
          ledgerEntries={ledgerEntries}
          ledgerLoading={ledgerLoading}
          row={selectedRow}
          userDetail={userDetail}
          userDetailError={userDetailError}
          userDetailLoading={userDetailLoading}
          onDisableKey={(key) => void handleDisableKey(key)}
          onOpenKeys={onOpenKeys}
          onOpenRequestDetail={onOpenRequestDetail}
          onOpenRequests={onOpenRequests}
          onUserStatusAction={(row, status) => setUserStatusAction({ row, status })}
          onRestoreKey={setKeyRestoreAction}
        />
      </section>

      {keyRestoreAction ? (
        <KeyRestoreDialog
          busy={busyKeyId === keyRestoreAction.id}
          keySummary={keyRestoreAction}
          onCancel={() => setKeyRestoreAction(null)}
          onSubmit={(reason) => void handleRestoreKey(keyRestoreAction, reason)}
        />
      ) : null}

      {userStatusAction ? (
        <UserStatusActionDialog
          action={userStatusAction}
          busy={busyUserId === userStatusAction.row.user?.id}
          onCancel={() => setUserStatusAction(null)}
          onSubmit={(reason) => void handleUserStatusChange(userStatusAction.row, userStatusAction.status, reason)}
        />
      ) : null}

      {bulkStatusAction ? (
        <BulkUserStatusActionDialog
          busy={busyUserId === "bulk"}
          selectedCount={selectedUserCount}
          status={bulkStatusAction}
          onCancel={() => setBulkStatusAction(null)}
          onSubmit={(reason) => void handleBulkUserStatusChange(bulkStatusAction, reason)}
        />
      ) : null}

      {bulkOperationPlanAction ? (
        <BulkUserOperationPlanDialog
          action={bulkOperationPlanAction}
          busy={busyUserId === "bulk-plan"}
          selectedCount={selectedUserCount}
          onCancel={() => setBulkOperationPlanAction(null)}
          onSubmit={(reason) => void handleBulkOperationPlan(bulkOperationPlanAction, reason)}
        />
      ) : null}
    </div>
  );
}

export default UsersPage;

function UserDetailPanel({
  busyKeyId,
  ledgerEntries,
  ledgerLoading,
  onDisableKey,
  onOpenKeys,
  onOpenRequestDetail,
  onOpenRequests,
  onUserStatusAction,
  onRestoreKey,
  row,
  userDetail,
  userDetailError,
  userDetailLoading,
}: {
  busyKeyId: string | null;
  ledgerEntries: LedgerEntry[];
  ledgerLoading: boolean;
  row: UserWorkRow | null;
  userDetail: AdminManagedUserDetail | null;
  userDetailError: string | null;
  userDetailLoading: boolean;
  onDisableKey: (key: VirtualKey) => void;
  onOpenKeys?: () => void;
  onOpenRequestDetail?: (requestId: string) => void;
  onOpenRequests?: () => void;
  onUserStatusAction: (row: UserWorkRow, status: "active" | "disabled") => void;
  onRestoreKey: (key: VirtualKey) => void;
}) {
  if (!row) {
    return (
      <section className="admin-panel" aria-label="用户详情">
        <EmptyState title="选择用户" detail="选择一行后查看余额、key、请求和 ledger 安全摘要。" />
      </section>
    );
  }

  return (
    <section className="admin-panel users-detail" aria-label="用户详情">
      <SectionHeader
        title={row.displayName}
        description={`Project ${safeShortId(row.projectId)} / ${row.source === "admin_users" ? "用户目录" : "项目聚合"}`}
        actions={
          <div className="action-row">
            <ActionButton disabled={!row.user || row.status === "disabled"} icon={<ShieldOff aria-hidden="true" size={16} />} onClick={() => onUserStatusAction(row, "disabled")}>
              禁用用户
            </ActionButton>
            <ActionButton disabled={!row.user || row.status === "active"} icon={<RotateCcw aria-hidden="true" size={16} />} onClick={() => onUserStatusAction(row, "active")}>
              恢复用户
            </ActionButton>
          </div>
        }
      />
      {!row.user ? (
        <p className="users-safe-note">当前为 project rollup fallback 视图，只读聚合 wallet/key/request/ledger；禁用/恢复需要 `/admin/users` 返回真实 user_id。</p>
      ) : null}
      {row.user ? (
        <p className="users-safe-note">
          详情 readback 来自 <code>GET /admin/users/{safeShortId(row.user.id)}/detail</code>；secret、raw payload、provider key、voucher raw code 和 idempotency key 均按 omitted fields 处理。
        </p>
      ) : null}
      {userDetailLoading ? <p className="muted-copy">正在读取用户详情 readback。</p> : null}
      {userDetailError ? <p className="error-message">用户详情读取失败：{userDetailError}</p> : null}

      <div className="metric-card-grid">
        <MetricTile
          label="Wallet"
          value={userDetail ? formatCount(userDetail.wallet_summary.active_wallet_count) : walletBalanceLabel(row.wallet)}
          detail={userDetail ? `${userDetail.wallet_summary.wallet_count} total / ${statusLabel(userDetail.wallet_summary.readback_status)}` : walletLedgerDetail(row.wallet)}
          tone={userDetail ? readbackTone(userDetail.wallet_summary.readback_status) : balanceTone(row.wallet)}
        />
        <MetricTile
          label="API key"
          value={`${userDetail?.key_summary.active_key_count ?? row.activeKeyCount} active`}
          detail={`${userDetail?.key_summary.inactive_key_count ?? row.disabledKeyCount} inactive / secret_returned=${String(userDetail?.key_summary.secret_returned ?? false)}`}
          tone={(userDetail?.key_summary.active_key_count ?? row.activeKeyCount) > 0 ? "good" : "warn"}
        />
        <MetricTile
          label="请求"
          value={formatCount(userDetail?.request_summary.request_count ?? row.requestCount)}
          detail={`${userDetail?.request_summary.failed_count ?? row.failedRequestCount} failed / payload_returned=${String(userDetail?.request_summary.payload_returned ?? false)}`}
          tone={(userDetail?.request_summary.failed_count ?? row.failedRequestCount) > 0 ? "warn" : "neutral"}
        />
        <MetricTile
          label="Risk"
          value={statusLabel(userDetail?.risk_policy_summary.status ?? "local")}
          detail={userDetail?.risk_policy_summary.recommendation ?? "等待用户详情 readback"}
          tone={userDetail ? metricTone(userDetail.risk_policy_summary.status) : "neutral"}
        />
      </div>

      <div className="detail-grid detail-grid--compact">
        {userDetail ? <AdminUserDetailReadbackPanel detail={userDetail} /> : null}

        <article className="detail-panel">
          <h3>API key 摘要</h3>
          {row.keys.length === 0 ? (
            <p className="muted-copy">当前 project 没有加载到 API key；可打开 API 密钥页面按 project 查询。</p>
          ) : (
            <DataTable aria-label="用户 API key 摘要">
              <thead>
                <tr>
                  <th>名称</th>
                  <th>Prefix</th>
                  <th>状态</th>
                  <th>操作</th>
                </tr>
              </thead>
              <tbody>
                {row.keys.map((key) => (
                  <tr key={key.id}>
                    <td>{safeDisplayText(key.name)}</td>
                    <td>{safeDisplayText(key.key_prefix)}</td>
                    <td><StatusChip tone={statusTone(key.status)}>{statusLabel(key.status)}</StatusChip></td>
                    <td>
                      {key.status === "active" ? (
                        <ActionButton
                          disabled={busyKeyId === key.id}
                          icon={<ShieldOff aria-hidden="true" size={14} />}
                          variant="table"
                          onClick={() => onDisableKey(key)}
                        >
                          禁用
                        </ActionButton>
                      ) : (
                        <ActionButton
                          disabled={busyKeyId === key.id}
                          icon={<RotateCcw aria-hidden="true" size={14} />}
                          variant="table"
                          onClick={() => onRestoreKey(key)}
                        >
                          恢复
                        </ActionButton>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </DataTable>
          )}
          {onOpenKeys ? (
            <ActionButton className="users-followup-action" icon={<Key aria-hidden="true" size={16} />} onClick={onOpenKeys}>
              打开 API 密钥
            </ActionButton>
          ) : null}
        </article>

        <article className="detail-panel">
          <h3>最近请求</h3>
          {row.logs.length === 0 ? (
            <p className="muted-copy">当前 project 没有最近请求；用户调用 gateway 后会显示模型、成本和错误摘要。</p>
          ) : (
            <DataTable aria-label="用户最近请求摘要">
              <thead>
                <tr>
                  <th>请求</th>
                  <th>模型</th>
                  <th>成本</th>
                  <th>状态</th>
                </tr>
              </thead>
              <tbody>
                {row.logs.slice(0, 6).map((log) => (
                  <tr key={log.id}>
                    <td>
                      <button className="link-button" type="button" onClick={() => onOpenRequestDetail?.(log.id)}>
                        {safeShortId(log.id)}
                      </button>
                      <span className="table-subtext">{formatDateTime(log.created_at)}</span>
                    </td>
                    <td>{safeDisplayText(log.requested_model ?? log.upstream_model)}</td>
                    <td>{formatMoney(log.final_cost, log.currency)}</td>
                    <td><StatusChip tone={statusTone(log.status)}>{statusLabel(log.status)}</StatusChip></td>
                  </tr>
                ))}
              </tbody>
            </DataTable>
          )}
          {onOpenRequests ? (
            <ActionButton className="users-followup-action" icon={<Eye aria-hidden="true" size={16} />} onClick={onOpenRequests}>
              打开请求日志
            </ActionButton>
          ) : null}
        </article>

        <article className="detail-panel detail-panel--wide">
          <h3>Ledger 摘要</h3>
          {ledgerLoading ? (
            <p className="muted-copy">正在加载 ledger 摘要。</p>
          ) : ledgerEntries.length === 0 ? (
            <p className="muted-copy">没有 ledger entry；充值、voucher 兑换或 gateway 计费后会出现 reserve/settle/refund/adjust 摘要。</p>
          ) : (
            <DataTable aria-label="用户 ledger 摘要">
              <thead>
                <tr>
                  <th>Entry</th>
                  <th>类型</th>
                  <th>金额</th>
                  <th>请求</th>
                  <th>用量</th>
                  <th>状态</th>
                </tr>
              </thead>
              <tbody>
                {ledgerEntries.map((entry) => (
                  <tr key={entry.id}>
                    <td>
                      {safeShortId(entry.id)}
                      <span className="table-subtext">{formatDateTime(entry.occurred_at)}</span>
                    </td>
                    <td>{statusLabel(entry.entry_type)}</td>
                    <td>{formatMoney(entry.amount, entry.currency)}</td>
                    <td>{safeShortId(entry.request_id)}</td>
                    <td>{ledgerUsageLabel(entry)}</td>
                    <td><StatusChip tone={statusTone(entry.status)}>{statusLabel(entry.status)}</StatusChip></td>
                  </tr>
                ))}
              </tbody>
            </DataTable>
          )}
        </article>
      </div>
    </section>
  );
}

function AdminUserDetailReadbackPanel({ detail }: { detail: AdminManagedUserDetail }) {
  return (
    <>
      <article className="detail-panel">
        <h3>详情 readback</h3>
        <dl className="detail-list">
          <div>
            <dt>User</dt>
            <dd>{userDisplayName(detail.user)} / {safeShortId(detail.user.id)}</dd>
          </div>
          <div>
            <dt>Status</dt>
            <dd><StatusChip tone={statusTone(detail.user.status)}>{statusLabel(detail.user.status)}</StatusChip></dd>
          </div>
          <div>
            <dt>Last login</dt>
            <dd>{formatDateTime(detail.user.last_login_at)}</dd>
          </div>
          <div>
            <dt>Project scope</dt>
            <dd>{formatCount(detail.tenant_boundary.project_count)} projects / write_allowed={String(detail.project_rollup_fallback.write_allowed)}</dd>
          </div>
        </dl>
      </article>

      <article className="detail-panel">
        <h3>Wallet / Request / Ledger</h3>
        <dl className="detail-list">
          <div>
            <dt>Wallets</dt>
            <dd>{detail.wallet_summary.active_wallet_count} active / {detail.wallet_summary.wallet_count} total</dd>
          </div>
          <div>
            <dt>Requests</dt>
            <dd>{detail.request_summary.succeeded_count} success / {detail.request_summary.failed_count} failed</dd>
          </div>
          <div>
            <dt>Tokens</dt>
            <dd>{formatTokenUsage(detail.request_summary.input_tokens, detail.request_summary.output_tokens)}</dd>
          </div>
          <div>
            <dt>Ledger</dt>
            <dd>{detail.ledger_summary.confirmed_entry_count} confirmed / idempotency_key_returned={String(detail.ledger_summary.idempotency_key_returned)}</dd>
          </div>
        </dl>
      </article>

      <article className="detail-panel">
        <h3>Risk policy</h3>
        <dl className="detail-list">
          <div>
            <dt>Status</dt>
            <dd><StatusChip tone={statusTone(detail.risk_policy_summary.status)}>{statusLabel(detail.risk_policy_summary.status)}</StatusChip></dd>
          </div>
          <div>
            <dt>Signals</dt>
            <dd>
              {detail.risk_policy_summary.signals.active_key_count} active keys / {detail.risk_policy_summary.signals.failed_request_count} failed requests
            </dd>
          </div>
          <div>
            <dt>Enforcement</dt>
            <dd>automatic={String(detail.risk_policy_summary.automatic_enforcement)} / operator_required={String(detail.risk_policy_summary.operator_confirmation_required)}</dd>
          </div>
          <div>
            <dt>Recommendation</dt>
            <dd>{safeDisplayText(detail.risk_policy_summary.recommendation)}</dd>
          </div>
        </dl>
      </article>

      <article className="detail-panel">
        <h3>Tenant boundary</h3>
        <dl className="detail-list">
          <div>
            <dt>Boundary</dt>
            <dd><StatusChip tone={statusTone(detail.tenant_boundary.boundary_status)}>{statusLabel(detail.tenant_boundary.boundary_status)}</StatusChip></dd>
          </div>
          <div>
            <dt>Tenant</dt>
            <dd>{safeShortId(detail.tenant_boundary.tenant_id)} / cross_tenant={String(detail.tenant_boundary.cross_tenant_lookup_allowed)}</dd>
          </div>
          <div>
            <dt>Projects</dt>
            <dd>{summarizeIds(detail.tenant_boundary.project_ids)}</dd>
          </div>
          <div>
            <dt>Source tables</dt>
            <dd>{summarizeList(detail.tenant_boundary.source_tables)}</dd>
          </div>
        </dl>
      </article>

      <article className="detail-panel">
        <h3>Production audit</h3>
        <dl className="detail-list">
          <div>
            <dt>Status</dt>
            <dd><StatusChip tone={statusTone(detail.production_audit_report.status)}>{statusLabel(detail.production_audit_report.status)}</StatusChip></dd>
          </div>
          <div>
            <dt>Recent audit</dt>
            <dd>{detail.recent_audit_summary.audit_log_count} logs / raw_snapshots_returned={String(detail.recent_audit_summary.raw_snapshots_returned)}</dd>
          </div>
          <div>
            <dt>Last audit</dt>
            <dd>{formatDateTime(detail.recent_audit_summary.last_audit_at)}</dd>
          </div>
          <div>
            <dt>Next step</dt>
            <dd>{safeDisplayText(detail.production_audit_report.next_step)}</dd>
          </div>
        </dl>
      </article>

      <article className="detail-panel">
        <h3>Omitted fields</h3>
        <p className="muted-copy">{summarizeList(detail.omitted_fields)}</p>
        <p className="users-safe-note">
          secret_safe={String(detail.secret_safe)} / external_ml={String(detail.risk_policy_summary.external_ml_connected)} / external_siem={String(detail.production_audit_report.external_siem_connected)}
        </p>
      </article>
    </>
  );
}

function UserStatusActionDialog({
  action,
  busy,
  onCancel,
  onSubmit,
}: {
  action: { row: UserWorkRow; status: "active" | "disabled" };
  busy: boolean;
  onCancel: () => void;
  onSubmit: (reason: string) => void;
}) {
  const [reason, setReason] = useState("");
  const verb = action.status === "disabled" ? "禁用" : "恢复";

  function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const normalizedReason = reason.trim();
    if (!normalizedReason) {
      return;
    }
    onSubmit(normalizedReason);
  }

  return (
    <section className="admin-panel" aria-label={`${verb}用户`}>
      <form className="users-status-form" onSubmit={handleSubmit}>
        <SectionHeader
          title={`${verb}用户`}
          description={`${action.row.displayName} / Project ${safeShortId(action.row.projectId)}。需要填写 audit reason；不会展示 secret、voucher raw code 或 payload。`}
        />
        <label className="field">
          Audit reason
          <textarea
            maxLength={256}
            required
            rows={4}
            value={reason}
            onChange={(event) => setReason(event.currentTarget.value)}
            placeholder="例如：用户请求暂停访问、风控复核、欠费人工处理"
          />
        </label>
        {!action.row.user ? (
          <p className="users-safe-note">当前行没有用户目录 id，提交后会提示先确认用户目录记录；不会对 project 聚合数据做隐式写入。</p>
        ) : null}
        <div className="action-row action-row--end">
          <ActionButton type="button" onClick={onCancel}>
            取消
          </ActionButton>
          <ActionButton disabled={busy || !reason.trim()} icon={action.status === "disabled" ? <ShieldOff aria-hidden="true" size={16} /> : <RotateCcw aria-hidden="true" size={16} />} type="submit" variant="primary">
            {busy ? "提交中" : verb}
          </ActionButton>
        </div>
      </form>
    </section>
  );
}

function BulkUserStatusActionDialog({
  busy,
  onCancel,
  onSubmit,
  selectedCount,
  status,
}: {
  busy: boolean;
  onCancel: () => void;
  onSubmit: (reason: string) => void;
  selectedCount: number;
  status: "active" | "disabled";
}) {
  const [reason, setReason] = useState("");
  const verb = status === "disabled" ? "批量禁用" : "批量恢复";

  function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const normalizedReason = reason.trim();
    if (!normalizedReason || selectedCount === 0) {
      return;
    }
    onSubmit(normalizedReason);
  }

  return (
    <section className="admin-panel" aria-label={verb}>
      <form className="users-status-form" onSubmit={handleSubmit}>
        <SectionHeader
          title={verb}
          description={`${selectedCount} 个真实用户目录行。提交后返回 operation_id、逐行 action_result 和 audit refs；project rollup fallback 仍为 write_allowed=false。`}
        />
        <label className="field">
          Audit reason
          <textarea
            maxLength={256}
            required
            rows={4}
            value={reason}
            onChange={(event) => setReason(event.currentTarget.value)}
            placeholder="例如：批量风控复核、运营暂停访问、人工恢复误禁用用户"
          />
        </label>
        <p className="users-safe-note">批量结果不会展示 API key secret、secret hash、Authorization、voucher raw code、raw payload 或 provider key。</p>
        <div className="action-row action-row--end">
          <ActionButton type="button" onClick={onCancel}>
            取消
          </ActionButton>
          <ActionButton disabled={busy || selectedCount === 0 || !reason.trim()} icon={status === "disabled" ? <ShieldOff aria-hidden="true" size={16} /> : <RotateCcw aria-hidden="true" size={16} />} type="submit" variant="primary">
            {busy ? "提交中" : verb}
          </ActionButton>
        </div>
      </form>
    </section>
  );
}

function BulkUserOperationPlanDialog({
  action,
  busy,
  onCancel,
  onSubmit,
  selectedCount,
}: {
  action: "disable" | "restore" | "audit_export";
  busy: boolean;
  onCancel: () => void;
  onSubmit: (reason: string) => void;
  selectedCount: number;
}) {
  const [reason, setReason] = useState("");
  const actionLabel = action === "audit_export" ? "审计导出计划" : action === "disable" ? "批量禁用计划" : "批量恢复计划";

  function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const normalizedReason = reason.trim();
    if (!normalizedReason) {
      return;
    }
    onSubmit(normalizedReason);
  }

  return (
    <section className="admin-panel" aria-label={actionLabel}>
      <form className="users-status-form" onSubmit={handleSubmit}>
        <SectionHeader
          title={actionLabel}
          description={
            selectedCount > 0
              ? `${selectedCount} 个选中用户。只生成 dry-run plan，不写入用户状态或外部 SIEM。`
              : "未选择用户时按当前筛选范围估算。只生成 dry-run plan，不写入用户状态或外部 SIEM。"
          }
        />
        <label className="field">
          Plan reason
          <textarea
            maxLength={256}
            required
            rows={4}
            value={reason}
            onChange={(event) => setReason(event.currentTarget.value)}
            placeholder="例如：运营批量风控复核、生产审计导出准备、人工禁用前 dry-run"
          />
        </label>
        <p className="users-safe-note">
          Plan 只返回 affected estimate、blocked reasons、risk policy summary 和 audit export plan；不返回 password hash、key secret/hash、Authorization、provider key、voucher raw code、raw payload、raw audit snapshot、idempotency key 或完整 token。
        </p>
        <div className="action-row action-row--end">
          <ActionButton type="button" onClick={onCancel}>
            取消
          </ActionButton>
          <ActionButton disabled={busy || !reason.trim()} icon={<ScrollText aria-hidden="true" size={16} />} type="submit" variant="primary">
            {busy ? "生成中" : "生成 dry-run plan"}
          </ActionButton>
        </div>
      </form>
    </section>
  );
}

function BulkUserOperationPlanResult({
  onOpenUserDetail,
  plan,
}: {
  onOpenUserDetail: (userId: string, projectId?: string | null) => void;
  plan: AdminManagedUserBulkOperationPlan;
}) {
  return (
    <article className="detail-panel" aria-label="批量用户运营计划">
      <h3>批量运营 dry-run plan</h3>
      <div className="metric-card-grid">
        <MetricTile label="Affected" value={formatCount(plan.affected_estimate.estimated_user_count)} detail={`${plan.affected_estimate.active_user_count} active / ${plan.affected_estimate.disabled_user_count} disabled`} tone="neutral" />
        <MetricTile label="Blocked" value={formatCount(plan.blocked_reasons.length)} detail={`${plan.affected_estimate.missing_selected_count} missing selected`} tone={plan.blocked_reasons.length > 0 ? "warn" : "good"} />
        <MetricTile label="Risk" value={statusLabel(plan.risk_policy_summary.status)} detail={safeDisplayText(plan.risk_policy_summary.summary)} tone={metricTone(plan.risk_policy_summary.status)} />
        <MetricTile label="Audit export" value={statusLabel(plan.audit_export_plan.status)} detail={`SIEM=${String(plan.audit_export_plan.external_siem_connected)} / raw=${String(plan.audit_export_plan.raw_snapshots_returned)}`} tone="neutral" />
      </div>
      <dl className="detail-list">
        <div>
          <dt>Scope</dt>
          <dd>{statusLabel(plan.scope.source)} / selected {plan.scope.selected_user_count} / cross_tenant={String(plan.scope.cross_tenant_lookup_allowed)}</dd>
        </div>
        <div>
          <dt>Apply policy</dt>
          <dd>{plan.apply_policy.message} / supported={String(plan.apply_policy.apply_supported)}</dd>
        </div>
        <div>
          <dt>Safe export fields</dt>
          <dd>{summarizeList(plan.audit_export_plan.safe_fields)}</dd>
        </div>
        <div>
          <dt>Omitted</dt>
          <dd>{summarizeList(plan.omitted_fields)}</dd>
        </div>
      </dl>
      {plan.rows.length > 0 ? (
        <DataTable aria-label="批量用户运营计划逐行结果">
          <thead>
            <tr>
              <th>User</th>
              <th>计划结果</th>
              <th>Project</th>
              <th>Blocked</th>
              <th>详情</th>
            </tr>
          </thead>
          <tbody>
            {plan.rows.slice(0, 10).map((row) => (
              <tr key={`${plan.schema}-${row.user_id}`}>
                <td>{safeShortId(row.user_id)}</td>
                <td>{statusLabel(row.planned_action_result)}</td>
                <td>{formatCount(row.project_count)}</td>
                <td>{row.blocked_reasons.length ? summarizeList(row.blocked_reasons) : "none"}</td>
                <td>
                  <ActionButton
                    icon={<Eye aria-hidden="true" size={14} />}
                    variant="table"
                    onClick={() => onOpenUserDetail(row.user_id, row.project_ids[0])}
                  >
                    打开详情
                  </ActionButton>
                </td>
              </tr>
            ))}
          </tbody>
        </DataTable>
      ) : (
        <p className="muted-copy">当前范围没有匹配用户。</p>
      )}
    </article>
  );
}

function BulkUserStatusResults({
  onOpenUserDetail,
  result,
}: {
  onOpenUserDetail: (userId: string, projectId?: string | null) => void;
  result: AdminManagedUserBulkStatusResponse;
}) {
  return (
    <article className="detail-panel" aria-label="批量用户操作结果">
      <h3>最近批量操作</h3>
      <p className="muted-copy">
        operation {safeShortId(result.operation_id)} / affected {result.affected_count} / failed {result.failed_count} / audit refs {result.audit_log_ids.length}
      </p>
      <DataTable aria-label="批量用户操作逐行结果">
        <thead>
          <tr>
            <th>User</th>
            <th>结果</th>
            <th>状态</th>
            <th>Audit</th>
            <th>Readback</th>
            <th>详情</th>
          </tr>
        </thead>
        <tbody>
          {result.results.map((row) => (
            <tr key={`${result.operation_id}-${row.user_id}`}>
              <td>{safeShortId(row.user_id)}</td>
              <td>{statusLabel(row.action_result)}</td>
              <td>{statusLabel(row.status)}</td>
              <td>{safeShortId(row.audit_log_id)}</td>
              <td>
                {row.error
                  ? safeDisplayText(row.error.code ?? row.error.message)
                  : row.readback?.status_matches_target && row.readback.audit_log_readback
                    ? "users/audit confirmed"
                    : "needs review"}
              </td>
              <td>
                <ActionButton
                  icon={<Eye aria-hidden="true" size={14} />}
                  variant="table"
                  onClick={() => onOpenUserDetail(row.user_id, row.primary_project_id)}
                >
                  打开详情
                </ActionButton>
              </td>
            </tr>
          ))}
        </tbody>
      </DataTable>
    </article>
  );
}

function KeyRestoreDialog({
  busy,
  keySummary,
  onCancel,
  onSubmit,
}: {
  busy: boolean;
  keySummary: VirtualKey;
  onCancel: () => void;
  onSubmit: (reason: string) => void;
}) {
  const [confirmed, setConfirmed] = useState(false);
  const [reason, setReason] = useState("");
  const normalizedStatus = safeStatusValue(keySummary.status);
  const disabledRestore = normalizedStatus === "disabled";
  const description = disabledRestore
    ? "该路径只恢复 disabled API key 到 active；不会显示或重发 key secret。"
    : "该 key 当前不是 disabled；提交后会走后端安全拒绝路径并返回 audit id 与原因，不会恢复 secret。";

  function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const normalizedReason = reason.trim();
    if (!normalizedReason || !confirmed) {
      return;
    }
    onSubmit(normalizedReason);
  }

  return (
    <section className="admin-panel" aria-label="恢复 API key">
      <form className="users-status-form" onSubmit={handleSubmit}>
        <SectionHeader
          title="恢复 API key"
          description={`${safeKeyLabel(keySummary)} / ${statusLabel(keySummary.status)}。${description}`}
        />
        <div className="detail-grid detail-grid--compact">
          <MetricTile label="Key id" value={safeShortId(keySummary.id)} detail="secret omitted" tone="neutral" />
          <MetricTile label="Prefix" value={safeDisplayText(keySummary.key_prefix)} detail="safe identifier only" tone="neutral" />
          <MetricTile label="当前状态" value={statusLabel(keySummary.status)} detail={disabledRestore ? "eligible for disabled -> active" : "restore will be refused if unsupported"} tone="warn" />
        </div>
        <label className="field">
          Audit reason
          <textarea
            maxLength={256}
            required
            rows={4}
            value={reason}
            onChange={(event) => setReason(event.currentTarget.value)}
            placeholder="例如：管理员确认误禁用，用户身份已复核，需要恢复 disabled key"
          />
        </label>
        <label className="checkbox-field">
          <input checked={confirmed} required type="checkbox" onChange={(event) => setConfirmed(event.currentTarget.checked)} />
          确认只恢复 disabled key 到 active；deleted/expired key 必须重发新 key，不展示或恢复 secret。
        </label>
        <div className="action-row action-row--end">
          <ActionButton type="button" onClick={onCancel}>
            取消
          </ActionButton>
          <ActionButton disabled={busy || !reason.trim() || !confirmed} icon={<RotateCcw aria-hidden="true" size={16} />} type="submit" variant="primary">
            {busy ? "提交中" : "确认恢复"}
          </ActionButton>
        </div>
      </form>
    </section>
  );
}

function buildUserWorkRows(input: {
  filters: UserFilterState;
  keys: VirtualKey[];
  logs: RequestLogSummary[];
  users: AdminManagedUser[];
  wallets: AdminWalletCreditSurface[];
}): UserWorkRow[] {
  const rows = new Map<string, UserWorkRow>();
  const search = input.filters.search.trim().toLowerCase();
  const status = input.filters.status.trim();
  const projectFilter = input.filters.projectId.trim();

  for (const user of input.users) {
    const projectIds = user.project_ids?.length ? user.project_ids : user.primary_project_id ? [user.primary_project_id] : [null];
    for (const projectId of projectIds) {
      const key = projectId ?? user.id;
      rows.set(key, emptyRow({
        displayName: userDisplayName(user),
        projectId,
        source: "admin_users",
        status: user.status,
        user,
      }));
    }
  }

  for (const wallet of input.wallets) {
    const projectId = wallet.wallet.project_id ?? wallet.wallet.id;
    const current = rows.get(projectId) ?? emptyRow({
      displayName: `Project ${safeShortId(projectId)}`,
      projectId,
      source: "project_rollup",
      status: wallet.wallet.status,
    });
    current.wallet = wallet;
    current.status = current.user?.status ?? wallet.wallet.status;
    rows.set(projectId, current);
  }

  for (const key of input.keys) {
    const current = rows.get(key.project_id) ?? emptyRow({
      displayName: `Project ${safeShortId(key.project_id)}`,
      projectId: key.project_id,
      source: "project_rollup",
      status: "active",
    });
    current.keys.push(key);
    if (key.status === "active") {
      current.activeKeyCount += 1;
    } else if (key.status === "disabled") {
      current.disabledKeyCount += 1;
    }
    rows.set(key.project_id, current);
  }

  for (const log of input.logs) {
    if (!log.project_id) {
      continue;
    }
    const current = rows.get(log.project_id) ?? emptyRow({
      displayName: `Project ${safeShortId(log.project_id)}`,
      projectId: log.project_id,
      source: "project_rollup",
      status: "active",
    });
    current.logs.push(log);
    current.requestCount += 1;
    if (log.status !== "succeeded" && log.status !== "success") {
      current.failedRequestCount += 1;
    }
    current.lastRequestAt = newestDate(current.lastRequestAt, log.created_at);
    addCurrencyAmount(current.totalCostByCurrency, log.currency, log.final_cost);
    rows.set(log.project_id, current);
  }

  return Array.from(rows.values())
    .filter((row) => !projectFilter || row.projectId === projectFilter)
    .filter((row) => !status || row.status === status)
    .filter((row) => !search || rowMatchesSearch(row, search))
    .sort((a, b) => (b.lastRequestAt ?? "").localeCompare(a.lastRequestAt ?? ""));
}

function emptyRow(input: Pick<UserWorkRow, "displayName" | "projectId" | "source" | "status"> & { user?: AdminManagedUser }): UserWorkRow {
  return {
    activeKeyCount: 0,
    disabledKeyCount: 0,
    displayName: input.displayName,
    failedRequestCount: 0,
    keys: [],
    logs: [],
    projectId: input.projectId,
    requestCount: 0,
    source: input.source,
    status: safeStatusValue(input.status),
    totalCostByCurrency: new Map(),
    user: input.user,
  };
}

function adminUsersFallbackMessage(error: unknown): string {
  const status = typeof error === "object" && error !== null && "status" in error ? (error as ApiClientError).status : undefined;

  if (status === 404 || status === 501) {
    return "用户目录 API 尚未开放；当前使用 wallet/key/request/ledger 聚合成安全的项目用户视图。";
  }

  return `用户目录暂不可用；已降级为项目用户视图。${errorMessage(error)}`;
}

function userDisplayName(user: AdminManagedUser): string {
  const name = safeDisplayText(user.display_name);
  if (name !== "-") {
    return name;
  }

  const email = maskedEmail(user.email);
  if (email !== "-") {
    return email;
  }

  return `User ${safeShortId(user.id)}`;
}

function maskedEmail(value: string | null | undefined): string {
  const raw = value?.trim();
  if (!raw || !raw.includes("@")) {
    return "-";
  }
  const [local, domain] = raw.split("@");
  return `${local.slice(0, 2)}***@${domain}`;
}

function rowMatchesSearch(row: UserWorkRow, search: string): boolean {
  return [
    row.displayName,
    row.projectId,
    row.user?.id,
    row.user?.email ? maskedEmail(row.user.email) : "",
    row.keys.map((key) => `${key.name} ${key.key_prefix}`).join(" "),
  ].some((value) => value?.toLowerCase().includes(search));
}

function walletBalanceLabel(wallet: AdminWalletCreditSurface | undefined): string {
  if (!wallet) {
    return "-";
  }
  return formatMoney(wallet.credit_grants.active_remaining_total, wallet.wallet.currency);
}

function walletLedgerDetail(wallet: AdminWalletCreditSurface | undefined): string {
  if (!wallet) {
    return "wallet unavailable";
  }
  return `${wallet.ledger_balance_window.ledger_entry_count} ledger / pending ${wallet.pending_reserves.reserve_count}`;
}

function ledgerRowLabel(wallet: AdminWalletCreditSurface | undefined): string {
  if (!wallet) {
    return "-";
  }
  return `${wallet.ledger_balance_window.ledger_entry_count} entries / ${formatMoney(wallet.ledger_balance_window.confirmed_net_amount, wallet.wallet.currency)}`;
}

function balanceTone(wallet: AdminWalletCreditSurface | undefined): "good" | "neutral" | "warn" {
  if (!wallet) {
    return "warn";
  }
  const remaining = Number(wallet.credit_grants.active_remaining_total);
  return Number.isFinite(remaining) && remaining > 0 ? "good" : "warn";
}

function statusTone(status: string): "good" | "neutral" | "warn" {
  const normalized = safeStatusValue(status);
  if (normalized === "active" || normalized === "enabled" || normalized === "succeeded" || normalized === "success" || normalized === "confirmed" || normalized === "normal" || normalized === "tenant-scoped" || normalized === "ready" || normalized === "minimal-readback") {
    return "good";
  }
  if (normalized === "disabled" || normalized === "manual_disabled" || normalized === "pending") {
    return "warn";
  }
  if (normalized === "deleted" || normalized === "failed" || normalized === "rejected" || normalized === "expired") {
    return "warn";
  }
  return "neutral";
}

function readbackTone(status: string): "good" | "neutral" | "warn" {
  const normalized = safeStatusValue(status);
  if (normalized === "ready" || normalized === "active") {
    return "good";
  }
  if (normalized === "no-project-membership" || normalized === "config-needed") {
    return "warn";
  }
  return "neutral";
}

function metricTone(status: string): "good" | "neutral" | "warn" {
  return statusTone(status);
}

function safeKeyLabel(key: VirtualKey): string {
  return `${safeDisplayText(key.name)} / ${safeDisplayText(key.key_prefix)}`;
}

function keyFromRestoreResult(key: VirtualKey, result: RestoreVirtualKeyResponse): VirtualKey {
  return {
    ...key,
    key_prefix: result.key_prefix ?? key.key_prefix,
    status: result.status ?? key.status,
    secret: undefined,
    secret_once: false,
    secret_redacted: true,
  };
}

function restoreKeyNotice(result: RestoreVirtualKeyResponse): string {
  const parts = [
    `API key ${safeShortId(result.key_id)} / ${safeDisplayText(result.key_prefix)}：${statusLabel(result.action_result)}`,
    `status ${statusLabel(result.status ?? "unknown")}`,
    `audit ${safeShortId(result.audit_log_id)}`,
  ];
  if (result.safety_reason) {
    parts.push(safeDisplayText(result.safety_reason));
  }
  return `${parts.join("；")}。`;
}

function applyBulkUserStatuses(users: AdminManagedUser[], result: AdminManagedUserBulkStatusResponse): AdminManagedUser[] {
  const updates = new Map(
    result.results
      .filter((row) => !row.error && row.user_id)
      .map((row) => [row.user_id, row]),
  );

  return users.map((user) => {
    const update = updates.get(user.id);
    if (!update) {
      return user;
    }
    return {
      ...user,
      primary_project_id: update.primary_project_id ?? user.primary_project_id,
      project_ids: update.project_ids ?? user.project_ids,
      status: update.status,
    };
  });
}

function bulkUserStatusNotice(result: AdminManagedUserBulkStatusResponse): string {
  return `批量用户操作 ${safeShortId(result.operation_id)} 完成：${result.affected_count} 成功，${result.failed_count} 失败，audit refs ${result.audit_log_ids.length}；project rollup fallback write_allowed=false。`;
}

function userStatusNotice(result: AdminManagedUserStatusActionResult): string {
  const readback = result.readback;
  const parts = [
    `用户 ${safeShortId(result.user_id)} 已更新为 ${statusLabel(result.status)}`,
    `结果 ${statusLabel(result.action_result)}`,
    `audit ${safeShortId(result.audit_log_id)}`,
  ];

  if (readback) {
    parts.push(
      readback.status_matches_target && readback.audit_log_readback
        ? "readback 已确认 users/audit"
        : "readback 需要复查",
    );
    if (readback.project_rollup_fallback.supported) {
      parts.push("project rollup fallback 只读");
    }
  }

  return `${parts.join("；")}。`;
}

function rowKey(row: UserWorkRow): string {
  return row.projectId ?? row.user?.id ?? row.displayName;
}

function optionalString(value: string): string | undefined {
  const trimmed = value.trim();
  return trimmed ? trimmed : undefined;
}

function optionalPositiveInteger(value: string): number | undefined {
  const trimmed = value.trim();
  if (!trimmed) {
    return undefined;
  }
  const parsed = Number(trimmed);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : undefined;
}

function newestDate(current: string | null | undefined, next: string | null | undefined): string | null | undefined {
  if (!current) {
    return next;
  }
  if (!next) {
    return current;
  }
  return next.localeCompare(current) > 0 ? next : current;
}

function addCurrencyAmount(values: Map<string, number>, currency: string | null | undefined, amount: string | number | null | undefined) {
  const key = safeDisplayText(currency);
  const parsed = Number(amount);
  if (key === "-" || !Number.isFinite(parsed)) {
    return;
  }
  values.set(key, (values.get(key) ?? 0) + parsed);
}

function formatMoneySummary(values: Map<string, number>): string {
  const parts = Array.from(values.entries()).map(([currency, amount]) => formatMoney(amount.toFixed(8), currency));
  return parts.length > 0 ? parts.join(", ") : "no cost";
}

function summarizeIds(values: string[] | null | undefined): string {
  if (!values?.length) {
    return "-";
  }
  return values.slice(0, 4).map((value) => safeShortId(value)).join(", ") + (values.length > 4 ? ` +${values.length - 4}` : "");
}

function summarizeList(values: string[] | null | undefined): string {
  if (!values?.length) {
    return "-";
  }
  return values.slice(0, 6).map((value) => safeDisplayText(value)).join(", ") + (values.length > 6 ? ` +${values.length - 6}` : "");
}

function ledgerUsageLabel(entry: LedgerEntry): string {
  if (typeof entry.usage_snapshot === "object" && entry.usage_snapshot !== null && !Array.isArray(entry.usage_snapshot)) {
    const inputTokens = entry.usage_snapshot.input_tokens;
    const outputTokens = entry.usage_snapshot.output_tokens;
    return formatTokenUsage(
      typeof inputTokens === "number" ? inputTokens : null,
      typeof outputTokens === "number" ? outputTokens : null,
    );
  }

  return "-";
}
