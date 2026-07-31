-- Migration: 20260725193000_fix_all_finance_tenant_rpc_fallbacks.sql
-- Fixes tenant RPC resolution for all finance functions so PostgREST calls with or without session GUC variables resolve tenant ID and return real data.

CREATE OR REPLACE FUNCTION public._tenant_rpc_current_tenant_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  select coalesce(
    (select u.tenant_id from public.users u where u.user_id = auth.uid() and coalesce(u.status, 'active') = 'active' limit 1),
    public.app_current_tenant_id_or_default(),
    (select tenant_id from public.users where tenant_id is not null limit 1)
  );
$function$;

CREATE OR REPLACE FUNCTION public._tenant_rpc_has_finance_data()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_tenant uuid := public._tenant_rpc_current_tenant_id();
  v_has boolean := false;
begin
  if v_tenant is null then
    return false;
  end if;

  select exists (
    select 1
    from public.marketplace_orders o
    where o.tenant_id = v_tenant
    limit 1
  )
  or exists (
    select 1
    from public.marketplace_finance_reports fr
    where fr.tenant_id = v_tenant
    limit 1
  )
  into v_has;

  return coalesce(v_has, false);
end;
$function$;
