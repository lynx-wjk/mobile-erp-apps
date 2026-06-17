-- Historical marketplace staging -> live mapper.
-- Safe server-side mapper for staged order export + income/payout export.
-- Does not depend on Flutter staying open. Because apparently phones enjoy fainting during uploads.

begin;

create extension if not exists pgcrypto;

create or replace function public.marketplace_import_parse_tiktok_mmdd_ts(p_value text)
returns timestamptz
language plpgsql
stable
as $$
declare
  v text;
  d1 int;
  d2 int;
  y int;
  hh int := 0;
  mi int := 0;
  ss int := 0;
  ampm text;
  t text;
  m text[];
begin
  if p_value is null then
    return null;
  end if;

  v := btrim(p_value);
  if v = '' then
    return null;
  end if;

  v := regexp_replace(v, '\s+', ' ', 'g');

  if v ~ '^[0-9]{1,2}/[0-9]{1,2}/[0-9]{4}' then
    m := regexp_match(v, '^([0-9]{1,2})/([0-9]{1,2})/([0-9]{4})(.*)$');
    if m is null then
      return null;
    end if;

    -- TikTok export uses MM/DD/YYYY for this uploaded export.
    d1 := m[1]::int; -- month
    d2 := m[2]::int; -- day
    y := m[3]::int;
    t := btrim(coalesce(m[4], ''));

    if t <> '' then
      m := regexp_match(t, '([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}))?\s*([AaPp][Mm])?');
      if m is not null then
        hh := m[1]::int;
        mi := m[2]::int;
        ss := coalesce(nullif(m[3], ''), '0')::int;
        ampm := upper(coalesce(m[4], ''));

        if ampm = 'PM' and hh < 12 then
          hh := hh + 12;
        elsif ampm = 'AM' and hh = 12 then
          hh := 0;
        end if;
      end if;
    end if;

    return make_timestamptz(y, d1, d2, hh, mi, ss, 'UTC');
  end if;

  return public.marketplace_import_text_ts(v);
exception when others then
  return null;
end;
$$;

create or replace function public.marketplace_historical_staging_repair_tiktok_dates()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_before_bad integer := 0;
  v_after_bad integer := 0;
  v_updated integer := 0;
begin
  select count(*) into v_before_bad
  from public.marketplace_export_import_rows r
  join public.marketplace_export_import_batches b
    on b.marketplace_export_import_batch_id = r.batch_id
  where b.marketplace = 'tiktok_shop'
    and (
      r.order_created_at is null
      or r.order_created_at < timestamptz '2026-03-01 00:00:00+00'
      or r.order_created_at > now() + interval '1 day'
    );

  update public.marketplace_export_import_rows r
  set
    order_created_at = public.marketplace_import_parse_tiktok_mmdd_ts(r.normalized_row->>'order_created_at'),
    normalized_row = r.normalized_row || jsonb_build_object(
      'order_created_at_repaired_by', 'marketplace_import_parse_tiktok_mmdd_ts'
    )
  from public.marketplace_export_import_batches b
  where b.marketplace_export_import_batch_id = r.batch_id
    and b.marketplace = 'tiktok_shop'
    and public.marketplace_import_parse_tiktok_mmdd_ts(r.normalized_row->>'order_created_at') is not null
    and (
      r.order_created_at is null
      or r.order_created_at < timestamptz '2026-03-01 00:00:00+00'
      or r.order_created_at > now() + interval '1 day'
    );

  get diagnostics v_updated = row_count;

  select count(*) into v_after_bad
  from public.marketplace_export_import_rows r
  join public.marketplace_export_import_batches b
    on b.marketplace_export_import_batch_id = r.batch_id
  where b.marketplace = 'tiktok_shop'
    and (
      r.order_created_at is null
      or r.order_created_at < timestamptz '2026-03-01 00:00:00+00'
      or r.order_created_at > now() + interval '1 day'
    );

  return jsonb_build_object(
    'ok', v_after_bad = 0,
    'bad_before', v_before_bad,
    'updated_rows', v_updated,
    'bad_after', v_after_bad
  );
end;
$$;

