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
  with tenant_accounts as (
    select
      t.tenant_id,
      t.tenant_name,
      t.status as tenant_status,
      ma.marketplace,
      ma.marketplace_account_id,
      coalesce(ma.store_alias, ma.shop_name, '-') as store_alias,
      ma.status as account_status
    from public.app_tenants t
    left join public.marketplace_accounts ma
      on ma.tenant_id = t.tenant_id
     and coalesce(ma.is_deleted, false) = false
  )
  select
    ta.tenant_id,
    ta.tenant_name::text,
    ta.tenant_status::text,
    ta.marketplace::text,
    ta.marketplace_account_id,
    ta.store_alias::text,
    ta.account_status::text,
    coalesce((
      select count(*)
      from public.marketplace_product_snapshots p
      where p.tenant_id = ta.tenant_id
        and p.marketplace_account_id = ta.marketplace_account_id
    ), 0)::bigint as product_snapshot_count,
    coalesce((
      select count(*)
      from public.marketplace_variant_snapshots v
      where v.tenant_id = ta.tenant_id
        and v.marketplace_account_id = ta.marketplace_account_id
    ), 0)::bigint as variant_snapshot_count,
    coalesce((
      select count(*)
      from public.marketplace_orders o
      where o.tenant_id = ta.tenant_id
        and o.marketplace_account_id = ta.marketplace_account_id
    ), 0)::bigint as order_count,
    coalesce((
      select count(*)
      from public.marketplace_finance_reports f
      where f.tenant_id = ta.tenant_id
        and f.marketplace_account_id = ta.marketplace_account_id
    ), 0)::bigint as finance_count,
    coalesce((
      select count(*)
      from public.marketplace_variant_snapshots v
      where v.tenant_id = ta.tenant_id
        and v.marketplace_account_id = ta.marketplace_account_id
        and exists (
          select 1
          from public.marketplace_sku_maps m
          where m.tenant_id = v.tenant_id
            and m.marketplace_account_id = v.marketplace_account_id
            and coalesce(m.status, 'active') = 'active'
            and (
              m.marketplace_variant_snapshot_id = v.marketplace_variant_snapshot_id
              or (
                coalesce(nullif(m.marketplace_product_id, ''), nullif(m.remote_product_id, '')) = coalesce(nullif(v.marketplace_product_id, ''), '')
                and coalesce(nullif(m.marketplace_sku_id, ''), nullif(m.remote_sku_id, ''), nullif(m.marketplace_sku, '')) = coalesce(nullif(v.marketplace_sku_id, ''), '')
              )
              or (
                nullif(v.marketplace_seller_sku, '') is not null
                and lower(coalesce(nullif(m.marketplace_seller_sku, ''), nullif(m.remote_seller_sku, ''))) = lower(v.marketplace_seller_sku)
              )
            )
        )
    ), 0)::bigint as sku_mapped_count,
    coalesce((
      select count(*)
      from public.marketplace_variant_snapshots v
      where v.tenant_id = ta.tenant_id
        and v.marketplace_account_id = ta.marketplace_account_id
        and exists (
          select 1
          from public.marketplace_variant_hpp_mappings h
          where h.tenant_id = v.tenant_id
            and h.marketplace_account_id = v.marketplace_account_id
            and coalesce(h.is_active, true) = true
            and coalesce(h.hpp, h.hpp_amount, h.hpp_per_item, 0) > 0
            and (
              (
                nullif(h.marketplace_product_id, '') is not null
                and nullif(h.marketplace_sku_id, '') is not null
                and h.marketplace_product_id = v.marketplace_product_id
                and h.marketplace_sku_id = v.marketplace_sku_id
              )
              or (
                nullif(h.marketplace_sku_id, '') is not null
                and h.marketplace_sku_id = v.marketplace_sku_id
              )
              or (
                nullif(v.marketplace_seller_sku, '') is not null
                and lower(coalesce(nullif(h.marketplace_seller_sku, ''), '')) = lower(v.marketplace_seller_sku)
              )
            )
        )
    ), 0)::bigint as hpp_mapped_count,
    coalesce((
      select count(*)
      from public.marketplace_order_items oi
      where oi.tenant_id = ta.tenant_id
        and oi.marketplace_account_id = ta.marketplace_account_id
        and not exists (
          select 1
          from public.marketplace_sku_maps m
          where m.tenant_id = oi.tenant_id
            and m.marketplace_account_id = oi.marketplace_account_id
            and coalesce(m.status, 'active') = 'active'
            and (
              (
                coalesce(nullif(m.marketplace_product_id, ''), nullif(m.remote_product_id, '')) = coalesce(nullif(oi.marketplace_product_id, ''), '')
                and coalesce(nullif(m.marketplace_sku_id, ''), nullif(m.remote_sku_id, ''), nullif(m.marketplace_sku, '')) = coalesce(nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, ''), '')
              )
              or (
                nullif(coalesce(oi.marketplace_seller_sku, oi.seller_sku), '') is not null
                and lower(coalesce(nullif(m.marketplace_seller_sku, ''), nullif(m.remote_seller_sku, ''))) = lower(coalesce(oi.marketplace_seller_sku, oi.seller_sku))
              )
            )
        )
    ), 0)::bigint as unmapped_order_item_count,
    (
      case
        when ta.marketplace_account_id is null then 'no_account'
        when coalesce((
          select count(*)
          from public.marketplace_variant_snapshots v
          where v.tenant_id = ta.tenant_id
            and v.marketplace_account_id = ta.marketplace_account_id
        ), 0) = 0 then 'needs_product_pull'
        when coalesce((
          select count(*)
          from public.marketplace_orders o
          where o.tenant_id = ta.tenant_id
            and o.marketplace_account_id = ta.marketplace_account_id
        ), 0) = 0 then 'needs_order_pull'
        else 'ready'
      end
    )::text as readiness_status
  from tenant_accounts ta
  order by ta.tenant_name, ta.marketplace, ta.store_alias;
end;
$$;

grant execute on function public.platform_tenant_readiness_summary() to authenticated;
grant execute on function public.platform_tenant_readiness_summary() to service_role;
