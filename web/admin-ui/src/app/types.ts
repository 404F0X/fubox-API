export type AppView =
  | "overview"
  | "distribution"
  | "importWizard"
  | "requestLogs"
  | "auditLogs"
  | "billing"
  | "users"
  | "providerKeys"
  | "providers"
  | "models"
  | "routing"
  | "settings"
  | "keys";

export type DistributionTarget =
  | "providers"
  | "providerKeys"
  | "models"
  | "routing"
  | "settings"
  | "keys"
  | "requestLogs"
  | "billing";

export type DashboardTarget = DistributionTarget | "users" | "auditLogs";

export type UsersFocusTarget = {
  projectId?: string | null;
  status?: string | null;
  userId?: string | null;
};

export type RequestLogsFocusTarget = {
  requestId?: string | null;
  traceId?: string | null;
};

export type AuditLogsFocusTarget = {
  auditLogId?: string | null;
  requestId?: string | null;
  resourceId?: string | null;
  resourceType?: string | null;
};

export type ApiKeysFocusTarget = {
  keyId?: string | null;
  keyPrefix?: string | null;
  projectId?: string | null;
  status?: string | null;
};
