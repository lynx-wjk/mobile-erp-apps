create or replace function public.platform_tenant_readiness_summary()
returns table (
  tenant_id uuid,
  tenant_name text,
  tenant_status text,
  marketplace text,
  marketplace_account_id uuid,
  store_alias text,
  account_status text,
  product_snapshot_count bigint,
  variant_snapshot_count bigint,
  order_count bigint,
  finance_count bigint,
  sku_mapped_count bigint,
  hpp_mapped_count bigint,
  unmapped_order_item_count bigint,
  readiness_status text
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1
    from public.users u
    where u.user_id = auth.uid()
      and u.status = 'active'
      and u.role_id = 'platform_owner'
  ) then
    raise exception 'Forbidden';
  end if;

  return query
  select
    t.tenant_id,
    t.tenant_name::text,
    t.status::text as tenant_status,
    ma.marketplace::text,
    ma.marketplace_account_id,
    coalesce(ma.store_alias, ma.shop_name, '-')::text as store_alias,
    ma.status::text as account_status,

    coalesce((
      select count(*)
      from public.marketplace_product_snapshots p
      where p.tenant_id = t.tenant_id
        and p.marketplace_account_id = ma.marketplace_account_id
    ), 0)::bigint as product_snapshot_count,

    coalesce((
      select count(*)
      from public.marketplace_variant_snapshots v
      where v.tenant_id = t.tenant_id
        and v.marketplace_account_id = ma.marketplace_account_id
    ), 0)::bigint as variant_snapshot_count,

    coalesce((
      select count(*)
      from public.marketplace_orders o
      where o.tenant_id = t.tenant_id
        and o.marketplace_account_id = ma.marketplace_account_id
    ), 0)::bigint as order_count,

    coalesce((
      select count(*)
      from public.marketplace_finance_reports f
      where f.tenant_id = t.tenant_id
        and f.marketplace_account_id = ma.marketplace_account_id
    ), 0)::bigint as finance_count,

    coalesce((
      select count(*)
      from public.marketplace_sku_maps m
      where m.tenant_id = t.tenant_id
        and m.marketplace_account_id = ma.marketplace_account_id
        and coalesce(m.status, 'active') = 'active'
    ), 0)::bigint as sku_mapped_count,

    coalesce((
      select count(*)
      from public.marketplace_variant_hpp_mappings h
      where h.tenant_id = t.tenant_id
        and h.marketplace_account_id = ma.marketplace_account_id
        and coalesce(h.is_active, true) = true
    ), 0)::bigint as hpp_mapped_count,

    coalesce((
      select count(*)
      from public.marketplace_order_items oi
      where oi.tenant_id = t.tenant_id
        and oi.marketplace_account_id = ma.marketplace_account_id
        and not exists (
          select 1
          from public.marketplace_sku_maps m
          where m.tenant_id = oi.tenant_id
            and m.marketplace_account_id = oi.marketplace_account_id
            and m.marketplace = oi.marketplace
            and coalesce(m.status, 'active') = 'active'
            and coalesce(m.marketplace_product_id, m.remote_product_id, '') = coalesce(oi.marketplace_product_id, '')
            and coalesce(m.marketplace_sku_id, m.remote_sku_id, m.marketplace_sku, '') = coalesce(oi.marketplace_sku_id, '')
        )
    ), 0)::bigint as unmapped_order_item_count,

    (
      case
        when ma.marketplace_account_id is null then 'no_account'
        when ma.status is distinct from 'active' then 'account_inactive'
        when ma.access_token_expired_at is not null and ma.access_token_expired_at <= now() then 'token_expired'
        when coalesce((
          select count(*)
          from public.marketplace_variant_snapshots v
          where v.tenant_id = t.tenant_id
            and v.marketplace_account_id = ma.marketplace_account_id
        ), 0) = 0 then 'no_variants'
        when coalesce((
          select count(*)
          from public.marketplace_variant_snapshots v
          where v.tenant_id = t.tenant_id
            and v.marketplace_account_id = ma.marketplace_account_id
            and not exists (
              select 1
              from public.marketplace_sku_maps m
              where m.tenant_id = v.tenant_id
                and m.marketplace_account_id = v.marketplace_account_id
                and m.marketplace = v.marketplace
                and coalesce(m.status, 'active') = 'active'
                and coalesce(m.marketplace_product_id, m.remote_product_id, '') = coalesce(v.marketplace_product_id, '')
                and coalesce(m.marketplace_sku_id, m.remote_sku_id, m.marketplace_sku, '') = coalesce(v.marketplace_sku_id, '')
            )
        ), 0) > 0 then 'unmapped_skus'
        else 'ready'
      end
    )::text as readiness_status

  from public.app_tenants t
  left join public.marketplace_accounts ma
    on ma.tenant_id = t.tenant_id
   and coalesce(ma.is_deleted, false) = false
  order by t.tenant_name, ma.marketplace;
end;
$$;

grant execute on function public.platform_tenant_readiness_summary() to authenticated;
grant execute on function public.platform_tenant_readiness_summary() to service_role;
