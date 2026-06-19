-- Fix Finance HPP row-level, expense RLS/edit/delete visibility, and trigger status backlog.
-- v27 unique resume:
-- - Do not use marketplace_sku display/seller text as marketplace_sku_id.
-- - Use only true variant SKU id columns for central HPP mapping insert/update.
-- - Existing unique constraint is on marketplace_sku_id, so conflict check follows that column.

create or replace function public.mobile_erp_num0(p_value text)
returns numeric
language sql
immutable
as $$
  select case
    when p_value is null then 0::numeric
    when trim(p_value) ~ '^-?[0-9]+(\.[0-9]+)?$' then trim(p_value)::numeric
    else 0::numeric
  end
$$;

create or replace function public.mobile_erp_uuid_or_null(p_value text)
returns uuid
language sql
immutable
as $$
  select case
    when p_value is null then null::uuid
    when trim(p_value) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then trim(p_value)::uuid
    else null::uuid
  end
$$;

with candidates_raw as (
  select
    oi.tenant_id,
    oi.marketplace_account_id,
    oi.marketplace,
    coalesce(nullif(oi.marketplace_product_id,''), nullif(sm.marketplace_product_id,'')) as marketplace_product_id,

    -- IMPORTANT: true SKU id only. Do NOT fall back to marketplace_sku display text like "Rubelle Top".
    coalesce(nullif(oi.marketplace_sku_id,''), nullif(oi.remote_sku_id,''), nullif(sm.marketplace_sku_id,'')) as marketplace_sku_id,

    coalesce(nullif(oi.marketplace_seller_sku,''), nullif(oi.seller_sku,''), nullif(sm.marketplace_seller_sku,''), nullif(sm.marketplace_sku,'')) as marketplace_seller_sku,
    coalesce(nullif(oi.marketplace_product_name,''), nullif(oi.product_name,''), nullif(sm.marketplace_product_name,'')) as marketplace_product_name,
    coalesce(nullif(oi.marketplace_variant_name,''), nullif(oi.variant_name,''), nullif(oi.variation_name,''), nullif(sm.marketplace_variation_name,'')) as marketplace_variant_name,
    p.product_id as local_product_id,
    coalesce(nullif(p.nama_barang,''), nullif(sm.local_product_name,''), nullif(oi.local_product_name,'')) as local_product_name,
    coalesce(nullif(p.kode_sku,''), nullif(sm.local_sku,''), nullif(oi.local_sku,''), nullif(oi.mapped_local_sku,'')) as local_sku,
    coalesce(nullif(p.harga_hpp_default,0), 0)::numeric as hpp,
    30::numeric as target_margin_percent,
    oi.updated_at
  from public.marketplace_order_items oi
  left join public.marketplace_sku_maps_public sm
    on sm.tenant_id = oi.tenant_id
   and sm.marketplace = oi.marketplace
   and (sm.marketplace_account_id is null or sm.marketplace_account_id = oi.marketplace_account_id)
   and (
     nullif(sm.marketplace_sku_id,'') = coalesce(nullif(oi.marketplace_sku_id,''), nullif(oi.remote_sku_id,''))
     or lower(coalesce(sm.local_sku,'')) = lower(coalesce(nullif(oi.local_sku,''), nullif(oi.mapped_local_sku,''), ''))
   )
  join public.products p
    on p.tenant_id = oi.tenant_id
   and (
     p.product_id = coalesce(sm.product_id, oi.product_id, oi.local_product_id, oi.mapped_product_id)
     or lower(p.kode_sku) = lower(coalesce(nullif(sm.local_sku,''), nullif(oi.local_sku,''), nullif(oi.mapped_local_sku,''), ''))
     or lower(p.nama_barang) = lower(coalesce(nullif(sm.local_product_name,''), nullif(oi.local_product_name,''), nullif(oi.local_sku,''), ''))
   )
  where oi.tenant_id is not null
    and oi.marketplace_account_id is not null
    and coalesce(nullif(oi.marketplace_sku_id,''), nullif(oi.remote_sku_id,''), nullif(sm.marketplace_sku_id,'')) is not null
    and coalesce(nullif(p.harga_hpp_default,0),0) > 0
),
candidates as (
  select distinct on (marketplace_sku_id)
    tenant_id,
    marketplace_account_id,
    marketplace,
    marketplace_product_id,
    marketplace_sku_id,
    marketplace_seller_sku,
    marketplace_product_name,
    marketplace_variant_name,
    local_product_id,
    local_product_name,
    local_sku,
    hpp,
    target_margin_percent
  from candidates_raw
  where nullif(marketplace_sku_id,'') is not null
  order by marketplace_sku_id, updated_at desc nulls last
),
updated as (
  update public.marketplace_variant_hpp_mappings h
  set
    tenant_id = coalesce(h.tenant_id, c.tenant_id),
    marketplace_account_id = coalesce(h.marketplace_account_id, c.marketplace_account_id),
    marketplace = coalesce(h.marketplace, c.marketplace),
    marketplace_product_id = coalesce(nullif(h.marketplace_product_id,''), c.marketplace_product_id),
    marketplace_seller_sku = coalesce(nullif(h.marketplace_seller_sku,''), c.marketplace_seller_sku),
    marketplace_product_name = coalesce(nullif(h.marketplace_product_name,''), c.marketplace_product_name),
    marketplace_variant_name = coalesce(nullif(h.marketplace_variant_name,''), c.marketplace_variant_name),
    local_product_id = coalesce(h.local_product_id, c.local_product_id),
    local_product_name = coalesce(nullif(h.local_product_name,''), c.local_product_name),
    local_sku = coalesce(nullif(h.local_sku,''), c.local_sku),
    hpp = case when coalesce(h.hpp,0) = 0 then c.hpp else h.hpp end,
    hpp_amount = case when coalesce(h.hpp_amount,0) = 0 then c.hpp else h.hpp_amount end,
    hpp_per_item = case when coalesce(h.hpp_per_item,0) = 0 then c.hpp else h.hpp_per_item end,
    target_margin_percent = case when coalesce(h.target_margin_percent,0) = 0 then c.target_margin_percent else h.target_margin_percent end,
    target_margin = case when coalesce(h.target_margin,0) = 0 then c.target_margin_percent else h.target_margin end,
    is_active = true,
    updated_at = now(),
    source = coalesce(h.source, 'backfill_from_mapped_product_hpp')
  from candidates c
  where h.marketplace_sku_id = c.marketplace_sku_id
  returning h.marketplace_sku_id
)
insert into public.marketplace_variant_hpp_mappings (
  mapping_id,
  tenant_id,
  marketplace_account_id,
  marketplace,
  marketplace_product_id,
  marketplace_sku_id,
  marketplace_seller_sku,
  marketplace_product_name,
  marketplace_variant_name,
  local_product_id,
  local_product_name,
  local_sku,
  hpp,
  hpp_amount,
  hpp_per_item,
  target_margin_percent,
  target_margin,
  is_active,
  source,
  created_at,
  updated_at
)
select
  gen_random_uuid(),
  c.tenant_id,
  c.marketplace_account_id,
  c.marketplace,
  c.marketplace_product_id,
  c.marketplace_sku_id,
  c.marketplace_seller_sku,
  c.marketplace_product_name,
  c.marketplace_variant_name,
  c.local_product_id,
  c.local_product_name,
  c.local_sku,
  c.hpp,
  c.hpp,
  c.hpp,
  c.target_margin_percent,
  c.target_margin_percent,
  true,
  'backfill_from_mapped_product_hpp',
  now(),
  now()
