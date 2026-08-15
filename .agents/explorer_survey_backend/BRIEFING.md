# BRIEFING — 2026-08-15T01:46:40+07:00

## Mission
Investigate and formulate exact SQL fixes for RPCs `finance_sku_order_line_details` and `finance_sku_order_details_group_20260625` to resolve Retur/Batal modal display and ensure strict separation of pending payout vs returned/cancelled orders (R1 & R2).

## 🔒 My Identity
- Archetype: explorer
- Roles: Backend SQL Specialist
- Working directory: c:\Users\budic\Downloads\android\inventory_control_apps\.agents\explorer_survey_backend
- Original parent: bf5a721a-983c-4c75-b5f8-b071203f463c
- Milestone: Explorer Survey

## 🔒 Key Constraints
- Read-only investigation — do NOT implement directly in production or modify source files outside agent folder.
- Follow backend skill rules: stable source of truth, preserve canonical naming, STRICT REAL API PAYOUT RULE, COGS settlement rule.

## Current Parent
- Conversation ID: bf5a721a-983c-4c75-b5f8-b071203f463c
- Updated: 2026-08-15T01:46:40+07:00

## Investigation State
- **Explored paths**:
  - `supabase/migrations/20260721000000_finance_sku_details_resi.sql`
  - `supabase/migrations/20260724120000_fix_laba_rugi_breakdown_and_sku_details.sql`
  - `supabase/migrations/20260725440000_fix_sku_detail_performance_and_belumpayout.sql`
  - `supabase/migrations/20260725450000_optimize_finance_sku_order_details_group.sql`
  - `supabase/migrations/20260725460000_drop_overloaded_sku_group_function.sql`
  - `lib/features/finance/presentation/finance_report_page.dart`
- **Key findings**:
  1. `finance_sku_order_line_details` / `finance_sku_order_details_v24_6_82o` completely eliminated return/cancel orders in `valid_orders` via `NOT (upper(...) like any (array['%CANCEL%', '%REFUND%', '%RETURN%', '%FAILED%', '%CLOSE%']))`, lacked `returned` filter normalization, and omitted `is_returned` flag in the output row objects.
  2. `finance_sku_order_details_group_20260625` also filtered out return/cancel orders in `valid_orders`, and did not calculate `qty_returned`, `hpp_return`, `qty_unsettled`, or `unpaid_hpp` fields required by the Flutter UI.
  3. Formulated drop-in replacement SQL definitions for both RPCs with strict filter segregation (`filter (where not f.has_payout and not f.is_returned)` vs `filter (where f.is_returned)`).
- **Unexplored areas**: None for backend SQL scope.

## Key Decisions Made
- Formulated the exact SQL definitions ready to be placed into a single new migration `supabase/migrations/20260815020000_fix_finance_sku_retur_batal_and_unpaid_separation.sql`.

## Artifact Index
- DISPATCH.md — incoming dispatch instructions
- BRIEFING.md — situational awareness
- progress.md — liveness heartbeat
- handoff.md — final 5-component report
