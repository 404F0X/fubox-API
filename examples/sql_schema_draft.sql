-- Draft copy synchronized with db/migrations/0001_init.sql.
-- Keep this file aligned when the initial schema changes.

create extension if not exists pgcrypto;

create table if not exists tenants (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null,
  status text not null default 'active',
  default_timezone text not null default 'UTC',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  unique (slug),
  check (length(btrim(name)) > 0),
  check (length(btrim(slug)) > 0),
  check (status in ('active', 'suspended', 'deleted')),
  check (jsonb_typeof(metadata) = 'object')
);

create table if not exists teams (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  name text not null,
  status text not null default 'active',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  unique (tenant_id, id),
  unique (tenant_id, name),
  check (length(btrim(name)) > 0),
  check (status in ('active', 'disabled', 'deleted')),
  check (jsonb_typeof(metadata) = 'object')
);

create table if not exists users (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  email text not null,
  display_name text not null,
  password_hash text null,
  status text not null default 'active',
  last_login_at timestamptz null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  unique (tenant_id, id),
  check (position('@' in email) > 1),
  check (length(btrim(display_name)) > 0),
  check (status in ('active', 'invited', 'disabled', 'deleted')),
  check (jsonb_typeof(metadata) = 'object')
);

create unique index if not exists uq_users_tenant_email_ci
  on users (tenant_id, lower(email))
  where deleted_at is null;

create index if not exists idx_users_tenant_status
  on users(tenant_id, status);

create table if not exists user_identities (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  user_id uuid not null,
  provider text not null,
  provider_subject text not null,
  email_at_provider text null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, provider, provider_subject),
  foreign key (tenant_id, user_id) references users(tenant_id, id),
  check (length(btrim(provider)) > 0),
  check (length(btrim(provider_subject)) > 0),
  check (jsonb_typeof(metadata) = 'object')
);

create table if not exists team_members (
  tenant_id uuid not null references tenants(id),
  team_id uuid not null,
  user_id uuid not null,
  role text not null,
  created_at timestamptz not null default now(),
  primary key (tenant_id, team_id, user_id),
  foreign key (tenant_id, team_id) references teams(tenant_id, id),
  foreign key (tenant_id, user_id) references users(tenant_id, id),
  check (role in ('owner', 'admin', 'ops', 'billing', 'developer', 'viewer'))
);

create table if not exists projects (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  team_id uuid null,
  name text not null,
  status text not null default 'active',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  unique (tenant_id, id),
  unique (tenant_id, name),
  foreign key (tenant_id, team_id) references teams(tenant_id, id),
  check (length(btrim(name)) > 0),
  check (status in ('active', 'disabled', 'archived', 'deleted')),
  check (jsonb_typeof(metadata) = 'object')
);

create index if not exists idx_projects_tenant_status
  on projects(tenant_id, status);

create table if not exists project_members (
  tenant_id uuid not null references tenants(id),
  project_id uuid not null,
  user_id uuid not null,
  role text not null,
  created_at timestamptz not null default now(),
  primary key (tenant_id, project_id, user_id),
  foreign key (tenant_id, project_id) references projects(tenant_id, id),
  foreign key (tenant_id, user_id) references users(tenant_id, id),
  check (role in ('owner', 'admin', 'ops', 'billing', 'developer', 'viewer'))
);

create table if not exists payload_policies (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  name text not null,
  mode text not null default 'metadata_only',
  sample_rate numeric(5, 4) not null default 0,
  retention_days int null,
  config jsonb not null default '{}'::jsonb,
  status text not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  unique (tenant_id, id),
  unique (tenant_id, name),
  check (length(btrim(name)) > 0),
  check (mode in ('metadata_only', 'hash_only', 'redacted', 'full', 'sampled')),
  check (sample_rate >= 0 and sample_rate <= 1),
  check (retention_days is null or retention_days > 0),
  check (status in ('active', 'disabled', 'deleted')),
  check (jsonb_typeof(config) = 'object')
);

