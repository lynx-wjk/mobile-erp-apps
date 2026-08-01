-- 9I-I canonical finance cash/wallet audit trigger function.
-- Repoints finance cash/wallet audit triggers from audit_finance_cash_wallet_change_v1()
-- to audit_finance_cash_wallet_change().
-- Old *_v1 function is intentionally kept; no DROP FUNCTION here.
-- This does not change finance formulas, payout, HPP, omzet, or reporting logic.

create or replace function public.audit_finance_cash_wallet_change()
returns trigger
language plpgsql
as $function$
declare
  v_before jsonb := null;
  v_after jsonb := null;
  v_tenant_id uuid := null;
  v_user_id uuid := auth.uid();
  v_user_name text := null;
  v_user_email text := null;
  v_role_id text := null;
  v_action text := lower(TG_OP) || '_' || TG_TABLE_NAME;
begin
  if TG_OP in ('UPDATE', 'DELETE') then
    v_before := to_jsonb(OLD);
    v_tenant_id := OLD.tenant_id;
  end if;

  if TG_OP in ('INSERT', 'UPDATE') then
    v_after := to_jsonb(NEW);
    v_tenant_id := NEW.tenant_id;
  end if;

  if v_user_id is not null then
    select u.nama, u.email, u.role_id
      into v_user_name, v_user_email, v_role_id
      from public.users u
     where u.user_id = v_user_id
     limit 1;
  end if;

  begin
    insert into public.audit_logs (
      user_id,
      nama_user,
      role_id,
      aktivitas,
      modul,
      data_sebelum,
      data_sesudah,
      created_at,
      user_name,
      user_email,
      activity,
      module,
      before_data,
      after_data,
      tenant_id
    )
    values (
      v_user_id,
      coalesce(v_user_name, v_user_email, 'system'),
      v_role_id,
      v_action,
      'finance_cash_wallet',
      v_before,
      v_after,
      now(),
      coalesce(v_user_name, v_user_email, 'system'),
      v_user_email,
      v_action,
      'finance_cash_wallet',
      v_before,
      v_after,
      v_tenant_id
    );
  exception when others then
    null;
  end;

  if TG_OP = 'DELETE' then
    return OLD;
  end if;

  return NEW;
end;
$function$;

do $$
declare
  r record;
  v_def text;
begin
  for r in
    select *
    from (
      values
        ('finance_company_cash_adjustments', 'trg_audit_finance_cash_adjustments'),
        ('finance_company_cash_opening_balances', 'trg_audit_finance_cash_opening'),
        ('finance_marketplace_withdrawal_allocations', 'trg_audit_finance_marketplace_withdrawal_allocations'),
        ('finance_marketplace_withdrawals', 'trg_audit_finance_marketplace_withdrawals')
    ) as x(table_name, trigger_name)
  loop
    select pg_get_triggerdef(t.oid, true)
      into v_def
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = r.table_name
      and t.tgname = r.trigger_name
      and not t.tgisinternal;

    if v_def is null then
      raise exception 'Trigger not found: %.%', r.table_name, r.trigger_name;
    end if;

    execute format('drop trigger if exists %I on public.%I', r.trigger_name, r.table_name);

    v_def := replace(
      v_def,
      'EXECUTE FUNCTION audit_finance_cash_wallet_change_v1()',
      'EXECUTE FUNCTION public.audit_finance_cash_wallet_change()'
    );

    v_def := replace(
      v_def,
      'EXECUTE FUNCTION public.audit_finance_cash_wallet_change_v1()',
      'EXECUTE FUNCTION public.audit_finance_cash_wallet_change()'
    );

    execute v_def;
  end loop;
end $$;

notify pgrst, 'reload schema';
