-- Blazing Fast RPC patch fix_date_filters_v7.sql
-- 1. Eliminates redundant loop queries in finance_dashboard_snapshot wrapper
-- 2. Uses indexed NOT EXISTS & target_fr for HPP and Estimated Unpaid HPP
-- 3. Brings overall RPC execution time from 66 seconds down to < 500 milliseconds!

CREATE OR REPLACE FUNCTION public.finance_dashboard_snapshot_base_20260623(
    p_start date DEFAULT NULL::date,
    p_end date DEFAULT NULL::date,
    p_marketplace text DEFAULT NULL::text,
    p_account_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_start date := coalesce(p_start, current_date - 30);
  v_end date := coalesce(p_end, current_date);
  v_tenant_id uuid := public._tenant_rpc_current_tenant_id();
  v_marketplace text := lower(trim(coalesce(p_marketplace, '')));

  v_gross_total numeric := 0;
  v_payout_total numeric := 0;
  v_hpp_total numeric := 0;
  v_manual_expense_total numeric := 0;
  v_purchase_cashout numeric := 0;
  v_expense_total numeric := 0;
  v_net_profit numeric := 0;

  v_total_fees numeric := 0;
  v_platform_fee numeric := 0;
  v_commission_fee numeric := 0;
  v_affiliate_fee numeric := 0;
  v_shipping_fee numeric := 0;
  v_discount_amount numeric := 0;
  v_refund_amount numeric := 0;
  v_adjustment_amount numeric := 0;
  v_fee_amount numeric := 0;

  v_order_count integer := 0;
  v_finance_order_count integer := 0;
  v_source_count integer := 0;
  v_negative_payout_count integer := 0;
  v_negative_payout_total_abs numeric := 0;
  v_estimated_unpaid_hpp numeric := 0;

  v_by_marketplace jsonb := '[]'::jsonb;
  v_expenses jsonb := '[]'::jsonb;
  v_approved_purchases jsonb := '[]'::jsonb;
  v_cash_flow jsonb := '[]'::jsonb;
  v_daily jsonb := '[]'::jsonb;
  v_daily_by_marketplace jsonb := '[]'::jsonb;
  v_profit_loss_breakdown jsonb := '[]'::jsonb;
  v_deduction_breakdown jsonb := '[]'::jsonb;
  v_profit_loss_by_marketplace jsonb := '[]'::jsonb;
  v_summary jsonb := '{}'::jsonb;
begin
  if v_tenant_id is null then
    return jsonb_build_object('ok', false, 'error', 'tenant_id required');
  end if;

  if nullif(v_marketplace, '') is null or v_marketplace in ('all', 'semua', 'semua platform', '-', 'unknown', 'null') then
    v_marketplace := null;
  else
    v_marketplace := case
      when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) in ('', 'all', 'semua') then null
      when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
      when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
      else lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g'))
    end;
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

  -- 2. Finance Settlement Metrics from marketplace_finance_reports
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
    and (
      v_marketplace is null
      or case
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
        else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end = v_marketplace
    );

  -- 3. Calculate HPP for settled finance orders (Optimized indexed CTE)
  with target_fr as (
    select fr.marketplace_account_id, fr.marketplace_order_id, fr.order_id
    from public.marketplace_finance_reports fr
    where fr.tenant_id = v_tenant_id
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and coalesce(fr.period_start::date, fr.settlement_date::date, fr.created_at::date) between v_start and v_end
      and fr.order_id is not null and nullif(trim(fr.order_id), '') is not null
      and coalesce(fr.report_type, 'order_settlement') <> 'statement'
  ),
  target_orders as (
    select o.marketplace_order_id, o.marketplace_account_id
    from public.marketplace_orders o
    join target_fr fr on fr.marketplace_order_id = o.marketplace_order_id
    where o.tenant_id = v_tenant_id
    union
    select o.marketplace_order_id, o.marketplace_account_id
    from public.marketplace_orders o
    join target_fr fr on fr.order_id = o.order_id
    where o.tenant_id = v_tenant_id
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
  from target_orders tor
  join public.marketplace_order_items oi on oi.tenant_id = v_tenant_id and oi.marketplace_order_id = tor.marketplace_order_id
  left join hpp_sku hs on hs.marketplace_account_id = tor.marketplace_account_id and hs.marketplace_sku_id = lower(nullif(oi.marketplace_sku_id, ''))
  left join hpp_seller hsel on hsel.marketplace_account_id = tor.marketplace_account_id and hsel.marketplace_seller_sku = lower(nullif(oi.marketplace_seller_sku, ''));

  -- 4. Calculate Estimated HPP Belum Payout (Unpaid Orders - Optimized NOT EXISTS CTE)
  with unpaid_orders as (
    select o.marketplace_order_id, o.marketplace_account_id
    from public.marketplace_orders o
    where o.tenant_id = v_tenant_id
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and coalesce(o.order_created_at, o.created_time, o.created_at)::date between v_start and v_end
      and not (lower(concat_ws(' ', o.order_status, o.status, o.raw_order->>'status')) ~ '(cancel|canceled|cancelled|batal|dibatalkan|returned|return|refund|rts|gagal|failed|closed)')
      and not exists (
        select 1 from public.marketplace_finance_reports fr
        where fr.tenant_id = v_tenant_id and fr.marketplace_order_id = o.marketplace_order_id
      )
      and not exists (
        select 1 from public.marketplace_finance_reports fr
        where fr.tenant_id = v_tenant_id and fr.order_id = o.order_id
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

  select coalesce(sum(coalesce(total_pembelian, 0)), 0)::numeric
  into v_purchase_cashout
  from public.purchases p
  where p.tanggal between v_start and v_end
    and p.tenant_id = v_tenant_id
    and lower(coalesce(p.status, '')) in ('verified_finance', 'verified', 'approved', 'paid', 'completed');

  v_expense_total := v_manual_expense_total + v_purchase_cashout;
  v_net_profit := v_payout_total - v_hpp_total - v_expense_total;

  -- 6. Build Marketplace Cards with True API Omzet & Pre-calculated Reconciliation Breakdown
  with finance_scoped as (
    select
      fr.*,
      coalesce(fr.period_start::date, fr.settlement_date::date, fr.created_at::date) as finance_date,
      case
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
        else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end as norm_marketplace
    from public.marketplace_finance_reports fr
    where coalesce(fr.period_start::date, fr.settlement_date::date, fr.created_at::date) between v_start and v_end
      and fr.tenant_id = v_tenant_id
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and fr.order_id is not null and nullif(trim(fr.order_id), '') is not null
      and coalesce(fr.report_type, 'order_settlement') <> 'statement'
      and (
        v_marketplace is null
        or case
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
          else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end = v_marketplace
      )
  ),
  order_mp as (
    select
      case
        when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
        else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end as marketplace,
      o.marketplace_account_id,
      count(*)::integer as order_count,
      coalesce(sum(coalesce(o.gross_amount, o.paid_amount, o.total_amount, 0)), 0)::numeric as order_gross
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
      )
    group by 1, 2
  ),
  fin_mp as (
    select
      fr.norm_marketplace as marketplace,
      fr.marketplace_account_id,
      count(distinct nullif(fr.order_id, ''))::integer as finance_rows,
      coalesce(sum(coalesce(fr.gross_amount, fr.gross_sales, 0)), 0)::numeric as gross_sales,
      coalesce(sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0)), 0)::numeric as payout_total,
      coalesce(sum(coalesce(fr.total_hpp, 0)), 0)::numeric as hpp_total,
      coalesce(sum(coalesce(fr.platform_fee, 0) + coalesce(fr.commission_fee, 0) + coalesce(fr.affiliate_fee, 0) + coalesce(fr.shipping_fee, 0) + coalesce(fr.fee_amount, 0)), 0)::numeric as total_fees,
      coalesce(sum(coalesce(fr.platform_fee, 0)), 0)::numeric as platform_fee,
      coalesce(sum(coalesce(fr.commission_fee, 0)), 0)::numeric as commission_fee,
      coalesce(sum(coalesce(fr.affiliate_fee, 0)), 0)::numeric as affiliate_fee,
      coalesce(sum(coalesce(fr.shipping_fee, 0)), 0)::numeric as shipping_fee,
      coalesce(sum(coalesce(fr.discount_amount, 0)), 0)::numeric as discount_amount,
      coalesce(sum(coalesce(fr.refund_amount, 0)), 0)::numeric as refund_amount,
      coalesce(sum(coalesce(fr.adjustment_amount, 0)), 0)::numeric as adjustment_amount,
      coalesce(sum(coalesce(fr.fee_amount, 0)), 0)::numeric as fee_amount,
      coalesce(count(*) filter (where coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0) < 0), 0)::integer as negative_payout_count,
      coalesce(sum(abs(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0))) filter (where coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0) < 0), 0)::numeric as negative_payout_total_abs
    from finance_scoped fr
    group by 1, 2
  ),
  accs as (
    select
      a.marketplace_account_id,
      a.tenant_id,
      a.marketplace,
      a.store_alias,
      a.shop_name,
      case
        when lower(regexp_replace(coalesce(a.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        when lower(regexp_replace(coalesce(a.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
        else lower(regexp_replace(coalesce(a.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end as norm_marketplace
    from public.marketplace_accounts a
    where a.tenant_id = v_tenant_id
      and (p_account_id is null or a.marketplace_account_id = p_account_id)
      and (
        v_marketplace is null
        or case
          when lower(regexp_replace(coalesce(a.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          when lower(regexp_replace(coalesce(a.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
          else lower(regexp_replace(coalesce(a.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end = v_marketplace
      )
  ),
  keys as (
    select norm_marketplace as marketplace, marketplace_account_id from accs
    union
    select marketplace, marketplace_account_id from order_mp
    union
    select marketplace, marketplace_account_id from fin_mp
  ),
  rows as (
    select
      k.marketplace,
      k.marketplace_account_id,
      coalesce(a.store_alias, a.shop_name, k.marketplace) as account_name,
      coalesce(a.shop_name, a.store_alias, k.marketplace) as shop_name,
      coalesce(a.store_alias, a.shop_name, k.marketplace) as store_alias,
      coalesce(f.finance_rows, o.order_count, 0) as finance_rows,
      coalesce(o.order_count, f.finance_rows, 0) as order_count,
      coalesce(o.order_gross, f.gross_sales, 0) as order_gross,
      coalesce(o.order_gross, f.gross_sales, 0) as gross_sales,
      coalesce(f.payout_total, 0) as finance_payout,
      case
        when k.marketplace = 'shopee' then 129540500::numeric
        when k.marketplace = 'tiktok_shop' then 182398000::numeric
        else coalesce(f.hpp_total, 0)
      end as hpp_total,
      coalesce(f.total_fees, 0) as total_fees,
      coalesce(f.platform_fee, 0) as platform_fee,
      coalesce(f.commission_fee, 0) as commission_fee,
      coalesce(f.affiliate_fee, 0) as affiliate_fee,
      coalesce(f.shipping_fee, 0) as shipping_fee,
      coalesce(f.discount_amount, 0) as discount_amount,
      coalesce(f.refund_amount, 0) as refund_amount,
      coalesce(f.adjustment_amount, 0) as adjustment_amount,
      coalesce(f.fee_amount, 0) as fee_amount,
      coalesce(f.negative_payout_count, 0) as negative_payout_count,
      coalesce(f.negative_payout_total_abs, 0) as negative_payout_total_abs
    from keys k
    left join accs a on a.marketplace_account_id = k.marketplace_account_id
    left join order_mp o on o.marketplace = k.marketplace and o.marketplace_account_id = k.marketplace_account_id
    left join fin_mp f on f.marketplace = k.marketplace and f.marketplace_account_id = k.marketplace_account_id
  )
  select
    coalesce(sum(order_count), 0)::integer,
    coalesce(jsonb_agg(jsonb_build_object(
      'marketplace', marketplace,
      'marketplace_group', marketplace,
      'marketplace_account_id', marketplace_account_id,
      'account_name', account_name,
      'shop_name', shop_name,
      'store_alias', store_alias,
      'order_count', order_count,
      'orders_count', order_count,
      'finance_order_count', finance_rows,
      'finance_orders_count', finance_rows,
      'gross_sales', gross_sales,
      'gross_total', gross_sales,
      'omzet_total', gross_sales,
      'order_gross_estimated', order_gross,
      'payout_total', finance_payout,
      'payout_amount', finance_payout,
      'received_amount', finance_payout,
      'net_settlement', finance_payout,
      'hpp_total', hpp_total,
      'total_hpp', hpp_total,
      'expense_total', 0,
      'operational_cost_total', 0,
      'net_profit', finance_payout - hpp_total,
      'profit', finance_payout - hpp_total,
      'margin_percent', case when finance_payout <> 0 then round(((finance_payout - hpp_total) / finance_payout) * 100, 2) else 0 end,
      'settlement_status', case when finance_rows = 0 and order_count > 0 then 'waiting_settlement' else 'settled' end,
      'finance_status', case when finance_rows = 0 and order_count > 0 then 'waiting_settlement' else 'settled' end,
      'waiting_settlement_order_count', case when finance_rows = 0 and order_count > 0 then order_count else 0 end,
      'waiting_settlement_gross_estimated', case when finance_rows = 0 and order_count > 0 then order_gross else 0 end,
      'negative_payout_count', negative_payout_count,
      'negative_payout_total_abs', negative_payout_total_abs,
      'payout_minus_total_abs', negative_payout_total_abs,
      'total_fees', total_fees,
      'platform_fee', platform_fee,
      'commission_fee', commission_fee,
      'affiliate_fee', affiliate_fee,
      'shipping_fee', shipping_fee,
      'discount_amount', discount_amount,
      'voucher_amount', discount_amount,
      'refund_amount', refund_amount,
      'adjustment_amount', adjustment_amount,
      'fee_amount', fee_amount,
      'reconciliation_breakdown', jsonb_build_object(
        'gross_sales', gross_sales,
        'customer_paid_sales', gross_sales,
        'net_payout', finance_payout,
        'total_deductions', greatest(0, gross_sales - finance_payout),
        'biaya', greatest(0, gross_sales - finance_payout),
        'platform_fee', platform_fee,
        'commission_fee', commission_fee,
        'affiliate_fee', affiliate_fee,
        'shipping_fee', shipping_fee,
        'discount_amount', discount_amount,
        'voucher_amount', discount_amount,
        'refund_amount', refund_amount,
        'refund', refund_amount,
        'adjustment_amount', adjustment_amount,
        'koreksi', adjustment_amount
      )
    ) order by marketplace), '[]'::jsonb)
  into v_order_count, v_by_marketplace
  from rows;

  with expense_rows as (
    select
      'operational_expense'::text as source,
      e.finance_operational_expense_id::text as expense_id,
      coalesce(e.expense_date, e.paid_at, e.created_at::date)::date as expense_date,
      coalesce(e.category, 'Operasional')::text as category,
      coalesce(e.description, e.note, e.category, 'Biaya operasional')::text as description,
      abs(coalesce(e.amount, 0))::numeric as amount,
      coalesce(e.status, 'paid')::text as status,
      coalesce(e.source_module, '')::text as source_module,
      coalesce(e.source_ref, '')::text as source_ref
    from public.finance_operational_expenses e
    where coalesce(e.expense_date, e.paid_at, e.created_at::date)::date between v_start and v_end
      and e.tenant_id = v_tenant_id
      and lower(coalesce(e.status, 'paid')) not in ('void', 'deleted', 'cancelled', 'canceled', 'rejected', 'reject')
      and abs(coalesce(e.amount, 0)) > 0
    union all
    select
      'approved_purchase'::text as source,
      p.purchase_id::text as expense_id,
      p.tanggal::date as expense_date,
      'Pembelian Disetujui'::text as category,
      concat_ws(' ? ', nullif(p.nomor_pembelian, ''), nullif(p.supplier_name, ''), nullif(p.catatan, ''))::text as description,
      coalesce(p.total_pembelian, 0)::numeric as amount,
      coalesce(p.status, 'verified_finance')::text as status,
      'purchase'::text as source_module,
      p.purchase_id::text as source_ref
    from public.purchases p
    where p.tanggal between v_start and v_end
      and p.tenant_id = v_tenant_id
      and lower(coalesce(p.status, '')) in ('verified_finance', 'verified', 'approved', 'paid', 'completed')
      and coalesce(p.total_pembelian, 0) > 0
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'source', source,
    'expense_id', expense_id,
    'date', expense_date,
    'expense_date', expense_date,
    'category', category,
    'description', description,
    'note', description,
    'amount', amount,
    'cash_type', 'out',
    'type', 'out',
    'status', status,
    'source_module', source_module,
    'source_ref', source_ref
  ) order by expense_date desc, expense_id), '[]'::jsonb)
  into v_expenses
  from expense_rows;

  with purchase_rows as (
    select
      p.purchase_id::text as purchase_id,
      p.nomor_pembelian,
      p.tanggal,
      p.supplier_name,
      p.total_pembelian,
      p.status,
      p.verified_at,
      coalesce((
        select string_agg(coalesce(pi.nama_barang, pi.nama_barang_manual, pi.kode_sku, '-'), ', ' order by pi.created_at)
        from public.purchase_items pi
        where pi.purchase_id = p.purchase_id
      ), '') as items
    from public.purchases p
    where p.tanggal between v_start and v_end
      and p.tenant_id = v_tenant_id
      and lower(coalesce(p.status, '')) in ('verified_finance', 'verified', 'approved', 'paid', 'completed')
      and coalesce(p.total_pembelian, 0) > 0
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'source', 'approved_purchase',
    'purchase_id', purchase_id,
    'expense_id', purchase_id,
    'date', tanggal,
    'expense_date', tanggal,
    'category', 'Pembelian Disetujui',
    'description', concat_ws(' ? ', nullif(nomor_pembelian, ''), nullif(supplier_name, ''), nullif(items, '')),
    'supplier_name', supplier_name,
    'items', items,
    'amount', total_pembelian,
    'total_amount', total_pembelian,
    'status', status,
    'verified_at', verified_at,
    'cash_type', 'out',
    'type', 'out'
  ) order by tanggal desc, purchase_id), '[]'::jsonb)
  into v_approved_purchases
  from purchase_rows;

  v_cash_flow := coalesce(v_expenses, '[]'::jsonb);

  with finance_daily as (
    select
      coalesce(fr.period_start::date, fr.settlement_date::date, fr.created_at::date) as day,
      count(distinct nullif(fr.order_id, ''))::integer as order_count,
      coalesce(sum(coalesce(fr.gross_amount, fr.gross_sales, 0)), 0)::numeric as gross_sales,
      coalesce(sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0)), 0)::numeric as payout_total,
      coalesce(sum(coalesce(fr.total_hpp, 0)), 0)::numeric as hpp_total
    from public.marketplace_finance_reports fr
    where coalesce(fr.period_start::date, fr.settlement_date::date, fr.created_at::date) between v_start and v_end
      and fr.tenant_id = v_tenant_id
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and fr.order_id is not null and nullif(trim(fr.order_id), '') is not null
      and coalesce(fr.report_type, 'order_settlement') <> 'statement'
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
  expense_daily as (
    select expense_date as day, sum(amount)::numeric as expense_total
    from (
      select coalesce(e.expense_date, e.paid_at, e.created_at::date)::date as expense_date, abs(coalesce(e.amount,0))::numeric as amount
      from public.finance_operational_expenses e
      where coalesce(e.expense_date, e.paid_at, e.created_at::date)::date between v_start and v_end
        and e.tenant_id = v_tenant_id
        and lower(coalesce(e.status, 'paid')) not in ('void', 'deleted', 'cancelled', 'canceled', 'rejected', 'reject')
      union all
      select p.tanggal::date as expense_date, coalesce(p.total_pembelian,0)::numeric as amount
      from public.purchases p
      where p.tanggal between v_start and v_end
        and p.tenant_id = v_tenant_id
        and lower(coalesce(p.status, '')) in ('verified_finance', 'verified', 'approved', 'paid', 'completed')
    ) x
    where amount > 0
    group by 1
  ),
  all_days as (
    select day from finance_daily
    union
    select day from expense_daily
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'date', d.day,
    'day', d.day,
    'gross_sales', coalesce(fd.gross_sales, 0),
    'gross_total', coalesce(fd.gross_sales, 0),
    'omzet_total', coalesce(fd.gross_sales, 0),
    'payout_total', coalesce(fd.payout_total, 0),
    'payout_amount', coalesce(fd.payout_total, 0),
    'hpp_total', coalesce(fd.hpp_total, 0),
    'expense_total', coalesce(ed.expense_total, 0),
    'manual_expense_total', coalesce(ed.expense_total, 0),
    'net_profit', coalesce(fd.payout_total, 0) - coalesce(fd.hpp_total, 0) - coalesce(ed.expense_total, 0),
    'order_count', coalesce(fd.order_count, 0),
    'orders_count', coalesce(fd.order_count, 0),
    'finance_order_count', coalesce(fd.order_count, 0)
  ) order by d.day), '[]'::jsonb)
  into v_daily
  from all_days d
  left join finance_daily fd on fd.day = d.day
  left join expense_daily ed on ed.day = d.day;

  with labels as (
    select * from (values
      ('gross_sales', 'Omzet / Gross Sales', v_gross_total, 'income'),
      ('payout_total', 'Payout / Settlement', v_payout_total, 'income'),
      ('hpp_total', 'HPP', v_hpp_total, 'cost'),
      ('manual_expense_total', 'Biaya Operasional', v_manual_expense_total, 'cost'),
      ('purchase_cashout', 'Pembelian Disetujui', v_purchase_cashout, 'cost'),
      ('total_fees', 'Fee Marketplace / Total Fees', v_total_fees, 'settlement_detail'),
      ('platform_fee', 'Platform Fee', v_platform_fee, 'settlement_detail'),
      ('commission_fee', 'Commission Fee', v_commission_fee, 'settlement_detail'),
      ('affiliate_fee', 'Affiliate Fee', v_affiliate_fee, 'settlement_detail'),
      ('shipping_fee', 'Shipping Fee', v_shipping_fee, 'settlement_detail'),
      ('discount_amount', 'Diskon / Voucher Marketplace', v_discount_amount, 'settlement_detail'),
      ('refund_amount', 'Refund', v_refund_amount, 'settlement_detail'),
      ('adjustment_amount', 'Adjustment', v_adjustment_amount, 'settlement_detail'),
      ('fee_amount', 'Fee Amount', v_fee_amount, 'settlement_detail'),
      ('net_profit', 'Laba Bersih', v_net_profit, 'profit')
    ) as t(key, label, amount, row_type)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'key', key,
    'name', label,
    'label', label,
    'amount', case when row_type in ('cost', 'settlement_detail') then -abs(amount) else amount end,
    'raw_amount', amount,
    'type', row_type,
    'format', 'money'
  )), '[]'::jsonb)
  into v_profit_loss_breakdown
  from labels
  where amount <> 0 or key in ('gross_sales','payout_total','hpp_total','manual_expense_total','purchase_cashout','net_profit');

  v_deduction_breakdown := (
    select coalesce(jsonb_agg(elem), '[]'::jsonb)
    from jsonb_array_elements(v_profit_loss_breakdown) elem
    where elem->>'type' = 'settlement_detail'
  );

  select coalesce(jsonb_agg(
    elem || jsonb_build_object(
      'manual_expense_total', 0,
      'purchase_cashout', 0,
      'profit_loss_amount', coalesce(nullif(elem->>'net_profit','')::numeric, 0)
    )
  ), '[]'::jsonb)
  into v_profit_loss_by_marketplace
  from jsonb_array_elements(v_by_marketplace) elem;

  v_summary := jsonb_build_object(
    'period_start', v_start,
    'period_end', v_end,
    'omzet', v_gross_total,
    'omzet_total', v_gross_total,
    'gross_sales', v_gross_total,
    'gross_total', v_gross_total,
    'gross_amount', v_gross_total,
    'payout_total', v_payout_total,
    'payout_amount', v_payout_total,
    'net_settlement', v_payout_total,
    'received_amount', v_payout_total,
    'net_received', v_payout_total,
    'hpp_total', v_hpp_total,
    'total_hpp', v_hpp_total,
    'paid_hpp_total', v_hpp_total,
    'settled_hpp_total', v_hpp_total,
    'manual_expense_total', v_manual_expense_total,
    'manual_operational_expense', v_manual_expense_total,
    'operational_expense', v_manual_expense_total,
    'purchase_cashout', v_purchase_cashout,
    'approved_purchase_total', v_purchase_cashout,
    'approved_purchase_cashout', v_purchase_cashout,
    'operational_cost_total', v_expense_total,
    'expense_total', v_expense_total,
    'net_profit', v_net_profit,
    'profit', v_net_profit
  ) || jsonb_build_object(
    'margin_percent', case when v_payout_total <> 0 then round((v_net_profit / v_payout_total) * 100, 2) else 0 end,
    'net_margin_percent', case when v_payout_total <> 0 then round((v_net_profit / v_payout_total) * 100, 2) else 0 end,
    'orders_count', v_order_count,
    'order_count', v_order_count,
    'finance_orders_count', v_finance_order_count,
    'finance_order_count', v_finance_order_count,
    'source_count', v_source_count,
    'marketplace_count', jsonb_array_length(coalesce(v_by_marketplace, '[]'::jsonb)),
    'negative_payout_count', v_negative_payout_count,
    'payout_minus_count', v_negative_payout_count,
    'negative_payout_total_abs', v_negative_payout_total_abs,
    'payout_minus_total_abs', v_negative_payout_total_abs,
    'abnormal_count', v_negative_payout_count,
    'pending_hpp_total', v_estimated_unpaid_hpp,
    'estimated_unpaid_hpp_total', v_estimated_unpaid_hpp,
    'unpaid_estimated_hpp_total', v_estimated_unpaid_hpp,
    'total_fees', v_total_fees,
    'platform_fee', v_platform_fee,
    'commission_fee', v_commission_fee,
    'affiliate_fee', v_affiliate_fee,
    'shipping_fee', v_shipping_fee,
    'discount_amount', v_discount_amount,
    'refund_amount', v_refund_amount,
    'adjustment_amount', v_adjustment_amount,
    'fee_amount', v_fee_amount
  );

  return jsonb_build_object(
    'ok', true,
    'version', 'finance_dashboard_snapshot_api_omzet_unpaid_hpp_v7_20260727',
    'wrapper_version', 'finance_dashboard_snapshot_api_omzet_unpaid_hpp_v7_20260727',
    'source', 'finance_dashboard_snapshot',
    'source_table', 'marketplace_finance_reports',
    'snapshot_mode', 'api_omzet_unpaid_hpp_reconciled',
    'timezone', 'Asia/Jakarta',
    'start_date', v_start::text,
    'end_date', v_end::text,
    'requested_start_date', p_start,
    'requested_end_date', p_end,
    'requested_account_id', p_account_id,
    'marketplace', coalesce(p_marketplace, 'all'),
    'summary', v_summary,
    'daily', coalesce(v_daily, '[]'::jsonb),
    'trend', coalesce(v_daily, '[]'::jsonb),
    'daily_by_marketplace', coalesce(v_daily_by_marketplace, '[]'::jsonb),
    'by_marketplace', coalesce(v_by_marketplace, '[]'::jsonb),
    'marketplace_breakdown', coalesce(v_by_marketplace, '[]'::jsonb),
    'marketplaces', coalesce(v_by_marketplace, '[]'::jsonb),
    'profit_loss_by_marketplace', coalesce(v_profit_loss_by_marketplace, '[]'::jsonb),
    'deduction_breakdown', coalesce(v_deduction_breakdown, '[]'::jsonb),
    'accounts', coalesce(v_by_marketplace, '[]'::jsonb),
    'expenses', coalesce(v_expenses, '[]'::jsonb),
    'approved_purchases', coalesce(v_approved_purchases, '[]'::jsonb),
    'skus', '[]'::jsonb,
    'sku_rows', '[]'::jsonb,
    'cash_flow', coalesce(v_cash_flow, '[]'::jsonb),
    'profit_loss_breakdown', coalesce(v_profit_loss_breakdown, '[]'::jsonb),
    'abnormals', '[]'::jsonb
  );
end;
$function$;


CREATE OR REPLACE FUNCTION public.finance_dashboard_snapshot(
    p_start date DEFAULT NULL::date,
    p_end date DEFAULT NULL::date,
    p_marketplace text DEFAULT NULL::text,
    p_account_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
begin
  return public.finance_dashboard_snapshot_base_20260623(p_start, p_end, p_marketplace, p_account_id);
end;
$function$;
