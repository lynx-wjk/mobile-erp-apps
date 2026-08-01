alter table if exists public.marketplace_variant_hpp_mappings
  drop constraint if exists marketplace_variant_hpp_mappi_tenant_id_marketplace_account_key;

drop index if exists public.uq_marketplace_variant_hpp_mappings_marketplace_sku_id_v82o;

create unique index if not exists uq_mvhpp_active_marketplace_key_20260627
  on public.marketplace_variant_hpp_mappings (
    tenant_id,
    marketplace_account_id,
    marketplace,
    marketplace_product_id,
    marketplace_sku_id
  )
  where coalesce(is_active, true) = true
    and marketplace_product_id is not null
    and marketplace_sku_id is not null;

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
with best_maps as (
  select distinct on (
    m.tenant_id,
    m.marketplace_account_id,
    lower(m.marketplace),
    m.marketplace_product_id,
    m.marketplace_sku_id
  )
    m.*
  from public.marketplace_sku_maps m
  where m.tenant_id = p_tenant_id
    and (p_marketplace_account_id is null or m.marketplace_account_id = p_marketplace_account_id)
    and coalesce(m.status, 'active') = 'active'
    and nullif(trim(m.marketplace_product_id), '') is not null
    and nullif(trim(m.marketplace_sku_id), '') is not null
  order by
    m.tenant_id,
    m.marketplace_account_id,
    lower(m.marketplace),
    m.marketplace_product_id,
    m.marketplace_sku_id,
    m.updated_at desc nulls last,
    m.created_at desc nulls last,
    m.marketplace_sku_map_id::text
),
best_hpp as (
  select distinct on (
    h.tenant_id,
    h.marketplace_account_id,
    lower(h.marketplace),
    h.marketplace_product_id,
    h.marketplace_sku_id
  )
    h.*
  from public.marketplace_variant_hpp_mappings h
  where h.tenant_id = p_tenant_id
    and (p_marketplace_account_id is null or h.marketplace_account_id = p_marketplace_account_id)
    and coalesce(h.is_active, true) = true
    and nullif(trim(h.marketplace_product_id), '') is not null
    and nullif(trim(h.marketplace_sku_id), '') is not null
  order by
    h.tenant_id,
    h.marketplace_account_id,
    lower(h.marketplace),
    h.marketplace_product_id,
    h.marketplace_sku_id,
    h.updated_at desc nulls last,
    h.created_at desc nulls last,
    h.mapping_id::text
),
variant_rows as (
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
    h.mapping_id as hpp_mapping_id,
    h.hpp,
    coalesce(h.hpp_amount, h.hpp, h.hpp_per_item) as hpp_amount,
    coalesce(h.hpp_per_item, h.hpp_amount, h.hpp) as hpp_per_item,
    coalesce(h.target_margin_percent, h.target_margin) as target_margin_percent,
    h.target_margin
  from public.marketplace_variant_snapshots v
  left join best_maps m
    on m.tenant_id = v.tenant_id
   and m.marketplace_account_id = v.marketplace_account_id
   and lower(m.marketplace) = lower(coalesce(v.marketplace, m.marketplace))
   and m.marketplace_product_id = v.marketplace_product_id
   and m.marketplace_sku_id = v.marketplace_sku_id
  left join best_hpp h
    on h.tenant_id = v.tenant_id
   and h.marketplace_account_id = v.marketplace_account_id
   and lower(h.marketplace) = lower(coalesce(v.marketplace, h.marketplace))
   and h.marketplace_product_id = v.marketplace_product_id
   and h.marketplace_sku_id = v.marketplace_sku_id
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
  'source', 'marketplace_sku_hpp_direct_key_contracts_20260627',
  'variants', coalesce((
    select jsonb_agg(to_jsonb(v) order by v.marketplace, v.marketplace_product_name, v.marketplace_variant_name)
    from variant_rows v
  ), '[]'::jsonb),
  'local_products', coalesce((
    select jsonb_agg(to_jsonb(p) order by p.nama_barang, p.kode_sku)
    from local_products p
  ), '[]'::jsonb)
);
$$;

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
  v_key text;
  v_seen_keys text[] := array[]::text[];
  v_upserted int := 0;
  v_skipped_invalid int := 0;
  v_duplicates_skipped int := 0;
  v_errors jsonb := '[]'::jsonb;
