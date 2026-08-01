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
  v jsonb := '{}'::jsonb;
begin
  select jsonb_build_object(
    'local_sku',
      coalesce(
        nullif(to_jsonb(m)->>'local_sku',''),
        nullif(to_jsonb(m)->>'mapped_local_sku',''),
        nullif(to_jsonb(m)->>'sku',''),
        nullif(to_jsonb(m)->>'local_product_sku',''),
        nullif(p_current_local_sku,'')
      ),
    'hpp',
      coalesce(
        nullif(to_jsonb(m)->>'hpp',''),
        nullif(to_jsonb(m)->>'hpp_amount',''),
        nullif(to_jsonb(m)->>'hpp_per_item',''),
        '0'
      ),
    'target_margin',
      coalesce(
        nullif(to_jsonb(m)->>'target_margin_percent',''),
        nullif(to_jsonb(m)->>'target_margin',''),
        '0'
      ),
    'mapping_id',
      coalesce(to_jsonb(m)->>'marketplace_variant_hpp_mapping_id', to_jsonb(m)->>'id')
  )
  into v
  from public.marketplace_variant_hpp_mappings m
  where m.tenant_id = p_tenant_id
    and (p_account_id is null or m.marketplace_account_id = p_account_id)
    and coalesce((to_jsonb(m)->>'is_active')::boolean, true) is true
    and (
      lower(coalesce(to_jsonb(m)->>'marketplace_sku_id','')) = lower(coalesce(p_marketplace_sku,''))
      or lower(coalesce(to_jsonb(m)->>'marketplace_sku','')) = lower(coalesce(p_marketplace_sku,''))
      or lower(coalesce(to_jsonb(m)->>'marketplace_seller_sku','')) = lower(coalesce(p_seller_sku,''))
      or lower(coalesce(to_jsonb(m)->>'seller_sku','')) = lower(coalesce(p_seller_sku,''))
      or lower(coalesce(to_jsonb(m)->>'local_sku','')) = lower(coalesce(p_current_local_sku,''))
      or lower(coalesce(to_jsonb(m)->>'mapped_local_sku','')) = lower(coalesce(p_current_local_sku,''))
    )
  order by
    coalesce(nullif(to_jsonb(m)->>'updated_at','')::timestamptz, nullif(to_jsonb(m)->>'created_at','')::timestamptz, now()) desc
  limit 1;

  return coalesce(v, jsonb_build_object(
    'local_sku', nullif(p_current_local_sku,''),
    'hpp', '0',
    'target_margin', '0',
    'mapping_id', null
  ));
end;
$$;

grant execute on function public.finance_resolve_variant_mapping_20260625(uuid,uuid,text,text,text)
to anon, authenticated, service_role;