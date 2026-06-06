# Active PATCH40 Finance/Marketplace RPC Report

Audit date: 2026-05-28 WIB  
Project: `tllknfqoczarogizheal`  
Status: `CLEAN_BASELINE_FINANCE_ORDER.sql` applied. Cleanup SQL is prepared but not applied.

## Scope

Scanned active Flutter source under:

- `lib/features/finance/**`
- `lib/features/marketplace/**`
- `lib/**/repositories/**`
- `lib/**/services/**`
- `lib/**/data_sources/**`
- related dashboard/auth/stock entry points that call finance or marketplace RPCs

Forbidden backend patterns reconfirmed for the direct baseline: no `marketplace_order_pull_auto_settings`, no `marketplace_finance_sync_jobs`, no `v90/v91/v92`, no bridge RPCs, no table drops, and no business-data deletes.

## Backend Validation Snapshot

Validation was run after applying `CLEAN_BASELINE_FINANCE_ORDER.sql`.

| Gate | Result |
|---|---|
| Finance anomaly aggregate, today | ok, raw negative payout matched RPC and snapshot: count `0`, total `0` |
| Finance anomaly aggregate, 7 days | ok, raw negative payout matched RPC and snapshot: count `199`, total `-3995690` |
| Finance anomaly aggregate, current month | ok, raw negative payout matched RPC and snapshot: count `199`, total `-3995690` |
| Finance anomaly aggregate, 30 days | ok, raw negative payout matched RPC and snapshot: count `199`, total `-3995690` |
| SKU detail sample | ok, returned `order_id`, `resi`, `order_date`, `gross`, `payout`, `status`, `qty`, `local_sku`, `marketplace_sku`, `hpp`, `margin` |
| HPP cache last 7 days | ok, missing HPP count `0` for 2026-05-22 through 2026-05-28 |
| Job monitor | ok, compact `order_counts` and `finance_counts` returned |
| Auto order queue | ok, pending `0`, running `0`, future window `0`, future year `0` |
| Latest order data | latest order time in DB after validation: `28/05/2026 01:17:45 WIB`; latest created row: `28/05/2026 01:20:07 WIB` |

## Finance RPCs

