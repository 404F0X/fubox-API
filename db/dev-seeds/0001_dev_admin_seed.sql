-- Development/smoke admin seed only. Do not use this account in production.
-- Raw credentials: admin@example.com / local-password.

insert into users (
  id,
  tenant_id,
  email,
  display_name,
  password_hash,
  status,
  metadata
)
values (
  '00000000-0000-0000-0000-0000000000a1',
  '00000000-0000-0000-0000-000000000001',
  'admin@example.com',
  'Local Admin',
  'pbkdf2-sha256$v1$210000$000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f$09d4ad00a3fbf85ac4bebe70a5a4598357f830d572331c94000d9d898062deb8',
  'active',
  '{"dev_seed": true}'::jsonb
)
on conflict do nothing;

update users
set email = 'admin@example.com',
    display_name = 'Local Admin',
    password_hash = 'pbkdf2-sha256$v1$210000$000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f$09d4ad00a3fbf85ac4bebe70a5a4598357f830d572331c94000d9d898062deb8',
    status = 'active',
    deleted_at = null,
    metadata = metadata || '{"dev_seed": true}'::jsonb,
    updated_at = now()
where tenant_id = '00000000-0000-0000-0000-000000000001'
  and id = '00000000-0000-0000-0000-0000000000a1';

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
on conflict (tenant_id, team_id, user_id) do update
set role = excluded.role;

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
on conflict (tenant_id, project_id, user_id) do update
set role = excluded.role;
