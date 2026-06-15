-- 9I-E canonical marketplace tenant trigger functions.
-- Repoints six marketplace tenant assignment triggers to canonical names.
-- Old *_v1 trigger functions are intentionally kept; no DROP FUNCTION here.

create or replace function public.marketplace_assign_products_tenant()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_tenant_id uuid;
begin
  if NEW.tenant_id is null and NEW.marketplace_account_id is not null then
    select ma.tenant_id into v_tenant_id
    from public.marketplace_accounts ma
    where ma.marketplace_account_id = NEW.marketplace_account_id
    limit 1;
    NEW.tenant_id := v_tenant_id;
  end if;
  return NEW;
end;
$function$;

create or replace function public.marketplace_assign_stock_sync_jobs_tenant()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_tenant_id uuid;
begin
  if NEW.tenant_id is null and NEW.marketplace_account_id is not null then
    select ma.tenant_id into v_tenant_id
    from public.marketplace_accounts ma
    where ma.marketplace_account_id = NEW.marketplace_account_id
    limit 1;
    NEW.tenant_id := v_tenant_id;
  end if;
  return NEW;
end;
$function$;

create or replace function public.marketplace_assign_sync_logs_tenant()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_tenant_id uuid;
begin
  if NEW.tenant_id is null then
    if NEW.marketplace_account_id is not null then
      select ma.tenant_id into v_tenant_id
      from public.marketplace_accounts ma
      where ma.marketplace_account_id = NEW.marketplace_account_id
      limit 1;
      NEW.tenant_id := v_tenant_id;
    elsif NEW.sync_job_id is not null then
      select j.tenant_id into v_tenant_id
      from public.marketplace_stock_sync_jobs j
      where j.sync_job_id = NEW.sync_job_id
      limit 1;
      NEW.tenant_id := v_tenant_id;
    end if;
  end if;
  return NEW;
end;
$function$;

create or replace function public.marketplace_assign_order_scan_logs_tenant()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_tenant_id uuid;
begin
  if NEW.tenant_id is null and NEW.marketplace_order_id is not null then
    select o.tenant_id into v_tenant_id
    from public.marketplace_orders o
    where o.marketplace_order_id = NEW.marketplace_order_id
    limit 1;
    NEW.tenant_id := v_tenant_id;
  end if;
  return NEW;
end;
$function$;

create or replace function public.marketplace_assign_closing_books_tenant()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_tenant_id uuid;
begin
  if NEW.tenant_id is null and NEW.created_by is not null then
    select u.tenant_id into v_tenant_id
    from public.users u
    where u.user_id = NEW.created_by
    limit 1;
    NEW.tenant_id := v_tenant_id;
  end if;
  return NEW;
end;
$function$;

create or replace function public.marketplace_assign_closing_book_files_tenant()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_tenant_id uuid;
begin
  if NEW.tenant_id is null and NEW.closing_book_id is not null then
    select b.tenant_id into v_tenant_id
    from public.marketplace_closing_books b
    where b.closing_book_id = NEW.closing_book_id
    limit 1;
    NEW.tenant_id := v_tenant_id;
  end if;
  return NEW;
end;
$function$;

do $$
declare
  r record;
  v_def text;
begin
  for r in
    select *
    from (
      values
        ('marketplace_products', 'trg_marketplace_products_tenant_v1', 'trg_marketplace_products_tenant', 'marketplace_assign_products_tenant_v1', 'marketplace_assign_products_tenant'),
        ('marketplace_stock_sync_jobs', 'trg_marketplace_stock_sync_jobs_tenant_v1', 'trg_marketplace_stock_sync_jobs_tenant', 'marketplace_assign_stock_sync_jobs_tenant_v1', 'marketplace_assign_stock_sync_jobs_tenant'),
        ('marketplace_sync_logs', 'trg_marketplace_sync_logs_tenant_v1', 'trg_marketplace_sync_logs_tenant', 'marketplace_assign_sync_logs_tenant_v1', 'marketplace_assign_sync_logs_tenant'),
        ('marketplace_order_scan_logs', 'trg_marketplace_order_scan_logs_tenant_v1', 'trg_marketplace_order_scan_logs_tenant', 'marketplace_assign_order_scan_logs_tenant_v1', 'marketplace_assign_order_scan_logs_tenant'),
        ('marketplace_closing_books', 'trg_marketplace_closing_books_tenant_v1', 'trg_marketplace_closing_books_tenant', 'marketplace_assign_closing_books_tenant_v1', 'marketplace_assign_closing_books_tenant'),
        ('marketplace_closing_book_files', 'trg_marketplace_closing_book_files_tenant_v1', 'trg_marketplace_closing_book_files_tenant', 'marketplace_assign_closing_book_files_tenant_v1', 'marketplace_assign_closing_book_files_tenant')
    ) as x(table_name, old_trigger_name, new_trigger_name, old_function_name, new_function_name)
  loop
    select pg_get_triggerdef(t.oid, true)
      into v_def
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = r.table_name
      and t.tgname = r.old_trigger_name
      and not t.tgisinternal;

    if v_def is null then
      raise exception 'Old trigger not found: %.%', r.table_name, r.old_trigger_name;
    end if;

    execute format('drop trigger if exists %I on public.%I', r.old_trigger_name, r.table_name);

    v_def := replace(
      v_def,
      'CREATE TRIGGER ' || r.old_trigger_name,
      'CREATE TRIGGER ' || r.new_trigger_name
    );

    v_def := replace(
      v_def,
      'EXECUTE FUNCTION ' || r.old_function_name || '()',
      'EXECUTE FUNCTION public.' || r.new_function_name || '()'
    );

    v_def := replace(
      v_def,
      'EXECUTE FUNCTION public.' || r.old_function_name || '()',
      'EXECUTE FUNCTION public.' || r.new_function_name || '()'
    );

    execute v_def;
  end loop;
end $$;

notify pgrst, 'reload schema';
