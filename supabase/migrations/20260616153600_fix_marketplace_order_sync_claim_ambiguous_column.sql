-- Fix ambiguous column references in canonical marketplace_order_sync_claim.
-- No new versioned object names.

create or replace function public.marketplace_order_sync_claim(
  p_limit integer default 6,
  p_lock_seconds integer default 600
)
returns table (
  sync_state_id uuid,
  tenant_id uuid,
  marketplace_account_id uuid,
  marketplace text,
  bootstrap_status text,
  bootstrap_from_seconds bigint,
  bootstrap_to_seconds bigint,
  bootstrap_cursor_seconds bigint,
  recent_cursor_seconds bigint,
  last_success_window_end_seconds bigint,
  last_success_at timestamptz,
  failure_count integer,
  lock_token uuid
)
language plpgsql
as $$
declare
  v_now_seconds bigint := extract(epoch from now())::bigint;
  v_from_seconds bigint := extract(epoch from (now() - interval '90 days'))::bigint;
  v_lock_seconds integer := greatest(60, least(coalesce(p_lock_seconds, 600), 1800));
begin
  -- Insert sync state only for active marketplace accounts that do not have state yet.
  insert into public.marketplace_order_sync_state (
    tenant_id,
    marketplace_account_id,
    marketplace,
    bootstrap_status,
    bootstrap_from_seconds,
    bootstrap_to_seconds,
    bootstrap_cursor_seconds,
    recent_cursor_seconds,
    next_run_at,
    created_at,
    updated_at
  )
  select
    a.tenant_id,
    a.marketplace_account_id,
    a.marketplace,
    'pending',
    v_from_seconds,
    v_now_seconds,
    v_from_seconds,
    null,
    now(),
    now(),
    now()
  from public.marketplace_accounts a
  where a.status = 'active'
    and a.marketplace in ('shopee', 'tiktok_shop')
    and not exists (
      select 1
      from public.marketplace_order_sync_state existing_state
      where existing_state.marketplace_account_id = a.marketplace_account_id
    );

  -- Keep state aligned if account tenant/marketplace changed, without resetting cursors.
  update public.marketplace_order_sync_state s
  set
    tenant_id = a.tenant_id,
    marketplace = a.marketplace,
    updated_at = now()
  from public.marketplace_accounts a
  where s.marketplace_account_id = a.marketplace_account_id
    and a.status = 'active'
    and a.marketplace in ('shopee', 'tiktok_shop')
    and (
      s.tenant_id is distinct from a.tenant_id
      or s.marketplace is distinct from a.marketplace
    );

  return query
  with due as (
    select s.sync_state_id
    from public.marketplace_order_sync_state s
    join public.marketplace_accounts a
      on a.marketplace_account_id = s.marketplace_account_id
     and a.tenant_id = s.tenant_id
     and a.marketplace = s.marketplace
    where a.status = 'active'
      and a.marketplace in ('shopee', 'tiktok_shop')
      and s.next_run_at <= now()
      and (s.locked_until is null or s.locked_until < now())
    order by
      case
        when s.bootstrap_status = 'done'
         and coalesce(s.recent_cursor_seconds, s.last_success_window_end_seconds, 0) < extract(epoch from now())::bigint - 300
          then 1
        when s.bootstrap_status = 'done'
          then 2
        when s.bootstrap_status in ('pending', 'running')
          then 3
        else 4
      end,
      coalesce(s.last_success_at, timestamp with time zone 'epoch') asc,
      s.next_run_at asc,
      s.created_at asc
    limit greatest(1, least(coalesce(p_limit, 6), 20))
  ),
  claimed as (
    update public.marketplace_order_sync_state s
    set
      lock_token = gen_random_uuid(),
      locked_until = now() + make_interval(secs => v_lock_seconds),
      bootstrap_status = case
        when s.bootstrap_status = 'pending' then 'running'
        else s.bootstrap_status
      end,
      bootstrap_started_at = case
        when s.bootstrap_status = 'pending' then coalesce(s.bootstrap_started_at, now())
        else s.bootstrap_started_at
      end,
      updated_at = now()
    from due
    where s.sync_state_id = due.sync_state_id
    returning s.*
  )
  select
    c.sync_state_id,
    c.tenant_id,
    c.marketplace_account_id,
    c.marketplace,
    c.bootstrap_status,
    c.bootstrap_from_seconds,
    c.bootstrap_to_seconds,
    c.bootstrap_cursor_seconds,
    c.recent_cursor_seconds,
    c.last_success_window_end_seconds,
    c.last_success_at,
    c.failure_count,
    c.lock_token
  from claimed c
  order by
    case
      when c.bootstrap_status = 'done'
       and coalesce(c.recent_cursor_seconds, c.last_success_window_end_seconds, 0) < extract(epoch from now())::bigint - 300
        then 1
      when c.bootstrap_status = 'done'
        then 2
      when c.bootstrap_status in ('pending', 'running')
        then 3
      else 4
    end,
    coalesce(c.last_success_at, timestamp with time zone 'epoch') asc,
    c.next_run_at asc;
end;
$$;

revoke all on function public.marketplace_order_sync_claim(integer, integer) from anon, authenticated;
grant execute on function public.marketplace_order_sync_claim(integer, integer) to service_role;

notify pgrst, 'reload schema';
select pg_notify('pgrst', 'reload schema');
