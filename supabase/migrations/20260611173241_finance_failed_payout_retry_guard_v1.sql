create or replace function public.marketplace_requeue_failed_finance_jobs_90d_v1(
  p_max_jobs integer default 2
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_requeued integer := 0;
  v_jobs jsonb := '[]'::jsonb;
begin
  with candidates as (
    select
      j.finance_sync_job_id,
      j.job_type,
      j.marketplace,
      j.marketplace_account_id,
      j.period_start,
      j.period_end,
      j.priority,
      j.attempts,
      j.last_message,
      case
        when coalesce(j.last_result->>'failed', '') ~ '^[0-9]+$'
          then (j.last_result->>'failed')::integer
        else 0
      end as failed_count,
      row_number() over (
        partition by j.marketplace_account_id, j.job_type, j.period_start, j.period_end
        order by
          case
            when j.last_result::text ilike '%too many requests%' then 0
            when coalesce(j.last_result->>'failed', '') ~ '^[0-9]+$' and (j.last_result->>'failed')::integer > 0 then 1
            else 2
          end,
          j.updated_at asc
      ) as rn
    from public.finance_sync_jobs j
    join public.marketplace_accounts ma
      on ma.tenant_id = j.tenant_id
     and ma.marketplace_account_id = j.marketplace_account_id
    where j.created_at >= now() - interval '90 days'
      and coalesce(ma.is_active, true) = true
      and coalesce(ma.environment, 'production') = 'production'
      and lower(coalesce(j.status, '')) in ('done', 'success', 'completed', 'failed', 'error')
      and coalesce(j.updated_at, j.created_at) < now() - interval '20 minutes'
      and coalesce(j.attempts, 0) < 5
      and (
        (
          coalesce(j.last_result->>'failed', '') ~ '^[0-9]+$'
          and (j.last_result->>'failed')::integer > 0
        )
        or j.last_result::text ilike '%too many requests%'
        or j.last_result::text ilike '%rate limit%'
        or j.last_result::text ilike '%36009002%'
        or lower(coalesce(j.last_message, '')) like '%gagal%'
      )
    order by
      case when j.last_result::text ilike '%too many requests%' then 0 else 1 end,
      j.updated_at asc
    limit greatest(1, coalesce(p_max_jobs, 2))
  ),
  updated as (
    update public.finance_sync_jobs j
       set status = 'retry',
           priority = greatest(coalesce(j.priority, 0), 92),
           attempts = coalesce(j.attempts, 0) + 1,
           next_run_at = now() + make_interval(mins => 12 + least(coalesce(j.attempts, 0), 4) * 8),
           locked_at = null,
           last_run_at = null,
           finished_at = null,
           last_message = 'Retry payout otomatis dijadwalkan ulang pelan karena sebagian finance pull gagal/rate-limit.',
           payload = coalesce(j.payload, '{}'::jsonb)
             || jsonb_build_object(
               'source', 'marketplace_requeue_failed_finance_jobs_90d_v1',
               'retry_failed_finance_only', true,
               'missing_only', true,
               'include_pending_payout', true,
               'include_all_missing_payout', true,
               'skip_settled_with_payout', true,
               'max_orders', 15,
               'max_batches_per_job', 1,
               'requeued_failed_finance_at', now()
             ),
           updated_at = now()
      from candidates c
     where j.finance_sync_job_id = c.finance_sync_job_id
       and c.rn = 1
    returning
      j.finance_sync_job_id,
      j.job_type,
      j.marketplace,
      j.marketplace_account_id,
      j.period_start,
      j.period_end,
      j.status,
      j.priority,
      j.attempts,
      j.next_run_at
  )
  select
    count(*)::integer,
    coalesce(jsonb_agg(jsonb_build_object(
      'finance_sync_job_id', finance_sync_job_id,
      'job_type', job_type,
      'marketplace', marketplace,
      'marketplace_account_id', marketplace_account_id,
      'period_start', period_start,
      'period_end', period_end,
      'status', status,
      'priority', priority,
      'attempts', attempts,
      'next_run_at_wib', to_char(timezone('Asia/Jakarta', next_run_at), 'YYYY-MM-DD HH24:MI:SS')
    )), '[]'::jsonb)
  into v_requeued, v_jobs
  from updated;

  return jsonb_build_object(
    'ok', true,
    'version', 'marketplace_requeue_failed_finance_jobs_90d_v1',
    'requeued_jobs', coalesce(v_requeued, 0),
    'jobs', coalesce(v_jobs, '[]'::jsonb)
  );
end;
$$;

create or replace function public.marketplace_requeue_failed_finance_jobs_90d_cron_v1()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.marketplace_requeue_failed_finance_jobs_90d_v1(2);
end;
$$;

create or replace function public.marketplace_failed_finance_jobs_90d_health_v1()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tenant_id uuid := public.app_current_tenant_id_or_default();
begin
  return jsonb_build_object(
    'ok', true,
    'version', 'marketplace_failed_finance_jobs_90d_health_v1',
    'generated_at_wib', to_char(timezone('Asia/Jakarta', now()), 'YYYY-MM-DD HH24:MI:SS'),
    'done_with_embedded_failures', coalesce((
      select count(*)::integer
      from public.finance_sync_jobs j
      where j.tenant_id = v_tenant_id
        and j.created_at >= now() - interval '90 days'
        and lower(coalesce(j.status, '')) in ('done', 'success', 'completed')
        and (
          (
            coalesce(j.last_result->>'failed', '') ~ '^[0-9]+$'
            and (j.last_result->>'failed')::integer > 0
          )
          or j.last_result::text ilike '%too many requests%'
          or j.last_result::text ilike '%rate limit%'
          or j.last_result::text ilike '%36009002%'
        )
    ), 0),
    'pending_retry', coalesce((
      select count(*)::integer
      from public.finance_sync_jobs j
      where j.tenant_id = v_tenant_id
        and j.created_at >= now() - interval '90 days'
        and lower(coalesce(j.status, '')) in ('pending', 'retry')
    ), 0),
    'running_stale', coalesce((
      select count(*)::integer
      from public.finance_sync_jobs j
      where j.tenant_id = v_tenant_id
        and j.created_at >= now() - interval '90 days'
        and lower(coalesce(j.status, '')) = 'running'
        and coalesce(j.locked_at, j.last_run_at, j.updated_at, j.created_at) < now() - interval '20 minutes'
    ), 0),
    'recent_problem_jobs', coalesce((
      select jsonb_agg(jsonb_build_object(
        'finance_sync_job_id', x.finance_sync_job_id,
        'job_type', x.job_type,
        'status', x.status,
        'attempts', x.attempts,
        'period_start', x.period_start,
        'period_end', x.period_end,
        'failed_count', x.failed_count,
        'updated_at_wib', x.updated_at_wib,
        'message', x.message
      ) order by x.updated_at desc)
      from (
        select
          j.finance_sync_job_id,
          j.job_type,
          j.status,
          j.attempts,
          j.period_start,
          j.period_end,
          j.updated_at,
          to_char(timezone('Asia/Jakarta', j.updated_at), 'YYYY-MM-DD HH24:MI:SS') as updated_at_wib,
          case
            when coalesce(j.last_result->>'failed', '') ~ '^[0-9]+$'
              then (j.last_result->>'failed')::integer
            else 0
          end as failed_count,
          left(coalesce(j.last_message, j.last_result->>'message', ''), 180) as message
        from public.finance_sync_jobs j
        where j.tenant_id = v_tenant_id
          and j.created_at >= now() - interval '90 days'
          and (
            lower(coalesce(j.status, '')) in ('pending', 'retry', 'failed', 'error')
            or (
              lower(coalesce(j.status, '')) in ('done', 'success', 'completed')
              and (
                (
                  coalesce(j.last_result->>'failed', '') ~ '^[0-9]+$'
                  and (j.last_result->>'failed')::integer > 0
                )
                or j.last_result::text ilike '%too many requests%'
                or j.last_result::text ilike '%rate limit%'
                or j.last_result::text ilike '%36009002%'
              )
            )
          )
        order by j.updated_at desc
        limit 12
      ) x
    ), '[]'::jsonb)
  );
end;
$$;

revoke execute on function public.marketplace_requeue_failed_finance_jobs_90d_v1(integer) from public, anon, authenticated;
revoke execute on function public.marketplace_requeue_failed_finance_jobs_90d_cron_v1() from public, anon, authenticated;
grant execute on function public.marketplace_requeue_failed_finance_jobs_90d_v1(integer) to service_role;
grant execute on function public.marketplace_requeue_failed_finance_jobs_90d_cron_v1() to service_role;

grant execute on function public.marketplace_failed_finance_jobs_90d_health_v1() to authenticated;
revoke execute on function public.marketplace_failed_finance_jobs_90d_health_v1() from anon;

comment on function public.marketplace_requeue_failed_finance_jobs_90d_v1(integer) is
'Lightweight retry guard for finance/payout jobs that finished with embedded per-order failures, commonly TikTok rate limits.';

comment on function public.marketplace_failed_finance_jobs_90d_health_v1() is
'Tenant-scoped monitor for finance/payout jobs that still need retry after embedded API failures.';

do $$
begin
  if to_regprocedure('cron.unschedule(text)') is not null then
    begin perform cron.unschedule('marketplace-finance-failed-payout-retry-90d-v1'); exception when others then null; end;
  end if;

  perform cron.schedule(
    'marketplace-finance-failed-payout-retry-90d-v1',
    '11-59/20 * * * *',
    'select public.marketplace_requeue_failed_finance_jobs_90d_cron_v1();'
  );
exception when others then
  raise notice 'Skip failed finance retry cron schedule: %', sqlerrm;
end $$;
