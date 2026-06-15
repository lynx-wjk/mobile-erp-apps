# Phase 3 Safe Audit: Canonical RPC Wrappers

This document audits the main Remote Procedure Calls (RPCs) invoked within the Flutter application. It categorizes them, identifies versioned RPC names, and outlines a safe migration plan to move towards a canonical naming convention without breaking the self-hosted production backend.

---

## RPC Audit Log

The table below lists the primary `.rpc` calls discovered in the codebase, detailing their params, version status, proposed canonical names, risk levels, and safe transition actions.

| File Path | Current RPC Name | Parameters | Expected Return Shape | Screen / UI Menu | Versioned? | Proposed Canonical Name | Risk Level | Safe to Reroute Now? | Notes |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `platform_owner_dashboard.dart` | `platform_tenant_readiness_summary` | None | `List<Map>` | Platform Owner Dashboard | No (Canonical) | `platform_tenant_readiness_summary` | Low | Yes | Already canonical. |
| `platform_owner_dashboard.dart` | `platform_create_tenant_for_app` | `p_name`, `p_domain` | `Map` (status/id) | Create Tenant Form | No (Canonical) | `platform_create_tenant_for_app` | Low | Yes | Already canonical. |
| `platform_owner_dashboard.dart` | `create_invite` | `p_role`, `p_tenant_id` | `String` (token) | Generate Undangan | No (Canonical) | `create_invite` | Low | Yes | Uses `md5` hashing. |
| `register_page.dart` | `check_invite` | `p_token` | `Map` (valid status) | Register Page | No (Canonical) | `check_invite` | Low | Yes | Already canonical. |
| `register_page.dart` | `accept_invite` | `p_token`, `p_email`, `p_password` | `Map` (success/id) | Register Page | No (Canonical) | `accept_invite` | Low | Yes | Already canonical. |
| `dashboard_page.dart` | `finance_customer_dashboard_snapshot_v24_6_82o` | `p_start_date`, `p_end_date` | `Map` (metrics/aggregates) | Main Dashboard / Customer Dashboard | **Yes** | `finance_customer_dashboard_snapshot` | Medium | **No** (Wait for draft SQL) | Needs canonical wrapper routing. |
| `dashboard_page.dart` | `finance_live_20260606_local_cache_fast_v20` | `p_filters` | `List<Map>` | Live Sync Monitoring | **Yes** | `finance_live_local_cache_fast` | High | **No** (Do not touch live sync) | Connected to marketplace sync dashboard. |
| `finance_report_page.dart` | `finance_sku_summary_rows_v24_6_82e` | `p_filters` | `List<Map>` | SKU Summary Report | **Yes** | `finance_sku_summary_rows` | Medium | **No** | Requires query parameter updates. |
| `finance_report_page.dart` | `finance_unpaid_sku_rows_v24_6_82e` | `p_filters` | `List<Map>` | Unpaid SKU Screen | **Yes** | `finance_unpaid_sku_rows` | Medium | **No** | Reroute after writing SQL wrappers. |
| `finance_report_page.dart` | `finance_get_latest_runtime_progress_v24_6_3` | None | `Map` (progress details) | Run Finance Calculations | **Yes** | `finance_get_latest_runtime_progress` | Medium | **No** | High volatility. |
| `finance_report_page.dart` | `finance_upsert_runtime_progress_v24_6_3` | `p_data` | `Void` / `Map` | Start Finance Run | **Yes** | `finance_upsert_runtime_progress` | High | **No** | Critical execution point. |
| `finance_report_page.dart` | `finance_mark_no_payout_order_v24_6_28` | `p_order_id` | `Void` | Mark No Payout | **Yes** | `finance_mark_no_payout_order` | Low | **No** | Safe to wrap. |

---

## Phase 3 Execution Strategy

1. **Step 1: Write and Deploy Draft SQL Wrappers**
   - Deploy `phase3_canonical_rpc_wrappers_draft.sql` to your Supabase instance.
   - The SQL wrappers must only delegate parameters and executions to the currently active versioned RPCs without any destructive drops.
2. **Step 2: Incremental Rerouting in Flutter**
   - Update Flutter RPC calls one module at a time.
   - Reroute the dashboard calls first (`finance_customer_dashboard_snapshot`).
   - Run integration tests or device tests to ensure that payload parsing functions work flawlessly.
3. **Step 3: Verification**
   - Verify every UI screen after changing its backend hooks.
   - Assert page tables render properly and do not raise cast exceptions (e.g. `List<dynamic>` to `List<Map>`).
4. **Step 4: Safe Deletion Log**
   - Compile a list of obsolete versioned RPC functions.
   - The deletion of these functions belongs to a separate reviewed migration and should not be combined with wrappers deployment.
