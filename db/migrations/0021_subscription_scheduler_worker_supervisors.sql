create table if not exists subscription_scheduler_worker_supervisors (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  worker_id text not null,
  worker_status text not null default 'idle',
  lease_heartbeat_at timestamptz null,
  last_run_at timestamptz null,
  next_run_at timestamptz null,
  processed_count bigint not null default 0,
  skipped_count bigint not null default 0,
  blocked_count bigint not null default 0,
  last_mode text null,
  last_event_status_filter text[] not null default array[]::text[],
  last_event_type_filter text[] not null default array[]::text[],
  last_run_summary jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, worker_id),
  check (length(btrim(worker_id)) > 0),
  check (worker_status in ('idle', 'running', 'blocked', 'error')),
  check (processed_count >= 0),
  check (skipped_count >= 0),
  check (blocked_count >= 0),
  check (jsonb_typeof(last_run_summary) = 'object'),
  check (jsonb_typeof(metadata) = 'object')
);

create index if not exists idx_subscription_scheduler_worker_supervisors_tenant_updated
  on subscription_scheduler_worker_supervisors(tenant_id, updated_at desc);
