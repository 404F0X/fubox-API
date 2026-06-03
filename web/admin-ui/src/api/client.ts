export type ServiceProbe = {
  name: string;
  url: string;
  kind: "http" | "process" | "datastore";
};

export type ProbeResult = {
  name: string;
  status: "online" | "offline" | "pending";
  detail: string;
};

export type HealthSummaryRecentLastError = {
  code?: string | null;
  http_status?: number | null;
  observed_at: string;
  owner?: string | null;
  status: string;
};

export type HealthSummaryRecentStats = {
  error_count: number;
  last_error?: HealthSummaryRecentLastError | null;
  request_count: number;
  success_count?: number;
  success_rate?: number | null;
};

export type HealthSummaryEntityBase = {
  health_score?: number | null;
  health_state: "healthy" | "degraded" | "unhealthy" | "no_signal" | string;
  id: string;
  recent: HealthSummaryRecentStats;
  status: string;
};

export type HealthSummaryProvider = HealthSummaryEntityBase & {
  channel_count: number;
  code: string;
  enabled_channel_count: number;
  enabled_provider_key_count: number;
  name: string;
  provider_key_count: number;
};

export type HealthSummaryChannel = HealthSummaryEntityBase & {
  enabled_provider_key_count: number;
  model_count: number;
  name: string;
  priority: number;
  protocol_mode: string;
  provider_id: string;
  provider_key_count: number;
  region?: string | null;
  weight: number;
};

export type HealthSummaryProviderKey = HealthSummaryEntityBase & {
  channel_id: string;
  configured_last_error_code?: string | null;
  cooldown_until?: string | null;
  credential_configured: boolean;
  key_alias: string;
  limits: {
    concurrency?: number | null;
    rpm?: number | null;
    tpm?: number | null;
  };
};

export type HealthSummaryModel = {
  association_count: number;
  display_name: string;
  enabled_association_count: number;
  family?: string | null;
  id: string;
  model_key: string;
  recent: HealthSummaryRecentStats;
  routable_channel_count: number;
  routing_state: "routable" | "no_route" | "disabled" | string;
  status: string;
  visibility: string;
};

export type HealthSummary = {
  channels: HealthSummaryChannel[];
  models: HealthSummaryModel[];
  provider_keys: HealthSummaryProviderKey[];
  providers: HealthSummaryProvider[];
  recent_window: {
    error_count?: number;
    sample_count: number;
    sample_limit: number;
    source: string;
    success_count?: number;
    success_rate?: number | null;
    window?: {
      minutes: number;
      unit: "minutes" | string;
    };
    window_minutes?: number;
  };
  status_counts: {
    channels: Record<string, number>;
    models: Record<string, number>;
    provider_keys: Record<string, number>;
    providers: Record<string, number>;
  };
  summary_version: number;
  tenant_id: string;
  totals: {
    channels: number;
    model_associations: number;
    models: number;
    provider_keys: number;
    providers: number;
  };
};

export type HealthSummaryFilters = {
  sample_limit?: number;
  window_minutes?: number;
};

export type ServiceName = "gateway" | "controlPlane" | "mockProvider";

export type ErrorEnvelope = {
  error?: {
    code?: unknown;
    message?: unknown;
    type?: unknown;
    param?: unknown;
  };
  gateway?: {
    error_owner?: unknown;
    error_stage?: unknown;
    retryable?: unknown;
  };
};

export type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue };
export type JsonObject = { [key: string]: JsonValue };

export type JsonRequestOptions = Omit<RequestInit, "body" | "signal"> & {
  baseUrl?: string;
  body?: unknown;
  signal?: AbortSignal;
  timeoutMs?: number;
};

export type RequestLogListFilters = {
  canonical_model_id?: string;
  channel_id?: string;
  limit?: number;
  model?: string;
  resolved_channel_id?: string;
  status?: string;
};

export type ProviderStatus = "enabled" | "disabled" | "deleted" | string;

export type Provider = {
  base_url?: string | null;
  code: string;
  id: string;
  metadata: JsonValue;
  name: string;
  provider_type?: string | null;
  status: ProviderStatus;
  tenant_id: string;
};

export type CreateProviderRequest = {
  base_url?: string;
  code: string;
  metadata?: JsonObject;
  name: string;
  provider_type?: string;
  status?: ProviderStatus;
};

export type PatchProviderRequest = Partial<CreateProviderRequest>;

export type ChannelStatus = "enabled" | "disabled" | "degraded" | "cooldown" | "deleted" | string;

export type Channel = {
  endpoint: string;
  health_score: number;
  id: string;
  model_mappings: JsonValue;
  name: string;
  priority: number;
  probe_policy: JsonValue;
  protocol_mode: string;
  provider_id: string;
  region?: string | null;
  request_overrides: JsonValue;
  status: ChannelStatus;
  tags: JsonValue;
  tenant_id: string;
  timeout_policy: JsonValue;
  weight: number;
};

export type CreateChannelRequest = {
  base_url?: string;
  endpoint?: string;
  health_score?: number;
  model_mappings?: JsonValue;
  name: string;
  priority?: number;
  probe_policy?: JsonValue;
  protocol?: string;
  protocol_mode?: string;
  provider_id: string;
  region?: string;
  request_overrides?: JsonValue;
  status?: ChannelStatus;
  tags?: JsonValue;
  timeout_policy?: JsonValue;
  weight?: number;
};

export type PatchChannelRequest = Partial<CreateChannelRequest>;

