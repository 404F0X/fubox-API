-- Gateway hot-path indexes for auth, model listing, and route resolution.

create index if not exists idx_virtual_keys_auth_active_lookup
  on virtual_keys(key_prefix, secret_hash)
  where deleted_at is null
    and status <> 'deleted';

create index if not exists idx_canonical_models_visible_active_list
  on canonical_models(tenant_id, model_key)
  where deleted_at is null
    and status = 'active'
    and visibility in ('public', 'internal');

create index if not exists idx_model_associations_enabled_route
  on model_associations(tenant_id, canonical_model_id, priority, id)
  where deleted_at is null
    and status = 'enabled';

create index if not exists idx_channels_openai_route_candidates
  on channels(tenant_id, priority, weight desc, id)
  where deleted_at is null
    and status <> 'deleted'
    and protocol_mode = 'openai_compatible';
