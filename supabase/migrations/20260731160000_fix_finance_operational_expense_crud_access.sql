-- Migration: Fix finance operational expense update and delete access checks
-- Allows updating/deleting operational expenses when tenant matches app_current_tenant_id_or_default()
-- or when authenticated user is active platform_owner/super_admin.

CREATE OR REPLACE FUNCTION public.finance_update_manual_operational_expense(
  p_expense_id uuid,
  p_category text,
  p_amount numeric,
  p_expense_date date,
  p_note text DEFAULT NULL::text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
declare
  v_tenant_id uuid := public.app_current_tenant_id_or_default();
  v_row public.finance_operational_expenses%rowtype;
begin
  if p_expense_id is null then
    raise exception 'expense_id wajib diisi';
  end if;
  if coalesce(p_amount, 0) <= 0 then
    raise exception 'amount wajib lebih dari 0';
  end if;

  update public.finance_operational_expenses e
  set
    category = nullif(trim(coalesce(p_category, e.category)), ''),
    description = coalesce(nullif(trim(coalesce(p_category, e.description)), ''), e.description),
    amount = p_amount,
    expense_date = coalesce(p_expense_date, e.expense_date),
    paid_at = coalesce(p_expense_date, e.paid_at),
    note = nullif(trim(coalesce(p_note, e.note)), ''),
    updated_at = now()
  where (e.expense_id = p_expense_id or e.finance_operational_expense_id = p_expense_id)
    and (
      e.tenant_id = v_tenant_id
      or exists (
        select 1
        from public.users u
        where u.user_id = auth.uid()
          and u.status = 'active'
          and (u.role_id in ('platform_owner', 'super_admin') or u.tenant_id = e.tenant_id)
      )
    )
  returning * into v_row;

  if not found then
    raise exception 'Biaya operasional tidak ditemukan atau akses ditolak: %', p_expense_id;
  end if;

  return jsonb_build_object('ok', true, 'data', to_jsonb(v_row));
end;
$$;

CREATE OR REPLACE FUNCTION public.finance_delete_manual_operational_expense(
  p_expense_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
declare
  v_tenant_id uuid := public.app_current_tenant_id_or_default();
  v_deleted public.finance_operational_expenses%rowtype;
begin
  if p_expense_id is null then
    raise exception 'expense_id wajib diisi';
  end if;

  update public.production_tailor_payments
     set finance_expense_id = null,
         updated_at = now()
   where (tenant_id = v_tenant_id or tenant_id is null)
     and finance_expense_id = p_expense_id;

  delete from public.finance_operational_expenses e
  where (e.expense_id = p_expense_id or e.finance_operational_expense_id = p_expense_id)
    and (
      e.tenant_id = v_tenant_id
      or exists (
        select 1
        from public.users u
        where u.user_id = auth.uid()
          and u.status = 'active'
          and (u.role_id in ('platform_owner', 'super_admin') or u.tenant_id = e.tenant_id)
      )
    )
  returning * into v_deleted;

  if not found then
    raise exception 'Biaya operasional tidak ditemukan atau akses ditolak: %', p_expense_id;
  end if;

  return jsonb_build_object('ok', true, 'deleted', to_jsonb(v_deleted));
end;
$$;
