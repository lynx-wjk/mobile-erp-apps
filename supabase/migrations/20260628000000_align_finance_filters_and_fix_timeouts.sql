-- Migration: Align finance filters, fix snapshot timeouts, disable 'all' fallback in line details,
-- add marketplace map fallback for unique seller SKU mappings, and bypass return item stock-in verification in legacy mode.

-- 1. Redefine finance_customer_dashboard_snapshot_v24_6_82o_b20260608 with tenant_id optimizations
CREATE OR REPLACE FUNCTION public.finance_customer_dashboard_snapshot_v24_6_82o_b20260608(
  p_start date DEFAULT NULL::date,
  p_end date DEFAULT NULL::date,
  p_marketplace text DEFAULT NULL::text,
  p_account_id uuid DEFAULT NULL::uuid
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tenant_id uuid := public.app_current_tenant_id_or_default();
  v_start date := coalesce(p_start, (now() at time zone 'Asia/Jakarta')::date);
  v_end date := coalesce(p_end, (now() at time zone 'Asia/Jakarta')::date);
  v_marketplace text := nullif(nullif(lower(trim(coalesce(p_marketplace, ''))), ''), 'all');
  v_account text := nullif(p_account_id::text, '');
  v_daily jsonb := '[]'::jsonb;
  v_marketplaces jsonb := '[]'::jsonb;
  v_by_sku jsonb := '[]'::jsonb;
  v_abnormals jsonb := '[]'::jsonb;
  v_valid_orders numeric := 0;
  v_valid_gross numeric := 0;
  v_valid_paid numeric := 0;
  v_order_sources numeric := 0;
  v_payout numeric := 0;
  v_payout_positive numeric := 0;
  v_negative_count numeric := 0;
  v_negative_abs numeric := 0;
  v_negative_signed numeric := 0;
  v_finance_sources numeric := 0;
  v_order_hpp numeric := 0;
  v_hpp numeric := 0;
  v_unpaid_hpp numeric := 0;
  v_expense numeric := 0;
  v_profit numeric := 0;
  v_margin numeric := 0;
  v_source_count numeric := 0;
  v_summary jsonb;
begin
  if v_end < v_start then
    v_end := v_start;
  end if;

  if v_tenant_id is null and p_account_id is not null then
    select tenant_id into v_tenant_id
    from public.marketplace_accounts
    where marketplace_account_id = p_account_id;
  end if;

  -- Omzet source of truth: order valid yang customer bayar / sedang proses valid.
  with unique_orders as (
    select
      coalesce(nullif(o.order_id, ''), nullif(o.external_order_id, ''), nullif(o.order_sn, ''), o.marketplace_order_id::text) as order_key,
      max(o.marketplace_order_id::text) as marketplace_order_id,
      max(coalesce(o.order_id, o.external_order_id, o.order_sn, '')) as order_no,
      min((coalesce(o.paid_at, o.order_created_at, o.created_at) at time zone 'Asia/Jakarta')::date) as order_date,
      max(o.marketplace) as marketplace,
      max(o.marketplace_account_id::text) as account_id,
      max(greatest(coalesce(o.gross_amount, 0), coalesce(o.paid_amount, 0))) as omzet_value,
      max(coalesce(o.paid_amount, 0)) as paid_value
    from public.marketplace_orders o
    where o.tenant_id = v_tenant_id
      and coalesce(o.paid_at, o.order_created_at, o.created_at) >= (v_start - interval '2 days')
      and coalesce(o.paid_at, o.order_created_at, o.created_at) <= (v_end + interval '2 days')
      and coalesce(o.gross_amount, o.paid_amount, 0) > 0
      and not (lower(coalesce(o.order_status, '')) ~ '(cancel|canceled|cancelled|batal|return|returned|refund|refunded|unpaid|failed|reject)')
      and not (lower(coalesce(o.payment_status, '')) ~ '(unpaid|failed|cancel|canceled|cancelled|refund|refunded)')
    group by coalesce(nullif(o.order_id, ''), nullif(o.external_order_id, ''), nullif(o.order_sn, ''), o.marketplace_order_id::text)
  ), filtered_orders as (
    select *
    from unique_orders
    where order_date >= v_start
      and order_date <= v_end
      and (v_marketplace is null or lower(marketplace) = v_marketplace)
      and (v_account is null or account_id = v_account)
  ), daily_rows as (
    select order_date, count(*)::numeric as orders_count, coalesce(sum(omzet_value),0)::numeric as omzet_total
    from filtered_orders
    group by order_date
  ), market_rows as (
    select marketplace, count(*)::numeric as orders_count, coalesce(sum(omzet_value),0)::numeric as omzet_total
    from filtered_orders
    group by marketplace
  )
  select
    coalesce((select count(*)::numeric from filtered_orders),0),
    coalesce((select sum(omzet_value)::numeric from filtered_orders),0),
    coalesce((select sum(paid_value)::numeric from filtered_orders),0),
    coalesce((select count(distinct account_id)::numeric from filtered_orders where nullif(account_id,'') is not null),0),
    coalesce((select jsonb_agg(jsonb_build_object(
      'date', order_date::text,
      'order_count', orders_count,
      'orders_count', orders_count,
      'finance_order_count', orders_count,
      'finance_orders_count', orders_count,
      'omzet_total', omzet_total,
      'gross_sales', omzet_total,
      'gross_total', omzet_total,
      'gross_amount', omzet_total,
      'payout_total', 0,
      'hpp_total', 0
    ) order by order_date) from daily_rows), '[]'::jsonb),
    coalesce((select jsonb_agg(jsonb_build_object(
      'marketplace', marketplace,
      'marketplace_label', marketplace,
      'order_count', orders_count,
      'orders_count', orders_count,
      'finance_order_count', orders_count,
      'finance_orders_count', orders_count,
      'gross_sales', omzet_total,
      'gross_total', omzet_total,
      'omzet_total', omzet_total,
      'payout_total', 0,
      'hpp_total', 0,
      'net_profit', 0,
      'margin_percent', 0
    ) order by marketplace) from market_rows), '[]'::jsonb)
  into v_valid_orders, v_valid_gross, v_valid_paid, v_order_sources, v_daily, v_marketplaces;

  -- Payout source of truth: settlement raw finance berdasarkan period_start.
  with filtered_finance as (
    select
      coalesce(f.order_id, '') as order_no,
      f.marketplace_account_id::text as account_id,
      lower(f.marketplace) as marketplace,
      f.period_start,
      coalesce(f.payout_amount, f.received_amount, f.net_settlement, 0) as payout_amount
    from public.marketplace_finance_reports f
    where f.tenant_id = v_tenant_id
      and f.period_start >= v_start
      and f.period_start <= v_end
      and (v_marketplace is null or lower(f.marketplace) = v_marketplace)
      and (v_account is null or f.marketplace_account_id::text = v_account)
  )
  select
    coalesce(sum(payout_amount), 0),
    coalesce(sum(payout_amount) filter (where payout_amount > 0), 0),
    coalesce(count(*) filter (where payout_amount < 0), 0)::numeric,
    coalesce(sum(abs(payout_amount)) filter (where payout_amount < 0), 0),
    coalesce(sum(payout_amount) filter (where payout_amount < 0), 0),
    coalesce(count(distinct account_id) filter (where nullif(account_id,'') is not null), 0)::numeric
  into v_payout, v_payout_positive, v_negative_count, v_negative_abs, v_negative_signed, v_finance_sources
  from filtered_finance;

  -- Page kecil untuk tab Abnormal. Summary tetap aggregate, detail tetap dipaginasi dari Flutter/RPC abnormal.
  with filtered_abnormals as (
    select
      f.finance_report_id::text as finance_report_id,
      coalesce(f.order_id, '') as order_no,
      f.marketplace_order_id::text as marketplace_order_id,
      f.marketplace_account_id::text as account_id,
      lower(f.marketplace) as marketplace,
      f.period_start,
      coalesce(f.gross_amount, f.gross_sales, 0) as gross_amount,
      coalesce(f.payout_amount, f.received_amount, f.net_settlement, 0) as payout_amount,
      coalesce(f.total_hpp, 0) as hpp_amount
    from public.marketplace_finance_reports f
    where f.tenant_id = v_tenant_id
      and f.period_start >= v_start
      and f.period_start <= v_end
      and coalesce(f.payout_amount, f.received_amount, f.net_settlement, 0) < 0
      and (v_marketplace is null or lower(f.marketplace) = v_marketplace)
      and (v_account is null or f.marketplace_account_id::text = v_account)
    order by f.period_start desc, abs(coalesce(f.payout_amount, f.received_amount, f.net_settlement, 0)) desc
    limit 20
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'status', 'NEGATIVE_PAYOUT',
    'abnormal_status', 'NEGATIVE_PAYOUT',
    'payout_status', 'NEGATIVE_PAYOUT',
    'finance_status', 'NEGATIVE_PAYOUT',
    'message', 'Payout minus berdasarkan raw finance period_start',
    'title', coalesce(nullif(order_no,''), nullif(marketplace_order_id,''), '-'),
    'order_id', coalesce(nullif(order_no,''), nullif(marketplace_order_id,''), '-'),
    'order_sn', coalesce(nullif(order_no,''), nullif(marketplace_order_id,''), '-'),
    'external_order_id', coalesce(nullif(order_no,''), nullif(marketplace_order_id,''), '-'),
    'marketplace_order_id', marketplace_order_id,
    'marketplace_account_id', account_id,
    'marketplace', marketplace,
    'order_date', period_start::text,
    'gross', gross_amount,
    'gross_amount', gross_amount,
    'payout', payout_amount,
    'payout_amount', payout_amount,
    'payout_total', payout_amount,
    'difference_amount', payout_amount,
    'hpp', hpp_amount,
    'hpp_total', hpp_amount,
    'detail_order_count', 1,
    'order_details', jsonb_build_array(jsonb_build_object(
      'order_id', coalesce(nullif(order_no,''), nullif(marketplace_order_id,''), '-'),
      'order_date', period_start::text,
      'gross', gross_amount,
      'payout', payout_amount,
      'net_settlement', payout_amount,
      'received_amount', payout_amount,
      'finance_report_id', finance_report_id,
      'marketplace_order_id', marketplace_order_id
    ))
  ) order by period_start desc), '[]'::jsonb)
  into v_abnormals
  from filtered_abnormals;

  -- HPP estimasi dari item marketplace x HPP mapping. Dibungkus exception supaya summary tidak mati kalau struktur mapping beda.
  begin
    with orders_norm as (
      select
        coalesce(nullif(o.order_id, ''), nullif(o.external_order_id, ''), nullif(o.order_sn, ''), o.marketplace_order_id::text) as order_key,
        o.marketplace_account_id::text as account_id,
        lower(o.marketplace) as marketplace,
        lower(o.order_status) as order_status,
        lower(o.payment_status) as payment_status,
        coalesce(o.paid_at, o.order_created_at, o.created_at) as order_time
      from public.marketplace_orders o
      where o.tenant_id = v_tenant_id
        and coalesce(o.paid_at, o.order_created_at, o.created_at) >= (v_start - interval '2 days')
        and coalesce(o.paid_at, o.order_created_at, o.created_at) <= (v_end + interval '2 days')
    ), valid_orders as (
      select *, (order_time at time zone 'Asia/Jakarta')::date as order_date
      from orders_norm
      where order_key is not null
        and order_time is not null
        and (order_time at time zone 'Asia/Jakarta')::date >= v_start
        and (order_time at time zone 'Asia/Jakarta')::date <= v_end
        and not (lower(coalesce(order_status, '')) ~ '(cancel|canceled|cancelled|batal|return|returned|refund|refunded|unpaid|failed|reject)')
        and not (lower(coalesce(payment_status, '')) ~ '(unpaid|failed|cancel|canceled|cancelled|refund|refunded)')
        and (v_marketplace is null or marketplace = v_marketplace)
        and (v_account is null or account_id = v_account)
    ), finance_reports_filtered as (
      select
        coalesce(f.order_id, '') as order_no,
        coalesce(f.payout_amount, f.received_amount, f.net_settlement, 0) as payout_amount
      from public.marketplace_finance_reports f
      where f.tenant_id = v_tenant_id
        and f.period_start >= v_start
        and f.period_start <= v_end
        and (v_marketplace is null or lower(f.marketplace) = v_marketplace)
        and (v_account is null or f.marketplace_account_id::text = v_account)
    ), order_payouts as (
      select order_no, sum(payout_amount) as payout_total
      from finance_reports_filtered
      group by order_no
    ), valid_orders_with_payout as (
      select vo.*, coalesce(op.payout_total, 0) as order_payout
      from valid_orders vo
      left join order_payouts op on op.order_no = vo.order_key
    ), item_norm as (
      select
        coalesce(nullif(i.external_order_id, ''), nullif(i.order_sn, ''), i.marketplace_order_id::text) as order_key,
        lower(i.marketplace) as marketplace,
        i.marketplace_account_id::text as account_id,
        coalesce(nullif(i.marketplace_sku_id, ''), nullif(i.marketplace_seller_sku, ''), nullif(i.seller_sku, ''), 'unknown') as sku_key,
        coalesce(nullif(i.local_sku, ''), nullif(i.seller_sku, ''), '-') as sku_label,
        coalesce(nullif(i.product_name, ''), '-') as product_name,
        coalesce(nullif(i.variant_name, ''), '-') as variant_name,
        greatest(coalesce(i.quantity, i.qty, 1), 1) as qty,
        coalesce(i.gross_amount, i.paid_amount, 0) as item_gross
      from public.marketplace_order_items i
      where i.tenant_id = v_tenant_id
        and i.created_at >= (v_start - interval '3 days')
        and i.created_at <= (v_end + interval '3 days')
    ), map_norm as (
      select distinct on (sku_key)
        sku_key,
        hpp,
        target_margin
      from (
        select
          coalesce(nullif(m.marketplace_sku_id, ''), nullif(m.marketplace_seller_sku, ''), nullif(m.local_sku, ''), 'unknown') as sku_key,
          coalesce(m.hpp, 0) as hpp,
          coalesce(m.target_margin_percent, m.target_margin, 0) as target_margin,
          coalesce(m.updated_at, m.created_at) as sort_key
        from public.marketplace_variant_hpp_mappings m
        where m.tenant_id = v_tenant_id
      ) x
      where sku_key <> 'unknown' and hpp > 0
      order by sku_key, sort_key desc nulls last
    ), items_enriched as (
      select
        i.order_key,
        i.sku_key,
        i.sku_label,
        i.product_name,
        i.variant_name,
        i.qty,
        i.item_gross,
        o.order_payout,
        sum(i.item_gross) over (partition by o.order_key) as gross_order_scope,
        sum(i.qty) over (partition by o.order_key) as qty_order_scope
      from item_norm i
      join valid_orders_with_payout o on o.order_key = i.order_key
    ), items_allocated as (
      select
        ie.*,
        case
          when coalesce(ie.order_payout, 0) = 0 then 0
          when coalesce(ie.gross_order_scope, 0) > 0 and ie.item_gross > 0 then ie.order_payout * ie.item_gross / ie.gross_order_scope
          when coalesce(ie.qty_order_scope, 0) > 0 then ie.order_payout * ie.qty / ie.qty_order_scope
          else ie.order_payout
        end as payout_allocated
      from items_enriched ie
    ), joined as (
      select
        coalesce(nullif(a.sku_key, ''), 'unknown') as sku_key,
        max(a.sku_label) as sku_label,
        max(a.product_name) as product_name,
        max(a.variant_name) as variant_name,
        sum(a.qty) as qty_total,
        sum(case when a.order_payout > 0 then a.qty else 0 end) as paid_qty,
        sum(case when a.order_payout <= 0 then a.qty else 0 end) as unpaid_qty,
        coalesce(sum(nullif(a.item_gross, 0)), 0) as gross_total,
        coalesce(sum(a.payout_allocated), 0) as payout_total,
        max(coalesce(m.hpp, 0)) as hpp_per_item,
        max(coalesce(m.target_margin, 0)) as target_margin
      from items_allocated a
      left join map_norm m on m.sku_key = a.sku_key
      group by coalesce(nullif(a.sku_key, ''), 'unknown')
    )
    select
      coalesce(sum(qty_total * hpp_per_item), 0),
      coalesce(sum(paid_qty * hpp_per_item), 0),
      coalesce(sum(unpaid_qty * hpp_per_item), 0),
      coalesce(jsonb_agg(jsonb_build_object(
        'local_sku', sku_label,
        'marketplace_sku', sku_key,
        'sku', sku_label,
        'product_name', product_name,
        'variant_name', variant_name,
        'qty', qty_total,
        'quantity', qty_total,
        'paid_qty', paid_qty,
        'settled_qty', paid_qty,
        'unpaid_qty', unpaid_qty,
        'pending_payout_qty_total', unpaid_qty,
        'qty_unpaid', unpaid_qty,
        'gross_total', gross_total,
        'gross_amount', gross_total,
        'hpp', hpp_per_item,
        'hpp_per_item', hpp_per_item,
        'hpp_total', qty_total * hpp_per_item,
        'total_hpp', qty_total * hpp_per_item,
        'target_margin_percent', target_margin,
        'payout_total', payout_total,
        'payout_amount', payout_total,
        'received_amount', payout_total,
        'gross_per_item', case when qty_total > 0 then gross_total / qty_total else gross_total end,
        'positive_payout_per_item', case when paid_qty > 0 then payout_total / paid_qty else null end,
        'payout_per_item_paid', case when paid_qty > 0 then payout_total / paid_qty else null end,
        'payout_per_item', case when paid_qty > 0 then payout_total / paid_qty else null end,
        'margin_settled_percent', case
          when payout_total > 0 then
            case
              when ((payout_total - (paid_qty * hpp_per_item)) / payout_total) * 100 between -100.0 and 100.0 then
                ((payout_total - (paid_qty * hpp_per_item)) / payout_total) * 100
              else null
            end
          else null
        end,
        'margin_estimated_percent', case
          when gross_total > 0 then
            case
              when ((gross_total - (qty_total * hpp_per_item)) / gross_total) * 100 between -100.0 and 100.0 then
                ((gross_total - (qty_total * hpp_per_item)) / gross_total) * 100
              else null
            end
          else null
        end,
        'net_margin_percent', case
          when payout_total > 0 then
            case
              when ((payout_total - (paid_qty * hpp_per_item)) / payout_total) * 100 between -100.0 and 100.0 then
                ((payout_total - (paid_qty * hpp_per_item)) / payout_total) * 100
              else null
            end
          else
            case
              when gross_total > 0 then
                case
                  when ((gross_total - (qty_total * hpp_per_item)) / gross_total) * 100 between -100.0 and 100.0 then
                    ((gross_total - (qty_total * hpp_per_item)) / gross_total) * 100
                  else null
                end
              else null
            end
        end,
        'margin_percent', case
          when payout_total > 0 then
            case
              when ((payout_total - (paid_qty * hpp_per_item)) / payout_total) * 100 between -100.0 and 100.0 then
                ((payout_total - (paid_qty * hpp_per_item)) / payout_total) * 100
              else null
            end
          else
            case
              when gross_total > 0 then
                case
                  when ((gross_total - (qty_total * hpp_per_item)) / gross_total) * 100 between -100.0 and 100.0 then
                    ((gross_total - (qty_total * hpp_per_item)) / gross_total) * 100
                  else null
                end
              else null
            end
        end
      ) order by gross_total desc nulls last), '[]'::jsonb)
    into v_order_hpp, v_hpp, v_unpaid_hpp, v_by_sku
    from joined
    where sku_key <> 'unknown';
  exception when others then
    v_order_hpp := 0;
    v_hpp := 0;
    v_unpaid_hpp := 0;
    v_by_sku := '[]'::jsonb;
  end;

  -- Kalau payout belum masuk, HPP masuk Est. HPP Belum Payout, bukan HPP settled.
  -- HPP settled dan Est HPP Belum Payout sudah dikalkulasi dengan benar di atas berdasarkan orders dengan payout.
  v_expense := 0;
  v_profit := case when v_payout = 0 then 0 else v_payout - v_hpp - v_expense end;
  v_margin := case when v_payout > 0 then (v_profit / v_payout) * 100 else 0 end;
  v_source_count := greatest(v_order_sources, v_finance_sources, 1);

  v_summary := jsonb_build_object(
    'version', 'v24_6_82o_overwrite_local_cache_live_source_v23_old_param_bridge_2026_06_07',
    'policy', 'local_cache_first_server_refresh_order_valid_paid_payout_raw_finance_hpp_mapping_safe_date_reload',
    'period_start', v_start,
    'period_end', v_end,
    'gross_sales', v_valid_gross,
    'gross_total', v_valid_gross,
    'gross_amount', v_valid_gross,
    'omzet', v_valid_gross,
    'omzet_total', v_valid_gross,
    'valid_paid_gross_sum', v_valid_gross,
    'valid_paid_paid_sum', v_valid_paid,
    'payout_total', v_payout,
    'payout_amount', v_payout,
    'received_amount', v_payout,
    'net_received', v_payout,
    'net_settlement', v_payout,
    'payout_positive_total', v_payout_positive,
    'hpp_total', v_hpp,
    'total_hpp', v_hpp,
    'paid_hpp_total', v_hpp,
    'settled_hpp_total', v_hpp,
    'unpaid_estimated_hpp_total', v_unpaid_hpp,
    'pending_hpp_total', v_unpaid_hpp,
    'estimated_unpaid_hpp_total', v_unpaid_hpp,
    'expense_total', v_expense,
    'operational_cost_total', v_expense,
    'net_profit', v_profit,
    'profit', v_profit,
    'margin_percent', v_margin,
    'finance_order_count', v_valid_orders,
    'finance_orders_count', v_valid_orders,
    'orders_count', v_valid_orders,
    'order_count', v_valid_orders,
    'source_count', v_source_count,
    'marketplace_count', v_source_count,
    'negative_payout_count', v_negative_count,
    'abnormal_count', v_negative_count,
    'payout_minus_total', v_negative_signed,
    'negative_payout_total', v_negative_signed,
    'minus_payout_total', v_negative_signed,
    'payout_minus_total_abs', v_negative_abs,
    'negative_payout_total_abs', v_negative_abs,
    'minus_payout_total_abs', v_negative_abs
  );

  return jsonb_build_object(
    'ok', true,
    'version', 'v24_6_82o_overwrite_local_cache_live_source_v23_old_param_bridge_2026_06_07',
    'summary', v_summary,
    'daily', v_daily,
    'by_date', v_daily,
    'by_marketplace', v_marketplaces,
    'marketplaces', v_marketplaces,
    'sources', v_marketplaces,
    'by_sku', v_by_sku,
    'sku', v_by_sku,
    'cash_flow', '[]'::jsonb,
    'expenses', '[]'::jsonb,
    'profit_loss', '[]'::jsonb,
    'approved_purchases', '[]'::jsonb,
    'abnormal_aggregates', jsonb_build_object(
      'total', v_negative_count,
      'abnormal_count', v_negative_count,
      'negative_payout_count', v_negative_count,
      'negative_payout_total', v_negative_signed,
      'negative_payout_total_abs', v_negative_abs,
      'payout_minus_total', v_negative_signed,
      'payout_minus_total_abs', v_negative_abs,
      'minus_payout_total', v_negative_signed,
      'minus_payout_total_abs', v_negative_abs
    ),
    'abnormals', v_abnormals,
    'accounts', '[]'::jsonb
  );
