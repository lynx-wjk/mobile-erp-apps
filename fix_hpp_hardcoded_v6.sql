-- Fix hardcoded HPP values in finance_dashboard_snapshot_base_20260623
-- The previous version had hardcoded HPP for shopee (129540500) and tiktok_shop (182398000)
-- This fix calculates HPP dynamically per marketplace using marketplace_variant_hpp_mappings

CREATE OR REPLACE FUNCTION public.finance_dashboard_snapshot_base_20260623(
  p_start date DEFAULT NULL,
  p_end date DEFAULT NULL,
  p_marketplace text DEFAULT NULL,
  p_account_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $fn$
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

  -- 4. Calculate Estimated HPP Belum Payout (Unpaid Orders)
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

  -- 6. Build Marketplace Cards with Dynamic HPP per marketplace
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
  -- NEW: Dynamic HPP per marketplace+account from order items x hpp mappings
  -- First get distinct orders matched to finance reports, then calc HPP
  hpp_target_fr as (
    select fr2.marketplace_account_id, fr2.marketplace_order_id, fr2.order_id
    from public.marketplace_finance_reports fr2
    where fr2.tenant_id = v_tenant_id
      and (p_account_id is null or fr2.marketplace_account_id = p_account_id)
      and coalesce(fr2.period_start::date, fr2.settlement_date::date, fr2.created_at::date) between v_start and v_end
      and fr2.order_id is not null and nullif(trim(fr2.order_id), '') is not null
      and coalesce(fr2.report_type, 'order_settlement') <> 'statement'
      and (
        v_marketplace is null
        or case
          when lower(regexp_replace(coalesce(fr2.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          when lower(regexp_replace(coalesce(fr2.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
          else lower(regexp_replace(coalesce(fr2.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end = v_marketplace
      )
  ),
  hpp_target_orders as (
    select distinct o.marketplace_order_id, o.marketplace_account_id,
      case
        when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
        else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end as norm_marketplace
    from public.marketplace_orders o
    join hpp_target_fr fr on fr.marketplace_order_id = o.marketplace_order_id
    where o.tenant_id = v_tenant_id
    union
    select distinct o.marketplace_order_id, o.marketplace_account_id,
      case
        when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
        else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end as norm_marketplace
    from public.marketplace_orders o
    join hpp_target_fr fr on fr.order_id = o.order_id
    where o.tenant_id = v_tenant_id
  ),
  hpp_sku_mp as (
    select marketplace_account_id, lower(nullif(marketplace_sku_id, '')) as sku,
           max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp
    from public.marketplace_variant_hpp_mappings
    where coalesce(is_active, true) = true and tenant_id = v_tenant_id and nullif(marketplace_sku_id, '') is not null
    group by 1, 2
  ),
  hpp_seller_mp as (
    select marketplace_account_id, lower(nullif(marketplace_seller_sku, '')) as sku,
           max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp
    from public.marketplace_variant_hpp_mappings
    where coalesce(is_active, true) = true and tenant_id = v_tenant_id and nullif(marketplace_seller_sku, '') is not null
    group by 1, 2
  ),
  hpp_per_mp as (
    select
      hto.norm_marketplace as marketplace,
      hto.marketplace_account_id,
      coalesce(sum(coalesce(oi.quantity, oi.qty, 1) * coalesce(hs.hpp, hsel.hpp, 0)), 0)::numeric as hpp_total
    from hpp_target_orders hto
    join public.marketplace_order_items oi
      on oi.tenant_id = v_tenant_id
      and oi.marketplace_order_id = hto.marketplace_order_id
    left join hpp_sku_mp hs on hs.marketplace_account_id = hto.marketplace_account_id and hs.sku = lower(nullif(oi.marketplace_sku_id, ''))
    left join hpp_seller_mp hsel on hsel.marketplace_account_id = hto.marketplace_account_id and hsel.sku = lower(nullif(oi.marketplace_seller_sku, ''))
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
      -- FIXED: Dynamic HPP from hpp_per_mp instead of hardcoded values
      coalesce(h.hpp_total, f.hpp_total, 0) as hpp_total,
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
    left join hpp_per_mp h on h.marketplace = k.marketplace and h.marketplace_account_id = k.marketplace_account_id
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
        'fee_amount', fee_amount,
        'unaccounted', greatest(0, gross_sales - finance_payout) - (platform_fee + commission_fee + affiliate_fee + shipping_fee + discount_amount + refund_amount + adjustment_amount + fee_amount)
      )
    )), '[]'::jsonb)
  into v_order_count, v_by_marketplace
  from rows;

  -- 7. Source count
  select count(distinct marketplace_account_id)::integer
  into v_source_count
  from public.marketplace_accounts
  where tenant_id = v_tenant_id
    and (p_account_id is null or marketplace_account_id = p_account_id);

  -- 8. Approved Purchases
  select coalesce(jsonb_agg(jsonb_build_object(
    'purchase_id', p.purchase_id,
    'nomor_pembelian', p.nomor_pembelian,
    'supplier_name', p.supplier_name,
    'tanggal', p.tanggal,
    'status', p.status,
    'total_pembelian', p.total_pembelian
  ) order by p.tanggal desc), '[]'::jsonb)
  into v_approved_purchases
  from public.purchases p
  where p.tanggal between v_start and v_end
    and p.tenant_id = v_tenant_id
    and lower(coalesce(p.status, '')) in ('verified_finance', 'verified', 'approved', 'paid', 'completed');

  -- 9. Manual Expenses
  select coalesce(jsonb_agg(jsonb_build_object(
    'expense_id', e.expense_id,
    'category', e.category,
    'description', e.description,
    'amount', abs(coalesce(e.amount, 0)),
    'expense_date', coalesce(e.expense_date, e.paid_at, e.created_at::date),
    'status', e.status
  ) order by coalesce(e.expense_date, e.paid_at, e.created_at::date) desc), '[]'::jsonb)
  into v_expenses
  from public.finance_operational_expenses e
  where coalesce(e.expense_date, e.paid_at, e.created_at::date)::date between v_start and v_end
    and e.tenant_id = v_tenant_id
    and lower(coalesce(e.status, 'paid')) not in ('void', 'deleted', 'cancelled', 'canceled', 'rejected', 'reject');

  -- 10. Build summary object
  v_summary := jsonb_build_object(
    'ok', true,
    'period_start', v_start,
    'period_end', v_end,
    'marketplace_filter', coalesce(v_marketplace, 'all'),
    'account_filter', coalesce(p_account_id::text, 'all'),
    'gross_total', v_gross_total,
    'omzet_total', v_gross_total,
    'payout_total', v_payout_total,
    'hpp_total', v_hpp_total,
    'expense_total', v_expense_total,
    'manual_expense_total', v_manual_expense_total,
    'purchase_cashout', v_purchase_cashout,
    'net_profit', v_net_profit,
    'margin_percent', case when v_payout_total <> 0 then round(((v_payout_total - v_hpp_total - v_expense_total) / v_payout_total) * 100, 2) else 0 end,
    'order_count', v_order_count,
    'finance_order_count', v_finance_order_count,
    'source_count', v_source_count,
    'negative_payout_count', v_negative_payout_count,
    'negative_payout_total_abs', v_negative_payout_total_abs,
    'payout_minus_count', v_negative_payout_count,
    'payout_minus_total_abs', v_negative_payout_total_abs,
    'estimated_unpaid_hpp', v_estimated_unpaid_hpp,
    'hpp_belum_payout', v_estimated_unpaid_hpp,
    'total_fees', v_total_fees,
    'platform_fee', v_platform_fee,
    'commission_fee', v_commission_fee,
    'affiliate_fee', v_affiliate_fee,
    'shipping_fee', v_shipping_fee,
    'discount_amount', v_discount_amount,
    'refund_amount', v_refund_amount,
    'adjustment_amount', v_adjustment_amount,
    'fee_amount', v_fee_amount,
    'by_marketplace', v_by_marketplace,
    'expenses', v_expenses,
    'approved_purchases', v_approved_purchases,
    'no_payout_count', 0,
    'sample_gratis_count', 0,
    'abnormal_count', 0
  );

  return v_summary;
end;
$fn$;
