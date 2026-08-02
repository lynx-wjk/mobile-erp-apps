-- v8: Fix settlement status filtering for pulled TikTok reports & purchases / marketplace_accounts column names & CTE scoping
CREATE OR REPLACE FUNCTION public.finance_dashboard_snapshot_base_20260623(
    p_tenant_id uuid,
    p_start_date date,
    p_end_date date,
    p_marketplace text DEFAULT NULL::text,
    p_account_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_tenant_id uuid := p_tenant_id;
  v_start date := coalesce(p_start_date, CURRENT_DATE - INTERVAL '30 days');
  v_end date := coalesce(p_end_date, CURRENT_DATE);
  v_marketplace text := nullif(lower(trim(p_marketplace)), '');

  v_gross_total numeric := 0;
  v_payout_total numeric := 0;
  v_finance_order_count integer := 0;

  v_total_fees numeric := 0;
  v_platform_fee numeric := 0;
  v_commission_fee numeric := 0;
  v_affiliate_fee numeric := 0;
  v_shipping_fee numeric := 0;
  v_discount_amount numeric := 0;
  v_refund_amount numeric := 0;
  v_adjustment_amount numeric := 0;
  v_fee_amount numeric := 0;

  v_negative_payout_count integer := 0;
  v_negative_payout_total_abs numeric := 0;

  v_hpp_total numeric := 0;
  v_hpp_unpaid_total numeric := 0;
  v_unpaid_order_count integer := 0;
  v_estimated_unpaid_hpp numeric := 0;

  v_manual_expense_total numeric := 0;
  v_approved_purchase_total numeric := 0;
  v_total_operational_expense numeric := 0;

  v_net_profit numeric := 0;
  v_profit_margin numeric := 0;

  v_by_marketplace jsonb := '[]'::jsonb;
  v_by_sku jsonb := '[]'::jsonb;
  v_result jsonb;
begin
  if v_tenant_id is null then
    return jsonb_build_object(
      'status', 'error',
      'message', 'tenant_id is required'
    );
  end if;

  -- 1. API Gross Omzet from marketplace_orders
  select coalesce(sum(coalesce(o.gross_amount, o.paid_amount, o.total_amount, 0)), 0)::numeric
  into v_gross_total
  from public.marketplace_orders o
  where coalesce(o.order_created_at, o.created_time, o.created_at)::date between v_start and v_end
    and o.tenant_id = v_tenant_id
    and (p_account_id is null or o.marketplace_account_id = p_account_id)
    and not (lower(concat_ws(' ', o.order_status, o.status, o.raw_order->>'status')) ~ '(cancel|canceled|cancelled|batal|dibatalkan|returned|return|refund|rts|gagal|failed|closed)')
    and (
      v_marketplace is null
      or case
        when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
        else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end = v_marketplace
    );

  -- 2. Finance Settlement Metrics from marketplace_finance_reports (Confirmed Settled Payouts)
  select
    coalesce(sum(coalesce(payout_amount, net_settlement, received_amount, 0)), 0)::numeric,
    count(distinct nullif(order_id, ''))::integer,
    coalesce(sum(coalesce(platform_fee, 0) + coalesce(commission_fee, 0) + coalesce(affiliate_fee, 0) + coalesce(shipping_fee, 0) + coalesce(fee_amount, 0)), 0)::numeric,
    coalesce(sum(coalesce(platform_fee, 0)), 0)::numeric,
    coalesce(sum(coalesce(commission_fee, 0)), 0)::numeric,
    coalesce(sum(coalesce(affiliate_fee, 0)), 0)::numeric,
    coalesce(sum(coalesce(shipping_fee, 0)), 0)::numeric,
    coalesce(sum(coalesce(discount_amount, 0)), 0)::numeric,
    coalesce(sum(coalesce(refund_amount, 0)), 0)::numeric,
    coalesce(sum(coalesce(adjustment_amount, 0)), 0)::numeric,
    coalesce(sum(coalesce(fee_amount, 0)), 0)::numeric,
    coalesce(count(*) filter (where coalesce(payout_amount, net_settlement, received_amount, 0) < 0), 0)::integer,
    coalesce(sum(abs(coalesce(payout_amount, net_settlement, received_amount, 0))) filter (where coalesce(payout_amount, net_settlement, received_amount, 0) < 0), 0)::numeric
  into
    v_payout_total, v_finance_order_count,
    v_total_fees, v_platform_fee, v_commission_fee, v_affiliate_fee, v_shipping_fee,
    v_discount_amount, v_refund_amount, v_adjustment_amount, v_fee_amount,
    v_negative_payout_count, v_negative_payout_total_abs
  from public.marketplace_finance_reports fr
  where coalesce(fr.period_start::date, fr.settlement_date::date, fr.created_at::date) between v_start and v_end
    and fr.tenant_id = v_tenant_id
    and (p_account_id is null or fr.marketplace_account_id = p_account_id)
    and fr.order_id is not null and nullif(trim(fr.order_id), '') is not null
    and coalesce(fr.report_type, 'order_settlement') <> 'statement'
    and (nullif(trim(fr.settlement_status), '') is null or lower(trim(fr.settlement_status)) not in ('unsettled', 'pending', 'waiting_settlement', 'belum_payout', 'belum_cair'))
    and (
      v_marketplace is null
      or case
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
        else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end = v_marketplace
    );

  -- 3. Dynamic HPP Calculation for Settled Orders
  with settled_fr as (
    select distinct fr.order_id, fr.marketplace_order_id
    from public.marketplace_finance_reports fr
    where coalesce(fr.period_start::date, fr.settlement_date::date, fr.created_at::date) between v_start and v_end
      and fr.tenant_id = v_tenant_id
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and fr.order_id is not null and nullif(trim(fr.order_id), '') is not null
      and coalesce(fr.report_type, 'order_settlement') <> 'statement'
      and (nullif(trim(fr.settlement_status), '') is null or lower(trim(fr.settlement_status)) not in ('unsettled', 'pending', 'waiting_settlement', 'belum_payout', 'belum_cair'))
      and (
        v_marketplace is null
        or case
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
          else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end = v_marketplace
      )
  ),
  settled_orders as (
    select o.marketplace_order_id, o.marketplace_account_id
    from public.marketplace_orders o
    join settled_fr fr on (fr.marketplace_order_id = o.marketplace_order_id or fr.order_id = o.order_id)
    where o.tenant_id = v_tenant_id
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
  ),
  hpp_sku as (
    select marketplace_account_id, lower(nullif(marketplace_sku_id, '')) as marketplace_sku_id,
           max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp
    from public.marketplace_variant_hpp_mappings
    where coalesce(is_active, true) = true and tenant_id = v_tenant_id and nullif(marketplace_sku_id, '') is not null
    group by 1, 2
  ),
  hpp_seller as (
    select marketplace_account_id, lower(nullif(marketplace_seller_sku, '')) as marketplace_seller_sku,
           max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp
    from public.marketplace_variant_hpp_mappings
    where coalesce(is_active, true) = true and tenant_id = v_tenant_id and nullif(marketplace_seller_sku, '') is not null
    group by 1, 2
  )
  select coalesce(sum(coalesce(oi.quantity, oi.qty, 1) * coalesce(hs.hpp, hsel.hpp, 0)), 0)::numeric
  into v_hpp_total
  from settled_orders so
  join public.marketplace_order_items oi on oi.tenant_id = v_tenant_id and oi.marketplace_order_id = so.marketplace_order_id
  left join hpp_sku hs on hs.marketplace_account_id = so.marketplace_account_id and hs.marketplace_sku_id = lower(nullif(oi.marketplace_sku_id, ''))
  left join hpp_seller hsel on hsel.marketplace_account_id = so.marketplace_account_id and hsel.marketplace_seller_sku = lower(nullif(oi.marketplace_seller_sku, ''));

  -- 4. Dynamic HPP Calculation for Unpaid/Unsettled Orders created in date range
  with settled_target_fr as (
    select distinct fr.order_id, fr.marketplace_order_id
    from public.marketplace_finance_reports fr
    where fr.tenant_id = v_tenant_id
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and fr.order_id is not null and nullif(trim(fr.order_id), '') is not null
      and coalesce(fr.report_type, 'order_settlement') <> 'statement'
      and (nullif(trim(fr.settlement_status), '') is null or lower(trim(fr.settlement_status)) not in ('unsettled', 'pending', 'waiting_settlement', 'belum_payout', 'belum_cair'))
  ),
  unpaid_orders as (
    select o.marketplace_order_id, o.marketplace_account_id
    from public.marketplace_orders o
    where o.tenant_id = v_tenant_id
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and coalesce(o.order_created_at, o.created_time, o.created_at)::date between v_start and v_end
      and not (lower(concat_ws(' ', o.order_status, o.status, o.raw_order->>'status')) ~ '(cancel|canceled|cancelled|batal|dibatalkan|returned|return|refund|rts|gagal|failed|closed)')
      and not exists (
        select 1 from settled_target_fr fr
        where fr.marketplace_order_id = o.marketplace_order_id or fr.order_id = o.order_id
      )
  ),
  hpp_sku as (
    select marketplace_account_id, lower(nullif(marketplace_sku_id, '')) as marketplace_sku_id,
           max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp
    from public.marketplace_variant_hpp_mappings
    where coalesce(is_active, true) = true and tenant_id = v_tenant_id and nullif(marketplace_sku_id, '') is not null
    group by 1, 2
  ),
  hpp_seller as (
    select marketplace_account_id, lower(nullif(marketplace_seller_sku, '')) as marketplace_seller_sku,
           max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp
    from public.marketplace_variant_hpp_mappings
    where coalesce(is_active, true) = true and tenant_id = v_tenant_id and nullif(marketplace_seller_sku, '') is not null
    group by 1, 2
  )
  select coalesce(sum(coalesce(oi.quantity, oi.qty, 1) * coalesce(hs.hpp, hsel.hpp, 0)), 0)::numeric
  into v_estimated_unpaid_hpp
  from unpaid_orders uo
  join public.marketplace_order_items oi on oi.tenant_id = v_tenant_id and oi.marketplace_order_id = uo.marketplace_order_id
  left join hpp_sku hs on hs.marketplace_account_id = uo.marketplace_account_id and hs.marketplace_sku_id = lower(nullif(oi.marketplace_sku_id, ''))
  left join hpp_seller hsel on hsel.marketplace_account_id = uo.marketplace_account_id and hsel.marketplace_seller_sku = lower(nullif(oi.marketplace_seller_sku, ''));

  -- 5. Operational Expenses & Approved Purchases
  select coalesce(sum(abs(coalesce(amount, 0))), 0)::numeric
  into v_manual_expense_total
  from public.finance_operational_expenses e
  where coalesce(e.expense_date, e.paid_at, e.created_at::date)::date between v_start and v_end
    and e.tenant_id = v_tenant_id
    and lower(coalesce(e.status, 'paid')) not in ('void', 'deleted', 'cancelled', 'canceled', 'rejected', 'reject');

  select coalesce(sum(coalesce(p.total_pembelian, 0)), 0)::numeric
  into v_approved_purchase_total
  from public.purchases p
  where coalesce(p.tanggal, p.created_at)::date between v_start and v_end
    and p.tenant_id = v_tenant_id
    and lower(coalesce(p.status, '')) in ('approved', 'disetujui', 'completed', 'selesai', 'paid');

  v_total_operational_expense := v_manual_expense_total + v_approved_purchase_total;

  -- 6. Net Profit & Margin
  v_net_profit := v_payout_total - v_hpp_total - v_total_operational_expense;
  if v_payout_total > 0 then
    v_profit_margin := round((v_net_profit / v_payout_total * 100.0), 2);
  else
    v_profit_margin := 0;
  end if;

  -- 7. Marketplace Breakdown CTE
  with mp_orders as (
    select
      coalesce(o.marketplace_account_id, '00000000-0000-0000-0000-000000000000'::uuid) as account_id,
      case
        when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'Shopee'
        when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'TikTok Shop'
        else coalesce(o.marketplace, 'Marketplace')
      end as mp_name,
      coalesce(acc.shop_name, acc.store_alias, o.shop_id, 'Toko') as store_name,
      count(*)::integer as order_count,
      sum(coalesce(o.gross_amount, o.paid_amount, o.total_amount, 0))::numeric as omzet
    from public.marketplace_orders o
    left join public.marketplace_accounts acc on acc.marketplace_account_id = o.marketplace_account_id
    where coalesce(o.order_created_at, o.created_time, o.created_at)::date between v_start and v_end
      and o.tenant_id = v_tenant_id
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and not (lower(concat_ws(' ', o.order_status, o.status, o.raw_order->>'status')) ~ '(cancel|canceled|cancelled|batal|dibatalkan|returned|return|refund|rts|gagal|failed|closed)')
      and (
        v_marketplace is null
        or case
          when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
          else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end = v_marketplace
      )
    group by 1, 2, 3
  ),
  mp_fr as (
    select
      coalesce(fr.marketplace_account_id, '00000000-0000-0000-0000-000000000000'::uuid) as account_id,
      sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0))::numeric as payout
    from public.marketplace_finance_reports fr
    where coalesce(fr.period_start::date, fr.settlement_date::date, fr.created_at::date) between v_start and v_end
      and fr.tenant_id = v_tenant_id
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and fr.order_id is not null and nullif(trim(fr.order_id), '') is not null
      and coalesce(fr.report_type, 'order_settlement') <> 'statement'
      and (nullif(trim(fr.settlement_status), '') is null or lower(trim(fr.settlement_status)) not in ('unsettled', 'pending', 'waiting_settlement', 'belum_payout', 'belum_cair'))
      and (
        v_marketplace is null
        or case
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
          else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end = v_marketplace
      )
    group by 1
  ),
  mp_settled_fr as (
    select distinct fr.order_id, fr.marketplace_order_id
    from public.marketplace_finance_reports fr
    where coalesce(fr.period_start::date, fr.settlement_date::date, fr.created_at::date) between v_start and v_end
      and fr.tenant_id = v_tenant_id
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and fr.order_id is not null and nullif(trim(fr.order_id), '') is not null
      and coalesce(fr.report_type, 'order_settlement') <> 'statement'
      and (nullif(trim(fr.settlement_status), '') is null or lower(trim(fr.settlement_status)) not in ('unsettled', 'pending', 'waiting_settlement', 'belum_payout', 'belum_cair'))
  ),
  mp_settled_orders as (
    select o.marketplace_order_id, o.marketplace_account_id
    from public.marketplace_orders o
    join mp_settled_fr fr on (fr.marketplace_order_id = o.marketplace_order_id or fr.order_id = o.order_id)
    where o.tenant_id = v_tenant_id
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
  ),
  hpp_sku as (
    select marketplace_account_id, lower(nullif(marketplace_sku_id, '')) as marketplace_sku_id,
           max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp
    from public.marketplace_variant_hpp_mappings
    where coalesce(is_active, true) = true and tenant_id = v_tenant_id and nullif(marketplace_sku_id, '') is not null
    group by 1, 2
  ),
  hpp_seller as (
    select marketplace_account_id, lower(nullif(marketplace_seller_sku, '')) as marketplace_seller_sku,
           max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp
    from public.marketplace_variant_hpp_mappings
    where coalesce(is_active, true) = true and tenant_id = v_tenant_id and nullif(marketplace_seller_sku, '') is not null
    group by 1, 2
  ),
  mp_hpp as (
    select
      so.marketplace_account_id as account_id,
      sum(coalesce(oi.quantity, oi.qty, 1) * coalesce(hs.hpp, hsel.hpp, 0))::numeric as hpp
    from mp_settled_orders so
    join public.marketplace_order_items oi on oi.tenant_id = v_tenant_id and oi.marketplace_order_id = so.marketplace_order_id
    left join hpp_sku hs on hs.marketplace_account_id = so.marketplace_account_id and hs.marketplace_sku_id = lower(nullif(oi.marketplace_sku_id, ''))
    left join hpp_seller hsel on hsel.marketplace_account_id = so.marketplace_account_id and hsel.marketplace_seller_sku = lower(nullif(oi.marketplace_seller_sku, ''))
    group by 1
  )
  select jsonb_agg(
    jsonb_build_object(
      'account_id', mo.account_id,
      'marketplace', mo.mp_name,
      'channel', mo.mp_name,
      'store_name', mo.store_name,
      'account_name', mo.store_name,
      'order_count', mo.order_count,
      'total_orders', mo.order_count,
      'gross_total', mo.omzet,
      'omzet', mo.omzet,
      'omzet_total', mo.omzet,
      'payout_total', coalesce(mf.payout, 0),
      'payout', coalesce(mf.payout, 0),
      'net_settlement', coalesce(mf.payout, 0),
      'hpp_total', coalesce(mh.hpp, 0),
      'hpp', coalesce(mh.hpp, 0),
      'net_profit', coalesce(mf.payout, 0) - coalesce(mh.hpp, 0),
      'laba', coalesce(mf.payout, 0) - coalesce(mh.hpp, 0),
      'profit_margin', case when coalesce(mf.payout, 0) > 0 then round(((coalesce(mf.payout, 0) - coalesce(mh.hpp, 0)) / coalesce(mf.payout, 0) * 100.0), 2) else 0 end,
      'margin', case when coalesce(mf.payout, 0) > 0 then round(((coalesce(mf.payout, 0) - coalesce(mh.hpp, 0)) / coalesce(mf.payout, 0) * 100.0), 2) else 0 end
    )
  )
  into v_by_marketplace
  from mp_orders mo
  left join mp_fr mf on mf.account_id = mo.account_id
  left join mp_hpp mh on mh.account_id = mo.account_id;

  -- Build final JSON
  v_result := jsonb_build_object(
    'status', 'success',
    'period_start', v_start,
    'period_end', v_end,
    'gross_total', v_gross_total,
    'omzet_total', v_gross_total,
    'payout_total', v_payout_total,
    'hpp_total', v_hpp_total,
    'total_fees', v_total_fees,
    'platform_fee', v_platform_fee,
    'commission_fee', v_commission_fee,
    'affiliate_fee', v_affiliate_fee,
    'shipping_fee', v_shipping_fee,
    'discount_amount', v_discount_amount,
    'refund_amount', v_refund_amount,
    'adjustment_amount', v_adjustment_amount,
    'fee_amount', v_fee_amount,
    'negative_payout_count', v_negative_payout_count,
    'negative_payout_total_abs', v_negative_payout_total_abs,
    'manual_expense_total', v_manual_expense_total,
    'approved_purchase_total', v_approved_purchase_total,
    'total_operational_expense', v_total_operational_expense,
    'estimated_unpaid_hpp', v_estimated_unpaid_hpp,
    'hpp_belum_payout', v_estimated_unpaid_hpp,
    'net_profit', v_net_profit,
    'profit_margin', v_profit_margin,
    'by_marketplace', coalesce(v_by_marketplace, '[]'::jsonb),
    'by_sku', '[]'::jsonb
  );

  return v_result;
end;
$function$;
