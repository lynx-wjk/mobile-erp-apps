-- Canonical RPC overwrite only. Dashboard analytics must be true MTD in WIB
-- and must not group TikTok imports by bulk finance period_start.

create or replace function public.dashboard_marketplace_order_analytics_90d(
  p_marketplace text default null,
  p_days integer default 90
)
returns jsonb
language sql
stable
security definer
set search_path = public
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
order_rows as materialized (
  select
    o.marketplace_order_id,
    o.tenant_id,
    o.marketplace_account_id,
    timezone(
      'Asia/Jakarta',
      coalesce(o.order_created_at, o.created_time, o.created_at)
    )::date as order_date,
    coalesce(
      nullif(o.order_id::text, ''),
      nullif(o.order_sn::text, ''),
      o.marketplace_order_id::text
    ) as order_key,
    case
      when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
      when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
      else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
    end as marketplace_group
  from public.marketplace_orders o
  cross join tenant_scope t
  where (
      t.jwt_role = 'service_role'
      or (t.tenant_id is not null and o.tenant_id = t.tenant_id)
    )
),
order_base as materialized (
  select o.*
  from order_rows o
  cross join params p
  where o.order_date >= p.start_date
    and o.order_date <= p.end_date
    and (p.marketplace_filter is null or o.marketplace_group = p.marketplace_filter)
),
finance_by_order as materialized (
  select
    ob.marketplace_order_id,
    coalesce(sum(coalesce(fr.gross_amount, fr.gross_sales, 0)), 0)::numeric as gross,
    coalesce(sum(coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)), 0)::numeric as payout,
    coalesce(sum(coalesce(fr.total_hpp, 0)), 0)::numeric as hpp
  from order_base ob
  join public.marketplace_finance_reports fr
    on fr.tenant_id = ob.tenant_id
   and fr.marketplace_account_id = ob.marketplace_account_id
   and coalesce(
        nullif(fr.order_id::text, ''),
        nullif(fr.marketplace_order_id::text, '')
      ) = ob.order_key
   and case
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
        else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end = ob.marketplace_group
  group by ob.marketplace_order_id
),
order_finance as materialized (
  select
    ob.order_date,
    ob.marketplace_group,
    ob.marketplace_order_id,
    coalesce(f.gross, 0)::numeric as gross,
    coalesce(f.payout, 0)::numeric as payout,
    coalesce(f.hpp, 0)::numeric as hpp,
    (f.marketplace_order_id is not null) as has_finance
  from order_base ob
  left join finance_by_order f
    on f.marketplace_order_id = ob.marketplace_order_id
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
  left join order_finance ofn
    on ofn.order_date = c.day
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
  'source_table', 'marketplace_orders+marketplace_finance_reports',
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
    'abnormal_count', (select negative_payout_count from summary),
    'anomaly_count', (select negative_payout_count from summary),
    'negative_payout_total_abs', (select negative_payout_total_abs from summary),
    'payout_minus_total_abs', (select negative_payout_total_abs from summary)
  ),
  'daily', (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'date', d.day,
        'order_date', d.day,
        'omzet_total', d.omzet_total,
        'gross_total', d.omzet_total,
        'payout_total', d.payout_total,
        'hpp_total', d.hpp_total,
        'orders_count', d.orders_count,
        'order_count', d.orders_count,
        'finance_orders_count', d.finance_orders_count,
        'abnormal_count', d.negative_payout_count,
        'negative_payout_total_abs', d.negative_payout_total_abs
      )
      order by d.day
    ), '[]'::jsonb)
    from daily d
  ),
  'by_marketplace', (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'marketplace', marketplace,
        'omzet_total', omzet_total,
        'gross_total', omzet_total,
        'payout_total', payout_total,
        'hpp_total', hpp_total,
        'orders_count', orders_count,
        'order_count', orders_count,
        'finance_orders_count', finance_orders_count
      )
      order by marketplace
    ), '[]'::jsonb)
    from by_marketplace
  )
);
$$;

grant execute on function public.dashboard_marketplace_order_analytics_90d(text, integer) to authenticated, service_role;
