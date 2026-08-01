create or replace function public.marketplace_apply_sku_maps_to_order_items(
  p_tenant_id uuid,
  p_marketplace_account_id uuid default null,
  p_days_back integer default 90
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated integer := 0;
begin
  if p_tenant_id is null then
    return jsonb_build_object(
      'ok', false,
      'message', 'tenant_id kosong.',
      'updated', 0
    );
  end if;

  with candidate_items as (
    select
      i.marketplace_order_item_id,
      i.tenant_id,
      i.marketplace_account_id,
      i.marketplace_order_id,
      to_jsonb(i) as ij,
      to_jsonb(o) as oj
    from public.marketplace_order_items i
    join public.marketplace_orders o
      on o.marketplace_order_id = i.marketplace_order_id
     and o.tenant_id = i.tenant_id
    where i.tenant_id = p_tenant_id
      and (p_marketplace_account_id is null or i.marketplace_account_id = p_marketplace_account_id)
      and coalesce(o.order_created_at, o.created_at, i.created_at) >= now() - make_interval(days => greatest(coalesce(p_days_back, 90), 1))
  ),
  item_keys as (
    select
      ci.*,
      lower(coalesce(ci.oj->>'marketplace', ci.ij->>'marketplace', '')) as item_marketplace,
      nullif(coalesce(
        ci.ij->>'marketplace_product_id',
        ci.ij#>>'{raw_item,product_id}',
        ci.ij#>>'{raw_data,product_id}',
        ci.ij#>>'{raw_item,product_id_str}',
        ci.ij#>>'{raw_data,product_id_str}'
      ), '') as item_product_id,
      nullif(coalesce(
        ci.ij->>'marketplace_sku_id',
        ci.ij->>'sku_id',
        ci.ij->>'remote_sku_id',
        ci.ij->>'marketplace_sku',
        ci.ij#>>'{raw_item,sku_id}',
        ci.ij#>>'{raw_data,sku_id}',
        ci.ij#>>'{raw_item,sku_id_str}',
        ci.ij#>>'{raw_data,sku_id_str}'
      ), '') as item_sku_id,
      nullif(coalesce(
        ci.ij->>'marketplace_seller_sku',
        ci.ij->>'seller_sku',
        ci.ij->>'remote_seller_sku',
        ci.ij#>>'{raw_item,seller_sku}',
        ci.ij#>>'{raw_data,seller_sku}',
        ci.ij#>>'{raw_item,sellerSku}',
        ci.ij#>>'{raw_data,sellerSku}'
      ), '') as item_seller_sku
    from candidate_items ci
  ),
  best_map as (
    select distinct on (ik.marketplace_order_item_id)
      ik.marketplace_order_item_id,
      m.marketplace_sku_map_id,
      coalesce(m.local_product_id, m.product_id) as mapped_product_id,
      m.local_sku,
      m.local_product_name,
      case
        when coalesce(m.marketplace_product_id, '') <> ''
         and coalesce(m.marketplace_sku_id, '') <> ''
         and coalesce(m.marketplace_product_id, '') = coalesce(ik.item_product_id, '')
         and coalesce(m.marketplace_sku_id, '') = coalesce(ik.item_sku_id, '')
          then 1
        when coalesce(m.marketplace_sku_id, '') <> ''
         and coalesce(m.marketplace_sku_id, '') = coalesce(ik.item_sku_id, '')
          then 2
        when coalesce(m.marketplace_seller_sku, '') <> ''
         and lower(coalesce(m.marketplace_seller_sku, '')) = lower(coalesce(ik.item_seller_sku, ''))
          then 3
        else 9
      end as match_rank,
      m.updated_at
    from item_keys ik
    join public.marketplace_sku_maps m
      on m.tenant_id = ik.tenant_id
     and m.marketplace_account_id = ik.marketplace_account_id
     and coalesce(m.status, 'active') <> 'deleted'
     and coalesce(m.local_sku, '') <> ''
     and coalesce(m.local_product_id, m.product_id) is not null
     and (
          (
            coalesce(m.marketplace_product_id, '') <> ''
            and coalesce(m.marketplace_sku_id, '') <> ''
            and coalesce(m.marketplace_product_id, '') = coalesce(ik.item_product_id, '')
            and coalesce(m.marketplace_sku_id, '') = coalesce(ik.item_sku_id, '')
          )
          or (
            coalesce(m.marketplace_sku_id, '') <> ''
            and coalesce(m.marketplace_sku_id, '') = coalesce(ik.item_sku_id, '')
          )
          or (
            coalesce(m.marketplace_seller_sku, '') <> ''
            and lower(coalesce(m.marketplace_seller_sku, '')) = lower(coalesce(ik.item_seller_sku, ''))
          )
     )
    order by
      ik.marketplace_order_item_id,
      match_rank,
      m.updated_at desc nulls last,
      m.created_at desc nulls last
  ),
  updated as (
    update public.marketplace_order_items i
       set marketplace_sku_map_id = bm.marketplace_sku_map_id,
           product_id = bm.mapped_product_id,
           local_product_id = bm.mapped_product_id,
           mapped_product_id = bm.mapped_product_id,
           mapped_local_sku = bm.local_sku,
           mapping_status = 'mapped',
           updated_at = now()
      from best_map bm
     where i.marketplace_order_item_id = bm.marketplace_order_item_id
       and bm.match_rank < 9
       and (
            i.marketplace_sku_map_id is distinct from bm.marketplace_sku_map_id
         or i.product_id is distinct from bm.mapped_product_id
         or i.local_product_id is distinct from bm.mapped_product_id
         or i.mapped_product_id is distinct from bm.mapped_product_id
         or coalesce(i.mapped_local_sku, '') is distinct from coalesce(bm.local_sku, '')
         or coalesce(i.mapping_status, '') <> 'mapped'
       )
     returning 1
  )
  select count(*) into v_updated from updated;

  return jsonb_build_object(
    'ok', true,
    'source', 'marketplace_apply_sku_maps_to_order_items_cache_20260627',
    'tenant_id', p_tenant_id,
    'marketplace_account_id', p_marketplace_account_id,
    'days_back', greatest(coalesce(p_days_back, 90), 1),
    'updated', v_updated,
    'message', format('%s order item mapping cache updated.', v_updated)
  );
end;
$$;

grant execute on function public.marketplace_apply_sku_maps_to_order_items(uuid, uuid, integer) to authenticated;
grant execute on function public.marketplace_apply_sku_maps_to_order_items(uuid, uuid, integer) to service_role;
