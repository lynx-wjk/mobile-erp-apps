-- Recovery patch after historical marketplace import.
-- Adds lightweight order list RPC, SKU mapping Excel import/export RPC,
-- HPP sync from SKU mapping, and finance refresh trigger.

create index if not exists idx_marketplace_orders_tenant_date_fast
  on public.marketplace_orders(tenant_id, order_created_at desc);
create index if not exists idx_marketplace_orders_account_date_fast
  on public.marketplace_orders(marketplace_account_id, order_created_at desc);
create index if not exists idx_marketplace_order_items_order_fast
  on public.marketplace_order_items(marketplace_order_id);
create index if not exists idx_marketplace_variant_snapshots_account_fast
  on public.marketplace_variant_snapshots(marketplace_account_id, updated_at desc);
create index if not exists idx_marketplace_sku_maps_account_variant_fast
  on public.marketplace_sku_maps(marketplace_account_id, marketplace_product_id, marketplace_sku_id);

create or replace function public.marketplace_orders_fast_list(
  p_tenant_id uuid,
  p_marketplace text default null,
  p_marketplace_account_id uuid default null,
  p_status text default 'all',
  p_search text default null,
  p_start date default null,
  p_end date default null,
  p_limit integer default 120,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 120), 1), 250);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_start timestamptz := case when p_start is null then null else (p_start::timestamp at time zone 'Asia/Jakarta') end;
  v_end timestamptz := case when p_end is null then null else ((p_end + 1)::timestamp at time zone 'Asia/Jakarta') end;
  v_rows jsonb;
