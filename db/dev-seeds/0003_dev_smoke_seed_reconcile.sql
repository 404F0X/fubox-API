-- Development/smoke seed reconciliation only.
-- This file is safe to rerun against an existing compose database.

alter table provider_attempts add column if not exists upstream_model text null;

-- Keep the deterministic default tenant/project/profile path present for local smoke tests.
update tenants
set name = 'Default Tenant',
    slug = 'default',
    status = 'active',
    deleted_at = null,
    metadata = metadata || '{"dev_seed": true}'::jsonb,
    updated_at = now()
where id = '00000000-0000-0000-0000-000000000001';

insert into tenants (id, name, slug, status, metadata)
select
  '00000000-0000-0000-0000-000000000001',
  'Default Tenant',
  'default',
  'active',
  '{"dev_seed": true}'::jsonb
where not exists (
  select 1 from tenants
  where id = '00000000-0000-0000-0000-000000000001'
)
on conflict do nothing;

update teams
set name = 'Default Team',
    status = 'active',
    deleted_at = null,
    metadata = metadata || '{"dev_seed": true}'::jsonb,
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and id = '00000000-0000-0000-0000-000000000010';

insert into teams (id, tenant_id, name, status, metadata)
select
  '00000000-0000-0000-0000-000000000010',
  '00000000-0000-0000-0000-000000000001',
  'Default Team',
  'active',
  '{"dev_seed": true}'::jsonb
where not exists (
  select 1 from teams
  where tenant_id = '00000000-0000-0000-0000-000000000001'
    and id = '00000000-0000-0000-0000-000000000010'
)
on conflict do nothing;

update projects
set team_id = coalesce(
      (
        select id from teams
        where tenant_id = '00000000-0000-0000-0000-000000000001'
          and name = 'Default Team'
        order by (id = '00000000-0000-0000-0000-000000000010'::uuid) desc
        limit 1
      ),
      team_id
    ),
    name = 'Default Project',
    status = 'active',
    deleted_at = null,
    metadata = metadata || '{"dev_seed": true}'::jsonb,
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and id = '00000000-0000-0000-0000-000000000020';

insert into projects (id, tenant_id, team_id, name, status, metadata)
select
  '00000000-0000-0000-0000-000000000020',
  '00000000-0000-0000-0000-000000000001',
  (
    select id from teams
    where tenant_id = '00000000-0000-0000-0000-000000000001'
      and name = 'Default Team'
    order by (id = '00000000-0000-0000-0000-000000000010'::uuid) desc
    limit 1
  ),
  'Default Project',
  'active',
  '{"dev_seed": true}'::jsonb
where not exists (
  select 1 from projects
  where tenant_id = '00000000-0000-0000-0000-000000000001'
    and id = '00000000-0000-0000-0000-000000000020'
)
on conflict do nothing;

update team_members
set role = 'owner'
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and team_id = '00000000-0000-0000-0000-000000000010'
  and user_id = '00000000-0000-0000-0000-0000000000a1';

insert into team_members (tenant_id, team_id, user_id, role)
select
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000010',
  '00000000-0000-0000-0000-0000000000a1',
  'owner'
where exists (
  select 1
  from teams
  where tenant_id = '00000000-0000-0000-0000-000000000001'
    and id = '00000000-0000-0000-0000-000000000010'
)
and exists (
  select 1
  from users
  where tenant_id = '00000000-0000-0000-0000-000000000001'
    and id = '00000000-0000-0000-0000-0000000000a1'
    and status = 'active'
    and deleted_at is null
)
and not exists (
  select 1
  from team_members
  where tenant_id = '00000000-0000-0000-0000-000000000001'
    and team_id = '00000000-0000-0000-0000-000000000010'
    and user_id = '00000000-0000-0000-0000-0000000000a1'
);

update project_members
set role = 'owner'
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and project_id = '00000000-0000-0000-0000-000000000020'
  and user_id = '00000000-0000-0000-0000-0000000000a1';

insert into project_members (tenant_id, project_id, user_id, role)
select
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000020',
  '00000000-0000-0000-0000-0000000000a1',
  'owner'
where exists (
  select 1
  from projects
  where tenant_id = '00000000-0000-0000-0000-000000000001'
    and id = '00000000-0000-0000-0000-000000000020'
)
and exists (
  select 1
  from users
  where tenant_id = '00000000-0000-0000-0000-000000000001'
    and id = '00000000-0000-0000-0000-0000000000a1'
    and status = 'active'
    and deleted_at is null
)
and not exists (
  select 1
  from project_members
  where tenant_id = '00000000-0000-0000-0000-000000000001'
    and project_id = '00000000-0000-0000-0000-000000000020'
    and user_id = '00000000-0000-0000-0000-0000000000a1'
);

update payload_policies
set name = 'Default Metadata Only',
    mode = 'metadata_only',
    status = 'active',
    config = config || '{"dev_seed": true}'::jsonb,
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and id = '00000000-0000-0000-0000-000000000030';

insert into payload_policies (id, tenant_id, name, mode, status, config)
select
  '00000000-0000-0000-0000-000000000030',
  '00000000-0000-0000-0000-000000000001',
  'Default Metadata Only',
  'metadata_only',
  'active',
  '{"dev_seed": true}'::jsonb
where not exists (
  select 1 from payload_policies
  where tenant_id = '00000000-0000-0000-0000-000000000001'
    and id = '00000000-0000-0000-0000-000000000030'
)
on conflict do nothing;

-- The strong-auth smoke key resolves through this default profile.
update api_key_profiles
set name = 'dev-seed-duplicate-' || id::text,
    status = 'deleted',
    deleted_at = coalesce(deleted_at, now()),
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and name = 'Default OpenAI Compatible'
  and id <> '00000000-0000-0000-0000-000000000040';

update api_key_profiles
set project_id = coalesce(
      (
        select id from projects
        where tenant_id = '00000000-0000-0000-0000-000000000001'
          and name = 'Default Project'
        order by (id = '00000000-0000-0000-0000-000000000020'::uuid) desc
        limit 1
      ),
      project_id
    ),
    name = 'Default OpenAI Compatible',
    inbound_protocol = 'openai',
    default_protocol_mode = 'openai_compatible',
    model_aliases = '{}'::jsonb,
    allowed_models = '["mock-gpt-4o-mini"]'::jsonb,
    denied_models = '[]'::jsonb,
    allowed_channel_tags = '["dev", "mock", "openai-compatible"]'::jsonb,
    blocked_provider_ids = '[]'::jsonb,
    trace_header_rules = '{}'::jsonb,
    request_overrides = '[]'::jsonb,
    payload_policy_id = (
      select id from payload_policies
      where tenant_id = '00000000-0000-0000-0000-000000000001'
        and name = 'Default Metadata Only'
      order by (id = '00000000-0000-0000-0000-000000000030'::uuid) desc
      limit 1
    ),
    status = 'active',
    deleted_at = null,
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and (
    id = '00000000-0000-0000-0000-000000000040'
    or (
      project_id = (
        select id from projects
        where tenant_id = '00000000-0000-0000-0000-000000000001'
          and name = 'Default Project'
        order by (id = '00000000-0000-0000-0000-000000000020'::uuid) desc
        limit 1
      )
      and name = 'Default OpenAI Compatible'
    )
  );

