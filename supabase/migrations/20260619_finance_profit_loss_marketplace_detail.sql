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
finance_by_order as materialized (
  select
    fr.tenant_id,
    fr.marketplace_account_id,
    coalesce(
      nullif(to_jsonb(fr)->>'order_id', ''),
      nullif(to_jsonb(fr)->>'external_order_id', ''),
      nullif(to_jsonb(fr)->>'order_sn', ''),
      nullif(to_jsonb(fr)->>'marketplace_order_sn', ''),
      nullif(to_jsonb(fr)->>'remote_order_id', ''),
      nullif(to_jsonb(fr)->>'title', '')
    ) as order_key,
    sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0)::numeric) as payout_amount,
    sum(abs(coalesce(fr.discount_amount, 0)::numeric)) as discount_amount,
    sum(abs(coalesce(fr.platform_fee, 0)::numeric)) as platform_fee,
    sum(abs(coalesce(fr.commission_fee, 0)::numeric)) as commission_fee,
    sum(abs(coalesce(fr.affiliate_fee, 0)::numeric)) as affiliate_fee,
    sum(abs(coalesce(fr.shipping_fee, 0)::numeric)) as shipping_fee,
    sum(abs(coalesce(fr.fee_amount, 0)::numeric)) as fee_amount,
    sum(abs(coalesce(fr.total_fees, 0)::numeric)) as total_fees,
    sum(abs(coalesce(fr.refund_amount, fr.total_refund, 0)::numeric)) as refund_amount,
    sum(abs(
      public.finance_json_num_fast(to_jsonb(fr), 'tax_amount') +
      public.finance_json_num_fast(to_jsonb(fr), 'vat_amount') +
      public.finance_json_num_fast(to_jsonb(fr), 'ppn') +
      public.finance_json_num_fast(to_jsonb(fr), 'pph') +
      public.finance_json_num_fast(to_jsonb(fr), 'withholding_tax')
    )) as tax_amount,
    sum(coalesce(fr.adjustment_amount, 0)::numeric) as adjustment_amount
  from public.marketplace_finance_reports fr
  cross join tenant t
  where (t.tenant_id is null or fr.tenant_id = t.tenant_id)
    and (p_account_id is null or fr.marketplace_account_id = p_account_id)
    and (p_marketplace is null or p_marketplace = '' or p_marketplace = 'all' or coalesce(fr.marketplace, to_jsonb(fr)->>'marketplace', '') = p_marketplace)
  group by fr.tenant_id, fr.marketplace_account_id, order_key
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
      greatest(coalesce(f.total_fees, 0), coalesce(f.fee_amount, 0)) -
      (coalesce(f.platform_fee, 0) + coalesce(f.commission_fee, 0) + coalesce(f.affiliate_fee, 0) + coalesce(f.shipping_fee, 0)),
      0
    ) as other_fee,
    coalesce(f.refund_amount, 0) as refund_amount,
    coalesce(f.tax_amount, 0) as tax_amount,
    coalesce(f.adjustment_amount, 0) as adjustment_amount,
    (
      o.gross_amount <= 0
      or o.payment_text ~ '(sample|gratis|free|zero|0 payment|no payment|tester|giveaway)'
      or (o.payment_text = '' and o.gross_amount = 0 and o.status_text ~ '(complete|completed|delivered|selesai|dikirim|done)')
    ) as is_sample_order
  from orders_scoped o
  left join finance_by_order f
    on f.tenant_id = o.tenant_id
   and f.marketplace_account_id = o.marketplace_account_id
   and f.order_key = o.order_key
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
    coalesce(sum(j.other_fee), 0) as other_fee,
    coalesce(sum(j.refund_amount), 0) as refund_amount,
    coalesce(sum(j.tax_amount), 0) as tax_amount,
    coalesce(sum(j.adjustment_amount), 0) as adjustment_amount,
    count(*) filter (where j.is_sample_order)::int as sample_order_count,
    coalesce(sum(abs(j.payout_amount)) filter (where j.is_sample_order and j.payout_amount < 0), 0) as sample_negative_payout_total
  from joined j
  left join public.marketplace_accounts a
    on a.marketplace_account_id = j.marketplace_account_id
  group by j.marketplace, j.marketplace_account_id, coalesce(a.shop_name, a.store_alias, to_jsonb(a)->>'seller_name', to_jsonb(a)->>'account_name', j.marketplace)
),
with_unclassified as (
  select
    *,
    greatest(
      gross_sales - payout_total -
      (
        discount_amount + platform_fee + commission_fee + affiliate_fee + shipping_fee + other_fee +
        refund_amount + tax_amount + abs(adjustment_amount) + sample_negative_payout_total
      ),
      0
    ) as unclassified_amount
  from marketplace_group
)
select jsonb_build_object(
  'ok', true,
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
    'other_fee', other_fee,
    'refund_amount', refund_amount,
    'tax_amount', tax_amount,
    'adjustment_amount', adjustment_amount,
    'sample_order_count', sample_order_count,
    'sample_negative_payout_total', sample_negative_payout_total,
    'unclassified_amount', unclassified_amount
  ) order by marketplace, shop_name), '[]'::jsonb)
)
from with_unclassified;
$$;

grant execute on function public.finance_marketplace_profit_loss_detail(date, date, text, uuid)
  to authenticated, service_role;

notify pgrst, 'reload schema';
