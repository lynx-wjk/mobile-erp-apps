-- Migration: 20260724070000_fix_sample_hpp_and_unpaid_est_hpp.sql
-- Fixes HPP sample calculation on Tab Ringkasan & Tab Abnormal
-- Fixes Estimated HPP Belum Payout for orders created/paid in current date range
-- Ensures all status order, resi, and payout data are strictly synced with marketplace data

-- 1. Update finance_sample_order_counts to include sample_hpp, sample_hpp_total, & abnormal_sample_hpp
CREATE OR REPLACE FUNCTION public.finance_sample_order_counts(
  p_start date DEFAULT NULL::date,
  p_end date DEFAULT NULL::date,
  p_marketplace text DEFAULT NULL::text,
  p_account_id uuid DEFAULT NULL::uuid,
  p_count_only boolean DEFAULT true,
  p_page integer DEFAULT 1,
  p_page_size integer DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_tenant_id uuid := public.app_current_tenant_id_or_default();
  v_role text := coalesce(nullif(v_claims->>'role', ''), nullif(current_setting('role', true), ''), current_user);
  v_start date := coalesce(p_start, date_trunc('month', timezone('Asia/Jakarta', now()))::date);
  v_end date := coalesce(p_end, timezone('Asia/Jakarta', now())::date);
  v_marketplace text;
  v_rows jsonb := '[]'::jsonb;
  v_summary jsonb := '{}'::jsonb;
  v_page integer := greatest(1, coalesce(p_page, 1));
  v_page_size integer := greatest(1, least(coalesce(p_page_size, 50), 200));
  v_offset integer := (v_page - 1) * v_page_size;
begin
  v_marketplace := case
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
    else null
  end;

  if v_marketplace is null and p_account_id is not null then
    select case
      when lower(regexp_replace(coalesce(ma.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
      when lower(regexp_replace(coalesce(ma.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
      else nullif(lower(regexp_replace(coalesce(ma.marketplace, ''), '[^a-z0-9]+', '', 'g')), '')
    end
    into v_marketplace
    from public.marketplace_accounts ma
    where ma.marketplace_account_id = p_account_id
      and coalesce(ma.is_deleted, false) is false
      and (v_role = 'service_role' or ma.tenant_id = v_tenant_id)
    limit 1;
  end if;

  with sample_orders_base as (
    select
      o.tenant_id,
      case
        when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
        else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end as marketplace_group,
      o.marketplace_account_id,
      o.marketplace_order_id,
      coalesce(nullif(o.order_sn, ''), nullif(o.external_order_id, ''), nullif(o.order_id::text, ''), o.marketplace_order_id::text) as order_key,
      o.order_status,
      o.tracking_number,
      o.order_created_at,
      coalesce(o.gross_amount, o.total_amount, o.paid_amount, 0)::numeric as gross_amount,
      coalesce(o.paid_amount, 0)::numeric as paid_amount,
      (coalesce(o.order_created_at, o.created_at) at time zone 'Asia/Jakarta')::date as order_date_wib
    from public.marketplace_orders o
    where o.tenant_id = v_tenant_id
      and (coalesce(o.order_created_at, o.created_at) at time zone 'Asia/Jakarta')::date between v_start and v_end
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and (
        v_marketplace is null
        or case
          when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
          else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end = v_marketplace
      )
      and not (lower(concat_ws(' ', o.order_status, o.status, o.raw_order->>'status')) ~ '(cancel|canceled|cancelled|batal|dibatalkan|returned|return|refund|rts|gagal|failed|closed)')
      and (
        (o.raw_order->>'is_sample_order')::boolean is true
        or (o.raw_order->>'is_sample')::boolean is true
        or upper(coalesce(o.raw_order->>'order_type', '')) like '%SAMPLE%'
        or o.raw_order->>'sample_type' is not null
        or (coalesce(o.paid_amount, o.gross_amount, 0) = 0 and lower(coalesce(o.order_status, '')) not like '%unpaid%')
      )
  ),
  hpp_sku as (
    select tenant_id, marketplace_account_id, lower(nullif(marketplace_sku_id, '')) as marketplace_sku_id,
           max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp
    from public.marketplace_variant_hpp_mappings
    where coalesce(is_active, true) = true and tenant_id = v_tenant_id and nullif(marketplace_sku_id, '') is not null
    group by tenant_id, marketplace_account_id, lower(nullif(marketplace_sku_id, ''))
  ),
  hpp_seller as (
    select tenant_id, marketplace_account_id, lower(nullif(marketplace_seller_sku, '')) as marketplace_seller_sku,
           max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp
    from public.marketplace_variant_hpp_mappings
    where coalesce(is_active, true) = true and tenant_id = v_tenant_id and nullif(marketplace_seller_sku, '') is not null
    group by tenant_id, marketplace_account_id, lower(nullif(marketplace_seller_sku, ''))
  ),
  hpp_local as (
    select tenant_id, marketplace_account_id, lower(nullif(local_sku, '')) as local_sku,
           max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp
    from public.marketplace_variant_hpp_mappings
    where coalesce(is_active, true) = true and tenant_id = v_tenant_id and nullif(local_sku, '') is not null
    group by tenant_id, marketplace_account_id, lower(nullif(local_sku, ''))
  ),
  sample_items as (
    select
      so.*,
      oi.marketplace_order_item_id,
      coalesce(oi.quantity, oi.qty, 1)::numeric as qty,
      coalesce(nullif(oi.product_name, ''), nullif(oi.marketplace_product_name, ''), 'Sample Product') as product_name,
      coalesce(nullif(oi.variant_name, ''), nullif(oi.marketplace_variant_name, ''), '') as variant_name,
      coalesce(nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, ''), '-') as marketplace_sku_id,
      coalesce(nullif(oi.marketplace_seller_sku, ''), nullif(oi.seller_sku, ''), '-') as marketplace_seller_sku,
      coalesce(nullif(oi.mapped_local_sku, ''), nullif(oi.local_sku, ''), '-') as local_sku,
      coalesce(hs.hpp, hsel.hpp, hl.hpp, 0)::numeric as unit_hpp
    from sample_orders_base so
    join public.marketplace_order_items oi on oi.marketplace_order_id = so.marketplace_order_id
    left join hpp_sku hs on hs.tenant_id = so.tenant_id and hs.marketplace_account_id = so.marketplace_account_id and hs.marketplace_sku_id = lower(nullif(oi.marketplace_sku_id, ''))
    left join hpp_seller hsel on hsel.tenant_id = so.tenant_id and hsel.marketplace_account_id = so.marketplace_account_id and hsel.marketplace_seller_sku = lower(nullif(oi.marketplace_seller_sku, ''))
    left join hpp_local hl on hl.tenant_id = so.tenant_id and hl.marketplace_account_id = so.marketplace_account_id and hl.local_sku = lower(nullif(coalesce(oi.mapped_local_sku, oi.local_sku), ''))
  ),
  sample_aggregated as (
    select
      count(distinct order_key)::integer as sample_order_count,
      coalesce(sum(qty * unit_hpp), 0)::numeric as sample_hpp
    from sample_items
  ),
  paged_sample_orders as (
    select
      si.marketplace_account_id,
      si.marketplace_group as marketplace,
      si.order_key,
      si.order_date_wib,
      si.order_status,
      si.tracking_number,
      si.product_name,
      si.variant_name,
      si.marketplace_sku_id,
      si.marketplace_seller_sku,
      si.local_sku,
      si.qty,
      si.unit_hpp,
      (si.qty * si.unit_hpp)::numeric as hpp_total
    from sample_items si
    order by si.order_date_wib desc, si.order_key desc
    limit case when p_count_only then 0 else v_page_size end
    offset case when p_count_only then 0 else v_offset end
  )
  select
    jsonb_build_object(
      'sample_order_count', sa.sample_order_count,
      'sample_count', sa.sample_order_count,
      'abnormal_sample_count', sa.sample_order_count,
      'sample_hpp', sa.sample_hpp,
      'sample_hpp_total', sa.sample_hpp,
      'abnormal_sample_hpp', sa.sample_hpp,
      'hpp_sample_total', sa.sample_hpp,
      'total_sample_hpp', sa.sample_hpp
    ),
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'source', 'finance_sample_order_counts',
            'order_id', order_key,
            'order_sn', order_key,
            'marketplace', marketplace,
            'marketplace_account_id', marketplace_account_id,
            'order_date', order_date_wib,
            'order_status', order_status,
            'status', order_status,
            'tracking_number', tracking_number,
            'resi', tracking_number,
            'product_name', product_name,
            'variant_name', variant_name,
            'marketplace_sku_id', marketplace_sku_id,
            'marketplace_seller_sku', marketplace_seller_sku,
            'local_sku', local_sku,
            'qty', qty,
            'quantity', qty,
            'unit_hpp', unit_hpp,
            'hpp', hpp_total,
            'hpp_total', hpp_total,
            'abnormal_status', 'SAMPLE_FREE',
            'payout_status', 'SAMPLE_FREE',
            'finance_status', 'SAMPLE_FREE',
            'note', 'Sample order from marketplace API'
          )
        )
        from paged_sample_orders
      ),
      '[]'::jsonb
    )
  into v_summary, v_rows
  from sample_aggregated sa;

  return jsonb_build_object(
    'ok', true,
    'source', 'finance_sample_order_counts',
    'summary', coalesce(v_summary, '{}'::jsonb),
    'sample_orders', coalesce(v_rows, '[]'::jsonb),
    'rows', coalesce(v_rows, '[]'::jsonb)
  );
end;
$function$;


-- 2. Update finance_snapshot_order_omzet_settlement_overlay_20260623 to compute sample HPP & estimated unpaid HPP
CREATE OR REPLACE FUNCTION public.finance_snapshot_order_omzet_settlement_overlay_20260623(
  p_base jsonb,
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
  v_tenant_id uuid := public.app_current_tenant_id_or_default();
  v_start date := coalesce(p_start, date_trunc('month', timezone('Asia/Jakarta', now()))::date);
  v_end date := coalesce(p_end, timezone('Asia/Jakarta', now())::date);
  v_marketplace text := null;
  v_summary jsonb := coalesce(p_base->'summary', '{}'::jsonb);

  v_sample_order_count integer := 0;
  v_sample_hpp numeric := 0;
  v_unpaid_order_count integer := 0;
  v_estimated_unpaid_hpp numeric := 0;
begin
  v_marketplace := case
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) in ('', 'all', 'semua') then null
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
    else lower(regexp_replace(coalesce(p_marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
  end;

  -- 1. Shared HPP CTEs
  with hpp_sku as (
    select tenant_id, marketplace_account_id, lower(nullif(marketplace_sku_id, '')) as marketplace_sku_id,
           max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp
    from public.marketplace_variant_hpp_mappings
    where coalesce(is_active, true) = true and tenant_id = v_tenant_id and nullif(marketplace_sku_id, '') is not null
    group by tenant_id, marketplace_account_id, lower(nullif(marketplace_sku_id, ''))
  ),
  hpp_seller as (
    select tenant_id, marketplace_account_id, lower(nullif(marketplace_seller_sku, '')) as marketplace_seller_sku,
           max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp
    from public.marketplace_variant_hpp_mappings
    where coalesce(is_active, true) = true and tenant_id = v_tenant_id and nullif(marketplace_seller_sku, '') is not null
    group by tenant_id, marketplace_account_id, lower(nullif(marketplace_seller_sku, ''))
  ),
  hpp_local as (
    select tenant_id, marketplace_account_id, lower(nullif(local_sku, '')) as local_sku,
           max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp
    from public.marketplace_variant_hpp_mappings
    where coalesce(is_active, true) = true and tenant_id = v_tenant_id and nullif(local_sku, '') is not null
    group by tenant_id, marketplace_account_id, lower(nullif(local_sku, ''))
  ),
  -- 2. Valid orders in selected period (v_start to v_end)
  valid_orders as (
    select
      o.tenant_id,
      o.marketplace_account_id,
      o.marketplace_order_id,
      coalesce(nullif(o.external_order_id, ''), nullif(o.order_sn, ''), o.marketplace_order_id::text) as order_key,
      (
        (o.raw_order->>'is_sample_order')::boolean is true
        or (o.raw_order->>'is_sample')::boolean is true
        or upper(coalesce(o.raw_order->>'order_type', '')) like '%SAMPLE%'
        or o.raw_order->>'sample_type' is not null
        or (coalesce(o.paid_amount, o.gross_amount, 0) = 0 and lower(coalesce(o.order_status, '')) not like '%unpaid%')
      ) as is_sample
    from public.marketplace_orders o
    where o.tenant_id = v_tenant_id
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and (coalesce(o.order_created_at, o.created_at) at time zone 'Asia/Jakarta')::date between v_start and v_end
      and not (lower(concat_ws(' ', o.order_status, o.status, o.raw_order->>'status')) ~ '(cancel|canceled|cancelled|batal|dibatalkan|returned|return|refund|rts|gagal|failed|closed)')
      and (
        v_marketplace is null or
        case
          when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
          when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end = v_marketplace
      )
  ),
  finance_payout as (
    select fr.order_id as order_key, sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0)) as payout_total
    from public.marketplace_finance_reports fr
    where fr.tenant_id = v_tenant_id
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
    group by fr.order_id
  ),
  order_items_enrich as (
    select
      vo.order_key,
      vo.is_sample,
      coalesce(fp.payout_total, 0) > 0 as is_paid,
      coalesce(oi.quantity, oi.qty, 1)::numeric as qty,
      coalesce(hs.hpp, hsel.hpp, hl.hpp, 0)::numeric as unit_hpp
    from valid_orders vo
    join public.marketplace_order_items oi on oi.marketplace_order_id = vo.marketplace_order_id
    left join finance_payout fp on fp.order_key = vo.order_key
    left join hpp_sku hs on hs.tenant_id = vo.tenant_id and hs.marketplace_account_id = vo.marketplace_account_id and hs.marketplace_sku_id = lower(nullif(oi.marketplace_sku_id, ''))
    left join hpp_seller hsel on hsel.tenant_id = vo.tenant_id and hsel.marketplace_account_id = vo.marketplace_account_id and hsel.marketplace_seller_sku = lower(nullif(oi.marketplace_seller_sku, ''))
    left join hpp_local hl on hl.tenant_id = vo.tenant_id and hl.marketplace_account_id = vo.marketplace_account_id and hl.local_sku = lower(nullif(coalesce(oi.mapped_local_sku, oi.local_sku), ''))
  )
  select
    count(distinct order_key) filter (where is_sample)::integer,
    coalesce(sum(qty * unit_hpp) filter (where is_sample), 0)::numeric,
    count(distinct order_key) filter (where not is_paid and not is_sample)::integer,
    coalesce(sum(qty * unit_hpp) filter (where not is_paid and not is_sample), 0)::numeric
  into v_sample_order_count, v_sample_hpp, v_unpaid_order_count, v_estimated_unpaid_hpp
  from order_items_enrich;

  -- 3. Inject computed sample HPP and estimated unpaid HPP into v_summary
  v_summary := jsonb_set(v_summary, '{sample_order_count}', to_jsonb(v_sample_order_count), true);
  v_summary := jsonb_set(v_summary, '{abnormal_sample_count}', to_jsonb(v_sample_order_count), true);
  v_summary := jsonb_set(v_summary, '{sample_hpp}', to_jsonb(v_sample_hpp), true);
  v_summary := jsonb_set(v_summary, '{sample_hpp_total}', to_jsonb(v_sample_hpp), true);
  v_summary := jsonb_set(v_summary, '{abnormal_sample_hpp}', to_jsonb(v_sample_hpp), true);
  v_summary := jsonb_set(v_summary, '{hpp_sample_total}', to_jsonb(v_sample_hpp), true);
  
  v_summary := jsonb_set(v_summary, '{unpaid_order_count}', to_jsonb(v_unpaid_order_count), true);
  v_summary := jsonb_set(v_summary, '{estimated_unpaid_hpp_total}', to_jsonb(v_estimated_unpaid_hpp), true);
  v_summary := jsonb_set(v_summary, '{unpaid_estimated_hpp_total}', to_jsonb(v_estimated_unpaid_hpp), true);
  v_summary := jsonb_set(v_summary, '{unpaid_hpp}', to_jsonb(v_estimated_unpaid_hpp), true);

  return jsonb_set(p_base, '{summary}', v_summary, true);
end;
$function$;
