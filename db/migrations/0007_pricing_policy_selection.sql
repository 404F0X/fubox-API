-- Pricing policy selectors for tenant/project/profile scoped defaults.
-- Keep idempotent for existing development databases.

alter table tenants add column if not exists default_price_book_id uuid null;
alter table projects add column if not exists default_price_book_id uuid null;
alter table api_key_profiles add column if not exists default_price_book_id uuid null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.tenants'::regclass
      and conname = 'fk_tenants_default_price_book_tenant'
  ) then
    alter table tenants
      add constraint fk_tenants_default_price_book_tenant
      foreign key (id, default_price_book_id) references price_books(tenant_id, id);
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.projects'::regclass
      and conname = 'fk_projects_default_price_book_tenant'
  ) then
    alter table projects
      add constraint fk_projects_default_price_book_tenant
      foreign key (tenant_id, default_price_book_id) references price_books(tenant_id, id);
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.api_key_profiles'::regclass
      and conname = 'fk_api_key_profiles_default_price_book_tenant'
  ) then
    alter table api_key_profiles
      add constraint fk_api_key_profiles_default_price_book_tenant
      foreign key (tenant_id, default_price_book_id) references price_books(tenant_id, id);
  end if;
end $$;

create index if not exists idx_tenants_default_price_book_active
  on tenants(id, default_price_book_id)
  where default_price_book_id is not null
    and status = 'active'
    and deleted_at is null;

create index if not exists idx_projects_default_price_book_active
  on projects(tenant_id, id, default_price_book_id)
  where default_price_book_id is not null
    and status = 'active'
    and deleted_at is null;

create index if not exists idx_api_key_profiles_default_price_book_active
  on api_key_profiles(tenant_id, project_id, id, default_price_book_id)
  where default_price_book_id is not null
    and status = 'active'
    and deleted_at is null;

create index if not exists idx_price_books_active_scope
  on price_books(tenant_id, id, project_id)
  where status = 'active';

create index if not exists idx_price_versions_active_effective_lookup
  on price_versions(tenant_id, price_book_id, canonical_model_id, effective_at desc, created_at desc, id)
  where status = 'active';