begin
  with filtered_orders as (
    select o.*,
           a.store_alias as account_store_alias,
           a.shop_name as account_shop_name
    from public.marketplace_orders o
    left join public.marketplace_accounts a
      on a.marketplace_account_id = o.marketplace_account_id
    where o.tenant_id = p_tenant_id
      and (p_marketplace is null or p_marketplace = '' or p_marketplace = 'all' or o.marketplace = p_marketplace)
      and (p_marketplace_account_id is null or o.marketplace_account_id = p_marketplace_account_id)
      and (p_status is null or p_status = '' or p_status = 'all' or coalesce(o.stock_action_status, 'pending') = p_status)
      and (v_start is null or o.order_created_at >= v_start)
      and (v_end is null or o.order_created_at < v_end)
      and (
        p_search is null or btrim(p_search) = '' or
        coalesce(o.external_order_id, '') ilike '%' || p_search || '%' or
        coalesce(o.order_sn, '') ilike '%' || p_search || '%' or
        coalesce(o.order_id::text, '') ilike '%' || p_search || '%' or
        coalesce(o.remote_order_id, '') ilike '%' || p_search || '%' or
        coalesce(o.package_id, '') ilike '%' || p_search || '%' or
        coalesce(o.tracking_number, '') ilike '%' || p_search || '%' or
        coalesce(o.buyer_username, '') ilike '%' || p_search || '%' or
        coalesce(o.recipient_name, '') ilike '%' || p_search || '%'
      )
    order by o.order_created_at desc nulls last, o.pulled_at desc nulls last, o.updated_at desc nulls last
    limit v_limit offset v_offset
  ),
  item_counts as (
    select
      i.marketplace_order_id,
      count(*)::int as item_count,
      coalesce(sum(coalesce(i.quantity, i.qty, 1)), 0) as qty_total,
      count(*) filter (where coalesce(i.local_sku, '') <> '' or coalesce(i.product_id::text, '') <> '')::int as mapped_item_count,
      count(*) filter (where coalesce(i.local_sku, '') = '' and coalesce(i.product_id::text, '') = '')::int as unmapped_item_count,
      count(*) filter (where coalesce(i.stock_action_status, '') = 'stock_out_done')::int as stock_out_done_count,
      count(*) filter (where coalesce(i.stock_action_status, '') = 'stock_out_failed')::int as stock_out_failed_count,
      count(*) filter (where coalesce(i.stock_action_status, '') = 'reserved')::int as reserved_item_count,
      count(*) filter (where coalesce(i.scan_status, '') = 'partial_scanned')::int as partial_scanned_item_count,
      count(*) filter (where coalesce(i.scan_status, '') = 'scanned_done')::int as scanned_done_item_count
    from public.marketplace_order_items i
    join filtered_orders fo on fo.marketplace_order_id = i.marketplace_order_id
    group by i.marketplace_order_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'marketplace_order_id', fo.marketplace_order_id,
    'tenant_id', fo.tenant_id,
    'marketplace_account_id', fo.marketplace_account_id,
    'marketplace', fo.marketplace,
    'account_store_alias', coalesce(fo.account_store_alias, fo.account_shop_name, fo.marketplace),
    'account_shop_name', coalesce(fo.account_shop_name, fo.account_store_alias, fo.marketplace),
    'external_order_id', coalesce(fo.external_order_id, fo.order_sn, fo.remote_order_id, fo.order_id::text),
    'order_sn', fo.order_sn,
    'remote_order_id', fo.remote_order_id,
    'order_id', fo.order_id,
    'order_status', coalesce(fo.order_status, fo.status),
    'order_status_label', coalesce(fo.order_status, fo.status),
    'stock_action_status', coalesce(fo.stock_action_status, 'pending'),
    'stock_action_label', coalesce(fo.stock_action_status, 'Pending'),
    'buyer_username', coalesce(fo.buyer_username, '-'),
    'recipient_name', coalesce(fo.recipient_name, '-'),
    'payment_method', coalesce(fo.payment_method, '-'),
    'currency', coalesce(fo.currency, ''),
    'total_amount', coalesce(fo.total_amount, fo.gross_amount, 0),
    'order_created_at', fo.order_created_at,
    'order_updated_at', fo.order_updated_at,
    'pulled_at', fo.pulled_at,
    'last_error', fo.last_error,
    'item_count', coalesce(ic.item_count, 0),
    'qty_total', coalesce(ic.qty_total, 0),
    'mapped_item_count', coalesce(ic.mapped_item_count, 0),
    'unmapped_item_count', coalesce(ic.unmapped_item_count, 0),
    'stock_out_done_count', coalesce(ic.stock_out_done_count, 0),
    'stock_out_failed_count', coalesce(ic.stock_out_failed_count, 0),
    'reserved_item_count', coalesce(ic.reserved_item_count, 0),
    'partial_scanned_item_count', coalesce(ic.partial_scanned_item_count, 0),
    'scanned_done_item_count', coalesce(ic.scanned_done_item_count, 0),
    'order_status_group', coalesce(fo.order_status_group, 'normal'),
    'tracking_number', coalesce(fo.tracking_number, ''),
    'shipping_provider_name', coalesce(fo.shipping_provider_name, ''),
    'package_id', coalesce(fo.package_id, ''),
    'logistic_status', coalesce(fo.logistic_status, ''),
    'label_code', coalesce(fo.label_code, ''),
    'has_cancel_request', coalesce(fo.has_cancel_request, false),
    'cancel_request_id', coalesce(fo.cancel_request_id, ''),
    'cancel_request_status', coalesce(fo.cancel_request_status, ''),
    'cancel_request_reason', coalesce(fo.cancel_request_reason, ''),
    'cancel_request_note', coalesce(fo.cancel_request_note, ''),
    'cancel_requested_at', fo.cancel_requested_at,
    'cancel_request_pulled_at', fo.cancel_request_pulled_at
  ) order by fo.order_created_at desc nulls last), '[]'::jsonb)
  into v_rows
  from filtered_orders fo
  left join item_counts ic on ic.marketplace_order_id = fo.marketplace_order_id;

  return jsonb_build_object('ok', true, 'rows', coalesce(v_rows, '[]'::jsonb));
end;
$$;

grant execute on function public.marketplace_orders_fast_list(uuid,text,uuid,text,text,date,date,integer,integer) to authenticated, service_role;

