-- Migration: Fix SKU Dashboard Regression & TikTok Shop Reconciliation details
-- Recreates public.finance_sku_payout_count_summary without the dummy UNION ALL block and filters out invalid/empty SKUs.

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
  v_user_id uuid;
  v_tenant_id uuid;
  v_marketplace text := lower(trim(coalesce(p_marketplace, '')));
  v_result jsonb;
begin
  begin
    v_user_id := nullif(
      coalesce(
        auth.uid()::text,
        (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
      ),
      ''
    )::uuid;
  exception when others then
    v_user_id := null;
  end;

  select coalesce(u.tenant_id, current_setting('app.current_tenant_id', true)::uuid)
    into v_tenant_id
  from public.users u
  where u.user_id = v_user_id
  limit 1;

  if v_tenant_id is null then
    v_tenant_id := coalesce(current_setting('app.current_tenant_id', true)::uuid, (select tenant_id from public.users limit 1));
  end if;

  if v_tenant_id is null then return '{"ok":false,"error":"tenant_id required"}'::jsonb; end if;

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
      (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date as order_date_wib
    from public.marketplace_orders o
    where o.tenant_id = v_tenant_id
      and (v_marketplace = '' or lower(coalesce(o.marketplace, '')) = v_marketplace)
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date >= v_start
      and (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date <= v_end
  ),
  finance_by_order as (
    select
      coalesce(nullif(order_id, ''), marketplace_order_id::text, 'no_order_id_' || md5(random()::text)) as order_key,
      marketplace_account_id,
      marketplace,
      max(settlement_status) as settlement_status,
      sum(coalesce(payout_amount, net_settlement, 0)) as payout_total
    from public.marketplace_finance_reports
    where tenant_id = v_tenant_id
      and (v_marketplace = '' or lower(coalesce(marketplace, '')) = v_marketplace)
      and (p_account_id is null or marketplace_account_id = p_account_id)
      and coalesce(settlement_date, period_start) >= v_start
      and coalesce(settlement_date, period_start) <= v_end
    group by 1, 2, 3
  ),
  detail as (
    select
      vo.marketplace_account_id,
      vo.marketplace,
      vo.order_key,
      vo.order_status,
      vo.order_date_wib,
      oi.marketplace_sku_id,
      oi.quantity as qty,
      coalesce(nullif(oi.marketplace_seller_sku, ''), nullif(oi.seller_sku, '')) as marketplace_seller_sku,
      coalesce(nullif(oi.mapped_local_sku, ''), nullif(oi.local_sku, ''), 'Unmapped') as local_sku,
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
    where oi.marketplace_sku_id is not null
      and nullif(trim(oi.marketplace_sku_id), '') is not null
      and nullif(trim(oi.marketplace_sku_id), '-') is not null
      and nullif(trim(coalesce(oi.marketplace_seller_sku, oi.seller_sku, '')), '') is not null
      and nullif(trim(coalesce(oi.marketplace_seller_sku, oi.seller_sku, '')), '-') is not null
  ),
  hpp_sku as (
    select tenant_id, marketplace_account_id, lower(nullif(marketplace_sku_id, '')) as marketplace_sku_id,
           max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
           max(nullif(local_sku, '')) as mapped_local_sku
    from public.marketplace_variant_hpp_mappings
    where coalesce(is_active, true) is true and nullif(marketplace_sku_id, '') is not null
      and tenant_id = v_tenant_id
    group by tenant_id, marketplace_account_id, lower(nullif(marketplace_sku_id, ''))
  ),
  hpp_seller as (
    select tenant_id, marketplace_account_id, lower(nullif(marketplace_seller_sku, '')) as marketplace_seller_sku,
           max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
           max(nullif(local_sku, '')) as mapped_local_sku
    from public.marketplace_variant_hpp_mappings
    where coalesce(is_active, true) is true and nullif(marketplace_seller_sku, '') is not null
      and tenant_id = v_tenant_id
    group by tenant_id, marketplace_account_id, lower(nullif(marketplace_seller_sku, ''))
  ),
  hpp_local as (
    select tenant_id, marketplace_account_id, lower(nullif(local_sku, '')) as local_sku,
           max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
           max(nullif(local_sku, '')) as mapped_local_sku
    from public.marketplace_variant_hpp_mappings
    where coalesce(is_active, true) is true and nullif(local_sku, '') is not null
      and tenant_id = v_tenant_id
    group by tenant_id, marketplace_account_id, lower(nullif(local_sku, ''))
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
      coalesce(hs.mapped_local_sku, hsel.mapped_local_sku, hl.mapped_local_sku, d.local_sku) as live_local_sku
    from detail d
    left join finance_by_order fbo
      on fbo.marketplace_account_id = d.marketplace_account_id
      and fbo.order_key = d.order_key
    left join hpp_sku hs on hs.marketplace_account_id = d.marketplace_account_id and hs.marketplace_sku_id = lower(nullif(d.marketplace_sku_id, ''))
    left join hpp_seller hsel on hsel.marketplace_account_id = d.marketplace_account_id and hsel.marketplace_seller_sku = lower(nullif(d.marketplace_seller_sku, ''))
    left join hpp_local hl on hl.marketplace_account_id = d.marketplace_account_id and hl.local_sku = lower(nullif(d.local_sku, ''))
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
        or upper(c.payout_status_clean) like '%CANCEL%'
        or upper(c.payout_status_clean) like '%REFUND%'
        or upper(c.payout_status_clean) like '%RETURN%'
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
      max(product_name) as product_name,
      max(variant_name) as variant_name,
      max(unit_hpp) as unit_hpp,

      count(*) filter (
        where not is_cancel_refund_return
          and coalesce(payout_allocated, 0) <> 0
      )::int as paid_rows,

      count(*) filter (
        where not is_cancel_refund_return
          and coalesce(payout_allocated, 0) = 0
          and payout_status_clean = 'Belum Payout'
      )::int as unpaid_rows,

      coalesce(sum(qty) filter (
        where not is_cancel_refund_return
          and coalesce(payout_allocated, 0) <> 0
      ), 0)::numeric as paid_qty,

      coalesce(sum(qty) filter (
        where not is_cancel_refund_return
          and coalesce(payout_allocated, 0) = 0
          and payout_status_clean = 'Belum Payout'
      ), 0)::numeric as unpaid_qty,

      coalesce(sum(gross_line) filter (
        where not is_cancel_refund_return
          and coalesce(payout_allocated, 0) <> 0
      ), 0)::numeric as paid_gross_total,

      coalesce(sum(gross_line) filter (
        where not is_cancel_refund_return
          and coalesce(payout_allocated, 0) = 0
          and payout_status_clean = 'Belum Payout'
      ), 0)::numeric as unpaid_gross_total,

      coalesce(sum(payout_allocated) filter (
        where not is_cancel_refund_return
          and coalesce(payout_allocated, 0) <> 0
      ), 0)::numeric as paid_payout_total,

      count(*)::int as all_rows,
      coalesce(sum(qty), 0)::numeric as all_qty,
      coalesce(sum(qty * unit_hpp), 0)::numeric as hpp_total
    from flagged
    group by 1, 2, 3, 4, 5
  )
  select jsonb_build_object(
    'ok', true,
    'version', 'finance_sku_payout_count_summary_2026_07_06_v6_clean_skus',
    'start', v_start,
    'end', v_end,
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'marketplace_account_id', marketplace_account_id,
      'marketplace', marketplace,
      'marketplace_sku', marketplace_seller_sku,
      'marketplace_sku_id', marketplace_sku_id,
      'marketplace_seller_sku', marketplace_seller_sku,
      'local_sku', local_sku,
      'product_name', product_name,
      'variant_name', variant_name,
      'unit_hpp', unit_hpp,
      'hpp_total', hpp_total,

      'paid_rows', paid_rows,
      'unpaid_rows', unpaid_rows,
      'paid_qty', paid_qty,
      'unpaid_qty', unpaid_qty,

      'settled_qty', paid_qty,
      'qty_unpaid', unpaid_qty,
      'paid_total', paid_rows,
      'unpaid_total', unpaid_rows,

      'paid_gross_total', paid_gross_total,
      'unpaid_gross_total', unpaid_gross_total,
      'paid_payout_total', paid_payout_total,

      'all_rows', all_rows,
      'all_qty', all_qty
    ) order by all_qty desc, product_name, variant_name), '[]'::jsonb)
  )
  into v_result
  from grouped;

  return coalesce(v_result, jsonb_build_object(
    'ok', true,
    'version', 'finance_sku_payout_count_summary_2026_07_06_v6_clean_skus',
    'start', v_start,
    'end', v_end,
    'rows', '[]'::jsonb
  ));
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
 SET statement_timeout TO '25s'
 AS $function$
