# Original User Request

## Initial Request — 2026-08-15T01:38:30+07:00

# Teamwork Project Prompt

Investigate and update finance SKU report RPCs (`finance_sku_order_line_details` and `finance_sku_order_details_group_20260625`) and Flutter UI so Retur/Batal order detail modal shows full order records, and pending payout metrics correctly separate active pending orders from returned/cancelled orders across June & July 2026.

Working directory: c:\Users\budic\Downloads\android\inventory_control_apps
Integrity mode: development

## Requirements

### R1. Fix Retur / Batal Modal RPC (`finance_sku_order_line_details`)
Remove the hardcoded exclusion `NOT (status ~ 'cancel|batal|return|refund')` inside `valid_orders` CTE of `finance_sku_order_line_details` so that returned and cancelled orders are included, categorized as `is_returned = true`, and correctly returned when `p_payout_filter = 'returned'`.

### R2. Strict Separation of Pending Payout vs Returned / Cancelled Orders
Ensure `unpaid_hpp` and `qty_unsettled` ONLY include active, non-cancelled orders that have not yet received payout. All cancelled/returned orders must be strictly categorized under `hpp_return` and `qty_returned`.

### R3. Flutter UI Alignment (`finance_report_page.dart`)
Update `finance_report_page.dart` to call the updated RPCs with full support for `payoutFilter = 'returned'`, ensuring `_skuReturnedCountMap` displays total retur count and clicking `Retur/Batal` opens the modal with complete order rows.

## Acceptance Criteria

### Objective Verification
- [ ] Executing `finance_sku_order_line_details` with `p_payout_filter = 'returned'` returns >0 rows of cancelled/returned orders for June & July 2026.
- [ ] Executing `finance_sku_order_details_group_20260625` returns `unpaid_hpp` containing ONLY non-cancelled pending orders.
- [ ] `flutter build web --release` completes with zero compilation errors and is deployed to live VPS (`https://mdhproduction.com`).
