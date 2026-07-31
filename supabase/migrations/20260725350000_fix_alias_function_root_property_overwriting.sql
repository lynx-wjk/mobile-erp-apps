-- Migration: 20260725350000_fix_alias_function_root_property_overwriting.sql
-- Fixes finance_dashboard_snapshot_alias_20260625 so it reads root properties from j directly without overwriting them with 0s.

CREATE OR REPLACE FUNCTION public.finance_dashboard_snapshot_alias_20260625(
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
  j jsonb;
  s jsonb;
  mp jsonb;
  cf jsonb;
  pl jsonb;
  fee jsonb;
begin
  j := public.finance_dashboard_snapshot_core_20260625(
    p_start, p_end, p_marketplace, p_account_id
  );

  j := public.finance_snapshot_order_omzet_settlement_overlay_20260623(
    j, p_start, p_end, p_marketplace, p_account_id
  );

  s := j;

  mp := coalesce(j->'marketplace_breakdown', j->'by_marketplace', j->'marketplaces');
  if jsonb_typeof(mp) is distinct from 'array' then
    mp := '[]'::jsonb;
  end if;

  cf := coalesce(j->'cash_flow', j->'cashflow', '[]'::jsonb);
  if jsonb_typeof(cf) is distinct from 'array' then
    cf := '[]'::jsonb;
  end if;

  pl := coalesce(j->'profit_loss', j->'profit_loss_breakdown', j->'deduction_breakdown', '[]'::jsonb);
  if jsonb_typeof(pl) is distinct from 'array' then
    pl := '[]'::jsonb;
  end if;

  fee := coalesce(j->'fee_breakdown', '{}'::jsonb);
  if jsonb_typeof(fee) is distinct from 'object' then
    fee := '{}'::jsonb;
  end if;

  j := jsonb_set(j, '{summary}', s, true);

  j := jsonb_set(j, '{by_marketplace}', mp, true);
  j := jsonb_set(j, '{marketplaces}', mp, true);
  j := jsonb_set(j, '{marketplace_breakdown}', mp, true);
  j := jsonb_set(j, '{profit_loss_by_marketplace}', mp, true);

  j := jsonb_set(j, '{cash_flow}', cf, true);
  j := jsonb_set(j, '{cashflow}', cf, true);

  j := jsonb_set(j, '{profit_loss}', pl, true);
  j := jsonb_set(j, '{profit_loss_breakdown}', pl, true);
  j := jsonb_set(j, '{deduction_breakdown}', pl, true);

  j := jsonb_set(j, '{fee_breakdown}', fee, true);

  j := jsonb_set(j, '{approved_purchases}', coalesce(j->'purchases', '[]'::jsonb), true);
  j := jsonb_set(j, '{purchases_approved}', coalesce(j->'purchases', '[]'::jsonb), true);

  if coalesce((s->>'omzet_total')::numeric, 0) > 0 then
    j := jsonb_set(j, '{omzet_total}', coalesce(s->'omzet_total', s->'gross_sales', '0'::jsonb), true);
    j := jsonb_set(j, '{gross_sales}', coalesce(s->'gross_sales', s->'omzet_total', '0'::jsonb), true);
    j := jsonb_set(j, '{gross_total}', coalesce(s->'gross_sales', s->'omzet_total', '0'::jsonb), true);
  end if;

  if coalesce((s->>'payout_total')::numeric, 0) > 0 then
    j := jsonb_set(j, '{payout_total}', coalesce(s->'payout_total', s->'payout_amount', '0'::jsonb), true);
    j := jsonb_set(j, '{payout}', coalesce(s->'payout_total', s->'payout_amount', '0'::jsonb), true);
    j := jsonb_set(j, '{payout_amount}', coalesce(s->'payout_total', s->'payout_amount', '0'::jsonb), true);
    j := jsonb_set(j, '{net_settlement}', coalesce(s->'payout_total', s->'payout_amount', '0'::jsonb), true);
  end if;

  if coalesce((s->>'order_count')::integer, 0) > 0 then
    j := jsonb_set(j, '{order_count}', coalesce(s->'order_count', s->'orders_count', '0'::jsonb), true);
    j := jsonb_set(j, '{orders_count}', coalesce(s->'orders_count', s->'order_count', '0'::jsonb), true);
  end if;

  j := jsonb_set(
    j,
    '{source}',
    to_jsonb((coalesce(j->>'source','finance_dashboard_snapshot') || '+alias_payload_fixed_v4')::text),
    true
  );
  j := jsonb_set(j, '{reconciliation_source}', to_jsonb('alias_payload_fixed_v4'::text), true);

  return j;
end;
$function$;
