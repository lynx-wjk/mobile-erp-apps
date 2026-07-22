-- Faster finance dashboard snapshot using direct columns, not to_jsonb extraction per row.
-- Supports marketplace/account filters without timing out.

create index if not exists idx_marketplace_orders_fast_finance_direct
on public.marketplace_orders (order_created_at, marketplace_account_id, marketplace);

create index if not exists idx_marketplace_finance_reports_fast_finance_direct
on public.marketplace_finance_reports (period_start, marketplace_account_id, marketplace);

analyze public.marketplace_orders;
analyze public.marketplace_finance_reports;

create or replace function public.finance_dashboard_snapshot(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null
)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_start date := coalesce(p_start, date_trunc('month', now() at time zone 'Asia/Jakarta')::date);
  v_end date := coalesce(p_end, (now() at time zone 'Asia/Jakarta')::date);
  v_start_ts timestamptz := (coalesce(p_start, date_trunc('month', now() at time zone 'Asia/Jakarta')::date)::timestamp at time zone 'Asia/Jakarta');
  v_end_ts timestamptz := ((coalesce(p_end, (now() at time zone 'Asia/Jakarta')::date) + 1)::timestamp at time zone 'Asia/Jakarta');
  v_marketplace_norm text := public._finance_marketplace_norm_20260624(p_marketplace);

  v_daily jsonb := '[]'::jsonb;
  v_omzet numeric := 0;
  v_order_count integer := 0;
  v_payout numeric := 0;
  v_negative_payout_abs numeric := 0;
  v_abnormal_count integer := 0;
  v_expense numeric := 0;
  v_hpp numeric := 0;
  v_net_profit numeric := 0;
  v_net_margin numeric := 0;
begin
  with days as (
    select generate_series(v_start, v_end, interval '1 day')::date as d
  ),
  orders_daily as (
    select
      (o.order_created_at at time zone 'Asia/Jakarta')::date as d,
      count(*)::integer as order_count,
      coalesce(sum(coalesce(o.gross_amount, 0)), 0)::numeric as omzet_total
    from public.marketplace_orders o
    where o.order_created_at >= v_start_ts
      and o.order_created_at < v_end_ts
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and (
        v_marketplace_norm = ''
        or case
          when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
          when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          else lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g'))
        end = v_marketplace_norm
      )
      and upper(coalesce(o.order_status, o.status, '')) not in (
        'CANCELLED', 'CANCELED', 'REFUND', 'RETURN', 'RETURNED'
      )
    group by 1
  ),
  finance_daily as (
    select
      coalesce(fr.period_start, (fr.created_at at time zone 'Asia/Jakarta')::date) as d,
      coalesce(sum(coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)), 0)::numeric as payout_total,
      coalesce(sum(abs(coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0))) filter (
        where coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0) < 0
      ), 0)::numeric as negative_payout_abs,
      count(*) filter (
        where coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0) < 0
      )::integer as abnormal_count
    from public.marketplace_finance_reports fr
    where coalesce(fr.period_start, (fr.created_at at time zone 'Asia/Jakarta')::date) between v_start and v_end
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and (
        v_marketplace_norm = ''
        or case
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          else lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g'))
        end = v_marketplace_norm
      )
    group by 1
  ),
  daily as (
    select
      d.d,
      coalesce(od.omzet_total, 0)::numeric as omzet_total,
      coalesce(od.order_count, 0)::integer as order_count,
      coalesce(fd.payout_total, 0)::numeric as payout_total,
      coalesce(fd.negative_payout_abs, 0)::numeric as negative_payout_abs,
      coalesce(fd.abnormal_count, 0)::integer as abnormal_count
    from days d
    left join orders_daily od on od.d = d.d
    left join finance_daily fd on fd.d = d.d
  )
  select
    coalesce(sum(omzet_total), 0),
    coalesce(sum(order_count), 0)::integer,
    coalesce(sum(payout_total), 0),
    coalesce(sum(negative_payout_abs), 0),
    coalesce(sum(abnormal_count), 0)::integer,
    coalesce(jsonb_agg(jsonb_build_object(
      'date', to_char(d, 'YYYY-MM-DD'),
      'period_start', to_char(d, 'YYYY-MM-DD'),
      'omzet_total', omzet_total,
      'gross_sales', omzet_total,
      'gross_amount', omzet_total,
      'order_count', order_count,
      'orders_count', order_count,
      'payout_total', payout_total,
      'received_amount', payout_total,
      'net_settlement', payout_total,
      'negative_payout_total_abs', negative_payout_abs,
      'abnormal_count', abnormal_count,
      'fast_snapshot', true,
      'direct_column_snapshot', true
    ) order by d), '[]'::jsonb)
  into
    v_omzet,
    v_order_count,
    v_payout,
    v_negative_payout_abs,
    v_abnormal_count,
    v_daily
  from daily;

  v_net_profit := v_payout - v_hpp - v_expense;
  v_net_margin := case when v_payout > 0 then (v_net_profit / v_payout) * 100 else 0 end;

  return jsonb_build_object(
    'ok', true,
    'source', 'finance_dashboard_snapshot_fast_direct_columns_20260624',
    'start', v_start,
    'end', v_end,
    'marketplace', p_marketplace,
    'marketplace_account_id', p_account_id,
    'generated_at', now(),

    'omzet_total', v_omzet,
    'gross_sales', v_omzet,
    'gross_amount', v_omzet,
    'order_count', v_order_count,
    'orders_count', v_order_count,

    'payout_total', v_payout,
    'received_amount', v_payout,
    'net_settlement', v_payout,

    'hpp_total', v_hpp,
    'total_hpp', v_hpp,
    'expense_total', v_expense,
    'biaya_total', v_expense,
    'net_profit', v_net_profit,
    'profit_netto', v_net_profit,
    'net_margin_percent', v_net_margin,
    'margin_percent', v_net_margin,

    'abnormal_count', v_abnormal_count,
    'negative_payout_total_abs', v_negative_payout_abs,

    'daily', v_daily,
    'by_sku', '[]'::jsonb,
    'sku_rows', '[]'::jsonb,
    'marketplace_breakdown', '[]'::jsonb,

    'summary', jsonb_build_object(
      'omzet_total', v_omzet,
      'gross_sales', v_omzet,
      'gross_amount', v_omzet,
      'order_count', v_order_count,
      'orders_count', v_order_count,
      'payout_total', v_payout,
      'received_amount', v_payout,
      'net_settlement', v_payout,
      'hpp_total', v_hpp,
      'expense_total', v_expense,
      'net_profit', v_net_profit,
      'net_margin_percent', v_net_margin,
      'abnormal_count', v_abnormal_count,
      'negative_payout_total_abs', v_negative_payout_abs,
      'fast_snapshot', true,
      'direct_column_snapshot', true
    )
  );
end $$;

revoke all on function public.finance_dashboard_snapshot(date,date,text,uuid) from public;
grant execute on function public.finance_dashboard_snapshot(date,date,text,uuid) to authenticated, service_role;

notify pgrst, 'reload schema';