insert into api_key_profiles (
  id,
  tenant_id,
  project_id,
  name,
  inbound_protocol,
  default_protocol_mode,
  model_aliases,
  allowed_models,
  denied_models,
  allowed_channel_tags,
  blocked_provider_ids,
  trace_header_rules,
  request_overrides,
  payload_policy_id,
  status
)
select
  '00000000-0000-0000-0000-000000000040',
  '00000000-0000-0000-0000-000000000001',
  (
    select id from projects
    where tenant_id = '00000000-0000-0000-0000-000000000001'
      and name = 'Default Project'
    order by (id = '00000000-0000-0000-0000-000000000020'::uuid) desc
    limit 1
  ),
  'Default OpenAI Compatible',
  'openai',
  'openai_compatible',
  '{}'::jsonb,
  '["mock-gpt-4o-mini"]'::jsonb,
  '[]'::jsonb,
  '["dev", "mock", "openai-compatible"]'::jsonb,
  '[]'::jsonb,
  '{}'::jsonb,
  '[]'::jsonb,
  (
    select id from payload_policies
    where tenant_id = '00000000-0000-0000-0000-000000000001'
      and name = 'Default Metadata Only'
    order by (id = '00000000-0000-0000-0000-000000000030'::uuid) desc
    limit 1
  ),
  'active'
where not exists (
  select 1 from api_key_profiles
  where tenant_id = '00000000-0000-0000-0000-000000000001'
    and id = '00000000-0000-0000-0000-000000000040'
)
on conflict do nothing;

-- Public canonical model plus mock provider/channel/model association.
update providers
set code = 'dev-seed-duplicate-' || id::text,
    status = 'deleted',
    deleted_at = coalesce(deleted_at, now()),
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and code = 'mock-openai'
  and id <> '00000000-0000-0000-0000-000000000060';

update providers
set code = 'mock-openai',
    name = 'Mock OpenAI Compatible Provider',
    status = 'enabled',
    deleted_at = null,
    metadata = metadata || '{"dev_seed": true}'::jsonb,
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and (id = '00000000-0000-0000-0000-000000000060' or code = 'mock-openai');

insert into providers (id, tenant_id, code, name, status, metadata)
select
  '00000000-0000-0000-0000-000000000060',
  '00000000-0000-0000-0000-000000000001',
  'mock-openai',
  'Mock OpenAI Compatible Provider',
  'enabled',
  '{"dev_seed": true}'::jsonb
where not exists (
  select 1 from providers
  where tenant_id = '00000000-0000-0000-0000-000000000001'
    and (id = '00000000-0000-0000-0000-000000000060' or code = 'mock-openai')
)
on conflict do nothing;

update channels
set name = 'dev-seed-duplicate-' || id::text,
    status = 'deleted',
    deleted_at = coalesce(deleted_at, now()),
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and name = 'mock-openai-default'
  and id <> '00000000-0000-0000-0000-000000000070';

update channels
set provider_id = (
      select id from providers
      where tenant_id = '00000000-0000-0000-0000-000000000001'
        and code = 'mock-openai'
      order by (id = '00000000-0000-0000-0000-000000000060'::uuid) desc
      limit 1
    ),
    name = 'mock-openai-default',
    endpoint = 'http://mock-provider:18080',
    protocol_mode = 'openai_compatible',
    status = 'enabled',
    region = null,
    priority = 10,
    weight = 100,
    tags = '["dev", "mock", "openai-compatible"]'::jsonb,
    model_mappings = '{"mock-gpt-4o-mini": "mock-gpt-4o-mini"}'::jsonb,
    timeout_policy = '{"connect_timeout_ms": 3000, "request_timeout_ms": 30000}'::jsonb,
    probe_policy = '{"healthz_path": "/healthz"}'::jsonb,
    health_score = 1.0,
    deleted_at = null,
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and (
    id = '00000000-0000-0000-0000-000000000070'
    or (
      provider_id = (
        select id from providers
        where tenant_id = '00000000-0000-0000-0000-000000000001'
          and code = 'mock-openai'
        order by (id = '00000000-0000-0000-0000-000000000060'::uuid) desc
        limit 1
      )
      and name = 'mock-openai-default'
    )
  );

insert into channels (
  id,
  tenant_id,
  provider_id,
  name,
  endpoint,
  protocol_mode,
  status,
  priority,
  weight,
  tags,
  model_mappings,
  timeout_policy,
  probe_policy,
  health_score
)
select
  '00000000-0000-0000-0000-000000000070',
  '00000000-0000-0000-0000-000000000001',
  (
    select id from providers
    where tenant_id = '00000000-0000-0000-0000-000000000001'
      and code = 'mock-openai'
    order by (id = '00000000-0000-0000-0000-000000000060'::uuid) desc
    limit 1
  ),
  'mock-openai-default',
  'http://mock-provider:18080',
  'openai_compatible',
  'enabled',
  10,
  100,
  '["dev", "mock", "openai-compatible"]'::jsonb,
  '{"mock-gpt-4o-mini": "mock-gpt-4o-mini"}'::jsonb,
  '{"connect_timeout_ms": 3000, "request_timeout_ms": 30000}'::jsonb,
  '{"healthz_path": "/healthz"}'::jsonb,
  1.0
where not exists (
  select 1 from channels
  where tenant_id = '00000000-0000-0000-0000-000000000001'
    and id = '00000000-0000-0000-0000-000000000070'
)
on conflict do nothing;

update provider_keys
set key_alias = 'dev-seed-duplicate-' || id::text,
    secret_fingerprint = case
      when secret_fingerprint = 'dev-mock-provider-key-fingerprint'
      then 'dev-seed-duplicate-' || id::text
      else secret_fingerprint
    end,
    status = 'deleted',
    deleted_at = coalesce(deleted_at, now()),
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and id <> '00000000-0000-0000-0000-000000000075'
  and (
    key_alias = 'mock-dev-key'
    or secret_fingerprint = 'dev-mock-provider-key-fingerprint'
  );

update provider_keys
set channel_id = (
      select id from channels
      where tenant_id = '00000000-0000-0000-0000-000000000001'
        and name = 'mock-openai-default'
      order by (id = '00000000-0000-0000-0000-000000000070'::uuid) desc
      limit 1
    ),
    key_alias = 'mock-dev-key',
    encrypted_secret = '{"algorithm":"aes-256-gcm","ciphertext":"fc31dbd39aec2a2f5879fa15e7d95c5ed2af95fab8604709f3f6788eb2761c70df6f734515fa127f","master_key_id":"dev-seed-v1","nonce":"3a648880a0c00417ad5c0bd6","version":1}',
    secret_fingerprint = 'hmac-sha256-v1:850e131450a7c691b8300375967287a7532bdab7d922dbc2db974f5a0f1bea2a',
    status = 'enabled',
    health_score = 1.0,
    cooldown_until = null,
    last_error_code = null,
    metadata = metadata || '{"dev_seed": true, "sealed_placeholder": true}'::jsonb,
    deleted_at = null,
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and (
    id = '00000000-0000-0000-0000-000000000075'
    or (
      channel_id = (
        select id from channels
        where tenant_id = '00000000-0000-0000-0000-000000000001'
          and name = 'mock-openai-default'
        order by (id = '00000000-0000-0000-0000-000000000070'::uuid) desc
        limit 1
      )
      and key_alias = 'mock-dev-key'
    )
  );

