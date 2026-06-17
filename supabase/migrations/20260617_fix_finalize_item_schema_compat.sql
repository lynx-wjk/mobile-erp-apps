begin;

alter table public.marketplace_order_items
  add column if not exists external_order_id text,
  add column if not exists external_order_item_id text,
  add column if not exists marketplace_seller_sku text,
  add column if not exists seller_sku text,
  add column if not exists marketplace_sku text,
  add column if not exists marketplace_sku_id text,
  add column if not exists local_sku text,
  add column if not exists qty numeric,
  add column if not exists quantity numeric,
  add column if not exists scanned_qty numeric default 0,
  add column if not exists scan_status text,
  add column if not exists stock_action_status text,
  add column if not exists gross_amount numeric default 0,
  add column if not exists paid_amount numeric default 0,
  add column if not exists unit_gross_amount numeric default 0,
  add column if not exists unit_paid_amount numeric default 0,
  add column if not exists raw_item jsonb default '{}'::jsonb;

update public.marketplace_historical_finalize_jobs
set
  status = 'running',
  phase = case
    when coalesce(orders_upserted, 0) < coalesce(total_orders, 0) then 'orders'
    when coalesce(items_upserted, 0) < coalesce(total_items, 0) then 'items'
    when coalesce(finance_reports_upserted, 0) < coalesce(total_finance_orders, 0) then 'finance'
    else 'finalizing'
  end,
  last_error = null,
  finished_at = null,
  updated_at = now()
where status = 'error'
  and coalesce(last_error, '') ilike '%marketplace_sku%';

notify pgrst, 'reload schema';

commit;