create table if not exists api_key_profiles (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  project_id uuid not null,
  name text not null,
  inbound_protocol text not null default 'auto',
  default_protocol_mode text not null default 'openai_compatible',
  model_aliases jsonb not null default '{}'::jsonb,
  allowed_models jsonb not null default '[]'::jsonb,
  denied_models jsonb not null default '[]'::jsonb,
  allowed_channel_tags jsonb not null default '[]'::jsonb,
  blocked_provider_ids jsonb not null default '[]'::jsonb,
  trace_header_rules jsonb not null default '{}'::jsonb,
  ip_allowlist jsonb not null default '[]'::jsonb,
  request_overrides jsonb not null default '[]'::jsonb,
  payload_policy_id uuid null,
  status text not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  unique (tenant_id, id),
  unique (tenant_id, project_id, id),
  unique (tenant_id, project_id, name),
  foreign key (tenant_id, project_id) references projects(tenant_id, id),
  foreign key (tenant_id, payload_policy_id) references payload_policies(tenant_id, id),
  check (length(btrim(name)) > 0),
  check (inbound_protocol in ('auto', 'openai', 'anthropic', 'gemini')),
  check (default_protocol_mode in ('openai_compatible', 'native_proxy', 'adapter_transform')),
  check (status in ('active', 'disabled', 'deleted')),
  check (jsonb_typeof(model_aliases) = 'object'),
  check (jsonb_typeof(allowed_models) = 'array'),
  check (jsonb_typeof(denied_models) = 'array'),
  check (jsonb_typeof(allowed_channel_tags) = 'array'),
  check (jsonb_typeof(blocked_provider_ids) = 'array'),
  check (jsonb_typeof(trace_header_rules) = 'object'),
  check (jsonb_typeof(request_overrides) = 'array')
);

create index if not exists idx_api_key_profiles_project_status
  on api_key_profiles(tenant_id, project_id, status);

create table if not exists virtual_keys (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  project_id uuid not null,
  name text not null,
  key_prefix text not null,
  secret_hash text not null,
  status text not null default 'active',
  default_profile_id uuid null,
  expires_at timestamptz null,
  last_used_at timestamptz null,
  ip_allowlist jsonb not null default '[]'::jsonb,
  rate_limit_policy jsonb not null default '{}'::jsonb,
  budget_policy jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_by_user_id uuid null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  unique (tenant_id, id),
  unique (tenant_id, project_id, id),
  unique (tenant_id, key_prefix),
  foreign key (tenant_id, project_id) references projects(tenant_id, id),
  foreign key (tenant_id, project_id, default_profile_id) references api_key_profiles(tenant_id, project_id, id),
  foreign key (tenant_id, created_by_user_id) references users(tenant_id, id),
  check (length(btrim(name)) > 0),
  check (length(btrim(key_prefix)) >= 8),
  check (length(btrim(secret_hash)) > 0),
  check (status in ('active', 'disabled', 'expired', 'revoked', 'deleted')),
  check (expires_at is null or expires_at > created_at),
  check (jsonb_typeof(ip_allowlist) = 'array'),
  check (jsonb_typeof(rate_limit_policy) = 'object'),
  check (jsonb_typeof(budget_policy) = 'object'),
  check (jsonb_typeof(metadata) = 'object')
);

create index if not exists idx_virtual_keys_project_status
  on virtual_keys(tenant_id, project_id, status);

create index if not exists idx_virtual_keys_last_used
  on virtual_keys(tenant_id, last_used_at desc)
  where last_used_at is not null;

create table if not exists virtual_key_profile_bindings (
  tenant_id uuid not null references tenants(id),
  project_id uuid not null,
  virtual_key_id uuid not null,
  profile_id uuid not null,
  is_default boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (tenant_id, virtual_key_id, profile_id),
  foreign key (tenant_id, project_id, virtual_key_id) references virtual_keys(tenant_id, project_id, id),
  foreign key (tenant_id, project_id, profile_id) references api_key_profiles(tenant_id, project_id, id)
);

create unique index if not exists uq_virtual_key_one_default_profile
  on virtual_key_profile_bindings(tenant_id, virtual_key_id)
  where is_default;

create table if not exists providers (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  code text not null,
  name text not null,
  status text not null default 'enabled',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  unique (tenant_id, id),
  unique (tenant_id, code),
  check (length(btrim(code)) > 0),
  check (length(btrim(name)) > 0),
  check (status in ('enabled', 'disabled', 'deleted')),
  check (jsonb_typeof(metadata) = 'object')
);

create index if not exists idx_providers_tenant_status
  on providers(tenant_id, status);

