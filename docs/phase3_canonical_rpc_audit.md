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
| `dashboard_page.dart` | `finance_customer_dashboard_snapshot_v24_6_82o` | `p_start_date`, `p_end_date` | `Map` (metrics/aggregates) | Main Dashboard / Customer Dashboard | **Yes** | `finance_customer_dashboard_snapshot` | Medium | **Yes** (Wrapper active) | Rerouted in Flutter (Dashboard Page). |
| `dashboard_page.dart` | `finance_live_20260606_local_cache_fast_v20` | `p_filters` | `List<Map>` | Live Sync Monitoring | **Yes** | `finance_live_local_cache_fast` | High | **No** (Do not touch live sync) | Connected to marketplace sync dashboard. |
| `finance_report_page.dart` | `finance_sku_summary_rows_v24_6_82e` | `p_filters` | `List<Map>` | SKU Summary Report | **Yes** | `finance_sku_summary_rows` | Medium | **Yes** (Wrapper active) | Rerouted in Flutter (Finance Report Page). |
| `finance_report_page.dart` | `finance_unpaid_sku_rows_v24_6_82e` | `p_filters` | `List<Map>` | Unpaid SKU Screen | **Yes** | `finance_unpaid_sku_rows` | Medium | **Yes** (Wrapper active) | Rerouted in Flutter (Finance Report Page). |
| `finance_report_page.dart` | `finance_get_latest_runtime_progress_v24_6_3` | None | `Map` (progress details) | Run Finance Calculations | **Yes** | `finance_get_latest_runtime_progress` | Medium | **No** | High volatility. |
| `finance_report_page.dart` | `finance_upsert_runtime_progress_v24_6_3` | `p_data` | `Void` / `Map` | Start Finance Run | **Yes** | `finance_upsert_runtime_progress` | High | **No** | Critical execution point. |
| `finance_report_page.dart` | `finance_mark_no_payout_order_v24_6_28` | `p_order_id` | `Void` | Mark No Payout | **Yes** | `finance_mark_no_payout_order` | Low | **Yes** (Wrapper active) | Rerouted in Flutter (Finance Report Page). |

---

## Phase 3 Execution Strategy & Status

1. **Step 1: Write and Deploy Safe SQL Wrappers** (Completed)
   - Created and staged `supabase/migrations/20260615120000_phase3_canonical_wrappers.sql` with safe canonical wrappers for `finance_customer_dashboard_snapshot`, `finance_sku_summary_rows`, `finance_unpaid_sku_rows`, and `finance_mark_no_payout_order`.
   - Bypassed high-risk live sync/operational scheduler functions.
   - Old/versioned RPCs are retained for safety.
2. **Step 2: Incremental Rerouting in Flutter** (In Progress)
   - Updated `dashboard_page.dart` to query `finance_customer_dashboard_snapshot` as the primary candidate, with automatic fallback to versioned variants if missing.
3. **Step 3: Verification** (Pending)
   - Verify dashboard loading on device/VPS to ensure payload format parsing doesn't crash.
4. **Step 4: Safe Deletion Log** (Deferred)
   - Do not drop versioned RPCs until all modules are rerouted, tested, and validated in production.

