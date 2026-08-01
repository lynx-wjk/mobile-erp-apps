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
  v_marketplace_norm text := public._finance_marketplace_norm_20260624(p_marketplace);
  v_apply_company_expense boolean := (
    p_account_id is null
    and coalesce(v_marketplace_norm, '') in ('', 'all')
  );

  v_manual_total numeric := 0;
  v_purchase_total numeric := 0;
  v_tailor_total numeric := 0;
  v_expense_total numeric := 0;

  v_manual_op numeric := 0;
  v_manual_legacy numeric := 0;
  v_purchase_op numeric := 0;
  v_purchase_table numeric := 0;
  v_purchase_request numeric := 0;
  v_tailor_op numeric := 0;
  v_tailor_unlinked numeric := 0;

  v_payout numeric := 0;
  v_hpp numeric := 0;
  v_net_profit numeric := 0;
  v_net_margin numeric := 0;

  v_out jsonb := coalesce(p_payload, '{}'::jsonb);
  v_summary jsonb := '{}'::jsonb;
begin
  if v_apply_company_expense then
    select coalesce(sum(e.amount), 0)
      into v_manual_op
    from public.finance_operational_expenses e
    where coalesce(e.expense_date, e.paid_at, e.created_at::date) between v_start and v_end
      and lower(coalesce(e.status, 'active')) not in ('cancelled','canceled','deleted','void','voided','rejected')
      and lower(coalesce(e.source_module, 'manual')) not in (
        'purchase','purchases','purchase_request','purchase_requests',
        'production','production_tailor','tailor','tailor_payment','production_payment'
      );

    select coalesce(sum(e.amount), 0)
      into v_manual_legacy
    from public.finance_manual_expenses_v24_6_35 e
    where e.expense_date between v_start and v_end
      and lower(coalesce(e.status, 'active')) not in ('cancelled','canceled','deleted','void','voided','rejected');

    -- Legacy hanya fallback, bukan dijumlahkan, karena terbukti mirror 7.250.000.
    v_manual_total := case
      when coalesce(v_manual_op, 0) > 0 then v_manual_op
      else coalesce(v_manual_legacy, 0)
    end;

    select coalesce(sum(e.amount), 0)
      into v_purchase_op
    from public.finance_operational_expenses e
    where coalesce(e.expense_date, e.paid_at, e.created_at::date) between v_start and v_end
      and lower(coalesce(e.status, 'active')) not in ('cancelled','canceled','deleted','void','voided','rejected')
      and lower(coalesce(e.source_module, '')) in ('purchase','purchases','purchase_request','purchase_requests');

    select coalesce(sum(p.total_pembelian), 0)
      into v_purchase_table
    from public.purchases p
    where coalesce(p.tanggal, p.verified_at::date, p.created_at::date) between v_start and v_end
      and lower(coalesce(p.status, '')) in (
        'verified',
        'verified_finance',
        'finance_verified',
        'approved',
        'approved_by_finance',
        'finance_approved',
        'paid',
        'completed',
        'done',
        'selesai',
        'finish',
        'finished'
      );

    select coalesce(sum(pr.total_amount), 0)
      into v_purchase_request
    from public.purchase_requests pr
    where coalesce(pr.tanggal_beli, pr.verified_at::date, pr.created_at::date) between v_start and v_end
      and lower(coalesce(pr.status, '')) in (
        'verified',
        'verified_finance',
        'finance_verified',
        'approved',
        'approved_by_finance',
        'finance_approved',
        'paid',
        'completed',
        'done',
        'selesai',
        'finish',
        'finished'
      );

    -- Jangan double count kalau purchase juga sudah mirror ke finance_operational_expenses.
    v_purchase_total := greatest(
      coalesce(v_purchase_op, 0),
      coalesce(v_purchase_table, 0) + coalesce(v_purchase_request, 0)
    );

    select coalesce(sum(e.amount), 0)
      into v_tailor_op
    from public.finance_operational_expenses e
    where coalesce(e.expense_date, e.paid_at, e.created_at::date) between v_start and v_end
      and lower(coalesce(e.status, 'active')) not in ('cancelled','canceled','deleted','void','voided','rejected')
      and lower(coalesce(e.source_module, '')) in (
        'production','production_tailor','tailor','tailor_payment','production_payment'
      );

    select coalesce(sum(pt.amount), 0)
      into v_tailor_unlinked
    from public.production_tailor_payments pt
    where pt.payment_date between v_start and v_end
      and pt.finance_expense_id is null
      and coalesce(pt.is_voided, false) = false
      and lower(coalesce(pt.payment_status, 'paid')) not in ('cancelled','canceled','deleted','void','voided','rejected');

    v_tailor_total := coalesce(v_tailor_op, 0) + coalesce(v_tailor_unlinked, 0);

    v_expense_total := coalesce(v_manual_total, 0)
      + coalesce(v_purchase_total, 0)
      + coalesce(v_tailor_total, 0);
  end if;

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
    'source', regexp_replace(coalesce(v_out ->> 'source', 'finance_dashboard_snapshot'), '\+expense_[a-z0-9_]+_20260624$', '') || '+expense_split_verified_purchase_20260624',

    'manual_expense_total', v_manual_total,
    'manual_operational_expense', v_manual_total,
    'operational_expense', v_manual_total,
    'operational_expense_total', v_manual_total,
    'operational_cost_total', v_manual_total,

    'approved_purchase_total', v_purchase_total,
    'purchase_cashout', v_purchase_total,
    'purchase_expense_total', v_purchase_total,

    'production_tailor_paid_total', v_tailor_total,
    'paid_production_total', v_tailor_total,

    'expense_total', v_expense_total,
    'biaya_total', v_expense_total,
    'total_expenses', v_expense_total,

    'net_profit', v_net_profit,
    'profit_netto', v_net_profit,
    'laba', v_net_profit,
    'net_margin_percent', v_net_margin,
    'margin_percent', v_net_margin,

    'expense_breakdown', jsonb_build_object(
      'manual_expense_total', v_manual_total,
      'approved_purchase_total', v_purchase_total,
      'production_tailor_paid_total', v_tailor_total,
      'expense_total', v_expense_total,
      'debug_manual_operational', v_manual_op,
      'debug_manual_legacy_fallback_only', v_manual_legacy,
      'debug_purchase_operational', v_purchase_op,
      'debug_purchases', v_purchase_table,
      'debug_purchase_requests', v_purchase_request,
      'debug_tailor_operational', v_tailor_op,
      'debug_tailor_unlinked', v_tailor_unlinked,
      'company_expense_applied', v_apply_company_expense
    )
  );

  v_summary := coalesce(v_out -> 'summary', '{}'::jsonb) || jsonb_build_object(
    'manual_expense_total', v_manual_total,
    'manual_operational_expense', v_manual_total,
    'operational_expense', v_manual_total,
    'approved_purchase_total', v_purchase_total,
    'purchase_cashout', v_purchase_total,
    'production_tailor_paid_total', v_tailor_total,
    'paid_production_total', v_tailor_total,
    'expense_total', v_expense_total,
    'biaya_total', v_expense_total,
    'total_expenses', v_expense_total,
    'net_profit', v_net_profit,
    'profit_netto', v_net_profit,
    'laba', v_net_profit,
    'net_margin_percent', v_net_margin,
    'margin_percent', v_net_margin
  );

  return jsonb_set(v_out, '{summary}', v_summary, true);
end $$;

grant execute on function public._finance_dashboard_expense_overlay_20260624(jsonb,date,date,text,uuid)
  to anon, authenticated, service_role;

notify pgrst, 'reload schema';