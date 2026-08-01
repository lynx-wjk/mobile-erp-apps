-- Final compatibility hotfix after historical import recovery.
-- Adds missing HPP compatibility columns and recreates robust functions.
-- Safe: no delete, no reset.

alter table if exists public.marketplace_variant_hpp_mappings
  add column if not exists hpp numeric;

alter table if exists public.marketplace_variant_hpp_mappings
  add column if not exists hpp_amount numeric;

alter table if exists public.marketplace_variant_hpp_mappings
  add column if not exists hpp_per_item numeric;

alter table if exists public.marketplace_variant_hpp_mappings
  add column if not exists target_margin_percent numeric;

alter table if exists public.marketplace_variant_hpp_mappings
  add column if not exists source text;

alter table if exists public.marketplace_variant_hpp_mappings
  add column if not exists marketplace_product_id text;

alter table if exists public.marketplace_variant_hpp_mappings
  add column if not exists marketplace_sku_id text;

alter table if exists public.marketplace_variant_hpp_mappings
  add column if not exists marketplace_seller_sku text;

alter table if exists public.marketplace_variant_hpp_mappings
  add column if not exists marketplace_product_name text;

alter table if exists public.marketplace_variant_hpp_mappings
  add column if not exists marketplace_variant_name text;

alter table if exists public.marketplace_variant_hpp_mappings
  add column if not exists local_product_id uuid;

alter table if exists public.marketplace_variant_hpp_mappings
  add column if not exists local_sku text;

alter table if exists public.marketplace_variant_hpp_mappings
  add column if not exists local_product_name text;

create index if not exists idx_mo_fast_list_tenant_date
  on public.marketplace_orders(tenant_id, order_created_at desc);

create index if not exists idx_mo_fast_list_account_date
  on public.marketplace_orders(marketplace_account_id, order_created_at desc);

create index if not exists idx_moi_fast_list_order
  on public.marketplace_order_items(marketplace_order_id);

create index if not exists idx_msm_account_variant
  on public.marketplace_sku_maps(marketplace_account_id, marketplace_product_id, marketplace_sku_id);

create index if not exists idx_mvhm_account_variant
  on public.marketplace_variant_hpp_mappings(marketplace_account_id, marketplace_product_id, marketplace_sku_id);

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
stable
security definer
set search_path = public
as $$
declare
  v_limit int := greatest(1, least(coalesce(p_limit, 120), 250));
  v_offset int := greatest(0, coalesce(p_offset, 0));
  v_start timestamptz := case when p_start is null then null else (p_start::timestamp - interval '7 hours')::timestamptz end;
  v_end timestamptz := case when p_end is null then null else ((p_end + 1)::timestamp - interval '7 hours')::timestamptz end;
  v_result jsonb;
