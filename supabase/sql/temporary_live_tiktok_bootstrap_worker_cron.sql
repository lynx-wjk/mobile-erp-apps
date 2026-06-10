-- temporary_live_tiktok_bootstrap_worker_cron.sql
-- TEMPORARY LIVE HOTFIX ONLY.
-- Do NOT use this as generic real-client migration because tenant/account are internal test values.
-- Purpose: drain TikTok internal bootstrap retry queue safely with single-flight worker.

create or replace function public.invoke_tiktok_bootstrap_worker_once_v1()
returns bigint
language plpgsql
security definer
set search_path = public, cron, net
as $$
declare
  v_secret text;
  v_request_id bigint;
  v_running integer;
  v_pending integer;
  v_job_id uuid;
begin
  update public.marketplace_order_pull_jobs
  set status='retry', locked_at=null, finished_at=null, next_run_at=now(),
      last_message='Auto reset stale running into retry before isolated helper invoke.', updated_at=now()
  where job_type='bootstrap_90d_adaptive_v1'
    and marketplace='tiktok_shop'
    and status='running'
    and coalesce(locked_at, updated_at) < now() - interval '3 minutes';

  update public.marketplace_order_pull_jobs j
  set status='retry', locked_at=null, finished_at=null, next_run_at=now(),
      last_message='Auto requeued page-limit risk into retry before isolated helper invoke.', updated_at=now()
  from public.marketplace_bootstrap_page_limit_audit_v1 r
  where r.order_pull_job_id = j.order_pull_job_id
    and r.likely_page_limit_risk = true
    and j.marketplace='tiktok_shop'
    and j.job_type='bootstrap_90d_adaptive_v1'
    and j.status='done';

  select count(*)::integer into v_running
  from public.marketplace_order_pull_jobs
  where job_type='bootstrap_90d_adaptive_v1'
    and marketplace='tiktok_shop'
    and status='running';

  if coalesce(v_running,0) > 0 then
    return null;
  end if;

  select count(*)::integer into v_pending
  from public.marketplace_order_pull_jobs
  where job_type='bootstrap_90d_adaptive_v1'
    and marketplace='tiktok_shop'
    and status='pending';

  if coalesce(v_pending,0) = 0 then
    select order_pull_job_id into v_job_id
    from public.marketplace_order_pull_jobs
    where job_type='bootstrap_90d_adaptive_v1'
      and marketplace='tiktok_shop'
      and status='retry'
    order by priority desc, next_run_at asc, period_start desc
    limit 1;

    if v_job_id is null then
      return null;
    end if;

    update public.marketplace_order_pull_jobs
    set status='pending', next_run_at=now(), locked_at=null, finished_at=null,
        last_message='Promoted from retry to pending for isolated bootstrap helper.', updated_at=now()
    where order_pull_job_id = v_job_id;
  end if;

  select substring(command from '''x-marketplace-cron-secret''\s*,\s*''([^'']+)''') into v_secret
  from cron.job
  where jobname='marketplace-auto-runner-every-2-min'
  limit 1;

  if nullif(v_secret,'') is null then
    raise exception 'marketplace cron secret not found';
  end if;

  select net.http_post(
    url := 'https://tllknfqoczarogizheal.supabase.co/functions/v1/marketplace-bootstrap-order-worker',
    headers := jsonb_build_object('Content-Type','application/json','x-marketplace-cron-secret',v_secret),
    body := jsonb_build_object(
      'tenant_id','ae730499-550b-4907-bb18-bbc2629c64f4',
      'marketplace_account_id','e21c4302-79d7-4abd-9b99-9dc23cb240eb',
      'requeue_page_limit_risk',false,
      'max_jobs',1,
      'page_size',50,
      'max_pages',5
    ),
    timeout_milliseconds := 180000
  ) into v_request_id;

  return v_request_id;
end;
$$;

select cron.unschedule('marketplace-bootstrap-order-worker-every-1-min')
where exists (select 1 from cron.job where jobname = 'marketplace-bootstrap-order-worker-every-1-min');

select cron.schedule(
  'marketplace-bootstrap-order-worker-every-1-min',
  '* * * * *',
  'select public.invoke_tiktok_bootstrap_worker_once_v1();'
);

-- To stop after retry/pending/running all reach 0:
-- select cron.unschedule('marketplace-bootstrap-order-worker-every-1-min');
