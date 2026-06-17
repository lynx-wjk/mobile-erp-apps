-- Repair marketplace sync-state bootstrap_status constraints.
-- Safe for mixed schema: only touches tables/columns that exist.

begin;

do $$
begin
  if to_regclass('public.marketplace_order_sync_state') is not null
     and exists (
       select 1
       from information_schema.columns
       where table_schema = 'public'
         and table_name = 'marketplace_order_sync_state'
         and column_name = 'bootstrap_status'
     )
  then
    alter table public.marketplace_order_sync_state
      drop constraint if exists marketplace_order_sync_state_bootstrap_status_check;

    alter table public.marketplace_order_sync_state
      add constraint marketplace_order_sync_state_bootstrap_status_check
      check (
        bootstrap_status is null
        or bootstrap_status = any (
          array[
            'pending',
            'queued',
            'running',
            'done',
            'complete',
            'completed',
            'failed',
            'blocked',
            'paused',
            'disabled',
            'export_import_pending',
            'export_import_pending_connect_guard',
            'manual_import_pending',
            'api_backfill_pending',
            'api_backfill_running',
            'api_backfill_complete'
          ]::text[]
        )
      );
  end if;

  if to_regclass('public.marketplace_finance_sync_state') is not null
     and exists (
       select 1
       from information_schema.columns
       where table_schema = 'public'
         and table_name = 'marketplace_finance_sync_state'
         and column_name = 'bootstrap_status'
     )
  then
    alter table public.marketplace_finance_sync_state
      drop constraint if exists marketplace_finance_sync_state_bootstrap_status_check;

    alter table public.marketplace_finance_sync_state
      add constraint marketplace_finance_sync_state_bootstrap_status_check
      check (
        bootstrap_status is null
        or bootstrap_status = any (
          array[
            'pending',
            'queued',
            'running',
            'done',
            'complete',
            'completed',
            'failed',
            'blocked',
            'paused',
            'disabled',
            'income_export_pending',
            'income_export_pending_connect_guard',
            'manual_import_pending',
            'api_backfill_pending',
            'api_backfill_running',
            'api_backfill_complete'
          ]::text[]
        )
      );
  end if;
end $$;

notify pgrst, 'reload schema';

commit;
