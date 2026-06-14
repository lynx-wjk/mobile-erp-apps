-- Tenant-scope audit log reads/deletes and keep demo_super_admin read-only.

alter table public.audit_logs enable row level security;

create or replace function public.audit_log_has_tenant_access(
  p_tenant_id uuid,
  p_user_id uuid,
  p_require_write boolean default false
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.users current_user_row
    where current_user_row.user_id = auth.uid()
      and coalesce(current_user_row.status, 'active') = 'active'
      and (
        case
          when p_require_write then lower(coalesce(current_user_row.role_id, '')) = 'super_admin'
          else lower(coalesce(current_user_row.role_id, '')) in ('super_admin', 'demo_super_admin')
        end
      )
      and (
        p_tenant_id = current_user_row.tenant_id
        or (
          p_tenant_id is null
          and exists (
            select 1
            from public.users actor_user_row
            where actor_user_row.user_id = p_user_id
              and actor_user_row.tenant_id = current_user_row.tenant_id
          )
        )
      )
  );
$$;

create or replace function public.audit_log_same_tenant_for_insert(p_tenant_id uuid)
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
      and coalesce(u.status, 'active') = 'active'
      and (p_tenant_id is null or u.tenant_id = p_tenant_id)
  );
$$;

drop policy if exists authenticated_all on public.audit_logs;
drop policy if exists audit_logs_admin_all on public.audit_logs;
drop policy if exists audit_logs_insert_active_users on public.audit_logs;
drop policy if exists audit_logs_select_tenant_admin on public.audit_logs;
drop policy if exists audit_logs_insert_active_same_tenant on public.audit_logs;
drop policy if exists audit_logs_delete_tenant_super_admin on public.audit_logs;

create policy audit_logs_select_tenant_admin
  on public.audit_logs
  for select
  to authenticated
  using (public.audit_log_has_tenant_access(tenant_id, user_id, false));

create policy audit_logs_insert_active_same_tenant
  on public.audit_logs
  for insert
  to authenticated
  with check (
    auth.uid() is not null
    and user_id = auth.uid()
    and public.audit_log_same_tenant_for_insert(tenant_id)
  );

create policy audit_logs_delete_tenant_super_admin
  on public.audit_logs
  for delete
  to authenticated
  using (public.audit_log_has_tenant_access(tenant_id, user_id, true));

create or replace function public.list_audit_logs_for_app(
  p_date date default null::date,
  p_limit integer default 500
)
returns table(
  audit_log_id uuid,
  user_id uuid,
  nama_user text,
  user_name text,
  user_email text,
  role_id text,
  aktivitas text,
  activity text,
  modul text,
  module text,
  data_sebelum jsonb,
  before_data jsonb,
  data_sesudah jsonb,
  after_data jsonb,
  latitude numeric,
  longitude numeric,
  created_at timestamp with time zone
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tenant_id uuid;
  v_role text;
begin
  select u.tenant_id, lower(coalesce(u.role_id, ''))
    into v_tenant_id, v_role
  from public.users u
  where u.user_id = auth.uid()
    and coalesce(u.status, 'active') = 'active'
  limit 1;

  if v_tenant_id is null then
    raise exception 'User belum terhubung ke tenant aktif.';
  end if;

  if v_role not in ('super_admin', 'demo_super_admin') then
    raise exception 'Akses ditolak. Hanya super_admin yang bisa melihat audit log.';
  end if;

  return query
  select
    a.audit_log_id,
    a.user_id,
    a.nama_user,
    a.user_name,
    a.user_email,
    a.role_id,
    a.aktivitas,
    a.activity,
    a.modul,
    a.module,
    a.data_sebelum,
    a.before_data,
    a.data_sesudah,
    a.after_data,
    a.latitude,
    a.longitude,
    a.created_at
  from public.audit_logs a
  where (p_date is null or a.created_at::date = p_date)
    and (
      a.tenant_id = v_tenant_id
      or (
        a.tenant_id is null
        and exists (
          select 1
          from public.users actor_user
          where actor_user.user_id = a.user_id
            and actor_user.tenant_id = v_tenant_id
        )
      )
    )
  order by a.created_at desc
  limit greatest(1, least(coalesce(p_limit, 500), 2000));
end;
$$;

create or replace function public.delete_audit_log_for_app(p_audit_log_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tenant_id uuid;
  v_role text;
begin
  select u.tenant_id, lower(coalesce(u.role_id, ''))
    into v_tenant_id, v_role
  from public.users u
  where u.user_id = auth.uid()
    and coalesce(u.status, 'active') = 'active'
  limit 1;

  if v_tenant_id is null then
    raise exception 'User belum terhubung ke tenant aktif.';
  end if;

  if v_role <> 'super_admin' then
    raise exception 'Akses ditolak. Demo dan role selain super_admin tidak bisa menghapus audit log.';
  end if;

  delete from public.audit_logs a
  where a.audit_log_id = p_audit_log_id
    and (
      a.tenant_id = v_tenant_id
      or (
        a.tenant_id is null
        and exists (
          select 1
          from public.users actor_user
          where actor_user.user_id = a.user_id
            and actor_user.tenant_id = v_tenant_id
        )
      )
    );
end;
$$;

create or replace function public.delete_all_audit_logs_for_app()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tenant_id uuid;
  v_role text;
begin
  select u.tenant_id, lower(coalesce(u.role_id, ''))
    into v_tenant_id, v_role
  from public.users u
  where u.user_id = auth.uid()
    and coalesce(u.status, 'active') = 'active'
  limit 1;

  if v_tenant_id is null then
    raise exception 'User belum terhubung ke tenant aktif.';
  end if;

  if v_role <> 'super_admin' then
    raise exception 'Akses ditolak. Demo dan role selain super_admin tidak bisa menghapus audit log.';
  end if;

  delete from public.audit_logs a
  where a.created_at <= now() + interval '1 second'
    and (
      a.tenant_id = v_tenant_id
      or (
        a.tenant_id is null
        and exists (
          select 1
          from public.users actor_user
          where actor_user.user_id = a.user_id
            and actor_user.tenant_id = v_tenant_id
        )
      )
    );
end;
$$;

grant execute on function public.audit_log_has_tenant_access(uuid, uuid, boolean) to authenticated, service_role;
grant execute on function public.audit_log_same_tenant_for_insert(uuid) to authenticated, service_role;
grant execute on function public.list_audit_logs_for_app(date, integer) to authenticated, service_role;
grant execute on function public.delete_audit_log_for_app(uuid) to authenticated, service_role;
grant execute on function public.delete_all_audit_logs_for_app() to authenticated, service_role;
revoke execute on function public.list_audit_logs_for_app(date, integer) from anon;
revoke execute on function public.delete_audit_log_for_app(uuid) from anon;
revoke execute on function public.delete_all_audit_logs_for_app() from anon;

comment on function public.audit_log_has_tenant_access(uuid, uuid, boolean) is
'Checks audit_logs tenant access. super_admin and demo_super_admin may read their own tenant; only super_admin may delete.';

comment on function public.audit_log_same_tenant_for_insert(uuid) is
'Allows direct audit_logs insert only for the current active user tenant.';
