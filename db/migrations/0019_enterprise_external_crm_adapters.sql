create table if not exists enterprise_external_crm_adapters (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  provider text not null,
  status text not null default 'disabled',
  secret_ref_present boolean not null default false,
  webhook_ref_present boolean not null default false,
  sync_direction text not null default 'read-only',
  last_sync_marker text null,
  actor_session_id uuid null,
  audit_id uuid null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  disabled_at timestamptz null,
  foreign key (tenant_id) references tenants(id),
  foreign key (tenant_id, audit_id) references audit_logs(tenant_id, id),
  unique (tenant_id),
  check (provider in ('hubspot', 'salesforce', 'pipedrive', 'zoho', 'custom-http')),
  check (status in ('enabled', 'disabled')),
  check (sync_direction in ('read-only', 'write-only', 'bidirectional', 'webhook-only')),
  check (last_sync_marker is null or length(btrim(last_sync_marker)) > 0),
  check (jsonb_typeof(metadata) = 'object')
);

create index if not exists idx_enterprise_external_crm_adapters_tenant_status
  on enterprise_external_crm_adapters(tenant_id, status, updated_at desc);
