-- Phase 3: Remaining Safe Canonical RPC Wrappers
-- This migration creates additional canonical database function wrappers that delegate
-- parameters and executions to the stable versioned RPC counterparts.
-- Old/versioned RPCs are NOT dropped.
-- High-risk sync and operational queue RPCs left untouched.

-- 1. Wrapper for Checking Latest Runtime Progress
CREATE OR REPLACE FUNCTION public.finance_get_latest_runtime_progress()
RETURNS jsonb
SECURITY DEFINER
AS $$
BEGIN
    RETURN public.finance_get_latest_runtime_progress_v24_6_3();
END;
$$ LANGUAGE plpgsql;

GRANT ALL ON FUNCTION public.finance_get_latest_runtime_progress() TO anon;
GRANT ALL ON FUNCTION public.finance_get_latest_runtime_progress() TO authenticated;
GRANT ALL ON FUNCTION public.finance_get_latest_runtime_progress() TO service_role;

-- 2. Wrapper for Listing Manual Operational Expenses
CREATE OR REPLACE FUNCTION public.finance_list_manual_operational_expenses(
    p_start date DEFAULT NULL::date,
    p_end date DEFAULT NULL::date,
    p_marketplace text DEFAULT NULL::text,
    p_account_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
SECURITY DEFINER
AS $$
BEGIN
    RETURN public.finance_list_manual_operational_expenses_v24_6_80m(p_start, p_end, p_marketplace, p_account_id);
END;
$$ LANGUAGE plpgsql;

GRANT ALL ON FUNCTION public.finance_list_manual_operational_expenses(date, date, text, uuid) TO anon;
GRANT ALL ON FUNCTION public.finance_list_manual_operational_expenses(date, date, text, uuid) TO authenticated;
GRANT ALL ON FUNCTION public.finance_list_manual_operational_expenses(date, date, text, uuid) TO service_role;
