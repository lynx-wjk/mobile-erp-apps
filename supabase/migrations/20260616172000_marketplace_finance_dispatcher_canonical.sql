create extension if not exists pgcrypto;

create table if not exists public.marketplace_finance_sync_state (
  finance_sync_state_id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  marketplace_account_id uuid not null,
  marketplace text not null,
  finance_status text not null default 'pending',
  bootstrap_from_date date not null default (current_date - 90),
  bootstrap_to_date date not null default current_date,
  bootstrap_cursor_date date,
  bootstrap_started_at timestamptz,
  bootstrap_completed_at timestamptz,
  recent_cursor_date date,
  recent_caught_up_at timestamptz,
  last_success_period_start date,
  last_success_period_end date,
  last_success_at timestamptz,
  last_mode text,
  last_error text,
  failure_count integer not null default 0,
  checked_total integer not null default 0,
  synced_total integer not null default 0,
  failed_total integer not null default 0,
  lock_token text,
  locked_until timestamptz,
  next_run_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (marketplace_account_id)
);

create index if not exists marketplace_finance_sync_state_due_idx
on public.marketplace_finance_sync_state (next_run_at, locked_until, marketplace, finance_status);

create index if not exists marketplace_finance_sync_state_tenant_idx
on public.marketplace_finance_sync_state (tenant_id, marketplace_account_id);

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
begin
  insert into public.marketplace_finance_sync_state (
    tenant_id,
    marketplace_account_id,
    marketplace,
    finance_status,
    bootstrap_from_date,
    bootstrap_to_date,
    bootstrap_cursor_date,
    next_run_at
  )
  select
    ma.tenant_id,
    ma.marketplace_account_id,
    ma.marketplace,
    case when ma.marketplace = 'tiktok_shop' then 'unsupported' else 'pending' end,
    current_date - v_bootstrap_days,
    current_date,
    current_date - v_bootstrap_days,
    case when ma.marketplace = 'tiktok_shop' then v_now + interval '1 day' else v_now end
  from public.marketplace_accounts ma
  where ma.marketplace in ('shopee', 'tiktok_shop')
    and ma.status = 'active'
    and coalesce(ma.is_deleted, false) = false
    and coalesce(ma.is_active, true) = true
  on conflict (marketplace_account_id) do update
  set
    tenant_id = excluded.tenant_id,
    marketplace = excluded.marketplace,
    finance_status = case
      when excluded.marketplace = 'tiktok_shop' then 'unsupported'
      when public.marketplace_finance_sync_state.finance_status = 'unsupported' then 'pending'
      else public.marketplace_finance_sync_state.finance_status
    end,
    updated_at = v_now;

  update public.marketplace_finance_sync_state s
  set
    finance_status = 'unsupported',
    failure_count = 0,
    last_error = null,
    lock_token = null,
    locked_until = null,
    next_run_at = v_now + interval '1 day',
    updated_at = v_now
  where s.marketplace = 'tiktok_shop'
    and s.finance_status <> 'unsupported';

  if p_dry_run then
    return query
    with due as (
      select s.*
      from public.marketplace_finance_sync_state s
      join public.marketplace_accounts ma
        on ma.marketplace_account_id = s.marketplace_account_id
      where s.marketplace = 'shopee'
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
    where s.marketplace = 'shopee'
      and ma.status = 'active'
      and coalesce(ma.is_deleted, false) = false
      and coalesce(ma.is_active, true) = true
      and (s.locked_until is null or s.locked_until < v_now)
      and s.next_run_at <= v_now
    order by s.next_run_at asc, s.last_success_at asc nulls first, s.created_at asc
    limit v_limit
    for update skip locked
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
begin
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
      finance_status = 'error',
      last_mode = p_mode,
      last_error = left(coalesce(p_message, 'finance dispatcher failed'), 1000),
      failure_count = s.failure_count + 1,
      failed_total = s.failed_total + greatest(coalesce(p_failed, 1), 1),
      lock_token = null,
      locked_until = null,
      next_run_at = v_now + (
        case
          when s.failure_count <= 0 then interval '5 minutes'
          when s.failure_count = 1 then interval '15 minutes'
          else interval '30 minutes'
        end
      ),
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

grant execute on function public.marketplace_finance_sync_claim(integer, integer, integer, integer, boolean) to service_role;
grant execute on function public.marketplace_finance_sync_finish(uuid, boolean, text, date, date, date, integer, integer, integer, text) to service_role;
