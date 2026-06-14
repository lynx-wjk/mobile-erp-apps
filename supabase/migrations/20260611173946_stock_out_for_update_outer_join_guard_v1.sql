do $$
declare
  v_def text;
  v_new text;
begin
  select pg_get_functiondef(
    'public.marketplace_scan_order_item_manual_override_by_resi(uuid,text,uuid,uuid,text)'::regprocedure
  )
    into v_def;

  v_new := regexp_replace(
    v_def,
    '(and o\.marketplace_order_id = v_order_id\s+)for update;',
    E'\\1for update of o;',
    'i'
  );

  if v_new is distinct from v_def then
    execute v_new;
  end if;

  select pg_get_functiondef(
    'public.marketplace_finalize_scanned_order_stock_out(uuid,uuid)'::regprocedure
  )
    into v_def;

  v_new := regexp_replace(
    v_def,
    '(and o\.marketplace_order_id = p_marketplace_order_id\s+)for update;',
    E'\\1for update of o;',
    'i'
  );

  if v_new is distinct from v_def then
    execute v_new;
  end if;
end $$;

comment on function public.marketplace_scan_order_item_manual_override_by_resi(uuid, text, uuid, uuid, text) is
'Manual stock-out SKU override by resi. Locks only marketplace_orders alias during order lookup to avoid FOR UPDATE on nullable left join tables.';

comment on function public.marketplace_finalize_scanned_order_stock_out(uuid, uuid) is
'Finalizes scanned marketplace stock out. Locks only marketplace_orders alias during order lookup to avoid FOR UPDATE on nullable left join tables.';
