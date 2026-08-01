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
  v_matched integer := 0;
  v_ambiguous_seller_skipped integer := 0;
  v_unmatched integer := 0;
begin
  if p_tenant_id is null then
    return jsonb_build_object(
      'ok', false,
      'message', 'tenant_id kosong.',
      'updated', 0,
      'matched', 0,
      'ambiguous_seller_skipped', 0,
      'unmatched', 0,
      'source', 'marketplace_apply_sku_maps_to_order_items_safe_unique_seller_20260627'
    );
  end if;

  with candidate_items as (
    select
      i.marketplace_order_item_id,
      i.tenant_id,
      i.marketplace_account_id,
      to_jsonb(i) as ij,
      to_jsonb(o) as oj
    from public.marketplace_order_items i
    join public.marketplace_orders o
      on o.marketplace_order_id = i.marketplace_order_id
     and o.tenant_id = i.tenant_id
    where i.tenant_id = p_tenant_id
      and (
        p_marketplace_account_id is null
        or i.marketplace_account_id = p_marketplace_account_id
      )
      and coalesce(o.order_created_at, o.created_at, i.created_at)
          >= now() - make_interval(days => greatest(coalesce(p_days_back, 90), 1))
  ),
  item_keys as (
    select
      ci.*,
      lower(nullif(trim(coalesce(ci.oj->>'marketplace', ci.ij->>'marketplace', '')), '')) as item_marketplace,
      nullif(trim(ci.ij->>'marketplace_product_id'), '') as direct_product_id,
      nullif(trim(coalesce(
        ci.ij->>'marketplace_sku_id',
        ci.ij->>'sku_id'
      )), '') as direct_sku_id,
      nullif(trim(ci.ij->>'remote_sku_id'), '') as direct_remote_sku_id,
      nullif(trim(ci.ij->>'marketplace_sku'), '') as direct_marketplace_sku,
      nullif(trim(coalesce(
        ci.ij#>>'{raw_item,product_id}',
        ci.ij#>>'{raw_data,product_id}',
        ci.ij#>>'{raw_item,product_id_str}',
        ci.ij#>>'{raw_data,product_id_str}',
        ci.ij#>>'{raw_item,item_id}',
        ci.ij#>>'{raw_data,item_id}',
        ci.ij#>>'{raw_item,product,id}',
        ci.ij#>>'{raw_data,product,id}',
        ci.ij#>>'{raw_item,sku,product_id}',
        ci.ij#>>'{raw_data,sku,product_id}'
      )), '') as raw_product_id,
      nullif(trim(coalesce(
        ci.ij#>>'{raw_item,sku_id}',
        ci.ij#>>'{raw_data,sku_id}',
        ci.ij#>>'{raw_item,sku_id_str}',
        ci.ij#>>'{raw_data,sku_id_str}',
        ci.ij#>>'{raw_item,model_id}',
        ci.ij#>>'{raw_data,model_id}',
        ci.ij#>>'{raw_item,model_id_str}',
        ci.ij#>>'{raw_data,model_id_str}',
        ci.ij#>>'{raw_item,sku,id}',
        ci.ij#>>'{raw_data,sku,id}',
        ci.ij#>>'{raw_item,skus,0,sku_id}',
        ci.ij#>>'{raw_data,skus,0,sku_id}',
        ci.ij#>>'{raw_item,sku_list,0,sku_id}',
        ci.ij#>>'{raw_data,sku_list,0,sku_id}',
        ci.ij#>>'{raw_item,package_list,0,sku_id}',
        ci.ij#>>'{raw_data,package_list,0,sku_id}'
      )), '') as raw_sku_id,
      nullif(trim(coalesce(
        ci.ij->>'marketplace_variant_snapshot_id',
        ci.ij#>>'{raw_item,marketplace_variant_snapshot_id}',
        ci.ij#>>'{raw_data,marketplace_variant_snapshot_id}',
        ci.ij#>>'{raw_item,variant_snapshot_id}',
        ci.ij#>>'{raw_data,variant_snapshot_id}'
      )), '') as item_variant_snapshot_id,
      nullif(trim(coalesce(
        ci.ij->>'marketplace_seller_sku',
        ci.ij->>'seller_sku',
        ci.ij->>'remote_seller_sku',
        ci.ij#>>'{raw_item,seller_sku}',
        ci.ij#>>'{raw_data,seller_sku}',
        ci.ij#>>'{raw_item,sellerSku}',
        ci.ij#>>'{raw_data,sellerSku}',
        ci.ij#>>'{raw_item,model_sku}',
        ci.ij#>>'{raw_data,model_sku}'
      )), '') as item_seller_sku
    from candidate_items ci
  ),
  active_maps as (
    select
      m.*,
      lower(trim(coalesce(m.marketplace, ''))) as map_marketplace,
      lower(trim(coalesce(m.marketplace_seller_sku, m.remote_seller_sku, ''))) as seller_key,
      nullif(trim(m.marketplace_product_id), '') as map_product_id,
      nullif(trim(m.marketplace_sku_id), '') as map_sku_id,
      nullif(trim(m.remote_sku_id), '') as map_remote_sku_id,
      case
        when nullif(trim(coalesce(m.marketplace_sku, '')), '') is null then null
        when lower(trim(coalesce(m.marketplace_sku, ''))) =
             lower(trim(coalesce(m.marketplace_seller_sku, m.remote_seller_sku, ''))) then null
        else nullif(trim(m.marketplace_sku), '')
      end as map_marketplace_sku,
      nullif(trim(m.marketplace_variant_snapshot_id::text), '') as map_variant_snapshot_id
    from public.marketplace_sku_maps m
    where m.tenant_id = p_tenant_id
      and (
        p_marketplace_account_id is null
        or m.marketplace_account_id = p_marketplace_account_id
      )
      and coalesce(m.status, 'active') = 'active'
      and coalesce(m.local_sku, '') <> ''
      and coalesce(m.local_product_id, m.product_id) is not null
  ),
  seller_map_counts as (
    select
      tenant_id,
      marketplace_account_id,
      map_marketplace,
      seller_key,
      count(*) as map_count,
      (array_agg(
        marketplace_sku_map_id
        order by updated_at desc nulls last,
                 created_at desc nulls last,
                 marketplace_sku_map_id::text
      ))[1] as marketplace_sku_map_id
    from active_maps
    where seller_key is not null
      and seller_key <> ''
    group by tenant_id, marketplace_account_id, map_marketplace, seller_key
  ),
  best_map as (
    select distinct on (ik.marketplace_order_item_id)
      ik.marketplace_order_item_id,
      m.marketplace_sku_map_id,
      coalesce(m.local_product_id, m.product_id) as mapped_product_id,
      m.local_sku,
      case
        when m.map_product_id is not null
         and m.map_product_id = ik.direct_product_id
         and m.map_sku_id = ik.direct_sku_id
          then 1
        when ik.direct_sku_id is not null
         and m.map_sku_id = ik.direct_sku_id
          then 2
        when (
              m.map_product_id is not null
          and m.map_product_id = ik.raw_product_id
          and (
               m.map_sku_id = ik.raw_sku_id
            or m.map_remote_sku_id = ik.raw_sku_id
            or m.map_marketplace_sku = ik.raw_sku_id
            or m.map_remote_sku_id = ik.direct_remote_sku_id
            or m.map_marketplace_sku = ik.direct_marketplace_sku
          )
        )
          or (
              ik.raw_sku_id is not null
          and (
               m.map_sku_id = ik.raw_sku_id
            or m.map_remote_sku_id = ik.raw_sku_id
            or m.map_marketplace_sku = ik.raw_sku_id
          )
        )
          or (
              ik.direct_remote_sku_id is not null
          and m.map_remote_sku_id = ik.direct_remote_sku_id
        )
          or (
              ik.direct_marketplace_sku is not null
          and m.map_marketplace_sku = ik.direct_marketplace_sku
        )
          or (
              ik.item_variant_snapshot_id is not null
          and m.map_variant_snapshot_id = ik.item_variant_snapshot_id
        )
          then 3
        when coalesce(
               ik.direct_sku_id,
               ik.direct_remote_sku_id,
               ik.direct_marketplace_sku,
               ik.raw_sku_id,
               ik.direct_product_id,
               ik.raw_product_id
             ) is null
         and smc.map_count = 1
          then 8
        else 99
      end as match_rank,
      m.updated_at,
      m.created_at
    from item_keys ik
    join active_maps m
      on m.tenant_id = ik.tenant_id
     and m.marketplace_account_id = ik.marketplace_account_id
     and (
          ik.item_marketplace is null
          or ik.item_marketplace = ''
          or m.map_marketplace = ik.item_marketplace
     )
    left join seller_map_counts smc
      on smc.tenant_id = ik.tenant_id
     and smc.marketplace_account_id = ik.marketplace_account_id
     and smc.map_marketplace = m.map_marketplace
     and smc.seller_key = lower(trim(coalesce(ik.item_seller_sku, '')))
     and smc.marketplace_sku_map_id = m.marketplace_sku_map_id
    where
      (
        m.map_product_id is not null
        and m.map_product_id = ik.direct_product_id
        and m.map_sku_id = ik.direct_sku_id
      )
      or (
        ik.direct_sku_id is not null
        and m.map_sku_id = ik.direct_sku_id
      )
      or (
        m.map_product_id is not null
        and m.map_product_id = ik.raw_product_id
        and (
             m.map_sku_id = ik.raw_sku_id
          or m.map_remote_sku_id = ik.raw_sku_id
          or m.map_marketplace_sku = ik.raw_sku_id
          or m.map_remote_sku_id = ik.direct_remote_sku_id
          or m.map_marketplace_sku = ik.direct_marketplace_sku
        )
      )
      or (
        ik.raw_sku_id is not null
        and (
             m.map_sku_id = ik.raw_sku_id
          or m.map_remote_sku_id = ik.raw_sku_id
          or m.map_marketplace_sku = ik.raw_sku_id
        )
      )
      or (
        ik.direct_remote_sku_id is not null
        and m.map_remote_sku_id = ik.direct_remote_sku_id
      )
      or (
        ik.direct_marketplace_sku is not null
        and m.map_marketplace_sku = ik.direct_marketplace_sku
      )
      or (
        ik.item_variant_snapshot_id is not null
        and m.map_variant_snapshot_id = ik.item_variant_snapshot_id
      )
      or (
        coalesce(
          ik.direct_sku_id,
          ik.direct_remote_sku_id,
          ik.direct_marketplace_sku,
          ik.raw_sku_id,
          ik.direct_product_id,
          ik.raw_product_id
        ) is null
        and smc.map_count = 1
      )
    order by
      ik.marketplace_order_item_id,
      match_rank,
      m.updated_at desc nulls last,
      m.created_at desc nulls last,
      m.marketplace_sku_map_id::text
  ),
  ambiguous_seller_items as (
    select distinct ik.marketplace_order_item_id
    from item_keys ik
    join seller_map_counts smc
      on smc.tenant_id = ik.tenant_id
     and smc.marketplace_account_id = ik.marketplace_account_id
     and (
          ik.item_marketplace is null
          or ik.item_marketplace = ''
          or smc.map_marketplace = ik.item_marketplace
     )
     and smc.seller_key = lower(trim(coalesce(ik.item_seller_sku, '')))
    left join best_map bm
      on bm.marketplace_order_item_id = ik.marketplace_order_item_id
     and bm.match_rank < 99
    where smc.map_count > 1
      and bm.marketplace_order_item_id is null
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
       and bm.match_rank < 99
       and (
            i.marketplace_sku_map_id is distinct from bm.marketplace_sku_map_id
         or i.product_id is distinct from bm.mapped_product_id
         or i.local_product_id is distinct from bm.mapped_product_id
         or i.mapped_product_id is distinct from bm.mapped_product_id
         or coalesce(i.mapped_local_sku, '') is distinct from coalesce(bm.local_sku, '')
         or coalesce(i.mapping_status, '') <> 'mapped'
       )
     returning 1
  ),
  counts as (
    select
      (select count(*) from updated) as updated,
      (select count(*) from best_map where match_rank < 99) as matched,
      (select count(*) from ambiguous_seller_items) as ambiguous_seller_skipped,
      greatest(
        (select count(*) from candidate_items)
        - (select count(*) from best_map where match_rank < 99),
        0
      ) as unmatched
  )
  select
    updated,
    matched,
    ambiguous_seller_skipped,
    unmatched
  into
    v_updated,
    v_matched,
    v_ambiguous_seller_skipped,
    v_unmatched
  from counts;

  return jsonb_build_object(
    'ok', true,
    'source', 'marketplace_apply_sku_maps_to_order_items_safe_unique_seller_20260627',
    'updated', coalesce(v_updated, 0),
    'matched', coalesce(v_matched, 0),
    'ambiguous_seller_skipped', coalesce(v_ambiguous_seller_skipped, 0),
    'unmatched', coalesce(v_unmatched, 0),
    'days_back', greatest(coalesce(p_days_back, 90), 1),
    'tenant_id', p_tenant_id,
    'marketplace_account_id', p_marketplace_account_id,
    'message', format(
      '%s order item mapping cache updated. %s matched, %s ambiguous seller SKU skipped, %s unmatched.',
      coalesce(v_updated, 0),
      coalesce(v_matched, 0),
      coalesce(v_ambiguous_seller_skipped, 0),
      coalesce(v_unmatched, 0)
    )
  );
end;
$$;

grant execute on function public.marketplace_apply_sku_maps_to_order_items(uuid, uuid, integer) to authenticated;
grant execute on function public.marketplace_apply_sku_maps_to_order_items(uuid, uuid, integer) to service_role;
