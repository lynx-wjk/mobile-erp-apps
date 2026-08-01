drop policy if exists finance_operational_expenses_tenant_select on public.finance_operational_expenses;
drop policy if exists finance_operational_expenses_tenant_insert on public.finance_operational_expenses;
drop policy if exists finance_operational_expenses_tenant_update on public.finance_operational_expenses;
drop policy if exists finance_operational_expenses_tenant_delete on public.finance_operational_expenses;

create policy finance_operational_expenses_tenant_select
on public.finance_operational_expenses
for select
to authenticated
using (public.app_has_tenant_access(tenant_id));

create policy finance_operational_expenses_tenant_insert
on public.finance_operational_expenses
for insert
to authenticated
with check (public.app_has_tenant_write_access(tenant_id));

create policy finance_operational_expenses_tenant_update
on public.finance_operational_expenses
for update
to authenticated
using (public.app_has_tenant_write_access(tenant_id))
with check (public.app_has_tenant_write_access(tenant_id));

create policy finance_operational_expenses_tenant_delete
on public.finance_operational_expenses
for delete
to authenticated
using (public.app_has_tenant_write_access(tenant_id));

notify pgrst, 'reload schema';