export type ChannelManualTestRequest = {
  dry_run?: boolean;
  model: string;
  upstream_model_name?: string;
};

export type ChannelManualTestChannel = {
  endpoint: string;
  health_score: number;
  id: string;
  name: string;
  priority: number;
  protocol_mode: string;
  status: ChannelStatus;
  weight: number;
};

export type ChannelManualTestProvider = {
  code: string;
  id: string;
  name: string;
  status: ProviderStatus;
};

export type ChannelManualTestBilling = {
  billable: false;
  ledger_write: false;
  request_log_write: false;
};

export type ChannelManualTestRequestPlan = {
  method: "POST" | string;
  model: string;
  path: string;
  protocol_mode: string;
};

export type ChannelManualTestResponse = {
  billing: ChannelManualTestBilling;
  channel: ChannelManualTestChannel;
  credential_material: {
    provider_key_secret: "omitted" | string;
    secret_fingerprint: "omitted" | string;
  };
  dry_run: true;
  next_steps: string[];
  provider: ChannelManualTestProvider;
  requested_model: string;
  request_plan: ChannelManualTestRequestPlan;
  test_mode: "channel_manual_test" | string;
  upstream_call: false;
  upstream_model: string;
};

export type CanonicalModelStatus = "active" | "disabled" | "deleted" | string;

export type CanonicalModel = {
  capabilities: JsonValue;
  context_length?: number | null;
  display_name: string;
  family?: string | null;
  id: string;
  max_output_tokens?: number | null;
  model_key: string;
  status: CanonicalModelStatus;
  supports_audio: boolean;
  supports_reasoning: boolean;
  supports_stream: boolean;
  supports_tools: boolean;
  supports_vision: boolean;
  tenant_id: string;
  visibility: string;
};

export type CreateCanonicalModelRequest = {
  capabilities?: JsonObject;
  context_length?: number;
  display_name?: string;
  family?: string;
  max_output_tokens?: number;
  model_key?: string;
  name?: string;
  status?: CanonicalModelStatus;
  supports_audio?: boolean;
  supports_reasoning?: boolean;
  supports_stream?: boolean;
  supports_tools?: boolean;
  supports_vision?: boolean;
  visibility?: string;
};

export type PatchCanonicalModelRequest = Partial<CreateCanonicalModelRequest>;

export type ModelAssociationStatus = "enabled" | "disabled" | "deleted" | string;

export type ModelAssociation = {
  association_type: string;
  canary_percent: number;
  canonical_model_id: string;
  channel_id?: string | null;
  channel_tag?: string | null;
  conditions: JsonValue;
  fallback_allowed: boolean;
  id: string;
  model_pattern?: string | null;
  priority: number;
  status: ModelAssociationStatus;
  tenant_id: string;
  upstream_model_name?: string | null;
};

export type CreateModelAssociationRequest = {
  association_type: string;
  canary_percent?: number;
  canonical_model_id: string;
  channel_id?: string;
  channel_tag?: string;
  conditions?: JsonObject;
  fallback_allowed?: boolean;
  model_pattern?: string;
  priority?: number;
  status?: ModelAssociationStatus;
  upstream_model_name?: string;
};

export type PatchModelAssociationRequest = Partial<CreateModelAssociationRequest>;

export type RequestLogSummary = {
  api_key_profile_id?: string | null;
  canonical_model_id?: string | null;
  client_request_id?: string | null;
  completed_at?: string | null;
  created_at: string;
  currency: string;
  error_code?: string | null;
  error_owner?: string | null;
  final_cost: string;
  http_status?: number | null;
  id: string;
  inbound_protocol?: string | null;
  input_tokens: number;
  latency_ms?: number | null;
  outbound_protocol?: string | null;
  output_tokens: number;
  partial_sent: boolean;
  project_id?: string | null;
  protocol_mode?: string | null;
  provider_key_id?: string | null;
  redaction_status: string;
  request_body_hash?: string | null;
  payload_policy_id?: string | null;
  payload_stored: boolean;
  requested_model?: string | null;
  resolved_channel_id?: string | null;
  resolved_provider_id?: string | null;
  response_body_hash?: string | null;
  retryable?: boolean | null;
  route_policy_version?: string | null;
  status: string;
  stream_end_reason?: string | null;
  tenant_id: string;
  thread_id?: string | null;
  trace_id?: string | null;
  ttft_ms?: number | null;
  upstream_model?: string | null;
  virtual_key_id?: string | null;
};

export type ProviderAttempt = {
  attempt_no: number;
  channel_id?: string | null;
  error_code?: string | null;
  error_owner?: string | null;
  fallback_reason?: string | null;
  http_status?: number | null;
  id: string;
  input_tokens: number;
  latency_ms?: number | null;
  metadata: JsonValue;
  output_tokens: number;
  provider_id?: string | null;
  provider_key_id?: string | null;
  provider_request_id?: string | null;
  request_id: string;
  retryable?: boolean | null;
  status: string;
  tenant_id: string;
  ttft_ms?: number | null;
  upstream_model?: string | null;
};

export type LedgerEntrySummary = {
  amount: string;
  created_at: string;
  currency: string;
  entry_type: LedgerEntryType;
  occurred_at: string;
  request_id?: string | null;
  status: LedgerEntryStatus;
};

export type RequestLedgerSummary = {
  currencies: string[];
  entries: LedgerEntrySummary[];
  limit: number;
  limit_reached: boolean;
  omitted_fields: string[];
  request_count: number;
  returned_count: number;
};

