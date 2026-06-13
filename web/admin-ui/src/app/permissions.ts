import type { AdminSession } from "../components/LoginPanel";
import type { AppView } from "./types";

export type AdminCapability =
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

const knownCapabilities = new Set<AdminCapability>([
  "provider.read",
  "provider.manage",
  "key.read",
  "key.manage",
  "provider_key.recovery",
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

export function capabilityAccessFromSession(session: AdminSession): Set<AdminCapability> {
  const denied = new Set(session.capabilitySummary.denied_capabilities);

  return new Set(
    session.capabilitySummary.capabilities.filter(
      (capability): capability is AdminCapability => isAdminCapability(capability) && !denied.has(capability),
    ),
  );
}

export function hasSessionCapability(session: AdminSession, capability: AdminCapability): boolean {
  return capabilityAccessFromSession(session).has(capability);
}

export function isAdminCapability(capability: string): capability is AdminCapability {
  return knownCapabilities.has(capability as AdminCapability);
}

export function preferredAdminViewForCapabilities(
  capabilityAccess: Set<AdminCapability>,
  availableViews: Iterable<AppView>,
): AppView | undefined {
  const available = new Set(availableViews);

  if (available.size === 0) {
    return undefined;
  }

  const preferred = defaultViewPreferences.find(
    (candidate) =>
      available.has(candidate.view) &&
      candidate.capabilities.some((capability) => capabilityAccess.has(capability)),
  );

  return preferred?.view ?? available.values().next().value;
}

const defaultViewPreferences: Array<{
  view: AppView;
  capabilities: AdminCapability[];
}> = [
  {
    view: "overview",
    capabilities: ["provider_health.read"],
  },
  {
    view: "billing",
    capabilities: ["billing.read", "price.read", "reconciliation.read", "price_version.create"],
  },
  {
    view: "providers",
    capabilities: ["provider.read", "provider.manage", "manual_test.run", "provider_key.recovery"],
  },
  {
    view: "requestLogs",
    capabilities: ["request_log.read", "trace.read"],
  },
  {
    view: "providerKeys",
    capabilities: ["key.manage", "provider_key.recovery"],
  },
  {
    view: "keys",
    capabilities: ["key.read", "key.manage"],
  },
  {
    view: "auditLogs",
    capabilities: ["audit.read"],
  },
  {
    view: "importWizard",
    capabilities: ["provider.read", "key.read"],
  },
  {
    view: "settings",
    capabilities: ["key.manage"],
  },
];
