-- CLEANUP_UNUSED_FUNCTIONS.sql
-- Post-baseline cleanup candidates for Patch40.
--
-- Run this only after:
-- 1) CLEAN_BASELINE_FINANCE_ORDER.sql has been applied successfully.
-- 2) Patch40 Flutter smoke tests pass for finance tabs, SKU detail, order pull,
--    refresh payout, auto finance job, and job monitor.
-- 3) A fresh Flutter source scan confirms these names are no longer called.
--
-- Direct cleanup only; no new version suffixes are introduced.
-- Drops are intentionally conservative and avoid every RPC still referenced by
-- the active Patch40 fallback lists.

begin;

-- ---------------------------------------------------------------------------
-- Active names intentionally kept
-- ---------------------------------------------------------------------------
-- finance_customer_dashboard_snapshot_v24_6_82o
-- finance_sku_summary_rows_v24_6_82e, v24_6_82c, v24_6_82b, v24_6_82, v24_6_80m
-- finance_sku_order_details_v24_6_80m, v24_6_80l
-- finance_sku_order_detail_lines_v24_6_82e, v24_6_82b, v24_6_82, v24_6_80m
-- finance_unpaid_sku_rows_v24_6_82e, v24_6_82b, v24_6_82, v24_6_80j,
--   v24_6_80i, v24_6_80h, v24_6_80g, v24_6_80b, v24_6_80, v24_6_79
-- finance_anomaly_search_v24_6_82e, v24_6_80m, v24_6_80l, v24_6_80j,
--   v24_6_80i, v24_6_80g, v24_6_80e, v24_6_80c, v24_6_80b, v24_6_80,
--   v24_6_79, v24_6_78, v24_6_58, v24_6_57, v24_6_56, v24_6_55,
--   v24_6_41, v24_6_31, v24_6_28
-- finance_list_manual_operational_expenses_v24_6_80m, v24_6_79, v24_6_78, v24_6_77
-- finance_insert_manual_operational_expense_v24_6_79, v24_6_78, v24_6_77, v24_6_29
-- finance_update_manual_operational_expense_v24_6_79, v24_6_78, v24_6_77, unsuffixed
-- finance_delete_manual_operational_expense_v24_6_79, v24_6_78, v24_6_77, unsuffixed
-- marketplace_job_monitor_snapshot_v24_6_9
-- marketplace_job_reset_stuck_v24_6_9
-- marketplace_variant_hpp_list_v24_6_49, v24_6_47, v24_6_44, v24_6_28
-- marketplace_variant_hpp_upsert_bulk_v24_6_49, v24_6_47, v24_6_28