begin
  with filtered_orders as (
    select
      o.marketplace_order_id,
      o.tenant_id,
      o.marketplace_account_id,
      o.marketplace,
      o.order_created_at,
      o.order_updated_at,
      o.pulled_at,
      o.updated_at,
      to_jsonb(o) as oj,
      to_jsonb(a) as aj
    from public.marketplace_orders o
    left join public.marketplace_accounts a
      on a.marketplace_account_id = o.marketplace_account_id
    where o.tenant_id = p_tenant_id
      and (
        p_marketplace is null or p_marketplace = '' or p_marketplace = 'all'
        or o.marketplace = p_marketplace
      )
      and (
        p_marketplace_account_id is null
        or o.marketplace_account_id = p_marketplace_account_id
      )
      and (
        p_status is null or p_status = '' or p_status = 'all'
        or coalesce(to_jsonb(o)->>'stock_action_status', 'pending') = p_status
      )
      and (v_start is null or o.order_created_at >= v_start)
      and (v_end is null or o.order_created_at < v_end)
      and (
        p_search is null or btrim(p_search) = '' or
        coalesce(to_jsonb(o)->>'external_order_id', '') ilike '%' || p_search || '%' or
        coalesce(to_jsonb(o)->>'order_sn', '') ilike '%' || p_search || '%' or
        coalesce(to_jsonb(o)->>'remote_order_id', '') ilike '%' || p_search || '%' or
        coalesce(to_jsonb(o)->>'order_id', '') ilike '%' || p_search || '%' or
        coalesce(to_jsonb(o)->>'package_id', '') ilike '%' || p_search || '%' or
        coalesce(to_jsonb(o)->>'tracking_number', '') ilike '%' || p_search || '%' or
        coalesce(to_jsonb(o)->>'buyer_username', '') ilike '%' || p_search || '%' or
        coalesce(to_jsonb(o)->>'recipient_name', '') ilike '%' || p_search || '%'
      )
    order by o.order_created_at desc nulls last, o.pulled_at desc nulls last, o.updated_at desc nulls last
    limit v_limit offset v_offset
  ),
  item_source as (
    select
      i.marketplace_order_id,
      to_jsonb(i) as ij
    from public.marketplace_order_items i
    join filtered_orders fo on fo.marketplace_order_id = i.marketplace_order_id
  ),
  item_counts as (
    select
      marketplace_order_id,
      count(*)::int as item_count,
      coalesce(sum(coalesce(nullif(ij->>'quantity', '')::numeric, nullif(ij->>'qty', '')::numeric, 1)), 0) as qty_total,
      count(*) filter (
        where coalesce(ij->>'local_sku', '') <> ''
           or coalesce(ij->>'product_id', '') <> ''
      )::int as mapped_item_count,
      count(*) filter (
        where coalesce(ij->>'local_sku', '') = ''
          and coalesce(ij->>'product_id', '') = ''
      )::int as unmapped_item_count,
      count(*) filter (where coalesce(ij->>'stock_action_status', '') = 'stock_out_done')::int as stock_out_done_count,
      count(*) filter (where coalesce(ij->>'stock_action_status', '') = 'stock_out_failed')::int as stock_out_failed_count,
      count(*) filter (where coalesce(ij->>'stock_action_status', '') = 'reserved')::int as reserved_item_count,
      count(*) filter (where coalesce(ij->>'scan_status', '') = 'partial_scanned')::int as partial_scanned_item_count,
      count(*) filter (where coalesce(ij->>'scan_status', '') = 'scanned_done')::int as scanned_done_item_count
    from item_source
    group by marketplace_order_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'marketplace_order_id', fo.marketplace_order_id,
    'tenant_id', fo.tenant_id,
    'marketplace_account_id', fo.marketplace_account_id,
    'marketplace', fo.marketplace,
    'account_store_alias', coalesce(fo.aj->>'store_alias', fo.aj->>'shop_name', fo.marketplace),
    'account_shop_name', coalesce(fo.aj->>'shop_name', fo.aj->>'store_alias', fo.marketplace),
    'external_order_id', coalesce(fo.oj->>'external_order_id', fo.oj->>'order_sn', fo.oj->>'remote_order_id', fo.oj->>'order_id', '-'),
    'order_sn', coalesce(fo.oj->>'order_sn', ''),
    'remote_order_id', coalesce(fo.oj->>'remote_order_id', ''),
    'order_id', coalesce(fo.oj->>'order_id', ''),
    'order_status', coalesce(fo.oj->>'order_status', fo.oj->>'status', '-'),
    'order_status_label', coalesce(fo.oj->>'order_status_label', fo.oj->>'order_status', fo.oj->>'status', '-'),
    'stock_action_status', coalesce(fo.oj->>'stock_action_status', 'pending'),
    'stock_action_label', coalesce(fo.oj->>'stock_action_label', fo.oj->>'stock_action_status', 'Pending'),
    'buyer_username', coalesce(fo.oj->>'buyer_username', '-'),
    'recipient_name', coalesce(fo.oj->>'recipient_name', '-'),
    'payment_method', coalesce(fo.oj->>'payment_method', '-'),
    'currency', coalesce(fo.oj->>'currency', ''),
    'total_amount', coalesce(nullif(fo.oj->>'total_amount', '')::numeric, nullif(fo.oj->>'gross_amount', '')::numeric, 0),
    'order_created_at', fo.order_created_at,
    'order_updated_at', fo.order_updated_at,
    'pulled_at', fo.pulled_at,
    'last_error', fo.oj->>'last_error',
    'item_count', coalesce(ic.item_count, 0),
    'qty_total', coalesce(ic.qty_total, 0),
    'mapped_item_count', coalesce(ic.mapped_item_count, 0),
    'unmapped_item_count', coalesce(ic.unmapped_item_count, 0),
    'stock_out_done_count', coalesce(ic.stock_out_done_count, 0),
    'stock_out_failed_count', coalesce(ic.stock_out_failed_count, 0),
    'reserved_item_count', coalesce(ic.reserved_item_count, 0),
    'partial_scanned_item_count', coalesce(ic.partial_scanned_item_count, 0),
    'scanned_done_item_count', coalesce(ic.scanned_done_item_count, 0),
    'order_status_group', coalesce(fo.oj->>'order_status_group', 'normal'),
    'tracking_number', coalesce(fo.oj->>'tracking_number', ''),
    'shipping_provider_name', coalesce(fo.oj->>'shipping_provider_name', ''),
    'package_id', coalesce(fo.oj->>'package_id', ''),
    'logistic_status', coalesce(fo.oj->>'logistic_status', ''),
    'label_code', coalesce(fo.oj->>'label_code', ''),
    'has_cancel_request',
      case lower(coalesce(fo.oj->>'has_cancel_request', 'false'))
        when 'true' then true
        when 't' then true
        when '1' then true
        else false
      end,
    'cancel_request_id', coalesce(fo.oj->>'cancel_request_id', ''),
    'cancel_request_status', coalesce(fo.oj->>'cancel_request_status', ''),
    'cancel_request_reason', coalesce(fo.oj->>'cancel_request_reason', ''),
    'cancel_request_note', coalesce(fo.oj->>'cancel_request_note', ''),
    'cancel_requested_at', fo.oj->>'cancel_requested_at',
    'cancel_request_pulled_at', fo.oj->>'cancel_request_pulled_at'
  ) order by fo.order_created_at desc nulls last), '[]'::jsonb)
  into v_result
  from filtered_orders fo
  left join item_counts ic on ic.marketplace_order_id = fo.marketplace_order_id;

  return v_result;
