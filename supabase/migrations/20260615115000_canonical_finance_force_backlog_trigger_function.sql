-- 9I-K canonical finance force backlog trigger function.
-- Repoints finance_sync_jobs trigger from finance_force_auto_today_yesterday_to_missing_backlog_v1()
-- to finance_force_auto_today_yesterday_to_missing_backlog().
-- Old *_v1 function is intentionally kept; no DROP FUNCTION here.
-- Logic is preserved. Only payload source metadata is canonicalized.

create or replace function public.finance_force_auto_today_yesterday_to_missing_backlog()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if new.marketplace = 'tiktok_shop'
     and new.job_type in ('auto_today', 'auto_yesterday')
     and coalesce(new.payload, '{}'::jsonb)->>'mode' = 'today_yesterday'
  then
    new.job_type := 'auto_unpaid_backlog_90d';
    new.period_end := current_date;
    new.period_start := current_date - 90;
    new.priority := greatest(coalesce(new.priority, 0), 90);
    new.next_run_at := coalesce(new.next_run_at, now());
    new.payload := coalesce(new.payload, '{}'::jsonb)
      || jsonb_build_object(
        'mode', 'recent_unpaid',
        'source', 'finance_force_auto_today_yesterday_to_missing_backlog',
        'days_back', 90,
        'unpaid_backlog_days', 90,
        'job_type_hint', 'auto_unpaid_backlog_90d',
        'missing_only', true,
        'include_unpaid_backlog', true,
        'auto_unpaid_backlog_90d', true,
        'include_pending_payout', true,
        'include_all_missing_payout', true,
        'skip_settled_with_payout', true,
        'include_sku_details', true,
        'max_orders', 20,
        'max_batches_per_job', 3,
        'forced_from_job_type', new.job_type,
        'forced_at', now()
      );
  end if;

  return new;
end;
$function$;

do $$
declare
  v_def text;
begin
  select pg_get_triggerdef(t.oid, true)
    into v_def
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname = 'finance_sync_jobs'
    and t.tgname = 'trg_finance_force_auto_today_yesterday_to_missing_backlog_v1'
    and not t.tgisinternal;

  if v_def is null then
    raise exception 'Old trigger not found: trg_finance_force_auto_today_yesterday_to_missing_backlog_v1';
  end if;

  execute 'drop trigger if exists trg_finance_force_auto_today_yesterday_to_missing_backlog_v1 on public.finance_sync_jobs';

  v_def := replace(
    v_def,
    'CREATE TRIGGER trg_finance_force_auto_today_yesterday_to_missing_backlog_v1',
    'CREATE TRIGGER trg_finance_force_auto_today_yesterday_to_missing_backlog'
  );

  v_def := replace(
    v_def,
    'EXECUTE FUNCTION finance_force_auto_today_yesterday_to_missing_backlog_v1()',
    'EXECUTE FUNCTION public.finance_force_auto_today_yesterday_to_missing_backlog()'
  );

  v_def := replace(
    v_def,
    'EXECUTE FUNCTION public.finance_force_auto_today_yesterday_to_missing_backlog_v1()',
    'EXECUTE FUNCTION public.finance_force_auto_today_yesterday_to_missing_backlog()'
  );

  execute v_def;
end $$;

notify pgrst, 'reload schema';
