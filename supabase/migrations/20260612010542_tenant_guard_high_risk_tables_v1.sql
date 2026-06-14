-- Replace broad authenticated policies on high-risk tenant tables.
-- This keeps behavior within a tenant broad enough to avoid workflow breaks,
-- while stopping cross-tenant reads/writes and making demo users read-only.

create or replace function public.app_has_tenant_access(p_tenant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.users u
    where u.user_id = auth.uid()
      and u.tenant_id = p_tenant_id
      and coalesce(u.status, 'active') = 'active'
  );
$$;

create or replace function public.app_has_tenant_write_access(p_tenant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.users u
    where u.user_id = auth.uid()
      and u.tenant_id = p_tenant_id
      and coalesce(u.status, 'active') = 'active'
      and lower(coalesce(u.role_id, '')) not in ('demo_super_admin', 'demo')
  );
$$;

create or replace function public.app_has_tenant_super_admin_access(p_tenant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.users u
    where u.user_id = auth.uid()
      and u.tenant_id = p_tenant_id
      and coalesce(u.status, 'active') = 'active'
      and lower(coalesce(u.role_id, '')) = 'super_admin'
  );
$$;

do $$
declare
  v_table text;
  v_tables text[] := array[
    'attendance',
    'attendance_logs',
    'content_proofs',
    'content_task',
    'content_tasks',
    'finance_verifications',
    'host_live_sessions',
    'live_proofs',
    'live_schedules',
    'live_verifications',
    'module_records',
    'photo_evidences',
    'products',
    'purchase_items',
    'purchase_receipts',
    'purchases',
    'stock_transactions',
    'suppliers',
    'task_comments',
    'tasks',
    'work_locations'
  ];
begin
  foreach v_table in array v_tables loop
    execute format('alter table public.%I enable row level security', v_table);

    execute format('drop policy if exists authenticated_all on public.%I', v_table);
    execute format('drop policy if exists %I on public.%I', v_table || '_admin_all', v_table);
    execute format('drop policy if exists tenant_select on public.%I', v_table);
    execute format('drop policy if exists tenant_insert on public.%I', v_table);
    execute format('drop policy if exists tenant_update on public.%I', v_table);
    execute format('drop policy if exists tenant_delete on public.%I', v_table);

    if v_table = 'photo_evidences' then
      execute 'drop policy if exists photo_evidences_select_authenticated on public.photo_evidences';
    end if;

    execute format(
      'create policy tenant_select on public.%I for select to authenticated using (public.app_has_tenant_access(tenant_id))',
      v_table
    );
    execute format(
      'create policy tenant_insert on public.%I for insert to authenticated with check (public.app_has_tenant_write_access(tenant_id))',
      v_table
    );
    execute format(
      'create policy tenant_update on public.%I for update to authenticated using (public.app_has_tenant_write_access(tenant_id)) with check (public.app_has_tenant_write_access(tenant_id))',
      v_table
    );
    execute format(
      'create policy tenant_delete on public.%I for delete to authenticated using (public.app_has_tenant_write_access(tenant_id))',
      v_table
    );
  end loop;
end;
$$;

alter table public.users enable row level security;

drop policy if exists authenticated_all on public.users;
drop policy if exists users_insert_admin on public.users;
drop policy if exists users_update_admin on public.users;
drop policy if exists users_tenant_select on public.users;
drop policy if exists users_tenant_insert on public.users;
drop policy if exists users_tenant_update on public.users;
drop policy if exists users_tenant_delete on public.users;

create policy users_tenant_select
  on public.users
  for select
  to authenticated
  using (public.app_has_tenant_access(tenant_id));

create policy users_tenant_insert
  on public.users
  for insert
  to authenticated
  with check (public.app_has_tenant_super_admin_access(tenant_id));

create policy users_tenant_update
  on public.users
  for update
  to authenticated
  using (public.app_has_tenant_super_admin_access(tenant_id))
  with check (public.app_has_tenant_super_admin_access(tenant_id));

create policy users_tenant_delete
  on public.users
  for delete
  to authenticated
  using (public.app_has_tenant_super_admin_access(tenant_id));

alter table public.roles enable row level security;
drop policy if exists authenticated_all on public.roles;
drop policy if exists roles_read_authenticated on public.roles;
create policy roles_read_authenticated
  on public.roles
  for select
  to authenticated
  using (true);

grant execute on function public.app_has_tenant_access(uuid) to authenticated, service_role;
grant execute on function public.app_has_tenant_write_access(uuid) to authenticated, service_role;
grant execute on function public.app_has_tenant_super_admin_access(uuid) to authenticated, service_role;

comment on function public.app_has_tenant_access(uuid) is
'True when the current active user belongs to the tenant.';
comment on function public.app_has_tenant_write_access(uuid) is
'True when the current active non-demo user belongs to the tenant.';
comment on function public.app_has_tenant_super_admin_access(uuid) is
'True when the current active super_admin belongs to the tenant.';
