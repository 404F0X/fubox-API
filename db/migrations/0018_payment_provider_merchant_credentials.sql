-- Tenant-scoped payment provider merchant credential source-of-truth.
-- Secrets are not stored here. Operators store secret references and a short
-- fingerprint prefix for safe readback/correlation.

create table if not exists payment_provider_merchant_credentials (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  provider text not null,
  status text not null default 'disabled',
  merchant_account_ref text null,
  credential_secret_ref text null,
  credential_fingerprint_prefix text null,
  webhook_secret_ref text null,
  rotation_version bigint not null default 1,
  active_credential_generation bigint not null default 1,
  last_rotation_marker_hash text null,
  previous_credential_fingerprint_prefix text null,
  last_rotated_at timestamptz null,
  disabled_at timestamptz null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  unique (tenant_id, provider),
  check (length(btrim(provider)) > 0),
  check (provider !~* '(secret|token|credential|password|authorization)'),
  check (status in ('enabled', 'disabled')),
  check (credential_fingerprint_prefix is null or credential_fingerprint_prefix ~ '^[a-f0-9]{8,32}$'),
  check (jsonb_typeof(metadata) = 'object')
);

create index if not exists idx_payment_provider_merchant_credentials_tenant_status
  on payment_provider_merchant_credentials(tenant_id, status)
  where deleted_at is null;
