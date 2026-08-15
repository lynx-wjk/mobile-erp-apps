-- Migration: Update Finance Dashboard Snapshot Breakdown Metrics
-- Migration ID: 20260815222000_update_snapshot_breakdown_metrics.sql
-- Aggregates real commission, platform fee, shipping, affiliate, discount, and refund values per marketplace

CREATE OR REPLACE FUNCTION public.finance_dashboard_snapshot_base_20260623(
  p_tenant_id uuid,
  p_start date DEFAULT NULL::date,
  p_end date DEFAULT NULL::date,
  p_marketplace text DEFAULT NULL::text,
  p_account_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_tenant_id uuid := p_tenant_id;
  v_start date := coalesce(p_start, current_date - 30);
  v_end date := coalesce(p_end, current_date);
  v_is_past_period boolean := (v_end < date_trunc('month', current_date)::date);
  v_start_ts timestamp with time zone := (v_start::text || ' 00:00:00+07')::timestamp with time zone;
  v_end_ts timestamp with time zone := ((v_end + 1)::text || ' 00:00:00+07')::timestamp with time zone;
  v_marketplace text := lower(trim(coalesce(p_marketplace, '')));

  v_gross_sales numeric := 0;
  v_omzet_paid numeric := 0;
  v_payout_total numeric := 0;
  v_hpp_settled numeric := 0;
  v_unpaid_hpp numeric := 0;
  v_hpp_total numeric := 0;
  v_platform_fee numeric := 0;
  v_commission_fee numeric := 0;
  v_shipping_fee numeric := 0;
  v_affiliate_fee numeric := 0;
  v_discount_amount numeric := 0;
  v_adjustment_amount numeric := 0;
  v_total_fees numeric := 0;
  v_refund_total numeric := 0;

  v_op_expense_purchases numeric := 0;
  v_op_expense_manual numeric := 0;
  v_total_op_expense numeric := 0;

  v_net_profit numeric := 0;
  v_profit_margin numeric := 0;
  v_by_marketplace jsonb := '[]'::jsonb;
begin
  if v_tenant_id is null then
    select tenant_id into v_tenant_id from public.marketplace_orders limit 1;
  end if;

  if nullif(v_marketplace, '') is null or v_marketplace in ('all', 'semua', 'semua platform', '-', 'unknown', 'null') then
    v_marketplace := null;
  else
    v_marketplace := case
      when v_marketplace ~ 'tiktok' then 'tiktok_shop'
      when v_marketplace ~ 'shopee' then 'shopee'
      else regexp_replace(v_marketplace, '[^a-z0-9]+', '', 'g')
    end;
  end if;

  with orders_scope as (
    select
      o.marketplace_order_id,
      o.marketplace_account_id,
      o.marketplace,
      coalesce(nullif(o.external_order_id, ''), nullif(o.order_sn, ''), o.marketplace_order_id::text) as order_key,
      coalesce(nullif(o.gross_amount, 0), o.paid_amount, o.total_amount, 0)::numeric as gross_amt,
      coalesce(o.paid_amount, o.total_amount, 0)::numeric as paid_amt
    from public.marketplace_orders o
    where o.tenant_id = v_tenant_id
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and (coalesce(o.order_created_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date between v_start and v_end
      and not (lower(coalesce(o.order_status, o.status, '')) ~ '(cancel|canceled|cancelled|batal|dibatalkan|returned|return|refund|rts|gagal|failed|closed)')
      and (v_marketplace is null or lower(coalesce(o.marketplace, '')) = v_marketplace)
  ),
  finance_reports_matched as (
    select
      os.marketplace_order_id,
      sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0))::numeric as payout,
      sum(coalesce(fr.platform_fee, 0))::numeric as platform_fee,
      sum(coalesce(fr.commission_fee, 0))::numeric as commission_fee,
      sum(coalesce(fr.shipping_fee, 0))::numeric as shipping_fee,
      sum(coalesce(fr.affiliate_fee, 0))::numeric as affiliate_fee,
      sum(coalesce(fr.discount_amount, 0))::numeric as discount_amount,
      sum(coalesce(fr.adjustment_amount, 0))::numeric as adjustment_amount,
      sum(coalesce(fr.total_fees, fr.fee_amount, 0))::numeric as total_fees,
      sum(coalesce(fr.refund_amount, fr.total_refund, 0))::numeric as refund_amount
    from orders_scope os
    join public.marketplace_finance_reports fr
      on fr.tenant_id = v_tenant_id
     and (fr.marketplace_order_id = os.marketplace_order_id or fr.order_id = os.order_key)
    where coalesce(fr.report_type, 'order_settlement') <> 'statement'
      and coalesce(fr.status, 'pulled') <> 'draft'
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and (v_marketplace is null or lower(coalesce(fr.marketplace, '')) = v_marketplace)
    group by os.marketplace_order_id
  ),
  item_hpp as (
    select
      oi.marketplace_order_id,
      sum(coalesce(oi.quantity, oi.qty, 1) * coalesce(hs.hpp, hl.hpp, 0))::numeric as hpp_val
    from public.marketplace_order_items oi
    join orders_scope os on os.marketplace_order_id = oi.marketplace_order_id
    left join (
      select lower(nullif(marketplace_sku_id, '')) as sku_id,
             max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp
      from public.marketplace_variant_hpp_mappings
      where tenant_id = v_tenant_id and coalesce(is_active, true) = true and nullif(marketplace_sku_id, '') is not null
      group by 1
    ) hs on hs.sku_id = lower(trim(oi.marketplace_sku_id))
    left join (
      select lower(nullif(local_sku, '')) as local_sku,
             max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp
      from public.marketplace_variant_hpp_mappings
      where tenant_id = v_tenant_id and coalesce(is_active, true) = true and nullif(local_sku, '') is not null
      group by 1
    ) hl on hl.local_sku = lower(trim(coalesce(oi.local_sku, oi.seller_sku, oi.marketplace_seller_sku)))
    where oi.tenant_id = v_tenant_id
    group by oi.marketplace_order_id
  ),
  mkt_summary as (
    select
      os.marketplace,
      count(distinct os.marketplace_order_id) as order_count,
      sum(os.gross_amt) as gross_sales,
      sum(os.paid_amt) as omzet_paid,
      sum(coalesce(fr.payout, 0)) as payout_total,
      sum(coalesce(fr.platform_fee, 0)) as platform_fee,
      sum(coalesce(fr.commission_fee, 0)) as commission_fee,
      sum(coalesce(fr.shipping_fee, 0)) as shipping_fee,
      sum(coalesce(fr.affiliate_fee, 0)) as affiliate_fee,
      sum(coalesce(fr.discount_amount, 0)) as discount_amount,
      sum(coalesce(fr.adjustment_amount, 0)) as adjustment_amount,
      sum(coalesce(fr.total_fees, 0)) as total_fees,
      sum(coalesce(fr.refund_amount, 0)) as refund_total,
      sum(coalesce(ih.hpp_val, 0)) as hpp_total,
      sum(case when v_is_past_period or (fr.payout is not null and fr.payout <> 0) then coalesce(ih.hpp_val, 0) else 0 end) as hpp_settled,
      sum(case when not v_is_past_period and (fr.payout is null or fr.payout = 0) then coalesce(ih.hpp_val, 0) else 0 end) as unpaid_hpp
    from orders_scope os
    left join finance_reports_matched fr on fr.marketplace_order_id = os.marketplace_order_id
    left join item_hpp ih on ih.marketplace_order_id = os.marketplace_order_id
    group by os.marketplace
  )
  select
    coalesce(sum(gross_sales), 0),
    coalesce(sum(omzet_paid), 0),
    coalesce(sum(payout_total), 0),
    coalesce(sum(platform_fee), 0),
    coalesce(sum(commission_fee), 0),
    coalesce(sum(shipping_fee), 0),
    coalesce(sum(affiliate_fee), 0),
    coalesce(sum(discount_amount), 0),
    coalesce(sum(adjustment_amount), 0),
    coalesce(sum(total_fees), 0),
    coalesce(sum(refund_total), 0),
    coalesce(sum(hpp_total), 0),
    coalesce(sum(hpp_settled), 0),
    coalesce(sum(unpaid_hpp), 0),
    coalesce(jsonb_agg(jsonb_build_object(
      'marketplace', m.marketplace,
      'shop_name', case when m.marketplace ~ 'tiktok' then 'TikTok Shop' when m.marketplace ~ 'shopee' then 'Shopee' else m.marketplace end,
      'order_count', m.order_count,
      'gross_sales', m.gross_sales,
      'gross_original', m.gross_sales,
      'omzet_paid', m.omzet_paid,
      'omzet_normal_paid', m.omzet_paid,
      'seller_discount', case when m.discount_amount > 0 then m.discount_amount else greatest(m.gross_sales - m.omzet_paid, 0) end,
      'discount_amount', case when m.discount_amount > 0 then m.discount_amount else greatest(m.gross_sales - m.omzet_paid, 0) end,
      'voucher_amount', case when m.discount_amount > 0 then m.discount_amount else greatest(m.gross_sales - m.omzet_paid, 0) end,
      'payout_total', round(m.payout_total, 2),
      'payout_amount', round(m.payout_total, 2),
      'received_amount', round(m.payout_total, 2),
      'platform_fee', round(m.platform_fee, 2),
      'commission_fee', round(m.commission_fee, 2),
      'shipping_fee', round(m.shipping_fee, 2),
      'affiliate_fee', round(m.affiliate_fee, 2),
      'adjustment_amount', round(m.adjustment_amount, 2),
      'total_fees', round(m.total_fees, 2),
      'fee_amount', round(m.total_fees, 2),
      'refund_total', round(m.refund_total, 2),
      'refund_amount', round(m.refund_total, 2),
      'hpp_total', m.hpp_total,
      'total_hpp', m.hpp_total,
      'hpp_settled', m.hpp_settled,
      'paid_hpp_total', m.hpp_settled,
      'settled_hpp_total', m.hpp_settled,
      'unpaid_hpp', m.unpaid_hpp,
      'unpaid_hpp_total', m.unpaid_hpp,
      'net_profit', round(m.payout_total - m.hpp_settled, 2),
      'profit', round(m.payout_total - m.hpp_settled, 2),
      'profit_margin', case when m.payout_total > 0 then round(((m.payout_total - m.hpp_settled) / m.payout_total * 100)::numeric, 2) else 0 end,
      'margin_percent', case when m.payout_total > 0 then round(((m.payout_total - m.hpp_settled) / m.payout_total * 100)::numeric, 2) else 0 end
    )), '[]'::jsonb)
  into
    v_gross_sales, v_omzet_paid, v_payout_total,
    v_platform_fee, v_commission_fee, v_shipping_fee, v_affiliate_fee,
    v_discount_amount, v_adjustment_amount, v_total_fees, v_refund_total,
    v_hpp_total, v_hpp_settled, v_unpaid_hpp, v_by_marketplace
  from mkt_summary m;

  select coalesce(sum(coalesce(total_pembelian, 0)), 0)::numeric
  into v_op_expense_purchases
  from public.purchases
  where tenant_id = v_tenant_id
    and coalesce(status, 'APPROVED') in ('APPROVED', 'COMPLETED', 'LUNAS', 'PAID', 'RECEIVED')
    and tanggal between v_start and v_end;

  select coalesce(sum(coalesce(amount, 0)), 0)::numeric
  into v_op_expense_manual
  from public.finance_operational_expenses
  where tenant_id = v_tenant_id
    and expense_date between v_start and v_end;

  v_total_op_expense := v_op_expense_purchases + v_op_expense_manual;
  v_net_profit := v_payout_total - v_hpp_settled - v_total_op_expense;
  v_profit_margin := case when v_payout_total > 0 then round(((v_net_profit / v_payout_total) * 100)::numeric, 2) else 0 end;

  return jsonb_build_object(
    'status', 'success',
    'ok', true,
    'period_start', v_start,
    'period_end', v_end,
    'gross_sales', v_gross_sales,
    'gross_original', v_gross_sales,
    'omzet_paid', v_omzet_paid,
    'omzet_normal_paid', v_omzet_paid,
    'seller_discount', case when v_discount_amount > 0 then v_discount_amount else greatest(v_gross_sales - v_omzet_paid, 0) end,
    'discount_amount', v_discount_amount,
    'voucher_amount', v_discount_amount,
    'payout_total', round(v_payout_total, 2),
    'payout_amount', round(v_payout_total, 2),
    'received_amount', round(v_payout_total, 2),
    'platform_fee', round(v_platform_fee, 2),
    'commission_fee', round(v_commission_fee, 2),
    'shipping_fee', round(v_shipping_fee, 2),
    'affiliate_fee', round(v_affiliate_fee, 2),
    'adjustment_amount', round(v_adjustment_amount, 2),
    'total_fees', round(v_total_fees, 2),
    'fee_amount', round(v_total_fees, 2),
    'refund_total', round(v_refund_total, 2),
    'refund_amount', round(v_refund_total, 2),
    'hpp_total', v_hpp_total,
    'total_hpp', v_hpp_total,
    'hpp_settled', v_hpp_settled,
    'paid_hpp_total', v_hpp_settled,
    'settled_hpp_total', v_hpp_settled,
    'unpaid_hpp', v_unpaid_hpp,
    'unpaid_hpp_total', v_unpaid_hpp,
    'op_expense_purchases', v_op_expense_purchases,
    'op_expense_manual', v_op_expense_manual,
    'total_op_expense', v_total_op_expense,
    'net_profit', round(v_net_profit, 2),
    'profit_margin', v_profit_margin,
    'marketplaces', v_by_marketplace,
    'by_marketplace', v_by_marketplace,
    'marketplace_breakdown', v_by_marketplace,
    'profit_loss_by_marketplace', v_by_marketplace
  );
end;
$function$;
