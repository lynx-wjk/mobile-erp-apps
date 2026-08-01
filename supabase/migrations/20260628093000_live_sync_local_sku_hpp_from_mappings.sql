-- Migration: Live-sync local_sku to marketplace_order_items on mapping save.
-- HPP is resolved live from marketplace_variant_hpp_mappings at query time.
-- This sync only updates local_sku/mapped_local_sku so SKU filter and display are correct.

-- -------------------------------------------------------
-- Trigger function 1: hpp_mapping -> order_items local_sku sync
-- -------------------------------------------------------
CREATE OR REPLACE FUNCTION public._trg_sync_order_items_from_hpp_mapping()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_local_sku text := nullif(trim(coalesce(new.local_sku, '')), '');
  v_sku_id text := nullif(trim(coalesce(new.marketplace_sku_id, '')), '');
  v_seller_sku text := lower(nullif(trim(coalesce(new.marketplace_seller_sku, '')), ''));
begin
  -- Skip if local_sku unchanged
  if TG_OP = 'UPDATE' and new.local_sku is not distinct from old.local_sku then
    return new;
  end if;

  if v_local_sku is null then
    return new;
  end if;

  if v_sku_id is not null then
    update public.marketplace_order_items oi
    set
      local_sku        = v_local_sku,
      mapped_local_sku = v_local_sku,
      updated_at       = now()
    where oi.tenant_id = new.tenant_id
      and oi.marketplace_account_id = new.marketplace_account_id
      and oi.marketplace_sku_id = v_sku_id
      and oi.local_sku is distinct from v_local_sku;
  elsif v_seller_sku is not null then
    update public.marketplace_order_items oi
    set
      local_sku        = v_local_sku,
      mapped_local_sku = v_local_sku,
      updated_at       = now()
    where oi.tenant_id = new.tenant_id
      and oi.marketplace_account_id = new.marketplace_account_id
      and lower(coalesce(oi.marketplace_seller_sku, oi.seller_sku, '')) = v_seller_sku
      and oi.local_sku is distinct from v_local_sku;
  end if;

  return new;
end;
$function$;

-- -------------------------------------------------------
-- Trigger function 2: sku_maps -> order_items local_sku sync
-- -------------------------------------------------------
CREATE OR REPLACE FUNCTION public._trg_sync_order_items_from_sku_maps()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_local_sku text := nullif(trim(coalesce(new.local_sku, '')), '');
  v_sku_id text := nullif(trim(coalesce(new.marketplace_sku_id, new.remote_sku_id, '')), '');
  v_seller_sku text := lower(nullif(trim(coalesce(new.marketplace_seller_sku, new.remote_seller_sku, '')), ''));
begin
  -- Skip if local_sku unchanged or mapping inactive
  if TG_OP = 'UPDATE' and new.local_sku is not distinct from old.local_sku then
    return new;
  end if;
  if coalesce(new.status,'active') not in ('active','') then
    return new;
  end if;
  if v_local_sku is null then
    return new;
  end if;

  if v_sku_id is not null then
    update public.marketplace_order_items oi
    set
      local_sku        = v_local_sku,
      mapped_local_sku = v_local_sku,
      updated_at       = now()
    where oi.tenant_id = new.tenant_id
      and oi.marketplace_account_id = new.marketplace_account_id
      and oi.marketplace_sku_id = v_sku_id
      and oi.local_sku is distinct from v_local_sku;
  elsif v_seller_sku is not null then
    update public.marketplace_order_items oi
    set
      local_sku        = v_local_sku,
      mapped_local_sku = v_local_sku,
      updated_at       = now()
    where oi.tenant_id = new.tenant_id
      and oi.marketplace_account_id = new.marketplace_account_id
      and lower(coalesce(oi.marketplace_seller_sku, oi.seller_sku, '')) = v_seller_sku
      and oi.local_sku is distinct from v_local_sku;
  end if;

  return new;
end;
$function$;

-- -------------------------------------------------------
-- Attach triggers
-- -------------------------------------------------------
DROP TRIGGER IF EXISTS trg_sync_order_items_from_hpp_mapping
  ON public.marketplace_variant_hpp_mappings;
