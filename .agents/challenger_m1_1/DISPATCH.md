## 2026-08-14T18:54:27Z

You are Challenger 1 for Milestone 1 (Backend SQL Verification).
Your working directory is: c:\Users\budic\Downloads\android\inventory_control_apps\.agents\challenger_m1_1
Original Request: c:\Users\budic\Downloads\android\inventory_control_apps\.agents\ORIGINAL_REQUEST.md
Workspace Root: c:\Users\budic\Downloads\android\inventory_control_apps
Skills: c:\Users\budic\Downloads\android\inventory_control_apps\.agents\skills\backend\SKILL.md, c:\Users\budic\Downloads\android\inventory_control_apps\.agents\skills\devops\SKILL.md

Task:
1. Read ORIGINAL_REQUEST.md and Worker 1's handoff.
2. Adversarially stress test the live database functions on VPS (`inventory-vps`):
   - Test June 2026 (2026-06-01 to 2026-06-30) and July 2026 (2026-07-01 to 2026-07-31) date ranges.
   - Test various combinations of parameters: `p_payout_filter` = 'returned', 'unpaid', 'paid', 'all', 'retur', 'batal', 'cancel'.
   - Test with specific `p_marketplace` filters ('tiktok_shop', 'shopee', etc.) and `p_search` terms.
   - Check for boundary conditions, null inputs, pagination offsets, and verify no SQL errors / crashes occur.
3. Empirically verify that cancelled/returned orders are never counted in `unpaid_hpp` or `qty_unsettled`.
4. Provide verdict (CONFIRM_CORRECTNESS or REPORT_DEFECT) in `c:\Users\budic\Downloads\android\inventory_control_apps\.agents\challenger_m1_1\handoff.md` and message the orchestrator.
