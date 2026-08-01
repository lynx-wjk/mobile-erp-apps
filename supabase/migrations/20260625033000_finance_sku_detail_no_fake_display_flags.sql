do $$
begin
  if to_regprocedure('public.finance_sku_order_line_details_no_fake_core_20260625(date,date,text,uuid,text,text,text,text,integer,integer)') is null then
    alter function public.finance_sku_order_line_details(date,date,text,uuid,text,text,text,text,integer,integer)
      rename to finance_sku_order_line_details_no_fake_core_20260625;
  end if;
end $$;

create or replace function public.finance_sku_order_line_details(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null,
  p_marketplace_sku text default null,
  p_local_sku text default null,
  p_search text default null,
  p_payout_filter text default 'all',
  p_page integer default 1,
  p_page_size integer default 25
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '25s'
as $$
declare
  j jsonb;
  rows jsonb := '[]'::jsonb;
  patched_rows jsonb := '[]'::jsonb;
begin
  j := public.finance_sku_order_line_details_no_fake_core_20260625(
    p_start,
    p_end,
    p_marketplace,
    p_account_id,
    p_marketplace_sku,
    p_local_sku,
    p_search,
    p_payout_filter,
    p_page,
    p_page_size
  );

  rows := coalesce(j->'rows','[]'::jsonb);

  with src as (
    select
      r.row,
      r.ord,
      public._finance_num_any_20260625(coalesce(r.row->>'gross_sales', r.row->>'gross_amount', r.row->>'gross_total', '0')) as gross_num,
      public._finance_num_any_20260625(coalesce(r.row->>'harga_jual_per_item', r.row->>'unit_price', r.row->>'price_per_item', r.row->>'gross_per_item', '0')) as unit_num,
      coalesce(r.row->>'gross_source','') as gross_source
    from jsonb_array_elements(rows) with ordinality as r(row, ord)
  ),
  fixed as (
    select
      ord,
      row ||
      jsonb_build_object(
        'is_gross_missing',
          case
            when gross_source = 'missing' or gross_num <= 0 or unit_num <= 0 then true
            else false
          end,
        'is_marketplace_gross_valid',
          case
            when gross_source = 'missing' or gross_num <= 0 or unit_num <= 0 then false
            else true
          end,
        'exclude_from_gross_total',
          case
            when gross_source = 'missing' or gross_num <= 0 or unit_num <= 0 then true
            else false
          end,
        'gross_missing_label',
          case
            when gross_source = 'missing' or gross_num <= 0 or unit_num <= 0
            then 'Harga marketplace belum tersedia'
            else null
          end,
        'gross_sales_display',
          case
            when gross_source = 'missing' or gross_num <= 0 or unit_num <= 0
            then 'Harga marketplace belum tersedia'
            else row->>'gross_sales'
          end,
        'harga_jual_per_item_display',
          case
            when gross_source = 'missing' or gross_num <= 0 or unit_num <= 0
            then 'Harga marketplace belum tersedia'
            else coalesce(row->>'harga_jual_per_item', row->>'unit_price', row->>'price_per_item', row->>'gross_per_item')
          end,
        'gross_missing_reason',
          case
            when gross_source = 'missing' or gross_num <= 0 or unit_num <= 0
            then 'Raw marketplace gross kosong atau 0. Data tidak dipalsukan dan tidak boleh dihitung sebagai gross valid.'
            else null
          end
      ) as row
    from src
  )
  select coalesce(jsonb_agg(row order by ord), '[]'::jsonb)
  into patched_rows
  from fixed;

  return j ||
    jsonb_build_object(
      'rows', patched_rows,
      'data', patched_rows,
      'items', patched_rows,
      'source', 'finance_sku_order_line_details_no_fake_display_flags_20260625',
      'delegate_source', coalesce(j->>'source',''),
      'core_delegate_source', coalesce(j->>'delegate_source','')
    );
end;
$$;

grant execute on function public.finance_sku_order_line_details(date,date,text,uuid,text,text,text,text,integer,integer)
to anon, authenticated, service_role;

notify pgrst, 'reload schema';