insert into provider_keys (
  id,
  tenant_id,
  channel_id,
  key_alias,
  encrypted_secret,
  secret_fingerprint,
  status,
  health_score,
  metadata
)
select
  '00000000-0000-0000-0000-000000000075',
  '00000000-0000-0000-0000-000000000001',
  (
    select id from channels
    where tenant_id = '00000000-0000-0000-0000-000000000001'
      and name = 'mock-openai-default'
    order by (id = '00000000-0000-0000-0000-000000000070'::uuid) desc
    limit 1
  ),
  'mock-dev-key',
  '{"algorithm":"aes-256-gcm","ciphertext":"fc31dbd39aec2a2f5879fa15e7d95c5ed2af95fab8604709f3f6788eb2761c70df6f734515fa127f","master_key_id":"dev-seed-v1","nonce":"3a648880a0c00417ad5c0bd6","version":1}',
  'hmac-sha256-v1:850e131450a7c691b8300375967287a7532bdab7d922dbc2db974f5a0f1bea2a',
  'enabled',
  1.0,
  '{"dev_seed": true, "sealed_placeholder": true}'::jsonb
where not exists (
  select 1 from provider_keys
  where tenant_id = '00000000-0000-0000-0000-000000000001'
    and id = '00000000-0000-0000-0000-000000000075'
)
on conflict do nothing;

update canonical_models
set model_key = 'dev-seed-duplicate-' || id::text,
    status = 'deleted',
    deleted_at = coalesce(deleted_at, now()),
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and model_key in ('gpt-4o-mini', 'mock-gpt-4o-mini')
  and id <> '00000000-0000-0000-0000-000000000080';

update canonical_models
set model_key = 'mock-gpt-4o-mini',
    display_name = 'GPT-4o Mini Dev Mock',
    family = 'chat',
    capabilities = '{"chat": true, "mock": true, "owned_by": "mock-openai"}'::jsonb,
    context_length = 128000,
    max_output_tokens = 16384,
    supports_stream = true,
    supports_tools = true,
    supports_vision = false,
    supports_audio = false,
    supports_reasoning = false,
    visibility = 'public',
    status = 'active',
    deleted_at = null,
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and (id = '00000000-0000-0000-0000-000000000080' or model_key in ('gpt-4o-mini', 'mock-gpt-4o-mini'));

insert into canonical_models (
  id,
  tenant_id,
  model_key,
  display_name,
  family,
  capabilities,
  context_length,
  max_output_tokens,
  supports_stream,
  supports_tools,
  supports_vision,
  supports_audio,
  supports_reasoning,
  visibility,
  status
)
select
  '00000000-0000-0000-0000-000000000080',
  '00000000-0000-0000-0000-000000000001',
  'mock-gpt-4o-mini',
  'GPT-4o Mini Dev Mock',
  'chat',
  '{"chat": true, "mock": true, "owned_by": "mock-openai"}'::jsonb,
  128000,
  16384,
  true,
  true,
  false,
  false,
  false,
  'public',
  'active'
where not exists (
  select 1 from canonical_models
  where tenant_id = '00000000-0000-0000-0000-000000000001'
    and (id = '00000000-0000-0000-0000-000000000080' or model_key in ('gpt-4o-mini', 'mock-gpt-4o-mini'))
  )
on conflict do nothing;

update model_associations
set status = 'deleted',
    deleted_at = coalesce(deleted_at, now()),
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and id <> '00000000-0000-0000-0000-000000000090'
  and association_type = 'explicit_channel'
  and coalesce(upstream_model_name, '') in ('gpt-4o-mini', 'mock-gpt-4o-mini')
  and canonical_model_id = (
    select id from canonical_models
    where tenant_id = '00000000-0000-0000-0000-000000000001'
      and model_key = 'mock-gpt-4o-mini'
    order by (id = '00000000-0000-0000-0000-000000000080'::uuid) desc
    limit 1
  )
  and channel_id = (
    select id from channels
    where tenant_id = '00000000-0000-0000-0000-000000000001'
      and name = 'mock-openai-default'
    order by (id = '00000000-0000-0000-0000-000000000070'::uuid) desc
    limit 1
  );

update model_associations
set canonical_model_id = (
      select id from canonical_models
      where tenant_id = '00000000-0000-0000-0000-000000000001'
        and model_key = 'mock-gpt-4o-mini'
      order by (id = '00000000-0000-0000-0000-000000000080'::uuid) desc
      limit 1
    ),
    association_type = 'explicit_channel',
    channel_id = (
      select id from channels
      where tenant_id = '00000000-0000-0000-0000-000000000001'
        and name = 'mock-openai-default'
      order by (id = '00000000-0000-0000-0000-000000000070'::uuid) desc
      limit 1
    ),
    channel_tag = null,
    model_pattern = null,
    upstream_model_name = 'mock-gpt-4o-mini',
    priority = 10,
    conditions = '{}'::jsonb,
    fallback_allowed = true,
    canary_percent = 100,
    status = 'enabled',
    deleted_at = null,
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and (
    id = '00000000-0000-0000-0000-000000000090'
    or (
      canonical_model_id = (
        select id from canonical_models
        where tenant_id = '00000000-0000-0000-0000-000000000001'
          and model_key = 'mock-gpt-4o-mini'
        order by (id = '00000000-0000-0000-0000-000000000080'::uuid) desc
        limit 1
      )
      and channel_id = (
        select id from channels
        where tenant_id = '00000000-0000-0000-0000-000000000001'
          and name = 'mock-openai-default'
        order by (id = '00000000-0000-0000-0000-000000000070'::uuid) desc
        limit 1
      )
      and association_type = 'explicit_channel'
      and coalesce(upstream_model_name, '') in ('gpt-4o-mini', 'mock-gpt-4o-mini')
    )
  );

insert into model_associations (
  id,
  tenant_id,
  canonical_model_id,
  association_type,
  channel_id,
  channel_tag,
  model_pattern,
  upstream_model_name,
  priority,
  conditions,
  fallback_allowed,
  canary_percent,
  status
)
select
  '00000000-0000-0000-0000-000000000090',
  '00000000-0000-0000-0000-000000000001',
  (
    select id from canonical_models
    where tenant_id = '00000000-0000-0000-0000-000000000001'
      and model_key = 'mock-gpt-4o-mini'
    order by (id = '00000000-0000-0000-0000-000000000080'::uuid) desc
    limit 1
  ),
  'explicit_channel',
  (
    select id from channels
    where tenant_id = '00000000-0000-0000-0000-000000000001'
      and name = 'mock-openai-default'
    order by (id = '00000000-0000-0000-0000-000000000070'::uuid) desc
    limit 1
  ),
  null,
  null,
  'mock-gpt-4o-mini',
  10,
  '{}'::jsonb,
  true,
  100,
  'enabled'
where not exists (
  select 1 from model_associations
  where tenant_id = '00000000-0000-0000-0000-000000000001'
    and id = '00000000-0000-0000-0000-000000000090'
)
on conflict do nothing;

-- Strong-auth smoke virtual key. Raw value: dev_test_key_123456789.
update virtual_keys
set key_prefix = 'dev-seed-duplicate-' || id::text,
    status = 'deleted',
    deleted_at = coalesce(deleted_at, now()),
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and key_prefix = 'dev_test_key'
  and id <> '00000000-0000-0000-0000-000000000050';