create table if not exists channels (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  provider_id uuid not null,
  name text not null,
  endpoint text not null,
  protocol_mode text not null,
  status text not null default 'enabled',
  region text null,
  priority int not null default 100,
  weight int not null default 100,
  tags jsonb not null default '[]'::jsonb,
  model_mappings jsonb not null default '{}'::jsonb,
  request_overrides jsonb not null default '[]'::jsonb,
  timeout_policy jsonb not null default '{}'::jsonb,
  probe_policy jsonb not null default '{}'::jsonb,
  health_score numeric(6, 3) not null default 1.0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  unique (tenant_id, id),
  unique (tenant_id, provider_id, id),
  unique (tenant_id, provider_id, name),
  foreign key (tenant_id, provider_id) references providers(tenant_id, id),
  check (length(btrim(name)) > 0),
  check (endpoint ~* '^https?://'),
  check (protocol_mode in ('openai_compatible', 'native_proxy', 'adapter_transform')),
  check (status in ('enabled', 'disabled', 'degraded', 'cooldown', 'deleted')),
  check (priority >= 0),
  check (weight >= 0),
  check (health_score >= 0 and health_score <= 1),
  check (jsonb_typeof(tags) = 'array'),
  check (jsonb_typeof(model_mappings) = 'object'),
  check (jsonb_typeof(request_overrides) = 'array'),
  check (jsonb_typeof(timeout_policy) = 'object'),
  check (jsonb_typeof(probe_policy) = 'object')
);

create index if not exists idx_channels_tenant_status_priority
  on channels(tenant_id, status, priority, health_score desc);

create index if not exists idx_channels_provider_status
  on channels(tenant_id, provider_id, status);

create index if not exists idx_channels_tags
  on channels using gin(tags jsonb_path_ops);

create table if not exists provider_keys (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  channel_id uuid not null,
  key_alias text not null,
  encrypted_secret text not null,
  secret_fingerprint text null,
  status text not null default 'enabled',
  health_score numeric(6, 3) not null default 1.0,
  cooldown_until timestamptz null,
  last_error_code text null,
  rpm_limit int null,
  tpm_limit int null,
  concurrency_limit int null,
  current_window_state jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  unique (tenant_id, id),
  unique (tenant_id, channel_id, id),
  unique (tenant_id, channel_id, key_alias),
  foreign key (tenant_id, channel_id) references channels(tenant_id, id),
  check (length(btrim(key_alias)) > 0),
  check (length(btrim(encrypted_secret)) > 0),
  check (status in ('enabled', 'degraded', 'cooldown', 'recovery_probe', 'auth_failed', 'quota_exhausted', 'manual_disabled', 'deleted')),
  check (health_score >= 0 and health_score <= 1),
  check (rpm_limit is null or rpm_limit > 0),
  check (tpm_limit is null or tpm_limit > 0),
  check (concurrency_limit is null or concurrency_limit > 0),
  check (jsonb_typeof(current_window_state) = 'object'),
  check (jsonb_typeof(metadata) = 'object')
);

create unique index if not exists uq_provider_keys_secret_fingerprint
  on provider_keys(tenant_id, channel_id, secret_fingerprint)
  where secret_fingerprint is not null and deleted_at is null;

create index if not exists idx_provider_keys_channel_status
  on provider_keys(tenant_id, channel_id, status);

create index if not exists idx_provider_keys_cooldown
  on provider_keys(tenant_id, cooldown_until)
  where cooldown_until is not null;

create table if not exists wallets (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  project_id uuid null,
  name text not null,
  currency text not null default 'USD',
  status text not null default 'active',
  balance_floor numeric(20, 8) not null default 0,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  unique (tenant_id, id),
  foreign key (tenant_id, project_id) references projects(tenant_id, id),
  check (length(btrim(name)) > 0),
  check (currency ~ '^[A-Z][A-Z0-9_]{2,31}$'),
  check (status in ('active', 'suspended', 'closed', 'deleted')),
  check (jsonb_typeof(metadata) = 'object')
);

create unique index if not exists uq_wallets_project_currency_active
  on wallets(tenant_id, project_id, currency)
  where project_id is not null and status in ('active', 'suspended');

create table if not exists credit_grants (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  wallet_id uuid not null,
  amount numeric(20, 8) not null,
  remaining_amount numeric(20, 8) not null,
  currency text not null default 'USD',
  source text not null,
  valid_from timestamptz not null default now(),
  valid_until timestamptz null,
  status text not null default 'active',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, wallet_id) references wallets(tenant_id, id),
  check (amount > 0),
  check (remaining_amount >= 0 and remaining_amount <= amount),
  check (currency ~ '^[A-Z][A-Z0-9_]{2,31}$'),
  check (length(btrim(source)) > 0),
  check (valid_until is null or valid_until > valid_from),
  check (status in ('active', 'consumed', 'expired', 'voided')),
  check (jsonb_typeof(metadata) = 'object')
);

