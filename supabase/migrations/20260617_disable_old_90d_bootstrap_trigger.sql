begin;

do $$
begin
  if exists (
    select 1
    from pg_trigger
    where tgrelid = 'public.marketplace_accounts'::regclass
      and tgname = 'trg_marketplace_accounts_enqueue_bootstrap_90d'
  ) then
    alter table public.marketplace_accounts
      disable trigger trg_marketplace_accounts_enqueue_bootstrap_90d;
  end if;
end $$;

notify pgrst, 'reload schema';

commit;
