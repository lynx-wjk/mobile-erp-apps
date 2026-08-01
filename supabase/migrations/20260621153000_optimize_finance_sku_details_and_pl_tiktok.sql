-- Migration: Optimize finance_sku_order_details performance and fix TikTok Laba Rugi discount aggregation
-- Created: 2026-06-21

create or replace function public.finance_sku_order_details(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null,
  p_marketplace_sku text default null,
  p_local_sku text default null,
  p_search text default null,
  p_payout_filter text default 'all',
  p_page integer default 1,
  p_page_size integer default 20
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '30s'
as $$
declare
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_tenant_id uuid;
  v_role text;
  v_start date := coalesce(p_start, date_trunc('month', timezone('Asia/Jakarta', now()))::date);
  v_end date := coalesce(p_end, timezone('Asia/Jakarta', now())::date);
  v_start_ts timestamptz;
  v_end_ts timestamptz;
  v_marketplace text;
  v_account_id uuid := p_account_id;
  v_marketplace_sku text := lower(nullif(trim(coalesce(p_marketplace_sku, '')), ''));
  v_local_sku text := lower(nullif(trim(coalesce(p_local_sku, '')), ''));
  v_search text := lower(nullif(trim(coalesce(p_search, '')), ''));
  v_filter text := lower(trim(coalesce(p_payout_filter, 'all')));
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_page_size integer := least(greatest(coalesce(p_page_size, 20), 1), 25);
  v_offset integer;
  v_detail_mode boolean;
begin
  -- Set local work_mem to 64MB to keep sorts in-memory (e.g. for partition window functions)
  perform set_config('work_mem', '64MB', true);

  select
    coalesce(
      case
        when (v_claims->>'tenant_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        then (v_claims->>'tenant_id')::uuid
        else null::uuid
      end,
      (select u.tenant_id from public.users u where u.user_id = auth.uid() limit 1)
    ),
    coalesce(nullif(v_claims->>'role', ''), '')
  into v_tenant_id, v_role;

  v_start_ts := (v_start::timestamp at time zone 'Asia/Jakarta');
  v_end_ts := ((v_end + 1)::timestamp at time zone 'Asia/Jakarta');
  v_offset := (v_page - 1) * v_page_size;
  v_filter := case
    when v_filter in ('settled', 'released', 'release', 'payout', 'paid payout', 'sudah payout') then 'paid'
    when v_filter in ('pending', 'belum payout', 'no payout', 'missing payout') then 'unpaid'
    when v_filter = '' then 'all'
    else v_filter
  end;
  v_marketplace := case
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
    else null
  end;
  v_detail_mode := v_marketplace_sku is not null
    or v_local_sku is not null
    or v_search is not null;

  if v_role <> 'service_role' and v_tenant_id is null then
    return jsonb_build_object(
      'rows', '[]'::jsonb,
      'page', v_page,
      'page_size', v_page_size,
      'total', 0,
      'total_count', 0,
      'total_pages', 1,
      'source', 'finance_sku_order_details_fast_mtd'
    );
  end if;

  if v_detail_mode then
    return (
      with order_base as (
        select *
        from (
          select
            o.marketplace_order_id,
            o.tenant_id,
            o.marketplace_account_id,
            o.order_created_at,
            timezone('Asia/Jakarta', o.order_created_at)::date as order_date,
            coalesce(nullif(o.order_id::text, ''), nullif(o.order_sn::text, ''), nullif(o.external_order_id::text, ''), o.marketplace_order_id::text) as order_key,
            coalesce(nullif(o.order_sn::text, ''), nullif(o.external_order_id::text, ''), nullif(o.order_id::text, '')) as order_sn,
            coalesce(nullif(o.tracking_number, ''), nullif(o.label_code, ''), nullif(o.package_id, '')) as tracking_number,
            lower(concat_ws(' ', o.order_status, o.status, o.payment_status, o.fulfillment_status, o.order_status_label)) as status_text,
            coalesce(nullif(o.gross_amount, 0), nullif(o.total_amount, 0), nullif(o.paid_amount, 0), 0)::numeric as order_gross,
            case
              when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
              when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
              else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
            end as marketplace_group
          from public.marketplace_orders o
          where o.order_created_at >= v_start_ts
            and o.order_created_at < v_end_ts
            and (v_role = 'service_role' or o.tenant_id = v_tenant_id)
            and (v_account_id is null or o.marketplace_account_id = v_account_id)
        ) o
        where (v_marketplace is null or o.marketplace_group = v_marketplace)
          and o.status_text not like '%cancel%'
          and o.status_text not like '%batal%'
          and o.status_text not like '%unpaid%'
          and o.status_text not like '%in_cancel%'
      ),
      finance_by_order as (
        select
          ob.marketplace_order_id,
          coalesce(sum(coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)), 0)::numeric as payout,
          coalesce(sum(coalesce(fr.gross_amount, fr.gross_sales, 0)), 0)::numeric as finance_gross
        from order_base ob
        join public.marketplace_finance_reports fr
          on fr.tenant_id = ob.tenant_id
         and fr.marketplace_account_id = ob.marketplace_account_id
         and fr.order_id = ob.order_key
        group by ob.marketplace_order_id
      ),
      line_base as (
        select
          ob.*,
          oi.marketplace_order_item_id,
          coalesce(nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, '')) as marketplace_sku_id,
          coalesce(nullif(oi.marketplace_sku, ''), nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, '')) as marketplace_sku,
          coalesce(nullif(oi.marketplace_seller_sku, ''), nullif(oi.seller_sku, '')) as marketplace_seller_sku,
          coalesce(nullif(oi.local_sku, ''), nullif(oi.mapped_local_sku, '')) as local_sku,
          coalesce(nullif(oi.marketplace_product_name, ''), nullif(oi.product_name, ''), nullif(oi.local_product_name, '')) as product_name,
          coalesce(nullif(oi.marketplace_variant_name, ''), nullif(oi.variant_name, ''), nullif(oi.variation_name, '')) as variant_name,
          greatest(coalesce(nullif(oi.qty, 0), nullif(oi.quantity, 0), 1), 1)::numeric as qty,
          coalesce(
            nullif(oi.gross_amount, 0),
            nullif(oi.paid_amount, 0),
            nullif(oi.unit_gross_amount, 0) * greatest(coalesce(nullif(oi.qty, 0), nullif(oi.quantity, 0), 1), 1),
            0
          )::numeric as line_gross
        from order_base ob
        join public.marketplace_order_items oi
          on oi.tenant_id = ob.tenant_id
         and oi.marketplace_order_id = ob.marketplace_order_id
        where (v_marketplace_sku is null or v_marketplace_sku in (
            lower(coalesce(oi.marketplace_sku_id, '')),
            lower(coalesce(oi.marketplace_sku, '')),
            lower(coalesce(oi.remote_sku_id, '')),
            lower(coalesce(oi.marketplace_seller_sku, '')),
            lower(coalesce(oi.seller_sku, ''))
          ))
          and (v_local_sku is null or v_local_sku = lower(coalesce(oi.local_sku, oi.mapped_local_sku, '')))
          and (v_search is null or lower(concat_ws(' ', ob.order_key, ob.order_sn, ob.tracking_number, oi.marketplace_sku_id, oi.marketplace_sku, oi.marketplace_seller_sku, oi.seller_sku, oi.local_sku, oi.mapped_local_sku, oi.marketplace_product_name, oi.product_name, oi.marketplace_variant_name, oi.variant_name)) like '%' || v_search || '%')
      ),
      line_calc as (
        select lb.*, sum(lb.line_gross) over (partition by lb.marketplace_order_id) as order_line_gross
        from line_base lb
      ),
      enriched_base as (
        select
          lc.*,
          coalesce(f.payout, 0)::numeric as order_payout,
          (f.marketplace_order_id is not null) as has_payout
        from line_calc lc
        left join finance_by_order f on f.marketplace_order_id = lc.marketplace_order_id
      ),
      filtered as (
        select *
        from enriched_base
        where (v_filter = 'all' or (v_filter = 'paid' and has_payout) or (v_filter = 'unpaid' and not has_payout))
      ),
      counted as (
        select filtered.*, count(*) over ()::integer as total_count
        from filtered
      ),
      paged as (
        select *
        from counted
        order by order_created_at desc, order_key
        offset v_offset
        limit v_page_size
      ),
      hpp_sku as (
        select tenant_id, marketplace_account_id, lower(nullif(marketplace_sku_id, '')) as marketplace_sku_id,
               max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
               max(coalesce(target_margin_percent, target_margin, 0))::numeric as target_margin
        from public.marketplace_variant_hpp_mappings
        where coalesce(is_active, true) is true and nullif(marketplace_sku_id, '') is not null
          and (v_role = 'service_role' or tenant_id = v_tenant_id)
        group by tenant_id, marketplace_account_id, lower(nullif(marketplace_sku_id, ''))
      ),
      hpp_seller as (
        select tenant_id, marketplace_account_id, lower(nullif(marketplace_seller_sku, '')) as marketplace_seller_sku,
               max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
               max(coalesce(target_margin_percent, target_margin, 0))::numeric as target_margin
        from public.marketplace_variant_hpp_mappings
        where coalesce(is_active, true) is true and nullif(marketplace_seller_sku, '') is not null
          and (v_role = 'service_role' or tenant_id = v_tenant_id)
        group by tenant_id, marketplace_account_id, lower(nullif(marketplace_seller_sku, ''))
      ),
      hpp_local as (
        select tenant_id, marketplace_account_id, lower(nullif(local_sku, '')) as local_sku,
               max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
               max(coalesce(target_margin_percent, target_margin, 0))::numeric as target_margin
        from public.marketplace_variant_hpp_mappings
        where coalesce(is_active, true) is true and nullif(local_sku, '') is not null
          and (v_role = 'service_role' or tenant_id = v_tenant_id)
        group by tenant_id, marketplace_account_id, lower(nullif(local_sku, ''))
      ),
      paged_enriched as (
        select
          p.*,
          coalesce(hs.hpp, hsel.hpp, hl.hpp, 0)::numeric as unit_hpp,
          coalesce(hs.target_margin, hsel.target_margin, hl.target_margin, 0)::numeric as target_margin
        from paged p
        left join hpp_sku hs on hs.tenant_id = p.tenant_id and hs.marketplace_account_id = p.marketplace_account_id and hs.marketplace_sku_id = lower(nullif(p.marketplace_sku_id, ''))
        left join hpp_seller hsel on hsel.tenant_id = p.tenant_id and hsel.marketplace_account_id = p.marketplace_account_id and hsel.marketplace_seller_sku = lower(nullif(p.marketplace_seller_sku, ''))
        left join hpp_local hl on hl.tenant_id = p.tenant_id and hl.marketplace_account_id = p.marketplace_account_id and hl.local_sku = lower(nullif(p.local_sku, ''))
      )
      select jsonb_build_object(
        'rows', coalesce(jsonb_agg(jsonb_build_object(
          'source', 'finance_sku_order_details_fast_mtd_detail',
          'order', order_key,
          'order_id', order_key,
          'order_sn', order_sn,
          'marketplace_order_id', marketplace_order_id,
          'marketplace_order_item_id', marketplace_order_item_id,
          'resi', tracking_number,
          'tracking_number', tracking_number,
          'order_date', order_created_at,
          'order_created_at', order_created_at,
          'marketplace', marketplace_group,
          'marketplace_account_id', marketplace_account_id,
          'local_sku', coalesce(nullif(local_sku, ''), '-'),
          'sku', coalesce(nullif(local_sku, ''), nullif(marketplace_sku_id, ''), nullif(marketplace_seller_sku, ''), '-'),
          'marketplace_sku_id', marketplace_sku_id,
          'marketplace_sku', marketplace_sku,
          'marketplace_seller_sku', marketplace_seller_sku,
          'product_name', product_name,
          'variant_name', variant_name,
          'marketplace_variation_name', variant_name,
          'qty', qty,
          'quantity', qty,
          'gross', line_gross,
          'gross_amount', line_gross,
          'gross_total', line_gross,
          'gross_per_item', case when qty > 0 then line_gross / qty else 0 end,
          'payout', case when has_payout and order_line_gross > 0 then order_payout * (line_gross / order_line_gross) else 0 end,
          'payout_amount', case when has_payout and order_line_gross > 0 then order_payout * (line_gross / order_line_gross) else 0 end,
          'payout_per_item', case when has_payout and order_line_gross > 0 and qty > 0 then (order_payout * (line_gross / order_line_gross)) / qty else 0 end,
          'hpp', unit_hpp * qty,
          'hpp_total', unit_hpp * qty,
          'hpp_per_item', unit_hpp,
          'unit_hpp', unit_hpp,
          'hpp_status', case when unit_hpp > 0 then 'HPP mapping' else 'HPP belum mapping' end,
          'target_margin_percent', target_margin,
          'finance_status', case when has_payout then 'SETTLED' else 'PENDING_PAYOUT' end,
          'payout_status', case when has_payout then 'SETTLED' else 'PENDING_PAYOUT' end
        ) order by order_created_at desc, order_key), '[]'::jsonb),
        'page', v_page,
        'page_size', v_page_size,
        'total', coalesce(max(total_count), 0),
        'total_count', coalesce(max(total_count), 0),
        'total_pages', greatest(1, ceil(coalesce(max(total_count), 0)::numeric / v_page_size)::integer),
        'source', 'finance_sku_order_details_fast_mtd'
      )
      from paged_enriched
    );
  end if;

  return (
    with order_base as (
      select *
      from (
        select
          o.marketplace_order_id,
          o.tenant_id,
          o.marketplace_account_id,
          o.order_created_at,
          timezone('Asia/Jakarta', o.order_created_at)::date as order_date,
          coalesce(nullif(o.order_id::text, ''), nullif(o.order_sn::text, ''), nullif(o.external_order_id::text, ''), o.marketplace_order_id::text) as order_key,
          lower(concat_ws(' ', o.order_status, o.status, o.payment_status, o.fulfillment_status, o.order_status_label)) as status_text,
          case
            when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
            when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
            else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
          end as marketplace_group
        from public.marketplace_orders o
        where o.order_created_at >= v_start_ts
          and o.order_created_at < v_end_ts
          and (v_role = 'service_role' or o.tenant_id = v_tenant_id)
          and (v_account_id is null or o.marketplace_account_id = v_account_id)
      ) o
      where (v_marketplace is null or o.marketplace_group = v_marketplace)
        and o.status_text not like '%cancel%'
        and o.status_text not like '%batal%'
        and o.status_text not like '%unpaid%'
        and o.status_text not like '%in_cancel%'
    ),
    finance_by_order as (
      select
        ob.marketplace_order_id,
        coalesce(sum(coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)), 0)::numeric as payout
      from order_base ob
      join public.marketplace_finance_reports fr
        on fr.tenant_id = ob.tenant_id
       and fr.marketplace_account_id = ob.marketplace_account_id
       and fr.order_id = ob.order_key
      group by ob.marketplace_order_id
    ),
    line_base as (
      select
        ob.*,
        oi.marketplace_order_item_id,
        coalesce(nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, '')) as marketplace_sku_id,
        coalesce(nullif(oi.marketplace_sku, ''), nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, '')) as marketplace_sku,
        coalesce(nullif(oi.marketplace_seller_sku, ''), nullif(oi.seller_sku, '')) as marketplace_seller_sku,
        coalesce(nullif(oi.local_sku, ''), nullif(oi.mapped_local_sku, '')) as local_sku,
        coalesce(nullif(oi.marketplace_product_name, ''), nullif(oi.product_name, ''), nullif(oi.local_product_name, '')) as product_name,
        coalesce(nullif(oi.marketplace_variant_name, ''), nullif(oi.variant_name, ''), nullif(oi.variation_name, '')) as variant_name,
        greatest(coalesce(nullif(oi.qty, 0), nullif(oi.quantity, 0), 1), 1)::numeric as qty,
        coalesce(
          nullif(oi.gross_amount, 0),
          nullif(oi.paid_amount, 0),
          nullif(oi.unit_gross_amount, 0) * greatest(coalesce(nullif(oi.qty, 0), nullif(oi.quantity, 0), 1), 1),
          0
        )::numeric as line_gross
      from order_base ob
      join public.marketplace_order_items oi
        on oi.tenant_id = ob.tenant_id
       and oi.marketplace_order_id = ob.marketplace_order_id
    ),
    line_calc as (
      select lb.*, sum(lb.line_gross) over (partition by lb.marketplace_order_id) as order_line_gross
      from line_base lb
    ),
    enriched_base as (
      select
        lc.*,
        coalesce(f.payout, 0)::numeric as order_payout,
        (f.marketplace_order_id is not null) as has_payout
      from line_calc lc
      left join finance_by_order f on f.marketplace_order_id = lc.marketplace_order_id
    ),
    filtered as (
      select *
      from enriched_base
      where (v_filter = 'all' or (v_filter = 'paid' and has_payout) or (v_filter = 'unpaid' and not has_payout))
    ),
    grouped as (
      select
        tenant_id,
        marketplace_account_id,
        marketplace_group,
        coalesce(nullif(marketplace_sku_id, ''), nullif(marketplace_seller_sku, ''), nullif(local_sku, ''), 'unmapped') as sku_key,
        min(nullif(marketplace_sku_id, '')) as marketplace_sku_id,
        min(nullif(marketplace_sku, '')) as marketplace_sku,
        min(nullif(marketplace_seller_sku, '')) as marketplace_seller_sku,
        min(nullif(local_sku, '')) as local_sku,
        min(nullif(product_name, '')) as product_name,
        min(nullif(variant_name, '')) as variant_name,
        sum(qty)::numeric as qty_total,
        sum(line_gross)::numeric as gross_total,
        sum(line_gross) filter (where has_payout)::numeric as settled_gross_total,
        sum(line_gross) filter (where not has_payout)::numeric as unpaid_gross_total,
        sum(case when has_payout and order_line_gross > 0 then order_payout * (line_gross / order_line_gross) else 0 end)::numeric as payout_total,
        sum(case when has_payout and order_line_gross > 0 and order_payout > 0 then order_payout * (line_gross / order_line_gross) else 0 end)::numeric as positive_payout_total,
        sum(case when has_payout and order_line_gross > 0 and order_payout < 0 then order_payout * (line_gross / order_line_gross) else 0 end)::numeric as negative_payout_total,
        sum(qty) filter (where has_payout)::numeric as settled_qty,
        sum(qty) filter (where not has_payout)::numeric as unpaid_qty,
        count(distinct order_key)::integer as order_count,
        count(distinct order_key) filter (where has_payout)::integer as settled_order_count,
        count(distinct order_key) filter (where not has_payout)::integer as unpaid_order_count
      from filtered
      group by tenant_id, marketplace_account_id, marketplace_group,
        coalesce(nullif(marketplace_sku_id, ''), nullif(marketplace_seller_sku, ''), nullif(local_sku, ''), 'unmapped')
    ),
    hpp_sku as (
      select tenant_id, marketplace_account_id, lower(nullif(marketplace_sku_id, '')) as marketplace_sku_id,
             max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
             max(coalesce(target_margin_percent, target_margin, 0))::numeric as target_margin
      from public.marketplace_variant_hpp_mappings
      where coalesce(is_active, true) is true and nullif(marketplace_sku_id, '') is not null
        and (v_role = 'service_role' or tenant_id = v_tenant_id)
      group by tenant_id, marketplace_account_id, lower(nullif(marketplace_sku_id, ''))
    ),
    hpp_seller as (
      select tenant_id, marketplace_account_id, lower(nullif(marketplace_seller_sku, '')) as marketplace_seller_sku,
             max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
             max(coalesce(target_margin_percent, target_margin, 0))::numeric as target_margin
      from public.marketplace_variant_hpp_mappings
      where coalesce(is_active, true) is true and nullif(marketplace_seller_sku, '') is not null
        and (v_role = 'service_role' or tenant_id = v_tenant_id)
      group by tenant_id, marketplace_account_id, lower(nullif(marketplace_seller_sku, ''))
    ),
    hpp_local as (
      select tenant_id, marketplace_account_id, lower(nullif(local_sku, '')) as local_sku,
             max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
             max(coalesce(target_margin_percent, target_margin, 0))::numeric as target_margin
      from public.marketplace_variant_hpp_mappings
      where coalesce(is_active, true) is true and nullif(local_sku, '') is not null
        and (v_role = 'service_role' or tenant_id = v_tenant_id)
      group by tenant_id, marketplace_account_id, lower(nullif(local_sku, ''))
    ),
    grouped_enriched as (
      select
        g.*,
        coalesce(hs.hpp, hsel.hpp, hl.hpp, 0)::numeric as hpp_per_item,
        coalesce(hs.target_margin, hsel.target_margin, hl.target_margin, 0)::numeric as target_margin_percent,
        (coalesce(hs.hpp, hsel.hpp, hl.hpp, 0) * g.qty_total)::numeric as hpp_total
      from grouped g
      left join hpp_sku hs on hs.tenant_id = g.tenant_id and hs.marketplace_account_id = g.marketplace_account_id and hs.marketplace_sku_id = lower(nullif(g.marketplace_sku_id, ''))
      left join hpp_seller hsel on hsel.tenant_id = g.tenant_id and hsel.marketplace_account_id = g.marketplace_account_id and hsel.marketplace_seller_sku = lower(nullif(g.marketplace_seller_sku, ''))
      left join hpp_local hl on hl.tenant_id = g.tenant_id and hl.marketplace_account_id = g.marketplace_account_id and hl.local_sku = lower(nullif(g.local_sku, ''))
    ),
    counted as (
      select grouped_enriched.*, count(*) over ()::integer as total_count
      from grouped_enriched
    ),
    paged as (
      select *
      from counted
      order by payout_total desc nulls last, gross_total desc nulls last, sku_key
      offset v_offset
      limit v_page_size
    ),
    aggregates as (
      select
        coalesce(sum(gross_total), 0)::numeric as gross_total,
        coalesce(sum(payout_total), 0)::numeric as payout_total,
        coalesce(sum(hpp_total), 0)::numeric as hpp_total,
        coalesce(sum(qty_total), 0)::numeric as qty_total,
        coalesce(sum(settled_qty), 0)::numeric as settled_qty,
        coalesce(sum(unpaid_qty), 0)::numeric as unpaid_qty
      from grouped_enriched
    )
    select jsonb_build_object(
      'rows', coalesce(jsonb_agg(jsonb_build_object(
        'source', 'finance_sku_order_details_fast_mtd_group',
        'sku_detail_source', 'v82o',
        'marketplace', marketplace_group,
        'marketplace_account_id', marketplace_account_id,
        'sku', coalesce(nullif(local_sku, ''), nullif(marketplace_sku_id, ''), nullif(marketplace_seller_sku, ''), sku_key),
        'local_sku', coalesce(nullif(local_sku, ''), '-'),
        'marketplace_sku_id', marketplace_sku_id,
        'marketplace_sku', marketplace_sku,
        'marketplace_seller_sku', marketplace_seller_sku,
        'product_name', product_name,
        'variant_name', variant_name,
        'marketplace_variation_name', variant_name,
        'qty', coalesce(qty_total, 0),
        'qty_total', coalesce(qty_total, 0),
        'quantity', coalesce(qty_total, 0),
        'paid_qty', coalesce(settled_qty, 0),
        'settled_qty', coalesce(settled_qty, 0),
        'qty_settled', coalesce(settled_qty, 0),
        'unpaid_qty', coalesce(unpaid_qty, 0),
        'qty_unpaid', coalesce(unpaid_qty, 0),
        'gross_total', coalesce(gross_total, 0),
        'gross_sales', coalesce(gross_total, 0),
        'gross_amount', coalesce(gross_total, 0),
        'paid_gross_total', coalesce(settled_gross_total, 0),
        'settled_gross_total', coalesce(settled_gross_total, 0),
        'unpaid_gross_total', coalesce(unpaid_gross_total, 0),
        'payout_total', coalesce(payout_total, 0),
        'payout_amount', coalesce(payout_total, 0),
        'received_amount', coalesce(payout_total, 0),
        'net_settlement', coalesce(payout_total, 0),
        'positive_payout_total', coalesce(positive_payout_total, 0),
        'negative_payout_total', coalesce(negative_payout_total, 0),
        'hpp_total', coalesce(hpp_total, 0),
        'total_hpp', coalesce(hpp_total, 0),
        'paid_hpp_total', coalesce(hpp_total, 0),
        'settled_hpp_total', coalesce(hpp_total, 0),
        'hpp_per_item', coalesce(hpp_per_item, 0),
        'unit_hpp', coalesce(hpp_per_item, 0),
        'hpp', coalesce(hpp_per_item, 0),
        'hpp_status', case when coalesce(hpp_per_item, 0) > 0 then 'HPP mapping' else 'HPP belum mapping' end,
        'target_margin_percent', coalesce(target_margin_percent, 0),
        'order_count', coalesce(order_count, 0),
        'paid_order_count', coalesce(settled_order_count, 0),
        'settled_order_count', coalesce(settled_order_count, 0),
        'unpaid_order_count', coalesce(unpaid_order_count, 0),
        'gross_per_item', case when coalesce(qty_total, 0) > 0 then coalesce(gross_total, 0) / qty_total else 0 end,
        'payout_per_item', case when coalesce(settled_qty, 0) > 0 then coalesce(payout_total, 0) / settled_qty else 0 end
      ) order by payout_total desc nulls last, gross_total desc nulls last, sku_key), '[]'::jsonb),
      'page', v_page,
      'page_size', v_page_size,
      'total', coalesce(max(total_count), 0),
      'total_count', coalesce(max(total_count), 0),
      'total_pages', greatest(1, ceil(coalesce(max(total_count), 0)::numeric / v_page_size)::integer),
      'aggregates', (select to_jsonb(a) from aggregates a),
      'source', 'finance_sku_order_details_fast_mtd'
    )
    from paged
  );
