-- Migration: Fix finance dashboard snapshot total_amount error and optimize apply_sku_maps
--
-- 1. In finance_dashboard_snapshot_core_20260625, marketplace_finance_reports does not 
--    have a total_amount column. Replace fi.total_amount with 0 or remove it.
-- 2. marketplace_apply_sku_maps_to_order_items times out on 90 days because it extracts
--    complex JSON paths from raw_data for every single order item. We rewrite it to rely
--    only on the indexed top-level columns: marketplace_sku_id and marketplace_seller_sku.

-- ==============================================================================
-- 1. Fix finance_dashboard_snapshot_core_20260625
-- ==============================================================================
CREATE OR REPLACE FUNCTION public.finance_dashboard_snapshot_core_20260625(
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
  v_start date := coalesce(p_start, date_trunc('month', now() at time zone 'Asia/Jakarta')::date);
  v_end date := coalesce(p_end, (now() at time zone 'Asia/Jakarta')::date);
  v_marketplace text := nullif(lower(trim(coalesce(p_marketplace,''))), '');
  v_user_id uuid;
  v_tenant_id uuid;

  v_base jsonb;
  v_expenses jsonb := '[]'::jsonb;
  v_purchases jsonb := '[]'::jsonb;
  v_cash_flow jsonb := '[]'::jsonb;
  v_breakdown jsonb := '[]'::jsonb;
  v_fee jsonb := '{}'::jsonb;

  v_ops_total numeric := 0;
  v_purchase_total numeric := 0;
  v_payout_total numeric := 0;
  v_hpp_total numeric := 0;

  -- payout sourced directly from marketplace_finance_reports
  v_reports_payout numeric := 0;
  v_reports_omzet  numeric := 0;
begin
  if v_marketplace in ('all','semua','_all','*') then
    v_marketplace := null;
  end if;

  begin
    v_user_id := nullif(
      coalesce(
        auth.uid()::text,
        (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
      ),
      ''
    )::uuid;
  exception when others then
    v_user_id := null;
  end;

  select u.tenant_id
    into v_tenant_id
  from public.users u
  where u.user_id = v_user_id
  limit 1;

  v_base := public.finance_customer_dashboard_snapshot_v24_6_82o(
    v_start,
    v_end,
    v_marketplace,
    p_account_id
  );

  v_payout_total :=
    case
      when coalesce(
        v_base->'summary'->>'payout_total',
        v_base->'summary'->>'payout_amount',
        v_base->'summary'->>'net_settlement',
        v_base->'summary'->>'received_amount',
        '0'
      ) ~ '^-?[0-9]+(\.[0-9]+)?$'
      then coalesce(
        v_base->'summary'->>'payout_total',
        v_base->'summary'->>'payout_amount',
        v_base->'summary'->>'net_settlement',
        v_base->'summary'->>'received_amount',
        '0'
      )::numeric
      else 0
    end;

  v_hpp_total :=
    case
      when coalesce(
        v_base->'summary'->>'hpp_total',
        v_base->'summary'->>'total_hpp',
        '0'
      ) ~ '^-?[0-9]+(\.[0-9]+)?$'
      then coalesce(
        v_base->'summary'->>'hpp_total',
        v_base->'summary'->>'total_hpp',
        '0'
      )::numeric
      else 0
    end;

  -- Source payout directly from marketplace_finance_reports (the ground truth).
  -- Use this when base chain returns 0 (stale or missing finance sync).
  if v_tenant_id is not null then
    select
      coalesce(sum(coalesce(fi.payout_amount, fi.received_amount, fi.net_settlement, 0)), 0),
      coalesce(sum(coalesce(fi.gross_amount, 0)), 0) -- FIXED: removed fi.total_amount
    into v_reports_payout, v_reports_omzet
    from public.marketplace_finance_reports fi
    where fi.tenant_id = v_tenant_id
      and coalesce(fi.settlement_date, fi.period_start) between v_start and v_end
      and (p_account_id is null or fi.marketplace_account_id = p_account_id)
      and (
        v_marketplace is null
        or public._finance_marketplace_norm_20260624(fi.marketplace) =
           public._finance_marketplace_norm_20260624(v_marketplace)
      );

    -- Override payout when base returned 0 but reports has data
    if v_payout_total = 0 and v_reports_payout > 0 then
      v_payout_total := v_reports_payout;
      -- patch summary in base
      v_base := jsonb_set(v_base, '{summary,payout_total}', to_jsonb(v_reports_payout), true);
      v_base := jsonb_set(v_base, '{summary,payout_amount}', to_jsonb(v_reports_payout), true);
      v_base := jsonb_set(v_base, '{summary,net_settlement}', to_jsonb(v_reports_payout), true);
      v_base := jsonb_set(v_base, '{summary,received_amount}', to_jsonb(v_reports_payout), true);
      v_base := jsonb_set(v_base, '{payout_total}', to_jsonb(v_reports_payout), true);
    end if;
  end if;

  if v_tenant_id is not null then
    select
      coalesce(
        jsonb_agg(
          to_jsonb(e)
          order by coalesce(e.expense_date, e.paid_at, e.created_at::date) desc, e.created_at desc
        ),
        '[]'::jsonb
      ),
      coalesce(sum(e.amount),0)
    into v_expenses, v_ops_total
    from public.finance_operational_expenses e
    where e.tenant_id = v_tenant_id
      and coalesce(e.expense_date, e.paid_at, e.created_at::date) between v_start and v_end
      and lower(coalesce(e.status,'active')) not in ('cancelled','canceled','deleted','void','voided','rejected');

    select
      coalesce(
        jsonb_agg(
          to_jsonb(p)
          order by coalesce(p.tanggal, p.created_at::date) desc, p.created_at desc
        ),
        '[]'::jsonb
      ),
      coalesce(sum(p.total_pembelian),0)
    into v_purchases, v_purchase_total
    from public.purchases p
    where p.tenant_id = v_tenant_id
      and coalesce(p.tanggal, p.created_at::date) between v_start and v_end
      and lower(coalesce(p.status,'')) in (
        'verified','verified_finance','finance_verified','approved','approved_by_finance',
        'finance_approved','paid','completed','done','selesai','finish','finished'
      );
  end if;

  with fee as (
    select
      coalesce(sum(platform_fee),0)      as platform_fee,
      coalesce(sum(commission_fee),0)    as commission_fee,
      0::numeric                         as service_fee,
      coalesce(sum(affiliate_fee),0)     as affiliate_fee,
      coalesce(sum(shipping_fee),0)      as shipping_fee,
      0::numeric                         as voucher_amount,
      coalesce(sum(discount_amount),0)   as discount_amount,
      coalesce(sum(refund_amount),0)     as refund_amount,
      coalesce(sum(adjustment_amount),0) as adjustment_amount
    from public.marketplace_finance_reports fi
    where fi.tenant_id = v_tenant_id
      and coalesce(fi.settlement_date, fi.period_start) between v_start and v_end
      and (p_account_id is null or fi.marketplace_account_id = p_account_id)
      and (
        v_marketplace is null
        or public._finance_marketplace_norm_20260624(fi.marketplace) =
           public._finance_marketplace_norm_20260624(v_marketplace)
      )
  )
  select jsonb_build_object(
    'platform_fee', platform_fee,
    'commission_fee', commission_fee,
    'service_fee', service_fee,
    'affiliate_fee', affiliate_fee,
    'shipping_fee', shipping_fee,
    'voucher_amount', voucher_amount,
    'discount_amount', discount_amount,
    'refund_amount', refund_amount,
    'adjustment_amount', adjustment_amount,
    'total_deductions',
      platform_fee + commission_fee + service_fee + affiliate_fee + shipping_fee
      + voucher_amount + discount_amount + refund_amount + adjustment_amount
  )
  into v_fee
  from fee;

  with marketplace_rows as (
    select
      elem,
      coalesce(
        elem->>'marketplace',
        elem->>'marketplace_name',
        elem->>'name',
        elem->>'label',
        'Marketplace'
      ) as marketplace_label,
      case
        when coalesce(
          elem->>'payout_total',
          elem->>'payout_amount',
          elem->>'net_settlement',
          elem->>'received_amount',
          elem->>'payout',
          '0'
        ) ~ '^-?[0-9]+(\.[0-9]+)?$'
        then coalesce(
          elem->>'payout_total',
          elem->>'payout_amount',
          elem->>'net_settlement',
          elem->>'received_amount',
          elem->>'payout',
          '0'
        )::numeric
        else 0
      end as amount
    from jsonb_array_elements(
      coalesce(
        v_base->'by_marketplace',
        v_base->'marketplace_breakdown',
        v_base->'marketplaces',
        '[]'::jsonb
      )
    ) as elem
  ),
  rows as (
    select jsonb_build_object(
      'date', v_start,
      'category', marketplace_label,
      'marketplace', marketplace_label,
      'type', 'income',
      'amount', amount,
      'source', 'marketplace_by_marketplace'
    ) as row
    from marketplace_rows
    where amount <> 0

    union all
    select jsonb_build_object(
      'date', v_start,
      'category', 'Biaya operasional',
      'type', 'expense',
      'amount', -v_ops_total,
      'source', 'operational_expenses'
    ) as row
    where v_ops_total <> 0

    union all
    select jsonb_build_object(
      'date', v_start,
      'category', 'Pembelian bahan/barang',
      'type', 'expense',
      'amount', -v_purchase_total,
      'source', 'purchases'
    ) as row
    where v_purchase_total <> 0
  )
  select coalesce(jsonb_agg(row order by (row->>'amount')::numeric desc), '[]'::jsonb)
    into v_cash_flow
  from rows;

  with fee_rows as (
    select jsonb_array_elements(
      jsonb_build_array(
        jsonb_build_object('name','Platform fee','type','deduction','amount',coalesce((v_fee->>'platform_fee')::numeric,0)),
        jsonb_build_object('name','Commission fee','type','deduction','amount',coalesce((v_fee->>'commission_fee')::numeric,0)),
        jsonb_build_object('name','Service fee','type','deduction','amount',coalesce((v_fee->>'service_fee')::numeric,0)),
        jsonb_build_object('name','Affiliate fee','type','deduction','amount',coalesce((v_fee->>'affiliate_fee')::numeric,0)),
        jsonb_build_object('name','Shipping fee','type','deduction','amount',coalesce((v_fee->>'shipping_fee')::numeric,0)),
        jsonb_build_object('name','Voucher/Discount','type','deduction','amount',coalesce((v_fee->>'voucher_amount')::numeric,0) + coalesce((v_fee->>'discount_amount')::numeric,0)),
        jsonb_build_object('name','Refund','type','deduction','amount',coalesce((v_fee->>'refund_amount')::numeric,0)),
        jsonb_build_object('name','Adjustment','type','deduction','amount',coalesce((v_fee->>'adjustment_amount')::numeric,0))
      )
    ) as item
  )
  select coalesce(
    jsonb_agg(item order by (item->>'amount')::numeric asc),
    '[]'::jsonb
  )
    into v_breakdown
  from fee_rows
  where coalesce((item->>'amount')::numeric,0) <> 0;

  return jsonb_build_object(
    'ok', true,
    'base', v_base,
    'fee_breakdown', v_fee,
    'fee_items', v_breakdown,
    'cash_flow', v_cash_flow,
    'expenses', v_expenses,
    'purchases', v_purchases,
    'payout_total', v_payout_total,
    'hpp_total', v_hpp_total,
    'ops_total', v_ops_total,
    'purchase_total', v_purchase_total,
    'reports_payout', v_reports_payout
  );
end;
$function$;

-- ==============================================================================
-- 2. Optimize marketplace_apply_sku_maps_to_order_items 
--    (Avoid deep JSON CTEs, just match by marketplace_sku_id and seller_sku)
-- ==============================================================================
CREATE OR REPLACE FUNCTION public.marketplace_apply_sku_maps_to_order_items(
  p_tenant_id uuid,
  p_marketplace_account_id uuid DEFAULT NULL::uuid,
  p_days_back integer DEFAULT 90
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '25s'
AS $function$
declare
  v_updated integer := 0;
begin
  if p_tenant_id is null then
    return jsonb_build_object(
      'ok', false,
      'message', 'tenant_id kosong.',
      'updated', 0,
      'source', 'marketplace_apply_sku_maps_to_order_items_optimized'
    );
  end if;

  -- 1. Apply by exact marketplace_sku_id match
  with maps as (
    select distinct on (tenant_id, marketplace_account_id, coalesce(marketplace_sku_id, remote_sku_id))
      tenant_id,
      marketplace_account_id,
      coalesce(marketplace_sku_id, remote_sku_id) as sku_id,
      nullif(trim(local_sku), '') as local_sku
    from public.marketplace_sku_maps
    where tenant_id = p_tenant_id
      and (p_marketplace_account_id is null or marketplace_account_id = p_marketplace_account_id)
      and coalesce(status, 'active') = 'active'
      and nullif(trim(local_sku), '') is not null
      and coalesce(marketplace_sku_id, remote_sku_id) is not null
    order by tenant_id, marketplace_account_id, coalesce(marketplace_sku_id, remote_sku_id), updated_at desc nulls last
  )
  update public.marketplace_order_items oi
  set 
    local_sku = m.local_sku,
    mapped_local_sku = m.local_sku,
    updated_at = now()
  from maps m
  where oi.tenant_id = m.tenant_id
    and oi.marketplace_account_id = m.marketplace_account_id
    and oi.marketplace_sku_id = m.sku_id
    and oi.local_sku is distinct from m.local_sku
    and oi.created_at >= now() - make_interval(days => coalesce(p_days_back, 90));

  v_updated := v_updated + ROW_COUNT;

  -- 2. Apply by seller_sku for those still unmapped
  with seller_maps as (
    select tenant_id, marketplace_account_id, lower(trim(coalesce(marketplace_seller_sku, remote_seller_sku))) as seller_sku,
           min(nullif(trim(local_sku), '')) as local_sku
    from public.marketplace_sku_maps
    where tenant_id = p_tenant_id
      and (p_marketplace_account_id is null or marketplace_account_id = p_marketplace_account_id)
      and coalesce(status, 'active') = 'active'
      and nullif(trim(local_sku), '') is not null
      and nullif(trim(coalesce(marketplace_seller_sku, remote_seller_sku)), '') is not null
    group by tenant_id, marketplace_account_id, lower(trim(coalesce(marketplace_seller_sku, remote_seller_sku)))
    having count(distinct nullif(trim(local_sku), '')) = 1 -- Only unambiguously mapped seller skus
  )
  update public.marketplace_order_items oi
  set 
    local_sku = sm.local_sku,
    mapped_local_sku = sm.local_sku,
    updated_at = now()
  from seller_maps sm
  where oi.tenant_id = sm.tenant_id
    and oi.marketplace_account_id = sm.marketplace_account_id
    and lower(trim(coalesce(oi.marketplace_seller_sku, oi.seller_sku))) = sm.seller_sku
    and oi.local_sku is null
    and oi.created_at >= now() - make_interval(days => coalesce(p_days_back, 90));
    
  v_updated := v_updated + ROW_COUNT;

  return jsonb_build_object(
    'ok', true,
    'message', 'Berhasil memperbarui pemetaan SKU pada pesanan.',
    'updated', v_updated,
    'source', 'marketplace_apply_sku_maps_to_order_items_optimized'
  );
end;
$function$;
