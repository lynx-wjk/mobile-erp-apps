create index if not exists idx_mfr_fast_account_order_marketplace
on public.marketplace_finance_reports (marketplace_account_id, order_id, marketplace)
include (payout_amount, received_amount, net_settlement, period_start);

create index if not exists idx_mo_fast_order_date_account_marketplace
on public.marketplace_orders (order_created_at, marketplace_account_id, marketplace);

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
security definer
set search_path = public
as $$
declare
  v_start date := coalesce(p_start, date_trunc('month', now() at time zone 'Asia/Jakarta')::date);
  v_end date := coalesce(p_end, (now() at time zone 'Asia/Jakarta')::date);
  v_start_ts timestamptz := (v_start::timestamp at time zone 'Asia/Jakarta');
  v_end_ts timestamptz := ((v_end + 1)::timestamp at time zone 'Asia/Jakarta');
  v_marketplace_norm text := public._finance_marketplace_norm_20260624(p_marketplace);

  v_daily jsonb := '[]'::jsonb;
  v_breakdown jsonb := '[]'::jsonb;

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
  order_base as (
    select
      (o.order_created_at at time zone 'Asia/Jakarta')::date as d,
      o.marketplace_account_id,
      case
        when public._finance_marketplace_norm_20260624(o.marketplace) = 'tiktok' then 'tiktok_shop'
        when public._finance_marketplace_norm_20260624(o.marketplace) = 'shopee' then 'shopee'
        else public._finance_marketplace_norm_20260624(o.marketplace)
      end as marketplace_key,
      coalesce(
        nullif(to_jsonb(o)->>'order_id', ''),
        nullif(to_jsonb(o)->>'order_sn', ''),
        nullif(to_jsonb(o)->>'marketplace_order_id', ''),
        nullif(to_jsonb(o)->>'external_order_id', '')
      ) as order_key,
      coalesce(o.gross_amount, 0)::numeric as gross_amount
    from public.marketplace_orders o
    where o.order_created_at >= v_start_ts
      and o.order_created_at < v_end_ts
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and (
        v_marketplace_norm = ''
        or public._finance_marketplace_norm_20260624(o.marketplace) = v_marketplace_norm
      )
      and upper(coalesce(o.order_status, o.status, '')) not in (
        'CANCELLED', 'CANCELED', 'REFUND', 'RETURN', 'RETURNED'
      )
  ),
  orders_daily as (
    select
      d,
      count(*)::integer as order_count,
      coalesce(sum(gross_amount), 0)::numeric as omzet_total
    from order_base
    group by d
  ),
  finance_by_order as (
    select
      ob.d,
      ob.marketplace_key,
      ob.marketplace_account_id,
      ob.order_key,
      max(coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0))::numeric as payout_amount
    from order_base ob
    left join public.marketplace_finance_reports fr
      on fr.marketplace_account_id = ob.marketplace_account_id
     and fr.order_id = ob.order_key
    where ob.order_key is not null
    group by ob.d, ob.marketplace_key, ob.marketplace_account_id, ob.order_key
  ),
  finance_daily as (
    select
      d,
      coalesce(sum(payout_amount), 0)::numeric as payout_total,
      coalesce(sum(abs(payout_amount)) filter (where payout_amount < 0), 0)::numeric as negative_payout_abs,
      count(*) filter (where payout_amount < 0)::integer as abnormal_count
    from finance_by_order
    group by d
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
  ),
  breakdown_orders as (
    select
      marketplace_key,
      count(*)::integer as order_count,
      coalesce(sum(gross_amount), 0)::numeric as omzet_total
    from order_base
    group by marketplace_key
  ),
  breakdown_finance as (
    select
      marketplace_key,
      coalesce(sum(payout_amount), 0)::numeric as payout_total,
      coalesce(sum(abs(payout_amount)) filter (where payout_amount < 0), 0)::numeric as negative_payout_abs,
      count(*) filter (where payout_amount < 0)::integer as abnormal_count
    from finance_by_order
    group by marketplace_key
  ),
  breakdown as (
    select
      bo.marketplace_key,
      case
        when bo.marketplace_key = 'tiktok_shop' then 'TikTok Shop'
        when bo.marketplace_key = 'shopee' then 'Shopee'
        else initcap(replace(bo.marketplace_key, '_', ' '))
      end as marketplace_label,
      bo.order_count,
      bo.omzet_total,
      coalesce(bf.payout_total, 0)::numeric as payout_total,
      0::numeric as hpp_total,
      coalesce(bf.payout_total, 0)::numeric as net_profit,
      case
        when coalesce(bf.payout_total, 0) > 0 then 100::numeric
        else 0::numeric
      end as margin_percent,
      coalesce(bf.negative_payout_abs, 0)::numeric as negative_payout_abs,
      coalesce(bf.abnormal_count, 0)::integer as abnormal_count
    from breakdown_orders bo
    left join breakdown_finance bf on bf.marketplace_key = bo.marketplace_key
    where coalesce(bo.marketplace_key, '') <> ''
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
      'marketplace_breakdown_fixed', true
    ) order by d), '[]'::jsonb)
  into
    v_omzet,
    v_order_count,
    v_payout,
    v_negative_payout_abs,
    v_abnormal_count,
    v_daily
  from daily;

  select coalesce(jsonb_agg(jsonb_build_object(
    'marketplace', marketplace_key,
    'marketplace_name', marketplace_label,
    'marketplace_label', marketplace_label,
    'account_name', 'Semua toko',
    'store_name', 'Semua toko',
    'omzet_total', omzet_total,
    'gross_sales', omzet_total,
    'gross_amount', omzet_total,
    'order_count', order_count,
    'orders_count', order_count,
    'payout_total', payout_total,
    'received_amount', payout_total,
    'net_settlement', payout_total,
    'hpp_total', hpp_total,
    'total_hpp', hpp_total,
    'net_profit', net_profit,
    'profit_netto', net_profit,
    'laba', net_profit,
    'margin_percent', margin_percent,
    'net_margin_percent', margin_percent,
    'negative_payout_total_abs', negative_payout_abs,
    'abnormal_count', abnormal_count
  ) order by marketplace_key), '[]'::jsonb)
  into v_breakdown
  from breakdown;

  v_net_profit := v_payout - v_hpp - v_expense;
  v_net_margin := case when v_payout > 0 then (v_net_profit / v_payout) * 100 else 0 end;

  return jsonb_build_object(
    'ok', true,
    'source', 'finance_dashboard_snapshot_fast_marketplace_breakdown_20260624',
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
    'marketplace_breakdown', v_breakdown,
    'by_marketplace', v_breakdown,
    'by_sku', '[]'::jsonb,
    'sku_rows', '[]'::jsonb,

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
      'marketplace_breakdown_fixed', true
    )
  );
end $$;

grant execute on function public.finance_dashboard_snapshot(date,date,text,uuid)
  to anon, authenticated, service_role;

notify pgrst, 'reload schema';