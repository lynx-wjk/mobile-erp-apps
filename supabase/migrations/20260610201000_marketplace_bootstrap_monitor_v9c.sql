-- 20260610201000_marketplace_bootstrap_monitor_v9c.sql
-- Production-safe monitor/audit layer for marketplace 90-day bootstrap.
-- No Finance/HPP logic changes. No physical delete. No hardcoded tenant/account.

create or replace view public.marketplace_bootstrap_page_limit_audit_v1 as
with b as (
  select
    j.tenant_id,
    j.marketplace_account_id,
    j.marketplace,
    j.order_pull_job_id,
    j.job_type,
    j.period_start,
    j.period_end,
    j.window_start_seconds,
    j.window_end_seconds,
    j.order_count,
    j.item_count,
    j.warning_count,
    j.last_message,
    j.payload,
    j.finished_at
  from public.marketplace_order_pull_jobs j
  where j.job_type in ('bootstrap_90d_adaptive_v1', 'bootstrap_90d_daily_v1')
    and j.status = 'done'
), d as (
  select
    b.order_pull_job_id,
    count(o.marketplace_order_id)::bigint as db_orders_in_window,
    count(o.marketplace_order_id) filter (where upper(coalesce(o.order_status,o.status,'')) = 'COMPLETED')::bigint as db_completed_orders_in_window,
    count(o.marketplace_order_id) filter (where upper(coalesce(o.order_status,o.status,'')) <> 'COMPLETED')::bigint as db_non_completed_orders_in_window,
    min(coalesce(o.order_created_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta') as first_order_wib,
    max(coalesce(o.order_created_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta') as last_order_wib
  from b
  left join public.marketplace_orders o
    on o.tenant_id = b.tenant_id
   and o.marketplace_account_id = b.marketplace_account_id
   and extract(epoch from coalesce(o.order_created_at, o.created_time, o.created_at))::bigint >= b.window_start_seconds
   and extract(epoch from coalesce(o.order_created_at, o.created_time, o.created_at))::bigint < b.window_end_seconds
  group by b.order_pull_job_id
)
select
  b.tenant_id,
  b.marketplace_account_id,
  b.marketplace,
  coalesce(a.store_alias, a.shop_name, b.marketplace_account_id::text) as store_name,
  b.order_pull_job_id,
  b.job_type,
  b.period_start,
  b.period_end,
  b.order_count as pulled_orders_in_job,
  b.item_count as pulled_items_in_job,
  d.db_orders_in_window,
  d.db_completed_orders_in_window,
  d.db_non_completed_orders_in_window,
  d.first_order_wib,
  d.last_order_wib,
  b.warning_count,
  b.last_message,
  nullif(b.payload->>'max_pages_per_window','')::integer as payload_max_pages_per_window,
  b.payload->>'window_kind' as window_kind,
  b.finished_at,
  b.finished_at at time zone 'Asia/Jakarta' as finished_wib,
  (b.order_count >= 10 and d.db_orders_in_window > b.order_count and b.last_message ilike '%Page dicek: 1%') as likely_page_limit_risk,
  case when (b.order_count >= 10 and d.db_orders_in_window > b.order_count and b.last_message ilike '%Page dicek: 1%')
    then 'Job hanya memproses 1 page/10 order, tetapi DB punya order lebih banyak di window yang sama. Bootstrap belum final sampai pagination worker diperbaiki.'
    else null end as risk_message,
  now() as refreshed_at,
  now() at time zone 'Asia/Jakarta' as refreshed_at_wib
from b
join d on d.order_pull_job_id = b.order_pull_job_id
left join public.marketplace_accounts a on a.marketplace_account_id = b.marketplace_account_id;

revoke all on public.marketplace_bootstrap_page_limit_audit_v1 from public;
revoke all on public.marketplace_bootstrap_page_limit_audit_v1 from anon;
revoke all on public.marketplace_bootstrap_page_limit_audit_v1 from authenticated;

create or replace view public.marketplace_account_bootstrap_status_v2 as
with page_risk as (
  select
    tenant_id,
    marketplace_account_id,
    marketplace,
    count(*) filter (where likely_page_limit_risk)::integer as page_limit_risk_jobs,
    max(db_orders_in_window) filter (where likely_page_limit_risk) as max_risk_window_db_orders,
    max(pulled_orders_in_job) filter (where likely_page_limit_risk) as max_risk_window_pulled_orders,
    max(risk_message) filter (where likely_page_limit_risk) as page_limit_risk_message
  from public.marketplace_bootstrap_page_limit_audit_v1
  group by tenant_id, marketplace_account_id, marketplace
)
select
  s.tenant_id,
  s.marketplace_account_id,
  s.marketplace,
  s.store_name,
  s.shop_name,
  s.store_alias,
  s.environment,
  s.account_status,
  s.connected_at,
  s.last_connected_at,
  s.reauthorized_at,
  s.revoked_at,
  case when coalesce(pr.page_limit_risk_jobs,0) > 0 then 'blocked_pagination_limit' else s.bootstrap_status end as bootstrap_status,
  case when coalesce(pr.page_limit_risk_jobs,0) > 0
    then 'Sinkronisasi 90 hari tertahan karena data marketplace lebih banyak dari limit halaman yang diproses. Admin perlu memperbaiki pagination sebelum data dianggap final.'
    else s.client_message end as client_message,
  s.total_jobs,
  s.done_jobs,
  s.pending_jobs,
  s.running_jobs,
  s.failed_jobs,
  s.cancelled_jobs,
  s.orders_pulled,
  s.items_pulled,
  coalesce(pr.page_limit_risk_jobs,0) as page_limit_risk_jobs,
  pr.max_risk_window_db_orders,
  pr.max_risk_window_pulled_orders,
  pr.page_limit_risk_message,
  s.progress_pct,
  s.period_start,
  s.period_end,
  s.first_queued_at,
  s.first_done_run_at,
  s.first_finished_at,
  s.last_finished_at,
  s.next_pending_at,
  s.last_updated_at,
  s.last_running_touch_at,
  s.seconds_per_job_est,
  s.estimated_remaining,
  s.estimated_finish_at,
  s.estimated_finish_wib,
  s.job_types,
  s.window_kinds,
  s.last_failed_message,
  s.last_message,
  s.account_last_error,
  s.refreshed_at,
  s.refreshed_at_wib
from public.marketplace_account_bootstrap_status_v1 s
left join page_risk pr
  on pr.tenant_id = s.tenant_id
 and pr.marketplace_account_id = s.marketplace_account_id
 and pr.marketplace = s.marketplace;

revoke all on public.marketplace_account_bootstrap_status_v2 from public;
revoke all on public.marketplace_account_bootstrap_status_v2 from anon;
revoke all on public.marketplace_account_bootstrap_status_v2 from authenticated;

create or replace function public.marketplace_bootstrap_status_for_current_tenant_v1()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tenant_id uuid := public.app_current_tenant_id_or_default();
  v_accounts jsonb := '[]'::jsonb;
  v_summary jsonb := '{}'::jsonb;
begin
  if v_tenant_id is null then
    return jsonb_build_object('ok', false, 'message', 'Tenant tidak ditemukan untuk user aktif.', 'accounts', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(to_jsonb(s) - 'tenant_id' order by s.marketplace, s.store_name), '[]'::jsonb)
    into v_accounts
  from public.marketplace_account_bootstrap_status_v2 s
  where s.tenant_id = v_tenant_id;

  select jsonb_build_object(
    'total_accounts', count(*)::integer,
    'syncing_accounts', count(*) filter (where bootstrap_status in ('queued','pulling','syncing'))::integer,
    'completed_accounts', count(*) filter (where bootstrap_status = 'completed')::integer,
    'failed_accounts', count(*) filter (where bootstrap_status = 'failed')::integer,
    'blocked_accounts', count(*) filter (where bootstrap_status = 'blocked_pagination_limit')::integer,
    'page_limit_risk_jobs', coalesce(sum(page_limit_risk_jobs),0)::integer,
    'total_jobs', coalesce(sum(total_jobs),0)::integer,
    'done_jobs', coalesce(sum(done_jobs),0)::integer,
    'pending_jobs', coalesce(sum(pending_jobs),0)::integer,
    'running_jobs', coalesce(sum(running_jobs),0)::integer,
    'failed_jobs', coalesce(sum(failed_jobs),0)::integer,
    'orders_pulled', coalesce(sum(orders_pulled),0)::bigint,
    'items_pulled', coalesce(sum(items_pulled),0)::bigint,
    'progress_pct', case when coalesce(sum(total_jobs),0)=0 then 0 else round((coalesce(sum(done_jobs),0)::numeric/nullif(sum(total_jobs),0))*100,1) end,
    'estimated_finish_at', max(estimated_finish_at),
    'estimated_finish_wib', max(estimated_finish_wib),
    'refreshed_at', now(),
    'refreshed_at_wib', now() at time zone 'Asia/Jakarta'
  ) into v_summary
  from public.marketplace_account_bootstrap_status_v2
  where tenant_id = v_tenant_id;

  return jsonb_build_object('ok', true, 'tenant_id', v_tenant_id, 'accounts', v_accounts, 'summary', v_summary);
end;
$$;

grant execute on function public.marketplace_bootstrap_status_for_current_tenant_v1() to authenticated;
revoke execute on function public.marketplace_bootstrap_status_for_current_tenant_v1() from anon;
