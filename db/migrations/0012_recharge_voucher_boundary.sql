create table if not exists recharge_intents (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  project_id uuid null,
  wallet_id uuid not null,
  currency text not null,
  amount numeric(20, 8) not null,
  status text not null,
  external_source text not null,
  external_reference_id text null,
  idempotency_key_hash text not null,
  provider_reference_redacted text null,
  credit_grant_id uuid null,
  ledger_entry_id uuid null,
  reversal_ledger_entry_id uuid null,
  audit_id uuid null,
  request_summary jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, idempotency_key_hash),
  unique (tenant_id, external_source, external_reference_id),
  foreign key (tenant_id, project_id) references projects(tenant_id, id),
  foreign key (tenant_id, wallet_id) references wallets(tenant_id, id),
  foreign key (tenant_id, credit_grant_id) references credit_grants(tenant_id, id),
  foreign key (tenant_id, ledger_entry_id) references ledger_entries(tenant_id, id),
  foreign key (tenant_id, reversal_ledger_entry_id) references ledger_entries(tenant_id, id),
  foreign key (tenant_id, audit_id) references audit_logs(tenant_id, id),
  check (currency ~ '^[A-Z][A-Z0-9_]{2,31}$'),
  check (amount > 0),
  check (status in ('created', 'pending', 'paid', 'cancelled', 'refunded', 'refused')),
  check (length(btrim(external_source)) > 0),
  check (length(btrim(idempotency_key_hash)) > 0),
  check (external_reference_id is null or length(btrim(external_reference_id)) > 0),
  check (jsonb_typeof(request_summary) = 'object'),
  check (jsonb_typeof(metadata) = 'object')
);

create index if not exists idx_recharge_intents_wallet_status_created
  on recharge_intents(tenant_id, wallet_id, status, created_at desc);

create index if not exists idx_recharge_intents_project_created
  on recharge_intents(tenant_id, project_id, created_at desc)
  where project_id is not null;

create table if not exists voucher_campaigns (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  project_id uuid null,
  name text not null,
  scope text not null,
  currency text not null,
  amount numeric(20, 8) not null,
  max_redemptions integer not null default 1,
  valid_from timestamptz not null default now(),
  expires_at timestamptz null,
  status text not null default 'active',
  audit_id uuid null,
  request_summary jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, project_id) references projects(tenant_id, id),
  foreign key (tenant_id, audit_id) references audit_logs(tenant_id, id),
  check (currency ~ '^[A-Z][A-Z0-9_]{2,31}$'),
  check (amount > 0),
  check (max_redemptions > 0),
  check (status in ('active', 'paused', 'expired', 'revoked')),
  check (scope in ('tenant', 'project', 'wallet')),
  check (length(btrim(name)) > 0),
  check (jsonb_typeof(request_summary) = 'object'),
  check (jsonb_typeof(metadata) = 'object')
);

create index if not exists idx_voucher_campaigns_tenant_status
  on voucher_campaigns(tenant_id, status, created_at desc);

create table if not exists voucher_issuances (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  project_id uuid null,
  wallet_id uuid null,
  campaign_id uuid null,
  currency text not null,
  amount numeric(20, 8) not null,
  code_hash text not null,
  code_lookup_prefix text not null,
  code_redacted text not null,
  status text not null default 'issued',
  max_redemptions integer not null default 1,
  redemption_count integer not null default 0,
  valid_from timestamptz not null default now(),
  expires_at timestamptz null,
  idempotency_key_hash text not null,
  audit_id uuid null,
  request_summary jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, code_hash),
  unique (tenant_id, idempotency_key_hash),
  foreign key (tenant_id, project_id) references projects(tenant_id, id),
  foreign key (tenant_id, wallet_id) references wallets(tenant_id, id),
  foreign key (tenant_id, campaign_id) references voucher_campaigns(tenant_id, id),
  foreign key (tenant_id, audit_id) references audit_logs(tenant_id, id),
  check (currency ~ '^[A-Z][A-Z0-9_]{2,31}$'),
  check (amount > 0),
  check (status in ('issued', 'redeemed', 'expired', 'revoked')),
  check (max_redemptions > 0),
  check (redemption_count >= 0 and redemption_count <= max_redemptions),
  check (length(btrim(code_hash)) > 0),
  check (length(btrim(code_lookup_prefix)) > 0),
  check (length(btrim(code_redacted)) > 0),
  check (length(btrim(idempotency_key_hash)) > 0),
  check (jsonb_typeof(request_summary) = 'object'),
  check (jsonb_typeof(metadata) = 'object')
);