create or replace function public.marketplace_sku_mapping_export_snapshot(
  p_tenant_id uuid,
  p_marketplace_account_id uuid default null
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
with variant_rows as (
  select
    v.marketplace_variant_snapshot_id,
    v.tenant_id,
    v.marketplace_account_id,
    v.marketplace,
    v.marketplace_product_id,
    v.marketplace_sku_id,
    v.marketplace_sku_code,
    v.marketplace_seller_sku,
    v.marketplace_product_name,
    v.marketplace_variant_name,
    v.product_status,
    v.sku_status,
    v.price_amount,
    v.stock_quantity,
    m.marketplace_sku_map_id,
    coalesce(m.local_product_id, m.product_id) as local_product_id,
    m.local_sku,
    m.local_product_name,
    coalesce(m.sync_enabled, m.is_stock_sync_enabled, false) as sync_enabled,
    p.hpp_amount,
    p.target_margin_percent
  from public.marketplace_variant_snapshots v
  left join public.marketplace_sku_maps m
    on m.tenant_id = v.tenant_id
   and m.marketplace_account_id = v.marketplace_account_id
   and coalesce(m.status, 'active') <> 'deleted'
   and (
     nullif(m.marketplace_variant_snapshot_id::text, '') = v.marketplace_variant_snapshot_id::text
     or (
       coalesce(m.marketplace_product_id, '') = coalesce(v.marketplace_product_id, '')
       and coalesce(m.marketplace_sku_id, '') = coalesce(v.marketplace_sku_id, '')
     )
     or (
       coalesce(m.marketplace_seller_sku, '') <> ''
       and coalesce(m.marketplace_seller_sku, '') = coalesce(v.marketplace_seller_sku, '')
     )
   )
  left join public.marketplace_variant_hpp_mappings p
    on p.tenant_id = v.tenant_id
   and p.marketplace_account_id = v.marketplace_account_id
   and coalesce(p.marketplace_product_id, '') = coalesce(v.marketplace_product_id, '')
   and coalesce(p.marketplace_sku_id, '') = coalesce(v.marketplace_sku_id, '')
  where v.tenant_id = p_tenant_id
    and (p_marketplace_account_id is null or v.marketplace_account_id = p_marketplace_account_id)
),
local_products as (
  select
    product_id,
    kode_sku,
    kode_barcode,
    nama_barang,
    kategori,
    harga_hpp_default,
    stock_saat_ini,
    status
  from public.products
  where tenant_id = p_tenant_id
    and coalesce(status, 'active') = 'active'
)
select jsonb_build_object(
  'ok', true,
  'variants', coalesce((select jsonb_agg(to_jsonb(v) order by v.marketplace, v.marketplace_product_name, v.marketplace_variant_name) from variant_rows v), '[]'::jsonb),
  'local_products', coalesce((select jsonb_agg(to_jsonb(p) order by p.nama_barang, p.kode_sku) from local_products p), '[]'::jsonb)
);
$$;

grant execute on function public.marketplace_sku_mapping_export_snapshot(uuid,uuid) to authenticated, service_role;

create or replace function public.marketplace_sku_mapping_import_bulk(
  p_rows jsonb,
  p_sync_enabled boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r jsonb;
  v_tenant_id uuid;
  v_account_id uuid;
  v_marketplace text;
  v_snapshot_id uuid;
  v_product_id uuid;
  v_local_sku text;
  v_local_name text;
  v_marketplace_product_id text;
  v_marketplace_sku_id text;
  v_marketplace_sku text;
  v_marketplace_seller_sku text;
  v_product_name text;
  v_variant_name text;
  v_existing_id uuid;
  v_upserted int := 0;
  v_skipped_invalid int := 0;
  v_errors jsonb := '[]'::jsonb;
begin
  if jsonb_typeof(coalesce(p_rows, '[]'::jsonb)) <> 'array' then
    return jsonb_build_object('ok', false, 'message', 'p_rows harus array jsonb', 'upserted', 0);
  end if;

  for r in select value from jsonb_array_elements(p_rows) loop
    begin
      v_tenant_id := nullif(r->>'tenant_id', '')::uuid;
      v_account_id := nullif(r->>'marketplace_account_id', '')::uuid;
      v_marketplace := nullif(r->>'marketplace', '');
      v_snapshot_id := nullif(r->>'marketplace_variant_snapshot_id', '')::uuid;
      v_product_id := nullif(coalesce(r->>'local_product_id', r->>'product_id'), '')::uuid;
      v_local_sku := nullif(r->>'local_sku', '');
      v_marketplace_product_id := nullif(r->>'marketplace_product_id', '');
      v_marketplace_sku_id := nullif(r->>'marketplace_sku_id', '');
      v_marketplace_sku := nullif(coalesce(r->>'marketplace_sku', r->>'marketplace_sku_code'), '');
      v_marketplace_seller_sku := nullif(coalesce(r->>'marketplace_seller_sku', r->>'seller_sku'), '');
      v_product_name := nullif(coalesce(r->>'marketplace_product_name', r->>'product_name'), '');
      v_variant_name := nullif(coalesce(r->>'marketplace_variation_name', r->>'marketplace_variant_name', r->>'variant_name'), '');

      if v_tenant_id is null or v_account_id is null or (v_marketplace_sku_id is null and v_marketplace_seller_sku is null and v_snapshot_id is null) then
        v_skipped_invalid := v_skipped_invalid + 1;
        continue;
      end if;

      if v_product_id is null and v_local_sku is not null then
        select p.product_id, p.kode_sku, p.nama_barang
          into v_product_id, v_local_sku, v_local_name
        from public.products p
        where p.tenant_id = v_tenant_id
          and lower(p.kode_sku) = lower(v_local_sku)
          and coalesce(p.status, 'active') = 'active'
        limit 1;
      else
        select p.kode_sku, p.nama_barang
          into v_local_sku, v_local_name
        from public.products p
        where p.product_id = v_product_id
          and p.tenant_id = v_tenant_id
        limit 1;
      end if;

      if v_product_id is null or coalesce(v_local_sku, '') = '' then
        v_skipped_invalid := v_skipped_invalid + 1;
        continue;
      end if;

      if v_marketplace is null then
        select marketplace into v_marketplace
        from public.marketplace_accounts
        where marketplace_account_id = v_account_id
        limit 1;
      end if;

      v_existing_id := null;
      select m.marketplace_sku_map_id into v_existing_id
      from public.marketplace_sku_maps m
      where m.tenant_id = v_tenant_id
        and m.marketplace_account_id = v_account_id
        and coalesce(m.status, 'active') <> 'deleted'
        and (
          (v_snapshot_id is not null and m.marketplace_variant_snapshot_id = v_snapshot_id) or
          (coalesce(v_marketplace_product_id, '') <> '' and coalesce(v_marketplace_sku_id, '') <> '' and coalesce(m.marketplace_product_id, '') = v_marketplace_product_id and coalesce(m.marketplace_sku_id, '') = v_marketplace_sku_id) or
          (coalesce(v_marketplace_seller_sku, '') <> '' and coalesce(m.marketplace_seller_sku, '') = v_marketplace_seller_sku)
        )
      order by m.updated_at desc nulls last
      limit 1;

      if v_existing_id is null then
        insert into public.marketplace_sku_maps(
          tenant_id, marketplace_account_id, marketplace,
          product_id, local_product_id, local_sku, local_product_name,
          marketplace_product_id, marketplace_sku_id, marketplace_sku, marketplace_seller_sku,
          marketplace_product_name, marketplace_variation_name, marketplace_variant_snapshot_id,
          mapping_source, sync_enabled, status, last_error, created_at, updated_at
        ) values (
          v_tenant_id, v_account_id, v_marketplace,
          v_product_id, v_product_id, v_local_sku, v_local_name,
          v_marketplace_product_id, v_marketplace_sku_id, v_marketplace_sku, coalesce(v_marketplace_seller_sku, v_marketplace_sku_id, v_local_sku),
          v_product_name, v_variant_name, v_snapshot_id,
          'excel_import', coalesce(p_sync_enabled, true), 'active', null, now(), now()
        );
      else
        update public.marketplace_sku_maps
        set
          marketplace = coalesce(v_marketplace, marketplace),
          product_id = v_product_id,
          local_product_id = v_product_id,
          local_sku = v_local_sku,
          local_product_name = v_local_name,
          marketplace_product_id = coalesce(v_marketplace_product_id, marketplace_product_id),
          marketplace_sku_id = coalesce(v_marketplace_sku_id, marketplace_sku_id),
          marketplace_sku = coalesce(v_marketplace_sku, marketplace_sku),
          marketplace_seller_sku = coalesce(v_marketplace_seller_sku, marketplace_seller_sku, v_marketplace_sku_id, v_local_sku),
          marketplace_product_name = coalesce(v_product_name, marketplace_product_name),
          marketplace_variation_name = coalesce(v_variant_name, marketplace_variation_name),
          marketplace_variant_snapshot_id = coalesce(v_snapshot_id, marketplace_variant_snapshot_id),
          mapping_source = 'excel_import',
          sync_enabled = coalesce(p_sync_enabled, sync_enabled, true),
          status = 'active',
          last_error = null,
          updated_at = now()
        where marketplace_sku_map_id = v_existing_id;
      end if;

      v_upserted := v_upserted + 1;
    exception when others then
      v_skipped_invalid := v_skipped_invalid + 1;
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('row', r, 'error', sqlerrm));
    end;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'upserted', v_upserted,
    'skipped_invalid', v_skipped_invalid,
    'errors', v_errors
  );