CREATE TRIGGER trg_sync_order_items_from_hpp_mapping
  AFTER INSERT OR UPDATE ON public.marketplace_variant_hpp_mappings
  FOR EACH ROW
  EXECUTE FUNCTION public._trg_sync_order_items_from_hpp_mapping();

DROP TRIGGER IF EXISTS trg_sync_order_items_from_sku_maps
  ON public.marketplace_sku_maps;
CREATE TRIGGER trg_sync_order_items_from_sku_maps
  AFTER INSERT OR UPDATE ON public.marketplace_sku_maps
  FOR EACH ROW
  EXECUTE FUNCTION public._trg_sync_order_items_from_sku_maps();

-- -------------------------------------------------------
-- RPC: on-demand backfill — call once from SKU mapping page on load
-- -------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_order_items_local_sku_from_mappings(
  p_marketplace_account_id uuid DEFAULT NULL::uuid,
  p_marketplace_sku_id text DEFAULT NULL::text
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '30s'
AS $function$
declare
  v_tenant_id uuid := public.app_current_tenant_id_or_default();
  v_updated_hpp integer := 0;
  v_updated_map integer := 0;
begin
  -- Sync from marketplace_variant_hpp_mappings (local_sku only)
  with mappings as (
    select distinct on (m.tenant_id, m.marketplace_account_id, m.marketplace_sku_id)
      m.tenant_id,
      m.marketplace_account_id,
      m.marketplace_sku_id,
      nullif(trim(coalesce(m.local_sku,'')), '') as local_sku
    from public.marketplace_variant_hpp_mappings m
    where m.tenant_id = v_tenant_id
      and (p_marketplace_account_id is null or m.marketplace_account_id = p_marketplace_account_id)
      and (p_marketplace_sku_id is null or m.marketplace_sku_id = p_marketplace_sku_id)
      and coalesce(m.is_active, true) = true
      and nullif(trim(coalesce(m.local_sku,'')), '') is not null
    order by m.tenant_id, m.marketplace_account_id, m.marketplace_sku_id, m.updated_at desc nulls last
  )
  update public.marketplace_order_items oi
  set
    local_sku        = m.local_sku,
    mapped_local_sku = m.local_sku,
    updated_at       = now()
  from mappings m
  where oi.tenant_id = m.tenant_id
    and oi.marketplace_account_id = m.marketplace_account_id
    and oi.marketplace_sku_id = m.marketplace_sku_id
    and oi.local_sku is distinct from m.local_sku;

  get diagnostics v_updated_hpp = ROW_COUNT;

  -- Sync from marketplace_sku_maps (authoritative product mapping)
  with skumaps as (
    select distinct on (sm.tenant_id, sm.marketplace_account_id, coalesce(sm.marketplace_sku_id, sm.remote_sku_id))
      sm.tenant_id,
      sm.marketplace_account_id,
      coalesce(sm.marketplace_sku_id, sm.remote_sku_id) as marketplace_sku_id,
      nullif(trim(coalesce(sm.local_sku,'')), '') as local_sku
    from public.marketplace_sku_maps sm
    where sm.tenant_id = v_tenant_id
      and (p_marketplace_account_id is null or sm.marketplace_account_id = p_marketplace_account_id)
      and coalesce(sm.status, 'active') = 'active'
      and nullif(trim(coalesce(sm.local_sku,'')), '') is not null
    order by sm.tenant_id, sm.marketplace_account_id, coalesce(sm.marketplace_sku_id, sm.remote_sku_id),
             sm.updated_at desc nulls last
  )
  update public.marketplace_order_items oi
  set
    local_sku        = s.local_sku,
    mapped_local_sku = s.local_sku,
    updated_at       = now()
  from skumaps s
  where oi.tenant_id = s.tenant_id
    and oi.marketplace_account_id = s.marketplace_account_id
    and oi.marketplace_sku_id = s.marketplace_sku_id
    and oi.local_sku is distinct from s.local_sku;

  get diagnostics v_updated_map = ROW_COUNT;

  return jsonb_build_object(
    'ok', true,
    'updated_from_hpp_mapping', v_updated_hpp,
    'updated_from_sku_maps', v_updated_map,
    'total_updated', v_updated_hpp + v_updated_map
  );
end;
$function$;