create index if not exists idx_voucher_issuances_lookup
  on voucher_issuances(tenant_id, code_lookup_prefix, status);

create index if not exists idx_voucher_issuances_wallet_status_created
  on voucher_issuances(tenant_id, wallet_id, status, created_at desc)
  where wallet_id is not null;

create table if not exists voucher_redemptions (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  project_id uuid null,
  wallet_id uuid not null,
  voucher_id uuid not null,
  redeemer_user_id uuid null,
  currency text not null,
  amount numeric(20, 8) not null,
  status text not null,
  idempotency_key_hash text not null,
  credit_grant_id uuid null,
  ledger_entry_id uuid null,
  audit_id uuid null,
  refusal_code text null,
  request_summary jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, idempotency_key_hash),
  foreign key (tenant_id, project_id) references projects(tenant_id, id),
  foreign key (tenant_id, wallet_id) references wallets(tenant_id, id),
  foreign key (tenant_id, voucher_id) references voucher_issuances(tenant_id, id),
  foreign key (tenant_id, credit_grant_id) references credit_grants(tenant_id, id),
  foreign key (tenant_id, ledger_entry_id) references ledger_entries(tenant_id, id),
  foreign key (tenant_id, audit_id) references audit_logs(tenant_id, id),
  check (currency ~ '^[A-Z][A-Z0-9_]{2,31}$'),
  check (amount > 0),
  check (status in ('redeemed', 'replayed', 'refused')),
  check (length(btrim(idempotency_key_hash)) > 0),
  check (refusal_code is null or length(btrim(refusal_code)) > 0),
  check (jsonb_typeof(request_summary) = 'object'),
  check (jsonb_typeof(metadata) = 'object')
);

create index if not exists idx_voucher_redemptions_voucher_created
  on voucher_redemptions(tenant_id, voucher_id, created_at desc);

create index if not exists idx_voucher_redemptions_wallet_created
  on voucher_redemptions(tenant_id, wallet_id, created_at desc);

create table if not exists voucher_redeem_attempts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  project_id uuid null,
  wallet_id uuid null,
  code_lookup_prefix text not null,
  outcome text not null,
  refusal_code text null,
  actor_fingerprint_hash text null,
  attempt_count integer not null default 1,
  window_started_at timestamptz not null default now(),
  audit_id uuid null,
  request_summary jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, project_id) references projects(tenant_id, id),
  foreign key (tenant_id, wallet_id) references wallets(tenant_id, id),
  foreign key (tenant_id, audit_id) references audit_logs(tenant_id, id),
  check (outcome in ('accepted', 'refused', 'rate_limited')),
  check (attempt_count > 0),
  check (length(btrim(code_lookup_prefix)) > 0),
  check (refusal_code is null or length(btrim(refusal_code)) > 0),
  check (actor_fingerprint_hash is null or length(btrim(actor_fingerprint_hash)) > 0),
  check (jsonb_typeof(request_summary) = 'object'),
  check (jsonb_typeof(metadata) = 'object')
);

create index if not exists idx_voucher_redeem_attempts_prefix_window
  on voucher_redeem_attempts(tenant_id, code_lookup_prefix, window_started_at desc);

