# Progress Tracker — Explorer 1

Last visited: 2026-08-15T01:39:35+07:00

## Status
Starting investigation of backend SQL RPCs and migration structure.

## Plan
- [x] Read ORIGINAL_REQUEST.md and set up workspace.
- [ ] Search codebase for `finance_sku_order_line_details`, `finance_sku_order_details_group_20260625`, and related functions/views.
- [ ] Inspect all migration files and SQL scripts.
- [ ] Analyze `valid_orders` CTE and cancellation/return logic in `finance_sku_order_line_details`.
- [ ] Analyze `unpaid_hpp`, `qty_unsettled`, `hpp_return`, `qty_returned` calculation in `finance_sku_order_details_group_20260625`.
- [ ] Examine deployment/migration workflows (Supabase, direct SQL, scripts, VPS).
- [ ] Compile comprehensive `handoff.md` and notify parent.