export type RouteDecisionSnapshotSummary = {
  candidate_count?: number | null;
  filtered_count?: number | null;
  filter_reasons?: string[] | null;
  selected_channel_id?: string | null;
  selected_provider_model?: string | null;
  selected_score_total?: number | null;
  trace_affinity_status?: string | null;
};

export type RequestLogDetail = {
  ledger: RequestLedgerSummary;
  provider_attempts: ProviderAttempt[];
  request_log: RequestLogSummary;
  route_decision_snapshot: JsonValue;
};

export type RequestTraceSummaryFilters = {
  limit?: number;
};

export type RequestTraceSummary = {
  currencies: string[];
  error_count: number;
  first_request_at?: string | null;
  last_error?: HealthSummaryRecentLastError | null;
  last_request_at?: string | null;
  ledger: RequestLedgerSummary;
  limit: number;
  limit_reached: boolean;
  request_count: number;
  requests: RequestLogSummary[];
  tenant_id: string;
  total_input_tokens: number;
  total_output_tokens: number;
  trace_id: string;
};

export type AuditLogListFilters = {
  action?: string;
  actor_user_id?: string;
  created_from?: string;
  created_to?: string;
  limit?: number;
  resource_type?: string;
};

export type AuditLog = {
  action: string;
  actor_user_id?: string | null;
  after_snapshot?: JsonValue | null;
  before_snapshot?: JsonValue | null;
  created_at: string;
  id: string;
  metadata: JsonValue;
  request_id?: string | null;
  resource_id?: string | null;
  resource_tenant_id?: string | null;
  resource_type: string;
  tenant_id: string;
};

export type ModelAssociationDryRunRequest = {
  canonical_model_id?: string;
  canonical_model_key?: string;
  previous_successful_channel_id?: string;
  profile_id: string;
  project_id: string;
  requested_model?: string;
  seed?: number;
  trace_id?: string;
};

export type ModelAssociationDryRunCanonicalModel = {
  display_name: string;
  family?: string | null;
  id: string;
  model_key: string;
  status: string;
};

export type ModelAssociationDryRunSelection = {
  selected: JsonValue;
  selected_channel_id?: string | null;
  status: string;
};

export type ModelAssociationDryRunCandidate = {
  association_id: string;
  association_priority: number;
  association_type: string;
  canonical_model_id: string;
  channel_health_score?: number | null;
  channel_id: string;
  channel_name: string;
  channel_priority?: number | null;
  channel_status: string;
  channel_weight?: number | null;
  fallback_allowed: boolean;
  filter_reason?: string | null;
  filtered: boolean;
  priority?: number | null;
  protocol_mode?: string | null;
  provider_code?: string | null;
  provider_id: string;
  provider_model?: string | null;
  provider_name: string;
  provider_status: string;
  rate_limit_available?: boolean | null;
  routing_health?: string | null;
  routing_status?: string | null;
  score?: JsonValue;
  selected: boolean;
  trace_affinity_match: boolean;
  upstream_model?: string | null;
  weight?: number | null;
};

export type ModelAssociationDryRunResponse = {
  candidates: ModelAssociationDryRunCandidate[];
  canonical_model: ModelAssociationDryRunCanonicalModel | null;
  decision_snapshot_version: number;
  policy: JsonValue;
  profile_id: string;
  project_id: string;
  requested_model: string;
  route_decision_snapshot: JsonValue;
  route_policy_version: string;
  selected_candidate: ModelAssociationDryRunCandidate | null;
  selection: ModelAssociationDryRunSelection;
  trace_affinity: JsonValue;
  trace_id?: string | null;
};

export type ProviderKeyStatus =
  | "enabled"
  | "manual_disabled"
  | "degraded"
  | "cooldown"
  | "recovery_probe"
  | "auth_failed"
  | "quota_exhausted"
  | "deleted"
  | string;

export type ProviderKey = {
  channel_id: string;
  concurrency_limit?: number | null;
  cooldown_until?: string | null;
  current_window_state: JsonValue;
  health_score: number;
  id: string;
  key_alias: string;
  last_error_code?: string | null;
  metadata: JsonValue;
  rpm_limit?: number | null;
  status: ProviderKeyStatus;
  tenant_id: string;
  tpm_limit?: number | null;
};

export type CreateProviderKeyRequest = {
  api_key?: string;
  channel_id: string;
  key_alias: string;
  metadata?: JsonObject;
  secret?: string;
  status?: ProviderKeyStatus;
};

export type PatchProviderKeyRequest = {
  metadata?: JsonObject;
  status?: ProviderKeyStatus;
};

export type ProviderKeyRecoveryTargetStatus = "recovery_probe" | "enabled";

export type ProviderKeyRecoveryRequest = {
  reason?: string;
  target_status?: ProviderKeyRecoveryTargetStatus;
};

export type ProviderKeyRecoveryResponse = {
  billing: {
    billable: false;
    ledger_write: false;
  };
  controlled_status_transition: true;
  credential_material: {
    omitted: true;
  };
  dry_run: false;
  provider_key: ProviderKey;
  reason?: string | null;
  target_status: ProviderKeyRecoveryTargetStatus;
  transition: {
    allowed_source_statuses: string[];
    allowed_target_statuses: ProviderKeyRecoveryTargetStatus[];
    from_status: ProviderKeyStatus;
    to_status: ProviderKeyRecoveryTargetStatus;
  };
  upstream_probe: {
    billable: false;
    executed: false;
    mode: "not_implemented" | string;
    request_log_write: false;
  };
};

