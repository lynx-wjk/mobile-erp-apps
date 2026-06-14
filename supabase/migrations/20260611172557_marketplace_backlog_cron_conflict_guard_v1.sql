alter table public.marketplace_accounts
  add column if not exists is_active boolean
  generated always as (
    lower(coalesce(status, '')) = 'active'
    and coalesce(is_deleted, false) = false
  ) stored;

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
  v_reactivated integer := 0;
  v_existing_active integer := 0;
  v_existing_recent integer := 0;
  v_days jsonb := '[]'::jsonb;
begin
  with stale_days as (
    select
      o.tenant_id,
      o.marketplace_account_id,
      o.marketplace,
      (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date as day,
      count(*) as stale_orders,
      count(*) filter (where nullif(o.tracking_number, '') is not null or nullif(o.label_code, '') is not null) as with_resi,
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
      and upper(coalesce(o.order_status, o.status, o.raw_order->>'status', '')) in ('AWAITING_SHIPMENT', 'AWAITING_COLLECTION', 'IN_TRANSIT')
      and fr.marketplace_order_id is null
      and fr.order_id is null
    group by 1, 2, 3, 4
    having count(*) > 0
    order by count(*) desc, day desc
    limit greatest(1, coalesce(p_max_days, 3))
  ),
  keyed as (
    select
      sd.*,
      extract(epoch from (sd.day::timestamp at time zone 'Asia/Jakarta'))::bigint as window_start_seconds,
      extract(epoch from ((sd.day + 1)::timestamp at time zone 'Asia/Jakarta'))::bigint as window_end_seconds
    from stale_days sd
  ),
  existing as (
    select
      k.*,
      j.order_pull_job_id as existing_job_id,
      lower(coalesce(j.status, '')) as existing_status,
      j.updated_at as existing_updated_at
    from keyed k
    left join public.marketplace_order_pull_jobs j
      on j.tenant_id = k.tenant_id
     and j.marketplace_account_id = k.marketplace_account_id
     and j.marketplace = k.marketplace
     and j.job_type = 'stale_order_status_backlog_90d_v1'
     and j.window_start_seconds = k.window_start_seconds
     and j.window_end_seconds = k.window_end_seconds
  ),
  candidates as (
    select *
    from existing e
    where coalesce(e.existing_status, '') not in ('pending', 'running', 'retry')
      and (
        e.existing_job_id is null
        or coalesce(e.existing_updated_at, now() - interval '100 years') < now() - interval '2 hours'
      )
  ),
  upserted as (
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
      locked_at,
      last_run_at,
      finished_at,
      order_count,
      item_count,
      mapped_count,
      unmapped_count,
      warning_count,
      last_message,
      payload,
      last_result,
      created_at,
      updated_at
    )
    select
      c.tenant_id,
      c.marketplace_account_id,
      c.marketplace,
      'stale_order_status_backlog_90d_v1',
      c.day,
      c.day + 1,
      c.window_start_seconds,
      c.window_end_seconds,
      'Stale order status backlog 90d ' || c.marketplace || ' ' || c.day::text,
      'pending',
      96,
      0,
      now(),
      null,
      null,
      null,
      0,
      0,
      0,
      0,
      0,
      'Queued stale status backlog because finance/payout is still missing.',
      jsonb_build_object(
        'mode', 'stale_order_status_backlog_90d',
        'source', 'marketplace_order_status_backlog_90d_queue_v1_conflict_guard',
        'missing_finance_only', true,
        'refresh_status_only', true,
        'exclude_statuses', jsonb_build_array('CANCELLED', 'UNPAID', 'RETURNED', 'REFUNDED', 'FAILED', 'CLOSED'),
        'target_statuses', jsonb_build_array('AWAITING_SHIPMENT', 'AWAITING_COLLECTION', 'IN_TRANSIT'),
        'stale_orders', c.stale_orders,
        'with_resi', c.with_resi,
        'oldest_pulled_at', c.oldest_pulled_at,
        'requeue_after_hours', 2,
        'max_pages', 3,
        'page_size', 50,
        'max_orders', 150
      ),
      '{}'::jsonb,
      now(),
      now()
    from candidates c
    on conflict (marketplace_account_id, job_type, window_start_seconds, window_end_seconds)
    do update set
      status = 'pending',
      priority = greatest(public.marketplace_order_pull_jobs.priority, excluded.priority),
      attempts = 0,
      next_run_at = now(),
      locked_at = null,
      last_run_at = null,
      finished_at = null,
      order_count = 0,
      item_count = 0,
      mapped_count = 0,
      unmapped_count = 0,
      warning_count = 0,
      window_label = excluded.window_label,
      last_message = 'Requeued stale status backlog because finance/payout is still missing.',
      payload = public.marketplace_order_pull_jobs.payload
        || excluded.payload
        || jsonb_build_object(
          'reactivated_from_status', public.marketplace_order_pull_jobs.status,
          'reactivated_at', now()
        ),
      last_result = '{}'::jsonb,
      updated_at = now()
    where lower(coalesce(public.marketplace_order_pull_jobs.status, '')) not in ('pending', 'running', 'retry')
      and coalesce(public.marketplace_order_pull_jobs.updated_at, public.marketplace_order_pull_jobs.created_at) < now() - interval '2 hours'
    returning
      (xmax = 0) as inserted,
      period_start,
      payload,
      status
  )
  select
    coalesce(count(*) filter (where inserted), 0)::integer,
    coalesce(count(*) filter (where not inserted), 0)::integer,
    coalesce((
      select count(*)::integer
      from existing
      where existing_status in ('pending', 'running', 'retry')
    ), 0),
    coalesce((
      select count(*)::integer
      from existing
      where existing_job_id is not null
        and existing_status not in ('pending', 'running', 'retry')
        and coalesce(existing_updated_at, now() - interval '100 years') >= now() - interval '2 hours'
    ), 0),
    coalesce((
      select jsonb_agg(jsonb_build_object('day', period_start, 'status', status, 'payload', payload))
      from upserted
    ), '[]'::jsonb)
  into v_inserted, v_reactivated, v_existing_active, v_existing_recent, v_days
  from upserted;

  return jsonb_build_object(
    'ok', true,
    'version', 'marketplace_order_status_backlog_90d_queue_v1_conflict_guard',
    'range_start', v_start,
    'range_end', v_end,
    'inserted_jobs', v_inserted,
    'reactivated_jobs', v_reactivated,
    'existing_active_jobs', v_existing_active,
    'existing_recent_jobs', v_existing_recent,
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

create or replace function public.marketplace_requeue_cancelled_order_windows_90d_v1(
  p_max_jobs integer default 3
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  v_start_seconds bigint := extract(epoch from ((v_today - 89)::timestamp at time zone 'Asia/Jakarta'))::bigint;
  v_end_seconds bigint := extract(epoch from ((v_today + 1)::timestamp at time zone 'Asia/Jakarta'))::bigint;
  v_inserted integer := 0;
  v_reactivated integer := 0;
  v_jobs jsonb := '[]'::jsonb;
begin
  with source_windows as (
    select
      j.*,
      row_number() over (
        partition by j.tenant_id, j.marketplace_account_id, j.marketplace, j.window_start_seconds, j.window_end_seconds
        order by
          case when j.window_start_seconds >= extract(epoch from ((v_today - 7)::timestamp at time zone 'Asia/Jakarta'))::bigint then 0 else 1 end,
          j.window_start_seconds desc,
          j.updated_at desc
      ) as rn
    from public.marketplace_order_pull_jobs j
    join public.marketplace_accounts ma
      on ma.tenant_id = j.tenant_id
     and ma.marketplace_account_id = j.marketplace_account_id
    where lower(coalesce(j.status, '')) in ('cancelled', 'canceled', 'failed')
      and j.job_type in ('auto_recent', 'auto_recent_free_plan', 'auto_today_window', 'auto_yesterday_window')
      and j.window_start_seconds >= v_start_seconds
      and j.window_start_seconds < v_end_seconds
      and coalesce(ma.is_active, true) = true
      and coalesce(ma.environment, 'production') = 'production'
      and not exists (
        select 1
        from public.marketplace_order_pull_jobs existing
        where existing.tenant_id = j.tenant_id
          and existing.marketplace_account_id = j.marketplace_account_id
          and existing.marketplace = j.marketplace
          and existing.job_type = 'cancelled_order_window_backlog_90d_v1'
          and existing.window_start_seconds = j.window_start_seconds
          and existing.window_end_seconds = j.window_end_seconds
          and lower(coalesce(existing.status, '')) in ('pending', 'running', 'retry', 'done', 'success', 'completed')
      )
    order by
      case when j.window_start_seconds >= extract(epoch from ((v_today - 7)::timestamp at time zone 'Asia/Jakarta'))::bigint then 0 else 1 end,
      j.window_start_seconds desc,
      j.updated_at desc
    limit greatest(1, coalesce(p_max_jobs, 3))
  ),
  selected as (
    select *
    from source_windows
    where rn = 1
  ),
  upserted as (
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
      locked_at,
      last_run_at,
      finished_at,
      order_count,
      item_count,
      mapped_count,
      unmapped_count,
      warning_count,
      last_message,
      payload,
      last_result,
      requested_by,
      created_at,
      updated_at
    )
    select
      s.tenant_id,
      s.marketplace_account_id,
      s.marketplace,
      'cancelled_order_window_backlog_90d_v1',
      (to_timestamp(s.window_start_seconds) at time zone 'Asia/Jakarta')::date,
      (to_timestamp(greatest(s.window_end_seconds - 1, s.window_start_seconds)) at time zone 'Asia/Jakarta')::date,
      s.window_start_seconds,
      s.window_end_seconds,
      'Cancelled window backlog 90d ' || s.marketplace || ' ' || to_char(to_timestamp(s.window_start_seconds) at time zone 'Asia/Jakarta', 'YYYY-MM-DD HH24:MI'),
      'pending',
      greatest(coalesce(s.priority, 0), 88),
      0,
      now(),
      null,
      null,
      null,
      0,
      0,
      0,
      0,
      0,
      'Requeued cancelled/failed automatic order window for 90-day backlog reconciliation.',
      jsonb_build_object(
        'mode', 'cancelled_order_window_backlog_90d',
        'source', 'marketplace_requeue_cancelled_order_windows_90d_v1',
        'rescued_order_pull_job_id', s.order_pull_job_id,
        'rescued_job_type', s.job_type,
        'rescued_status', s.status,
        'rescued_last_message', s.last_message,
        'skip_completed_order_pull', false,
        'skip_completed_orders', false,
        'skip_final_orders', false,
        'include_completed', true,
        'statusless_only', false,
        'include_update_time_search', true,
        'max_orders', 80,
        'max_pages', 3,
        'max_details', 80
      ),
      '{}'::jsonb,
      null,
      now(),
      now()
    from selected s
    on conflict (marketplace_account_id, job_type, window_start_seconds, window_end_seconds)
    do update set
      status = 'pending',
      priority = greatest(public.marketplace_order_pull_jobs.priority, excluded.priority),
      attempts = 0,
      next_run_at = now(),
      locked_at = null,
      last_run_at = null,
      finished_at = null,
      order_count = 0,
      item_count = 0,
      mapped_count = 0,
      unmapped_count = 0,
      warning_count = 0,
      last_message = excluded.last_message,
      payload = public.marketplace_order_pull_jobs.payload
        || excluded.payload
        || jsonb_build_object(
          'reactivated_from_status', public.marketplace_order_pull_jobs.status,
          'reactivated_at', now()
        ),
      last_result = '{}'::jsonb,
      updated_at = now()
    where lower(coalesce(public.marketplace_order_pull_jobs.status, '')) in ('failed', 'cancelled', 'canceled')
      and coalesce(public.marketplace_order_pull_jobs.updated_at, public.marketplace_order_pull_jobs.created_at) < now() - interval '1 hour'
    returning
      (xmax = 0) as inserted,
      order_pull_job_id,
      marketplace,
      window_label,
      payload
  )
  select
    coalesce(count(*) filter (where inserted), 0)::integer,
    coalesce(count(*) filter (where not inserted), 0)::integer,
    coalesce(jsonb_agg(jsonb_build_object(
      'order_pull_job_id', order_pull_job_id,
      'marketplace', marketplace,
      'window_label', window_label,
      'payload', payload
    )), '[]'::jsonb)
  into v_inserted, v_reactivated, v_jobs
  from upserted;

  return jsonb_build_object(
    'ok', true,
    'version', 'marketplace_requeue_cancelled_order_windows_90d_v1',
    'inserted_jobs', v_inserted,
    'reactivated_jobs', v_reactivated,
    'jobs', v_jobs
  );
end;
$$;

create or replace function public.marketplace_requeue_cancelled_order_windows_90d_cron_v1()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.marketplace_requeue_cancelled_order_windows_90d_v1(3);
end;
$$;

create or replace function public.marketplace_backfill_order_notes_from_raw_90d_v1(
  p_limit integer default 500
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated integer := 0;
begin
  with candidates as (
    select
      o.marketplace_order_id,
      public.marketplace_extract_order_note(o.note, o.raw_order) as extracted_note
    from public.marketplace_orders o
    where coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) >= now() - interval '90 days'
      and nullif(trim(coalesce(o.note, '')), '') is null
      and o.raw_order is not null
      and nullif(trim(coalesce(public.marketplace_extract_order_note(o.note, o.raw_order), '')), '') is not null
    order by coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) desc
    limit greatest(1, coalesce(p_limit, 500))
  ),
  updated as (
    update public.marketplace_orders o
       set note = c.extracted_note,
           updated_at = now()
      from candidates c
     where o.marketplace_order_id = c.marketplace_order_id
    returning o.marketplace_order_id
  )
  select count(*)::integer into v_updated from updated;

  return jsonb_build_object(
    'ok', true,
    'version', 'marketplace_backfill_order_notes_from_raw_90d_v1',
    'updated_orders', coalesce(v_updated, 0)
  );
