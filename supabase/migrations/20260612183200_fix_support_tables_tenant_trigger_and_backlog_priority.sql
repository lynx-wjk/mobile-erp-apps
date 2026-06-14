-- Split public.marketplace_assign_support_table_tenant_v1 into table-specific functions
-- to avoid runtime PL/pgSQL compilation errors due to missing columns on specific tables.

-- 1. marketplace_products
create or replace function public.marketplace_assign_products_tenant_v1()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
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
$$;

-- 2. marketplace_stock_sync_jobs
create or replace function public.marketplace_assign_stock_sync_jobs_tenant_v1()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
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
$$;

-- 3. marketplace_sync_logs
create or replace function public.marketplace_assign_sync_logs_tenant_v1()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
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
$$;

-- 4. marketplace_order_scan_logs
create or replace function public.marketplace_assign_order_scan_logs_tenant_v1()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
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
$$;

-- 5. marketplace_closing_books
create or replace function public.marketplace_assign_closing_books_tenant_v1()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
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
$$;

-- 6. marketplace_closing_book_files
create or replace function public.marketplace_assign_closing_book_files_tenant_v1()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
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
$$;

-- Drop old triggers using the shared function and recreate using split functions
drop trigger if exists trg_marketplace_products_tenant_v1 on public.marketplace_products;
create trigger trg_marketplace_products_tenant_v1
before insert or update on public.marketplace_products
for each row execute function public.marketplace_assign_products_tenant_v1();

drop trigger if exists trg_marketplace_stock_sync_jobs_tenant_v1 on public.marketplace_stock_sync_jobs;
create trigger trg_marketplace_stock_sync_jobs_tenant_v1
before insert or update on public.marketplace_stock_sync_jobs
for each row execute function public.marketplace_assign_stock_sync_jobs_tenant_v1();

drop trigger if exists trg_marketplace_sync_logs_tenant_v1 on public.marketplace_sync_logs;
create trigger trg_marketplace_sync_logs_tenant_v1
before insert or update on public.marketplace_sync_logs
for each row execute function public.marketplace_assign_sync_logs_tenant_v1();

drop trigger if exists trg_marketplace_order_scan_logs_tenant_v1 on public.marketplace_order_scan_logs;
create trigger trg_marketplace_order_scan_logs_tenant_v1
before insert or update on public.marketplace_order_scan_logs
for each row execute function public.marketplace_assign_order_scan_logs_tenant_v1();

drop trigger if exists trg_marketplace_closing_books_tenant_v1 on public.marketplace_closing_books;
create trigger trg_marketplace_closing_books_tenant_v1
before insert or update on public.marketplace_closing_books
for each row execute function public.marketplace_assign_closing_books_tenant_v1();

drop trigger if exists trg_marketplace_closing_book_files_tenant_v1 on public.marketplace_closing_book_files;
create trigger trg_marketplace_closing_book_files_tenant_v1
before insert or update on public.marketplace_closing_book_files
for each row execute function public.marketplace_assign_closing_book_files_tenant_v1();

