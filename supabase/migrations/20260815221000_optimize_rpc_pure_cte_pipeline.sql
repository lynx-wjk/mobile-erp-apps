-- Migration: Optimize Finance SKU RPCs with Pure In-Memory CTE Pipeline
-- Migration ID: 20260815221000_optimize_rpc_pure_cte_pipeline.sql
-- Eliminates temporary table disk/catalog locks and accelerates multi-tenant finance reporting

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
  v_tenant_id uuid := public.app_current_tenant_id_or_default();
  v_marketplace text := lower(trim(coalesce(p_marketplace, '')));
  v_search text := lower(trim(coalesce(p_search, '')));
  v_payout_filter text := lower(trim(coalesce(p_payout_filter, 'all')));
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_page_size integer := greatest(coalesce(p_page_size, 20), 1);
  v_offset integer := (v_page - 1) * v_page_size;
  v_result jsonb;
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

  with all_orders as (
    select
      o.tenant_id,
      o.marketplace_order_id,
      o.marketplace_account_id,
      o.marketplace,
      o.external_order_id,
      o.order_sn,
      coalesce(nullif(o.external_order_id, ''), nullif(o.order_sn, ''), o.marketplace_order_id::text) as order_key,
      (
        lower(coalesce(o.order_status, o.status, '')) ~ '(cancel|canceled|cancelled|batal|dibatalkan|returned|return|refund|rts|gagal|failed|closed)'
        and coalesce(nullif(trim(o.tracking_number), ''), '-') <> '-'
      ) as is_returned,
      (
        lower(coalesce(o.order_status, o.status, '')) ~ '(cancel|canceled|cancelled|batal|dibatalkan|returned|return|refund|rts|gagal|failed|closed)'
        and coalesce(nullif(trim(o.tracking_number), ''), '-') = '-'
      ) as is_pre_shipment_cancel
    from public.marketplace_orders o
    where o.tenant_id = v_tenant_id
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and (coalesce(o.order_created_at, o.created_time, o.created_at, o.paid_at) at time zone 'Asia/Jakarta')::date between v_start and v_end
      and (v_marketplace is null or lower(coalesce(o.marketplace, '')) = v_marketplace)
  ),
  finance_by_order as (
    select
      ao.marketplace_order_id,
      sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0))::numeric as payout_total
    from all_orders ao
    join public.marketplace_finance_reports fr on fr.tenant_id = v_tenant_id
      and (fr.marketplace_order_id = ao.marketplace_order_id or fr.order_id = ao.order_key or fr.order_id = ao.external_order_id or fr.order_id = ao.order_sn)
    where coalesce(fr.report_type, 'order_settlement') <> 'statement'
      and coalesce(fr.status, 'pulled') <> 'draft'
    group by 1
  ),
  hpp_sku as (
    select lower(nullif(marketplace_sku_id, '')) as sku_id,
           max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp,
           max(nullif(local_sku, '')) as mapped_local_sku
    from public.marketplace_variant_hpp_mappings
    where tenant_id = v_tenant_id and coalesce(is_active, true) = true and nullif(marketplace_sku_id, '') is not null
    group by 1
  ),
  hpp_local as (
    select lower(nullif(local_sku, '')) as local_sku,
           max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp,
           max(nullif(local_sku, '')) as mapped_local_sku
    from public.marketplace_variant_hpp_mappings
    where tenant_id = v_tenant_id and coalesce(is_active, true) = true and nullif(local_sku, '') is not null
    group by 1
  ),
  order_gross_totals as (
    select
      ao.marketplace_order_id,
      count(*)::numeric as item_count,
      sum(coalesce(
        nullif(oi.gross_amount, 0),
        nullif(oi.paid_amount, 0),
        coalesce(oi.unit_gross_amount, 0) * greatest(coalesce(nullif(oi.quantity, 0), nullif(oi.qty, 0), 1), 1)
      ))::numeric as gross_item_sum
    from all_orders ao
    join public.marketplace_order_items oi on oi.marketplace_order_id = ao.marketplace_order_id
    group by ao.marketplace_order_id
  ),
  item_details as (
    select
      ao.marketplace_order_id,
      ao.is_returned,
      ao.is_pre_shipment_cancel,
      coalesce(
        nullif(trim(hs.mapped_local_sku), ''),
        nullif(trim(hl.mapped_local_sku), ''),
        nullif(trim(oi.mapped_local_sku),''),
        nullif(trim(oi.local_sku),''),
        case
          when nullif(trim(oi.variant_name), '') is not null
          then trim(coalesce(oi.marketplace_seller_sku, oi.seller_sku, oi.product_name, '')) || ' - ' || trim(oi.variant_name)
          else nullif(trim(coalesce(oi.marketplace_seller_sku, oi.seller_sku)), '')
        end,
        nullif(trim(oi.marketplace_sku_id),''),
        nullif(trim(oi.product_name),''),
        'Unmapped'
      ) as local_sku,
      coalesce(nullif(oi.marketplace_seller_sku, ''), nullif(oi.seller_sku, ''), oi.product_name) as seller_sku,
      coalesce(nullif(oi.product_name, ''), oi.marketplace_product_name) as product_name,
      coalesce(nullif(oi.quantity, 0), nullif(oi.qty, 0), 1) as qty,
      coalesce(
        nullif(oi.gross_amount, 0),
        nullif(oi.paid_amount, 0),
        coalesce(oi.unit_gross_amount, 0) * greatest(coalesce(nullif(oi.quantity, 0), nullif(oi.qty, 0), 1), 1),
        0
      ) as gross_line,
      coalesce(hs.hpp, hl.hpp, 0) as unit_hpp,
      (not ao.is_returned and not ao.is_pre_shipment_cancel and fbo.payout_total is not null and fbo.payout_total <> 0) as has_payout,
      case
        when ao.is_returned or ao.is_pre_shipment_cancel or fbo.payout_total is null or fbo.payout_total = 0 then 0
        when coalesce(ogt.gross_item_sum, 0) > 0 then round(fbo.payout_total * (coalesce(nullif(oi.gross_amount, 0), nullif(oi.paid_amount, 0), coalesce(oi.unit_gross_amount, 0) * greatest(coalesce(nullif(oi.quantity, 0), nullif(oi.qty, 0), 1), 1)) / ogt.gross_item_sum), 2)
        when coalesce(ogt.item_count, 0) > 0 then round(fbo.payout_total / ogt.item_count, 2)
        else fbo.payout_total
      end as line_payout
    from all_orders ao
    join public.marketplace_order_items oi on oi.marketplace_order_id = ao.marketplace_order_id
    left join order_gross_totals ogt on ogt.marketplace_order_id = ao.marketplace_order_id
    left join finance_by_order fbo on fbo.marketplace_order_id = ao.marketplace_order_id
    left join hpp_sku hs on hs.sku_id = lower(trim(oi.marketplace_sku_id))
    left join hpp_local hl on hl.local_sku = lower(trim(coalesce(oi.local_sku, oi.seller_sku, oi.marketplace_seller_sku)))
    where not ao.is_pre_shipment_cancel
      and (
        v_search = '' or
        lower(coalesce(ao.order_sn, '')) like '%' || v_search || '%' or
        lower(coalesce(ao.external_order_id, '')) like '%' || v_search || '%' or
        lower(coalesce(oi.product_name, '')) like '%' || v_search || '%' or
        lower(coalesce(oi.marketplace_seller_sku, oi.seller_sku, '')) like '%' || v_search || '%'
      )
  ),
  aggregated as (
    select
      local_sku,
      max(seller_sku) as seller_sku,
      max(product_name) as product_name,
      count(distinct marketplace_order_id)::integer as orders_count,
      round(sum(case when not is_returned then qty else 0 end), 2)::numeric as total_qty,
      round(sum(case when has_payout then qty else 0 end), 2)::numeric as qty_settled,
      round(sum(case when not is_returned and not has_payout then qty else 0 end), 2)::numeric as qty_unsettled,
      round(sum(case when is_returned then qty else 0 end), 2)::numeric as qty_returned,
      round(sum(case when not is_returned then gross_line else 0 end), 2)::numeric as total_omzet,
      round(sum(case when not is_returned then gross_line else 0 end), 2)::numeric as gross_sales,
      round(sum(line_payout), 2)::numeric as total_payout,
      round(sum(line_payout), 2)::numeric as payout_total,
      round(sum(line_payout), 2)::numeric as payout_amount,
      case when sum(case when not is_returned then qty else 0 end) > 0 then round(sum(case when not is_returned then gross_line else 0 end) / sum(case when not is_returned then qty else 0 end), 2) else 0 end::numeric as gross_per_item,
      case when sum(case when has_payout then qty else 0 end) > 0 then round(sum(line_payout) / sum(case when has_payout then qty else 0 end), 2) else 0 end::numeric as payout_per_item,
      case when sum(case when not is_returned then qty else 0 end) > 0 then round(sum(case when not is_returned then qty * unit_hpp else 0 end) / sum(case when not is_returned then qty else 0 end), 2) else 0 end::numeric as hpp_per_item,
      round(sum(case when not is_returned then qty * unit_hpp else 0 end), 2)::numeric as total_hpp,
      round(sum(case when has_payout then qty * unit_hpp else 0 end), 2)::numeric as hpp_settled,
      round(sum(case when not is_returned and not has_payout then qty * unit_hpp else 0 end), 2)::numeric as unpaid_hpp,
      round(sum(case when is_returned then qty * unit_hpp else 0 end), 2)::numeric as hpp_return,
      round((sum(line_payout) - sum(case when has_payout then qty * unit_hpp else 0 end)), 2)::numeric as net_profit,
      case when sum(line_payout) > 0 then round(((sum(line_payout) - sum(case when has_payout then qty * unit_hpp else 0 end)) / sum(line_payout)) * 100, 2) else 0 end::numeric as margin_net_pct
    from item_details
    group by local_sku
  ),
  filtered_summary as (
    select
      count(*)::integer as total_skus,
      coalesce(sum(orders_count), 0)::integer as total_orders,
      coalesce(sum(total_qty), 0)::numeric as total_qty,
      round(coalesce(sum(total_omzet), 0), 2)::numeric as total_omzet,
      round(coalesce(sum(total_payout), 0), 2)::numeric as total_payout,
      round(coalesce(sum(total_hpp), 0), 2)::numeric as total_hpp,
      round(coalesce(sum(hpp_settled), 0), 2)::numeric as hpp_settled,
      round(coalesce(sum(unpaid_hpp), 0), 2)::numeric as unpaid_hpp,
      round(coalesce(sum(hpp_return), 0), 2)::numeric as hpp_return,
      round(coalesce(sum(qty_returned), 0), 2)::numeric as total_qty_returned,
      round(coalesce(sum(net_profit), 0), 2)::numeric as total_laba
    from aggregated
    where (v_payout_filter = 'all')
       or (v_payout_filter in ('settled', 'lunas') and qty_settled > 0)
       or (v_payout_filter in ('unsettled', 'belum_payout') and qty_unsettled > 0)
       or (v_payout_filter in ('returned', 'batal', 'retur') and qty_returned > 0)
  ),
  paged_items as (
    select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) as items
    from (
      select *
      from aggregated
      where (v_payout_filter = 'all')
         or (v_payout_filter in ('settled', 'lunas') and qty_settled > 0)
         or (v_payout_filter in ('unsettled', 'belum_payout') and qty_unsettled > 0)
         or (v_payout_filter in ('returned', 'batal', 'retur') and qty_returned > 0)
      order by total_omzet desc
      limit v_page_size offset v_offset
    ) t
  )
  select jsonb_build_object(
    'ok', true,
    'total_skus', fs.total_skus,
    'total_orders', fs.total_orders,
    'total_qty', fs.total_qty,
    'total_qty_returned', fs.total_qty_returned,
    'total_omzet', fs.total_omzet,
    'total_payout', fs.total_payout,
    'payout_total', fs.total_payout,
    'gross_sales', fs.total_omzet,
    'total_hpp', fs.total_hpp,
    'hpp_settled', fs.hpp_settled,
    'unpaid_hpp', fs.unpaid_hpp,
    'hpp_return', fs.hpp_return,
    'hpp_retur', fs.hpp_return,
    'total_laba', fs.total_laba,
    'net_profit', fs.total_laba,
    'page', v_page,
    'page_size', v_page_size,
    'items', pi.items
  )
  into v_result
  from filtered_summary fs
  cross join paged_items pi;

  return v_result;
