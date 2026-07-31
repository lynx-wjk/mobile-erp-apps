-- Migration: 20260724120000_fix_laba_rugi_breakdown_and_sku_details.sql
-- Fixes Tab Laba Rugi margin & detailed fee breakdown and SKU line-item detail lookup for Shopee & TikTok Shop

-- 1. Update finance_snapshot_order_omzet_settlement_overlay_20260623
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
  v_tenant_id uuid := public.app_current_tenant_id_or_default();
  v_marketplace text := lower(trim(coalesce(p_marketplace, '')));
  v_mp_arr jsonb := coalesce(p_base->'marketplace_breakdown', p_base->'by_marketplace', p_base->'marketplaces', '[]'::jsonb);
  v_new_mp_arr jsonb := '[]'::jsonb;
  v_summary jsonb := p_base;

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

  if jsonb_typeof(v_mp_arr) is distinct from 'array' then
    v_mp_arr := '[]'::jsonb;
  end if;

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
      fr.order_id as order_key,
      fr.marketplace_account_id,
      sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0)) as payout_total
    from public.marketplace_finance_reports fr
    where fr.tenant_id = v_tenant_id
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
    group by fr.order_id, fr.marketplace_account_id
  ),
  mp_payout_totals as (
    select
      vo.marketplace_clean as mp_norm,
      sum(vo.gross_amount) as gross_sales,
      sum(coalesce(fp.payout_total, 0)) as payout_total
    from valid_orders vo
    left join finance_payout fp on fp.order_key = vo.order_key
    group by vo.marketplace_clean
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
      coalesce(h.settled_hpp, 0)::numeric as settled_hpp_val,
      coalesce(h.sample_hpp, 0)::numeric as sample_hpp_val,
      coalesce(h.unpaid_hpp, 0)::numeric as unpaid_hpp_val,
      coalesce(h.total_hpp, 0)::numeric as total_hpp_val,
      coalesce(p.payout_total, 0)::numeric as payout_val,
      coalesce(p.gross_sales, (r.elem->>'omzet_total')::numeric, (r.elem->>'gross_sales')::numeric, 0)::numeric as omzet_val
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


-- 2. Update finance_sku_order_details_v24_6_82o
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
  v_payout_filter text := lower(trim(coalesce(p_payout_filter, 'all')));
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_page_size integer := least(greatest(coalesce(p_page_size, 20), 1), 200);
  v_offset integer := (v_page - 1) * v_page_size;

  v_marketplace_sku text := lower(trim(coalesce(p_marketplace_sku, '')));
  v_local_sku text := lower(trim(coalesce(p_local_sku, '')));
  v_search text := lower(trim(coalesce(p_search, '')));

  v_rows jsonb := '[]'::jsonb;
  v_total integer := 0;
  v_total_pages integer := 1;
  v_result jsonb;
begin
  if v_tenant_id is null then
    return jsonb_build_object('ok', false, 'error', 'tenant_id required');
  end if;

  if v_marketplace in ('all', 'semua', 'semua platform', '-') then
    v_marketplace := '';
  end if;

  if v_payout_filter in ('settled', 'sudah_payout', 'sudah payout', 'sudah ada payout', 'paid') then
    v_payout_filter := 'paid';
  elsif v_payout_filter in ('belum_payout', 'belum payout', 'belum ada payout', 'pending', 'unpaid') then
    v_payout_filter := 'unpaid';
  elsif v_payout_filter in ('all', 'semua', '') then
    v_payout_filter := 'all';
  end if;

  with valid_orders as (
    select
      o.tenant_id,
      o.marketplace_account_id,
      o.marketplace_order_id,
      o.marketplace,
      coalesce(nullif(o.external_order_id, ''), nullif(o.order_sn, ''), o.marketplace_order_id::text) as order_key,
      coalesce(o.order_status, o.status, o.raw_order->>'status', '-') as order_status,
      (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta') as order_ts_wib,
      (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date as order_date_wib,
      coalesce(nullif(o.tracking_number, ''), nullif(o.raw_order->>'tracking_number', ''), '-') as tracking_number
    from public.marketplace_orders o
    where o.tenant_id = v_tenant_id
      and (v_marketplace = '' or lower(coalesce(o.marketplace, '')) = v_marketplace)
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date between v_start and v_end
      and not (
        upper(coalesce(o.order_status, o.status, o.raw_order->>'status', '')) like any (
          array['%CANCEL%', '%REFUND%', '%RETURN%', '%FAILED%', '%CLOSE%']
        )
      )
  ),
  finance_by_order as (
    select
      coalesce(nullif(fr.order_id, ''), fr.marketplace_order_id::text, 'no_order_id_' || md5(random()::text)) as order_key,
      fr.marketplace_account_id,
      fr.marketplace,
      max(fr.statement_id) as statement_id,
      max(fr.settlement_status) as settlement_status,
      max(fr.finance_report_id::text) as finance_report_id,
      max(fr.period_start::text) as finance_at,
      sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0)) as payout_total
    from public.marketplace_finance_reports fr
    where fr.tenant_id = v_tenant_id
      and (v_marketplace = '' or lower(coalesce(fr.marketplace, '')) = v_marketplace)
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and coalesce(fr.settlement_date, fr.period_start) >= v_start - 30
      and coalesce(fr.settlement_date, fr.period_start) <= v_end + 30
    group by 1, 2, 3
  ),
  order_items_filtered as (
    select
      vo.marketplace_account_id,
      vo.marketplace,
      vo.order_key,
      vo.order_status,
      vo.order_date_wib,
      vo.tracking_number,
      coalesce(nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, '')) as marketplace_sku_id,
      coalesce(nullif(oi.marketplace_seller_sku, ''), nullif(oi.seller_sku, '')) as marketplace_seller_sku,
      coalesce(nullif(trim(oi.mapped_local_sku),''), nullif(trim(oi.local_sku),''), nullif(trim(oi.seller_sku),''), nullif(trim(oi.marketplace_seller_sku),''), nullif(trim(oi.marketplace_sku_id),''), '-') as local_sku,
      coalesce(nullif(oi.quantity, 0), nullif(oi.qty, 0), 1) as qty,
      coalesce(nullif(oi.product_name, ''), nullif(oi.marketplace_product_name, ''), nullif(oi.local_product_name, '')) as product_name,
      coalesce(nullif(oi.variant_name, ''), nullif(oi.marketplace_variant_name, ''), nullif(oi.variation_name, '')) as variant_name,
      greatest(
        coalesce(oi.gross_amount, 0),
        coalesce(oi.paid_amount, 0),
        coalesce(oi.unit_gross_amount, 0) * greatest(coalesce(nullif(oi.quantity, 0), nullif(oi.qty, 0), 1), 1)
      ) as gross_line
    from valid_orders vo
    join public.marketplace_order_items oi
      on oi.tenant_id = vo.tenant_id
     and oi.marketplace_order_id = vo.marketplace_order_id
    where (
      (v_marketplace_sku = '' and v_local_sku = '')
      or (v_marketplace_sku <> '' and (
        lower(coalesce(oi.marketplace_sku_id, oi.remote_sku_id, '')) = v_marketplace_sku
        or lower(coalesce(oi.marketplace_seller_sku, oi.seller_sku, '')) = v_marketplace_sku
        or lower(coalesce(oi.mapped_local_sku, oi.local_sku, '')) = v_marketplace_sku
      ))
      or (v_local_sku <> '' and (
        lower(coalesce(oi.mapped_local_sku, oi.local_sku, '')) = v_local_sku
        or lower(coalesce(oi.marketplace_seller_sku, oi.seller_sku, '')) = v_local_sku
        or lower(coalesce(oi.marketplace_sku_id, oi.remote_sku_id, '')) = v_local_sku
        or lower(coalesce(oi.product_name, '')) = v_local_sku
      ))
    )
    and (
      v_search = ''
      or lower(coalesce(vo.order_key, '')) like '%' || v_search || '%'
      or lower(coalesce(vo.tracking_number, '')) like '%' || v_search || '%'
      or lower(coalesce(oi.product_name, '')) like '%' || v_search || '%'
      or lower(coalesce(oi.variant_name, '')) like '%' || v_search || '%'
      or lower(coalesce(oi.local_sku, '')) like '%' || v_search || '%'
    )
  ),
  hpp_sku as (
    select tenant_id, marketplace_account_id, lower(nullif(marketplace_sku_id, '')) as marketplace_sku_id,
           max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
           max(coalesce(nullif(target_margin_percent, 0), nullif(target_margin, 0), 0))::numeric as target_margin_percent,
           max(nullif(local_sku, '')) as mapped_local_sku
    from public.marketplace_variant_hpp_mappings
    where coalesce(is_active, true) is true and nullif(marketplace_sku_id, '') is not null
      and tenant_id = v_tenant_id
    group by tenant_id, marketplace_account_id, lower(nullif(marketplace_sku_id, ''))
  ),
  hpp_seller as (
    select tenant_id, marketplace_account_id, lower(nullif(marketplace_seller_sku, '')) as marketplace_seller_sku,
           max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
           max(coalesce(nullif(target_margin_percent, 0), nullif(target_margin, 0), 0))::numeric as target_margin_percent,
           max(nullif(local_sku, '')) as mapped_local_sku
    from public.marketplace_variant_hpp_mappings
    where coalesce(is_active, true) is true and nullif(marketplace_seller_sku, '') is not null
      and tenant_id = v_tenant_id
    group by tenant_id, marketplace_account_id, lower(nullif(marketplace_seller_sku, ''))
  ),
  hpp_local as (
    select tenant_id, marketplace_account_id, lower(nullif(local_sku, '')) as local_sku,
           max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
           max(coalesce(nullif(target_margin_percent, 0), nullif(target_margin, 0), 0))::numeric as target_margin_percent,
           max(nullif(local_sku, '')) as mapped_local_sku
    from public.marketplace_variant_hpp_mappings
    where coalesce(is_active, true) is true and nullif(local_sku, '') is not null
      and tenant_id = v_tenant_id
    group by tenant_id, marketplace_account_id, lower(nullif(local_sku, ''))
  ),
  margin_settings as (
    select lower(nullif(local_sku, '')) as local_sku,
           max(target_margin_percent)::numeric as target_margin_percent
    from public.finance_sku_margin_settings
    where tenant_id = v_tenant_id and target_margin_percent > 0 and nullif(local_sku, '') is not null
    group by lower(nullif(local_sku, ''))
  ),
  margin_products as (
    select lower(nullif(kode_sku, '')) as local_sku,
           max(target_margin_percent)::numeric as target_margin_percent
    from public.products
    where tenant_id = v_tenant_id and target_margin_percent > 0 and nullif(kode_sku, '') is not null
    group by lower(nullif(kode_sku, ''))
  ),
  enriched as (
    select
      d.marketplace_account_id,
      d.marketplace,
      d.order_key,
      d.order_status,
      d.order_date_wib,
      d.tracking_number,
      d.marketplace_sku_id,
      d.marketplace_seller_sku,
      d.local_sku,
      coalesce(hs.mapped_local_sku, hsel.mapped_local_sku, hl.mapped_local_sku, d.local_sku) as live_local_sku,
      d.qty,
      d.product_name,
      d.variant_name,
      d.gross_line,
      fbo.payout_total as order_payout,
      fbo.settlement_status,
      fbo.statement_id,
      fbo.finance_report_id,
      fbo.finance_at,
      sum(nullif(d.gross_line, 0)) over (partition by d.marketplace_account_id, d.order_key) as gross_order_scope,
      sum(d.qty) over (partition by d.marketplace_account_id, d.order_key) as qty_order_scope,
      coalesce(hs.hpp, hsel.hpp, hl.hpp, 0)::numeric as unit_hpp,
      coalesce(
        ms.target_margin_percent,
        hs.target_margin_percent,
        hsel.target_margin_percent,
        hl.target_margin_percent,
        mp.target_margin_percent,
        30
      )::numeric as target_margin_percent
    from order_items_filtered d
    left join finance_by_order fbo
      on fbo.marketplace_account_id = d.marketplace_account_id
     and fbo.order_key = d.order_key
    left join hpp_sku hs on hs.marketplace_account_id = d.marketplace_account_id and hs.marketplace_sku_id = lower(nullif(d.marketplace_sku_id, ''))
    left join hpp_seller hsel on hsel.marketplace_account_id = d.marketplace_account_id and hsel.marketplace_seller_sku = lower(nullif(d.marketplace_seller_sku, ''))
    left join hpp_local hl on hl.marketplace_account_id = d.marketplace_account_id and hl.local_sku = lower(nullif(d.local_sku, ''))
    left join margin_settings ms on ms.local_sku = lower(nullif(d.local_sku, ''))
    left join margin_products mp on mp.local_sku = lower(nullif(d.local_sku, ''))
  ),
  allocated as (
    select
      *,
      case
        when coalesce(order_payout, 0) = 0 then 0
        when coalesce(gross_order_scope, 0) > 0 and gross_line > 0 then order_payout * gross_line / gross_order_scope
        when coalesce(qty_order_scope, 0) > 0 then order_payout * qty / qty_order_scope
        else order_payout
      end as payout_allocated
    from enriched
  ),
  calculated as (
    select
      a.*,
      upper(coalesce(a.order_status, '')) as order_status_upper,
      case
        when upper(coalesce(a.order_status, '')) like '%CANCEL%'
          or upper(coalesce(a.order_status, '')) like '%REFUND%'
          or upper(coalesce(a.order_status, '')) like '%RETURN%' then 'Cancel/Refund/Return'
        when coalesce(a.payout_allocated, 0) <> 0 then coalesce(nullif(a.settlement_status, ''), 'Settled')
        else 'Belum Payout'
      end as payout_status_clean,
      (a.payout_allocated - (a.qty * a.unit_hpp)) as net_margin_nominal,
      case
        when a.payout_allocated > 0 then round(((a.payout_allocated - (a.qty * a.unit_hpp)) / a.payout_allocated * 100)::numeric, 2)
        else 0
      end as net_margin_percent
    from allocated a
  ),
  filtered_rows as (
    select c.*, row_number() over (order by order_date_wib desc, order_key desc) as rn
    from calculated c
    where (
      v_payout_filter = 'all'
      or (v_payout_filter = 'paid' and coalesce(c.payout_allocated, 0) <> 0 and c.payout_status_clean <> 'Cancel/Refund/Return')
      or (v_payout_filter = 'unpaid' and coalesce(c.payout_allocated, 0) = 0 and c.payout_status_clean <> 'Cancel/Refund/Return')
    )
  ),
  counted as (
    select count(*)::integer as total_count from filtered_rows
  ),
  paged as (
    select *
    from filtered_rows
    where rn > v_offset and rn <= v_offset + v_page_size
    order by rn
  )
  select
    (select total_count from counted),
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', md5(concat_ws('_', marketplace_account_id, order_key, marketplace_sku_id, live_local_sku)),
          'source', 'finance_sku_order_details_v24_6_82o',
          'order_id', order_key,
          'order_sn', order_key,
          'external_order_id', order_key,
          'order_date', order_date_wib,
          'order_created_at', order_date_wib,
          'created_time', order_date_wib,
          'created_at', order_date_wib,
          'finance_at', finance_at,
          'order_status', order_status,
          'status', order_status,
          'payout_status', payout_status_clean,
          'settlement_status', payout_status_clean,
          'tracking_number', tracking_number,
          'resi', tracking_number,
          'marketplace', marketplace,
          'shop_name', marketplace,
          'marketplace_account_id', marketplace_account_id,
          'marketplace_sku_id', marketplace_sku_id,
          'marketplace_sku', marketplace_sku_id,
          'marketplace_seller_sku', marketplace_seller_sku,
          'local_sku', live_local_sku,
          'product_name', product_name,
          'variant_name', variant_name,
          'quantity', qty,
          'qty', qty,
          'gross_line', gross_line,
          'gross_amount', gross_line,
          'payout_amount', payout_allocated,
          'payout_allocated', payout_allocated,
          'net_settlement', payout_allocated,
          'received_amount', payout_allocated
        ) || jsonb_build_object(
          'has_payout', (payout_allocated > 0),
          'hpp', unit_hpp,
          'hpp_per_item', unit_hpp,
          'unit_hpp', unit_hpp,
          'hpp_total', qty * unit_hpp,
          'net_profit', net_margin_nominal,
          'profit', net_margin_nominal,
          'net_margin_nominal', net_margin_nominal,
          'net_margin_percent', net_margin_percent,
          'margin_percent', net_margin_percent,
          'net_margin', net_margin_percent,
          'target_margin', target_margin_percent,
          'target_margin_percent', target_margin_percent,
          'target_margin_pct', target_margin_percent,
          'sku_target_margin_percent', target_margin_percent,
          'hpp_target_margin_percent', target_margin_percent,
          'default_target_margin_percent', target_margin_percent,
          'mapped_target_margin_percent', target_margin_percent,
          'statement_id', statement_id,
          'finance_report_id', finance_report_id
        )
      ),
      '[]'::jsonb
    )
  into v_total, v_rows
  from paged;

  v_total := coalesce(v_total, 0);
  v_total_pages := greatest(ceil(v_total::numeric / v_page_size::numeric)::integer, 1);

  v_result := jsonb_build_object(
    'ok', true,
    'source', 'finance_sku_order_details_v24_6_82o',
    'page', v_page,
    'page_size', v_page_size,
    'total', v_total,
    'total_count', v_total,
    'total_pages', v_total_pages,
    'rows', v_rows
  );

  return v_result;
end;
$function$;


-- 3. Wrapper for finance_sku_order_line_details
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
begin
  return public.finance_sku_order_details_v24_6_82o(
    p_start, p_end, p_marketplace, p_account_id, p_marketplace_sku, p_local_sku, p_search, p_payout_filter, p_page, p_page_size
  );
end;
$function$;