-- ---------------------------------------------------------------------------
-- Obsolete finance dashboard snapshot versions
-- ---------------------------------------------------------------------------
drop function if exists public.finance_customer_dashboard_snapshot(p_start date, p_end date);
drop function if exists public.finance_customer_dashboard_snapshot(p_start_date date, p_end_date date, p_marketplace_filter text, p_account_id_filter uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v3(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v4(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v5(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v6(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v7(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v8(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v9(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v10(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v11(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v22(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v23(p_start_date date, p_end_date date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v25(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v26(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v27(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v28(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v29(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v30(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_41(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_41(p_start date, p_end date, p_marketplace text, p_account_id uuid, p_store_name text);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_44(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_46(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_49(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_51(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_52(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_53(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_53(p_start date, p_end date, p_marketplace text, p_account_id uuid, p_store_name text);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_57(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_57(p_start date, p_end date, p_marketplace text, p_account_id uuid, p_store_name text);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_58(p_start date, p_end date, p_marketplace text, p_account_id uuid, p_store_name text);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_60(p_start date, p_end date, p_marketplace text, p_account_id uuid, p_store_name text);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_65(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_66(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_66(p_start date, p_end date, p_marketplace text, p_account_id uuid, p_store_name text);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_67(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_67(p_start date, p_end date, p_marketplace text, p_account_id uuid, p_store_name text);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_71(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_73(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_78(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_79(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_80b(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_80c(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_80e(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_80g(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_80i(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_80j(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_80k(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_80l(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_80m(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_82(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_82b(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_82c(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_82d(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_82e(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_82f(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_82g(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_82h(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_82i(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_82k(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_82l(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_82m(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_82n(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_82p(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_82q(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_customer_dashboard_snapshot_v24_6_89(p_start_date date, p_end_date date, p_marketplace text, p_account_id uuid);

-- ---------------------------------------------------------------------------
-- Obsolete SKU/detail/anomaly versions not referenced by Patch40
-- ---------------------------------------------------------------------------
drop function if exists public.finance_sku_order_detail_lines_v24_6_82o(p_start date, p_end date, p_marketplace text, p_account_id uuid, p_sku text, p_limit integer, p_offset integer);
drop function if exists public.finance_sku_order_detail_lines_v24_6_82q(p_start date, p_end date, p_marketplace text, p_account_id uuid, p_sku text, p_limit integer, p_offset integer);
drop function if exists public.finance_sku_order_detail_lines_v24_6_82q_v21b_internal(p_start date, p_end date, p_marketplace text, p_account_id uuid, p_sku text, p_limit integer, p_offset integer);
drop function if exists public.finance_sku_order_detail_lines_v24_6_85(p_start date, p_end date, p_marketplace text, p_account_id uuid, p_sku text, p_limit integer, p_offset integer);
drop function if exists public.finance_sku_order_detail_lines_v24_6_86(p_start date, p_end date, p_marketplace text, p_account_id uuid, p_sku text, p_limit integer, p_offset integer);
drop function if exists public.finance_sku_order_details_v22(p_start date, p_end date, p_marketplace text, p_account_id uuid, p_product_id uuid, p_local_sku text, p_marketplace_sku text, p_limit integer, p_offset integer);
drop function if exists public.finance_sku_order_details_v24_6_80k(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_sku_summary_rows_v24_6_82d(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_unpaid_sku_rows_v24_6_78(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_unpaid_sku_rows_v24_6_80c(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_unpaid_sku_rows_v24_6_80d(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_unpaid_sku_rows_v24_6_80e(p_start date, p_end date, p_marketplace text, p_account_id uuid);
drop function if exists public.finance_unpaid_sku_rows_v24_6_80f(p_start date, p_end date, p_marketplace text, p_account_id uuid);

drop function if exists public.finance_anomaly_search_v24_6_30(p_start date, p_end date, p_marketplace text, p_account_id uuid, p_search text, p_status text, p_page integer, p_page_size integer);
drop function if exists public.finance_anomaly_search_v24_6_53(p_start date, p_end date, p_marketplace text, p_account_id uuid, p_search text, p_status text, p_page integer, p_page_size integer);
drop function if exists public.finance_anomaly_search_v24_6_60(p_start date, p_end date, p_marketplace text, p_account_id uuid, p_search text, p_status text, p_page integer, p_page_size integer);
drop function if exists public.finance_anomaly_search_v24_6_80d(p_start date, p_end date, p_marketplace text, p_account_id uuid, p_search text, p_status text, p_page integer, p_page_size integer);
drop function if exists public.finance_anomaly_search_v24_6_80f(p_start date, p_end date, p_marketplace text, p_account_id uuid, p_search text, p_status text, p_page integer, p_page_size integer);
drop function if exists public.finance_anomaly_search_v24_6_80h(p_start date, p_end date, p_marketplace text, p_account_id uuid, p_search text, p_status text, p_page integer, p_page_size integer);
drop function if exists public.finance_anomaly_search_v24_6_80k(p_start date, p_end date, p_marketplace text, p_account_id uuid, p_search text, p_status text, p_page integer, p_page_size integer);
drop function if exists public.finance_anomaly_search_v24_6_82(p_start date, p_end date, p_marketplace text, p_account_id uuid, p_search text, p_status text, p_page integer, p_page_size integer);
drop function if exists public.finance_anomaly_search_v24_6_82b(p_start date, p_end date, p_marketplace text, p_account_id uuid, p_search text, p_status text, p_page integer, p_page_size integer);
drop function if exists public.finance_anomaly_search_v24_6_85(p_start date, p_end date, p_marketplace text, p_account_id uuid, p_search text, p_status text, p_page integer, p_page_size integer);

-- ---------------------------------------------------------------------------
-- Obsolete manual expense/order monitor/HPP/refund versions not referenced by Patch40
-- ---------------------------------------------------------------------------
drop function if exists public.finance_insert_manual_operational_expense(p_category text, p_amount numeric, p_expense_date date, p_note text);
drop function if exists public.finance_insert_manual_operational_expense_v24_6_35(p_category text, p_amount numeric, p_expense_date date, p_note text);
drop function if exists public.finance_insert_manual_operational_expense_v24_6_36(p_category text, p_amount numeric, p_expense_date date, p_note text);
drop function if exists public.finance_insert_manual_operational_expense_v24_6_38(p_category text, p_amount numeric, p_expense_date date, p_note text);
drop function if exists public.finance_insert_manual_operational_expense_v24_6_61(p_category text, p_amount numeric, p_expense_date date, p_note text);
drop function if exists public.marketplace_job_monitor_snapshot_v24_6_4();
drop function if exists public.marketplace_job_reset_stuck_v24_6_4(p_kind text, p_retry_failed boolean);
drop function if exists public.marketplace_variant_hpp_list_v24_6_46(p_account_id uuid, p_search text, p_missing_only boolean, p_page integer, p_page_size integer);
drop function if exists public.marketplace_refund_cancel_review_v24_6_30(p_start date, p_end date, p_account_id uuid, p_search text, p_status text, p_page integer, p_page_size integer);
drop function if exists public.marketplace_refund_cancel_review_v24_6_35(p_account_id uuid, p_search text, p_page integer, p_page_size integer);

commit;
