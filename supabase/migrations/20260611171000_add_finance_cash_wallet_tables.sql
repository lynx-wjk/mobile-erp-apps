create extension if not exists pgcrypto;

create table if not exists public.finance_company_cash_opening_balances (
  cash_opening_balance_id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.app_tenants(tenant_id) on delete cascade,
  period_month date not null,
  amount numeric not null default 0,
  note text,
  created_by uuid references public.users(user_id) on delete set null,
  created_by_name text,
  created_by_email text,
  created_by_role text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint finance_company_cash_opening_month_start_chk
    check (period_month = date_trunc('month', period_month)::date),
  constraint finance_company_cash_opening_amount_chk check (amount >= 0),
  constraint finance_company_cash_opening_unique unique (tenant_id, period_month)
);

create table if not exists public.finance_company_cash_adjustments (
  cash_adjustment_id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.app_tenants(tenant_id) on delete cascade,
  adjustment_date date not null,
  direction text not null,
  amount numeric not null default 0,
  category text not null default 'manual',
  note text,
  created_by uuid references public.users(user_id) on delete set null,
  created_by_name text,
  created_by_email text,
  created_by_role text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint finance_company_cash_adjustments_direction_chk check (direction in ('in','out')),
  constraint finance_company_cash_adjustments_amount_chk check (amount >= 0)
);

create table if not exists public.finance_marketplace_withdrawals (
  marketplace_withdrawal_id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.app_tenants(tenant_id) on delete cascade,
  marketplace_account_id uuid references public.marketplace_accounts(marketplace_account_id) on delete set null,
  marketplace text,
  withdrawal_date date not null,
  amount numeric not null default 0,
  bank_account_name text,
  bank_reference text,
  note text,
  created_by uuid references public.users(user_id) on delete set null,
  created_by_name text,
  created_by_email text,
  created_by_role text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint finance_marketplace_withdrawals_amount_chk check (amount >= 0)
);

create table if not exists public.finance_marketplace_withdrawal_allocations (
  marketplace_withdrawal_allocation_id uuid primary key default gen_random_uuid(),
  marketplace_withdrawal_id uuid not null references public.finance_marketplace_withdrawals(marketplace_withdrawal_id) on delete cascade,
  tenant_id uuid not null references public.app_tenants(tenant_id) on delete cascade,
  marketplace_account_id uuid references public.marketplace_accounts(marketplace_account_id) on delete set null,
  marketplace text,
  source_period_month date not null,
  amount numeric not null default 0,
  allocation_method text not null default 'manual',
  note text,
  created_at timestamptz not null default now(),
  constraint finance_withdrawal_alloc_month_start_chk
    check (source_period_month = date_trunc('month', source_period_month)::date),
  constraint finance_withdrawal_alloc_amount_chk check (amount >= 0),
  constraint finance_withdrawal_alloc_method_chk check (allocation_method in ('manual','fifo','system'))
);

create index if not exists idx_finance_company_cash_opening_tenant_month
  on public.finance_company_cash_opening_balances(tenant_id, period_month desc);

create index if not exists idx_finance_company_cash_adjustments_tenant_date
  on public.finance_company_cash_adjustments(tenant_id, adjustment_date desc);

create index if not exists idx_finance_marketplace_withdrawals_tenant_date
  on public.finance_marketplace_withdrawals(tenant_id, withdrawal_date desc);

create index if not exists idx_finance_marketplace_withdrawals_account_date
  on public.finance_marketplace_withdrawals(marketplace_account_id, withdrawal_date desc);

create index if not exists idx_finance_marketplace_alloc_source
  on public.finance_marketplace_withdrawal_allocations(tenant_id, marketplace_account_id, source_period_month desc);

grant select, insert, update, delete on public.finance_company_cash_opening_balances to anon, authenticated;
grant select, insert, update, delete on public.finance_company_cash_adjustments to anon, authenticated;
grant select, insert, update, delete on public.finance_marketplace_withdrawals to anon, authenticated;
grant select, insert, update, delete on public.finance_marketplace_withdrawal_allocations to anon, authenticated;