end;
$$;

grant execute on function public.marketplace_orders_fast_list(uuid, text, uuid, text, text, date, date, integer, integer)
  to authenticated, service_role;

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
  v_updated int := 0;
  v_inserted int := 0;
begin
  create temporary table if not exists _hpp_sync_source (
    tenant_id uuid,
    marketplace_account_id uuid,
    marketplace text,
    marketplace_product_id text,
    marketplace_sku_id text,
    marketplace_seller_sku text,
    marketplace_product_name text,
    marketplace_variant_name text,
    local_product_id uuid,
    local_sku text,
    local_product_name text,
    hpp numeric,
    target_margin_percent numeric
  ) on commit drop;

  truncate _hpp_sync_source;

  insert into _hpp_sync_source
  select
    m.tenant_id,
    m.marketplace_account_id,
    m.marketplace,
    m.marketplace_product_id,
    m.marketplace_sku_id,
    m.marketplace_seller_sku,
    m.marketplace_product_name,
    coalesce(m.marketplace_variation_name, m.marketplace_variant_name),
    coalesce(nullif(m.local_product_id::text, '')::uuid, nullif(m.product_id::text, '')::uuid),
    coalesce(nullif(m.local_sku, ''), p.kode_sku),
    coalesce(nullif(m.local_product_name, ''), p.nama_barang),
    coalesce(p.harga_hpp_default, 0),
    coalesce(nullif(p_default_target_margin, 0), 30)
  from public.marketplace_sku_maps m
  join public.products p
    on p.tenant_id = m.tenant_id
   and (
     p.product_id = coalesce(nullif(m.local_product_id::text, '')::uuid, nullif(m.product_id::text, '')::uuid)
     or (m.local_product_id is null and m.product_id is null and p.kode_sku = m.local_sku)
   )
  where m.tenant_id = p_tenant_id
    and coalesce(m.status, 'active') <> 'deleted'
    and (p_marketplace_account_id is null or m.marketplace_account_id = p_marketplace_account_id)
    and coalesce(m.marketplace_product_id, '') <> ''
    and coalesce(m.marketplace_sku_id, '') <> '';

  update public.marketplace_variant_hpp_mappings h
  set
    local_product_id = s.local_product_id,
    local_sku = s.local_sku,
    local_product_name = s.local_product_name,
    marketplace_seller_sku = coalesce(s.marketplace_seller_sku, h.marketplace_seller_sku),
    marketplace_product_name = coalesce(s.marketplace_product_name, h.marketplace_product_name),
    marketplace_variant_name = coalesce(s.marketplace_variant_name, h.marketplace_variant_name),
    hpp = case when p_overwrite or coalesce(h.hpp, 0) = 0 then s.hpp else h.hpp end,
    hpp_amount = case when p_overwrite or coalesce(h.hpp_amount, 0) = 0 then s.hpp else h.hpp_amount end,
    hpp_per_item = case when p_overwrite or coalesce(h.hpp_per_item, 0) = 0 then s.hpp else h.hpp_per_item end,
    target_margin_percent = case when coalesce(h.target_margin_percent, 0) = 0 then s.target_margin_percent else h.target_margin_percent end,
    source = coalesce(h.source, 'sync_from_sku_mapping'),
    updated_at = now()
  from _hpp_sync_source s
  where h.tenant_id = s.tenant_id
    and h.marketplace_account_id = s.marketplace_account_id
    and h.marketplace_product_id = s.marketplace_product_id
    and h.marketplace_sku_id = s.marketplace_sku_id;

  get diagnostics v_updated = row_count;

  insert into public.marketplace_variant_hpp_mappings (
    tenant_id,
    marketplace_account_id,
    marketplace,
    marketplace_product_id,
    marketplace_sku_id,
    marketplace_seller_sku,
    marketplace_product_name,
    marketplace_variant_name,
    local_product_id,
    local_sku,
    local_product_name,
    hpp,
    hpp_amount,
    hpp_per_item,
    target_margin_percent,
    source,
    created_at,
    updated_at
  )
  select
    s.tenant_id,
    s.marketplace_account_id,
    s.marketplace,
    s.marketplace_product_id,
    s.marketplace_sku_id,
    s.marketplace_seller_sku,
    s.marketplace_product_name,
    s.marketplace_variant_name,
    s.local_product_id,
    s.local_sku,
    s.local_product_name,
    s.hpp,
    s.hpp,
    s.hpp,
    s.target_margin_percent,
    'sync_from_sku_mapping',
    now(),
    now()
  from _hpp_sync_source s
  where not exists (
    select 1
    from public.marketplace_variant_hpp_mappings h
    where h.tenant_id = s.tenant_id
      and h.marketplace_account_id = s.marketplace_account_id
      and h.marketplace_product_id = s.marketplace_product_id
      and h.marketplace_sku_id = s.marketplace_sku_id
  );

  get diagnostics v_inserted = row_count;

  return jsonb_build_object(
    'ok', true,
    'inserted', v_inserted,
    'updated', v_updated,
    'upserted', v_inserted + v_updated,
    'overwrite', p_overwrite,
    'message', format('%s HPP mapping disinkronkan dari SKU mapping.', v_inserted + v_updated)
  );
