-- Keep the active finance dashboard RPC reproducible:
-- omzet comes from marketplace_orders by order date, while payout comes from
-- marketplace_finance_reports by settlement/period date.

do $$
declare
  v_def text;
begin
  if to_regprocedure('public.finance_dashboard_snapshot_base_20260623(date,date,text,uuid)') is null then
    select pg_get_functiondef('public.finance_dashboard_snapshot(date,date,text,uuid)'::regprocedure)
      into v_def;

    v_def := regexp_replace(
      v_def,
      'CREATE OR REPLACE FUNCTION public\.finance_dashboard_snapshot\(',
      'CREATE OR REPLACE FUNCTION public.finance_dashboard_snapshot_base_20260623('
    );

    execute v_def;
  end if;

  if to_regprocedure('public.finance_customer_dashboard_snapshot_v24_6_82o(date,date,text,uuid)') is not null
     and to_regprocedure('public.finance_customer_dashboard_snapshot_v24_6_82o_base_20260623(date,date,text,uuid)') is null then
    select pg_get_functiondef('public.finance_customer_dashboard_snapshot_v24_6_82o(date,date,text,uuid)'::regprocedure)
      into v_def;

    v_def := regexp_replace(
      v_def,
      'CREATE OR REPLACE FUNCTION public\.finance_customer_dashboard_snapshot_v24_6_82o\(',
      'CREATE OR REPLACE FUNCTION public.finance_customer_dashboard_snapshot_v24_6_82o_base_20260623('
    );

    execute v_def;
  end if;
end
$$;

