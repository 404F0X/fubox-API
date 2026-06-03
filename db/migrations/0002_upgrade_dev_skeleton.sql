create extension if not exists pgcrypto;

alter table tenants add column if not exists slug text;
alter table tenants add column if not exists metadata jsonb not null default '{}'::jsonb;
alter table tenants add column if not exists deleted_at timestamptz null;
update tenants
set slug = lower(regexp_replace(name, '[^a-zA-Z0-9]+', '-', 'g'))
where slug is null or length(btrim(slug)) = 0;
update tenants
set slug = 'tenant-' || left(id::text, 8)
where slug is null or length(btrim(slug)) = 0;
alter table tenants alter column slug set not null;
create unique index if not exists ux_tenants_slug_upgrade on tenants(slug);

alter table teams add column if not exists metadata jsonb not null default '{}'::jsonb;
alter table teams add column if not exists deleted_at timestamptz null;
alter table users add column if not exists last_login_at timestamptz null;
alter table users add column if not exists metadata jsonb not null default '{}'::jsonb;
alter table users add column if not exists deleted_at timestamptz null;
alter table projects add column if not exists metadata jsonb not null default '{}'::jsonb;
alter table projects add column if not exists deleted_at timestamptz null;
alter table providers add column if not exists deleted_at timestamptz null;

create unique index if not exists ux_teams_tenant_id_upgrade on teams(tenant_id, id);
create unique index if not exists ux_users_tenant_id_upgrade on users(tenant_id, id);
create unique index if not exists ux_projects_tenant_id_upgrade on projects(tenant_id, id);
create unique index if not exists ux_providers_tenant_id_upgrade on providers(tenant_id, id);
create unique index if not exists ux_users_tenant_email_ci_upgrade
  on users(tenant_id, lower(email))
  where deleted_at is null;

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
  check (jsonb_typeof(ip_allowlist) = 'array'),
  check (jsonb_typeof(request_overrides) = 'array')
);

alter table virtual_keys add column if not exists rate_limit_policy jsonb not null default '{}'::jsonb;
alter table virtual_keys add column if not exists budget_policy jsonb not null default '{}'::jsonb;
alter table virtual_keys add column if not exists created_by_user_id uuid null;
alter table virtual_keys add column if not exists deleted_at timestamptz null;
create unique index if not exists ux_virtual_keys_tenant_id_upgrade on virtual_keys(tenant_id, id);
create unique index if not exists ux_virtual_keys_tenant_project_id_upgrade on virtual_keys(tenant_id, project_id, id);

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

alter table channels add column if not exists region text null;
alter table channels add column if not exists probe_policy jsonb not null default '{}'::jsonb;
alter table channels add column if not exists deleted_at timestamptz null;
create unique index if not exists ux_channels_tenant_id_upgrade on channels(tenant_id, id);
create unique index if not exists ux_channels_tenant_provider_id_upgrade on channels(tenant_id, provider_id, id);
create unique index if not exists ux_channels_tenant_provider_name_upgrade on channels(tenant_id, provider_id, name);

alter table provider_keys add column if not exists secret_fingerprint text null;
alter table provider_keys add column if not exists concurrency_limit int null;
alter table provider_keys add column if not exists metadata jsonb not null default '{}'::jsonb;
alter table provider_keys add column if not exists deleted_at timestamptz null;
create unique index if not exists ux_provider_keys_tenant_id_upgrade on provider_keys(tenant_id, id);
create unique index if not exists ux_provider_keys_tenant_channel_id_upgrade on provider_keys(tenant_id, channel_id, id);

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

