-- Finance reconciliation detailed breakdown + UI-safe by_marketplace.
-- This function intentionally uses temp tables; volatility must be volatile.

create index if not exists idx_finance_reports_account_order
  on public.marketplace_finance_reports(marketplace_account_id, order_id);

create index if not exists idx_orders_account_created
  on public.marketplace_orders(marketplace_account_id, order_created_at desc);

create index if not exists idx_items_order_account_variant
  on public.marketplace_order_items(marketplace_order_id, marketplace_account_id, marketplace_product_id, marketplace_sku_id);

create index if not exists idx_hpp_account_variant
  on public.marketplace_variant_hpp_mappings(marketplace_account_id, marketplace_product_id, marketplace_sku_id);

create or replace function public.finance_json_num_fast(p_json jsonb, p_key text)
returns numeric
language sql
immutable
as $$
  select coalesce(
    nullif(regexp_replace(coalesce(p_json ->> p_key, ''), '[^0-9.\-]', '', 'g'), '')::numeric,
    0
  );
$$;

create or replace function public.finance_marketplace_reconciliation_breakdown(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null
)
returns jsonb
language plpgsql
volatile
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
  v_discount numeric := 0;
  v_fee numeric := 0;
  v_refund numeric := 0;
  v_tax numeric := 0;
  v_adjustment numeric := 0;
  v_sample_count int := 0;
  v_sample_gross numeric := 0;
  v_sample_hpp numeric := 0;
  v_sample_negative_payout numeric := 0;
  v_sample_loss_estimate numeric := 0;
  v_known numeric := 0;
  v_other numeric := 0;

  v_breakdown jsonb := '[]'::jsonb;
  v_by_marketplace jsonb := '[]'::jsonb;
  v_sample_orders jsonb := '[]'::jsonb;
  v_abnormals jsonb := '[]'::jsonb;