end;
$$;

create or replace function public.marketplace_backfill_order_notes_from_raw_90d_cron_v1()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.marketplace_backfill_order_notes_from_raw_90d_v1(500);
end;
$$;

create or replace function public.marketplace_backlog_90d_health_v1()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tenant_id uuid := public.app_current_tenant_id_or_default();
  v_start timestamptz := now() - interval '90 days';
begin
  return jsonb_build_object(
    'ok', true,
    'version', 'marketplace_backlog_90d_health_v1',
    'generated_at_wib', to_char(timezone('Asia/Jakarta', now()), 'YYYY-MM-DD HH24:MI:SS'),
    'tenant_id', v_tenant_id,
    'cron_jobs', coalesce((
      select jsonb_agg(jsonb_build_object(
        'jobname', j.jobname,
        'schedule', j.schedule,
        'active', j.active
      ) order by j.jobname)
      from cron.job j
      where j.jobname in (
        'marketplace-auto-runner-every-2-min',
        'marketplace-status-refresh-every-10-min',
        'marketplace-finance-pull-every-5-min',
        'marketplace-finance-backlog-missing-payout-90d-v1',
        'marketplace-order-status-backlog-90d-v1',
        'marketplace-cancelled-order-window-backlog-90d-v1',
        'marketplace-order-note-backfill-90d-v1'
      )
    ), '[]'::jsonb),
    'cron_failures_12h', coalesce((
      select jsonb_agg(jsonb_build_object(
        'jobname', x.jobname,
        'failed_runs', x.failed_runs,
        'last_failed_at_wib', x.last_failed_at_wib,
        'last_message', x.last_message
      ) order by x.jobname)
      from (
        select
          j.jobname,
          count(*)::integer as failed_runs,
          to_char(timezone('Asia/Jakarta', max(d.start_time)), 'YYYY-MM-DD HH24:MI:SS') as last_failed_at_wib,
          left(max(d.return_message), 220) as last_message
        from cron.job_run_details d
        join cron.job j on j.jobid = d.jobid
        where j.jobname ilike '%marketplace%'
          and d.start_time > now() - interval '12 hours'
          and d.status <> 'succeeded'
        group by j.jobname
      ) x
    ), '[]'::jsonb),
    'order_job_counts_90d', coalesce((
      select jsonb_agg(jsonb_build_object(
        'job_type', job_type,
        'status', status,
        'count_jobs', count_jobs,
        'oldest_created_wib', oldest_created_wib,
        'newest_updated_wib', newest_updated_wib
      ) order by job_type, status)
      from (
        select
          j.job_type,
          lower(coalesce(j.status, '')) as status,
          count(*)::integer as count_jobs,
          to_char(timezone('Asia/Jakarta', min(j.created_at)), 'YYYY-MM-DD HH24:MI:SS') as oldest_created_wib,
          to_char(timezone('Asia/Jakarta', max(j.updated_at)), 'YYYY-MM-DD HH24:MI:SS') as newest_updated_wib
        from public.marketplace_order_pull_jobs j
        where j.tenant_id = v_tenant_id
          and j.created_at >= v_start
        group by 1, 2
      ) s
    ), '[]'::jsonb),
    'finance_job_counts_90d', coalesce((
      select jsonb_agg(jsonb_build_object(
        'job_type', job_type,
        'status', status,
        'count_jobs', count_jobs,
        'oldest_created_wib', oldest_created_wib,
        'newest_updated_wib', newest_updated_wib
      ) order by job_type, status)
      from (
        select
          j.job_type,
          lower(coalesce(j.status, '')) as status,
          count(*)::integer as count_jobs,
          to_char(timezone('Asia/Jakarta', min(j.created_at)), 'YYYY-MM-DD HH24:MI:SS') as oldest_created_wib,
          to_char(timezone('Asia/Jakarta', max(j.updated_at)), 'YYYY-MM-DD HH24:MI:SS') as newest_updated_wib
        from public.finance_sync_jobs j
        where j.tenant_id = v_tenant_id
          and j.created_at >= v_start
        group by 1, 2
      ) s
    ), '[]'::jsonb),
    'stale_or_pending_order_jobs', coalesce((
      select jsonb_build_object(
        'pending_retry', count(*) filter (where lower(coalesce(status, '')) in ('pending', 'retry')),
        'running_stale', count(*) filter (
          where lower(coalesce(status, '')) = 'running'
            and coalesce(locked_at, last_run_at, updated_at, created_at) < now() - interval '20 minutes'
        ),
        'failed', count(*) filter (where lower(coalesce(status, '')) = 'failed')
      )
      from public.marketplace_order_pull_jobs
      where tenant_id = v_tenant_id
        and created_at >= v_start
    ), '{}'::jsonb),
    'cancelled_auto_windows_without_rescue_90d', coalesce((
      select count(*)::integer
      from public.marketplace_order_pull_jobs j
      where j.tenant_id = v_tenant_id
        and lower(coalesce(j.status, '')) in ('cancelled', 'canceled', 'failed')
        and j.job_type in ('auto_recent', 'auto_recent_free_plan', 'auto_today_window', 'auto_yesterday_window')
        and j.created_at >= v_start
        and not exists (
          select 1
          from public.marketplace_order_pull_jobs existing
          where existing.tenant_id = j.tenant_id
            and existing.marketplace_account_id = j.marketplace_account_id
            and existing.marketplace = j.marketplace
            and existing.job_type = 'cancelled_order_window_backlog_90d_v1'
            and existing.window_start_seconds = j.window_start_seconds
            and existing.window_end_seconds = j.window_end_seconds
            and lower(coalesce(existing.status, '')) in ('pending', 'running', 'retry', 'done', 'success', 'completed')
        )
    ), 0),
    'missing_finance_orders_90d', coalesce((
      select count(*)::integer
      from public.marketplace_orders o
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
      where o.tenant_id = v_tenant_id
        and coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) >= v_start
        and upper(coalesce(o.order_status, o.status, o.raw_order->>'status', '')) not in ('CANCELLED', 'CANCELED', 'UNPAID', 'RETURNED', 'REFUNDED', 'FAILED', 'CLOSED')
        and fr.marketplace_order_id is null
        and fr.order_id is null
    ), 0),
    'orders_missing_persisted_note_90d', coalesce((
      select count(*)::integer
      from public.marketplace_orders o
      where o.tenant_id = v_tenant_id
        and coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) >= v_start
        and nullif(trim(coalesce(o.note, '')), '') is null
        and o.raw_order is not null
        and nullif(trim(coalesce(public.marketplace_extract_order_note(o.note, o.raw_order), '')), '') is not null
    ), 0)
  );
