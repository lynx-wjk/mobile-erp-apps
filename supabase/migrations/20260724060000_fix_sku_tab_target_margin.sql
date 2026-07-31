-- Migration: 20260724060000_fix_sku_tab_target_margin.sql
-- Fixes Target Margin calculation & sync in SKU tab & per-SKU detail popups

-- 1. Update finance_upsert_sku_target_margin to write to all target margin tables
CREATE OR REPLACE FUNCTION public.finance_upsert_sku_target_margin(
  p_sku text,
  p_target_margin_percent numeric DEFAULT 30
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_tenant_id uuid := public.app_current_tenant_id_or_default();
  v_sku text := nullif(trim(p_sku), '');
  v_target_margin numeric := coalesce(p_target_margin_percent, 30);
  v_count integer := 0;
begin
  if v_sku is null then
    return jsonb_build_object('ok', false, 'message', 'SKU is required');
  end if;

  -- Update/Insert in finance_sku_margin_settings
  INSERT INTO public.finance_sku_margin_settings (
    margin_setting_id, tenant_id, local_sku, target_margin_percent, updated_by, created_at, updated_at
  )
  VALUES (
    gen_random_uuid(), v_tenant_id, v_sku, v_target_margin, auth.uid(), now(), now()
  )
  ON CONFLICT (tenant_id, local_sku) DO UPDATE
  SET target_margin_percent = EXCLUDED.target_margin_percent,
      updated_by = EXCLUDED.updated_by,
      updated_at = EXCLUDED.updated_at;

  -- Sync to products table if local_sku matches kode_sku
  UPDATE public.products
     SET target_margin_percent = v_target_margin,
         updated_at = now()
   WHERE tenant_id = v_tenant_id
     AND lower(trim(kode_sku)) = lower(v_sku);

  -- Sync to marketplace_variant_hpp_mappings
  UPDATE public.marketplace_variant_hpp_mappings
     SET target_margin_percent = v_target_margin,
         target_margin = v_target_margin,
         updated_at = now()
   WHERE tenant_id = v_tenant_id
     AND (
       lower(trim(local_sku)) = lower(v_sku)
       OR lower(trim(marketplace_sku_id)) = lower(v_sku)
       OR lower(trim(marketplace_seller_sku)) = lower(v_sku)
     );

  return jsonb_build_object('ok', true, 'sku', v_sku, 'target_margin_percent', v_target_margin);
end;
$function$;


-- 2. Update finance_sku_payout_count_summary to populate target_margin_percent in SKU rows
CREATE OR REPLACE FUNCTION public.finance_sku_payout_count_summary(
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
  v_result jsonb;
begin
  if v_tenant_id is null then return '{"ok":false,"error":"tenant_id required"}'::jsonb; end if;

  if v_marketplace in ('all', 'semua', 'semua platform', '-') then
    v_marketplace := '';
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
      coalesce(nullif(o.external_order_id, ''), nullif(o.order_sn, ''), o.marketplace_order_id::text) as order_key,
      (coalesce(o.paid_at, coalesce(o.order_created_at, o.created_time, o.created_at)) at time zone 'Asia/Jakarta') as order_ts_wib,
      (coalesce(o.paid_at, coalesce(o.order_created_at, o.created_time, o.created_at)) at time zone 'Asia/Jakarta')::date as order_date_wib
    from public.marketplace_orders o
    where o.tenant_id = v_tenant_id
      and (v_marketplace = '' or lower(coalesce(o.marketplace, '')) = v_marketplace)
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and (coalesce(o.paid_at, coalesce(o.order_created_at, o.created_time, o.created_at)) at time zone 'Asia/Jakarta')::date between v_start and v_end
      and not (
        upper(coalesce(o.order_status, o.status, o.raw_order->>'status', '')) like any (
          array['%CANCEL%', '%UNPAID%', '%REFUND%', '%RETURN%', '%FAILED%', '%CLOSE%']
        )
      )
  ),
  finance_by_order as (
    select
      coalesce(nullif(fr.order_id, ''), fr.marketplace_order_id::text, 'no_order_id_' || md5(random()::text)) as order_key,
      fr.marketplace_account_id,
      fr.marketplace,
      max(fr.settlement_status) as settlement_status,
      sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0)) as payout_total
    from public.marketplace_finance_reports fr
    where fr.tenant_id = v_tenant_id
      and (v_marketplace = '' or lower(coalesce(fr.marketplace, '')) = v_marketplace)
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and coalesce(fr.settlement_date, fr.period_start) >= v_start - 30
      and coalesce(fr.settlement_date, fr.period_start) <= v_end + 30
    group by 1, 2, 3
  ),
  detail as (
    select
      vo.marketplace_account_id,
      vo.marketplace,
      vo.order_key,
      vo.order_status,
      vo.order_date_wib,
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
      ) as gross_line
    from valid_orders vo
    join public.marketplace_order_items oi
      on oi.tenant_id = vo.tenant_id
     and oi.marketplace_order_id = vo.marketplace_order_id
    where coalesce(
      nullif(trim(oi.marketplace_sku_id), ''),
      nullif(trim(oi.marketplace_seller_sku), ''),
      nullif(trim(oi.seller_sku), ''),
      nullif(trim(oi.local_sku), ''),
      nullif(trim(oi.mapped_local_sku), '')
    ) is not null
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
      d.marketplace_sku_id,
      d.qty,
      d.marketplace_seller_sku,
      d.local_sku,
      d.product_name,
      d.variant_name,
      d.gross_line,
      fbo.payout_total as order_payout,
      fbo.settlement_status,
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
    from detail d
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
        when coalesce(a.order_payout, 0) = 0 then 'Belum Payout'
        when a.payout_allocated < 0 then 'Payout Minus'
        else coalesce(nullif(a.settlement_status, ''), 'Settled')
      end as payout_status_clean
    from allocated a
  ),
  flagged as (
    select
      c.*,
      (
        c.order_status_upper like '%CANCEL%'
        or c.order_status_upper like '%REFUND%'
        or c.order_status_upper like '%RETURN%'
        or payout_status_clean = 'Cancel/Refund/Return'
      ) as is_cancel_refund_return
    from calculated c
  ),
  grouped as (
    select
      marketplace_account_id,
      marketplace,
      coalesce(nullif(marketplace_sku_id, ''), '-') as marketplace_sku_id,
      coalesce(nullif(marketplace_seller_sku, ''), '-') as marketplace_seller_sku,
      coalesce(nullif(local_sku, ''), '-') as local_sku,
      max(trim(product_name)) as product_name,
      max(trim(variant_name)) as variant_name,
      max(unit_hpp) as unit_hpp,
      max(target_margin_percent) as target_margin_percent,
      count(*) filter (where not is_cancel_refund_return and coalesce(payout_allocated, 0) <> 0)::int as paid_rows,
      count(*) filter (where not is_cancel_refund_return and coalesce(payout_allocated, 0) = 0 and payout_status_clean = 'Belum Payout')::int as unpaid_rows,
      coalesce(sum(qty) filter (where not is_cancel_refund_return and coalesce(payout_allocated, 0) <> 0), 0)::numeric as paid_qty,
      coalesce(sum(qty) filter (where not is_cancel_refund_return and coalesce(payout_allocated, 0) = 0 and payout_status_clean = 'Belum Payout'), 0)::numeric as unpaid_qty,
      coalesce(sum(gross_line) filter (where not is_cancel_refund_return and coalesce(payout_allocated, 0) <> 0), 0)::numeric as paid_gross_total,
      coalesce(sum(gross_line) filter (where not is_cancel_refund_return and coalesce(payout_allocated, 0) = 0 and payout_status_clean = 'Belum Payout'), 0)::numeric as unpaid_gross_total,
      coalesce(sum(payout_allocated) filter (where not is_cancel_refund_return and coalesce(payout_allocated, 0) <> 0), 0)::numeric as paid_payout_total,
      coalesce(sum(qty * unit_hpp) filter (where not is_cancel_refund_return and coalesce(payout_allocated, 0) <> 0), 0)::numeric as hpp_total,
      count(*)::int as all_rows,
      coalesce(sum(qty), 0)::numeric as all_qty
    from flagged
    group by 1, 2, 3, 4, 5
  )
  select jsonb_build_object(
    'ok', true,
    'source', 'finance_sku_payout_count_summary_with_target_margin',
    'rows', coalesce(
      (select jsonb_agg(
        jsonb_build_object(
          'source', 'finance_sku_order_details_group_from_payout_summary_20260625_fixed_v2',
          'sku', coalesce(nullif(x.local_sku, ''), 'Unmapped'),
          'quantity', x.all_qty,
          'qty', x.all_qty,
          'qty_total', x.all_qty,
          'gross_sales', x.paid_gross_total + x.unpaid_gross_total,
          'gross_total', x.paid_gross_total + x.unpaid_gross_total,
          'payout_total', x.paid_payout_total,
          'payout_amount', x.paid_payout_total,
          'received_amount', x.paid_payout_total,
          'net_settlement', x.paid_payout_total,
          'order_count', x.all_rows,
          'paid_order_count', x.paid_rows,
          'unpaid_order_count', x.unpaid_rows,
          'settled_qty', x.paid_qty,
          'qty_settled', x.paid_qty,
          'hpp', x.hpp_total,
          'hpp_total', x.hpp_total,
          'total_hpp', x.hpp_total,
          'unit_hpp', x.unit_hpp,
          'target_margin_percent', x.target_margin_percent,
          'target_margin', x.target_margin_percent,
          'target_margin_pct', x.target_margin_percent,
          'sku_target_margin_percent', x.target_margin_percent,
          'hpp_target_margin_percent', x.target_margin_percent,
          'default_target_margin_percent', x.target_margin_percent,
          'mapped_target_margin_percent', x.target_margin_percent,
          'product_name', x.product_name,
          'nama_barang', x.product_name,
          'variant_name', x.variant_name,
          'marketplace_sku', x.marketplace_sku_id,
          'marketplace_sku_id', x.marketplace_sku_id,
          'marketplace_seller_sku', x.marketplace_seller_sku,
          'local_sku', x.local_sku,
          'marketplace', x.marketplace,
          'marketplace_account_id', x.marketplace_account_id
        )
      ) from grouped x), '[]'::jsonb
    )
  )
  into v_result;

  return coalesce(v_result, '{"ok":true,"rows":[]}'::jsonb);