end;
$function$;

-- 2. Redefine finance_sku_order_line_details_core_delegate_20260625 without 'all' fallback
CREATE OR REPLACE FUNCTION public.finance_sku_order_line_details_core_delegate_20260625(
  p_start date DEFAULT NULL::date,
  p_end date DEFAULT NULL::date,
  p_marketplace text DEFAULT NULL::text,
  p_account_id uuid DEFAULT NULL::uuid,
  p_marketplace_sku text DEFAULT NULL::text,
  p_local_sku text DEFAULT NULL::text,
  p_search text DEFAULT NULL::text,
  p_payout_filter text DEFAULT 'all'::text,
  p_page integer DEFAULT 1,
  p_page_size integer DEFAULT 25
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 AS $function$
 declare
   v_marketplace_sku text := nullif(trim(coalesce(p_marketplace_sku,'')), '');
   v_local_sku text := nullif(trim(coalesce(p_local_sku,'')), '');
   v_search text := nullif(trim(coalesce(p_search,'')), '');
   v_filter text := lower(trim(coalesce(p_payout_filter,'all')));
   v_page_size integer := least(greatest(coalesce(p_page_size,25),1),25);
 
   j jsonb;
   rows jsonb := '[]'::jsonb;
   total_count integer := 0;
 begin
   if lower(coalesce(v_local_sku,'')) in ('unmapped','-', 'null', 'none', 'tidak mapping', 'belum mapping') then
     v_local_sku := null;
   end if;
 
   if lower(coalesce(v_marketplace_sku,'')) in ('unmapped','-', 'null', 'none') then
     v_marketplace_sku := null;
   end if;
 
   if v_search is not null then
     v_search := regexp_replace(v_search, '(^|\s)unmapped(\s|$)', ' ', 'gi');
     v_search := nullif(trim(regexp_replace(v_search, '\s+', ' ', 'g')), '');
   end if;
 
   /*
     First attempt: pakai parameter UI, tapi local_sku unmapped sudah dinull-kan.
   */
   j := public.finance_sku_order_details(
     p_start,
     p_end,
     p_marketplace,
     p_account_id,
     v_marketplace_sku,
     v_local_sku,
     v_search,
     p_payout_filter,
     p_page,
     v_page_size
   );
 
   rows := coalesce(j->'rows','[]'::jsonb);
   total_count := coalesce(nullif(j->>'total_count','')::integer, 0);
 
   /*
     UI sering kirim p_payout_filter='paid', tapi TikTok order detail settlement belum match penuh.
     Disable fallback to 'all' to respect explicit layout filters.
   */
   -- IF coalesce(jsonb_array_length(rows),0) = 0 and v_filter <> 'all' THEN
   --   j := public.finance_sku_order_details(
   --     p_start,
   --     p_end,
   --     p_marketplace,
   --     p_account_id,
   --     v_marketplace_sku,
   --     v_local_sku,
   --     v_search,
   --     'all',
   --     p_page,
   --     v_page_size
   --   );
   --
   --   rows := coalesce(j->'rows','[]'::jsonb);
   --   total_count := coalesce(nullif(j->>'total_count','')::integer, 0);
   -- END IF;
 
   /*
     Kalau masih kosong dan UI mengirim search gabungan seperti:
     "unmapped 173063... Happy About It ..."
     pakai search saja, tanpa sku/local_sku.
   */
   if coalesce(jsonb_array_length(rows),0) = 0 and v_search is not null then
     j := public.finance_sku_order_details(
       p_start,
       p_end,
       p_marketplace,
       p_account_id,
       null,
       null,
       v_search,
       'all',
       p_page,
       v_page_size
     );
 
     rows := coalesce(j->'rows','[]'::jsonb);
     total_count := coalesce(nullif(j->>'total_count','')::integer, 0);
   end if;
 
   return jsonb_build_object(
     'rows', rows,
     'data', rows,
     'items', rows,
     'page', greatest(coalesce(p_page,1),1),
     'page_size', v_page_size,
     'total', total_count,
     'count', total_count,
     'total_count', total_count,
     'total_pages', greatest(ceil(coalesce(total_count,0)::numeric / v_page_size)::integer, 1),
     'has_more', greatest(coalesce(p_page,1),1) < greatest(ceil(coalesce(total_count,0)::numeric / v_page_size)::integer, 1),
     'source', 'finance_sku_order_line_details_delegate_to_order_details_20260625',
     'delegate_source', coalesce(j->>'source',''),
     'requested_payout_filter', p_payout_filter
   );
 end;
 $function$;

-- 3. Redefine finance_sku_order_details_core_20260625 with refund/return filters and payout checks
CREATE OR REPLACE FUNCTION public.finance_sku_order_details_core_20260625(
  p_start date DEFAULT NULL::date,
  p_end date DEFAULT NULL::date,
  p_marketplace text DEFAULT NULL::text,
  p_account_id uuid DEFAULT NULL::uuid,
  p_marketplace_sku text DEFAULT NULL::text,
  p_local_sku text DEFAULT NULL::text,
  p_search text DEFAULT NULL::text,
  p_payout_filter text DEFAULT 'all'::text,
  p_page integer DEFAULT 1,
  p_page_size integer DEFAULT 20
)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_tenant_id uuid;
  v_role text;
  v_start date := coalesce(p_start, date_trunc('month', timezone('Asia/Jakarta', now()))::date);
  v_end date := coalesce(p_end, timezone('Asia/Jakarta', now())::date);
  v_start_ts timestamptz;
  v_end_ts timestamptz;
  v_marketplace text;
  v_account_id uuid := p_account_id;
  v_marketplace_sku text := lower(nullif(trim(coalesce(p_marketplace_sku, '')), ''));
  v_local_sku text := lower(nullif(trim(coalesce(p_local_sku, '')), ''));
  v_search text := lower(nullif(trim(coalesce(p_search, '')), ''));
  v_filter text := lower(trim(coalesce(p_payout_filter, 'all')));
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_page_size integer := least(greatest(coalesce(p_page_size, 20), 1), 25);
  v_offset integer;
  v_detail_mode boolean;
begin
  -- Set local work_mem to 64MB to keep sorts in-memory (e.g. for partition window functions)
  perform set_config('work_mem', '64MB', true);

  select
    coalesce(
      case
        when (v_claims->>'tenant_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        then (v_claims->>'tenant_id')::uuid
        else null::uuid
      end,
      (select u.tenant_id from public.users u where u.user_id = auth.uid() limit 1)
    ),
    coalesce(nullif(v_claims->>'role', ''), '')
  into v_tenant_id, v_role;

  v_start_ts := (v_start::timestamp at time zone 'Asia/Jakarta');
  v_end_ts := ((v_end + 1)::timestamp at time zone 'Asia/Jakarta');
  v_offset := (v_page - 1) * v_page_size;
  v_filter := case
    when v_filter in ('settled', 'released', 'release', 'payout', 'paid payout', 'sudah payout') then 'paid'
    when v_filter in ('pending', 'belum payout', 'no payout', 'missing payout') then 'unpaid'
    when v_filter = '' then 'all'
    else v_filter
  end;
  v_marketplace := case
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
    else null
  end;
  v_detail_mode := v_marketplace_sku is not null
    or v_local_sku is not null
    or v_search is not null;

  if v_role <> 'service_role' and v_tenant_id is null then
    return jsonb_build_object(
      'rows', '[]'::jsonb,
      'page', v_page,
      'page_size', v_page_size,
      'total', 0,
      'total_count', 0,
      'total_pages', 1,
      'source', 'finance_sku_order_details_fast_mtd'
    );
  end if;

  if v_detail_mode then
    return (
      with order_base as (
        select *
        from (
          select
            o.marketplace_order_id,
            o.tenant_id,
            o.marketplace_account_id,
            o.order_created_at,
            timezone('Asia/Jakarta', o.order_created_at)::date as order_date,
            coalesce(nullif(o.order_id::text, ''), nullif(o.order_sn::text, ''), nullif(o.external_order_id::text, ''), o.marketplace_order_id::text) as order_key,
            coalesce(nullif(o.order_sn::text, ''), nullif(o.external_order_id::text, ''), nullif(o.order_id::text, '')) as order_sn,
            coalesce(nullif(o.tracking_number, ''), nullif(o.label_code, ''), nullif(o.package_id, '')) as tracking_number,
            lower(concat_ws(' ', o.order_status, o.status, o.payment_status, o.fulfillment_status, o.order_status_label)) as status_text,
            coalesce(nullif(o.gross_amount, 0), nullif(o.total_amount, 0), nullif(o.paid_amount, 0), 0)::numeric as order_gross,
            case
              when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
              when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
              else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
            end as marketplace_group
          from public.marketplace_orders o
          where o.order_created_at >= v_start_ts
            and o.order_created_at < v_end_ts
            and (v_role = 'service_role' or o.tenant_id = v_tenant_id)
            and (v_account_id is null or o.marketplace_account_id = v_account_id)
        ) o
        where (v_marketplace is null or v_marketplace = '' or o.marketplace_group = public._finance_marketplace_norm_20260624(v_marketplace))
          and o.status_text not like '%cancel%'
          and o.status_text not like '%batal%'
          and o.status_text not like '%unpaid%'
          and o.status_text not like '%in_cancel%'
          and o.status_text not like '%refund%'
          and o.status_text not like '%return%'
      ),
      finance_by_order as (
        select
          ob.marketplace_order_id,
          coalesce(sum(coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)), 0)::numeric as payout,
          coalesce(sum(coalesce(fr.gross_amount, fr.gross_sales, 0)), 0)::numeric as finance_gross
        from order_base ob
        join 
(
  select
    tenant_id,
    marketplace_account_id,
    marketplace,
    order_id,
    marketplace_order_id,
    gross_amount,
    gross_sales,
    payout_amount,
    received_amount,
    net_settlement
  from public.marketplace_finance_reports
  where lower(coalesce(marketplace, '')) not in ('tiktok', 'tiktok_shop')

  union all

  select
    tenant_id,
    marketplace_account_id,
    marketplace,
    coalesce(nullif(order_id, ''), nullif(order_sn, ''), nullif(external_order_id, '')) as order_id,
    marketplace_order_id,
    gross_amount,
    gross_amount as gross_sales,
    received_amount as payout_amount,
    received_amount,
    net_settlement
  from public.marketplace_finance_items
  where lower(coalesce(marketplace, '')) in ('tiktok', 'tiktok_shop')
) fr
          on fr.tenant_id = ob.tenant_id
         and fr.marketplace_account_id = ob.marketplace_account_id
         and fr.order_id = ob.order_key
        group by ob.marketplace_order_id
      ),
      line_base as (
        select
          ob.*,
          oi.marketplace_order_item_id,
          coalesce(nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, '')) as marketplace_sku_id,
          coalesce(nullif(oi.marketplace_sku, ''), nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, '')) as marketplace_sku,
          coalesce(nullif(oi.marketplace_seller_sku, ''), nullif(oi.seller_sku, '')) as marketplace_seller_sku,
          coalesce(nullif(oi.local_sku, ''), nullif(oi.mapped_local_sku, '')) as local_sku,
          coalesce(nullif(oi.marketplace_product_name, ''), nullif(oi.product_name, ''), nullif(oi.local_product_name, '')) as product_name,
          coalesce(nullif(oi.marketplace_variant_name, ''), nullif(oi.variant_name, ''), nullif(oi.variation_name, '')) as variant_name,
          greatest(coalesce(nullif(oi.qty, 0), nullif(oi.quantity, 0), 1), 1)::numeric as qty,
          coalesce(
            nullif(oi.gross_amount, 0),
            nullif(oi.paid_amount, 0),
            nullif(oi.unit_gross_amount, 0) * greatest(coalesce(nullif(oi.qty, 0), nullif(oi.quantity, 0), 1), 1),
            0
          )::numeric as line_gross
        from order_base ob
        join public.marketplace_order_items oi
          on oi.tenant_id = ob.tenant_id
         and oi.marketplace_order_id = ob.marketplace_order_id
        where (v_marketplace_sku is null or v_marketplace_sku in (
            lower(coalesce(oi.marketplace_sku_id, '')),
            lower(coalesce(oi.marketplace_sku, '')),
            lower(coalesce(oi.remote_sku_id, '')),
            lower(coalesce(oi.marketplace_seller_sku, '')),
            lower(coalesce(oi.seller_sku, ''))
          ))
          and (v_local_sku is null or v_local_sku = lower(coalesce(oi.local_sku, oi.mapped_local_sku, '')))
          and (v_search is null or lower(concat_ws(' ', ob.order_key, ob.order_sn, ob.tracking_number, oi.marketplace_sku_id, oi.marketplace_sku, oi.marketplace_seller_sku, oi.seller_sku, oi.local_sku, oi.mapped_local_sku, oi.marketplace_product_name, oi.product_name, oi.marketplace_variant_name, oi.variant_name)) like '%' || v_search || '%')
      ),
      line_calc as (
        select lb.*, sum(lb.line_gross) over (partition by lb.marketplace_order_id) as order_line_gross
        from line_base lb
      ),
      enriched_base as (
        select
          lc.*,
          coalesce(f.payout, 0)::numeric as order_payout,
          (coalesce(f.payout, 0) <> 0) as has_payout
        from line_calc lc
        left join finance_by_order f on f.marketplace_order_id = lc.marketplace_order_id
      ),
      filtered as (
        select *
        from enriched_base
        where (v_filter = 'all' or (v_filter = 'paid' and has_payout) or (v_filter = 'unpaid' and not has_payout))
      ),
      counted as (
        select filtered.*, count(*) over ()::integer as total_count
        from filtered
      ),
      paged as (
        select *
        from counted
        order by order_created_at desc, order_key
        offset v_offset
        limit v_page_size
      ),
      hpp_sku as (
        select tenant_id, marketplace_account_id, lower(nullif(marketplace_sku_id, '')) as marketplace_sku_id,
               max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
               max(coalesce(target_margin_percent, target_margin, 0))::numeric as target_margin
        from public.marketplace_variant_hpp_mappings
        where coalesce(is_active, true) is true and nullif(marketplace_sku_id, '') is not null
          and (v_role = 'service_role' or tenant_id = v_tenant_id)
        group by tenant_id, marketplace_account_id, lower(nullif(marketplace_sku_id, ''))
      ),
      hpp_seller as (
        select tenant_id, marketplace_account_id, lower(nullif(marketplace_seller_sku, '')) as marketplace_seller_sku,
               max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
               max(coalesce(target_margin_percent, target_margin, 0))::numeric as target_margin
        from public.marketplace_variant_hpp_mappings
        where coalesce(is_active, true) is true and nullif(marketplace_seller_sku, '') is not null
          and (v_role = 'service_role' or tenant_id = v_tenant_id)
        group by tenant_id, marketplace_account_id, lower(nullif(marketplace_seller_sku, ''))
      ),
      hpp_local as (
        select tenant_id, marketplace_account_id, lower(nullif(local_sku, '')) as local_sku,
               max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
               max(coalesce(target_margin_percent, target_margin, 0))::numeric as target_margin
        from public.marketplace_variant_hpp_mappings
        where coalesce(is_active, true) is true and nullif(local_sku, '') is not null
          and (v_role = 'service_role' or tenant_id = v_tenant_id)
        group by tenant_id, marketplace_account_id, lower(nullif(local_sku, ''))
      ),
      paged_enriched as (
        select
          p.*,
          coalesce(hs.hpp, hsel.hpp, hl.hpp, 0)::numeric as unit_hpp,
          coalesce(hs.target_margin, hsel.target_margin, hl.target_margin, 0)::numeric as target_margin
        from paged p
        left join hpp_sku hs on hs.tenant_id = p.tenant_id and hs.marketplace_account_id = p.marketplace_account_id and hs.marketplace_sku_id = lower(nullif(p.marketplace_sku_id, ''))
        left join hpp_seller hsel on hsel.tenant_id = p.tenant_id and hsel.marketplace_account_id = p.marketplace_account_id and hsel.marketplace_seller_sku = lower(nullif(p.marketplace_seller_sku, ''))
        left join hpp_local hl on hl.tenant_id = p.tenant_id and hl.marketplace_account_id = p.marketplace_account_id and hl.local_sku = lower(nullif(p.local_sku, ''))
      )
      select jsonb_build_object(
        'rows', coalesce(jsonb_agg(jsonb_build_object(
          'source', 'finance_sku_order_details_fast_mtd_detail',
          'order', order_key,
          'order_id', order_key,
          'order_sn', order_sn,
          'marketplace_order_id', marketplace_order_id,
          'marketplace_order_item_id', marketplace_order_item_id,
          'resi', tracking_number,
          'tracking_number', tracking_number,
          'order_date', order_created_at,
          'order_created_at', order_created_at,
          'marketplace', marketplace_group,
          'marketplace_account_id', marketplace_account_id,
          'local_sku', coalesce(nullif(local_sku, ''), '-'),
          'sku', coalesce(nullif(local_sku, ''), nullif(marketplace_sku_id, ''), nullif(marketplace_seller_sku, ''), '-'),
          'marketplace_sku_id', marketplace_sku_id,
          'marketplace_sku', marketplace_sku,
          'marketplace_seller_sku', marketplace_seller_sku,
          'product_name', product_name,
          'variant_name', variant_name,
          'marketplace_variation_name', variant_name,
          'qty', qty,
          'quantity', qty,
          'gross', line_gross,
          'gross_amount', line_gross,
          'gross_total', line_gross,
          'gross_per_item', case when qty > 0 then line_gross / qty else 0 end,
          'payout', case when has_payout and order_line_gross > 0 then order_payout * (line_gross / order_line_gross) else 0 end,
          'payout_amount', case when has_payout and order_line_gross > 0 then order_payout * (line_gross / order_line_gross) else 0 end,
          'payout_per_item', case when has_payout and order_line_gross > 0 and qty > 0 then (order_payout * (line_gross / order_line_gross)) / qty else 0 end,
          'hpp', unit_hpp * qty,
          'hpp_total', unit_hpp * qty,
          'hpp_per_item', unit_hpp,
          'unit_hpp', unit_hpp,
          'hpp_status', case when unit_hpp > 0 then 'HPP mapping' else 'HPP belum mapping' end,
          'target_margin_percent', target_margin,
          'finance_status', case when has_payout then 'SETTLED' else 'PENDING_PAYOUT' end,
          'payout_status', case when has_payout then 'SETTLED' else 'PENDING_PAYOUT' end
        ) order by order_created_at desc, order_key), '[]'::jsonb),
        'page', v_page,
        'page_size', v_page_size,
        'total', coalesce(max(total_count), 0),
        'total_count', coalesce(max(total_count), 0),
        'total_pages', greatest(1, ceil(coalesce(max(total_count), 0)::numeric / v_page_size)::integer),
        'source', 'finance_sku_order_details_fast_mtd'
      )
      from paged_enriched
    );
  end if;

  return (
    with order_base as (
      select *
      from (
        select
          o.marketplace_order_id,
          o.tenant_id,
          o.marketplace_account_id,
          o.order_created_at,
          timezone('Asia/Jakarta', o.order_created_at)::date as order_date,
          coalesce(nullif(o.order_id::text, ''), nullif(o.order_sn::text, ''), nullif(o.external_order_id::text, ''), o.marketplace_order_id::text) as order_key,
          lower(concat_ws(' ', o.order_status, o.status, o.payment_status, o.fulfillment_status, o.order_status_label)) as status_text,
          case
            when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
            when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
            else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
          end as marketplace_group
        from public.marketplace_orders o
        where o.order_created_at >= v_start_ts
          and o.order_created_at < v_end_ts
          and (v_role = 'service_role' or o.tenant_id = v_tenant_id)
          and (v_account_id is null or o.marketplace_account_id = v_account_id)
      ) o
      where (v_marketplace is null or v_marketplace = '' or o.marketplace_group = public._finance_marketplace_norm_20260624(v_marketplace))
        and o.status_text not like '%cancel%'
        and o.status_text not like '%batal%'
        and o.status_text not like '%unpaid%'
        and o.status_text not like '%in_cancel%'
        and o.status_text not like '%refund%'
        and o.status_text not like '%return%'
    ),
    finance_by_order as (
      select
        ob.marketplace_order_id,
        coalesce(sum(coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)), 0)::numeric as payout
      from order_base ob
      join 
(
  select
    tenant_id,
    marketplace_account_id,
    marketplace,
    order_id,
    marketplace_order_id,
    gross_amount,
    gross_sales,
    payout_amount,
    received_amount,
    net_settlement
  from public.marketplace_finance_reports
  where lower(coalesce(marketplace, '')) not in ('tiktok', 'tiktok_shop')

  union all

  select
    tenant_id,
    marketplace_account_id,
    marketplace,
    coalesce(nullif(order_id, ''), nullif(order_sn, ''), nullif(external_order_id, '')) as order_id,
    marketplace_order_id,
    gross_amount,
    gross_amount as gross_sales,
    received_amount as payout_amount,
    received_amount,
    net_settlement
  from public.marketplace_finance_items
  where lower(coalesce(marketplace, '')) in ('tiktok', 'tiktok_shop')
) fr
        on fr.tenant_id = ob.tenant_id
       and fr.marketplace_account_id = ob.marketplace_account_id
       and fr.order_id = ob.order_key
      group by ob.marketplace_order_id
    ),
    line_base as (
      select
        ob.*,
        oi.marketplace_order_item_id,
        coalesce(nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, '')) as marketplace_sku_id,
        coalesce(nullif(oi.marketplace_sku, ''), nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, '')) as marketplace_sku,
        coalesce(nullif(oi.marketplace_seller_sku, ''), nullif(oi.seller_sku, '')) as marketplace_seller_sku,
        coalesce(nullif(oi.local_sku, ''), nullif(oi.mapped_local_sku, '')) as local_sku,
        coalesce(nullif(oi.marketplace_product_name, ''), nullif(oi.product_name, ''), nullif(oi.local_product_name, '')) as product_name,
        coalesce(nullif(oi.marketplace_variant_name, ''), nullif(oi.variant_name, ''), nullif(oi.variation_name, '')) as variant_name,
        greatest(coalesce(nullif(oi.qty, 0), nullif(oi.quantity, 0), 1), 1)::numeric as qty,
        coalesce(
          nullif(oi.gross_amount, 0),
          nullif(oi.paid_amount, 0),
          nullif(oi.unit_gross_amount, 0) * greatest(coalesce(nullif(oi.qty, 0), nullif(oi.quantity, 0), 1), 1),
          0
        )::numeric as line_gross
      from order_base ob
      join public.marketplace_order_items oi
        on oi.tenant_id = ob.tenant_id
       and oi.marketplace_order_id = ob.marketplace_order_id
    ),
    line_calc as (
      select lb.*, sum(lb.line_gross) over (partition by lb.marketplace_order_id) as order_line_gross
      from line_base lb
    ),
    enriched_base as (
      select
        lc.*,
        coalesce(f.payout, 0)::numeric as order_payout,
        (coalesce(f.payout, 0) <> 0) as has_payout
      from line_calc lc
      left join finance_by_order f on f.marketplace_order_id = lc.marketplace_order_id
    ),
    filtered as (
      select *
      from enriched_base
      where (v_filter = 'all' or (v_filter = 'paid' and has_payout) or (v_filter = 'unpaid' and not has_payout))
    ),
    grouped as (
      select
        tenant_id,
        marketplace_account_id,
        marketplace_group,
        coalesce(nullif(marketplace_sku_id, ''), nullif(marketplace_seller_sku, ''), nullif(local_sku, ''), 'unmapped') as sku_key,
        min(nullif(marketplace_sku_id, '')) as marketplace_sku_id,
        min(nullif(marketplace_sku, '')) as marketplace_sku,
        min(nullif(marketplace_seller_sku, '')) as marketplace_seller_sku,
        min(nullif(local_sku, '')) as local_sku,
        min(nullif(product_name, '')) as product_name,
        min(nullif(variant_name, '')) as variant_name,
        sum(qty)::numeric as qty_total,
        sum(line_gross)::numeric as gross_total,
        sum(line_gross) filter (where has_payout)::numeric as settled_gross_total,
        sum(line_gross) filter (where not has_payout)::numeric as unpaid_gross_total,
        sum(case when has_payout and order_line_gross > 0 then order_payout * (line_gross / order_line_gross) else 0 end)::numeric as payout_total,
        sum(case when has_payout and order_line_gross > 0 and order_payout > 0 then order_payout * (line_gross / order_line_gross) else 0 end)::numeric as positive_payout_total,
        sum(case when has_payout and order_line_gross > 0 and order_payout < 0 then order_payout * (line_gross / order_line_gross) else 0 end)::numeric as negative_payout_total,
        sum(qty) filter (where has_payout)::numeric as settled_qty,
        sum(qty) filter (where not has_payout)::numeric as unpaid_qty,
        count(distinct order_key)::integer as order_count,
        count(distinct order_key) filter (where has_payout)::integer as settled_order_count,
        count(distinct order_key) filter (where not has_payout)::integer as unpaid_order_count
      from filtered
      group by tenant_id, marketplace_account_id, marketplace_group,
        coalesce(nullif(marketplace_sku_id, ''), nullif(marketplace_seller_sku, ''), nullif(local_sku, ''), 'unmapped')
    ),
    hpp_sku as (
      select tenant_id, marketplace_account_id, lower(nullif(marketplace_sku_id, '')) as marketplace_sku_id,
             max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
             max(coalesce(target_margin_percent, target_margin, 0))::numeric as target_margin
      from public.marketplace_variant_hpp_mappings
      where coalesce(is_active, true) is true and nullif(marketplace_sku_id, '') is not null
        and (v_role = 'service_role' or tenant_id = v_tenant_id)
      group by tenant_id, marketplace_account_id, lower(nullif(marketplace_sku_id, ''))
    ),
    hpp_seller as (
      select tenant_id, marketplace_account_id, lower(nullif(marketplace_seller_sku, '')) as marketplace_seller_sku,
             max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
             max(coalesce(target_margin_percent, target_margin, 0))::numeric as target_margin
      from public.marketplace_variant_hpp_mappings
      where coalesce(is_active, true) is true and nullif(marketplace_seller_sku, '') is not null
        and (v_role = 'service_role' or tenant_id = v_tenant_id)
      group by tenant_id, marketplace_account_id, lower(nullif(marketplace_seller_sku, ''))
    ),
    hpp_local as (
      select tenant_id, marketplace_account_id, lower(nullif(local_sku, '')) as local_sku,
             max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
             max(coalesce(target_margin_percent, target_margin, 0))::numeric as target_margin
      from public.marketplace_variant_hpp_mappings
      where coalesce(is_active, true) is true and nullif(local_sku, '') is not null
        and (v_role = 'service_role' or tenant_id = v_tenant_id)
      group by tenant_id, marketplace_account_id, lower(nullif(local_sku, ''))
    ),
    grouped_enriched as (
      select
        g.*,
        coalesce(hs.hpp, hsel.hpp, hl.hpp, 0)::numeric as hpp_per_item,
        coalesce(hs.target_margin, hsel.target_margin, hl.target_margin, 0)::numeric as target_margin_percent,
        (coalesce(hs.hpp, hsel.hpp, hl.hpp, 0) * g.qty_total)::numeric as hpp_total
      from grouped g
      left join hpp_sku hs on hs.tenant_id = g.tenant_id and hs.marketplace_account_id = g.marketplace_account_id and hs.marketplace_sku_id = lower(nullif(g.marketplace_sku_id, ''))
      left join hpp_seller hsel on hsel.tenant_id = g.tenant_id and hsel.marketplace_account_id = g.marketplace_account_id and hsel.marketplace_seller_sku = lower(nullif(g.marketplace_seller_sku, ''))
      left join hpp_local hl on hl.tenant_id = g.tenant_id and hl.marketplace_account_id = g.marketplace_account_id and hl.local_sku = lower(nullif(g.local_sku, ''))
    ),
    counted as (
      select grouped_enriched.*, count(*) over ()::integer as total_count
      from grouped_enriched
    ),
    paged as (
      select *
      from counted
      order by payout_total desc nulls last, gross_total desc nulls last, sku_key
      offset v_offset
      limit v_page_size
    ),
    aggregates as (
      select
        coalesce(sum(gross_total), 0)::numeric as gross_total,
        coalesce(sum(payout_total), 0)::numeric as payout_total,
        coalesce(sum(hpp_total), 0)::numeric as hpp_total,
        coalesce(sum(qty_total), 0)::numeric as qty_total,
        coalesce(sum(settled_qty), 0)::numeric as settled_qty,
        coalesce(sum(unpaid_qty), 0)::numeric as unpaid_qty
      from grouped_enriched
    )
    select jsonb_build_object(
      'rows', coalesce(jsonb_agg(jsonb_build_object(
        'source', 'finance_sku_order_details_fast_mtd_group',
        'sku_detail_source', 'v82o',
        'marketplace', marketplace_group,
        'marketplace_account_id', marketplace_account_id,
        'sku', coalesce(nullif(local_sku, ''), nullif(marketplace_sku_id, ''), nullif(marketplace_seller_sku, ''), sku_key),
        'local_sku', coalesce(nullif(local_sku, ''), '-'),
        'marketplace_sku_id', marketplace_sku_id,
        'marketplace_sku', marketplace_sku,
        'marketplace_seller_sku', marketplace_seller_sku,
        'product_name', product_name,
        'variant_name', variant_name,
        'marketplace_variation_name', variant_name,
        'qty', coalesce(qty_total, 0),
        'qty_total', coalesce(qty_total, 0),
        'quantity', coalesce(qty_total, 0),
        'paid_qty', coalesce(settled_qty, 0),
        'settled_qty', coalesce(settled_qty, 0),
        'qty_settled', coalesce(settled_qty, 0),
        'unpaid_qty', coalesce(unpaid_qty, 0),
        'qty_unpaid', coalesce(unpaid_qty, 0),
        'gross_total', coalesce(gross_total, 0),
        'gross_sales', coalesce(gross_total, 0),
        'gross_amount', coalesce(gross_total, 0),
        'paid_gross_total', coalesce(settled_gross_total, 0),
        'settled_gross_total', coalesce(settled_gross_total, 0),
        'unpaid_gross_total', coalesce(unpaid_gross_total, 0),
        'payout_total', coalesce(payout_total, 0),
        'payout_amount', coalesce(payout_total, 0),
        'received_amount', coalesce(payout_total, 0),
        'net_settlement', coalesce(payout_total, 0),
        'positive_payout_total', coalesce(positive_payout_total, 0),
        'negative_payout_total', coalesce(negative_payout_total, 0),
        'hpp_total', coalesce(hpp_total, 0),
        'total_hpp', coalesce(hpp_total, 0),
        'paid_hpp_total', coalesce(hpp_total, 0),
        'settled_hpp_total', coalesce(hpp_total, 0),
        'hpp_per_item', coalesce(hpp_per_item, 0),
        'unit_hpp', coalesce(hpp_per_item, 0),
        'hpp', coalesce(hpp_per_item, 0),
        'hpp_status', case when coalesce(hpp_per_item, 0) > 0 then 'HPP mapping' else 'HPP belum mapping' end,
        'target_margin_percent', coalesce(target_margin_percent, 0),
        'order_count', coalesce(order_count, 0),
        'paid_order_count', coalesce(settled_order_count, 0),
        'settled_order_count', coalesce(settled_order_count, 0),
        'unpaid_order_count', coalesce(unpaid_order_count, 0),
        'gross_per_item', case when coalesce(qty_total, 0) > 0 then coalesce(gross_total, 0) / qty_total else 0 end,
        'payout_per_item', case when coalesce(settled_qty, 0) > 0 then coalesce(payout_total, 0) / settled_qty else 0 end
      ) order by payout_total desc nulls last, gross_total desc nulls last, sku_key), '[]'::jsonb),
      'page', v_page,
      'page_size', v_page_size,
      'total', coalesce(max(total_count), 0),
      'total_count', coalesce(max(total_count), 0),
      'total_pages', greatest(1, ceil(coalesce(max(total_count), 0)::numeric / v_page_size)::integer),
      'aggregates', (select to_jsonb(a) from aggregates a),
      'source', 'finance_sku_order_details_fast_mtd'
    )
    from paged
  );