end;
$$;

revoke execute on function public.marketplace_requeue_cancelled_order_windows_90d_v1(integer) from public, anon, authenticated;
revoke execute on function public.marketplace_requeue_cancelled_order_windows_90d_cron_v1() from public, anon, authenticated;
revoke execute on function public.marketplace_backfill_order_notes_from_raw_90d_v1(integer) from public, anon, authenticated;
revoke execute on function public.marketplace_backfill_order_notes_from_raw_90d_cron_v1() from public, anon, authenticated;
grant execute on function public.marketplace_requeue_cancelled_order_windows_90d_v1(integer) to service_role;
grant execute on function public.marketplace_requeue_cancelled_order_windows_90d_cron_v1() to service_role;
grant execute on function public.marketplace_backfill_order_notes_from_raw_90d_v1(integer) to service_role;
grant execute on function public.marketplace_backfill_order_notes_from_raw_90d_cron_v1() to service_role;

grant execute on function public.marketplace_backlog_90d_health_v1() to authenticated;
revoke execute on function public.marketplace_backlog_90d_health_v1() from anon;

comment on function public.marketplace_order_status_backlog_90d_queue_v1(integer) is
'Queues/requeues stale 90-day TikTok status backlog windows without failing on existing unique windows.';

comment on function public.marketplace_requeue_cancelled_order_windows_90d_v1(integer) is
'Lightweight rescue queue for cancelled/failed automatic order windows in the last 90 days.';

