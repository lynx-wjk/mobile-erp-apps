-- Migration: Fix SKU detail columns and optimize sample count & reconciliation breakdown

begin;

-- 1. Redefine finance_sku_order_line_details with the correct FROM clause in the final SELECT
create or replace function public.finance_sku_order_line_details(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null,
  p_marketplace_sku text default null,
  p_local_sku text default null,
  p_search text default null,
  p_payout_filter text default 'all',
  p_page integer default 1,
  p_page_size integer default 25
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '8s'
as $$
declare
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_tenant_id uuid;
  v_role text := coalesce(nullif(v_claims->>'role', ''), nullif(current_setting('role', true), ''), current_user);
  v_start date := coalesce(p_start, date_trunc('month', timezone('Asia/Jakarta', now()))::date);
  v_end date := coalesce(p_end, timezone('Asia/Jakarta', now())::date);
  v_start_ts timestamptz;
  v_end_ts timestamptz;
  v_marketplace text;
  v_marketplace_sku_raw text := nullif(trim(coalesce(p_marketplace_sku, '')), '');
  v_local_sku_raw text := nullif(trim(coalesce(p_local_sku, '')), '');
  v_marketplace_sku text := lower(nullif(trim(coalesce(p_marketplace_sku, '')), ''));
  v_local_sku text := lower(nullif(trim(coalesce(p_local_sku, '')), ''));
  v_search text := lower(nullif(trim(coalesce(p_search, '')), ''));
  v_filter text := lower(trim(coalesce(p_payout_filter, 'all')));
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_page_size integer := least(greatest(coalesce(p_page_size, 25), 1), 25);
  v_offset integer;
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

  v_start_ts := (v_start::timestamp at time zone 'Asia/Jakarta');
  v_end_ts := ((v_end + 1)::timestamp at time zone 'Asia/Jakarta');
  v_offset := (v_page - 1) * v_page_size;
  v_filter := case
    when v_filter in ('settled', 'released', 'release', 'payout', 'paid', 'paid payout', 'sudah payout') then 'paid'
    when v_filter in ('pending', 'unpaid', 'belum payout', 'no payout', 'missing payout') then 'unpaid'
    when v_filter = '' then 'all'
    else v_filter
  end;
  v_marketplace := case
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
    else null
  end;

  if v_role <> 'service_role' and v_tenant_id is null then
    return jsonb_build_object('rows', '[]'::jsonb, 'page', v_page, 'page_size', v_page_size, 'total', 0, 'total_count', 0, 'total_pages', 1, 'source', 'finance_sku_order_line_details_page_first');
  end if;

  if v_marketplace_sku is null and v_local_sku is null and v_search is null then
    return jsonb_build_object('rows', '[]'::jsonb, 'page', v_page, 'page_size', v_page_size, 'total', 0, 'total_count', 0, 'total_pages', 1, 'source', 'finance_sku_order_line_details_page_first');
  end if;

  return (
    with matched_with_extra as materialized (
      select
        o.marketplace_order_id,
        o.tenant_id,
        o.marketplace_account_id,
        o.order_created_at,
        timezone('Asia/Jakarta', o.order_created_at)::date as order_date,
        coalesce(nullif(o.order_id::text, ''), nullif(o.order_sn::text, ''), nullif(o.external_order_id::text, ''), o.marketplace_order_id::text) as order_key,
        coalesce(nullif(o.order_sn::text, ''), nullif(o.external_order_id::text, ''), nullif(o.order_id::text, '')) as order_sn,
        coalesce(nullif(o.tracking_number, ''), nullif(o.label_code, ''), nullif(o.package_id, '')) as tracking_number,
        lower(concat_ws(' ', o.order_status, o.status, o.payment_status, o.fulfillment_status, o.order_status_label)) as status_text,
        coalesce(nullif(o.order_status, ''), nullif(o.status, ''), nullif(o.order_status_label, '')) as order_status,
        coalesce(nullif(o.order_status_label, ''), nullif(o.order_status, ''), nullif(o.status, '')) as order_status_label,
        case
          when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
          else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end as marketplace_group,
        oi.marketplace_order_item_id,
        coalesce(nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, '')) as marketplace_sku_id,
        coalesce(nullif(oi.marketplace_sku, ''), nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, '')) as marketplace_sku,
        coalesce(nullif(oi.marketplace_seller_sku, ''), nullif(oi.seller_sku, '')) as marketplace_seller_sku,
        coalesce(nullif(oi.local_sku, ''), nullif(oi.mapped_local_sku, '')) as local_sku,
        coalesce(nullif(oi.marketplace_product_name, ''), nullif(oi.product_name, ''), nullif(oi.local_product_name, '')) as product_name,
        coalesce(nullif(oi.marketplace_variant_name, ''), nullif(oi.variant_name, ''), nullif(oi.variation_name, '')) as variant_name,
        greatest(coalesce(nullif(oi.qty, 0), nullif(oi.quantity, 0), 1), 1)::numeric as qty,
        coalesce(
          nullif(oi.gross_amount, 0),
          nullif(oi.paid_amount, 0),
          nullif(oi.unit_gross_amount, 0) * greatest(coalesce(nullif(oi.qty, 0), nullif(oi.quantity, 0), 1), 1),
          0
        )::numeric as line_gross
      from public.marketplace_order_items oi
      join public.marketplace_orders o
        on o.tenant_id = oi.tenant_id
        and o.marketplace_order_id = oi.marketplace_order_id
      where o.order_created_at >= v_start_ts
        and o.order_created_at < v_end_ts
        and (v_role = 'service_role' or oi.tenant_id = v_tenant_id)
        and (v_role = 'service_role' or o.tenant_id = v_tenant_id)
        and (p_account_id is null or oi.marketplace_account_id = p_account_id)
        and (p_account_id is null or o.marketplace_account_id = p_account_id)
        and (
          v_marketplace_sku is null
          or oi.marketplace_sku_id = v_marketplace_sku_raw
          or oi.marketplace_sku = v_marketplace_sku_raw
          or oi.remote_sku_id = v_marketplace_sku_raw
          or oi.marketplace_seller_sku = v_marketplace_sku_raw
          or oi.seller_sku = v_marketplace_sku_raw
          or v_marketplace_sku in (
              lower(coalesce(oi.marketplace_sku_id, '')),
              lower(coalesce(oi.marketplace_sku, '')),
              lower(coalesce(oi.remote_sku_id, '')),
              lower(coalesce(oi.marketplace_seller_sku, '')),
              lower(coalesce(oi.seller_sku, ''))
            )
        )
        and (
          v_local_sku is null
          or oi.local_sku = v_local_sku_raw
          or oi.mapped_local_sku = v_local_sku_raw
          or v_local_sku = lower(coalesce(oi.local_sku, oi.mapped_local_sku, ''))
        )
        and (
          v_search is null
          or lower(concat_ws(' ', o.order_id, o.order_sn, o.external_order_id, o.tracking_number, oi.marketplace_sku_id, oi.marketplace_sku, oi.marketplace_seller_sku, oi.seller_sku, oi.local_sku, oi.mapped_local_sku, oi.marketplace_product_name, oi.product_name, oi.marketplace_variant_name, oi.variant_name)) like '%' || v_search || '%'
        )
        and (v_marketplace is null or (
          case
            when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
            when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
            else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
          end
        ) = v_marketplace)
        and lower(concat_ws(' ', o.order_status, o.status, o.payment_status, o.fulfillment_status, o.order_status_label)) not like '%cancel%'
        and lower(concat_ws(' ', o.order_status, o.status, o.payment_status, o.fulfillment_status, o.order_status_label)) not like '%batal%'
        and lower(concat_ws(' ', o.order_status, o.status, o.payment_status, o.fulfillment_status, o.order_status_label)) not like '%unpaid%'
        and lower(concat_ws(' ', o.order_status, o.status, o.payment_status, o.fulfillment_status, o.order_status_label)) not like '%in_cancel%'
        and (
          v_filter = 'all'
          or (
            v_filter = 'paid'
            and exists (
              select 1
              from public.marketplace_finance_reports fr
              where fr.tenant_id = o.tenant_id
                and fr.marketplace_account_id = o.marketplace_account_id
                and (
                  fr.marketplace_order_id = o.marketplace_order_id
                  or fr.order_id = coalesce(nullif(o.order_id::text, ''), nullif(o.order_sn::text, ''), nullif(o.external_order_id::text, ''), o.marketplace_order_id::text)
                )
            )
          )
          or (
            v_filter = 'unpaid'
            and not exists (
              select 1
              from public.marketplace_finance_reports fr
              where fr.tenant_id = o.tenant_id
                and fr.marketplace_account_id = o.marketplace_account_id
                and (
                  fr.marketplace_order_id = o.marketplace_order_id
                  or fr.order_id = coalesce(nullif(o.order_id::text, ''), nullif(o.order_sn::text, ''), nullif(o.external_order_id::text, ''), o.marketplace_order_id::text)
                )
            )
          )
        )
      order by o.order_created_at desc, coalesce(nullif(o.order_id::text, ''), nullif(o.order_sn::text, ''), nullif(o.external_order_id::text, ''), o.marketplace_order_id::text), oi.marketplace_order_item_id
      offset v_offset
      limit v_page_size + 1
    ),
    paged as (
      select *
      from matched_with_extra
      order by order_created_at desc, order_key, marketplace_order_item_id
      limit v_page_size
    ),
    page_meta as (
      select
        (select count(*)::integer from paged) as visible_count,
        (select count(*)::integer from matched_with_extra) > v_page_size as has_more
    ),
    enriched as (
      select
        pl.*,
        coalesce(olt.order_line_gross, pl.line_gross, 0)::numeric as order_line_gross,
        coalesce(fin.order_payout, 0)::numeric as order_payout,
        coalesce(fin.has_payout, false) as has_payout,
        coalesce(fin.statement_id, '') as statement_id,
        coalesce(fin.settlement_status, '') as settlement_status,
        fin.settlement_date,
        coalesce(fin.payout_source, '') as payout_source,
        coalesce(fin.platform_fee, 0)::numeric as platform_fee,
        coalesce(fin.commission_fee, 0)::numeric as commission_fee,
        coalesce(fin.affiliate_fee, 0)::numeric as affiliate_fee,
        coalesce(fin.shipping_fee, 0)::numeric as shipping_fee,
        coalesce(fin.discount_amount, 0)::numeric as discount_amount,
        coalesce(fin.refund_amount, 0)::numeric as refund_amount,
        coalesce(fin.adjustment_amount, 0)::numeric as adjustment_amount,
        coalesce(fin.fee_amount, 0)::numeric as fee_amount,
        coalesce(hpp.unit_hpp, 0)::numeric as unit_hpp,
        coalesce(hpp.target_margin, 0)::numeric as target_margin
      from paged pl
      left join lateral (
        select coalesce(sum(coalesce(
          nullif(oi2.gross_amount, 0),
          nullif(oi2.paid_amount, 0),
          nullif(oi2.unit_gross_amount, 0) * greatest(coalesce(nullif(oi2.qty, 0), nullif(oi2.quantity, 0), 1), 1),
          0
        )), 0)::numeric as order_line_gross
        from public.marketplace_order_items oi2
        where oi2.tenant_id = pl.tenant_id
          and oi2.marketplace_order_id = pl.marketplace_order_id
      ) olt on true
      left join lateral (
        select
          coalesce(sum(coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)), 0)::numeric as order_payout,
          count(fr.finance_report_id) > 0 as has_payout,
          max(nullif(fr.statement_id, '')) as statement_id,
          max(nullif(fr.settlement_status, '')) as settlement_status,
          max(fr.settlement_date) as settlement_date,
          coalesce(sum(fr.platform_fee), 0)::numeric as platform_fee,
          coalesce(sum(fr.commission_fee), 0)::numeric as commission_fee,
          coalesce(sum(fr.affiliate_fee), 0)::numeric as affiliate_fee,
          coalesce(sum(fr.shipping_fee), 0)::numeric as shipping_fee,
          coalesce(sum(fr.discount_amount), 0)::numeric as discount_amount,
          coalesce(sum(coalesce(fr.refund_amount, fr.total_refund, 0)), 0)::numeric as refund_amount,
          coalesce(sum(fr.adjustment_amount), 0)::numeric as adjustment_amount,
          coalesce(sum(coalesce(fr.fee_amount, fr.total_fees, 0)), 0)::numeric as fee_amount,
          case
            when count(fr.payout_amount) filter (where fr.payout_amount is not null) > 0 then 'marketplace_finance_reports.payout_amount'
            when count(fr.received_amount) filter (where fr.received_amount is not null) > 0 then 'marketplace_finance_reports.received_amount'
            when count(fr.net_settlement) filter (where fr.net_settlement is not null) > 0 then 'marketplace_finance_reports.net_settlement'
            when count(fr.finance_report_id) > 0 then 'marketplace_finance_reports.settlement_status'
            else ''
          end as payout_source
        from public.marketplace_finance_reports fr
        where fr.tenant_id = pl.tenant_id
          and fr.marketplace_account_id = pl.marketplace_account_id
          and (
            fr.marketplace_order_id = pl.marketplace_order_id
            or fr.order_id = pl.order_key
          )
      ) fin on true
      left join lateral (
        select
          max(coalesce(m.hpp, m.hpp_amount, m.hpp_per_item, 0))::numeric as unit_hpp,
          max(coalesce(m.target_margin_percent, m.target_margin, 0))::numeric as target_margin
        from public.marketplace_variant_hpp_mappings m
        where m.tenant_id = pl.tenant_id
          and m.marketplace_account_id = pl.marketplace_account_id
          and coalesce(m.is_active, true) is true
          and (
            lower(nullif(m.marketplace_sku_id, '')) = lower(nullif(pl.marketplace_sku_id, ''))
            or lower(nullif(m.marketplace_seller_sku, '')) = lower(nullif(pl.marketplace_seller_sku, ''))
            or lower(nullif(m.local_sku, '')) = lower(nullif(pl.local_sku, ''))
          )
      ) hpp on true
    )
    select jsonb_build_object(
      'rows', coalesce(jsonb_agg((
        jsonb_build_object(
          'source', 'finance_sku_order_line_details_page_first',
          'sku_detail_source', 'finance_sku_order_line_details_page_first',
          'payout_source', nullif(payout_source, ''),
          'order', order_key,
          'order_id', order_key,
          'order_sn', order_sn,
          'marketplace_order_id', marketplace_order_id,
          'marketplace_order_item_id', marketplace_order_item_id,
          'resi', tracking_number,
          'tracking_number', tracking_number,
          'order_date', order_created_at,
          'order_created_at', order_created_at,
          'marketplace', marketplace_group,
          'marketplace_account_id', marketplace_account_id,
          'order_payout', order_payout,
          'order_line_gross', order_line_gross
        ) ||
        jsonb_build_object(
          'status', order_status,
          'order_status', order_status,
          'order_status_label', order_status_label,
          'local_sku', coalesce(nullif(local_sku, ''), '-'),
          'sku', coalesce(nullif(local_sku, ''), nullif(marketplace_sku_id, ''), nullif(marketplace_seller_sku, ''), '-'),
          'marketplace_sku_id', marketplace_sku_id,
          'marketplace_sku', marketplace_sku,
          'marketplace_seller_sku', marketplace_seller_sku,
          'product_name', product_name,
          'variant_name', variant_name,
          'marketplace_variation_name', variant_name,
          'qty', qty,
          'quantity', qty,
          'gross', line_gross,
          'gross_amount', line_gross,
          'gross_total', line_gross,
          'gross_per_item', case when qty > 0 then line_gross / qty else 0 end,
          'payout', case when has_payout and order_line_gross > 0 then order_payout * (line_gross / order_line_gross) else 0 end,
          'payout_amount', case when has_payout and order_line_gross > 0 then order_payout * (line_gross / order_line_gross) else 0 end,
          'payout_per_item', case when has_payout and order_line_gross > 0 and qty > 0 then (order_payout * (line_gross / order_line_gross)) / qty else 0 end
        ) ||
        jsonb_build_object(
          'platform_fee_item', case when has_payout and order_line_gross > 0 then platform_fee * (line_gross / order_line_gross) else 0 end,
          'commission_fee_item', case when has_payout and order_line_gross > 0 then commission_fee * (line_gross / order_line_gross) else 0 end,
          'affiliate_fee_item', case when has_payout and order_line_gross > 0 then affiliate_fee * (line_gross / order_line_gross) else 0 end,
          'shipping_fee_item', case when has_payout and order_line_gross > 0 then shipping_fee * (line_gross / order_line_gross) else 0 end,
          'discount_amount_item', case when has_payout and order_line_gross > 0 then discount_amount * (line_gross / order_line_gross) else 0 end,
          'refund_amount_item', case when has_payout and order_line_gross > 0 then refund_amount * (line_gross / order_line_gross) else 0 end,
          'adjustment_amount_item', case when has_payout and order_line_gross > 0 then adjustment_amount * (line_gross / order_line_gross) else 0 end,
          'fee_amount_item', case when has_payout and order_line_gross > 0 then fee_amount * (line_gross / order_line_gross) else 0 end,
          'hpp', unit_hpp * qty,
          'hpp_total', unit_hpp * qty,
          'hpp_per_item', unit_hpp,
          'unit_hpp', unit_hpp,
          'hpp_status', case when unit_hpp > 0 then 'HPP mapping' else 'HPP belum mapping' end,
          'target_margin_percent', target_margin,
          'statement_id', nullif(statement_id, ''),
          'settlement_ref', nullif(statement_id, ''),
          'settlement_status', case when has_payout then coalesce(nullif(settlement_status, ''), 'SETTLED') else 'PENDING_PAYOUT' end,
          'settlement_date', settlement_date,
          'finance_status', case when has_payout then coalesce(nullif(settlement_status, ''), 'SETTLED') else 'PENDING_PAYOUT' end,
          'payout_status', case when has_payout then coalesce(nullif(settlement_status, ''), 'SETTLED') else 'PENDING_PAYOUT' end
        )
      ) order by order_created_at desc, order_key, marketplace_order_item_id)
        filter (where marketplace_order_item_id is not null), '[]'::jsonb),
      'page', v_page,
      'page_size', v_page_size,
      'total', v_offset + page_meta.visible_count + case when page_meta.has_more then 1 else 0 end,
      'total_count', v_offset + page_meta.visible_count + case when page_meta.has_more then 1 else 0 end,
      'total_pages', case when page_meta.has_more then v_page + 1 else greatest(v_page, 1) end,
      'has_more', page_meta.has_more,
      'source', 'finance_sku_order_line_details_page_first'
    )
    from page_meta
    left join enriched on true
    group by page_meta.visible_count, page_meta.has_more
  );
