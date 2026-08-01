-- Phase 3: Safe Canonical RPC Wrappers
-- This migration creates the canonical database function wrappers that delegate
-- parameters and executions to the stable versioned RPC counterparts.
-- Old/versioned RPCs are NOT dropped.
-- No finance logic, calculations, or return shapes are modified.

-- 1. Wrapper for Customer Dashboard Snapshot
CREATE OR REPLACE FUNCTION public.finance_customer_dashboard_snapshot(
    p_start date DEFAULT NULL::date,
    p_end date DEFAULT NULL::date,
    p_marketplace text DEFAULT NULL::text,
    p_account_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
SECURITY DEFINER
AS $$
BEGIN
    RETURN public.finance_customer_dashboard_snapshot_v24_6_82o(p_start, p_end, p_marketplace, p_account_id);
END;
$$ LANGUAGE plpgsql;

GRANT ALL ON FUNCTION public.finance_customer_dashboard_snapshot(date, date, text, uuid) TO anon;
GRANT ALL ON FUNCTION public.finance_customer_dashboard_snapshot(date, date, text, uuid) TO authenticated;
GRANT ALL ON FUNCTION public.finance_customer_dashboard_snapshot(date, date, text, uuid) TO service_role;

-- 2. Wrapper for SKU Summary Rows
CREATE OR REPLACE FUNCTION public.finance_sku_summary_rows(
    p_start date DEFAULT NULL::date,
    p_end date DEFAULT NULL::date,
    p_marketplace text DEFAULT NULL::text,
    p_account_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
SECURITY DEFINER
AS $$
BEGIN
    RETURN public.finance_sku_summary_rows_v24_6_82e(p_start, p_end, p_marketplace, p_account_id);
END;
$$ LANGUAGE plpgsql;

GRANT ALL ON FUNCTION public.finance_sku_summary_rows(date, date, text, uuid) TO anon;
GRANT ALL ON FUNCTION public.finance_sku_summary_rows(date, date, text, uuid) TO authenticated;
GRANT ALL ON FUNCTION public.finance_sku_summary_rows(date, date, text, uuid) TO service_role;

-- 3. Wrapper for Unpaid SKU Rows
CREATE OR REPLACE FUNCTION public.finance_unpaid_sku_rows(
    p_start date DEFAULT NULL::date,
    p_end date DEFAULT NULL::date,
    p_marketplace text DEFAULT NULL::text,
    p_account_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
SECURITY DEFINER
AS $$
BEGIN
    RETURN public.finance_unpaid_sku_rows_v24_6_82e(p_start, p_end, p_marketplace, p_account_id);
END;
$$ LANGUAGE plpgsql;

GRANT ALL ON FUNCTION public.finance_unpaid_sku_rows(date, date, text, uuid) TO anon;
GRANT ALL ON FUNCTION public.finance_unpaid_sku_rows(date, date, text, uuid) TO authenticated;
GRANT ALL ON FUNCTION public.finance_unpaid_sku_rows(date, date, text, uuid) TO service_role;

-- 4. Wrapper for Marking Orders as No Payout Expected
CREATE OR REPLACE FUNCTION public.finance_mark_no_payout_order(
    p_order_id text,
    p_account_id uuid,
    p_reason text DEFAULT 'manual_no_payout_expected'::text,
    p_note text DEFAULT NULL::text
)
RETURNS jsonb
SECURITY DEFINER
AS $$
BEGIN
    RETURN public.finance_mark_no_payout_order_v24_6_28(p_order_id, p_account_id, p_reason, p_note);
END;
$$ LANGUAGE plpgsql;

GRANT ALL ON FUNCTION public.finance_mark_no_payout_order(text, uuid, text, text) TO anon;
GRANT ALL ON FUNCTION public.finance_mark_no_payout_order(text, uuid, text, text) TO authenticated;
GRANT ALL ON FUNCTION public.finance_mark_no_payout_order(text, uuid, text, text) TO service_role;
