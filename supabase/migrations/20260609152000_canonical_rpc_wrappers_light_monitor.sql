-- Canonical RPC wrappers and safe marketplace monitor
-- Generated from live Supabase functions on 2026-06-09.
-- Do not drop old RPC versions in this migration.
-- Stable baseline: keep finance snapshot/detail/order runner/payout cron logic unchanged.
CREATE OR REPLACE FUNCTION public.finance_sku_payout_count_summary(p_start date DEFAULT NULL::date, p_end date DEFAULT NULL::date, p_marketplace text DEFAULT NULL::text, p_account_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tenant_id uuid := public.app_current_tenant_id_or_default();
  v_start date := coalesce(p_start, current_date - 30);
  v_end date := coalesce(p_end, current_date);
  v_marketplace text := lower(trim(coalesce(p_marketplace, '')));
  v_result jsonb;
begin
  if v_marketplace in ('all', 'semua', 'semua platform', '-') then
    v_marketplace := '';
  end if;

  if (v_end - v_start) > 90 then
    v_start := v_end - 90;
  end if;

  with valid_orders as (
    select
      o.*,
      coalesce(nullif(o.external_order_id, ''), nullif(o.order_sn, ''), nullif(o.order_id, ''), o.marketplace_order_id::text) as order_key,
      (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta') as order_ts_wib,
      (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date as order_date_wib
    from public.marketplace_orders o
    where o.tenant_id = v_tenant_id
      and (v_marketplace = '' or lower(coalesce(o.marketplace, '')) = v_marketplace)
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date between v_start and v_end
  ),
  finance_by_order as (
    select
      fr.marketplace_account_id,
      coalesce(nullif(fr.order_id, ''), fr.marketplace_order_id::text) as order_key,
      sum(coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)) as payout_total,
      max(fr.statement_id::text) as statement_id,
      max(fr.settlement_status) as settlement_status,
      max(fr.pulled_at) as finance_at
    from public.marketplace_finance_reports fr
    where fr.tenant_id = v_tenant_id
      and (
        fr.order_id in (select external_order_id from valid_orders where external_order_id is not null and external_order_id <> '')
        or fr.order_id in (select order_sn from valid_orders where order_sn is not null and order_sn <> '')
        or fr.marketplace_order_id in (select marketplace_order_id from valid_orders)
      )
    group by 1, 2
  ),
  detail as (
    select
      vo.marketplace_account_id,
      vo.marketplace,
      vo.order_key,
      coalesce(vo.order_status, vo.status) as order_status,
      oi.marketplace_order_item_id,
      coalesce(nullif(oi.quantity, 0), nullif(oi.qty, 0), 1) as qty,
      coalesce(nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, '')) as marketplace_sku_id,
      coalesce(nullif(oi.marketplace_seller_sku, ''), nullif(oi.seller_sku, '')) as marketplace_seller_sku,
      coalesce(nullif(oi.mapped_local_sku, ''), nullif(oi.local_sku, ''), nullif(oi.seller_sku, ''), nullif(oi.marketplace_seller_sku, ''), nullif(oi.marketplace_sku_id, ''), '-') as local_sku,
      coalesce(nullif(oi.product_name, ''), nullif(oi.marketplace_product_name, ''), nullif(oi.local_product_name, '')) as product_name,
      coalesce(nullif(oi.variant_name, ''), nullif(oi.marketplace_variant_name, ''), nullif(oi.variation_name, '')) as variant_name,
      greatest(
        coalesce(oi.gross_amount, 0),
        coalesce(oi.paid_amount, 0),
        coalesce(oi.unit_gross_amount, 0) * greatest(coalesce(nullif(oi.quantity, 0), nullif(oi.qty, 0), 1), 1)
      ) as gross_line
    from valid_orders vo
    join public.marketplace_order_items oi
      on oi.tenant_id = vo.tenant_id
     and oi.marketplace_order_id = vo.marketplace_order_id
  ),
  enriched as (
    select
      d.*,
      fbo.payout_total as order_payout,
      fbo.settlement_status,
      sum(nullif(d.gross_line, 0)) over (partition by d.marketplace_account_id, d.order_key) as gross_order_scope,
      sum(d.qty) over (partition by d.marketplace_account_id, d.order_key) as qty_order_scope
    from detail d
    left join finance_by_order fbo
      on fbo.marketplace_account_id = d.marketplace_account_id
     and fbo.order_key = d.order_key
  ),
  allocated as (
    select
      *,
      case
        when coalesce(order_payout, 0) = 0 then 0
        when coalesce(gross_order_scope, 0) > 0 and gross_line > 0 then order_payout * gross_line / gross_order_scope
        when coalesce(qty_order_scope, 0) > 0 then order_payout * qty / qty_order_scope
        else order_payout
      end as payout_allocated
    from enriched
  ),
  calculated as (
    select
      a.*,
      upper(coalesce(a.order_status, '')) as order_status_upper,
      case
        when upper(coalesce(a.order_status, '')) like '%CANCEL%'
          or upper(coalesce(a.order_status, '')) like '%REFUND%'
          or upper(coalesce(a.order_status, '')) like '%RETURN%' then 'Cancel/Refund/Return'
        when coalesce(a.order_payout, 0) = 0 then 'Belum Payout'
        when a.payout_allocated < 0 then 'Payout Minus'
        else coalesce(nullif(a.settlement_status, ''), 'Settled')
      end as payout_status_clean
    from allocated a
  ),
  flagged as (
    select
      c.*,
      (
        c.order_status_upper like '%CANCEL%'
        or c.order_status_upper like '%REFUND%'
        or c.order_status_upper like '%RETURN%'
        or upper(c.payout_status_clean) like '%CANCEL%'
        or upper(c.payout_status_clean) like '%REFUND%'
        or upper(c.payout_status_clean) like '%RETURN%'
      ) as is_cancel_refund_return
    from calculated c
  ),
  grouped as (
    select
      marketplace_account_id,
      marketplace,
      coalesce(nullif(marketplace_sku_id, ''), '-') as marketplace_sku,
      coalesce(nullif(local_sku, ''), '-') as local_sku,
      max(product_name) as product_name,
      max(variant_name) as variant_name,

      count(*) filter (
        where not is_cancel_refund_return
          and coalesce(payout_allocated, 0) <> 0
      )::int as paid_rows,

      count(*) filter (
        where not is_cancel_refund_return
          and coalesce(payout_allocated, 0) = 0
          and payout_status_clean = 'Belum Payout'
      )::int as unpaid_rows,

      coalesce(sum(qty) filter (
        where not is_cancel_refund_return
          and coalesce(payout_allocated, 0) <> 0
      ), 0)::numeric as paid_qty,

      coalesce(sum(qty) filter (
        where not is_cancel_refund_return
          and coalesce(payout_allocated, 0) = 0
          and payout_status_clean = 'Belum Payout'
      ), 0)::numeric as unpaid_qty,

      coalesce(sum(gross_line) filter (
        where not is_cancel_refund_return
          and coalesce(payout_allocated, 0) <> 0
      ), 0)::numeric as paid_gross_total,

      coalesce(sum(gross_line) filter (
        where not is_cancel_refund_return
          and coalesce(payout_allocated, 0) = 0
          and payout_status_clean = 'Belum Payout'
      ), 0)::numeric as unpaid_gross_total,

      coalesce(sum(payout_allocated) filter (
        where not is_cancel_refund_return
          and coalesce(payout_allocated, 0) <> 0
      ), 0)::numeric as paid_payout_total,

      count(*)::int as all_rows,
      coalesce(sum(qty), 0)::numeric as all_qty
    from flagged
    group by 1, 2, 3, 4
  )
  select jsonb_build_object(
    'ok', true,
    'version', 'finance_sku_payout_count_summary_2026_06_09',
    'start', v_start,
    'end', v_end,
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'marketplace_account_id', marketplace_account_id,
      'marketplace', marketplace,
      'marketplace_sku', marketplace_sku,
      'local_sku', local_sku,
      'product_name', product_name,
      'variant_name', variant_name,

      'paid_rows', paid_rows,
      'unpaid_rows', unpaid_rows,
      'paid_qty', paid_qty,
      'unpaid_qty', unpaid_qty,

      'settled_qty', paid_qty,
      'qty_unpaid', unpaid_qty,
      'paid_total', paid_rows,
      'unpaid_total', unpaid_rows,

      'paid_gross_total', paid_gross_total,
      'unpaid_gross_total', unpaid_gross_total,
      'paid_payout_total', paid_payout_total,

      'all_rows', all_rows,
      'all_qty', all_qty
    ) order by all_qty desc, product_name, variant_name), '[]'::jsonb)
  )
  into v_result
  from grouped;

  return coalesce(v_result, jsonb_build_object(
    'ok', true,
    'version', 'finance_sku_payout_count_summary_2026_06_09',
    'start', v_start,
    'end', v_end,
    'rows', '[]'::jsonb
  ));
