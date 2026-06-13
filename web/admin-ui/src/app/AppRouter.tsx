import { lazy, Suspense, useEffect, useMemo, useState, type ReactNode } from "react";

import {
  clearAdminSessionToken,
  getProviderHealthSummary,
  type HealthSummary,
  logoutAdmin,
  type ProbeResult,
  probeServices,
  requestProviderKeyRecovery,
} from "../api/client";
import { errorMessage } from "../components/adminUtils";
import { Activity, Database, FileInput, Key, Network, ScrollText, ShieldCheck } from "../components/icons";
import type { AdminSession } from "../components/LoginPanel";
import type { NavItem } from "../components/Navigation";
import { HealthDashboard } from "../features/dashboard/HealthDashboard";
import { AdminShell } from "../layouts/AdminShell";
import { CommandPalette } from "./CommandPalette";
import {
  capabilityAccessFromSession,
  hasSessionCapability,
  isAdminCapability,
  preferredAdminViewForCapabilities,
  type AdminCapability,
} from "./permissions";
import type {
  ApiKeysFocusTarget,
  AppView,
  AuditLogsFocusTarget,
  DashboardTarget,
  DistributionTarget,
  RequestLogsFocusTarget,
  UsersFocusTarget,
} from "./types";

const BillingPage = lazy(() => import("../features/billing/BillingPage"));
const AuditLogsPage = lazy(() =>
  import("../features/audit/AuditLogsPage").catch(() => ({ default: AuditLogsConfigNeeded })),
);
const DistributionReadinessPage = lazy(() => import("../features/distribution/DistributionReadinessPage"));
const ImportWizardPage = lazy(() => import("../components/ImportWizardPage"));
const ModelsPage = lazy(() => import("../features/models/ModelsPage"));
const ProviderKeysPage = lazy(() =>
  import("../features/providers/ProviderKeysPage").then((module) => ({ default: module.ProviderKeysPage })),
);
const ProvidersPage = lazy(() =>
  import("../features/providers/ProvidersPage").then((module) => ({ default: module.ProvidersPage })),
);
const RequestLogsPage = lazy(() =>
  import("../features/requests/RequestLogsPage").then((module) => ({ default: module.RequestLogsPage })),
);
const RoutingPage = lazy(() => import("../features/routing/RoutingPage"));
const NetworkSecuritySettingsPage = lazy(() => import("../features/settings/NetworkSecuritySettingsPage"));
const UsersPage = lazy(() => import("../features/users/UsersPage"));
const VirtualKeysPage = lazy(() => import("../features/api-keys/VirtualKeysPage"));

type AppRouterProps = {
  session: AdminSession;
  onAdminSessionCleared: () => void;
  onOpenUserPortal: () => void;
};

const navItems: NavItem<AppView>[] = [
  { id: "overview", label: "仪表盘", icon: Activity, permission: "运营", capabilities: ["provider_health.read"] },
  {
    id: "distribution",
    label: "分发就绪",
    icon: ShieldCheck,
    permission: "就绪检查",
    capabilities: ["provider_health.read", "key.read", "request_log.read"],
  },
  { id: "providers", label: "供应商与通道", icon: Network, permission: "供应商", capabilities: ["provider.read"] },
  { id: "models", label: "模型", icon: Database, permission: "模型", capabilities: ["provider.manage"] },
  { id: "routing", label: "路由", icon: Network, permission: "路由", capabilities: ["provider.manage"] },
  { id: "providerKeys", label: "供应商密钥", icon: Key, permission: "凭据", capabilities: ["key.manage"] },
  { id: "keys", label: "API 密钥", icon: Key, permission: "密钥", capabilities: ["key.manage"] },
  { id: "settings", label: "设置", icon: ShieldCheck, permission: "设置", capabilities: ["key.manage"] },
  {
    id: "requestLogs",
    label: "请求与追踪",
    icon: ScrollText,
    permission: "审计",
    capabilities: ["request_log.read", "trace.read"],
  },
  {
    id: "users",
    label: "用户",
    icon: Key,
    permission: "用户",
    capabilities: ["key.read", "request_log.read", "billing.read"],
  },
  {
    id: "billing",
    label: "计费",
    icon: Database,
    permission: "计费",
    capabilities: ["billing.read", "price.read", "reconciliation.read"],
  },
  {
    id: "importWizard",
    label: "导入向导",
    icon: FileInput,
    permission: "导入",
    capabilities: ["provider.read", "key.read"],
  },
  {
    id: "auditLogs",
    label: "审计日志",
    icon: ShieldCheck,
    permission: "审计",
    capabilities: ["audit.read"],
  },
];

