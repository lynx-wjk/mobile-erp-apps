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

## Future Cleanup Plan (Deferred)

Once the read-only audit (using `supabase/sql/audit_finance_duplicates_readonly.sql`) confirms the scope of duplicates, the following cleanup strategy should be implemented:

1. **Dry-Run Validation**: Run a `SELECT` query utilizing `ctid` or primary keys to ensure that exactly $N-1$ rows are targeted for removal, keeping the most recently updated or canonical row.
2. **Execution**: Execute the cleanup strictly inside a `BEGIN; ... COMMIT;` transaction, verifying the exact count of affected rows before committing.
3. **Prevention**: Implement a `UNIQUE` constraint or enforce strict `ON CONFLICT` updates during data ingestion to prevent future duplicates.

*Note: No data will be deleted during the current hotfix cycle. This document serves purely as a preparatory audit.*