end;
$$;

grant execute on function public.marketplace_sku_mapping_import_bulk(jsonb,boolean) to authenticated, service_role;

create or replace function public.marketplace_sync_hpp_from_sku_maps(
  p_tenant_id uuid,
  p_marketplace_account_id uuid default null,
  p_overwrite boolean default false,
  p_default_target_margin numeric default 30
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rows jsonb;
  v_result jsonb;
begin
  with source_rows as (
    select
      m.tenant_id,
      m.marketplace_account_id,
      m.marketplace,
      m.marketplace_product_id,
      m.marketplace_sku_id,
      m.marketplace_seller_sku,
      m.marketplace_product_name,
      m.marketplace_variation_name,
      coalesce(m.local_product_id, m.product_id) as local_product_id,
      p.kode_sku as local_sku,
      p.nama_barang as local_product_name,
      coalesce(p.harga_hpp_default, 0) as hpp_amount,
      coalesce(h.target_margin_percent, p_default_target_margin, 30) as target_margin_percent,
      h.hpp_mapping_id,
      coalesce(h.hpp_amount, h.hpp_per_item, h.hpp, 0) as existing_hpp
    from public.marketplace_sku_maps m
    join public.products p
      on p.tenant_id = m.tenant_id
     and p.product_id = coalesce(m.local_product_id, m.product_id)
    left join public.marketplace_variant_hpp_mappings h
      on h.tenant_id = m.tenant_id
     and h.marketplace_account_id = m.marketplace_account_id
     and coalesce(h.marketplace_product_id, '') = coalesce(m.marketplace_product_id, '')
     and coalesce(h.marketplace_sku_id, '') = coalesce(m.marketplace_sku_id, '')
    where m.tenant_id = p_tenant_id
      and (p_marketplace_account_id is null or m.marketplace_account_id = p_marketplace_account_id)
      and coalesce(m.status, 'active') <> 'deleted'
      and coalesce(p.status, 'active') = 'active'
      and coalesce(p.harga_hpp_default, 0) > 0
      and (p_overwrite or h.hpp_mapping_id is null or coalesce(h.hpp_amount, h.hpp_per_item, h.hpp, 0) = 0)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'tenant_id', tenant_id,
    'marketplace_account_id', marketplace_account_id,
    'marketplace', marketplace,
    'marketplace_product_id', marketplace_product_id,
    'marketplace_sku_id', marketplace_sku_id,
    'marketplace_seller_sku', marketplace_seller_sku,
    'marketplace_product_name', marketplace_product_name,
    'marketplace_variant_name', marketplace_variation_name,
    'local_product_id', local_product_id,
    'local_sku', local_sku,
    'local_product_name', local_product_name,
    'hpp', hpp_amount,
    'hpp_amount', hpp_amount,
    'hpp_per_item', hpp_amount,
    'target_margin_percent', target_margin_percent
  )), '[]'::jsonb)
  into v_rows
  from source_rows;

  if jsonb_array_length(v_rows) = 0 then
    return jsonb_build_object('ok', true, 'upserted', 0, 'message', 'Tidak ada mapping SKU dengan HPP default yang perlu disinkronkan.');
  end if;

  select public.marketplace_variant_hpp_upsert_bulk(v_rows) into v_result;
  return coalesce(v_result, jsonb_build_object('ok', true, 'upserted', jsonb_array_length(v_rows)));