create index if not exists idx_credit_grants_wallet_status
  on credit_grants(tenant_id, wallet_id, status, valid_until);

create table if not exists budgets (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  project_id uuid null,
  virtual_key_id uuid null,
  name text not null,
  scope text not null,
  currency text not null default 'USD',
  limit_amount numeric(20, 8) not null,
  period text not null default 'month',
  period_anchor timestamptz not null default now(),
  status text not null default 'active',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  unique (tenant_id, id),
  foreign key (tenant_id, project_id) references projects(tenant_id, id),
  foreign key (tenant_id, virtual_key_id) references virtual_keys(tenant_id, id),
  check (length(btrim(name)) > 0),
  check (scope in ('tenant', 'project', 'virtual_key')),
  check (currency ~ '^[A-Z][A-Z0-9_]{2,31}$'),
  check (limit_amount > 0),
  check (period in ('day', 'week', 'month', 'rolling_24h', 'rolling_7d', 'rolling_30d')),
  check (status in ('active', 'disabled', 'deleted')),
  check (jsonb_typeof(metadata) = 'object')
);

create index if not exists idx_budgets_scope_status
  on budgets(tenant_id, scope, status);

create table if not exists price_books (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  project_id uuid null,
  name text not null,
  currency text not null default 'USD',
  status text not null default 'draft',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz null,
  unique (tenant_id, id),
  unique (tenant_id, name),
  foreign key (tenant_id, project_id) references projects(tenant_id, id),
  check (length(btrim(name)) > 0),
  check (currency ~ '^[A-Z][A-Z0-9_]{2,31}$'),
  check (status in ('draft', 'active', 'archived')),
  check (jsonb_typeof(metadata) = 'object')
);

create table if not exists canonical_models (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  model_key text not null,
  display_name text not null,
  family text null,
  capabilities jsonb not null default '{}'::jsonb,
  context_length int null,
  max_output_tokens int null,
  supports_stream boolean not null default true,
  supports_tools boolean not null default false,
  supports_vision boolean not null default false,
  supports_audio boolean not null default false,
  supports_reasoning boolean not null default false,
  default_price_book_id uuid null,
  visibility text not null default 'internal',
  status text not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  unique (tenant_id, id),
  unique (tenant_id, model_key),
  foreign key (tenant_id, default_price_book_id) references price_books(tenant_id, id),
  check (length(btrim(model_key)) > 0),
  check (length(btrim(display_name)) > 0),
  check (context_length is null or context_length > 0),
  check (max_output_tokens is null or max_output_tokens > 0),
  check (visibility in ('public', 'internal', 'hidden')),
  check (status in ('active', 'deprecated', 'disabled', 'deleted')),
  check (jsonb_typeof(capabilities) = 'object')
);

create index if not exists idx_canonical_models_visibility_status
  on canonical_models(tenant_id, visibility, status);

create table if not exists model_associations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  canonical_model_id uuid not null,
  association_type text not null,
  channel_id uuid null,
  channel_tag text null,
  model_pattern text null,
  upstream_model_name text null,
  priority int not null default 100,
  conditions jsonb not null default '{}'::jsonb,
  fallback_allowed boolean not null default true,
  canary_percent numeric(5, 2) not null default 100,
  status text not null default 'enabled',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  unique (tenant_id, id),
  foreign key (tenant_id, canonical_model_id) references canonical_models(tenant_id, id),
  foreign key (tenant_id, channel_id) references channels(tenant_id, id),
  check (association_type in ('explicit_channel', 'channel_tag', 'model_pattern', 'global')),
  check (
    (association_type = 'explicit_channel' and channel_id is not null and channel_tag is null and model_pattern is null)
    or (association_type = 'channel_tag' and channel_id is null and channel_tag is not null and model_pattern is null)
    or (association_type = 'model_pattern' and channel_id is null and channel_tag is null and model_pattern is not null)
    or (association_type = 'global' and channel_id is null and channel_tag is null and model_pattern is null)
  ),
  check (priority >= 0),
  check (canary_percent >= 0 and canary_percent <= 100),
  check (status in ('enabled', 'disabled', 'deleted')),
  check (jsonb_typeof(conditions) = 'object')
);

