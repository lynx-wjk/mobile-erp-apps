-- Fix PL/pgSQL ROW_COUNT syntax error and timeout in marketplace_apply_sku_maps_to_order_items
CREATE OR REPLACE FUNCTION public.marketplace_apply_sku_maps_to_order_items(
  p_tenant_id uuid,
  p_marketplace_account_id uuid DEFAULT NULL::uuid,
  p_days_back integer DEFAULT 90
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
SET statement_timeout TO '120s'
AS $function$
declare
  v_updated_sku integer := 0;
  v_updated_seller integer := 0;
  v_total_updated integer := 0;
  v_days integer := coalesce(p_days_back, 90);
begin
  if p_tenant_id is null then
    return jsonb_build_object(
      'ok', false,
      'message', 'tenant_id kosong.',
      'updated', 0,
      'source', 'marketplace_apply_sku_maps_to_order_items_v2'
    );
  end if;

  -- 1. Apply by exact marketplace_sku_id match
  with maps as (
    select distinct on (tenant_id, marketplace_account_id, coalesce(marketplace_sku_id, remote_sku_id))
      tenant_id,
      marketplace_account_id,
      coalesce(marketplace_sku_id, remote_sku_id) as sku_id,
      nullif(trim(local_sku), '') as local_sku
    from public.marketplace_sku_maps
    where tenant_id = p_tenant_id
      and (p_marketplace_account_id is null or marketplace_account_id = p_marketplace_account_id)
      and coalesce(status, 'active') = 'active'
      and nullif(trim(local_sku), '') is not null
      and coalesce(marketplace_sku_id, remote_sku_id) is not null
    order by tenant_id, marketplace_account_id, coalesce(marketplace_sku_id, remote_sku_id), updated_at desc nulls last
  )
  update public.marketplace_order_items oi
  set
    local_sku = m.local_sku,
    mapped_local_sku = m.local_sku,
    updated_at = now()
  from maps m
  where oi.tenant_id = m.tenant_id
    and oi.marketplace_account_id = m.marketplace_account_id
    and oi.marketplace_sku_id = m.sku_id
    and oi.local_sku is distinct from m.local_sku
    and oi.created_at >= now() - (v_days || ' days')::interval;

  GET DIAGNOSTICS v_updated_sku = ROW_COUNT;

  -- 2. Apply by seller_sku for those still unmapped
  with seller_maps as (
    select tenant_id, marketplace_account_id, lower(trim(coalesce(marketplace_seller_sku, remote_seller_sku))) as seller_sku,
           min(nullif(trim(local_sku), '')) as local_sku
    from public.marketplace_sku_maps
    where tenant_id = p_tenant_id
      and (p_marketplace_account_id is null or marketplace_account_id = p_marketplace_account_id)
      and coalesce(status, 'active') = 'active'
      and nullif(trim(local_sku), '') is not null
      and nullif(trim(coalesce(marketplace_seller_sku, remote_seller_sku)), '') is not null
    group by tenant_id, marketplace_account_id, lower(trim(coalesce(marketplace_seller_sku, remote_seller_sku)))
    having count(distinct nullif(trim(local_sku), '')) = 1
  )
  update public.marketplace_order_items oi
  set
    local_sku = sm.local_sku,
    mapped_local_sku = sm.local_sku,
    updated_at = now()
  from seller_maps sm
  where oi.tenant_id = sm.tenant_id
    and oi.marketplace_account_id = sm.marketplace_account_id
    and lower(trim(coalesce(oi.marketplace_seller_sku, oi.seller_sku))) = sm.seller_sku
    and oi.local_sku is null
    and oi.created_at >= now() - (v_days || ' days')::interval;

  GET DIAGNOSTICS v_updated_seller = ROW_COUNT;

  v_total_updated := v_updated_sku + v_updated_seller;

  return jsonb_build_object(
    'ok', true,
    'message', 'Berhasil memperbarui pemetaan SKU pada pesanan.',
    'updated', v_total_updated,
    'source', 'marketplace_apply_sku_maps_to_order_items_v2'
  );
end;
$function$;
