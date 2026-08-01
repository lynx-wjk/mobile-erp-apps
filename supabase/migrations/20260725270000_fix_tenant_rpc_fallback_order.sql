-- Migration: 20260725270000_fix_tenant_rpc_fallback_order.sql
-- Fixes _tenant_rpc_current_tenant_id fallback order so active tenant with orders is selected instead of dummy default UUID.

CREATE OR REPLACE FUNCTION public._tenant_rpc_current_tenant_id()
RETURNS uuid
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  select coalesce(
    nullif(current_setting('app.current_tenant_id', true), '')::uuid,
    (select tenant_id from public.users where user_id = auth.uid() and coalesce(status, 'active') = 'active' limit 1),
    (select tenant_id from public.marketplace_orders where tenant_id is not null limit 1),
    (select tenant_id from public.users where tenant_id is not null limit 1),
    public.app_current_tenant_id_or_default()
  );
$function$;