export type ApiKeyProfileStatus = "active" | "disabled" | "deleted" | string;

export type ApiKeyProfile = {
  allowed_channel_tags: JsonValue;
  allowed_models: JsonValue;
  blocked_provider_ids: JsonValue;
  default_protocol_mode: string;
  denied_models: JsonValue;
  id: string;
  inbound_protocol: string;
  ip_allowlist: JsonValue;
  model_aliases: JsonValue;
  name: string;
  payload_policy_id?: string | null;
  project_id: string;
  request_overrides: JsonValue;
  status: ApiKeyProfileStatus;
  tenant_id: string;
  trace_header_rules: JsonValue;
};

export type ApiKeyProfileListFilters = {
  project_id: string;
};

export type CreateApiKeyProfileRequest = {
  allowed_channel_tags?: JsonValue;
  allowed_models?: JsonValue;
  blocked_provider_ids?: JsonValue;
  default_protocol_mode?: string;
  denied_models?: JsonValue;
  inbound_protocol?: string;
  ip_allowlist?: JsonValue;
  model_aliases?: JsonValue;
  name: string;
  payload_policy_id?: string | null;
  project_id: string;
  request_overrides?: JsonValue;
  status?: ApiKeyProfileStatus;
  trace_header_rules?: JsonValue;
};

export type PatchApiKeyProfileRequest = Partial<Omit<CreateApiKeyProfileRequest, "project_id">>;

export type VirtualKeyStatus = "active" | "disabled" | "expired" | "deleted" | string;

export type VirtualKey = {
  budget_policy: JsonValue;
  default_profile_id?: string | null;
  id: string;
  ip_allowlist: JsonValue;
  key_prefix: string;
  metadata: JsonValue;
  name: string;
  project_id: string;
  rate_limit_policy: JsonValue;
  secret?: string;
  secret_once?: boolean;
  secret_redacted: boolean;
  status: VirtualKeyStatus;
  tenant_id: string;
};

export type VirtualKeyListFilters = {
  project_id: string;
  status?: VirtualKeyStatus;
};

export type CreateVirtualKeyRequest = {
  budget_policy?: JsonValue;
  default_profile_id: string;
  ip_allowlist?: JsonValue;
  metadata?: JsonValue;
  name: string;
  project_id: string;
  rate_limit_policy?: JsonValue;
  status?: VirtualKeyStatus;
};

export type PriceVersionStatus = "draft" | "active" | "retired" | string;

export type PriceVersion = {
  canonical_model_id?: string | null;
  created_at: string;
  effective_at: string;
  id: string;
  price_book_id: string;
  pricing_rules: JsonValue;
  retired_at?: string | null;
  status: PriceVersionStatus;
  tenant_id: string;
  version: string;
};

export type PriceVersionListFilters = {
  canonical_model_id?: string;
  limit?: number;
  price_book_id?: string;
  status?: PriceVersionStatus;
};

export type CreatePriceVersionRequest = {
  canonical_model_id?: string;
  effective_at?: string;
  price_book_id: string;
  pricing_rules: JsonObject;
  retired_at?: string;
  status?: PriceVersionStatus;
  version: string;
};

export type LedgerEntryType =
  | "reserve"
  | "settle"
  | "refund"
  | "adjust"
  | "expire"
  | "credit_grant"
  | "credit_expire"
  | string;

export type LedgerEntryStatus = "pending" | "confirmed" | "reversed" | string;

export type LedgerEntry = {
  amount: string;
  created_at: string;
  currency: string;
  entry_type: LedgerEntryType;
  id: string;
  idempotency_key: string;
  metadata: JsonValue;
  occurred_at: string;
  policy_snapshot: JsonValue;
  price_version_id?: string | null;
  project_id?: string | null;
  related_ledger_entry_id?: string | null;
  request_id?: string | null;
  status: LedgerEntryStatus;
  tenant_id: string;
  trace_id?: string | null;
  usage_snapshot: JsonValue;
  virtual_key_id?: string | null;
  wallet_id?: string | null;
};

export type LedgerEntryListFilters = {
  limit?: number;
  project_id?: string;
  request_id?: string;
  wallet_id?: string;
};

export type BillingReconciliationReportFilters = {
  day?: string;
  limit?: number;
};

export type BillingReconciliationIssue =
  | "missing_ledger"
  | "unexpected_ledger"
  | "amount_mismatch"
  | "currency_mismatch"
  | string;

export type BillingReconciliationCurrencyTotal = {
  currency: string;
  difference_amount: string;
  expected_ledger_amount_total: string;
  ledger_amount_total: string;
  request_final_cost_total: string;
};

export type BillingReconciliationSummary = {
  amount_mismatch_count: number;
  billable_request_count: number;
  currency_mismatch_count: number;
  currency_totals: BillingReconciliationCurrencyTotal[];
  discrepancy_count: number;
  ledger_entry_count: number;
  matched_request_count: number;
  missing_ledger_count: number;
  request_count: number;
  returned_discrepancy_count: number;
  unexpected_ledger_count: number;
};

