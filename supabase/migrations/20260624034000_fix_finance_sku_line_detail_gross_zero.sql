create or replace function public._finance_num_safe_20260624(p_value text)
returns numeric
language sql
immutable
as $$
  with cleaned as (
    select regexp_replace(coalesce(p_value, ''), '[^0-9\.\-]', '', 'g') as v
  )
  select case
    when v ~ '^-?[0-9]+(\.[0-9]+)?$' then v::numeric
    else 0::numeric
  end
  from cleaned;
$$;

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
  p_page_size integer default 20
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_tenant_id uuid := public.app_current_tenant_id_or_default();
  v_base jsonb;
  v_rows jsonb;
  v_new_rows jsonb := '[]'::jsonb;
  v_row jsonb;
  v_qty numeric;
  v_existing_gross numeric;
  v_gross numeric;
  v_order_key text;
  v_marketplace_sku text;
  v_seller_sku text;
  v_local_sku text;
  v_marketplace text := lower(trim(coalesce(p_marketplace, '')));
begin
  if v_marketplace in ('all', 'semua', 'semua platform', '-') then
    v_marketplace := '';
  end if;

  v_base := public.finance_sku_order_line_details_base_20260622(
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

  v_rows := case
    when jsonb_typeof(v_base) = 'array' then v_base
    when jsonb_typeof(v_base) = 'object' and jsonb_typeof(v_base->'rows') = 'array' then v_base->'rows'
    when jsonb_typeof(v_base) = 'object' and jsonb_typeof(v_base->'data') = 'array' then v_base->'data'
    when jsonb_typeof(v_base) = 'object' and jsonb_typeof(v_base->'items') = 'array' then v_base->'items'
    else '[]'::jsonb
  end;

  for v_row in
    select value from jsonb_array_elements(coalesce(v_rows, '[]'::jsonb))
  loop
    v_qty := greatest(
      1,
      public._finance_num_safe_20260624(v_row->>'qty'),
      public._finance_num_safe_20260624(v_row->>'quantity')
    );

    v_existing_gross := greatest(
      public._finance_num_safe_20260624(v_row->>'gross'),
      public._finance_num_safe_20260624(v_row->>'gross_amount'),
      public._finance_num_safe_20260624(v_row->>'gross_total'),
      public._finance_num_safe_20260624(v_row->>'order_line_gross_total'),
      public._finance_num_safe_20260624(v_row->>'unit_gross_amount') * v_qty,
      public._finance_num_safe_20260624(v_row->>'gross_per_item') * v_qty
    );

    if v_existing_gross <= 0 then
      v_order_key := lower(nullif(coalesce(
        v_row->>'order_id',
        v_row->>'order_sn',
        v_row->>'external_order_id',
        v_row->>'ref',
        v_row->>'order',
        ''
      ), ''));

      v_marketplace_sku := lower(nullif(coalesce(
        v_row->>'marketplace_sku_id',
        v_row->>'marketplace_sku',
        ''
      ), ''));

      v_seller_sku := lower(nullif(coalesce(
        v_row->>'marketplace_seller_sku',
        v_row->>'seller_sku',
        ''
      ), ''));

      v_local_sku := lower(nullif(coalesce(
        v_row->>'local_sku',
        v_row->>'sku',
        ''
      ), ''));

      v_gross := 0;

      -- Source 1: finance item exact / raw settlement detail.
      select c.val
        into v_gross
      from public.marketplace_finance_items fi
      cross join lateral (
        values
          (abs(coalesce(fi.gross_amount, 0))),
          (abs(coalesce(fi.expected_amount, 0))),
          (abs(public._finance_num_safe_20260624(fi.raw_finance #>> '{detail,revenue_breakdown,subtotal_before_discount_amount}'))),
          (abs(public._finance_num_safe_20260624(fi.raw_finance #>> '{detail,subtotal_before_discount_amount}'))),
          (abs(public._finance_num_safe_20260624(fi.raw_finance #>> '{detail,gross_amount}'))),
          (abs(public._finance_num_safe_20260624(fi.raw_finance #>> '{gross_amount}')))
      ) as c(val)
      where fi.tenant_id = v_tenant_id
        and c.val > 0
        and (v_marketplace = '' or lower(coalesce(fi.marketplace, '')) = v_marketplace)
        and (p_account_id is null or fi.marketplace_account_id = p_account_id)
        and (
          v_order_key is null
          or lower(coalesce(fi.order_sn, '')) = v_order_key
          or lower(coalesce(fi.order_id, '')) = v_order_key
          or lower(coalesce(fi.external_order_id, '')) = v_order_key
          or lower(coalesce(fi.remote_order_id, '')) = v_order_key
          or fi.marketplace_order_id::text = v_order_key
        )
        and (
          coalesce(v_marketplace_sku, '') = ''
          or lower(coalesce(fi.marketplace_sku, '')) = v_marketplace_sku
          or lower(coalesce(fi.marketplace_seller_sku, '')) = v_seller_sku
          or lower(coalesce(fi.seller_sku, '')) = v_seller_sku
          or lower(coalesce(fi.local_sku, '')) = v_local_sku
        )
      order by
        case when abs(coalesce(fi.gross_amount, 0)) > 0 then 0 else 1 end,
        fi.updated_at desc nulls last,
        fi.created_at desc nulls last
      limit 1;

      -- Source 2: marketplace order item gross fallback.
      if coalesce(v_gross, 0) <= 0 then
        select c.val
          into v_gross
        from public.marketplace_order_items oi
        cross join lateral (
          values
            (abs(coalesce(oi.gross_amount, 0))),
            (abs(coalesce(oi.unit_gross_amount, 0)) * greatest(1, coalesce(nullif(oi.quantity, 0), nullif(oi.qty, 0), 1)))
        ) as c(val)
        where oi.tenant_id = v_tenant_id
          and c.val > 0
          and (v_marketplace = '' or lower(coalesce(oi.marketplace, '')) = v_marketplace)
          and (p_account_id is null or oi.marketplace_account_id = p_account_id)
          and (
            v_order_key is null
            or lower(coalesce(oi.order_sn, '')) = v_order_key
            or lower(coalesce(oi.external_order_id, '')) = v_order_key
            or oi.marketplace_order_id::text = v_order_key
          )
          and (
            coalesce(v_marketplace_sku, '') = ''
            or lower(coalesce(oi.marketplace_sku_id, '')) = v_marketplace_sku
            or lower(coalesce(oi.marketplace_sku, '')) = v_marketplace_sku
            or lower(coalesce(oi.remote_sku_id, '')) = v_marketplace_sku
            or lower(coalesce(oi.marketplace_seller_sku, '')) = v_seller_sku
            or lower(coalesce(oi.seller_sku, '')) = v_seller_sku
            or lower(coalesce(oi.local_sku, '')) = v_local_sku
            or lower(coalesce(oi.mapped_local_sku, '')) = v_local_sku
          )
        order by
          case when abs(coalesce(oi.gross_amount, 0)) > 0 then 0 else 1 end,
          oi.updated_at desc nulls last,
          oi.created_at desc nulls last
        limit 1;
      end if;

      if coalesce(v_gross, 0) > 0 then
        v_row := jsonb_set(v_row, '{gross}', to_jsonb(v_gross), true);
        v_row := jsonb_set(v_row, '{gross_amount}', to_jsonb(v_gross), true);
        v_row := jsonb_set(v_row, '{gross_total}', to_jsonb(v_gross), true);
        v_row := jsonb_set(v_row, '{order_line_gross_total}', to_jsonb(v_gross), true);
        v_row := jsonb_set(v_row, '{gross_per_item}', to_jsonb(v_gross / v_qty), true);
        v_row := jsonb_set(v_row, '{gross_fix_source}', to_jsonb('finance_sku_order_line_details_gross_enrich_20260624'::text), true);
      end if;
    end if;

    v_new_rows := v_new_rows || jsonb_build_array(v_row);
  end loop;

  if jsonb_typeof(v_base) = 'array' then
    return v_new_rows;
  end if;

  if jsonb_typeof(v_base) = 'object' then
    if jsonb_typeof(v_base->'rows') = 'array' then
      v_base := jsonb_set(v_base, '{rows}', v_new_rows, true);
    elsif jsonb_typeof(v_base->'data') = 'array' then
      v_base := jsonb_set(v_base, '{data}', v_new_rows, true);
    elsif jsonb_typeof(v_base->'items') = 'array' then
      v_base := jsonb_set(v_base, '{items}', v_new_rows, true);
    end if;

    v_base := jsonb_set(v_base, '{gross_enrich_source}', to_jsonb('finance_sku_order_line_details_wrapper_20260624'::text), true);
    return v_base;
  end if;

  return v_base;
end;
$function$;

revoke all on function public._finance_num_safe_20260624(text) from public;
grant execute on function public._finance_num_safe_20260624(text) to authenticated, service_role;

revoke all on function public.finance_sku_order_line_details(date, date, text, uuid, text, text, text, text, integer, integer) from public;
grant execute on function public.finance_sku_order_line_details(date, date, text, uuid, text, text, text, text, integer, integer) to authenticated, service_role;
