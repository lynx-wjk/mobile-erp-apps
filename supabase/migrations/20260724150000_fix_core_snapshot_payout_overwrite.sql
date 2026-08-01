-- Migration: 20260724150000_fix_core_snapshot_payout_overwrite.sql
-- Fixes finance_dashboard_snapshot_core_20260625 so it never overwrites valid base per-marketplace payout metrics with 0.

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

  v_reports_payout numeric := 0;
  v_reports_omzet  numeric := 0;

  v_mp_payout_map jsonb := '{}'::jsonb;
  v_marketplaces_arr jsonb := '[]'::jsonb;

  v_sum_platform_fee numeric := 0;
  v_sum_commission_fee numeric := 0;
  v_sum_affiliate_fee numeric := 0;
  v_sum_shipping_fee numeric := 0;
  v_sum_discount_amount numeric := 0;
  v_sum_refund_amount numeric := 0;
  v_total_deductions numeric := 0;
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

  begin
    v_tenant_id := coalesce(
      (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'tenant_id')::uuid,
      (
        select u.tenant_id
        from public.users u
        where u.user_id = nullif(
          coalesce(
            auth.uid()::text,
            (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
          ),
          ''
        )::uuid
        limit 1
      ),
      public.app_current_tenant_id_or_default(),
      (select tenant_id from public.users where tenant_id is not null limit 1)
    );
  exception when others then
    v_tenant_id := public.app_current_tenant_id_or_default();
  end;

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

  if v_tenant_id is not null then
    with mp_payout as (
      select
        public._finance_marketplace_norm_20260624(fi.marketplace) as marketplace,
        coalesce(sum(coalesce(fi.payout_amount, fi.received_amount, fi.net_settlement, 0)), 0) as payout,
        coalesce(sum(coalesce(fi.gross_amount, 0)), 0) as omzet
      from public.marketplace_finance_reports fi
      where fi.tenant_id = v_tenant_id
        and coalesce(fi.settlement_date::date, fi.period_start::date, fi.created_at::date) between v_start and v_end
        and (
           coalesce(fi.report_type, '') <> 'statement'
           or public._finance_marketplace_norm_20260624(fi.marketplace) = 'tiktok_shop'
        )
        and not (
           public._finance_marketplace_norm_20260624(fi.marketplace) = 'tiktok_shop'
           and coalesce(fi.report_type, '') = 'order_settlement'
        )
        and (p_account_id is null or fi.marketplace_account_id = p_account_id)
        and (
          v_marketplace is null
          or public._finance_marketplace_norm_20260624(fi.marketplace) =
             public._finance_marketplace_norm_20260624(v_marketplace)
        )
      group by public._finance_marketplace_norm_20260624(fi.marketplace)
    )
    select
      coalesce(jsonb_object_agg(marketplace, payout), '{}'::jsonb),
      coalesce(sum(payout), 0),
      coalesce(sum(omzet), 0)
    into v_mp_payout_map, v_reports_payout, v_reports_omzet
    from mp_payout;

    v_marketplaces_arr := coalesce(
      v_base->'marketplace_breakdown',
      v_base->'by_marketplace',
      v_base->'marketplaces',
      '[]'::jsonb
    );

    if jsonb_array_length(v_marketplaces_arr) > 0 then
      select jsonb_agg(
        case
          when coalesce((v_mp_payout_map->>public._finance_marketplace_norm_20260624(elem->>'marketplace'))::numeric, 0) > 0 then
            jsonb_set(
              jsonb_set(
                jsonb_set(
                  jsonb_set(elem, '{payout_total}', to_jsonb((v_mp_payout_map->>public._finance_marketplace_norm_20260624(elem->>'marketplace'))::numeric), true),
                  '{payout_amount}', to_jsonb((v_mp_payout_map->>public._finance_marketplace_norm_20260624(elem->>'marketplace'))::numeric), true),
                '{net_settlement}', to_jsonb((v_mp_payout_map->>public._finance_marketplace_norm_20260624(elem->>'marketplace'))::numeric), true),
              '{received_amount}', to_jsonb((v_mp_payout_map->>public._finance_marketplace_norm_20260624(elem->>'marketplace'))::numeric), true)
          else elem
        end
      )
      into v_marketplaces_arr
      from jsonb_array_elements(v_marketplaces_arr) elem;

      v_base := jsonb_set(v_base, '{marketplace_breakdown}', v_marketplaces_arr, true);
      v_base := jsonb_set(v_base, '{by_marketplace}', v_marketplaces_arr, true);
      v_base := jsonb_set(v_base, '{marketplaces}', v_marketplaces_arr, true);
    end if;

    if v_reports_payout > 0 then
      v_payout_total := v_reports_payout;
      v_base := jsonb_set(v_base, '{summary,payout_total}', to_jsonb(v_reports_payout), true);
      v_base := jsonb_set(v_base, '{summary,payout_amount}', to_jsonb(v_reports_payout), true);
      v_base := jsonb_set(v_base, '{summary,net_settlement}', to_jsonb(v_reports_payout), true);
      v_base := jsonb_set(v_base, '{summary,received_amount}', to_jsonb(v_reports_payout), true);
      v_base := jsonb_set(v_base, '{payout_total}', to_jsonb(v_reports_payout), true);
    end if;

    select
      coalesce(sum(coalesce(fi.platform_fee, 0)), 0),
      coalesce(sum(coalesce(fi.commission_fee, 0)), 0),
      coalesce(sum(coalesce(fi.affiliate_fee, 0)), 0),
      coalesce(sum(coalesce(fi.shipping_fee, 0)), 0),
      coalesce(sum(coalesce(fi.discount_amount, 0)), 0),
      coalesce(sum(coalesce(fi.refund_amount, 0)), 0)
    into
      v_sum_platform_fee,
      v_sum_commission_fee,
      v_sum_affiliate_fee,
      v_sum_shipping_fee,
      v_sum_discount_amount,
      v_sum_refund_amount
    from public.marketplace_finance_reports fi
    where fi.tenant_id = v_tenant_id
      and coalesce(fi.settlement_date::date, fi.period_start::date, fi.created_at::date) between v_start and v_end
      and coalesce(fi.report_type, '') <> 'statement'
      and (p_account_id is null or fi.marketplace_account_id = p_account_id)
      and (
        v_marketplace is null
        or public._finance_marketplace_norm_20260624(fi.marketplace) =
           public._finance_marketplace_norm_20260624(v_marketplace)
      );

    v_total_deductions := v_sum_platform_fee + v_sum_commission_fee + v_sum_affiliate_fee + v_sum_shipping_fee + v_sum_discount_amount + v_sum_refund_amount;

    v_base := jsonb_set(v_base, '{deductions}', jsonb_build_object(
      'platform_fee', v_sum_platform_fee,
      'commission_fee', v_sum_commission_fee,
      'affiliate_fee', v_sum_affiliate_fee,
      'shipping_fee', v_sum_shipping_fee,
      'discount_amount', v_sum_discount_amount,
      'refund_amount', v_sum_refund_amount,
      'service_fee', 0,
      'voucher_amount', 0,
      'adjustment_amount', 0,
      'total_deductions', v_total_deductions
    ), true);

    v_base := jsonb_set(v_base, '{fee_breakdown}', jsonb_build_object(
      'platform_fee', v_sum_platform_fee,
      'commission_fee', v_sum_commission_fee,
      'affiliate_fee', v_sum_affiliate_fee,
      'shipping_fee', v_sum_shipping_fee,
      'discount_amount', v_sum_discount_amount,
      'refund_amount', v_sum_refund_amount,
      'service_fee', 0,
      'voucher_amount', 0,
      'adjustment_amount', 0,
      'total_deductions', v_total_deductions
    ), true);
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
      and lower(coalesce(p.status,'active')) not in ('cancelled','canceled','deleted','void','voided','rejected');
  end if;

  with rows as (
    select jsonb_build_object(
      'category', 'Sales / Omzet Marketplace',
      'inflow', coalesce(v_base->'summary'->>'omzet_total', '0')::numeric,
      'outflow', 0,
      'net', coalesce(v_base->'summary'->>'omzet_total', '0')::numeric
    ) as row_item
    union all
    select jsonb_build_object(
      'category', 'HPP Produk',
      'inflow', 0,
      'outflow', v_hpp_total,
      'net', -v_hpp_total
    )
    union all
    select jsonb_build_object(
      'category', 'Operasional',
      'inflow', 0,
      'outflow', v_ops_total,
      'net', -v_ops_total
    )
    union all
    select jsonb_build_object(
      'category', 'Pembelian Stock / PO',
      'inflow', 0,
      'outflow', v_purchase_total,
      'net', -v_purchase_total
    )
  )
  select coalesce(jsonb_agg(row_item), '[]'::jsonb)
  into v_cash_flow
  from rows;

  return jsonb_build_object(
    'summary', jsonb_build_object(
      'omzet_total', coalesce(v_base->'summary'->>'omzet_total', '0')::numeric,
      'gross_sales', coalesce(v_base->'summary'->>'omzet_total', '0')::numeric,
      'gross_total', coalesce(v_base->'summary'->>'omzet_total', '0')::numeric,
      'gross_amount', coalesce(v_base->'summary'->>'omzet_total', '0')::numeric,
      'order_count', coalesce(v_base->'summary'->>'order_count', '0')::numeric,
      'orders_count', coalesce(v_base->'summary'->>'order_count', '0')::numeric,
      'all_orders_count', coalesce(v_base->'summary'->>'order_count', '0')::numeric,
      'payout_total', v_payout_total,
      'payout_amount', v_payout_total,
      'received_amount', v_payout_total,
      'net_settlement', v_payout_total,
      'finance_order_count', coalesce(v_base->'summary'->>'finance_order_count', '0')::numeric,
      'finance_orders_count', coalesce(v_base->'summary'->>'finance_order_count', '0')::numeric,
      'operational_cost', v_ops_total,
      'expense_total', v_ops_total,
      'purchase_total', v_purchase_total,
      'pembelian_total', v_purchase_total,
      'hpp_total', v_hpp_total,
      'total_hpp', v_hpp_total,
      'net_profit', v_payout_total - v_hpp_total - v_ops_total - v_purchase_total,
      'profit', v_payout_total - v_hpp_total - v_ops_total - v_purchase_total,
      'net_margin_percent', case when v_payout_total > 0 then round(((v_payout_total - v_hpp_total - v_ops_total - v_purchase_total) / v_payout_total) * 100, 2) else 0 end,
      'summary_policy', 'omzet_by_order_date_payout_by_settlement_date_v2'
    ),
    'by_marketplace', coalesce(v_base->'by_marketplace', v_base->'marketplace_breakdown', '[]'::jsonb),
    'marketplace_breakdown', coalesce(v_base->'marketplace_breakdown', v_base->'by_marketplace', '[]'::jsonb),
    'marketplaces', coalesce(v_base->'marketplaces', v_base->'by_marketplace', '[]'::jsonb),
    'operational_expenses', v_expenses,
    'expenses', v_expenses,
    'purchases', v_purchases,
    'pembelian', v_purchases,
    'cash_adjustments', coalesce(v_base->'cash_adjustments', '[]'::jsonb),
    'company_cash_adjustments', coalesce(v_base->'cash_adjustments', '[]'::jsonb),
    'cash_flow', v_cash_flow,
    'fee_breakdown', v_fee,
    'deductions', v_fee,
    'source', 'finance_dashboard_snapshot_core_20260625_settlement_payout_v2_protected',
    'ok', true
  );
end;
$function$;
