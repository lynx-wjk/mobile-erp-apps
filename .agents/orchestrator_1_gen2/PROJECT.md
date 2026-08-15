# Project: Finance SKU Report & Retur/Batal Order Modal Fix

## Architecture
- **Backend**: PostgreSQL database functions (RPCs) hosted on Supabase / VPS (`finance_sku_order_line_details`, `finance_sku_order_details_group_20260625`).
- **Frontend**: Flutter Web/Mobile app (`lib/pages/finance_report_page.dart`).
- **Infrastructure**: VPS running Supabase and web server hosting Flutter Web (`https://mdhproduction.com`).

## Feature Inventory
| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| 1 | R1: Retur/Batal Modal RPC | Remove `NOT (status ~ 'cancel|batal|return|refund')` in `valid_orders` CTE of `finance_sku_order_line_details`, set `is_returned = true`, support `p_payout_filter = 'returned'`. | M1 | ORIGINAL_REQUEST.md |
| 2 | R2: Strict Separation of Pending Payout vs Retur | Ensure `unpaid_hpp` and `qty_unsettled` exclude cancelled/returned orders; categorize cancelled/returned under `hpp_return` and `qty_returned`. | M1 | ORIGINAL_REQUEST.md |
| 3 | R3: Flutter UI Alignment | Update `finance_report_page.dart` to call updated RPCs, display `_skuReturnedCountMap`, open modal with complete cancelled/returned order rows. | M2 | ORIGINAL_REQUEST.md |
| 4 | Verification on Live Data | Verify `finance_sku_order_line_details` returns >0 cancelled/returned rows for June & July 2026 and `unpaid_hpp` is accurate. | M3 | ORIGINAL_REQUEST.md |
| 5 | Web Release & Deployment | Build `flutter build web --release` and deploy to live VPS (`https://mdhproduction.com`). | M4 | ORIGINAL_REQUEST.md |

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| 1 | Backend RPC Fix | SQL migration & execution for `finance_sku_order_line_details` and `finance_sku_order_details_group_20260625` | none | DONE |
| 2 | Flutter UI Alignment | Update `lib/pages/finance_report_page.dart` for retur modal & count map | M1 | IN_PROGRESS |
| 3 | E2E Acceptance Verification | Test queries on June & July 2026 datasets and widget tests | M1, M2 | PLANNED |
| 4 | Web Release & VPS Deploy | `flutter build web --release` and deploy to `https://mdhproduction.com` | M1, M2, M3 | PLANNED |

## Interface Contracts
### `finance_sku_order_line_details`
- Parameters: `p_sku_name text, p_start_date timestamptz, p_end_date timestamptz, p_payout_filter text, p_store_id text`
- Filter: When `p_payout_filter = 'returned'`, returns order lines where `is_returned = true` or status matches returned/cancelled.
- Return Columns: `order_id, order_created_at, sku, item_name, quantity, hpp, selling_price, order_status, payout_status, is_returned, store_name, ...`

### `finance_sku_order_details_group_20260625`
- Aggregates by SKU: `qty_sold, total_sales, total_hpp, gross_profit, qty_settled, settled_hpp, qty_unsettled, unpaid_hpp, qty_returned, hpp_return`
- Invariant: `unpaid_hpp` strictly excludes cancelled/returned orders. Cancelled/returned orders strictly in `hpp_return` and `qty_returned`.
