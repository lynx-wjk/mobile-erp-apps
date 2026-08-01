create index if not exists idx_hist_order_batches_account
  on public.marketplace_export_import_batches(marketplace_account_id, marketplace_export_import_batch_id);

create index if not exists idx_hist_order_rows_batch_order_row
  on public.marketplace_export_import_rows(batch_id, marketplace_order_sn, row_index);

create index if not exists idx_hist_order_rows_batch_row
  on public.marketplace_export_import_rows(batch_id, row_index);

create index if not exists idx_live_orders_marketplace_account_sn
  on public.marketplace_orders(marketplace, marketplace_account_id, order_sn);

create index if not exists idx_live_items_historical_external_lookup
  on public.marketplace_order_items(tenant_id, marketplace_account_id, external_order_id, external_order_item_id);

create index if not exists idx_hist_finance_batches_account
  on public.marketplace_finance_export_import_batches(marketplace_account_id, marketplace_finance_export_import_batch_id);

create index if not exists idx_hist_finance_rows_batch_order_row
  on public.marketplace_finance_export_import_rows(batch_id, marketplace_order_sn, row_index);

do $migrate$
declare
  v_def text;
begin
  select pg_get_functiondef('public.marketplace_historical_finalize_process_step(uuid, integer)'::regprocedure)
    into v_def;

  if v_def is null then
    raise exception 'Function public.marketplace_historical_finalize_process_step(uuid, integer) not found';
  end if;

  v_def := replace(v_def, '''45s''', '''180s''');

  v_def := regexp_replace(
    v_def,
    'v_limit\s+int\s*:=\s*greatest\(least\(coalesce\(p_limit,\s*500\),\s*1000\),\s*50\);',
    'v_limit int := greatest(least(coalesce(p_limit, 100), 100), 25);',
    'g'
  );

  v_def := regexp_replace(
    v_def,
    'v_limit\s+integer\s*:=\s*greatest\(least\(coalesce\(p_limit,\s*500\),\s*1000\),\s*50\);',
    'v_limit int := greatest(least(coalesce(p_limit, 100), 100), 25);',
    'g'
  );

  execute v_def;
end
$migrate$;

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
  and (
    coalesce(last_error, '') ilike '%statement timeout%'
    or coalesce(last_error, '') ilike '%canceling statement%'
    or coalesce(last_error, '') ilike '%marketplace_sku%'
  );

notify pgrst, 'reload schema';
