-- Remove duplicate export/import guard trigger.
-- The canonical trigger marketplace_accounts_ensure_sync_states_after_connect
-- already creates schema-safe order/finance sync states.
-- The old zz guard called another trigger function directly, causing:
-- "trigger functions can only be called as triggers".

begin;

drop trigger if exists zz_marketplace_disable_auto_90d_on_connect_export_import_guard
on public.marketplace_accounts;

create or replace function public.marketplace_disable_auto_90d_on_connect_export_import_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- No-op compatibility function. Keep it harmless for old migrations.
  return new;
end;
$$;

notify pgrst, 'reload schema';

commit;
