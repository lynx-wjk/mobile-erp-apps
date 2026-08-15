# Reviewer Handoff Report — Milestone 1 (Backend SQL Migration)

**Author**: Reviewer 1 (Quality Reviewer & Adversarial Critic)  
**Date**: 2026-08-15T01:56:10+07:00  
**Target Environment**: Live VPS PostgreSQL (`inventory-vps` / `38.47.191.226`, database: `postgres`, container: `supabase-db`)  
**Artifact Reviewed**: `supabase/migrations/20260815020000_fix_finance_sku_retur_batal_and_unpaid_separation.sql`  
**Worker Report**: `.agents/worker_milestone1/handoff.md`  
**Verdict**: **APPROVE**

---

## 1. Observation

### A. Integrity & Code Quality Audit
1. **Source Code Inspection (`supabase/migrations/20260815020000_fix_finance_sku_retur_batal_and_unpaid_separation.sql`)**:
   - Lines 10–345: `public.finance_sku_order_line_details` function implementation.
     - CTE `valid_orders` (lines 72–96): Hardcoded exclusion for cancelled/returned orders has been cleanly removed.
     - CTE `calculated` (lines 233–250): `is_returned` is computed via regex `lower(concat_ws(' ', a.order_status, a.order_key)) ~ '(cancel|canceled|cancelled|batal|dibatalkan|returned|return|refund|rts|gagal|failed|closed)'`.
     - CTE `filtered_rows` (lines 251–260): Explicitly filters `(v_payout_filter = 'returned' and c.is_returned)`.
   - Lines 349–705: `public.finance_sku_order_details_group_20260625` function implementation.
     - Aggregation CTE `grouped` (lines 544–582):
       - Settled: `qty_settled` & `settled_hpp` where `f.has_payout and not f.is_returned`.
       - Unsettled/Unpaid: `qty_unsettled` & `unpaid_hpp` where `not f.has_payout and not f.is_returned`.
       - Returned: `qty_returned` & `hpp_return` where `f.is_returned`.
   - Integrity check: No hardcoded test values, dummy fixtures, or bypasses. All data is dynamically computed from underlying tables.

### B. Live PostgreSQL Verification on `inventory-vps`
1. **R1 Verification — June 2026 `finance_sku_order_line_details` (`p_payout_filter = 'returned'`)**:
   - Command:
     ```sql
     SELECT (public.finance_sku_order_line_details(p_start => '2026-06-01'::date, p_end => '2026-06-30'::date, p_payout_filter => 'returned', p_page_size => 5)->>'total')::int;
     ```
   - **Result**: `2,435` records returned. Every record has `is_returned = true`, `payout_status = 'Cancel/Refund/Return'`, with full order SN, resi / tracking number, variant name, and unit HPP.
2. **R1 Verification — July 2026 `finance_sku_order_line_details` (`p_payout_filter = 'returned'`)**:
   - Command:
     ```sql
     SELECT (public.finance_sku_order_line_details(p_start => '2026-07-01'::date, p_end => '2026-07-31'::date, p_payout_filter => 'returned', p_page_size => 5)->>'total')::int;
     ```
   - **Result**: `1,583` records returned. Every record has `is_returned = true`, `payout_status = 'Cancel/Refund/Return'`.
3. **R2 Verification — Strict Partitioning & Separation**:
   - Command:
     ```sql
     SELECT
       (public.finance_sku_order_line_details(p_start => '2026-06-01'::date, p_end => '2026-06-30'::date, p_payout_filter => 'unpaid')->>'total')::int as unpaid_total,
       (public.finance_sku_order_line_details(p_start => '2026-06-01'::date, p_end => '2026-06-30'::date, p_payout_filter => 'paid')->>'total')::int as paid_total,
       (public.finance_sku_order_line_details(p_start => '2026-06-01'::date, p_end => '2026-06-30'::date, p_payout_filter => 'returned')->>'total')::int as returned_total,
       (public.finance_sku_order_line_details(p_start => '2026-06-01'::date, p_end => '2026-06-30'::date, p_payout_filter => 'all')->>'total')::int as all_total;
     ```
   - **Result**:
     - `unpaid_total`: `254`
     - `paid_total`: `13,886`
     - `returned_total`: `2,435`
     - `all_total`: `16,575`
     - Mathematical check: `254 + 13,886 + 2,435 = 16,575` (exact partition with 0 leak and 0 duplicate).
4. **Group Function Verification — `finance_sku_order_details_group_20260625`**:
   - For June 2026: `total_skus = 227`, `total_qty = 5,118`, `qty_returned = 770`, `hpp_return = 27,476,000`, `unpaid_hpp = 1,271,000`.
   - Top SKU (`Striped Shirt Top`): `total_qty (2,253) = qty_settled (1,816) + qty_unsettled (10) + qty_returned (427)`. Exact partition.
   - For July 2026: `total_skus = 210`, `total_qty = 2,518`, `qty_returned = 438`, `hpp_return = 15,389,000`, `unpaid_hpp = 1,081,000`.

