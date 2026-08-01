create or replace function public._finance_num_any_20260625(p_value text)
returns numeric
language plpgsql
immutable
as $$
declare
  v text;
begin
  v := trim(coalesce(p_value,''));
  if v = '' or lower(v) in ('null','nan','-') then
    return 0;
  end if;

  -- remove currency/string noise, keep digits, minus, dot, comma
  v := regexp_replace(v, '[^0-9,\.\-]', '', 'g');

  if v = '' or v = '-' then
    return 0;
  end if;

  -- common API numeric: 62900 or 62900.50
  if v ~ '^-?[0-9]+(\.[0-9]+)?$' then
    return v::numeric;
  end if;

  -- common IDR formatted: 62.900 or 62,900 -> 62900
  if v ~ '^-?[0-9]{1,3}([.,][0-9]{3})+$' then
    return replace(replace(v, '.', ''), ',', '')::numeric;
  end if;

  -- fallback: comma decimal
  if v ~ '^-?[0-9]+,[0-9]+$' then
    return replace(v, ',', '.')::numeric;
  end if;

  return 0;
exception when others then
  return 0;
end;
$$;

create or replace function public.finance_order_item_gross_from_json_20260625(
  p_item jsonb,
  p_order jsonb,
  p_qty numeric default 1
)
returns numeric
language plpgsql
stable
as $$
declare
  q numeric := greatest(coalesce(nullif(p_qty,0), 1), 1);
  total numeric := 0;
  unit numeric := 0;
