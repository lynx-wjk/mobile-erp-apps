create or replace function public.marketplace_dispatcher_monitor_snapshot()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := now();
  v_order jsonb;
  v_finance jsonb;
  v_cron jsonb;
  v_coverage jsonb;
  v_summary jsonb;
begin
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'tenant_id', s.tenant_id,
      'marketplace_account_id', s.marketplace_account_id,
      'marketplace', s.marketplace,
      'bootstrap_status', s.bootstrap_status,
      'bootstrap_from_at', case when s.bootstrap_from_seconds is null then null else to_timestamp(s.bootstrap_from_seconds) end,
      'bootstrap_to_at', case when s.bootstrap_to_seconds is null then null else to_timestamp(s.bootstrap_to_seconds) end,
      'bootstrap_cursor_at', case when s.bootstrap_cursor_seconds is null then null else to_timestamp(s.bootstrap_cursor_seconds) end,
      'recent_cursor_at', case when s.recent_cursor_seconds is null then null else to_timestamp(s.recent_cursor_seconds) end,
      'last_success_window_start_at', case when s.last_success_window_start_seconds is null then null else to_timestamp(s.last_success_window_start_seconds) end,
      'last_success_window_end_at', case when s.last_success_window_end_seconds is null then null else to_timestamp(s.last_success_window_end_seconds) end,
      'last_success_at', s.last_success_at,
      'last_mode', s.last_mode,
      'failure_count', s.failure_count,
      'last_error', s.last_error,
      'locked_until', s.locked_until,
      'lock_status', case
        when s.locked_until is null then 'free'
        when s.locked_until < v_now then 'stale'
        else 'locked'
      end,
      'next_run_at', s.next_run_at,
      'orders_90d', coalesce(o.orders_90d, 0),
      'first_order_created_at', o.first_order_created_at,
      'last_order_created_at', o.last_order_created_at,
      'last_order_updated_at', o.last_order_updated_at
    )
    order by s.marketplace, s.marketplace_account_id
  ), '[]'::jsonb)
  into v_order
  from public.marketplace_order_sync_state s
  left join lateral (
    select
      count(*)::integer as orders_90d,
      min(mo.order_created_at) as first_order_created_at,
      max(mo.order_created_at) as last_order_created_at,
      max(mo.updated_at) as last_order_updated_at
    from public.marketplace_orders mo
    where mo.marketplace_account_id = s.marketplace_account_id
      and mo.order_created_at >= current_date - interval '90 days'
  ) o on true;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'tenant_id', s.tenant_id,
      'marketplace_account_id', s.marketplace_account_id,
      'marketplace', s.marketplace,
      'finance_status', s.finance_status,
      'bootstrap_from_date', s.bootstrap_from_date,
      'bootstrap_to_date', s.bootstrap_to_date,
      'bootstrap_cursor_date', s.bootstrap_cursor_date,
      'recent_cursor_date', s.recent_cursor_date,
      'last_success_period_start', s.last_success_period_start,
      'last_success_period_end', s.last_success_period_end,
      'last_success_at', s.last_success_at,
      'last_mode', s.last_mode,
      'failure_count', s.failure_count,
      'last_error', s.last_error,
      'checked_total', s.checked_total,
      'synced_total', s.synced_total,
      'failed_total', s.failed_total,
      'locked_until', s.locked_until,
      'lock_status', case
        when s.locked_until is null then 'free'
        when s.locked_until < v_now then 'stale'
        else 'locked'
      end,
      'next_run_at', s.next_run_at,
      'finance_reports_90d', coalesce(f.finance_reports_90d, 0),
      'first_finance_period', f.first_finance_period,
      'last_finance_period', f.last_finance_period,
      'last_finance_updated_at', f.last_finance_updated_at,
      'payout_sum_90d', coalesce(f.payout_sum_90d, 0)
    )
    order by s.marketplace, s.marketplace_account_id
  ), '[]'::jsonb)
  into v_finance
  from public.marketplace_finance_sync_state s
  left join lateral (
    select
      count(*)::integer as finance_reports_90d,
      min(fr.period_start) as first_finance_period,
      max(fr.period_end) as last_finance_period,
      max(fr.updated_at) as last_finance_updated_at,
      sum(coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)) as payout_sum_90d
    from public.marketplace_finance_reports fr
    where fr.marketplace_account_id = s.marketplace_account_id
      and fr.period_start >= current_date - interval '90 days'
  ) f on true;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'jobid', c.jobid,
      'jobname', c.jobname,
      'schedule', c.schedule,
      'active', c.active
    )
    order by c.jobid
  ), '[]'::jsonb)
  into v_cron
  from cron.job c
  where c.jobname ilike '%marketplace%';

  select jsonb_build_object(
    'active_accounts', (
      select count(*)::integer
      from public.marketplace_accounts ma
      where ma.marketplace in ('shopee', 'tiktok_shop')
        and ma.status = 'active'
        and coalesce(ma.is_deleted, false) = false
        and coalesce(ma.is_active, true) = true
    ),
    'accounts_missing_order_state', (
      select count(*)::integer
      from public.marketplace_accounts ma
      left join public.marketplace_order_sync_state os
        on os.marketplace_account_id = ma.marketplace_account_id
      where ma.marketplace in ('shopee', 'tiktok_shop')
        and ma.status = 'active'
        and coalesce(ma.is_deleted, false) = false
        and coalesce(ma.is_active, true) = true
        and os.marketplace_account_id is null
    ),
    'accounts_missing_finance_state', (
      select count(*)::integer
      from public.marketplace_accounts ma
      left join public.marketplace_finance_sync_state fs
        on fs.marketplace_account_id = ma.marketplace_account_id
      where ma.marketplace in ('shopee', 'tiktok_shop')
        and ma.status = 'active'
        and coalesce(ma.is_deleted, false) = false
        and coalesce(ma.is_active, true) = true
        and fs.marketplace_account_id is null
    )
  )
  into v_coverage;

  select jsonb_build_object(
    'order_bad_count', (
      select count(*)::integer
      from public.marketplace_order_sync_state
      where failure_count > 0
         or last_error is not null
         or locked_until < v_now
    ),
    'finance_bad_count', (
      select count(*)::integer
      from public.marketplace_finance_sync_state
      where (
        marketplace = 'shopee'
        and (
          failure_count > 0
          or last_error is not null
          or locked_until < v_now
        )
      )
      or (
        marketplace = 'tiktok_shop'
        and (
          finance_status <> 'unsupported'
          or failure_count > 0
          or last_error is not null
        )
      )
    ),
    'order_dispatcher_active', exists (
      select 1 from cron.job
      where jobname = 'marketplace-order-dispatcher-every-2-min'
        and active is true
    ),
    'finance_dispatcher_active', exists (
      select 1 from cron.job
      where jobname = 'marketplace-finance-dispatcher-every-5-min'
        and active is true
    ),
    'old_finance_pull_active', exists (
      select 1 from cron.job
      where jobname = 'marketplace-finance-pull-every-5-min'
        and active is true
    )
  )
  into v_summary;

  return jsonb_build_object(
    'ok', true,
    'generated_at', v_now,
    'summary', v_summary,
    'coverage', v_coverage,
    'order_states', v_order,
    'finance_states', v_finance,
    'cron_jobs', v_cron
  );
end;
$$;

grant execute on function public.marketplace_dispatcher_monitor_snapshot() to authenticated;
grant execute on function public.marketplace_dispatcher_monitor_snapshot() to service_role;
