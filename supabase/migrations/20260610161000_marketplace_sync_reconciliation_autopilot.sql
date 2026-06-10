-- 20260610_marketplace_sync_reconciliation_autopilot.sql
-- Canonical marketplace sync reconciliation guard + audit view.
-- No Finance/HPP formula changes. No versioned finance RPC.

create schema if not exists internal;

-- Pause noisy v51 stale refresh cron. It used high priority and update-time refresh, which can disturb fresh order queue.
update cron.job
set active = false
where jobname = 'marketplace-stale-status-refresh-single-v51';

-- Cancel only stale v51 pending/running jobs. Do not touch normal fresh order jobs.
update public.marketplace_order_pull_jobs
set
  status = 'cancelled',
  locked_at = null,
  finished_at = now(),
  updated_at = now(),
  last_message = coalesce(last_message, '') || ' | cancelled by marketplace sync reconciliation autopilot; stale v51 replaced'
where status in ('pending','running')
  and payload->>'source' in (
    'auto_stale_status_refresh_single_v51',
    'manual_stale_status_refresh_single_v51',
    'manual_stale_status_refresh_batch_v51'
  );

create or replace view public.marketplace_sync_reconciliation_audit as
with order_base as (
  select
    o.tenant_id,
    o.marketplace,
    o.marketplace_account_id,
    o.marketplace_order_id,
    o.order_sn,
    coalesce(o.order_created_at, o.created_time) as order_created_at,
    upper(coalesce(o.order_status, o.status, o.fulfillment_status, 'UNKNOWN')) as order_status,
    coalesce(o.total_amount, 0)::numeric as total_amount,
    coalesce(o.paid_amount, 0)::numeric as paid_amount,
    o.tracking_number,
    o.pulled_at,
    o.updated_at
  from public.marketplace_orders o
), finance_by_order as (
  select
    fr.tenant_id,
    fr.marketplace,
    fr.marketplace_account_id,
    fr.order_id as order_sn,
    count(*)::integer as finance_rows,
    sum(coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0))::numeric as payout_amount,
    sum(coalesce(fr.gross_amount, fr.gross_sales, 0))::numeric as finance_gross_amount,
    min(fr.pulled_at) as first_finance_pulled_at,
    max(fr.pulled_at) as last_finance_pulled_at
  from public.marketplace_finance_reports fr
  group by fr.tenant_id, fr.marketplace, fr.marketplace_account_id, fr.order_id
)
select
  ob.tenant_id,
  ob.marketplace,
  ob.marketplace_account_id,
  date_trunc('month', ob.order_created_at at time zone 'Asia/Jakarta')::date as month_wib,
  ob.order_status,
  count(*)::integer as order_count,
  sum(ob.total_amount)::numeric as total_amount,
  sum(ob.paid_amount)::numeric as paid_amount,
  count(*) filter (where ob.tracking_number is null)::integer as no_tracking,
  count(*) filter (where ob.tracking_number is not null)::integer as has_tracking,
  count(*) filter (where f.finance_rows is not null)::integer as orders_with_finance_report,
  count(*) filter (where f.finance_rows is null)::integer as orders_without_finance_report,
  coalesce(sum(f.payout_amount), 0)::numeric as payout_amount,
  coalesce(sum(f.finance_gross_amount), 0)::numeric as finance_gross_amount,
  count(*) filter (where ob.marketplace = 'shopee' and f.finance_rows is null and ob.order_status not in ('CANCELLED','CANCELED','UNPAID'))::integer as shopee_pending_or_unsupported,
  count(*) filter (where ob.marketplace = 'tiktok_shop' and f.finance_rows is null and ob.order_status not in ('CANCELLED','CANCELED','UNPAID'))::integer as tiktok_pending_payout,
  count(*) filter (where ob.order_status in ('CANCELLED','CANCELED'))::integer as cancelled_orders,
  min(ob.order_created_at at time zone 'Asia/Jakarta') as min_order_created_wib,
  max(ob.order_created_at at time zone 'Asia/Jakarta') as max_order_created_wib,
  max(ob.pulled_at at time zone 'Asia/Jakarta') as max_order_pulled_wib,
  max(ob.updated_at at time zone 'Asia/Jakarta') as max_order_db_updated_wib,
  max(f.last_finance_pulled_at at time zone 'Asia/Jakarta') as max_finance_pulled_wib
from order_base ob
left join finance_by_order f
  on f.tenant_id = ob.tenant_id
 and f.marketplace = ob.marketplace
 and f.marketplace_account_id = ob.marketplace_account_id
 and f.order_sn = ob.order_sn
group by ob.tenant_id, ob.marketplace, ob.marketplace_account_id, 4, ob.order_status;

comment on view public.marketplace_sync_reconciliation_audit is
'Canonical audit view for marketplace order status and finance payout reconciliation. Read-only. Does not change Finance/HPP formulas.';
