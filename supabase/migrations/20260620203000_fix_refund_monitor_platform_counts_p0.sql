create or replace function public.marketplace_refund_cancel_review(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null,
  p_search text default null,
  p_action text default null,
  p_page integer default 1,
  p_page_size integer default 20
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_tenant uuid;
  v_start date;
  v_end date;
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_page_size integer := least(greatest(coalesce(p_page_size, 20), 1), 50);
  v_offset integer;
  v_marketplace text;
  v_search text := nullif(lower(trim(coalesce(p_search, ''))), '');
  v_action text := nullif(upper(trim(coalesce(p_action, ''))), '');
  v_result jsonb;
begin
  select coalesce(
    case
      when (v_claims->>'tenant_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        then (v_claims->>'tenant_id')::uuid
      else null::uuid
    end,
    (select u.tenant_id from public.users u where u.user_id = auth.uid() limit 1)
  )
  into v_tenant;

  if v_tenant is null then
    return jsonb_build_object(
      'ok', false,
      'rows', '[]'::jsonb,
      'total', 0,
      'page', v_page,
      'page_size', v_page_size,
      'note', 'Tenant tidak ditemukan.'
    );
  end if;

  v_end := coalesce(p_end, (now() at time zone 'Asia/Jakarta')::date);
  v_start := coalesce(p_start, v_end - 90);
  if v_start > v_end then
    v_start := v_end;
  end if;
  if v_start < v_end - 90 then
    v_start := v_end - 90;
  end if;
  v_offset := (v_page - 1) * v_page_size;

  v_marketplace := case
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
    else null
  end;

  with orders_scope as materialized (
    select
      o.*,
      coalesce(o.order_created_at, o.created_time, o.paid_at, o.created_at) as order_ts,
      (coalesce(o.order_created_at, o.created_time, o.paid_at, o.created_at) at time zone 'Asia/Jakarta')::date as order_day,
      coalesce(nullif(o.external_order_id, ''), nullif(o.order_sn, ''), nullif(o.order_id, ''), o.marketplace_order_id::text) as order_key,
      exists (
        select 1
        from public.marketplace_order_items i
        where i.tenant_id = o.tenant_id
          and i.marketplace_order_id = o.marketplace_order_id
          and (
            i.stock_out_at is not null
            or upper(coalesce(i.stock_action_status, '')) in ('STOCK_OUT_SUBMITTED', 'MATCHED', 'DONE', 'COMPLETED')
          )
      ) as items_stocked_out
    from public.marketplace_orders o
    where o.tenant_id = v_tenant
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and (v_marketplace is null or o.marketplace = v_marketplace or (v_marketplace = 'tiktok_shop' and o.marketplace = 'tiktok'))
      and (coalesce(o.order_created_at, o.created_time, o.paid_at, o.created_at) at time zone 'Asia/Jakarta')::date between v_start and v_end
      and (
        upper(coalesce(o.order_status, o.status, '')) in ('CANCELLED', 'CANCELED', 'UNPAID', 'RETURNED', 'REFUND', 'REFUNDED', 'AWAITING_COLLECTION')
        or upper(coalesce(o.logistic_status, '')) = 'AWAITING_COLLECTION'
        or nullif(o.label_code, '') is not null
        or coalesce(o.has_cancel_request, false) = true
        or nullif(o.cancel_request_id, '') is not null
        or nullif(o.return_case_id, '') is not null
        or nullif(o.return_case_status, '') is not null
      )
  ),
  orders_base as materialized (
    select *
    from (
      select
        s.*,
        row_number() over (
          partition by s.tenant_id, s.marketplace_account_id, s.marketplace, s.order_key
          order by s.order_ts desc nulls last, s.updated_at desc nulls last, s.marketplace_order_id desc
        ) as rn
      from orders_scope s
      where coalesce(s.order_key, '') <> ''
    ) x
    where x.rn = 1
  ),
  search_filtered as materialized (
    select b.*
    from orders_base b
    where v_search is null
      or lower(concat_ws(' ',
          b.order_key,
          b.external_order_id,
          b.order_id,
          b.order_sn,
          b.package_id,
          b.remote_package_id,
          b.tracking_number,
          b.label_code,
          b.buyer_username,
          b.recipient_name,
          b.order_status,
          b.order_status_label,
          b.stock_action_status,
          b.return_case_id,
          b.return_case_status,
          b.cancel_request_id,
          b.cancel_request_status
        )) like '%' || v_search || '%'
      or exists (
        select 1
        from public.marketplace_order_items i
        left join public.products p
          on p.tenant_id = i.tenant_id
         and p.product_id = coalesce(i.product_id, i.local_product_id, i.mapped_product_id)
        where i.tenant_id = v_tenant
          and i.marketplace_order_id = b.marketplace_order_id
          and lower(concat_ws(' ',
            i.external_order_id,
            i.order_sn,
            i.tracking_number,
            i.package_id,
            i.marketplace_product_id,
            i.marketplace_sku_id,
            i.marketplace_sku,
            i.marketplace_seller_sku,
            i.seller_sku,
            i.local_sku,
            i.mapped_local_sku,
            i.marketplace_product_name,
            i.product_name,
            i.marketplace_variant_name,
            i.variant_name,
            p.kode_sku,
            p.kode_barcode,
            p.qr_code_value,
            p.nama_barang
          )) like '%' || v_search || '%'
      )
  ),
  classified as materialized (
    select
      sf.*,
      case
        when upper(coalesce(sf.order_status, sf.status, '')) in ('CANCELLED', 'CANCELED', 'UNPAID')
          and not (
            coalesce(sf.is_stock_out_completed, false)
            or sf.stock_transaction_id is not null
            or sf.stock_out_at is not null
            or sf.packed_at is not null
            or coalesce(sf.items_stocked_out, false)
          )
          and (
            nullif(sf.tracking_number, '') is null
            or sf.tracking_number in (sf.order_key, sf.order_id, sf.external_order_id, sf.order_sn, sf.label_code, sf.package_id)
          )
          then 'AUTO_DONE_NO_STOCK_IN'
        when upper(coalesce(sf.order_status, sf.status, '')) in ('CANCELLED', 'CANCELED', 'UNPAID')
          or coalesce(sf.has_cancel_request, false)
          or sf.cancel_request_id is not null
          or nullif(sf.cancel_request_status, '') is not null
          then 'REVIEW_CANCEL_WITH_REAL_RESI'
        when upper(concat_ws(' ', sf.order_status, sf.return_case_status, sf.return_review_status, sf.status)) like '%RETURN%'
          or upper(concat_ws(' ', sf.order_status, sf.return_case_status, sf.return_review_status, sf.status)) like '%REFUND%'
          or sf.return_case_id is not null
          then 'REVIEW_REFUND_RETURN'
        else 'REVIEW_AWAITING_COLLECTION'
      end as recommended_action,
      case
        when upper(coalesce(sf.order_status, sf.status, '')) in ('CANCELLED', 'CANCELED', 'UNPAID')
          and not (
            coalesce(sf.is_stock_out_completed, false)
            or sf.stock_transaction_id is not null
            or sf.stock_out_at is not null
            or sf.packed_at is not null
            or coalesce(sf.items_stocked_out, false)
          )
          then 'Pesanan batal tanpa bukti stok keluar. Tidak perlu stock-in.'
        when upper(coalesce(sf.order_status, sf.status, '')) in ('CANCELLED', 'CANCELED', 'UNPAID')
          then 'Pesanan batal setelah ada resi atau stok keluar. Cek barang dan proses stok masuk bila barang kembali.'
        when upper(concat_ws(' ', sf.order_status, sf.return_case_status, sf.return_review_status, sf.status)) like '%RETURN%'
          or upper(concat_ws(' ', sf.order_status, sf.return_case_status, sf.return_review_status, sf.status)) like '%REFUND%'
          then 'Pesanan refund/return. Cek item fisik sebelum stock-in.'
        else 'Pesanan menunggu pengiriman. Pantau status sebelum keputusan stok.'
      end as review_note
    from search_filtered sf
  ),
  action_filtered as materialized (
    select *
    from classified
    where v_action is null or recommended_action = v_action
  ),
  counted as materialized (
    select action_filtered.*, count(*) over ()::integer as total_count
    from action_filtered
  ),
  paged as materialized (
    select *
    from counted
    order by order_ts desc nulls last, updated_at desc nulls last, marketplace_order_id
    offset v_offset
    limit v_page_size
  )
  select jsonb_build_object(
    'ok', true,
    'note', 'Detail refund dan cancel sudah memuat item pesanan untuk pengecekan stok.',
    'version', 'data terbaru',
    'page', v_page,
    'page_size', v_page_size,
    'total', coalesce(max(p.total_count), 0),
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'marketplace_order_id', p.marketplace_order_id,
      'tenant_id', p.tenant_id,
      'marketplace_account_id', p.marketplace_account_id,
      'marketplace', p.marketplace,
      'shop_name', coalesce(ma.store_alias, ma.shop_name, '-'),
      'external_order_id', p.order_key,
      'order_id', p.order_id,
      'order_sn', coalesce(nullif(p.order_sn, ''), p.order_key),
      'order_status', coalesce(nullif(p.order_status, ''), nullif(p.status, ''), '-'),
      'order_status_label', coalesce(nullif(p.order_status_label, ''), nullif(p.order_status, ''), nullif(p.status, ''), '-'),
      'order_date', p.order_day,
      'order_created_at', p.order_ts,
      'order_updated_at', coalesce(p.order_updated_at, p.updated_time, p.updated_at, p.pulled_at),
      'tracking_number', coalesce(nullif(p.tracking_number, ''), nullif(p.label_code, ''), '-'),
      'real_tracking_number', nullif(p.tracking_number, ''),
      'label_code', coalesce(nullif(p.label_code, ''), nullif(p.tracking_number, ''), '-'),
      'package_id', p.package_id,
      'buyer_username', p.buyer_username,
      'recipient_name', p.recipient_name,
      'buyer_name_masked', p.buyer_name_masked,
      'shipping_provider_name', p.shipping_provider_name,
      'logistic_status', p.logistic_status,
      'stock_action_status', p.stock_action_status,
      'return_review_status', p.return_review_status,
      'cancel_review_status', p.cancel_review_status,
      'return_case_id', p.return_case_id,
      'return_case_status', p.return_case_status,
      'return_case_pulled_at', p.return_case_pulled_at,
      'cancel_request_id', p.cancel_request_id,
      'cancel_request_status', p.cancel_request_status,
      'cancel_request_reason', p.cancel_request_reason,
      'cancel_request_note', p.cancel_request_note,
      'cancel_requested_at', p.cancel_requested_at,
      'stock_in_restored_at', p.stock_in_restored_at,
      'stock_was_processed', coalesce(p.is_stock_out_completed, false)
        or p.stock_transaction_id is not null
        or p.stock_out_at is not null
        or p.packed_at is not null
        or coalesce(p.items_stocked_out, false),
      'recommended_action', p.recommended_action,
      'note', p.review_note,
      'item_count', coalesce(ia.item_count, 0),
      'qty_total', coalesce(ia.qty_total, 0),
      'hpp_total', coalesce(ia.hpp_total, 0),
      'item_names', coalesce(ia.item_names, '-'),
      'local_skus', coalesce(ia.local_skus, '-'),
      'marketplace_skus', coalesce(ia.marketplace_skus, '-'),
      'item_details', coalesce(ia.item_details, '[]'::jsonb)
    ) order by p.order_ts desc nulls last, p.updated_at desc nulls last, p.marketplace_order_id), '[]'::jsonb)
  )
  into v_result
  from paged p
  left join public.marketplace_accounts ma
    on ma.tenant_id = p.tenant_id
   and ma.marketplace_account_id = p.marketplace_account_id
  left join lateral (
    with item_rows as (
      select
        i.*,
        coalesce(nullif(i.quantity, 0), nullif(i.qty, 0), 1) as qty_final,
        coalesce(nullif(i.product_name, ''), nullif(i.marketplace_product_name, ''), nullif(i.local_product_name, ''), '-') as item_product_name,
        coalesce(nullif(i.variant_name, ''), nullif(i.marketplace_variant_name, ''), nullif(i.variation_name, ''), '-') as item_variant_name,
        coalesce(nullif(i.mapped_local_sku, ''), nullif(i.local_sku, ''), nullif(i.seller_sku, ''), '-') as item_local_sku,
        coalesce(nullif(i.marketplace_sku_id, ''), nullif(i.remote_sku_id, ''), nullif(i.marketplace_sku, ''), nullif(i.marketplace_seller_sku, ''), nullif(i.seller_sku, ''), '-') as item_marketplace_sku,
        coalesce(h.hpp, h.hpp_amount, h.hpp_per_item, 0) as hpp_per_item
      from public.marketplace_order_items i
      left join lateral (
        select hm.*
        from public.marketplace_variant_hpp_mappings hm
        where hm.tenant_id = v_tenant
          and hm.marketplace_account_id = i.marketplace_account_id
          and coalesce(hm.is_active, true) = true
          and (
            (nullif(hm.marketplace_sku_id, '') is not null and hm.marketplace_sku_id = coalesce(nullif(i.marketplace_sku_id, ''), nullif(i.remote_sku_id, ''), nullif(i.marketplace_sku, '')))
            or (nullif(hm.marketplace_seller_sku, '') is not null and lower(hm.marketplace_seller_sku) = lower(coalesce(nullif(i.marketplace_seller_sku, ''), nullif(i.seller_sku, ''))))
            or (nullif(hm.local_sku, '') is not null and lower(hm.local_sku) = lower(coalesce(nullif(i.mapped_local_sku, ''), nullif(i.local_sku, ''))))
          )
        order by hm.updated_at desc nulls last, hm.created_at desc nulls last
        limit 1
      ) h on true
      where i.tenant_id = v_tenant
        and i.marketplace_order_id = p.marketplace_order_id
    )
    select
      count(*)::integer as item_count,
      sum(coalesce(qty_final, 0))::numeric as qty_total,
      sum(coalesce(hpp_per_item, 0) * coalesce(qty_final, 0))::numeric as hpp_total,
      string_agg(distinct item_product_name, ', ' order by item_product_name) as item_names,
      string_agg(distinct nullif(item_local_sku, '-'), ', ' order by nullif(item_local_sku, '-')) as local_skus,
      string_agg(distinct nullif(item_marketplace_sku, '-'), ', ' order by nullif(item_marketplace_sku, '-')) as marketplace_skus,
      jsonb_agg(jsonb_build_object(
        'item_id', marketplace_order_item_id,
        'marketplace_order_item_id', marketplace_order_item_id,
        'product_name', item_product_name,
        'variant_name', item_variant_name,
        'local_sku', item_local_sku,
        'marketplace_sku', item_marketplace_sku,
        'marketplace_seller_sku', coalesce(nullif(marketplace_seller_sku, ''), nullif(seller_sku, ''), '-'),
        'qty', qty_final,
        'gross', greatest(coalesce(gross_amount, 0), coalesce(unit_gross_amount, 0) * qty_final),
        'hpp', coalesce(hpp_per_item, 0) * qty_final,
        'hpp_per_item', coalesce(hpp_per_item, 0),
        'tracking_number', coalesce(nullif(tracking_number, ''), nullif(p.tracking_number, ''), '-'),
        'stock_action_status', coalesce(nullif(stock_action_status, ''), 'unmapped'),
        'return_case_id', return_case_id,
        'return_case_status', return_case_status,
        'return_review_status', return_review_status
      ) order by item_product_name, item_variant_name) as item_details
    from item_rows
  ) ia on true;

  return coalesce(v_result, jsonb_build_object(
    'ok', true,
    'rows', '[]'::jsonb,
    'total', 0,
    'page', v_page,
    'page_size', v_page_size,
    'version', 'data terbaru'
  ));