alter table canonical_models add column if not exists supports_stream boolean not null default true;
alter table canonical_models add column if not exists supports_tools boolean not null default false;
alter table canonical_models add column if not exists supports_vision boolean not null default false;
alter table canonical_models add column if not exists supports_audio boolean not null default false;
alter table canonical_models add column if not exists supports_reasoning boolean not null default false;
alter table canonical_models add column if not exists default_price_book_id uuid null;
alter table canonical_models add column if not exists deleted_at timestamptz null;
create unique index if not exists ux_canonical_models_tenant_id_upgrade on canonical_models(tenant_id, id);

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
  check (priority >= 0),
  check (canary_percent >= 0 and canary_percent <= 100),
  check (status in ('enabled', 'disabled', 'deleted')),
  check (jsonb_typeof(conditions) = 'object')
);

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'model_associations'::regclass
      and conname = 'chk_model_associations_type_target_upgrade'
  ) then
    alter table model_associations
      add constraint chk_model_associations_type_target_upgrade
      check (
        (association_type = 'explicit_channel' and channel_id is not null and channel_tag is null and model_pattern is null)
        or (association_type = 'channel_tag' and channel_id is null and channel_tag is not null and model_pattern is null)
        or (association_type = 'model_pattern' and channel_id is null and channel_tag is null and model_pattern is not null)
        or (association_type = 'global' and channel_id is null and channel_tag is null and model_pattern is null)
      ) not valid;
  end if;
end $$;

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

alter table request_logs add column if not exists api_key_profile_id uuid null;
alter table request_logs add column if not exists project_id uuid null;
alter table request_logs add column if not exists virtual_key_id uuid null;
alter table request_logs add column if not exists trace_id text null;
alter table request_logs add column if not exists thread_id text null;
alter table request_logs add column if not exists client_request_id text null;
alter table request_logs add column if not exists inbound_protocol text null;
alter table request_logs add column if not exists outbound_protocol text null;
alter table request_logs add column if not exists protocol_mode text null;
alter table request_logs add column if not exists requested_model text null;
alter table request_logs add column if not exists canonical_model_id uuid null;
alter table request_logs add column if not exists upstream_model text null;
alter table request_logs add column if not exists resolved_provider_id uuid null;
alter table request_logs add column if not exists resolved_channel_id uuid null;
alter table request_logs add column if not exists provider_key_id uuid null;
alter table request_logs add column if not exists route_policy_version text null;
alter table request_logs add column if not exists status text not null default 'started';
alter table request_logs add column if not exists http_status int null;
alter table request_logs add column if not exists error_owner text null;
alter table request_logs add column if not exists error_code text null;
alter table request_logs add column if not exists retryable boolean null;
alter table request_logs add column if not exists partial_sent boolean not null default false;
alter table request_logs add column if not exists stream_end_reason text null;
alter table request_logs add column if not exists input_tokens bigint not null default 0;
alter table request_logs add column if not exists output_tokens bigint not null default 0;
alter table request_logs add column if not exists cache_read_tokens bigint not null default 0;
alter table request_logs add column if not exists cache_write_tokens bigint not null default 0;
alter table request_logs add column if not exists reasoning_tokens bigint not null default 0;
alter table request_logs add column if not exists estimated_cost numeric(20, 8) not null default 0;
alter table request_logs add column if not exists final_cost numeric(20, 8) not null default 0;
alter table request_logs add column if not exists currency text not null default 'USD';
alter table request_logs add column if not exists price_version_id uuid null;
alter table request_logs add column if not exists latency_ms int null;
alter table request_logs add column if not exists ttft_ms int null;
alter table request_logs add column if not exists stream_duration_ms int null;
alter table request_logs add column if not exists tokens_per_second numeric(20, 8) null;
alter table request_logs add column if not exists payload_policy_id uuid null;
alter table request_logs add column if not exists payload_stored boolean not null default false;
alter table request_logs add column if not exists payload_object_ref text null;
alter table request_logs add column if not exists redaction_status text not null default 'metadata_only';
alter table request_logs add column if not exists request_body_hash text null;
alter table request_logs add column if not exists response_body_hash text null;
alter table request_logs add column if not exists route_decision_snapshot jsonb not null default '{}'::jsonb;
alter table request_logs add column if not exists completed_at timestamptz null;
create unique index if not exists ux_request_logs_tenant_id_upgrade on request_logs(tenant_id, id);