comment on function public.marketplace_backfill_order_notes_from_raw_90d_v1(integer) is
'Backfills marketplace_orders.note from raw marketplace seller/order notes for the last 90 days.';

comment on function public.marketplace_backlog_90d_health_v1() is
'Tenant-scoped health snapshot for 90-day marketplace order, note, finance, payout, and backlog automation.';

do $$
begin
  begin
    perform public.marketplace_backfill_order_notes_from_raw_90d_v1(1000);
  exception when others then
    raise notice 'Skip immediate order-note backfill: %', sqlerrm;
  end;

  if to_regprocedure('cron.unschedule(text)') is not null then
    begin perform cron.unschedule('marketplace-order-status-backlog-90d-v1'); exception when others then null; end;
    begin perform cron.unschedule('marketplace-cancelled-order-window-backlog-90d-v1'); exception when others then null; end;
    begin perform cron.unschedule('marketplace-order-note-backfill-90d-v1'); exception when others then null; end;
  end if;

  perform cron.schedule(
    'marketplace-order-status-backlog-90d-v1',
    '*/10 * * * *',
    'select public.marketplace_order_status_backlog_90d_cron_v1();'
  );

  perform cron.schedule(
    'marketplace-cancelled-order-window-backlog-90d-v1',
    '7-59/10 * * * *',
    'select public.marketplace_requeue_cancelled_order_windows_90d_cron_v1();'
  );

  perform cron.schedule(
    'marketplace-order-note-backfill-90d-v1',
    '8-59/15 * * * *',
    'select public.marketplace_backfill_order_notes_from_raw_90d_cron_v1();'
  );
exception when others then
  raise notice 'Skip marketplace backlog cron schedule patch: %', sqlerrm;
end $$;
