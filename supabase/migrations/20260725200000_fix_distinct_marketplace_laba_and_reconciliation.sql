-- Migration: 20260725200000_fix_distinct_marketplace_laba_and_reconciliation.sql
-- Fixes per-marketplace breakdown to calculate distinct Laba Net, Margin %, and detailed reconciliation breakdown per marketplace.

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
  v_start date := coalesce(p_start, current_date - 30);
  v_end date := coalesce(p_end, current_date);
  v_tenant_id uuid := coalesce(
    public.app_current_tenant_id_or_default(),
    (select tenant_id from public.users where tenant_id is not null limit 1)
  );
  v_marketplace text := lower(trim(coalesce(p_marketplace, '')));
  v_mp_arr jsonb := coalesce(p_base->'marketplace_breakdown', p_base->'by_marketplace', p_base->'marketplaces', '[]'::jsonb);
  v_new_mp_arr jsonb := '[]'::jsonb;
  v_summary jsonb := coalesce(p_base->'summary', p_base);

  v_sample_order_count integer := 0;
  v_total_sample_hpp numeric := 0;
  v_unpaid_order_count integer := 0;
  v_total_unpaid_hpp numeric := 0;
  v_total_settled_hpp numeric := 0;
  v_total_gross_hpp numeric := 0;
