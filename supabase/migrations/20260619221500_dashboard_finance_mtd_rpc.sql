-- Overwrite existing dashboard analytics RPC without adding a versioned wrapper.
-- Dashboard finance must use bounded server-side MTD aggregates from marketplace_finance_reports,
-- not client-side row reads capped at 10k.

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
with params as (
  select
    greatest(1, least(coalesce(p_days, 90), 90))::integer as days_count,
    current_date as end_date,
    (current_date - (greatest(1, least(coalesce(p_days, 90), 90))::integer - 1))::date as start_date,
    case
      when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
      when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
      else null
    end as marketplace_filter
),
tenant as (
  select
    nullif(current_setting('request.jwt.claims', true), '')::jsonb as claims
),
tenant_scope as (
  select
    nullif(claims->>'tenant_id', '')::uuid as tenant_id,
    coalesce(nullif(claims->>'role', ''), '') as jwt_role
  from tenant
),
calendar as (
  select generate_series(
    (select start_date from params),
    (select end_date from params),
    interval '1 day'
  )::date as day
),
finance_rows as (
  select
    fr.period_start::date as report_date,
    coalesce(
      nullif(fr.order_id::text, ''),
      nullif(fr.marketplace_order_id::text, ''),
      fr.finance_report_id::text
    ) as order_key,
    case
      when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
      when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
      else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
    end as marketplace_group,
    coalesce(fr.gross_amount, fr.gross_sales, 0)::numeric as gross,
    coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)::numeric as payout,
    coalesce(fr.total_hpp, 0)::numeric as hpp
  from public.marketplace_finance_reports fr
  cross join params p
  cross join tenant_scope t
  where fr.period_start >= p.start_date
    and fr.period_start < (p.end_date + 1)
    and (
      t.jwt_role = 'service_role'
      or (t.tenant_id is not null and fr.tenant_id = t.tenant_id)
    )
),
filtered_finance as (
  select f.*
  from finance_rows f
  cross join params p
  where (p.marketplace_filter is null or f.marketplace_group = p.marketplace_filter)
    and f.order_key is not null
    and f.order_key <> ''
),
daily as (
  select
    c.day,
    coalesce(sum(f.gross), 0)::numeric as omzet_total,
    coalesce(sum(f.payout), 0)::numeric as payout_total,
    coalesce(sum(f.hpp), 0)::numeric as hpp_total,
    count(distinct f.order_key)::integer as orders_count,
    count(*) filter (where f.payout < 0)::integer as negative_payout_count,
    coalesce(sum(abs(f.payout)) filter (where f.payout < 0), 0)::numeric as negative_payout_total_abs
  from calendar c
  left join filtered_finance f
    on f.report_date = c.day
  group by c.day
),
summary as (
  select
    coalesce(sum(d.omzet_total), 0)::numeric as omzet_total,
    coalesce(sum(d.payout_total), 0)::numeric as payout_total,
    coalesce(sum(d.hpp_total), 0)::numeric as hpp_total,
    coalesce(sum(d.orders_count), 0)::integer as orders_count,
    coalesce(sum(d.negative_payout_count), 0)::integer as negative_payout_count,
    coalesce(sum(d.negative_payout_total_abs), 0)::numeric as negative_payout_total_abs
  from daily d
),
by_marketplace as (
  select
    f.marketplace_group as marketplace,
    coalesce(sum(f.gross), 0)::numeric as omzet_total,
    coalesce(sum(f.payout), 0)::numeric as payout_total,
    coalesce(sum(f.hpp), 0)::numeric as hpp_total,
    count(distinct f.order_key)::integer as orders_count
  from filtered_finance f
  group by f.marketplace_group
)
select jsonb_build_object(
  'ok', true,
  'source', 'dashboard_marketplace_order_analytics_90d',
  'source_table', 'marketplace_finance_reports',
  'marketplace', coalesce((select marketplace_filter from params), 'all'),
  'days', (select days_count from params),
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
    'abnormal_count', (select negative_payout_count from summary),
    'anomaly_count', (select negative_payout_count from summary),
    'negative_payout_total_abs', (select negative_payout_total_abs from summary),
    'payout_minus_total_abs', (select negative_payout_total_abs from summary)
  ),
  'daily', (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'date', d.day,
        'omzet_total', d.omzet_total,
        'gross_total', d.omzet_total,
        'payout_total', d.payout_total,
        'hpp_total', d.hpp_total,
        'orders_count', d.orders_count,
        'order_count', d.orders_count,
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
        'order_count', orders_count
      )
      order by marketplace
    ), '[]'::jsonb)
    from by_marketplace
  )
);
$$;

grant execute on function public.dashboard_marketplace_order_analytics_90d(text, integer) to authenticated;
grant execute on function public.dashboard_marketplace_order_analytics_90d(text, integer) to service_role;

notify pgrst, 'reload schema';
