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
  v_sku_map jsonb := '{}'::jsonb;
  v_hpp_map jsonb := '{}'::jsonb;

  v_marketplace_sku text := lower(nullif(trim(coalesce(p_marketplace_sku,'')), ''));
  v_seller_sku text := lower(nullif(trim(coalesce(p_seller_sku,'')), ''));
  v_current_local_sku text := lower(nullif(trim(coalesce(p_current_local_sku,'')), ''));

  v_resolved_local_sku text;
  v_mapping_id text;
  v_mapping_source text;
  v_hpp numeric := 0;
  v_target_margin numeric := 0;
begin
  /*
    1) Resolve local SKU dari marketplace_sku_maps.
    Ini tabel mapping SKU utama UI.
  */
  select to_jsonb(m)
    into v_sku_map
  from public.marketplace_sku_maps m
  where m.tenant_id = p_tenant_id
    and (p_account_id is null or m.marketplace_account_id = p_account_id)
    and lower(coalesce(m.status,'active')) not in ('deleted','archived','inactive','disabled')
    and (
      lower(coalesce(m.marketplace_sku_id,'')) = coalesce(v_marketplace_sku,'')
      or lower(coalesce(m.marketplace_sku,'')) = coalesce(v_marketplace_sku,'')
      or lower(coalesce(m.remote_sku_id,'')) = coalesce(v_marketplace_sku,'')
      or lower(coalesce(m.marketplace_seller_sku,'')) = coalesce(v_seller_sku,'')
      or lower(coalesce(m.remote_seller_sku,'')) = coalesce(v_seller_sku,'')
      or lower(coalesce(m.local_sku,'')) = coalesce(v_current_local_sku,'')
    )
  order by
    case
      when lower(coalesce(m.marketplace_sku_id,'')) = coalesce(v_marketplace_sku,'') then 1
      when lower(coalesce(m.marketplace_sku,'')) = coalesce(v_marketplace_sku,'') then 2
      when lower(coalesce(m.remote_sku_id,'')) = coalesce(v_marketplace_sku,'') then 3
      when lower(coalesce(m.marketplace_seller_sku,'')) = coalesce(v_seller_sku,'') then 4
      when lower(coalesce(m.remote_seller_sku,'')) = coalesce(v_seller_sku,'') then 5
      when lower(coalesce(m.local_sku,'')) = coalesce(v_current_local_sku,'') then 9
      else 99
    end,
    coalesce(m.updated_at, m.created_at, now()) desc
  limit 1;

  v_resolved_local_sku := coalesce(
    nullif(v_sku_map->>'local_sku',''),
    nullif(v_sku_map->>'mapped_local_sku',''),
    nullif(v_sku_map->>'local_product_sku',''),
    nullif(p_current_local_sku,'')
  );

  v_mapping_id := coalesce(
    nullif(v_sku_map->>'marketplace_sku_map_id',''),
    nullif(v_sku_map->>'map_id','')
  );

  if v_mapping_id is not null then
    v_mapping_source := 'marketplace_sku_maps';
  end if;

  /*
    2) Resolve HPP dari marketplace_variant_hpp_mappings.
    Cocokkan ke sku_map_id jika ada, lalu marketplace_sku_id/seller_sku/local_sku.
  */
  select to_jsonb(h)
    into v_hpp_map
  from public.marketplace_variant_hpp_mappings h
  where h.tenant_id = p_tenant_id
    and (p_account_id is null or h.marketplace_account_id = p_account_id)
    and coalesce(h.is_active, true) is true
    and (
      lower(coalesce(h.marketplace_sku_map_id::text,'')) = lower(coalesce(v_mapping_id,''))
      or lower(coalesce(h.marketplace_sku_id,'')) = coalesce(v_marketplace_sku,'')
      or lower(coalesce(to_jsonb(h)->>'marketplace_sku','')) = coalesce(v_marketplace_sku,'')
      or lower(coalesce(h.marketplace_seller_sku,'')) = coalesce(v_seller_sku,'')
      or lower(coalesce(to_jsonb(h)->>'seller_sku','')) = coalesce(v_seller_sku,'')
      or lower(coalesce(h.local_sku,'')) = lower(coalesce(v_resolved_local_sku, p_current_local_sku, ''))
    )
  order by
    case
      when lower(coalesce(h.marketplace_sku_map_id::text,'')) = lower(coalesce(v_mapping_id,'')) then 1
      when lower(coalesce(h.marketplace_sku_id,'')) = coalesce(v_marketplace_sku,'') then 2
      when lower(coalesce(h.marketplace_seller_sku,'')) = coalesce(v_seller_sku,'') then 3
      when lower(coalesce(h.local_sku,'')) = lower(coalesce(v_resolved_local_sku, p_current_local_sku, '')) then 8
      else 99
    end,
    coalesce(h.updated_at, h.created_at, now()) desc
  limit 1;

  v_resolved_local_sku := coalesce(
    nullif(v_hpp_map->>'local_sku',''),
    nullif(v_hpp_map->>'mapped_local_sku',''),
    v_resolved_local_sku,
    nullif(p_current_local_sku,'')
  );

  v_mapping_id := coalesce(
    nullif(v_hpp_map->>'mapping_id',''),
    nullif(v_hpp_map->>'hpp_mapping_id',''),
    nullif(v_hpp_map->>'id',''),
    v_mapping_id
  );

  v_hpp := public'),
    nullif(v_hpp_map->>'id',''),
    v_mapping_id
  );

  v_hpp := public._finance_num_20260625(coalesce(
    nullif(v_hpp_map->>'hpp',''),
    nullif(v_hpp_map->>'hpp_amount',''),
    nullif(v_hpp_map->>'hpp_per_item',''),
    '0'
  ));

  v_target_margin := public._finance_num_20260625(coalesce(
    nullif(v_hpp_map->>'target_margin_percent',''),
    nullif(v_hpp_map->>'target_margin',''),
    '0'
  ));

  if v_hpp_map <> '{}'::jsonb then
    v_mapping_source := coalesce(v_mapping_source || '+marketplace_variant_hpp_mappings', 'marketplace_variant_hpp_mappings');
  end if;

  return jsonb_build_object(
    'local_sku', v_resolved_local_sku,
    'hpp', v_hpp,
    'target_margin', v_target_margin,
    'mapping_id', v_mapping_id,
    'mapping_source', v_mapping_source,
    'sku_map_id', coalesce(v_sku_map->>'marketplace_sku_map_id', v_sku_map->>'map_id'),
    'hpp_mapping_id', coalesce(v_hpp_map->>'mapping_id', v_hpp_map->>'hpp_mapping_id', v_hpp_map->>'id')
  );
end;
$$;

grant execute on function public.finance_resolve_variant_mapping_20260625(uuid,uuid,text,text,text)
to anon, authenticated, service_role;

notify pgrst, 'reload schema';