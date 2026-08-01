create or replace function public.marketplace_connect_ensure_sync_states()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := now();
  v_from_seconds bigint := floor(extract(epoch from (v_now - interval '90 days')));
  v_to_seconds bigint := floor(extract(epoch from v_now));
  v_from_date date := current_date - 90;
  v_to_date date := current_date;
begin
  if new.marketplace not in ('shopee', 'tiktok_shop') then
    return new;
  end if;

  if new.status <> 'active'
     or coalesce(new.is_deleted, false) = true
     or coalesce(new.is_active, true) = false then
    return new;
  end if;

  insert into public.marketplace_order_sync_state (
    tenant_id,
    marketplace_account_id,
    marketplace,
    bootstrap_status,
    bootstrap_from_seconds,
    bootstrap_to_seconds,
    bootstrap_cursor_seconds,
    next_run_at,
    created_at,
    updated_at
  )
  values (
    new.tenant_id,
    new.marketplace_account_id,
    new.marketplace,
    'pending',
    v_from_seconds,
    v_to_seconds,
    v_from_seconds,
    v_now,
    v_now,
    v_now
  )
  on conflict (marketplace_account_id) do update
  set
    tenant_id = excluded.tenant_id,
    marketplace = excluded.marketplace,
    next_run_at = least(public.marketplace_order_sync_state.next_run_at, v_now),
    updated_at = v_now
  where public.marketplace_order_sync_state.marketplace_account_id = excluded.marketplace_account_id;

  insert into public.marketplace_finance_sync_state (
    tenant_id,
    marketplace_account_id,
    marketplace,
    finance_status,
    bootstrap_from_date,
    bootstrap_to_date,
    bootstrap_cursor_date,
    next_run_at,
    created_at,
    updated_at
  )
  values (
    new.tenant_id,
    new.marketplace_account_id,
    new.marketplace,
    case when new.marketplace = 'tiktok_shop' then 'unsupported' else 'pending' end,
    v_from_date,
    v_to_date,
    v_from_date,
    case when new.marketplace = 'tiktok_shop' then v_now + interval '1 day' else v_now end,
    v_now,
    v_now
  )
  on conflict (marketplace_account_id) do update
  set
    tenant_id = excluded.tenant_id,
    marketplace = excluded.marketplace,
    finance_status = case
      when excluded.marketplace = 'tiktok_shop' then 'unsupported'
      when public.marketplace_finance_sync_state.finance_status = 'unsupported' then 'pending'
      else public.marketplace_finance_sync_state.finance_status
    end,
    next_run_at = case
      when excluded.marketplace = 'tiktok_shop' then public.marketplace_finance_sync_state.next_run_at
      else least(public.marketplace_finance_sync_state.next_run_at, v_now)
    end,
    updated_at = v_now
  where public.marketplace_finance_sync_state.marketplace_account_id = excluded.marketplace_account_id;

  return new;
end;
$$;

drop trigger if exists marketplace_accounts_ensure_sync_states_after_connect on public.marketplace_accounts;

create trigger marketplace_accounts_ensure_sync_states_after_connect
after insert or update of status, is_active, is_deleted, tenant_id, marketplace
on public.marketplace_accounts
for each row
execute function public.marketplace_connect_ensure_sync_states();

insert into public.marketplace_order_sync_state (
  tenant_id,
  marketplace_account_id,
  marketplace,
  bootstrap_status,
  bootstrap_from_seconds,
  bootstrap_to_seconds,
  bootstrap_cursor_seconds,
  next_run_at,
  created_at,
  updated_at
)
select
  ma.tenant_id,
  ma.marketplace_account_id,
  ma.marketplace,
  'pending',
  floor(extract(epoch from (now() - interval '90 days'))),
  floor(extract(epoch from now())),
  floor(extract(epoch from (now() - interval '90 days'))),
  now(),
  now(),
  now()
from public.marketplace_accounts ma
where ma.marketplace in ('shopee', 'tiktok_shop')
  and ma.status = 'active'
  and coalesce(ma.is_deleted, false) = false
  and coalesce(ma.is_active, true) = true
on conflict (marketplace_account_id) do nothing;

insert into public.marketplace_finance_sync_state (
  tenant_id,
  marketplace_account_id,
  marketplace,
  finance_status,
  bootstrap_from_date,
  bootstrap_to_date,
  bootstrap_cursor_date,
  next_run_at,
  created_at,
  updated_at
)
select
  ma.tenant_id,
  ma.marketplace_account_id,
  ma.marketplace,
  case when ma.marketplace = 'tiktok_shop' then 'unsupported' else 'pending' end,
  current_date - 90,
  current_date,
  current_date - 90,
  case when ma.marketplace = 'tiktok_shop' then now() + interval '1 day' else now() end,
  now(),
  now()
from public.marketplace_accounts ma
where ma.marketplace in ('shopee', 'tiktok_shop')
  and ma.status = 'active'
  and coalesce(ma.is_deleted, false) = false
  and coalesce(ma.is_active, true) = true
on conflict (marketplace_account_id) do nothing;
