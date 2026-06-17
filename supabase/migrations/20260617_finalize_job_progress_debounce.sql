
begin;

create table if not exists public.marketplace_historical_finalize_jobs (
  marketplace_historical_finalize_job_id uuid primary key default gen_random_uuid(),
  tenant_id uuid null,
  marketplace_account_id uuid not null,
  marketplace text not null,
  shop_name text null,
  status text not null default 'running',
  phase text not null default 'orders',
  total_orders integer not null default 0,
  total_items integer not null default 0,
  total_finance_orders integer not null default 0,
  orders_upserted integer not null default 0,
  items_upserted integer not null default 0,
  finance_reports_upserted integer not null default 0,
  last_error text null,
  started_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  finished_at timestamptz null
);

create index if not exists idx_marketplace_historical_finalize_jobs_account
  on public.marketplace_historical_finalize_jobs(marketplace_account_id, updated_at desc);

update public.marketplace_historical_finalize_jobs j
set status = 'cancelled',
    phase = 'cancelled',
    last_error = 'Cancelled because a newer active finalize job exists for the same account.',
    updated_at = now(),
    finished_at = now()
where j.status in ('running', 'queued')
  and exists (
    select 1
    from public.marketplace_historical_finalize_jobs newer
    where newer.marketplace_account_id = j.marketplace_account_id
      and newer.status in ('running', 'queued')
      and newer.updated_at > j.updated_at
  );

create unique index if not exists uq_marketplace_historical_finalize_jobs_active_account
  on public.marketplace_historical_finalize_jobs(marketplace_account_id)
  where status in ('running', 'queued');

create or replace function public.marketplace_historical_finalize_job_status(p_job_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_job record;
  v_total_work numeric;
  v_done_work numeric;
  v_percent numeric;
begin
  select *
    into v_job
  from public.marketplace_historical_finalize_jobs
  where marketplace_historical_finalize_job_id = p_job_id;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'message', 'Job finalisasi tidak ditemukan.',
      'job_id', p_job_id
    );
  end if;

  v_total_work := greatest(v_job.total_orders + v_job.total_items + v_job.total_finance_orders, 1);
  v_done_work := least(v_job.orders_upserted, v_job.total_orders)
              + least(v_job.items_upserted, v_job.total_items)
              + least(v_job.finance_reports_upserted, v_job.total_finance_orders);
  v_percent := round((v_done_work / v_total_work) * 100, 2);

  return jsonb_build_object(
    'ok', v_job.status <> 'error',
    'job_id', v_job.marketplace_historical_finalize_job_id,
    'marketplace_account_id', v_job.marketplace_account_id,
    'marketplace', v_job.marketplace,
    'shop_name', v_job.shop_name,
    'status', v_job.status,
    'phase', v_job.phase,
    'progress_percent', v_percent,
    'total_orders', v_job.total_orders,
    'total_items', v_job.total_items,
    'total_finance_orders', v_job.total_finance_orders,
    'orders_upserted', v_job.orders_upserted,
    'items_upserted', v_job.items_upserted,
    'finance_reports_upserted', v_job.finance_reports_upserted,
    'last_error', v_job.last_error,
    'started_at', v_job.started_at,
    'updated_at', v_job.updated_at,
    'finished_at', v_job.finished_at
  );
end;
$$;