end;
$$;

grant execute on function public.finance_sku_order_line_details(date, date, text, uuid, text, text, text, text, integer, integer) to authenticated, service_role;


-- 2. Redefine finance_sample_order_counts with optimizations, parameter default count_only = true, and pagination
create or replace function public.finance_sample_order_counts(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null,
  p_count_only boolean default true,
  p_page integer default 1,
  p_page_size integer default 50
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

  with all_orders_base as (
    select
      o.tenant_id,
      case
        when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
        else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end as marketplace_group,
      o.marketplace_account_id,
      o.marketplace_order_id,
      coalesce(nullif(o.order_sn, ''), nullif(o.external_order_id, ''), nullif(o.order_id::text, ''), o.marketplace_order_id::text) as order_key,
      o.order_status,
      o.tracking_number,
      o.order_created_at,
      coalesce(o.gross_amount, o.total_amount, o.paid_amount, 0)::numeric as gross_amount,
      coalesce(o.paid_amount, 0)::numeric as paid_amount,
      lower(coalesce(o.payment_method, o.payment_status, '')) as payment_text,
      lower(coalesce(o.order_status, o.status, o.raw_order->>'status', '')) as status_text,
      lower(concat_ws(
        ' ',
        o.payment_method,
        o.payment_status,
        o.note,
        o.raw_order->>'buyer_message',
        o.raw_order->>'buyer_note',
        o.raw_order->>'message_to_seller',
        o.raw_order->>'seller_note',
        o.raw_order->>'seller_remark',
        o.raw_order->>'remark',
        o.raw_order->>'note'
      )) as order_note_text,
      -- fast simple check for potential sample candidate to avoid scanning order items/jsonb texts
      (
        coalesce(o.gross_amount, o.total_amount, o.paid_amount, 0) <= 0
        or lower(coalesce(o.payment_method, o.payment_status, '')) ~ '(sample|gratis|free)'
        or lower(concat_ws(
          ' ',
          o.note,
          o.raw_order->>'buyer_message',
          o.raw_order->>'buyer_note',
          o.raw_order->>'message_to_seller',
          o.raw_order->>'seller_note',
          o.raw_order->>'seller_remark',
          o.raw_order->>'remark',
          o.raw_order->>'note'
        )) ~ '(sample|gratis|tester|giveaway|freebie|free sample|sample gratis|test order|uji coba)'
      ) as is_sample_candidate
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
  ),
  finance_by_order as (
    select
      fr.tenant_id,
      fr.marketplace_account_id,
      fr.order_id as order_key,
      count(*)::integer as finance_rows,
      sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0)::numeric) as payout_amount,
      sum(abs(coalesce(fr.discount_amount, 0)::numeric)) as discount_amount,
      sum(abs(coalesce(fr.platform_fee, 0)::numeric)) as platform_fee,
      sum(abs(coalesce(fr.commission_fee, 0)::numeric)) as commission_fee,
      sum(abs(coalesce(fr.affiliate_fee, 0)::numeric)) as affiliate_fee,
      sum(abs(coalesce(fr.shipping_fee, 0)::numeric)) as shipping_fee,
      sum(abs(coalesce(fr.fee_amount, 0)::numeric)) as fee_amount,
      sum(abs(coalesce(fr.total_fees, 0)::numeric)) as total_fees,
      sum(abs(coalesce(fr.refund_amount, 0)::numeric)) as refund_amount,
      sum(coalesce(fr.adjustment_amount, 0)::numeric) as adjustment_amount,
      -- fast simple check for finance sample flag (no casting huge jsonb to text)
      bool_or(
        lower(concat_ws(
          ' ',
          fr.settlement_status,
          fr.note,
          fr.raw_finance->>'settlement_status',
          fr.raw_finance->>'note'
        )) ~ '(sample|gratis|tester|giveaway|freebie|free sample|sample_order|is_sample)'
      ) as finance_sample_flag
    from public.marketplace_finance_reports fr
    where (v_role = 'service_role' or fr.tenant_id = v_tenant_id)
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and fr.order_id in (select order_key from all_orders_base)
    group by fr.tenant_id, fr.marketplace_account_id, fr.order_id
  ),
  item_evidence as (
    select
      oi.marketplace_order_id,
      bool_or(
        lower(concat_ws(
          ' ',
          oi.product_name,
          oi.variant_name,
          oi.marketplace_product_name,
          oi.marketplace_variant_name
        )) ~ '(sample|gratis|tester|giveaway|freebie|free sample|sample gratis|test order|uji coba)'
      ) as has_sample_label
    from public.marketplace_order_items oi
    join all_orders_base ob on ob.marketplace_order_id = oi.marketplace_order_id
    where ob.is_sample_candidate -- only run on candidate orders!
      and (v_role = 'service_role' or oi.tenant_id = v_tenant_id)
    group by oi.marketplace_order_id
  ),
  classified_stage as (
    select
      ob.*,
      coalesce(f.finance_rows, 0) as finance_rows,
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
      coalesce(f.adjustment_amount, 0) as adjustment_amount,
      coalesce(f.finance_sample_flag, false) as finance_sample_flag,
      coalesce(ie.has_sample_label, false) as has_sample_label,
      (
        ob.order_note_text ~ '(sample|gratis|tester|giveaway|freebie|free sample|sample gratis|test order|uji coba)'
        or ob.payment_text ~ '(sample|gratis|tester|giveaway|freebie|free sample|sample gratis|test order|uji coba)'
      ) as has_sample_text,
      ob.status_text ~ '(cancel|canceled|cancelled|batal|dibatalkan|returned|return|refund|rts|gagal|failed|closed)' as is_cancelled,
      ob.status_text ~ '(awaiting_shipment|ready_to_ship|awaiting_collection|in_transit|to_ship|to_pack|processed|unshipped|awaiting|ready|transit|belum|kemas|proses|ship|collect|pickup|dropoff)' as is_active_status,
      nullif(trim(coalesce(ob.tracking_number, '')), '') is not null
        and trim(coalesce(ob.tracking_number, '')) <> '-' as has_resi,
      ob.status_text ~ '(complete|completed|delivered|selesai|done|diterima)' as is_completed_status
    from all_orders_base ob
    left join finance_by_order f
      on f.tenant_id = ob.tenant_id
     and f.marketplace_account_id = ob.marketplace_account_id
     and f.order_key = ob.order_key
    left join item_evidence ie
      on ie.marketplace_order_id = ob.marketplace_order_id
  ),
  classified_evidence as (
    select
      *,
      case
        when is_cancelled then null::text
        when has_sample_text then 'sample_text_marker'
        when has_sample_label then 'sample_label'
        when finance_sample_flag then 'finance_sample_flag'
        when is_completed_status and gross_amount <= 0 and discount_amount > 0 then 'discount_100_delivered'
        else null::text
      end as sample_evidence_source
    from classified_stage
  ),
  all_classified as (
    select
      *,
      case
        when is_cancelled then 'cancelled'
        when sample_evidence_source is not null then 'confirmed_sample'
        when payout_amount < 0 then 'payout_minus'
        when payout_amount = 0 and (is_active_status or not has_resi) then 'pending_active'
        when payout_amount = 0
          and finance_rows = 0
          and is_completed_status
          and has_resi
          and order_created_at < (now() - interval '7 days') then 'no_payout_eligible'
        else 'other'
      end as category
    from classified_evidence
  ),
  sample_orders_enriched as (
    select
      *,
      case
        when payout_amount >= 0 then null::text
        when shipping_fee > discount_amount
          and shipping_fee > platform_fee + commission_fee + affiliate_fee then 'payout_minus_shipping'
        when discount_amount > shipping_fee
          and discount_amount > platform_fee + commission_fee + affiliate_fee then 'payout_minus_voucher'
        when platform_fee + commission_fee + affiliate_fee > shipping_fee
          and platform_fee + commission_fee + affiliate_fee > discount_amount then 'payout_minus_platform'
        else 'payout_minus_settlement'
      end as payout_minus_reason
    from all_classified
    where category = 'confirmed_sample'
  ),
  sample_counts as (
    select
      coalesce(count(*), 0)::integer as confirmed_sample_count,
      coalesce(count(*) filter (where sample_evidence_source = 'sample_text_marker'), 0)::integer as sample_text_marker_count,
      coalesce(count(*) filter (where sample_evidence_source = 'sample_label'), 0)::integer as sample_label_count,
      coalesce(count(*) filter (where sample_evidence_source = 'discount_100_delivered'), 0)::integer as sample_discount_100_count,
      coalesce(count(*) filter (where sample_evidence_source = 'finance_sample_flag'), 0)::integer as sample_finance_flag_count,
      coalesce(sum(gross_amount), 0)::numeric as sample_gross_total,
      coalesce(sum(payout_amount), 0)::numeric as sample_payout_total,
      coalesce(sum(payout_amount) filter (where payout_amount < 0), 0)::numeric as sample_payout_minus_total,
      coalesce(sum(abs(payout_amount)) filter (where payout_amount < 0), 0)::numeric as sample_payout_minus_total_abs,
      coalesce(sum(discount_amount), 0)::numeric as sample_discount_total,
      coalesce(sum(shipping_fee), 0)::numeric as sample_shipping_total,
      coalesce(sum(platform_fee + commission_fee + affiliate_fee + other_fee), 0)::numeric as sample_fee_total,
      coalesce(sum(refund_amount), 0)::numeric as sample_refund_total,
      coalesce(sum(adjustment_amount), 0)::numeric as sample_adjustment_total,
      coalesce(sum(abs(payout_amount)) filter (where payout_minus_reason = 'payout_minus_shipping'), 0)::numeric as sample_payout_minus_shipping_total,
      coalesce(sum(abs(payout_amount)) filter (where payout_minus_reason = 'payout_minus_voucher'), 0)::numeric as sample_payout_minus_voucher_total,
      coalesce(sum(abs(payout_amount)) filter (where payout_minus_reason = 'payout_minus_platform'), 0)::numeric as sample_payout_minus_platform_total,
      coalesce(sum(abs(payout_amount)) filter (where payout_minus_reason = 'payout_minus_settlement'), 0)::numeric as sample_payout_minus_settlement_total
    from sample_orders_enriched
  ),
  category_counts as (
    select
      coalesce(count(*) filter (where category = 'cancelled'), 0)::integer as cancelled_count,
      coalesce(count(*) filter (where category = 'pending_active'), 0)::integer as pending_count,
      coalesce(count(*) filter (where category = 'no_payout_eligible'), 0)::integer as no_payout_eligible_count,
      coalesce(count(*) filter (where category = 'payout_minus'), 0)::integer as payout_minus_count,
      coalesce(sum(abs(payout_amount)) filter (where category = 'payout_minus'), 0)::numeric as payout_minus_total_abs,
      coalesce(count(*) filter (where category = 'other'), 0)::integer as other_count
    from all_classified
  ),
  counts as (
    select
      s.confirmed_sample_count,
      s.sample_text_marker_count,
      s.sample_label_count,
      s.sample_discount_100_count,
      s.sample_finance_flag_count,
      s.sample_gross_total,
      s.sample_payout_total,
      s.sample_payout_minus_total,
      s.sample_payout_minus_total_abs,
      s.sample_payout_minus_shipping_total,
      s.sample_payout_minus_voucher_total,
      s.sample_payout_minus_platform_total,
      s.sample_payout_minus_settlement_total,
      s.sample_discount_total,
      s.sample_shipping_total,
      s.sample_fee_total,
      s.sample_refund_total,
      s.sample_adjustment_total,
      c.cancelled_count,
      c.pending_count,
      c.no_payout_eligible_count,
      c.payout_minus_count,
      c.payout_minus_total_abs,
      c.other_count
    from sample_counts s
    cross join category_counts c
  ),
  limited as (
    select *
    from sample_orders_enriched
    order by order_created_at desc
    offset ((p_page - 1) * p_page_size)
    limit (case when p_count_only then 0 else p_page_size end)
  )
  select
    jsonb_build_object(
      'sample_order_count', c.confirmed_sample_count,
      'confirmed_sample_count', c.confirmed_sample_count,
      'sample_free_count', c.confirmed_sample_count,
      'sample_text_marker_count', c.sample_text_marker_count,
      'sample_label_count', c.sample_label_count,
      'sample_discount_100_count', c.sample_discount_100_count,
      'sample_finance_flag_count', c.sample_finance_flag_count,
      'sample_gross_total', c.sample_gross_total,
      'sample_payout_total', c.sample_payout_total,
      'sample_payout_minus_total', c.sample_payout_minus_total,
      'sample_payout_minus_total_abs', c.sample_payout_minus_total_abs,
      'sample_payout_minus_shipping_total', c.sample_payout_minus_shipping_total,
      'sample_payout_minus_ongkir_total', c.sample_payout_minus_shipping_total,
      'sample_payout_minus_voucher_total', c.sample_payout_minus_voucher_total,
      'sample_payout_minus_platform_total', c.sample_payout_minus_platform_total,
      'sample_payout_minus_settlement_total', c.sample_payout_minus_settlement_total,
      'sample_discount_total', c.sample_discount_total,
      'sample_shipping_total', c.sample_shipping_total,
      'sample_fee_total', c.sample_fee_total,
      'sample_refund_total', c.sample_refund_total,
      'sample_adjustment_total', c.sample_adjustment_total,
      'cancelled_count', c.cancelled_count,
      'pending_count', c.pending_count,
      'no_payout_eligible_count', c.no_payout_eligible_count,
      'payout_minus_count', c.payout_minus_count,
      'payout_minus_total_abs', c.payout_minus_total_abs,
      'other_count', c.other_count,
      'source_breakdown', jsonb_build_object(
        'confirmed_sample_count', c.confirmed_sample_count,
        'sample_text_marker_count', c.sample_text_marker_count,
        'sample_label_count', c.sample_label_count,
        'sample_discount_100_count', c.sample_discount_100_count,
        'sample_finance_flag_count', c.sample_finance_flag_count,
        'cancelled_count', c.cancelled_count,
        'pending_count', c.pending_count,
        'no_payout_eligible_count', c.no_payout_eligible_count,
        'payout_minus_count', c.payout_minus_count,
        'other_count', c.other_count
      )
    ),
    coalesce(jsonb_agg(jsonb_build_object(
      'abnormal_status', 'SAMPLE_FREE',
      'finance_status', 'SAMPLE_FREE',
      'payout_status', 'SAMPLE_FREE',
      'category', 'sample_free',
      'classification_category', category,
      'sample_evidence_source', sample_evidence_source,
      'payout_minus_reason', payout_minus_reason,
      'message', 'Confirmed Sample/Gratis berdasarkan bukti eksplisit.',
      'marketplace', marketplace_group,
      'marketplace_account_id', marketplace_account_id,
      'marketplace_order_id', marketplace_order_id,
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
      'tracking_number', tracking_number,
      'is_sample_order', true
    ) order by order_created_at desc) filter (where marketplace_group is not null), '[]'::jsonb)
  into v_summary, v_rows
  from counts c
  left join limited on true
  group by c.confirmed_sample_count, c.sample_text_marker_count, c.sample_label_count,
           c.sample_discount_100_count, c.sample_finance_flag_count,
           c.sample_gross_total, c.sample_payout_total, c.sample_payout_minus_total,
           c.sample_payout_minus_total_abs, c.sample_payout_minus_shipping_total,
           c.sample_payout_minus_voucher_total, c.sample_payout_minus_platform_total,
           c.sample_payout_minus_settlement_total, c.sample_discount_total,
           c.sample_shipping_total, c.sample_fee_total, c.sample_refund_total,
           c.sample_adjustment_total, c.cancelled_count, c.pending_count,
           c.no_payout_eligible_count, c.payout_minus_count, c.payout_minus_total_abs,
           c.other_count;

  return jsonb_build_object(
    'ok', true,
    'source', 'finance_sample_order_counts',
    'version', 'strict_sample_no_payout_20260621',
    'timezone', 'Asia/Jakarta',
    'start_date', v_start,
    'end_date', v_end,
    'effective_marketplace', v_marketplace,
    'summary', coalesce(v_summary, '{}'::jsonb),
    'rows', coalesce(v_rows, '[]'::jsonb),
    'sample_orders', coalesce(v_rows, '[]'::jsonb)
  );
