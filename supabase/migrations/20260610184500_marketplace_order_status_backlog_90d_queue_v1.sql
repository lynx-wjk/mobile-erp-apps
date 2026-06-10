create or replace function public.marketplace_order_status_backlog_90d_queue_v1(
  p_max_days integer default 3
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  v_start date := greatest(date '2026-03-13', v_today - 89);
  v_end date := v_today - 2;
  v_inserted integer := 0;
  v_existing integer := 0;
  v_days jsonb := '[]'::jsonb;
begin
  with stale_days as (
    select
      o.tenant_id,
      o.marketplace_account_id,
      o.marketplace,
      (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date as day,
      count(*) as stale_orders,
      count(*) filter (where nullif(o.tracking_number,'') is not null or nullif(o.label_code,'') is not null) as with_resi,
      min(o.pulled_at) as oldest_pulled_at
    from public.marketplace_orders o
    join public.marketplace_accounts ma
      on ma.marketplace_account_id = o.marketplace_account_id
     and ma.tenant_id = o.tenant_id
    left join public.marketplace_finance_reports fr
      on fr.tenant_id = o.tenant_id
     and fr.marketplace_account_id = o.marketplace_account_id
     and fr.marketplace = o.marketplace
     and (
        fr.marketplace_order_id = o.marketplace_order_id
        or fr.order_id = o.order_id
        or fr.order_id = o.order_sn
        or fr.order_id = o.external_order_id
        or fr.order_id = o.remote_order_id
     )
    where coalesce(ma.is_active, true) = true
      and coalesce(ma.environment, 'production') = 'production'
      and o.marketplace = 'tiktok_shop'
      and (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date between v_start and v_end
      and upper(coalesce(o.order_status, o.status, o.raw_order->>'status','')) in ('AWAITING_SHIPMENT','AWAITING_COLLECTION','IN_TRANSIT')
      and fr.marketplace_order_id is null
      and fr.order_id is null
    group by 1,2,3,4
    having count(*) > 0
    order by count(*) desc, day desc
    limit greatest(1, p_max_days)
  ),
  existing as (
    select sd.*,
      exists (
        select 1
        from public.marketplace_order_pull_jobs j
        where j.tenant_id = sd.tenant_id
          and j.marketplace_account_id = sd.marketplace_account_id
          and j.marketplace = sd.marketplace
          and j.period_start = sd.day
          and j.period_end = sd.day + 1
          and j.status in ('pending','running')
          and j.job_type in ('stale_order_status_backlog_90d_v1','manual_tiktok_stale_status_refresh_daily_v1')
      ) as has_existing_job
    from stale_days sd
  ),
  inserted as (
    insert into public.marketplace_order_pull_jobs (
      tenant_id,
      marketplace_account_id,
      marketplace,
      job_type,
      period_start,
      period_end,
      window_start_seconds,
      window_end_seconds,
      window_label,
      status,
      priority,
      attempts,
      next_run_at,
      order_count,
      item_count,
      mapped_count,
      unmapped_count,
      warning_count,
      payload,
      last_result,
      created_at,
      updated_at
    )
    select
      e.tenant_id,
      e.marketplace_account_id,
      e.marketplace,
      'stale_order_status_backlog_90d_v1',
      e.day,
      e.day + 1,
      extract(epoch from (e.day::timestamp at time zone 'Asia/Jakarta'))::bigint,
      extract(epoch from ((e.day + 1)::timestamp at time zone 'Asia/Jakarta'))::bigint,
      'Stale order status backlog 90d ' || e.marketplace || ' ' || e.day::text,
      'pending',
      85,
      0,
      now(),
      0,
      0,
      0,
      0,
      0,
      jsonb_build_object(
        'mode','stale_order_status_backlog_90d',
        'source','marketplace_order_status_backlog_90d_queue_v1',
        'missing_finance_only', true,
        'refresh_status_only', true,
        'exclude_statuses', jsonb_build_array('CANCELLED','UNPAID','RETURNED','REFUNDED','FAILED','CLOSED'),
        'target_statuses', jsonb_build_array('AWAITING_SHIPMENT','AWAITING_COLLECTION','IN_TRANSIT'),
        'stale_orders', e.stale_orders,
        'with_resi', e.with_resi,
        'max_pages', 3,
        'page_size', 50,
        'max_orders', 150
      ),
      '{}'::jsonb,
      now(),
      now()
    from existing e
    where not e.has_existing_job
    returning period_start, payload
  )
  select
    (select count(*) from inserted),
    (select count(*) from existing where has_existing_job),
    coalesce((select jsonb_agg(jsonb_build_object('day', period_start, 'payload', payload)) from inserted), '[]'::jsonb)
  into v_inserted, v_existing, v_days;

  return jsonb_build_object(
    'ok', true,
    'version', 'marketplace_order_status_backlog_90d_queue_v1',
    'range_start', v_start,
    'range_end', v_end,
    'inserted_jobs', v_inserted,
    'existing_pending_or_running_jobs', v_existing,
    'days', v_days
  );
end;
$$;

create or replace function public.marketplace_order_status_backlog_90d_cron_v1()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.marketplace_order_status_backlog_90d_queue_v1(3);
end;
$$;

do $$
begin
  if to_regprocedure('cron.unschedule(text)') is not null then
    begin
      perform cron.unschedule('marketplace-order-status-backlog-90d-v1');
    exception when others then
      null;
    end;
  end if;

  perform cron.schedule(
    'marketplace-order-status-backlog-90d-v1',
    '*/10 * * * *',
    'select public.marketplace_order_status_backlog_90d_cron_v1();'
  );
exception when others then
  raise notice 'Skip schedule order status backlog cron: %', sqlerrm;
end $$;