const viewTitles: Record<AppView, string> = {
  overview: "仪表盘",
  distribution: "API 分发",
  importWizard: "导入向导",
  requestLogs: "请求与追踪",
  auditLogs: "审计日志",
  billing: "计费 / 价格",
  users: "用户",
  providerKeys: "供应商密钥",
  providers: "供应商与通道",
  models: "模型",
  routing: "路由",
  settings: "设置",
  keys: "API 密钥",
};

export function AppRouter({ session, onAdminSessionCleared, onOpenUserPortal }: AppRouterProps) {
  const capabilityAccess = useMemo(() => capabilityAccessFromSession(session), [session]);
  const visibleNavItems = useMemo(
    () =>
      navItems.filter((item) =>
        item.capabilities.some((capability) => isAdminCapability(capability) && capabilityAccess.has(capability)),
      ),
    [capabilityAccess],
  );
  const visibleViews = useMemo(() => new Set(visibleNavItems.map((item) => item.id)), [visibleNavItems]);
  const defaultView = preferredAdminViewForCapabilities(capabilityAccess, visibleViews);
  const [activeView, setActiveView] = useState<AppView>(() => defaultView ?? "overview");
  const [apiKeysFocus, setApiKeysFocus] = useState<ApiKeysFocusTarget | null>(null);
  const [billingInitialTab, setBillingInitialTab] = useState<"wallets" | null>(null);
  const [commandPaletteOpen, setCommandPaletteOpen] = useState(false);
  const [createProviderRequestId, setCreateProviderRequestId] = useState(0);
  const [auditLogsFocus, setAuditLogsFocus] = useState<AuditLogsFocusTarget | null>(null);
  const [requestLogsFocus, setRequestLogsFocus] = useState<RequestLogsFocusTarget | null>(null);
  const [usersFocus, setUsersFocus] = useState<UsersFocusTarget | null>(null);
  const [results, setResults] = useState<ProbeResult[]>([]);
  const [healthSummary, setHealthSummary] = useState<HealthSummary | null>(null);
  const [healthSummaryError, setHealthSummaryError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [lastChecked, setLastChecked] = useState<string | null>(null);
  const [recoveryRequests, setRecoveryRequests] = useState<Record<string, "pending" | "succeeded" | "failed">>({});
  const [recoveryErrors, setRecoveryErrors] = useState<Record<string, string>>({});

  async function refresh() {
    setLoading(true);
    try {
      const [probeResult, summaryResult] = await Promise.allSettled([probeServices(), getProviderHealthSummary()]);

      if (probeResult.status === "fulfilled") {
        setResults(probeResult.value);
      } else {
        setResults([]);
      }

      if (summaryResult.status === "fulfilled") {
        setHealthSummary(summaryResult.value);
        setHealthSummaryError(null);
      } else {
        setHealthSummary(null);
        setHealthSummaryError(errorMessage(summaryResult.reason));
      }

      setLastChecked(
        new Date().toLocaleTimeString([], {
          hour: "2-digit",
          minute: "2-digit",
        }),
      );
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    if (!session || !hasSessionCapability(session, "provider_health.read")) {
      return;
    }

    void refresh();
  }, [session]);

  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        setCommandPaletteOpen(true);
      }
    }

    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, []);

  async function requestRecovery(providerKeyId: string) {
    setRecoveryRequests((current) => ({ ...current, [providerKeyId]: "pending" }));
    setRecoveryErrors((current) => {
      const next = { ...current };
      delete next[providerKeyId];
      return next;
    });

    try {
      await requestProviderKeyRecovery(providerKeyId, {
        reason: "overview manual recovery request",
        target_status: "recovery_probe",
      });
      setRecoveryRequests((current) => ({ ...current, [providerKeyId]: "succeeded" }));
      void refresh();
    } catch (error) {
      setRecoveryRequests((current) => ({ ...current, [providerKeyId]: "failed" }));
      setRecoveryErrors((current) => ({ ...current, [providerKeyId]: errorMessage(error) }));
    }
  }

  function resetRouterState() {
    setActiveView("overview");
    setHealthSummary(null);
    setHealthSummaryError(null);
    setLastChecked(null);
    setRecoveryErrors({});
    setRecoveryRequests({});
    setResults([]);
  }

  async function signOut() {
    try {
      await logoutAdmin();
    } finally {
      clearAdminSessionToken();
      resetRouterState();
      onAdminSessionCleared();
    }
  }

  async function openUserPortalFromAdmin() {
    try {
      await logoutAdmin();
    } finally {
      clearAdminSessionToken();
      resetRouterState();
      onOpenUserPortal();
    }
  }

  const selectedNavItem = visibleNavItems.find((item) => item.id === activeView);
  const activeNavItem = selectedNavItem ?? visibleNavItems.find((item) => item.id === defaultView);
  const selectedView = activeNavItem?.id;

  function selectView(view: AppView) {
    if (visibleViews.has(view)) {
      setActiveView(view);
    } else if (defaultView) {
      setActiveView(defaultView);
    }
  }

  useEffect(() => {
    if (activeView && visibleViews.has(activeView)) {
      return;
    }
    if (defaultView) {
      setActiveView(defaultView);
    }
  }, [activeView, defaultView, visibleViews]);

  return (
    <AdminShell
      activePermission={activeNavItem?.permission ?? "受限"}
      activeTitle={activeNavItem ? viewTitles[activeNavItem.id] : "没有可用管理工作区"}
      activeView={selectedView ?? activeView}
      items={visibleNavItems}
      session={session}
      commandPalette={
        <CommandPalette
          items={visibleNavItems}
          open={commandPaletteOpen}
          onClose={() => setCommandPaletteOpen(false)}
          onCreateProvider={() => {
            setCreateProviderRequestId((current) => current + 1);
            selectView("providers");
          }}
          onOpenBillingWallet={() => {
            setBillingInitialTab("wallets");
            selectView("billing");
          }}
          onNavigate={selectView}
          onOpenApiKey={(target) => {
            setApiKeysFocus(target);
            selectView("keys");
          }}
          onOpenRequest={(requestId) => {
            setRequestLogsFocus({ requestId });
            selectView("requestLogs");
          }}
          onOpenRequestLogs={() => {
            setRequestLogsFocus(null);
            selectView("requestLogs");
          }}
          onOpenUser={(target) => {
            setUsersFocus(target);
            selectView("users");
          }}
          onOpenUserPortal={() => void openUserPortalFromAdmin()}
        />
      }
      onLogout={() => void signOut()}
      onOpenCommandPalette={() => setCommandPaletteOpen(true)}
      onSelect={selectView}
    >
      <AppRouteContent
        activeView={selectedView}
        capabilityAccess={capabilityAccess}
        healthSummary={healthSummary}
        healthSummaryError={healthSummaryError}
        lastChecked={lastChecked}
        loading={loading}
        recoveryErrors={recoveryErrors}
        recoveryRequests={recoveryRequests}
        auditLogsFocus={auditLogsFocus}
        requestLogsFocus={requestLogsFocus}
        results={results}
        session={session}
        apiKeysFocus={apiKeysFocus}
        billingInitialTab={billingInitialTab}
        createProviderRequestId={createProviderRequestId}
        usersFocus={usersFocus}
        onBillingRequestDetail={(requestId) => {
          setRequestLogsFocus({ requestId });
          selectView("requestLogs");
        }}
        onBillingTraceDetail={(traceId) => {
          setRequestLogsFocus({ traceId });
          selectView("requestLogs");
        }}
        onBillingAuditLog={(target) => {
          setAuditLogsFocus(target);
          selectView("auditLogs");
        }}
        onBillingUser={(target) => {
          setUsersFocus(target);
          selectView("users");
        }}
        onClearApiKeysFocus={() => setApiKeysFocus(null)}
        onAuditApiKeyFocus={(target) => {
          setApiKeysFocus(target);
          selectView("keys");
        }}
        onAuditUserFocus={(target) => {
          setUsersFocus(target);
          selectView("users");
        }}
        onDashboardNavigate={selectView}
        onDistributionNavigate={selectView}
        onOpenUserPortal={() => void openUserPortalFromAdmin()}
        onRecoveryRequest={(providerKeyId) => void requestRecovery(providerKeyId)}
        onRefresh={refresh}
      />
    </AdminShell>
  );
}