update virtual_keys
set project_id = (
      select id from projects
      where tenant_id = '00000000-0000-0000-0000-000000000001'
        and name = 'Default Project'
      order by (id = '00000000-0000-0000-0000-000000000020'::uuid) desc
      limit 1
    ),
    name = 'Dev Smoke Virtual Key',
    key_prefix = 'dev_test_key',
    secret_hash = '165c66ca7e0aff3d28b1aaca0126d4feefabc507d91a38fe4680d921540f8e83',
    status = 'active',
    default_profile_id = (
      select id from api_key_profiles
      where tenant_id = '00000000-0000-0000-0000-000000000001'
        and name = 'Default OpenAI Compatible'
      order by (id = '00000000-0000-0000-0000-000000000040'::uuid) desc
      limit 1
    ),
    expires_at = null,
    ip_allowlist = '[]'::jsonb,
    rate_limit_policy = '{}'::jsonb,
    budget_policy = '{}'::jsonb,
    metadata = metadata || '{"dev_seed": true, "smoke_key": true}'::jsonb,
    deleted_at = null,
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and (id = '00000000-0000-0000-0000-000000000050' or key_prefix = 'dev_test_key');

insert into virtual_keys (
  id,
  tenant_id,
  project_id,
  name,
  key_prefix,
  secret_hash,
  status,
  default_profile_id,
  expires_at,
  ip_allowlist,
  rate_limit_policy,
  budget_policy,
  metadata
)
select
  '00000000-0000-0000-0000-000000000050',
  '00000000-0000-0000-0000-000000000001',
  (
    select id from projects
    where tenant_id = '00000000-0000-0000-0000-000000000001'
      and name = 'Default Project'
    order by (id = '00000000-0000-0000-0000-000000000020'::uuid) desc
    limit 1
  ),
  'Dev Smoke Virtual Key',
  'dev_test_key',
  '165c66ca7e0aff3d28b1aaca0126d4feefabc507d91a38fe4680d921540f8e83',
  'active',
  (
    select id from api_key_profiles
    where tenant_id = '00000000-0000-0000-0000-000000000001'
      and name = 'Default OpenAI Compatible'
    order by (id = '00000000-0000-0000-0000-000000000040'::uuid) desc
    limit 1
  ),
  null,
  '[]'::jsonb,
  '{}'::jsonb,
  '{}'::jsonb,
  '{"dev_seed": true, "smoke_key": true}'::jsonb
where not exists (
  select 1 from virtual_keys
  where tenant_id = '00000000-0000-0000-0000-000000000001'
    and (id = '00000000-0000-0000-0000-000000000050' or key_prefix = 'dev_test_key')
)
on conflict do nothing;

update virtual_key_profile_bindings
set is_default = false
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and virtual_key_id = (
    select id from virtual_keys
    where tenant_id = '00000000-0000-0000-0000-000000000001'
      and key_prefix = 'dev_test_key'
    order by (id = '00000000-0000-0000-0000-000000000050'::uuid) desc
    limit 1
  )
  and profile_id <> (
    select id from api_key_profiles
    where tenant_id = '00000000-0000-0000-0000-000000000001'
      and name = 'Default OpenAI Compatible'
    order by (id = '00000000-0000-0000-0000-000000000040'::uuid) desc
    limit 1
  )
  and is_default = true;

insert into virtual_key_profile_bindings (
  tenant_id,
  project_id,
  virtual_key_id,
  profile_id,
  is_default
)
select
  '00000000-0000-0000-0000-000000000001',
  vk.project_id,
  vk.id,
  p.id,
  true
from virtual_keys vk
join api_key_profiles p
  on p.tenant_id = vk.tenant_id
 and p.project_id = vk.project_id
 and p.name = 'Default OpenAI Compatible'
where vk.tenant_id = '00000000-0000-0000-0000-000000000001'
  and vk.key_prefix = 'dev_test_key'
order by (vk.id = '00000000-0000-0000-0000-000000000050'::uuid) desc,
         (p.id = '00000000-0000-0000-0000-000000000040'::uuid) desc
limit 1
on conflict (tenant_id, virtual_key_id, profile_id) do update
set project_id = excluded.project_id,
    is_default = true;

-- Dedicated retry/fallback live strict profile and routes.
-- Each strict model has a first candidate endpoint pinned to one mock-provider
-- failure scenario and a second candidate pointing at the normal success path.
update api_key_profiles
set name = 'dev-seed-duplicate-' || id::text,
    status = 'deleted',
    deleted_at = coalesce(deleted_at, now()),
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and name = 'Fallback Live Strict Smoke'
  and id <> '00000000-0000-0000-0000-000000000041';

update api_key_profiles
set project_id = (
      select id from projects
      where tenant_id = '00000000-0000-0000-0000-000000000001'
        and name = 'Default Project'
      order by (id = '00000000-0000-0000-0000-000000000020'::uuid) desc
      limit 1
    ),
    name = 'Fallback Live Strict Smoke',
    inbound_protocol = 'openai',
    default_protocol_mode = 'openai_compatible',
    model_aliases = '{}'::jsonb,
    allowed_models = '[
      "mock-gpt-4o-mini-fallback-429",
      "mock-gpt-4o-mini-fallback-5xx",
      "mock-gpt-4o-mini-fallback-timeout",
      "mock-gpt-4o-mini-fallback-eof"
    ]'::jsonb,
    denied_models = '[]'::jsonb,
    allowed_channel_tags = '["fallback-live-strict"]'::jsonb,
    blocked_provider_ids = '[]'::jsonb,
    trace_header_rules = '{}'::jsonb,
    request_overrides = '[]'::jsonb,
    payload_policy_id = (
      select id from payload_policies
      where tenant_id = '00000000-0000-0000-0000-000000000001'
        and name = 'Default Metadata Only'
      order by (id = '00000000-0000-0000-0000-000000000030'::uuid) desc
      limit 1
    ),
    status = 'active',
    deleted_at = null,
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and (
    id = '00000000-0000-0000-0000-000000000041'
    or (
      project_id = (
        select id from projects
        where tenant_id = '00000000-0000-0000-0000-000000000001'
          and name = 'Default Project'
        order by (id = '00000000-0000-0000-0000-000000000020'::uuid) desc
        limit 1
      )
      and name = 'Fallback Live Strict Smoke'
    )
  );

insert into api_key_profiles (
  id,
  tenant_id,
  project_id,
  name,
  inbound_protocol,
  default_protocol_mode,
  model_aliases,
  allowed_models,
  denied_models,
  allowed_channel_tags,
  blocked_provider_ids,
  trace_header_rules,
  request_overrides,
  payload_policy_id,
  status
)
select
  '00000000-0000-0000-0000-000000000041',
  '00000000-0000-0000-0000-000000000001',
  (
    select id from projects
    where tenant_id = '00000000-0000-0000-0000-000000000001'
      and name = 'Default Project'
    order by (id = '00000000-0000-0000-0000-000000000020'::uuid) desc
    limit 1
  ),
  'Fallback Live Strict Smoke',
  'openai',
  'openai_compatible',
  '{}'::jsonb,
  '[
    "mock-gpt-4o-mini-fallback-429",
    "mock-gpt-4o-mini-fallback-5xx",
    "mock-gpt-4o-mini-fallback-timeout",
    "mock-gpt-4o-mini-fallback-eof"
  ]'::jsonb,
  '[]'::jsonb,
  '["fallback-live-strict"]'::jsonb,
  '[]'::jsonb,
  '{}'::jsonb,
  '[]'::jsonb,
  (
    select id from payload_policies
    where tenant_id = '00000000-0000-0000-0000-000000000001'
      and name = 'Default Metadata Only'
    order by (id = '00000000-0000-0000-0000-000000000030'::uuid) desc
    limit 1
  ),
  'active'