end;
$$;

grant execute on function public.finance_sample_order_counts(date, date, text, uuid, boolean, integer, integer) to authenticated, service_role;


-- 3. Redefine finance_marketplace_reconciliation_breakdown to use optimized sample count and HPP direct query
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
  v_start date := coalesce(p_start, date_trunc('month', timezone('Asia/Jakarta', now()))::date);
  v_end date := coalesce(p_end, timezone('Asia/Jakarta', now())::date);
  v_start_ts timestamptz := (coalesce(p_start, date_trunc('month', timezone('Asia/Jakarta', now()))::date)::timestamp at time zone 'Asia/Jakarta');
  v_end_ts timestamptz := ((coalesce(p_end, timezone('Asia/Jakarta', now())::date) + 1)::timestamp at time zone 'Asia/Jakarta');
  v_marketplace text;
  v_order_count int := 0;
  v_gross numeric := 0;
  v_payout numeric := 0;
  v_gap numeric := 0;
  v_sample_count int := 0;
  v_sample_hpp numeric := 0;
  v_sample_negative_payout_abs numeric := 0;
  v_sample_loss_estimate numeric := 0;
  v_breakdown jsonb := '[]'::jsonb;
  v_by_marketplace jsonb := '[]'::jsonb;
  v_sample_result jsonb := '{}'::jsonb;
  v_sample_summary jsonb := '{}'::jsonb;
