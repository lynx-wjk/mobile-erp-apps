-- Add tenant_id to marketplace support tables that previously relied on
-- role-only marketplace_can_read/write RLS helpers.

alter table public.marketplace_products
  add column if not exists tenant_id uuid;

alter table public.marketplace_stock_sync_jobs
  add column if not exists tenant_id uuid;

alter table public.marketplace_sync_logs
  add column if not exists tenant_id uuid;

alter table public.marketplace_order_scan_logs
  add column if not exists tenant_id uuid;

alter table public.marketplace_closing_books
  add column if not exists tenant_id uuid;

alter table public.marketplace_closing_book_files
  add column if not exists tenant_id uuid;

update public.marketplace_products mp
   set tenant_id = ma.tenant_id
  from public.marketplace_accounts ma
 where mp.tenant_id is null
   and ma.marketplace_account_id = mp.marketplace_account_id;

update public.marketplace_stock_sync_jobs j
   set tenant_id = ma.tenant_id
  from public.marketplace_accounts ma
 where j.tenant_id is null
   and ma.marketplace_account_id = j.marketplace_account_id;

update public.marketplace_sync_logs l
   set tenant_id = ma.tenant_id
  from public.marketplace_accounts ma
 where l.tenant_id is null
   and ma.marketplace_account_id = l.marketplace_account_id;

update public.marketplace_sync_logs l
   set tenant_id = j.tenant_id
  from public.marketplace_stock_sync_jobs j
 where l.tenant_id is null
   and j.sync_job_id = l.sync_job_id;

update public.marketplace_order_scan_logs s
   set tenant_id = o.tenant_id
  from public.marketplace_orders o
 where s.tenant_id is null
   and o.marketplace_order_id = s.marketplace_order_id;

update public.marketplace_closing_books b
   set tenant_id = u.tenant_id
  from public.users u
 where b.tenant_id is null
   and u.user_id = b.created_by;

update public.marketplace_closing_book_files f
   set tenant_id = b.tenant_id
  from public.marketplace_closing_books b
 where f.tenant_id is null
   and b.closing_book_id = f.closing_book_id;

create index if not exists marketplace_products_tenant_idx
  on public.marketplace_products (tenant_id);

create index if not exists marketplace_stock_sync_jobs_tenant_idx
  on public.marketplace_stock_sync_jobs (tenant_id);

create index if not exists marketplace_sync_logs_tenant_created_idx
  on public.marketplace_sync_logs (tenant_id, created_at desc);

create index if not exists marketplace_order_scan_logs_tenant_idx
  on public.marketplace_order_scan_logs (tenant_id);

create index if not exists marketplace_closing_books_tenant_idx
  on public.marketplace_closing_books (tenant_id);

create index if not exists marketplace_closing_book_files_tenant_idx
  on public.marketplace_closing_book_files (tenant_id);

create or replace function public.marketplace_assign_support_table_tenant_v1()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tenant_id uuid;
begin
  if TG_TABLE_NAME in ('marketplace_products', 'marketplace_stock_sync_jobs', 'marketplace_sync_logs') then
    if NEW.tenant_id is null and NEW.marketplace_account_id is not null then
      select ma.tenant_id
        into v_tenant_id
      from public.marketplace_accounts ma
      where ma.marketplace_account_id = NEW.marketplace_account_id
      limit 1;
      NEW.tenant_id := v_tenant_id;
    end if;
  end if;

  if TG_TABLE_NAME = 'marketplace_sync_logs' and NEW.tenant_id is null and NEW.sync_job_id is not null then
    select j.tenant_id
      into v_tenant_id
    from public.marketplace_stock_sync_jobs j
    where j.sync_job_id = NEW.sync_job_id
    limit 1;
    NEW.tenant_id := v_tenant_id;
  end if;

  if TG_TABLE_NAME = 'marketplace_order_scan_logs' and NEW.tenant_id is null and NEW.marketplace_order_id is not null then
    select o.tenant_id
      into v_tenant_id
    from public.marketplace_orders o
    where o.marketplace_order_id = NEW.marketplace_order_id
    limit 1;
    NEW.tenant_id := v_tenant_id;
  end if;

  if TG_TABLE_NAME = 'marketplace_closing_books' and NEW.tenant_id is null and NEW.created_by is not null then
    select u.tenant_id
      into v_tenant_id
    from public.users u
    where u.user_id = NEW.created_by
    limit 1;
    NEW.tenant_id := v_tenant_id;
  end if;

  if TG_TABLE_NAME = 'marketplace_closing_book_files' and NEW.tenant_id is null and NEW.closing_book_id is not null then
    select b.tenant_id
      into v_tenant_id
    from public.marketplace_closing_books b
    where b.closing_book_id = NEW.closing_book_id
    limit 1;
    NEW.tenant_id := v_tenant_id;
  end if;

  return NEW;
