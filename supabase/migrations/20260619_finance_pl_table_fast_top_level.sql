-- Fast top-level Profit/Loss detail per marketplace.
-- Uses only normalized/top-level finance columns and joins finance rows to scoped order rows first.
-- This avoids broad raw JSON scans and avoids scanning all finance rows for every UI request.

create index if not exists idx_finance_reports_marketplace_order_id
  on public.marketplace_finance_reports(marketplace_order_id);

create index if not exists idx_finance_reports_account_order
  on public.marketplace_finance_reports(marketplace_account_id, order_id);

create index if not exists idx_orders_account_created
  on public.marketplace_orders(marketplace_account_id, order_created_at desc);

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
set statement_timeout = '120s'
as $$
with vars as (
  select
    case when p_start is null then null else (p_start::timestamp - interval '7 hours')::timestamptz end as start_ts,
    case when p_end is null then null else ((p_end + 1)::timestamp - interval '7 hours')::timestamptz end as end_ts
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
    o.order_created_at,
    coalesce(
      nullif(to_jsonb(o)->>'external_order_id', ''),
      nullif(to_jsonb(o)->>'order_sn', ''),
      nullif(to_jsonb(o)->>'remote_order_id', ''),
      nullif(to_jsonb(o)->>'order_id', ''),
      o.marketplace_order_id::text
    ) as order_key,
    coalesce(o.gross_amount, o.total_amount, 0)::numeric as gross_amount,
    lower(coalesce(to_jsonb(o)->>'payment_method', to_jsonb(o)->>'payment_channel', to_jsonb(o)->>'payment_status', '')) as payment_text,
    lower(coalesce(to_jsonb(o)->>'order_status', to_jsonb(o)->>'status', '')) as status_text
  from public.marketplace_orders o
  cross join vars v
  cross join tenant t
  where (t.tenant_id is null or o.tenant_id = t.tenant_id)
    and (p_marketplace is null or p_marketplace = '' or p_marketplace = 'all' or o.marketplace = p_marketplace)
    and (p_account_id is null or o.marketplace_account_id = p_account_id)
    and (v.start_ts is null or o.order_created_at >= v.start_ts)
    and (v.end_ts is null or o.order_created_at < v.end_ts)
),
finance_match as materialized (
  select
    o.marketplace_order_id as local_marketplace_order_id,
    fr.marketplace_finance_report_id,
    fr.payout_amount,
    fr.net_settlement,
    fr.received_amount,
    fr.discount_amount,
    fr.platform_fee,
    fr.commission_fee,
    fr.affiliate_fee,
    fr.shipping_fee,
    fr.fee_amount,
    fr.total_fees,
    fr.refund_amount,
    fr.total_refund,
    fr.adjustment_amount
  from orders_scoped o
  join public.marketplace_finance_reports fr
    on fr.marketplace_order_id = o.marketplace_order_id

  union

  select
    o.marketplace_order_id as local_marketplace_order_id,
    fr.marketplace_finance_report_id,
    fr.payout_amount,
    fr.net_settlement,
    fr.received_amount,
    fr.discount_amount,
    fr.platform_fee,
    fr.commission_fee,
    fr.affiliate_fee,
    fr.shipping_fee,
    fr.fee_amount,
    fr.total_fees,
    fr.refund_amount,
    fr.total_refund,
    fr.adjustment_amount
  from orders_scoped o
  join public.marketplace_finance_reports fr
    on fr.marketplace_account_id = o.marketplace_account_id
   and fr.order_id::text = o.order_key
),
finance_by_order as materialized (
  select
    local_marketplace_order_id as marketplace_order_id,
    sum(coalesce(payout_amount, net_settlement, received_amount, 0)::numeric) as payout_amount,
    sum(abs(coalesce(discount_amount, 0)::numeric)) as discount_amount,
    sum(abs(coalesce(platform_fee, 0)::numeric)) as platform_fee,
    sum(abs(coalesce(commission_fee, 0)::numeric)) as commission_fee,
    sum(abs(coalesce(affiliate_fee, 0)::numeric)) as affiliate_fee,
    sum(abs(coalesce(shipping_fee, 0)::numeric)) as shipping_fee,
    sum(abs(coalesce(fee_amount, 0)::numeric)) as fee_amount,
    sum(abs(coalesce(total_fees, 0)::numeric)) as total_fees,
    sum(abs(coalesce(refund_amount, total_refund, 0)::numeric)) as refund_amount,
    sum(abs(coalesce(adjustment_amount, 0)::numeric)) as adjustment_amount
  from finance_match
  group by local_marketplace_order_id
),
joined as materialized (
  select
    o.*,
    coalesce(f.payout_amount, 0) as payout_amount,
    coalesce(f.discount_amount, 0) as discount_amount,
    coalesce(f.platform_fee, 0) as platform_fee,
    coalesce(f.commission_fee, 0) as commission_fee,
    coalesce(f.affiliate_fee, 0) as affiliate_fee,
    coalesce(f.shipping_fee, 0) as shipping_fee,
    greatest(
      coalesce(f.fee_amount, 0) -
      (coalesce(f.platform_fee, 0) + coalesce(f.commission_fee, 0) + coalesce(f.affiliate_fee, 0) + coalesce(f.shipping_fee, 0)),
      0
    ) as payment_transaction_fee,
    greatest(
      coalesce(f.total_fees, 0) -
      greatest(
        coalesce(f.fee_amount, 0),
        coalesce(f.platform_fee, 0) + coalesce(f.commission_fee, 0) + coalesce(f.affiliate_fee, 0) + coalesce(f.shipping_fee, 0)
      ),
      0
    ) as other_fee,
    coalesce(f.refund_amount, 0) as refund_amount,
    0::numeric as tax_amount,
    coalesce(f.adjustment_amount, 0) as adjustment_amount,
    (
      o.gross_amount <= 0
      or o.payment_text ~ '(sample|gratis|free|zero|0 payment|no payment|tester|giveaway)'
      or (o.payment_text = '' and o.gross_amount = 0 and o.status_text ~ '(complete|completed|delivered|selesai|dikirim|done)')
    ) as is_sample_order
  from orders_scoped o
  left join finance_by_order f
    on f.marketplace_order_id = o.marketplace_order_id
),
marketplace_group as (
  select
    j.marketplace,
    j.marketplace_account_id,
    coalesce(a.shop_name, a.store_alias, to_jsonb(a)->>'seller_name', to_jsonb(a)->>'account_name', j.marketplace) as shop_name,
    count(*)::int as order_count,
    coalesce(sum(j.gross_amount), 0) as gross_sales,
    coalesce(sum(j.payout_amount), 0) as payout_total,
    coalesce(sum(j.discount_amount), 0) as discount_amount,
    coalesce(sum(j.platform_fee), 0) as platform_fee,
    coalesce(sum(j.commission_fee), 0) as commission_fee,
    coalesce(sum(j.affiliate_fee), 0) as affiliate_fee,
    coalesce(sum(j.shipping_fee), 0) as shipping_fee,
    coalesce(sum(j.payment_transaction_fee), 0) as payment_transaction_fee,
    coalesce(sum(j.other_fee), 0) as other_fee,
    coalesce(sum(j.refund_amount), 0) as refund_amount,
    coalesce(sum(j.tax_amount), 0) as tax_amount,
    coalesce(sum(j.adjustment_amount), 0) as adjustment_amount,
    count(*) filter (where j.is_sample_order)::int as sample_order_count,
    coalesce(sum(abs(j.payout_amount)) filter (where j.is_sample_order and j.payout_amount < 0), 0) as sample_negative_payout_total,
    count(*) filter (where j.payout_amount = 0 and not j.is_sample_order) as missing_payout_non_sample_count
  from joined j
  left join public.marketplace_accounts a
    on a.marketplace_account_id = j.marketplace_account_id
  group by j.marketplace, j.marketplace_account_id, coalesce(a.shop_name, a.store_alias, to_jsonb(a)->>'seller_name', to_jsonb(a)->>'account_name', j.marketplace)
),
with_final_gap as (
  select
    *,
    greatest(
      gross_sales - payout_total -
      (
        discount_amount + platform_fee + commission_fee + affiliate_fee + shipping_fee +
        payment_transaction_fee + other_fee + refund_amount + tax_amount +
        abs(adjustment_amount) + sample_negative_payout_total
      ),
      0
    ) as settlement_not_final_amount
  from marketplace_group
)
select jsonb_build_object(
  'ok', true,
  'mapping_source', 'normalized_top_level_fast',
  'label_policy', 'settlement_not_final',
  'rows', coalesce(jsonb_agg(jsonb_build_object(
    'marketplace', marketplace,
    'marketplace_account_id', marketplace_account_id,
    'shop_name', shop_name,
    'account_name', shop_name,
    'order_count', order_count,
    'gross_sales', gross_sales,
    'payout_total', payout_total,
    'gross_payout_gap', greatest(gross_sales - payout_total, 0),
    'discount_amount', discount_amount,
    'platform_fee', platform_fee,
    'commission_fee', commission_fee,
    'affiliate_fee', affiliate_fee,
    'shipping_fee', shipping_fee,
    'payment_transaction_fee', payment_transaction_fee,
    'other_fee', other_fee,
    'refund_amount', refund_amount,
    'tax_amount', tax_amount,
    'adjustment_amount', adjustment_amount,
    'sample_order_count', sample_order_count,
    'sample_negative_payout_total', sample_negative_payout_total,
    'missing_payout_non_sample_count', missing_payout_non_sample_count,
    'settlement_not_final_amount', settlement_not_final_amount
  ) order by marketplace, shop_name), '[]'::jsonb)
)
from with_final_gap;
$$;

grant execute on function public.finance_marketplace_profit_loss_detail(date, date, text, uuid)
  to authenticated, service_role;

notify pgrst, 'reload schema';