create unique index if not exists uq_model_associations_channel
  on model_associations(tenant_id, canonical_model_id, channel_id, coalesce(upstream_model_name, ''))
  where association_type = 'explicit_channel' and status <> 'deleted';

create unique index if not exists uq_model_associations_tag
  on model_associations(tenant_id, canonical_model_id, channel_tag, coalesce(upstream_model_name, ''))
  where association_type = 'channel_tag' and status <> 'deleted';

create index if not exists idx_model_associations_route
  on model_associations(tenant_id, canonical_model_id, status, priority);

create table if not exists price_versions (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  price_book_id uuid not null,
  canonical_model_id uuid null,
  version text not null,
  pricing_rules jsonb not null,
  effective_at timestamptz not null default now(),
  retired_at timestamptz null,
  status text not null default 'draft',
  created_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, price_book_id, version),
  foreign key (tenant_id, price_book_id) references price_books(tenant_id, id),
  foreign key (tenant_id, canonical_model_id) references canonical_models(tenant_id, id),
  check (length(btrim(version)) > 0),
  check (jsonb_typeof(pricing_rules) = 'object'),
  check (retired_at is null or retired_at > effective_at),
  check (status in ('draft', 'active', 'retired'))
);

create index if not exists idx_price_versions_lookup
  on price_versions(tenant_id, price_book_id, canonical_model_id, status, effective_at desc);

create table if not exists request_logs (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  project_id uuid null,
  virtual_key_id uuid null,
  api_key_profile_id uuid null,
  trace_id text null,
  thread_id text null,
  client_request_id text null,
  inbound_protocol text null,
  outbound_protocol text null,
  protocol_mode text null,
  requested_model text null,
  canonical_model_id uuid null,
  upstream_model text null,
  resolved_provider_id uuid null,
  resolved_channel_id uuid null,
  provider_key_id uuid null,
  route_policy_version text null,
  status text not null,
  http_status int null,
  error_owner text null,
  error_code text null,
  retryable boolean null,
  partial_sent boolean not null default false,
  stream_end_reason text null,
  input_tokens bigint not null default 0,
  output_tokens bigint not null default 0,
  cache_read_tokens bigint not null default 0,
  cache_write_tokens bigint not null default 0,
  reasoning_tokens bigint not null default 0,
  estimated_cost numeric(20, 8) not null default 0,
  final_cost numeric(20, 8) not null default 0,
  currency text not null default 'USD',
  price_version_id uuid null,
  latency_ms int null,
  ttft_ms int null,
  stream_duration_ms int null,
  tokens_per_second numeric(20, 8) null,
  payload_policy_id uuid null,
  payload_stored boolean not null default false,
  payload_object_ref text null,
  redaction_status text not null default 'metadata_only',
  request_body_hash text null,
  response_body_hash text null,
  route_decision_snapshot jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  completed_at timestamptz null,
  unique (tenant_id, id),
  foreign key (tenant_id, project_id) references projects(tenant_id, id),
  foreign key (tenant_id, project_id, virtual_key_id) references virtual_keys(tenant_id, project_id, id),
  foreign key (tenant_id, project_id, api_key_profile_id) references api_key_profiles(tenant_id, project_id, id),
  foreign key (tenant_id, canonical_model_id) references canonical_models(tenant_id, id),
  foreign key (tenant_id, resolved_provider_id) references providers(tenant_id, id),
  foreign key (tenant_id, resolved_channel_id) references channels(tenant_id, id),
  foreign key (tenant_id, provider_key_id) references provider_keys(tenant_id, id),
  foreign key (tenant_id, price_version_id) references price_versions(tenant_id, id),
  foreign key (tenant_id, payload_policy_id) references payload_policies(tenant_id, id),
  check (virtual_key_id is null or project_id is not null),
  check (api_key_profile_id is null or project_id is not null),
  check (status in ('started', 'succeeded', 'failed', 'cancelled', 'partial', 'rejected')),
  check (http_status is null or (http_status >= 100 and http_status <= 599)),
  check (error_owner is null or error_owner in ('client', 'gateway', 'provider', 'network', 'parser', 'billing', 'policy', 'task')),
  check (stream_end_reason is null or stream_end_reason in ('completed', 'client_cancel', 'provider_eof', 'missing_terminal', 'gateway_abort', 'timeout', 'error')),
  check (input_tokens >= 0),
  check (output_tokens >= 0),
  check (cache_read_tokens >= 0),
  check (cache_write_tokens >= 0),
  check (reasoning_tokens >= 0),
  check (estimated_cost >= 0),
  check (final_cost >= 0),
  check (currency ~ '^[A-Z][A-Z0-9_]{2,31}$'),
  check (latency_ms is null or latency_ms >= 0),
  check (ttft_ms is null or ttft_ms >= 0),
  check (stream_duration_ms is null or stream_duration_ms >= 0),
  check (tokens_per_second is null or tokens_per_second >= 0),
  check (redaction_status in ('metadata_only', 'hash_only', 'redacted', 'full', 'sampled')),
  check (completed_at is null or completed_at >= created_at),
  check (jsonb_typeof(route_decision_snapshot) = 'object')
);

