# Obsolete RPC Cleanup Report

Audit date: 2026-05-28 WIB  
Cleanup file: `CLEANUP_UNUSED_FUNCTIONS_AFTER_PASS.sql`  
Status: prepared only. Do not apply until finance/order smoke tests pass in the app.

## Gate

Cleanup was not executed. The SQL file contains only `DROP FUNCTION IF EXISTS ...` statements and does not drop tables or delete business data.

Fresh source scan after fallback cleanup confirms these active RPC names are not present in cleanup `DROP FUNCTION` statements:

- `finance_customer_dashboard_snapshot_v24_6_82o`
- `finance_fix_exact_cache_settled_hpp_v24_6_82q`
- `finance_sku_summary_rows_v24_6_82e`
- `finance_sku_order_detail_lines_v24_6_82e`
- `finance_unpaid_sku_rows_v24_6_82e`
- `finance_anomaly_search_v24_6_82e`
- `finance_list_manual_operational_expenses_v24_6_80m`
- `finance_insert_manual_operational_expense_v24_6_79`
- `finance_update_manual_operational_expense_v24_6_79`
- `finance_delete_manual_operational_expense_v24_6_79`
- `marketplace_job_monitor_snapshot_v24_6_9`
- `marketplace_job_reset_stuck_v24_6_9`
- `marketplace_refund_cancel_review_v24_6_42`
- active order scan/HPP mapping RPCs

Conflict check result: no active RPC names were found in cleanup drop statements.

## Cleanup Candidates Added Or Confirmed

These are obsolete because active PATCH40 source no longer calls them after the direct baseline cleanup.

### Finance SKU Summary

- `finance_sku_summary_rows_v24_6_80m(p_start date, p_end date, p_marketplace text, p_account_id uuid)`
- `finance_sku_summary_rows_v24_6_82(p_start date, p_end date, p_marketplace text, p_account_id uuid)`
- `finance_sku_summary_rows_v24_6_82b(p_start date, p_end date, p_marketplace text, p_account_id uuid)`
- `finance_sku_summary_rows_v24_6_82c(p_start date, p_end date, p_marketplace text, p_account_id uuid)`

### Finance SKU Detail

- `finance_sku_order_details_v24_6_80l(p_start date, p_end date, p_marketplace text, p_account_id uuid)`
- `finance_sku_order_details_v24_6_80m(p_start date, p_end date, p_marketplace text, p_account_id uuid)`
- `finance_sku_order_detail_lines_v24_6_80m(p_start date, p_end date, p_marketplace text, p_account_id uuid, p_sku text, p_limit integer)`
- `finance_sku_order_detail_lines_v24_6_82(p_start date, p_end date, p_marketplace text, p_account_id uuid, p_sku text, p_limit integer, p_offset integer)`
- `finance_sku_order_detail_lines_v24_6_82b(p_start date, p_end date, p_marketplace text, p_account_id uuid, p_sku text, p_limit integer, p_offset integer)`
- older already-listed detail versions such as `_82o`, `_82q`, `_85`, `_86`

### Finance Unpaid SKU

- `finance_unpaid_sku_rows_v24_6_79(p_start date, p_end date, p_marketplace text, p_account_id uuid)`
- `finance_unpaid_sku_rows_v24_6_80(p_start date, p_end date, p_marketplace text, p_account_id uuid)`
- `finance_unpaid_sku_rows_v24_6_80b(p_start date, p_end date, p_marketplace text, p_account_id uuid)`
- `finance_unpaid_sku_rows_v24_6_80g(p_start date, p_end date, p_marketplace text, p_account_id uuid)`
- `finance_unpaid_sku_rows_v24_6_80h(p_start date, p_end date, p_marketplace text, p_account_id uuid)`
- `finance_unpaid_sku_rows_v24_6_80i(p_start date, p_end date, p_marketplace text, p_account_id uuid)`
- `finance_unpaid_sku_rows_v24_6_80j(p_start date, p_end date, p_marketplace text, p_account_id uuid)`
- `finance_unpaid_sku_rows_v24_6_82(p_start date, p_end date, p_marketplace text, p_account_id uuid)`
- `finance_unpaid_sku_rows_v24_6_82b(p_start date, p_end date, p_marketplace text, p_account_id uuid)`
- older already-listed unpaid versions such as `_78`, `_80c`, `_80d`, `_80e`, `_80f`