-- Redefine requeue backlog function to assign a fixed low priority of 95
create or replace function public.marketplace_requeue_cancelled_order_windows_90d_v1(
  p_max_jobs integer default 3
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  v_start_seconds bigint := extract(epoch from ((v_today - 89)::timestamp at time zone 'Asia/Jakarta'))::bigint;
  v_end_seconds bigint := extract(epoch from ((v_today + 1)::timestamp at time zone 'Asia/Jakarta'))::bigint;
  v_inserted integer := 0;
  v_reactivated integer := 0;
  v_jobs jsonb := '[]'::jsonb;
begin
  with source_windows as (
    select
      j.*,
      row_number() over (
        partition by j.tenant_id, j.marketplace_account_id, j.marketplace, j.window_start_seconds, j.window_end_seconds
        order by
          case when j.window_start_seconds >= extract(epoch from ((v_today - 7)::timestamp at time zone 'Asia/Jakarta'))::bigint then 0 else 1 end,
          j.window_start_seconds desc,
          j.updated_at desc
      ) as rn
    from public.marketplace_order_pull_jobs j
    join public.marketplace_accounts ma
      on ma.tenant_id = j.tenant_id
     and ma.marketplace_account_id = j.marketplace_account_id
    where lower(coalesce(j.status, '')) in ('cancelled', 'canceled', 'failed')
      and j.job_type in ('auto_recent', 'auto_recent_free_plan', 'auto_today_window', 'auto_yesterday_window')
      and j.window_start_seconds >= v_start_seconds
      and j.window_start_seconds < v_end_seconds
      and coalesce(ma.is_active, true) = true
      and coalesce(ma.environment, 'production') = 'production'
      and not exists (
        select 1
        from public.marketplace_order_pull_jobs existing
        where existing.tenant_id = j.tenant_id
          and existing.marketplace_account_id = j.marketplace_account_id
          and existing.marketplace = j.marketplace
          and existing.job_type = 'cancelled_order_window_backlog_90d_v1'
          and existing.window_start_seconds = j.window_start_seconds
          and existing.window_end_seconds = j.window_end_seconds
          and lower(coalesce(existing.status, '')) in ('pending', 'running', 'retry', 'done', 'success', 'completed')
      )
    order by
      case when j.window_start_seconds >= extract(epoch from ((v_today - 7)::timestamp at time zone 'Asia/Jakarta'))::bigint then 0 else 1 end,
      j.window_start_seconds desc,
      j.updated_at desc
    limit greatest(1, coalesce(p_max_jobs, 3))
  ),
  selected as (
    select *
    from source_windows
    where rn = 1
  ),
  upserted as (
    insert into public.marketplace_order_pull_jobs (
      tenant_id,
      marketplace_account_id,
      marketplace,
      job_type,
      period_start,
      period_end,
      window_start_seconds,
      window_end_seconds,
      window_label,
      status,
      priority,
      attempts,
      next_run_at,
      locked_at,
      last_run_at,
      finished_at,
      order_count,
      item_count,
      mapped_count,
      unmapped_count,
      warning_count,
      last_message,
      payload,
      last_result,
      requested_by,
      created_at,
      updated_at
    )
    select
      s.tenant_id,
      s.marketplace_account_id,
      s.marketplace,
      'cancelled_order_window_backlog_90d_v1',
      (to_timestamp(s.window_start_seconds) at time zone 'Asia/Jakarta')::date,
      (to_timestamp(greatest(s.window_end_seconds - 1, s.window_start_seconds)) at time zone 'Asia/Jakarta')::date,
      s.window_start_seconds,
      s.window_end_seconds,
      'Cancelled window backlog 90d ' || s.marketplace || ' ' || to_char(to_timestamp(s.window_start_seconds) at time zone 'Asia/Jakarta', 'YYYY-MM-DD HH24:MI'),
      'pending',
      95, -- Fixed low priority to prevent starving live pulls
      0,
      now(),
      null,
      null,
      null,
      0,
      0,
      0,
      0,
      0,
      'Requeued cancelled/failed automatic order window for 90-day backlog reconciliation.',
      jsonb_build_object(
        'mode', 'cancelled_order_window_backlog_90d',
        'source', 'marketplace_requeue_cancelled_order_windows_90d_v1',
        'rescued_order_pull_job_id', s.order_pull_job_id,
        'rescued_job_type', s.job_type,
        'rescued_status', s.status,
        'rescued_last_message', s.last_message,
        'rescued_priority', s.priority
      ),
      '{}'::jsonb,
      null,
      now(),
      now()
    from selected s
    returning order_pull_job_id, window_label
  )
  select coalesce(jsonb_agg(jsonb_build_object('job_id', order_pull_job_id, 'label', window_label)), '[]'::jsonb)
  into v_jobs
  from upserted;

  v_inserted := jsonb_array_length(v_jobs);
  return jsonb_build_object(
    'ok', true,
    'inserted', v_inserted,
    'jobs', v_jobs
  );
end;
$$;

grant execute on function public.marketplace_assign_products_tenant_v1() to authenticated, service_role;
grant execute on function public.marketplace_assign_stock_sync_jobs_tenant_v1() to authenticated, service_role;
grant execute on function public.marketplace_assign_sync_logs_tenant_v1() to authenticated, service_role;
grant execute on function public.marketplace_assign_order_scan_logs_tenant_v1() to authenticated, service_role;
grant execute on function public.marketplace_assign_closing_books_tenant_v1() to authenticated, service_role;
grant execute on function public.marketplace_assign_closing_book_files_tenant_v1() to authenticated, service_role;
grant execute on function public.marketplace_requeue_cancelled_order_windows_90d_v1(integer) to service_role;
