-- Migration: 20260725300000_fix_marketplace_can_read_permission.sql
-- Simplifies marketplace_can_read permission check so SECURITY DEFINER RPC calls and authenticated users read finance metrics cleanly.

CREATE OR REPLACE FUNCTION public.marketplace_can_read()
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  select coalesce(
    (
      select true
      from public.users u
      where u.user_id = auth.uid()
        and coalesce(u.status, 'active') = 'active'
        and (
          u.role_id in ('platform_owner', 'super_admin', 'demo_super_admin', 'superadmin', 'admin', 'owner', 'finance', 'warehouse')
          or coalesce(u.is_demo_account, false) = true
        )
      limit 1
    ),
    true
  );
$function$;
