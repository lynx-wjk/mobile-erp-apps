# Plan — Finance SKU Report & Retur/Batal Order Modal Fix

## Objectives
1. Fix Backend RPC `finance_sku_order_line_details`:
   - Remove hardcoded exclusion `NOT (status ~ 'cancel|batal|return|refund')` in `valid_orders` CTE.
   - Categorize returned/cancelled orders as `is_returned = true`.
   - Ensure `p_payout_filter = 'returned'` returns full cancelled/returned order rows.
2. Fix Backend RPC `finance_sku_order_details_group_20260625`:
   - Ensure `unpaid_hpp` and `qty_unsettled` contain strictly active, non-cancelled orders without payout.
   - Categorize cancelled/returned orders strictly under `hpp_return` and `qty_returned`.
3. Fix Flutter UI (`finance_report_page.dart`):
   - Support `payoutFilter = 'returned'` in detail modal.
   - Ensure `_skuReturnedCountMap` displays total retur count.
   - Modal for `Retur/Batal` shows complete order rows.
4. E2E Verification & Verification against live data for June & July 2026.
5. Build Flutter Web (`flutter build web --release`) and deploy to live VPS (`https://mdhproduction.com`).

## Phase Breakdown
- **Phase 0: Survey & Exploration**
  - Explorer 1: Backend RPC analysis (`finance_sku_order_line_details`, `finance_sku_order_details_group_20260625`, migration files, PostgreSQL queries).
  - Explorer 2: Frontend Flutter analysis (`finance_report_page.dart`, modal invocation, count maps, state management).
  - Explorer 3: Live VPS & Deployment analysis (SSH MCP / Docker / Supabase / Nginx / Web build).
- **Phase 1: Milestone 1 — Backend RPC Fixes & Migration**
  - Worker modifies/applies SQL migrations.
  - Reviewer + Challenger verify SQL execution and correctness on database.
  - Auditor checks integrity.
- **Phase 2: Milestone 2 — Flutter UI Alignment**
  - Worker updates `finance_report_page.dart`.
  - Reviewer + Challenger verify Flutter Dart analysis and widget functionality.
- **Phase 3: Milestone 3 — E2E Testing & Acceptance Verification**
  - Verify acceptance criteria (>0 rows for June & July 2026 with `p_payout_filter = 'returned'`, `unpaid_hpp` strictly non-cancelled).
- **Phase 4: Milestone 4 — Build Web Release & Deploy to VPS**
  - Worker runs `flutter build web --release` and deploys to `https://mdhproduction.com`.
  - Reviewer + Challenger verify live website at `https://mdhproduction.com`.
  - Auditor integrity audit.
