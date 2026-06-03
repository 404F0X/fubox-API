-- E1/E2/E3/E10 integrity hardening.
-- Keep this migration idempotent and compatible with existing rows.

create table if not exists user_sessions (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  user_id uuid not null,
  token_lookup_prefix text not null,
  token_hash text not null,
  status text not null default 'active',
  ip_address inet null,
  user_agent text null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz null,
  expires_at timestamptz not null,
  revoked_at timestamptz null,
  unique (tenant_id, id),
  foreign key (tenant_id, user_id) references users(tenant_id, id),
  check (token_lookup_prefix ~ '^sess_[0-9a-fA-F]{15}$'),
  check (token_hash ~ '^[0-9a-f]{64}$'),
  check (status in ('active', 'revoked', 'expired')),
  check (expires_at > created_at),
  check (last_seen_at is null or last_seen_at >= created_at),
  check (revoked_at is null or revoked_at >= created_at),
  check (jsonb_typeof(metadata) = 'object')
);

create unique index if not exists uq_user_sessions_token_hash
  on user_sessions(token_hash);

create index if not exists idx_user_sessions_lookup_active
  on user_sessions(token_lookup_prefix, status, expires_at)
  where status = 'active';

create index if not exists idx_user_sessions_user_status
  on user_sessions(tenant_id, user_id, status, expires_at desc);

create index if not exists idx_team_members_user_role
  on team_members(tenant_id, user_id, role, team_id);

create index if not exists idx_team_members_team_role
  on team_members(tenant_id, team_id, role, user_id);

create index if not exists idx_project_members_user_role
  on project_members(tenant_id, user_id, role, project_id);

create index if not exists idx_project_members_project_role
  on project_members(tenant_id, project_id, role, user_id);

create index if not exists idx_api_key_profiles_active_lookup
  on api_key_profiles(tenant_id, project_id, name, status)
  where deleted_at is null;

create index if not exists idx_api_key_profiles_allowed_models
  on api_key_profiles using gin(allowed_models);

create index if not exists idx_api_key_profiles_allowed_channel_tags
  on api_key_profiles using gin(allowed_channel_tags);

create index if not exists idx_api_key_profiles_blocked_providers
  on api_key_profiles using gin(blocked_provider_ids);

create index if not exists idx_virtual_key_profile_bindings_profile_default
  on virtual_key_profile_bindings(tenant_id, profile_id, is_default, virtual_key_id);

create index if not exists idx_virtual_keys_default_profile
  on virtual_keys(tenant_id, project_id, default_profile_id, status)
  where default_profile_id is not null and deleted_at is null;

create index if not exists idx_channels_health_routing
  on channels(tenant_id, status, priority, health_score desc, weight desc)
  where deleted_at is null and status in ('enabled', 'degraded');

create index if not exists idx_channels_probe_policy
  on channels using gin(probe_policy jsonb_path_ops);

create index if not exists idx_channels_tags_ops
  on channels using gin(tags)
  where deleted_at is null;

create index if not exists idx_provider_keys_health_pool
  on provider_keys(tenant_id, channel_id, status, health_score desc, cooldown_until)
  where deleted_at is null;

create index if not exists idx_provider_keys_error_health
  on provider_keys(tenant_id, last_error_code, status, cooldown_until)
  where last_error_code is not null;

create index if not exists idx_request_logs_profile_time
  on request_logs(tenant_id, api_key_profile_id, created_at desc)
  where api_key_profile_id is not null;

create index if not exists idx_request_logs_client_request_time
  on request_logs(tenant_id, client_request_id, created_at desc)
  where client_request_id is not null;

create index if not exists idx_request_logs_route_snapshot
  on request_logs using gin(route_decision_snapshot jsonb_path_ops);

create index if not exists idx_provider_attempts_provider_status_time
  on provider_attempts(tenant_id, provider_id, status, started_at desc)
  where provider_id is not null;

create index if not exists idx_audit_logs_request_time
  on audit_logs(tenant_id, request_id, created_at desc)
  where request_id is not null;

create index if not exists idx_audit_logs_action_time
  on audit_logs(tenant_id, action, created_at desc);

