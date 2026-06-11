create or replace function public.finance_cash_can_read_tenant(p_tenant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.users u
    where u.user_id::text = auth.uid()::text
      and u.tenant_id = p_tenant_id
      and coalesce(u.status, 'active') = 'active'
  );
$$;

create or replace function public.finance_cash_can_write_tenant(p_tenant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.users u
    where u.user_id::text = auth.uid()::text
      and u.tenant_id = p_tenant_id
      and coalesce(u.status, 'active') = 'active'
      and coalesce(u.is_demo_account, false) = false
      and u.role_id in ('super_admin', 'finance')
  );
$$;

alter table public.finance_company_cash_opening_balances enable row level security;
alter table public.finance_company_cash_adjustments enable row level security;
alter table public.finance_marketplace_withdrawals enable row level security;
alter table public.finance_marketplace_withdrawal_allocations enable row level security;

drop policy if exists finance_cash_opening_read on public.finance_company_cash_opening_balances;
drop policy if exists finance_cash_opening_insert on public.finance_company_cash_opening_balances;
drop policy if exists finance_cash_opening_update on public.finance_company_cash_opening_balances;
drop policy if exists finance_cash_opening_delete on public.finance_company_cash_opening_balances;

create policy finance_cash_opening_read
on public.finance_company_cash_opening_balances
for select
to authenticated
using (public.finance_cash_can_read_tenant(tenant_id));

create policy finance_cash_opening_insert
on public.finance_company_cash_opening_balances
for insert
to authenticated
with check (public.finance_cash_can_write_tenant(tenant_id));

create policy finance_cash_opening_update
on public.finance_company_cash_opening_balances
for update
to authenticated
using (public.finance_cash_can_write_tenant(tenant_id))
with check (public.finance_cash_can_write_tenant(tenant_id));

create policy finance_cash_opening_delete
on public.finance_company_cash_opening_balances
for delete
to authenticated
using (public.finance_cash_can_write_tenant(tenant_id));

drop policy if exists finance_cash_adjustments_read on public.finance_company_cash_adjustments;
drop policy if exists finance_cash_adjustments_insert on public.finance_company_cash_adjustments;
drop policy if exists finance_cash_adjustments_update on public.finance_company_cash_adjustments;
drop policy if exists finance_cash_adjustments_delete on public.finance_company_cash_adjustments;

create policy finance_cash_adjustments_read
on public.finance_company_cash_adjustments
for select
to authenticated
using (public.finance_cash_can_read_tenant(tenant_id));

create policy finance_cash_adjustments_insert
on public.finance_company_cash_adjustments
for insert
to authenticated
with check (public.finance_cash_can_write_tenant(tenant_id));

create policy finance_cash_adjustments_update
on public.finance_company_cash_adjustments
for update
to authenticated
using (public.finance_cash_can_write_tenant(tenant_id))
with check (public.finance_cash_can_write_tenant(tenant_id));

create policy finance_cash_adjustments_delete
on public.finance_company_cash_adjustments
for delete
to authenticated
using (public.finance_cash_can_write_tenant(tenant_id));

drop policy if exists finance_marketplace_withdrawals_read on public.finance_marketplace_withdrawals;
drop policy if exists finance_marketplace_withdrawals_insert on public.finance_marketplace_withdrawals;
drop policy if exists finance_marketplace_withdrawals_update on public.finance_marketplace_withdrawals;
drop policy if exists finance_marketplace_withdrawals_delete on public.finance_marketplace_withdrawals;

create policy finance_marketplace_withdrawals_read
on public.finance_marketplace_withdrawals
for select
to authenticated
using (public.finance_cash_can_read_tenant(tenant_id));

create policy finance_marketplace_withdrawals_insert
on public.finance_marketplace_withdrawals
for insert
to authenticated
with check (public.finance_cash_can_write_tenant(tenant_id));

create policy finance_marketplace_withdrawals_update
on public.finance_marketplace_withdrawals
for update
to authenticated
using (public.finance_cash_can_write_tenant(tenant_id))
with check (public.finance_cash_can_write_tenant(tenant_id));

create policy finance_marketplace_withdrawals_delete
on public.finance_marketplace_withdrawals
for delete
to authenticated
using (public.finance_cash_can_write_tenant(tenant_id));

drop policy if exists finance_marketplace_withdrawal_allocations_read on public.finance_marketplace_withdrawal_allocations;
drop policy if exists finance_marketplace_withdrawal_allocations_insert on public.finance_marketplace_withdrawal_allocations;
drop policy if exists finance_marketplace_withdrawal_allocations_update on public.finance_marketplace_withdrawal_allocations;
drop policy if exists finance_marketplace_withdrawal_allocations_delete on public.finance_marketplace_withdrawal_allocations;

create policy finance_marketplace_withdrawal_allocations_read
on public.finance_marketplace_withdrawal_allocations
for select
to authenticated
using (public.finance_cash_can_read_tenant(tenant_id));

create policy finance_marketplace_withdrawal_allocations_insert
on public.finance_marketplace_withdrawal_allocations
for insert
to authenticated
with check (public.finance_cash_can_write_tenant(tenant_id));

create policy finance_marketplace_withdrawal_allocations_update
on public.finance_marketplace_withdrawal_allocations
for update
to authenticated
using (public.finance_cash_can_write_tenant(tenant_id))
with check (public.finance_cash_can_write_tenant(tenant_id));

create policy finance_marketplace_withdrawal_allocations_delete
on public.finance_marketplace_withdrawal_allocations
for delete
to authenticated
using (public.finance_cash_can_write_tenant(tenant_id));

grant execute on function public.finance_cash_can_read_tenant(uuid) to authenticated;
grant execute on function public.finance_cash_can_write_tenant(uuid) to authenticated;
