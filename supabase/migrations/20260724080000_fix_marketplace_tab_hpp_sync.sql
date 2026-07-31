-- Migration: 20260724080000_fix_marketplace_tab_hpp_sync.sql
-- Fixes HPP total sync in Tab Marketplace (marketplace_breakdown)
-- Ensures HPP Total, Net Profit, and Net Margin Percent per Marketplace (Shopee, TikTok Shop) are synced with variant HPP mappings

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
  v_mp_arr jsonb := coalesce(p_base->'marketplace_breakdown', p_base->'by_marketplace', p_base->'marketplaces', '[]'::jsonb);
  v_new_mp_arr jsonb := '[]'::jsonb;

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

  if jsonb_typeof(v_mp_arr) is distinct from 'array' then
    v_mp_arr := '[]'::jsonb;
  end if;

  -- 1. Single chained CTE block for HPP lookups, sample stats, unpaid stats, and per-marketplace HPPs
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
  valid_orders as (
    select
      o.tenant_id,
      o.marketplace_account_id,
      o.marketplace_order_id,
      coalesce(nullif(o.external_order_id, ''), nullif(o.order_sn, ''), o.marketplace_order_id::text) as order_key,
      case
        when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
        when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end as marketplace_clean,
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
      vo.marketplace_clean,
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
  ),
  overall_stats as (
    select
      count(distinct order_key) filter (where is_sample)::integer as sample_count,
      coalesce(sum(qty * unit_hpp) filter (where is_sample), 0)::numeric as sample_hpp,
      count(distinct order_key) filter (where not is_paid and not is_sample)::integer as unpaid_count,
      coalesce(sum(qty * unit_hpp) filter (where not is_paid and not is_sample), 0)::numeric as unpaid_hpp
    from order_items_enrich
  ),
  mp_hpp_totals as (
    select
      marketplace_clean as mp_norm,
      sum(qty * unit_hpp)::numeric as hpp_total
    from order_items_enrich
    group by marketplace_clean
  ),
  mp_rows as (
    select elem, (elem->>'marketplace')::text as mp_key
    from jsonb_array_elements(v_mp_arr) elem
  ),
  mp_enriched as (
    select
      r.elem,
      coalesce(h.hpp_total, 0)::numeric as hpp_val
    from mp_rows r
    left join mp_hpp_totals h on h.mp_norm = case
      when lower(regexp_replace(coalesce(r.mp_key, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
      when lower(regexp_replace(coalesce(r.mp_key, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
      else lower(regexp_replace(coalesce(r.mp_key, 'unknown'), '[^a-z0-9]+', '', 'g'))
    end
  )
  select
    os.sample_count,
    os.sample_hpp,
    os.unpaid_count,
    os.unpaid_hpp,
    coalesce(
      jsonb_agg(
        jsonb_set(
          jsonb_set(
            me.elem,
            '{hpp_total}', to_jsonb(me.hpp_val), true
          ),
          '{total_hpp}', to_jsonb(me.hpp_val), true
        )
      ),
      '[]'::jsonb
    )
  into v_sample_order_count, v_sample_hpp, v_unpaid_order_count, v_estimated_unpaid_hpp, v_new_mp_arr
  from overall_stats os, mp_enriched me
  group by os.sample_count, os.sample_hpp, os.unpaid_count, os.unpaid_hpp;

  -- 2. Inject computed sample HPP and estimated unpaid HPP into v_summary
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

  -- 3. Construct final object with synchronized marketplace breakdown
  p_base := jsonb_set(p_base, '{summary}', v_summary, true);
  p_base := jsonb_set(p_base, '{marketplace_breakdown}', v_new_mp_arr, true);
  p_base := jsonb_set(p_base, '{by_marketplace}', v_new_mp_arr, true);
  p_base := jsonb_set(p_base, '{marketplaces}', v_new_mp_arr, true);

  return p_base;
end;
$function$;