create index if not exists idx_request_logs_tenant_time
  on request_logs(tenant_id, created_at desc);

create index if not exists idx_request_logs_project_time
  on request_logs(tenant_id, project_id, created_at desc)
  where project_id is not null;

create index if not exists idx_request_logs_virtual_key_time
  on request_logs(tenant_id, virtual_key_id, created_at desc)
  where virtual_key_id is not null;

create index if not exists idx_request_logs_trace_time
  on request_logs(tenant_id, trace_id, created_at desc)
  where trace_id is not null;

create index if not exists idx_request_logs_thread_time
  on request_logs(tenant_id, thread_id, created_at desc)
  where thread_id is not null;

create index if not exists idx_request_logs_model_time
  on request_logs(tenant_id, canonical_model_id, created_at desc)
  where canonical_model_id is not null;

create index if not exists idx_request_logs_channel_time
  on request_logs(tenant_id, resolved_channel_id, created_at desc)
  where resolved_channel_id is not null;

create index if not exists idx_request_logs_error_time
  on request_logs(tenant_id, error_code, created_at desc)
  where error_code is not null;

create table if not exists provider_attempts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  request_id uuid not null,
  provider_id uuid null,
  channel_id uuid null,
  provider_key_id uuid null,
  attempt_no int not null,
  upstream_model text null,
  status text not null,
  http_status int null,
  error_owner text null,
  error_code text null,
  retryable boolean null,
  fallback_reason text null,
  latency_ms int null,
  ttft_ms int null,
  provider_request_id text null,
  input_tokens bigint not null default 0,
  output_tokens bigint not null default 0,
  metadata jsonb not null default '{}'::jsonb,
  started_at timestamptz not null default now(),
  completed_at timestamptz null,
  unique (tenant_id, id),
  unique (tenant_id, request_id, attempt_no),
  foreign key (tenant_id, request_id) references request_logs(tenant_id, id),
  foreign key (tenant_id, provider_id) references providers(tenant_id, id),
  foreign key (tenant_id, channel_id) references channels(tenant_id, id),
  foreign key (tenant_id, provider_key_id) references provider_keys(tenant_id, id),
  check (attempt_no > 0),
  check (status in ('candidate', 'skipped', 'started', 'succeeded', 'failed', 'cancelled')),
  check (http_status is null or (http_status >= 100 and http_status <= 599)),
  check (error_owner is null or error_owner in ('client', 'gateway', 'provider', 'network', 'parser', 'billing', 'policy', 'task')),
  check (latency_ms is null or latency_ms >= 0),
  check (ttft_ms is null or ttft_ms >= 0),
  check (input_tokens >= 0),
  check (output_tokens >= 0),
  check (completed_at is null or completed_at >= started_at),
  check (jsonb_typeof(metadata) = 'object')
);

create index if not exists idx_provider_attempts_request
  on provider_attempts(tenant_id, request_id, attempt_no);

create index if not exists idx_provider_attempts_channel_time
  on provider_attempts(tenant_id, channel_id, started_at desc)
  where channel_id is not null;

create index if not exists idx_provider_attempts_key_time
  on provider_attempts(tenant_id, provider_key_id, started_at desc)
  where provider_key_id is not null;

create index if not exists idx_provider_attempts_error_time
  on provider_attempts(tenant_id, error_code, started_at desc)
  where error_code is not null;

