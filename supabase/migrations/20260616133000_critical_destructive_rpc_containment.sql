-- Phase 3D-1B: Critical destructive RPC containment.
-- Goal:
-- - Block global destructive production reset.
-- - Block legacy module delete by ID only.
-- - Harden generic super-admin delete with tenant filter and deny risky tables.
-- - Remove anon EXECUTE from destructive RPCs.
--
-- This is containment, not cleanup. Old functions stay for dependency stability.

begin;

create or replace function public._rpc_current_user_for_write()
returns table(
  user_id uuid,
  tenant_id uuid,
  role_id text,
  normalized_role text
)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select
    u.user_id,
    u.tenant_id,
    coalesce(u.role_id, '') as role_id,
    regexp_replace(lower(coalesce(u.role_id, '')), '[^a-z0-9]+', '_', 'g') as normalized_role
  from public.users u
  where u.user_id = auth.uid()
    and coalesce(u.status, 'active') = 'active'
  limit 1;
$function$;

create or replace function public._rpc_is_tenant_admin_role(p_role text)
returns boolean
language sql
immutable
as $function$
  select coalesce(p_role, '') in ('super_admin', 'superadmin', 'admin', 'owner', 'hr');
$function$;

create or replace function public._rpc_is_platform_owner_role(p_role text)
returns boolean
language sql
immutable
as $function$
  select coalesce(p_role, '') in ('platform_owner', 'platformowner');
$function$;

create or replace function public.clear_production_progress_for_app()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  raise exception 'clear_production_progress_for_app disabled: global production delete is not allowed on multi-tenant self-host';
end;
$function$;

create or replace function public.delete_module_record(
  p_record_id uuid
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  raise exception 'delete_module_record disabled: legacy delete by id without tenant scope is not allowed';
end;
$function$;

create or replace function public.delete_record_for_super_admin(
  p_table_name text,
  p_record_id uuid
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_user record;
  v_table text := lower(trim(coalesce(p_table_name, '')));
  v_deleted int := 0;
begin
  if auth.uid() is null then
    raise exception 'User belum login';
  end if;

  select *
    into v_user
  from public._rpc_current_user_for_write()
  limit 1;

  if v_user.user_id is null then
    raise exception 'User tidak ditemukan atau nonaktif';
  end if;

  if v_user.tenant_id is null then
    raise exception 'Tenant tidak ditemukan';
  end if;

  if not public._rpc_is_tenant_admin_role(v_user.normalized_role)
     and not public._rpc_is_platform_owner_role(v_user.normalized_role) then
    raise exception 'Hanya admin tenant/platform owner yang boleh menghapus data';
  end if;

  if p_record_id is null then
    raise exception 'record_id kosong';
  end if;

  -- Explicitly blocked because these are too risky for a generic delete RPC.
  if v_table in (
    'users',
    'user',
    'attendance',
    'attendance_logs',
    'module_records',
    'production_progress',
    'products',
    'stock_transactions',
    'marketplace_orders',
    'marketplace_order_items',
    'marketplace_finance_reports',
    'marketplace_finance_items',
    'purchases',
    'purchase_items',
    'finance_operational_expenses'
  ) then
    raise exception 'Generic delete disabled for table %. Use a tenant-scoped dedicated RPC.', v_table;
  end if;

  if v_table = 'suppliers' then
    delete from public.suppliers s
    where s.supplier_id = p_record_id
      and (
        public._rpc_is_platform_owner_role(v_user.normalized_role)
        or s.tenant_id = v_user.tenant_id
      );
    get diagnostics v_deleted = row_count;

  elsif v_table = 'tasks' then
    delete from public.tasks t
    where t.task_id = p_record_id
      and (
        public._rpc_is_platform_owner_role(v_user.normalized_role)
        or t.tenant_id = v_user.tenant_id
      );
    get diagnostics v_deleted = row_count;

  elsif v_table = 'live_schedules' then
    delete from public.live_schedules l
    where l.live_schedule_id = p_record_id
      and (
        public._rpc_is_platform_owner_role(v_user.normalized_role)
        or l.tenant_id = v_user.tenant_id
      );
    get diagnostics v_deleted = row_count;

  elsif v_table = 'content_tasks' then
    delete from public.content_tasks c
    where c.content_task_id = p_record_id
      and (
        public._rpc_is_platform_owner_role(v_user.normalized_role)
        or c.tenant_id = v_user.tenant_id
      );
    get diagnostics v_deleted = row_count;

  elsif v_table = 'work_locations' then
    delete from public.work_locations w
    where w.location_id = p_record_id
      and (
        public._rpc_is_platform_owner_role(v_user.normalized_role)
        or w.tenant_id = v_user.tenant_id
      );
    get diagnostics v_deleted = row_count;

  else
    raise exception 'Table % tidak diizinkan untuk generic delete.', v_table;
  end if;

  if v_deleted = 0 then
    raise exception 'Data tidak ditemukan atau bukan milik tenant ini.';
  end if;
end;
$function$;

-- Remove public/anonymous access from destructive/high-risk functions.
-- PostgreSQL grants EXECUTE on functions to PUBLIC by default, so revoking anon alone is useless.
revoke execute on function public.clear_production_progress_for_app() from public;
revoke execute on function public.delete_module_record(uuid) from public;
revoke execute on function public.delete_record_for_super_admin(text, uuid) from public;

revoke execute on function public.clear_production_progress_for_app() from anon;
revoke execute on function public.delete_module_record(uuid) from anon;
revoke execute on function public.delete_record_for_super_admin(text, uuid) from anon;

grant execute on function public.clear_production_progress_for_app() to authenticated;
grant execute on function public.delete_module_record(uuid) to authenticated;
grant execute on function public.delete_record_for_super_admin(text, uuid) to authenticated;

notify pgrst, 'reload schema';

commit;
