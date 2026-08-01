create or replace function public.finance_dashboard_snapshot_marketplace_core_20260624(
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
begin
  drop table if exists pg_temp.finance_dash_orders_base;
  drop table if exists pg_temp.finance_dash_tiktok_import_dates;
  drop table if exists pg_temp.finance_dash_finance_source;

  create temporary table finance_dash_orders_base on commit drop as
  select
    (o.order_created_at at time zone 'Asia/Jakarta')::date as d,
    case
      when public._finance_marketplace_norm_20260624(o.marketplace) = 'tiktok' then 'tiktok_shop'
      when public._finance_marketplace_norm_20260624(o.marketplace) = 'shopee' then 'shopee'
      else public._finance_marketplace_norm_20260624(o.marketplace)
    end as marketplace_key,
    coalesce(o.gross_amount, 0)::numeric as gross_amount
  from public.marketplace_orders o
  where o.order_created_at >= v_start_ts
    and o.order_created_at < v_end_ts
    and (p_account_id is null or o.marketplace_account_id = p_account_id)
    and (
      coalesce(v_marketplace_norm, '') = ''
      or public._finance_marketplace_norm_20260624(o.marketplace) = v_marketplace_norm
    )
    and upper(coalesce(o.order_status, o.status, '')) not in (
      'CANCELLED', 'CANCELED', 'REFUND', 'RETURN', 'RETURNED'
    );

  create temporary table finance_dash_tiktok_import_dates on commit drop as
  select distinct
    b.marketplace_account_id,
    coalesce(r.settlement_at::date, (r.created_at at time zone 'Asia/Jakarta')::date) as d
  from public.marketplace_finance_export_import_rows r
  join public.marketplace_finance_export_import_batches b
    on b.marketplace_finance_export_import_batch_id = r.batch_id
  where public._finance_marketplace_norm_20260624(b.marketplace) = 'tiktok'
    and lower(coalesce(b.status, '')) in ('finalized','completed','done','imported')
    and coalesce(r.settlement_at::date, (r.created_at at time zone 'Asia/Jakarta')::date) between v_start and v_end
    and (p_account_id is null or b.marketplace_account_id = p_account_id)
    and (coalesce(v_marketplace_norm, '') = '' or v_marketplace_norm = 'tiktok');

  create temporary table finance_dash_finance_source on commit drop as
  -- TikTok source 1: finalized Excel import rows by settlement_at.
  select
    coalesce(r.settlement_at::date, (r.created_at at time zone 'Asia/Jakarta')::date) as d,
    'tiktok_shop'::text as marketplace_key,
    coalesce(sum(r.payout_amount), 0)::numeric as payout_amount
  from public.marketplace_finance_export_import_rows r
  join public.marketplace_finance_export_import_batches b
    on b.marketplace_finance_export_import_batch_id = r.batch_id
  where public._finance_marketplace_norm_20260624(b.marketplace) = 'tiktok'
    and lower(coalesce(b.status, '')) in ('finalized','completed','done','imported')
    and coalesce(r.settlement_at::date, (r.created_at at time zone 'Asia/Jakarta')::date) between v_start and v_end
    and (p_account_id is null or b.marketplace_account_id = p_account_id)
    and (coalesce(v_marketplace_norm, '') = '' or v_marketplace_norm = 'tiktok')
  group by 1, 2

  union all

  -- TikTok source 2: API statement report only for dates not already covered by import.
  select
    coalesce(fr.period_start, (fr.created_at at time zone 'Asia/Jakarta')::date) as d,
    'tiktok_shop'::text as marketplace_key,
    coalesce(sum(fr.received_amount), sum(fr.net_settlement), sum(fr.payout_amount), 0)::numeric as payout_amount
  from public.marketplace_finance_reports fr
  where public._finance_marketplace_norm_20260624(fr.marketplace) = 'tiktok'
    and coalesce(fr.report_type, '') = 'statement'
    and coalesce(fr.period_start, (fr.created_at at time zone 'Asia/Jakarta')::date) between v_start and v_end
    and (p_account_id is null or fr.marketplace_account_id = p_account_id)
    and (coalesce(v_marketplace_norm, '') = '' or v_marketplace_norm = 'tiktok')
    and not exists (
      select 1
      from pg_temp.finance_dash_tiktok_import_dates tid
      where tid.marketplace_account_id = fr.marketplace_account_id
        and tid.d = coalesce(fr.period_start, (fr.created_at at time zone 'Asia/Jakarta')::date)
    )
  group by 1, 2

  union all

  -- Non-TikTok source tetap finance_reports.
  select
    coalesce(fr.period_start, (fr.created_at at time zone 'Asia/Jakarta')::date) as d,
    case
      when public._finance_marketplace_norm_20260624(fr.marketplace) = 'shopee' then 'shopee'
      else public._finance_marketplace_norm_20260624(fr.marketplace)
    end as marketplace_key,
    coalesce(sum(fr.payout_amount), sum(fr.received_amount), sum(fr.net_settlement), 0)::numeric as payout_amount
  from public.marketplace_finance_reports fr
  where public._finance_marketplace_norm_20260624(fr.marketplace) <> 'tiktok'
    and coalesce(fr.period_start, (fr.created_at at time zone 'Asia/Jakarta')::date) between v_start and v_end
    and (p_account_id is null or fr.marketplace_account_id = p_account_id)
    and (
      coalesce(v_marketplace_norm, '') = ''
      or public._finance_marketplace_norm_20260624(fr.marketplace) = v_marketplace_norm
    )
  group by 1, 2;

  with days as (
    select generate_series(v_start, v_end, interval '1 day')::date as d
  ),
  orders_daily as (
    select d, count(*)::integer as order_count, coalesce(sum(gross_amount), 0)::numeric as omzet_total
    from pg_temp.finance_dash_orders_base
    group by d
  ),
  finance_daily as (
    select
      d,
      coalesce(sum(payout_amount), 0)::numeric as payout_total,
      coalesce(sum(abs(payout_amount)) filter (where payout_amount < 0), 0)::numeric as negative_payout_abs,
      count(*) filter (where payout_amount < 0)::integer as abnormal_count
    from pg_temp.finance_dash_finance_source
    group by d
  ),
  daily as (
    select
      days.d,
      coalesce(od.omzet_total, 0)::numeric as omzet_total,
      coalesce(od.order_count, 0)::integer as order_count,
      coalesce(fd.payout_total, 0)::numeric as payout_total,
      coalesce(fd.negative_payout_abs, 0)::numeric as negative_payout_abs,
      coalesce(fd.abnormal_count, 0)::integer as abnormal_count
    from days
    left join orders_daily od on od.d = days.d
    left join finance_daily fd on fd.d = days.d
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
      'tiktok_payout_from_import_settlement_or_statement', true
    ) order by d), '[]'::jsonb)
  into v_omzet, v_order_count, v_payout, v_negative_payout_abs, v_abnormal_count, v_daily
  from daily;

  with order_breakdown as (
    select marketplace_key, count(*)::integer as order_count, coalesce(sum(gross_amount), 0)::numeric as omzet_total
    from pg_temp.finance_dash_orders_base
    group by marketplace_key
  ),
  finance_breakdown as (
    select
      marketplace_key,
      coalesce(sum(payout_amount), 0)::numeric as payout_total,
      coalesce(sum(abs(payout_amount)) filter (where payout_amount < 0), 0)::numeric as negative_payout_abs,
      count(*) filter (where payout_amount < 0)::integer as abnormal_count
    from pg_temp.finance_dash_finance_source
    group by marketplace_key
  ),
  keys as (
    select marketplace_key from order_breakdown
    union
    select marketplace_key from finance_breakdown
  ),
  breakdown as (
    select
      k.marketplace_key,
      case
        when k.marketplace_key = 'tiktok_shop' then 'TikTok Shop'
        when k.marketplace_key = 'shopee' then 'Shopee'
        else initcap(replace(k.marketplace_key, '_', ' '))
      end as marketplace_label,
      coalesce(ob.order_count, 0)::integer as order_count,
      coalesce(ob.omzet_total, 0)::numeric as omzet_total,
      coalesce(fb.payout_total, 0)::numeric as payout_total,
      0::numeric as hpp_total,
      coalesce(fb.payout_total, 0)::numeric as net_profit,
      case when coalesce(fb.payout_total, 0) > 0 then 100::numeric else 0::numeric end as margin_percent,
      coalesce(fb.negative_payout_abs, 0)::numeric as negative_payout_abs,
      coalesce(fb.abnormal_count, 0)::integer as abnormal_count
    from keys k
    left join order_breakdown ob on ob.marketplace_key = k.marketplace_key
    left join finance_breakdown fb on fb.marketplace_key = k.marketplace_key
    where coalesce(k.marketplace_key, '') <> ''
  )
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

  return jsonb_build_object(
    'ok', true,
    'source', 'finance_dashboard_tiktok_import_settlement_or_statement_20260624',
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

    'hpp_total', 0,
    'total_hpp', 0,
    'expense_total', 0,
    'biaya_total', 0,
    'net_profit', v_payout,
    'profit_netto', v_payout,
    'net_margin_percent', case when v_payout > 0 then 100 else 0 end,
    'margin_percent', case when v_payout > 0 then 100 else 0 end,

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
      'hpp_total', 0,
      'expense_total', 0,
      'net_profit', v_payout,
      'net_margin_percent', case when v_payout > 0 then 100 else 0 end,
      'abnormal_count', v_abnormal_count,
      'negative_payout_total_abs', v_negative_payout_abs,
      'tiktok_payout_from_import_settlement_or_statement', true
    )
  );
end $$;

grant execute on function public.finance_dashboard_snapshot_marketplace_core_20260624(date,date,text,uuid)
  to anon, authenticated, service_role;

notify pgrst, 'reload schema';