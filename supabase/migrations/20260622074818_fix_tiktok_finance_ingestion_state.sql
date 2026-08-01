-- Route TikTok finance through the finance dispatcher instead of treating it as
-- unsupported, and prevent zero-row export/connect guards from being recorded
-- as successful finance syncs.

begin;

create extension if not exists pgcrypto;

create or replace function public.marketplace_connect_ensure_sync_states()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now_epoch bigint := extract(epoch from now())::bigint;
  v_today date := current_date;
  v_finance_pending_reason text := 'income_export_pending_connect_guard: finance sync pending; no marketplace finance rows synced yet.';
begin
  if new.status = 'active' and new.deleted_at is null then
    if to_regclass('public.marketplace_order_sync_state') is not null then
      insert into public.marketplace_order_sync_state (
        tenant_id,
        marketplace_account_id,
        marketplace,
        bootstrap_status,
        bootstrap_from_seconds,
        bootstrap_to_seconds,
        bootstrap_cursor_seconds,
        bootstrap_started_at,
        bootstrap_completed_at,
        recent_cursor_seconds,
        recent_caught_up_at,
        last_success_window_start_seconds,
        last_success_window_end_seconds,
        last_success_at,
        last_mode,
        last_error,
        failure_count,
        lock_token,
        locked_until,
        next_run_at,
        created_at,
        updated_at
      )
      select
        new.tenant_id,
        new.marketplace_account_id,
        new.marketplace,
        'done',
        v_now_epoch,
        v_now_epoch,
        v_now_epoch,
        now(),
        now(),
        v_now_epoch,
        now(),
        v_now_epoch,
        v_now_epoch,
        now(),
        'export_import_pending_connect_guard',
        null,
        0,
        null,
        null,
        now(),
        now(),
        now()
      where not exists (
        select 1
        from public.marketplace_order_sync_state s
        where s.marketplace_account_id = new.marketplace_account_id
      );

      update public.marketplace_order_sync_state
      set
        tenant_id = new.tenant_id,
        marketplace = new.marketplace,
        bootstrap_status = 'done',
        bootstrap_from_seconds = coalesce(bootstrap_from_seconds, v_now_epoch),
        bootstrap_to_seconds = v_now_epoch,
        bootstrap_cursor_seconds = v_now_epoch,
        bootstrap_started_at = coalesce(bootstrap_started_at, now()),
        bootstrap_completed_at = now(),
        recent_cursor_seconds = v_now_epoch,
        recent_caught_up_at = now(),
        last_success_window_start_seconds = v_now_epoch,
        last_success_window_end_seconds = v_now_epoch,
        last_success_at = now(),
        last_mode = 'export_import_pending_connect_guard',
        last_error = null,
        failure_count = 0,
        lock_token = null,
        locked_until = null,
        next_run_at = now(),
        updated_at = now()
      where marketplace_account_id = new.marketplace_account_id;
    end if;

    if to_regclass('public.marketplace_finance_sync_state') is not null then
      insert into public.marketplace_finance_sync_state (
        tenant_id,
        marketplace_account_id,
        marketplace,
        finance_status,
        bootstrap_from_date,
        bootstrap_to_date,
        bootstrap_cursor_date,
        bootstrap_started_at,
        bootstrap_completed_at,
        recent_cursor_date,
        recent_caught_up_at,
        last_success_period_start,
        last_success_period_end,
        last_success_at,
        last_mode,
        last_error,
        failure_count,
        checked_total,
        synced_total,
        failed_total,
        lock_token,
        locked_until,
        next_run_at,
        created_at,
        updated_at
      )
      select
        new.tenant_id,
        new.marketplace_account_id,
        new.marketplace,
        'pending',
        v_today - 90,
        v_today,
        v_today - 90,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        'income_export_pending_connect_guard',
        v_finance_pending_reason,
        0,
        0,
        0,
        0,
        null,
        null,
        now(),
        now(),
        now()
      where not exists (
        select 1
        from public.marketplace_finance_sync_state s
        where s.marketplace_account_id = new.marketplace_account_id
      );

      update public.marketplace_finance_sync_state
      set
        tenant_id = new.tenant_id,
        marketplace = new.marketplace,
        finance_status = case
          when coalesce(synced_total, 0) = 0
            and (
              coalesce(last_mode, '') = 'income_export_pending_connect_guard'
              or finance_status = 'unsupported'
            )
            then 'pending'
          else finance_status
        end,
        bootstrap_from_date = coalesce(bootstrap_from_date, v_today - 90),
        bootstrap_to_date = greatest(coalesce(bootstrap_to_date, v_today), v_today),
        bootstrap_cursor_date = case
          when coalesce(synced_total, 0) = 0
            and (
              coalesce(last_mode, '') = 'income_export_pending_connect_guard'
              or finance_status = 'unsupported'
            )
            then coalesce(bootstrap_cursor_date, bootstrap_from_date, v_today - 90)
          else bootstrap_cursor_date
        end,
        bootstrap_started_at = case
          when coalesce(synced_total, 0) = 0
            and (
              coalesce(last_mode, '') = 'income_export_pending_connect_guard'
              or finance_status = 'unsupported'
            )
            then null
          else bootstrap_started_at
        end,
        bootstrap_completed_at = case
          when coalesce(synced_total, 0) = 0
            and (
              coalesce(last_mode, '') = 'income_export_pending_connect_guard'
              or finance_status = 'unsupported'
            )
            then null
          else bootstrap_completed_at
        end,
        recent_cursor_date = case
          when coalesce(synced_total, 0) = 0
            and (
              coalesce(last_mode, '') = 'income_export_pending_connect_guard'
              or finance_status = 'unsupported'
            )
            then null
          else recent_cursor_date
        end,
        recent_caught_up_at = case
          when coalesce(synced_total, 0) = 0
            and (
              coalesce(last_mode, '') = 'income_export_pending_connect_guard'
              or finance_status = 'unsupported'
            )
            then null
          else recent_caught_up_at
        end,
        last_success_period_start = case
          when coalesce(synced_total, 0) = 0
            and (
              coalesce(last_mode, '') = 'income_export_pending_connect_guard'
              or finance_status = 'unsupported'
            )
            then null
          else last_success_period_start
        end,
        last_success_period_end = case
          when coalesce(synced_total, 0) = 0
            and (
              coalesce(last_mode, '') = 'income_export_pending_connect_guard'
              or finance_status = 'unsupported'
            )
            then null
          else last_success_period_end
        end,
        last_success_at = case
          when coalesce(synced_total, 0) = 0
            and (
              coalesce(last_mode, '') = 'income_export_pending_connect_guard'
              or finance_status = 'unsupported'
            )
            then null
          else last_success_at
        end,
        last_mode = case
          when coalesce(synced_total, 0) = 0
            and (
              coalesce(last_mode, '') = 'income_export_pending_connect_guard'
              or finance_status = 'unsupported'
            )
            then 'income_export_pending_connect_guard'
          else last_mode
        end,
        last_error = case
          when coalesce(synced_total, 0) = 0
            and (
              coalesce(last_mode, '') = 'income_export_pending_connect_guard'
              or finance_status = 'unsupported'
            )
            then v_finance_pending_reason
          else last_error
        end,
        lock_token = case
          when coalesce(synced_total, 0) = 0
            and (
              coalesce(last_mode, '') = 'income_export_pending_connect_guard'
              or finance_status = 'unsupported'
            )
            then null
          else lock_token
        end,
        locked_until = case
          when coalesce(synced_total, 0) = 0
            and (
              coalesce(last_mode, '') = 'income_export_pending_connect_guard'
              or finance_status = 'unsupported'
            )
            then null
          else locked_until
        end,
        next_run_at = case
          when coalesce(synced_total, 0) = 0
            and (
              coalesce(last_mode, '') = 'income_export_pending_connect_guard'
              or finance_status = 'unsupported'
            )
            then now()
          else coalesce(next_run_at, now())
        end,
        updated_at = now()
      where marketplace_account_id = new.marketplace_account_id;
    end if;
  end if;

  return new;