create index if not exists idx_audit_logs_resource_tenant_time
  on audit_logs(tenant_id, resource_tenant_id, resource_type, created_at desc)
  where resource_tenant_id is not null;

do $$
declare
  old_constraint record;
begin
  if to_regclass('public.request_logs') is not null then
    for old_constraint in
      select c.conname
      from pg_constraint c
      where c.conrelid = to_regclass('public.request_logs')
        and c.contype = 'c'
        and c.conname <> 'chk_request_logs_stream_end_reason_current'
        and (
          position('provider_eof' in pg_get_constraintdef(c.oid)) > 0
          or position('missing_terminal' in pg_get_constraintdef(c.oid)) > 0
        )
    loop
      execute format('alter table public.request_logs drop constraint %I', old_constraint.conname);
    end loop;

    if not exists (
      select 1
      from pg_constraint
      where conrelid = to_regclass('public.request_logs')
        and conname = 'chk_request_logs_stream_end_reason_current'
    ) then
      alter table public.request_logs
        add constraint chk_request_logs_stream_end_reason_current
        check (
          stream_end_reason is null
          or stream_end_reason in (
            'completed',
            'client_cancel',
            'upstream_eof',
            'upstream_error',
            'parser_error',
            'timeout',
            'gateway_abort'
          )
        ) not valid;
    end if;
  end if;
end $$;

do $$
begin
  if to_regclass('public.audit_logs') is not null
     and not exists (
       select 1
       from pg_constraint
       where conrelid = to_regclass('public.audit_logs')
         and conname = 'fk_audit_logs_resource_tenant'
     ) then
    alter table public.audit_logs
      add constraint fk_audit_logs_resource_tenant
      foreign key (resource_tenant_id) references public.tenants(id) not valid;
  end if;
end $$;

do $$
begin
  if to_regclass('public.provider_keys') is not null
     and not exists (
       select 1
       from pg_constraint
       where conrelid = to_regclass('public.provider_keys')
         and conname = 'chk_provider_keys_cooldown_until_required'
     ) then
    alter table public.provider_keys
      add constraint chk_provider_keys_cooldown_until_required
      check (status <> 'cooldown' or cooldown_until is not null) not valid;
  end if;
end $$;

do $$
begin
  if to_regclass('public.provider_keys') is not null
     and not exists (
       select 1
       from pg_constraint
       where conrelid = to_regclass('public.provider_keys')
         and conname = 'chk_provider_keys_last_error_code_not_blank'
     ) then
    alter table public.provider_keys
      add constraint chk_provider_keys_last_error_code_not_blank
      check (last_error_code is null or length(btrim(last_error_code)) > 0) not valid;
  end if;
end $$;

do $$
begin
  if to_regclass('public.channels') is not null
     and not exists (
       select 1
       from pg_constraint
       where conrelid = to_regclass('public.channels')
         and conname = 'chk_channels_region_not_blank'
     ) then
    alter table public.channels
      add constraint chk_channels_region_not_blank
      check (region is null or length(btrim(region)) > 0) not valid;
  end if;
end $$;

do $$
begin
  if to_regclass('public.request_logs') is not null
     and not exists (
       select 1
       from pg_constraint
       where conrelid = to_regclass('public.request_logs')
         and conname = 'chk_request_logs_trace_ids_not_blank'
     ) then
    alter table public.request_logs
      add constraint chk_request_logs_trace_ids_not_blank
      check (
        (trace_id is null or length(btrim(trace_id)) > 0)
        and (thread_id is null or length(btrim(thread_id)) > 0)
        and (client_request_id is null or length(btrim(client_request_id)) > 0)
      ) not valid;
  end if;
end $$;

do $$
begin
  if to_regclass('public.request_logs') is not null
     and not exists (
       select 1
       from pg_constraint
       where conrelid = to_regclass('public.request_logs')
         and conname = 'chk_request_logs_payload_ref_when_stored'
     ) then
    alter table public.request_logs
      add constraint chk_request_logs_payload_ref_when_stored
      check (
        payload_stored = false
        or (payload_object_ref is not null and length(btrim(payload_object_ref)) > 0)
      ) not valid;
  end if;
end $$;
