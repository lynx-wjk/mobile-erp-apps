-- Canonical Finance snapshot for the current P0 path.
-- Use the same tenant-scoped, WIB month-to-date order-date aggregate as
-- Dashboard Analytics. SKU details stay on finance_sku_order_details.

create or replace function public.finance_dashboard_snapshot(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_current_start date := date_trunc('month', timezone('Asia/Jakarta', now()))::date;
  v_current_end date := timezone('Asia/Jakarta', now())::date;
  v_base jsonb;
begin
  -- Dashboard Analytics is the canonical bounded MTD source for these
  -- top-level finance cards. It is tenant-scoped internally and resolves
  -- tiktok/tiktok_shop consistently.
  v_base := public.dashboard_marketplace_order_analytics_90d(p_marketplace, 90);

  return jsonb_build_object(
    'ok', true,
    'version', 'finance_dashboard_snapshot_dashboard_mtd_20260620',
    'source', 'finance_dashboard_snapshot',
    'source_table', 'dashboard_marketplace_order_analytics_90d',
    'timezone', 'Asia/Jakarta',
    'start_date', coalesce(v_base->>'start_date', v_current_start::text),
    'end_date', coalesce(v_base->>'end_date', v_current_end::text),
    'requested_start_date', coalesce(p_start, v_current_start),
    'requested_end_date', coalesce(p_end, v_current_end),
    'requested_account_id', p_account_id,
    'marketplace', coalesce(v_base->>'marketplace', 'all'),
    'summary', coalesce(v_base->'summary', '{}'::jsonb),
    'daily', coalesce(v_base->'daily', '[]'::jsonb),
    'trend', coalesce(v_base->'trend', v_base->'daily', '[]'::jsonb),
    'by_marketplace', coalesce(v_base->'by_marketplace', '[]'::jsonb),
    'marketplaces', coalesce(v_base->'by_marketplace', '[]'::jsonb),
    'profit_loss_by_marketplace', coalesce(v_base->'by_marketplace', '[]'::jsonb),
    'abnormal_aggregates', jsonb_build_object(
      'abnormal_count', coalesce(v_base->'summary'->'abnormal_count', '0'::jsonb),
      'negative_payout_total_abs', coalesce(v_base->'summary'->'negative_payout_total_abs', '0'::jsonb)
    ),
    'accounts', '[]'::jsonb,
    'expenses', '[]'::jsonb,
    'approved_purchases', '[]'::jsonb,
    'skus', '[]'::jsonb,
    'sku_rows', '[]'::jsonb,
    'cash_flow', '[]'::jsonb,
    'profit_loss_breakdown', '[]'::jsonb,
    'abnormals', '[]'::jsonb
  );
end;
$$;

grant execute on function public.finance_dashboard_snapshot(date, date, text, uuid)
  to authenticated, service_role;

notify pgrst, 'reload schema';
