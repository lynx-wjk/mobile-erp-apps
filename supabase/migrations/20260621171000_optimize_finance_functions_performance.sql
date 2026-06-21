-- Migration to optimize performance of finance functions.
-- 1. Replaces to_jsonb conversions with direct column references.
-- 2. Constrains finance report queries to scope orders within the target range to avoid full table scans.
-- 3. Implements lightweight hybrid path for finance_dashboard_snapshot when date range is > 31 days.

create or replace function public.finance_marketplace_profit_loss_detail(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null
)
returns jsonb
language sql
stable
security definer
set search_path = public
set statement_timeout = '30s'
as $$
with vars as (
  select
    coalesce(p_start, date_trunc('month', now())::date)::timestamptz as start_ts,
    (coalesce(p_end, now()::date)::date + 1)::timestamptz as end_ts,
    coalesce(public.marketplace_normalize_key(p_marketplace), p_marketplace) as marketplace_filter
),
tenant as (
  select
    case
      when nullif(current_setting('request.jwt.claims', true), '') is null then null::uuid
      else nullif((current_setting('request.jwt.claims', true)::jsonb ->> 'tenant_id'), '')::uuid
    end as tenant_id
),
orders_scoped as (
  select
    o.marketplace_order_id,
    o.tenant_id,
    o.marketplace_account_id,
    o.marketplace,
    o.order_sn,
    o.order_created_at,
    coalesce(o.total_amount, o.gross_amount, o.paid_amount, 0)::numeric as gross_amount,
    lower(coalesce(o.order_status, o.status, '')) as status_text,
    lower(coalesce(o.payment_method, o.payment_status, '')) as payment_text
  from public.marketplace_orders o
  cross join vars v
  cross join tenant t
  where (t.tenant_id is null or o.tenant_id = t.tenant_id)
    and o.marketplace in ('shopee', 'tiktok_shop')
    and (v.marketplace_filter is null or v.marketplace_filter = '' or v.marketplace_filter = 'all' or o.marketplace = v.marketplace_filter)
    and (p_account_id is null or o.marketplace_account_id = p_account_id)
    and o.order_created_at >= v.start_ts
    and o.order_created_at < v.end_ts
    and lower(coalesce(o.order_status, o.status, '')) !~ '(cancel|batal|dibatalkan|unpaid|belum bayar|belum dibayar)'
),
finance_by_order as (
  select
    fr.tenant_id,
    fr.marketplace,
    fr.marketplace_account_id,
    fr.order_id as order_sn,
    count(distinct fr.marketplace_finance_report_id)::integer as finance_rows,
    sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0)::numeric) as payout_amount,
    sum(abs(coalesce(fr.discount_amount, 0)::numeric)) as discount_amount,
    sum(abs(coalesce(fr.platform_fee, 0)::numeric)) as platform_fee,
    sum(abs(coalesce(fr.commission_fee, 0)::numeric)) as commission_fee,
    sum(abs(coalesce(fr.affiliate_fee, 0)::numeric)) as affiliate_fee,
    sum(abs(coalesce(fr.shipping_fee, 0)::numeric)) as shipping_fee,
    sum(abs(coalesce(fr.fee_amount, 0)::numeric)) as fee_amount,
    sum(abs(coalesce(fr.total_fees, 0)::numeric)) as total_fees,
    sum(abs(coalesce(fr.refund_amount, 0)::numeric)) as refund_amount,
    sum(abs(coalesce(fr.adjustment_amount, 0)::numeric)) as adjustment_abs,
    sum(coalesce(fr.adjustment_amount, 0)::numeric) as adjustment_signed
  from public.marketplace_finance_reports fr
  cross join vars v
  cross join tenant t
  where (t.tenant_id is null or fr.tenant_id = t.tenant_id)
    and fr.marketplace in ('shopee', 'tiktok_shop')
    and (v.marketplace_filter is null or v.marketplace_filter = '' or v.marketplace_filter = 'all' or fr.marketplace = v.marketplace_filter)
    and (p_account_id is null or fr.marketplace_account_id = p_account_id)
    and fr.order_id in (select order_sn from orders_scoped) -- SCOPE TO DATES
  group by fr.tenant_id, fr.marketplace, fr.marketplace_account_id, fr.order_id
),
joined as (
  select
    o.*,
    f.finance_rows,
    coalesce(f.payout_amount, 0) as payout_amount,
    coalesce(f.discount_amount, 0) as discount_amount,
    coalesce(f.platform_fee, 0) as platform_fee,
    coalesce(f.commission_fee, 0) as commission_fee,
    coalesce(f.affiliate_fee, 0) as affiliate_fee,
    coalesce(f.shipping_fee, 0) as shipping_fee,
    greatest(
      greatest(coalesce(f.total_fees, 0), coalesce(f.fee_amount, 0)) -
      (
        coalesce(f.platform_fee, 0)
        + coalesce(f.commission_fee, 0)
        + coalesce(f.affiliate_fee, 0)
        + coalesce(f.shipping_fee, 0)
      ),
      0
    ) as other_fee,
    coalesce(f.refund_amount, 0) as refund_amount,
    coalesce(f.adjustment_abs, 0) as adjustment_amount,
    coalesce(f.adjustment_signed, 0) as adjustment_signed,
    (
      o.gross_amount <= 0
      or o.payment_text ~ '(sample|gratis|free|zero|0 payment|no payment|tester|giveaway)'
      or (o.payment_text = '' and o.gross_amount = 0 and o.status_text ~ '(complete|completed|delivered|selesai|dikirim|done)')
    ) as is_sample_order
  from orders_scoped o
  left join finance_by_order f
    on f.tenant_id = o.tenant_id
   and f.marketplace = o.marketplace
   and f.marketplace_account_id = o.marketplace_account_id
   and f.order_sn = o.order_sn
),
grouped as (
  select
    j.marketplace,
    j.marketplace_account_id,
    coalesce(nullif(a.shop_name, ''), nullif(a.store_alias, ''), j.marketplace) as shop_name,
    count(distinct j.order_sn)::int as order_count,
    count(distinct j.order_sn) filter (where j.finance_rows is not null)::int as matched_finance_count,
    count(distinct j.order_sn) filter (where j.finance_rows is null)::int as unmatched_order_count,
    coalesce(sum(case when j.marketplace = 'tiktok_shop' then j.gross_amount + j.discount_amount else j.gross_amount end), 0) as gross_sales,
    coalesce(sum(j.gross_amount) filter (where j.finance_rows is null), 0) as unmatched_order_gross,
    coalesce(sum(j.payout_amount), 0) as payout_total,
    coalesce(sum(j.discount_amount), 0) as discount_amount,
    coalesce(sum(j.platform_fee), 0) as platform_fee,
    coalesce(sum(j.commission_fee), 0) as commission_fee,
    coalesce(sum(j.affiliate_fee), 0) as affiliate_fee,
    coalesce(sum(j.shipping_fee), 0) as shipping_fee,
    coalesce(sum(j.other_fee), 0) as other_fee,
    coalesce(sum(j.refund_amount), 0) as refund_amount,
    coalesce(sum(j.adjustment_amount), 0) as adjustment_amount,
    count(distinct j.order_sn) filter (where j.is_sample_order)::int as sample_order_count,
    coalesce(sum(abs(j.payout_amount)) filter (where j.is_sample_order and j.payout_amount < 0), 0) as sample_negative_payout_total
  from joined j
  left join public.marketplace_accounts a
    on a.marketplace_account_id = j.marketplace_account_id
  group by j.marketplace, j.marketplace_account_id, coalesce(nullif(a.shop_name, ''), nullif(a.store_alias, ''), j.marketplace)
),
final_rows as (
  select
    *,
    greatest(gross_sales - payout_total, 0) as gross_payout_gap,
    greatest(
      gross_sales - payout_total -
      (
        discount_amount + platform_fee + commission_fee + affiliate_fee + shipping_fee + other_fee
        + refund_amount + adjustment_amount + sample_negative_payout_total
      ),
      0
    ) as unclassified_amount
  from grouped
)
select jsonb_build_object(
  'ok', true,
  'source', 'finance_marketplace_profit_loss_detail_optimized',
  'diagnostic_only', true,
  'description', 'Order-date gross vs payout reconciliation. Not final P&L expense.',
  'rows', coalesce(jsonb_agg(jsonb_build_object(
    'row_kind', 'order_date_reconciliation',
    'diagnostic_only', true,
    'marketplace', marketplace,
    'marketplace_account_id', marketplace_account_id,
    'shop_name', shop_name,
    'account_name', shop_name,
    'order_count', order_count,
    'finance_order_count', matched_finance_count,
    'matched_finance_count', matched_finance_count,
    'unmatched_order_count', unmatched_order_count,
    'unmatched_order_gross', unmatched_order_gross,
    'gross_sales', gross_sales,
    'gross_total', gross_sales,
    'omzet', gross_sales,
    'payout_total', payout_total,
    'payout_amount', payout_total,
    'received_amount', payout_total,
    'gross_payout_gap', gross_payout_gap,
    'gross_minus_payout', gross_payout_gap,
    'selisih_omzet_payout', gross_payout_gap,
    'settlement_unmatched_total', unmatched_order_gross,
    'settlement_belum_final', unmatched_order_gross,
    'discount_amount', discount_amount,
    'platform_fee', platform_fee,
    'commission_fee', commission_fee,
    'affiliate_fee', affiliate_fee,
    'shipping_fee', shipping_fee,
    'other_fee', other_fee,
    'refund_amount', refund_amount,
    'tax_amount', 0,
    'adjustment_amount', adjustment_amount,
    'sample_order_count', sample_order_count,
    'sample_negative_payout_total', sample_negative_payout_total,
    'unclassified_amount', unclassified_amount
  ) order by marketplace, shop_name), '[]'::jsonb)
)
from final_rows;
$$;

