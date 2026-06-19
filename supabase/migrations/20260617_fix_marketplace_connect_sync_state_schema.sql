-- Fix marketplace connect sync-state trigger for mixed order/finance sync schemas.
-- Order sync uses bootstrap_status + epoch seconds.
-- Finance sync uses finance_status + date cursors.
-- This prevents callback failure: column bootstrap_status of marketplace_finance_sync_state does not exist.

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
begin
  if new.status = 'active' and new.deleted_at is null then
    -- ORDER STATE: schema has bootstrap_status + epoch seconds.
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

    -- FINANCE STATE: schema has finance_status + date cursors, no bootstrap_status column.
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
        'done',
        v_today,
        v_today,
        v_today,
        now(),
        now(),
        v_today,
        now(),
        v_today,
        v_today,
        now(),
        'income_export_pending_connect_guard',
        null,
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
        finance_status = 'done',
        bootstrap_from_date = coalesce(bootstrap_from_date, v_today),
        bootstrap_to_date = v_today,
        bootstrap_cursor_date = v_today,
        bootstrap_started_at = coalesce(bootstrap_started_at, now()),
        bootstrap_completed_at = now(),
        recent_cursor_date = v_today,
        recent_caught_up_at = now(),
        last_success_period_start = v_today,
        last_success_period_end = v_today,
        last_success_at = now(),
        last_mode = 'income_export_pending_connect_guard',
        last_error = null,
        failure_count = 0,
        checked_total = 0,
        synced_total = 0,
        failed_total = 0,
        lock_token = null,
        locked_until = null,
        next_run_at = now(),
        updated_at = now()
      where marketplace_account_id = new.marketplace_account_id;
    end if;
  end if;

  return new;
end;
$$;

create or replace function public.marketplace_disable_auto_90d_on_connect_export_import_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Keep the later zz trigger schema-safe by delegating to the canonical connect-state guard.
  return public.marketplace_connect_ensure_sync_states();
end;
$$;

notify pgrst, 'reload schema';

commit;
