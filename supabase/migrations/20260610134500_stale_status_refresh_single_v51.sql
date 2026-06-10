-- 20260610_stale_status_refresh_single_v51.sql
-- Install/overwrite auto single-window stale TikTok status refresh.

create schema if not exists internal;

create or replace function internal.enqueue_next_tiktok_stale_status_refresh_v51()
returns jsonb
language plpgsql
security definer
set search_path = public, internal
as $$
declare
  v_active_jobs integer := 0;
  v_job record;
begin
  select count(*) into v_active_jobs
  from public.marketplace_order_pull_jobs j
  where j.marketplace = 'tiktok_shop'
    and j.marketplace_account_id = 'e21c4302-79d7-4abd-9b99-9dc23cb240eb'
    and j.status in ('pending', 'running')
    and (
      j.payload->>'source' in ('auto_stale_status_refresh_single_v51','manual_stale_status_refresh_single_v51','manual_stale_status_refresh_batch_v51')
      or j.window_label like 'auto single stale refresh%'
      or j.window_label like 'manual single stale refresh%'
      or j.window_label like 'manual stale status refresh%'
    );

  if v_active_jobs > 0 then
    return jsonb_build_object('ok', true, 'action', 'skip_active_job', 'active_jobs', v_active_jobs);
  end if;

  with target_window as (
    select date_trunc('hour', o.order_created_at) as window_start, count(*) as stale_rows
    from public.marketplace_orders o
    where o.marketplace = 'tiktok_shop'
      and o.marketplace_account_id = 'e21c4302-79d7-4abd-9b99-9dc23cb240eb'
      and o.order_created_at >= current_date - interval '90 days'
      and o.order_created_at < now() - interval '2 days'
      and o.order_status in ('AWAITING_COLLECTION','AWAITING_SHIPMENT','IN_TRANSIT','PROCESSED','READY_TO_SHIP','TO_SHIP','UNSHIPPED')
      and not exists (
        select 1 from public.marketplace_order_pull_jobs j
        where j.marketplace_account_id = o.marketplace_account_id
          and j.marketplace = o.marketplace
          and j.job_type = 'auto_today_window'
          and j.window_start_seconds = extract(epoch from date_trunc('hour', o.order_created_at))::bigint
          and j.payload->>'source' in ('auto_stale_status_refresh_single_v51','manual_stale_status_refresh_single_v51','manual_stale_status_refresh_batch_v51')
          and j.status = 'done'
          and j.updated_at > now() - interval '24 hours'
      )
    group by date_trunc('hour', o.order_created_at)
    order by window_start asc
    limit 1
  ), src as (
    select ma.tenant_id, ma.marketplace_account_id, ma.marketplace, tw.window_start, tw.window_start + interval '1 hour' - interval '1 second' as window_end, tw.stale_rows
    from target_window tw
    join public.marketplace_accounts ma on ma.marketplace='tiktok_shop' and ma.marketplace_account_id='e21c4302-79d7-4abd-9b99-9dc23cb240eb'
  ), upserted as (
    insert into public.marketplace_order_pull_jobs (tenant_id,marketplace_account_id,marketplace,job_type,period_start,period_end,window_start_seconds,window_end_seconds,window_label,status,priority,attempts,next_run_at,locked_at,last_run_at,finished_at,order_count,item_count,mapped_count,unmapped_count,warning_count,last_message,payload,last_result,requested_by,created_at,updated_at)
    select tenant_id, marketplace_account_id, marketplace, 'auto_today_window', window_start::date, window_start::date, extract(epoch from window_start)::bigint, extract(epoch from window_end)::bigint,
      'auto single stale refresh ' || to_char(window_start, 'YYYY-MM-DD HH24:MI'), 'pending', 3500, 0, now(), null, null, null, 0,0,0,0,0,
      'Auto single stale status refresh. stale_rows=' || stale_rows,
      jsonb_build_object('mode','manual_force_refresh','source','auto_stale_status_refresh_single_v51','purpose','auto refresh one stale non-final marketplace order window','stale_rows',stale_rows,'window_start',window_start,'window_end',window_end,'skip_completed_order_pull',false,'skip_completed_orders',false,'skip_final_orders',false,'include_completed',true,'statusless_only',false,'include_update_time_search',true,'max_orders',80,'max_pages',5,'max_details',80),
      '{}'::jsonb, null, now(), now()
    from src
    on conflict (marketplace_account_id, job_type, window_start_seconds, window_end_seconds)
    do update set status='pending', priority=3500, attempts=0, next_run_at=now(), locked_at=null, last_run_at=null, finished_at=null, order_count=0, item_count=0, mapped_count=0, unmapped_count=0, warning_count=0, window_label=excluded.window_label, last_message=excluded.last_message, payload=excluded.payload, last_result='{}'::jsonb, updated_at=now()
    returning order_pull_job_id, marketplace, status, priority, window_label, payload, updated_at
  )
  select * into v_job from upserted limit 1;

  if not found then
    return jsonb_build_object('ok', true, 'action', 'no_stale_window');
  end if;

  return jsonb_build_object('ok', true, 'action', 'queued', 'order_pull_job_id', v_job.order_pull_job_id, 'marketplace', v_job.marketplace, 'status', v_job.status, 'priority', v_job.priority, 'window_label', v_job.window_label, 'payload', v_job.payload, 'updated_at', v_job.updated_at);
end;
$$;

select cron.unschedule(jobid) from cron.job where jobname = 'marketplace-stale-status-refresh-single-v51';
select cron.schedule('marketplace-stale-status-refresh-single-v51','*/5 * * * *',$$select internal.enqueue_next_tiktok_stale_status_refresh_v51();$$);
