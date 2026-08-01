-- Fast resume for finance marketplace reconciliation.
-- Replaces the heavy JSON parser scan with a constrained period/account aggregation.

create index if not exists idx_finance_reports_account_created
  on public.marketplace_finance_reports(marketplace_account_id, created_at desc);

create index if not exists idx_finance_reports_account_order
  on public.marketplace_finance_reports(marketplace_account_id, order_id);

create index if not exists idx_orders_account_created
  on public.marketplace_orders(marketplace_account_id, order_created_at desc);

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
stable
security definer
set search_path = public
set statement_timeout = '90s'
as $$
declare
  v_tenant_id uuid := null;
  v_start timestamptz := case when p_start is null then null else (p_start::timestamp - interval '7 hours')::timestamptz end;
  v_end timestamptz := case when p_end is null then null else ((p_end + 1)::timestamp - interval '7 hours')::timestamptz end;

  v_order_count int := 0;
  v_gross numeric := 0;
  v_payout numeric := 0;
  v_gap numeric := 0;
  v_fee numeric := 0;
  v_discount numeric := 0;
  v_tax numeric := 0;
  v_refund numeric := 0;
  v_sample_count int := 0;
  v_sample_gross numeric := 0;
  v_known numeric := 0;
  v_other numeric := 0;

  v_breakdown jsonb := '[]'::jsonb;
  v_sample_orders jsonb := '[]'::jsonb;
  v_abnormals jsonb := '[]'::jsonb;