create or replace function public.finance_snapshot_order_omzet_settlement_overlay_20260623(
  p_base jsonb,
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
set statement_timeout to '20s'
as $function$
declare
  v_claims jsonb := '{}'::jsonb;
  v_tenant_id uuid := null;
  v_start date := coalesce(p_start, date_trunc('month', timezone('Asia/Jakarta', now()))::date);
  v_end date := coalesce(p_end, timezone('Asia/Jakarta', now())::date);
  v_marketplace text := null;
  v_summary jsonb := coalesce(p_base->'summary', '{}'::jsonb);
  v_by_marketplace jsonb := '[]'::jsonb;
  v_cash_adjustments jsonb := '[]'::jsonb;
  v_order_gross numeric := 0;
  v_order_count numeric := 0;
  v_payout numeric := 0;
  v_finance_count numeric := 0;
  v_expense numeric := 0;
  v_hpp numeric := 0;
begin
  begin
    v_claims := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  exception when others then
    v_claims := '{}'::jsonb;
  end;

  v_tenant_id := case
    when (v_claims->>'tenant_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then (v_claims->>'tenant_id')::uuid
    else null::uuid
  end;

  if v_tenant_id is null then
    select case when count(*) = 1 then (array_agg(tenant_id))[1] else null end
      into v_tenant_id
    from (select distinct tenant_id from public.users where tenant_id is not null) t;
  end if;

  v_marketplace := case
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) in ('', 'all', 'semua') then null
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
    else lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g'))
  end;

  with order_omzet as (
    select
      case
        when lower(regexp_replace(coalesce(mo.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
        when lower(regexp_replace(coalesce(mo.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        else lower(regexp_replace(coalesce(mo.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end as marketplace,
      count(*)::numeric as order_count,
      sum(coalesce(mo.total_amount, mo.gross_amount, mo.paid_amount, 0))::numeric as omzet_total
    from public.marketplace_orders mo
    where (v_tenant_id is null or mo.tenant_id = v_tenant_id)
      and (p_account_id is null or mo.marketplace_account_id = p_account_id)
      and coalesce(mo.order_created_at, mo.created_time, mo.created_at)::date between v_start and v_end
      and upper(coalesce(mo.order_status, '')) not in ('CANCELLED', 'CANCELED', 'REFUNDED', 'RETURNED')
      and (
        v_marketplace is null or
        case
          when lower(regexp_replace(coalesce(mo.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
          when lower(regexp_replace(coalesce(mo.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          else lower(regexp_replace(coalesce(mo.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end = v_marketplace
      )
    group by 1
  ),
  finance_payout as (
    select
      case
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end as marketplace,
      count(distinct coalesce(fr.marketplace_order_id::text, fr.order_id::text, fr.statement_id::text, fr.ctid::text))::numeric as finance_order_count,
      sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0))::numeric as payout_total
    from public.marketplace_finance_reports fr
    where (v_tenant_id is null or fr.tenant_id = v_tenant_id)
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and coalesce(fr.settlement_date::date, fr.period_start::date, fr.created_at::date) between v_start and v_end
      and (
        v_marketplace is null or
        case
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end = v_marketplace
      )
    group by 1
  ),
  merged as (
    select
      coalesce(o.marketplace, f.marketplace) as marketplace,
      coalesce(o.order_count, 0) as order_count,
      coalesce(o.omzet_total, 0) as omzet_total,
      coalesce(f.finance_order_count, 0) as finance_order_count,
      coalesce(f.payout_total, 0) as payout_total
    from order_omzet o
    full outer join finance_payout f using (marketplace)
  )
  select
    coalesce(sum(omzet_total), 0),
    coalesce(sum(order_count), 0),
    coalesce(sum(payout_total), 0),
    coalesce(sum(finance_order_count), 0),
    coalesce(jsonb_agg(jsonb_build_object(
      'marketplace', marketplace,
      'marketplace_label', marketplace,
      'shop_name', case
        when marketplace = 'tiktok_shop' then 'TikTok'
        when marketplace = 'shopee' then 'Shopee'
        else 'Marketplace'
      end,
      'order_count', order_count,
      'orders_count', order_count,
      'finance_order_count', finance_order_count,
      'finance_orders_count', finance_order_count,
      'omzet_total', omzet_total,
      'gross_sales', omzet_total,
      'gross_total', omzet_total,
      'gross_amount', omzet_total,
      'payout_total', payout_total,
      'payout_amount', payout_total,
      'received_amount', payout_total,
      'net_settlement', payout_total,
      'hpp_total', 0,
      'profit', payout_total,
      'net_profit', payout_total,
      'net_margin_percent', case when payout_total > 0 then 100 else 0 end,
      'omzet_source', 'marketplace_orders.order_created_at',
      'payout_source', 'marketplace_finance_reports.settlement_date'
    ) order by marketplace), '[]'::jsonb)
  into v_order_gross, v_order_count, v_payout, v_finance_count, v_by_marketplace
  from merged;

  select coalesce(jsonb_agg(jsonb_build_object(
      'cash_adjustment_id', cash_adjustment_id,
      'tenant_id', tenant_id,
      'adjustment_date', adjustment_date,
      'date', adjustment_date,
      'direction', direction,
      'type', case when lower(coalesce(direction, '')) = 'out' then 'out' else 'in' end,
      'cash_type', case when lower(coalesce(direction, '')) = 'out' then 'out' else 'in' end,
      'amount', amount,
      'category', category,
      'source', category,
      'title', category,
      'note', note,
      'description', note,
      'created_at', created_at
    ) order by adjustment_date desc, created_at desc), '[]'::jsonb)
    into v_cash_adjustments
  from public.finance_company_cash_adjustments
  where (v_tenant_id is null or tenant_id = v_tenant_id)
    and adjustment_date between v_start and v_end;

  v_expense := coalesce(nullif(v_summary->>'expense_total', '')::numeric, 0);
  v_hpp := coalesce(nullif(v_summary->>'hpp_total', '')::numeric, 0);

  v_summary := v_summary || jsonb_build_object(
    'omzet_total', v_order_gross,
    'gross_sales', v_order_gross,
    'gross_total', v_order_gross,
    'gross_amount', v_order_gross,
    'order_count', v_order_count,
    'orders_count', v_order_count,
    'all_orders_count', v_order_count,
    'payout_total', v_payout,
    'payout_amount', v_payout,
    'received_amount', v_payout,
    'net_settlement', v_payout,
    'finance_order_count', v_finance_count,
    'finance_orders_count', v_finance_count,
    'net_profit', v_payout - v_hpp - v_expense,
    'profit', v_payout - v_hpp - v_expense,
    'summary_policy', 'omzet_by_order_date_payout_by_settlement_date'
  );

  return p_base || jsonb_build_object(
    'summary', v_summary,
    'by_marketplace', v_by_marketplace,
    'marketplaces', v_by_marketplace,
    'cash_adjustments', v_cash_adjustments,
    'company_cash_adjustments', v_cash_adjustments,
    'wrapper_version', coalesce(p_base->>'wrapper_version', '') || '_order_omzet_settlement_payout_20260623'
  );
end;
$function$;

create or replace function public.finance_dashboard_snapshot(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
set statement_timeout to '20s'
as $function$
declare
  v_base jsonb;
begin
  v_base := public.finance_dashboard_snapshot_base_20260623(
    p_start, p_end, p_marketplace, p_account_id
  );

  return public.finance_snapshot_order_omzet_settlement_overlay_20260623(
    v_base, p_start, p_end, p_marketplace, p_account_id
  );
end;
$function$;

create or replace function public.finance_customer_dashboard_snapshot_v24_6_82o(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
set statement_timeout to '20s'
as $function$
declare
  v_base jsonb;
begin
  if to_regprocedure('public.finance_customer_dashboard_snapshot_v24_6_82o_base_20260623(date,date,text,uuid)') is null then
    return public.finance_dashboard_snapshot(
      p_start, p_end, p_marketplace, p_account_id
    );
  end if;

  v_base := public.finance_customer_dashboard_snapshot_v24_6_82o_base_20260623(
    p_start, p_end, p_marketplace, p_account_id
  );

  return public.finance_snapshot_order_omzet_settlement_overlay_20260623(
    v_base, p_start, p_end, p_marketplace, p_account_id
  );
end;
$function$;

revoke all on function public.finance_dashboard_snapshot(date, date, text, uuid) from public;
grant execute on function public.finance_dashboard_snapshot(date, date, text, uuid) to anon, authenticated, service_role;

revoke all on function public.finance_customer_dashboard_snapshot_v24_6_82o(date, date, text, uuid) from public;
grant execute on function public.finance_customer_dashboard_snapshot_v24_6_82o(date, date, text, uuid) to anon, authenticated, service_role;

-- Master SKU identity rule:
-- kode_barcode is the tenant-scoped unique identity. kode_sku is a display/grouping code
-- and must be allowed to duplicate.
drop index if exists public.uq_products_tenant_kode_sku;
drop index if exists public.idx_products_kode_barcode;

create unique index if not exists uq_products_tenant_kode_barcode
  on public.products (tenant_id, kode_barcode)
  where tenant_id is not null and nullif(kode_barcode, '') is not null;

create index if not exists idx_marketplace_sku_maps_tenant_local_barcode
  on public.marketplace_sku_maps (tenant_id, local_barcode);

create or replace function public.marketplace_upsert_sku_map_from_variant(
  p_tenant_id uuid,
  p_marketplace_account_id uuid,
  p_marketplace text,
  p_product_id uuid,
  p_local_sku text,
  p_marketplace_product_id text,
  p_marketplace_sku_id text,
  p_marketplace_sku text default null,
  p_marketplace_seller_sku text default null,
  p_marketplace_product_name text default null,
  p_marketplace_variation_name text default null,
  p_marketplace_variant_snapshot_id uuid default null,
  p_sync_enabled boolean default true
)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_id uuid;
  v_now timestamp with time zone := now();
  v_product record;
begin
  if p_tenant_id is null then
    raise exception 'tenant_id is required';
  end if;

  if p_marketplace_account_id is null then
    raise exception 'marketplace_account_id is required';
  end if;

  if p_product_id is null then
    raise exception 'local product_id is required';
  end if;

  if nullif(trim(coalesce(p_marketplace_product_id, '')), '') is null then
    raise exception 'marketplace_product_id is required';
  end if;

  if nullif(trim(coalesce(p_marketplace_sku_id, '')), '') is null then
    raise exception 'marketplace_sku_id is required';
  end if;

  if not coalesce(public.app_is_platform_super_admin(), false)
     and p_tenant_id is distinct from public.app_current_user_tenant_id() then
    raise exception 'Forbidden tenant access';
  end if;

  select p.product_id, p.kode_sku, p.kode_barcode, p.nama_barang
    into v_product
  from public.products p
  where p.tenant_id = p_tenant_id
    and p.product_id = p_product_id
  limit 1;

  if v_product.product_id is null then
    raise exception 'local product_id does not exist for tenant';
  end if;

  if nullif(trim(coalesce(v_product.kode_barcode, '')), '') is null then
    raise exception 'local product barcode is required for marketplace mapping';
  end if;

  update public.marketplace_sku_maps
  set status = 'duplicate_archived',
      sync_enabled = false,
      last_error = 'Archived before upsert because another active mapping will be used.',
      updated_at = v_now
  where tenant_id = p_tenant_id
    and marketplace_account_id = p_marketplace_account_id
    and marketplace_product_id = p_marketplace_product_id
    and marketplace_sku_id = p_marketplace_sku_id
    and coalesce(status, 'active') = 'active'
    and marketplace_sku_map_id not in (
      select marketplace_sku_map_id
      from public.marketplace_sku_maps
      where tenant_id = p_tenant_id
        and marketplace_account_id = p_marketplace_account_id
        and marketplace_product_id = p_marketplace_product_id
        and marketplace_sku_id = p_marketplace_sku_id
        and coalesce(status, 'active') = 'active'
      order by updated_at desc nulls last, created_at desc nulls last
      limit 1
    );

  select marketplace_sku_map_id
    into v_id
  from public.marketplace_sku_maps
  where tenant_id = p_tenant_id
    and marketplace_account_id = p_marketplace_account_id
    and marketplace_product_id = p_marketplace_product_id
    and marketplace_sku_id = p_marketplace_sku_id
    and coalesce(status, 'active') = 'active'
  order by updated_at desc nulls last, created_at desc nulls last
  limit 1;

  if v_id is null then
    insert into public.marketplace_sku_maps (
      tenant_id,
      marketplace_account_id,
      marketplace,
      product_id,
      local_product_id,
      local_sku,
      local_barcode,
      local_product_name,
      marketplace_product_id,
      marketplace_sku_id,
      marketplace_sku,
      marketplace_seller_sku,
      marketplace_product_name,
      marketplace_variation_name,
      marketplace_variant_snapshot_id,
      mapping_source,
      sync_enabled,
      status,
      last_error,
      created_at,
      updated_at
    ) values (
      p_tenant_id,
      p_marketplace_account_id,
      p_marketplace,
      v_product.product_id,
      v_product.product_id,
      nullif(trim(coalesce(v_product.kode_sku, p_local_sku, '')), ''),
      nullif(trim(v_product.kode_barcode), ''),
      nullif(trim(coalesce(v_product.nama_barang, '')), ''),
      p_marketplace_product_id,
      p_marketplace_sku_id,
      nullif(trim(coalesce(p_marketplace_sku, '')), ''),
      nullif(trim(coalesce(p_marketplace_seller_sku, '')), ''),
      nullif(trim(coalesce(p_marketplace_product_name, '')), ''),
      nullif(trim(coalesce(p_marketplace_variation_name, '')), ''),
      p_marketplace_variant_snapshot_id,
      'marketplace_variant_pull',
      coalesce(p_sync_enabled, true),
      'active',
      null,
      v_now,
      v_now
    )
    returning marketplace_sku_map_id into v_id;
  else
    update public.marketplace_sku_maps
    set product_id = v_product.product_id,
        local_product_id = v_product.product_id,
        local_sku = nullif(trim(coalesce(v_product.kode_sku, p_local_sku, '')), ''),
        local_barcode = nullif(trim(v_product.kode_barcode), ''),
        local_product_name = nullif(trim(coalesce(v_product.nama_barang, '')), ''),
        marketplace = p_marketplace,
        marketplace_sku = nullif(trim(coalesce(p_marketplace_sku, '')), ''),
        marketplace_seller_sku = nullif(trim(coalesce(p_marketplace_seller_sku, '')), ''),
        marketplace_product_name = nullif(trim(coalesce(p_marketplace_product_name, '')), ''),
        marketplace_variation_name = nullif(trim(coalesce(p_marketplace_variation_name, '')), ''),
        marketplace_variant_snapshot_id = p_marketplace_variant_snapshot_id,
        mapping_source = 'marketplace_variant_pull',
        sync_enabled = coalesce(p_sync_enabled, true),
        status = 'active',
        last_error = null,
        updated_at = v_now
    where marketplace_sku_map_id = v_id;
  end if;

  return v_id;
end;
$function$;

notify pgrst, 'reload schema';