alter table provider_attempts add column if not exists request_id uuid null;
alter table provider_attempts add column if not exists provider_id uuid null;
alter table provider_attempts add column if not exists channel_id uuid null;
alter table provider_attempts add column if not exists provider_key_id uuid null;
alter table provider_attempts add column if not exists attempt_no int not null default 1;
alter table provider_attempts add column if not exists upstream_model text null;
alter table provider_attempts add column if not exists status text not null default 'started';
alter table provider_attempts add column if not exists http_status int null;
alter table provider_attempts add column if not exists error_owner text null;
alter table provider_attempts add column if not exists error_code text null;
alter table provider_attempts add column if not exists retryable boolean null;
alter table provider_attempts add column if not exists fallback_reason text null;
alter table provider_attempts add column if not exists latency_ms int null;
alter table provider_attempts add column if not exists ttft_ms int null;
alter table provider_attempts add column if not exists provider_request_id text null;
alter table provider_attempts add column if not exists input_tokens bigint not null default 0;
alter table provider_attempts add column if not exists output_tokens bigint not null default 0;
alter table provider_attempts add column if not exists metadata jsonb not null default '{}'::jsonb;
alter table provider_attempts add column if not exists started_at timestamptz not null default now();
alter table provider_attempts add column if not exists completed_at timestamptz null;
create unique index if not exists ux_provider_attempts_tenant_id_upgrade on provider_attempts(tenant_id, id);

alter table ledger_entries add column if not exists wallet_id uuid null;
alter table ledger_entries add column if not exists virtual_key_id uuid null;
alter table ledger_entries add column if not exists trace_id text null;
alter table ledger_entries add column if not exists related_ledger_entry_id uuid null;
alter table ledger_entries add column if not exists metadata jsonb not null default '{}'::jsonb;
alter table ledger_entries add column if not exists occurred_at timestamptz not null default now();
create unique index if not exists ux_ledger_entries_tenant_id_upgrade on ledger_entries(tenant_id, id);
create unique index if not exists uq_ledger_entries_one_settle_per_request
  on ledger_entries(tenant_id, request_id)
  where entry_type = 'settle' and status in ('pending', 'confirmed') and request_id is not null;

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

create index if not exists idx_api_key_profiles_project_status
  on api_key_profiles(tenant_id, project_id, status);
create index if not exists idx_model_associations_route
  on model_associations(tenant_id, canonical_model_id, status, priority);
create index if not exists idx_price_versions_lookup
  on price_versions(tenant_id, price_book_id, canonical_model_id, status, effective_at desc);
create index if not exists idx_audit_logs_tenant_time
  on audit_logs(tenant_id, created_at desc);

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'chk_tenants_status_upgrade') then
    alter table tenants
      add constraint chk_tenants_status_upgrade
      check (status in ('active', 'suspended', 'deleted'));
  end if;

  if not exists (select 1 from pg_constraint where conname = 'fk_request_logs_project_tenant_upgrade') then
    alter table request_logs
      add constraint fk_request_logs_project_tenant_upgrade
      foreign key (tenant_id, project_id) references projects(tenant_id, id);
  end if;

  if not exists (select 1 from pg_constraint where conname = 'fk_request_logs_virtual_key_tenant_upgrade') then
    alter table request_logs
      add constraint fk_request_logs_virtual_key_tenant_upgrade
      foreign key (tenant_id, virtual_key_id) references virtual_keys(tenant_id, id);
  end if;

  if not exists (select 1 from pg_constraint where conname = 'fk_provider_attempts_request_tenant_upgrade') then
    alter table provider_attempts
      add constraint fk_provider_attempts_request_tenant_upgrade
      foreign key (tenant_id, request_id) references request_logs(tenant_id, id);
  end if;

  if not exists (select 1 from pg_constraint where conname = 'fk_ledger_entries_request_tenant_upgrade') then
    alter table ledger_entries
      add constraint fk_ledger_entries_request_tenant_upgrade
      foreign key (tenant_id, request_id) references request_logs(tenant_id, id);
  end if;
end $$;

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
