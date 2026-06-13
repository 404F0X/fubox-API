create table if not exists enterprise_sales_activities (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  activity_type text not null,
  status text not null default 'open',
  summary text not null,
  owner text null,
  next_action text null,
  outcome text null,
  occurred_at timestamptz not null default now(),
  due_at timestamptz null,
  actor_session_id uuid null,
  audit_id uuid null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (tenant_id) references tenants(id),
  foreign key (tenant_id, audit_id) references audit_logs(tenant_id, id),
  check (activity_type in ('call', 'email', 'demo', 'followup', 'meeting', 'note', 'task', 'stage-change', 'renewal-review')),
  check (status in ('open', 'planned', 'completed', 'cancelled')),
  check (outcome is null or outcome in ('connected', 'left-message', 'no-response', 'interested', 'not-interested', 'demo-scheduled', 'demo-completed', 'followup-required', 'blocked', 'closed-won', 'closed-lost')),
  check (length(btrim(summary)) > 0),
  check (jsonb_typeof(metadata) = 'object')
);

create index if not exists idx_enterprise_sales_activities_tenant_time
  on enterprise_sales_activities(tenant_id, occurred_at desc, created_at desc);

create index if not exists idx_enterprise_sales_activities_tenant_status_due
  on enterprise_sales_activities(tenant_id, status, due_at asc)
  where status in ('open', 'planned');