end;
$$;

grant execute on function public.marketplace_refund_cancel_review(date, date, text, uuid, text, text, integer, integer) to anon, authenticated, service_role;

create or replace function public.platform_tenant_readiness_summary()
returns table (
  tenant_id uuid,
  tenant_name text,
  tenant_status text,
  marketplace text,
  marketplace_account_id uuid,
  store_alias text,
  account_status text,
  product_snapshot_count bigint,
  variant_snapshot_count bigint,
  order_count bigint,
  finance_count bigint,
  sku_mapped_count bigint,
  hpp_mapped_count bigint,
  unmapped_order_item_count bigint,
  readiness_status text
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1
    from public.users u
    where u.user_id = auth.uid()
      and u.status = 'active'
      and u.role_id = 'platform_owner'
  ) then
    raise exception 'Forbidden';
  end if;

  return query
  with tenant_accounts as (
    select
      t.tenant_id,
      t.tenant_name,
      t.status as tenant_status,
      ma.marketplace,
      ma.marketplace_account_id,
      coalesce(ma.store_alias, ma.shop_name, '-') as store_alias,
      ma.status as account_status,
      ma.access_token_expired_at
    from public.app_tenants t
    left join public.marketplace_accounts ma
      on ma.tenant_id = t.tenant_id
     and coalesce(ma.is_deleted, false) = false
  )
  select
    ta.tenant_id,
    ta.tenant_name::text,
    ta.tenant_status::text,
    ta.marketplace::text,
    ta.marketplace_account_id,
    ta.store_alias::text,
    ta.account_status::text,
    coalesce((
      select count(*)
      from public.marketplace_product_snapshots p
      where p.tenant_id = ta.tenant_id
        and p.marketplace_account_id = ta.marketplace_account_id
    ), 0)::bigint as product_snapshot_count,
    coalesce((
      select count(*)
      from public.marketplace_variant_snapshots v
      where v.tenant_id = ta.tenant_id
        and v.marketplace_account_id = ta.marketplace_account_id
    ), 0)::bigint as variant_snapshot_count,
    coalesce((
      select count(*)
      from public.marketplace_orders o
      where o.tenant_id = ta.tenant_id
        and o.marketplace_account_id = ta.marketplace_account_id
    ), 0)::bigint as order_count,
    coalesce((
      select count(*)
      from public.marketplace_finance_reports f
      where f.tenant_id = ta.tenant_id
        and f.marketplace_account_id = ta.marketplace_account_id
    ), 0)::bigint as finance_count,
    coalesce((
      select count(*)
      from public.marketplace_variant_snapshots v
      where v.tenant_id = ta.tenant_id
        and v.marketplace_account_id = ta.marketplace_account_id
        and exists (
          select 1
          from public.marketplace_sku_maps m
          where m.tenant_id = v.tenant_id
            and m.marketplace_account_id = v.marketplace_account_id
            and coalesce(m.status, 'active') = 'active'
            and (
              m.marketplace_variant_snapshot_id = v.marketplace_variant_snapshot_id
              or (
                coalesce(nullif(m.marketplace_product_id, ''), nullif(m.remote_product_id, '')) = coalesce(nullif(v.marketplace_product_id, ''), '')
                and coalesce(nullif(m.marketplace_sku_id, ''), nullif(m.remote_sku_id, ''), nullif(m.marketplace_sku, '')) = coalesce(nullif(v.marketplace_sku_id, ''), '')
              )
              or (
                nullif(v.marketplace_seller_sku, '') is not null
                and lower(coalesce(nullif(m.marketplace_seller_sku, ''), nullif(m.remote_seller_sku, ''))) = lower(v.marketplace_seller_sku)
              )
            )
        )
    ), 0)::bigint as sku_mapped_count,
    coalesce((
      select count(*)
      from public.marketplace_variant_snapshots v
      where v.tenant_id = ta.tenant_id
        and v.marketplace_account_id = ta.marketplace_account_id
        and exists (
          select 1
          from public.marketplace_variant_hpp_mappings h
          where h.tenant_id = v.tenant_id
            and h.marketplace_account_id = v.marketplace_account_id
            and coalesce(h.is_active, true) = true
            and (
              (
                nullif(h.marketplace_product_id, '') is not null
                and nullif(h.marketplace_sku_id, '') is not null
                and h.marketplace_product_id = v.marketplace_product_id
                and h.marketplace_sku_id = v.marketplace_sku_id
              )
              or (
                nullif(h.marketplace_sku_id, '') is not null
                and h.marketplace_sku_id = v.marketplace_sku_id
              )
              or (
                nullif(v.marketplace_seller_sku, '') is not null
                and lower(coalesce(nullif(h.marketplace_seller_sku, ''), '')) = lower(v.marketplace_seller_sku)
              )
            )
        )
    ), 0)::bigint as hpp_mapped_count,
    coalesce((
      select count(*)
      from public.marketplace_order_items oi
      where oi.tenant_id = ta.tenant_id
        and oi.marketplace_account_id = ta.marketplace_account_id
        and not exists (
          select 1
          from public.marketplace_sku_maps m
          where m.tenant_id = oi.tenant_id
            and m.marketplace_account_id = oi.marketplace_account_id
            and coalesce(m.status, 'active') = 'active'
            and (
              (
                coalesce(nullif(m.marketplace_product_id, ''), nullif(m.remote_product_id, '')) = coalesce(nullif(oi.marketplace_product_id, ''), '')
                and coalesce(nullif(m.marketplace_sku_id, ''), nullif(m.remote_sku_id, ''), nullif(m.marketplace_sku, '')) = coalesce(nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, ''), '')
              )
              or (
                nullif(coalesce(oi.marketplace_seller_sku, oi.seller_sku), '') is not null
                and lower(coalesce(nullif(m.marketplace_seller_sku, ''), nullif(m.remote_seller_sku, ''))) = lower(coalesce(oi.marketplace_seller_sku, oi.seller_sku))
              )
            )
        )
    ), 0)::bigint as unmapped_order_item_count,
    (
      case
        when ta.marketplace_account_id is null then 'no_account'
        when ta.account_status is distinct from 'active' then 'account_inactive'
        when ta.access_token_expired_at is not null and ta.access_token_expired_at <= now() then 'token_expired'
        when coalesce((
          select count(*)
          from public.marketplace_variant_snapshots v
          where v.tenant_id = ta.tenant_id
            and v.marketplace_account_id = ta.marketplace_account_id
        ), 0) = 0 then 'no_variants'
        when coalesce((
          select count(*)
          from public.marketplace_variant_snapshots v
          where v.tenant_id = ta.tenant_id
            and v.marketplace_account_id = ta.marketplace_account_id
            and not exists (
              select 1
              from public.marketplace_sku_maps m
              where m.tenant_id = v.tenant_id
                and m.marketplace_account_id = v.marketplace_account_id
                and coalesce(m.status, 'active') = 'active'
                and (
                  m.marketplace_variant_snapshot_id = v.marketplace_variant_snapshot_id
                  or (
                    coalesce(nullif(m.marketplace_product_id, ''), nullif(m.remote_product_id, '')) = coalesce(nullif(v.marketplace_product_id, ''), '')
                    and coalesce(nullif(m.marketplace_sku_id, ''), nullif(m.remote_sku_id, ''), nullif(m.marketplace_sku, '')) = coalesce(nullif(v.marketplace_sku_id, ''), '')
                  )
                  or (
                    nullif(v.marketplace_seller_sku, '') is not null
                    and lower(coalesce(nullif(m.marketplace_seller_sku, ''), nullif(m.remote_seller_sku, ''))) = lower(v.marketplace_seller_sku)
                  )
                )
            )
        ), 0) > 0 then 'unmapped_skus'
        else 'ready'
      end
    )::text as readiness_status
  from tenant_accounts ta
  order by ta.tenant_name, ta.marketplace;
end;
$$;

grant execute on function public.platform_tenant_readiness_summary() to authenticated;
grant execute on function public.platform_tenant_readiness_summary() to service_role;
