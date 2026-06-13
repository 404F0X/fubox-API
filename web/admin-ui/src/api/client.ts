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
  avg_latency_ms?: number | null;
  error_top?: Array<{
    code: string;
    count: number;
  }>;
  error_count: number;
  last_error?: HealthSummaryRecentLastError | null;
  p95_latency_ms?: number | null;
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

export type EndpointCapability = {
  authorization_returned?: false;
  endpoint: "chat" | "responses" | "embeddings" | "anthropic_messages" | "gemini_native" | "gemini_generate_content" | string;
  known_missing_pieces?: string[];
  live_config_status?: string;
  live_ready_channel_count?: number;
  mock_contract?: string;
  mockable_config_status?: string;
  operation?: string;
  path_template?: string;
  protocol?: string;
  provider_key_present?: boolean;
  provider_key_returned?: false;
  raw_endpoint_returned?: false;
  raw_payload_returned?: false;
  safe_next_action?: string;
  supported: boolean;
  supported_channel_count?: number;
};

export type EndpointCapabilitiesReadback = {
  endpoints: EndpointCapability[];
  protocol?: string;
  schema: string;
};

export type ProtocolReadinessReadback = {
  authorization_returned?: false;
  channel_count?: number;
  known_missing_pieces?: string[];
  live_config_status?: string;
  live_ready_channel_count?: number;
  mockable_config_status?: string;
  normalized_protocol?: string;
  protocol_mode?: string;
  provider_key_present?: boolean;
  provider_key_returned?: false;
  raw_endpoint_returned?: false;
  raw_payload_returned?: false;
  safe_next_action?: string;
  schema: string;
  secret_safe?: boolean;
  status: string;
  supported_endpoint_count?: number;
  supported_protocol_channel_count?: number;
};

export type ProtocolCapabilityMatrixEndpoint = {
  authorization_returned: false;
  blocked_reason?: string | null;
  config_needed: boolean;
  endpoint: "chat" | "responses" | "embeddings" | "anthropic_messages" | "gemini_generate_content" | string;
  known_missing_pieces: string[];
  live_config_status: string;
  mockable: boolean;
  mockable_config_status: string;
  operation: string;
  path_template: string;
  protocol: string;
  provider_key_returned: false;
  raw_endpoint_returned: false;
  raw_payload_returned: false;
  status: "supported" | "config-needed" | "blocked" | string;
  supported: boolean;
};

export type ProtocolCapabilityMatrixRow = {
  authorization_returned: false;
  blocked_reasons: string[];
  channel_id: string;
  channel_name: string;
  channel_status: string;
  endpoints: ProtocolCapabilityMatrixEndpoint[];
  model_id?: string | null;
  model_key?: string | null;
  model_status?: string | null;
  normalized_protocol: string;
  profile_default_protocol_mode?: string | null;
  profile_id?: string | null;
  profile_inbound_protocol?: string | null;
  profile_status?: string | null;
  protocol_mode: string;
  provider_code?: string | null;
  provider_id?: string | null;
  provider_key_present: boolean;
  provider_key_returned: false;
  provider_status?: string | null;
  raw_endpoint_returned: false;
  raw_payload_returned: false;
  secret_safe: true;
  status: "supported" | "config-needed" | "blocked" | string;
  supported_endpoint_count: number;
};

export type ProtocolCapabilityMatrixReadback = {
  authorization_returned: false;
  dimensions: Array<"provider" | "channel" | "model" | "profile" | string>;
  endpoints: Array<"chat" | "responses" | "embeddings" | "anthropic_messages" | "gemini_generate_content" | string>;
  profile_default_protocol_mode?: string | null;
  profile_id?: string | null;
  profile_inbound_protocol?: string | null;
  provider_key_returned: false;
  raw_endpoint_returned: false;
  raw_payload_returned: false;
  row_count: number;
  rows: ProtocolCapabilityMatrixRow[];
  schema: "provider_protocol_capability_matrix.v1" | string;
  secret_safe: true;
};

export type HealthSummaryProvider = HealthSummaryEntityBase & {
  channel_count: number;
  code: string;
  enabled_channel_count: number;
  enabled_provider_key_count: number;
  endpoint_capabilities?: EndpointCapabilitiesReadback;
  name: string;
  provider_key_count: number;
  protocol_readiness?: ProtocolReadinessReadback;
};