create table if not exists ledger_entries (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  project_id uuid null,
  wallet_id uuid null,
  request_id uuid null,
  virtual_key_id uuid null,
  trace_id text null,
  related_ledger_entry_id uuid null,
  entry_type text not null,
  amount numeric(20, 8) not null,
  currency text not null,
  status text not null default 'confirmed',
  idempotency_key text not null,
  price_version_id uuid null,
  usage_snapshot jsonb not null default '{}'::jsonb,
  policy_snapshot jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, idempotency_key),
  foreign key (tenant_id, project_id) references projects(tenant_id, id),
  foreign key (tenant_id, wallet_id) references wallets(tenant_id, id),
  foreign key (tenant_id, request_id) references request_logs(tenant_id, id),
  foreign key (tenant_id, virtual_key_id) references virtual_keys(tenant_id, id),
  foreign key (tenant_id, related_ledger_entry_id) references ledger_entries(tenant_id, id),
  foreign key (tenant_id, price_version_id) references price_versions(tenant_id, id),
  check (length(btrim(idempotency_key)) > 0),
  check (entry_type in ('reserve', 'settle', 'refund', 'adjust', 'expire', 'credit_grant', 'credit_expire')),
  check (amount <> 0),
  check (currency ~ '^[A-Z][A-Z0-9_]{2,31}$'),
  check (status in ('pending', 'confirmed', 'reversed')),
  check (entry_type <> 'refund' or related_ledger_entry_id is not null),
  check (jsonb_typeof(usage_snapshot) = 'object'),
  check (jsonb_typeof(policy_snapshot) = 'object'),
  check (jsonb_typeof(metadata) = 'object')
);

create unique index if not exists uq_ledger_entries_one_settle_per_request
  on ledger_entries(tenant_id, request_id)
  where entry_type = 'settle' and status in ('pending', 'confirmed') and request_id is not null;

create index if not exists idx_ledger_entries_tenant_time
  on ledger_entries(tenant_id, created_at desc);

create index if not exists idx_ledger_entries_project_time
  on ledger_entries(tenant_id, project_id, created_at desc)
  where project_id is not null;

create index if not exists idx_ledger_entries_request
  on ledger_entries(tenant_id, request_id)
  where request_id is not null;

create index if not exists idx_ledger_entries_wallet_time
  on ledger_entries(tenant_id, wallet_id, created_at desc)
  where wallet_id is not null;

create table if not exists audit_logs (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  actor_user_id uuid null,
  request_id uuid null,
  action text not null,
  resource_type text not null,
  resource_id uuid null,
  resource_tenant_id uuid null,
  before_snapshot jsonb null,
  after_snapshot jsonb null,
  ip_address inet null,
  user_agent text null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, actor_user_id) references users(tenant_id, id),
  foreign key (tenant_id, request_id) references request_logs(tenant_id, id),
  check (length(btrim(action)) > 0),
  check (length(btrim(resource_type)) > 0),
  check (before_snapshot is null or jsonb_typeof(before_snapshot) = 'object'),
  check (after_snapshot is null or jsonb_typeof(after_snapshot) = 'object'),
  check (jsonb_typeof(metadata) = 'object')
);

create index if not exists idx_audit_logs_tenant_time
  on audit_logs(tenant_id, created_at desc);

create index if not exists idx_audit_logs_actor_time
  on audit_logs(tenant_id, actor_user_id, created_at desc)
  where actor_user_id is not null;

create index if not exists idx_audit_logs_resource
  on audit_logs(tenant_id, resource_type, resource_id, created_at desc)
  where resource_id is not null;

insert into tenants (id, name, slug)
values ('00000000-0000-0000-0000-000000000001', 'Default Tenant', 'default')
on conflict do nothing;

insert into teams (id, tenant_id, name)
values ('00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001', 'Default Team')
on conflict do nothing;

insert into projects (id, tenant_id, team_id, name)
values (
  '00000000-0000-0000-0000-000000000020',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000010',
  'Default Project'
)
on conflict do nothing;

insert into payload_policies (id, tenant_id, name, mode)
values ('00000000-0000-0000-0000-000000000030', '00000000-0000-0000-0000-000000000001', 'Default Metadata Only', 'metadata_only')
on conflict do nothing;

insert into api_key_profiles (id, tenant_id, project_id, name, inbound_protocol, default_protocol_mode, payload_policy_id)
values (
  '00000000-0000-0000-0000-000000000040',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000020',
  'Default OpenAI Compatible',
  'openai',
  'openai_compatible',
  '00000000-0000-0000-0000-000000000030'
)
on conflict do nothing;
