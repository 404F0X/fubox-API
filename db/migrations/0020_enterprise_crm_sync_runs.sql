create table if not exists enterprise_crm_sync_runs (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  adapter_id uuid null,
  provider text not null,
  direction text not null,
  status text not null,
  started_at timestamptz not null default now(),
  completed_at timestamptz null,
  imported_activity_count integer not null default 0,
  refused_reason text null,
  sync_marker text null,
  actor_session_id uuid null,
  audit_id uuid null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (tenant_id) references tenants(id),
  foreign key (adapter_id) references enterprise_external_crm_adapters(id),
  foreign key (tenant_id, audit_id) references audit_logs(tenant_id, id),
  check (provider in ('hubspot', 'salesforce', 'pipedrive', 'zoho', 'custom-http', 'not-configured')),
  check (direction in ('read-only', 'write-only', 'bidirectional', 'webhook-only')),
  check (status in ('running', 'completed', 'refused')),
  check (imported_activity_count >= 0),
  check (refused_reason is null or length(btrim(refused_reason)) > 0),
  check (sync_marker is null or length(btrim(sync_marker)) > 0),
  check (jsonb_typeof(metadata) = 'object')
);

create index if not exists idx_enterprise_crm_sync_runs_tenant_created
  on enterprise_crm_sync_runs(tenant_id, created_at desc);

create index if not exists idx_enterprise_crm_sync_runs_adapter_status
  on enterprise_crm_sync_runs(adapter_id, status, created_at desc);