begin
  begin
    v_tenant_id := nullif(current_setting('request.jwt.claims', true)::jsonb->>'tenant_id', '')::uuid;
  exception when others then
    v_tenant_id := null;
  end;

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
      lower(coalesce(
        to_jsonb(o)->>'payment_method',
        to_jsonb(o)->>'payment_channel',
        to_jsonb(o)->>'payment_status',
        ''
      )) as payment_text,
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
      abs(
        public.finance_json_num_fast(to_jsonb(fr), 'voucher_amount') +
        public.finance_json_num_fast(to_jsonb(fr), 'seller_voucher') +
        public.finance_json_num_fast(to_jsonb(fr), 'platform_voucher') +
        public.finance_json_num_fast(to_jsonb(fr), 'discount_amount') +
        public.finance_json_num_fast(to_jsonb(fr), 'seller_discount') +
        public.finance_json_num_fast(to_jsonb(fr), 'platform_discount')
      ) as discount_amount,
      abs(
        public.finance_json_num_fast(to_jsonb(fr), 'commission_fee') +
        public.finance_json_num_fast(to_jsonb(fr), 'service_fee') +
        public.finance_json_num_fast(to_jsonb(fr), 'transaction_fee') +
        public.finance_json_num_fast(to_jsonb(fr), 'admin_fee') +
        public.finance_json_num_fast(to_jsonb(fr), 'platform_fee') +
        public.finance_json_num_fast(to_jsonb(fr), 'marketplace_fee')
      ) as fee_amount,
      abs(
        public.finance_json_num_fast(to_jsonb(fr), 'tax_amount') +
        public.finance_json_num_fast(to_jsonb(fr), 'vat_amount') +
        public.finance_json_num_fast(to_jsonb(fr), 'ppn') +
        public.finance_json_num_fast(to_jsonb(fr), 'pph') +
        public.finance_json_num_fast(to_jsonb(fr), 'withholding_tax')
      ) as tax_amount,
      abs(
        public.finance_json_num_fast(to_jsonb(fr), 'refund_amount') +
        public.finance_json_num_fast(to_jsonb(fr), 'return_refund_amount') +
        public.finance_json_num_fast(to_jsonb(fr), 'reverse_amount') +
        public.finance_json_num_fast(to_jsonb(fr), 'cancellation_amount')
      ) as refund_amount
    from public.marketplace_finance_reports fr
    where (v_tenant_id is null or fr.tenant_id = v_tenant_id)
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and (
        p_marketplace is null or p_marketplace = '' or p_marketplace = 'all'
        or coalesce(to_jsonb(fr)->>'marketplace', '') = p_marketplace
      )
      and (
        p_start is null
        or fr.created_at >= (p_start::timestamp - interval '120 days')
      )
      and (
        p_end is null
        or fr.created_at < ((p_end + 1)::timestamp + interval '30 days')
      )
  ),
  finance_by_order as (
    select
      tenant_id,
      marketplace_account_id,
      order_key,
      sum(payout_amount) as payout_amount,
      sum(discount_amount) as discount_amount,
      sum(fee_amount) as fee_amount,
      sum(tax_amount) as tax_amount,
      sum(refund_amount) as refund_amount
    from scoped_finance
    where coalesce(order_key, '') <> ''
    group by tenant_id, marketplace_account_id, order_key
  ),
  joined as (
    select
      o.*,
      coalesce(f.payout_amount, 0) as payout_amount,
      coalesce(f.discount_amount, 0) as discount_amount,
      coalesce(f.fee_amount, 0) as fee_amount,
      coalesce(f.tax_amount, 0) as tax_amount,
      coalesce(f.refund_amount, 0) as refund_amount,
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
  )
  select
    count(*)::int,
    coalesce(sum(gross_amount), 0),
    coalesce(sum(payout_amount), 0),
    coalesce(sum(discount_amount), 0),
    coalesce(sum(fee_amount), 0),
    coalesce(sum(tax_amount), 0),
    coalesce(sum(refund_amount), 0),
    count(*) filter (where is_sample_order)::int,
    coalesce(sum(gross_amount) filter (where is_sample_order), 0)
  into
    v_order_count,
    v_gross,
    v_payout,
    v_discount,
    v_fee,
    v_tax,
    v_refund,
    v_sample_count,
    v_sample_gross
  from joined;

  v_gap := greatest(v_gross - v_payout, 0);
  v_known := coalesce(v_discount, 0) + coalesce(v_fee, 0) + coalesce(v_tax, 0) + coalesce(v_refund, 0) + coalesce(v_sample_gross, 0);
  v_other := greatest(v_gap - v_known, 0);

  v_breakdown := (
    select coalesce(jsonb_agg(item), '[]'::jsonb)
    from (
      select jsonb_build_object(
        'label', 'Voucher / diskon',
        'category', 'voucher_discount',
        'description', 'Diskon, voucher seller/platform, promo, atau coin discount dari settlement.',
        'amount', v_discount,
        'order_count', null
      ) item where v_discount > 0
      union all
      select jsonb_build_object(
        'label', 'Fee / komisi marketplace',
        'category', 'marketplace_fee',
        'description', 'Komisi, service fee, transaction fee, admin fee, affiliate fee, atau biaya marketplace.',
        'amount', v_fee,
        'order_count', null
      ) where v_fee > 0
      union all
      select jsonb_build_object(
        'label', 'Pajak marketplace',
        'category', 'tax',
        'description', 'PPN, PPh, withholding tax, VAT, atau pajak lain dari settlement.',
        'amount', v_tax,
        'order_count', null
      ) where v_tax > 0
      union all
      select jsonb_build_object(
        'label', 'Refund / retur / batal',
        'category', 'refund_return_cancel',
        'description', 'Pengembalian dana, retur, pembatalan, koreksi reverse, atau settlement negatif.',
        'amount', v_refund,
        'order_count', null
      ) where v_refund > 0
      union all
      select jsonb_build_object(
        'label', 'Sample / gratis / pembayaran 0',
        'category', 'sample_zero_payment',
        'description', 'Order sample/gratis/zero payment. Masuk laporan sebagai penyesuaian karena tidak menghasilkan payout normal.',
        'amount', v_sample_gross,
        'order_count', v_sample_count
      ) where v_sample_count > 0
      union all
      select jsonb_build_object(
        'label', 'Penyesuaian belum terklasifikasi',
        'category', 'unclassified_adjustment',
        'description', 'Selisih omzet dan payout yang belum bisa diklasifikasi dari kolom settlement. Perlu cek detail settlement marketplace.',
        'amount', v_other,
        'order_count', null
      ) where v_other > 0
    ) rows
  );

  with sample_rows as (
    select *
    from (
      select
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
    ) s
    where s.gross_amount <= 0
       or s.payment_text ~ '(sample|gratis|free|zero|0 payment|no payment|tester|giveaway)'
       or (s.payment_text = '' and s.gross_amount = 0 and s.status_text ~ '(complete|completed|delivered|selesai|dikirim|done)')
    order by s.order_created_at desc nulls last
    limit 80
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'order_id', order_key,
      'marketplace', marketplace,
      'marketplace_account_id', marketplace_account_id,
      'order_created_at', order_created_at,
      'gross_amount', gross_amount,
      'payout_amount', 0,
      'payment_method', payment_text,
      'order_status', status_text,
      'category', 'sample_zero_payment',
      'message', 'Order sample/gratis/pembayaran 0. Perlu dicek karena tidak menghasilkan payout normal.'
    )), '[]'::jsonb),
    coalesce(jsonb_agg(jsonb_build_object(
      'order_id', order_key,
      'marketplace', marketplace,
      'marketplace_account_id', marketplace_account_id,
      'date', order_created_at,
      'gross', gross_amount,
      'payout', 0,
      'qty', 1,
      'type', 'SAMPLE_ZERO_PAYMENT',
      'status', status_text,
      'message', 'Order sample/gratis/pembayaran 0. Masuk abnormal finance agar tidak dianggap profit valid.'
    )), '[]'::jsonb)
  into v_sample_orders, v_abnormals
  from sample_rows;

  return jsonb_build_object(
    'ok', true,
    'summary', jsonb_build_object(
      'order_count', v_order_count,
      'gross_sales', v_gross,
      'payout_total', v_payout,
      'gross_payout_gap', v_gap,
      'sample_order_count', v_sample_count,
      'sample_order_gross', v_sample_gross,
      'reconciliation_known_total', v_known,
      'reconciliation_unclassified_total', v_other
    ),
    'profit_loss_breakdown', v_breakdown,
    'sample_orders', v_sample_orders,
    'abnormals', v_abnormals
  );
end;
$$;

grant execute on function public.finance_json_num_fast(jsonb, text) to authenticated, service_role;
grant execute on function public.finance_marketplace_reconciliation_breakdown(date, date, text, uuid) to authenticated, service_role;

notify pgrst, 'reload schema';