export type BillingReconciliationDiscrepancy = {
  canonical_model_id?: string | null;
  difference_amount?: string | null;
  expected_ledger_amount?: string | null;
  input_tokens?: number | null;
  issues: BillingReconciliationIssue[];
  ledger_amount?: string | null;
  ledger_currency?: string | null;
  ledger_entry_ids: string[];
  output_tokens?: number | null;
  project_id?: string | null;
  request_currency?: string | null;
  request_final_cost?: string | null;
  request_id?: string | null;
  request_status?: string | null;
  requested_model?: string | null;
  resolved_channel_id?: string | null;
  resolved_provider_id?: string | null;
  trace_id?: string | null;
  upstream_model?: string | null;
  virtual_key_id?: string | null;
};

export type BillingReconciliationReport = {
  discrepancies: BillingReconciliationDiscrepancy[];
  period_end: string;
  period_start: string;
  report_version: 1;
  summary: BillingReconciliationSummary;
  tenant_id: string;
};

export type AdminUser = {
  display_name: string;
  email: string;
  id: string;
  roles: string[];
  tenant_id: string;
};

export type AdminSessionInfo = {
  expires_at: string;
  id: string;
};

export type AdminCapabilitySummary = {
  capabilities: string[];
  denied_capabilities: string[];
  personas?: string[];
  roles?: string[];
  secret_safe?: boolean;
};

export type AdminLoginRequest = {
  email: string;
  password: string;
};

export type AdminLoginResponse = {
  session: AdminSessionInfo;
  session_token_once: string;
  user: AdminUser;
};

export type AdminMeResponse = {
  capability_summary: AdminCapabilitySummary;
  session: AdminSessionInfo;
  user: AdminUser;
};

export const DEFAULT_REQUEST_TIMEOUT_MS = 10_000;
export const HEALTH_PROBE_TIMEOUT_MS = 3_000;
export const ADMIN_SESSION_HEADER = "x-admin-session";

let adminSessionToken: string | null = null;

const sameOriginBaseUrls = {
  gateway: "/api/gateway",
  controlPlane: "/api/control-plane",
  mockProvider: "/api/mock-provider",
} satisfies Record<ServiceName, string>;

function configuredBaseUrl(values: Array<string | undefined>, fallback: string): string {
  for (const value of values) {
    const trimmed = value?.trim();
    if (trimmed) {
      return withoutTrailingSlash(trimmed);
    }
  }

  return fallback;
}

function withoutTrailingSlash(value: string): string {
  return value.replace(/\/+$/, "");
}

export const serviceBaseUrls = {
  gateway: configuredBaseUrl(
    [import.meta.env.VITE_GATEWAY_BASE_URL, import.meta.env.VITE_API_BASE_URL],
    sameOriginBaseUrls.gateway,
  ),
  controlPlane: configuredBaseUrl([import.meta.env.VITE_CONTROL_BASE_URL], sameOriginBaseUrls.controlPlane),
  mockProvider: configuredBaseUrl([import.meta.env.VITE_MOCK_PROVIDER_BASE_URL], sameOriginBaseUrls.mockProvider),
} satisfies Record<ServiceName, string>;

export class ApiClientError extends Error {
  readonly code?: string;
  readonly envelope?: ErrorEnvelope;
  readonly retryable?: boolean;
  readonly status?: number;
  readonly statusText?: string;
  readonly type?: string;
  readonly url: string;

  constructor(message: string, options: {
    code?: string;
    envelope?: ErrorEnvelope;
    retryable?: boolean;
    status?: number;
    statusText?: string;
    type?: string;
    url: string;
  }) {
    super(message);
    this.name = "ApiClientError";
    this.code = options.code;
    this.envelope = options.envelope;
    this.retryable = options.retryable;
    this.status = options.status;
    this.statusText = options.statusText;
    this.type = options.type;
    this.url = options.url;
  }
}

export function joinUrl(baseUrl: string, path: string): string {
  const normalizedBase = withoutTrailingSlash(baseUrl.trim());
  const normalizedPath = path.startsWith("/") ? path : `/${path}`;

  return normalizedBase ? `${normalizedBase}${normalizedPath}` : normalizedPath;
}

export function setAdminSessionToken(token: string | null): void {
  const trimmed = token?.trim();
  adminSessionToken = trimmed ? trimmed : null;
}

export function clearAdminSessionToken(): void {
  adminSessionToken = null;
}

export const serviceProbes: ServiceProbe[] = [
  { name: "Gateway", url: joinUrl(serviceBaseUrls.gateway, "/healthz"), kind: "http" },
  { name: "Control Plane", url: joinUrl(serviceBaseUrls.controlPlane, "/healthz"), kind: "http" },
  { name: "Mock Provider", url: joinUrl(serviceBaseUrls.mockProvider, "/healthz"), kind: "http" },
  { name: "Worker", url: "worker", kind: "process" },
  { name: "PostgreSQL", url: "postgres:5432", kind: "datastore" },
  { name: "Redis", url: "redis:6379", kind: "datastore" },
];

export async function apiJson<T>(path: string, options: JsonRequestOptions = {}): Promise<T> {
  const {
    baseUrl = serviceBaseUrls.controlPlane,
    body,
    headers,
    timeoutMs = DEFAULT_REQUEST_TIMEOUT_MS,
    ...requestInit
  } = options;
  const url = joinUrl(baseUrl, path);
  const requestHeaders = new Headers(headers);
  applyAdminSessionHeader(path, requestHeaders);
  let requestBody: BodyInit | null | undefined;

  if (body !== undefined) {
    if (body instanceof FormData || body instanceof Blob || body instanceof URLSearchParams) {
      requestBody = body;
    } else if (typeof body === "string") {
      requestBody = body;
      setDefaultHeader(requestHeaders, "Content-Type", "text/plain");
    } else {
      requestBody = JSON.stringify(body);
      setDefaultHeader(requestHeaders, "Content-Type", "application/json");
    }
  }

  const response = await fetchWithTimeout(url, {
    ...requestInit,
    body: requestBody,
    credentials: requestInit.credentials ?? "include",
    headers: requestHeaders,
    timeoutMs,
  });

  return readJsonResponse<T>(response, url);
}