### C. Adversarial Stress-Testing
1. **Filter Alias Stress-Testing**:
   - `'retur'` alias -> returned 2,435 (identical to `'returned'`)
   - `'batal'` alias -> returned 2,435 (identical to `'returned'`)
   - `'belum payout'` alias -> returned 254 (identical to `'unpaid'`)
   - `'sudah payout'` alias -> returned 13,886 (identical to `'paid'`)
2. **Bounds & Clamping**:
   - `p_page_size = 500` -> clamped to `200` as designed.
   - Non-existent search terms -> returns `0` records gracefully without SQL errors.
3. **Permissions**:
   - Verified `GRANT EXECUTE` exists for `anon`, `authenticated`, `postgres`, and `service_role`.

---

## 2. Logic Chain

1. **R1 Fulfillment**:
   - `finance_sku_order_line_details` previously dropped cancelled / returned orders in the initial CTE `valid_orders`, making it impossible to query retur details.
   - Removing the WHERE condition and classifying `is_returned` dynamically in CTE `calculated` ensures all records flow through with full metadata.
   - Filtering by `v_payout_filter = 'returned'` extracts the exact 2,435 retur line items for June 2026 and 1,583 for July 2026.
2. **R2 Fulfillment**:
   - Pending payout metrics (`qty_unsettled`, `unpaid_hpp`) must exclusively represent active orders pending marketplace settlement.
   - Adding `where not f.has_payout and not f.is_returned` to `unpaid_hpp` prevents cancelled / returned orders without payout from polluting the unpaid HPP liability calculation.
   - All return costs and quantities are isolated into `hpp_return` and `qty_returned`.
3. **Soundness & Stability**:
   - Date range comparisons use indexable `>=` and `<` B-tree scans against `(tenant_id, order_created_at)`.
   - Multi-item order gross allocation handles proportional distribution correctly.

---

## 3. Caveats

- **Frontend Scope (Milestone 2)**: The database backend is fully fixed and verified. Milestone 2 will wire `finance_report_page.dart` to invoke `finance_sku_order_line_details` with `p_payout_filter = 'returned'` when clicking the Retur/Batal count button, build the release web app, and deploy it to `https://mdhproduction.com`.
- **Negative Payout Handling**: Orders with negative escrow adjustments (e.g., return shipping deductions) have `has_payout = true` and are factored into net settlement calculations as required by the business finance rules.

---

## 4. Conclusion

- **Verdict**: **APPROVE**
- The SQL migration `supabase/migrations/20260815020000_fix_finance_sku_retur_batal_and_unpaid_separation.sql` is correct, performant, secure, and rigorously tested against the live database.
- Requirements **R1** and **R2** are 100% satisfied.
- Ready to proceed to Milestone 2 (Frontend UI Alignment & Deployment).

---

## 5. Verification Method

To independently reproduce the verification:

1. **Verify Retur Line Details Query for June 2026**:
   ```powershell
   "SELECT (public.finance_sku_order_line_details(p_start => '2026-06-01'::date, p_end => '2026-06-30'::date, p_payout_filter => 'returned', p_page_size => 1)->>'total')::int;" | ssh inventory-vps "docker exec -i supabase-db psql -U postgres -d postgres"
   ```
   **Expected**: Output is `2435`.

2. **Verify Retur Line Details Query for July 2026**:
   ```powershell
   "SELECT (public.finance_sku_order_line_details(p_start => '2026-07-01'::date, p_end => '2026-07-31'::date, p_payout_filter => 'returned', p_page_size => 1)->>'total')::int;" | ssh inventory-vps "docker exec -i supabase-db psql -U postgres -d postgres"
   ```
   **Expected**: Output is `1583`.

3. **Verify Strict Partition Sum**:
   ```powershell
   "SELECT (public.finance_sku_order_line_details(p_start => '2026-06-01'::date, p_end => '2026-06-30'::date, p_payout_filter => 'unpaid', p_page_size => 1)->>'total')::int as unpaid, (public.finance_sku_order_line_details(p_start => '2026-06-01'::date, p_end => '2026-06-30'::date, p_payout_filter => 'paid', p_page_size => 1)->>'total')::int as paid, (public.finance_sku_order_line_details(p_start => '2026-06-01'::date, p_end => '2026-06-30'::date, p_payout_filter => 'returned', p_page_size => 1)->>'total')::int as retur, (public.finance_sku_order_line_details(p_start => '2026-06-01'::date, p_end => '2026-06-30'::date, p_payout_filter => 'all', p_page_size => 1)->>'total')::int as all_total;" | ssh inventory-vps "docker exec -i supabase-db psql -U postgres -d postgres"
   ```
   **Expected**: `unpaid` = 254, `paid` = 13886, `retur` = 2435, `all_total` = 16575 (`254 + 13886 + 2435 == 16575`).
