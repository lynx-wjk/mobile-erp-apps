-- 9I-D small trigger canonicalization batch.
-- Creates canonical trigger functions and repoints only two low-risk triggers.
-- Old trigger functions are intentionally kept as backing/history; no DROP FUNCTION here.

create or replace function public.finance_operational_expenses_fill_description()
returns trigger
language plpgsql
as $function$
begin
  new.description := coalesce(nullif(btrim(new.description), ''), nullif(btrim(new.category), ''), 'Biaya operasional');
  return new;
end;
$function$;

create or replace function public.marketplace_orders_sync_status_alias()
returns trigger
language plpgsql
as $function$
declare
  v_order_status text;
  v_raw_status text;
  v_canonical text;
begin
  v_order_status := nullif(btrim(coalesce(new.order_status, '')), '');
  v_raw_status := nullif(btrim(coalesce(new.raw_order->>'status', '')), '');
  v_canonical := coalesce(v_order_status, v_raw_status);

  if v_canonical is not null
     and (v_raw_status is null or upper(v_raw_status) = upper(v_canonical)) then
    new.order_status := upper(v_canonical);
    new.status := upper(v_canonical);
    new.order_status_label := upper(v_canonical);
  end if;

  return new;
end;
$function$;

do $$
declare
  v_def text;
begin
  select pg_get_triggerdef(t.oid, true)
    into v_def
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname = 'finance_operational_expenses'
    and t.tgname = 'trg_finance_operational_expenses_fill_description_v24_6_75'
    and not t.tgisinternal;

  if v_def is null then
    raise exception 'Old trigger not found: trg_finance_operational_expenses_fill_description_v24_6_75';
  end if;

  execute 'drop trigger if exists trg_finance_operational_expenses_fill_description_v24_6_75 on public.finance_operational_expenses';

  v_def := replace(
    v_def,
    'CREATE TRIGGER trg_finance_operational_expenses_fill_description_v24_6_75',
    'CREATE TRIGGER trg_finance_operational_expenses_fill_description'
  );
  v_def := replace(
    v_def,
    'EXECUTE FUNCTION finance_operational_expenses_fill_description_v24_6_75()',
    'EXECUTE FUNCTION public.finance_operational_expenses_fill_description()'
  );
  v_def := replace(
    v_def,
    'EXECUTE FUNCTION public.finance_operational_expenses_fill_description_v24_6_75()',
    'EXECUTE FUNCTION public.finance_operational_expenses_fill_description()'
  );

  execute v_def;
end $$;

do $$
declare
  v_def text;
begin
  select pg_get_triggerdef(t.oid, true)
    into v_def
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname = 'marketplace_orders'
    and t.tgname = 'trg_marketplace_orders_sync_status_alias_v24_6_82'
    and not t.tgisinternal;

  if v_def is null then
    raise exception 'Old trigger not found: trg_marketplace_orders_sync_status_alias_v24_6_82';
  end if;

  execute 'drop trigger if exists trg_marketplace_orders_sync_status_alias_v24_6_82 on public.marketplace_orders';

  v_def := replace(
    v_def,
    'CREATE TRIGGER trg_marketplace_orders_sync_status_alias_v24_6_82',
    'CREATE TRIGGER trg_marketplace_orders_sync_status_alias'
  );
  v_def := replace(
    v_def,
    'EXECUTE FUNCTION marketplace_orders_sync_status_alias_v24_6_82()',
    'EXECUTE FUNCTION public.marketplace_orders_sync_status_alias()'
  );
  v_def := replace(
    v_def,
    'EXECUTE FUNCTION public.marketplace_orders_sync_status_alias_v24_6_82()',
    'EXECUTE FUNCTION public.marketplace_orders_sync_status_alias()'
  );

  execute v_def;
end $$;

notify pgrst, 'reload schema';