create or replace function public.marketplace_historical_finalize_start(
  p_account_id uuid,
  p_min_valid_orders integer default 1,
  p_force boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_account record;
  v_repair jsonb;
  v_order_batches int := 0;
  v_finance_batches int := 0;
  v_order_rows int := 0;
  v_finance_rows int := 0;
  v_valid_orders int := 0;
  v_bad_dates int := 0;
  v_total_orders int := 0;
  v_total_items int := 0;
  v_total_finance_orders int := 0;
  v_existing_job_id uuid;
  v_job_id uuid;
  v_lock_ok boolean;
begin
  perform set_config('statement_timeout', '45s', true);
  perform set_config('lock_timeout', '10s', true);

  v_lock_ok := pg_try_advisory_xact_lock(
    hashtextextended('marketplace_historical_finalize_start:' || p_account_id::text, 0)
  );

  if not v_lock_ok then
    select marketplace_historical_finalize_job_id
      into v_existing_job_id
    from public.marketplace_historical_finalize_jobs
    where marketplace_account_id = p_account_id
      and status in ('running', 'queued')
    order by updated_at desc
    limit 1;

    if v_existing_job_id is not null then
      return public.marketplace_historical_finalize_job_status(v_existing_job_id);
    end if;

    return jsonb_build_object(
      'ok', false,
      'message', 'Job finalisasi sedang disiapkan. Coba lagi beberapa detik.',
      'marketplace_account_id', p_account_id
    );
  end if;

  select marketplace_historical_finalize_job_id
    into v_existing_job_id
  from public.marketplace_historical_finalize_jobs
  where marketplace_account_id = p_account_id
    and status in ('running', 'queued')
  order by updated_at desc
  limit 1;

  if v_existing_job_id is not null then
    return public.marketplace_historical_finalize_job_status(v_existing_job_id);
  end if;

  select *
    into v_account
  from public.marketplace_accounts
  where marketplace_account_id = p_account_id
    and status = 'active';

  if not found then
    return jsonb_build_object(
      'ok', false,
      'message', 'Akun marketplace aktif tidak ditemukan.',
      'marketplace_account_id', p_account_id
    );
  end if;

  v_repair := public.marketplace_historical_repair_selected_account_dates(p_account_id);

  select
    count(distinct b.marketplace_export_import_batch_id),
    count(r.*),
    count(distinct nullif(r.marketplace_order_sn, '')),
    count(*) filter (
      where r.order_created_at is null
         or r.order_created_at < timestamptz '2026-03-01 00:00:00+00'
         or r.order_created_at > now() + interval '1 day'
    )
  into
    v_order_batches,
    v_order_rows,
    v_valid_orders,
    v_bad_dates
  from public.marketplace_export_import_batches b
  left join public.marketplace_export_import_rows r
    on r.batch_id = b.marketplace_export_import_batch_id
  where b.marketplace_account_id = p_account_id;

  select
    count(distinct b.marketplace_finance_export_import_batch_id),
    count(r.*)
  into
    v_finance_batches,
    v_finance_rows
  from public.marketplace_finance_export_import_batches b
  left join public.marketplace_finance_export_import_rows r
    on r.batch_id = b.marketplace_finance_export_import_batch_id
  where b.marketplace_account_id = p_account_id;

  if v_order_batches = 0 or v_order_rows = 0 then
    return jsonb_build_object('ok', false, 'message', 'Order export belum masuk staging untuk akun ini.');
  end if;

  if v_finance_batches = 0 or v_finance_rows = 0 then
    return jsonb_build_object('ok', false, 'message', 'Income/Payout export belum masuk staging untuk akun ini.');
  end if;

  if not p_force and v_valid_orders < p_min_valid_orders then
    return jsonb_build_object(
      'ok', false,
      'message', 'Jumlah valid order masih di bawah minimum.',
      'valid_orders', v_valid_orders,
      'min_valid_orders', p_min_valid_orders
    );
  end if;

  if v_bad_dates > 0 then
    return jsonb_build_object(
      'ok', false,
      'message', 'Masih ada tanggal order yang perlu diperbaiki sebelum finalize.',
      'bad_dates', v_bad_dates,
      'repair', v_repair
    );
  end if;

  select count(distinct nullif(r.marketplace_order_sn, ''))
    into v_total_orders
  from public.marketplace_export_import_batches b
  join public.marketplace_export_import_rows r
    on r.batch_id = b.marketplace_export_import_batch_id
  where b.marketplace_account_id = p_account_id;

  select count(*)
    into v_total_items
  from public.marketplace_export_import_batches b
  join public.marketplace_export_import_rows r
    on r.batch_id = b.marketplace_export_import_batch_id
  where b.marketplace_account_id = p_account_id;

  select count(distinct nullif(r.marketplace_order_sn, ''))
    into v_total_finance_orders
  from public.marketplace_finance_export_import_batches b
  join public.marketplace_finance_export_import_rows r
    on r.batch_id = b.marketplace_finance_export_import_batch_id
  where b.marketplace_account_id = p_account_id
    and nullif(r.marketplace_order_sn, '') is not null;

  insert into public.marketplace_historical_finalize_jobs(
    tenant_id,
    marketplace_account_id,
    marketplace,
    shop_name,
    status,
    phase,
    total_orders,
    total_items,
    total_finance_orders
  )
  values (
    v_account.tenant_id,
    v_account.marketplace_account_id,
    v_account.marketplace,
    coalesce(v_account.shop_name, v_account.shop_id::text, '-'),
    'running',
    'orders',
    v_total_orders,
    v_total_items,
    v_total_finance_orders
  )
  returning marketplace_historical_finalize_job_id into v_job_id;

  return public.marketplace_historical_finalize_job_status(v_job_id);
exception
  when unique_violation then
    select marketplace_historical_finalize_job_id
      into v_existing_job_id
    from public.marketplace_historical_finalize_jobs
    where marketplace_account_id = p_account_id
      and status in ('running', 'queued')
    order by updated_at desc
    limit 1;

    if v_existing_job_id is not null then
      return public.marketplace_historical_finalize_job_status(v_existing_job_id);
    end if;

    return jsonb_build_object(
      'ok', false,
      'message', 'Job finalisasi aktif sudah ada, tetapi status job tidak dapat dibaca.',
      'marketplace_account_id', p_account_id
    );
end;
$$;

create or replace function public.marketplace_historical_finalize_process_step(
  p_job_id uuid,
  p_limit integer default 500
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job record;
  v_done int := 0;
  v_limit int := greatest(least(coalesce(p_limit, 500), 1000), 50);
  v_now_epoch bigint := extract(epoch from now())::bigint;
begin
  perform set_config('statement_timeout', '45s', true);
  perform set_config('lock_timeout', '10s', true);

  select *
    into v_job
  from public.marketplace_historical_finalize_jobs
  where marketplace_historical_finalize_job_id = p_job_id
  for update;

  if not found then
    return jsonb_build_object('ok', false, 'message', 'Job finalisasi tidak ditemukan.', 'job_id', p_job_id);
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
      limit v_limit
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
      orders_upserted = case when v_done = 0 then total_orders else least(total_orders, orders_upserted + v_done) end,
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
        nullif(r.marketplace_sku, '') as seller_sku,
        coalesce(r.quantity, 1) as qty,
        coalesce(r.total_amount, 0) as amount,
        r.raw_row,
        r.normalized_row,
        r.order_status
      from public.marketplace_export_import_rows r
      join public.marketplace_export_import_batches b
        on b.marketplace_export_import_batch_id = r.batch_id
      join public.marketplace_accounts a
        on a.marketplace_account_id = b.marketplace_account_id
      join public.marketplace_orders mo
        on mo.marketplace = a.marketplace
       and mo.marketplace_account_id = a.marketplace_account_id
       and mo.order_sn = r.marketplace_order_sn
      left join public.marketplace_order_items existing
        on existing.tenant_id = a.tenant_id
       and existing.marketplace_account_id = a.marketplace_account_id
       and existing.external_order_id = r.marketplace_order_sn
       and existing.external_order_item_id = r.marketplace_export_import_row_id::text
      where a.marketplace_account_id = v_job.marketplace_account_id
        and nullif(r.marketplace_order_sn, '') is not null
        and existing.marketplace_order_item_id is null
      order by r.row_index
      limit v_limit
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
    select count(*) into v_done from upserted_items;

    update public.marketplace_historical_finalize_jobs
    set
      items_upserted = case when v_done = 0 then total_items else least(total_items, items_upserted + v_done) end,
      phase = case when v_done = 0 then 'finance' else 'items' end,
      updated_at = now()
    where marketplace_historical_finalize_job_id = p_job_id;

    return public.marketplace_historical_finalize_job_status(p_job_id);
  end if;

  if v_job.phase = 'finance' then
    with finance_order as (
      select
        a.tenant_id,
        a.marketplace_account_id,
        a.marketplace,
        a.shop_id,
        a.shop_region,
        r.marketplace_order_sn as order_sn,
        sum(coalesce(r.payout_amount, 0)) as payout_amount,
        sum(coalesce(r.fee_amount, 0)) as fee_amount,
        sum(
          case
            when a.marketplace = 'tiktok_shop' and abs(coalesce(r.adjustment_amount, 0)) > 1000000000 then 0
            else coalesce(r.adjustment_amount, 0)
          end
        ) as adjustment_amount,
        max(r.settlement_at)::date as settlement_date,
        count(*) as finance_rows,
        jsonb_build_object(
          'source', 'historical_finance_income_import',
          'finance_rows', count(*)
        ) as raw_finance
      from public.marketplace_finance_export_import_rows r
      join public.marketplace_finance_export_import_batches b
        on b.marketplace_finance_export_import_batch_id = r.batch_id
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
      finance_reports_upserted = case when v_done = 0 then total_finance_orders else least(total_finance_orders, finance_reports_upserted + v_done) end,
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

create or replace function public.marketplace_historical_import_status_snapshot()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'ok', true,
    'accounts',
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'marketplace_account_id', a.marketplace_account_id,
          'marketplace', a.marketplace,
          'shop_name', coalesce(a.shop_name, a.shop_id::text, '-'),
          'order_batches', ob.order_batches,
          'order_finalized_batches', ob.order_finalized_batches,
          'order_rows', orows.order_rows,
          'valid_orders', orows.valid_orders,
          'bad_date_rows', orows.bad_date_rows,
          'finance_batches', fb.finance_batches,
          'finance_finalized_batches', fb.finance_finalized_batches,
          'finance_rows', frows.finance_rows,
          'live_orders', live.live_orders,
          'live_items', live.live_items,
          'live_finance_reports', live.live_finance_reports,
          'active_job', job.job_data,
          'finalize_status',
            case
              when job.job_status = 'running' then 'finalizing'
              when job.job_status = 'error' then 'finalize_error'
              when ob.order_batches = 0 and fb.finance_batches = 0 then 'waiting_order_and_income'
              when ob.order_batches = 0 then 'waiting_order'
              when fb.finance_batches = 0 then 'waiting_income'
              when orows.bad_date_rows > 0 then 'needs_repair'
              when ob.order_batches > 0
                and fb.finance_batches > 0
                and ob.order_finalized_batches = ob.order_batches
                and fb.finance_finalized_batches = fb.finance_batches
                and live.live_orders >= greatest(orows.valid_orders, 1)
                then 'finalized'
              else 'ready_to_finalize'
            end
        )
        order by a.marketplace, coalesce(a.shop_name, a.shop_id::text, '-')
      ),
      '[]'::jsonb
    )
  )
  from public.marketplace_accounts a
  cross join lateral (
    select
      count(*)::int as order_batches,
      count(*) filter (where status = 'finalized')::int as order_finalized_batches
    from public.marketplace_export_import_batches b
    where b.marketplace_account_id = a.marketplace_account_id
  ) ob
  cross join lateral (
    select
      count(r.*)::int as order_rows,
      count(distinct nullif(r.marketplace_order_sn, ''))::int as valid_orders,
      count(*) filter (
        where r.order_created_at is null
           or r.order_created_at < timestamptz '2026-03-01 00:00:00+00'
           or r.order_created_at > now() + interval '1 day'
      )::int as bad_date_rows
    from public.marketplace_export_import_batches b
    left join public.marketplace_export_import_rows r
      on r.batch_id = b.marketplace_export_import_batch_id
    where b.marketplace_account_id = a.marketplace_account_id
  ) orows
  cross join lateral (
    select
      count(*)::int as finance_batches,
      count(*) filter (where status = 'finalized')::int as finance_finalized_batches
    from public.marketplace_finance_export_import_batches b
    where b.marketplace_account_id = a.marketplace_account_id
  ) fb
  cross join lateral (
    select
      count(r.*)::int as finance_rows
    from public.marketplace_finance_export_import_batches b
    left join public.marketplace_finance_export_import_rows r
      on r.batch_id = b.marketplace_finance_export_import_batch_id
    where b.marketplace_account_id = a.marketplace_account_id
  ) frows
  cross join lateral (
    select
      count(distinct o.marketplace_order_id)::int as live_orders,
      count(distinct i.marketplace_order_item_id)::int as live_items,
      count(distinct fr.marketplace_finance_report_id)::int as live_finance_reports
    from public.marketplace_orders o
    left join public.marketplace_order_items i
      on i.marketplace_order_id = o.marketplace_order_id
    left join public.marketplace_finance_reports fr
      on fr.marketplace_account_id = a.marketplace_account_id
    where o.marketplace_account_id = a.marketplace_account_id
  ) live
  left join lateral (
    select
      j.status as job_status,
      public.marketplace_historical_finalize_job_status(j.marketplace_historical_finalize_job_id) as job_data
    from public.marketplace_historical_finalize_jobs j
    where j.marketplace_account_id = a.marketplace_account_id
    order by j.updated_at desc
    limit 1
  ) job on true
  where a.status = 'active'
    and a.marketplace in ('shopee', 'tiktok_shop');
$$;

create or replace function public.marketplace_finalize_export_bootstrap(
  p_account_id uuid,
  p_min_valid_orders integer default 1,
  p_force boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.marketplace_historical_finalize_start(
    p_account_id,
    p_min_valid_orders,
    p_force
  );
end;
$$;

grant execute on function public.marketplace_historical_finalize_job_status(uuid) to authenticated, service_role;
grant execute on function public.marketplace_historical_finalize_start(uuid, integer, boolean) to authenticated, service_role;
grant execute on function public.marketplace_historical_finalize_process_step(uuid, integer) to authenticated, service_role;
grant execute on function public.marketplace_historical_import_status_snapshot() to authenticated, service_role;
grant execute on function public.marketplace_finalize_export_bootstrap(uuid, integer, boolean) to authenticated, service_role;

notify pgrst, 'reload schema';

commit;
