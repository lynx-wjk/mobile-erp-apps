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

create or replace function public.finance_update_manual_operational_expense(
  p_expense_id uuid,
  p_category text,
  p_amount numeric,
  p_expense_date date,
  p_note text default null::text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_row public.finance_operational_expenses%rowtype;
begin
  if p_expense_id is null then
    raise exception 'expense_id wajib diisi';
  end if;
  if coalesce(p_amount,0) <= 0 then
    raise exception 'amount wajib lebih dari 0';
  end if;

  update public.finance_operational_expenses
  set
    category = nullif(trim(coalesce(p_category, category)), ''),
    amount = p_amount,
    expense_date = coalesce(p_expense_date, expense_date),
    note = nullif(trim(coalesce(p_note, note)), ''),
    updated_at = now()
  where expense_id = p_expense_id
  returning * into v_row;

  if not found then
    raise exception 'Biaya operasional tidak ditemukan: %', p_expense_id;
  end if;

  return to_jsonb(v_row);
end
$function$;

create or replace function public.finance_delete_manual_operational_expense(
  p_expense_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_deleted public.finance_operational_expenses%rowtype;
begin
  if p_expense_id is null then
    raise exception 'expense_id wajib diisi';
  end if;

  delete from public.finance_operational_expenses
  where expense_id = p_expense_id
  returning * into v_deleted;

  if not found then
    raise exception 'Biaya operasional tidak ditemukan: %', p_expense_id;
  end if;

  return jsonb_build_object('ok', true, 'deleted', to_jsonb(v_deleted));
end
$function$;

grant execute on function public.finance_update_manual_operational_expense(uuid,text,numeric,date,text)
  to anon, authenticated, service_role;
grant execute on function public.finance_delete_manual_operational_expense(uuid)
  to anon, authenticated, service_role;

with live as (
  select elem as row
  from jsonb_array_elements(
    coalesce(
      public.finance_sku_order_details_v24_6_82o(
        date_trunc('month', now())::date,
        now()::date,
        null,
        null,
        null,
        null,
        null,
        'paid',
        1,
        10000
      )::jsonb -> 'rows',
      '[]'::jsonb
    )
  ) elem
),
candidates_raw as (
  select
    coalesce(nullif(row->>'tenant_id','')::uuid, p.tenant_id) as tenant_id,
    nullif(row->>'marketplace_account_id','')::uuid as marketplace_account_id,
    nullif(row->>'marketplace','') as marketplace,
    nullif(row->>'marketplace_product_id','') as marketplace_product_id,
    coalesce(nullif(row->>'marketplace_sku_id',''), nullif(row->>'marketplace_sku','')) as marketplace_sku_id,
    nullif(row->>'marketplace_seller_sku','') as marketplace_seller_sku,
    coalesce(nullif(row->>'product_name',''), nullif(row->>'nama_barang','')) as marketplace_product_name,
    nullif(row->>'variant_name','') as marketplace_variant_name,
    p.product_id as local_product_id,
    p.nama_barang as local_product_name,
    p.kode_sku as local_sku,
    p.harga_hpp_default::numeric as hpp,
    30::numeric as target_margin_percent
  from live
  join public.products p
    on (
      lower(p.kode_sku) = lower(nullif(live.row->>'local_sku',''))
      or lower(p.nama_barang) = lower(nullif(live.row->>'local_sku',''))
      or lower(p.nama_barang) = lower(nullif(live.row->>'product_name',''))
      or lower(p.kode_sku) = lower(nullif(live.row->>'sku',''))
    )
  where coalesce(p.harga_hpp_default,0) > 0
    and coalesce(nullif(row->>'marketplace_sku_id',''), nullif(row->>'marketplace_sku','')) is not null
    and coalesce(nullif(row->>'marketplace_sku_id',''), nullif(row->>'marketplace_sku','')) !~* '^[a-z ]+$'
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
  where tenant_id is not null and marketplace_sku_id is not null
  order by marketplace_sku_id, hpp desc
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
    source = coalesce(h.source, 'backfill_from_finance_sku_rows')
  from candidates c
  where h.marketplace_sku_id = c.marketplace_sku_id
  returning h.marketplace_sku_id
)
insert into public.marketplace_variant_hpp_mappings (
  mapping_id, tenant_id, marketplace_account_id, marketplace, marketplace_product_id,
  marketplace_sku_id, marketplace_seller_sku, marketplace_product_name,
  marketplace_variant_name, local_product_id, local_product_name, local_sku,
  hpp, hpp_amount, hpp_per_item, target_margin_percent, target_margin,
  is_active, source, created_at, updated_at
)
select
  gen_random_uuid(), c.tenant_id, c.marketplace_account_id, c.marketplace,
  c.marketplace_product_id, c.marketplace_sku_id, c.marketplace_seller_sku,
  c.marketplace_product_name, c.marketplace_variant_name, c.local_product_id,
  c.local_product_name, c.local_sku, c.hpp, c.hpp, c.hpp,
  c.target_margin_percent, c.target_margin_percent, true,
  'backfill_from_finance_sku_rows', now(), now()
from candidates c
where not exists (
  select 1 from public.marketplace_variant_hpp_mappings h
  where h.marketplace_sku_id = c.marketplace_sku_id
);

notify pgrst, 'reload schema';

select 'hpp_mapping_count_v28' as check_name,
       count(*) as rows,
       count(*) filter (where is_active and coalesce(nullif(hpp_per_item,0), nullif(hpp_amount,0), nullif(hpp,0)) > 0) as active_hpp_rows
from public.marketplace_variant_hpp_mappings;

select 'manual_expense_rpc_v28' as check_name,
       count(*) filter (where proname='finance_update_manual_operational_expense') as update_rpc,
       count(*) filter (where proname='finance_delete_manual_operational_expense') as delete_rpc
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname='public'
  and proname in ('finance_update_manual_operational_expense','finance_delete_manual_operational_expense');
