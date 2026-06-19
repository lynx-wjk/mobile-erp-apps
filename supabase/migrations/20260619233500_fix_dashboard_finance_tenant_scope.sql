-- Canonical RPC overwrite only. No new versioned functions.
-- Fix self-hosted JWTs that have auth.uid()/sub but no tenant_id claim.
-- Finance page initial load uses a bounded tenant-scoped aggregate instead of
-- blocking on the heavy finance_customer_dashboard_snapshot RPC.

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
finance_rows as materialized (
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
filtered_finance as materialized (
  select f.*
  from finance_rows f
  cross join params p
  where (p.marketplace_filter is null or f.marketplace_group = p.marketplace_filter)
    and f.order_key is not null
    and f.order_key <> ''
),
daily as materialized (
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

create or replace function public.finance_dashboard_snapshot(
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
    coalesce(p_start, date_trunc('month', current_date)::date) as start_date,
    coalesce(p_end, current_date)::date as end_date,
    case
      when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
      when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
      else null
    end as marketplace_filter
),
accounts as (
  select ma.marketplace_account_id, ma.tenant_id, ma.marketplace,
         coalesce(nullif(ma.store_alias, ''), nullif(ma.shop_name, ''), ma.shop_id, ma.marketplace) as store_label,
         ma.store_alias, ma.shop_name, ma.status, ma.is_active
  from public.marketplace_accounts ma
  cross join tenant_scope t
  where (
      t.jwt_role = 'service_role'
      or (t.tenant_id is not null and ma.tenant_id = t.tenant_id)
    )
    and coalesce(ma.is_deleted, false) = false
),
finance_rows as materialized (
  select
    fr.period_start::date as report_date,
    coalesce(
      nullif(fr.order_id::text, ''),
      nullif(fr.marketplace_order_id::text, ''),
      fr.finance_report_id::text
    ) as order_key,
    fr.marketplace_account_id,
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
    and (p.marketplace_filter is null or
      case
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
        else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end = p.marketplace_filter)
    and (p_account_id is null or fr.marketplace_account_id = p_account_id)
),
daily as materialized (
  select
    f.report_date,
    coalesce(sum(f.gross), 0)::numeric as omzet_total,
    coalesce(sum(f.payout), 0)::numeric as payout_total,
    coalesce(sum(f.hpp), 0)::numeric as hpp_total,
    count(distinct f.order_key)::integer as orders_count,
    count(*) filter (where f.payout < 0)::integer as abnormal_count,
    coalesce(sum(abs(f.payout)) filter (where f.payout < 0), 0)::numeric as negative_payout_total_abs
  from finance_rows f
  where f.order_key is not null and f.order_key <> ''
  group by f.report_date
),
summary as (
  select
    coalesce(sum(d.omzet_total), 0)::numeric as omzet_total,
    coalesce(sum(d.payout_total), 0)::numeric as payout_total,
    coalesce(sum(d.hpp_total), 0)::numeric as hpp_total,
    coalesce(sum(d.orders_count), 0)::integer as orders_count,
    coalesce(sum(d.abnormal_count), 0)::integer as abnormal_count,
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
  from finance_rows f
  where f.order_key is not null and f.order_key <> ''
  group by f.marketplace_group
)
select jsonb_build_object(
  'ok', true,
  'version', 'finance_dashboard_snapshot_mtd_aggregate_20260619',
  'source', 'finance_dashboard_snapshot',
  'source_table', 'marketplace_finance_reports',
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
    'finance_order_count', (select orders_count from summary),
    'order_count', (select orders_count from summary),
    'abnormal_count', (select abnormal_count from summary),
    'anomaly_count', (select abnormal_count from summary),
    'negative_payout_total_abs', (select negative_payout_total_abs from summary),
    'payout_minus_total_abs', (select negative_payout_total_abs from summary)
  ),
  'daily', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'date', d.report_date,
      'omzet_total', d.omzet_total,
      'gross_total', d.omzet_total,
      'payout_total', d.payout_total,
      'hpp_total', d.hpp_total,
      'orders_count', d.orders_count,
      'order_count', d.orders_count,
      'abnormal_count', d.abnormal_count,
      'negative_payout_total_abs', d.negative_payout_total_abs
    ) order by d.report_date), '[]'::jsonb)
    from daily d
  ),
  'by_marketplace', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'marketplace', marketplace,
      'omzet_total', omzet_total,
      'gross_total', omzet_total,
      'payout_total', payout_total,
      'hpp_total', hpp_total,
      'orders_count', orders_count,
      'order_count', orders_count
    ) order by marketplace), '[]'::jsonb)
    from by_marketplace
  ),
  'accounts', (
    select coalesce(jsonb_agg(to_jsonb(a) order by a.marketplace, a.store_label), '[]'::jsonb)
    from accounts a
  ),
  'expenses', '[]'::jsonb,
  'approved_purchases', '[]'::jsonb,
  'skus', '[]'::jsonb,
  'sku_rows', '[]'::jsonb,
  'cash_flow', '[]'::jsonb,
  'profit_loss_breakdown', '[]'::jsonb
);
$$;

grant execute on function public.dashboard_marketplace_order_analytics_90d(text, integer) to authenticated, service_role;
grant execute on function public.finance_dashboard_snapshot(date, date, text, uuid) to authenticated, service_role;

notify pgrst, 'reload schema';