### Finance Anomaly Search

- `finance_anomaly_search_v24_6_28(...)`
- `finance_anomaly_search_v24_6_31(...)`
- `finance_anomaly_search_v24_6_41(...)`
- `finance_anomaly_search_v24_6_57(...)`
- `finance_anomaly_search_v24_6_58(...)`
- `finance_anomaly_search_v24_6_78(...)`
- `finance_anomaly_search_v24_6_79(...)`
- `finance_anomaly_search_v24_6_80(...)`
- `finance_anomaly_search_v24_6_80b(...)`
- `finance_anomaly_search_v24_6_80c(...)`
- `finance_anomaly_search_v24_6_80e(...)`
- `finance_anomaly_search_v24_6_80g(...)`
- `finance_anomaly_search_v24_6_80i(...)`
- `finance_anomaly_search_v24_6_80j(...)`
- `finance_anomaly_search_v24_6_80l(...)`
- `finance_anomaly_search_v24_6_80m(...)`
- `finance_anomaly_search_v24_6_82(...)`
- `finance_anomaly_search_v24_6_82b(...)`
- older already-listed anomaly versions such as `_30`, `_53`, `_60`, `_80d`, `_80f`, `_80h`, `_80k`, `_85`

All anomaly cleanup candidates have the active Flutter search signature:

`p_start date, p_end date, p_marketplace text, p_account_id uuid, p_search text, p_status text, p_page integer, p_page_size integer`

### Manual Operational Expense

- `finance_list_manual_operational_expenses_v24_6_77(p_start date, p_end date)`
- `finance_list_manual_operational_expenses_v24_6_78(p_start date, p_end date, p_marketplace text, p_account_id uuid)`
- `finance_list_manual_operational_expenses_v24_6_79(p_start date, p_end date, p_marketplace text, p_account_id uuid)`
- `finance_insert_manual_operational_expense_v24_6_29(p_expense_date date, p_category text, p_amount numeric, p_note text)`
- `finance_insert_manual_operational_expense_v24_6_78(p_category text, p_amount numeric, p_expense_date date, p_note text)`
- `finance_update_manual_operational_expense(p_expense_id uuid, p_amount numeric, p_category text, p_expense_date date, p_note text)`
- `finance_update_manual_operational_expense(p_expense_id uuid, p_category text, p_amount numeric, p_expense_date date, p_note text)`
- `finance_update_manual_operational_expense_v24_6_78(p_expense_id uuid, p_category text, p_amount numeric, p_expense_date date, p_note text)`
- `finance_delete_manual_operational_expense(p_expense_id uuid)`
- `finance_delete_manual_operational_expense_v24_6_78(p_expense_id uuid)`

Active Flutter now calls only the direct baseline manual expense names:

- `finance_list_manual_operational_expenses_v24_6_80m`
- `finance_insert_manual_operational_expense_v24_6_79`
- `finance_update_manual_operational_expense_v24_6_79`
- `finance_delete_manual_operational_expense_v24_6_79`

### Refund / Cancel Monitor

- `marketplace_refund_cancel_review_v24_6_30(...)`
- `marketplace_refund_cancel_review_v24_6_35(p_account_id uuid, p_search text, p_page integer, p_page_size integer)`
- `marketplace_refund_cancel_review_v24_6_36(p_account_id uuid, p_search text, p_page integer, p_page_size integer)`
- `marketplace_refund_cancel_review_v24_6_36(p_start date, p_end date, p_marketplace text, p_account_id uuid, p_search text, p_action text, p_page integer, p_page_size integer)`
- `marketplace_refund_cancel_review_v24_6_39(p_start date, p_end date, p_marketplace text, p_account_id uuid, p_search text, p_action text, p_page integer, p_page_size integer)`
- `marketplace_refund_cancel_review_v24_6_41(p_start date, p_end date, p_marketplace text, p_account_id uuid, p_search text, p_action text, p_page integer, p_page_size integer)`

Active Flutter now calls only:

- `marketplace_refund_cancel_review_v24_6_42`

## Apply Command, Later Only

Run this only after app smoke tests pass:

```powershell
supabase db query --linked --file CLEANUP_UNUSED_FUNCTIONS_AFTER_PASS.sql -o json
```

Immediately after cleanup, re-run the finance/order validation queries for today, 7 days, current month, 30 days, SKU detail, anomaly page 1, order job monitor, and queue state.
