create or replace function public.marketplace_finance_backlog_missing_payout_90d_v1()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job record;
  v_req bigint;
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  v_start date := greatest(date '2026-03-13', v_today - 89);
  v_end date := v_today - 2;
  v_body jsonb;
  v_results jsonb := '[]'::jsonb;
begin
  select jobid, command
    into v_job
  from cron.job
  where active = true
    and command ilike '%marketplace-finance-pull%'
    and command ilike '%x-marketplace-cron-secret%'
  order by jobid desc
  limit 1;

  if v_job.command is null then
    return jsonb_build_object(
      'ok', false,
      'version', 'finance_backlog_missing_payout_90d_cron_v1',
      'message', 'Active marketplace-finance-pull cron command with cron secret was not found.'
    );
  end if;

  v_body := jsonb_build_object(
    'mode', 'period',
    'period_mode', 'backlog_missing_payout_90d',
    'start_date', to_char(v_start, 'YYYY-MM-DD'),
    'end_date', to_char(v_end, 'YYYY-MM-DD'),
    'enqueue', true,
    'force_requeue', false,
    'missing_only', true,
    'include_sku_details', true,
    'include_pending_payout', true,
    'include_all_missing_payout', true,
    'skip_settled_with_payout', true,
    'exclude_cancelled_unpaid', true,
    'max_jobs', 2,
    'max_accounts', 1,
    'max_orders', 25,
    'max_batches_per_job', 3,
    'max_statements', 4,
    'max_transactions', 60,
    'max_order_details', 60,
    'source', 'pg_cron_finance_backlog_missing_payout_90d_v1'
  );

  execute replace(
    v_job.command,
    regexp_replace(v_job.command, '(?is).*body\s*:=\s*(''[^'']*''::jsonb).*', '\1'),
    quote_literal(v_body::text) || '::jsonb'
  ) into v_req;

  v_results := v_results || jsonb_build_array(jsonb_build_object(
    'request_id', v_req,
    'start_date', v_start,
    'end_date', v_end,
    'body_mode', v_body->>'mode',
    'period_mode', v_body->>'period_mode',
    'max_jobs', v_body->>'max_jobs',
    'max_orders', v_body->>'max_orders'
  ));

  return jsonb_build_object(
    'ok', true,
    'version', 'finance_backlog_missing_payout_90d_cron_v1',
    'message', 'Finance backlog missing payout 90d request queued via existing marketplace-finance-pull cron command.',
    'results', v_results
  );
exception when others then
  return jsonb_build_object(
    'ok', false,
    'version', 'finance_backlog_missing_payout_90d_cron_v1',
    'message', sqlerrm
  );
end;
$$;

do $$
begin
  if to_regprocedure('cron.unschedule(text)') is not null then
    begin perform cron.unschedule('marketplace-finance-backlog-missing-payout-90d-v1'); exception when others then null; end;
  end if;

  perform cron.schedule(
    'marketplace-finance-backlog-missing-payout-90d-v1',
    '*/10 * * * *',
    'select public.marketplace_finance_backlog_missing_payout_90d_v1();'
  );
exception when others then
  raise notice 'Skip schedule finance backlog cron: %', sqlerrm;
end $$;
