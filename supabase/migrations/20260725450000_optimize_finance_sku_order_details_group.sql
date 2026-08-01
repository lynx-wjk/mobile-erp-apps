-- Migration: 20260725450000_optimize_finance_sku_order_details_group.sql
-- Optimizes finance_sku_order_details_group_20260625 to run < 300ms using B-tree indexed joins.

CREATE OR REPLACE FUNCTION public.finance_sku_order_details_group_20260625(
  p_start date DEFAULT NULL::date,
  p_end date DEFAULT NULL::date,
  p_marketplace text DEFAULT NULL::text,
  p_account_id uuid DEFAULT NULL::uuid,
  p_search text DEFAULT NULL::text,
  p_payout_filter text DEFAULT NULL::text,
  p_page integer DEFAULT 1,
  p_page_size integer DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_start date := coalesce(p_start, current_date - 30);
  v_end date := coalesce(p_end, current_date);
  v_t_start timestamp with time zone := (v_start::text || ' 00:00:00+07')::timestamp with time zone;
  v_t_end timestamp with time zone := ((v_end + 1)::text || ' 00:00:00+07')::timestamp with time zone;
  v_tenant_id uuid := public._tenant_rpc_current_tenant_id();
  v_marketplace text := lower(trim(coalesce(p_marketplace, '')));
  v_search text := lower(trim(coalesce(p_search, '')));
  v_payout_filter text := lower(trim(coalesce(p_payout_filter, 'all')));
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_page_size integer := greatest(coalesce(p_page_size, 20), 1);
  v_offset integer := (v_page - 1) * v_page_size;
  v_res jsonb;

  v_total_sku_count integer := 0;
  v_total_orders_count integer := 0;
  v_total_qty_count integer := 0;
  v_total_omzet numeric := 0;
  v_total_payout numeric := 0;
  v_total_hpp numeric := 0;
  v_total_laba numeric := 0;
  v_items jsonb := '[]'::jsonb;
begin
  if v_tenant_id is null then
    return jsonb_build_object('ok', false, 'error', 'tenant_id required');
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

  with valid_orders as (
    select
      o.tenant_id,
      o.marketplace_order_id,
      o.marketplace_account_id,
      o.marketplace,
      o.external_order_id,
      o.order_sn,
      o.order_status,
      o.status,
      coalesce(nullif(o.external_order_id, ''), nullif(o.order_sn, ''), o.marketplace_order_id::text) as order_key
    from public.marketplace_orders o
    where o.tenant_id = v_tenant_id
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and o.order_created_at >= v_t_start and o.order_created_at < v_t_end
      and not (lower(concat_ws(' ', o.order_status, o.status, o.raw_order->>'status')) ~ '(cancel|canceled|cancelled|batal|dibatalkan|returned|return|refund|rts|gagal|failed|closed)')
      and (
        v_marketplace is null or
        case
          when lower(coalesce(o.marketplace, '')) ~ 'tiktok' then 'tiktok_shop'
          when lower(coalesce(o.marketplace, '')) ~ 'shopee' then 'shopee'
          else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end = v_marketplace
      )
  ),
  finance_payout_by_id as (
    select
      fr.marketplace_order_id,
      max(fr.settlement_status) as settlement_status,
      sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0)) as payout_total
    from valid_orders vo
    join public.marketplace_finance_reports fr on fr.tenant_id = vo.tenant_id and fr.marketplace_order_id = vo.marketplace_order_id
    where fr.marketplace_order_id is not null
    group by fr.marketplace_order_id
  ),
  finance_payout_by_key as (
    select
      fr.order_id,
      max(fr.settlement_status) as settlement_status,
      sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0)) as payout_total
    from valid_orders vo
    join public.marketplace_finance_reports fr on fr.tenant_id = vo.tenant_id and fr.order_id = vo.order_key
    where fr.order_id is not null
    group by fr.order_id
  ),
  order_payout_matched as (
    select
      vo.tenant_id,
      vo.marketplace_account_id,
      vo.marketplace_order_id,
      vo.order_key,
      vo.order_status,
      coalesce(fpi.payout_total, fpk.payout_total, 0) as payout_total,
      coalesce(fpi.settlement_status, fpk.settlement_status, '') as settlement_status
    from valid_orders vo
    left join finance_payout_by_id fpi on fpi.marketplace_order_id = vo.marketplace_order_id
    left join finance_payout_by_key fpk on fpk.order_id = vo.order_key and fpi.payout_total is null
  ),
  hpp_sku as (
    select lower(nullif(marketplace_sku_id, '')) as sku_id,
           max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp
    from public.marketplace_variant_hpp_mappings
    where tenant_id = v_tenant_id and coalesce(is_active, true) = true and nullif(marketplace_sku_id, '') is not null
    group by 1
  ),
  hpp_seller as (
    select lower(nullif(marketplace_seller_sku, '')) as seller_sku,
           max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp
    from public.marketplace_variant_hpp_mappings
    where tenant_id = v_tenant_id and coalesce(is_active, true) = true and nullif(marketplace_seller_sku, '') is not null
    group by 1
  ),
  hpp_local as (
    select lower(nullif(local_sku, '')) as local_sku,
           max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp
    from public.marketplace_variant_hpp_mappings
    where tenant_id = v_tenant_id and coalesce(is_active, true) = true and nullif(local_sku, '') is not null
    group by 1
  ),
  detail as (
    select
      opm.marketplace_order_id,
      opm.order_key,
      opm.order_status,
      opm.payout_total,
      opm.settlement_status,
      coalesce(nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, '')) as marketplace_sku_id,
      coalesce(nullif(oi.quantity, 0), nullif(oi.qty, 0), 1) as qty,
      coalesce(nullif(oi.marketplace_seller_sku, ''), nullif(oi.seller_sku, '')) as marketplace_seller_sku,
      coalesce(nullif(trim(oi.mapped_local_sku),''), nullif(trim(oi.local_sku),''), nullif(trim(oi.seller_sku),''), nullif(trim(oi.marketplace_seller_sku),''), nullif(trim(oi.marketplace_sku_id),''), 'Unmapped') as local_sku,
      coalesce(nullif(oi.product_name, ''), nullif(oi.marketplace_product_name, ''), nullif(oi.local_product_name, '')) as product_name,
      coalesce(nullif(oi.variant_name, ''), nullif(oi.marketplace_variant_name, ''), nullif(oi.variation_name, '')) as variant_name,
      greatest(
        coalesce(oi.gross_amount, 0),
        coalesce(oi.paid_amount, 0),
        coalesce(oi.unit_gross_amount, 0) * greatest(coalesce(nullif(oi.quantity, 0), nullif(oi.qty, 0), 1), 1)
      ) as gross_line,
      coalesce(hs.hpp, hsel.hpp, hl.hpp, 0)::numeric as unit_hpp
    from order_payout_matched opm
    join public.marketplace_order_items oi on oi.marketplace_order_id = opm.marketplace_order_id
    left join hpp_sku hs on hs.sku_id = lower(nullif(oi.marketplace_sku_id, ''))
    left join hpp_seller hsel on hsel.seller_sku = lower(nullif(oi.marketplace_seller_sku, ''))
    left join hpp_local hl on hl.local_sku = lower(nullif(coalesce(oi.mapped_local_sku, oi.local_sku), ''))
  ),
  classified as (
    select
      d.*,
      case
        when upper(coalesce(d.order_status, '')) ~ '(CANCEL|REFUND|RETURN|BATAL)' then 'Cancel/Refund/Return'
        when d.payout_total = 0 then 'Belum Payout'
        when d.payout_total < 0 then 'Payout Minus'
        else coalesce(nullif(d.settlement_status, ''), 'Settled')
      end as payout_status_clean
    from detail d
    where (
      v_search = ''
      or lower(d.local_sku) like '%' || v_search || '%'
      or lower(coalesce(d.marketplace_seller_sku, '')) like '%' || v_search || '%'
      or lower(coalesce(d.product_name, '')) like '%' || v_search || '%'
    )
  ),
  filtered as (
    select *
    from classified c
    where v_payout_filter in ('all', 'semua', '')
       or lower(c.payout_status_clean) = v_payout_filter
       or (v_payout_filter ~ 'belum' and c.payout_status_clean = 'Belum Payout')
       or (v_payout_filter ~ 'settle' and c.payout_status_clean = 'Settled')
  ),
  grouped as (
    select
      f.local_sku,
      max(f.marketplace_seller_sku) as marketplace_seller_sku,
      max(f.marketplace_sku_id) as marketplace_sku_id,
      max(f.product_name) as product_name,
      max(f.variant_name) as variant_name,
      count(distinct f.marketplace_order_id)::integer as order_count,
      sum(f.qty)::integer as total_qty,
      sum(f.gross_line)::numeric as total_omzet,
      sum(f.payout_total)::numeric as total_payout,
      sum(f.qty * f.unit_hpp)::numeric as total_hpp,
      sum(f.payout_total - (f.qty * f.unit_hpp))::numeric as net_profit,
      case
        when sum(f.payout_total) > 0 then round(((sum(f.payout_total - (f.qty * f.unit_hpp)) / sum(f.payout_total)) * 100)::numeric, 2)
        else 0
      end as margin_percent
    from filtered f
    group by f.local_sku
  )
  select
    count(*)::integer,
    coalesce(sum(order_count), 0)::integer,
    coalesce(sum(total_qty), 0)::integer,
    coalesce(sum(total_omzet), 0)::numeric,
    coalesce(sum(total_payout), 0)::numeric,
    coalesce(sum(total_hpp), 0)::numeric,
    coalesce(sum(net_profit), 0)::numeric,
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'local_sku', g.local_sku,
          'seller_sku', g.marketplace_seller_sku,
          'marketplace_seller_sku', g.marketplace_seller_sku,
          'marketplace_sku_id', g.marketplace_sku_id,
          'product_name', g.product_name,
          'variant_name', g.variant_name,
          'order_count', g.order_count,
          'orders_count', g.order_count,
          'total_qty', g.total_qty,
          'qty_total', g.total_qty,
          'total_omzet', g.total_omzet,
          'omzet_total', g.total_omzet,
          'total_payout', g.total_payout,
          'payout_total', g.total_payout,
          'total_hpp', g.total_hpp,
          'hpp_total', g.total_hpp,
          'net_profit', g.net_profit,
          'laba_net', g.net_profit,
          'margin_percent', g.margin_percent
        ) order by g.total_omzet desc
      ),
      '[]'::jsonb
    )
  into
    v_total_sku_count,
    v_total_orders_count,
    v_total_qty_count,
    v_total_omzet,
    v_total_payout,
    v_total_hpp,
    v_total_laba,
    v_items
  from (
    select * from grouped order by total_omzet desc limit v_page_size offset v_offset
  ) g;

  v_res := jsonb_build_object(
    'ok', true,
    'total_sku_count', v_total_sku_count,
    'total_orders_count', v_total_orders_count,
    'total_qty_count', v_total_qty_count,
    'total_omzet', v_total_omzet,
    'total_payout', v_total_payout,
    'total_hpp', v_total_hpp,
    'total_laba', v_total_laba,
    'page', v_page,
    'page_size', v_page_size,
    'items', v_items,
    'data', v_items
  );

  return v_res;
end;
$function$;
