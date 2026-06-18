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

  create temporary table if not exists _finance_recon_joined (
    marketplace_order_id uuid,
    tenant_id uuid,
    marketplace_account_id uuid,
    marketplace text,
    order_created_at timestamptz,
    order_key text,
    gross_amount numeric,
    payout_amount numeric,
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
    is_sample_order
  )
  with scoped_orders as (
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
  finance_by_order as (
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
      sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0)::numeric) as payout_amount
    from public.marketplace_finance_reports fr
    where (v_tenant_id is null or fr.tenant_id = v_tenant_id)
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and (p_marketplace is null or p_marketplace = '' or p_marketplace = 'all' or coalesce(to_jsonb(fr)->>'marketplace', '') = p_marketplace)
    group by fr.tenant_id, fr.marketplace_account_id, order_key
  )
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
    coalesce(sum(gross_amount), 0),
    coalesce(sum(payout_amount), 0),
    count(*) filter (where is_sample_order)::int,
    coalesce(sum(coalesce(sh.sample_hpp, 0)) filter (where j.is_sample_order), 0),
    coalesce(sum(abs(j.payout_amount)) filter (where j.is_sample_order and j.payout_amount < 0), 0)
  into
    v_order_count,
    v_gross,
    v_payout,
    v_sample_count,
    v_sample_hpp,
    v_sample_negative_payout
  from _finance_recon_joined j
  left join _finance_recon_sample_hpp sh
    on sh.marketplace_order_id = j.marketplace_order_id;

  v_gap := greatest(v_gross - v_payout, 0);
  v_sample_loss_estimate := v_sample_hpp + v_sample_negative_payout;

  v_breakdown := jsonb_build_array(
    jsonb_build_object(
      'label', 'Sample / gratis / pembayaran 0',
      'category', 'sample_zero_payment',
      'description', 'Order sample/gratis/zero payment. Dampak dihitung dari HPP sample dan payout minus sample.',
      'amount', v_sample_loss_estimate,
      'hpp_total', v_sample_hpp,
      'negative_payout_total', v_sample_negative_payout,
      'order_count', v_sample_count
    ),
    jsonb_build_object(
      'label', 'Penyesuaian omzet vs payout',
      'category', 'unclassified_adjustment',
      'description', 'Selisih omzet dan payout yang belum diklasifikasi detail.',
      'amount', greatest(v_gap - v_sample_loss_estimate, 0),
      'order_count', null
    )
  );

  with marketplace_group as (
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
    from _finance_recon_joined j
    left join public.marketplace_accounts a
      on a.marketplace_account_id = j.marketplace_account_id
    left join _finance_recon_sample_hpp sh
      on sh.marketplace_order_id = j.marketplace_order_id
    group by j.marketplace, j.marketplace_account_id, coalesce(a.shop_name, a.store_alias, to_jsonb(a)->>'seller_name', j.marketplace)
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
    'sample_order_count', sample_order_count,
    'sample_hpp_total', sample_hpp_total,
    'sample_negative_payout_total', sample_negative_payout_total,
    'sample_loss_estimate', sample_hpp_total + sample_negative_payout_total,
    'last_updated_at', last_updated_at
  ) order by marketplace, shop_name), '[]'::jsonb)
  into v_by_marketplace
  from marketplace_group;

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

grant execute on function public.finance_marketplace_reconciliation_breakdown(date, date, text, uuid)
  to authenticated, service_role;

notify pgrst, 'reload schema';
