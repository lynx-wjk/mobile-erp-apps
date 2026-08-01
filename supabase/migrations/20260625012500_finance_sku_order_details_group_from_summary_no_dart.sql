do $$
begin
  if to_regprocedure('public.finance_sku_order_details_core_20260625(date,date,text,uuid,text,text,text,text,integer,integer)') is null then
    alter function public.finance_sku_order_details(date,date,text,uuid,text,text,text,text,integer,integer)
      rename to finance_sku_order_details_core_20260625;
  end if;
end $$;

create or replace function public._finance_num_20260625(p_value text)
returns numeric
language sql
immutable
as $$
  select case
    when coalesce(p_value,'') ~ '^-?[0-9]+(\.[0-9]+)?$' then p_value::numeric
    else 0::numeric
  end;
$$;

create or replace function public._finance_int_20260625(p_value text)
returns integer
language sql
immutable
as $$
  select case
    when coalesce(p_value,'') ~ '^-?[0-9]+$' then p_value::integer
    else 0::integer
  end;
$$;

create or replace function public.finance_sku_order_details(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null,
  p_marketplace_sku text default null,
  p_local_sku text default null,
  p_search text default null,
  p_payout_filter text default 'all',
  p_page integer default 1,
  p_page_size integer default 20
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '20s'
as $$
declare
  v_detail boolean := nullif(trim(coalesce(p_marketplace_sku,'')), '') is not null
    or nullif(trim(coalesce(p_local_sku,'')), '') is not null
    or nullif(trim(coalesce(p_search,'')), '') is not null;
  v_page integer := greatest(coalesce(p_page,1),1);
  v_page_size integer := least(greatest(coalesce(p_page_size,20),1),25);
  v_offset integer := (greatest(coalesce(p_page,1),1)-1) * least(greatest(coalesce(p_page_size,20),1),25);
  v_filter text := lower(trim(coalesce(p_payout_filter,'all')));
  v_summary jsonb;
  v_rows jsonb := '[]'::jsonb;
  v_total integer := 0;
begin
  if v_detail then
    return public.finance_sku_order_details_core_20260625(
      p_start,p_end,p_marketplace,p_account_id,p_marketplace_sku,p_local_sku,p_search,p_payout_filter,p_page,p_page_size
    );
  end if;

  v_summary := public.finance_sku_payout_count_summary(p_start,p_end,p_marketplace,p_account_id);

  with src as (
    select
      row_number() over (
        order by
          case when lower(coalesce(x->>'marketplace','')) like '%tiktok%' then 0 else 1 end,
          public._finance_num_20260625(x->>'all_qty') desc,
          public._finance_num_20260625(x->>'paid_gross_total') desc,
          coalesce(x->>'local_sku', x->>'marketplace_sku', '')
      ) rn,
      x
    from jsonb_array_elements(coalesce(v_summary->'rows','[]'::jsonb)) x
    where v_filter in ('all','')
       or (
         v_filter in ('paid','settled','payout','sudah payout')
         and public._finance_num_20260625(x->>'paid_qty') > 0
       )
       or (
         v_filter in ('unpaid','pending','belum payout','no payout')
         and public._finance_num_20260625(x->>'unpaid_qty') > 0
       )
  ),
  counted as (
    select count(*)::integer c from src
  ),
  paged as (
    select x
    from src
    where rn > v_offset and rn <= v_offset + v_page_size
    order by rn
  )
  select
    coalesce(jsonb_agg(
      x || jsonb_build_object(
        'source','finance_sku_order_details_group_from_payout_summary_20260625',
        'sku', coalesce(nullif(x->>'local_sku',''), nullif(x->>'marketplace_sku',''), '-'),
        'quantity', public._finance_num_20260625(x->>'all_qty'),
        'qty', public._finance_num_20260625(x->>'all_qty'),
        'qty_total', public._finance_num_20260625(x->>'all_qty'),
        'gross_sales', public._finance_num_20260625(x->>'paid_gross_total') + public._finance_num_20260625(x->>'unpaid_gross_total'),
        'gross_total', public._finance_num_20260625(x->>'paid_gross_total') + public._finance_num_20260625(x->>'unpaid_gross_total'),
        'payout_total', public._finance_num_20260625(x->>'paid_payout_total'),
        'payout_amount', public._finance_num_20260625(x->>'paid_payout_total'),
        'received_amount', public._finance_num_20260625(x->>'paid_payout_total'),
        'net_settlement', public._finance_num_20260625(x->>'paid_payout_total'),
        'order_count', public._finance_int_20260625(x->>'all_rows'),
        'paid_order_count', public._finance_int_20260625(x->>'paid_rows'),
        'unpaid_order_count', public._finance_int_20260625(x->>'unpaid_rows'),
        'settled_qty', public._finance_num_20260625(x->>'paid_qty'),
        'qty_settled', public._finance_num_20260625(x->>'paid_qty'),
        'hpp', public._finance_num_20260625(x->>'hpp'),
        'hpp_total', public._finance_num_20260625(x->>'hpp_total'),
        'total_hpp', public._finance_num_20260625(x->>'hpp_total'),
        'unit_hpp', public._finance_num_20260625(x->>'unit_hpp')
      )
    ), '[]'::jsonb),
    (select c from counted)
  into v_rows, v_total
  from paged;

  return jsonb_build_object(
    'rows', coalesce(v_rows,'[]'::jsonb),
    'page', v_page,
    'page_size', v_page_size,
    'total', coalesce(v_total,0),
    'total_count', coalesce(v_total,0),
    'total_pages', greatest(ceil(coalesce(v_total,0)::numeric / v_page_size)::integer, 1),
    'source', 'finance_sku_order_details_group_from_payout_summary_20260625',
    'summary_source', v_summary->>'version'
  );
end;
$$;

grant execute on function public.finance_sku_order_details(date,date,text,uuid,text,text,text,text,integer,integer)
to anon, authenticated, service_role;

notify pgrst, 'reload schema';