end;
$$;

drop trigger if exists trg_marketplace_products_tenant_v1 on public.marketplace_products;
create trigger trg_marketplace_products_tenant_v1
before insert or update on public.marketplace_products
for each row execute function public.marketplace_assign_support_table_tenant_v1();

drop trigger if exists trg_marketplace_stock_sync_jobs_tenant_v1 on public.marketplace_stock_sync_jobs;
create trigger trg_marketplace_stock_sync_jobs_tenant_v1
before insert or update on public.marketplace_stock_sync_jobs
for each row execute function public.marketplace_assign_support_table_tenant_v1();

drop trigger if exists trg_marketplace_sync_logs_tenant_v1 on public.marketplace_sync_logs;
create trigger trg_marketplace_sync_logs_tenant_v1
before insert or update on public.marketplace_sync_logs
for each row execute function public.marketplace_assign_support_table_tenant_v1();

drop trigger if exists trg_marketplace_order_scan_logs_tenant_v1 on public.marketplace_order_scan_logs;
create trigger trg_marketplace_order_scan_logs_tenant_v1
before insert or update on public.marketplace_order_scan_logs
for each row execute function public.marketplace_assign_support_table_tenant_v1();

drop trigger if exists trg_marketplace_closing_books_tenant_v1 on public.marketplace_closing_books;
create trigger trg_marketplace_closing_books_tenant_v1
before insert or update on public.marketplace_closing_books
for each row execute function public.marketplace_assign_support_table_tenant_v1();

drop trigger if exists trg_marketplace_closing_book_files_tenant_v1 on public.marketplace_closing_book_files;
create trigger trg_marketplace_closing_book_files_tenant_v1
before insert or update on public.marketplace_closing_book_files
for each row execute function public.marketplace_assign_support_table_tenant_v1();

do $$
declare
  v_table text;
  v_tables text[] := array[
    'marketplace_products',
    'marketplace_stock_sync_jobs',
    'marketplace_sync_logs',
    'marketplace_order_scan_logs',
    'marketplace_closing_books',
    'marketplace_closing_book_files'
  ];
begin
  foreach v_table in array v_tables loop
    execute format('alter table public.%I enable row level security', v_table);
    execute format('drop policy if exists marketplace_read_policy on public.%I', v_table);
    execute format('drop policy if exists marketplace_insert_policy on public.%I', v_table);
    execute format('drop policy if exists marketplace_update_policy on public.%I', v_table);
    execute format('drop policy if exists marketplace_delete_policy on public.%I', v_table);
    execute format('drop policy if exists tenant_select on public.%I', v_table);
    execute format('drop policy if exists tenant_insert on public.%I', v_table);
    execute format('drop policy if exists tenant_update on public.%I', v_table);
    execute format('drop policy if exists tenant_delete on public.%I', v_table);

    execute format(
      'create policy tenant_select on public.%I for select to authenticated using (public.app_has_tenant_access(tenant_id))',
      v_table
    );
    execute format(
      'create policy tenant_insert on public.%I for insert to authenticated with check (public.app_has_tenant_write_access(tenant_id))',
      v_table
    );
    execute format(
      'create policy tenant_update on public.%I for update to authenticated using (public.app_has_tenant_write_access(tenant_id)) with check (public.app_has_tenant_write_access(tenant_id))',
      v_table
    );
    execute format(
      'create policy tenant_delete on public.%I for delete to authenticated using (public.app_has_tenant_write_access(tenant_id))',
      v_table
    );
  end loop;
end;
$$;

comment on function public.marketplace_assign_support_table_tenant_v1() is
'Backfills tenant_id for marketplace support tables from account/order/job/created_by parent rows before RLS checks.';