end;
$$;

grant execute on function public.marketplace_sync_hpp_from_sku_maps(uuid,uuid,boolean,numeric) to authenticated, service_role;

create or replace function public.marketplace_finance_recalc_after_hpp_mapping(
  p_tenant_id uuid,
  p_marketplace_account_id uuid default null,
  p_start date default null,
  p_end date default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_start date := coalesce(p_start, date_trunc('month', now())::date);
  v_end date := coalesce(p_end, now()::date);
  v_cache_result jsonb;
begin
  begin
    select public.finance_fix_exact_cache_settled_hpp(
      p_start := v_start,
      p_end := v_end,
      p_marketplace := null,
      p_account_id := p_marketplace_account_id
    ) into v_cache_result;
  exception when undefined_function then
    v_cache_result := jsonb_build_object('ok', true, 'message', 'Exact finance cache function belum tersedia. Dashboard akan membaca data live/RPC utama.');
  when others then
    v_cache_result := jsonb_build_object('ok', false, 'message', sqlerrm);
  end;

  notify pgrst, 'reload schema';
  return jsonb_build_object(
    'ok', true,
    'start', v_start,
    'end', v_end,
    'marketplace_account_id', p_marketplace_account_id,
    'cache_result', coalesce(v_cache_result, '{}'::jsonb)
  );
end;
$$;

grant execute on function public.marketplace_finance_recalc_after_hpp_mapping(uuid,uuid,date,date) to authenticated, service_role;

notify pgrst, 'reload schema';