begin
  if jsonb_typeof(coalesce(p_rows, '[]'::jsonb)) <> 'array' then
    return jsonb_build_object('ok', false, 'message', 'p_rows harus array jsonb', 'upserted', 0);
  end if;

  for r in select value from jsonb_array_elements(p_rows) loop
    begin
      v_tenant_id := nullif(r->>'tenant_id', '')::uuid;
      v_account_id := nullif(coalesce(r->>'marketplace_account_id', r->>'account_id'), '')::uuid;
      v_marketplace := nullif(trim(coalesce(r->>'marketplace', '')), '');
      v_snapshot_id := nullif(r->>'marketplace_variant_snapshot_id', '')::uuid;
      v_product_id := nullif(coalesce(r->>'local_product_id', r->>'product_id'), '')::uuid;
      v_local_sku := nullif(trim(coalesce(r->>'local_sku', '')), '');
      v_marketplace_product_id := nullif(trim(coalesce(r->>'marketplace_product_id', '')), '');
      v_marketplace_sku_id := nullif(trim(coalesce(r->>'marketplace_sku_id', r->>'sku_id', '')), '');
      v_marketplace_sku := nullif(trim(coalesce(r->>'marketplace_sku', r->>'marketplace_sku_code', '')), '');
      v_marketplace_seller_sku := nullif(trim(coalesce(r->>'marketplace_seller_sku', r->>'seller_sku', '')), '');
      v_product_name := nullif(trim(coalesce(r->>'marketplace_product_name', r->>'product_name', '')), '');
      v_variant_name := nullif(trim(coalesce(r->>'marketplace_variation_name', r->>'marketplace_variant_name', r->>'variant_name', '')), '');

      if v_account_id is not null then
        select coalesce(v_tenant_id, a.tenant_id),
               coalesce(v_marketplace, nullif(trim(a.marketplace), ''))
          into v_tenant_id, v_marketplace
        from public.marketplace_accounts a
        where a.marketplace_account_id = v_account_id
        limit 1;
      end if;

      if v_snapshot_id is not null and (v_marketplace_product_id is null or v_marketplace_sku_id is null) then
        select
          coalesce(v_tenant_id, s.tenant_id),
          coalesce(v_account_id, s.marketplace_account_id),
          coalesce(v_marketplace, s.marketplace),
          coalesce(v_marketplace_product_id, nullif(trim(s.marketplace_product_id), '')),
          coalesce(v_marketplace_sku_id, nullif(trim(s.marketplace_sku_id), '')),
          coalesce(v_marketplace_sku, nullif(trim(s.marketplace_sku_code), '')),
          coalesce(v_marketplace_seller_sku, nullif(trim(s.marketplace_seller_sku), '')),
          coalesce(v_product_name, nullif(trim(s.marketplace_product_name), '')),
          coalesce(v_variant_name, nullif(trim(s.marketplace_variant_name), ''))
        into
          v_tenant_id,
          v_account_id,
          v_marketplace,
          v_marketplace_product_id,
          v_marketplace_sku_id,
          v_marketplace_sku,
          v_marketplace_seller_sku,
          v_product_name,
          v_variant_name
        from public.marketplace_variant_snapshots s
        where s.marketplace_variant_snapshot_id = v_snapshot_id
        limit 1;
      end if;

      if v_tenant_id is null
         or v_account_id is null
         or v_marketplace is null
         or v_marketplace_product_id is null
         or v_marketplace_sku_id is null then
        v_skipped_invalid := v_skipped_invalid + 1;
        continue;
      end if;

      v_key := v_tenant_id::text || '|' || v_account_id::text || '|' ||
               lower(v_marketplace) || '|' || v_marketplace_product_id || '|' ||
               v_marketplace_sku_id;
      if v_key = any(v_seen_keys) then
        v_duplicates_skipped := v_duplicates_skipped + 1;
        continue;
      end if;
      v_seen_keys := array_append(v_seen_keys, v_key);

      if v_product_id is null and v_local_sku is not null then
        select p.product_id, p.kode_sku, p.nama_barang
          into v_product_id, v_local_sku, v_local_name
        from public.products p
        where p.tenant_id = v_tenant_id
          and lower(p.kode_sku) = lower(v_local_sku)
          and coalesce(p.status, 'active') = 'active'
        order by p.updated_at desc nulls last, p.created_at desc nulls last
        limit 1;
      elsif v_product_id is not null then
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

      select m.marketplace_sku_map_id
        into v_existing_id
      from public.marketplace_sku_maps m
      where m.tenant_id = v_tenant_id
        and m.marketplace_account_id = v_account_id
        and lower(m.marketplace) = lower(v_marketplace)
        and m.marketplace_product_id = v_marketplace_product_id
        and m.marketplace_sku_id = v_marketplace_sku_id
        and coalesce(m.status, 'active') = 'active'
      order by m.updated_at desc nulls last, m.created_at desc nulls last, m.marketplace_sku_map_id::text
      limit 1;

      if v_existing_id is null then
        insert into public.marketplace_sku_maps(
          tenant_id,
          marketplace_account_id,
          marketplace,
          product_id,
          local_product_id,
          local_sku,
          local_product_name,
          marketplace_product_id,
          marketplace_sku_id,
          marketplace_sku,
          marketplace_seller_sku,
          marketplace_product_name,
          marketplace_variation_name,
          marketplace_variant_snapshot_id,
          mapping_source,
          sync_enabled,
          status,
          last_error,
          created_at,
          updated_at
        ) values (
          v_tenant_id,
          v_account_id,
          v_marketplace,
          v_product_id,
          v_product_id,
          v_local_sku,
          v_local_name,
          v_marketplace_product_id,
          v_marketplace_sku_id,
          v_marketplace_sku,
          v_marketplace_seller_sku,
          v_product_name,
          v_variant_name,
          v_snapshot_id,
          'excel_import',
          coalesce(p_sync_enabled, true),
          'active',
          null,
          now(),
          now()
        )
        returning marketplace_sku_map_id into v_existing_id;
      else
        update public.marketplace_sku_maps
           set marketplace = v_marketplace,
               product_id = v_product_id,
               local_product_id = v_product_id,
               local_sku = v_local_sku,
               local_product_name = v_local_name,
               marketplace_product_id = v_marketplace_product_id,
               marketplace_sku_id = v_marketplace_sku_id,
               marketplace_sku = coalesce(v_marketplace_sku, marketplace_sku),
               marketplace_seller_sku = coalesce(v_marketplace_seller_sku, marketplace_seller_sku),
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

      update public.marketplace_sku_maps m
         set status = 'inactive',
             sync_enabled = false,
             is_stock_sync_enabled = false,
             updated_at = now()
       where m.tenant_id = v_tenant_id
         and m.marketplace_account_id = v_account_id
         and lower(m.marketplace) = lower(v_marketplace)
         and m.marketplace_product_id = v_marketplace_product_id
         and m.marketplace_sku_id = v_marketplace_sku_id
         and m.marketplace_sku_map_id <> v_existing_id
         and coalesce(m.status, 'active') = 'active';

      v_upserted := v_upserted + 1;
    exception when others then
      v_skipped_invalid := v_skipped_invalid + 1;
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('row', r, 'error', sqlerrm));
    end;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'source', 'marketplace_sku_mapping_import_bulk_direct_key_20260627',
    'upserted', v_upserted,
    'skipped_invalid', v_skipped_invalid,
    'duplicates_skipped', v_duplicates_skipped,
    'errors', v_errors
  );
