-- DRAFT ONLY: DO NOT RUN THIS ON PRODUCTION DIRECTLY UNTIL ACTIVE PHASE 3 IS APPROVED.
-- This file defines the canonical wrapper functions. They act as forwarding functions
-- that forward parameters directly to the versioned RPC counterparts.
-- Note: This ensures backward-compatibility and zero destructive changes during migration.

-- 1. Wrapper for Customer Dashboard Snapshot
CREATE OR REPLACE FUNCTION public.finance_customer_dashboard_snapshot(
    p_start_date date,
    p_end_date date
)
RETURNS jsonb
SECURITY DEFINER
AS $$
BEGIN
    -- Forward execution to the latest stable versioned snapshot function
    RETURN public.finance_customer_dashboard_snapshot_v24_6_82o(p_start_date, p_end_date);
END;
$$ LANGUAGE plpgsql;

-- 2. Wrapper for SKU Summary Rows
CREATE OR REPLACE FUNCTION public.finance_sku_summary_rows(
    p_filters jsonb
)
RETURNS SETOF jsonb
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY 
    SELECT * FROM public.finance_sku_summary_rows_v24_6_82e(p_filters);
END;
$$ LANGUAGE plpgsql;

-- 3. Wrapper for Unpaid SKU Rows
CREATE OR REPLACE FUNCTION public.finance_unpaid_sku_rows(
    p_filters jsonb
)
RETURNS SETOF jsonb
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY 
    SELECT * FROM public.finance_unpaid_sku_rows_v24_6_82e(p_filters);
END;
$$ LANGUAGE plpgsql;

-- 4. Wrapper for Runtime Progress Tracker
CREATE OR REPLACE FUNCTION public.finance_get_latest_runtime_progress()
RETURNS jsonb
SECURITY DEFINER
AS $$
BEGIN
    RETURN public.finance_get_latest_runtime_progress_v24_6_3();
END;
$$ LANGUAGE plpgsql;

-- 5. Wrapper for Upserting Runtime Progress
CREATE OR REPLACE FUNCTION public.finance_upsert_runtime_progress(
    p_data jsonb
)
RETURNS void
SECURITY DEFINER
AS $$
BEGIN
    PERFORM public.finance_upsert_runtime_progress_v24_6_3(p_data);
END;
$$ LANGUAGE plpgsql;

-- 6. Wrapper for Marking Orders as Unpaid
CREATE OR REPLACE FUNCTION public.finance_mark_no_payout_order(
    p_order_id text
)
RETURNS void
SECURITY DEFINER
AS $$
BEGIN
    PERFORM public.finance_mark_no_payout_order_v24_6_28(p_order_id);
END;
$$ LANGUAGE plpgsql;
