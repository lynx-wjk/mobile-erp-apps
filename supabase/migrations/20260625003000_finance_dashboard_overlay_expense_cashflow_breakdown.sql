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
  v_start date := coalesce(p_start, date_trunc('month', now() at time zone 'Asia/Jakarta')::date);
  v_end date := coalesce(p_end, (now() at time zone 'Asia/Jakarta')::date);
  v_marketplace text := nullif(lower(trim(coalesce(p_marketplace,''))), '');
  v_base jsonb;
  v_expenses jsonb;
  v_purchases jsonb;
  v_cash_flow jsonb;
  v_breakdown jsonb;
  v_fee jsonb;
  v_ops_total numeric := 0;
  v_purchase_total numeric := 0;
begin
  if v_marketplace in ('all','semua','_all','*') then
    v_marketplace := null;
  end if;

  v_base := public.finance_customer_dashboard_snapshot_v24_6_82o(
    v_start,
    v_end,
    v_marketplace,
    p_account_id
  );

  select coalesce(jsonb_agg(to_jsonb(e) order by coalesce(e.expense_date, e.paid_at, e.created_at::date) desc, e.created_at desc), '[]'::jsonb),
         coalesce(sum(e.amount),0)
    into v_expenses, v_ops_total
  from public.finance_operational_expenses e
  where coalesce(e.expense_date, e.paid_at, e.created_at::date) between v_start and v_end
    and lower(coalesce(e.status,'active')) not in ('cancelled','canceled','deleted','void','voided','rejected')
    and public.app_has_tenant_access(e.tenant_id);

  select coalesce(jsonb_agg(to_jsonb(p) order by coalesce(p.tanggal, p.created_at::date) desc, p.created_at desc), '[]'::jsonb),
         coalesce(sum(p.total_pembelian),0)
    into v_purchases, v_purchase_total
  from public.purchases p
  where coalesce(p.tanggal, p.created_at::date) between v_start and v_end
    and lower(coalesce(p.status,'')) in (
      'verified','verified_finance','finance_verified','approved','approved_by_finance',
      'finance_approved','paid','completed','done','selesai','finish','finished'
    )
    and public.app_has_tenant_access(p.tenant_id);

  with fee as (
    select
      coalesce(sum(platform_fee),0) as platform_fee,
      coalesce(sum(commission_fee),0) as commission_fee,
      coalesce(sum(service_fee),0) as service_fee,
      coalesce(sum(affiliate_fee),0) as affiliate_fee,
      coalesce(sum(shipping_fee),0) as shipping_fee,
      coalesce(sum(voucher_amount),0) as voucher_amount,
      coalesce(sum(discount_amount),0) as discount_amount,
      coalesce(sum(refund_amount),0) as refund_amount,
      coalesce(sum(adjustment_amount),0) as adjustment_amount
    from public.marketplace_finance_items fi
    where coalesce(fi.transaction_time::date, fi.order_created_at::date, fi.created_at::date) between v_start and v_end
      and (p_account_id is null or fi.marketplace_account_id = p_account_id)
      and (
        v_marketplace is null
        or public._finance_marketplace_norm_20260624(fi.marketplace) = public._finance_marketplace_norm_20260624(v_marketplace)
      )
  )
  select jsonb_build_object(
    'platform_fee', platform_fee,
    'commission_fee', commission_fee,
    'service_fee', service_fee,
    'affiliate_fee', affiliate_fee,
    'shipping_fee', shipping_fee,
    'voucher_amount', voucher_amount,
    'discount_amount', discount_amount,
    'refund_amount', refund_amount,
    'adjustment_amount', adjustment_amount,
    'total_deductions',
      platform_fee + commission_fee + service_fee + affiliate_fee + shipping_fee
      + voucher_amount + discount_amount + refund_amount + adjustment_amount
  )
  into v_fee
  from fee;

  v_breakdown := jsonb_build_array(
    jsonb_build_object('name','Payout diterima','type','income','amount',coalesce((v_base->'summary'->>'payout_total')::numeric,0)),
    jsonb_build_object('name','HPP','type','expense','amount',-abs(coalesce((v_base->'summary'->>'hpp_total')::numeric,0))),
    jsonb_build_object('name','Biaya operasional','type','expense','amount',-abs(v_ops_total)),
    jsonb_build_object('name','Pembelian verified finance','type','expense','amount',-abs(v_purchase_total)),
    jsonb_build_object('name','Platform fee','type','deduction','amount',coalesce((v_fee->>'platform_fee')::numeric,0)),
    jsonb_build_object('name','Commission fee','type','deduction','amount',coalesce((v_fee->>'commission_fee')::numeric,0)),
    jsonb_build_object('name','Service fee','type','deduction','amount',coalesce((v_fee->>'service_fee')::numeric,0)),
    jsonb_build_object('name','Affiliate fee','type','deduction','amount',coalesce((v_fee->>'affiliate_fee')::numeric,0)),
    jsonb_build_object('name','Shipping fee','type','deduction','amount',coalesce((v_fee->>'shipping_fee')::numeric,0)),
    jsonb_build_object('name','Voucher / diskon','type','deduction','amount',coalesce((v_fee->>'voucher_amount')::numeric,0) + coalesce((v_fee->>'discount_amount')::numeric,0)),
    jsonb_build_object('name','Refund','type','deduction','amount',coalesce((v_fee->>'refund_amount')::numeric,0)),
    jsonb_build_object('name','Adjustment','type','deduction','amount',coalesce((v_fee->>'adjustment_amount')::numeric,0))
  );

  v_cash_flow := jsonb_build_array(
    jsonb_build_object('date', v_start, 'category', 'Payout marketplace', 'type', 'income', 'amount', coalesce((v_base->'summary'->>'payout_total')::numeric,0)),
    jsonb_build_object('date', v_start, 'category', 'Biaya operasional', 'type', 'expense', 'amount', -abs(v_ops_total)),
    jsonb_build_object('date', v_start, 'category', 'Pembelian verified finance', 'type', 'expense', 'amount', -abs(v_purchase_total))
  );

  v_base := jsonb_set(v_base, '{expenses}', v_expenses, true);
  v_base := jsonb_set(v_base, '{approved_purchases}', v_purchases, true);
  v_base := jsonb_set(v_base, '{cash_flow}', v_cash_flow, true);
  v_base := jsonb_set(v_base, '{profit_loss}', v_breakdown, true);
  v_base := jsonb_set(v_base, '{deduction_breakdown}', v_breakdown, true);
  v_base := jsonb_set(v_base, '{fee_breakdown}', coalesce(v_fee,'{}'::jsonb), true);
  v_base := jsonb_set(v_base, '{summary,expense_total}', to_jsonb(v_ops_total + v_purchase_total), true);
  v_base := jsonb_set(v_base, '{summary,biaya_total}', to_jsonb(v_ops_total + v_purchase_total), true);
  v_base := jsonb_set(v_base, '{summary,operational_expense}', to_jsonb(v_ops_total), true);
  v_base := jsonb_set(v_base, '{summary,approved_purchase_total}', to_jsonb(v_purchase_total), true);
  v_base := jsonb_set(v_base, '{source}', to_jsonb(coalesce(v_base->>'source','finance_dashboard_snapshot') || '+live_expense_cashflow_breakdown_20260625'), true);

  return v_base;
end;
$$;

grant execute on function public.finance_dashboard_snapshot(date,date,text,uuid) to anon, authenticated, service_role;
notify pgrst, 'reload schema';