from candidates c
where not exists (
  select 1
  from public.marketplace_variant_hpp_mappings h
  where h.marketplace_sku_id = c.marketplace_sku_id
);

create index if not exists marketplace_variant_hpp_mappings_tenant_market_sku_idx
  on public.marketplace_variant_hpp_mappings(tenant_id, marketplace, marketplace_account_id, marketplace_sku_id)
  where is_active = true;

alter table public.finance_operational_expenses enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='finance_operational_expenses'
      and policyname='finance_operational_expenses_tenant_select'
  ) then
    create policy finance_operational_expenses_tenant_select
      on public.finance_operational_expenses
      for select to authenticated
      using (
        tenant_id = nullif((nullif(current_setting('request.jwt.claims', true),'')::jsonb ->> 'tenant_id'),'')::uuid
      );
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='finance_operational_expenses'
      and policyname='finance_operational_expenses_tenant_insert'
  ) then
    create policy finance_operational_expenses_tenant_insert
      on public.finance_operational_expenses
      for insert to authenticated
      with check (
        tenant_id = nullif((nullif(current_setting('request.jwt.claims', true),'')::jsonb ->> 'tenant_id'),'')::uuid
      );
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='finance_operational_expenses'
      and policyname='finance_operational_expenses_tenant_update'
  ) then
    create policy finance_operational_expenses_tenant_update
      on public.finance_operational_expenses
      for update to authenticated
      using (
        tenant_id = nullif((nullif(current_setting('request.jwt.claims', true),'')::jsonb ->> 'tenant_id'),'')::uuid
      )
      with check (
        tenant_id = nullif((nullif(current_setting('request.jwt.claims', true),'')::jsonb ->> 'tenant_id'),'')::uuid
      );
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='finance_operational_expenses'
      and policyname='finance_operational_expenses_tenant_delete'
  ) then
    create policy finance_operational_expenses_tenant_delete
      on public.finance_operational_expenses
      for delete to authenticated
      using (
        tenant_id = nullif((nullif(current_setting('request.jwt.claims', true),'')::jsonb ->> 'tenant_id'),'')::uuid
      );
  end if;