declare
  v_tenant_id uuid := public.app_current_tenant_id_or_default();
  v_start date := coalesce(p_start, date_trunc('month', now() at time zone 'Asia/Jakarta')::date);
  v_end date := coalesce(p_end, (now() at time zone 'Asia/Jakarta')::date);
  v_marketplace text := nullif(lower(trim(coalesce(p_marketplace,''))), '');
  v_filter text := lower(trim(coalesce(p_payout_filter,'all')));
  v_local_sku text := lower(trim(coalesce(p_local_sku,'')));
  v_page integer := greatest(1, coalesce(p_page, 1));
  v_page_size integer := least(100, greatest(1, coalesce(p_page_size, 25)));
  v_offset integer;
  v_is_unmapped boolean := false;
  v_rows jsonb;
  v_total integer;
begin
  v_offset := (v_page - 1) * v_page_size;

  if v_marketplace in ('all','semua','_all','*','-','semua platform') then
    v_marketplace := null;
  end if;

  if v_filter in ('','all','semua','-') then
    v_filter := 'all';
  elsif v_filter in ('settled','released','release','payout','paid','sudah payout') then
    v_filter := 'paid';
  elsif v_filter in ('pending','unpaid','belum payout','no payout','missing payout') then
    v_filter := 'unpaid';
  end if;

  -- Detect UI "unmapped" label -> search for null local_sku in DB
  if v_local_sku in ('unmapped','not_mapped','tidak_dipetakan','belum dipetakan','belum_dipetakan') then
    v_is_unmapped := true;
    v_local_sku := '';
  end if;

  -- Fast path for unmapped: query marketplace_order_items directly
  if v_is_unmapped then
    with base as (
      select
        o.tenant_id,
        o.marketplace,
        coalesce(nullif(o.order_id::text,''), nullif(o.order_sn,''), o.marketplace_order_id::text) as order_key,
        o.order_created_at,
        o.order_status,
        o.marketplace_account_id,
        oi.marketplace_order_item_id,
        oi.marketplace_sku,
        oi.marketplace_seller_sku,
        oi.seller_sku,
        null::text as local_sku,
        oi.marketplace_product_name,
        oi.product_name,
        oi.marketplace_variant_name,
        oi.variant_name,
        greatest(1, coalesce(nullif(oi.quantity,0), nullif(oi.qty,0), 1))::integer as qty,
        coalesce(oi.gross_amount, 0)::numeric as gross_amount,
        coalesce(oi.unit_gross_amount, 0)::numeric as unit_price,
        oi.marketplace_product_id,
        oi.marketplace_sku_id,
        oi.marketplace_order_id
      from public.marketplace_order_items oi
      join public.marketplace_orders o
        on o.marketplace_order_id = oi.marketplace_order_id
        and o.tenant_id = oi.tenant_id
      where oi.tenant_id = v_tenant_id
        and (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date >= v_start
        and (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date <= v_end
        and (p_account_id is null or o.marketplace_account_id = p_account_id)
        and (
          v_marketplace is null
          or public._finance_marketplace_norm_20260624(o.marketplace)
             = public._finance_marketplace_norm_20260624(v_marketplace)
        )
        -- Exclude cancelled/unpaid/batal/failed/refunded orders
        and not (lower(coalesce(o.order_status, '')) ~ '(cancel|canceled|cancelled|batal|return|returned|refund|refunded|unpaid|failed|reject|in_cancel)')
        and not (lower(coalesce(o.payment_status, '')) ~ '(unpaid|failed|cancel|canceled|cancelled|refund|refunded)')
        -- Exclude UUID fake orders
        and not (o.order_sn ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        and not (coalesce(o.order_id, '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        -- unmapped: local_sku is null/empty on the item
        and coalesce(nullif(trim(oi.local_sku),''), nullif(trim(oi.mapped_local_sku),'')) is null
        -- Filter by p_marketplace_sku and p_search in unmapped path
        and (
          p_marketplace_sku is null or p_marketplace_sku = ''
          or lower(coalesce(oi.marketplace_sku, oi.marketplace_seller_sku, oi.seller_sku, '')) = lower(p_marketplace_sku)
        )
        and (
          p_search is null or p_search = ''
          or o.order_id::text ilike '%' || p_search || '%'
          or coalesce(oi.marketplace_product_name, oi.product_name, '') ilike '%' || p_search || '%'
        )
    ),
    unmapped_base as (
      select b.*
      from base b
      left join lateral (
        select m.local_sku
        from public.marketplace_sku_maps m
        where m.tenant_id = b.tenant_id
          and m.marketplace_account_id = b.marketplace_account_id
          and m.marketplace_product_id = b.marketplace_product_id
          and m.marketplace_sku_id = b.marketplace_sku_id
          and coalesce(m.status, 'active') = 'active'
        limit 1
      ) m on true
      where m.local_sku is null
    ),
    with_payout as (
      select
        u.*,
        coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)::numeric as order_payout,
        (fr.finance_report_id is not null) as has_payout
      from unmapped_base u
      left join lateral (
        select fr.finance_report_id, fr.payout_amount, fr.received_amount, fr.net_settlement
        from (
          select fr.finance_report_id, fr.payout_amount, fr.received_amount, fr.net_settlement, 1 as priority
          from public.marketplace_finance_reports fr
          where fr.tenant_id = u.tenant_id
            and fr.marketplace_account_id = u.marketplace_account_id
            and fr.order_id = u.order_key
            and coalesce(fr.report_type, '') <> 'statement'
          union all
          select fr.finance_report_id, fr.payout_amount, fr.received_amount, fr.net_settlement, 2 as priority
          from public.marketplace_finance_reports fr
          where fr.tenant_id = u.tenant_id
            and fr.marketplace_account_id = u.marketplace_account_id
            and fr.marketplace_order_id = u.marketplace_order_id
            and coalesce(fr.report_type, '') <> 'statement'
        ) fr
        order by priority
        limit 1
      ) fr on true
    ),
    filtered as (
      select *
      from with_payout
      where
        v_filter = 'all'
        or (v_filter = 'paid' and has_payout)
        or (v_filter = 'unpaid' and not has_payout)
    ),
    counted as (
      select count(*)::integer as total from filtered
    ),
    paged as (
      select * from filtered
      order by order_created_at desc, order_key, marketplace_order_item_id
      limit v_page_size offset v_offset
    )
    select
      coalesce(jsonb_agg(
        jsonb_build_object(
          'id', marketplace_order_item_id,
          'order_id', order_key,
          'order_sn', order_key,
          'marketplace', marketplace,
          'marketplace_name', marketplace,
          'created_at', order_created_at,
          'order_status', order_status,
          'status', order_status,
          'product_name', coalesce(marketplace_product_name, product_name, '-'),
          'variant_name', coalesce(marketplace_variant_name, variant_name, '-'),
          'marketplace_sku', coalesce(marketplace_sku, marketplace_seller_sku, seller_sku, '-'),
          'local_sku', 'Unmapped',
          'qty', qty,
          'quantity', qty,
          'gross_amount', gross_amount,
          'unit_price', unit_price,
          'order_payout', order_payout,
          'has_payout', has_payout
        ) order by order_created_at desc, order_key
      ), '[]'::jsonb),
      (select coalesce(max(total),0) from counted)
    into v_rows, v_total
    from paged;

    return jsonb_build_object(
      'ok', true,
      'source', 'unmapped_direct_join',
      'rows', v_rows,
      'total', v_total,
      'page', v_page,
      'page_size', v_page_size,
      'total_pages', ceil(v_total::numeric / v_page_size::numeric),
      'total_count', v_total,
      'summary_source', 'marketplace_order_items'
    );
  end if;

  -- Default mapped logic
  with base_items as (
    select
      i.marketplace_order_item_id,
      i.marketplace_order_id,
      o.marketplace,
      o.marketplace_account_id,
      coalesce(nullif(o.order_id::text,''), nullif(o.order_sn,''), o.marketplace_order_id::text) as order_key,
      o.order_created_at,
      o.order_status,
      i.marketplace_product_name,
      i.product_name,
      i.marketplace_variant_name,
      i.variant_name,
      i.marketplace_sku,
      i.marketplace_seller_sku,
      i.seller_sku,
      coalesce(nullif(trim(i.local_sku),''), nullif(trim(i.mapped_local_sku),'')) as local_sku,
      greatest(1, coalesce(nullif(i.quantity,0), nullif(i.qty,0), 1))::integer as qty,
      coalesce(i.gross_amount, 0)::numeric as gross_amount,
      coalesce(i.unit_gross_amount, 0)::numeric as unit_price
    from public.marketplace_order_items i
    join public.marketplace_orders o
      on o.marketplace_order_id = i.marketplace_order_id
      and o.tenant_id = i.tenant_id
    where i.tenant_id = v_tenant_id
      and (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date >= v_start
      and (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date <= v_end
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and (
        v_marketplace is null
        or public._finance_marketplace_norm_20260624(o.marketplace)
           = public._finance_marketplace_norm_20260624(v_marketplace)
      )
      -- Exclude cancelled/unpaid/batal/failed/refunded orders
      and not (lower(coalesce(o.order_status, '')) ~ '(cancel|canceled|cancelled|batal|return|returned|refund|refunded|unpaid|failed|reject|in_cancel)')
      and not (lower(coalesce(o.payment_status, '')) ~ '(unpaid|failed|cancel|canceled|cancelled|refund|refunded)')
      -- Exclude UUID fake orders
      and not (o.order_sn ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
      and not (coalesce(o.order_id, '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
  ),
  match_sku as (
    select *
    from base_items b
    where
      (
        p_marketplace_sku is null or p_marketplace_sku = ''
        or lower(coalesce(b.marketplace_sku, b.marketplace_seller_sku, b.seller_sku, '')) = lower(p_marketplace_sku)
      )
      and (
        v_local_sku is null or v_local_sku = ''
        or lower(coalesce(b.local_sku,'')) = v_local_sku
      )
      and (
        p_search is null or p_search = ''
        or b.order_key ilike '%' || p_search || '%'
        or coalesce(b.marketplace_product_name, b.product_name, '') ilike '%' || p_search || '%'
      )
  ),
  with_payout as (
    select
      m.*,
      coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)::numeric as order_payout,
      (fr.finance_report_id is not null) as has_payout
    from match_sku m
    left join lateral (
      select fr.finance_report_id, fr.payout_amount, fr.received_amount, fr.net_settlement
      from (
        select fr.finance_report_id, fr.payout_amount, fr.received_amount, fr.net_settlement, 1 as priority
        from public.marketplace_finance_reports fr
        where fr.tenant_id = v_tenant_id
          and fr.marketplace_account_id = m.marketplace_account_id
          and fr.order_id = m.order_key
          and coalesce(fr.report_type, '') <> 'statement'
        union all
        select fr.finance_report_id, fr.payout_amount, fr.received_amount, fr.net_settlement, 2 as priority
        from public.marketplace_finance_reports fr
        where fr.tenant_id = v_tenant_id
          and fr.marketplace_account_id = m.marketplace_account_id
          and fr.marketplace_order_id = m.marketplace_order_id
          and coalesce(fr.report_type, '') <> 'statement'
      ) fr
      order by priority
      limit 1
    ) fr on true
  ),
  filtered as (
    select *
    from with_payout
    where
      v_filter = 'all'
      or (v_filter = 'paid' and has_payout)
      or (v_filter = 'unpaid' and not has_payout)
  ),
  counted as (
    select count(*)::integer as total from filtered
  ),
  paged as (
    select * from filtered
    order by order_created_at desc, order_key, marketplace_order_item_id
    limit v_page_size offset v_offset
  )
  select
    coalesce(jsonb_agg(
      jsonb_build_object(
        'id', marketplace_order_item_id,
        'order_id', order_key,
        'order_sn', order_key,
        'marketplace', marketplace,
        'marketplace_name', marketplace,
        'created_at', order_created_at,
        'order_status', order_status,
        'status', order_status,
        'product_name', coalesce(marketplace_product_name, product_name, '-'),
        'variant_name', coalesce(marketplace_variant_name, variant_name, '-'),
        'marketplace_sku', coalesce(marketplace_sku, marketplace_seller_sku, seller_sku, '-'),
        'local_sku', coalesce(local_sku, 'Unmapped'),
        'qty', qty,
        'quantity', qty,
        'gross_amount', gross_amount,
        'unit_price', unit_price,
        'order_payout', order_payout,
        'has_payout', has_payout
      ) order by order_created_at desc, order_key
    ), '[]'::jsonb),
    (select coalesce(max(total),0) from counted)
  into v_rows, v_total
  from paged;

  return jsonb_build_object(
    'ok', true,
    'source', 'mapped_direct_join',
    'rows', v_rows,
    'total', v_total,
    'page', v_page,
    'page_size', v_page_size,
    'total_pages', ceil(v_total::numeric / v_page_size::numeric),
    'total_count', v_total,
    'summary_source', 'marketplace_order_items'
  );
end;
$function$;