type AppRouteContentProps = {
  activeView: AppView | undefined;
  apiKeysFocus: ApiKeysFocusTarget | null;
  auditLogsFocus: AuditLogsFocusTarget | null;
  billingInitialTab: "wallets" | null;
  capabilityAccess: Set<AdminCapability>;
  createProviderRequestId: number;
  healthSummary: HealthSummary | null;
  healthSummaryError: string | null;
  lastChecked: string | null;
  loading: boolean;
  recoveryErrors: Record<string, string>;
  recoveryRequests: Record<string, "pending" | "succeeded" | "failed">;
  requestLogsFocus: RequestLogsFocusTarget | null;
  results: ProbeResult[];
  session: AdminSession;
  usersFocus: UsersFocusTarget | null;
  onAuditApiKeyFocus: (target: ApiKeysFocusTarget) => void;
  onAuditUserFocus: (target: UsersFocusTarget) => void;
  onBillingAuditLog: (target: AuditLogsFocusTarget) => void;
  onBillingRequestDetail: (requestId: string) => void;
  onBillingTraceDetail: (traceId: string) => void;
  onBillingUser: (target: UsersFocusTarget) => void;
  onClearApiKeysFocus: () => void;
  onDashboardNavigate: (target: DashboardTarget) => void;
  onDistributionNavigate: (target: DistributionTarget) => void;
  onOpenUserPortal: () => void;
  onRecoveryRequest: (providerKeyId: string) => void;
  onRefresh: () => Promise<void>;
};

