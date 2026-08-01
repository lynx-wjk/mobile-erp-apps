do $$
declare
  def text;
begin
  if to_regprocedure('public.finance_dashboard_snapshot_marketplace_core_20260624(date,date,text,uuid)') is null then
    select pg_get_functiondef('public.finance_dashboard_snapshot(date,date,text,uuid)'::regprocedure)
      into def;

    def := replace(
      def,
      'FUNCTION public.finance_dashboard_snapshot(',
      'FUNCTION public.finance_dashboard_snapshot_marketplace_core_20260624('
    );

    if def = pg_get_functiondef('public.finance_dashboard_snapshot(date,date,text,uuid)'::regprocedure) then
      raise exception 'Failed to copy finance_dashboard_snapshot core function';
    end if;

    execute def;
  end if;
end $$;

create or replace function public._finance_dashboard_expense_overlay_20260624(
  p_payload jsonb,
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_start date := coalesce(p_start, date_trunc('month', now() at time zone 'Asia/Jakarta')::date);
  v_end date := coalesce(p_end, (now() at time zone 'Asia/Jakarta')::date);
  v_tenant_id uuid;

  v_expense_payload jsonb := '{}'::jsonb;
  v_manual_rows jsonb := '[]'::jsonb;

  v_operational numeric := 0;
  v_manual numeric := 0;
  v_manual_legacy numeric := 0;
  v_purchase_total numeric := 0;
  v_purchase_request_total numeric := 0;
  v_tailor_unlinked numeric := 0;

  v_helper_total numeric := 0;
  v_operational_total numeric := 0;
  v_approved_purchase_total numeric := 0;
  v_expense_total numeric := 0;

  v_payout numeric := 0;
  v_hpp numeric := 0;
  v_net_profit numeric := 0;
  v_net_margin numeric := 0;

  v_out jsonb := coalesce(p_payload, '{}'::jsonb);
  v_summary jsonb := '{}'::jsonb;
begin
  if p_account_id is not null then
    select ma.tenant_id
      into v_tenant_id
    from public.marketplace_accounts ma
    where ma.marketplace_account_id = p_account_id
    limit 1;
  end if;

  begin
    v_expense_payload := coalesce(public._finance_expenses_payload_v24_6_82e(v_start, v_end), '{}'::jsonb);
  exception when others then
    v_expense_payload := '{}'::jsonb;
  end;

  begin
    v_manual_rows := coalesce(public.finance_list_manual_operational_expenses_v24_6_80m(v_start, v_end, p_marketplace, p_account_id), '[]'::jsonb);
  exception when others then
    v_manual_rows := '[]'::jsonb;
  end;

  select coalesce(sum(e.amount), 0)
    into v_operational
  from public.finance_operational_expenses e
  where coalesce(e.expense_date, e.paid_at, e.created_at::date) between v_start and v_end
    and (v_tenant_id is null or e.tenant_id = v_tenant_id)
    and lower(coalesce(e.status, 'active')) not in ('cancelled','canceled','deleted','void','voided','rejected')
    and lower(coalesce(e.source_module, 'manual')) not in ('purchase','purchases','purchase_request','purchase_requests');

  select coalesce(sum(e.amount), 0)
    into v_manual
  from public.finance_manual_expenses e
  where e.expense_date between v_start and v_end
    and (v_tenant_id is null or e.tenant_id = v_tenant_id);

  select coalesce(sum(e.amount), 0)
    into v_manual_legacy
  from public.finance_manual_expenses_v24_6_35 e
  where e.expense_date between v_start and v_end
    and lower(coalesce(e.status, 'active')) not in ('cancelled','canceled','deleted','void','voided','rejected');

  select coalesce(sum(p.total_pembelian), 0)
    into v_purchase_total
  from public.purchases p
  where p.tanggal between v_start and v_end
    and (v_tenant_id is null or p.tenant_id = v_tenant_id)
    and lower(coalesce(p.status, '')) in ('verified','approved','paid','completed','done','selesai','finish','finished');

  select coalesce(sum(pr.total_amount), 0)
    into v_purchase_request_total
  from public.purchase_requests pr
  where pr.tanggal_beli between v_start and v_end
    and (v_tenant_id is null or pr.tenant_id = v_tenant_id)
    and lower(coalesce(pr.status, '')) in ('verified','approved','paid','completed','done','selesai','finish','finished');

  select coalesce(sum(pt.amount), 0)
    into v_tailor_unlinked
  from public.production_tailor_payments pt
  where pt.payment_date between v_start and v_end
    and (v_tenant_id is null or pt.tenant_id = v_tenant_id)
    and pt.finance_expense_id is null
    and coalesce(pt.is_voided, false) = false
    and lower(coalesce(pt.payment_status, 'paid')) not in ('cancelled','canceled','deleted','void','voided','rejected');

  v_helper_total := greatest(
    public._finance_num_safe_20260624(v_expense_payload ->> 'expense_total'),
    public._finance_num_safe_20260624(v_expense_payload ->> 'biaya_total'),
    public._finance_num_safe_20260624(v_expense_payload ->> 'operational_expense'),
    public._finance_num_safe_20260624(v_expense_payload ->> 'manual_expense_total'),
    public._finance_num_safe_20260624(v_expense_payload ->> 'approved_purchase_total')
  );

  v_operational_total := coalesce(v_operational,0) + coalesce(v_manual,0) + coalesce(v_manual_legacy,0) + coalesce(v_tailor_unlinked,0);
  v_approved_purchase_total := coalesce(v_purchase_total,0) + coalesce(v_purchase_request_total,0);

  v_expense_total := greatest(
    coalesce(v_helper_total, 0),
    coalesce(v_operational_total, 0) + coalesce(v_approved_purchase_total, 0)
  );

  v_payout := greatest(
    public._finance_num_safe_20260624(v_out ->> 'payout_total'),
    public._finance_num_safe_20260624(v_out ->> 'received_amount'),
    public._finance_num_safe_20260624(v_out ->> 'net_settlement')
  );

  v_hpp := greatest(
    public._finance_num_safe_20260624(v_out ->> 'hpp_total'),
    public._finance_num_safe_20260624(v_out ->> 'total_hpp')
  );

  v_net_profit := v_payout - v_hpp - v_expense_total;
  v_net_margin := case when v_payout > 0 then (v_net_profit / v_payout) * 100 else 0 end;

  v_out := v_out || jsonb_build_object(
    'source', coalesce(v_out ->> 'source', 'finance_dashboard_snapshot') || '+expense_overlay_20260624',

    'expense_total', v_expense_total,
    'biaya_total', v_expense_total,
    'total_expenses', v_expense_total,

    'operational_expense', v_operational_total,
    'operational_expense_total', v_operational_total,
    'operational_cost_total', v_operational_total,
    'manual_expense_total', v_operational_total,
    'manual_operational_expense', v_operational_total,

    'approved_purchase_total', v_approved_purchase_total,
    'purchase_cashout', v_approved_purchase_total,
    'purchase_expense_total', v_approved_purchase_total,

    'production_tailor_paid_total', v_tailor_unlinked,
    'paid_production_total', v_tailor_unlinked,

    'net_profit', v_net_profit,
    'profit_netto', v_net_profit,
    'laba', v_net_profit,
    'net_margin_percent', v_net_margin,
    'margin_percent', v_net_margin,

    'expenses', v_manual_rows,
    'manual_expenses', v_manual_rows,
    'operational_expenses', v_manual_rows,

    'expense_payload', v_expense_payload,
    'expense_breakdown', jsonb_build_object(
      'finance_operational_expenses', v_operational,
      'finance_manual_expenses', v_manual,
      'finance_manual_expenses_legacy', v_manual_legacy,
      'purchases', v_purchase_total,
      'purchase_requests', v_purchase_request_total,
      'production_tailor_payments_unlinked', v_tailor_unlinked,
      'operational_total', v_operational_total,
      'approved_purchase_total', v_approved_purchase_total,
      'expense_total', v_expense_total
    )
  );

  v_summary := coalesce(v_out -> 'summary', '{}'::jsonb) || jsonb_build_object(
    'expense_total', v_expense_total,
    'biaya_total', v_expense_total,
    'total_expenses', v_expense_total,
    'operational_expense', v_operational_total,
    'operational_expense_total', v_operational_total,
    'manual_expense_total', v_operational_total,
    'approved_purchase_total', v_approved_purchase_total,
    'purchase_cashout', v_approved_purchase_total,
    'production_tailor_paid_total', v_tailor_unlinked,
    'paid_production_total', v_tailor_unlinked,
    'net_profit', v_net_profit,
    'profit_netto', v_net_profit,
    'laba', v_net_profit,
    'net_margin_percent', v_net_margin,
    'margin_percent', v_net_margin
  );

  v_out := jsonb_set(v_out, '{summary}', v_summary, true);

  return v_out;
end $$;

create or replace function public.finance_dashboard_snapshot(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_core jsonb;
begin
  v_core := public.finance_dashboard_snapshot_marketplace_core_20260624(
    p_start,
    p_end,
    p_marketplace,
    p_account_id
  );

  return public._finance_dashboard_expense_overlay_20260624(
    v_core,
    p_start,
    p_end,
    p_marketplace,
    p_account_id
  );
end $$;

grant execute on function public._finance_dashboard_expense_overlay_20260624(jsonb,date,date,text,uuid)
  to anon, authenticated, service_role;

grant execute on function public.finance_dashboard_snapshot(date,date,text,uuid)
  to anon, authenticated, service_role;

notify pgrst, 'reload schema';