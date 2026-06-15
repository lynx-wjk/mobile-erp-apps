-- 9I-B canonical marketplace audit view aliases.
-- Keep old versioned views as backing implementation. No old view is dropped here.

create or replace view public.marketplace_bootstrap_page_limit_audit as
select *
from public.marketplace_bootstrap_page_limit_audit_v1;

create or replace view public.marketplace_account_bootstrap_status as
select *
from public.marketplace_account_bootstrap_status_v2;

create or replace view public.marketplace_finance_coverage_audit as
select *
from public.marketplace_finance_coverage_audit_v1;

create or replace view public.marketplace_retention_90d_audit as
select *
from public.marketplace_retention_90d_audit_v1;

revoke all on public.marketplace_bootstrap_page_limit_audit from public, anon, authenticated;
revoke all on public.marketplace_account_bootstrap_status from public, anon, authenticated;
revoke all on public.marketplace_finance_coverage_audit from public, anon, authenticated;
revoke all on public.marketplace_retention_90d_audit from public, anon, authenticated;

grant select on public.marketplace_bootstrap_page_limit_audit to service_role;
grant select on public.marketplace_account_bootstrap_status to service_role;
grant select on public.marketplace_finance_coverage_audit to service_role;
grant select on public.marketplace_retention_90d_audit to service_role;

notify pgrst, 'reload schema';