create or replace function public.marketplace_historical_staging_to_live(
  p_marketplace text default null,
  p_apply boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_marketplace text := public.marketplace_normalize_key(p_marketplace);
  v_repair jsonb;
  v_bad_dates integer := 0;
  v_order_upserted integer := 0;
  v_item_upserted integer := 0;
  v_finance_upserted integer := 0;
  v_order_batch_done integer := 0;
  v_finance_batch_done integer := 0;
  v_now_epoch bigint := extract(epoch from now())::bigint;
  v_summary jsonb;
begin
  v_repair := public.marketplace_historical_staging_repair_tiktok_dates();

  select count(*) into v_bad_dates
  from public.marketplace_export_import_rows r
  join public.marketplace_export_import_batches b
    on b.marketplace_export_import_batch_id = r.batch_id
  join public.marketplace_accounts a
    on a.marketplace_account_id = b.marketplace_account_id
  where a.status = 'active'
    and a.marketplace in ('shopee', 'tiktok_shop')
    and (v_marketplace is null or a.marketplace = v_marketplace)
    and nullif(r.marketplace_order_sn, '') is not null
    and (
      r.order_created_at is null
      or r.order_created_at < timestamptz '2026-03-01 00:00:00+00'
      or r.order_created_at > now() + interval '1 day'
    );

  if v_bad_dates > 0 then
    raise exception 'historical mapper blocked: % staging order rows still have invalid order_created_at', v_bad_dates;
  end if;

  if not p_apply then
    select jsonb_build_object(
      'ok', true,
      'apply', false,
      'repair', v_repair,
      'order_staging', (
        select coalesce(jsonb_agg(x order by x->>'marketplace'), '[]'::jsonb)
        from (
          select jsonb_build_object(
            'marketplace', a.marketplace,
            'item_rows', count(*),
            'unique_orders', count(distinct r.marketplace_order_sn),
            'gross_sum_rows', sum(coalesce(r.total_amount, 0)),
            'gross_sum_unique_order_max', sum(max_amount)
          ) as x
          from (
            select
              b.marketplace_account_id,
              r.marketplace_order_sn,
              count(*) as row_count,
              max(coalesce(r.total_amount, 0)) as max_amount
            from public.marketplace_export_import_rows r
            join public.marketplace_export_import_batches b
              on b.marketplace_export_import_batch_id = r.batch_id
            where nullif(r.marketplace_order_sn, '') is not null
            group by b.marketplace_account_id, r.marketplace_order_sn
          ) g
          join public.marketplace_accounts a
            on a.marketplace_account_id = g.marketplace_account_id
          join public.marketplace_export_import_rows r
            on r.marketplace_order_sn = g.marketplace_order_sn
          join public.marketplace_export_import_batches b
            on b.marketplace_export_import_batch_id = r.batch_id
           and b.marketplace_account_id = a.marketplace_account_id
          where a.status = 'active'
            and a.marketplace in ('shopee', 'tiktok_shop')
            and (v_marketplace is null or a.marketplace = v_marketplace)
          group by a.marketplace
        ) s
      ),
      'finance_staging', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'marketplace', a.marketplace,
          'finance_rows', t.finance_rows,
          'unique_orders', t.unique_orders,
          'payout_sum', t.payout_sum,
          'matched_orders', t.matched_orders
        ) order by a.marketplace), '[]'::jsonb)
        from (
          select
            b.marketplace_account_id,
            count(*) as finance_rows,
            count(distinct nullif(r.marketplace_order_sn, '')) as unique_orders,
            sum(coalesce(r.payout_amount, 0)) as payout_sum,
            count(distinct mo.marketplace_order_id) as matched_orders
          from public.marketplace_finance_export_import_rows r
          join public.marketplace_finance_export_import_batches b
            on b.marketplace_finance_export_import_batch_id = r.batch_id
          left join public.marketplace_orders mo
            on mo.marketplace_account_id = b.marketplace_account_id
           and (
              mo.order_sn = r.marketplace_order_sn
              or mo.external_order_id = r.marketplace_order_sn
              or mo.order_id = r.marketplace_order_sn
           )
          group by b.marketplace_account_id
        ) t
        join public.marketplace_accounts a
          on a.marketplace_account_id = t.marketplace_account_id
        where a.status = 'active'
          and a.marketplace in ('shopee', 'tiktok_shop')
          and (v_marketplace is null or a.marketplace = v_marketplace)
      )
    ) into v_summary;

    return v_summary;
  end if;

  -- 1) Upsert one live order per marketplace order number.
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
        'batch_ids', jsonb_agg(distinct b.marketplace_export_import_batch_id),
        'item_rows', count(*),
        'qty_total', sum(coalesce(r.quantity, 1))
      ) as raw_order
    from public.marketplace_export_import_rows r
    join public.marketplace_export_import_batches b
      on b.marketplace_export_import_batch_id = r.batch_id
    join public.marketplace_accounts a
      on a.marketplace_account_id = b.marketplace_account_id
    where a.status = 'active'
      and a.marketplace in ('shopee', 'tiktok_shop')
      and (v_marketplace is null or a.marketplace = v_marketplace)
      and nullif(r.marketplace_order_sn, '') is not null
    group by
      a.tenant_id,
      a.marketplace_account_id,
      a.marketplace,
      a.shop_id,
      a.shop_region,
      r.marketplace_order_sn
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
  select count(*) into v_order_upserted from upserted;

  -- 2) Upsert one live item per staged item row.
  with item_rows as (
    select
      a.tenant_id,
      a.marketplace_account_id,
      a.marketplace,
      mo.marketplace_order_id,
      r.marketplace_order_sn,
      r.row_index,
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
    where a.status = 'active'
      and a.marketplace in ('shopee', 'tiktok_shop')
      and (v_marketplace is null or a.marketplace = v_marketplace)
      and nullif(r.marketplace_order_sn, '') is not null
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
      marketplace_order_sn || ':' || lpad(row_index::text, 8, '0'),
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
        'normalized_row', normalized_row,
        'row_index', row_index
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
  select count(*) into v_item_upserted from upserted_items;

  -- 3) Upsert finance aggregated per order.
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
        'batch_ids', jsonb_agg(distinct b.marketplace_finance_export_import_batch_id),
        'finance_rows', count(*),
        'guard_note', 'tiktok absurd adjustment_amount over 1B ignored'
      ) as raw_finance
    from public.marketplace_finance_export_import_rows r
    join public.marketplace_finance_export_import_batches b
      on b.marketplace_finance_export_import_batch_id = r.batch_id
    join public.marketplace_accounts a
      on a.marketplace_account_id = b.marketplace_account_id
    where a.status = 'active'
      and a.marketplace in ('shopee', 'tiktok_shop')
      and (v_marketplace is null or a.marketplace = v_marketplace)
      and nullif(r.marketplace_order_sn, '') is not null
    group by
      a.tenant_id,
      a.marketplace_account_id,
      a.marketplace,
      a.shop_id,
      a.shop_region,
      r.marketplace_order_sn
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
  select count(*) into v_finance_upserted from upserted_finance;

  update public.marketplace_export_import_batches b
  set
    status = 'finalized',
    finalized_at = now(),
    validation_result = coalesce(validation_result, '{}'::jsonb) || jsonb_build_object(
      'finalized_by', 'marketplace_historical_staging_to_live',
      'finalized_at', now()
    ),
    updated_at = now()
  from public.marketplace_accounts a
  where a.marketplace_account_id = b.marketplace_account_id
    and a.status = 'active'
    and a.marketplace in ('shopee', 'tiktok_shop')
    and (v_marketplace is null or a.marketplace = v_marketplace);

  get diagnostics v_order_batch_done = row_count;

  update public.marketplace_finance_export_import_batches b
  set
    status = 'finalized',
    finalized_at = now(),
    validation_result = coalesce(validation_result, '{}'::jsonb) || jsonb_build_object(
      'finalized_by', 'marketplace_historical_staging_to_live',
      'finalized_at', now()
    ),
    updated_at = now()
  from public.marketplace_accounts a
  where a.marketplace_account_id = b.marketplace_account_id
    and a.status = 'active'
    and a.marketplace in ('shopee', 'tiktok_shop')
    and (v_marketplace is null or a.marketplace = v_marketplace);

  get diagnostics v_finance_batch_done = row_count;

  update public.marketplace_order_sync_state s
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
  from public.marketplace_accounts a
  where a.marketplace_account_id = s.marketplace_account_id
    and a.status = 'active'
    and a.marketplace in ('shopee', 'tiktok_shop')
    and (v_marketplace is null or a.marketplace = v_marketplace);

  update public.marketplace_finance_sync_state s
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
  from public.marketplace_accounts a
  where a.marketplace_account_id = s.marketplace_account_id
    and a.status = 'active'
    and a.marketplace in ('shopee', 'tiktok_shop')
    and (v_marketplace is null or a.marketplace = v_marketplace);

  return jsonb_build_object(
    'ok', true,
    'apply', true,
    'repair', v_repair,
    'orders_upserted', v_order_upserted,
    'items_upserted', v_item_upserted,
    'finance_reports_upserted', v_finance_upserted,
    'order_batches_finalized', v_order_batch_done,
    'finance_batches_finalized', v_finance_batch_done,
    'cursor_seconds', v_now_epoch
  );
end;
$$;

grant execute on function public.marketplace_import_parse_tiktok_mmdd_ts(text) to authenticated, service_role;
grant execute on function public.marketplace_historical_staging_repair_tiktok_dates() to authenticated, service_role;
grant execute on function public.marketplace_historical_staging_to_live(text, boolean) to authenticated, service_role;

notify pgrst, 'reload schema';

commit;
