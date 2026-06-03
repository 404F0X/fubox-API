-- Development/smoke seed only. Do not use these credentials in production.

insert into providers (id, tenant_id, code, name, status, metadata)
values (
  '00000000-0000-0000-0000-000000000060',
  '00000000-0000-0000-0000-000000000001',
  'mock-openai',
  'Mock OpenAI Compatible Provider',
  'enabled',
  '{"dev_seed": true}'::jsonb
)
on conflict do nothing;

update channels
set model_mappings = '{"mock-gpt-4o-mini": "mock-gpt-4o-mini"}'::jsonb,
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and id = '00000000-0000-0000-0000-000000000070';

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
  probe_policy
)
values (
  '00000000-0000-0000-0000-000000000070',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000060',
  'mock-openai-default',
  'http://mock-provider:18080',
  'openai_compatible',
  'enabled',
  10,
  100,
  '["dev", "mock", "openai-compatible"]'::jsonb,
  '{"mock-gpt-4o-mini": "mock-gpt-4o-mini"}'::jsonb,
  '{"connect_timeout_ms": 3000, "request_timeout_ms": 30000}'::jsonb,
  '{"healthz_path": "/healthz"}'::jsonb
)
on conflict do nothing;

update canonical_models
set model_key = 'mock-gpt-4o-mini',
    display_name = 'GPT-4o Mini Dev Mock',
    capabilities = '{"chat": true, "mock": true}'::jsonb,
    visibility = 'public',
    status = 'active',
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and id = '00000000-0000-0000-0000-000000000080';

insert into provider_keys (
  id,
  tenant_id,
  channel_id,
  key_alias,
  encrypted_secret,
  secret_fingerprint,
  status,
  metadata
)
values (
  '00000000-0000-0000-0000-000000000075',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000070',
  'mock-dev-key',
  '{"algorithm":"aes-256-gcm","ciphertext":"fc31dbd39aec2a2f5879fa15e7d95c5ed2af95fab8604709f3f6788eb2761c70df6f734515fa127f","master_key_id":"dev-seed-v1","nonce":"3a648880a0c00417ad5c0bd6","version":1}',
  'hmac-sha256-v1:850e131450a7c691b8300375967287a7532bdab7d922dbc2db974f5a0f1bea2a',
  'enabled',
  '{"dev_seed": true, "sealed_placeholder": true}'::jsonb
)
on conflict do nothing;

update model_associations
set upstream_model_name = 'mock-gpt-4o-mini',
    status = 'enabled',
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and id = '00000000-0000-0000-0000-000000000090';

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
  visibility,
  status
)
values (
  '00000000-0000-0000-0000-000000000080',
  '00000000-0000-0000-0000-000000000001',
  'mock-gpt-4o-mini',
  'GPT-4o Mini Dev Mock',
  'chat',
  '{"chat": true, "mock": true}'::jsonb,
  128000,
  16384,
  true,
  true,
  'public',
  'active'
)
on conflict do nothing;

insert into model_associations (
  id,
  tenant_id,
  canonical_model_id,
  association_type,
  channel_id,
  upstream_model_name,
  priority,
  fallback_allowed,
  canary_percent,
  status
)
values (
  '00000000-0000-0000-0000-000000000090',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000080',
  'explicit_channel',
  '00000000-0000-0000-0000-000000000070',
  'mock-gpt-4o-mini',
  10,
  true,
  100,
  'enabled'
)
on conflict do nothing;

insert into virtual_keys (
  id,
  tenant_id,
  project_id,
  name,
  key_prefix,
  secret_hash,
  status,
  default_profile_id,
  metadata
)
values (
  '00000000-0000-0000-0000-000000000050',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000020',
  'Dev Smoke Virtual Key',
  'dev_test_key',
  '165c66ca7e0aff3d28b1aaca0126d4feefabc507d91a38fe4680d921540f8e83',
  'active',
  '00000000-0000-0000-0000-000000000040',
  '{"dev_seed": true}'::jsonb
)
on conflict do nothing;

insert into virtual_key_profile_bindings (
  tenant_id,
  project_id,
  virtual_key_id,
  profile_id,
  is_default
)
values (
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000020',
  '00000000-0000-0000-0000-000000000050',
  '00000000-0000-0000-0000-000000000040',
  true
)
on conflict do nothing;

update api_key_profiles
set allowed_models = '["mock-gpt-4o-mini"]'::jsonb,
    allowed_channel_tags = '["dev", "mock", "openai-compatible"]'::jsonb,
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and id = '00000000-0000-0000-0000-000000000040';