| Module/tab | Exact RPC/function | File:line | Arguments sent | Response fields used |
|---|---|---:|---|---|
| Finance auto job | `finance_get_auto_sync_setting` | `lib/features/finance/presentation/finance_report_page.dart:141` | none | `auto_finance_sync_enabled`, `last_auto_run_message`, `last_auto_run_at` |
| Finance auto job | `finance_set_auto_sync_enabled` | `lib/features/finance/presentation/finance_report_page.dart:173` | `p_enabled`, `p_interval_minutes=10` | `auto_finance_sync_enabled`, `last_auto_run_message`, `last_auto_run_at` |
| Finance Ringkasan, Marketplace, SKU, Arus Kas, Biaya, Laba Rugi, Anomali | `finance_customer_dashboard_snapshot_v24_6_82o` | `lib/features/finance/presentation/finance_report_page.dart:206`; dashboard also at `lib/features/dashboard/presentation/dashboard_page.dart:340` | Flutter maps to `p_start_date`, `p_end_date`, `p_marketplace_filter`, `p_account_id_filter` | `summary`, `anomaly_aggregates`, `by_marketplace`, `by_sku`, `cash_flow`, `expenses`, `approved_purchases`, `profit_loss_breakdown`, `anomalies`, `sources`, last order/finance timestamps |
| Finance cache/HPP refresh | `finance_fix_exact_cache_settled_hpp_v24_6_82q` | `lib/features/finance/presentation/finance_report_page.dart:262` | `p_start`, `p_end`, `p_marketplace`, `p_account_id` | `ok`, `message`, `summary`, cache refresh counts |
| Finance Biaya | `finance_list_manual_operational_expenses_v24_6_80m` | `lib/features/finance/presentation/finance_report_page.dart:408` | `p_start`, `p_end`, `p_marketplace`, `p_account_id` | `rows[]`: expense id, category, amount, note, source, expense date, timestamps |
| Finance SKU | `finance_sku_summary_rows_v24_6_82e` | `lib/features/finance/presentation/finance_report_page.dart:445` | `p_start`, `p_end`, `p_marketplace`, `p_account_id` | `rows[]`: SKU, qty totals, settled/pending qty, gross, payout, HPP, margin, product/variant fields |
| Finance SKU detail | `finance_sku_order_detail_lines_v24_6_82e` | `lib/features/finance/presentation/finance_report_page.dart:484` | `p_start`, `p_end`, `p_marketplace`, `p_account_id`, `p_sku`, `p_limit=200`, `p_offset=0` | `rows[]`: `order_id`, `resi`/tracking, `order_date`, marketplace, product, variant, `local_sku`, `marketplace_sku`, qty, gross, payout, payout status, HPP, margin |
| Finance SKU unpaid | `finance_unpaid_sku_rows_v24_6_82e` | `lib/features/finance/presentation/finance_report_page.dart:537` | `p_start`, `p_end`, `p_marketplace=null`, `p_account_id=null` | `rows[]`: SKU, qty, gross, payout, HPP, status |
| Finance runtime progress save | `finance_upsert_runtime_progress_v24_6_3` | `lib/features/finance/presentation/finance_report_page.dart:692` | `p_status`, `p_title`, `p_lines`, `p_checked`, `p_success`, `p_failed`, `p_skipped` | no returned fields required |
| Finance runtime progress read | `finance_get_latest_runtime_progress_v24_6_3` | `lib/features/finance/presentation/finance_report_page.dart:718` | none | `message`, progress counters/timestamps |
| Finance purchases | `list_purchase_requests` | `lib/features/finance/presentation/finance_report_page.dart:1783` | none | purchase request rows used for approved purchase expense display |
| Finance Anomali | `finance_anomaly_search_v24_6_82e` | `lib/features/finance/presentation/finance_report_page.dart:3032` | `p_start`, `p_end`, `p_marketplace`, `p_account_id`, `p_search`, `p_status`, `p_page`, `p_page_size` | `rows`, `total`, `page`, `page_size`, `summary`/`aggregates` fields: `negative_payout_count`, `negative_payout_total`, `missing_payout_count`, cancel/refund/return totals |
| Finance Anomali action | `finance_unmark_no_payout_order_v24_6_28` | `lib/features/finance/presentation/finance_report_page.dart:3268` | `p_order_id`, `p_account_id` | no returned fields required |
| Finance Anomali action | `finance_auto_mark_cancel_no_payout_v24_6_28` | `lib/features/finance/presentation/finance_report_page.dart:3313` | `p_start`, `p_end`, `p_account_id` | `marked` |
| Finance Anomali action | `finance_mark_no_payout_order_v24_6_28` | `lib/features/finance/presentation/finance_report_page.dart:3380` | `p_order_id`, `p_account_id`, `p_reason`, `p_note` | no returned fields required |
| Pull Finance / reset display | `marketplace_reset_order_finance_data` | `lib/features/finance/presentation/finance_report_page.dart:3470`; service wrapper at `lib/features/marketplace/services/marketplace_service.dart:2146` | `p_account_id` | baseline returns zero-delete no-op fields; business data remains intact |
| Pull Finance / Refresh Payout log | `finance_record_sync_log` | `lib/features/finance/presentation/finance_report_page.dart:3770` | `p_sync_type`, `p_start`, `p_end`, `p_marketplace`, `p_account_id`, `p_checked`, `p_success`, `p_failed`, `p_skipped`, `p_message` | no returned fields required |
| Finance SKU target margin | `finance_upsert_sku_target_margin` | `lib/features/finance/presentation/finance_report_page.dart:3996` | `p_sku`, `p_target_margin_percent` | no returned fields required |
| Finance Biaya insert | `finance_insert_manual_operational_expense_v24_6_79` | `lib/features/finance/presentation/finance_report_page.dart:4152` | `p_category`, `p_amount`, `p_expense_date`, `p_note` | no returned fields required |
| Finance Biaya update | `finance_update_manual_operational_expense_v24_6_79` | `lib/features/finance/presentation/finance_report_page.dart:4315` | `p_expense_id`, `p_category`, `p_amount`, `p_expense_date`, `p_note` | no returned fields required |
| Finance Biaya delete | `finance_delete_manual_operational_expense_v24_6_79` | `lib/features/finance/presentation/finance_report_page.dart:4377` | `p_expense_id` | no returned fields required |
| Finance filters | `marketplace_list_active_accounts_for_filter` | `lib/features/finance/presentation/finance_report_page.dart:7020` | `p_marketplace` | account id, marketplace, store/shop label, status, timestamps |
| Finance Biaya categories | `finance_list_operational_expense_categories` | `lib/features/finance/presentation/finance_report_page.dart:7106` | none | `category` string values |