export async function loginAdmin(
  request: AdminLoginRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<AdminLoginResponse> {
  return apiJson<AdminLoginResponse>("/admin/auth/login", {
    ...options,
    body: request,
    method: "POST",
  });
}

export function getAdminMe(options: Omit<JsonRequestOptions, "body" | "method"> = {}): Promise<AdminMeResponse> {
  return apiJson<AdminMeResponse>("/admin/auth/me", {
    ...options,
    method: "GET",
  });
}

export async function logoutAdmin(options: Omit<JsonRequestOptions, "body" | "method"> = {}): Promise<void> {
  try {
    await apiJson<{ logged_out: boolean }>("/admin/auth/logout", {
      ...options,
      method: "POST",
    });
  } finally {
    clearAdminSessionToken();
  }
}

export function listRequestLogs(
  filters: RequestLogListFilters = {},
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<RequestLogSummary[]> {
  return apiJson<RequestLogSummary[]>(`/admin/request-logs${queryString(filters)}`, {
    ...options,
    method: "GET",
  });
}

export function listAuditLogs(
  filters: AuditLogListFilters = {},
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<AuditLog[]> {
  return apiJson<AuditLog[]>(`/admin/audit-logs${queryString(filters)}`, {
    ...options,
    method: "GET",
  });
}

export function getProviderHealthSummary(
  filters: HealthSummaryFilters = {},
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<HealthSummary> {
  return apiJson<HealthSummary>(`/admin/providers/health-summary${queryString(filters)}`, {
    ...options,
    method: "GET",
  });
}

export function getRequestLogDetail(
  id: string,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<RequestLogDetail> {
  return apiJson<RequestLogDetail>(`/admin/request-logs/${encodeURIComponent(id)}`, {
    ...options,
    method: "GET",
  });
}

export function getRequestTraceSummary(
  traceId: string,
  filters: RequestTraceSummaryFilters = {},
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<RequestTraceSummary> {
  return apiJson<RequestTraceSummary>(`/admin/traces/${encodeURIComponent(traceId)}${queryString(filters)}`, {
    ...options,
    method: "GET",
  });
}

export function dryRunModelAssociation(
  request: ModelAssociationDryRunRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<ModelAssociationDryRunResponse> {
  return apiJson<ModelAssociationDryRunResponse>("/admin/model-associations/dry-run", {
    ...options,
    body: request,
    method: "POST",
  });
}

export function listProviders(options: Omit<JsonRequestOptions, "body" | "method"> = {}): Promise<Provider[]> {
  return apiJson<Provider[]>("/admin/providers", {
    ...options,
    method: "GET",
  });
}

export function createProvider(
  request: CreateProviderRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<Provider> {
  return apiJson<Provider>("/admin/providers", {
    ...options,
    body: request,
    method: "POST",
  });
}

export function patchProvider(
  id: string,
  request: PatchProviderRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<Provider> {
  return apiJson<Provider>(`/admin/providers/${encodeURIComponent(id)}`, {
    ...options,
    body: request,
    method: "PATCH",
  });
}

export function deleteProvider(
  id: string,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<Provider> {
  return apiJson<Provider>(`/admin/providers/${encodeURIComponent(id)}`, {
    ...options,
    method: "DELETE",
  });
}

export function listChannels(options: Omit<JsonRequestOptions, "body" | "method"> = {}): Promise<Channel[]> {
  return apiJson<Channel[]>("/admin/channels", {
    ...options,
    method: "GET",
  });
}

export function createChannel(
  request: CreateChannelRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<Channel> {
  return apiJson<Channel>("/admin/channels", {
    ...options,
    body: request,
    method: "POST",
  });
}

export function patchChannel(
  id: string,
  request: PatchChannelRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<Channel> {
  return apiJson<Channel>(`/admin/channels/${encodeURIComponent(id)}`, {
    ...options,
    body: request,
    method: "PATCH",
  });
}

export function deleteChannel(
  id: string,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<Channel> {
  return apiJson<Channel>(`/admin/channels/${encodeURIComponent(id)}`, {
    ...options,
    method: "DELETE",
  });
}

export function dryRunChannelManualTest(
  id: string,
  request: ChannelManualTestRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<ChannelManualTestResponse> {
  return apiJson<ChannelManualTestResponse>(`/admin/channels/${encodeURIComponent(id)}/manual-test`, {
    ...options,
    body: request,
    method: "POST",
  });
}

export function listCanonicalModels(
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<CanonicalModel[]> {
  return apiJson<CanonicalModel[]>("/admin/models", {
    ...options,
    method: "GET",
  });
}

export function createCanonicalModel(
  request: CreateCanonicalModelRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<CanonicalModel> {
  return apiJson<CanonicalModel>("/admin/models", {
    ...options,
    body: request,
    method: "POST",
  });
}

export function patchCanonicalModel(
  id: string,
  request: PatchCanonicalModelRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<CanonicalModel> {
  return apiJson<CanonicalModel>(`/admin/models/${encodeURIComponent(id)}`, {
    ...options,
    body: request,
    method: "PATCH",
  });
}

export function deleteCanonicalModel(
  id: string,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<CanonicalModel> {
  return apiJson<CanonicalModel>(`/admin/models/${encodeURIComponent(id)}`, {
    ...options,
    method: "DELETE",
  });
}

export function listModelAssociations(
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<ModelAssociation[]> {
  return apiJson<ModelAssociation[]>("/admin/model-associations", {
    ...options,
    method: "GET",
  });
}

export function createModelAssociation(
  request: CreateModelAssociationRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<ModelAssociation> {
  return apiJson<ModelAssociation>("/admin/model-associations", {
    ...options,
    body: request,
    method: "POST",
  });
}

export function patchModelAssociation(
  id: string,
  request: PatchModelAssociationRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<ModelAssociation> {
  return apiJson<ModelAssociation>(`/admin/model-associations/${encodeURIComponent(id)}`, {
    ...options,
    body: request,
    method: "PATCH",
  });
}

export function deleteModelAssociation(
  id: string,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<ModelAssociation> {
  return apiJson<ModelAssociation>(`/admin/model-associations/${encodeURIComponent(id)}`, {
    ...options,
    method: "DELETE",
  });
}

export function listProviderKeys(
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<ProviderKey[]> {
  return apiJson<ProviderKey[]>("/admin/provider-keys", {
    ...options,
    method: "GET",
  });
}

export function createProviderKey(
  request: CreateProviderKeyRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<ProviderKey> {
  return apiJson<ProviderKey>("/admin/provider-keys", {
    ...options,
    body: request,
    method: "POST",
  });
}

export function patchProviderKey(
  id: string,
  request: PatchProviderKeyRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<ProviderKey> {
  return apiJson<ProviderKey>(`/admin/provider-keys/${encodeURIComponent(id)}`, {
    ...options,
    body: request,
    method: "PATCH",
  });
}

export function requestProviderKeyRecovery(
  id: string,
  request: ProviderKeyRecoveryRequest = {},
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<ProviderKeyRecoveryResponse> {
  return apiJson<ProviderKeyRecoveryResponse>(`/admin/provider-keys/${encodeURIComponent(id)}/recovery`, {
    ...options,
    body: request,
    method: "POST",
  });
}

export function deleteProviderKey(
  id: string,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<ProviderKey> {
  return apiJson<ProviderKey>(`/admin/provider-keys/${encodeURIComponent(id)}`, {
    ...options,
    method: "DELETE",
  });
}

export function listApiKeyProfiles(
  filters: ApiKeyProfileListFilters,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<ApiKeyProfile[]> {
  return apiJson<ApiKeyProfile[]>(`/admin/api-key-profiles${queryString(filters)}`, {
    ...options,
    method: "GET",
  });
}

export function getApiKeyProfile(
  id: string,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<ApiKeyProfile> {
  return apiJson<ApiKeyProfile>(`/admin/api-key-profiles/${encodeURIComponent(id)}`, {
    ...options,
    method: "GET",
  });
}

export function createApiKeyProfile(
  request: CreateApiKeyProfileRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<ApiKeyProfile> {
  return apiJson<ApiKeyProfile>("/admin/api-key-profiles", {
    ...options,
    body: request,
    method: "POST",
  });
}

export function patchApiKeyProfile(
  id: string,
  request: PatchApiKeyProfileRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<ApiKeyProfile> {
  return apiJson<ApiKeyProfile>(`/admin/api-key-profiles/${encodeURIComponent(id)}`, {
    ...options,
    body: request,
    method: "PATCH",
  });
}

export function deleteApiKeyProfile(
  id: string,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<ApiKeyProfile> {
  return apiJson<ApiKeyProfile>(`/admin/api-key-profiles/${encodeURIComponent(id)}`, {
    ...options,
    method: "DELETE",
  });
}

export function listVirtualKeys(
  filters: VirtualKeyListFilters,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<VirtualKey[]> {
  return apiJson<VirtualKey[]>(`/admin/virtual-keys${queryString(filters)}`, {
    ...options,
    method: "GET",
  });
}

export function getVirtualKey(
  id: string,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<VirtualKey> {
  return apiJson<VirtualKey>(`/admin/virtual-keys/${encodeURIComponent(id)}`, {
    ...options,
    method: "GET",
  });
}

export function createVirtualKey(
  request: CreateVirtualKeyRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<VirtualKey> {
  return apiJson<VirtualKey>("/admin/virtual-keys", {
    ...options,
    body: request,
    method: "POST",
  });
}

export function disableVirtualKey(
  id: string,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<VirtualKey> {
  return apiJson<VirtualKey>(`/admin/virtual-keys/${encodeURIComponent(id)}/disable`, {
    ...options,
    method: "POST",
  });
}

export function expireVirtualKey(
  id: string,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<VirtualKey> {
  return apiJson<VirtualKey>(`/admin/virtual-keys/${encodeURIComponent(id)}/expire`, {
    ...options,
    method: "POST",
  });
}

export function listPriceVersions(
  filters: PriceVersionListFilters = {},
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<PriceVersion[]> {
  return apiJson<PriceVersion[]>(`/admin/price-versions${queryString(filters)}`, {
    ...options,
    method: "GET",
  });
}

export function createPriceVersion(
  request: CreatePriceVersionRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<PriceVersion> {
  return apiJson<PriceVersion>("/admin/price-versions", {
    ...options,
    body: request,
    method: "POST",
  });
}

export function listLedgerEntries(
  filters: LedgerEntryListFilters = {},
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<LedgerEntry[]> {
  return apiJson<LedgerEntry[]>(`/admin/ledger/entries${queryString(filters)}`, {
    ...options,
    method: "GET",
  });
}

export function getBillingReconciliationReport(
  filters: BillingReconciliationReportFilters = {},
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<BillingReconciliationReport> {
  return apiJson<BillingReconciliationReport>(`/admin/billing/reconciliation${queryString(filters)}`, {
    ...options,
    method: "GET",
  });
}

export async function probeServices(probes: ServiceProbe[] = serviceProbes): Promise<ProbeResult[]> {
  return Promise.all(
    probes.map(async (probe) => {
      if (probe.kind !== "http") {
        return {
          name: probe.name,
          status: "pending",
          detail: probe.url,
        } satisfies ProbeResult;
      }

      try {
        const response = await fetchWithTimeout(probe.url, {
          cache: "no-store",
          timeoutMs: HEALTH_PROBE_TIMEOUT_MS,
        });
        return {
          name: probe.name,
          status: response.ok ? "online" : "offline",
          detail: probe.url,
        } satisfies ProbeResult;
      } catch {
        return {
          name: probe.name,
          status: "offline",
          detail: probe.url,
        } satisfies ProbeResult;
      }
    }),
  );
}

async function fetchWithTimeout(
  url: string,
  { signal, timeoutMs = DEFAULT_REQUEST_TIMEOUT_MS, ...requestInit }: RequestInit & { timeoutMs?: number },
): Promise<Response> {
  const controller = new AbortController();
  let didCancel = false;
  let didTimeout = false;
  let timeoutId: ReturnType<typeof setTimeout> | undefined;
  let removeAbortListener: (() => void) | undefined;

  if (timeoutMs > 0) {
    timeoutId = setTimeout(() => {
      didTimeout = true;
      controller.abort();
    }, timeoutMs);
  }

  if (signal) {
    if (signal.aborted) {
      didCancel = true;
      controller.abort();
    } else {
      const abort = () => {
        didCancel = true;
        controller.abort();
      };
      signal.addEventListener("abort", abort, { once: true });
      removeAbortListener = () => signal.removeEventListener("abort", abort);
    }
  }

  try {
    return await fetch(url, {
      ...requestInit,
      signal: controller.signal,
    });
  } catch (error) {
    if (didTimeout) {
      throw new ApiClientError(`Request timed out after ${timeoutMs}ms`, {
        code: "request_timeout",
        retryable: true,
        url,
      });
    }

    if (didCancel) {
      throw new ApiClientError("Request was aborted", {
        code: "request_aborted",
        retryable: false,
        url,
      });
    }

    if (error instanceof ApiClientError) {
      throw error;
    }

    throw new ApiClientError(error instanceof Error ? error.message : "Network request failed", {
      code: "network_error",
      retryable: true,
      url,
    });
  } finally {
    if (timeoutId) {
      clearTimeout(timeoutId);
    }
    removeAbortListener?.();
  }
}

async function readJsonResponse<T>(response: Response, url: string): Promise<T> {
  const text = await response.text();
  const payload = text ? parseJson(text, response, url) : undefined;

  if (!response.ok) {
    const envelope = toErrorEnvelope(payload);
    const error = envelope?.error;
    const gateway = envelope?.gateway;

    throw new ApiClientError(stringValue(error?.message) ?? response.statusText ?? "API request failed", {
      code: stringValue(error?.code),
      envelope,
      retryable: booleanValue(gateway?.retryable),
      status: response.status,
      statusText: response.statusText,
      type: stringValue(error?.type),
      url,
    });
  }

  return unwrapDataEnvelope(payload) as T;
}

function parseJson(text: string, response: Response, url: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    throw new ApiClientError("API response was not valid JSON", {
      code: "invalid_json",
      status: response.status,
      statusText: response.statusText,
      url,
    });
  }
}

function unwrapDataEnvelope(payload: unknown): unknown {
  if (isRecord(payload) && "data" in payload) {
    return payload.data;
  }

  return payload;
}

function queryString(filters: Record<string, unknown>): string {
  const params = new URLSearchParams();

  for (const [key, value] of Object.entries(filters)) {
    if (value !== undefined && value !== null && String(value).trim() !== "") {
      params.set(key, String(value));
    }
  }

  const query = params.toString();

  return query ? `?${query}` : "";
}

function toErrorEnvelope(payload: unknown): ErrorEnvelope | undefined {
  if (!isRecord(payload)) {
    return undefined;
  }

  return payload as ErrorEnvelope;
}

function setDefaultHeader(headers: Headers, key: string, value: string): void {
  if (!headers.has(key)) {
    headers.set(key, value);
  }
}

function applyAdminSessionHeader(path: string, headers: Headers): void {
  if (!adminSessionToken || !path.startsWith("/admin/") || path === "/admin/auth/login") {
    return;
  }

  if (!headers.has(ADMIN_SESSION_HEADER)) {
    headers.set(ADMIN_SESSION_HEADER, adminSessionToken);
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function booleanValue(value: unknown): boolean | undefined {
  return typeof value === "boolean" ? value : undefined;
}