end $$;

create or replace function public.finance_sku_order_details(
  p_start date default null::date,
  p_end date default null::date,
  p_marketplace text default null::text,
  p_account_id uuid default null::uuid,
  p_marketplace_sku text default null::text,
  p_local_sku text default null::text,
  p_search text default null::text,
  p_payout_filter text default 'all'::text,
  p_page integer default 1,
  p_page_size integer default 20
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_filter text := lower(coalesce(p_payout_filter, 'all'));
  v_base jsonb := '{}'::jsonb;
  v_rows jsonb := '[]'::jsonb;
  v_aggregates jsonb := '{}'::jsonb;
  v_page_hpp numeric := 0;
  v_missing_count integer := 0;
begin
  if v_filter in ('settled', 'released', 'release', 'payout', 'paid_payout', 'sudah_payout', 'sudah payout') then
    v_filter := 'paid';
  elsif v_filter in ('pending', 'belum_payout', 'belum payout', 'no_payout', 'no payout', 'missing_payout') then
    v_filter := 'unpaid';
  end if;

  v_base := coalesce(public.finance_sku_order_details_v24_6_82o(
    p_start,
    p_end,
    p_marketplace,
    p_account_id,
    p_marketplace_sku,
    p_local_sku,
    p_search,
    v_filter,
    p_page,
    p_page_size
  ), '{}'::jsonb);

  with src as (
    select elem as row, ord
    from jsonb_array_elements(coalesce(v_base->'rows','[]'::jsonb)) with ordinality as t(elem, ord)
  ),
  norm as (
    select
      s.row,
      s.ord,
      public.mobile_erp_uuid_or_null(s.row->>'tenant_id') as tenant_id,
      public.mobile_erp_uuid_or_null(s.row->>'marketplace_account_id') as marketplace_account_id,
      nullif(s.row->>'marketplace','') as marketplace,
      nullif(coalesce(s.row->>'marketplace_sku_id', s.row->>'marketplace_sku'),'') as marketplace_sku_id,
      nullif(s.row->>'marketplace_sku','') as marketplace_sku,
      nullif(s.row->>'local_sku','') as local_sku,
      greatest(
        public.mobile_erp_num0(s.row->>'paid_qty'),
        public.mobile_erp_num0(s.row->>'settled_qty'),
        public.mobile_erp_num0(s.row->>'qty_paid'),
        case when v_filter = 'paid' then public.mobile_erp_num0(s.row->>'qty') else 0 end
      ) as paid_qty
    from src s
  ),
  enriched as (
    select
      n.ord,
      n.row,
      n.paid_qty,
      h.hpp_value,
      h.target_margin_value
    from norm n
    left join lateral (
      select
        coalesce(nullif(hm.hpp_per_item,0), nullif(hm.hpp_amount,0), nullif(hm.hpp,0))::numeric as hpp_value,
        coalesce(nullif(hm.target_margin_percent,0), nullif(hm.target_margin,0), 0)::numeric as target_margin_value
      from public.marketplace_variant_hpp_mappings hm
      where hm.is_active = true
        and coalesce(nullif(hm.hpp_per_item,0), nullif(hm.hpp_amount,0), nullif(hm.hpp,0)) > 0
        and (n.tenant_id is null or hm.tenant_id = n.tenant_id)
        and (n.marketplace is null or hm.marketplace = n.marketplace)
        and (n.marketplace_account_id is null or hm.marketplace_account_id = n.marketplace_account_id)
        and (
          nullif(hm.marketplace_sku_id,'') = n.marketplace_sku_id
          or nullif(hm.marketplace_sku_id,'') = n.marketplace_sku
          or lower(coalesce(hm.local_sku,'')) = lower(coalesce(n.local_sku,''))
        )
      order by
        case when n.marketplace_account_id is not null and hm.marketplace_account_id = n.marketplace_account_id then 0 else 10 end,
        case when nullif(hm.marketplace_sku_id,'') = n.marketplace_sku_id then 0 else 1 end,
        case when nullif(hm.marketplace_sku_id,'') = n.marketplace_sku then 0 else 1 end,
        hm.updated_at desc nulls last
      limit 1
    ) h on true
  ),
  final_rows as (
    select
      ord,
      case
        when coalesce(hpp_value,0) > 0 then
          row || jsonb_build_object(
            'paid_qty', case when paid_qty > 0 then paid_qty else public.mobile_erp_num0(row->>'paid_qty') end,
            'settled_qty', case when paid_qty > 0 then paid_qty else public.mobile_erp_num0(row->>'settled_qty') end,
            'hpp_per_item', hpp_value,
            'hpp', hpp_value,
            'hpp_item', hpp_value,
            'paid_hpp_total', hpp_value * greatest(paid_qty, public.mobile_erp_num0(row->>'qty'), 1),
            'settled_hpp_total', hpp_value * greatest(paid_qty, public.mobile_erp_num0(row->>'qty'), 1),
            'hpp_total', hpp_value * greatest(paid_qty, public.mobile_erp_num0(row->>'qty'), 1),
            'target_margin_percent', target_margin_value,
            'hpp_status', 'mapped'
          )
        else
          row || jsonb_build_object('hpp_status', 'HPP belum mapping')
      end as row
    from enriched
  )
  select
    coalesce(jsonb_agg(row order by ord), '[]'::jsonb),
    coalesce(sum(public.mobile_erp_num0(row->>'paid_hpp_total')), 0),
    coalesce(count(*) filter (where row->>'hpp_status' = 'HPP belum mapping'), 0)
  into v_rows, v_page_hpp, v_missing_count
  from final_rows;

  v_aggregates := coalesce(v_base->'aggregates', '{}'::jsonb)
    || jsonb_build_object(
      'page_hpp_total', v_page_hpp,
      'page_paid_hpp_total', v_page_hpp,
      'page_settled_hpp_total', v_page_hpp,
      'hpp_missing_mapping_count', v_missing_count
    );

  v_base := jsonb_set(v_base, '{rows}', v_rows, true);
  v_base := jsonb_set(v_base, '{aggregates}', v_aggregates, true);
  return v_base;
end
$function$;

grant execute on function public.finance_sku_order_details(date,date,text,uuid,text,text,text,text,integer,integer)
  to anon, authenticated, service_role;

do $$
begin
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='marketplace_order_status_backlog_90d_cron_v1'
  ) then
    perform public.marketplace_order_status_backlog_90d_cron_v1();
  end if;
exception when others then
  raise notice 'status_backlog_kick_skipped=%', sqlerrm;
end $$;

notify pgrst, 'reload schema';

select 'hpp_mapping_count' as check_name,
       count(*) as rows,
       count(*) filter (where is_active and coalesce(nullif(hpp_per_item,0), nullif(hpp_amount,0), nullif(hpp,0)) > 0) as active_hpp_rows
from public.marketplace_variant_hpp_mappings;

select 'expense_policies' as check_name,
       count(*) filter (where policyname ilike '%select%') as select_policies,
       count(*) filter (where policyname ilike '%insert%') as insert_policies,
       count(*) filter (where policyname ilike '%update%') as update_policies,
       count(*) filter (where policyname ilike '%delete%') as delete_policies
from pg_policies
where schemaname='public' and tablename='finance_operational_expenses';
