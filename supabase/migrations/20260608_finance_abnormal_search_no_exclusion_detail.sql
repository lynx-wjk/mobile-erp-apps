begin;

create or replace function public.finance_abnormal_search_v24_6_82e(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null,
  p_search text default null,
  p_status text default null,
  p_page integer default 1,
  p_page_size integer default 20
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_start date := coalesce(p_start, date_trunc('month', now() at time zone 'Asia/Jakarta')::date);
  v_end date := coalesce(p_end, (now() at time zone 'Asia/Jakarta')::date);
  v_marketplace text := lower(nullif(coalesce(p_marketplace, 'all'), ''));
  v_status text := upper(nullif(coalesce(p_status, 'all'), ''));
  v_search text := lower(nullif(btrim(coalesce(p_search, '')), ''));
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_page_size integer := least(greatest(coalesce(p_page_size, 20), 1), 100);
  v_offset integer;
  v_result jsonb;
begin
  if v_marketplace is null then
    v_marketplace := 'all';
  end if;

  if v_status is null then
    v_status := 'ALL';
  end if;

  v_offset := (v_page - 1) * v_page_size;

  with finance_base as (
    select
      fr.*,
      coalesce(fr.raw_finance, fr.raw_report, fr.raw_response, '{}'::jsonb) as raw_payload,
      coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)::numeric as payout_value
    from public.marketplace_finance_reports fr
    where fr.period_start >= v_start
      and fr.period_start <= v_end
      and (v_marketplace = 'all' or lower(coalesce(fr.marketplace, '')) = v_marketplace)
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)::numeric < 0
  ),
  expanded as (
    select
      fb.*,
      mo.order_status as live_order_status,
      mo.status as live_status,
      mo.raw_order->>'status' as live_raw_status,
      mo.tracking_number as live_tracking_number,
      mo.total_amount as live_total_amount,
      mo.gross_amount as live_gross_amount,
      mo.paid_amount as live_paid_amount,
      mo.order_created_at as live_order_created_at,
      tx.sku_tx
    from finance_base fb
    left join public.marketplace_orders mo
      on mo.marketplace_account_id = fb.marketplace_account_id
     and mo.order_id = fb.order_id
    left join lateral (
      select value as sku_tx
      from jsonb_array_elements(
        coalesce(
          fb.raw_payload #> '{data,sku_transactions}',
          fb.raw_payload #> '{sku_transactions}',
          '[]'::jsonb
        )
      )
      limit 1
    ) tx on true
  ),
  scoped as (
    select *
    from expanded e
    where (v_status in ('ALL', 'NEGATIVE_PAYOUT', 'PAYOUT_MINUS') or v_status is null)
      and (
        v_search is null
        or lower(coalesce(e.order_id, '')) like '%' || v_search || '%'
        or lower(coalesce(e.live_tracking_number, '')) like '%' || v_search || '%'
        or lower(coalesce(e.sku_tx->>'sku_name', '')) like '%' || v_search || '%'
        or lower(coalesce(e.sku_tx->>'product_name', '')) like '%' || v_search || '%'
        or lower(coalesce(e.sku_tx->>'statement_id', '')) like '%' || v_search || '%'
      )
  ),
  agg as (
    select
      count(*)::integer as total,
      count(*)::integer as negative_payout_count,
      coalesce(sum(abs(payout_value)), 0)::numeric as negative_payout_total_abs
    from scoped
  ),
  paged as (
    select *
    from scoped
    order by period_start desc, pulled_at desc, order_id desc
    offset v_offset
    limit v_page_size
  ),
  rows_json as (
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'title', order_id,
          'order_id', order_id,
          'order_sn', order_id,
          'external_order_id', order_id,
          'marketplace', marketplace,
          'marketplace_account_id', marketplace_account_id,
          'marketplace_order_id', marketplace_order_id,
          'order_status', coalesce(live_order_status, live_status, live_raw_status, ''),
          'status_order', coalesce(live_order_status, live_status, live_raw_status, ''),
          'live_status', coalesce(live_status, live_order_status, live_raw_status, ''),
          'tracking_number', coalesce(live_tracking_number, ''),
          'resi', coalesce(live_tracking_number, ''),
          'order_created_at', live_order_created_at,
          'order_date', live_order_created_at,
          'created_at', live_order_created_at,
          'date', live_order_created_at,
          'period_start', period_start,
          'period_end', period_end,
          'statement_id', sku_tx->>'statement_id',
          'product_name', sku_tx->>'product_name',
          'variant_name', sku_tx->>'sku_name',
          'marketplace_sku', sku_tx->>'sku_id',
          'sku_marketplace', sku_tx->>'sku_name',
          'qty', coalesce(nullif(sku_tx->>'quantity', '')::numeric, 1),
          'quantity', coalesce(nullif(sku_tx->>'quantity', '')::numeric, 1),
          'gross', coalesce(nullif(gross_amount, 0), nullif(gross_sales, 0), nullif(live_gross_amount, 0), nullif(live_total_amount, 0), 0),
          'gross_amount', coalesce(nullif(gross_amount, 0), nullif(gross_sales, 0), nullif(live_gross_amount, 0), nullif(live_total_amount, 0), 0),
          'payout', payout_value,
          'payout_amount', payout_value,
          'received_amount', payout_value,
          'net_settlement', payout_value,
          'difference_amount', payout_value,
          'hpp_total', coalesce(total_hpp, 0),
          'hpp_per_item', 0,
          'abnormal_status', 'NEGATIVE_PAYOUT',
          'payout_status', 'NEGATIVE_PAYOUT',
          'finance_status', 'NEGATIVE_PAYOUT',
          'message', 'Payout minus berdasarkan raw finance settlement.',
          'abnormal_reason', 'Payout minus dari marketplace settlement.',
          'detail_order_count', 1,
          'source', 'finance_abnormal_search_v24_6_82e_no_exclusion_detail',
          'raw_source', 'marketplace_finance_reports'
        )
      ),
      '[]'::jsonb
    ) as rows
    from paged
  )
  select jsonb_build_object(
    'ok', true,
    'version', 'finance_abnormal_search_v24_6_82e_no_exclusion_detail_2026_06_08',
    'page', v_page,
    'page_size', v_page_size,
    'total', agg.total,
    'rows', rows_json.rows,
    'aggregates', jsonb_build_object(
      'total', agg.total,
      'abnormal_count', agg.total,
      'negative_payout_count', agg.negative_payout_count,
      'negative_payout_total_abs', agg.negative_payout_total_abs
    )
  )
  into v_result
  from agg
  cross join rows_json;

  return coalesce(v_result, jsonb_build_object(
    'ok', true,
    'version', 'finance_abnormal_search_v24_6_82e_no_exclusion_detail_2026_06_08',
    'page', v_page,
    'page_size', v_page_size,
    'total', 0,
    'rows', '[]'::jsonb,
    'aggregates', jsonb_build_object(
      'total', 0,
      'abnormal_count', 0,
      'negative_payout_count', 0,
      'negative_payout_total_abs', 0
    )
  ));
end;
$$;

grant execute on function public.finance_abnormal_search_v24_6_82e(
  date,
  date,
  text,
  uuid,
  text,
  text,
  integer,
  integer
) to authenticated, anon, service_role;

commit;