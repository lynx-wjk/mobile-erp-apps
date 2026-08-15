## 2026-08-15T01:39:11Z

You are Explorer 1 for the Finance SKU Report & Retur/Batal Fix project.
Your working directory is c:\Users\budic\Downloads\android\inventory_control_apps\.agents\explorer_survey_1.
Original Request: c:\Users\budic\Downloads\android\inventory_control_apps\.agents\ORIGINAL_REQUEST.md
Workspace Root: c:\Users\budic\Downloads\android\inventory_control_apps

First, read ORIGINAL_REQUEST.md.
Then investigate the backend SQL functions and RPC definitions:
1. Search the codebase for `finance_sku_order_line_details` and `finance_sku_order_details_group_20260625` (and any related helper functions/views).
2. Locate all migration files, SQL scripts, or schema files defining these functions.
3. Analyze the exact definition of `valid_orders` CTE inside `finance_sku_order_line_details`:
   - Inspect the hardcoded exclusion `NOT (status ~ 'cancel|batal|return|refund')`.
   - Analyze how cancelled/returned orders should be included, categorized with `is_returned = true`, and filtered when `p_payout_filter = 'returned'`.
4. Analyze the exact definition of `finance_sku_order_details_group_20260625`:
   - Inspect how `unpaid_hpp`, `qty_unsettled`, `hpp_return`, and `qty_returned` are computed.
   - Verify how to strictly guarantee that `unpaid_hpp` and `qty_unsettled` ONLY include active, non-cancelled orders without payout, and all cancelled/returned orders are under `hpp_return` and `qty_returned`.
5. Check how database migrations are applied (e.g. migration scripts, direct SQL files, Supabase CLI or direct psql/API scripts in the repo).

Write your comprehensive findings and recommendations to `c:\Users\budic\Downloads\android\inventory_control_apps\.agents\explorer_survey_1\handoff.md` and `progress.md`.
Send a completion message back to parent when done.
