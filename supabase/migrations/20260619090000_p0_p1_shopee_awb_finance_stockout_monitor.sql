-- P0/P1 canonical fixes: Shopee physical AWB guard, finance marketplace aliasing, dispatcher monitor coverage.
CREATE OR REPLACE FUNCTION public.marketplace_find_order_by_resi(p_tenant_id uuid, p_resi_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_code text := lower(trim(coalesce(p_resi_code, '')));
  v_order record;
  v_total_items integer := 0;
  v_scanned_items integer := 0;
  v_marketplace_note text;
  v_physical_resi text;
begin
  if p_tenant_id is null or v_code = '' then
    return jsonb_build_object('ok', false, 'message', 'Scan atau input resi fisik label pengiriman terlebih dahulu.');
  end if;

  if upper(v_code) like 'OFG%' or v_code ~ '^1200[0-9]{6,}$' or v_code ~ '^[0-9]{16,}$' then
    return jsonb_build_object(
      'ok', false,
      'message', 'Scan resi fisik label pengiriman, bukan OFG/order/package reference marketplace.'
    );
  end if;

  perform public.marketplace_assert_tenant_access(p_tenant_id);

  select
    o.*,
    coalesce(nullif(ma.store_alias, ''), nullif(ma.shop_name, ''), nullif(o.shop_id, ''), '-') as account_name,
    coalesce(
      nullif(o.tracking_number, ''),
      nullif(o.raw_order->>'tracking_number', '')
    ) as physical_resi
  into v_order
  from public.marketplace_orders o
  left join public.marketplace_accounts ma
    on ma.marketplace_account_id = o.marketplace_account_id
   and ma.tenant_id = o.tenant_id
  where o.tenant_id = p_tenant_id
    and (
      lower(coalesce(o.tracking_number, '')) = v_code
      or lower(coalesce(o.raw_order->>'tracking_number', '')) = v_code
      or exists (
        select 1
        from public.marketplace_order_items oi
        where oi.tenant_id = o.tenant_id
          and oi.marketplace_order_id = o.marketplace_order_id
          and lower(coalesce(oi.tracking_number, '')) = v_code
      )
    )
  order by coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) desc nulls last,
           o.created_at desc nulls last
  limit 1;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'message', 'Pesanan tidak ditemukan untuk resi fisik tersebut. Jika ini Shopee dan yang muncul masih OFG/package number, tarik/backfill resi fisik dari logistics API dulu.'
    );
  end if;

  if v_code in (
    lower(coalesce(v_order.external_order_id, '')),
    lower(coalesce(v_order.order_sn, '')),
    lower(coalesce(v_order.order_id, '')),
    lower(coalesce(v_order.remote_order_id, '')),
    lower(coalesce(v_order.package_id, '')),
    lower(coalesce(v_order.remote_package_id, ''))
  ) then
    return jsonb_build_object(
      'ok', false,
      'message', 'Scan resi fisik label pengiriman, bukan nomor order atau package marketplace.'
    );
  end if;

  v_physical_resi := nullif(v_order.physical_resi, '');
  if v_physical_resi is null then
    v_physical_resi := p_resi_code;
  end if;

  v_marketplace_note := public.marketplace_extract_order_note(v_order.note, v_order.raw_order);

  select
    count(*)::integer,
    count(*) filter (
      where coalesce(oi.scanned_qty, 0) >= greatest(coalesce(nullif(oi.quantity, 0), nullif(oi.qty, 0), 1), 1)
    )::integer
  into v_total_items, v_scanned_items
  from public.marketplace_order_items oi
  where oi.tenant_id = p_tenant_id
    and oi.marketplace_order_id = v_order.marketplace_order_id;

  return jsonb_build_object(
    'ok', true,
    'message', 'Pesanan ditemukan dari resi fisik. Silakan lanjut scan item.',
    'marketplace_order_id', v_order.marketplace_order_id,
    'marketplace', v_order.marketplace,
    'account_name', v_order.account_name,
    'shop_name', v_order.account_name,
    'external_order_id', coalesce(nullif(v_order.external_order_id, ''), nullif(v_order.order_sn, ''), nullif(v_order.order_id, ''), v_order.marketplace_order_id::text),
    'order_sn', v_order.order_sn,
    'tracking_number', v_physical_resi,
    'physical_resi', v_physical_resi,
    'order_status', coalesce(v_order.order_status, v_order.status),
    'marketplace_note', v_marketplace_note,
    'seller_note', v_marketplace_note,
    'order_date', (coalesce(v_order.order_created_at, v_order.paid_at, v_order.created_time, v_order.created_at) at time zone 'Asia/Jakarta')::date,
    'total_items', coalesce(v_total_items, 0),
    'processed', coalesce(v_scanned_items, 0),
    'order_ready_to_finalize', coalesce(v_total_items, 0) > 0 and coalesce(v_scanned_items, 0) >= coalesce(v_total_items, 0)
  );
