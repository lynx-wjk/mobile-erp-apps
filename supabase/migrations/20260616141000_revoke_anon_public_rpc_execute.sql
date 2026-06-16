-- Phase 3D-1E-A:
-- Revoke anonymous/public EXECUTE on public RPC functions.
--
-- Why:
-- PostgreSQL grants EXECUTE on functions to PUBLIC by default.
-- That made many SECURITY DEFINER / destructive / maintenance RPCs callable by anon.
--
-- Policy:
-- - anon: only tiny public bootstrap allowlist
-- - authenticated: keep execute on existing functions to avoid breaking app flows
-- - future functions: no PUBLIC execute by default

begin;

do $$
declare
  r record;
  v_oid oid;
  v_allowlist text[] := array[
    'public.check_invite(text)',
    'public.accept_invite(text,text,text,text)',
    'public.list_public_subscription_plans()'
  ];
  v_sig text;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
  loop
    execute format('revoke execute on function %s from public', r.sig);
    execute format('revoke execute on function %s from anon', r.sig);
    execute format('grant execute on function %s to authenticated', r.sig);
  end loop;

  foreach v_sig in array v_allowlist loop
    v_oid := to_regprocedure(v_sig);
    if v_oid is not null then
      execute format('grant execute on function %s to anon', v_oid::regprocedure);
    end if;
  end loop;
end $$;

alter default privileges in schema public revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from anon;
alter default privileges in schema public grant execute on functions to authenticated;

notify pgrst, 'reload schema';

commit;