grant execute on function public.finance_marketplace_profit_loss_detail(date, date, text, uuid) to authenticated, service_role;


-- Re-define finance_marketplace_reconciliation_breakdown with optimized column queries and scoping.
create or replace function public.finance_marketplace_reconciliation_breakdown(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '120s'
as $$
declare
  v_tenant_id uuid := null;
  v_start timestamptz := case when p_start is null then null else (p_start::timestamp - interval '7 hours')::timestamptz end;
  v_end timestamptz := case when p_end is null then null else ((p_end + 1)::timestamp - interval '7 hours')::timestamptz end;

  v_order_count int := 0;
  v_gross numeric := 0;
  v_payout numeric := 0;
  v_gap numeric := 0;
  v_sample_count int := 0;
  v_sample_hpp numeric := 0;
  v_sample_negative_payout numeric := 0;
  v_sample_loss_estimate numeric := 0;
  v_breakdown jsonb := '[]'::jsonb;
  v_by_marketplace jsonb := '[]'::jsonb;
begin
  begin
    v_tenant_id := nullif(current_setting('request.jwt.claims', true)::jsonb->>'tenant_id', '')::uuid;
  exception when others then
    v_tenant_id := null;
  end;

  with scoped_orders as (
    select
      o.marketplace_order_id,
      o.tenant_id,
      o.marketplace_account_id,
      o.marketplace,
      o.order_created_at,
      coalesce(
        nullif(o.external_order_id, ''),
        nullif(o.order_sn, ''),
        nullif(o.remote_order_id, ''),
        nullif(o.order_id::text, ''),
        o.marketplace_order_id::text
      ) as order_key,
      coalesce(o.gross_amount, o.total_amount, 0)::numeric as gross_amount,
      lower(coalesce(o.payment_method, o.payment_status, '')) as payment_text,
      lower(coalesce(o.order_status, o.status, '')) as status_text
    from public.marketplace_orders o
    where (v_tenant_id is null or o.tenant_id = v_tenant_id)
      and (p_marketplace is null or p_marketplace = '' or p_marketplace = 'all' or o.marketplace = p_marketplace)
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and (v_start is null or o.order_created_at >= v_start)
      and (v_end is null or o.order_created_at < v_end)
  ),
  finance_by_order as (
    select
      fr.tenant_id,
      fr.marketplace_account_id,
      fr.order_id as order_key,
      sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0)::numeric) as payout_amount
    from public.marketplace_finance_reports fr
    where (v_tenant_id is null or fr.tenant_id = v_tenant_id)
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and (p_marketplace is null or p_marketplace = '' or p_marketplace = 'all' or fr.marketplace = p_marketplace)
      and fr.order_id in (select order_key from scoped_orders)
    group by fr.tenant_id, fr.marketplace_account_id, fr.order_id
  ),
  recon_joined as (
    select
      o.marketplace_order_id,
      o.tenant_id,
      o.marketplace_account_id,
      o.marketplace,
      o.order_created_at,
      o.order_key,
      o.gross_amount,
      coalesce(f.payout_amount, 0) as payout_amount,
      (
        o.gross_amount <= 0
        or o.payment_text ~ '(sample|gratis|free|zero|0 payment|no payment|tester|giveaway)'
        or (o.payment_text = '' and o.gross_amount = 0 and o.status_text ~ '(complete|completed|delivered|selesai|dikirim|done)')
      ) as is_sample_order
    from scoped_orders o
    left join finance_by_order f
      on f.tenant_id = o.tenant_id
     and f.marketplace_account_id = o.marketplace_account_id
     and f.order_key = o.order_key
  ),
  sample_hpp as (
    select
      j.marketplace_order_id,
      sum(
        coalesce(i.qty, i.quantity, 1)
        * coalesce(h.hpp, h.hpp_amount, h.hpp_per_item, 0)
      ) as sample_hpp
    from recon_joined j
    join public.marketplace_order_items i
      on i.marketplace_order_id = j.marketplace_order_id
    left join public.marketplace_variant_hpp_mappings h
      on h.marketplace_account_id = i.marketplace_account_id
     and h.marketplace_product_id = i.marketplace_product_id
     and h.marketplace_sku_id = i.marketplace_sku_id
    where j.is_sample_order
    group by j.marketplace_order_id
  ),
  stats as (
    select
      count(*)::int as order_count,
      coalesce(sum(gross_amount), 0) as gross,
      coalesce(sum(payout_amount), 0) as payout,
      count(*) filter (where is_sample_order)::int as sample_count,
      coalesce(sum(coalesce(sh.sample_hpp, 0)) filter (where j.is_sample_order), 0) as sample_hpp,
      coalesce(sum(abs(j.payout_amount)) filter (where j.is_sample_order and j.payout_amount < 0), 0) as sample_negative_payout
    from recon_joined j
    left join sample_hpp sh
      on sh.marketplace_order_id = j.marketplace_order_id
  ),
  marketplace_group as (
    select
      j.marketplace,
      j.marketplace_account_id,
      coalesce(a.shop_name, a.store_alias, to_jsonb(a)->>'seller_name', j.marketplace) as shop_name,
      count(*)::int as order_count,
      coalesce(sum(j.gross_amount), 0) as gross_sales,
      coalesce(sum(j.payout_amount), 0) as payout_total,
      count(*) filter (where j.is_sample_order)::int as sample_order_count,
      coalesce(sum(coalesce(sh.sample_hpp, 0)) filter (where j.is_sample_order), 0) as sample_hpp_total,
      coalesce(sum(abs(j.payout_amount)) filter (where j.is_sample_order and j.payout_amount < 0), 0) as sample_negative_payout_total,
      max(j.order_created_at) as last_updated_at
    from recon_joined j
    left join public.marketplace_accounts a
      on a.marketplace_account_id = j.marketplace_account_id
    left join sample_hpp sh
      on sh.marketplace_order_id = j.marketplace_order_id
    group by j.marketplace, j.marketplace_account_id, coalesce(a.shop_name, a.store_alias, to_jsonb(a)->>'seller_name', j.marketplace)
  ),
  by_mkt as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'marketplace', marketplace,
      'marketplace_account_id', marketplace_account_id,
      'shop_name', shop_name,
      'account_name', shop_name,
      'order_count', order_count,
      'gross_sales', gross_sales,
      'payout_total', payout_total,
      'hpp_total', 0,
      'net_profit', payout_total,
      'profit', payout_total,
      'sample_order_count', sample_order_count,
      'sample_hpp_total', sample_hpp_total,
      'sample_negative_payout_total', sample_negative_payout_total,
      'sample_loss_estimate', sample_hpp_total + sample_negative_payout_total,
      'last_updated_at', last_updated_at
    ) order by marketplace, shop_name), '[]'::jsonb) as by_marketplace
    from marketplace_group
  )
  select
    s.order_count,
    s.gross,
    s.payout,
    s.sample_count,
    s.sample_hpp,
    s.sample_negative_payout,
    bm.by_marketplace
  into
    v_order_count,
    v_gross,
    v_payout,
    v_sample_count,
    v_sample_hpp,
    v_sample_negative_payout,
    v_by_marketplace
  from stats s
  cross join by_mkt bm;

  v_gap := greatest(v_gross - v_payout, 0);
  v_sample_loss_estimate := v_sample_hpp + v_sample_negative_payout;

  v_breakdown := jsonb_build_array(
    jsonb_build_object(
      'label', 'Sample / gratis / pembayaran 0',
      'category', 'sample_zero_payment',
      'description', 'Order sample/gratis/zero payment. Dampak dihitung dari HPP sample and payout minus sample.',
      'amount', v_sample_loss_estimate,
      'hpp_total', v_sample_hpp,
      'negative_payout_total', v_sample_negative_payout,
      'order_count', v_sample_count
    ),
    jsonb_build_object(
      'label', 'Penyesuaian omzet vs payout',
      'category', 'unclassified_adjustment',
      'description', 'Selisih omzet and payout yang belum diklasifikasi detail.',
      'amount', greatest(v_gap - v_sample_loss_estimate, 0),
      'order_count', null
    )
  );

  return jsonb_build_object(
    'ok', true,
    'summary', jsonb_build_object(
      'order_count', v_order_count,
      'finance_order_count', v_order_count,
      'gross_sales', v_gross,
      'payout_total', v_payout,
      'gross_payout_gap', v_gap,
      'sample_order_count', v_sample_count,
      'sample_hpp_total', v_sample_hpp,
      'sample_negative_payout_total', v_sample_negative_payout,
      'sample_loss_estimate', v_sample_loss_estimate
    ),
    'by_marketplace', v_by_marketplace,
    'profit_loss_breakdown', v_breakdown,
    'sample_orders', '[]'::jsonb,
    'abnormals', '[]'::jsonb
  );