end;
$$;

grant execute on function public.marketplace_sync_hpp_from_sku_maps(uuid, uuid, boolean, numeric)
  to authenticated, service_role;

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
  v_orders int := 0;
  v_finance int := 0;
  v_hpp int := 0;
begin
  select count(*) into v_orders
  from public.marketplace_orders
  where tenant_id = p_tenant_id
    and (p_marketplace_account_id is null or marketplace_account_id = p_marketplace_account_id)
    and (p_start is null or order_created_at >= (p_start::timestamp - interval '7 hours')::timestamptz)
    and (p_end is null or order_created_at < ((p_end + 1)::timestamp - interval '7 hours')::timestamptz);

  select count(*) into v_finance
  from public.marketplace_finance_reports
  where tenant_id = p_tenant_id
    and (p_marketplace_account_id is null or marketplace_account_id = p_marketplace_account_id);

  select count(*) into v_hpp
  from public.marketplace_variant_hpp_mappings
  where tenant_id = p_tenant_id
    and (p_marketplace_account_id is null or marketplace_account_id = p_marketplace_account_id)
    and coalesce(hpp, hpp_amount, hpp_per_item, 0) > 0;

  notify pgrst, 'reload schema';

  return jsonb_build_object(
    'ok', true,
    'orders', v_orders,
    'finance_reports', v_finance,
    'hpp_maps', v_hpp,
    'message', 'Finance siap dibaca ulang setelah sinkron HPP.'
  );
end;
$$;

grant execute on function public.marketplace_finance_recalc_after_hpp_mapping(uuid, uuid, date, date)
  to authenticated, service_role;

notify pgrst, 'reload schema';