end;
$function$;

GRANT EXECUTE ON FUNCTION public.marketplace_find_order_by_resi(uuid, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.finance_customer_dashboard_snapshot(p_start date DEFAULT NULL::date, p_end date DEFAULT NULL::date, p_marketplace text DEFAULT NULL::text, p_account_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '180s'
AS $function$
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
    v_marketplace,
    p_account_id
  ), '{}'::jsonb);

  v_recon_summary := coalesce(v_recon->'summary', '{}'::jsonb);

  v_sku := coalesce(public.finance_sku_order_details(
    v_start,
    v_end,
    v_marketplace,
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
$function$;

GRANT EXECUTE ON FUNCTION public.finance_customer_dashboard_snapshot(date, date, text, uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.marketplace_dispatcher_monitor_snapshot()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_now timestamptz := now();
  v_order jsonb;
  v_finance jsonb;
  v_product jsonb;
  v_retention jsonb;
  v_bootstrap jsonb;
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
      'lock_status', case when s.locked_until is null then 'free' when s.locked_until < v_now then 'stale' else 'locked' end,
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
    select count(*)::integer as orders_90d,
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
      'lock_status', case when s.locked_until is null then 'free' when s.locked_until < v_now then 'stale' else 'locked' end,
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
    select count(*)::integer as finance_reports_90d,
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
      'tenant_id', ma.tenant_id,
      'marketplace_account_id', ma.marketplace_account_id,
      'marketplace', ma.marketplace,
      'status', case when coalesce(p.product_rows, 0) > 0 then 'synced' else 'empty' end,
      'product_rows', coalesce(p.product_rows, 0),
      'product_statuses', coalesce(p.product_statuses, '[]'::jsonb),
      'last_product_updated_at', p.last_product_updated_at,
      'last_product_seen_at', p.last_product_seen_at
    ) order by ma.marketplace, ma.marketplace_account_id
  ), '[]'::jsonb)
  into v_product
  from public.marketplace_accounts ma
  left join lateral (
    select count(*)::integer as product_rows,
      max(ps.updated_at) as last_product_updated_at,
      max(ps.last_seen_at) as last_product_seen_at,
      coalesce((
        select jsonb_agg(jsonb_build_object('status', product_status, 'rows', rows) order by product_status)
        from (
          select coalesce(ps2.product_status, '-') as product_status, count(*)::integer as rows
          from public.marketplace_product_snapshots ps2
          where ps2.marketplace_account_id = ma.marketplace_account_id
          group by 1
        ) x
      ), '[]'::jsonb) as product_statuses
    from public.marketplace_product_snapshots ps
    where ps.marketplace_account_id = ma.marketplace_account_id
  ) p on true
  where ma.marketplace in ('shopee', 'tiktok_shop')
    and ma.status = 'active'
    and coalesce(ma.is_deleted, false) = false
    and coalesce(ma.is_active, true) = true;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'tenant_id', tenant_id,
      'marketplace_account_id', marketplace_account_id,
      'marketplace', marketplace,
      'store_name', store_name,
      'status', case when coalesce(total_old_rows, 0) > 0 then 'needs_cleanup' else 'ok' end,
      'cutoff_date_wib', cutoff_date_wib,
      'old_order_rows', coalesce(old_order_rows, 0),
      'old_finance_report_rows', coalesce(old_finance_report_rows, 0),
      'old_order_job_rows', coalesce(old_order_job_rows, 0),
      'old_finance_job_rows', coalesce(old_finance_job_rows, 0),
      'total_old_rows', coalesce(total_old_rows, 0),
      'refreshed_at', refreshed_at
    ) order by marketplace, marketplace_account_id
  ), '[]'::jsonb)
  into v_retention
  from public.marketplace_retention_90d_audit;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'tenant_id', ma.tenant_id,
      'marketplace_account_id', ma.marketplace_account_id,
      'marketplace', ma.marketplace,
      'order_bootstrap_status', coalesce(os.bootstrap_status, 'missing'),
      'order_bootstrap_cursor_at', case when os.bootstrap_cursor_seconds is null then null else to_timestamp(os.bootstrap_cursor_seconds) end,
      'order_bootstrap_completed_at', os.bootstrap_completed_at,
      'finance_bootstrap_status', coalesce(fs.finance_status, 'missing'),
      'finance_bootstrap_cursor_date', fs.bootstrap_cursor_date,
      'finance_bootstrap_completed_at', fs.bootstrap_completed_at
    ) order by ma.marketplace, ma.marketplace_account_id
  ), '[]'::jsonb)
  into v_bootstrap
  from public.marketplace_accounts ma
  left join public.marketplace_order_sync_state os
    on os.marketplace_account_id = ma.marketplace_account_id
  left join public.marketplace_finance_sync_state fs
    on fs.marketplace_account_id = ma.marketplace_account_id
  where ma.marketplace in ('shopee', 'tiktok_shop')
    and ma.status = 'active'
    and coalesce(ma.is_deleted, false) = false
    and coalesce(ma.is_active, true) = true;

  select coalesce(jsonb_agg(
    jsonb_build_object('jobid', c.jobid, 'jobname', c.jobname, 'schedule', c.schedule, 'active', c.active)
    order by c.jobid
  ), '[]'::jsonb)
  into v_cron
  from cron.job c
  where c.jobname ilike '%marketplace%';

  select jsonb_build_object(
    'active_accounts', (
      select count(*)::integer from public.marketplace_accounts ma
      where ma.marketplace in ('shopee', 'tiktok_shop') and ma.status = 'active'
        and coalesce(ma.is_deleted, false) = false and coalesce(ma.is_active, true) = true
    ),
    'accounts_missing_order_state', (
      select count(*)::integer from public.marketplace_accounts ma
      left join public.marketplace_order_sync_state os on os.marketplace_account_id = ma.marketplace_account_id
      where ma.marketplace in ('shopee', 'tiktok_shop') and ma.status = 'active'
        and coalesce(ma.is_deleted, false) = false and coalesce(ma.is_active, true) = true
        and os.marketplace_account_id is null
    ),
    'accounts_missing_finance_state', (
      select count(*)::integer from public.marketplace_accounts ma
      left join public.marketplace_finance_sync_state fs on fs.marketplace_account_id = ma.marketplace_account_id
      where ma.marketplace in ('shopee', 'tiktok_shop') and ma.status = 'active'
        and coalesce(ma.is_deleted, false) = false and coalesce(ma.is_active, true) = true
        and fs.marketplace_account_id is null
    ),
    'accounts_missing_product_snapshot', (
      select count(*)::integer from public.marketplace_accounts ma
      where ma.marketplace in ('shopee', 'tiktok_shop') and ma.status = 'active'
        and coalesce(ma.is_deleted, false) = false and coalesce(ma.is_active, true) = true
        and not exists (
          select 1 from public.marketplace_product_snapshots ps
          where ps.marketplace_account_id = ma.marketplace_account_id
        )
    ),
    'retention_accounts_with_old_rows', (
      select count(*)::integer from public.marketplace_retention_90d_audit
      where coalesce(total_old_rows, 0) > 0
    )
  )
  into v_coverage;

  select jsonb_build_object(
    'order_bad_count', (
      select count(*)::integer from public.marketplace_order_sync_state
      where failure_count > 0 or last_error is not null or locked_until < v_now
    ),
    'finance_bad_count', (
      select count(*)::integer from public.marketplace_finance_sync_state
      where (marketplace = 'shopee' and (failure_count > 0 or last_error is not null or locked_until < v_now))
         or (marketplace = 'tiktok_shop' and (finance_status <> 'unsupported' or failure_count > 0 or last_error is not null))
    ),
    'product_bad_count', (
      select count(*)::integer
      from jsonb_array_elements(v_product) p
      where coalesce((p->>'product_rows')::integer, 0) = 0
    ),
    'retention_old_rows', (
      select coalesce(sum(total_old_rows), 0)::bigint from public.marketplace_retention_90d_audit
    ),
    'bootstrap_running_count', (
      select count(*)::integer
      from public.marketplace_order_sync_state
      where bootstrap_status in ('running', 'queued', 'pulling', 'syncing')
    ),
    'order_dispatcher_active', exists (
      select 1 from cron.job where jobname = 'marketplace-order-dispatcher-every-2-min' and active is true
    ),
    'finance_dispatcher_active', exists (
      select 1 from cron.job where jobname = 'marketplace-finance-dispatcher-every-5-min' and active is true
    ),
    'product_pull_available', exists (
      select 1 from public.marketplace_product_snapshots
    ),
    'retention_cron_active', exists (
      select 1 from cron.job where jobname ilike '%retention%' and active is true
    ),
    'old_finance_pull_active', exists (
      select 1 from cron.job where jobname = 'marketplace-finance-pull-every-5-min' and active is true
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
    'product_states', v_product,
    'retention_states', v_retention,
    'bootstrap_states', v_bootstrap,
    'cron_jobs', v_cron
  );
end;
$function$;

GRANT EXECUTE ON FUNCTION public.marketplace_dispatcher_monitor_snapshot() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.fill_shopee_tracking_from_raw_order()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
declare
  v_tracking text;
  v_tracking_lower text;
begin
  if new.marketplace = 'shopee' then
    v_tracking := coalesce(
      nullif(new.raw_order #>> '{logistics_tracking_response,response,tracking_number}', ''),
      nullif(new.raw_order #>> '{logistics_tracking_response,tracking_number}', ''),
      nullif(new.raw_order #>> '{logistics_tracking_response,response,tracking_no}', ''),
      nullif(new.raw_order #>> '{logistics_tracking_response,tracking_no}', ''),
      nullif(new.raw_order #>> '{logistics_tracking_response,response,waybill_number}', ''),
      nullif(new.raw_order #>> '{logistics_tracking_response,waybill_number}', ''),
      nullif(new.raw_order #>> '{logistics_tracking_response,response,awb_number}', ''),
      nullif(new.raw_order #>> '{logistics_tracking_response,awb_number}', ''),
      nullif(new.raw_order #>> '{package_list,0,tracking_number}', ''),
      nullif(new.raw_order #>> '{package_list,0,tracking_no}', '')
    );

    if v_tracking is not null then
      v_tracking_lower := lower(trim(v_tracking));
      if upper(v_tracking) like 'OFG%'
         or v_tracking ~ '^1200[0-9]{6,}$'
         or v_tracking ~ '^[0-9]{16,}$'
         or v_tracking_lower in (
           lower(coalesce(new.external_order_id, '')),
           lower(coalesce(new.order_sn, '')),
           lower(coalesce(new.order_id, '')),
           lower(coalesce(new.remote_order_id, '')),
           lower(coalesce(new.package_id, '')),
           lower(coalesce(new.remote_package_id, '')),
           lower(coalesce(new.label_code, ''))
         ) then
        v_tracking := null;
      end if;
    end if;

    if new.tracking_number is not null and (
      upper(new.tracking_number) like 'OFG%'
      or new.tracking_number ~ '^1200[0-9]{6,}$'
      or new.tracking_number ~ '^[0-9]{16,}$'
      or lower(new.tracking_number) in (
        lower(coalesce(new.external_order_id, '')),
        lower(coalesce(new.order_sn, '')),
        lower(coalesce(new.order_id, '')),
        lower(coalesce(new.remote_order_id, '')),
        lower(coalesce(new.package_id, '')),
        lower(coalesce(new.remote_package_id, ''))
      )
    ) then
      new.tracking_number := null;
    end if;

    if new.label_code is not null and (
      upper(new.label_code) like 'OFG%'
      or new.label_code ~ '^1200[0-9]{6,}$'
      or new.label_code ~ '^[0-9]{16,}$'
      or lower(new.label_code) in (
        lower(coalesce(new.external_order_id, '')),
        lower(coalesce(new.order_sn, '')),
        lower(coalesce(new.order_id, '')),
        lower(coalesce(new.remote_order_id, '')),
        lower(coalesce(new.package_id, '')),
        lower(coalesce(new.remote_package_id, ''))
      )
    ) then
      new.label_code := null;
    end if;

    if v_tracking is not null then
      if new.tracking_number is null or new.tracking_number = '' then
        new.tracking_number := v_tracking;
      end if;
      if new.label_code is null or new.label_code = '' then
        new.label_code := v_tracking;
      end if;
    end if;
  end if;

  return new;
end;
$function$;
