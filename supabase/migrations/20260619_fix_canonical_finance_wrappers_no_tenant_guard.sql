-- Fix canonical finance wrappers without adding public RPC versions.
-- Canonical snapshot is rebuilt from existing live RPCs:
--   finance_marketplace_reconciliation_breakdown
--   finance_sku_order_details
-- It avoids the old v24 snapshot payout/import-date mismatch and keeps app-facing names stable.

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
set statement_timeout = '180s'
as $$
declare
  v_start date := coalesce(p_start, date_trunc('month', now())::date);
  v_end date := coalesce(p_end, now()::date);
  v_start_ts timestamptz := coalesce(p_start, date_trunc('month', now())::date)::timestamptz;
  v_end_ts timestamptz := (coalesce(p_end, now()::date)::date + 1)::timestamptz;
  v_marketplace text := coalesce(public.marketplace_normalize_key(p_marketplace), p_marketplace);
  v_tenant_id uuid := null;
  v_claims text := null;

  v_recon jsonb := '{}'::jsonb;
  v_recon_summary jsonb := '{}'::jsonb;
  v_sku jsonb := '{}'::jsonb;
  v_sku_aggr jsonb := '{}'::jsonb;
  v_sku_rows jsonb := '[]'::jsonb;
  v_by_marketplace jsonb := '[]'::jsonb;
  v_daily jsonb := '[]'::jsonb;
  v_profit_loss jsonb := '[]'::jsonb;

  v_gross numeric := 0;
  v_payout numeric := 0;
  v_hpp numeric := 0;
  v_unpaid_hpp numeric := 0;
  v_expense numeric := 0;
  v_profit numeric := 0;
  v_order_count numeric := 0;
  v_finance_order_count numeric := 0;
  v_abnormal_count numeric := 0;
  v_margin numeric := 0;