end;
$$;

create or replace function public.marketplace_finance_sync_claim(
  p_max_accounts integer default 1,
  p_lock_seconds integer default 240,
  p_window_days integer default 3,
  p_bootstrap_days integer default 90,
  p_dry_run boolean default false
)
returns table (
  finance_sync_state_id uuid,
  tenant_id uuid,
  marketplace_account_id uuid,
  marketplace text,
  mode text,
  period_start date,
  period_end date,
  next_cursor_date date,
  lock_token text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := now();
  v_lock text := gen_random_uuid()::text;
  v_limit integer := greatest(1, least(coalesce(p_max_accounts, 1), 10));
  v_lock_seconds integer := greatest(60, least(coalesce(p_lock_seconds, 240), 1800));
  v_window_days integer := greatest(1, least(coalesce(p_window_days, 3), 14));
  v_bootstrap_days integer := greatest(1, least(coalesce(p_bootstrap_days, 90), 90));
  v_finance_pending_reason text := 'income_export_pending_connect_guard: finance sync pending; no marketplace finance rows synced yet.';
begin
  insert into public.marketplace_finance_sync_state (
    tenant_id,
    marketplace_account_id,
    marketplace,
    finance_status,
    bootstrap_from_date,
    bootstrap_to_date,
    bootstrap_cursor_date,
    next_run_at,
    last_mode,
    last_error
  )
  select
    ma.tenant_id,
    ma.marketplace_account_id,
    ma.marketplace,
    'pending',
    current_date - v_bootstrap_days,
    current_date,
    current_date - v_bootstrap_days,
    v_now,
    'income_export_pending_connect_guard',
    v_finance_pending_reason
  from public.marketplace_accounts ma
  where ma.marketplace in ('shopee', 'tiktok_shop')
    and ma.status = 'active'
    and coalesce(ma.is_deleted, false) = false
    and coalesce(ma.is_active, true) = true
  on conflict on constraint marketplace_finance_sync_state_marketplace_account_id_key do update
  set
    tenant_id = excluded.tenant_id,
    marketplace = excluded.marketplace,
    finance_status = case
      when coalesce(public.marketplace_finance_sync_state.synced_total, 0) = 0
        and (
          public.marketplace_finance_sync_state.finance_status = 'unsupported'
          or coalesce(public.marketplace_finance_sync_state.last_mode, '') = 'income_export_pending_connect_guard'
        )
        then 'pending'
      else public.marketplace_finance_sync_state.finance_status
    end,
    bootstrap_from_date = coalesce(public.marketplace_finance_sync_state.bootstrap_from_date, excluded.bootstrap_from_date),
    bootstrap_to_date = greatest(coalesce(public.marketplace_finance_sync_state.bootstrap_to_date, excluded.bootstrap_to_date), excluded.bootstrap_to_date),
    bootstrap_cursor_date = case
      when coalesce(public.marketplace_finance_sync_state.synced_total, 0) = 0
        and (
          public.marketplace_finance_sync_state.finance_status = 'unsupported'
          or coalesce(public.marketplace_finance_sync_state.last_mode, '') = 'income_export_pending_connect_guard'
        )
        then coalesce(public.marketplace_finance_sync_state.bootstrap_cursor_date, excluded.bootstrap_cursor_date)
      else public.marketplace_finance_sync_state.bootstrap_cursor_date
    end,
    last_mode = case
      when coalesce(public.marketplace_finance_sync_state.synced_total, 0) = 0
        and (
          public.marketplace_finance_sync_state.finance_status = 'unsupported'
          or coalesce(public.marketplace_finance_sync_state.last_mode, '') = 'income_export_pending_connect_guard'
        )
        then 'income_export_pending_connect_guard'
      else public.marketplace_finance_sync_state.last_mode
    end,
    last_error = case
      when coalesce(public.marketplace_finance_sync_state.synced_total, 0) = 0
        and (
          public.marketplace_finance_sync_state.finance_status = 'unsupported'
          or coalesce(public.marketplace_finance_sync_state.last_mode, '') = 'income_export_pending_connect_guard'
        )
        then v_finance_pending_reason
      else public.marketplace_finance_sync_state.last_error
    end,
    lock_token = case
      when coalesce(public.marketplace_finance_sync_state.synced_total, 0) = 0
        and (
          public.marketplace_finance_sync_state.finance_status = 'unsupported'
          or coalesce(public.marketplace_finance_sync_state.last_mode, '') = 'income_export_pending_connect_guard'
        )
        then null
      else public.marketplace_finance_sync_state.lock_token
    end,
    locked_until = case
      when coalesce(public.marketplace_finance_sync_state.synced_total, 0) = 0
        and (
          public.marketplace_finance_sync_state.finance_status = 'unsupported'
          or coalesce(public.marketplace_finance_sync_state.last_mode, '') = 'income_export_pending_connect_guard'
        )
        then null
      else public.marketplace_finance_sync_state.locked_until
    end,
    next_run_at = case
      when coalesce(public.marketplace_finance_sync_state.synced_total, 0) = 0
        and (
          public.marketplace_finance_sync_state.finance_status = 'unsupported'
          or coalesce(public.marketplace_finance_sync_state.last_mode, '') = 'income_export_pending_connect_guard'
        )
        then v_now
      else public.marketplace_finance_sync_state.next_run_at
    end,
    updated_at = v_now;

  if p_dry_run then
    return query
    with due as (
      select s.*
      from public.marketplace_finance_sync_state s
      join public.marketplace_accounts ma
        on ma.marketplace_account_id = s.marketplace_account_id
      where s.marketplace in ('shopee', 'tiktok_shop')
        and s.finance_status <> 'blocked'
        and ma.status = 'active'
        and coalesce(ma.is_deleted, false) = false
        and coalesce(ma.is_active, true) = true
        and (s.locked_until is null or s.locked_until < v_now)
        and s.next_run_at <= v_now
      order by s.next_run_at asc, s.last_success_at asc nulls first, s.created_at asc
      limit v_limit
    ),
    base as (
      select
        d.finance_sync_state_id,
        d.tenant_id,
        d.marketplace_account_id,
        d.marketplace,
        case
          when coalesce(d.bootstrap_cursor_date, d.bootstrap_from_date) <= d.bootstrap_to_date then 'backfill_90d'
          when coalesce(d.recent_cursor_date, current_date - 3) < current_date - 3 then 'catchup_gap'
          else 'recent_pull'
        end as mode,
        case
          when coalesce(d.bootstrap_cursor_date, d.bootstrap_from_date) <= d.bootstrap_to_date
            then coalesce(d.bootstrap_cursor_date, d.bootstrap_from_date)
          when coalesce(d.recent_cursor_date, current_date - 3) < current_date - 3
            then coalesce(d.recent_cursor_date + 1, current_date - 3)
          else current_date - 2
        end as period_start,
        d.bootstrap_to_date
      from due d
    ),
    planned as (
      select
        b.*,
        case
          when b.mode = 'backfill_90d' then least(b.period_start + (v_window_days - 1), b.bootstrap_to_date)
          when b.mode = 'catchup_gap' then least(b.period_start + (v_window_days - 1), current_date)
          else current_date
        end as period_end
      from base b
    )
    select
      p.finance_sync_state_id,
      p.tenant_id,
      p.marketplace_account_id,
      p.marketplace,
      p.mode,
      p.period_start,
      p.period_end,
      case
        when p.mode = 'backfill_90d' then p.period_end + 1
        else p.period_end
      end as next_cursor_date,
      v_lock
    from planned p;

    return;
  end if;

  return query
  with due as (
    select s.*
    from public.marketplace_finance_sync_state s
    join public.marketplace_accounts ma
      on ma.marketplace_account_id = s.marketplace_account_id
    where s.marketplace in ('shopee', 'tiktok_shop')
      and s.finance_status <> 'blocked'
      and ma.status = 'active'
      and coalesce(ma.is_deleted, false) = false
      and coalesce(ma.is_active, true) = true
      and (s.locked_until is null or s.locked_until < v_now)
      and s.next_run_at <= v_now
    order by s.next_run_at asc, s.last_success_at asc nulls first, s.created_at asc
    limit v_limit
    for update of s skip locked
  ),
  base as (
    select
      d.finance_sync_state_id,
      d.tenant_id,
      d.marketplace_account_id,
      d.marketplace,
      case
        when coalesce(d.bootstrap_cursor_date, d.bootstrap_from_date) <= d.bootstrap_to_date then 'backfill_90d'
        when coalesce(d.recent_cursor_date, current_date - 3) < current_date - 3 then 'catchup_gap'
        else 'recent_pull'
      end as mode,
      case
        when coalesce(d.bootstrap_cursor_date, d.bootstrap_from_date) <= d.bootstrap_to_date
          then coalesce(d.bootstrap_cursor_date, d.bootstrap_from_date)
        when coalesce(d.recent_cursor_date, current_date - 3) < current_date - 3
          then coalesce(d.recent_cursor_date + 1, current_date - 3)
        else current_date - 2
      end as period_start,
      d.bootstrap_to_date
    from due d
  ),
  planned as (
    select
      b.*,
      case
        when b.mode = 'backfill_90d' then least(b.period_start + (v_window_days - 1), b.bootstrap_to_date)
        when b.mode = 'catchup_gap' then least(b.period_start + (v_window_days - 1), current_date)
        else current_date
      end as period_end
    from base b
  ),
  upd as (
    update public.marketplace_finance_sync_state s
    set
      finance_status = 'running',
      lock_token = v_lock,
      locked_until = v_now + (v_lock_seconds || ' seconds')::interval,
      bootstrap_started_at = coalesce(s.bootstrap_started_at, v_now),
      updated_at = v_now
    from planned p
    where s.finance_sync_state_id = p.finance_sync_state_id
    returning
      p.finance_sync_state_id,
      p.tenant_id,
      p.marketplace_account_id,
      p.marketplace,
      p.mode,
      p.period_start,
      p.period_end,
      case
        when p.mode = 'backfill_90d' then p.period_end + 1
        else p.period_end
      end as next_cursor_date,
      v_lock as lock_token
  )
  select
    u.finance_sync_state_id,
    u.tenant_id,
    u.marketplace_account_id,
    u.marketplace,
    u.mode,
    u.period_start,
    u.period_end,
    u.next_cursor_date,
    u.lock_token
  from upd u;
end;
$$;

create or replace function public.marketplace_finance_sync_finish(
  p_finance_sync_state_id uuid,
  p_ok boolean,
  p_mode text,
  p_period_start date,
  p_period_end date,
  p_next_cursor_date date,
  p_checked integer default 0,
  p_synced integer default 0,
  p_failed integer default 0,
  p_message text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := now();
  v_row public.marketplace_finance_sync_state%rowtype;
  v_message text := left(coalesce(p_message, 'finance dispatcher failed'), 1000);
  v_lower_message text := lower(coalesce(p_message, ''));
  v_blocked boolean := false;
begin
  v_blocked :=
    v_lower_message like '%income_export_pending_connect_guard%'
    or v_lower_message like '%tiktok_finance_not_synced%'
    or v_lower_message like '%belum tersinkron%'
    or v_lower_message like '%export%'
    or v_lower_message like '%connect%'
    or v_lower_message like '%scope%'
    or v_lower_message like '%token%'
    or v_lower_message like '%authorize%'
    or v_lower_message like '%authorise%';

  if p_ok then
    update public.marketplace_finance_sync_state s
    set
      finance_status = case
        when p_mode = 'backfill_90d' and p_next_cursor_date > s.bootstrap_to_date then 'caught_up'
        else 'running'
      end,
      bootstrap_cursor_date = case
        when p_mode = 'backfill_90d' then p_next_cursor_date
        else s.bootstrap_cursor_date
      end,
      bootstrap_completed_at = case
        when p_mode = 'backfill_90d' and p_next_cursor_date > s.bootstrap_to_date then v_now
        else s.bootstrap_completed_at
      end,
      recent_cursor_date = case
        when p_mode in ('catchup_gap', 'recent_pull') then p_period_end
        else s.recent_cursor_date
      end,
      recent_caught_up_at = case
        when p_mode in ('catchup_gap', 'recent_pull') then v_now
        else s.recent_caught_up_at
      end,
      last_success_period_start = p_period_start,
      last_success_period_end = p_period_end,
      last_success_at = v_now,
      last_mode = p_mode,
      last_error = null,
      failure_count = 0,
      checked_total = s.checked_total + greatest(coalesce(p_checked, 0), 0),
      synced_total = s.synced_total + greatest(coalesce(p_synced, 0), 0),
      failed_total = s.failed_total + greatest(coalesce(p_failed, 0), 0),
      lock_token = null,
      locked_until = null,
      next_run_at = case
        when p_mode = 'recent_pull' then v_now + interval '5 minutes'
        else v_now + interval '30 seconds'
      end,
      updated_at = v_now
    where s.finance_sync_state_id = p_finance_sync_state_id
    returning * into v_row;
  else
    update public.marketplace_finance_sync_state s
    set
      finance_status = case when v_blocked then 'blocked' else 'error' end,
      last_mode = p_mode,
      last_error = v_message,
      failure_count = s.failure_count + 1,
      failed_total = s.failed_total + greatest(coalesce(p_failed, 1), 1),
      lock_token = null,
      locked_until = null,
      next_run_at = case
        when v_blocked then v_now + interval '30 minutes'
        else v_now + (
          case
            when s.failure_count <= 0 then interval '5 minutes'
            when s.failure_count = 1 then interval '15 minutes'
            else interval '30 minutes'
          end
        )
      end,
      updated_at = v_now
    where s.finance_sync_state_id = p_finance_sync_state_id
    returning * into v_row;
  end if;

  if v_row.finance_sync_state_id is null then
    return jsonb_build_object('ok', false, 'message', 'finance sync state not found');
  end if;

  return jsonb_build_object(
    'ok', true,
    'state_id', v_row.finance_sync_state_id,
    'marketplace', v_row.marketplace,
    'account_id', v_row.marketplace_account_id,
    'finance_status', v_row.finance_status,
    'failure_count', v_row.failure_count,
    'next_run_at', v_row.next_run_at
  );
end;
$$;

update public.marketplace_finance_sync_state
set
  finance_status = 'pending',
  last_error = 'income_export_pending_connect_guard: finance sync pending; no marketplace finance rows synced yet.',
  last_success_period_start = null,
  last_success_period_end = null,
  last_success_at = null,
  bootstrap_completed_at = null,
  recent_caught_up_at = null,
  lock_token = null,
  locked_until = null,
  next_run_at = now(),
  updated_at = now()
where coalesce(synced_total, 0) = 0
  and coalesce(last_mode, '') = 'income_export_pending_connect_guard'
  and finance_status in ('done', 'unsupported');

grant execute on function public.marketplace_finance_sync_claim(integer, integer, integer, integer, boolean) to service_role;
grant execute on function public.marketplace_finance_sync_finish(uuid, boolean, text, date, date, date, integer, integer, integer, text) to service_role;

notify pgrst, 'reload schema';

commit;
