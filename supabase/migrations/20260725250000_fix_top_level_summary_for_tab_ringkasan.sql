-- Migration: 20260725250000_fix_top_level_summary_for_tab_ringkasan.sql
-- Ensures top-level summary object and fields are fully populated for Tab Ringkasan in Flutter UI

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
  v_start date := coalesce(p_start, current_date - 30);
  v_end date := coalesce(p_end, current_date);
  v_tenant_id uuid := coalesce(
    (select u.tenant_id from public.users u where u.user_id = auth.uid() limit 1),
    public.app_current_tenant_id_or_default(),
    (select tenant_id from public.users where tenant_id is not null limit 1)
  );
  v_marketplace text := lower(trim(coalesce(p_marketplace, '')));
  v_res jsonb;

  v_total_orders integer := 0;
  v_gross_sales numeric := 0;
  v_payout_total numeric := 0;
  v_total_deductions numeric := 0;
  v_net_profit numeric := 0;
  v_margin_pct numeric := 0;
  v_mp_arr jsonb := '[]'::jsonb;
  v_summary_obj jsonb;
begin
  if v_marketplace in ('all', 'semua', 'semua platform', '-') then
    v_marketplace := null;
  else
    v_marketplace := case
      when lower(coalesce(p_marketplace, '')) ~ 'tiktok' then 'tiktok_shop'
      when lower(coalesce(p_marketplace, '')) ~ 'shopee' then 'shopee'
      else lower(regexp_replace(coalesce(p_marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
    end;
  end if;

  with valid_orders as (
    select
      o.tenant_id,
      o.marketplace_account_id,
      o.marketplace_order_id,
      coalesce(nullif(o.external_order_id, ''), nullif(o.order_sn, ''), o.marketplace_order_id::text) as order_key,
      coalesce(o.paid_amount, o.gross_amount, 0)::numeric as gross_amount,
      case
        when lower(coalesce(o.marketplace, '')) ~ 'tiktok' then 'tiktok_shop'
        when lower(coalesce(o.marketplace, '')) ~ 'shopee' then 'shopee'
        else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end as marketplace_clean
    from public.marketplace_orders o
    where o.tenant_id = v_tenant_id
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and (coalesce(o.order_created_at, o.created_at) at time zone 'Asia/Jakarta')::date between v_start and v_end
      and not (lower(concat_ws(' ', o.order_status, o.status, o.raw_order->>'status')) ~ '(cancel|canceled|cancelled|batal|dibatalkan|returned|return|refund|rts|gagal|failed|closed)')
      and (
        v_marketplace is null or
        case
          when lower(coalesce(o.marketplace, '')) ~ 'tiktok' then 'tiktok_shop'
          when lower(coalesce(o.marketplace, '')) ~ 'shopee' then 'shopee'
          else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end = v_marketplace
      )
  ),
  finance_payout as (
    select
      fr.tenant_id,
      coalesce(nullif(fr.order_id, ''), fr.marketplace_order_id::text) as order_key,
      sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0)) as payout_total
    from public.marketplace_finance_reports fr
    where fr.tenant_id = v_tenant_id
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
    group by fr.tenant_id, 1, 2
  ),
  matched as (
    select
      vo.marketplace_clean,
      vo.gross_amount,
      coalesce(fp.payout_total, 0) as payout_total
    from valid_orders vo
    left join finance_payout fp on fp.order_key = vo.order_key
  )
  select
    count(*)::integer,
    coalesce(sum(gross_amount), 0)::numeric,
    coalesce(sum(payout_total), 0)::numeric,
    greatest(coalesce(sum(gross_amount), 0) - coalesce(sum(payout_total), 0), 0)::numeric
  into v_total_orders, v_gross_sales, v_payout_total, v_total_deductions
  from matched;

  v_summary_obj := jsonb_build_object(
    'order_count', v_total_orders,
    'orders_count', v_total_orders,
    'finance_order_count', v_total_orders,
    'finance_orders_count', v_total_orders,
    'omzet_total', v_gross_sales,
    'gross_sales', v_gross_sales,
    'gross_total', v_gross_sales,
    'gross_amount', v_gross_sales,
    'payout_total', v_payout_total,
    'payout', v_payout_total,
    'payout_amount', v_payout_total,
    'net_settlement', v_payout_total,
    'received_amount', v_payout_total,
    'total_deductions', v_total_deductions,
    'biaya_total', v_total_deductions,
    'biaya', v_total_deductions,
    'deductions', v_total_deductions
  );

  v_res := jsonb_build_object(
    'ok', true,
    'source', 'finance_dashboard_snapshot_core_20260625_fixed_v4',
    'summary', v_summary_obj,
    'order_count', v_total_orders,
    'orders_count', v_total_orders,
    'finance_order_count', v_total_orders,
    'finance_orders_count', v_total_orders,
    'omzet_total', v_gross_sales,
    'gross_sales', v_gross_sales,
    'gross_total', v_gross_sales,
    'gross_amount', v_gross_sales,
    'payout_total', v_payout_total,
    'payout', v_payout_total,
    'payout_amount', v_payout_total,
    'net_settlement', v_payout_total,
    'received_amount', v_payout_total,
    'biaya_total', v_total_deductions,
    'biaya', v_total_deductions,
    'deductions', v_total_deductions,
    'marketplace_breakdown', '[]'::jsonb,
    'by_marketplace', '[]'::jsonb,
    'marketplaces', '[]'::jsonb,
    'profit_loss_by_marketplace', '[]'::jsonb,
    'profit_loss', '[]'::jsonb,
    'cashflow', '[]'::jsonb,
    'cash_flow', '[]'::jsonb
  );

  -- Apply non-destructive HPP & per-marketplace overlay
  return public.finance_snapshot_order_omzet_settlement_overlay_20260623(v_res, v_start, v_end, p_marketplace, p_account_id);
end;
$function$;
