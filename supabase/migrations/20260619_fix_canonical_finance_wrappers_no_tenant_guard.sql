-- Canonical finance wrapper repair.
-- No new public RPC name/version is added.
-- Fixes:
-- - finance_customer_dashboard_snapshot returns daily/chart data, expense/cash rows, and HPP split per marketplace.
-- - finance_dashboard_snapshot aliases canonical snapshot.
-- - finance_sku_order_details/detail_lines remain canonical wrappers to existing stable implementation.

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
declare
  v_filter text := lower(coalesce(p_payout_filter, 'all'));
begin
  if v_filter in ('settled', 'released', 'release', 'payout', 'paid_payout', 'sudah_payout', 'sudah payout') then
    v_filter := 'paid';
  elsif v_filter in ('pending', 'belum_payout', 'belum payout', 'no_payout', 'no payout', 'missing_payout') then
    v_filter := 'unpaid';
  end if;

  return public.finance_sku_order_details_v24_6_82o(
    p_start,
    p_end,
    p_marketplace,
    p_account_id,
    p_marketplace_sku,
    p_local_sku,
    p_search,
    v_filter,
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
  v_expenses jsonb := '[]'::jsonb;
  v_cash_flow jsonb := '[]'::jsonb;
  v_approved_purchases jsonb := '[]'::jsonb;
  v_profit_loss jsonb := '[]'::jsonb;

  v_gross numeric := 0;
  v_payout numeric := 0;
  v_hpp numeric := 0;
  v_unpaid_hpp numeric := 0;
  v_expense numeric := 0;
  v_purchase_cashout numeric := 0;
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

  -- Expenses and approved purchases.
  with expense_rows as (
    select
      'operational_expense'::text as source,
      coalesce(expense_date, paid_at)::date as row_date,
      coalesce(category, description, 'Biaya operasional')::text as category,
      coalesce(description, note, category, 'Biaya operasional')::text as note,
      abs(coalesce(amount, 0))::numeric as amount
    from public.finance_operational_expenses
    where coalesce(expense_date, paid_at)::date >= v_start
      and coalesce(expense_date, paid_at)::date <= v_end
      and (v_tenant_id is null or tenant_id = v_tenant_id)
      and lower(coalesce(status, 'approved')) not in ('rejected','reject','cancelled','canceled','void','deleted')
      and abs(coalesce(amount, 0)) > 0

    union all

    select
      'manual_expense'::text as source,
      expense_date::date as row_date,
      coalesce(category, 'Biaya manual')::text as category,
      coalesce(note, category, 'Biaya manual')::text as note,
      abs(coalesce(amount, 0))::numeric as amount
    from public.finance_manual_expenses
    where expense_date >= v_start
      and expense_date <= v_end
      and (v_tenant_id is null or tenant_id = v_tenant_id)
      and abs(coalesce(amount, 0)) > 0
  ),
  expense_json as (
    select
      coalesce(sum(amount), 0) as total,
      coalesce(jsonb_agg(jsonb_build_object(
        'source', source,
        'category', category,
        'description', note,
        'note', note,
        'date', row_date,
        'amount', amount,
        'cash_type', 'out',
        'type', 'out'
      ) order by row_date desc, source), '[]'::jsonb) as rows
    from expense_rows
  ),
  purchase_rows as (
    select
      'approved_purchase'::text as source,
      tanggal_beli::date as row_date,
      coalesce(nomor_nota, supplier_name, 'Pembelian disetujui')::text as category,
      coalesce(finance_note, catatan, supplier_name, nomor_nota, 'Pembelian disetujui')::text as note,
      abs(coalesce(total_amount, 0))::numeric as amount,
      request_id
    from public.purchase_requests
    where tanggal_beli >= v_start
      and tanggal_beli <= v_end
      and (v_tenant_id is null or tenant_id = v_tenant_id)
      and abs(coalesce(total_amount, 0)) > 0
      and (
        verified_at is not null
        or lower(coalesce(status,'')) in ('approved','verified','finance_approved','done','completed','paid')
      )
  ),
  purchase_json as (
    select
      coalesce(sum(amount), 0) as total,
      coalesce(jsonb_agg(jsonb_build_object(
        'source', source,
        'category', category,
        'description', note,
        'note', note,
        'date', row_date,
        'amount', amount,
        'cash_type', 'out',
        'type', 'out',
        'purchase_id', request_id
      ) order by row_date desc), '[]'::jsonb) as rows
    from purchase_rows
  )
  select
    ej.total,
    pj.total,
    ej.rows,
    pj.rows
  into v_expense, v_purchase_cashout, v_expenses, v_approved_purchases
  from expense_json ej cross join purchase_json pj;

  -- Direct HPP split from order items + HPP mappings.
  with item_rows as (
    select
      o.marketplace,
      o.marketplace_account_id,
      coalesce(oi.marketplace_sku_id, oi.remote_sku_id, oi.marketplace_sku) as marketplace_sku_id,
      coalesce(oi.marketplace_seller_sku, oi.seller_sku, oi.local_sku, oi.mapped_local_sku) as seller_sku,
      coalesce(oi.local_sku, oi.mapped_local_sku) as local_sku,
      coalesce(oi.qty, oi.quantity, 1)::numeric as qty
    from public.marketplace_order_items oi
    join public.marketplace_orders o
      on o.marketplace_order_id = oi.marketplace_order_id
    where o.order_created_at >= v_start_ts
      and o.order_created_at < v_end_ts
      and o.marketplace in ('shopee','tiktok_shop')
      and lower(coalesce(o.order_status, o.status, '')) !~ '(cancel|batal|dibatalkan|unpaid|belum bayar|belum dibayar)'
      and (v_tenant_id is null or o.tenant_id = v_tenant_id)
      and (v_marketplace is null or v_marketplace = '' or v_marketplace = 'all' or o.marketplace = v_marketplace)
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
  ),
  matched_hpp as (
    select
      i.marketplace,
      i.marketplace_account_id,
      i.qty,
      coalesce(mv.hpp_value, 0) as hpp_value
    from item_rows i
    left join lateral (
      select coalesce(m.hpp, m.hpp_amount, m.hpp_per_item, 0)::numeric as hpp_value
      from public.marketplace_variant_hpp_mappings m
      where m.marketplace = i.marketplace
        and (m.marketplace_account_id is null or m.marketplace_account_id = i.marketplace_account_id)
        and m.is_active is true
        and coalesce(m.hpp, m.hpp_amount, m.hpp_per_item, 0) > 0
        and (
          nullif(m.marketplace_sku_id,'') = nullif(i.marketplace_sku_id,'')
          or lower(nullif(m.marketplace_seller_sku,'')) = lower(nullif(i.seller_sku,''))
          or lower(nullif(m.local_sku,'')) = lower(nullif(i.local_sku,''))
        )
      order by
        case
          when nullif(m.marketplace_sku_id,'') = nullif(i.marketplace_sku_id,'') then 1
          when lower(nullif(m.marketplace_seller_sku,'')) = lower(nullif(i.seller_sku,'')) then 2
          when lower(nullif(m.local_sku,'')) = lower(nullif(i.local_sku,'')) then 3
          else 9
        end,
        m.updated_at desc nulls last
      limit 1
    ) mv on true
  ),
  hpp_by_marketplace as (
    select
      marketplace,
      marketplace_account_id,
      sum(qty * hpp_value) as hpp_total
    from matched_hpp
    group by 1,2
  )
  select coalesce(sum(hpp_total), 0)
  into v_hpp
  from hpp_by_marketplace;

  v_gross := coalesce(nullif(v_recon_summary->>'gross_sales', '')::numeric, 0);
  v_payout := coalesce(nullif(v_recon_summary->>'payout_total', '')::numeric, 0);
  v_unpaid_hpp := abs(coalesce(nullif(v_sku_aggr->>'unpaid_hpp_total', '')::numeric, 0));
  v_order_count := coalesce(nullif(v_recon_summary->>'order_count', '')::numeric, 0);
  v_finance_order_count := coalesce(nullif(v_recon_summary->>'finance_order_count', '')::numeric, 0);
  v_abnormal_count := coalesce(nullif(v_recon_summary->>'sample_order_count', '')::numeric, 0)
    + coalesce(nullif(v_recon_summary->>'negative_payout_count', '')::numeric, 0);
  v_profit := v_payout - v_hpp - v_expense - v_purchase_cashout;
  v_margin := case when v_payout > 0 then (v_profit / v_payout) * 100 else 0 end;

  -- Daily trend for dashboard analytics.
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
    'omzet_total', gross_sales,
    'payout_total', payout_total,
    'received_amount', payout_total,
    'order_count', order_count,
    'orders_count', order_count,
    'net_profit', payout_total
  ) order by day), '[]'::jsonb)
  into v_daily
  from daily_rows;

  -- Marketplace breakdown with correct direct HPP split.
  with item_rows as (
    select
      o.marketplace,
      o.marketplace_account_id,
      coalesce(oi.marketplace_sku_id, oi.remote_sku_id, oi.marketplace_sku) as marketplace_sku_id,
      coalesce(oi.marketplace_seller_sku, oi.seller_sku, oi.local_sku, oi.mapped_local_sku) as seller_sku,
      coalesce(oi.local_sku, oi.mapped_local_sku) as local_sku,
      coalesce(oi.qty, oi.quantity, 1)::numeric as qty
    from public.marketplace_order_items oi
    join public.marketplace_orders o
      on o.marketplace_order_id = oi.marketplace_order_id
    where o.order_created_at >= v_start_ts
      and o.order_created_at < v_end_ts
      and o.marketplace in ('shopee','tiktok_shop')
      and lower(coalesce(o.order_status, o.status, '')) !~ '(cancel|batal|dibatalkan|unpaid|belum bayar|belum dibayar)'
      and (v_tenant_id is null or o.tenant_id = v_tenant_id)
      and (v_marketplace is null or v_marketplace = '' or v_marketplace = 'all' or o.marketplace = v_marketplace)
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
  ),
  matched_hpp as (
    select
      i.marketplace,
      i.marketplace_account_id,
      i.qty,
      coalesce(mv.hpp_value, 0) as hpp_value
    from item_rows i
    left join lateral (
      select coalesce(m.hpp, m.hpp_amount, m.hpp_per_item, 0)::numeric as hpp_value
      from public.marketplace_variant_hpp_mappings m
      where m.marketplace = i.marketplace
        and (m.marketplace_account_id is null or m.marketplace_account_id = i.marketplace_account_id)
        and m.is_active is true
        and coalesce(m.hpp, m.hpp_amount, m.hpp_per_item, 0) > 0
        and (
          nullif(m.marketplace_sku_id,'') = nullif(i.marketplace_sku_id,'')
          or lower(nullif(m.marketplace_seller_sku,'')) = lower(nullif(i.seller_sku,''))
          or lower(nullif(m.local_sku,'')) = lower(nullif(i.local_sku,''))
        )
      order by
        case
          when nullif(m.marketplace_sku_id,'') = nullif(i.marketplace_sku_id,'') then 1
          when lower(nullif(m.marketplace_seller_sku,'')) = lower(nullif(i.seller_sku,'')) then 2
          when lower(nullif(m.local_sku,'')) = lower(nullif(i.local_sku,'')) then 3
          else 9
        end,
        m.updated_at desc nulls last
      limit 1
    ) mv on true
  ),
  hpp_by_marketplace as (
    select
      marketplace,
      marketplace_account_id,
      sum(qty * hpp_value) as hpp_total
    from matched_hpp
    group by 1,2
  ),
  market_rows as (
    select
      row,
      coalesce(h.hpp_total, 0) as hpp_total
    from jsonb_array_elements(coalesce(v_recon->'by_marketplace', '[]'::jsonb)) row
    left join hpp_by_marketplace h
      on h.marketplace = row->>'marketplace'
     and h.marketplace_account_id::text = row->>'marketplace_account_id'
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

  v_cash_flow := jsonb_build_array(
    jsonb_build_object('source', 'Marketplace', 'category', 'Payout marketplace', 'cash_type', 'in', 'type', 'in', 'amount', v_payout, 'date', v_end),
    jsonb_build_object('source', 'Biaya operasional', 'category', 'Biaya operasional', 'cash_type', 'out', 'type', 'out', 'amount', -abs(v_expense), 'date', v_end),
    jsonb_build_object('source', 'Pembelian disetujui', 'category', 'Pembelian disetujui', 'cash_type', 'out', 'type', 'out', 'amount', -abs(v_purchase_cashout), 'date', v_end),
    jsonb_build_object('source', 'Arus kas bersih', 'category', 'Arus kas bersih', 'cash_type', case when (v_payout - v_expense - v_purchase_cashout) >= 0 then 'in' else 'out' end, 'type', case when (v_payout - v_expense - v_purchase_cashout) >= 0 then 'in' else 'out' end, 'amount', v_payout - v_expense - v_purchase_cashout, 'date', v_end)
  );

  v_profit_loss := jsonb_build_array(
    jsonb_build_object('label', 'Omzet', 'category', 'gross_sales', 'amount', v_gross, 'format', 'money'),
    jsonb_build_object('label', 'Payout diterima', 'category', 'payout', 'amount', v_payout, 'format', 'money'),
    jsonb_build_object('label', 'HPP settled', 'category', 'hpp', 'amount', -abs(v_hpp), 'format', 'money'),
    jsonb_build_object('label', 'Biaya operasional', 'category', 'operational_expense', 'amount', -abs(v_expense), 'format', 'money'),
    jsonb_build_object('label', 'Pembelian disetujui', 'category', 'approved_purchase', 'amount', -abs(v_purchase_cashout), 'format', 'money'),
    jsonb_build_object('label', 'Laba bersih', 'category', 'net_profit', 'amount', v_profit, 'format', 'money')
  );

  return jsonb_build_object(
    'ok', true,
    'version', 'finance_customer_dashboard_snapshot_canonical_existing_wrappers_20260619_runtime_v2',
    'source', 'finance_customer_dashboard_snapshot',
    'reconciliation_source', coalesce(v_recon->>'reconciliation_source', 'finance_marketplace_reconciliation_breakdown'),
    'period_start', v_start,
    'period_end', v_end,
    'summary', jsonb_build_object(
      'policy', 'canonical_existing_rpc_order_date_reconciliation_direct_hpp_expense_cash',
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
      'manual_expense_total', v_expense,
      'manual_operational_expense', v_expense,
      'expense_total', v_expense + v_purchase_cashout,
      'operational_cost_total', v_expense + v_purchase_cashout,
      'approved_purchase_total', v_purchase_cashout,
      'purchase_cashout', v_purchase_cashout,
      'approved_purchase_cashout', v_purchase_cashout,
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
    'by_date', v_daily,
    'trend', v_daily,
    'by_sku', v_sku_rows,
    'sku_rows', v_sku_rows,
    'by_marketplace', v_by_marketplace,
    'marketplaces', v_by_marketplace,
    'profit_loss', v_profit_loss,
    'profit_loss_breakdown', coalesce(v_recon->'profit_loss_breakdown', '[]'::jsonb),
    'abnormals', coalesce(v_recon->'abnormals', '[]'::jsonb),
    'server_abnormals', coalesce(v_recon->'abnormals', '[]'::jsonb),
    'sample_orders', coalesce(v_recon->'sample_orders', '[]'::jsonb),
    'expenses', v_expenses,
    'cash_flow', v_cash_flow,
    'approved_purchases', v_approved_purchases
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