where not exists (
  select 1 from api_key_profiles
  where tenant_id = '00000000-0000-0000-0000-000000000001'
    and (
      id = '00000000-0000-0000-0000-000000000041'
      or (
        project_id = (
          select id from projects
          where tenant_id = '00000000-0000-0000-0000-000000000001'
            and name = 'Default Project'
          order by (id = '00000000-0000-0000-0000-000000000020'::uuid) desc
          limit 1
        )
        and name = 'Fallback Live Strict Smoke'
      )
    )
)
on conflict do nothing;

insert into virtual_key_profile_bindings (
  tenant_id,
  project_id,
  virtual_key_id,
  profile_id,
  is_default
)
select
  '00000000-0000-0000-0000-000000000001',
  vk.project_id,
  vk.id,
  p.id,
  false
from virtual_keys vk
join api_key_profiles p
  on p.tenant_id = vk.tenant_id
 and p.project_id = vk.project_id
 and p.name = 'Fallback Live Strict Smoke'
where vk.tenant_id = '00000000-0000-0000-0000-000000000001'
  and vk.key_prefix = 'dev_test_key'
order by (vk.id = '00000000-0000-0000-0000-000000000050'::uuid) desc,
         (p.id = '00000000-0000-0000-0000-000000000041'::uuid) desc
limit 1
on conflict (tenant_id, virtual_key_id, profile_id) do update
set project_id = excluded.project_id,
    is_default = false;

with strict_models(id, model_key, display_name) as (
  values
    ('00000000-0000-0000-0000-000000000081'::uuid, 'mock-gpt-4o-mini-fallback-429', 'GPT-4o Mini Fallback Strict 429'),
    ('00000000-0000-0000-0000-000000000082'::uuid, 'mock-gpt-4o-mini-fallback-5xx', 'GPT-4o Mini Fallback Strict 5xx'),
    ('00000000-0000-0000-0000-000000000083'::uuid, 'mock-gpt-4o-mini-fallback-timeout', 'GPT-4o Mini Fallback Strict Timeout'),
    ('00000000-0000-0000-0000-000000000084'::uuid, 'mock-gpt-4o-mini-fallback-eof', 'GPT-4o Mini Fallback Strict EOF')
)
update canonical_models cm
set model_key = 'dev-seed-duplicate-' || cm.id::text,
    status = 'deleted',
    deleted_at = coalesce(cm.deleted_at, now()),
    updated_at = now()
from strict_models sm
where cm.tenant_id = '00000000-0000-0000-0000-000000000001'
  and cm.model_key = sm.model_key
  and cm.id <> sm.id;

with strict_models(id, model_key, display_name) as (
  values
    ('00000000-0000-0000-0000-000000000081'::uuid, 'mock-gpt-4o-mini-fallback-429', 'GPT-4o Mini Fallback Strict 429'),
    ('00000000-0000-0000-0000-000000000082'::uuid, 'mock-gpt-4o-mini-fallback-5xx', 'GPT-4o Mini Fallback Strict 5xx'),
    ('00000000-0000-0000-0000-000000000083'::uuid, 'mock-gpt-4o-mini-fallback-timeout', 'GPT-4o Mini Fallback Strict Timeout'),
    ('00000000-0000-0000-0000-000000000084'::uuid, 'mock-gpt-4o-mini-fallback-eof', 'GPT-4o Mini Fallback Strict EOF')
)
update canonical_models cm
set model_key = sm.model_key,
    display_name = sm.display_name,
    family = 'chat',
    capabilities = '{"chat": true, "mock": true, "owned_by": "mock-openai", "fallback_live_strict": true}'::jsonb,
    context_length = 128000,
    max_output_tokens = 16384,
    supports_stream = false,
    supports_tools = true,
    supports_vision = false,
    supports_audio = false,
    supports_reasoning = false,
    visibility = 'internal',
    status = 'active',
    deleted_at = null,
    updated_at = now()
from strict_models sm
where cm.tenant_id = '00000000-0000-0000-0000-000000000001'
  and (cm.id = sm.id or cm.model_key = sm.model_key);

with strict_models(id, model_key, display_name) as (
  values
    ('00000000-0000-0000-0000-000000000081'::uuid, 'mock-gpt-4o-mini-fallback-429', 'GPT-4o Mini Fallback Strict 429'),
    ('00000000-0000-0000-0000-000000000082'::uuid, 'mock-gpt-4o-mini-fallback-5xx', 'GPT-4o Mini Fallback Strict 5xx'),
    ('00000000-0000-0000-0000-000000000083'::uuid, 'mock-gpt-4o-mini-fallback-timeout', 'GPT-4o Mini Fallback Strict Timeout'),
    ('00000000-0000-0000-0000-000000000084'::uuid, 'mock-gpt-4o-mini-fallback-eof', 'GPT-4o Mini Fallback Strict EOF')
)
insert into canonical_models (
  id,
  tenant_id,
  model_key,
  display_name,
  family,
  capabilities,
  context_length,
  max_output_tokens,
  supports_stream,
  supports_tools,
  supports_vision,
  supports_audio,
  supports_reasoning,
  visibility,
  status
)
select
  sm.id,
  '00000000-0000-0000-0000-000000000001',
  sm.model_key,
  sm.display_name,
  'chat',
  '{"chat": true, "mock": true, "owned_by": "mock-openai", "fallback_live_strict": true}'::jsonb,
  128000,
  16384,
  false,
  true,
  false,
  false,
  false,
  'internal',
  'active'
from strict_models sm
where not exists (
  select 1 from canonical_models cm
  where cm.tenant_id = '00000000-0000-0000-0000-000000000001'
    and (cm.id = sm.id or cm.model_key = sm.model_key)
)
on conflict do nothing;

with strict_channels(id, name, endpoint, priority) as (
  values
    ('00000000-0000-0000-0000-000000000101'::uuid, 'mock-openai-fallback-strict-success', 'http://mock-provider:18080', 20),
    ('00000000-0000-0000-0000-000000000102'::uuid, 'mock-openai-fallback-strict-429', 'http://mock-provider:18080/__scenario/429', 10),
    ('00000000-0000-0000-0000-000000000103'::uuid, 'mock-openai-fallback-strict-5xx', 'http://mock-provider:18080/__scenario/5xx', 10),
    ('00000000-0000-0000-0000-000000000104'::uuid, 'mock-openai-fallback-strict-timeout', 'http://mock-provider:18080/__scenario/timeout', 10),
    ('00000000-0000-0000-0000-000000000105'::uuid, 'mock-openai-fallback-strict-eof', 'http://mock-provider:18080/__scenario/eof', 10)
)
update channels ch
set name = 'dev-seed-duplicate-' || ch.id::text,
    status = 'deleted',
    deleted_at = coalesce(ch.deleted_at, now()),
    updated_at = now()
from strict_channels sc
where ch.tenant_id = '00000000-0000-0000-0000-000000000001'
  and ch.name = sc.name
  and ch.id <> sc.id;