begin
  total := coalesce(
    nullif(public._finance_num_any_20260625(p_item->>'gross_amount'),0),
    nullif(public._finance_num_any_20260625(p_item->>'gross_sales'),0),
    nullif(public._finance_num_any_20260625(p_item->>'gross_total'),0),
    nullif(public._finance_num_any_20260625(p_item->>'line_gross'),0),
    nullif(public._finance_num_any_20260625(p_item->>'item_gross'),0),
    nullif(public._finance_num_any_20260625(p_item->>'total_amount'),0),
    nullif(public._finance_num_any_20260625(p_item->>'paid_amount'),0),
    nullif(public._finance_num_any_20260625(p_item->>'payment_amount'),0),
    nullif(public._finance_num_any_20260625(p_item->>'seller_discounted_price'),0),
    nullif(public._finance_num_any_20260625(p_item->>'discounted_price'),0),
    nullif(public._finance_num_any_20260625(p_item->>'subtotal'),0),
    nullif(public._finance_num_any_20260625(p_item#>>'{raw_item,gross_amount}'),0),
    nullif(public._finance_num_any_20260625(p_item#>>'{raw_item,total_amount}'),0),
    nullif(public._finance_num_any_20260625(p_item#>>'{raw_item,paid_amount}'),0),
    nullif(public._finance_num_any_20260625(p_item#>>'{raw_item,seller_discounted_price}'),0),
    nullif(public._finance_num_any_20260625(p_item#>>'{raw_item,discounted_price}'),0),
    0
  );

  if total > 0 then
    return total;
  end if;

  unit := coalesce(
    nullif(public._finance_num_any_20260625(p_item->>'unit_gross_amount'),0),
    nullif(public._finance_num_any_20260625(p_item->>'unit_price'),0),
    nullif(public._finance_num_any_20260625(p_item->>'price'),0),
    nullif(public._finance_num_any_20260625(p_item->>'sale_price'),0),
    nullif(public._finance_num_any_20260625(p_item->>'original_price'),0),
    nullif(public._finance_num_any_20260625(p_item->>'sku_sale_price'),0),
    nullif(public._finance_num_any_20260625(p_item->>'sku_original_price'),0),
    nullif(public._finance_num_any_20260625(p_item->>'display_price'),0),
    nullif(public._finance_num_any_20260625(p_item#>>'{raw_item,unit_price}'),0),
    nullif(public._finance_num_any_20260625(p_item#>>'{raw_item,price}'),0),
    nullif(public._finance_num_any_20260625(p_item#>>'{raw_item,sale_price}'),0),
    nullif(public._finance_num_any_20260625(p_item#>>'{raw_item,original_price}'),0),
    nullif(public._finance_num_any_20260625(p_item#>>'{raw_item,sku_sale_price}'),0),
    nullif(public._finance_num_any_20260625(p_item#>>'{raw_item,sku_original_price}'),0),
    0
  );

  if unit > 0 then
    return unit * q;
  end if;

  -- last fallback: order gross only if item has no usable price
  return coalesce(
    nullif(public._finance_num_any_20260625(p_order->>'gross_amount'),0),
    nullif(public._finance_num_any_20260625(p_order->>'total_amount'),0),
    nullif(public._finance_num_any_20260625(p_order->>'paid_amount'),0),
    0
  );
end;
$$;

grant execute on function public._finance_num_any_20260625(text)
to anon, authenticated, service_role;

grant execute on function public.finance_order_item_gross_from_json_20260625(jsonb,jsonb,numeric)
to anon, authenticated, service_role;

do $$
begin
  if to_regprocedure('public.finance_sku_order_line_details_core_delegate_20260625(date,date,text,uuid,text,text,text,text,integer,integer)') is null then
    alter function public.finance_sku_order_line_details(date,date,text,uuid,text,text,text,text,integer,integer)
      rename to finance_sku_order_line_details_core_delegate_20260625;
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
  total_count integer := 0;
  v_page_size integer := least(greatest(coalesce(p_page_size,25),1),25);
begin
  j := public.finance_sku_order_line_details_core_delegate_20260625(
    p_start,p_end,p_marketplace,p_account_id,p_marketplace_sku,p_local_sku,p_search,p_payout_filter,p_page,v_page_size
  );

  rows := coalesce(j->'rows','[]'::jsonb);
  total_count := coalesce(nullif(j->>'total_count','')::integer, 0);

  with src as (
    select
      r.row,
      r.ord,
      greatest(public._finance_num_any_20260625(r.row->>'qty'), 1) as qty,
      public._finance_num_any_20260625(coalesce(r.row->>'gross_sales', r.row->>'gross_total', r.row->>'gross_amount', '0')) as row_gross
    from jsonb_array_elements(rows) with ordinality as r(row, ord)
  ),
  joined as (
    select
      s.*,
      oi.marketplace_order_item_id,
      o.marketplace_order_id,
      public.finance_order_item_gross_from_json_20260625(to_jsonb(oi), to_jsonb(o), s.qty) as db_gross
    from src s
    left join public.marketplace_order_items oi
      on oi.marketplace_order_item_id::text = s.row->>'marketplace_order_item_id'
    left join public.marketplace_orders o
      on o.marketplace_order_id = oi.marketplace_order_id
  ),
  fixed as (
    select
      ord,
      row ||
      jsonb_build_object(
        'gross_sales',
          case when row_gross > 0 then row_gross else coalesce(nullif(db_gross,0),0) end,
        'gross_amount',
          case when row_gross > 0 then row_gross else coalesce(nullif(db_gross,0),0) end,
        'gross_total',
          case when row_gross > 0 then row_gross else coalesce(nullif(db_gross,0),0) end,
        'harga_jual',
          case when row_gross > 0 then row_gross else coalesce(nullif(db_gross,0),0) end,
        'harga_jual_total',
          case when row_gross > 0 then row_gross else coalesce(nullif(db_gross,0),0) end,
        'harga_jual_per_item',
          round((case when row_gross > 0 then row_gross else coalesce(nullif(db_gross,0),0) end) / greatest(qty,1), 2),
        'unit_price',
          round((case when row_gross > 0 then row_gross else coalesce(nullif(db_gross,0),0) end) / greatest(qty,1), 2),
        'price_per_item',
          round((case when row_gross > 0 then row_gross else coalesce(nullif(db_gross,0),0) end) / greatest(qty,1), 2),
        'gross_per_item',
          round((case when row_gross > 0 then row_gross else coalesce(nullif(db_gross,0),0) end) / greatest(qty,1), 2),
        'gross_source',
          case
            when row_gross > 0 then 'row_gross'
            when coalesce(db_gross,0) > 0 then 'marketplace_order_items_json'
            else 'missing'
          end
      ) as row
    from joined
  )
  select coalesce(jsonb_agg(row order by ord), '[]'::jsonb)
  into patched_rows
  from fixed;

  return jsonb_build_object(
    'rows', patched_rows,
    'data', patched_rows,
    'items', patched_rows,
    'page', greatest(coalesce(p_page,1),1),
    'page_size', v_page_size,
    'total', total_count,
    'count', total_count,
    'total_count', total_count,
    'total_pages', greatest(ceil(coalesce(total_count,0)::numeric / v_page_size)::integer, 1),
    'has_more', greatest(coalesce(p_page,1),1) < greatest(ceil(coalesce(total_count,0)::numeric / v_page_size)::integer, 1),
    'source', 'finance_sku_order_line_details_gross_unit_price_patch_20260625',
    'delegate_source', coalesce(j->>'source',''),
    'requested_payout_filter', p_payout_filter
  );
end;
$$;

grant execute on function public.finance_sku_order_line_details(date,date,text,uuid,text,text,text,text,integer,integer)
to anon, authenticated, service_role;

notify pgrst, 'reload schema';