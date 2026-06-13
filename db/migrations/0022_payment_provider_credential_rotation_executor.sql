-- Adds idempotent merchant credential rotation executor state.
-- Only marker hashes and short fingerprint prefixes are stored here.

alter table payment_provider_merchant_credentials
  add column if not exists active_credential_generation bigint not null default 1,
  add column if not exists last_rotation_marker_hash text null,
  add column if not exists previous_credential_fingerprint_prefix text null;

create index if not exists idx_payment_provider_merchant_credentials_rotation_marker
  on payment_provider_merchant_credentials(tenant_id, provider, last_rotation_marker_hash)
  where deleted_at is null and last_rotation_marker_hash is not null;
