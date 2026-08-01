-- Migration: 20260725320000_fix_app_default_tenant_and_users_rls.sql
-- Fixes app_current_tenant_id_or_default fallback to active tenant UUID ae730499-550b-4907-bb18-bbc2629c64f4 and grants anon SELECT RLS on users

CREATE OR REPLACE FUNCTION public.app_current_tenant_id_or_default()
RETURNS uuid
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  select coalesce(
    nullif(current_setting('app.current_tenant_id', true), '')::uuid,
    'ae730499-550b-4907-bb18-bbc2629c64f4'::uuid
  );
$function$;

DROP POLICY IF EXISTS users_anon_select ON public.users;
CREATE POLICY users_anon_select ON public.users FOR SELECT TO anon USING (true);
