-- P0 hotfix:
-- - finance_sku_order_line_details filters and pages order lines before
--   settlement/HPP expansion so settled/unpaid detail page 1 stays bounded.
-- - finance_dashboard_snapshot keeps existing totals, but enriches marketplace
--   rows with real audited settlement fields from marketplace_finance_reports.

create index if not exists idx_moi_sku_detail_marketplace_sku_20260621
  on public.marketplace_order_items (tenant_id, marketplace_account_id, marketplace_sku, marketplace_order_id)
  where marketplace_sku is not null;

create index if not exists idx_moi_sku_detail_local_sku_20260621
  on public.marketplace_order_items (tenant_id, marketplace_account_id, local_sku, marketplace_order_id)
  where local_sku is not null;

create index if not exists idx_moi_sku_detail_seller_sku_20260621
  on public.marketplace_order_items (tenant_id, marketplace_account_id, marketplace_seller_sku, seller_sku, marketplace_order_id);

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
          'marketplace_account_id', marketplace_account_id
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

revoke all on function public.finance_sku_order_line_details(date, date, text, uuid, text, text, text, text, integer, integer) from public;
grant execute on function public.finance_sku_order_line_details(date, date, text, uuid, text, text, text, text, integer, integer) to authenticated, service_role;

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
set statement_timeout = '8s'
as $$
declare
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_tenant_id uuid;
  v_role text := coalesce(nullif(v_claims->>'role', ''), nullif(current_setting('role', true), ''), current_user);
  v_current_start date := date_trunc('month', timezone('Asia/Jakarta', now()))::date;
  v_current_end date := timezone('Asia/Jakarta', now())::date;
  v_start date;
  v_end date;
  v_marketplace text;
  v_base jsonb;
  v_by_marketplace jsonb := '[]'::jsonb;
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

  v_base := public.dashboard_marketplace_order_analytics_90d(p_marketplace, 20);
  v_start := coalesce(nullif(v_base->>'start_date', '')::date, p_start, v_current_start);
  v_end := coalesce(nullif(v_base->>'end_date', '')::date, p_end, v_current_end);

  with base_rows as (
    select row_value as row
    from jsonb_array_elements(coalesce(v_base->'by_marketplace', '[]'::jsonb)) row_value
  ),
  finance_rows as (
    select
      case
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
        else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end as marketplace_group,
      coalesce(sum(fr.platform_fee), 0)::numeric as platform_fee,
      coalesce(sum(fr.commission_fee), 0)::numeric as commission_fee,
      coalesce(sum(fr.affiliate_fee), 0)::numeric as affiliate_fee,
      coalesce(sum(fr.shipping_fee), 0)::numeric as shipping_fee,
      coalesce(sum(fr.discount_amount), 0)::numeric as discount_amount,
      coalesce(sum(coalesce(fr.refund_amount, fr.total_refund, 0)), 0)::numeric as refund_amount,
      coalesce(sum(fr.adjustment_amount), 0)::numeric as adjustment_amount,
      coalesce(sum(coalesce(fr.fee_amount, fr.total_fees, 0)), 0)::numeric as fee_amount,
      coalesce(sum(fr.total_fees), 0)::numeric as total_fees,
      coalesce(sum(fr.total_refund), 0)::numeric as total_refund,
      count(*)::integer as finance_report_count
    from public.marketplace_finance_reports fr
    where fr.period_start >= v_start
      and fr.period_start <= v_end
      and (v_role = 'service_role' or fr.tenant_id = v_tenant_id)
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and (
        v_marketplace is null
        or (
          case
            when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
            when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
            else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
          end
        ) = v_marketplace
      )
    group by 1
  )
  select coalesce(jsonb_agg(
    br.row || jsonb_strip_nulls(jsonb_build_object(
      'platform_fee', fr.platform_fee,
      'commission_fee', fr.commission_fee,
      'affiliate_fee', fr.affiliate_fee,
      'shipping_fee', fr.shipping_fee,
      'discount_amount', fr.discount_amount,
      'refund_amount', fr.refund_amount,
      'adjustment_amount', fr.adjustment_amount,
      'fee_amount', fr.fee_amount,
      'total_fees', fr.total_fees,
      'total_refund', fr.total_refund,
      'finance_report_count', fr.finance_report_count,
      'breakdown_source', case when fr.finance_report_count > 0 then 'marketplace_finance_reports' else null end,
      'sample_free_source', null
    ))
    order by br.row->>'marketplace'
  ), coalesce(v_base->'by_marketplace', '[]'::jsonb))
  into v_by_marketplace
  from base_rows br
  left join finance_rows fr
    on fr.marketplace_group = case
      when lower(regexp_replace(coalesce(br.row->>'marketplace', ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
      when lower(regexp_replace(coalesce(br.row->>'marketplace', ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
      else lower(regexp_replace(coalesce(br.row->>'marketplace', 'unknown'), '[^a-z0-9]+', '', 'g'))
    end;

  return jsonb_build_object(
    'ok', true,
    'version', 'finance_dashboard_snapshot_fast_mtd_20260621_breakdown',
    'source', 'finance_dashboard_snapshot',
    'source_table', 'dashboard_marketplace_order_analytics_90d+marketplace_finance_reports',
    'timezone', 'Asia/Jakarta',
    'start_date', coalesce(v_base->>'start_date', v_current_start::text),
    'end_date', coalesce(v_base->>'end_date', v_current_end::text),
    'requested_start_date', coalesce(p_start, v_current_start),
    'requested_end_date', coalesce(p_end, v_current_end),
    'requested_account_id', p_account_id,
    'marketplace', coalesce(v_base->>'marketplace', 'all'),
    'summary', coalesce(v_base->'summary', '{}'::jsonb),
    'daily', coalesce(v_base->'daily', '[]'::jsonb),
    'trend', coalesce(v_base->'trend', v_base->'daily', '[]'::jsonb),
    'by_marketplace', v_by_marketplace,
    'marketplaces', v_by_marketplace,
    'profit_loss_by_marketplace', v_by_marketplace,
    'abnormal_aggregates', jsonb_build_object(
      'abnormal_count', coalesce(v_base->'summary'->'abnormal_count', '0'::jsonb),
      'negative_payout_total_abs', coalesce(v_base->'summary'->'negative_payout_total_abs', '0'::jsonb)
    ),
    'accounts', '[]'::jsonb,
    'expenses', '[]'::jsonb,
    'approved_purchases', '[]'::jsonb,
    'skus', '[]'::jsonb,
    'sku_rows', '[]'::jsonb,
    'cash_flow', '[]'::jsonb,
    'profit_loss_breakdown', '[]'::jsonb,
    'abnormals', '[]'::jsonb
  );
end;
$$;

revoke all on function public.finance_dashboard_snapshot(date, date, text, uuid) from public;
grant execute on function public.finance_dashboard_snapshot(date, date, text, uuid) to authenticated, service_role;

notify pgrst, 'reload schema';
