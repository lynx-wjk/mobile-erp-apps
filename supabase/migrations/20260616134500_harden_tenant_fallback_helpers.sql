-- Phase 3D-1C: Harden tenant fallback helpers.
--
-- Containment target:
-- - app_safe_tenant_id_v24_6_30 must not fallback to random marketplace_accounts/orders tenant.
-- - anon must not directly execute tenant helper functions.
--
-- Intentionally not changing app_current_tenant_id_or_default() yet because many legacy
-- finance/marketplace RPCs still depend on it. That helper needs separate caller audit.

begin;

create or replace function public.app_safe_tenant_id_v24_6_30()
returns uuid
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_tenant uuid;
begin
  if auth.uid() is null then
    return null;
  end if;

  select u.tenant_id
    into v_tenant
  from public.users u
  where u.user_id = auth.uid()
    and coalesce(u.status, 'active') = 'active'
  limit 1;

  return v_tenant;
end;
$function$;

-- Remove direct anonymous access. PostgreSQL default EXECUTE comes from PUBLIC.
revoke execute on function public.app_safe_tenant_id_v24_6_30() from public;
revoke execute on function public.app_safe_tenant_id_v24_6_30() from anon;
grant execute on function public.app_safe_tenant_id_v24_6_30() to authenticated;

-- Do not allow anonymous direct calls to generic tenant helpers.
-- Internal SECURITY DEFINER functions can still call these as owner.
revoke execute on function public.app_default_tenant_id() from public;
revoke execute on function public.app_default_tenant_id() from anon;

revoke execute on function public.app_current_tenant_id_or_default() from public;
revoke execute on function public.app_current_tenant_id_or_default() from anon;
grant execute on function public.app_current_tenant_id_or_default() to authenticated;

revoke execute on function public.app_current_user_tenant_id() from public;
revoke execute on function public.app_current_user_tenant_id() from anon;
grant execute on function public.app_current_user_tenant_id() to authenticated;

notify pgrst, 'reload schema';

commit;
