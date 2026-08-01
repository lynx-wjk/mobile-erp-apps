do $$
declare
  v_def text;
  v_old text;
  v_new text;
begin
  select pg_get_functiondef(p.oid)
    into v_def
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'finance_sku_order_details_v24_6_82o'
    and pg_get_function_arguments(p.oid) = 'p_start date DEFAULT NULL::date, p_end date DEFAULT NULL::date, p_marketplace text DEFAULT NULL::text, p_account_id uuid DEFAULT NULL::uuid, p_marketplace_sku text DEFAULT NULL::text, p_local_sku text DEFAULT NULL::text, p_search text DEFAULT NULL::text, p_payout_filter text DEFAULT ''all''::text, p_page integer DEFAULT 1, p_page_size integer DEFAULT 20'
  limit 1;

  if v_def is null then
    raise exception 'finance_sku_order_details_v24_6_82o canonical function not found';
  end if;

  v_old := '      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone ''Asia/Jakarta'')::date between v_start and v_end
  ),';

  v_new := '      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone ''Asia/Jakarta'')::date between v_start and v_end
      and not (
        upper(coalesce(o.order_status, o.status, o.raw_order->>''status'', '''')) like any (
          array[''%CANCEL%'', ''%UNPAID%'', ''%REFUND%'', ''%RETURN%'', ''%FAILED%'', ''%CLOSE%'']
        )
      )
  ),';

  if position(v_new in v_def) = 0 then
    if position(v_old in v_def) = 0 then
      raise exception 'expected valid_orders predicate block not found in finance_sku_order_details_v24_6_82o';
    end if;

    v_def := replace(v_def, v_old, v_new);
  end if;

  v_def := replace(
    v_def,
    '''version'', ''v24_6_82o_details_strict_status_filters_2026_06_09''',
    '''version'', ''v24_6_82o_details_exclude_invalid_order_status_2026_06_11'''
  );

  execute v_def;
end $$;
