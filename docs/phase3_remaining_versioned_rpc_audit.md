# Phase 3 Safe Audit: Remaining Versioned RPCs

This document audits the remaining versioned database RPCs present in the finance modules of the application, evaluating them for wrapping safety and transition priority.

---

## RPC Audit Log

The table below lists all remaining versioned RPC references in the finance modules, their type, wrapping recommendation, current fallback, proposed canonical name, risk, and status.

| File Path | Function / RPC Name | Read-Only / Write | Safe to Wrap? | Recommended Canonical Name | Risk Level | Status / Action |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `finance_report_page.dart` | `finance_customer_dashboard_snapshot_v24_6_82o` | Read-only | Yes | `finance_customer_dashboard_snapshot` | Medium | **Rerouted**. Fixed spelling mismatch in `candidates`. |
| `finance_report_page.dart` | `finance_list_manual_operational_expenses_v24_6_80m` | Read-only | Yes | `finance_list_manual_operational_expenses` | Low | **Rerouted**. Staged safe SQL wrapper and updated Flutter UI call. |
| `finance_report_page.dart` | `finance_get_latest_runtime_progress_v24_6_3` | Read-only | Yes | `finance_get_latest_runtime_progress` | Low | **Rerouted**. Staged safe SQL wrapper and updated Flutter UI call. |
| `finance_report_page.dart` | `finance_fix_exact_cache_settled_hpp_v24_6_82q` | Write / Heavy | **No** | `finance_fix_exact_cache_settled_hpp` | High | **DEFERRED**. Cache-warming functions have side effects and are volatile. |
| `finance_report_page.dart` | `finance_upsert_runtime_progress_v24_6_3` | Write / Action | **No** | `finance_upsert_runtime_progress` | High | **DEFERRED**. High-risk writer calculating and logging finance runs. |
| `finance_report_page.dart` | `finance_unmark_no_payout_order_v24_6_28` | Write / Action | **No** | `finance_unmark_no_payout_order` | Medium | **DEFERRED**. Write action. |
| `finance_report_page.dart` | `finance_auto_mark_cancel_no_payout_v24_6_28` | Write / Action | **No** | `finance_auto_mark_cancel_no_payout` | Medium | **DEFERRED**. Write action. |

---

## Rerouting & Wrapper Specifications

1. **`finance_customer_dashboard_snapshot`**
   - **Reason**: Rerouting was failing due to a spelling mismatch (`finance_dashboard_snapshot` instead of `finance_customer_dashboard_snapshot`) in the `candidates` array inside `finance_report_page.dart`. Corrected spelling. Fallback to `v24_6_82o` is retained.
2. **`finance_list_manual_operational_expenses`**
   - **Wrapper**: Deployed in `20260615120100_phase3_remaining_wrappers.sql`.
   - **Flutter Rerouting**: Patched `_fetchUnpaidSkuRowsPeriod` to list `finance_list_manual_operational_expenses` as the primary option, utilizing the `_rpcWithFallback` utility.
3. **`finance_get_latest_runtime_progress`**
   - **Wrapper**: Deployed in `20260615120100_phase3_remaining_wrappers.sql`.
   - **Flutter Rerouting**: Patched `_loadPersistedFinanceProgressFromDb` to call the canonical name as the primary candidate.