begin
  begin
    v_tenant_id := nullif(current_setting('request.jwt.claims', true)::jsonb->>'tenant_id', '')::uuid;
  exception when others then
    v_tenant_id := null;
  end;

  create temporary table if not exists _finance_recon_joined (
    marketplace_order_id uuid,
    tenant_id uuid,
    marketplace_account_id uuid,
    marketplace text,
    order_created_at timestamptz,
    order_key text,
    gross_amount numeric,
    payout_amount numeric,
    discount_amount numeric,
    fee_amount numeric,
    refund_amount numeric,
    tax_amount numeric,
    adjustment_amount numeric,
    is_sample_order boolean
  ) on commit drop;

  create temporary table if not exists _finance_recon_sample_hpp (
    marketplace_order_id uuid,
    sample_hpp numeric
  ) on commit drop;

  truncate _finance_recon_joined;
  truncate _finance_recon_sample_hpp;

  insert into _finance_recon_joined (
    marketplace_order_id,
    tenant_id,
    marketplace_account_id,
    marketplace,
    order_created_at,
    order_key,
    gross_amount,
    payout_amount,
    discount_amount,
    fee_amount,
    refund_amount,
    tax_amount,
    adjustment_amount,
    is_sample_order
  )
  with scoped_orders as materialized (
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
    where (v_tenant_id is null or o.tenant_id = v_tenant_id)
      and (p_marketplace is null or p_marketplace = '' or p_marketplace = 'all' or o.marketplace = p_marketplace)
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and (v_start is null or o.order_created_at >= v_start)
      and (v_end is null or o.order_created_at < v_end)
  ),
  scoped_finance as materialized (
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
      coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0)::numeric as payout_amount,
      abs(coalesce(fr.discount_amount, 0)) as discount_amount,
      abs(
        coalesce(fr.platform_fee, 0)
        + coalesce(fr.commission_fee, 0)
        + coalesce(fr.affiliate_fee, 0)
        + coalesce(fr.shipping_fee, 0)
        + case
            when coalesce(fr.platform_fee, 0)
               + coalesce(fr.commission_fee, 0)
               + coalesce(fr.affiliate_fee, 0)
               + coalesce(fr.shipping_fee, 0) = 0
            then coalesce(fr.fee_amount, fr.total_fees, 0)
            else 0
          end
      ) as fee_amount,
      abs(coalesce(fr.refund_amount, fr.total_refund, 0)) as refund_amount,
      abs(
        public.finance_json_num_fast(to_jsonb(fr), 'tax_amount')
        + public.finance_json_num_fast(to_jsonb(fr), 'vat_amount')
        + public.finance_json_num_fast(to_jsonb(fr), 'ppn')
        + public.finance_json_num_fast(to_jsonb(fr), 'pph')
        + public.finance_json_num_fast(to_jsonb(fr), 'withholding_tax')
      ) as tax_amount,
      coalesce(fr.adjustment_amount, 0)::numeric as adjustment_amount
    from public.marketplace_finance_reports fr
    where (v_tenant_id is null or fr.tenant_id = v_tenant_id)
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and (p_marketplace is null or p_marketplace = '' or p_marketplace = 'all' or coalesce(fr.marketplace, to_jsonb(fr)->>'marketplace', '') = p_marketplace)
  ),
  finance_by_order as (
    select
      tenant_id,
      marketplace_account_id,
      order_key,
      sum(payout_amount) as payout_amount,
      sum(discount_amount) as discount_amount,
      sum(fee_amount) as fee_amount,
      sum(refund_amount) as refund_amount,
      sum(tax_amount) as tax_amount,
      sum(adjustment_amount) as adjustment_amount
    from scoped_finance
    where coalesce(order_key, '') <> ''
    group by tenant_id, marketplace_account_id, order_key
  )
  select
    o.marketplace_order_id,
    o.tenant_id,
    o.marketplace_account_id,
    o.marketplace,
    o.order_created_at,
    o.order_key,
    o.gross_amount,
    coalesce(f.payout_amount, 0),
    coalesce(f.discount_amount, 0),
    coalesce(f.fee_amount, 0),
    coalesce(f.refund_amount, 0),
    coalesce(f.tax_amount, 0),
    coalesce(f.adjustment_amount, 0),
    (
      o.gross_amount <= 0
      or o.payment_text ~ '(sample|gratis|free|zero|0 payment|no payment|tester|giveaway)'
      or (o.payment_text = '' and o.gross_amount = 0 and o.status_text ~ '(complete|completed|delivered|selesai|dikirim|done)')
    ) as is_sample_order
  from scoped_orders o
  left join finance_by_order f
    on f.tenant_id = o.tenant_id
   and f.marketplace_account_id = o.marketplace_account_id
   and f.order_key = o.order_key;

  insert into _finance_recon_sample_hpp (marketplace_order_id, sample_hpp)
  select
    j.marketplace_order_id,
    sum(
      coalesce(nullif(to_jsonb(i)->>'quantity', '')::numeric, nullif(to_jsonb(i)->>'qty', '')::numeric, 1)
      * coalesce(h.hpp, h.hpp_amount, h.hpp_per_item, 0)
    ) as sample_hpp
  from _finance_recon_joined j
  join public.marketplace_order_items i
    on i.marketplace_order_id = j.marketplace_order_id
  left join public.marketplace_variant_hpp_mappings h
    on h.marketplace_account_id = i.marketplace_account_id
   and h.marketplace_product_id = i.marketplace_product_id
   and h.marketplace_sku_id = i.marketplace_sku_id
  where j.is_sample_order
  group by j.marketplace_order_id;

  select
    count(*)::int,
    coalesce(sum(j.gross_amount), 0),
    coalesce(sum(j.payout_amount), 0),
    coalesce(sum(j.discount_amount), 0),
    coalesce(sum(j.fee_amount), 0),
    coalesce(sum(j.refund_amount), 0),
    coalesce(sum(j.tax_amount), 0),
    coalesce(sum(j.adjustment_amount), 0),
    count(*) filter (where j.is_sample_order)::int,
    coalesce(sum(j.gross_amount) filter (where j.is_sample_order), 0),
    coalesce(sum(coalesce(sh.sample_hpp, 0)) filter (where j.is_sample_order), 0),
    coalesce(sum(abs(j.payout_amount)) filter (where j.is_sample_order and j.payout_amount < 0), 0)
  into
    v_order_count,
    v_gross,
    v_payout,
    v_discount,
    v_fee,
    v_refund,
    v_tax,
    v_adjustment,
    v_sample_count,
    v_sample_gross,
    v_sample_hpp,
    v_sample_negative_payout
  from _finance_recon_joined j
  left join _finance_recon_sample_hpp sh on sh.marketplace_order_id = j.marketplace_order_id;

  v_gap := greatest(v_gross - v_payout, 0);
  v_sample_loss_estimate := v_sample_hpp + v_sample_negative_payout;
  v_known := v_discount + v_fee + v_refund + v_tax + abs(v_adjustment) + v_sample_negative_payout + v_sample_gross;
  v_other := greatest(v_gap - v_known, 0);

  v_breakdown := (
    select coalesce(jsonb_agg(item), '[]'::jsonb)
    from (
      select jsonb_build_object('label','Voucher / diskon','category','voucher_discount','description','Discount amount dari settlement marketplace.','amount',v_discount,'order_count',null) item where v_discount > 0
      union all select jsonb_build_object('label','Fee / komisi / ongkir marketplace','category','marketplace_fee','description','Platform fee, komisi, affiliate fee, shipping fee, atau total fees settlement.','amount',v_fee,'order_count',null) where v_fee > 0
      union all select jsonb_build_object('label','Refund / retur / batal','category','refund_return_cancel','description','Refund amount atau total refund settlement.','amount',v_refund,'order_count',null) where v_refund > 0
      union all select jsonb_build_object('label','Pajak marketplace','category','tax','description','Tax/VAT/PPN/PPh/withholding tax bila tersedia di raw settlement.','amount',v_tax,'order_count',null) where v_tax > 0
      union all select jsonb_build_object('label','Adjustment settlement','category','settlement_adjustment','description','Adjustment amount dari settlement marketplace.','amount',abs(v_adjustment),'order_count',null) where v_adjustment <> 0
      union all select jsonb_build_object('label','Sample / gratis / pembayaran 0','category','sample_zero_payment','description','Order sample/gratis/zero payment. Dampak dihitung dari HPP sample dan payout minus sample.','amount',v_sample_loss_estimate,'hpp_total',v_sample_hpp,'negative_payout_total',v_sample_negative_payout,'order_count',v_sample_count) where v_sample_count > 0
      union all select jsonb_build_object('label','Penyesuaian omzet vs payout belum terklasifikasi','category','unclassified_adjustment','description','Sisa selisih omzet dan payout setelah discount, fee, refund, pajak, adjustment, dan sample.','amount',v_other,'order_count',null) where v_other > 0
    ) rows
  );

  with marketplace_group as (
    select
      j.marketplace,
      j.marketplace_account_id,
      coalesce(a.shop_name, a.store_alias, to_jsonb(a)->>'seller_name', to_jsonb(a)->>'account_name', j.marketplace) as shop_name,
      count(*)::int as order_count,
      coalesce(sum(j.gross_amount), 0) as gross_sales,
      coalesce(sum(j.payout_amount), 0) as payout_total,
      coalesce(sum(j.discount_amount), 0) as discount_amount,
      coalesce(sum(j.fee_amount), 0) as fee_amount,
      coalesce(sum(j.refund_amount), 0) as refund_amount,
      coalesce(sum(j.tax_amount), 0) as tax_amount,
      coalesce(sum(j.adjustment_amount), 0) as adjustment_amount,
      count(*) filter (where j.is_sample_order)::int as sample_order_count,
      coalesce(sum(coalesce(sh.sample_hpp, 0)) filter (where j.is_sample_order), 0) as sample_hpp_total,
      coalesce(sum(abs(j.payout_amount)) filter (where j.is_sample_order and j.payout_amount < 0), 0) as sample_negative_payout_total,
      max(j.order_created_at) as last_updated_at
    from _finance_recon_joined j
    left join public.marketplace_accounts a
      on a.marketplace_account_id = j.marketplace_account_id
    left join _finance_recon_sample_hpp sh
      on sh.marketplace_order_id = j.marketplace_order_id
    group by j.marketplace, j.marketplace_account_id, coalesce(a.shop_name, a.store_alias, to_jsonb(a)->>'seller_name', to_jsonb(a)->>'account_name', j.marketplace)
  )
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
    'net_margin_percent', case when payout_total > 0 then 100 else 0 end,
    'margin_percent', case when payout_total > 0 then 100 else 0 end,
    'discount_amount', discount_amount,
    'fee_amount', fee_amount,
    'refund_amount', refund_amount,
    'tax_amount', tax_amount,
    'adjustment_amount', adjustment_amount,
    'sample_order_count', sample_order_count,
    'sample_hpp_total', sample_hpp_total,
    'sample_negative_payout_total', sample_negative_payout_total,
    'sample_loss_estimate', sample_hpp_total + sample_negative_payout_total,
    'last_updated_at', last_updated_at
  ) order by marketplace, shop_name), '[]'::jsonb)
  into v_by_marketplace
  from marketplace_group;

  with sample_rows as (
    select
      j.*,
      coalesce(sh.sample_hpp, 0) as sample_hpp
    from _finance_recon_joined j
    left join _finance_recon_sample_hpp sh on sh.marketplace_order_id = j.marketplace_order_id
    where j.is_sample_order
    order by j.order_created_at desc nulls last
    limit 80
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'order_id', order_key,
      'marketplace', marketplace,
      'marketplace_account_id', marketplace_account_id,
      'order_created_at', order_created_at,
      'gross_amount', gross_amount,
      'payout_amount', payout_amount,
      'hpp_total', sample_hpp,
      'negative_payout_total', case when payout_amount < 0 then abs(payout_amount) else 0 end,
      'category', 'sample_zero_payment',
      'message', 'Order sample/gratis/pembayaran 0. Perlu dicek karena tidak menghasilkan payout normal.'
    )), '[]'::jsonb),
    coalesce(jsonb_agg(jsonb_build_object(
      'order_id', order_key,
      'marketplace', marketplace,
      'marketplace_account_id', marketplace_account_id,
      'date', order_created_at,
      'gross', gross_amount,
      'payout', payout_amount,
      'hpp_total', sample_hpp,
      'negative_payout_total', case when payout_amount < 0 then abs(payout_amount) else 0 end,
      'qty', 1,
      'type', 'SAMPLE_ZERO_PAYMENT',
      'message', 'Order sample/gratis/pembayaran 0. Masuk abnormal finance agar tidak dianggap profit valid.'
    )), '[]'::jsonb)
  into v_sample_orders, v_abnormals
  from sample_rows;

  return jsonb_build_object(
    'ok', true,
    'reconciliation_source', 'finance_marketplace_reconciliation_breakdown',
    'summary', jsonb_build_object(
      'order_count', v_order_count,
      'finance_order_count', v_order_count,
      'gross_sales', v_gross,
      'payout_total', v_payout,
      'gross_payout_gap', v_gap,
      'discount_amount', v_discount,
      'fee_amount', v_fee,
      'refund_amount', v_refund,
      'tax_amount', v_tax,
      'adjustment_amount', v_adjustment,
      'sample_order_count', v_sample_count,
      'sample_order_gross', v_sample_gross,
      'sample_hpp_total', v_sample_hpp,
      'sample_negative_payout_total', v_sample_negative_payout,
      'sample_loss_estimate', v_sample_loss_estimate,
      'reconciliation_known_total', v_known,
      'reconciliation_unclassified_total', v_other
    ),
    'by_marketplace', v_by_marketplace,
    'profit_loss_breakdown', v_breakdown,
    'sample_orders', v_sample_orders,
    'abnormals', v_abnormals
  );
end;
$$;

grant execute on function public.finance_json_num_fast(jsonb, text) to authenticated, service_role;
grant execute on function public.finance_marketplace_reconciliation_breakdown(date, date, text, uuid) to authenticated, service_role;

notify pgrst, 'reload schema';