end;
$$;

create or replace function public.marketplace_variant_hpp_upsert_bulk(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rows jsonb := coalesce(p_rows, '[]'::jsonb);
  v_row jsonb;
  v_marketplace_account_id uuid;
  v_tenant_id uuid;
  v_marketplace text;
  v_marketplace_product_id text;
  v_marketplace_sku_id text;
  v_marketplace_seller_sku text;
  v_marketplace_product_name text;
  v_marketplace_variant_name text;
  v_local_product_id uuid;
  v_local_variant_id uuid;
  v_local_product_name text;
  v_local_variant_name text;
  v_local_sku text;
  v_hpp numeric;
  v_hpp_text text;
  v_margin numeric;
  v_existing_id uuid;
  v_new_id uuid;
  v_key text;
  v_seen_keys text[] := array[]::text[];
  v_saved int := 0;
  v_skipped int := 0;
  v_duplicates_skipped int := 0;
  v_errors int := 0;
  v_total int := 0;
  v_error_sample jsonb := '[]'::jsonb;
begin
  if jsonb_typeof(v_rows) <> 'array' then
    return jsonb_build_object('ok', false, 'message', 'Payload harus JSON array.', 'saved', 0, 'upserted', 0, 'skipped', 0, 'errors', 1);
  end if;

  for v_row in select value from jsonb_array_elements(v_rows) loop
    v_total := v_total + 1;
    begin
      v_marketplace_account_id := nullif(coalesce(v_row->>'marketplace_account_id', v_row->>'account_id', v_row->>'marketplaceAccountId'), '')::uuid;
      v_marketplace := nullif(trim(coalesce(v_row->>'marketplace', v_row->>'platform', '')), '');
      v_marketplace_product_id := nullif(trim(coalesce(v_row->>'marketplace_product_id', v_row->>'product_id_marketplace', v_row->>'marketplaceProductId', '')), '');
      v_marketplace_sku_id := nullif(trim(coalesce(v_row->>'marketplace_sku_id', v_row->>'sku_id', v_row->>'marketplaceSkuId', '')), '');
      v_marketplace_seller_sku := nullif(trim(coalesce(v_row->>'marketplace_seller_sku', v_row->>'seller_sku', v_row->>'sellerSku', '')), '');

      if v_marketplace_account_id is not null then
        select a.tenant_id, coalesce(v_marketplace, nullif(trim(a.marketplace), ''))
          into v_tenant_id, v_marketplace
        from public.marketplace_accounts a
        where a.marketplace_account_id = v_marketplace_account_id
        limit 1;
      end if;

      v_tenant_id := coalesce(v_tenant_id, nullif(v_row->>'tenant_id', '')::uuid);
      v_marketplace_product_name := nullif(trim(coalesce(v_row->>'marketplace_product_name', v_row->>'product_name', v_row->>'nama_produk_marketplace', '')), '');
      v_marketplace_variant_name := nullif(trim(coalesce(v_row->>'marketplace_variant_name', v_row->>'variant_name', v_row->>'variant', v_row->>'sku_name', v_row->>'nama_varian', '')), '');
      v_local_product_id := nullif(coalesce(v_row->>'local_product_id', v_row->>'product_id'), '')::uuid;
      v_local_variant_id := nullif(coalesce(v_row->>'local_variant_id', v_row->>'variant_id'), '')::uuid;
      v_local_sku := nullif(trim(coalesce(v_row->>'local_sku', v_row->>'sku_lokal', '')), '');
      v_local_product_name := nullif(trim(coalesce(v_row->>'local_product_name', v_row->>'nama_produk_lokal', '')), '');
      v_local_variant_name := nullif(trim(coalesce(v_row->>'local_variant_name', v_row->>'nama_varian_lokal', '')), '');
      v_hpp_text := nullif(trim(coalesce(v_row->>'hpp_amount', v_row->>'hpp_per_item', v_row->>'hpp', '')), '');
      v_hpp := public._finance_to_num_v82o(v_hpp_text);
      v_margin := coalesce(
        public._finance_to_num_v82o(v_row->>'target_margin_percent'),
        public._finance_to_num_v82o(v_row->>'target_margin'),
        public._finance_to_num_v82o(v_row->>'margin_percent'),
        0
      );

      if v_tenant_id is null
         or v_marketplace_account_id is null
         or v_marketplace is null
         or v_marketplace_product_id is null
         or v_marketplace_sku_id is null
         or v_hpp is null then
        v_skipped := v_skipped + 1;
        continue;
      end if;

      v_key := v_tenant_id::text || '|' || v_marketplace_account_id::text || '|' ||
               lower(v_marketplace) || '|' || v_marketplace_product_id || '|' ||
               v_marketplace_sku_id;
      if v_key = any(v_seen_keys) then
        v_duplicates_skipped := v_duplicates_skipped + 1;
        continue;
      end if;
      v_seen_keys := array_append(v_seen_keys, v_key);

      select h.mapping_id
        into v_existing_id
      from public.marketplace_variant_hpp_mappings h
      where h.tenant_id = v_tenant_id
        and h.marketplace_account_id = v_marketplace_account_id
        and lower(h.marketplace) = lower(v_marketplace)
        and h.marketplace_product_id = v_marketplace_product_id
        and h.marketplace_sku_id = v_marketplace_sku_id
        and coalesce(h.is_active, true) = true
      order by h.updated_at desc nulls last, h.created_at desc nulls last, h.mapping_id::text
      limit 1;

      if v_existing_id is null then
        v_new_id := gen_random_uuid();
        insert into public.marketplace_variant_hpp_mappings (
          mapping_id,
          hpp_mapping_id,
          id,
          tenant_id,
          marketplace_account_id,
          marketplace,
          marketplace_product_id,
          marketplace_sku_id,
          marketplace_seller_sku,
          marketplace_product_name,
          marketplace_variant_name,
          local_product_id,
          local_variant_id,
          local_product_name,
          local_variant_name,
          local_sku,
          hpp,
          hpp_amount,
          hpp_per_item,
          target_margin,
          target_margin_percent,
          is_active,
          source,
          updated_by,
          updated_at,
          created_at
        ) values (
          v_new_id,
          v_new_id,
          v_new_id,
          v_tenant_id,
          v_marketplace_account_id,
          v_marketplace,
          v_marketplace_product_id,
          v_marketplace_sku_id,
          v_marketplace_seller_sku,
          v_marketplace_product_name,
          v_marketplace_variant_name,
          v_local_product_id,
          v_local_variant_id,
          v_local_product_name,
          v_local_variant_name,
          v_local_sku,
          v_hpp,
          v_hpp,
          v_hpp,
          v_margin,
          v_margin,
          true,
          'hpp_import',
          auth.uid(),
          now(),
          now()
        )
        returning mapping_id into v_existing_id;
      else
        update public.marketplace_variant_hpp_mappings h
           set marketplace_seller_sku = coalesce(v_marketplace_seller_sku, h.marketplace_seller_sku),
               marketplace_product_name = coalesce(v_marketplace_product_name, h.marketplace_product_name),
               marketplace_variant_name = coalesce(v_marketplace_variant_name, h.marketplace_variant_name),
               local_product_id = coalesce(v_local_product_id, h.local_product_id),
               local_variant_id = coalesce(v_local_variant_id, h.local_variant_id),
               local_product_name = coalesce(v_local_product_name, h.local_product_name),
               local_variant_name = coalesce(v_local_variant_name, h.local_variant_name),
               local_sku = coalesce(v_local_sku, h.local_sku),
               hpp = v_hpp,
               hpp_amount = v_hpp,
               hpp_per_item = v_hpp,
               target_margin = v_margin,
               target_margin_percent = v_margin,
               is_active = true,
               source = 'hpp_import',
               updated_by = auth.uid(),
               updated_at = now()
         where h.mapping_id = v_existing_id;
      end if;

      update public.marketplace_variant_hpp_mappings h
         set is_active = false,
             updated_at = now()
       where h.tenant_id = v_tenant_id
         and h.marketplace_account_id = v_marketplace_account_id
         and lower(h.marketplace) = lower(v_marketplace)
         and h.marketplace_product_id = v_marketplace_product_id
         and h.marketplace_sku_id = v_marketplace_sku_id
         and h.mapping_id <> v_existing_id
         and coalesce(h.is_active, true) = true;

      v_saved := v_saved + 1;
    exception when others then
      v_errors := v_errors + 1;
      if jsonb_array_length(v_error_sample) < 10 then
        v_error_sample := v_error_sample || jsonb_build_array(jsonb_build_object(
          'row', v_total,
          'marketplace_account_id', coalesce(v_marketplace_account_id::text, v_row->>'marketplace_account_id'),
          'marketplace_product_id', coalesce(v_marketplace_product_id, v_row->>'marketplace_product_id'),
          'marketplace_sku_id', coalesce(v_marketplace_sku_id, v_row->>'marketplace_sku_id'),
          'error', sqlerrm
        ));
      end if;
    end;
  end loop;

  return jsonb_build_object(
    'ok', v_errors = 0,
    'source', 'marketplace_variant_hpp_upsert_bulk_direct_key_20260627',
    'message', format('%s/%s baris HPP tersimpan. skipped=%s duplicates=%s errors=%s.', v_saved, v_total, v_skipped, v_duplicates_skipped, v_errors),
    'total', v_total,
    'requested', v_total,
    'saved', v_saved,
    'upserted', v_saved,
    'skipped', v_skipped,
    'duplicates_skipped', v_duplicates_skipped,
    'errors', v_errors,
    'error_sample', v_error_sample
  );
end;
$$;

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
  r record;
  v_existing_id uuid;
  v_new_id uuid;
  v_inserted int := 0;
  v_updated int := 0;
begin
  for r in
    select distinct on (
      m.tenant_id,
      m.marketplace_account_id,
      lower(m.marketplace),
      m.marketplace_product_id,
      m.marketplace_sku_id
    )
      m.tenant_id,
      m.marketplace_account_id,
      m.marketplace,
      m.marketplace_product_id,
      m.marketplace_sku_id,
      m.marketplace_seller_sku,
      m.marketplace_product_name,
      coalesce(m.marketplace_variant_name, m.marketplace_variation_name) as marketplace_variant_name,
      coalesce(m.local_product_id, m.product_id) as local_product_id,
      m.local_sku,
      m.local_product_name,
      p.harga_hpp_default as product_hpp,
      p.target_margin_percent as product_target_margin,
      m.marketplace_sku_map_id
    from public.marketplace_sku_maps m
    join public.products p
      on p.product_id = coalesce(m.local_product_id, m.product_id)
     and p.tenant_id = m.tenant_id
    where m.tenant_id = p_tenant_id
      and (p_marketplace_account_id is null or m.marketplace_account_id = p_marketplace_account_id)
      and coalesce(m.status, 'active') = 'active'
      and nullif(trim(m.marketplace_product_id), '') is not null
      and nullif(trim(m.marketplace_sku_id), '') is not null
    order by
      m.tenant_id,
      m.marketplace_account_id,
      lower(m.marketplace),
      m.marketplace_product_id,
      m.marketplace_sku_id,
      m.updated_at desc nulls last,
      m.created_at desc nulls last,
      m.marketplace_sku_map_id::text
  loop
    select h.mapping_id
      into v_existing_id
    from public.marketplace_variant_hpp_mappings h
    where h.tenant_id = r.tenant_id
      and h.marketplace_account_id = r.marketplace_account_id
      and lower(h.marketplace) = lower(r.marketplace)
      and h.marketplace_product_id = r.marketplace_product_id
      and h.marketplace_sku_id = r.marketplace_sku_id
      and coalesce(h.is_active, true) = true
    order by h.updated_at desc nulls last, h.created_at desc nulls last, h.mapping_id::text
    limit 1;

    if v_existing_id is null then
      v_new_id := gen_random_uuid();
      insert into public.marketplace_variant_hpp_mappings (
        mapping_id,
        hpp_mapping_id,
        id,
        tenant_id,
        marketplace_account_id,
        marketplace,
        marketplace_product_id,
        marketplace_sku_id,
        marketplace_seller_sku,
        marketplace_product_name,
        marketplace_variant_name,
        local_product_id,
        local_product_name,
        local_sku,
        hpp,
        hpp_amount,
        hpp_per_item,
        target_margin,
        target_margin_percent,
        marketplace_sku_map_id,
        is_active,
        source,
        updated_by,
        updated_at,
        created_at
      ) values (
        v_new_id,
        v_new_id,
        v_new_id,
        r.tenant_id,
        r.marketplace_account_id,
        r.marketplace,
        r.marketplace_product_id,
        r.marketplace_sku_id,
        r.marketplace_seller_sku,
        r.marketplace_product_name,
        r.marketplace_variant_name,
        r.local_product_id,
        r.local_product_name,
        r.local_sku,
        r.product_hpp,
        r.product_hpp,
        r.product_hpp,
        coalesce(r.product_target_margin, p_default_target_margin, 0),
        coalesce(r.product_target_margin, p_default_target_margin, 0),
        r.marketplace_sku_map_id,
        true,
        'sync_from_sku_maps',
        auth.uid(),
        now(),
        now()
      );
      v_inserted := v_inserted + 1;
    else
      update public.marketplace_variant_hpp_mappings h
         set marketplace_seller_sku = coalesce(r.marketplace_seller_sku, h.marketplace_seller_sku),
             marketplace_product_name = coalesce(r.marketplace_product_name, h.marketplace_product_name),
             marketplace_variant_name = coalesce(r.marketplace_variant_name, h.marketplace_variant_name),
             local_product_id = coalesce(r.local_product_id, h.local_product_id),
             local_product_name = coalesce(r.local_product_name, h.local_product_name),
             local_sku = coalesce(r.local_sku, h.local_sku),
             hpp = case when p_overwrite then r.product_hpp else h.hpp end,
             hpp_amount = case when p_overwrite then r.product_hpp else coalesce(h.hpp_amount, h.hpp) end,
             hpp_per_item = case when p_overwrite then r.product_hpp else coalesce(h.hpp_per_item, h.hpp_amount, h.hpp) end,
             target_margin = case when p_overwrite then coalesce(r.product_target_margin, p_default_target_margin, 0) else coalesce(h.target_margin, h.target_margin_percent) end,
             target_margin_percent = case when p_overwrite then coalesce(r.product_target_margin, p_default_target_margin, 0) else coalesce(h.target_margin_percent, h.target_margin) end,
             marketplace_sku_map_id = r.marketplace_sku_map_id,
             is_active = true,
             source = case when p_overwrite then 'sync_from_sku_maps' else coalesce(h.source, 'sync_from_sku_maps') end,
             updated_by = auth.uid(),
             updated_at = now()
       where h.mapping_id = v_existing_id;
      v_updated := v_updated + 1;
    end if;

    update public.marketplace_variant_hpp_mappings h
       set is_active = false,
           updated_at = now()
     where h.tenant_id = r.tenant_id
       and h.marketplace_account_id = r.marketplace_account_id
       and lower(h.marketplace) = lower(r.marketplace)
       and h.marketplace_product_id = r.marketplace_product_id
       and h.marketplace_sku_id = r.marketplace_sku_id
       and h.mapping_id <> coalesce(v_existing_id, v_new_id)
       and coalesce(h.is_active, true) = true;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'source', 'marketplace_sync_hpp_from_sku_maps_direct_key_20260627',
    'inserted', v_inserted,
    'updated', v_updated,
    'upserted', v_inserted + v_updated,
    'overwrite', p_overwrite,
    'message', format('%s HPP mapping disinkronkan dari SKU mapping.', v_inserted + v_updated)
  );
