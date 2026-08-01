-- 9H-B canonical active RPC wrappers.
-- Purpose: expose non-versioned canonical RPC names while preserving old stable implementations.
-- No old function is dropped here.

set search_path = public;

create or replace function public.finance_auto_mark_cancel_no_payout(
  p_start date default null,
  p_end date default null,
  p_account_id uuid default null
)
returns jsonb
language sql
volatile
security definer
set search_path = public
as $$
  select public.finance_auto_mark_cancel_no_payout_v24_6_28(p_start, p_end, p_account_id);
$$;

create or replace function public.finance_fix_exact_cache_settled_hpp(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null
)
returns jsonb
language sql
volatile
security definer
set search_path = public
as $$
  select public.finance_fix_exact_cache_settled_hpp_v24_6_82q(p_start, p_end, p_marketplace, p_account_id);
$$;

create or replace function public.finance_insert_manual_operational_expense(
  p_category text,
  p_amount numeric,
  p_expense_date date default current_date,
  p_note text default null
)
returns jsonb
language sql
volatile
security definer
set search_path = public
as $$
  select public.finance_insert_manual_operational_expense_v24_6_79(p_category, p_amount, p_expense_date, p_note);
$$;

create or replace function public.finance_refresh_recent_caches(
  p_marketplace text default 'all',
  p_account_id uuid default null,
  p_reason text default 'auto'
)
returns jsonb
language sql
volatile
security definer
set search_path = public
as $$
  select public.finance_refresh_recent_caches_v24_6_81b(p_marketplace, p_account_id, p_reason);
$$;

create or replace function public.finance_sku_order_detail_lines(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null,
  p_sku text default null,
  p_limit integer default 1000,
  p_offset integer default 0
)
returns jsonb
language sql
volatile
security definer
set search_path = public
as $$
  select public.finance_sku_order_detail_lines_v24_6_82e(
    p_start,
    p_end,
    p_marketplace,
    p_account_id,
    p_sku,
    p_limit,
    p_offset
  );
$$;

create or replace function public.finance_unmark_no_payout_order(
  p_order_id text,
  p_account_id uuid
)
returns jsonb
language sql
volatile
security definer
set search_path = public
as $$
  select public.finance_unmark_no_payout_order_v24_6_28(p_order_id, p_account_id);
$$;

create or replace function public.finance_upsert_runtime_progress(
  p_sync_type text,
  p_status text,
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null,
  p_checked integer default 0,
  p_success integer default 0,
  p_failed integer default 0,
  p_skipped integer default 0,
  p_message text default null
)
returns jsonb
language sql
volatile
security definer
set search_path = public
as $$
  select public.finance_upsert_runtime_progress_v24_6_3(
    p_sync_type,
    p_status,
    p_start,
    p_end,
    p_marketplace,
    p_account_id,
    p_checked,
    p_success,
    p_failed,
    p_skipped,
    p_message
  );
$$;

create or replace function public.marketplace_auto_runner_release_lock(
  p_lock_key text,
  p_owner text default null
)
returns boolean
language sql
volatile
security definer
set search_path = public
as $$
  select public.marketplace_auto_runner_release_lock_v24_6_81b(p_lock_key, p_owner);
$$;

create or replace function public.marketplace_auto_runner_try_lock(
  p_lock_key text,
  p_ttl_seconds integer default 300,
  p_owner text default null
)
returns boolean
language sql
volatile
security definer
set search_path = public
as $$
  select public.marketplace_auto_runner_try_lock_v24_6_81b(p_lock_key, p_ttl_seconds, p_owner);
$$;

create or replace function public.marketplace_bootstrap_ui_status()
returns jsonb
language sql
volatile
security definer
set search_path = public
as $$
  select public.marketplace_bootstrap_ui_status_v1();
$$;

create or replace function public.marketplace_failed_finance_jobs_90d_health()
returns jsonb
language sql
volatile
security definer
set search_path = public
as $$
  select public.marketplace_failed_finance_jobs_90d_health_v1();
