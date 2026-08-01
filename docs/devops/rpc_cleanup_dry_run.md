# RPC Cleanup Dry Run Report
**Path**: `docs/devops/rpc_cleanup_dry_run.md`

## 1. Active RPCs in Production Use

The following database functions (RPCs) are actively called by the Flutter client application, cron tasks, or Edge Functions:

### Flutter Client UI
- `public.finance_dashboard_snapshot(p_start, p_end, p_marketplace, p_account_id)`
- `public.finance_sku_order_details(p_start, p_end, p_marketplace, p_account_id, ...)`
- `public.finance_sku_order_line_details(p_start, p_end, p_marketplace, p_account_id, ...)`
- `public.finance_sample_order_counts(p_start, p_end, p_marketplace, p_account_id, p_count_only, ...)`
- `public.finance_marketplace_reconciliation_breakdown(p_start, p_end, p_marketplace, p_account_id)`
- `public.finance_abnormal_search(p_start, p_end, p_marketplace, p_account_id, ...)`
- `public.list_purchase_requests()`

### Cron Jobs & Edge Functions
- `public.marketplace_finance_dispatcher_every_5_min()` (Active cron job)
- `public.marketplace_bootstrap_monitor()`
- `public.marketplace_order_sync_dispatcher()`

---

## 2. Unused / Legacy Candidates for Deprecation (Dry Run)

The following RPCs exist in the database schema but are no longer directly invoked by the production codebase. They are recommended for removal **only after the current hotfix stabilizes the finance platform**:

1. `public.finance_abnormal_search_v24_6_82e(...)`
   - *Reason*: Legacy version of the abnormal search function, now wrapped by the standard `finance_abnormal_search`.
2. `public.finance_list_manual_operational_expenses(...)`
   - *Reason*: This RPC is slow and causes database pool timeouts. The client has transitioned to direct, bounded queries on the `finance_operational_expenses` table.
3. `public.finance_reconciliation_detailed_ui_fix(...)`
   - *Reason*: Older experimental reconciliation function.
4. `public.finance_dashboard_snapshot_fallback(...)`
   - *Reason*: Replaced by the updated dynamic period fallbacks in the Dart codebase.

---

## 3. Deprecation Process Plan
To safely drop candidates without breaking system components:
1. Confirm that no references exist in `lib/` or `supabase/functions/`.
2. Deploy the drop commands in a transaction during off-peak hours:
   ```sql
   begin;
   drop function if exists public.finance_abnormal_search_v24_6_82e(date, date, text, uuid, text, text, integer, integer);
   drop function if exists public.finance_list_manual_operational_expenses(date, date, text, uuid);
   commit;
   ```
3. Monitor real-time Postgres log output for any `function does not exist` (code `42883`) errors.
