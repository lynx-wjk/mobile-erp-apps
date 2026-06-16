-- Phase 3D-1C follow-up:
-- app_default_tenant_id is internal fallback helper, not a client RPC.
-- Keep it callable by owner/internal SECURITY DEFINER functions, but block direct client execution.

begin;

revoke execute on function public.app_default_tenant_id() from public;
revoke execute on function public.app_default_tenant_id() from anon;
revoke execute on function public.app_default_tenant_id() from authenticated;

notify pgrst, 'reload schema';

commit;