end;
$function$;

CREATE OR REPLACE FUNCTION public.finance_sku_order_line_details(
  p_start date DEFAULT NULL::date,
  p_end date DEFAULT NULL::date,
  p_marketplace text DEFAULT NULL::text,
  p_account_id uuid DEFAULT NULL::uuid,
  p_marketplace_sku text DEFAULT NULL::text,
  p_local_sku text DEFAULT NULL::text,
  p_search text DEFAULT NULL::text,
  p_payout_filter text DEFAULT 'all'::text,
  p_page integer DEFAULT 1,
  p_page_size integer DEFAULT 25
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_tenant_id uuid := public.app_current_tenant_id_or_default();
  v_start date := coalesce(p_start, date_trunc('month', now())::date);
  v_end date := coalesce(p_end, now()::date);
  v_marketplace text := lower(trim(coalesce(p_marketplace, '')));
  v_marketplace_sku text := lower(trim(coalesce(p_marketplace_sku, '')));
  v_local_sku text := lower(trim(coalesce(p_local_sku, '')));
  v_search text := lower(trim(coalesce(p_search, '')));
  v_payout_filter text := lower(trim(coalesce(p_payout_filter, 'all')));

  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_page_size integer := greatest(coalesce(p_page_size, 25), 1);
  v_offset integer := (v_page - 1) * v_page_size;
  v_result jsonb;
begin
  if v_tenant_id is null or not exists (select 1 from public.marketplace_orders where tenant_id = v_tenant_id) then
    select tenant_id into v_tenant_id
    from public.marketplace_orders
    group by tenant_id
    order by count(*) desc
    limit 1;
  end if;

  if v_marketplace in ('all', 'semua', 'semua platform', '-', 'unknown', 'null', '') then
    v_marketplace := '';
  else
    v_marketplace := case
      when v_marketplace ~ 'shopee' then 'shopee'
      when v_marketplace ~ 'tiktok' then 'tiktok_shop'
      else regexp_replace(v_marketplace, '[^a-z0-9]+', '', 'g')
    end;
  end if;

  with target_items as (
    select
      oi.marketplace_order_id,
      coalesce(nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, '')) as marketplace_sku_id,
      coalesce(nullif(oi.marketplace_seller_sku, ''), nullif(oi.seller_sku, '')) as marketplace_seller_sku,
      coalesce(
        nullif(trim(hs.mapped_local_sku), ''),
        nullif(trim(hl.mapped_local_sku), ''),
        nullif(trim(oi.mapped_local_sku),''),
        nullif(trim(oi.local_sku),''),
        case
          when nullif(trim(oi.variant_name), '') is not null
          then trim(coalesce(oi.marketplace_seller_sku, oi.seller_sku, oi.product_name, '')) || ' - ' || trim(oi.variant_name)
          else nullif(trim(coalesce(oi.marketplace_seller_sku, oi.seller_sku)), '')
        end,
        nullif(trim(oi.marketplace_sku_id),''),
        nullif(trim(oi.product_name),''),
        'Unmapped'
      ) as local_sku,
      coalesce(nullif(oi.quantity, 0), nullif(oi.qty, 0), 1) as qty,
      coalesce(nullif(oi.product_name, ''), nullif(oi.marketplace_product_name, ''), nullif(oi.local_product_name, '')) as product_name,
      coalesce(nullif(oi.variant_name, ''), nullif(oi.marketplace_variant_name, ''), nullif(oi.variation_name, '')) as variant_name,
      coalesce(nullif(oi.gross_amount, 0), nullif(oi.paid_amount, 0), coalesce(oi.unit_gross_amount, 0) * greatest(coalesce(nullif(oi.quantity, 0), nullif(oi.qty, 0), 1), 1), 0) as raw_item_gross,
      coalesce(hs.hpp, hl.hpp, 0) as unit_hpp
    from public.marketplace_order_items oi
    join public.marketplace_orders o on o.marketplace_order_id = oi.marketplace_order_id
    left join (
      select lower(nullif(marketplace_sku_id, '')) as sku_id,
             max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp,
             max(nullif(local_sku, '')) as mapped_local_sku
      from public.marketplace_variant_hpp_mappings
      where tenant_id = v_tenant_id and coalesce(is_active, true) = true and nullif(marketplace_sku_id, '') is not null
      group by 1
    ) hs on hs.sku_id = lower(trim(oi.marketplace_sku_id))
    left join (
      select lower(nullif(local_sku, '')) as local_sku,
             max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp,
             max(nullif(local_sku, '')) as mapped_local_sku
      from public.marketplace_variant_hpp_mappings
      where tenant_id = v_tenant_id and coalesce(is_active, true) = true and nullif(local_sku, '') is not null
      group by 1
    ) hl on hl.local_sku = lower(trim(coalesce(oi.local_sku, oi.seller_sku, oi.marketplace_seller_sku)))
    where o.tenant_id = v_tenant_id
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and (coalesce(o.order_created_at, o.created_time, o.created_at, o.paid_at) at time zone 'Asia/Jakarta')::date between v_start and v_end
      and (v_marketplace = '' or lower(coalesce(o.marketplace, '')) = v_marketplace)
  ),
  matched_orders as (
    select distinct ti.marketplace_order_id
    from target_items ti
    join public.marketplace_orders o on o.marketplace_order_id = ti.marketplace_order_id
    where (
        v_marketplace_sku = '' or 
        lower(coalesce(ti.marketplace_sku_id, '')) = v_marketplace_sku or 
        lower(coalesce(ti.marketplace_seller_sku, '')) = v_marketplace_sku or
        lower(coalesce(ti.product_name, '')) like '%' || v_marketplace_sku || '%'
      )
      and (v_local_sku = '' or lower(coalesce(ti.local_sku, '')) = v_local_sku)
      and (
        v_search = '' or
        lower(coalesce(o.order_sn, '')) like '%' || v_search || '%' or
        lower(coalesce(o.external_order_id, '')) like '%' || v_search || '%' or
        lower(coalesce(ti.local_sku, '')) like '%' || v_search || '%' or
        lower(coalesce(ti.marketplace_sku_id, '')) like '%' || v_search || '%' or
        lower(coalesce(ti.marketplace_seller_sku, '')) like '%' || v_search || '%' or
        lower(coalesce(ti.product_name, '')) like '%' || v_search || '%' or
        lower(coalesce(ti.variant_name, '')) like '%' || v_search || '%'
      )
  ),
  order_gross_sums as (
    select marketplace_order_id, sum(raw_item_gross) as gross_item_sum, count(*)::numeric as item_count
    from target_items
    group by 1
  ),
  finance_matching as (
    select
      mo.marketplace_order_id,
      sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0))::numeric as payout_total,
      max(coalesce(fr.marketplace_finance_report_id::text, fr.finance_report_id::text, '')) as finance_report_id,
      max(fr.statement_id) as statement_id,
      max(coalesce(fr.settlement_date, fr.created_at)::text) as finance_at
    from matched_orders mo
    join public.marketplace_orders o on o.marketplace_order_id = mo.marketplace_order_id
    join public.marketplace_finance_reports fr on fr.tenant_id = v_tenant_id
      and (fr.marketplace_order_id = o.marketplace_order_id or fr.order_id = coalesce(nullif(o.external_order_id, ''), nullif(o.order_sn, ''), o.marketplace_order_id::text) or fr.order_id = o.external_order_id or fr.order_id = o.order_sn)
    where coalesce(fr.report_type, 'order_settlement') <> 'statement'
      and coalesce(fr.status, 'pulled') <> 'draft'
    group by 1
  ),
  all_order_lines as (
    select
      o.marketplace_order_id::text as id,
      coalesce(nullif(o.external_order_id, ''), nullif(o.order_sn, ''), o.marketplace_order_id::text) as order_id,
      o.order_sn,
      o.external_order_id,
      coalesce(nullif(o.external_order_id, ''), nullif(o.order_sn, ''), o.marketplace_order_id::text) as order_key,
      o.marketplace_account_id,
      coalesce(acc.shop_name, o.marketplace) as shop_name,
      o.marketplace,
      coalesce(o.order_status, o.status, '-') as order_status,
      coalesce(o.order_status, o.status, '-') as status,
      coalesce(o.tracking_number, '-') as tracking_number,
      coalesce(o.tracking_number, '-') as resi,
      (coalesce(o.order_created_at, o.created_time, o.created_at, o.paid_at) at time zone 'Asia/Jakarta')::text as order_date,
      (coalesce(o.order_created_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::text as created_at,
      (coalesce(o.order_created_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::text as order_created_at,
      (coalesce(o.order_created_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::text as created_time,
      coalesce(fmp.statement_id, '-') as statement_id,
      case 
        when lower(coalesce(o.order_status, o.status, '')) ~ '(cancel|canceled|cancelled|batal|dibatalkan|returned|return|refund|rts|gagal|failed|closed)'
             and coalesce(nullif(trim(o.tracking_number), ''), '-') <> '-' then 'retur_batal'
        when fmp.payout_total is not null and fmp.payout_total <> 0 then 'lunas'
        else 'belum_payout'
      end as settlement_status,
      coalesce(fmp.finance_report_id, '-') as finance_report_id,
      coalesce(fmp.finance_at, '-') as finance_at,
      ti.local_sku,
      coalesce(ti.marketplace_sku_id, ti.marketplace_seller_sku, '-') as marketplace_sku,
      coalesce(ti.marketplace_sku_id, '-') as marketplace_sku_id,
      coalesce(ti.marketplace_seller_sku, '-') as marketplace_seller_sku,
      coalesce(ti.product_name, '-') as product_name,
      coalesce(ti.variant_name, '-') as variant_name,
      ti.qty as quantity,
      ti.qty,
      ti.raw_item_gross as gross_line,
      ti.raw_item_gross as gross_amount,
      (not lower(coalesce(o.order_status, o.status, '')) ~ '(cancel|canceled|cancelled|batal|dibatalkan|returned|return|refund|rts|gagal|failed|closed)' and fmp.payout_total is not null and fmp.payout_total <> 0) as has_payout,
      (lower(coalesce(o.order_status, o.status, '')) ~ '(cancel|canceled|cancelled|batal|dibatalkan|returned|return|refund|rts|gagal|failed|closed)' and coalesce(nullif(trim(o.tracking_number), ''), '-') <> '-') as is_returned,
      case
        when lower(coalesce(o.order_status, o.status, '')) ~ '(cancel|canceled|cancelled|batal|dibatalkan|returned|return|refund|rts|gagal|failed|closed)' or fmp.payout_total is null or fmp.payout_total = 0 then 0
        when coalesce(ogs.gross_item_sum, 0) > 0 then round(fmp.payout_total * (ti.raw_item_gross / ogs.gross_item_sum), 2)
        when coalesce(ogs.item_count, 0) > 0 then round(fmp.payout_total / ogs.item_count, 2)
        else fmp.payout_total
      end as payout_amount,
      ti.unit_hpp,
      (ti.qty * ti.unit_hpp) as hpp_total
    from matched_orders mo
    join public.marketplace_orders o on o.marketplace_order_id = mo.marketplace_order_id
    join target_items ti on ti.marketplace_order_id = mo.marketplace_order_id
    left join order_gross_sums ogs on ogs.marketplace_order_id = mo.marketplace_order_id
    left join finance_matching fmp on fmp.marketplace_order_id = mo.marketplace_order_id
    left join public.marketplace_accounts acc on acc.marketplace_account_id = o.marketplace_account_id
    where not (lower(coalesce(o.order_status, o.status, '')) ~ '(cancel|canceled|cancelled|batal|dibatalkan|returned|return|refund|rts|gagal|failed|closed)' and coalesce(nullif(trim(o.tracking_number), ''), '-') = '-')
  ),
  filtered_lines as (
    select *
    from all_order_lines tod
    where v_payout_filter = 'all' or
          (v_payout_filter in ('settled', 'lunas', 'paid') and tod.has_payout = true and tod.is_returned = false) or
          (v_payout_filter in ('unsettled', 'belum_payout', 'unpaid') and tod.has_payout = false and tod.is_returned = false) or
          (v_payout_filter in ('returned', 'batal', 'retur', 'refund') and tod.is_returned = true)
  ),
  total_count as (
    select count(*)::integer as count_total from filtered_lines
  ),
  paged_rows as (
    select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) as rows
    from (
      select *
      from filtered_lines
      order by order_date desc
      limit v_page_size offset v_offset
    ) t
  )
  select jsonb_build_object(
    'ok', true,
    'total', tc.count_total,
    'total_pages', ceiling(tc.count_total::numeric / greatest(v_page_size, 1)),
    'page', v_page,
    'page_size', v_page_size,
    'rows', pr.rows
  )
  into v_result
  from total_count tc
  cross join paged_rows pr;

  return v_result;
end;
$function$;

CREATE OR REPLACE FUNCTION public.finance_sku_order_details_v24_6_82o(
  p_start date DEFAULT NULL::date,
  p_end date DEFAULT NULL::date,
  p_marketplace text DEFAULT NULL::text,
  p_account_id uuid DEFAULT NULL::uuid,
  p_marketplace_sku text DEFAULT NULL::text,
  p_local_sku text DEFAULT NULL::text,
  p_search text DEFAULT NULL::text,
  p_payout_filter text DEFAULT 'all'::text,
  p_page integer DEFAULT 1,
  p_page_size integer DEFAULT 25
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
begin
  return public.finance_sku_order_line_details(
    p_start,
    p_end,
    p_marketplace,
    p_account_id,
    p_marketplace_sku,
    p_local_sku,
    p_search,
    p_payout_filter,
    p_page,
    p_page_size
  );
end;
$function$;