function AppRouteContent({
  activeView,
  apiKeysFocus,
  auditLogsFocus,
  billingInitialTab,
  capabilityAccess,
  createProviderRequestId,
  healthSummary,
  healthSummaryError,
  lastChecked,
  loading,
  recoveryErrors,
  recoveryRequests,
  requestLogsFocus,
  results,
  session,
  usersFocus,
  onAuditApiKeyFocus,
  onAuditUserFocus,
  onBillingAuditLog,
  onBillingRequestDetail,
  onBillingTraceDetail,
  onBillingUser,
  onClearApiKeysFocus,
  onDashboardNavigate,
  onDistributionNavigate,
  onOpenUserPortal,
  onRecoveryRequest,
  onRefresh,
}: AppRouteContentProps) {
  if (!activeView) {
    return (
      <section className="admin-panel" aria-label="没有可用管理区域">
        <h2>没有可用区域</h2>
        <p className="muted-copy">当前管理员权限没有包含任何控制台区域。</p>
      </section>
    );
  }

  if (activeView === "overview") {
    return (
      <HealthDashboard
        canRequestRecovery={hasSessionCapability(session, "provider_key.recovery")}
        lastChecked={lastChecked}
        healthSummary={healthSummary}
        healthSummaryError={healthSummaryError}
        loading={loading || (results.length === 0 && lastChecked === null)}
        recoveryErrors={recoveryErrors}
        recoveryRequests={recoveryRequests}
        results={results}
        onOpenRequestDetail={onBillingRequestDetail}
        onRecoveryRequest={onRecoveryRequest}
        onRefresh={onRefresh}
        onSetupNavigate={onDashboardNavigate}
      />
    );
  }

  if (activeView === "distribution") {
    return (
      <RouteSuspense fallbackText="正在加载分发就绪状态。">
        <DistributionReadinessPage
          onNavigate={onDistributionNavigate}
          onOpenRequestDetail={(requestId) => {
            onBillingRequestDetail(requestId);
          }}
          onOpenUserPortal={onOpenUserPortal}
        />
      </RouteSuspense>
    );
  }

  if (activeView === "importWizard") {
    return (
      <RouteSuspense fallbackText="正在加载导入向导。">
        <ImportWizardPage />
      </RouteSuspense>
    );
  }

  if (activeView === "requestLogs") {
    return (
      <RouteSuspense fallbackText="正在加载请求与追踪。">
        <RequestLogsPage focusTarget={requestLogsFocus} />
      </RouteSuspense>
    );
  }

  if (activeView === "auditLogs") {
    return (
      <RouteSuspense fallbackText="正在加载审计日志。">
        <AuditLogsPage
          focusTarget={auditLogsFocus}
          onOpenApiKey={onAuditApiKeyFocus}
          onOpenRequestDetail={onBillingRequestDetail}
          onOpenUser={onAuditUserFocus}
        />
      </RouteSuspense>
    );
  }

  if (activeView === "billing") {
    return (
      <RouteSuspense fallbackText="正在加载计费。">
        <BillingPage
          initialTab={billingInitialTab ?? undefined}
          onOpenRequestDetail={onBillingRequestDetail}
        />
      </RouteSuspense>
    );
  }

  if (activeView === "providerKeys") {
    return (
      <RouteSuspense fallbackText="正在加载供应商密钥。">
        <ProviderKeysPage />
      </RouteSuspense>
    );
  }

  if (activeView === "providers") {
    return (
      <RouteSuspense fallbackText="正在加载供应商。">
        <ProvidersPage
          canManageProviders={capabilityAccess.has("provider.manage")}
          canRequestProviderKeyRecovery={capabilityAccess.has("provider_key.recovery")}
          canRunManualTest={capabilityAccess.has("manual_test.run")}
          createProviderRequestId={createProviderRequestId}
        />
      </RouteSuspense>
    );
  }

  if (activeView === "models") {
    return (
      <RouteSuspense fallbackText="正在加载模型。">
        <ModelsPage />
      </RouteSuspense>
    );
  }

  if (activeView === "routing") {
    return (
      <RouteSuspense fallbackText="正在加载路由。">
        <RoutingPage onOpenKeys={() => onDistributionNavigate("keys")} onOpenModels={() => onDistributionNavigate("models")} />
      </RouteSuspense>
    );
  }

  if (activeView === "settings") {
    return (
      <RouteSuspense fallbackText="正在加载设置。">
        <NetworkSecuritySettingsPage />
      </RouteSuspense>
    );
  }

  if (activeView === "users") {
    return (
      <RouteSuspense fallbackText="正在加载用户管理。">
        <UsersPage
          focusTarget={usersFocus}
          onOpenKeys={() => onDistributionNavigate("keys")}
          onOpenRequestDetail={onBillingRequestDetail}
          onOpenRequests={() => onDistributionNavigate("requestLogs")}
        />
      </RouteSuspense>
    );
  }

  return (
    <RouteSuspense fallbackText="正在加载 API 密钥。">
      <VirtualKeysPage focusTarget={apiKeysFocus} onClearFocus={onClearApiKeysFocus} />
    </RouteSuspense>
  );
}

function RouteSuspense({ children, fallbackText }: { children: ReactNode; fallbackText: string }) {
  return (
    <Suspense
      fallback={
        <section className="admin-panel">
          <p className="muted-copy">{fallbackText}</p>
        </section>
      }
    >
      {children}
    </Suspense>
  );
}

function AuditLogsConfigNeeded() {
  return (
    <section className="admin-panel" aria-label="审计日志未就绪">
      <h2>审计日志</h2>
      <p className="muted-copy">
        config-needed：Audit logs 页面还未加载或仍在并行实现中。Dashboard 已保留安全 view target，不会传递 secret、raw payload 或 prompt。
      </p>
    </section>
  );
}
