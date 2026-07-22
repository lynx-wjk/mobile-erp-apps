-- Migration: Fix timeout limits for base functions

ALTER FUNCTION public.finance_customer_dashboard_snapshot_v24_6_82o_base_20260623(date, date, text, uuid)
    SET statement_timeout TO '30s';

ALTER FUNCTION public.finance_customer_dashboard_snapshot_v24_6_82o_b20260608(date, date, text, uuid)
    SET statement_timeout TO '30s';
