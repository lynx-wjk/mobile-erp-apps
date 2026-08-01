alter table public.marketplace_accounts
  add column if not exists is_active boolean
  generated always as (
    lower(coalesce(status, '')) = 'active'
    and coalesce(is_deleted, false) = false
  ) stored;

comment on column public.marketplace_accounts.is_active is
'Compatibility generated flag for backend cron functions. True when status is active and the account is not deleted.';