end;
$$;

grant execute on function public.finance_marketplace_reconciliation_breakdown(date, date, text, uuid) to authenticated, service_role;


-- Redefining finance_dashboard_snapshot to make it fully dynamic and respect p_start/p_end/p_account_id
create or replace function public.finance_dashboard_snapshot(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '15s'
as $$
declare
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_tenant_id uuid;
  v_role text := coalesce(nullif(v_claims->>'role', ''), nullif(current_setting('role', true), ''), current_user);
  v_current_start date := date_trunc('month', timezone('Asia/Jakarta', now()))::date;
  v_current_end date := timezone('Asia/Jakarta', now())::date;
  v_start date := coalesce(p_start, v_current_start);
  v_end date := coalesce(p_end, v_current_end);
  v_start_ts timestamptz := (v_start::timestamp at time zone 'Asia/Jakarta');
  v_end_ts timestamptz := ((v_end + 1)::timestamp at time zone 'Asia/Jakarta');
  v_marketplace text;

  v_by_marketplace jsonb := '[]'::jsonb;
  v_daily jsonb := '[]'::jsonb;
  v_recon_summary jsonb := '{}'::jsonb;
  v_recon_breakdown jsonb := '[]'::jsonb;

  v_abnormal_count integer := 0;
  v_negative_payout_total_abs numeric := 0;
  v_sample_order_count integer := 0;
  v_sample_hpp_total numeric := 0;
  v_sample_negative_payout_total numeric := 0;
  v_sample_loss_estimate numeric := 0;
  v_no_payout_count integer := 0;
  v_payout_minus_count integer := 0;
  v_omzet_total numeric := 0;
  v_payout_total numeric := 0;
  v_hpp_total numeric := 0;
  v_orders_count integer := 0;
  v_finance_orders_count integer := 0;
begin
  select coalesce(
    case
      when (v_claims->>'tenant_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then (v_claims->>'tenant_id')::uuid
      else null::uuid
    end,
    (select u.tenant_id from public.users u where u.user_id = auth.uid() limit 1)
  )
  into v_tenant_id;

  v_marketplace := case
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
    else null
  end;

  if (v_end - v_start) <= 31 then
    -- 1) Call profit/loss details to get the by_marketplace rows and aggregates
    with pl_res as (
      select coalesce(public.finance_marketplace_profit_loss_detail(v_start, v_end, p_marketplace, p_account_id)->'rows', '[]'::jsonb) as rows_val
    ),
    pl_elements as (
      select jsonb_array_elements(rows_val) as row_val from pl_res
    ),
    unpacked as (
      select
        coalesce((row_val->>'gross_sales')::numeric, 0) as gross_sales,
        coalesce((row_val->>'payout_total')::numeric, 0) as payout_total,
        coalesce((row_val->>'discount_amount')::numeric, 0) as discount_amount,
        coalesce((row_val->>'platform_fee')::numeric, 0) as platform_fee,
        coalesce((row_val->>'commission_fee')::numeric, 0) as commission_fee,
        coalesce((row_val->>'affiliate_fee')::numeric, 0) as affiliate_fee,
        coalesce((row_val->>'shipping_fee')::numeric, 0) as shipping_fee,
        coalesce((row_val->>'other_fee')::numeric, 0) as other_fee,
        coalesce((row_val->>'refund_amount')::numeric, 0) as refund_amount,
        coalesce((row_val->>'adjustment_amount')::numeric, 0) as adjustment_amount,
        coalesce((row_val->>'sample_order_count')::integer, 0) as sample_order_count,
        coalesce((row_val->>'sample_negative_payout_total')::numeric, 0) as sample_negative_payout_total,
        coalesce((row_val->>'order_count')::integer, 0) as order_count,
        coalesce((row_val->>'finance_order_count')::integer, 0) as finance_order_count,
        coalesce((row_val->>'unmatched_order_count')::integer, 0) as unmatched_order_count,
        coalesce((row_val->>'unmatched_order_gross')::numeric, 0) as unmatched_order_gross,
        row_val
      from pl_elements
    )
    select
      coalesce(sum(gross_sales), 0),
      coalesce(sum(payout_total), 0),
      coalesce(sum(sample_order_count), 0),
      coalesce(sum(sample_negative_payout_total), 0),
      coalesce(sum(order_count), 0),
      coalesce(sum(finance_order_count), 0),
      coalesce(sum(unmatched_order_count), 0),
      coalesce(jsonb_agg(row_val), '[]'::jsonb)
    into
      v_omzet_total,
      v_payout_total,
      v_sample_order_count,
      v_sample_negative_payout_total,
      v_orders_count,
      v_finance_orders_count,
      v_no_payout_count,
      v_by_marketplace
    from unpacked;

    -- 2) Call reconciliation breakdown for sample HPP and unclassified breakdown
    select
      coalesce((v_recon->'summary'->>'sample_hpp_total')::numeric, 0),
      coalesce((v_recon->'summary'->>'sample_loss_estimate')::numeric, 0),
      coalesce(v_recon->'profit_loss_breakdown', '[]'::jsonb)
    into
      v_sample_hpp_total,
      v_sample_loss_estimate,
      v_recon_breakdown
    from (
      select public.finance_marketplace_reconciliation_breakdown(v_start, v_end, p_marketplace, p_account_id) as v_recon
    ) x;
  else
    -- LIGHTWEIGHT PATH FOR > 31 DAYS (e.g. 90d dashboard loads)
    with orders_by_mkt as (
      select
        o.marketplace,
        o.marketplace_account_id,
        count(distinct o.order_sn)::integer as order_count,
        coalesce(sum(coalesce(o.total_amount, o.gross_amount, o.paid_amount, 0)), 0)::numeric as gross_sales
      from public.marketplace_orders o
      where o.order_created_at >= v_start_ts
        and o.order_created_at < v_end_ts
        and (v_role = 'service_role' or o.tenant_id = v_tenant_id)
        and (p_account_id is null or o.marketplace_account_id = p_account_id)
        and (v_marketplace is null or o.marketplace = v_marketplace)
        and lower(coalesce(o.order_status, o.status, '')) !~ '(cancel|batal|dibatalkan|unpaid|belum bayar|belum dibayar)'
      group by 1, 2
    ),
    finance_by_mkt as (
      select
        fr.marketplace,
        fr.marketplace_account_id,
        count(distinct fr.order_id)::integer as finance_order_count,
        coalesce(sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0)), 0)::numeric as payout_total,
        coalesce(sum(abs(fr.discount_amount)), 0)::numeric as discount_amount,
        coalesce(sum(abs(fr.platform_fee)), 0)::numeric as platform_fee,
        coalesce(sum(abs(fr.commission_fee)), 0)::numeric as commission_fee,
        coalesce(sum(abs(fr.affiliate_fee)), 0)::numeric as affiliate_fee,
        coalesce(sum(abs(fr.shipping_fee)), 0)::numeric as shipping_fee,
        coalesce(sum(abs(fr.fee_amount)), 0)::numeric as other_fee,
        coalesce(sum(abs(fr.refund_amount)), 0)::numeric as refund_amount,
        coalesce(sum(fr.adjustment_amount), 0)::numeric as adjustment_amount
      from public.marketplace_finance_reports fr
      where fr.settlement_date >= v_start
        and fr.settlement_date <= v_end
        and (v_role = 'service_role' or fr.tenant_id = v_tenant_id)
        and (p_account_id is null or fr.marketplace_account_id = p_account_id)
        and (v_marketplace is null or fr.marketplace = v_marketplace)
      group by 1, 2
    ),
    joined_mkt as (
      select
        coalesce(o.marketplace, f.marketplace) as marketplace,
        coalesce(o.marketplace_account_id, f.marketplace_account_id) as marketplace_account_id,
        coalesce(a.shop_name, a.store_alias, to_jsonb(a)->>'seller_name', coalesce(o.marketplace, f.marketplace)) as shop_name,
        coalesce(o.order_count, 0) as order_count,
        coalesce(f.finance_order_count, 0) as finance_order_count,
        coalesce(o.gross_sales, 0) as gross_sales,
        coalesce(f.payout_total, 0) as payout_total,
        coalesce(f.discount_amount, 0) as discount_amount,
        coalesce(f.platform_fee, 0) as platform_fee,
        coalesce(f.commission_fee, 0) as commission_fee,
        coalesce(f.affiliate_fee, 0) as affiliate_fee,
        coalesce(f.shipping_fee, 0) as shipping_fee,
        coalesce(f.other_fee, 0) as other_fee,
        coalesce(f.refund_amount, 0) as refund_amount,
        coalesce(f.adjustment_amount, 0) as adjustment_amount
      from orders_by_mkt o
      full outer join finance_by_mkt f
        on f.marketplace_account_id = o.marketplace_account_id
      left join public.marketplace_accounts a
        on a.marketplace_account_id = coalesce(o.marketplace_account_id, f.marketplace_account_id)
    )
    select
      coalesce(sum(gross_sales), 0),
      coalesce(sum(payout_total), 0),
      coalesce(sum(order_count), 0),
      coalesce(sum(finance_order_count), 0),
      coalesce(jsonb_agg(jsonb_build_object(
        'row_kind', 'order_date_reconciliation',
        'marketplace', marketplace,
        'marketplace_account_id', marketplace_account_id,
        'shop_name', shop_name,
        'account_name', shop_name,
        'order_count', order_count,
        'finance_order_count', finance_order_count,
        'matched_finance_count', finance_order_count,
        'unmatched_order_count', greatest(order_count - finance_order_count, 0),
        'unmatched_order_gross', 0,
        'gross_sales', gross_sales,
        'gross_total', gross_sales,
        'omzet', gross_sales,
        'payout_total', payout_total,
        'payout_amount', payout_total,
        'received_amount', payout_total,
        'gross_payout_gap', greatest(gross_sales - payout_total, 0),
        'gross_minus_payout', greatest(gross_sales - payout_total, 0),
        'selisih_omzet_payout', greatest(gross_sales - payout_total, 0),
        'settlement_unmatched_total', 0,
        'settlement_belum_final', 0,
        'discount_amount', discount_amount,
        'platform_fee', platform_fee,
        'commission_fee', commission_fee,
        'affiliate_fee', affiliate_fee,
        'shipping_fee', shipping_fee,
        'other_fee', other_fee,
        'refund_amount', refund_amount,
        'tax_amount', 0,
        'adjustment_amount', adjustment_amount,
        'sample_order_count', 0,
        'sample_negative_payout_total', 0,
        'unclassified_amount', greatest(gross_sales - payout_total - (discount_amount + platform_fee + commission_fee + affiliate_fee + shipping_fee + other_fee + refund_amount + adjustment_amount), 0)
      ) order by marketplace, shop_name), '[]'::jsonb)
    into
      v_omzet_total,
      v_payout_total,
      v_orders_count,
      v_finance_orders_count,
      v_by_marketplace
    from joined_mkt;

    v_sample_order_count := 0;
    v_sample_negative_payout_total := 0;
    v_no_payout_count := 0;
    v_sample_hpp_total := 0;
    v_sample_loss_estimate := 0;
    v_recon_breakdown := '[]'::jsonb;
  end if;

  -- 3) Calculate abnormal counts and negative payouts from finance reports
  select
    coalesce(count(*), 0)::integer,
    coalesce(sum(abs(coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0))), 0)::numeric,
    coalesce(count(*) filter (where coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0) < 0), 0)::integer
  into
    v_abnormal_count,
    v_negative_payout_total_abs,
    v_payout_minus_count
  from public.marketplace_finance_reports fr
  where fr.period_start >= v_start
    and fr.period_start <= v_end
    and (v_role = 'service_role' or fr.tenant_id = v_tenant_id)
    and (p_account_id is null or fr.marketplace_account_id = p_account_id)
    and (v_marketplace is null or (
      case
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
        else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end
    ) = v_marketplace)
    and coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)::numeric < 0;

  -- 4) Build daily trend series dynamically
  with calendar as (
    select generate_series(v_start, v_end, interval '1 day')::date as day
  ),
  daily_orders as (
    select
      timezone('Asia/Jakarta', o.order_created_at)::date as order_date,
      coalesce(sum(coalesce(o.total_amount, o.gross_amount, o.paid_amount, 0)), 0)::numeric as gross_total,
      count(distinct coalesce(nullif(o.order_sn, ''), nullif(o.external_order_id, ''), nullif(o.order_id, ''), o.marketplace_order_id::text))::integer as orders_count
    from public.marketplace_orders o
    where o.order_created_at >= v_start_ts
      and o.order_created_at < v_end_ts
      and (v_role = 'service_role' or o.tenant_id = v_tenant_id)
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and (v_marketplace is null or (
        case
          when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
          else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end
      ) = v_marketplace)
      and lower(coalesce(o.order_status, o.status, '')) !~ '(cancel|batal|dibatalkan|unpaid|belum bayar|belum dibayar)'
    group by 1
  ),
  daily_finance as (
    select
      fr.period_start::date as finance_date,
      coalesce(sum(coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)), 0)::numeric as payout_total,
      count(*)::integer as finance_orders_count,
      count(*) filter (where coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0) < 0)::integer as negative_payout_count,
      coalesce(sum(abs(coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0))) filter (where coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0) < 0), 0)::numeric as negative_payout_total_abs
    from public.marketplace_finance_reports fr
    where fr.period_start >= v_start
      and fr.period_start <= v_end
      and (v_role = 'service_role' or fr.tenant_id = v_tenant_id)
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and (v_marketplace is null or (
        case
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
          else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end
      ) = v_marketplace)
    group by 1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'date', c.day,
    'order_date', c.day,
    'omzet_total', coalesce(d_ord.gross_total, 0),
    'gross_total', coalesce(d_ord.gross_total, 0),
    'gross_sales', coalesce(d_ord.gross_total, 0),
    'payout_total', coalesce(d_fin.payout_total, 0),
    'hpp_total', 0,
    'orders_count', coalesce(d_ord.orders_count, 0),
    'order_count', coalesce(d_ord.orders_count, 0),
    'finance_orders_count', coalesce(d_fin.finance_orders_count, 0),
    'abnormal_count', coalesce(d_fin.negative_payout_count, 0),
    'negative_payout_total_abs', coalesce(d_fin.negative_payout_total_abs, 0)
  ) order by c.day), '[]'::jsonb)
  into v_daily
  from calendar c
  left join daily_orders d_ord on d_ord.order_date = c.day
  left join daily_finance d_fin on d_fin.finance_date = c.day;

  return jsonb_build_object(
    'ok', true,
    'version', 'finance_dashboard_snapshot_dynamic_dates_20260621',
    'source', 'finance_dashboard_snapshot',
    'source_table', 'finance_marketplace_profit_loss_detail+marketplace_finance_reports',
    'timezone', 'Asia/Jakarta',
    'start_date', v_start::text,
    'end_date', v_end::text,
    'requested_start_date', p_start,
    'requested_end_date', p_end,
    'requested_account_id', p_account_id,
    'marketplace', coalesce(p_marketplace, 'all'),
    'summary', jsonb_build_object(
      'omzet_total', v_omzet_total,
      'gross_total', v_omzet_total,
      'gross_sales', v_omzet_total,
      'payout_total', v_payout_total,
      'payout_amount', v_payout_total,
      'hpp_total', v_hpp_total,
      'total_hpp', v_hpp_total,
      'net_profit', v_payout_total - v_hpp_total,
      'orders_count', v_orders_count,
      'order_count', v_orders_count,
      'finance_orders_count', v_finance_orders_count,
      'finance_order_count', v_finance_orders_count,
      'abnormal_count', v_abnormal_count,
      'anomaly_count', v_abnormal_count,
      'negative_payout_total_abs', v_negative_payout_total_abs,
      'payout_minus_total_abs', v_negative_payout_total_abs,
      'sample_order_count', v_sample_order_count,
      'sample_hpp_total', v_sample_hpp_total,
      'sample_negative_payout_total', v_sample_negative_payout_total,
      'sample_loss_estimate', v_sample_loss_estimate,
      'no_payout_count', v_no_payout_count,
      'payout_minus_count', v_payout_minus_count
    ),
    'daily', v_daily,
    'trend', v_daily,
    'by_marketplace', v_by_marketplace,
    'marketplaces', v_by_marketplace,
    'profit_loss_by_marketplace', v_by_marketplace,
    'abnormal_aggregates', jsonb_build_object(
      'abnormal_count', v_abnormal_count,
      'negative_payout_total_abs', v_negative_payout_total_abs
    ),
    'accounts', '[]'::jsonb,
    'expenses', '[]'::jsonb,
    'approved_purchases', '[]'::jsonb,
    'skus', '[]'::jsonb,
    'sku_rows', '[]'::jsonb,
    'cash_flow', '[]'::jsonb,
    'profit_loss_breakdown', v_recon_breakdown,
    'abnormals', '[]'::jsonb
  );
end;
$$;

grant execute on function public.finance_dashboard_snapshot(date, date, text, uuid) to authenticated, service_role;
