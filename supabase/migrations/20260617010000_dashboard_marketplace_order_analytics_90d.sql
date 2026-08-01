create or replace function public.dashboard_marketplace_order_analytics_90d(
  p_marketplace text default null,
  p_days integer default 90
)
returns jsonb
language sql
stable
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
calendar as (
  select generate_series(
    (select start_date from params),
    (select end_date from params),
    interval '1 day'
  )::date as day
),
base_orders as (
  select
    mo.order_created_at,
    to_jsonb(mo) as j,
    ma.marketplace as account_marketplace
  from public.marketplace_orders mo
  left join public.marketplace_accounts ma
    on ma.marketplace_account_id = mo.marketplace_account_id
  cross join params p
  where mo.order_created_at >= p.start_date::timestamptz
    and mo.order_created_at < (p.end_date + 1)::timestamptz
),
normalized_orders as (
  select
    date(order_created_at) as order_date,
    coalesce(
      nullif(j->>'marketplace_order_id', ''),
      nullif(j->>'order_sn', ''),
      nullif(j->>'external_order_id', ''),
      nullif(j->>'order_id', ''),
      md5(j::text)
    ) as order_key,
    case
      when lower(regexp_replace(coalesce(nullif(j->>'marketplace', ''), account_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
      when lower(regexp_replace(coalesce(nullif(j->>'marketplace', ''), account_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
      else lower(regexp_replace(coalesce(nullif(j->>'marketplace', ''), account_marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
    end as marketplace_group,
    lower(coalesce(nullif(j->>'order_status', ''), nullif(j->>'status', ''), '')) as order_status,
    coalesce(
      case when coalesce(j->>'gross_amount', '') ~ '^-?[0-9]+(\.[0-9]+)?$' then (j->>'gross_amount')::numeric end,
      case when coalesce(j->>'gross_sales', '') ~ '^-?[0-9]+(\.[0-9]+)?$' then (j->>'gross_sales')::numeric end,
      case when coalesce(j->>'total_amount', '') ~ '^-?[0-9]+(\.[0-9]+)?$' then (j->>'total_amount')::numeric end,
      case when coalesce(j->>'paid_amount', '') ~ '^-?[0-9]+(\.[0-9]+)?$' then (j->>'paid_amount')::numeric end,
      case when coalesce(j->>'buyer_paid_amount', '') ~ '^-?[0-9]+(\.[0-9]+)?$' then (j->>'buyer_paid_amount')::numeric end,
      0::numeric
    ) as amount
  from base_orders
  where order_created_at is not null
),
filtered_orders as (
  select n.*
  from normalized_orders n
  cross join params p
  where (p.marketplace_filter is null or n.marketplace_group = p.marketplace_filter)
    and n.order_key is not null
    and n.order_key <> ''
    and n.order_status not in ('cancelled', 'canceled', 'cancel')
),
daily as (
  select
    c.day,
    coalesce(sum(f.amount), 0)::numeric as omzet_total,
    count(distinct f.order_key)::integer as orders_count
  from calendar c
  left join filtered_orders f
    on f.order_date = c.day
  group by c.day
),
summary as (
  select
    coalesce(sum(d.omzet_total), 0)::numeric as omzet_total,
    coalesce(sum(d.orders_count), 0)::integer as orders_count
  from daily d
),
by_marketplace as (
  select
    n.marketplace_group as marketplace,
    coalesce(sum(n.amount), 0)::numeric as omzet_total,
    count(distinct n.order_key)::integer as orders_count
  from filtered_orders n
  group by n.marketplace_group
)
select jsonb_build_object(
  'ok', true,
  'source', 'dashboard_marketplace_order_analytics_90d',
  'marketplace', coalesce((select marketplace_filter from params), 'all'),
  'days', (select days_count from params),
  'start_date', (select start_date from params),
  'end_date', (select end_date from params),
  'summary', jsonb_build_object(
    'omzet_total', (select omzet_total from summary),
    'orders_count', (select orders_count from summary),
    'order_count', (select orders_count from summary)
  ),
  'daily', (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'date', d.day,
        'omzet_total', d.omzet_total,
        'orders_count', d.orders_count,
        'order_count', d.orders_count
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
        'orders_count', orders_count
      )
      order by marketplace
    ), '[]'::jsonb)
    from by_marketplace
  )
);
$$;

grant execute on function public.dashboard_marketplace_order_analytics_90d(text, integer) to authenticated;
grant execute on function public.dashboard_marketplace_order_analytics_90d(text, integer) to service_role;
