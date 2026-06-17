create index if not exists idx_hist_order_batches_account
  on public.marketplace_export_import_batches(marketplace_account_id, marketplace_export_import_batch_id);

create index if not exists idx_hist_order_rows_batch_row
  on public.marketplace_export_import_rows(batch_id, row_index);

create index if not exists idx_hist_order_rows_batch_order_row
  on public.marketplace_export_import_rows(batch_id, marketplace_order_sn, row_index);

create index if not exists idx_live_orders_marketplace_account_sn
  on public.marketplace_orders(marketplace, marketplace_account_id, order_sn);

create unique index if not exists uq_moi_hist_external_item
  on public.marketplace_order_items(tenant_id, marketplace_account_id, external_order_id, external_order_item_id);

create unique index if not exists uq_mfr_tenant_marketplace_order
  on public.marketplace_finance_reports(tenant_id, marketplace, order_id);

alter table public.marketplace_historical_finalize_jobs
  add column if not exists last_item_row_index integer not null default 0;

create or replace function public.marketplace_historical_finalize_process_step(
  p_job_id uuid,
  p_limit integer default 25
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job record;
  v_done int := 0;
  v_limit int := greatest(least(coalesce(p_limit, 25), 25), 10);
  v_now_epoch bigint := extract(epoch from now())::bigint;
  v_last_item_row_index integer := 0;
begin
  perform set_config('statement_timeout', '180s', true);
  perform set_config('lock_timeout', '10s', true);

  select *
    into v_job
  from public.marketplace_historical_finalize_jobs
  where marketplace_historical_finalize_job_id = p_job_id
  for update;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'message', 'Job finalisasi tidak ditemukan.',
      'job_id', p_job_id
    );
  end if;

  if v_job.status in ('done', 'error') then
    return public.marketplace_historical_finalize_job_status(p_job_id);
  end if;

  if v_job.phase = 'orders' then
    with staged_orders as (
      select
        a.tenant_id,
        a.marketplace_account_id,
        a.marketplace,
        a.shop_id,
        a.shop_region,
        r.marketplace_order_sn as order_sn,
        max(nullif(r.order_status, '')) as order_status,
        min(r.order_created_at) as order_created_at,
        max(coalesce(r.total_amount, 0)) as order_amount,
        sum(coalesce(r.quantity, 1)) as qty_total,
        count(*) as item_rows,
        jsonb_build_object(
          'source', 'historical_export_import',
          'item_rows', count(*),
          'qty_total', sum(coalesce(r.quantity, 1))
        ) as raw_order
      from public.marketplace_export_import_rows r
      join public.marketplace_export_import_batches b
        on b.marketplace_export_import_batch_id = r.batch_id
      join public.marketplace_accounts a
        on a.marketplace_account_id = b.marketplace_account_id
      left join public.marketplace_orders mo
        on mo.marketplace = a.marketplace
       and mo.marketplace_account_id = a.marketplace_account_id
       and mo.order_sn = r.marketplace_order_sn
      where a.marketplace_account_id = v_job.marketplace_account_id
        and nullif(r.marketplace_order_sn, '') is not null
        and mo.marketplace_order_id is null
      group by
        a.tenant_id,
        a.marketplace_account_id,
        a.marketplace,
        a.shop_id,
        a.shop_region,
        r.marketplace_order_sn
      order by min(r.row_index)
      limit 100
    ),
    upserted as (
      insert into public.marketplace_orders(
        tenant_id,
        marketplace_account_id,
        marketplace,
        shop_id,
        shop_region,
        order_sn,
        external_order_id,
        remote_order_id,
        order_id,
        order_status,
        status,
        order_status_label,
        total_amount,
        gross_amount,
        paid_amount,
        currency,
        order_created_at,
        created_time,
        paid_at,
        pulled_at,
        packing_status,
        warehouse_status,
        stock_action_status,
        raw_order,
        created_at,
        updated_at
      )
      select
        tenant_id,
        marketplace_account_id,
        marketplace,
        shop_id,
        shop_region,
        order_sn,
        order_sn,
        order_sn,
        order_sn,
        order_status,
        order_status,
        order_status,
        order_amount,
        order_amount,
        case
          when lower(coalesce(order_status, '')) ~ '(batal|cancel|dibatalkan|belum bayar|belum dibayar|unpaid)' then 0
          else order_amount
        end,
        'IDR',
        order_created_at,
        order_created_at,
        case
          when lower(coalesce(order_status, '')) ~ '(batal|cancel|dibatalkan|belum bayar|belum dibayar|unpaid)' then null
          else order_created_at
        end,
        now(),
        case
          when lower(coalesce(order_status, '')) ~ '(batal|cancel|dibatalkan)' then 'cancelled'
          else 'waiting_scan'
        end,
        case
          when lower(coalesce(order_status, '')) ~ '(batal|cancel|dibatalkan)' then 'cancelled'
          else 'waiting_scan'
        end,
        case
          when lower(coalesce(order_status, '')) ~ '(batal|cancel|dibatalkan)' then 'cancelled'
          else 'pending'
        end,
        raw_order,
        now(),
        now()
      from staged_orders
      on conflict (marketplace, marketplace_account_id, order_sn) do update set
        external_order_id = excluded.external_order_id,
        remote_order_id = excluded.remote_order_id,
        order_id = excluded.order_id,
        order_status = excluded.order_status,
        status = excluded.status,
        order_status_label = excluded.order_status_label,
        total_amount = excluded.total_amount,
        gross_amount = excluded.gross_amount,
        paid_amount = excluded.paid_amount,
        order_created_at = excluded.order_created_at,
        created_time = excluded.created_time,
        paid_at = excluded.paid_at,
        pulled_at = now(),
        raw_order = coalesce(public.marketplace_orders.raw_order, '{}'::jsonb) || excluded.raw_order,
        updated_at = now()
      returning 1
    )
    select count(*) into v_done from upserted;

    update public.marketplace_historical_finalize_jobs
    set
      orders_upserted = case
        when v_done = 0 then total_orders
        else least(total_orders, orders_upserted + v_done)
      end,
      phase = case when v_done = 0 then 'items' else 'orders' end,
      updated_at = now()
    where marketplace_historical_finalize_job_id = p_job_id;

    return public.marketplace_historical_finalize_job_status(p_job_id);
  end if;

  if v_job.phase = 'items' then
    with item_rows as (
      select
        a.tenant_id,
        a.marketplace_account_id,
        a.marketplace,
        mo.marketplace_order_id,
        r.marketplace_order_sn,
        r.marketplace_export_import_row_id,
        coalesce(r.row_index, 0)::integer as row_index,
        nullif(r.marketplace_sku, '') as seller_sku,
        coalesce(r.quantity, 1) as qty,
        coalesce(r.total_amount, 0) as amount,
        r.raw_row,
        r.normalized_row,
        r.order_status
      from public.marketplace_export_import_batches b
      join public.marketplace_export_import_rows r
        on r.batch_id = b.marketplace_export_import_batch_id
      join public.marketplace_accounts a
        on a.marketplace_account_id = b.marketplace_account_id
      left join public.marketplace_orders mo
        on mo.marketplace = a.marketplace
       and mo.marketplace_account_id = a.marketplace_account_id
       and mo.order_sn = r.marketplace_order_sn
      where a.marketplace_account_id = v_job.marketplace_account_id
        and coalesce(r.row_index, 0) > coalesce(v_job.last_item_row_index, 0)
        and nullif(r.marketplace_order_sn, '') is not null
      order by coalesce(r.row_index, 0)
      limit v_limit
    ),
    stats as (
      select
        count(*)::int as processed_rows,
        coalesce(max(row_index), coalesce(v_job.last_item_row_index, 0))::int as max_row_index
      from item_rows
    ),
    upserted_items as (
      insert into public.marketplace_order_items(
        tenant_id,
        marketplace_account_id,
        marketplace_order_id,
        marketplace,
        order_sn,
        external_order_id,
        external_order_item_id,
        marketplace_seller_sku,
        seller_sku,
        marketplace_sku,
        marketplace_sku_id,
        local_sku,
        qty,
        quantity,
        scanned_qty,
        scan_status,
        stock_action_status,
        gross_amount,
        paid_amount,
        unit_gross_amount,
        unit_paid_amount,
        raw_item,
        created_at,
        updated_at
      )
      select
        tenant_id,
        marketplace_account_id,
        marketplace_order_id,
        marketplace,
        marketplace_order_sn,
        marketplace_order_sn,
        marketplace_export_import_row_id::text,
        seller_sku,
        seller_sku,
        seller_sku,
        seller_sku,
        seller_sku,
        qty,
        qty,
        0,
        case
          when lower(coalesce(order_status, '')) ~ '(batal|cancel|dibatalkan)' then 'cancelled'
          else 'waiting_scan'
        end,
        case
          when lower(coalesce(order_status, '')) ~ '(batal|cancel|dibatalkan)' then 'cancelled'
          else 'pending'
        end,
        amount,
        case
          when lower(coalesce(order_status, '')) ~ '(batal|cancel|dibatalkan|belum bayar|belum dibayar|unpaid)' then 0
          else amount
        end,
        case when qty = 0 then 0 else amount / nullif(qty, 0) end,
        case
          when lower(coalesce(order_status, '')) ~ '(batal|cancel|dibatalkan|belum bayar|belum dibayar|unpaid)' then 0
          when qty = 0 then 0
          else amount / nullif(qty, 0)
        end,
        jsonb_build_object(
          'source', 'historical_export_import',
          'raw_row', raw_row,
          'normalized_row', normalized_row
        ),
        now(),
        now()
      from item_rows
      where marketplace_order_id is not null
      on conflict (tenant_id, marketplace_account_id, external_order_id, external_order_item_id) do update set
        marketplace_order_id = excluded.marketplace_order_id,
        marketplace_seller_sku = excluded.marketplace_seller_sku,
        seller_sku = excluded.seller_sku,
        marketplace_sku = excluded.marketplace_sku,
        marketplace_sku_id = excluded.marketplace_sku_id,
        local_sku = excluded.local_sku,
        qty = excluded.qty,
        quantity = excluded.quantity,
        scan_status = excluded.scan_status,
        stock_action_status = excluded.stock_action_status,
        gross_amount = excluded.gross_amount,
        paid_amount = excluded.paid_amount,
        unit_gross_amount = excluded.unit_gross_amount,
        unit_paid_amount = excluded.unit_paid_amount,
        raw_item = excluded.raw_item,
        updated_at = now()
      returning 1
    )
    select processed_rows, max_row_index
      into v_done, v_last_item_row_index
    from stats;

    update public.marketplace_historical_finalize_jobs
    set
      items_upserted = case
        when v_done = 0 then total_items
        else least(total_items, items_upserted + v_done)
      end,
      last_item_row_index = greatest(coalesce(last_item_row_index, 0), coalesce(v_last_item_row_index, 0)),
      phase = case when v_done = 0 then 'finance' else 'items' end,
      updated_at = now()
    where marketplace_historical_finalize_job_id = p_job_id;

    return public.marketplace_historical_finalize_job_status(p_job_id);
  end if;

  if v_job.phase = 'finance' then
    with finance_keys as (
      select
        a.tenant_id,
        a.marketplace_account_id,
        a.marketplace,
        a.shop_id,
        a.shop_region,
        r.marketplace_order_sn as order_sn,
        min(r.row_index) as first_row_index
      from public.marketplace_finance_export_import_batches b
      join public.marketplace_finance_export_import_rows r
        on r.batch_id = b.marketplace_finance_export_import_batch_id
      join public.marketplace_accounts a
        on a.marketplace_account_id = b.marketplace_account_id
      left join public.marketplace_finance_reports fr
        on fr.tenant_id = a.tenant_id
       and fr.marketplace = a.marketplace
       and fr.order_id = r.marketplace_order_sn
      where a.marketplace_account_id = v_job.marketplace_account_id
        and nullif(r.marketplace_order_sn, '') is not null
        and fr.marketplace_finance_report_id is null
      group by
        a.tenant_id,
        a.marketplace_account_id,
        a.marketplace,
        a.shop_id,
        a.shop_region,
        r.marketplace_order_sn
      order by min(r.row_index)
      limit v_limit
    ),
    finance_order as (
      select
        k.tenant_id,
        k.marketplace_account_id,
        k.marketplace,
        k.shop_id,
        k.shop_region,
        k.order_sn,
        sum(coalesce(r.payout_amount, 0)) as payout_amount,
        sum(coalesce(r.fee_amount, 0)) as fee_amount,
        sum(
          case
            when k.marketplace = 'tiktok_shop' and abs(coalesce(r.adjustment_amount, 0)) > 1000000000 then 0
            else coalesce(r.adjustment_amount, 0)
          end
        ) as adjustment_amount,
        max(r.settlement_at)::date as settlement_date,
        count(*) as finance_rows,
        jsonb_build_object(
          'source', 'historical_finance_income_import',
          'finance_rows', count(*)
        ) as raw_finance
      from finance_keys k
      join public.marketplace_finance_export_import_batches b
        on b.marketplace_account_id = k.marketplace_account_id
      join public.marketplace_finance_export_import_rows r
        on r.batch_id = b.marketplace_finance_export_import_batch_id
       and r.marketplace_order_sn = k.order_sn
      group by
        k.tenant_id,
        k.marketplace_account_id,
        k.marketplace,
        k.shop_id,
        k.shop_region,
        k.order_sn
    ),
    finance_joined as (
      select
        f.*,
        mo.marketplace_order_id,
        coalesce(mo.gross_amount, mo.total_amount, 0) as order_gross_amount
      from finance_order f
      left join public.marketplace_orders mo
        on mo.tenant_id = f.tenant_id
       and mo.marketplace_account_id = f.marketplace_account_id
       and mo.marketplace = f.marketplace
       and mo.order_sn = f.order_sn
    ),
    upserted_finance as (
      insert into public.marketplace_finance_reports(
        tenant_id,
        marketplace_account_id,
        marketplace,
        shop_id,
        shop_region,
        report_type,
        period_start,
        period_end,
        total_orders,
        gross_sales,
        gross_amount,
        received_amount,
        net_settlement,
        payout_amount,
        total_fees,
        fee_amount,
        platform_fee,
        adjustment_amount,
        total_refund,
        refund_amount,
        total_hpp,
        estimated_profit,
        currency,
        status,
        settlement_status,
        settlement_date,
        order_id,
        marketplace_order_id,
        statement_id,
        raw_finance,
        raw_report,
        raw_response,
        pulled_at,
        note,
        created_at,
        updated_at
      )
      select
        tenant_id,
        marketplace_account_id,
        marketplace,
        shop_id,
        shop_region,
        'order_settlement',
        coalesce(settlement_date, now()::date),
        coalesce(settlement_date, now()::date),
        1,
        order_gross_amount,
        order_gross_amount,
        payout_amount,
        payout_amount,
        payout_amount,
        abs(fee_amount),
        fee_amount,
        abs(fee_amount),
        adjustment_amount,
        0,
        0,
        0,
        0,
        'IDR',
        'pulled',
        'historical_import',
        settlement_date,
        order_sn,
        marketplace_order_id,
        'historical:' || marketplace || ':' || marketplace_account_id::text || ':' || order_sn,
        raw_finance,
        raw_finance,
        raw_finance,
        now(),
        'Imported from marketplace income/payout export staging',
        now(),
        now()
      from finance_joined
      on conflict (tenant_id, marketplace, order_id) do update set
        marketplace_account_id = excluded.marketplace_account_id,
        marketplace_order_id = excluded.marketplace_order_id,
        gross_sales = excluded.gross_sales,
        gross_amount = excluded.gross_amount,
        received_amount = excluded.received_amount,
        net_settlement = excluded.net_settlement,
        payout_amount = excluded.payout_amount,
        total_fees = excluded.total_fees,
        fee_amount = excluded.fee_amount,
        platform_fee = excluded.platform_fee,
        adjustment_amount = excluded.adjustment_amount,
        settlement_status = excluded.settlement_status,
        settlement_date = excluded.settlement_date,
        raw_finance = excluded.raw_finance,
        raw_report = excluded.raw_report,
        raw_response = excluded.raw_response,
        pulled_at = now(),
        updated_at = now()
      returning 1
    )
    select count(*) into v_done from upserted_finance;

    update public.marketplace_historical_finalize_jobs
    set
      finance_reports_upserted = case
        when v_done = 0 then total_finance_orders
        else least(total_finance_orders, finance_reports_upserted + v_done)
      end,
      phase = case when v_done = 0 then 'finalizing' else 'finance' end,
      updated_at = now()
    where marketplace_historical_finalize_job_id = p_job_id;

    return public.marketplace_historical_finalize_job_status(p_job_id);
  end if;

  if v_job.phase = 'finalizing' then
    update public.marketplace_export_import_batches
    set
      status = 'finalized',
      finalized_at = coalesce(finalized_at, now()),
      updated_at = now()
    where marketplace_account_id = v_job.marketplace_account_id;

    update public.marketplace_finance_export_import_batches
    set
      status = 'finalized',
      finalized_at = coalesce(finalized_at, now()),
      updated_at = now()
    where marketplace_account_id = v_job.marketplace_account_id;

    update public.marketplace_order_sync_state
    set
      bootstrap_status = 'complete',
      bootstrap_cursor_seconds = v_now_epoch,
      bootstrap_to_seconds = v_now_epoch,
      recent_cursor_seconds = v_now_epoch,
      last_mode = 'historical_export_import_finalized_to_live',
      last_error = null,
      failure_count = 0,
      locked_until = null,
      lock_token = null,
      next_run_at = now(),
      updated_at = now()
    where marketplace_account_id = v_job.marketplace_account_id;

    update public.marketplace_finance_sync_state
    set
      finance_status = 'done',
      bootstrap_cursor_date = now()::date,
      bootstrap_to_date = now()::date,
      recent_cursor_date = now()::date,
      last_mode = 'historical_income_export_finalized_to_live',
      last_error = null,
      failure_count = 0,
      locked_until = null,
      next_run_at = now(),
      updated_at = now()
    where marketplace_account_id = v_job.marketplace_account_id;

    update public.marketplace_historical_finalize_jobs
    set
      status = 'done',
      phase = 'done',
      finished_at = now(),
      updated_at = now()
    where marketplace_historical_finalize_job_id = p_job_id;

    return public.marketplace_historical_finalize_job_status(p_job_id);
  end if;

  update public.marketplace_historical_finalize_jobs
  set
    status = 'error',
    last_error = 'Unknown finalize phase: ' || coalesce(phase, '-'),
    updated_at = now()
  where marketplace_historical_finalize_job_id = p_job_id;

  return public.marketplace_historical_finalize_job_status(p_job_id);

exception when others then
  update public.marketplace_historical_finalize_jobs
  set
    status = 'error',
    last_error = sqlerrm,
    updated_at = now()
  where marketplace_historical_finalize_job_id = p_job_id;

  return jsonb_build_object(
    'ok', false,
    'job_id', p_job_id,
    'status', 'error',
    'message', 'Finalisasi gagal: ' || sqlerrm,
    'sqlstate', sqlstate
  );
end;
$$;

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
