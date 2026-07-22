create or replace function public.marketplace_clear_sku_hpp_mapping(
  p_tenant_id uuid,
  p_marketplace_account_id uuid,
  p_marketplace text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sku_cleared integer := 0;
  v_hpp_cleared integer := 0;
  v_marketplace text := nullif(trim(coalesce(p_marketplace, '')), '');
begin
  if p_tenant_id is null or p_marketplace_account_id is null then
    return jsonb_build_object(
      'ok', false,
      'message', 'Tenant dan marketplace account wajib dipilih.',
      'sku_cleared', 0,
      'hpp_cleared', 0
    );
  end if;

  update public.marketplace_variant_hpp_mappings h
     set is_active = false,
         updated_at = now()
   where h.tenant_id = p_tenant_id
     and h.marketplace_account_id = p_marketplace_account_id
     and (v_marketplace is null or v_marketplace = 'all' or h.marketplace = v_marketplace)
     and coalesce(h.is_active, true) = true;
  get diagnostics v_hpp_cleared = row_count;

  update public.marketplace_sku_maps m
     set status = 'inactive',
         sync_enabled = false,
         is_stock_sync_enabled = false,
         updated_at = now()
   where m.tenant_id = p_tenant_id
     and m.marketplace_account_id = p_marketplace_account_id
     and (v_marketplace is null or v_marketplace = 'all' or m.marketplace = v_marketplace)
     and coalesce(m.status, 'active') = 'active';
  get diagnostics v_sku_cleared = row_count;

  return jsonb_build_object(
    'ok', true,
    'source', 'marketplace_clear_sku_hpp_mapping_selected_account_20260627',
    'tenant_id', p_tenant_id,
    'marketplace_account_id', p_marketplace_account_id,
    'marketplace', v_marketplace,
    'sku_cleared', v_sku_cleared,
    'hpp_cleared', v_hpp_cleared,
    'message', format(
      'Clear SKU/HPP mapping selesai. SKU: %s, HPP: %s.',
      v_sku_cleared,
      v_hpp_cleared
    )
  );
end;
$$;

grant execute on function public.marketplace_clear_sku_hpp_mapping(uuid, uuid, text) to authenticated;
grant execute on function public.marketplace_clear_sku_hpp_mapping(uuid, uuid, text) to service_role;
