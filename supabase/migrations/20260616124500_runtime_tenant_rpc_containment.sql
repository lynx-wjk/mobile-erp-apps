-- Runtime tenant RPC containment.
-- Fixes confirmed SECURITY DEFINER leaks for:
-- - list_work_locations()
-- - marketplace_job_monitor_snapshot_light()
-- - marketplace_job_monitor_snapshot_v24_6_9()
-- - finance dashboard/abnormal/SKU wrappers for tenants with no own finance/order data.
--
-- This is a containment patch. It does not rewrite the legacy finance formula internals yet.

begin;

create or replace function public._tenant_rpc_current_tenant_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select u.tenant_id
  from public.users u
  where u.user_id = auth.uid()
    and coalesce(u.status, 'active') = 'active'
  limit 1
$$;

create or replace function public._tenant_rpc_has_finance_data()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_tenant uuid := public._tenant_rpc_current_tenant_id();
  v_has boolean := false;
begin
  if v_tenant is null then
    return false;
  end if;

  select exists (
    select 1
    from public.marketplace_orders o
    where o.tenant_id = v_tenant
    limit 1
  )
  or exists (
    select 1
    from public.marketplace_finance_reports fr
    where fr.tenant_id = v_tenant
    limit 1
  )
  into v_has;

  return coalesce(v_has, false);
end;
$$;

create or replace function public._tenant_empty_finance_snapshot(
  p_reason text default 'tenant_has_no_finance_data'
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'ok', true,
    'version', 'tenant_empty_finance_snapshot_20260616',
    'source', 'tenant_runtime_guard',
    'reason', coalesce(p_reason, 'tenant_has_no_finance_data'),
    'summary', jsonb_build_object(
      'order_count', 0,
      'orders_count', 0,
      'finance_order_count', 0,
      'finance_orders_count', 0,
      'gross_sales', 0,
      'gross_total', 0,
      'gross_amount', 0,
      'omzet_total', 0,
      'payout_total', 0,
      'payout_amount', 0,
      'received_amount', 0,
      'net_settlement', 0,
      'hpp_total', 0,
      'total_hpp', 0,
      'expense_total', 0,
      'operational_cost_total', 0,
      'net_profit', 0,
      'profit', 0,
      'margin_percent', 0,
      'marketplace_count', 0,
      'abnormal_count', 0,
      'negative_payout_count', 0,
      'minus_payout_total', 0,
      'payout_minus_total', 0,
      'pending_hpp_total', 0,
      'estimated_unpaid_hpp_total', 0
    ),
    'daily', '[]'::jsonb,
    'days', '[]'::jsonb,
    'marketplaces', '[]'::jsonb,
    'by_marketplace', '[]'::jsonb,
    'by_sku', '[]'::jsonb,
    'sku_rows', '[]'::jsonb,
    'abnormals', '[]'::jsonb,
    'server_abnormals', '[]'::jsonb,
    'cash_flow', '[]'::jsonb,
    'expenses', '[]'::jsonb,
    'profit_loss', '[]'::jsonb,
    'approved_purchases', '[]'::jsonb
  )
$$;

