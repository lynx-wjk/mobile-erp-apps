-- Canonical marketplace order dispatcher state.
-- No app v1/v2/v24 naming.
-- One state row per marketplace account.
-- Dispatcher uses cursor-based bootstrap, catchup, and recent pull.

create table if not exists public.marketplace_order_sync_state (
  sync_state_id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  marketplace_account_id uuid not null unique,
  marketplace text not null check (marketplace in ('shopee', 'tiktok_shop')),
  bootstrap_status text not null default 'pending' check (bootstrap_status in ('pending', 'running', 'done', 'failed')),
  bootstrap_from_seconds bigint,
  bootstrap_to_seconds bigint,
  bootstrap_cursor_seconds bigint,
  bootstrap_started_at timestamptz,
  bootstrap_completed_at timestamptz,
  recent_cursor_seconds bigint,
  recent_caught_up_at timestamptz,
  last_success_window_start_seconds bigint,
  last_success_window_end_seconds bigint,
  last_success_at timestamptz,
  last_mode text,
  last_error text,
  failure_count integer not null default 0,
  lock_token uuid,
  locked_until timestamptz,
  next_run_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_marketplace_order_sync_state_tenant
on public.marketplace_order_sync_state (tenant_id, marketplace);

create index if not exists idx_marketplace_order_sync_state_due
on public.marketplace_order_sync_state (next_run_at, locked_until);

alter table public.marketplace_order_sync_state enable row level security;

revoke all on public.marketplace_order_sync_state from anon, authenticated;
grant all on public.marketplace_order_sync_state to service_role;

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
  on conflict (marketplace_account_id) do update
  set
    tenant_id = excluded.tenant_id,
    marketplace = excluded.marketplace,
    updated_at = now()
  where public.marketplace_order_sync_state.tenant_id is distinct from excluded.tenant_id
     or public.marketplace_order_sync_state.marketplace is distinct from excluded.marketplace;

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
      s.next_run_at asc,
      coalesce(s.last_success_at, timestamp with time zone 'epoch') asc,
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
  order by c.next_run_at asc, coalesce(c.last_success_at, timestamp with time zone 'epoch') asc;
end;
$$;

revoke all on function public.marketplace_order_sync_claim(integer, integer) from anon, authenticated;
grant execute on function public.marketplace_order_sync_claim(integer, integer) to service_role;
