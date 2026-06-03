import { lazy, Suspense, useEffect, useState } from "react";
import {
  getProviderHealthSummary,
  type HealthSummary,
  logoutAdmin,
  type ProbeResult,
  probeServices,
  requestProviderKeyRecovery,
} from "./api/client";
import { HealthDashboard } from "./components/HealthDashboard";
import { Activity, Database, Key, Network, ScrollText, ShieldCheck } from "./components/icons";
import { type AdminSession, LoginPanel } from "./components/LoginPanel";
import { Navigation, type NavItem } from "./components/Navigation";
import { ProviderKeysPage } from "./components/ProviderKeysPage";
import { ProvidersPage } from "./components/ProvidersPage";

type AppView =
  | "overview"
  | "requestLogs"
  | "auditLogs"
  | "billing"
  | "providerKeys"
  | "providers"
  | "models"
  | "routing"
  | "keys";
type AdminCapability =
  | "provider.read"
  | "provider.manage"
  | "key.read"
  | "key.manage"
  | "provider_key.recovery"
  | "request_log.read"
  | "trace.read"
  | "audit.read"
  | "billing.read"
  | "price.read"
  | "reconciliation.read"
  | "price_version.create"
  | "manual_test.run"
  | "provider_health.read"
  | "alert_webhook.validate"
  | "health.liveness"
  | "health.readiness";

const BillingPage = lazy(() => import("./components/BillingPage"));
const AuditLogsPage = lazy(() => import("./components/AuditLogsPage"));
const ModelsPage = lazy(() => import("./components/ModelsPage"));
const RequestLogsPage = lazy(() =>
  import("./components/RequestLogsPage").then((module) => ({ default: module.RequestLogsPage })),
);
const RoutingPage = lazy(() => import("./components/RoutingPage"));
const VirtualKeysPage = lazy(() => import("./components/VirtualKeysPage"));

const navItems: NavItem<AppView>[] = [
  { id: "overview", label: "Overview", icon: Activity, permission: "Operations", capabilities: ["provider_health.read"] },
  {
    id: "requestLogs",
    label: "Request/Trace",
    icon: ScrollText,
    permission: "Audit",
    capabilities: ["request_log.read", "trace.read"],
  },
  {
    id: "auditLogs",
    label: "Audit Logs",
    icon: ShieldCheck,
    permission: "Audit",
    capabilities: ["audit.read"],
  },
  {
    id: "billing",
    label: "Billing",
    icon: Database,
    permission: "Billing",
    capabilities: ["billing.read", "price.read", "reconciliation.read"],
  },
  { id: "providerKeys", label: "Provider Keys", icon: Key, permission: "Credentials", capabilities: ["key.manage"] },
  { id: "providers", label: "Providers", icon: Network, permission: "Providers", capabilities: ["provider.read"] },
  { id: "models", label: "Models", icon: Database, permission: "Models", capabilities: ["provider.manage"] },
  { id: "routing", label: "Routing", icon: Network, permission: "Routing", capabilities: ["provider.manage"] },
  { id: "keys", label: "Virtual Keys", icon: Key, permission: "Keys", capabilities: ["key.manage"] },
];

