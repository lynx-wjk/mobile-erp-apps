# Finance Duplicate and Marketplace Gap Audit Plan

This document outlines the strategy for identifying duplicate data across the finance and marketplace operational tables without executing any destructive SQL operations (no `DELETE`, `DROP`, or `TRUNCATE`).

## Scope of Audit

We target the following critical tables to ensure that duplicate synchronization records are identified and accurately reported.

### 1. `marketplace_finance_reports`
- **Goal:** Identify cases where the same order/statement has been fetched and inserted multiple times.
- **Criteria:** Group by `tenant_id`, `marketplace_account_id`, `order_id`, and `statement_id`.
- **Expected Outcome:** `HAVING count(*) > 1`

### 2. `marketplace_orders`
- **Goal:** Identify cases where the same logical order (by `order_sn` or `order_id`) exists multiple times for a single account.
- **Criteria:** Group by `tenant_id`, `marketplace_account_id`, and a normalized order key (using `order_sn` falling back to `order_id`).
- **Expected Outcome:** `HAVING count(*) > 1`

### 3. `marketplace_order_items`
- **Goal:** Identify duplicate item allocations within a single order.
- **Criteria:** Group by `tenant_id`, `marketplace_order_id`, and the `marketplace_sku_id` (or `marketplace_sku`).
- **Expected Outcome:** `HAVING count(*) > 1`

### 4. Marketplace Finance Gap by Date
- **Goal:** Distinguish marketplace order ingestion from finance settlement ingestion for a selected period.
- **Criteria:** Compare `marketplace_orders` by `order_created_at` against `marketplace_finance_reports` by `period_start`, grouped by marketplace account.
- **Current proof for `2026-06-21..2026-06-21`:**
  - Shopee HAi has finance settlement rows: 90 rows / 90 finance orders / payout 5,300,903.
  - TikTok HAi has order rows: 238 rows / 238 orders.
  - TikTok HAi has 0 finance settlement rows for the same date.
- **Conclusion:** Hari Ini TikTok finance is an ingestion gap, not a UI filter/cache hiding existing TikTok finance settlement rows.

### 5. Cost Source Coverage
- **Goal:** Ensure Arus Kas and Biaya can audit all outgoing cost sources without relying on the lightweight dashboard snapshot.
- **Sources:** manual cash-out (`finance_company_cash_adjustments`), approved operational expenses (`finance_operational_expenses`), approved purchase requests/purchases, and paid production/tailor payments (`production_tailor_payments`).
- **Current proof for `2026-06-01..2026-06-21`:**
  - `approved_operational_expense`: 4 rows / 7,500,000.
  - `paid_production_tailor_payment`: 1 row / 500,000.
  - `manual_cash_out`: 0 rows.
  - `approved_purchase_requests`: 0 rows.
  - `approved_purchases`: 0 rows.
- **Conclusion:** Manual cash-out is restored in the UI source path, but the live database has no `direction='out'` manual adjustment rows in this period.

### 6. SKU Detail Duplicate Handling
- **Goal:** Deduplicate repeated detail rows without collapsing different SKU lines from the same order.
- **Criteria:** Prefer `marketplace_order_item_id`/external line identifiers, then fall back to order/resi/settlement/SKU/variant/qty/gross/payout/HPP facts.
- **Current proof for June 2026:** With service-role claims, `finance_sku_order_details` returns TikTok and Shopee SKU rows; `finance_sku_order_line_details` returns 25 paid rows and 25 unpaid rows for the first June SKU.
- **Conclusion:** The UI must deduplicate by line/facts, not by order ID only.

## Future Cleanup Plan (Deferred)

Once the read-only audit (using `supabase/sql/audit_finance_duplicates_readonly.sql`) confirms the scope of duplicates, the following cleanup strategy should be implemented:

1. **Dry-Run Validation**: Run a `SELECT` query utilizing `ctid` or primary keys to ensure that exactly $N-1$ rows are targeted for removal, keeping the most recently updated or canonical row.
2. **Execution**: Execute the cleanup strictly inside a `BEGIN; ... COMMIT;` transaction, verifying the exact count of affected rows before committing.
3. **Prevention**: Implement a `UNIQUE` constraint or enforce strict `ON CONFLICT` updates during data ingestion to prevent future duplicates.

*Note: No data will be deleted during the current hotfix cycle. This document serves purely as a preparatory audit.*
