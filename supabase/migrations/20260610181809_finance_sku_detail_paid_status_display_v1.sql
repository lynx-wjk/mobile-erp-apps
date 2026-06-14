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
  limit 1;

  if v_def is null then
    raise exception 'finance_sku_order_details_v24_6_82o not found';
  end if;

  v_old := '''status'', order_status,
      ''order_status'', order_status,
      ''order_date'', order_date_wib,';

  v_new := '''status'', case
        when payout_status_clean in (''Settled'', ''Payout Minus'') then payout_status_clean
        else order_status
      end,
      ''order_status'', case
        when payout_status_clean in (''Settled'', ''Payout Minus'') then payout_status_clean
        else order_status
      end,
      ''status_order'', case
        when payout_status_clean in (''Settled'', ''Payout Minus'') then payout_status_clean
        else order_status
      end,
      ''live_status'', order_status,
      ''live_order_status'', order_status,
      ''marketplace_order_status'', order_status,
      ''order_date'', order_date_wib,';

  if position(v_new in v_def) = 0 then
    if position(v_old in v_def) = 0 then
      raise exception 'expected status output block not found in finance_sku_order_details_v24_6_82o';
    end if;
    v_def := replace(v_def, v_old, v_new);
  end if;

  v_def := replace(
    v_def,
    '''version'', ''v24_6_82o_details_exclude_invalid_order_status_2026_06_11''',
    '''version'', ''v24_6_82o_details_finance_status_display_2026_06_11'''
  );

  execute v_def;
end $$;
