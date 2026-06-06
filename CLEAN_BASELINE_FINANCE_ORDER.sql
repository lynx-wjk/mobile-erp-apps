-- CLEAN_BASELINE_FINANCE_ORDER.sql
-- Patch40 direct override baseline for finance report, marketplace order queue,
-- and job monitor RPCs. Direct overrides only; no new version suffixes.
-- Review, then run in Supabase SQL editor. This file is not auto-applied.

begin;

create extension if not exists pgcrypto;

create table if not exists public.marketplace_auto_runner_locks (
  lock_key text primary key,
  owner text,
  locked_until timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.marketplace_auto_runner_locks
  add column if not exists owner text,
  add column if not exists locked_until timestamptz not null default now(),
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists updated_at timestamptz not null default now();

alter table public.finance_auto_sync_settings
  add column if not exists enabled boolean,
  add column if not exists max_orders_per_account integer;

alter table public.finance_sync_logs
  add column if not exists checked_count integer,
  add column if not exists success_count integer,
  add column if not exists failed_count integer,
  add column if not exists skipped_count integer,
  add column if not exists raw_response jsonb,
  add column if not exists job_type text,
  add column if not exists finished_at timestamptz,
  add column if not exists updated_at timestamptz;

create table if not exists public.marketplace_order_pull_settings (
  tenant_id uuid primary key,
  auto_order_pull_enabled boolean not null default false,
  interval_minutes integer not null default 10,
  days_back integer not null default 3,
  previous_unpacked_days integer not null default 3,
  last_auto_run_at timestamptz,
  last_auto_run_message text,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.marketplace_order_pull_settings
  add column if not exists auto_order_pull_enabled boolean not null default false,
  add column if not exists interval_minutes integer not null default 10,
  add column if not exists days_back integer not null default 3,
  add column if not exists previous_unpacked_days integer not null default 3,
  add column if not exists last_auto_run_at timestamptz,
  add column if not exists last_auto_run_message text,
  add column if not exists updated_by uuid,
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists updated_at timestamptz not null default now();

-- ---------------------------------------------------------------------------
-- Finance auto sync setting used by finance_report_page.dart
-- ---------------------------------------------------------------------------

create or replace function public.finance_get_auto_sync_setting()
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_tenant_id uuid := public.app_current_tenant_id_or_default();
  v_row public.finance_auto_sync_settings%rowtype;
begin
  insert into public.finance_auto_sync_settings (
    tenant_id,
    auto_finance_sync_enabled,
    enabled,
    interval_minutes,
    max_orders_per_account,
    created_at,
    updated_at
  )
  select v_tenant_id, false, false, 10, 20, now(), now()
  where v_tenant_id is not null
    and not exists (
      select 1
      from public.finance_auto_sync_settings s
      where s.tenant_id = v_tenant_id
    );

  select *
    into v_row
  from public.finance_auto_sync_settings s
  where s.tenant_id = v_tenant_id
  order by s.updated_at desc nulls last
  limit 1;

  return jsonb_build_object(
    'auto_finance_sync_enabled', coalesce(v_row.auto_finance_sync_enabled, v_row.enabled, false),
    'enabled', coalesce(v_row.enabled, v_row.auto_finance_sync_enabled, false),
    'interval_minutes', coalesce(v_row.interval_minutes, 10),
    'max_orders_per_account', coalesce(v_row.max_orders_per_account, 20),
    'last_auto_run_at', v_row.last_auto_run_at,
    'last_auto_run_message', v_row.last_auto_run_message,
    'updated_at', v_row.updated_at
  );
end;
$function$;

create or replace function public.finance_set_auto_sync_enabled(
  p_enabled boolean,
  p_interval_minutes integer default 10
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_tenant_id uuid := public.app_current_tenant_id_or_default();
  v_interval integer := greatest(5, least(1440, coalesce(p_interval_minutes, 10)));
begin
  insert into public.finance_auto_sync_settings (
    tenant_id,
    auto_finance_sync_enabled,
    enabled,
    interval_minutes,
    max_orders_per_account,
    updated_by,
    created_at,
    updated_at
  )
  values (
    v_tenant_id,
    coalesce(p_enabled, false),
    coalesce(p_enabled, false),
    v_interval,
    20,
    nullif(auth.uid()::text, '')::uuid,
    now(),
    now()
  )
  on conflict (tenant_id) do update
     set auto_finance_sync_enabled = excluded.auto_finance_sync_enabled,
         enabled = excluded.enabled,
         interval_minutes = excluded.interval_minutes,
         updated_by = excluded.updated_by,
         updated_at = now();

  return public.finance_get_auto_sync_setting();
end;
$function$;

-- ---------------------------------------------------------------------------
-- Finance report free-plan readers
-- ---------------------------------------------------------------------------

create or replace function public.finance_customer_dashboard_snapshot_v24_6_82o(
  p_start_date date,
  p_end_date date,
  p_marketplace_filter text default null,
  p_account_id_filter uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_tenant_id uuid := public.app_current_tenant_id_or_default();
  v_start date := coalesce(p_start_date, current_date);
  v_end date := coalesce(p_end_date, coalesce(p_start_date, current_date));
  v_tmp date;
  v_marketplace text := nullif(lower(trim(coalesce(p_marketplace_filter, ''))), '');
  v_manual_expense numeric := 0;
  v_purchase_expense numeric := 0;
  v_accounts jsonb := '[]'::jsonb;
  v_by_sku jsonb := '[]'::jsonb;
  v_by_marketplace jsonb := '[]'::jsonb;
  v_expenses jsonb := '[]'::jsonb;
  v_purchases jsonb := '[]'::jsonb;
  v_anomalies jsonb := '[]'::jsonb;
  v_daily jsonb := '[]'::jsonb;
  v_anomaly_report jsonb := '{}'::jsonb;
  v_anomaly_aggregates jsonb := '{}'::jsonb;
  v_summary jsonb := '{}'::jsonb;
begin
  if v_start > v_end then
    v_tmp := v_start;
    v_start := v_end;
    v_end := v_tmp;
  end if;

  if v_marketplace in ('all', 'semua', 'semua platform', '-') then
    v_marketplace := null;
  end if;

  select coalesce(jsonb_agg(to_jsonb(a) order by a.marketplace, a.store_label), '[]'::jsonb)
    into v_accounts
  from (
    select
      ma.marketplace_account_id,
      ma.tenant_id,
      ma.marketplace,
      coalesce(nullif(ma.store_alias, ''), nullif(ma.shop_name, ''), ma.marketplace_account_id::text) as store_label,
      ma.store_alias,
      ma.shop_name,
      ma.shop_region,
      ma.status,
      ma.connected_at,
      ma.reauthorized_at,
      ma.updated_at
    from public.marketplace_accounts ma
    where ma.tenant_id = v_tenant_id
      and coalesce(ma.is_deleted, false) = false
      and lower(coalesce(ma.status, '')) not in ('deleted', 'revoked', 'inactive_deleted')
      and (v_marketplace is null or lower(coalesce(ma.marketplace, '')) = v_marketplace)
      and (p_account_id_filter is null or ma.marketplace_account_id = p_account_id_filter)
    order by ma.marketplace, coalesce(ma.store_alias, ma.shop_name, ma.marketplace_account_id::text)
  ) a;

  select coalesce(sum(e.amount), 0),
         coalesce(jsonb_agg(to_jsonb(e) order by coalesce(e.expense_date, e.paid_at) desc, e.created_at desc), '[]'::jsonb)
    into v_manual_expense, v_expenses
  from (
    select
      e.expense_id,
      coalesce(e.finance_operational_expense_id, e.expense_id) as operational_expense_id,
      e.tenant_id,
      e.category,
      e.description,
      e.amount,
      coalesce(e.expense_date, e.paid_at) as expense_date,
      e.paid_at,
      coalesce(e.status, 'paid') as status,
      e.note,
      e.created_at,
      e.updated_at,
      'manual_expense' as source
    from public.finance_operational_expenses e
    where e.tenant_id = v_tenant_id
      and coalesce(e.expense_date, e.paid_at) between v_start and v_end
  ) e;

  select coalesce(sum(p.total_pembelian), 0),
         coalesce(jsonb_agg(to_jsonb(p) order by p.tanggal desc, p.created_at desc), '[]'::jsonb)
    into v_purchase_expense, v_purchases
  from (
    select
      p.purchase_id,
      p.nomor_pembelian,
      p.tanggal,
      p.supplier_name,
      p.total_pembelian,
      p.status,
      p.catatan,
      p.created_at,
      'approved_purchase' as source
    from public.purchases p
    where p.tenant_id = v_tenant_id
      and p.tanggal between v_start and v_end
      and lower(coalesce(p.status, '')) in ('approved', 'verified_finance', 'selesai', 'done')
  ) p;

  with valid_orders as (
    select
      o.*,
      coalesce(nullif(o.external_order_id, ''), nullif(o.order_sn, ''), nullif(o.order_id, ''), o.marketplace_order_id::text) as order_key,
      (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date as order_date_wib
    from public.marketplace_orders o
    where o.tenant_id = v_tenant_id
      and (v_marketplace is null or lower(coalesce(o.marketplace, '')) = v_marketplace)
      and (p_account_id_filter is null or o.marketplace_account_id = p_account_id_filter)
      and (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date between v_start and v_end
      and upper(coalesce(o.order_status, o.status, '')) not like all (array['%CANCEL%', '%UNPAID%', '%REFUND%', '%RETURN%', '%FAILED%', '%CLOSE%'])
  ),
  finance_by_order as (
    select
      fr.marketplace_account_id,
      coalesce(nullif(fr.order_id, ''), fr.marketplace_order_id::text) as order_key,
      sum(coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)) as payout_total,
      max(fr.statement_id::text) as statement_id,
      max(fr.settlement_status) as settlement_status,
      max(fr.settlement_date) as settlement_date,
      max(fr.pulled_at) as finance_at
    from public.marketplace_finance_reports fr
    where fr.tenant_id = v_tenant_id
      and (v_marketplace is null or lower(coalesce(fr.marketplace, '')) = v_marketplace)
      and (p_account_id_filter is null or fr.marketplace_account_id = p_account_id_filter)
    group by 1, 2
  ),
  item_lines as (
    select
      vo.tenant_id,
      vo.marketplace_account_id,
      vo.marketplace,
      vo.order_key,
      vo.external_order_id,
      vo.order_sn,
      vo.marketplace_order_id,
      coalesce(vo.tracking_number, vo.label_code) as tracking_number,
      coalesce(vo.order_status, vo.status) as order_status,
      vo.order_date_wib,
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
      il.*,
      coalesce(h.hpp, h.hpp_amount, 0) as hpp_per_item,
      coalesce(h.target_margin_percent, h.target_margin, 0) as target_margin_percent,
      fbo.payout_total as order_payout,
      fbo.statement_id,
      fbo.settlement_status,
      fbo.finance_at,
      sum(nullif(il.gross_line, 0)) over (partition by il.marketplace_account_id, il.order_key) as gross_order_scope,
      sum(il.qty) over (partition by il.marketplace_account_id, il.order_key) as qty_order_scope
    from item_lines il
    left join finance_by_order fbo
      on fbo.marketplace_account_id = il.marketplace_account_id
     and fbo.order_key = il.order_key
    left join lateral (
      select hm.*
      from public.marketplace_variant_hpp_mappings hm
      where coalesce(hm.is_active, true) = true
        and hm.tenant_id = il.tenant_id
        and hm.marketplace_account_id = il.marketplace_account_id
        and (
          hm.marketplace_sku_id = il.marketplace_sku_id
          or hm.marketplace_seller_sku = il.marketplace_seller_sku
          or hm.local_sku = il.local_sku
        )
      order by hm.updated_at desc nulls last, hm.created_at desc nulls last
      limit 1
    ) h on true
  ),
  final_lines as (
    select
      e.*,
      case
        when coalesce(e.order_payout, 0) = 0 then 0
        when coalesce(e.gross_order_scope, 0) > 0 and e.gross_line > 0 then e.order_payout * e.gross_line / e.gross_order_scope
        when coalesce(e.qty_order_scope, 0) > 0 then e.order_payout * e.qty / e.qty_order_scope
        else e.order_payout
      end as payout_allocated
    from enriched e
  ),
  ranked_details as (
    select
      fl.*,
      row_number() over (
        partition by fl.local_sku
        order by fl.order_date_wib desc nulls last, fl.order_key desc
      ) as detail_rank
    from final_lines fl
  ),
  sku_group as (
    select
      local_sku as sku,
      local_sku,
      max(marketplace_sku_id) as marketplace_sku_id,
      max(marketplace_sku_id) as marketplace_sku,
      max(marketplace_seller_sku) as marketplace_seller_sku,
      max(product_name) as product_name,
      max(variant_name) as variant_name,
      max(marketplace) as marketplace,
      max(marketplace_account_id::text)::uuid as marketplace_account_id,
      sum(qty) as qty_total,
      sum(case when coalesce(order_payout, 0) <> 0 then qty else 0 end) as paid_qty,
      sum(case when coalesce(order_payout, 0) = 0 then qty else 0 end) as unpaid_qty,
      sum(gross_line) as gross_total,
      sum(case when coalesce(order_payout, 0) <> 0 then gross_line else 0 end) as paid_gross_total,
      sum(case when coalesce(order_payout, 0) = 0 then gross_line else 0 end) as unpaid_gross_total,
      sum(payout_allocated) as payout_total,
      sum(case when coalesce(order_payout, 0) <> 0 then hpp_per_item * qty else 0 end) as hpp_total,
      sum(hpp_per_item * qty) as estimated_hpp_total,
      max(hpp_per_item) as hpp_per_item,
      max(target_margin_percent) as target_margin_percent,
      count(distinct order_key) filter (where coalesce(order_payout, 0) <> 0) as paid_order_count,
      count(distinct order_key) filter (where coalesce(order_payout, 0) = 0) as unpaid_order_count,
      coalesce(jsonb_agg(jsonb_build_object(
        'order', order_key,
        'order_id', order_key,
        'order_sn', order_sn,
        'external_order_id', external_order_id,
        'tracking_number', tracking_number,
        'resi', tracking_number,
        'order_date', order_date_wib,
        'order_created_at', order_date_wib,
        'gross', gross_line,
        'gross_amount', gross_line,
        'payout', payout_allocated,
        'payout_amount', payout_allocated,
        'payout_total', payout_allocated,
        'status', order_status,
        'payout_status', case when coalesce(order_payout, 0) <> 0 then coalesce(settlement_status, 'SETTLED') else 'PENDING_PAYOUT' end,
        'order_status', order_status,
        'qty', qty,
        'marketplace_sku_id', marketplace_sku_id,
        'marketplace_sku', marketplace_sku_id,
        'marketplace_seller_sku', marketplace_seller_sku,
        'local_sku', local_sku,
        'variant_name', variant_name,
        'product_name', product_name,
        'statement_id', statement_id,
        'hpp_per_item', hpp_per_item,
        'hpp', hpp_per_item * qty,
        'hpp_total', hpp_per_item * qty,
        'net_profit', payout_allocated - (hpp_per_item * qty),
        'margin', payout_allocated - (hpp_per_item * qty),
        'margin_percent', case when payout_allocated <> 0 then ((payout_allocated - (hpp_per_item * qty)) / payout_allocated) * 100 else 0 end,
        'source', 'direct_order_reader_v24_6_82o'
      ) order by order_date_wib desc, order_key desc) filter (where detail_rank <= 40), '[]'::jsonb) as order_details
    from ranked_details
    group by local_sku
  ),
  marketplace_group as (
    select
      fl.marketplace,
      fl.marketplace_account_id,
      coalesce(nullif(max(ma.store_alias), ''), nullif(max(ma.shop_name), ''), fl.marketplace_account_id::text) as shop_name,
      count(distinct fl.order_key) as order_count,
      sum(fl.qty) as qty_total,
      sum(fl.gross_line) as gross_sales,
      sum(fl.payout_allocated) as payout_total,
      sum(case when coalesce(fl.order_payout, 0) <> 0 then fl.hpp_per_item * fl.qty else 0 end) as hpp_total
    from final_lines fl
    left join public.marketplace_accounts ma
      on ma.marketplace_account_id = fl.marketplace_account_id
    group by fl.marketplace, fl.marketplace_account_id
  ),
  daily_group as (
    select
      fl.order_date_wib as report_date,
      count(distinct fl.order_key) as order_count,
      coalesce(sum(fl.qty), 0) as qty_total,
      coalesce(sum(fl.gross_line), 0) as gross_total,
      coalesce(sum(fl.payout_allocated), 0) as payout_total,
      coalesce(sum(case when coalesce(fl.order_payout, 0) <> 0 then fl.hpp_per_item * fl.qty else 0 end), 0) as hpp_total,
      coalesce(sum(fl.payout_allocated), 0)
        - coalesce(sum(case when coalesce(fl.order_payout, 0) <> 0 then fl.hpp_per_item * fl.qty else 0 end), 0) as net_profit
    from final_lines fl
    group by fl.order_date_wib
  ),
  summary as (
    select
      count(distinct order_key) as orders_count,
      coalesce(sum(qty), 0) as qty_total,
      coalesce(sum(gross_line), 0) as gross_total,
      coalesce(sum(payout_allocated), 0) as payout_total,
      coalesce(sum(case when coalesce(order_payout, 0) <> 0 then hpp_per_item * qty else 0 end), 0) as hpp_total,
      coalesce(sum(hpp_per_item * qty), 0) as estimated_hpp_total,
      coalesce(sum(case when coalesce(hpp_per_item, 0) <= 0 then 1 else 0 end), 0) as missing_hpp_count,
      count(distinct order_key) filter (where coalesce(order_payout, 0) <> 0) as settled_order_count,
      count(distinct order_key) filter (where coalesce(order_payout, 0) = 0) as pending_payout_order_count,
      count(distinct local_sku) as sku_count
    from final_lines
  )
  select
    coalesce((select jsonb_agg(to_jsonb(s) || jsonb_build_object(
      'gross_sales', s.gross_total,
      'gross_amount', s.gross_total,
      'payout_amount', s.payout_total,
      'received_amount', s.payout_total,
      'paid_qty_total', s.paid_qty,
      'settled_qty', s.paid_qty,
      'pending_payout_qty_total', s.unpaid_qty,
      'qty_unpaid', s.unpaid_qty,
      'paid_hpp_total', s.hpp_total,
      'settled_hpp_total', s.hpp_total,
      'total_hpp', s.hpp_total,
      'profit', s.payout_total - s.hpp_total,
      'net_profit', s.payout_total - s.hpp_total,
      'margin_percent', case when s.payout_total <> 0 then ((s.payout_total - s.hpp_total) / s.payout_total) * 100 else 0 end,
      'order_details', s.order_details
    ) order by s.payout_total desc, s.gross_total desc) from sku_group s), '[]'::jsonb),
    coalesce((select jsonb_agg(to_jsonb(m) || jsonb_build_object(
      'store_label', m.shop_name,
      'payout_amount', m.payout_total,
      'received_amount', m.payout_total,
      'profit', m.payout_total - m.hpp_total,
      'net_profit', m.payout_total - m.hpp_total,
      'margin_percent', case when m.payout_total <> 0 then ((m.payout_total - m.hpp_total) / m.payout_total) * 100 else 0 end
    ) order by m.payout_total desc) from marketplace_group m), '[]'::jsonb),
    coalesce((select jsonb_build_object(
      'orders_count', orders_count,
      'order_count', orders_count,
      'finance_order_count', settled_order_count,
      'settled_order_count', settled_order_count,
      'pending_payout_order_count', pending_payout_order_count,
      'qty_total', qty_total,
      'gross_total', gross_total,
      'gross_sales', gross_total,
      'omzet_total', gross_total,
      'payout_total', payout_total,
      'payout_amount', payout_total,
      'received_amount', payout_total,
      'hpp_total', hpp_total,
      'total_hpp', hpp_total,
      'settled_hpp_total', hpp_total,
      'estimated_hpp_total', estimated_hpp_total,
      'manual_expense_total', v_manual_expense,
      'approved_purchase_total', v_purchase_expense,
      'expense_total', v_manual_expense + v_purchase_expense,
      'operational_expense', v_manual_expense + v_purchase_expense,
      'net_profit', payout_total - hpp_total - v_manual_expense - v_purchase_expense,
      'profit', payout_total - hpp_total - v_manual_expense - v_purchase_expense,
      'missing_hpp_count', missing_hpp_count,
      'sku_count', sku_count,
      'marketplace_count', jsonb_array_length(v_accounts),
      'margin_percent', case when payout_total <> 0 then ((payout_total - hpp_total - v_manual_expense - v_purchase_expense) / payout_total) * 100 else 0 end,
      'summary_policy', 'direct_order_date_reader_free_plan_no_monthly_snapshot'
    ) from summary), jsonb_build_object(
      'orders_count', 0,
      'order_count', 0,
      'finance_order_count', 0,
      'settled_order_count', 0,
      'pending_payout_order_count', 0,
      'qty_total', 0,
      'gross_total', 0,
      'gross_sales', 0,
      'omzet_total', 0,
      'payout_total', 0,
      'payout_amount', 0,
      'received_amount', 0,
      'hpp_total', 0,
      'total_hpp', 0,
      'settled_hpp_total', 0,
      'estimated_hpp_total', 0,
      'manual_expense_total', v_manual_expense,
      'approved_purchase_total', v_purchase_expense,
      'expense_total', v_manual_expense + v_purchase_expense,
      'operational_expense', v_manual_expense + v_purchase_expense,
      'net_profit', 0 - v_manual_expense - v_purchase_expense,
      'profit', 0 - v_manual_expense - v_purchase_expense,
      'missing_hpp_count', 0,
      'sku_count', 0,
      'marketplace_count', jsonb_array_length(v_accounts),
      'margin_percent', 0,
      'summary_policy', 'direct_order_date_reader_free_plan_empty'
    )),
    coalesce((select jsonb_agg(to_jsonb(d) || jsonb_build_object(
      'date', d.report_date,
      'gross_sales', d.gross_total,
      'omzet_total', d.gross_total,
      'payout_amount', d.payout_total,
      'received_amount', d.payout_total,
      'profit', d.net_profit
    ) order by d.report_date) from daily_group d), '[]'::jsonb)
  into v_by_sku, v_by_marketplace, v_summary, v_daily;

  v_anomaly_report := coalesce(public.finance_anomaly_search_v24_6_82e(
    v_start,
    v_end,
    v_marketplace,
    p_account_id_filter,
    null,
    null,
    1,
    20
  ), '{}'::jsonb);
  v_anomalies := coalesce(v_anomaly_report->'rows', '[]'::jsonb);
  v_anomaly_aggregates := coalesce(v_anomaly_report->'aggregates', '{}'::jsonb);
  v_summary := v_summary || jsonb_build_object(
    'anomaly_count', coalesce(nullif(v_anomaly_report->>'total', '')::integer, 0),
    'negative_payout_count', coalesce(nullif(v_anomaly_aggregates->>'negative_payout_count', '')::integer, 0),
    'negative_payout_total', coalesce(nullif(v_anomaly_aggregates->>'negative_payout_total', '')::numeric, 0),
    'minus_payout_total', coalesce(nullif(v_anomaly_aggregates->>'negative_payout_total', '')::numeric, 0),
    'payout_minus_total', coalesce(nullif(v_anomaly_aggregates->>'negative_payout_total', '')::numeric, 0),
    'total_negative_payout', coalesce(nullif(v_anomaly_aggregates->>'negative_payout_total', '')::numeric, 0),
    'missing_payout_count', coalesce(nullif(v_anomaly_aggregates->>'missing_payout_count', '')::integer, 0),
    'pending_payout_count', coalesce(nullif(v_anomaly_aggregates->>'pending_payout_count', '')::integer, 0),
    'cancel_refund_count', coalesce(nullif(v_anomaly_aggregates->>'cancel_refund_count', '')::integer, 0),
    'cancel_refund_total', coalesce(nullif(v_anomaly_aggregates->>'cancel_refund_total', '')::numeric, 0)
  );

  return jsonb_build_object(
    'ok', true,
    'version', 'v24_6_82o_direct_baseline_free_plan',
    'meta', jsonb_build_object(
      'requested_start', v_start,
      'requested_end', v_end,
      'date_policy', 'order_created_at_wib',
      'reader_policy', 'paginated_light_no_monthly_snapshot',
      'free_plan_safe', true
    ),
    'accounts', v_accounts,
    'summary', v_summary,
    'by_marketplace', v_by_marketplace,
    'marketplaces', v_by_marketplace,
    'by_sku', v_by_sku,
    'sku', v_by_sku,
    'sku_margin', v_by_sku,
    'cash_flow', jsonb_build_array(
      jsonb_build_object('label', 'Payout marketplace', 'amount', coalesce((v_summary->>'payout_total')::numeric, 0), 'type', 'in'),
      jsonb_build_object('label', 'HPP settled', 'amount', -coalesce((v_summary->>'hpp_total')::numeric, 0), 'type', 'out'),
      jsonb_build_object('label', 'Biaya operasional', 'amount', -coalesce((v_summary->>'expense_total')::numeric, 0), 'type', 'out')
    ),
    'cashflow', jsonb_build_array(
      jsonb_build_object('label', 'Payout marketplace', 'amount', coalesce((v_summary->>'payout_total')::numeric, 0), 'type', 'in'),
      jsonb_build_object('label', 'HPP settled', 'amount', -coalesce((v_summary->>'hpp_total')::numeric, 0), 'type', 'out'),
      jsonb_build_object('label', 'Biaya operasional', 'amount', -coalesce((v_summary->>'expense_total')::numeric, 0), 'type', 'out')
    ),
    'daily', v_daily,
    'by_date', v_daily,
    'expenses', v_expenses,
    'biaya', v_expenses,
    'approved_purchases', v_purchases,
    'purchases_approved', v_purchases,
    'profit_loss_breakdown', jsonb_build_array(
      jsonb_build_object('label', 'Omzet', 'amount', coalesce((v_summary->>'gross_total')::numeric, 0)),
      jsonb_build_object('label', 'Payout', 'amount', coalesce((v_summary->>'payout_total')::numeric, 0)),
      jsonb_build_object('label', 'HPP', 'amount', -coalesce((v_summary->>'hpp_total')::numeric, 0)),
      jsonb_build_object('label', 'Biaya', 'amount', -coalesce((v_summary->>'expense_total')::numeric, 0)),
      jsonb_build_object('label', 'Laba rugi', 'amount', coalesce((v_summary->>'net_profit')::numeric, 0))
    ),
    'profit_loss', jsonb_build_array(
      jsonb_build_object('label', 'Omzet', 'amount', coalesce((v_summary->>'gross_total')::numeric, 0)),
      jsonb_build_object('label', 'Payout', 'amount', coalesce((v_summary->>'payout_total')::numeric, 0)),
      jsonb_build_object('label', 'HPP', 'amount', -coalesce((v_summary->>'hpp_total')::numeric, 0)),
      jsonb_build_object('label', 'Biaya', 'amount', -coalesce((v_summary->>'expense_total')::numeric, 0)),
      jsonb_build_object('label', 'Laba rugi', 'amount', coalesce((v_summary->>'net_profit')::numeric, 0))
    ),
    'anomalies', v_anomalies,
    'anomaly_aggregates', v_anomaly_aggregates,
    'anomaly_status_counts', coalesce(v_anomaly_report->'status_counts', '{}'::jsonb),
    'anomaly_total', coalesce(nullif(v_anomaly_report->>'total', '')::integer, 0),
    'sources', jsonb_build_array(jsonb_build_object('source', 'finance_customer_dashboard_snapshot_v24_6_82o', 'mode', 'direct_baseline')),
    'by_sku_count', jsonb_array_length(v_by_sku)
  );
exception when query_canceled then
  return jsonb_build_object(
    'ok', false,
    'version', 'v24_6_82o_direct_baseline_timeout_guard',
    'message', 'Periode laporan terlalu besar untuk dimuat sekaligus. Pilih rentang yang lebih pendek lalu coba lagi.',
    'summary', jsonb_build_object('orders_count', 0, 'gross_total', 0, 'payout_total', 0, 'hpp_total', 0, 'expense_total', 0, 'net_profit', 0),
    'by_marketplace', '[]'::jsonb,
    'by_sku', '[]'::jsonb,
    'expenses', '[]'::jsonb,
    'approved_purchases', '[]'::jsonb,
    'anomalies', '[]'::jsonb
  );
end;
$function$;

create or replace function public.finance_sku_order_detail_lines_v24_6_82e(
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
as $function$
declare
  v_tenant_id uuid := public.app_current_tenant_id_or_default();
  v_start date := coalesce(p_start, current_date);
  v_end date := coalesce(p_end, coalesce(p_start, current_date));
  v_sku text := lower(trim(coalesce(p_sku, '')));
  v_limit integer := greatest(1, least(coalesce(p_limit, 1000), 1000));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  v_rows jsonb;
begin
  with valid_orders as (
    select
      o.*,
      coalesce(nullif(o.external_order_id, ''), nullif(o.order_sn, ''), nullif(o.order_id, ''), o.marketplace_order_id::text) as order_key,
      (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date as order_date_wib
    from public.marketplace_orders o
    where o.tenant_id = v_tenant_id
      and (p_marketplace is null or lower(coalesce(o.marketplace, '')) = lower(p_marketplace))
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
    group by 1, 2
  ),
  detail as (
    select
      vo.marketplace_account_id,
      vo.marketplace,
      vo.order_key,
      vo.external_order_id,
      vo.order_sn,
      vo.marketplace_order_id,
      coalesce(vo.tracking_number, vo.label_code) as tracking_number,
      coalesce(vo.order_status, vo.status) as order_status,
      vo.order_date_wib,
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
    where v_sku = ''
       or lower(coalesce(oi.mapped_local_sku, oi.local_sku, '')) = v_sku
       or lower(coalesce(oi.marketplace_sku_id, oi.remote_sku_id, '')) = v_sku
       or lower(coalesce(oi.marketplace_seller_sku, oi.seller_sku, '')) = v_sku
  ),
  enriched as (
    select
      d.*,
      coalesce(h.hpp, h.hpp_amount, 0) as hpp_per_item,
      fbo.payout_total as order_payout,
      fbo.statement_id,
      fbo.settlement_status,
      fbo.finance_at,
      sum(nullif(d.gross_line, 0)) over (partition by d.marketplace_account_id, d.order_key) as gross_order_scope,
      sum(d.qty) over (partition by d.marketplace_account_id, d.order_key) as qty_order_scope
    from detail d
    left join finance_by_order fbo
      on fbo.marketplace_account_id = d.marketplace_account_id
     and fbo.order_key = d.order_key
    left join lateral (
      select hm.*
      from public.marketplace_variant_hpp_mappings hm
      where coalesce(hm.is_active, true) = true
        and hm.tenant_id = v_tenant_id
        and hm.marketplace_account_id = d.marketplace_account_id
        and (
          hm.marketplace_sku_id = d.marketplace_sku_id
          or hm.marketplace_seller_sku = d.marketplace_seller_sku
          or hm.local_sku = d.local_sku
        )
      order by hm.updated_at desc nulls last, hm.created_at desc nulls last
      limit 1
    ) h on true
  ),
  final_rows as (
    select
      *,
      case
        when coalesce(order_payout, 0) = 0 then 0
        when coalesce(gross_order_scope, 0) > 0 and gross_line > 0 then order_payout * gross_line / gross_order_scope
        when coalesce(qty_order_scope, 0) > 0 then order_payout * qty / qty_order_scope
        else order_payout
      end as payout_allocated
    from enriched
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'order', order_key,
    'order_id', order_key,
    'order_sn', order_sn,
    'external_order_id', external_order_id,
    'tracking_number', tracking_number,
    'resi', tracking_number,
    'order_date', order_date_wib,
    'order_created_at', order_date_wib,
    'gross', gross_line,
    'gross_amount', gross_line,
    'payout', payout_allocated,
    'payout_amount', payout_allocated,
    'payout_total', payout_allocated,
    'status', order_status,
    'order_status', order_status,
    'payout_status', case when coalesce(order_payout, 0) <> 0 then coalesce(settlement_status, 'SETTLED') else 'PENDING_PAYOUT' end,
    'qty', qty,
    'local_sku', local_sku,
    'marketplace_sku', marketplace_sku_id,
    'marketplace_sku_id', marketplace_sku_id,
    'marketplace_seller_sku', marketplace_seller_sku,
    'variant_name', variant_name,
    'product_name', product_name,
    'statement_id', statement_id,
    'hpp', hpp_per_item * qty,
    'hpp_total', hpp_per_item * qty,
    'hpp_per_item', hpp_per_item,
    'net_profit', payout_allocated - (hpp_per_item * qty),
    'margin', payout_allocated - (hpp_per_item * qty),
    'margin_percent', case when payout_allocated <> 0 then ((payout_allocated - (hpp_per_item * qty)) / payout_allocated) * 100 else 0 end,
    'finance_at', finance_at,
    'source', 'finance_sku_order_detail_lines_v24_6_82e_direct'
  ) order by order_date_wib desc, order_key desc), '[]'::jsonb)
    into v_rows
  from (
    select *
    from final_rows
    order by order_date_wib desc, order_key desc
    limit v_limit offset v_offset
  ) page_rows;

  return jsonb_build_object(
    'ok', true,
    'version', 'v24_6_82e_direct_baseline_detail_lines',
    'rows', v_rows,
    'limit', v_limit,
    'offset', v_offset
  );
end;
$function$;

create or replace function public.finance_sku_summary_rows_v24_6_82e(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_snapshot jsonb;
begin
  v_snapshot := public.finance_customer_dashboard_snapshot_v24_6_82o(
    p_start,
    p_end,
    p_marketplace,
    p_account_id
  );
  return jsonb_build_object(
    'ok', true,
    'version', 'v24_6_82e_direct_baseline_summary_rows',
    'rows', coalesce(v_snapshot->'by_sku', '[]'::jsonb),
    'by_sku', coalesce(v_snapshot->'by_sku', '[]'::jsonb),
    'total', jsonb_array_length(coalesce(v_snapshot->'by_sku', '[]'::jsonb))
  );
end;
$function$;

create or replace function public.finance_unpaid_sku_rows_v24_6_82e(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_snapshot jsonb;
  v_rows jsonb;
begin
  v_snapshot := public.finance_customer_dashboard_snapshot_v24_6_82o(
    p_start,
    p_end,
    p_marketplace,
    p_account_id
  );

  select coalesce(jsonb_agg(value), '[]'::jsonb)
    into v_rows
  from jsonb_array_elements(coalesce(v_snapshot->'by_sku', '[]'::jsonb)) value
  where coalesce((value->>'unpaid_qty')::numeric, 0) > 0
     or coalesce((value->>'pending_payout_qty_total')::numeric, 0) > 0;

  return jsonb_build_object(
    'ok', true,
    'version', 'v24_6_82e_direct_baseline_unpaid_sku',
    'rows', v_rows,
    'total', jsonb_array_length(v_rows)
  );
end;
$function$;

create or replace function public.finance_anomaly_search_v24_6_82e(
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
as $function$
declare
  v_tenant_id uuid := public.app_current_tenant_id_or_default();
  v_start date := coalesce(p_start, current_date);
  v_end date := coalesce(p_end, coalesce(p_start, current_date));
  v_page integer := greatest(1, coalesce(p_page, 1));
  v_page_size integer := greatest(1, least(coalesce(p_page_size, 20), 100));
  v_search text := lower(trim(coalesce(p_search, '')));
  v_status text := upper(trim(coalesce(p_status, '')));
  v_rows jsonb := '[]'::jsonb;
  v_total integer := 0;
  v_aggregates jsonb := '{}'::jsonb;
  v_status_counts jsonb := '{}'::jsonb;
begin
  with order_scope as (
    select
      o.tenant_id,
      o.marketplace_account_id,
      o.marketplace,
      coalesce(nullif(o.external_order_id, ''), nullif(o.order_sn, ''), nullif(o.order_id, ''), o.marketplace_order_id::text) as order_key,
      o.external_order_id,
      o.order_sn,
      o.marketplace_order_id,
      coalesce(o.tracking_number, o.label_code) as tracking_number,
      coalesce(o.order_status, o.status) as order_status,
      (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date as order_date,
      coalesce(o.total_amount, o.gross_amount, o.paid_amount, 0) as expected_amount
    from public.marketplace_orders o
    where o.tenant_id = v_tenant_id
      and (p_marketplace is null or lower(coalesce(o.marketplace, '')) = lower(p_marketplace))
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date between v_start and v_end
  ),
  finance_scope as (
    select
      fr.marketplace_account_id,
      coalesce(nullif(fr.order_id, ''), fr.marketplace_order_id::text) as order_key,
      sum(coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)) as payout_amount,
      max(fr.statement_id::text) as statement_id,
      max(fr.settlement_status) as settlement_status,
      max(fr.pulled_at) as finance_at
    from public.marketplace_finance_reports fr
    where fr.tenant_id = v_tenant_id
      and (p_marketplace is null or lower(coalesce(fr.marketplace, '')) = lower(p_marketplace))
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
    group by 1, 2
  ),
  order_base as (
    select
      os.*,
      coalesce(fs.payout_amount, 0) as payout_amount,
      fs.statement_id,
      fs.settlement_status,
      fs.finance_at,
      ex.exclusion_id,
      ex.reason as exclusion_reason,
      case
        when ex.exclusion_id is not null then 'NO_PAYOUT_EXPECTED'
        when coalesce(fs.payout_amount, 0) < 0 then 'NEGATIVE_PAYOUT'
        when upper(coalesce(os.order_status, '')) like any (array['%CANCEL%', '%REFUND%', '%RETURN%']) and coalesce(fs.payout_amount, 0) = 0 then 'SAFE_CANCEL_UNPAID'
        when upper(coalesce(os.order_status, '')) in ('COMPLETED', 'DELIVERED') and coalesce(fs.payout_amount, 0) = 0 then 'MISSING_PAYOUT_FINAL'
        when coalesce(fs.payout_amount, 0) = 0 then 'PENDING_PAYOUT'
        else 'OK'
      end as anomaly_status
    from order_scope os
    left join finance_scope fs
      on fs.marketplace_account_id = os.marketplace_account_id
     and fs.order_key = os.order_key
    left join public.finance_no_payout_exclusions ex
      on ex.tenant_id = os.tenant_id
     and ex.marketplace_account_id = os.marketplace_account_id
      and coalesce(ex.is_active, true) = true
     and (ex.order_id = os.order_key or ex.external_order_id = os.order_key)
  ),
  finance_negative_raw as (
    select
      fr.tenant_id,
      fr.marketplace_account_id,
      coalesce(fr.marketplace, o.marketplace) as marketplace,
      coalesce(nullif(fr.order_id, ''), fr.marketplace_order_id::text, fr.statement_id::text) as order_key,
      o.external_order_id,
      o.order_sn,
      coalesce(fr.marketplace_order_id, o.marketplace_order_id) as marketplace_order_id,
      coalesce(o.tracking_number, o.label_code) as tracking_number,
      coalesce(o.order_status, o.status, fr.settlement_status, 'FINANCE') as order_status,
      coalesce((coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date, fr.settlement_date::date, (fr.pulled_at at time zone 'Asia/Jakarta')::date) as order_date,
      coalesce(o.total_amount, o.gross_amount, o.paid_amount, 0) as expected_amount,
      coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0) as payout_amount,
      fr.statement_id::text as statement_id,
      fr.settlement_status,
      fr.pulled_at as finance_at,
      null::uuid as exclusion_id,
      null::text as exclusion_reason,
      'NEGATIVE_PAYOUT'::text as anomaly_status
    from public.marketplace_finance_reports fr
    left join public.marketplace_orders o
      on o.tenant_id = fr.tenant_id
     and o.marketplace_account_id = fr.marketplace_account_id
     and (
       o.marketplace_order_id = fr.marketplace_order_id
       or coalesce(nullif(o.external_order_id, ''), nullif(o.order_sn, ''), nullif(o.order_id, ''), o.marketplace_order_id::text)
          = coalesce(nullif(fr.order_id, ''), fr.marketplace_order_id::text)
     )
    where fr.tenant_id = v_tenant_id
      and (p_marketplace is null or lower(coalesce(fr.marketplace, o.marketplace, '')) = lower(p_marketplace))
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0) < 0
      and coalesce(fr.settlement_date::date, (fr.pulled_at at time zone 'Asia/Jakarta')::date) between v_start and v_end
  ),
  base as (
    select *
    from order_base
    where anomaly_status <> 'OK'
    union all
    select fn.*
    from finance_negative_raw fn
    where not exists (
      select 1
      from order_base ob
      where ob.marketplace_account_id = fn.marketplace_account_id
        and ob.order_key = fn.order_key
        and ob.anomaly_status = 'NEGATIVE_PAYOUT'
    )
  ),
  filtered as (
    select *
    from base
    where (v_status = '' or v_status = 'ALL' or anomaly_status = v_status)
      and (
        v_search = ''
        or lower(order_key) like '%' || v_search || '%'
        or lower(coalesce(tracking_number, '')) like '%' || v_search || '%'
        or lower(coalesce(order_status, '')) like '%' || v_search || '%'
        or lower(coalesce(anomaly_status, '')) like '%' || v_search || '%'
      )
  ),
  stats as (
    select
      count(*)::integer as total,
      count(*) filter (where anomaly_status = 'NEGATIVE_PAYOUT')::integer as negative_payout_count,
      coalesce(sum(payout_amount) filter (where anomaly_status = 'NEGATIVE_PAYOUT'), 0) as negative_payout_total,
      count(*) filter (where anomaly_status = 'MISSING_PAYOUT_FINAL')::integer as missing_payout_count,
      coalesce(sum(expected_amount) filter (where anomaly_status = 'MISSING_PAYOUT_FINAL'), 0) as missing_payout_expected_total,
      count(*) filter (where anomaly_status = 'PENDING_PAYOUT')::integer as pending_payout_count,
      coalesce(sum(expected_amount) filter (where anomaly_status = 'PENDING_PAYOUT'), 0) as pending_payout_expected_total,
      count(*) filter (where anomaly_status in ('SAFE_CANCEL_UNPAID', 'NO_PAYOUT_EXPECTED'))::integer as cancel_refund_count,
      coalesce(sum(expected_amount) filter (where anomaly_status in ('SAFE_CANCEL_UNPAID', 'NO_PAYOUT_EXPECTED')), 0) as cancel_refund_total
    from filtered
  ),
  status_counts as (
    select anomaly_status, count(*)::integer as count_rows, coalesce(sum(payout_amount), 0) as payout_total
    from filtered
    group by anomaly_status
  ),
  page_rows as (
    select *
    from filtered
    order by order_date desc nulls last, order_key desc
    limit v_page_size offset ((v_page - 1) * v_page_size)
  )
  select
         coalesce((select total from stats), 0),
         coalesce((select jsonb_build_object(
           'total', total,
           'negative_payout_count', negative_payout_count,
           'negative_payout_total', negative_payout_total,
           'minus_payout_total', negative_payout_total,
           'payout_minus_total', negative_payout_total,
           'total_negative_payout', negative_payout_total,
           'missing_payout_count', missing_payout_count,
           'missing_payout_expected_total', missing_payout_expected_total,
           'pending_payout_count', pending_payout_count,
           'pending_payout_expected_total', pending_payout_expected_total,
           'cancel_refund_count', cancel_refund_count,
           'cancel_refund_total', cancel_refund_total
         ) from stats), '{}'::jsonb),
         coalesce((select jsonb_object_agg(anomaly_status, jsonb_build_object('count', count_rows, 'payout_total', payout_total)) from status_counts), '{}'::jsonb),
         coalesce((select jsonb_agg(jsonb_build_object(
           'title', order_key,
           'order_id', order_key,
           'order_sn', order_sn,
           'external_order_id', external_order_id,
           'marketplace_order_id', marketplace_order_id,
           'marketplace_account_id', marketplace_account_id,
           'marketplace', marketplace,
           'tracking_number', tracking_number,
           'resi', tracking_number,
           'order_date', order_date,
           'order_status', order_status,
           'status', order_status,
           'expected_amount', expected_amount,
           'gross', expected_amount,
           'gross_amount', expected_amount,
           'payout_amount', payout_amount,
           'payout_total', payout_amount,
           'statement_id', statement_id,
           'finance_at', finance_at,
           'anomaly_status', anomaly_status,
           'finance_status', anomaly_status,
           'payout_status', anomaly_status,
           'no_payout_excluded', exclusion_id is not null,
           'exclusion_reason', exclusion_reason,
           'message', case anomaly_status
             when 'NO_PAYOUT_EXPECTED' then 'Order ditandai tidak perlu payout.'
             when 'NEGATIVE_PAYOUT' then 'Payout minus/koreksi marketplace.'
             when 'SAFE_CANCEL_UNPAID' then 'Cancel/return tanpa payout, aman bila tidak stock out.'
             when 'MISSING_PAYOUT_FINAL' then 'Order final belum punya payout.'
             else 'Order menunggu payout.'
            end
          ) order by order_date desc nulls last, order_key desc) from page_rows), '[]'::jsonb)
    into v_total, v_aggregates, v_status_counts, v_rows;

  return jsonb_build_object(
    'ok', true,
    'version', 'v24_6_82e_direct_baseline_anomaly_search',
    'rows', v_rows,
    'aggregates', v_aggregates,
    'summary', v_aggregates,
    'status_counts', v_status_counts,
    'total', coalesce(v_total, 0),
    'page', v_page,
    'page_size', v_page_size
  );
end;
$function$;

create or replace function public.finance_fix_exact_cache_settled_hpp_v24_6_82q(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_start date := coalesce(p_start, current_date);
  v_end date := coalesce(p_end, coalesce(p_start, current_date));
  v_snapshot jsonb := '{}'::jsonb;
  v_anomaly jsonb := '{}'::jsonb;
begin
  v_snapshot := public.finance_customer_dashboard_snapshot_v24_6_82o(
    v_start,
    v_end,
    p_marketplace,
    p_account_id
  );

  v_anomaly := public.finance_anomaly_search_v24_6_82e(
    v_start,
    v_end,
    p_marketplace,
    p_account_id,
    null,
    null,
    1,
    20
  );

  return jsonb_build_object(
    'ok', true,
    'version', 'v24_6_82q_direct_baseline_light_refresh',
    'message', 'Cache laporan lokal sudah diperbarui. Data terbaru akan dimuat ulang.',
    'p_start', v_start,
    'p_end', v_end,
    'p_marketplace', p_marketplace,
    'p_account_id', p_account_id,
    'summary', coalesce(v_snapshot->'summary', '{}'::jsonb),
    'anomaly_aggregates', coalesce(v_anomaly->'aggregates', '{}'::jsonb),
    'refreshed_at', now()
  );
end;
$function$;

-- ---------------------------------------------------------------------------
-- Finance operational expense and runtime log RPCs
-- ---------------------------------------------------------------------------

create or replace function public.finance_list_manual_operational_expenses_v24_6_80m(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_tenant_id uuid := public.app_current_tenant_id_or_default();
  v_rows jsonb;
begin
  select coalesce(jsonb_agg(to_jsonb(x) order by x.expense_date desc, x.created_at desc), '[]'::jsonb)
    into v_rows
  from (
    select
      e.expense_id,
      coalesce(e.finance_operational_expense_id, e.expense_id) as operational_expense_id,
      e.category,
      e.description,
      e.amount,
      coalesce(e.expense_date, e.paid_at) as expense_date,
      e.paid_at,
      coalesce(e.status, 'paid') as status,
      e.note,
      e.created_at,
      e.updated_at,
      'manual_expense' as source
    from public.finance_operational_expenses e
    where e.tenant_id = v_tenant_id
      and (p_start is null or coalesce(e.expense_date, e.paid_at) >= p_start)
      and (p_end is null or coalesce(e.expense_date, e.paid_at) <= p_end)
  ) x;

  return jsonb_build_object('ok', true, 'rows', v_rows, 'total', jsonb_array_length(v_rows));
end;
$function$;

create or replace function public.finance_list_operational_expense_categories()
returns table(category text)
language sql
security definer
set search_path = public
as $function$
  select c.category
  from (
    select distinct category
    from public.finance_operational_expenses
    where tenant_id = public.app_current_tenant_id_or_default()
      and nullif(category, '') is not null
    union
    select unnest(array['Salary','Ads','Packaging','Transport','Operational'])
  ) c
  order by c.category;
$function$;

create or replace function public.list_purchase_requests()
returns table(
  request_id uuid,
  supplier_id uuid,
  supplier_name text,
  nomor_nota text,
  tanggal_beli date,
  nota_url text,
  total_amount numeric,
  status text,
  catatan text,
  finance_note text,
  created_by uuid,
  created_by_name text,
  created_by_email text,
  created_by_role text,
  verified_by uuid,
  verified_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_tenant_id uuid := public.app_current_tenant_id_or_default();
begin
  return query
  select
    pr.request_id,
    pr.supplier_id,
    pr.supplier_name,
    pr.nomor_nota,
    pr.tanggal_beli,
    pr.nota_url,
    coalesce(pr.total_amount, 0)::numeric,
    coalesce(pr.status, 'draft')::text,
    pr.catatan,
    pr.finance_note,
    pr.created_by,
    pr.created_by_name,
    pr.created_by_email,
    pr.created_by_role,
    pr.verified_by,
    pr.verified_at,
    pr.created_at,
    pr.updated_at
  from public.purchase_requests pr
  where v_tenant_id is null
     or pr.tenant_id is null
     or pr.tenant_id = v_tenant_id
  order by pr.tanggal_beli desc nulls last, pr.created_at desc nulls last
  limit 500;
end;
$function$;

create or replace function public.marketplace_list_active_accounts_for_filter(
  p_marketplace text default null
)
returns table(
  marketplace_account_id uuid,
  tenant_id uuid,
  marketplace text,
  store_label text,
  store_alias text,
  shop_name text,
  shop_region text,
  status text,
  shop_id_masked text,
  connected_at timestamptz,
  reauthorized_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_tenant_id uuid := public.app_current_tenant_id_or_default();
begin
  return query
  select
    ma.marketplace_account_id,
    ma.tenant_id,
    ma.marketplace,
    coalesce(nullif(ma.store_alias, ''), nullif(ma.shop_name, ''), ma.marketplace)::text,
    ma.store_alias,
    ma.shop_name,
    ma.shop_region,
    coalesce(ma.status, 'unknown')::text,
    case
      when ma.shop_id is null or length(ma.shop_id) <= 6 then ma.shop_id
      else left(ma.shop_id, 3) || repeat('*', greatest(length(ma.shop_id) - 6, 0)) || right(ma.shop_id, 3)
    end::text,
    ma.connected_at,
    ma.reauthorized_at,
    ma.updated_at
  from public.marketplace_accounts ma
  where (v_tenant_id is null or ma.tenant_id = v_tenant_id)
    and (p_marketplace is null or p_marketplace = '' or lower(ma.marketplace) = lower(p_marketplace))
    and coalesce(ma.is_deleted, false) = false
    and coalesce(ma.status, 'active') <> 'deleted'
  order by coalesce(nullif(ma.store_alias, ''), nullif(ma.shop_name, ''), ma.marketplace), ma.updated_at desc nulls last;
end;
$function$;

create or replace function public.marketplace_list_accounts_public(
  p_tenant_id uuid
)
returns table(
  marketplace_account_id uuid,
  tenant_id uuid,
  marketplace text,
  store_alias text,
  shop_name text,
  shop_region text,
  status text,
  environment text,
  stock_sync_enabled boolean,
  last_error text,
  shop_id_masked text,
  shop_cipher_masked text,
  access_token_expired_at timestamptz,
  refresh_token_expired_at timestamptz,
  connected_at timestamptz,
  reauthorized_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_tenant_id uuid := coalesce(p_tenant_id, public.app_current_tenant_id_or_default());
begin
  return query
  select
    ma.marketplace_account_id,
    ma.tenant_id,
    ma.marketplace,
    ma.store_alias,
    ma.shop_name,
    ma.shop_region,
    coalesce(ma.status, 'unknown')::text,
    coalesce(ma.environment, 'production')::text,
    coalesce(ma.stock_sync_enabled, false),
    ma.last_error,
    case
      when ma.shop_id is null or length(ma.shop_id) <= 6 then ma.shop_id
      else left(ma.shop_id, 3) || repeat('*', greatest(length(ma.shop_id) - 6, 0)) || right(ma.shop_id, 3)
    end::text,
    case
      when ma.shop_cipher is null or length(ma.shop_cipher) <= 6 then ma.shop_cipher
      else left(ma.shop_cipher, 3) || repeat('*', greatest(length(ma.shop_cipher) - 6, 0)) || right(ma.shop_cipher, 3)
    end::text,
    ma.access_token_expired_at,
    ma.refresh_token_expired_at,
    ma.connected_at,
    ma.reauthorized_at,
    ma.created_at,
    ma.updated_at
  from public.marketplace_accounts ma
  where ma.tenant_id = v_tenant_id
    and coalesce(ma.is_deleted, false) = false
    and coalesce(ma.status, 'active') <> 'deleted'
  order by ma.updated_at desc nulls last;
end;
$function$;

create or replace function public.finance_insert_manual_operational_expense_v24_6_79(
  p_category text,
  p_amount numeric,
  p_expense_date date default current_date,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into public.finance_operational_expenses (
    expense_id,
    finance_operational_expense_id,
    tenant_id,
    category,
    description,
    amount,
    paid_at,
    expense_date,
    payment_method,
    note,
    status,
    created_by,
    created_at,
    updated_at
  )
  values (
    v_id,
    v_id,
    public.app_current_tenant_id_or_default(),
    trim(coalesce(p_category, 'Operational')),
    trim(coalesce(p_note, p_category, 'Operational')),
    coalesce(p_amount, 0),
    coalesce(p_expense_date, current_date),
    coalesce(p_expense_date, current_date),
    'manual',
    p_note,
    'paid',
    auth.uid(),
    now(),
    now()
  );

  return jsonb_build_object('ok', true, 'expense_id', v_id);
end;
$function$;

create or replace function public.finance_update_manual_operational_expense_v24_6_79(
  p_expense_id uuid,
  p_category text,
  p_amount numeric,
  p_expense_date date default current_date,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_count integer;
begin
  update public.finance_operational_expenses
     set category = trim(coalesce(p_category, category)),
         description = trim(coalesce(p_note, p_category, description)),
         amount = coalesce(p_amount, amount),
         paid_at = coalesce(p_expense_date, paid_at),
         expense_date = coalesce(p_expense_date, expense_date, paid_at),
         note = p_note,
         updated_at = now()
   where tenant_id = public.app_current_tenant_id_or_default()
     and (expense_id = p_expense_id or finance_operational_expense_id = p_expense_id);

  get diagnostics v_count = row_count;
  return jsonb_build_object('ok', v_count > 0, 'updated', v_count);
end;
$function$;

create or replace function public.finance_delete_manual_operational_expense_v24_6_79(
  p_expense_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_count integer;
begin
  delete from public.finance_operational_expenses
   where tenant_id = public.app_current_tenant_id_or_default()
     and (expense_id = p_expense_id or finance_operational_expense_id = p_expense_id);

  get diagnostics v_count = row_count;
  return jsonb_build_object('ok', v_count > 0, 'deleted', v_count);
end;
$function$;

create or replace function public.finance_upsert_sku_target_margin(
  p_sku text,
  p_target_margin_percent numeric default 30
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_tenant_id uuid := public.app_current_tenant_id_or_default();
  v_sku text := nullif(trim(p_sku), '');
  v_count integer := 0;
begin
  if v_sku is null then
    return jsonb_build_object('ok', false, 'message', 'SKU is required');
  end if;

  update public.finance_sku_margin_settings
     set target_margin_percent = coalesce(p_target_margin_percent, 0),
         updated_by = auth.uid(),
         updated_at = now()
   where tenant_id = v_tenant_id
     and local_sku = v_sku;

  get diagnostics v_count = row_count;

  if v_count = 0 then
  insert into public.finance_sku_margin_settings (
    margin_setting_id,
    tenant_id,
    local_sku,
    target_margin_percent,
    updated_by,
    created_at,
    updated_at
  )
  values (
    gen_random_uuid(),
    v_tenant_id,
    v_sku,
    coalesce(p_target_margin_percent, 0),
    auth.uid(),
    now(),
    now()
  );
  end if;

  return jsonb_build_object('ok', true, 'sku', v_sku, 'target_margin_percent', p_target_margin_percent);
end;
$function$;

create or replace function public.finance_record_sync_log(
  p_sync_type text,
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
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into public.finance_sync_logs (
    sync_log_id,
    tenant_id,
    marketplace,
    marketplace_account_id,
    sync_type,
    period_start,
    period_end,
    status,
    total_checked,
    total_success,
    total_failed,
    total_skipped,
    checked_count,
    success_count,
    failed_count,
    skipped_count,
    message,
    created_by,
    created_at,
    updated_at
  )
  values (
    v_id,
    public.app_current_tenant_id_or_default(),
    coalesce(p_marketplace, 'all'),
    p_account_id,
    coalesce(p_sync_type, 'manual_period'),
    p_start,
    p_end,
    case when coalesce(p_failed, 0) > 0 then 'partial' else 'success' end,
    coalesce(p_checked, 0),
    coalesce(p_success, 0),
    coalesce(p_failed, 0),
    coalesce(p_skipped, 0),
    coalesce(p_checked, 0),
    coalesce(p_success, 0),
    coalesce(p_failed, 0),
    coalesce(p_skipped, 0),
    p_message,
    auth.uid(),
    now(),
    now()
  );

  return jsonb_build_object('ok', true, 'sync_log_id', v_id);
end;
$function$;

create or replace function public.finance_upsert_runtime_progress_v24_6_3(
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
language plpgsql
security definer
set search_path = public
as $function$
begin
  perform public.finance_record_sync_log(
    coalesce(p_sync_type, 'manual_period_progress'),
    p_start,
    p_end,
    p_marketplace,
    p_account_id,
    coalesce(p_checked, 0),
    coalesce(p_success, 0),
    coalesce(p_failed, 0),
    coalesce(p_skipped, 0),
    p_message
  );

  update public.finance_sync_logs
     set status = coalesce(p_status, status),
         updated_at = now()
   where sync_log_id = (
     select sync_log_id
     from public.finance_sync_logs
     where tenant_id = public.app_current_tenant_id_or_default()
     order by created_at desc
     limit 1
   );

  return jsonb_build_object('ok', true);
end;
$function$;

create or replace function public.finance_get_latest_runtime_progress_v24_6_3()
returns jsonb
language sql
security definer
set search_path = public
as $function$
  select coalesce((
    select jsonb_build_object(
      'status', status,
      'message', message,
      'updated_at', coalesce(updated_at, created_at),
      'checked', coalesce(checked_count, total_checked, 0),
      'success', coalesce(success_count, total_success, 0),
      'failed', coalesce(failed_count, total_failed, 0),
      'skipped', coalesce(skipped_count, total_skipped, 0)
    )
    from public.finance_sync_logs
    where tenant_id = public.app_current_tenant_id_or_default()
      and sync_type in ('manual_period_progress', 'manual_period')
    order by coalesce(updated_at, created_at) desc
    limit 1
  ), '{}'::jsonb);
$function$;

-- ---------------------------------------------------------------------------
-- No-payout anomaly controls
-- ---------------------------------------------------------------------------

create or replace function public.finance_mark_no_payout_order_v24_6_28(
  p_order_id text,
  p_account_id uuid,
  p_reason text default 'manual_no_payout_expected',
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into public.finance_no_payout_exclusions (
    exclusion_id,
    tenant_id,
    marketplace_account_id,
    order_id,
    external_order_id,
    reason,
    note,
    is_active,
    marked_by,
    marked_at,
    updated_at
  )
  values (
    v_id,
    public.app_current_tenant_id_or_default(),
    p_account_id,
    p_order_id,
    p_order_id,
    coalesce(p_reason, 'manual_no_payout_expected'),
    p_note,
    true,
    auth.uid(),
    now(),
    now()
  )
  on conflict do nothing;

  update public.finance_no_payout_exclusions
     set is_active = true,
         reason = coalesce(p_reason, reason),
         note = coalesce(p_note, note),
         updated_at = now()
   where tenant_id = public.app_current_tenant_id_or_default()
     and marketplace_account_id = p_account_id
     and (order_id = p_order_id or external_order_id = p_order_id);

  return jsonb_build_object('ok', true, 'order_id', p_order_id);
end;
$function$;

create or replace function public.finance_unmark_no_payout_order_v24_6_28(
  p_order_id text,
  p_account_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_count integer;
begin
  update public.finance_no_payout_exclusions
     set is_active = false,
         updated_at = now()
   where tenant_id = public.app_current_tenant_id_or_default()
     and marketplace_account_id = p_account_id
     and (order_id = p_order_id or external_order_id = p_order_id);

  get diagnostics v_count = row_count;
  return jsonb_build_object('ok', true, 'unmarked', v_count);
end;
$function$;

create or replace function public.finance_auto_mark_cancel_no_payout_v24_6_28(
  p_start date default null,
  p_end date default null,
  p_account_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_count integer := 0;
begin
  insert into public.finance_no_payout_exclusions (
    exclusion_id,
    tenant_id,
    marketplace_account_id,
    order_id,
    external_order_id,
    reason,
    note,
    is_active,
    marked_by,
    marked_at,
    updated_at
  )
  select
    gen_random_uuid(),
    o.tenant_id,
    o.marketplace_account_id,
    coalesce(nullif(o.external_order_id, ''), nullif(o.order_sn, ''), nullif(o.order_id, ''), o.marketplace_order_id::text),
    coalesce(nullif(o.external_order_id, ''), nullif(o.order_sn, ''), nullif(o.order_id, ''), o.marketplace_order_id::text),
    'auto_cancel_unpaid_no_payout_expected',
    'Auto mark dari tab Anomali',
    true,
    auth.uid(),
    now(),
    now()
  from public.marketplace_orders o
  where o.tenant_id = public.app_current_tenant_id_or_default()
    and (p_account_id is null or o.marketplace_account_id = p_account_id)
    and (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date
        between coalesce(p_start, current_date) and coalesce(p_end, coalesce(p_start, current_date))
    and upper(coalesce(o.order_status, o.status, '')) like any (array['%CANCEL%', '%UNPAID%', '%REFUND%', '%RETURN%'])
  on conflict do nothing;

  get diagnostics v_count = row_count;
  return jsonb_build_object('ok', true, 'marked', v_count);
end;
$function$;

-- ---------------------------------------------------------------------------
-- Marketplace order settings, queue housekeeping, job monitor, and reset
-- ---------------------------------------------------------------------------

create or replace function public.marketplace_get_order_pull_auto_setting(
  p_tenant_id uuid
)
returns table (
  auto_order_pull_enabled boolean,
  interval_minutes integer,
  days_back integer,
  previous_unpacked_days integer,
  updated_at timestamptz,
  last_auto_run_at timestamptz,
  last_auto_run_message text
)
language plpgsql
security definer
set search_path = public
as $function$
begin
  insert into public.marketplace_order_pull_settings (
    tenant_id,
    auto_order_pull_enabled,
    interval_minutes,
    days_back,
    previous_unpacked_days,
    created_at,
    updated_at
  )
  select p_tenant_id, false, 10, 1, 3, now(), now()
  where p_tenant_id is not null
    and not exists (
      select 1 from public.marketplace_order_pull_settings s where s.tenant_id = p_tenant_id
    );

  return query
  select
    coalesce(s.auto_order_pull_enabled, false),
    coalesce(s.interval_minutes, 10),
    least(greatest(coalesce(s.days_back, 1), 1), 3),
    least(greatest(coalesce(s.previous_unpacked_days, 3), 1), 3),
    s.updated_at,
    s.last_auto_run_at,
    s.last_auto_run_message
  from public.marketplace_order_pull_settings s
  where s.tenant_id = p_tenant_id
  limit 1;
end;
$function$;

create or replace function public.marketplace_set_order_pull_auto_enabled(
  p_tenant_id uuid,
  p_enabled boolean
)
returns table (
  auto_order_pull_enabled boolean,
  interval_minutes integer,
  days_back integer,
  previous_unpacked_days integer,
  updated_at timestamptz,
  last_auto_run_at timestamptz,
  last_auto_run_message text
)
language plpgsql
security definer
set search_path = public
as $function$
begin
  insert into public.marketplace_order_pull_settings (
    tenant_id,
    auto_order_pull_enabled,
    interval_minutes,
    days_back,
    previous_unpacked_days,
    updated_by,
    created_at,
    updated_at
  )
  values (
    p_tenant_id,
    coalesce(p_enabled, false),
    10,
    1,
    3,
    auth.uid(),
    now(),
    now()
  )
  on conflict (tenant_id) do update
     set auto_order_pull_enabled = excluded.auto_order_pull_enabled,
         interval_minutes = 10,
         days_back = least(greatest(coalesce(public.marketplace_order_pull_settings.days_back, 1), 1), 3),
         previous_unpacked_days = least(greatest(coalesce(public.marketplace_order_pull_settings.previous_unpacked_days, 3), 1), 3),
         updated_by = excluded.updated_by,
         updated_at = now();

  return query select * from public.marketplace_get_order_pull_auto_setting(p_tenant_id);
end;
$function$;

create or replace function public.marketplace_order_pull_free_plan_housekeeping_v24_6_88(
  p_keep_pending integer default 24,
  p_cancel_old_hours integer default 8
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_cancel_old integer := 0;
  v_cancel_extra integer := 0;
  v_keep integer := greatest(1, least(coalesce(p_keep_pending, 24), 48));
begin
  update public.marketplace_order_pull_jobs
     set status = 'cancelled',
         locked_at = null,
         finished_at = now(),
         last_message = 'Antrean lama dibersihkan agar pembaruan terbaru bisa berjalan.',
         updated_at = now()
   where status in ('pending', 'retry')
     and coalesce(job_type, '') like 'auto_%'
     and coalesce(created_at, updated_at, now()) < now() - make_interval(hours => greatest(coalesce(p_cancel_old_hours, 8), 1));
  get diagnostics v_cancel_old = row_count;

  with ranked as (
    select
      order_pull_job_id,
      row_number() over (
        partition by tenant_id, marketplace_account_id
        order by priority desc, window_start_seconds desc, created_at desc
      ) as rn
    from public.marketplace_order_pull_jobs
    where status in ('pending', 'retry')
      and coalesce(job_type, '') like 'auto_%'
  )
  update public.marketplace_order_pull_jobs j
     set status = 'cancelled',
         locked_at = null,
         finished_at = now(),
         last_message = 'Antrean dirapikan agar proses tetap ringan.',
         updated_at = now()
  from ranked r
  where r.order_pull_job_id = j.order_pull_job_id
    and r.rn > v_keep;
  get diagnostics v_cancel_extra = row_count;

  return jsonb_build_object(
    'ok', true,
    'cancelled_old', v_cancel_old,
    'cancelled_extra', v_cancel_extra,
    'keep_pending_per_account', v_keep
  );
end;
$function$;

create or replace function public.marketplace_run_auto_order_pull_10m()
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_cleanup jsonb;
  v_inserted integer := 0;
  v_now_sec bigint := floor(extract(epoch from now()))::bigint;
  v_start_sec bigint := floor(extract(epoch from (now() - interval '2 hours')))::bigint;
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
begin
  v_cleanup := public.marketplace_order_pull_free_plan_housekeeping_v24_6_88(24, 8);

  insert into public.marketplace_order_pull_jobs (
    order_pull_job_id,
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
    payload,
    last_result,
    created_at,
    updated_at
  )
  select
    gen_random_uuid(),
    ma.tenant_id,
    ma.marketplace_account_id,
    ma.marketplace,
    'auto_recent_safe_window',
    v_today,
    v_today,
    v_start_sec,
    v_now_sec,
    to_char(now() at time zone 'Asia/Jakarta', 'YYYY-MM-DD HH24:MI') || ' recent 2h',
    'pending',
    95,
    0,
    now(),
    jsonb_build_object('source', 'marketplace_run_auto_order_pull_10m_direct_baseline', 'window_policy', 'recent_2h_one_job_if_no_active'),
    '{}'::jsonb,
    now(),
    now()
  from public.marketplace_order_pull_settings s
  join public.marketplace_accounts ma
    on ma.tenant_id = s.tenant_id
   and ma.marketplace = 'tiktok_shop'
   and lower(coalesce(ma.status, '')) = 'active'
   and coalesce(ma.is_deleted, false) = false
  where coalesce(s.auto_order_pull_enabled, false) = true
    and not exists (
      select 1
      from public.marketplace_order_pull_jobs j
      where j.tenant_id = ma.tenant_id
        and j.marketplace_account_id = ma.marketplace_account_id
        and j.status in ('pending', 'retry', 'running')
        and coalesce(j.job_type, '') like 'auto_%'
    );
  get diagnostics v_inserted = row_count;

  update public.marketplace_order_pull_settings s
     set last_auto_run_at = now(),
         last_auto_run_message = 'Auto order SQL baseline: queued=' || v_inserted || ', cleanup=' || v_cleanup::text,
         updated_at = now()
   where coalesce(s.auto_order_pull_enabled, false) = true;

  return jsonb_build_object(
    'ok', true,
    'queued', v_inserted,
    'cleanup', v_cleanup,
    'window_policy', 'recent_2h_one_job_per_account_only_if_no_active_pending'
  );
end;
$function$;

create or replace function public.marketplace_order_queue_cleanup_v24_6_87(
  p_keep_pending_per_account integer default 1,
  p_pending_max_age_minutes integer default 30,
  p_stale_running_minutes integer default 20,
  p_future_days integer default 1
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_now timestamptz := now();
  v_now_epoch bigint := floor(extract(epoch from now()))::bigint;
  v_future_limit bigint := floor(extract(epoch from (now() + make_interval(days => greatest(coalesce(p_future_days, 1), 1)))))::bigint;
  v_keep integer := greatest(coalesce(p_keep_pending_per_account, 1), 1);
  v_pending_age integer := greatest(coalesce(p_pending_max_age_minutes, 30), 10);
  v_stale integer := greatest(coalesce(p_stale_running_minutes, 20), 5);
  v_cancel_invalid integer := 0;
  v_cancel_old integer := 0;
  v_cancel_overflow integer := 0;
  v_cancel_stale integer := 0;
begin
  update public.marketplace_order_pull_jobs j
     set status = 'cancelled',
         locked_at = null,
         finished_at = v_now,
         updated_at = v_now,
         last_message = 'Jadwal pembaruan tidak valid dibatalkan otomatis.'
   where coalesce(j.status, '') in ('pending', 'running', 'retry')
     and (
       coalesce(j.window_start_seconds, 0) <= 0
       or coalesce(j.window_end_seconds, 0) <= 0
       or coalesce(j.window_end_seconds, 0) <= coalesce(j.window_start_seconds, 0)
       or coalesce(j.window_start_seconds, 0) > v_future_limit
       or coalesce(j.window_end_seconds, 0) > v_future_limit
     );
  get diagnostics v_cancel_invalid = row_count;

  update public.marketplace_order_pull_jobs j
     set status = 'cancelled',
         locked_at = null,
         finished_at = v_now,
         updated_at = v_now,
         last_message = 'Antrean otomatis lama dibersihkan agar pembaruan terbaru bisa berjalan.'
   where coalesce(j.status, '') in ('pending', 'retry')
     and coalesce(j.job_type, '') like 'auto_%'
     and coalesce(j.updated_at, j.created_at, v_now) < v_now - make_interval(mins => v_pending_age);
  get diagnostics v_cancel_old = row_count;

  update public.marketplace_order_pull_jobs j
     set status = 'retry',
         next_run_at = v_now,
         locked_at = null,
         finished_at = null,
         updated_at = v_now,
         last_message = 'Pembaruan lama dijadwalkan ulang.'
   where coalesce(j.status, '') = 'running'
     and coalesce(j.locked_at, j.last_run_at, j.updated_at, j.created_at, v_now) < v_now - make_interval(mins => v_stale);
  get diagnostics v_cancel_stale = row_count;

  with ranked as (
    select
      j.order_pull_job_id,
      row_number() over (
        partition by coalesce(j.marketplace_account_id::text, 'no-account'), coalesce(j.marketplace, '')
        order by coalesce(j.priority, 0) desc, coalesce(j.updated_at, j.created_at, v_now) desc, j.order_pull_job_id desc
      ) as rn
    from public.marketplace_order_pull_jobs j
    where coalesce(j.status, '') in ('pending', 'retry')
      and coalesce(j.job_type, '') like 'auto_%'
      and coalesce(j.window_start_seconds, 0) > 0
      and coalesce(j.window_end_seconds, 0) > coalesce(j.window_start_seconds, 0)
      and coalesce(j.window_end_seconds, 0) <= v_now_epoch + 300
  )
  update public.marketplace_order_pull_jobs j
     set status = 'cancelled',
         locked_at = null,
         finished_at = v_now,
         updated_at = v_now,
         last_message = 'Antrean berlebih dirapikan agar proses tetap ringan.'
  from ranked r
  where j.order_pull_job_id = r.order_pull_job_id
    and r.rn > v_keep;
  get diagnostics v_cancel_overflow = row_count;

  return jsonb_build_object(
    'ok', true,
    'version', 'v24_6_87_direct_baseline_queue_cleanup',
    'cancel_invalid_or_future', v_cancel_invalid,
    'cancel_old_auto_pending', v_cancel_old,
    'reset_stale_running', v_cancel_stale,
    'cancel_pending_overflow', v_cancel_overflow,
    'keep_pending_per_account', v_keep,
    'pending_max_age_minutes', v_pending_age
  );
end;
$function$;

create or replace function public.marketplace_auto_runner_try_lock_v24_6_81b(
  p_lock_key text,
  p_ttl_seconds integer default 300,
  p_owner text default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_owner text := coalesce(nullif(p_owner, ''), gen_random_uuid()::text);
  v_count integer := 0;
begin
  insert into public.marketplace_auto_runner_locks(lock_key, owner, locked_until, updated_at)
  values (
    p_lock_key,
    v_owner,
    now() + make_interval(secs => greatest(coalesce(p_ttl_seconds, 300), 30)),
    now()
  )
  on conflict (lock_key) do update
     set owner = excluded.owner,
         locked_until = excluded.locked_until,
         updated_at = now()
   where public.marketplace_auto_runner_locks.locked_until < now()
      or public.marketplace_auto_runner_locks.owner = excluded.owner;

  get diagnostics v_count = row_count;
  return v_count > 0;
end;
$function$;

create or replace function public.marketplace_auto_runner_release_lock_v24_6_81b(
  p_lock_key text,
  p_owner text default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_count integer;
begin
  delete from public.marketplace_auto_runner_locks
   where lock_key = p_lock_key
     and owner = p_owner;
  get diagnostics v_count = row_count;
  return v_count > 0;
end;
$function$;

create or replace function public.marketplace_reset_stale_auto_jobs_v24_6_81b(
  p_order_stale_minutes integer default 10,
  p_finance_stale_minutes integer default 15,
  p_revive_failed boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_order_reset integer := 0;
  v_order_pending_cancelled integer := 0;
  v_finance_reset integer := 0;
  v_order_failed_revived integer := 0;
  v_finance_failed_revived integer := 0;
begin
  update public.marketplace_order_pull_jobs
     set status = 'retry',
         next_run_at = now(),
         locked_at = null,
         finished_at = null,
        last_message = 'Pembaruan order lama dijadwalkan ulang.',
         updated_at = now()
   where status = 'running'
     and coalesce(locked_at, last_run_at, updated_at, created_at) < now() - make_interval(mins => greatest(coalesce(p_order_stale_minutes, 10), 3));
  get diagnostics v_order_reset = row_count;

  update public.marketplace_order_pull_jobs
     set status = 'cancelled',
         next_run_at = null,
         locked_at = null,
         finished_at = now(),
         last_message = 'Antrean order lama dibersihkan sebelum pembaruan otomatis berjalan.',
         updated_at = now()
   where status in ('pending', 'retry')
     and coalesce(job_type, '') like 'auto_%'
     and coalesce(updated_at, created_at) < now() - make_interval(mins => greatest(coalesce(p_order_stale_minutes, 10), 10));
  get diagnostics v_order_pending_cancelled = row_count;

  update public.finance_sync_jobs
     set status = 'retry',
         next_run_at = now(),
         locked_at = null,
         finished_at = null,
        last_message = 'Pembaruan payout lama dijadwalkan ulang.',
         updated_at = now()
   where status = 'running'
     and coalesce(locked_at, last_run_at, updated_at, created_at) < now() - make_interval(mins => greatest(coalesce(p_finance_stale_minutes, 15), 5));
  get diagnostics v_finance_reset = row_count;

  if coalesce(p_revive_failed, false) then
    update public.marketplace_order_pull_jobs
       set status = 'retry', next_run_at = now(), locked_at = null, finished_at = null, updated_at = now()
     where status = 'failed'
       and coalesce(finished_at, updated_at, created_at) >= now() - interval '1 day';
    get diagnostics v_order_failed_revived = row_count;

    update public.finance_sync_jobs
       set status = 'retry', next_run_at = now(), locked_at = null, finished_at = null, updated_at = now()
     where status = 'failed'
       and coalesce(finished_at, updated_at, created_at) >= now() - interval '1 day';
    get diagnostics v_finance_failed_revived = row_count;
  end if;

  return jsonb_build_object(
    'ok', true,
    'order_running_reset', v_order_reset,
    'order_pending_cancelled', v_order_pending_cancelled,
    'finance_running_reset', v_finance_reset,
    'order_failed_revived', v_order_failed_revived,
    'finance_failed_revived', v_finance_failed_revived,
    'finance_table', 'public.finance_sync_jobs'
  );
end;
$function$;

create or replace function public.marketplace_auto_direct_order_pull_v24_6_82q()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_ctx record;
  v_setting record;
  v_enqueue jsonb;
  v_cleanup jsonb;
  v_results jsonb := '[]'::jsonb;
  v_body jsonb;
  v_req bigint;
begin
  v_cleanup := public.marketplace_order_queue_cleanup_v24_6_87(1, 30, 20, 1);
  v_enqueue := public.marketplace_enqueue_recent_order_pull_jobs_v24_6_87(120, 120, 10);

  begin
    select * into v_ctx from public._marketplace_cron_edge_context_v24_6_82q() limit 1;
  exception when others then
    return jsonb_build_object(
      'ok', false,
      'version', 'v24_6_82q_direct_baseline_order_cron_worker',
      'cleanup', v_cleanup,
      'enqueue', v_enqueue,
      'needs_config', true,
      'message', sqlerrm
    );
  end;

  for v_setting in
    select tenant_id
    from public.marketplace_order_pull_settings
    where coalesce(auto_order_pull_enabled, false) = true
    order by updated_at desc nulls last
    limit 10
  loop
    v_body := jsonb_build_object(
      'tenant_id', v_setting.tenant_id,
      'mode', 'process_pending',
      'enqueue', false,
      'process', true,
      'max_jobs', 1,
      'page_size', 50,
      'max_pages', 1,
      'max_details', 50,
      'include_update_time_search', true,
      'refresh_existing_status', true,
      'status_range_days', 14,
      'max_existing_orders', 80,
      'skip_completed_status_refresh', true,
      'skip_completed_order_pull', true,
      'background', true,
      'source', 'pg_cron_direct_order_v24_6_82q_direct_baseline_worker'
    );

    select net.http_post(
      url := v_ctx.base_url || '/marketplace-order-sync-jobs',
      headers := v_ctx.headers,
      body := v_body,
      timeout_milliseconds := 115000
    ) into v_req;

    if to_regclass('public.marketplace_auto_pull_request_log_v24_6_82q') is not null then
      insert into public.marketplace_auto_pull_request_log_v24_6_82q(kind, marketplace_account_id, request_id, request_body)
      values ('order', null, v_req, v_body);
    end if;

    v_results := v_results || jsonb_build_array(jsonb_build_object(
      'tenant_id', v_setting.tenant_id,
      'request_id', v_req,
      'mode', 'process_pending',
      'max_jobs', 1
    ));
  end loop;

  return jsonb_build_object(
    'ok', true,
    'version', 'v24_6_82q_direct_baseline_order_cron_worker',
    'cleanup', v_cleanup,
    'enqueue', v_enqueue,
    'worker_requests', v_results
  );
end;
$function$;

create or replace function public.marketplace_job_monitor_snapshot_v24_6_9()
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_stale_before timestamptz := now() - interval '20 minutes';
begin
  return jsonb_build_object(
    'generated_at_wib', to_char(now() at time zone 'Asia/Jakarta', 'DD/MM/YYYY HH24:MI:SS'),
    'stale_threshold_minutes', 20,
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

create or replace function public.marketplace_job_reset_stuck_v24_6_9(
  p_kind text default 'all',
  p_retry_failed boolean default false,
  p_stale_minutes integer default 20
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_kind text := lower(coalesce(p_kind, 'order'));
  v_reset integer := 0;
begin
  if v_kind = 'finance' then
    update public.finance_sync_jobs
       set status = 'retry',
           next_run_at = now(),
           locked_at = null,
           finished_at = null,
            last_message = case when p_retry_failed then 'Pembaruan dijadwalkan ulang.' else 'Antrean yang terlalu lama disiapkan ulang.' end,
           updated_at = now()
     where (status = 'running' and coalesce(locked_at, last_run_at, updated_at, created_at) < now() - make_interval(mins => greatest(coalesce(p_stale_minutes, 20), 5)))
        or (coalesce(p_retry_failed, false) and status in ('failed', 'retry'));
  else
    update public.marketplace_order_pull_jobs
       set status = 'retry',
           next_run_at = now(),
           locked_at = null,
           finished_at = null,
            last_message = case when p_retry_failed then 'Pembaruan dijadwalkan ulang.' else 'Antrean yang terlalu lama disiapkan ulang.' end,
           updated_at = now()
     where (status = 'running' and coalesce(locked_at, last_run_at, updated_at, created_at) < now() - make_interval(mins => greatest(coalesce(p_stale_minutes, 20), 5)))
        or (coalesce(p_retry_failed, false) and status in ('failed', 'retry'));
  end if;

  get diagnostics v_reset = row_count;
  return jsonb_build_object('ok', true, 'reset', v_reset, 'kind', v_kind, 'message', v_reset || ' antrean disiapkan ulang.');
end;
$function$;

create or replace function public.marketplace_reset_order_finance_data(
  p_account_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_orders integer := 0;
  v_items integer := 0;
  v_finance_reports integer := 0;
  v_finance_items integer := 0;
  v_anomalies integer := 0;
  v_order_jobs integer := 0;
begin
  return jsonb_build_object(
    'ok', true,
    'orders_deleted', v_orders,
    'order_items_deleted', v_items,
    'finance_reports_deleted', v_finance_reports,
    'finance_items_deleted', v_finance_items,
    'finance_anomalies_deleted', v_anomalies,
    'order_jobs_deleted', v_order_jobs,
    'mapping_deleted', 0,
    'message', 'Safe baseline mode: reset request ignored so existing order and finance data remain intact.'
  );
end;
$function$;

create or replace function public.marketplace_find_order_by_resi(
  p_tenant_id uuid,
  p_resi_code text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_code text := lower(trim(coalesce(p_resi_code, '')));
  v_order record;
  v_total_items integer := 0;
  v_scanned_items integer := 0;
begin
  if p_tenant_id is null or v_code = '' then
    return jsonb_build_object('ok', false, 'message', 'Scan atau input nomor resi/order terlebih dahulu.');
  end if;

  select o.*
    into v_order
  from public.marketplace_orders o
  where o.tenant_id = p_tenant_id
    and (
      lower(coalesce(o.tracking_number, '')) = v_code
      or lower(coalesce(o.label_code, '')) = v_code
      or lower(coalesce(o.package_id, '')) = v_code
      or lower(coalesce(o.external_order_id, '')) = v_code
      or lower(coalesce(o.order_sn, '')) = v_code
      or lower(coalesce(o.order_id, '')) = v_code
      or lower(o.marketplace_order_id::text) = v_code
      or exists (
        select 1
        from public.marketplace_order_items oi
        where oi.tenant_id = o.tenant_id
          and oi.marketplace_order_id = o.marketplace_order_id
          and (
            lower(coalesce(oi.tracking_number, '')) = v_code
            or lower(coalesce(oi.package_id, '')) = v_code
            or lower(coalesce(oi.external_order_item_id, '')) = v_code
          )
      )
    )
  order by coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) desc nulls last,
           o.created_at desc nulls last
  limit 1;

  if not found then
    return jsonb_build_object('ok', false, 'message', 'Pesanan tidak ditemukan untuk resi/order tersebut.');
  end if;

  select count(*)::integer,
         count(*) filter (
           where coalesce(oi.scanned_qty, 0) >= greatest(coalesce(nullif(oi.quantity, 0), nullif(oi.qty, 0), 1), 1)
         )::integer
    into v_total_items, v_scanned_items
  from public.marketplace_order_items oi
  where oi.tenant_id = p_tenant_id
    and oi.marketplace_order_id = v_order.marketplace_order_id;

  return jsonb_build_object(
    'ok', true,
    'message', 'Pesanan ditemukan. Silakan lanjut scan item.',
    'marketplace_order_id', v_order.marketplace_order_id,
    'external_order_id', coalesce(nullif(v_order.external_order_id, ''), nullif(v_order.order_sn, ''), nullif(v_order.order_id, ''), v_order.marketplace_order_id::text),
    'order_sn', v_order.order_sn,
    'tracking_number', coalesce(nullif(v_order.tracking_number, ''), nullif(v_order.label_code, ''), p_resi_code),
    'order_status', coalesce(v_order.order_status, v_order.status),
    'order_date', (coalesce(v_order.order_created_at, v_order.paid_at, v_order.created_time, v_order.created_at) at time zone 'Asia/Jakarta')::date,
    'total_items', coalesce(v_total_items, 0),
    'processed', coalesce(v_scanned_items, 0),
    'order_ready_to_finalize', coalesce(v_total_items, 0) > 0 and coalesce(v_scanned_items, 0) >= coalesce(v_total_items, 0)
  );
end;
$function$;

create or replace function public.marketplace_activate_order_for_scan_by_resi(
  p_tenant_id uuid,
  p_resi_code text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_found jsonb;
  v_order_id uuid;
begin
  v_found := public.marketplace_find_order_by_resi(p_tenant_id, p_resi_code);
  if coalesce((v_found->>'ok')::boolean, false) = false then
    return v_found;
  end if;

  v_order_id := nullif(v_found->>'marketplace_order_id', '')::uuid;

  update public.marketplace_order_items oi
     set stock_action_status = case
           when coalesce(oi.stock_action_status, '') in ('', 'pending', 'ready_stock_out', 'ignored_status') then 'waiting_scan'
           else oi.stock_action_status
         end,
         updated_at = now()
   where oi.tenant_id = p_tenant_id
     and oi.marketplace_order_id = v_order_id
     and coalesce(oi.stock_action_status, '') not in ('stock_out_done', 'return_review_done', 'cancelled_released');

  return v_found || jsonb_build_object(
    'ok', true,
    'message', 'Pesanan siap discan. Data dicari dari semua tanggal order.'
  );
end;
$function$;

create or replace function public.marketplace_scan_order_item_by_resi(
  p_tenant_id uuid,
  p_resi_code text,
  p_scan_code text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_found jsonb;
  v_order_id uuid;
  v_scan jsonb;
begin
  v_found := public.marketplace_find_order_by_resi(p_tenant_id, p_resi_code);
  if coalesce((v_found->>'ok')::boolean, false) = false then
    return v_found;
  end if;

  v_order_id := nullif(v_found->>'marketplace_order_id', '')::uuid;
  v_scan := public.marketplace_scan_order_item_barcode(p_tenant_id, v_order_id, p_scan_code);

  return coalesce(v_scan, '{}'::jsonb) || jsonb_build_object(
    'marketplace_order_id', v_order_id,
    'external_order_id', v_found->>'external_order_id',
    'tracking_number', v_found->>'tracking_number'
  );
end;
$function$;

create or replace function public.marketplace_scan_order_item_manual_by_resi(
  p_tenant_id uuid,
  p_resi_code text,
  p_marketplace_order_item_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_found jsonb;
  v_order_id uuid;
begin
  v_found := public.marketplace_find_order_by_resi(p_tenant_id, p_resi_code);
  if coalesce((v_found->>'ok')::boolean, false) = false then
    return v_found;
  end if;

  v_order_id := nullif(v_found->>'marketplace_order_id', '')::uuid;

  update public.marketplace_order_items oi
     set scanned_qty = least(greatest(coalesce(nullif(oi.quantity, 0), nullif(oi.qty, 0), 1), 1), coalesce(oi.scanned_qty, 0) + 1),
         stock_action_status = case
           when least(greatest(coalesce(nullif(oi.quantity, 0), nullif(oi.qty, 0), 1), 1), coalesce(oi.scanned_qty, 0) + 1)
                >= greatest(coalesce(nullif(oi.quantity, 0), nullif(oi.qty, 0), 1), 1)
           then 'scanned_done'
           else 'partial_scanned'
         end,
         updated_at = now()
   where oi.tenant_id = p_tenant_id
     and oi.marketplace_order_id = v_order_id
     and oi.marketplace_order_item_id = p_marketplace_order_item_id
     and coalesce(oi.stock_action_status, '') <> 'stock_out_done';

  if not found then
    return v_found || jsonb_build_object('ok', false, 'message', 'Item tidak ditemukan pada pesanan ini.');
  end if;

  return public.marketplace_find_order_by_resi(p_tenant_id, p_resi_code)
    || jsonb_build_object('ok', true, 'message', 'Item berhasil ditandai sudah discan.');
end;
$function$;

create or replace function public.marketplace_finalize_scanned_order_stock_out_by_resi_guarded(
  p_tenant_id uuid,
  p_resi_code text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_found jsonb;
  v_order_id uuid;
  v_result jsonb;
begin
  v_found := public.marketplace_find_order_by_resi(p_tenant_id, p_resi_code);
  if coalesce((v_found->>'ok')::boolean, false) = false then
    return v_found;
  end if;

  v_order_id := nullif(v_found->>'marketplace_order_id', '')::uuid;
  v_result := public.marketplace_finalize_scanned_order_stock_out(p_tenant_id, v_order_id);

  return coalesce(v_result, '{}'::jsonb) || jsonb_build_object(
    'marketplace_order_id', v_order_id,
    'external_order_id', v_found->>'external_order_id',
    'tracking_number', v_found->>'tracking_number'
  );
end;
$function$;

create or replace function public.marketplace_refund_cancel_review_v24_6_42(
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
language plpgsql
stable
security definer
set search_path = public
as $function$
declare
  v_tenant uuid := public.app_current_tenant_id_or_default();
  v_start date := coalesce(p_start, ((now() at time zone 'Asia/Jakarta')::date - 30));
  v_end date := coalesce(p_end, (now() at time zone 'Asia/Jakarta')::date);
  v_marketplace text := lower(nullif(trim(coalesce(p_marketplace, '')), ''));
  v_search text := lower(nullif(trim(coalesce(p_search, '')), ''));
  v_action text := upper(nullif(trim(coalesce(p_action, '')), ''));
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_page_size integer := least(greatest(coalesce(p_page_size, 20), 1), 100);
  v_total integer := 0;
  v_rows jsonb := '[]'::jsonb;
begin
  with orders_raw as (
    select
      o.*,
      coalesce(nullif(o.order_id, ''), nullif(o.external_order_id, ''), nullif(o.order_sn, ''), nullif(o.remote_order_id, '')) as order_key,
      coalesce(o.order_created_at, o.created_time, o.paid_at, o.pulled_at, o.created_at) as order_at
    from public.marketplace_orders o
    where o.tenant_id = v_tenant
      and ((coalesce(o.order_created_at, o.created_time, o.paid_at, o.pulled_at, o.created_at) at time zone 'Asia/Jakarta')::date between v_start and v_end)
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and (v_marketplace is null or v_marketplace in ('all', '') or lower(coalesce(o.marketplace, '')) = v_marketplace)
  ),
  orders_base as (
    select *
    from (
      select
        r.*,
        row_number() over (
          partition by r.tenant_id, r.marketplace_account_id, r.marketplace, r.order_key
          order by coalesce(r.order_updated_at, r.updated_time, r.updated_at, r.pulled_at, r.created_at) desc nulls last,
                   r.marketplace_order_id desc
        ) rn
      from orders_raw r
      where coalesce(r.order_key, '') <> ''
    ) x
    where x.rn = 1
  ),
  item_enriched as (
    select
      i.*,
      coalesce(nullif(i.quantity, 0), nullif(i.qty, 0), 1) as qty_final,
      coalesce(nullif(i.product_name, ''), nullif(i.marketplace_product_name, ''), nullif(i.local_product_name, ''), '-') as item_product_name,
      coalesce(nullif(i.variant_name, ''), nullif(i.marketplace_variant_name, ''), nullif(i.variation_name, ''), '-') as item_variant_name,
      coalesce(nullif(i.mapped_local_sku, ''), nullif(i.local_sku, ''), nullif(h.local_sku, ''), nullif(i.seller_sku, ''), '-') as item_local_sku,
      coalesce(nullif(i.marketplace_sku_id, ''), nullif(i.remote_sku_id, ''), nullif(i.marketplace_seller_sku, ''), nullif(i.seller_sku, ''), '-') as item_marketplace_sku,
      coalesce(h.hpp, h.hpp_amount, 0) as hpp_per_item,
      greatest(
        coalesce(i.gross_amount, 0),
        coalesce(i.paid_amount, 0),
        coalesce(i.unit_gross_amount, 0) * greatest(coalesce(nullif(i.quantity, 0), nullif(i.qty, 0), 1), 1)
      ) as gross_line
    from public.marketplace_order_items i
    left join lateral (
      select hm.*
      from public.marketplace_variant_hpp_mappings hm
      where hm.tenant_id = v_tenant
        and coalesce(hm.is_active, true) = true
        and hm.marketplace_account_id = i.marketplace_account_id
        and (
          hm.marketplace_sku_id = coalesce(nullif(i.marketplace_sku_id, ''), nullif(i.remote_sku_id, ''))
          or hm.marketplace_seller_sku = coalesce(nullif(i.marketplace_seller_sku, ''), nullif(i.seller_sku, ''))
          or hm.local_sku = coalesce(nullif(i.mapped_local_sku, ''), nullif(i.local_sku, ''))
        )
      order by hm.updated_at desc nulls last, hm.created_at desc nulls last
      limit 1
    ) h on true
    where i.tenant_id = v_tenant
  ),
  item_agg as (
    select
      i.marketplace_order_id,
      count(*)::integer as item_count,
      bool_or(
        i.stock_out_at is not null
        or upper(coalesce(i.stock_action_status, '')) in ('STOCK_OUT_SUBMITTED','MATCHED','DONE','COMPLETED')
      ) as items_stocked_out,
      sum(coalesce(i.qty_final, 0))::numeric as qty_total,
      sum(coalesce(i.hpp_per_item, 0) * coalesce(i.qty_final, 0))::numeric as hpp_total,
      string_agg(distinct i.item_product_name, ', ' order by i.item_product_name) as item_names,
      string_agg(distinct nullif(i.item_local_sku, '-'), ', ' order by nullif(i.item_local_sku, '-')) as local_skus,
      string_agg(distinct nullif(i.item_marketplace_sku, '-'), ', ' order by nullif(i.item_marketplace_sku, '-')) as marketplace_skus,
      jsonb_agg(
        jsonb_build_object(
          'item_id', i.marketplace_order_item_id,
          'product_name', i.item_product_name,
          'variant_name', i.item_variant_name,
          'local_sku', i.item_local_sku,
          'marketplace_sku', i.item_marketplace_sku,
          'marketplace_seller_sku', coalesce(nullif(i.marketplace_seller_sku, ''), nullif(i.seller_sku, ''), '-'),
          'qty', i.qty_final,
          'gross', i.gross_line,
          'hpp_per_item', i.hpp_per_item,
          'hpp', i.hpp_per_item * i.qty_final,
          'stock_action_status', coalesce(nullif(i.stock_action_status, ''), nullif(i.scan_status, ''), nullif(i.return_review_status, ''), '-'),
          'tracking_number', coalesce(nullif(i.tracking_number, ''), nullif(i.package_id, ''), '-'),
          'return_case_id', nullif(i.return_case_id, ''),
          'return_case_status', nullif(i.return_case_status, '')
        )
        order by i.item_product_name, i.item_variant_name, i.marketplace_order_item_id
      ) as item_details
    from item_enriched i
    group by i.marketplace_order_id
  ),
  classified as (
    select
      ob.marketplace_order_id,
      ob.marketplace_account_id,
      ob.marketplace,
      coalesce(nullif(ma.store_alias, ''), nullif(ma.shop_name, ''), nullif(ob.shop_id, ''), '-') as shop_name,
      ob.order_key as external_order_id,
      ob.order_sn,
      upper(coalesce(ob.order_status, ob.status, '')) as order_status,
      ob.order_status_label,
      ob.buyer_username,
      ob.buyer_name_masked,
      ob.recipient_name,
      ob.tracking_number,
      case
        when nullif(ob.tracking_number, '') is null then null
        when ob.tracking_number in (ob.order_key, ob.order_id, ob.external_order_id, ob.order_sn, ob.label_code, ob.package_id) then null
        else ob.tracking_number
      end as real_tracking_number,
      ob.label_code,
      ob.package_id,
      ob.shipping_provider_name,
      ob.logistic_status,
      ob.cancel_request_id,
      ob.cancel_request_status,
      ob.cancel_request_reason,
      ob.cancel_request_note,
      ob.cancel_requested_at,
      ob.return_case_id,
      ob.return_case_status,
      ob.return_case_pulled_at,
      ob.cancel_review_status,
      ob.return_review_status,
      ob.stock_in_restored_at,
      coalesce(ia.item_count, 0) as item_count,
      coalesce(ia.qty_total, 0) as qty_total,
      coalesce(ia.hpp_total, 0) as hpp_total,
      coalesce(ia.item_names, '-') as item_names,
      coalesce(ia.local_skus, '-') as local_skus,
      coalesce(ia.marketplace_skus, '-') as marketplace_skus,
      coalesce(ia.item_details, '[]'::jsonb) as item_details,
      coalesce(ob.is_stock_out_completed, false)
        or ob.stock_transaction_id is not null
        or ob.stock_out_at is not null
        or ob.packed_at is not null
        or coalesce(ia.items_stocked_out, false) as stock_was_processed,
      case
        when upper(coalesce(ob.order_status, ob.status, '')) in ('CANCELLED','UNPAID')
         and not (
           coalesce(ob.is_stock_out_completed, false)
           or ob.stock_transaction_id is not null
           or ob.stock_out_at is not null
           or ob.packed_at is not null
           or coalesce(ia.items_stocked_out, false)
         )
         and (
           nullif(ob.tracking_number, '') is null
           or ob.tracking_number in (ob.order_key, ob.order_id, ob.external_order_id, ob.order_sn, ob.label_code, ob.package_id)
         ) then 'AUTO_DONE_NO_STOCK_IN'
        when upper(coalesce(ob.order_status, ob.status, '')) in ('CANCELLED','UNPAID') then 'REVIEW_CANCEL_WITH_REAL_RESI'
        when nullif(ob.return_case_id, '') is not null
          or upper(coalesce(ob.return_case_status, '')) in ('REQUESTED','PENDING','ACCEPTED','REFUNDING','REFUNDED','RETURNED','COMPLETED')
          or upper(coalesce(ob.order_status, ob.status, '')) in ('RETURNED','REFUND','REFUNDED') then 'REVIEW_REFUND_RETURN'
        when upper(coalesce(ob.order_status, ob.status, '')) = 'AWAITING_COLLECTION'
          or upper(coalesce(ob.logistic_status, '')) = 'AWAITING_COLLECTION'
          or nullif(ob.label_code, '') is not null then 'REVIEW_AWAITING_COLLECTION'
        else 'REVIEW'
      end as recommended_action,
      case
        when nullif(ob.cancel_request_reason, '') is not null then ob.cancel_request_reason
        when nullif(ob.cancel_request_note, '') is not null then ob.cancel_request_note
        when nullif(ob.return_case_status, '') is not null then 'Status retur: ' || ob.return_case_status
        when upper(coalesce(ob.order_status, ob.status, '')) in ('CANCELLED','UNPAID')
         and not (
           coalesce(ob.is_stock_out_completed, false)
           or ob.stock_transaction_id is not null
           or ob.stock_out_at is not null
           or ob.packed_at is not null
           or coalesce(ia.items_stocked_out, false)
         )
         and (
           nullif(ob.tracking_number, '') is null
           or ob.tracking_number in (ob.order_key, ob.order_id, ob.external_order_id, ob.order_sn, ob.label_code, ob.package_id)
         ) then 'Pesanan batal sebelum stok keluar. Tidak perlu stok masuk.'
        when upper(coalesce(ob.order_status, ob.status, '')) in ('CANCELLED','UNPAID') then 'Pesanan batal setelah ada resi atau stok keluar. Cek barang dan proses stok masuk bila barang kembali.'
        when nullif(ob.return_case_id, '') is not null
          or upper(coalesce(ob.return_case_status, '')) in ('REQUESTED','PENDING','ACCEPTED','REFUNDING','REFUNDED','RETURNED','COMPLETED')
          or upper(coalesce(ob.order_status, ob.status, '')) in ('RETURNED','REFUND','REFUNDED') then 'Ada refund atau retur. Cek barang fisik sebelum stok masuk.'
        when upper(coalesce(ob.order_status, ob.status, '')) = 'AWAITING_COLLECTION'
          or upper(coalesce(ob.logistic_status, '')) = 'AWAITING_COLLECTION'
          or nullif(ob.label_code, '') is not null then 'Pesanan menunggu pengiriman. Pantau status sebelum keputusan stok.'
        else 'Perlu dicek manual.'
      end as note,
      ob.order_at as order_created_at,
      (ob.order_at at time zone 'Asia/Jakarta')::date as order_date,
      coalesce(ob.order_updated_at, ob.updated_time, ob.updated_at, ob.pulled_at) as order_updated_at
    from orders_base ob
    left join item_agg ia on ia.marketplace_order_id = ob.marketplace_order_id
    left join public.marketplace_accounts ma
      on ma.marketplace_account_id = ob.marketplace_account_id
     and ma.tenant_id = ob.tenant_id
    where upper(coalesce(ob.order_status, ob.status, '')) in ('CANCELLED','UNPAID','RETURNED','REFUND','REFUNDED','AWAITING_COLLECTION')
       or coalesce(ob.has_cancel_request, false) = true
       or nullif(ob.cancel_request_id, '') is not null
       or nullif(ob.return_case_id, '') is not null
       or nullif(ob.return_case_status, '') is not null
       or nullif(ob.label_code, '') is not null
  ),
  searched as (
    select *
    from classified
    where v_search is null
       or lower(coalesce(external_order_id, '')) like '%' || v_search || '%'
       or lower(coalesce(order_sn, '')) like '%' || v_search || '%'
       or lower(coalesce(tracking_number, '')) like '%' || v_search || '%'
       or lower(coalesce(real_tracking_number, '')) like '%' || v_search || '%'
       or lower(coalesce(label_code, '')) like '%' || v_search || '%'
       or lower(coalesce(cancel_request_id, '')) like '%' || v_search || '%'
       or lower(coalesce(return_case_id, '')) like '%' || v_search || '%'
       or lower(coalesce(item_names, '')) like '%' || v_search || '%'
       or lower(coalesce(local_skus, '')) like '%' || v_search || '%'
       or lower(coalesce(marketplace_skus, '')) like '%' || v_search || '%'
  ),
  filtered as (
    select *
    from searched
    where v_action is null or v_action = 'ALL' or recommended_action = v_action
  ),
  counted as (
    select count(*)::integer as total from filtered
  ),
  paged as (
    select *
    from filtered
    order by
      case recommended_action
        when 'REVIEW_CANCEL_WITH_REAL_RESI' then 0
        when 'REVIEW_REFUND_RETURN' then 1
        when 'REVIEW_AWAITING_COLLECTION' then 2
        when 'AUTO_DONE_NO_STOCK_IN' then 3
        else 4
      end,
      order_updated_at desc nulls last,
      external_order_id desc
    offset ((v_page - 1) * v_page_size)
    limit v_page_size
  )
  select
    c.total,
    coalesce(jsonb_agg(to_jsonb(p) order by p.order_updated_at desc nulls last, p.external_order_id desc) filter (where p.external_order_id is not null), '[]'::jsonb)
  into v_total, v_rows
  from counted c
  left join paged p on true
  group by c.total;

  return jsonb_build_object(
    'ok', true,
    'version', 'data terbaru',
    'page', v_page,
    'page_size', v_page_size,
    'total', coalesce(v_total, 0),
    'rows', coalesce(v_rows, '[]'::jsonb),
    'note', 'Detail refund dan cancel sudah memuat item pesanan untuk pengecekan stok.'
  );
end;
$function$;

grant execute on function public.finance_get_auto_sync_setting() to authenticated, service_role;
grant execute on function public.finance_set_auto_sync_enabled(boolean, integer) to authenticated, service_role;
grant execute on function public.finance_customer_dashboard_snapshot_v24_6_82o(date, date, text, uuid) to authenticated, service_role;
grant execute on function public.finance_sku_order_detail_lines_v24_6_82e(date, date, text, uuid, text, integer, integer) to authenticated, service_role;
grant execute on function public.finance_sku_summary_rows_v24_6_82e(date, date, text, uuid) to authenticated, service_role;
grant execute on function public.finance_unpaid_sku_rows_v24_6_82e(date, date, text, uuid) to authenticated, service_role;
grant execute on function public.finance_anomaly_search_v24_6_82e(date, date, text, uuid, text, text, integer, integer) to authenticated, service_role;
grant execute on function public.finance_fix_exact_cache_settled_hpp_v24_6_82q(date, date, text, uuid) to authenticated, service_role;
grant execute on function public.finance_list_manual_operational_expenses_v24_6_80m(date, date, text, uuid) to authenticated, service_role;
grant execute on function public.finance_list_operational_expense_categories() to authenticated, service_role;
grant execute on function public.list_purchase_requests() to authenticated, service_role;
grant execute on function public.marketplace_list_active_accounts_for_filter(text) to authenticated, service_role;
grant execute on function public.marketplace_list_accounts_public(uuid) to authenticated, service_role;
grant execute on function public.marketplace_find_order_by_resi(uuid, text) to authenticated, service_role;
grant execute on function public.marketplace_activate_order_for_scan_by_resi(uuid, text) to authenticated, service_role;
grant execute on function public.marketplace_scan_order_item_by_resi(uuid, text, text) to authenticated, service_role;
grant execute on function public.marketplace_scan_order_item_manual_by_resi(uuid, text, uuid) to authenticated, service_role;
grant execute on function public.marketplace_finalize_scanned_order_stock_out_by_resi_guarded(uuid, text) to authenticated, service_role;
grant execute on function public.finance_insert_manual_operational_expense_v24_6_79(text, numeric, date, text) to authenticated, service_role;
grant execute on function public.finance_update_manual_operational_expense_v24_6_79(uuid, text, numeric, date, text) to authenticated, service_role;
grant execute on function public.finance_delete_manual_operational_expense_v24_6_79(uuid) to authenticated, service_role;
grant execute on function public.finance_upsert_sku_target_margin(text, numeric) to authenticated, service_role;
grant execute on function public.finance_record_sync_log(text, date, date, text, uuid, integer, integer, integer, integer, text) to authenticated, service_role;
grant execute on function public.finance_upsert_runtime_progress_v24_6_3(text, text, date, date, text, uuid, integer, integer, integer, integer, text) to authenticated, service_role;
grant execute on function public.finance_get_latest_runtime_progress_v24_6_3() to authenticated, service_role;
grant execute on function public.finance_mark_no_payout_order_v24_6_28(text, uuid, text, text) to authenticated, service_role;
grant execute on function public.finance_unmark_no_payout_order_v24_6_28(text, uuid) to authenticated, service_role;
grant execute on function public.finance_auto_mark_cancel_no_payout_v24_6_28(date, date, uuid) to authenticated, service_role;
grant execute on function public.marketplace_get_order_pull_auto_setting(uuid) to authenticated, service_role;
grant execute on function public.marketplace_set_order_pull_auto_enabled(uuid, boolean) to authenticated, service_role;
grant execute on function public.marketplace_order_pull_free_plan_housekeeping_v24_6_88(integer, integer) to authenticated, service_role;
grant execute on function public.marketplace_run_auto_order_pull_10m() to authenticated, service_role;
grant execute on function public.marketplace_order_queue_cleanup_v24_6_87(integer, integer, integer, integer) to authenticated, service_role;
grant execute on function public.marketplace_auto_runner_try_lock_v24_6_81b(text, integer, text) to authenticated, service_role;
grant execute on function public.marketplace_auto_runner_release_lock_v24_6_81b(text, text) to authenticated, service_role;
grant execute on function public.marketplace_reset_stale_auto_jobs_v24_6_81b(integer, integer, boolean) to authenticated, service_role;
grant execute on function public.marketplace_auto_direct_order_pull_v24_6_82q() to authenticated, service_role;
grant execute on function public.marketplace_job_monitor_snapshot_v24_6_9() to authenticated, service_role;
grant execute on function public.marketplace_job_reset_stuck_v24_6_9(text, boolean, integer) to authenticated, service_role;
grant execute on function public.marketplace_reset_order_finance_data(uuid) to authenticated, service_role;
grant execute on function public.marketplace_refund_cancel_review_v24_6_42(date, date, text, uuid, text, text, integer, integer) to authenticated, service_role;

notify pgrst, 'reload schema';

commit;