export function App() {
  const [session, setSession] = useState<AdminSession | null>(null);
  const [activeView, setActiveView] = useState<AppView>("overview");
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
        setHealthSummaryError(errorText(summaryResult.reason));
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
      setRecoveryErrors((current) => ({ ...current, [providerKeyId]: errorText(error) }));
    }
  }

  async function signOut() {
    try {
      await logoutAdmin();
    } finally {
      setSession(null);
      setActiveView("overview");
    }
  }

  if (!session) {
    return <LoginPanel onLogin={setSession} />;
  }

  const capabilityAccess = capabilityAccessFromSession(session);
  const visibleNavItems = navItems.filter((item) =>
    item.capabilities.some((capability) => isAdminCapability(capability) && capabilityAccess.has(capability)),
  );
  const selectedNavItem = visibleNavItems.find((item) => item.id === activeView);
  const activeNavItem = selectedNavItem ?? visibleNavItems[0];
  const selectedView = activeNavItem?.id;
  const activeTitle =
    selectedView === "overview"
      ? "Gateway Control"
      : selectedView === "requestLogs"
        ? "Request/Trace"
        : selectedView === "auditLogs"
          ? "Audit Logs"
          : selectedView === "billing"
            ? "Billing / Prices"
            : selectedView === "providerKeys"
              ? "Provider Keys"
              : selectedView === "providers"
                ? "Providers"
                : selectedView === "models"
                  ? "Models"
                  : selectedView === "routing"
                    ? "Routing"
                    : "Virtual Keys";

  return (
    <main className="shell">
      <Navigation
        activeView={selectedView ?? activeView}
        items={visibleNavItems}
        session={session}
        onLogout={() => void signOut()}
        onSelect={setActiveView}
      />

      <section className="workspace">
        <header className="topbar">
          <div>
            <p className="eyebrow">{activeNavItem?.permission ?? "Scoped"} workspace</p>
            <h1>{activeNavItem ? activeTitle : "No Admin Workspace"}</h1>
          </div>
        </header>

        {!activeNavItem ? (
          <section className="admin-panel" aria-label="No available admin sections">
            <h2>No available sections</h2>
            <p className="muted-copy">Your current admin access does not include any console sections.</p>
          </section>
        ) : selectedView === "overview" ? (
          <HealthDashboard
            lastChecked={lastChecked}
            healthSummary={healthSummary}
            healthSummaryError={healthSummaryError}
            loading={loading || (results.length === 0 && lastChecked === null)}
            recoveryErrors={recoveryErrors}
            recoveryRequests={recoveryRequests}
            results={results}
            onRecoveryRequest={(providerKeyId) => void requestRecovery(providerKeyId)}
            onRefresh={refresh}
          />
        ) : selectedView === "requestLogs" ? (
          <Suspense
            fallback={
              <section className="admin-panel">
                <p className="muted-copy">Loading request/trace.</p>
              </section>
            }
          >
            <RequestLogsPage />
          </Suspense>
        ) : selectedView === "auditLogs" ? (
          <Suspense
            fallback={
              <section className="admin-panel">
                <p className="muted-copy">Loading audit logs.</p>
              </section>
            }
          >
            <AuditLogsPage />
          </Suspense>
        ) : selectedView === "billing" ? (
          <Suspense
            fallback={
              <section className="admin-panel">
                <p className="muted-copy">Loading billing.</p>
              </section>
            }
          >
            <BillingPage />
          </Suspense>
        ) : selectedView === "providerKeys" ? (
          <ProviderKeysPage />
        ) : selectedView === "providers" ? (
          <ProvidersPage
            canManageProviders={capabilityAccess.has("provider.manage")}
            canRunManualTest={capabilityAccess.has("manual_test.run")}
          />
        ) : selectedView === "models" ? (
          <Suspense
            fallback={
              <section className="admin-panel">
                <p className="muted-copy">Loading models.</p>
              </section>
            }
          >
            <ModelsPage />
          </Suspense>
        ) : selectedView === "routing" ? (
          <Suspense
            fallback={
              <section className="admin-panel">
                <p className="muted-copy">Loading routing.</p>
              </section>
            }
          >
            <RoutingPage />
          </Suspense>
        ) : selectedView === "keys" ? (
          <Suspense
            fallback={
              <section className="admin-panel">
                <p className="muted-copy">Loading virtual keys.</p>
              </section>
            }
          >
            <VirtualKeysPage />
          </Suspense>
        ) : null}
      </section>
    </main>
  );
}

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function capabilityAccessFromSession(session: AdminSession): Set<AdminCapability> {
  const denied = new Set(session.capabilitySummary.denied_capabilities);

  return new Set(
    session.capabilitySummary.capabilities.filter(
      (capability): capability is AdminCapability => isAdminCapability(capability) && !denied.has(capability),
    ),
  );
}

function hasSessionCapability(session: AdminSession, capability: AdminCapability): boolean {
  return capabilityAccessFromSession(session).has(capability);
}

function isAdminCapability(capability: string): capability is AdminCapability {
  return knownCapabilities.has(capability as AdminCapability);
}

const knownCapabilities = new Set<AdminCapability>([
  "provider.read",
  "provider.manage",
  "key.read",
  "key.manage",
  "request_log.read",
  "trace.read",
  "audit.read",
  "billing.read",
  "price.read",
  "reconciliation.read",
  "price_version.create",
  "manual_test.run",
  "provider_health.read",
  "alert_webhook.validate",
  "health.liveness",
  "health.readiness",
]);
