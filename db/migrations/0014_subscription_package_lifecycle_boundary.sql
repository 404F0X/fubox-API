create table if not exists subscription_plans (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  plan_code text not null,
  display_name text not null,
  status text not null,
  currency text not null,
  billing_interval text not null,
  unit_price numeric(20, 8) not null,
  included_credit_amount numeric(20, 8) not null default 0,
  trial_days integer not null default 0,
  request_summary jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, plan_code),
  check (length(btrim(plan_code)) > 0),
  check (length(btrim(display_name)) > 0),
  check (status in ('draft', 'active', 'archived')),
  check (currency ~ '^[A-Z][A-Z0-9_]{2,31}$'),
  check (billing_interval in ('month', 'year', 'one_time')),
  check (unit_price > 0),
  check (included_credit_amount >= 0),
  check (trial_days >= 0),
  check (jsonb_typeof(request_summary) = 'object'),
  check (jsonb_typeof(metadata) = 'object')
);

create index if not exists idx_subscription_plans_tenant_status_created
  on subscription_plans(tenant_id, status, created_at desc);

create table if not exists subscription_packages (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  plan_id uuid not null,
  package_code text not null,
  status text not null,
  entitlement_summary jsonb not null default '{}'::jsonb,
  request_summary jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, package_code),
  foreign key (tenant_id, plan_id) references subscription_plans(tenant_id, id),
  check (length(btrim(package_code)) > 0),
  check (status in ('draft', 'active', 'archived')),
  check (jsonb_typeof(entitlement_summary) = 'object'),
  check (jsonb_typeof(request_summary) = 'object'),
  check (jsonb_typeof(metadata) = 'object')
);

create index if not exists idx_subscription_packages_plan_status_created
  on subscription_packages(tenant_id, plan_id, status, created_at desc);

create table if not exists subscriptions (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  project_id uuid null,
  wallet_id uuid not null,
  plan_id uuid not null,
  package_id uuid null,
  status text not null,
  currency text not null,
  current_period_start timestamptz not null,
  current_period_end timestamptz not null,
  trial_ends_at timestamptz null,
  paused_at timestamptz null,
  cancelled_at timestamptz null,
  idempotency_key_hash text not null,
  latest_credit_grant_id uuid null,
  latest_ledger_entry_id uuid null,
  latest_invoice_id uuid null,
  latest_order_id uuid null,
  audit_id uuid null,
  request_summary jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, idempotency_key_hash),
  foreign key (tenant_id, project_id) references projects(tenant_id, id),
  foreign key (tenant_id, wallet_id) references wallets(tenant_id, id),
  foreign key (tenant_id, plan_id) references subscription_plans(tenant_id, id),
  foreign key (tenant_id, package_id) references subscription_packages(tenant_id, id),
  foreign key (tenant_id, latest_credit_grant_id) references credit_grants(tenant_id, id),
  foreign key (tenant_id, latest_ledger_entry_id) references ledger_entries(tenant_id, id),
  foreign key (tenant_id, latest_invoice_id) references invoices(tenant_id, id),
  foreign key (tenant_id, latest_order_id) references payment_orders(tenant_id, id),
  foreign key (tenant_id, audit_id) references audit_logs(tenant_id, id),
  check (status in ('created', 'trialing', 'active', 'renewed', 'paused', 'resumed', 'cancelled', 'payment_failed', 'expired', 'terminated')),
  check (currency ~ '^[A-Z][A-Z0-9_]{2,31}$'),
  check (current_period_end > current_period_start),
  check (length(btrim(idempotency_key_hash)) > 0),
  check (jsonb_typeof(request_summary) = 'object'),
  check (jsonb_typeof(metadata) = 'object')
);

create index if not exists idx_subscriptions_wallet_status_period
  on subscriptions(tenant_id, wallet_id, status, current_period_end desc);

create table if not exists subscription_events_or_schedules (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  subscription_id uuid not null,
  event_type text not null,
  event_status text not null,
  effective_at timestamptz not null,
  idempotency_key_hash text not null,
  credit_grant_id uuid null,
  ledger_entry_id uuid null,
  invoice_id uuid null,
  order_id uuid null,
  audit_id uuid null,
  refusal_code text null,
  request_summary jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, idempotency_key_hash),
  foreign key (tenant_id, subscription_id) references subscriptions(tenant_id, id),
  foreign key (tenant_id, credit_grant_id) references credit_grants(tenant_id, id),
  foreign key (tenant_id, ledger_entry_id) references ledger_entries(tenant_id, id),
  foreign key (tenant_id, invoice_id) references invoices(tenant_id, id),
  foreign key (tenant_id, order_id) references payment_orders(tenant_id, id),
  foreign key (tenant_id, audit_id) references audit_logs(tenant_id, id),
  check (event_type in ('create', 'trial_end', 'activate', 'renew', 'pause', 'resume', 'cancel', 'prorate', 'payment_failed', 'dunning', 'expire', 'terminate', 'refusal', 'reconciliation')),
  check (event_status in ('scheduled', 'applied', 'replayed', 'refused', 'matched')),
  check (length(btrim(idempotency_key_hash)) > 0),
  check (refusal_code is null or length(btrim(refusal_code)) > 0),
  check (jsonb_typeof(request_summary) = 'object'),
  check (jsonb_typeof(metadata) = 'object')
);

create index if not exists idx_subscription_events_subscription_effective
  on subscription_events_or_schedules(tenant_id, subscription_id, effective_at desc);
