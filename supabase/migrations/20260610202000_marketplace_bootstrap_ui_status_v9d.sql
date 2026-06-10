-- 20260610202000_marketplace_bootstrap_ui_status_v9d.sql
-- UI-ready tenant-scoped marketplace bootstrap status RPC.
-- No Finance/HPP logic changes. No physical delete. No hardcoded tenant/account.

create or replace function public.marketplace_bootstrap_ui_status_v1()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tenant_id uuid := public.app_current_tenant_id_or_default();
  v_accounts jsonb := '[]'::jsonb;
  v_summary jsonb := '{}'::jsonb;
  v_has_active boolean := false;
  v_has_blocked boolean := false;
  v_has_failed boolean := false;
  v_has_syncing boolean := false;
  v_all_completed boolean := false;
begin
  if v_tenant_id is null then
    return jsonb_build_object(
      'ok', false,
      'severity', 'error',
      'show_banner', true,
      'title', 'Tenant tidak ditemukan',
      'message', 'User aktif belum terhubung ke tenant.',
      'accounts', '[]'::jsonb,
      'summary', jsonb_build_object('total_accounts',0)
    );
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'marketplace_account_id', marketplace_account_id,
      'marketplace', marketplace,
      'store_name', store_name,
      'environment', environment,
      'account_status', account_status,
      'bootstrap_status', bootstrap_status,
      'client_message', client_message,
      'progress_pct', progress_pct,
      'total_jobs', total_jobs,
      'done_jobs', done_jobs,
      'pending_jobs', pending_jobs,
      'running_jobs', running_jobs,
      'retry_jobs', case when marketplace = 'tiktok_shop' then (
        select count(*)::integer
        from public.marketplace_order_pull_jobs j
        where j.tenant_id = s.tenant_id
          and j.marketplace_account_id = s.marketplace_account_id
          and j.job_type = 'bootstrap_90d_adaptive_v1'
          and j.status = 'retry'
      ) else 0 end,
      'failed_jobs', failed_jobs,
      'page_limit_risk_jobs', page_limit_risk_jobs,
      'orders_pulled', orders_pulled,
      'items_pulled', items_pulled,
      'estimated_finish_wib', estimated_finish_wib,
      'estimated_remaining', estimated_remaining::text,
      'last_finished_at', last_finished_at,
      'last_updated_at', last_updated_at,
      'technical_status', case
        when bootstrap_status = 'blocked_pagination_limit' then 'pagination_limit_requires_admin'
        when failed_jobs > 0 then 'failed_requires_admin'
        when running_jobs > 0 or pending_jobs > 0 then 'syncing'
        when bootstrap_status = 'completed' then 'completed'
        else bootstrap_status
      end
    ) order by marketplace, store_name
  ), '[]'::jsonb)
  into v_accounts
  from public.marketplace_account_bootstrap_status_v2 s
  where tenant_id = v_tenant_id;

  select
    count(*) > 0,
    count(*) filter (where bootstrap_status = 'blocked_pagination_limit') > 0,
    count(*) filter (where failed_jobs > 0 or bootstrap_status = 'failed') > 0,
    count(*) filter (where bootstrap_status in ('queued','pulling','syncing') or pending_jobs > 0 or running_jobs > 0) > 0,
    count(*) > 0 and count(*) filter (where bootstrap_status = 'completed') = count(*)
  into v_has_active, v_has_blocked, v_has_failed, v_has_syncing, v_all_completed
  from public.marketplace_account_bootstrap_status_v2
  where tenant_id = v_tenant_id;

  select jsonb_build_object(
    'total_accounts', count(*)::integer,
    'completed_accounts', count(*) filter (where bootstrap_status = 'completed')::integer,
    'syncing_accounts', count(*) filter (where bootstrap_status in ('queued','pulling','syncing') or pending_jobs > 0 or running_jobs > 0)::integer,
    'blocked_accounts', count(*) filter (where bootstrap_status = 'blocked_pagination_limit')::integer,
    'failed_accounts', count(*) filter (where failed_jobs > 0 or bootstrap_status = 'failed')::integer,
    'total_jobs', coalesce(sum(total_jobs),0)::integer,
    'done_jobs', coalesce(sum(done_jobs),0)::integer,
    'pending_jobs', coalesce(sum(pending_jobs),0)::integer,
    'running_jobs', coalesce(sum(running_jobs),0)::integer,
    'failed_jobs', coalesce(sum(failed_jobs),0)::integer,
    'retry_jobs', coalesce((
      select sum(case when j.status = 'retry' then 1 else 0 end)::integer
      from public.marketplace_order_pull_jobs j
      where j.tenant_id = v_tenant_id
        and j.job_type = 'bootstrap_90d_adaptive_v1'
    ), 0),
    'orders_pulled', coalesce(sum(orders_pulled),0)::bigint,
    'items_pulled', coalesce(sum(items_pulled),0)::bigint,
    'page_limit_risk_jobs', coalesce(sum(page_limit_risk_jobs),0)::integer,
    'estimated_finish_wib', max(estimated_finish_wib),
    'refreshed_at_wib', now() at time zone 'Asia/Jakarta'
  ) into v_summary
  from public.marketplace_account_bootstrap_status_v2
  where tenant_id = v_tenant_id;

  return jsonb_build_object(
    'ok', true,
    'tenant_id', v_tenant_id,
    'show_banner', (v_has_blocked or v_has_failed or v_has_syncing),
    'severity', case
      when v_has_failed then 'error'
      when v_has_blocked then 'warning'
      when v_has_syncing then 'info'
      when v_all_completed then 'success'
      else 'neutral'
    end,
    'title', case
      when v_has_failed then 'Sinkronisasi marketplace perlu dicek admin'
      when v_has_blocked then 'Data marketplace sedang diperbaiki'
      when v_has_syncing then 'Data marketplace 90 hari sedang diambil'
      when v_all_completed then 'Data marketplace siap'
      else 'Belum ada toko marketplace aktif'
    end,
    'message', case
      when v_has_failed then 'Ada job sinkronisasi yang gagal. Data dashboard belum final sampai admin menyelesaikan sinkronisasi.'
      when v_has_blocked then 'Sebagian data marketplace lebih besar dari limit halaman worker lama. Sistem sedang memproses ulang data secara aman. Dashboard akan terisi bertahap.'
      when v_has_syncing then 'Order, resi, refund/return, dan payout marketplace sedang disinkronkan. Data akan muncul bertahap dan dashboard finance belum final sampai proses selesai.'
      when v_all_completed then 'Data marketplace 90 hari sudah selesai disinkronkan.'
      else 'Hubungkan toko marketplace untuk mulai mengambil data 90 hari terakhir.'
    end,
    'summary', v_summary,
    'accounts', v_accounts
  );
end;
$$;

grant execute on function public.marketplace_bootstrap_ui_status_v1() to authenticated;
revoke execute on function public.marketplace_bootstrap_ui_status_v1() from anon;

comment on function public.marketplace_bootstrap_ui_status_v1() is
'Tenant-scoped UI payload for marketplace 90-day bootstrap progress/banner/status. Read-only. Does not modify finance/HPP/order data.';
