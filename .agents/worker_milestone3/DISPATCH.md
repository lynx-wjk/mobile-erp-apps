# DISPATCH — 2026-08-15T03:04:00Z

## Assignment
You are Worker for Milestone 3 (E2E Acceptance Verification on June & July 2026 Data).

Your Working Directory: c:\Users\budic\Downloads\android\inventory_control_apps\.agents\worker_milestone3
Original Request: c:\Users\budic\Downloads\android\inventory_control_apps\.agents\ORIGINAL_REQUEST.md
Project Scope: c:\Users\budic\Downloads\android\inventory_control_apps\.agents\orchestrator_1_gen3\PROJECT.md

Task:
1. Read ORIGINAL_REQUEST.md and PROJECT.md.
2. Perform comprehensive end-to-end verification against the live PostgreSQL database (via `ssh inventory-vps "docker exec -i supabase-db psql -U postgres -d postgres"` or curl/PostgREST/script):
   a. Test `finance_sku_order_line_details` for June 2026 (`2026-06-01` to `2026-06-30`) with `p_payout_filter = 'returned'`, `'unpaid'`, `'paid'`, `'all'`. Verify returned count > 0 and rows returned contain returned/cancelled items with `is_returned = true`.
   b. Test `finance_sku_order_line_details` for July 2026 (`2026-07-01` to `2026-07-31`) with `p_payout_filter = 'returned'`, `'unpaid'`, `'paid'`, `'all'`. Verify returned count > 0 and rows returned contain returned/cancelled items with `is_returned = true`.
   c. Test `finance_sku_order_details_group_20260625` for June & July 2026. Verify that `unpaid_hpp` and `qty_unsettled` contain ONLY non-cancelled pending orders, and that all cancelled/returned orders are counted under `hpp_return` and `qty_returned`.
   d. Compare aggregated group totals against line-item totals to prove mathematical consistency across all dimensions.
3. Run all frontend test suites (`flutter test`, `flutter analyze`) to ensure the entire workspace is clean.
4. Document all raw query commands, exact row counts, financial metric numbers, and test results in your handoff report at `c:\Users\budic\Downloads\android\inventory_control_apps\.agents\worker_milestone3\handoff.md`.
5. Notify orchestrator via send_message when complete.
