create index if not exists idx_marketplace_orders_account_live_count
  on public.marketplace_orders(marketplace_account_id);

create index if not exists idx_marketplace_order_items_account_live_count
  on public.marketplace_order_items(marketplace_account_id);

create index if not exists idx_marketplace_finance_reports_account_live_count
  on public.marketplace_finance_reports(marketplace_account_id);

create index if not exists idx_hist_order_batches_account_status
  on public.marketplace_export_import_batches(marketplace_account_id, status);

create index if not exists idx_hist_finance_batches_account_status
  on public.marketplace_finance_export_import_batches(marketplace_account_id, status);

create index if not exists idx_hist_finalize_jobs_account_updated
  on public.marketplace_historical_finalize_jobs(marketplace_account_id, updated_at desc);

create or replace function public.marketplace_historical_import_status_snapshot()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
with active_accounts as (
  select
    marketplace_account_id,
    marketplace,
    coalesce(shop_name, shop_id::text, '-') as shop_name
  from public.marketplace_accounts
  where status = 'active'
    and marketplace in ('shopee', 'tiktok_shop')
),
order_batches as (
  select
    marketplace_account_id,
    count(*)::int as order_batches,
    count(*) filter (where status = 'finalized')::int as order_finalized_batches
  from public.marketplace_export_import_batches
  group by marketplace_account_id
),
order_rows as (
  select
    b.marketplace_account_id,
    count(r.*)::int as order_rows,
    count(distinct nullif(r.marketplace_order_sn, ''))::int as valid_orders,
    count(*) filter (
      where r.order_created_at is null
         or r.order_created_at < timestamptz '2026-03-01 00:00:00+00'
         or r.order_created_at > now() + interval '1 day'
    )::int as bad_date_rows
  from public.marketplace_export_import_batches b
  left join public.marketplace_export_import_rows r
    on r.batch_id = b.marketplace_export_import_batch_id
  group by b.marketplace_account_id
),
finance_batches as (
  select
    marketplace_account_id,
    count(*)::int as finance_batches,
    count(*) filter (where status = 'finalized')::int as finance_finalized_batches
  from public.marketplace_finance_export_import_batches
  group by marketplace_account_id
),
finance_rows as (
  select
    b.marketplace_account_id,
    count(r.*)::int as finance_rows
  from public.marketplace_finance_export_import_batches b
  left join public.marketplace_finance_export_import_rows r
    on r.batch_id = b.marketplace_finance_export_import_batch_id
  group by b.marketplace_account_id
),
live_orders as (
  select
    marketplace_account_id,
    count(*)::int as live_orders
  from public.marketplace_orders
  group by marketplace_account_id
),
live_items as (
  select
    marketplace_account_id,
    count(*)::int as live_items
  from public.marketplace_order_items
  group by marketplace_account_id
),
live_finance as (
  select
    marketplace_account_id,
    count(*)::int as live_finance_reports
  from public.marketplace_finance_reports
  group by marketplace_account_id
),
latest_jobs as (
  select distinct on (marketplace_account_id)
    marketplace_account_id,
    marketplace_historical_finalize_job_id,
    status as job_status
  from public.marketplace_historical_finalize_jobs
  order by marketplace_account_id, updated_at desc
)
select jsonb_build_object(
  'ok', true,
  'accounts',
  coalesce(
    jsonb_agg(
      jsonb_build_object(
        'marketplace_account_id', a.marketplace_account_id,
        'marketplace', a.marketplace,
        'shop_name', a.shop_name,

        'order_batches', coalesce(ob.order_batches, 0),
        'order_finalized_batches', coalesce(ob.order_finalized_batches, 0),
        'order_rows', coalesce(orows.order_rows, 0),
        'valid_orders', coalesce(orows.valid_orders, 0),
        'bad_date_rows', coalesce(orows.bad_date_rows, 0),

        'finance_batches', coalesce(fb.finance_batches, 0),
        'finance_finalized_batches', coalesce(fb.finance_finalized_batches, 0),
        'finance_rows', coalesce(frows.finance_rows, 0),

        'live_orders', coalesce(lo.live_orders, 0),
        'live_items', coalesce(li.live_items, 0),
        'live_finance_reports', coalesce(lf.live_finance_reports, 0),

        'active_job',
          case
            when lj.marketplace_historical_finalize_job_id is null then null
            else public.marketplace_historical_finalize_job_status(lj.marketplace_historical_finalize_job_id)
          end,

        'finalize_status',
          case
            when lj.job_status = 'running' then 'finalizing'
            when lj.job_status = 'error' then 'finalize_error'
            when lj.job_status = 'done' then 'finalized'
            when coalesce(ob.order_batches, 0) = 0 and coalesce(fb.finance_batches, 0) = 0 then 'waiting_order_and_income'
            when coalesce(ob.order_batches, 0) = 0 then 'waiting_order'
            when coalesce(fb.finance_batches, 0) = 0 then 'waiting_income'
            when coalesce(orows.bad_date_rows, 0) > 0 then 'needs_repair'
            when coalesce(ob.order_batches, 0) > 0
              and coalesce(fb.finance_batches, 0) > 0
              and coalesce(ob.order_finalized_batches, 0) = coalesce(ob.order_batches, 0)
              and coalesce(fb.finance_finalized_batches, 0) = coalesce(fb.finance_batches, 0)
              then 'finalized'
            else 'ready_to_finalize'
          end
      )
      order by a.marketplace, a.shop_name
    ),
    '[]'::jsonb
  )
)
from active_accounts a
left join order_batches ob on ob.marketplace_account_id = a.marketplace_account_id
left join order_rows orows on orows.marketplace_account_id = a.marketplace_account_id
left join finance_batches fb on fb.marketplace_account_id = a.marketplace_account_id
left join finance_rows frows on frows.marketplace_account_id = a.marketplace_account_id
left join live_orders lo on lo.marketplace_account_id = a.marketplace_account_id
left join live_items li on li.marketplace_account_id = a.marketplace_account_id
left join live_finance lf on lf.marketplace_account_id = a.marketplace_account_id
left join latest_jobs lj on lj.marketplace_account_id = a.marketplace_account_id;
$$;

grant execute on function public.marketplace_historical_import_status_snapshot() to authenticated, service_role;

notify pgrst, 'reload schema';
