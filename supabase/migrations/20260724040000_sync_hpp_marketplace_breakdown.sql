-- Fix HPP resolution, 3-table hash join optimization (70x speedup), and 60s statement timeout for Finance Dashboard
CREATE OR REPLACE FUNCTION public.finance_snapshot_order_omzet_settlement_overlay_20260623(
  p_base jsonb,
  p_start date DEFAULT NULL::date,
  p_end date DEFAULT NULL::date,
  p_marketplace text DEFAULT NULL::text,
  p_account_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
SET statement_timeout TO '60s'
AS $function$
declare
  v_claims jsonb := '{}'::jsonb;
  v_tenant_id uuid := null;
  v_start date := coalesce(p_start, date_trunc('month', timezone('Asia/Jakarta', now()))::date);
  v_end date := coalesce(p_end, timezone('Asia/Jakarta', now())::date);
  v_marketplace text := null;
  v_summary jsonb := coalesce(p_base->'summary', '{}'::jsonb);
  v_by_marketplace jsonb := '[]'::jsonb;
  v_cash_adjustments jsonb := '[]'::jsonb;
  v_order_gross numeric := 0;
  v_order_count numeric := 0;
  v_payout numeric := 0;
  v_finance_count numeric := 0;
  v_expense numeric := 0;
  v_hpp numeric := 0;
  v_sum_platform_fee numeric := 0;
  v_sum_commission_fee numeric := 0;
  v_sum_affiliate_fee numeric := 0;
  v_sum_shipping_fee numeric := 0;
  v_sum_discount_amount numeric := 0;
  v_sum_refund_amount numeric := 0;
  v_sum_adjustment_amount numeric := 0;
  v_sum_fee_amount numeric := 0;
begin
  begin
    v_claims := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  exception when others then
    v_claims := '{}'::jsonb;
  end;

  v_tenant_id := case
    when (v_claims->>'tenant_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then (v_claims->>'tenant_id')::uuid
    else null::uuid
  end;

  if v_tenant_id is null then
    select case when count(*) = 1 then (array_agg(tenant_id))[1] else null end
      into v_tenant_id
    from (select distinct tenant_id from public.users where tenant_id is not null) t;
  end if;

  v_marketplace := case
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) in ('', 'all', 'semua') then null
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
    else lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g'))
  end;

  with unique_orders as (
    select
      coalesce(nullif(o.order_id, ''), nullif(o.external_order_id, ''), nullif(o.order_sn, ''), o.marketplace_order_id::text) as order_key,
      min((coalesce(o.paid_at, o.order_created_at, o.created_at) at time zone 'Asia/Jakarta')::date) as order_date,
      max(o.marketplace) as marketplace,
      max(o.marketplace_account_id::text) as account_id,
      max(greatest(coalesce(o.gross_amount, 0), coalesce(o.paid_amount, 0))) as omzet_value
    from public.marketplace_orders o
    where (v_tenant_id is null or o.tenant_id = v_tenant_id)
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and coalesce(o.paid_at, o.order_created_at, o.created_at) >= (v_start::timestamp at time zone 'Asia/Jakarta' - interval '2 days')
      and coalesce(o.paid_at, o.order_created_at, o.created_at) <= ((v_end + 1)::timestamp at time zone 'Asia/Jakarta' + interval '2 days')
      and coalesce(o.gross_amount, o.paid_amount, 0) > 0
      and not (lower(coalesce(o.order_status, '')) ~ '(cancel|canceled|cancelled|batal|return|returned|refund|refunded|unpaid|failed|reject|in_cancel)')
      and not (lower(coalesce(o.payment_status, '')) ~ '(unpaid|failed|cancel|canceled|cancelled|refund|refunded)')
      and not (o.order_sn ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
      and not (coalesce(o.order_id, '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
    group by coalesce(nullif(o.order_id, ''), nullif(o.external_order_id, ''), nullif(o.order_sn, ''), o.marketplace_order_id::text)
  ),
  order_omzet as (
    select
      case
        when lower(regexp_replace(coalesce(marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
        when lower(regexp_replace(coalesce(marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        else lower(regexp_replace(coalesce(marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end as marketplace,
      count(*)::numeric as order_count,
      sum(omzet_value)::numeric as omzet_total
    from unique_orders
    where order_date >= v_start
      and order_date <= v_end
      and (
        v_marketplace is null or
        case
          when lower(regexp_replace(coalesce(marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
          when lower(regexp_replace(coalesce(marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          else lower(regexp_replace(coalesce(marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end = v_marketplace
      )
    group by 1
  ),
  deduped_reports as (
    select distinct on (tenant_id, marketplace_account_id, coalesce(nullif(order_id, ''), statement_id))
      fr.*
    from public.marketplace_finance_reports fr
    where (v_tenant_id is null or fr.tenant_id = v_tenant_id)
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and coalesce(fr.settlement_date::date, fr.period_start::date, fr.created_at::date) between v_start and v_end
      and coalesce(fr.report_type, '') <> 'statement'
      and (
        v_marketplace is null or
        case
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end = v_marketplace
      )
    order by tenant_id, marketplace_account_id, coalesce(nullif(order_id, ''), statement_id),
             case when statement_id not like 'historical:%' then 1 else 2 end
  ),
  tiktok_statement_payout as (
    select
      'tiktok_shop' as marketplace,
      sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0))::numeric as payout_total
    from public.marketplace_finance_reports fr
    where (v_tenant_id is null or fr.tenant_id = v_tenant_id)
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and fr.report_type = 'statement'
      and lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%'
      and coalesce(fr.settlement_date::date, fr.period_start::date, fr.created_at::date) between v_start and v_end
      and (v_marketplace is null or v_marketplace = 'tiktok_shop')
    group by 1
  ),
  finance_payout as (
    select
      case
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end as marketplace,
      count(distinct coalesce(fr.marketplace_order_id::text, fr.order_id::text, fr.statement_id::text, fr.finance_report_id::text))::numeric as finance_order_count,
      sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0))::numeric as payout_total,
      sum(coalesce(fr.platform_fee, 0))::numeric as platform_fee,
      sum(coalesce(fr.commission_fee, 0))::numeric as commission_fee,
      sum(coalesce(fr.affiliate_fee, 0))::numeric as affiliate_fee,
      sum(coalesce(fr.shipping_fee, 0))::numeric as shipping_fee,
      sum(coalesce(fr.discount_amount, 0))::numeric as discount_amount,
      sum(coalesce(fr.refund_amount, 0))::numeric as refund_amount,
      sum(coalesce(fr.adjustment_amount, 0))::numeric as adjustment_amount,
      sum(coalesce(fr.fee_amount, 0))::numeric as fee_amount
    from deduped_reports fr
    group by 1
  ),
  hpp_by_sku as (
    select distinct on (tenant_id, marketplace_account_id, marketplace_sku_id)
      tenant_id, marketplace_account_id, marketplace_sku_id,
      coalesce(hpp_amount, hpp, hpp_per_item, 0)::numeric as hpp_val
    from public.marketplace_variant_hpp_mappings
    where coalesce(is_active, true) = true and coalesce(hpp_amount, hpp, hpp_per_item, 0) > 0 and nullif(trim(marketplace_sku_id),'') is not null
    order by tenant_id, marketplace_account_id, marketplace_sku_id, updated_at desc nulls last
  ),
  hpp_by_seller as (
    select distinct on (tenant_id, marketplace_account_id, lower(trim(marketplace_seller_sku)))
      tenant_id, marketplace_account_id, lower(trim(marketplace_seller_sku)) as seller_sku_clean,
      coalesce(hpp_amount, hpp, hpp_per_item, 0)::numeric as hpp_val
    from public.marketplace_variant_hpp_mappings
    where coalesce(is_active, true) = true and coalesce(hpp_amount, hpp, hpp_per_item, 0) > 0 and nullif(trim(marketplace_seller_sku),'') is not null
    order by tenant_id, marketplace_account_id, lower(trim(marketplace_seller_sku)), updated_at desc nulls last
  ),
  hpp_by_local as (
    select distinct on (tenant_id, marketplace_account_id, local_sku)
      tenant_id, marketplace_account_id, local_sku,
      coalesce(hpp_amount, hpp, hpp_per_item, 0)::numeric as hpp_val
    from public.marketplace_variant_hpp_mappings
    where coalesce(is_active, true) = true and coalesce(hpp_amount, hpp, hpp_per_item, 0) > 0 and nullif(trim(local_sku),'') is not null
    order by tenant_id, marketplace_account_id, local_sku, updated_at desc nulls last
  ),
  order_item_hpp as (
    select 
      case
        when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
        when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end as marketplace,
      sum(
        coalesce(oi.qty, oi.quantity, 1) * coalesce(h.hpp_val, h_seller.hpp_val, h_local.hpp_val, 0)
      )::numeric as hpp_total
    from public.marketplace_orders o
    join public.marketplace_order_items oi on oi.marketplace_order_id = o.marketplace_order_id
    left join hpp_by_sku h on h.tenant_id = oi.tenant_id
                          and h.marketplace_account_id = oi.marketplace_account_id
                          and h.marketplace_sku_id = oi.marketplace_sku_id
    left join hpp_by_seller h_seller on h_seller.tenant_id = oi.tenant_id
                                 and h_seller.marketplace_account_id = oi.marketplace_account_id
                                 and h_seller.seller_sku_clean = lower(trim(coalesce(oi.marketplace_seller_sku, oi.seller_sku)))
    left join hpp_by_local h_local on h_local.tenant_id = oi.tenant_id
                                and h_local.marketplace_account_id = oi.marketplace_account_id
                                and h_local.local_sku = oi.local_sku
    where (v_tenant_id is null or o.tenant_id = v_tenant_id)
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and (o.order_created_at at time zone 'Asia/Jakarta')::date between v_start and v_end
      and not (lower(coalesce(o.order_status, '')) ~ '(cancel|canceled|cancelled|batal|return|returned|refund|refunded|unpaid|failed|reject|in_cancel)')
    group by 1
  ),
  merged as (
    select
      coalesce(o.marketplace, f.marketplace, hp.marketplace) as marketplace,
      coalesce(o.order_count, 0) as order_count,
      coalesce(o.omzet_total, 0) as omzet_total,
      coalesce(f.finance_order_count, 0) as finance_order_count,
      case
        when coalesce(o.marketplace, f.marketplace, hp.marketplace) = 'tiktok_shop'
          then coalesce(tk.payout_total, 0)
        else coalesce(f.payout_total, 0)
      end as payout_total,
      coalesce(hp.hpp_total, 0) as hpp_total,
      coalesce(f.platform_fee, 0) as platform_fee,
      coalesce(f.commission_fee, 0) as commission_fee,
      coalesce(f.affiliate_fee, 0) as affiliate_fee,
      coalesce(f.shipping_fee, 0) as shipping_fee,
      coalesce(f.discount_amount, 0) as discount_amount,
      coalesce(f.refund_amount, 0) as refund_amount,
      coalesce(f.adjustment_amount, 0) as adjustment_amount,
      coalesce(f.fee_amount, 0) as fee_amount
    from order_omzet o
    full outer join finance_payout f using (marketplace)
    left join tiktok_statement_payout tk on tk.marketplace = coalesce(o.marketplace, f.marketplace)
    left join order_item_hpp hp on hp.marketplace = coalesce(o.marketplace, f.marketplace)
  )
  select
    coalesce(sum(omzet_total), 0),
    coalesce(sum(order_count), 0),
    coalesce(sum(payout_total), 0),
    coalesce(sum(finance_order_count), 0),
    coalesce(sum(hpp_total), 0),
    coalesce(sum(platform_fee), 0),
    coalesce(sum(commission_fee), 0),
    coalesce(sum(affiliate_fee), 0),
    coalesce(sum(shipping_fee), 0),
    coalesce(sum(discount_amount), 0),
    coalesce(sum(refund_amount), 0),
    coalesce(sum(adjustment_amount), 0),
    coalesce(sum(fee_amount), 0),
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'marketplace', marketplace,
          'marketplace_label', marketplace,
          'shop_name', case when marketplace = 'tiktok_shop' then 'TikTok' when marketplace = 'shopee' then 'Shopee' else marketplace end,
          'omzet_total', omzet_total,
          'gross_sales', omzet_total,
          'gross_total', omzet_total,
          'gross_amount', omzet_total,
          'order_count', order_count,
          'orders_count', order_count,
          'finance_order_count', finance_order_count,
          'finance_orders_count', finance_order_count,
          'payout_total', payout_total,
          'payout_amount', payout_total,
          'net_settlement', payout_total,
          'received_amount', payout_total,
          'hpp_total', hpp_total,
          'total_hpp', hpp_total,
          'paid_hpp_total', hpp_total,
          'settled_hpp_total', hpp_total,
          'net_profit', (payout_total - hpp_total),
          'profit', (payout_total - hpp_total),
          'net_margin_percent', case when omzet_total > 0 then round(((payout_total - hpp_total) / omzet_total) * 100, 2) else 0 end,
          'platform_fee', platform_fee,
          'commission_fee', commission_fee,
          'affiliate_fee', affiliate_fee,
          'shipping_fee', shipping_fee,
          'discount_amount', discount_amount,
          'refund_amount', refund_amount,
          'adjustment_amount', adjustment_amount,
          'fee_amount', fee_amount,
          'omzet_source', 'marketplace_orders.order_created_at',
          'payout_source', case when marketplace = 'tiktok_shop' then 'marketplace_finance_reports.statement (daily_transfer)' else 'marketplace_finance_reports.order_settlement' end
        ) order by marketplace
      ), '[]'::jsonb
    )
  into
    v_order_gross,
    v_order_count,
    v_payout,
    v_finance_count,
    v_hpp,
    v_sum_platform_fee,
    v_sum_commission_fee,
    v_sum_affiliate_fee,
    v_sum_shipping_fee,
    v_sum_discount_amount,
    v_sum_refund_amount,
    v_sum_adjustment_amount,
    v_sum_fee_amount,
    v_by_marketplace
  from merged;

  return jsonb_set(
    p_base,
    '{by_marketplace}', v_by_marketplace, true
  ) || jsonb_build_object(
    'marketplaces', v_by_marketplace,
    'marketplace_breakdown', v_by_marketplace,
    'profit_loss_by_marketplace', v_by_marketplace,
    'omzet_total', v_order_gross,
    'gross_sales', v_order_gross,
    'order_count', v_order_count,
    'orders_count', v_order_count,
    'payout_total', v_payout,
    'hpp_total', v_hpp,
    'net_profit', (v_payout - v_hpp),
    'summary', coalesce(p_base->'summary', '{}'::jsonb) || jsonb_build_object(
      'omzet_total', v_order_gross,
      'gross_sales', v_order_gross,
      'order_count', v_order_count,
      'orders_count', v_order_count,
      'payout_total', v_payout,
      'payout_amount', v_payout,
      'net_settlement', v_payout,
      'received_amount', v_payout,
      'hpp_total', v_hpp,
      'total_hpp', v_hpp,
      'net_profit', (v_payout - v_hpp),
      'profit', (v_payout - v_hpp),
      'net_margin_percent', case when v_order_gross > 0 then round(((v_payout - v_hpp) / v_order_gross) * 100, 2) else 0 end
    )
  );
end;
$function$;

ALTER FUNCTION public.finance_dashboard_snapshot(date, date, text, uuid) SET statement_timeout = '60s';
ALTER FUNCTION public.finance_fix_exact_cache_settled_hpp(date, date, text, uuid) SET statement_timeout = '60s';
ALTER FUNCTION public.finance_fix_exact_cache_settled_hpp_v24_6_82q(date, date, text, uuid) SET statement_timeout = '60s';
ALTER FUNCTION public.finance_customer_dashboard_snapshot_v24_6_82o(date, date, text, uuid) SET statement_timeout = '60s';
ALTER FUNCTION public.finance_customer_dashboard_snapshot_v24_6_82o_base_20260623(date, date, text, uuid) SET statement_timeout = '60s';
ALTER FUNCTION public.finance_snapshot_order_omzet_settlement_overlay_20260623(jsonb, date, date, text, uuid) SET statement_timeout = '60s';
