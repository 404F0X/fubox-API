alter table api_key_profiles
  add column if not exists ip_allowlist jsonb not null default '[]'::jsonb;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.api_key_profiles'::regclass
      and conname = 'chk_api_key_profiles_ip_allowlist_array'
  ) then
    alter table api_key_profiles
      add constraint chk_api_key_profiles_ip_allowlist_array
      check (jsonb_typeof(ip_allowlist) = 'array');
  end if;
end $$;

create index if not exists idx_api_key_profiles_ip_allowlist
  on api_key_profiles using gin(ip_allowlist);
