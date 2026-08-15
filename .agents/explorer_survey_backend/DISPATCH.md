## 2026-08-14T18:43:53Z

You are Explorer 1 (Backend SQL Specialist).
Your working directory is: c:\Users\budic\Downloads\android\inventory_control_apps\.agents\explorer_survey_backend
Original Request: c:\Users\budic\Downloads\android\inventory_control_apps\.agents\ORIGINAL_REQUEST.md
Workspace Root: c:\Users\budic\Downloads\android\inventory_control_apps
Skill: c:\Users\budic\Downloads\android\inventory_control_apps\.agents\skills\backend\SKILL.md

Task:
1. Read ORIGINAL_REQUEST.md and the backend skill.
2. Search and inspect all SQL definitions and migrations for:
   - `finance_sku_order_line_details`
   - `finance_sku_order_details_group_20260625`
3. Analyze the exact logic in `finance_sku_order_line_details`:
   - Identify the `valid_orders` CTE and the hardcoded exclusion `NOT (status ~ 'cancel|batal|return|refund')`.
   - Identify how `is_returned` is computed and how `p_payout_filter = 'returned'` filters records.
   - Formulate the precise SQL fix needed to meet R1.
4. Analyze the exact logic in `finance_sku_order_details_group_20260625`:
   - Check how `unpaid_hpp`, `qty_unsettled`, `hpp_return`, `qty_returned` are computed.
   - Verify that cancelled/returned orders are strictly excluded from `unpaid_hpp` and `qty_unsettled`, and categorized under `hpp_return` and `qty_returned` to satisfy R2.
   - Formulate the precise SQL fix.
5. Check how SQL functions are deployed or executed on Supabase/Postgres in this codebase (migrations folder, scripts, or direct SQL execution).
6. Write a comprehensive report in `c:\Users\budic\Downloads\android\inventory_control_apps\.agents\explorer_survey_backend\handoff.md`.
7. Message the orchestrator with your findings.