with strict_channels(id, name, endpoint, priority) as (
  values
    ('00000000-0000-0000-0000-000000000101'::uuid, 'mock-openai-fallback-strict-success', 'http://mock-provider:18080', 20),
    ('00000000-0000-0000-0000-000000000102'::uuid, 'mock-openai-fallback-strict-429', 'http://mock-provider:18080/__scenario/429', 10),
    ('00000000-0000-0000-0000-000000000103'::uuid, 'mock-openai-fallback-strict-5xx', 'http://mock-provider:18080/__scenario/5xx', 10),
    ('00000000-0000-0000-0000-000000000104'::uuid, 'mock-openai-fallback-strict-timeout', 'http://mock-provider:18080/__scenario/timeout', 10),
    ('00000000-0000-0000-0000-000000000105'::uuid, 'mock-openai-fallback-strict-eof', 'http://mock-provider:18080/__scenario/eof', 10)
)
update channels ch
set provider_id = (
      select id from providers
      where tenant_id = '00000000-0000-0000-0000-000000000001'
        and code = 'mock-openai'
      order by (id = '00000000-0000-0000-0000-000000000060'::uuid) desc
      limit 1
    ),
    name = sc.name,
    endpoint = sc.endpoint,
    protocol_mode = 'openai_compatible',
    status = 'enabled',
    region = null,
    priority = sc.priority,
    weight = 100,
    tags = '["dev", "mock", "openai-compatible", "fallback-live-strict"]'::jsonb,
    model_mappings = '{
      "mock-gpt-4o-mini-fallback-429": "mock-gpt-4o-mini",
      "mock-gpt-4o-mini-fallback-5xx": "mock-gpt-4o-mini",
      "mock-gpt-4o-mini-fallback-timeout": "mock-gpt-4o-mini",
      "mock-gpt-4o-mini-fallback-eof": "mock-gpt-4o-mini"
    }'::jsonb,
    request_overrides = '[]'::jsonb,
    timeout_policy = '{"connect_timeout_ms": 3000, "request_timeout_ms": 30000}'::jsonb,
    probe_policy = '{"healthz_path": "/healthz", "fallback_live_strict": true}'::jsonb,
    health_score = 1.0,
    deleted_at = null,
    updated_at = now()
from strict_channels sc
where ch.tenant_id = '00000000-0000-0000-0000-000000000001'
  and (
    ch.id = sc.id
    or (
      ch.provider_id = (
        select id from providers
        where tenant_id = '00000000-0000-0000-0000-000000000001'
          and code = 'mock-openai'
        order by (id = '00000000-0000-0000-0000-000000000060'::uuid) desc
        limit 1
      )
      and ch.name = sc.name
    )
  );

with strict_channels(id, name, endpoint, priority) as (
  values
    ('00000000-0000-0000-0000-000000000101'::uuid, 'mock-openai-fallback-strict-success', 'http://mock-provider:18080', 20),
    ('00000000-0000-0000-0000-000000000102'::uuid, 'mock-openai-fallback-strict-429', 'http://mock-provider:18080/__scenario/429', 10),
    ('00000000-0000-0000-0000-000000000103'::uuid, 'mock-openai-fallback-strict-5xx', 'http://mock-provider:18080/__scenario/5xx', 10),
    ('00000000-0000-0000-0000-000000000104'::uuid, 'mock-openai-fallback-strict-timeout', 'http://mock-provider:18080/__scenario/timeout', 10),
    ('00000000-0000-0000-0000-000000000105'::uuid, 'mock-openai-fallback-strict-eof', 'http://mock-provider:18080/__scenario/eof', 10)
)
insert into channels (
  id,
  tenant_id,
  provider_id,
  name,
  endpoint,
  protocol_mode,
  status,
  priority,
  weight,
  tags,
  model_mappings,
  request_overrides,
  timeout_policy,
  probe_policy,
  health_score
)
select
  sc.id,
  '00000000-0000-0000-0000-000000000001',
  (
    select id from providers
    where tenant_id = '00000000-0000-0000-0000-000000000001'
      and code = 'mock-openai'
    order by (id = '00000000-0000-0000-0000-000000000060'::uuid) desc
    limit 1
  ),
  sc.name,
  sc.endpoint,
  'openai_compatible',
  'enabled',
  sc.priority,
  100,
  '["dev", "mock", "openai-compatible", "fallback-live-strict"]'::jsonb,
  '{
    "mock-gpt-4o-mini-fallback-429": "mock-gpt-4o-mini",
    "mock-gpt-4o-mini-fallback-5xx": "mock-gpt-4o-mini",
    "mock-gpt-4o-mini-fallback-timeout": "mock-gpt-4o-mini",
    "mock-gpt-4o-mini-fallback-eof": "mock-gpt-4o-mini"
  }'::jsonb,
  '[]'::jsonb,
  '{"connect_timeout_ms": 3000, "request_timeout_ms": 30000}'::jsonb,
  '{"healthz_path": "/healthz", "fallback_live_strict": true}'::jsonb,
  1.0
from strict_channels sc
where not exists (
  select 1 from channels ch
  where ch.tenant_id = '00000000-0000-0000-0000-000000000001'
    and (
      ch.id = sc.id
      or (
        ch.provider_id = (
          select id from providers
          where tenant_id = '00000000-0000-0000-0000-000000000001'
            and code = 'mock-openai'
          order by (id = '00000000-0000-0000-0000-000000000060'::uuid) desc
          limit 1
        )
        and ch.name = sc.name
      )
    )
)
on conflict do nothing;

with strict_keys(id, channel_name, key_alias, secret_fingerprint, encrypted_secret) as (
  values
    ('00000000-0000-0000-0000-000000000111'::uuid, 'mock-openai-fallback-strict-success', 'fallback-strict-success-key', 'dev-fallback-strict-success-key-fingerprint', '{"algorithm":"aes-256-gcm","ciphertext":"12ef2851edb76fa9e7a96dd7281bb2e6b4c551cde54d2c82dfb61e3a62f25a6cd2427ba544cb8625","master_key_id":"dev-seed-v1","nonce":"f5773c9dff8be57846107680","version":1}'),
    ('00000000-0000-0000-0000-000000000112'::uuid, 'mock-openai-fallback-strict-429', 'fallback-strict-429-key', 'dev-fallback-strict-429-key-fingerprint', '{"algorithm":"aes-256-gcm","ciphertext":"1949ec9c6f98c685606fadf11eb894e2f5c859e6de18f488e6a7a559f6a71cacd32266cd567cd952","master_key_id":"dev-seed-v1","nonce":"cee8bd9baedec7837c8c213e","version":1}'),
    ('00000000-0000-0000-0000-000000000113'::uuid, 'mock-openai-fallback-strict-5xx', 'fallback-strict-5xx-key', 'dev-fallback-strict-5xx-key-fingerprint', '{"algorithm":"aes-256-gcm","ciphertext":"f34625781f56cdb03d3fe254846b1d9ef84ded217d3be98f59a9a14f4af7a47b403fef8600206272","master_key_id":"dev-seed-v1","nonce":"ca321451f1e2542b5a08b1be","version":1}'),
    ('00000000-0000-0000-0000-000000000114'::uuid, 'mock-openai-fallback-strict-timeout', 'fallback-strict-timeout-key', 'dev-fallback-strict-timeout-key-fingerprint', '{"algorithm":"aes-256-gcm","ciphertext":"f5f88f5d46e7d7fda54d9bd409d5873318eb6d2581e5d35ea66ab9877167f8560bc4ab906a3805ce","master_key_id":"dev-seed-v1","nonce":"5c154cfd37f068237fa6ac53","version":1}'),
    ('00000000-0000-0000-0000-000000000115'::uuid, 'mock-openai-fallback-strict-eof', 'fallback-strict-eof-key', 'dev-fallback-strict-eof-key-fingerprint', '{"algorithm":"aes-256-gcm","ciphertext":"1cbefdc0704cf764a98ae4512423ac696c0f21ec2b5bad2a68fd1247c4da351e4159bc4c4c7d8938","master_key_id":"dev-seed-v1","nonce":"964762c98016625e9840c762","version":1}')
)
update provider_keys pk
set key_alias = 'dev-seed-duplicate-' || pk.id::text,
    secret_fingerprint = 'dev-seed-duplicate-' || pk.id::text,
    status = 'deleted',
    deleted_at = coalesce(pk.deleted_at, now()),
    updated_at = now()