end;
$function$;

CREATE OR REPLACE FUNCTION public.marketplace_finance_pull_status()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_counts jsonb := jsonb_build_object(
    'pending', 0,
    'running', 0,
    'active_running', 0,
    'stale_running', 0,
    'done', 0,
    'failed', 0,
    'retry', 0,
    'cancelled', 0
  );
  v_recent jsonb := '[]'::jsonb;
begin
  if to_regclass('public.finance_sync_jobs') is null then
    return jsonb_build_object(
      'counts', v_counts,
      'recent_jobs', v_recent,
      'source_table', 'public.finance_sync_jobs_missing'
    );
  end if;

  with jobs as (
    select
      to_jsonb(j) as row,
      lower(coalesce(to_jsonb(j)->>'status', '')) as status,
      coalesce(
        nullif(to_jsonb(j)->>'updated_at', '')::timestamptz,
        nullif(to_jsonb(j)->>'finished_at', '')::timestamptz,
        nullif(to_jsonb(j)->>'last_run_at', '')::timestamptz,
        nullif(to_jsonb(j)->>'created_at', '')::timestamptz,
        now() - interval '100 years'
      ) as ts
    from public.finance_sync_jobs j
    where coalesce(
        nullif(to_jsonb(j)->>'updated_at', '')::timestamptz,
        nullif(to_jsonb(j)->>'finished_at', '')::timestamptz,
        nullif(to_jsonb(j)->>'last_run_at', '')::timestamptz,
        nullif(to_jsonb(j)->>'created_at', '')::timestamptz,
        now() - interval '100 years'
      ) >= now() - interval '14 days'
  ),
  counts as (
    select
      count(*) filter (where status in ('pending', 'queued'))::int as pending,
      count(*) filter (where status = 'running')::int as running,
      count(*) filter (
        where status = 'running'
          and ts >= now() - interval '20 minutes'
      )::int as active_running,
      count(*) filter (
        where status = 'running'
          and ts < now() - interval '20 minutes'
      )::int as stale_running,
      count(*) filter (where status in ('done', 'success', 'completed'))::int as done,
      count(*) filter (where status in ('failed', 'error'))::int as failed,
      count(*) filter (where status = 'retry')::int as retry,
      count(*) filter (where status in ('cancelled', 'canceled'))::int as cancelled
    from jobs
  ),
  recent as (
    select row, status, ts
    from jobs
    order by ts desc
    limit 12
  )
  select
    jsonb_build_object(
      'pending', coalesce(c.pending, 0),
      'running', coalesce(c.running, 0),
      'active_running', coalesce(c.active_running, 0),
      'stale_running', coalesce(c.stale_running, 0),
      'done', coalesce(c.done, 0),
      'failed', coalesce(c.failed, 0),
      'retry', coalesce(c.retry, 0),
      'cancelled', coalesce(c.cancelled, 0)
    ),
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'title', 'Pembaruan payout otomatis',
          'status', case
            when status in ('done', 'success', 'completed') then 'done'
            when status in ('failed', 'error') then 'failed'
            when status in ('pending', 'queued') then 'pending'
            else coalesce(nullif(status, ''), 'done')
          end,
          'updated_at_wib', to_char(timezone('Asia/Jakarta', ts), 'DD/MM/YYYY HH24:MI'),
          'created_at_wib', to_char(timezone('Asia/Jakarta', ts), 'DD/MM/YYYY HH24:MI'),
          'age_minutes', greatest(0, floor(extract(epoch from (now() - ts)) / 60)::int),

          'checked', coalesce(
            nullif(row#>>'{last_result,checked}', '')::int,
            nullif(row->>'transaction_count', '')::int,
            nullif(row->>'item_count', '')::int,
            0
          ),
          'success', coalesce(
            nullif(row#>>'{last_result,success}', '')::int,
            nullif(row->>'item_count', '')::int,
            nullif(row->>'transaction_count', '')::int,
            0
          ),
          'failed', coalesce(
            nullif(row#>>'{last_result,failed}', '')::int,
            case when status in ('failed', 'error') then 1 else 0 end,
            0
          ),

          'period_start', row->>'period_start',
          'period_end', row->>'period_end',
          'job_type', row->>'job_type',
          'marketplace', row->>'marketplace',
          'attempts', coalesce(nullif(row->>'attempts', '')::int, 0),
          'is_stale', status = 'running' and ts < now() - interval '20 minutes',
          'message', coalesce(
            nullif(row->>'last_message', ''),
            nullif(row#>>'{last_result,message}', ''),
            'Finance selesai.'
          )
        )
        order by ts desc
      )
      from recent
    ), '[]'::jsonb)
  into v_counts, v_recent
  from counts c;

  return jsonb_build_object(
    'counts', coalesce(v_counts, '{}'::jsonb),
    'recent_jobs', coalesce(v_recent, '[]'::jsonb),
    'source_table', 'public.finance_sync_jobs'
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.marketplace_job_monitor_snapshot_light()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_order jsonb := jsonb_build_object('counts', '{}'::jsonb, 'recent_jobs', '[]'::jsonb);
  v_finance jsonb := jsonb_build_object('counts', '{}'::jsonb, 'recent_jobs', '[]'::jsonb);
  v_status jsonb := jsonb_build_object(
    'nonfinal_order_refresh_candidates', '{}'::jsonb,
    'status_refresh_runs', '{}'::jsonb,
    'recent_status_refresh_logs', '[]'::jsonb
  );
  v_account_auth jsonb := '[]'::jsonb;
  v_recent jsonb := '[]'::jsonb;
  v_recent_marketplace jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
begin
  begin
    v_order := public.marketplace_order_pull_status();
  exception when others then
    v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
      'section', 'order_status',
      'error', sqlerrm
    ));
  end;

  begin
    v_finance := public.marketplace_finance_pull_status();
  exception when others then
    v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
      'section', 'finance_status',
      'error', sqlerrm
    ));
  end;

  begin
    v_status := public.marketplace_status_refresh_status();
  exception when others then
    v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
      'section', 'status_refresh',
      'error', sqlerrm
    ));
  end;

  begin
    v_account_auth := public.marketplace_account_auth_status();
  exception when others then
    v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
      'section', 'account_auth',
      'error', sqlerrm
    ));
  end;

  begin
    v_recent := public.marketplace_recent_sync_logs(12, null);
  exception when others then
    v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
      'section', 'recent_sync_logs',
      'error', sqlerrm
    ));
  end;

  begin
    v_recent_marketplace := public.marketplace_recent_sync_logs(12, 'order_pull');
  exception when others then
    v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
      'section', 'recent_marketplace_logs',
      'error', sqlerrm
    ));
  end;

  return jsonb_build_object(
    'ok', true,
    'version', 'canonical_light_monitor_safe_2026_06_09',
    'generated_at_wib', to_char(timezone('Asia/Jakarta', now()), 'DD/MM/YYYY HH24:MI:SS'),
    'stale_threshold_minutes', 20,
    'warnings', v_warnings,

    'account_auth', coalesce(v_account_auth, '[]'::jsonb),

    'order_counts', coalesce(v_order->'counts', '{}'::jsonb),
    'recent_order_jobs', coalesce(v_order->'recent_jobs', '[]'::jsonb),

    'finance_counts', coalesce(v_finance->'counts', '{}'::jsonb),
    'recent_finance_jobs', coalesce(v_finance->'recent_jobs', '[]'::jsonb),

    'nonfinal_order_refresh_candidates', coalesce(v_status->'nonfinal_order_refresh_candidates', '{}'::jsonb),
    'status_refresh_runs', coalesce(v_status->'status_refresh_runs', '{}'::jsonb),
    'recent_status_refresh_logs', coalesce(v_status->'recent_status_refresh_logs', '[]'::jsonb),

    'recent_marketplace_logs', coalesce(v_recent_marketplace, '[]'::jsonb),
    'recent_sync_logs', coalesce(v_recent, '[]'::jsonb),

    'order_status_refresh_policy', jsonb_build_object(
      'range_days', 90,
      'priority', 'payout_positive_nonfinal_first',
      'note', 'Order status tetap dari marketplace order API. Payout hanya dipakai untuk prioritas refresh dan warning UI.',
      'target_statuses', jsonb_build_array(
        'AWAITING_SHIPMENT',
        'AWAITING_COLLECTION',
        'IN_TRANSIT',
        'DELIVERED',
        'READY_TO_SHIP',
        'TO_SHIP',
        'TO_PACK'
      )
    )
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.marketplace_job_monitor_snapshot_v24_6_9()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select public.marketplace_job_monitor_snapshot_light();
$function$;