create or replace function public.finance_company_cashflow_monthly_snapshot(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_month_start date := date_trunc('month', coalesce(p_start, current_date))::date;
  v_month_end date := (date_trunc('month', coalesce(p_start, current_date)) + interval '1 month - 1 day')::date;
  v_tenant_id uuid;
  v_scope_marketplace text := nullif(nullif(lower(coalesce(p_marketplace, 'all')), ''), 'all');
  v_opening_cash numeric := 0;
  v_manual_cash_in numeric := 0;
  v_manual_cash_out numeric := 0;
  v_withdrawn_current numeric := 0;
  v_settlement_current numeric := 0;
  v_opening_marketplace_balance numeric := 0;
  v_marketplace_balance_end numeric := 0;
  v_company_cash_end numeric := 0;
  v_withdrawals jsonb := '[]'::jsonb;
  v_marketplace_monthly jsonb := '[]'::jsonb;
begin
  if p_account_id is not null then
    select ma.tenant_id into v_tenant_id
    from public.marketplace_accounts ma
    where ma.marketplace_account_id = p_account_id
    limit 1;
  end if;

  if v_tenant_id is null then
    select ma.tenant_id into v_tenant_id
    from public.marketplace_accounts ma
    where coalesce(ma.is_deleted, false) = false
      and (v_scope_marketplace is null or lower(ma.marketplace) = v_scope_marketplace)
    order by ma.created_at nulls last
    limit 1;
  end if;

  if v_tenant_id is null then
    select at.tenant_id into v_tenant_id
    from public.app_tenants at
    order by at.created_at nulls last
    limit 1;
  end if;

  select coalesce(max(amount), 0) into v_opening_cash
  from public.finance_company_cash_opening_balances b
  where b.tenant_id = v_tenant_id
    and b.period_month = v_month_start;

  select coalesce(sum(case when direction = 'in' then amount else 0 end), 0),
         coalesce(sum(case when direction = 'out' then amount else 0 end), 0)
    into v_manual_cash_in, v_manual_cash_out
  from public.finance_company_cash_adjustments a
  where a.tenant_id = v_tenant_id
    and a.adjustment_date between v_month_start and v_month_end;

  select coalesce(sum(w.amount), 0) into v_withdrawn_current
  from public.finance_marketplace_withdrawals w
  where w.tenant_id = v_tenant_id
    and w.withdrawal_date between v_month_start and v_month_end
    and (p_account_id is null or w.marketplace_account_id = p_account_id)
    and (v_scope_marketplace is null or lower(coalesce(w.marketplace, '')) = v_scope_marketplace);

  select coalesce(sum(coalesce(i.net_settlement, i.received_amount, i.payout_amount, 0)), 0)
    into v_settlement_current
  from public.marketplace_finance_items i
  where i.tenant_id = v_tenant_id
    and coalesce(i.transaction_time, i.pulled_at, i.created_at)::date between v_month_start and v_month_end
    and (p_account_id is null or i.marketplace_account_id = p_account_id)
    and (v_scope_marketplace is null or lower(coalesce(i.marketplace, '')) = v_scope_marketplace);

  with months as (
    select date_trunc('month', coalesce(i.transaction_time, i.pulled_at, i.created_at))::date as period_month,
           coalesce(i.marketplace_account_id, p_account_id) as marketplace_account_id,
           lower(coalesce(i.marketplace, 'marketplace')) as marketplace,
           sum(coalesce(i.net_settlement, i.received_amount, i.payout_amount, 0)) as settlement_amount
    from public.marketplace_finance_items i
    where i.tenant_id = v_tenant_id
      and coalesce(i.transaction_time, i.pulled_at, i.created_at)::date < v_month_start
      and (p_account_id is null or i.marketplace_account_id = p_account_id)
      and (v_scope_marketplace is null or lower(coalesce(i.marketplace, '')) = v_scope_marketplace)
    group by 1, 2, 3
  ), allocated_before as (
    select a.source_period_month as period_month,
           a.marketplace_account_id,
           lower(coalesce(a.marketplace, 'marketplace')) as marketplace,
           sum(a.amount) as allocated_amount
    from public.finance_marketplace_withdrawal_allocations a
    join public.finance_marketplace_withdrawals w
      on w.marketplace_withdrawal_id = a.marketplace_withdrawal_id
    where a.tenant_id = v_tenant_id
      and w.withdrawal_date < v_month_start
      and (p_account_id is null or a.marketplace_account_id = p_account_id)
      and (v_scope_marketplace is null or lower(coalesce(a.marketplace, '')) = v_scope_marketplace)
    group by 1, 2, 3
  )
  select coalesce(sum(greatest(m.settlement_amount - coalesce(a.allocated_amount, 0), 0)), 0)
    into v_opening_marketplace_balance
  from months m
  left join allocated_before a
    on a.period_month = m.period_month
   and a.marketplace = m.marketplace
   and coalesce(a.marketplace_account_id, '00000000-0000-0000-0000-000000000000'::uuid) =
       coalesce(m.marketplace_account_id, '00000000-0000-0000-0000-000000000000'::uuid);

  v_marketplace_balance_end := v_opening_marketplace_balance + v_settlement_current - v_withdrawn_current;
  v_company_cash_end := v_opening_cash + v_withdrawn_current + v_manual_cash_in - v_manual_cash_out;

  select coalesce(jsonb_agg(jsonb_build_object(
    'marketplace_withdrawal_id', w.marketplace_withdrawal_id,
    'withdrawal_date', w.withdrawal_date,
    'marketplace', coalesce(w.marketplace, ma.marketplace),
    'marketplace_account_id', w.marketplace_account_id,
    'shop_name', ma.shop_name,
    'store_alias', ma.store_alias,
    'amount', w.amount,
    'bank_account_name', w.bank_account_name,
    'bank_reference', w.bank_reference,
    'note', w.note
  ) order by w.withdrawal_date desc, w.created_at desc), '[]'::jsonb)
    into v_withdrawals
  from public.finance_marketplace_withdrawals w
  left join public.marketplace_accounts ma
    on ma.marketplace_account_id = w.marketplace_account_id
  where w.tenant_id = v_tenant_id
    and w.withdrawal_date between v_month_start and v_month_end
    and (p_account_id is null or w.marketplace_account_id = p_account_id)
    and (v_scope_marketplace is null or lower(coalesce(w.marketplace, ma.marketplace, '')) = v_scope_marketplace);

  with monthly_settlement as (
    select date_trunc('month', coalesce(i.transaction_time, i.pulled_at, i.created_at))::date as period_month,
           i.marketplace_account_id,
           lower(coalesce(i.marketplace, 'marketplace')) as marketplace,
           sum(coalesce(i.net_settlement, i.received_amount, i.payout_amount, 0)) as settlement_amount
    from public.marketplace_finance_items i
    where i.tenant_id = v_tenant_id
      and coalesce(i.transaction_time, i.pulled_at, i.created_at)::date <= v_month_end
      and (p_account_id is null or i.marketplace_account_id = p_account_id)
      and (v_scope_marketplace is null or lower(coalesce(i.marketplace, '')) = v_scope_marketplace)
    group by 1, 2, 3
  ), allocated as (
    select a.source_period_month as period_month,
           a.marketplace_account_id,
           lower(coalesce(a.marketplace, 'marketplace')) as marketplace,
           sum(a.amount) as allocated_amount
    from public.finance_marketplace_withdrawal_allocations a
    join public.finance_marketplace_withdrawals w
      on w.marketplace_withdrawal_id = a.marketplace_withdrawal_id
    where a.tenant_id = v_tenant_id
      and w.withdrawal_date <= v_month_end
      and (p_account_id is null or a.marketplace_account_id = p_account_id)
      and (v_scope_marketplace is null or lower(coalesce(a.marketplace, '')) = v_scope_marketplace)
    group by 1, 2, 3
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'source_period_month', m.period_month,
    'marketplace', m.marketplace,
    'marketplace_account_id', m.marketplace_account_id,
    'shop_name', ma.shop_name,
    'store_alias', ma.store_alias,
    'settlement_amount', m.settlement_amount,
    'withdrawn_amount', coalesce(a.allocated_amount, 0),
    'remaining_amount', greatest(m.settlement_amount - coalesce(a.allocated_amount, 0), 0)
  ) order by m.period_month desc, m.marketplace), '[]'::jsonb)
    into v_marketplace_monthly
  from monthly_settlement m
  left join allocated a
    on a.period_month = m.period_month
   and a.marketplace = m.marketplace
   and coalesce(a.marketplace_account_id, '00000000-0000-0000-0000-000000000000'::uuid) =
       coalesce(m.marketplace_account_id, '00000000-0000-0000-0000-000000000000'::uuid)
  left join public.marketplace_accounts ma
    on ma.marketplace_account_id = m.marketplace_account_id
  where greatest(m.settlement_amount - coalesce(a.allocated_amount, 0), 0) > 0
     or m.period_month = v_month_start;

  return jsonb_build_object(
    'ok', true,
    'tenant_id', v_tenant_id,
    'period_start', v_month_start,
    'period_end', v_month_end,
    'opening_company_cash', v_opening_cash,
    'manual_cash_in', v_manual_cash_in,
    'manual_cash_out', v_manual_cash_out,
    'marketplace_opening_balance', v_opening_marketplace_balance,
    'marketplace_settlement_current', v_settlement_current,
    'marketplace_withdrawn_current', v_withdrawn_current,
    'marketplace_remaining_balance', v_marketplace_balance_end,
    'company_cash_end', v_company_cash_end,
    'withdrawals', v_withdrawals,
    'marketplace_monthly_balances', v_marketplace_monthly
  );
end;
$$;

grant execute on function public.finance_company_cashflow_monthly_snapshot(date, date, text, uuid)
to anon, authenticated;