end;
$$;

create or replace function public.marketplace_variant_hpp_list(
  p_account_id uuid default null,
  p_search text default null,
  p_missing_only boolean default false,
  p_page integer default 1,
  p_page_size integer default 20
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
with account_scope as (
  select a.tenant_id, a.marketplace_account_id
  from public.marketplace_accounts a
  where (p_account_id is null or a.marketplace_account_id = p_account_id)
    and (p_account_id is not null or a.tenant_id = public.app_current_tenant_id_or_default())
),
variant_base as (
  select distinct on (
    v.tenant_id,
    v.marketplace_account_id,
    lower(v.marketplace),
    v.marketplace_product_id,
    v.marketplace_sku_id
  )
    v.*
  from public.marketplace_variant_snapshots v
  join account_scope a
    on a.tenant_id = v.tenant_id
   and a.marketplace_account_id = v.marketplace_account_id
  where nullif(trim(v.marketplace_product_id), '') is not null
    and nullif(trim(v.marketplace_sku_id), '') is not null
  order by
    v.tenant_id,
    v.marketplace_account_id,
    lower(v.marketplace),
    v.marketplace_product_id,
    v.marketplace_sku_id,
    v.updated_at desc nulls last,
    v.last_seen_at desc nulls last,
    v.created_at desc nulls last,
    v.marketplace_variant_snapshot_id::text
),
best_hpp as (
  select distinct on (
    h.tenant_id,
    h.marketplace_account_id,
    lower(h.marketplace),
    h.marketplace_product_id,
    h.marketplace_sku_id
  )
    h.*
  from public.marketplace_variant_hpp_mappings h
  join account_scope a
    on a.tenant_id = h.tenant_id
   and a.marketplace_account_id = h.marketplace_account_id
  where coalesce(h.is_active, true) = true
    and nullif(trim(h.marketplace_product_id), '') is not null
    and nullif(trim(h.marketplace_sku_id), '') is not null
  order by
    h.tenant_id,
    h.marketplace_account_id,
    lower(h.marketplace),
    h.marketplace_product_id,
    h.marketplace_sku_id,
    h.updated_at desc nulls last,
    h.created_at desc nulls last,
    h.mapping_id::text
),
joined_rows as (
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
    v.price_amount,
    v.stock_quantity,
    h.mapping_id as hpp_mapping_id,
    h.hpp,
    coalesce(h.hpp_amount, h.hpp, h.hpp_per_item) as hpp_amount,
    coalesce(h.hpp_per_item, h.hpp_amount, h.hpp) as hpp_per_item,
    coalesce(h.target_margin_percent, h.target_margin) as target_margin_percent,
    h.target_margin,
    h.local_product_id,
    h.local_variant_id,
    h.local_product_name,
    h.local_variant_name,
    h.local_sku,
    h.is_active,
    h.source,
    h.updated_at
  from variant_base v
  left join best_hpp h
    on h.tenant_id = v.tenant_id
   and h.marketplace_account_id = v.marketplace_account_id
   and lower(h.marketplace) = lower(coalesce(v.marketplace, h.marketplace))
   and h.marketplace_product_id = v.marketplace_product_id
   and h.marketplace_sku_id = v.marketplace_sku_id
),
filtered as (
  select *
  from joined_rows r
  where (
      nullif(trim(coalesce(p_search, '')), '') is null
      or lower(coalesce(r.marketplace_product_name, '')) like '%' || lower(trim(p_search)) || '%'
      or lower(coalesce(r.marketplace_variant_name, '')) like '%' || lower(trim(p_search)) || '%'
      or lower(coalesce(r.marketplace_sku_id, '')) like '%' || lower(trim(p_search)) || '%'
      or lower(coalesce(r.marketplace_seller_sku, '')) like '%' || lower(trim(p_search)) || '%'
      or lower(coalesce(r.local_sku, '')) like '%' || lower(trim(p_search)) || '%'
    )
    and (
      coalesce(p_missing_only, false) = false
      or r.hpp_mapping_id is null
      or r.hpp_amount is null
    )
),
paged as (
  select *
  from filtered
  order by marketplace_product_name nulls last, marketplace_variant_name nulls last, marketplace_sku_id
  limit greatest(coalesce(p_page_size, 20), 1)
  offset (greatest(coalesce(p_page, 1), 1) - 1) * greatest(coalesce(p_page_size, 20), 1)
)
select jsonb_build_object(
  'ok', true,
  'source', 'marketplace_variant_hpp_list_direct_key_20260627',
  'page', greatest(coalesce(p_page, 1), 1),
  'page_size', greatest(coalesce(p_page_size, 20), 1),
  'total', (select count(*) from filtered),
  'rows', coalesce((select jsonb_agg(to_jsonb(paged)) from paged), '[]'::jsonb)
);
$$;

create or replace function public.finance_resolve_variant_mapping_20260625(
  p_tenant_id uuid,
  p_account_id uuid,
  p_marketplace_sku text default null,
  p_seller_sku text default null,
  p_current_local_sku text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_map record;
  v_hpp record;
  v_seller_key text := lower(nullif(trim(coalesce(p_seller_sku, '')), ''));
  v_marketplace_sku text := nullif(trim(coalesce(p_marketplace_sku, '')), '');
begin
  select m.*
    into v_map
  from public.marketplace_sku_maps m
  where m.tenant_id = p_tenant_id
    and (p_account_id is null or m.marketplace_account_id = p_account_id)
    and coalesce(m.status, 'active') = 'active'
    and (
      (v_marketplace_sku is not null and m.marketplace_sku_id = v_marketplace_sku)
      or (
        v_marketplace_sku is null
        and v_seller_key is not null
        and lower(coalesce(m.marketplace_seller_sku, m.remote_seller_sku, '')) = v_seller_key
        and 1 = (
          select count(*)
          from public.marketplace_sku_maps sm
          where sm.tenant_id = p_tenant_id
            and (p_account_id is null or sm.marketplace_account_id = p_account_id)
            and coalesce(sm.status, 'active') = 'active'
            and lower(coalesce(sm.marketplace_seller_sku, sm.remote_seller_sku, '')) = v_seller_key
        )
      )
    )
  order by
    case when v_marketplace_sku is not null and m.marketplace_sku_id = v_marketplace_sku then 1 else 8 end,
    m.updated_at desc nulls last,
    m.created_at desc nulls last,
    m.marketplace_sku_map_id::text
  limit 1;

  select h.*
    into v_hpp
  from public.marketplace_variant_hpp_mappings h
  where h.tenant_id = p_tenant_id
    and (p_account_id is null or h.marketplace_account_id = p_account_id)
    and coalesce(h.is_active, true) = true
    and (
      (
        v_map.marketplace_product_id is not null
        and h.marketplace_product_id = v_map.marketplace_product_id
        and h.marketplace_sku_id = v_map.marketplace_sku_id
      )
      or (
        v_marketplace_sku is not null
        and h.marketplace_sku_id = v_marketplace_sku
      )
      or (
        v_marketplace_sku is null
        and v_seller_key is not null
        and lower(coalesce(h.marketplace_seller_sku, '')) = v_seller_key
        and 1 = (
          select count(*)
          from public.marketplace_variant_hpp_mappings sh
          where sh.tenant_id = p_tenant_id
            and (p_account_id is null or sh.marketplace_account_id = p_account_id)
            and coalesce(sh.is_active, true) = true
            and lower(coalesce(sh.marketplace_seller_sku, '')) = v_seller_key
        )
      )
    )
  order by
    case
      when v_map.marketplace_product_id is not null
       and h.marketplace_product_id = v_map.marketplace_product_id
       and h.marketplace_sku_id = v_map.marketplace_sku_id then 1
      when v_marketplace_sku is not null and h.marketplace_sku_id = v_marketplace_sku then 2
      else 8
    end,
    h.updated_at desc nulls last,
    h.created_at desc nulls last,
    h.mapping_id::text
  limit 1;

  return jsonb_build_object(
    'marketplace_sku_map_id', v_map.marketplace_sku_map_id,
    'hpp_mapping_id', v_hpp.mapping_id,
    'mapping_id', v_hpp.mapping_id,
    'local_product_id', coalesce(v_map.local_product_id, v_map.product_id, v_hpp.local_product_id),
    'local_sku', coalesce(nullif(v_map.local_sku, ''), nullif(v_hpp.local_sku, ''), nullif(p_current_local_sku, '')),
    'local_product_name', coalesce(nullif(v_map.local_product_name, ''), nullif(v_hpp.local_product_name, '')),
    'hpp', coalesce(v_hpp.hpp_amount, v_hpp.hpp_per_item, v_hpp.hpp),
    'hpp_amount', coalesce(v_hpp.hpp_amount, v_hpp.hpp_per_item, v_hpp.hpp),
    'hpp_per_item', coalesce(v_hpp.hpp_per_item, v_hpp.hpp_amount, v_hpp.hpp),
    'target_margin_percent', coalesce(v_hpp.target_margin_percent, v_hpp.target_margin),
    'target_margin', coalesce(v_hpp.target_margin, v_hpp.target_margin_percent),
    'mapping_source',
      case
        when v_map.marketplace_sku_map_id is not null and v_hpp.mapping_id is not null then 'sku_map_hpp'
        when v_map.marketplace_sku_map_id is not null then 'sku_map'
        when v_hpp.mapping_id is not null then 'hpp_mapping'
        when nullif(p_current_local_sku, '') is not null then 'input_local_sku_only'
        else 'unmapped'
      end,
    'source', 'finance_resolve_variant_mapping_direct_key_20260627'
  );
end;
$$;

grant execute on function public.marketplace_sku_mapping_export_snapshot(uuid, uuid) to authenticated, service_role;
grant execute on function public.marketplace_sku_mapping_import_bulk(jsonb, boolean) to authenticated, service_role;
grant execute on function public.marketplace_variant_hpp_upsert_bulk(jsonb) to anon, authenticated, service_role;
grant execute on function public.marketplace_sync_hpp_from_sku_maps(uuid, uuid, boolean, numeric) to authenticated, service_role;
grant execute on function public.marketplace_variant_hpp_list(uuid, text, boolean, integer, integer) to anon, authenticated, service_role;
grant execute on function public.finance_resolve_variant_mapping_20260625(uuid, uuid, text, text, text) to anon, authenticated, service_role;
