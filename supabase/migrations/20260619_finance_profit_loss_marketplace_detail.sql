-- Overwrite existing canonical marketplace profit/loss detail RPC.
-- No new public RPC/version is added.
-- Source rule: marketplace order date, not marketplace_finance_reports.created_at.
-- Output is diagnostic reconciliation only, not final P&L expense.

create index if not exists idx_marketplace_orders_recon_order_date
  on public.marketplace_orders(marketplace, marketplace_account_id, order_created_at, order_sn);

create index if not exists idx_finance_reports_recon_order
  on public.marketplace_finance_reports(marketplace, marketplace_account_id, order_id);

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
set statement_timeout = '180s'
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
orders_scoped as materialized (
  select
    o.marketplace_order_id,
    o.tenant_id,
    o.marketplace_account_id,
    o.marketplace,
    o.order_sn,
    o.order_created_at,
    coalesce(o.total_amount, o.gross_amount, o.paid_amount, 0)::numeric as gross_amount,
    lower(coalesce(o.order_status, o.status, '')) as status_text,
    lower(coalesce(to_jsonb(o)->>'payment_method', to_jsonb(o)->>'payment_channel', to_jsonb(o)->>'payment_status', '')) as payment_text
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
finance_by_order as materialized (
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
  group by fr.tenant_id, fr.marketplace, fr.marketplace_account_id, fr.order_id
),
joined as materialized (
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
    coalesce(sum(j.gross_amount), 0) as gross_sales,
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
  'source', 'finance_marketplace_profit_loss_detail',
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

grant execute on function public.finance_marketplace_profit_loss_detail(date, date, text, uuid)
  to authenticated, service_role;

notify pgrst, 'reload schema';