export type HealthSummaryChannel = HealthSummaryEntityBase & {
  enabled_provider_key_count: number;
  endpoint_capabilities?: EndpointCapabilitiesReadback;
  model_count: number;
  name: string;
  priority: number;
  protocol_readiness?: ProtocolReadinessReadback;
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
  recovery_probe?: {
    error_code?: string | null;
    last_checked_at?: string | null;
    next_step?: string | null;
    result?: string | null;
  } | null;
  recovery_action_readback?: ProviderKeyRecoveryActionReadback | null;
  recovery_apply_plan_readback?: ProviderKeyRecoveryApplyPlanReadback | null;
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
  probe_status?: {
    next_probe?: string | null;
    probe_source: "request_logs" | "scheduled_probe" | string;
    scheduler_pending: boolean;
    status: "scheduler_pending" | "active" | "disabled" | string;
  };
  provider_keys: HealthSummaryProviderKey[];
  providers: HealthSummaryProvider[];
  protocol_capability_matrix?: ProtocolCapabilityMatrixReadback;
  recent_window: {
    error_count?: number;
    avg_latency_ms?: number | null;
    error_top?: Array<{
      code: string;
      count: number;
    }>;
    p95_latency_ms?: number | null;
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

export type AdminDistributionReadinessCheck = {
  blocking: boolean;
  detail: string;
  evidence: string;
  id: string;
  label: string;
  next_action: string;
  status: "online" | "offline" | "pending" | string;
};

export type AdminDistributionVoucherBatchStatus = {
  admin_route: string;
  batch_count: number;
  code_hash_returned: false;
  evidence: string;
  idempotency_hash_returned?: false;
  latest_voucher_created_at?: string | null;
  raw_voucher_code_returned: false;
  revocable_count: number;
  safe_next_action: string;
  schema: "voucher_batch_status_readback.v1" | string;
  secret_safe: true;
  status: "ready" | "attention" | "blocked" | string;
  voucher_count: number;
};

export type AdminDistributionRedeemReadiness = {
  admin_runtime_route?: string;
  authorization_returned: false;
  code_hash_returned: false;
  credit_or_ledger_effect_count: number;
  evidence: string;
  issued_count: number;
  raw_voucher_code_returned: false;
  redemption_count: number;
  redeem_attempt_count?: number;
  refused_redemption_count?: number;
  safe_next_action: string;
  schema: "voucher_redeem_readiness_readback.v1" | string;
  secret_safe: true;
  status: "ready" | "attention" | "blocked" | string;
  successful_redemption_count?: number;
  user_route: string;
};

export type AdminDistributionVirtualKeyIssuanceReadiness = {
  active_profile_count: number;
  active_virtual_key_count: number;
  admin_route: string;
  api_key_secret_or_hash_returned: false;
  authorization_returned: false;
  configured_budget_policy_count: number;
  configured_rate_limit_policy_count: number;
  one_time_secret_policy: string;
  profile_count: number;
  provider_key_returned: false;
  raw_virtual_key_secret_returned: false;
  safe_next_action: string;
  schema: "virtual_key_issuance_readiness_readback.v1" | string;
  secret_safe: true;
  status: "ready" | "blocked" | string;
  user_route: string;
  virtual_key_count: number;
};

export type AdminDistributionQuotaPricingGuardrails = {
  active_price_version_count: number;
  configured_virtual_key_budget_policy_count: number;
  configured_virtual_key_rate_limit_policy_count: number;
  price_version_count: number;
  pricing_rules_returned: false;
  provider_key_count: number;
  provider_key_limit_guardrail_count: number;
  raw_policy_payload_returned: false;
  safe_next_action: string;
  schema: "quota_pricing_guardrails_readback.v1" | string;
  secret_safe: true;
  status: "ready" | "blocked" | string;
};

export type AdminDistributionReadiness = {
  blockers: string[];
  checks: AdminDistributionReadinessCheck[];
  counts: Record<string, number>;
  default_project_id: string;
  deferred_runtime: Record<string, string>;
  external_inputs: JsonValue;
  health_summary: HealthSummary;
  overall_status: "ready" | "attention" | "blocked" | string;
  production_distribution_full_ready: boolean;
  quota_pricing_guardrails?: AdminDistributionQuotaPricingGuardrails;
  raw_provider_key_returned: false;
  raw_request_payload_returned: false;
  raw_virtual_key_secret_returned: false;
  raw_voucher_code_returned: false;
  ready_to_distribute_api: boolean;
  redeem_readiness?: AdminDistributionRedeemReadiness;
  safe_next_action?: string;
  schema: "admin_distribution_readiness.v1" | string;
  secret_safe: boolean;
  source: "control_plane_authoritative_readback" | string;
  summary: {
    attention: number;
    blocked: number;
    ready: number;
    total: number;
  };
  tenant_id: string;
  virtual_key_issuance_readiness?: AdminDistributionVirtualKeyIssuanceReadiness;
  voucher_batch_status?: AdminDistributionVoucherBatchStatus;
};

export type AdminSetupReadbackCheck = {
  code: string;
  detail: string;
  label: string;
  next_action: string;
  status: "ready" | "attention" | "blocked" | string;
};

export type AdminSetupFirstRunReadinessItem = {
  blocked_reasons: string[];
  safe_next_action: string;
  secret_safe: true;
  status: "ready" | "attention" | "blocked" | string;
};

export type AdminSetupFirstRunReadiness = {
  admin: AdminSetupFirstRunReadinessItem;
  api_key_secret_hash_returned: false;
  api_key_secret_returned: false;
  authorization_returned: false;
  blocked_reasons: string[];
  gateway_chat: AdminSetupFirstRunReadinessItem;
  gateway_embeddings: AdminSetupFirstRunReadinessItem;
  gateway_responses: AdminSetupFirstRunReadinessItem;
  mock_channel: AdminSetupFirstRunReadinessItem;
  mock_model: AdminSetupFirstRunReadinessItem;
  mock_provider: AdminSetupFirstRunReadinessItem;
  omitted_fields: string[];
  provider_secret_hash_returned: false;
  provider_secret_returned: false;
  raw_admin_password_returned: false;
  raw_payload_returned: false;
  safe_next_action: string;
  schema: "admin_setup_first_run_readiness.v1" | string;
  secret_safe: true;
  status: "ready" | "attention" | "blocked" | string;
  test_key: AdminSetupFirstRunReadinessItem;
};

export type AdminSetupReadback = {
  authorization_returned: false;
  blockers: string[];
  checks: AdminSetupReadbackCheck[];
  counts: {
    blocked: number;
    ready: number;
    recent_mock_chat_successes: number;
    total: number;
  };
  default_project_id: string;
  first_run_readiness?: AdminSetupFirstRunReadiness;
  gateway: {
    chat_readiness: {
      next_action: string;
      raw_payload_returned: false;
      recent_success_count: number;
      status: "ready" | "attention" | "blocked" | string;
    };
    model_readiness: {
      authorization_returned: false;
      model: string;
      requires_authorization_header: boolean;
      status: "ready" | "attention" | "blocked" | string;
    };
  };
  handoff: {
    admin_ui_target: string;
    omitted_fields: string[];
    production_credentials_required: false;
    script_next_check: string;
    user_portal_target: string;
  };
  local_seed: {
    admin_exists: boolean;
    default_model: {
      active: boolean;
      association_enabled: boolean;
      exists: boolean;
      model_key: string;
    };
    mock_channel: {
      enabled: boolean;
      exists: boolean;
      name: string;
    };
    mock_provider: {
      code: string;
      enabled: boolean;
      exists: boolean;
    };
    mock_provider_key: {
      alias: string;
      credential_configured: boolean;
      exists: boolean;
    };
    test_key: {
      active: boolean;
      key_prefix: string;
      present: boolean;
      secret_returned: false;
    };
  };
  next_action: string;
  raw_admin_password_returned: false;
  raw_provider_key_returned: false;
  raw_request_payload_returned: false;
  raw_test_key_secret_returned: false;
  schema: "admin_setup_readback.v1" | string;
  secret_safe: boolean;
  source: "control_plane_local_seed_readback" | string;
  state: "ready" | "attention" | "blocked" | string;
  tenant_id: string;
  wizard_steps?: Array<{
    code: "admin" | "mock_provider_channel_model" | "test_key" | "gateway_model_chat_readiness" | string;
    detail: string;
    evidence: string;
    label: string;
    next_action: string;
    production_credentials_required: false;
    status: "ready" | "attention" | "blocked" | string;
  }>;
};

export type AdminProductionReadModelStatus = {
  backend: "postgres" | "clickhouse" | "config-needed" | string;
  clickhouse: {
    connectivity_check_enabled: false;
    contract: string;
    credentials?: {
      api_secret_present?: boolean;
      basic_secret_present?: boolean;
      basic_user_present?: boolean;
      bearer_header_present?: boolean;
      endpoint_userinfo_present?: boolean;
      redaction: "presence_only" | string;
    };
    database?: string | null;
    enabled: boolean;
    endpoint_configured: boolean;
    endpoint_returned: false;
    network_requests: false;
    status: "configured" | "disabled" | "config-needed" | string;
    table?: string | null;
  };
  contract: {
    admin_path: "GET /admin/production/read-model/status" | string;
    authorization_returned: false;
    clickhouse_connected: false;
    clickhouse_contract: string;
    credentials_returned: false;
    db_url_returned: false;
    frontend_contract: "AdminProductionReadModelStatus" | string;
    lag_explainability_contract: "admin_production_read_model_lag_explainability.v1" | string;
    network_requests: false;
    raw_payload_returned: false;
    raw_query_returned: false;
    raw_sql_returned: false;
    smoke_plan_contract: "admin_production_read_model_smoke_plan.v1" | string;
  };
  lag: {
    lag_seconds?: number | null;
    latest_request_created_at?: string | null;
    source: "postgres_request_logs" | string;
    staleness: "fresh" | "stale" | "very-stale" | "no-signal" | string;
  };
  next_step: string;
  omitted_fields: string[];
  postgres: {
    lag_seconds?: number | null;
    latest_completed_at?: string | null;
    latest_request_created_at?: string | null;
    raw_payload_returned: false;
    readback: "request_logs_safe_summary" | string;
    request_count: number;
    staleness: "fresh" | "stale" | "very-stale" | "no-signal" | string;
    status: "ready" | "empty" | string;
    tokenized_request_count: number;
  };
  schema: "admin_production_read_model_status.v1" | string;
  secret_safe: true;
  read_model_lag_explainability?: {
    backend_selection: {
      clickhouse_candidate: boolean;
      clickhouse_configured: boolean;
      clickhouse_connectivity_checked: false;
      clickhouse_live_result_present: false;
      decision_source: "clickhouse_config_presence_and_postgres_safe_readback" | string;
      fallback_backend: "postgres" | string;
      postgres_available: boolean;
      postgres_candidate: true;
      raw_backend_config_returned: false;
      selected_backend: "postgres" | "clickhouse" | "config-needed" | string;
    };
    forbidden_outputs: string[];
    lag_staleness_source: {
      clickhouse_lag_checked: false;
      lag_seconds?: number | null;
      latest_completed_at_present: boolean;
      latest_request_created_at_present: boolean;
      raw_payload_returned: false;
      raw_timestamp_query_returned: false;
      readback: "request_logs_safe_summary" | string;
      source: "postgres_request_logs_max_created_at" | string;
      staleness: "fresh" | "stale" | "very-stale" | "no-signal" | string;
    };
    safe_next_action: string;
    sample_query_plan_presence: {
      clickhouse_plan_present: boolean;
      postgres_plan_present: boolean;
      present: boolean;
      raw_payload_selected: false;
      raw_query_returned: false;
      raw_sql_returned: false;
      source: "request_logs_safe_summary" | string;
      tokenizer_plan_present: boolean;
    };
    schema: "admin_production_read_model_lag_explainability.v1" | string;
    secret_safe: true;
    status: "readback-present" | "no-signal" | string;
    tokenizer_config_presence: {
      backend_configured: boolean;
      config_path_configured: boolean;
      configured: boolean;
      model_configured: boolean;
      raw_tokenizer_config_returned: false;
      source: "configured_tokenizer_presence" | "provider_usage_token_columns" | string;
      tokenized_request_count: number;
    };
  };
  smoke_plan?: {
    backend: "postgres" | "clickhouse" | "config-needed" | string;
    clickhouse_connected: false;
    forbidden_outputs: string[];
    network_requests: false;
    next_step: string;
    operator_action_required: boolean;
    readback_expectations: {
      clickhouse_live_result_required_here: false;
      postgres_request_count: number;
      postgres_staleness: "fresh" | "stale" | "very-stale" | "no-signal" | string;
      postgres_tokenized_request_count: number;
      release_evidence_closure: false;
    };
    required_config_presence: {
      clickhouse_endpoint_configured: boolean;
      clickhouse_log_store_enabled: boolean;
      clickhouse_secret_presence?: {
        api_secret_present?: boolean;
        basic_secret_present?: boolean;
        basic_user_present?: boolean;
        bearer_header_present?: boolean;
        endpoint_userinfo_present?: boolean;
        redaction: "presence_only" | string;
      };
      raw_values_returned: false;
      tokenizer_backend_configured: boolean;
      tokenizer_config_path_configured: boolean;
      tokenizer_model_configured: boolean;
    };
    sample_query_plan: {
      clickhouse_readback: {
        database?: string | null;
        enabled_when: string;
        network_requests: false;
        query_text_returned: false;
        selected_fields: string[];
        table?: string | null;
      };
      postgres_readback: {
        filters: string[];
        raw_payload_selected: false;
        selected_fields: string[];
        table: "request_logs" | string;
      };
      source: "request_logs_safe_summary" | string;
      tokenizer_readback: {
        raw_tokenizer_config_returned: false;
        source: "configured_tokenizer_presence" | "provider_usage_token_columns" | string;
        status: string;
        tokenized_request_count: number;
      };
    };
    schema: "admin_production_read_model_smoke_plan.v1" | string;
    secret_safe: true;
    status: "ready-for-operator-smoke" | "readback-ready" | "blocked" | "config-needed" | string;
  };
  source: "control_plane_config_and_postgres_readback" | string;
  status: "ready" | "attention" | "config-needed" | "no-signal" | string;
  tenant_id: string;
  tokenizer_status: {
    backend_configured: boolean;
    config_path_configured: boolean;
    configured: boolean;
    model_configured: boolean;
    next_step: string;
    raw_tokenizer_config_returned: false;
    status: "configured" | "provider-usage-readback" | "config-needed" | "no-signal" | string;
    tokenized_request_count: number;
  };
};

export type EnterpriseIdentityMappingSummary = {
  configured: boolean;
  entry_count: number;
  values_returned: false;
};

export type EnterpriseIdentityConnection = {
  authorization_header_returned: false;
  client_secret_returned: false;
  config_needed: string[];
  mapped_groups: EnterpriseIdentityMappingSummary;
  mapped_roles: EnterpriseIdentityMappingSummary;
  metadata_url_present: boolean;
  next_step: string;
  provider_type: "oidc" | "saml" | string;
  raw_claims_returned: false;
  raw_tokens_or_assertions_returned: false;
  status: "disabled" | "config-needed" | "validation-pending" | string;
};

export type EnterpriseIdentityConnectionsReadback = {
  callback_exchange_boundary: {
    accepted_input_source: string;
    oidc_callback: {
      authorization_code_exchange_implemented: false;
      id_token_jwks_validation_implemented: false;
      network_request_attempted: false;
      path: string;
      session_creation_implemented: false;
      status: "plan_only_refusal" | string;
    };
    raw_material_echoed: false;
    rejected_input: string[];
    saml_acs: {
      path: string;
      saml_response_accepted: false;
      session_creation_implemented: false;
      status: "config-needed" | string;
      xml_signature_validation_implemented: false;
    };
    status: "rejected_until_real_validation" | string;
  };
  connections: EnterpriseIdentityConnection[];
  next_step: string;
  omitted_fields: string[];
  production_sso_verification_implemented: false;
  raw_tokens_or_assertions_accepted: false;
  runtime_implemented: true;
  schema: "enterprise_identity_connections_readback.v1" | string;
  secret_safe: true;
  status: "disabled" | "config-needed" | "validation-pending" | string;
  tenant_id: string;
};

export type EnterpriseIdentityProviderValidationPlan = {
  authorization_header_returned: false;
  callback_or_acs_enabled: false;
  certificate_or_private_key_returned: false;
  client_secret_returned: false;
  config_needed: string[];
  enabled: boolean;
  next_step: string;
  provider_specific: JsonValue;
  provider_type: "oidc" | "saml" | string;
  raw_tokens_or_assertions_accepted: false;
  role_group_mapping: {
    accepted_source: string;
    mapped_groups: EnterpriseIdentityMappingSummary;
    mapped_roles: EnterpriseIdentityMappingSummary;
    next_step: string;
    raw_claim_values_returned: false;
    status: "ready-for-validation" | "config-needed" | string;
  };
  session_creation_implemented: false;
  status: "disabled" | "config-needed" | "validation-pending" | string;
  validation_runtime_implemented: false;
};

export type EnterpriseIdentityValidationPlan = {
  callback_acs_boundary: {
    accepted_input_source: string;
    oidc_callback: {
      authorization_code_exchange_implemented: false;
      client_submitted_token_login_allowed: false;
      enabled_for_login: false;
      id_token_jwks_validation_implemented: false;
      path: string;
      session_creation_implemented: false;
    };
    raw_material_echoed: false;
    rejected_input: string[];
    saml_acs: {
      enabled_for_login: false;
      path: string;
      saml_response_accepted: false;
      session_creation_implemented: false;
      xml_signature_validation_implemented: false;
    };
    status: "disabled_until_real_validation" | string;
  };
  dry_run_only: true;
  network_requests: false;
  next_step: string;
  omitted_fields: string[];
  providers: EnterpriseIdentityProviderValidationPlan[];
  raw_tokens_or_assertions_accepted: false;
  schema: "enterprise_identity_validation_plan.v1" | string;
  secret_safe: true;
  session_creation_implemented: false;
  status: "disabled" | "config-needed" | "validation-pending" | string;
  tenant_id: string;
};

export type EnterpriseOidcValidateCodePlanRequest = {
  authorization_code_present?: boolean;
  authorization_code_sha256?: string;
  authorization_code_hash?: string;
  code_present?: boolean;
  fixture_claims_summary?: Record<string, JsonValue>;
  nonce_record_present?: boolean;
  pkce_verifier_present?: boolean;
  redirect_uri_present?: boolean;
  sample_claims_summary?: Record<string, JsonValue>;
  state_record_present?: boolean;
};

export type EnterpriseOidcValidateCodePlan = {
  authorization_code_exchange_plan: JsonValue;
  authorization_header_returned: false;
  client_secret_returned: false;
  dry_run_only: true;
  input_summary: {
    authorization_code_hash_present: boolean;
    authorization_code_present: boolean;
    fixture_claims_summary_present: boolean;
    nonce_record_present: boolean;
    pkce_verifier_present: boolean;
    raw_values_returned: false;
    redirect_uri_present: boolean;
    state_record_present: boolean;
  };
  jwks_fetched: false;
  jwks_validation_plan: JsonValue;
  network_requests: false;
  next_step: string;
  omitted_fields: string[];
  provider_type: "oidc";
  raw_claim_values_accepted: false;
  raw_tokens_accepted: false;
  schema: "enterprise_oidc_validate_code_plan.v1" | string;
  secret_safe: true;
  session_binding_plan: JsonValue;
  session_created: false;
  status: "ready-for-real-executor-implementation" | "plan-incomplete" | string;
  tenant_id: string;
  token_endpoint_called: false;
  user_identity_binding_plan: JsonValue;
};

export type EnterpriseOidcExecuteValidatedLoginRequest = {
  apply?: boolean;
  audience_client_id_present?: boolean;
  domain?: string;
  email?: string;
  expiration_valid?: boolean;
  external_subject_hash: string;
  issuer_present?: boolean;
  issued_at_checked?: boolean;
  jwks_validation?: {
    alg?: "RS256" | "ES256" | string;
    alg_allowlisted?: boolean;
    alg_present?: boolean;
    jwks_key_fingerprint_present?: boolean;
    key_metadata_present?: boolean;
    kid_matches_jwks_key?: boolean;
    kid_present?: boolean;
    signature_valid?: boolean;
    verified_subject_hash_source?:
      | "server_side_verified_id_token_sub_sha256"
      | "fixture_verified_subject_hash"
      | "verified_claims_summary_subject_hash"
      | "external_subject_hash_field"
      | string;
  };
  jwt_jwks_parser_fetch?: {
    alg?: "RS256" | "ES256" | string;
    audience?: string;
    crypto_parser?: {
      claims_audience?: string;
      claims_exp_unix?: number;
      claims_iat_unix?: number;
      claims_issuer_url?: string;
      claims_nonce_matches_request?: boolean;
      claims_nonce_present?: boolean;
      claims_subject_hash?: string;
      header_alg?: "RS256" | "ES256" | string;
      header_kid?: string;
      jwks_key_alg?: "RS256" | "ES256" | string;
      jwks_key_kid?: string;
      signature_verified?: boolean;
    };
    issuer?: string;
    issuer_url?: string;
    jwks_uri?: string;
    jwks_uri_ref?: string;
    kid?: string;
    nonce?: string;
    subject_hash?: string;
  };
  jwks_validation_result?: boolean;
  mapped_groups?: string[];
  mapped_roles?: string[];
  nonce_valid?: boolean;
  verified_claims_summary?: Record<string, JsonValue>;
};

export type EnterpriseOidcJwksValidatorExecutor = {
  authorization_header_accepted: false;
  binding_handoff_readiness: JsonValue;
  blocked_reasons: string[];
  client_secret_accepted: false;
  idp_network_called: false;
  identity_binding_handoff: JsonValue;
  jwks_fetched: false;
  jwks_or_jwk_body_accepted: false;
  mockable_executor: true;
  network_call_performed: false;
  network_enabled: false;
  next_step: string;
  omitted_fields: string[];
  private_key_or_certificate_accepted: false;
  provider_type: "oidc";
  raw_claims_accepted: false;
  raw_token_accepted: false;
  runtime_implemented: true;
  schema: "enterprise_oidc_jwks_validator_executor.v1" | string;
  secret_safe: true;
  session_issue_handoff: JsonValue;
  session_handoff_readiness: JsonValue;
  status: "validator-passed" | "validator-blocked" | string;
  tenant_id: string;
  validator_result: JsonValue;
};

export type EnterpriseOidcExecuteValidatedLogin = {
  authorization_header_accepted: false;
  binding_result: EnterpriseIdentityBindingPlan;
  client_secret_accepted: false;
  jwks_fetched: false;
  jwks_validation_result: true;
  jwks_validator: JsonValue;
  jwt_jwks_crypto_parser_result: JsonValue;
  jwt_jwks_parser_fetch_adapter: JsonValue;
  mockable_executor: true;
  network_requests: false;
  next_step: string;
  omitted_fields: string[];
  provider_type: "oidc";
  raw_claims_accepted: false;
  raw_code_accepted: false;
  raw_tokens_accepted: false;
  runtime_implemented: true;
  schema: "enterprise_oidc_validated_login_execution.v1" | string;
  secret_safe: true;
  server_side_simulated_input: true;
  session_blocked_reason: string;
  session_created: false;
  session_creation_disabled: true;
  status:
    | "binding-applied-session-disabled"
    | "binding-exists-session-disabled"
    | "ready-to-apply-session-disabled"
    | "local-user-not-found-session-disabled"
    | string;
  tenant_id: string;
  token_endpoint_called: false;
  verified_subject_hash_source: string;
  verified_claims_summary: {
    audience_client_id_present: boolean;
    domain?: string | null;
    email_present: boolean;
    expiration_valid: boolean;
    fixture_summary_present: boolean;
    issued_at_checked: boolean;
    issuer_present: boolean;
    mapped_group_count: number;
    mapped_role_count: number;
    nonce_valid: boolean;
    raw_claim_values_returned: false;
    raw_email_returned: false;
    raw_subject_returned: false;
    subject_hash_present: true;
  };
};

export type EnterpriseSamlValidateAcsPlanRequest = {
  assertion_hash?: string;
  assertion_hash_present?: boolean;
  assertion_present?: boolean;
  assertion_sha256?: string;
  audience_present?: boolean;
  certificate_fingerprint?: string;
  fixture_assertion_summary?: Record<string, JsonValue>;
  idp_certificate_fingerprint?: string;
  idp_certificate_sha256?: string;
  issuer_present?: boolean;
  metadata_summary?: Record<string, JsonValue>;
  metadata_url_present?: boolean;
  metadata_xml_present?: boolean;
  name_id_present?: boolean;
  sample_claims_summary?: Record<string, JsonValue>;
  saml_response_hash?: string;
  saml_response_hash_present?: boolean;
  saml_response_present?: boolean;
  saml_response_sha256?: string;
};

export type EnterpriseSamlValidateAcsPlan = {
  assertion_validation_plan: JsonValue;
  attribute_mapping_plan: JsonValue;
  authorization_header_returned: false;
  certificate_or_private_key_returned: false;
  dry_run_only: true;
  input_summary: {
    assertion_hash_present: boolean;
    assertion_present: boolean;
    attribute_summary_present: boolean;
    audience_present: boolean;
    fixture_assertion_summary_present: boolean;
    idp_certificate_fingerprint_present: boolean;
    issuer_present: boolean;
    metadata_summary_present: boolean;
    name_id_present: boolean;
    raw_values_returned: false;
    saml_response_hash_present: boolean;
    saml_response_present: boolean;
  };
  network_requests: false;
  next_step: string;
  omitted_fields: string[];
  provider_type: "saml";
  raw_assertion_accepted: false;
  raw_claim_values_accepted: false;
  raw_saml_response_accepted: false;
  schema: "enterprise_saml_validate_acs_plan.v1" | string;
  secret_safe: true;
  session_binding_plan: JsonValue;
  session_created: false;
  signature_verified: false;
  status: "ready-for-real-executor-implementation" | "plan-incomplete" | string;
  tenant_id: string;
  user_identity_binding_plan: JsonValue;
  xml_parsed: false;
  xml_signature_validation_plan: JsonValue;
};

export type EnterpriseSamlExecuteValidatedAcsRequest = {
  assertion_validation_result?: boolean;
  assertion_validator_input?: {
    issuer_present?: boolean;
    issuer_hash?: string;
    issuer_sha256?: string;
    entity_id_present?: boolean;
    entity_id_hash?: string;
    entity_id_sha256?: string;
    audience_present?: boolean;
    audience_hash?: string;
    audience_sha256?: string;
    audience_count?: number;
    name_id_hash_present?: boolean;
    name_id_hash?: string;
    name_id_sha256?: string;
    group_count?: number;
    role_count?: number;
    not_before_unix?: number;
    not_on_or_after_unix?: number;
    signature_verified?: boolean;
    attribute_mapping_summary?: {
      group_count?: number;
      role_count?: number;
      mapped_group_count?: number;
      mapped_role_count?: number;
      mapping_configured?: boolean;
    };
  };
  audience_validation_result?: boolean;
  apply?: boolean;
  external_subject_hash: string;
  fixture_assertion_summary?: Record<string, JsonValue>;
  issuer_validation_result?: boolean;
  metadata_trust?: {
    cert_fingerprint_prefix?: string;
    entity_id?: string;
    entity_id_present?: boolean;
    metadata_ref?: string;
    metadata_ref_present?: boolean;
    metadata_url?: string;
    metadata_url_present?: boolean;
    signature_alg?: string;
    trust_status?: string;
    valid_from_present?: boolean;
    valid_to_present?: boolean;
  };
  xml_signature_validation?: {
    signed_info_digest_present: boolean;
    canonicalization_alg?: string;
    signature_alg?: string;
    reference_digest_valid: boolean;
    signature_value_valid: boolean;
    cert_fingerprint_matches_metadata: boolean;
  };
  parsed_assertion_summary?: Record<string, JsonValue>;
  signature_validation_result: boolean;
  time_conditions_validation_result?: boolean;
  verified_assertion_summary?: Record<string, JsonValue>;
};

export type EnterpriseSamlExecuteValidatedAcs = {
  assertion_validator_result: JsonValue;
  authorization_header_returned: false;
  binding_result?: EnterpriseIdentityBindingPlan;
  binding_session_handoff_readiness: JsonValue;
  blocked_reasons: string[];
  certificate_or_private_key_returned: false;
  mock_executor: boolean;
  network_requests: false;
  next_step: string;
  omitted_fields: string[];
  provider_type: "saml";
  raw_assertion_accepted: false;
  raw_claim_values_accepted: false;
  raw_saml_response_accepted: false;
  role_group_mapping_result: JsonValue;
  runtime_implemented: true;
  saml_validator: JsonValue;
  schema: "enterprise_saml_execute_validated_acs.v1" | string;
  secret_safe: true;
  server_side_simulated_input_only: true;
  identity_binding_handoff: JsonValue;
  session_issue_handoff: JsonValue;
  session_binding: {
    blocked_reason: string;
    cookie_returned: false;
    session_created: false;
    session_creation_disabled: true;
  };
  signature_validation: JsonValue;
  status:
    | "binding-applied-session-disabled"
    | "binding-exists-session-disabled"
    | "ready-to-apply-session-disabled"
    | "local-user-not-found-session-disabled"
    | string;
  tenant_id: string;
  user_identity_binding_readback: EnterpriseIdentityBindingPlan;
  verified_assertion_summary: JsonValue;
  xml_parsed_by_this_endpoint: false;
};

export type EnterpriseIdentityBindingPlanRequest = {
  apply?: boolean;
  domain?: string;
  email?: string;
  external_subject_hash: string;
  fixture_subject_summary?: Record<string, JsonValue>;
  mapped_groups?: string[];
  mapped_roles?: string[];
  provider_type: "oidc" | "saml" | string;
};

export type EnterpriseIdentityBindingPlan = {
  apply_requested: boolean;
  audit_id?: string | null;
  dry_run: boolean;
  input_summary: {
    domain?: string | null;
    email_present: boolean;
    external_subject_hash_present: true;
    fixture_subject_summary_present: boolean;
    mapped_group_count: number;
    mapped_role_count: number;
    raw_email_returned: false;
    raw_group_or_role_values_returned: false;
    raw_subject_returned: false;
  };
  matched_user: {
    display_name_present: boolean;
    email_present: boolean;
    raw_email_returned: false;
    source: "email" | "user_identity" | "none" | string;
    status: "matched" | "not-found" | string;
    user_id?: string | null;
    user_status?: string;
  };
  next_step: string;
  omitted_fields: string[];
  provider_type: "oidc" | "saml" | string;
  readback_path: "POST /admin/enterprise/identity-bindings/plan" | string;
  role_group_mapping_result: JsonValue;
  runtime_implemented: true;
  schema: "enterprise_identity_binding_plan.v1" | string;
  secret_safe: true;
  session_binding: {
    cookie_returned: false;
    requires_completed_oidc_or_saml_validation: true;
    session_created: false;
    session_creation_disabled: true;
  };
  status:
    | "binding-applied"
    | "binding-exists"
    | "matched-local-user"
    | "ready-to-apply"
    | "local-user-not-found"
    | string;
  tenant_id: string;
  user_identity_binding: {
    applied: boolean;
    create_user_disabled: true;
    existing_binding: boolean;
    idempotent: true;
    identity_id?: string | null;
    lookup: "user_identities(provider, provider_subject, tenant_id)" | string;
    metadata_written: boolean;
    raw_claims_returned: false;
    raw_subject_returned: false;
    status: string;
    would_create_user: false;
  };
};

export type EnterpriseIdentitySessionIssuePlanRequest =
  | {
      apply?: boolean;
      idempotency_key?: string;
      user_identity_id: string;
      verified_by: "oidc_mock_executor" | "saml_mock_executor" | string;
    }
  | {
      apply?: boolean;
      external_subject_hash: string;
      idempotency_key?: string;
      provider_type: "oidc" | "saml" | string;
      user_id: string;
      verified_by: "oidc_mock_executor" | "saml_mock_executor" | string;
    };

export type EnterpriseIdentitySessionIssuePlan = {
  apply_requested: boolean;
  audit_id: string | null;
  dry_run: boolean;
  expires_at: string | null;
  input_summary: {
    external_subject_hash_present: boolean;
    lookup_mode: "user_identity_id" | "bound_subject" | string;
    provider_type?: "oidc" | "saml" | string;
    provider_type_present?: boolean;
    raw_subject_returned: false;
    idempotency_key_hash_present?: boolean;
    raw_idempotency_key_returned?: false;
    user_id?: string;
    user_id_present?: boolean;
    user_identity_id?: string | null;
    verified_by: "oidc_mock_executor" | "saml_mock_executor" | string;
  };
  next_step: string;
  omitted_fields: string[];
  provider_type: "oidc" | "saml" | string;
  readback: {
    audit_action: "enterprise_identity.session_issued" | "none" | string;
    audit_marker_written: boolean;
    audit_written: boolean;
    audit_readback_path: "GET /admin/audit-logs" | string;
    readback_path: "POST /admin/enterprise/identity-sessions/issue-plan" | string;
    session_created: boolean;
    session_creation_disabled: boolean;
    session_id: string | null;
    session_readback_path: string;
    user_identity_id: string | null;
    verified_by: "oidc_mock_executor" | "saml_mock_executor" | string | null;
    idempotency_key_fingerprint: string | null;
    raw_session_token_returned: false;
    raw_idempotency_key_returned: false;
  };
  role_group_mapping_summary: JsonValue;
  runtime_implemented: true;
  schema: "enterprise_identity_session_issue_plan.v1" | string;
  secret_safe: true;
  session_policy: {
    authorization_returned: false;
    bounded_session_creation_available: true;
    cookie_returned: false;
    idempotency_key_hash_present: boolean;
    raw_token_or_assertion_returned: false;
    raw_session_token_returned: false;
    raw_idempotency_key_returned: false;
    readback_source: "user_sessions" | "plan_only" | string;
    session_created: boolean;
    session_creation_disabled: boolean;
    session_creation_disabled_reason: string | null;
    session_id: string | null;
    session_status: string | null;
    session_expires_at: string | null;
    session_replayed: boolean;
    status: "active" | "not-created" | string;
    write_behavior: "bounded_user_session_insert" | "idempotent_replay" | "dry_run_only" | string;
  };
  status:
    | "identity-binding-not-found"
    | "bound-user-not-active"
    | "session-issue-ready"
    | "session-issued"
    | "session-replayed"
    | string;
  tenant_id: string;
  tenant_user_binding_summary: {
    create_user_disabled: true;
    matched_user: EnterpriseIdentityBindingPlan["matched_user"];
    tenant_boundary_enforced: true;
    tenant_id: string;
    user_identity: {
      external_subject_hash_present: boolean;
      identity_id?: string | null;
      lookup: string;
      provider_type: "oidc" | "saml" | string;
      raw_claims_returned: false;
      raw_subject_returned: false;
      status: "bound" | "not-found" | string;
    };
    would_create_user: false;
  };
  verified_by: "oidc_mock_executor" | "saml_mock_executor" | string;
  session_id: string | null;
};

export type EnterpriseAccountReadback = {
  account_name: string;
  account_owner?: string | null;
  account_owner_summary?: EnterpriseAccountContactSummary;
  account_slug: string;
  account_status?: "prospect" | "onboarding" | "trial" | "active" | "suspended" | "churn-risk" | "closed" | string;
  admin_dashboard?: EnterpriseAccountCompactAdminDashboard;
  admin_contact_summary?: EnterpriseAccountContactSummary;
  provisioning_or_invite_handoff?: EnterpriseProvisioningOrInviteHandoff;
  billing_readiness: {
    active_subscription_count: number;
    active_wallet_count: number;
    invoice_count: number;
    latest_subscription_status?: string | null;
    merchant_connected: false;
    next_step: string;
    pending_scheduler: true;
    raw_invoice_metadata_returned: false;
    raw_payment_payload_returned: false;
    receipt_count: number;
    status: "config-needed" | "plan-needed" | "runtime-records-pending" | "local-readback-ready" | string;
  };
  next_step: string;
  plan: {
    billing_interval?: string | null;
    currency?: string | null;
    display_name?: string | null;
    plan_code?: string | null;
    plan_id?: string | null;
    raw_plan_metadata_returned: false;
    source: "subscriptions_and_subscription_plans" | string;
    status: "active" | "pending" | "not-configured" | string;
    tier?: "not-configured" | "starter" | "team" | "business" | "enterprise" | "custom" | string;
    unit_price?: string | null;
  };
  quota_summary: {
    active_profile_count: number;
    active_project_count: number;
    active_virtual_key_count: number;
    authorization_header_returned: false;
    currency: string;
    monthly_spend_quota?: string | null;
    project_count: number;
    quota_limit?: number | null;
    quota_unit: "tokens_30d" | string;
    raw_request_payload_returned: false;
    request_count_30d: number;
    source: "request_logs_virtual_keys_profiles_projects" | string;
    spend_30d: string;
    status: "ready" | "attention" | "exhausted" | "config-needed" | string;
    success_count_30d: number;
    total_tokens_30d: number;
  };
  sales: {
    account_notes_present?: boolean;
    activity: EnterpriseSalesActivityReadback;
    crm_connected: boolean;
    external_crm_payload_returned: false;
    external_crm_adapter?: EnterpriseExternalCrmAdapterReadback;
    external_crm_sync_run?: EnterpriseCrmSyncRunReadback | {
      source: "enterprise_crm_sync_runs" | string;
      status: "not-run" | string;
      would_call: false;
      http_request_plan?: EnterpriseCrmHttpRequestPlan;
      http_executor_boundary?: EnterpriseCrmHttpExecutorBoundary;
      blocked_reason?: string | null;
      imported_activity_count: 0;
      updated_count: 0;
      skipped_count: 0;
      retry_policy_readback?: EnterpriseCrmRetryPolicyReadback;
      retry_attempt_readback?: EnterpriseCrmRetryAttemptReadback;
      rate_limit_handoff?: EnterpriseCrmRateLimitHandoff;
      retry_worker_handoff_summary?: EnterpriseCrmRetryWorkerHandoffSummary;
      network_requests_executed: false;
      secret_returned: false;
      authorization_header_returned: false;
      raw_external_payload_returned: false;
    };
    local_crm_adapter?: {
      adapter: "enterprise_sales_activities" | string;
      external_crm_connected: false;
      raw_external_payload_returned: false;
      tenant_scoped: true;
      write_path: "PATCH /admin/enterprise/accounts" | string;
    };
    local_metadata_write_path?: "PATCH /admin/enterprise/accounts" | string;
    next_action_reducer?: EnterpriseAccountNextActionReducer;
    next_step: string;
    source: "env_allowlist" | "tenant_metadata_allowlist" | string;
    stage:
      | "not-connected"
      | "lead"
      | "qualified"
      | "trial"
      | "negotiation"
      | "customer"
      | "churn-risk"
      | string;
  };
  seat_summary: {
    active_user_count: number;
    available_seats?: number | null;
    disabled_user_count: number;
    invited_user_count: number;
    project_member_count: number;
    raw_user_metadata_returned: false;
    seat_limit?: number | null;
    seats_used: number;
    source: "users_and_project_members" | string;
    user_count: number;
  };
  sso_readiness: {
    authorization_header_returned: false;
    client_secret_returned: false;
    identity_connections_path: "GET /admin/enterprise/identity-connections" | string;
    next_step: string;
    oidc_status: "disabled" | "config-needed" | "validation-pending" | string;
    production_sso_verification_implemented: false;
    raw_tokens_or_assertions_returned: false;
    saml_status: "disabled" | "config-needed" | "validation-pending" | string;
    status: "disabled" | "config-needed" | "validation-pending" | string;
  };
  tenant_id: string;
  tenant_name: string;
  tenant_slug: string;
  tenant_status: string;
  workspace_linkage?: EnterpriseWorkspaceLinkage;
};

export type EnterpriseAccountCompactAdminDashboard = {
  schema: "admin_enterprise_account_compact_dashboard.v1" | string;
  secret_safe: true;
  read_only: true;
  runtime_implemented: true;
  identity_readiness: {
    status: "disabled" | "config-needed" | "validation-pending" | string;
    oidc_status: "disabled" | "config-needed" | "validation-pending" | string;
    saml_status: "disabled" | "config-needed" | "validation-pending" | string;
    identity_connections_path: "GET /admin/enterprise/identity-connections" | string;
    oidc_mock_executor_path: "POST /admin/enterprise/identity-connections/oidc/execute-validated-login" | string;
    saml_mock_executor_path: "POST /admin/enterprise/identity-connections/saml/execute-validated-acs" | string;
    identity_binding_plan_path: "POST /admin/enterprise/identity-bindings/plan" | string;
    identity_session_issue_plan_path: "POST /admin/enterprise/identity-sessions/issue-plan" | string;
    mock_executor_binding_readback_only: true;
    production_sso_verification_implemented: false;
    raw_tokens_or_assertions_returned: false;
    authorization_header_returned: false;
    provider_secrets_returned: false;
  };
  sales_activity_next_action: {
    status: EnterpriseAccountNextActionReducer["status"];
    source: EnterpriseAccountNextActionReducer["source"];
    action: string;
    reason: string;
    owner?: string | null;
    due_at?: string | null;
    write_path: "PATCH /admin/enterprise/accounts" | string;
    network_requests_executed: false;
    raw_contact_returned: false;
    raw_email_returned: false;
    raw_external_payload_returned: false;
  };
  provisioning_invite_handoff: {
    status: EnterpriseProvisioningOrInviteHandoff["status"];
    provisioning_status: EnterpriseProvisioningOrInviteHandoff["provisioning_status"];
    invite_delivery_status: EnterpriseProvisioningOrInviteHandoff["invite_delivery_status"];
    next_action: string;
    plan_paths?: EnterpriseProvisioningOrInviteHandoff["plan_paths"];
    email_sent: false;
    external_email_provider_called: false;
    network_requests_executed: false;
  };
  crm_sync_status: {
    status: "not-run" | "running" | "completed" | "refused" | string;
    provider: "hubspot" | "salesforce" | "pipedrive" | "zoho" | "custom-http" | "not-configured" | string;
    retry_status: "not-attempted" | "scheduled" | "not_recommended" | "blocked" | string;
    retry_worker_handoff_summary?: EnterpriseCrmRetryWorkerHandoffSummary | JsonValue;
    readback_path: "GET /admin/enterprise/accounts" | string;
    write_path: "PATCH /admin/enterprise/accounts" | string;
    dashboard_readback_path: "GET /admin/enterprise/sales-dashboard" | string;
    network_requests_executed: false;
    raw_crm_payload_returned: false;
    authorization_header_returned: false;
    provider_secrets_returned: false;
  };
  local_readiness_summary: {
    billing_status: EnterpriseAccountReadback["billing_readiness"]["status"];
    quota_status: EnterpriseAccountReadback["quota_summary"]["status"];
    next_step: string;
  };
  omitted_fields: string[];
};

export type EnterpriseProvisioningOrInviteHandoff = {
  account_status: "prospect" | "onboarding" | "trial" | "active" | "suspended" | "churn-risk" | "closed" | "filtered-out" | string;
  audit_refs: {
    invite_delivery_audit_id?: string | null;
    invite_delivery_audit_ref_present: boolean;
    provisioning_apply_audit_id?: string | null;
    provisioning_apply_audit_ref_present: boolean;
    raw_metadata_returned: false;
    source: "audit_logs" | string;
  };
  invite_delivery_status:
    | "delivery_planned"
    | "send_required"
    | "no_invited_users"
    | "no_target_users"
    | "filtered-out"
    | string;
  local_record_refs: {
    invited_user_ref_present: boolean;
    project_member_ref_present: boolean;
    source: "tenants/projects/users/project_members" | "filtered" | string;
    tenant_id_present: boolean;
    user_ref_present: boolean;
    workspace_ref_present: boolean;
  };
  next_action: string;
  omitted_fields: string[];
  plan_paths?: {
    invite_delivery_apply: "POST /admin/enterprise/accounts/invite-delivery-apply" | string;
    invite_delivery_plan: "POST /admin/enterprise/accounts/invite-delivery-plan" | string;
    provisioning_apply: "POST /admin/enterprise/accounts/provisioning-apply" | string;
    provisioning_plan: "POST /admin/enterprise/accounts/provisioning-plan" | string;
    readback: "GET /admin/enterprise/accounts" | string;
  };
  provisioning_status: "applied" | "local_records_present_audit_missing" | "not_applied" | "filtered-out" | string;
  refusal_reason?: string | null;
  retry_reason?: string | null;
  schema: "admin_enterprise_provisioning_or_invite_handoff.v1" | string;
  secret_safe: true;
  side_effects: {
    crm_connected: false;
    email_sent: false;
    external_email_provider_called: false;
    network_requests_executed: false;
  };
  status: "readback-ready" | "action-required" | "blocked" | "filtered-out" | string;
};

export type EnterpriseAccountContactSummary = {
  email_domain?: string | null;
  hash_prefix?: string | null;
  present: boolean;
  raw_returned: false;
  sha256?: string | null;
};

export type EnterpriseWorkspaceLinkage = {
  active_workspace_count: number;
  create_path?: "POST /admin/enterprise/accounts" | string;
  project_metadata_returned: false;
  readback_path?: "GET /admin/enterprise/accounts" | string;
  recent_limit?: number;
  source: "projects" | string;
  status: "linked" | "not-linked" | string;
  tenant_scoped: true;
  workspace_count: number;
  workspaces: Array<{
    created_at: string;
    project_metadata_returned: false;
    source: "projects" | string;
    tenant_id: string;
    tenant_scoped: true;
    workspace_id: string;
    workspace_name: string;
    workspace_status: "active" | "disabled" | "archived" | "deleted" | string;
  }>;
};

export type EnterpriseExternalCrmAdapterReadback = {
  adapter_kind?: "hubspot" | "salesforce" | "pipedrive" | "zoho" | "custom-http" | string | null;
  adapter_readiness?: {
    adapter_kind: "hubspot" | "salesforce" | "pipedrive" | "zoho" | "custom-http" | "not-configured" | string;
    readiness: "ready-for-request-plan" | "blocked" | string;
    unsupported_reason?: string | null;
    blocked_reason?: string | null;
    network_requests_executed: false;
  };
  authorization_header_returned: false;
  blocked_reason?: string | null;
  crm_connected: boolean;
  disabled_at?: string | null;
  endpoint_ref_present: boolean;
  filtered_out?: boolean;
  id?: string;
  last_sync_marker?: string | null;
  last_sync_marker_present: boolean;
  network_requests_executed: false;
  provider?: "hubspot" | "salesforce" | "pipedrive" | "zoho" | "custom-http" | string | null;
  raw_external_payload_returned: false;
  readback_path?: "GET /admin/enterprise/accounts" | string;
  secret_ref_present: boolean;
  secret_returned: false;
  source: "enterprise_external_crm_adapters" | string;
  status: "enabled" | "disabled" | "not-configured" | string;
  sync_direction?: "read-only" | "write-only" | "bidirectional" | "webhook-only" | string | null;
  tenant_scoped?: true;
  typed_client_ready?: boolean;
  updated_at?: string;
  webhook_ref_present: boolean;
  write_path?: "PATCH /admin/enterprise/accounts" | string;
};

export type EnterpriseCrmSyncRunReadback = {
  adapter_id?: string | null;
  adapter_kind: "hubspot" | "salesforce" | "pipedrive" | "zoho" | "custom-http" | "not-configured" | string;
  adapter_request?: {
    adapter_kind: string;
    endpoint_ref_present: boolean;
    secret_ref_present: boolean;
    operation: string;
    direction: string;
    external_ids_hash_present: boolean;
    external_ids_hash?: string | null;
    sync_marker_present: boolean;
    sync_marker?: string | null;
    imported_activity_summary_present?: boolean;
  };
  adapter_result?: {
    would_call: boolean;
    blocked_reason?: string | null;
    imported_count: number;
    updated_count: number;
    skipped_count: number;
  };
  http_request_plan?: EnterpriseCrmHttpRequestPlan;
  http_executor_boundary?: EnterpriseCrmHttpExecutorBoundary;
  audit_id: string;
  authorization_header_returned: false;
  blocked_reason?: string | null;
  completed_at?: string | null;
  direction: "read-only" | "write-only" | "bidirectional" | "webhook-only" | string;
  endpoint_ref_present: boolean;
  external_ids_hash?: string | null;
  external_ids_hash_present: boolean;
  id: string;
  imported_activity?: EnterpriseSalesActivityItem | null;
  imported_activity_count: number;
  failed_count: number;
  network_requests_executed: false;
  operation: "sync-activities" | "import-activities" | "export-activities" | "webhook-readback" | string;
  provider: "hubspot" | "salesforce" | "pipedrive" | "zoho" | "custom-http" | "not-configured" | string;
  provider_response_parser?: EnterpriseCrmProviderResponseParser;
  provider_response_reducer?: EnterpriseCrmProviderResponseReducer;
  retry_policy_readback?: EnterpriseCrmRetryPolicyReadback;
  retry_attempt_readback?: EnterpriseCrmRetryAttemptReadback;
  rate_limit_handoff?: EnterpriseCrmRateLimitHandoff;
  retry_worker_handoff_summary?: EnterpriseCrmRetryWorkerHandoffSummary;
  raw_external_payload_returned: false;
  readback_path: "GET /admin/enterprise/accounts" | string;
  refused_reason?: string | null;
  runtime_implemented: true;
  secret_ref_present: boolean;
  secret_returned: false;
  source: "enterprise_crm_sync_runs" | string;
  started_at: string;
  status: "running" | "completed" | "refused" | string;
  sync_marker?: string | null;
  sync_marker_present: boolean;
  tenant_id: string;
  tenant_scoped: true;
  updated_count: number;
  skipped_count: number;
  would_call: boolean;
  write_path: "PATCH /admin/enterprise/accounts" | string;
};

export type EnterpriseCrmProviderResponseParser = {
  schema: "enterprise_crm_provider_response_parser.v1" | string;
  input_source: "external_crm_sync_run.provider_response_parser" | "external_crm_sync_run.provider_response_summary" | "fixture_safe_request_counts" | string;
  adapter_kind: "hubspot" | "salesforce" | "pipedrive" | "zoho" | "custom-http" | "not-configured" | string;
  provider: "hubspot" | "salesforce" | "pipedrive" | "zoho" | "custom-http" | "not-configured" | string;
  normalized_provider: "hubspot" | "salesforce" | "pipedrive" | "zoho" | "not-configured" | string;
  status: "not-provided" | "success" | "partial" | "rate-limited" | "provider-error" | "auth-error" | "blocked" | string;
  blocked: boolean;
  blocked_reason?: string | null;
  retry_after: {
    present: boolean;
    seconds?: number | null;
    raw_header_returned: false;
  };
  rate_limit: {
    present: boolean;
    reset_present: boolean;
    remaining_present: boolean;
    raw_headers_accepted: false;
    raw_headers_returned: false;
  };
  cursor: {
    present: boolean;
    next_cursor_hash_present: boolean;
    next_cursor_hash?: string | null;
    next_sync_marker_hash_present: boolean;
    next_sync_marker_hash?: string | null;
    raw_cursor_accepted: false;
    raw_cursor_returned: false;
  };
  external_id_counts: {
    total: number;
    created: number;
    updated: number;
    skipped: number;
  };
  result_counts: {
    imported: number;
    updated: number;
    skipped: number;
    failed: number;
  };
  provider_error: {
    present: boolean;
    category: "none" | "auth" | "permission" | "rate-limit" | "validation" | "not-found" | "conflict" | "server" | "unknown" | string;
  };
  safe_next_action: string;
  network_requests_executed: false;
  raw_response_body_accepted: false;
  raw_response_body_returned: false;
  raw_headers_accepted: false;
  raw_headers_returned: false;
  raw_payload_accepted: false;
  raw_external_payload_returned: false;
  raw_cursor_accepted: false;
  raw_cursor_returned: false;
  raw_endpoint_url_returned: false;
  authorization_header_returned: false;
  secret_returned: false;
};

export type EnterpriseCrmProviderResponseReducer = {
  schema: "enterprise_crm_provider_response_reducer.v1" | string;
  adapter_kind: "hubspot" | "salesforce" | "pipedrive" | "zoho" | "custom-http" | "not-configured" | string;
  provider: "hubspot" | "salesforce" | "pipedrive" | "zoho" | "custom-http" | "not-configured" | string;
  would_call: boolean;
  outcome: "succeeded" | "partial" | "failed" | "blocked" | string;
  blocked: boolean;
  blocked_reason?: string | null;
  imported_count: number;
  updated_count: number;
  skipped_count: number;
  failed_count: number;
  next_cursor_hash_present: boolean;
  next_cursor_hash?: string | null;
  next_sync_marker_hash_present: boolean;
  next_sync_marker_hash?: string | null;
  rate_limit: {
    present: boolean;
    reset_present: boolean;
    raw_headers_returned: false;
  };
  provider_error: {
    present: boolean;
    category?: "none" | "auth" | "permission" | "rate-limit" | "validation" | "not-found" | "conflict" | "server" | "unknown" | string | null;
  };
  input_source: "external_crm_sync_run.provider_response_summary" | "fixture_safe_request_counts" | string;
  network_requests_executed: false;
  raw_response_body_accepted: false;
  raw_response_body_returned: false;
  raw_external_payload_returned: false;
  raw_cursor_returned: false;
  authorization_header_returned: false;
  secret_returned: false;
  raw_endpoint_url_returned: false;
};

export type EnterpriseCrmRateLimitHandoff = {
  present: boolean;
  reset_at_present: boolean;
  next_retry_after_seconds?: number | null;
  raw_headers_returned: false;
  raw_reset_at_returned: false;
};

export type EnterpriseCrmRetryPolicyReadback = {
  schema: "enterprise_crm_retry_policy_readback.v1" | string;
  retry_recommended: boolean;
  next_retry_after_seconds?: number | null;
  reset_at_present: boolean;
  backoff_reason:
    | "none"
    | "provider_rate_limit"
    | "provider_server_error"
    | "provider_unknown_error"
    | "provider_credentials_or_permissions"
    | "provider_non_retryable_error"
    | "provider_item_failures"
    | "external_crm_adapter_disabled"
    | "external_crm_secret_ref_missing"
    | "external_crm_endpoint_ref_missing"
    | "external_crm_adapter_unsupported"
    | "external_crm_sync_run_not_requested"
    | "filtered_out"
    | string;
  max_attempts: number;
  operator_next_action: string;
  rate_limit_handoff: EnterpriseCrmRateLimitHandoff;
  network_requests_executed: false;
  raw_response_body_returned: false;
  raw_headers_returned: false;
  authorization_header_returned: false;
  secret_returned: false;
  raw_endpoint_url_returned: false;
  raw_cursor_returned: false;
};

export type EnterpriseCrmRetryAttemptReadback = {
  schema: "enterprise_crm_retry_attempt_readback.v1" | string;
  attempt_count: number;
  previous_attempt_count?: number;
  next_attempt_count?: number;
  max_attempts: number;
  next_retry_after_seconds?: number | null;
  reset_at_present: boolean;
  status: "scheduled" | "not_recommended" | "blocked" | string;
  attempt_status?: "attempted_local_marker" | "skipped_local_marker" | "attempt_blocked" | "skipped_blocked" | string;
  attempted_at?: string | null;
  operator_reason?: string | null;
  reason: string;
  idempotency_fingerprint: string;
  provider_response_summary_present: boolean;
  provider_response_parser_present: boolean;
  network_requests_executed: false;
  raw_response_body_returned: false;
  raw_headers_returned: false;
  authorization_header_returned: false;
  secret_returned: false;
  raw_endpoint_url_returned: false;
  raw_cursor_returned: false;
};

export type EnterpriseCrmRetryWorkerHandoffSummary = {
  schema: "enterprise_crm_retry_worker_handoff_summary.v1" | string;
  source: "enterprise_crm_sync_runs.metadata.retry_attempt_readback" | string;
  filtered_out?: boolean;
  scheduled_count: number;
  blocked_count: number;
  next_retry_after_seconds_min?: number | null;
  provider_counts: Record<string, Record<string, number>>;
  operator_next_actions: Array<{
    action: string;
    retry_marker_count: number;
  }>;
  status_counts: Record<string, number>;
  row_limit?: number;
  readback_path: "GET /admin/enterprise/accounts" | string;
  dashboard_readback_path: "GET /admin/enterprise/sales-dashboard" | string;
  worker_handoff_ready: boolean;
  tenant_scoped: boolean;
  cross_tenant?: boolean;
  read_only: true;
  network_requests_executed: false;
  authorization_header_returned: false;
  secret_returned: false;
  raw_endpoint_url_returned: false;
  raw_cursor_returned: false;
  raw_external_payload_returned: false;
};

export type EnterpriseCrmHttpExecutorBoundary = {
  schema: "enterprise_crm_http_executor_boundary.v1" | string;
  implementation: "network_disabled_request_builder_readback" | string;
  request_builder: {
    method: "GET" | "POST" | string;
    path_or_endpoint_ref: string;
    endpoint_ref_present: boolean;
    headers_required_presence: EnterpriseCrmHttpRequestPlan["headers_required_presence"];
    body_shape: EnterpriseCrmHttpRequestPlan["body_shape"];
    timeout: {
      connect_timeout_ms: number;
      request_timeout_ms: number;
      source: "bounded_default_readback" | string;
    };
    raw_endpoint_url_returned: false;
    authorization_header_returned: false;
    secret_returned: false;
    raw_request_body_returned: false;
    raw_external_payload_returned: false;
  };
  retry_summary: {
    retry_recommended: boolean;
    backoff_reason: string;
    max_attempts: number;
    next_retry_after_seconds?: number | null;
    reset_at_present: boolean;
    attempt_status: string;
    attempt_count: number;
  };
  network_enabled: false;
  network_call_performed: false;
  network_requests_executed: false;
  would_send_if_enabled: boolean;
  blocked: boolean;
  blocked_reason?: string | null;
  raw_response_body_returned: false;
  raw_headers_returned: false;
  raw_endpoint_url_returned: false;
  authorization_header_returned: false;
  secret_returned: false;
  raw_request_body_returned: false;
  raw_external_payload_returned: false;
};

export type EnterpriseCrmHttpRequestPlan = {
  adapter_kind: "hubspot" | "salesforce" | "pipedrive" | "zoho" | "custom-http" | "not-configured" | string;
  operation: "sync-activities" | "import-activities" | "export-activities" | "webhook-readback" | string;
  direction: "read-only" | "write-only" | "bidirectional" | "webhook-only" | string;
  method: "GET" | "POST" | string;
  path_or_endpoint_ref: string;
  endpoint_ref_present: boolean;
  headers_required_presence: {
    authorization: boolean;
    authorization_secret_ref_present: boolean;
    content_type_json: boolean;
    provider_version_header: boolean;
    raw_header_values_returned: false;
  };
  body_shape: {
    kind: "query_or_marker_summary" | "activity_write_summary" | string;
    fields: string[];
    external_ids_hash_present: boolean;
    sync_marker_present: boolean;
    imported_activity_summary_present: boolean;
    raw_body_returned: false;
    raw_external_payload_returned: false;
  };
  idempotency_fingerprint: string;
  would_send: boolean;
  would_call?: boolean;
  blocked: boolean;
  blocked_reason?: string | null;
  network_requests_executed: false;
  raw_endpoint_url_returned: false;
  authorization_header_returned: false;
  secret_returned: false;
  raw_external_payload_returned: false;
};

export type EnterpriseSalesActivityItem = {
  activity_type: "call" | "email" | "demo" | "followup" | "meeting" | "note" | "task" | "stage-change" | "renewal-review" | string;
  created_at: string;
  due_at?: string | null;
  external_crm_connected?: false;
  id: string;
  next_action?: string | null;
  occurred_at: string;
  outcome?: "connected" | "left-message" | "no-response" | "interested" | "not-interested" | "demo-scheduled" | "demo-completed" | "followup-required" | "blocked" | "closed-won" | "closed-lost" | string | null;
  owner?: string | null;
  owner_marker?: string | null;
  raw_contact_email_returned?: false;
  raw_external_payload_returned: false;
  readback_path?: "GET /admin/enterprise/accounts" | string;
  status: "open" | "planned" | "completed" | "cancelled" | string;
  summary: string;
  tenant_id?: string;
  tenant_scoped?: true;
};

export type EnterpriseSalesActivityReadback = {
  activity_count?: number;
  external_crm_connected?: false;
  filtered_out?: boolean;
  last_contact_at?: string | null;
  next_action?: string | null;
  next_action_due_at?: string | null;
  raw_contact_email_returned?: false;
  raw_external_payload_returned: false;
  recent: EnterpriseSalesActivityItem[];
  recent_limit?: number;
  source: "enterprise_sales_activities" | string;
  tenant_scoped?: true;
  write_path?: "PATCH /admin/enterprise/accounts" | string;
};

export type EnterpriseAccountNextActionReducer = {
  schema: "enterprise_account_next_action_reducer.v1" | string;
  status: "action-required" | "config-needed" | "blocked" | "ready-for-local-marker" | "readback-ready" | string;
  source:
    | "enterprise_sales_activities"
    | "tenant_metadata_allowlist"
    | "enterprise_external_crm_adapters"
    | "enterprise_crm_sync_runs"
    | "local_enterprise_account_readback"
    | string;
  action: string;
  reason: string;
  due_at?: string | null;
  recomputed?: true;
  recompute_source?: "enterprise_account_next_action_reducer" | string;
  readback_path: "GET /admin/enterprise/accounts" | string;
  write_path: "PATCH /admin/enterprise/accounts" | string;
  network_requests_executed: false;
  raw_contact_returned: false;
  raw_email_returned: false;
  raw_external_payload_returned: false;
  raw_idempotency_key_returned: false;
};

export type EnterpriseAccountsReadback = {
  accounts: EnterpriseAccountReadback[];
  crm_connected: false;
  external_sales_system_connected: false;
  filtered_out_count?: number;
  filters?: {
    billing_status?: string | null;
    sales_stage?: string | null;
    sso_status?: string | null;
    supported?: {
      billing_status: string[];
      sales_stage: string[];
      sso_status: string[];
    };
  };
  next_step: string;
  omitted_fields: string[];
  runtime_implemented: true;
  schema: "admin_enterprise_accounts_readback.v1" | string;
  secret_safe: true;
  status: "customer-ready" | "trial-ready" | "attention" | "config-needed" | string;
  tenant_id: string;
};

export type EnterpriseAccountsFilters = {
  billing_status?: string;
  sales_stage?: string;
  sso_status?: string;
};

export type PatchEnterpriseAccountRequest = {
  account_status?: "prospect" | "onboarding" | "trial" | "active" | "suspended" | "churn-risk" | "closed" | string;
  admin_contact_email?: string;
  account_name?: string;
  account_notes?: string;
  account_owner?: string;
  account_slug?: string;
  plan_tier?: "not-configured" | "starter" | "team" | "business" | "enterprise" | "custom" | string;
  monthly_spend_quota?: string;
  monthly_token_quota?: number;
  external_crm_adapter?: {
    provider: "hubspot" | "salesforce" | "pipedrive" | "zoho" | "custom-http" | string;
    status: "enabled" | "disabled" | string;
    endpoint_ref_present?: boolean;
    secret_ref_present?: boolean;
    webhook_ref_present?: boolean;
    sync_direction?: "read-only" | "write-only" | "bidirectional" | "webhook-only" | string;
    last_sync_marker?: string;
  };
  external_crm_sync_run?: {
    retry_attempt_mode?: "plan" | "mark_attempted" | "mark_skipped" | string;
    operator_reason?: string;
    operation?: "sync-activities" | "import-activities" | "export-activities" | "webhook-readback" | string;
    direction?: "read-only" | "write-only" | "bidirectional" | "webhook-only" | string;
    external_ids_hash?: string;
    sync_marker?: string;
    updated_count?: number;
    skipped_count?: number;
    provider_response_summary?: {
      imported_count?: number;
      updated_count?: number;
      skipped_count?: number;
      failed_count?: number;
      next_cursor_hash?: string;
      next_sync_marker_hash?: string;
      rate_limit_present?: boolean;
      rate_limit_reset_present?: boolean;
      provider_error_category?: "none" | "auth" | "permission" | "rate-limit" | "validation" | "not-found" | "conflict" | "server" | "unknown" | string;
    };
    provider_response_parser?: {
      status?: "not-provided" | "success" | "partial" | "rate-limited" | "provider-error" | "auth-error" | "blocked" | string;
      retry_after_seconds?: number;
      rate_limit_present?: boolean;
      rate_limit_reset_present?: boolean;
      rate_limit_remaining_present?: boolean;
      cursor_present?: boolean;
      imported_count?: number;
      updated_count?: number;
      skipped_count?: number;
      failed_count?: number;
      external_id_count?: number;
      external_id_created_count?: number;
      external_id_updated_count?: number;
      external_id_skipped_count?: number;
      next_cursor_hash?: string;
      next_sync_marker_hash?: string;
      provider_error_category?: "none" | "auth" | "permission" | "rate-limit" | "validation" | "not-found" | "conflict" | "server" | "unknown" | string;
      safe_next_action?: string;
    };
    imported_activity_summary?: {
      activity_type: "call" | "email" | "demo" | "followup" | "meeting" | "note" | "task" | "stage-change" | "renewal-review" | string;
      due_at?: string;
      external_reference_hash?: string;
      next_action?: string;
      occurred_at?: string;
      outcome?: "connected" | "left-message" | "no-response" | "interested" | "not-interested" | "demo-scheduled" | "demo-completed" | "followup-required" | "blocked" | "closed-won" | "closed-lost" | string;
      owner?: string;
      status?: "open" | "planned" | "completed" | "cancelled" | string;
      summary: string;
    };
  };
  sales_activity?: {
    activity_type: "call" | "email" | "demo" | "followup" | "meeting" | "note" | "task" | "stage-change" | "renewal-review" | string;
    due_at?: string;
    external_reference_hash?: string;
    next_action?: string;
    occurred_at?: string;
    outcome?: "connected" | "left-message" | "no-response" | "interested" | "not-interested" | "demo-scheduled" | "demo-completed" | "followup-required" | "blocked" | "closed-won" | "closed-lost" | string;
    owner?: string;
    status?: "open" | "planned" | "completed" | "cancelled" | string;
    summary: string;
  };
  sales_stage?: string;
  seat_limit?: number;
};

export type CreateEnterpriseAccountRequest = Omit<
  PatchEnterpriseAccountRequest,
  "external_crm_adapter" | "external_crm_sync_run"
> & {
  ensure_default_workspace?: boolean;
  workspace_name?: string;
};

export type EnterpriseAccountMetadataUpdate = {
  accepted_fields: string[];
  account: {
    account_status?: string;
    account_name_present: boolean;
    account_notes_present: boolean;
    account_owner_present: boolean;
    account_owner_summary?: EnterpriseAccountContactSummary;
    account_slug_present: boolean;
    admin_contact_summary?: EnterpriseAccountContactSummary;
    monthly_spend_quota_present: boolean;
    monthly_token_quota_present: boolean;
    plan_tier?: string;
    raw_notes_returned: false;
    sales_stage: string;
    seat_limit_present: boolean;
    secret_safe: true;
    tenant_metadata_fields_returned: false;
  };
  audit_id: string;
  crm_connected: false;
  external_sales_system_connected: false;
  next_step: string;
  omitted_fields: string[];
  readback_path: "GET /admin/enterprise/accounts" | string;
  runtime_implemented: true;
  schema: "admin_enterprise_account_metadata_update.v1" | string;
  secret_safe: true;
  sales_activity?: EnterpriseSalesActivityItem | null;
  external_crm_adapter?: EnterpriseExternalCrmAdapterReadback | null;
  external_crm_sync_run?: EnterpriseCrmSyncRunReadback | null;
  status: "updated" | string;
  tenant_id: string;
  updated_fields: string[];
};

export type EnterpriseAccountLifecycleCreate = {
  accepted_fields: string[];
  account: EnterpriseAccountMetadataUpdate["account"];
  audit_id: string;
  next_step: string;
  omitted_fields: string[];
  patch_path: "PATCH /admin/enterprise/accounts" | string;
  readback_path: "GET /admin/enterprise/accounts" | string;
  runtime_implemented: true;
  schema: "admin_enterprise_account_lifecycle_create.v1" | string;
  secret_safe: true;
  sales_activity?: EnterpriseSalesActivityItem | null;
  status: "created-or-updated" | "unchanged" | string;
  tenant_id: string;
  tenant_scoped: true;
  updated_fields: string[];
  workspace?: EnterpriseWorkspaceLinkage["workspaces"][number] | null;
};

export type EnterpriseAccountProvisioningRequest = {
  admin_contact_email: string;
  idempotency_key: string;
  owner_contact_email?: string;
  plan_tier: "not-configured" | "starter" | "team" | "business" | "enterprise" | "custom" | string;
  sales_stage: "not-connected" | "lead" | "qualified" | "trial" | "negotiation" | "customer" | "churn-risk" | string;
  tenant_name: string;
  tenant_slug: string;
  workspace_name: string;
};

export type EnterpriseAccountProvisioningPlan = {
  admin_invite: {
    admin_contact_summary: EnterpriseAccountContactSummary;
    email_delivery: "not_attempted" | string;
    local_user_exists: boolean;
    owner_contact_summary: EnterpriseAccountContactSummary;
    raw_email_returned: false;
    source: "users/project_members" | string;
    would_create: boolean;
    would_update: boolean;
  };
  admin_only: true;
  apply_path: "POST /admin/enterprise/accounts/provisioning-apply" | string;
  audit_id?: string | null;
  db_effects: {
    apply_writes: string[];
    bounded_marker_only: boolean;
    email_sent: false;
    would_create: Record<string, boolean>;
    would_update: Record<string, boolean>;
  };
  idempotency: {
    fingerprint: string;
    hash_returned: false;
    marker_exists: boolean;
    marker_source: string;
    raw_key_returned: false;
    replay_safe: true;
  };
  metadata_diff: Record<string, boolean>;
  mode: "dry_run" | "apply" | "replay" | string;
  next_step: string;
  omitted_fields: string[];
  operator_tenant_id: string;
  plan_path: "POST /admin/enterprise/accounts/provisioning-plan" | string;
  plan_tier: string;
  readback_path: "GET /admin/enterprise/accounts" | string;
  runtime_implemented: true;
  sales_stage: string;
  schema: "admin_enterprise_account_provisioning_plan.v1" | string;
  secret_safe: true;
  status: "planned" | "applied" | "replayed" | string;
  target_tenant_id?: string | null;
  tenant: {
    exists: boolean;
    existing_status?: string | null;
    source: "tenants" | string;
    tenant_name: string;
    tenant_slug: string;
    would_create: boolean;
    would_update: boolean;
  };
  workspace: {
    exists: boolean;
    source: "projects" | string;
    workspace_name: string;
    would_create: boolean;
    would_update: boolean;
  };
};

export type EnterpriseInviteDeliveryRequest = {
  delivery_request_id?: string;
  idempotency_key?: string;
  target_user_email?: string;
  target_user_id?: string;
  tenant_id?: string;
  tenant_slug?: string;
  workspace_id?: string;
  workspace_name?: string;
};

export type EnterpriseInviteDeliveryPlan = {
  admin_only: true;
  apply_path: "POST /admin/enterprise/accounts/invite-delivery-apply" | string;
  audit_id?: string | null;
  blocked_reasons: string[];
  db_effects: {
    apply_writes: string[];
    bounded_marker_only: true;
    creates_or_updates_project_members: false;
    creates_or_updates_users: false;
    email_sent: false;
    plan_writes: string[];
  };
  delivery_adapter: {
    email_sent: false;
    external_provider_status: "no_provider" | string;
    mode: "local_only" | string;
    provider_request_created: false;
    raw_contact_returned: false;
    raw_email_returned: false;
  };
  delivery_adapter_readiness: "local_only" | "blocked" | "no_provider" | string;
  idempotency: {
    fingerprint: string;
    hash_returned: false;
    marker_audit_id?: string | null;
    marker_exists: boolean;
    marker_source: string;
    raw_key_returned: false;
    replay_safe: true;
  };
  idempotency_fingerprint: string;
  invite_status: "send_required" | "delivery_planned" | "already_exists" | "blocked" | "no_target_users" | string;
  mode: "dry_run" | "apply" | "replay" | string;
  next_step: string;
  omitted_fields: string[];
  operator_tenant_id: string;
  plan_path: "POST /admin/enterprise/accounts/invite-delivery-plan" | string;
  readback_path: "POST /admin/enterprise/accounts/invite-delivery-plan" | string;
  runtime_implemented: true;
  schema: "admin_enterprise_invite_delivery_plan.v1" | string;
  secret_safe: true;
  status: "planned" | "replayed" | string;
  target_user_refs: JsonValue[];
  tenant_ref: JsonValue;
  workspace_ref: JsonValue;
  would_send: boolean;
};

export type HealthSummaryFilters = {
  sample_limit?: number;
  window_minutes?: number;
};

export type ServiceName = "gateway" | "controlPlane" | "mockProvider";

export type ErrorEnvelope = {
  data?: unknown;
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

export type ImporterMappingQualityReadback = {
  authorization_returned: false;
  conflicts: {
    blocking_count: number;
    count: number;
    refs: JsonValue[];
  };
  db_url_returned: false;
  dry_run_only: true;
  forbidden_material_returned?: false;
  mapping_counts: {
    canonical_model_candidates?: number;
    channel_mappings: number;
    conflicts: number;
    key_mappings: number;
    model_mappings: number;
    non_migratable_items?: number;
    provider_key_handoffs?: number;
    provider_mappings: number;
    subscription_mappings: number;
    user_key_reissue_handoffs?: number;
    user_mappings: number;
    wallet_mappings: number;
    [key: string]: number | undefined;
  };
  non_migratable_reasons: JsonValue[];
  operator_handoff_refs_presence: {
    provider_key_handoff_refs_present: boolean;
    provider_key_handoffs_present: boolean;
    required_operator_path_present: boolean;
    subscription_mapping_refs_present: boolean;
    user_key_reissue_refs_present: boolean;
    wallet_opening_balance_refs_present: boolean;
  };
  raw_provider_key_returned: false;
  raw_sql_returned: false;
  raw_user_key_returned: false;
  safe_next_action: string;
  schema_version: "importer.mapping-quality-readback.v1" | string;
  secret_safe: true;
  source_system: string;
  status: string;
  token_returned: false;
};

export type JsonRequestOptions = Omit<RequestInit, "body" | "signal"> & {
  baseUrl?: string;
  body?: unknown;
  signal?: AbortSignal;
  timeoutMs?: number;
};

export type RequestLogListFilters = {
  api_key_profile_id?: string;
  canonical_model_id?: string;
  channel_id?: string;
  created_from?: string;
  created_to?: string;
  cursor?: string;
  error_code?: string;
  error_type?: string;
  limit?: number;
  model?: string;
  page?: number;
  resolved_channel_id?: string;
  sort_dir?: "asc" | "desc";
  sort_key?: string;
  status?: string;
  stream?: boolean | string;
  trace_id?: string;
  virtual_key_id?: string;
};

export type AdminRequestLogsPage = {
  items: RequestLogSummary[];
  pagination: {
    cursor?: string | null;
    has_more?: boolean | null;
    limit: number;
    next_cursor?: string | null;
    page?: number | null;
    sort_dir?: "asc" | "desc";
    sort_key?: string | null;
    total?: number | null;
    unsupported?: boolean;
    unsupported_reason?: string;
  };
};

export const adminRequestLogsExportCsvContract = {
  schema_version: "admin_request_logs_export_csv.v1",
  content_type: "text/csv",
  audit_action: "request_logs.export_csv",
  primary_acceptance_surface: false,
  export_audit_readback: {
    schema: "admin_request_logs_export_audit_readback.v1",
    audit_action: "request_logs.export_csv",
    audit_readback_path: "GET /admin/audit-logs?action=request_logs.export_csv",
    audit_id_ref_present: false,
    redaction_policy: "metadata_only_safe_summary_columns",
    filtered_row_count_field: "filtered_row_count",
    safe_next_action:
      "Read Audit Logs for action=request_logs.export_csv and compare filtered_row_count plus allowed_columns; use request detail or trace summary for row-level troubleshooting.",
  },
  allowed_columns: [
    "request_id",
    "created_at",
    "completed_at",
    "status",
    "http_status",
    "requested_model",
    "canonical_model_id",
    "channel_id",
    "virtual_key_id",
    "api_key_profile_id",
    "trace_id",
    "client_request_id",
    "stream",
    "latency_ms",
    "ttft_ms",
    "input_tokens",
    "output_tokens",
    "final_cost",
    "currency",
    "error_owner",
    "error_code",
    "redaction_status",
  ],
  forbidden_columns: [
    "prompt",
    "messages",
    "raw_request_payload",
    "raw_response_payload",
    "raw_provider_payload",
    "raw_route_decision_snapshot",
    "provider_response",
    "provider_key",
    "provider_key_id",
    "provider_secret",
    "api_key_secret",
    "authorization",
    "cookie",
    "raw_payload",
    "raw_route_snapshot",
  ],
} as const;

export type AdminRequestLogsExportCsvColumn =
  (typeof adminRequestLogsExportCsvContract.allowed_columns)[number];

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
  mock_contract?: string;
  model: string;
  operation?: string;
  path: string;
  protocol_mode: string;
};

export type ChannelManualTestExplainability = {
  config_needed: string[];
  endpoint_capability: {
    capabilities: EndpointCapability[];
    method: "POST" | string;
    mock_contract?: string | null;
    operation?: string | null;
    path_template: string;
    raw_endpoint_returned: false;
    raw_payload_returned: false;
  };
  execution_mode: "dry_run_only" | string;
  live_status: string;
  mock_status: string;
  omitted_secret_policy: {
    authorization_header_returned: false;
    omitted_fields: string[];
    policy: "presence_and_status_only" | string;
    provider_key_fingerprint_returned: false;
    provider_key_returned: false;
    provider_key_secret_returned: false;
    raw_endpoint_returned: false;
    raw_payload_returned: false;
  };
  protocol: string;
  provider_key_lifecycle_summary: {
    authorization_returned: false;
    enabled_provider_key_present: boolean;
    fingerprint_returned: false;
    secret_available_to_runtime: boolean;
    secret_returned: false;
    summary: string;
  };
  safe_next_action: string;
  schema: "channel_manual_test_explainability.v1" | string;
  secret_safe: true;
  status: string;
};

export type ChannelManualTestResponse = {
  billing: ChannelManualTestBilling;
  channel: ChannelManualTestChannel;
  credential_material: {
    authorization_header?: "omitted" | string;
    configured?: boolean;
    provider_key_secret: "omitted" | string;
    secret_fingerprint: "omitted" | string;
  };
  dry_run: true;
  endpoint_capabilities?: EndpointCapabilitiesReadback;
  manual_test_explainability?: ChannelManualTestExplainability;
  next_step?: string;
  next_steps: string[];
  protocol?: string;
  protocol_readiness?: ProtocolReadinessReadback;
  provider: ChannelManualTestProvider;
  requested_model: string;
  request_plan: ChannelManualTestRequestPlan;
  status?: "contract-ready" | "config-needed" | "unknown" | string;
  test_mode: "channel_manual_test" | string;
  upstream_call: false;
  upstream_model: string;
};

export type CanonicalModelStatus = "active" | "disabled" | "deleted" | string;

export type CanonicalModel = {
  capabilities: JsonValue;
  context_length?: number | null;
  default_price_book_id?: string | null;
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
  default_price_book_id?: string | null;
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
  metadata?: JsonValue | null;
  outbound_protocol?: string | null;
  output_tokens: number;
  partial_sent: boolean;
  project_id?: string | null;
  protocol_mode?: string | null;
  provider_protocol_summary?: RequestProviderProtocolSummary | null;
  provider_key_id?: string | null;
  openai_compat?: GatewayOpenAiCompatProjection | null;
  redaction_status: string;
  request_body_hash?: string | null;
  rate_limit_metadata?: RequestRateLimitMetadata | null;
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
  stream_finalizer?: RequestStreamFinalizerProjection | null;
  tenant_id: string;
  thread_id?: string | null;
  trace_id?: string | null;
  ttft_ms?: number | null;
  upstream_model?: string | null;
  virtual_key_id?: string | null;
};

export type GatewayOpenAiCompatProjection = {
  choices_count?: number | null;
  done_sent?: boolean | null;
  endpoint?: string | null;
  final_chunk?: string | null;
  finish_reason_present?: boolean | null;
  finish_reasons?: Array<string | null> | null;
  input_tokens_recorded?: boolean | null;
  mode?: "stream" | "non_stream" | string | null;
  model?: string | null;
  object?: string | null;
  output_tokens_recorded?: boolean | null;
  provider_usage_present?: boolean | null;
  request_id_header_present?: boolean | null;
  response_body_hash?: string | null;
  response_id?: string | null;
  response_id_present?: boolean | null;
  schema: string;
  secret_safe?: boolean;
  source_schema?: string | null;
  status: "recorded" | "config-needed" | "not_recorded" | string;
  type?: string | null;
  usage_present?: boolean | null;
  usage_recorded?: boolean | null;
  x_request_id?: string | null;
};

export type RequestStreamFinalizerProjection = {
  billing_eligible?: boolean | null;
  concurrency_release?: string | null;
  end_reason?: string | null;
  partial_sent?: boolean | null;
  reserve_release_reason?: string | null;
  schema: string;
  secret_safe?: boolean;
  source_schema?: string | null;
  status: "recorded" | "config-needed" | "not_recorded" | string;
  ttft_ms?: number | null;
  usage_observed?: boolean | null;
  usage_recorded?: boolean | null;
};

export type RequestProviderProtocolSummary = {
  completion_tokens?: number | null;
  downstream_protocol?: string | null;
  end_reason?: string | null;
  end_reason_present?: boolean | null;
  finish_reason_present?: boolean | null;
  prompt_tokens?: number | null;
  provider_protocol?: string | null;
  schema: string;
  secret_safe?: boolean;
  source_schema?: string | null;
  status: "recorded" | "config-needed" | "not_recorded" | string;
  total_tokens?: number | null;
  usage_observed?: boolean | null;
  usage_recorded?: boolean | null;
};

export type RequestRateLimitDimensionMetadata = {
  limit?: number | null;
  remaining?: number | null;
  required?: number | null;
  retry_after_ms?: number | null;
  scope?: string | null;
  status:
    | "ok"
    | "limited"
    | "not_applied"
    | "configured"
    | "not_configured"
    | "not_recorded"
    | string;
  used?: number | null;
  window_seconds?: number | null;
  window_status?:
    | "summary_only"
    | "not_windowed"
    | "not_recorded"
    | "not_configured"
    | string;
};

export type RequestRateLimitMetadata = {
  concurrency: RequestRateLimitDimensionMetadata;
  retry_after_ms?: number | null;
  rpm: RequestRateLimitDimensionMetadata;
  schema: string;
  scope?: string | null;
  secret_safe?: boolean;
  source_schema?: string | null;
  status: "ok" | "limited" | "not_checked" | "not_recorded" | string;
  tpm: RequestRateLimitDimensionMetadata;
  window_status?: "summary_only" | "not_windowed" | "not_recorded" | string;
};

export type RequestUsageTokenSource = {
  adapter_usage?: boolean;
  recorded: boolean;
  safe_mismatch_reason?: string | null;
  source:
    | "adapter_usage_projection"
    | "gateway_request_log_fallback"
    | "not_recorded"
    | string;
  tokens?: number | null;
};

export type RequestUsageExplainability = {
  adapter_usage: {
    observed: boolean;
    recorded: boolean;
    source: "adapter_usage_projection" | "not_observed" | string;
  };
  endpoint: {
    downstream_protocol?: string | null;
    inbound_protocol?: string | null;
    openai_compat_endpoint?: string | null;
    outbound_protocol?: string | null;
    protocol_mode?: string | null;
    provider_protocol?: string | null;
    requested_model_present?: boolean;
    upstream_model_present?: boolean;
  };
  gateway_fallback: {
    source: "request_logs_token_columns" | "not_used" | string;
    used: boolean;
  };
  ledger: {
    confirmed_ref_present: boolean;
    entry_count: number;
    ref_present: boolean;
    source: "ledger_entries_by_request_id" | string;
  };
  omitted_fields?: string[];
  provider_attempts: {
    count: number;
    fallback_attempt_present: boolean;
    token_sum: number;
    usage_present: boolean;
  };
  rating: {
    currency?: string | null;
    final_cost?: string | null;
    price_version_ref_present: boolean;
    status:
      | "rated_and_ledger_ref_present"
      | "ledger_ref_present_rating_ref_partial"
      | "not_rated_or_zero_cost"
      | "rated_without_ledger_ref"
      | string;
  };
  safe_mismatch_reasons: string[];
  schema: "admin_request_usage_explainability_v1" | string;
  secret_safe?: boolean;
  source: "request_log_detail_safe_read_model" | string;
  tokens: {
    cache: RequestUsageTokenSource;
    completion: RequestUsageTokenSource;
    embedding: RequestUsageTokenSource;
    prompt: RequestUsageTokenSource;
    reasoning: RequestUsageTokenSource;
  };
};

export type RequestPreauthorizeRateLimitExplainability = {
  fallback_or_reject: {
    billing_refusal_reason?: string | null;
    fallback_present: boolean;
    fallback_reasons: string[];
    reject_reason?: string | null;
    route_fallback_reason?: string | null;
    route_reject_reason?: string | null;
  };
  ledger_refs: {
    any_ledger_ref_present: boolean;
    entry_count: number;
    reservation_ref_present: boolean;
    settle_ref_present: boolean;
    source: "ledger_entries_by_request_id" | string;
  };
  omitted_fields?: string[];
  preauthorize: {
    balance: {
      amount_omitted?: boolean;
      source: string;
      status: string;
    };
    budget: {
      amount_omitted?: boolean;
      source: string;
      status: string;
    };
    provider_attempts_blocked: boolean;
    reject_reason?: string | null;
    status: string;
  };
  rate_limit_reservation: {
    concurrency: RequestRateLimitDimensionMetadata & { reservation_status?: string | null };
    retry_after_ms?: number | null;
    rpm: RequestRateLimitDimensionMetadata & { reservation_status?: string | null };
    scope?: string | null;
    status: string;
    tpm: RequestRateLimitDimensionMetadata & { reservation_status?: string | null };
    window_status?: string | null;
  };
  safe_next_action: string;
  schema: "admin_preauthorize_and_rate_limit_explainability_v1" | string;
  secret_safe?: boolean;
  source: "request_log_detail_safe_read_model" | string;
};

export type RequestProviderAttemptExplainabilityStep = {
  attempt_no: number;
  channel?: {
    id?: string | null;
    present: boolean;
  };
  channel_id?: string | null;
  error_category: string;
  error_code?: string | null;
  error_owner?: string | null;
  fallback_reason?: string | null;
  first_token_recorded?: boolean;
  http_status?: number | null;
  latency?: {
    first_token_recorded: boolean;
    latency_ms?: number | null;
    recorded: boolean;
    ttft_ms?: number | null;
  };
  provider?: {
    id?: string | null;
    present: boolean;
  };
  provider_id?: string | null;
  retryable?: boolean | null;
  role?: "selected" | "fallback" | "candidate" | string;
  status: string;
};

export type RequestProviderAttemptsExplainability = {
  attempt_count: number;
  fallback_attempt_count: number;
  fallback_sequence: RequestProviderAttemptExplainabilityStep[];
  first_token_observed: boolean;
  latency_observed: boolean;
  omitted_fields?: string[];
  provider_channel_status: {
    attempts_recorded: boolean;
    selected_channel_id?: string | null;
    selected_provider_id?: string | null;
    terminal_status: string;
  };
  retryable_attempt_count: number;
  safe_next_action: string;
  schema: "admin_provider_attempts_explainability_v1" | string;
  secret_safe?: boolean;
  selected_attempt_no?: number | null;
  selected_fallback_sequence: RequestProviderAttemptExplainabilityStep[];
  source: "request_log_detail_provider_attempts_safe_projection" | string;
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
  output_tokens: number;
  provider_id?: string | null;
  request_id: string;
  retryable?: boolean | null;
  completed_at?: string | null;
  started_at?: string | null;
  status: string;
  tenant_id: string;
  ttft_ms?: number | null;
  upstream_model?: string | null;
};

export type LedgerEntrySummary = {
  amount: string;
  balance?: {
    after?: string | null;
    before?: string | null;
    currency?: string | null;
    reason?: string | null;
    source?: string | null;
    status?: "config-needed" | "no-ledger" | string;
  } | null;
  created_at: string;
  currency: string;
  entry_type: LedgerEntryType;
  id?: string | null;
  occurred_at: string;
  price_version_id?: string | null;
  project_id?: string | null;
  refs?: {
    credit_grant_id?: string | null;
    invoice_id?: string | null;
    ledger_entry_id?: string | null;
    order_id?: string | null;
    payment_capture_id?: string | null;
    payment_intent_id?: string | null;
    price_version_id?: string | null;
    project_id?: string | null;
    ref_source?: string | null;
    refund_id?: string | null;
    related_ledger_entry_id?: string | null;
    request_id?: string | null;
    trace_id?: string | null;
    virtual_key_id?: string | null;
    voucher_id?: string | null;
    voucher_redemption_id?: string | null;
    wallet_id?: string | null;
  } | null;
  request_id?: string | null;
  related_ledger_entry_id?: string | null;
  status: LedgerEntryStatus;
  trace_id?: string | null;
  virtual_key_id?: string | null;
  wallet_id?: string | null;
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

export type RequestTraceTimelineStage = {
  category:
    | "auth"
    | "routing"
    | "preauth_rate_limit"
    | "provider"
    | "streaming"
    | "ledger"
    | "payload_policy"
    | string;
  latency: {
    latency_ms?: number | null;
    recorded: boolean;
    ttft_ms?: number | null;
  };
  refs: Record<string, JsonValue>;
  safe_next_action: string;
  stage:
    | "auth_key_profile"
    | "routing_decision"
    | "preauthorize_rate_limit"
    | "provider_attempts_fallback"
    | "stream_finalizer"
    | "ledger_settlement"
    | "payload_preview_policy"
    | string;
  status: string;
};

export type RequestTraceTimelineReadback = {
  omitted_fields: string[];
  raw_material_returned: false;
  schema: "admin_request_trace_timeline_readback.v1" | string;
  secret_safe: true;
  source: "request_log_detail_compact_safe_readback" | string;
  stages: RequestTraceTimelineStage[];
};

export type RequestLogDetail = {
  billing_usage_source?: RequestUsageExplainability | null;
  ledger: RequestLedgerSummary;
  preauthorize_and_rate_limit_explainability?: RequestPreauthorizeRateLimitExplainability | null;
  provider_attempts_explainability?: RequestProviderAttemptsExplainability | null;
  provider_protocol_summary?: RequestProviderProtocolSummary | null;
  provider_attempts: ProviderAttempt[];
  request_log: RequestLogSummary;
  route_decision_snapshot: JsonValue;
  trace_timeline_readback?: RequestTraceTimelineReadback | null;
  usage_explainability?: RequestUsageExplainability | null;
};

export type RequestPayloadPreview = {
  available?: boolean;
  payload_preview_policy_readback?: {
    audit_ref_presence: {
      audit_action: string;
      audit_ref_present: false;
      reason: string;
      status: "not_written_for_metadata_only_readback" | string;
    };
    click_to_load_endpoint: string;
    click_to_load_required: true;
    forbidden_raw_fields_policy: {
      authorization_header_returned: false;
      forbidden_fields: string[];
      provider_key_id_returned: false;
      provider_key_returned: false;
      raw_body_returned: false;
      raw_prompt_returned: false;
      raw_provider_response_returned: false;
      raw_request_payload_returned: false;
      raw_response_payload_returned: false;
    };
    metadata_only: true;
    raw_material_returned: false;
    redaction_status: string;
    safe_next_action: string;
    schema: "payload_preview_policy_readback.v1" | string;
    secret_safe: true;
    status: "stored_metadata_only" | "not_stored_metadata_only" | string;
    storage_status: "stored" | "not_stored" | string;
  };
  metadata?: JsonValue | null;
  omitted_fields?: string[] | null;
  payload_policy_id?: string | null;
  payload_stored?: boolean | null;
  redacted_request_preview?: JsonValue | null;
  redacted_response_preview?: JsonValue | null;
  redaction_status?: string | null;
  request_body_hash?: string | null;
  request_id?: string | null;
  request_metadata?: JsonValue | null;
  response_body_hash?: string | null;
  response_metadata?: JsonValue | null;
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
  actor_session_id?: string;
  actor_user_id?: string;
  created_from?: string;
  created_to?: string;
  entity_type?: string;
  limit?: number;
  resource_id?: string;
  resource_tenant_id?: string;
  resource_type?: string;
};

export type AuditLog = {
  action: string;
  actor_user_id?: string | null;
  after_snapshot?: JsonValue | null;
  audit_log_detail_readback?: {
    action: string;
    action_result: string;
    actor_session_presence: {
      actor_session_id_present: boolean;
      actor_user_id_present: boolean;
      raw_session_returned: false;
    };
    audit_log_id: string;
    metadata_redaction_summary: {
      after_snapshot_redacted_field_count: number;
      before_snapshot_redacted_field_count: number;
      forbidden_material_omitted: string[];
      metadata_object: boolean;
      raw_api_key_returned: false;
      raw_authorization_returned: false;
      raw_payload_returned: false;
      raw_provider_key_returned: false;
      redacted_field_count: number;
      safe_summary_keys: string[];
    };
    resource_refs: {
      request_id?: string | null;
      request_id_present: boolean;
      resource_id?: string | null;
      resource_id_present: boolean;
      resource_tenant_id?: string | null;
      resource_tenant_id_present: boolean;
      resource_type: string;
    };
    safe_next_action: string;
    schema: "audit_log_detail_readback.v1" | string;
    source: "audit_logs" | string;
  };
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
  blocked_reasons?: string[];
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
  endpoint_configured?: boolean;
  priority?: number | null;
  provider_key_presence?: {
    configured: boolean;
    credential_material_returned: false;
    enabled_configured: boolean;
    enabled_provider_key_count: number;
    provider_key_count: number;
  };
  protocol_endpoint_capability_readiness?: JsonValue;
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
  safe_next_action?: string;
  trace_affinity_match: boolean;
  upstream_model?: string | null;
  weight?: number | null;
};

export type ModelAssociationDryRunProfileVisibilityReadback = {
  allowed_channel_tags: {
    count: number;
    mode: "all_channel_tags" | "explicit_list" | string;
    tags: string[];
  };
  allowed_models: {
    count: number;
    mode: "all_visible_models" | "explicit_list" | string;
    models: string[];
  };
  credential_scope: "profile" | string;
  authorization_returned: false;
  blocked_provider_ids: {
    count: number;
    ids: string[];
  };
  canonical_model_key?: string | null;
  credential_material_returned: false;
  denied_models: {
    count: number;
    models: string[];
  };
  profile_id: string;
  profile_status: string;
  project_id: string;
  raw_upstream_model_payload_returned: false;
  requested_model: string;
  requested_model_decision: "allowed" | "denied" | "not_in_allowed_models" | "model_not_found_or_not_allowed" | string;
  schema: "model_profile_visibility_diagnostics.v1" | string;
};

export type ModelAssociationDryRunPriceConfigPresence = {
  active_price_version_selector: string;
  default_price_book_configured: boolean;
  default_price_book_id?: string | null;
  pricing_rules_returned: false;
  safe_next_action: string;
  schema: "model_price_config_presence.v1" | string;
};

export type ModelAssociationDryRunDiagnosticReadback = {
  blocked_provider_channel_reasons: string[];
  candidate_count: number;
  filtered_candidate_count: number;
  price_config_present: boolean;
  profile_id: string;
  project_id: string;
  protocol_endpoint_capability_readiness_present: boolean;
  provider_key_presence: {
    candidate_channel_count: number;
    credential_material_returned: false;
    enabled_configured_provider_key_count: number;
  };
  requested_model: string;
  safe_next_action: string;
  schema: "model_profile_visibility_diagnostics_readback.v1" | string;
  secret_safety: {
    authorization_returned: false;
    provider_key_returned: false;
    raw_channel_endpoint_returned: false;
    raw_upstream_model_payload_returned: false;
  };
  selected_candidate_count: number;
};

export type ModelAssociationDryRunResponse = {
  candidates: ModelAssociationDryRunCandidate[];
  canonical_model: ModelAssociationDryRunCanonicalModel | null;
  decision_snapshot_version: number;
  diagnostic_readback?: ModelAssociationDryRunDiagnosticReadback;
  policy: JsonValue;
  price_config_presence?: ModelAssociationDryRunPriceConfigPresence;
  profile_visibility_readback?: ModelAssociationDryRunProfileVisibilityReadback;
  protocol_capability_matrix?: ProtocolCapabilityMatrixReadback;
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
  credential_configured?: boolean;
  credential_generation?: {
    secret_material_returned: false;
    source: string;
    value?: number | null;
  };
  health_score: number;
  id: string;
  key_alias: string;
  last_error_code?: string | null;
  last_probe_summary?: ProviderKeyRecoveryProbeSummary | null;
  lifecycle_state?: string;
  metadata?: JsonValue;
  omitted_secret_policy?: ProviderKeyOmittedSecretPolicy;
  recovery_probe?: {
    error_code?: string | null;
    last_checked_at?: string | null;
    next_step?: string | null;
    result?: string | null;
  } | null;
  recovery_action_readback?: ProviderKeyRecoveryActionReadback | null;
  recovery_apply_plan_readback?: ProviderKeyRecoveryApplyPlanReadback | null;
  rotation_needed?: {
    needed: boolean;
    reason: string;
  };
  rpm_limit?: number | null;
  safe_next_action?: string;
  secret_redacted?: boolean;
  status: ProviderKeyStatus;
  tenant_id: string;
  tpm_limit?: number | null;
};

export type ProviderKeyRecoveryActionReadback = {
  cooldown_or_refusal_reason: string;
  last_probe_status: string;
  omitted_secret_policy?: ProviderKeyOmittedSecretPolicy;
  operator_confirmation_required: boolean;
  safe_next_action: string;
  schema: "provider_key_recovery_action_readback.v1" | string;
  secret_safe: true;
  suggested_action:
    | "request_recovery_probe"
    | "rotate_provider_key_secret"
    | "operator_review_reenable"
    | "monitor_request_logs"
    | "check_provider_quota_and_limits"
    | "create_replacement_provider_key"
    | "operator_review_provider_key_state"
    | string;
  upstream_probe_executed: false;
};

export type ProviderKeyRecoveryApplyPlanReadback = {
  blocked_reasons: string[];
  local_execution_boundary: {
    billing_ledger_write: false;
    live_provider_smoke: false;
    provider_network_call: false;
    request_log_write: false;
    secret_write_allowed: boolean;
    status_write_allowed: boolean;
    upstream_probe_executed: false;
  };
  omitted_secret_policy?: ProviderKeyOmittedSecretPolicy;
  operator_confirmation_required: boolean;
  preconditions: string[];
  safe_next_action: string;
  schema: "provider_key_recovery_apply_plan_readback.v1" | string;
  secret_safe: true;
  suggested_action: ProviderKeyRecoveryActionReadback["suggested_action"];
  would_enable: boolean;
  would_probe: boolean;
  would_refuse: boolean;
  would_rotate: boolean;
};

export type ProviderKeyRecoveryProbeSummary = {
  error_code?: string | null;
  last_checked_at?: string | null;
  next_step?: string | null;
  result?: string | null;
};

export type ProviderKeyOmittedSecretPolicy = {
  authorization_header_returned: false;
  fingerprint_returned: false;
  key_secret_returned: false;
  public_credential_indicator: "credential_configured" | string;
  raw_endpoint_returned: false;
  raw_payload_returned: false;
  sealed_secret_returned: false;
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
    policy?: ProviderKeyOmittedSecretPolicy;
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
  recovery_apply_plan_readback?: ProviderKeyRecoveryApplyPlanReadback;
  safe_next_action?: string;
};

export type ProviderKeyRotateRequest = {
  api_key?: string;
  key_alias?: string;
  reason?: string;
  secret?: string;
};

export type ProviderKeyRotateResponse = {
  controlled_rotation?: true;
  credential_material: {
    omitted: true;
    encrypted_at_rest?: true;
    fingerprint_returned?: false;
    policy?: ProviderKeyOmittedSecretPolicy;
  };
  new_provider_key: ProviderKey;
  old_provider_key: ProviderKey;
  production_rotation_closure_allowed: false;
  rotation_needed?: {
    needed: boolean;
    reason: string;
  };
  safe_next_action?: string;
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

export type VirtualKeyPolicyDiagnostics = {
  blocked_reasons: string[];
  budget: {
    blocked_reason?: string | null;
    current_usage_summary: Record<string, unknown>;
    limit_present: boolean;
    policy_present: boolean;
    reject_reason?: string | null;
    safe_next_action: string;
    status: string;
    window_present: boolean;
  };
  current_usage_summary: Record<string, unknown>;
  omitted_fields: string[];
  profile: {
    blocked_reason?: string | null;
    default_profile_present: boolean;
  };
  rate_limit: {
    blocked_reason?: string | null;
    current_usage_summary: Record<string, unknown>;
    limit_present: boolean;
    limits: {
      concurrency_limit_present: boolean;
      rpm_limit_present: boolean;
      tpm_limit_present: boolean;
    };
    policy_present: boolean;
    reject_reason?: string | null;
    safe_next_action: string;
    status: string;
    window_present: boolean;
  };
  refs_presence: {
    ledger_ref_present: boolean;
    preauth_ref_present: boolean;
    request_log_ref_present: boolean;
    source: string;
  };
  reject_reason?: string | null;
  safe_next_action: string;
  schema: string;
  secret_safe: boolean;
};

export type VirtualKey = {
  budget_policy: JsonValue;
  default_profile_id?: string | null;
  id: string;
  ip_allowlist: JsonValue;
  key_prefix: string;
  metadata: JsonValue;
  name: string;
  policy_diagnostics?: VirtualKeyPolicyDiagnostics;
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

export type VirtualKeyLeakAction = "suspected_leaked" | "disable" | "revoke";

export type BulkVirtualKeyLeakActionRequest = {
  action: VirtualKeyLeakAction;
  key_ids: string[];
  reason: string;
};

export type BulkVirtualKeyLeakActionResult = {
  action_result: string;
  key_id: string;
  key_prefix: string | null;
  status: VirtualKeyStatus | null;
};

export type BulkVirtualKeyLeakActionResponse = BulkVirtualKeyLeakActionResult[];

export type VirtualKeyExternalScannerHandoffRequest = {
  detected_at: string;
  finding_count: number;
  key_hash_present: boolean;
  key_prefix_present: boolean;
  provider: "github_secret_scanning" | "gitleaks" | "trufflehog" | "custom" | string;
  repo_ref_hash: string;
  severity: "info" | "low" | "medium" | "high" | "critical" | string;
  signature_validated: boolean;
  virtual_key_id?: string;
};

export type VirtualKeyExternalScannerHandoffResponse = {
  detected_at: string;
  finding_count: number;
  key_hash_present: boolean;
  key_prefix_present: boolean;
  network_call_performed: false;
  payload_omitted: true;
  provider: string;
  raw_findings_accepted: false;
  raw_findings_returned: false;
  repo_ref_hash_present: true;
  result: {
    action_result: string;
    audit_log_id: string | null;
    key_id: string | null;
    key_prefix: string | null;
    metadata_marker_written: boolean;
    status: VirtualKeyStatus | null;
  };
  safe_markers: string[];
  secret_safe: true;
  severity: string;
  signature_validated: boolean;
  source: "external_scanner_handoff";
  webhook_signature_verification: string;
};

export type VirtualKeyLeakCandidate = {
  action_recommendation: string;
  automatic_action: false;
  confidence: number;
  first_seen: string | null;
  key_id: string;
  key_prefix: string;
  last_seen: string | null;
  next_step: string;
  operator_confirmation_required: true;
  reason: string;
  rule_status: string;
  safe_markers: string[];
  source: string;
  status: VirtualKeyStatus;
};

export type VirtualKeyLeakCandidateSourceMarker = {
  marker: "manual_marker" | "audit_marker" | "external_scanner_config_needed" | string;
  next_step: string;
  status: "active" | "config-needed" | string;
};

export type VirtualKeyExternalScannerAdapterReadback = {
  accepts_raw_payloads: false;
  blocked_reason: string | null;
  endpoint_ref_present: boolean;
  external_scanner_connected: false;
  last_scan_marker: {
    status: "not_run" | "metadata_seen" | string;
    source: string;
    marker_present: boolean;
    external_candidate_count?: number;
    marker_counts?: Record<string, number>;
    last_seen?: string | null;
    raw_findings_returned: false;
  };
  network_call_performed: false;
  next_step: string;
  provider: "unconfigured" | "github_secret_scanning" | "gitleaks" | "trufflehog" | "custom" | string;
  raw_findings_returned: false;
  readiness: "blocked" | "ready-for-metadata-handoff" | string;
  secret_ref_present: boolean;
  status: "config-needed" | "configured" | string;
  sync_direction: "external_to_control_plane_metadata_only" | "control_plane_to_external_disabled" | string;
  webhook_ref_present: boolean;
};

export type VirtualKeyLeakCandidateSourcePolicy = {
  accepted_candidate_sources: string[];
  automatic_disable_or_revoke?: false;
  candidate_only_until_confirmed: true;
  destructive_actions_require_operator_confirmation: string[];
  forbidden_response_material: string[];
  safe_markers: VirtualKeyLeakCandidateSourceMarker[];
  scanner_adapter: VirtualKeyExternalScannerAdapterReadback;
  source_policy_version: "virtual-key-leak-detection-rules-v1" | string;
};

export type VirtualKeyLeakCandidatesResponse = {
  automatic_disable_or_revoke: false;
  external_scanner_adapter: VirtualKeyExternalScannerAdapterReadback;
  leak_candidates: VirtualKeyLeakCandidate[];
  operator_confirmation_required: true;
  payload_omitted: true;
  secret_safe: true;
  source_policy: VirtualKeyLeakCandidateSourcePolicy;
  suspected_leaked: VirtualKeyLeakCandidate[];
};

export type RestoreVirtualKeyRequest = {
  reason: string;
};

export type RestoreVirtualKeyResponse = {
  action_result: string;
  audit_log_id?: string | null;
  id?: string;
  key_id: string;
  key_prefix: string | null;
  restore_supported: boolean;
  safety_reason?: string | null;
  secret_returned: false;
  status: VirtualKeyStatus | null;
};

export type NetworkSecurityConfigStatus = "configured" | "config-needed" | "pending" | string;

export type NetworkSecuritySettings = {
  action_result?: string;
  allowlist_handoff?: {
    config_file_fields: Array<{
      config_path_env: "AI_GATEWAY_CONFIG" | string;
      field: string;
      patch_behavior: string;
      patch_path: string;
      restart_required: boolean;
    }>;
    editable_fields: Array<{
      apply_path: string;
      effect: string;
      field: string;
      readback_path: string;
    }>;
    read_only_fields: Array<{
      change_path: string;
      effect: string;
      field: string;
      readback_path: string;
    }>;
  };
  config_keys: {
    config_path_env: "AI_GATEWAY_CONFIG" | string;
    trusted_proxy_allowlist: "server.trusted_proxy_allowlist" | string;
  };
  effective_trusted_proxy_allowlist: string[];
  example_generator?: {
    command: string;
    contains_real_networks_or_secrets: false;
    default_output_path: string;
    example_address_policy: string;
    print_only_behavior: string;
    print_only_command: string;
    script_path: string;
  };
  hot_reload_supported: false;
  next_action: string;
  recommended_env_keys: string[];
  requested_trusted_proxy_allowlist_count?: number;
  schema: "admin_network_security_settings.v1" | string;
  secret_safe: true;
  status: NetworkSecurityConfigStatus;
  trusted_proxy_config_source: "runtime_config" | "config-needed" | string;
};

export type PatchNetworkSecuritySettingsRequest = {
  trusted_proxy_allowlist?: string[];
};

export type PriceVersionStatus = "draft" | "active" | "retired" | string;

export type PriceVersion = {
  canonical_model_id?: string | null;
  created_at: string;
  effective_at: string;
  id: string;
  price_book_id: string;
  pricing_rules: PriceVersionPricingRules | JsonValue;
  retired_at?: string | null;
  status: PriceVersionStatus;
  tenant_id: string;
  version: string;
};

export type PriceVersionPricingRules = {
  cache_token_rate_per_1m?: string | number | null;
  currency: string;
  fixed_request_cost?: string | number | null;
  input_token_rate_per_1m?: string | number | null;
  output_token_rate_per_1m?: string | number | null;
  reasoning_token_rate_per_1m?: string | number | null;
  scale?: number | null;
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

export type SubscriptionPlanStatus = "draft" | "active" | "archived" | string;
export type SubscriptionBillingInterval = "month" | "year" | "one_time" | string;

export type SubscriptionLifecycleReadback = {
  schema: "subscription_lifecycle_readback.v1" | string;
  source: string;
  current_plan: {
    billing_interval?: string;
    currency?: string;
    plan_code?: string;
    plan_id?: string;
    status?: string;
    subscription_id?: string;
    subscription_status?: string;
  } & JsonObject;
  period_status: JsonValue;
  quota_or_credit_grant_refs_presence: {
    credit_automation_status?: string;
    credit_grant_ref_present?: boolean;
    included_credit_amount?: string;
    ledger_entry_ref_present?: boolean;
    quota_ref_present?: boolean;
  } & JsonObject;
  scheduler_event_refs_presence: {
    audit_ref_present?: boolean;
    invoice_ref_present?: boolean;
    order_ref_present?: boolean;
    scheduled_event_count?: number;
    scheduler_status?: string;
    subscription_event_ref_present?: boolean;
  } & JsonObject;
  payment_handoff_status: {
    network_call_performed: false;
    payment_capture_handoff_present?: boolean;
    payment_provider_executor_handoff_present?: boolean;
    provider_source_ref_present?: boolean;
    refund_or_credit_note_handoff_present?: boolean;
    status: string;
  } & JsonObject;
  safe_next_action: string;
  forbidden_material_returned: false;
  secret_safe: true;
  raw_provider_payload_returned: false;
  authorization_returned: false;
  raw_invoice_metadata_returned: false;
  provider_secret_returned: false;
};

export type SubscriptionPlan = {
  billing_interval: SubscriptionBillingInterval;
  created_at: string;
  currency: string;
  display_name: string;
  entitlement_summary: JsonValue;
  expiration_policy: JsonValue;
  id: string;
  included_credit_amount: string;
  metadata: JsonValue;
  payment_status: "not_connected" | string;
  plan_code: string;
  raw_payment_payload_returned: false;
  request_summary: JsonValue;
  scheduler_status: "pending_scheduler" | string;
  secret_safe: true;
  status: SubscriptionPlanStatus;
  subscription_lifecycle_readback?: SubscriptionLifecycleReadback;
  tenant_id: string;
  trial_days: number;
  unit_price: string;
  updated_at: string;
};

export type SubscriptionPlanListFilters = {
  billing_interval?: SubscriptionBillingInterval;
  limit?: number;
  status?: SubscriptionPlanStatus;
};

export type CreateSubscriptionPlanRequest = {
  billing_interval: SubscriptionBillingInterval;
  currency: string;
  display_name: string;
  included_credit_amount: string;
  metadata?: JsonObject;
  plan_code: string;
  request_summary?: JsonObject;
  status?: SubscriptionPlanStatus;
  trial_days?: number;
  unit_price: string;
};

export type PatchSubscriptionPlanRequest = Partial<Omit<CreateSubscriptionPlanRequest, "plan_code">>;

export type SubscriptionSchedulerPlanRequest = {
  action?: "all" | "renewal" | "grace" | "dunning" | "proration" | string;
  limit?: number;
  mode?: "dry_run" | "apply" | string;
  reason?: string | null;
  subscription_id?: string | null;
  target_plan_id?: string | null;
};

export type SubscriptionSchedulerPlan = {
  action: string;
  apply_result: {
    applied: boolean;
    events: Array<{
      effective_at: string;
      event_status: string;
      event_type: string;
      id: string;
      idempotency_key_fingerprint: string;
      raw_idempotency_key_echoed: false;
      secret_safe: true;
      subscription_id: string;
    }>;
    invoice_order_ledger_credit_writes: false;
    scheduled_event_count: number;
    subscription_rows_updated: false;
    writes_limited_to: string[];
  };
  candidate_count: number;
  candidates: Array<{
    currency?: string | null;
    dunning: JsonValue;
    existing_scheduled_event_count?: number;
    grace: JsonValue;
    period?: JsonValue;
    plan_code?: string | null;
    plan_id: string;
    planned_event_types: string[];
    proration: JsonValue;
    project_id?: string | null;
    raw_idempotency_key_echoed: false;
    raw_payment_payload_returned: false;
    raw_provider_payload_returned: false;
    renewal: JsonValue;
    secret_safe: true;
    status: string;
    subscription_lifecycle_readback?: SubscriptionLifecycleReadback;
    subscription_id: string;
    target_plan_id?: string | null;
    wallet_id: string;
  }>;
  mode: string;
  next_action: string;
  raw_idempotency_key_echoed: false;
  raw_payment_payload_returned: false;
  raw_provider_payload_returned: false;
  authorization_returned: false;
  schema: "admin_subscription_scheduler_plan.v1" | string;
  secret_safe: true;
  status: string;
  subscription_id?: string | null;
  target_plan_id?: string | null;
  tenant_id?: string | null;
};

export type ImporterApplyPlanReadback = {
  schema_version: "control_plane.importer_apply_plan_readback.v1" | string;
  status: "readback-ready" | "blocked" | string;
  tenant_id?: string | null;
  session_id?: string | null;
  plan_hash?: string | null;
  idempotency_fingerprint: JsonValue;
  apply_result: {
    applied_row_counts: Record<string, number>;
    db_writes_performed: false;
    production_db_apply_performed: false;
    raw_sql_returned: false;
  };
  rollback_result: {
    rollback_journal_ref_present: boolean;
    rollback_db_writes_performed: false;
    raw_sql_returned: false;
  };
  applied_row_counts: Record<string, number>;
  rollback_journal_ref_present: boolean;
  blocked_reasons: string[];
  safe_next_action: string;
  db_writes_performed: false;
  readback_source: "local_demo_or_operator_handoff" | string;
  forbidden_material_returned?: false;
  db_url_returned: false;
  raw_sql_returned: false;
  raw_user_key_returned: false;
  provider_key_returned: false;
  authorization_returned: false;
  secret_returned: false;
  secret_safe: true;
};

export type ImporterApplyPlanReadbackRecordRequest = {
  plan_hash?: string | null;
  reviewed_plan_hash_sha256?: string | null;
  idempotency_fingerprint?: JsonValue;
  idempotency_summary?: JsonValue;
  apply_result?: {
    applied_row_counts?: Record<string, number>;
    db_writes_performed?: false;
  };
  rollback_result?: {
    rollback_journal_ref_present?: boolean;
  };
  applied_row_counts?: Record<string, number>;
  rollback_journal_ref_present?: boolean;
  blocked_reasons?: string[];
  safe_next_action?: string;
  db_writes_performed?: false;
  operator_approval_packet?: JsonObject;
  rollback_guard?: JsonObject;
};

export type SubscriptionSchedulerEventExecuteRequest = {
  mode?: "dry_run" | "apply" | "refuse" | "replay" | string;
  reason?: string | null;
};

export type SubscriptionSchedulerProviderCaptureReconciliationPlan = {
  schema: "admin_subscription_scheduler_provider_capture_reconciliation_plan.v1" | string;
  status: "blocked" | "provider_source_ready_waiting_fetch" | string;
  provider: string;
  action: "capture" | string;
  operator_api_call: JsonValue;
  provider_object_fetch_summary: JsonValue;
  executor_source_of_truth: JsonValue;
  expected_payment_reconciliation?: JsonValue;
  expected_reconciliation_schema?: string;
  status_mapping?: JsonValue;
  next_action?: string;
  success_local_ref_updates: JsonValue;
  preconditions: JsonValue;
  blocked_reasons?: string[];
  writes: JsonValue;
  network_call_enabled: false;
  network_call_performed: false;
  secret_safe: true;
  raw_provider_ref_echoed: false;
  raw_provider_payload_echoed: false;
  authorization_returned: false;
  provider_secret_returned: false;
  raw_idempotency_key_echoed: false;
};

export type SubscriptionSchedulerPaymentCaptureHandoff = {
  schema: "admin_subscription_scheduler_payment_capture_handoff.v1" | string;
  status: "blocked" | "not_applicable" | "provider_source_ready_waiting_fetch" | string;
  event_id: string;
  subscription_id: string;
  event_type: string;
  event_status: string;
  due_now: boolean;
  next_provider_executor_action: "capture" | string;
  ready_for_provider_executor: false;
  blocked_reasons: string[];
  operator_api_call: {
    method: "POST" | string;
    path: "/admin/billing/payment-provider/executor" | string;
    action: "capture" | string;
    idempotency_fingerprint: string;
    raw_idempotency_key_required_from_ui: false;
  };
  local_refs: JsonValue;
  provider_refs: JsonValue;
  provider_source_ref_plan: JsonValue;
  credential_source: JsonValue;
  source_of_truth: {
    provider_object_fetch_required_before_capture: true;
    provider_object_fetch_summary_required: true;
    provider_object_fetch_summary_schema: "payment_provider_stripe_like_source_of_truth_summary.v1" | string;
    expected_reconciliation_schema?: "payment_provider_stripe_like_response_object_reconciliation.v1" | string;
    network_call_enabled: false;
    network_call_performed: false;
    production_payment_evidence: false;
  };
  expected_payment_reconciliation?: JsonValue;
  provider_capture_reconciliation_plan: SubscriptionSchedulerProviderCaptureReconciliationPlan;
  billing_ledger_executor_contract: JsonValue;
  stripe_like_client_request_plan: JsonValue;
  idempotency: {
    source: string;
    fingerprint: string;
    raw_idempotency_key_echoed: false;
    key_hash_returned: false;
  };
  writes: JsonValue;
  payment_capture_executed: false;
  network_call_enabled: false;
  network_call_performed: false;
  secret_safe: true;
  raw_payment_payload_returned: false;
  raw_provider_payload_returned: false;
  authorization_returned: false;
  provider_secret_returned: false;
  raw_idempotency_key_echoed: false;
};

export type SubscriptionSchedulerRefundOrCreditNoteHandoff = {
  schema: "admin_subscription_scheduler_refund_or_credit_note_handoff.v1" | string;
  status: "blocked" | "not_applicable" | string;
  event_id: string;
  subscription_id: string;
  event_type: string;
  event_status: string;
  due_now: boolean;
  scenario: "negative_proration_refund_or_credit_note" | "not_applicable" | string;
  next_provider_executor_action: "refund_or_credit_note" | string;
  ready_for_provider_executor: false;
  blocked_reasons: string[];
  next_action: string;
  operator_api_call: {
    method: "POST" | string;
    path: "/admin/billing/payment-provider/executor" | string;
    action: "refund" | string;
    idempotency_fingerprint: string;
    raw_idempotency_key_required_from_ui: false;
  };
  local_refs: {
    credit_grant_id?: string | null;
    ledger_entry_id?: string | null;
    payment_refund_id?: string | null;
    order_id?: string | null;
    invoice_id?: string | null;
    payment_intent_id?: string | null;
    local_credit_note_refs_present: boolean;
    local_payment_refund_ref_present: boolean;
  } & JsonObject;
  payment_refund: {
    id?: string | null;
    status?: string | null;
    idempotency_fingerprint?: string | null;
    provider_refund_ref_present: boolean;
    raw_provider_ref_echoed: false;
  };
  provider_refs: JsonValue;
  provider_object_fetch_requirement: JsonValue;
  source_of_truth_policy: JsonValue;
  negative_proration_readback?: JsonValue;
  billing_ledger_executor_contract: JsonValue;
  stripe_like_client_request_plan: JsonValue;
  idempotency: {
    source: string;
    fingerprint: string;
    raw_idempotency_key_echoed: false;
    key_hash_returned: false;
  };
  writes: JsonValue;
  refund_executed: false;
  credit_note_recorded_locally: boolean;
  network_call_enabled: false;
  network_call_performed: false;
  secret_safe: true;
  raw_payment_payload_returned: false;
  raw_provider_payload_returned: false;
  authorization_returned: false;
  provider_secret_returned: false;
  raw_idempotency_key_echoed: false;
};

export type SubscriptionSchedulerEventExecutePlan = {
  authorization_returned: false;
  event: {
    billing?: JsonValue;
    created_at: string;
    effective_at: string;
    event_status: "scheduled" | "applied" | "replayed" | "refused" | "matched" | string;
    event_type: string;
    execute_mode: string;
    execution_plan: JsonValue;
    id: string;
    idempotency_key_fingerprint: string;
    local_execution_readback?: JsonValue;
    metadata_policy: JsonValue;
    payment_capture_handoff?: SubscriptionSchedulerPaymentCaptureHandoff;
    payment_provider_executor_handoff?: SubscriptionSchedulerPaymentCaptureHandoff;
    refund_or_credit_note_handoff?: SubscriptionSchedulerRefundOrCreditNoteHandoff;
    period?: JsonValue;
    plan_code?: string | null;
    plan_id: string;
    project_id?: string | null;
    raw_idempotency_key_echoed: false;
    raw_invoice_metadata_returned: false;
    raw_payment_payload_returned: false;
    raw_provider_payload_returned: false;
    refs?: JsonValue;
    secret_safe: true;
    subscription_lifecycle_readback?: SubscriptionLifecycleReadback;
    subscription_id: string;
    subscription_status?: string;
    target_event_status: string;
    updated_at: string;
    wallet_id: string;
  };
  execution_boundary: {
    authorization_returned: false;
    credit_grant_executed: false;
    current_runtime: string;
    invoice_creation_executed: boolean;
    ledger_settlement_executed: false;
    order_creation_executed: boolean;
    payment_provider_connected: false;
    raw_idempotency_key_echoed: false;
    raw_invoice_metadata_returned: false;
    raw_payment_payload_returned: false;
    raw_provider_payload_returned: false;
    worker_can_pick_up_statuses: string[];
    worker_handoff_ready: boolean;
  };
  mode: string;
  next_action: string;
  executor_steps?: JsonValue;
  runtime_implemented?: boolean;
  subscription_rows_updated?: number | JsonValue;
  ledger_or_credit_readback?: JsonValue;
  invoice_order_readback?: JsonValue;
  dunning_retry_readback?: JsonValue;
  proration_delta_readback?: JsonValue;
  negative_proration_readback?: JsonValue;
  payment_capture_handoff?: SubscriptionSchedulerPaymentCaptureHandoff;
  payment_provider_executor_handoff?: SubscriptionSchedulerPaymentCaptureHandoff;
  refund_or_credit_note_handoff?: SubscriptionSchedulerRefundOrCreditNoteHandoff;
  raw_idempotency_key_echoed: false;
  raw_invoice_metadata_returned: false;
  raw_payment_payload_returned: false;
  raw_provider_payload_returned: false;
  schema: "admin_subscription_scheduler_event_execute_plan.v1" | string;
  secret_safe: true;
  status_transition: {
    from: string;
    invoice_order_ledger_credit_writes?: false | string;
    ledger_or_credit_readback?: JsonValue;
    invoice_order_readback?: JsonValue;
    dunning_retry_readback?: JsonValue;
    proration_delta_readback?: JsonValue;
    negative_proration_readback?: JsonValue;
    mutated: boolean;
    payment_capture_handoff?: SubscriptionSchedulerPaymentCaptureHandoff;
    refund_or_credit_note_handoff?: SubscriptionSchedulerRefundOrCreditNoteHandoff;
    payment_capture_executed: false;
    runtime_implemented?: boolean;
    subscription_rows_updated: false | number | JsonValue;
    to: string;
    writes_limited_to: string[];
  };
};

export type SubscriptionSchedulerRunDueProcessedEvent = {
  event: SubscriptionSchedulerEventExecutePlan["event"];
  status: string;
  status_transition: {
    mutated: boolean;
    from: string;
    to: string;
    writes_limited_to: string[];
    runtime_implemented?: boolean;
    subscription_rows_updated?: false | number | JsonValue;
    ledger_or_credit_readback?: JsonValue;
    invoice_order_readback?: JsonValue;
    dunning_retry_readback?: JsonValue;
    proration_delta_readback?: JsonValue;
    negative_proration_readback?: JsonValue;
    payment_capture_handoff?: SubscriptionSchedulerPaymentCaptureHandoff;
    payment_capture_executed?: false;
  };
  local_execution_readback?: JsonValue;
  payment_capture_handoff?: SubscriptionSchedulerPaymentCaptureHandoff;
  payment_provider_executor_handoff?: SubscriptionSchedulerPaymentCaptureHandoff;
  refund_or_credit_note_handoff?: SubscriptionSchedulerRefundOrCreditNoteHandoff;
  invoice_order_readback?: JsonValue;
  dunning_retry_readback?: JsonValue;
  proration_delta_readback?: JsonValue;
  negative_proration_readback?: JsonValue;
  executor_steps?: JsonValue;
};

export type SubscriptionSchedulerWorkerHandoff = {
  authorization_returned: false;
  due_event_count: number;
  due_events: Array<{
    authorization_returned: false;
    billing?: JsonValue;
    created_at: string;
    due_now: boolean;
    effective_at: string;
    event_status: "scheduled" | "replayed" | string;
    event_type: string;
    id: string;
    idempotency_key_fingerprint: string;
    plan_code?: string | null;
    plan_id: string;
    project_id?: string | null;
    raw_idempotency_key_echoed: false;
    raw_invoice_metadata_returned: false;
    raw_payment_payload_returned: false;
    raw_provider_payload_returned: false;
    secret_safe: true;
    subscription_id: string;
    subscription_status?: string;
    updated_at: string;
    wallet_id: string;
    worker_handoff: JsonValue;
  }>;
  dunning_policy: JsonValue;
  event_status_filter: string;
  event_type_filter: string[];
  next_action: string;
  next_run: JsonValue;
  proration_policy: JsonValue;
  raw_idempotency_key_echoed: false;
  raw_invoice_metadata_returned: false;
  raw_payment_payload_returned: false;
  raw_provider_payload_returned: false;
  retry_policy: JsonValue;
  schema: "admin_subscription_scheduler_worker_handoff.v1" | string;
  secret_safe: true;
  status: string;
  supervisor?: SubscriptionSchedulerSupervisorState;
  tenant_id?: string | null;
  worker_handoff: JsonValue;
};

export type AdminWorkersJobsDashboardSection = {
  schema: "admin_workers_jobs_dashboard_section.v1" | string;
  source: string;
  status: "idle" | "handoff_ready" | "blocked" | "not_initialized" | "config_needed" | string;
  count: number;
  ref?: JsonValue;
  refs?: JsonValue[];
  next_action: string;
  read_only: true;
  network_requests_executed: false;
  business_table_writes_performed: false;
  secret_safe: true;
  authorization_returned?: false;
  provider_key_returned?: false;
  raw_payload_returned?: false;
  raw_payment_payload_returned?: false;
  raw_provider_payload_returned?: false;
  raw_webhook_body_returned?: false;
  [key: string]: JsonValue | undefined;
};

export type AdminWorkersJobsDashboard = {
  schema: "admin_workers_jobs_dashboard.v1" | string;
  tenant_id?: string | null;
  status: "idle" | "handoff_ready" | "attention_needed" | string;
  sections: {
    subscription_scheduler_supervisor: AdminWorkersJobsDashboardSection;
    pending_scheduled_events: AdminWorkersJobsDashboardSection;
    import_apply_runner_handoff: AdminWorkersJobsDashboardSection;
    crm_retry_handoff: AdminWorkersJobsDashboardSection;
    provider_health_probe_recovery_handoff: AdminWorkersJobsDashboardSection;
    payment_provider_executor_handoff: AdminWorkersJobsDashboardSection;
  };
  readback_path: "GET /admin/workers/jobs-dashboard" | string;
  read_only: true;
  runtime_daemon_started: false;
  network_requests_executed: false;
  business_table_writes_performed: false;
  omitted_fields: string[];
  secret_safe: true;
  authorization_returned: false;
  session_token_returned: false;
  provider_key_returned: false;
  db_url_returned: false;
  raw_payload_returned: false;
  raw_sql_returned: false;
  raw_webhook_body_returned: false;
  raw_metadata_returned: false;
  next_action: string;
};

export type SubscriptionSchedulerWorkerHandoffFilters = {
  event_status?: "scheduled" | "replayed" | string;
  event_type?: "all" | "renew" | "payment_failed" | "dunning" | "expire" | "prorate" | string;
  limit?: number;
  worker_id?: string | null;
};

export type SubscriptionSchedulerRunDueRequest = {
  mode?: "dry_run" | "apply" | "refuse" | "replay" | string;
  tenant_id?: string | null;
  limit?: number;
  event_status?: "all" | "scheduled" | "replayed" | string;
  event_type?: "all" | "renew" | "payment_failed" | "dunning" | "expire" | "prorate" | string;
  worker_id?: string | null;
  reason?: string | null;
};

export type SubscriptionSchedulerRunDueResult = {
  authorization_returned: false;
  blocked: JsonValue[];
  blocked_count: number;
  event_status_filter: string[];
  event_type_filter: string[];
  limit: number;
  mode: "dry_run" | "apply" | "refuse" | "replay" | string;
  next_action: string;
  next_run: JsonValue;
  omitted_fields: string[];
  policy: JsonValue;
  processed: Array<SubscriptionSchedulerRunDueProcessedEvent | JsonValue>;
  processed_count: number;
  raw_idempotency_key_echoed: false;
  raw_invoice_metadata_returned: false;
  raw_payment_payload_returned: false;
  raw_provider_payload_returned: false;
  schema: "admin_subscription_scheduler_run_due_events.v1" | string;
  secret_safe: true;
  skipped: JsonValue[];
  skipped_count: number;
  status: string;
  supervisor?: SubscriptionSchedulerSupervisorState;
  tenant_id?: string | null;
  worker_id: string;
};

export type SubscriptionSchedulerSupervisorState = {
  authorization_returned?: false;
  background_process_started: false;
  blocked_count?: number;
  durable_state_table: "subscription_scheduler_worker_supervisors" | string;
  external_worker_loop_supported: true;
  last_event_status_filter?: string[];
  last_event_type_filter?: string[];
  last_mode?: string | null;
  last_run_at?: string | null;
  last_run_summary?: JsonValue;
  latest_workers?: JsonValue[];
  lease_heartbeat_at?: string | null;
  next_run_at?: string | null;
  processed_count?: number;
  raw_idempotency_key_echoed?: false;
  raw_payment_payload_returned?: false;
  raw_provider_payload_returned?: false;
  schema: "admin_subscription_scheduler_supervisor_state.v1" | string;
  secret_safe?: true;
  skipped_count?: number;
  state_available: boolean;
  status: string;
  updated_at?: string;
  worker_id?: string;
};

export type SubscriptionSchedulerEventLeaseRequest = {
  lease_seconds?: number;
  reason?: string | null;
  worker_id?: string | null;
};

export type SubscriptionSchedulerEventLease = {
  authorization_returned: false;
  event: {
    due_now: boolean;
    effective_at: string;
    event_status: "scheduled" | "replayed" | string;
    event_type: string;
    id: string;
    idempotency_key_fingerprint: string;
    subscription_id: string;
    updated_at: string;
  };
  lease: JsonValue;
  next_action: string;
  raw_idempotency_key_echoed: false;
  raw_invoice_metadata_returned: false;
  raw_payment_payload_returned: false;
  raw_provider_payload_returned: false;
  schema: "admin_subscription_scheduler_worker_lease.v1" | string;
  secret_safe: true;
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
  balance?: {
    after?: string | null;
    before?: string | null;
    currency?: string | null;
    reason?: string | null;
    source?: string | null;
    status?: "config-needed" | "no-ledger" | string;
  } | null;
  created_at: string;
  currency: string;
  entry_type: LedgerEntryType;
  id: string;
  idempotency_key?: string;
  metadata?: JsonValue;
  occurred_at: string;
  policy_snapshot?: JsonValue;
  price_version_id?: string | null;
  project_id?: string | null;
  related_ledger_entry_id?: string | null;
  request_id?: string | null;
  refs?: {
    credit_grant_id?: string | null;
    invoice_id?: string | null;
    ledger_entry_id?: string | null;
    order_id?: string | null;
    payment_capture_id?: string | null;
    payment_intent_id?: string | null;
    price_version_id?: string | null;
    project_id?: string | null;
    ref_source?: string | null;
    refund_id?: string | null;
    related_ledger_entry_id?: string | null;
    request_id?: string | null;
    virtual_key_id?: string | null;
    voucher_id?: string | null;
    voucher_redemption_id?: string | null;
    wallet_id?: string | null;
  } | null;
  status: LedgerEntryStatus;
  tenant_id: string;
  trace_id?: string | null;
  usage_snapshot?: JsonValue;
  virtual_key_id?: string | null;
  wallet_id?: string | null;
};

export type LedgerEntryListFilters = {
  limit?: number;
  project_id?: string;
  request_id?: string;
  wallet_id?: string;
};

export type AdminManagedUserStatus = "active" | "disabled" | "deleted" | string;

export type AdminManagedUser = {
  created_at?: string | null;
  display_name?: string | null;
  email?: string | null;
  id: string;
  last_login_at?: string | null;
  metadata?: JsonValue | null;
  primary_project_id?: string | null;
  project_ids?: string[];
  status: AdminManagedUserStatus;
  tenant_id?: string | null;
};

export type MembershipProjectAccessSummary = {
  active_key_count?: number;
  active_profile_count: number;
  key_access_present: boolean;
  key_count?: number;
  key_default_profile_present?: boolean;
  profile_access_present: boolean;
  raw_policy_returned?: false;
  secret_returned: false;
  source: string;
  user_active_key_count?: number;
  user_key_count?: number;
};

export type MembershipRecentUsageSummary = {
  cost_present: boolean;
  failed_count?: number;
  final_cost: string;
  last_request_at?: string | null;
  payload_returned: false;
  request_count: number;
  source: string;
  succeeded_count?: number;
  window_days: number;
};

export type AdminProjectMemberCompactSummary = {
  membership_created_at?: string | null;
  membership_source: "project_members" | string;
  project_access: MembershipProjectAccessSummary;
  raw_email_returned?: false;
  recent_usage: MembershipRecentUsageSummary;
  role: string;
  safe_next_action: string;
  secret_returned: false;
  status: AdminManagedUserStatus;
  user_id: string;
};

export type AdminProjectMembersSummary = {
  member_count: number;
  members: AdminProjectMemberCompactSummary[];
  omitted_fields: string[];
  project_access: MembershipProjectAccessSummary;
  project_id: string;
  project_scoped: true;
  project_status: string;
  raw_email_returned: false;
  recent_usage: MembershipRecentUsageSummary;
  safe_next_action: string;
  schema: "admin_project_membership_compact_readback.v1" | string;
  secret_safe: true;
  source: string;
  tenant_id: string;
  tenant_scoped: true;
};

export type AdminUserMembershipProjectSummary = {
  membership_created_at?: string | null;
  membership_source: "project_members" | string;
  project_access: MembershipProjectAccessSummary;
  project_id: string;
  project_status: string;
  recent_usage: MembershipRecentUsageSummary;
  role: string;
  safe_next_action: string;
  secret_returned: false;
  status: string;
};

export type AdminUserMembershipSummary = {
  member_count: number;
  memberships: AdminUserMembershipProjectSummary[];
  omitted_fields: string[];
  raw_email_returned: false;
  safe_next_action: string;
  schema: "admin_user_membership_compact_readback.v1" | string;
  secret_safe: true;
  source: string;
  tenant_id: string;
  tenant_scoped: true;
  user_id: string;
};

export type AdminManagedUserListFilters = {
  limit?: number;
  project_id?: string;
  search?: string;
  status?: AdminManagedUserStatus;
};

export type PatchAdminManagedUserStatusRequest = {
  reason: string;
  status: Extract<AdminManagedUserStatus, "active" | "disabled"> | "active" | "disabled";
};

export type BulkAdminManagedUserStatusRequest = PatchAdminManagedUserStatusRequest & {
  user_ids: string[];
};

export type AdminManagedUserStatusReadback = {
  audit_log_readback: boolean;
  omitted_fields: string[];
  project_count: number;
  project_membership_readback: boolean;
  project_rollup_fallback: {
    requires_user_id_for_status_write: boolean;
    source: "wallet_virtual_key_request_ledger_rollup" | string;
    supported: boolean;
    write_allowed: false;
  };
  schema: "admin_managed_user_status_readback.v1" | string;
  secret_safe: true;
  source: "users_table_after_write" | string;
  status_matches_target: boolean;
  user_status: AdminManagedUserStatus;
};

export type AdminManagedUserStatusActionResult = {
  action_result: string;
  audit_log_id?: string | null;
  id: string;
  primary_project_id?: string | null;
  project_ids?: string[];
  readback?: AdminManagedUserStatusReadback;
  status: AdminManagedUserStatus;
  user_id: string;
};

export type AdminManagedUserBulkStatusRowResult = AdminManagedUserStatusActionResult & {
  error?: {
    code?: string;
    message?: string;
    status?: number;
  };
  operation_id?: string;
  requested_status?: AdminManagedUserStatus;
  secret_safe?: true;
  write_allowed?: boolean;
};

export type AdminManagedUserBulkStatusResponse = {
  affected_count: number;
  audit_log_ids: string[];
  failed_count: number;
  omitted_fields: string[];
  operation_id: string;
  project_rollup_fallback: {
    requires_user_id_for_status_write: boolean;
    source: "wallet_virtual_key_request_ledger_rollup" | string;
    supported: boolean;
    write_allowed: false;
  };
  requested_status: AdminManagedUserStatus;
  results: AdminManagedUserBulkStatusRowResult[];
  schema: "admin_managed_users_bulk_status.v1" | string;
  secret_safe: true;
};

export type AdminManagedUserBulkOperationPlanAction = "disable" | "restore" | "audit_export" | "review" | string;

export type AdminManagedUserBulkOperationPlanRequest = {
  action: AdminManagedUserBulkOperationPlanAction;
  filters?: AdminManagedUserListFilters;
  mode?: "dry_run";
  reason: string;
  selected_user_ids?: string[];
};

export type AdminManagedUserBulkOperationPlan = {
  action: AdminManagedUserBulkOperationPlanAction;
  affected_estimate: {
    active_user_count: number;
    disabled_user_count: number;
    estimated_user_count: number;
    estimate_source: "users_table_tenant_scoped_readback" | string;
    missing_selected_count: number;
  };
  apply_policy: {
    allowed_apply_actions: string[];
    apply_supported: false;
    dangerous_cross_tenant_write_allowed: false;
    message: string;
    safe_status_apply_path?: string | null;
  };
  audit_export_plan: {
    external_siem_connected: false;
    export_ready: boolean;
    forbidden_fields: string[];
    next_step: string;
    raw_snapshots_returned: false;
    recommended_format: "jsonl" | string;
    safe_fields: string[];
    schema: "admin_users_audit_export_plan.v1" | string;
    source: "audit_logs" | string;
    status: "plan-only" | string;
  };
  blocked_reasons: JsonValue[];
  mode: "dry_run" | string;
  omitted_fields: string[];
  project_rollup_fallback: {
    requires_user_id_for_status_write: boolean;
    source: "wallet_virtual_key_request_ledger_rollup" | string;
    supported: boolean;
    write_allowed: false;
  };
  reason_present: boolean;
  reason_required: true;
  risk_policy_summary: {
    automatic_enforcement: false;
    external_ml_connected: false;
    external_siem_connected: false;
    forbidden_material_returned: false;
    operator_confirmation_required: true;
    policy_source: "local_readback_rules" | string;
    schema: "admin_users_bulk_risk_policy_summary.v1" | string;
    signals: JsonValue;
    status: "review-ready" | "attention" | "blocked" | "no-op" | string;
    summary: string;
  };
  rows: Array<{
    blocked_reasons: string[];
    detail_path: string;
    planned_action_result: string;
    project_count: number;
    project_ids: string[];
    secret_safe: true;
    status: AdminManagedUserStatus;
    user_id: string;
    write_allowed: false;
  }>;
  schema: "admin_managed_users_bulk_operation_plan.v1" | string;
  scope: {
    cross_tenant_lookup_allowed: false;
    filter_project_id?: string | null;
    filter_search_present: boolean;
    filter_status?: AdminManagedUserStatus | null;
    limit: number;
    selected_user_count: number;
    source: "selected_user_ids" | "filters" | string;
    tenant_scope: "current_admin_tenant" | string;
  };
  secret_safe: true;
};

export type AdminManagedUserDetail = {
  schema: "admin_managed_user_detail.v1" | string;
  user: AdminManagedUser;
  membership_summary?: AdminUserMembershipSummary;
  wallet_summary: {
    active_wallet_count: number;
    currencies: JsonValue;
    first_wallet_created_at?: string | null;
    last_wallet_updated_at?: string | null;
    project_scoped: boolean;
    readback_status: "ready" | "no-project-membership" | string;
    source: "wallets" | string;
    wallet_count: number;
  };
  funding_source_readback?: FundingSourceReadback | null;
  key_summary: {
    active_key_count: number;
    inactive_key_count: number;
    key_count: number;
    last_key_used_at?: string | null;
    project_scoped: boolean;
    recent_keys: Array<{
      key_id?: string | null;
      key_prefix?: string | null;
      last_used_at?: string | null;
      project_id?: string | null;
      status?: string | null;
    }> | JsonValue;
    secret_returned: false;
    source: "virtual_keys" | string;
  };
  request_summary: {
    currencies: JsonValue;
    failed_count: number;
    final_cost: string;
    input_tokens: number;
    last_request_at?: string | null;
    output_tokens: number;
    payload_returned: false;
    project_scoped: boolean;
    recent_error_codes: JsonValue;
    request_count: number;
    source: "request_logs" | string;
    succeeded_count: number;
    success_rate?: number | null;
  };
  ledger_summary: {
    confirmed_credit_total: string;
    confirmed_debit_total: string;
    confirmed_entry_count: number;
    currencies: JsonValue;
    idempotency_key_returned: false;
    last_ledger_entry_at?: string | null;
    ledger_entry_count: number;
    project_scoped: boolean;
    source: "ledger_entries" | string;
  };
  recent_audit_summary: {
    audit_log_count: number;
    last_audit_at?: string | null;
    metadata_sanitized: true;
    raw_snapshots_returned: false;
    recent_actions: JsonValue;
    schema: "admin_user_recent_audit_summary.v1" | string;
    source: "audit_logs" | string;
  };
  risk_policy_summary: {
    automatic_enforcement: false;
    external_ml_connected: false;
    external_siem_connected: false;
    forbidden_material_returned: false;
    operator_confirmation_required: true;
    policy_source: "local_readback_rules" | string;
    recommendation: string;
    schema: "admin_user_risk_policy_summary.v1" | string;
    signals: {
      active_key_count: number;
      failed_request_count: number;
      project_count: number;
      user_status: AdminManagedUserStatus;
    };
    status: "normal" | "attention" | "config-needed" | string;
  };
  tenant_boundary: {
    boundary_status: "tenant-scoped" | "no-project-membership" | string;
    cross_tenant_lookup_allowed: false;
    cross_tenant_result_count: 0;
    project_count: number;
    project_ids: string[];
    project_rollup_fallback_write_allowed: false;
    requested_user_id: string;
    schema: "admin_user_tenant_boundary.v1" | string;
    source_tables: string[];
    tenant_id: string;
    tenant_scope: "current_admin_tenant" | string;
  };
  project_rollup_fallback: {
    requires_user_id_for_status_write: boolean;
    source: "wallet_virtual_key_request_ledger_rollup" | string;
    supported: boolean;
    write_allowed: false;
  };
  omitted_fields: string[];
  production_audit_report: {
    external_siem_connected: false;
    next_step: string;
    raw_snapshots_returned: false;
    schema: "admin_user_production_audit_report_minimal.v1" | string;
    source: "audit_logs" | string;
    status: "minimal-readback" | string;
  };
  secret_safe: true;
};

export type AdminWalletListFilters = {
  currency?: string;
  limit?: number;
  project_id?: string;
  status?: string;
};

export type AdminWalletDetailFilters = {
  ledger_window_days?: number;
};

export type AdminWalletInfo = {
  balance_floor: string;
  created_at: string;
  currency: string;
  id: string;
  name: string;
  project_id?: string | null;
  status: string;
  tenant_id: string;
  updated_at: string;
};

export type AdminWalletCreditGrant = {
  amount: string;
  created_at: string;
  currency: string;
  id: string;
  remaining_amount: string;
  source: string;
  status: string;
  valid_from: string;
  valid_until?: string | null;
};

export type AdminWalletCreditGrantsSummary = {
  active_amount_total: string;
  active_count: number;
  active_remaining_total: string;
  consumed_count: number;
  expired_amount_total: string;
  expired_count: number;
  grants: AdminWalletCreditGrant[];
  total_count: number;
  voided_count: number;
};

export type CreditGrantExpirationAvailableAmount = {
  active_count: number;
  available_amount: string;
  currency: string;
};

export type CreditGrantExpirationBoundedGrant = {
  credit_grant_id: string;
  currency: string;
  remaining_amount: string;
  status: string;
  valid_until?: string | null;
};

export type CreditGrantExpirationReadback = {
  active_count: number;
  api_key_secret_returned: false;
  authorization_returned: false;
  available_amount_by_currency: CreditGrantExpirationAvailableAmount[];
  bounded_grants: CreditGrantExpirationBoundedGrant[];
  bounded_ids_only: true;
  expired_count: number;
  expiring_soon_count: number;
  expiring_soon_window_days: number;
  next_expiration_at?: string | null;
  provider_key_returned: false;
  raw_ledger_metadata_returned: false;
  raw_payload_returned: false;
  raw_voucher_code_hash_returned: false;
  raw_voucher_code_returned: false;
  read_only: true;
  safe_next_action: string;
  schema: "credit_grant_expiration_readback.v1" | string;
  secret_safe: true;
  source: "credit_grants" | string;
  source_refs_presence: {
    admin_adjustment_source_ref_present: boolean;
    import_source_ref_present: boolean;
    payment_source_ref_present: boolean;
    raw_source_ref_returned: false;
    subscription_source_ref_present: boolean;
    voucher_source_ref_present: boolean;
  };
  total_count: number;
  wallet_id: string;
};

export type FundingSourceCategory =
  | "voucher"
  | "manual_adjustment"
  | "payment_order"
  | "subscription_credit"
  | "negative_proration_credit"
  | string;

export type FundingSourceReadbackCategory = {
  amount_by_currency: Array<{
    amount: string;
    currency: string;
  }>;
  bounded_refs: Array<{
    amount: string;
    currency: string;
    source_id: string;
    source_table: "credit_grants" | "ledger_entries" | "payment_orders" | "subscription_events_or_schedules" | string;
    status: string;
    wallet_id?: string | null;
  }>;
  category: FundingSourceCategory;
  count: number;
  ref_present: boolean;
  safe_next_action: string;
  source_status: "ready" | "not_observed" | "refs_absent" | string;
  statuses: string[];
};

export type FundingSourceReadback = {
  api_key_secret_returned: false;
  authorization_returned: false;
  bounded_ids_only: true;
  categories: FundingSourceReadbackCategory[];
  project_ids?: string[];
  provider_key_returned: false;
  raw_ledger_metadata_returned: false;
  raw_payload_returned: false;
  raw_voucher_code_hash_returned: false;
  raw_voucher_code_returned: false;
  read_only: true;
  safe_next_action: string;
  schema: "admin_wallet_funding_source_readback.v1" | string;
  secret_safe: true;
  source: "credit_grants_ledger_payment_orders_subscription_events" | string;
  source_status: "ready" | "not_observed" | "refs_absent" | string;
  total_source_count: number;
  wallet_id?: string | null;
};

export type AdminWalletLedgerBalanceWindow = {
  confirmed_credit_total: string;
  confirmed_debit_total: string;
  confirmed_net_amount: string;
  currency: string;
  last_confirmed_ledger_entry_id?: string | null;
  ledger_entry_count: number;
  pending_amount: string;
  reversed_amount: string;
  window_end: string;
  window_start: string;
};

export type AdminWalletPendingReserves = {
  newest_pending_reserve_at?: string | null;
  oldest_pending_reserve_at?: string | null;
  reserve_amount_total: string;
  reserve_count: number;
};

export type AdminWalletBoundedLinks = {
  audit_log_ids?: string[];
  ledger_entry_ids?: string[];
  link_policy?: string;
  request_ids?: string[];
  trace_ids?: string[];
};

export type AdminWalletCreditSurface = {
  bounded_links: AdminWalletBoundedLinks;
  budget_remaining: JsonValue;
  consistency: JsonValue;
  credit_grant_expiration_readback: CreditGrantExpirationReadback;
  funding_source_readback: FundingSourceReadback;
  credit_grants: AdminWalletCreditGrantsSummary;
  last_ledger_entry_ids: string[];
  ledger_balance_window: AdminWalletLedgerBalanceWindow;
  pending_reserves: AdminWalletPendingReserves;
  read_only: boolean;
  secret_safe: JsonValue;
  wallet: AdminWalletInfo;
};

export type LedgerAdjustmentOperation = "adjust" | "refund";
export type LedgerAdjustmentRequestMode = "dry_run" | "execute_contract" | "execute";

export type LedgerAdjustmentDryRunRequest = {
  amount: string;
  currency: string;
  mode?: LedgerAdjustmentRequestMode;
  operation: LedgerAdjustmentOperation;
  project_id?: string;
  reason: string;
  related_ledger_entry_id?: string;
  request_id?: string;
  wallet_id?: string;
};

export type LocalPaymentDemoCreateOrderRequest = {
  amount: string;
  currency: string;
  idempotency_key: string;
  project_id?: string;
  reason: string;
  tenant_id: string;
  wallet_id: string;
};

export type LocalPaymentDemoMarkPaidRequest = {
  payment_idempotency_key: string;
  reason: string;
  tenant_id: string;
};

export type PaymentProviderEventType = "callback" | "capture" | "refund" | "chargeback" | string;

export type PaymentProviderAdapterConfigStatus = {
  adapter: "stripe_like_sandbox" | string;
  adapter_enabled: boolean;
  authorization_echoed: false;
  credential_generation?: PaymentProviderMerchantCredentialGeneration;
  credential_source?: PaymentProviderMerchantCredentialSource;
  credential_fingerprint_present: boolean;
  credential_fingerprint_prefix?: string | null;
  credential_lifecycle: PaymentProviderCredentialLifecycleReadback;
  credential_present: boolean;
  credential_status: "enabled" | "disabled" | string;
  credential_value_echoed: false;
  db_url_echoed: false;
  merchant_account_present: boolean;
  merchant_connected: boolean;
  next_step: string;
  omitted_fields: string[];
  production_payment_evidence: false;
  provider: string;
  provider_secret_echoed: false;
  raw_webhook_body_echoed: false;
  schema: "payment_provider_adapter_config_status.v1" | string;
  secret_safe: true;
  signature_format_support: PaymentProviderSignatureFormatSupport;
  stripe_api_source_of_truth: PaymentProviderStripeApiSourceOfTruthReadback;
  signature_verifier_status: "disabled" | "config-needed" | "configured-not-validated" | string;
  status: "disabled" | "config-needed" | "ready-for-sandbox" | string;
  supported_events: PaymentProviderEventType[];
};

export type PaymentProviderStripeApiSourceOfTruthReadback = {
  adapter: "stripe_api_source_of_truth" | string;
  api_read_model: "stripe_api_object_fetch_plan_v1" | string;
  authorization_echoed: false;
  callback_source_selection: string;
  capture_source_selection: string;
  chargeback_source_selection: string;
  credential_source: string;
  credential_source_ready: boolean;
  fetch_adapter: StripeApiFetchAdapterReadback;
  network_call_enabled: false;
  object_ref_readback: {
    api_object_ref_mapping: string;
    event_type?: PaymentProviderEventType | null;
    local_payment_capture_ref_present: boolean;
    local_payment_intent_ref_present: boolean;
    local_refund_ref_present: boolean;
    provider_event_id_present: boolean;
    provider_object_id_present: boolean;
  };
  object_ref_requirements: {
    credential_secret_ref_required: boolean;
    event_id_required: boolean;
    local_intent_or_capture_ref_required_for_accounting: boolean;
    merchant_account_ref_required: boolean;
    object_id_required: boolean;
    webhook_secret_ref_required_for_callback: boolean;
  };
  omitted_fields: string[];
  production_payment_evidence: false;
  provider: string;
  provider_secret_echoed: false;
  raw_provider_payload_echoed: false;
  raw_webhook_body_echoed: false;
  refund_source_selection: string;
  sandbox_local_only: true;
  schema: "payment_provider_stripe_api_source_of_truth.v1" | string;
  secret_ref_required: true;
  secret_safe: true;
  source_of_truth_blocked_reason?: string | null;
  source_of_truth_status:
    | "unsupported_provider"
    | "credential_source_not_ready"
    | "ready_for_network_client_but_disabled"
    | string;
};

export type StripeApiObjectType = "event" | "payment_intent" | "charge" | "refund" | "dispute" | string;

export type StripeApiFetchRequest = {
  credential_secret_ref_required: boolean;
  expand: string[];
  merchant_account_ref_required: boolean;
  object_ref_present: boolean;
  object_ref_source: string;
  object_type: StripeApiObjectType;
  raw_object_ref_echoed: false;
};

export type StripeApiFetchResult = {
  authorization_echoed: false;
  blocked_reason?: string | null;
  http_client: "network_disabled" | string;
  network_call_performed: false;
  object_found?: boolean | null;
  object_ref_present: boolean;
  object_type: StripeApiObjectType;
  provider_secret_echoed: false;
  raw_object_payload_echoed: false;
  raw_object_ref_echoed: false;
  secret_safe: true;
  status: "network_disabled_ready" | "blocked" | string;
};

export type StripeApiFetchAdapterReadback = {
  adapter: "stripe_api_fetch" | string;
  adapter_ready_for_network_client: boolean;
  credential_source_ready: boolean;
  implementation: "network_disabled" | string;
  interface: "StripeApiFetchRequest -> StripeApiFetchResult" | string;
  network_call_enabled: false;
  network_call_performed: false;
  object_refs_ready: boolean;
  omitted_fields: string[];
  provider_supported: boolean;
  replace_with: string;
  requests: StripeApiFetchRequest[];
  results: StripeApiFetchResult[];
  schema: "payment_provider_stripe_api_fetch_adapter.v1" | string;
};

export type PaymentProviderMerchantCredentialRuntimeSecretResolution = {
  credential_secret_value_loaded: boolean;
  secret_storage_policy: "operator_secret_ref_only" | "legacy_env_fallback" | string;
  webhook_secret_ref_resolved: boolean;
  webhook_signing_secret_env_present: boolean;
};

export type PaymentProviderMerchantCredentialRotation = {
  active_generation?: number | null;
  current_credential_fingerprint_prefix?: string | null;
  disabled_at?: string | null;
  last_rotation_marker_hash?: string | null;
  last_rotation_marker_hash_present?: boolean;
  last_rotated_at?: string | null;
  previous_credential_fingerprint_prefix?: string | null;
  updated_at?: string | null;
  version?: number | null;
};

export type PaymentProviderMerchantCredentialGeneration = {
  active_generation?: number | null;
  enabled: boolean;
  fingerprint_prefix?: string | null;
  previous_fingerprint_prefix?: string | null;
  runtime_gate: "eligible" | "disabled" | "legacy_env_fallback" | "unknown" | string;
  status: "active" | "disabled" | "legacy_env_active" | "unknown" | string;
};

export type PaymentProviderMerchantCredentialSource = {
  credential_generation?: PaymentProviderMerchantCredentialGeneration;
  credential_fingerprint_prefix?: string | null;
  credential_id?: string;
  credential_secret_ref_present: boolean;
  credential_value_echoed: false;
  enabled: boolean;
  merchant_account_ref_present: boolean;
  provider: string;
  provider_secret_echoed: false;
  rotation: PaymentProviderMerchantCredentialRotation;
  runtime_secret_resolution: PaymentProviderMerchantCredentialRuntimeSecretResolution;
  schema: "payment_provider_merchant_credential_source.v1" | string;
  secret_value_returned: false;
  secret_value_stored: false;
  source: "tenant_db" | "env_fallback" | string;
  source_priority: "tenant_db_over_env" | "tenant_db_missing_env_fallback" | string;
  status: "enabled" | "disabled" | "missing" | string;
  tenant_id: string;
  webhook_secret_ref_present: boolean;
};

export type PaymentProviderMerchantCredentialPatchRequest = {
  credential_fingerprint_prefix?: string;
  credential_secret_ref?: string;
  enabled?: boolean;
  merchant_account_ref?: string;
  metadata?: JsonObject;
  provider: string;
  rotate_marker?: boolean;
  rotation_idempotency_key?: string;
  rotation_reason?: string;
  webhook_secret_ref?: string;
};

export type PaymentProviderCredentialRotationReadback = {
  active_generation?: number | null;
  idempotency_key_hash_stored: boolean;
  last_rotated_at?: string | null;
  new_fingerprint_prefix?: string | null;
  old_fingerprint_prefix?: string | null;
  rotate_requested: boolean;
  rotation_applied: boolean;
  rotation_marker_hash_echoed: false;
  rotation_marker_hash_present: boolean;
  rotation_replayed: boolean;
  rotation_version?: number | null;
  schema: "payment_provider_credential_rotation_readback.v1" | string;
  secret_value_returned: false;
  secret_value_stored: false;
};

export type PaymentProviderMerchantCredentialPatchResponse = {
  config_status: PaymentProviderAdapterConfigStatus;
  credential_generation?: PaymentProviderMerchantCredentialGeneration;
  credential_id: string;
  credential_source: PaymentProviderMerchantCredentialSource;
  omitted_fields: string[];
  provider: string;
  rotation_marker_applied: boolean;
  rotation_marker_replayed?: boolean;
  rotation_readback?: PaymentProviderCredentialRotationReadback;
  rotation_reason_present: boolean;
  schema: "payment_provider_merchant_credential_source.v1" | string;
  secret_value_returned: false;
  secret_value_stored: false;
};

export type PaymentProviderCredentialLifecycleReadback = {
  credential_present: boolean;
  credential_value_echoed: false;
  disabled_reason?: string | null;
  enabled: boolean;
  fingerprint_present: boolean;
  fingerprint_prefix?: string | null;
  refusal_reason?: string | null;
  secret_returned: false;
  status: "enabled" | "disabled" | string;
};

export type PaymentProviderSignatureFormatSupport = {
  formats: string[];
  header_names: string[];
  raw_header_echoed: false;
  raw_signature_echoed: false;
  timestamp_tolerance_seconds?: number | null;
};

export type PaymentProviderRefs = {
  audit_id?: string | null;
  credit_grant_id?: string | null;
  invoice_id?: string | null;
  ledger_entry_id?: string | null;
  order_id?: string | null;
  payment_capture_id?: string | null;
  payment_event_id?: string | null;
  payment_intent_id?: string | null;
  refund_id?: string | null;
  reversal_ledger_entry_id?: string | null;
};

export type PaymentProviderExecutorSafeRef = {
  present: boolean;
  hash?: string | null;
  fingerprint?: string | null;
};

export type PaymentProviderExecutorContract = {
  schema: "payment_provider_executor_contract.v1" | string;
  provider: string;
  action: PaymentProviderLocalExecutorAction;
  status: "planned" | "refused" | string;
  action_result: "capture_planned" | "refund_planned" | "chargeback_ack_planned" | "executor_refused" | string;
  required_refs: string[];
  amount: string;
  currency: string;
  reason_present: boolean;
  idempotency_key_hash_present: boolean;
  idempotency_fingerprint?: string | null;
  provider_refs: {
    provider_event_ref: PaymentProviderExecutorSafeRef;
    provider_object_ref: PaymentProviderExecutorSafeRef;
    dispute_ref: PaymentProviderExecutorSafeRef;
    charge_ref: PaymentProviderExecutorSafeRef;
    refund_ref: PaymentProviderExecutorSafeRef;
  };
  local_refs: PaymentProviderRefs;
  gate_readback: {
    status: "allowed" | "blocked" | string;
    adapter_enabled: boolean;
    merchant_connected: boolean;
    credential_present: boolean;
    credential_fingerprint_present: boolean;
    signature_verified: boolean;
    network_call_enabled: false;
    production_payment_evidence: false;
    refusal_reasons: string[];
  };
  secret_safe: true;
  raw_provider_payload_echoed: false;
  raw_idempotency_key_echoed: false;
  authorization_echoed: false;
  provider_secret_echoed: false;
  provider_ref_raw_echoed: false;
  validation_errors: string[];
  omitted_fields: string[];
};

export type PaymentProviderSimulatorEventRequest = {
  amount: string;
  credit_grant_id?: string;
  currency: string;
  event_type: PaymentProviderEventType;
  external_event_id: string;
  idempotency_key?: string;
  invoice_id?: string;
  ledger_entry_id?: string;
  order_id?: string;
  payment_capture_id?: string;
  payment_intent_id?: string;
  provider: string;
  reason: string;
  refund_id?: string;
  reversal_ledger_entry_id?: string;
  tenant_id: string;
};

export type PaymentProviderSimulatorEventResponse = {
  action_result: string;
  adapter_config: PaymentProviderAdapterConfigStatus;
  amount: string;
  audit_id?: string | null;
  authorization_echoed: false;
  currency: string;
  db_url_echoed: false;
  event_type: PaymentProviderEventType;
  external_event_id_hash: string;
  idempotency_key_hash?: string | null;
  merchant_connected: boolean;
  mode: "manual_local_simulator" | string;
  notes: string[];
  omitted_fields: string[];
  production_payment_evidence: false;
  provider: string;
  provider_callback_route?: string;
  provider_secret_echoed: false;
  raw_idempotency_key_echoed: false;
  raw_provider_payload_echoed: false;
  raw_webhook_body_echoed: false;
  real_provider_credentials_loaded: false;
  reason_provided?: boolean;
  refs: PaymentProviderRefs;
  runtime_write_performed: false;
  schema: "payment_provider_runtime_skeleton.v1" | string;
  secret_safe: true;
  signature_verification: string;
};

export type PaymentProviderWebhookSignatureStatus =
  | "signature_missing"
  | "config_needed"
  | "verified_stripe_like"
  | "verified_simulated"
  | "signature_mismatch"
  | "signature_replay_window_refused"
  | "refused"
  | string;

export type PaymentProviderWebhookEventRequest = {
  amount: string;
  credit_grant_id?: string;
  currency: string;
  event_type: PaymentProviderEventType;
  external_event_id: string;
  idempotency_key?: string;
  invoice_id?: string;
  ledger_entry_id?: string;
  order_id?: string;
  payment_capture_id?: string;
  payment_intent_id?: string;
  project_id?: string;
  refund_id?: string;
  reversal_ledger_entry_id?: string;
  tenant_id: string;
  wallet_id?: string;
};

export type PaymentProviderWebhookNativeEventRequest = JsonValue;

export type PaymentProviderWebhookEventWrite = {
  attempted: boolean;
  created_at?: string;
  db_event_type?: "provider_handoff" | "capture_confirm" | "refund" | "refusal" | string;
  metadata?: Record<string, unknown>;
  outcome?: string;
  payment_event_id?: string;
  provider_event_type?: PaymentProviderEventType;
  readback_status: "not_written" | "read_back" | string;
  reason?: string;
  request_summary?: Record<string, unknown>;
  written: boolean;
};

export type PaymentProviderSourceOfTruthSelection =
  | "local_db_verified"
  | "provider_api_required"
  | "provider_webhook_verified"
  | "refused"
  | string;

export type PaymentProviderSourceOfTruthPolicy = {
  schema: "payment_provider_source_of_truth_policy.v1" | string;
  scope: "capture" | "refund" | "chargeback" | "unknown" | string;
  source_selection: {
    capture: PaymentProviderSourceOfTruthSelection;
    refund: PaymentProviderSourceOfTruthSelection;
    chargeback: PaymentProviderSourceOfTruthSelection;
  };
  source_of_truth_status: "candidate_ready" | "blocked" | string;
  source_of_truth_blocker?: string | null;
  trust_local_accounting: boolean;
  provider_webhook_verified: boolean;
  credential_source_ready: boolean;
  production_reconciliation_matched: boolean;
  provider_api_readback_required: boolean;
  frontend_guidance: string;
  network_call_performed: false;
  raw_provider_payload_echoed: false;
  provider_secret_echoed: false;
  secret_safe: true;
};

export type PaymentProviderProductionReconciliation = Record<string, unknown> & {
  source_of_truth_status?: "candidate_ready" | "blocked" | string;
  source_of_truth_policy?: PaymentProviderSourceOfTruthPolicy;
  production_source_of_truth_candidate?: boolean;
  source_of_truth_blocked_reason?: string | null;
};

export type PaymentProviderBoundedExecutionPlan = {
  action_result: "not_executed" | "written" | "replayed" | string;
  attempted: boolean;
  authorization_echoed: false;
  chargeback_policy?: Record<string, unknown>;
  credit_executor?: Record<string, unknown>;
  credit_reversal_executor?: Record<string, unknown>;
  db_url_echoed: false;
  disabled_writes: string[];
  event_type?: PaymentProviderEventType;
  mode: "verified_simulated_min_executor" | string;
  next_step?: string;
  payment_capture?: Record<string, unknown>;
  payment_event_id?: string;
  payment_refund?: Record<string, unknown>;
  ledger_executor?: Record<string, unknown>;
  production_reconciliation?: PaymentProviderProductionReconciliation;
  provider?: string;
  provider_secret_echoed: false;
  raw_idempotency_key_echoed: false;
  raw_provider_payload_echoed: false;
  raw_webhook_body_echoed: false;
  reason?: string;
  reconciliation?: Record<string, unknown>;
  refs?: Record<string, unknown>;
  schema: "payment_provider_bounded_execution_plan.v1" | string;
  secret_safe: true;
  wallet_accounting?: Record<string, unknown>;
  writes: Record<string, string>;
};

export type PaymentProviderWebhookEventResponse = {
  action_result: "signature_missing" | "config_needed" | "verified_stripe_like" | "verified_simulated" | "refused" | string;
  adapter?: "stripe_like_sandbox" | string;
  adapter_normalization?: PaymentProviderStripeLikeSandboxAdapterReadback | Record<string, unknown> | null;
  adapter_config: PaymentProviderAdapterConfigStatus;
  adapter_readback?: PaymentProviderStripeLikeSandboxAdapterReadback | Record<string, unknown> | null;
  amount?: string;
  authorization_echoed: false;
  currency?: string;
  db_url_echoed: false;
  event_type?: PaymentProviderEventType;
  event_write: PaymentProviderWebhookEventWrite;
  execution_plan: PaymentProviderBoundedExecutionPlan;
  external_event_id_hash?: string;
  idempotency_key_hash?: string | null;
  merchant_connected: boolean;
  mode: "real_provider_webhook_boundary" | string;
  omitted_fields: string[];
  production_payment_evidence: false;
  provider: string;
  provider_secret_echoed: false;
  raw_idempotency_key_echoed?: false;
  raw_provider_payload_echoed: false;
  raw_webhook_body_echoed: false;
  refs?: PaymentProviderRefs;
  runtime_write_performed: boolean;
  schema: "payment_provider_webhook_event_write_readback.v1" | string;
  secret_safe: true;
  signature_verification: PaymentProviderWebhookSignatureStatus;
  stripe_api_source_of_truth?: PaymentProviderStripeApiSourceOfTruthReadback | null;
  unsupported_reason?: string;
};

export type PaymentProviderLocalExecutorAction = "capture" | "refund" | "chargeback_ack" | string;

export type PaymentProviderLocalExecutorRequest = {
  action: PaymentProviderLocalExecutorAction;
  amount: string;
  credit_grant_id?: string;
  currency: string;
  dispute_ref?: string;
  idempotency_key: string;
  invoice_id?: string;
  ledger_entry_id?: string;
  metadata?: JsonObject;
  order_id?: string;
  payment_capture_id?: string;
  payment_intent_id?: string;
  project_id?: string;
  provider: string;
  provider_event_ref?: string;
  provider_object_ref?: string;
  provider_object_source_of_truth?: JsonObject;
  provider_object_payload?: JsonObject;
  stripe_like_provider_object_source_of_truth?: JsonObject;
  reason: string;
  refund_id?: string;
  reversal_ledger_entry_id?: string;
  tenant_id: string;
  wallet_id?: string;
};

export type PaymentProviderStripeLikeClientOperation =
  | "retrieve_payment_intent"
  | "retrieve_charge"
  | "retrieve_refund"
  | "retrieve_dispute"
  | "capture_payment_intent"
  | "create_refund"
  | "chargeback_ack"
  | string;

export type PaymentProviderStripeLikeClientBodyFieldReadback = {
  name: string;
  source: string;
  value_echoed: false;
  value_present: boolean;
};

export type PaymentProviderStripeLikeClientRequestPlan = {
  operation: PaymentProviderStripeLikeClientOperation;
  method: "GET" | "POST" | string;
  path_template: string;
  path_ref_source: string;
  path_ref_present: boolean;
  body_fields: PaymentProviderStripeLikeClientBodyFieldReadback[];
  idempotency_header_required: boolean;
  idempotency_header_present: boolean;
  idempotency_header_value_echoed: false;
  credential_source_required: true;
  credential_source_ready: boolean;
  authorization_header_required: true;
  authorization_header_value_echoed: false;
  merchant_account_ref_required: true;
  merchant_account_ref_present: boolean;
  raw_provider_payload_echoed: false;
};

export type PaymentProviderStripeLikeClientRequestPlanReadback = {
  schema: "payment_provider_stripe_like_client_plan.v1" | string;
  provider: string;
  status: "network_disabled_ready" | "blocked" | string;
  request: PaymentProviderStripeLikeClientRequestPlan;
  network_call_performed: false;
  http_client: "request_plan_only" | string;
  object_found?: boolean | null;
  credential_source_required: true;
  credential_source: string;
  required_refs: string[];
  validation_errors: string[];
  blocked_reasons: string[];
  secret_safe: true;
  raw_secret_echoed: false;
  authorization_echoed: false;
  raw_idempotency_key_echoed: false;
  raw_provider_payload_echoed: false;
  raw_provider_ref_echoed: false;
  omitted_fields: string[];
};

export type PaymentProviderStripeLikeProviderObjectSummary = {
  schema: "payment_provider_stripe_like_source_of_truth_summary.v1" | string;
  provider: string;
  provider_object_type?: string | null;
  provider_object_type_raw?: string | null;
  provider_object_id_present: boolean;
  provider_object_id_hash?: string | null;
  status?: string | null;
  amount?: string | null;
  currency?: string | null;
  local_refs: {
    metadata_present: boolean;
    local_ref_count: number;
    refs: Array<{
      name: string;
      present: boolean;
      value_hash?: string | null;
    }>;
  };
  captured: Record<string, unknown>;
  refunded: Record<string, unknown>;
  disputed: Record<string, unknown>;
  unsupported_field_reasons: string[];
  missing_field_reasons: string[];
  sensitive_field_presence_detected: boolean;
  secret_safe: true;
  raw_provider_payload_echoed: false;
  raw_customer_echoed: false;
  raw_email_echoed: false;
  raw_payment_method_echoed: false;
  raw_receipt_url_echoed: false;
  raw_billing_details_echoed: false;
  omitted_fields: string[];
};

export type PaymentProviderStripeLikeFetchExecutorReadback = {
  schema: "payment_provider_stripe_like_fetch_executor.v1" | string;
  provider: string;
  status: "object_not_loaded" | "fixture_parsed" | "network_client_not_configured" | string;
  interface: string;
  implementation: "network_disabled_fixture_parser" | string;
  replace_with: string;
  request_plan: PaymentProviderStripeLikeClientRequestPlan;
  network_call_enabled: boolean;
  network_call_performed: false;
  http_client: "not_configured" | string;
  object_found?: boolean | null;
  provider_object_summary?: PaymentProviderStripeLikeProviderObjectSummary | null;
  fixture_response_parsed: boolean;
  parser_summary_available: boolean;
  blocked_reasons: string[];
  secret_safe: true;
  raw_secret_echoed: false;
  authorization_echoed: false;
  raw_idempotency_key_echoed: false;
  raw_provider_payload_echoed: false;
  raw_provider_ref_echoed: false;
  omitted_fields: string[];
};

export type PaymentProviderStripeLikeProviderObjectSummaryReadback = {
  schema: "payment_provider_stripe_like_provider_object_summary_readback.v1" | string;
  status: "loaded" | "blocked" | string;
  source_of_truth_status: "loaded_from_request" | "object_not_loaded" | string;
  blocked_reason?: "network_disabled" | string | null;
  next_step?: "fetch_provider_object_source_of_truth" | string | null;
  provider: string;
  expected_object_type: "payment_intent" | "refund" | "dispute" | string;
  expected_statuses: string[];
  expected_local_refs: string[];
  summary?: Record<string, unknown> | null;
  object_type_readback?: Record<string, unknown>;
  object_ref_readback: Record<string, unknown>;
  status_readback: Record<string, unknown>;
  amount_readback: Record<string, unknown>;
  currency_readback: Record<string, unknown>;
  local_metadata_ref_readback: Record<string, unknown>;
  network_call_enabled: false;
  network_call_performed: false;
  provider_object_source_of_truth_echoed: false;
  raw_provider_payload_echoed: false;
  raw_provider_ref_echoed: false;
  raw_idempotency_key_echoed: false;
  authorization_echoed: false;
  provider_secret_echoed: false;
  secret_safe: true;
  omitted_fields: string[];
};

export type PaymentProviderLocalExecutorReadback = {
  action: PaymentProviderLocalExecutorAction;
  action_result: "applied" | "replayed" | "blocked" | "refused" | string;
  adapter_config: PaymentProviderAdapterConfigStatus;
  amount: string;
  authorization_echoed: false;
  billing_ledger_executor_contract: PaymentProviderExecutorContract;
  credential_source: PaymentProviderMerchantCredentialSource;
  currency: string;
  db_url_echoed: false;
  event_type: PaymentProviderEventType;
  event_write?: PaymentProviderWebhookEventWrite;
  execution_plan: PaymentProviderBoundedExecutionPlan;
  executor_request: Record<string, unknown>;
  executor_result: {
    applied: boolean;
    blocked: boolean;
    payment_event_id?: string;
    reason?: string;
    refused: boolean;
    replayed: boolean;
    runtime_write_performed: boolean;
    status: "applied" | "replayed" | "blocked" | "refused" | string;
  };
  merchant_connected: boolean;
  mode: "typed_local_executor" | string;
  omitted_fields: string[];
  production_payment_evidence: false;
  provider: string;
  provider_secret_echoed: false;
  raw_idempotency_key_echoed: false;
  raw_provider_payload_echoed: false;
  refusal_reason?: string;
  schema: "payment_provider_local_executor_readback.v1" | string;
  secret_safe: true;
  stripe_like_client_request_plan: PaymentProviderStripeLikeClientRequestPlanReadback;
  stripe_like_fetch_executor: PaymentProviderStripeLikeFetchExecutorReadback;
  stripe_like_provider_object_summary: PaymentProviderStripeLikeProviderObjectSummaryReadback;
  stripe_like_response_object_reconciliation?: {
    schema: "payment_provider_stripe_like_response_object_reconciliation.v1" | string;
    status: "matched" | "mismatch" | "blocked" | string;
    action: PaymentProviderLocalExecutorAction | string;
    matched: boolean;
    provider: string;
    provider_object_summary_present: boolean;
    response_header_summary_present: boolean;
    provider_object_type_matches?: boolean | null;
    provider_status_matches?: boolean | null;
    amount_matches?: boolean | null;
    currency_matches?: boolean | null;
    local_refs_match?: boolean | null;
    expected_provider_object_types: string[];
    expected_provider_statuses: string[];
    expected_local_refs: string[];
    mismatch_reasons: string[];
    blocked_reasons: string[];
    retry_recommended: boolean;
    retry_reason: string;
    safe_next_action: string;
    network_call_performed: false;
    secret_safe: true;
    raw_provider_payload_echoed: false;
    raw_headers_echoed: false;
    raw_provider_ref_echoed: false;
    authorization_echoed: false;
    provider_secret_echoed: false;
    omitted_fields: string[];
  };
  stripe_api_source_of_truth: PaymentProviderStripeApiSourceOfTruthReadback;
};

export type PaymentProviderStripeLikeSandboxAdapterReadback = {
  adapter: "stripe_like_sandbox";
  authorization_echoed: false;
  db_url_echoed: false;
  event_mapping: {
    normalized_event_type?: PaymentProviderEventType | null;
    provider_event_type?: string | null;
    supported: boolean;
    unsupported_reason?: string | null;
  };
  provider_event_readback: {
    amount_present: boolean;
    currency_present: boolean;
    local_ref_count: number;
    metadata_present: boolean;
    provider_event_id_hash?: string | null;
    provider_event_id_present: boolean;
    provider_event_type?: string | null;
    provider_event_type_present: boolean;
    provider_object_id_hash?: string | null;
    provider_object_id_present: boolean;
    raw_idempotency_key_echoed: false;
    raw_provider_payload_echoed: false;
    refusal_reason?: string | null;
    schema_valid: boolean;
    tenant_id_present: boolean;
  };
  normalized_event?: {
    amount: string;
    currency: string;
    event_type: PaymentProviderEventType;
    external_event_id: string;
    idempotency_key?: null;
    tenant_id?: string | null;
    order_id?: string | null;
    project_id?: string | null;
    wallet_id?: string | null;
    payment_intent_id?: string | null;
    payment_capture_id?: string | null;
    refund_id?: string | null;
    credit_grant_id?: string | null;
    ledger_entry_id?: string | null;
    reversal_ledger_entry_id?: string | null;
    invoice_id?: string | null;
  } | null;
  omitted_fields: string[];
  provider: string;
  provider_secret_echoed: false;
  provider_supported: boolean;
  raw_idempotency_key_echoed: false;
  raw_provider_payload_echoed: false;
  raw_webhook_body_echoed: false;
  schema: "payment_provider_stripe_like_sandbox_adapter.v1" | string;
  secret_safe: true;
  signature_format_support: PaymentProviderSignatureFormatSupport;
  signature_parse: {
    format: "stripe_like" | "fubox_simulated_sha256" | "fubox_simulated_bare_hex" | "missing" | "unsupported" | string;
    header_name?: string | null;
    header_present: boolean;
    raw_header_echoed: false;
    raw_signature_echoed: false;
    selected_scheme?: string | null;
    signature_count: number;
    signature_present: boolean;
    timestamp?: number | null;
    timestamp_present: boolean;
    unsupported_reason?: string | null;
  };
  signature_verification_readback?: {
    format: string;
    mismatch_reason?: string | null;
    payload_sha256: string;
    raw_header_echoed: false;
    raw_payload_echoed: false;
    raw_signature_echoed: false;
    replay_window_ok: boolean;
    secret_echoed: false;
    signature_match: boolean;
    signature_present: boolean;
    signed_payload_basis: "stripe:t.raw_body" | "raw_body" | string;
    signed_payload_sha256?: string | null;
    status: "verified" | "refused" | string;
    timestamp_age_seconds?: number | null;
    timestamp_present: boolean;
    timestamp_tolerance_seconds?: number | null;
  } | null;
  unsupported_reason?: string | null;
};

export type LocalPaymentDemoResponse = {
  accounting: {
    amount: string;
    credit_source: string;
    currency: string;
    invoice_policy: string;
    receipt_policy?: string;
    reconciliation_policy?: string;
    ledger_entry_type: string;
    ledger_operation: string;
    ledger_status: string;
    money_scale: number;
  };
  contract?: JsonValue;
  extra?: JsonValue;
  local_only: true;
  merchant_connected: false;
  mode: "local_runtime_demo" | string;
  notes: string[];
  operation: string;
  order: {
    amount: string;
    created_at: string;
    currency: string;
    id: string;
    project_id?: string | null;
    source: string;
    status: string;
    tenant_id: string;
    updated_at: string;
    wallet_id: string;
  };
  outcome: string;
  production_payment_evidence: false;
  raw_idempotency_key_echoed: false;
  raw_metadata_echoed: false;
  raw_provider_payload_echoed: false;
  invoice?: {
    amount: string;
    currency: string;
    invoice_id?: string | null;
    invoice_number?: string | null;
    legal_invoice: false;
    next_step: string;
    status: string;
  };
  receipt?: {
    amount: string;
    currency: string;
    legal_receipt: false;
    next_step: string;
    receipt_id?: string | null;
    receipt_number?: string | null;
    status: string;
  };
  reconciliation?: {
    amount: string;
    currency: string;
    invoice_id?: string | null;
    ledger_entry_id?: string | null;
    marker_id?: string | null;
    matched: boolean;
    next_step: string;
    payment_capture_id?: string | null;
    status: string;
  };
  invoice_receipt_reconciliation_readback?: {
    authorization_echoed: false;
    invoice_status: string;
    ledger_refs_presence: {
      credit_grant_id_present: boolean;
      ledger_entry_id_present: boolean;
      ledger_status: string;
      present: boolean;
    };
    legal_invoice: false;
    legal_receipt: false;
    local_only: true;
    merchant_connected: false;
    payment_refs_presence: {
      payment_capture_id_present: boolean;
      payment_intent_id_present: boolean;
      present: boolean;
      provider_event_refs_present: boolean;
      provider_reference_redacted: boolean;
    };
    production_payment_evidence: false;
    provider_secret_echoed: false;
    raw_idempotency_key_echoed: false;
    raw_invoice_metadata_echoed: false;
    raw_provider_payload_echoed: false;
    receipt_status: string;
    reconciliation_refs_presence: {
      invoice_id_present: boolean;
      ledger_entry_id_present: boolean;
      marker_id_present: boolean;
      payment_capture_id_present: boolean;
      present: boolean;
      receipt_id_present: boolean;
    };
    reconciliation_status: string;
    safe_next_action: string;
    schema: "invoice_receipt_reconciliation_readback.v1" | string;
    secret_safe: true;
    source: "local_payment_demo_runtime_readback" | string;
    status: "pending_payment" | "matched" | "incomplete_readback" | string;
  };
  ledger_refs?: {
    credit_grant_id?: string | null;
    ledger_entry_id?: string | null;
    ledger_entry_type: string;
    ledger_operation: string;
    ledger_status: string;
  };
  payment_refs?: {
    order_id: string;
    payment_capture_id?: string | null;
    payment_intent_id?: string | null;
    provider_reference?: string | null;
    provider_reference_redacted: boolean;
  };
  refs: {
    audit_id?: string | null;
    credit_grant_id?: string | null;
    invoice_id?: string | null;
    ledger_entry_id?: string | null;
    order_id: string;
    payment_capture_id?: string | null;
    payment_intent_id?: string | null;
    receipt_id?: string | null;
    reconciliation_id?: string | null;
  };
  schema: "billing_local_payment_demo.v1" | string;
  secret_safe: true;
};

export type LedgerAdjustmentRelatedEntrySummary = {
  amount: string;
  currency: string;
  entry_type: LedgerEntryType;
  id: string;
  project_id?: string | null;
  related_ledger_entry_id?: string | null;
  request_id?: string | null;
  status: LedgerEntryStatus;
  wallet_id?: string | null;
};

export type LedgerAdjustmentPlannedEntry = {
  amount: string;
  currency: string;
  dedupe_policy: string;
  entry_type: LedgerEntryType;
  metadata_policy: string;
  project_id?: string | null;
  related_ledger_entry_id?: string | null;
  request_id?: string | null;
  status: "planned" | string;
  wallet_id?: string | null;
};

export type LedgerAdjustmentDryRunValidation = {
  amount_checked: boolean;
  currency_checked: boolean;
  refund_remaining_checked: boolean;
  reason_provided: boolean;
  related_ledger_entry_checked: boolean;
  sensitive_material_policy: string;
};

export type LedgerRefundRemainingSummary = {
  confirmed_credit_amount: string;
  confirmed_credit_count: number;
  confirmed_only: boolean;
  credit_entry_types: string[];
  currency: string;
  currency_bounded: boolean;
  remaining_refundable_amount: string;
  requested_refund_amount: string;
  source_debit_amount: string;
  source_entry_bounded: boolean;
  tenant_bounded: boolean;
};

export type LedgerAdjustmentFutureWriteContract = {
  audit_action: string;
  audit_insert_failure_rolls_back_ledger_write: boolean;
  audit_snapshot_policy: string;
  business_and_success_audit_share_transaction: boolean;
  ledger_write: false;
  refusal_does_not_build_success_audit: boolean;
  success_audit_only_after_ledger_write: boolean;
  upstream_call: false;
};

export type LedgerAdjustmentDryRunResponse = {
  audit_log_write: false;
  future_write_contract: LedgerAdjustmentFutureWriteContract;
  ledger_adjustment_execution_readback?: LedgerAdjustmentExecutionReadback;
  ledger_write: false;
  operation: LedgerAdjustmentOperation;
  plan_only: true;
  planned_ledger_entry: LedgerAdjustmentPlannedEntry;
  project_id?: string | null;
  related_ledger_entry?: LedgerAdjustmentRelatedEntrySummary | null;
  refund_remaining_summary?: LedgerRefundRemainingSummary | null;
  request_id?: string | null;
  request_log_write: false;
  tenant_id: string;
  upstream_call: false;
  validation: LedgerAdjustmentDryRunValidation;
  wallet_id?: string | null;
};

export type LedgerAdjustmentExecuteContractFlags = {
  audit_insert_failure_rolls_back_ledger_write: boolean;
  audit_log_write: boolean;
  audit_snapshot_policy?: string;
  business_and_success_audit_share_transaction: boolean;
  contract_version?: string;
  dedupe_material_echoed?: boolean;
  dedupe_contract?: {
    client_supplied_dedupe_material_rejected?: boolean;
    conflicting_duplicate_refused_before_ledger_insert?: boolean;
    dedupe_material_echoed?: boolean;
    public_output?: string;
    replay_same_digest_returns_prior_result_after_writer_exists?: boolean;
    server_generated_dedupe_material?: boolean;
  };
  dry_run_constraints_enforced_before_refusal?: string[];
  future_writer_required?: boolean;
  ledger_executor_refusal_summary_contract?: LedgerExecutorRefusalSummaryContract;
  ledger_executor_summary_contract?: LedgerExecutorSummaryContract;
  ledger_write: boolean;
  ledger_writer_contract?: {
    future_writer?: string;
    insert_status_on_success?: string;
    metadata_policy?: string;
    refund_over_remaining_refused_after_locked_recompute?: boolean;
    write_performed?: boolean;
  };
  refusal_does_not_build_success_audit: boolean;
  request_log_write: boolean;
  request_log_contract?: {
    future_behavior?: string;
    request_log_mutation_allowed?: boolean;
    request_material_echoed?: boolean;
    write_performed?: boolean;
  };
  safe_output_contract?: {
    audit_snapshot_policy?: string;
    credential_material_echoed?: boolean;
    dedupe_material_echoed?: boolean;
    request_material_echoed?: boolean;
  };
  server_generated_dedupe_material?: boolean;
  success_audit_only_after_ledger_write: boolean;
  transaction_contract?: {
    begin_before_locking?: boolean;
    bounded_by?: string[];
    bounded_lock_order?: string[];
    commit_only_after_ledger_and_success_audit?: boolean;
    future_isolation?: string;
    recompute_after_locks?: string[];
    rollback_on_audit_insert_failure?: boolean;
    rollback_on_ledger_write_failure?: boolean;
    rollback_on_refund_remaining_change?: boolean;
    rollback_executor_summary_contract?: LedgerExecutorRollbackSummaryContract;
    unbounded_scan_allowed?: boolean;
  };
  upstream_call: boolean;
  validated_before_refusal?: boolean;
  audit_contract?: {
    audit_insert_failure_rolls_back_ledger_write?: boolean;
    business_and_success_audit_share_transaction?: boolean;
    refusal_does_not_build_success_audit?: boolean;
    snapshot_policy?: string;
    success_audit_only_after_ledger_write?: boolean;
    write_performed?: boolean;
  };
};

export type LedgerAdjustmentExecuteContractResponse = {
  execute_contract: LedgerAdjustmentExecuteContractFlags;
  ledger_adjustment_execution_readback?: LedgerAdjustmentExecutionReadback;
  ledger_executor_summary?: LedgerExecutorSummary;
  mode: "execute_contract";
  validated_plan: LedgerAdjustmentDryRunResponse;
};

export type LedgerAdjustmentExecuteOutcome = "applied" | "idempotent" | "blocked" | "failed" | string;

export type LedgerExecutorSummaryContract = {
  compatible_fields?: string[];
  credential_material_echoed?: boolean;
  dedupe_material_echoed?: boolean;
  error_detail_output?: string;
  operation_key_output?: string;
  raw_metadata_echoed?: boolean;
  raw_executor_error_detail_echoed?: boolean;
  response_field?: string;
  schema_version?: string;
};

export type LedgerExecutorRefusalSummaryContract = LedgerExecutorSummaryContract & {
  preflight_refusal?: LedgerExecutorRefusalContractSummary;
  rollback_refusal?: LedgerExecutorRefusalContractSummary;
  supported_outcomes?: string[];
};

export type LedgerExecutorRollbackSummaryContract = LedgerExecutorSummaryContract & LedgerExecutorRefusalContractSummary & {
  outcome?: string;
};

export type LedgerExecutorRefusalContractSummary = {
  committed?: boolean;
  refused_statement_count?: number | string;
  rolled_back?: boolean;
  row_count_mismatch?: boolean | string;
};

export type LedgerExecutorSummary = {
  committed?: boolean;
  dedupe_material_echoed?: boolean;
  error_detail_output?: string;
  executed_statement_count?: number;
  executor?: string;
  final_statement_kind?: string | null;
  final_statement_order?: number | null;
  omitted_material?: string[];
  operation?: string;
  operation_key_output?: string;
  outcome?: string;
  raw_executor_error_detail_echoed?: boolean;
  refused_statement_count?: number;
  rolled_back?: boolean;
  row_count_mismatch?: boolean;
  schema_version?: string;
  statement_count?: number;
  total_rows_affected?: number;
};

export type LedgerAdjustmentExecutionReadback = {
  blocked_reasons: string[];
  idempotency: {
    fingerprint: string;
    raw_idempotency_hash_returned: boolean;
    raw_idempotency_returned: boolean;
    source: string;
  };
  mode: "dry_run" | "execute" | "execute_contract" | string;
  outcome: "dry_run" | "applied" | "idempotent" | "refused_preflight" | "refused_rollback" | string;
  refs_presence: {
    budget_ref_present: boolean;
    credit_grant_ref_present: boolean;
    ledger_entry_ref_present: boolean;
    ref_values_policy: string;
    related_ledger_entry_ref_present: boolean;
    request_ref_present: boolean;
    wallet_ref_present: boolean;
  };
  safe_next_action: string;
  schema: "ledger_adjustment_execution_readback.v1" | string;
  secret_safety: {
    authorization_returned: boolean;
    provider_key_returned: boolean;
    raw_idempotency_returned: boolean;
    raw_metadata_returned: boolean;
    raw_sql_returned: boolean;
    wallet_secret_returned: boolean;
  };
  status: "plan_only" | "readback_ready" | "refused" | string;
};

export type LedgerAdjustmentExecutedEntrySummary = LedgerAdjustmentRelatedEntrySummary & {
  omitted_material?: string[];
  tenant_id?: string | null;
};

export type LedgerAdjustmentExecuteTransactionContract = {
  begin_before_locking?: boolean;
  bounded_by?: string[];
  bounded_lock_order?: string[];
  commit_only_after_ledger_and_success_audit?: boolean;
  dedupe_material_echoed?: boolean;
  isolation?: string;
  rollback_on_audit_insert_failure?: boolean;
  rollback_on_ledger_write_failure?: boolean;
  rollback_on_refund_remaining_change?: boolean;
  rollback_executor_summary_contract?: LedgerExecutorRollbackSummaryContract;
  unbounded_scan_allowed?: boolean;
  write_performed?: boolean;
  writer?: string;
};

export type LedgerAdjustmentFutureExecuteResponse = {
  audit_log_write: boolean;
  audit_insert_failure_rolls_back_ledger_write?: boolean;
  audit_log_id?: string | null;
  business_and_success_audit_share_transaction?: boolean;
  dedupe_material_echoed?: boolean;
  dedupe_public_output?: string;
  executed?: boolean;
  ledger_adjustment_execution_readback?: LedgerAdjustmentExecutionReadback;
  ledger_entry?: LedgerAdjustmentExecutedEntrySummary;
  ledger_executor_summary?: LedgerExecutorSummary;
  ledger_executor_summary_contract?: LedgerExecutorSummaryContract;
  ledger_write: boolean;
  mode: "execute";
  outcome?: LedgerAdjustmentExecuteOutcome;
  refusal_does_not_build_success_audit?: boolean;
  refund_remaining_summary?: LedgerRefundRemainingSummary | null;
  request_log_write: boolean;
  success_audit_only_after_ledger_write?: boolean;
  transaction_contract?: LedgerAdjustmentExecuteTransactionContract;
  upstream_call: boolean;
  validated_plan?: JsonValue;
};

export type LedgerAdjustmentExecuteResponse =
  | LedgerAdjustmentExecuteContractResponse
  | LedgerAdjustmentFutureExecuteResponse;

export type LedgerAdjustmentExecuteResult =
  | {
      kind: "writer_required";
      message: string;
      response: LedgerAdjustmentExecuteContractResponse;
      status?: number;
    }
  | {
      kind: "contract_ready";
      response: LedgerAdjustmentExecuteContractResponse;
    }
  | {
      kind: "future_execute";
      response: LedgerAdjustmentFutureExecuteResponse;
    };

export type BillingReconciliationReportFilters = {
  day?: string;
  limit?: number;
  request_id?: string;
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

export type UserAuthRequest = {
  email: string;
  password: string;
};

export type UserRegisterRequest = UserAuthRequest & {
  display_name?: string;
};

export type UserAccount = {
  accepted_at?: string | null;
  display_name: string;
  email: string;
  id: string;
  pending_acceptance?: boolean;
  privacy_version?: string;
  tenant_id: string;
  terms_version?: string;
};

export type UserProject = {
  id: string;
  role: string;
};

export type UserAuthResponse = {
  project: UserProject;
  session: AdminSessionInfo;
  session_token_once: string;
  user: UserAccount;
};

export type UserMeResponse = {
  project: UserProject;
  session: AdminSessionInfo;
  user: UserAccount;
};

export type UserTeamMemberSummary = {
  membership_created_at?: string | null;
  membership_source: "project_members" | string;
  raw_email_returned: false;
  role: string;
  secret_returned: false;
  status: string;
  user_id: string;
};

export type UserTeamSummary = {
  handoff: {
    authorization_returned: false;
    contract: "GET /user/team-summary" | string;
    fallback: string;
    omitted_fields: string[];
    raw_email_returned: false;
    raw_metadata_returned: false;
    secret_returned: false;
    source: "user_session_project_scoped_membership_readback" | string;
  };
  membership_source: "user_session_project_members" | string;
  project_access: MembershipProjectAccessSummary;
  project_id: string;
  recent_usage: MembershipRecentUsageSummary;
  role: string;
  safe_next_action: string;
  schema: "user_team_membership_compact_readback.v1" | string;
  secret_safe: true;
  status: string;
  team_members: UserTeamMemberSummary[];
  tenant_id: string;
  user_id: string;
};

export type UserPasswordResetRequest = {
  email: string;
};

export type UserProductizationStatusResponse = {
  account_disclosure: "none" | string;
  audit?: JsonValue;
  code: string;
  delivery_mode?: "config-needed" | "queued" | "local-only" | string;
  email_delivery: "config_needed" | "pending" | string;
  email_configured?: boolean;
  expires_in_seconds?: number | null;
  message: string;
  next_action: string;
  request_id?: string;
  secret_safe: boolean;
  status: "pending" | "config-needed" | "config_needed" | string;
};

export type UserVirtualKeyStatus = "active" | "disabled" | "expired" | "deleted" | string;

export type UserVirtualKey = {
  budget_policy: JsonValue;
  default_profile_id?: string | null;
  id: string;
  ip_allowlist: JsonValue;
  key_prefix: string;
  metadata: JsonValue;
  name: string;
  policy_diagnostics?: VirtualKeyPolicyDiagnostics;
  project_id: string;
  rate_limit_policy: JsonValue;
  secret?: string | null;
  secret_once: boolean;
  secret_redacted: boolean;
  status: UserVirtualKeyStatus;
  tenant_id: string;
};

export type CreateUserVirtualKeyRequest = {
  budget_policy?: JsonValue;
  default_profile_id?: string;
  ip_allowlist?: JsonValue;
  metadata?: JsonValue;
  name: string;
  rate_limit_policy?: JsonValue;
};

export type UserBalance = {
  active_credit_grant_total: string;
  available_to_spend: string;
  credit_grant_expiration_readback?: CreditGrantExpirationReadback | null;
  funding_source_readback?: FundingSourceReadback | null;
  currency: string;
  last_credit_grant_ids: string[];
  last_ledger_entry_ids: string[];
  pending_confirmed_ledger_window: string;
  schema: string;
  secret_safe: boolean;
  wallet_id: string;
};

export type UserModelPrice = {
  currency?: string | null;
  effective_at?: string | null;
  estimate_label?: string | null;
  estimate_notice?: string | null;
  price_book_id?: string | null;
  price_summary?: string | null;
  price_version_id: string;
  pricing_rules?: JsonValue | null;
  retired_at?: string | null;
  secret_safe: boolean;
  version?: string | null;
};

export type UserModel = {
  context_length?: number | null;
  default_profile_id?: string | null;
  display_name: string;
  family?: string | null;
  id: string;
  max_output_tokens?: number | null;
  model: string;
  price?: UserModelPrice | null;
  primary_protocol?: string | null;
  protocol_modes?: string[];
  route_status?: string | null;
  routable: boolean;
  routable_channel_count: number;
  status: string;
  supports_audio: boolean;
  supports_reasoning: boolean;
  supports_stream: boolean;
  supports_tools: boolean;
  supports_vision: boolean;
  unavailable_reason?: string | null;
  unavailable_reasons?: string[];
  visibility: string;
};

export type ModelAvailabilityReadback = {
  blocked_models: {
    allowed_filter_hidden_count: number;
    explicit_denied_count: number;
    reasons: Array<{
      count: number;
      reason:
        | "profile_denied_model"
        | "profile_allowed_models_filter"
        | "visible_but_no_enabled_route"
        | string;
      sample_models: string[];
    }>;
    total_blocked: number;
    unroutable_visible_count: number;
  };
  handoff: {
    api_key_secret_hash_returned: false;
    authorization_returned: false;
    contract: string;
    omitted_fields: string[];
    provider_key_returned: false;
    raw_api_key_returned: false;
    raw_payload_returned: false;
    raw_route_policy_returned: false;
    source: "profile_filtered_model_and_guardrail_counts" | string;
  };
  protocol_capability_summary: Array<{
    protocol_mode: string;
    routable_model_count: number;
    status: "routable" | "config-needed" | string;
    visible_model_count: number;
  }>;
  quota_rate_budget_guardrails: {
    active_price_version_count: number;
    active_profile_count: number;
    active_virtual_key_count: number;
    budget_policy_present: boolean;
    budget_policy_present_count: number;
    pricing_guardrail_present: boolean;
    provider_key_returned: false;
    rate_limit_policy_present: boolean;
    rate_limit_policy_present_count: number;
    raw_policy_payload_returned: false;
  };
  safe_next_action: string;
  schema: "model_availability_readback.v1" | string;
  scope: {
    api_key_profile_id?: string | null;
    profile_status?: string | null;
    project_id: string;
    source: "user_session_project_profile_virtual_key_scope" | string;
    virtual_key_id?: string | null;
  };
  secret_safe: true;
  visible_models: UserHomeSummary["models"];
};

export type UserModelsMeta = {
  model_availability_readback?: ModelAvailabilityReadback;
  project_id: string;
  schema: "user_models.v1" | string;
  secret_safe: boolean;
  source: "active_user_profile" | string;
};

export type UserModelsEnvelope = {
  data: UserModel[];
  meta: UserModelsMeta;
};

export type UserVoucherRedeemRequest = {
  currency?: string;
  idempotency_key?: string;
  voucher_code: string;
};

export type UserVoucherRedeemReceipt = {
  amount?: string | null;
  code_locator?: string | null;
  code_redacted?: string | null;
  credit_grant_id?: string | null;
  currency?: string | null;
  expires_at?: string | null;
  idempotency_key?: "omitted" | string;
  ledger_entry_id?: string | null;
  project_id?: string | null;
  raw_idempotency_key_echoed?: false;
  raw_voucher_code_echoed?: false;
  redemption_id?: string | null;
  refs?: {
    credit_grant_id?: string | null;
    ledger_entry_id?: string | null;
    project_id?: string | null;
    tenant_id?: string | null;
    voucher_id?: string | null;
    voucher_redemption_id?: string | null;
    wallet_id?: string | null;
  };
  schema: "user_voucher_redeem_receipt.v1" | string;
  secret_safe?: true;
  status: string;
  tenant_id?: string | null;
  valid_until?: string | null;
  voucher_code?: "omitted" | string;
  voucher_id?: string | null;
  wallet_id?: string | null;
};

export type UserVoucherRedeemResponse = {
  amount?: string | null;
  code_locator?: string | null;
  code_redacted?: string | null;
  credit_grant_id?: string | null;
  currency?: string | null;
  expires_at?: string | null;
  ledger_entry_id?: string | null;
  operation: string;
  project_id?: string | null;
  receipt?: UserVoucherRedeemReceipt;
  redemption_id?: string | null;
  refusal_code?: string | null;
  status: string;
  tenant_id?: string | null;
  valid_until?: string | null;
  voucher_id?: string | null;
  wallet_id?: string | null;
};

export type AdminVoucherIssueRequest = {
  amount: string;
  campaign_id?: string | null;
  currency: string;
  expires_at?: string | null;
  idempotency_key: string;
  max_redemptions?: number | null;
  project_id?: string | null;
  raw_voucher_code: string;
  tenant_id: string;
  wallet_id: string;
};

export type AdminVoucherIssueResponse = {
  amount?: string | null;
  code_hash_present?: boolean;
  code_lookup_prefix_present?: boolean;
  credit_grant_id?: string | null;
  currency?: string | null;
  id?: string | null;
  ledger_entry_id?: string | null;
  operation?: string;
  raw_voucher_code_echoed?: boolean;
  runtime_implemented?: boolean;
  secret_safe?: boolean;
  status: string;
  voucher_id?: string | null;
  wallet_id?: string | null;
};

export type AdminVoucherIssueBatchItemRequest = {
  idempotency_key: string;
  raw_voucher_code: string;
};

export type AdminVoucherIssueBatchRequest = {
  batch_idempotency_key: string;
  defaults: Omit<AdminVoucherIssueRequest, "idempotency_key" | "raw_voucher_code">;
  items: AdminVoucherIssueBatchItemRequest[];
};

export type AdminVoucherIssueBatchItemResponse = {
  amount?: string | null;
  code_redacted?: string | null;
  currency?: string | null;
  index: number;
  message?: string | null;
  raw_idempotency_key_echoed?: boolean;
  raw_voucher_code_echoed?: boolean;
  refusal_code?: string | null;
  secret_safe?: boolean;
  status: string;
  voucher_id?: string | null;
  wallet_id?: string | null;
};

export type AdminVoucherIssueBatchResponse = {
  batch_idempotency_key_hash?: string | null;
  batch_hash?: string | null;
  batch_idempotency_key_hash_present?: boolean;
  database_writes?: boolean;
  issued: number;
  items: AdminVoucherIssueBatchItemResponse[];
  operation?: string;
  raw_idempotency_key_echoed?: boolean;
  raw_voucher_code_echoed?: boolean;
  refused: number;
  replayed: number;
  runtime_implemented?: boolean;
  schema?: string;
  secret_safe?: boolean;
  status: string;
  total: number;
};

export type AdminVoucherBatchQueryResponse = {
  audit_ids?: string[];
  batch_hash?: string | null;
  batch_idempotency_key_hash: string;
  batch_idempotency_key_hash_present?: boolean;
  code_hash_present?: boolean;
  code_lookup_prefix_present?: boolean;
  expired?: number;
  issued: number;
  items: AdminVoucherIssuanceSummary[];
  operation?: string;
  raw_idempotency_key_echoed?: boolean;
  raw_voucher_code_echoed?: boolean;
  redeemed: number;
  revocable_count: number;
  revoke_audit_ids?: string[];
  revoked: number;
  runtime_implemented?: boolean;
  schema?: string;
  secret_safe?: boolean;
  status: string;
  total: number;
};

export type AdminVoucherIssuanceListFilters = {
  batch_idempotency_key_hash?: string;
  campaign_id?: string;
  limit?: number;
  project_id?: string;
  status?: string;
  wallet_id?: string;
};

export type AdminVoucherIssuanceSummary = {
  amount: string;
  audit_id?: string | null;
  batch_idempotency_key_hash?: string | null;
  campaign_id?: string | null;
  code_hash_present?: boolean;
  code_lookup_prefix_present?: boolean;
  code_redacted: string;
  currency: string;
  effective_status?: string | null;
  expires_at?: string | null;
  max_redemptions: number;
  project_id?: string | null;
  raw_idempotency_key_echoed?: boolean;
  raw_voucher_code_echoed?: boolean;
  redemption_count: number;
  revoke_audit_id?: string | null;
  schema?: string;
  secret_safe?: boolean;
  status: string;
  tenant_id: string;
  voucher_id: string;
  wallet_id?: string | null;
};

export type AdminVoucherIssuanceListResponse = {
  count: number;
  items: AdminVoucherIssuanceSummary[];
  limit: number;
  raw_voucher_code_echoed?: boolean;
  runtime_implemented?: boolean;
  schema?: string;
  secret_safe?: boolean;
};

export type AdminVoucherRevokeResponse = {
  audit_id?: string | null;
  operation?: string;
  raw_idempotency_key_echoed?: boolean;
  raw_voucher_code_echoed?: boolean;
  runtime_implemented?: boolean;
  schema?: string;
  secret_safe?: boolean;
  status: string;
  voucher: AdminVoucherIssuanceSummary;
};

export type AdminVoucherBatchRevokeResponse = {
  audit_ids?: string[];
  batch_hash?: string | null;
  batch_idempotency_key_hash: string;
  batch_idempotency_key_hash_present?: boolean;
  code_hash_present?: boolean;
  code_lookup_prefix_present?: boolean;
  expired?: number;
  issued: number;
  operation?: string;
  operation_id: string;
  raw_idempotency_key_echoed?: boolean;
  raw_voucher_code_echoed?: boolean;
  redeemed: number;
  revocable_count: number;
  revocable_count_before: number;
  revoked: number;
  revoked_count: number;
  revoked_voucher_ids?: string[];
  runtime_implemented?: boolean;
  schema?: string;
  secret_safe?: boolean;
  status: string;
  total: number;
  total_matched_before: number;
};

export type UserRequestLogFilters = {
  limit?: number;
  model?: string;
  request_id?: string;
  status?: string;
  trace_id?: string;
};

export type UserRequestLogSummary = {
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
  provider_protocol_summary?: RequestProviderProtocolSummary | null;
  redaction_status: string;
  rate_limit_metadata?: RequestRateLimitMetadata | null;
  request_body_hash?: string | null;
  requested_model?: string | null;
  response_body_hash?: string | null;
  retryable?: boolean | null;
  status: string;
  stream_end_reason?: string | null;
  tenant_id: string;
  thread_id?: string | null;
  trace_id?: string | null;
  ttft_ms?: number | null;
  upstream_model?: string | null;
  virtual_key_id?: string | null;
};

export type UserRequestTraceSummaryFilters = {
  limit?: number;
  window_days?: number;
};

export type UserRequestTraceLastError = {
  code?: string | null;
  http_status?: number | null;
  observed_at: string;
  owner?: string | null;
};

export type UserRequestTraceSummary = {
  currencies: string[];
  error_count: number;
  first_request_at?: string | null;
  last_error?: UserRequestTraceLastError | null;
  last_request_at?: string | null;
  limit: number;
  limit_reached: boolean;
  project_id: string;
  request_count: number;
  requests: UserRequestLogSummary[];
  schema: string;
  secret_safe: boolean;
  total_cost: string;
  total_input_tokens: number;
  total_output_tokens: number;
  trace_id: string;
  window_days: number;
};

export type UserReadinessCheckStatus = "ready" | "attention" | "blocked" | string;

export type UserReadinessCheck = {
  code: string;
  detail: string;
  label: string;
  next_action: string;
  status: UserReadinessCheckStatus;
};

export type UserReadiness = {
  checks: UserReadinessCheck[];
  counts: {
    active_keys: number;
    active_profiles: number;
    available_models: number;
    recent_requests: number;
    routable_models: number;
  };
  next_action: string;
  project_id: string;
  schema: string;
  secret_safe: boolean;
  state: "ready" | "attention" | "blocked" | string;
};

export type UserUsageSummaryFilters = {
  window_days?: number;
};

export type UserUsageTotals = {
  avg_latency_ms?: number | null;
  currency: string;
  failed_count: number;
  input_tokens: number;
  output_tokens: number;
  request_count: number;
  retryable_failed_count: number;
  success_count: number;
  total_cost: string;
  total_tokens: number;
};

export type UserUsageModelSummary = {
  avg_latency_ms?: number | null;
  currency: string;
  failed_count: number;
  model: string;
  request_count: number;
  success_count: number;
  total_cost: string;
  total_tokens: number;
};

export type UserUsageKeySummary = {
  currency: string;
  failed_count: number;
  key_name?: string | null;
  key_prefix?: string | null;
  last_request_at?: string | null;
  request_count: number;
  total_cost: string;
  total_tokens: number;
  virtual_key_id?: string | null;
};

export type UserUsageErrorSummary = {
  error_code: string;
  error_owner?: string | null;
  last_seen_at?: string | null;
  request_count: number;
  retryable_count: number;
};

export type UserUsageSummary = {
  by_key: UserUsageKeySummary[];
  by_model: UserUsageModelSummary[];
  project_id: string;
  schema: string;
  secret_safe: boolean;
  top_errors: UserUsageErrorSummary[];
  totals: UserUsageTotals;
  window_days: number;
};

export type UserBillingHistoryReadback = {
  authorization_returned: false;
  balance: UserBalance;
  credit_grant_expiration_readback?: CreditGrantExpirationReadback | null;
  funding_source_readback?: FundingSourceReadback | null;
  ledger_recent_entries: {
    confirmed_count: number;
    confirmed_net_amount: string;
    currency: string;
    entries: Array<{
      amount: string;
      created_at: string;
      currency: string;
      entry_type: string;
      ledger_entry_id: string;
      raw_metadata_returned: false;
      request_id?: string | null;
      status: string;
      virtual_key_id?: string | null;
      wallet_id?: string | null;
    }>;
    entry_count: number;
    last_ledger_at?: string | null;
    raw_ledger_metadata_returned: false;
    raw_payload_returned: false;
    source: "ledger_entries_project_scope" | string;
    window_days: number;
  };
  omitted_fields: string[];
  project_id: string;
  provider_key_returned: false;
  raw_api_key_returned: false;
  raw_invoice_metadata_returned: false;
  raw_ledger_metadata_returned: false;
  raw_payload_returned: false;
  refs_presence: {
    authorization_returned: false;
    order: {
      count: number;
      last_order_at?: string | null;
      paid_count: number;
      raw_invoice_metadata_returned: false;
      raw_payment_payload_returned: false;
    };
    order_refs_present: boolean;
    provider_key_returned: false;
    raw_payload_returned: false;
    source: "voucher_order_subscription_project_or_wallet_scope" | string;
    subscription: {
      active_count: number;
      count: number;
      last_subscription_at?: string | null;
      raw_invoice_metadata_returned: false;
    };
    subscription_refs_present: boolean;
    voucher: {
      count: number;
      last_redemption_at?: string | null;
      raw_voucher_code_returned: false;
      redemption_count: number;
      voucher_code_hash_returned: false;
    };
    voucher_refs_present: boolean;
  };
  request_usage_cost_rollup: UserUsageTotals;
  safe_next_action: string;
  schema: "user_billing_history_readback.v1" | string;
  secret_safe: true;
  user_id: string;
  wallet_id: string;
  window_days: number;
};

export type UserHomeSummary = {
  balance: UserBalance;
  endpoint: {
    base_url: string;
    chat_completions_url: string;
    config_needed: boolean;
    models_url: string;
    openai_base_url: string;
    source: "runtime_config" | "local_fallback" | string;
  };
  handoff: {
    contract: "GET /user/home-summary" | string;
    fallback: string;
    omitted_fields: string[];
  };
  models: {
    routable_count: number;
    sample: Array<{
      display_name: string;
      id: string;
      model: string;
      primary_protocol?: string | null;
      routable: boolean;
      routable_channel_count: number;
      route_status: "routable" | "config-needed" | string;
    }>;
    total_visible: number;
  };
  project_id: string;
  recent_requests: {
    count: number;
    request_ids: string[];
    requests: UserRequestLogSummary[];
  };
  recent_usage: UserUsageTotals;
  schema: "user_home_summary.v1" | string;
  secret_safe: boolean;
};

export type UserDeveloperQuickstartReadback = {
  available_models: UserHomeSummary["models"];
  billing_balance_summary: UserBalance;
  current_key_status: {
    active_keys: number;
    deleted_keys: number;
    disabled_keys: number;
    expired_keys: number;
    current_status: "active" | "attention" | "missing" | string;
    latest_key?: {
      created_at: string;
      default_profile_id?: string | null;
      id: string;
      key_prefix: string;
      last_used_at?: string | null;
      name: string;
      status: UserVirtualKeyStatus;
    } | null;
    raw_api_key_returned: false;
    secret_hash_returned: false;
    total_keys: number;
  };
  endpoint: UserHomeSummary["endpoint"];
  handoff: {
    authorization_returned: false;
    contract: "GET /user/developer-quickstart-readback" | string;
    fallback: string;
    omitted_fields: string[];
    provider_key_returned: false;
    raw_payload_returned: false;
    source: "user_session_project_scoped_readback" | string;
  };
  model_availability_readback: ModelAvailabilityReadback;
  mock_readiness: Array<{
    endpoint: "mock_chat" | "mock_responses" | "mock_embeddings" | string;
    next_action: string;
    path: "POST /v1/chat/completions" | "POST /v1/responses" | "POST /v1/embeddings" | string;
    recent_success_count: number;
    required: string[];
    route_ready: boolean;
    status: "recent-success" | "ready-to-try" | "config-needed" | string;
  }>;
  project_id: string;
  recent_request_ids: string[];
  safe_next_actions: string[];
  schema: "user_developer_quickstart_readback.v1" | string;
  secret_safe: boolean;
};

export type UserDeveloperDistributionPacketReadback = {
  endpoint_readiness: UserDeveloperQuickstartReadback["mock_readiness"];
  handoff: {
    api_key_secret_returned: false;
    authorization_returned: false;
    contract: "GET /user/developer-distribution-packet-readback" | string;
    fallback: string;
    omitted_fields: string[];
    provider_key_returned: false;
    raw_api_key_returned: false;
    raw_payload_returned: false;
    source: "user_session_project_scoped_distribution_packet_readback" | string;
    token_returned: false;
    voucher_code_returned: false;
  };
  model_availability: UserHomeSummary["models"];
  project_id: string;
  quota_rate_budget_guardrails: {
    active_price_version_count: number;
    active_profile_count: number;
    active_virtual_key_count: number;
    budget_policy_present_count: number;
    guardrails_present: boolean;
    provider_key_limit_guardrail_count: number;
    provider_key_returned: false;
    rate_limit_policy_present_count: number;
    raw_policy_payload_returned: false;
    safe_next_action: string;
    schema: "developer_distribution_guardrails_readback.v1" | string;
    status: "ready" | "attention" | "blocked" | string;
  };
  safe_next_action: string;
  schema: "developer_distribution_packet_readback.v1" | string;
  secret_safe: boolean;
  voucher_key_handoff_refs: {
    api_key_secret_returned: false;
    authorization_returned: false;
    developer_quickstart_route: string;
    operator_packet_artifact_ref: string;
    provider_key_returned: false;
    raw_api_key_returned: false;
    schema: "developer_distribution_handoff_refs.v1" | string;
    user_balance_route: string;
    user_models_route: string;
    user_request_logs_route: string;
    user_virtual_key_route: string;
    user_voucher_redeem_route: string;
    voucher_code_returned: false;
  };
};

export type UserSecurityActivitySummary = {
  api_key_activity: {
    api_key_secret_hash_returned: false;
    api_key_secret_returned: false;
    audit_count: number;
    created_count: number;
    disabled_or_deleted_count: number;
    key_counts: {
      active_keys: number;
      deleted_keys: number;
      disabled_keys: number;
      expired_keys: number;
      total_keys: number;
    };
    last_audit_at?: string | null;
    samples: Array<{
      action: string;
      audit_log_id: string;
      created_at: string;
      virtual_key_id?: string | null;
    }>;
    source: "audit_logs_virtual_keys" | string;
    status: "available" | string;
  };
  balance_and_ledger_activity: {
    confirmed_count: number;
    confirmed_net_amount: string;
    credit_or_adjust_count: number;
    currency: string;
    last_ledger_at?: string | null;
    ledger_entry_count: number;
    raw_ledger_metadata_returned: false;
    raw_payload_returned: false;
    samples: Array<{
      amount: string;
      created_at: string;
      currency: string;
      entry_type: string;
      ledger_entry_id: string;
      request_id?: string | null;
      status: string;
      virtual_key_id?: string | null;
      wallet_id?: string | null;
    }>;
    source: "ledger_entries_project_scope" | string;
    status: "available" | string;
    usage_or_refund_count: number;
  };
  handoff: {
    api_key_secret_hash_returned: false;
    api_key_secret_returned: false;
    authorization_returned: false;
    contract: "GET /user/security-activity-summary" | string;
    fallback: string;
    omitted_fields: string[];
    password_hash_returned: false;
    raw_payload_returned: false;
    session_token_returned: false;
    source: "user_session_project_scoped_readback" | string;
  };
  login_activity: {
    active_session_count: number;
    last_login_at?: string | null;
    last_seen_at?: string | null;
    safe_count_only: true;
    samples: Array<{
      created_at: string;
      expires_at: string;
      last_seen_at?: string | null;
      session_id: string;
      session_token_returned: false;
      status: string;
      token_hash_returned: false;
    }>;
    session_count: number;
    source: "user_sessions" | string;
    status: "available" | string;
  };
  password_and_email_requests: {
    counts_available: false;
    email_verification_request_endpoint: "POST /auth/email-verification/request" | string;
    next_action: string;
    password_hash_returned: false;
    password_reset_request_endpoint: "POST /auth/password-reset/request" | string;
    safe_samples: JsonValue[];
    source: "auth_productization_placeholders" | string;
    status: "productization_placeholder" | string;
  };
  project_id: string;
  safe_next_actions: string[];
  schema: "user_security_activity_summary.v1" | string;
  secret_safe: boolean;
  user_id: string;
  window_days: number;
};

export type UserSubscriptionPlanSummary = Pick<
  SubscriptionPlan,
  | "billing_interval"
  | "currency"
  | "display_name"
  | "entitlement_summary"
  | "expiration_policy"
  | "id"
  | "included_credit_amount"
  | "payment_status"
  | "plan_code"
  | "raw_payment_payload_returned"
  | "scheduler_status"
  | "secret_safe"
  | "status"
  | "trial_days"
  | "unit_price"
>;

export type UserSubscriptionPaymentOverview = {
  current_subscription: {
    current_period_end?: string | null;
    current_period_start?: string | null;
    dunning_status?: string | null;
    grace_status?: string | null;
    included_credit_remaining?: string | null;
    lifecycle_state?: string | null;
    next_action: string;
    next_renewal_at?: string | null;
    plan_code?: string | null;
    plan_id?: string | null;
    renewal_status?: string | null;
    status: "none" | "pending" | "active" | "expired" | "cancelled" | string;
  };
  demo_payment: {
    invoice_status: "placeholder" | "not_created" | string;
    local_only: true;
    merchant_connected: false;
    next_action: string;
    order_status: "not_created" | "pending" | "paid" | string;
    production_payment_evidence: false;
  };
  local_only: true;
  merchant_connected: false;
  pending_scheduler: true;
  plans: UserSubscriptionPlanSummary[];
  project_id?: string | null;
  raw_idempotency_key_echoed: false;
  raw_invoice_metadata_returned: false;
  raw_payment_payload_returned: false;
  scheduler_status: "pending_scheduler" | string;
  scheduler_demo?: {
    dunning?: {
      attempt_count?: number | null;
      max_attempts?: number | null;
      next_attempt_at?: string | null;
      status: string;
      write_enabled?: false;
    };
    grace?: {
      ends_at?: string | null;
      grace_days?: number | null;
      status: string;
      write_enabled?: false;
    };
    lifecycle_state: string;
    local_only: true;
    merchant_connected: false;
    mode: string;
    next_action: string;
    pending_scheduler: true;
    raw_idempotency_key_echoed: false;
    raw_invoice_metadata_returned: false;
    raw_payload_returned?: false;
    raw_payment_payload_returned: false;
    readback_source: string;
    runtime_scheduler_enabled: false;
    scheduled_events: Array<{
      effective_at: string;
      event_status: string;
      event_type: string;
      refusal_code?: string | null;
    }>;
    scheduler_status: "pending_scheduler" | string;
    schema: "user_subscription_scheduler_demo.v1" | string;
    secret_safe: true;
    subscription_id?: string | null;
    subscription_status: string;
    upcoming_renewal?: {
      amount?: string | null;
      billing_interval?: string | null;
      credit_grant_write?: false;
      currency?: string | null;
      due_at?: string | null;
      invoice_status?: string | null;
      ledger_write?: false;
      order_status?: string | null;
      plan_code?: string | null;
      status: string;
    };
  };
  schema: "user_subscription_payment_overview.v1" | string;
  secret_safe: true;
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

export async function apiJsonEnvelope<T>(path: string, options: JsonRequestOptions = {}): Promise<T> {
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

  return readJsonEnvelopeResponse<T>(response, url);
}

export async function apiText(path: string, options: Omit<JsonRequestOptions, "body"> = {}): Promise<string> {
  const {
    baseUrl = serviceBaseUrls.controlPlane,
    headers,
    timeoutMs = DEFAULT_REQUEST_TIMEOUT_MS,
    ...requestInit
  } = options;
  const url = joinUrl(baseUrl, path);
  const requestHeaders = new Headers(headers);
  applyAdminSessionHeader(path, requestHeaders);

  const response = await fetchWithTimeout(url, {
    ...requestInit,
    credentials: requestInit.credentials ?? "include",
    headers: requestHeaders,
    timeoutMs,
  });

  return readTextResponse(response, url);
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

export function registerUser(
  request: UserRegisterRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<UserAuthResponse> {
  return apiJson<UserAuthResponse>("/auth/register", {
    ...options,
    body: request,
    method: "POST",
  });
}

export function loginUser(
  request: UserAuthRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<UserAuthResponse> {
  return apiJson<UserAuthResponse>("/auth/login", {
    ...options,
    body: request,
    method: "POST",
  });
}

export function getUserMe(options: Omit<JsonRequestOptions, "body" | "method"> = {}): Promise<UserMeResponse> {
  return apiJson<UserMeResponse>("/auth/me", {
    ...options,
    method: "GET",
  });
}

export function requestUserPasswordReset(
  request: UserPasswordResetRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<UserProductizationStatusResponse> {
  return apiJson<UserProductizationStatusResponse>("/auth/password-reset/request", {
    ...options,
    body: request,
    method: "POST",
  });
}

export function requestUserEmailVerification(
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<UserProductizationStatusResponse> {
  return apiJson<UserProductizationStatusResponse>("/auth/email-verification/request", {
    ...options,
    body: {},
    method: "POST",
  });
}

export async function logoutUser(options: Omit<JsonRequestOptions, "body" | "method"> = {}): Promise<void> {
  await apiJson<{ logged_out: boolean }>("/auth/logout", {
    ...options,
    method: "POST",
  });
}

export function listUserVirtualKeys(
  filters: { status?: UserVirtualKeyStatus } = {},
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<UserVirtualKey[]> {
  return apiJson<UserVirtualKey[]>(`/user/virtual-keys${queryString(filters)}`, {
    ...options,
    method: "GET",
  });
}

export function createUserVirtualKey(
  request: CreateUserVirtualKeyRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<UserVirtualKey> {
  return apiJson<UserVirtualKey>("/user/virtual-keys", {
    ...options,
    body: request,
    method: "POST",
  });
}

export function disableUserVirtualKey(
  id: string,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<UserVirtualKey> {
  return apiJson<UserVirtualKey>(`/user/virtual-keys/${encodeURIComponent(id)}/disable`, {
    ...options,
    method: "POST",
  });
}

export function deleteUserVirtualKey(
  id: string,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<UserVirtualKey> {
  return apiJson<UserVirtualKey>(`/user/virtual-keys/${encodeURIComponent(id)}`, {
    ...options,
    method: "DELETE",
  });
}

export function getUserBalance(
  filters: { currency?: string; ledger_window_days?: number } = {},
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<UserBalance> {
  return apiJson<UserBalance>(`/user/balance${queryString(filters)}`, {
    ...options,
    method: "GET",
  });
}

export function getUserBillingHistoryReadback(
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<UserBillingHistoryReadback> {
  return apiJson<UserBillingHistoryReadback>("/user/billing-history-readback", {
    ...options,
    method: "GET",
  });
}

export function listUserModels(options: Omit<JsonRequestOptions, "body" | "method"> = {}): Promise<UserModel[]> {
  return apiJson<UserModel[]>("/user/models", {
    ...options,
    method: "GET",
  });
}

export function listUserModelsEnvelope(
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<UserModelsEnvelope> {
  return apiJsonEnvelope<UserModelsEnvelope>("/user/models", {
    ...options,
    method: "GET",
  });
}

export function getUserReadiness(options: Omit<JsonRequestOptions, "body" | "method"> = {}): Promise<UserReadiness> {
  return apiJson<UserReadiness>("/user/readiness", {
    ...options,
    method: "GET",
  });
}

export function getUserHomeSummary(options: Omit<JsonRequestOptions, "body" | "method"> = {}): Promise<UserHomeSummary> {
  return apiJson<UserHomeSummary>("/user/home-summary", {
    ...options,
    method: "GET",
  });
}

export function getUserTeamSummary(options: Omit<JsonRequestOptions, "body" | "method"> = {}): Promise<UserTeamSummary> {
  return apiJson<UserTeamSummary>("/user/team-summary", {
    ...options,
    method: "GET",
  });
}

export function getUserDeveloperQuickstartReadback(
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<UserDeveloperQuickstartReadback> {
  return apiJson<UserDeveloperQuickstartReadback>("/user/developer-quickstart-readback", {
    ...options,
    method: "GET",
  });
}

export function getUserDeveloperDistributionPacketReadback(
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<UserDeveloperDistributionPacketReadback> {
  return apiJson<UserDeveloperDistributionPacketReadback>("/user/developer-distribution-packet-readback", {
    ...options,
    method: "GET",
  });
}

export function getUserSecurityActivitySummary(
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<UserSecurityActivitySummary> {
  return apiJson<UserSecurityActivitySummary>("/user/security-activity-summary", {
    ...options,
    method: "GET",
  });
}

export function getUserUsageSummary(
  filters: UserUsageSummaryFilters = {},
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<UserUsageSummary> {
  return apiJson<UserUsageSummary>(`/user/usage-summary${queryString(filters)}`, {
    ...options,
    method: "GET",
  });
}

export async function getUserSubscriptionPaymentOverview(
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<UserSubscriptionPaymentOverview> {
  try {
    return await apiJson<UserSubscriptionPaymentOverview>("/user/subscription-payment", {
      ...options,
      method: "GET",
    });
  } catch (error) {
    if (error instanceof ApiClientError && (error.status === 404 || error.status === 501)) {
      return userSubscriptionPaymentOverviewFallback();
    }

    throw error;
  }
}

export function getUserRequestTraceSummary(
  traceId: string,
  filters: UserRequestTraceSummaryFilters = {},
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<UserRequestTraceSummary> {
  return apiJson<UserRequestTraceSummary>(`/user/traces/${encodeURIComponent(traceId)}${queryString(filters)}`, {
    ...options,
    method: "GET",
  });
}

export function redeemUserVoucher(
  request: UserVoucherRedeemRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<UserVoucherRedeemResponse> {
  return apiJson<UserVoucherRedeemResponse>("/user/vouchers/redeem", {
    ...options,
    body: request,
    method: "POST",
  });
}

export function issueAdminVoucher(
  request: AdminVoucherIssueRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<AdminVoucherIssueResponse> {
  return apiJson<AdminVoucherIssueResponse>("/admin/voucher-issuances", {
    ...options,
    body: request,
    method: "POST",
  });
}

export function issueAdminVoucherBatch(
  request: AdminVoucherIssueBatchRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<AdminVoucherIssueBatchResponse> {
  return apiJson<AdminVoucherIssueBatchResponse>("/admin/voucher-issuance-batches", {
    ...options,
    body: request,
    method: "POST",
  });
}

export function listAdminVoucherIssuances(
  filters: AdminVoucherIssuanceListFilters = {},
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<AdminVoucherIssuanceListResponse> {
  return apiJson<AdminVoucherIssuanceListResponse>(`/admin/voucher-issuances${queryString(filters)}`, {
    ...options,
    method: "GET",
  });
}

export function getAdminVoucherBatch(
  batchHash: string,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<AdminVoucherBatchQueryResponse> {
  return apiJson<AdminVoucherBatchQueryResponse>(`/admin/voucher-issuance-batches/${encodeURIComponent(batchHash)}`, {
    ...options,
    method: "GET",
  });
}

export function revokeAdminVoucherIssuance(
  voucherId: string,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<AdminVoucherRevokeResponse> {
  return apiJson<AdminVoucherRevokeResponse>(`/admin/voucher-issuances/${encodeURIComponent(voucherId)}/revoke`, {
    ...options,
    method: "POST",
  });
}

export function revokeAdminVoucherBatch(
  batchHash: string,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<AdminVoucherBatchRevokeResponse> {
  return apiJson<AdminVoucherBatchRevokeResponse>(
    `/admin/voucher-issuance-batches/${encodeURIComponent(batchHash)}/revoke`,
    {
      ...options,
      method: "POST",
    },
  );
}

export function listUserRequestLogs(
  filters: UserRequestLogFilters = {},
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<UserRequestLogSummary[]> {
  return apiJson<UserRequestLogSummary[]>(`/user/request-logs${queryString(filters)}`, {
    ...options,
    method: "GET",
  });
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

export async function listRequestLogsPage(
  filters: RequestLogListFilters = {},
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<RequestLogSummary[] | AdminRequestLogsPage> {
  return apiJson<RequestLogSummary[] | AdminRequestLogsPage>(`/admin/request-logs${queryString(filters)}`, {
    ...options,
    method: "GET",
  });
}

export function exportRequestLogsCsv(
  filters: RequestLogListFilters = {},
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<string> {
  return apiText(`/admin/request-logs/export.csv${queryString(filters)}`, {
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

export function getAdminDistributionReadiness(
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<AdminDistributionReadiness> {
  return apiJson<AdminDistributionReadiness>("/admin/distribution/readiness", {
    ...options,
    method: "GET",
  });
}

export function getAdminSetupReadback(
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<AdminSetupReadback> {
  return apiJson<AdminSetupReadback>("/admin/setup/readback", {
    ...options,
    method: "GET",
  });
}

export function getAdminProductionReadModelStatus(
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<AdminProductionReadModelStatus> {
  return apiJson<AdminProductionReadModelStatus>("/admin/production/read-model/status", {
    ...options,
    method: "GET",
  });
}

export function getEnterpriseIdentityConnections(
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<EnterpriseIdentityConnectionsReadback> {
  return apiJson<EnterpriseIdentityConnectionsReadback>("/admin/enterprise/identity-connections", {
    ...options,
    method: "GET",
  });
}

export function getEnterpriseIdentityValidationPlan(
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<EnterpriseIdentityValidationPlan> {
  return apiJson<EnterpriseIdentityValidationPlan>(
    "/admin/enterprise/identity-connections/validation-plan",
    {
      ...options,
      method: "GET",
    },
  );
}

export function postEnterpriseOidcValidateCodePlan(
  body: EnterpriseOidcValidateCodePlanRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<EnterpriseOidcValidateCodePlan> {
  return apiJson<EnterpriseOidcValidateCodePlan>(
    "/admin/enterprise/identity-connections/oidc/validate-code-plan",
    {
      ...options,
      method: "POST",
      body,
    },
  );
}

export function postEnterpriseOidcJwksValidatorExecutor(
  body: EnterpriseOidcExecuteValidatedLoginRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<EnterpriseOidcJwksValidatorExecutor> {
  return apiJson<EnterpriseOidcJwksValidatorExecutor>(
    "/admin/enterprise/identity-connections/oidc/jwks-validator-executor",
    {
      ...options,
      method: "POST",
      body,
    },
  );
}

export function postEnterpriseOidcExecuteValidatedLogin(
  body: EnterpriseOidcExecuteValidatedLoginRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<EnterpriseOidcExecuteValidatedLogin> {
  return apiJson<EnterpriseOidcExecuteValidatedLogin>(
    "/admin/enterprise/identity-connections/oidc/execute-validated-login",
    {
      ...options,
      method: "POST",
      body,
    },
  );
}

export function postEnterpriseSamlValidateAcsPlan(
  body: EnterpriseSamlValidateAcsPlanRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<EnterpriseSamlValidateAcsPlan> {
  return apiJson<EnterpriseSamlValidateAcsPlan>(
    "/admin/enterprise/identity-connections/saml/validate-acs-plan",
    {
      ...options,
      method: "POST",
      body,
    },
  );
}

export function postEnterpriseSamlExecuteValidatedAcs(
  body: EnterpriseSamlExecuteValidatedAcsRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<EnterpriseSamlExecuteValidatedAcs> {
  return apiJson<EnterpriseSamlExecuteValidatedAcs>(
    "/admin/enterprise/identity-connections/saml/execute-validated-acs",
    {
      ...options,
      method: "POST",
      body,
    },
  );
}

export function postEnterpriseIdentityBindingPlan(
  body: EnterpriseIdentityBindingPlanRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<EnterpriseIdentityBindingPlan> {
  return apiJson<EnterpriseIdentityBindingPlan>("/admin/enterprise/identity-bindings/plan", {
    ...options,
    method: "POST",
    body,
  });
}

export function postEnterpriseIdentitySessionIssuePlan(
  body: EnterpriseIdentitySessionIssuePlanRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<EnterpriseIdentitySessionIssuePlan> {
  return apiJson<EnterpriseIdentitySessionIssuePlan>(
    "/admin/enterprise/identity-sessions/issue-plan",
    {
      ...options,
      method: "POST",
      body,
    },
  );
}

export function getEnterpriseAccounts(
  filters: EnterpriseAccountsFilters = {},
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<EnterpriseAccountsReadback> {
  return apiJson<EnterpriseAccountsReadback>(`/admin/enterprise/accounts${queryString(filters)}`, {
    ...options,
    method: "GET",
  });
}

export function createEnterpriseAccount(
  body: CreateEnterpriseAccountRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<EnterpriseAccountLifecycleCreate> {
  return apiJson<EnterpriseAccountLifecycleCreate>("/admin/enterprise/accounts", {
    ...options,
    method: "POST",
    body,
  });
}

export function patchEnterpriseAccount(
  body: PatchEnterpriseAccountRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<EnterpriseAccountMetadataUpdate> {
  return apiJson<EnterpriseAccountMetadataUpdate>("/admin/enterprise/accounts", {
    ...options,
    method: "PATCH",
    body,
  });
}

export function planEnterpriseAccountProvisioning(
  body: EnterpriseAccountProvisioningRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<EnterpriseAccountProvisioningPlan> {
  return apiJson<EnterpriseAccountProvisioningPlan>(
    "/admin/enterprise/accounts/provisioning-plan",
    {
      ...options,
      method: "POST",
      body,
    },
  );
}

export function applyEnterpriseAccountProvisioning(
  body: EnterpriseAccountProvisioningRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<EnterpriseAccountProvisioningPlan> {
  return apiJson<EnterpriseAccountProvisioningPlan>(
    "/admin/enterprise/accounts/provisioning-apply",
    {
      ...options,
      method: "POST",
      body,
    },
  );
}

export function planEnterpriseInviteDelivery(
  body: EnterpriseInviteDeliveryRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<EnterpriseInviteDeliveryPlan> {
  return apiJson<EnterpriseInviteDeliveryPlan>(
    "/admin/enterprise/accounts/invite-delivery-plan",
    {
      ...options,
      method: "POST",
      body,
    },
  );
}

export function applyEnterpriseInviteDelivery(
  body: EnterpriseInviteDeliveryRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<EnterpriseInviteDeliveryPlan> {
  return apiJson<EnterpriseInviteDeliveryPlan>(
    "/admin/enterprise/accounts/invite-delivery-apply",
    {
      ...options,
      method: "POST",
      body,
    },
  );
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

export function getRequestPayloadPreview(
  id: string,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<RequestPayloadPreview> {
  return apiJson<RequestPayloadPreview>(`/admin/request-logs/${encodeURIComponent(id)}/payload`, {
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

export function rotateProviderKey(
  id: string,
  request: ProviderKeyRotateRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<ProviderKeyRotateResponse> {
  return apiJson<ProviderKeyRotateResponse>(`/admin/provider-keys/${encodeURIComponent(id)}/rotate`, {
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

export function bulkVirtualKeyLeakAction(
  request: BulkVirtualKeyLeakActionRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<BulkVirtualKeyLeakActionResponse> {
  return apiJson<BulkVirtualKeyLeakActionResult[]>("/admin/virtual-keys/bulk-leak-action", {
    ...options,
    body: request,
    method: "POST",
  });
}

export function handoffVirtualKeyExternalScannerFindings(
  request: VirtualKeyExternalScannerHandoffRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<VirtualKeyExternalScannerHandoffResponse> {
  return apiJson<VirtualKeyExternalScannerHandoffResponse>("/admin/virtual-keys/external-scanner/handoff", {
    ...options,
    body: request,
    method: "POST",
  });
}

export function getImporterApplyPlanReadback(
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<ImporterApplyPlanReadback> {
  return apiJson<ImporterApplyPlanReadback>("/admin/importer/apply-runs/readback", {
    ...options,
    method: "GET",
  });
}

export function recordImporterApplyPlanReadback(
  request: ImporterApplyPlanReadbackRecordRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<ImporterApplyPlanReadback> {
  return apiJson<ImporterApplyPlanReadback>("/admin/importer/apply-runs/readback", {
    ...options,
    body: request,
    method: "POST",
  });
}

export function listVirtualKeyLeakCandidates(
  filters: VirtualKeyListFilters,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<VirtualKeyLeakCandidatesResponse> {
  return apiJson<VirtualKeyLeakCandidatesResponse>(`/admin/virtual-keys/leak-candidates${queryString(filters)}`, {
    ...options,
    method: "GET",
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

export function restoreVirtualKey(
  id: string,
  request: RestoreVirtualKeyRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<RestoreVirtualKeyResponse> {
  return apiJson<RestoreVirtualKeyResponse>(`/admin/virtual-keys/${encodeURIComponent(id)}/restore`, {
    ...options,
    body: request,
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

export function getNetworkSecuritySettings(
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<NetworkSecuritySettings> {
  return apiJson<NetworkSecuritySettings>("/admin/settings/network-security", {
    ...options,
    method: "GET",
  });
}

export function patchNetworkSecuritySettings(
  request: PatchNetworkSecuritySettingsRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<NetworkSecuritySettings> {
  return apiJson<NetworkSecuritySettings>("/admin/settings/network-security", {
    ...options,
    body: request,
    method: "PATCH",
  }).catch((error: unknown) => {
    if (error instanceof ApiClientError && error.code === "config_needed") {
      const data = error.envelope?.data;
      if (isNetworkSecuritySettings(data)) {
        return data;
      }
    }

    throw error;
  });
}

function isNetworkSecuritySettings(value: unknown): value is NetworkSecuritySettings {
  return (
    isRecord(value) &&
    value.schema === "admin_network_security_settings.v1" &&
    value.secret_safe === true &&
    Array.isArray(value.effective_trusted_proxy_allowlist) &&
    typeof value.next_action === "string"
  );
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

export function listSubscriptionPlans(
  filters: SubscriptionPlanListFilters = {},
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<SubscriptionPlan[]> {
  return apiJson<SubscriptionPlan[]>(`/admin/subscription-plans${queryString(filters)}`, {
    ...options,
    method: "GET",
  });
}

export function createSubscriptionPlan(
  request: CreateSubscriptionPlanRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<SubscriptionPlan> {
  return apiJson<SubscriptionPlan>("/admin/subscription-plans", {
    ...options,
    body: request,
    method: "POST",
  });
}

export function patchSubscriptionPlan(
  id: string,
  request: PatchSubscriptionPlanRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<SubscriptionPlan> {
  return apiJson<SubscriptionPlan>(`/admin/subscription-plans/${encodeURIComponent(id)}`, {
    ...options,
    body: request,
    method: "PATCH",
  });
}

export function planSubscriptionScheduler(
  request: SubscriptionSchedulerPlanRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<SubscriptionSchedulerPlan> {
  return apiJson<SubscriptionSchedulerPlan>("/admin/subscriptions/scheduler-plan", {
    ...options,
    body: request,
    method: "POST",
  });
}

export function executeSubscriptionSchedulerEventPlan(
  id: string,
  request: SubscriptionSchedulerEventExecuteRequest = {},
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<SubscriptionSchedulerEventExecutePlan> {
  return apiJson<SubscriptionSchedulerEventExecutePlan>(
    `/admin/subscriptions/scheduler-events/${encodeURIComponent(id)}/execute-plan`,
    {
      ...options,
      body: request,
      method: "POST",
    },
  );
}

export function getSubscriptionSchedulerWorkerHandoff(
  filters: SubscriptionSchedulerWorkerHandoffFilters = {},
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<SubscriptionSchedulerWorkerHandoff> {
  return apiJson<SubscriptionSchedulerWorkerHandoff>(
    `/admin/subscriptions/scheduler-worker${queryString(filters)}`,
    options,
  );
}

export function getAdminWorkersJobsDashboard(
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<AdminWorkersJobsDashboard> {
  return apiJson<AdminWorkersJobsDashboard>("/admin/workers/jobs-dashboard", {
    ...options,
    method: "GET",
  });
}

export function runDueSubscriptionSchedulerEvents(
  request: SubscriptionSchedulerRunDueRequest = {},
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<SubscriptionSchedulerRunDueResult> {
  return apiJson<SubscriptionSchedulerRunDueResult>(
    "/admin/subscriptions/run-due-scheduler-events",
    {
      ...options,
      body: request,
      method: "POST",
    },
  );
}

export function leaseSubscriptionSchedulerEvent(
  id: string,
  request: SubscriptionSchedulerEventLeaseRequest = {},
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<SubscriptionSchedulerEventLease> {
  return apiJson<SubscriptionSchedulerEventLease>(
    `/admin/subscriptions/scheduler-events/${encodeURIComponent(id)}/lease`,
    {
      ...options,
      body: request,
      method: "POST",
    },
  );
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

export function listAdminManagedUsers(
  filters: AdminManagedUserListFilters = {},
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<AdminManagedUser[]> {
  return apiJson<AdminManagedUser[]>(`/admin/users${queryString(filters)}`, {
    ...options,
    method: "GET",
  });
}

export function getAdminManagedUserDetail(
  id: string,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<AdminManagedUserDetail> {
  return apiJson<AdminManagedUserDetail>(`/admin/users/${encodeURIComponent(id)}/detail`, {
    ...options,
    method: "GET",
  });
}

export function getAdminProjectMembersSummary(
  projectId: string,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<AdminProjectMembersSummary> {
  return apiJson<AdminProjectMembersSummary>(`/admin/projects/${encodeURIComponent(projectId)}/members-summary`, {
    ...options,
    method: "GET",
  });
}

export function patchAdminManagedUserStatus(
  id: string,
  request: PatchAdminManagedUserStatusRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<AdminManagedUserStatusActionResult> {
  return apiJson<AdminManagedUserStatusActionResult>(`/admin/users/${encodeURIComponent(id)}/status`, {
    ...options,
    body: request,
    method: "PATCH",
  });
}

export function bulkAdminManagedUserStatus(
  request: BulkAdminManagedUserStatusRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<AdminManagedUserBulkStatusResponse> {
  return apiJson<AdminManagedUserBulkStatusResponse>("/admin/users/bulk-status", {
    ...options,
    body: request,
    method: "POST",
  });
}

export function planAdminManagedUserBulkOperation(
  request: AdminManagedUserBulkOperationPlanRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<AdminManagedUserBulkOperationPlan> {
  return apiJson<AdminManagedUserBulkOperationPlan>("/admin/users/bulk-operation-plan", {
    ...options,
    body: request,
    method: "POST",
  });
}

export function listAdminWallets(
  filters: AdminWalletListFilters = {},
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<AdminWalletCreditSurface[]> {
  return apiJson<AdminWalletCreditSurface[]>(`/admin/wallets${queryString(filters)}`, {
    ...options,
    method: "GET",
  });
}

export function getAdminWallet(
  walletId: string,
  filters: AdminWalletDetailFilters = {},
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<AdminWalletCreditSurface> {
  return apiJson<AdminWalletCreditSurface>(`/admin/wallets/${encodeURIComponent(walletId)}${queryString(filters)}`, {
    ...options,
    method: "GET",
  });
}

export function dryRunLedgerAdjustment(
  request: LedgerAdjustmentDryRunRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<LedgerAdjustmentDryRunResponse> {
  return apiJson<LedgerAdjustmentDryRunResponse>("/admin/ledger/adjustments/dry-run", {
    ...options,
    body: request,
    method: "POST",
  });
}

export async function requestLedgerAdjustmentExecuteContract(
  request: LedgerAdjustmentDryRunRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<LedgerAdjustmentExecuteResult> {
  const executeContractRequest = { ...request, mode: "execute_contract" } satisfies LedgerAdjustmentDryRunRequest;

  try {
    const response = await apiJson<LedgerAdjustmentExecuteResponse>("/admin/ledger/adjustments/dry-run", {
      ...options,
      body: executeContractRequest,
      method: "POST",
    });

    return ledgerAdjustmentExecuteResultFromResponse(response);
  } catch (error) {
    if (error instanceof ApiClientError && error.status === 501 && error.code === "future_writer_required") {
      const response = ledgerAdjustmentExecuteResponseFromEnvelope(error.envelope);

      if (response?.mode === "execute_contract") {
        return {
          kind: "writer_required",
          message: error.message,
          response,
          status: error.status,
        };
      }
    }

    throw error;
  }
}

export async function executeLedgerAdjustment(
  request: LedgerAdjustmentDryRunRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<LedgerAdjustmentExecuteResult> {
  const executeRequest = { ...request, mode: "execute" } satisfies LedgerAdjustmentDryRunRequest;
  const response = await apiJson<LedgerAdjustmentExecuteResponse>("/admin/ledger/adjustments/dry-run", {
    ...options,
    body: executeRequest,
    method: "POST",
  });

  return ledgerAdjustmentExecuteResultFromResponse(response);
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

export function createLocalPaymentDemoOrder(
  request: LocalPaymentDemoCreateOrderRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<LocalPaymentDemoResponse> {
  return apiJson<LocalPaymentDemoResponse>("/admin/billing/payment-demo/orders", {
    ...options,
    body: request,
    method: "POST",
  });
}

export function markLocalPaymentDemoOrderPaid(
  orderId: string,
  request: LocalPaymentDemoMarkPaidRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<LocalPaymentDemoResponse> {
  return apiJson<LocalPaymentDemoResponse>(
    `/admin/billing/payment-demo/orders/${encodeURIComponent(orderId)}/mark-paid`,
    {
      ...options,
      body: request,
      method: "POST",
    },
  );
}

export function getPaymentProviderConfigStatus(
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<PaymentProviderAdapterConfigStatus> {
  return apiJson<PaymentProviderAdapterConfigStatus>("/admin/billing/payment-provider/config-status", {
    ...options,
    method: "GET",
  });
}

export function patchPaymentProviderMerchantCredential(
  request: PaymentProviderMerchantCredentialPatchRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<PaymentProviderMerchantCredentialPatchResponse> {
  return apiJson<PaymentProviderMerchantCredentialPatchResponse>(
    "/admin/billing/payment-provider/merchant-credential",
    {
      ...options,
      body: request,
      method: "PATCH",
    },
  );
}

export function simulatePaymentProviderEvent(
  request: PaymentProviderSimulatorEventRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<PaymentProviderSimulatorEventResponse> {
  return apiJson<PaymentProviderSimulatorEventResponse>("/admin/billing/payment-provider/simulator/events", {
    ...options,
    body: request,
    method: "POST",
  });
}

export function executePaymentProviderLocalAction(
  request: PaymentProviderLocalExecutorRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> = {},
): Promise<PaymentProviderLocalExecutorReadback> {
  return apiJson<PaymentProviderLocalExecutorReadback>("/admin/billing/payment-provider/executor", {
    ...options,
    body: request,
    method: "POST",
  });
}

export function receivePaymentProviderWebhook(
  provider: string,
  request: PaymentProviderWebhookEventRequest | PaymentProviderWebhookNativeEventRequest,
  options: Omit<JsonRequestOptions, "body" | "method"> & { signature?: string } = {},
): Promise<PaymentProviderWebhookEventResponse> {
  const { signature, headers, ...requestOptions } = options;
  const requestHeaders = new Headers(headers);
  if (signature) {
    requestHeaders.set("x-fubox-payment-signature", signature);
  }
  return apiJson<PaymentProviderWebhookEventResponse>(
    `/billing/payment-provider/webhooks/${encodeURIComponent(provider)}`,
    {
      ...requestOptions,
      body: request,
      headers: requestHeaders,
      method: "POST",
    },
  );
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

async function readJsonEnvelopeResponse<T>(response: Response, url: string): Promise<T> {
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

  return payload as T;
}

async function readTextResponse(response: Response, url: string): Promise<string> {
  const text = await response.text();

  if (!response.ok) {
    let envelope: ErrorEnvelope | undefined;
    try {
      envelope = text ? toErrorEnvelope(JSON.parse(text)) : undefined;
    } catch {
      envelope = undefined;
    }
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

  return text;
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

function ledgerAdjustmentExecuteResultFromResponse(
  response: LedgerAdjustmentExecuteResponse,
): LedgerAdjustmentExecuteResult {
  if (response.mode === "execute") {
    return {
      kind: "future_execute",
      response,
    };
  }

  return {
    kind: "contract_ready",
    response,
  };
}

function ledgerAdjustmentExecuteResponseFromEnvelope(
  envelope: ErrorEnvelope | undefined,
): LedgerAdjustmentExecuteResponse | undefined {
  return ledgerAdjustmentExecuteResponseFromUnknown(envelope?.data);
}

function ledgerAdjustmentExecuteResponseFromUnknown(value: unknown): LedgerAdjustmentExecuteResponse | undefined {
  if (!isRecord(value) || typeof value.mode !== "string") {
    return undefined;
  }

  if (value.mode === "execute_contract" && isRecord(value.execute_contract) && isRecord(value.validated_plan)) {
    return value as LedgerAdjustmentExecuteContractResponse;
  }

  if (value.mode === "execute") {
    return value as LedgerAdjustmentFutureExecuteResponse;
  }

  return undefined;
}

function userSubscriptionPaymentOverviewFallback(): UserSubscriptionPaymentOverview {
  return {
    current_subscription: {
      dunning_status: "not_in_dunning",
      grace_status: "not_in_grace",
      lifecycle_state: "no_subscription",
      next_action: "套餐目录接口已预留；订阅创建、续费和额度发放等待用户侧后端切片接入。",
      next_renewal_at: null,
      renewal_status: "not_scheduled",
      status: "none",
    },
    demo_payment: {
      invoice_status: "placeholder",
      local_only: true,
      merchant_connected: false,
      next_action: "本地支付 demo 只展示 pending 状态；不会连接真实商户、创建真实 invoice 或运行 scheduler。",
      order_status: "not_created",
      production_payment_evidence: false,
    },
    local_only: true,
    merchant_connected: false,
    pending_scheduler: true,
    plans: [],
    raw_idempotency_key_echoed: false,
    raw_invoice_metadata_returned: false,
    raw_payment_payload_returned: false,
    scheduler_status: "pending_scheduler",
    scheduler_demo: {
      dunning: {
        attempt_count: 0,
        max_attempts: 3,
        next_attempt_at: null,
        status: "not_in_dunning",
        write_enabled: false,
      },
      grace: {
        ends_at: null,
        grace_days: 3,
        status: "not_in_grace",
        write_enabled: false,
      },
      lifecycle_state: "no_subscription",
      local_only: true,
      merchant_connected: false,
      mode: "local_readback_demo",
      next_action: "创建或导入本地订阅后，此区域会展示 upcoming renewal、grace 和 dunning readback。",
      pending_scheduler: true,
      raw_idempotency_key_echoed: false,
      raw_invoice_metadata_returned: false,
      raw_payload_returned: false,
      raw_payment_payload_returned: false,
      readback_source: "fallback",
      runtime_scheduler_enabled: false,
      scheduled_events: [],
      scheduler_status: "pending_scheduler",
      schema: "user_subscription_scheduler_demo.v1",
      secret_safe: true,
      subscription_id: null,
      subscription_status: "none",
      upcoming_renewal: {
        amount: null,
        billing_interval: null,
        credit_grant_write: false,
        currency: null,
        due_at: null,
        invoice_status: "placeholder",
        ledger_write: false,
        order_status: "not_created",
        plan_code: null,
        status: "not_scheduled",
      },
    },
    schema: "user_subscription_payment_overview.v1",
    secret_safe: true,
  };
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
