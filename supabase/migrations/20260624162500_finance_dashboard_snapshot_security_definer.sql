-- REST/app currently calls RPC with anon apikey only.
-- Make dashboard snapshot execute as function owner so it can read finance/order tables.

alter function public.finance_dashboard_snapshot(date,date,text,uuid)
  security definer;

alter function public.finance_dashboard_snapshot(date,date,text,uuid)
  set search_path = public;

grant execute on function public.finance_dashboard_snapshot(date,date,text,uuid)
  to anon, authenticated, service_role;

grant execute on function public._finance_marketplace_norm_20260624(text)
  to anon, authenticated, service_role;

notify pgrst, 'reload schema';

select
  p.oid::regprocedure as signature,
  p.prosecdef as security_definer,
  p.proacl
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'finance_dashboard_snapshot';