begin
  begin
    v_claims := current_setting('request.jwt.claims', true);
    if nullif(v_claims, '') is not null then
      v_tenant_id := nullif((v_claims::jsonb ->> 'tenant_id'), '')::uuid;
    end if;
  exception when others then
    v_tenant_id := null;
  end;

  v_recon := coalesce(public.finance_marketplace_reconciliation_breakdown(
    v_start,
    v_end,
    p_marketplace,
    p_account_id
  ), '{}'::jsonb);

  v_recon_summary := coalesce(v_recon->'summary', '{}'::jsonb);

  -- page_size intentionally high so dashboard by_sku/HPP marketplace split has enough rows.
  -- aggregates still come from the canonical SKU detail RPC.
  v_sku := coalesce(public.finance_sku_order_details(
    v_start,
    v_end,
    p_marketplace,
    p_account_id,
    null,
    null,
    null,
    'all',
    1,
    10000
  ), '{}'::jsonb);

  v_sku_aggr := coalesce(v_sku->'aggregates', '{}'::jsonb);
  v_sku_rows := coalesce(v_sku->'rows', '[]'::jsonb);

  v_gross := coalesce(nullif(v_recon_summary->>'gross_sales', '')::numeric, 0);
  v_payout := coalesce(nullif(v_recon_summary->>'payout_total', '')::numeric, 0);
  v_hpp := abs(coalesce(nullif(v_sku_aggr->>'total_hpp', '')::numeric, 0));
  v_unpaid_hpp := abs(coalesce(nullif(v_sku_aggr->>'unpaid_hpp_total', '')::numeric, 0));
  v_expense := coalesce(nullif(v_recon_summary->>'expense_total', '')::numeric, 0);
  v_profit := v_payout - v_hpp - v_expense;
  v_order_count := coalesce(nullif(v_recon_summary->>'order_count', '')::numeric, 0);
  v_finance_order_count := coalesce(nullif(v_recon_summary->>'finance_order_count', '')::numeric, 0);
  v_abnormal_count := coalesce(nullif(v_recon_summary->>'sample_order_count', '')::numeric, 0)
    + coalesce(nullif(v_recon_summary->>'negative_payout_count', '')::numeric, 0);
  v_margin := case when v_payout > 0 then (v_profit / v_payout) * 100 else 0 end;

  with finance_by_order as (
    select
      fr.tenant_id,
      fr.marketplace,
      fr.marketplace_account_id,
      fr.order_id as order_sn,
      sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0))::numeric as payout_amount
    from public.marketplace_finance_reports fr
    where fr.marketplace in ('shopee', 'tiktok_shop')
      and (v_tenant_id is null or fr.tenant_id = v_tenant_id)
      and (v_marketplace is null or v_marketplace = '' or v_marketplace = 'all' or fr.marketplace = v_marketplace)
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
    group by fr.tenant_id, fr.marketplace, fr.marketplace_account_id, fr.order_id
  ),
  daily_rows as (
    select
      (mo.order_created_at at time zone 'UTC')::date as day,
      count(distinct mo.order_sn)::int as order_count,
      sum(coalesce(mo.total_amount, mo.gross_amount, mo.paid_amount, 0))::numeric as gross_sales,
      sum(coalesce(f.payout_amount, 0))::numeric as payout_total
    from public.marketplace_orders mo
    left join finance_by_order f
      on f.tenant_id = mo.tenant_id
     and f.marketplace = mo.marketplace
     and f.marketplace_account_id = mo.marketplace_account_id
     and f.order_sn = mo.order_sn
    where mo.order_created_at >= v_start_ts
      and mo.order_created_at < v_end_ts
      and mo.marketplace in ('shopee', 'tiktok_shop')
      and (v_tenant_id is null or mo.tenant_id = v_tenant_id)
      and (v_marketplace is null or v_marketplace = '' or v_marketplace = 'all' or mo.marketplace = v_marketplace)
      and (p_account_id is null or mo.marketplace_account_id = p_account_id)
      and lower(coalesce(mo.order_status, mo.status, '')) !~ '(cancel|batal|dibatalkan|unpaid|belum bayar|belum dibayar)'
    group by 1
    order by 1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'date', day,
    'day', day,
    'gross_sales', gross_sales,
    'gross_total', gross_sales,
    'omzet', gross_sales,
    'payout_total', payout_total,
    'received_amount', payout_total,
    'order_count', order_count,
    'orders_count', order_count,
    'net_profit', payout_total
  ) order by day), '[]'::jsonb)
  into v_daily
  from daily_rows;

  with sku_hpp_by_marketplace as (
    select
      elem->>'marketplace' as marketplace,
      elem->>'marketplace_account_id' as marketplace_account_id,
      sum(abs(coalesce(nullif(elem->>'hpp_total', '')::numeric, 0))) as hpp_total
    from jsonb_array_elements(v_sku_rows) elem
    group by 1, 2
  ),
  market_rows as (
    select
      row,
      coalesce(h.hpp_total, 0) as hpp_total
    from jsonb_array_elements(coalesce(v_recon->'by_marketplace', '[]'::jsonb)) row
    left join sku_hpp_by_marketplace h
      on h.marketplace = row->>'marketplace'
     and (
       h.marketplace_account_id = row->>'marketplace_account_id'
       or h.marketplace_account_id is null
       or h.marketplace_account_id = ''
     )
  )
  select coalesce(jsonb_agg(
    row || jsonb_build_object(
      'hpp_total', hpp_total,
      'total_hpp', hpp_total,
      'settled_hpp_total', hpp_total,
      'paid_hpp_total', hpp_total,
      'profit', coalesce(nullif(row->>'payout_total', '')::numeric, 0) - hpp_total,
      'net_profit', coalesce(nullif(row->>'payout_total', '')::numeric, 0) - hpp_total,
      'margin_percent', case
        when coalesce(nullif(row->>'payout_total', '')::numeric, 0) > 0
        then ((coalesce(nullif(row->>'payout_total', '')::numeric, 0) - hpp_total)
          / coalesce(nullif(row->>'payout_total', '')::numeric, 0)) * 100
        else 0
      end,
      'net_margin_percent', case
        when coalesce(nullif(row->>'payout_total', '')::numeric, 0) > 0
        then ((coalesce(nullif(row->>'payout_total', '')::numeric, 0) - hpp_total)
          / coalesce(nullif(row->>'payout_total', '')::numeric, 0)) * 100
        else 0
      end
    )
  ), '[]'::jsonb)
  into v_by_marketplace
  from market_rows;

  v_profit_loss := jsonb_build_array(
    jsonb_build_object('label', 'HPP settled', 'category', 'hpp', 'amount', v_hpp, 'format', 'money'),
    jsonb_build_object('label', 'Biaya operasional', 'category', 'operational_expense', 'amount', v_expense, 'format', 'money'),
    jsonb_build_object('label', 'Laba bersih', 'category', 'net_profit', 'amount', v_profit, 'format', 'money')
  );

  return jsonb_build_object(
    'ok', true,
    'version', 'finance_customer_dashboard_snapshot_canonical_existing_wrappers_20260619',
    'source', 'finance_customer_dashboard_snapshot',
    'reconciliation_source', coalesce(v_recon->>'reconciliation_source', 'finance_marketplace_reconciliation_breakdown'),
    'period_start', v_start,
    'period_end', v_end,
    'summary', jsonb_build_object(
      'policy', 'canonical_existing_rpc_order_date_reconciliation_plus_sku_hpp',
      'period_start', v_start,
      'period_end', v_end,
      'gross_sales', v_gross,
      'gross_total', v_gross,
      'gross_amount', v_gross,
      'omzet', v_gross,
      'omzet_total', v_gross,
      'payout_total', v_payout,
      'payout_amount', v_payout,
      'received_amount', v_payout,
      'net_received', v_payout,
      'net_settlement', v_payout,
      'hpp_total', v_hpp,
      'total_hpp', v_hpp,
      'paid_hpp_total', v_hpp,
      'settled_hpp_total', v_hpp,
      'pending_hpp_total', v_unpaid_hpp,
      'estimated_unpaid_hpp_total', v_unpaid_hpp,
      'unpaid_estimated_hpp_total', v_unpaid_hpp,
      'expense_total', v_expense,
      'operational_cost_total', v_expense,
      'net_profit', v_profit,
      'profit', v_profit,
      'margin_percent', v_margin,
      'net_margin_percent', v_margin,
      'order_count', v_order_count,
      'orders_count', v_order_count,
      'finance_order_count', v_finance_order_count,
      'finance_orders_count', v_finance_order_count,
      'abnormal_count', v_abnormal_count,
      'marketplace_count', jsonb_array_length(v_by_marketplace),
      'source_count', jsonb_array_length(v_by_marketplace),
      'minus_payout_total', coalesce(nullif(v_recon_summary->>'sample_negative_payout_total', '')::numeric, 0) * -1,
      'payout_minus_total', coalesce(nullif(v_recon_summary->>'sample_negative_payout_total', '')::numeric, 0) * -1,
      'minus_payout_total_abs', abs(coalesce(nullif(v_recon_summary->>'sample_negative_payout_total', '')::numeric, 0)),
      'payout_minus_total_abs', abs(coalesce(nullif(v_recon_summary->>'sample_negative_payout_total', '')::numeric, 0)),
      'negative_payout_total_abs', abs(coalesce(nullif(v_recon_summary->>'sample_negative_payout_total', '')::numeric, 0)),
      'negative_payout_total', coalesce(nullif(v_recon_summary->>'sample_negative_payout_total', '')::numeric, 0) * -1,
      'negative_payout_count', coalesce(nullif(v_recon_summary->>'sample_order_count', '')::numeric, 0)
    ),
    'days', v_daily,
    'daily', v_daily,
    'by_sku', v_sku_rows,
    'sku_rows', v_sku_rows,
    'by_marketplace', v_by_marketplace,
    'marketplaces', v_by_marketplace,
    'profit_loss', v_profit_loss,
    'profit_loss_breakdown', coalesce(v_recon->'profit_loss_breakdown', '[]'::jsonb),
    'abnormals', coalesce(v_recon->'abnormals', '[]'::jsonb),
    'server_abnormals', coalesce(v_recon->'abnormals', '[]'::jsonb),
    'sample_orders', coalesce(v_recon->'sample_orders', '[]'::jsonb),
    'expenses', '[]'::jsonb,
    'cash_flow', '[]'::jsonb,
    'approved_purchases', '[]'::jsonb
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
set statement_timeout = '180s'
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

grant execute on function public.finance_customer_dashboard_snapshot(date, date, text, uuid)
  to authenticated, service_role;

grant execute on function public.finance_dashboard_snapshot(date, date, text, uuid)
  to authenticated, service_role;

grant execute on function public.finance_sku_order_details(date, date, text, uuid, text, text, text, text, integer, integer)
  to authenticated, service_role;

grant execute on function public.finance_sku_order_detail_lines(date, date, text, uuid, text, integer, integer)
  to authenticated, service_role;

notify pgrst, 'reload schema';
