-- 9I-F canonical marketplace order pull job epoch guard.
-- Creates canonical helper + trigger function, then repoints trigger.
-- Old _v24_6_88 functions are intentionally kept; no DROP FUNCTION here.

create or replace function public.marketplace_fix_epoch_seconds(p_seconds bigint)
returns bigint
language plpgsql
stable
as $function$
declare
  v_now_sec bigint := extract(epoch from now())::bigint;
  v_candidate bigint;
  v_candidate_ts timestamptz;
begin
  if p_seconds is null then
    return null;
  end if;

  -- Milliseconds guard, just in case a caller sends ms instead of seconds.
  if p_seconds > 100000000000 then
    v_candidate := floor(p_seconds / 1000.0)::bigint;

    if to_timestamp(v_candidate) between now() - interval '30 days' and now() + interval '2 days' then
      return v_candidate;
    end if;
  end if;

  -- Main bug: 2026 epoch + 2026 epoch = 2082 epoch.
  -- If subtracting current epoch returns a sane recent timestamp, keep the corrected value.
  if p_seconds > v_now_sec + 86400 then
    v_candidate := p_seconds - v_now_sec;
    v_candidate_ts := to_timestamp(v_candidate);

    if v_candidate_ts between now() - interval '30 days' and now() + interval '2 days' then
      return v_candidate;
    end if;
  end if;

  return p_seconds;
exception when others then
  return p_seconds;
end;
$function$;

create or replace function public.marketplace_order_pull_jobs_epoch_guard()
returns trigger
language plpgsql
as $function$
begin
  new.window_start_seconds := public.marketplace_fix_epoch_seconds(new.window_start_seconds);
  new.window_end_seconds := public.marketplace_fix_epoch_seconds(new.window_end_seconds);

  if new.window_start_seconds is not null
     and new.window_end_seconds is not null
     and new.window_end_seconds <= new.window_start_seconds then
    new.window_end_seconds := new.window_start_seconds + 1800;
  end if;

  if new.status = 'pending'
     and (new.next_run_at is null or new.next_run_at > now() + interval '5 minutes') then
    new.next_run_at := now();
  end if;

  new.updated_at := coalesce(new.updated_at, now());
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
    and c.relname = 'marketplace_order_pull_jobs'
    and t.tgname = 'trg_marketplace_order_pull_jobs_epoch_guard_v24_6_88'
    and not t.tgisinternal;

  if v_def is null then
    raise exception 'Old trigger not found: trg_marketplace_order_pull_jobs_epoch_guard_v24_6_88';
  end if;

  execute 'drop trigger if exists trg_marketplace_order_pull_jobs_epoch_guard_v24_6_88 on public.marketplace_order_pull_jobs';

  v_def := replace(
    v_def,
    'CREATE TRIGGER trg_marketplace_order_pull_jobs_epoch_guard_v24_6_88',
    'CREATE TRIGGER trg_marketplace_order_pull_jobs_epoch_guard'
  );

  v_def := replace(
    v_def,
    'EXECUTE FUNCTION _marketplace_order_pull_jobs_epoch_guard_v24_6_88()',
    'EXECUTE FUNCTION public.marketplace_order_pull_jobs_epoch_guard()'
  );

  v_def := replace(
    v_def,
    'EXECUTE FUNCTION public._marketplace_order_pull_jobs_epoch_guard_v24_6_88()',
    'EXECUTE FUNCTION public.marketplace_order_pull_jobs_epoch_guard()'
  );

  execute v_def;
end $$;

notify pgrst, 'reload schema';