begin
  if v_tenant_id is null or p_base is null then
    return p_base;
  end if;

  if v_marketplace in ('all', 'semua', 'semua platform', '-') then
    v_marketplace := null;
  else
    v_marketplace := case
      when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
      when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
      else lower(regexp_replace(coalesce(p_marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
    end;
  end if;

  if jsonb_typeof(v_mp_arr) is distinct from 'array' or jsonb_array_length(v_mp_arr) = 0 then
    v_mp_arr := '[{"marketplace":"shopee"},{"marketplace":"tiktok_shop"}]'::jsonb;
  end if;

  with hpp_sku as (
    select tenant_id, lower(nullif(marketplace_sku_id, '')) as marketplace_sku_id,
           max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp
    from public.marketplace_variant_hpp_mappings
    where coalesce(is_active, true) = true and tenant_id = v_tenant_id and nullif(marketplace_sku_id, '') is not null
    group by tenant_id, lower(nullif(marketplace_sku_id, ''))
  ),
  hpp_seller as (
    select tenant_id, lower(nullif(marketplace_seller_sku, '')) as marketplace_seller_sku,
           max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp
    from public.marketplace_variant_hpp_mappings
    where coalesce(is_active, true) = true and tenant_id = v_tenant_id and nullif(marketplace_seller_sku, '') is not null
    group by tenant_id, lower(nullif(marketplace_seller_sku, ''))
  ),
  hpp_local as (
    select tenant_id, lower(nullif(local_sku, '')) as local_sku,
           max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp
    from public.marketplace_variant_hpp_mappings
    where coalesce(is_active, true) = true and tenant_id = v_tenant_id and nullif(local_sku, '') is not null
    group by tenant_id, lower(nullif(local_sku, ''))
  ),
  valid_orders as (
    select
      o.tenant_id,
      o.marketplace_account_id,
      o.marketplace_order_id,
      coalesce(nullif(o.external_order_id, ''), nullif(o.order_sn, ''), o.marketplace_order_id::text) as order_key,
      o.external_order_id,
      o.order_sn,
      coalesce(o.paid_amount, o.gross_amount, 0)::numeric as gross_amount,
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
    select
      fr.tenant_id,
      coalesce(nullif(fr.order_id, ''), fr.marketplace_order_id::text) as order_key,
      fr.marketplace_order_id,
      sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0)) as payout_total
    from public.marketplace_finance_reports fr
    where fr.tenant_id = v_tenant_id
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
    group by fr.tenant_id, 2, fr.marketplace_order_id
  ),
  order_payout_matched as (
    select
      vo.tenant_id,
      vo.marketplace_account_id,
      vo.marketplace_order_id,
      vo.marketplace_clean,
      vo.order_key,
      vo.is_sample,
      vo.gross_amount,
      coalesce(fp.payout_total, fp_by_id.payout_total, fp_by_sn.payout_total, fp_by_ext.payout_total, 0) as payout_total
    from valid_orders vo
    left join finance_payout fp on fp.order_key = vo.order_key
    left join finance_payout fp_by_id on fp_by_id.marketplace_order_id = vo.marketplace_order_id and fp.payout_total is null
    left join finance_payout fp_by_sn on fp_by_sn.order_key = vo.order_sn and fp.payout_total is null and fp_by_id.payout_total is null
    left join finance_payout fp_by_ext on fp_by_ext.order_key = vo.external_order_id and fp.payout_total is null and fp_by_id.payout_total is null and fp_by_sn.payout_total is null
  ),
  mp_payout_totals as (
    select
      marketplace_clean as mp_norm,
      sum(gross_amount) as gross_sales,
      sum(payout_total) as payout_total,
      count(*) as order_count
    from order_payout_matched
    group by marketplace_clean
  ),
  order_items_enrich as (
    select
      opm.order_key,
      opm.marketplace_clean,
      opm.is_sample,
      (opm.payout_total > 0) as is_paid,
      coalesce(oi.quantity, oi.qty, 1)::numeric as qty,
      coalesce(hs.hpp, hsel.hpp, hl.hpp, 0)::numeric as unit_hpp
    from order_payout_matched opm
    join public.marketplace_order_items oi on oi.marketplace_order_id = opm.marketplace_order_id
    left join hpp_sku hs on hs.tenant_id = opm.tenant_id and hs.marketplace_sku_id = lower(nullif(oi.marketplace_sku_id, ''))
    left join hpp_seller hsel on hsel.tenant_id = opm.tenant_id and hsel.marketplace_seller_sku = lower(nullif(oi.marketplace_seller_sku, ''))
    left join hpp_local hl on hl.tenant_id = opm.tenant_id and hl.local_sku = lower(nullif(coalesce(oi.mapped_local_sku, oi.local_sku), ''))
  ),
  overall_stats as (
    select
      count(distinct order_key) filter (where is_sample)::integer as sample_count,
      coalesce(sum(qty * unit_hpp) filter (where is_sample), 0)::numeric as sample_hpp,
      count(distinct order_key) filter (where not is_paid and not is_sample)::integer as unpaid_count,
      coalesce(sum(qty * unit_hpp) filter (where not is_paid and not is_sample), 0)::numeric as unpaid_hpp,
      coalesce(sum(qty * unit_hpp) filter (where is_paid and not is_sample), 0)::numeric as settled_hpp,
      coalesce(sum(qty * unit_hpp), 0)::numeric as gross_hpp
    from order_items_enrich
  ),
  mp_hpp_totals as (
    select
      marketplace_clean as mp_norm,
      coalesce(sum(qty * unit_hpp) filter (where is_paid and not is_sample), 0)::numeric as settled_hpp,
      coalesce(sum(qty * unit_hpp) filter (where is_sample), 0)::numeric as sample_hpp,
      coalesce(sum(qty * unit_hpp) filter (where not is_paid and not is_sample), 0)::numeric as unpaid_hpp,
      coalesce(sum(qty * unit_hpp), 0)::numeric as total_hpp
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
      case
        when lower(regexp_replace(coalesce(r.mp_key, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
        when lower(regexp_replace(coalesce(r.mp_key, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        else lower(regexp_replace(coalesce(r.mp_key, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end as mp_norm,
      coalesce(nullif(h.settled_hpp, 0), nullif((r.elem->>'settled_hpp')::numeric, 0), nullif((r.elem->>'hpp_total')::numeric, 0), 0)::numeric as settled_hpp_val,
      coalesce(nullif(h.sample_hpp, 0), nullif((r.elem->>'sample_hpp')::numeric, 0), 0)::numeric as sample_hpp_val,
      coalesce(nullif(h.unpaid_hpp, 0), nullif((r.elem->>'unpaid_hpp')::numeric, 0), 0)::numeric as unpaid_hpp_val,
      coalesce(nullif(h.total_hpp, 0), nullif((r.elem->>'total_hpp')::numeric, 0), nullif((r.elem->>'hpp_total')::numeric, 0), 0)::numeric as total_hpp_val,
      coalesce(nullif(p.payout_total, 0), nullif((r.elem->>'payout_total')::numeric, 0), nullif((r.elem->>'payout_amount')::numeric, 0), nullif((r.elem->>'net_settlement')::numeric, 0), 0)::numeric as payout_val,
      coalesce(nullif(p.gross_sales, 0), nullif((r.elem->>'omzet_total')::numeric, 0), nullif((r.elem->>'gross_sales')::numeric, 0), 0)::numeric as omzet_val,
      coalesce(nullif(p.order_count, 0), nullif((r.elem->>'order_count')::integer, 0), nullif((r.elem->>'orders_count')::integer, 0), 0)::integer as order_count_val
    from mp_rows r
    left join mp_hpp_totals h on h.mp_norm = case
      when lower(regexp_replace(coalesce(r.mp_key, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
      when lower(regexp_replace(coalesce(r.mp_key, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
      else lower(regexp_replace(coalesce(r.mp_key, 'unknown'), '[^a-z0-9]+', '', 'g'))
    end
    left join mp_payout_totals p on p.mp_norm = case
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
    os.settled_hpp,
    os.gross_hpp,
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'marketplace', me.mp_norm,
          'marketplace_label', me.mp_norm,
          'order_count', me.order_count_val,
          'orders_count', me.order_count_val,
          'finance_order_count', me.order_count_val,
          'finance_orders_count', me.order_count_val,
          'omzet_total', me.omzet_val,
          'gross_sales', me.omzet_val,
          'gross_total', me.omzet_val,
          'payout_total', me.payout_val,
          'payout', me.payout_val,
          'payout_amount', me.payout_val,
          'net_settlement', me.payout_val,
          'received_amount', me.payout_val,
          'hpp_total', case when me.settled_hpp_val > 0 then me.settled_hpp_val else me.total_hpp_val end,
          'settled_hpp', me.settled_hpp_val,
          'total_hpp', case when me.settled_hpp_val > 0 then me.settled_hpp_val else me.total_hpp_val end,
          'sample_hpp', me.sample_hpp_val,
          'gross_all_hpp', me.total_hpp_val,
          'net_profit', (me.payout_val - (case when me.settled_hpp_val > 0 then me.settled_hpp_val else me.total_hpp_val end)),
          'laba', (me.payout_val - (case when me.settled_hpp_val > 0 then me.settled_hpp_val else me.total_hpp_val end)),
          'profit', (me.payout_val - (case when me.settled_hpp_val > 0 then me.settled_hpp_val else me.total_hpp_val end)),
          'margin_percent', case when me.payout_val > 0 then round(((me.payout_val - (case when me.settled_hpp_val > 0 then me.settled_hpp_val else me.total_hpp_val end)) / me.payout_val * 100)::numeric, 2) else 0 end,
          'margin', case when me.payout_val > 0 then round(((me.payout_val - (case when me.settled_hpp_val > 0 then me.settled_hpp_val else me.total_hpp_val end)) / me.payout_val * 100)::numeric, 2) else 0 end,
          'net_margin_percent', case when me.payout_val > 0 then round(((me.payout_val - (case when me.settled_hpp_val > 0 then me.settled_hpp_val else me.total_hpp_val end)) / me.payout_val * 100)::numeric, 2) else 0 end,
          'total_deductions', greatest(me.omzet_val - me.payout_val, 0),
          'biaya', greatest(me.omzet_val - me.payout_val, 0),
          'deductions', greatest(me.omzet_val - me.payout_val, 0),
          'reconciliation_breakdown', jsonb_build_object(
            'gross_sales', me.omzet_val,
            'customer_paid_sales', me.omzet_val,
            'net_payout', me.payout_val,
            'total_deductions', greatest(me.omzet_val - me.payout_val, 0),
            'biaya', greatest(me.omzet_val - me.payout_val, 0),
            'refund', 0,
            'koreksi', 0
          )
        )
      ),
      '[]'::jsonb
    )
  into v_sample_order_count, v_total_sample_hpp, v_unpaid_order_count, v_total_unpaid_hpp, v_total_settled_hpp, v_total_gross_hpp, v_new_mp_arr
  from overall_stats os, mp_enriched me
  group by os.sample_count, os.sample_hpp, os.unpaid_count, os.unpaid_hpp, os.settled_hpp, os.gross_hpp;

  if v_total_settled_hpp > 0 then
    v_summary := jsonb_set(v_summary, '{hpp_total}', to_jsonb(v_total_settled_hpp), true);
    v_summary := jsonb_set(v_summary, '{total_hpp}', to_jsonb(v_total_settled_hpp), true);
    v_summary := jsonb_set(v_summary, '{settled_hpp}', to_jsonb(v_total_settled_hpp), true);
  end if;

  if v_total_gross_hpp > 0 then
    v_summary := jsonb_set(v_summary, '{gross_all_hpp}', to_jsonb(v_total_gross_hpp), true);
  end if;

  if v_total_sample_hpp > 0 then
    v_summary := jsonb_set(v_summary, '{sample_hpp}', to_jsonb(v_total_sample_hpp), true);
  end if;

  v_summary := jsonb_set(v_summary, '{marketplace_breakdown}', v_new_mp_arr, true);
  v_summary := jsonb_set(v_summary, '{by_marketplace}', v_new_mp_arr, true);
  v_summary := jsonb_set(v_summary, '{marketplaces}', v_new_mp_arr, true);
  v_summary := jsonb_set(v_summary, '{profit_loss_by_marketplace}', v_new_mp_arr, true);

  return v_summary;
end;
$function$;
