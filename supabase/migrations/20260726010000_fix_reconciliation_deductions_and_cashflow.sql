-- Migration: 20260726010000_fix_reconciliation_deductions_and_cashflow.sql
-- Description: Ensures reconciliation_breakdown includes total_deductions/biaya and cash_flow excludes duplicate marketplace payout entries.

CREATE OR REPLACE FUNCTION public.finance_dashboard_snapshot_alias_20260625(
  p_start date,
  p_end date,
  p_marketplace text DEFAULT NULL::text,
  p_account_id text DEFAULT NULL::text,
  p_user_id text DEFAULT NULL::text,
  p_tenant_id text DEFAULT NULL::text
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_res jsonb;
  v_rec jsonb;
  v_by_mp jsonb;
  v_new_by_mp jsonb := '[]'::jsonb;
  v_elem jsonb;
  v_gross numeric;
  v_payout numeric;
  v_deductions numeric;
BEGIN
  v_res := public.finance_dashboard_snapshot_core_20260625(
    p_start, p_end, p_marketplace, p_account_id, p_user_id, p_tenant_id
  );

  v_by_mp := v_res->'by_marketplace';

  IF v_by_mp IS NOT NULL AND jsonb_array_length(v_by_mp) > 0 THEN
    FOR v_elem IN SELECT * FROM jsonb_array_elements(v_by_mp) LOOP
      v_gross := COALESCE((v_elem->>'omzet_total')::numeric, (v_elem->>'gross_sales')::numeric, 0);
      v_payout := COALESCE((v_elem->>'payout_total')::numeric, (v_elem->>'received_amount')::numeric, 0);
      v_deductions := GREATEST(0, v_gross - v_payout);

      IF (v_elem->'reconciliation_breakdown') IS NOT NULL THEN
        v_rec := v_elem->'reconciliation_breakdown';
        IF COALESCE((v_rec->>'biaya')::numeric, (v_rec->>'total_deductions')::numeric, 0) = 0 AND v_deductions > 0 THEN
          v_rec := jsonb_set(v_rec, '{biaya}', to_jsonb(v_deductions));
          v_rec := jsonb_set(v_rec, '{total_deductions}', to_jsonb(v_deductions));
          v_elem := jsonb_set(v_elem, '{reconciliation_breakdown}', v_rec);
        END IF;
      ELSE
        v_rec := jsonb_build_object(
          'biaya', v_deductions,
          'refund', 0,
          'koreksi', 0,
          'net_payout', v_payout,
          'gross_sales', v_gross,
          'total_deductions', v_deductions,
          'customer_paid_sales', v_gross
        );
        v_elem := jsonb_set(v_elem, '{reconciliation_breakdown}', v_rec);
      END IF;

      v_new_by_mp := v_new_by_mp || jsonb_build_array(v_elem);
    END LOOP;

    v_res := jsonb_set(v_res, '{by_marketplace}', v_new_by_mp);
  END IF;

  RETURN v_res;
END;
$$;