## Marketplace / Order RPCs

| Module | Exact RPC/function | File:line | Arguments sent | Response fields used |
|---|---|---:|---|---|
| Order Job Monitor | `marketplace_job_monitor_snapshot_v24_6_9` | `lib/features/marketplace/presentation/marketplace_job_monitor_page.dart:42` | none | `order_counts`, `finance_counts`, latest order/finance logs |
| Order Job Monitor | `marketplace_job_reset_stuck_v24_6_9` | `lib/features/marketplace/presentation/marketplace_job_monitor_page.dart:76` | `p_kind`, `p_retry_failed`, `p_stale_minutes` | `ok`, message/count fields |
| Refund / Cancel Monitor | `marketplace_refund_cancel_review_v24_6_42` | `lib/features/marketplace/presentation/marketplace_refund_monitor_page.dart:136` | `p_start`, `p_end`, `p_marketplace`, `p_account_id`, `p_search`, `p_action`, `p_page`, `p_page_size` | `rows`, `total`, per order metadata, `item_details`, buyer/shop/resi/order status, HPP, stock action status, reason/note |
| Auto Pull Order | `marketplace_get_order_pull_auto_setting` | `lib/features/marketplace/services/marketplace_service.dart:1644` | `p_tenant_id` | `auto_order_pull_enabled`, `interval_minutes`, `days_back`, timestamps/message |
| Auto Pull Order | `marketplace_set_order_pull_auto_enabled` | `lib/features/marketplace/services/marketplace_service.dart:1677` | `p_tenant_id`, `p_enabled` | same setting fields |
| Stock out QR/reference scan | `marketplace_find_order_by_resi` | `lib/features/marketplace/services/marketplace_order_pick_service.dart:144` | `p_tenant_id`, `p_resi_code` | order match result, active order metadata, items |
| Stock out QR/reference scan | `marketplace_activate_order_for_scan_by_resi` | `lib/features/marketplace/services/marketplace_order_pick_service.dart:159` | `p_tenant_id`, `p_resi_code` | order scan activation result |
| Stock out QR/reference scan | `marketplace_scan_order_item_by_resi` | `lib/features/marketplace/services/marketplace_order_pick_service.dart:175` | `p_tenant_id`, `p_resi_code`, `p_scan_code` | scanned item result, counts, message |
| Stock out QR/reference scan | `marketplace_scan_order_item_manual_by_resi` | `lib/features/marketplace/services/marketplace_order_pick_service.dart:192` | `p_tenant_id`, `p_resi_code`, `p_marketplace_order_item_id` | manual scanned item result |
| Stock out QR/reference scan | `marketplace_finalize_scanned_order_stock_out_by_resi_guarded` | `lib/features/marketplace/services/marketplace_order_pick_service.dart:208` | `p_tenant_id`, `p_resi_code` | finalized stock-out result |
| Marketplace order pick | `marketplace_scan_order_item_barcode` | `lib/features/marketplace/services/marketplace_order_pick_service.dart:113` | `p_tenant_id`, `p_marketplace_order_id`, `p_scan_code` | scanned item result |
| Marketplace order pick | `marketplace_finalize_scanned_order_stock_out` | `lib/features/marketplace/services/marketplace_order_pick_service.dart:129` | `p_tenant_id`, `p_marketplace_order_id` | finalized stock-out result |
| Return review | `marketplace_prepare_return_item_reviews` | `lib/features/marketplace/services/marketplace_service.dart:1742`; pick service at `lib/features/marketplace/services/marketplace_order_pick_service.dart:243` | `p_tenant_id`, `p_marketplace_account_id` | review preparation counts/result |
| Return review | `marketplace_submit_return_item_review` | `lib/features/marketplace/services/marketplace_order_pick_service.dart:305` | review id/status/note/reviewer fields | result map |
| Return review | `marketplace_submit_return_review` | `lib/features/marketplace/services/marketplace_order_pick_service.dart:329` | review id/status/note/reviewer fields | result map |
| Stock out review | `marketplace_prepare_stock_out_reviews` | `lib/features/marketplace/presentation/marketplace_stock_out_review_page.dart:56` | `p_tenant_id`, `p_limit=300` | preparation result ignored; table read follows |
| Stock out review | `marketplace_submit_stock_out_review` | `lib/features/marketplace/presentation/marketplace_stock_out_review_page.dart:161` | review id/status/note/reviewer fields | `ok`, `message` |
| Order stock out | `marketplace_process_order_stock_out` | `lib/features/marketplace/services/marketplace_service.dart:2079` | `p_tenant_id`, `p_marketplace_order_id` | `ok`, stock-out counts/message |
| Order stock out bulk | `marketplace_process_ready_order_stock_out` | `lib/features/marketplace/services/marketplace_service.dart:2096` | `p_tenant_id`, `p_marketplace_account_id`, `p_limit` | `ok`, processed counts/message |
| HPP mapping | `marketplace_variant_hpp_list_v24_6_49`, `_47`, `_44`, `_28` | `lib/features/marketplace/services/marketplace_service.dart:2225-2239` | `p_account_id`, `p_search`, `p_missing_only`, `p_page`, `p_page_size` | `ok`, `rows`, `total`, page metadata |
| HPP mapping | `marketplace_variant_hpp_upsert_bulk_v24_6_49`, `_47`, `_28` | `lib/features/marketplace/services/marketplace_service.dart:2295-2308` | `p_rows` | `ok`, upsert count/message |

