-- Index support for finance_dashboard_snapshot fast filter.

do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'marketplace_orders'
      and column_name = 'order_created_at'
  ) then
    execute '
      create index if not exists idx_marketplace_orders_finance_fast_date_account_marketplace
      on public.marketplace_orders (
        ((order_created_at at time zone ''Asia/Jakarta'')::date),
        marketplace_account_id,
        marketplace
      )
    ';
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'marketplace_finance_reports'
      and column_name = 'period_start'
  ) then
    execute '
      create index if not exists idx_marketplace_finance_reports_fast_period_account_marketplace
      on public.marketplace_finance_reports (
        period_start,
        marketplace_account_id,
        marketplace
      )
    ';
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'marketplace_finance_items'
      and column_name = 'order_created_at'
  ) then
    execute '
      create index if not exists idx_marketplace_finance_items_fast_date_account_marketplace
      on public.marketplace_finance_items (
        ((coalesce(order_created_at, created_at) at time zone ''Asia/Jakarta'')::date),
        marketplace_account_id,
        marketplace
      )
    ';
  end if;
end $$;

analyze public.marketplace_orders;
analyze public.marketplace_finance_reports;
analyze public.marketplace_finance_items;

notify pgrst, 'reload schema';