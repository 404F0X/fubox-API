create table if not exists opening_balance_imports (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  project_id uuid null,
  wallet_id uuid not null,
  currency text not null,
  opening_amount numeric(20, 8) not null,
  external_source text not null,
  external_reference_id text not null,
  effective_at timestamptz not null,
  reason text not null,
  actor_id uuid not null,
  actor_type text not null,
  idempotency_key text not null,
  status text not null,
  ledger_entry_id uuid null,
  admin_adjustment_entry_id uuid null,
  audit_id uuid null,
  request_summary jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, idempotency_key),
  unique (tenant_id, external_source, external_reference_id),
  foreign key (tenant_id, project_id) references projects(tenant_id, id),
  foreign key (tenant_id, wallet_id) references wallets(tenant_id, id),
  foreign key (tenant_id, ledger_entry_id) references ledger_entries(tenant_id, id),
  foreign key (tenant_id, admin_adjustment_entry_id) references ledger_entries(tenant_id, id),
  foreign key (tenant_id, audit_id) references audit_logs(tenant_id, id),
  check (currency ~ '^[A-Z][A-Z0-9_]{2,31}$'),
  check (opening_amount > 0),
  check (length(btrim(external_source)) > 0),
  check (length(btrim(external_reference_id)) > 0),
  check (length(btrim(reason)) > 0),
  check (length(btrim(actor_type)) > 0),
  check (length(btrim(idempotency_key)) > 0),
  check (status in ('imported', 'replayed', 'refused')),
  check (jsonb_typeof(request_summary) = 'object'),
  check (jsonb_typeof(metadata) = 'object')
);

create index if not exists idx_opening_balance_imports_tenant_created
  on opening_balance_imports(tenant_id, created_at desc);

create index if not exists idx_opening_balance_imports_wallet_status_created
  on opening_balance_imports(tenant_id, wallet_id, status, created_at desc);

create index if not exists idx_opening_balance_imports_project_created
  on opening_balance_imports(tenant_id, project_id, created_at desc)
  where project_id is not null;

create index if not exists idx_opening_balance_imports_ledger_entry
  on opening_balance_imports(tenant_id, ledger_entry_id)
  where ledger_entry_id is not null;

create index if not exists idx_opening_balance_imports_audit
  on opening_balance_imports(tenant_id, audit_id)
  where audit_id is not null;