end;
$function$;


-- 3. Update finance_sku_order_details_v24_6_82o to populate target_margin_percent in detail lines
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
  v_tenant_id uuid := public.app_current_tenant_id_or_default();
  v_start date := coalesce(p_start, current_date - 30);
  v_end date := coalesce(p_end, current_date);
  v_marketplace text := lower(trim(coalesce(p_marketplace, '')));
  v_marketplace_sku text := lower(trim(coalesce(p_marketplace_sku, '')));
  v_local_sku text := lower(trim(coalesce(p_local_sku, '')));
  v_search text := lower(trim(coalesce(p_search, '')));
  v_payout_filter text := lower(trim(coalesce(p_payout_filter, 'all')));
  v_page integer := greatest(1, coalesce(p_page, 1));
  v_page_size integer := greatest(1, least(coalesce(p_page_size, 20), 100));
  v_offset integer := (v_page - 1) * v_page_size;
  v_result jsonb;
begin
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

  if (v_end - v_start) > 90 then
    v_start := v_end - 90;
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
      coalesce(nullif(o.external_order_id, ''), nullif(o.order_sn, ''), o.marketplace_order_id::text) as order_key,
      (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta') as order_ts_wib,
      (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date as order_date_wib,
      coalesce(o.tracking_number, o.label_code) as tracking_number_clean
    from public.marketplace_orders o
    where o.tenant_id = v_tenant_id
      and (v_marketplace = '' or lower(coalesce(o.marketplace, '')) = v_marketplace)
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date between v_start and v_end
      and not (
        upper(coalesce(o.order_status, o.status, o.raw_order->>'status', '')) like any (
          array['%CANCEL%', '%UNPAID%', '%REFUND%', '%RETURN%', '%FAILED%', '%CLOSE%']
        )
      )
  ),
  finance_by_order as (
    select
      fr.marketplace_account_id,
      coalesce(nullif(fr.order_id, ''), fr.marketplace_order_id::text) as order_key,
      sum(coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)) as payout_total,
      max(fr.statement_id::text) as statement_id,
      max(fr.settlement_status) as settlement_status,
      max(fr.pulled_at) as finance_at
    from public.marketplace_finance_reports fr
    where fr.tenant_id = v_tenant_id
      and (v_marketplace = '' or lower(coalesce(fr.marketplace, '')) = v_marketplace)
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and coalesce(fr.settlement_date, fr.period_start) >= v_start - 30
      and coalesce(fr.settlement_date, fr.period_start) <= v_end + 30
    group by 1, 2
  ),
  detail as (
    select
      vo.marketplace_account_id,
      vo.marketplace,
      vo.order_key,
      vo.external_order_id,
      vo.order_sn,
      vo.marketplace_order_id,
      vo.tracking_number_clean as tracking_number,
      coalesce(vo.order_status, vo.status) as order_status,
      vo.order_date_wib,
      vo.order_ts_wib,
      oi.marketplace_order_item_id,
      coalesce(nullif(oi.quantity, 0), nullif(oi.qty, 0), 1) as qty,
      coalesce(nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, '')) as marketplace_sku_id,
      coalesce(nullif(oi.marketplace_seller_sku, ''), nullif(oi.seller_sku, '')) as marketplace_seller_sku,
      coalesce(nullif(trim(oi.mapped_local_sku),''), nullif(trim(oi.local_sku),''), nullif(trim(oi.seller_sku),''), nullif(trim(oi.marketplace_seller_sku),''), nullif(trim(oi.marketplace_sku_id),''), '-') as local_sku,
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
      or (
        (v_marketplace_sku = '' or (
          lower(coalesce(oi.marketplace_sku_id, oi.remote_sku_id, '')) = v_marketplace_sku
          or lower(coalesce(oi.marketplace_seller_sku, oi.seller_sku, '')) = v_marketplace_sku
          or lower(coalesce(oi.mapped_local_sku, oi.local_sku, '')) = v_marketplace_sku
        ))
        and (v_local_sku = '' or (
          lower(coalesce(oi.mapped_local_sku, oi.local_sku, '')) = v_local_sku
          or lower(coalesce(oi.marketplace_seller_sku, oi.seller_sku, '')) = v_local_sku
          or lower(coalesce(oi.marketplace_sku_id, oi.remote_sku_id, '')) = v_local_sku
        ))
      )
    )
    and (
      v_search = ''
      or lower(coalesce(oi.product_name, '')) like '%' || v_search || '%'
      or lower(coalesce(oi.variant_name, '')) like '%' || v_search || '%'
      or lower(coalesce(oi.marketplace_sku_id, '')) like '%' || v_search || '%'
      or lower(coalesce(oi.marketplace_seller_sku, '')) like '%' || v_search || '%'
      or lower(coalesce(oi.local_sku, '')) like '%' || v_search || '%'
      or lower(coalesce(vo.external_order_id, '')) like '%' || v_search || '%'
      or lower(coalesce(vo.order_sn, '')) like '%' || v_search || '%'
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
      d.*,
      fbo.payout_total as order_payout,
      fbo.statement_id,
      fbo.settlement_status,
      fbo.finance_at,
      acc.store_alias,
      acc.shop_name,
      sum(nullif(d.gross_line, 0)) over (partition by d.marketplace_account_id, d.order_key) as gross_order_scope,
      sum(d.qty) over (partition by d.marketplace_account_id, d.order_key) as qty_order_scope,
      coalesce(hs.hpp, hsel.hpp, hl.hpp, 0)::numeric as hpp_per_item,
      coalesce(
        ms.target_margin_percent,
        hs.target_margin_percent,
        hsel.target_margin_percent,
        hl.target_margin_percent,
        mp.target_margin_percent,
        30
      )::numeric as target_margin_percent,
      coalesce(hs.mapped_local_sku, hsel.mapped_local_sku, hl.mapped_local_sku, d.local_sku) as live_local_sku
    from detail d
    left join public.marketplace_accounts acc
      on acc.tenant_id = v_tenant_id
     and acc.marketplace_account_id = d.marketplace_account_id
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
      (a.qty * a.hpp_per_item) as hpp_total,
      case
        when coalesce(a.order_payout, 0) <> 0 then a.payout_allocated - (a.qty * a.hpp_per_item)
        else a.gross_line - (a.qty * a.hpp_per_item)
      end as net_margin_nominal,
      case
        when coalesce(a.order_payout, 0) <> 0 then
          case when a.payout_allocated > 0 then ((a.payout_allocated - (a.qty * a.hpp_per_item)) / a.payout_allocated) * 100 else null end
        else
          case when a.gross_line > 0 then ((a.gross_line - (a.qty * a.hpp_per_item)) / a.gross_line) * 100 else null end
      end as net_margin_percent,
      case
        when coalesce(a.order_payout, 0) = 0 then 'Belum Payout'
        when a.payout_allocated < 0 then 'Payout Minus'
        else coalesce(nullif(a.settlement_status, ''), 'Settled')
      end as payout_status_clean
    from allocated a
  ),
  filtered as (
    select *
    from calculated
    where (
      v_payout_filter = 'all'
      or (v_payout_filter = 'paid' and payout_status_clean in ('Settled', 'Payout Minus'))
      or (v_payout_filter = 'unpaid' and payout_status_clean = 'Belum Payout')
    )
  ),
  total_count as (
    select count(*)::integer as total from filtered
  ),
  agg as (
    select
      coalesce(sum(qty), 0)::numeric as total_qty,
      coalesce(sum(gross_line), 0)::numeric as total_gross,
      coalesce(sum(payout_allocated), 0)::numeric as total_payout,
      coalesce(sum(hpp_total), 0)::numeric as total_hpp,
      coalesce(sum(net_margin_nominal), 0)::numeric as total_margin_nominal
    from filtered
  ),
  paged as (
    select *
    from filtered
    order by order_ts_wib desc nulls last, marketplace_order_item_id desc
    limit v_page_size offset v_offset
  ),
  rows_json as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'source', 'finance_sku_order_details_v24_6_82o',
      'marketplace', marketplace,
      'shop_name', coalesce(shop_name, store_alias, ''),
      'marketplace_account_id', marketplace_account_id,
      'order_id', order_key,
      'order_sn', order_key,
      'external_order_id', coalesce(external_order_id, order_sn, order_key),
      'tracking_number', tracking_number,
      'resi', tracking_number,
      'status', case when payout_status_clean in ('Settled', 'Payout Minus') then payout_status_clean else order_status end,
      'order_status', case when payout_status_clean in ('Settled', 'Payout Minus') then payout_status_clean else order_status end,
      'order_date', order_date_wib,
      'order_created_at', order_ts_wib,
      'created_time', order_ts_wib,
      'statement_id', statement_id,
      'finance_at', finance_at,
      'marketplace_sku_id', marketplace_sku_id,
      'marketplace_sku', marketplace_sku_id,
      'marketplace_seller_sku', marketplace_seller_sku,
      'local_sku', local_sku,
      'product_name', product_name,
      'variant_name', variant_name,
      'quantity', qty,
      'qty', qty,
      'gross_line', gross_line,
      'gross_amount', gross_line,
      'payout_allocated', payout_allocated,
      'payout_amount', payout_allocated,
      'received_amount', payout_allocated,
      'net_settlement', payout_allocated,
      'hpp', hpp_per_item,
      'hpp_per_item', hpp_per_item,
      'hpp_total', hpp_total,
      'target_margin_percent', target_margin_percent,
      'target_margin', target_margin_percent,
      'target_margin_pct', target_margin_percent,
      'sku_target_margin_percent', target_margin_percent,
      'hpp_target_margin_percent', target_margin_percent,
      'default_target_margin_percent', target_margin_percent,
      'mapped_target_margin_percent', target_margin_percent,
      'net_margin_nominal', net_margin_nominal,
      'net_margin_percent', net_margin_percent,
      'payout_status', payout_status_clean,
      'settlement_status', payout_status_clean
    )), '[]'::jsonb) as rows
    from paged
  )
  select jsonb_build_object(
    'ok', true,
    'version', 'v24_6_82o_details_target_margin_fixed_20260724',
    'page', v_page,
    'page_size', v_page_size,
    'total', total_count.total,
    'total_pages', case when v_page_size > 0 then ceil(total_count.total::numeric / v_page_size)::integer else 0 end,
    'rows', rows_json.rows,
    'aggregates', jsonb_build_object(
      'total_qty', agg.total_qty,
      'total_gross', agg.total_gross,
      'total_payout', agg.total_payout,
      'total_hpp', agg.total_hpp,
      'total_margin_nominal', agg.total_margin_nominal
    )
  )
  into v_result
  from total_count
  cross join agg
  cross join rows_json;

  return coalesce(v_result, jsonb_build_object(
    'ok', true,
    'version', 'v24_6_82o_details_target_margin_fixed_20260724',
    'page', v_page,
    'page_size', v_page_size,
    'total', 0,
    'total_pages', 0,
    'rows', '[]'::jsonb,
    'aggregates', jsonb_build_object(
      'total_qty', 0,
      'total_gross', 0,
      'total_payout', 0,
      'total_hpp', 0,
      'total_margin_nominal', 0
    )
  ));
end;
$function$;
