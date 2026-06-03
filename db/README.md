# Database Schema Principles

The initial PostgreSQL schema is intentionally stricter than a demo schema because later gateway features depend on DB-level guarantees.

- Tenant-owned tables carry `tenant_id` and expose `unique (tenant_id, id)` so child tables can use composite foreign keys and cannot silently reference rows from another tenant.
- Status fields remain strings for readability, but every status column has a CHECK constraint to prevent unsupported state-machine values.
- JSONB policy/config fields are typed with CHECK constraints as `object` or `array` so malformed configuration is rejected before it reaches the gateway hot path.
- Ledger writes are protected by `(tenant_id, idempotency_key)` and by a partial unique index that prevents more than one pending/confirmed `settle` entry for the same request.
- Request and provider attempt tables are indexed around the Admin UI and worker access patterns: tenant time ranges, project/key/model/channel filters, trace/thread lookup, and error investigation.
- Billing facts are append-oriented. Application code should not mutate confirmed ledger entries in place; use reversal or refund entries with `related_ledger_entry_id`.
- Repository code uses runtime `sqlx::query` calls rather than compile-time database macros. This keeps local builds independent of a live compile-time database while still returning typed Rust models at the crate boundary.
- Auth lookup should parse `Authorization: Bearer <key>` in `ai-gateway-auth`, query `virtual_keys` by `key_prefix`, then compare the SHA-256 `secret_hash`; raw virtual keys must never be persisted.
- Control-plane CRUD should prefer soft-delete status transitions for provider/channel/model records so audit and historical request references remain valid.

## Development Seed

The generic `db/migrations` set creates the schema plus deterministic default tenant/project/profile rows used by schema checks. Development-only runtime data lives under `db/dev-seeds`:

- `0002_dev_gateway_seed.sql` inserts the initial local provider/channel/model/virtual-key seed.
- `0003_dev_smoke_seed_reconcile.sql` reconciles the seed to the current Gateway strong-auth smoke shape so an existing compose database can be repaired without dropping data.
- `0001_dev_admin_seed.sql` inserts the local Control Plane admin user for smoke tests.

- Tenant/project/profile rows build on the deterministic defaults in `0001`.
- Dev virtual key raw value: `dev_test_key_123456789`.
- Stored virtual key prefix: `dev_test_key`.
- Stored secret hash: `165c66ca7e0aff3d28b1aaca0126d4feefabc507d91a38fe4680d921540f8e83`.
- Mock provider/channel/model point at the compose mock provider and canonical model `mock-gpt-4o-mini`.
- Dev provider key rows are sealed with master key id `dev-seed-v1`; local compose sets the matching dev-only provider-key master key environment variables so those sealed payloads can be opened during smoke tests.

These values are fake and must not be reused in production. Production seed/migration paths should create tenants and keys through the control plane and store only prefixes plus hashes.

`deploy/docker-compose/docker-compose.yml` mounts the repository `db` directory at `/app/db`, and `deploy/docker-compose/postgres-init.sh` applies all `db/migrations/*.sql` files before the development seeds. Production migration pipelines must apply `db/migrations` without applying `db/dev-seeds`.

For local Admin UI calls to the Control Plane, configure
`AI_GATEWAY_CONTROL_CORS_ALLOWED_ORIGINS` with explicit origins instead of a
wildcard. In HTTPS deployments, set `AI_GATEWAY_ADMIN_COOKIE_SECURE=true` or run
with `AI_GATEWAY_ENV=production` so the admin session cookie includes `Secure`.

For an already-initialized compose database, re-apply the upgrade migration and development seed files directly:

```powershell
docker compose -f deploy\docker-compose\docker-compose.yml exec -T postgres psql -U ai_gateway -d ai_gateway -f /app/db/migrations/0002_upgrade_dev_skeleton.sql
docker compose -f deploy\docker-compose\docker-compose.yml exec -T postgres psql -U ai_gateway -d ai_gateway -f /app/db/dev-seeds/0002_dev_gateway_seed.sql
docker compose -f deploy\docker-compose\docker-compose.yml exec -T postgres psql -U ai_gateway -d ai_gateway -f /app/db/dev-seeds/0003_dev_smoke_seed_reconcile.sql
docker compose -f deploy\docker-compose\docker-compose.yml exec -T postgres psql -U ai_gateway -d ai_gateway -f /app/db/dev-seeds/0001_dev_admin_seed.sql
```

Then verify the strong-auth smoke rows:

```sql
select
  vk.key_prefix,
  vk.secret_hash,
  vk.status as key_status,
  p.status as profile_status,
  cm.model_key,
  cm.visibility,
  pr.code as provider_code,
  ch.name as channel_name,
  ma.status as association_status
from virtual_keys vk
join virtual_key_profile_bindings vkb
  on vkb.tenant_id = vk.tenant_id
 and vkb.virtual_key_id = vk.id
 and vkb.is_default = true
join api_key_profiles p
  on p.tenant_id = vkb.tenant_id
 and p.project_id = vkb.project_id
 and p.id = vkb.profile_id
join canonical_models cm
  on cm.tenant_id = vk.tenant_id
 and cm.model_key = 'mock-gpt-4o-mini'
join model_associations ma
  on ma.tenant_id = cm.tenant_id
 and ma.canonical_model_id = cm.id
 and ma.upstream_model_name = 'mock-gpt-4o-mini'
join channels ch
  on ch.tenant_id = ma.tenant_id
 and ch.id = ma.channel_id
join providers pr
  on pr.tenant_id = ch.tenant_id
 and pr.id = ch.provider_id
where vk.key_prefix = 'dev_test_key'
  and vk.secret_hash = '165c66ca7e0aff3d28b1aaca0126d4feefabc507d91a38fe4680d921540f8e83';
```

Known follow-up work:

- Add partitioning for `request_logs`, `provider_attempts`, and `audit_logs` before large production traffic.
- Add migration tests that assert cross-tenant foreign keys, invalid statuses, duplicate ledger settlement, and request trace lookups.
- Add application-level migrations for `updated_at` automation or explicit write-path updates.

## Verification

Run the repeatable schema check from the repository root:

```powershell
.\scripts\verify_db_schema.ps1
```

The script starts a temporary PostgreSQL 16 container, initializes `db/migrations`, asserts key tables exist, and verifies that invalid status values, cross-tenant references, and duplicate settlement entries are rejected.

`0002_upgrade_dev_skeleton.sql` exists to non-destructively upgrade development databases that were initialized before the stricter `0001_init.sql` schema landed. Fresh databases still initialize through `0001` first, then `0002` runs idempotently.