end;
$$;


-- Redefining finance_marketplace_profit_loss_detail to fix TikTok discount/voucher P&L mismatch
create or replace function public.finance_marketplace_profit_loss_detail(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null
)
returns jsonb
language sql
stable
security definer
set search_path = public
set statement_timeout = '180s'
as $$
with vars as (
  select
    coalesce(p_start, date_trunc('month', now())::date)::timestamptz as start_ts,
    (coalesce(p_end, now()::date)::date + 1)::timestamptz as end_ts,
    coalesce(public.marketplace_normalize_key(p_marketplace), p_marketplace) as marketplace_filter
),
tenant as (
  select
    case
      when nullif(current_setting('request.jwt.claims', true), '') is null then null::uuid
      else nullif((current_setting('request.jwt.claims', true)::jsonb ->> 'tenant_id'), '')::uuid
    end as tenant_id
),
orders_scoped as (
  select
    o.marketplace_order_id,
    o.tenant_id,
    o.marketplace_account_id,
    o.marketplace,
    o.order_sn,
    o.order_created_at,
    coalesce(o.total_amount, o.gross_amount, o.paid_amount, 0)::numeric as gross_amount,
    lower(coalesce(o.order_status, o.status, '')) as status_text,
    lower(coalesce(to_jsonb(o)->>'payment_method', to_jsonb(o)->>'payment_channel', to_jsonb(o)->>'payment_status', '')) as payment_text
  from public.marketplace_orders o
  cross join vars v
  cross join tenant t
  where (t.tenant_id is null or o.tenant_id = t.tenant_id)
    and o.marketplace in ('shopee', 'tiktok_shop')
    and (v.marketplace_filter is null or v.marketplace_filter = '' or v.marketplace_filter = 'all' or o.marketplace = v.marketplace_filter)
    and (p_account_id is null or o.marketplace_account_id = p_account_id)
    and o.order_created_at >= v.start_ts
    and o.order_created_at < v.end_ts
    and lower(coalesce(o.order_status, o.status, '')) !~ '(cancel|batal|dibatalkan|unpaid|belum bayar|belum dibayar)'
),
finance_by_order as (
  select
    fr.tenant_id,
    fr.marketplace,
    fr.marketplace_account_id,
    fr.order_id as order_sn,
    count(distinct fr.marketplace_finance_report_id)::integer as finance_rows,
    sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0)::numeric) as payout_amount,
    sum(abs(coalesce(fr.discount_amount, 0)::numeric)) as discount_amount,
    sum(abs(coalesce(fr.platform_fee, 0)::numeric)) as platform_fee,
    sum(abs(coalesce(fr.commission_fee, 0)::numeric)) as commission_fee,
    sum(abs(coalesce(fr.affiliate_fee, 0)::numeric)) as affiliate_fee,
    sum(abs(coalesce(fr.shipping_fee, 0)::numeric)) as shipping_fee,
    sum(abs(coalesce(fr.fee_amount, 0)::numeric)) as fee_amount,
    sum(abs(coalesce(fr.total_fees, 0)::numeric)) as total_fees,
    sum(abs(coalesce(fr.refund_amount, 0)::numeric)) as refund_amount,
    sum(abs(coalesce(fr.adjustment_amount, 0)::numeric)) as adjustment_abs,
    sum(coalesce(fr.adjustment_amount, 0)::numeric) as adjustment_signed
  from public.marketplace_finance_reports fr
  cross join vars v
  cross join tenant t
  where (t.tenant_id is null or fr.tenant_id = t.tenant_id)
    and fr.marketplace in ('shopee', 'tiktok_shop')
    and (v.marketplace_filter is null or v.marketplace_filter = '' or v.marketplace_filter = 'all' or fr.marketplace = v.marketplace_filter)
    and (p_account_id is null or fr.marketplace_account_id = p_account_id)
  group by fr.tenant_id, fr.marketplace, fr.marketplace_account_id, fr.order_id
),
joined as (
  select
    o.*,
    f.finance_rows,
    coalesce(f.payout_amount, 0) as payout_amount,
    coalesce(f.discount_amount, 0) as discount_amount,
    coalesce(f.platform_fee, 0) as platform_fee,
    coalesce(f.commission_fee, 0) as commission_fee,
    coalesce(f.affiliate_fee, 0) as affiliate_fee,
    coalesce(f.shipping_fee, 0) as shipping_fee,
    greatest(
      greatest(coalesce(f.total_fees, 0), coalesce(f.fee_amount, 0)) -
      (
        coalesce(f.platform_fee, 0)
        + coalesce(f.commission_fee, 0)
        + coalesce(f.affiliate_fee, 0)
        + coalesce(f.shipping_fee, 0)
      ),
      0
    ) as other_fee,
    coalesce(f.refund_amount, 0) as refund_amount,
    coalesce(f.adjustment_abs, 0) as adjustment_amount,
    coalesce(f.adjustment_signed, 0) as adjustment_signed,
    (
      o.gross_amount <= 0
      or o.payment_text ~ '(sample|gratis|free|zero|0 payment|no payment|tester|giveaway)'
      or (o.payment_text = '' and o.gross_amount = 0 and o.status_text ~ '(complete|completed|delivered|selesai|dikirim|done)')
    ) as is_sample_order
  from orders_scoped o
  left join finance_by_order f
    on f.tenant_id = o.tenant_id
   and f.marketplace = o.marketplace
   and f.marketplace_account_id = o.marketplace_account_id
   and f.order_sn = o.order_sn
),
grouped as (
  select
    j.marketplace,
    j.marketplace_account_id,
    coalesce(nullif(a.shop_name, ''), nullif(a.store_alias, ''), j.marketplace) as shop_name,
    count(distinct j.order_sn)::int as order_count,
    count(distinct j.order_sn) filter (where j.finance_rows is not null)::int as matched_finance_count,
    count(distinct j.order_sn) filter (where j.finance_rows is null)::int as unmatched_order_count,
    -- Fix: For TikTok Shop, the gross_amount column represents net paid, so we must add discount_amount to represent true gross omzet.
    coalesce(sum(case when j.marketplace = 'tiktok_shop' then j.gross_amount + j.discount_amount else j.gross_amount end), 0) as gross_sales,
    coalesce(sum(j.gross_amount) filter (where j.finance_rows is null), 0) as unmatched_order_gross,
    coalesce(sum(j.payout_amount), 0) as payout_total,
    coalesce(sum(j.discount_amount), 0) as discount_amount,
    coalesce(sum(j.platform_fee), 0) as platform_fee,
    coalesce(sum(j.commission_fee), 0) as commission_fee,
    coalesce(sum(j.affiliate_fee), 0) as affiliate_fee,
    coalesce(sum(j.shipping_fee), 0) as shipping_fee,
    coalesce(sum(j.other_fee), 0) as other_fee,
    coalesce(sum(j.refund_amount), 0) as refund_amount,
    coalesce(sum(j.adjustment_amount), 0) as adjustment_amount,
    count(distinct j.order_sn) filter (where j.is_sample_order)::int as sample_order_count,
    coalesce(sum(abs(j.payout_amount)) filter (where j.is_sample_order and j.payout_amount < 0), 0) as sample_negative_payout_total
  from joined j
  left join public.marketplace_accounts a
    on a.marketplace_account_id = j.marketplace_account_id
  group by j.marketplace, j.marketplace_account_id, coalesce(nullif(a.shop_name, ''), nullif(a.store_alias, ''), j.marketplace)
),
final_rows as (
  select
    *,
    greatest(gross_sales - payout_total, 0) as gross_payout_gap,
    greatest(
      gross_sales - payout_total -
      (
        discount_amount + platform_fee + commission_fee + affiliate_fee + shipping_fee + other_fee
        + refund_amount + adjustment_amount + sample_negative_payout_total
      ),
      0
    ) as unclassified_amount
  from grouped
)
select jsonb_build_object(
  'ok', true,
  'source', 'finance_marketplace_profit_loss_detail',
  'diagnostic_only', true,
  'description', 'Order-date gross vs payout reconciliation. Not final P&L expense.',
  'rows', coalesce(jsonb_agg(jsonb_build_object(
    'row_kind', 'order_date_reconciliation',
    'diagnostic_only', true,
    'marketplace', marketplace,
    'marketplace_account_id', marketplace_account_id,
    'shop_name', shop_name,
    'account_name', shop_name,
    'order_count', order_count,
    'finance_order_count', matched_finance_count,
    'matched_finance_count', matched_finance_count,
    'unmatched_order_count', unmatched_order_count,
    'unmatched_order_gross', unmatched_order_gross,
    'gross_sales', gross_sales,
    'gross_total', gross_sales,
    'omzet', gross_sales,
    'payout_total', payout_total,
    'payout_amount', payout_total,
    'received_amount', payout_total,
    'gross_payout_gap', gross_payout_gap,
    'gross_minus_payout', gross_payout_gap,
    'selisih_omzet_payout', gross_payout_gap,
    'settlement_unmatched_total', unmatched_order_gross,
    'settlement_belum_final', unmatched_order_gross,
    'discount_amount', discount_amount,
    'platform_fee', platform_fee,
    'commission_fee', commission_fee,
    'affiliate_fee', affiliate_fee,
    'shipping_fee', shipping_fee,
    'other_fee', other_fee,
    'refund_amount', refund_amount,
    'tax_amount', 0,
    'adjustment_amount', adjustment_amount,
    'sample_order_count', sample_order_count,
    'sample_negative_payout_total', sample_negative_payout_total,
    'unclassified_amount', unclassified_amount
  ) order by marketplace, shop_name), '[]'::jsonb)
)
from final_rows;
$$;