begin
  begin
    v_tenant_id := nullif(current_setting('request.jwt.claims', true)::jsonb->>'tenant_id', '')::uuid;
  exception when others then
    v_tenant_id := null;
  end;

  v_marketplace := case
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
    else null
  end;

  -- Call count-only version of finance_sample_order_counts for supreme speed
  v_sample_result := public.finance_sample_order_counts(v_start, v_end, p_marketplace, p_account_id, true);
  v_sample_summary := coalesce(v_sample_result->'summary', '{}'::jsonb);

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
      coalesce(o.gross_amount, o.total_amount, 0)::numeric as gross_amount
    from public.marketplace_orders o
    where (v_tenant_id is null or o.tenant_id = v_tenant_id)
      and (v_marketplace is null or (
        case
          when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
          else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end
      ) = v_marketplace)
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and o.order_created_at >= v_start_ts
      and o.order_created_at < v_end_ts
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
      and (v_marketplace is null or (
        case
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
          else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end
      ) = v_marketplace)
      and fr.order_id in (select order_key from scoped_orders)
    group by fr.tenant_id, fr.marketplace_account_id, fr.order_id
  ),
  joined as (
    select
      o.*,
      coalesce(f.payout_amount, 0) as payout_amount
    from scoped_orders o
    left join finance_by_order f
      on f.tenant_id = o.tenant_id
     and f.marketplace_account_id = o.marketplace_account_id
     and f.order_key = o.order_key
  ),
  sample_orders as (
    select ob.marketplace_order_id, ob.tenant_id
    from (
      select
        o.marketplace_order_id,
        o.tenant_id,
        coalesce(o.gross_amount, o.total_amount, o.paid_amount, 0)::numeric as gross_amount,
        lower(coalesce(o.payment_method, o.payment_status, '')) as payment_text,
        lower(concat_ws(
          ' ',
          o.note,
          o.raw_order->>'buyer_message',
          o.raw_order->>'buyer_note',
          o.raw_order->>'message_to_seller',
          o.raw_order->>'seller_note',
          o.raw_order->>'seller_remark',
          o.raw_order->>'remark',
          o.raw_order->>'note'
        )) as order_note_text,
        lower(coalesce(o.order_status, o.status, o.raw_order->>'status', '')) as status_text
      from public.marketplace_orders o
      where o.order_created_at >= v_start_ts
        and o.order_created_at < v_end_ts
        and (v_tenant_id is null or o.tenant_id = v_tenant_id)
        and (p_account_id is null or o.marketplace_account_id = p_account_id)
        and (v_marketplace is null or (
          case
            when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
            when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
            else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
          end
        ) = v_marketplace)
    ) ob
    left join lateral (
      select
        bool_or(
          lower(concat_ws(
            ' ',
            oi.product_name,
            oi.variant_name,
            oi.marketplace_product_name,
            oi.marketplace_variant_name
          )) ~ '(sample|gratis|tester|giveaway|freebie|free sample|sample gratis|test order|uji coba)'
        ) as has_sample_label
      from public.marketplace_order_items oi
      where oi.marketplace_order_id = ob.marketplace_order_id
        and (v_tenant_id is null or oi.tenant_id = ob.tenant_id)
    ) ie on true
    left join lateral (
      select
        bool_or(
          lower(concat_ws(
            ' ',
            fr.settlement_status,
            fr.note,
            fr.raw_finance->>'settlement_status',
            fr.raw_finance->>'note'
          )) ~ '(sample|gratis|tester|giveaway|freebie|free sample|sample_order|is_sample)'
        ) as finance_sample_flag
      from public.marketplace_finance_reports fr
      where (v_tenant_id is null or fr.tenant_id = ob.tenant_id)
        and fr.order_id = coalesce(nullif(ob.marketplace_order_id::text, ''), ob.marketplace_order_id::text)
    ) f on true
    where (
      (
        ob.gross_amount <= 0
        or ob.payment_text ~ '(sample|gratis|free)'
        or ob.order_note_text ~ '(sample|gratis|tester|giveaway|freebie|free sample|sample gratis|test order|uji coba)'
        or ie.has_sample_label
        or f.finance_sample_flag
      )
      and ob.status_text !~ '(cancel|batal|dibatalkan|unpaid)'
    )
  ),
  sample_hpp as (
    select
      so.marketplace_order_id,
      sum(
        greatest(coalesce(nullif(i.qty, 0), nullif(i.quantity, 0), 1), 1)
        * coalesce(h.hpp, h.hpp_amount, 0)
      ) as sample_hpp
    from sample_orders so
    join public.marketplace_order_items i
      on i.marketplace_order_id = so.marketplace_order_id
    left join public.marketplace_variant_hpp_mappings h
      on h.marketplace_account_id = i.marketplace_account_id
     and h.marketplace_product_id = i.marketplace_product_id
     and h.marketplace_sku_id = i.marketplace_sku_id
    group by so.marketplace_order_id
  ),
  stats as (
    select
      count(*)::int as order_count,
      coalesce(sum(gross_amount), 0) as gross,
      coalesce(sum(payout_amount), 0) as payout
    from joined
  ),
  marketplace_group as (
    select
      j.marketplace,
      j.marketplace_account_id,
      coalesce(a.shop_name, a.store_alias, to_jsonb(a)->>'seller_name', j.marketplace) as shop_name,
      count(*)::int as order_count,
      coalesce(sum(j.gross_amount), 0) as gross_sales,
      coalesce(sum(j.payout_amount), 0) as payout_total,
      max(j.order_created_at) as last_updated_at
    from joined j
    left join public.marketplace_accounts a
      on a.marketplace_account_id = j.marketplace_account_id
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
      'sample_order_count', 0,
      'sample_hpp_total', 0,
      'sample_negative_payout_total', 0,
      'sample_loss_estimate', 0,
      'last_updated_at', last_updated_at
    ) order by marketplace, shop_name), '[]'::jsonb) as by_marketplace
    from marketplace_group
  )
  select
    s.order_count,
    s.gross,
    s.payout,
    coalesce((v_sample_summary->>'sample_order_count')::int, 0),
    coalesce((select sum(sample_hpp) from sample_hpp), 0),
    coalesce((v_sample_summary->>'sample_payout_minus_total_abs')::numeric, 0),
    bm.by_marketplace
  into
    v_order_count,
    v_gross,
    v_payout,
    v_sample_count,
    v_sample_hpp,
    v_sample_negative_payout_abs,
    v_by_marketplace
  from stats s
  cross join by_mkt bm;

  v_gap := greatest(v_gross - v_payout, 0);
  v_sample_loss_estimate := v_sample_hpp + v_sample_negative_payout_abs;

  v_breakdown := jsonb_build_array(
    jsonb_build_object(
      'label', 'Confirmed Sample/Gratis',
      'category', 'confirmed_sample_gratis',
      'description', 'Hanya order dengan bukti eksplisit sample/free/test, label sample, diskon 100% selesai, atau flag finance sample.',
      'amount', v_sample_loss_estimate,
      'hpp_total', v_sample_hpp,
      'payout_minus_total_abs', v_sample_negative_payout_abs,
      'order_count', v_sample_count,
      'source_breakdown', coalesce(v_sample_summary->'source_breakdown', '{}'::jsonb)
    ),
    jsonb_build_object(
      'label', 'Payout minus dari settlement',
      'category', 'payout_minus_settlement',
      'description', 'Nilai minus berasal dari settlement marketplace yang negatif.',
      'amount', coalesce((v_sample_summary->>'sample_payout_minus_settlement_total')::numeric, 0),
      'order_count', null
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
    'version', 'strict_reconciliation_20260621',
    'summary', jsonb_build_object(
      'order_count', v_order_count,
      'finance_order_count', v_order_count,
      'gross_sales', v_gross,
      'payout_total', v_payout,
      'gross_payout_gap', v_gap,
      'sample_order_count', v_sample_count,
      'confirmed_sample_count', v_sample_count,
      'sample_hpp_total', v_sample_hpp,
      'sample_negative_payout_total', v_sample_negative_payout_abs,
      'sample_payout_minus_total_abs', v_sample_negative_payout_abs,
      'sample_loss_estimate', v_sample_loss_estimate,
      'source_breakdown', coalesce(v_sample_summary->'source_breakdown', '{}'::jsonb),
      'no_payout_eligible_count', coalesce((v_sample_summary->>'no_payout_eligible_count')::int, 0),
      'payout_minus_count', coalesce((v_sample_summary->>'payout_minus_count')::int, 0)
    ) || coalesce(v_sample_summary, '{}'::jsonb),
    'by_marketplace', v_by_marketplace,
    'profit_loss_breakdown', v_breakdown,
    'sample_orders', '[]'::jsonb,
    'abnormals', '[]'::jsonb
  );
end;
$$;

grant execute on function public.finance_marketplace_reconciliation_breakdown(date, date, text, uuid) to authenticated, service_role;

commit;

notify pgrst, 'reload schema';