from strict_keys sk
join channels ch
  on ch.tenant_id = '00000000-0000-0000-0000-000000000001'
 and ch.name = sk.channel_name
where pk.tenant_id = '00000000-0000-0000-0000-000000000001'
  and pk.channel_id = ch.id
  and pk.key_alias = sk.key_alias
  and pk.id <> sk.id;

with strict_keys(id, channel_name, key_alias, secret_fingerprint, encrypted_secret) as (
  values
    ('00000000-0000-0000-0000-000000000111'::uuid, 'mock-openai-fallback-strict-success', 'fallback-strict-success-key', 'dev-fallback-strict-success-key-fingerprint', '{"algorithm":"aes-256-gcm","ciphertext":"12ef2851edb76fa9e7a96dd7281bb2e6b4c551cde54d2c82dfb61e3a62f25a6cd2427ba544cb8625","master_key_id":"dev-seed-v1","nonce":"f5773c9dff8be57846107680","version":1}'),
    ('00000000-0000-0000-0000-000000000112'::uuid, 'mock-openai-fallback-strict-429', 'fallback-strict-429-key', 'dev-fallback-strict-429-key-fingerprint', '{"algorithm":"aes-256-gcm","ciphertext":"1949ec9c6f98c685606fadf11eb894e2f5c859e6de18f488e6a7a559f6a71cacd32266cd567cd952","master_key_id":"dev-seed-v1","nonce":"cee8bd9baedec7837c8c213e","version":1}'),
    ('00000000-0000-0000-0000-000000000113'::uuid, 'mock-openai-fallback-strict-5xx', 'fallback-strict-5xx-key', 'dev-fallback-strict-5xx-key-fingerprint', '{"algorithm":"aes-256-gcm","ciphertext":"f34625781f56cdb03d3fe254846b1d9ef84ded217d3be98f59a9a14f4af7a47b403fef8600206272","master_key_id":"dev-seed-v1","nonce":"ca321451f1e2542b5a08b1be","version":1}'),
    ('00000000-0000-0000-0000-000000000114'::uuid, 'mock-openai-fallback-strict-timeout', 'fallback-strict-timeout-key', 'dev-fallback-strict-timeout-key-fingerprint', '{"algorithm":"aes-256-gcm","ciphertext":"f5f88f5d46e7d7fda54d9bd409d5873318eb6d2581e5d35ea66ab9877167f8560bc4ab906a3805ce","master_key_id":"dev-seed-v1","nonce":"5c154cfd37f068237fa6ac53","version":1}'),
    ('00000000-0000-0000-0000-000000000115'::uuid, 'mock-openai-fallback-strict-eof', 'fallback-strict-eof-key', 'dev-fallback-strict-eof-key-fingerprint', '{"algorithm":"aes-256-gcm","ciphertext":"1cbefdc0704cf764a98ae4512423ac696c0f21ec2b5bad2a68fd1247c4da351e4159bc4c4c7d8938","master_key_id":"dev-seed-v1","nonce":"964762c98016625e9840c762","version":1}')
)
update provider_keys pk
set channel_id = ch.id,
    key_alias = sk.key_alias,
    encrypted_secret = sk.encrypted_secret,
    secret_fingerprint = sk.secret_fingerprint,
    status = 'enabled',
    health_score = 1.0,
    cooldown_until = null,
    last_error_code = null,
    metadata = '{"dev_seed": true, "sealed_placeholder": true, "fallback_live_strict": true}'::jsonb,
    deleted_at = null,
    updated_at = now()
from strict_keys sk
join channels ch
  on ch.tenant_id = '00000000-0000-0000-0000-000000000001'
 and ch.name = sk.channel_name
where pk.tenant_id = '00000000-0000-0000-0000-000000000001'
  and (pk.id = sk.id or (pk.channel_id = ch.id and pk.key_alias = sk.key_alias));

with strict_keys(id, channel_name, key_alias, secret_fingerprint, encrypted_secret) as (
  values
    ('00000000-0000-0000-0000-000000000111'::uuid, 'mock-openai-fallback-strict-success', 'fallback-strict-success-key', 'dev-fallback-strict-success-key-fingerprint', '{"algorithm":"aes-256-gcm","ciphertext":"12ef2851edb76fa9e7a96dd7281bb2e6b4c551cde54d2c82dfb61e3a62f25a6cd2427ba544cb8625","master_key_id":"dev-seed-v1","nonce":"f5773c9dff8be57846107680","version":1}'),
    ('00000000-0000-0000-0000-000000000112'::uuid, 'mock-openai-fallback-strict-429', 'fallback-strict-429-key', 'dev-fallback-strict-429-key-fingerprint', '{"algorithm":"aes-256-gcm","ciphertext":"1949ec9c6f98c685606fadf11eb894e2f5c859e6de18f488e6a7a559f6a71cacd32266cd567cd952","master_key_id":"dev-seed-v1","nonce":"cee8bd9baedec7837c8c213e","version":1}'),
    ('00000000-0000-0000-0000-000000000113'::uuid, 'mock-openai-fallback-strict-5xx', 'fallback-strict-5xx-key', 'dev-fallback-strict-5xx-key-fingerprint', '{"algorithm":"aes-256-gcm","ciphertext":"f34625781f56cdb03d3fe254846b1d9ef84ded217d3be98f59a9a14f4af7a47b403fef8600206272","master_key_id":"dev-seed-v1","nonce":"ca321451f1e2542b5a08b1be","version":1}'),
    ('00000000-0000-0000-0000-000000000114'::uuid, 'mock-openai-fallback-strict-timeout', 'fallback-strict-timeout-key', 'dev-fallback-strict-timeout-key-fingerprint', '{"algorithm":"aes-256-gcm","ciphertext":"f5f88f5d46e7d7fda54d9bd409d5873318eb6d2581e5d35ea66ab9877167f8560bc4ab906a3805ce","master_key_id":"dev-seed-v1","nonce":"5c154cfd37f068237fa6ac53","version":1}'),
    ('00000000-0000-0000-0000-000000000115'::uuid, 'mock-openai-fallback-strict-eof', 'fallback-strict-eof-key', 'dev-fallback-strict-eof-key-fingerprint', '{"algorithm":"aes-256-gcm","ciphertext":"1cbefdc0704cf764a98ae4512423ac696c0f21ec2b5bad2a68fd1247c4da351e4159bc4c4c7d8938","master_key_id":"dev-seed-v1","nonce":"964762c98016625e9840c762","version":1}')
)
insert into provider_keys (
  id,
  tenant_id,
  channel_id,
  key_alias,
  encrypted_secret,
  secret_fingerprint,
  status,
  health_score,
  metadata
)
select
  sk.id,
  '00000000-0000-0000-0000-000000000001',
  ch.id,
  sk.key_alias,
  sk.encrypted_secret,
  sk.secret_fingerprint,
  'enabled',
  1.0,
  '{"dev_seed": true, "sealed_placeholder": true, "fallback_live_strict": true}'::jsonb
from strict_keys sk
join channels ch
  on ch.tenant_id = '00000000-0000-0000-0000-000000000001'
 and ch.name = sk.channel_name
where not exists (
  select 1 from provider_keys pk
  where pk.tenant_id = '00000000-0000-0000-0000-000000000001'
    and (pk.id = sk.id or (pk.channel_id = ch.id and pk.key_alias = sk.key_alias))
)
on conflict do nothing;