$$;

create or replace function public.marketplace_refund_cancel_review(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null,
  p_search text default null,
  p_action text default null,
  p_page integer default 1,
  p_page_size integer default 20
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.marketplace_refund_cancel_review_v24_6_42(
    p_start,
    p_end,
    p_marketplace,
    p_account_id,
    p_search,
    p_action,
    p_page,
    p_page_size
  );
$$;

create or replace function public.marketplace_reset_stale_auto_jobs(
  p_order_stale_minutes integer default 10,
  p_finance_stale_minutes integer default 15,
  p_revive_failed boolean default false
)
returns jsonb
language sql
volatile
security definer
set search_path = public
as $$
  select public.marketplace_reset_stale_auto_jobs_v24_6_81b(
    p_order_stale_minutes,
    p_finance_stale_minutes,
    p_revive_failed
  );
$$;

create or replace function public.marketplace_variant_hpp_list(
  p_account_id uuid default null,
  p_search text default null,
  p_missing_only boolean default false,
  p_page integer default 1,
  p_page_size integer default 20
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.marketplace_variant_hpp_list_v24_6_49(
    p_account_id,
    p_search,
    p_missing_only,
    p_page,
    p_page_size
  );
$$;

create or replace function public.marketplace_variant_hpp_upsert_bulk(
  p_rows jsonb
)
returns jsonb
language sql
volatile
security definer
set search_path = public
as $$
  select public.marketplace_variant_hpp_upsert_bulk_v24_6_49(p_rows);
$$;

create or replace function public.user_work_schedule_list(
  p_user_id uuid default null
)
returns jsonb
language sql
volatile
security definer
set search_path = public
as $$
  select public.user_work_schedule_list_v24_6_28(p_user_id);
$$;

create or replace function public.user_work_schedule_upsert_bulk(
  p_rows jsonb
)
returns jsonb
language sql
volatile
security definer
set search_path = public
as $$
  select public.user_work_schedule_upsert_bulk_v24_6_28(p_rows);
$$;

grant execute on function public.finance_auto_mark_cancel_no_payout(date,date,uuid) to anon, authenticated, service_role;
grant execute on function public.finance_fix_exact_cache_settled_hpp(date,date,text,uuid) to anon, authenticated, service_role;
grant execute on function public.finance_insert_manual_operational_expense(text,numeric,date,text) to anon, authenticated, service_role;
grant execute on function public.finance_refresh_recent_caches(text,uuid,text) to anon, authenticated, service_role;
grant execute on function public.finance_sku_order_detail_lines(date,date,text,uuid,text,integer,integer) to anon, authenticated, service_role;
grant execute on function public.finance_unmark_no_payout_order(text,uuid) to anon, authenticated, service_role;
grant execute on function public.finance_upsert_runtime_progress(text,text,date,date,text,uuid,integer,integer,integer,integer,text) to anon, authenticated, service_role;

grant execute on function public.marketplace_auto_runner_release_lock(text,text) to anon, authenticated, service_role;
grant execute on function public.marketplace_auto_runner_try_lock(text,integer,text) to anon, authenticated, service_role;
grant execute on function public.marketplace_bootstrap_ui_status() to anon, authenticated, service_role;
grant execute on function public.marketplace_failed_finance_jobs_90d_health() to anon, authenticated, service_role;
grant execute on function public.marketplace_refund_cancel_review(date,date,text,uuid,text,text,integer,integer) to anon, authenticated, service_role;
grant execute on function public.marketplace_reset_stale_auto_jobs(integer,integer,boolean) to anon, authenticated, service_role;
grant execute on function public.marketplace_variant_hpp_list(uuid,text,boolean,integer,integer) to anon, authenticated, service_role;
grant execute on function public.marketplace_variant_hpp_upsert_bulk(jsonb) to anon, authenticated, service_role;

grant execute on function public.user_work_schedule_list(uuid) to anon, authenticated, service_role;
grant execute on function public.user_work_schedule_upsert_bulk(jsonb) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
