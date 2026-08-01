-- Audit: RPC Dependencies and Candidate Unused Functions (Read-Only)
-- Target: C:\Users\budic\Downloads\android\inventory_control_apps\supabase\sql\audit_rpc_dependencies_readonly.sql

-- 1. List all custom functions in the public schema with arguments and return types
select
  p.proname as function_name,
  pg_catalog.pg_get_function_arguments(p.oid) as function_arguments,
  pg_catalog.pg_get_function_result(p.oid) as result_type,
  n.nspname as schema_name,
  case
    when p.prosecdef then 'security definer'
    else 'security invoker'
  end as security_type,
  l.lanname as language,
  p.provolatile as volatility
from pg_catalog.pg_proc p
left join pg_catalog.pg_namespace n on n.oid = p.pronamespace
left join pg_catalog.pg_language l on l.oid = p.prolang
where n.nspname = 'public'
  and l.lanname in ('plpgsql', 'sql')
order by p.proname asc;

-- 2. Audit potential candidate unused / legacy functions by pattern mismatch
-- We check for older versions or duplicates that are no longer referenced in latest codebase
select
  p.proname as function_name,
  pg_catalog.pg_get_function_arguments(p.oid) as function_arguments,
  p.prosrc as source_code
from pg_catalog.pg_proc p
left join pg_catalog.pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and (
    p.proname like '%_v2%'
    or p.proname like '%_v3%'
    or p.proname like '%_fallback%'
    or p.proname like '%_old%'
    or p.proname like '%_legacy%'
  )
order by p.proname asc;
