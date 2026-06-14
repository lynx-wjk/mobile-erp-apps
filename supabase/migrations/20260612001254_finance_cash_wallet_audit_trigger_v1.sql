-- Finance cash wallet audit guard.
-- Keeps create/update/delete on cash wallet tables visible in audit_logs.

create or replace function public.audit_finance_cash_wallet_change_v1()
returns trigger
language plpgsql
as $$
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
$$;

drop trigger if exists trg_audit_finance_cash_opening on public.finance_company_cash_opening_balances;
create trigger trg_audit_finance_cash_opening
after insert or update or delete on public.finance_company_cash_opening_balances
for each row execute function public.audit_finance_cash_wallet_change_v1();

drop trigger if exists trg_audit_finance_cash_adjustments on public.finance_company_cash_adjustments;
create trigger trg_audit_finance_cash_adjustments
after insert or update or delete on public.finance_company_cash_adjustments
for each row execute function public.audit_finance_cash_wallet_change_v1();

drop trigger if exists trg_audit_finance_marketplace_withdrawals on public.finance_marketplace_withdrawals;
create trigger trg_audit_finance_marketplace_withdrawals
after insert or update or delete on public.finance_marketplace_withdrawals
for each row execute function public.audit_finance_cash_wallet_change_v1();

drop trigger if exists trg_audit_finance_marketplace_withdrawal_allocations on public.finance_marketplace_withdrawal_allocations;
create trigger trg_audit_finance_marketplace_withdrawal_allocations
after insert or update or delete on public.finance_marketplace_withdrawal_allocations
for each row execute function public.audit_finance_cash_wallet_change_v1();

comment on function public.audit_finance_cash_wallet_change_v1() is
'Audits Finance Cash Wallet opening balance, manual cash adjustment, marketplace withdrawal, and withdrawal allocation writes.';
