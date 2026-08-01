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
  on conflict on constraint marketplace_finance_sync_state_marketplace_account_id_key do update
  set
    tenant_id = excluded.tenant_id,
    marketplace = excluded.marketplace,
    finance_status = case
      when excluded.marketplace = 'tiktok_shop' then 'unsupported'
      when marketplace_finance_sync_state.finance_status = 'unsupported' then 'pending'
      else marketplace_finance_sync_state.finance_status
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

grant execute on function public.marketplace_finance_sync_claim(integer, integer, integer, integer, boolean) to service_role;
