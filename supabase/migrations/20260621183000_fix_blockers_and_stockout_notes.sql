-- Migration: Fix Finance Blockers and Stock Out Notes Regression
-- Created: 2026-06-21

begin;

-- 1. Redefine public.finance_sample_order_counts
create or replace function public.finance_sample_order_counts(
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
set statement_timeout = '30s'
as $$
declare
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_tenant_id uuid;
  v_role text := coalesce(nullif(v_claims->>'role', ''), nullif(current_setting('role', true), ''), current_user);
  v_start date := coalesce(p_start, date_trunc('month', timezone('Asia/Jakarta', now()))::date);
  v_end date := coalesce(p_end, timezone('Asia/Jakarta', now())::date);
  v_marketplace text;
  v_count integer := 0;
  v_rows jsonb := '[]'::jsonb;
  v_summary jsonb := '{}'::jsonb;
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

  if v_marketplace is null and p_account_id is not null then
    select case
      when lower(regexp_replace(coalesce(ma.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
      when lower(regexp_replace(coalesce(ma.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
      else nullif(lower(regexp_replace(coalesce(ma.marketplace, ''), '[^a-z0-9]+', '', 'g')), '')
    end
    into v_marketplace
    from public.marketplace_accounts ma
    where ma.marketplace_account_id = p_account_id
      and coalesce(ma.is_deleted, false) is false
      and (v_role = 'service_role' or ma.tenant_id = v_tenant_id)
    limit 1;
  end if;

  with sample_orders_base as (
    select
      case
        when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
        else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end as marketplace_group,
      o.marketplace_account_id,
      o.marketplace_order_id,
      coalesce(nullif(o.order_sn, ''), nullif(o.external_order_id, ''), nullif(o.order_id, ''), o.marketplace_order_id::text) as order_key,
      o.order_status,
      o.tracking_number,
      o.order_created_at,
      coalesce(o.gross_amount, o.total_amount, o.paid_amount, 0)::numeric as gross_amount,
      coalesce(o.paid_amount, 0)::numeric as paid_amount,
      lower(coalesce(o.payment_method, o.payment_status, '')) as payment_text,
      lower(coalesce(o.order_status, o.status, '')) as status_text
    from public.marketplace_orders o
    where o.order_created_at >= (v_start::timestamp at time zone 'Asia/Jakarta')
      and o.order_created_at < ((v_end + 1)::timestamp at time zone 'Asia/Jakarta')
      and (v_role = 'service_role' or o.tenant_id = v_tenant_id)
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and (
        v_marketplace is null
        or (
          case
            when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
            when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
            else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
          end
        ) = v_marketplace
      )
      -- Align with profit_loss_detail definition of is_sample_order:
      and (
        o.gross_amount <= 0
        or lower(coalesce(o.payment_method, o.payment_status, '')) ~ '(sample|gratis|free|zero|0 payment|no payment|tester|giveaway)'
        or (lower(coalesce(o.payment_method, o.payment_status, '')) = '' and o.gross_amount = 0 and lower(coalesce(o.order_status, o.status, '')) ~ '(complete|completed|delivered|selesai|dikirim|done)')
      )
  ),
  finance_by_order as (
    select
      fr.tenant_id,
      fr.marketplace_account_id,
      fr.order_id as order_key,
      sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0)::numeric) as payout_amount,
      sum(abs(coalesce(fr.discount_amount, 0)::numeric)) as discount_amount,
      sum(abs(coalesce(fr.platform_fee, 0)::numeric)) as platform_fee,
      sum(abs(coalesce(fr.commission_fee, 0)::numeric)) as commission_fee,
      sum(abs(coalesce(fr.affiliate_fee, 0)::numeric)) as affiliate_fee,
      sum(abs(coalesce(fr.shipping_fee, 0)::numeric)) as shipping_fee,
      sum(abs(coalesce(fr.fee_amount, 0)::numeric)) as fee_amount,
      sum(abs(coalesce(fr.total_fees, 0)::numeric)) as total_fees,
      sum(abs(coalesce(fr.refund_amount, 0)::numeric)) as refund_amount,
      sum(coalesce(fr.adjustment_amount, 0)::numeric) as adjustment_amount
    from public.marketplace_finance_reports fr
    where (v_role = 'service_role' or fr.tenant_id = v_tenant_id)
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and fr.order_id in (select order_key from sample_orders_base)
    group by fr.tenant_id, fr.marketplace_account_id, fr.order_id
  ),
  sample_orders_enriched as (
    select
      ob.*,
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
      coalesce(f.adjustment_amount, 0) as adjustment_amount
    from sample_orders_base ob
    left join finance_by_order f
      on f.marketplace_account_id = ob.marketplace_account_id
     and f.order_key = ob.order_key
  ),
  counted as (
    select
      count(*)::integer as total,
      coalesce(sum(gross_amount), 0)::numeric as gross_total,
      coalesce(sum(payout_amount), 0)::numeric as payout_total,
      coalesce(sum(payout_amount) filter (where payout_amount < 0), 0)::numeric as payout_minus_total,
      coalesce(sum(discount_amount), 0)::numeric as discount_total,
      coalesce(sum(shipping_fee), 0)::numeric as shipping_total,
      coalesce(sum(platform_fee + commission_fee + affiliate_fee + other_fee), 0)::numeric as fee_total,
      coalesce(sum(refund_amount), 0)::numeric as refund_total,
      coalesce(sum(adjustment_amount), 0)::numeric as adjustment_total
    from sample_orders_enriched
  ),
  limited as (
    select *
    from sample_orders_enriched
    order by order_created_at desc
    limit 100
  )
  select
    c.total,
    jsonb_build_object(
      'sample_order_count', c.total,
      'sample_free_count', c.total,
      'sample_gross_total', c.gross_total,
      'sample_payout_total', c.payout_total,
      'sample_payout_minus_total', c.payout_minus_total,
      'sample_discount_total', c.discount_total,
      'sample_shipping_total', c.shipping_total,
      'sample_fee_total', c.fee_total,
      'sample_refund_total', c.refund_total,
      'sample_adjustment_total', c.adjustment_total
    ),
    coalesce(jsonb_agg(jsonb_build_object(
      'abnormal_status', 'SAMPLE_FREE',
      'finance_status', 'SAMPLE_FREE',
      'payout_status', 'SAMPLE_FREE',
      'category', 'sample_free',
      'message', 'Sample/Gratis sesuai filter. Tidak masuk omzet normal.',
      'marketplace', marketplace_group,
      'marketplace_account_id', marketplace_account_id,
      'order_id', order_key,
      'order_sn', order_key,
      'external_order_id', order_key,
      'order_status', order_status,
      'order_date', order_created_at,
      'gross_amount', gross_amount,
      'payout_amount', payout_amount,
      'discount_amount', discount_amount,
      'platform_fee', platform_fee,
      'commission_fee', commission_fee,
      'affiliate_fee', affiliate_fee,
      'shipping_fee', shipping_fee,
      'other_fee', other_fee,
      'refund_amount', refund_amount,
      'adjustment_amount', adjustment_amount,
      'resi', tracking_number,
      'is_sample_order', true
    ) order by order_created_at desc), '[]'::jsonb)
  into v_count, v_summary, v_rows
  from limited, counted c
  group by c.total, c.gross_total, c.payout_total, c.payout_minus_total, c.discount_total, c.shipping_total, c.fee_total, c.refund_total, c.adjustment_total;

  return jsonb_build_object(
    'ok', true,
    'source', 'finance_sample_order_counts',
    'timezone', 'Asia/Jakarta',
    'start_date', v_start,
    'end_date', v_end,
    'effective_marketplace', v_marketplace,
    'summary', v_summary,
    'rows', coalesce(v_rows, '[]'::jsonb),
    'sample_orders', coalesce(v_rows, '[]'::jsonb)
  );
end;
$$;

revoke all on function public.finance_sample_order_counts(date, date, text, uuid) from public;
grant execute on function public.finance_sample_order_counts(date, date, text, uuid) to authenticated, service_role;

-- 2. Redefine public.finance_marketplace_reconciliation_breakdown
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
      -- Exclude cancelled/unpaid orders to match profit_loss_detail:
      and lower(coalesce(o.order_status, o.status, '')) !~ '(cancel|batal|dibatalkan|unpaid|belum bayar|belum dibayar)'
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

-- 3. Redefine View public.marketplace_order_items_public
create or replace view public.marketplace_order_items_public as
SELECT i.marketplace_order_item_id,
     i.marketplace_order_id,
     i.tenant_id,
     i.marketplace_account_id,
     i.marketplace,
     i.external_order_id,
     i.external_order_item_id,
     i.marketplace_product_id,
     i.marketplace_sku_id,
     i.seller_sku,
     coalesce(i.product_name, i.raw_item->'normalized_row'->>'product_name', i.raw_item->'raw_row'->>'Product Name', i.raw_item->'raw_row'->>'product_name', '-') AS product_name,
     coalesce(i.variant_name, i.raw_item->'normalized_row'->>'variation', i.raw_item->'raw_row'->>'Variation', i.raw_item->'raw_row'->>'variation', '-') AS variant_name,
     i.quantity,
     i.mapped_product_id,
     i.mapped_local_sku,
     p.nama_barang AS local_product_name,
     p.kode_barcode AS local_barcode,
     COALESCE(p.stock_saat_ini, 0::numeric) AS local_stock,
     marketplace_reserved_qty_for_product(i.tenant_id, i.mapped_product_id) AS reserved_stock_total,
     marketplace_available_stock_for_product(i.tenant_id, i.mapped_product_id) AS available_stock,
     i.marketplace_sku_map_id,
     i.mapping_status,
         CASE i.mapping_status
             WHEN 'mapped'::text THEN 'Mapped'::text
             ELSE 'Unmapped'::text
         END AS mapping_label,
     i.reserved_qty,
     i.scanned_qty,
     i.returned_qty,
     i.stock_action_status,
         CASE i.stock_action_status
             WHEN 'ignored_status'::text THEN 'Waiting Scan'::text
             WHEN 'ignored'::text THEN 'Waiting Scan'::text
             WHEN 'waiting_scan'::text THEN 'Waiting Scan'::text
             WHEN 'reserved'::text THEN 'Waiting Scan'::text
             WHEN 'ready_to_pick'::text THEN 'Ready Pick'::text
             WHEN 'ready_stock_out'::text THEN 'Ready Pick'::text
             WHEN 'partial_scanned'::text THEN 'Partial Scanned'::text
             WHEN 'scanned_done'::text THEN 'Scanned Done'::text
             WHEN 'stock_out_done'::text THEN 'Stock Out Done'::text
             WHEN 'stock_out_failed'::text THEN 'Stock Out Failed'::text
             WHEN 'reserve_failed'::text THEN 'Reserve Failed'::text
             WHEN 'insufficient_stock'::text THEN 'Insufficient Stock'::text
             WHEN 'unmapped'::text THEN 'Unmapped SKU'::text
             ELSE initcap(replace(COALESCE(i.stock_action_status, 'waiting_scan'::text), '_'::text, ' '::text))
         END AS stock_action_label,
     i.last_error,
     i.created_at,
     i.updated_at,
     COALESCE(i.tracking_number, o.tracking_number) AS tracking_number,
     COALESCE(i.package_id, o.package_id) AS package_id,
     COALESCE(ov.override_qty, 0::numeric) AS fulfillment_override_qty,
     COALESCE(ov.actual_local_skus, ''::text) AS fulfillment_override_local_skus,
     COALESCE(ov.actual_product_names, ''::text) AS fulfillment_override_product_names,
     COALESCE(ov.latest_user_note, ''::text) AS fulfillment_override_note
    FROM marketplace_order_items i
      LEFT JOIN marketplace_orders o ON o.marketplace_order_id = i.marketplace_order_id
      LEFT JOIN products p ON p.product_id = i.mapped_product_id
      LEFT JOIN LATERAL ( SELECT sum(fo.qty) AS override_qty,
             string_agg(DISTINCT fo.actual_local_sku, ', '::text ORDER BY fo.actual_local_sku) AS actual_local_skus,
             string_agg(DISTINCT fo.actual_product_name, ', '::text ORDER BY fo.actual_product_name) AS actual_product_names,
             (array_agg(fo.user_note ORDER BY fo.created_at DESC))[1] AS latest_user_note
            FROM marketplace_stock_out_fulfillment_overrides fo
           WHERE fo.tenant_id = i.tenant_id AND fo.marketplace_order_item_id = i.marketplace_order_item_id) ov ON true
   WHERE (EXISTS ( SELECT 1
            FROM users u
           WHERE u.user_id = auth.uid() AND u.tenant_id = i.tenant_id AND u.status = 'active'::text));

grant select on public.marketplace_order_items_public to authenticated;

-- 4. Redefine Stock Out Resi Lookup SQL Functions
create or replace function public.marketplace_find_order_by_resi(
  p_tenant_id uuid,
  p_resi_code text
) returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '30s'
as $function$
declare
  v_code text := lower(trim(coalesce(p_resi_code, '')));
  v_order record;
  v_total_items integer := 0;
  v_scanned_items integer := 0;
  v_marketplace_note text;
  v_buyer_note text;
  v_seller_note text;
  v_physical_resi text;
begin
  if p_tenant_id is null or v_code = '' then
    return jsonb_build_object('ok', false, 'message', 'Scan atau input resi fisik label pengiriman terlebih dahulu.');
  end if;

  perform public.marketplace_assert_tenant_access(p_tenant_id);

  select
    o.*,
    coalesce(nullif(ma.store_alias, ''), nullif(ma.shop_name, ''), nullif(o.shop_id, ''), '-') as account_name,
    coalesce(
      nullif(o.tracking_number, ''),
      nullif(o.raw_order->>'tracking_number', '')
    ) as physical_resi
  into v_order
  from public.marketplace_orders o
  left join public.marketplace_accounts ma
    on ma.marketplace_account_id = o.marketplace_account_id
   and ma.tenant_id = o.tenant_id
  where o.tenant_id = p_tenant_id
    and (
      lower(coalesce(o.tracking_number, '')) = v_code
      or lower(coalesce(o.raw_order->>'tracking_number', '')) = v_code
      or exists (
        select 1
        from public.marketplace_order_items oi
        where oi.tenant_id = o.tenant_id
          and oi.marketplace_order_id = o.marketplace_order_id
          and lower(coalesce(oi.tracking_number, '')) = v_code
      )
    )
  order by coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) desc nulls last,
           o.created_at desc nulls last
  limit 1;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'message', 'Pesanan tidak ditemukan untuk resi fisik tersebut. Jika ini Shopee dan yang muncul masih OFG/package number, tarik/backfill resi fisik dari logistics API dulu.'
    );
  end if;

  v_physical_resi := nullif(v_order.physical_resi, '');
  if v_physical_resi is null then
    v_physical_resi := p_resi_code;
  end if;

  -- Extract Notes Separately from order level and item level
  v_buyer_note := coalesce(
    nullif(trim(v_order.raw_order->>'buyer_note'), ''),
    nullif(trim(v_order.raw_order->>'buyer_message'), ''),
    nullif(trim(v_order.raw_order->>'message_to_seller'), ''),
    (
      select string_agg(distinct nullif(trim(val), ''), E'\n')
      from (
        select coalesce(
          oi.raw_item #>> '{raw_row,Buyer Message}',
          oi.raw_item #>> '{raw_row,buyer_message}',
          oi.raw_item #>> '{raw_row,buyer_note}'
        ) as val
        from public.marketplace_order_items oi
        where oi.tenant_id = p_tenant_id
          and oi.marketplace_order_id = v_order.marketplace_order_id
      ) x
      where val is not null and trim(val) <> ''
    )
  );

  v_seller_note := coalesce(
    nullif(trim(v_order.note), ''),
    nullif(trim(v_order.raw_order->>'seller_note'), ''),
    nullif(trim(v_order.raw_order->>'seller_remark'), ''),
    nullif(trim(v_order.raw_order->>'remark'), ''),
    (
      select string_agg(distinct nullif(trim(val), ''), E'\n')
      from (
        select coalesce(
          oi.raw_item #>> '{raw_row,Seller Note}',
          oi.raw_item #>> '{raw_row,seller_note}',
          oi.raw_item #>> '{raw_row,note}',
          oi.raw_item #>> '{raw_row,remark}'
        ) as val
        from public.marketplace_order_items oi
        where oi.tenant_id = p_tenant_id
          and oi.marketplace_order_id = v_order.marketplace_order_id
      ) x
      where val is not null and trim(val) <> ''
    )
  );

  v_marketplace_note := trim(coalesce(nullif(v_buyer_note, ''), '') || E'\n' || coalesce(nullif(v_seller_note, ''), ''));
  if v_marketplace_note = '' then
    v_marketplace_note := null;
  end if;

  select
    count(*)::integer,
    count(*) filter (
      where coalesce(oi.scanned_qty, 0) >= greatest(coalesce(nullif(oi.quantity, 0), nullif(oi.qty, 0), 1), 1)
    )::integer
  into v_total_items, v_scanned_items
  from public.marketplace_order_items oi
  where oi.tenant_id = p_tenant_id
    and oi.marketplace_order_id = v_order.marketplace_order_id;

  return jsonb_build_object(
    'ok', true,
    'message', 'Pesanan ditemukan dari resi fisik. Silakan lanjut scan item.',
    'marketplace_order_id', v_order.marketplace_order_id,
    'marketplace', v_order.marketplace,
    'account_name', v_order.account_name,
    'shop_name', v_order.account_name,
    'external_order_id', coalesce(nullif(v_order.external_order_id, ''), nullif(v_order.order_sn, ''), nullif(v_order.order_id, ''), v_order.marketplace_order_id::text),
    'order_sn', v_order.order_sn,
    'tracking_number', v_physical_resi,
    'physical_resi', v_physical_resi,
    'order_status', coalesce(v_order.order_status, v_order.status),
    'marketplace_note', coalesce(v_marketplace_note, 'Tidak ada catatan'),
    'seller_note', coalesce(v_seller_note, 'Tidak ada catatan'),
    'buyer_note', coalesce(v_buyer_note, 'Tidak ada catatan'),
    'order_date', (coalesce(v_order.order_created_at, v_order.paid_at, v_order.created_time, v_order.created_at) at time zone 'Asia/Jakarta')::date,
    'total_items', coalesce(v_total_items, 0),
    'processed', coalesce(v_scanned_items, 0),
    'order_ready_to_finalize', coalesce(v_total_items, 0) > 0 and coalesce(v_scanned_items, 0) >= coalesce(v_total_items, 0)
  );
end;
$function$;

grant execute on function public.marketplace_find_order_by_resi(uuid, text) to authenticated, service_role;

-- 5. Redefine public.marketplace_scan_order_item_by_resi
create or replace function public.marketplace_scan_order_item_by_resi(
  p_tenant_id uuid,
  p_resi_code text,
  p_scan_code text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_found jsonb;
  v_order_id uuid;
  v_scan jsonb;
begin
  v_found := public.marketplace_find_order_by_resi(p_tenant_id, p_resi_code);
  if coalesce((v_found->>'ok')::boolean, false) = false then
    return v_found;
  end if;

  v_order_id := nullif(v_found->>'marketplace_order_id', '')::uuid;
  v_scan := public.marketplace_scan_order_item_barcode(p_tenant_id, v_order_id, p_scan_code);

  return coalesce(v_scan, '{}'::jsonb) || jsonb_build_object(
    'marketplace_order_id', v_order_id,
    'external_order_id', v_found->>'external_order_id',
    'tracking_number', v_found->>'tracking_number',
    'buyer_note', v_found->'buyer_note',
    'seller_note', v_found->'seller_note',
    'marketplace_note', v_found->'marketplace_note'
  );
end;
$function$;

grant execute on function public.marketplace_scan_order_item_by_resi(uuid, text, text) to authenticated, service_role;

commit;

-- Notify postgrest schema reload
notify pgrst, 'reload schema';