## Important Supabase Edge Function Invokes

These are not SQL RPCs, but they are active Supabase function calls in the same flows.

| Flow | Edge function | Behavior enforced by Flutter |
|---|---|---|
| Pull Finance / Refresh Payout / Auto Finance | `marketplace-tiktok-service` action `process_finance_sync_jobs` | `max_jobs=1`, `max_orders=10`, `max_batches_per_job=3`, cache refresh after completion |
| Order Marketplace / Auto Pull Order / Job Monitor | `marketplace-order-sync-jobs` and order pull worker | recent windows only, `refresh_existing_status=true`, `skip_completed_status_refresh=true`, `skip_completed_order_pull=true` |
| Refund / Cancel | `marketplace-return-refund-pull` | small recent refresh, then review preparation |
| Stock sync | `marketplace-stock-sync-worker` | bounded queue processing |

## Direct Table Reads

Direct `.from(...)` reads in the audited flows use bounded `.range(...)` or `.limit(...)`:

- `finance_operational_expenses` range `0..499` as fallback for manual expense list.
- `marketplace_accounts_public` range `0..199` for finance filters and account lists.
- `marketplace_stock_sync_overview_public`, `marketplace_stock_sync_logs_public`, `marketplace_stock_difference_public` with bounded ranges.
- `marketplace_orders_public`, `marketplace_order_items_public`, return/stock review public views with bounded ranges.

No cleanup was applied. `CLEANUP_UNUSED_FUNCTIONS_AFTER_PASS.sql` is only safe after full smoke tests stay green.
