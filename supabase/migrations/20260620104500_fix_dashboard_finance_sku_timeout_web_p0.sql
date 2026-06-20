-- P0 timeout fix:
-- - dashboard_marketplace_order_analytics_90d becomes bounded WIB MTD.
-- - finance_dashboard_snapshot uses the same dashboard-backed MTD source.
-- - finance_sku_order_details returns page-scoped SKU aggregates/details
--   without falling back to product/default HPP.

create or replace function public.dashboard_marketplace_order_analytics_90d(
  p_marketplace text default null,
  p_days integer default 90
)
returns jsonb
language sql
stable
security definer
set search_path = public
set statement_timeout = '8s'
as $$
with raw_claims as (
  select nullif(current_setting('request.jwt.claims', true), '') as raw
),
claims as (
  select coalesce(raw::jsonb, '{}'::jsonb) as value from raw_claims
),
tenant_scope as (
  select
    coalesce(
      case
        when (value->>'tenant_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        then (value->>'tenant_id')::uuid
        else null::uuid
      end,
      (select u.tenant_id from public.users u where u.user_id = auth.uid() limit 1)
    ) as tenant_id,
    coalesce(nullif(value->>'role', ''), '') as jwt_role
  from claims
),
params as (
  select
    date_trunc('month', timezone('Asia/Jakarta', now()))::date as start_date,
    timezone('Asia/Jakarta', now())::date as end_date,
    (date_trunc('month', timezone('Asia/Jakarta', now()))::date::timestamp at time zone 'Asia/Jakarta') as start_ts,
    ((timezone('Asia/Jakarta', now())::date + 1)::timestamp at time zone 'Asia/Jakarta') as end_ts,
    case
      when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
      when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
      else null
    end as marketplace_filter
),
calendar as (
  select generate_series(
    (select start_date from params),
    (select end_date from params),
    interval '1 day'
  )::date as day
),
order_base as materialized (
  select *
  from (
    select
      o.marketplace_order_id,
      o.tenant_id,
      o.marketplace_account_id,
      o.order_created_at,
      timezone('Asia/Jakarta', o.order_created_at)::date as order_date,
      coalesce(
        nullif(o.order_id::text, ''),
        nullif(o.order_sn::text, ''),
        nullif(o.external_order_id::text, ''),
        o.marketplace_order_id::text
      ) as order_key,
      coalesce(nullif(o.order_sn::text, ''), nullif(o.external_order_id::text, ''), nullif(o.order_id::text, '')) as order_sn,
      coalesce(nullif(o.tracking_number, ''), nullif(o.label_code, ''), nullif(o.package_id, '')) as tracking_number,
      coalesce(nullif(o.gross_amount, 0), nullif(o.total_amount, 0), nullif(o.paid_amount, 0), 0)::numeric as order_gross,
      lower(concat_ws(' ', o.order_status, o.status, o.payment_status, o.fulfillment_status, o.order_status_label)) as status_text,
      case
        when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
        else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end as marketplace_group
    from public.marketplace_orders o
    cross join tenant_scope t
    cross join params p
    where o.order_created_at >= p.start_ts
      and o.order_created_at < p.end_ts
      and (
        t.jwt_role = 'service_role'
        or (t.tenant_id is not null and o.tenant_id = t.tenant_id)
      )
  ) o
  cross join params p
  where (p.marketplace_filter is null or o.marketplace_group = p.marketplace_filter)
    and o.status_text not like '%cancel%'
    and o.status_text not like '%batal%'
    and o.status_text not like '%unpaid%'
    and o.status_text not like '%in_cancel%'
),
hpp_sku as materialized (
  select
    h.tenant_id,
    h.marketplace_account_id,
    case
      when lower(regexp_replace(coalesce(h.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
      when lower(regexp_replace(coalesce(h.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
      else lower(regexp_replace(coalesce(h.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
    end as marketplace_group,
    lower(nullif(h.marketplace_sku_id, '')) as marketplace_sku_id,
    max(coalesce(h.hpp, h.hpp_amount, h.hpp_per_item, 0))::numeric as hpp
  from public.marketplace_variant_hpp_mappings h
  where coalesce(h.is_active, true) is true
    and nullif(h.marketplace_sku_id, '') is not null
  group by h.tenant_id, h.marketplace_account_id, marketplace_group, lower(nullif(h.marketplace_sku_id, ''))
),
hpp_seller as materialized (
  select
    h.tenant_id,
    h.marketplace_account_id,
    case
      when lower(regexp_replace(coalesce(h.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
      when lower(regexp_replace(coalesce(h.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
      else lower(regexp_replace(coalesce(h.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
    end as marketplace_group,
    lower(nullif(h.marketplace_seller_sku, '')) as marketplace_seller_sku,
    max(coalesce(h.hpp, h.hpp_amount, h.hpp_per_item, 0))::numeric as hpp
  from public.marketplace_variant_hpp_mappings h
  where coalesce(h.is_active, true) is true
    and nullif(h.marketplace_seller_sku, '') is not null
  group by h.tenant_id, h.marketplace_account_id, marketplace_group, lower(nullif(h.marketplace_seller_sku, ''))
),
hpp_local as materialized (
  select
    h.tenant_id,
    h.marketplace_account_id,
    case
      when lower(regexp_replace(coalesce(h.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
      when lower(regexp_replace(coalesce(h.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
      else lower(regexp_replace(coalesce(h.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
    end as marketplace_group,
    lower(nullif(h.local_sku, '')) as local_sku,
    max(coalesce(h.hpp, h.hpp_amount, h.hpp_per_item, 0))::numeric as hpp
  from public.marketplace_variant_hpp_mappings h
  where coalesce(h.is_active, true) is true
    and nullif(h.local_sku, '') is not null
  group by h.tenant_id, h.marketplace_account_id, marketplace_group, lower(nullif(h.local_sku, ''))
),
item_rollup as materialized (
  select
    x.marketplace_order_id,
    coalesce(sum(x.line_gross), 0)::numeric as item_gross,
    coalesce(sum(x.line_hpp), 0)::numeric as item_hpp
  from (
    select
      ob.marketplace_order_id,
      coalesce(
        nullif(oi.gross_amount, 0),
        nullif(oi.paid_amount, 0),
        nullif(oi.unit_gross_amount, 0) * greatest(coalesce(nullif(oi.qty, 0), nullif(oi.quantity, 0), 1), 1),
        0
      )::numeric as line_gross,
      0::numeric as line_hpp
    from order_base ob
    join public.marketplace_order_items oi
      on oi.tenant_id = ob.tenant_id
     and oi.marketplace_order_id = ob.marketplace_order_id
    where coalesce(ob.order_gross, 0) = 0
  ) x
  group by x.marketplace_order_id
),
finance_by_order as materialized (
  select
    ob.marketplace_order_id,
    coalesce(sum(coalesce(fr.gross_amount, fr.gross_sales, 0)), 0)::numeric as gross,
    coalesce(sum(coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)), 0)::numeric as payout
  from order_base ob
  join public.marketplace_finance_reports fr
    on fr.tenant_id = ob.tenant_id
   and fr.marketplace_account_id = ob.marketplace_account_id
   and fr.order_id = ob.order_key
  group by ob.marketplace_order_id
),
order_finance as materialized (
  select
    ob.order_date,
    ob.marketplace_group,
    ob.marketplace_order_id,
    coalesce(nullif(f.gross, 0), nullif(ob.order_gross, 0), nullif(ir.item_gross, 0), 0)::numeric as gross,
    coalesce(f.payout, 0)::numeric as payout,
    coalesce(ir.item_hpp, 0)::numeric as hpp,
    (f.marketplace_order_id is not null) as has_finance
  from order_base ob
  left join item_rollup ir on ir.marketplace_order_id = ob.marketplace_order_id
  left join finance_by_order f on f.marketplace_order_id = ob.marketplace_order_id
),
daily as materialized (
  select
    c.day,
    coalesce(sum(ofn.gross), 0)::numeric as omzet_total,
    coalesce(sum(ofn.payout), 0)::numeric as payout_total,
    coalesce(sum(ofn.hpp), 0)::numeric as hpp_total,
    count(ofn.marketplace_order_id)::integer as orders_count,
    count(ofn.marketplace_order_id) filter (where ofn.has_finance)::integer as finance_orders_count,
    count(*) filter (where ofn.payout < 0)::integer as negative_payout_count,
    coalesce(sum(abs(ofn.payout)) filter (where ofn.payout < 0), 0)::numeric as negative_payout_total_abs
  from calendar c
  left join order_finance ofn on ofn.order_date = c.day
  group by c.day
),
summary as (
  select
    coalesce(sum(d.omzet_total), 0)::numeric as omzet_total,
    coalesce(sum(d.payout_total), 0)::numeric as payout_total,
    coalesce(sum(d.hpp_total), 0)::numeric as hpp_total,
    coalesce(sum(d.orders_count), 0)::integer as orders_count,
    coalesce(sum(d.finance_orders_count), 0)::integer as finance_orders_count,
    coalesce(sum(d.negative_payout_count), 0)::integer as negative_payout_count,
    coalesce(sum(d.negative_payout_total_abs), 0)::numeric as negative_payout_total_abs
  from daily d
),
by_marketplace as (
  select
    ofn.marketplace_group as marketplace,
    coalesce(sum(ofn.gross), 0)::numeric as omzet_total,
    coalesce(sum(ofn.payout), 0)::numeric as payout_total,
    coalesce(sum(ofn.hpp), 0)::numeric as hpp_total,
    count(ofn.marketplace_order_id)::integer as orders_count,
    count(ofn.marketplace_order_id) filter (where ofn.has_finance)::integer as finance_orders_count
  from order_finance ofn
  group by ofn.marketplace_group
)
select jsonb_build_object(
  'ok', true,
  'source', 'dashboard_marketplace_order_analytics_90d',
  'source_table', 'marketplace_orders+marketplace_order_items+marketplace_variant_hpp_mappings+marketplace_finance_reports',
  'timezone', 'Asia/Jakarta',
  'marketplace', coalesce((select marketplace_filter from params), 'all'),
  'days', ((select end_date from params) - (select start_date from params) + 1),
  'start_date', (select start_date from params),
  'end_date', (select end_date from params),
  'summary', jsonb_build_object(
    'omzet_total', (select omzet_total from summary),
    'gross_total', (select omzet_total from summary),
    'gross_sales', (select omzet_total from summary),
    'payout_total', (select payout_total from summary),
    'payout_amount', (select payout_total from summary),
    'hpp_total', (select hpp_total from summary),
    'total_hpp', (select hpp_total from summary),
    'net_profit', (select payout_total - hpp_total from summary),
    'orders_count', (select orders_count from summary),
    'order_count', (select orders_count from summary),
    'finance_orders_count', (select finance_orders_count from summary),
    'finance_order_count', (select finance_orders_count from summary),
    'abnormal_count', (select negative_payout_count from summary),
    'anomaly_count', (select negative_payout_count from summary),
    'negative_payout_total_abs', (select negative_payout_total_abs from summary),
    'payout_minus_total_abs', (select negative_payout_total_abs from summary)
  ),
  'daily', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'date', d.day,
      'order_date', d.day,
      'omzet_total', d.omzet_total,
      'gross_total', d.omzet_total,
      'gross_sales', d.omzet_total,
      'payout_total', d.payout_total,
      'hpp_total', d.hpp_total,
      'orders_count', d.orders_count,
      'order_count', d.orders_count,
      'finance_orders_count', d.finance_orders_count,
      'abnormal_count', d.negative_payout_count,
      'negative_payout_total_abs', d.negative_payout_total_abs
    ) order by d.day), '[]'::jsonb)
    from daily d
  ),
  'trend', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'date', d.day,
      'order_date', d.day,
      'omzet_total', d.omzet_total,
      'gross_total', d.omzet_total,
      'gross_sales', d.omzet_total,
      'payout_total', d.payout_total,
      'hpp_total', d.hpp_total,
      'orders_count', d.orders_count,
      'order_count', d.orders_count
    ) order by d.day), '[]'::jsonb)
    from daily d
  ),
  'by_marketplace', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'marketplace', marketplace,
      'omzet_total', omzet_total,
      'gross_total', omzet_total,
      'gross_sales', omzet_total,
      'payout_total', payout_total,
      'hpp_total', hpp_total,
      'orders_count', orders_count,
      'order_count', orders_count,
      'finance_orders_count', finance_orders_count
    ) order by marketplace), '[]'::jsonb)
    from by_marketplace
  )
);
$$;

create or replace function public.finance_dashboard_snapshot(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '8s'
as $$
declare
  v_current_start date := date_trunc('month', timezone('Asia/Jakarta', now()))::date;
  v_current_end date := timezone('Asia/Jakarta', now())::date;
  v_base jsonb;
begin
  v_base := public.dashboard_marketplace_order_analytics_90d(p_marketplace, 20);

  return jsonb_build_object(
    'ok', true,
    'version', 'finance_dashboard_snapshot_fast_mtd_20260620',
    'source', 'finance_dashboard_snapshot',
    'source_table', 'dashboard_marketplace_order_analytics_90d',
    'timezone', 'Asia/Jakarta',
    'start_date', coalesce(v_base->>'start_date', v_current_start::text),
    'end_date', coalesce(v_base->>'end_date', v_current_end::text),
    'requested_start_date', coalesce(p_start, v_current_start),
    'requested_end_date', coalesce(p_end, v_current_end),
    'requested_account_id', p_account_id,
    'marketplace', coalesce(v_base->>'marketplace', 'all'),
    'summary', coalesce(v_base->'summary', '{}'::jsonb),
    'daily', coalesce(v_base->'daily', '[]'::jsonb),
    'trend', coalesce(v_base->'trend', v_base->'daily', '[]'::jsonb),
    'by_marketplace', coalesce(v_base->'by_marketplace', '[]'::jsonb),
    'marketplaces', coalesce(v_base->'by_marketplace', '[]'::jsonb),
    'profit_loss_by_marketplace', coalesce(v_base->'by_marketplace', '[]'::jsonb),
    'abnormal_aggregates', jsonb_build_object(
      'abnormal_count', coalesce(v_base->'summary'->'abnormal_count', '0'::jsonb),
      'negative_payout_total_abs', coalesce(v_base->'summary'->'negative_payout_total_abs', '0'::jsonb)
    ),
    'accounts', '[]'::jsonb,
    'expenses', '[]'::jsonb,
    'approved_purchases', '[]'::jsonb,
    'skus', '[]'::jsonb,
    'sku_rows', '[]'::jsonb,
    'cash_flow', '[]'::jsonb,
    'profit_loss_breakdown', '[]'::jsonb,
    'abnormals', '[]'::jsonb
  );
end;
$$;

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
set statement_timeout = '8s'
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
      with order_base as materialized (
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
      finance_by_order as materialized (
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
      hpp_sku as materialized (
        select tenant_id, marketplace_account_id, lower(nullif(marketplace_sku_id, '')) as marketplace_sku_id,
               max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
               max(coalesce(target_margin_percent, target_margin, 0))::numeric as target_margin
        from public.marketplace_variant_hpp_mappings
        where coalesce(is_active, true) is true and nullif(marketplace_sku_id, '') is not null
        group by tenant_id, marketplace_account_id, lower(nullif(marketplace_sku_id, ''))
      ),
      hpp_seller as materialized (
        select tenant_id, marketplace_account_id, lower(nullif(marketplace_seller_sku, '')) as marketplace_seller_sku,
               max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
               max(coalesce(target_margin_percent, target_margin, 0))::numeric as target_margin
        from public.marketplace_variant_hpp_mappings
        where coalesce(is_active, true) is true and nullif(marketplace_seller_sku, '') is not null
        group by tenant_id, marketplace_account_id, lower(nullif(marketplace_seller_sku, ''))
      ),
      hpp_local as materialized (
        select tenant_id, marketplace_account_id, lower(nullif(local_sku, '')) as local_sku,
               max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
               max(coalesce(target_margin_percent, target_margin, 0))::numeric as target_margin
        from public.marketplace_variant_hpp_mappings
        where coalesce(is_active, true) is true and nullif(local_sku, '') is not null
        group by tenant_id, marketplace_account_id, lower(nullif(local_sku, ''))
      ),
      line_base as materialized (
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
      line_calc as materialized (
        select lb.*, sum(lb.line_gross) over (partition by lb.marketplace_order_id) as order_line_gross
        from line_base lb
      ),
      enriched as materialized (
        select
          lc.*,
          coalesce(f.payout, 0)::numeric as order_payout,
          (f.marketplace_order_id is not null) as has_payout,
          coalesce(hs.hpp, hsel.hpp, hl.hpp, 0)::numeric as unit_hpp,
          coalesce(hs.target_margin, hsel.target_margin, hl.target_margin, 0)::numeric as target_margin
        from line_calc lc
        left join finance_by_order f on f.marketplace_order_id = lc.marketplace_order_id
        left join hpp_sku hs on hs.tenant_id = lc.tenant_id and hs.marketplace_account_id = lc.marketplace_account_id and hs.marketplace_sku_id = lower(nullif(lc.marketplace_sku_id, ''))
        left join hpp_seller hsel on hsel.tenant_id = lc.tenant_id and hsel.marketplace_account_id = lc.marketplace_account_id and hsel.marketplace_seller_sku = lower(nullif(lc.marketplace_seller_sku, ''))
        left join hpp_local hl on hl.tenant_id = lc.tenant_id and hl.marketplace_account_id = lc.marketplace_account_id and hl.local_sku = lower(nullif(lc.local_sku, ''))
      ),
      filtered as materialized (
        select *
        from enriched
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
      from paged
    );
  end if;

  return (
    with order_base as materialized (
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
    finance_by_order as materialized (
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
    hpp_sku as materialized (
      select tenant_id, marketplace_account_id, lower(nullif(marketplace_sku_id, '')) as marketplace_sku_id,
             max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
             max(coalesce(target_margin_percent, target_margin, 0))::numeric as target_margin
      from public.marketplace_variant_hpp_mappings
      where coalesce(is_active, true) is true and nullif(marketplace_sku_id, '') is not null
      group by tenant_id, marketplace_account_id, lower(nullif(marketplace_sku_id, ''))
    ),
    hpp_seller as materialized (
      select tenant_id, marketplace_account_id, lower(nullif(marketplace_seller_sku, '')) as marketplace_seller_sku,
             max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
             max(coalesce(target_margin_percent, target_margin, 0))::numeric as target_margin
      from public.marketplace_variant_hpp_mappings
      where coalesce(is_active, true) is true and nullif(marketplace_seller_sku, '') is not null
      group by tenant_id, marketplace_account_id, lower(nullif(marketplace_seller_sku, ''))
    ),
    hpp_local as materialized (
      select tenant_id, marketplace_account_id, lower(nullif(local_sku, '')) as local_sku,
             max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
             max(coalesce(target_margin_percent, target_margin, 0))::numeric as target_margin
      from public.marketplace_variant_hpp_mappings
      where coalesce(is_active, true) is true and nullif(local_sku, '') is not null
      group by tenant_id, marketplace_account_id, lower(nullif(local_sku, ''))
    ),
    line_base as materialized (
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
    line_calc as materialized (
      select lb.*, sum(lb.line_gross) over (partition by lb.marketplace_order_id) as order_line_gross
      from line_base lb
    ),
    enriched as materialized (
      select
        lc.*,
        coalesce(f.payout, 0)::numeric as order_payout,
        (f.marketplace_order_id is not null) as has_payout,
        coalesce(hs.hpp, hsel.hpp, hl.hpp, 0)::numeric as unit_hpp,
        coalesce(hs.target_margin, hsel.target_margin, hl.target_margin, 0)::numeric as target_margin
      from line_calc lc
      left join finance_by_order f on f.marketplace_order_id = lc.marketplace_order_id
      left join hpp_sku hs on hs.tenant_id = lc.tenant_id and hs.marketplace_account_id = lc.marketplace_account_id and hs.marketplace_sku_id = lower(nullif(lc.marketplace_sku_id, ''))
      left join hpp_seller hsel on hsel.tenant_id = lc.tenant_id and hsel.marketplace_account_id = lc.marketplace_account_id and hsel.marketplace_seller_sku = lower(nullif(lc.marketplace_seller_sku, ''))
      left join hpp_local hl on hl.tenant_id = lc.tenant_id and hl.marketplace_account_id = lc.marketplace_account_id and hl.local_sku = lower(nullif(lc.local_sku, ''))
    ),
    filtered as materialized (
      select *
      from enriched
      where (v_filter = 'all' or (v_filter = 'paid' and has_payout) or (v_filter = 'unpaid' and not has_payout))
    ),
    grouped as materialized (
      select
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
        count(distinct order_key) filter (where not has_payout)::integer as unpaid_order_count,
        sum(unit_hpp * qty)::numeric as hpp_total,
        max(unit_hpp)::numeric as hpp_per_item,
        max(target_margin)::numeric as target_margin_percent
      from filtered
      group by marketplace_account_id, marketplace_group,
        coalesce(nullif(marketplace_sku_id, ''), nullif(marketplace_seller_sku, ''), nullif(local_sku, ''), 'unmapped')
    ),
    counted as (
      select grouped.*, count(*) over ()::integer as total_count
      from grouped
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
      from grouped
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

create or replace function public.dashboard_marketplace_order_analytics_90d(
  p_marketplace text default null,
  p_days integer default 90
)
returns jsonb
language sql
stable
security definer
set search_path = public
set statement_timeout = '8s'
as $$
with raw_claims as (
  select nullif(current_setting('request.jwt.claims', true), '') as raw
),
claims as (
  select coalesce(raw::jsonb, '{}'::jsonb) as value from raw_claims
),
tenant_scope as (
  select
    coalesce(
      case
        when (value->>'tenant_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        then (value->>'tenant_id')::uuid
        else null::uuid
      end,
      (select u.tenant_id from public.users u where u.user_id = auth.uid() limit 1)
    ) as tenant_id,
    coalesce(nullif(value->>'role', ''), '') as jwt_role
  from claims
),
params as (
  select
    date_trunc('month', timezone('Asia/Jakarta', now()))::date as start_date,
    timezone('Asia/Jakarta', now())::date as end_date,
    (date_trunc('month', timezone('Asia/Jakarta', now()))::date::timestamp at time zone 'Asia/Jakarta') as start_ts,
    ((timezone('Asia/Jakarta', now())::date + 1)::timestamp at time zone 'Asia/Jakarta') as end_ts,
    case
      when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
      when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
      else null
    end as marketplace_filter
),
calendar as (
  select generate_series(
    (select start_date from params),
    (select end_date from params),
    interval '1 day'
  )::date as day
),
order_base as materialized (
  select *
  from (
    select
      o.marketplace_order_id,
      o.tenant_id,
      o.marketplace_account_id,
      timezone('Asia/Jakarta', o.order_created_at)::date as order_date,
      coalesce(nullif(o.order_id::text, ''), nullif(o.order_sn::text, ''), nullif(o.external_order_id::text, ''), o.marketplace_order_id::text) as order_key,
      coalesce(nullif(o.gross_amount, 0), nullif(o.total_amount, 0), nullif(o.paid_amount, 0), 0)::numeric as order_gross,
      lower(concat_ws(' ', o.order_status, o.status, o.payment_status, o.fulfillment_status, o.order_status_label)) as status_text,
      case
        when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
        else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end as marketplace_group
    from public.marketplace_orders o
    cross join tenant_scope t
    cross join params p
    where o.order_created_at >= p.start_ts
      and o.order_created_at < p.end_ts
      and (
        t.jwt_role = 'service_role'
        or (t.tenant_id is not null and o.tenant_id = t.tenant_id)
      )
  ) o
  cross join params p
  where (p.marketplace_filter is null or o.marketplace_group = p.marketplace_filter)
    and o.status_text not like '%cancel%'
    and o.status_text not like '%batal%'
    and o.status_text not like '%unpaid%'
    and o.status_text not like '%in_cancel%'
),
zero_item_gross as materialized (
  select
    ob.marketplace_order_id,
    coalesce(sum(coalesce(
      nullif(oi.gross_amount, 0),
      nullif(oi.paid_amount, 0),
      nullif(oi.unit_gross_amount, 0) * greatest(coalesce(nullif(oi.qty, 0), nullif(oi.quantity, 0), 1), 1),
      0
    )), 0)::numeric as item_gross
  from order_base ob
  join public.marketplace_order_items oi
    on oi.tenant_id = ob.tenant_id
   and oi.marketplace_order_id = ob.marketplace_order_id
  where coalesce(ob.order_gross, 0) = 0
  group by ob.marketplace_order_id
),
order_amounts as materialized (
  select
    ob.order_date,
    ob.marketplace_group,
    ob.marketplace_order_id,
    ob.order_key,
    coalesce(nullif(ob.order_gross, 0), nullif(zig.item_gross, 0), 0)::numeric as gross
  from order_base ob
  left join zero_item_gross zig on zig.marketplace_order_id = ob.marketplace_order_id
),
finance_rows as materialized (
  select
    fr.period_start::date as finance_date,
    coalesce(nullif(fr.order_id::text, ''), nullif(fr.marketplace_order_id::text, ''), fr.finance_report_id::text) as order_key,
    case
      when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
      when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
      else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
    end as marketplace_group,
    coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)::numeric as payout
  from public.marketplace_finance_reports fr
  cross join tenant_scope t
  cross join params p
  where fr.period_start >= p.start_date
    and fr.period_start <= p.end_date
    and (
      t.jwt_role = 'service_role'
      or (t.tenant_id is not null and fr.tenant_id = t.tenant_id)
    )
),
finance_filtered as materialized (
  select f.*
  from finance_rows f
  cross join params p
  where (p.marketplace_filter is null or f.marketplace_group = p.marketplace_filter)
),
order_daily as materialized (
  select
    order_date as day,
    marketplace_group,
    coalesce(sum(gross), 0)::numeric as omzet_total,
    count(distinct order_key)::integer as orders_count
  from order_amounts
  group by order_date, marketplace_group
),
finance_daily as materialized (
  select
    finance_date as day,
    marketplace_group,
    coalesce(sum(payout), 0)::numeric as payout_total,
    count(distinct order_key)::integer as finance_orders_count,
    count(*) filter (where payout < 0)::integer as negative_payout_count,
    coalesce(sum(abs(payout)) filter (where payout < 0), 0)::numeric as negative_payout_total_abs
  from finance_filtered
  where order_key is not null and order_key <> ''
  group by finance_date, marketplace_group
),
daily_marketplace_keys as (
  select day, marketplace_group from order_daily
  union
  select day, marketplace_group from finance_daily
),
daily as materialized (
  select
    c.day,
    coalesce(sum(od.omzet_total), 0)::numeric as omzet_total,
    coalesce(sum(fd.payout_total), 0)::numeric as payout_total,
    0::numeric as hpp_total,
    coalesce(sum(od.orders_count), 0)::integer as orders_count,
    coalesce(sum(fd.finance_orders_count), 0)::integer as finance_orders_count,
    coalesce(sum(fd.negative_payout_count), 0)::integer as negative_payout_count,
    coalesce(sum(fd.negative_payout_total_abs), 0)::numeric as negative_payout_total_abs
  from calendar c
  left join daily_marketplace_keys dk on dk.day = c.day
  left join order_daily od
    on od.day = dk.day
   and od.marketplace_group = dk.marketplace_group
  left join finance_daily fd
    on fd.day = dk.day
   and fd.marketplace_group = dk.marketplace_group
  group by c.day
),
summary as (
  select
    coalesce(sum(d.omzet_total), 0)::numeric as omzet_total,
    coalesce(sum(d.payout_total), 0)::numeric as payout_total,
    0::numeric as hpp_total,
    coalesce(sum(d.orders_count), 0)::integer as orders_count,
    coalesce(sum(d.finance_orders_count), 0)::integer as finance_orders_count,
    coalesce(sum(d.negative_payout_count), 0)::integer as negative_payout_count,
    coalesce(sum(d.negative_payout_total_abs), 0)::numeric as negative_payout_total_abs
  from daily d
),
marketplace_keys as (
  select marketplace_group as marketplace from order_daily
  union
  select marketplace_group as marketplace from finance_daily
),
by_marketplace as (
  select
    mk.marketplace,
    coalesce((select sum(omzet_total) from order_daily od where od.marketplace_group = mk.marketplace), 0)::numeric as omzet_total,
    coalesce((select sum(payout_total) from finance_daily fd where fd.marketplace_group = mk.marketplace), 0)::numeric as payout_total,
    0::numeric as hpp_total,
    coalesce((select sum(orders_count) from order_daily od where od.marketplace_group = mk.marketplace), 0)::integer as orders_count,
    coalesce((select sum(finance_orders_count) from finance_daily fd where fd.marketplace_group = mk.marketplace), 0)::integer as finance_orders_count
  from marketplace_keys mk
)
select jsonb_build_object(
  'ok', true,
  'source', 'dashboard_marketplace_order_analytics_90d',
  'source_table', 'marketplace_orders+marketplace_order_items_zero_gross+marketplace_finance_reports_aggregate',
  'timezone', 'Asia/Jakarta',
  'marketplace', coalesce((select marketplace_filter from params), 'all'),
  'days', ((select end_date from params) - (select start_date from params) + 1),
  'start_date', (select start_date from params),
  'end_date', (select end_date from params),
  'summary', jsonb_build_object(
    'omzet_total', (select omzet_total from summary),
    'gross_total', (select omzet_total from summary),
    'gross_sales', (select omzet_total from summary),
    'payout_total', (select payout_total from summary),
    'payout_amount', (select payout_total from summary),
    'hpp_total', (select hpp_total from summary),
    'total_hpp', (select hpp_total from summary),
    'net_profit', (select payout_total - hpp_total from summary),
    'orders_count', (select orders_count from summary),
    'order_count', (select orders_count from summary),
    'finance_orders_count', (select finance_orders_count from summary),
    'finance_order_count', (select finance_orders_count from summary),
    'abnormal_count', (select negative_payout_count from summary),
    'anomaly_count', (select negative_payout_count from summary),
    'negative_payout_total_abs', (select negative_payout_total_abs from summary),
    'payout_minus_total_abs', (select negative_payout_total_abs from summary)
  ),
  'daily', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'date', d.day,
      'order_date', d.day,
      'omzet_total', d.omzet_total,
      'gross_total', d.omzet_total,
      'gross_sales', d.omzet_total,
      'payout_total', d.payout_total,
      'hpp_total', d.hpp_total,
      'orders_count', d.orders_count,
      'order_count', d.orders_count,
      'finance_orders_count', d.finance_orders_count,
      'abnormal_count', d.negative_payout_count,
      'negative_payout_total_abs', d.negative_payout_total_abs
    ) order by d.day), '[]'::jsonb)
    from daily d
  ),
  'trend', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'date', d.day,
      'order_date', d.day,
      'omzet_total', d.omzet_total,
      'gross_total', d.omzet_total,
      'gross_sales', d.omzet_total,
      'payout_total', d.payout_total,
      'hpp_total', d.hpp_total,
      'orders_count', d.orders_count,
      'order_count', d.orders_count
    ) order by d.day), '[]'::jsonb)
    from daily d
  ),
  'by_marketplace', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'marketplace', marketplace,
      'omzet_total', omzet_total,
      'gross_total', omzet_total,
      'gross_sales', omzet_total,
      'payout_total', payout_total,
      'hpp_total', hpp_total,
      'orders_count', orders_count,
      'order_count', orders_count,
      'finance_orders_count', finance_orders_count
    ) order by marketplace), '[]'::jsonb)
    from by_marketplace
  )
);
$$;

create or replace function public.dashboard_marketplace_order_analytics_90d(
  p_marketplace text default null,
  p_days integer default 90
)
returns jsonb
language sql
stable
security definer
set search_path = public
set statement_timeout = '8s'
as $$
with raw_claims as (
  select nullif(current_setting('request.jwt.claims', true), '') as raw
),
claims as (
  select coalesce(raw::jsonb, '{}'::jsonb) as value from raw_claims
),
tenant_scope as (
  select
    coalesce(
      case
        when (value->>'tenant_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        then (value->>'tenant_id')::uuid
        else null::uuid
      end,
      (select u.tenant_id from public.users u where u.user_id = auth.uid() limit 1)
    ) as tenant_id,
    coalesce(nullif(value->>'role', ''), '') as jwt_role
  from claims
),
params as (
  select
    date_trunc('month', timezone('Asia/Jakarta', now()))::date as start_date,
    timezone('Asia/Jakarta', now())::date as end_date,
    (date_trunc('month', timezone('Asia/Jakarta', now()))::date::timestamp at time zone 'Asia/Jakarta') as start_ts,
    ((timezone('Asia/Jakarta', now())::date + 1)::timestamp at time zone 'Asia/Jakarta') as end_ts,
    case
      when lower(coalesce(p_marketplace, '')) like '%shopee%' then 'shopee'
      when lower(coalesce(p_marketplace, '')) like '%tiktok%' then 'tiktok'
      else null
    end as marketplace_filter
),
calendar as (
  select generate_series((select start_date from params), (select end_date from params), interval '1 day')::date as day
),
order_base as materialized (
  select
    o.marketplace_order_id,
    o.tenant_id,
    o.marketplace_account_id,
    timezone('Asia/Jakarta', o.order_created_at)::date as order_date,
    coalesce(nullif(o.order_id::text, ''), nullif(o.order_sn::text, ''), nullif(o.external_order_id::text, ''), o.marketplace_order_id::text) as order_key,
    coalesce(nullif(o.gross_amount, 0), nullif(o.total_amount, 0), nullif(o.paid_amount, 0), 0)::numeric as order_gross,
    case
      when lower(coalesce(o.marketplace, '')) = 'shopee' then 'shopee'
      when lower(coalesce(o.marketplace, '')) in ('tiktok', 'tiktok_shop') then 'tiktok'
      else lower(coalesce(o.marketplace, 'unknown'))
    end as marketplace_group
  from public.marketplace_orders o
  cross join tenant_scope t
  cross join params p
  where o.order_created_at >= p.start_ts
    and o.order_created_at < p.end_ts
    and (t.jwt_role = 'service_role' or (t.tenant_id is not null and o.tenant_id = t.tenant_id))
    and (
      (p.marketplace_filter is null and o.marketplace in ('shopee', 'tiktok', 'tiktok_shop'))
      or (p.marketplace_filter = 'shopee' and o.marketplace = 'shopee')
      or (p.marketplace_filter = 'tiktok' and o.marketplace in ('tiktok', 'tiktok_shop'))
    )
    and lower(concat_ws(' ', o.order_status, o.status, o.payment_status, o.fulfillment_status, o.order_status_label)) not like '%cancel%'
    and lower(concat_ws(' ', o.order_status, o.status, o.payment_status, o.fulfillment_status, o.order_status_label)) not like '%batal%'
    and lower(concat_ws(' ', o.order_status, o.status, o.payment_status, o.fulfillment_status, o.order_status_label)) not like '%unpaid%'
    and lower(concat_ws(' ', o.order_status, o.status, o.payment_status, o.fulfillment_status, o.order_status_label)) not like '%in_cancel%'
),
zero_item_gross as materialized (
  select
    ob.marketplace_order_id,
    coalesce(sum(coalesce(
      nullif(oi.gross_amount, 0),
      nullif(oi.paid_amount, 0),
      nullif(oi.unit_gross_amount, 0) * greatest(coalesce(nullif(oi.qty, 0), nullif(oi.quantity, 0), 1), 1),
      0
    )), 0)::numeric as item_gross
  from order_base ob
  join public.marketplace_order_items oi
    on oi.tenant_id = ob.tenant_id
   and oi.marketplace_order_id = ob.marketplace_order_id
  where coalesce(ob.order_gross, 0) = 0
  group by ob.marketplace_order_id
),
finance_by_order as materialized (
  select
    ob.marketplace_order_id,
    coalesce(sum(coalesce(fr.gross_amount, fr.gross_sales, 0)), 0)::numeric as finance_gross,
    coalesce(sum(coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)), 0)::numeric as payout
  from order_base ob
  join public.marketplace_finance_reports fr
    on fr.tenant_id = ob.tenant_id
   and fr.marketplace_account_id = ob.marketplace_account_id
   and fr.order_id = ob.order_key
  group by ob.marketplace_order_id
),
order_finance as materialized (
  select
    ob.order_date,
    ob.marketplace_group,
    ob.marketplace_order_id,
    coalesce(nullif(f.finance_gross, 0), nullif(ob.order_gross, 0), nullif(zig.item_gross, 0), 0)::numeric as gross,
    coalesce(f.payout, 0)::numeric as payout,
    0::numeric as hpp,
    (f.marketplace_order_id is not null) as has_finance
  from order_base ob
  left join zero_item_gross zig on zig.marketplace_order_id = ob.marketplace_order_id
  left join finance_by_order f on f.marketplace_order_id = ob.marketplace_order_id
),
daily as materialized (
  select
    c.day,
    coalesce(sum(ofn.gross), 0)::numeric as omzet_total,
    coalesce(sum(ofn.payout), 0)::numeric as payout_total,
    0::numeric as hpp_total,
    count(ofn.marketplace_order_id)::integer as orders_count,
    count(ofn.marketplace_order_id) filter (where ofn.has_finance)::integer as finance_orders_count,
    count(*) filter (where ofn.payout < 0)::integer as negative_payout_count,
    coalesce(sum(abs(ofn.payout)) filter (where ofn.payout < 0), 0)::numeric as negative_payout_total_abs
  from calendar c
  left join order_finance ofn on ofn.order_date = c.day
  group by c.day
),
summary as (
  select
    coalesce(sum(d.omzet_total), 0)::numeric as omzet_total,
    coalesce(sum(d.payout_total), 0)::numeric as payout_total,
    0::numeric as hpp_total,
    coalesce(sum(d.orders_count), 0)::integer as orders_count,
    coalesce(sum(d.finance_orders_count), 0)::integer as finance_orders_count,
    coalesce(sum(d.negative_payout_count), 0)::integer as negative_payout_count,
    coalesce(sum(d.negative_payout_total_abs), 0)::numeric as negative_payout_total_abs
  from daily d
),
by_marketplace as (
  select
    ofn.marketplace_group as marketplace,
    coalesce(sum(ofn.gross), 0)::numeric as omzet_total,
    coalesce(sum(ofn.payout), 0)::numeric as payout_total,
    0::numeric as hpp_total,
    count(ofn.marketplace_order_id)::integer as orders_count,
    count(ofn.marketplace_order_id) filter (where ofn.has_finance)::integer as finance_orders_count
  from order_finance ofn
  group by ofn.marketplace_group
)
select jsonb_build_object(
  'ok', true,
  'source', 'dashboard_marketplace_order_analytics_90d',
  'source_table', 'marketplace_orders+marketplace_order_items_zero_gross+marketplace_finance_reports_joined',
  'timezone', 'Asia/Jakarta',
  'marketplace', coalesce((select marketplace_filter from params), 'all'),
  'days', ((select end_date from params) - (select start_date from params) + 1),
  'start_date', (select start_date from params),
  'end_date', (select end_date from params),
  'summary', jsonb_build_object(
    'omzet_total', (select omzet_total from summary),
    'gross_total', (select omzet_total from summary),
    'gross_sales', (select omzet_total from summary),
    'payout_total', (select payout_total from summary),
    'payout_amount', (select payout_total from summary),
    'hpp_total', (select hpp_total from summary),
    'total_hpp', (select hpp_total from summary),
    'net_profit', (select payout_total - hpp_total from summary),
    'orders_count', (select orders_count from summary),
    'order_count', (select orders_count from summary),
    'finance_orders_count', (select finance_orders_count from summary),
    'finance_order_count', (select finance_orders_count from summary),
    'abnormal_count', (select negative_payout_count from summary),
    'anomaly_count', (select negative_payout_count from summary),
    'negative_payout_total_abs', (select negative_payout_total_abs from summary),
    'payout_minus_total_abs', (select negative_payout_total_abs from summary)
  ),
  'daily', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'date', d.day,
      'order_date', d.day,
      'omzet_total', d.omzet_total,
      'gross_total', d.omzet_total,
      'gross_sales', d.omzet_total,
      'payout_total', d.payout_total,
      'hpp_total', d.hpp_total,
      'orders_count', d.orders_count,
      'order_count', d.orders_count,
      'finance_orders_count', d.finance_orders_count,
      'abnormal_count', d.negative_payout_count,
      'negative_payout_total_abs', d.negative_payout_total_abs
    ) order by d.day), '[]'::jsonb)
    from daily d
  ),
  'trend', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'date', d.day,
      'order_date', d.day,
      'omzet_total', d.omzet_total,
      'gross_total', d.omzet_total,
      'gross_sales', d.omzet_total,
      'payout_total', d.payout_total,
      'hpp_total', d.hpp_total,
      'orders_count', d.orders_count,
      'order_count', d.orders_count
    ) order by d.day), '[]'::jsonb)
    from daily d
  ),
  'by_marketplace', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'marketplace', marketplace,
      'omzet_total', omzet_total,
      'gross_total', omzet_total,
      'gross_sales', omzet_total,
      'payout_total', payout_total,
      'hpp_total', hpp_total,
      'orders_count', orders_count,
      'order_count', orders_count,
      'finance_orders_count', finance_orders_count
    ) order by marketplace), '[]'::jsonb)
    from by_marketplace
  )
);
$$;

grant execute on function public.dashboard_marketplace_order_analytics_90d(text, integer)
  to authenticated, service_role;
grant execute on function public.finance_dashboard_snapshot(date, date, text, uuid)
  to authenticated, service_role;
grant execute on function public.finance_sku_order_details(date, date, text, uuid, text, text, text, text, integer, integer)
  to authenticated, service_role;

notify pgrst, 'reload schema';