create or replace function public.finance_customer_dashboard_snapshot(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._tenant_rpc_has_finance_data() then
    return public._tenant_empty_finance_snapshot();
  end if;

  return public.finance_customer_dashboard_snapshot_v24_6_82o(
    p_start,
    p_end,
    p_marketplace,
    p_account_id
  );
end;
$$;

create or replace function public.finance_dashboard_snapshot(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.finance_customer_dashboard_snapshot(
    p_start,
    p_end,
    p_marketplace,
    p_account_id
  );
end;
$$;

create or replace function public.finance_abnormal_search(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null,
  p_search text default null,
  p_status text default null,
  p_page integer default 1,
  p_page_size integer default 20
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._tenant_rpc_has_finance_data() then
    return jsonb_build_object(
      'ok', true,
      'version', 'tenant_empty_abnormal_search_20260616',
      'source', 'tenant_runtime_guard',
      'page', greatest(coalesce(p_page, 1), 1),
      'page_size', least(greatest(coalesce(p_page_size, 20), 1), 100),
      'total', 0,
      'total_pages', 0,
      'rows', '[]'::jsonb,
      'aggregates', jsonb_build_object(
        'total', 0,
        'negative_payout_count', 0,
        'negative_payout_total_abs', 0
      )
    );
  end if;

  return public.finance_abnormal_search_v24_6_82e(
    p_start,
    p_end,
    p_marketplace,
    p_account_id,
    p_search,
    p_status,
    p_page,
    p_page_size
  );
end;
$$;

create or replace function public.finance_sku_order_details(
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
set search_path = public
as $$
begin
  if not public._tenant_rpc_has_finance_data() then
    return jsonb_build_object(
      'ok', true,
      'version', 'tenant_empty_sku_details_20260616',
      'source', 'tenant_runtime_guard',
      'page', greatest(coalesce(p_page, 1), 1),
      'page_size', least(greatest(coalesce(p_page_size, 20), 1), 100),
      'total', 0,
      'total_pages', 0,
      'rows', '[]'::jsonb,
      'aggregates', '{}'::jsonb
    );
  end if;

  return public.finance_sku_order_details_v24_6_82o(
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
end;
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
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._tenant_rpc_has_finance_data() then
    return jsonb_build_object(
      'ok', true,
      'version', 'tenant_empty_sku_detail_lines_20260616',
      'source', 'tenant_runtime_guard',
      'page', 1,
      'page_size', least(greatest(coalesce(p_limit, 1000), 1), 1000),
      'total', 0,
      'total_pages', 0,
      'rows', '[]'::jsonb,
      'aggregates', '{}'::jsonb
    );
  end if;

  return public.finance_sku_order_detail_lines_v24_6_82e(
    p_start,
    p_end,
    p_marketplace,
    p_account_id,
    p_sku,
    p_limit,
    p_offset
  );
end;
$$;

create or replace function public.list_work_locations()
returns table(
  location_id uuid,
  nama_lokasi text,
  latitude numeric,
  longitude numeric,
  radius_meter numeric,
  alamat text,
  catatan text,
  status text,
  created_at timestamptz,
  updated_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select
    wl.location_id,
    wl.nama_lokasi,
    wl.latitude,
    wl.longitude,
    wl.radius_meter,
    wl.alamat,
    wl.catatan,
    wl.status,
    wl.created_at,
    wl.updated_at
  from public.work_locations wl
  where wl.tenant_id = public._tenant_rpc_current_tenant_id()
    and coalesce(wl.status, 'active') <> 'deleted'
  order by wl.created_at desc
$$;

create or replace function public.marketplace_job_monitor_snapshot_light()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tenant uuid := public._tenant_rpc_current_tenant_id();
  v_account_auth jsonb := '[]'::jsonb;
begin
  if v_tenant is not null then
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'marketplace_account_id', ma.marketplace_account_id,
          'marketplace', ma.marketplace,
          'store_name', coalesce(nullif(ma.store_alias, ''), nullif(ma.shop_name, ''), ma.marketplace),
          'shop_name', ma.shop_name,
          'environment', coalesce(ma.environment, 'production'),
          'status', coalesce(ma.status, 'unknown'),
          'token_status', case
            when nullif(ma.access_token_encrypted, '') is null then 'token_missing'
            when ma.access_token_expired_at is null then 'token_no_expiry'
            when ma.access_token_expired_at <= now() then 'access_expired_needs_refresh'
            when ma.access_token_expired_at <= now() + interval '3 days' then 'access_expiring_soon'
            else 'token_present'
          end,
          'access_token_expired_at', ma.access_token_expired_at,
          'refresh_token_expired_at', ma.refresh_token_expired_at,
          'access_token_expired_at_wib', to_char(ma.access_token_expired_at at time zone 'Asia/Jakarta', 'DD/MM/YYYY HH24:MI'),
          'refresh_token_expired_at_wib', to_char(ma.refresh_token_expired_at at time zone 'Asia/Jakarta', 'DD/MM/YYYY HH24:MI'),
          'last_checked_at_wib', to_char(coalesce(ma.updated_at, ma.connected_at, ma.created_at) at time zone 'Asia/Jakarta', 'DD/MM/YYYY HH24:MI'),
          'last_refreshed_at_wib', to_char(coalesce(ma.reauthorized_at, ma.connected_at, ma.updated_at, ma.created_at) at time zone 'Asia/Jakarta', 'DD/MM/YYYY HH24:MI'),
          'last_error', ma.last_error
        )
        order by ma.marketplace, coalesce(ma.store_alias, ma.shop_name, ma.marketplace)
      ),
      '[]'::jsonb
    )
    into v_account_auth
    from public.marketplace_accounts ma
    where ma.tenant_id = v_tenant
      and coalesce(ma.is_deleted, false) = false
      and coalesce(ma.status, 'active') <> 'deleted';
  end if;

  return jsonb_build_object(
    'ok', true,
    'version', 'tenant_safe_light_monitor_20260616',
    'generated_at_wib', to_char(timezone('Asia/Jakarta', now()), 'DD/MM/YYYY HH24:MI:SS'),
    'stale_threshold_minutes', 20,
    'warnings', '[]'::jsonb,
    'account_auth', v_account_auth,
    'order_counts', '{}'::jsonb,
    'finance_counts', '{}'::jsonb,
    'recent_order_jobs', '[]'::jsonb,
    'recent_finance_jobs', '[]'::jsonb,
    'recent_marketplace_logs', '[]'::jsonb,
    'recent_sync_logs', '[]'::jsonb,
    'nonfinal_order_refresh_candidates', '{}'::jsonb,
    'status_refresh_runs', '{}'::jsonb,
    'recent_status_refresh_logs', '[]'::jsonb
  );
end;
$$;

create or replace function public.marketplace_job_monitor_snapshot_v24_6_9()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.marketplace_job_monitor_snapshot_light();
end;
$$;

revoke all on function public._tenant_rpc_current_tenant_id() from public;
revoke all on function public._tenant_rpc_has_finance_data() from public;
revoke all on function public._tenant_empty_finance_snapshot(text) from public;

grant execute on function public.finance_customer_dashboard_snapshot(date, date, text, uuid) to authenticated;
grant execute on function public.finance_dashboard_snapshot(date, date, text, uuid) to authenticated;
grant execute on function public.finance_abnormal_search(date, date, text, uuid, text, text, integer, integer) to authenticated;
grant execute on function public.finance_sku_order_details(date, date, text, uuid, text, text, text, text, integer, integer) to authenticated;
grant execute on function public.finance_sku_order_detail_lines(date, date, text, uuid, text, integer, integer) to authenticated;
grant execute on function public.list_work_locations() to authenticated;
grant execute on function public.marketplace_job_monitor_snapshot_light() to authenticated;
grant execute on function public.marketplace_job_monitor_snapshot_v24_6_9() to authenticated;

commit;