with strict_associations(id, model_key, channel_name, association_priority) as (
  values
    ('00000000-0000-0000-0000-000000000121'::uuid, 'mock-gpt-4o-mini-fallback-429', 'mock-openai-fallback-strict-429', 10),
    ('00000000-0000-0000-0000-000000000122'::uuid, 'mock-gpt-4o-mini-fallback-429', 'mock-openai-fallback-strict-success', 20),
    ('00000000-0000-0000-0000-000000000123'::uuid, 'mock-gpt-4o-mini-fallback-5xx', 'mock-openai-fallback-strict-5xx', 10),
    ('00000000-0000-0000-0000-000000000124'::uuid, 'mock-gpt-4o-mini-fallback-5xx', 'mock-openai-fallback-strict-success', 20),
    ('00000000-0000-0000-0000-000000000125'::uuid, 'mock-gpt-4o-mini-fallback-timeout', 'mock-openai-fallback-strict-timeout', 10),
    ('00000000-0000-0000-0000-000000000126'::uuid, 'mock-gpt-4o-mini-fallback-timeout', 'mock-openai-fallback-strict-success', 20),
    ('00000000-0000-0000-0000-000000000127'::uuid, 'mock-gpt-4o-mini-fallback-eof', 'mock-openai-fallback-strict-eof', 10),
    ('00000000-0000-0000-0000-000000000128'::uuid, 'mock-gpt-4o-mini-fallback-eof', 'mock-openai-fallback-strict-success', 20)
)
update model_associations ma
set status = 'deleted',
    deleted_at = coalesce(ma.deleted_at, now()),
    updated_at = now()
from strict_associations sa
join canonical_models cm
  on cm.tenant_id = '00000000-0000-0000-0000-000000000001'
 and cm.model_key = sa.model_key
join channels ch
  on ch.tenant_id = cm.tenant_id
 and ch.name = sa.channel_name
where ma.tenant_id = '00000000-0000-0000-0000-000000000001'
  and ma.canonical_model_id = cm.id
  and ma.channel_id = ch.id
  and ma.association_type = 'explicit_channel'
  and coalesce(ma.upstream_model_name, '') = 'mock-gpt-4o-mini'
  and ma.id <> sa.id;

with strict_associations(id, model_key, channel_name, association_priority) as (
  values
    ('00000000-0000-0000-0000-000000000121'::uuid, 'mock-gpt-4o-mini-fallback-429', 'mock-openai-fallback-strict-429', 10),
    ('00000000-0000-0000-0000-000000000122'::uuid, 'mock-gpt-4o-mini-fallback-429', 'mock-openai-fallback-strict-success', 20),
    ('00000000-0000-0000-0000-000000000123'::uuid, 'mock-gpt-4o-mini-fallback-5xx', 'mock-openai-fallback-strict-5xx', 10),
    ('00000000-0000-0000-0000-000000000124'::uuid, 'mock-gpt-4o-mini-fallback-5xx', 'mock-openai-fallback-strict-success', 20),
    ('00000000-0000-0000-0000-000000000125'::uuid, 'mock-gpt-4o-mini-fallback-timeout', 'mock-openai-fallback-strict-timeout', 10),
    ('00000000-0000-0000-0000-000000000126'::uuid, 'mock-gpt-4o-mini-fallback-timeout', 'mock-openai-fallback-strict-success', 20),
    ('00000000-0000-0000-0000-000000000127'::uuid, 'mock-gpt-4o-mini-fallback-eof', 'mock-openai-fallback-strict-eof', 10),
    ('00000000-0000-0000-0000-000000000128'::uuid, 'mock-gpt-4o-mini-fallback-eof', 'mock-openai-fallback-strict-success', 20)
)
update model_associations ma
set canonical_model_id = cm.id,
    association_type = 'explicit_channel',
    channel_id = ch.id,
    channel_tag = null,
    model_pattern = null,
    upstream_model_name = 'mock-gpt-4o-mini',
    priority = sa.association_priority,
    conditions = '{}'::jsonb,
    fallback_allowed = true,
    canary_percent = 100,
    status = 'enabled',
    deleted_at = null,
    updated_at = now()
from strict_associations sa
join canonical_models cm
  on cm.tenant_id = '00000000-0000-0000-0000-000000000001'
 and cm.model_key = sa.model_key
join channels ch
  on ch.tenant_id = cm.tenant_id
 and ch.name = sa.channel_name
where ma.tenant_id = '00000000-0000-0000-0000-000000000001'
  and (
    ma.id = sa.id
    or (
      ma.canonical_model_id = cm.id
      and ma.channel_id = ch.id
      and ma.association_type = 'explicit_channel'
      and coalesce(ma.upstream_model_name, '') = 'mock-gpt-4o-mini'
    )
  );

with strict_associations(id, model_key, channel_name, association_priority) as (
  values
    ('00000000-0000-0000-0000-000000000121'::uuid, 'mock-gpt-4o-mini-fallback-429', 'mock-openai-fallback-strict-429', 10),
    ('00000000-0000-0000-0000-000000000122'::uuid, 'mock-gpt-4o-mini-fallback-429', 'mock-openai-fallback-strict-success', 20),
    ('00000000-0000-0000-0000-000000000123'::uuid, 'mock-gpt-4o-mini-fallback-5xx', 'mock-openai-fallback-strict-5xx', 10),
    ('00000000-0000-0000-0000-000000000124'::uuid, 'mock-gpt-4o-mini-fallback-5xx', 'mock-openai-fallback-strict-success', 20),
    ('00000000-0000-0000-0000-000000000125'::uuid, 'mock-gpt-4o-mini-fallback-timeout', 'mock-openai-fallback-strict-timeout', 10),
    ('00000000-0000-0000-0000-000000000126'::uuid, 'mock-gpt-4o-mini-fallback-timeout', 'mock-openai-fallback-strict-success', 20),
    ('00000000-0000-0000-0000-000000000127'::uuid, 'mock-gpt-4o-mini-fallback-eof', 'mock-openai-fallback-strict-eof', 10),
    ('00000000-0000-0000-0000-000000000128'::uuid, 'mock-gpt-4o-mini-fallback-eof', 'mock-openai-fallback-strict-success', 20)
)
insert into model_associations (
  id,
  tenant_id,
  canonical_model_id,
  association_type,
  channel_id,
  channel_tag,
  model_pattern,
  upstream_model_name,
  priority,
  conditions,
  fallback_allowed,
  canary_percent,
  status
)
select
  sa.id,
  '00000000-0000-0000-0000-000000000001',
  cm.id,
  'explicit_channel',
  ch.id,
  null,
  null,
  'mock-gpt-4o-mini',
  sa.association_priority,
  '{}'::jsonb,
  true,
  100,
  'enabled'
from strict_associations sa
join canonical_models cm
  on cm.tenant_id = '00000000-0000-0000-0000-000000000001'
 and cm.model_key = sa.model_key
join channels ch
  on ch.tenant_id = cm.tenant_id
 and ch.name = sa.channel_name
where not exists (
  select 1 from model_associations ma
  where ma.tenant_id = '00000000-0000-0000-0000-000000000001'
    and (
      ma.id = sa.id
      or (
        ma.canonical_model_id = cm.id
        and ma.channel_id = ch.id
        and ma.association_type = 'explicit_channel'
        and coalesce(ma.upstream_model_name, '') = 'mock-gpt-4o-mini'
      )
    )
)
on conflict do nothing;
