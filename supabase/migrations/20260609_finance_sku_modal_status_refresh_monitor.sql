begin;

create or replace function public.marketplace_job_monitor_snapshot_v24_6_9()
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_stale_before timestamptz := now() - interval '20 minutes';
  v_refresh_cutoff timestamptz := now() - interval '90 days';
begin
  return jsonb_build_object(
    'generated_at_wib', to_char(now() at time zone 'Asia/Jakarta', 'DD/MM/YYYY HH24:MI:SS'),
    'stale_threshold_minutes', 20,
    'order_status_refresh_policy', jsonb_build_object(
      'range_days', 90,
      'target_statuses', jsonb_build_array(
        'AWAITING_SHIPMENT', 'AWAITING_COLLECTION', 'IN_TRANSIT', 'DELIVERED',
        'READY_TO_SHIP', 'TO_SHIP', 'TO_PACK'
      ),
      'priority', 'payout_positive_nonfinal_first',
      'note', 'Order status tetap dari marketplace order API. Payout hanya dipakai untuk prioritas refresh dan warning UI.'
    ),
    'nonfinal_order_refresh_candidates', coalesce((
      select jsonb_build_object(
        'total_nonfinal_90d', count(*),
        'payout_positive_priority', count(*) filter (where exists (
          select 1
          from public.marketplace_finance_reports fr
          where fr.marketplace_account_id = o.marketplace_account_id
            and fr.period_start >= (now() at time zone 'Asia/Jakarta')::date - 90
            and (
              nullif(fr.order_id, '') = nullif(o.order_id, '')
              or nullif(fr.order_id, '') = nullif(o.external_order_id, '')
              or nullif(fr.order_id, '') = nullif(o.order_sn, '')
              or fr.marketplace_order_id = o.marketplace_order_id
            )
            and coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0) > 0
        )),
        'last_checked_at_wib', to_char(max(coalesce(o.pulled_at, o.updated_at, o.order_updated_at, o.order_created_at, o.created_at)) at time zone 'Asia/Jakarta', 'DD/MM/YYYY HH24:MI')
      )
      from public.marketplace_orders o
      where coalesce(o.order_updated_at, o.order_created_at, o.updated_at, o.created_at) >= v_refresh_cutoff
        and upper(coalesce(o.order_status, o.status, '')) in (
          'AWAITING_SHIPMENT', 'AWAITING_COLLECTION', 'IN_TRANSIT', 'DELIVERED',
          'READY_TO_SHIP', 'TO_SHIP', 'TO_PACK', 'PAID', 'UNSHIPPED',
          'AWAITING_PICKUP', 'READY_FOR_COLLECTION', 'READY_FOR_PICKUP'
        )
    ), jsonb_build_object(
      'total_nonfinal_90d', 0,
      'payout_positive_priority', 0,
      'last_checked_at_wib', null
    )),
    'account_auth', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.marketplace, x.store_name)
      from (
        select
          ma.marketplace_account_id,
          ma.marketplace,
          coalesce(nullif(ma.store_alias, ''), nullif(ma.shop_name, ''), ma.marketplace) as store_name,
          coalesce(ma.environment, 'production') as environment,
          coalesce(ma.status, 'unknown') as status,
          case
            when nullif(ma.access_token_encrypted, '') is null then 'token_missing'
            when ma.access_token_expired_at is null then 'token_no_expiry'
            when ma.access_token_expired_at <= now() then 'access_expired_needs_refresh'
            when ma.access_token_expired_at <= now() + interval '3 days' then 'access_expiring_soon'
            else 'token_present'
          end as token_status,
          ma.access_token_expired_at,
          ma.refresh_token_expired_at,
          to_char(ma.access_token_expired_at at time zone 'Asia/Jakarta', 'DD/MM/YYYY HH24:MI') as access_token_expired_at_wib,
          to_char(ma.refresh_token_expired_at at time zone 'Asia/Jakarta', 'DD/MM/YYYY HH24:MI') as refresh_token_expired_at_wib,
          to_char(coalesce(ma.updated_at, ma.connected_at, ma.created_at) at time zone 'Asia/Jakarta', 'DD/MM/YYYY HH24:MI') as last_checked_at_wib,
          to_char(coalesce(ma.reauthorized_at, ma.connected_at, ma.updated_at, ma.created_at) at time zone 'Asia/Jakarta', 'DD/MM/YYYY HH24:MI') as last_refreshed_at_wib,
          ma.last_error
        from public.marketplace_accounts ma
        where coalesce(ma.is_deleted, false) = false
          and coalesce(ma.status, 'active') <> 'deleted'
        order by ma.marketplace, coalesce(ma.store_alias, ma.shop_name, ma.marketplace)
      ) x
    ), '[]'::jsonb),
    'order_counts', coalesce((
      select jsonb_build_object(
        'pending', count(*) filter (where status = 'pending'),
        'running', count(*) filter (where status = 'running'),
        'active_running', count(*) filter (where status = 'running' and coalesce(locked_at, last_run_at, updated_at, created_at) >= v_stale_before),
        'stale_running', count(*) filter (where status = 'running' and coalesce(locked_at, last_run_at, updated_at, created_at) < v_stale_before),
        'done', count(*) filter (where status = 'done'),
        'failed', count(*) filter (where status = 'failed'),
        'retry', count(*) filter (where status = 'retry'),
        'cancelled', count(*) filter (where status = 'cancelled')
      )
      from public.marketplace_order_pull_jobs
    ), '{}'::jsonb),
    'finance_counts', coalesce((
      select jsonb_build_object(
        'pending', count(*) filter (where status = 'pending'),
        'running', count(*) filter (where status = 'running'),
        'active_running', count(*) filter (where status = 'running' and coalesce(locked_at, last_run_at, updated_at, created_at) >= v_stale_before),
        'stale_running', count(*) filter (where status = 'running' and coalesce(locked_at, last_run_at, updated_at, created_at) < v_stale_before),
        'done', count(*) filter (where status = 'done'),
        'failed', count(*) filter (where status = 'failed'),
        'retry', count(*) filter (where status = 'retry'),
        'cancelled', count(*) filter (where status = 'cancelled')
      )
      from public.finance_sync_jobs
    ), '{}'::jsonb),
    'recent_order_jobs', coalesce((
      select jsonb_agg(to_jsonb(x))
      from (
        select
          'Pembaruan order otomatis' as title,
          status,
          attempts,
          coalesce(order_count, 0) as order_count,
          coalesce(item_count, 0) as item_count,
          coalesce(order_count, 0) as checked,
          coalesce(item_count, 0) as success,
          coalesce(last_message, 'Pembaruan order selesai.') as message,
          to_char(coalesce(updated_at, created_at) at time zone 'Asia/Jakarta', 'DD/MM/YYYY HH24:MI') as updated_at_wib,
          greatest(0, floor(extract(epoch from (now() - coalesce(locked_at, last_run_at, updated_at, created_at))) / 60)::int) as age_minutes,
          status = 'running' and coalesce(locked_at, last_run_at, updated_at, created_at) < v_stale_before as is_stale
        from public.marketplace_order_pull_jobs
        order by coalesce(updated_at, created_at) desc nulls last
        limit 12
      ) x
    ), '[]'::jsonb),
    'recent_finance_jobs', coalesce((
      select jsonb_agg(to_jsonb(x))
      from (
        select
          'Pembaruan payout' as title,
          status,
          attempts,
          coalesce(transaction_count, 0) as checked,
          coalesce(item_count, 0) as success,
          coalesce(last_message, 'Pembaruan payout selesai.') as message,
          to_char(coalesce(updated_at, created_at) at time zone 'Asia/Jakarta', 'DD/MM/YYYY HH24:MI') as updated_at_wib,
          greatest(0, floor(extract(epoch from (now() - coalesce(locked_at, last_run_at, updated_at, created_at))) / 60)::int) as age_minutes,
          status = 'running' and coalesce(locked_at, last_run_at, updated_at, created_at) < v_stale_before as is_stale,
          period_start,
          period_end
        from public.finance_sync_jobs
        order by coalesce(updated_at, created_at) desc nulls last
        limit 12
      ) x
    ), '[]'::jsonb),
    'recent_marketplace_logs', coalesce((
      select jsonb_agg(to_jsonb(x))
      from (
        select
          coalesce(action, 'marketplace_sync') as title,
          status,
          coalesce(message, '-') as message,
          to_char(created_at at time zone 'Asia/Jakarta', 'DD/MM/YYYY HH24:MI') as created_at_wib,
          greatest(0, floor(extract(epoch from (now() - created_at)) / 60)::int) as age_minutes,
          coalesce(case when response_payload->>'checked' ~ '^[-]?[0-9]+$' then (response_payload->>'checked')::int end, case when response_payload->>'orders' ~ '^[-]?[0-9]+$' then (response_payload->>'orders')::int end, 0) as checked,
          coalesce(case when response_payload->>'updated' ~ '^[-]?[0-9]+$' then (response_payload->>'updated')::int end, case when response_payload->>'items' ~ '^[-]?[0-9]+$' then (response_payload->>'items')::int end, 0) as success,
          coalesce(case when response_payload->>'failed' ~ '^[-]?[0-9]+$' then (response_payload->>'failed')::int end, 0) as failed,
          false as is_stale
        from public.marketplace_sync_logs
        order by created_at desc nulls last
        limit 12
      ) x
    ), '[]'::jsonb),
    'recent_sync_logs', coalesce((
      select jsonb_agg(to_jsonb(x))
      from (
        select
          'Riwayat pembaruan' as title,
          status,
          coalesce(checked_count, total_checked, 0) as checked,
          coalesce(success_count, total_success, 0) as success,
          coalesce(failed_count, total_failed, 0) as failed,
          message,
          to_char(coalesce(updated_at, created_at, finished_at) at time zone 'Asia/Jakarta', 'DD/MM/YYYY HH24:MI') as created_at_wib,
          greatest(0, floor(extract(epoch from (now() - coalesce(updated_at, created_at, finished_at))) / 60)::int) as age_minutes,
          false as is_stale
        from public.finance_sync_logs
        order by coalesce(updated_at, created_at, finished_at) desc nulls last
        limit 12
      ) x
    ), '[]'::jsonb)
  );
end;
$function$;

grant execute on function public.marketplace_job_monitor_snapshot_v24_6_9() to authenticated, service_role;

commit;