end;
$function$;

-- 4. Redefine marketplace_apply_sku_maps_to_order_items with unique seller SKU mapping fallback
CREATE OR REPLACE FUNCTION public.marketplace_apply_sku_maps_to_order_items(
  p_tenant_id uuid,
  p_marketplace_account_id uuid DEFAULT NULL::uuid,
  p_days_back integer DEFAULT 90
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_updated integer := 0;
  v_matched integer := 0;
  v_ambiguous_seller_skipped integer := 0;
  v_unmatched integer := 0;
begin
  if p_tenant_id is null then
    return jsonb_build_object(
      'ok', false,
      'message', 'tenant_id kosong.',
      'updated', 0,
      'matched', 0,
      'ambiguous_seller_skipped', 0,
      'unmatched', 0,
      'source', 'marketplace_apply_sku_maps_to_order_items_safe_unique_seller_20260627'
    );
  end if;

  with candidate_items as (
    select
      i.marketplace_order_item_id,
      i.tenant_id,
      i.marketplace_account_id,
      to_jsonb(i) as ij,
      to_jsonb(o) as oj
    from public.marketplace_order_items i
    join public.marketplace_orders o
      on o.marketplace_order_id = i.marketplace_order_id
     and o.tenant_id = i.tenant_id
    where i.tenant_id = p_tenant_id
      and (
        p_marketplace_account_id is null
        or i.marketplace_account_id = p_marketplace_account_id
      )
      and coalesce(o.order_created_at, o.created_at, i.created_at)
          >= now() - make_interval(days => greatest(coalesce(p_days_back, 90), 1))
  ),
  item_keys as (
    select
      ci.*,
      lower(nullif(trim(coalesce(ci.oj->>'marketplace', ci.ij->>'marketplace', '')), '')) as item_marketplace,
      nullif(trim(ci.ij->>'marketplace_product_id'), '') as direct_product_id,
      nullif(trim(coalesce(
        ci.ij->>'marketplace_sku_id',
        ci.ij->>'sku_id'
      )), '') as direct_sku_id,
      nullif(trim(ci.ij->>'remote_sku_id'), '') as direct_remote_sku_id,
      nullif(trim(ci.ij->>'marketplace_sku'), '') as direct_marketplace_sku,
      nullif(trim(coalesce(
        ci.ij#>>'{raw_item,product_id}',
        ci.ij#>>'{raw_data,product_id}',
        ci.ij#>>'{raw_item,product_id_str}',
        ci.ij#>>'{raw_data,product_id_str}',
        ci.ij#>>'{raw_item,item_id}',
        ci.ij#>>'{raw_data,item_id}',
        ci.ij#>>'{raw_item,product,id}',
        ci.ij#>>'{raw_data,product,id}',
        ci.ij#>>'{raw_item,sku,product_id}',
        ci.ij#>>'{raw_data,sku,product_id}'
      )), '') as raw_product_id,
      nullif(trim(coalesce(
        ci.ij#>>'{raw_item,sku_id}',
        ci.ij#>>'{raw_data,sku_id}',
        ci.ij#>>'{raw_item,sku_id_str}',
        ci.ij#>>'{raw_data,sku_id_str}',
        ci.ij#>>'{raw_item,model_id}',
        ci.ij#>>'{raw_data,model_id}',
        ci.ij#>>'{raw_item,model_id_str}',
        ci.ij#>>'{raw_data,model_id_str}',
        ci.ij#>>'{raw_item,sku,id}',
        ci.ij#>>'{raw_data,sku,id}',
        ci.ij#>>'{raw_item,skus,0,sku_id}',
        ci.ij#>>'{raw_data,skus,0,sku_id}',
        ci.ij#>>'{raw_item,sku_list,0,sku_id}',
        ci.ij#>>'{raw_data,sku_list,0,sku_id}',
        ci.ij#>>'{raw_item,package_list,0,sku_id}',
        ci.ij#>>'{raw_data,package_list,0,sku_id}'
      )), '') as raw_sku_id,
      nullif(trim(coalesce(
        ci.ij->>'marketplace_variant_snapshot_id',
        ci.ij#>>'{raw_item,marketplace_variant_snapshot_id}',
        ci.ij#>>'{raw_data,marketplace_variant_snapshot_id}',
        ci.ij#>>'{raw_item,variant_snapshot_id}',
        ci.ij#>>'{raw_data,variant_snapshot_id}'
      )), '') as item_variant_snapshot_id,
      nullif(trim(coalesce(
        ci.ij->>'marketplace_seller_sku',
        ci.ij->>'seller_sku',
        ci.ij->>'remote_seller_sku',
        ci.ij#>>'{raw_item,seller_sku}',
        ci.ij#>>'{raw_data,seller_sku}',
        ci.ij#>>'{raw_item,sellerSku}',
        ci.ij#>>'{raw_data,sellerSku}',
        ci.ij#>>'{raw_item,model_sku}',
        ci.ij#>>'{raw_data,model_sku}'
      )), '') as item_seller_sku
    from candidate_items ci
  ),
  active_maps as (
    select
      m.*,
      lower(trim(coalesce(m.marketplace, ''))) as map_marketplace,
      lower(trim(coalesce(m.marketplace_seller_sku, m.remote_seller_sku, ''))) as seller_key,
      nullif(trim(m.marketplace_product_id), '') as map_product_id,
      nullif(trim(m.marketplace_sku_id), '') as map_sku_id,
      nullif(trim(m.remote_sku_id), '') as map_remote_sku_id,
      case
        when nullif(trim(coalesce(m.marketplace_sku, '')), '') is null then null
        when lower(trim(coalesce(m.marketplace_sku, ''))) =
             lower(trim(coalesce(m.marketplace_seller_sku, m.remote_seller_sku, ''))) then null
        else nullif(trim(m.marketplace_sku), '')
      end as map_marketplace_sku,
      nullif(trim(m.marketplace_variant_snapshot_id::text), '') as map_variant_snapshot_id
    from public.marketplace_sku_maps m
    where m.tenant_id = p_tenant_id
      and (
        p_marketplace_account_id is null
        or m.marketplace_account_id = p_marketplace_account_id
      )
      and coalesce(m.status, 'active') = 'active'
      and coalesce(m.local_sku, '') <> ''
      and coalesce(m.local_product_id, m.product_id) is not null
  ),
  seller_map_counts as (
    select
      tenant_id,
      marketplace_account_id,
      map_marketplace,
      seller_key,
      count(*) as map_count,
      (array_agg(
        marketplace_sku_map_id
        order by updated_at desc nulls last,
                 created_at desc nulls last,
                 marketplace_sku_map_id::text
      ))[1] as marketplace_sku_map_id
    from active_maps
    where seller_key is not null
      and seller_key <> ''
    group by tenant_id, marketplace_account_id, map_marketplace, seller_key
  ),
  best_map as (
    select distinct on (ik.marketplace_order_item_id)
      ik.marketplace_order_item_id,
      m.marketplace_sku_map_id,
      coalesce(m.local_product_id, m.product_id) as mapped_product_id,
      m.local_sku,
      case
        when m.map_product_id is not null
         and m.map_product_id = ik.direct_product_id
         and m.map_sku_id = ik.direct_sku_id
          then 1
        when ik.direct_sku_id is not null
         and m.map_sku_id = ik.direct_sku_id
          then 2
        when (
              m.map_product_id is not null
          and m.map_product_id = ik.raw_product_id
          and (
               m.map_sku_id = ik.raw_sku_id
            or m.map_remote_sku_id = ik.raw_sku_id
            or m.map_marketplace_sku = ik.raw_sku_id
            or m.map_remote_sku_id = ik.direct_remote_sku_id
            or m.map_marketplace_sku = ik.direct_marketplace_sku
          )
        )
          or (
              ik.raw_sku_id is not null
          and (
               m.map_sku_id = ik.raw_sku_id
            or m.map_remote_sku_id = ik.raw_sku_id
            or m.map_marketplace_sku = ik.raw_sku_id
          )
        )
          or (
              ik.direct_remote_sku_id is not null
          and m.map_remote_sku_id = ik.direct_remote_sku_id
        )
          or (
              ik.direct_marketplace_sku is not null
          and m.map_marketplace_sku = ik.direct_marketplace_sku
        )
          or (
              ik.item_variant_snapshot_id is not null
          and m.map_variant_snapshot_id = ik.item_variant_snapshot_id
        )
          then 3
        when smc.map_count = 1
          then 8
        else 99
      end as match_rank,
      m.updated_at,
      m.created_at
    from item_keys ik
    join active_maps m
      on m.tenant_id = ik.tenant_id
     and m.marketplace_account_id = ik.marketplace_account_id
     and (
          ik.item_marketplace is null
          or ik.item_marketplace = ''
          or m.map_marketplace = ik.item_marketplace
     )
    left join seller_map_counts smc
      on smc.tenant_id = ik.tenant_id
     and smc.marketplace_account_id = ik.marketplace_account_id
     and smc.map_marketplace = m.map_marketplace
     and smc.seller_key = lower(trim(coalesce(ik.item_seller_sku, '')))
     and smc.marketplace_sku_map_id = m.marketplace_sku_map_id
    where
      (
        m.map_product_id is not null
        and m.map_product_id = ik.direct_product_id
        and m.map_sku_id = ik.direct_sku_id
      )
      or (
        ik.direct_sku_id is not null
        and m.map_sku_id = ik.direct_sku_id
      )
      or (
        m.map_product_id is not null
        and m.map_product_id = ik.raw_product_id
        and (
             m.map_sku_id = ik.raw_sku_id
          or m.map_remote_sku_id = ik.raw_sku_id
          or m.map_marketplace_sku = ik.raw_sku_id
          or m.map_remote_sku_id = ik.direct_remote_sku_id
          or m.map_marketplace_sku = ik.direct_marketplace_sku
        )
      )
      or (
        ik.raw_sku_id is not null
        and (
             m.map_sku_id = ik.raw_sku_id
          or m.map_remote_sku_id = ik.raw_sku_id
          or m.map_marketplace_sku = ik.raw_sku_id
        )
      )
      or (
        ik.direct_remote_sku_id is not null
        and m.map_remote_sku_id = ik.direct_remote_sku_id
      )
      or (
        ik.direct_marketplace_sku is not null
        and m.map_marketplace_sku = ik.direct_marketplace_sku
      )
      or (
        ik.item_variant_snapshot_id is not null
        and m.map_variant_snapshot_id = ik.item_variant_snapshot_id
      )
      or (
        smc.map_count = 1
      )
    order by
      ik.marketplace_order_item_id,
      match_rank,
      m.updated_at desc nulls last,
      m.created_at desc nulls last,
      m.marketplace_sku_map_id::text
  ),
  ambiguous_seller_items as (
    select distinct ik.marketplace_order_item_id
    from item_keys ik
    join seller_map_counts smc
      on smc.tenant_id = ik.tenant_id
     and smc.marketplace_account_id = ik.marketplace_account_id
     and (
          ik.item_marketplace is null
          or ik.item_marketplace = ''
          or smc.map_marketplace = ik.item_marketplace
     )
     and smc.seller_key = lower(trim(coalesce(ik.item_seller_sku, '')))
    left join best_map bm
      on bm.marketplace_order_item_id = ik.marketplace_order_item_id
     and bm.match_rank < 99
    where smc.map_count > 1
      and bm.marketplace_order_item_id is null
  ),
  valid_matches as (
    select bm.*
    from best_map bm
    left join ambiguous_seller_items asi
      on asi.marketplace_order_item_id = bm.marketplace_order_item_id
    where bm.match_rank < 99
      and asi.marketplace_order_item_id is null
  ),
  updated_rows as (
    update public.marketplace_order_items i
      set mapped_product_id = vm.mapped_product_id,
          mapped_local_sku = vm.local_sku,
          marketplace_sku_map_id = vm.marketplace_sku_map_id,
          last_error = null,
          updated_at = now()
      from valid_matches vm
      where i.marketplace_order_item_id = vm.marketplace_order_item_id
        and (
             i.mapped_product_id is distinct from vm.mapped_product_id
          or i.mapped_local_sku is distinct from vm.local_sku
          or i.marketplace_sku_map_id is distinct from vm.marketplace_sku_map_id
        )
      returning i.marketplace_order_item_id
  )
  select
    coalesce(count(*)::integer, 0)
  into v_updated
  from updated_rows;

  select count(distinct marketplace_order_item_id)::integer into v_matched
  from best_map
  where match_rank < 99;

  select count(distinct marketplace_order_item_id)::integer into v_ambiguous_seller_skipped
  from ambiguous_seller_items;

  select count(distinct ik.marketplace_order_item_id)::integer into v_unmatched
  from item_keys ik
  left join best_map bm on bm.marketplace_order_item_id = ik.marketplace_order_item_id and bm.match_rank < 99
  left join ambiguous_seller_items asi on asi.marketplace_order_item_id = ik.marketplace_order_item_id
  where bm.marketplace_order_item_id is null
    and asi.marketplace_order_item_id is null;

  return jsonb_build_object(
    'ok', true,
    'message', 'Mapping local_sku berhasil diterapkan ke order items.',
    'updated', v_updated,
    'matched', v_matched,
    'ambiguous_seller_skipped', v_ambiguous_seller_skipped,
    'unmatched', v_unmatched,
    'source', 'marketplace_apply_sku_maps_to_order_items_safe_unique_seller_20260627'
  );
end;
$function$;

-- 5. Redefine marketplace_submit_return_item_review to bypass return item stock-in verification in legacy mode
CREATE OR REPLACE FUNCTION public.marketplace_submit_return_item_review(
  p_tenant_id uuid,
  p_marketplace_order_item_id uuid,
  p_package_match_status text,
  p_item_condition text,
  p_can_restock boolean,
  p_note text DEFAULT NULL::text
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 AS $function$
 declare
   v_order record;
   v_item record;
   v_review_status text := 'rejected_no_stock_in';
   v_stock_in_status text := 'not_applicable';
   v_stock_in_count integer := 0;
   v_qty integer := 0;
   v_note text;
   v_existing_done boolean := false;
   v_is_stocked_out boolean := false;
 begin
   perform public.marketplace_assert_tenant_access(p_tenant_id);
 
   select i.* into v_item
   from public.marketplace_order_items as i
   where i.tenant_id = p_tenant_id
     and i.marketplace_order_item_id = p_marketplace_order_item_id
   for update;
 
   if not found then
     raise exception 'Item order marketplace tidak ditemukan.';
   end if;
 
   select o.* into v_order
   from public.marketplace_orders as o
   where o.tenant_id = p_tenant_id
     and o.marketplace_order_id = v_item.marketplace_order_id
   for update;
 
   if not found then
     raise exception 'Order marketplace tidak ditemukan.';
   end if;
 
   select public.marketplace_order_item_is_stocked_out(p_tenant_id, p_marketplace_order_item_id)
     into v_is_stocked_out;
 
   if coalesce(p_note, '') like '%legacy_mode=true%' then
     v_is_stocked_out := true;
   end if;
 
   -- Kalau status order packable/AWAITING_COLLECTION dan bukti fisik stock out ada, rapikan status itemnya dulu.
   if v_is_stocked_out and coalesce(v_item.stock_action_status, '') <> 'stock_out_done' then
     update public.marketplace_order_items i
        set stock_action_status = 'stock_out_done',
            reserved_qty = 0,
            stock_out_at = coalesce(i.stock_out_at, now()),
            last_error = null,
            updated_at = now()
      where i.marketplace_order_item_id = p_marketplace_order_item_id;
 
     select i.* into v_item
     from public.marketplace_order_items as i
     where i.tenant_id = p_tenant_id
       and i.marketplace_order_item_id = p_marketplace_order_item_id
     for update;
   end if;
 
   select exists (
     select 1 from public.marketplace_order_stock_movements m
     where m.tenant_id = p_tenant_id
       and m.marketplace_order_item_id = p_marketplace_order_item_id
       and m.action_type in ('marketplace_return_stock_in','marketplace_cancel_stock_in','marketplace_refund_stock_in')
       and m.movement_status = 'done'
   ) into v_existing_done;
 
   if coalesce(p_can_restock, false)
      and lower(coalesce(p_package_match_status, '')) = 'sesuai'
      and lower(coalesce(p_item_condition, '')) = 'baik'
      and v_is_stocked_out
   then
     v_review_status := 'approved_stock_in';
 
     if v_existing_done or coalesce(v_item.return_review_status, '') = 'stock_in_done' then
       v_stock_in_status := 'skipped_duplicate';
       v_stock_in_count := 0;
     else
       v_qty := greatest(coalesce(v_item.quantity, 0), 0)::integer;
       if v_qty <= 0 then
         raise exception 'Qty return tidak valid.';
       end if;
 
       begin
         v_note := concat(
           'Marketplace return stock in ',
           coalesce(v_order.marketplace, '-'),
           ' #', coalesce(v_order.external_order_id, v_order.order_sn, v_order.marketplace_order_id::text),
           ' item ', coalesce(v_item.mapped_local_sku, v_item.seller_sku, v_item.marketplace_sku_id, '-')
         );
 
         perform public.register_stock_transaction(
           v_item.mapped_product_id,
           'IN',
           v_qty,
           'marketplace_return_restore',
           v_note,
           null,
           null
         );
 
         insert into public.marketplace_order_stock_movements (
           marketplace_order_id,
           marketplace_order_item_id,
           tenant_id,
           marketplace_account_id,
           product_id,
           local_sku,
           quantity,
           action_type,
           movement_status,
           created_by
         ) values (
           v_item.marketplace_order_id,
           v_item.marketplace_order_item_id,
           v_item.tenant_id,
           v_item.marketplace_account_id,
           v_item.mapped_product_id,
           v_item.mapped_local_sku,
           v_qty,
           case public.marketplace_order_status_group(v_order.order_status)
             when 'cancelled' then 'marketplace_cancel_stock_in'
             when 'return_refund' then 'marketplace_refund_stock_in'
             else 'marketplace_return_stock_in'
           end,
           'done',
           auth.uid()
         );
 
         update public.marketplace_order_items as i
            set returned_qty = v_qty,
                return_review_status = 'stock_in_done',
                stock_in_restored_at = now(),
                updated_at = now()
          where i.marketplace_order_item_id = p_marketplace_order_item_id;
 
         perform public.marketplace_try_queue_stock_sync_for_item(p_tenant_id, p_marketplace_order_item_id, 'marketplace_return_stock_in');
 
         v_stock_in_status := 'done';
         v_stock_in_count := 1;
       exception when others then
         v_stock_in_status := 'failed';
 
         insert into public.marketplace_order_stock_movements (
           marketplace_order_id,
           marketplace_order_item_id,
           tenant_id,
           marketplace_account_id,
           product_id,
           local_sku,
           quantity,
           action_type,
           movement_status,
           error_message,
           created_by
         ) values (
           v_item.marketplace_order_id,
           v_item.marketplace_order_item_id,
           v_item.tenant_id,
           v_item.marketplace_account_id,
           v_item.mapped_product_id,
           v_item.mapped_local_sku,
           greatest(coalesce(v_item.quantity, 0), 0),
           'marketplace_return_stock_in',
           'failed',
           sqlerrm,
           auth.uid()
         );
       end;
     end if;
   elsif not v_is_stocked_out
         and coalesce(v_item.reserved_qty, 0) > 0
   then
     v_review_status := 'released_reservation';
     v_stock_in_status := 'not_applicable';
 
     update public.marketplace_order_items as i
        set reserved_qty = 0,
            return_review_status = 'reservation_released',
            stock_action_status = 'cancelled_released',
            updated_at = now()
      where i.marketplace_order_item_id = p_marketplace_order_item_id;
 
     perform public.marketplace_try_queue_stock_sync_for_item(p_tenant_id, p_marketplace_order_item_id, 'marketplace_cancel_release_reservation');
   else
     v_review_status := 'rejected_no_stock_in';
     v_stock_in_status := 'not_applicable';
 
     update public.marketplace_order_items as i
        set return_review_status = 'not_restocked',
            updated_at = now()
      where i.marketplace_order_item_id = p_marketplace_order_item_id;
   end if;
 
   insert into public.marketplace_return_item_reviews (
     tenant_id,
     marketplace_account_id,
     marketplace_order_id,
     marketplace_order_item_id,
     external_order_id,
     review_type,
     package_match_status,
     item_condition,
     can_restock,
     note,
     created_by
   ) values (
     p_tenant_id,
     v_item.marketplace_account_id,
     v_item.marketplace_order_id,
     v_item.marketplace_order_item_id,
     v_order.external_order_id,
     v_review_status,
     p_package_match_status,
     p_item_condition,
     p_can_restock,
     p_note,
     auth.uid()
   );
 
   return jsonb_build_object(
     'ok', true,
     'review_status', v_review_status,
     'stock_in_status', v_stock_in_status,
     'stock_in_count', v_stock_in_count,
     'is_stocked_out', v_is_stocked_out,
     'message', 'Review item return berhasil disimpan.'
   );
 end;
 $function$;
