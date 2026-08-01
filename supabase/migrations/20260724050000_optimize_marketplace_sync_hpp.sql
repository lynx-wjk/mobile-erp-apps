-- Replace slow row-by-row cursor loop in marketplace_sync_hpp_from_sku_maps with set-based bulk ON CONFLICT upsert to eliminate lock contention (55P03) and statement timeouts (57014)
CREATE OR REPLACE FUNCTION public.marketplace_sync_hpp_from_sku_maps(
  p_tenant_id uuid,
  p_marketplace_account_id uuid DEFAULT NULL::uuid,
  p_overwrite boolean DEFAULT false,
  p_default_target_margin numeric DEFAULT 30
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
SET statement_timeout TO '60s'
AS $function$
declare
  v_inserted int := 0;
  v_updated int := 0;
begin
  with active_maps as (
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
      coalesce(p.target_margin_percent, p_default_target_margin, 30) as product_target_margin,
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
      m.updated_at desc nulls last
  ),
  upserted as (
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
    )
    select
      gen_random_uuid(),
      gen_random_uuid(),
      gen_random_uuid(),
      m.tenant_id,
      m.marketplace_account_id,
      m.marketplace,
      m.marketplace_product_id,
      m.marketplace_sku_id,
      m.marketplace_seller_sku,
      m.marketplace_product_name,
      m.marketplace_variant_name,
      m.local_product_id,
      m.local_product_name,
      m.local_sku,
      m.product_hpp,
      m.product_hpp,
      m.product_hpp,
      m.product_target_margin,
      m.product_target_margin,
      m.marketplace_sku_map_id,
      true,
      'sync_from_sku_maps',
      auth.uid(),
      now(),
      now()
    from active_maps m
    on conflict (tenant_id, marketplace_account_id, marketplace, marketplace_product_id, marketplace_sku_id) WHERE COALESCE(is_active, true) = true AND marketplace_product_id IS NOT NULL AND marketplace_sku_id IS NOT NULL
    do update set
      marketplace_seller_sku = coalesce(excluded.marketplace_seller_sku, marketplace_variant_hpp_mappings.marketplace_seller_sku),
      marketplace_product_name = coalesce(excluded.marketplace_product_name, marketplace_variant_hpp_mappings.marketplace_product_name),
      marketplace_variant_name = coalesce(excluded.marketplace_variant_name, marketplace_variant_hpp_mappings.marketplace_variant_name),
      local_product_id = coalesce(excluded.local_product_id, marketplace_variant_hpp_mappings.local_product_id),
      local_product_name = coalesce(excluded.local_product_name, marketplace_variant_hpp_mappings.local_product_name),
      local_sku = coalesce(excluded.local_sku, marketplace_variant_hpp_mappings.local_sku),
      hpp = case when p_overwrite then excluded.hpp else marketplace_variant_hpp_mappings.hpp end,
      hpp_amount = case when p_overwrite then excluded.hpp_amount else coalesce(marketplace_variant_hpp_mappings.hpp_amount, marketplace_variant_hpp_mappings.hpp) end,
      hpp_per_item = case when p_overwrite then excluded.hpp_per_item else coalesce(marketplace_variant_hpp_mappings.hpp_per_item, marketplace_variant_hpp_mappings.hpp_amount, marketplace_variant_hpp_mappings.hpp) end,
      target_margin = case when p_overwrite then excluded.target_margin else coalesce(marketplace_variant_hpp_mappings.target_margin, marketplace_variant_hpp_mappings.target_margin_percent) end,
      target_margin_percent = case when p_overwrite then excluded.target_margin_percent else coalesce(marketplace_variant_hpp_mappings.target_margin_percent, marketplace_variant_hpp_mappings.target_margin) end,
      marketplace_sku_map_id = excluded.marketplace_sku_map_id,
      is_active = true,
      source = case when p_overwrite then 'sync_from_sku_maps' else coalesce(marketplace_variant_hpp_mappings.source, 'sync_from_sku_maps') end,
      updated_by = auth.uid(),
      updated_at = now()
    returning (xmax = 0) as is_insert
  )
  select
    count(*) filter (where is_insert) as inserted,
    count(*) filter (where not is_insert) as updated
  into v_inserted, v_updated
  from upserted;

  return jsonb_build_object(
    'ok', true,
    'source', 'marketplace_sync_hpp_from_sku_maps_bulk_v2026',
    'inserted', coalesce(v_inserted, 0),
    'updated', coalesce(v_updated, 0),
    'upserted', coalesce(v_inserted, 0) + coalesce(v_updated, 0),
    'overwrite', p_overwrite,
    'message', format('%s HPP mapping disinkronkan dari SKU mapping.', coalesce(v_inserted, 0) + coalesce(v_updated, 0))
  );
end;
$function$;
